#!/usr/bin/env python3
"""Synthetic self-check for the invocation-ledger adapters."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from ingest import Metadata, ingest


def write_jsonl(path: Path, lines: list[str]) -> None:
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def main() -> int:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        state = root / ".telemetry"
        metadata = Metadata("director-core", "UNIT-1", None, "gpt-test",
                            "2026-07-25T12:00:00Z")

        claude_input = root / "claude.jsonl"
        write_jsonl(claude_input, [json.dumps({
            "timestamp": "2026-07-25T12:01:00Z",
            "message": {"model": "claude-test", "usage": {
                "input_tokens": 10, "cache_creation_input_tokens": 20,
                "cache_read_input_tokens": 30, "output_tokens": 40,
                "service_tier": "standard",
            }},
        })])
        ingest("claude_code", [str(claude_input)], metadata, state)
        claude = read_jsonl(state / "invocations.jsonl")[0]
        assert claude["cache_creation_tokens"] == 20

        codex_input = root / "codex.jsonl"
        usage = {
            "input_tokens": 3, "cached_input_tokens": 4,
            "cache_write_input_tokens": 5, "output_tokens": 6,
            "reasoning_output_tokens": 7, "total_tokens": 25,
        }
        write_jsonl(codex_input, [
            json.dumps({
                "timestamp": "2026-07-25T12:03:00Z",
                "model": "gpt-event",
                "payload": {
                    "info": {
                        "total_token_usage": {**usage, "input_tokens": 300, "total_tokens": 2500},
                        "last_token_usage": usage,
                        "model_context_window": 258400,
                    },
                    "rate_limits": {
                        "limit_id": "codex",
                        "primary": {
                            "used_percent": 12.5,
                            "window_minutes": 10080,
                            "resets_at": 1785109623,
                        },
                    },
                },
            }),
            json.dumps({
                "timestamp": "2026-07-25T12:04:00Z",
                "last_token_usage": usage,
                "time_to_first_token_ms": 12,
            }),
        ])
        ingest("codex", [str(codex_input)], metadata, state)
        codex, codex_without_quota = read_jsonl(state / "invocations.jsonl")[1:3]
        assert codex["input_tokens"] == 3 and codex["total_tokens"] == 25
        assert codex["started_at"] == "2026-07-25T12:03:00Z"
        assert codex["model"] == "gpt-event"
        assert codex["quota_used_percent"] == 12.5
        assert codex["quota_window_minutes"] == 10080
        assert codex["quota_resets_at"] == "2026-07-26T23:47:03Z"
        assert codex["quota_limit_id"] == "codex"
        assert codex["model_context_window"] == 258400
        assert codex_without_quota["quota_used_percent"] is None
        assert codex_without_quota["quota_window_minutes"] is None
        assert codex_without_quota["quota_resets_at"] is None
        assert codex_without_quota["quota_limit_id"] is None
        assert codex_without_quota["model_context_window"] is None

        agy_metadata = Metadata("director-core", "UNIT-1", "agy-run", "gemini-test",
                                "2026-07-25T12:02:00Z")
        ingest("agy_fallback", [], agy_metadata, state)
        agy = read_jsonl(state / "invocations.jsonl")[3]
        assert agy["input_tokens"] is None and agy["output_tokens"] is None
        assert agy["telemetry_authoritative"] is False
        assert agy["telemetry_unavailable"] is True

        before = len(read_jsonl(state / "invocations.jsonl"))
        ingest("claude_code", [str(claude_input)], metadata, state)
        assert len(read_jsonl(state / "invocations.jsonl")) == before

        corrupt_input = root / "corrupt.jsonl"
        write_jsonl(corrupt_input, ["{not valid json"])
        result = ingest("claude_code", [str(corrupt_input)], metadata, state)
        assert result["quarantined"] == 1
        assert len(read_jsonl(state / "quarantine.jsonl")) == 1

    print("PASS: Claude Code cache creation mapping")
    print("PASS: Codex uses source timestamps and last_token_usage deltas")
    print("PASS: Codex captures quota telemetry and leaves absent fields null")
    print("PASS: agy fallback records unknown telemetry")
    print("PASS: ingestion is idempotent and corrupt input is quarantined")
    print("PASS: telemetry demo complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
