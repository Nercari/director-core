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

if command -v check-jsonschema >/dev/null 2>&1; then
  if ! check-jsonschema --schemafile "$ROOT/schemas/handoff.schema.json" "$HANDOFF" >/dev/null 2>&1; then
    echo "DENIED by require-handoff: handoff violates schemas/handoff.schema.json" >&2
    check-jsonschema --schemafile "$ROOT/schemas/handoff.schema.json" "$HANDOFF" 2>&1 | head -5 >&2
    exit 2
  fi
fi

exit 0
