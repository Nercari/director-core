[CmdletBinding()]
param(
    [string]$Repository,
    [string]$OutputPath,
    [string]$UserName = "director-exec",
    [string]$ExecutorPath,
    [switch]$RestrictedLoginChild,
    [switch]$Login
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryWasExplicit = -not [string]::IsNullOrWhiteSpace($Repository)
if ([string]::IsNullOrWhiteSpace($Repository)) {
    # Resolve the checkout from this wrapper's location, not the caller's cwd.
    # This keeps the one-step command safe to invoke from C:\Windows\System32.
    $Repository = Join-Path $PSScriptRoot ".."
}
$repositoryPath = (Resolve-Path -LiteralPath $Repository -ErrorAction Stop).Path
$wrapperPath = (Resolve-Path -LiteralPath $PSCommandPath -ErrorAction Stop).Path
$account = Get-LocalUser -Name $UserName -ErrorAction Stop
$expectedSid = [string]$account.SID.Value
$probePath = Join-Path $repositoryPath "scripts\restricted-account-probe.ps1"
$launcherPath = Join-Path $PSScriptRoot "exec-as-account.ps1"
$loginRunnerPath = Join-Path $PSScriptRoot "login-and-run-restricted-probe.ps1"
if ($RestrictedLoginChild) {
    if ([string]::IsNullOrWhiteSpace($ExecutorPath)) {
        throw "ExecutorPath is required for restricted login child mode"
    }
    $resolvedExecutorPath = (Resolve-Path -LiteralPath $ExecutorPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedExecutorPath -PathType Leaf)) {
        throw "Codex CLI is missing: $resolvedExecutorPath"
    }
    $executor = [pscustomobject]@{ Source = $resolvedExecutorPath }
} else {
    $executor = Get-Command -Name "codex" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -in @("Application", "ExternalScript") } |
        Select-Object -First 1
    if ($null -eq $executor) {
        throw "Codex CLI is not resolvable for the launcher account"
    }
}
$executorBinDirectory = Split-Path -Parent ([string]$executor.Source)
if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    throw "restricted account probe is missing: $probePath"
}
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "account launcher is missing: $launcherPath"
}
if (-not (Test-Path -LiteralPath $loginRunnerPath -PathType Leaf)) {
    throw "login-and-probe runner is missing: $loginRunnerPath"
}

$outputWasExplicit = -not [string]::IsNullOrWhiteSpace($OutputPath)
if (-not $outputWasExplicit) {
    $OutputPath = Join-Path $repositoryPath ".director\evidence\restricted-account-probe.json"
}

if ($RestrictedLoginChild) {
    & $loginRunnerPath `
        -ExecutorPath ([string]$executor.Source) `
        -ProbePath $probePath `
        -ExpectedUser $UserName `
        -ExpectedSid $expectedSid `
        -WorkingDirectory $repositoryPath `
        -Repository $repositoryPath `
        -ExecutorBinDirectory $executorBinDirectory `
        -OutputPath $OutputPath
    exit $LASTEXITCODE
}

if ($Login) {
    $runAsUser = if ($UserName -match "\\") { $UserName } else { "$env:COMPUTERNAME\$UserName" }
    $bootstrapArguments = @(
        "-UserName `"$UserName`""
        "-ExecutorPath `"$($executor.Source)`""
    )
    if ($repositoryWasExplicit) {
        $bootstrapArguments += "-Repository `"$repositoryPath`""
    }
    if ($outputWasExplicit) {
        $bootstrapArguments += "-OutputPath `"$OutputPath`""
    }
    # runas mis-parses a long program string when quoted paths contain both
    # spaces and drive-letter colons. Keep only a short re-entry bootstrap in
    # an audit-friendly UTF-16LE payload; the child derives its own paths.
    $loginPayload = @"
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`" -RestrictedLoginChild $($bootstrapArguments -join ' ')
exit `$LASTEXITCODE
"@
    $loginEncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($loginPayload))
    $loginCommand = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $loginEncodedCommand"
    if (($loginCommand.Length + 1) -gt 1024) {
        throw "restricted login bootstrap exceeds the runas command limit: $($loginCommand.Length + 1) characters"
    }
    $runAsPath = Join-Path $env:SystemRoot "System32\runas.exe"
    & $runAsPath "/profile" "/user:$runAsUser" $loginCommand
    exit $LASTEXITCODE
}

$probeArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$probePath`" -ExpectedUser $UserName -ExpectedSid $expectedSid -WorkingDirectory `"$repositoryPath`" -Repository `"$repositoryPath`" -ExecutorBinDirectory `"$executorBinDirectory`" -OutputPath `"$OutputPath`""
& $launcherPath -UserName $UserName -FilePath "powershell.exe" -ArgumentList $probeArgs -WorkingDirectory $repositoryPath
exit $LASTEXITCODE
