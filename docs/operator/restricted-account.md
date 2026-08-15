# Running the bounded executor as the restricted account

Issue [#59](https://github.com/Nercari/director-core/issues/59), under
[#27](https://github.com/Nercari/director-core/issues/27).

This document describes the account boundary and the evidence probe. It does
not create a Windows account, change a firewall rule, copy a token, or publish
a route claim. Those are operator actions and must be performed separately,
with their own review and rollback.

## What is implemented

`scripts/restricted-account-probe.ps1` emits structured JSON evidence for:

- the effective Windows account, SID, groups, process, parent process, working
  directory, user profile, and resolved tool paths;
- the restricted account's own Codex login state, recorded as an
  authenticated/not-authenticated result with redacted command output and the
  effective `CODEX_HOME` value;
- credential signals without reading credential values, including environment
  variables, the GitHub CLI hosts file, and Git credential-helper presence;
- `gh auth status`, `gh api user`, a network-free `git credential fill` refusal,
  and a credential-free `git push --dry-run`, with proxy variables unset,
  interactive prompts disabled, and pre-push hooks disabled; the push verdict
  distinguishes an egress block from a credential refusal;
- a deterministic local smoke task that creates, reads, validates, and removes
  one temporary artifact in the worktree;
- fail-closed status when the expected account, required tools, smoke task, or
  credential refusals are not observed.

The probe never treats a configuration excerpt as proof. A successful
credentialed command is a failure, not evidence of readiness. Command output is
redacted before it is placed in the JSON report, and credential values are not
read into the report. Each child probe receives an empty temporary
`GH_CONFIG_DIR`, so removing a caller override cannot reactivate the default
GitHub CLI profile.

`scripts/exec-as-account.ps1` is the operator-owned launcher. It requests the
dedicated account password through an explicit interactive console
`Read-Host -AsSecureString` prompt, constructs the fixed-user `PSCredential`,
starts the target directly with `Start-Process -Credential`, redirects output
through a temporary directory, redacts output, and removes that directory at
exit. Before prompting, it bounds the complete credentialed launch command
(resolved executable path plus arguments) at 1024 characters and directs an
oversized launch to the tracked `-File` bootstrap. Redirected or empty input
fails before launch. The password is not converted to plaintext or written to
a file, environment variable, argument list, or repository artifact.

The operator-side correction is performed by the tracked
`scripts/clean-restricted-account-probe.ps1` script. While still in the
operator account, it verifies the expected local account SID, clones the
requested branch and exact commit into a new path below
`C:\Users\director-exec`, verifies the remote, commit, and clean status, and
writes `.director\clean-clone-preflight.json`. It then scopes the target owner
and ACL to `director-exec`, verifies the resulting owner, and launches the
short tracked child as `director-exec` through the secure launcher.

The restricted account does not clone from GitHub: the egress boundary denies
that operation. The child derives all probe paths from the clean clone and
resolves `git` and `codex` from the restricted account's own `PATH`; it does
not inject the operator's executable path or login state. `director-exec`
must complete its own interactive Codex login before the evidence can be
`completed`.

The probe records the clean-clone owner, origin remote, full `HEAD` SHA, and
scoped repository status. Git's `dubious ownership` result is a repository
precondition failure, not credential-refusal evidence. Static ACL and
repository metadata checks are setup diagnostics; the child's effective SID
and account evidence establish who ran the probe.

## Local self-test

The self-test checks the redaction helper, the identity comparison guard, and
the smoke-task lifecycle. It deliberately does not switch accounts and cannot
prove that `director-exec` exists:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\restricted-account-probe.ps1 -SelfTest
```

## Operator evidence run

Run the tracked clean-clone bootstrap from the operator checkout. It clones
and verifies the clean commit before writing the manifest, scopes owner/ACL on
the target, and opens the launcher's secure Windows credential prompt. The
password is never supplied as a command argument:

```powershell
$remote = (git remote get-url origin).Trim()
$branch = (git branch --show-current).Trim()
$expectedCommit = (git rev-parse --verify HEAD).Trim()
$expectedSid = [string](Get-LocalUser -Name "director-exec").SID.Value
& .\scripts\clean-restricted-account-probe.ps1 `
  -Remote $remote `
  -Branch $branch `
  -ExpectedCommit $expectedCommit `
  -ExpectedSid $expectedSid `
  -TargetPath "C:\Users\director-exec\director-core-issue-59"
```

The plain `scripts\run-restricted-account-probe.ps1` wrapper is useful for
local mechanics, but a run from the operator checkout is not acceptance
evidence: the proof checkout must be the fresh clone owned by `director-exec`.

The expected success status is `completed`. Inspect the JSON itself and retain
it as evidence. In particular, confirm `identity.user` is `director-exec`,
`identity_checks.sid_matches_expected` is true,
`path.user_profile_matches_expected_user` is true,
`tools.executor.login.authenticated` is true, `smoke.passed` is true, both `gh` checks refused, and
`git_credential_fill.refused` is true. Under the restricted account's egress
boundary, the expected `git_push_dry_run.verdict` is `egress_blocked`, and that
verdict is a pass: the push never reached the remote. Credential absence for
Git is proven by `git_credential_fill.refused`, not by the push verdict. A
failed or incomplete report is
not promoted by editing its status.

If `tools.executor.login.authenticated` is false, complete the dedicated
account's official browser login when the clean-clone bootstrap invokes the
login runner. After a successful browser login, it automatically runs the
evidence probe. Do not substitute the operator checkout or pass an executor
path from the operator account:

```text
codex login --device-auth
```

This login runs as `director-exec`; it does not reuse the calling account's
login or ask for a token in the command line.

This correction produces an evidence handoff for Sol/operator review. It does
not by itself wire the `exec-jail` or route, and it does not establish full
issue-59 acceptance. The launcher is intentionally not a route. Do not change
`EXEC_STRONG.runs_as` from `operator` until a real run has recorded the
effective identity and the operator has reviewed the evidence. After that
review, update the route declaration and rerun preflight/conformance as a
separate change.

## Safety boundary

The implementation in this ticket performs no account administration, firewall
mutation, network-policy mutation, credential provisioning, push, merge, or PR
operation. The real account and firewall setup described by the egress-boundary
document remains operator work. A self-test passing is therefore only proof of
the local mechanics; it is not proof that the executor is already restricted.
