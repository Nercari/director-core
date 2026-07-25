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
