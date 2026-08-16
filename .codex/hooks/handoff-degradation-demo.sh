#!/usr/bin/env bash
# Operator-visible behavior check: handoff validation fails closed when the
# required validator is unavailable. Ticket #47.
#
# Every case prints the handoff it fed the hook, the state of the validator, and
# the verdict, so the decisions can be watched happening. It does not report
# that a suite passed.
#
# Each case runs against a throwaway Git fixture, never this repository, so the
# real .director/current-handoff.json is never read or written. The hook resolves
# its paths from the Git top level, which is what makes the fixture work.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_SOURCE="$ROOT/.claude/hooks/require-handoff.sh"
SCHEMA_SOURCE="$ROOT/schemas/handoff.schema.json"
ROUTES_SOURCE="$ROOT/.director/routes.yaml"
ROUTING_POLICY_SOURCE="$ROOT/.telemetry/routing-policy.yaml"
FAILURES=0
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

# A handoff that satisfies the contract. Cases derive their variants from it.
VALID='{"published_at":"2026-07-29T00:00:00Z","run_id":"demo","capacity_state":"C","objective":"demonstrate the gate","repository_state":{"main_commit":"0123456","open_branches":[],"open_pull_requests":[]},"decisions_taken":[],"next_action":"stop","layer2":{"executor_vendor":"openai","reviewer_vendor":"anthropic","self_review":false},"workflow_efficiency":{"work_unit_route":"director-primary_executor-strong"}}'

# A stub standing in for an installed validator. It accepts or refuses on
# command, so the validator-present arm is observable on a machine that does
# not have check-jsonschema.
stub_dir() {
  local mode="$1" dir
  dir="$TEMP/stub-$mode-$RANDOM"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$mode" = accept ]; then printf 'exit 0\n'; else printf 'exit 1\n'; fi
  } > "$dir/check-jsonschema"
  chmod +x "$dir/check-jsonschema"
  printf '%s' "$dir"
}

# "Absent" has to mean absent. On CI this runner installs check-jsonschema, so
# leaving PATH alone would silently run the validator-present code for every case
# labelled absent. The directory holding the real binary is removed from PATH
# instead of trusting the label.
absent_path() {
  local real dir entry out=""
  real="$(command -v check-jsonschema 2>/dev/null || true)"
  if [ -z "$real" ]; then printf '%s' "$PATH"; return; fi
  dir="$(cd "$(dirname "$real")" && pwd)"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ -d "$entry" ] && [ "$(cd "$entry" && pwd)" = "$dir" ]; then continue; fi
    out="${out:+$out:}$entry"
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  printf '%s' "$out"
}
ABSENT_PATH="$(absent_path)"

# check <expected> <label> <validator: absent|accept|refuse> <in-flight: yes|no>
#       <handoff-json|OMIT> [drop-schema] [expected-output]
check() {
  local expected="$1" label="$2" validator="$3" inflight="$4" handoff="$5" drop="${6:-}" expected_output="${7:-}"
  local fixture code verdict output path

  fixture="$TEMP/fixture-$RANDOM$RANDOM"
  mkdir -p "$fixture/.claude/hooks" "$fixture/.director" "$fixture/.telemetry" "$fixture/schemas"
  git init -q "$fixture" 2>/dev/null
  cp "$HOOK_SOURCE" "$fixture/.claude/hooks/require-handoff.sh"
  [ "$drop" = drop-schema ] || cp "$SCHEMA_SOURCE" "$fixture/schemas/handoff.schema.json"
  cp "$ROUTES_SOURCE" "$fixture/.director/routes.yaml"
  cp "$ROUTING_POLICY_SOURCE" "$fixture/.telemetry/routing-policy.yaml"
  [ "$inflight" = yes ] && printf '%s\n' "$fixture" > "$fixture/.director/active-worktree"
  [ "$handoff" = OMIT ] || printf '%s' "$handoff" > "$fixture/.director/current-handoff.json"

  case "$validator" in
  accept | refuse) path="$(stub_dir "$validator"):$PATH" ;;
  absent) path="$ABSENT_PATH" ;;
  esac

  printf '=== %s\n' "$label"
  printf '  validator    : %s\n' "$validator"
  printf '  unit in flight: %s\n' "$inflight"
  if [ "$handoff" = OMIT ]; then
    printf '  handoff      : (no file)\n'
  else
    printf '  handoff      : %s\n' "$handoff"
  fi

  output="$(cd "$fixture" && printf '{}' | PATH="$path" bash .claude/hooks/require-handoff.sh 2>&1)"
  code=$?
  case "$code" in
  0) verdict=ALLOWED ;;
  2) verdict=DENIED ;;
  *) verdict="ERROR (exit $code)" ;;
  esac
  printf '  verdict      : %s (expected %s)\n' "$verdict" "$expected"
  # The reason is part of the behaviour: a refusal that does not say what is
  # wrong sends the operator back to the schema by hand.
  printf '%s\n' "$output" | sed 's/^/  | /'
  printf '\n'

  [ "$verdict" = "$expected" ] || FAILURES=$((FAILURES + 1))
  if [ -n "$expected_output" ] && ! printf '%s' "$output" | grep -Fq "$expected_output"; then
    printf '  expected output: %s\n' "$expected_output"
    FAILURES=$((FAILURES + 1))
  fi
}

INSTALL_HINT="Install it with: pipx install check-jsonschema"

echo "handoff validation fail-closed — behavior check"
echo

echo "--- validator absent: the active cycle must stop with installation guidance"
check DENIED "empty object" absent yes '{}'
check DENIED "missing next_action" absent yes \
  "$(printf '%s' "$VALID" | jq 'del(.next_action)')"
check DENIED "missing repository_state.main_commit" absent yes \
  "$(printf '%s' "$VALID" | jq 'del(.repository_state.main_commit)')"
check DENIED "objective present but empty" absent yes \
  "$(printf '%s' "$VALID" | jq '.objective = ""')"
check DENIED "capacity_state outside the enumeration" absent yes \
  "$(printf '%s' "$VALID" | jq '.capacity_state = "Z"')"
check DENIED "no handoff file at all" absent yes OMIT
check DENIED "not valid JSON" absent yes 'not json at all'
check DENIED "no validator and no schema either" absent yes "$VALID" drop-schema
check DENIED "valid handoff" absent yes "$VALID" "" "$INSTALL_HINT"

echo "--- validator present: behaviour unchanged"
check ALLOWED "valid handoff, validator accepts" accept yes "$VALID"
check DENIED "validator refuses" refuse yes "$VALID"
check DENIED "empty object, validator refuses" refuse yes '{}'

echo "--- no unit in flight: an ordinary conversation is not a cycle"
check ALLOWED "no active worktree, no handoff" absent no OMIT
check ALLOWED "no active worktree, junk handoff" absent no '{}'

echo "--- malformed handoff remains blocked when validator is absent"
check DENIED "unknown field, validator absent" absent yes \
  "$(printf '%s' "$VALID" | jq '.invented_field = "not in the schema"')"
check DENIED "unknown field, validator present" refuse yes \
  "$(printf '%s' "$VALID" | jq '.invented_field = "not in the schema"')"

if [ "$FAILURES" -ne 0 ]; then
  printf 'handoff fail-closed demo FAILED: %s wrong verdict(s)\n' "$FAILURES" >&2
  exit 1
fi
echo "handoff fail-closed demo: every verdict as specified."
exit 0
