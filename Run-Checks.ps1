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
    [switch]$SkipTests
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
    'TelegramBridge.ps1', 'CinegyAirTitler.psm1',
    'Install-BridgeTask.ps1', 'Uninstall-BridgeTask.ps1',
    'Install-BridgeService-NSSM.ps1', 'Uninstall-BridgeService-NSSM.ps1',
    'config.example.json', 'templates.example.json',
    'Tests\Bridge.Tests.ps1', 'README.md', 'CHANGELOG.md'
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
    'TelegramBridge.ps1', 'CinegyAirTitler.psm1',
    'Install-BridgeTask.ps1', 'Uninstall-BridgeTask.ps1',
    'Install-BridgeService-NSSM.ps1', 'Uninstall-BridgeService-NSSM.ps1'
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
    # The bridge deliberately uses Write-Host for console output and a few
    # non-standard verbs kept for readability; those rules are excluded rather
    # than left to drown out real findings.
    $results = Invoke-ScriptAnalyzer -Path $root -Recurse -Severity Error, Warning `
        -ExcludeRule PSAvoidUsingWriteHost, PSUseShouldProcessForStateChangingFunctions, PSUseSingularNouns
    if ($results) {
        $errorCount = @($results | Where-Object { $_.Severity -eq 'Error' }).Count
        if ($errorCount -gt 0) { $failed = $true }
        $results | Sort-Object Severity, ScriptName, Line |
            Format-Table Severity, ScriptName, Line, RuleName, Message -AutoSize -Wrap | Out-String | Write-Host
        Write-Host "  $($results.Count) finding(s), $errorCount error(s)" -ForegroundColor $(if ($errorCount) { 'Red' } else { 'Yellow' })
    }
    else {
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
    $result = Invoke-Pester -Configuration $cfg
    if ($result.FailedCount -gt 0 -or $result.Errors.Count -gt 0) { $failed = $true }
}

Write-Section "Result"
if ($failed) {
    Write-Host "  FAILED - do not deploy this build." -ForegroundColor Red
    exit 1
}
Write-Host "  All checks passed." -ForegroundColor Green
Write-Host "  Static checks only - still run a smoke test in Telegram before going on air." -ForegroundColor DarkGray
exit 0
