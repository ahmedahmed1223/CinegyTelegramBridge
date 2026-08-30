#requires -Version 7
<#
    Test-ServiceLifecycle.ps1

    End-to-end lifecycle check of the bridge as a managed background service,
    run inside CI (windows-latest) WITHOUT real secrets. It builds a throwaway
    mock config + template registry, registers the bridge as a Windows Scheduled
    Task (the built-in supervisor, no third-party NSSM binary needed), starts it,
    confirms the process actually came up and wrote its startup line, then stops
    and removes the task so the runner stays clean.

    It deliberately uses a fake bot token/chat id, so Telegram never connects.
    That is fine: we are proving the service is installed, runs, stays up, and is
    manageable (start/stop/uninstall) - not that it can talk to Telegram.

    Exit code 0 = the service lifecycle behaves; 1 = something in the lifecycle broke.
#>

param(
    [string]$TaskName = "CinegyTelegramBridge-CI-$PID",
    [int]$WaitSeconds = 12
)

$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot | Split-Path -Parent
$workspace = Join-Path $env:ProgramData "CinegyTelegramBridge-CI-$([guid]::NewGuid().ToString('N'))"
$taskRegistered = $false

function Write-Step { param([string]$t) Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Stop-Step { param([string]$Message) throw $Message }

try {
    # ---- 1. isolate a full disposable bridge workspace ---------------------
    Write-Step "1/6  Build isolated mock workspace"
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    Get-ChildItem -LiteralPath $sourceRoot -Force | Where-Object {
        $_.Name -notin @('.git', 'artifacts', 'dist', 'logs', 'config.json', 'secrets.dpapi.json', 'templates.json')
    } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $workspace -Recurse -Force }
    $root = $workspace
    $example = Get-Content (Join-Path $root 'config.example.json') -Raw | ConvertFrom-Json
    $example.BotToken = '1234567890:AAAAfakeCIbotTokenNotReal000000000'
    $example.TemplateRegistryPath = 'templates.ci.json'
    $example.LogPath = '.\logs\bridge.log'
    $example.Settings.EnableSnapshot = $false
    $example.Settings.EnableLiveRelay = $false
    # v6 settings schema: OutputMonitorMinutes was removed (output monitoring
    # is now event-driven). Use the surviving threshold to silence alerts.
    $example.Settings.EnableTimedShow = $false
    $example.Settings.EnableNewsTickerManagement = $false
    $example.Settings.MaintenanceMode = $true
    $example.Settings.HideAllLayers = @()
    $example.Settings.OutputMonitorFailureAlertThreshold = 99999
    $configPath = Join-Path $root 'config.json'
    $example | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8
    $mockTemplates = [ordered]@{
        urgent = [ordered]@{ path = 'C:\CI\urgent.cintitle'; layer = 4; order = 1; description = 'CI mock'; fields = @('Headline.Text'); presets = @() }
    }
    $mockTemplates | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'templates.ci.json') -Encoding utf8

    # ---- 2. readiness gate -------------------------------------------------
    Write-Step "2/6  Run readiness gate"
    & (Join-Path $root 'scripts\Test-BridgeReadiness.ps1') -RunAsAccount 'SYSTEM' -Quiet
    if ($LASTEXITCODE -ne 0) { Stop-Step 'Readiness aborted the install.' }
    Write-Host '  ok    readiness passed' -ForegroundColor Green

    # ---- 3. install as a Scheduled Task ------------------------------------
    Write-Step "3/6  Register Scheduled Task"
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $bridge = Join-Path $root 'TelegramBridge.ps1'
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -WindowStyle Hidden -File `"$bridge`" -ConfigPath `"$configPath`"" -WorkingDirectory $root
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'CI service lifecycle test' -Force | Out-Null
    $taskRegistered = $true
    Write-Host '  ok    task registered' -ForegroundColor Green

    # ---- 4. start and confirm it came up ----------------------------------
    Write-Step "4/6  Start task and confirm it runs"
    $launchedAt = Get-Date
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds $WaitSeconds
    $task = Get-ScheduledTask -TaskName $TaskName
    $info = $task | Get-ScheduledTaskInfo
    $state = [string]$task.State
    Write-Host "  task state: $state | last result: $($info.LastTaskResult)"
    $log = Join-Path $root 'logs\bridge.log'
    $starts = 0
    if (Test-Path -LiteralPath $log) {
        foreach ($line in @(Get-Content -LiteralPath $log -Tail 100 -ErrorAction SilentlyContinue)) {
            $ts = [datetime]::MinValue
            if ([datetime]::TryParse($line.Substring(0, [Math]::Min(19, $line.Length)), [ref]$ts) -and $ts -ge $launchedAt -and $line -match 'Bridge v.* starting') { $starts++ }
        }
    }
    Import-Module (Join-Path $root 'Modules\BridgeInstall.psm1') -Force
    $verdict = Get-BridgeStartVerdict -State $state -StartupLinesSinceLaunch $starts
    if (-not $verdict.Healthy) { Stop-Step $verdict.Reason }
    Write-Host "  ok    $($verdict.Reason)" -ForegroundColor Green

    # ---- 5. stop -----------------------------------------------------------
    Write-Step "5/6  Stop task"
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Start-Sleep -Seconds 2
    $state = [string](Get-ScheduledTask -TaskName $TaskName).State
    if ($state -eq 'Running') { Stop-Step 'Task is still running after Stop-ScheduledTask.' }
    Write-Host '  ok    task stopped' -ForegroundColor Green

    Write-Host "`nService lifecycle check passed." -ForegroundColor Green
}
finally {
    Write-Step "6/6  Remove task and isolated workspace"
    if ($taskRegistered) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host '  ok    cleanup completed' -ForegroundColor Green
}
