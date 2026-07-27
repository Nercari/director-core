#!/usr/bin/env bash
# worktree — create or destroy the one worktree a unit is allowed.
# Blueprint §15.2, §16, §17. Usage:
#   worktree.sh create <unit-id>
#   worktree.sh remove <unit-id>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_NAME="$(basename "$ROOT")"
LOCK="$ROOT/.director/worktree.lock"
ACTIVE_WORKTREE="$ROOT/.director/active-worktree"
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
WT="$(cd "$ROOT/.." && pwd)/$REPO_NAME-$UNIT"

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
  # The directory is the atomic lock; its owner file binds that lock to this
  # unit so another unit's cleanup cannot release a live writer.
  printf '%s\n' "$UNIT" > "$LOCK/unit_id" || {
    rmdir "$LOCK"
    echo "could not record worktree lock owner" >&2
    exit 1
  }

  base="$(git -C "$ROOT" rev-parse main)"

  if ! git -C "$ROOT" worktree add -b "$BRANCH" "$WT" main; then
    rm -f "$LOCK/unit_id"
    rmdir "$LOCK"
    echo "worktree creation failed" >&2
    exit 1
  fi

  # Recovery point: an empty commit you can always reset back to.
  git -C "$WT" commit --allow-empty -q -m "checkpoint before $UNIT"

  # The hooks use this path to make the in-flight unit observable. It must be
  # written by the lifecycle command, not fabricated by a test or a caller.
  if ! printf '%s\n' "$WT" > "$ACTIVE_WORKTREE"; then
    git -C "$ROOT" worktree remove "$WT" --force >/dev/null 2>&1 || true
    rm -f "$LOCK/unit_id"
    rmdir "$LOCK" 2>/dev/null || true
    echo "could not record active worktree" >&2
    exit 1
  fi

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
  if [ -d "$LOCK" ]; then
    lock_owner="$(cat "$LOCK/unit_id" 2>/dev/null || true)"
    if [ "$lock_owner" = "$UNIT" ]; then
      rm -f "$LOCK/unit_id"
      if rmdir "$LOCK"; then
        rm -f "$ACTIVE_WORKTREE"
        echo "lock released"
      fi
    else
      echo "worktree lock belongs to ${lock_owner:-an unknown unit}; not released for $UNIT" >&2
    fi
  fi
  ;;

*) usage ;;
esac
