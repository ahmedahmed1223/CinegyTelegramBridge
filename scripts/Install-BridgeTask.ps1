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
    [string]$TaskName = "CinegyTelegramBridge",
    [string]$RunAsAccount = 'SYSTEM'
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent (Split-Path -Path $MyInvocation.MyCommand.Path -Parent)

# ---- refuse to install something that cannot run -------------------------
# Registering a supervisor around a broken configuration is the worst outcome
# available: the bridge crashes, the task restarts it, and it does that for
# ever while the task looks healthy.
& (Join-Path $PSScriptRoot 'Test-BridgeReadiness.ps1') -RunAsAccount $RunAsAccount
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Install aborted. Fix the failures above and run this again.' -ForegroundColor Red
    exit 1
}

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

$principal = New-ScheduledTaskPrincipal -UserId $RunAsAccount -LogonType ServiceAccount -RunLevel Highest

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
    $launchedAt = Get-Date
    Start-ScheduledTask -TaskName $TaskName
    Write-Host 'Waiting 12s to see whether it stays up...' -ForegroundColor Cyan
    Start-Sleep -Seconds 12
    Import-Module (Join-Path $scriptRoot 'Modules\BridgeInstall.psm1') -Force
    $log = Join-Path $scriptRoot 'logs\bridge.log'
    $starts = 0; $connected = $false
    if (Test-Path -LiteralPath $log) {
        foreach ($line in @(Get-Content -LiteralPath $log -Tail 200 -ErrorAction SilentlyContinue)) {
            $stamp = [datetime]::MinValue
            if (-not [datetime]::TryParse($line.Substring(0, [Math]::Min(19, $line.Length)), [ref]$stamp)) { continue }
            if ($stamp -lt $launchedAt) { continue }
            if ($line -match 'Bridge v.* starting') { $starts++ }
            if ($line -match 'Telegram connection changed .* to connected') { $connected = $true }
        }
    }
    # A task that ran and exited reports Ready, not Running - so a crash looks
    # like success unless the log is consulted.
    $state = if ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running') { 'Running' } else { 'Stopped' }
    $verdict = Get-BridgeStartVerdict -State $state -StartupLinesSinceLaunch $starts -SawTelegramConnection:$connected
    if ($verdict.Healthy) { Write-Host "  ok    $($verdict.Reason)" -ForegroundColor Green }
    else { Write-Host "  FAIL  $($verdict.Reason)" -ForegroundColor Red }

    Write-Host "Tail the log to confirm it's polling: Get-Content '$scriptRoot\logs\bridge.log' -Wait -Tail 20" -ForegroundColor Cyan
}
