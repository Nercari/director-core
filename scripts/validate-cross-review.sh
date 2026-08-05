#!/usr/bin/env sh
# validate-cross-review — check one cross-review ledger.
#
# Shape is checked against schemas/cross-review.schema.json, which is read and
# interpreted rather than restated here, so the declared contract and the
# enforced contract cannot drift apart. The cross-field rules plain JSON Schema
# cannot express — identity consistency, Layer 2 independence, blocker
# propagation, and the standing promotion prohibitions — are enforced on top.
#
# Every reference in the document is validated as a string and nothing more.
# This validator never fetches, opens, executes, replays, or proves the
# existence of anything a reference points at: the ledger records that a claim
# was made, and dereferencing it here would make validation an execution and
# network surface rather than a check.
#
# Usage: validate-cross-review.sh <document.json> [<document.json> ...]
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
schema_path = script_dir.parent / "schemas" / "cross-review.schema.json"

if not documents:
    print("usage: validate-cross-review.sh <document.json> [...]", file=sys.stderr)
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

    Deliberately small, and deliberately the same subset the executor-evidence
    validator interprets: enough to read the committed schema, no more. An
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

    if "oneOf" in schema and sum(not check(value, branch, path) for branch in schema["oneOf"]) != 1:
        errors.append(f"{path}: matches none of the permitted shapes")
    return errors


# Reasons a review can never be the independent one. Each is a fact about the
# recorded identities, not a judgement about the review's content.
def disqualifications(review, executor):
    reasons = []
    reviewer = review["reviewer"]
    if review["same_invocation_as_executor"] or (
        reviewer.get("invocation_id") == executor.get("invocation_id")
    ):
        reasons.append("shares the executor's invocation")
    if review["same_provider_as_executor"] or reviewer.get("provider") == executor.get("provider"):
        reasons.append("shares the executor's provider")
    if review["same_tool_as_executor"] or reviewer.get("tool") == executor.get("tool"):
        reasons.append("shares the executor's tool")
    if review["self_review_declared"]:
        reasons.append("declares a self-review")
    if review["mutation_authority"]:
        reasons.append("holds mutation authority")
    if review["changed_files"]:
        reasons.append("changed files")
    if not review["read_only"]:
        reasons.append("is not read_only")
    return reasons


def identity_contradictions(review, executor):
    """The same_* booleans are attestations; recompute and reject contradictions.

    Reconciling silently would let a record assert an identity relation the
    identities themselves deny, which is the exact claim this ledger exists to
    be able to refuse.
    """
    reviewer = review["reviewer"]
    errors = []
    for field, label, plural in (
        ("tool", "tool", "tools"),
        ("provider", "provider", "providers"),
        ("invocation_id", "invocation_id", "invocation ids"),
    ):
        flag = "same_invocation_as_executor" if field == "invocation_id" else f"same_{label}_as_executor"
        declared = review[flag]
        actual = reviewer.get(field) is not None and reviewer.get(field) == executor.get(field)
        if declared != actual:
            errors.append(
                f"declares {flag} {json.dumps(declared)}, but the recorded {plural} "
                f"{'are' if actual else 'are not'} identical"
            )
    return errors


def semantic_errors(ledger):
    """Cross-field rules. Plain JSON Schema cannot express these."""
    executor = ledger["executor"]
    reviews = ledger["reviews"]
    layer2 = ledger["layer2"]
    promotion = ledger["promotion"]
    adapter_internal = ledger["adapter_internal_verification"]
    errors = []
    add = errors.append

    # Standing prohibitions. True at every status, for every shape of record.
    if layer2["auto_promotion_allowed_by_this_record"] is not False:
        add("layer2.auto_promotion_allowed_by_this_record must always be false — this "
            "ledger never arms auto-merge")
    if promotion["authorized_by_this_record"] is not False:
        add("promotion.authorized_by_this_record must always be false — review evidence "
            "may add reasons to reject, never the reason to merge")
    if adapter_internal["counts_as_independent_layer2"] is not False:
        add("adapter_internal_verification.counts_as_independent_layer2 must always be "
            "false — adapter-local verification of adapter-local work is not independent")

    if adapter_internal["present"] is True and adapter_internal["verifier"] is None:
        add("adapter_internal_verification.present == true requires a named verifier")
    if adapter_internal["present"] is False:
        if adapter_internal["verifier"] is not None:
            add("adapter_internal_verification.present == false requires verifier to be null")
        if adapter_internal["evidence_ref"] is not None:
            add("adapter_internal_verification.present == false requires evidence_ref to be null")

    if executor["changed_files"] and executor["mutation_authority"] is not True:
        add("executor.changed_files is non-empty, so executor.mutation_authority must be true")

    behavior = ledger["behavior_check"]
    if behavior["completed"] is True and behavior["evidence_ref"] is None:
        add("behavior_check.completed == true requires an evidence_ref")
    if behavior["completed"] is False and behavior["evidence_ref"] is not None:
        add("behavior_check.completed == false requires evidence_ref to be null")

    # Reference integrity, before anything reads through those references.
    identifiers = [review["review_id"] for review in reviews]
    seen = set()
    for identifier in identifiers:
        if identifier in seen:
            add(f"duplicate review_id {identifier!r} — review ids must be unique")
        seen.add(identifier)
    by_id = {review["review_id"]: review for review in reviews}
    auxiliary = layer2["auxiliary_review_ids"]
    for identifier in auxiliary:
        if identifier not in by_id:
            add(f"layer2.auxiliary_review_ids entry {identifier!r} names no review in reviews[]")
    for identifier in promotion["blocking_review_ids"]:
        if identifier not in by_id:
            add(f"promotion.blocking_review_ids entry {identifier!r} names no review in reviews[]")

    # Identity attestations, and the reviews that can never be independent.
    for index, review in enumerate(reviews):
        identifier = review["review_id"]
        for contradiction in identity_contradictions(review, executor):
            add(f"reviews[{index}] ({identifier}): {contradiction}")
        if review["read_only"] is True and review["mutation_authority"] is True:
            add(f"reviews[{index}] ({identifier}): read_only == true contradicts "
                f"mutation_authority == true")
        if review["read_only"] is True and review["changed_files"]:
            add(f"reviews[{index}] ({identifier}): read_only == true contradicts a non-empty "
                f"changed_files")
        if disqualifications(review, executor) and identifier not in auxiliary:
            add(f"reviews[{index}] ({identifier}): must be recorded in "
                f"layer2.auxiliary_review_ids — it "
                + ", ".join(disqualifications(review, executor)))

    # A blocker blocks the whole record, wherever it was recorded. There is no
    # resolution field and no resolved-blocker exception in this version.
    blocking = sorted(
        review["review_id"]
        for review in reviews
        if review["verdict"] == "blocked"
        or any(finding["severity"] == "blocker" for finding in review["findings"])
    )
    if blocking:
        named = ", ".join(blocking)
        if layer2["independent_review_satisfied"] is not False:
            add("a blocker finding or a blocked verdict requires "
                f"layer2.independent_review_satisfied == false — recorded on: {named}")
        if promotion["blocked_by_this_record"] is not True:
            add("a blocker finding or a blocked verdict requires "
                f"promotion.blocked_by_this_record == true — recorded on: {named}")
        missing = [identifier for identifier in blocking
                   if identifier not in promotion["blocking_review_ids"]]
        if missing:
            add("promotion.blocking_review_ids must name every review carrying a blocker "
                "finding or a blocked verdict — missing: " + ", ".join(missing))

    named_id = layer2["independent_review_id"]
    if layer2["independent_review_satisfied"] is False:
        if named_id is not None:
            add("layer2.independent_review_satisfied == false requires "
                "independent_review_id to be null")
        return errors

    # From here the record claims independent Layer 2, so every condition holds.
    if not isinstance(named_id, str) or not named_id:
        add("layer2.independent_review_satisfied == true requires independent_review_id "
            "to name a review — multiple auxiliary reviews never aggregate into an "
            "independent one")
        return errors
    if named_id in auxiliary:
        add(f"layer2.independent_review_id {named_id!r} also appears in "
            f"auxiliary_review_ids — a review is one or the other")
    if named_id not in by_id:
        add(f"layer2.independent_review_id {named_id!r} names no review in reviews[]")
        return errors

    review = by_id[named_id]
    for reason in disqualifications(review, executor):
        add(f"independent Layer 2 forbids a reviewer that {reason} — {named_id} {reason}")
    if review["verdict"] != "pass":
        add(f"independent Layer 2 requires the named review to pass — {named_id} "
            f"recorded verdict {review['verdict']!r}")
    # Two unknowns cannot be mechanically proven distinct, so an unrecorded or
    # unrecognised identity on either side cannot support an independence claim.
    for who, identity in (("executor", executor), (f"reviewer {named_id}", review["reviewer"])):
        for field in ("tool", "provider"):
            if identity.get(field) == "other":
                add(f"independent Layer 2 cannot be claimed when either side records "
                    f"{field}: other — {who} does")
    if adapter_internal["present"] is True and review["reviewer"].get("adapter") is not None:
        if review["reviewer"]["adapter"] == adapter_internal["verifier"]:
            add(f"independent Layer 2 forbids naming adapter-internal verification as the "
                f"independent review — {named_id} runs under the same adapter as "
                f"adapter_internal_verification.verifier")
    return errors


rejected = 0
unreadable = 0
for name in documents:
    path = Path(name)
    print(f"validate-cross-review — {path.name}")
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

    failures = check(document, SCHEMA, "cross_review document")
    if not failures:
        # References are read as strings here and never dereferenced. Fetching
        # what a reviewed party supplied would make this validator a network and
        # execution surface rather than a check.
        failures = semantic_errors(document["cross_review"])

    if failures:
        for failure in failures:
            print(f"  [FAIL]  {failure}")
        print("  REJECT")
        rejected += 1
    else:
        print("  [ OK ]  shape, enums, references, identity consistency, Layer 2, and "
              "promotion rules satisfied")
        print("  ACCEPT")

if unreadable:
    raise SystemExit(2)
raise SystemExit(1 if rejected else 0)
PY
    fi
done

printf '%s\n' 'error: no Python 3 interpreter found (searched: python3, python, py)' >&2
exit 1
