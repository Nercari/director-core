#!/usr/bin/env python3
"""Assert-based synthetic checks for the explicitly non-authoritative preflight budget."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from preflight_budget import ACTION_ORDER, append_estimate, reconcile, run_estimate


def policy(root: Path, budget: int) -> Path:
    path = root / "routing-policy.yaml"
    path.write_text(
        "preflight_policy:\n"
        f"  default_budget: {budget}\n"
        "  task_class_budgets:\n"
        f"    default: {budget}\n",
        encoding="utf-8",
    )
    return path


def source(role: str, value: str) -> dict[str, str]:
    return {"kind": "string", "role": role, "value": value}


def row(value: dict) -> str:
    return json.dumps(value, sort_keys=True) + "\n"


def main() -> int:
    try:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = run_estimate("unit-a", "bounded-code-change", [source("packet", "abcdefgh")],
                                  policy(root, 1))
            assert result["authoritative"] is False
            assert result["estimate_label"] == "estimated_not_measured"
            assert "estimated_input_tokens" in result
            print("PASS: preflight output is explicitly estimated and never authoritative")

            assert result["over_budget"] is True
            under = run_estimate("unit-b", "bounded-code-change", [source("packet", "abcd")],
                                 policy(root, 2))
            assert under["over_budget"] is False
            print("PASS: over_budget follows the estimated value and policy budget")

            ordered = [item["action"] for item in result["recommended_actions"]]
            assert ordered == list(ACTION_ORDER)
            print("PASS: over-budget recommended actions preserve the declared order")

            sources = [source("packet", "abcd"), source("history", "efgh"),
                       source("tool_definitions", "ijkl")]
            breakdown = run_estimate("unit-c", "bounded-code-change", sources, policy(root, 99))
            assert len(breakdown["components"]) == len(sources)
            assert [item["role"] for item in breakdown["components"]] == ["packet", "history", "tool_definitions"]
            print("PASS: component breakdown accounts for every input source")

            missing = run_estimate("unit-d", "bounded-code-change", [
                {"kind": "file", "role": "packet", "value": str(root / "missing.txt")}
            ], policy(root, 99))
            component = missing["components"][0]
            assert missing["estimated_input_tokens"] is None and component["estimated_input_tokens"] is None
            assert component["reason"] and missing["estimate_reason"]
            print("PASS: missing input is null with a reason and never fabricated")

            unreadable_path = root / "not-utf8.bin"
            unreadable_path.write_bytes(b"\xff")
            unreadable = run_estimate("unit-e", "bounded-code-change", [
                {"kind": "file", "role": "packet", "value": str(unreadable_path)}
            ], policy(root, 99))
            assert unreadable["estimated_input_tokens"] is None
            assert unreadable["components"][0]["reason"] == "input_file_unreadable"
            print("PASS: unreadable input is null with a reason and never fabricated")

            estimates = root / "preflight-estimates.jsonl"
            ledger = root / "invocations.jsonl"
            append_estimate(estimates, result)
            ledger.write_text(row({"work_unit_id": "unit-a", "input_tokens": 2,
                                   "telemetry_authoritative": True}), encoding="utf-8")
            short = reconcile(estimates, ledger)
            assert short["sample_count"] == 1 and short["suggested_calibration_factor"] is None
            assert short["calibration_reason"] == "fewer_than_10_matched_pairs"
            print("PASS: reconciliation refuses calibration suggestions below ten matched pairs")

            estimates.write_text("".join([
                row({"work_unit_id": "joined", "estimated_input_tokens": 10}),
                row({"work_unit_id": "estimate-only", "estimated_input_tokens": 10}),
            ]), encoding="utf-8")
            ledger.write_text("".join([
                row({"work_unit_id": "joined", "input_tokens": 15, "telemetry_authoritative": True}),
                row({"work_unit_id": "ledger-only", "input_tokens": 99, "telemetry_authoritative": True}),
                row({"work_unit_id": "joined", "input_tokens": 88, "telemetry_authoritative": False}),
            ]), encoding="utf-8")
            joined = reconcile(estimates, ledger)
            assert joined["sample_count"] == 1 and joined["mean_actual_to_estimated_ratio"] == 1.5
            print("PASS: reconciliation joins by work_unit_id and ignores unmatched or non-authoritative records")

            untouched_ledger = root / "authoritative-ledger.jsonl"
            original = row({"work_unit_id": "unit-a", "input_tokens": 55, "telemetry_authoritative": True})
            untouched_ledger.write_text(original, encoding="utf-8")
            append_estimate(root / "separate-estimates.jsonl", result)
            assert untouched_ledger.read_text(encoding="utf-8") == original
            print("PASS: preflight estimates never overwrite authoritative ledger fields")
    except (AssertionError, OSError, ValueError) as error:
        print(f"FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
