# register-exec-task - register the restricted-account launch task, once.
# ADR docs/adr/0001-restricted-account-launch.md. Issue #59, criterion 3.
#
# ASCII only. Windows PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI, so a
# multi-byte character here is a parse error under the engine this runs on.
#
# This needs administrative rights ONCE, at registration. Triggering the task
# afterwards does not, which is the whole reason the task exists: an unelevated
# automated caller cannot self-elevate, and UAC consent is a human action.
#
# The action is FIXED. This script never accepts a command to run as the
# restricted account, and the registered task never takes one. A task that runs
# an arbitrary command line as director-exec would be a privilege-launch
# mechanism for anyone able to trigger it.
#
# REWORKED after an adversarial cross-vendor review of PR #82. The action it
# built was missing -WorktreePath, so every triggered run would have recorded
# "no worktree was supplied" and failed - and the self-test never noticed,
# because it never exercised the registered action. It does now: -SelfTest runs
# the argument string this script would register, through the same builder.
#
# DEPENDENCIES, stated rather than glossed. Get-LocalUser, Get-LocalGroupMember,
# Get-ScheduledTask, New-ScheduledTaskAction, New-ScheduledTaskSettingsSet and
# Register-ScheduledTask are MODULE cmdlets (Microsoft.PowerShell.LocalAccounts,
# ScheduledTasks), not engine built-ins. The previous claim that this script was
# "5.1-safe" was narrower than stated: it is 5.1-safe on a Windows install that
# ships those modules. secedit.exe is also required, for the batch-logon check.
#
# New-ScheduledTaskPrincipal was listed here until 2026-08-16 and is NOT called -
# it was removed when the Register-ScheduledTask parameter-set defect was fixed.
# A dependency list that names something the script does not use is the same
# class of defect as a comment claiming a guarantee the code does not provide.
[CmdletBinding()]
param(
    [string]$TaskName = "director-exec-launch",
    [string]$UserName = "director-exec",
    # Resolved after the param block, not in it: $PSScriptRoot is not populated
    # inside a param default under Windows PowerShell 5.1.
    [string]$WrapperPath = "",
    # Review finding 7: this used to be caller-supplied and unvalidated, so the
    # task could be registered against an arbitrary directory while every
    # surrounding comment described a single fixed tree. It is now checked
    # against the account's actual profile below.
    [string]$PermittedRoot = "",
    # Review finding 1. The fixed action must carry the worktree, because the
    # trigger cannot: a task that accepts a path at trigger time is a task that
    # accepts caller input, which is the thing the fixed action exists to avoid.
    # Baked in here, one fixed path, re-pointed by the operator between units.
    [string]$WorktreePath = "",
    [switch]$Verify,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TaskActionArgument {
    param(
        [Parameter(Mandatory = $true)][string]$Wrapper,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Worktree,
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$Evidence
    )
    # ONE builder, used by both registration and -SelfTest. That is the whole
    # point: the previous self-test passed while the registered action was
    # missing a required parameter, because the two were built in different
    # places and only one of them was ever exercised.
    return @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"' + $Wrapper + '"'),
        "-PermittedRoot", ('"' + $Root + '"'),
        "-WorktreePath", ('"' + $Worktree + '"'),
        "-ExpectedSid", $Sid,
        "-OutputPath", ('"' + $Evidence + '"')
    ) -join " "
}

function Test-BatchLogonRight {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        # Matched as well as the SID, and NOT optional in practice. Measured
        # 2026-08-16 on this machine, reading the live export:
        #   SeInteractiveLogonRight = Guest,*S-1-5-32-544,*S-1-5-32-545,...
        # "Guest" is a plain ACCOUNT NAME. secedit records these entries in
        # either form, so a SID-only match would report "not granted" for a
        # machine where the right IS granted and Windows happened to store the
        # name - refusing a correctly configured system and blaming the
        # operator. Found by running the check, not by reading it.
        [Parameter(Mandatory = $true)][string]$AccountName
    )

    # THE PRECONDITION THAT WAS MISSING, AND IT COST A WHOLE EXPERIMENT.
    # Measured 2026-08-16: this task registered cleanly, Start-ScheduledTask
    # returned without error, and NOTHING HAPPENED. No process, no output, no
    # file. Get-ScheduledTaskInfo reported LastTaskResult 0x00041303
    # (SCHED_S_TASK_HAS_NOT_RUN) with LastRunTime at the 1999 "never" sentinel:
    # the task had never run even once.
    #
    # The cause, read straight out of local policy rather than inferred:
    #   SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559
    # Administrators, Backup Operators, Performance Log Users. director-exec was
    # not there. A task whose principal supplies a password needs a BATCH logon,
    # and an account without that right cannot get one, so Task Scheduler never
    # creates the session and never starts the action.
    #
    # Windows says so at registration time and the cmdlet throws the message
    # away: RegisterTaskDefinition documents the success-with-warning HRESULT
    # 0x0004131C, SCHED_S_BATCH_LOGON_PROBLEM - "the task is registered, but may
    # fail to start; batch logon privilege needs to be enabled for the task
    # principal". Register-ScheduledTask surfaces no such warning, so the only
    # way to see it is to check the right ourselves, before registering.
    #
    # This script does NOT grant the right. Granting a logon right is a change to
    # machine security policy and belongs to the operator, deliberately, in front
    # of them - not to a script that already holds elevation for another purpose.
    $result = [ordered]@{
        granted = $false
        denied = $false
        readable = $false
        detail = ""
    }
    $export = Join-Path ([IO.Path]::GetTempPath()) ("director-userrights-" + [guid]::NewGuid().ToString("N") + ".inf")
    try {
        & (Join-Path ([Environment]::GetFolderPath("System")) "secedit.exe") `
            /export /areas USER_RIGHTS /cfg $export /quiet 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $export -PathType Leaf)) {
            $result.detail = "secedit produced no policy export, so the right could not be read"
            return $result
        }
        $result.readable = $true
        $policy = Get-Content -LiteralPath $export
        $allow = @($policy | Where-Object { $_ -match "^SeBatchLogonRight" })
        $deny = @($policy | Where-Object { $_ -match "^SeDenyBatchLogonRight" })
        # Either form counts. The name is matched on its own comma-delimited
        # field so that a substring cannot produce a false positive:
        # "director-exec-evil" must not satisfy a check for "director-exec".
        $leaf = ($AccountName -split "\\")[-1]
        $namePattern = "(^|[=,])\s*(\*?[A-Za-z0-9\-]+\\)?" + [regex]::Escape($leaf) + "\s*($|,)"
        $matchesEntry = {
            param($lines)
            $hit = $false
            foreach ($line in @($lines)) {
                if ($line -match [regex]::Escape($Sid)) { $hit = $true }
                if ($line -match $namePattern) { $hit = $true }
            }
            return $hit
        }
        $result.granted = & $matchesEntry $allow
        # DENY OVERRIDES ALLOW. Checking only the allow line would pass an account
        # that policy explicitly forbids.
        $result.denied = & $matchesEntry $deny
        $result.detail = "allow: " + $(if ($allow) { $allow -join " " } else { "(no SeBatchLogonRight line)" }) +
            " | deny: " + $(if ($deny) { $deny -join " " } else { "(none)" })
    } catch {
        $result.detail = "could not read local policy: " + [string]$_
    } finally {
        if (Test-Path -LiteralPath $export -PathType Leaf) {
            Remove-Item -LiteralPath $export -Force -ErrorAction SilentlyContinue
        }
    }
    return $result
}

function Get-SystemPowerShellPath {
    # One resolver, used by BOTH the registered action and -SelfTest. They were
    # separate, and drifted the moment the production path was pinned: the
    # self-test kept a bare "powershell.exe" that resolves through the working
    # directory. Same class of defect as the two copies of the path guard.
    $path = Join-Path ([Environment]::GetFolderPath("System")) "WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "powershell.exe is not at its system path: $path"
    }
    return $path
}

function Get-RegisterParameterNames {
    # The exact parameters the real Register-ScheduledTask call supplies. One
    # source of truth, checked against the call itself at registration time and
    # bind-checked against the live cmdlet by -SelfTest.
    return @("TaskName", "Action", "Settings", "User", "Password", "RunLevel", "Force")
}

function Test-RegisterParametersBindToOneSet {
    # THE CHECK THAT WOULD HAVE CAUGHT THE CRITICAL DEFECT. The previous version
    # passed -Principal together with -User and -Password. Those live in
    # different parameter sets, so binding failed before Task Scheduler was
    # reached and the task could never register - and -SelfTest passed anyway,
    # because it exited before that line and only ever checked argument shape.
    #
    # This asks the LIVE cmdlet whether the parameters actually used all fit in
    # a single set. No registration, no elevation, no side effects, and it
    # cannot go stale the way a comment can.
    $names = Get-RegisterParameterNames
    $command = Get-Command -Name "ScheduledTasks\Register-ScheduledTask" -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return [ordered]@{
            ok = $false
            detail = "Register-ScheduledTask is not available, so its parameter sets cannot be checked"
            sets = @()
        }
    }
    $satisfying = @()
    foreach ($set in $command.ParameterSets) {
        $available = @($set.Parameters | ForEach-Object { [string]$_.Name })
        $missing = @($names | Where-Object { $available -notcontains $_ })
        if ($missing.Count -eq 0) {
            $satisfying += [string]$set.Name
        }
    }
    return [ordered]@{
        ok = ($satisfying.Count -ge 1)
        detail = $(if ($satisfying.Count -ge 1) {
                "all parameters bind to set(s): " + ($satisfying -join ", ")
            } else {
                "no single parameter set of Register-ScheduledTask accepts all of: " + ($names -join ", ")
            })
        sets = @($satisfying)
    }
}

function Get-ReparseSegments {
    # Same guard as the wrapper, for the same reason: a junction anywhere on
    # the path can redirect the tail outside the root. Duplicated rather than
    # shared because dot-sourcing the wrapper from the registrar would let a
    # writable wrapper influence its own registration.
    param([AllowNull()][string]$Path)
    $found = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @($found)
    }
    $current = ""
    $reachedRoot = $false
    try {
        $current = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    } catch {
        return @("<unresolvable: " + $Path + ">")
    }
    # THE BOUND IS DERIVED FROM THE PATH, not a guessed constant. A flat 64 was
    # fail-open first (it returned an empty list at the cap, indistinguishable
    # from a clean walk) and then, once made fail-closed, fail-WRONG: a
    # legitimately deep path returned "walk incomplete" and callers read that as
    # a reparse failure. Neither is acceptable for a guard.
    #
    # A path cannot have more separators than it has characters, and each
    # iteration strips exactly one component, so the component count plus a
    # small margin is an EXACT ceiling that can never be reached by a valid path
    # and still cannot spin on a malformed one.
    $maxDepth = ($current.Split([char]92).Count) + 4
    for ($depth = 0; $depth -lt $maxDepth -and -not [string]::IsNullOrWhiteSpace($current); $depth++) {
        if (Test-Path -LiteralPath $current) {
            # Fails closed, same as the wrapper's copy: a segment whose
            # attributes cannot be read is REPORTED, not skipped.
            $attributes = $null
            try {
                $attributes = [IO.File]::GetAttributes($current)
            } catch {
                $found.Add("<unreadable attributes: " + $current + ">")
            }
            if ($null -ne $attributes -and $attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
                $found.Add($current)
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            $reachedRoot = $true
            break
        }
        $current = $parent
    }
    # THE BOUND FAILED OPEN. The loop stopped at 64 levels and returned an empty
    # list, indistinguishable from "walked the whole path, found nothing" - so a
    # path with more than 64 components followed by a junction would have been
    # accepted. A walk that did not reach the root is now REPORTED.
    if (-not $reachedRoot) {
        $found.Add("<walk did not reach the filesystem root: " + $Path + ">")
    }
    return @($found)
}

function Test-PathWithinRoot {
    # THE TWO COPIES HAD DIVERGED, and the adversarial review found it. This one
    # was purely lexical while the wrapper's rejected reparse points, so
    # Assert-WrapperOutsideExecutorTree could be defeated by a junction OUTSIDE
    # the permitted root pointing INTO it: the string prefix said "outside",
    # registration allowed it, and the wrapper was writable by the account after
    # all. The reparse rejection is now in both.
    #
    # Still duplicated rather than shared. The Gemini CLI recommended extracting
    # both guards into a security-utils.ps1 dot-sourced by each script, and its
    # reasoning about the dot-source direction is right - sourcing the WRAPPER
    # into the elevated registrar would run wrapper code elevated. But a third
    # file for two functions is the kind of structure this repository adds only
    # after a failure mode recurs, and divergence has now happened once.
    # Recorded rather than built.
    param([string]$Candidate, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }
    $c = ([IO.Path]::GetFullPath($Candidate)).TrimEnd("\").ToLowerInvariant()
    $r = ([IO.Path]::GetFullPath($Root)).TrimEnd("\").ToLowerInvariant()
    $lexicallyInside = ($c -eq $r) -or $c.StartsWith($r + "\", [StringComparison]::Ordinal)
    if (-not $lexicallyInside) {
        return $false
    }
    return (@(Get-ReparseSegments -Path $Candidate).Count -eq 0) -and
           (@(Get-ReparseSegments -Path $Root).Count -eq 0)
}

function Assert-WrapperOutsideExecutorTree {
    param([string]$Wrapper, [string]$Root)

    # Review finding 4, answered STRUCTURALLY rather than by a better ACL read.
    #
    # What was here before: Assert-WrapperNotWritableByExecutor, which matched
    # ACE IdentityReference strings with a regex against Allow ACEs only. It
    # missed access granted through group membership, ownership (an owner can
    # rewrite the DACL, so any deny it found was rewritable), deny-ACE
    # precedence, inheritance, and the containing directory - where Delete or
    # CreateFiles lets the account replace the wrapper without ever writing to
    # the file. It also claimed to establish that the executor cannot rewrite
    # the wrapper, which it never did.
    #
    # It is not replaced by a better query. The OpenAI CLI recommended an Authz
    # effective-access check, which is the accurate form of that query, but it
    # needs a P/Invoke block inside the security-critical script and still only
    # predicts what the OS would do. Two things replace it instead:
    #
    #   1. THIS: the wrapper must live outside the tree the restricted account
    #      owns. Purely structural, nothing to get subtly wrong, and it is the
    #      property that actually matters. A wrapper inside the executor's own
    #      profile is writable by construction no matter what any ACL says.
    #   2. The wrapper measures its own writability AT TRIGGER TIME, as the
    #      restricted account, by opening itself for write. See
    #      Test-SelfReplaceable in exec-task-wrapper.ps1. That is a measured
    #      operation by the account that matters, which is the only thing this
    #      repository accepts as evidence about access.
    #
    # So registration refuses on structure, and the triggered run measures the
    # access. Neither claims to be the other.
    #
    # AND THAT PAIR IS STILL NOT A PROOF, which a second adversarial pass caught
    # and the sentence above was quietly implying. Two gaps, both real:
    #
    #   1. Outside the account's tree is NECESSARY, not SUFFICIENT. This function
    #      performs no ACL, owner, or privilege check, so a wrapper sitting
    #      outside that tree while granting the account WRITE_DAC, ownership, or
    #      delete rights on its directory passes here unremarked.
    #   2. The trigger-time measurement is performed BY THE WRAPPER. If the
    #      account replaced the wrapper before the first trigger, the code doing
    #      the measuring is already the attacker's, and it will report whatever
    #      it likes. A component cannot vouch for itself.
    #
    # No code change closes either one from here; both are properties of the
    # deployment, not of this script. They are stated rather than implied, and
    # the ADR now says the same. What this pair DOES establish is that the
    # wrapper is not in the obvious place the account could trivially rewrite -
    # a misconfiguration check, which is what the whole mechanism can honestly
    # claim against an adversary that is not already resident.
    # THE REPARSE CHECK IS DONE HERE AND NOT DELEGATED, and the direction is the
    # reason. Test-PathWithinRoot answers "is this INSIDE", and it fails closed
    # by returning false when a reparse point is present - correct for the two
    # callers that REQUIRE inside, wrong for this one, which requires OUTSIDE. A
    # junction-laced path would have come back "false = outside = allowed",
    # which is the exact bypass being closed. So the reparse rejection is
    # applied explicitly, as its own refusal, before the containment question is
    # asked at all.
    $wrapperReparse = @(Get-ReparseSegments -Path $Wrapper)
    $rootReparse = @(Get-ReparseSegments -Path $Root)
    if ($wrapperReparse.Count -gt 0 -or $rootReparse.Count -gt 0) {
        throw ("refusing to register: the wrapper path or the permitted root traverses a " +
            "reparse point, so 'the wrapper is outside the account's tree' cannot be " +
            "established by comparing them: " + (@($wrapperReparse + $rootReparse) -join ", "))
    }
    $wrapperFull = ([IO.Path]::GetFullPath($Wrapper)).TrimEnd("\").ToLowerInvariant()
    $rootFull = ([IO.Path]::GetFullPath($Root)).TrimEnd("\").ToLowerInvariant()
    if ($wrapperFull -eq $rootFull -or $wrapperFull.StartsWith($rootFull + "\", [StringComparison]::Ordinal)) {
        throw ("refusing to register: the wrapper at $Wrapper is inside the restricted " +
            "account's own tree ($Root), so that account can replace it and run its own " +
            "code with the task's blessing. Move the wrapper outside that tree.")
    }
}

if ([string]::IsNullOrWhiteSpace($WrapperPath)) {
    $here = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $PSScriptRoot
    } else {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $WrapperPath = Join-Path $here "exec-task-wrapper.ps1"
}
if (-not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) {
    throw "wrapper script not found: $WrapperPath"
}
$WrapperPath = (Resolve-Path -LiteralPath $WrapperPath).Path

if ($SelfTest) {
    # -SelfTest EXECUTES THE WRAPPER, so it must never execute one a caller
    # named. Found by the third adversarial pass: the self-test block sits above
    # Assert-WrapperOutsideExecutorTree and exits before reaching it, so
    # `-SelfTest -WrapperPath <anything.ps1>` ran that file through
    # powershell.exe with no guard whatsoever - and an operator has every reason
    # to run -SelfTest from an elevated prompt, since registration needs
    # elevation and the two are used together.
    #
    # The fix is a refusal rather than a relocated guard. The self-test's whole
    # purpose is to exercise the wrapper that ships beside this script; there is
    # no legitimate reason to point it somewhere else, so pointing it somewhere
    # else is refused outright and the guard's placement stops mattering.
    if ($PSBoundParameters.ContainsKey("WrapperPath")) {
        throw ("-SelfTest will not run a caller-supplied -WrapperPath: it EXECUTES that file, " +
            "and this script is normally run elevated. Run -SelfTest with no -WrapperPath so it " +
            "exercises the wrapper shipped beside it, which is the only one it is meant to test.")
    }

    # Review finding 1, answered at its root cause. The old self-test proved the
    # path guard and the evidence shape and never once ran what would actually
    # be registered, so a missing -WorktreePath survived every check. This runs
    # the argument string from Get-TaskActionArgument - the same builder
    # registration uses - against a temporary tree, and reads the evidence back.
    $failures = New-Object System.Collections.Generic.List[string]
    $root = Join-Path ([IO.Path]::GetTempPath()) ("director-reg-selftest-" + [guid]::NewGuid().ToString("N"))
    $worktree = Join-Path $root "wt"
    $evidencePath = Join-Path $root "launch-evidence.json"
    try {
        # THE REGISTRATION CALL ITSELF, bind-checked. This is the assertion that
        # would have caught the critical defect: the call used to mix -Principal
        # with -User/-Password, which are mutually exclusive, so the task could
        # never register while this self-test happily passed.
        $binding = Test-RegisterParametersBindToOneSet
        if (-not $binding.ok) {
            $failures.Add("the registration call cannot bind: " + $binding.detail)
        }
        Write-Output ("self-test: registration parameter binding | " + $binding.detail)

        New-Item -ItemType Directory -Path $worktree -Force | Out-Null
        # A SID this process definitely is not, so a passing identity assertion
        # here would mean the assertion is not enforcing.
        $arguments = Get-TaskActionArgument -Wrapper $WrapperPath -Root $root `
            -Worktree $worktree -Sid "S-1-5-18" -Evidence $evidencePath
        # THE SAME ABSOLUTE PATH THE REAL TASK USES. This said "powershell.exe"
        # while production had already been pinned to the system path, so the
        # self-test resolved through the working directory - the more reachable
        # of the two - and did not exercise what actually runs.
        $shell = Get-SystemPowerShellPath
        Write-Output ("self-test: registered action | " + $shell + " " + $arguments)

        $process = Start-Process -FilePath $shell -ArgumentList $arguments `
            -NoNewWindow -Wait -PassThru
        Write-Output ("self-test: triggered action exit code | " + $process.ExitCode)

        if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
            $failures.Add("the registered action wrote no evidence file at $evidencePath")
        } else {
            $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
            $failureText = (@($evidence.failures) -join "; ")

            # THE DEFECT THIS EXISTS TO CATCH. If the action ever stops carrying
            # -WorktreePath, this fires.
            if ($failureText.Contains("no worktree was supplied")) {
                $failures.Add("the registered action did not carry -WorktreePath; every triggered run would fail")
            }
            if (-not $evidence.worktree.within_permitted_root) {
                $failures.Add("the registered action's worktree was not accepted as inside its permitted root")
            }
            if (-not $evidence.worktree.exists) {
                $failures.Add("the registered action did not find the worktree it was given")
            }
            # And that -ExpectedSid is carried AND enforcing.
            if ([string]::IsNullOrWhiteSpace([string]$evidence.expected_sid)) {
                $failures.Add("the registered action did not carry -ExpectedSid")
            }
            if ($evidence.identity_checks.sid_matches_expected) {
                $failures.Add("the wrapper accepted S-1-5-18 as this process's SID; the identity assertion is not enforcing")
            }
            if (-not $failureText.Contains("not the required")) {
                $failures.Add("a SID mismatch was not reported by the registered action")
            }
            if ($process.ExitCode -eq 0) {
                $failures.Add("the registered action exited 0 while running as the wrong account")
            }
            Write-Output ("self-test: evidence | status: " + $evidence.status +
                " | within root: " + ([string]$evidence.worktree.within_permitted_root).ToLowerInvariant() +
                " | expected sid carried: " + (-not [string]::IsNullOrWhiteSpace([string]$evidence.expected_sid)).ToString().ToLowerInvariant() +
                " | sid matched: " + ([string]$evidence.identity_checks.sid_matches_expected).ToLowerInvariant())
            Write-Output ("self-test: action failures | " + $failureText)
        }

        # THE POSITIVE PATH. Every assertion above is a rejection, and a wrapper
        # that rejected EVERYTHING would satisfy all of them - the reviewer gave
        # the exact counterexample. So the action is run once more with this
        # process's real SID, and the identity check must ACCEPT it.
        #
        # Note what is and is not asserted. `status: completed` is NOT required:
        # the wrapper is writable by the operator running this, so its
        # self-protection check correctly reports a failure here. What must hold
        # is that the SID check flips to true and stops contributing a failure.
        $ownSid = [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $positiveEvidence = Join-Path $root "launch-evidence-positive.json"
        $positiveArguments = Get-TaskActionArgument -Wrapper $WrapperPath -Root $root `
            -Worktree $worktree -Sid $ownSid -Evidence $positiveEvidence
        Start-Process -FilePath $shell -ArgumentList $positiveArguments -NoNewWindow -Wait | Out-Null
        if (-not (Test-Path -LiteralPath $positiveEvidence -PathType Leaf)) {
            $failures.Add("the positive-path run wrote no evidence file")
        } else {
            $positive = Get-Content -LiteralPath $positiveEvidence -Raw | ConvertFrom-Json
            $positiveFailures = (@($positive.failures) -join "; ")
            if (-not $positive.identity_checks.sid_matches_expected) {
                $failures.Add("the wrapper REJECTED this process's own SID; the identity check refuses everything and would reject the restricted account too")
            }
            if ($positiveFailures.Contains("not the required")) {
                $failures.Add("a SID mismatch was reported for the correct SID")
            }
            Write-Output ("self-test: positive path | required " + $ownSid +
                " | sid matched: " + ([string]$positive.identity_checks.sid_matches_expected).ToLowerInvariant() +
                " | remaining failures: " + $positiveFailures)
        }
    } finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # The batch-logon precondition, exercised in BOTH directions against live
    # policy. Administrators (S-1-5-32-544) holds the right on any default
    # Windows install; a well-formed SID that belongs to nobody does not. If the
    # policy cannot be read at all - secedit needs elevation and -SelfTest does
    # not require it - the check reports that instead of guessing, and the
    # assertions are skipped rather than passing silently.
    $rightKnown = Test-BatchLogonRight -Sid "S-1-5-32-544" -AccountName "Administrators"
    $rightAbsent = Test-BatchLogonRight -Sid "S-1-5-21-9999999999-9999999999-9999999999-4321" -AccountName "director-exec-no-such-account"
    if (-not $rightKnown.readable) {
        Write-Output ("self-test: batch logon right NOT asserted - local policy is unreadable from this session " +
            "(secedit needs elevation). " + $rightKnown.detail)
    } else {
        if (-not $rightKnown.granted) {
            $failures.Add("the batch-logon check did not find the right for BUILTIN\Administrators, which holds it by default; it is reporting false for everything")
        }
        if ($rightAbsent.granted) {
            $failures.Add("the batch-logon check reported the right for a SID that belongs to no account; it is reporting true for everything")
        }
        Write-Output ("self-test: batch logon right | Administrators granted: " + ([string]$rightKnown.granted).ToLowerInvariant() +
            " | nonexistent SID granted: " + ([string]$rightAbsent.granted).ToLowerInvariant())
    }

    Write-Output "self-test: does NOT register anything, and does NOT establish the account switch"
    if ($failures.Count -eq 0) {
        Write-Output "register-exec-task self-test PASSED"
        exit 0
    }
    Write-Output ("register-exec-task self-test FAILED: " + ($failures -join "; "))
    exit 1
}

if ($Verify) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Write-Output "task '$TaskName' is NOT registered"
        exit 1
    }
    Write-Output ("task:      " + $task.TaskName)
    Write-Output ("runs as:   " + $task.Principal.UserId)
    Write-Output ("logon:     " + $task.Principal.LogonType)
    Write-Output ("run level: " + $task.Principal.RunLevel)
    foreach ($action in $task.Actions) {
        Write-Output ("action:    " + $action.Execute + " " + $action.Arguments)
    }
    Write-Output ""
    Write-Output "Registration is not evidence. Trigger it and read the evidence the"
    Write-Output "wrapper writes: identity.sid must be the restricted account's SID, and"
    Write-Output "wrapper_self_protection must report the wrapper unwritable by it."
    Write-Output "identity.parent_process is DATA and establishes nothing - see the"
    Write-Output "comment on that field in exec-task-wrapper.ps1."
    exit 0
}

if (-not (Test-Elevated)) {
    throw "registration requires an elevated session. Triggering the task afterwards does not."
}

# THE ACCOUNT IS PINNED. -UserName was a free parameter, so an elevated caller
# could point the whole mechanism at any other non-administrator local account:
# the script would compute that account's SID and profile, build the action
# around it, and register a task the ADR does not describe. The ADR is about one
# account. Overriding it is possible but must be deliberate and visible in the
# command line, not a default that silently drifts.
$adrAccount = "director-exec"
# NO OVERRIDE. -AllowOtherAccount used to let an elevated caller point the whole
# mechanism at any other non-administrator account behind a printed warning,
# which contradicted the ADR's own statement that this is about one named
# account. A switch that lets a caller leave the documented threat model, gated
# by a message nobody reads, is not a safeguard - it is an untested
# configuration path with a warning attached. Both consulted CLIs and the
# adversarial review agreed it should go, and it is gone.
if ($UserName -ine $adrAccount) {
    throw ("refusing to register for '$UserName': ADR 0001 specifies '$adrAccount', and every " +
        "claim in that ADR and in the evidence this produces is about '$adrAccount'. None of it " +
        "transfers to another account. Registering a different one needs a different ADR, not a " +
        "switch.")
}

$account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($null -eq $account) {
    throw "local account '$UserName' does not exist; this script does not create accounts"
}
$accountSid = [string]$account.SID.Value

# Review finding 10. RunLevel Limited does not by itself establish that the
# account is not an administrator: it caps the token of an account that could
# otherwise elevate. Assert the membership instead of inferring it.
#
# AND IT EXPANDS NESTED GROUPS. The previous version read the DIRECT members of
# Administrators only, so an account that is an administrator BY GROUP - a local
# or domain group that is itself a member - passed the guard.
#
# The Gemini CLI recommended doing nothing here, on the uncited claim that SAM
# forbids a local group from containing a local group, which would make the
# direct check sufficient. That claim was not verified, and it is not what this
# check should rest on. Measured on this machine: Administrators holds two Users
# and no groups, and PartOfDomain is False, so the shortcut happens to be safe
# HERE - by accident of configuration, not by argument. Expanding costs a few
# lines and is correct either way, including the day this machine joins a domain.
#
# A group that cannot be expanded is a REFUSAL, not a skip: an unexpandable
# member could be the one that contains the account.
$administrators = @()
try {
    $pending = New-Object System.Collections.Generic.Queue[string]
    $pending.Enqueue("S-1-5-32-544")
    $seenGroups = @{}
    $collected = New-Object System.Collections.Generic.List[string]
    while ($pending.Count -gt 0) {
        $groupSid = $pending.Dequeue()
        if ($seenGroups.ContainsKey($groupSid)) { continue }   # cycles cannot spin this
        $seenGroups[$groupSid] = $true
        foreach ($member in @(Get-LocalGroupMember -SID $groupSid -ErrorAction Stop)) {
            $memberSid = [string]$member.SID.Value
            $collected.Add($memberSid)
            if ([string]$member.ObjectClass -eq "Group") {
                $pending.Enqueue($memberSid)
            }
        }
    }
    $administrators = @($collected)
} catch {
    # FAILS CLOSED, deliberately, and the failure names its own workaround.
    # Get-LocalGroupMember is known to throw on a group containing an
    # unresolvable SID, which happens on domain-joined machines and after a
    # local account is deleted. An adversarial review called that a permanent
    # denial of service for this feature. It is an availability failure in the
    # safe direction, and it did NOT reproduce here - the call returned two
    # members cleanly on 2026-08-16 - so no fallback path is added for a failure
    # mode that has occurred zero times. The message carries the manual check
    # instead, so an operator who hits it is not stuck guessing.
    throw ("cannot read the local Administrators group, so it cannot be established that " +
        "'$UserName' is not an administrator: " + [string]$_ + [Environment]::NewLine +
        "This is a known Get-LocalGroupMember failure when the group holds an unresolvable SID. " +
        "Verify by hand with: net localgroup Administrators" + [Environment]::NewLine +
        "Registration stays refused until it can be established, not waived.")
}
if ($administrators -contains $accountSid) {
    throw ("refusing to register: '$UserName' is a member of the local Administrators group. " +
        "A task running as an administrator is not a containment boundary, whatever RunLevel says.")
}

# Batch logon. Without it the task registers and silently never runs.
$batchLogon = Test-BatchLogonRight -Sid $accountSid -AccountName $UserName
Write-Output ("batch logon right | granted: " + ([string]$batchLogon.granted).ToLowerInvariant() +
    " | denied: " + ([string]$batchLogon.denied).ToLowerInvariant() +
    " | " + $batchLogon.detail)
if (-not $batchLogon.readable) {
    throw ("refusing to register: local policy could not be read, so it cannot be established that " +
        "'$UserName' may log on as a batch job. Without that right the task registers and then " +
        "never runs, silently. " + $batchLogon.detail)
}
if ($batchLogon.denied) {
    throw ("refusing to register: '$UserName' is explicitly DENIED 'Log on as a batch job', which " +
        "overrides any grant. The task would register and never run. Remove the deny entry in " +
        "secpol.msc -> Local Policies -> User Rights Assignment -> Deny log on as a batch job.")
}
if (-not $batchLogon.granted) {
    throw ("refusing to register: '$UserName' does not hold 'Log on as a batch job'. A task whose " +
        "principal supplies a password needs a BATCH logon, so this task would register cleanly, " +
        "report no error when triggered, and never run - measured on this machine 2026-08-16, " +
        "LastTaskResult 0x00041303 SCHED_S_TASK_HAS_NOT_RUN. " + [Environment]::NewLine +
        "GRANT IT YOURSELF, deliberately: secpol.msc -> Local Policies -> User Rights Assignment " +
        "-> 'Log on as a batch job' -> add '$UserName'. This script will not change machine " +
        "security policy on your behalf.")
}

# Review finding 7. The permitted root defaults to the account's OWN profile and
# is checked against it, rather than being whatever a caller passed.
$expectedProfile = ([IO.Path]::GetFullPath((Join-Path "C:\Users" $UserName))).TrimEnd("\")
if ([string]::IsNullOrWhiteSpace($PermittedRoot)) {
    $PermittedRoot = $expectedProfile
}
$PermittedRoot = ([IO.Path]::GetFullPath($PermittedRoot)).TrimEnd("\")
if (-not (Test-PathWithinRoot -Candidate $PermittedRoot -Root $expectedProfile)) {
    throw ("refusing to register: -PermittedRoot '$PermittedRoot' is not inside the account's " +
        "own profile '$expectedProfile'. The fixed action is described everywhere as bounded by " +
        "one tree; it has to actually be that tree.")
}
if (-not (Test-Path -LiteralPath $PermittedRoot -PathType Container)) {
    throw "permitted root does not exist: $PermittedRoot"
}
$rootReparse = @(Get-ReparseSegments -Path $PermittedRoot)
if ($rootReparse.Count -gt 0) {
    throw ("refusing to register: the permitted root traverses a reparse point and therefore " +
        "bounds nothing: " + ($rootReparse -join ", "))
}

if ([string]::IsNullOrWhiteSpace($WorktreePath)) {
    throw ("-WorktreePath is required. The fixed action carries it, because a task that " +
        "accepts a path at trigger time accepts caller input.")
}
$WorktreePath = ([IO.Path]::GetFullPath($WorktreePath)).TrimEnd("\")
if (-not (Test-PathWithinRoot -Candidate $WorktreePath -Root $PermittedRoot)) {
    throw "refusing to register: worktree '$WorktreePath' is outside the permitted root '$PermittedRoot'"
}
if (-not (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
    throw "refusing to register: worktree does not exist: $WorktreePath"
}
$worktreeReparse = @(Get-ReparseSegments -Path $WorktreePath)
if ($worktreeReparse.Count -gt 0) {
    throw ("refusing to register: the worktree path traverses a reparse point, which can " +
        "redirect it outside the permitted root: " + ($worktreeReparse -join ", "))
}

Assert-WrapperOutsideExecutorTree -Wrapper $WrapperPath -Root $PermittedRoot

Write-Output ("registering for " + $UserName + " (SID " + $accountSid + ")")

# The evidence path lives under the restricted account's own profile, because
# that is a place it can write and the operator can read.
$evidencePath = Join-Path $PermittedRoot ".director\launch-evidence.json"
# STALE EVIDENCE READS AS CURRENT. Start-ScheduledTask is asynchronous, so it
# returns before the wrapper has written anything; if a previous run left a
# passing file and the new run fails before reaching the wrapper, the operator
# reads the old file and believes it. Any existing file is removed HERE, at
# registration, so its absence afterwards is itself informative: no file means
# the wrapper never ran. The wrapper stamps generated_utc for the same reason.
#
# AND THIS DELETE IS REPARSE-CHECKED, because without the check it was AN
# ARBITRARY FILE DELETE PRIMITIVE FOR THE RESTRICTED ACCOUNT. These lines were
# added in the previous round to fix the stale-evidence finding, and they run
# ELEVATED against a path inside the tree the account controls. The account
# makes .director a junction pointing at any operator directory, and this
# elevated Remove-Item -Force follows it and deletes the target. A medium
# finding was closed by opening a critical one. Found by the third adversarial
# pass; my own fix, not inherited.
#
# Every other path in these two scripts is reparse-guarded. This one was not,
# because it was written as cleanup rather than as a privileged file operation
# on attacker-controlled ground. It is both.
$stalePathReparse = @(Get-ReparseSegments -Path $evidencePath)
if ($stalePathReparse.Count -gt 0) {
    throw ("refusing to register: the evidence path traverses a reparse point, so deleting " +
        "stale evidence there would follow it out of the permitted root and delete something " +
        "else, elevated: " + ($stalePathReparse -join ", "))
}
if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
    Remove-Item -LiteralPath $evidencePath -Force -ErrorAction Stop
    Write-Output ("removed stale evidence at " + $evidencePath)
}
$arguments = Get-TaskActionArgument -Wrapper $WrapperPath -Root $PermittedRoot `
    -Worktree $WorktreePath -Sid $accountSid -Evidence $evidencePath

# ABSOLUTE PATH, not a bare name. Registering `-Execute "powershell.exe"` leaves
# the binary to be resolved at trigger time by a search order this script does
# not control, in a context where the restricted account controls its own user
# PATH and possibly the working directory. The two consulted CLIs disagreed on
# whether the bare-PATH hijack actually works - Gemini asserted that System32 is
# searched before the user PATH but the WORKING DIRECTORY before System32, with
# no citation and no probe; nothing here measured it. The disagreement does not
# matter, because an absolute path removes the search entirely and costs one
# line. Existence is checked rather than assumed.
$action = New-ScheduledTaskAction -Execute (Get-SystemPowerShellPath) -Argument $arguments
# Review finding 3. LogonType was Interactive, which requires an existing
# interactive logon session for the account - and the whole design triggers this
# on demand while director-exec is not logged on. Password is the type for a
# task registered with a stored credential, and Windows describes it as "log on
# as a batch job".
#
# S4U was considered and rejected. It needs no stored password, which is
# genuinely attractive, but Microsoft documents an S4U task as having no access
# to network resources or encrypted files, and this boundary exists to host an
# executor that must reach a model endpoint. The two CLIs consulted split on
# this - the OpenAI one recommended Password with citations, the Gemini one
# recommended S4U on the assumption that only raw outbound TCP is needed. That
# assumption is not established here, and neither logon type's actual token has
# been measured on this machine, because registration needs elevation.
# RunLevel Limited: the restricted account must never be elevated, and the
# wrapper fails closed if it finds itself elevated anyway.
#
# NO New-ScheduledTaskPrincipal. THE TASK COULD NEVER HAVE REGISTERED WITH ONE.
# A second independent adversarial pass found that the call below combined
# -Principal with -User/-Password, which belong to MUTUALLY EXCLUSIVE parameter
# sets, so binding failed before Task Scheduler was ever reached. Measured on
# this machine rather than taken from the review:
#
#   PS> (Get-Command Register-ScheduledTask).ParameterSets
#   User       ->  Force, Password, User, TaskName, TaskPath, Action,
#                  Description, Settings, Trigger, RunLevel
#   Principal  ->  Force, TaskName, TaskPath, Principal, Action,
#                  Description, Settings, Trigger
#
# The User set carries RunLevel and the Principal set carries no credential, so
# the User set is the only one that can express "run as this account, with this
# password, unelevated". The principal object is gone.
#
# This is the SECOND way this mechanism could never have run, found by the
# SECOND independent pass. The first was a missing -WorktreePath. Both were
# invisible to a self-test that asserted argument shape instead of executing the
# thing, which is why the self-test below now runs the real call.
#
# LOGON TYPE IS NOW IMPLICIT, and that is a real reduction in what this script
# states. Supplying -Password is what selects a password logon; nothing here
# names LogonType any more, and nothing here can confirm what Windows recorded.
# The -Verify path prints the registered LogonType so an operator can read it
# back. Expect Password; if it says something else, that is a finding.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Write-Output "Enter the password for $UserName. It is passed to Windows for this"
Write-Output "registration only, is never written to a file, an argument, or the"
Write-Output "repository, and the executor never receives it."
$securePassword = Read-Host -Prompt "Password for $UserName" -AsSecureString
if ($null -eq $securePassword -or $securePassword.Length -eq 0) {
    throw "empty password; refusing to register"
}
$plain = $null
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        # SPLATTED so the self-test can bind-check the exact same parameter set
        # without registering anything. Get-RegisterParameterNames is the single
        # source of truth for which parameters this call uses.
        $registerArguments = @{
            TaskName = $TaskName
            Action   = $action
            Settings = $settings
            User     = $UserName
            Password = $plain
            RunLevel = "Limited"
            Force    = $true
        }
        foreach ($name in (Get-RegisterParameterNames)) {
            if (-not $registerArguments.ContainsKey($name)) {
                throw "internal: Get-RegisterParameterNames lists '$name' but the call does not supply it"
            }
        }
        if ($registerArguments.Count -ne (Get-RegisterParameterNames).Count) {
            throw "internal: the registration call and Get-RegisterParameterNames have drifted apart"
        }
        # MODULE-QUALIFIED, and the guard above resolves the SAME qualified name.
        # Unqualified, a shadowing function could satisfy Get-Command's metadata
        # check and then receive the actual call. Qualifying both ends means the
        # thing that was validated is the thing that runs.
        ScheduledTasks\Register-ScheduledTask @registerArguments | Out-Null
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
} finally {
    $plain = $null
    $securePassword.Dispose()
    [GC]::Collect()
}

Write-Output ""
Write-Output "registered '$TaskName'."
Write-Output "Trigger it, unelevated, with:"
Write-Output ("  Start-ScheduledTask -TaskName " + $TaskName)
Write-Output "then read the evidence at:"
Write-Output ("  " + $evidencePath)
Write-Output ""
Write-Output "Start-ScheduledTask returns BEFORE the wrapper writes. Any stale evidence"
Write-Output "was deleted just now, so if no file appears, the wrapper did not run - do"
Write-Output "not read an older passing file as this run. Check generated_utc."
Write-Output ""
Write-Output "Registration proves nothing on its own. A triggered run should report:"
Write-Output ("  identity.sid = " + $accountSid)
Write-Output "  wrapper_self_protection.wrapper_writable   = false"
Write-Output "  wrapper_self_protection.directory_writable = false"
Write-Output ""
Write-Output "READ THAT FILE AS A SELF-REPORT, NOT AS PROOF. It is written by a"
Write-Output "process running AS the restricted account, into a directory that"
Write-Output "account controls, so that account can overwrite it with anything it"
Write-Output "likes. An adversarial review raised this and it is accepted rather"
Write-Output "than papered over: a process cannot prove its own containment to an"
Write-Output "outside observer without external infrastructure this repository does"
Write-Output "not have. The evidence is worth reading and is not worth trusting"
Write-Output "against an adversary already resident in the account."
Write-Output "identity.parent_process establishes nothing on its own either."
