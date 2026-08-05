#!/usr/bin/env sh
# validate-evidence-bundle — resolve one evidence bundle against local files.
#
# Shape is checked against schemas/evidence-bundle.schema.json, which is read and
# interpreted rather than restated here, so the declared contract and the
# enforced contract cannot drift apart. Everything plain JSON Schema cannot
# express is enforced on top: path containment, digest verification, reference
# consistency between the bundle, the executor-evidence artifact, and the
# cross-review artifact, and the standing prohibition on this record authorizing
# anything.
#
# The bundle directory is the directory the manifest sits in, and it is the only
# place an artifact may live. This validator opens local files and nothing else:
# it dereferences no network reference, resolves no remote store, and never runs
# a command recorded inside the evidence it reads. The two subordinate
# validators are the committed ones in this repository, invoked rather than
# reimplemented, so the executor-evidence and cross-review contracts have one
# enforcement point each.
#
# Usage: validate-evidence-bundle.sh <bundle.json> [<bundle.json> ...]
# Exit:  0 accepted, 1 rejected, 2 could not be checked.
set -eu

# shellcheck disable=SC1007  # CDPATH= is deliberately scoped to this cd.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for interpreter in python3 python py; do
    if command -v "$interpreter" >/dev/null 2>&1 &&
        "$interpreter" -c 'import sys; raise SystemExit(sys.version_info.major != 3)' >/dev/null 2>&1; then
        exec "$interpreter" - "$script_dir" "$@" <<'PY'
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

script_dir = Path(sys.argv[1])
documents = sys.argv[2:]
schema_path = script_dir.parent / "schemas" / "evidence-bundle.schema.json"
EXECUTOR_EVIDENCE_VALIDATOR = script_dir / "validate-executor-evidence.sh"
CROSS_REVIEW_VALIDATOR = script_dir / "validate-cross-review.sh"

if not documents:
    print("usage: validate-evidence-bundle.sh <bundle.json> [...]", file=sys.stderr)
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


ARTIFACT_PATTERN = resolve("#/$defs/artifact_reference")["pattern"]
KINDS = {bool: "boolean", int: "integer", str: "string", list: "array", dict: "object"}


def check(value, schema, path):
    """Evaluate the subset of JSON Schema this contract uses.

    Deliberately the same subset the executor-evidence and cross-review
    validators interpret: enough to read the committed schema, no more. An
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
            # A reference naming a remote location is the one malformed shape
            # worth naming separately: it is not a typo, it is a request for
            # this validator to reach outside the bundle, which it never does.
            if pattern == ARTIFACT_PATTERN and "://" in value:
                named = (
                    "artifact reference is a URL — an evidence bundle resolves local files "
                    "only and never dereferences a remote location"
                )
            elif pattern == ARTIFACT_PATTERN:
                named = "artifact reference does not match the required format"
            else:
                named = "does not match"
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
    return errors


COMPONENT = re.compile(r"^[A-Za-z0-9._-]+$")
WINDOWS_DRIVE = re.compile(r"^[A-Za-z]:[\\/]")


def path_error(bundle_dir, declared):
    """Why this artifact path cannot be resolved, or None.

    Every rule is checked against the declared string before the filesystem is
    touched, so a path that should never have been written down is refused for
    what it says rather than for what happens to exist. The symlink rule is
    checked on every component: a link anywhere in the chain can point the
    resolved bytes outside the bundle while each individual name looks local.
    """
    if "://" in declared:
        return "artifact path uses URL syntax — artifacts are local files inside the bundle"
    if WINDOWS_DRIVE.match(declared):
        return "artifact path uses Windows drive syntax"
    if declared.startswith("/") or declared.startswith("\\"):
        return "artifact path must be relative to the bundle directory"
    if "\\" in declared:
        return "artifact path must use '/' as its separator"
    if declared.startswith("~"):
        return "artifact path must not be a home-directory path"
    if "$" in declared or "%" in declared:
        return "artifact path must not carry an environment-variable or substitution reference"

    parts = declared.split("/")
    if ".." in parts:
        return "artifact path must not contain '..' — a bundle resolves nothing outside itself"
    if ".git" in parts:
        return "artifact path points into .git"
    for part in parts:
        if not COMPONENT.match(part):
            return f"artifact path component {part!r} is not a plain relative name"

    target = bundle_dir / declared
    walked = bundle_dir
    for part in parts:
        walked = walked / part
        if walked.is_symlink():
            return f"artifact path is a symlink at {part!r} — a bundle carries files, not links"
    if not os.path.lexists(target):
        return "artifact path does not exist"
    if target.is_dir():
        return "artifact path is a directory"
    if not target.is_file():
        return "artifact path is not a regular file"

    # Belt and braces. The rules above should make this unreachable; if some
    # future edit weakens one of them, containment still fails closed here.
    root = os.path.realpath(bundle_dir)
    resolved = os.path.realpath(target)
    if resolved != root and not resolved.startswith(root + os.sep):
        return "artifact path escapes the bundle directory once normalized"
    return None


def run_validator(validator, target):
    """Invoke a committed sibling validator. Never anything the bundle names.

    An absent interpreter or an absent validator is 'could not be checked', not
    'rejected' and emphatically not 'accepted': a contract nobody enforced must
    not read as a contract that passed.
    """
    if not validator.is_file():
        print(f"  [FAIL]  cannot check: {validator} is missing", file=sys.stderr)
        raise SystemExit(2)
    try:
        completed = subprocess.run(
            ["sh", str(validator), str(target)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
        )
    except OSError as error:
        print(f"  [FAIL]  cannot run {validator.name}: {error}", file=sys.stderr)
        raise SystemExit(2)
    if completed.returncode not in (0, 1):
        print(f"  [FAIL]  {validator.name} could not check the artifact "
              f"(exit {completed.returncode}): {completed.stdout.strip()}", file=sys.stderr)
        raise SystemExit(2)
    return completed.returncode, completed.stdout


def first_failure(output):
    for line in output.splitlines():
        if "[FAIL]" in line:
            return line.strip()
    return output.strip().splitlines()[-1] if output.strip() else "no output"


def semantic_errors(bundle, bundle_dir):
    """Everything JSON Schema cannot express, in the order a reader would ask it."""
    errors = []
    add = errors.append
    refs = bundle["refs"]
    artifacts = bundle["artifacts"]
    authority = bundle["authority"]

    # Standing prohibitions. True of every bundle, at every status.
    if authority["promotion_authorized_by_this_bundle"] is not False:
        add("authority.promotion_authorized_by_this_bundle must always be false — resolving "
            "evidence is not authorizing promotion")
    if authority["merge_authorized_by_this_bundle"] is not False:
        add("authority.merge_authorized_by_this_bundle must always be false — the operator "
            "merges by hand after watching the behavior check")

    # Reference integrity, before anything is read through a reference.
    by_ref = {}
    for index, entry in enumerate(artifacts):
        ref = entry["ref"]
        if ref in by_ref:
            add(f"artifacts[{index}]: duplicate artifact ref {ref!r} — one ref names one artifact")
            continue
        by_ref[ref] = entry

    REQUIRED = (
        ("executor_evidence_ref", "executor_evidence"),
        ("cross_review_ref", "cross_review"),
        ("diff_ref", "diff"),
        ("repo_status_ref", "repo_status"),
    )
    required_refs = [refs[name] for name, _ in REQUIRED]

    seen_paths = {}
    for entry in artifacts:
        if entry["ref"] not in required_refs:
            continue
        declared = entry["path"]
        if declared in seen_paths:
            add(f"duplicate artifact path {declared!r} — required artifacts {seen_paths[declared]!r} "
                f"and {entry['ref']!r} name the same file")
        seen_paths[declared] = entry["ref"]

    for name, kind in REQUIRED:
        ref = refs[name]
        entry = by_ref.get(ref)
        if entry is None:
            add(f"refs.{name} is {ref!r} but no artifact declares ref {ref!r}")
            continue
        if entry["kind"] != kind:
            add(f"refs.{name} resolves to an artifact of kind {entry['kind']!r}, expected {kind!r}")
        if entry["required"] is not True:
            add(f"refs.{name} resolves to an artifact declared required: false — the "
                f"{kind} artifact is required in every bundle")

    # Resolution and digests, for every artifact the bundle declares — including
    # any packet or result artifact. packet_ref and result_ref may name no
    # artifact at all in pass one, which is an honest record rather than a
    # defect; what they may not do is name one that fails to resolve.
    resolved = {}
    for index, entry in enumerate(artifacts):
        failure = path_error(bundle_dir, entry["path"])
        if failure is not None:
            add(f"artifacts[{index}] ({entry['ref']}): {failure} — found {entry['path']!r}")
            continue
        target = bundle_dir / entry["path"]
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        if digest != entry["sha256"]:
            add(f"artifacts[{index}] ({entry['ref']}): sha256 mismatch — recorded "
                f"{entry['sha256']}, computed {digest}")
            continue
        resolved[entry["ref"]] = target

    # From here the required artifacts are local files whose bytes are the ones
    # recorded, so their contents can be read and cross-checked.
    evidence_path = resolved.get(refs["executor_evidence_ref"])
    review_path = resolved.get(refs["cross_review_ref"])

    evidence = None
    if evidence_path is not None:
        code, output = run_validator(EXECUTOR_EVIDENCE_VALIDATOR, evidence_path)
        if code != 0:
            add(f"the executor_evidence artifact was rejected by "
                f"scripts/validate-executor-evidence.sh: {first_failure(output)}")
        else:
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))["executor_evidence"]

    review = None
    if review_path is not None:
        code, output = run_validator(CROSS_REVIEW_VALIDATOR, review_path)
        if code != 0:
            add(f"the cross_review artifact was rejected by "
                f"scripts/validate-cross-review.sh: {first_failure(output)}")
        else:
            review = json.loads(review_path.read_text(encoding="utf-8"))["cross_review"]

    unit = bundle["work_unit_id"]
    if evidence is not None and evidence["work_unit_id"] != unit:
        add(f"the executor-evidence artifact records work_unit_id "
            f"{evidence['work_unit_id']!r}, but the bundle is for {unit!r}")
    if review is not None and review["work_unit_id"] != unit:
        add(f"the cross-review artifact records work_unit_id "
            f"{review['work_unit_id']!r}, but the bundle is for {unit!r}")

    if review is not None:
        subject = review["subject"]
        for name in (
            "packet_ref",
            "result_ref",
            "executor_evidence_ref",
            "diff_ref",
            "repo_status_ref",
        ):
            if subject[name] != refs[name]:
                add(f"cross_review.subject.{name} is {subject[name]!r}, but the bundle's "
                    f"refs.{name} is {refs[name]!r} — the review reviewed something else")
        # The cross-review validator already forbids this. Asserting it here too
        # is what makes the bundle's own answer to "does this authorize a merge"
        # a check rather than an inherited assumption.
        if review["promotion"]["authorized_by_this_record"] is not False:
            add("the cross_review artifact claims promotion authority — no record this "
                "bundle carries can authorize promotion")
    return errors


rejected = 0
unreadable = 0
for name in documents:
    path = Path(name)
    print(f"validate-evidence-bundle — {path.name}")
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

    failures = check(document, SCHEMA, "evidence_bundle document")
    if not failures:
        # The bundle directory is the manifest's own directory, and resolution
        # never leaves it.
        failures = semantic_errors(document["evidence_bundle"], path.parent)

    if failures:
        for failure in failures:
            print(f"  [FAIL]  {failure}")
        print("  REJECT")
        rejected += 1
    else:
        print("  [ OK ]  shape, local artifact paths, digests, executor-evidence, cross-review, "
              "reference consistency, and the standing promotion prohibition satisfied")
        print("  ACCEPT")

if unreadable:
    raise SystemExit(2)
raise SystemExit(1 if rejected else 0)
PY
    fi
done

printf '%s\n' 'error: no Python 3 interpreter found (searched: python3, python, py)' >&2
exit 1
