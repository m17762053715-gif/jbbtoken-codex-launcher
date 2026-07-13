$ErrorActionPreference = 'Stop'
$ExpectedVersion = '0.142.2'
$ExpectedSha256 = '44a9afddebcaab04be0e527a9fb3abf54ce021c0cee6e80fcf1442f48ce31f82'
$PackageName = 'codex-windows-x64-offline-package.tar.gz'

function Write-Step([string]$Message) { Write-Host "[JBBToken Codex Offline] $Message" }
function Path-Contains([string]$PathValue, [string]$Entry) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $false }
    $target = [IO.Path]::GetFullPath($Entry).TrimEnd('\')
    foreach ($part in ($PathValue -split ';')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        try { if ([IO.Path]::GetFullPath($part).TrimEnd('\').Equals($target, [StringComparison]::OrdinalIgnoreCase)) { return $true } } catch {}
    }
    return $false
}
function Ensure-Junction([string]$LinkPath, [string]$TargetPath) {
    if (Test-Path -LiteralPath $LinkPath) {
        $item = Get-Item -LiteralPath $LinkPath -Force
        if ($item.LinkType -eq 'Junction' -and $item.Target -and ([string]$item.Target).Equals($TargetPath, [StringComparison]::OrdinalIgnoreCase)) { return }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$LinkPath.bak-jbb-$stamp"
        Move-Item -LiteralPath $LinkPath -Destination $backup -Force
    }
    New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
}

if (-not [Environment]::Is64BitOperatingSystem) { throw 'Codex Windows 离线包需要 64 位 Windows。' }
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') { throw '当前离线包只支持 Windows x64。' }

$scriptDir = Split-Path -Parent $PSCommandPath
$archive = Join-Path $scriptDir $PackageName
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "离线包缺失：$archive" }
$actualSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha -ne $ExpectedSha256) { throw "离线包校验失败。expected=$ExpectedSha256 actual=$actualSha" }

$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $env:USERPROFILE '.codex' } else { $env:CODEX_HOME }
$standaloneRoot = Join-Path $codexHome 'packages\standalone'
$releasesDir = Join-Path $standaloneRoot 'releases'
$releaseName = "$ExpectedVersion-x86_64-pc-windows-msvc"
$releaseDir = Join-Path $releasesDir $releaseName
$currentDir = Join-Path $standaloneRoot 'current'
$visibleBinDir = if ([string]::IsNullOrWhiteSpace($env:CODEX_INSTALL_DIR)) { Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin' } else { $env:CODEX_INSTALL_DIR }

Write-Step "Installing Codex CLI $ExpectedVersion from bundled Windows x64 package"
New-Item -ItemType Directory -Force -Path $releasesDir | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $releaseDir 'bin\codex.exe') -PathType Leaf)) {
    $staging = Join-Path $releasesDir ".staging.$releaseName.$PID"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    tar -xzf $archive -C $staging
    foreach ($required in @('codex-package.json','bin\codex.exe','codex-path\rg.exe','codex-resources\codex-command-runner.exe','codex-resources\codex-windows-sandbox-setup.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $staging $required) -PathType Leaf)) { throw "离线包内容不完整：$required" }
    }
    if (Test-Path -LiteralPath $releaseDir) { Remove-Item -LiteralPath $releaseDir -Recurse -Force }
    Move-Item -LiteralPath $staging -Destination $releaseDir
}

New-Item -ItemType Directory -Force -Path $standaloneRoot | Out-Null
Ensure-Junction -LinkPath $currentDir -TargetPath $releaseDir
$visibleParent = Split-Path -Parent $visibleBinDir
New-Item -ItemType Directory -Force -Path $visibleParent | Out-Null
Ensure-Junction -LinkPath $visibleBinDir -TargetPath (Join-Path $currentDir 'bin')

$codexExe = Join-Path $visibleBinDir 'codex.exe'
$versionOutput = (& $codexExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch [regex]::Escape($ExpectedVersion)) { throw "Codex 验证失败：$versionOutput" }

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (Path-Contains -PathValue $userPath -Entry $visibleBinDir)) {
    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $visibleBinDir } else { "$visibleBinDir;$userPath" }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    Write-Step 'PATH updated for future PowerShell sessions.'
}
if (-not (Path-Contains -PathValue $env:Path -Entry $visibleBinDir)) { $env:Path = "$visibleBinDir;$env:Path" }
Write-Host "Codex CLI $ExpectedVersion installed successfully."
