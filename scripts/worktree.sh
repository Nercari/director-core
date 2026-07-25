#!/usr/bin/env bash
# worktree — create or destroy the one worktree a unit is allowed.
# Blueprint §15.2, §16, §17. Usage:
#   worktree.sh create <unit-id>
#   worktree.sh remove <unit-id>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_NAME="$(basename "$ROOT")"
LOCK="$ROOT/.director/worktree.lock"
ACTION="${1:-}"
UNIT="${2:-}"

usage() {
  echo "usage: worktree.sh {create|remove} <unit-id>" >&2
  exit 2
}
if [ -z "$ACTION" ] || [ -z "$UNIT" ]; then
  usage
fi
echo "$UNIT" | grep -qE '^[a-z0-9][a-z0-9-]*$' \
  || { echo "unit-id must be kebab-case: $UNIT" >&2; exit 2; }

BRANCH="task/$UNIT"
WT="$ROOT/../$REPO_NAME-$UNIT"

case "$ACTION" in
create)
  # flock is unavailable on this platform (Git Bash / Cygwin). mkdir is atomic
  # on every filesystem and fails if the directory exists — a second concurrent
  # create fails loudly instead of racing. §15.2.
  mkdir "$LOCK" 2>/dev/null || {
    echo "another unit holds the worktree lock: $LOCK" >&2
    echo "if no unit is running, a worktree was orphaned — remove the lock by hand." >&2
    exit 1
  }

  base="$(git -C "$ROOT" rev-parse main)"

  if ! git -C "$ROOT" worktree add -b "$BRANCH" "$WT" main; then
    rmdir "$LOCK"
    echo "worktree creation failed" >&2
    exit 1
  fi

  # Recovery point: an empty commit you can always reset back to.
  git -C "$WT" commit --allow-empty -q -m "checkpoint before $UNIT"

  mkdir -p "$ROOT/.director/runs/$UNIT"
  {
    echo "unit_id: $UNIT"
    echo "branch: $BRANCH"
    echo "base_commit: $base"
    echo "worktree: $WT"
    echo "created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$ROOT/.director/runs/$UNIT/worktree.yaml"

  echo "worktree:    $WT"
  echo "branch:      $BRANCH"
  echo "base_commit: $base"
  echo "lock held.   release with: worktree.sh remove $UNIT"
  ;;

remove)
  if [ -d "$WT" ]; then
    git -C "$ROOT" worktree remove "$WT" --force || {
      echo "could not remove worktree $WT" >&2
      exit 1
    }
    echo "removed worktree $WT"
  else
    echo "no worktree at $WT (nothing to remove)"
  fi
  git -C "$ROOT" worktree prune
  [ -d "$LOCK" ] && rmdir "$LOCK" && echo "lock released"
  ;;

*) usage ;;
esac
