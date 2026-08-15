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
[CmdletBinding()]
param(
    [string]$TaskName = "director-exec-launch",
    [string]$UserName = "director-exec",
    # Resolved after the param block, not in it: $PSScriptRoot is not populated
    # inside a param default under Windows PowerShell 5.1.
    [string]$WrapperPath = "",
    [string]$PermittedRoot = "C:\Users\director-exec",
    [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-WrapperNotWritableByExecutor {
    param([string]$Path, [string]$Account)

    # If the restricted account can modify the wrapper, it can run its own code
    # as itself with the task's blessing, and the containment claim is void.
    # This REFUSES rather than fixing the ACL: silently widening or narrowing
    # permissions on a security-relevant file is the operator's call, and a
    # refusal is measurable while a silent mutation is not.
    $writeRights = @("Write", "Modify", "FullControl", "WriteData", "CreateFiles", "TakeOwnership", "ChangePermissions")
    $offending = @()
    foreach ($ace in (Get-Acl -LiteralPath $Path).Access) {
        if ($ace.AccessControlType -ne "Allow") { continue }
        $who = [string]$ace.IdentityReference
        if ($who -notmatch [regex]::Escape($Account)) { continue }
        foreach ($right in $writeRights) {
            if (([string]$ace.FileSystemRights) -match $right) {
                $offending += ("$who : " + $ace.FileSystemRights)
                break
            }
        }
    }
    if ($offending.Count -gt 0) {
        throw ("refusing to register: '$Account' can modify the wrapper at $Path (" +
            ($offending -join "; ") + "). Remove that grant, then re-run. " +
            "A wrapper the executor can rewrite is a privilege-launch mechanism, not a boundary.")
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
    Write-Output "wrapper writes: the account that ran is whatever identity.sid says,"
    Write-Output "and identity.parent_process should be the Task Scheduler service"
    Write-Output "rather than an operator shell."
    exit 0
}

if (-not (Test-Elevated)) {
    throw "registration requires an elevated session. Triggering the task afterwards does not."
}

Assert-WrapperNotWritableByExecutor -Path $WrapperPath -Account $UserName

$account = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($null -eq $account) {
    throw "local account '$UserName' does not exist; this script does not create accounts"
}
Write-Output ("registering for " + $UserName + " (SID " + $account.SID.Value + ")")

# The evidence path lives under the restricted account's own profile, because
# that is a place it can write and the operator can read.
$evidencePath = Join-Path $PermittedRoot ".director\launch-evidence.json"
$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", ('"' + $WrapperPath + '"'),
    "-PermittedRoot", ('"' + $PermittedRoot + '"'),
    "-OutputPath", ('"' + $evidencePath + '"')
) -join " "

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
# Interactive logon type so the task can be triggered on demand and its process
# is a normal one. RunLevel Limited: the restricted account must never be
# elevated, and the wrapper fails closed if it finds itself elevated anyway.
$principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
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
Write-Output "when a triggered run reports identity.sid = $($account.SID.Value)"
Write-Output "with identity.parent_process naming the Task Scheduler service."
