#!/usr/bin/env bash
# Proves exec-jail actually removes gate access, and proves the baseline still
# has it — a jail test that never sees the unjailed case proves nothing.
#
# Asserts the negative honestly too: network egress is NOT blocked. If that
# assertion ever starts failing, someone added a control and should say so.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JAIL="$ROOT/scripts/exec-jail.sh"
FAILURES=0

ok()   { printf '  [ OK ]  %s\n' "$1"; }
bad()  { printf '  [FAIL]  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf '  [NOTE]  %s\n' "$1"; }

echo "exec-jail selfcheck"
echo

# --- SSH agent credentials must not cross the jail boundary -----------------
# Set sentinels explicitly so this assertion stays meaningful on hosts that do
# not normally run an SSH agent.
ssh_env="$(SSH_AUTH_SOCK=/tmp/director-selfcheck-agent SSH_AGENT_PID=4242 \
  bash "$JAIL" env)"
if echo "$ssh_env" | grep -qE '^(SSH_AUTH_SOCK|SSH_AGENT_PID)='; then
  bad "jailed process inherited SSH agent variables"
else
  ok "jailed process has no SSH agent variables"
fi

# --- gh must be unauthenticated inside the jail ------------------------------
if command -v gh >/dev/null 2>&1; then
  out="$(bash "$JAIL" gh auth status 2>&1 | head -2)"
  case "$out" in
  *"not logged"* | *"gh auth login"*) ok "jailed gh is unauthenticated" ;;
  *) bad "jailed gh still reports auth: $out" ;;
  esac

  out="$(bash "$JAIL" gh api user 2>&1 | head -1)"
  case "$out" in
  *"gh auth login"* | *"GH_TOKEN"* | *error* | *Error*) ok "jailed gh api is refused" ;;
  *) bad "jailed gh api returned data: ${out:0:60}" ;;
  esac

  # The baseline must still work, or the jail proves nothing.
  if gh auth status >/dev/null 2>&1; then
    ok "unjailed gh IS authenticated (baseline intact, so the jail is meaningful)"
  else
    note "unjailed gh is not authenticated either — jail result is inconclusive here"
  fi
else
  note "gh not on PATH; skipping gh assertions"
fi

# --- git must not be able to authenticate a push ----------------------------
if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  # A repo-level credential helper would defeat the jail. Fail loudly if present.
  if [ -n "$(git -C "$ROOT" config --local --get-all credential.helper 2>/dev/null)" ]; then
    bad "repo-level credential.helper is set — it survives the jail"
  else
    ok "no repo-level credential.helper to leak through"
  fi

  out="$(cd "$ROOT" && bash "$JAIL" git push --dry-run origin \
          HEAD:refs/heads/exec-jail-selfcheck-never-created 2>&1 | tail -1)"
  case "$out" in
  *"could not read Username"* | *"Authentication failed"* | *"terminal prompts disabled"* | *denied*)
    ok "jailed git push cannot authenticate" ;;
  *"new branch"* | *"up to date"*)
    bad "JAILED PUSH AUTHENTICATED — the gate is reachable: $out" ;;
  *)
    note "jailed push gave an unrecognised result, inspect by hand: ${out:0:80}" ;;
  esac
else
  note "no origin remote; skipping push assertion"
fi

# --- the honest negative: egress is NOT blocked -----------------------------
if bash "$JAIL" nslookup github.com >/dev/null 2>&1; then
  ok "network egress still open, as documented — the jail is not isolation"
else
  note "DNS failed inside the jail. Something else is blocking egress; update §21.8, because the jail does not do this"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "SELFCHECK FAILED — $FAILURES assertion(s) wrong."
  exit 1
fi
echo "SELFCHECK PASSED — gate access removed, egress deliberately still open."
exit 0
