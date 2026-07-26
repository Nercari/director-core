#!/usr/bin/env python3
"""Estimate planned dispatch input size before invoking an executor.

This tool has no tokenizer or provider usage API.  Its output is therefore an
estimate only; authoritative input-token usage is captured after invocation in
the separate invocation ledger.  ``reconcile`` compares the two records but
never changes either one or applies its suggested calibration automatically.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from route_advisor import load_minimal_yaml


# Approximation for ordinary mixed English prose, source code, and JSON-like
# prompt material; character-to-token ratios vary by language and tokenizer.
CHARS_PER_TOKEN = 4
ESTIMATE_METHOD = "character_count_divided_by_chars_per_token_v1"
ESTIMATE_CONFIDENCE = "low"
ACTION_ORDER = (
    "remove_unneeded_history",
    "remove_unneeded_tool_definitions",
    "load_current_handoff",
    "retrieve_only_required_files",
    "recount",
    "split_work_unit",
    "require_context_rollover",
)


def json_line(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def estimated_tokens(character_count: int) -> int:
    """Round up a character heuristic so a non-empty source is never zero."""
    return (character_count + CHARS_PER_TOKEN - 1) // CHARS_PER_TOKEN


def source_file(role: str, path: str) -> dict[str, str]:
    return {"kind": "file", "role": role, "value": path}


def source_text(role: str, value: str) -> dict[str, str]:
    return {"kind": "string", "role": role, "value": value}


def component_for(source: dict[str, str], ordinal: int) -> dict[str, Any]:
    """Return a labelled estimate, or null and a stable reason if unavailable."""
    role = source["role"]
    if source["kind"] == "string":
        text = source["value"]
        return {
            "source": f"string:{ordinal}", "kind": "string", "role": role,
            "estimated_input_tokens": estimated_tokens(len(text)), "reason": None,
        }

    path = Path(source["value"])
    try:
        regular_file = path.is_file()
    except (OSError, ValueError):
        regular_file = False
    if not regular_file:
        return {
            "source": str(path), "kind": "file", "role": role,
            "estimated_input_tokens": None, "reason": "input_file_not_found_or_not_regular",
        }
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return {
            "source": str(path), "kind": "file", "role": role,
            "estimated_input_tokens": None, "reason": "input_file_unreadable",
        }
    return {
        "source": str(path), "kind": "file", "role": role,
        "estimated_input_tokens": estimated_tokens(len(text)), "reason": None,
    }


def read_budget(policy_path: Path, task_class: str) -> int:
    policy = load_minimal_yaml(policy_path).get("preflight_policy")
    if not isinstance(policy, dict):
        raise ValueError(f"{policy_path}: preflight_policy is required")
    default_budget = policy.get("default_budget")
    if not isinstance(default_budget, int) or isinstance(default_budget, bool) or default_budget <= 0:
        raise ValueError(f"{policy_path}: preflight_policy.default_budget must be a positive integer")
    overrides = policy.get("task_class_budgets", {})
    if not isinstance(overrides, dict):
        raise ValueError(f"{policy_path}: preflight_policy.task_class_budgets must be a mapping")
    budget = overrides.get(task_class, overrides.get("default", default_budget))
    if not isinstance(budget, int) or isinstance(budget, bool) or budget <= 0:
        raise ValueError(f"{policy_path}: task-class preflight budget must be a positive integer")
    return budget


def role_total(components: Iterable[dict[str, Any]], role: str) -> int | None:
    selected = [component["estimated_input_tokens"] for component in components
                if component["role"] == role]
    if not selected or any(value is None for value in selected):
        return None
    return sum(selected)


def recommended_actions(components: list[dict[str, Any]], over_budget: bool) -> list[dict[str, Any]]:
    if not over_budget:
        return []
    history = role_total(components, "history")
    tools = role_total(components, "tool_definitions")
    handoff = role_total(components, "handoff")
    handoff_saving = None
    if history is not None and handoff is not None:
        handoff_saving = max(0, history - handoff)
    savings = {
        "remove_unneeded_history": history,
        "remove_unneeded_tool_definitions": tools,
        "load_current_handoff": handoff_saving,
    }
    actions: list[dict[str, Any]] = []
    for index, action in enumerate(ACTION_ORDER, start=1):
        item: dict[str, Any] = {"order": index, "action": action,
                                "estimated_saving_tokens": savings.get(action)}
        if index > 5:
            item["condition"] = "if_still_over_budget_after_recount"
        actions.append(item)
    return actions


def run_estimate(work_unit_id: str, task_class: str, sources: list[dict[str, str]],
                 policy_path: Path) -> dict[str, Any]:
    components = [component_for(source, ordinal) for ordinal, source in enumerate(sources, start=1)]
    unavailable = [component["source"] for component in components
                   if component["estimated_input_tokens"] is None]
    estimate = None if unavailable else sum(component["estimated_input_tokens"] for component in components)
    budget = read_budget(policy_path, task_class)
    over_budget = estimate is not None and estimate > budget
    result: dict[str, Any] = {
        "work_unit_id": work_unit_id,
        "task_class": task_class,
        "estimated_input_tokens": estimate,
        "estimate_label": "estimated_not_measured",
        "estimate_method": ESTIMATE_METHOD,
        "estimate_confidence": ESTIMATE_CONFIDENCE if estimate is not None else "unavailable",
        "budget": budget,
        "over_budget": over_budget,
        "components": components,
        "recommended_actions": recommended_actions(components, over_budget),
        # No pre-invocation token-counting API is available; only the later
        # provider usage event in invocations.jsonl can be authoritative.
        "authoritative": False,
    }
    if unavailable:
        result["estimate_reason"] = "unavailable_component: " + ", ".join(unavailable)
    return result


def append_estimate(path: Path, result: dict[str, Any]) -> None:
    """Append a compact preflight record; never writes the invocation ledger."""
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "work_unit_id": result["work_unit_id"], "timestamp": utc_now(),
        "estimated_input_tokens": result["estimated_input_tokens"],
        "estimate_label": result["estimate_label"], "authoritative": False,
        "estimate_method": result["estimate_method"], "budget": result["budget"],
        "over_budget": result["over_budget"],
    }
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json_line(record) + "\n")


def jsonl_rows(path: Path) -> Iterable[dict[str, Any]]:
    if not path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def is_non_negative_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0


def reconcile(estimates_path: Path, ledger_path: Path) -> dict[str, Any]:
    """Compare latest usable estimate with summed authoritative input by work unit."""
    estimates: dict[str, float] = {}
    for row in jsonl_rows(estimates_path):
        work_unit_id = row.get("work_unit_id")
        estimate = row.get("estimated_input_tokens")
        if isinstance(work_unit_id, str) and work_unit_id and is_non_negative_number(estimate) and estimate > 0:
            estimates[work_unit_id] = float(estimate)
    actuals: dict[str, float] = {}
    for row in jsonl_rows(ledger_path):
        work_unit_id = row.get("work_unit_id")
        actual = row.get("input_tokens")
        if (isinstance(work_unit_id, str) and work_unit_id and
                row.get("telemetry_authoritative") is True and is_non_negative_number(actual)):
            actuals[work_unit_id] = actuals.get(work_unit_id, 0.0) + float(actual)
    ratios = [actuals[work_unit_id] / estimate for work_unit_id, estimate in estimates.items()
              if work_unit_id in actuals]
    sample_count = len(ratios)
    result: dict[str, Any] = {
        "sample_count": sample_count,
        "mean_actual_to_estimated_ratio": round(statistics.mean(ratios), 3) if ratios else None,
        "median_actual_to_estimated_ratio": round(statistics.median(ratios), 3) if ratios else None,
        "suggested_calibration_factor": None,
        "calibration_auto_applied": False,
    }
    if sample_count < 10:
        result["calibration_reason"] = "fewer_than_10_matched_pairs"
    else:
        # Median is resistant to one unusually large dispatch. It is a
        # suggestion for an operator to review, never a setting this tool uses.
        result["suggested_calibration_factor"] = result["median_actual_to_estimated_ratio"]
        result["calibration_reason"] = "suggested_only_manual_review_required"
    return result


def add_sources(parser: argparse.ArgumentParser, args: argparse.Namespace) -> list[dict[str, str]]:
    sources: list[dict[str, str]] = []
    for path in args.input_file:
        sources.append(source_file("unclassified", path))
    for text in args.input_string:
        sources.append(source_text("unclassified", text))
    for option, role in ((args.packet_file, "packet"), (args.handoff_file, "handoff"),
                         (args.history_file, "history"), (args.retrieved_file, "retrieved_file"),
                         (args.tool_definitions_file, "tool_definitions")):
        for path in option:
            sources.append(source_file(role, path))
    if not sources:
        parser.error("at least one input source is required")
    return sources


def estimate_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog="Reconcile later with: preflight_budget.sh reconcile --estimates PATH --ledger PATH",
    )
    parser.add_argument("--work-unit-id", required=True)
    parser.add_argument("--task-class", required=True)
    parser.add_argument("--input-file", action="append", default=[], metavar="PATH",
                        help="unclassified UTF-8 prompt file; repeatable")
    parser.add_argument("--input-string", action="append", default=[], metavar="TEXT",
                        help="unclassified prompt text; repeatable")
    parser.add_argument("--packet-file", action="append", default=[], metavar="PATH")
    parser.add_argument("--handoff-file", action="append", default=[], metavar="PATH")
    parser.add_argument("--history-file", action="append", default=[], metavar="PATH")
    parser.add_argument("--retrieved-file", action="append", default=[], metavar="PATH")
    parser.add_argument("--tool-definitions-file", action="append", default=[], metavar="PATH")
    parser.add_argument("--policy", type=Path, default=Path(".telemetry/routing-policy.yaml"))
    parser.add_argument("--estimates", type=Path, default=Path(".telemetry/preflight-estimates.jsonl"))
    return parser


def reconciliation_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Reconcile preflight estimates with authoritative input usage.")
    parser.add_argument("--estimates", type=Path, default=Path(".telemetry/preflight-estimates.jsonl"))
    parser.add_argument("--ledger", type=Path, default=Path(".telemetry/invocations.jsonl"))
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments and arguments[0] == "reconcile":
        args = reconciliation_parser().parse_args(arguments[1:])
        print(json_line(reconcile(args.estimates, args.ledger)))
        return 0
    parser = estimate_parser()
    args = parser.parse_args(arguments)
    result = run_estimate(args.work_unit_id, args.task_class, add_sources(parser, args), args.policy)
    append_estimate(args.estimates, result)
    print(json_line(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
