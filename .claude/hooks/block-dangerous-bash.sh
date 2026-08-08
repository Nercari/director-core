#!/usr/bin/env bash
# PreToolUse on Bash. Exit 2 denies the call. Blueprint §15.1.
#
# DECLARED WEAKNESS: this matches on command text, and text can be rewritten.
# The git rules below match ORDERED, PER-SEGMENT text — git, then the verb, then
# the protected ref, inside one command segment — rather than unordered
# substrings anywhere in the line. Ordering is what lets a read-only
# `git log --grep push main` through while still refusing
# `bash -c "git push origin main"`, whose payload is just text in one segment.
# It is still text matching. It is still evadable: a git-level option outside
# the small allow list below is read as a subcommand and lets a push through,
# and a nested or escaped quote inside an argument is not modelled. These hooks
# are a barrier against a confused agent, not a determined one. The GitHub
# ruleset is what actually stops a push to main. Do not add a shell parser here
# expecting it to close that gap.
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

# --- git command matching ----------------------------------------------------
# The unordered globs these replaced denied any line containing "push" and
# " main" anywhere, in any order. That refused read-only work — `git merge-base`,
# `git log --grep push main`, and prose in an echo before an unrelated `git log`
# — while still missing `git push origin refs/heads/main`, quoted refs, and
# `git -C . merge`. Both directions were measured before this change.
#
# sq/dq keep the bracket expressions readable; embedding raw quotes in these
# strings is what makes this class of pattern unreviewable.
sq="'"
dq='"'

# One shell "word": bare characters and quoted spans, concatenated. This is what
# makes -c core.sshCommand="ssh -i key" one argument rather than two.
atom="([^[:space:]${sq}${dq}]|${sq}[^${sq}]*${sq}|${dq}[^${dq}]*${dq})"
arg="${atom}+"

# git-level options permitted BEFORE the subcommand. Deliberately a short list:
# every addition widens what may sit between "git" and the verb. Anything not
# here is read as the subcommand, so the rule stops rather than over-reaching.
opt="(-C[[:space:]]*${arg}|-c[[:space:]]*${arg}"
opt="${opt}|--git-dir(=|[[:space:]]+)${arg}"
opt="${opt}|--work-tree(=|[[:space:]]+)${arg}"
opt="${opt}|--no-pager|--paginate)[[:space:]]+"

# "git" as a command word. The leading class allows a path prefix so
# /usr/bin/git is covered, while still rejecting "legit" and "-git".
gverb="(^|[^A-Za-z0-9_-])git[[:space:]]+(${opt})*"

# main as a whole ref token: optionally quoted, optional leading +, optional
# <src>: refspec source, optional refs/heads/ prefix. The trailing boundary is
# what keeps a branch called "mainline" out of this.
ref="[[:space:]][${sq}${dq}]?[+]?([^[:space:]${sq}${dq}]*:)?(refs/heads/)?main[${sq}${dq}]?([[:space:]]|\$)"

re_push_main="${gverb}push([[:space:]]|\$).*${ref}"
re_delete="${gverb}push([[:space:]]|\$).*([[:space:]](--delete|-d|-D)([[:space:]]|\$)|[[:space:]][${sq}${dq}]?:[A-Za-z0-9_/.-]+)"
re_merge="${gverb}merge([^A-Za-z0-9_-]|\$)"

# Split on shell separators and let grep do the per-line matching it already
# does. An earlier version of this used `while read` over the same text and was
# wrong in the most dangerous possible way: sed does not append a trailing
# newline, `read` returns non-zero on an unterminated final line, so the loop
# body never ran and every rule below became dead code. grep has no such edge,
# and there is no loop left to get wrong.
git_match() {
  printf '%s' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g' | grep -qE "$1"
}

# push-to-main is tested before deletion so a colon refspec to main is named for
# what it is. The old order reported `git push origin :main` as a branch
# deletion, which denied correctly and explained wrongly.
if git_match "$re_push_main"; then
  deny "push to main. Push task/<unit-id> and open a pull request (§16)."
fi

if git_match "$re_delete"; then
  deny "branch deletion."
fi

case "$cmd" in
*"branch -D"*)
  deny "branch deletion." ;;
esac

# --- merging -----------------------------------------------------------------
# Auto-merge was removed, so `--auto` is no longer an exception. Arming it and
# merging immediately are the same denial: only the operator merges.
case "$cmd" in
*"gh pr merge"*)
  deny "gh pr merge. Only the operator merges (§13.1). Auto-merge is off — '--auto' is denied too." ;;
esac

# `git merge` uses the same command model as push, so `git -C . merge` is caught
# — the old adjacent-string glob missed it. The word boundary after "merge" is
# what lets the read-only merge-base, merge-tree and merge-file through.
if git_match "$re_merge"; then
  deny "merging. Only the operator merges."
fi

case "$cmd" in
*"gh pr review"*"--approve"*)
  deny "self-approving. Only the operator merges." ;;
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
