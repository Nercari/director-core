#!/usr/bin/env python3
"""Assert-based synthetic checks for the telemetry reducer and Codex delta fix."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from ingest import Metadata, ingest
from reduce import aggregate, percentile_95, scorecards


def record(work_unit_id: str, route_id: str = "EXEC_PRIMARY", **values: object) -> dict:
    base = {
        "work_unit_id": work_unit_id,
        "task_class": "feature",
        "complexity_band": "small",
        "validation_standard": "behavior",
        "route_id": route_id,
        "execution_mode": "headless",
        "role": "executor",
        "total_tokens": 100,
        "estimated_cost": None,
        "latency_ms": 10,
    }
    base.update(values)
    return base


def codex_usage(total: int) -> dict:
    return {
        "input_tokens": total,
        "cached_input_tokens": 0,
        "cache_write_input_tokens": 0,
        "output_tokens": 0,
        "reasoning_output_tokens": 0,
        "total_tokens": total,
    }


def check_duplicate_codex_delta() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        source = root / "codex.jsonl"
        usage = codex_usage(100)
        source.write_text("\n".join(json.dumps({
            "timestamp": timestamp,
            "model": "gpt-test",
            "payload": {"info": {"total_token_usage": usage, "last_token_usage": usage}},
        }) for timestamp in ("2026-07-20T01:30:58.338Z", "2026-07-20T01:31:07.183Z")) + "\n", encoding="utf-8")
        state = root / ".telemetry"
        ingest("codex", [str(source)], Metadata("test", "duplicate", None, None, None), state)
        rows = [json.loads(line) for line in (state / "invocations.jsonl").read_text(encoding="utf-8").splitlines()]
        assert [row["total_tokens"] for row in rows] == [100, 0]
        assert sum(row["total_tokens"] for row in rows) == 100


def completed_records(count: int, route_id: str, *, start: int = 0) -> list[dict]:
    return [record(f"unit-{start + index}", route_id, completed=True,
                   validation_passed=True, attempt_number=1)
            for index in range(count)]


def main() -> int:
    try:
        check_duplicate_codex_delta()
        print("PASS: duplicate Codex cumulative snapshot yields zero delta")

        retried = [
            record("retry", total_tokens=120, attempt_number=1),
            record("retry", total_tokens=180, attempt_number=2, completed=True,
                   validation_passed=True),
        ]
        retry_metrics = aggregate(retried)
        assert retry_metrics["total_tokens"] == 300
        assert retry_metrics["validated_success_count"] == 1
        assert retry_metrics["tokens_per_validated_success"] == 300
        print("PASS: retry tokens count toward the same work unit")

        outcomes = [
            record("failed", completed=False, validation_passed=False, attempt_number=1),
            record("passed", completed=True, validation_passed=True, attempt_number=1),
        ]
        assert aggregate(outcomes)["validated_success_count"] == 1
        print("PASS: failed work unit is excluded from validated successes")

        no_success = aggregate([record("unfinished", completed=False, validation_passed=False)])
        assert no_success["tokens_per_validated_success"] is None
        assert no_success["cost_per_validated_success"] is None
        print("PASS: divide by zero yields null")

        partial_cost = aggregate([
            record("cost-a", estimated_cost=1.25),
            record("cost-b", estimated_cost=None),
        ])
        assert partial_cost["estimated_cost"] is None
        print("PASS: cost is null when any record lacks real cost")

        assert percentile_95([0, 10, 20, 30, 40]) == 38
        print("PASS: p95 uses documented inclusive linear interpolation")

        mixed = completed_records(10, "eligible") + completed_records(9, "low", start=10)
        card = scorecards(mixed)[0]
        low_route = next(route for route in card["routes"] if route["route_id"] == "low")
        assert low_route["confidence"] == "low"
        assert low_route["eligible_for_recommendation"] is False
        assert card["recommended_route"] == "eligible"
        print("PASS: low-confidence route is not recommended")

        no_eligible = scorecards(completed_records(9, "low-only"))[0]
        assert no_eligible["recommended_route"] is None
        assert no_eligible["recommendation_reason"]
        print("PASS: no eligible route produces null recommendation")
    except AssertionError as error:
        print(f"FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
