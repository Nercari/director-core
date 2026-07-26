#!/usr/bin/env python3
"""Assert attribution fields and overhead metrics survive the ledger workflow."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from ingest import Ledger
from reduce import aggregate


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def append(ledger: Ledger, key: str, record: dict) -> None:
    assert ledger.append(key, record)


def main() -> int:
    try:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state"
            ledger = Ledger(state)
            parent = "parent-run-1"
            unit = "UNIT-ATTRIBUTION"
            append(ledger, "director", {
                "work_unit_id": unit, "run_id": parent, "role": "director",
                "total_tokens": 40, "attempt_number": 1,
            })
            append(ledger, "executor-first", {
                "work_unit_id": unit, "run_id": "child-run-1", "parent_run_id": parent,
                "role": "executor", "executor_id": "executor-one", "total_tokens": 100,
                "attempt_number": 1, "completed": False, "validation_passed": False,
            })
            append(ledger, "executor-retry", {
                "work_unit_id": unit, "run_id": "child-run-2", "parent_run_id": parent,
                "role": "executor", "executor_id": "executor-one", "total_tokens": 120,
                "attempt_number": 2, "completed": True, "validation_passed": True,
            })
            append(ledger, "parallel-executor", {
                "work_unit_id": "UNIT-PARALLEL", "run_id": "child-run-3", "parent_run_id": parent,
                "role": "executor", "executor_id": "executor-two", "total_tokens": 80,
                "attempt_number": 1, "completed": True, "validation_passed": True,
            })
            append(ledger, "auxiliary", {
                "work_unit_id": unit, "run_id": "aux-run-1", "parent_run_id": parent,
                "role": "auxiliary", "auxiliary_kind": "compaction", "total_tokens": 25,
                "attempt_number": 2,
            })
            rows = read_jsonl(state / "invocations.jsonl")

            director = next(row for row in rows if row["role"] == "director")
            assert director["total_tokens"] == 40
            print("PASS: director usage is retained with role=director")

            first_executor = next(row for row in rows if row.get("run_id") == "child-run-1")
            assert first_executor["executor_id"] == "executor-one"
            print("PASS: executor usage retains the correct executor_id")

            children = [row for row in rows if row.get("parent_run_id") == parent]
            assert {row["run_id"] for row in children} == {"child-run-1", "child-run-2", "child-run-3", "aux-run-1"}
            print("PASS: parent and child invocations remain linked by parent_run_id")

            unit_rows = [row for row in rows if row["work_unit_id"] == unit]
            unit_metrics = aggregate(unit_rows)
            assert unit_metrics["work_unit_count"] == 1 and unit_metrics["validated_success_count"] == 1
            assert unit_metrics["retry_rate"] == 1
            print("PASS: retries remain in the original work_unit_id")

            executors = {row.get("executor_id") for row in rows if row.get("role") == "executor"}
            assert executors == {"executor-one", "executor-two"}
            print("PASS: parallel executors remain separately identifiable")

            assert unit_metrics["handoff_overhead_tokens"] == 25
            assert unit_metrics["director_overhead_ratio"] == 40 / 285
            print("PASS: auxiliary compaction usage is role=auxiliary and counts as handoff overhead")
    except (AssertionError, OSError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
