# Executor evidence envelope

A normalized record an executor adapter submits about one work unit. The contract is
`schemas/executor-evidence.schema.json`; `scripts/validate-executor-evidence.sh` checks a
document against it.

## What it is

The envelope is **adapter-neutral**. Director Core does not depend on any adapter, runtime,
authentication flow, or model. An adapter name may appear in an example, in the sanitized
form `<vendor>-example`, and that is the only sense in which any adapter is named here.
Nothing in this contract makes one a dependency.

Every example under `examples/executor-evidence/` uses placeholder identities —
`example-adapter`, `example-executor`, `example-invocation`, `artifact:test-log`.

## Evidence references

`acceptance.criteria[].evidence[]` and `commands_run[].evidence_reference` must match:

```
^(artifact|file|commit|run):[A-Za-z0-9._/-]+$
```

This is a positive format, not a list of banned phrases. `"it worked"` and
`"all checks came back clean"` are rejected for the same structural reason: they point at
nothing retrievable. A narrative summary is not evidence.

## Command records are records

`verification.commands_run[]` is a log of what happened. **No validator replays it.** The
envelope is composed from material the executor supplies, so executing the strings inside
it would turn a record into an execution surface. Conformance asserts this directly: a
document whose command records would create a file is validated, and the file must not
appear.

Two shapes are accepted, and exactly one applies to any record:

| Shape | Required | Notes |
|---|---|---|
| ran | `command`, `exit_code`, `evidence_reference` | `not_run` absent or `false` |
| not run | `command`, `not_run: true`, and one of `blocker_id` / `evidence_reference` | `exit_code` must be absent |

A `blocker_id` must name a real entry in `blockers[]`. An exit code is never required for a
command that did not run, because there is no exit code to report.

## What `fulfilled` requires

`status: fulfilled` is rejected unless all of the following hold:

- `route.route_verified == true`
- `route.mutation_source_verified == true`
- `scope.forbidden_files_changed` is empty
- at least one acceptance criterion exists, and every one has `status: pass`
- every criterion carries at least one evidence reference in the format above
- `verification.diff_inspected == true`
- `verification.repo_status_inspected == true`
- `verification.secret_or_external_action_issue == false`
- `verification.tests_blocked` is empty
- no command record has `not_run: true`

A command that never ran belongs in a `blocked`, `partial`, or `failed` envelope, where it
carries blocker context. It is never part of a claim of completion.

## What honest non-completion can say

`blocked`, `partial`, and `failed` envelopes are first-class and valid, provided they name
what they hit rather than implying completion. A `blocked` envelope must carry at least one
blocker. `partial` may report some criteria passing and others blocked. `failed` may report
a non-zero exit code with the evidence reference for its log. None of these is a degraded
form of `fulfilled`; each is the accurate answer to a different outcome.

## Enums

Three string enums, with no boolean anywhere in them:

```
status                       fulfilled | partial | blocked | failed
acceptance criterion status  pass | fail | blocked
dirty_worktree_preserved     preserved | not_preserved | not_applicable
```

`route_verified`, `mutation_source_verified`, `diff_inspected`, `repo_status_inspected`,
and `secret_or_external_action_issue` are booleans.

## Example sanitizer

`scripts/check-example-sanitization.sh` scans `examples/executor-evidence/**` for
credential-shaped names, key-like prefixes, private key blocks, absolute filesystem paths,
URLs carrying credentials, non-public hostnames, and long high-entropy strings. The
committed patterns are generic; a denylist naming real aliases would publish the topology
it protects. Site-specific patterns go in `.sanitizer-denylist.local`, which is untracked,
read when present, and skipped silently when absent. CI never depends on it.

The sanitizer's negative case lives in `tests/sanitizer/executor-evidence/`, outside the
scanned tree, as a template whose offending strings are assembled at run time and deleted
after the assertion. See that directory's README.

## What this envelope does not do

Stated plainly, because each of these is a claim the envelope could be mistaken for:

- It does **not** prove the recorded commands actually ran. It records that an executor
  said they did, in a checkable shape, pointing at named evidence.
- It does **not** prove the referenced evidence is complete, or that it says what the
  envelope claims.
- It does **not** prove that every test a work packet required was sufficient, or was run.
  Comparing packet to evidence is separate machinery and does not exist yet.
- It does **not** prove review independence, and does not address a same-vendor review
  cycle.
- It does **not** prove restricted-account execution.
- It does **not** prove OS sandboxing, network containment, credential isolation, or that
  any behavior check was watched and completed.
- It does **not** authorize a commit, a push, a pull request, a merge, a deployment, or a
  promotion. It is a record, and records confer no authority.

## Validating a document

```sh
sh scripts/validate-executor-evidence.sh examples/executor-evidence/fulfilled.valid.json
sh scripts/check-example-sanitization.sh
```

Exit `0` accepted, `1` rejected, `2` could not be checked. Both run inside
`scripts/conformance.sh`, which CI already invokes.

## A note on how shape is enforced

`check-jsonschema` is not guaranteed present on an operator machine, and the fulfillment
rules are cross-field conditionals that plain JSON Schema cannot express. Rather than
restate the shape in a second place, the validator reads
`schemas/executor-evidence.schema.json` and interprets it, then applies the cross-field
rules on top. The schema stays the single declaration of shape; only the cross-field rules
live in code.
