#!/usr/bin/env bash
# worktree — create, resume, or destroy the one worktree a unit is allowed.
# Blueprint §15.2, §16, §17. Usage:
#   worktree.sh create <unit-id>    new branch task/<unit-id> from main
#   worktree.sh resume <unit-id>    existing branch task/<unit-id>
#   worktree.sh remove <unit-id>
#
# WHY resume EXISTS. `create` always branches fresh from main and cannot check
# out a branch that already exists, so adding a commit to an already-open pull
# request had no supported path. The workaround used five times on 2026-08-16
# was to `create` a throwaway unit, take its lock, and then `git checkout` the
# real branch inside that worktree. The lock invariant held, but the run record
# named a unit whose branch carried nothing, and four empty branches were left
# behind.
#
# The downstream cost was larger than the mess: because every correction round
# had to start a new branch from main, each one produced a pull request carrying
# re-applied copies of everything before it. Five pull requests were closed on
# 2026-08-16 as duplicates of one another for exactly this reason. That is what
# this action removes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_NAME="$(basename "$ROOT")"
LOCK="$ROOT/.director/worktree.lock"
ACTIVE_WORKTREE="$ROOT/.director/active-worktree"
ACTION="${1:-}"
UNIT="${2:-}"

usage() {
  echo "usage: worktree.sh {create|resume|remove} <unit-id>" >&2
  exit 2
}
if [ -z "$ACTION" ] || [ -z "$UNIT" ]; then
  usage
fi
echo "$UNIT" | grep -qE '^[a-z0-9][a-z0-9-]*$' \
  || { echo "unit-id must be kebab-case: $UNIT" >&2; exit 2; }

BRANCH="task/$UNIT"
WT="$(cd "$ROOT/.." && pwd)/$REPO_NAME-$UNIT"

branch_exists() {
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"
}

# Which worktree, if any, already has this branch checked out. git refuses to
# check out the same branch twice, and its own message does not name the unit,
# so this is resolved here to say something an operator can act on.
branch_checked_out_at() {
  git -C "$ROOT" worktree list --porcelain 2>/dev/null \
    | awk -v want="refs/heads/$BRANCH" '
        /^worktree /  { path = substr($0, 10) }
        /^branch /    { if (substr($0, 8) == want) { print path; exit } }'
}

# The lock, acquired identically by create and resume. VALIDATION HAPPENS BEFORE
# THIS IS CALLED, deliberately: a refusal that has already taken the lock leaves
# the lock stranded and the next unit blocked on a run that never started.
acquire_lock() {
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
}

release_lock_after_failure() {
  rm -f "$LOCK/unit_id"
  rmdir "$LOCK" 2>/dev/null || true
}

# The hooks read this path to make the in-flight unit observable. It must be
# written by the lifecycle command, not fabricated by a caller.
record_active_worktree() {
  if ! printf '%s\n' "$WT" > "$ACTIVE_WORKTREE"; then
    git -C "$ROOT" worktree remove "$WT" --force >/dev/null 2>&1 || true
    release_lock_after_failure
    echo "could not record active worktree" >&2
    exit 1
  fi
}

write_run_record() {
  mkdir -p "$ROOT/.director/runs/$UNIT"
  {
    echo "unit_id: $UNIT"
    echo "branch: $BRANCH"
    echo "base_commit: $1"
    echo "worktree: $WT"
    echo "$2: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$ROOT/.director/runs/$UNIT/worktree.yaml"
}

case "$ACTION" in
create)
  # Validated BEFORE the lock. The old code took the lock first and then let
  # `git worktree add -b` fail on an existing branch, with git's own message,
  # which said nothing about `resume`.
  if branch_exists; then
    echo "branch $BRANCH already exists." >&2
    echo "To add commits to it - an open pull request, a review correction - use:" >&2
    echo "  worktree.sh resume $UNIT" >&2
    echo "\`create\` only ever starts a NEW branch from main." >&2
    exit 1
  fi
  if [ -e "$WT" ]; then
    echo "a path already exists at $WT; remove it or pick another unit-id" >&2
    exit 1
  fi

  acquire_lock
  base="$(git -C "$ROOT" rev-parse main)"

  if ! git -C "$ROOT" worktree add -b "$BRANCH" "$WT" main; then
    release_lock_after_failure
    echo "worktree creation failed" >&2
    exit 1
  fi

  # Recovery point: an empty commit you can always reset back to.
  git -C "$WT" commit --allow-empty -q -m "checkpoint before $UNIT"

  record_active_worktree
  write_run_record "$base" "created"

  echo "worktree:    $WT"
  echo "branch:      $BRANCH"
  echo "base_commit: $base"
  echo "lock held.   release with: worktree.sh remove $UNIT"
  ;;

resume)
  # Same lock, same active-worktree record, same one-writer invariant. The only
  # difference from `create` is that the branch already exists and is checked
  # out rather than created - and that NO checkpoint commit is made, because an
  # empty commit on a branch with an open pull request is noise in someone
  # else's review.
  if ! branch_exists; then
    echo "branch $BRANCH does not exist." >&2
    echo "To start it: worktree.sh create $UNIT" >&2
    exit 1
  fi
  existing="$(branch_checked_out_at)"
  if [ -n "$existing" ]; then
    echo "branch $BRANCH is already checked out at:" >&2
    echo "  $existing" >&2
    echo "git allows a branch in one worktree at a time. Work there, or move that" >&2
    echo "worktree off the branch first. NOTE: if that path is the main repository," >&2
    echo "check whether anything external depends on it - a registered scheduled" >&2
    echo "task pinned to its scripts/ directory did on 2026-08-16." >&2
    exit 1
  fi
  if [ -e "$WT" ]; then
    echo "a path already exists at $WT; remove it first" >&2
    exit 1
  fi

  acquire_lock
  base="$(git -C "$ROOT" rev-parse "$BRANCH")"

  if ! git -C "$ROOT" worktree add "$WT" "$BRANCH"; then
    release_lock_after_failure
    echo "could not check out $BRANCH into a worktree" >&2
    exit 1
  fi

  record_active_worktree
  write_run_record "$base" "resumed"

  echo "worktree:    $WT"
  echo "branch:      $BRANCH  (resumed, not created)"
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
