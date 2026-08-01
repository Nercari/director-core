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

# A fixed outer bound on every re-run test. Non-negotiable rule 4 says every
# agent call carries a timeout; this is that rule's enforcement point in the
# gate rather than only in prose. Overridable so the conformance suite can
# exercise the timeout path in seconds instead of a quarter of an hour.
TEST_TIMEOUT="${DIRECTOR_TEST_TIMEOUT:-900}"

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
  echo "  [SKIP]  check-jsonschema not installed; enforcing critical schema invariants locally"
fi

status="$(jq -r '.status' "$RESULT")"
route="$(jq -r '.route_used' "$RESULT")"

# check-jsonschema is optional on this host. These gate-critical schema
# invariants are enforced here as well, so a missing validator never widens
# what an executor can claim.
case "$status" in
  completed | blocked | failed) pass "status=$status is allowed" ;;
  *) fail "status=$status is not allowed — REJECT" ;;
esac

branch="$(jq -r '.branch // ""' "$RESULT")"
if [ -z "$branch" ] || [[ "$branch" == *$'\n'* ]] || ! [[ "$branch" =~ ^task/[a-z0-9][a-z0-9-]*$ ]]; then
  fail "branch=${branch:-<missing>} does not match task/<unit-id> — REJECT"
else
  pass "branch=$branch matches task/<unit-id>"
fi

if [ -z "$route" ] || [ "$route" = "null" ]; then
  fail "route_used is missing or empty — REJECT"
fi

for forbidden_key in candidate_commit pull_request_url branch_pushed; do
  if jq -e "has(\"$forbidden_key\")" "$RESULT" >/dev/null 2>&1; then
    fail "result contains forbidden key $forbidden_key — REJECT"
  fi
done

# The executor reports a completed working-tree diff. The orchestrator reviews,
# stages, and commits only after this validation; a candidate commit is neither
# expected nor possible under the configured workspace-write sandbox.
if [ "$status" = "completed" ]; then
  pass "status=completed (working-tree diff awaits orchestrator review)"
elif [ "$status" = "blocked" ] || [ "$status" = "failed" ]; then
  pass "status=$status"
fi

# Stopping stops being a valid way to say nothing.
#
# A blocked result must state what it hit. Counting entries is not enough: the
# schema admits the empty string, so a length-only check passes on [""] and on
# ["   "] — a placeholder satisfies the obligation while carrying no
# information. The check is on content, not on count.
#
# `failed` is deliberately outside this obligation. Whether it should carry the
# same one is a separate question and is not decided here.
if [ "$status" = "blocked" ]; then
  # \s alone leaves a hole: a zero-width space or a byte-order mark is not
  # matched by it, so an entry made of one counts as a stated risk while
  # rendering as nothing. Cf (format) and Zs (space separator) close it.
  substantive="$(jq '[.unresolved_risks[]?
                      | select(type == "string")
                      | select((gsub("[\\s\\p{Cf}\\p{Zs}]"; "")) != "")]
                     | length' "$RESULT" 2>/dev/null)"
  if [ "${substantive:-0}" -eq 0 ]; then
    fail "status=blocked with no substantive unresolved_risks entry — REJECT"
  else
    pass "status=blocked names $substantive substantive unresolved risk(s)"
  fi
fi

# main must be untouched. The executor works on a branch, in a worktree, only.
main_before="$(sed -n 's/^base_commit: *//p' "$RUN/worktree.yaml" 2>/dev/null)"
main_now="$(git -C "$ROOT" rev-parse main 2>/dev/null)"
base_valid=0
if [ -z "$main_before" ]; then
  fail "base_commit is missing or empty — REJECT"
elif ! git -C "$WT" cat-file -e "$main_before^{commit}" 2>/dev/null; then
  fail "base_commit $main_before is not a commit in the worktree — REJECT"
else
  base_valid=1
  pass "base_commit $main_before exists in the worktree"
fi
if [ -n "$main_before" ] && [ "$main_before" != "$main_now" ]; then
  fail "main moved during the unit ($main_before -> $main_now) — REJECT"
else
  pass "main unchanged"
fi

# Scope. Anything outside the packet's declared paths is out of scope, full stop.
#
# This FAILS CLOSED. Verified 2026-07-26: it previously skipped silently when the
# packet was missing or declared no paths, and printed
# "VALIDATED - safe to review, push, and open a pull request" for a commit
# containing a deliberate FORBIDDEN.txt. Both executors have been observed
# writing outside their declared scope, so an absent declaration is the one case
# where waving the change through is least acceptable.
if [ ! -f "$PACKET" ]; then
  fail "no packet at $PACKET — scope cannot be checked, so nothing is in scope — REJECT"
fi

if [ -f "$PACKET" ] && [ "$base_valid" -eq 1 ]; then
  changed="$(
    {
      git -C "$WT" diff --name-only --no-renames "$main_before"
      git -C "$WT" ls-files --others --exclude-standard
    } | sort -u
  )"
  allowed="$(sed -n '/^allowed_paths:/,/^[a-z_]*:/p' "$PACKET" | sed -n 's/^ *- *//p')"
  # The packet is the single declaration of scope. Nothing is denied by default
  # here and nothing is hardcoded: an empty forbidden_paths means no deny stage.
  forbidden="$(sed -n '/^forbidden_paths:/,/^[a-z_]*:/p' "$PACKET" | sed -n 's/^ *- *//p')"

  # A glob in both lists is not a conflict to resolve — it is a scope declaration
  # that does not say what it permits. Resolving it either way invents an intent
  # the packet never expressed, and resolving it permissively is the failure this
  # deny stage exists to prevent.
  ambiguous=""
  while IFS= read -r deny_glob; do
    [ -z "$deny_glob" ] && continue
    while IFS= read -r allow_glob; do
      [ -z "$allow_glob" ] && continue
      [ "$deny_glob" = "$allow_glob" ] && ambiguous="$ambiguous$deny_glob"$'\n'
    done <<< "$allowed"
  done <<< "$forbidden"
  if [ -n "$ambiguous" ]; then
    fail "ambiguous scope declaration — the same path is in both allowed_paths and forbidden_paths — REJECT:"
    # shellcheck disable=SC2086  # intentional word splitting, one path per line
    printf '            %s\n' $ambiguous
  fi

  if [ -z "$allowed" ]; then
    fail "packet declares no allowed_paths — REJECT. An undeclared scope is not an unlimited scope."
  elif [ -z "$ambiguous" ]; then
    # Deny before allow. A changed path matching any forbidden glob is rejected
    # whatever allowed_paths says, so granting scope on one file can never grant
    # scope on a file the packet explicitly withheld.
    denied=""
    outside=""
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      hit=""
      while IFS= read -r glob; do
        [ -z "$glob" ] && continue
        # shellcheck disable=SC2254
        case "$f" in $glob) hit="$glob"; break ;; esac
      done <<< "$forbidden"
      if [ -n "$hit" ]; then
        denied="$denied$f (matched forbidden_paths glob: $hit)"$'\n'
        continue
      fi
      ok=0
      while IFS= read -r glob; do
        [ -z "$glob" ] && continue
        # shellcheck disable=SC2254
        case "$f" in $glob) ok=1; break ;; esac
      done <<< "$allowed"
      [ "$ok" -eq 0 ] && outside="$outside$f"$'\n'
    done <<< "$changed"
    if [ -n "$denied" ]; then
      fail "files changed inside forbidden_paths — REJECT:"
      # The glob is named beside the path so the operator can tell a scope
      # violation from a validator bug without re-deriving the match. Printed a
      # line at a time: the reason text contains spaces, so the word-splitting
      # form used for bare paths below would shred it.
      while IFS= read -r denied_line; do
        [ -z "$denied_line" ] && continue
        printf '            %s\n' "$denied_line"
      done <<< "$denied"
    fi
    if [ -n "$outside" ]; then
      fail "files changed outside declared paths — REJECT:"
      # shellcheck disable=SC2086  # intentional word splitting, one path per line
      printf '            %s\n' $outside
    fi
    if [ -z "$denied" ] && [ -z "$outside" ]; then
      pass "all changed files within declared paths and outside forbidden_paths"
    fi
  fi
fi

# The executor is SUPPOSED to have no network, but as of 2026-07-26 it does
# (§8.3 correction). So this only catches an executor that ADMITS reaching the
# gate. An executor that pushes and stays quiet passes this check.
# It is a tripwire, not a control. The control is §21.8's account isolation.
if [ "$(jq -r '.pull_request_url // "absent"' "$RESULT")" != "absent" ]; then
  fail "result reports a pull_request_url — the executor reached the gate — REJECT"
else
  pass "executor did not report reaching the gate (tripwire only — not proof)"
fi

if [ -n "$route" ] && [ "$route" != "null" ]; then
  case "$route" in
    EXEC_PRIMARY | EXEC_STRONG | EXEC_LOCAL | DIRECT)
      pass "route_used=$route is authorised"
      ;;
    *)
      fail "route_used=$route is not allowed — REJECT"
      ;;
  esac
fi

# Tests are re-run here, independently. A self-reported pass is not evidence.
tests_declared_run="$(jq -r '[.tests_run[]?] | length' "$RESULT")"
declared="$(sed -n '/^required_tests:/,/^[a-z_]*:/p' "$PACKET" 2>/dev/null | sed -n 's/^ *- *//p')"
if [ -n "$declared" ]; then
  if [ "$tests_declared_run" -eq 0 ]; then
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
    # No shell. Each entry is split on whitespace into an argument vector and
    # executed directly, so a packet field cannot become a second command. The
    # packet is composed from material that includes externally authored issue
    # text, and the word "test" never constrained what the string did.
    #
    # An entry carrying metacharacters therefore becomes one command with
    # literal arguments: `python x.py; touch owned` runs python with the
    # arguments `x.py;`, `touch`, `owned`. It fails, and the side effect the
    # metacharacters were reaching for does not happen.
    #
    # Every entry written to date is two tokens — an interpreter and a script.
    # The entry shape in the contract is unchanged; nothing here needs more.
    #
    # KNOWN CEILING: timeout terminates the direct child, not a process tree.
    # A test that spawns a background process leaves it running on Windows.
    # Named, not fixed — closing it is out of scope.
    if ! command -v timeout >/dev/null 2>&1; then
      fail "timeout is not available — refusing to re-run tests unbounded (rule 4) — REJECT"
      trouble=1
    else
      while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        log="$RUN/evidence/$(echo "$cmd" | tr -c 'a-zA-Z0-9' '_' | cut -c1-60).log"
        # Word splitting is the whole mechanism: no globbing, no expansion, no
        # quote handling. Any of those would reintroduce what this removed.
        read -r -a argv <<< "$cmd"
        if [ "${#argv[@]}" -eq 0 ]; then
          continue
        fi
        (cd "$WT" && timeout "$TEST_TIMEOUT" "${argv[@]}") > "$log" 2>&1
        test_status=$?
        if [ "$test_status" -eq 0 ]; then
          pass "re-ran: $cmd"
        elif [ "$test_status" -eq 124 ]; then
          fail "re-run TIMED OUT after ${TEST_TIMEOUT}s: $cmd (see $log)"
          trouble=1
        else
          fail "re-run FAILED: $cmd (see $log)"
          trouble=1
        fi
      done <<< "$declared"
    fi
    [ "$trouble" -eq 0 ] && pass "raw output preserved in $RUN/evidence/"
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "REJECT — $FAIL check(s) failed. Nothing leaves this machine."
  exit 1
fi
if [ "$status" = "completed" ]; then
  echo "VALIDATED — safe to review, push, and open a pull request."
  exit 0
fi
echo "STOPPED: status=$status. Nothing is authorised to leave this machine."
exit 2
