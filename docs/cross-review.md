# Cross-review ledger

A recorded review-identity and evidence-adequacy ledger for one work unit. The contract is
`schemas/cross-review.schema.json`; `scripts/validate-cross-review.sh` checks a document
against it.

It records who mutated, who reviewed, whether the review was read-only, whether that review
can count as independent Layer 2 under current policy, whether findings block promotion,
and whether the human behavior check is still required.

## What it is, and what it is not

**This is not an independence guarantee.** It is a deterministic record that can reject a
false independence claim and a false completion claim. Nothing about it makes an
independent review happen; it makes an unsupported claim of one fail a check.

The ledger is **provider-neutral and adapter-neutral**. Identities are public enums —
`codex`, `claude`, `antigravity`, `human`, `other` for tools, and `openai`, `anthropic`,
`google`, `human`, `other` for providers. Private model names, private route names, and
private aliases never appear in this contract or in its examples.

An adapter name may appear in an example in the sanitized form `<vendor>-example`.
Moonrail appears in `examples/cross-review/` as an example adapter and skill name only:
Director Core does not depend on Moonrail, and Moonrail is not a Director Core route.

Every example uses placeholder identities — `example-unit`, `example-exec-invocation`,
`example-review-invocation`, `artifact:executor-evidence`, `artifact:diff`,
`artifact:repo-status`.

## The subject is referenced, never dereferenced

`subject.packet_ref`, `result_ref`, `executor_evidence_ref`, `diff_ref`, and
`repo_status_ref` must each be a non-empty string in the reference format the
executor-evidence contract already uses:

```
^(artifact|file|commit|run):[A-Za-z0-9._/-]+$
```

A conformance scenario asserts this pattern is identical in both schemas, so the two cannot
drift apart.

`subject.executor_evidence_ref` is **a validated reference string only**. The validator does
not fetch, open, execute, replay, or prove the existence of what any reference points at,
and a conformance scenario asserts that a reference whose target exists is neither read nor
reported. The ledger records that a claim was made — not that the referenced artifact
exists or says what the record claims. Artifact existence and content verification belongs
to a later artifact-store integration, which does not exist yet.

## Identity attestations are recomputed

`same_tool_as_executor`, `same_provider_as_executor`, and `same_invocation_as_executor` are
redundant against the recorded identities on purpose. They are attestations: the validator
recomputes each from `executor` and `reviewer` and rejects any contradiction in either
direction. A record that declares "different provider" while recording the same provider is
a bad record, not something to reconcile silently. That is why the fields exist and why
they must not later be simplified away.

## When independent Layer 2 may be claimed

`layer2.independent_review_satisfied: true` is accepted only if all of the following hold:

- `independent_review_id` is a non-empty string naming an existing review
- that id does not appear in `auxiliary_review_ids`
- the named reviewer shares neither the executor's invocation, provider, nor tool
- neither executor nor reviewer records `tool: other` or `provider: other`
- the reviewer is `read_only: true`, holds no mutation authority, and changed no files
- `self_review_declared: false`
- the named review's verdict is `pass`
- no review carries a `blocker` finding and no review has `verdict: blocked`
- adapter-internal verification is not the review being named

Review ids are unique. `independent_review_id` is a required key — absent is invalid, and
`null` is required when independence is not satisfied. There is **no aggregation**:
multiple auxiliary reviews never add up to one independent review.

## What each kind of review can claim

| Review | Can claim | Cannot claim |
|---|---|---|
| distinct tool **and** provider, read-only, passing | independent Layer 2 | promotion, merge, or that the behavior check ran |
| same provider as the executor | auxiliary evidence, findings, reject reasons | independent Layer 2 |
| same tool as the executor | auxiliary evidence, findings, reject reasons | independent Layer 2 |
| same invocation as the executor | nothing beyond a recorded self-review | independent Layer 2 |
| either side recorded as `other` | auxiliary evidence only | independent Layer 2 — two unknowns cannot be mechanically proven distinct |
| adapter-internal verification | useful local evidence | independent Layer 2, ever |

A review must be recorded as auxiliary when it shares the executor's tool, provider, or
invocation; when either identity is `other`, missing, or ambiguous; when the reviewer held
mutation authority, changed files, or proposed fixes in the same unit; or when self-review
is declared or mechanically implied. The validator rejects a record that leaves such a
review out of `auxiliary_review_ids`.

## Cross-review matrix

| Executor | Reviewer | Status |
|---|---|---|
| Claude | Codex/Moonrail read-only | independent only if provider and tool are distinct and the reviewer is read-only |
| Codex direct using a Moonrail skill | Claude read-only | independent only if Claude is read-only and identity is mechanically recorded |
| Antigravity/Moonrail | Claude or Codex/Moonrail read-only | independent only if Antigravity does not arbitrate itself |
| Codex/Moonrail | Codex/Moonrail | auxiliary only |
| Claude | Claude | auxiliary only |

The first two rows are the committed fixtures
`cross-executor-review-distinct-provider.valid.json` and
`cross-reviewer-executor-swapped.valid.json`. The same-vendor rows are
`same-provider-auxiliary-only.valid.json` and the same-tool and same-provider invalid
fixtures. Self-arbitration is
`adapter-internal-verification-auxiliary.valid.json` and
`adapter-internal-independent.invalid.json`.

## Blockers block the whole record

Any review with `verdict: blocked`, and any finding with `severity: blocker`, forces
`layer2.independent_review_satisfied: false` and `promotion.blocked_by_this_record: true`,
and must be named in `promotion.blocking_review_ids`. This holds **even when the blocker
sits on an auxiliary review** rather than the one named independent.

There is no resolution mechanism in this version. `finding.status` is not a field, so a
finding carrying resolution wording is rejected as an unrecognised field rather than
interpreted as a resolved blocker.

## Promotion, which this record never grants

`layer2.auto_promotion_allowed_by_this_record` must always be `false`.
`promotion.authorized_by_this_record` must always be `false`. Both are rejected when true.

`promotion.blocked_by_this_record: false` means only that this ledger recorded no
promotion-blocking review finding. It never means promotion is authorized. Review evidence
may add reasons to reject; it may never be the reason to merge.

## The four roles

1. **Director Core authority** — the schema, the validator, and this document.
2. **Executor** — `executor`, the one mutator for the unit.
3. **Reviewer, independent or auxiliary** — `reviews[]` and `layer2`.
4. **Human operator promotion authority** — `behavior_check` and
   `promotion.authorized_by_this_record: false`.

`role-separated-pattern.valid.json` is the fixture that shows all four at once.

## The behavior check stays outside

The human behavior check is not part of this ledger and is not satisfied by it. A missing
one is recorded honestly:

```json
"behavior_check": { "required": true, "completed": false, "evidence_ref": null }
```

`completed: false` requires a null reference and `completed: true` requires a real one, so
"the check ran" cannot be recorded without pointing at something.

## What this ledger does not do

- It does **not** prove that a review was actually independent. It records identity claims
  in a checkable shape and refuses claims those identities contradict.
- It does **not** prove the referenced packet, result, diff, repo status, or executor
  evidence exists, is complete, or says what the record claims.
- It does **not** replace deterministic CI. No model review can.
- It does **not** replace the human behavior check for observable behavior.
- It does **not** enforce the full operational same-vendor cycle refusal. It records and
  validates cross-review claims; refusing to run such a cycle in the first place is
  separate and still open.
- It does **not** prove restricted-account execution, OS sandboxing, network containment,
  or credential isolation.
- It does **not** prove any behavior check was watched or completed.
- It does **not** authorize a commit, a push, a pull request, a merge, a deployment, or a
  promotion. It is a record, and records confer no authority.

## Validating a document

```sh
sh scripts/validate-cross-review.sh examples/cross-review/role-separated-pattern.valid.json
sh scripts/check-example-sanitization.sh examples/cross-review
```

Exit `0` accepted, `1` rejected, `2` could not be checked. Both run inside
`scripts/conformance.sh`, which CI already invokes; every fixture is registered by name in
`scripts/conformance.py`, so a fixture cannot be added, renamed, or deleted without a
conformance failure naming it.

## A note on how shape is enforced

Same approach as the executor-evidence contract, for the same reason: the validator reads
`schemas/cross-review.schema.json` and interprets it rather than restating the shape, then
applies on top the cross-field rules — identity consistency, Layer 2 independence, blocker
propagation, and the standing promotion prohibitions — that plain JSON Schema cannot
express. The schema stays the single declaration of shape.
