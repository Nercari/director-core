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
# Get-ScheduledTask, New-ScheduledTaskAction, New-ScheduledTaskPrincipal,
# New-ScheduledTaskSettingsSet and Register-ScheduledTask are MODULE cmdlets
# (Microsoft.PowerShell.LocalAccounts, ScheduledTasks), not engine built-ins.
# The previous claim that this script was "5.1-safe" was narrower than stated:
# it is 5.1-safe on a Windows install that ships those modules.
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
    try {
        $current = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    } catch {
        return @("<unresolvable: " + $Path + ">")
    }
    for ($depth = 0; $depth -lt 64 -and -not [string]::IsNullOrWhiteSpace($current); $depth++) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and $item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
                $found.Add($current)
            }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
    return @($found)
}

function Test-PathWithinRoot {
    param([string]$Candidate, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Candidate) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }
    $c = ([IO.Path]::GetFullPath($Candidate)).TrimEnd("\").ToLowerInvariant()
    $r = ([IO.Path]::GetFullPath($Root)).TrimEnd("\").ToLowerInvariant()
    return ($c -eq $r) -or $c.StartsWith($r + "\", [StringComparison]::Ordinal)
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
    if (Test-PathWithinRoot -Candidate $Wrapper -Root $Root) {
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
        New-Item -ItemType Directory -Path $worktree -Force | Out-Null
        # A SID this process definitely is not, so a passing identity assertion
        # here would mean the assertion is not enforcing.
        $arguments = Get-TaskActionArgument -Wrapper $WrapperPath -Root $root `
            -Worktree $worktree -Sid "S-1-5-18" -Evidence $evidencePath
        Write-Output ("self-test: registered action | powershell.exe " + $arguments)

        $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments `
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
    } finally {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
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

$account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($null -eq $account) {
    throw "local account '$UserName' does not exist; this script does not create accounts"
}
$accountSid = [string]$account.SID.Value

# Review finding 10. RunLevel Limited does not by itself establish that the
# account is not an administrator: it caps the token of an account that could
# otherwise elevate. Assert the membership instead of inferring it.
$administrators = @()
try {
    $administrators = @(Get-LocalGroupMember -SID "S-1-5-32-544" -ErrorAction Stop |
            ForEach-Object { [string]$_.SID.Value })
} catch {
    throw ("cannot read the local Administrators group, so it cannot be established that " +
        "'$UserName' is not an administrator: " + [string]$_)
}
if ($administrators -contains $accountSid) {
    throw ("refusing to register: '$UserName' is a member of the local Administrators group. " +
        "A task running as an administrator is not a containment boundary, whatever RunLevel says.")
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
$arguments = Get-TaskActionArgument -Wrapper $WrapperPath -Root $PermittedRoot `
    -Worktree $WorktreePath -Sid $accountSid -Evidence $evidencePath

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
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
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Password -RunLevel Limited
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
        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
            -Settings $settings -User $UserName -Password $plain -Force | Out-Null
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
Write-Output "Registration proves nothing on its own. The claim is established only"
Write-Output "when a triggered run reports:"
Write-Output ("  identity.sid = " + $accountSid)
Write-Output "  wrapper_self_protection.wrapper_writable   = false"
Write-Output "  wrapper_self_protection.directory_writable = false"
Write-Output "identity.parent_process is DATA and establishes nothing on its own."
