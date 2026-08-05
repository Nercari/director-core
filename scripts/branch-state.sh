#!/usr/bin/env sh
# branch-state — is a pull request's material content already on the base branch?
#
# The question a sequencing gate needs answered is "is this PR's content present
# on current main", and a three-dot diff does not answer it. `git diff
# base...head` answers "what changed on the head since the merge base", which
# stays non-empty after a squash merge, a rebase, or a superseding merge even
# when main already carries the same content or a strict superset of it. Reading
# that non-empty output as proof the work is unreachable is how a landed change
# gets re-blocked.
#
# So the three-dot signal is computed, printed, and given no authority. The
# status comes from comparing content: blob identity first, then a conservative
# two-dot line comparison, and `unknown` whenever neither can decide.
#
# Nothing here reaches the network. Refs must already be local — fetching them
# is the caller's job, and an unfetched ref is `unknown`, never "absent".
#
# Usage: branch-state.sh --base <ref> --head <ref> [--repo <dir>]
#                        [--pr-state open|closed|merged] [--] [<path> ...]
#        With no <path>, the claimed set is every path the head touched since
#        the merge base — the one thing three-dot output is good for.
# Exit:  0 superseded (or the PR is not open, so this cannot block),
#        1 BLOCKED_BRANCH_STATE, 2 UNKNOWN_BRANCH_SUPERSESSION,
#        3 the arguments themselves could not be used.
set -eu

repo="."
base=""
head=""
pr_state="open"

usage() {
    printf '%s\n' "usage: branch-state.sh --base <ref> --head <ref> [--repo <dir>]" >&2
    printf '%s\n' "                       [--pr-state open|closed|merged] [--] [<path> ...]" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --base) [ $# -ge 2 ] || { usage; exit 3; }; base="$2"; shift 2 ;;
        --head) [ $# -ge 2 ] || { usage; exit 3; }; head="$2"; shift 2 ;;
        --repo) [ $# -ge 2 ] || { usage; exit 3; }; repo="$2"; shift 2 ;;
        --pr-state) [ $# -ge 2 ] || { usage; exit 3; }; pr_state="$2"; shift 2 ;;
        --) shift; break ;;
        -*) usage; exit 3 ;;
        *) break ;;
    esac
done

if [ -z "$base" ] || [ -z "$head" ]; then
    usage
    exit 3
fi
case "$pr_state" in
    open | closed | merged) ;;
    *) printf 'branch-state: unknown --pr-state %s\n' "$pr_state" >&2; exit 3 ;;
esac

g() { git -C "$repo" "$@"; }

printf 'branch-state — base %s, head %s, pr_state %s\n' "$base" "$head" "$pr_state"

# An unresolvable ref is the fetch-was-rejected case. It is reported as unknown,
# never silently treated as "the content is not there".
unresolved=""
for ref in "$base" "$head"; do
    if ! g rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
        unresolved="${unresolved:+$unresolved, }$ref"
    fi
done
if [ -n "$unresolved" ]; then
    printf 'Three-dot proxy result: not computed — unresolvable ref(s): %s\n' "$unresolved"
    printf 'Content-level result: not computed\n'
    printf 'Status: UNKNOWN_BRANCH_SUPERSESSION (unresolvable ref(s): %s)\n' "$unresolved"
    exit 2
fi

# The three-dot signal. Printed for debugging and for the historical context it
# genuinely carries; it decides nothing below.
if ! three_dot=$(g diff --name-only "$base...$head" 2>/dev/null); then
    printf 'Three-dot proxy result: not computed — no merge base between %s and %s\n' "$base" "$head"
    printf 'Content-level result: not computed\n'
    printf 'Status: UNKNOWN_BRANCH_SUPERSESSION (no merge base)\n'
    exit 2
fi
three_dot_count=$(printf '%s' "$three_dot" | grep -c . || true)
if [ "$three_dot_count" -eq 0 ]; then
    printf 'Three-dot proxy result: empty — 0 path(s) changed on the head since the merge base\n'
else
    printf 'Three-dot proxy result: NON-EMPTY — %s path(s) changed on the head since the merge base\n' \
        "$three_dot_count"
fi

claimed=$*
if [ -z "$claimed" ]; then
    claimed="$three_dot"
else
    claimed=$(printf '%s\n' "$@")
fi

printf 'Content-level result:\n'
if [ -z "$claimed" ]; then
    printf '  (no claimed paths)\n'
    printf 'Status: SUPERSEDED (nothing claimed)\n'
    exit 0
fi

blocked=0
unknown=0

# Classify one path by content, never by ancestry.
classify() {
    path="$1"
    head_has=0
    base_has=0
    g cat-file -e "$head:$path" 2>/dev/null && head_has=1 || head_has=0
    g cat-file -e "$base:$path" 2>/dev/null && base_has=1 || base_has=0

    if [ "$head_has" -eq 0 ] && [ "$base_has" -eq 0 ]; then
        printf 'deleted_landed'
        return 0
    fi
    if [ "$head_has" -eq 0 ] && [ "$base_has" -eq 1 ]; then
        # The head removed it and the base still carries it. The head's content
        # for this path — its removal — is not present on the base.
        printf 'not_landed|deletion on the head has not landed on the base'
        return 0
    fi
    if [ "$head_has" -eq 1 ] && [ "$base_has" -eq 0 ]; then
        printf 'not_landed|present on the head, absent from the base'
        return 0
    fi

    head_blob=$(g rev-parse "$head:$path" 2>/dev/null || echo "")
    base_blob=$(g rev-parse "$base:$path" 2>/dev/null || echo "")
    if [ -z "$head_blob" ] || [ -z "$base_blob" ]; then
        printf 'unknown|object for this path could not be resolved'
        return 0
    fi
    if [ "$head_blob" = "$base_blob" ]; then
        printf 'landed_exact'
        return 0
    fi

    # Blobs differ. A binary difference cannot be compared line by line, and
    # guessing at one would be exactly the overreach this script exists to undo.
    numstat=$(g diff --numstat "$base" "$head" -- "$path" 2>/dev/null || echo "")
    case "$numstat" in
        "-	-	"*) printf 'unknown|binary difference, not line-comparable'; return 0 ;;
    esac

    # Two-dot, base against head: "+" lines are head-only content the base lacks,
    # "-" lines are base-only content the head lacks.
    counts=$(g diff "$base" "$head" -- "$path" 2>/dev/null | awk '
        /^\+\+\+/ { next }
        /^---/    { next }
        /^\+/     { added++ }
        /^-/      { removed++ }
        END       { printf "%d %d", added + 0, removed + 0 }
    ')
    added=${counts% *}
    removed=${counts#* }
    if [ "$added" -eq 0 ] && [ "$removed" -gt 0 ]; then
        printf 'main_superset|base carries %s line(s) the head does not; no head-only lines' "$removed"
        return 0
    fi
    if [ "$added" -gt 0 ]; then
        printf 'not_landed|%s head-only line(s) absent from the base' "$added"
        return 0
    fi
    printf 'unknown|content differs but no line difference was produced'
}

# Classified once, into a file, then printed and tallied from that. A pipeline
# would put the loop in a subshell and lose the tallies, and re-running the
# classifier for the tally would let the report and the status disagree.
verdicts=$(mktemp)
trap 'rm -f "$verdicts"' EXIT INT TERM
printf '%s\n' "$claimed" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\t%s\n' "$(classify "$path")" "$path"
done > "$verdicts"

while IFS= read -r line; do
    [ -n "$line" ] || continue
    verdict=${line%%	*}
    path=${line#*	}
    label=${verdict%%|*}
    detail=""
    case "$verdict" in
        *"|"*) detail=" — ${verdict#*|}" ;;
    esac
    printf '  %-15s %s%s\n' "$label" "$path" "$detail"
    case "$label" in
        not_landed) blocked=$((blocked + 1)) ;;
        unknown) unknown=$((unknown + 1)) ;;
    esac
done < "$verdicts"

if [ "$pr_state" != "open" ]; then
    printf 'Status: CONTEXT_ONLY_PR_NOT_OPEN — the pull request is %s; a stale branch does not block sequencing\n' \
        "$pr_state"
    exit 0
fi
if [ "$blocked" -gt 0 ]; then
    printf 'Status: BLOCKED_BRANCH_STATE — %s claimed path(s) not landed on the base\n' "$blocked"
    exit 1
fi
if [ "$unknown" -gt 0 ]; then
    printf 'Status: UNKNOWN_BRANCH_SUPERSESSION — %s claimed path(s) could not be classified safely\n' \
        "$unknown"
    exit 2
fi
printf 'Status: SUPERSEDED — every claimed path is landed, superseded, or deleted on the base\n'
exit 0
