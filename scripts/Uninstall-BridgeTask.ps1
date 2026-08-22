#requires -RunAsAdministrator
<#
    Uninstall-BridgeTask.ps1

    Stops and removes the Scheduled Task created by Install-BridgeTask.ps1.
    Run as Administrator.
#>

param(
    [string]$TaskName = "CinegyTelegramBridge"
)

$ErrorActionPreference = "Stop"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Host "No scheduled task named '$TaskName' found - nothing to remove." -ForegroundColor Yellow
    return
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false

Write-Host "Scheduled Task '$TaskName' stopped and removed." -ForegroundColor Green
