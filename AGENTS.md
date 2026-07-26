# Director rules

Reasoning lives in `docs/blueprint.md`. These are the rules. Keep this file short.

## Roles

- **Orchestrator** decides, reviews, pushes the branch, opens the pull request. Never merges.
- **Executor** edits files inside the worktree, commits, writes its result, stops. No network.
- **Operator** runs the behavior check and merges. The only one who merges.

## Non-negotiable

1. One writer at a time. `scripts/worktree.sh` holds the lock. Readers unlimited.
2. The executor never pushes, never opens a pull request, never merges, never reaches the network.
3. Never push to `main`. Never force-push. Never `reset --hard` a pushed branch. Never rewrite history — revert instead.
4. Every headless agent call carries a `timeout`, and no inner timeout is shorter than the outer one.
5. No `*_API_KEY` in any command. Subscription and OAuth auth only.
6. Only routes named in `.director/routes.yaml` may be invoked, and never a model listed in that route's `forbidden_models`.
7. No cycle ends without a handoff that validates against `schemas/handoff.schema.json`.
8. If auth source, model identity, or no-overage status cannot be verified: publish a handoff and stop.

## The work unit

One unit = one worktree = one branch (`task/<unit-id>`) = one pull request. Contract in `schemas/work-unit.schema.json`.

Every acceptance criterion must be **observable** — something you could watch happen. "Handles dates properly" is not a criterion; "given 2026-02-29, prints an error naming the invalid date" is.

`behavior_check` is the command the operator runs and watches. It must demonstrate the behavior, not report that a suite passed, and it must run on Windows.

A unit that cannot be specified in 1,500–4,000 tokens without hand-waving is too big. Diffs over ~400 lines defeat review.

## The four decisions

- **PROMOTE** — criteria met, tests pass, scope respected. Push, open the PR, recommend merge.
- **FOCUSED_CORRECTION** — specific defect, same route still right. One only, per diagnosis.
- **ESCALATE** — a stronger route is justified, on a fresh diagnosis naming the capability delta. "Use a smarter model" is not a diagnosis.
- **REJECT** — unsafe, out of scope, or cheaper to redo than repair.

Before escalating, run the attribution test in blueprint §13.2. Questions 1 and 2 fail far more often than 3.

## Review — Layer 2

Two passes, reported separately, never merged into one verdict:

- **Spec pass** — measured against `acceptance_criteria`. What is missing, what nobody asked for, what is wrong. Quote the criterion.
- **Standards pass** — written conventions only. Cite the source. Skip whatever a linter enforces.

Findings, not essays. **May add reasons to reject; may never be the reason to merge.**

Never review with a model from the executor's vendor.

## Auto-merge

Only `change_class: green-path`, only with every check green, only when the diff touches none of `.github/**`, `.claude/hooks/**`, `.claude/settings*.json`, `AGENTS.md`, `CLAUDE.md`, `.director/routes.yaml`, `scripts/**`.

If `change_class` is ever ambiguous, it is `behavior`.

**The operator's spot-check is an intent audit, not a code review.** One question per sampled pull request: *should this have been `behavior`?*

## Token accounting

Read the scorecard, never the raw ledger — reading it spends the budget you are measuring.

```bash
bash scripts/telemetry/route_advisor.sh --task-class <class> --complexity-band <band>
```

Consult it before selecting a route, before escalating, and when choosing batch vs interactive.

The policy is **advisory**. It reports what it would choose; you still decide. Only the operator may set `mode: enforcing`.

`recommended_route: null` means insufficient evidence, not "any route is fine". Under 10 completed runs or below 0.90 validated success, a route is ineligible. Today every answer is null — that is correct, not broken.

Deviating from a recommendation is allowed and expected. Record the reason.

Optimise `tokens_per_validated_success`, never tokens per attempt — a cheap route that retries constantly is the expensive one.

Never call an estimate a measurement. Preflight estimates; only post-invocation telemetry measures. `estimated_cost` is null because we are on subscriptions; quota is the currency.

## Adding anything

Nothing is added — no rule, script, hook, note, route, or section — for a failure mode that has not occurred at least twice in `.director/failures.md`.

If a proposed rule can be a GitHub ruleset, a CI step, a hook, or a registry entry, it must not be prose. Prose is the weakest tier and this file is already competing with a large ambient instruction layer.
