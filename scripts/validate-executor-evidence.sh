#!/usr/bin/env sh
# validate-executor-evidence — check one executor evidence envelope.
#
# Shape is checked against schemas/executor-evidence.schema.json, which is read
# and interpreted rather than restated here, so the declared contract and the
# enforced contract cannot drift apart. Cross-field fulfillment rules, which
# plain JSON Schema cannot express, are enforced on top of that.
#
# Usage: validate-executor-evidence.sh <document.json> [<document.json> ...]
# Exit:  0 accepted, 1 rejected, 2 could not be checked.
set -eu

# shellcheck disable=SC1007  # CDPATH= is deliberately scoped to this cd.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for interpreter in python3 python py; do
    if command -v "$interpreter" >/dev/null 2>&1 &&
        "$interpreter" -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
        exec "$interpreter" - "$script_dir" "$@" <<'PY'
import json
import re
import sys
from pathlib import Path

script_dir = Path(sys.argv[1])
documents = sys.argv[2:]
schema_path = script_dir.parent / "schemas" / "executor-evidence.schema.json"

if not documents:
    print("usage: validate-executor-evidence.sh <document.json> [...]", file=sys.stderr)
    raise SystemExit(2)
try:
    SCHEMA = json.loads(schema_path.read_text(encoding="utf-8"))
except OSError as error:
    print(f"cannot read {schema_path}: {error}", file=sys.stderr)
    raise SystemExit(2)


def resolve(ref):
    node = SCHEMA
    for part in ref.lstrip("#/").split("/"):
        node = node[part]
    return node


EVIDENCE_PATTERN = resolve("#/$defs/evidence_reference")["pattern"]
KINDS = {bool: "boolean", int: "integer", str: "string", list: "array", dict: "object"}


def check(value, schema, path):
    """Evaluate the subset of JSON Schema this contract uses.

    Deliberately small: enough to interpret the committed schema, no more. An
    unrecognised keyword is ignored rather than guessed at.
    """
    if "$ref" in schema:
        return check(value, resolve(schema["$ref"]), path)
    errors = []
    found = "null" if value is None else KINDS.get(type(value), "number")

    if "type" in schema:
        allowed = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if found not in allowed:
            return [f"{path}: expected {'/'.join(allowed)}, found {found}"]
    if "const" in schema and value != schema["const"]:
        return [f"{path}: expected {json.dumps(schema['const'])}, found {json.dumps(value)}"]
    if "enum" in schema and value not in schema["enum"]:
        allowed = ", ".join(json.dumps(option) for option in schema["enum"])
        return [f"{path}: {json.dumps(value)} is not one of [{allowed}]"]

    if found == "string":
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{path}: must not be empty")
        pattern = schema.get("pattern")
        if pattern is not None and re.search(pattern, value) is None:
            named = (
                "evidence reference does not match the required format"
                if pattern == EVIDENCE_PATTERN
                else "does not match"
            )
            errors.append(f"{path}: {named} {pattern} — found {json.dumps(value)}")

    if found == "object":
        properties = schema.get("properties", {})
        errors += [
            f"{path}: missing required field {name!r}"
            for name in schema.get("required", [])
            if name not in value
        ]
        if schema.get("additionalProperties") is False:
            errors += [f"{path}: unexpected field {n!r}" for n in value if n not in properties]
        for name, subschema in properties.items():
            if name in value:
                errors += check(value[name], subschema, f"{path}.{name}")

    if found == "array" and "items" in schema:
        for index, item in enumerate(value):
            errors += check(item, schema["items"], f"{path}[{index}]")

    if "oneOf" in schema and sum(not check(value, b, path) for b in schema["oneOf"]) != 1:
        errors.append(
            f"{path}: command record matches neither the ran shape "
            f"(command, exit_code, evidence_reference) nor the not-run shape "
            f"(command, not_run: true, blocker_id or evidence_reference)"
        )
    if "anyOf" in schema and all(check(value, b, path) for b in schema["anyOf"]):
        errors.append(f"{path}: satisfies none of the permitted shapes")
    return errors


def semantic_errors(evidence):
    """Cross-field rules. Plain JSON Schema cannot express these."""
    route, scope = evidence["route"], evidence["scope"]
    verification = evidence["verification"]
    criteria = evidence["acceptance"]["criteria"]
    commands = verification["commands_run"]
    blocker_ids = {blocker["id"] for blocker in evidence["blockers"]}
    errors = []

    # Applies at every status: a not-run record pointing at a blocker that does
    # not exist is an unresolvable reference, not an explanation.
    for index, command in enumerate(commands):
        named = command.get("blocker_id")
        if command.get("not_run") is True and named is not None and named not in blocker_ids:
            errors.append(
                f"verification.commands_run[{index}]: blocker_id {named!r} "
                f"matches no entry in blockers[]"
            )
    if evidence["status"] == "blocked" and not evidence["blockers"]:
        errors.append("status=blocked requires at least one entry in blockers[]")
    if evidence["status"] != "fulfilled":
        return errors

    add = errors.append
    if route["route_verified"] is not True:
        add("fulfilled requires route.route_verified == true")
    if route["mutation_source_verified"] is not True:
        add("fulfilled requires route.mutation_source_verified == true")
    if scope["forbidden_files_changed"]:
        add("fulfilled requires scope.forbidden_files_changed to be empty — found "
            + ", ".join(scope["forbidden_files_changed"]))
    if not criteria:
        add("fulfilled requires at least one acceptance criterion")
    not_pass = [c["id"] for c in criteria if c["status"] != "pass"]
    if not_pass:
        add("fulfilled requires every acceptance criterion to be pass — not pass: "
            + ", ".join(not_pass))
    unevidenced = [c["id"] for c in criteria if c["status"] == "pass" and not c["evidence"]]
    if unevidenced:
        add("fulfilled requires every acceptance criterion to carry an evidence reference"
            " — without one: " + ", ".join(unevidenced))
    if verification["diff_inspected"] is not True:
        add("fulfilled requires verification.diff_inspected == true")
    if verification["repo_status_inspected"] is not True:
        add("fulfilled requires verification.repo_status_inspected == true")
    if verification["secret_or_external_action_issue"] is not False:
        add("fulfilled requires verification.secret_or_external_action_issue == false")
    if verification["tests_blocked"]:
        add("fulfilled requires verification.tests_blocked to be empty — found "
            + ", ".join(verification["tests_blocked"]))
    # A command that never ran belongs in a blocked, partial, or failed envelope,
    # where it carries blocker context. It is never part of a completion claim.
    unrun = [c["command"] for c in commands if c.get("not_run") is True]
    if unrun:
        add("fulfilled forbids a not_run command record — a command that did not run "
            "belongs in a blocked, partial, or failed envelope: " + ", ".join(unrun))
    return errors


rejected = 0
unreadable = 0
for name in documents:
    path = Path(name)
    print(f"validate-executor-evidence — {path.name}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        print(f"  [FAIL]  cannot read: {error}")
        unreadable += 1
        continue
    except ValueError as error:
        print(f"  [FAIL]  not valid JSON: {error}")
        rejected += 1
        continue

    failures = check(document, SCHEMA, "executor_evidence document")
    if not failures:
        # Command records are read here and never executed. Replaying a string
        # supplied by the thing under review would make this validator an
        # execution surface rather than a check.
        failures = semantic_errors(document["executor_evidence"])

    if failures:
        for failure in failures:
            print(f"  [FAIL]  {failure}")
        print("  REJECT")
        rejected += 1
    else:
        print("  [ OK ]  shape, enums, evidence references, and fulfillment rules satisfied")
        print("  ACCEPT")

if unreadable:
    raise SystemExit(2)
raise SystemExit(1 if rejected else 0)
PY
    fi
done

printf '%s\n' 'error: no Python 3 interpreter found (searched: python3, python, py)' >&2
exit 1
