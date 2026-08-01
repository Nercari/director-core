[CmdletBinding()]
param(
    [string]$UserName = "director-exec",
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string]$ArgumentList = "",
    [string]$WorkingDirectory = (Get-Location).Path
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

Write-Output "Starting '$resolvedFilePath' as '$UserName'. The password is requested interactively and is not stored by this script."
$credential = Get-Credential -UserName $UserName -Message "Enter the password for the dedicated restricted executor account. Do not paste API keys here."
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("director-account-launch-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporary -Force | Out-Null
$stdoutPath = Join-Path $temporary "stdout.txt"
$stderrPath = Join-Path $temporary "stderr.txt"
$child = $null
$pathKeys = @([Environment]::GetEnvironmentVariables("Process").Keys | Where-Object { $_ -ieq "Path" })
$pathValue = [Environment]::GetEnvironmentVariable("Path", "Process")
try {
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
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError = $stderrPath
        Wait = $true
        PassThru = $true
    }
    if ((Get-Command -Name Start-Process).Parameters.ContainsKey("LoadUserProfile")) {
        $startParameters.LoadUserProfile = $true
    }
    $child = Start-Process @startParameters
    if (Test-Path -LiteralPath $stdoutPath) {
        $output = Get-Content -LiteralPath $stdoutPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($output)) {
            Write-Output (Redact-Text $output).TrimEnd()
        }
    }
    if (Test-Path -LiteralPath $stderrPath) {
        $errorOutput = Get-Content -LiteralPath $stderrPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($errorOutput)) {
            [Console]::Error.WriteLine((Redact-Text $errorOutput).TrimEnd())
        }
    }
    exit ([int]$child.ExitCode)
} finally {
    Remove-Variable -Name credential -ErrorAction SilentlyContinue
    if ($pathKeys.Count -gt 1) {
        Remove-Item -LiteralPath "Env:Path" -ErrorAction SilentlyContinue
        foreach ($key in $pathKeys) {
            Set-Item -LiteralPath "Env:$key" -Value $pathValue
        }
    }
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
