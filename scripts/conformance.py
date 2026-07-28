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

    def write_packet(self, allowed_paths: Iterable[str], required_tests: Iterable[str]) -> None:
        allowed = list(allowed_paths)
        tests = list(required_tests)
        if not allowed:
            raise RuntimeError("fixture packet requires declared paths")
        packet = ["allowed_paths:"]
        packet.extend(f"  - {path}" for path in allowed)
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
                        "unresolved_risks": [],
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


def preflight_fixture_routes(primary_block: str) -> str:
    return f"""routes:
  ORCH_PRIMARY:
    model: default
    last_verified: 2026-07-26
  ORCH_FALLBACK:
    model: default
    last_verified: 2026-07-26
  EXEC_PRIMARY:
{primary_block}
  EXEC_STRONG:
    model: default
    last_verified: 2026-07-26
  EXEC_LOCAL:
    model: local
    state: absent
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
    last_verified: 2026-07-26
  ORCH_FALLBACK:
    model: default
    last_verified: 2026-07-26
  EXEC_PRIMARY:
    model: primary-fixture
    quarantined: false
    jail_verified: true
    last_verified: 2026-07-26
  EXEC_STRONG:
    model: strong-fixture
    invoke: scripts/exec-jail.sh strong-fixture
    quarantined: true
    jail_verified: false
    last_verified: 2026-07-26
  EXEC_LOCAL:
    model: local-fixture
    invoke: scripts/exec-jail.sh local-fixture
    quarantined: false
    jail_verified: true
    state: active
    last_verified: 2026-07-26
"""
    try:
        result = run_preflight_with_routes(routes)
        if result.returncode != 0:
            return False, f"availability declarations made preflight exit {result.returncode}"
        expected_lines = (
            "EXEC_PRIMARY route unusable: invoke key absent",
            "EXEC_STRONG route unusable: quarantined; jail not verified",
            "EXEC_LOCAL route usable",
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
    last_verified: 2026-07-26
  ORCH_FALLBACK:
    model: default
    last_verified: 2026-07-26
  EXEC_PRIMARY:
    model: primary-fixture
    invoke: scripts/exec-jail.sh primary-fixture
    quarantined: true
    jail_verified: true
    last_verified: 2026-07-26
  EXEC_STRONG:
    model: strong-fixture
    invoke: scripts/exec-jail.sh strong-fixture
    quarantined: true
    jail_verified: true
    last_verified: 2026-07-26
  EXEC_LOCAL:
    model: local-fixture
    invoke: scripts/exec-jail.sh local-fixture
    quarantined: true
    jail_verified: true
    state: absent
    last_verified: 2026-07-26
"""
    usable_strong_route = all_quarantined_routes.replace(
        """  EXEC_STRONG:
    model: strong-fixture
    invoke: scripts/exec-jail.sh strong-fixture
    quarantined: true
    jail_verified: true
""",
        """  EXEC_STRONG:
    model: strong-fixture
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
        scenario_route_availability(),
        scenario_route_availability_gate(),
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
