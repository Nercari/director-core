# Token-accounting subsystem — implementation report

Date: 2026-07-26

## Scope and result

Units 1–4 provide the append-only ledger, source adapters, reducer, scorecards,
advisory routing policy, and preflight estimate/calibration workflow. Unit 5
adds an isolated synthetic demonstration, resilience checks, attribution
checks, and a process-local append lock discovered to be necessary by the
concurrent-write check.

The synthetic demonstration proves the comparison mechanism. It does **not**
measure, rank, or recommend any real route.

## Files changed

| File | Purpose |
| --- | --- |
| `scripts/telemetry/ingest.py` | Serializes each physical JSONL append within one process so concurrent adapter threads cannot lose or interleave a line. |
| `scripts/telemetry/seed_example.py` | Generates a deterministic, fully labelled synthetic invocation ledger. |
| `scripts/telemetry/seed_example.sh` | Portable Python 3 launcher for the seeded ledger generator. |
| `scripts/telemetry/demo_comparison.sh` | Runs seed → reduce → advisory route comparison only against `.telemetry/example/`, then prints the comparison. |
| `scripts/telemetry/resilience_selfcheck.py` and `.sh` | Exercises partial, duplicate, corrupt, concurrent, null, and unmatched-record behavior. |
| `scripts/telemetry/attribution_selfcheck.py` and `.sh` | Exercises role, executor, parent/child, retry, parallel, and auxiliary attribution. |
| `.gitignore` | Excludes `.telemetry/example/`, because generated synthetic records must not be committed. |
| `.director/handoffs/UNIT-5-telemetry.json` | Local end-of-unit handoff; the directory is already ignored. |
| `docs/telemetry-implementation-report.md` | This report. |

## Architecture actually implemented

```text
provider or harness JSONL ──> ingest adapter ──> append-only invocation ledger
                                      │                    │
                                      │                    ├─> reduce ─> metrics + scorecards
                                      │                    │                  │
                                      │                    │                  └─> advisory route decision
                                      │                    └─> preflight reconciliation

synthetic seed ───────────────────────> .telemetry/example/invocations.jsonl
                                            └─> reduce + advisory demo only
```

The synthetic branch has no input from and no output to the real ledger. The
demonstration uses the same task class, complexity band, and validation
standard for both synthetic routes so the scorecard comparison is legitimate.

## Telemetry sources and authority

| Source | Status | Treatment |
| --- | --- | --- |
| Claude Code session JSONL | **AUTHORITATIVE** provider telemetry | The adapter records usage as authoritative when the provider event supplies it. |
| Codex rollout JSONL | **AUTHORITATIVE** harness/provider telemetry | The adapter records forward token deltas from cumulative usage when present. |
| agy fallback | **UNAVAILABLE** for usage | Its adapter records null token fields and `telemetry_authoritative: false`; it never invents usage. |
| Preflight | Estimate, not measurement | It uses a character-count heuristic and labels output `estimated_not_measured`. |
| Seeded example | Synthetic, not measurement | Every record has `project_id: EXAMPLE-SYNTHETIC`, `synthetic: true`, and `telemetry_authoritative: false`. |

Only provider or harness telemetry is authoritative. Actual usage means a
provider or harness value, estimated usage means the preflight heuristic, and
metrics such as retry rate or tokens per validated success are derived from
those records.

## Ledger schema

Each JSONL record is append-only and carries workflow identity (`project_id`,
`work_unit_id`, `run_id`, optional `parent_run_id`), attribution (`role`,
optional `executor_id`), comparison dimensions (`route_id`, `task_class`,
`complexity_band`, `validation_standard`, `execution_mode`), attempt/outcome
state (`attempt_number`, `completed`, `validation_passed`), token fields,
optional cost and latency, and telemetry provenance (`telemetry_source`,
`telemetry_authoritative`). Missing or unavailable values remain null rather
than being inferred.

The synthetic fixture adds `synthetic`, `synthetic_seed`,
`synthetic_nonce`, and `synthetic_route_label` solely to prevent accidental
confusion with real telemetry.

## Metrics implemented

The deterministic reducer reports token totals and components, estimated cost
when every record has a real cost, completed and validated-success counts,
first-pass and validated-success rates, retry/escalation/human-intervention
rates, median and p95 latency, cache-hit ratio, director-overhead ratio,
auxiliary handoff-overhead tokens, and tokens/cost per validated success.

Scorecards compare routes only within the same task class and complexity band.
The routing objective uses cost per validated success when all compared costs
are known; otherwise it uses tokens per validated success. Routes require at
least ten completed samples, and the policy's success-rate threshold also
applies.

## Routing-policy behavior

The policy remains **advisory by default**. The advisor writes the route it
would select, but never changes an active route. This prevents an unproven
comparison from silently changing execution behavior. It is especially
important now because the real ledger has zero completed runs, so it has no
evidence for a real recommendation. The capacity-routing rules also require a
stop and handoff rather than a silent provider switch when capacity is refused.

## Tests executed

Final successful run:

```text
bash scripts/telemetry/demo_comparison.sh
bash scripts/telemetry/reduce_selfcheck.sh
bash scripts/telemetry/route_advisor_selfcheck.sh
bash scripts/telemetry/preflight_selfcheck.sh
bash scripts/telemetry/resilience_selfcheck.sh
bash scripts/telemetry/attribution_selfcheck.sh
```

All six commands exited 0. The resilience check covers missing fields,
idempotent duplicate ingestion, interrupted outcomes, quarantine of corrupt
input, concurrent thread appends, null totals, and unmatched reconciliation.
The attribution check covers director, executor, parent/child, retries,
parallel executors, and auxiliary compaction overhead.

## Seeded route comparison

This is a **synthetic example only**. It uses fixed seed `20260725`, task
class `bounded-code-change`, complexity band `medium`, and validation standard
`example-check` for both routes.

| Synthetic route | Attempts | Tokens per attempt | Completed runs | Validated successes | Retry rate | Tokens per validated success |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| A (`batch-primary`) | 35 | 1,000.00 | 20 | 18 | 75% | 1,944.44 |
| B (`interactive-primary`) | 21 | 1,500.00 | 20 | 19 | 5% | 1,657.89 |

Route A is cheaper per attempt, but Route B wins on tokens per validated
success because its substantially lower retry rate outweighs its higher
per-attempt token cost. The advisory decision selected Route B using the
token-based fallback because estimated costs are intentionally null. This
proves that the mechanism rejects the misleading per-attempt metric; it does
not prove that either real route is superior.

## Known limitations

- There is no tokenizer, so preflight is an estimate rather than a token
  measurement.
- agy exposes no usage telemetry; its fallback adapter records nulls.
- The real ledger has zero completed runs, so no real route recommendation is
  possible yet.
- The seeded dataset is synthetic. It proves the comparison mechanism, not any
  real route's superiority.
- The append lock protects concurrent writes within one Python process. A
  separate cross-process coordination mechanism would be required before
  claiming multi-process writer safety.
- Token accounting does not establish quality beyond the recorded validation
  outcome; weak or inconsistent validation would produce weak derived metrics.

## Recommended next experiments

1. Collect at least ten real, comparable completed units per route with the
   same validation standard before treating the advisory output as evidence.
2. Inspect failed and retried units to confirm that validation outcomes are
   consistent and meaningful.
3. After ten matched authoritative preflight/actual pairs, review the suggested
   calibration factor manually; do not auto-apply it.
4. If multiple processes will write the same ledger, add and test an explicit
   cross-process lock before enabling that deployment shape.
5. Compare the advisory result with the route actually chosen, while retaining
   the policy's no-silent-switch boundary.

## Handoff location

The updated local handoff is
`.director/handoffs/UNIT-5-telemetry.json`. It is intentionally ignored with
other local handoffs and records the unit outcome without copying raw telemetry
into a handoff.
