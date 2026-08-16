# Issue #59 — one step, and why there is only one

Issue [#59](https://github.com/Nercari/director-core/issues/59) is blocked on a
single measurement that nobody has taken. This document is that measurement and
nothing else.

An earlier version described the whole six-step sequence. Two adversarial
cross-vendor reviews found 53 problems in it between them, including three that
could have made a run look successful while the property being tested was
false, and one that could have restored a credential file into the wrong
profile. The sequence has been cut. What remains is the part that is runnable
today and produces evidence not dependent on any code currently in draft.

## The one step

**From an UNELEVATED PowerShell terminal**, in a window you are looking at:

```powershell
codex sandbox whoami /user
```

A UAC prompt will appear. Accept it.

**The terminal must NOT be elevated.** This matters twice over:

- An already-elevated terminal never raises the prompt, so the repair never
  happens.
- More importantly, the identity this command reports would then be an
  administrator's. Writing *that* into a route's `runs_as:` would pin the route
  to an administrative identity while looking like a successful verification —
  the exact inversion this issue exists to prevent.

## What it does

Two things at once.

**It repairs the Codex sandbox.** Every codex child launch currently fails with
`windows sandbox: CreateProcessWithLogonW failed: 2`. The stale credential blob
has already been removed, which moved the failure to
`ShellExecuteExW failed to launch setup helper: 1223` — Win32 `ERROR_CANCELLED`,
the UAC prompt going unanswered. Accepting it lets the setup helper run.

**It measures which account codex actually executes as.** That is the part that
matters for #59.

## Reading the result

You get a username and a SID. Compare it against these, resolved independently
rather than from the command's own output:

```powershell
Get-LocalUser | Where-Object Name -match 'CodexSandbox|director-exec' |
  Select-Object Name, @{n='SID';e={$_.SID.Value}}
```

| If the SID is | Then |
|---|---|
| the operator's own | `EXEC_STRONG: runs_as: operator` is correct. No registry change. |
| `…-1006` (`CodexSandboxOffline`) or `…-1007` (`CodexSandboxOnline`) | **`runs_as: operator` is wrong.** Codex has been running executor work under a sandbox account and the registry never said so. |
| anything else | Record it verbatim and stop. |

If it is `…-1006`, note that account carries three enabled Block rules —
outbound, loopback TCP, loopback UDP — which is *stricter* than
`director-exec`'s own boundary. That would mean part of what #59 wants already
exists, under an account nobody declared.

**Do not update the registry from this result alone.** It tells you which
account a `codex sandbox` child runs as. Whether a full executor turn runs as
the same account is a separate question, and `runs_as:` governs that one.

## If it fails

Record the exact error in `.director/failures.md` with the command and the
time, and stop. A failed attempt is evidence — criterion 9 says so. Do not
reinstall or update the CLI to work around it: updating changes
`version_seen: 0.145.0`, a declared route property, and both consulted CLIs
advised repairing rather than updating.

## Immediately afterwards

Accepting the prompt lets the setup helper reconfigure its own sandbox
accounts. If it recreates them, their SIDs change while the firewall rules stay
bound to the old ones, leaving the new account with **unconstrained egress**.

```powershell
Get-LocalUser | Where-Object Name -match 'CodexSandbox' |
  Select-Object Name, @{n='SID';e={$_.SID.Value}}
Get-NetFirewallRule | Where-Object DisplayName -match 'codex_sandbox' |
  ForEach-Object { "$($_.DisplayName) -> $(($_ | Get-NetFirewallSecurityFilter).LocalUser)" }
```

A rule bound to a SID no longer held by any account is a containment
regression. Fix it before anything else proceeds.

## Rollback

Only one thing changes, so only one thing needs undoing.

| To undo | Command |
|---|---|
| The credential blob | `Copy-Item 'C:\Users\dorot\AppData\Local\Temp\sandbox_users.json.bak' 'C:\Users\dorot\.codex\.sandbox-secrets\sandbox_users.json'` |

Absolute paths deliberately. `$env:TEMP` and `$env:USERPROFILE` resolve to a
different profile in an elevated session, so a rollback written with them can
restore a credential file into the wrong place. Check the backup exists and is
828 bytes first.

## What is deliberately not here

Registering the launch task, triggering it, rerunning the evidence probe, and
updating the registry. All four depend on PRs #82 and #85, which are drafts
because adversarial review found real defects in them — a scheduled task that
could never have run, and a credential probe that reached its conclusion
circularly.

Writing those steps down before the code existed produced a document that read
as ready when it was not. They will be rewritten from what this measurement
actually shows, rather than from what it was expected to show.

## Also closed while writing this

`director-exec` held a non-inherited `Modify` grant on the operator's worktree
at `…\director-core-issue-59`, which contains five PowerShell scripts. That let
the restricted account modify scripts the operator might later run elevated.
Revoked 2026-08-15. Restore, if it is ever genuinely wanted:

```powershell
icacls "C:\Users\dorot\Documents\AI Projects\director-core-issue-59" /grant "Pedro-dsktp\director-exec:(OI)(CI)M"
```

## Standing status

Two criteria met, two partial, five not met. Unchanged by this document. No
route's `runs_as:` has changed. `.director/failures.md` holds the shortfall
record.
