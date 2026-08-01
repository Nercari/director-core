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
ROUTES="$ROOT/.director/routes.yaml"

if [ ! -f "$SCHEMA" ]; then
  echo "DENIED by require-handoff: no validator, and no schema at $SCHEMA." >&2
  echo "There is nothing left to enforce the handoff contract with." >&2
  exit 2
fi

# jq on this platform ends its output lines with CRLF. Strip it from every
# value read from the schema or registry before comparing it.
strip_cr() { tr -d '\015'; }

validator_available=0
if command -v check-jsonschema >/dev/null 2>&1; then
  validator_available=1
fi

deny() {
  echo "DENIED by require-handoff: $1" >&2
  if [ "$validator_available" -eq 0 ]; then
    echo "(enforced directly — check-jsonschema is not installed)" >&2
  fi
  exit 2
}

enforce_layer2_record() {
  while read -r field; do
    [ -n "$field" ] || continue
    jq -e --arg f "$field" 'has($f) and (.[$f] != null)' "$HANDOFF" >/dev/null 2>&1 \
      || deny "handoff is missing required field: $field"
  done < <(jq -r '.required[]? | select(. == "layer2")' "$SCHEMA" | strip_cr)

  layer2_type="$(jq -r '.properties.layer2.type // ""' "$SCHEMA" | strip_cr)"
  if [ "$layer2_type" = "object" ]; then
    jq -e '.layer2 | type == "object"' "$HANDOFF" >/dev/null 2>&1 \
      || deny "handoff field layer2 must be an object"
  fi

  while read -r field; do
    [ -n "$field" ] || continue
    jq -e --arg f "$field" \
      '(.layer2 | (type == "object") and has($f) and (.[$f] != null))' \
      "$HANDOFF" >/dev/null 2>&1 \
      || deny "handoff is missing required field: layer2.$field"
  done < <(jq -r '.properties.layer2.required[]?' "$SCHEMA" | strip_cr)

  while read -r field; do
    [ -n "$field" ] || continue
    allowed="$(jq -r --arg f "$field" \
      '.properties.layer2.properties[$f].enum // [] | join(" ")' \
      "$SCHEMA" | strip_cr)"
    value="$(jq -r --arg f "$field" '.layer2[$f] // ""' "$HANDOFF" | strip_cr)"
    case " $allowed " in
      *" $value "*) : ;;
      *) deny "layer2.$field=${value:-<missing>} is not one of: $allowed" ;;
    esac
  done < <(jq -r '.properties.layer2.properties | to_entries[]
                | select(.value.enum != null)
                | .key' "$SCHEMA" | strip_cr)

  while read -r field; do
    [ -n "$field" ] || continue
    expected_type="$(jq -r --arg f "$field" \
      '.properties.layer2.properties[$f].type // ""' "$SCHEMA" | strip_cr)"
    case "$expected_type" in
      boolean)
        jq -e --arg f "$field" '.layer2[$f] | type == "boolean"' "$HANDOFF" \
          >/dev/null 2>&1 \
          || deny "layer2.$field must be a boolean"
        ;;
    esac
  done < <(jq -r '.properties.layer2.properties | to_entries[]
                | select(.value.type != null)
                | .key' "$SCHEMA" | strip_cr)
}

enforce_layer2_record

if command -v check-jsonschema >/dev/null 2>&1; then
  if ! check-jsonschema --schemafile "$SCHEMA" "$HANDOFF" >/dev/null 2>&1; then
    echo "DENIED by require-handoff: handoff violates schemas/handoff.schema.json" >&2
    check-jsonschema --schemafile "$SCHEMA" "$HANDOFF" 2>&1 | head -5 >&2
    exit 2
  fi
else

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
echo "require-handoff: check-jsonschema is NOT installed, so this handoff is not" >&2
echo "  validated against the full schema. Enforcing directly, from $SCHEMA:" >&2
echo "  its required fields, the capacity_state enumeration, repository_state's" >&2
echo "  own required fields, layer2's enum and boolean, and non-empty text where" >&2
echo "  the schema demands it." >&2
echo "  NOT checked on this path: item shape inside decisions_taken and the" >&2
echo "  arrays, additionalProperties, and string formats." >&2

# deny() and strip_cr() are defined once near the top of this file, where the
# Layer 2 checks that also need them run. They used to be declared here as well;
# the second pair silently shadowed the first and was one more place for the two
# to drift apart.

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
fi

if jq -e '(.workflow_efficiency | type == "object") and (.workflow_efficiency.work_unit_route? != null)' \
  "$HANDOFF" >/dev/null 2>&1; then
  route="$(jq -r '.workflow_efficiency.work_unit_route' "$HANDOFF" | strip_cr)"

  if [ ! -f "$ROUTES" ]; then
    deny "cannot look up route '$route': .director/routes.yaml is missing"
  fi

  route_block="$(strip_cr < "$ROUTES" | awk -v route="$route" '
    $0 == "  " route ":" { found=1; next }
    found && $0 ~ /^  [A-Za-z_][A-Za-z0-9_]*:/ { exit }
    found { print }
  ')"
  if [ -z "$route_block" ]; then
    deny "route '$route' is not declared in .director/routes.yaml and has no vendor key"
  fi

  route_vendor="$(printf '%s\n' "$route_block" \
    | sed -n 's/^    vendor:[[:space:]]*//p' \
    | head -1 \
    | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | strip_cr)"
  if [ -z "$route_vendor" ]; then
    deny "route '$route' has no vendor key in .director/routes.yaml"
  fi

  executor_vendor="$(jq -r '.layer2.executor_vendor // ""' "$HANDOFF" | strip_cr)"
  if [ "$route_vendor" != "$executor_vendor" ]; then
    deny "route '$route' declares vendor '$route_vendor', but layer2.executor_vendor is '$executor_vendor'"
  fi
fi

exit 0
