#!/usr/bin/env bash
# PreToolUse on Bash. Exit 2 denies the call. Blueprint §15.1.
#
# DECLARED WEAKNESS: this matches on command text, and text can be rewritten.
# `git -C <dir> push origin main` never contains the string "push origin main"
# in the position this looks for. These hooks are a barrier against a confused
# agent, not a determined one. The GitHub ruleset is what actually stops a push
# to main. Do not add cleverness here expecting it to close that gap.
set -uo pipefail

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

deny() {
  echo "DENIED by block-dangerous-bash: $1" >&2
  exit 2
}

# --- history rewriting -------------------------------------------------------
case "$cmd" in
*"push"*"--force"* | *"push"*"-f "*)
  deny "force-push. Prefer revert; never rewrite history (§9.7)." ;;
esac

case "$cmd" in
*"reset --hard"*)
  deny "reset --hard. Use 'git reset --soft HEAD~1' for an unpushed commit (§9.7)." ;;
esac

case "$cmd" in
*"push"*"--delete"* | *"push"*":"[a-z]* | *"branch -D"*)
  deny "branch deletion." ;;
esac

# --- pushing to main ---------------------------------------------------------
# Belt to GitHub's braces. The ruleset is the real barrier.
case "$cmd" in
*"push"*" main"* | *"push"*"HEAD:main"* | *"push"*":main"*)
  deny "push to main. Push task/<unit-id> and open a pull request (§16)." ;;
esac

# --- merging -----------------------------------------------------------------
# `gh pr merge --auto` ARMS GitHub auto-merge and must be allowed. Only an
# immediate merge is denied. Rev 10.1's hook blocked both and so blocked its
# own auto-merge design.
case "$cmd" in
*"gh pr merge"*)
  case "$cmd" in
  *"--auto"*) : ;;   # arming auto-merge — permitted (§9.4)
  *) deny "gh pr merge. Only the operator merges (§13.1). '--auto' is allowed." ;;
  esac
  ;;
esac

case "$cmd" in
*"git merge"* | *"gh pr review"*"--approve"*)
  deny "merging or self-approving. Only the operator merges." ;;
esac

# --- metered credentials -----------------------------------------------------
if printf '%s' "$cmd" | grep -qE '[A-Z0-9_]*API_KEY'; then
  deny "command carries a *_API_KEY. Subscription and OAuth auth only (§14)."
fi

# `claude --bare` requires ANTHROPIC_API_KEY and disables project discovery.
if printf '%s' "$cmd" | grep -qE '(^|[;&|()[:space:]])claude([[:space:]]|$)' \
  && printf '%s' "$cmd" | grep -qE '(^|[[:space:]])--bare([[:space:]]|$)'; then
  deny "claude --bare violates AGENTS.md rule 5 and disables hook and settings discovery."
fi

# --- unbounded agent calls ---------------------------------------------------
# A headless agent with no timeout is an open-ended spend.
# Match command structure here, not prose carried in quoted arguments. This is
# deliberately only quoted-span removal, not shell parsing.
match_cmd="$(printf '%s' "$cmd" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"

if printf '%s' "$match_cmd" | grep -qE '(^|[;&|()[:space:]])(agy|codex|claude)([[:space:]]|$)'; then
  case "$match_cmd" in
  *"--version"* | *"--help"* | *"login status"* | *"models"*) : ;;  # cheap introspection
  *)
    printf '%s' "$match_cmd" | grep -q 'timeout' \
      || deny "headless agent call with no timeout (§15.1)."
    if printf '%s' "$match_cmd" | grep -qE '(^|[;&|()[:space:]])(agy|codex)([[:space:]]|$)'; then
      case "$match_cmd" in
      *"exec-jail.sh"*) : ;;
      *) deny "headless executor call missing exec-jail.sh (AGENTS.md rule 2)." ;;
      esac
    fi
    ;;
  esac
fi

exit 0
