[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExecutorPath,
    [Parameter(Mandatory = $true)][string]$ProbePath,
    [Parameter(Mandatory = $true)][string]$ExpectedUser,
    [Parameter(Mandatory = $true)][string]$ExpectedSid,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$ExecutorBinDirectory,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($path in @($ExecutorPath, $ProbePath)) {
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
if (-not (Test-Path -LiteralPath $ExecutorBinDirectory -PathType Container)) {
    throw "executor binary directory is missing: $ExecutorBinDirectory"
}

& $ExecutorPath "login" "--device-auth"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ProbePath `
    -ExpectedUser $ExpectedUser `
    -ExpectedSid $ExpectedSid `
    -WorkingDirectory $WorkingDirectory `
    -Repository $Repository `
    -ExecutorBinDirectory $ExecutorBinDirectory `
    -OutputPath $OutputPath
exit $LASTEXITCODE
