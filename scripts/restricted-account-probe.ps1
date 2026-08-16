[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$ExpectedUser = "director-exec",
    [string]$ExpectedSid,
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$Repository,
    [string]$ExecutorCommand = "codex",
    [string]$ExpectedCommit,
    [string]$OutputPath,
    # Paths the restricted account must NOT be able to write. The operator's
    # own tree belongs here; the machine-wide roots are added automatically.
    [string[]]$ForbiddenWritePaths = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ProxyVariables = @(
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
    "http_proxy", "https_proxy", "all_proxy"
)
$script:CredentialVariables = @(
    "GH_TOKEN", "GITHUB_TOKEN", "GIT_ASKPASS", "SSH_ASKPASS",
    "SSH_AUTH_SOCK", "GIT_SSH_COMMAND", "GH_CONFIG_DIR",
    "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY", "AZURE_CLIENT_SECRET"
)

function Redact-Text {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }

    $redacted = $Value
    $patterns = @(
        '(?i)(gho|ghp|ghs|ghr|github_pat)_[A-Za-z0-9_\-]+',
        '(?i)(x-access-token:|authorization\s*:\s*bearer\s+)[^\s,;]+',
        '(?i)(token|password|passwd|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+'
    )
    foreach ($pattern in $patterns) {
        $redacted = [regex]::Replace($redacted, $pattern, "`$1[REDACTED]")
    }
    return $redacted
}

function Invoke-CapturedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $lines = @()
    $exitCode = 1
    try {
        $lines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object {
                Redact-Text ([string]$_)
            })
        if ($null -ne $LASTEXITCODE) {
            $exitCode = [int]$LASTEXITCODE
        } else {
            $exitCode = 0
        }
    } catch {
        $lines += Redact-Text ([string]$_)
        $exitCode = 1
    }

    return [ordered]@{
        exit_code = $exitCode
        output = (($lines -join "`n").Trim())
    }
}

function Invoke-WithGuardedEnvironment {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [switch]$UnsetProxy
    )

    $names = @(
        "GIT_TERMINAL_PROMPT", "GCM_INTERACTIVE", "GH_PROMPT_DISABLED"
    ) + $script:CredentialVariables + $(if ($UnsetProxy) { $script:ProxyVariables } else { @() })
    $previous = @{}
    foreach ($name in $names) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    $emptyGhConfig = $null

    try {
        $env:GIT_TERMINAL_PROMPT = "0"
        $env:GCM_INTERACTIVE = "never"
        $env:GH_PROMPT_DISABLED = "1"
        $emptyGhConfig = Join-Path ([IO.Path]::GetTempPath()) ("director-empty-gh-config-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $emptyGhConfig -Force | Out-Null
        Set-Item -LiteralPath "Env:GH_CONFIG_DIR" -Value $emptyGhConfig
        if ($UnsetProxy) {
            foreach ($name in $script:ProxyVariables) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
        return & $ScriptBlock
    } finally {
        foreach ($name in $names) {
            if ($null -eq $previous[$name]) {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            } else {
                Set-Item -LiteralPath "Env:$name" -Value $previous[$name]
            }
        }
        if ($emptyGhConfig -and (Test-Path -LiteralPath $emptyGhConfig)) {
            Remove-Item -LiteralPath $emptyGhConfig -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-AccountLeaf {
    param([string]$Account)
    if ([string]::IsNullOrWhiteSpace($Account)) {
        return ""
    }
    return (($Account -split "\\")[-1]).Trim()
}

function Test-ExpectedAccount {
    param(
        [string]$ActualAccount,
        [string]$ExpectedAccount
    )
    return ((Get-AccountLeaf $ActualAccount) -ieq (Get-AccountLeaf $ExpectedAccount))
}

function Test-ExpectedSid {
    param(
        [string]$ActualSid,
        [string]$ExpectedSidValue
    )
    return (
        -not [string]::IsNullOrWhiteSpace($ActualSid) -and
        -not [string]::IsNullOrWhiteSpace($ExpectedSidValue) -and
        $ActualSid -ieq $ExpectedSidValue
    )
}

function Get-CurrentIdentityEvidence {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $account = [string]$identity.Name
    $sid = if ($null -ne $identity.User) { [string]$identity.User.Value } else { "" }
    $groups = @()
    foreach ($group in @($identity.Groups)) {
        try {
            $groups += $group.Translate([Security.Principal.NTAccount]).Value
        } catch {
            $groups += [string]$group.Value
        }
    }

    $processPath = ""
    $parentProcessId = $null
    try {
        $process = Get-Process -Id $PID -ErrorAction Stop
        $processPath = [string]$process.Path
        $parent = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        $parentProcessId = [int]$parent.ParentProcessId
    } catch {
        $processPath = "unavailable: " + (Redact-Text ([string]$_))
    }

    $whoamiCommand = Get-Command -Name "whoami.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $whoamiPath = if ($null -ne $whoamiCommand) { [string]$whoamiCommand.Source } else { "" }
    $whoamiUser = if ($whoamiPath) {
        Invoke-CapturedCommand -FilePath $whoamiPath -ArgumentList @("/user")
    } else {
        [ordered]@{ exit_code = 1; output = "whoami.exe not found" }
    }
    $whoamiGroups = if ($whoamiPath) {
        Invoke-CapturedCommand -FilePath $whoamiPath -ArgumentList @("/groups")
    } else {
        [ordered]@{ exit_code = 1; output = "whoami.exe not found" }
    }

    return [ordered]@{
        account = $account
        user = (Get-AccountLeaf $account)
        sid = $sid
        groups = @($groups | Sort-Object -Unique)
        pid = [int]$PID
        parent_pid = $parentProcessId
        executable = $processPath
        cwd = (Get-Location).Path
        whoami_user = $whoamiUser
        whoami_groups = $whoamiGroups
    }
}

function Resolve-Executable {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }
    if (Test-Path -LiteralPath $Name -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Name).Path
    }
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -in @("Application", "ExternalScript") } |
        Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }
    return [string]$command.Source
}

function Get-ToolEvidence {
    param(
        [string]$Name,
        [string]$ProbeArgument = "--version"
    )

    $resolved = Resolve-Executable $Name
    if ($null -eq $resolved) {
        return [ordered]@{
            requested = $Name
            present = $false
            path = ""
            version = [ordered]@{ exit_code = 1; output = "not found" }
        }
    }

    $version = Invoke-WithGuardedEnvironment -UnsetProxy {
        Invoke-CapturedCommand -FilePath $resolved -ArgumentList @($ProbeArgument)
    }
    return [ordered]@{
        requested = $Name
        present = $true
        path = $resolved
        version = $version
    }
}

function Get-ExecutorLoginEvidence {
    param([System.Collections.IDictionary]$Tool)

    if ($null -eq $Tool -or -not [bool]$Tool.present) {
        return [ordered]@{
            executed = $false
            authenticated = $false
            exit_code = 1
            detail = "executor is not resolvable"
            output = "executor is not resolvable"
            codex_home = [string]$(if ($null -eq [Environment]::GetEnvironmentVariable("CODEX_HOME", "Process")) { "" } else { [Environment]::GetEnvironmentVariable("CODEX_HOME", "Process") })
        }
    }

    $result = Invoke-WithGuardedEnvironment {
        Invoke-CapturedCommand -FilePath ([string]$Tool.path) -ArgumentList @("login", "status")
    }
    return [ordered]@{
        executed = $true
        authenticated = ([int]$result.exit_code -eq 0)
        exit_code = [int]$result.exit_code
        detail = $(if ([int]$result.exit_code -eq 0) { "authenticated" } else { "not authenticated" })
        output = [string]$result.output
        codex_home = [string]$(if ($null -eq [Environment]::GetEnvironmentVariable("CODEX_HOME", "Process")) { "" } else { [Environment]::GetEnvironmentVariable("CODEX_HOME", "Process") })
    }
}

function Get-CredentialEvidence {
    param([string]$GitPath)

    $environment = @()
    foreach ($name in $script:CredentialVariables) {
        $environment += [ordered]@{
            name = $name
            present = ($null -ne [Environment]::GetEnvironmentVariable($name, "Process"))
            source = "process environment"
        }
    }

    $ghConfig = ""
    if ($env:APPDATA) {
        $ghConfig = Join-Path $env:APPDATA "GitHub CLI\hosts.yml"
    }
    $gitHelper = if ($GitPath) {
        Invoke-WithGuardedEnvironment -UnsetProxy {
            Invoke-CapturedCommand -FilePath $GitPath -ArgumentList @("config", "--global", "--get-all", "credential.helper")
        }
    } else {
        [ordered]@{ exit_code = 1; output = "git not found" }
    }

    return [ordered]@{
        environment = $environment
        github_cli_hosts_file = [ordered]@{
            path = $ghConfig
            present = (-not [string]::IsNullOrWhiteSpace($ghConfig) -and (Test-Path -LiteralPath $ghConfig -PathType Leaf))
        }
        git_credential_helper_configured = ($gitHelper.exit_code -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$gitHelper.output))
        git_credential_helper_probe = [ordered]@{
            exit_code = $gitHelper.exit_code
            output = [string]$gitHelper.output
        }
    }
}

function Test-CredentialRefusal {
    param([System.Collections.IDictionary]$Result)

    if ([int]$Result.exit_code -eq 0) {
        return $false
    }
    $text = ([string]$Result.output).ToLowerInvariant()
    if ($text.Contains("dubious ownership") -or $text.Contains("detected dubious ownership")) {
        return $false
    }
    foreach ($marker in @(
        "not logged", "gh auth login", "authentication failed", "bad credentials",
        "could not read username", "terminal prompts disabled", "no credentials",
        "permission denied", "publickey"
    )) {
        if ($text.Contains($marker)) {
            return $true
        }
    }
    return $false
}

function Get-RepositoryEvidence {
    param(
        [string]$GitPath,
        [string]$RepositoryPath
    )

    $owner = ""
    $ownerError = ""
    try {
        $owner = [string](Get-Acl -LiteralPath $RepositoryPath -ErrorAction Stop).Owner
    } catch {
        $ownerError = Redact-Text ([string]$_)
    }

    $remote = [ordered]@{ exit_code = 1; output = "git or repository directory not found" }
    $commit = [ordered]@{ exit_code = 1; output = "git or repository directory not found" }
    $status = [ordered]@{ exit_code = 1; output = "git or repository directory not found" }
    if ($GitPath -and (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
        $remote = Invoke-WithGuardedEnvironment -UnsetProxy {
            Invoke-CapturedCommand -FilePath $GitPath -ArgumentList @(
                "-C", $RepositoryPath, "remote", "get-url", "origin"
            )
        }
        $commit = Invoke-WithGuardedEnvironment -UnsetProxy {
            Invoke-CapturedCommand -FilePath $GitPath -ArgumentList @(
                "-C", $RepositoryPath, "rev-parse", "--verify", "HEAD"
            )
        }
        $status = Invoke-WithGuardedEnvironment -UnsetProxy {
            Invoke-CapturedCommand -FilePath $GitPath -ArgumentList @(
                "-C", $RepositoryPath, "status", "--porcelain", "--untracked-files=all"
            )
        }
    }

    $commitSha = ([string]$commit.output).Trim()
    $statusText = ([string]$status.output).Trim()
    $repositoryOutputs = @($remote.output, $commit.output, $status.output)
    $repositoryPreconditionFailure = @($repositoryOutputs | ForEach-Object {
        ([string]$_).ToLowerInvariant()
    } | Where-Object {
        $_.Contains("dubious ownership") -or $_.Contains("detected dubious ownership")
    }).Count -gt 0
    $expectedCommitIsFullSha = $ExpectedCommit -match '^[0-9a-fA-F]{40}$'
    $allowedStatusPaths = @(
        ".director/clean-clone-preflight.json",
        ".director/evidence/restricted-account-probe.json"
    )
    $statusLines = @($statusText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $unexpectedStatus = @()
    foreach ($line in $statusLines) {
        $relativePath = if ($line.Length -gt 3) { $line.Substring(3).Trim().Replace("\", "/") } else { "" }
        if ($allowedStatusPaths -notcontains $relativePath) {
            $unexpectedStatus += $line
        }
    }
    $manifestPath = Join-Path $RepositoryPath ".director\clean-clone-preflight.json"
    $manifestPresent = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $ownerMatchesExpected = Test-ExpectedAccount -ActualAccount $owner -ExpectedAccount $ExpectedUser
    return [ordered]@{
        path = $RepositoryPath
        owner = $owner
        owner_error = $ownerError
        owner_matches_expected = $ownerMatchesExpected
        remote = ([string]$remote.output).Trim()
        remote_exit_code = [int]$remote.exit_code
        commit_sha = $commitSha
        commit_exit_code = [int]$commit.exit_code
        expected_commit = $ExpectedCommit
        commit_is_full_sha = ($commitSha -match '^[0-9a-fA-F]{40}$')
        commit_matches_expected = ($commitSha -ieq $ExpectedCommit)
        expected_commit_is_full_sha = $expectedCommitIsFullSha
        status_exit_code = [int]$status.exit_code
        status = $statusText
        status_scope = "tracked changes plus allowlisted generated evidence files"
        unexpected_status = $unexpectedStatus
        status_clean = ($status.exit_code -eq 0 -and $unexpectedStatus.Count -eq 0)
        precondition_failure = $repositoryPreconditionFailure
        clean_clone_manifest_present = $manifestPresent
        clean_clone = (
            $ownerMatchesExpected -and
            $commit.exit_code -eq 0 -and
            $remote.exit_code -eq 0 -and
            $status.exit_code -eq 0 -and
            $unexpectedStatus.Count -eq 0 -and
            $manifestPresent -and
            $commitSha -match '^[0-9a-fA-F]{40}$' -and
            $expectedCommitIsFullSha -and
            $commitSha -ieq $ExpectedCommit -and
            -not $repositoryPreconditionFailure
        )
    }
}

function Invoke-SmokeTask {
    param([string]$Directory)

    $artifact = Join-Path $Directory (".director-restricted-account-smoke-" + [guid]::NewGuid().ToString("N") + ".json")
    $started = (Get-Date).ToUniversalTime().ToString("o")
    $payload = [ordered]@{
        kind = "director-restricted-account-smoke"
        started_utc = $started
        pid = [int]$PID
        account = [string]([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    }
    $result = [ordered]@{
        passed = $false
        exit_code = 1
        artifact_created = $false
        artifact_removed = $false
        directory = $Directory
        error = ""
    }
    try {
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
            throw "working directory does not exist: $Directory"
        }
        [IO.File]::WriteAllText($artifact, ($payload | ConvertTo-Json -Compress))
        $result.artifact_created = $true
        $readBack = Get-Content -LiteralPath $artifact -Raw | ConvertFrom-Json
        $passed = (
            $readBack.kind -eq "director-restricted-account-smoke" -and
            [int]$readBack.pid -eq [int]$PID -and
            [string]$readBack.account -eq [string]$payload.account
        )
        if (-not $passed) {
            throw "smoke artifact read-back did not match its writer"
        }
        $result.passed = $true
        $result.exit_code = 0
    } catch {
        $result.error = Redact-Text ([string]$_)
    } finally {
        if (Test-Path -LiteralPath $artifact -PathType Leaf) {
            $cleanupError = ""
            foreach ($attempt in 1..3) {
                try {
                    Remove-Item -LiteralPath $artifact -Force -ErrorAction Stop
                    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
                        $result.artifact_removed = $true
                        break
                    }
                } catch {
                    $cleanupError = Redact-Text ([string]$_)
                }
                if ($attempt -lt 3) {
                    Start-Sleep -Milliseconds 150
                }
            }
            if (-not $result.artifact_removed) {
                $cleanupError = "smoke artifact cleanup failed after 3 attempts: " + $cleanupError
                $result.error = if ([string]::IsNullOrWhiteSpace($result.error)) {
                    $cleanupError
                } else {
                    $result.error + "; " + $cleanupError
                }
            }
        } else {
            $result.artifact_removed = $true
        }
    }
    return $result
}

function Test-GitPushAccepted {
    param([AllowNull()][string]$Output)

    $text = ([string]$Output).ToLowerInvariant()
    foreach ($marker in @(
        "everything up-to-date", "[new branch]", "[new tag]", "[up to date]",
        "successfully pushed", "push succeeded"
    )) {
        if ($text.Contains($marker)) {
            return $true
        }
    }
    return $false
}

function Get-GitPushVerdict {
    param([System.Collections.IDictionary]$Result)

    $text = ([string]$Result.output).ToLowerInvariant()
    $preconditionFailure = (
        $text.Contains("dubious ownership") -or
        $text.Contains("detected dubious ownership")
    )
    if ($preconditionFailure) {
        return "precondition_failure"
    }

    if ([int]$Result.exit_code -eq 0 -or (Test-GitPushAccepted -Output ([string]$Result.output))) {
        return "unexpected_success"
    }

    # Credential markers are tested BEFORE egress markers. Ballot item 8,
    # carried 3-of-3. If output carries both, the push reached something that
    # answered about credentials, which is the more specific fact; classifying
    # it as egress_blocked would credit containment for a connection that
    # actually happened.
    if (Test-CredentialRefusal $Result) {
        return "credential_refused"
    }

    foreach ($marker in @(
        "could not connect", "failed to connect", "could not resolve host",
        "connection refused", "connection timed out", "network is unreachable",
        "couldn't connect to server"
    )) {
        if ($text.Contains($marker)) {
            return "egress_blocked"
        }
    }

    return "unexpected_success"
}

function Invoke-GitPushProbe {
    param(
        [string]$GitPath,
        [string]$RepositoryPath
    )

    if (-not $GitPath -or -not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
        return [ordered]@{
            executed = $false
            expected_refusal = $true
            verdict = "precondition_failure"
            precondition_failure = $true
            exit_code = 1
            output = "git or repository directory not found"
        }
    }

    $branch = "director-exec-probe-" + [guid]::NewGuid().ToString("N")
    $result = Invoke-WithGuardedEnvironment -UnsetProxy {
        Invoke-CapturedCommand -FilePath $GitPath -ArgumentList @(
            "-C", $RepositoryPath,
            "-c", "http.proxy=",
            "-c", "https.proxy=",
            "-c", "credential.helper=",
            "push", "--dry-run", "--no-verify", "origin", "HEAD:refs/heads/$branch"
        )
    }
    return [ordered]@{
        executed = $true
        expected_refusal = $true
        verdict = Get-GitPushVerdict -Result $result
        precondition_failure = (([string]$result.output).ToLowerInvariant().Contains("dubious ownership"))
        exit_code = $result.exit_code
        output = [string]$result.output
    }
}

function Get-CredentialRequestShape {
    param([string]$RemoteUrl)

    # The request must match the remote the executor would actually push to. A
    # helper can be scoped to a host, a protocol, or a path prefix, so a generic
    # request to bare https://github.com can be refused while the real remote is
    # served. Ballot item 3, carried 3-of-3.
    $protocol = "https"
    $host_ = "github.com"
    $path = ""
    $derived = $false
    if (-not [string]::IsNullOrWhiteSpace($RemoteUrl)) {
        try {
            $uri = [Uri]$RemoteUrl
            if ($uri.Scheme -in @("http", "https")) {
                $protocol = $uri.Scheme
                $host_ = $uri.Host
                $path = $uri.AbsolutePath.TrimStart("/")
                $derived = $true
            }
        } catch {
            $derived = $false
        }
    }
    return [ordered]@{
        protocol = $protocol
        host = $host_
        path = $path
        derived_from_remote = $derived
    }
}

function Invoke-GitCredentialProbe {
    param(
        [string]$GitPath,
        [string]$RemoteUrl
    )

    if (-not $GitPath) {
        return [ordered]@{
            executed = $false
            refused = $false
            credential_supplied = $false
            exit_code = 1
            request = (Get-CredentialRequestShape -RemoteUrl $RemoteUrl)
            output = "git not found"
        }
    }
    $shape = Get-CredentialRequestShape -RemoteUrl $RemoteUrl

    $result = Invoke-WithGuardedEnvironment -UnsetProxy {
        # Stdin is written through ProcessStartInfo, never through a PowerShell
        # pipeline. Piping a string into a native command is not reliable under
        # Windows PowerShell 5.1, which is the engine this probe runs on:
        # whether the bytes arrive depends on the PARENT process's stdin handle,
        # not on this code. Launched with an inherited pipe the probe refused
        # correctly; launched with stdin from the null device -- the shape
        # `powershell.exe -NoProfile -File` gets non-interactively -- git
        # received nothing and answered "refusing to work with credential
        # missing protocol field", so a malformed request scored as "no
        # refusal". A probe whose verdict depends on how its shell was launched
        # is not evidence.
        #
        # ProcessStartInfo.ArgumentList does not exist on .NET Framework, so the
        # argument string is built by hand. None of these arguments contains a
        # space or a quote, so plain joining is exact here.
        $exitCode = 1
        $text = ""
        $credentialSupplied = $false
        $timedOut = $false
        $exitZeroNoCredential = $false
        $process = $null
        $requestFile = Join-Path ([IO.Path]::GetTempPath()) ("director-credprobe-" + [guid]::NewGuid().ToString("N") + ".txt")
        try {
            # The request is written as exact ASCII bytes and fed to git by
            # redirecting stdin from that file. Measured on this machine, under
            # Windows PowerShell 5.1, every in-process route delivers something
            # git rejects as "missing protocol field": StandardInput.Write, a
            # raw BaseStream write, and a hand-built UTF8Encoding($false)
            # StreamWriter all fail. 5.1's StandardInput encoding reports a
            # 3-byte preamble where PowerShell 7 reports none, which is why the
            # same code passes on 7 and fails on 5.1. Redirection from a file
            # whose bytes we wrote ourselves is the only form measured to work
            # on BOTH engines, so it is what the probe uses. The request file
            # holds a protocol, a host and a path. It never holds a credential.
            #
            # `credential.helper=` is NOT passed any more. Passing it disabled
            # every configured helper and the probe then concluded from the
            # resulting refusal that no credential existed, which was circular
            # and true on any machine. Ballot item 3, carried 3-of-3.
            #
            # THE SAFETY RULE THAT FOLLOWS FROM THAT. With helpers live, a
            # machine that HAS a credential will have git print it. `git
            # credential fill` writes the credential to STDOUT and its errors to
            # STDERR, so stdout is scanned line by line for a `password=` key
            # and then DISCARDED - never accumulated, never returned, never
            # written to the evidence file. Only stderr survives into evidence.
            $request = "protocol=" + $shape.protocol + "`nhost=" + $shape.host
            if (-not [string]::IsNullOrWhiteSpace($shape.path)) {
                $request += "`npath=" + $shape.path
            }
            $request += "`n`n"
            [IO.File]::WriteAllBytes($requestFile, [Text.Encoding]::ASCII.GetBytes($request))
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $env:ComSpec
            $psi.Arguments = '/c ""' + $GitPath + '" credential fill < "' + $requestFile + '""'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::Start($psi)
            # BOTH streams are read asynchronously. The previous version consumed
            # stdout with a synchronous ReadLine() loop placed BEFORE
            # WaitForExit, so a helper that never emitted a complete line blocked
            # forever and the 60s bound was decorative. Nothing here may block on
            # the child.
            $stdoutRead = $process.StandardOutput.ReadToEndAsync()
            $stderrRead = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) {
                try { $process.Kill() } catch { }
                # A hang is INCONCLUSIVE, not a credential. Scoring it "supplied"
                # was a false positive that would hard-fail a clean restricted
                # account whose helper merely hung.
                $text = "credential probe timed out after 60s and was killed"
                $exitCode = 1
                $timedOut = $true
            } else {
                $text = [string]$stderrRead.Result
                $exitCode = [int]$process.ExitCode
                # The ONLY signal that a credential came back is a credential key
                # on stdout. Exit code 0 is deliberately NOT used: git can exit 0
                # having echoed back protocol and host with no password, and
                # scoring that "supplied" would hard-fail a clean account and
                # block the whole issue. Both consulted CLIs independently
                # flagged the exit-code reading as the weakest claim.
                #
                # $stdout exists only inside this block. It is never returned,
                # printed, or stored.
                $stdout = [string]$stdoutRead.Result
                foreach ($candidate in ($stdout -split "`n")) {
                    $trimmed = $candidate.TrimEnd("`r")
                    foreach ($key in @("password=", "password_expiry_utc=", "oauth_refresh_token=")) {
                        if ($trimmed.StartsWith($key, [StringComparison]::OrdinalIgnoreCase)) {
                            $credentialSupplied = $true
                        }
                    }
                }
                $stdout = $null
                $trimmed = $null
                # Exit 0 with no credential key is neither a pass nor a failure.
                if (($exitCode -eq 0) -and (-not $credentialSupplied)) {
                    $timedOut = $false
                    $exitZeroNoCredential = $true
                }
            }
        } catch {
            # The exception message is redacted like any other output, but it is
            # also marked inconclusive: an exception is not evidence about
            # credentials either way.
            $text = [string]$_
            $exitCode = 1
            $timedOut = $false
            $exitZeroNoCredential = $true
        } finally {
            if ($null -ne $process) {
                $process.Dispose()
            }
            if (Test-Path -LiteralPath $requestFile -PathType Leaf) {
                Remove-Item -LiteralPath $requestFile -Force -ErrorAction SilentlyContinue
            }
        }

        return [ordered]@{
            exit_code = $exitCode
            credential_supplied = $credentialSupplied
            inconclusive = ($timedOut -or $exitZeroNoCredential)
            inconclusive_reason = $(
                if ($timedOut) { "probe timed out; a hang is not a credential result" }
                elseif ($exitZeroNoCredential) { "git exited 0 without returning a credential key, or the probe threw; neither proves a credential exists or is absent" }
                else { "" }
            )
            output = (Redact-Text $text).Trim()
        }
    }
    # A supplied credential is a HARD FAIL, not an inconclusive result: the
    # account can authenticate to the remote the executor would push to. It
    # overrides any refusal marker that also appeared on stderr.
    $supplied = [bool]$result.credential_supplied
    $undecided = [bool]$result.inconclusive
    return [ordered]@{
        executed = $true
        credential_supplied = $supplied
        inconclusive = $undecided
        inconclusive_reason = [string]$result.inconclusive_reason
        refused = ((-not $supplied) -and (-not $undecided) -and (Test-CredentialRefusal $result))
        exit_code = [int]$result.exit_code
        request = $shape
        output = [string]$result.output
    }
}

function Get-ProfileWriteTargets {
    # Issue #59, criterion 6. The forbidden set is DERIVED here rather than
    # taken on trust from -ForbiddenWritePaths. Passing that switch was the only
    # thing that put the operator's tree in scope, so omitting it silently
    # shrank the probe to the machine roots and nothing noticed. It is now an
    # ADDITION to this set, never a replacement.
    #
    # Measured on this machine 2026-08-16, which is what makes the derivation
    # possible at all from a restricted account:
    #   HKLM\...\CurrentVersion\ProfileList   BUILTIN\Users : ReadKey
    #   ProfilesDirectory                     C:\Users
    #   C:\Users                              BUILTIN\Users : ReadAndExecute
    #   C:\Users\<operator>                   no Users or Everyone ACE at all
    # The operator tree is discoverable BY NAME and unreadable BY CONTENT, so a
    # restricted account can enumerate exactly the paths it must not be able to
    # write without being able to read any of them.
    $derived = New-Object System.Collections.Generic.List[string]
    $profilesDirectory = ""
    $errorText = ""
    try {
        $profilesDirectory = [Environment]::ExpandEnvironmentVariables(
            [string](Get-ItemProperty `
                    -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" `
                    -Name "ProfilesDirectory" -ErrorAction Stop).ProfilesDirectory
        ).TrimEnd("\")
        if ([string]::IsNullOrWhiteSpace($profilesDirectory)) {
            throw "ProfilesDirectory is empty"
        }
        $derived.Add($profilesDirectory)

        $ownProfile = [string][Environment]::GetEnvironmentVariable("USERPROFILE", "Process")
        $ownLeaf = if ([string]::IsNullOrWhiteSpace($ownProfile)) {
            ""
        } else {
            Split-Path -Leaf ($ownProfile.TrimEnd("\"))
        }
        foreach ($entry in @(Get-ChildItem -LiteralPath $profilesDirectory -Directory -Force -ErrorAction Stop)) {
            # Junctions are not profiles. "All Users" resolves to ProgramData,
            # which grants Users create-file BY DESIGN, so probing it would
            # report a containment failure that is not one; "Default User"
            # resolves to Default, already excluded below.
            if ($entry.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
                continue
            }
            # Public is shared by design and Default is a template. Neither is
            # evidence about containment. The account's own profile is excluded
            # for the reason the probe has always excluded it: it has to have a
            # home and writing there is expected.
            if (@("Public", "Default") -contains $entry.Name) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($ownLeaf) -and $entry.Name -ieq $ownLeaf) {
                continue
            }
            $derived.Add($entry.FullName)
        }
    } catch {
        # A derivation that fails is not a pass. The caller turns this into a
        # probe failure, because the alternative is a probe that quietly covers
        # less than it claims - the exact fault this function exists to remove.
        $errorText = Redact-Text ([string]$_)
    }
    return [ordered]@{
        profiles_directory = $profilesDirectory
        derived = @($derived)
        error = $errorText
    }
}

function Invoke-WriteBoundaryProbe {
    param(
        [string]$Repository,
        [string[]]$ForbiddenWritePaths = @()
    )

    # Issue #59, criterion 6, second half. The smoke task proves the granted
    # worktree is writable; this proves nothing outside it is, by TRYING rather
    # than by reading an ACL. A configuration excerpt is not proof anywhere else
    # in this probe and it is not proof here either: on 2026-08-15 a stale grant
    # on the operator's own worktree was found by measurement while the ACL read
    # alone had looked reasonable.
    #
    # The restricted account's OWN profile is deliberately not a target. It has
    # to have a home and writing there is expected. The boundary that matters is
    # the operator's tree and the machine's shared roots, so the caller passes
    # operator paths explicitly and the universal ones are defaults.
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $ForbiddenWritePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $targets.Add($candidate)
        }
    }
    foreach ($candidate in @(
        [Environment]::GetFolderPath("Windows"),
        [Environment]::GetEnvironmentVariable("ProgramFiles", "Process")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $targets.Add($candidate)
        }
    }
    $profileRoot = [Environment]::GetEnvironmentVariable("USERPROFILE", "Process")
    if (-not [string]::IsNullOrWhiteSpace($profileRoot)) {
        $usersRoot = Split-Path -Parent ($profileRoot.TrimEnd("\"))
        if (-not [string]::IsNullOrWhiteSpace($usersRoot)) {
            $targets.Add($usersRoot)
        }
    }
    # Every OTHER profile on the machine, derived rather than declared. The
    # caller's -ForbiddenWritePaths is added on top of this, above.
    $profileTargets = Get-ProfileWriteTargets
    foreach ($candidate in $profileTargets.derived) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $targets.Add($candidate)
        }
    }

    $attempts = @()
    $allRefused = $true
    $allCleaned = $true
    $anyInconclusive = $false
    foreach ($target in ($targets | Select-Object -Unique)) {
        $artifact = Join-Path $target ("director-write-boundary-" + [guid]::NewGuid().ToString("N") + ".tmp")
        $refused = $false
        $inconclusive = $false
        $detail = ""
        $removed = $true
        try {
            [IO.File]::WriteAllText($artifact, "director write-boundary probe")
            $refused = $false
            $detail = "write succeeded"
            $allRefused = $false
        } catch {
            # PowerShell wraps a failing .NET call in MethodInvocationException,
            # which names the wrapper rather than the reason. Unwrap it first.
            $reason = $_.Exception
            while ($null -ne $reason.InnerException) {
                $reason = $reason.InnerException
            }
            $typeName = $reason.GetType().Name
            # Ballot item 4, carried 3-of-3. ONLY an access denial counts as a
            # refusal. Every other failure is INCONCLUSIVE and fails the probe
            # rather than passing it. Previously every caught exception was
            # scored `refused`, so a path that merely did not exist counted as
            # proof of denied access -- and the self-test's target was a
            # deliberately nonexistent directory, which meant that assertion
            # passed on a machine where the account could write everywhere.
            #
            # UnauthorizedAccessException is reported as "OS access refused"
            # rather than "ACL denied": it also covers a read-only attribute or
            # a policy denial, and this probe does not distinguish those.
            if ($typeName -in @("UnauthorizedAccessException", "SecurityException")) {
                $refused = $true
                $inconclusive = $false
            } else {
                $refused = $false
                $inconclusive = $true
            }
            $detail = Redact-Text ($typeName + ": " + $reason.Message)
        }
        # Clean up even on the path that should never be reached. An earlier
        # probe left an artifact in the operator's worktree that was still
        # there two weeks later.
        if (Test-Path -LiteralPath $artifact -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $artifact -Force -ErrorAction Stop
                $removed = -not (Test-Path -LiteralPath $artifact -PathType Leaf)
            } catch {
                $removed = $false
            }
            if (-not $removed) {
                $allCleaned = $false
            }
        }
        if ($inconclusive) {
            $anyInconclusive = $true
            $allRefused = $false
        }
        $attempts += [ordered]@{
            path = $target
            refused = $refused
            inconclusive = $inconclusive
            detail = $detail
            artifact_removed = $removed
        }
    }

    # An empty target list used to leave all_refused true while nothing had been
    # attempted. Ballot item 4: no attempts is a failure, never a pass.
    $executed = ($attempts.Count -gt 0)
    if (-not $executed) {
        $allRefused = $false
    }
    return [ordered]@{
        executed = $executed
        all_refused = $allRefused
        any_inconclusive = $anyInconclusive
        all_artifacts_removed = $allCleaned
        granted_worktree = $Repository
        profiles_directory = [string]$profileTargets.profiles_directory
        derived_profile_targets = @($profileTargets.derived)
        derivation_error = [string]$profileTargets.error
        target_source = "derived from the profile list, plus the machine roots, plus any -ForbiddenWritePaths the caller added"
        attempts = @($attempts)
    }
}

function Get-BaselineEvidence {
    param([string]$Repository)

    # Issue #59, criterion 7. Each result has to be a difference rather than an
    # isolated observation, so the evidence names the runs it should be read
    # against instead of leaving a reader to go find them.
    $documents = @(
        [ordered]@{
            role = "unjailed operator account, for comparison"
            path = "docs/evidence/baseline-unrestricted-2026-07-28.md"
        },
        [ordered]@{
            role = "restricted account egress boundary, measured"
            path = "docs/evidence/baseline-director-exec-2026-07-30.md"
        }
    )
    # Ballot item 6, carried 3-of-3. Test-Path on a filename proved nothing: an
    # empty or unrelated file with the right name passed. Each citation now
    # carries a SHA-256 and a byte count.
    #
    # What that DOES establish: which exact document a reader must open to
    # compare against, and that it has not silently changed between runs.
    # What it does NOT establish: that the document is a valid baseline, that
    # it was produced by a comparable procedure, or that the comparison is
    # meaningful. Those are a reader's judgement and this field does not stand
    # in for them.
    $cited = @()
    foreach ($document in $documents) {
        $full = if ([string]::IsNullOrWhiteSpace($Repository)) {
            $document.path
        } else {
            Join-Path $Repository $document.path
        }
        $present = (Test-Path -LiteralPath $full -PathType Leaf)
        $sha = ""
        $bytes = 0
        if ($present) {
            # Hashed with .NET rather than Get-FileHash. The cmdlet failed
            # silently when the probe was launched through cmd /c -- byte counts
            # came back correct while every hash came back empty, and the catch
            # below turned that into "baseline missing". A probe must not depend
            # on which host started it; that is the same fault class as the
            # stdin defect.
            $hasher = $null
            try {
                $bytes = [int64](Get-Item -LiteralPath $full).Length
                $hasher = [Security.Cryptography.SHA256]::Create()
                $sha = ([BitConverter]::ToString($hasher.ComputeHash([IO.File]::ReadAllBytes($full)))).Replace("-", "")
            } catch {
                $sha = ""
            } finally {
                if ($null -ne $hasher) {
                    $hasher.Dispose()
                }
            }
        }
        $cited += [ordered]@{
            role = $document.role
            path = $document.path
            present = $present
            bytes = $bytes
            sha256 = $sha
            # An empty or unhashable file is not a citation.
            usable = ($present -and $bytes -gt 0 -and -not [string]::IsNullOrWhiteSpace($sha))
        }
    }
    return [ordered]@{
        cited = @($cited)
        all_present = (@($cited | Where-Object { -not $_.usable }).Count -eq 0)
        establishes = "which document to compare against, and that it has not changed; NOT that the comparison is valid"
    }
}

function New-ProbeEvidence {
    $identity = Get-CurrentIdentityEvidence
    $pathEntries = @([Environment]::GetEnvironmentVariable("Path", "Process") -split ";" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $profilePath = [Environment]::GetEnvironmentVariable("USERPROFILE", "Process")
    $profileLeaf = if ([string]::IsNullOrWhiteSpace($profilePath)) {
        ""
    } else {
        Split-Path -Leaf ($profilePath.TrimEnd("\"))
    }
    $profileMatchesExpectedUser = (
        -not [string]::IsNullOrWhiteSpace($profileLeaf) -and
        $profileLeaf -like ((Get-AccountLeaf $ExpectedUser) + "*")
    )
    $git = Get-ToolEvidence -Name "git"
    $executor = Get-ToolEvidence -Name $ExecutorCommand
    $executorLogin = Get-ExecutorLoginEvidence -Tool $executor
    $executor["login"] = $executorLogin
    $gh = Get-ToolEvidence -Name "gh"
    $credentials = Get-CredentialEvidence -GitPath $(if ($git.present) { $git.path } else { "" })
    # Repository evidence is gathered FIRST now: the credential probe needs the
    # real remote URL so it can request the shape a helper would actually be
    # scoped to, rather than a generic https://github.com.
    $repositoryEvidence = Get-RepositoryEvidence -GitPath $(if ($git.present) { $git.path } else { "" }) -RepositoryPath $Repository
    $gitCredentialFill = Invoke-GitCredentialProbe -GitPath $(if ($git.present) { $git.path } else { "" }) -RemoteUrl ([string]$repositoryEvidence.remote)
    $writeBoundary = Invoke-WriteBoundaryProbe -Repository $Repository -ForbiddenWritePaths $ForbiddenWritePaths
    $baselines = Get-BaselineEvidence -Repository $Repository
    $profileRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        ""
    } else {
        (Resolve-Path -LiteralPath $env:USERPROFILE -ErrorAction SilentlyContinue).Path.TrimEnd("\")
    }
    $repositoryUnderProfile = (
        -not [string]::IsNullOrWhiteSpace($profileRoot) -and
        $Repository.StartsWith($profileRoot + "\", [StringComparison]::OrdinalIgnoreCase)
    )
    $smoke = Invoke-SmokeTask -Directory $WorkingDirectory
    $failures = New-Object System.Collections.Generic.List[string]

    if (-not (Test-ExpectedAccount -ActualAccount $identity.account -ExpectedAccount $ExpectedUser)) {
        $failures.Add("effective account does not match expected user '$ExpectedUser'")
    }
    $sidMatchesExpected = Test-ExpectedSid -ActualSid $identity.sid -ExpectedSidValue $ExpectedSid
    if (-not $sidMatchesExpected) {
        $failures.Add("effective SID does not match the required -ExpectedSid value")
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedSid)) {
        $failures.Add("-ExpectedSid is required; account names and profiles are not authoritative")
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedCommit) -or $ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
        $failures.Add("-ExpectedCommit must be a full exact commit SHA")
    }
    if (-not $repositoryEvidence.clean_clone) {
        $failures.Add("repository is not a readable clean clone with an origin remote and full HEAD SHA")
    }
    if ($repositoryEvidence.precondition_failure) {
        $failures.Add("repository precondition failed: git reported dubious ownership; use a clean clone owned by the restricted account")
    }
    if (-not $repositoryEvidence.commit_matches_expected) {
        $failures.Add("repository HEAD does not match the required full exact expected commit SHA")
    }
    if (-not $repositoryEvidence.owner_matches_expected) {
        $failures.Add("repository owner does not match the expected restricted account")
    }
    if (-not $repositoryUnderProfile) {
        $failures.Add("repository is not below the restricted account profile")
    }
    if (-not $profileMatchesExpectedUser) {
        $failures.Add("USERPROFILE does not identify the expected restricted user")
    }
    if (-not $git.present) {
        $failures.Add("required tool 'git' is not resolvable")
    }
    if (-not $executor.present) {
        $failures.Add("required executor '$ExecutorCommand' is not resolvable")
    } elseif (-not $executorLogin.authenticated) {
        $failures.Add("restricted executor does not have its own Codex login")
    }
    if (-not ($smoke.passed -and $smoke.artifact_removed)) {
        $failures.Add("deterministic no-network smoke task did not create, read, and remove its artifact")
    }

    $credentialSignals = @($credentials.environment | Where-Object { $_.present })
    if ($credentialSignals.Count -gt 0) {
        $failures.Add("credential-bearing environment variables are present: " + (($credentialSignals | ForEach-Object { $_.name }) -join ", "))
    }
    if ($credentials.github_cli_hosts_file.present) {
        $failures.Add("GitHub CLI hosts file is present for the restricted probe")
    }
    if ($credentials.git_credential_helper_configured) {
        $failures.Add("global Git credential helper is configured for the restricted probe")
    }
    # A supplied credential is the hard failure; a non-refusal is the softer one.
    # They are reported separately so a reader is never left guessing which
    # happened.
    if ($gitCredentialFill.credential_supplied) {
        $failures.Add("git credential fill SUPPLIED a credential for " +
            $gitCredentialFill.request.protocol + "://" + $gitCredentialFill.request.host +
            "; the account can authenticate to the remote")
    } elseif ($gitCredentialFill.inconclusive) {
        $failures.Add("git credential fill was INCONCLUSIVE: " + $gitCredentialFill.inconclusive_reason)
    } elseif (-not $gitCredentialFill.refused) {
        $failures.Add("git credential fill neither supplied a credential nor refused recognisably; the result is inconclusive")
    }
    if (-not $gitCredentialFill.request.derived_from_remote) {
        $failures.Add("git credential fill used a generic request shape because the repository remote could not be read; a helper scoped to the real remote would not have been tested")
    }
    # Issue #59, criterion 6, second half.
    if (-not $writeBoundary.executed) {
        $failures.Add("write-boundary probe did not run; criterion 6 cannot be claimed")
    } else {
        if (-not [string]::IsNullOrWhiteSpace($writeBoundary.derivation_error)) {
            $failures.Add("write-boundary targets could not be derived from the profile list: " +
                $writeBoundary.derivation_error +
                ". Coverage would silently fall back to the machine roots plus whatever -ForbiddenWritePaths happened to carry")
        }
        $writable = @($writeBoundary.attempts | Where-Object { (-not $_.refused) -and (-not $_.inconclusive) } | ForEach-Object { $_.path })
        if ($writable.Count -gt 0) {
            $failures.Add("restricted account can write outside its granted worktree: " + ($writable -join ", "))
        }
        $undecided = @($writeBoundary.attempts | Where-Object { $_.inconclusive } | ForEach-Object { $_.path + " (" + $_.detail + ")" })
        if ($undecided.Count -gt 0) {
            $failures.Add("write-boundary probe was INCONCLUSIVE for: " + ($undecided -join "; ") +
                ". Only an access denial counts as a refusal; anything else proves nothing")
        }
    }
    if ($writeBoundary.executed -and -not $writeBoundary.all_artifacts_removed) {
        $failures.Add("write-boundary probe left an artifact behind")
    }
    # Issue #59, criterion 7.
    if (-not $baselines.all_present) {
        $missing = @($baselines.cited | Where-Object { -not $_.usable } | ForEach-Object { $_.path })
        $failures.Add("baseline evidence is missing, empty, or unhashable: " + ($missing -join ", "))
    }

    $ghAuthentication = [ordered]@{ executed = $false; refused = $true; result = [ordered]@{ exit_code = 1; output = "gh not found" } }
    $ghUser = [ordered]@{ executed = $false; refused = $true; result = [ordered]@{ exit_code = 1; output = "gh not found" } }
    if ($gh.present) {
        $ghAuthentication.executed = $true
        $ghAuthentication.result = Invoke-WithGuardedEnvironment -UnsetProxy {
            Invoke-CapturedCommand -FilePath $gh.path -ArgumentList @("auth", "status", "--hostname", "github.com")
        }
        $ghAuthentication.refused = (Test-CredentialRefusal $ghAuthentication.result)
        $ghUser.executed = $true
        $ghUser.result = Invoke-WithGuardedEnvironment -UnsetProxy {
            Invoke-CapturedCommand -FilePath $gh.path -ArgumentList @("api", "user")
        }
        $ghUser.refused = (Test-CredentialRefusal $ghUser.result)
        if (-not $ghAuthentication.refused) {
            $failures.Add("gh auth status succeeded; GitHub credentials are available")
        }
        if (-not $ghUser.refused) {
            $failures.Add("gh api user succeeded; GitHub API credentials are available")
        }
    } else {
        $failures.Add("required tool 'gh' is not resolvable for credential refusal probes")
    }

    $pushProbe = [ordered]@{
        executed = $false
        expected_refusal = $true
        verdict = "precondition_failure"
        precondition_failure = $true
        exit_code = 1
        output = "not run; -Repository is required for the real account probe"
    }
    if ([string]::IsNullOrWhiteSpace($Repository)) {
        $failures.Add("-Repository is required to prove a credential-free git push refusal")
    } else {
        $pushProbe = Invoke-GitPushProbe -GitPath $(if ($git.present) { $git.path } else { "" }) -RepositoryPath $Repository
        if ($pushProbe.verdict -in @("unexpected_success", "precondition_failure")) {
            $failures.Add("git push probe verdict was '$($pushProbe.verdict)'")
        }
    }

    return [ordered]@{
        schema_version = "director.restricted-account-evidence.v3"
        ticket = 59
        generated_utc = (Get-Date).ToUniversalTime().ToString("o")
        status = $(if ($failures.Count -eq 0) { "completed" } else { "failed" })
        expected_user = $ExpectedUser
        expected_sid = $ExpectedSid
        identity = $identity
        identity_checks = [ordered]@{
            account_matches_expected = (Test-ExpectedAccount -ActualAccount $identity.account -ExpectedAccount $ExpectedUser)
            sid_matches_expected = $sidMatchesExpected
        }
        process = [ordered]@{
            pid = [int]$PID
            parent_pid = $identity.parent_pid
            executable = $identity.executable
            cwd = (Get-Location).Path
        }
        path = [ordered]@{
            entries = $pathEntries
            executor_command = $ExecutorCommand
            user_profile = $profilePath
            user_profile_leaf = $profileLeaf
            user_profile_matches_expected_user = $profileMatchesExpectedUser
        }
        repository = $repositoryEvidence
        tools = [ordered]@{
            git = $git
            executor = $executor
            gh = $gh
        }
        credentials = [ordered]@{
            signals = $credentials
            gh_auth_status = $ghAuthentication
            gh_api_user = $ghUser
        }
        smoke = $smoke
        write_boundary = $writeBoundary
        baselines = $baselines
        git_credential_fill = $gitCredentialFill
        git_push_dry_run = $pushProbe
        failures = @($failures)
        redaction = [ordered]@{
            enabled = $true
            values_collected = $false
            policy = "credential values are never read into evidence; command output is pattern-redacted"
        }
    }
}

function Invoke-SelfTest {
    $failures = New-Object System.Collections.Generic.List[string]
    $redacted = Redact-Text "GH_TOKEN=gho_supersecret Authorization: Bearer abc123 api_key=hidden"
    if ($redacted -match "supersecret|abc123|hidden") {
        $failures.Add("redaction helper left a credential-shaped value visible")
    }
    Write-Output ("self-test: redaction " + $(if ($failures.Count -eq 0) { "OK" } else { "FAIL" }))

    $identityGuard = (
        (Test-ExpectedAccount "MACHINE\director-exec" "director-exec") -and
        (-not (Test-ExpectedAccount "MACHINE\operator" "director-exec"))
    )
    if (-not $identityGuard) {
        $failures.Add("identity guard accepted a mismatched account")
    }
    Write-Output ("self-test: identity guard " + $(if ($identityGuard) { "OK" } else { "FAIL" }))

    $missingExecutorLogin = Get-ExecutorLoginEvidence -Tool ([ordered]@{ present = $false })
    if ($missingExecutorLogin.authenticated -or $missingExecutorLogin.executed) {
        $failures.Add("executor login guard accepted a missing executor")
    }
    Write-Output ("self-test: executor login guard " + $(if (-not $missingExecutorLogin.authenticated) { "OK" } else { "FAIL" }))
    $sidGuard = (
        (Test-ExpectedSid "S-1-5-21-100" "S-1-5-21-100") -and
        (-not (Test-ExpectedSid "S-1-5-21-100" "S-1-5-21-200")) -and
        (-not (Test-ExpectedSid "" "S-1-5-21-100"))
    )
    if (-not $sidGuard) {
        $failures.Add("SID guard accepted a missing or mismatched SID")
    }
    Write-Output ("self-test: SID guard " + $(if ($sidGuard) { "OK" } else { "FAIL" }))
    Write-Output ("self-test: engine " + $PSVersionTable.PSEdition + " " + $PSVersionTable.PSVersion)

    $authGuard = (
        (Test-CredentialRefusal ([ordered]@{ exit_code = 1; output = "To get started, run gh auth login" })) -and
        (-not (Test-CredentialRefusal ([ordered]@{ exit_code = 1; output = "Could not resolve host" })))
    )
    if (-not $authGuard) {
        $failures.Add("credential refusal guard accepted a generic network failure")
    }
    Write-Output ("self-test: credential refusal guard " + $(if ($authGuard) { "OK" } else { "FAIL" }))

    $connectFailureText = "fatal: unable to access 'https://github.com/...': Failed to connect to github.com port 443 after 74 ms: Could not connect to server"
    $connectFailureResult = [ordered]@{ exit_code = 1; output = $connectFailureText }
    $connectFailureVerdict = Get-GitPushVerdict -Result $connectFailureResult
    $connectFailureOkay = ($connectFailureVerdict -eq "egress_blocked")
    if (-not $connectFailureOkay) {
        $failures.Add("connect failure was classified as '$connectFailureVerdict' instead of 'egress_blocked'")
    }
    Write-Output ("self-test: git push classification | input: $connectFailureText | classified as: $connectFailureVerdict")

    $ghRefusalText = "To get started with GitHub CLI, please run: gh auth login"
    $ghRefusalResult = [ordered]@{ exit_code = 1; output = $ghRefusalText }
    $ghRefusalVerdict = Get-GitPushVerdict -Result $ghRefusalResult
    $ghRefusalOkay = ($ghRefusalVerdict -eq "credential_refused")
    if (-not $ghRefusalOkay) {
        $failures.Add("GitHub CLI refusal was classified as '$ghRefusalVerdict' instead of 'credential_refused'")
    }
    Write-Output ("self-test: git push classification | input: $ghRefusalText | classified as: $ghRefusalVerdict")

    $exitZeroText = "Everything up-to-date"
    $exitZeroResult = [ordered]@{ exit_code = 0; output = $exitZeroText }
    $exitZeroVerdict = Get-GitPushVerdict -Result $exitZeroResult
    $exitZeroOkay = ($exitZeroVerdict -eq "unexpected_success")
    if (-not $exitZeroOkay) {
        $failures.Add("exit-0 push result was classified as '$exitZeroVerdict' instead of 'unexpected_success'")
    }
    Write-Output ("self-test: git push classification | input: $exitZeroText | classified as: $exitZeroVerdict")

    $unknownFailureText = "fatal: some new git error nobody has seen"
    $unknownFailureResult = [ordered]@{ exit_code = 1; output = $unknownFailureText }
    $unknownFailureVerdict = Get-GitPushVerdict -Result $unknownFailureResult
    $unknownFailureOkay = ($unknownFailureVerdict -eq "unexpected_success")
    if (-not $unknownFailureOkay) {
        $failures.Add("unrecognised push failure was classified as '$unknownFailureVerdict' instead of 'unexpected_success'")
    }
    Write-Output ("self-test: git push classification | input: $unknownFailureText | classified as: $unknownFailureVerdict")

    # The credential probe now runs with helpers LIVE, so on the operator's own
    # account it may legitimately return a credential. Asserting refused:true
    # here would be asserting a property of the machine running the self-test,
    # not of the probe. What the self-test asserts instead is the property that
    # must hold EVERYWHERE: the probe never lets a secret into its output.
    $gitPath = Resolve-Executable -Name "git"
    $gitCredentialFill = Invoke-GitCredentialProbe -GitPath $gitPath -RemoteUrl "https://github.com/Nercari/director-core.git"
    $credentialProbeOutput = ([string]$gitCredentialFill.output).Replace("`r", " ").Replace("`n", " ")
    # @() around the pipeline: under StrictMode a single match returns a scalar
    # and no match returns $null, and .Count exists on neither.
    $leaked = @(@("password=", "password_expiry_utc=", "oauth_refresh_token=") |
        Where-Object { $credentialProbeOutput.ToLowerInvariant().Contains($_) })
    if ($leaked.Count -gt 0) {
        $failures.Add("git credential fill LEAKED a secret into probe output: matched " + ($leaked -join ", "))
    }
    if (-not $gitCredentialFill.executed) {
        $failures.Add("git credential fill probe did not execute")
    }
    if (-not $gitCredentialFill.request.derived_from_remote) {
        $failures.Add("credential request shape was not derived from the supplied remote URL")
    }
    Write-Output ("self-test: git credential fill | request: " + $gitCredentialFill.request.protocol + "://" + $gitCredentialFill.request.host + "/" + $gitCredentialFill.request.path + " | supplied: " + ([string]$gitCredentialFill.credential_supplied).ToLowerInvariant() + " | refused: " + ([string]$gitCredentialFill.refused).ToLowerInvariant() + " | inconclusive: " + ([string]$gitCredentialFill.inconclusive).ToLowerInvariant() + " " + $gitCredentialFill.inconclusive_reason)
    # The three states are mutually exclusive. A result that is more than one of
    # them, or none of them, is a scoring bug rather than a machine property.
    $states = @($gitCredentialFill.credential_supplied, $gitCredentialFill.refused, $gitCredentialFill.inconclusive) |
        Where-Object { $_ }
    if (@($states).Count -ne 1) {
        $failures.Add("credential probe returned " + @($states).Count + " simultaneous states; supplied, refused and inconclusive must be mutually exclusive")
    }
    Write-Output ("self-test: git credential fill output carries no secret | checked password=, password_expiry_utc=, oauth_refresh_token= | clean: " + ([string]($leaked.Count -eq 0)).ToLowerInvariant())
    Write-Output ("self-test: git credential fill stderr | " + $credentialProbeOutput)

    # Fail closed on the one regression this probe has already had. If stdin is
    # not delivered, git answers "refusing to work with credential missing
    # protocol field" -- a malformed-request error, NOT a credential refusal.
    # Test-CredentialRefusal correctly scores it false, so the probe fails
    # rather than passing, but the failure message would blame credentials.
    # This names the real cause instead. That string must never be added to
    # Test-CredentialRefusal's markers.
    $stdinDelivered = -not ($credentialProbeOutput.ToLowerInvariant().Contains("missing protocol field"))
    if (-not $stdinDelivered) {
        $failures.Add("git credential fill received no stdin: git reported 'missing protocol field', so the request never reached it. This is a stdin delivery fault in the probe, not a credential result")
    }
    Write-Output ("self-test: git credential fill stdin delivered | checked for 'missing protocol field' | delivered: " + ([string]$stdinDelivered).ToLowerInvariant())

    # Write boundary, issue #59 criterion 6. The assertion uses a directory that
    # cannot exist, so the result does not depend on whether whoever runs the
    # self-test happens to be elevated. The real run gets the operator's tree
    # through -ForbiddenWritePaths and the machine roots by default.
    # THE ASSERTION IS INVERTED FROM THE PREVIOUS VERSION, deliberately.
    # A nonexistent directory must classify as INCONCLUSIVE, never as refused.
    # The old self-test asserted the opposite, which meant it passed on a
    # machine where the account could write everywhere. Ballot item 4.
    $absent = Join-Path ([Environment]::GetEnvironmentVariable("SystemDrive", "Process") + "\") ("director-selftest-absent-" + [guid]::NewGuid().ToString("N"))
    $boundary = Invoke-WriteBoundaryProbe -Repository (Get-Location).Path -ForbiddenWritePaths @($absent)
    $absentAttempt = @($boundary.attempts | Where-Object { $_.path -eq $absent })
    if ($absentAttempt.Count -ne 1 -or $absentAttempt[0].refused -or -not $absentAttempt[0].inconclusive) {
        $failures.Add("a nonexistent directory must be INCONCLUSIVE, never refused; that misclassification is what let the old probe pass on a machine writable everywhere")
    }
    # A path that genuinely denies access must classify as refused - but ONLY
    # when this process is not elevated. An elevated run can legitimately write
    # into the Windows directory, and asserting a denial unconditionally made
    # the self-test fail for a correct probe depending on how it was launched.
    # That is the same environment-dependence this file has been bitten by
    # twice; the assertion is now conditional and says so when it is skipped.
    $denied = [Environment]::GetFolderPath("Windows")
    $deniedAttempt = @($boundary.attempts | Where-Object { $_.path -eq $denied })
    $selfIsElevated = ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($selfIsElevated) {
        Write-Output ("self-test: refusal path NOT asserted - this session is elevated, so a write into '$denied' may legitimately succeed. Re-run unelevated to exercise it.")
    } elseif ($deniedAttempt.Count -ne 1 -or -not $deniedAttempt[0].refused) {
        $failures.Add("expected an access denial writing into '$denied' and did not observe one; the refusal path is untested")
    }
    if (-not $boundary.executed -or -not $boundary.all_artifacts_removed) {
        $failures.Add("write-boundary probe did not execute, or left an artifact behind")
    }
    if (-not $boundary.any_inconclusive) {
        $failures.Add("the inconclusive path was never exercised, so its scoring is unverified")
    }
    foreach ($attempt in $boundary.attempts) {
        Write-Output ("self-test: write boundary | path: " + $attempt.path + " | refused: " + ([string]$attempt.refused).ToLowerInvariant() + " | inconclusive: " + ([string]$attempt.inconclusive).ToLowerInvariant() + " | " + $attempt.detail + " | artifact removed: " + ([string]$attempt.artifact_removed).ToLowerInvariant())
    }

    # The derived forbidden set, issue #59 criterion 6. What is asserted is the
    # derivation, not the machine: that it ran, that it found the profile root,
    # and that it excluded the three trees a restricted account may legitimately
    # write - its own profile, Public, and Default. Asserting a particular
    # neighbour profile exists would be asserting a property of this machine.
    if (-not [string]::IsNullOrWhiteSpace($boundary.derivation_error)) {
        $failures.Add("write-boundary target derivation failed: " + $boundary.derivation_error)
    }
    if ([string]::IsNullOrWhiteSpace($boundary.profiles_directory)) {
        $failures.Add("write-boundary target derivation returned no profiles directory")
    }
    $ownProfileNormalised = ([string][Environment]::GetEnvironmentVariable("USERPROFILE", "Process")).TrimEnd("\")
    $mustNotBeDerived = @($boundary.derived_profile_targets | Where-Object {
            $leaf = Split-Path -Leaf ([string]$_).TrimEnd("\")
            (@("Public", "Default") -contains $leaf) -or
            (-not [string]::IsNullOrWhiteSpace($ownProfileNormalised) -and
                ([string]$_).TrimEnd("\") -ieq $ownProfileNormalised)
        })
    if ($mustNotBeDerived.Count -gt 0) {
        $failures.Add("derived forbidden set wrongly includes a tree that is writable by design: " + ($mustNotBeDerived -join ", "))
    }
    # Derivation takes no argument, so it cannot depend on
    # -ForbiddenWritePaths - but being derived is worthless if the derived
    # paths are never attempted. Every one of them must appear as an attempt.
    # The probe is NOT run a second time to check this: a second run would
    # write into every machine root and every neighbour profile again to prove
    # something the attempt list already shows.
    $attemptedPaths = @($boundary.attempts | ForEach-Object { ([string]$_.path).TrimEnd("\") })
    $notAttempted = @($boundary.derived_profile_targets | Where-Object {
            $attemptedPaths -notcontains ([string]$_).TrimEnd("\")
        })
    if ($notAttempted.Count -gt 0) {
        $failures.Add("derived forbidden paths were never attempted: " + ($notAttempted -join ", "))
    }
    Write-Output ("self-test: derived forbidden set | profiles directory: " + $boundary.profiles_directory + " | derived: " + @($boundary.derived_profile_targets).Count + " | " + (@($boundary.derived_profile_targets) -join ", "))
    # No assertion for the empty-target case, and that absence is deliberate.
    # The three machine-wide roots are added unconditionally, so the target list
    # cannot be empty and the guard for it is unreachable belt-and-braces. An
    # earlier draft of this self-test "tested" it by passing no forbidden paths,
    # which still produced three targets and asserted nothing -- precisely the
    # check-that-proves-nothing this rework exists to remove. The guard stays in
    # Invoke-WriteBoundaryProbe because a future caller could change the
    # defaults; it is simply not claimed as tested.

    # Baseline citation, issue #59 criterion 7.
    # The repository root is derived from THIS SCRIPT's location, not from the
    # caller's working directory. Using Get-Location made the self-test pass
    # when invoked one way and fail when invoked another, which is the same
    # depends-on-how-you-launched-it fault the stdin defect had.
    $selfTestRoot = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($selfTestRoot)) {
        $selfTestRoot = (Get-Location).Path
    }
    $baselineEvidence = Get-BaselineEvidence -Repository $selfTestRoot
    if (-not $baselineEvidence.all_present) {
        $failures.Add("baseline evidence documents named for comparison are missing from this checkout")
    }
    foreach ($citation in $baselineEvidence.cited) {
        Write-Output ("self-test: baseline cited | " + $citation.path + " | usable: " + ([string]$citation.usable).ToLowerInvariant() + " | bytes: " + $citation.bytes + " | sha256: " + $citation.sha256)
    }
    Write-Output ("self-test: baselines establish | " + $baselineEvidence.establishes)

    $callerGhConfig = Join-Path ([IO.Path]::GetTempPath()) ("director-caller-gh-config-" + [guid]::NewGuid().ToString("N"))
    $previousGhConfig = [Environment]::GetEnvironmentVariable("GH_CONFIG_DIR", "Process")
    $ghConfigIsolation = $false
    try {
        New-Item -ItemType Directory -Path $callerGhConfig -Force | Out-Null
        Set-Item -LiteralPath "Env:GH_CONFIG_DIR" -Value $callerGhConfig
        $ghObservation = Invoke-WithGuardedEnvironment {
            [ordered]@{
                path = [Environment]::GetEnvironmentVariable("GH_CONFIG_DIR", "Process")
                empty = (@(Get-ChildItem -LiteralPath $env:GH_CONFIG_DIR -Force).Count -eq 0)
            }
        }
        $ghConfigIsolation = (
            $ghObservation.empty -and
            $ghObservation.path -ne $callerGhConfig
        )
        if (-not $ghConfigIsolation) {
            $failures.Add("GH_CONFIG_DIR isolation did not replace the caller profile with an empty directory")
        }
    } finally {
        if ($null -eq $previousGhConfig) {
            Remove-Item -LiteralPath "Env:GH_CONFIG_DIR" -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath "Env:GH_CONFIG_DIR" -Value $previousGhConfig
        }
        if (Test-Path -LiteralPath $callerGhConfig) {
            Remove-Item -LiteralPath $callerGhConfig -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Output ("self-test: GH config isolation " + $(if ($ghConfigIsolation) { "OK" } else { "FAIL" }))

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("director-restricted-self-test-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $smokeOkay = $false
    try {
        $smoke = Invoke-SmokeTask -Directory $temp
        $smokeOkay = ($smoke.passed -and $smoke.artifact_removed)
        if (-not $smokeOkay) {
            $failures.Add("smoke helper did not create, read, and remove its artifact")
        }
    } finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Output ("self-test: smoke helper " + $(if ($smokeOkay) { "OK" } else { "FAIL" }))
    Write-Output "self-test: does not establish director-exec (operator must run the launcher)"

    if ($failures.Count -eq 0) {
        Write-Output "restricted-account-probe self-test PASSED"
        $script:SelfTestExitCode = 0
        return
    }
    Write-Output ("restricted-account-probe self-test FAILED: " + (($failures | ForEach-Object { $_ }) -join "; "))
    $script:SelfTestExitCode = 1
}

if ($SelfTest) {
    $script:SelfTestExitCode = 1
    Invoke-SelfTest
    exit $script:SelfTestExitCode
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit) -or $ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "-ExpectedCommit must be a full exact commit SHA for a real restricted-account probe"
}

$WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
Set-Location -LiteralPath $WorkingDirectory -ErrorAction Stop
$evidence = New-ProbeEvidence
$json = $evidence | ConvertTo-Json -Depth 16
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($OutputPath, $json)
}
Write-Output $json
if ($evidence.status -eq "completed") {
    exit 0
}
exit 1
