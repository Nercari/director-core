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
  printf '%s' "$json" | bash "$HOOKS/$hook" >/dev/null 2>&1
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
  printf '%s' "$json" | bash "$HOOKS/$hook" >/dev/null 2>&1
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

echo "hook selftest"
echo
echo "block-dangerous-bash — must refuse"
expect_block "push to main"           block-dangerous-bash.sh "$(bash_cmd 'git push origin main')"
expect_block "force push"             block-dangerous-bash.sh "$(bash_cmd 'git push --force origin task/x')"
expect_block "reset --hard"           block-dangerous-bash.sh "$(bash_cmd 'git reset --hard HEAD~3')"
expect_block "immediate pr merge"     block-dangerous-bash.sh "$(bash_cmd 'gh pr merge 4 --squash')"
expect_block "self-approve"           block-dangerous-bash.sh "$(bash_cmd 'gh pr review 4 --approve')"
expect_block "API key in command"     block-dangerous-bash.sh "$(bash_cmd 'OPENAI_API_KEY=sk-x codex exec "hi"')"
expect_block "agent with no timeout"  block-dangerous-bash.sh "$(bash_cmd 'agy -p "do the thing"')"
expect_block "agy without jail"       block-dangerous-bash.sh "$(bash_cmd 'timeout 900 agy -p --print-timeout 15m "do it"')"
expect_block "codex without jail"     block-dangerous-bash.sh "$(bash_cmd 'timeout 900 codex exec --sandbox workspace-write "do it"')"
expect_block "claude bare"             block-dangerous-bash.sh "$(bash_cmd 'timeout 900 claude --bare -p "do it"')"

echo
echo "block-dangerous-bash — must permit"
expect_allow "push a task branch"     block-dangerous-bash.sh "$(bash_cmd 'git push -u origin task/demo')"
expect_allow "ARM auto-merge"         block-dangerous-bash.sh "$(bash_cmd 'gh pr merge 4 --auto --squash')"
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
ACTIVE_ROOT="$ROOT/.selftest-active-worktree"
printf '%s\n' "$ACTIVE_ROOT" > "$ACTIVE_FILE"
expect_block "outside active worktree" block-out-of-scope-write.sh "$(file_path "$ROOT/outside-active-worktree.txt")"
expect_allow "inside active worktree"  block-out-of-scope-write.sh "$(file_path "$ACTIVE_ROOT/inside.txt")"
rm -f "$HANDOFF_FILE"
expect_block "missing handoff in active cycle" require-handoff.sh '{}'
printf '%s\n' '{"published_at":"2026-07-27T00:00:00Z","run_id":"selftest","capacity_state":"A","objective":"exercise the hook","repository_state":{"main_commit":"0123456","open_branches":[],"open_pull_requests":[]},"decisions_taken":[],"next_action":"stop"}' > "$HANDOFF_FILE"
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
