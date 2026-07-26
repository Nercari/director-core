#!/usr/bin/env python3
"""Assert-based checks for the advisory route policy and handoff efficiency block."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from handoff_efficiency import workflow_efficiency
from route_advisor import (append_jsonl, load_minimal_yaml, recommend,
                           record_actual_route, record_advisory_decision)


def route(route_id: str, *, completed: int = 10, success: float = 1.0,
          tokens: float = 100.0, cost: float | None = None, retry: float = 0.0,
          human: float = 0.0, p95: float = 10.0, overhead: float = 0.1) -> dict:
    return {
        "route_id": route_id, "completed_runs": completed,
        "validated_success_rate": success, "tokens_per_validated_success": tokens,
        "cost_per_validated_success": cost, "retry_rate": retry,
        "human_intervention_rate": human, "p95_latency_ms": p95,
        "director_overhead_ratio": overhead,
    }


def summary(*routes: dict) -> dict:
    return {"scorecards": [{"task_class": "bounded-code-change", "complexity_band": "medium",
                            "routes": list(routes)}]}


def policy() -> dict:
    return {
        "policy_version": 1, "mode": "advisory",
        "eligibility": {"minimum_completed_samples": 10, "minimum_validated_success_rate": 0.90},
        "objective": {"primary": "lowest_cost_per_validated_success",
                      "fallback": "lowest_tokens_per_validated_success"},
        "tie_breakers": ["lowest_retry_rate", "lowest_human_intervention_rate",
                         "lowest_p95_latency", "lowest_director_overhead_ratio"],
        "exploration": {"enabled": True, "percentage": 10},
    }


def decision(result: dict) -> str:
    return result["recommendation_reason"]


def assert_tie_breaker(field: str, first: dict, second: dict) -> None:
    result = recommend(summary(first, second), policy(), "bounded-code-change", "medium", seed=0)
    assert field in decision(result), result


def main() -> int:
    try:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_policy = Path(".telemetry/routing-policy.yaml")
            parsed = load_minimal_yaml(source_policy)
            assert parsed["mode"] == "advisory"
            before = json.dumps(summary(route("one")), sort_keys=True)
            result = recommend(summary(route("one")), parsed, "bounded-code-change", "medium", seed=0)
            assert result["mode"] == "advisory" and json.dumps(summary(route("one")), sort_keys=True) == before
            print("PASS: advisory is the default and only records its recommendation")

            result = recommend(summary(route("few", completed=9)), policy(), "bounded-code-change", "medium")
            assert result["recommended_route"] is None and result["considered_routes"][0]["ineligible_reason"] == "insufficient_completed_samples"
            print("PASS: route with fewer than ten completed runs is ineligible")

            result = recommend(summary(route("weak", success=0.89)), policy(), "bounded-code-change", "medium")
            assert result["recommended_route"] is None and result["considered_routes"][0]["ineligible_reason"] == "validated_success_rate_below_minimum"
            print("PASS: route below the validated-success threshold is ineligible")

            result = recommend(summary(route("few", completed=2)), policy(), "bounded-code-change", "medium")
            assert result["recommended_route"] is None and "No eligible routes" in decision(result)
            print("PASS: no eligible routes returns null with a reason")

            result = recommend(summary(route("unknown", tokens=None)), policy(), "bounded-code-change", "medium")
            assert result["recommended_route"] is None and "cannot recommend" in decision(result)
            print("PASS: missing objective metrics never produce a guessed route")

            result = recommend(summary(route("expensive", tokens=200), route("efficient", tokens=100)),
                               policy(), "bounded-code-change", "medium", seed=0)
            assert result["recommended_route"] == "efficient" and "Estimated cost is unknown" in decision(result)
            print("PASS: token efficiency is used when estimated cost is null")

            assert_tie_breaker("lowest_retry_rate", route("a", retry=0.1), route("b", retry=0.2))
            assert_tie_breaker("lowest_human_intervention_rate", route("a", human=0.1), route("b", human=0.2))
            assert_tie_breaker("lowest_p95_latency", route("a", p95=10), route("b", p95=20))
            assert_tie_breaker("lowest_director_overhead_ratio", route("a", overhead=0.1), route("b", overhead=0.2))
            print("PASS: declared tie-breakers decide and are recorded in order")

            exploration_policy = policy()
            exploration_policy["exploration"]["percentage"] = 100
            first = recommend(summary(route("best", tokens=10), route("other", tokens=20)),
                              exploration_policy, "bounded-code-change", "medium", seed=31)
            second = recommend(summary(route("best", tokens=10), route("other", tokens=20)),
                               exploration_policy, "bounded-code-change", "medium", seed=31)
            assert first["exploration_selected"] and first == second and first["recommended_route"] == "other"
            print("PASS: exploration is deterministic with a fixed seed")

            log = root / "routing-decisions.jsonl"
            logged = recommend(summary(route("one")), policy(), "bounded-code-change", "medium")
            record_advisory_decision(log, "UNIT-3", logged)
            original = log.read_text(encoding="utf-8")
            record_actual_route(log, "UNIT-3", "director-primary_executor-primary")
            rows = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
            assert len(rows) == 2 and log.read_text(encoding="utf-8").startswith(original)
            assert rows[0]["actual_route"] is None and rows[1]["event_type"] == "actual_route_recorded"
            print("PASS: actual-route recording appends without mutating the decision")

            ledger = [
                {"work_unit_id": "UNIT-3", "role": "director", "route_id": "director-primary_executor-primary",
                 "total_tokens": 10, "attempt_number": 1},
                {"work_unit_id": "UNIT-3", "role": "executor", "total_tokens": 20, "attempt_number": 2,
                 "validation_passed": True, "opaque_raw_payload": {"must": "not appear"}},
            ]
            block = workflow_efficiency(ledger, rows, "UNIT-3")
            encoded = json.dumps({"workflow_efficiency": block})
            assert "opaque_raw_payload" not in encoded and "records" not in block
            assert block["total_tokens"] == 30 and block["retries"] == 1
            print("PASS: handoff efficiency block is compact and contains no raw ledger records")
    except AssertionError as error:
        print(f"FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
