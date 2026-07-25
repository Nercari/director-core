#!/usr/bin/env bash
# validate-result — the gate between the executor and anything leaving the machine.
# Rejects claimed success. Blueprint §8.3.
# Usage: validate-result.sh <unit-id>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_NAME="$(basename "$ROOT")"
UNIT="${1:-}"
[ -n "$UNIT" ] || { echo "usage: validate-result.sh <unit-id>" >&2; exit 2; }

WT="$ROOT/../$REPO_NAME-$UNIT"
RUN="$ROOT/.director/runs/$UNIT"
RESULT="$RUN/result.json"
PACKET="$RUN/packet.yaml"
FAIL=0

pass() { printf '  [ OK ]  %s\n' "$1"; }
fail() { printf '  [FAIL]  %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "validate-result — unit $UNIT"
echo

[ -f "$RESULT" ] || { echo "  [FAIL]  no result.json at $RESULT"; exit 1; }
[ -d "$WT" ] || { echo "  [FAIL]  no worktree at $WT"; exit 1; }

if jq empty "$RESULT" 2>/dev/null; then
  pass "result.json is valid JSON"
else
  echo "  [FAIL]  result.json is not valid JSON"; exit 1
fi

if command -v check-jsonschema >/dev/null 2>&1; then
  if check-jsonschema --schemafile "$ROOT/schemas/result.schema.json" "$RESULT" >/dev/null 2>&1; then
    pass "result.json matches schema"
  else
    fail "result.json violates schemas/result.schema.json"
  fi
else
  echo "  [SKIP]  check-jsonschema not installed (CI enforces it)"
fi

status="$(jq -r '.status' "$RESULT")"
commit="$(jq -r '.candidate_commit // "null"' "$RESULT")"
route="$(jq -r '.route_used' "$RESULT")"

# A "completed" with no commit is the first conformance scenario. Reject.
if [ "$status" = "completed" ]; then
  if [ "$commit" = "null" ] || [ -z "$commit" ]; then
    fail "status=completed but no candidate_commit — REJECT"
  elif git -C "$WT" cat-file -e "$commit^{commit}" 2>/dev/null; then
    pass "candidate_commit $commit exists"
  else
    fail "candidate_commit $commit does not exist in the worktree — REJECT"
  fi
else
  pass "status=$status (no commit required)"
fi

# main must be untouched. The executor works on a branch, in a worktree, only.
main_before="$(sed -n 's/^base_commit: *//p' "$RUN/worktree.yaml" 2>/dev/null)"
main_now="$(git -C "$ROOT" rev-parse main 2>/dev/null)"
if [ -n "$main_before" ] && [ "$main_before" != "$main_now" ]; then
  fail "main moved during the unit ($main_before -> $main_now) — REJECT"
else
  pass "main unchanged"
fi

# Scope. Anything outside the packet's declared paths is out of scope, full stop.
if [ -f "$PACKET" ] && [ "$commit" != "null" ]; then
  changed="$(git -C "$WT" diff --name-only "$main_before" "$commit" 2>/dev/null)"
  allowed="$(sed -n '/^allowed_paths:/,/^[a-z_]*:/p' "$PACKET" | sed -n 's/^ *- *//p')"
  if [ -n "$allowed" ]; then
    outside=""
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      ok=0
      while IFS= read -r glob; do
        [ -z "$glob" ] && continue
        # shellcheck disable=SC2254
        case "$f" in $glob) ok=1; break ;; esac
      done <<< "$allowed"
      [ "$ok" -eq 0 ] && outside="$outside$f"$'\n'
    done <<< "$changed"
    if [ -n "$outside" ]; then
      fail "files changed outside declared paths — REJECT:"
      # shellcheck disable=SC2086  # intentional word splitting, one path per line
      printf '            %s\n' $outside
    else
      pass "all changed files within declared paths"
    fi
  fi
fi

# The executor has no network (§8.3). If it reached the gate, the sandbox failed.
if [ "$(jq -r '.pull_request_url // "absent"' "$RESULT")" != "absent" ]; then
  fail "result reports a pull_request_url — the executor reached the network — REJECT"
else
  pass "executor did not reach the gate"
fi

if jq -e '.route_used' "$RESULT" >/dev/null 2>&1; then
  if grep -q "$route" "$ROOT/.director/routes.yaml" 2>/dev/null \
    || [ "$route" = "DIRECT" ]; then
    pass "route_used=$route is authorised"
  else
    fail "route_used=$route is not in routes.yaml — REJECT"
  fi
fi

# Tests are re-run here, independently. A self-reported pass is not evidence.
skipped="$(jq -r '[.tests_run[]?] | length' "$RESULT")"
declared="$(sed -n '/^required_tests:/,/^[a-z_]*:/p' "$PACKET" 2>/dev/null | sed -n 's/^ *- *//p')"
if [ -n "$declared" ]; then
  if [ "$skipped" -eq 0 ]; then
    blocker="$(jq -r '.unresolved_risks | length' "$RESULT")"
    if [ "$blocker" -eq 0 ]; then
      fail "required tests declared but none run, and no blocker reported — REJECT"
    else
      pass "tests skipped with a reported blocker"
    fi
  else
    echo "  ....    re-running required tests independently"
    mkdir -p "$RUN/evidence"
    trouble=0
    while IFS= read -r cmd; do
      [ -z "$cmd" ] && continue
      log="$RUN/evidence/$(echo "$cmd" | tr -c 'a-zA-Z0-9' '_' | cut -c1-60).log"
      if (cd "$WT" && eval "$cmd") > "$log" 2>&1; then
        pass "re-ran: $cmd"
      else
        fail "re-run FAILED: $cmd (see $log)"
        trouble=1
      fi
    done <<< "$declared"
    [ "$trouble" -eq 0 ] && pass "raw output preserved in $RUN/evidence/"
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "REJECT — $FAIL check(s) failed. Nothing leaves this machine."
  exit 1
fi
echo "VALIDATED — safe to review, push, and open a pull request."
exit 0
