# exec-task-wrapper - the fixed action of the restricted-account scheduled task.
#
# ASCII only, deliberately. Windows PowerShell 5.1 reads a UTF-8 file with no
# BOM as ANSI, so a single multi-byte character here is a parse error under the
# engine this actually runs on, while PowerShell 7 accepts it. Measured
# 2026-08-15: two em dashes in this file broke 5.1 and not 7.
# ADR docs/adr/0001-restricted-account-launch.md. Issue #59, criteria 3 and 4.
#
# This script takes NO caller-supplied command, and that is the whole point. A
# task that runs an arbitrary command line as director-exec is not a containment
# mechanism, it is a privilege-launch mechanism for anyone able to trigger it.
#
# Its job right now is to report WHICH ACCOUNT ACTUALLY RAN IT. The process
# reports its own token rather than the caller reporting what it intended, which
# is what criterion 4 asks for and what a logon record cannot establish.
# Executor invocation is deliberately not wired in yet: the identity transition
# is proven first, on its own, or the proof is contaminated by whatever the
# executor does.
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$WorktreePath,
    [string]$OutputPath,
    # The only tree this account may be pointed at. A worktree outside it is
    # refused rather than measured, because measuring it would normalise the
    # thing the boundary exists to prevent.
    [string]$PermittedRoot = "C:\Users\director-exec"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalisedPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    return ([IO.Path]::GetFullPath($Path)).TrimEnd("\").ToLowerInvariant()
}

function Test-PathWithinRoot {
    param([string]$Candidate, [string]$Root)
    $c = Get-NormalisedPath $Candidate
    $r = Get-NormalisedPath $Root
    if ([string]::IsNullOrWhiteSpace($c) -or [string]::IsNullOrWhiteSpace($r)) {
        return $false
    }
    # Segment-aware: "C:\a\bc" must not match root "C:\a\b".
    return ($c -eq $r) -or $c.StartsWith($r + "\", [StringComparison]::Ordinal)
}

function Get-IdentityEvidence {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $process = Get-Process -Id $PID
    $parentId = $null
    $parentName = ""
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        $parentId = [int]$cim.ParentProcessId
        $parent = Get-Process -Id $parentId -ErrorAction SilentlyContinue
        if ($null -ne $parent) {
            $parentName = [string]$parent.ProcessName
        }
    } catch {
        $parentName = "unavailable"
    }
    # The mandatory label comes from whoami. Two in-process routes were tried
    # first and both returned nothing on this system: WindowsIdentity.Claims,
    # and scanning WindowsIdentity.Groups for an S-1-16-* SID. Each left this
    # field reading "unknown", which is worse than not having it. whoami is
    # also what the restricted-account probe already uses for identity, so this
    # agrees with the evidence it will be read beside.
    $integrity = "unknown"
    try {
        $labelLine = & whoami.exe /groups 2>$null | Select-String -Pattern "S-1-16-" | Select-Object -First 1
        if ($null -ne $labelLine -and [string]$labelLine -match "S-1-16-(\d+)") {
            $integrity = switch ($Matches[1]) {
                "0" { "untrusted" }
                "4096" { "low" }
                "8192" { "medium" }
                "8448" { "medium plus" }
                "12288" { "high" }
                "16384" { "system" }
                default { "S-1-16-" + $Matches[1] }
            }
        }
    } catch {
        $integrity = "unavailable"
    }
    return [ordered]@{
        user = [string]$current.Name
        sid = [string]$current.User.Value
        integrity_level = $integrity
        is_elevated = ([Security.Principal.WindowsPrincipal]::new($current)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        groups = @($current.Groups | ForEach-Object {
                try { $_.Translate([Security.Principal.NTAccount]).Value } catch { $_.Value }
            } | Sort-Object)
        pid = $PID
        parent_pid = $parentId
        # Expected to be the Task Scheduler service, not the operator's shell.
        # This is what distinguishes a triggered task run from someone simply
        # running the wrapper by hand.
        parent_process = $parentName
        process_name = [string]$process.ProcessName
        cwd = (Get-Location).Path
        user_profile = [string][Environment]::GetEnvironmentVariable("USERPROFILE", "Process")
    }
}

function New-LaunchEvidence {
    param([string]$Worktree, [string]$Root)

    $identity = Get-IdentityEvidence
    $failures = New-Object System.Collections.Generic.List[string]

    $withinRoot = Test-PathWithinRoot -Candidate $Worktree -Root $Root
    $exists = (-not [string]::IsNullOrWhiteSpace($Worktree)) -and (Test-Path -LiteralPath $Worktree -PathType Container)
    if ([string]::IsNullOrWhiteSpace($Worktree)) {
        $failures.Add("no worktree was supplied")
    } else {
        if (-not $withinRoot) {
            $failures.Add("worktree is outside the permitted root '$Root'")
        }
        if (-not $exists) {
            $failures.Add("worktree does not exist or is not a directory")
        }
    }
    if ($identity.is_elevated) {
        $failures.Add("wrapper is running elevated; the restricted account must not be an administrator")
    }

    return [ordered]@{
        schema_version = "director.restricted-launch-evidence.v1"
        ticket = 59
        generated_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = $(if ($failures.Count -eq 0) { "completed" } else { "failed" })
        identity = $identity
        worktree = [ordered]@{
            requested = [string]$Worktree
            permitted_root = [string]$Root
            within_permitted_root = $withinRoot
            exists = $exists
        }
        executor = [ordered]@{
            invoked = $false
            note = "identity transition is proven on its own before any executor runs; see docs/adr/0001-restricted-account-launch.md"
        }
        failures = @($failures)
    }
}

function Invoke-SelfTest {
    # Runs without administrative rights, without the scheduled task, and
    # without the director-exec account existing. It proves the path guard and
    # the evidence shape only. It CANNOT prove the account switch, and says so.
    $failures = New-Object System.Collections.Generic.List[string]

    $cases = @(
        @{ candidate = "C:\Users\director-exec\wt";        root = "C:\Users\director-exec"; expected = $true },
        @{ candidate = "C:\Users\director-exec";           root = "C:\Users\director-exec"; expected = $true },
        @{ candidate = "C:\Users\director-exec-evil\wt";   root = "C:\Users\director-exec"; expected = $false },
        @{ candidate = "C:\Users\dorot\Documents";         root = "C:\Users\director-exec"; expected = $false },
        @{ candidate = "C:\Users\director-exec\..\dorot";  root = "C:\Users\director-exec"; expected = $false },
        @{ candidate = "";                                 root = "C:\Users\director-exec"; expected = $false }
    )
    foreach ($case in $cases) {
        $actual = Test-PathWithinRoot -Candidate $case.candidate -Root $case.root
        $verdict = $(if ($actual -eq $case.expected) { "OK" } else { "FAIL" })
        if ($actual -ne $case.expected) {
            $failures.Add("path guard: '$($case.candidate)' returned $actual, expected $($case.expected)")
        }
        Write-Output ("self-test: path guard | candidate: '" + $case.candidate + "' | within '" + $case.root + "': " + ([string]$actual).ToLowerInvariant() + " | " + $verdict)
    }

    $evidence = New-LaunchEvidence -Worktree "" -Root "C:\Users\director-exec"
    foreach ($field in @("schema_version", "identity", "worktree", "failures", "status")) {
        if (-not $evidence.Contains($field)) {
            $failures.Add("evidence is missing required field '$field'")
        }
    }
    if ($evidence.status -ne "failed") {
        $failures.Add("evidence with no worktree should fail closed")
    }
    Write-Output ("self-test: fails closed with no worktree | status: " + $evidence.status)
    Write-Output ("self-test: reports its own token | user: " + $evidence.identity.user + " | sid: " + $evidence.identity.sid + " | integrity: " + $evidence.identity.integrity_level + " | parent: " + $evidence.identity.parent_process)
    Write-Output "self-test: does NOT establish the account switch - that needs the registered task, and the operator to register it"

    if ($failures.Count -eq 0) {
        Write-Output "exec-task-wrapper self-test PASSED"
        exit 0
    }
    Write-Output ("exec-task-wrapper self-test FAILED: " + ($failures -join "; "))
    exit 1
}

if ($SelfTest) {
    Invoke-SelfTest
}

$evidence = New-LaunchEvidence -Worktree $WorktreePath -Root $PermittedRoot
$json = $evidence | ConvertTo-Json -Depth 6
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
}
Write-Output $json
exit $(if ($evidence.status -eq "completed") { 0 } else { 1 })
