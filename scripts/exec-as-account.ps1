[CmdletBinding()]
param(
    [string]$UserName = "director-exec",
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string]$ArgumentList = "",
    [string]$WorkingDirectory = (Get-Location).Path,
    [switch]$Interactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Redact-Text {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) {
        return ""
    }
    $redacted = $Value
    foreach ($pattern in @(
        '(?i)(gho|ghp|ghs|ghr|github_pat)_[A-Za-z0-9_\-]+',
        '(?i)(x-access-token:|authorization\s*:\s*bearer\s+)[^\s,;]+',
        '(?i)(token|password|passwd|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+'
    )) {
        $redacted = [regex]::Replace($redacted, $pattern, "`$1[REDACTED]")
    }
    return $redacted
}

$resolvedFilePath = $null
if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
    $resolvedFilePath = (Resolve-Path -LiteralPath $FilePath).Path
} else {
    $command = Get-Command -Name $FilePath -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandType -in @("Application", "ExternalScript") } |
        Select-Object -First 1
    if ($null -ne $command) {
        $resolvedFilePath = [string]$command.Source
    }
}
if ([string]::IsNullOrWhiteSpace($resolvedFilePath)) {
    throw "launcher target does not exist or is not resolvable: $FilePath"
}
if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    throw "launcher working directory does not exist: $WorkingDirectory"
}
if ($ArgumentList -match '(?i)(gho|ghp|ghs|ghr|github_pat)_[A-Za-z0-9_\-]+|GH_TOKEN\s*=|GITHUB_TOKEN\s*=|OPENAI_API_KEY\s*=|ANTHROPIC_API_KEY\s*=') {
    throw "refusing to pass credential-shaped material to the restricted account"
}
$resolvedLaunchCommand = '"' + $resolvedFilePath + '"'
if (-not [string]::IsNullOrWhiteSpace($ArgumentList)) {
    $resolvedLaunchCommand += " " + $ArgumentList
}
$resolvedLaunchCommandLength = $resolvedLaunchCommand.Length
if ($resolvedLaunchCommandLength -gt 1024) {
    throw "credentialed launch command is too long ($resolvedLaunchCommandLength characters; maximum 1024). Remediation: invoke the tracked -File bootstrap instead of embedding a long command payload"
}

Write-Output "Starting '$resolvedFilePath' as '$UserName'. The password is requested interactively and is not stored by this script."
$securePassword = $null
$credential = $null
$temporary = $null
$stdoutPath = $null
$stderrPath = $null
$child = $null
$startParameters = $null
$temporaryCreated = $false
$pathKeys = @([Environment]::GetEnvironmentVariables("Process").Keys | Where-Object { $_ -ieq "Path" })
$pathValue = [Environment]::GetEnvironmentVariable("Path", "Process")
$childExitCode = $null
$primaryError = $null
$cleanupError = $null
try {
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        throw "credential prompt requires an interactive console; refusing noninteractive or redirected input"
    }
    try {
        $securePassword = Read-Host -Prompt "Enter the password for $UserName. Do not paste API keys here." -AsSecureString
    } catch {
        throw "credential prompt was cancelled or unavailable; no credential was acquired"
    }
    if ($null -eq $securePassword -or $securePassword.Length -eq 0) {
        throw "credential prompt returned an empty password; refusing to launch"
    }
    $credential = [PSCredential]::new($UserName, $securePassword)
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("director-account-launch-" + [guid]::NewGuid().ToString("N"))
    if (Test-Path -LiteralPath $temporary) {
        throw "temporary launch directory candidate already exists; refusing to reuse it"
    }
    New-Item -ItemType Directory -Path $temporary -Force -ErrorAction Stop | Out-Null
    $temporaryCreated = $true
    $stdoutPath = Join-Path $temporary "stdout.txt"
    $stderrPath = Join-Path $temporary "stderr.txt"

    # Windows PowerShell 5.1's Start-Process -Credential builds a case-insensitive
    # environment dictionary. Codex can expose both Path and PATH, which makes
    # that API fail before logon. Canonicalize only this duplicate for the child,
    # then restore the caller's exact environment in finally.
    if ($pathKeys.Count -gt 1) {
        foreach ($key in $pathKeys) {
            Remove-Item -LiteralPath "Env:$key" -ErrorAction SilentlyContinue
        }
        Set-Item -LiteralPath "Env:Path" -Value $pathValue
    }
    $startParameters = @{
        FilePath = $resolvedFilePath
        ArgumentList = $ArgumentList
        WorkingDirectory = $WorkingDirectory
        Credential = $credential
        Wait = $true
        PassThru = $true
    }
    if (-not $Interactive) {
        $startParameters.RedirectStandardOutput = $stdoutPath
        $startParameters.RedirectStandardError = $stderrPath
    } else {
        $startParameters.WindowStyle = "Normal"
    }
    if ((Get-Command -Name Start-Process).Parameters.ContainsKey("LoadUserProfile")) {
        $startParameters.LoadUserProfile = $true
    }
    $child = Start-Process @startParameters
    $credential = $null
    $startParameters = $null
    if (-not $Interactive -and (Test-Path -LiteralPath $stdoutPath)) {
        $output = Get-Content -LiteralPath $stdoutPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            Write-Output (Redact-Text $output).TrimEnd()
        }
    }
    if (-not $Interactive -and (Test-Path -LiteralPath $stderrPath)) {
        $errorOutput = Get-Content -LiteralPath $stderrPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($errorOutput)) {
            [Console]::Error.WriteLine((Redact-Text $errorOutput).TrimEnd())
        }
    }
    if ($Interactive) {
        Write-Output ("Interactive restricted-account process exited with code " + [int]$child.ExitCode + ".")
    }
    $childExitCode = [int]$child.ExitCode
} catch {
    $primaryError = $_
} finally {
    try {
        if ($null -ne $securePassword) {
            $securePassword.Dispose()
        }
    } catch {
        if ($null -eq $cleanupError) {
            $cleanupError = $_
        }
    }
    $securePassword = $null
    $credential = $null
    $startParameters = $null
    try {
        if ($pathKeys.Count -gt 1) {
            Remove-Item -LiteralPath "Env:Path" -ErrorAction Stop
            foreach ($key in $pathKeys) {
                Set-Item -LiteralPath "Env:$key" -Value $pathValue
            }
        }
    } catch {
        if ($null -eq $cleanupError) {
            $cleanupError = $_
        }
    }
    try {
        if ($temporaryCreated -and $null -ne $temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction Stop
        }
    } catch {
        if ($null -eq $cleanupError) {
            $cleanupError = $_
        }
    }
}
if ($null -ne $primaryError) {
    throw $primaryError
}
if ($null -ne $cleanupError -and ($null -eq $childExitCode -or $childExitCode -eq 0)) {
    throw $cleanupError
}
if ($null -ne $childExitCode) {
    exit $childExitCode
}
throw "restricted-account process did not produce an exit code"
