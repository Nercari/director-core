# Evidence bundle

A local, deterministic set of artifacts for one work unit, listed by reference and pinned
by digest. The contract is `schemas/evidence-bundle.schema.json`;
`scripts/validate-evidence-bundle.sh` resolves a manifest against it.

It answers one question: **do the references that executor-evidence and cross-review
already carry resolve to local, inspectable files whose bytes are the ones recorded?**
Until something resolves them, `artifact:diff` is a well-formed string and nothing more.

## What it is, and what it is not

The bundle is **local and deterministic**. It resolves files on disk, compares digests,
and reads two artifacts with the validators that already own those contracts. Run twice on
the same bytes it gives the same answer, with no network, no clock, and no model.

It is **not** a claim about anything it cannot see:

- It does not prove **human behavior**. Whether an operator watched a behavior check
  happens outside every record here. A bundle whose cross-review says the check is
  required and not completed is a valid bundle — that is the honest shape, not a defect.
- It does not prove **restricted-account execution**. Nothing in a bundle establishes
  which account produced the artifacts.
- It does not prove **OS sandboxing, network containment, or credential isolation**.
  Those are properties of how an executor was run; a bundle is what was left behind.
- It does not implement **same-vendor cycle refusal**. Reviewer and executor identity
  rules live in `schemas/cross-review.schema.json` and are enforced there.
- It grants **no authority to commit, push, open a pull request, merge, deploy, or
  promote anything.** `authority.promotion_authorized_by_this_bundle` and
  `authority.merge_authorized_by_this_bundle` are always `false`, and a bundle that says
  otherwise is rejected. Auto-merge is off; the operator merges by hand.

Every example uses placeholder identities — `example-unit`, `example-adapter`,
`example-exec-invocation`, `artifact:executor-evidence`, `artifact:diff`.

## The bundle directory is the boundary

The **bundle directory** is the directory the manifest file sits in. Every artifact path
is relative to it, and resolution never leaves it.

`artifacts[].path` is rejected when it is absolute, contains `..`, points into `.git`,
uses URL or Windows-drive syntax, uses `\` as a separator, starts with `~`, carries a `$`
or `%` substitution, contains anything outside `[A-Za-z0-9._-]` in a component, is a
symlink at any component of the chain, is a directory, is not a regular file, or does not
exist. After all of that, containment is checked once more against the normalized real
path, so a weakened rule fails closed rather than open.

The symlink rule is checked per component and not only on the leaf: a link partway down
the chain can point the resolved bytes outside the bundle while every individual name
still looks local. A conformance scenario links an artifact to a **byte-identical** file
outside the bundle, so only the symlink rule can reject it.

## References are `artifact:` only

`refs` requires six non-empty references: `packet_ref`, `result_ref`,
`executor_evidence_ref`, `cross_review_ref`, `diff_ref`, `repo_status_ref`. Each must
match:

```
^artifact:[A-Za-z0-9._/-]+$
```

That is the artifact-only narrowing of the reference format executor-evidence and
cross-review share. Pass one resolves nothing else, so a `file:`, `commit:`, or `run:`
reference — which names something outside the bundle — is refused rather than silently
skipped. A conformance scenario derives this pattern from the shared one, so a change to
either fails a check instead of drifting.

**Network dereferencing is forbidden, and a URL reference is rejected.** `http://`,
`https://`, SSH URLs, and `file://` all fail the format, and a URL is named as such in
the rejection rather than reported as a generic typo. There is no remote artifact store,
no fetching, and no way to complete a bundle by reaching for something. A conformance
scenario asserts the validator carries no import or command capable of dereferencing a
remote reference at all, because the URL fixture proves a URL is refused and cannot prove
the capability is absent.

## Every artifact is hashed

`sha256` is required on every artifact, as 64 lowercase hex characters. The validator
recomputes the digest of the resolved file and rejects a mismatch. A recorded digest is a
claim until something recomputes it.

`kind` is a narrow public enum: `packet`, `result`, `executor_evidence`, `cross_review`,
`diff`, `repo_status`, `test_log`, `acceptance_map`, `other`.

A bundle must carry resolvable, `required: true` artifacts for **`executor_evidence`,
`cross_review`, `diff`, and `repo_status`**. `packet_ref` and `result_ref` need not have
an artifact behind them in pass one — a reference with nothing carried for it is an
honest record. What they may not do is name an artifact that fails to resolve or hash.

Refs must be unique. Two required artifacts may not share one path.

## Command records are never replayed

`verification.commands_run[].command` inside an executor-evidence artifact is **evidence
text**. The bundle validator opens that artifact — which is exactly the step that could
turn a recorded command into an executed one — and never runs anything it finds there.

The fixture in `examples/evidence-bundle/artifacts/executor-evidence.json` carries a
harmless sentinel-writing command for this reason. A conformance scenario rewrites it to
write an observable file into a temporary directory and asserts that file does not appear,
so the guarantee is checked against the filesystem rather than asserted in prose.

The only commands this validator runs are the two committed sibling validators, named by
path in this repository. Nothing a bundle contains can name a command to run.

## The two validators are reused, not reimplemented

The executor-evidence artifact is checked by `scripts/validate-executor-evidence.sh` and
the cross-review artifact by `scripts/validate-cross-review.sh`. Each contract keeps one
enforcement point, so a bundle cannot accept an envelope those validators reject.

On top of that, the bundle checks the consistency no single document can check alone:

- `work_unit_id` matches across the bundle, the executor-evidence artifact, and the
  cross-review artifact.
- `cross_review.subject.packet_ref`, `result_ref`, `executor_evidence_ref`, `diff_ref`,
  and `repo_status_ref` each equal the bundle's corresponding `refs` entry. A review that
  reviewed something else is not evidence about this bundle.
- The cross-review artifact does not claim promotion authority.

## Running it

```sh
sh scripts/validate-evidence-bundle.sh examples/evidence-bundle/minimal-fulfilled.valid.json
```

Exit `0` accepted, `1` rejected, `2` could not be checked.

Fixtures live in `examples/evidence-bundle/`. Manifests sit at the top level and share one
`artifacts/` subdirectory, because a bundle directory is whatever directory the manifest
sits in — giving each manifest its own copy of four artifacts would multiply fixture data
without testing anything the shared tree does not already test. Every manifest is
registered by name in `scripts/conformance.py`; a fixture cannot be added, renamed, or
deleted without a conformance failure naming it.

CI validates the bundle contract through the existing path only: schema, fixtures,
conformance, and `scripts/check-example-sanitization.sh`. No live model call, no network
artifact resolution, no private route.
