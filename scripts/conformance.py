#!/usr/bin/env python3
"""Mechanically exercise the five Phase 4 conformance scenarios.

The validator scenarios run an unchanged copy of scripts/validate-result.sh in
an isolated temporary repository.  Copying the entry point gives it a fixture
root while preserving the production validator logic under test.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR_SOURCE = ROOT / "scripts" / "validate-result.sh"
ROUTES_SOURCE = ROOT / ".director" / "routes.yaml"
WORKTREE_SOURCE = ROOT / "scripts" / "worktree.sh"
PREFLIGHT_SOURCE = ROOT / "scripts" / "preflight.sh"
JAIL = ROOT / "scripts" / "exec-jail.sh"
BASH = shutil.which("bash")
POWERSHELL = shutil.which("powershell.exe") or shutil.which("powershell")
RESTRICTED_ACCOUNT_PROBE = ROOT / "scripts" / "restricted-account-probe.ps1"
RESTRICTED_ACCOUNT_LAUNCHER = ROOT / "scripts" / "exec-as-account.ps1"
RESTRICTED_ACCOUNT_WRAPPER = ROOT / "scripts" / "run-restricted-account-probe.ps1"
RESTRICTED_ACCOUNT_LOGIN_RUNNER = ROOT / "scripts" / "login-and-run-restricted-probe.ps1"
RESTRICTED_ACCOUNT_CLEAN_BOOTSTRAP = ROOT / "scripts" / "clean-restricted-account-probe.ps1"
EXECUTOR_EVIDENCE_VALIDATOR = ROOT / "scripts" / "validate-executor-evidence.sh"
EXAMPLE_SANITIZER = ROOT / "scripts" / "check-example-sanitization.sh"
EXECUTOR_EVIDENCE_EXAMPLES = ROOT / "examples" / "executor-evidence"
EXECUTOR_EVIDENCE_SCHEMA = ROOT / "schemas" / "executor-evidence.schema.json"
CROSS_REVIEW_VALIDATOR = ROOT / "scripts" / "validate-cross-review.sh"
CROSS_REVIEW_EXAMPLES = ROOT / "examples" / "cross-review"
CROSS_REVIEW_SCHEMA = ROOT / "schemas" / "cross-review.schema.json"
BRANCH_STATE = ROOT / "scripts" / "branch-state.sh"
SANITIZER_NEGATIVE_TEMPLATE = (
    ROOT / "tests" / "sanitizer" / "executor-evidence" / "leak-case.generated.invalid.yaml.tmpl"
)

# The fixture set is canonical: one invalid fixture per rejection rule, four valid
# envelopes. A scenario asserts the set on disk still matches these tables, so a
# fixture cannot be deleted or renamed without a conformance failure naming it.
EXECUTOR_EVIDENCE_VALID_CASES = (
    "fulfilled",
    "blocked",
    "partial-blocked-test",
    "failed-command",
)

EXECUTOR_EVIDENCE_REJECT_CASES = (
    ("reject-route-unverified", "fulfilled requires route.route_verified == true"),
    (
        "reject-mutation-source-unverified",
        "fulfilled requires route.mutation_source_verified == true",
    ),
    ("reject-blocked-criterion", "fulfilled requires every acceptance criterion to be pass"),
    ("reject-failed-criterion", "fulfilled requires every acceptance criterion to be pass"),
    (
        "reject-criterion-missing-evidence",
        "fulfilled requires every acceptance criterion to carry an evidence reference",
    ),
    ("reject-forbidden-files", "fulfilled requires scope.forbidden_files_changed to be empty"),
    ("reject-diff-not-inspected", "fulfilled requires verification.diff_inspected == true"),
    (
        "reject-repo-status-not-inspected",
        "fulfilled requires verification.repo_status_inspected == true",
    ),
    (
        "reject-secret-or-external-action",
        "fulfilled requires verification.secret_or_external_action_issue == false",
    ),
    ("reject-tests-blocked", "fulfilled requires verification.tests_blocked to be empty"),
    ("reject-narrative-evidence", "evidence reference does not match"),
)

# The cross-review fixture set is canonical in the same way: every fixture is
# registered here by name, conformance uses explicit registration rather than
# discovery, and a scenario asserts the directory still matches these tables.
CROSS_REVIEW_VALID_CASES = (
    "cross-executor-review-distinct-provider",
    "cross-reviewer-executor-swapped",
    "same-provider-auxiliary-only",
    "adapter-internal-verification-auxiliary",
    "blocked-finding-prevents-promotion",
    "missing-behavior-check-not-promotion",
    "role-separated-pattern",
)

CROSS_REVIEW_REJECT_CASES = (
    ("self-review-independent", "forbids a reviewer that declares a self-review"),
    ("same-invocation-independent", "shares the executor's invocation"),
    ("same-provider-independent", "shares the executor's provider"),
    ("same-tool-independent", "shares the executor's tool"),
    ("reviewer-mutated-code", "holds mutation authority"),
    ("reviewer-not-read-only", "is not read_only"),
    (
        "adapter-internal-independent",
        "adapter_internal_verification.counts_as_independent_layer2 must always be",
    ),
    (
        "blocker-with-promotion-unblocked",
        "requires promotion.blocked_by_this_record == true",
    ),
    # No resolution machinery exists in this version, so a finding claiming
    # resolution is rejected as an unrecognised field rather than interpreted.
    ("resolved-blocker-with-promotion-unblocked", "unexpected field 'status'"),
    (
        "auxiliary-blocker-with-independence-claimed",
        "requires layer2.independent_review_satisfied == false",
    ),
    (
        "verdict-blocked-with-layer2-satisfied",
        "requires layer2.independent_review_satisfied == false",
    ),
    (
        "auto-promotion-true",
        "layer2.auto_promotion_allowed_by_this_record must always be false",
    ),
    (
        "promotion-authorized-true",
        "promotion.authorized_by_this_record must always be false",
    ),
    ("missing-executor-evidence-ref", "missing required field 'executor_evidence_ref'"),
    (
        "malformed-executor-evidence-ref",
        "evidence reference does not match the required format",
    ),
    (
        "contradictory-identity-flags",
        "declares same_provider_as_executor false, but the recorded providers are identical",
    ),
    ("tool-other-claimed-independent", "cannot be claimed when either side records tool: other"),
    (
        "provider-other-claimed-independent",
        "cannot be claimed when either side records provider: other",
    ),
    (
        "multiple-auxiliary-claim-independent",
        "multiple auxiliary reviews never aggregate into an independent one",
    ),
    ("missing-independent-review-id", "missing required field 'independent_review_id'"),
    ("independent-id-nonexistent-review", "names no review in reviews[]"),
    ("independent-id-listed-auxiliary", "also appears in auxiliary_review_ids"),
    ("duplicate-review-ids", "duplicate review_id 'review-001'"),
    (
        "independent-satisfied-false-with-nonnull-id",
        "requires independent_review_id to be null",
    ),
    ("reviewer-identity-missing", "missing required field 'provider'"),
)


@dataclass
class Command:
    returncode: int
    output: str


def run(command: Iterable[str], cwd: Optional[Path] = None) -> Command:
    """Run a bounded command and retain combined output for an assertion."""
    # encoding is pinned to utf-8 rather than left to text=True's platform
    # default. On Windows that default is cp1252 (locale.getpreferredencoding()),
    # which corrupts every multi-byte UTF-8 character the bash scripts under
    # test emit -- silently, since decode errors are not the same failure shape
    # as a real assertion mismatch. errors="replace" keeps a decoding surprise
    # from crashing the runner; a replacement character in an assertion message
    # is a visible clue, not a hidden one.
    completed = subprocess.run(
        list(command),
        cwd=str(cwd) if cwd is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=45,
        check=False,
    )
    return Command(completed.returncode, completed.stdout.decode("utf-8", errors="replace"))


def checked(command: Iterable[str], cwd: Optional[Path] = None) -> str:
    completed = run(command, cwd)
    if completed.returncode != 0:
        rendered = " ".join(command)
        raise RuntimeError(f"command failed ({completed.returncode}): {rendered}\n{completed.output}")
    return completed.output.strip()


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


class ValidatorFixture:
    """A real main repository plus a real sibling git worktree."""

    def __init__(self, unit: str) -> None:
        self._temporary_directory = tempfile.TemporaryDirectory(prefix="director-conformance-")
        self.temp = Path(self._temporary_directory.name)
        self.unit = unit
        self.root = self.temp / "fixture-repository"
        self.worktree = self.temp / f"fixture-repository-{unit}"
        self.run_directory = self.root / ".director" / "runs" / unit
        self.validator = self.root / "scripts" / "validate-result.sh"
        self.base_commit = ""

    def __enter__(self) -> "ValidatorFixture":
        try:
            self.root.mkdir()
            (self.root / ".director").mkdir()
            (self.root / "scripts").mkdir()
            (self.root / "schemas").mkdir()
            shutil.copy2(ROUTES_SOURCE, self.root / ".director" / "routes.yaml")
            shutil.copy2(VALIDATOR_SOURCE, self.validator)
            shutil.copy2(ROOT / "schemas" / "result.schema.json", self.root / "schemas" / "result.schema.json")
            if self.validator.read_bytes() != VALIDATOR_SOURCE.read_bytes():
                raise RuntimeError("fixture validator differs from scripts/validate-result.sh")

            checked(["git", "init", "--initial-branch=main", str(self.root)])
            checked(["git", "-C", str(self.root), "config", "user.email", "conformance@example.invalid"])
            checked(["git", "-C", str(self.root), "config", "user.name", "Conformance fixture"])
            write_text(self.root / "README.md", "fixture main branch\n")
            checked(["git", "-C", str(self.root), "add", "README.md"])
            checked(["git", "-C", str(self.root), "commit", "-m", "fixture base"])
            self.base_commit = checked(["git", "-C", str(self.root), "rev-parse", "main"])
            checked(
                [
                    "git",
                    "-C",
                    str(self.root),
                    "worktree",
                    "add",
                    "-b",
                    f"task/{self.unit}",
                    str(self.worktree),
                    "main",
                ]
            )
            return self
        except Exception:
            self.close()
            raise

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.close()

    def close(self) -> None:
        self._temporary_directory.cleanup()

    def modify_files(self, files: dict[str, str]) -> None:
        if not files:
            raise RuntimeError("fixture change requires at least one file")
        for relative_path, content in files.items():
            write_text(self.worktree / relative_path, content)

    def write_packet(
        self,
        allowed_paths: Iterable[str],
        required_tests: Iterable[str],
        forbidden_paths: Iterable[str] = (),
    ) -> None:
        allowed = list(allowed_paths)
        tests = list(required_tests)
        forbidden = list(forbidden_paths)
        if not allowed:
            raise RuntimeError("fixture packet requires declared paths")
        packet = ["allowed_paths:"]
        packet.extend(f"  - {path}" for path in allowed)
        if forbidden:
            packet.append("forbidden_paths:")
            packet.extend(f"  - {path}" for path in forbidden)
        packet.append("required_tests:")
        packet.extend(f"  - {test}" for test in tests)
        write_text(self.run_directory / "packet.yaml", "\n".join(packet) + "\n")
        write_text(self.run_directory / "worktree.yaml", f"base_commit: {self.base_commit}\n")

    def write_result(self, tests_run: Iterable[str]) -> None:
        result = {
            "status": "completed",
            "branch": f"task/{self.unit}",
            "route_used": "DIRECT",
            "summary": "conformance fixture",
            "files_changed": [],
            "tests_run": list(tests_run),
            "tests_passed": list(tests_run),
            "tests_failed": [],
            "unresolved_risks": [],
            "deviations_from_plan": [],
            "wall_time_seconds": 0,
        }
        write_text(self.run_directory / "result.json", json.dumps(result) + "\n")

    def write_raw_result(self, result: dict[str, object]) -> None:
        write_text(self.run_directory / "result.json", json.dumps(result) + "\n")

    def validate(self) -> Command:
        if BASH is None:
            raise RuntimeError("bash is required to execute scripts/validate-result.sh")
        return run([BASH, str(self.validator), self.unit], self.root)


def expect_validator_reject(
    fixture: ValidatorFixture, expected_reason: str
) -> tuple[bool, str]:
    result = fixture.validate()
    if result.returncode != 1:
        return False, f"validator exited {result.returncode}, expected 1"
    if expected_reason not in result.output:
        return False, f"validator omitted expected reason: {expected_reason}"
    return True, expected_reason


def expect_validator_accept(fixture: ValidatorFixture, expected_reason: str) -> tuple[bool, str]:
    result = fixture.validate()
    if result.returncode != 0:
        return False, f"validator exited {result.returncode}, expected 0: {result.output}"
    if expected_reason not in result.output:
        return False, f"validator omitted expected reason: {expected_reason}"
    return True, expected_reason


def expect_validator_stopped(
    fixture: ValidatorFixture, expected_exit_code: int, expected_line: str
) -> tuple[bool, str]:
    result = fixture.validate()
    if result.returncode != expected_exit_code:
        return (
            False,
            f"validator exited {result.returncode}, expected {expected_exit_code}: {result.output}",
        )
    if expected_line not in result.output:
        return False, f"validator omitted expected line: {expected_line}"
    return True, expected_line


def scenario_one() -> tuple[bool, str]:
    try:
        with ValidatorFixture("uncommitted-reviewed-diff") as fixture:
            fixture.modify_files({"allowed.txt": "executor leaves an uncommitted diff\n"})
            fixture.write_packet(["allowed.txt"], ["test -f allowed.txt"])
            fixture.write_result(["test -f allowed.txt"])
            return expect_validator_accept(
                fixture, "status=completed (working-tree diff awaits orchestrator review)"
            )
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_two(break_fixture: bool) -> tuple[bool, str]:
    try:
        with ValidatorFixture("outside-declared-scope") as fixture:
            fixture.modify_files(
                {"allowed.txt": "within scope\n", "forbidden.txt": "outside scope\n"}
            )
            allowed_paths = ["allowed.txt", "forbidden.txt"] if break_fixture else ["allowed.txt"]
            fixture.write_packet(allowed_paths, ["test -f allowed.txt"])
            fixture.write_result(["test -f allowed.txt"])
            return expect_validator_reject(
                fixture, "files changed outside declared paths — REJECT:"
            )
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_three() -> tuple[bool, str]:
    try:
        with ValidatorFixture("required-test-skipped") as fixture:
            fixture.modify_files({"allowed.txt": "test must be reported\n"})
            fixture.write_packet(["allowed.txt"], ["test -f allowed.txt"])
            fixture.write_result([])
            return expect_validator_reject(
                fixture,
                "required tests declared but none run, and no blocker reported — REJECT",
            )
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_stopped_terminal_outcomes() -> tuple[bool, str]:
    # The blocked arm carries a substantive unresolved risk because a blocked
    # result that names nothing is now rejected rather than stopped — see
    # scenario_blocked_states_what_it_hit. This fixture exists to assert the
    # terminal treatment, not the absence of that obligation, so it states a
    # risk rather than asserting the old behaviour.
    risks_for = {
        "blocked": ["the declared fixture path does not exist"],
        "failed": [],
    }
    try:
        for status in ("blocked", "failed"):
            with ValidatorFixture(f"stopped-{status}") as fixture:
                fixture.modify_files({"allowed.txt": f"{status} result\n"})
                fixture.write_packet(["allowed.txt"], [])
                fixture.write_raw_result(
                    {
                        "status": status,
                        "branch": f"task/stopped-{status}",
                        "route_used": "EXEC_STRONG",
                        "summary": "conformance fixture stopped",
                        "files_changed": ["allowed.txt"],
                        "tests_run": [],
                        "tests_passed": [],
                        "tests_failed": [],
                        "unresolved_risks": risks_for[status],
                        "deviations_from_plan": [],
                        "wall_time_seconds": 0,
                    }
                )
                expected_line = (
                    f"STOPPED: status={status}. "
                    "Nothing is authorised to leave this machine."
                )
                passed, reason = expect_validator_stopped(fixture, 2, expected_line)
                if not passed:
                    return False, f"{status}: {reason}"
        return True, "blocked and failed produce distinct stopped outcomes with exit 2"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_blocked_states_what_it_hit() -> tuple[bool, str]:
    """A blocked result must say what it hit, in content and not merely in count.

    The schema admits the empty string, so a length-only check passes on [""]
    and on ["   "]: a placeholder satisfies the requirement while carrying no
    information. Stopping must not become a way to say nothing.
    """
    reject_line = "status=blocked with no substantive unresolved_risks entry — REJECT"
    # A sentinel distinct from every JSON value, so "the key is absent" is a
    # case in its own right rather than a synonym for the empty list.
    omitted = object()
    empty_cases = (
        ("key-omitted", omitted),
        ("null", None),
        ("empty-list", []),
        # Not strings. The schema rejects these, so the gate only has to avoid
        # counting them as a stated risk.
        ("number-entry", [42]),
        ("nested-array", [["a risk"]]),
        ("null-entry", [None]),
        ("empty-string", [""]),
        ("whitespace-only", ["   "]),
        # Renders as nothing but is not matched by \s. A placeholder that
        # looks empty must not satisfy an obligation to state something.
        ("zero-width", ["​"]),
        ("byte-order-mark", ["﻿"]),
        ("non-breaking-space", [" "]),
    )

    def raw(unit: str, status: str, risks: object) -> dict:
        body = {
            "status": status,
            "branch": f"task/{unit}",
            "route_used": "EXEC_STRONG",
            "summary": f"conformance fixture {status}",
            "files_changed": ["allowed.txt"],
            "tests_run": [],
            "tests_passed": [],
            "tests_failed": [],
            "unresolved_risks": risks,
            "deviations_from_plan": [],
            "wall_time_seconds": 0,
        }
        if risks is omitted:
            del body["unresolved_risks"]
        return body

    try:
        # Every empty form is exercised before reporting. Returning on the
        # first failure would evidence only one form under a revert probe,
        # leaving the rest inferred rather than demonstrated.
        empty_failures = []
        for label, risks in empty_cases:
            unit = f"blocked-risks-{label}"
            with ValidatorFixture(unit) as fixture:
                fixture.modify_files({"allowed.txt": f"{label}\n"})
                fixture.write_packet(["allowed.txt"], [])
                fixture.write_raw_result(raw(unit, "blocked", risks))
                passed, reason = expect_validator_reject(fixture, reject_line)
                if not passed:
                    empty_failures.append(f"{label}: {reason}")
        if empty_failures:
            return False, "; ".join(empty_failures)

        # A blocked result that does say what it hit keeps the terminal
        # treatment: stopped with exit 2, neither rejected nor validated.
        # Leading and trailing whitespace around real content must not count
        # against it — the check is on substance, not on formatting.
        unit = "blocked-risks-substantive"
        with ValidatorFixture(unit) as fixture:
            fixture.modify_files({"allowed.txt": "substantive\n"})
            fixture.write_packet(["allowed.txt"], [])
            fixture.write_raw_result(
                raw(unit, "blocked", ["  the declared fixture path does not exist  "])
            )
            passed, reason = expect_validator_stopped(
                fixture,
                2,
                "STOPPED: status=blocked. Nothing is authorised to leave this machine.",
            )
            if not passed:
                return False, f"substantive: {reason}"

        # failed is deliberately out of scope for this obligation. An empty
        # list must still stop rather than reject, or the change has widened
        # past its ticket.
        unit = "failed-risks-empty"
        with ValidatorFixture(unit) as fixture:
            fixture.modify_files({"allowed.txt": "failed\n"})
            fixture.write_packet(["allowed.txt"], [])
            fixture.write_raw_result(raw(unit, "failed", []))
            passed, reason = expect_validator_stopped(
                fixture,
                2,
                "STOPPED: status=failed. Nothing is authorised to leave this machine.",
            )
            if not passed:
                return False, f"failed unaffected: {reason}"

        # completed is likewise untouched.
        unit = "completed-risks-empty"
        with ValidatorFixture(unit) as fixture:
            fixture.modify_files({"allowed.txt": "completed\n"})
            fixture.write_packet(["allowed.txt"], [])
            fixture.write_raw_result(raw(unit, "completed", []))
            passed, reason = expect_validator_accept(
                fixture, "VALIDATED — safe to review, push, and open a pull request."
            )
            if not passed:
                return False, f"completed unaffected: {reason}"

        return True, "blocked must name a substantive risk; failed and completed unaffected"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_defect_one_lock_owner() -> tuple[bool, str]:
    """Removing beta must not release the lock created by alpha."""
    if BASH is None:
        return False, "bash is required to exercise scripts/worktree.sh"
    try:
        with tempfile.TemporaryDirectory(prefix="director-worktree-lock-") as temporary:
            temp = Path(temporary)
            root = temp / "fixture-repository"
            worktree_script = root / "scripts" / "worktree.sh"
            root.mkdir()
            worktree_script.parent.mkdir()
            (root / ".director").mkdir()
            shutil.copy2(WORKTREE_SOURCE, worktree_script)
            checked(["git", "init", "--initial-branch=main", str(root)])
            checked(["git", "-C", str(root), "config", "user.email", "conformance@example.invalid"])
            checked(["git", "-C", str(root), "config", "user.name", "Conformance fixture"])
            write_text(root / "README.md", "fixture main branch\n")
            checked(["git", "-C", str(root), "add", "README.md"])
            checked(["git", "-C", str(root), "commit", "-m", "fixture base"])

            created = run([BASH, str(worktree_script), "create", "alpha"], root)
            if created.returncode != 0:
                return False, f"could not create alpha fixture worktree: {created.output}"
            active = root / ".director" / "active-worktree"
            if not active.is_file():
                return False, "creating alpha did not write active-worktree"
            expected_parent = checked([BASH, "-c", 'cd "$1/.." && pwd', "--", str(root)])
            expected_worktree = f"{expected_parent}/fixture-repository-alpha"
            if active.read_text(encoding="utf-8").strip() != expected_worktree:
                return False, "active-worktree did not name alpha's absolute worktree path"
            removed = run([BASH, str(worktree_script), "remove", "beta"], root)
            lock = root / ".director" / "worktree.lock"
            if not lock.is_dir():
                return False, "removing beta released alpha's lock"
            if not active.is_file():
                return False, "removing beta deleted alpha's active-worktree"
            if "belongs to alpha" not in removed.output:
                return False, "removing beta did not report the lock owner"
            cleaned = run([BASH, str(worktree_script), "remove", "alpha"], root)
            if cleaned.returncode != 0:
                return False, f"could not clean alpha fixture worktree: {cleaned.output}"
            if active.exists():
                return False, "removing alpha did not delete active-worktree"
            return True, "worktree lifecycle writes active-worktree and only its owner removes it"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_defect_two_missing_base_commit() -> tuple[bool, str]:
    try:
        with ValidatorFixture("missing-base-commit") as fixture:
            fixture.modify_files({"allowed.txt": "within declared scope\n", "FORBIDDEN.txt": "outside declared scope\n"})
            fixture.write_packet(["allowed.txt"], ["test -f allowed.txt"])
            write_text(fixture.run_directory / "worktree.yaml", "unit_id: missing-base-commit\n")
            fixture.write_result(["test -f allowed.txt"])
            return expect_validator_reject(
                fixture, "base_commit is missing or empty — REJECT"
            )
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_defect_three_result_invariants() -> tuple[bool, str]:
    cases = (
        ("unknown-status", {"status": "not-completed"}, "status=not-completed is not allowed — REJECT"),
        ("bad-branch", {"status": "blocked", "branch": "main", "route_used": "DIRECT"}, "branch=main does not match task/<unit-id> — REJECT"),
        ("missing-route", {"status": "blocked", "branch": "task/missing-route"}, "route_used is missing or empty — REJECT"),
        ("forbidden-key", {"status": "blocked", "branch": "task/forbidden-key", "route_used": "DIRECT", "pull_request_url": "https://example.invalid/pr/1"}, "result contains forbidden key pull_request_url — REJECT"),
    )
    try:
        for unit, result, expected in cases:
            with ValidatorFixture(unit) as fixture:
                fixture.write_raw_result(result)
                passed, reason = expect_validator_reject(fixture, expected)
                if not passed:
                    return False, f"{unit}: {reason}"
        return True, "fallback validation rejects invalid status, branch, route, and forbidden keys"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_result_route_used_closed_enum() -> tuple[bool, str]:
    try:
        for unit, route, accepted in (
            ("invalid-route-used", "tool", False),
            ("valid-exec-strong-route", "EXEC_STRONG", True),
        ):
            with ValidatorFixture(unit) as fixture:
                fixture.modify_files({"allowed.txt": "route fixture\n"})
                fixture.write_packet(["allowed.txt"], [])
                fixture.write_raw_result(
                    {
                        "status": "completed",
                        "branch": f"task/{unit}",
                        "route_used": route,
                        "summary": "conformance fixture",
                    }
                )
                if accepted:
                    passed, reason = expect_validator_accept(
                        fixture, f"route_used={route} is authorised"
                    )
                else:
                    passed, reason = expect_validator_reject(
                        fixture, f"route_used={route} is not allowed"
                    )
                if not passed:
                    return False, f"{unit}: {reason}"
        return True, "route_used rejects tool and accepts EXEC_STRONG"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_removed_route_is_not_authorised() -> tuple[bool, str]:
    """EXEC_LOCAL was deleted; a result declaring it must not pass authorisation."""
    try:
        with ValidatorFixture("removed-route-rejected") as fixture:
            fixture.modify_files({"allowed.txt": "in scope\n"})
            fixture.write_packet(["allowed.txt"], [])
            fixture.write_raw_result(
                {
                    "status": "completed",
                    "branch": "task/removed-route-rejected",
                    "route_used": "EXEC_LOCAL",
                    "summary": "conformance fixture",
                }
            )
            return expect_validator_reject(
                fixture, "route_used=EXEC_LOCAL is not allowed"
            )
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_forbidden_paths_deny_before_allow() -> tuple[bool, str]:
    """A deny glob beats an allow glob that also matches the same file."""
    try:
        with ValidatorFixture("deny-beats-allow") as fixture:
            fixture.modify_files({"scripts/gate.sh": "executor edited the gate\n"})
            fixture.write_packet(["scripts/*"], [], forbidden_paths=["scripts/gate.sh"])
            fixture.write_result([])
            passed, reason = expect_validator_reject(
                fixture, "files changed inside forbidden_paths — REJECT:"
            )
            if not passed:
                return False, reason
            output = fixture.validate().output
            if "scripts/gate.sh (matched forbidden_paths glob: scripts/gate.sh)" not in output:
                return False, "rejection did not name the path and the deny glob that matched it"
        return True, "a path matching both lists is denied, and the matching glob is named"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_forbidden_paths_ambiguous_declaration() -> tuple[bool, str]:
    """The same glob in both lists is rejected, not resolved in either direction."""
    try:
        with ValidatorFixture("ambiguous-scope") as fixture:
            fixture.modify_files({"allowed.txt": "in scope by one reading\n"})
            fixture.write_packet(["allowed.txt"], [], forbidden_paths=["allowed.txt"])
            fixture.write_result([])
            return expect_validator_reject(
                fixture,
                "ambiguous scope declaration — the same path is in both allowed_paths "
                "and forbidden_paths — REJECT:",
            )
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_forbidden_paths_no_match_still_validates() -> tuple[bool, str]:
    """A deny list that matches nothing must not narrow an otherwise valid unit."""
    try:
        with ValidatorFixture("deny-list-unmatched") as fixture:
            fixture.modify_files({"allowed.txt": "ordinary in-scope change\n"})
            fixture.write_packet(["allowed.txt"], [], forbidden_paths=[".github/*"])
            fixture.write_result([])
            return expect_validator_accept(
                fixture, "all changed files within declared paths and outside forbidden_paths"
            )
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_required_tests_take_no_shell() -> tuple[bool, str]:
    """Metacharacters in a required test are arguments, not a second command."""
    try:
        with ValidatorFixture("required-tests-no-shell") as fixture:
            fixture.modify_files({"allowed.txt": "in scope\n"})
            side_effect = fixture.worktree / "SIDE-EFFECT.txt"
            payload = f"python --version; touch {side_effect.name}"
            fixture.write_packet(["allowed.txt"], [payload])
            fixture.write_result([payload])
            passed, reason = expect_validator_reject(fixture, "re-run FAILED:")
            if not passed:
                return False, reason
            if side_effect.exists():
                return False, "the metacharacter payload's side effect occurred"
        return True, "a metacharacter payload fails and produces no side effect"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_required_tests_are_bounded() -> tuple[bool, str]:
    """A test that outruns the bound fails the unit instead of hanging the gate."""
    previous = os.environ.get("DIRECTOR_TEST_TIMEOUT")
    os.environ["DIRECTOR_TEST_TIMEOUT"] = "2"
    try:
        with ValidatorFixture("required-tests-bounded") as fixture:
            fixture.modify_files({"allowed.txt": "in scope\n"})
            # No shell, so the -c source has to survive whitespace splitting as
            # a single token. Nothing interprets the quotes or the parentheses.
            slow = "python -c __import__('time').sleep(30)"
            fixture.write_packet(["allowed.txt"], [slow])
            fixture.write_result([slow])
            return expect_validator_reject(fixture, "re-run TIMED OUT after 2s:")
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"
    finally:
        if previous is None:
            os.environ.pop("DIRECTOR_TEST_TIMEOUT", None)
        else:
            os.environ["DIRECTOR_TEST_TIMEOUT"] = previous


def scenario_required_tests_ordinary_entries_pass() -> tuple[bool, str]:
    """The two-token shape every packet actually uses still runs and passes."""
    try:
        with ValidatorFixture("required-tests-ordinary") as fixture:
            fixture.modify_files({"allowed.txt": "in scope\n"})
            fixture.write_packet(["allowed.txt"], ["python --version"])
            fixture.write_result(["python --version"])
            passed, reason = expect_validator_accept(fixture, "re-ran: python --version")
            if not passed:
                return False, reason
            evidence = list((fixture.run_directory / "evidence").glob("*.log"))
            if not evidence:
                return False, "raw per-test output was not preserved as evidence"
        return True, "an ordinary two-token entry runs, passes, and leaves its raw output"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def preflight_fixture_routes(primary_block: str) -> str:
    # Every route must declare runs_as or preflight fails it, so the fixture
    # supplies the operator default. A block that declares its own identity
    # keeps it — that is how the identity scenarios below inject a claim.
    if "runs_as:" not in primary_block:
        primary_block = "    runs_as: operator\n" + primary_block
    return f"""routes:
  ORCH_PRIMARY:
    model: default
    runs_as: operator
    last_verified: 2026-07-26
  ORCH_FALLBACK:
    model: default
    runs_as: operator
    last_verified: 2026-07-26
  EXEC_PRIMARY:
{primary_block}
  EXEC_STRONG:
    model: default
    runs_as: operator
    last_verified: 2026-07-26
"""


def run_preflight_with_routes(routes: str) -> Command:
    if BASH is None:
        raise RuntimeError("bash is required to exercise scripts/preflight.sh")
    with tempfile.TemporaryDirectory(prefix="director-preflight-") as temporary:
        temp = Path(temporary)
        root = temp / "fixture-repository"
        scripts = root / "scripts"
        fake_bin = temp / "bin"
        scripts.mkdir(parents=True)
        fake_bin.mkdir()
        shutil.copy2(PREFLIGHT_SOURCE, scripts / "preflight.sh")
        write_text(root / ".director" / "routes.yaml", routes)
        checked(["git", "init", "--initial-branch=main", str(root)])
        checked(["git", "-C", str(root), "config", "user.email", "conformance@example.invalid"])
        checked(["git", "-C", str(root), "config", "user.name", "Conformance fixture"])
        write_text(root / "README.md", "fixture\n")
        checked(["git", "-C", str(root), "add", "README.md"])
        checked(["git", "-C", str(root), "commit", "-m", "fixture base"])
        write_text(fake_bin / "codex", "#!/usr/bin/env bash\necho 'Logged in using ChatGPT'\n")
        write_text(fake_bin / "claude", "#!/usr/bin/env bash\nexit 0\n")
        write_text(fake_bin / "agy", "#!/usr/bin/env bash\nexit 0\n")
        write_text(fake_bin / "gh", "#!/usr/bin/env bash\nif [ \"$1\" = auth ]; then exit 0; fi\nif [ \"$1\" = api ]; then echo 'X-Oauth-Scopes: repo, workflow'; exit 0; fi\nexit 1\n")
        for executable in fake_bin.iterdir():
            executable.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
        completed = subprocess.run(
            [BASH, str(scripts / "preflight.sh")],
            cwd=str(root),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=45,
            check=False,
            env=env,
        )
        return Command(completed.returncode, completed.stdout)


def run_preflight_fixture(primary_block: str) -> Command:
    return run_preflight_with_routes(preflight_fixture_routes(primary_block))


def scenario_defect_four_forbidden_model() -> tuple[bool, str]:
    try:
        result = run_preflight_fixture(
            "    model: claude-3-7-sonnet\n    forbidden_models:\n      - \"claude-*\"\n    last_verified: 2026-07-26\n"
        )
        if result.returncode == 0:
            return False, "preflight accepted a model matching its forbidden_models pattern"
        if "claude-3-7-sonnet matches forbidden_models pattern claude-*" not in result.output:
            return False, "preflight did not name the forbidden model and pattern"
        return True, "preflight rejects a forbidden executor model"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_defect_five_future_verification() -> tuple[bool, str]:
    try:
        result = run_preflight_fixture(
            "    model: gemini-fixture\n    last_verified: 2099-01-01\n"
        )
        if result.returncode == 0:
            return False, "preflight accepted a future last_verified date"
        if "EXEC_PRIMARY last_verified is in the future: 2099-01-01" not in result.output:
            return False, "preflight did not identify the future verification date"
        return True, "preflight rejects a future last_verified date"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_route_availability() -> tuple[bool, str]:
    routes = """routes:
  ORCH_PRIMARY:
    model: default
    runs_as: operator
    last_verified: 2026-07-26
  ORCH_FALLBACK:
    model: default
    runs_as: operator
    last_verified: 2026-07-26
  EXEC_PRIMARY:
    model: primary-fixture
    runs_as: operator
    quarantined: false
    jail_verified: true
    last_verified: 2026-07-26
  EXEC_STRONG:
    model: strong-fixture
    runs_as: operator
    invoke: scripts/exec-jail.sh strong-fixture
    quarantined: false
    jail_verified: true
    last_verified: 2026-07-26
"""
    try:
        result = run_preflight_with_routes(routes)
        if result.returncode != 0:
            return False, f"availability declarations made preflight exit {result.returncode}"
        expected_lines = (
            "EXEC_PRIMARY route unusable: invoke key absent",
            "EXEC_STRONG route usable",
        )
        missing = [line for line in expected_lines if line not in result.output]
        if missing:
            return False, f"preflight omitted availability verdict: {missing[0]}"
        return True, "preflight distinguishes unusable route reasons and confirms a usable route"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_route_availability_gate() -> tuple[bool, str]:
    all_quarantined_routes = """routes:
  ORCH_PRIMARY:
    model: default
    runs_as: operator
    last_verified: 2026-07-26
  ORCH_FALLBACK:
    model: default
    runs_as: operator
    last_verified: 2026-07-26
  EXEC_PRIMARY:
    model: primary-fixture
    runs_as: operator
    invoke: scripts/exec-jail.sh primary-fixture
    quarantined: true
    jail_verified: true
    last_verified: 2026-07-26
  EXEC_STRONG:
    model: strong-fixture
    runs_as: operator
    invoke: scripts/exec-jail.sh strong-fixture
    quarantined: true
    jail_verified: true
    last_verified: 2026-07-26
"""
    usable_strong_route = all_quarantined_routes.replace(
        """  EXEC_STRONG:
    model: strong-fixture
    runs_as: operator
    invoke: scripts/exec-jail.sh strong-fixture
    quarantined: true
    jail_verified: true
""",
        """  EXEC_STRONG:
    model: strong-fixture
    runs_as: operator
    invoke: scripts/exec-jail.sh strong-fixture
    quarantined: false
    jail_verified: true
""",
    )
    try:
        unavailable = run_preflight_with_routes(all_quarantined_routes)
        if unavailable.returncode == 0:
            return False, "preflight accepted a registry with zero usable executor routes"
        expected_line = "zero usable executor routes; preflight cannot launch work"
        if expected_line not in unavailable.output:
            return False, "preflight did not name the zero-usable-route launch failure"

        available = run_preflight_with_routes(usable_strong_route)
        if available.returncode != 0:
            return False, f"preflight rejected a registry with EXEC_STRONG usable: {available.output}"
        return True, "preflight rejects zero usable executor routes and accepts one usable route"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_runs_as_claim_must_match_effective_user() -> tuple[bool, str]:
    """A route may not claim the restricted account this session does not have.

    Both directions go through the existing preflight fixture seam: the fixture
    registry is the input and the process's real user is the comparison, so no
    mock of the environment is introduced. The suite is not run as director-exec,
    which is exactly the condition the claim must fail under.
    """
    try:
        effective_user = os.environ.get("USERNAME") or os.environ.get("USER") or ""
        if effective_user == "director-exec":
            return None, "suite is running as director-exec; the mismatch direction cannot be exercised"

        claimed = run_preflight_fixture(
            "    model: gemini-fixture\n    runs_as: director-exec\n    last_verified: 2026-07-26\n"
        )
        if claimed.returncode == 0:
            return False, "preflight accepted a route claiming director-exec from another account"
        if "EXEC_PRIMARY declares runs_as: director-exec but the effective user is" not in claimed.output:
            return False, "preflight did not name the identity mismatch"

        # The matching direction asserts a GREEN preflight, so this block also
        # has to be a usable route — otherwise the run fails on "zero usable
        # executor routes" and the identity check is never what decided it.
        matching = run_preflight_fixture(
            "    model: gemini-fixture\n"
            "    runs_as: operator\n"
            "    invoke: scripts/exec-jail.sh gemini-fixture\n"
            "    quarantined: false\n"
            "    jail_verified: true\n"
            "    last_verified: 2026-07-26\n"
        )
        if matching.returncode != 0:
            return False, f"preflight rejected a route whose declared identity matches: {matching.output}"
        if "EXEC_PRIMARY runs_as operator, matching effective user" not in matching.output:
            return False, "preflight did not confirm the matching identity"
        return True, "preflight fails a director-exec claim and passes a matching operator claim"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


def scenario_runs_as_is_required() -> tuple[bool, str]:
    """A route with no declared identity is not a route with a default identity."""
    try:
        result = run_preflight_fixture(
            "    model: gemini-fixture\n    runs_as:\n    last_verified: 2026-07-26\n"
        )
        if result.returncode == 0:
            return False, "preflight accepted a route with no declared runs_as"
        if "EXEC_PRIMARY has no usable runs_as" not in result.output:
            return False, "preflight did not name the missing identity declaration"
        return True, "preflight rejects a route that declares no identity"
    except Exception as error:
        return False, f"fixture could not be built or exercised: {error}"


@dataclass(frozen=True)
class AttributionCase:
    name: str
    observable_outcome: bool
    behavior_check_distinguishes: bool
    failures_on_same_diagnosis: int
    expected_decision: str
    expected_route_change_valid: bool


def attribution_decision(case: AttributionCase) -> tuple[str, bool]:
    """Apply blueprint section 13.2 in its mandated question order."""
    if not case.observable_outcome:
        return "REJECT and re-slice", False
    if not case.behavior_check_distinguishes:
        return "REJECT and re-slice", False
    if case.failures_on_same_diagnosis >= 2:
        return "ESCALATE", True
    return "FOCUSED_CORRECTION", False


def scenario_four() -> tuple[bool, str]:
    cases = (
        AttributionCase(
            "second failure: criterion has no observable outcome",
            False,
            True,
            2,
            "REJECT and re-slice",
            False,
        ),
        AttributionCase(
            "second failure: behavior check passes on broken state",
            True,
            False,
            2,
            "REJECT and re-slice",
            False,
        ),
        AttributionCase(
            "second search failure after two valid answers",
            True,
            True,
            2,
            "ESCALATE",
            True,
        ),
    )
    for case in cases:
        decision, route_change_valid = attribution_decision(case)
        if decision != case.expected_decision:
            return False, f"{case.name}: got {decision}, expected {case.expected_decision}"
        if route_change_valid != case.expected_route_change_valid:
            return False, f"{case.name}: route-change validity was wrong"
        objective_failure = not case.observable_outcome or not case.behavior_check_distinguishes
        if objective_failure and (decision == "ESCALATE" or route_change_valid):
            return False, f"{case.name}: objective failure incorrectly allowed a route change"
    return True, "objective second failures reject and re-slice; route change is invalid"


def authenticated_status(result: Command) -> bool:
    lowered = result.output.lower()
    return result.returncode == 0 and "not logged" not in lowered and "logged in" in lowered


def authenticated_user_json(result: Command) -> bool:
    if result.returncode != 0:
        return False
    try:
        payload = json.loads(result.output)
    except json.JSONDecodeError:
        return False
    return isinstance(payload, dict) and isinstance(payload.get("login"), str) and bool(payload["login"])


def authentication_refusal(result: Command) -> bool:
    lowered = result.output.lower()
    markers = (
        "not logged",
        "gh auth login",
        "authentication failed",
        "bad credentials",
        "could not read username",
        "terminal prompts disabled",
        "no credentials",
        "permission denied",
        "denied",
        # gh's own GitHub Actions detection: inside a workflow it refuses with
        # this message instead of any of the markers above, even though it is
        # exactly as much a refusal. Confirmed live on ubuntu-latest: this
        # scenario failed there with gh genuinely unauthenticated, jailed and
        # unjailed alike, purely because this marker was missing.
        "set the gh_token environment variable",
    )
    return result.returncode != 0 and any(marker in lowered for marker in markers)


def scenario_five() -> tuple[Optional[bool], str]:
    if not JAIL.is_file():
        return False, "required scripts/exec-jail.sh is missing"
    if BASH is None:
        return False, "bash is required to probe scripts/exec-jail.sh"
    # This is the only scenario that probes the host's real gate credentials
    # rather than a fixture, so it is the only one whose prerequisite can be
    # legitimately absent. Reported as SKIP, not PASS: a machine without gh has
    # not verified the jail, and must not be told that it has.
    if shutil.which("gh") is None:
        return None, "SKIPPED: gh absent, so gate-capability removal cannot be probed here"

    try:
        branch = f"refs/heads/director-conformance-baseline-{os.getpid()}"
        jailed_status = run([BASH, str(JAIL), "gh", "auth", "status"], ROOT)
        jailed_api = run([BASH, str(JAIL), "gh", "api", "user"], ROOT)
        jailed_push = run([BASH, str(JAIL), "git", "push", "--dry-run", "origin", f"HEAD:{branch}"], ROOT)
        jailed_dns = run(
            [
                BASH,
                str(JAIL),
                sys.executable,
                "-c",
                "import socket; socket.getaddrinfo('github.com', 443)",
            ],
            ROOT,
        )

        baseline_status = run(["gh", "auth", "status"], ROOT)
        baseline_api = run(["gh", "api", "user"], ROOT)
        baseline_push = run(["git", "push", "--dry-run", "origin", f"HEAD:{branch}"], ROOT)
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, f"capability probe could not run: {error}"

    failures = []
    if not authentication_refusal(jailed_status):
        failures.append("jailed gh auth status did not prove unauthenticated")
    if not authentication_refusal(jailed_api):
        failures.append("jailed gh api user did not refuse authenticated JSON")
    if not authentication_refusal(jailed_push):
        failures.append("jailed git push --dry-run did not refuse authentication")
    if jailed_dns.returncode != 0:
        failures.append("jailed DNS did not resolve the documented egress residual")

    baseline_missing = []
    if not authenticated_status(baseline_status):
        baseline_missing.append("gh auth status")
    if not authenticated_user_json(baseline_api):
        baseline_missing.append("gh api user")
    if baseline_push.returncode != 0:
        baseline_missing.append("git push --dry-run")
    egress = "egress remains open (documented residual)" if jailed_dns.returncode == 0 else "egress DNS probe failed"
    if baseline_missing:
        joined = ", ".join(baseline_missing)
        if failures:
            return False, "; ".join(failures + [egress])
        return True, f"gate capability absent; unjailed baseline unavailable in this session ({joined}); {egress}"
    if failures:
        return False, "; ".join(failures)
    return True, "gate capability absent; unjailed baseline authenticated; egress remains open (documented residual)"


def scenario_restricted_account_probe_self_test() -> tuple[Optional[bool], str]:
    """Verify the local #59 probe mechanics without claiming account proof."""
    if POWERSHELL is None:
        return None, "SKIPPED: PowerShell is required for the restricted-account probe self-test"
    if not RESTRICTED_ACCOUNT_PROBE.is_file():
        return False, "required scripts/restricted-account-probe.ps1 is missing"
    try:
        result = run(
            [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(RESTRICTED_ACCOUNT_PROBE),
                "-SelfTest",
            ],
            ROOT,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, f"restricted-account probe self-test could not run: {error}"
    required = (
        "self-test: redaction OK",
        "self-test: identity guard OK",
        "self-test: SID guard OK",
        "self-test: engine ",
        "self-test: credential refusal guard OK",
        "self-test: GH config isolation OK",
        "self-test: smoke helper OK",
        "self-test: does not establish director-exec",
        "restricted-account-probe self-test PASSED",
    )
    missing = [marker for marker in required if marker not in result.output]
    if result.returncode != 0 or missing:
        detail = f"exit {result.returncode}"
        if missing:
            detail += "; missing: " + ", ".join(missing)
        return False, detail
    return True, "#59 probe self-test passed; it explicitly does not establish director-exec"


def scenario_restricted_account_launcher_prompt_contract() -> tuple[bool, str]:
    """Guard the launcher prompt and its protected cleanup ordering."""
    if not RESTRICTED_ACCOUNT_LAUNCHER.is_file():
        return False, "required scripts/exec-as-account.ps1 is missing"
    try:
        source = RESTRICTED_ACCOUNT_LAUNCHER.read_text(encoding="utf-8")
    except OSError as error:
        return False, f"launcher source could not be read: {error}"

    forbidden = (
        "Get-Credential",
        "ConvertFrom-SecureString",
        "ConvertTo-PlainText",
        "SecureStringToBSTR",
    )
    found = [marker for marker in forbidden if marker in source]
    if found:
        return False, "launcher contains forbidden credential handling: " + ", ".join(found)

    try:
        outer_try = source.index("\ntry {\n")
        finally_block = source.index("\n} finally {\n", outer_try)
        post_finally = source.index("\nif ($null -ne $primaryError)", finally_block)
        guard = source.index("if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected)")
        prompt = source.index("Read-Host -Prompt", guard)
        launch_command = source.index("$resolvedLaunchCommand =")
        launch_command_length = source.index(
            "$resolvedLaunchCommandLength = $resolvedLaunchCommand.Length", launch_command
        )
        command_limit = source.index(
            "if ($resolvedLaunchCommandLength -gt 1024)", launch_command_length
        )
        temp_marker_false = source.index("$temporaryCreated = $false")
        candidate_guard = source.index("if (Test-Path -LiteralPath $temporary)", temp_marker_false)
        temp_create = source.index(
            "New-Item -ItemType Directory -Path $temporary -Force -ErrorAction Stop",
            candidate_guard,
        )
        temp_marker_true = source.index("$temporaryCreated = $true", temp_create)
        launch = source.index("$child = Start-Process @startParameters", temp_create)
        credential_clear = source.index("$credential = $null", launch)
        parameters_clear = source.index("$startParameters = $null", launch)
        dispose = source.index("$securePassword.Dispose()", finally_block)
        temp_cleanup = source.index("if ($temporaryCreated -and $null -ne $temporary", finally_block)
        primary_guard = source.index("if ($null -ne $primaryError)", post_finally)
        cleanup_guard = source.index("if ($null -ne $cleanupError -and", primary_guard)
        child_guard = source.index("if ($null -ne $childExitCode)", cleanup_guard)
    except ValueError as error:
        return False, f"launcher ordering contract is incomplete: {error}"

    initializations = (
        "$securePassword = $null",
        "$credential = $null",
        "$temporary = $null",
        "$stdoutPath = $null",
        "$stderrPath = $null",
        "$child = $null",
        "$startParameters = $null",
        "$temporaryCreated = $false",
    )
    if any(source.index(marker) > outer_try for marker in initializations):
        return False, "launcher state is not initialized before the protected scope"
    if not (
        temp_marker_false
        < outer_try
        < guard
        < prompt
        < candidate_guard
        < temp_create
        < temp_marker_true
        < finally_block
    ):
        return False, "prompt and temporary directory creation are not inside the protected scope"
    if "if ($ArgumentList.Length -gt 1024)" in source:
        return False, "launcher still limits ArgumentList without the resolved executable path"
    if not (launch_command < launch_command_length < command_limit < prompt):
        return False, "complete credentialed launch command is not bounded before Read-Host"
    launch_guard_source = source[launch_command:prompt]
    if "$resolvedFilePath" not in launch_guard_source or "$ArgumentList" not in launch_guard_source:
        return False, "launch command guard does not include both executable path and argument list"
    if "maximum 1024" not in launch_guard_source or "tracked -File bootstrap" not in launch_guard_source:
        return False, "complete launch-command rejection lacks a bounded diagnostic and tracked -File remediation"
    if not (launch < credential_clear and launch < parameters_clear):
        return False, "credential references are not cleared after launch"
    cleanup_source = source[finally_block:post_finally]
    if dispose >= post_finally or temp_cleanup <= dispose:
        return False, "secure password disposal is not first and protected in cleanup"
    if cleanup_source.count("$cleanupError = $_") < 3:
        return False, "cleanup failures are not captured without masking the primary error"
    if not (primary_guard < cleanup_guard < child_guard):
        return False, "primary error, cleanup failure, and child exit-code precedence is not preserved"
    candidate = Path(tempfile.mkdtemp(prefix="director-existing-candidate-"))
    try:
        owned = False
        try:
            if candidate.exists():
                raise FileExistsError("pre-existing candidate")
            candidate.mkdir()
            owned = True
        except FileExistsError:
            pass
        finally:
            if owned and candidate.exists():
                shutil.rmtree(candidate)
        if not candidate.is_dir():
            return False, "pre-existing candidate was removed by the ownership model"
    finally:
        if candidate.exists():
            shutil.rmtree(candidate)
    return True, "#59 launcher bounds the complete credentialed command before prompt and preserves protected cleanup"


def scenario_restricted_account_continuation_contract() -> tuple[bool, str]:
    """Guard the short clean-clone continuation and proof-path invariants."""
    paths = (
        RESTRICTED_ACCOUNT_WRAPPER,
        RESTRICTED_ACCOUNT_LOGIN_RUNNER,
        RESTRICTED_ACCOUNT_PROBE,
        RESTRICTED_ACCOUNT_CLEAN_BOOTSTRAP,
    )
    if any(not path.is_file() for path in paths):
        return False, "required #59 continuation script is missing"
    try:
        wrapper = RESTRICTED_ACCOUNT_WRAPPER.read_text(encoding="utf-8")
        login = RESTRICTED_ACCOUNT_LOGIN_RUNNER.read_text(encoding="utf-8")
        probe = RESTRICTED_ACCOUNT_PROBE.read_text(encoding="utf-8")
        bootstrap = RESTRICTED_ACCOUNT_CLEAN_BOOTSTRAP.read_text(encoding="utf-8")
    except OSError as error:
        return False, f"#59 continuation source could not be read: {error}"

    if "EncodedCommand" in wrapper or "-EncodedCommand" in wrapper:
        return False, "run-restricted-account-probe still embeds an encoded payload"
    required_wrapper = (
        "-File `\"$childScriptPath`\"",
        "-RestrictedLoginChild",
        "director-core-issue-59",
        "Get-ResolvedCommit",
        "ExpectedCommit",
        "^[0-9a-fA-F]{40}$",
    )
    missing = [marker for marker in required_wrapper if marker not in wrapper]
    if missing:
        return False, "clean-clone bootstrap contract is incomplete: " + ", ".join(missing)
    if "-ExecutorPath" in wrapper or "-ExecutorBinDirectory" in wrapper:
        return False, "wrapper still injects an operator executor path"

    required_login = (
        'Get-Command -Name "git"',
        'Get-Command -Name "codex"',
        "restricted account's own PATH",
    )
    missing = [marker for marker in required_login if marker not in login]
    if missing:
        return False, "restricted login PATH resolution contract is incomplete: " + ", ".join(missing)
    if "ExecutorPath" in login or "ExecutorBinDirectory" in login:
        return False, "login runner accepts operator executable injection"

    required_bootstrap = (
        'Get-Command -Name $Name',
        "clone --branch $Branch --single-branch",
        "$git.Source clone --branch $Branch --single-branch $Remote $target",
        "$target.StartsWith($profileRoot + \"\\\", [StringComparison]::OrdinalIgnoreCase)",
        "ExpectedCommit",
        "ExpectedSid",
        "status --porcelain --untracked-files=all",
        "owner_before_scope",
        "Invoke-Icacls -Arguments @($target, \"/setowner\", $UserName, \"/T\", \"/C\")",
        "Invoke-Icacls -Arguments @($target, \"/grant\", \"${UserName}:(OI)(CI)M\", \"/T\", \"/C\")",
        "ownerAfterScope",
        "clean-clone-preflight.json",
        "login-and-run-restricted-probe.ps1",
        'Join-Path $env:LOCALAPPDATA "Programs\\OpenAI\\Codex\\bin\\codex.exe"',
        'Get-Command -Name "codex" -CommandType Application',
        "--version",
        '[Environment]::GetEnvironmentVariable("Path", "Machine")',
        '[Environment]::SetEnvironmentVariable("Path", $updatedMachinePath, "Machine")',
        "$env:Path",
        "registry write failed",
    )
    missing = [marker for marker in required_bootstrap if marker not in bootstrap]
    if missing:
        return False, "clean-clone bootstrap contract is incomplete: " + ", ".join(missing)
    if (
        "--untracked-files=no" in bootstrap
        or "EncodedCommand" in bootstrap
        or "ExecutorPath" in bootstrap
        or "ExecutorBinDirectory" in bootstrap
        or "safe.directory=" in bootstrap
    ):
        return False, "clean-clone bootstrap injects an operator path or safe.directory"

    forbidden_probe = ("safe.directory=", "Add-ExecutableDirectoryToPath", "ExecutorBinDirectory")
    found = [marker for marker in forbidden_probe if marker in probe]
    if found:
        return False, "restricted proof path retains forbidden injection: " + ", ".join(found)
    required_probe = (
        "Get-RepositoryEvidence",
        "path = $RepositoryPath",
        "owner = $owner",
        "owner_error = $ownerError",
        "remote = ([string]$remote.output).Trim()",
        "remote_exit_code",
        "commit_sha = $commitSha",
        "commit_exit_code",
        "expected_commit = $ExpectedCommit",
        "status_exit_code",
        "status_clean",
        "precondition_failure",
        "dubious ownership",
        "artifact_removed",
        "owner_matches_expected",
        "status_scope",
    )
    missing = [marker for marker in required_probe if marker not in probe]
    if missing:
        return False, "restricted evidence contract is incomplete: " + ", ".join(missing)
    return True, "#59 continuation uses a short tracked bootstrap and identity-safe proof paths"


def build_branch_state_repository(root: Path, head_files: dict, main_files: dict) -> None:
    """A synthetic repository shaped like a squash merge.

    One base commit, a head branch that changes files, then a main commit that
    reaches the given content **without** the head's commit in its ancestry —
    which is exactly what a squash merge, a rebase, or a superseding merge
    leaves behind, and exactly the shape a three-dot diff misreads. No network,
    no GitHub, no pull request: the defect is reproducible from git alone.
    """
    checked(["git", "init", "--initial-branch=main", str(root)])
    checked(["git", "-C", str(root), "config", "user.email", "conformance@example.invalid"])
    checked(["git", "-C", str(root), "config", "user.name", "Conformance fixture"])
    write_text(root / "base.txt", "base\n")
    write_text(root / "file.txt", "line1\n")
    write_text(root / "doomed.txt", "doomed\n")
    checked(["git", "-C", str(root), "add", "."])
    checked(["git", "-C", str(root), "commit", "-m", "base"])

    checked(["git", "-C", str(root), "checkout", "-b", "pr-head"])
    apply_files(root, head_files)
    checked(["git", "-C", str(root), "commit", "-m", "head work"])

    checked(["git", "-C", str(root), "checkout", "main"])
    apply_files(root, main_files)
    # --allow-empty: a case may leave main untouched on purpose (the unresolvable
    # ref case never reaches path comparison), and that is a fixture, not a bug.
    checked(["git", "-C", str(root), "commit", "--allow-empty", "-m", "squashed onto main"])


def apply_files(root: Path, files: dict) -> None:
    for name, content in files.items():
        target = root / name
        if content is None:
            if target.exists():
                target.unlink()
            checked(["git", "-C", str(root), "rm", "-q", "--cached", name])
        elif isinstance(content, bytes):
            target.write_bytes(content)
            checked(["git", "-C", str(root), "add", name])
        else:
            write_text(target, content)
            checked(["git", "-C", str(root), "add", name])


def run_branch_state(root: Path, *arguments: str) -> Command:
    if BASH is None:
        raise RuntimeError("bash is required to execute scripts/branch-state.sh")
    return run([BASH, str(BRANCH_STATE), "--repo", str(root), *arguments], ROOT)


def branch_state_case(
    head_files: dict,
    main_files: dict,
    expected_status: str,
    expected_returncode: int,
    expected_paths: Iterable[str] = (),
    arguments: Iterable[str] = (),
) -> tuple[bool, str]:
    """Build one synthetic case, run the classifier, assert status and table."""
    if not BRANCH_STATE.is_file():
        return False, f"missing classifier: {BRANCH_STATE}"
    try:
        with tempfile.TemporaryDirectory(prefix="director-branch-state-") as temporary:
            root = Path(temporary) / "fixture-repository"
            root.mkdir(parents=True)
            build_branch_state_repository(root, head_files, main_files)
            result = run_branch_state(root, "--base", "main", "--head", "pr-head", *arguments)
    except Exception as error:
        return False, f"case could not be built or exercised: {error}"
    if f"Status: {expected_status}" not in result.output:
        return False, f"expected status {expected_status}: {result.output.strip()}"
    if result.returncode != expected_returncode:
        return (
            False,
            f"expected exit {expected_returncode}, got {result.returncode}: {result.output.strip()}",
        )
    # Column padding is presentation, so the assertions compare on collapsed
    # whitespace. A test that fails when a column widens teaches people to edit
    # the test rather than read it.
    collapsed = " ".join(result.output.split())
    for expected in expected_paths:
        if " ".join(expected.split()) not in collapsed:
            return False, f"report omitted {expected!r}: {result.output.strip()}"
    return True, f"{expected_status} (exit {expected_returncode})"


def scenario_branch_state_squash_landed_exact() -> tuple[bool, str]:
    """The defect itself: identical content, non-empty three-dot, not blocked."""
    outcome, reason = branch_state_case(
        head_files={"file.txt": "line1\nline2\n"},
        main_files={"file.txt": "line1\nline2\n"},
        expected_status="SUPERSEDED",
        expected_returncode=0,
        expected_paths=["landed_exact   file.txt"],
    )
    return outcome, f"squash-merged content classified landed_exact: {reason}"


def scenario_branch_state_main_superset() -> tuple[bool, str]:
    outcome, reason = branch_state_case(
        head_files={"file.txt": "line1\nline2\n"},
        main_files={"file.txt": "line1\nline2\nline3\n"},
        expected_status="SUPERSEDED",
        expected_returncode=0,
        expected_paths=["main_superset  file.txt"],
    )
    return outcome, f"base carrying a strict superset does not block: {reason}"


def scenario_branch_state_not_landed_blocks() -> tuple[bool, str]:
    outcome, reason = branch_state_case(
        head_files={"file.txt": "line1\nline2\n"},
        main_files={"base.txt": "base\nunrelated\n"},
        expected_status="BLOCKED_BRANCH_STATE",
        expected_returncode=1,
        expected_paths=["not_landed"],
    )
    return outcome, f"genuinely unlanded content still blocks: {reason}"


def scenario_branch_state_deleted_landed() -> tuple[bool, str]:
    outcome, reason = branch_state_case(
        head_files={"doomed.txt": None},
        main_files={"doomed.txt": None},
        expected_status="SUPERSEDED",
        expected_returncode=0,
        expected_paths=["deleted_landed doomed.txt"],
    )
    return outcome, f"a deletion present on both sides is landed: {reason}"


def scenario_branch_state_unknown_unresolvable_ref() -> tuple[bool, str]:
    """A ref that was never fetched is unknown, never 'the content is absent'."""
    if not BRANCH_STATE.is_file():
        return False, f"missing classifier: {BRANCH_STATE}"
    try:
        with tempfile.TemporaryDirectory(prefix="director-branch-state-") as temporary:
            root = Path(temporary) / "fixture-repository"
            root.mkdir(parents=True)
            build_branch_state_repository(root, {"file.txt": "line1\nline2\n"}, {})
            result = run_branch_state(
                root, "--base", "main", "--head", "refs/remotes/pr/9999"
            )
    except Exception as error:
        return False, f"case could not be built or exercised: {error}"
    if "Status: UNKNOWN_BRANCH_SUPERSESSION" not in result.output or result.returncode != 2:
        return False, f"expected UNKNOWN_BRANCH_SUPERSESSION with exit 2: {result.output.strip()}"
    if "BLOCKED_BRANCH_STATE" in result.output:
        return False, "an unfetched ref was reported as blocked rather than unknown"
    return True, "an unresolvable head ref is unknown, not blocked (exit 2)"


def scenario_branch_state_unknown_binary() -> tuple[bool, str]:
    outcome, reason = branch_state_case(
        head_files={"blob.bin": b"\x00\x01head\x00"},
        main_files={"blob.bin": b"\x00\x01main\x00"},
        expected_status="UNKNOWN_BRANCH_SUPERSESSION",
        expected_returncode=2,
        expected_paths=["unknown", "binary difference"],
    )
    return outcome, f"a binary difference is unknown, not guessed at: {reason}"


def scenario_branch_state_mixed_blocks_and_reports_both() -> tuple[bool, str]:
    outcome, reason = branch_state_case(
        head_files={"file.txt": "line1\nline2\n", "other.txt": "head only\n"},
        main_files={"file.txt": "line1\nline2\n"},
        expected_status="BLOCKED_BRANCH_STATE",
        expected_returncode=1,
        expected_paths=["landed_exact   file.txt", "not_landed", "other.txt"],
    )
    return outcome, f"a mixed set blocks and reports every path: {reason}"


def scenario_branch_state_three_dot_is_demoted() -> tuple[bool, str]:
    """Both signals are reported, and the content-level one decides."""
    if not BRANCH_STATE.is_file():
        return False, f"missing classifier: {BRANCH_STATE}"
    try:
        with tempfile.TemporaryDirectory(prefix="director-branch-state-") as temporary:
            root = Path(temporary) / "fixture-repository"
            root.mkdir(parents=True)
            build_branch_state_repository(
                root, {"file.txt": "line1\nline2\n"}, {"file.txt": "line1\nline2\n"}
            )
            legacy = run(
                ["git", "-C", str(root), "diff", "--name-only", "main...pr-head"], ROOT
            )
            result = run_branch_state(root, "--base", "main", "--head", "pr-head")
    except Exception as error:
        return False, f"case could not be built or exercised: {error}"
    if "file.txt" not in legacy.output:
        return False, "the legacy three-dot proxy did not reproduce the misleading signal"
    if "Three-dot proxy result: NON-EMPTY" not in result.output:
        return False, f"the three-dot signal was not reported: {result.output.strip()}"
    if "Status: SUPERSEDED" not in result.output or result.returncode != 0:
        return False, f"the three-dot signal still drove the status: {result.output.strip()}"
    return True, "three-dot reported NON-EMPTY, status still SUPERSEDED from content"


def scenario_branch_state_closed_pr_does_not_block() -> tuple[bool, str]:
    outcome, reason = branch_state_case(
        head_files={"file.txt": "line1\nline2\n"},
        main_files={"base.txt": "base\nunrelated\n"},
        expected_status="CONTEXT_ONLY_PR_NOT_OPEN",
        expected_returncode=0,
        expected_paths=["not_landed"],
        arguments=["--pr-state", "merged"],
    )
    return outcome, f"a merged pull request reports content as context only: {reason}"


def run_preflight_supersession(head_files: dict, main_files: dict, head: str) -> Command:
    """Drive scripts/preflight.sh over a synthetic superseded repository."""
    if BASH is None:
        raise RuntimeError("bash is required to exercise scripts/preflight.sh")
    with tempfile.TemporaryDirectory(prefix="director-preflight-supersession-") as temporary:
        temp = Path(temporary)
        root = temp / "fixture-repository"
        scripts = root / "scripts"
        fake_bin = temp / "bin"
        scripts.mkdir(parents=True)
        fake_bin.mkdir()
        build_branch_state_repository(root, head_files, main_files)
        shutil.copy2(PREFLIGHT_SOURCE, scripts / "preflight.sh")
        shutil.copy2(BRANCH_STATE, scripts / "branch-state.sh")
        # A usable executor route, so the only thing that can turn this fixture
        # RED is the branch-state section under test.
        write_text(root / ".director" / "routes.yaml", preflight_fixture_routes(
            "    model: primary-fixture\n"
            "    runs_as: operator\n"
            "    invoke: scripts/exec-jail.sh primary-fixture\n"
            "    quarantined: false\n"
            "    jail_verified: true\n"
            "    last_verified: 2026-07-26\n"
        ))
        write_text(fake_bin / "codex", "#!/usr/bin/env bash\necho 'Logged in using ChatGPT'\n")
        write_text(fake_bin / "claude", "#!/usr/bin/env bash\nexit 0\n")
        write_text(fake_bin / "agy", "#!/usr/bin/env bash\nexit 0\n")
        write_text(
            fake_bin / "gh",
            "#!/usr/bin/env bash\nif [ \"$1\" = auth ]; then exit 0; fi\n"
            "if [ \"$1\" = api ]; then echo 'X-Oauth-Scopes: repo, workflow'; exit 0; fi\nexit 1\n",
        )
        for executable in fake_bin.iterdir():
            executable.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
        env["PREFLIGHT_SUPERSESSION_BASE"] = "main"
        env["PREFLIGHT_SUPERSESSION_HEAD"] = head
        completed = subprocess.run(
            [BASH, str(scripts / "preflight.sh")],
            cwd=str(root),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=45,
            check=False,
            env=env,
        )
        return Command(completed.returncode, completed.stdout)


def scenario_preflight_does_not_block_superseded_content() -> tuple[bool, str]:
    """The gate itself: a squash-merged head must not turn preflight RED."""
    if not BRANCH_STATE.is_file():
        return False, f"missing classifier: {BRANCH_STATE}"
    try:
        result = run_preflight_supersession(
            {"file.txt": "line1\nline2\n"}, {"file.txt": "line1\nline2\n"}, "pr-head"
        )
    except Exception as error:
        return False, f"preflight could not be exercised: {error}"
    if "BLOCKED_BRANCH_STATE" in result.output:
        return False, f"preflight blocked on superseded content: {result.output.strip()}"
    if "Status: SUPERSEDED" not in result.output:
        return False, f"preflight did not report the content-level status: {result.output.strip()}"
    if result.returncode != 0:
        return False, f"preflight exited {result.returncode}, expected 0: {result.output.strip()}"
    return True, "preflight stays GREEN when the head's content is already on the base"


def scenario_preflight_still_blocks_unlanded_content() -> tuple[bool, str]:
    """And the gate still refuses what genuinely has not landed."""
    if not BRANCH_STATE.is_file():
        return False, f"missing classifier: {BRANCH_STATE}"
    try:
        result = run_preflight_supersession(
            {"file.txt": "line1\nline2\n"}, {"base.txt": "base\nunrelated\n"}, "pr-head"
        )
    except Exception as error:
        return False, f"preflight could not be exercised: {error}"
    if "BLOCKED_BRANCH_STATE" not in result.output:
        return False, f"preflight did not block unlanded content: {result.output.strip()}"
    if result.returncode == 0:
        return False, f"preflight exited 0 on unlanded content: {result.output.strip()}"
    return True, "preflight is still RED when a claimed path has not landed"


def run_executor_evidence_validator(document: Path) -> Command:
    """Run the executor-evidence validator over one document.

    The validator is invoked as a real entry point rather than imported, for the
    same reason the result-validator scenarios copy and run the shell script: the
    thing under test is what an adapter would actually call.
    """
    if BASH is None:
        raise RuntimeError("bash is required to execute scripts/validate-executor-evidence.sh")
    return run([BASH, str(EXECUTOR_EVIDENCE_VALIDATOR), str(document)], ROOT)


def executor_evidence_fixture(stem: str, kind: str) -> Path:
    return EXECUTOR_EVIDENCE_EXAMPLES / f"{stem}.{kind}.json"


def scenario_executor_evidence_accepts(stem: str) -> tuple[bool, str]:
    fixture = executor_evidence_fixture(stem, "valid")
    if not fixture.is_file():
        return False, f"missing valid fixture: {fixture.name}"
    try:
        result = run_executor_evidence_validator(fixture)
    except Exception as error:
        return False, f"{fixture.name}: validator could not be run: {error}"
    if result.returncode != 0:
        return False, f"{fixture.name}: validator exited {result.returncode}, expected 0: {result.output.strip()}"
    return True, f"{fixture.name} accepted"


def scenario_executor_evidence_rejects(stem: str, expected_reason: str) -> tuple[bool, str]:
    fixture = executor_evidence_fixture(stem, "invalid")
    if not fixture.is_file():
        return False, f"missing invalid fixture: {fixture.name}"
    try:
        result = run_executor_evidence_validator(fixture)
    except Exception as error:
        return False, f"{fixture.name}: validator could not be run: {error}"
    if result.returncode != 1:
        return False, f"{fixture.name}: validator exited {result.returncode}, expected 1: {result.output.strip()}"
    if expected_reason not in result.output:
        return (
            False,
            f"{fixture.name}: validator omitted expected reason {expected_reason!r}: {result.output.strip()}",
        )
    return True, f"{fixture.name} rejected: {expected_reason}"


def scenario_executor_evidence_fulfilled_forbids_not_run() -> tuple[bool, str]:
    """A fulfilled envelope may not carry a command that never ran.

    Synthesized rather than committed: the rule is about a combination, and a
    sixteenth near-identical fixture would buy nothing a temporary file does not.
    """
    source = executor_evidence_fixture("fulfilled", "valid")
    if not source.is_file():
        return False, f"missing valid fixture: {source.name}"
    try:
        document = json.loads(source.read_text(encoding="utf-8"))
        evidence = document["executor_evidence"]
        evidence["blockers"] = [{"id": "BLK-001", "detail": "synthesized for this scenario"}]
        evidence["verification"]["commands_run"].append(
            {"command": "scripts/integration.sh", "not_run": True, "blocker_id": "BLK-001"}
        )
        with tempfile.TemporaryDirectory(prefix="director-executor-evidence-") as temporary:
            candidate = Path(temporary) / "fulfilled-with-not-run.json"
            write_text(candidate, json.dumps(document, indent=2) + "\n")
            result = run_executor_evidence_validator(candidate)
    except Exception as error:
        return False, f"scenario could not be built or exercised: {error}"
    expected = "fulfilled forbids a not_run command record"
    if result.returncode != 1:
        return False, f"validator exited {result.returncode}, expected 1: {result.output.strip()}"
    if expected not in result.output:
        return False, f"validator omitted expected reason {expected!r}: {result.output.strip()}"
    return True, expected


def scenario_executor_evidence_does_not_replay_commands() -> tuple[bool, str]:
    """Command records are evidence, never a script the validator runs.

    The envelope is composed from material an executor supplies. If validating it
    executed the strings inside it, the contract would be a remote-execution
    surface rather than a record.
    """
    source = executor_evidence_fixture("fulfilled", "valid")
    if not source.is_file():
        return False, f"missing valid fixture: {source.name}"
    try:
        with tempfile.TemporaryDirectory(prefix="director-executor-evidence-") as temporary:
            sentinel = Path(temporary) / "replayed"
            document = json.loads(source.read_text(encoding="utf-8"))
            evidence = document["executor_evidence"]
            # Two shapes of the same attempt: a command that would create the
            # sentinel directly, and one that tries to reach a second command
            # through a metacharacter.
            evidence["verification"]["commands_run"] = [
                {
                    "command": f"touch {sentinel}",
                    "exit_code": 0,
                    "evidence_reference": "artifact:test-log",
                },
                {
                    "command": f"true; touch {sentinel}",
                    "exit_code": 0,
                    "evidence_reference": "artifact:test-log",
                },
            ]
            evidence["verification"]["tests_passed"] = []
            candidate = Path(temporary) / "replay-attempt.json"
            write_text(candidate, json.dumps(document, indent=2) + "\n")
            result = run_executor_evidence_validator(candidate)
            replayed = sentinel.exists()
    except Exception as error:
        return False, f"scenario could not be built or exercised: {error}"
    if replayed:
        return False, "the validator executed a command from verification.commands_run"
    if result.returncode != 0:
        return False, f"validator exited {result.returncode}, expected 0: {result.output.strip()}"
    return True, "command records are recorded, not replayed"


def scenario_executor_evidence_fixture_set_is_canonical() -> tuple[bool, str]:
    if not EXECUTOR_EVIDENCE_EXAMPLES.is_dir():
        return False, f"missing fixture directory: {EXECUTOR_EVIDENCE_EXAMPLES}"
    expected_valid = {f"{stem}.valid.json" for stem in EXECUTOR_EVIDENCE_VALID_CASES}
    expected_invalid = {f"{stem}.invalid.json" for stem, _ in EXECUTOR_EVIDENCE_REJECT_CASES}
    expected = expected_valid | expected_invalid
    present = {path.name for path in EXECUTOR_EVIDENCE_EXAMPLES.iterdir() if path.is_file()}
    missing = sorted(expected - present)
    unexpected = sorted(present - expected)
    if missing:
        return False, "fixtures missing from the canonical set: " + ", ".join(missing)
    if unexpected:
        return False, "fixtures outside the canonical set: " + ", ".join(unexpected)
    return True, f"{len(expected_valid)} valid and {len(expected_invalid)} invalid fixtures, names as specified"


def run_cross_review_validator(document: Path) -> Command:
    """Run the cross-review validator over one document, as an adapter would."""
    if BASH is None:
        raise RuntimeError("bash is required to execute scripts/validate-cross-review.sh")
    return run([BASH, str(CROSS_REVIEW_VALIDATOR), str(document)], ROOT)


def cross_review_fixture(stem: str, kind: str) -> Path:
    return CROSS_REVIEW_EXAMPLES / f"{stem}.{kind}.json"


def scenario_cross_review_accepts(stem: str) -> tuple[bool, str]:
    fixture = cross_review_fixture(stem, "valid")
    if not fixture.is_file():
        return False, f"missing valid fixture: {fixture.name}"
    try:
        result = run_cross_review_validator(fixture)
    except Exception as error:
        return False, f"{fixture.name}: validator could not be run: {error}"
    if result.returncode != 0:
        return False, f"{fixture.name}: validator exited {result.returncode}, expected 0: {result.output.strip()}"
    return True, f"{fixture.name} accepted"


def scenario_cross_review_rejects(stem: str, expected_reason: str) -> tuple[bool, str]:
    fixture = cross_review_fixture(stem, "invalid")
    if not fixture.is_file():
        return False, f"missing invalid fixture: {fixture.name}"
    try:
        result = run_cross_review_validator(fixture)
    except Exception as error:
        return False, f"{fixture.name}: validator could not be run: {error}"
    if result.returncode != 1:
        return False, f"{fixture.name}: validator exited {result.returncode}, expected 1: {result.output.strip()}"
    if expected_reason not in result.output:
        return (
            False,
            f"{fixture.name}: validator omitted expected reason {expected_reason!r}: {result.output.strip()}",
        )
    return True, f"{fixture.name} rejected: {expected_reason}"


def scenario_cross_review_fixture_set_is_canonical() -> tuple[bool, str]:
    if not CROSS_REVIEW_EXAMPLES.is_dir():
        return False, f"missing fixture directory: {CROSS_REVIEW_EXAMPLES}"
    expected_valid = {f"{stem}.valid.json" for stem in CROSS_REVIEW_VALID_CASES}
    expected_invalid = {f"{stem}.invalid.json" for stem, _ in CROSS_REVIEW_REJECT_CASES}
    expected = expected_valid | expected_invalid
    present = {path.name for path in CROSS_REVIEW_EXAMPLES.iterdir() if path.is_file()}
    missing = sorted(expected - present)
    unexpected = sorted(present - expected)
    if missing:
        return False, "cross-review fixtures missing from the canonical set: " + ", ".join(missing)
    if unexpected:
        return False, "cross-review fixtures outside the canonical set: " + ", ".join(unexpected)
    return True, (
        f"{len(expected_valid)} valid and {len(expected_invalid)} invalid cross-review "
        f"fixtures, each registered by name"
    )


def scenario_cross_review_reference_format_matches_executor_evidence() -> tuple[bool, str]:
    """One evidence-reference format across contracts, asserted rather than assumed.

    subject.executor_evidence_ref is validated against the same pattern the
    executor-evidence contract already uses. Restating the pattern in a second
    schema is only safe if something fails when the two drift.
    """
    for path in (CROSS_REVIEW_SCHEMA, EXECUTOR_EVIDENCE_SCHEMA):
        if not path.is_file():
            return False, f"missing schema: {path}"
    try:
        cross = json.loads(CROSS_REVIEW_SCHEMA.read_text(encoding="utf-8"))
        evidence = json.loads(EXECUTOR_EVIDENCE_SCHEMA.read_text(encoding="utf-8"))
        cross_pattern = cross["$defs"]["evidence_reference"]["pattern"]
        evidence_pattern = evidence["$defs"]["evidence_reference"]["pattern"]
    except Exception as error:
        return False, f"could not read both evidence-reference patterns: {error}"
    if cross_pattern != evidence_pattern:
        return False, (
            f"evidence-reference patterns have drifted: cross-review {cross_pattern!r} "
            f"vs executor-evidence {evidence_pattern!r}"
        )
    return True, "cross-review reuses the executor-evidence reference format"


def scenario_cross_review_does_not_dereference_subject() -> tuple[bool, str]:
    """Subject references are validated as strings and never followed.

    The ledger is composed from material supplied by the parties under review. A
    validator that opened, fetched, or executed what those references point at
    would be an execution surface rather than a check, so the rule is asserted
    with a reference whose target would be observable if it were ever touched.
    """
    source = cross_review_fixture("cross-executor-review-distinct-provider", "valid")
    if not source.is_file():
        return False, f"missing valid fixture: {source.name}"
    try:
        with tempfile.TemporaryDirectory(prefix="director-cross-review-") as temporary:
            sentinel = Path(temporary) / "dereferenced"
            write_text(sentinel, "the validator opened a subject reference\n")
            document = json.loads(source.read_text(encoding="utf-8"))
            # A well-formed reference pointing at a file that exists. Validation
            # must neither read it nor care whether it is there.
            document["cross_review"]["subject"]["diff_ref"] = "file:dereferenced"
            candidate = Path(temporary) / "dereference-attempt.json"
            write_text(candidate, json.dumps(document, indent=2) + "\n")
            result = run_cross_review_validator(candidate)
            if sentinel.read_text(encoding="utf-8").strip().endswith("reference"):
                sentinel.unlink()
    except Exception as error:
        return False, f"scenario could not be built or exercised: {error}"
    if result.returncode != 0:
        return False, f"validator exited {result.returncode}, expected 0: {result.output.strip()}"
    if "dereferenced" in result.output and "diff_ref" not in result.output:
        return False, f"validator reported the reference target: {result.output.strip()}"
    return True, "subject references are validated as strings, never dereferenced"


def scenario_cross_review_examples_are_sanitized() -> tuple[bool, str]:
    """The sanitizer's default scan covers executor-evidence, so name the tree."""
    if BASH is None:
        return False, "bash is required to execute scripts/check-example-sanitization.sh"
    if not CROSS_REVIEW_EXAMPLES.is_dir():
        return False, f"missing fixture directory: {CROSS_REVIEW_EXAMPLES}"
    try:
        result = run([BASH, str(EXAMPLE_SANITIZER), str(CROSS_REVIEW_EXAMPLES)], ROOT)
    except Exception as error:
        return False, f"sanitizer could not be run: {error}"
    if result.returncode != 0:
        return False, f"sanitizer rejected the cross-review examples: {result.output.strip()}"
    return True, "cross-review examples carry no credential, absolute path, or private hostname"


def scenario_example_sanitizer_accepts_public_examples() -> tuple[bool, str]:
    if BASH is None:
        return False, "bash is required to execute scripts/check-example-sanitization.sh"
    try:
        result = run([BASH, str(EXAMPLE_SANITIZER)], ROOT)
    except Exception as error:
        return False, f"sanitizer could not be run: {error}"
    if result.returncode != 0:
        return False, f"sanitizer rejected the committed examples: {result.output.strip()}"
    return True, "committed examples carry no credential, absolute path, or private hostname"


def scenario_example_sanitizer_rejects_generated_leak() -> tuple[bool, str]:
    """The negative case is synthesized, asserted, and deleted.

    It is never written under examples/: committing a realistic secret to prove a
    secret scanner works is the failure the scanner exists to prevent.
    """
    if BASH is None:
        return False, "bash is required to execute scripts/check-example-sanitization.sh"
    if not SANITIZER_NEGATIVE_TEMPLATE.is_file():
        return False, f"missing sanitizer negative template: {SANITIZER_NEGATIVE_TEMPLATE}"
    generated: Optional[Path] = None
    try:
        template = SANITIZER_NEGATIVE_TEMPLATE.read_text(encoding="utf-8")
        # Assembled here, from fragments that are inert apart. Neither the
        # template nor this file contains a complete offending string.
        substitutions = {
            "{{ENV_KEY_NAME}}": "EXAMPLE" + "_API" + "_KEY",
            "{{ABSOLUTE_HOME_PATH}}": "/" + "home/" + "example-user/notes.txt",
        }
        body = template
        for placeholder, replacement in substitutions.items():
            if placeholder not in body:
                return False, f"template is missing placeholder {placeholder}"
            body = body.replace(placeholder, replacement)
        with tempfile.TemporaryDirectory(prefix="director-sanitizer-negative-") as temporary:
            generated = Path(temporary) / "leak-case.generated.invalid.json"
            write_text(generated, body)
            if EXECUTOR_EVIDENCE_EXAMPLES.resolve() in generated.resolve().parents:
                return False, "refusing to run: the generated case landed inside the scanned tree"
            result = run([BASH, str(EXAMPLE_SANITIZER), str(generated)], ROOT)
            existed = generated.is_file()
        removed = not generated.exists()
    except Exception as error:
        return False, f"scenario could not be built or exercised: {error}"
    if not existed:
        return False, "the generated case was not written"
    if result.returncode == 0:
        return False, f"sanitizer accepted a document carrying a leak: {result.output.strip()}"
    if "_API_KEY" not in result.output or "absolute path" not in result.output:
        return False, f"sanitizer did not name both matched patterns: {result.output.strip()}"
    if not removed:
        return False, "the generated case outlived the scenario"
    return True, "synthesized leak rejected by pattern, then deleted"


def report(number: int, passed: Optional[bool], reason: str) -> bool:
    """Print one scenario outcome and report whether it blocks the suite.

    A skipped scenario (``passed is None``) does not fail the run, but it is
    never printed as a pass — an unrun check is an unknown check, and the
    distinction is the point of §13.3's failure log.
    """
    state = "SKIP" if passed is None else ("PASS" if passed else "FAIL")
    print(f"{state} scenario {number}: {reason}")
    return passed is not False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--break-scenario-2",
        action="store_true",
        help="deliberately make the scenario 2 fixture in-scope; proves this runner fails",
    )
    args = parser.parse_args()

    outcomes = (
        scenario_one(),
        scenario_two(args.break_scenario_2),
        scenario_three(),
        scenario_four(),
        scenario_five(),
        scenario_defect_one_lock_owner(),
        scenario_defect_two_missing_base_commit(),
        scenario_defect_three_result_invariants(),
        scenario_result_route_used_closed_enum(),
        scenario_defect_four_forbidden_model(),
        scenario_defect_five_future_verification(),
        scenario_stopped_terminal_outcomes(),
        scenario_blocked_states_what_it_hit(),
        scenario_route_availability(),
        scenario_route_availability_gate(),
        scenario_forbidden_paths_deny_before_allow(),
        scenario_forbidden_paths_ambiguous_declaration(),
        scenario_forbidden_paths_no_match_still_validates(),
        scenario_runs_as_claim_must_match_effective_user(),
        scenario_runs_as_is_required(),
        scenario_required_tests_take_no_shell(),
        scenario_required_tests_are_bounded(),
        scenario_required_tests_ordinary_entries_pass(),
        scenario_removed_route_is_not_authorised(),
        scenario_restricted_account_probe_self_test(),
        scenario_restricted_account_launcher_prompt_contract(),
        scenario_restricted_account_continuation_contract(),
        *(scenario_executor_evidence_accepts(stem) for stem in EXECUTOR_EVIDENCE_VALID_CASES),
        *(
            scenario_executor_evidence_rejects(stem, reason)
            for stem, reason in EXECUTOR_EVIDENCE_REJECT_CASES
        ),
        scenario_executor_evidence_fulfilled_forbids_not_run(),
        scenario_executor_evidence_does_not_replay_commands(),
        scenario_executor_evidence_fixture_set_is_canonical(),
        *(scenario_cross_review_accepts(stem) for stem in CROSS_REVIEW_VALID_CASES),
        *(
            scenario_cross_review_rejects(stem, reason)
            for stem, reason in CROSS_REVIEW_REJECT_CASES
        ),
        scenario_cross_review_fixture_set_is_canonical(),
        scenario_cross_review_reference_format_matches_executor_evidence(),
        scenario_cross_review_does_not_dereference_subject(),
        scenario_cross_review_examples_are_sanitized(),
        scenario_branch_state_squash_landed_exact(),
        scenario_branch_state_main_superset(),
        scenario_branch_state_not_landed_blocks(),
        scenario_branch_state_deleted_landed(),
        scenario_branch_state_unknown_unresolvable_ref(),
        scenario_branch_state_unknown_binary(),
        scenario_branch_state_mixed_blocks_and_reports_both(),
        scenario_branch_state_three_dot_is_demoted(),
        scenario_branch_state_closed_pr_does_not_block(),
        scenario_preflight_does_not_block_superseded_content(),
        scenario_preflight_still_blocks_unlanded_content(),
        scenario_example_sanitizer_accepts_public_examples(),
        scenario_example_sanitizer_rejects_generated_leak(),
    )
    all_passed = True
    for index, (passed, reason) in enumerate(outcomes, 1):
        all_passed = report(index, passed, reason) and all_passed
    skipped = sum(1 for passed, _ in outcomes if passed is None)
    if not all_passed:
        print("CONFORMANCE FAILED")
        return 1
    if skipped:
        print(f"CONFORMANCE PASSED — {skipped} scenario(s) skipped for an absent prerequisite")
        return 0
    print("CONFORMANCE PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
