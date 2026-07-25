#!/usr/bin/env python3
"""Reduce the invocation ledger into comparable metrics and route scorecards.

`total_tokens` is treated as the provider's inclusive total: cache-read and
cache-creation tokens are reported separately for diagnostics but are never
added to a non-null `total_tokens`.  When a record has no total, its available
input, output, and cache token fields are summed as a fallback total.

P95 uses inclusive linear interpolation: after sorting n samples, interpolate
between positions floor((n - 1) * 0.95) and ceil((n - 1) * 0.95).
"""

from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable


GROUP_FIELDS = (
    "task_class", "complexity_band", "validation_standard", "route_id",
    "execution_mode",
)
SCORECARD_FIELDS = ("task_class", "complexity_band")
TOKEN_FIELDS = (
    "input_tokens", "output_tokens", "cache_read_tokens",
    "cache_creation_tokens",
)


def json_line(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            text = raw.strip()
            if not text:
                continue
            try:
                value = json.loads(text)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error.msg}") from error
            if not isinstance(value, dict):
                raise ValueError(f"{path}:{line_number}: ledger record must be an object")
            records.append(value)
    return records


def non_negative_number(value: Any) -> int | float | None:
    if (isinstance(value, bool) or not isinstance(value, (int, float)) or
            not math.isfinite(value) or value < 0):
        return None
    return value


def record_total(record: dict[str, Any]) -> int | float | None:
    """Return the inclusive total without double-counting diagnostic caches."""
    total = non_negative_number(record.get("total_tokens"))
    if total is not None:
        return total
    parts = [non_negative_number(record.get(name)) for name in TOKEN_FIELDS]
    known = [part for part in parts if part is not None]
    return sum(known) if known else None


def sum_field(records: Iterable[dict[str, Any]], field: str) -> int | float:
    return sum(value for record in records
               if (value := non_negative_number(record.get(field))) is not None)


def percentile_95(samples: Iterable[int | float]) -> int | float | None:
    """Inclusive linear-interpolated p95; returns null for an empty sample."""
    ordered = sorted(samples)
    if not ordered:
        return None
    position = (len(ordered) - 1) * 0.95
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def median(samples: Iterable[int | float]) -> int | float | None:
    ordered = sorted(samples)
    if not ordered:
        return None
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def divide(numerator: int | float | None, denominator: int | float | None) -> int | float | None:
    if numerator is None or denominator is None or denominator == 0:
        return None
    return numerator / denominator


def group_key(record: dict[str, Any], fields: tuple[str, ...]) -> tuple[Any, ...]:
    return tuple(record.get(field) for field in fields)


def latest_outcome(records: list[dict[str, Any]]) -> dict[str, Any] | None:
    outcomes = [record for record in records
                if isinstance(record.get("completed"), bool) or
                isinstance(record.get("validation_passed"), bool)]
    return outcomes[-1] if outcomes else None


def has_retry(records: list[dict[str, Any]]) -> bool:
    attempts = {record.get("attempt_number") for record in records
                if isinstance(record.get("attempt_number"), int) and
                not isinstance(record.get("attempt_number"), bool)}
    return len(attempts) > 1


def aggregate(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate records whose comparison dimensions already match."""
    by_unit: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for index, record in enumerate(records):
        work_unit_id = record.get("work_unit_id")
        by_unit[str(work_unit_id) if work_unit_id is not None else f"__missing_{index}"].append(record)

    completed_runs = 0
    validated_success_count = 0
    first_pass_success_count = 0
    retry_count = 0
    escalation_count = 0
    human_intervention_count = 0
    for unit_records in by_unit.values():
        outcome = latest_outcome(unit_records)
        if outcome is None:
            continue
        completed_runs += 1
        retried = has_retry(unit_records)
        success = outcome.get("completed") is True and outcome.get("validation_passed") is True
        if success:
            validated_success_count += 1
            if not retried:
                first_pass_success_count += 1
        if retried:
            retry_count += 1
        if any(record.get("escalated") is True for record in unit_records):
            escalation_count += 1
        if any(record.get("human_intervention") is True for record in unit_records):
            human_intervention_count += 1

    total_tokens = sum(value for record in records if (value := record_total(record)) is not None)
    estimated_cost_values = [non_negative_number(record.get("estimated_cost")) for record in records]
    estimated_cost = (sum(value for value in estimated_cost_values if value is not None)
                      if records and all(value is not None for value in estimated_cost_values) else None)
    latencies = [value for record in records
                 if (value := non_negative_number(record.get("latency_ms"))) is not None]
    cache_read_tokens = sum_field(records, "cache_read_tokens")
    input_tokens = sum_field(records, "input_tokens")
    director_tokens = sum(record_total(record) or 0 for record in records
                          if record.get("role") == "director")
    handoff_overhead_tokens = sum(record_total(record) or 0 for record in records
                                  if record.get("role") == "auxiliary")

    return {
        "record_count": len(records),
        "work_unit_count": len(by_unit),
        "total_tokens": total_tokens,
        "input_tokens": input_tokens,
        "output_tokens": sum_field(records, "output_tokens"),
        "cache_read_tokens": cache_read_tokens,
        "cache_creation_tokens": sum_field(records, "cache_creation_tokens"),
        "estimated_cost": estimated_cost,
        "validated_success_count": validated_success_count,
        "completed_runs": completed_runs,
        "first_pass_success_rate": divide(first_pass_success_count, completed_runs),
        "validated_success_rate": divide(validated_success_count, completed_runs),
        "retry_rate": divide(retry_count, completed_runs),
        "escalation_rate": divide(escalation_count, completed_runs),
        "human_intervention_rate": divide(human_intervention_count, completed_runs),
        "median_latency_ms": median(latencies),
        "p95_latency_ms": percentile_95(latencies),
        "cache_hit_ratio": divide(cache_read_tokens, input_tokens),
        "director_overhead_ratio": divide(director_tokens, total_tokens),
        "handoff_overhead_tokens": handoff_overhead_tokens,
        "tokens_per_validated_success": divide(total_tokens, validated_success_count),
        "cost_per_validated_success": divide(estimated_cost, validated_success_count),
    }


def reduce_records(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[Any, ...], list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        grouped[group_key(record, GROUP_FIELDS)].append(record)
    result: list[dict[str, Any]] = []
    for key in sorted(grouped, key=lambda value: json.dumps(value, default=str)):
        item = dict(zip(GROUP_FIELDS, key))
        item.update(aggregate(grouped[key]))
        result.append(item)
    return result


def confidence(completed_runs: int) -> str:
    if completed_runs >= 30:
        return "high"
    if completed_runs >= 10:
        return "medium"
    return "low"


def sort_number(value: Any) -> float:
    return float(value) if isinstance(value, (int, float)) else math.inf


def recommended_route(routes: list[dict[str, Any]]) -> tuple[str | None, str | None]:
    eligible = [route for route in routes if route["completed_runs"] >= 10]
    if not eligible:
        return None, "No route has the required 10 completed runs."
    all_costs_known = all(route["cost_per_validated_success"] is not None for route in eligible)
    primary = "cost_per_validated_success" if all_costs_known else "tokens_per_validated_success"
    ordered = sorted(
        eligible,
        key=lambda route: (
            sort_number(route[primary]),
            sort_number(route["retry_rate"]),
            sort_number(route["human_intervention_rate"]),
            sort_number(route["p95_latency_ms"]),
            sort_number(route["director_overhead_ratio"]),
            str(route["route_id"]),
        ),
    )
    return ordered[0]["route_id"], None


def scorecards(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[Any, ...], dict[Any, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for record in records:
        groups[group_key(record, SCORECARD_FIELDS)][record.get("route_id")].append(record)
    result: list[dict[str, Any]] = []
    for key in sorted(groups, key=lambda value: json.dumps(value, default=str)):
        routes: list[dict[str, Any]] = []
        for route_id in sorted(groups[key], key=lambda value: str(value)):
            metrics = aggregate(groups[key][route_id])
            routes.append({
                "route_id": route_id,
                "completed_runs": metrics["completed_runs"],
                "first_pass_success_rate": metrics["first_pass_success_rate"],
                "validated_success_rate": metrics["validated_success_rate"],
                "retry_rate": metrics["retry_rate"],
                "human_intervention_rate": metrics["human_intervention_rate"],
                "tokens_per_validated_success": metrics["tokens_per_validated_success"],
                "cost_per_validated_success": metrics["cost_per_validated_success"],
                "median_latency_ms": metrics["median_latency_ms"],
                "p95_latency_ms": metrics["p95_latency_ms"],
                "director_overhead_ratio": metrics["director_overhead_ratio"],
                "confidence": confidence(metrics["completed_runs"]),
                "eligible_for_recommendation": metrics["completed_runs"] >= 10,
            })
        route, reason = recommended_route(routes)
        card = dict(zip(SCORECARD_FIELDS, key))
        card["routes"] = routes
        card["recommended_route"] = route
        if reason is not None:
            card["recommendation_reason"] = reason
        result.append(card)
    return result


def write_reports(records: list[dict[str, Any]], output_dir: Path) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    metrics_path = output_dir / "metrics.json"
    summary_path = output_dir / "workflow-summary.json"
    common = {
        "schema_version": 1,
        "methodology": {
            "cache_tokens": "Cache tokens are diagnostic fields already included in non-null total_tokens; they are not added again.",
            "p95": "Inclusive linear interpolation at index (n - 1) * 0.95.",
            "cost": "Estimated cost is null unless every record in the comparison group has a real cost.",
        },
    }
    metrics_path.write_text(json_line({**common, "groups": reduce_records(records)}) + "\n", encoding="utf-8")
    summary_path.write_text(json_line({**common, "scorecards": scorecards(records)}) + "\n", encoding="utf-8")
    return metrics_path, summary_path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=Path(".telemetry/invocations.jsonl"))
    parser.add_argument("--output-dir", type=Path, default=Path(".telemetry"))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or [])
    if not args.input.is_file():
        raise SystemExit(f"error: ledger not found: {args.input}")
    metrics_path, summary_path = write_reports(read_jsonl(args.input), args.output_dir)
    print(f"metrics={metrics_path} workflow_summary={summary_path}")
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(main(sys.argv[1:]))
