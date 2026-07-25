#!/usr/bin/env bash
# Proves the hooks refuse what they must and permit what they must.
# Run by CI (gate.yml) and by the operator during Phase 1 verification.
#
# A gate never seen refusing something is not a gate — so this asserts BOTH
# directions, and it deliberately asserts the known bypass too. A test suite
# that hides a weakness is worse than no test suite.
set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILURES=0

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

echo
echo "block-dangerous-bash — must permit"
expect_allow "push a task branch"     block-dangerous-bash.sh "$(bash_cmd 'git push -u origin task/demo')"
expect_allow "ARM auto-merge"         block-dangerous-bash.sh "$(bash_cmd 'gh pr merge 4 --auto --squash')"
expect_allow "agent with timeout"     block-dangerous-bash.sh "$(bash_cmd 'timeout 900 agy -p --print-timeout 15m "do it"')"
expect_allow "cheap introspection"    block-dangerous-bash.sh "$(bash_cmd 'agy models')"
expect_allow "ordinary status"        block-dangerous-bash.sh "$(bash_cmd 'git status --short')"

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
