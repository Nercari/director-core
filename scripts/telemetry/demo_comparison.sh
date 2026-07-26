#!/usr/bin/env sh
set -eu

# shellcheck disable=SC1003
# shellcheck disable=SC1007
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1003
# shellcheck disable=SC1007
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

interpreter=''
for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 &&
        "$candidate" -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
        interpreter=$candidate
        break
    fi
done
if [ -z "$interpreter" ]; then
    printf '%s\n' 'error: no Python 3 interpreter found (searched: python3, python, py)' >&2
    exit 1
fi

example_dir="$project_root/.telemetry/example"
ledger="$example_dir/invocations.jsonl"
summary="$example_dir/workflow-summary.json"
decisions="$example_dir/routing-decisions.jsonl"
policy="$project_root/.telemetry/routing-policy.yaml"

"$interpreter" "$script_dir/seed_example.py" --output-dir "$example_dir" --seed 20260725
"$interpreter" "$script_dir/reduce.py" --input "$ledger" --output-dir "$example_dir"
"$interpreter" "$script_dir/route_advisor.py" \
    --task-class bounded-code-change --complexity-band medium \
    --work-unit-id EXAMPLE-COMPARISON --summary "$summary" --policy "$policy" \
    --decision-log "$decisions" --seed 0 >/dev/null

"$interpreter" - "$ledger" "$summary" "$decisions" <<'PY'
import json
import sys
from pathlib import Path

ledger_path, summary_path, decisions_path = map(Path, sys.argv[1:])
ledger = [json.loads(line) for line in ledger_path.read_text(encoding="utf-8").splitlines() if line.strip()]
summary = json.loads(summary_path.read_text(encoding="utf-8"))
decisions = [json.loads(line) for line in decisions_path.read_text(encoding="utf-8").splitlines() if line.strip()]

assert ledger and all(row.get("project_id") == "EXAMPLE-SYNTHETIC" and row.get("synthetic") is True for row in ledger)
card = next(card for card in summary["scorecards"] if card["task_class"] == "bounded-code-change" and card["complexity_band"] == "medium")
metrics = {route["route_id"]: route for route in card["routes"]}
labels = {"A": "batch-primary", "B": "interactive-primary"}

def attempts(route_id):
    return sum(1 for row in ledger if row.get("route_id") == route_id)

def show(label):
    route_id = labels[label]
    route = metrics[route_id]
    total = sum(row["total_tokens"] for row in ledger if row.get("route_id") == route_id)
    count = attempts(route_id)
    print(f"Route {label} ({route_id}):")
    print(f"  attempts={count}; total_tokens={total}; tokens_per_attempt={total / count:.2f}")
    print(f"  completed_runs={route['completed_runs']}; validated_successes={route['validated_success_rate'] * route['completed_runs']:.0f}; retry_rate={route['retry_rate']:.0%}")
    print(f"  tokens_per_validated_success={route['tokens_per_validated_success']:.2f}")

print("SYNTHETIC EXAMPLE ONLY — not provider telemetry and not evidence about real routes.")
print("Comparison scope: same task_class=bounded-code-change, complexity_band=medium, validation_standard=example-check.")
show("A")
show("B")

a, b = metrics[labels["A"]], metrics[labels["B"]]
a_per_attempt = sum(row["total_tokens"] for row in ledger if row.get("route_id") == labels["A"]) / attempts(labels["A"])
b_per_attempt = sum(row["total_tokens"] for row in ledger if row.get("route_id") == labels["B"]) / attempts(labels["B"])
decision = decisions[-1]
assert a_per_attempt < b_per_attempt
assert b["tokens_per_validated_success"] < a["tokens_per_validated_success"]
assert decision["recommended_route"] == labels["B"]
print("Result: Route A is cheaper per attempt, but Route B wins on tokens_per_validated_success.")
print(f"Advisory recommendation: Route B ({decision['recommended_route']}); {decision['reason']}")
print("The demonstration writes only under .telemetry/example/; the real ledger is not an input or output.")
PY
