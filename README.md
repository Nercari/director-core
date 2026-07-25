# director-core

The reusable core of the Director orchestration workflow. Copied into every project at setup.

The full design, its reasoning, and its verified environment facts live in **[`docs/blueprint.md`](docs/blueprint.md)** (revision 10.2).

## What lives here

| Artefact | Purpose |
|---|---|
| `AGENTS.md` | Director rules — the single canonical source, read natively by Codex and Antigravity |
| `CLAUDE.md` | One line: `@AGENTS.md`. A bridge for Claude Code, which does not read `AGENTS.md` |
| `scripts/` | `preflight`, `worktree`, `validate-result` — three, and only three |
| `.claude/hooks/` | The ten deterministic invariants (§15.1) |
| `.github/workflows/gate.yml` | The credential-free CI gate |
| `schemas/` | Work-unit and result contracts |
| `docs/blueprint.md` | This system's specification |

When a core artefact improves, it improves **here**, and the next project inherits it. Existing projects do not auto-update — they are independent repositories, and a silent retroactive change to a hook is exactly the class of invisible change this system exists to surface.

## Why this repository is public

Required by §9.1 of the blueprint: the visibility decision and its reason must be recorded, because it is the one decision in the system that cannot be undone.

**This repository is public**, and the justification is narrow and specific: it holds orchestration infrastructure and nothing else — rules, hooks, scripts, schemas, a CI workflow, and the blueprint. No content, no notes, no study material, no client data.

On a free plan, that choice buys enforcement that is otherwise unavailable:

| | Free public | Free private |
|---|---|---|
| Rulesets / branch protection | **yes** | no |
| Secret push protection | **yes, on by default** | no |
| Actions minutes | unlimited | 2,000/mo |

On the specific axis of *"stop me from committing a key,"* a free public repository is the strongest of the available options. Since the operator cannot read code, mechanical enforcement is worth more here than privacy is.

**That justification does not transfer.** Any project holding actual content is private by default, and anything committed to a public repository is public permanently — `git revert` cancels an effect, it does not erase history. Every project makes this decision fresh, before its first commit, and records the reason in its own README.

Commits here use a GitHub noreply address deliberately: an email in public history cannot be removed without rewriting it, which §9.7 forbids.

## Status

Pre-Phase 0. Only the blueprint exists. See §18 for the implementation sequence and its prerequisites.
