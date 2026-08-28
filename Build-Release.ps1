#requires -Version 7
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$CodeSigningThumbprint = '',
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionLine = Select-String -LiteralPath (Join-Path $root 'TelegramBridge.ps1') -Pattern "BridgeVersion = '([^']+)'" | Select-Object -First 1
    if (-not $versionLine) { throw 'Could not determine BridgeVersion.' }
    $Version = $versionLine.Matches[0].Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
    throw "Invalid release version '$Version'."
}

if (-not $SkipChecks) {
    & (Join-Path $root 'Run-Checks.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Release checks failed.' }
}

$allowList = @(
    'Parts\Bridge.Core.ps1', 'Parts\Bridge.Telegram.ps1', 'Parts\Bridge.News.ps1', 'Parts\Bridge.Users.ps1', 'Parts\Bridge.Templates.ps1', 'Parts\Bridge.OnAir.ps1', 'Parts\Bridge.Schedule.ps1', 'Parts\Bridge.Keyboards.ps1', 'Parts\Bridge.ShowFlow.ps1', 'Parts\Bridge.Admin.ps1', 'Parts\Bridge.Media.ps1', 'Parts\Bridge.Commands.ps1', 'Parts\Bridge.Callbacks.ps1', 'Parts\Bridge.Tick.ps1',
    'TelegramBridge.ps1', 'Modules\CinegyAirTitler.psm1', 'Modules\BridgeSecurity.psm1', 'Modules\BridgeSettings.psm1', 'Modules\BridgeStorage.psm1', 'Modules\BridgeTelegram.psm1', 'Modules\BridgeAuthorization.psm1', 'Modules\BridgeFlowState.psm1', 'Modules\BridgeCinegyState.psm1', 'Modules\BridgeSchedulePolicy.psm1', 'Modules\BridgeMedia.psm1', 'Modules\BridgeRelayPolicy.psm1', 'Modules\BridgeRuntimeState.psm1', 'Modules\BridgeNewsTicker.psm1', 'Modules\BridgeOperationPolicy.psm1', 'Modules\BridgeSettingsSchema.psm1', 'Modules\BridgeStateMigration.psm1', 'Modules\BridgeUiPaging.psm1', 'Modules\BridgeLiveScenes.psm1',
    'scripts\Install-BridgeTask.ps1', 'scripts\Uninstall-BridgeTask.ps1',
    'scripts\Install-BridgeService-NSSM.ps1', 'scripts\Uninstall-BridgeService-NSSM.ps1',
    'Run-Checks.ps1', 'Build-Release.ps1', 'scripts\Protect-BridgeSecrets.ps1', 'scripts\Test-BridgeReadiness.ps1', 'scripts\Test-ServiceLifecycle.ps1', 'Modules\BridgeInstall.psm1',
    'config.example.json', 'templates.example.json',
    'README.md', 'CHANGELOG.md', 'DEVELOPMENT-PLAN.md', 'RELEASE.md', 'docs\VERSION-6.md'
)
$forbiddenNames = @('config.json', 'secrets.dpapi.json', 'templates.json', 'onair.json', 'audit.jsonl', 'bridge.log', 'schedule.json', 'autohide.json', 'template-reminders.json')
$releaseRoot = Join-Path $OutputDirectory "CinegyTelegramBridge-$Version"
$zipPath = Join-Path $OutputDirectory "CinegyTelegramBridge-$Version.zip"
$checksumPath = "$zipPath.sha256"

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Test-Path -LiteralPath $releaseRoot) { Remove-Item -LiteralPath $releaseRoot -Recurse -Force }
New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

foreach ($relativePath in $allowList) {
    $source = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required release file missing: $relativePath" }
    $destination = Join-Path $releaseRoot $relativePath
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) { New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

$signed = $false
if (-not [string]::IsNullOrWhiteSpace($CodeSigningThumbprint)) {
    $certificate = Get-ChildItem -LiteralPath Cert:\CurrentUser\My | Where-Object Thumbprint -eq $CodeSigningThumbprint | Select-Object -First 1
    if (-not $certificate) { throw "Code-signing certificate '$CodeSigningThumbprint' was not found in Cert:\CurrentUser\My." }
    foreach ($file in @(Get-ChildItem -LiteralPath $releaseRoot -File -Recurse | Where-Object Extension -in @('.ps1', '.psm1'))) {
        $signature = Set-AuthenticodeSignature -LiteralPath $file.FullName -Certificate $certificate -HashAlgorithm SHA256
        if ($signature.Status -ne 'Valid') { throw "Signing failed for $($file.Name): $($signature.StatusMessage)" }
    }
    $signed = $true
}

$packagedFiles = @(Get-ChildItem -LiteralPath $releaseRoot -File -Recurse)
foreach ($file in $packagedFiles) {
    if ($forbiddenNames -contains $file.Name -or $file.Name -match '\.(bak|tmp|log|jsonl)$') {
        throw "Forbidden runtime or secret-bearing file entered the package: $($file.Name)"
    }
}
$manifestFiles = @($packagedFiles | Sort-Object FullName | ForEach-Object {
    $relativeName = [IO.Path]::GetRelativePath($releaseRoot, $_.FullName).Replace('\','/')
    [ordered]@{ Name = $relativeName; Length = $_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
$manifest = [ordered]@{
    Product = 'CinegyTelegramBridge'; Version = $Version
    BuiltAtUtc = [DateTime]::UtcNow.ToString('o'); AuthenticodeSigned = $signed
    Files = $manifestFiles
}
$manifestPath = Join-Path $releaseRoot 'release-manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $releaseRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
[IO.File]::WriteAllText($checksumPath, "$zipHash  $([IO.Path]::GetFileName($zipPath))`n", [Text.UTF8Encoding]::new($false))

[pscustomobject]@{ Version = $Version; ZipPath = $zipPath; ChecksumPath = $checksumPath; Signed = $signed }
