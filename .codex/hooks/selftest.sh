#!/usr/bin/env bash
# Proves the hooks refuse what they must and permit what they must.
# Run by CI (gate.yml) and by the operator during Phase 1 verification.
#
# A gate never seen refusing something is not a gate — so this asserts BOTH
# directions, and it deliberately asserts the known bypass too. A test suite
# that hides a weakness is worse than no test suite.
set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HOOKS/../.." && pwd)"
FAILURES=0
CONTROL_DIR="$(mktemp -d)"
ACTIVE_FILE="$ROOT/.director/active-worktree"
HANDOFF_FILE="$ROOT/.director/current-handoff.json"
ACTIVE_BACKUP=""
HANDOFF_BACKUP=""

# shellcheck disable=SC2329,SC2317  # invoked indirectly by the EXIT trap below,
# which older shellcheck reports as unreachable (SC2317) and newer as uncalled
# (SC2329). Both are the same blind spot: neither version follows a trap.
# Both codes are listed because CI's shellcheck and a current local build
# disagree about which one to emit.
# The trap is deliberate: this restores .director/active-worktree even when an
# assertion fails, because leaving that file behind changes hook behaviour for
# every later session, and deleting it while a unit is live silently disables
# both hooks it gates.
restore_control_files() {
  if [ -n "$ACTIVE_BACKUP" ]; then
    cp "$ACTIVE_BACKUP" "$ACTIVE_FILE"
  else
    rm -f "$ACTIVE_FILE"
  fi
  if [ -n "$HANDOFF_BACKUP" ]; then
    cp "$HANDOFF_BACKUP" "$HANDOFF_FILE"
  else
    rm -f "$HANDOFF_FILE"
  fi
  rm -rf "$CONTROL_DIR"
}
# Case (a): this selftest writes the repository's active-worktree and handoff
# controls, so EXIT always restores their prior state, including on failure.
trap restore_control_files EXIT

HOOK_PATH="$PATH"

# Exercise both the installed-validator path and the fail-closed path where
# check-jsonschema is absent. The stub only selects the installed path; the
# hook still performs the Layer 2 checks at the handoff seam.
stub_dir() {
  local mode="$1" dir
  dir="$CONTROL_DIR/check-jsonschema-$mode"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$mode" = accept ]; then printf 'exit 0\n'; else printf 'exit 1\n'; fi
  } > "$dir/check-jsonschema"
  chmod +x "$dir/check-jsonschema"
  printf '%s' "$dir"
}

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
PRESENT_PATH="$(stub_dir accept):$PATH"

VALID_HANDOFF='{"published_at":"2026-07-27T00:00:00Z","run_id":"selftest","capacity_state":"A","objective":"exercise the hook","repository_state":{"main_commit":"0123456","open_branches":[],"open_pull_requests":[]},"decisions_taken":[],"next_action":"stop","layer2":{"executor_vendor":"openai","reviewer_vendor":"anthropic","self_review":true},"workflow_efficiency":{"work_unit_route":"director-primary_executor-strong"}}'

if [ -f "$ACTIVE_FILE" ]; then
  ACTIVE_BACKUP="$CONTROL_DIR/active-worktree"
  cp "$ACTIVE_FILE" "$ACTIVE_BACKUP"
fi
if [ -f "$HANDOFF_FILE" ]; then
  HANDOFF_BACKUP="$CONTROL_DIR/current-handoff.json"
  cp "$HANDOFF_FILE" "$HANDOFF_BACKUP"
fi

# expect_block <label> <hook> <json>
expect_block() {
  local label="$1" hook="$2" json="$3" code
  printf '%s' "$json" | PATH="$HOOK_PATH" bash "$HOOKS/$hook" >/dev/null 2>&1
  code=$?
  if [ "$code" -eq 2 ]; then
    printf '  [ OK ]  blocked: %s\n' "$label"
  else
    printf '  [FAIL]  NOT blocked (exit %s): %s\n' "$code" "$label"
    FAILURES=$((FAILURES + 1))
  fi
}

# expect_block_message additionally proves that a same-vendor refusal explains
# the unit, both recorded vendors, and the cross-vendor rule to the operator.
expect_block_message() {
  local label="$1" hook="$2" json="$3" expected="$4" code output
  output="$(printf '%s' "$json" | PATH="$HOOK_PATH" bash "$HOOKS/$hook" 2>&1 >/dev/null)"
  code=$?
  if [ "$code" -eq 2 ] && printf '%s' "$output" | grep -Fq "$expected"; then
    printf '  [ OK ]  blocked with reason: %s\n' "$label"
  else
    printf '  [FAIL]  wrong refusal (exit %s): %s\n' "$code" "$label"
    printf '           expected text: %s\n' "$expected"
    printf '           actual output: %s\n' "$output"
    FAILURES=$((FAILURES + 1))
  fi
}

# expect_allow <label> <hook> <json>
expect_allow() {
  local label="$1" hook="$2" json="$3" code
  printf '%s' "$json" | PATH="$HOOK_PATH" bash "$HOOKS/$hook" >/dev/null 2>&1
  code=$?
  if [ "$code" -eq 0 ]; then
    printf '  [ OK ]  allowed: %s\n' "$label"
  else
    printf '  [FAIL]  wrongly blocked (exit %s): %s\n' "$code" "$label"
    FAILURES=$((FAILURES + 1))
  fi
}

# assert_worktree_active_file proves the lifecycle command creates and removes
# the hook control in an isolated Git fixture. The fixture keeps this selftest
# from creating a real unit or changing this repository's history.
assert_worktree_active_file() {
  local temporary fixture script active expected code
  temporary="$(mktemp -d)"
  fixture="$temporary/fixture-repository"
  script="$fixture/scripts/worktree.sh"
  mkdir -p "$fixture/scripts" "$fixture/.director"
  cp "$ROOT/scripts/worktree.sh" "$script"
  git init --initial-branch=main "$fixture" >/dev/null 2>&1 || { rm -rf "$temporary"; return 1; }
  git -C "$fixture" config user.name "Hook selftest" || { rm -rf "$temporary"; return 1; }
  git -C "$fixture" config user.email "hook-selftest@director.local" || { rm -rf "$temporary"; return 1; }
  printf 'fixture\n' > "$fixture/README.md"
  if ! git -C "$fixture" add README.md || ! git -C "$fixture" commit -m fixture >/dev/null 2>&1; then
    rm -rf "$temporary"
    return 1
  fi
  local create_output remove_output
  create_output="$(bash "$script" create selftest-active 2>&1)"
  code=$?
  active="$fixture/.director/active-worktree"
  expected="$temporary/fixture-repository-selftest-active"
  if [ "$code" -ne 0 ] || [ ! -f "$active" ] || [ "$(tr -d '\r\n' < "$active")" != "$expected" ]; then
    printf '%s\n' "$create_output" >&2
    rm -rf "$temporary"
    return 1
  fi
  remove_output="$(bash "$script" remove selftest-active 2>&1)"
  code=$?
  if [ "$code" -ne 0 ] || [ -e "$active" ]; then
    printf '%s\n' "$remove_output" >&2
    rm -rf "$temporary"
    return 1
  fi
  rm -rf "$temporary"
  return 0
}

bash_cmd() { printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
file_path() { printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

run_layer2_cases() {
  local path_label="$1" path_value="$2"
  HOOK_PATH="$path_value"

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq 'del(.layer2)')" > "$HANDOFF_FILE"
  expect_block "$path_label: layer2 missing" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq 'del(.layer2.executor_vendor)')" > "$HANDOFF_FILE"
  expect_block "$path_label: layer2.executor_vendor missing" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq 'del(.layer2.reviewer_vendor)')" > "$HANDOFF_FILE"
  expect_block "$path_label: layer2.reviewer_vendor missing" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq 'del(.layer2.self_review)')" > "$HANDOFF_FILE"
  expect_block "$path_label: layer2.self_review missing" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.layer2.executor_vendor = "vendor-not-recognised"')" > "$HANDOFF_FILE"
  expect_block "$path_label: executor vendor outside enum" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.layer2.reviewer_vendor = "vendor-not-recognised"')" > "$HANDOFF_FILE"
  expect_block "$path_label: reviewer vendor outside enum" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.layer2.self_review = "true"')" > "$HANDOFF_FILE"
  expect_block "$path_label: self_review is not boolean" require-handoff.sh '{}'

  printf '%s\n' "$VALID_HANDOFF" > "$HANDOFF_FILE"
  expect_allow "$path_label: two recognised vendors" require-handoff.sh '{}'

  same_vendor_no_self_review="$(printf '%s' "$VALID_HANDOFF" | jq '.layer2.reviewer_vendor = .layer2.executor_vendor | .layer2.self_review = false')"
  printf '%s\n' "$same_vendor_no_self_review" > "$HANDOFF_FILE"
  expect_block_message "$path_label: same vendor without self-review" require-handoff.sh '{}' \
    "unit 'selftest' cannot end: Layer 2 executor_vendor='openai' and reviewer_vendor='openai' are the same; cross-vendor review is required"

  same_vendor_self_review="$(printf '%s' "$same_vendor_no_self_review" | jq '.layer2.self_review = true')"
  printf '%s\n' "$same_vendor_self_review" > "$HANDOFF_FILE"
  expect_allow "$path_label: same vendor declared self-review permitted" require-handoff.sh '{}'
  expect_block "$path_label: self-review cannot arm auto-merge" block-dangerous-bash.sh \
    "$(bash_cmd 'gh pr merge 4 --auto --squash')"

  printf '%s\n' "$(printf '%s' "$same_vendor_self_review" | jq '.workflow_efficiency = {work_unit_route: "ORCH_PRIMARY"}')" > "$HANDOFF_FILE"
  expect_block "$path_label: self-review cannot bypass route/vendor check" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.layer2.self_review = false')" > "$HANDOFF_FILE"
  expect_allow "$path_label: false self_review permitted" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq 'del(.workflow_efficiency)')" > "$HANDOFF_FILE"
  expect_block "$path_label: missing work_unit_route blocks lookup bypass" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: null}')" > "$HANDOFF_FILE"
  expect_block "$path_label: null work_unit_route blocks lookup bypass" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "director-primary_executor-strong"}')" > "$HANDOFF_FILE"
  expect_allow "$path_label: route vendor agrees with executor vendor" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "director-primary_executor-primary"}')" > "$HANDOFF_FILE"
  expect_block "$path_label: route vendor disagrees with executor vendor" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "primary-then-strong-escalation"}')" > "$HANDOFF_FILE"
  expect_block_message "$path_label: ambiguous escalation route is refused" require-handoff.sh '{}' \
    "multiple executor candidates; record the effective executor route explicitly"

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "DIRECT"}')" > "$HANDOFF_FILE"
  expect_block "$path_label: route has no vendor key" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "ROUTE_NOT_REGISTERED"}')" > "$HANDOFF_FILE"
  expect_block "$path_label: route is not registered" require-handoff.sh '{}'

  direct_self_review="$(printf '%s' "$VALID_HANDOFF" | jq '.capacity_state = "C_prime" | .layer2 = {executor_vendor: "anthropic", reviewer_vendor: "anthropic", self_review: true} | .workflow_efficiency = {work_unit_route: "direct-orchestrator"}')"
  printf '%s\n' "$direct_self_review" > "$HANDOFF_FILE"
  expect_allow "$path_label: direct-orchestrator self-review is explicit and permitted" require-handoff.sh '{}'

  direct_without_self_review="$(printf '%s' "$VALID_HANDOFF" | jq '.capacity_state = "C_prime" | .layer2 = {executor_vendor: "openai", reviewer_vendor: "anthropic", self_review: false} | .workflow_efficiency = {work_unit_route: "direct-orchestrator"}')"
  printf '%s\n' "$direct_without_self_review" > "$HANDOFF_FILE"
  expect_block_message "$path_label: direct-orchestrator requires explicit self-review" require-handoff.sh '{}' \
    "requires layer2.self_review=true"

  direct_wrong_vendor="$(printf '%s' "$VALID_HANDOFF" | jq '.capacity_state = "C_prime" | .layer2 = {executor_vendor: "openai", reviewer_vendor: "anthropic", self_review: true} | .workflow_efficiency = {work_unit_route: "direct-orchestrator"}')"
  printf '%s\n' "$direct_wrong_vendor" > "$HANDOFF_FILE"
  expect_block_message "$path_label: direct-orchestrator effective vendor must agree" require-handoff.sh '{}' \
    "declares effective vendor 'anthropic', but layer2.executor_vendor is 'openai'"
}

assert_producer_workflow_route() {
  local temporary ledger generated generated_code efficiency real_handoff
  temporary="$(mktemp -d)"
  ledger="$temporary/invocations.jsonl"
  # Synthetic ledger row: it deliberately supplies only the producer's required
  # identity fields. This checks the real handoff_efficiency.py output shape and
  # route-ID semantics; it is not provider telemetry or a captured model run.
  printf '%s\n' '{"work_unit_id":"selftest-route","route_id":"director-primary_executor-strong"}' > "$ledger"
  generated="$(python "$ROOT/scripts/telemetry/handoff_efficiency.py" \
    --work-unit-id selftest-route \
    --ledger "$ledger" \
    --decision-log "$temporary/routing-decisions.jsonl" 2>&1)"
  generated_code=$?
  if [ "$generated_code" -ne 0 ]; then
    printf '  [FAIL]  handoff_efficiency.py could not produce a route: %s\n' "$generated"
    FAILURES=$((FAILURES + 1))
    rm -rf "$temporary"
    return
  fi
  efficiency="$(printf '%s' "$generated" | jq -c '.workflow_efficiency')"
  real_handoff="$(printf '%s' "$VALID_HANDOFF" | jq --argjson value "$efficiency" '.workflow_efficiency = $value')"
  printf '%s\n' "$real_handoff" > "$HANDOFF_FILE"
  expect_allow "producer handoff_efficiency.py route ID is accepted" require-handoff.sh '{}'
  rm -rf "$temporary"
}

assert_vendorless_registry_route() {
  local temporary fixture output code handoff
  temporary="$(mktemp -d)"
  fixture="$temporary/fixture"
  mkdir -p "$fixture/.claude/hooks" "$fixture/.director" "$fixture/schemas"
  git init -q "$fixture" >/dev/null 2>&1
  cp "$ROOT/.claude/hooks/require-handoff.sh" "$fixture/.claude/hooks/require-handoff.sh"
  cp "$ROOT/schemas/handoff.schema.json" "$fixture/schemas/handoff.schema.json"
  printf '%s\n' "$fixture" > "$fixture/.director/active-worktree"
  printf '%s\n' 'routes:' '  EXEC_VENDORLESS:' '    tool: codex' > "$fixture/.director/routes.yaml"
  handoff="$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "EXEC_VENDORLESS"}')"
  printf '%s\n' "$handoff" > "$fixture/.director/current-handoff.json"
  output="$(cd "$fixture" && PATH="$PRESENT_PATH" bash .claude/hooks/require-handoff.sh 2>&1)"
  code=$?
  if [ "$code" -eq 2 ] && printf '%s' "$output" | grep -Fq "has no vendor key"; then
    printf '  [ OK ]  newly declared route without vendor is refused\n'
  else
    printf '  [FAIL]  vendorless route was not refused (exit %s): %s\n' "$code" "$output"
    FAILURES=$((FAILURES + 1))
  fi
  rm -rf "$temporary"
}

assert_direct_registry_semantics() {
  local temporary fixture output code handoff direct_allowed
  temporary="$(mktemp -d)"
  fixture="$temporary/fixture"
  mkdir -p "$fixture/.claude/hooks" "$fixture/.director" "$fixture/.telemetry" "$fixture/schemas"
  git init -q "$fixture" >/dev/null 2>&1
  cp "$ROOT/.claude/hooks/require-handoff.sh" "$fixture/.claude/hooks/require-handoff.sh"
  cp "$ROOT/schemas/handoff.schema.json" "$fixture/schemas/handoff.schema.json"
  printf '%s\n' "$fixture" > "$fixture/.director/active-worktree"
  printf '%s\n' 'routes:' '  ORCH_PRIMARY:' '    vendor: anthropic' '  DIRECT:' '    vendor: openai' > "$fixture/.director/routes.yaml"
  printf '%s\n' 'route_ids:' '  direct-orchestrator:' '    orchestrator: ORCH_PRIMARY' '    executor: DIRECT' > "$fixture/.telemetry/routing-policy.yaml"

  handoff="$(printf '%s' "$VALID_HANDOFF" | jq '.capacity_state = "C_prime" | .layer2 = {executor_vendor: "anthropic", reviewer_vendor: "anthropic", self_review: true} | .workflow_efficiency = {work_unit_route: "direct-orchestrator"}')"
  printf '%s\n' "$handoff" > "$fixture/.director/current-handoff.json"
  output="$(cd "$fixture" && PATH="$PRESENT_PATH" bash .claude/hooks/require-handoff.sh 2>&1)"
  code=$?
  if [ "$code" -eq 0 ]; then
    printf '  [ OK ]  direct-orchestrator ignores a conflicting DIRECT registry vendor\n'
  else
    printf '  [FAIL]  explicit direct-orchestrator was blocked by DIRECT registry vendor (exit %s): %s\n' "$code" "$output"
    FAILURES=$((FAILURES + 1))
  fi

  handoff="$(printf '%s' "$handoff" | jq '.layer2.self_review = false | .layer2.executor_vendor = "openai" | .layer2.reviewer_vendor = "anthropic"')"
  printf '%s\n' "$handoff" > "$fixture/.director/current-handoff.json"
  output="$(cd "$fixture" && PATH="$PRESENT_PATH" bash .claude/hooks/require-handoff.sh 2>&1)"
  code=$?
  if [ "$code" -eq 2 ] && printf '%s' "$output" | grep -Fq 'requires layer2.self_review=true'; then
    printf '  [ OK ]  direct-orchestrator still requires explicit self-review\n'
  else
    printf '  [FAIL]  direct-orchestrator self-review bypassed (exit %s): %s\n' "$code" "$output"
    FAILURES=$((FAILURES + 1))
  fi

  direct_allowed="$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "DIRECT"}')"
  printf '%s\n' "$direct_allowed" > "$fixture/.director/current-handoff.json"
  output="$(cd "$fixture" && PATH="$PRESENT_PATH" bash .claude/hooks/require-handoff.sh 2>&1)"
  code=$?
  if [ "$code" -eq 2 ] && printf '%s' "$output" | grep -Fq 'only through the explicit direct-orchestrator policy'; then
    printf '  [ OK ]  raw DIRECT registry route is refused\n'
  else
    printf '  [FAIL]  raw DIRECT registry route was accepted (exit %s): %s\n' "$code" "$output"
    FAILURES=$((FAILURES + 1))
  fi
  rm -rf "$temporary"
}

run_registry_conflict_case() {
  local label="$1" route_name="$2" expected="$3" routes_yaml="$4" policy_yaml="${5:-}"
  local temporary fixture output code handoff
  temporary="$(mktemp -d)"
  fixture="$temporary/fixture"
  mkdir -p "$fixture/.claude/hooks" "$fixture/.director" "$fixture/schemas"
  git init -q "$fixture" >/dev/null 2>&1
  cp "$ROOT/.claude/hooks/require-handoff.sh" "$fixture/.claude/hooks/require-handoff.sh"
  cp "$ROOT/schemas/handoff.schema.json" "$fixture/schemas/handoff.schema.json"
  printf '%s\n' "$fixture" > "$fixture/.director/active-worktree"
  printf '%s\n' "$routes_yaml" > "$fixture/.director/routes.yaml"
  if [ -n "$policy_yaml" ]; then
    mkdir -p "$fixture/.telemetry"
    printf '%s\n' "$policy_yaml" > "$fixture/.telemetry/routing-policy.yaml"
  fi
  handoff="$(printf '%s' "$VALID_HANDOFF" | jq --arg route "$route_name" '.workflow_efficiency = {work_unit_route: $route}')"
  printf '%s\n' "$handoff" > "$fixture/.director/current-handoff.json"
  output="$(cd "$fixture" && PATH="$PRESENT_PATH" bash .claude/hooks/require-handoff.sh 2>&1)"
  code=$?
  if [ "$code" -eq 2 ] && printf '%s' "$output" | grep -Fq "$expected"; then
    printf '  [ OK ]  registry conflict refused: %s\n' "$label"
  else
    printf '  [FAIL]  registry conflict was not refused: %s (exit %s): %s\n' "$label" "$code" "$output"
    FAILURES=$((FAILURES + 1))
  fi
  rm -rf "$temporary"
}

assert_registry_conflict_cases() {
  run_registry_conflict_case "duplicate route alias" "EXEC_DUP" \
    "appears more than once in .director/routes.yaml" \
    $'routes:\n  EXEC_DUP:\n    vendor: openai\n  EXEC_DUP:\n    vendor: google'
  run_registry_conflict_case "duplicate vendor key" "EXEC_VENDOR_DUP" \
    "has more than one vendor key" \
    $'routes:\n  EXEC_VENDOR_DUP:\n    vendor: openai\n    vendor: google'
  run_registry_conflict_case "duplicate workflow route ID" "WORKFLOW_DUP" \
    "appears more than once in .telemetry/routing-policy.yaml" \
    $'routes:\n  EXEC_STRONG:\n    vendor: openai' \
    $'route_ids:\n  WORKFLOW_DUP:\n    orchestrator: ORCH_PRIMARY\n    executor: EXEC_STRONG\n  WORKFLOW_DUP:\n    orchestrator: ORCH_PRIMARY\n    executor: EXEC_STRONG'
  run_registry_conflict_case "route ID collision" "route-collision" \
    "collides between" \
    $'routes:\n  route-collision:\n    vendor: openai' \
    $'route_ids:\n  route-collision:\n    orchestrator: ORCH_PRIMARY\n    executor: EXEC_STRONG'
  run_registry_conflict_case "missing workflow orchestrator" "WORKFLOW_NO_ORCH" \
    "must declare exactly one orchestrator alias" \
    $'routes:\n  EXEC_STRONG:\n    vendor: openai' \
    $'route_ids:\n  WORKFLOW_NO_ORCH:\n    executor: EXEC_STRONG'
  run_registry_conflict_case "duplicate workflow orchestrator" "WORKFLOW_DUP_ORCH" \
    "must declare exactly one orchestrator alias" \
    $'routes:\n  EXEC_STRONG:\n    vendor: openai' \
    $'route_ids:\n  WORKFLOW_DUP_ORCH:\n    orchestrator: ORCH_PRIMARY\n    orchestrator: ORCH_FALLBACK\n    executor: EXEC_STRONG'
  run_registry_conflict_case "empty workflow orchestrator" "WORKFLOW_EMPTY_ORCH" \
    "invalid orchestrator alias" \
    $'routes:\n  EXEC_STRONG:\n    vendor: openai' \
    $'route_ids:\n  WORKFLOW_EMPTY_ORCH:\n    orchestrator:\n    executor: EXEC_STRONG'
}

echo "hook selftest"
echo
echo "block-dangerous-bash — must refuse"
expect_block "push to main"           block-dangerous-bash.sh "$(bash_cmd 'git push origin main')"
expect_block "force push"             block-dangerous-bash.sh "$(bash_cmd 'git push --force origin task/x')"
expect_block "reset --hard"           block-dangerous-bash.sh "$(bash_cmd 'git reset --hard HEAD~3')"
expect_block "immediate pr merge"     block-dangerous-bash.sh "$(bash_cmd 'gh pr merge 4 --squash')"
# Replaces an expect_allow. Auto-merge is off; a silent revert of that removal
# fails here rather than being noticed after a pull request merges itself.
expect_block "ARM auto-merge"         block-dangerous-bash.sh "$(bash_cmd 'gh pr merge 4 --auto --squash')"
expect_block "self-approve"           block-dangerous-bash.sh "$(bash_cmd 'gh pr review 4 --approve')"
expect_block "API key in command"     block-dangerous-bash.sh "$(bash_cmd 'OPENAI_API_KEY=sk-x codex exec "hi"')"
expect_block "agent with no timeout"  block-dangerous-bash.sh "$(bash_cmd 'agy -p "do the thing"')"
expect_block "agy without jail"       block-dangerous-bash.sh "$(bash_cmd 'timeout 900 agy -p --print-timeout 15m "do it"')"
expect_block "codex without jail"     block-dangerous-bash.sh "$(bash_cmd 'timeout 900 codex exec --sandbox workspace-write "do it"')"
expect_block "claude bare"             block-dangerous-bash.sh "$(bash_cmd 'timeout 900 claude --bare -p "do it"')"

echo
echo "block-dangerous-bash — must permit"
expect_allow "push a task branch"     block-dangerous-bash.sh "$(bash_cmd 'git push -u origin task/demo')"
expect_allow "agent with timeout"     block-dangerous-bash.sh "$(bash_cmd 'timeout 900 scripts/exec-jail.sh agy -p --print-timeout 15m "do it"')"
expect_allow "codex through jail"     block-dangerous-bash.sh "$(bash_cmd 'timeout 900 scripts/exec-jail.sh codex exec --sandbox workspace-write "do it"')"
expect_allow "claude without jail"    block-dangerous-bash.sh "$(bash_cmd 'timeout 900 claude -p "do it"')"
expect_allow "cheap introspection"    block-dangerous-bash.sh "$(bash_cmd 'agy models')"
expect_allow "ordinary status"        block-dangerous-bash.sh "$(bash_cmd 'git status --short')"
expect_allow "executor prose in commit message" block-dangerous-bash.sh \
  '{"tool_input":{"command":"git commit -m \"ran codex exec through exec-jail.sh with a timeout\"","description":"Record the completed change"}}'
expect_allow "ordinary git bare repo" block-dangerous-bash.sh "$(bash_cmd 'git init --bare /tmp/x.git')"

echo
echo "block-secret-read — must refuse"
expect_block ".env"                   block-secret-read.sh "$(file_path '/repo/.env')"
expect_block ".env.production"        block-secret-read.sh "$(file_path '/repo/.env.production')"
expect_block "private key"            block-secret-read.sh "$(file_path '/repo/deploy.pem')"
expect_block "inside secrets/"        block-secret-read.sh "$(file_path '/repo/secrets/db.txt')"
echo "block-secret-read — must permit"
expect_allow "ordinary source file"   block-secret-read.sh "$(file_path '/repo/scripts/preflight.sh')"

echo
echo "block-out-of-scope-write — vault"
expect_block "vault 04_Memory"        block-out-of-scope-write.sh "$(file_path 'C:\Users\dorot\Documents\Obsidian Vaults\Antigravity\04_Memory\x.md')"
expect_block "vault global/"          block-out-of-scope-write.sh "$(file_path 'C:\Users\dorot\Documents\Obsidian Vaults\Antigravity\global\wiki\overview.md')"
expect_allow "vault 01_Inbox"         block-out-of-scope-write.sh "$(file_path 'C:\Users\dorot\Documents\Obsidian Vaults\Antigravity\01_Inbox\handoff.md')"

echo
echo "active-worktree lifecycle and hooks"
rm -f "$ACTIVE_FILE" "$HANDOFF_FILE"
HOOK_PATH="$ABSENT_PATH"
expect_allow "no unit in flight exits 0 without a handoff" require-handoff.sh '{}'
ACTIVE_ROOT="$ROOT/.selftest-active-worktree"
printf '%s\n' "$ACTIVE_ROOT" > "$ACTIVE_FILE"
expect_block "outside active worktree" block-out-of-scope-write.sh "$(file_path "$ROOT/outside-active-worktree.txt")"
expect_allow "inside active worktree"  block-out-of-scope-write.sh "$(file_path "$ACTIVE_ROOT/inside.txt")"
rm -f "$HANDOFF_FILE"
expect_block "missing handoff in active cycle" require-handoff.sh '{}'

echo
echo "require-handoff — missing validator fails closed"
HOOK_PATH="$ABSENT_PATH"
printf '%s\n' "$VALID_HANDOFF" > "$HANDOFF_FILE"
expect_block_message "missing validator tells operator how to install it" require-handoff.sh '{}' \
  "Install it with: pipx install check-jsonschema"
printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.capacity_state = "Z"')" > "$HANDOFF_FILE"
expect_block "missing validator blocks malformed handoff too" require-handoff.sh '{}'

echo
echo "require-handoff Layer 2 — validator present path"
run_layer2_cases "validator present" "$PRESENT_PATH"
assert_producer_workflow_route
assert_vendorless_registry_route
assert_registry_conflict_cases
assert_direct_registry_semantics

HOOK_PATH="$ABSENT_PATH"
printf '%s\n' "$VALID_HANDOFF" > "$HANDOFF_FILE"
expect_block "valid handoff remains blocked until validator is installed" require-handoff.sh '{}'
if assert_worktree_active_file; then
  printf '  [ OK ]  worktree create writes active-worktree and owned remove deletes it\n'
else
  printf '  [FAIL]  worktree lifecycle did not maintain active-worktree\n'
  FAILURES=$((FAILURES + 1))
fi

echo
echo "KNOWN BYPASS — asserted, not hidden (§15.1 declared weakness)"
bypass_code=0
printf '%s' "$(bash_cmd 'git -C /repo push origin main')" \
  | bash "$HOOKS/block-dangerous-bash.sh" >/dev/null 2>&1 || bypass_code=$?
if [ "$bypass_code" -eq 2 ]; then
  printf '  [ OK ]  git -C form also blocked (better than documented)\n'
else
  printf '  [ !! ]  git -C /repo push origin main is NOT blocked — the documented\n'
  printf '          bypass. The GitHub ruleset is the real barrier. Not a failure.\n'
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "SELFTEST FAILED — $FAILURES assertion(s) wrong."
  exit 1
fi
echo "SELFTEST PASSED — every hook refuses and permits as specified."
exit 0
