#requires -RunAsAdministrator
<#
    Install-BridgeService-NSSM.ps1

    Alternative to Install-BridgeTask.ps1: registers TelegramBridge.ps1 as a
    real Windows Service (visible in services.msc) using NSSM
    (the Non-Sucking Service Manager, https://nssm.cc/). Unlike a Scheduled
    Task, NSSM gives you: a proper service entry you can start/stop/restart
    from services.msc or `Get-Service`, automatic stdout/stderr capture to
    files with log rotation, and fine-grained restart-on-crash behavior.

    NSSM is a small third-party .exe, not part of Windows, so it has to be
    present on this machine first. This script will try to find it (PATH,
    common install locations, next to this script); if it can't, it prints
    exactly how to get it and stops - it will not silently download a
    binary from the internet.

    Run this ONCE, as Administrator, on the machine that will host the
    bridge (usually the Air Pro playout box itself):

        cd 'D:\cingy cg\CinegyTelegramBridge'
        .\scripts\Install-BridgeService-NSSM.ps1

    To remove it later, run .\scripts\Uninstall-BridgeService-NSSM.ps1 (also as Admin).
#>

param(
    [string]$ServiceName = "CinegyTelegramBridge",
    [string]$NssmPath
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent (Split-Path -Path $MyInvocation.MyCommand.Path -Parent)

function Find-Nssm {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }

    $local = Join-Path $scriptRoot "nssm.exe"
    if (Test-Path $local) { return $local }

    $onPath = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    foreach ($candidate in @(
            "$env:ProgramData\chocolatey\bin\nssm.exe",
            "C:\nssm\nssm.exe",
            "C:\nssm\win64\nssm.exe"
        )) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

$nssmPath = Find-Nssm -Explicit $NssmPath
if (-not $nssmPath) {
    Write-Host "nssm.exe was not found on this machine." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Get it one of these ways, then re-run this script:" -ForegroundColor Yellow
    Write-Host "  1) winget install -e --id NSSM.NSSM"
    Write-Host "  2) choco install nssm -y   (if Chocolatey is installed)"
    Write-Host "  3) Manually: download from https://nssm.cc/download, unzip, and copy"
    Write-Host "     win64\nssm.exe (or win32 on a 32-bit OS) into:"
    Write-Host "     $scriptRoot\nssm.exe"
    Write-Host ""
    Write-Host "(If you'd rather avoid a third-party tool entirely, use Install-BridgeTask.ps1" -ForegroundColor Cyan
    Write-Host " instead - it does the same job with the built-in Windows Task Scheduler.)" -ForegroundColor Cyan
    exit 1
}
Write-Host "Using nssm.exe at: $nssmPath" -ForegroundColor Cyan

$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
if (-not (Test-Path $pwshPath)) {
    throw "Could not find pwsh.exe (PowerShell 7). Install it from https://aka.ms/powershell-release, then re-run this script."
}

$bridgeScript = Join-Path $scriptRoot "TelegramBridge.ps1"
$configPath = Join-Path $scriptRoot "config.json"
if (-not (Test-Path $bridgeScript)) { throw "TelegramBridge.ps1 not found in $scriptRoot." }
if (-not (Test-Path $configPath)) { throw "config.json not found in $scriptRoot. Copy config.example.json to config.json and edit it first." }

$logDir = Join-Path $scriptRoot "logs"
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
$stdoutLog = Join-Path $logDir "service-stdout.log"
$stderrLog = Join-Path $logDir "service-stderr.log"

$appArgs = "-NoProfile -WindowStyle Hidden -File `"$bridgeScript`" -ConfigPath `"$configPath`""

$existing = & $nssmPath status $ServiceName 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
    Write-Host "Service '$ServiceName' already exists (status: $existing). Removing it first so settings are re-applied cleanly." -ForegroundColor Yellow
    & $nssmPath stop $ServiceName confirm 2>$null | Out-Null
    & $nssmPath remove $ServiceName confirm | Out-Null
}

& $nssmPath install $ServiceName $pwshPath | Out-Null
& $nssmPath set $ServiceName AppParameters $appArgs | Out-Null
& $nssmPath set $ServiceName AppDirectory $scriptRoot | Out-Null
& $nssmPath set $ServiceName DisplayName "Cinegy Air Pro Telegram Bridge" | Out-Null
& $nssmPath set $ServiceName Description "Telegram bot bridge for Cinegy Air Pro Titler graphics (see $scriptRoot)" | Out-Null
& $nssmPath set $ServiceName Start SERVICE_AUTO_START | Out-Null
& $nssmPath set $ServiceName AppStdout $stdoutLog | Out-Null
& $nssmPath set $ServiceName AppStderr $stderrLog | Out-Null
& $nssmPath set $ServiceName AppRotateFiles 1 | Out-Null
& $nssmPath set $ServiceName AppRotateOnline 1 | Out-Null
& $nssmPath set $ServiceName AppRotateBytes 10485760 | Out-Null
& $nssmPath set $ServiceName AppExit Default Restart | Out-Null
& $nssmPath set $ServiceName AppRestartDelay 5000 | Out-Null

Write-Host "Service '$ServiceName' installed via NSSM." -ForegroundColor Green
Write-Host "Start now:   Start-Service '$ServiceName'   (or: nssm start $ServiceName)" -ForegroundColor Cyan
Write-Host "Stop:        Stop-Service  '$ServiceName'" -ForegroundColor Cyan
Write-Host "Status:      Get-Service   '$ServiceName'   (or open services.msc)" -ForegroundColor Cyan
Write-Host "App logs:    $scriptRoot\logs\bridge.log" -ForegroundColor Cyan
Write-Host "Service I/O: $stdoutLog / $stderrLog" -ForegroundColor Cyan

$answer = Read-Host "Start it now? (Y/N)"
if ($answer -match '^[Yy]') {
    Start-Service $ServiceName
    Start-Sleep -Seconds 2
    Get-Service $ServiceName | Format-Table -AutoSize
}
