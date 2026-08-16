#!/usr/bin/env bash
# PreToolUse on Read. Exit 2 denies the call. Blueprint §15.1.
set -uo pipefail

payload="$(cat)"
path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null)"
[ -z "$path" ] && exit 0

base="$(basename "$path")"
# shellcheck disable=SC1003
norm="$(printf '%s' "$path" | tr '\\' '/')"

deny() {
  echo "DENIED by block-secret-read: $1" >&2
  exit 2
}

case "$base" in
.env | .env.*) deny "reading $base (§15.1)" ;;
*.key | *.pem) deny "reading a key file: $base" ;;
esac

case "$norm" in
*/secrets/*) deny "reading inside secrets/ (§15.1)" ;;
esac

exit 0
