$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceFiles = @(
    'src\CodexCLI-Launcher.ps1',
    'src\Install-CodexOffline-Win64.ps1',
    'scripts\Build-Installer.ps1',
    'scripts\Test-Source.ps1'
)

foreach ($relative in $sourceFiles) {
    $path = Join-Path $repoRoot $relative
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $messages = $errors | ForEach-Object { "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" }
        throw ($messages -join [Environment]::NewLine)
    }
}

$launcher = Get-Content -LiteralPath (Join-Path $repoRoot 'src\CodexCLI-Launcher.ps1') -Raw
$requiredMarkers = @(
    "`$script:AppVersion = 'v1.1.34-dropdown-panel-win64'",
    'https://downstream.jbbtoken.cn/api/desktop/codex',
    'function Invoke-JbbConfigureCodex'
)
foreach ($marker in $requiredMarkers) {
    if (-not $launcher.Contains($marker)) { throw "Required launcher marker missing: $marker" }
}

$forbiddenPatterns = @(
    '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----',
    '(?i)\bsk-[A-Za-z0-9_-]{16,}',
    '(?i)\bAKIA[0-9A-Z]{16}\b',
    '(?i)(client_secret|api_key|password)\s*=\s*["''][^"'']{12,}["'']'
)
$allText = Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
    Where-Object { $_.Length -lt 5MB -and $_.Extension -notin @('.exe', '.dll') } |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue }
foreach ($pattern in $forbiddenPatterns) {
    if (($allText -join "`n") -match $pattern) { throw "Potential secret matched forbidden pattern: $pattern" }
}

Write-Host 'Source validation passed.'
