# Issue #59 — the restricted-account run, as a controlled experiment

Everything in issue [#59](https://github.com/Nercari/director-core/issues/59)
now turns on one run that a human has to start. This document is that run,
written so it can be executed without interpretation.

**Implementation is frozen.** Not paused for lack of ideas: the probe's
self-test executes as whoever invokes it, so it cannot establish any property
of `director-exec`. Hardening it further improves code that has no authority to
test the thing it exists to test. Nothing else should be built until this run
produces evidence.

## Why a human is required

Two prerequisites need administrative elevation, and UAC consent is a human
action by design. No flag on any tool supplies it, and an unelevated process
cannot self-elevate.

## Current status against the nine criteria

| # | Criterion | Status | What would change it |
|---|---|---|---|
| 1 | Own executor-CLI subscription auth | **not met** | Step 4, and it will likely still fail — see the egress note |
| 2 | Resolves `git` + executor on its own PATH | **met** | already measured 2026-08-15 |
| 3 | `exec-jail.sh` runs the executor as the account | **not met** | Step 2 + Step 3 |
| 4 | Executor's own reported identity captured | **not met** | Step 3 |
| 5 | Credential stripping holds under the switch | **partial** | Step 5 |
| 6 | Worktree writable, nothing outside it | **partial** | Step 5 |
| 7 | Baselines cited alongside | **partial** | Step 5 |
| 8 | Registry `runs_as:` matches measured identity | **not met** | only after Steps 3 and 5 both pass |
| 9 | Shortfall recorded if the above fail | **met** | `.director/failures.md` |

## Before you start

- Nothing here changes a route. `runs_as: operator` stays until Step 6, which
  is a separate decision after you have read the evidence.
- **Not everything is reversible.** The rollback table covers the task, the
  credential blob and the stale ACE. It does NOT cover the hostname-inventory
  proxy log, an executor login that succeeds, or artifacts a probe leaves
  behind. Treat reversibility as scoped to that table and nothing wider.
- If a step fails, **stop and record it** in `.director/failures.md` with the
  command, the raw output and the time. A failed attempt is evidence, which is
  what criterion 9 says. Do not overwrite an existing entry.

## What is runnable today, and what is not

An adversarial review of this document found that most of it depends on code
still in draft. Read this before opening an elevated session.

| Step | Runnable now? |
|---|---|
| 1 — repair the Codex sandbox | **YES** — this is the whole of today's session |
| 2 — register the launch task | **NO** — needs PR #82, drafted, known defective |
| 3 — trigger the task | **NO** — needs Step 2 |
| 4 — hostname inventory | **Partly** — the proxy capture works; the login fails by design |
| 5 — rerun the evidence probe | **NO** — needs PR #85, drafted |
| 6 — update the registry | **NO** — needs Steps 3 and 5 |

**Today's elevated session is Step 1 and nothing else.** Steps 2 to 6 are
written down so the sequence is known, not because they are ready. Starting
them consumes the session and fails.

## Step 1 — repair the Codex sandbox (elevated)

Every codex child launch currently fails with
`windows sandbox: CreateProcessWithLogonW failed: 2`. The stale credential blob
was already removed (backup at `%TEMP%\sandbox_users.json.bak`), which changed
the failure to `ShellExecuteExW failed to launch setup helper: 1223`.
Win32 1223 is `ERROR_CANCELLED` — the UAC prompt being declined.

From an **interactive terminal where UAC can prompt**, accept the prompt:

```powershell
codex sandbox whoami /user
```

**Expected:** a username and SID.

**What it also settles:** whether codex children run under a sandbox account
rather than the invoking user. Two enabled local accounts exist —
`CodexSandboxOffline` (SID `…-1006`) and `CodexSandboxOnline` (`…-1007`). The
Offline one carries three enabled Block rules (outbound, loopback TCP, loopback
UDP), which is *stricter* than `director-exec`'s own boundary.

If the SID returned is `…-1006` or `…-1007`, then `EXEC_STRONG: runs_as:
operator` **is wrong** and the registry must be corrected. Do not write that
correction from the account names alone — the SID from this command is the
measurement.

**If it still fails:** record the exact error and stop. Do not reinstall or
update the CLI to work around it; updating changes `version_seen: 0.145.0`, a
declared route property, and both consulted CLIs advised repairing rather than
updating.

## Step 2 — register the launch task (elevated)

Requires PR #82's scripts, which are **in draft and known defective**. Do not
run this step until #82 is reworked. It is listed here so the sequence is
complete.

When it is ready:

```powershell
& .\scripts\register-exec-task.ps1
```

It refuses if the session is not elevated, and refuses if `director-exec` can
modify the wrapper.

## Step 3 — trigger the task, unelevated

```powershell
Start-ScheduledTask -TaskName director-exec-launch
Get-Content C:\Users\director-exec\.director\launch-evidence.json
```

**The claim holds only if both of these are true:**

- `identity.sid` is the **complete** string
  `S-1-5-21-3373388009-2580916617-4075887755-1010`. Compare it in full. A
  suffix match is not enough: any value ending `-1010` would pass that, and the
  string is produced by the process being measured.
- `identity.parent_process` names the Task Scheduler service, not a shell

Then confirm the SID independently, from outside the probe's own output:

```powershell
(Get-LocalUser -Name 'director-exec').SID.Value
```

If those two strings are not identical, the evidence is not about the account
you think it is.

`status: completed` alone is **not** sufficient. An operator hand-running the
wrapper also produces `completed`.

**Then check the SIDs did not move.** If the sandbox repair in Step 1
recreated any account, its SID changed while the firewall rules stayed bound to
the old one, leaving that account with unconstrained egress:

```powershell
Get-LocalUser | Where-Object Name -match 'CodexSandbox|director-exec' |
  Select-Object Name, SID
Get-NetFirewallRule | Where-Object DisplayName -match 'codex_sandbox|director-exec' |
  ForEach-Object { "$($_.DisplayName) $(($_ | Get-NetFirewallSecurityFilter).LocalUser)" }
```

A rule bound to a SID no longer held by any account is a **containment
regression** and must be fixed before anything else proceeds.

## Step 4 — the executor login (expected to fail, and that is the finding)

Criterion 1 needs `director-exec` to hold its own subscription auth. It has all
outbound TCP denied, and the hostname proxy allows one Google host, so no
OpenAI endpoint is reachable. A device login can neither complete nor refresh.

**Do not add hostnames to the allow list from anyone's recollection.** Both
consulted CLIs were asked for the Codex CLI's endpoint list; one declined to
guess, the other produced a table and then retracted the row that mattered.

Measure it instead. `scripts/egress-proxy.py` logs
`DENY <target> host not on the allow list` for every refused CONNECT:

```powershell
python scripts\egress-proxy.py --port 8899 --log C:\tmp\proxy-inventory.log
# then, as director-exec, with HTTPS_PROXY/HTTP_PROXY pointed at 127.0.0.1:8899
codex login --device-auth
```

The DENY lines **are** the hostname inventory. Decide the allow list from that
log, not from this document.

## Step 5 — rerun the evidence probe as `director-exec`

Requires PR #85, in draft. Uses the bootstrap in
`docs/operator/restricted-account.md`, plus `-ForbiddenWritePaths` naming the
operator's tree.

**Read these fields and nothing else as the verdict:**

| Field | Passing value | Meaning |
|---|---|---|
| `identity.sid` | ends `-1010` | who actually ran |
| `git_push_dry_run.verdict` | `egress_blocked` or `credential_refused` | both pass the CREDENTIAL criterion. Only `egress_blocked` says anything about containment: `credential_refused` means the push reached something that answered, so it is evidence the network was **open**, not closed. Do not read it as containment. |
| `git_credential_fill.credential_supplied` | `false` | `true` is a hard fail |
| `git_credential_fill.inconclusive` | `false` | a timeout or exit-0-without-key is not a result |
| `write_boundary.all_refused` | `true` | with `any_inconclusive: false` |
| `baselines.all_present` | `true` | proves which document, not that the comparison is valid |

`status: completed` is a summary. Read the fields.

## Step 6 — only now, the registry

If and only if Steps 3 and 5 both passed, update the route's `runs_as:` to the
**measured** identity and rerun preflight and conformance as a separate change.
If either failed, `runs_as` stays `operator` and the shortfall is recorded.

## Rollback

**Every path here is absolute, deliberately.** `$env:TEMP` and
`$env:USERPROFILE` resolve to a DIFFERENT profile in an elevated session
started as another administrator, so a rollback written with those variables
can restore a credential file into the wrong profile, or fail to find the
backup at all. Do not reintroduce them.

| To undo | Command |
|---|---|
| The launch task | `Unregister-ScheduledTask -TaskName 'director-exec-launch' -TaskPath '\' -Confirm:$false` — confirm first with `Get-ScheduledTask -TaskName 'director-exec-launch' -TaskPath '\'` that its `Principal.UserId` is `director-exec`, so a same-named task is not removed by mistake |
| The credential blob | `Copy-Item 'C:\Users\dorot\AppData\Local\Temp\sandbox_users.json.bak' 'C:\Users\dorot\.codex\.sandbox-secrets\sandbox_users.json'` — the backup was taken from the `dorot` profile and belongs only there. Check it exists and is 828 bytes before restoring. |
| The stale worktree grant | `icacls "C:\Users\dorot\Documents\AI Projects\director-core-issue-59" /remove:g "Pedro-dsktp\director-exec"` — inspect first with `icacls "C:\Users\dorot\Documents\AI Projects\director-core-issue-59"`; remove only the non-inherited `Modify` ACE for that principal, and re-inspect afterwards |
| The proxy log | `Remove-Item 'C:\tmp\proxy-inventory.log'` if you do not want the hostname inventory retained |

Nothing above modifies a firewall rule. If a step tempts you to, stop: the
boundary is the thing being measured, and widening it to get a green result
would invert the purpose of the exercise.

## What this document does not claim

It does not claim the scripts are correct. Two adversarial cross-vendor review
passes found real defects in them, including a task that could never have run
and a credential probe that reached its conclusion circularly. PRs #82 and #85
are drafts for that reason. This document exists so that when they are ready,
the run is a controlled experiment rather than an improvisation.

It does not claim to be correct itself. A third adversarial pass, over this
document, returned 39 findings. The dangerous one is fixed: the rollback for
the credential blob used `$env:TEMP` and `$env:USERPROFILE`, which resolve to a
different profile in an elevated session and could have restored a credential
file into the wrong place. Every rollback path is now absolute.

**Every field in the Step 5 table is output from the probe being evaluated.**
That is a circularity the review named and this document cannot fix: a
compromised or defective probe reports whatever it reports. The independent
checks are the ones that come from elsewhere — `Get-LocalUser` for the SID, the
firewall enumeration for rule bindings, and the proxy's own log for hostnames.
Weight those above anything the probe says about itself.

Steps 2, 3, 5 and 6 also lack literal commands, because the code they would
invoke is in draft and its interface may change. They are a sequence, not a
script. Do not treat them as ready.
