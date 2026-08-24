# A0 capture implementation packets

These packets decompose the reviewed A0 capture specification at commit
`5e49f41ac03d2279ddc4e33cb7058d22f14e2ae1`. They are planning artifacts,
not authorization to implement or collect A0.

All packets are `change_class: behavior`, use `EXEC_STRONG`, and are based on
source revision `d0409936005d2161ae10f3ce1d08a3b9eaaf5854`. Refreshing a packet's
base at execution time requires a reviewed packet update; it must not be done
silently.

## Packet materialization and review order

1. Run the reviewed `bash scripts/worktree.sh create <unit-id>` command.
2. Record the `base_commit` reported in `.director/runs/<unit-id>/worktree.yaml`.
3. After the reported base matches the reviewed packet's `base_commit`, the
   orchestrator materializes `.director/runs/<unit-id>/packet.yaml` in the owned
   main repository from the exact reviewed Git blob at the endorsed planning
   commit. The implementation worktree is not the packet source, and no packet
   field is rewritten.
4. Verify that the materialized packet is byte-identical to the reviewed Git
   blob, validate it against `schemas/work-unit.schema.json`, and confirm that
   its `base_commit` equals the run record's `base_commit`.
5. Only after all checks pass is implementation authorized. Stop on any
   mismatch or validation failure.

Materialization is a reviewed packet update, not a silent base refresh.

`worktree.sh resume` is only for continuing work on the same already-reviewed existing unit/branch. It is not a mechanism for materializing a new packet, refreshing a packet base, or silently updating `base_commit`.

## Dependency order

1. `a0-cap-01-run-claim` — none
2. `a0-cap-02-fact-ledger` — none
3. `a0-cap-02-ledger-integrity` — `a0-cap-02-fact-ledger`
4. `a0-cap-03-execution-capture` — `a0-cap-01-run-claim`
5. `a0-cap-04-thread-binding` — `a0-cap-03-execution-capture`
6. `a0-cap-05-rollout-usage` — `a0-cap-02-fact-ledger`, `a0-cap-04-thread-binding`
7. `a0-cap-06-result-relay` — `a0-cap-03-execution-capture`, `a0-cap-04-thread-binding`; V8-gated
8. `a0-cap-07-validation-capture` — `a0-cap-01-run-claim`, `a0-cap-02-fact-ledger`, `a0-cap-06-result-relay`
9. `a0-cap-08-capture-coverage` — `a0-cap-03-execution-capture`, `a0-cap-06-result-relay`
10. `a0-cap-09-evidence-bundle` — `a0-cap-03-execution-capture`, `a0-cap-05-rollout-usage`, `a0-cap-06-result-relay`, `a0-cap-07-validation-capture`
11. `a0-cap-09-evidence-freeze` — `a0-cap-02-ledger-integrity`, `a0-cap-09-evidence-bundle`
12. `a0-cap-10-corpus-preflight` — `a0-cap-08-capture-coverage`, `a0-cap-09-evidence-freeze`
13. `a0-cap-11-lifecycle-conformance` — `a0-cap-05-rollout-usage`, `a0-cap-06-result-relay`, `a0-cap-07-validation-capture`, `a0-cap-08-capture-coverage`, `a0-cap-10-corpus-preflight`

The graph is acyclic. Its longest path contains nine packets:
`01 → 03 → 04 → 06 → 07 → 09-evidence-bundle → 09-evidence-freeze → 10 → 11`.

## External gates

- P0 is not a packet in this set. A0 collection remains externally blocked on
  P0 being separately specified, implemented, reviewed, merged, and validated.
- `a0-cap-06-result-relay` must not enter implementation until the operator
  restores Codex subscription authentication, the existing preflight accepts
  it, and V8 verifies successful `--output-last-message <FILE>` behavior.
- Governed implementation or A0 execution requires the existing preflight to
  terminate unambiguously RED or GREEN. Tool-resolution noise is never a
  successful preflight. PATH hardening remains separate work.

## Sizing decisions

The old CAP-02 was split because canonical fact claiming and malformed-ledger
reduction gating touch different commands, have different failure modes, and
require different operator-visible behavior checks. The split keeps the ledger
primitive focused on ingestion concurrency and the integrity gate focused on
pre-reduction refusal.

The old CAP-09 was split because evidence schema/sanitization validation and
durable retention/freeze eligibility are independently testable boundaries.
The first packet defines and validates safe package contents; the second proves
that the retained referent exists, hash-checks, and gates freeze.
