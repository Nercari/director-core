#!/usr/bin/env bash
# baseline-probe — record what the environment can actually reach, right now.
# Issue #28, under #27. Blueprint §21.8, §21.9.
#
# WHY THIS EXISTS. Every later probe of the restricted account produces
# refusals. A refusal only means something if the same probe succeeded before
# the boundary existed. Without a "before" column, a refusal is indistinguishable
# from a broken environment, a host that is down, or a ref that never existed.
# The previous attempt at this work was rejected in review for exactly that.
#
# THIS SCRIPT CHANGES NOTHING. It records. Specifically:
#   - the push is --dry-run, to a ref name that exists nowhere and is never created
#   - every HTTP probe is a plain GET; no credentials are sent to the model host
#   - no file outside stdout is written
#
# RE-RUN IT VERBATIM under the restricted account. Same file, no edits, no
# arguments. That is the whole contract: the "after" column must come from the
# same probes as the "before" column, or the comparison is worthless.
#
# Credential results and network results are printed in separate sections and
# never merged into a verdict. A firewall refusal must never be read as a
# credential wrapper success, and vice versa. This script prints no verdict at
# all — it reports exit codes and raw output. Judgement belongs to the reader.
#
# Usage: bash scripts/baseline-probe.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The gate: where push, pull request, and merge authority live.
GATE_HOST="${DIRECTOR_GATE_HOST:-github.com}"
GATE_API_HOST="${DIRECTOR_GATE_API_HOST:-api.github.com}"

# The model API the bounded executor needs to keep reaching. Overridable
# because the exact endpoint for the bounded route has not been observed on the
# wire yet — #31 is where the proxy learns which hostname it must allow. The
# default is the documented public endpoint for that vendor. If #31 finds a
# different host, set DIRECTOR_MODEL_HOST rather than editing this file, so the
# before/after pair stays comparable.
MODEL_HOST="${DIRECTOR_MODEL_HOST:-generativelanguage.googleapis.com}"

# A neutral host that no allowance will cover once the boundary exists: not the
# gate, not the model API. It is the control for "everything else is refused".
BLOCKED_HOST="${DIRECTOR_BLOCKED_HOST:-example.com}"

# Exists nowhere, on purpose. --dry-run means it is never created either.
DEAD_REF="refs/heads/director-baseline-probe-never-created"

hr() { printf '%s\n' "------------------------------------------------------------"; }

# Run a probe, print its exit code on one line, then its raw output indented.
# Never aborts: a probe that fails IS a result.
probe() {
  local name="$1"
  shift
  local out status
  out="$("$@" 2>&1)"
  status=$?
  printf 'PROBE  %-24s exit=%d\n' "$name" "$status"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/       | /'
  else
    printf '       | (no output)\n'
  fi
  printf '\n'
}

echo "director baseline probe"
hr
# Criterion: the record states the account, machine, and date it was taken on.
printf 'account     %s\n' "$(whoami 2>&1)"
printf 'machine     %s\n' "$(hostname 2>&1)"
printf 'os          %s\n' "$(uname -s -r 2>&1)"
printf 'date_utc    %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>&1)"
printf 'repo        %s\n' "$ROOT"
printf 'gate        %s / %s\n' "$GATE_HOST" "$GATE_API_HOST"
printf 'model_host  %s\n' "$MODEL_HOST"
printf 'blocked_host %s\n' "$BLOCKED_HOST"
hr
echo

# --- CREDENTIALS ------------------------------------------------------------
# Can this account act as the gate? Answered on its own, in its own section.
echo "== CREDENTIALS =="
echo "Can this account exercise gate authority? Recorded independently of network reachability."
echo

if command -v gh >/dev/null 2>&1; then
  probe gh-auth-status gh auth status
  probe gh-api-user gh api user
else
  printf 'PROBE  %-24s exit=127\n       | gh not on PATH\n\n' "gh-auth-status"
  printf 'PROBE  %-24s exit=127\n       | gh not on PATH\n\n' "gh-api-user"
fi

# Dry run only. If this ever reports "[new branch]" the account can push.
probe git-push-dry-run \
  git -C "$ROOT" push --dry-run origin "HEAD:$DEAD_REF"

# --- NETWORK ----------------------------------------------------------------
# Can this account reach the wire? Separate section, separate lines, no merging
# with the credential result above.
echo "== NETWORK =="
echo "What can this account reach directly? Recorded independently of credential status."
echo

probe dns-gate nslookup "$GATE_HOST"
probe dns-model nslookup "$MODEL_HOST"

# -o /dev/null: the body is irrelevant, reachability is the measurement.
# A 401/404 from the model host still proves TCP+TLS completed to that host.
curl_probe() {
  curl -sS -o /dev/null --max-time 15 \
    -w 'http_code=%{http_code} remote_ip=%{remote_ip} tls=%{ssl_verify_result} time=%{time_total}s\n' \
    "$1"
}

probe https-blocked-host curl_probe "https://$BLOCKED_HOST"
probe https-model-host curl_probe "https://$MODEL_HOST"
probe https-gate-host curl_probe "https://$GATE_API_HOST"

hr
echo "END. No verdict is printed and none should be inferred from a single run."
echo "Compare against the restricted-account run of this same file, unedited."
