#!/usr/bin/env bash
# egress-boundary-probe — does the boundary hold? Issue #31, under #27.
#
# RUN THIS UNDER THE RESTRICTED ACCOUNT, after the operator has applied the
# firewall rules in docs/operator/egress-boundary.md and started the proxy.
# Run it verbatim, no edits, no arguments — the same contract as
# scripts/baseline-probe.sh, whose output is the "before" column this compares
# against. A refusal with no baseline is indistinguishable from a broken
# environment.
#
# THIS SCRIPT CHANGES NOTHING. The push is --dry-run against a ref name that
# exists nowhere. Every HTTP probe is a plain GET. No credentials are sent to
# the model host. It prints exit codes and raw output and reaches no verdict:
# judgement belongs to the reader, and a firewall refusal must never be read as
# a credential-wrapper success.
#
# THE CRITERION THAT DECIDES EVERYTHING is the DIRECT section. Setting proxy
# environment variables only routes a cooperative process. If a direct request
# succeeds with those variables unset, the proxy is a suggestion the executor
# can decline, and nothing else in this file matters.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GATE_HOST="${DIRECTOR_GATE_HOST:-github.com}"
GATE_API_HOST="${DIRECTOR_GATE_API_HOST:-api.github.com}"
MODEL_HOST="${DIRECTOR_MODEL_HOST:-generativelanguage.googleapis.com}"
BLOCKED_HOST="${DIRECTOR_BLOCKED_HOST:-example.com}"
PROXY_URL="${DIRECTOR_PROXY_URL:-http://127.0.0.1:8899}"
DEAD_REF="refs/heads/director-boundary-probe-never-created"

hr() { printf '%s\n' "------------------------------------------------------------"; }

# Never aborts. A probe that fails IS a result.
probe() {
  local name="$1"
  shift
  local out status
  out="$("$@" 2>&1)"
  status=$?
  printf 'PROBE  %-28s exit=%d\n' "$name" "$status"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/       | /'
  else
    printf '       | (no output)\n'
  fi
  printf '\n'
}

# --max-time keeps a silently dropped packet from hanging the probe: a firewall
# DROP produces a timeout, not a refusal, and a timeout is the observation.
curl_via_proxy() {
  curl -sS -o /dev/null --max-time 20 --proxy "$PROXY_URL" \
    -w 'http_code=%{http_code} remote_ip=%{remote_ip} time=%{time_total}s\n' "$1"
}

# env -u removes the variables rather than emptying them: curl treats an empty
# http_proxy as "no proxy" too, but an emptied variable still tells a reader the
# variable was considered. Removing them is the honest form of "unset".
curl_direct() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
    curl -sS -o /dev/null --max-time 20 --noproxy '*' \
    -w 'http_code=%{http_code} remote_ip=%{remote_ip} time=%{time_total}s\n' "$1"
}

echo "director egress boundary probe"
hr
printf 'account      %s\n' "$(whoami 2>&1)"
printf 'machine      %s\n' "$(hostname 2>&1)"
printf 'os           %s\n' "$(uname -s -r 2>&1)"
printf 'date_utc     %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>&1)"
printf 'repo         %s\n' "$ROOT"
printf 'gate         %s / %s\n' "$GATE_HOST" "$GATE_API_HOST"
printf 'model_host   %s\n' "$MODEL_HOST"
printf 'blocked_host %s\n' "$BLOCKED_HOST"
printf 'proxy        %s\n' "$PROXY_URL"
hr
echo

# --- NAME RESOLUTION --------------------------------------------------------
# The boundary permits DNS. If resolution fails, every later refusal has a
# second possible cause and the run proves nothing.
echo "== NAME RESOLUTION =="
echo "Permitted by design. A failure here invalidates the rest of this run."
echo
probe dns-model nslookup "$MODEL_HOST"
probe dns-gate nslookup "$GATE_HOST"

# --- THROUGH THE PROXY ------------------------------------------------------
echo "== THROUGH THE PROXY =="
echo "The model host must be reachable here. Everything else must not."
echo
probe proxy-model-host curl_via_proxy "https://$MODEL_HOST"
probe proxy-gate-host curl_via_proxy "https://$GATE_API_HOST"
probe proxy-blocked-host curl_via_proxy "https://$BLOCKED_HOST"

# --- DIRECT, PROXY VARIABLES UNSET -----------------------------------------
# The criterion the whole unit turns on. Recorded as its own section so it can
# never be summarised away into a general "network denied" line.
echo "== DIRECT, WITH THE PROXY VARIABLES UNSET =="
echo "Every probe in this section MUST fail. A success here means the proxy is"
echo "optional, the executor can decline it, and the boundary does not exist."
echo
probe direct-model-host curl_direct "https://$MODEL_HOST"
probe direct-gate-host curl_direct "https://$GATE_API_HOST"
probe direct-blocked-host curl_direct "https://$BLOCKED_HOST"

# QUIC would route around a TCP-only rule, so UDP/443 is denied for this
# account and that denial is probed rather than assumed. curl reports a protocol
# failure if the datagram never leaves.
if curl --version 2>/dev/null | grep -q HTTP3; then
  probe direct-quic-model \
    env -u https_proxy -u HTTPS_PROXY curl -sS -o /dev/null --max-time 20 --http3-only \
      -w 'http_code=%{http_code} time=%{time_total}s\n' "https://$MODEL_HOST"
else
  printf 'PROBE  %-28s exit=127\n       | curl has no HTTP3 support; UDP/443 not probed here.\n' "direct-quic-model"
  printf '       | The firewall rule is still required — see the operator doc.\n\n'
fi

# --- CREDENTIALS ------------------------------------------------------------
# Separate section, separate lines. This answers "can this account act as the
# gate", which is a different question from "can this account reach the wire",
# and the two answers must never be merged.
echo "== CREDENTIALS =="
echo "Recorded independently of every network result above."
echo
if command -v gh >/dev/null 2>&1; then
  probe gh-auth-status gh auth status
  probe gh-api-user gh api user
else
  printf 'PROBE  %-28s exit=127\n       | gh not on PATH\n\n' "gh-auth-status"
  printf 'PROBE  %-28s exit=127\n       | gh not on PATH\n\n' "gh-api-user"
fi
probe git-push-dry-run git -C "$ROOT" push --dry-run origin "HEAD:$DEAD_REF"

hr
echo "No verdict is printed on purpose. Read the DIRECT section first: if any"
echo "probe there succeeded, the boundary does not hold and nothing else counts."
