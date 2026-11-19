#requires -Version 7
<#
    Start-DevBridge.ps1 - the bridge's web channel, for developing the web
    interface without a live station.

    Loads TelegramBridge.ps1 with -LoadOnly and config.example.json (the same
    way the tests do), opens the real web channel on a development pipe, and
    publishes a made-up air state that moves. Nothing here talks to Cinegy,
    and the placeholder token means nothing reaches Telegram either.

    A Telegram sign-in is approved automatically as the owner after a few
    seconds - there is no bot to approve it in. That shortcut exists only in
    this script.

        pwsh -File Web/dev/Start-DevBridge.ps1
        dotnet run --project Web/Server -- --PipeName CinegyTelegramBridge.Web.Dev
        pnpm --dir Web/Client dev
#>
param(
    [string]$PipeName = 'CinegyTelegramBridge.Web.Dev',
    [long]$OwnerId = 1001
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runtime = Join-Path ([IO.Path]::GetTempPath()) 'cgb-dev-bridge'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
. (Join-Path $root 'TelegramBridge.ps1') -LoadOnly -ConfigPath 'config.example.json' -RuntimePath $runtime

$config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @($OwnerId) -Force
$config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @($OwnerId, 1002) -Force
$config | Add-Member -NotePropertyName 'AllowedUserIds' -NotePropertyValue @($OwnerId, 1002, 1003) -Force
$script:UserAliases[[string]$OwnerId] = 'مدير المحطة'
$script:UserAliases['1002'] = 'رئيس التحرير'
$script:UserAliases['1003'] = 'مشغّل الفترة المسائية'
# Saving is the bridge's business on a station; here it would rewrite the
# example config in the repository.
function Save-Config { }
function Save-UserAliases { $true }
function Update-WebBotUsername { $script:WebBotUsername = 'cinegy_dev_bot' }

$script:WebChannelPipeName = $PipeName
Start-WebChannel

$started = Get-Date
$script:RuntimeState.Monitoring.TelegramConnectionState = 'connected'
$script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
$script:OnAir[1] = [pscustomobject]@{ Key = 'شعار القناة'; At = $started.AddMinutes(-47); UserId = $OwnerId; Source = 'bridge' }
$script:OnAir[3] = [pscustomobject]@{ Key = 'شريط الأخبار العاجلة'; At = $started.AddSeconds(-95); UserId = 1003; Source = 'bridge' }
$script:OnAir[5] = [pscustomobject]@{ Key = 'اسم الضيف — د. سامر الخطيب'; At = $started.AddSeconds(-20); UserId = 0; Source = 'cinegy' }
$script:AutoHideQueue = @([pscustomobject]@{ Layer = 5; At = $started.AddSeconds(40) })

Write-Host "Dev bridge on pipe $PipeName. Ctrl+C to stop." -ForegroundColor Cyan
try {
    while ($true) {
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = Get-Date
        $script:RuntimeState.Monitoring.LastCinegyStateFailedCount = 0
        foreach ($code in @($script:WebLoginRequests.Keys)) {
            $request = $script:WebLoginRequests[$code]
            if ($request.State -eq 'pending' -and ((Get-Date) - $request.ExpiresAt.AddMinutes(-$script:WebLoginLifetimeMinutes)).TotalSeconds -gt 4) {
                $request.State = 'approved'; $request.UserId = $OwnerId; $request.RequestedBy = $OwnerId
                Write-Host "DEV: approved sign-in $code as the owner" -ForegroundColor Yellow
            }
        }
        Publish-WebChannelState
        Invoke-WebChannelRequests
        Wait-WebChannelSignal -Milliseconds 250
    }
}
finally { Stop-WebChannel }
