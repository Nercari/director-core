#!/usr/bin/env bash
# PreToolUse on Write/Edit. Exit 2 denies the call. Blueprint §15.1.
# Two invariants: no writes outside the active worktree, and the vault is
# writable only at 01_Inbox/.
set -uo pipefail

VAULT="/c/Users/dorot/Documents/Obsidian Vaults/Antigravity"
VAULT_WIN='C:\Users\dorot\Documents\Obsidian Vaults\Antigravity'

payload="$(cat)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"
[ -z "$path" ] && exit 0

deny() {
  echo "DENIED by block-out-of-scope-write: $1" >&2
  exit 2
}

# Normalise to forward slashes so Windows and POSIX forms compare alike, AND
# fold the drive-letter form so C:/Users/... compares equal to /c/Users/...
#
# The slash half alone was not enough and the gap was load-bearing:
# worktree.sh computes the worktree path in Git Bash, so .director/active-worktree
# holds /c/Users/..., while the harness proposing the write supplies C:/Users/...
# The case match below could therefore never succeed, and EVERY write was denied
# while a unit was in flight — including writes inside the worktree this hook
# exists to permit. It failed closed, so nothing unsafe got through; it also
# meant the allow path had never once executed.
norm_path() {
  local p drive
  # shellcheck disable=SC1003
  p="$(printf '%s' "$1" | tr '\\' '/')"
  case "$p" in
  [A-Za-z]:/*)
    drive="$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')"
    p="/$drive/${p#*:/}"
    ;;
  esac
  printf '%s' "$p"
}

norm="$(norm_path "$path")"
vault_norm="$(norm_path "$VAULT_WIN")"

# --- the vault ---------------------------------------------------------------
case "$norm" in
"$vault_norm"/* | "$VAULT"/*)
  rel="${norm#*Obsidian Vaults/Antigravity/}"
  case "$rel" in
  01_Inbox/*) exit 0 ;;
  *) deny "vault is read-only outside 01_Inbox/ — proposed: $rel (AI-SHARED.md)" ;;
  esac
  ;;
esac

# --- the active worktree -----------------------------------------------------
# When a unit is running, .director/active-worktree names the only writable root.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -n "$ROOT" ] && [ -f "$ROOT/.director/active-worktree" ]; then
  active="$(norm_path "$(tr -d '\r\n' < "$ROOT/.director/active-worktree")")"
  if [ -n "$active" ]; then
    case "$norm" in
    "$active"/*) exit 0 ;;
    *) deny "write outside the active worktree ($active) — proposed: $norm" ;;
    esac
  fi
fi

exit 0
