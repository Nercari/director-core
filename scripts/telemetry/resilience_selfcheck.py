#!/usr/bin/env python3
"""Assert resilience properties of the append-only telemetry workflow."""

from __future__ import annotations

import json
import tempfile
import threading
from pathlib import Path

from ingest import Ledger, Metadata, ingest
from preflight_budget import reconcile
from reduce import aggregate


def jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")


def codex_event() -> str:
    usage = {
        "input_tokens": 10, "cached_input_tokens": 0, "cache_write_input_tokens": 0,
        "output_tokens": 5, "reasoning_output_tokens": 0, "total_tokens": 15,
    }
    return json.dumps({"timestamp": "2026-01-01T00:00:00Z", "model": "EXEC_PRIMARY",
                       "total_token_usage": usage})


def main() -> int:
    try:
        missing = aggregate([{"work_unit_id": "missing-fields"}])
        assert missing["total_tokens"] == 0 and missing["completed_runs"] == 0
        print("PASS: missing telemetry fields do not crash aggregation")

        incomplete = aggregate([{"work_unit_id": "interrupted", "attempt_number": 1,
                                  "total_tokens": 12, "completed": False}])
        assert incomplete["completed_runs"] == 1
        assert incomplete["validated_success_count"] == 0
        assert incomplete["tokens_per_validated_success"] is None
        print("PASS: interrupted work remains incomplete and is never counted as a success")

        null_total = aggregate([{"work_unit_id": "null-total", "completed": True,
                                 "validation_passed": True, "total_tokens": None,
                                 "input_tokens": 7, "output_tokens": 3}])
        assert null_total["total_tokens"] == 10
        assert null_total["tokens_per_validated_success"] == 10
        print("PASS: null total_tokens uses known parts and does not poison sums")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = root / "state"
            source = root / "provider.jsonl"
            source.write_text(codex_event() + "\n", encoding="utf-8")
            metadata = Metadata("test", "duplicate", None, "EXEC_PRIMARY", "2026-01-01T00:00:00Z")
            first = ingest("codex", [str(source)], metadata, state)
            second = ingest("codex", [str(source)], metadata, state)
            records = [json.loads(line) for line in (state / "invocations.jsonl").read_text(encoding="utf-8").splitlines()]
            assert first["ingested"] == 1 and second["skipped"] == 1 and len(records) == 1
            print("PASS: duplicate provider event is detected and re-ingestion is idempotent")

            corrupt = root / "corrupt.jsonl"
            corrupt.write_text("{broken json\n", encoding="utf-8")
            result = ingest("codex", [str(corrupt)], metadata, state)
            quarantined = [json.loads(line) for line in (state / "quarantine.jsonl").read_text(encoding="utf-8").splitlines()]
            assert result["quarantined"] == 1 and len(quarantined) == 1
            print("PASS: corrupt records are quarantined and ingestion returns normally")

            concurrent = root / "concurrent"
            workers, per_worker = 8, 25
            barrier = threading.Barrier(workers)

            def append_worker(worker: int) -> None:
                ledger = Ledger(concurrent)
                barrier.wait()
                for ordinal in range(per_worker):
                    assert ledger.append(f"worker-{worker}-{ordinal}", {
                        "work_unit_id": f"concurrent-{worker}-{ordinal}", "total_tokens": ordinal,
                    })

            threads = [threading.Thread(target=append_worker, args=(worker,)) for worker in range(workers)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
            lines = (concurrent / "invocations.jsonl").read_text(encoding="utf-8").splitlines()
            assert len(lines) == workers * per_worker
            assert all(isinstance(json.loads(line), dict) for line in lines)
            print("PASS: concurrent ledger appends leave every JSONL line complete and parseable")

            estimates = root / "estimates.jsonl"
            ledger = root / "ledger.jsonl"
            jsonl(estimates, [{"work_unit_id": "estimate-only", "estimated_input_tokens": 10}])
            jsonl(ledger, [{"work_unit_id": "ledger-only", "input_tokens": 20,
                            "telemetry_authoritative": True}])
            result = reconcile(estimates, ledger)
            assert result["sample_count"] == 0 and result["mean_actual_to_estimated_ratio"] is None
            print("PASS: unmatched work_unit_id values are ignored rather than guessed")
    except (AssertionError, OSError, ValueError, threading.BrokenBarrierError) as error:
        print(f"FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
