[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$ExpectedUser = "director-exec",
    [string]$ExpectedSid,
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$Repository,
    [string]$ExecutorCommand = "codex",
    [string]$OutputPath
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
            try {
                Remove-Item -LiteralPath $artifact -Force -ErrorAction Stop
                $result.artifact_removed = $true
            } catch {
                $result.artifact_removed = $false
            }
        } else {
            $result.artifact_removed = $true
        }
    }
    return $result
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
            credential_refused = $false
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
        credential_refused = (Test-CredentialRefusal $result)
        exit_code = $result.exit_code
        output = [string]$result.output
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
    $gh = Get-ToolEvidence -Name "gh"
    $credentials = Get-CredentialEvidence -GitPath $(if ($git.present) { $git.path } else { "" })
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
    if (-not $profileMatchesExpectedUser) {
        $failures.Add("USERPROFILE does not identify the expected restricted user")
    }
    if (-not $git.present) {
        $failures.Add("required tool 'git' is not resolvable")
    }
    if (-not $executor.present) {
        $failures.Add("required executor '$ExecutorCommand' is not resolvable")
    }
    if (-not $smoke.passed) {
        $failures.Add("deterministic no-network smoke task failed")
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
        credential_refused = $false
        exit_code = 1
        output = "not run; -Repository is required for the real account probe"
    }
    if ([string]::IsNullOrWhiteSpace($Repository)) {
        $failures.Add("-Repository is required to prove a credential-free git push refusal")
    } else {
        $pushProbe = Invoke-GitPushProbe -GitPath $(if ($git.present) { $git.path } else { "" }) -RepositoryPath $Repository
        if (-not $pushProbe.executed) {
            $failures.Add("git push probe could not execute")
        } elseif (-not $pushProbe.credential_refused) {
            $failures.Add("git push --dry-run did not refuse without credentials")
        }
    }

    return [ordered]@{
        schema_version = "director.restricted-account-evidence.v1"
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
