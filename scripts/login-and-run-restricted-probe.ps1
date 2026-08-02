[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProbePath,
    [Parameter(Mandatory = $true)][string]$ExpectedUser,
    [Parameter(Mandatory = $true)][string]$ExpectedSid,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($path in @($ProbePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "required file is missing: $path"
    }
}
if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    throw "working directory is missing: $WorkingDirectory"
}
if (-not (Test-Path -LiteralPath $Repository -PathType Container)) {
    throw "repository is missing: $Repository"
}
if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "a full exact expected commit SHA is required"
}

$git = Get-Command -Name "git" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandType -eq "Application" } |
    Select-Object -First 1
$executor = Get-Command -Name "codex" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandType -in @("Application", "ExternalScript") } |
    Select-Object -First 1
if ($null -eq $git) {
    throw "git is not resolvable from the restricted account's own PATH"
}
if ($null -eq $executor) {
    throw "codex is not resolvable from the restricted account's own PATH"
}

& $executor.Source "login" "--device-auth"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ProbePath `
    -ExpectedUser $ExpectedUser `
    -ExpectedSid $ExpectedSid `
    -ExpectedCommit $ExpectedCommit `
    -WorkingDirectory $WorkingDirectory `
    -Repository $Repository `
    -OutputPath $OutputPath
exit $LASTEXITCODE
