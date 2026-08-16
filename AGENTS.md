# Director rules

Reasoning lives in `docs/blueprint.md`. These are the rules. Keep this file short.

## Roles

- **Orchestrator** decides, reviews, pushes the branch, opens the pull request. Never merges.
- **Executor** edits files inside the worktree, writes its result, stops.
- **Operator** runs the behavior check and merges. The only one who merges.

## Non-negotiable

1. One writer at a time. `scripts/worktree.sh` holds the lock. Readers unlimited.
2. The executor cannot push, open a pull request, or merge — **provided you invoke it through `scripts/exec-jail.sh`, which is what each usable route's `invoke:` line in `routes.yaml` does. Never call an executor binary directly. A route with no `invoke:` key is not usable — see §7.4.** Jailed and probed 2026-07-26: `gh` unauthenticated, `gh api` refused, `git push` cannot authenticate. Unjailed, all three succeed.
2a. **Executors have made incidental writes** (for example a stray log, cache, or their own memory file), while observed runs respected declared task boundaries: they stopped at stop conditions, refused unavailable commits, reported the exact reason, and did not touch forbidden paths. Never treat an executor's exit code or prose as evidence anyway. Diff its working-tree changes yourself and reject any scope violation — that check belongs to the orchestrator.
2b. **Egress is closed for the `director-exec` account only, and no route runs as that account.** TCP egress from `director-exec` is denied by SID-scoped firewall rules and was measured on 2026-07-30. UDP/443 is denied by the same rules and has never been observed being denied — this curl has no HTTP3 support, so the QUIC probe has never run. `scripts/exec-jail.sh` performs credential removal, not account isolation: it scrubs gate credentials and does not switch user, so an executor launched through it inherits the invoking account's unrestricted network. **Until a route declares `runs_as: director-exec` and preflight proves it, every executor has full network and can exfiltrate.** Do not describe the jail as isolation.
2c. **No adapter imposes on another harness a restriction written for Claude, Codex, or any single vendor.** Required isolation and safety properties are imposed by the runner or by external controls — identity, ACL, worktree, sandbox/jail, network, validation, rulesets — and stated as the property that must hold, never as one vendor's flag. A vendor flag is an implementation detail of the adapter that happens to be running. Recorded 2026-07-30: a Claude-flag rule blocked an unrelated evaluation harness while failing to stop the same behavior through a subprocess.
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

**Auto-merge is off.** The operator merges every pull request, by hand, after watching the behavior check. `gh pr merge --auto` is denied by `.claude/hooks/block-dangerous-bash.sh`, and the hook self-test asserts that denial.

The eligibility rules that used to sit here — green-path only, every check green, a protected-path list — lived in prose and nothing recomputed them for the commit being merged. Auto-merge was armed on four behavior-class units and correctly zero times that anyone measured. It was removed rather than verified, because the pipeline has not yet completed one work unit end to end and there is nothing to optimise.

The deleted rules are in git history. Earning the capability back means building a deterministic eligibility check, not restoring the prose.

`change_class` still declares intent in the packet. If it is ever ambiguous, it is `behavior`.

## Running these scripts on Windows

`bash` is not Git's bash from a PowerShell prompt. `C:\Windows\System32\bash.exe`
is the WSL launcher and shadows it, so every `bash scripts/...` line here fails
with `execvpe(/bin/bash) failed: No such file or directory` on a machine with no
WSL distro. Measured 2026-08-16 running `worktree.sh resume`.
`docs/operator/egress-boundary.md` had already worked around this in one place,
which is why the note lives here instead of being fixed in that doc alone.

From PowerShell, name Git's bash:

```powershell
& "$env:ProgramFiles\Git\bin\bash.exe" scripts/<script>.sh <args>
```

From Git Bash, or from an agent's own shell, `bash scripts/<script>.sh` is
correct and unchanged. Every `bash` fence in this file is written for that shell.

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

## Agent skills

### Issue tracker

GitHub Issues on `Nercari/director-core`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical labels, unchanged (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
