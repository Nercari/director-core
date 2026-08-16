# 0001 — How an executor process comes to run as the restricted account

Status: accepted, 2026-08-15. Supersedes nothing.
Context: issue [#59](https://github.com/Nercari/director-core/issues/59), criterion 3.

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
  The wrapper must live where the executor cannot write. **Amended 2026-08-16**:
  this originally said the registration "must set an ACL that enforces it", and
  the first implementation tried to, with an ACE-string check that missed group
  membership, ownership, deny precedence, inheritance, and the containing
  directory. Registration now enforces the **structural** property — the wrapper
  must be outside the tree the account owns — and the access itself is measured
  by the wrapper at trigger time, as the account, by opening itself for write.
  Registration refuses on structure; the triggered run measures the access.
  Neither is claimed to be the other. **Amended again after a second adversarial
  pass:** that pair is still not a proof, and the sentence above was implying it
  was. Outside the account's tree is *necessary, not sufficient* — nothing checks
  whether the wrapper's own ACL grants the account `WRITE_DAC`, ownership, or
  delete rights on its directory. And the trigger-time measurement is performed
  *by the wrapper*, so if the account replaced the wrapper before the first
  trigger, the measuring code is already the attacker's. A component cannot vouch
  for itself. Both are properties of the deployment rather than of these scripts,
  and neither is closed here.
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
`S-1-5-21-3373388009-2580916617-4075887755-1010`, and reports
`wrapper_self_protection.wrapper_writable` and `.directory_writable` both false,
measured by attempting the writes rather than reading an ACL.

**Amended 2026-08-16, third amendment — the evidence path has an unclosed race,
and the fix is a relocation nobody has done yet.** The wrapper checks the
evidence path for reparse points and then writes to it; the account owns that
tree and can swap a directory for a junction in between. Both consulted CLIs
were asked for a way to close this on PowerShell 5.1 and neither found one worth
taking — `FILE_FLAG_OPEN_REPARSE_POINT` opens the reparse object rather than
refusing traversal, and a relative open via `NtCreateFile`'s `RootDirectory`
needs P/Invoke these scripts will not carry. **The real fix is to move the
evidence out of the account-owned tree**, into a directory the operator owns
where the account may write a file but cannot replace the directory entry. That
is the upgrade path. Until it is done, the reparse check is a misconfiguration
guard and is not atomic, and nothing here should describe it as one.

A related limit, stated because it is easy to over-claim: a run that dies
without throwing now leaves a `pending` record rather than the previous run's
verdict, but a task that **never launches** writes nothing at all, so whatever
was on disk survives. Only the caller can close that, by invalidating before
triggering. Timestamp freshness alone is not sufficient — a fixed action carries
no trusted per-run identifier.

**Amended 2026-08-16, second amendment — that evidence is a self-report, not
proof.** An adversarial review pointed out that the wrapper runs *as* the
restricted account and writes its JSON into a directory that account controls,
so an adversary already resident in the account can overwrite the file with a
fabricated passing report. Accepted rather than papered over: a process cannot
prove its own containment to an outside observer without trusted external
infrastructure, which this repository does not have. The acceptance above is a
check against **misconfiguration**, which it can address, and not against an
**already-resident adversary**, which it cannot. Both scripts say so where an
operator will read it.

**Amended 2026-08-16.** This previously also required the run to come "from a
process whose parent is the Task Scheduler service rather than the operator's
shell". That criterion is **withdrawn, not weakened**: a process name is
trivially reproducible, and nothing inside a process can establish its own
provenance. The scheduler's own
`Microsoft-Windows-TaskScheduler/Operational` channel would be external evidence
and therefore stronger, but `wevtutil gl` reports it `enabled: false` on this
machine, so it records nothing to correlate against. An operator who wants
provenance must enable that channel first; its `channelAccess` already grants
`BATCH` read, `(A;;0x3;;;S-1-5-3)`, so a task-triggered run could read it.
Nothing in this ADR depends on that.

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
