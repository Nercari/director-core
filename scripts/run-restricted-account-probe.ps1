[CmdletBinding()]
param(
    [string]$Repository,
    [string]$OutputPath,
    [string]$UserName = "director-exec",
    [string]$ExpectedCommit,
    [switch]$RestrictedLoginChild,
    [switch]$Login
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AccountLeaf {
    param([Parameter(Mandatory = $true)][string]$Account)
    return (($Account -split "\\")[-1]).Trim()
}

function Get-ResolvedCommit {
    param([Parameter(Mandatory = $true)][string]$RepositoryPath)

    $git = Get-Command -Name "git" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -eq "Application" } |
        Select-Object -First 1
    if ($null -eq $git) {
        throw "git is not resolvable from the current account's PATH"
    }
    $commit = [string](& $git.Source -C $RepositoryPath rev-parse --verify HEAD 2>&1).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "repository does not expose a full exact HEAD commit: $RepositoryPath"
    }
    return $commit.ToLowerInvariant()
}

$account = Get-LocalUser -Name (Get-AccountLeaf $UserName) -ErrorAction Stop
$expectedSid = [string]$account.SID.Value
$accountLeaf = Get-AccountLeaf $UserName
$profileRoot = (Join-Path "C:\Users" $accountLeaf).TrimEnd("\")

if ($RestrictedLoginChild) {
    # The restricted child always derives its repository and scripts from the
    # tracked checkout that launched this file, never from operator arguments.
    $repositoryPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
    if (-not $repositoryPath.StartsWith($profileRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "restricted login child must run from a clean clone below $profileRoot"
    }
    if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "restricted login child requires a full exact expected commit SHA"
    }
    $ExpectedCommit = $ExpectedCommit.ToLowerInvariant()
    $childCommit = Get-ResolvedCommit -RepositoryPath $repositoryPath
    if ($childCommit -cne $ExpectedCommit) {
        throw "restricted login child clone commit does not match the expected full SHA: expected $ExpectedCommit, found $childCommit"
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $actualAccount = Get-AccountLeaf ([string]$identity.Name)
    if ($actualAccount -ine $accountLeaf) {
        throw "restricted login child is running under '$actualAccount', not '$accountLeaf'"
    }
    $actualSid = if ($null -ne $identity.User) { [string]$identity.User.Value } else { "" }
    if ($actualSid -cne $expectedSid) {
        throw "restricted login child SID does not match the expected restricted account SID"
    }
} else {
    if ([string]::IsNullOrWhiteSpace($Repository)) {
        $Repository = Join-Path $PSScriptRoot ".."
    }
    $repositoryPath = (Resolve-Path -LiteralPath $Repository -ErrorAction Stop).Path
    $ExpectedCommit = Get-ResolvedCommit -RepositoryPath $repositoryPath
}

$probePath = Join-Path $repositoryPath "scripts\restricted-account-probe.ps1"
$launcherPath = Join-Path $PSScriptRoot "exec-as-account.ps1"
$loginRunnerPath = Join-Path $repositoryPath "scripts\login-and-run-restricted-probe.ps1"
if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    throw "restricted account probe is missing: $probePath"
}
if (-not $RestrictedLoginChild -and -not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "account launcher is missing: $launcherPath"
}
if (-not (Test-Path -LiteralPath $loginRunnerPath -PathType Leaf)) {
    throw "login-and-probe runner is missing: $loginRunnerPath"
}

if ($RestrictedLoginChild) {
    $childOutputPath = Join-Path $repositoryPath ".director\evidence\restricted-account-probe.json"
    & $loginRunnerPath `
        -ProbePath $probePath `
        -ExpectedUser $UserName `
        -ExpectedSid $expectedSid `
        -WorkingDirectory $repositoryPath `
        -Repository $repositoryPath `
        -ExpectedCommit $ExpectedCommit `
        -OutputPath $childOutputPath
    exit $LASTEXITCODE
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryPath ".director\evidence\restricted-account-probe.json"
}

if ($Login) {
    $cleanClonePath = Join-Path $profileRoot "director-core-issue-59"
    $cleanClonePath = (Resolve-Path -LiteralPath $cleanClonePath -ErrorAction Stop).Path
    $cleanCloneCommit = Get-ResolvedCommit -RepositoryPath $cleanClonePath
    if ($cleanCloneCommit -cne $ExpectedCommit) {
        throw "clean clone commit does not match the expected full SHA: expected $ExpectedCommit, found $cleanCloneCommit"
    }
    $childScriptPath = Join-Path $cleanClonePath "scripts\run-restricted-account-probe.ps1"
    if (-not (Test-Path -LiteralPath $childScriptPath -PathType Leaf)) {
        throw "clean clone bootstrap is missing: $childScriptPath"
    }

    $runAsUser = if ($UserName -match "\\") { $UserName } else { "$env:COMPUTERNAME\$accountLeaf" }
    $loginCommand = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$childScriptPath`" -RestrictedLoginChild -UserName `"$UserName`" -ExpectedCommit $ExpectedCommit"
    if (($loginCommand.Length + 1) -gt 1024) {
        throw "restricted login bootstrap exceeds the runas command limit: $($loginCommand.Length + 1) characters"
    }
    $runAsPath = Join-Path $env:SystemRoot "System32\runas.exe"
    & $runAsPath "/profile" "/user:$runAsUser" $loginCommand
    exit $LASTEXITCODE
}

$probeArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$probePath`" -ExpectedUser $UserName -ExpectedSid $expectedSid -ExpectedCommit $ExpectedCommit -WorkingDirectory `"$repositoryPath`" -Repository `"$repositoryPath`" -OutputPath `"$OutputPath`""
& $launcherPath -UserName $UserName -FilePath "powershell.exe" -ArgumentList $probeArgs -WorkingDirectory $repositoryPath
exit $LASTEXITCODE
