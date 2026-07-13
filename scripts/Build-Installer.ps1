param(
    [string]$OutputDirectory,
    [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'artifacts'
}
$buildRoot = Join-Path $repoRoot 'build'
$payloadRoot = Join-Path $buildRoot 'payload'
$packageName = 'codex-windows-x64-offline-package.tar.gz'
$packagePath = Join-Path $payloadRoot $packageName
$packageUrl = 'https://github.com/openai/codex/releases/download/rust-v0.142.2/codex-package-x86_64-pc-windows-msvc.tar.gz'
$packageSha256 = '44a9afddebcaab04be0e527a9fb3abf54ce021c0cee6e80fcf1442f48ce31f82'
$installerName = 'JBBToken-Codex-Setup-v1.1.34-dropdown-panel-win64.exe'

& (Join-Path $PSScriptRoot 'Test-Source.ps1')

New-Item -ItemType Directory -Force -Path $payloadRoot, $OutputDirectory | Out-Null
foreach ($name in @('CodexCLI-Launcher.ps1','CodexCLI-Launcher.vbs','Install-CodexOffline-Win64.ps1','Launch-CodexCLI.cmd')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot "src\$name") -Destination (Join-Path $payloadRoot $name) -Force
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $payloadRoot 'THIRD_PARTY_NOTICES.md') -Force

if (-not $SkipDownload -or -not (Test-Path -LiteralPath $packagePath)) {
    Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $packagePath -TimeoutSec 900
}
$actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $packageSha256) {
    throw "OpenAI Codex package hash mismatch. expected=$packageSha256 actual=$actualHash"
}

$targetPath = Join-Path $OutputDirectory $installerName
$sedPath = Join-Path $buildRoot 'JBBToken-Codex-Setup.sed'
$escapedPayload = $payloadRoot
$escapedTarget = $targetPath
$files = @(
    'CodexCLI-Launcher.ps1',
    'CodexCLI-Launcher.vbs',
    'Install-CodexOffline-Win64.ps1',
    'Launch-CodexCLI.cmd',
    'THIRD_PARTY_NOTICES.md',
    $packageName
)
$stringLines = for ($i = 0; $i -lt $files.Count; $i++) { "FILE$i=`"$($files[$i])`"" }
$fileLines = for ($i = 0; $i -lt $files.Count; $i++) { "%FILE$i%=" }
$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3

[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$escapedTarget
FriendlyName=JBBToken Codex CLI Setup v1.1.34
AppLaunched=wscript.exe CodexCLI-Launcher.vbs
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles

[SourceFiles]
SourceFiles0=$escapedPayload\

[SourceFiles0]
$($fileLines -join [Environment]::NewLine)

[Strings]
$($stringLines -join [Environment]::NewLine)
"@
[IO.File]::WriteAllText($sedPath, $sed, [Text.Encoding]::Default)

$iexpress = Join-Path $env:SystemRoot 'System32\iexpress.exe'
if (-not (Test-Path -LiteralPath $iexpress)) { throw "IExpress not found: $iexpress" }
$process = Start-Process -FilePath $iexpress -ArgumentList @('/N','/Q',('"' + $sedPath + '"')) -Wait -PassThru
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $targetPath)) {
    throw "IExpress build failed with exit code $($process.ExitCode)"
}

$hash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
Write-Host "Built: $targetPath"
Write-Host "SHA256: $hash"
