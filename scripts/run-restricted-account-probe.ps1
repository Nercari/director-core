[CmdletBinding()]
param(
    [string]$Repository,
    [string]$OutputPath,
    [string]$UserName = "director-exec"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Repository)) {
    # Resolve the checkout from this wrapper's location, not the caller's cwd.
    # This keeps the one-step command safe to invoke from C:\Windows\System32.
    $Repository = Join-Path $PSScriptRoot ".."
}
$repositoryPath = (Resolve-Path -LiteralPath $Repository -ErrorAction Stop).Path
$account = Get-LocalUser -Name $UserName -ErrorAction Stop
$expectedSid = [string]$account.SID.Value
$probePath = Join-Path $repositoryPath "scripts\restricted-account-probe.ps1"
$launcherPath = Join-Path $PSScriptRoot "exec-as-account.ps1"
if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    throw "restricted account probe is missing: $probePath"
}
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "account launcher is missing: $launcherPath"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repositoryPath ".director\evidence\restricted-account-probe.json"
}
$probeArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$probePath`" -ExpectedUser $UserName -ExpectedSid $expectedSid -WorkingDirectory `"$repositoryPath`" -Repository `"$repositoryPath`" -OutputPath `"$OutputPath`""
& $launcherPath -UserName $UserName -FilePath "powershell.exe" -ArgumentList $probeArgs -WorkingDirectory $repositoryPath
exit $LASTEXITCODE
