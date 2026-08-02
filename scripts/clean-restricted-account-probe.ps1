[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Remote,
    [Parameter(Mandatory = $true)][string]$Branch,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$ExpectedSid,
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [string]$UserName = "director-exec"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AccountLeaf {
    param([Parameter(Mandatory = $true)][string]$Account)
    return (($Account -split "\\")[-1]).Trim()
}

function Get-Tool {
    param([Parameter(Mandatory = $true)][string]$Name)
    $tool = Get-Command -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -eq "Application" } |
        Select-Object -First 1
    if ($null -eq $tool) {
        throw "$Name is not resolvable from the operator PATH"
    }
    return $tool
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][object]$Git,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $output = @(& $Git.Source @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw "git command failed with exit code ${LASTEXITCODE}: $($output -join "`n")"
    }
    return (($output -join "`n").Trim())
}

function Invoke-Icacls {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $icacls = Join-Path $env:SystemRoot "System32\icacls.exe"
    if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) {
        throw "icacls is missing: $icacls"
    }
    $output = @(& $icacls @Arguments 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed with exit code ${LASTEXITCODE}: $($output -join "`n")"
    }
    return (($output -join "`n").Trim())
}

if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "a full exact expected commit SHA is required"
}
if ($ExpectedSid -notmatch '^S-1-[0-9-]+$') {
    throw "a full expected account SID is required"
}
if ([string]::IsNullOrWhiteSpace($Remote) -or [string]::IsNullOrWhiteSpace($Branch)) {
    throw "remote and branch are required"
}

$accountLeaf = Get-AccountLeaf $UserName
$account = Get-LocalUser -Name $accountLeaf -ErrorAction Stop
if ([string]$account.SID.Value -cne $ExpectedSid) {
    throw "local account SID does not match the expected restricted account SID"
}
$operatorIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$operatorPrincipal = New-Object Security.Principal.WindowsPrincipal($operatorIdentity)
if (-not $operatorPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "operator elevation is required to set the owner and scoped ACL on the proof clone; remediation: reopen PowerShell as Administrator and rerun this setup"
}

$git = Get-Tool -Name "git"
$workspaceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
$accountLauncher = Join-Path $workspaceRoot "scripts\exec-as-account.ps1"
if (-not (Test-Path -LiteralPath $accountLauncher -PathType Leaf)) {
    throw "account launcher is missing: $accountLauncher"
}

$target = [IO.Path]::GetFullPath($TargetPath)
$profileRoot = [IO.Path]::GetFullPath((Join-Path "C:\Users" $accountLeaf)).TrimEnd("\")
if (-not $target.StartsWith($profileRoot + "\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "proof clone must be below the restricted account profile: $target"
}
if (Test-Path -LiteralPath $target) {
    throw "refusing to reuse an existing proof-clone path: $target"
}
$parent = Split-Path -Parent $target
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    throw "restricted profile path is not usable: $parent"
}

& $git.Source clone --branch $Branch --single-branch $Remote $target
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$actualCommit = Invoke-Git -Git $git -Arguments @("-C", $target, "rev-parse", "--verify", "HEAD")
$actualRemote = Invoke-Git -Git $git -Arguments @("-C", $target, "remote", "get-url", "origin")
$initialStatus = @(& $git.Source -C $target status --porcelain --untracked-files=all 2>&1 | ForEach-Object { [string]$_ })
if ($LASTEXITCODE -ne 0) {
    throw "clean-clone status could not be inspected: $($initialStatus -join "`n")"
}
$initialStatusText = ($initialStatus -join "`n").Trim()
if ($actualCommit -cne $ExpectedCommit) {
    throw "proof clone commit mismatch: expected $ExpectedCommit, found $actualCommit"
}
if ($actualRemote -cne $Remote) {
    throw "proof clone remote mismatch: expected $Remote, found $actualRemote"
}
if (-not [string]::IsNullOrWhiteSpace($initialStatusText)) {
    throw "proof clone is not clean before evidence setup: $initialStatusText"
}

$evidenceDirectory = Join-Path $target ".director\evidence"
$evidencePath = Join-Path $evidenceDirectory "restricted-account-probe.json"
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
$manifest = [ordered]@{
    kind = "director-clean-clone-preflight"
    generated_utc = (Get-Date).ToUniversalTime().ToString("o")
    repository = $target
    remote = $actualRemote
    branch = $Branch
    expected_commit = $ExpectedCommit
    actual_commit = $actualCommit
    owner_before_scope = [string](Get-Acl -LiteralPath $target -ErrorAction Stop).Owner
    expected_user = $UserName
    expected_sid = $ExpectedSid
    initial_status = $initialStatusText
    evidence_path = $evidencePath
}
[IO.File]::WriteAllText((Join-Path $target ".director\clean-clone-preflight.json"), ($manifest | ConvertTo-Json -Depth 8))

Invoke-Icacls -Arguments @($target, "/setowner", $UserName, "/T", "/C") | Out-Null
Invoke-Icacls -Arguments @($target, "/grant", "${UserName}:(OI)(CI)M", "/T", "/C") | Out-Null
$ownerAfterScope = [string](Get-Acl -LiteralPath $target -ErrorAction Stop).Owner
if ((Get-AccountLeaf $ownerAfterScope) -ine $accountLeaf) {
    throw "proof clone owner mismatch after scoped ownership change: $ownerAfterScope"
}

$childScriptPath = Join-Path $target "scripts\run-restricted-account-probe.ps1"
foreach ($requiredPath in @(
    $childScriptPath,
    (Join-Path $target "scripts\login-and-run-restricted-probe.ps1"),
    (Join-Path $target "scripts\restricted-account-probe.ps1")
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "required proof-clone path is missing: $requiredPath"
    }
}

$childArguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$childScriptPath`" -RestrictedLoginChild -UserName `"$UserName`" -ExpectedCommit $ExpectedCommit"
if ($childArguments.Length -gt 1024) {
    throw "restricted child bootstrap unexpectedly exceeds the 1024-character limit"
}
& $accountLauncher `
    -UserName $UserName `
    -FilePath "powershell.exe" `
    -ArgumentList $childArguments `
    -WorkingDirectory "C:\Windows\System32" `
    -Interactive
exit $LASTEXITCODE
