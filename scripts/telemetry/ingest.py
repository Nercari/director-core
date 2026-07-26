#!/usr/bin/env python3
"""Append authoritative provider usage events to the local invocation ledger.

Codex and agy do not provide all required invocation metadata in their usage
events. For Codex, event timestamps and model identifiers take precedence;
the command-line values are fallbacks, for example:

  bash scripts/telemetry/ingest.sh --source codex --input rollout.jsonl \\
    --project-id director-core --work-unit-id UNIT-1 \\
    --model "$(model for EXEC_STRONG from .director/routes.yaml)" \\
    --started-at 2026-07-25T12:00:00Z
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
import sys
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


TOKEN_FIELDS = (
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
)


# One process can receive concurrent adapter writes.  Serialize each physical
# JSONL append so a complete line is never lost or interleaved.  The ledger is
# append-only; the lock intentionally covers only one file write at a time.
APPEND_LOCK = threading.Lock()

# A lock directory is used instead of a platform-specific file lock: mkdir is
# atomic on the local filesystems supported by both Windows and POSIX Python.
# Contenders wait briefly for the small append, while a longer age threshold
# identifies a directory abandoned by a killed process.  Both limits are
# bounded so an abandoned lock cannot block the append-only ledger forever.
APPEND_LOCK_TIMEOUT_SECONDS = 2.0
APPEND_LOCK_RETRY_SECONDS = 0.02
APPEND_LOCK_STALE_SECONDS = 4.0


class LockAcquisitionError(RuntimeError):
    """Raised when a physical ledger append cannot obtain its process lock."""


def append_lock_path(path: Path) -> Path:
    return path.parent / f".{path.name}.append.lock"


class ProcessAppendLock:
    """Serialize one JSONL append across processes using an atomic directory.

    A lock directory whose modification time is at least ``stale_after_seconds``
    old is treated as abandoned and removed.  This recovers from a killed
    process while preserving a bounded wait for all other contention.
    """

    def __init__(self, path: Path, *, timeout_seconds: float | None = None,
                 retry_seconds: float | None = None,
                 stale_after_seconds: float | None = None) -> None:
        self.path = path
        self.timeout_seconds = (APPEND_LOCK_TIMEOUT_SECONDS if timeout_seconds is None
                                else timeout_seconds)
        self.retry_seconds = (APPEND_LOCK_RETRY_SECONDS if retry_seconds is None
                              else retry_seconds)
        self.stale_after_seconds = (APPEND_LOCK_STALE_SECONDS
                                    if stale_after_seconds is None
                                    else stale_after_seconds)
        self._held = False

    def __enter__(self) -> ProcessAppendLock:
        deadline = time.monotonic() + self.timeout_seconds
        while True:
            try:
                self.path.mkdir()
                self._held = True
                return self
            except (FileExistsError, PermissionError) as error:
                try:
                    age = time.time() - self.path.stat().st_mtime
                except FileNotFoundError:
                    if isinstance(error, PermissionError) and time.monotonic() >= deadline:
                        raise LockAcquisitionError(
                            f"timed out acquiring telemetry append lock at {self.path}"
                        ) from error
                    if isinstance(error, PermissionError):
                        time.sleep(min(
                            self.retry_seconds, max(0.0, deadline - time.monotonic())
                        ))
                    continue
                if age >= self.stale_after_seconds:
                    try:
                        self.path.rmdir()
                        print(
                            "warning: breaking stale telemetry append lock at "
                            f"{self.path} (age {age:.2f}s; timeout "
                            f"{self.stale_after_seconds:.2f}s)",
                            file=sys.stderr,
                        )
                    except FileNotFoundError:
                        pass
                    except OSError as error:
                        raise LockAcquisitionError(
                            f"unable to remove stale telemetry append lock at "
                            f"{self.path}: {error}"
                        ) from error
                    continue
                if time.monotonic() >= deadline:
                    raise LockAcquisitionError(
                        f"timed out acquiring telemetry append lock at {self.path}"
                    )
                time.sleep(min(self.retry_seconds, max(0.0, deadline - time.monotonic())))
            except OSError as error:
                raise LockAcquisitionError(
                    f"unable to acquire telemetry append lock at {self.path}: {error}"
                ) from error

    def __exit__(self, exc_type: object, exc_value: object,
                 traceback: object) -> bool:
        if self._held:
            try:
                self.path.rmdir()
            except FileNotFoundError:
                pass
            except OSError as error:
                print(
                    f"warning: could not remove telemetry append lock at {self.path}: {error}",
                    file=sys.stderr,
                )
            finally:
                self._held = False
        return False


@dataclass(frozen=True)
class Metadata:
    project_id: str
    work_unit_id: str
    run_id: str | None
    model: str | None
    started_at: str | None


def json_line(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def read_jsonl(path: Path) -> Iterable[tuple[int, str, Any | None, str | None]]:
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, start=1):
            text = raw.rstrip("\r\n")
            if not text:
                continue
            try:
                yield line_number, text, json.loads(text), None
            except json.JSONDecodeError as error:
                yield line_number, text, None, f"invalid_json: {error.msg}"


def input_files(inputs: list[str]) -> Iterable[Path]:
    for value in inputs:
        path = Path(value)
        if path.is_dir():
            yield from sorted(path.rglob("*.jsonl"))
        else:
            yield path


def require_non_negative_int(value: Any, name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return value


def nullable_number(value: Any, name: str) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        raise ValueError(f"{name} must be a non-negative number or null")
    return value


def nullable_integer(value: Any, name: str) -> int | None:
    if value is None:
        return None
    return require_non_negative_int(value, name)


def nullable_string(value: Any, name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name} must be a non-empty string or null")
    return value


def first_non_empty_string(*values: Any) -> str | None:
    for value in values:
        if isinstance(value, str) and value:
            return value
    return None


def base_record(metadata: Metadata, *, run_id: str, role: str, provider: str,
                model: str, started_at: str, authoritative: bool) -> dict[str, Any]:
    return {
        "project_id": metadata.project_id,
        "work_unit_id": metadata.work_unit_id,
        "run_id": run_id,
        "role": role,
        "provider": provider,
        "model": model,
        "started_at": started_at,
        "estimated_cost": None,
        "quota_used_percent": None,
        "quota_window_minutes": None,
        "quota_resets_at": None,
        "quota_limit_id": None,
        "model_context_window": None,
        "telemetry_authoritative": authoritative,
    }


def claude_record(event: Any, metadata: Metadata, path: Path) -> dict[str, Any]:
    if not isinstance(event, dict):
        raise ValueError("Claude event must be an object")
    message = event.get("message")
    if not isinstance(message, dict):
        raise ValueError("Claude event is missing message")
    usage = message.get("usage")
    if not isinstance(usage, dict):
        raise ValueError("Claude assistant message is missing usage")
    for name in (
        "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens",
        "output_tokens", "service_tier",
    ):
        if name not in usage:
            raise ValueError(f"Claude usage is missing {name}")
    model = message.get("model")
    started_at = event.get("timestamp")
    if not isinstance(model, str) or not model:
        raise ValueError("Claude message.model must be a non-empty string")
    if not isinstance(started_at, str) or not started_at:
        raise ValueError("Claude timestamp must be a non-empty string")
    run_id = metadata.run_id or path.stem
    record = base_record(metadata, run_id=run_id, role="director", provider="claude_code",
                         model=model, started_at=started_at, authoritative=True)
    record.update({
        "input_tokens": require_non_negative_int(usage["input_tokens"], "input_tokens"),
        "cache_creation_tokens": require_non_negative_int(
            usage["cache_creation_input_tokens"], "cache_creation_input_tokens"),
        "cache_read_tokens": require_non_negative_int(
            usage["cache_read_input_tokens"], "cache_read_input_tokens"),
        "output_tokens": require_non_negative_int(usage["output_tokens"], "output_tokens"),
        "total_tokens": None,
        "telemetry_source": "claude_code",
    })
    return record


def mappings(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from mappings(child)
    elif isinstance(value, list):
        for child in value:
            yield from mappings(child)


def codex_usage_events(event: Any) -> Iterable[dict[str, Any]]:
    """Yield owners of Codex usage snapshots without relying on wrappers."""
    for candidate in mappings(event):
        if (isinstance(candidate.get("total_token_usage"), dict) or
                isinstance(candidate.get("last_token_usage"), dict)):
            yield candidate


def event_payload(event: Any) -> dict[str, Any]:
    if not isinstance(event, dict):
        return {}
    payload = event.get("payload")
    return payload if isinstance(payload, dict) else {}


def codex_model_identifier(event: Any, owner: dict[str, Any] | None = None) -> str | None:
    payload = event_payload(event)
    return first_non_empty_string(
        event.get("model") if isinstance(event, dict) else None,
        payload.get("model"),
        owner.get("model") if owner else None,
    )


def codex_started_at(event: Any, metadata: Metadata) -> str | None:
    timestamp = event.get("timestamp") if isinstance(event, dict) else None
    return first_non_empty_string(timestamp, metadata.started_at)


def codex_quota_fields(event: Any, owner: dict[str, Any]) -> dict[str, Any]:
    payload = event_payload(event)
    rate_limits = payload.get("rate_limits")
    if not isinstance(rate_limits, dict):
        rate_limits = owner.get("rate_limits")
    if not isinstance(rate_limits, dict):
        return {
            "quota_used_percent": None,
            "quota_window_minutes": None,
            "quota_resets_at": None,
            "quota_limit_id": None,
        }
    primary = rate_limits.get("primary")
    if not isinstance(primary, dict):
        primary = {}
    resets_at = nullable_integer(primary.get("resets_at"), "rate_limits.primary.resets_at")
    if resets_at is None:
        quota_resets_at = None
    else:
        try:
            quota_resets_at = datetime.fromtimestamp(resets_at, tz=timezone.utc).isoformat().replace("+00:00", "Z")
        except (OverflowError, OSError, ValueError) as error:
            raise ValueError("rate_limits.primary.resets_at is outside the supported timestamp range") from error
    return {
        "quota_used_percent": nullable_number(
            primary.get("used_percent"), "rate_limits.primary.used_percent"),
        "quota_window_minutes": nullable_integer(
            primary.get("window_minutes"), "rate_limits.primary.window_minutes"),
        "quota_resets_at": quota_resets_at,
        "quota_limit_id": nullable_string(rate_limits.get("limit_id"), "rate_limits.limit_id"),
    }


def codex_context_window(event: Any, owner: dict[str, Any]) -> int | None:
    info = event_payload(event).get("info")
    if isinstance(info, dict) and "model_context_window" in info:
        return nullable_integer(info["model_context_window"], "model_context_window")
    return nullable_integer(owner.get("model_context_window"), "model_context_window")


def codex_token_delta(owner: dict[str, Any], previous: dict[str, int] | None) -> tuple[dict[str, int], dict[str, int] | None, str]:
    """Return a per-event delta, preferring the authoritative cumulative usage.

    Codex can emit an identical token_count snapshot more than once.  Forward
    differences make the repeated snapshot a zero delta.  A lower cumulative
    value is a reset caused by a fork/resume, so its negative difference is
    clamped to zero while the new snapshot becomes the next baseline.
    """
    cumulative = owner.get("total_token_usage")
    if isinstance(cumulative, dict):
        missing = [name for name in TOKEN_FIELDS if name not in cumulative]
        if missing:
            raise ValueError("Codex total_token_usage is missing " + ", ".join(missing))
        current = {
            name: require_non_negative_int(cumulative[name], f"total_token_usage.{name}")
            for name in TOKEN_FIELDS
        }
        if previous is None:
            delta = current.copy()
        else:
            delta = {name: max(0, current[name] - previous[name]) for name in TOKEN_FIELDS}
        return delta, current, "total_token_usage_forward_difference"

    fallback = owner.get("last_token_usage")
    if not isinstance(fallback, dict):
        raise ValueError("Codex usage event is missing total_token_usage and last_token_usage")
    missing = [name for name in TOKEN_FIELDS if name not in fallback]
    if missing:
        raise ValueError("Codex last_token_usage is missing " + ", ".join(missing))
    return ({name: require_non_negative_int(fallback[name], f"last_token_usage.{name}")
             for name in TOKEN_FIELDS}, previous, "last_token_usage_fallback")


def codex_record(event: Any, owner: dict[str, Any], metadata: Metadata, path: Path,
                 session_model: str | None,
                 previous_cumulative: dict[str, int] | None) -> tuple[dict[str, Any], dict[str, int] | None]:
    model = first_non_empty_string(codex_model_identifier(event, owner), session_model,
                                   metadata.model)
    started_at = codex_started_at(event, metadata)
    if not model or not started_at:
        raise ValueError("Codex ingestion requires a source or --model identifier and a source or --started-at timestamp")
    delta, next_cumulative, delta_source = codex_token_delta(owner, previous_cumulative)
    record = base_record(metadata, run_id=metadata.run_id or path.stem, role="executor",
                         provider="codex", model=model, started_at=started_at,
                         authoritative=True)
    record.update({
        "input_tokens": require_non_negative_int(delta["input_tokens"], "input_tokens"),
        "cache_read_tokens": require_non_negative_int(
            delta["cached_input_tokens"], "cached_input_tokens"),
        "cache_creation_tokens": require_non_negative_int(
            delta["cache_write_input_tokens"], "cache_write_input_tokens"),
        "output_tokens": require_non_negative_int(delta["output_tokens"], "output_tokens"),
        "total_tokens": require_non_negative_int(delta["total_tokens"], "total_tokens"),
        "latency_ms": nullable_number(owner.get("time_to_first_token_ms"),
                                       "time_to_first_token_ms"),
        **codex_quota_fields(event, owner),
        "model_context_window": codex_context_window(event, owner),
        "telemetry_source": "codex",
        "telemetry_delta_source": delta_source,
    })
    return record, next_cumulative


def agy_record(metadata: Metadata) -> dict[str, Any]:
    if not metadata.run_id or not metadata.model or not metadata.started_at:
        raise ValueError("agy_fallback requires --run-id, --model, and --started-at metadata")
    record = base_record(metadata, run_id=metadata.run_id, role="executor", provider="agy",
                         model=metadata.model, started_at=metadata.started_at,
                         authoritative=False)
    record.update({
        "input_tokens": None,
        "output_tokens": None,
        "cache_read_tokens": None,
        "cache_creation_tokens": None,
        "total_tokens": None,
        "telemetry_source": "agy_fallback",
        "telemetry_unavailable": True,
    })
    return record


class Ledger:
    def __init__(self, state_dir: Path) -> None:
        self.state_dir = state_dir
        self.ledger_path = state_dir / "invocations.jsonl"
        self.quarantine_path = state_dir / "quarantine.jsonl"
        self.index_path = state_dir / "ingested-event-hashes.jsonl"
        self.quarantine_index_path = state_dir / "quarantine-hashes.jsonl"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.keys = self._keys(self.index_path)
        self.quarantine_keys = self._keys(self.quarantine_index_path)

    @staticmethod
    def _keys(path: Path) -> set[str]:
        if not path.exists():
            return set()
        keys: set[str] = set()
        for _, _, event, error in read_jsonl(path):
            if error is None and isinstance(event, dict) and isinstance(event.get("key"), str):
                keys.add(event["key"])
        return keys

    @staticmethod
    def _append(path: Path, value: Any) -> None:
        with APPEND_LOCK:
            with ProcessAppendLock(append_lock_path(path)):
                with path.open("a", encoding="utf-8", newline="\n") as handle:
                    handle.write(json_line(value) + "\n")

    def append(self, key: str, record: dict[str, Any]) -> bool:
        if key in self.keys:
            return False
        self._append(self.ledger_path, record)
        self._append(self.index_path, {"key": key})
        self.keys.add(key)
        return True

    def quarantine(self, key: str, *, source: Path, line_number: int,
                   reason: str, raw: str) -> bool:
        if key in self.quarantine_keys:
            return False
        self._append(self.quarantine_path, {
            "source": str(source), "line_number": line_number,
            "reason": reason, "raw": raw,
        })
        self._append(self.quarantine_index_path, {"key": key})
        self.quarantine_keys.add(key)
        return True


def event_key(source: str, path: Path | None, line_number: int, raw: str) -> str:
    location = str(path.resolve()) if path else "manual"
    payload = f"{source}\0{location}\0{line_number}\0{raw}".encode("utf-8")
    return f"{source}:sha256:{hashlib.sha256(payload).hexdigest()}"


def ingest(source: str, inputs: list[str], metadata: Metadata, state_dir: Path) -> dict[str, int]:
    ledger = Ledger(state_dir)
    summary = {"ingested": 0, "skipped": 0, "quarantined": 0}
    if source == "agy_fallback":
        record = agy_record(metadata)
        key = event_key(source, None, 1, json_line(record))
        summary["ingested" if ledger.append(key, record) else "skipped"] += 1
        return summary

    for path in input_files(inputs):
        session_model: str | None = None
        previous_cumulative: dict[str, int] | None = None
        if not path.is_file():
            key = event_key(source, path, 0, "")
            if ledger.quarantine(key, source=path, line_number=0,
                                 reason="input_file_not_found", raw=""):
                summary["quarantined"] += 1
            continue
        for line_number, raw, event, error in read_jsonl(path):
            key = event_key(source, path, line_number, raw)
            if error:
                if ledger.quarantine(key, source=path, line_number=line_number,
                                     reason=error, raw=raw):
                    summary["quarantined"] += 1
                continue
            try:
                if source == "claude_code":
                    record = claude_record(event, metadata, path)
                    records = [record]
                else:
                    session_model = codex_model_identifier(event) or session_model
                    records = []
                    for owner in codex_usage_events(event):
                        record, previous_cumulative = codex_record(
                            event, owner, metadata, path, session_model,
                            previous_cumulative)
                        records.append(record)
                    if not records:
                        continue
                for ordinal, record in enumerate(records, start=1):
                    record_key = key if len(records) == 1 else f"{key}:{ordinal}"
                    summary["ingested" if ledger.append(record_key, record) else "skipped"] += 1
            except ValueError as error:
                if ledger.quarantine(key, source=path, line_number=line_number,
                                     reason=str(error), raw=raw):
                    summary["quarantined"] += 1
    return summary


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True,
                        choices=("claude_code", "codex", "agy_fallback"))
    parser.add_argument("--input", action="append", default=[],
                        help="JSONL file or directory; repeat for multiple inputs")
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--work-unit-id", required=True)
    parser.add_argument("--run-id")
    parser.add_argument("--model")
    parser.add_argument("--started-at")
    parser.add_argument("--state-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / ".telemetry")
    args = parser.parse_args(argv)
    if args.source != "agy_fallback" and not args.input:
        parser.error("--input is required for Claude Code and Codex ingestion")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    metadata = Metadata(args.project_id, args.work_unit_id, args.run_id,
                        args.model, args.started_at)
    try:
        summary = ingest(args.source, args.input, metadata, args.state_dir)
    except LockAcquisitionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("ingested={ingested} skipped={skipped} quarantined={quarantined}".format(**summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
