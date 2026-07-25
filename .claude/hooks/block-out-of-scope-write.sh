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

# Normalise to forward slashes so Windows and POSIX forms compare alike.
norm="$(printf '%s' "$path" | tr '\\' '/')"
vault_norm="$(printf '%s' "$VAULT_WIN" | tr '\\' '/')"

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
  active="$(tr -d '\r\n' < "$ROOT/.director/active-worktree" | tr '\\' '/')"
  if [ -n "$active" ]; then
    case "$norm" in
    "$active"/*) exit 0 ;;
    *) deny "write outside the active worktree ($active) — proposed: $norm" ;;
    esac
  fi
fi

exit 0
