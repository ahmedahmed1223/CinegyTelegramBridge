#requires -Version 7
<#
    Test-BridgeReadiness.ps1

    Checks that a bridge installation will actually run, before a service or
    scheduled task is registered around it. Both installers call this first;
    it is also useful on its own at any time:

        .\scripts\Test-BridgeReadiness.ps1

    Read-only: it inspects config.json, the template registry and the machine.
    It never edits anything and never contacts Telegram or Cinegy.

    Exit code 0 means ready (warnings may still be printed), 1 means the
    install would produce a service that cannot run.
#>

param(
    # The account the service will run under. Both installers default to
    # SYSTEM; pass the real one if you change it.
    [string]$RunAsAccount = 'SYSTEM',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Modules\BridgeInstall.psm1') -Force

# ---- gather facts (all the I/O lives here; the verdict itself is pure) ----
$configPath = Join-Path $root 'config.json'
$config = $null
if (Test-Path -LiteralPath $configPath) {
    try { $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { $config = $null }
}

$hasPwsh = [bool](Get-Command pwsh.exe -ErrorAction SilentlyContinue) -or
    (Test-Path -LiteralPath "$env:ProgramFiles\PowerShell\7\pwsh.exe")

$hasFfmpeg = [bool](Get-Command ffmpeg.exe -ErrorAction SilentlyContinue) -or
    (Test-Path -LiteralPath (Join-Path $root 'ffmpeg.exe'))

# The registry path is stored relative to the bridge root when set that way.
$templatesReadable = $false
$templatesError = ''
$registryPath = if ($config) { [string](Get-BridgeInstallProperty -Object $config -Name 'TemplateRegistryPath') } else { '' }
if ([string]::IsNullOrWhiteSpace($registryPath)) { $registryPath = 'templates.json' }
if (-not [IO.Path]::IsPathRooted($registryPath)) { $registryPath = Join-Path $root $registryPath }
if (-not (Test-Path -LiteralPath $registryPath)) { $templatesError = "not found at $registryPath" }
else {
    try {
        Get-Content -LiteralPath $registryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null
        $templatesReadable = $true
    }
    catch { $templatesError = 'invalid JSON' }
}

# Who protected the DPAPI store, if it is in use. The store is opaque - what
# matters is the identity able to open it, which is whoever ran
# Protect-BridgeSecrets.ps1.
$protectedBy = ''
$secretStore = Join-Path $root 'secrets.dpapi.json'
if (Test-Path -LiteralPath $secretStore) {
    try {
        $store = Get-Content -LiteralPath $secretStore -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $protectedBy = [string](Get-BridgeInstallProperty -Object $store -Name 'ProtectedBy')
    }
    catch { $protectedBy = '' }
    if ([string]::IsNullOrWhiteSpace($protectedBy)) { $protectedBy = '(unrecorded)' }
}

$report = Get-BridgeReadinessReport -Config $config -RunAsAccount $RunAsAccount -ProtectedBy $protectedBy `
    -HasPowerShell7:$hasPwsh -HasFfmpeg:$hasFfmpeg -TemplatesReadable:$templatesReadable -TemplatesError $templatesError

if (-not $Quiet) {
    Write-Host ''
    Write-Host '  Bridge readiness' -ForegroundColor Cyan
    Write-Host '  ----------------' -ForegroundColor DarkGray
    Write-Host "  will run as        : $RunAsAccount"
    Write-Host "  PowerShell 7       : $(if ($hasPwsh) { 'found' } else { 'MISSING' })"
    Write-Host "  config.json        : $(if ($config) { 'valid' } else { 'MISSING or invalid' })"
    Write-Host "  template registry  : $(if ($templatesReadable) { 'valid' } else { "unreadable - $templatesError" })"
    Write-Host "  ffmpeg             : $(if ($hasFfmpeg) { 'found' } else { 'not found' })"
    if ($protectedBy) { Write-Host "  DPAPI secrets      : protected for $protectedBy" }
    Write-Host ''
    foreach ($problem in $report.Errors) { Write-Host "  FAIL  $problem" -ForegroundColor Red }
    foreach ($note in $report.Warnings) { Write-Host "  WARN  $note" -ForegroundColor Yellow }
    if ($report.Ok -and $report.Warnings.Count -eq 0) { Write-Host '  ok    ready to install' -ForegroundColor Green }
    elseif ($report.Ok) { Write-Host '  ok    ready to install, with the warnings above' -ForegroundColor Green }
    Write-Host ''
}

if (-not $report.Ok) { exit 1 }
exit 0
