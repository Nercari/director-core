# Director A0 Automatic Execution, Result Relay, and Validation Capture

**Status:** Draft for Claude/Coviber review  
**Authoritative source revision:** `d0409936005d2161ae10f3ce1d08a3b9eaaf5854`  
**Scope:** Director A0 control-baseline capture only  
**Next workflow step:** Review; do not derive tickets until this draft is approved

## Problem Statement

Director governs WorkUnits, but its ordinary governed execution path does not yet produce a complete, automatically correlated record of one Run. Real WorkUnits have executed, yet the production invocation ledger contains no canonical invocation rows. The current ingestion command is manual and post-hoc. The deterministic validator expects an executor result at a fixed Director-owned location, but repository source contains no production relay that places an authoritative executor result there. Only five historical result artifacts survive, only four identify `EXEC_STRONG`, and none supplies a decision-grade historical A0 sample.

This leaves the operator unable to answer, from immutable correlated evidence, whether a particular authorized Run launched, which Codex thread executed it, what terminal result the executor supplied, whether validation is pending or complete, what the validator decided, what usage was measured, whether capture itself was healthy, and whether the Run is eligible for the A0 control corpus.

The problem is not merely missing telemetry. The missing capability is a governed lifecycle that makes execution, result relay, validation, measurement, and evidence independently observable without changing executor permissions, result meaning, deterministic validation, acceptance, containment, or route selection.

## Verified Current State

1. The WorkUnit contract already requires a non-empty `run_id`. The capture lifecycle can adopt and claim this identity before launch rather than introducing an `Attempt` entity or adding `run_id` to the closed result contract.
2. `EXEC_STRONG` is the only currently usable governed executor route. It invokes Codex through the existing credential-removal jail with model `gpt-5.6-luna`, reasoning effort `max`, subscription authentication, and `codex-cli 0.145.0`. Its current route declaration runs as the operator and retains open network egress.
3. Routing policy maps workflow shape `director-primary_executor-strong` to executor route `EXEC_STRONG`. The policy is advisory and exploration remains enabled, but current source contains no automatic advisor-to-dispatch connection.
4. `codex exec --json` emits `thread.started.thread_id` as its first valid JSON lifecycle event before substantive execution. In two surviving real captures, that identifier exactly equalled both `session_meta.id` and `session_meta.session_id` and appeared in the corresponding rollout filename. No newest-file, cwd, or timestamp heuristic is required.
5. Direct `--json` terminal usage uses a different shape from the current Codex ingestion adapter. Exactly bound rollout/session files contain the supported `total_token_usage` and `last_token_usage` structures.
6. The executor result schema is closed and does not contain `run_id`. It defines executor-reported status, branch, route, summary, changed files, tests, risks, deviations, and wall time. Its semantics should remain unchanged.
7. The WorkUnit output contract requires `result_json`, but neither it nor production source defines how the executor's authoritative result reaches the validator's Director-owned path. Current production source writes only worktree metadata; conformance fixtures are the only repository writers of validator input.
8. The validator is deterministic but not observationally pure: it reruns declared tests and writes evidence. It terminates with `VALIDATED`/exit `0`, `REJECT`/exit `1`, or `STOPPED`/exit `2`. These exit codes and terminal messages are the current observable contract.
9. Execution and validation can be separated by an unbounded operator interval. A terminal execution may legitimately remain validation-pending.
10. The invocation ledger schema already admits nullable completion and validation fields, but the reducer treats any boolean completion or validation field as an outcome. An execution-only record that sets `completed` before validation would incorrectly make pending validation count against validated-success metrics.
11. The current ledger serializes each physical append, but duplicate checking and ledger/index persistence are not one atomic transaction. A concurrent retry or a crash between writes can create ambiguous state.
12. The reducer aborts on a malformed canonical line. Detailed metrics include validation standard, but scorecards do not. A0 must therefore use one frozen validation standard and pass an integrity gate before reduction or freeze.
13. Existing evidence-bundle conventions provide local relative artifacts, required SHA-256 digests, containment, no network dereferencing, and no promotion authority. The current bundle is WorkUnit-scoped and does not by itself represent every Run lifecycle or fault outcome.
14. Historical populations are distinct: 54 PR-associated main commits, a route declaration claiming 11 `EXEC_STRONG` units, 59 surviving run directories, five surviving result artifacts dated in late July 2026, four surviving `EXEC_STRONG` results, one `DIRECT` result, zero canonical invocation rows, and zero measured A0 Runs.
15. The resume/base-commit defect is independently runtime-confirmed. It is external P0 work and is not fixed or ticketed by this specification.

## Objective

Make one governed Director Run produce deterministic, automatically correlated execution, authoritative result, validation, usage, capture-health, provenance, and retained evidence sufficient for a frozen decision-grade A0 control baseline, without changing execution or validation semantics.

The system must preserve four separate questions:

1. **Execution outcome:** What happened to the governed executor process?
2. **Validation state:** Has the existing validator run, and what did its existing contract decide?
3. **Measurement/capture health:** Are all required correlated facts and retained evidence complete and trustworthy?
4. **A0 eligibility:** May this Run enter the decision-grade control sample?

No single status field may stand in for all four.

## Solution

Director will establish one authoritative host-side governed invocation seam for A0. That seam will adopt the WorkUnit packet's unique `run_id` before launch, record immutable Run and provenance metadata, invoke the unchanged `EXEC_STRONG` command through the existing jail, capture the exact Codex thread identifier from the early lifecycle stream, retain execution terminal facts, relay the executor's dedicated terminal result into the validator's existing input contract, and bind supported usage from the exact rollout identified by that thread.

Validation remains a later, separately invocable governed operation. It will invoke the unchanged validator once for an explicitly intended validation invocation, durably retain its exit code and output, derive a normalized validation fact from the existing terminal contract, and persist that fact without rerunning validation during capture recovery.

Capture is fail-open relative to execution and validation: capture defects never rewrite executor or validator outcomes. Capture defects are nevertheless visible, make measurement health incomplete, and exclude the Run from decision-grade A0 until an evidence-backed recovery succeeds or a new Run is authorized.

The canonical invocation ledger remains the sole telemetry ledger. A Run-owned lifecycle manifest and retained evidence package are correlation/evidence artifacts, not competing metric ledgers. Canonical fact identity and persistence must be strengthened or serialized so retry, concurrency, replay, and interruption cannot create ambiguous Run histories.

## User Stories

1. As the Director operator, I want every governed A0 execution to adopt a unique Run identity before launch, so that all later facts refer to one authorized execution.
2. As the Director operator, I want reuse of a previously launched `run_id` for a new executor launch to be rejected, so that two executions cannot masquerade as one Run.
3. As the Director operator, I want the actual selected route recorded as `EXEC_STRONG`, so that the control arm cannot drift through advisory routing.
4. As an auditor, I want the workflow-shape identity and route/configuration digests retained, so that A0 route provenance can be reconstructed.
5. As an auditor, I want the installed Codex version, declared model, and reasoning effort recorded without upgrading or claiming unverified served-model identity, so that runtime provenance remains honest.
6. As the capture system, I want to bind `thread.started.thread_id` to `run_id` before substantive execution, so that usage and session evidence never depend on temporal or cwd heuristics.
7. As the Director operator, I want a missing or malformed thread binding reported as a capture defect, so that it cannot silently select the wrong rollout.
8. As an executor, I want capture failure not to change my permissions, process result, result semantics, or jail, so that measurement does not alter the control arm.
9. As the Director operator, I want executor stdout, stderr, process exit, timeout, and cancellation facts retained separately from result and validation, so that execution failures are diagnosable.
10. As the deterministic validator, I want to receive exactly one authoritative result through my existing input contract, so that I need no Codex-specific knowledge.
11. As the Director operator, I want the executor's dedicated terminal result channel distinguished from arbitrary event stdout and rollout content, so that result relay is deterministic.
12. As an auditor, I want the relayed validator input byte-identical to the retained per-Run result and pinned by digest, so that later validation can be attributed to the same Run.
13. As the Director operator, I want a missing, malformed, or schema-invalid terminal result reported as a result-relay defect, so that apparent executor success is not mistaken for a valid result.
14. As the Director operator, I want validation to remain pending for an unbounded interval after execution, so that operator review time does not become a false failure.
15. As the Director operator, I want the validator invoked once for each explicitly intended validation invocation, so that measurement retries cannot rerun tests or recreate evidence.
16. As an auditor, I want validator exit code and terminal disposition captured together, so that overloaded exit codes are interpreted consistently without redesigning them.
17. As the Director operator, I want capture persistence recovery to reuse the retained validation receipt, so that telemetry repair never invokes the validator again.
18. As a metrics consumer, I want validation-pending records excluded from validated-success denominators, so that absence of validation cannot suppress the 0.90 threshold.
19. As a metrics consumer, I want unsupported or missing usage marked separately from execution and validation, so that accounting gaps do not become execution failures.
20. As an auditor, I want the exact rollout located from the bound thread identifier, so that usage is attributable without newest-session or timestamp guessing.
21. As the Director operator, I want duplicate and concurrent capture of the same logical fact to converge on one unambiguous record, so that retries are safe.
22. As the Director operator, I want a crash between canonical writes detected and recoverable, so that ledger/index divergence cannot silently corrupt A0.
23. As an auditor, I want canonical ledger integrity checked before reduction, scorecard generation, and baseline freeze, so that a malformed line cannot invalidate a declared baseline.
24. As an auditor, I want one frozen validation standard across A0, so that scorecards do not silently aggregate unlike validation regimes.
25. As the Director operator, I want every A0-admitted execution to prove passage through the capture seam, so that direct or legacy invocation cannot enter the measured sample.
26. As a security reviewer, I want host-side capture to write runtime evidence without granting the executor model a telemetry write carve-out, so that the existing out-of-scope write guard remains intact.
27. As an auditor, I want a retained sanitized evidence package rather than a bare digest, so that the measured facts remain inspectable after raw sessions disappear.
28. As a security reviewer, I want raw prompts, provider payloads, repository excerpts, tool streams, and quarantine bytes excluded from committed evidence unless explicitly sanitized, so that baseline preservation does not create a data leak.
29. As the Director operator, I want corpus units frozen before execution with objective, base, scope, criteria, tests, expected terminal semantics, instructions, route, and validation provenance, so that A0 can be replayed fairly.
30. As an experiment owner, I want the baseline completion gate to require at least ten automatically captured completed Runs plus the four settled special scenarios, so that implementation fixtures cannot replace benchmark coverage.
31. As an experiment owner, I want historical executions excluded from the measured A0 count, so that sparse historical artifacts cannot inflate the control sample.
32. As the Director operator, I want capture rollback to restore the prior invocation shape without deleting evidence or claiming A0 readiness, so that capture can be disabled safely if defective.

## Authoritative Lifecycle

### 1. Authorize and claim the Run

The existing WorkUnit packet is the source of `run_id`; the authoritative invocation seam obtains rather than independently remints it. Before executor launch it must:

- validate the WorkUnit packet against its existing contract;
- map `unit_id` to telemetry `work_unit_id` without inventing a second WorkUnit identity;
- verify the packet declares `EXEC_STRONG`;
- atomically claim a previously unseen `run_id` in a Run-owned lifecycle manifest;
- reject a new launch for a `run_id` already marked launched or terminal;
- record packet digest, WorkUnit identity, base commit, route alias, workflow-shape ID, start timestamp, and initial capture health;
- record provenance identities required by the corpus manifest.

A recovery command may reopen the same Run manifest to repair capture facts, but it may not relaunch the executor. A new execution requires a new authorized `run_id`. `Attempt` is not introduced as an entity. The existing optional `attempt_number` ledger field is not used as Run identity.

### 2. Invoke through the governed capture seam

The smallest enforceable current topology is one authoritative host-side invocation entrypoint selected by the usable route declaration, backed by route/config conformance. The entrypoint must preserve the current inner invocation semantics: existing jail, Codex sandbox mode, model, reasoning effort, authentication mode, account claim, and timeout policy.

The route declaration may point to the capture entrypoint, which then invokes the exact current jailed executor command. This is an invocation-shape change, not a route-policy or executor-semantic change. The entrypoint is not named or modeled as a new “dispatcher.”

Conformance must prove that the usable A0 `EXEC_STRONG` route resolves through this seam. A direct legacy jail or Codex invocation produces no admissible capture proof and must fail A0 admission. A substring hook is neither required nor sufficient; hook enforcement may be added only if tickets later prove route/config conformance plus A0 admission checks cannot enforce or detect coverage.

### 3. Bind the Codex thread exactly

The entrypoint captures the JSON lifecycle stream and expects the first valid lifecycle record to be `thread.started` with a non-empty `thread_id`. It records that value against `run_id` before accepting subsequent substantive events as correlated evidence.

For `codex-cli 0.145.0`, the binding contract is:

- emitted `thread.started.thread_id` equals rollout `session_meta.id`;
- emitted `thread.started.thread_id` equals rollout `session_meta.session_id`;
- the rollout filename identity contains the same value.

The implementation may wait or search for the exact identifier under supported session roots. It may not select newest, closest timestamp, matching cwd, or another approximate candidate. A bounded wait for the exact identifier is not heuristic matching. Missing event, missing field, conflicting metadata, zero exact rollout matches after the allowed wait, or multiple exact matches is a visible binding defect. Execution continues or terminates according to the executor, but capture health becomes incomplete and A0 eligibility becomes false.

The verified CLI version is provenance and a compatibility boundary. An unreviewed CLI version change cannot silently inherit this contract; conformance must pass for the installed version before A0 execution.

### 4. Record execution terminal facts

The host records launch outcome, process exit code, timestamps, timeout/cancellation observation, captured stream digests, and any safely observable post-timeout cleanup facts. This record describes the process only. It does not assert Director acceptance and does not convert capture failure into executor failure.

Execution terminal states include at least:

- launch failed;
- launched/running;
- exited zero;
- exited nonzero;
- timed out;
- cancelled;
- terminal state unknown because host observation failed.

The V4 result proves only one GNU timeout 8.32 topology. Generic Windows descendant containment and Job Objects are not added here. Where a scenario depends on descendant cancellation, observable post-timeout process/lock evidence must be retained without claiming universal containment.

### 5. Relay the authoritative executor result

The authoritative result source is a dedicated executor terminal-result channel, not arbitrary event stdout and not the rollout. The current Codex CLI's dedicated last-message output capability is the narrowest source-backed channel available for implementation; tickets must verify its exact behavior under the pinned CLI before relying on it.

The model-facing output instruction must require that channel to contain exactly one JSON document satisfying the existing result contract. Structured-output flags must not be adopted if they require changing optional-field semantics. The host stages the terminal message outside model `Write/Edit`, parses it, validates it against the unchanged result schema, and confirms its route and branch are consistent with the authorized WorkUnit.

On success, the host:

- retains a per-Run canonical copy and digest;
- atomically materializes byte-identical content at the validator's existing WorkUnit result location, `.director/runs/<unit>/result.json`;
- records which Run currently owns that validator input;
- binds packet digest, result digest, and `run_id` in the Run manifest.

On missing output, non-JSON output, schema rejection, inconsistent route/branch, write failure, or digest mismatch, result relay fails visibly. Validation must not start without an authoritative bound result. The executor's actual terminal outcome remains unchanged.

`result.schema.json` remains unchanged and does not gain `run_id`. Correlation belongs to the Run manifest and retained evidence.

### 6. Leave validation pending until explicitly invoked

Execution completion and result relay do not synchronously invoke validation. A successful relay enters `validation_pending`. This state has no deadline and is not validation failure.

An explicit validation operation must identify `run_id`, verify that the WorkUnit, packet digest, retained result digest, and currently materialized validator input all match the Run, and atomically claim a validation-invocation ordinal before starting the validator. The ordinal identifies an invocation fact; it is not a domain `Attempt` entity.

The same claimed validation invocation cannot start twice. A separate human-authorized validation rerun, if ever needed, receives a new validation ordinal and is not triggered by telemetry repair.

### 7. Capture validation once and normalize its existing outcome

The validation operation invokes the unchanged validator once, while capturing stdout, stderr, exit code, start/end timestamps, and produced evidence into a durable validation receipt. Persistence of normalized telemetry is downstream of this receipt. Retrying downstream capture reads the receipt and never reruns validation.

Normalized interpretation is deliberately narrow:

- exit `0` plus the exact terminal `VALIDATED — safe to review, push, and open a pull request.` grammar means `validation_passed: true` and disposition `validated`;
- exit `1` plus terminal grammar `REJECT — <positive integer> check(s) failed. Nothing leaves this machine.` means `validation_passed: false` and disposition `rejected`;
- exit `2` plus terminal grammar `STOPPED: status=<blocked|failed>. Nothing is authorised to leave this machine.` means `validation_passed: false` and disposition `stopped`;
- any exit/message mismatch, signal, launch failure, missing terminal line, or unreadable receipt means validation capture is incomplete and `validation_passed: null`.

Both exit code and stable terminal grammar are required because current exit codes are overloaded. Conformance protects the grammar. Incidental intermediate log lines are not parsed. Validator exit codes and validator behavior are not redesigned.

### 8. Bind supported usage from the exact rollout

After exact thread binding and executor termination, usage ingestion reads only the rollout whose session metadata matches the bound thread identifier. It reuses the existing supported cumulative/last-usage adapter; no duplicate direct-stdout usage adapter is added.

If the exact rollout is still being written, the capture system may perform bounded retries against that same identified file and must require complete parseable JSONL records before declaring accounting complete. It may never switch candidates. Missing supported usage, partial usage, malformed content, disappearance, access failure, or quiescence timeout produces accounting state `partial` or `unavailable`, with an explicit reason and source digest where available.

Accounting completeness is independent of execution and validation. It may make capture health incomplete and the Run A0-ineligible, but it does not alter executor or validator outcomes.

### 9. Persist canonical facts idempotently

The existing invocation ledger remains canonical. Run lifecycle manifests and validation receipts are durable source facts used to populate or repair it; they are not a second telemetry ledger.

Every canonical lifecycle/measurement fact has logical identity:

`(run_id, fact_kind, ordinal_or_source_digest)`

At minimum, fact kinds distinguish usage, normalized validation outcome, and capture-health/evidence state. Invocation records must carry enough self-identifying data to reconstruct this identity after a crash; if the closed invocation schema cannot represent it, that schema receives the minimal reviewed extension. The result schema does not change.

Implementation tickets must compare two acceptable smallest mechanisms:

1. one serialized canonical writer that holds a cross-process claim through index refresh, uniqueness check, ledger append, index append, flush, and recovery; or
2. an atomic fact claim/append mechanism that provides the same observable guarantees under multiple writers.

Thread-only locking or passing a tuple to the current `append()` method is not sufficient. Required behavior:

- duplicate retry produces no duplicate fact;
- concurrent duplicate writers converge on one fact;
- replay of the same source converges on one fact;
- a crash after ledger append but before index append is detected and repaired without a second ambiguous fact;
- execution facts may exist while validation is absent;
- validation persistence retry uses the receipt rather than the validator;
- torn or malformed canonical lines fail integrity checks and baseline freeze;
- conflicting facts for one identity are quarantined or reported as a capture defect, never silently selected.

To preserve existing reducer semantics, execution-only and validation-pending ledger records must leave both `completed` and `validation_passed` null. Execution terminal state lives in the Run manifest. A normalized outcome record is appended only after validation produces a conclusive receipt. This prevents pending validation from entering the validated-success denominator as failure.

### 10. Retain decision-grade evidence

Raw rollout/session files and raw quarantine bytes remain local sensitive inputs and are not committed. A bare digest whose source may disappear is insufficient.

Each A0 Run must produce a retained, sanitized, self-contained evidence package. The package reuses the current evidence-bundle security conventions: relative contained files, explicit artifact kinds, required SHA-256 digests, no network dereferencing, deterministic validation, and no promotion authority. Because the existing bundle is WorkUnit-scoped, its contract must be minimally extended or complemented by a Run-bound manifest so `run_id` and lifecycle artifacts are explicit rather than encoded in names.

The retained package contains, when applicable:

- Run manifest and capture-health summary;
- frozen WorkUnit packet and packet digest;
- authoritative result and digest;
- execution terminal receipt;
- exact thread/session binding record;
- a sanitized usage-source excerpt containing only session identity and supported usage structures needed to audit extraction;
- normalized usage record;
- validation receipt, terminal disposition, and evidence references;
- environment/config and model-visible instruction provenance;
- evidence of A0 eligibility or the precise exclusion reasons.

Raw prompts, provider prose, tool payloads, arbitrary repository excerpts, full rollouts, and quarantine raw bytes are excluded unless a separately defined sanitizer proves they are necessary and safe. The frozen model-facing instruction artifact is retained because it is deliberate corpus input, not harvested provider output; corpus preflight must reject sensitive content before measurement.

The sanitized package is the durable audit artifact and may be version-controlled or placed in another explicitly durable reviewed store. If stored externally, the package must retain a durable resolvable reference plus digest; a transient local path is insufficient. The implementation may not declare a Run evidence-complete until the retained package itself is readable and hash-valid.

## Ownership Boundaries

- **WorkUnit authoring/orchestration** owns objective, packet, `run_id`, route declaration, scope, criteria, required tests, expected terminal semantics, and frozen instruction artifact.
- **Governed host invocation seam** owns Run claim, exact route invocation, thread binding, process observation, result-channel capture, result relay, usage-source binding, and execution capture health.
- **Executor** owns edits and the semantic contents of the existing result contract. It does not write Director telemetry through model `Write/Edit`.
- **Existing jail** continues to own gate-credential removal and nothing more. It is not described as network or account isolation.
- **Validation operation** owns exactly-once invocation claiming, validator process capture, durable validation receipt, and normalized validation fact.
- **Existing validator** remains the sole owner of deterministic acceptance checks and test reruns. It learns nothing about Codex sessions or telemetry.
- **Canonical capture writer** owns ledger idempotency, concurrency, replay, and recovery.
- **Evidence freezer** owns sanitization, artifact retention, digests, integrity verification, and A0 admission evidence.
- **Operator** retains review, behavior-check, promotion, and merge authority.

## Lifecycle State and Failure Matrix

| Situation | Execution outcome | Validation state | Measurement/capture health | A0 eligibility |
|---|---|---|---|---|
| Run claimed, executor never launched | `not_launched` or `launch_failed` | pending/not applicable | complete if launch failure recorded; otherwise incomplete | ineligible |
| Executor launched, no valid `thread.started.thread_id` | follows actual process | pending | binding defect | ineligible |
| Thread bound, executor crashes | nonzero/signal | pending until an authoritative result exists | complete only if terminal/evidence captured; usage may be partial | normally ineligible; may qualify only as a predeclared special scenario |
| Executor timeout | timed out | pending | include timeout and observable cleanup evidence | normal sample ineligible; special scenario only if predeclared |
| Cancellation | cancelled | pending | include cancellation and descendant/lock observations | cancellation special scenario only if predeclared |
| Executor exits nonzero | exited nonzero | pending | independent capture status | normal sample ineligible unless expected terminal semantics say otherwise |
| Executor exits zero, terminal result absent | exited zero | cannot start | result-relay defect | ineligible |
| Terminal result malformed or schema-invalid | actual process outcome | cannot start | result-relay defect | ineligible |
| Result relay write/digest check fails | actual process outcome | cannot start | result-relay defect | ineligible |
| Result exists and is bound | actual process outcome | pending | may be complete except validation | pending, not failed |
| Validator cannot start | unchanged | unknown/incomplete | validation capture defect | ineligible |
| Validator exits 0 with VALIDATED grammar | unchanged | passed | complete if receipt persisted | eligible if all other gates pass |
| Validator exits 1 with REJECT grammar | unchanged | rejected | complete if receipt persisted | completed-success sample ineligible |
| Validator exits 2 with STOPPED grammar | unchanged | stopped/unaccepted | complete if receipt persisted | normal sample ineligible; negative control may qualify as special scenario |
| Exit/message mismatch or validator crash | unchanged | unknown/incomplete | validation capture defect | ineligible |
| Validation receipt exists, ledger append fails | unchanged | derivable from receipt | ledger persistence defect | ineligible until repaired without rerun |
| Usage object unavailable/unsupported | unchanged | unchanged | accounting partial/unavailable | ineligible for decision-grade A0 until resolved or rerun policy is applied |
| Canonical ledger append fails | unchanged | unchanged | ledger capture defect | ineligible until repaired |
| Evidence preservation/sanitization fails | unchanged | unchanged | evidence incomplete | ineligible |
| Canonical ledger malformed at preflight | unchanged | unchanged | baseline integrity failure | all baseline freeze/reduction blocked |

## Route and Control-Arm Invariants

1. Every measured A0 Run declares and records route alias `EXEC_STRONG` and workflow shape `director-primary_executor-strong`.
2. The invocation seam verifies this route against the WorkUnit packet and route registry before launch.
3. The inner executor command retains the current model, reasoning effort, sandbox, jail, account claim, and authentication mode.
4. The full routing policy is retained by digest as provenance, including advisory mode and exploration settings.
5. A0 invocation does not ask the advisor to select a route. Advisor output, if recorded, is provenance only and cannot override the predeclared route.
6. Telemetry, scorecards, capture health, or recommendations cannot trigger route promotion, quarantine change, exploration, or fallback for an A0 Run.
7. An invocation not carrying capture proof for this seam cannot enter A0, even if it used the same Codex command manually.

## Corpus and Freeze Prerequisites

### Corpus source

The primary corpus is future/current real-provenance ready-for-agent work. The current issue pool is only a candidate pool. Historical issues or PRs may validate capture mechanics when reconstructable but do not become measured A0 samples.

Before the first measured Run, a corpus manifest freezes for each selected WorkUnit:

- issue/WorkUnit identity;
- objective;
- unique `run_id` for the authorized execution;
- base commit;
- allowed and, where applicable, forbidden paths;
- acceptance criteria;
- required tests and behavior check;
- expected terminal semantics;
- exact model-facing instruction artifact;
- one shared validation standard;
- route and routing-policy provenance;
- overlap, if any, with a declared special scenario.

Corpus preflight fails before execution when a required field is missing, the base is unavailable, the instruction artifact is not retained, the validation standard differs, or sensitive material prevents safe evidence retention.

### Environment and instruction provenance

Execution/config provenance records immutable identities for the relevant route declaration, full routing policy, jail, validator, worktree behavior, relevant hooks, result and WorkUnit contracts, source revision, Codex CLI version, declared model/reasoning effort, and ambient/local configuration that can affect execution.

Model-visible instruction provenance is narrower. It contains only material actually supplied or automatically loaded under a verified mechanism, with a visibility basis for each item such as explicit prompt inclusion or verified CLI instruction discovery. Repository existence alone does not prove visibility. `AGENTS.md` or other instructions are included only when the Run's actual invocation contract makes them model-visible. `docs/blueprint.md` remains repository provenance unless explicitly supplied or verified as loaded.

### Completion rule

The frozen A0 baseline is complete only with:

- at least **10 distinct automatically captured A0-eligible completed Runs**; and
- all four predeclared fault/negative scenarios:
  1. Windows path/encoding/locked-file;
  2. cancellation with a long-running descendant process;
  3. provider/authentication failure;
  4. negative-control WorkUnit whose correct outcome is blocked/no edit.

Overlap is allowed only when legitimate and declared before execution. A successful Windows/path case may also count among the ten. Cancellation, authentication failure, and blocked negative control normally do not. Capture conformance fixtures such as generic timeout, nonzero exit, or missing result do not substitute for these benchmark scenarios.

The baseline completion gate counts distinct eligible `run_id` values from retained evidence, not historical directories or the reducer's label alone. Multiple Runs for one WorkUnit remain separately captured but cannot inflate a matched comparison unless the frozen corpus design explicitly permits and discloses that sampling rule.

P0 must be merged and validated before corpus execution begins if correction/resume is part of the measured workflow.

## Security Constraints

1. Capture is host-side. No model `Write/Edit` telemetry carve-out is added, and the existing out-of-scope write guard is not weakened.
2. The existing jail and validator semantics remain unchanged.
3. Raw Codex sessions, provider payloads, quarantine bytes, prompts, and repository excerpts are not committed as baseline evidence.
4. Sanitization is deterministic and conformance-tested; failure is visible and blocks A0 eligibility.
5. Retained artifact references are local-contained or explicitly durable, digest-pinned, non-executable, and cannot confer promotion authority.
6. Recorded commands and provider content are evidence text and are never replayed by evidence validation.
7. Capture does not add credentials, API-key fallback, OAuth work, new accounts, or DSH access.
8. Open executor network egress and operator-account execution remain recorded residual risks; this specification does not falsely upgrade containment.

## Implementation Decisions

1. Use one authoritative governed invocation entrypoint as the highest practical test seam; route/config conformance and A0 admission enforce or detect coverage.
2. Adopt the WorkUnit packet's `run_id` before launch and reject reuse for a new launch.
3. Keep WorkUnit and Run as the domain hierarchy; do not introduce `Attempt`.
4. Keep `result.schema.json` unchanged. Bind result and validation through a separate Run-owned manifest and digests.
5. Use a dedicated terminal-result channel for authoritative result relay; do not treat arbitrary JSONL stdout or the rollout as the result.
6. Capture `thread.started.thread_id` and require exact equality with rollout session metadata; prohibit heuristics.
7. Reuse the current rollout usage adapter; do not add a duplicate direct-stdout usage adapter.
8. Separate execution recording from later validation recording. Pending validation is represented by null/absent outcome booleans in canonical metrics.
9. Persist a durable validation receipt before downstream ledger repair; capture retries never rerun validation.
10. Normalize validator outcomes only from exit code plus the stable terminal grammar defined above.
11. Keep the invocation ledger canonical. Strengthen or serialize logical fact claiming rather than creating another telemetry ledger.
12. Extend the invocation contract minimally only if needed to carry reconstructable fact identity. Do not misuse existing optional fields to hide lifecycle identity.
13. Reuse evidence-bundle containment/digest conventions for a sanitized Run-bound retained package; do not preserve only a hash.
14. Freeze `EXEC_STRONG` per A0 packet and invocation, while retaining the unchanged routing policy as provenance.
15. Use one validation standard across A0 because scorecard grouping does not presently encode that dimension.
16. Treat baseline completion and eligibility as an explicit distinct-Run evidence gate, not as an inference from historical counts.

The preliminary U1–U5 decomposition is not frozen. `/to-tickets` may revise boundaries based on dependency and repository size conventions after approval of this specification. P0 remains separate.

## Testing Decisions

Tests assert external lifecycle behavior at the highest available seam. Fixture-level unit tests may support parsing and persistence, but conformance must execute the host lifecycle with synthetic executors/validators and temporary state. No test needs a real provider request unless a separately reviewed compatibility probe is explicitly authorized.

Required coverage:

1. A valid packet claims one unique Run identity before launch.
2. Duplicate `run_id` launch is rejected while recovery without relaunch is allowed.
3. Duplicate fact retry produces one canonical fact.
4. Concurrent duplicate capture converges or is serialized without ambiguity.
5. Crash between ledger and index persistence is detected and repaired deterministically.
6. `thread.started.thread_id` is captured before substantive events.
7. Missing, empty, duplicate, or conflicting thread/session identity produces a visible capture defect.
8. Exact thread ID locates the correct rollout and no heuristic fallback exists.
9. Unsupported, partial, malformed, missing, disappearing, and still-growing usage artifacts produce accounting states without changing execution/validation outcomes.
10. Executor zero, nonzero, timeout, cancellation, and launch-failure states remain distinct.
11. Dedicated terminal result is relayed byte-identically and validates against the unchanged result contract.
12. Missing, malformed, inconsistent, or unwriteable result produces a relay defect and prevents validation start.
13. Result correlation rejects wrong WorkUnit, Run, packet digest, or result digest.
14. Validation remains pending without counting as failure.
15. Validator pass produces one receipt and normalized pass.
16. Validator reject produces one receipt and normalized rejection.
17. Validator stopped outcome produces one receipt and normalized stopped disposition.
18. Unexpected exit/terminal-message combinations produce capture-incomplete rather than guessed pass/fail.
19. Validator invocation count is exactly one for one claimed validation invocation.
20. Validation ledger-persistence retry reads the receipt and does not invoke the validator.
21. Validation receipt persistence failure is visible and A0-ineligible.
22. General capture persistence failure is visible while executor/validator exit behavior remains unchanged.
23. One malformed canonical ledger line blocks reduction and baseline freeze in preflight.
24. A0 invocation remains `EXEC_STRONG` regardless of advisor output, exploration setting, or populated telemetry.
25. Direct/bypass invocation cannot produce the capture proof required for A0 admission.
26. Existing model `Write/Edit` guard remains unchanged and host-side evidence writes still function.
27. Sanitized evidence package retains required source facts and digests while excluding seeded secret/provider-payload fixtures.
28. Evidence validation does not fetch, execute, or leave its package boundary.
29. Corpus preflight rejects mixed validation standards.
30. Windows path/encoding/locked-file behavior is covered where locally testable.
31. Blocked/no-edit negative control preserves zero edits and the expected stopped validation disposition.
32. Capture/conformance fixtures are reported separately from the four benchmark special scenarios.
33. A complete synthetic baseline manifest cannot pass with fewer than ten eligible completed Run IDs or any missing special scenario.

Prior art is the repository's existing conformance runner, validator fixtures, telemetry resilience checks, route-advisor checks, sanitizer fixtures, and evidence-bundle validator. New scenarios should extend these high-level seams rather than duplicate their enforcement logic.

## Rollout

1. Review and approve this specification before `/to-tickets`.
2. Specify, implement, review, and hand off P0 separately.
3. Derive narrow capture WorkUnits only after this specification is approved; preserve dependency ordering but do not assume U1–U5 boundaries are final.
4. Run synthetic lifecycle and persistence conformance without provider work.
5. Run one explicitly authorized non-benchmark smoke Run through `EXEC_STRONG` to verify exact current CLI/session behavior and evidence sanitization; do not count it as A0 unless it was frozen in advance under the corpus procedure.
6. Verify P0 and capture work are both merged and validated.
7. Freeze corpus, validation standard, environment/config provenance, and model-facing instructions.
8. Start A0 at zero measured Runs and admit only Runs passing every eligibility and evidence gate.
9. Freeze the completed baseline only after ledger integrity and evidence-package validation pass.

## Rollback

Capture is observational and fail-open for execution, but A0 admission depends on it. If capture is defective:

- stop A0 collection;
- preserve existing Run manifests, receipts, ledger state, and retained packages;
- restore the previous direct route invocation shape only through a reviewed rollback;
- do not delete or rewrite recorded evidence;
- do not infer missing facts;
- mark affected Runs capture-incomplete and exclude them;
- resume collection only after conformance again proves exact binding, deterministic relay, idempotent persistence, and evidence retention.

Rollback does not change executor result semantics, validator behavior, route economics, or P0.

## Acceptance Criteria

1. Every governed A0 `EXEC_STRONG` Run adopts one unique `run_id` before executor launch.
2. A second launch cannot reuse an already launched Run identity.
3. The emitted `thread.started.thread_id` is captured and exactly bound to that Run before substantive lifecycle events.
4. No newest-session, cwd, timestamp-proximity, or other heuristic session matching exists.
5. The exact bound rollout supplies supported usage where available, and missing usage changes only accounting/capture health.
6. The executor's dedicated terminal result reaches the validator's existing input location through a deterministic, digest-bound production relay.
7. The existing result schema and validator semantics remain unchanged.
8. Validation may remain pending indefinitely without becoming failure or entering validated-success denominators.
9. One intended validation invocation executes the validator exactly once.
10. Retrying validation capture never executes the validator again.
11. Normalized validation derives only from the protected exit-plus-terminal grammar.
12. Capture failure does not alter executor or validator outcome, is operator-visible, and excludes the Run from decision-grade A0.
13. Duplicate, concurrent, replayed, and crash-interrupted lifecycle capture cannot produce an ambiguous Run history.
14. Every A0-admitted execution proves passage through the capture seam; bypass is prevented by the authoritative route or detected at admission.
15. Telemetry and advisor output cannot alter A0 dispatch.
16. Each measured Run explicitly records route alias `EXEC_STRONG` and workflow shape `director-primary_executor-strong`.
17. Relevant execution/config and actual model-visible instruction provenance is frozen and hash-valid without overstating visibility.
18. A retained sanitized Run evidence package remains inspectable without committing raw sensitive provider/session material.
19. Canonical ledger integrity is checked before reduction, scorecard generation, and baseline freeze.
20. Corpus preflight enforces one frozen validation standard.
21. Baseline completion requires at least ten distinct eligible automatically captured completed Runs plus all four declared special scenarios.
22. The four scenarios remain Windows path/encoding/locked-file, descendant cancellation, provider/auth failure, and blocked/no-edit negative control.
23. Historical executions and artifacts contribute zero measured A0 Runs.
24. The completed A0 package contains enough frozen WorkUnit, environment, instruction, result, validation, usage, and provenance evidence to support a fair later A2 replay without claiming provider internals or historical measurements that were not captured.

## Out of Scope

- P0 resume/base-commit defect or any change to `worktree.sh` resume semantics.
- Validator exit-code redesign or changes to validation/acceptance semantics.
- `reduce.py` versus route-advisor eligibility divergence.
- Scorecard grouping omission of `validation_standard`; A0 instead freezes one standard.
- Reducer malformed-line recovery beyond the required integrity gate.
- Blueprint §16 command drift.
- Enforcement of the inner/outer timeout relationship.
- Generic Windows process-tree containment, Job Objects, or universal descendant guarantees.
- Route economics, model, reasoning effort, policy mode, quarantine state, or exploration changes.
- A new direct-stdout usage adapter.
- Harness architecture or repository creation.
- DSH or Cordis integration.
- OAuth feasibility work, credential changes, new Windows accounts, or API-key fallback.
- Metaprompter.
- A2 route/schema changes or benchmark execution.
- Public execution-event streams.
- Corpus selection/finalization beyond defining the freeze procedure and acceptance gate.
- Committing raw telemetry, full Codex rollouts, raw provider payloads, or quarantine bytes.
- Tickets, implementation, A0 collection, PR publication, or deployment.

## Prerequisites

### Before `/to-tickets`

- Claude/Coviber approval of this specification.
- No additional architecture decision is currently required.

### Before A0 collection

- P0 is separately specified, ticketed, implemented, reviewed, handed off, merged, and validated if correction/resume belongs to the measured workflow.
- Capture/result-relay work derived from this specification is implemented, reviewed, handed off, merged, and validated.
- Exact CLI event conformance passes for the installed Codex version.
- Corpus and one validation standard are frozen.
- Sanitized durable evidence retention is operational.
- Canonical ledger starts parseable and the integrity gate passes.

## Remaining Explicit Gaps for Ticket Decomposition

These do not block this specification but must be resolved by source-backed ticket design:

1. Whether the current evidence-bundle schema is minimally extended for Run artifacts or a small Run-bound companion manifest reuses its validator conventions.
2. Whether canonical fact safety is delivered by one serialized writer or a stronger atomic claim/append primitive.
3. The exact safe durable location for sanitized packages if they are not version-controlled.
4. The exact bounded wait/quiescence policy for the already identified rollout file.
5. The exact host-language implementation of the lifecycle seam. No language is prescribed; Node/TypeScript cannot be the sole containment boundary under ADR-0002.

## Historical Evidence Statement

The repository-local historical record contains 54 PR-associated main commits, a route/config claim of 11 `EXEC_STRONG` executions, 59 surviving run directories, five surviving late-July result artifacts, four result artifacts declaring `EXEC_STRONG`, one declaring `DIRECT`, zero canonical invocation rows, and zero measured A0 Runs. Each population proves only its own statement. Four surviving result artifacts demonstrate `EXEC_STRONG` result evidence; they do not prove that only four executions occurred. Historical artifacts do not count toward A0.

## Further Notes

ADR-0002 and ADR-0003 remain unchanged. This specification adds no Harness and consumes no DSH protocol. Route remains Director policy/capability rather than provider. Execution success remains distinct from Director acceptance. The future A0/A2 comparison depends on this work producing a new measured A0 corpus, not retroactively upgrading historical runs.
