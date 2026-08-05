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

# Structural rules the degraded path did not read until now: unknown keys where
# the schema forbids them, item shape inside decisions_taken, array item types,
# string patterns, and the date-time format. Each was measurably refused with
# check-jsonschema installed and permitted without it, so the gate was wider on
# the operator's machine than in CI — the same shape as the fail-open this file
# already closed once, one layer down.
#
# Every parameter is read out of the schema, for the reason stated below: a
# hand-copied list is a second source of truth that drifts silently. The one
# hand-written thing is the RFC 3339 shape, because the schema says "date-time"
# and does not spell out what that means. It is deliberately conservative —
# .claude/hooks/selftest.sh compares this path's verdicts against the real
# validator's on a shared corpus, so a shape this accepts and the validator
# refuses, or the reverse, fails the suite rather than passing quietly.
schema_structural_violations() {
  jq -n -r --slurpfile schema "$SCHEMA" --slurpfile document "$HANDOFF" '
    def unknown_keys($spec; $obj; $what):
      if ($spec.additionalProperties == false) and (($obj | type) == "object")
      then (($obj | keys) - ($spec.properties // {} | keys))[]
           | "\($what) has a field the schema does not declare: \(.)"
      else empty end;

    # Deep item shape is handled by array_of_objects, so object arrays are left
    # to it rather than reported twice for one defect.
    def item_types($props; $obj; $prefix):
      if ($obj | type) != "object" then empty
      else $props | to_entries[] as $p
        | select($p.value.type == "array")
        | select(($p.value.items.type // "object") != "object")
        | select(($obj[$p.key] | type) == "array")
        | ($obj[$p.key] | to_entries[]) as $e
        | select(($e.value | type) != $p.value.items.type)
        | "\($prefix)\($p.key)[\($e.key)] must be a \($p.value.items.type), found \($e.value | type)"
      end;

    def patterns($props; $obj; $prefix):
      if ($obj | type) != "object" then empty
      else $props | to_entries[] as $p
        | select($p.value.pattern != null)
        | select($obj | has($p.key))
        | ($obj[$p.key]) as $v
        | if ($v | type) != "string"
          then "\($prefix)\($p.key) must be a string, found \($v | type)"
          elif ($v | test($p.value.pattern)) then empty
          else "\($prefix)\($p.key) must match \($p.value.pattern) — found \($v | tojson)"
          end
      end;

    def date_times($props; $obj; $prefix):
      if ($obj | type) != "object" then empty
      else $props | to_entries[] as $p
        | select($p.value.format == "date-time")
        | select($obj | has($p.key))
        | ($obj[$p.key]) as $v
        | if ($v | type) != "string"
          then "\($prefix)\($p.key) must be a string, found \($v | type)"
          elif ($v | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$"))
          then empty
          else "\($prefix)\($p.key) must be an RFC 3339 date-time — the schema declares format: date-time — found \($v | tojson)"
          end
      end;

    def array_of_objects($spec; $arr; $at):
      if ($arr | type) != "array" then empty
      else ($arr | to_entries[]) as $e
        | ("\($at)[\($e.key)]") as $where
        | if ($e.value | type) != "object"
          then "\($where) must be an object, found \($e.value | type)"
          else
            # $required is bound before use: inside `$obj | has(.)` the dot is
            # rebound to $obj, so the field name is lost and jq fails with
            # "Cannot check whether object has a object key".
            ( ($spec.required // [])[] as $required
              | select(($e.value | has($required)) | not)
              | "\($where) is missing required field: \($required)" ),
            unknown_keys($spec; $e.value; $where),
            ( $spec.properties // {} | to_entries[] as $p
              | select($e.value | has($p.key))
              | ($e.value[$p.key]) as $v
              | ( if ($p.value.enum != null) and (($p.value.enum | index($v)) == null)
                  then "\($where).\($p.key)=\($v | tojson) is not one of: \($p.value.enum | join(", "))"
                  else empty end ),
                ( if ($p.value.type == "string") and (($v | type) != "string")
                  then "\($where).\($p.key) must be a string, found \($v | type)"
                  else empty end ),
                ( if ($p.value.type == "string") and (($v | type) == "string")
                     and (($v | length) < ($p.value.minLength // 0))
                  then "\($where).\($p.key) must be a non-empty string"
                  else empty end )
            )
          end
      end;

    ($schema[0]) as $s
    | ($document[0]) as $d
    | unknown_keys($s; $d; "handoff"),
      item_types($s.properties; $d; ""),
      patterns($s.properties; $d; ""),
      date_times($s.properties; $d; ""),
      ( ($s.properties.repository_state) as $r
        | unknown_keys($r; $d.repository_state; "repository_state"),
          item_types($r.properties; $d.repository_state; "repository_state."),
          patterns($r.properties; $d.repository_state; "repository_state."),
          date_times($r.properties; $d.repository_state; "repository_state.") ),
      ( ($s.properties.layer2) as $l
        | unknown_keys($l; $d.layer2; "layer2") ),
      ( ($s.properties.decisions_taken.items) as $i
        | if $i == null then empty
          else array_of_objects($i; $d.decisions_taken; "decisions_taken") end )
  '
}

# Same vendor on both sides of a review is not independent Layer 2. Stacked
# checks only multiply safety when they fail independently, so a reviewer from
# the executor's own vendor collapses the property the layer exists for.
#
# Honest self-review stays available: a cycle may declare it, end normally, and
# remain ineligible for auto-merge (which is off globally and denied by
# block-dangerous-bash.sh). What is refused is the undeclared case — two models
# from one vendor presented as an independent review. Declaring the flag makes
# that situation visible and costly; it does not make it independent, and it is
# not a cheaper path than using a reviewer from another vendor.
#
# Runs after enforce_layer2_record, so both vendors are already known to be in
# the schema's enumeration and self_review is already known to be a boolean.
enforce_layer2_independence() {
  local executor reviewer self_review run_id
  executor="$(jq -r '.layer2.executor_vendor // ""' "$HANDOFF" | strip_cr)"
  reviewer="$(jq -r '.layer2.reviewer_vendor // ""' "$HANDOFF" | strip_cr)"
  # Read directly, with no `// ""` alternative: jq's `//` fires on false as well
  # as null, so the alternative form turns self_review: false into an empty
  # string and this comparison would never match — the rule would be dead code
  # that reads as if it were enforcing something.
  self_review="$(jq -r '.layer2.self_review' "$HANDOFF" | strip_cr)"
  run_id="$(jq -r '.run_id // "<missing-run-id>"' "$HANDOFF" | strip_cr)"

  if [ "$executor" = "$reviewer" ] && [ "$self_review" = "false" ]; then
    deny "same-vendor review cannot end cycle run_id=$run_id;\
 executor_vendor=$executor; reviewer_vendor=$reviewer;\
 declare layer2.self_review=true or use a reviewer from a different vendor"
  fi
}

enforce_layer2_record
enforce_layer2_independence

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
echo "  It also checks the structural rules below, which this path used to skip:" >&2
echo "  unknown top-level, repository_state and layer2 keys, decisions_taken item" >&2
echo "  shape, array item types, string patterns, and the date-time format." >&2
echo "  Those five were measured permitted here and refused with the validator" >&2
echo "  installed; .claude/hooks/selftest.sh now compares both paths' verdicts on" >&2
echo "  a shared corpus, so a new divergence fails the suite." >&2
echo "  NOT checked on this path: union types such as [string, null], numeric" >&2
echo "  minimums, and additionalProperties inside workflow_efficiency." >&2

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

# A jq program that cannot be evaluated must block, not pass. Silently
# returning no violations because the checker itself broke is the fail-open
# this whole branch exists to have stopped doing.
if ! structural_violations="$(schema_structural_violations 2>&1)"; then
  echo "DENIED by require-handoff: the schema's structural rules could not be" >&2
  echo "  evaluated directly, so this handoff is unchecked rather than valid:" >&2
  printf '%s\n' "$structural_violations" | head -5 | sed 's/^/  /' >&2
  exit 2
fi
if [ -n "$structural_violations" ]; then
  printf '%s\n' "$structural_violations" | strip_cr | while IFS= read -r violation; do
    [ -n "$violation" ] && echo "DENIED by require-handoff: $violation" >&2
  done
  echo "(enforced directly — check-jsonschema is not installed)" >&2
  exit 2
fi
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
