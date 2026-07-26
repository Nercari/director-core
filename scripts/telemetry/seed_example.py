#!/usr/bin/env python3
"""Create a reproducible, clearly labelled synthetic route-comparison ledger.

This fixture exists only to demonstrate the token-accounting mechanism.  It is
not provider telemetry and must never be used as evidence about a real route.
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Any


PROJECT_ID = "EXAMPLE-SYNTHETIC"
TASK_CLASS = "bounded-code-change"
COMPLEXITY_BAND = "medium"
VALIDATION_STANDARD = "example-check"
ROUTE_A = "batch-primary"
ROUTE_B = "interactive-primary"


def json_line(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def attempt(route_id: str, route_label: str, unit_number: int, attempt_number: int,
            completed: bool, validation_passed: bool, total_tokens: int,
            seed: int, nonce: int) -> dict[str, Any]:
    """Make one synthetic invocation record without claiming provider usage."""
    work_unit_id = f"EXAMPLE-{route_label}-{unit_number:02d}"
    return {
        "project_id": PROJECT_ID,
        "synthetic": True,
        "synthetic_seed": seed,
        "synthetic_nonce": nonce,
        "telemetry_authoritative": False,
        "telemetry_source": "synthetic_example",
        "usage_kind": "synthetic",
        "work_unit_id": work_unit_id,
        "run_id": f"example-run-{route_label.lower()}-{unit_number:02d}",
        "parent_run_id": f"example-parent-{route_label.lower()}-{unit_number:02d}",
        "role": "executor",
        "executor_id": f"example-executor-{route_label.lower()}",
        "route_id": route_id,
        "synthetic_route_label": route_label,
        "execution_mode": "synthetic_subscription",
        "task_class": TASK_CLASS,
        "complexity_band": COMPLEXITY_BAND,
        "validation_standard": VALIDATION_STANDARD,
        "attempt_number": attempt_number,
        "completed": completed,
        "validation_passed": validation_passed,
        "model": "EXEC_PRIMARY",
        "started_at": f"2026-01-01T00:{unit_number:02d}:{attempt_number:02d}Z",
        "input_tokens": total_tokens // 2,
        "output_tokens": total_tokens - (total_tokens // 2),
        "cache_read_tokens": 0,
        "cache_creation_tokens": 0,
        "total_tokens": total_tokens,
        "estimated_cost": None,
        "latency_ms": 100 if route_label == "A" else 120,
    }


def build_records(seed: int) -> list[dict[str, Any]]:
    """Build two comparable routes with deliberately opposing cost signals.

    A costs fewer tokens for each attempt (1,000 versus B's 1,500), but it
    requires many more retries.  Consequently B uses fewer tokens for each
    validated success (31,500 / 19 versus A's 35,000 / 18).
    """
    rng = random.Random(seed)
    records: list[dict[str, Any]] = []

    # Route A: 20 completed units, 18 validated successes, 15 retrying units.
    for unit_number in range(1, 21):
        if unit_number <= 15:
            records.append(attempt(ROUTE_A, "A", unit_number, 1, False, False, 1000,
                                   seed, rng.randrange(1_000_000)))
            records.append(attempt(ROUTE_A, "A", unit_number, 2, True, True, 1000,
                                   seed, rng.randrange(1_000_000)))
        elif unit_number <= 18:
            records.append(attempt(ROUTE_A, "A", unit_number, 1, True, True, 1000,
                                   seed, rng.randrange(1_000_000)))
        else:
            records.append(attempt(ROUTE_A, "A", unit_number, 1, True, False, 1000,
                                   seed, rng.randrange(1_000_000)))

    # Route B: 20 completed units, 19 validated successes, one retrying unit.
    for unit_number in range(1, 21):
        if unit_number == 1:
            records.append(attempt(ROUTE_B, "B", unit_number, 1, False, False, 1500,
                                   seed, rng.randrange(1_000_000)))
            records.append(attempt(ROUTE_B, "B", unit_number, 2, True, True, 1500,
                                   seed, rng.randrange(1_000_000)))
        elif unit_number <= 19:
            records.append(attempt(ROUTE_B, "B", unit_number, 1, True, True, 1500,
                                   seed, rng.randrange(1_000_000)))
        else:
            records.append(attempt(ROUTE_B, "B", unit_number, 1, True, False, 1500,
                                   seed, rng.randrange(1_000_000)))
    return records


def write_example(output_dir: Path, seed: int) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    ledger = output_dir / "invocations.jsonl"
    records = build_records(seed)
    ledger.write_text("".join(json_line(record) + "\n" for record in records), encoding="utf-8")
    return ledger


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / ".telemetry" / "example")
    parser.add_argument("--seed", type=int, default=20260725)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or [])
    ledger = write_example(args.output_dir, args.seed)
    print(f"synthetic_ledger={ledger} records={len(build_records(args.seed))} seed={args.seed}")
    print("synthetic_only=true project_id=EXAMPLE-SYNTHETIC")
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(main(sys.argv[1:]))
