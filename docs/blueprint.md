# DIRECTOR ORCHESTRATION BLUEPRINT — REVISION 10.3

**Supersedes:** all prior revisions (7.4, 8.x, 9.0–9.3, 10.0, 10.1, 10.2)
**Date:** 2026-07-25
**Operator:** solo, non-programmer. Subscriptions: Claude Pro · ChatGPT Plus · Google AI Pro · local models via LM Studio
**Platform:** Windows 11 Pro, PowerShell primary, Git Bash (Cygwin bash 5.3.9) available
**Policy:** zero metered spend, always. OAuth/subscription auth only — never an API key
**Status:** implementation-ready. Every environment claim below was verified on this machine on 2026-07-25.

**What 10.3 adds:** §21, the Token Accounting and Workflow Efficiency Plane — implemented and merged after 10.2 was written. It was working code with no place in the specification, which is the §6.2 failure this document warns about applied to itself: a subsystem that exists only in the repository and in a conversation does not exist for the next session.

---

## 0. Read this first

The pipeline this document describes has never been run. Its **environment claims are now verified** (§Appendix A) but its **behavioral predictions are not**. When reality contradicts this document, reality wins and you edit the document.

**The one thing to understand before anything else:** you are not going to review code. Ever. You will review **behavior** and **intent**. The machines review mechanics. A second AI reviews implementation. None of them knows what you actually wanted — only you do, and that is the job this document assigns you.

**What 10.2 changes:** 10.1 was written from recall. 10.2 was written after querying the machine. Eleven decisions were made and eleven claims were falsified — including one mechanical self-contradiction that would have blocked auto-merge, one that would have blocked the orchestrator from improving its own core, and a hole in the enforcement model at the executor boundary that made five of the ten hook invariants decorative. A route 10.1 deleted as broken was found working. §19 lists what remains unverified; it is shorter than it was, and honest.

---

## 1. Decision in one paragraph

Claude Code orchestrates and reviews. A delegated executor implements **inside a worktree**; the jail removes gate credentials while egress remains an explicit residual. The Director is a single `AGENTS.md` read natively by Codex and Antigravity and bridged into Claude Code by a one-line `CLAUDE.md`. Every unit of work runs in its own git worktree on its own branch; the **orchestrator** — never the executor — reviews, stages, commits, pushes the branch, and opens the pull request. Changes that introduce **no new observable behavior** merge automatically when deterministic checks pass. Changes that introduce **new behavior** require you to run one command, watch it work, and click merge. A local git-backed Obsidian vault holds procedural memory; a separate public repository holds the reusable core. Nothing in the architecture names a model; models are chosen per project, at setup, and recorded in one registry file with expiry dates.

---

## 2. The verification model

Everything here serves this structure. It is the answer to "I can't read code."

Three verification layers, valuable because they **fail differently from one another**. Stacking checks multiplies safety only when failures are independent; correlated checks give far less protection than their individual rates suggest. This is why the design does not simply hand review to an AI.

**Layer 1 — Machines verify mechanics.** Tests, type checker, linter, schema validation, duplication threshold. These execute; they do not reason. They fail on a completely different error distribution than a language model, making them the most genuinely independent layer. They are also the narrowest: static analysis catches somewhere between 4.5% and 36% of real bugs depending on the study, and a type checker would have caught about 15% of JavaScript bugs in the largest study of the question.

**Layer 2 — A second model reviews implementation.** The orchestrator reads the diff the executor produced. Cross-vendor, so less correlated than a model reviewing itself — but not independent. Independently written implementations fail together far more than chance predicts, because they share a specification. **Therefore this layer may add reasons to reject and may never be the reason to merge.**

**Layer 3 — You verify behavior.** You run one command and watch the software do the thing you asked for. The only layer that knows the intent, and fully independent of every model in the pipeline. It catches the defect class the other two miss most: code that is correct, tested, reviewed, and does the wrong thing.

**The residual, stated plainly.** Even with all three, roughly one defect in seven survives — the measured ceiling of testing-plus-static-analysis without effective human inspection. The survivors are concentrated in specification and logic errors, because those are what mechanical checks cannot see and what a correlated reviewer shares.

**What follows.** The highest-leverage work is not review — it is **writing the specification as observable behaviors before any code exists**. A criterion you cannot observe is a criterion no layer can verify.

**Layer 2 is now preserved under degradation.** 10.1 accepted that losing the primary orchestrator collapsed reviewer and executor into one model. With three vendors available (§7.1) that is no longer true, and §7.5 is rebuilt accordingly. The one state where Layer 2 genuinely becomes self-review is named, and auto-merge is forbidden there.

---

## 3. What 10.2 changes from 10.1

| # | Change | Why |
|---|---|---|
| 1 | **The vault's real path, structure, and rulebook** (§11) | 10.1 pointed at `~/Documents/obsidian vault`, which does not exist, and invented a four-folder tree matching neither the real vault nor `AI-SHARED.md`, which declares itself canonical |
| 2 | **The reusable core moved out of the vault** into its own repository (§6.1, §11) | 10.1's §15.1 hook made the vault read-only outside one inbox path, while §11.3 required core artefacts to be improved in the vault. The orchestrator could never have improved its own core |
| 3 | **The executor loses gate credentials** (§8.3, §9, §15.1) | Hooks are Claude Code `PreToolUse` hooks. They fire on the orchestrator's tool calls and are invisible to a subprocess. 10.1's `output_contract` required the executor to push and open a PR — handing the gate's bypass to the least supervised process; egress remains recorded residual risk |
| 4 | **agy restored as a route** (§7.1, Appendix A) | 10.1 listed it Known-broken. Tested: `agy -p` exits 0 and prints correctly under non-TTY. The deletion rested on a false claim, and it contradicted a standing operator rule mandating delegation to that route |
| 5 | **Degradation ladder reordered** (§7.5) | 10.1 warned that one state lost Layer 2 and waved through a worse state that lost it to *self*-review. Escalating to a third vendor is now tried before going DIRECT |
| 6 | **`gh pr merge` hook narrowed** (§15.1) | 10.1's hook blocked `gh pr merge` outright. Auto-merge is armed with `gh pr merge --auto`. §15.1 blocked §9.4 |
| 7 | **Optimizing metric dropped; thresholds kept** (§13.3) | A weekly counting ritual is machinery for a decision months away. §13.3's own rule forbids it. The baseline was taken retrospectively from git history instead |
| 8 | **Parallelism split by evidence** (§16, §17) | The measured failure is concurrent *writers* losing work. 10.1's wording forbade concurrent readers too, which the evidence does not support and which costs a solo operator real speed |
| 9 | **Instruction tier demoted honestly** (§8.1, §15) | 10.1 argued for a short `AGENTS.md` on a ~15-constraint budget already exceeded several times over by the ambient session layer. Short is still right; load-bearing was never true |
| 10 | **Phase 3 moved to a content project** (§18) | §9.4 condition 4 makes almost every file in the core repository non-green-path. Auto-merge cannot be meaningfully exercised there |
| 11 | **Third-party material excluded from git** (§11.2) | The vault holds 118 PDFs of a paid commercial course. A private repository is not publication, but it is upload |

---

## 4. Durable core

**Structure** (expected to last years): the roles; the four decisions; the work-unit contract; one unit = one worktree = one branch = one pull request; the three-layer verification model; the human behavior gate; the handoff; the no-overage principle; the rule that machinery must earn its place; **the rule that enforcement stops at a process boundary**.

**Facts** (expected to rot in weeks): model identifiers, quota figures, CLI flag names, prices. All of it lives in that project's `.director/routes.yaml`.

### 4.1 Design principles

1. **Capability aliases, never model names.** `ORCH_PRIMARY`, `ORCH_FALLBACK`, `EXEC_PRIMARY`, `EXEC_STRONG`, `EXEC_LOCAL`.
2. **Prefer a native platform feature to bespoke code.**
3. **Enforce mechanically where possible; declare honestly where not.**
4. **Reversible by default.**
5. **No claim without a way to check it.**
6. **Nothing dated in prose.**
7. **Nothing is added for a failure that has not happened twice** (§13.3).
8. **Deterministic code for what must hold; readable markdown for what you must understand.**
9. **A fact that can be discovered must not be remembered.** If a CLI can report it, ask the CLI. If a search can confirm it, search at setup. Recall is the least reliable source available and it is the one that fails silently.
10. **New in 10.2 — enforcement stops at a process boundary.** A hook constrains the process it is installed in. Any rule you need to hold inside a subprocess must be enforced by removing the subprocess's capability, or by a server-side gate, or it is not enforced at all. Prefer removing the capability; it is a smaller change than adding a guard.

### 4.2 Surviving model churn

Every registry entry carries `last_verified: YYYY-MM-DD`; `preflight` warns past 90 days and refuses past 180.

**The ten-minute swap drill.** Change a route's model, re-run the conformance checklist. Pass: the swap touched only `routes.yaml`. Fail: you had to edit `AGENTS.md`, a hook, or a script — the abstraction leaked; fix the leak, not the model.

**This is why you do not need to know which model is best.** You need to know it is available and that swapping it leaves decisions identical. That is a test, not knowledge — and it is the entire reason model names are forbidden outside the registry.

---

## 5. Topology

```
Operator
│ answers the routing interview once per project
│ runs the behavior check, reads the summary, clicks merge
▼
ORCHESTRATOR ── ORCH_PRIMARY (Claude Code — the only route with hooks)
     └─ ORCH_FALLBACK (degraded — no hooks)
│ hosts: AGENTS.md · hooks · handoff · adversarial review
│ OWNS: worktree creation, branch push, pull-request creation
▼
ENFORCEMENT ── GitHub rulesets · CI gate · hooks · 3 scripts · git
▼
EXECUTOR ───── EXEC_PRIMARY        ── tool-specific sandbox; see §8.3
     ├─ EXEC_STRONG   (escalation, named capability delta only)
     └─ EXEC_LOCAL    (conditional — §17.1)
│ produces: modified files inside the worktree. Nothing else.
▼
EVIDENCE ───── worktree · branch · reviewed diff · raw test output
▼
GATE ───────── pull request → checks → (auto-merge | operator merge) → main

CONTEXT ────── director-core repo (reusable core) + vault (procedural memory)

ACCOUNTING ─── every invocation above is metered (§21)
     instrumentation → append-only ledger → reducer → scorecard → advisory route
     runs beside the pipeline, never inside the Director's context
```

One work unit = one worktree = one branch = one pull request. One **writer** at a time; readers unlimited (§17).

---

## 6. What carries over, and what does not

### 6.1 The reusable core — the `director-core` repository

Path: `C:\Users\dorot\Documents\AI Projects\director-core\`. Public. Copied into every project at setup.

| Artefact | Why it carries |
|---|---|
| `AGENTS.md` | The Director rules are about *how work is decided*, which does not vary by project |
| The one-line `CLAUDE.md` | Bridge, not content |
| `preflight`, `worktree`, `validate-result` | Mechanics, not policy |
| The hooks (§15.1) | Same invariants everywhere |
| `.github/workflows/gate.yml` | Same checks; a project may *add* to it, never remove |
| The work-unit and result schemas | Contracts |
| The five conformance scenarios | Decision consistency is project-independent |
| `.gitignore` baseline | Same secrets, same run-state |
| `docs/blueprint.md` | This document |

**Why a repository and not the vault.** 10.1 put these in the vault and then wrote a hook forbidding writes to the vault outside one inbox path, so the orchestrator could never have improved them. Beyond that: these artefacts need CI, diffs, and a public visibility setting that a private notes vault must not have. §11.1's own principle already separates them — *deterministic code for what must hold, markdown for what you must understand.* 10.1 filed the code under markdown.

**When a core artefact improves, it improves here**, and the next project inherits it. Existing projects do not auto-update — they are independent repositories, and a silent retroactive change to a hook is exactly the class of invisible change this system exists to surface. Update an existing project deliberately, as a work unit, with a diff you read.

### 6.2 Per-project decisions — made fresh, before the first commit

| Decision | Why it cannot carry |
|---|---|
| **Repository visibility** | §9.1 |
| **`routes.yaml`** | §7.2 — models rotate, and different work needs different capability |
| **The project's own CI additions** | A Python project's checks are not a shell project's |
| **Path-scope conventions for a work unit** | Structure differs |
| **Whether `EXEC_LOCAL` participates** | §17.1 |

**A per-project decision recorded in conversation is a decision that does not exist.** Every item above lands in a file in that project's repository, or it has not been decided.

---

## 7. Routes and capacity

### 7.1 The registry

`.director/routes.yaml` is the only file in a project containing provider names, model identifiers, quota figures, or prices.

```yaml
routes:
  ORCH_PRIMARY:
    tool: claude                    # 2.1.220
    auth: subscription              # Claude Pro, OAuth
    model: <filled at setup>
    note: the only route with hooks
    last_verified: 2026-07-25
  ORCH_FALLBACK:
    tool: codex                     # 0.144.5
    auth: subscription              # "Logged in using ChatGPT"
    model: <filled at setup>
    enforcement: reduced            # no hooks
    last_verified: 2026-07-25
  EXEC_PRIMARY:
    tool: agy -p                    # 1.1.7
    auth: subscription              # Google AI Pro, OAuth
    model: gemini-3.6-flash-medium
    invoke: NONE — this route has no working invocation (see §7.4). Probed flags
            `--sandbox --mode accept-edits` auto-deny every tool in headless mode.
    network: REACHABLE_NOT_ENFORCED # probed 2026-07-26; see §8.3 correction, §21.8
    gate_credentials: REACHABLE     # gh keyring visible to the executor
    quarantined: true               # do not route work here until enforced
    forbidden_models: [ "claude-*", "gpt-oss-*" ]
    last_verified: 2026-07-26
  EXEC_STRONG:
    tool: codex exec
    auth: subscription
    model: <filled at setup>
    use: escalation only, on a named capability delta
    network: REACHABLE_NOT_ENFORCED # probed 2026-07-26; same gap as EXEC_PRIMARY
    gate_credentials: REACHABLE
    quarantined: true
    last_verified: 2026-07-26
  EXEC_LOCAL:
    tool: lmstudio                  # gemma-4-12b-agentic-fable5-composer2.5-v2-3.5x-tau2, Q4_K_M, 7.38 GB
    auth: local
    state: absent                   # absent | candidate | active — §17.1
    last_verified: 2026-07-25
```

**`forbidden_models` is not optional.** `agy models` reports `claude-sonnet-4-6` and `claude-opus-4-6-thinking` among its options. An executor running a Claude model turns Layer 2 into Claude reviewing Claude, and §2's independence argument dies with nothing in the system detecting it. The same applies to `gpt-oss-*` against `ORCH_FALLBACK`.

**Structural capacity facts** (properties of the plans, not of any model): Claude Pro pools Claude Code with claude.ai and the desktop app, so orchestration competes with ordinary daily use. ChatGPT Plus has per-window and weekly limits. Google AI Pro has its own limits. No vendor publishes exact numbers. A local model has no cap and no marginal cost, but consumes your machine.

### 7.2 The per-project routing interview

Before Phase 0 of any project, the orchestrator conducts one short interview. **It proposes; you confirm or override.**

**The orchestrator's job:**

1. **Query what exists.** `claude --version`, `codex login status`, `agy models`, `lms ls`. Facts discovered, not recalled.
2. **Search for what is current**, at setup time, for anything the CLI does not report.
3. **Propose a complete `routes.yaml`** with every alias filled and dated.
4. **Ask you exactly three things**, and nothing else:
   - Which providers are near their cap right now? *(Your judgment is better here than any inference — this is reactive detection, and you know what you have been doing all week.)*
   - Does this project need `EXEC_LOCAL`? *(Default: no. See §17.1.)*
   - Anything about this project that changes the defaults?
5. **Write the file.** Not the chat.

**The mechanical backstop.** "The orchestrator will ask you" is a bottom-tier instruction, followed probabilistically (§15). So: **`preflight` refuses to launch when any alias is unresolved, when `state:` is missing, or when `last_verified` is older than 180 days.**

### 7.3 Where model facts come from

Neither the operator nor the orchestrator is a source of truth. The orchestrator's recall has a cutoff and degrades silently. The operator reads announcements, not benchmarks.

So the registry is filled from, in order of preference: **what the CLI reports** (a fact about today), **what a setup-time search finds** (live, not remembered), and **what the swap drill proves** (a test, not a claim).

10.1 is the cautionary example: it recorded a working route as permanently broken, on recall, and deleted it. One 45-second test reversed that.

### 7.4 A route that was declared and never worked

`EXEC_PRIMARY` named agy as the cheap primary executor and `EXEC_STRONG` as escalation-only. Eleven units ran. **All eleven went to `EXEC_STRONG`. Zero went to `EXEC_PRIMARY`.** The registry and the practice had disagreed since the day the registry was written, and nobody noticed because the configuration was never exercised.

Probed 2026-07-26 with the exact configured flags:

```
agy -p --sandbox --mode accept-edits --print-timeout 5m "<task>"
→ "a tool required the command permission that headless mode cannot
   prompt for, so it was auto-denied"
```

No output. No work. **The route could never have executed anything.** An orchestrator delegating to it would receive exit 0 and an empty result, which is the worst possible failure shape: silence that looks like success.

Making it functional needs `--dangerously-skip-permissions`, which auto-approves every tool. With egress still open (§21.9) and this route already observed writing outside its declared scope, that is strictly worse than `EXEC_STRONG`, whose workspace-write mode blocks `.git` writes but is not claimed to isolate egress or credentials.

**So the registry now says what is true:** `EXEC_PRIMARY` is quarantined with `blocked_on` recorded and **no runnable `invoke:` key at all** — the probed command is kept only under `invoke_NON_FUNCTIONAL_do_not_use`, because a broken command string sitting in a field named `invoke` is an invitation. `EXEC_STRONG` is marked de facto primary.

Unblock order, if agy is ever wanted: close egress (§21.9), re-probe `exec-jail` against agy specifically — §21.8's proof covers codex only — then reconsider.

**The general lesson, and it is the fourth instance of it in one day:** the shellcheck glob that skipped a directory, the model-name check that skipped a file type, `validate-result.sh`'s scope check that skipped when undeclared, and now an entire executor route. Each was correct in the file and did nothing in practice.

> A configuration nobody exercised is a hypothesis, not a configuration.

### 7.5 Capacity-aware routing

| State | Orchestrator | Executor | Layer 2 | Auto-merge |
|---|---|---|---|---|
| A — nominal | `ORCH_PRIMARY` | `EXEC_PRIMARY` | cross-vendor | permitted |
| B — primary out | `ORCH_FALLBACK` | `EXEC_PRIMARY` | **cross-vendor, intact** | permitted |
| C — primary executor out | `ORCH_PRIMARY` | `EXEC_STRONG` | cross-vendor | permitted |
| C′ — both executors out | `ORCH_PRIMARY` | none: DIRECT | **self-review** | **forbidden** |
| D — orchestrators out | stop, publish handoff, wait | | | |

**State B is no longer a degradation of Layer 2.** With Codex orchestrating and Antigravity executing, reviewer and executor remain different vendors. 10.1 could not express this because it had only one executor vendor.

**State C′ is the honest bad case.** The orchestrator writes the code and reviews its own diff. Self-preference bias in LLM evaluators is documented and scales with the model's ability to recognize its own output. So: nothing auto-merges, every change is treated as behavior-changing, and you run the behavior check even on a refactor. DIRECT is a last resort, not a shortcut — it also spends your scarcest budget, since Claude Pro is pooled with your daily claude.ai use.

**Detection is reactive.** No platform exposes remaining capacity reliably; the system learns it is out by being refused. `current-handoff.json` carries `capacity_state`, which you may set by hand — your judgement outranks inference. A refusal is a first-class event: stop, publish, record, report. Never silently switch providers.

---

## 8. The Director and the work unit

### 8.1 Single canonical source

`AGENTS.md` at the repository root is the only place Director rules are written.

| Platform | Loads it how |
|---|---|
| Codex CLI | natively |
| Antigravity / agy | natively (verified) |
| Claude Code | does **not** read `AGENTS.md`. Bridged by a `CLAUDE.md` containing one line: `@AGENTS.md` |

The widely repeated claim that Claude Code falls back to `AGENTS.md` is false. Use the import, not a symlink.

**Anti-drift rules:** Director rules exist in `AGENTS.md` and nowhere else · `CLAUDE.md` contains exactly one line · do not create `GEMINI.md` · provider facts live in `routes.yaml`, never in prose · no file outside `AGENTS.md` and this blueprint may **define** a Director term.

**Scope of the one-line rule:** `director-core` and projects the Director governs. Pre-existing projects are not migrated. The rule's only function is preventing Director rules from drifting into a second file; that risk exists only where the Director operates.

**Keep `AGENTS.md` short — but do not mistake short for enforced.** Instruction compliance degrades measurably with length, constraint count, and position in context; one benchmark found the best models perfectly follow fewer than 30% of realistic agentic instruction sets, with a distinct falloff past roughly fifteen constraints.

10.1 used that finding to argue a short `AGENTS.md` would keep you inside the budget. It will not. A real session on this machine already carries: a 54-line global `CLAUDE.md` with seven rule blocks, a project `CLAUDE.md`, two SessionStart style plugins, a per-turn UserPromptSubmit hook, a routing-policy notice, a skill-system directive marked EXTREMELY_IMPORTANT, a task-observer mandate, and memory-system instructions. The budget is spent several times over before `AGENTS.md` loads.

**The correct conclusion is the opposite of 10.1's.** Tier 3 is weaker here than assumed, not stronger. So:

- Keep `AGENTS.md` short, because it is free.
- Audit every Director rule with one question: *if the model ignores this, does anything catch it?* If nothing does, move it to a hook, a CI step, or a GitHub ruleset — or accept it as decoration and stop counting it as protection.
- Disable the ambient style plugins inside `director-core`, where they contribute nothing to orchestration and are the two largest blocks. This is the single largest budget recovery available and it costs one settings file.

Reasoning belongs in this blueprint. Rules belong in `AGENTS.md`. Context belongs in the vault.

### 8.2 The work-unit contract

```yaml
run_id: string
unit_id: string            # also the branch name: task/<unit-id>
base_commit: sha
change_class: green-path | behavior      # decides auto-merge eligibility (§9.4)
route: EXEC_PRIMARY | EXEC_STRONG | EXEC_LOCAL | DIRECT
objective: string
acceptance_criteria: [ observable condition ]
allowed_paths: [ path or glob ]
forbidden_paths: [ path or glob ]
required_tests: [ command ]
behavior_check: command    # the one YOU run and watch (§9.5) — must run on Windows
constraints: [ authoritative constraint ]
stop_conditions: [ condition requiring return to orchestrator ]
output_contract:
  modified_files: required     # the executor edits and stops
  evidence_bundle: required
  result_json: required
```

Target 1,500–4,000 tokens. **A unit whose objective and acceptance criteria cannot be written in that budget without hand-waving is too big.** Keep diffs small for a second reason: review effectiveness, human and machine, falls off sharply past roughly 200–400 changed lines.

**Every acceptance criterion must be observable.** Not "handles dates properly" but "given 2026-02-29, prints an error naming the invalid date." If you cannot say what you would watch happen, no layer can verify it, and that is where the residual risk lives.

**No foundation unit.** Every unit must stand green and revertible on its own. The test is not "is it useful alone" but **"is it verifiable alone."**

**The orchestrator stages and commits only after reviewing the diff.** `output_contract` deliberately excludes a candidate commit, `branch_pushed`, and `pull_request`. See §8.3.

### 8.3 Result, and the executor's boundary

```json
{
  "status": "completed | blocked | failed",
  "branch": "task/<unit-id>",
  "route_used": "EXEC_PRIMARY | EXEC_STRONG | EXEC_LOCAL | DIRECT",
  "summary": "short factual summary",
  "files_changed": [], "tests_run": [], "tests_passed": [], "tests_failed": [],
  "unresolved_risks": [], "deviations_from_plan": [],
  "wall_time_seconds": 0
}
```

> **CORRECTION, 2026-07-27 — the original output contract was unsatisfiable.**
> Under the configured `codex exec --sandbox workspace-write` invocation, Git
> fails before a commit: `fatal: Unable to create
> '.../.git/worktrees/<wt>/index.lock': Permission denied`. Supplying author
> and committer identity does not change that binding constraint. Two independent
> units completed their required tests and returned `blocked` with no candidate
> commit because they could not sign. Eleven earlier units appeared to work only
> because the orchestrator committed by hand and told the executor not to.
> Registry and practice diverged from the day the contract was written — the
> same shape as §7.4's unexercised invocation defect, but here the route works
> and the contract was wrong.
>
> Making `.git` writable would restore executor commits, but also gives the
> executor write access to Git's index and refs, including commit and history
> rewrite operations. That option is rejected: the safer boundary is reviewed
> working-tree changes followed by an orchestrator-owned stage and commit.
>
> **Sandbox is not one property across tools.** agy's `--sandbox restricted`
> was observed to restrict neither network, credentials, nor paths. Codex's
> `--sandbox workspace-write` blocks `.git` writes, but does not block network
> egress or inherited credentials. Do not transfer a property observed for one
> tool to the other.
>
> **Earlier correction, 2026-07-26 — read before relying on anything below.**
> This section described the executor as having no network. **It does.** Probed
> directly under `codex exec --sandbox workspace-write`: `nslookup github.com`
> exit 0, `gh auth status` exit 0, **`gh api user` exit 0 returning live
> authenticated JSON** with `repo` and `workflow` scope. An independent probe
> found the same for agy, which additionally wrote outside its `allowed_paths`.
> agy's sandbox restricted neither network, credentials, nor paths. Codex's
> workspace-write sandbox did restrict `.git` writes, but not network or
> credentials.
>
> Seven units were executed on this design on 2026-07-25. Nothing mechanical
> prevented the executor pushing a branch, opening a pull request, or merging
> one. Only the prompt asked it not to — tier 3, the weakest layer here.
>
> **The design below is right. The implementation was a declaration, not a
> control.** §4.1 principle 10 says to prefer removing the capability; what
> actually happened was writing down that it had been removed. `routes.yaml`
> now records `network: REACHABLE_NOT_ENFORCED` and both executor routes are
> quarantined. §21.9 records the enforcement that would make the claim true.
>
> **Update, same day:** the gate half is now closed and probed — see §21.8.
> `scripts/exec-jail.sh` removes the credentials, verified inside a live jailed
> executor run. Egress remains open. The routes are out of quarantine for the
> gate and only for the gate.
>
> This is the sharpest available example of the document's own thesis: a
> guarantee nobody probed is a guarantee nobody has.

**The executor's gate credentials are removed by the jail; egress remains open.**

10.1 required the executor to push its branch and open the pull request. That design hands the gate's bypass to the least supervised process in the system, for a structural reason 10.1 did not notice: **every hook in §15.1 is a Claude Code `PreToolUse` hook.** It fires on the orchestrator's tool calls. An executor launched as a subprocess runs its own shell; the hook sees `agy -p "<packet>"` and nothing after. Of the ten invariants, only "no push to `main`" had a second line of defence (the GitHub ruleset). The rest — no force-push, no hard reset, **no merging**, no reading secrets, no metered credentials — were unenforced against the one process actually writing code.

And the executor inherits the operator's credentials. `gh` is authenticated via keyring with `repo` scope, and §9.2 sets required approvals to zero. An executor running `gh pr merge` on its own pull request **would have succeeded** — which is precisely the fifth conformance scenario §18 Phase 4 claims to test.

**So the capability is removed rather than guarded** (§4.1 principle 10):

- The executor runs through the jail, with no reachable `gh` credential; egress remains an accepted residual.
- It edits files inside the worktree, writes evidence and its result JSON, and stops.
- The **orchestrator** reviews the uncommitted diff, stages and commits it, then pushes the branch and opens the pull request, where all ten hooks apply.
- Only the operator ever merges.

This is a smaller design than 10.1's, not a larger one: the orchestrator already holds the worktree, the diff, and the review. It also removes §9.4 condition 2's ambiguity about authorship, since nothing but the orchestrator ever opens a pull request.

`validate-result` rejects claimed success when: `main` changed · the working-tree diff contains files outside the unit's permitted paths · required tests were skipped without a reported blocker · a metered credential was used · an unauthorised route or a `forbidden_models` entry was used · the executor reports reaching the gate.

---

## 9. GitHub — the gate

### 9.1 Visibility — a per-project decision

| Setup | Rules enforced? | Secret push protection? | Actions | Cost |
|---|---|---|---|---|
| Free, public | yes | yes, on by default | unlimited | $0 |
| Free, private | **no** | no | 2,000 min/mo | $0 |
| Pro, private | yes | no (needs paid add-on) | 3,000 min/mo | ~$4/mo |

**`director-core` is public**, and the entire justification is that it holds orchestration infrastructure and nothing else — `AGENTS.md`, `routes.yaml`, hooks, three scripts, schemas, conformance scenarios, the CI workflow, this document. On the specific axis of "stop me from committing a key," a free public repository is the strongest of the three options.

**That justification does not transfer.** A project holding actual content has no such argument, and **anything committed to a public repository is public permanently.** `git revert` cancels an effect; it does not erase history. Switching to private afterwards does not un-publish and turns branch protection off.

**So, before the first commit of every project, decide explicitly:**

- Does this repository contain anything you would not publish, or anything you do not own? → **private**, and accept that free private repos get no rulesets and no push protection. Your gate becomes the CI check plus your own discipline.
- Orchestration infrastructure or genuinely public work only? → **public**, and you keep the free enforcement.

Record the decision and its reason in the project's README. It is the one decision in this whole system that cannot be undone.

**Private is not the same as unpublished.** A private repository still uploads. Content you do not own does not belong in either kind — see §11.2.

**Local run state stays out**, always. Before the first commit, `.gitignore`:

```
.director/handoffs/
.director/current-handoff.*
.director/runs/
.director/probes/
.scratch/
.claude/settings.local.json
.env
.env.*
*.key
*.pem
secrets/
```

### 9.2 Repository configuration (public repos)

**Ruleset on the default branch.** Enforcement: Active → target default branch. Enable: **Require a pull request before merging** with required approvals **ZERO** · **Require status checks to pass** · **Block force pushes** · **Restrict deletions**.

**Leave the bypass list EMPTY.** A rule the owner silently bypasses is not a gate. On a personal repository bypass actors cannot be added at all.

**Why zero approvals:** GitHub does not permit approving your own pull request. Requiring one makes every PR permanently unmergeable except by bypassing — which removes the gate entirely.

**Other settings:** squash-merge as default; PR template; Actions spending limit **$0**; Linux runners only; **`allow_auto_merge` → `true`** (it defaults to `false`; verified on this account. Merge queues are organization-only).

### 9.3 The CI gate

Deliberately **credential-free**: conformance scenarios need an agent, an agent needs an API key, and §14 forbids one.

`.github/workflows/gate.yml`:

```yaml
name: gate
on: pull_request          # never pull_request_target
permissions:
  contents: read          # least privilege; fork PRs get no secrets
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4   # pin by SHA once you know the digest

      - name: CLAUDE.md is exactly one line
        run: test "$(wc -l < CLAUDE.md)" -le 1

      - name: No Director term defined outside AGENTS.md
        run: |
          hits=$(grep -rl "PROMOTE\|FOCUSED_CORRECTION\|allowed_paths" \
                   --include="*.md" . \
                 | grep -v "^\./AGENTS\.md$" \
                 | grep -v "^\./docs/blueprint\.md$" || true)
          if [ -n "$hits" ]; then echo "Director terms in: $hits"; exit 1; fi

      - name: shellcheck
        run: shellcheck scripts/*.sh

      - name: schemas are valid
        run: |
          pipx install check-jsonschema
          check-jsonschema --check-metaschema schemas/*.json
```

**`pull_request`, never `pull_request_target`** — on a public repo, `pull_request` runs fork code with a read-only token and no secrets; `pull_request_target` runs with full secrets and write access and is the documented path by which public repositories get compromised. **`permissions: contents: read`** — least privilege, stated rather than inherited. **`|| true` after grep** — grep exits 1 when it finds nothing, which would fail the step on success.

**This document must live at `docs/blueprint.md`.** The grep step exempts exactly two paths. Move it and the gate fails on its own specification.

**`shellcheck` is not installed locally** and does not need to be — the step runs on `ubuntu-latest`.

**As a project grows, add in this order** (ranked by measured defect-detection value per unit of cost):

1. **Test suite** — highest value, most independent of model error.
2. **Type checker** — roughly 15% of bugs in the largest study; cheap, deterministic.
3. **Linter + formatter.**
4. **Duplication threshold** — targets the documented failure mode of AI-assisted code, where duplicated blocks rose roughly eightfold in a 211-million-line analysis.
5. **Mutation testing** — the honest answer to "would my tests notice if the feature vanished?" Expensive; run **monthly on a schedule, never per-PR**.

**How you verify the gate works** — once, before trusting it: open a throwaway PR adding a second line to `CLAUDE.md`. Red. Add a Director term to a new markdown file. Red. Break a script's syntax. Red. Revert, watch it go green. **A gate never seen refusing something is not a gate.**

### 9.4 Auto-merge

No model decides. A **check** decides, and only for changes it fully covers.

**Green-path change — auto-merge permitted.** No new observable behavior: refactor with unchanged tests, dependency bump, documentation, formatting, configuration validated by schema. Its acceptance criterion is "everything that worked still works," and the test suite completely verifies that claim.

**Behavior change — auto-merge forbidden.** Anything that adds or alters what the software does. No check can confirm it does what *you* wanted, because no check knows what you wanted.

`change_class` is a packet field. The orchestrator proposes it; if ever ambiguous, it is `behavior`. **That proposal is the one thing your spot-check audits** (§12).

**Hard conditions — all must hold:**

1. `change_class: green-path`.
2. **Opened by the orchestrator on your behalf.** Never a stranger's PR, ever.
3. Every required check green.
4. The diff touches none of: `.github/**`, `.claude/hooks/**`, `.claude/settings*.json`, `AGENTS.md`, `CLAUDE.md`, `.director/routes.yaml`, `scripts/**`. **A change to the enforcement layer is never green-path.**
5. Capacity state A, B, or C. **Never C′** — Layer 2 is self-review there (§7.5).
6. **`route_used` is not `EXEC_LOCAL`** while that route's `state: candidate` (§17.1).

**Public-repo hardening, all free:** pin every action by full commit SHA; require manual approval for first-time-contributor workflow runs; enable Dependabot and the dependency-review action; CODEOWNERS on `.github/**`.

### 9.5 The behavior check — your actual job

Before merging any behavior change, you run one command and watch it do the thing.

This closes the failure mode nothing else catches: **a green test on a feature that was never built.** The executor reports success, tests pass, the diff looks plausible, the reviewer approves — and it does not work, because the test and the feature came from the same model, the same session, and the same misunderstanding.

1. `behavior_check` is a packet field and appears **verbatim in the pull-request description**.
2. It must **demonstrate the behavior**, not report that a suite passed. `./run.sh --date 2026-02-29` printing an error naming the date is a demonstration. `pytest -q` printing `12 passed` is a report.
3. It runs in the worktree, before removal.
4. **It must be runnable by you, on Windows.** A one-line command in PowerShell or Git Bash, or a documented app launch. A check you cannot execute is a check that will not happen.
5. **A failing or unrunnable behavior check blocks the merge.** No exceptions, and specifically not "but CI is green."

### 9.6 Reading a pull request without reading code

None of this is code review. All of it is shape.

1. **Files changed** — does the list match the task? Unrelated files are the strongest red flag.
2. **Diff size** — proportionate?
3. **Tests** — present and green?
4. **Deletions** — large removed blocks deserve scrutiny.
5. **Secrets** — push protection catches known credential formats, not a password in a config file.
6. **The description** — does the agent's account match what you asked?
7. **The enforcement layer** — does the diff touch the §9.4 condition-4 paths? Read deliberately, never scan.
8. **The classification** — reading 1, 2 and 6 together: does this sound like it changes what the software does? If yes, it was not green-path.

**Do not merge to be polite to a machine.**

### 9.7 Undoing things

Unpushed commit → `git reset --soft HEAD~1` · pushed commit → `git revert <sha>` · merged PR → the **Revert** button · forbidden by hook: `push --force`, `reset --hard` on a pushed branch, branch deletion. **Prefer revert; never rewrite history.**

---

## 10. Adversarial review — Layer 2

After the executor stops and before the orchestrator stages and commits, the orchestrator reviews the diff.

**Why cross-vendor matters.** Different vendor, different training, different harness — measurably less correlated than a model grading its own work, where self-preference bias is documented and scales with the model's ability to recognize its own output. Costs nothing extra: the orchestrator already holds the diff.

**Why it is still not an audit.** Independently produced implementations fail together far more than chance predicts, and the shared cause is usually the specification. If your acceptance criteria are wrong, the executor implements the wrong thing and the reviewer approves the wrong thing, both flawlessly. Diversity of model does not buy diversity of understanding.

**Two short passes, reported separately, never merged into one verdict:**

- **Spec pass** — measured against `acceptance_criteria`: what is missing, what was added that nobody asked for, what was implemented incorrectly. Quote the criterion.
- **Standards pass** — does the diff violate written conventions? Cite the source. Skip anything a linter enforces.

Kept apart because a change can satisfy every convention and still do the wrong thing. Merged, a clean bill on one axis hides a failure on the other.

**Keep the prompt short.** A 2026 study of requirement-conformance judgement found LLM reviewers systematically overcorrect, and that prompts demanding detailed explanations *raised* the misjudgement rate. Ask for findings, not essays.

**The binding rule:** may add reasons to reject; may never be the reason to merge.

**Review is never delegated to `EXEC_LOCAL`.** See §17.1 — low correlation times low capability is not a useful reviewer.

**Review is never performed by a model from the executor's vendor.** Enforced by `forbidden_models` (§7.1) and by refusing auto-merge in state C′ (§7.5).

---

## 11. The vault — procedural memory

Path: `C:\Users\dorot\Documents\Obsidian Vaults\Antigravity\`. Its canonical rulebook is `AI-SHARED.md`, which governs vault reads and writes and wins any conflict about them. This blueprint governs orchestration and defers to it on vault matters.

**It is not Drive-synced, and that is deliberate.** The vault was previously on Google Drive. Evidence that this was harmful is in the vault itself: `_lock (1).md`, `_suggestions (1).md`, `AGENTS (1).md` are Drive conflicted copies. `hermes-codex-harness` reaches the same conclusion independently — *"Runtime state and SQLite files must stay on local NTFS, outside cloud-synchronized folders."*

10.1 described this vault as living at `~/Documents/obsidian vault` with a `00-core/10-projects/20-study/30-procedures` layout. Neither existed. The real structure is `00_Memo/ 01_Inbox/ 04_Memory/ global/ projects/ ai-memory/`, and it is what this section now uses.

### 11.1 What the vault is for

The crystallization principle is sound: agents handle uncertainty and exploration; once a behavior is understood and repeatable, stop paying to rediscover it. The question is *where* the frozen version goes, and for you the standard answer is wrong. A shell script is deterministic but unreadable to you — a permanent, invisible liability if it encodes something wrong. **A markdown procedure is readable, versionable, and reviewable in your own language.**

It is supported: distilling agent trajectories into written stepwise procedures measurably raises success rates and reduces steps on similar tasks.

**But be precise about what it is not.** A markdown procedure is an *instruction*, interpreted probabilistically. It never reaches the certainty of a hook or a CI check, and compliance degrades with length and context.

> **Deterministic code for anything that must hold every time. Markdown for anything you must understand.**

Never put a safety gate in a vault note. This is also why the reusable core left the vault (§6.1).

### 11.2 Backup, and what must never be committed

The vault is a git repository pushed to a **private** GitHub repository. Git supplies what Drive cannot: readable diffs, atomic commits, history, and drift detection — the recovery mechanism §19 depends on, which before 10.2 did not exist in any form.

**Not everything goes.** The vault contains 118 PDFs of a paid commercial course and 112 MB of third-party material. A private repository is not publication, but it is upload, and binaries have no diff value and cannot be removed later without rewriting history (§9.7 forbids that).

```gitignore
# never versioned — third-party paid course material
projects/Projeto Magistratura/

# belts, all projects
*.pdf
**/raw/
**/wiki/sources/
markitdown-output/
```

`raw/` is excluded on principle, not convenience: `AI-SHARED.md` defines it as the human-only immutable primary-source zone, which makes it the folder most likely to hold material that is not yours.

| Content | Backup | Why |
|---|---|---|
| Vault markdown minus the exclusions | private GitHub repo, git history | readable diffs, drift detection, recovery |
| `projects/Projeto Magistratura/`, all `raw/`, all PDFs | Drive plain file copy | binaries and third-party material; no history value, and no `.git` to corrupt |
| `director-core` | public GitHub repo | §9.1 — infrastructure only |

Drive keeps exactly the role it is good at: plain file copies of binaries. The objection to Drive was never Drive; it was Drive plus git.

### 11.3 Rules

1. **Agents read freely; agents write only to `01_Inbox/`.** Enforced by a PreToolUse hook on Write and Edit. `ai-memory/` is read-only to everyone but the Claude memory system itself; `raw/` is human-only.
2. **The vault is a git repository.** Every agent write is committed with a plain-English message. This is the only way you will notice a procedure silently drifting — and agent-maintained knowledge does drift: once an incorrect entry is stored it persists and propagates, and nothing distinguishes a validated note from a speculative one.
3. **You promote from `01_Inbox/` yourself.** An agent proposes; you read it — plain language — and move it to `04_Memory/` or a project wiki if right. This is the audit step frozen code denies you.
4. **Connect by plain filesystem access, not an MCP server.** Less context cost, no third-party dependency, less security surface.
5. **Keep resident procedures short; retrieve long ones on demand.**

### 11.4 The crystallization ladder

When you notice you are explaining the same thing again, climb one rung — not to the top.

| Rung | Form | Where | Determinism | Can you audit it? |
|---|---|---|---|---|
| 1 | Procedure note | vault `04_Memory/` | probabilistic | **yes** — plain language |
| 2 | Slash command (a named prompt) | skills | probabilistic | **yes** — you read the prompt |
| 3 | Line in `AGENTS.md` | `director-core` | probabilistic | **yes** — but costs every session; keep short |
| 4 | Hook or CI check | `director-core` | **deterministic** | no — compensate with a plain-English note describing what it enforces |

**Promote only when:** the behavior has recurred **at least three times**, the procedure came out the **same way each time**, and you can state what "working" looks like. Below three you are freezing a pattern whose shape you have not seen.

**Demote when it breaks.** A frozen procedure that fails silently is worse than none.

**Prune quarterly.** List every note, command, and script with its last-used date; delete the dead. Accumulated automation nobody uses and nobody can read is the failure mode most likely to sink this over a year. Reassess §20's simplify question at the same time.

---

## 12. Anti-complacency

Automating the gate creates a new risk, and the research is unambiguous: humans supervising reliable automation get worse at detecting its failures. It affects experts and novices alike, is worst when the automation is *highly* reliable, and cannot be trained away by practice.

**Not optional. Without it, §9.4 makes the system worse rather than better.**

**The spot-check is an intent audit, not a code review.** This must be stated in `AGENTS.md` in exactly those terms, because a spot-check framed as "review the diff" is one you cannot perform and will therefore stop performing.

Auto-merge only ever touches green-path changes, whose claim — "everything that worked still works" — the test suite verifies better than any reading could. So the human is not checking the implementation. The human is checking **one thing: whether `change_class` was right.** If the orchestrator mislabels a behavior change as green-path, auto-merge fires and §9.5 — your only real layer — never happens. That is the entire failure mode auto-merge introduces, and detecting it needs §9.6's shape questions, not code literacy.

1. **Spot-check auto-merged changes.** Every one for the first month; roughly one in five after. *There is no established optimal sampling rate in the literature — this is a sustainable number, not an evidence-based one.* One question per sampled PR: **should this have been `behavior`?**
2. **A census is worse than a sample.** Checking every green-path PR trains you to click approve on checks you cannot meaningfully perform, and that habit carries into behavior changes, where it costs you. Sampling keeps each check live.
3. **Run the quarterly defect drill.** Have the agent introduce a deliberate, realistic bug on a scratch branch and open a PR. Confirm the gates catch it. Needs no code reading — plant, observe red, revert. Experiencing automation failure measurably reduces complacency.
4. **Keep units small.** The single most reliable lever on review quality.
5. **A failed check hard-blocks.** The active ingredient in every checklist that ever worked was not the paper. It was empowering someone to stop the line. Your equivalent is CI: a failed check blocks mechanically, never by the agent choosing to comply.

**One mechanical safety net worth knowing:** §9.4 condition 4 blocks the worst misclassification by path, not by your attention. An enforcement-layer change can never be green-path no matter what the orchestrator labels it.

---

## 13. Decisions, diagnosis, and measurement

### 13.1 The four decisions

- **PROMOTE** — criteria met, tests pass, scope respected. The orchestrator pushes the branch, opens the PR, and recommends merging. **The orchestrator never merges.**
- **FOCUSED_CORRECTION** — specific defect, same route still right. **One only, per diagnosis.**
- **ESCALATE** — a stronger route is justified, on a fresh diagnosis naming the specific capability delta. "Use a smarter model" is not a diagnosis.
- **REJECT** — unsafe, out of scope, or cheaper to redo than repair.

**Mandatory stop:** whenever authentication source, model identity, or no-overage status cannot be verified, publish a handoff and stop.

**A fresh diagnosis** is a reproduction you can run on demand plus a ranked hypothesis with a falsifiable prediction. Build the failing check *first* — no further step begins until it exists.

### 13.2 The failure-attribution test

Either the executor failed to find an implementation the criteria would have accepted — a **search** failure — or the criteria were wrong, so nothing would have been accepted — an **objective** failure. Escalating fixes the first and is pure waste on the second.

**Three questions, in order:**

1. **Can you state what "working" looks like as one observable outcome?** If not, the criterion was never testable. **Objective failure. REJECT and re-slice.**
2. **Does `behavior_check` distinguish success from the current broken state?** Run it on the failing branch: it should fail. If it passes on broken code, the yardstick measures the wrong thing. **Objective failure. REJECT and re-slice.**
3. **Only if 1 and 2 hold:** search failure. One correction. If it fails again on the same diagnosis, ESCALATE — with a written capability delta naming what the stronger route does that the weaker could not. If that sentence cannot be written, it was never a search failure; return to question 1.

**Questions 1 and 2 fail far more often than 3.** A unit that failed twice is usually cut wrong, not under-powered. `EXEC_STRONG` may go unused for long stretches — the correct outcome, not a defect. Note that under §7.4 it now has a second job as the state-C executor, so it is less likely to be dead weight than in 10.1.

### 13.3 Measurement

**The satisficing thresholds are the measurement. There is no optimizing metric.**

| Threshold | Bar |
|---|---|
| Metered spend | exactly $0 |
| Behavior changes merged without you running the check | 0 |
| Enforcement-layer diffs merged unread | 0 |
| Auto-merged changes in the spot-check sample | reviewed |
| Third-party material committed to any repository | 0 |

These are binary, cost nothing to check, and are the rules that actually protect you.

**10.1 also demanded a weekly count of merged work units. Dropped.** §13.3's own rule forbids adding machinery for a failure that has not occurred twice, and a weekly self-measurement is machinery. Its only consumer is §20's "when it stops improving, simplify" — a decision months away. A ritual sustained by a solo operator against a pipeline that mostly works is the likeliest thing here to lapse silently, and a lapsed metric reads as a fresh one.

**The baseline, taken retrospectively.** 10.1 insisted a baseline week could only be recorded before the machinery existed. Half true — the throughput data was already on disk:

| Repo | commits | span |
|---|---|---|
| `Finance dashboard` | 15 | week 29, from 2026-07-18 |
| `Mega-brain Project` | 8 | week 29, from 2026-07-14 |
| `hermes-autoresearch` | 7 | week 30, from 2026-07-21 |

**Baseline: roughly 10–15 commits per week of directly-driven work.** The caveat is explicit and permanent: these are *commits*, not *merged units*, because none of that work passed through a pull request. It is comparable in magnitude, not in kind. Reassess at the quarterly prune (§11.4), not weekly.

**The failure log.** `.director/failures.md` — one line per failed unit: date, unit id, which question of §13.2 it failed, one sentence. It exists to make one rule enforceable:

> **Nothing may be added — no rule, script, hook, note, route, or section — for a failure mode that has not occurred at least twice in the log.**

Before investing in a fix, estimate its ceiling. If a category is 5% of failures, eliminating it perfectly buys 5%. Most proposed machinery targets categories at 0%. This rule deleted ten thousand words from an earlier revision and is what keeps this one from growing back. **It is also the rule that keeps `EXEC_LOCAL` out until capacity actually binds.**

---

## 14. No-overage controls

Absolute: **paid overage remains zero. OAuth or subscription auth only; no API key, ever.**

| Layer | Control | Verification |
|---|---|---|
| Anthropic | no `ANTHROPIC_API_KEY` in the environment | **verified 2026-07-25: no `*_API_KEY` set.** Hook blocks any command carrying one |
| OpenAI | no `CODEX_API_KEY` / `OPENAI_API_KEY` | **verified: `codex login status` → "Logged in using ChatGPT"** |
| Google | no Gemini API key | **verified: agy authenticates against Google AI Pro** |
| Local | no cloud credential in the local runner | `EXEC_LOCAL` is local inference only; if it ever needs a key, it is not this route |
| GitHub | free plan; `director-core` public, content repos private | rulesets, push protection, Actions all included at $0 |
| GitHub | Actions spending limit $0 | public-repo Actions on standard runners are unmetered anyway |
| Vendor credits | credit / auto-top-up settings | **you must confirm these in account settings.** Prior revisions asserted specific behaviours here that could not be verified; they are not repeated |

`preflight` checks every row it can check mechanically and refuses to launch if one fails, **and refuses on an unresolved or stale registry** (§7.2).

**One future exemption, recorded now so it is not improvised later.** When `EXEC_LOCAL` activates, LM Studio's local endpoint conventionally takes a dummy `OPENAI_API_KEY=lm-studio`. The metered-credential hook would block your own local route. The fix is a narrow exemption for localhost endpoints, written when the route activates and not before.

---

## 15. Enforcement

**Three tiers: GitHub (server-side) > hooks (local, deterministic) > instructions (probabilistic).** Put every rule at the highest tier that can hold it.

**And one boundary condition 10.1 missed: hooks do not cross a process boundary.** A `PreToolUse` hook constrains the process it is installed in. It cannot see inside a subprocess. Any invariant you need to hold for the executor is enforced by removing the executor's capability (§8.3), by a GitHub ruleset, or not at all.

### 15.1 Hooks

A PreToolUse hook exiting with code 2 denies the tool call.

| Invariant | Hook | Behaviour |
|---|---|---|
| No writes outside the active worktree | PreToolUse on Write/Edit | exit 2 on out-of-scope path |
| Vault writable only at `01_Inbox/` | PreToolUse on Write/Edit | exit 2 on any other vault path |
| No force-push, no hard reset | PreToolUse on Bash | exit 2 on `push --force`, `reset --hard` |
| No push to `main` | PreToolUse on Bash | exit 2 — belt to GitHub's braces |
| No merging | PreToolUse on Bash | exit 2 on `gh pr merge` **without `--auto`** |
| No reading secrets | PreToolUse on Read | exit 2 on `.env*`, `secrets/**` |
| No metered credentials | PreToolUse on Bash | exit 2 if the command passes `*_API_KEY` |
| No unauthorised executor or model | PreToolUse on Bash | exit 2 unless the binary appears in `routes.yaml`; exit 2 on any `forbidden_models` match |
| Every agent call is time-bounded | PreToolUse on Bash | exit 2 if a headless invocation carries no `timeout`, or if an inner timeout is shorter than the outer one |
| No cycle ends without a handoff | Stop | exit 2 if the handoff is missing or fails schema validation |

**The `--auto` carve-out is not cosmetic.** 10.1's hook blocked `gh pr merge` outright, and GitHub auto-merge is armed with `gh pr merge --auto`. As written, §15.1 blocked §9.4. Two sections of the same document cancelled each other.

**Declared weakness.** These hooks match on command text, and text can be rewritten — the published reference implementation of the git rows is bypassable with `git -C <dir> push`, which never contains the string it looks for. Hooks are a barrier against a confused agent, not a determined one. **The GitHub ruleset is what actually stops a push to `main`.**

**Verify before trusting:**

```bash
echo '{"tool_input":{"command":"git push origin main"}}' \
  | .claude/hooks/block-dangerous-git.sh; echo "exit=$?"
```

Expect a block and `exit=2`. Repeat with `git push -u origin task/demo` — expect `0`. Then `git -C . push origin main` — watch it return `0`, the bypass above. Three commands, three visible results, no code reading.

### 15.2 Scripts — three, and only three

- **`preflight`** — no-overage controls, route authorisation, registry validity and freshness. Green/red checklist. **Refuses to launch on an unresolved or stale registry.**
- **`worktree`** — creates and destroys the worktree and branch, records the base commit, holds an exclusive lock so a second concurrent creation fails loudly rather than racing.
- **`validate-result`** — checks the result JSON against the schema, compares the uncommitted working-tree files with the unit's permitted paths, re-runs required tests independently, preserves raw output.

**`flock` does not exist on this machine.** Use a lock *directory* instead — `mkdir` is atomic on every filesystem and fails if the directory exists:

```bash
lock=".director/worktree.lock"
mkdir "$lock" 2>/dev/null || { echo "another unit holds the worktree lock"; exit 1; }
trap 'rmdir "$lock"' EXIT
```

**If a proposed addition can be expressed as a GitHub rule, a CI step, a hook, or a registry entry, it must not be written as a script.**

---

## 16. The cycle

```bash
# 1. New unit → new worktree on a new branch (orchestrator, holding the lock)
git worktree add -b task/<unit-id> ../director-core-<unit-id> main
cd ../director-core-<unit-id>
git commit --allow-empty -m "checkpoint before <unit-id>"   # recovery point

# 2. Executor works here — jailed (§21.8), always time-bounded, always the
#    route in the packet, inner timeout >= outer bound.
#    This shows EXEC_STRONG because it is the only route that executes headlessly
#    without a permission-bypass flag. EXEC_PRIMARY has NO working invocation
#    (§7.5) — do not substitute agy here expecting it to work.
timeout 900 bash scripts/exec-jail.sh codex exec --sandbox workspace-write   --json --output-schema schemas/result.schema.json "<packet>"

# 3. Validate before anything leaves the machine
bash scripts/validate-result.sh

# 4. Orchestrator runs the adversarial review (§10)

# 5. ORCHESTRATOR pushes the branch — never the executor, never main
git push -u origin task/<unit-id>

# 6. ORCHESTRATOR opens the PR; behavior_check goes in the body, verbatim
gh pr create --base main --head task/<unit-id> --title "..." --body "..."

# 7a. green-path + all checks green → gh pr merge --auto --squash
# 7b. behavior change → YOU run behavior_check, read the summary, merge

# 8. Clean up
cd ../director-core && git pull
git worktree remove ../director-core-<unit-id>
```

**Note step 2's timeouts.** agy's `--print-timeout` defaults to 5 minutes. Left unset inside a `timeout 900`, the inner bound fires first and the outer one is decorative. The hook in §15.1 checks for this.

**Staleness.** A PR older than its base by more than a handful of merges is stale. Rebase, re-run, re-read — or close it and re-cut the unit. A second open PR usually means a worktree was orphaned, not that work is proceeding in parallel.

---

## 17. Deliberately rejected, and conditionally deferred

**One writer at a time. Readers unlimited.**

10.1 forbade parallel agents outright. Its evidence supports only half of that. Two agents writing one file lose work silently — you confirmed this, and a stress test produced physically interleaved output. That is a fact about **writers**. Readers cannot lose a byte: `Explore`, research agents, reviewers, and any delegation that returns a digest touch nothing. 10.1 forbade them by wording rather than by evidence, at real cost to a solo operator whose main speed lever is parallel reading.

So:

- **One writer at a time**, enforced by `worktree`'s lock (§15.2) — tier 2, not prose.
- **Readers parallel and unlimited.**
- **Delegation runs inside the worktree, holding the lock.** This makes the operator's standing "delegate bulk work without asking" rule and the enforcement layer agree instead of contradict.
- **One open pull request at a time** is a separate, weaker staleness rule (§16), not a concurrency rule.
- **Never run a second orchestrator over the same repository.** Swarm-style orchestration and the Director are two orchestrators; they may each own projects, never the same one.

**Graph orchestration / DAG agent workflows.** These help when many heterogeneous tasks run at once. You run one writer at a time, by design. **Not adopted.**

**Merge queues.** Not available on a personal public repository.

**MCP servers for the vault.** Plain filesystem access does the job with less context cost and less surface.

**Auto-merge on stranger PRs.** Never, under any configuration.

**Executor-side push and PR creation.** Rejected in 10.2 — see §8.3. This is the change with the largest safety effect in this revision.

### 17.1 `EXEC_LOCAL` — conditional, and deferred by default

**What it is.** `gemma-4-12b-agentic-fable5-composer2.5-v2-3.5x-tau2`, Q4_K_M, 7.38 GB, in LM Studio. No metered cost, no cap, no vendor window — it consumes your machine instead of your subscription.

**The genuine argument for it.** Your binding constraint is capacity, not money. And it is **architecturally distant** from every cloud route — different lab, different training, different scale — which means less correlated failure, the scarce property in §2.

**The arguments against, which currently win:**

- **Capability.** Low correlation times low capability is not a useful reviewer, and §10's overcorrection finding bites hardest on weaker reviewers. **It is never Layer 2.**
- **It cannot orchestrate.** The five conformance scenarios demand identical decisions across platforms. This rules the route out of `ORCH_*` permanently. (Executors do not decide, so the requirement does not bind them.)
- **Its harness is not operational.** `hermes-codex-harness` is explicit: *"Only Phase 0 — evidence, compatibility, and safe substrate is authorized. Aux is disabled. OmniRoute is not an operational dependency."* Nothing drives gemma as an executor today.
- **§13.3 forbids it.** The failure log is empty, capacity has never bound, and the pipeline has never run.

**Therefore: `state: absent` in every project's registry until all four of the following hold.**

1. **The capability test passes.** Two minutes: ask it to run `git status` in a folder and report the output. *Cannot run shell* → it is a chat model, not an executor. *Shell only* → usable inside a worktree, which under §8.3 is now the **only** thing any executor needs, since the orchestrator owns push and PR. That is a lower bar than 10.1 set, and deliberately so.
2. **Its harness is operational** past its own Phase 0.
3. **Capacity has actually bound.** You have hit a cap and it cost you work. Curiosity is not the trigger; a recorded failure is.
4. **Phase 4 is complete.** The pipeline works end to end with known-good executors first.

**When admitted, it enters as `state: candidate`** with these constraints:

- at most 3 files in its permitted paths;
- at least one required test per acceptance criterion;
- forbidden to create files not named in the packet;
- forbidden to change dependencies, configuration, or refactor untouched code;
- **never auto-merges** (§9.4 condition 6);
- **never Layer 2.**

Promotion to `active` requires ten units merged with no correction attributable to the route. Demotion on the first silent failure.

**Recorded as a decision, not an omission.** Rev 10.0 dropped this route without a verdict. That was the bug §17.1 exists to fix, which is why the stub stays in `routes.yaml` even at `state: absent`.

---

## 18. Implementation sequence

Each phase ends with something you can personally verify. Do not begin a phase until the previous check passes.

**Phase −1 — prerequisites and project setup.**

Five things that block Phase 0 and are not in any earlier revision:

1. **`gh auth refresh -h github.com -s workflow`.** Your token's scopes are `gist, read:org, repo`. Without `workflow`, GitHub **refuses** to accept a push that creates or updates `.github/workflows/gate.yml`. Phase 0 writes exactly that file.
2. **Delete `C:\Users\dorot\Documents\AI Projects\.git`** — an empty directory, 0 items, which makes git report the workspace as a repository on branch `HEAD` and will confuse every worktree command.
3. **Set `allow_auto_merge: true`** on the repository (defaults to `false`).
4. **`hermes-codex-harness` reports `dubious ownership`** and git refuses to read it. Unrelated to the Director, but it will block any git operation there.
5. **Migrate the vault** (§11.2): mirror Drive → local, verify, `git init`, first commit with the exclusions in place, push private, then delete the Drive vault. **In that order** — the Drive copy is currently the only complete one.

Then, per project: copy the core from `director-core`. Run the routing interview (§7.2). **Decide visibility (§9.1) and record the reason in the README.** Set `EXEC_LOCAL` to `state: absent` unless §17.1's four conditions hold.

*Verify:* `preflight` runs and passes. Blank one `model:` field and confirm it refuses.

**Phase 0 — safety rails.**
Set every control in §14. Create `director-core` as a **public** repository. Write `.gitignore` before the first commit. Configure per §9.2. Write `preflight` and the CI gate.
*Verify:* `preflight` green, exit 0. Break one control deliberately (`export OPENAI_API_KEY=fake`) and run again: it must fail, non-zero. From a clean clone, try `git push` directly to `main` — it must be rejected. If it succeeds, the bypass list is not empty. Stop and fix.

**Phase 1 — minimum orchestrator.**
`AGENTS.md` · one-line `CLAUDE.md` · `routes.yaml` · three scripts · the hooks in §15.1 · handoff schema · `EXEC_PRIMARY` only. Disable the ambient style plugins in this repository (§8.1).
*Verify:* ask the orchestrator to edit a file outside the worktree — blocked. To write to the vault outside `01_Inbox/` — blocked. To run `gh pr merge` — blocked. To run `gh pr merge --auto` — **allowed**. To end a cycle without a handoff — blocked. Then run the §15.1 bypass demonstration and watch a hook fail to block, so you know exactly what it is worth. Then the ten-minute swap drill.

**Phase 2 — delegation round trip.**
Wire agy with its restricted mode, JSON output, a schema, and an outer `timeout`. Confirm the jail removes reachable `gh` credentials; do not infer that its sandbox controls egress, credentials, or paths.
*Verify:* run one real bounded task end to end as a **behavior change**. Confirm by hand: the worktree existed; the **orchestrator** reviewed, staged, committed, pushed the branch, and opened the PR; **the executor's gate access is absent rather than merely unused** — probe it, do not infer it (§8.3 correction, §21.8); egress remains recorded and tested as open; the evidence directory holds real test output rather than prose; `validate-result` rejects a deliberately corrupted result file. Run the behavior check yourself, read the adversarial review, merge.

**Phase 3 — auto-merge, in `Finance dashboard`.**
**Not in `director-core`.** §9.4 condition 4 makes almost every file there non-green-path, so the only units available would be documentation edits — a thin test of a real gate. Apply Phase −1 to `Finance dashboard` (private), then run at least three green-path units through.
*Verify:* open a PR violating each CI check in turn and watch the gate go red. Confirm auto-merge does **not** fire on a PR touching `.github/**`. Spot-check every auto-merged change this month, asking only §12's one question.

**Phase 4 — fallback and conformance, in `director-core`.**
Build the five conformance scenarios: executor reports success with an uncommitted reviewed diff → ACCEPT · file changed outside permitted paths → REJECT · required test skipped with no blocker → REJECT · second failure with the attribution test blaming the criteria → REJECT and re-slice · **the executor jail cannot reach `gh` credentials — verify the capability is absent rather than the instruction obeyed.** As of 2026-07-26 this scenario PASSES for the gate when the executor is invoked through `scripts/exec-jail.sh` (§21.8): `gh api user` is refused and push cannot authenticate, probed live. It still FAILS for egress — DNS resolves — which needs §21.9's account isolation.
*Verify:* mid-task, publish a handoff and open the fallback orchestrator cold. It must reconstruct objective, decisions, repository state, and next action without the prior conversation. If it asks something the handoff already answers, the handoff is incomplete. Then run all five scenarios on both orchestrators; decisions must match. Where they diverge, tighten `AGENTS.md` and re-run both — never add a platform-specific patch.
**Re-run conformance when `ORCH_*` changes. Do not re-run it when `EXEC_*` changes** — executors do not decide, so swapping one cannot threaten decision consistency. This is what makes per-project executor rotation nearly free.

**Phase 5 — the vault, once there is something to remember.**
Populate `04_Memory/` only with procedures that have already recurred three times.

**Phase 6 — `EXEC_LOCAL`, only if §17.1's four conditions hold.**

---

## 19. Known weaknesses and residual risk

**Verified, and therefore no longer risks:** the agy route works · no metered credential is present in the environment · all three cloud routes are subscription-authenticated · `codex exec` supports schema-constrained output and sandboxing · rulesets are reachable on a free public repository · the vault path and structure are real.

**Still true:**

- **Roughly one defect in seven survives this pipeline**, concentrated in specification and logic errors — code that is correct, tested, reviewed, and does the wrong thing. **The mitigation is not more review. It is smaller units and observable acceptance criteria.**
- **Layer 2 is correlated with the executor.** Cross-vendor reduces it; shared specification error defeats it entirely.
- **Command-matching hooks are bypassable**, and they do not cross a process boundary at all. The GitHub ruleset and the executor's removed network are the real barriers.
- **A fine-grained token cannot be scoped to exclude `main`.**
- **Anything committed to a public repository is public permanently**, and §9.1 is a decision you make repeatedly, which means it is one you can get wrong repeatedly.
- **A private repository is still an upload.** §11.2's exclusions depend on you not adding third-party material later. Nothing enforces that mechanically.
- **Two agents writing one file lose work silently.** The worktree lock prevents two units starting at once; nothing prevents two writers inside one unit.
- **A vault procedure is an instruction, not a guarantee.**
- **The instruction tier is weaker than any earlier revision assumed** (§8.1). Every rule not backed by a hook, a CI step, or a GitHub ruleset should be read as a hope.
- **Automation complacency will degrade your attention** as the pipeline becomes reliable. §12 works only if you run the drill.
- **Non-expert supervision of automation is genuinely under-studied.** The least-grounded assumption in this document, and it is load-bearing.
- **Per-project routing is untested.** The interview could become a ritual you click through — which would make the registry stale in a way `last_verified` cannot detect, because the date would be fresh and the judgment behind it empty.
- **New in 10.2, and the one to watch:** the executor's lack of network shifts work to the orchestrator, which is the scarcest budget (Claude Pro pools with your daily claude.ai use). If orchestration windows become the bottleneck, that is the trade this revision made, and the honest response is smaller units — not restoring the executor's network.

---

## 20. Final decision

**The orchestrator decides, reviews, pushes, and opens the pull request.** Its hook layer supplies deterministic enforcement that would otherwise be bespoke, unauditable code — and it is the only process those hooks can constrain, which is why it owns everything that touches the gate.

**A delegated executor implements inside a worktree.** The jail removes gate credentials; egress remains open until the operator-level isolation exists. Which executor is used is a per-project decision recorded in a registry, never a fact in this document.

**GitHub provides the gate.** One unit, one worktree, one branch, one pull request. Green-path changes merge on green checks. Behavior changes wait for you to watch them work.

**Models are configuration, not architecture.** Nothing outside `routes.yaml` names a model. When a new one ships, edit one line and run the swap drill. Rev 10.1 is the standing warning against doing otherwise: it recorded a working route as broken, from recall, and deleted it. Query the CLI.

**The vault holds what you have already decided**, in language you can read, with git history so you can see it drift. The reusable core lives in a repository, because code that must hold every time belongs where CI can check it.

**And the honest summary:** three imperfect layers that fail differently, stacked so most defects hit at least one, with a residual you cannot eliminate and should not pretend away. The layers work because they differ *in kind* — a machine that executes, a model from another vendor, and a human who knows what he wanted. **Adding a fourth layer of the same kind as an existing one adds cost and almost no safety.**

**And one lesson 10.2 paid for:** a layer you cannot enforce is not a layer. Five of 10.1's ten invariants were decoration because a hook cannot see inside a subprocess. The fix was not more machinery — it was taking a capability away.

**It must keep justifying itself against the simplest thing that works.** When the satisficing thresholds hold but the work feels slower than the 10–15 commits per week you managed without any of this, simplify: route the work directly and delete a layer.

---

## 21. Token Accounting and Workflow Efficiency Plane

Added after 10.2. Answers one question with evidence instead of intuition: **which workflow is cheapest per validated successful work unit** — not per attempt, and not per token.

### 21.1 The principle

> Collect telemetry continuously **outside** the Director's context, aggregate it deterministically, and expose only a compact scorecard at routing boundaries.

The Director must never read the raw ledger. Doing so would spend the budget being measured and contaminate the measurement. It must also never estimate its own usage by reasoning about it — when harness telemetry exists, recall is the worst available source.

```
instrumentation → append-only ledger → deterministic reducer → scorecard → advisory routing
```

### 21.2 What is authoritative, and what is not

The distinction is load-bearing. Confusing the two makes every downstream number a guess wearing a suit.

| Source | Status | Notes |
|---|---|---|
| Claude Code session JSONL | **authoritative** | `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, model, timestamps |
| codex rollout JSONL | **authoritative** | adds `reasoning_output_tokens`, `time_to_first_token_ms`, `model_context_window`, and live quota (`used_percent`, `resets_at`, `credits`) |
| agy | **unavailable** | exposes nothing on disk. Its adapter records nulls with `telemetry_authoritative: false`. It does not guess |
| preflight estimate | **estimate only** | no tokenizer exists here. `authoritative` is hardcoded false |
| every derived metric | **derived** | labelled as such |

**`estimated_cost` is null everywhere.** The operator is on subscriptions, so quota is the currency and invented dollar figures would be worse than no figure. Accounting mode is `subscription_quota`.

### 21.3 Counting correctly

codex reports both a cumulative counter and a per-event delta, and **it can emit the same event twice** — observed nine seconds apart with the cumulative unchanged. Summing the deltas naively inflated a real 119-event session by 1.59%.

Deltas are therefore **forward differences of the cumulative counter**, which makes a duplicate a zero delta by construction rather than by detection. A decrease means a fork or resume: clamp to zero and rebaseline.

> A correction that works by construction beats one that works by recognising the case you happened to think of.

### 21.4 Comparison is scoped, or it is meaningless

Metrics group strictly by `task_class`, `complexity_band`, `validation_standard`, `route_id`, `execution_mode`. Unrelated work is never compared.

The optimizing metric is **`tokens_per_validated_success`**: all tokens across all attempts, divided by validated successes. Retries count. Failures never count as successes.

This is the whole point, and the seeded demonstration exists to show it:

| | tokens/attempt | retry rate | **tokens/validated success** |
|---|---|---|---|
| Route A | 1,000 | 75% | 1,944 |
| Route B | 1,500 | 5% | **1,658** |

Route A is 33% cheaper per attempt and worse per outcome. Per-attempt cost is the misleading number.

### 21.5 Advisory by default

`mode: advisory` in `.telemetry/routing-policy.yaml`. The optimizer computes and logs what it *would* choose and changes nothing. **Only a deliberate operator edit makes it `enforcing`.**

A route is ineligible below 10 completed runs or below 0.90 validated success rate. With no eligible route the answer is `null` plus a stated reason — never a guess.

Every advisory call appends a decision record. Recording the actual route afterwards **appends a linked event; it never mutates the original**, so the optimizer cannot rewrite its own history to look correct in hindsight. That disagreement log is the only thing that could ever justify enforcing mode.

The optimizer may change route, effort, batch vs interactive, parallel vs sequential, escalation timing, context size, retrieval scope. **It may never** remove required validation, skip a security review, skip a destructive-action confirmation, disable handoff generation, or lower a success threshold to make itself look better.

### 21.6 Preflight is an estimate, and says so

No token-counting API exists here — OAuth only, and §14 forbids introducing a metered key. So preflight uses a documented characters-per-token heuristic, labels everything `estimated_*`, reports confidence `low`, and emits `null` where it cannot compute rather than inventing a number.

It gets trustworthy through **calibration**: estimates are logged, then joined against authoritative post-invocation `input_tokens` by `work_unit_id`. Reconciliation suggests a correction factor, refuses below 10 matched pairs, and never auto-applies.

It **advises** remediation in order — trim history, trim tool definitions, prefer the handoff over full context, retrieve only required files, recount, then split the unit — but performs none of it. Splitting a work unit is a judgement call that belongs to the Director.

### 21.7 What it cannot do yet

- **Zero real completed runs.** Every honest answer today is "insufficient samples". The seeded comparison proves the mechanism, not any real route's superiority.
- **Each physical JSONL append is protected across threads and local processes.** `threading.Lock` serializes adapters within one interpreter, while an atomic lock directory beside the target JSONL serializes separate interpreter processes. Acquisition waits at most two seconds; a directory at least four seconds old is treated as abandoned, removed with a warning, and retried. A timeout fails loudly with the lock path rather than writing unlocked. This is not a transaction across the ledger and its separate hash index, and it is not a guarantee on network filesystems or for a live process paused longer than the stale-lock threshold.
- **agy contributes no usage data at all**, so any workflow routing through it is measured with a hole in it.

### 21.8 Executor gate containment — built and probed

**Closed 2026-07-26 for the gate. Still open for egress.** Naming the difference precisely is the point; the §8.3 correction exists because a previous version of this section did not.

`scripts/exec-jail.sh` wraps every executor invocation and removes the credentials that reach the gate:

| Variable | Effect |
|---|---|
| `GH_CONFIG_DIR` → empty dir | **the load-bearing one.** `gh` reads host credentials from there, so it is unauthenticated even though the operator's real keyring entry is untouched |
| `GIT_CONFIG_GLOBAL` / `_SYSTEM` → empty file | no credential helper is reachable |
| `GH_TOKEN`, `GITHUB_TOKEN` unset | no token fallback |
| `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never` | a credential prompt becomes an immediate failure rather than a hang |

Probed **inside a live jailed codex run**, not inferred:

| Probe | Unjailed | Jailed |
|---|---|---|
| `gh auth status` | `github.com` (authenticated) | `You are not logged into any GitHub hosts` |
| `gh api user` | live authenticated JSON | `please run gh auth login` |
| `git push --dry-run` | `* [new branch]` — would have pushed | cannot authenticate |
| `nslookup github.com` | resolves | **resolves — unchanged** |

**The control is the `invoke:` line in `routes.yaml`.** An executor called directly bypasses the jail entirely, which is why the wrapper is configuration rather than a habit.

**What remains open, stated plainly.** Egress. DNS resolves, public reads succeed — `git ls-remote` against a public repository needs no credentials at all. An executor can still fetch and could still exfiltrate. Closing that needs a dedicated non-admin account with a Windows Firewall outbound-block rule scoped to its **SID**, because per-image rules cannot work: the executor reaches the network through child processes (`git.exe`, `gh.exe`, `curl.exe`), each with its own firewall identity. That is an operating-system change and belongs to the operator, not to this repository.

A candidate account measured by the autoresearch session: `curl` fails to connect in 29 ms, `git ls-remote` in 73 ms, `gh auth status` reports no authentication. One caveat — a blanket outbound block also stops agy reaching Gemini, so a real agy unit needs the rule narrowed to GitHub's published ranges.

**Path enforcement stays with the orchestrator regardless.** `validate-result.sh` diffs the uncommitted working tree and rejects a scope violation; it fails *closed* when no scope is declared.

### 21.9 Executor isolation — the remaining operator task

§21.8 closed the gate. **Egress is still open**, and closing it needs a control at the operating-system layer, because everything weaker has been tried and observed to fail:

- **Prompt instruction** — tier 3. Observed insufficient for incidental writes such as a stray log, cache, or executor memory file; the orchestrator still verifies the actual diff.
- **Sandbox flags** — tool-specific, not a common isolation property. agy's restricted mode restricted neither network, credentials, nor paths; Codex workspace-write blocks `.git` writes but leaves egress and inherited credentials available.
- **Per-image firewall rules** — cannot work. The executor reaches the network through *child* processes (`git.exe`, `gh.exe`, `curl.exe`), each a separate image with its own firewall identity. Blocking `agy.exe` or `codex.exe` blocks nothing, and the `gh` keyring credential survives every such rule.

**The control that closes both holes at once:** run the executor as a dedicated non-admin Windows account, with a Windows Firewall outbound-block rule scoped to that account's **SID** — which covers every child process it spawns — and with no `gh` keyring entry and no credential-manager state for that account.

Measured by the autoresearch session on a candidate `hermes-exec` account: `curl` fails to connect in 29 ms, `git ls-remote` fails in 73 ms, `gh auth status` reports no authentication.

One caveat that matters: a blanket outbound block also stops agy reaching Gemini. For a real agy unit the rule must be narrowed to GitHub's published ranges rather than everything.

**Path enforcement stays with the orchestrator regardless.** The orchestrator diffs the working tree and rejects a scope violation — the review requirement in §8.3 survives intact.

### 21.10 The lesson this subsystem taught

Twice, a CI check was green **because it was not looking**: the shellcheck glob missed `scripts/telemetry/` entirely, then the model-name check omitted `*.py`. And the first ledger unit passed its own 5/5 self-check while being completely broken on real provider data — the fixtures and the implementation shared one misunderstanding, so the test could not see it.

> **Verify a gate's coverage, not just its logic.** A green check over an empty file set is indistinguishable from a green check over real files.
>
> **Anything that reads third-party data is validated against real files, never fixtures alone.**

---

## Appendix A — verified facts

**Verified on this machine, 2026-07-25.** Re-check anything older than 90 days.

**Toolchain:** `claude` 2.1.220 · `codex` 0.144.5, *"Logged in using ChatGPT"* · `agy` 1.1.7 · `gh` 2.96.0, authenticated as `Nercari` · git 2.54.0.windows.1 · bash 5.3.9 (Cygwin) · `jq`, `timeout`, `mktemp`, `realpath`, `sed`, `grep`, `awk` present · **`flock` absent** · `shellcheck` absent locally (CI runs it on `ubuntu-latest`) · Ollama and LM Studio installed.

**`agy` is not broken.** `timeout 45 agy -p "Reply with exactly: PONG" < /dev/null` → exit 0, stdout `PONG`, stderr empty. Rev 10.1 listed this route as Known-broken with empty stdout and hangs under non-TTY, and deleted it. **That was false.** `agy models` reports `gemini-3.6-flash-{high,medium,low}`, `gemini-3.5-flash-{high,medium,low}`, `gemini-3.1-pro-{high,low}`, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, `gpt-oss-120b-medium`. Flags include `--sandbox`, `--mode`, `--add-dir`, `--effort`, `--model`, `--print-timeout` (**default 5m**), `--dangerously-skip-permissions`. `AGENTS.md` is read from the workspace.

**`codex exec` supports** `--output-schema <FILE>`, `--json` (JSONL events), `-o/--output-last-message <FILE>`, `-s/--sandbox`, `-C/--cd`, `--skip-git-repo-check`, `-m/--model`, `-c key=value`.

**GitHub, on this account:** rulesets endpoint reachable on a free public repository · `allow_auto_merge` defaults to **`false`** · **token scopes are `gist, read:org, repo` — `workflow` is absent**, so a push creating `.github/workflows/*` will be refused until `gh auth refresh -s workflow` is run.

**Environment:** no `*_API_KEY` variable set. `C:\Users\dorot\Documents` shows no Drive-sync reparse point. `C:\Users\dorot\Documents\AI Projects\.git` is an **empty directory, 0 items**.

**The vault:** `C:\Users\dorot\Documents\Obsidian Vaults\Antigravity\`. Before migration it held 139 files against the Drive copy's 523 — a strict subset, **0 files unique to local**, and of 34 files present in both with differing content, **Drive was newer in all 34**. So the migration is a one-way mirror, not a merge. `projects/Projeto Magistratura/` holds 118 PDFs and 112.3 MB, with 50 of those PDFs inside `wiki/`, not only `raw/`. Drive **conflicted copies exist**: `_lock (1).md`, `_suggestions (1).md`, `AGENTS (1).md`.

**Local model:** `gemma-4-12b-agentic-fable5-composer2.5-v2-3.5x-tau2`, 12B, Q4_K_M, 7.38 GB, in LM Studio, alongside `google/gemma-4-12b-qat` and a nomic embedding model. Ollama separately holds `qwen2.5:7b`.

**Confirmed against primary documentation:** Claude Code reads `CLAUDE.md`, not `AGENTS.md`, with no fallback · `@AGENTS.md` import is a documented bridge · PreToolUse exit 2 denies a tool call · Codex defaults to `workspace-write` with network off and `.git` read-only · Codex CLI does not auto-create worktrees · rulesets and branch protection are free on public repos and unavailable on free private repos · you cannot approve your own PR · an empty bypass list makes rules apply to the owner · the Actions spending limit defaults to $0 and hard-stops · secret scanning and push protection are free and on by default for public repos · Actions minutes are unlimited on public repos with standard runners · fine-grained tokens cannot exclude a branch · required status checks work alongside zero approvals · `pull_request` runs fork PRs with a read-only token and no secrets while `pull_request_target` does not · auto-merge is available on free public repos · merge queues are organization-only · grep exits 1 on no match · GitHub refuses workflow-file pushes from tokens lacking `workflow` scope.

**Corrected from earlier revisions:** rev 10.1's Known-broken entry for `agy` is false · rev 10.1's vault path does not exist · rev 10.1's `00-core/` placement contradicted its own vault hook · rev 10.1's `gh pr merge` hook blocked its own auto-merge design · rev 10.1's `output_contract` required capabilities that bypass its own enforcement layer · `flock` is unavailable on this platform · `disable-model-invocation` does **not** keep a skill's description out of context · `disallowed-tools` is not a documented skill frontmatter field.

**Unverifiable — deliberately not relied upon:** vendor credit behaviour and auto-top-up re-enabling · Google AI Pro overage settings and refresh cadence · exact numeric Claude Pro, ChatGPT Plus, and Google AI Pro limits, which are not published.

---

## Appendix B — evidence base

The design decisions in §2, §9.4, §10, §11, and §12 rest on: Knight & Leveson (1986) on correlated failure in independently written implementations, and a 2026 replication with coding agents finding the overlap persists across model and harness diversity · Panickssery et al. (NeurIPS 2024) on LLM evaluators recognizing and favoring their own generations · a 2026 study in *Automated Software Engineering* finding systematic overcorrection in LLM requirement-conformance judgement, worsened by prompts demanding detailed explanations · Habib & Pradel (ASE 2018) finding 95.5% of 594 real bugs caught by no static analyzer · Gao, Bird & Barr (ICSE 2017) finding static typing would have caught ~15% of public JavaScript bugs · Capers Jones' defect-removal-efficiency benchmarks on the ~85–90% ceiling of testing without inspection · Parasuraman & Manzey (2010) on automation complacency in both naive and expert operators · Bainbridge (1983) on the ironies of automation · Pronovost et al. (NEJM 2006) and Haynes et al. (NEJM 2009) on checklists, whose active ingredient was enforcement · Liu et al. (TACL 2024) on lost-in-the-middle degradation · agentic instruction-following benchmarks showing sub-30% perfect compliance and a falloff past ~15 constraints · Memp (2025) on procedural memory raising success rates · DORA 2024–2025 on AI adoption raising throughput while reducing delivery stability · GitClear's 211-million-line analysis on rising duplication and churn · Ng, *Machine Learning Yearning*, chapters 8–14 and 44–45, for the error-analysis discipline and the optimization-verification structure §13.2 adapts.

Where sources are vendor-run benchmarks, single-vendor analyses, or non-peer-reviewed preprints, the body says so at the point of use.

**A note on this appendix.** Rev 10.2 did not re-verify any of these citations. They carry over from 10.1 unchanged and unaudited. Given that 10.1's *environment* claims were wrong at a rate of roughly one in three when finally checked, these should be treated as the least-verified content in the document — cited honestly, but not independently confirmed.
