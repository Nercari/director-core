# Failure log

One line per failed unit: date · unit-id · which question of blueprint §13.2 it
failed · one sentence.

This file exists to make one rule enforceable:

> **Nothing may be added — no rule, script, hook, note, route, or section — for a
> failure mode that has not occurred at least twice here.**

Before investing in a fix, estimate its ceiling. If a category is 5% of
failures, eliminating it perfectly buys 5%. Most proposed machinery targets
categories at 0%.

Questions 1 and 2 fail far more often than 3. A unit that failed twice is
usually cut wrong, not under-powered.

| Date | Unit | §13.2 question failed | What happened |
|---|---|---|---|
| — | — | — | *empty. The pipeline has not run.* |

## Baseline

Recorded retrospectively from git history on 2026-07-25, since the throughput
data already existed and a blocking baseline week would have been machinery for
a decision months away:

- `Finance dashboard` — 15 commits, week 29
- `Mega-brain Project` — 8 commits, week 29
- `hermes-autoresearch` — 7 commits, week 30

**Baseline: roughly 10–15 commits per week of directly-driven work.**

Permanent caveat: these are *commits*, not *merged units*, because none of that
work passed through a pull request. Comparable in magnitude, not in kind.

## Enforcement failures observed 2026-07-26

Not unit failures — false safety claims in this repository's own configuration,
found by an independent conformance probe plus a direct re-probe.

| Date | What | §13.2 | Detail |
|---|---|---|---|
| 2026-07-26 | `network: denied` on both executor routes | n/a — spec defect | Declared, never enforced. Probed under `--sandbox workspace-write`: `nslookup` exit 0, `gh auth status` exit 0, `gh api user` exit 0 returning live authenticated JSON with `repo`+`workflow`. Seven units ran with the gate reachable |
| 2026-07-26 | declared path scope ignored by agy | n/a — spec defect | Wrote to a forbidden path (`permitted: true`) and created an unrequested file |
| 2026-07-26 | declared path scope ignored by codex | n/a — spec defect | Left `.director-codex.log` at repo root after being scoped to specific files |

**Twice now, so §13.3's bar is met and machinery is justified:** declared-path
enforcement has failed on *both* executors, independently. The orchestrator must
diff and reject; the executor cannot be trusted to self-limit.

**Root cause of the network claim, stated plainly:** §4.1 principle 10 says to
prefer removing a capability over guarding it. What happened instead was writing
down that the capability had been removed. A guarantee nobody probed is a
guarantee nobody has.

## validate-result.sh fail-open, found 2026-07-26

Third enforcement defect of the day, and the second in the scope-checking path.

`validate-result.sh` had never been executed since it was written. First run
revealed it **failed open**: with the packet missing, or present but declaring no path scope, it skipped the scope check silently and printed
`VALIDATED - safe to review, push, and open a pull request` for a commit
containing a deliberate `FORBIDDEN.txt`.

Now fails closed. No packet, or no declared path scope, is a REJECT: an undeclared
scope is not an unlimited scope.

The lesson is the same one as the shellcheck glob and the model-name include
list: **an unexercised check is an unknown check.** Three of tonight's defects
were checks that reported success by not looking. Writing a gate and running a
gate are different acts.

## EXEC_PRIMARY declared but never functional, found 2026-07-26

`routes.yaml` named agy as the primary executor and codex as escalation-only.
Eleven units ran. **All eleven went to codex. Zero went to agy.** The registry
and the practice had disagreed since the day it was written, and nobody noticed
because the config was never exercised.

Probed with the exact configured invoke line:

    agy -p --sandbox --mode accept-edits --print-timeout 5m
    -> "a tool required the command permission that headless mode cannot
        prompt for, so it was auto-denied"

No output. No work done. The route could never have executed anything.

Making it work needs `--dangerously-skip-permissions`, which auto-approves every
tool. With egress still open and this route already observed writing outside its
declared scope, that is worse than the escalation route, which runs sandboxed
with no bypass flag at all.

**The pattern, fourth instance today:** a declaration nobody exercised. The
shellcheck glob, the model-name include list, `validate-result.sh`'s scope check,
and now an entire executor route. Each looked correct in the file and did nothing
in practice.

Corrected by describing what is true — agy blocked with the unblock order
recorded, codex marked de facto primary — rather than by adjusting practice to
match an aspiration.

## Executor commit contract impossible under workspace-write, found 2026-07-27

The configured invocation failed before Git could commit with `fatal: Unable to
create '.../.git/worktrees/<wt>/index.lock': Permission denied`. Supplying an
author and committer identity did not change that result. Two independent units
completed their required tests but could not sign; eleven earlier units hid the
defect because the orchestrator committed by hand and instructed the executor
not to. The route worked, but the contract had never been exercised. The
contract now requires modified files, evidence, and a result; the orchestrator
reviews, stages, and commits. Making `.git` writable was rejected because it
would also grant the executor write access to the Git index and refs.

## Enforcement failures observed 2026-07-28

Not unit failures — false or unusable enforcement claims found by direct probes.

| Date | What | §13.2 | Detail |
|---|---|---|---|
| 2026-07-28 | registered strong-executor invocation rejected by the API | n/a — invocation defect | The schema used a construct structured output cannot express, and structured output also requires every property to be required, which this intentionally optional-field contract cannot satisfy; fixed by dropping structured output from the route rather than changing the contract |
| 2026-07-28 | permission-bypass requirement refuted | n/a — registry defect | A headless probe ran without a bypass when the invocation granted the working directory and the tool allowlist covered the tools needed |

## Orchestrator-executor system defects, found 2026-07-28

Not unit failures. Found while orchestrating unit `unrestricted-baseline` (#28)
and then attempting to route the next unit in the #27 chain. Recorded here
because §13.3 gates every addition on a failure appearing twice, and several of
these are further instances of patterns already logged above.

| # | What | Class | Evidence |
|---|---|---|---|
| 1 | Layer 2 review is mandatory and has no route | registry gap | AGENTS.md forbids reviewing with the executor's vendor; rule 6 forbids invoking anything not in `routes.yaml`. The registry names no reviewer route. `layer2: cross-vendor` appears only as a property of `capacity_states`, not as an invocable route |
| 2 | Rule 7 has no enforcement point | unenforced rule | `.director/current-handoff.json` does not exist. Unit #28 completed with no handoff, and nothing objected |
| 3 | `preflight.sh` cannot answer its own hook question | check measures the wrong thing | It reported `CLAUDE_PROJECT_DIR is unset — cannot confirm the hooks are wired`, in a session where `block-dangerous-bash.sh` fired and resolved that variable correctly. Preflight inspects the orchestrator's shell, not the hook runtime |
| 4 | `preflight.sh` warns on the correct state | warning-fatigue defect | `[WARN] on branch 'task/<unit>', not main`. A unit must be on a task branch |
| 5 | Route availability is not machine-checked | unenforced rule | Blueprint §175 states it outright: no script reads `quarantined`, `jail_verified`, or a missing `invoke` key. Only the orchestrator reading the YAML by eye stopped a quarantined route being used |
| 6 | Duplicated registry state has drifted | stale duplicate | Blueprint §7.2's inline copy says `EXEC_STRONG: quarantined: true`; `routes.yaml` says `false`. §173's precedence rule contains the damage but the second copy is wrong |
| 7 | The #27 chain has a circular dependency | spec defect | #29 is labelled "Blocked by: None — can start immediately", but it measures drift in the bounded executor, which has no `invoke:` key. It is blocked by #31 and #32 — the very containment work it was meant to inform |
| 8 | The worktree lock cannot detect a dead owner | partial control | `worktree.sh` records `unit_id` but no PID or timestamp. A crashed orchestrator leaves a lock whose documented remedy is manual removal. One writer is enforced; one *live* writer is not. #33 covers the cross-project half; this half is uncovered |

**Defect 2 was committed by this orchestrator, not merely observed by it.** Unit
#28 ran without a worktree, without a work-unit packet, without
`validate-result.sh`, and without a handoff. It ran in capacity state C′ —
DIRECT execution with self-review — and that state was never declared. C′
forbids auto-merge and requires treating every change as behavior-changing.
Neither obligation was consciously discharged, because nothing asked.

**Defects 3 and 5 are the sixth and seventh instances of the pattern already
named above:** a check that reports success by not looking, and a declaration
nobody exercised. The bar in §13.3 was met several instances ago. Defect 5 is
the one with a mechanical fix available — `quarantined`, `jail_verified`, and a
missing `invoke` key are three fields a script can read — and #27 already scopes
it out as "its own unit".

**Defect 1 is the most serious and has no cheap fix.** Every unit merged so far
has either violated rule 6 or performed self-review while recording cross-vendor
review. Which of those it was cannot be determined from the record, and that is
itself the finding: the review tier leaves no evidence of which model reviewed.
