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

# Exercise both require-handoff branches even when check-jsonschema is absent
# locally or installed by CI. The stub only selects the branch; the hook still
# performs the Layer 2 checks itself.
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

# The parity corpus needs a different present-path oracle from the one above.
# PRESENT_PATH is a stub that exits 0, which selects the validator-present
# branch but answers every question "valid" — useful for proving the branch is
# taken, useless for proving the two branches agree about what the schema says.
# Parity uses the unmodified PATH, so the present arm is the real validator.
REAL_PRESENT_PATH="$PATH"
PARITY_DIR="$HOOKS/fixtures/handoff-parity"

VALID_HANDOFF='{"published_at":"2026-07-27T00:00:00Z","run_id":"selftest","capacity_state":"A","objective":"exercise the hook","repository_state":{"main_commit":"0123456","open_branches":[],"open_pull_requests":[]},"decisions_taken":[],"next_action":"stop","layer2":{"executor_vendor":"openai","reviewer_vendor":"anthropic","self_review":true}}'

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

# expect_message <label> <hook> <json> <substring> ...
# Asserts the refusal AND what it says. A gate that blocks for an unreadable
# reason sends the operator to the source to find out what happened, so the
# wording is part of the contract, not decoration.
expect_message() {
  local label="$1" hook="$2" json="$3" code output missing=""
  shift 3
  output="$(printf '%s' "$json" | PATH="$HOOK_PATH" bash "$HOOKS/$hook" 2>&1)"
  code=$?
  if [ "$code" -ne 2 ]; then
    printf '  [FAIL]  NOT blocked (exit %s): %s\n' "$code" "$label"
    FAILURES=$((FAILURES + 1))
    return
  fi
  for expected in "$@"; do
    case "$output" in
      *"$expected"*) : ;;
      *) missing="${missing:+$missing, }$expected" ;;
    esac
  done
  if [ -n "$missing" ]; then
    printf '  [FAIL]  blocked but the message omitted: %s — %s\n' "$missing" "$label"
    FAILURES=$((FAILURES + 1))
  else
    printf '  [ OK ]  blocked, and said why: %s\n' "$label"
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

  # The three cases that carry the policy. Labels say what is allowed and what
  # is refused, so a reader of the output learns the rule without reading the
  # hook: same vendor is permitted only when the handoff declares self-review.
  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" \
    | jq '.layer2.reviewer_vendor = .layer2.executor_vendor | .layer2.self_review = true')" \
    > "$HANDOFF_FILE"
  expect_allow "$path_label: same vendor with self_review declared is allowed" \
    require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.layer2.self_review = false')" > "$HANDOFF_FILE"
  expect_allow "$path_label: different vendors without self_review is allowed" \
    require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" \
    | jq '.layer2.reviewer_vendor = .layer2.executor_vendor | .layer2.self_review = false')" \
    > "$HANDOFF_FILE"
  expect_block "$path_label: same vendor without self_review is refused" \
    require-handoff.sh '{}'
  expect_message "$path_label: refusal names the unit, both vendors, and the rule" \
    require-handoff.sh '{}' \
    'run_id=selftest' 'executor_vendor=openai' 'reviewer_vendor=openai' \
    'same-vendor review cannot end cycle' 'layer2.self_review=true'

  # Adjacent, and not what the same-vendor rule was written to catch: a route
  # whose declared vendor agrees with the executor must not launder a
  # same-vendor pair. Passing one check is not passing the other.
  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" \
    | jq '.layer2.reviewer_vendor = .layer2.executor_vendor
          | .layer2.self_review = false
          | .workflow_efficiency = {work_unit_route: "EXEC_STRONG"}')" > "$HANDOFF_FILE"
  expect_block "$path_label: agreeing route vendor does not excuse a same-vendor pair" \
    require-handoff.sh '{}'

  # Also adjacent: declaring self-review while the vendors differ is an honest
  # over-declaration, not a violation, and must keep ending the cycle.
  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.layer2.self_review = true')" > "$HANDOFF_FILE"
  expect_allow "$path_label: declared self_review with different vendors is allowed" \
    require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: null}')" > "$HANDOFF_FILE"
  expect_allow "$path_label: null work_unit_route skips lookup" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "EXEC_STRONG"}')" > "$HANDOFF_FILE"
  expect_allow "$path_label: route vendor agrees with executor vendor" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "ORCH_PRIMARY"}')" > "$HANDOFF_FILE"
  expect_block "$path_label: route vendor disagrees with executor vendor" require-handoff.sh '{}'

  printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.workflow_efficiency = {work_unit_route: "DIRECT"}')" > "$HANDOFF_FILE"
  expect_block "$path_label: route has no vendor key" require-handoff.sh '{}'
}

# parity_verdict <path> <fixture> — prints allow, block, or error(<code>).
# Deliberately reduces the hook to its only external behaviour. Comparing
# verdicts is the point; stderr wording differs between the two paths by design
# and comparing that would fail on cosmetics rather than on policy.
parity_verdict() {
  local path_value="$1" fixture="$2" code
  cp "$fixture" "$HANDOFF_FILE"
  printf '{}' | PATH="$path_value" bash "$HOOKS/require-handoff.sh" >/dev/null 2>&1
  code=$?
  case "$code" in
  0) printf 'allow' ;;
  2) printf 'block' ;;
  *) printf 'error(%s)' "$code" ;;
  esac
}

# One corpus, both paths, verdicts compared. The gate is only as strong as its
# weakest path, and until this ran nothing recomputed whether the degraded path
# had drifted wider than the validated one. It had.
#
# Two distinct failures are reported separately because they mean different
# things: the paths disagreeing is the defect this exists to catch, and the
# paths agreeing on the wrong answer means the corpus and the schema have
# parted company.
run_parity_corpus() {
  local fixture name expected present absent
  if [ ! -d "$PARITY_DIR" ]; then
    printf '  [FAIL]  parity corpus directory is missing: %s\n' "$PARITY_DIR"
    FAILURES=$((FAILURES + 1))
    return
  fi
  # The present arm must be the real validator. A skip is honest on a machine
  # without it, but silence in CI would let the whole suite lapse unnoticed —
  # and CI installs the validator before running this, so absence there is a
  # broken gate rather than a missing convenience.
  if ! command -v check-jsonschema >/dev/null 2>&1; then
    if [ -n "${CI:-}" ]; then
      printf '  [FAIL]  check-jsonschema is absent in CI, so the parity corpus cannot\n'
      printf '          be checked against a real validator. gate.yml installs it before\n'
      printf '          this step; if that changed, parity is no longer being enforced.\n'
      FAILURES=$((FAILURES + 1))
    else
      printf '  [SKIP]  check-jsonschema is not installed here, so the validator-present\n'
      printf '          oracle is unavailable. CI installs it and runs this suite there.\n'
    fi
    return
  fi

  printf '%s\n' "$ROOT/.selftest-active-worktree" > "$ACTIVE_FILE"
  for fixture in "$PARITY_DIR"/*.json; do
    [ -f "$fixture" ] || continue
    name="$(basename "$fixture")"
    case "$name" in
    valid-*) expected=allow ;;
    invalid-*) expected=block ;;
    *)
      printf '  [FAIL]  %s: a parity fixture must be named valid-* or invalid-*, so the\n' "$name"
      printf '          expected verdict is declared rather than inferred\n'
      FAILURES=$((FAILURES + 1))
      continue
      ;;
    esac
    present="$(parity_verdict "$REAL_PRESENT_PATH" "$fixture")"
    absent="$(parity_verdict "$ABSENT_PATH" "$fixture")"
    if [ "$present" != "$absent" ]; then
      printf '  [FAIL]  PATH DIVERGENCE %s — validator present: %s, validator absent: %s\n' \
        "$name" "$present" "$absent"
      FAILURES=$((FAILURES + 1))
    elif [ "$present" != "$expected" ]; then
      printf '  [FAIL]  both paths agree on the wrong verdict for %s — %s, expected %s\n' \
        "$name" "$present" "$expected"
      FAILURES=$((FAILURES + 1))
    else
      printf '  [ OK ]  %s — present: %s, absent: %s\n' "$name" "$present" "$absent"
    fi
  done
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
echo "require-handoff Layer 2 — validator absent fallback"
run_layer2_cases "validator absent" "$ABSENT_PATH"
HOOK_PATH="$ABSENT_PATH"
printf '%s\n' "$(printf '%s' "$VALID_HANDOFF" | jq '.capacity_state = "Z"')" > "$HANDOFF_FILE"
expect_block "bad capacity_state still blocked by fallback" require-handoff.sh '{}'

echo
echo "require-handoff Layer 2 — validator present path"
run_layer2_cases "validator present" "$PRESENT_PATH"

echo
echo "require-handoff validator-path parity — one corpus, both paths, verdicts compared"
run_parity_corpus

HOOK_PATH="$ABSENT_PATH"
printf '%s\n' "$VALID_HANDOFF" > "$HANDOFF_FILE"
expect_allow "valid handoff in active cycle" require-handoff.sh '{}'
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
