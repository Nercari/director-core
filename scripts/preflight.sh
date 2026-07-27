#!/usr/bin/env bash
# preflight — refuses to launch unless every mechanically checkable control holds.
# Blueprint §14, §7.2. Exit 0 = green. Any non-zero = do not start work.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTES="$ROOT/.director/routes.yaml"
TODAY_EPOCH="$(date +%s)"
FAIL=0
WARN=0

pass() { printf '  [ OK ]  %s\n' "$1"; }
fail() { printf '  [FAIL]  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  [WARN]  %s\n' "$1"; WARN=$((WARN + 1)); }

# field <key> <<< "$block"
# Pulls a scalar out of a routes.yaml block. Strips the trailing "# comment"
# and surrounding whitespace — routes.yaml is heavily commented, and without
# this a value like "absent  # absent | candidate | active" never compares equal
# to "absent".
field() {
  sed -n "s/^ *$1: *//p" \
    | head -1 \
    | sed 's/[[:space:]]*#.*$//' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

echo "preflight — $(date '+%Y-%m-%d %H:%M')"
echo
echo "session scope"

# The hooks in .claude/settings.json only intercept tool calls for a Claude
# Code session actually rooted here. A session opened one directory up (the
# parent workspace) can write anywhere in this repo, or to the vault outside
# 01_Inbox/, with nothing firing — found by hand on 2026-07-25 when two
# probe writes that should have been blocked both succeeded silently.
# "The orchestrator will cd into the right place" is exactly the bottom-tier
# instruction §7.2 already refuses to rely on elsewhere in this file.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  cpd_real="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd || echo "$CLAUDE_PROJECT_DIR")"
  if [ "$cpd_real" = "$ROOT" ]; then
    pass "CLAUDE_PROJECT_DIR matches repo root — hooks are live for this session"
  else
    fail "CLAUDE_PROJECT_DIR ($cpd_real) does not match repo root ($ROOT) — hooks in .claude/settings.json will not fire for this session's tool calls. Open Claude Code with $ROOT as the project directory."
  fi
else
  warn "CLAUDE_PROJECT_DIR is unset — cannot confirm the hooks are wired to this session"
fi

echo
echo "no-overage controls (§14)"

# A metered credential anywhere in the environment is a hard stop. The whole
# no-overage guarantee is this check plus the hook that mirrors it.
leaked="$(env | grep -oE '^[A-Z0-9_]*API_KEY' || true)"
if [ -n "$leaked" ]; then
  fail "metered credential in environment: $(echo "$leaked" | tr '\n' ' ')"
else
  pass "no *_API_KEY in environment"
fi

if command -v codex >/dev/null 2>&1; then
  if codex login status 2>&1 | grep -qi "chatgpt"; then
    pass "codex authenticated by subscription"
  else
    fail "codex auth is not subscription-based (or status unreadable)"
  fi
else
  fail "codex not on PATH"
fi

for bin in claude agy gh git; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "$bin present"
  else
    fail "$bin not on PATH"
  fi
done

# gate.yml cannot be pushed without this scope. Cheaper to catch here than at push.
if gh auth status >/dev/null 2>&1; then
  scopes="$(gh api -i user 2>/dev/null | grep -i '^X-Oauth-Scopes:' || true)"
  if echo "$scopes" | grep -q 'workflow'; then
    pass "gh token carries workflow scope"
  else
    fail "gh token lacks workflow scope — run: gh auth refresh -h github.com -s workflow"
  fi
else
  fail "gh not authenticated"
fi

echo
echo "registry (§7.2)"

if [ ! -f "$ROUTES" ]; then
  fail "routes.yaml missing at $ROUTES"
else
  pass "routes.yaml present"

  # An unresolved alias means the routing interview never happened. Refuse —
  # this is the mechanical backstop that turns "should ask" into "cannot start".
  for alias in ORCH_PRIMARY ORCH_FALLBACK EXEC_PRIMARY EXEC_STRONG EXEC_LOCAL; do
    block="$(awk -v a="$alias:" '
      $0 ~ "^  "a"$" {f=1; next}
      f && /^  [A-Z_]+:$/ {exit}
      f {print}
    ' "$ROUTES")"

    if [ -z "$block" ]; then
      fail "$alias missing from routes.yaml"
      continue
    fi

    model="$(echo "$block" | field model)"
    if [ -z "$model" ] || echo "$model" | grep -q '<.*>'; then
      fail "$alias has no resolved model"
    fi

    forbidden_models="$(echo "$block" | awk '
      /^    forbidden_models:/ { in_forbidden=1; next }
      in_forbidden && /^    [a-zA-Z_][a-zA-Z0-9_]*:/ { exit }
      in_forbidden { sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); gsub("\"", ""); print }
    ')"
    while IFS= read -r forbidden_pattern; do
      [ -z "$forbidden_pattern" ] && continue
      # Glob matching is the point: a vendor wildcard pattern must match that
      # vendor's concrete model identifiers. Quoting the expansion makes the
      # comparison literal and the check would never fire. The directive belongs
      # in front of the whole case, not a branch (SC1124).
      # shellcheck disable=SC2254
      case "$model" in
        $forbidden_pattern)
          fail "$alias model $model matches forbidden_models pattern $forbidden_pattern"
          ;;
      esac
    done <<< "$forbidden_models"

    if [ "$alias" = "EXEC_LOCAL" ]; then
      state="$(echo "$block" | field state)"
      case "$state" in
        absent | candidate | active) pass "EXEC_LOCAL state: $state" ;;
        *) fail "EXEC_LOCAL state invalid or missing (got: '${state:-<empty>}')" ;;
      esac
    fi

    lv="$(echo "$block" | field last_verified)"
    if [ -z "$lv" ]; then
      fail "$alias has no last_verified"
    else
      lv_epoch="$(date -d "$lv" +%s 2>/dev/null || echo 0)"
      if [ "$lv_epoch" -eq 0 ]; then
        fail "$alias last_verified unparseable: $lv"
      else
        if [ "$lv_epoch" -gt "$TODAY_EPOCH" ]; then
          fail "$alias last_verified is in the future: $lv"
        else
          age_days=$(((TODAY_EPOCH - lv_epoch) / 86400))
        if [ "$age_days" -gt 180 ]; then
          fail "$alias last_verified is ${age_days}d old (>180) — re-run the routing interview"
        elif [ "$age_days" -gt 90 ]; then
          warn "$alias last_verified is ${age_days}d old (>90)"
        fi
        fi
      fi
    fi
  done
  [ "$FAIL" -eq 0 ] && pass "every alias resolved, dated, and fresh"
fi

echo
echo "repository"

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "inside a git work tree"
  branch="$(git -C "$ROOT" branch --show-current)"
  if [ "$branch" = "main" ]; then
    pass "on main (work happens in a worktree on task/<unit-id>)"
  else
    warn "on branch '$branch', not main"
  fi
else
  fail "not a git repository"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "RED — $FAIL failure(s), $WARN warning(s). Do not start work."
  exit 1
fi
echo "GREEN — 0 failures, $WARN warning(s)."
exit 0
