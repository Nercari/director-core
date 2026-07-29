#!/usr/bin/env bash
# Operator-visible behavior check for structure-aware command matching.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-dangerous-bash.sh"
FAILURES=0

check() {
  local expected="$1" command="$2" payload code verdict
  payload="$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$command" | jq -Rs .)")"
  printf 'command: %s\n' "$command"
  printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
  code=$?
  if [ "$code" -eq 0 ]; then
    verdict="ALLOWED"
  elif [ "$code" -eq 2 ]; then
    verdict="DENIED"
  else
    verdict="ERROR (exit $code)"
  fi
  printf 'verdict: %s\n\n' "$verdict"
  if [ "$verdict" != "$expected" ]; then
    FAILURES=$((FAILURES + 1))
  fi
}

check ALLOWED 'git commit -m "ran codex exec through exec-jail.sh with a timeout"'
check DENIED 'timeout 900 codex exec --sandbox workspace-write "do it"'
check DENIED 'timeout 900 claude --bare -p "do it"'
check ALLOWED 'git init --bare /tmp/x.git'
check DENIED 'bash -c "OPENAI_API_KEY=sk-x codex exec hi"'
check DENIED "bash -c 'ANTHROPIC_API_KEY=sk-x claude -p hi'"
check DENIED 'eval "git push origin main"'
check ALLOWED 'git init --bare /repos/claude'
check ALLOWED 'git init --bare /srv/claude'
check ALLOWED 'timeout 900 scripts/exec-jail.sh codex exec --sandbox workspace-write "do it"'
check ALLOWED 'git commit -m "ran codex exec via exec-jail.sh with a timeout"'

if [ "$FAILURES" -ne 0 ]; then
  printf 'command matching demo failed: %s wrong verdict(s)\n' "$FAILURES" >&2
  exit 1
fi
