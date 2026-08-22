#requires -RunAsAdministrator
<#
    Install-BridgeTask.ps1

    Registers TelegramBridge.ps1 as a Windows Scheduled Task so it behaves
    like a background service: starts automatically at boot, runs as
    SYSTEM (no one needs to be logged in), and restarts itself
    automatically if it ever crashes or the box reboots.

    This uses only built-in Task Scheduler - no third-party tool (e.g.
    NSSM) required.

    Run this ONCE, as Administrator, on the machine that will host the
    bridge (usually the Air Pro playout box itself):

        cd 'D:\cingy cg\CinegyTelegramBridge'
        .\scripts\Install-BridgeTask.ps1

    To remove it later, run .\scripts\Uninstall-BridgeTask.ps1 (also as Admin).
#>

param(
    [string]$TaskName = "CinegyTelegramBridge"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent (Split-Path -Path $MyInvocation.MyCommand.Path -Parent)

$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
$pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
if (-not (Test-Path $pwshPath)) {
    throw "Could not find pwsh.exe (PowerShell 7). Install it from https://aka.ms/powershell-release, then re-run this script."
}

$bridgeScript = Join-Path $scriptRoot "TelegramBridge.ps1"
$configPath = Join-Path $scriptRoot "config.json"
if (-not (Test-Path $bridgeScript)) { throw "TelegramBridge.ps1 not found in $scriptRoot." }
if (-not (Test-Path $configPath)) { throw "config.json not found in $scriptRoot. Copy config.example.json to config.json and edit it first." }

$action = New-ScheduledTaskAction -Execute $pwshPath `
    -Argument "-NoProfile -WindowStyle Hidden -File `"$bridgeScript`" -ConfigPath `"$configPath`"" `
    -WorkingDirectory $scriptRoot

$trigger = New-ScheduledTaskTrigger -AtStartup

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Cinegy Air Pro Telegram Bridge - auto-start at boot, auto-restart on crash" -Force | Out-Null

Write-Host "Scheduled Task '$TaskName' installed. It will start automatically at next boot." -ForegroundColor Green
Write-Host "Start now:   Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
Write-Host "Status:      Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo" -ForegroundColor Cyan
Write-Host "Stop:        Stop-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
Write-Host "Logs:        $scriptRoot\logs\bridge.log" -ForegroundColor Cyan

$answer = Read-Host "Start it now? (Y/N)"
if ($answer -match '^[Yy]') {
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    $info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
    Write-Host "State: $($info.LastTaskResult) / Last run: $($info.LastRunTime)" -ForegroundColor Green
    Write-Host "Tail the log to confirm it's polling: Get-Content '$scriptRoot\logs\bridge.log' -Wait -Tail 20" -ForegroundColor Cyan
}
