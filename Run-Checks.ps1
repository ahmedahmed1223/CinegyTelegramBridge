#requires -Version 7
<#
    Run-Checks.ps1

    One command to statically analyse and unit-test the bridge. Run this after
    every change and before putting a new build on air:

        .\Run-Checks.ps1

    It does NOT contact Telegram or Cinegy Air and does not touch config.json,
    so it is safe to run on the playout machine while the bridge is live.

    Missing modules are reported with the exact install command rather than
    being installed silently.
#>

param(
    [switch]$SkipAnalyzer,
    [switch]$SkipTests,
    [string]$TestResultPath = ''
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$failed = $false

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor DarkGray
}

# ---------------------------------------------------------- files and JSON
Write-Section "1/4  Required files and JSON"
$files = @(
    'Parts\Bridge.Core.ps1', 'Parts\Bridge.Telegram.ps1', 'Parts\Bridge.News.ps1', 'Parts\Bridge.Mojaz.ps1', 'Parts\Bridge.Mojaz.Design.ps1', 'Parts\Bridge.Mojaz.Screens.ps1', 'Parts\Bridge.Mojaz.Playback.ps1', 'Parts\Bridge.Urgent.ps1', 'Parts\Bridge.Urgent.Playback.ps1', 'Parts\Bridge.Users.ps1', 'Parts\Bridge.Templates.ps1', 'Parts\Bridge.OnAir.ps1', 'Parts\Bridge.Schedule.ps1', 'Parts\Bridge.Keyboards.ps1', 'Parts\Bridge.ShowFlow.ps1', 'Parts\Bridge.WhatsNew.ps1', 'Parts\Bridge.Help.ps1', 'Parts\Bridge.AirOperation.ps1', 'Parts\Bridge.Admin.ps1', 'Parts\Bridge.Admin.Templates.ps1', 'Parts\Bridge.Admin.Health.ps1', 'Parts\Bridge.Admin.Config.ps1', 'Parts\Bridge.Admin.Diagnostics.ps1', 'Parts\Bridge.Media.ps1', 'Parts\Bridge.Commands.ps1', 'Parts\Bridge.Callbacks.ps1', 'Parts\Bridge.Tick.ps1', 'Parts\Bridge.Reports.ps1', 'Parts\Bridge.Announcements.ps1',
    'TelegramBridge.ps1', 'Modules\CinegyAirTitler.psm1', 'Modules\BridgeSecurity.psm1', 'Modules\BridgeSettings.psm1', 'Modules\BridgeStorage.psm1', 'Modules\BridgeTelegram.psm1', 'Modules\BridgeAuthorization.psm1', 'Modules\BridgeFlowState.psm1', 'Modules\BridgeCinegyState.psm1', 'Modules\BridgeSchedulePolicy.psm1', 'Modules\BridgeMedia.psm1', 'Modules\BridgeRelayPolicy.psm1', 'Modules\BridgeRuntimeState.psm1', 'Modules\BridgeNewsTicker.psm1', 'Modules\BridgeMojaz.psm1', 'Modules\BridgeUrgent.psm1', 'Modules\BridgeOperationPolicy.psm1', 'Modules\BridgeOperationLifecycle.psm1', 'Modules\BridgeSettingsSchema.psm1', 'Modules\BridgeUiPaging.psm1', 'Modules\BridgeLiveScenes.psm1',
    'scripts\Install-BridgeTask.ps1', 'scripts\Uninstall-BridgeTask.ps1',
    'scripts\Install-BridgeService-NSSM.ps1', 'scripts\Uninstall-BridgeService-NSSM.ps1',
    'config.example.json', 'templates.example.json',
    'Tests\Bridge.Tests.ps1', 'Tests\Bridge.TestContext.ps1', 'Tests\Bridge.Templates.Tests.ps1', 'Tests\Bridge.Users.Tests.ps1', 'Tests\Bridge.SettingsScreens.Tests.ps1', 'Tests\Bridge.OnAir.Tests.ps1', 'Tests\Bridge.Cinegy.Tests.ps1', 'Tests\Bridge.NewsScreens.Tests.ps1', 'Tests\Bridge.Admin.Tests.ps1', 'Tests\Bridge.Schedule.Tests.ps1', 'Tests\Bridge.RuntimeHealth.Tests.ps1', 'Tests\Bridge.NewsSheet.Tests.ps1', 'Tests\Bridge.Help.Tests.ps1', 'Tests\Bridge.Access.Tests.ps1', 'Tests\BridgeNewsTicker.Tests.ps1', 'Tests\BridgeMojaz.Tests.ps1', 'Tests\BridgeUrgent.Tests.ps1', 'Tests\Bridge.Urgent.Tests.ps1', 'Tests\Bridge.UrgentRecovery.Tests.ps1', 'Tests\Bridge.TemplateMaxAir.Tests.ps1', 'Tests\Bridge.AutoHideExtension.Tests.ps1', 'Tests\Bridge.TemplateAirPolicy.Tests.ps1', 'Tests\BridgeSettings.Tests.ps1', 'Tests\BridgeStorage.Tests.ps1', 'Tests\BridgeTelegram.Tests.ps1', 'Tests\BridgeAuthorization.Tests.ps1', 'Tests\BridgeFlowState.Tests.ps1', 'Tests\BridgeCinegyState.Tests.ps1', 'Tests\BridgeSchedulePolicy.Tests.ps1', 'Tests\BridgeMedia.Tests.ps1', 'Tests\BridgeRelayPolicy.Tests.ps1', 'Tests\BridgeRuntimeState.Tests.ps1', 'Tests\BridgeOperationPolicy.Tests.ps1', 'Tests\BridgeOperationLifecycle.Tests.ps1', 'Tests\BridgeSettingsSchema.Tests.ps1', 'Tests\BridgeUiPaging.Tests.ps1', 'Tests\BridgeReports.Tests.ps1', 'Tests\BridgeLiveScenes.Tests.ps1', 'Tests\BridgeVersion6Load.Tests.ps1', 'Tests\Smoke-OnAir.Tests.ps1', 'Tests\Release.Tests.ps1', 'Tests\Security.Tests.ps1', 'Tests\BridgeInstall.Tests.ps1',
    'README.md', 'CHANGELOG.md', 'DEVELOPMENT-PLAN.md', 'docs\VERSION-6.md', 'docs\news-sheet-writeback.gs',
    'Build-Release.ps1', 'scripts\Protect-BridgeSecrets.ps1', 'scripts\Test-BridgeReadiness.ps1', 'scripts\Test-ServiceLifecycle.ps1', 'Modules\BridgeInstall.psm1', 'RELEASE.md', '.github\workflows\windows-ci.yml'
)
foreach ($file in $files) {
    $path = Join-Path $root $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failed = $true
        Write-Host "  FAIL  missing $file" -ForegroundColor Red
    }
    else { Write-Host "  ok    $file" -ForegroundColor Green }
}

$jsonFiles = @('config.example.json', 'templates.example.json')
foreach ($optional in @('config.json', 'templates.json')) {
    if (Test-Path -LiteralPath (Join-Path $root $optional) -PathType Leaf) { $jsonFiles += $optional }
}
foreach ($file in $jsonFiles) {
    $path = Join-Path $root $file
    try {
        Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null
        Write-Host "  json  $file" -ForegroundColor Green
    }
    catch {
        $failed = $true
        Write-Host "  FAIL  invalid JSON in $file`: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------------------------------------------------------------- parse check
Write-Section "2/4  Syntax (PowerShell parser)"
$powerShellFiles = @(
    'TelegramBridge.ps1', 'Modules\CinegyAirTitler.psm1', 'Modules\BridgeSecurity.psm1', 'Modules\BridgeSettings.psm1', 'Modules\BridgeStorage.psm1', 'Modules\BridgeTelegram.psm1', 'Modules\BridgeAuthorization.psm1', 'Modules\BridgeFlowState.psm1', 'Modules\BridgeCinegyState.psm1', 'Modules\BridgeSchedulePolicy.psm1', 'Modules\BridgeMedia.psm1', 'Modules\BridgeRelayPolicy.psm1', 'Modules\BridgeRuntimeState.psm1', 'Modules\BridgeNewsTicker.psm1', 'Modules\BridgeMojaz.psm1', 'Modules\BridgeUrgent.psm1', 'Modules\BridgeOperationPolicy.psm1', 'Modules\BridgeOperationLifecycle.psm1', 'Modules\BridgeSettingsSchema.psm1', 'Modules\BridgeUiPaging.psm1', 'Modules\BridgeLiveScenes.psm1',
    'scripts\Install-BridgeTask.ps1', 'scripts\Uninstall-BridgeTask.ps1',
    'scripts\Install-BridgeService-NSSM.ps1', 'scripts\Uninstall-BridgeService-NSSM.ps1',
    'Build-Release.ps1', 'scripts\Protect-BridgeSecrets.ps1', 'scripts\Test-BridgeReadiness.ps1', 'scripts\Test-ServiceLifecycle.ps1', 'Modules\BridgeInstall.psm1', 'Run-Checks.ps1'
)
foreach ($file in $powerShellFiles) {
    $path = Join-Path $root $file
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $failed = $true
        Write-Host "  FAIL  $file" -ForegroundColor Red
        foreach ($e in $errors) { Write-Host "        line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red }
    }
    else {
        Write-Host "  ok    $file" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------- analyzer
Write-Section "3/4  PSScriptAnalyzer"
if ($SkipAnalyzer) {
    Write-Host "  skipped (-SkipAnalyzer)" -ForegroundColor Yellow
}
elseif (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    $failed = $true
    Write-Host "  PSScriptAnalyzer is not installed. To enable this check:" -ForegroundColor Yellow
    Write-Host "      Install-Module PSScriptAnalyzer -Scope CurrentUser" -ForegroundColor Yellow
}
else {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    # PowerShell 7 reads UTF-8 without BOM correctly. Exclude those intentional
    # style choices so every reported warning is actionable.
    #
    # PSUseApprovedVerbs used to be excluded here for "one private XML helper".
    # It was covering three more that had drifted in unnoticed, and later let
    # Queue-BridgeOperation through until somebody caught it by hand. All four
    # were renamed and the rule is enforced again.
    # Scan source and test files explicitly. dist/, artifacts/, logs/, and the
    # *.backups runtime folders can contain old builds, generated data, or
    # ACL-protected secrets; recursively scanning the repository root lets
    # those files hide the real analyzer result behind an access error.
    $analyzerPaths = @(
        @($powerShellFiles | ForEach-Object { Join-Path $root $_ })
        @(Get-ChildItem -LiteralPath (Join-Path $root 'Parts') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
        @(Get-ChildItem -LiteralPath (Join-Path $root 'Tests') -Filter '*.ps1' -File | Select-Object -ExpandProperty FullName)
    )
    $analyzerErrors = @()
    $results = @()
    foreach ($analyzerPath in $analyzerPaths) {
        $results += @(Invoke-ScriptAnalyzer -Path $analyzerPath -Severity Error, Warning -ErrorVariable +analyzerErrors `
                -ExcludeRule PSAvoidUsingWriteHost, PSUseShouldProcessForStateChangingFunctions, PSUseSingularNouns, PSUseBOMForUnicodeEncodedFile)
    }
    if ($analyzerErrors.Count -gt 0) {
        $failed = $true
        Write-Host "  FAIL  PSScriptAnalyzer could not complete:" -ForegroundColor Red
        foreach ($errorRecord in $analyzerErrors) { Write-Host "        $($errorRecord.Exception.Message)" -ForegroundColor Red }
    }
    if ($results) {
        # Warnings fail the gate too. The five rules above are excluded as
        # deliberate style, so anything still reported here is actionable -
        # letting warnings pass is what buried a real automatic-variable bind
        # among hundreds of cosmetic ones.
        $failed = $true
        $errorCount = @($results | Where-Object { $_.Severity -eq 'Error' }).Count
        $results | Sort-Object Severity, ScriptName, Line |
            Format-Table Severity, ScriptName, Line, RuleName, Message -AutoSize -Wrap | Out-String | Write-Host
        Write-Host "  $($results.Count) finding(s), $errorCount error(s)" -ForegroundColor Red
    }
    elseif ($analyzerErrors.Count -eq 0) {
        Write-Host "  ok    no findings" -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------- tests
Write-Section "4/4  Pester tests"
if ($SkipTests) {
    Write-Host "  skipped (-SkipTests)" -ForegroundColor Yellow
}
elseif (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 })) {
    $failed = $true
    Write-Host "  Pester 5+ is not installed. To enable these tests:" -ForegroundColor Yellow
    Write-Host "      Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force" -ForegroundColor Yellow
}
else {
    Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = Join-Path $root 'Tests'
    $cfg.Output.Verbosity = 'Detailed'
    $cfg.Run.PassThru = $true
    # The bridge tests do not use Pester's registry drive. Keeping it off makes
    # the validation command work for locked-down service identities as well
    # as for an interactive administrator account.
    $cfg.TestRegistry.Enabled = $false
    if (-not [string]::IsNullOrWhiteSpace($TestResultPath)) {
        $resultDirectory = Split-Path $TestResultPath -Parent
        if ($resultDirectory -and -not (Test-Path -LiteralPath $resultDirectory)) { New-Item -ItemType Directory -Path $resultDirectory -Force | Out-Null }
        $cfg.TestResult.Enabled = $true
        $cfg.TestResult.OutputPath = $TestResultPath
        $cfg.TestResult.OutputFormat = 'NUnitXml'
    }
    $result = Invoke-Pester -Configuration $cfg
    if ($result.FailedCount -gt 0 -or $result.Errors.Count -gt 0) { $failed = $true }
}

Write-Section "Result"
if ($failed) {
    Write-Host "  FAILED - do not deploy this build." -ForegroundColor Red
    exit 1
}
Write-Host "  All checks passed." -ForegroundColor Green
Write-Host "  Static checks only - use a dedicated non-production layer for live smoke testing." -ForegroundColor DarkGray
Write-Host "  Do not send test SHOW/HIDE/EXIT commands in a working environment without an approved change window." -ForegroundColor DarkGray
exit 0
