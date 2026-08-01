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
- the restricted account's own Codex login state, recorded only as an
  authenticated/not-authenticated result without emitting login output;
- credential signals without reading credential values, including environment
  variables, the GitHub CLI hosts file, and Git credential-helper presence;
- `gh auth status`, `gh api user`, and a credential-free `git push --dry-run`,
  with proxy variables unset, interactive prompts disabled, and pre-push hooks
  disabled;
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
dedicated account password interactively through `Get-Credential`, starts the
target directly with `Start-Process -Credential`, redirects output through a
temporary directory, redacts output, and removes that directory at exit. The
password is not written to a file, environment variable, argument list, or
repository artifact.

The one-step wrapper resolves the local Codex CLI and supplies only its binary
directory to the restricted child process PATH. It does not copy the calling
account's `.codex` directory, token, or login. `director-exec` must complete
its own interactive Codex login before the evidence can be `completed`.

## Local self-test

The self-test checks the redaction helper, the identity comparison guard, and
the smoke-task lifecycle. It deliberately does not switch accounts and cannot
prove that `director-exec` exists:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\restricted-account-probe.ps1 -SelfTest
```

## Operator evidence run

Run the one-step operator wrapper from the repository. It reads the account SID
locally, prepares the evidence arguments, and opens the launcher's secure
Windows credential prompt. The password is never supplied as a command
argument:

```powershell
.\scripts\run-restricted-account-probe.ps1
```

The expected success status is `completed`. Inspect the JSON itself and retain
it as evidence. In particular, confirm `identity.user` is `director-exec`,
`identity_checks.sid_matches_expected` is true,
`path.user_profile_matches_expected_user` is true,
`tools.executor.login.authenticated` is true, `smoke.passed` is true, both `gh` checks refused, and
`git_push_dry_run.credential_refused` is true. A failed or incomplete report is
not promoted by editing its status.

If `tools.executor.login.authenticated` is false, start the dedicated account's
official browser login with the same wrapper. After a successful browser login,
it automatically runs the evidence probe:

```powershell
.\scripts\run-restricted-account-probe.ps1 -Login
```

This opens the login flow as `director-exec`; it does not reuse the calling
account's login or ask for a token in the command line.

The launcher is intentionally not a route. It is an operator-side mechanism
for obtaining the observation that the route registry currently lacks. Do not
change `EXEC_STRONG.runs_as` from `operator` until a real run has recorded the
effective identity and the operator has reviewed the evidence. After that
review, update the route declaration and rerun preflight/conformance as a
separate change.

## Safety boundary

The implementation in this ticket performs no account administration, firewall
mutation, network-policy mutation, credential provisioning, push, merge, or PR
operation. The real account and firewall setup described by the egress-boundary
document remains operator work. A self-test passing is therefore only proof of
the local mechanics; it is not proof that the executor is already restricted.
