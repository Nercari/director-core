# 0001 — How an executor process comes to run as the restricted account

Status: accepted, 2026-08-15. Supersedes nothing.
Context: issue [#59](https://github.com/Nercari/director-core/issues/59), criterion 3.

**Implementation is deliberately not part of this record.** The first attempt at
the two scripts was written under declared self-review, and an adversarial
cross-vendor pass then found critical defects in both: the registered task
omitted the worktree argument, so every triggered run would have failed; the
wrapper never asserted the running SID; and the ACL guard matched identity by
substring instead of querying effective access. Those scripts are drafted
pending rework. The decision below survived that review unchanged, which is why
it is recorded separately from the code that will implement it.

## The gap

`scripts/exec-jail.sh` is 75 lines and contains no account switch. It empties
`GH_CONFIG_DIR`, nulls git config, and sets an author identity — all under the
invoking user. Every route's `invoke:` line therefore runs the executor as the
operator, outside the measured boundary, with full network.

Issue #59 says this is "specced nowhere", and that is accurate. #27 names the
account, #31 built the firewall around it, #32 probes credentials without
requiring the session to be that account, and #34 lists what an invocation must
carry without identity on the list. Each ticket assumes the connection; none
requires it. This ADR is the missing decision.

`scripts/exec-as-account.ps1` already performs a switch with
`Start-Process -Credential` behind an interactive `Read-Host` prompt. It stores
nothing, which is why it is safe, and it cannot run headlessly, which is why it
is not the answer on its own.

## The threat model this is chosen against

The adversary is **the executor process itself**: an AI agent that reads its own
environment, writes files, and has been observed making incidental writes
outside its declared scope (`AGENTS.md` §2a). It is not a remote attacker. So
the question is not "is the credential encrypted" but "can the thing we are
containing get at it".

## Decision

**A Windows scheduled task with a fixed action, registered once with
administrative rights, triggered on demand without them.**

The task runs as `director-exec`. The executor is handed a process that is
*already* running as that account and never receives a password, because no
password is passed at run time — Windows holds it.

The action is **fixed**. It is a tracked wrapper script with no caller-supplied
command. A task that accepts an arbitrary command line is not a containment
mechanism; it is a privilege-launch mechanism that anyone able to trigger it can
use to run code as the restricted account.

### Rejected: a DPAPI-protected credential blob

This is what the Codex CLI does for its own sandbox accounts, storing
`~/.codex/.sandbox-secrets/sandbox_users.json`. Rejected on two grounds.

First, it puts a reusable password in a file. User-scoped DPAPI would bind it to
the operator, so the executor could not decrypt it — but the file still exists,
and the control becomes "the executor cannot reach the operator's profile",
which is an ACL argument rather than an identity one.

Second, and decisively: on 2026-08-15 this repository spent a day on a Codex
sandbox that could not launch a single process, and the fault traced to exactly
that credential path. A stale blob dated 2026-07-17 no longer matched, and the
recovery required an interactive elevation prompt. An operationally fragile
credential store is a poor foundation for a control we intend to trust.

### Rejected: a Windows service

Same shape as the scheduled task, with a larger permanent surface and no
benefit here. Anyone who can modify the service binary or configuration obtains
execution as the account. Worth revisiting only if a service is independently
justified.

### Rejected: a job object

A job object bounds resources and process membership. It does not perform an
identity transition and cannot answer this question at all.

### Retained: interactive-only, as the fallback

`exec-as-account.ps1` stays. If the task is not registered, the interactive path
is still the correct way to run a one-off measured session. It is not deleted
and not deprecated.

## Consequences

- Registration needs administrative rights **once**. Triggering does not. This
  matters: an unelevated automated caller cannot self-elevate, and UAC consent
  is a human action by design.
- The task definition and its action script become security-relevant files. If
  the executor can modify the wrapper, it can run its own code as the account.
  The wrapper must live where the executor cannot write, and the registration
  must set an ACL that enforces it.
- Password rotation invalidates the stored task credential and requires
  re-registration. That is a feature: it fails closed and loudly.
- The mechanism is recorded in the route registry rather than inferred from a
  script's name, which is what criterion 3 asks for.

## How this gets measured, not asserted

Nothing here may be claimed until observed. The wrapper's first job is to report
**its own token identity** — user, SID, integrity level, and process ancestry —
so the evidence says which account actually ran, rather than which account the
caller intended. `AGENTS.md` §2a already forbids treating an exit code or an
agent's prose as evidence, and a logon record is not proof of the executing
identity either.

Acceptance for this mechanism is: a triggered run reports SID
`S-1-5-21-3373388009-2580916617-4075887755-1010`, from a process whose parent is
the Task Scheduler service rather than the operator's shell, with the executor
unable to modify the wrapper it ran from.

## What this ADR deliberately does not decide

**Which executor runs behind the boundary.** That is issue #59 criterion 1 and it
is left open on purpose.

The restricted account currently reaches no OpenAI endpoint, so the Codex CLI
cannot complete or refresh a subscription login there. The alternative is an
executor whose host is already permitted. Choosing between them by argument
would mean guessing hostnames, and a guessed allow list is exactly the kind of
asserted control this repository has been wrong about three times.

It does not need to be guessed. `scripts/egress-proxy.py` logs
`DENY <target> host not on the allow list` for every refused CONNECT. Running a
CLI behind a deny-by-default proxy therefore **produces** the hostname inventory
as a measurement. The decision is deferred until that run exists, and the
identity mechanism above is independent of its outcome.

Until then no allow-list entry is added, and every route stays
`runs_as: operator`.
