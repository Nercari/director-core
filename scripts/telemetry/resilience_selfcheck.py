#!/usr/bin/env python3
"""Assert resilience properties of the append-only telemetry workflow."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import ingest as ingest_module
from ingest import Ledger, Metadata, append_lock_path, ingest
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


def process_worker(state_dir: Path, worker: int, per_worker: int,
                   ready_dir: Path, start_path: Path) -> int:
    ready_dir.mkdir(parents=True, exist_ok=True)
    (ready_dir / f"worker-{worker}.ready").write_text("ready\n", encoding="utf-8")
    deadline = time.monotonic() + 10.0
    while not start_path.exists():
        if time.monotonic() >= deadline:
            print("FAIL: worker start barrier timed out", file=sys.stderr)
            return 1
        time.sleep(0.01)

    ledger = Ledger(state_dir)
    for ordinal in range(per_worker):
        if not ledger.append(f"process-{worker}-{ordinal}", {
            "work_unit_id": f"process-{worker}-{ordinal}", "total_tokens": ordinal,
        }):
            print(f"FAIL: duplicate process record {worker}-{ordinal}", file=sys.stderr)
            return 1
    print(f"worker={worker} pid={os.getpid()} appended={per_worker}")
    return 0


def multi_process_append_selfcheck(root: Path) -> None:
    state_dir = root / "multi-process"
    ready_dir = state_dir / "ready"
    start_path = state_dir / "start"
    workers, per_worker = 4, 30
    processes: list[subprocess.Popen[str]] = []
    try:
        for worker in range(workers):
            processes.append(subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "--process-worker",
                 str(state_dir), str(worker), str(per_worker), str(ready_dir),
                 str(start_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ))

        deadline = time.monotonic() + 10.0
        while len(list(ready_dir.glob("*.ready"))) != workers:
            if time.monotonic() >= deadline:
                raise AssertionError("multi-process worker barrier timed out")
            time.sleep(0.01)
        start_path.touch()

        worker_output: list[str] = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=15.0)
            if process.returncode != 0:
                raise AssertionError(
                    f"multi-process worker {process.pid} failed: {stderr.strip()}"
                )
            worker_output.append(stdout.strip())

        lines = (state_dir / "invocations.jsonl").read_text(encoding="utf-8").splitlines()
        records = [json.loads(line) for line in lines]
        expected_ids = {
            f"process-{worker}-{ordinal}"
            for worker in range(workers)
            for ordinal in range(per_worker)
        }
        actual_ids = {record.get("work_unit_id") for record in records}
        assert len(lines) == workers * per_worker
        assert all(isinstance(record, dict) for record in records)
        assert actual_ids == expected_ids
        assert len(actual_ids) == workers * per_worker
        reported_pids = [
            int(next(field.split("=", 1)[1] for field in output.split() if field.startswith("pid=")))
            for output in worker_output
        ]
        assert len(set(reported_pids)) == workers
        print(
            "PASS: separate-process ledger appends preserve every complete JSONL "
            f"record (workers={workers}; pids={','.join(str(pid) for pid in reported_pids)})"
        )
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()


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

            multi_process_append_selfcheck(root)

            stale_state = root / "stale-lock"
            stale_lock = append_lock_path(stale_state / "invocations.jsonl")
            stale_state.mkdir()
            stale_lock.mkdir()
            abandoned_at = time.time() - ingest_module.APPEND_LOCK_STALE_SECONDS - 1.0
            os.utime(stale_lock, (abandoned_at, abandoned_at))
            diagnostics = io.StringIO()
            with contextlib.redirect_stderr(diagnostics):
                assert Ledger(stale_state).append("stale-lock-record", {
                    "work_unit_id": "stale-lock-record", "total_tokens": 1,
                })
            assert "breaking stale telemetry append lock" in diagnostics.getvalue()
            assert str(stale_lock) in diagnostics.getvalue()
            assert not stale_lock.exists()
            stale_records = (stale_state / "invocations.jsonl").read_text(encoding="utf-8").splitlines()
            assert len(stale_records) == 1 and isinstance(json.loads(stale_records[0]), dict)
            print("PASS: a stale process lock is broken, reported, and cleaned up")

            failure_state = root / "lock-failure"
            failure_lock = append_lock_path(failure_state / "invocations.jsonl")
            failure_state.mkdir()
            failure_lock.mkdir()
            try:
                blocked = subprocess.run(
                    [sys.executable, str(Path(ingest_module.__file__).resolve()),
                     "--source", "agy_fallback", "--project-id", "test",
                     "--work-unit-id", "blocked", "--run-id", "blocked",
                     "--model", "placeholder", "--started-at", "2026-01-01T00:00:00Z",
                     "--state-dir", str(failure_state)],
                    capture_output=True,
                    text=True,
                    timeout=10.0,
                )
                assert blocked.returncode == 1
                assert "error: timed out acquiring telemetry append lock" in blocked.stderr
                assert str(failure_lock) in blocked.stderr
            finally:
                failure_lock.rmdir()
            assert not (failure_state / "invocations.jsonl").exists()
            print("PASS: lock acquisition failure names the lock and never writes unlocked")

            estimates = root / "estimates.jsonl"
            ledger = root / "ledger.jsonl"
            jsonl(estimates, [{"work_unit_id": "estimate-only", "estimated_input_tokens": 10}])
            jsonl(ledger, [{"work_unit_id": "ledger-only", "input_tokens": 20,
                            "telemetry_authoritative": True}])
            result = reconcile(estimates, ledger)
            assert result["sample_count"] == 0 and result["mean_actual_to_estimated_ratio"] is None
            print("PASS: unmatched work_unit_id values are ignored rather than guessed")
    except (AssertionError, OSError, ValueError, subprocess.SubprocessError,
            threading.BrokenBarrierError) as error:
        print(f"FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 7 and sys.argv[1] == "--process-worker":
        raise SystemExit(process_worker(
            Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]),
            Path(sys.argv[5]), Path(sys.argv[6]),
        ))
    raise SystemExit(main())
