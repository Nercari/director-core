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
ROUTING_POLICY="$ROOT/.telemetry/routing-policy.yaml"

if [ ! -f "$SCHEMA" ]; then
  echo "DENIED by require-handoff: no validator, and no schema at $SCHEMA." >&2
  echo "There is nothing left to enforce the handoff contract with." >&2
  exit 2
fi

# jq on this platform ends its output lines with CRLF. Strip it from every
# value read from the schema or registry before comparing it.
strip_cr() { tr -d '\015'; }

deny() {
  echo "DENIED by require-handoff: $1" >&2
  exit 2
}

if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "DENIED by require-handoff: check-jsonschema is not installed." >&2
  echo "Install it with: pipx install check-jsonschema" >&2
  echo "An active cycle cannot end until the handoff can be validated against $SCHEMA." >&2
  exit 2
fi

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

  executor_vendor="$(jq -r '.layer2.executor_vendor // ""' "$HANDOFF" | strip_cr)"
  reviewer_vendor="$(jq -r '.layer2.reviewer_vendor // ""' "$HANDOFF" | strip_cr)"
  self_review="$(jq -r '.layer2.self_review // ""' "$HANDOFF" | strip_cr)"
  if [ "$executor_vendor" = "$reviewer_vendor" ] && [ "$self_review" != "true" ]; then
    run_id="$(jq -r '.run_id // "<unknown>"' "$HANDOFF" | strip_cr)"
    deny "unit '$run_id' cannot end: Layer 2 executor_vendor='$executor_vendor' and reviewer_vendor='$reviewer_vendor' are the same; cross-vendor review is required unless layer2.self_review=true"
  fi
}

enforce_layer2_record

if ! check-jsonschema --schemafile "$SCHEMA" "$HANDOFF" >/dev/null 2>&1; then
  echo "DENIED by require-handoff: handoff violates schemas/handoff.schema.json" >&2
  check-jsonschema --schemafile "$SCHEMA" "$HANDOFF" 2>&1 | head -5 >&2
  exit 2
fi

if ! jq -e '(.workflow_efficiency | type == "object")
            and (.workflow_efficiency.work_unit_route? | type == "string")
            and ((.workflow_efficiency.work_unit_route? | length) > 0)' \
  "$HANDOFF" >/dev/null 2>&1; then
  deny "handoff must declare a non-empty workflow_efficiency.work_unit_route while a unit is in flight"
fi

route="$(jq -r '.workflow_efficiency.work_unit_route' "$HANDOFF" | strip_cr)"
case "$route" in
  *[!A-Za-z0-9_-]*|'')
    deny "workflow route '$route' contains unsupported characters"
    ;;
esac

if [ ! -f "$ROUTES" ]; then
  deny "cannot look up route '$route': .director/routes.yaml is missing"
fi

registry_block() {
  local registry="$1" alias="$2"
  strip_cr < "$registry" | awk -v alias="$alias" '
    $0 == "  " alias ":" { found=1; next }
    found && $0 ~ /^  [A-Za-z0-9_-]+:/ { exit }
    found { print }
  '
}

registry_alias_count() {
  local registry="$1" alias="$2"
  strip_cr < "$registry" | awk -v alias="$alias" '
    $0 == "  " alias ":" { count += 1 }
    END { print count + 0 }
  '
}

block_field_count() {
  local block="$1" field="$2"
  printf '%s\n' "$block" | awk -v field="$field" '
    $0 ~ ("^    " field ":[[:space:]]*") { count += 1 }
    END { print count + 0 }
  '
}

block_field_value() {
  local block="$1" field="$2"
  printf '%s\n' "$block" \
    | sed -n "s/^    ${field}:[[:space:]]*//p" \
    | head -1 \
    | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' \
    | strip_cr
}

route_alias="$route"
orchestrator_alias=""
workflow_block=""
workflow_alias_count=0
workflow_route=0
route_block="$(registry_block "$ROUTES" "$route")"
route_alias_count="$(registry_alias_count "$ROUTES" "$route")"
if [ "$route_alias_count" -gt 1 ]; then
  deny "route alias '$route' appears more than once in .director/routes.yaml"
fi

if [ -f "$ROUTING_POLICY" ]; then
  workflow_alias_count="$(registry_alias_count "$ROUTING_POLICY" "$route")"
  if [ "$workflow_alias_count" -gt 1 ]; then
    deny "workflow route '$route' appears more than once in .telemetry/routing-policy.yaml"
  fi
  workflow_block="$(registry_block "$ROUTING_POLICY" "$route")"
fi

if [ -n "$route_block" ] && [ -n "$workflow_block" ]; then
  deny "route '$route' collides between .director/routes.yaml and .telemetry/routing-policy.yaml"
fi

if [ -z "$route_block" ]; then
  if [ -z "$workflow_block" ]; then
    deny "workflow route '$route' is not declared in .telemetry/routing-policy.yaml"
  fi
  workflow_route=1

  executor_field_count="$(block_field_count "$workflow_block" executor)"
  if [ "$executor_field_count" -ne 1 ]; then
    deny "workflow route '$route' must declare exactly one executor alias"
  fi
  orchestrator_field_count="$(block_field_count "$workflow_block" orchestrator)"
  if [ "$orchestrator_field_count" -ne 1 ]; then
    deny "workflow route '$route' must declare exactly one orchestrator alias"
  fi
  escalation_field_count="$(block_field_count "$workflow_block" escalation_executor)"
  if [ "$escalation_field_count" -gt 0 ]; then
    deny "workflow route '$route' has multiple executor candidates; record the effective executor route explicitly"
  fi

  route_alias="$(block_field_value "$workflow_block" executor)"
  orchestrator_alias="$(block_field_value "$workflow_block" orchestrator)"
  case "$route_alias" in
    *[!A-Za-z0-9_-]*|'')
      deny "workflow route '$route' resolves to an invalid executor alias"
      ;;
  esac
  case "$orchestrator_alias" in
    ''|*[!A-Za-z0-9_-]*)
      deny "workflow route '$route' resolves to an invalid orchestrator alias"
      ;;
  esac
  route_alias_count="$(registry_alias_count "$ROUTES" "$route_alias")"
  if [ "$route_alias_count" -gt 1 ]; then
    deny "executor alias '$route_alias' appears more than once in .director/routes.yaml"
  fi
  route_block="$(registry_block "$ROUTES" "$route_alias")"
fi

if [ -z "$route_block" ] && { [ "$route_alias" != "DIRECT" ] || [ -z "$orchestrator_alias" ]; }; then
  deny "workflow route '$route' resolves to '$route_alias', which is not declared in .director/routes.yaml"
fi

route_vendor=""
if [ "$route_alias" != "DIRECT" ] && [ -n "$route_block" ]; then
  vendor_field_count="$(block_field_count "$route_block" vendor)"
  if [ "$vendor_field_count" -gt 1 ]; then
    deny "route alias '$route_alias' has more than one vendor key in .director/routes.yaml"
  fi
  if [ "$vendor_field_count" -eq 1 ]; then
    route_vendor="$(block_field_value "$route_block" vendor)"
  fi
fi

# DIRECT has no executor process of its own. The only supported direct workflow
# is the explicit direct-orchestrator policy entry, whose effective vendor is
# the declared orchestrator vendor and which must be recorded as self-review.
# A raw DIRECT registry alias is never an alternative declaration, and any
# vendor written on that alias is ignored rather than allowed to alter this
# policy-defined meaning.
if [ "$route_alias" = "DIRECT" ]; then
  if [ "$workflow_route" -ne 1 ] || [ -z "$orchestrator_alias" ]; then
    deny "workflow route '$route' resolves to DIRECT only through the explicit direct-orchestrator policy"
  fi
  self_review="$(jq -r '.layer2.self_review // ""' "$HANDOFF" | strip_cr)"
  if [ "$self_review" != "true" ]; then
    deny "workflow route '$route' resolves to DIRECT and requires layer2.self_review=true"
  fi
  orchestrator_alias_count="$(registry_alias_count "$ROUTES" "$orchestrator_alias")"
  if [ "$orchestrator_alias_count" -gt 1 ]; then
    deny "orchestrator alias '$orchestrator_alias' appears more than once in .director/routes.yaml"
  fi
  orchestrator_block="$(registry_block "$ROUTES" "$orchestrator_alias")"
  orchestrator_vendor_count="$(block_field_count "$orchestrator_block" vendor)"
  if [ "$orchestrator_vendor_count" -ne 1 ]; then
    deny "orchestrator alias '$orchestrator_alias' must declare exactly one vendor key"
  fi
  route_vendor="$(block_field_value "$orchestrator_block" vendor)"
fi

if [ -z "$route_vendor" ]; then
  deny "workflow route '$route' resolves to '$route_alias' but has no vendor key in .director/routes.yaml"
fi

executor_vendor="$(jq -r '.layer2.executor_vendor // ""' "$HANDOFF" | strip_cr)"
if [ "$route_vendor" != "$executor_vendor" ]; then
  deny "workflow route '$route' declares effective vendor '$route_vendor', but layer2.executor_vendor is '$executor_vendor'"
fi

exit 0
