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
