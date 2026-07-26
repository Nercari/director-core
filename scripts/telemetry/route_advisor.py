#!/usr/bin/env python3
"""Recommend a telemetry route from the reducer's compact workflow summary.

This module never reads the raw invocation ledger.  In advisory mode it emits
and appends the route it *would* select; it never changes an active route.
"""

from __future__ import annotations

import argparse
import json
import math
import random
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TIE_BREAKER_FIELDS = {
    "lowest_retry_rate": "retry_rate",
    "lowest_human_intervention_rate": "human_intervention_rate",
    "lowest_p95_latency": "p95_latency_ms",
    "lowest_director_overhead_ratio": "director_overhead_ratio",
}


def json_line(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def scalar(value: str) -> Any:
    value = value.strip()
    if value in ("null", "~"):
        return None
    if value == "true":
        return True
    if value == "false":
        return False
    if value.startswith(('"', "'")) and value.endswith(("'", '"')):
        return value[1:-1]
    try:
        return int(value)
    except ValueError:
        try:
            return float(value)
        except ValueError:
            return value


def uncomment(line: str) -> str:
    """Remove simple YAML comments; policy values deliberately need no #."""
    return line.split("#", 1)[0].rstrip()


def load_minimal_yaml(path: Path) -> dict[str, Any]:
    """Parse the small mapping/list subset used by routing-policy.yaml only."""
    rows: list[tuple[int, str]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        text = uncomment(raw)
        if text.strip():
            rows.append((len(text) - len(text.lstrip(" ")), text.strip()))

    def block(index: int, indent: int) -> tuple[Any, int]:
        if index >= len(rows) or rows[index][0] < indent:
            return {}, index
        is_list = rows[index][1].startswith("- ")
        result: Any = [] if is_list else {}
        while index < len(rows) and rows[index][0] == indent:
            text = rows[index][1]
            if is_list:
                if not text.startswith("- "):
                    raise ValueError(f"{path}: mixed list and mapping")
                value = text[2:].strip()
                if not value:
                    child, index = block(index + 1, rows[index + 1][0])
                    result.append(child)
                    continue
                result.append(scalar(value))
                index += 1
                continue
            if text.startswith("- ") or ":" not in text:
                raise ValueError(f"{path}: unsupported policy line: {text}")
            key, value = text.split(":", 1)
            key, value = key.strip(), value.strip()
            if not value:
                if index + 1 >= len(rows) or rows[index + 1][0] <= indent:
                    result[key] = {}
                    index += 1
                else:
                    result[key], index = block(index + 1, rows[index + 1][0])
            else:
                result[key] = scalar(value)
                index += 1
        return result, index

    parsed, consumed = block(0, rows[0][0] if rows else 0)
    if consumed != len(rows) or not isinstance(parsed, dict):
        raise ValueError(f"{path}: invalid policy structure")
    return parsed


def load_summary(path: Path) -> dict[str, Any]:
    if not path.is_file():
        # A newly initialized, empty ledger has no reducer output yet.  This
        # remains evidence-free and therefore yields a null recommendation.
        return {"scorecards": []}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("scorecards"), list):
        raise ValueError(f"{path}: workflow summary must contain scorecards")
    return value


def number(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return math.inf
    return float(value)


def confidence(completed_runs: Any) -> str:
    if isinstance(completed_runs, int) and completed_runs >= 30:
        return "high"
    if isinstance(completed_runs, int) and completed_runs >= 10:
        return "medium"
    return "low"


def scorecard_for(summary: dict[str, Any], task_class: str, complexity_band: str) -> dict[str, Any] | None:
    for card in summary["scorecards"]:
        if (isinstance(card, dict) and card.get("task_class") == task_class and
                card.get("complexity_band") == complexity_band):
            return card
    return None


def eligible(route: dict[str, Any], policy: dict[str, Any]) -> tuple[bool, str | None]:
    rules = policy["eligibility"]
    completed = route.get("completed_runs")
    if not isinstance(completed, int) or completed < rules["minimum_completed_samples"]:
        return False, "insufficient_completed_samples"
    success_rate = route.get("validated_success_rate")
    if (isinstance(success_rate, bool) or not isinstance(success_rate, (int, float)) or
            success_rate < rules["minimum_validated_success_rate"]):
        return False, "validated_success_rate_below_minimum"
    return True, None


def choose_route(routes: list[dict[str, Any]], policy: dict[str, Any]) -> tuple[dict[str, Any], str, str]:
    """Return winner, metric used, and the metric that decided a tie."""
    cost_known = all(route.get("cost_per_validated_success") is not None for route in routes)
    primary = "cost_per_validated_success" if cost_known else "tokens_per_validated_success"
    candidates = routes[:]
    values = [number(route.get(primary)) for route in candidates]
    best = min(values)
    candidates = [route for route in candidates if number(route.get(primary)) == best]
    if len(candidates) == 1:
        return candidates[0], primary, primary
    for declared in policy["tie_breakers"]:
        field = TIE_BREAKER_FIELDS.get(declared)
        if field is None:
            raise ValueError(f"unsupported policy tie-breaker: {declared}")
        best = min(number(route.get(field)) for route in candidates)
        narrowed = [route for route in candidates if number(route.get(field)) == best]
        if len(narrowed) < len(candidates):
            if len(narrowed) == 1:
                return narrowed[0], primary, declared
            candidates = narrowed
    return sorted(candidates, key=lambda route: str(route.get("route_id")))[0], primary, "route_id"


def recommend(summary: dict[str, Any], policy: dict[str, Any], task_class: str,
              complexity_band: str, seed: int | None = None) -> dict[str, Any]:
    card = scorecard_for(summary, task_class, complexity_band)
    routes = card.get("routes", []) if card else []
    considered: list[dict[str, Any]] = []
    allowed: list[dict[str, Any]] = []
    for route in routes:
        if not isinstance(route, dict):
            continue
        is_eligible, ineligible_reason = eligible(route, policy)
        known_route_ids = policy.get("route_ids")
        if isinstance(known_route_ids, dict) and route.get("route_id") not in known_route_ids:
            is_eligible, ineligible_reason = False, "route_not_in_policy"
        judged_on = ("cost_per_validated_success" if route.get("cost_per_validated_success") is not None
                     else "tokens_per_validated_success")
        considered.append({
            "route_id": route.get("route_id"), "metric": judged_on,
            "metric_value": route.get(judged_on), "eligible": is_eligible,
            "ineligible_reason": ineligible_reason,
        })
        if is_eligible:
            allowed.append(route)
    result: dict[str, Any] = {
        "mode": policy["mode"], "task_class": task_class,
        "complexity_band": complexity_band, "recommended_route": None,
        "recommendation_reason": "No comparable route scorecard exists; insufficient samples.",
        "confidence": "none", "eligible_routes": [route.get("route_id") for route in allowed],
        "considered_routes": considered, "exploration_selected": False,
        "policy_version": policy["policy_version"],
    }
    if not allowed:
        if card is not None:
            result["recommendation_reason"] = (
                "No eligible routes: insufficient samples or validated success rate below the policy minimum.")
        return result
    costs_known = all(route.get("cost_per_validated_success") is not None for route in allowed)
    objective_field = "cost_per_validated_success" if costs_known else "tokens_per_validated_success"
    if not any(math.isfinite(number(route.get(objective_field))) for route in allowed):
        result["recommendation_reason"] = (
            f"Eligible routes have no known {objective_field}; cannot recommend without evidence.")
        return result
    winner, primary, deciding = choose_route(allowed, policy)
    reason = ""
    if primary == "cost_per_validated_success":
        reason = "Lowest cost per validated success selected."
    else:
        reason = "Estimated cost is unknown; used tokens per validated success instead."
    if deciding != primary:
        reason += f" Tie decided by {deciding}."
    else:
        reason += f" Decided by {primary}."
    selected = winner
    exploration = policy["exploration"]
    rng = random.Random(seed) if seed is not None else random.Random()
    alternatives = [route for route in allowed if route is not winner]
    if exploration["enabled"] and alternatives and rng.random() < exploration["percentage"] / 100:
        selected = alternatives[rng.randrange(len(alternatives))]
        result["exploration_selected"] = True
        reason = (f"Exploration selected non-optimal eligible route {selected.get('route_id')} "
                  f"instead of {winner.get('route_id')} (deterministic when seeded).")
    result["recommended_route"] = selected.get("route_id")
    result["recommendation_reason"] = reason
    result["confidence"] = confidence(selected.get("completed_runs"))
    return result


def now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json_line(record) + "\n")


def record_advisory_decision(path: Path, work_unit_id: str, result: dict[str, Any]) -> None:
    append_jsonl(path, {
        "event_type": "routing_recommendation", "timestamp": now(), "work_unit_id": work_unit_id,
        "task_class": result["task_class"], "complexity_band": result["complexity_band"],
        "mode": result["mode"], "recommended_route": result["recommended_route"],
        "actual_route": None, "agreement": None, "reason": result["recommendation_reason"],
        "confidence": result["confidence"], "policy_version": result["policy_version"],
    })


def record_actual_route(path: Path, work_unit_id: str, actual_route: str) -> None:
    prior: dict[str, Any] | None = None
    if path.is_file():
        for raw in path.read_text(encoding="utf-8").splitlines():
            if raw.strip():
                row = json.loads(raw)
                if (isinstance(row, dict) and row.get("work_unit_id") == work_unit_id and
                        row.get("event_type", "routing_recommendation") == "routing_recommendation"):
                    prior = row
    recommended = prior.get("recommended_route") if prior else None
    append_jsonl(path, {
        "event_type": "actual_route_recorded", "timestamp": now(), "work_unit_id": work_unit_id,
        "actual_route": actual_route, "recommended_route": recommended,
        "agreement": actual_route == recommended if isinstance(recommended, str) else None,
    })


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-class")
    parser.add_argument("--complexity-band")
    parser.add_argument("--work-unit-id", default="unassigned")
    parser.add_argument("--summary", type=Path, default=Path(".telemetry/workflow-summary.json"))
    parser.add_argument("--policy", type=Path, default=Path(".telemetry/routing-policy.yaml"))
    parser.add_argument("--decision-log", type=Path, default=Path(".telemetry/routing-decisions.jsonl"))
    parser.add_argument("--seed", type=int)
    parser.add_argument("--record-actual-route", metavar="ROUTE")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or [])
    if args.record_actual_route is not None:
        if args.work_unit_id == "unassigned":
            raise SystemExit("error: --work-unit-id is required when recording an actual route")
        record_actual_route(args.decision_log, args.work_unit_id, args.record_actual_route)
        print(json_line({"recorded_actual_route": args.record_actual_route, "work_unit_id": args.work_unit_id}))
        return 0
    if not args.task_class or not args.complexity_band:
        raise SystemExit("error: --task-class and --complexity-band are required")
    result = recommend(load_summary(args.summary), load_minimal_yaml(args.policy),
                       args.task_class, args.complexity_band, args.seed)
    if result["mode"] == "advisory":
        record_advisory_decision(args.decision_log, args.work_unit_id, result)
    print(json_line(result))
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(main(sys.argv[1:]))
