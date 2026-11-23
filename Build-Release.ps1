#requires -Version 7
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist'),
    [string]$CodeSigningThumbprint = '',
    [string]$WebBundleDirectory = '',
    [string]$ManagerBundleDirectory = '',
    [semver]$MinimumWebBridgeVersion,
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
if ($WebBundleDirectory) {
    $MinimumWebBridgeVersion ??= [semver]$Version
    if ($MinimumWebBridgeVersion -gt [semver]$Version) { throw 'The minimum bridge version for the web cannot exceed the release version.' }
}

if (-not $SkipChecks) {
    & (Join-Path $root 'Run-Checks.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Release checks failed.' }
}

$allowList = @(
    # Every part TelegramBridge.ps1 dot-sources, and every module it imports.
    # A part missing from here is not a smaller package: the bridge names each
    # one and throws on the first that is absent, so the extracted release does
    # not start at all. Thirteen of them had drifted out of this list as files
    # were split, and nothing noticed because the package was only ever checked
    # for what must NOT be in it. Tests\Release.Tests.ps1 now checks the other
    # direction against the built zip.
    'Parts\Bridge.Core.ps1', 'Parts\Bridge.Telegram.ps1', 'Parts\Bridge.News.ps1', 'Parts\Bridge.Users.ps1', 'Parts\Bridge.Templates.ps1', 'Parts\Bridge.OnAir.ps1', 'Parts\Bridge.Schedule.ps1', 'Parts\Bridge.Keyboards.ps1', 'Parts\Bridge.ShowFlow.ps1', 'Parts\Bridge.Admin.ps1', 'Parts\Bridge.Media.ps1', 'Parts\Bridge.Commands.ps1', 'Parts\Bridge.Callbacks.ps1', 'Parts\Bridge.Tick.ps1', 'Parts\Bridge.Reports.ps1', 'Parts\Bridge.Weekly.ps1', 'Parts\Bridge.Announcements.ps1',
    'Parts\Bridge.Mojaz.ps1', 'Parts\Bridge.Mojaz.Design.ps1', 'Parts\Bridge.Mojaz.Screens.ps1', 'Parts\Bridge.Mojaz.Playback.ps1',
    'Parts\Bridge.Urgent.ps1', 'Parts\Bridge.Urgent.Playback.ps1', 'Parts\Bridge.Boards.ps1',
    'Parts\Bridge.WhatsNew.ps1', 'Parts\Bridge.Help.ps1', 'Parts\Bridge.Help.En.ps1', 'Parts\Bridge.AirOperation.ps1',
    'Parts\Bridge.Admin.Templates.ps1', 'Parts\Bridge.Admin.Health.ps1', 'Parts\Bridge.Admin.Config.ps1', 'Parts\Bridge.Admin.Diagnostics.ps1', 'Parts\Bridge.AirStatusWidget.ps1', 'Parts\Bridge.WebChannel.ps1',
    'Parts\Bridge.WebSchedule.ps1', 'Parts\Bridge.WebRerun.ps1', 'Parts\Bridge.WebTelegramAccess.ps1',
    'Parts\Bridge.Schedule.Mutations.ps1', 'Parts\Bridge.WebSchedule.Materials.ps1', 'Parts\Bridge.WebAdminOverview.ps1', 'Parts\Bridge.WebManagedRestart.ps1', 'Parts\Bridge.WebAdminSettings.ps1', 'Parts\Bridge.WebAdminSettingsRecovery.ps1', 'Parts\Bridge.WebRollback.ps1', 'Parts\Bridge.WebAirText.ps1', 'Parts\Bridge.WebShiftHistory.ps1', 'Parts\Bridge.WebOperationReference.ps1',
    'Parts\Bridge.WebShiftNotices.ps1', 'Parts\Bridge.WebOperatorHelp.ps1', 'Parts\Bridge.WebOperationMetrics.ps1', 'Parts\Bridge.WebHideAllLayerScope.ps1', 'Parts\Bridge.HideAllLayerScope.ps1', 'Parts\Bridge.WebRelayDestination.ps1', 'Parts\Bridge.WebPersonalAirReminders.ps1', 'Parts\Bridge.TemplateReminderActions.ps1', 'Parts\Bridge.WebTelegramRoster.ps1', 'Parts\Bridge.WebTelegramUnblock.ps1', 'Parts\Bridge.WebAccessHistory.ps1', 'Parts\Bridge.WebTelegramSuspension.ps1', 'Parts\Bridge.WebTelegramAlias.ps1', 'Parts\Bridge.WebTelegramOperatorActivity.ps1', 'Parts\Bridge.WebTelegramDeliveryQuarantine.ps1', 'Parts\Bridge.UserWorkingNames.ps1', 'Parts\Bridge.WebAnnouncements.ps1',
    'Parts\Bridge.WebRuntimeFileDiagnostics.ps1', 'Parts\Bridge.WebDiagnosticBundle.ps1', 'Parts\Bridge.WebScheduleExecution.ps1', 'Parts\Bridge.WebSceneReplacement.ps1', 'Parts\Bridge.WebWorkSummary.ps1', 'Parts\Bridge.WebBulletinReport.ps1', 'Parts\Bridge.WebTickerReport.ps1', 'Parts\Bridge.WebTemplateReport.ps1', 'Parts\Bridge.WebHandoverReports.ps1', 'Parts\Bridge.ShiftHandoverAcknowledgement.ps1',
    'Parts\Bridge.Mojaz.Management.ps1', 'Parts\Bridge.WebBulletinManagement.ps1', 'Parts\Bridge.WebBulletinAfterUrgent.ps1', 'Parts\Bridge.WebBulletinSceneImages.ps1', 'Parts\Bridge.WebAirEmergency.ps1', 'Parts\Bridge.WebAirTimer.ps1', 'Parts\Bridge.WebLayerRemoval.ps1', 'Parts\Bridge.WebTemplateBackups.ps1', 'Parts\Bridge.WebTemplateRegistryTransfer.ps1', 'Parts\Bridge.LayerNames.ps1', 'Parts\Bridge.WebLayerNames.ps1', 'Parts\Bridge.WebTemplateFavorites.ps1', 'Parts\Bridge.WebTemplateMaxAir.ps1', 'Parts\Bridge.TemplateMaxAir.ps1', 'Parts\Bridge.WebTemplateRegistryExport.ps1', 'Parts\Bridge.WebTemplateRegistryImport.ps1', 'Parts\Bridge.WebTemplateIssues.ps1',
    'TelegramBridge.ps1', 'Modules\CinegyAirTitler.psm1', 'Modules\BridgeSecurity.psm1', 'Modules\BridgeSettings.psm1', 'Modules\BridgeStorage.psm1', 'Modules\BridgeTelegram.psm1', 'Modules\BridgeAuthorization.psm1', 'Modules\BridgeFlowState.psm1', 'Modules\BridgeCinegyState.psm1', 'Modules\BridgeSchedulePolicy.psm1', 'Modules\BridgeMedia.psm1', 'Modules\BridgeRelayPolicy.psm1', 'Modules\BridgeRuntimeState.psm1', 'Modules\BridgeNewsTicker.psm1', 'Modules\BridgeMojaz.psm1', 'Modules\BridgeUrgent.psm1', 'Modules\BridgeOperationPolicy.psm1', 'Modules\BridgeOperationLifecycle.psm1', 'Modules\BridgeSettingsSchema.psm1', 'Modules\BridgeUiPaging.psm1', 'Modules\BridgeLiveScenes.psm1', 'Modules\BridgeContentBoards.psm1', 'Modules\BridgeAirText.psm1', 'Modules\BridgeLanguage.psm1', 'Modules\BridgeStreamOutages.psm1', 'Modules\BridgeText\Common.ps1', 'Modules\BridgeText\Settings.ps1', 'Modules\BridgeText\Screens.ps1', 'Modules\BridgeText\Content.ps1', 'Modules\BridgeText\Alerts.ps1', 'Modules\BridgeText\Replies.ps1', 'Modules\BridgeText\Reports.ps1', 'Modules\BridgeText\Flow.ps1', 'Modules\BridgeText\Admin.ps1', 'Modules\BridgeText\Air.ps1', 'Modules\BridgeText\Keyboards.ps1', 'Modules\BridgeText\AdminTools.ps1', 'Modules\BridgeText\Screens2.ps1', 'Modules\BridgeText\Interp1.ps1', 'Modules\BridgeText\Interp2.ps1', 'Modules\BridgeText\Interp3.ps1', 'Modules\BridgeText\Interp4.ps1', 'Modules\BridgeText\Interp5.ps1', 'Modules\BridgeText\Interp6.ps1', 'Modules\BridgeText\Interp7.ps1', 'Modules\BridgeText\Interp8.ps1', 'Modules\BridgeText\Interp9.ps1', 'Modules\BridgeText\Core.ps1', 'Modules\BridgeText\Help.ps1', 'Modules\BridgeText\WhatsNew.ps1', 'Modules\BridgeText\Feed.ps1', 'Modules\BridgeText\Web.ps1',
    'scripts\Install-BridgeTask.ps1', 'scripts\Uninstall-BridgeTask.ps1',
    'scripts\Install-BridgeService-NSSM.ps1', 'scripts\Uninstall-BridgeService-NSSM.ps1',
    'Run-Checks.ps1', 'Build-Release.ps1', 'scripts\Protect-BridgeSecrets.ps1', 'scripts\Test-BridgeReadiness.ps1', 'scripts\Test-ServiceLifecycle.ps1', 'scripts\Update-BridgeWeb.ps1', 'Modules\BridgeInstall.psm1',
    'config.example.json', 'templates.example.json',
    'README.md', 'CHANGELOG.md', 'DEVELOPMENT-PLAN.md', 'RELEASE.md', 'docs\VERSION-6.md'
)
$forbiddenNames = @('config.json', 'secrets.dpapi.json', 'templates.json', 'onair.json', 'audit.jsonl', 'bridge.log', 'schedule.json', 'autohide.json', 'template-reminders.json')
$distributables = [ordered]@{}
foreach ($relativePath in $allowList) { $distributables[$relativePath] = Join-Path $root $relativePath }
if ($ManagerBundleDirectory) {
    $distributables['dist/BridgeManager/BridgeManager.exe'] = Join-Path $ManagerBundleDirectory 'BridgeManager.exe'
}
if ($WebBundleDirectory) {
    foreach ($expected in @('CinegyBridge.Web.exe', 'wwwroot/index.html')) {
        $distributables["dist/web/$expected"] = Join-Path $WebBundleDirectory $expected
    }
    foreach ($optional in 'favicon.svg', 'favicon.svg.br', 'favicon.svg.gz', 'index.html.br', 'index.html.gz') {
        $static = Join-Path $WebBundleDirectory "wwwroot/$optional"
        if (Test-Path -LiteralPath $static -PathType Leaf) { $distributables["dist/web/wwwroot/$optional"] = $static }
    }
    # Copy the built client files explicitly. Publish folders may also contain
    # logs, appsettings overrides, or state from a previous run.
    $assetExtensions = @('.css', '.js', '.mjs', '.woff', '.woff2', '.svg', '.webp', '.png', '.jpeg', '.jpg', '.ico', '.wasm')
    $assets = @(Get-ChildItem -LiteralPath (Join-Path $WebBundleDirectory 'wwwroot/assets') -File | Where-Object {
            $extension = if ($_.Extension -in '.br', '.gz') { [IO.Path]::GetExtension($_.BaseName) } else { $_.Extension }
            $extension -in $assetExtensions -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        })
    if (-not ($assets.Extension -contains '.js')) { throw 'The supplied web build has no client JavaScript assets.' }
    foreach ($asset in $assets) { $distributables["dist/web/wwwroot/assets/$($asset.Name)"] = $asset.FullName }
}
foreach ($relativePath in $distributables.Keys) {
    if (-not (Test-Path -LiteralPath $distributables[$relativePath] -PathType Leaf)) { throw "Required release file missing: $relativePath" }
}
$releaseRoot = Join-Path $OutputDirectory "CinegyTelegramBridge-$Version"
$zipPath = Join-Path $OutputDirectory "CinegyTelegramBridge-$Version.zip"
$checksumPath = "$zipPath.sha256"

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
if (Test-Path -LiteralPath $releaseRoot) { Remove-Item -LiteralPath $releaseRoot -Recurse -Force }
New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

foreach ($relativePath in $distributables.Keys) {
    $source = $distributables[$relativePath]
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
if ($WebBundleDirectory) { $manifest.MinimumWebBridgeVersion = [string]$MinimumWebBridgeVersion }
$manifestPath = Join-Path $releaseRoot 'release-manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $releaseRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
[IO.File]::WriteAllText($checksumPath, "$zipHash  $([IO.Path]::GetFileName($zipPath))`n", [Text.UTF8Encoding]::new($false))

[pscustomobject]@{ Version = $Version; ZipPath = $zipPath; ChecksumPath = $checksumPath; Signed = $signed }
