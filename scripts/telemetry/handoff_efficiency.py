#!/usr/bin/env python3
"""Produce the compact workflow_efficiency handoff block for one work unit."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any


def json_line(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            value = json.loads(line)
            if isinstance(value, dict):
                rows.append(value)
    return rows


def token_total(row: dict[str, Any]) -> int | float | None:
    total = row.get("total_tokens")
    if isinstance(total, (int, float)) and not isinstance(total, bool) and math.isfinite(total) and total >= 0:
        return total
    values = [row.get(name) for name in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens")]
    known = [value for value in values if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0]
    return sum(known) if known else None


def latest_outcome(rows: list[dict[str, Any]]) -> bool | None:
    outcomes = [row.get("validation_passed") for row in rows if isinstance(row.get("validation_passed"), bool)]
    return outcomes[-1] if outcomes else None


def latest_recommendation(rows: list[dict[str, Any]], work_unit_id: str) -> tuple[str | None, str | None]:
    matching = [row for row in rows if row.get("work_unit_id") == work_unit_id and
                row.get("event_type", "routing_recommendation") == "routing_recommendation"]
    if not matching:
        return None, None
    latest = matching[-1]
    route = latest.get("recommended_route")
    confidence = latest.get("confidence")
    return (route if isinstance(route, str) else None,
            confidence if isinstance(confidence, str) else None)


def workflow_efficiency(ledger: list[dict[str, Any]], decisions: list[dict[str, Any]],
                        work_unit_id: str) -> dict[str, Any]:
    rows = [row for row in ledger if row.get("work_unit_id") == work_unit_id]
    by_role = {"director": 0, "executor": 0, "auxiliary": 0}
    known_by_role = {role: False for role in by_role}
    totals: list[int | float] = []
    for row in rows:
        total = token_total(row)
        if total is None:
            continue
        totals.append(total)
        role = row.get("role")
        if role in by_role:
            by_role[role] += total
            known_by_role[role] = True
    attempts = {row.get("attempt_number") for row in rows if isinstance(row.get("attempt_number"), int) and
                not isinstance(row.get("attempt_number"), bool)}
    route = next((row.get("route_id") for row in reversed(rows) if isinstance(row.get("route_id"), str)), None)
    recommendation, confidence = latest_recommendation(decisions, work_unit_id)
    return {
        "work_unit_route": route,
        "director_tokens": by_role["director"] if known_by_role["director"] else None,
        "executor_tokens": by_role["executor"] if known_by_role["executor"] else None,
        "auxiliary_tokens": by_role["auxiliary"] if known_by_role["auxiliary"] else None,
        "total_tokens": sum(totals) if totals else None,
        "retries": max(0, len(attempts) - 1) if attempts else None,
        "validation_passed": latest_outcome(rows),
        "compared_route_recommendation": recommendation,
        "recommendation_confidence": confidence,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-unit-id", required=True)
    parser.add_argument("--ledger", type=Path, default=Path(".telemetry/invocations.jsonl"))
    parser.add_argument("--decision-log", type=Path, default=Path(".telemetry/routing-decisions.jsonl"))
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or [])
    print(json_line({"workflow_efficiency": workflow_efficiency(
        read_jsonl(args.ledger), read_jsonl(args.decision_log), args.work_unit_id)}))
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(main(sys.argv[1:]))
