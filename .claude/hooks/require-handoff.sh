#!/usr/bin/env bash
# Stop hook. Exit 2 blocks the cycle from ending. Blueprint §15.1.
# No cycle ends without a handoff that validates against the schema.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HANDOFF="$ROOT/.director/current-handoff.json"

# Only enforce when a unit is actually in flight. Ending an ordinary
# conversation is not a cycle.
[ -f "$ROOT/.director/active-worktree" ] || exit 0

if [ ! -f "$HANDOFF" ]; then
  echo "DENIED by require-handoff: a unit is in flight but there is no handoff at" >&2
  echo "  $HANDOFF" >&2
  echo "Publish one before ending the cycle (§15.1)." >&2
  exit 2
fi

if ! jq empty "$HANDOFF" 2>/dev/null; then
  echo "DENIED by require-handoff: current-handoff.json is not valid JSON." >&2
  exit 2
fi

SCHEMA="$ROOT/schemas/handoff.schema.json"

if command -v check-jsonschema >/dev/null 2>&1; then
  if ! check-jsonschema --schemafile "$SCHEMA" "$HANDOFF" >/dev/null 2>&1; then
    echo "DENIED by require-handoff: handoff violates schemas/handoff.schema.json" >&2
    check-jsonschema --schemafile "$SCHEMA" "$HANDOFF" 2>&1 | head -5 >&2
    exit 2
  fi
  exit 0
fi

# --- the validator is absent -------------------------------------------------
#
# What this branch used to do was nothing. `jq empty` above had already passed,
# so `{}` ended a cycle, and every field the schema declares required was
# unenforced in practice on the one machine where cycles actually end. A gate
# that stops checking when a tool is missing is not degraded, it is off.
#
# The sibling result validator handles this correctly: it announces the
# degradation and enforces the gate-critical invariants directly. This does the
# same. It is deliberately NOT a hard block on the missing tool — making the
# gate's correctness depend on an install step relocates the fragility instead
# of removing it, and would stop every cycle on this machine including the one
# shipping this change.
#
# Every invariant below is read out of the schema at run time rather than
# restated here. A hand-copied list is a second source of truth that drifts
# silently, and the drift would surface as a gate permitting what the schema
# forbids — the exact failure being fixed.
if [ ! -f "$SCHEMA" ]; then
  echo "DENIED by require-handoff: no validator, and no schema at $SCHEMA." >&2
  echo "There is nothing left to enforce the handoff contract with." >&2
  exit 2
fi

echo "require-handoff: check-jsonschema is NOT installed, so this handoff is not" >&2
echo "  validated against the full schema. Enforcing directly, from $SCHEMA:" >&2
echo "  its required fields, the capacity_state enumeration, repository_state's" >&2
echo "  own required fields, and non-empty text where the schema demands it." >&2
echo "  NOT checked on this path: item shape inside decisions_taken and the" >&2
echo "  arrays, additionalProperties, and string formats." >&2

deny() {
  echo "DENIED by require-handoff: $1" >&2
  echo "(enforced directly — check-jsonschema is not installed)" >&2
  exit 2
}

# jq on this platform ends its output lines with CRLF, so every value read from
# the schema arrives carrying a trailing carriage return and matches nothing.
# The behavior check's first run refused a valid handoff for a missing
# published_at that was present. strip_cr is why that does not happen.
strip_cr() { tr -d '\015'; }

while read -r field; do
  [ -n "$field" ] || continue
  jq -e --arg f "$field" 'has($f) and (.[$f] != null)' "$HANDOFF" >/dev/null 2>&1 \
    || deny "handoff is missing required field: $field"
done < <(jq -r '.required[]?' "$SCHEMA" | strip_cr)

while read -r field; do
  [ -n "$field" ] || continue
  jq -e --arg f "$field" '.repository_state | (type == "object") and has($f) and (.[$f] != null)' \
    "$HANDOFF" >/dev/null 2>&1 \
    || deny "handoff is missing required field: repository_state.$field"
done < <(jq -r '.properties.repository_state.required[]?' "$SCHEMA" | strip_cr)

# The schema marks these minLength 1. A field present but empty satisfies a
# has() check while saying nothing — the same hole the result validator closed
# for a blocked result's unresolved risks.
while read -r field; do
  [ -n "$field" ] || continue
  jq -e --arg f "$field" '(.[$f] | type == "string") and ((.[$f] | length) > 0)' \
    "$HANDOFF" >/dev/null 2>&1 \
    || deny "required field $field must be a non-empty string"
done < <(jq -r '.properties | to_entries[]
                | select(.value.type == "string" and .value.minLength == 1)
                | .key' "$SCHEMA" | strip_cr)

allowed_states="$(jq -r '.properties.capacity_state.enum | join(" ")' "$SCHEMA" | strip_cr)"
state="$(jq -r '.capacity_state // ""' "$HANDOFF" | strip_cr)"
case " $allowed_states " in
*" $state "*) : ;;
*) deny "capacity_state=${state:-<missing>} is not one of: $allowed_states" ;;
esac

exit 0
