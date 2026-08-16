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
# Its job right now is to report WHICH ACCOUNT ACTUALLY RAN IT, and to REFUSE if
# that is not the expected account. Executor invocation is deliberately not
# wired in yet: the identity transition is proven first, on its own, or the
# proof is contaminated by whatever the executor does.
#
# REWORKED after an adversarial cross-vendor review of PR #82 found ten defects.
# Three of them are answered here by redesign rather than patched. See the block
# comments on Get-ReparseSegments, Test-SelfReplaceable, and the parent_process
# field in Get-IdentityEvidence.
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$WorktreePath,
    [string]$OutputPath,
    # REQUIRED for a real run. Review finding 2: the previous wrapper RECORDED
    # its SID and required nothing of it, so an operator hand-running it with a
    # valid worktree produced status "completed". Recording is not enforcing.
    # An account NAME is not accepted here, for the reason the restricted
    # account probe already refuses one: names are not authoritative, SIDs are.
    [string]$ExpectedSid,
    # The only tree this account may be pointed at. A worktree outside it is
    # refused rather than measured, because measuring it would normalise the
    # thing the boundary exists to prevent.
    [string]$PermittedRoot = "C:\Users\director-exec"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# THE MODULE PATH IS PINNED TO THE SYSTEM DIRECTORY, BEFORE ANY CMDLET RUNS.
# -NoProfile does not make an unqualified cmdlet name trustworthy. PowerShell
# autoloads modules from every entry in PSModulePath, and a module can export a
# command that shadows a built-in one; the restricted account controls its own
# user module directory. The reviewer's concrete path: a shadowed Split-Path
# that returns C:\Windows for the wrapper's parent would make the
# self-protection probe measure C:\Windows, report directory_writable = false,
# and complete - while the account could still replace the wrapper.
#
# Pinning the path is one line and removes the whole class, rather than
# module-qualifying every call site and hoping none is missed later. Whether a
# task-launched process inherits the account's user module path was the
# reviewer's own stated inference and is NOT verified here; the fix does not
# depend on it being true.
$env:PSModulePath = Join-Path ([Environment]::GetFolderPath("System")) "WindowsPowerShell\v1.0\Modules"

function Get-NormalisedPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    return ([IO.Path]::GetFullPath($Path)).TrimEnd("\").ToLowerInvariant()
}

function Get-ReparseSegments {
    param([AllowNull()][string]$Path)

    # Review finding 5. The old guard was lexical only, so a junction at
    # C:\Users\director-exec\wt pointing at C:\Users\dorot normalised INSIDE the
    # root and returned true. Every existing segment of the path is now
    # inspected and any reparse point is reported.
    #
    # REJECTING a reparse point rather than RESOLVING it is deliberate, and it
    # is the stricter choice. Both consulted CLIs recommended
    # GetFinalPathNameByHandle through P/Invoke; the OpenAI CLI also observed
    # that rejecting every segment "is stricter and safer than accepting a link
    # whose resolved target happens to be inside the root". That is right, and
    # it needs no Add-Type block inside a security-relevant script.
    #
    # What this does NOT solve: the race. A path component can be repointed
    # after this returns, and resolution would have had the same hole. The
    # mitigation is structural and lives in register-exec-task.ps1: the
    # restricted account must not be able to modify the components of its own
    # permitted root.
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
    # Bounded: a malformed path must not spin here.
    for ($depth = 0; $depth -lt 64 -and -not [string]::IsNullOrWhiteSpace($current); $depth++) {
        if (Test-Path -LiteralPath $current) {
            # FAILS CLOSED. The previous version read attributes with
            # -ErrorAction SilentlyContinue and skipped the check when $item came
            # back $null, so any segment whose attributes could not be read was
            # silently accepted as an ordinary directory. An adversarial review
            # called that a fail-open, and it was one. A segment that cannot be
            # inspected is now REPORTED, which fails the caller's check.
            #
            # The reviewer's specific repro - the account denying itself
            # FILE_READ_ATTRIBUTES while keeping traverse - was NOT reproduced:
            # Get-Item on a directory this account cannot read into still
            # returned the item and its attributes. The fail-open path was real
            # whether or not that particular trigger is reachable.
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
    # THE BOUND ALSO FAILED OPEN. Stopping at 64 levels returned an empty list,
    # indistinguishable from "walked the whole path and found nothing", so more
    # than 64 components followed by a junction would have been accepted. A walk
    # that never reached the root is now REPORTED.
    if (-not $reachedRoot) {
        $found.Add("<walk incomplete past 64 levels: " + $Path + ">")
    }
    return @($found)
}

function Test-PathWithinRoot {
    param([string]$Candidate, [string]$Root)
    $c = Get-NormalisedPath $Candidate
    $r = Get-NormalisedPath $Root
    if ([string]::IsNullOrWhiteSpace($c) -or [string]::IsNullOrWhiteSpace($r)) {
        return $false
    }
    # Segment-aware: "C:\a\bc" must not match root "C:\a\b".
    $lexicallyInside = ($c -eq $r) -or $c.StartsWith($r + "\", [StringComparison]::Ordinal)
    if (-not $lexicallyInside) {
        return $false
    }
    # And no reparse point anywhere on either path. Fails closed.
    return (@(Get-ReparseSegments -Path $Candidate).Count -eq 0) -and
           (@(Get-ReparseSegments -Path $Root).Count -eq 0)
}

function Test-SelfReplaceable {
    param([string]$WrapperPath)

    # Review finding 4. The previous check lived in the REGISTRATION script and
    # matched ACE identity strings with a regex, against Allow ACEs only. It
    # missed access granted through group membership, ownership (an owner can
    # rewrite the DACL), deny-ACE precedence, inheritance, and the containing
    # DIRECTORY - where Delete or CreateFiles lets the account replace the
    # wrapper wholesale without ever writing to the file.
    #
    # It is replaced by a MEASURED OPERATION, performed by the account that
    # matters, at the only moment that account is running: here. Same primitive
    # as scripts/restricted-account-probe.ps1 - open for write with
    # FileMode.Open, write nothing, close. That is this repository's standing
    # preference over an effective-access query, and here is why: on 2026-08-15
    # an ACL that read as reasonable turned out to be a stale grant, and only an
    # attempt found it.
    #
    # Measured 2026-08-16, because it would otherwise mask every result:
    # PowerShell does NOT hold a write lock on the script it is executing. A
    # refusal here is an access denial, not a sharing violation.
    $result = [ordered]@{
        wrapper_path = [string]$WrapperPath
        wrapper_writable = $false
        wrapper_detail = ""
        directory = ""
        directory_writable = $false
        directory_detail = ""
        method = "open the wrapper for write with FileMode.Open and no bytes written; create and delete one file in its directory"
        inconclusive = $false
    }
    if ([string]::IsNullOrWhiteSpace($WrapperPath) -or -not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) {
        $result.inconclusive = $true
        $result.wrapper_detail = "wrapper path is not a readable file; nothing was measured"
        return $result
    }

    $stream = $null
    try {
        $stream = [IO.File]::Open($WrapperPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $result.wrapper_writable = $true
        $result.wrapper_detail = "opened for write"
    } catch {
        $reason = $_.Exception
        while ($null -ne $reason.InnerException) { $reason = $reason.InnerException }
        $typeName = $reason.GetType().Name
        $result.wrapper_detail = $typeName + ": " + $reason.Message
        # Only an access denial is a refusal. Anything else proves nothing and
        # must not be scored as containment.
        if ($typeName -notin @("UnauthorizedAccessException", "SecurityException")) {
            $result.inconclusive = $true
        }
        # A READ-ONLY ATTRIBUTE IS NOT CONTAINMENT. Measured 2026-08-16: the DOS
        # ReadOnly attribute throws the same UnauthorizedAccessException an ACL
        # denial throws, AND the account that set it can strip it again. So an
        # account WITH write access could set ReadOnly, let this report the
        # wrapper protected, strip it, and rewrite the wrapper. Inconclusive,
        # which fails the run. The attribute is read, never stripped: stripping
        # it would mutate the thing being measured. Same fix as the sibling
        # change in scripts/restricted-account-probe.ps1, same finding.
        try {
            if (([IO.File]::GetAttributes($WrapperPath)).HasFlag([IO.FileAttributes]::ReadOnly)) {
                $result.inconclusive = $true
                $result.wrapper_detail = "READONLY ATTRIBUTE SET, so the refusal cannot be attributed to the ACL: " + $result.wrapper_detail
            }
        } catch {
            $result.inconclusive = $true
            $result.wrapper_detail = "could not read the wrapper's attributes, so the refusal cannot be attributed: " + $result.wrapper_detail
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $directory = Split-Path -Parent $WrapperPath
    $result.directory = [string]$directory
    $probe = Join-Path $directory ("director-wrapper-dir-probe-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllText($probe, "director wrapper directory probe")
        $result.directory_writable = $true
        $result.directory_detail = "created a file beside the wrapper"
    } catch {
        $reason = $_.Exception
        while ($null -ne $reason.InnerException) { $reason = $reason.InnerException }
        $typeName = $reason.GetType().Name
        $result.directory_detail = $typeName + ": " + $reason.Message
        if ($typeName -notin @("UnauthorizedAccessException", "SecurityException")) {
            $result.inconclusive = $true
        }
    } finally {
        if (Test-Path -LiteralPath $probe -PathType Leaf) {
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $probe -PathType Leaf) {
                $result.directory_detail += "; PROBE ARTIFACT NOT REMOVED: " + $probe
            }
        }
    }
    return $result
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
        # ABSOLUTE PATH, not a bare name. The restricted account controls its own
        # user PATH, so `& whoami.exe` would let it place a fake whoami.exe ahead
        # of the real one and write whatever integrity level it liked into the
        # evidence. Found by adversarial review. The hijack itself is not
        # demonstrated here; a bare executable name in a security-relevant script
        # has no defence either way.
        $whoamiPath = Join-Path ([Environment]::GetFolderPath("System")) "whoami.exe"
        if (-not (Test-Path -LiteralPath $whoamiPath -PathType Leaf)) {
            throw "whoami.exe is not at its system path: $whoamiPath"
        }
        $labelLine = & $whoamiPath /groups 2>$null | Select-String -Pattern "S-1-16-" | Select-Object -First 1
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
        # THE CATCH USED TO READ $_.Value AND THAT KILLED THE WHOLE RUN. Inside
        # a ForEach-Object catch block, $_ is the ErrorRecord, not the group, so
        # the fallback read a property that does not exist - and under
        # Set-StrictMode -Version Latest that throws a second exception. One
        # untranslatable group SID in the token, which is an ordinary condition
        # on a domain-joined machine or after an account is deleted, and the
        # wrapper died before producing any evidence at all.
        #
        # The sibling scripts/restricted-account-probe.ps1 has always had this
        # right, using a named loop variable. This is the same code with the
        # same intent and it was wrong here for three review rounds.
        groups = @($current.Groups | ForEach-Object {
                $groupSid = $_
                try {
                    $groupSid.Translate([Security.Principal.NTAccount]).Value
                } catch {
                    [string]$groupSid.Value
                }
            } | Sort-Object)
        pid = $PID
        parent_pid = $parentId
        # Review finding 6. The comment that used to sit here claimed this field
        # distinguished a task-triggered run from a hand-run wrapper. It does
        # not. The claim is WITHDRAWN rather than strengthened: a process name is
        # trivially reproducible, and nothing inside a process can establish its
        # own provenance.
        #
        # The OpenAI CLI proposed correlating against the scheduler's own
        # Microsoft-Windows-TaskScheduler/Operational log, which is written by an
        # external service and would therefore be stronger. Measured 2026-08-16
        # on this machine: `wevtutil gl` reports that channel `enabled: false`.
        # It records nothing, so there is nothing to correlate against. Its
        # channelAccess does grant BATCH read - `(A;;0x3;;;S-1-5-3)` - so a
        # task-triggered run could read it if an operator enabled the channel.
        # That is an operator decision and nothing here depends on it.
        #
        # This field is retained as DATA, and labelled as data. It is not
        # evidence of anything.
        parent_process = $parentName
        parent_process_establishes_provenance = $false
        process_name = [string]$process.ProcessName
        cwd = (Get-Location).Path
        user_profile = [string][Environment]::GetEnvironmentVariable("USERPROFILE", "Process")
    }
}

function New-LaunchEvidence {
    param(
        [string]$Worktree,
        [string]$Root,
        [AllowNull()][string]$RequiredSid,
        [string]$WrapperPath
    )

    $identity = Get-IdentityEvidence
    $failures = New-Object System.Collections.Generic.List[string]

    # Review finding 2: assert, do not merely record.
    $sidMatches = (
        -not [string]::IsNullOrWhiteSpace($RequiredSid) -and
        -not [string]::IsNullOrWhiteSpace($identity.sid) -and
        ([string]$identity.sid) -ieq ([string]$RequiredSid)
    )
    if ([string]::IsNullOrWhiteSpace($RequiredSid)) {
        $failures.Add("-ExpectedSid is required; a wrapper that records its account without requiring one proves nothing")
    } elseif (-not $sidMatches) {
        $failures.Add("this process is running as SID '" + $identity.sid +
            "', not the required '" + $RequiredSid + "'")
    }

    $rootReparse = @(Get-ReparseSegments -Path $Root)
    $worktreeReparse = @(Get-ReparseSegments -Path $Worktree)
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
    if ($rootReparse.Count -gt 0) {
        $failures.Add("permitted root traverses a reparse point, so it cannot bound anything: " + ($rootReparse -join ", "))
    }
    if ($worktreeReparse.Count -gt 0) {
        $failures.Add("worktree path traverses a reparse point, which can redirect it outside the permitted root: " + ($worktreeReparse -join ", "))
    }
    if ($identity.is_elevated) {
        $failures.Add("wrapper is running elevated; the restricted account must not be an administrator")
    }
    # INTEGRITY IS NOW CHECKED, NOT JUST RECORDED. It was collected, printed, and
    # never validated, so a run whose label could not be read at all reported
    # status "completed". That is the same defect as recording a SID without
    # requiring one, in a field that exists precisely to show the token is not
    # privileged.
    if ($identity.integrity_level -in @("unknown", "unavailable")) {
        $failures.Add("integrity level could not be determined ('" + $identity.integrity_level +
            "'), so this run cannot show it is unprivileged")
    } elseif ($identity.integrity_level -notin @("low", "medium")) {
        $failures.Add("integrity level is '" + $identity.integrity_level +
            "'; the restricted account must run at low or medium")
    }

    $selfProtection = Test-SelfReplaceable -WrapperPath $WrapperPath
    if ($selfProtection.inconclusive) {
        $failures.Add("wrapper self-protection check was INCONCLUSIVE: " +
            $selfProtection.wrapper_detail + " / " + $selfProtection.directory_detail)
    }
    if ($selfProtection.wrapper_writable) {
        $failures.Add("this account can open the wrapper for writing, so it can run its own code with the task's blessing: " + $selfProtection.wrapper_path)
    }
    if ($selfProtection.directory_writable) {
        $failures.Add("this account can create files beside the wrapper, so it can replace the wrapper wholesale: " + $selfProtection.directory)
    }

    return [ordered]@{
        schema_version = "director.restricted-launch-evidence.v2"
        ticket = 59
        generated_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = $(if ($failures.Count -eq 0) { "completed" } else { "failed" })
        expected_sid = [string]$RequiredSid
        identity = $identity
        identity_checks = [ordered]@{
            sid_matches_expected = $sidMatches
            not_elevated = (-not $identity.is_elevated)
        }
        worktree = [ordered]@{
            requested = [string]$Worktree
            permitted_root = [string]$Root
            within_permitted_root = $withinRoot
            exists = $exists
            reparse_segments_in_worktree = @($worktreeReparse)
            reparse_segments_in_root = @($rootReparse)
        }
        wrapper_self_protection = $selfProtection
        executor = [ordered]@{
            invoked = $false
            note = "identity transition is proven on its own before any executor runs; see docs/adr/0001-restricted-account-launch.md"
        }
        failures = @($failures)
    }
}

function New-IncompleteEvidence {
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [AllowNull()][string]$RequiredSid
    )

    # A separate function purely so the self-test can exercise it with a real
    # caught error. Inline in the catch it was untestable, which is the same
    # fault as every other check in this file that was asserted rather than run.
    $reason = $ErrorRecord.Exception
    while ($null -ne $reason.InnerException) { $reason = $reason.InnerException }
    return [ordered]@{
        schema_version = "director.restricted-launch-evidence.v2"
        ticket = 59
        generated_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = "incomplete"
        expected_sid = [string]$RequiredSid
        incomplete_reason = ($reason.GetType().Name + ": " + $reason.Message)
        incomplete_at = [string]$ErrorRecord.InvocationInfo.PositionMessage
        # Deliberately minimal. Anything gathered here would be gathered by the
        # same code that just threw, so it is not trustworthy and is not
        # collected. This record says WHERE the run died; it does not stand in
        # for evidence that was never produced.
        identity = [ordered]@{
            user = [string]([Security.Principal.WindowsIdentity]::GetCurrent().Name)
            sid = [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        }
        failures = @("the wrapper threw before it could reach a verdict; this record is NOT a containment result")
    }
}

function Invoke-SelfTest {
    # Runs without administrative rights, without the scheduled task, and
    # without the director-exec account existing. It proves the path guard, the
    # identity assertion, the self-protection primitive, and the evidence shape.
    # It CANNOT prove the account switch, and says so.
    $failures = New-Object System.Collections.Generic.List[string]
    $wrapperPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($wrapperPath)) {
        $wrapperPath = $MyInvocation.MyCommand.Path
    }

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

    # Review finding 5, exercised against a REAL junction rather than argued
    # about. The lexical half of the guard passes this case; the reparse half
    # must overrule it.
    $junctionRoot = Join-Path ([IO.Path]::GetTempPath()) ("director-junc-" + [guid]::NewGuid().ToString("N"))
    $junctionEscape = Join-Path ([IO.Path]::GetTempPath()) ("director-escape-" + [guid]::NewGuid().ToString("N"))
    $junctionLink = Join-Path $junctionRoot "wt"
    $junctionMade = $false
    try {
        New-Item -ItemType Directory -Path $junctionRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $junctionEscape -Force | Out-Null
        # mklink /J needs no privilege. New-Item -ItemType Junction is not
        # available on every 5.1 build, so cmd is used, and whether the link was
        # actually created is measured rather than assumed.
        & $env:ComSpec /c ('mklink /J "' + $junctionLink + '" "' + $junctionEscape + '"') 2>&1 | Out-Null
        $junctionMade = (Test-Path -LiteralPath $junctionLink)
        if (-not $junctionMade) {
            Write-Output "self-test: junction escape NOT exercised - mklink /J did not create the link on this machine"
            $failures.Add("the junction escape case could not be exercised, so the reparse guard is unverified here")
        } else {
            $guarded = Test-PathWithinRoot -Candidate $junctionLink -Root $junctionRoot
            $segments = @(Get-ReparseSegments -Path $junctionLink)
            if ($guarded) {
                $failures.Add("a junction inside the root was accepted; the reparse guard did not fire")
            }
            if ($segments.Count -lt 1) {
                $failures.Add("Get-ReparseSegments did not report a junction it was pointed straight at")
            }
            Write-Output ("self-test: junction escape | link: " + $junctionLink +
                " | guard allows: " + ([string]$guarded).ToLowerInvariant() +
                " | reparse segments found: " + $segments.Count)
        }
    } catch {
        $failures.Add("junction self-test threw: " + [string]$_)
    } finally {
        if ($junctionMade) {
            & $env:ComSpec /c ('rmdir "' + $junctionLink + '"') 2>&1 | Out-Null
        }
        foreach ($path in @($junctionRoot, $junctionEscape)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # The self-protection primitive. No verdict is asserted about THIS machine:
    # the operator owns these scripts and should be able to write them. What is
    # asserted is that the check ran and reached a definite answer, because an
    # inconclusive result is the failure mode that would silently pass.
    $selfProtection = Test-SelfReplaceable -WrapperPath $wrapperPath
    if ($selfProtection.inconclusive) {
        $failures.Add("self-protection check was inconclusive against its own wrapper: " +
            $selfProtection.wrapper_detail + " / " + $selfProtection.directory_detail)
    }
    if ($selfProtection.directory_detail -match "PROBE ARTIFACT NOT REMOVED") {
        $failures.Add("self-protection directory probe left an artifact behind")
    }
    Write-Output ("self-test: self-protection | wrapper writable: " + ([string]$selfProtection.wrapper_writable).ToLowerInvariant() +
        " | directory writable: " + ([string]$selfProtection.directory_writable).ToLowerInvariant() +
        " | inconclusive: " + ([string]$selfProtection.inconclusive).ToLowerInvariant() +
        " | " + $selfProtection.wrapper_detail)

    # A READ-ONLY file must NOT be scored as protected. This is the masking
    # attack the adversarial review found: set the attribute, let the check
    # report the wrapper safe, strip the attribute, rewrite the wrapper. Both
    # halves were measured on this machine - the attribute throws the same
    # UnauthorizedAccessException an ACL denial throws, and the account that
    # sets it can strip it again. Exercised against a file the self-test makes,
    # so this does not depend on the machine or on elevation.
    $roDirectory = Join-Path ([IO.Path]::GetTempPath()) ("director-ro-" + [guid]::NewGuid().ToString("N"))
    $roFile = Join-Path $roDirectory "pretend-wrapper.ps1"
    try {
        New-Item -ItemType Directory -Path $roDirectory -Force | Out-Null
        [IO.File]::WriteAllText($roFile, "# pretend wrapper")
        [IO.File]::SetAttributes($roFile, [IO.FileAttributes]::ReadOnly)
        $roVerdict = Test-SelfReplaceable -WrapperPath $roFile
        if ($roVerdict.wrapper_writable) {
            $failures.Add("a read-only file was reported writable, so the open-for-write probe is not measuring what it claims")
        }
        if (-not $roVerdict.inconclusive) {
            $failures.Add("a READ-ONLY ATTRIBUTE was accepted as protection; the account that sets it can strip it again, so this is a false containment pass")
        }
        Write-Output ("self-test: read-only is not protection | writable: " + ([string]$roVerdict.wrapper_writable).ToLowerInvariant() +
            " | inconclusive: " + ([string]$roVerdict.inconclusive).ToLowerInvariant() +
            " | " + $roVerdict.wrapper_detail)
    } finally {
        if (Test-Path -LiteralPath $roFile -PathType Leaf) {
            try { [IO.File]::SetAttributes($roFile, [IO.FileAttributes]::Normal) } catch { }
        }
        if (Test-Path -LiteralPath $roDirectory) {
            Remove-Item -LiteralPath $roDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $roDirectory) {
            $failures.Add("the read-only self-test could not remove its own temporary directory: " + $roDirectory)
        }
    }

    $evidence = New-LaunchEvidence -Worktree "" -Root "C:\Users\director-exec" -RequiredSid "" -WrapperPath $wrapperPath
    foreach ($field in @("schema_version", "identity", "identity_checks", "worktree", "wrapper_self_protection", "failures", "status")) {
        if (-not $evidence.Contains($field)) {
            $failures.Add("evidence is missing required field '$field'")
        }
    }
    if ($evidence.status -ne "failed") {
        $failures.Add("evidence with no worktree should fail closed")
    }
    if (-not ((@($evidence.failures) -join "; ").Contains("-ExpectedSid is required"))) {
        $failures.Add("a run with no -ExpectedSid must fail for that reason and did not")
    }
    Write-Output ("self-test: fails closed with no worktree and no expected SID | status: " + $evidence.status)

    # Review finding 2, exercised: a SID this process definitely does not have
    # must be refused. S-1-5-18 is LocalSystem.
    $wrongSid = New-LaunchEvidence -Worktree "" -Root "C:\Users\director-exec" -RequiredSid "S-1-5-18" -WrapperPath $wrapperPath
    if ($wrongSid.identity_checks.sid_matches_expected) {
        $failures.Add("the identity assertion accepted a SID this process does not have")
    }
    if (-not ((@($wrongSid.failures) -join "; ").Contains("not the required"))) {
        $failures.Add("a SID mismatch must be named in the failures and was not")
    }
    Write-Output ("self-test: identity assertion is enforcing | required S-1-5-18 | matched: " +
        ([string]$wrongSid.identity_checks.sid_matches_expected).ToLowerInvariant())

    # And the converse. Without this, a check that refuses EVERYTHING would look
    # correct here while being useless in the registered task.
    $ownSid = [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $rightSid = New-LaunchEvidence -Worktree "" -Root "C:\Users\director-exec" -RequiredSid $ownSid -WrapperPath $wrapperPath
    if (-not $rightSid.identity_checks.sid_matches_expected) {
        $failures.Add("the identity assertion rejected this process's own SID, so it refuses everything")
    }
    Write-Output ("self-test: identity assertion accepts the true SID | " + $ownSid + " | matched: " +
        ([string]$rightSid.identity_checks.sid_matches_expected).ToLowerInvariant())

    Write-Output ("self-test: reports its own token | user: " + $evidence.identity.user + " | sid: " + $evidence.identity.sid + " | integrity: " + $evidence.identity.integrity_level)
    Write-Output ("self-test: parent process recorded as DATA, not provenance | parent: " + $evidence.identity.parent_process +
        " | establishes provenance: " + ([string]$evidence.identity.parent_process_establishes_provenance).ToLowerInvariant())
    # The incomplete path, exercised with a REAL caught error rather than
    # described. On 2026-08-16 the registered task produced no file at all and
    # the absence could not distinguish "never launched" from "crashed" from
    # "declined to write". This record exists so that never happens silently
    # again, and these assertions exist so the record is not itself a fiction.
    $incomplete = $null
    try {
        throw "synthetic failure for the incomplete-evidence self-test"
    } catch {
        $incomplete = New-IncompleteEvidence -ErrorRecord $_ -RequiredSid "S-1-5-18"
    }
    if ($incomplete.status -ne "incomplete") {
        $failures.Add("a run that threw produced status '" + $incomplete.status + "' instead of 'incomplete'")
    }
    if ($incomplete.status -eq "completed") {
        $failures.Add("a run that threw reported COMPLETED; incomplete must never be readable as success")
    }
    if (-not ([string]$incomplete.incomplete_reason).Contains("synthetic failure")) {
        $failures.Add("the incomplete record did not carry the reason it was incomplete")
    }
    if (@($incomplete.failures).Count -lt 1) {
        $failures.Add("the incomplete record carried no failures entry saying it is not a containment result")
    }
    Write-Output ("self-test: incomplete evidence | status: " + $incomplete.status +
        " | reason: " + $incomplete.incomplete_reason)
    Write-Output "self-test: three states are completed / failed / incomplete - a consumer must require 'completed', never file existence"

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

$selfPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($selfPath)) {
    $selfPath = $MyInvocation.MyCommand.Path
}

# EVIDENCE IS NOW WRITTEN ON THE FAILURE PATH TOO, and the reason is measured
# rather than theoretical. On 2026-08-16 the registered task produced NOTHING -
# no directory, no file, no output - and the absence was indistinguishable
# between "never launched", "launched and crashed", and "ran and declined to
# write". It turned out to be the first, but nothing in this script could have
# told anyone that.
#
# The old shape guaranteed that ambiguity: $ErrorActionPreference = "Stop" plus
# Set-StrictMode -Version Latest means ANY throw anywhere skips the write at the
# bottom of the file, so the one artefact a reader depends on is exactly the
# thing that disappears when something goes wrong.
#
# THREE STATES, not two. "completed" means every check passed. "failed" means the
# checks ran and some did not pass - a real verdict. "incomplete" means the run
# died before it could reach a verdict, which is NOT a verdict and must never be
# read as one. A consumer must require status = "completed"; the presence of the
# file has never meant success and now cannot be mistaken for it.
$evidence = $null
try {
    $evidence = New-LaunchEvidence -Worktree $WorktreePath -Root $PermittedRoot -RequiredSid $ExpectedSid -WrapperPath $selfPath
} catch {
    $evidence = New-IncompleteEvidence -ErrorRecord $_ -RequiredSid $ExpectedSid
}

$json = $evidence | ConvertTo-Json -Depth 6
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # THE EVIDENCE PATH GETS THE SAME REPARSE GUARD AS EVERY OTHER PATH. It did
    # not, and the account owns the tree it lives in: making .director a junction
    # to somewhere else redirected Set-Content out of the permitted root while
    # every other check still passed, because nothing ever inspected this path.
    # Refusing to write is the correct failure - the run's exit code still
    # reports the verdict, and a missing file now means something went wrong
    # rather than nothing happening.
    $outputReparse = @(Get-ReparseSegments -Path $OutputPath)
    if ($outputReparse.Count -gt 0) {
        Write-Output ("REFUSING to write evidence: its path traverses a reparse point and could " +
            "be redirected outside the permitted root: " + ($outputReparse -join ", "))
        exit 1
    }
    Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8
}
Write-Output $json
exit $(if ($evidence.status -eq "completed") { 0 } else { 1 })
