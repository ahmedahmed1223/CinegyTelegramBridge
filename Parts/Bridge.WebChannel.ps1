#requires -Version 7
<#
    The local channel between the bridge and CinegyBridge.Web.

    The web server is a separate process the control program starts. It never
    talks to Cinegy or Telegram: everything it knows comes through this named
    pipe, and everything it wants done goes back through it. That keeps one
    writer to the air - this script's thread - and one place where permission
    is decided, so the bot and the browser cannot disagree about either.

    Shape of the channel:
      * Listener runspaces own the pipe. They never see bridge state or
        functions. Reads ('status', 'identity', 'roster', 'live.playback') are answered from data the
        bridge thread publishes into $Shared; everything else is queued.
      * The bridge thread drains that queue in Update-WebChannel - from the
        tick, and from the pump that runs while a Telegram long poll is in
        flight - and hands each answer back to the waiting listener.

    Off by default (WebAccessEnabled). Off means no pipe, no pump, and the
    polling loop running exactly as it did before this file existed.
#>

$script:WebChannel = $null
$script:WebTickerSheetRequest = $null
$script:WebTickerTxtRequest = $null
$script:WebBulletinPhotoRequest = $null
$script:WebSceneRequest = $null
$script:WebUrgentManualReviews = @{}
$script:WebTemplateRehearsalReviews = @{}
$script:WebTemplateCatalogueReviews = @{}
$script:WebTemplateManagementReviews = @{}
$script:WebProgrammeBoardAirReviews = @{}
$script:WebBulletinPlaybackReviews = @{}
$script:WebTickerTxtModule = Join-Path $PSScriptRoot '..\Modules\BridgeNewsTicker.psm1'
$script:WebChannelPipeName = 'CinegyTelegramBridge.Web'
$script:WebChannelListenerCount = 4
$script:WebChannelPublishedAt = [datetime]::MinValue
# Accounts made in the browser for people without Telegram. Real Telegram user
# ids stay below 2^52; this range cannot collide with one, and nothing sent to
# it can reach anyone, so the send paths skip it.
$script:WebOnlyUserIdBase = 9000000000000000L
# code -> sign-in request awaiting approval in Telegram.
$script:WebLoginRequests = @{}
$script:WebLoginLifetimeMinutes = 5
$script:WebLoginMaxPending = 50
$script:WebRelayDestinationReviews = @{}
$script:WebRelayReviewKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$script:WebBulletinPreviewKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$script:WebCaptureRecords = @{}
$script:WebBotUsername = ''

function Test-WebOnlyUserId {
    param([long]$UserId)
    return $UserId -ge $script:WebOnlyUserIdBase
}

function Test-WebChannelActive {
    return $null -ne $script:WebChannel
}

function Get-WebChannelListenerScript {
    <# Runs inside each listener runspace. Deliberately plain: no bridge
       functions, no StrictMode, nothing but the pipe and $Shared. #>
    return {
        param($Shared, $PipeName, $Instances)
        $security = [System.IO.Pipes.PipeSecurity]::new()
        $owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new($owner, 'ReadWrite', 'Allow'))
        # The same account logged on over the network is still "the owner";
        # the channel is for this machine only.
        $network = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-2')
        $security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new($network, 'FullControl', 'Deny'))
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        while (-not $Shared.Stop) {
            $pipe = $null
            try {
                $pipe = [System.IO.Pipes.NamedPipeServerStreamAcl]::Create($PipeName, 'InOut', $Instances, 'Byte', 'Asynchronous', 0, 0, $security)
                $connecting = $pipe.WaitForConnectionAsync()
                while (-not $connecting.Wait(500)) { if ($Shared.Stop) { return } }
                $reader = [System.IO.StreamReader]::new($pipe, $utf8, $false, 4096, $true)
                $writer = [System.IO.StreamWriter]::new($pipe, $utf8, 4096, $true)
                $reading = $reader.ReadLineAsync()
                if (-not $reading.Wait(5000)) { continue }
                $line = [string]$reading.Result
                $reply = '{"ok":false,"error":"bad_request"}'
                if ($line.Length -gt 0 -and $line.Length -le 65536) {
                    $request = $null
                    try { $request = $line | ConvertFrom-Json -AsHashtable } catch { $request = $null }
                    if ($request -is [System.Collections.IDictionary] -and $request.Contains('op')) {
                        $op = [string]$request['op']
                        if ($op -eq 'status') {
                            # Composed, not re-serialised: the bridge thread
                            # already produced the JSON once.
                            $reply = '{"ok":true,"data":' + [string]$Shared.Status + '}'
                        }
                        elseif ($op -eq 'live.playback') {
                            # Local process read; the HTTP server enforces the browser session.
                            $reply = '{"ok":true,"data":' + [string]$Shared.Playback + '}'
                        }
                        elseif ($op -eq 'identity') {
                            $lookup = $request['args']
                            $who = if ($lookup -is [System.Collections.IDictionary]) { [string]$lookup['userId'] } else { '' }
                            $entry = $Shared.Roster[$who]
                            $reply = if ($entry) { '{"ok":true,"data":' + $entry + '}' } else { '{"ok":true,"data":null}' }
                        }
                        elseif ($op -eq 'roster') {
                            $reply = '{"ok":true,"data":[' + (@($Shared.Roster.Values) -join ',') + ']}'
                        }
                        else {
                            $item = @{
                                Request = $request
                                Deadline = [Diagnostics.Stopwatch]::GetTimestamp() + 15 * [Diagnostics.Stopwatch]::Frequency
                                Claim = [System.Threading.Tasks.TaskCompletionSource[bool]]::new()
                                Reply = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
                            }
                            $Shared.Queue.Enqueue($item)
                            [void]$Shared.Signal.Set()
                            $reply = if ($item.Reply.Task.Wait(15000)) { $item.Reply.Task.Result }
                                elseif ($item.Claim.TrySetResult($false) -or -not $item.Claim.Task.Result) { '{"ok":false,"error":"bridge_busy"}' }
                                else { '{"ok":false,"error":"bridge_outcome_unknown"}' }
                        }
                    }
                }
                $writer.WriteLine($reply)
                $writer.Flush()
                $pipe.WaitForPipeDrain()
            }
            catch {
                # A client that hung up mid-answer is its own problem; the
                # listener goes back to waiting for the next one.
                $Shared.LastListenerError = $_.Exception.Message
            }
            finally { if ($pipe) { $pipe.Dispose() } }
        }
    }
}

function Start-WebChannel {
    if (Test-WebChannelActive) { return }
    $shared = [hashtable]::Synchronized(@{
            Queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            Signal = [System.Threading.AutoResetEvent]::new($false)
            Status = '{}'
            Playback = '{"url":null}'
            Roster = @{}
            Stop = $false
            LastListenerError = ''
        })
    $pool = [runspacefactory]::CreateRunspacePool(1, $script:WebChannelListenerCount)
    $pool.Open()
    $listeners = foreach ($index in 1..$script:WebChannelListenerCount) {
        $pipeline = [powershell]::Create()
        $pipeline.RunspacePool = $pool
        $pipeline.AddScript((Get-WebChannelListenerScript)).AddArgument($shared).AddArgument($script:WebChannelPipeName).AddArgument($script:WebChannelListenerCount) | Out-Null
        @{ Pipeline = $pipeline; Handle = $pipeline.BeginInvoke() }
    }
    $script:WebChannel = @{ Shared = $shared; Pool = $pool; Listeners = @($listeners); PlaybackSetting = $null }
    $script:WebChannelPublishedAt = [datetime]::MinValue
    Publish-WebChannelState -Force
    Update-WebBotUsername
    Write-BridgeLog "Web channel open on pipe $($script:WebChannelPipeName)"
}

function Stop-WebChannel {
    if (-not (Test-WebChannelActive)) { return }
    $channel = $script:WebChannel
    $script:WebChannel = $null
    $channel.Shared.Stop = $true
    Stop-WebTickerSheetRequest -ErrorCode 'channel_closed'
    Stop-WebBulletinPhotoRequest -ErrorCode 'channel_closed'
    Stop-WebSceneRequest -Code 'channel_closed'
    if ($script:WebTickerTxtRequest) {
        $worker = $script:WebTickerTxtRequest
        $script:WebTickerTxtRequest = $null
        [void]$worker.Entry.Reply.TrySetResult('{"ok":false,"error":"channel_closed"}')
        $worker.Pipeline.Dispose()
    }
    # Anyone still waiting gets an answer rather than a fifteen-second hang.
    $pending = $null
    while ($channel.Shared.Queue.TryDequeue([ref]$pending)) {
        [void]$pending.Claim.TrySetResult($false)
        [void]$pending.Reply.TrySetResult('{"ok":false,"error":"channel_closed"}')
    }
    foreach ($listener in $channel.Listeners) {
        try { $listener.Pipeline.Stop() } catch { Write-BridgeLog "Web channel listener did not stop cleanly: $($_.Exception.Message)" 'DEBUG' }
        $listener.Pipeline.Dispose()
    }
    $channel.Pool.Dispose()
    $channel.Shared.Signal.Dispose()
    Write-BridgeLog 'Web channel closed'
}

function Update-WebBotUsername {
    <# Lets the sign-in page offer a t.me link. Best effort: without it the
       page shows the /web command to type, which works just as well. #>
    if ($script:WebBotUsername) { return }
    try {
        $probe = Invoke-BridgeTelegramRequest -Uri "$apiBase/getMe" -Method Get -TimeoutSec 3
        if ($probe.Success) { $script:WebBotUsername = [string](Get-JsonProp (Get-JsonProp $probe.Response 'result') 'username') }
    }
    catch { Write-BridgeLog "Web channel could not read the bot username: $($_.Exception.Message)" 'DEBUG' }
}

function Get-WebStatusSnapshot {
    param([datetime]$Now = (Get-Date))
    $monitoring = $script:RuntimeState.Monitoring
    $lastRead = $monitoring.LastCinegyStateSuccess
    $freshUntil = 0L
    if ($lastRead -gt [datetime]::MinValue -and $monitoring.LastCinegyStateFailedCount -eq 0) {
        $freshUntil = ([datetimeoffset]$lastRead.AddSeconds((Get-SettingInt 'CinegyStateStaleSeconds' 45))).ToUnixTimeMilliseconds()
    }
    $layers = foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
        $record = $script:OnAir[$layer]
        $timer = @($script:AutoHideQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq [int]$layer }) | Select-Object -First 1
        $source = [string](Get-JsonProp $record 'Source')
        $actorId = [long](Get-JsonProp $record 'UserId')
        [ordered]@{
            layer = [int]$layer
            key = [string](Get-JsonProp $record 'Key')
            name = Get-WebLayerNameSafe -Layer ([int]$layer)
            at = ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $record 'At')
            hideAt = if ($timer) { ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $timer 'At') } else { 0 }
            source = if ($source) { $source } else { 'bridge' }
            by = if ($actorId -gt 0) { Get-UserDisplayName -UserId $actorId } else { '' }
        }
    }
    $telegramHistory = $script:HealthHistory.Telegram
    return [ordered]@{
        version = $script:BridgeVersion
        startedAt = ([datetimeoffset]$script:BridgeStartedAt).ToUnixTimeMilliseconds()
        publishedAt = ([datetimeoffset]$Now).ToUnixTimeMilliseconds()
        telegram = [ordered]@{
            state = [string]$monitoring.TelegramConnectionState
            failures = [int]$telegramHistory.FailureCount
        }
        cinegy = [ordered]@{
            address = [string]$config.AirServerAddress
            channel = [int]$config.AirChannelNumber
            health = [string]$monitoring.CinegyHealthState
            lastReadAt = ConvertTo-AirStatusWidgetEpoch $lastRead
            freshUntil = $freshUntil
        }
        feed = Get-WebFeedStatus -Now $Now
        layers = @($layers)
        urgentNoticeId = Get-UrgentWebNoticeId
        urgentRevision = [int](Get-JsonProp $script:UrgentBoard 'Revision')
    }
}

function Get-WebFeedStatus {
    param([datetime]$Now)
    $settings = Get-JsonProp $config 'LiveStream'
    $primary = [string](Get-JsonProp $settings 'SourceUrl')
    $backup = [string](Get-JsonProp $settings 'BackupSourceUrl')
    $usesBackup = $script:OutputMonitorFallbackActive -and $backup
    $monitorMinutes = Get-SettingInt 'OutputMonitorMinutes' 0
    $unreachable = Get-BridgeOpenOutage -Ledger $script:StreamOutages -Kind unreachable
    $black = Get-BridgeOpenOutage -Ledger $script:StreamOutages -Kind black
    $state = if ($unreachable) { 'unreachable' }
    elseif ($black) { 'black' }
    elseif (-not $primary) { 'unconfigured' }
    elseif (-not $monitorMinutes) { 'off' }
    elseif ($script:LastOutputMonitorAt -eq [datetime]::MinValue) { 'pending' }
    elseif ($script:OutputMonitorFailureCount -gt 0) { 'degraded' }
    else { 'receiving' }
    $summary = Get-BridgeOutageSummary -Ledger $script:StreamOutages -WindowHours 24 -Now $Now
    $recent = @(
        foreach ($outage in @($script:StreamOutages.Outages | Select-Object -First 8)) {
            @{
                kind = [string]$outage.Kind
                startedAt = ConvertTo-AirStatusWidgetEpoch $outage.StartedAt
                endedAt = ConvertTo-AirStatusWidgetEpoch $outage.EndedAt
            }
        }
    )
    return @{
        state = $state; activeSource = $(if ($usesBackup) { 'backup' } elseif ($primary) { 'primary' } else { 'none' })
        backupConfigured = [bool]$backup; intervalMinutes = $monitorMinutes
        lastCheckAt = ConvertTo-AirStatusWidgetEpoch $script:LastOutputMonitorAt
        outageCount = $summary.Count; outageSeconds = $summary.TotalSeconds; recent = $recent
    }
}

function Get-WebLayerNameSafe {
    param([int]$Layer)
    try { return [string](Get-LayerName -Layer $Layer) } catch { return '' }
}

function Get-WebRoster {
    $roster = @{}
    foreach ($user in @(Get-AuthorizedUsers)) {
        if ($user.Disabled) { continue }
        $roster[[string]$user.UserId] = ([ordered]@{
                id = [long]$user.UserId
                name = [string]$user.Alias
                role = [string]$user.Role
                webOnly = Test-WebOnlyUserId -UserId ([long]$user.UserId)
            } | ConvertTo-Json -Compress)
    }
    return $roster
}

function Publish-WebChannelState {
    <# Twice a second at most: the listeners answer reads from this copy, so
       its age is the most a status read can lag. #>
    param([switch]$Force)
    if (-not (Test-WebChannelActive)) { return }
    $now = Get-Date
    if (-not $Force -and ($now - $script:WebChannelPublishedAt).TotalMilliseconds -lt 500) { return }
    $script:WebChannelPublishedAt = $now
    $shared = $script:WebChannel.Shared
    $shared.Status = (Get-WebStatusSnapshot -Now $now | ConvertTo-Json -Compress -Depth 6)
    # The settings writer owns this value. Rebuild the separate playback
    # snapshot only when it changes, rather than parsing it on each air tick.
    $playbackSetting = Get-JsonProp (Get-JsonProp $config 'Settings') 'WebLivePlaybackUrl'
    if (-not [object]::Equals((Get-JsonProp $script:WebChannel 'PlaybackSetting'), $playbackSetting)) {
        $shared.Playback = (@{ url = ConvertTo-WebLivePlaybackUrl $playbackSetting } | ConvertTo-Json -Compress)
        $script:WebChannel.PlaybackSetting = $playbackSetting
    }
    $shared.Roster = Get-WebRoster
}

function Invoke-WebChannelRequests {
    <# Drains what the listeners queued. Bounded per call so a flood of
       requests cannot hold the air clock; the rest wait for the next pass. #>
    param([int]$Limit = 25)
    Update-WebBulletinPhotoRequest
    Update-WebSceneRequest
    if (-not (Test-WebChannelActive)) { return }
    Update-WebTickerSheetRequest
    Update-WebTickerTxtRequest
    $queue = $script:WebChannel.Shared.Queue
    $item = $null
    for ($handled = 0; $handled -lt $Limit -and $queue.TryDequeue([ref]$item); $handled++) {
        if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $item.Deadline) {
            [void]$item.Claim.TrySetResult($false)
            [void]$item.Reply.TrySetResult('{"ok":false,"error":"bridge_busy"}')
            continue
        }
        # A listener that already reported a queue timeout wins the claim and
        # the abandoned command must never reach the air-control thread.
        if (-not $item.Claim.TrySetResult($true)) { continue }
        $answer = $null
        try {
            $answer = Invoke-WebChannelOperation -Request $item.Request -Entry $item
            if ($null -eq $answer -and (
                [object]::ReferenceEquals((Get-JsonProp $script:WebTickerSheetRequest 'Entry'), $item) -or
                [object]::ReferenceEquals((Get-JsonProp $script:WebTickerTxtRequest 'Entry'), $item) -or
                [object]::ReferenceEquals((Get-JsonProp $script:WebBulletinPhotoRequest 'Entry'), $item) -or
                [object]::ReferenceEquals((Get-JsonProp $script:WebSceneRequest 'Entry'), $item))) { continue }
        }
        catch {
            Write-BridgeLog "Web channel operation failed: $($_.Exception.Message)" 'ERROR'
            $answer = @{ ok = $false; error = 'internal' }
        }
        [void]$item.Reply.TrySetResult(($answer | ConvertTo-Json -Compress -Depth 6))
    }
}

function Invoke-WebChannelOperation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request, [hashtable]$Entry)
    $op = [string](Get-JsonProp $Request 'op')
    $arguments = Get-JsonProp $Request 'args'
    if ($arguments -isnot [System.Collections.IDictionary]) { $arguments = @{} }
    switch ($op) {
        'ping' { return @{ ok = $true; data = @{ version = $script:BridgeVersion } } }
        'login.register' { return Register-WebLoginRequest -Arguments $arguments }
        'login.status' { return Get-WebLoginRequestState -Code ([string](Get-JsonProp $arguments 'code')) }
        'account.grant' { return Grant-WebOnlyAccount -Arguments $arguments }
        'account.revoke' { return Revoke-WebOnlyAccount -Arguments $arguments }
        'air.templates' { return Get-WebTemplates }
        'air.templateScene' { return Invoke-WebTemplateSceneRequest -Arguments $arguments -Entry $Entry }
        'air.templateCatalogue' { return Start-WebSceneRequest -Arguments $arguments -Entry $Entry }
        'air.templateDefinition' { return Invoke-WebTemplateDefinition -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.hideAllScope' { return Get-WebHideAllLayerScope -Arguments $arguments }
        'air.hideAllScope.review' { return New-WebHideAllLayerScopeReview -Arguments $arguments }
        'air.hideAllScope.confirm' { return Complete-WebHideAllLayerScopeReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.personalReminders' { return Get-WebPersonalAirReminders -Arguments $arguments }
        'air.personalReminder.act' { return Invoke-WebPersonalAirReminderAction -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.templateFavorites' { return Get-WebTemplateFavorites -Arguments $arguments }
        'air.templateFavorite.set' { return Set-WebTemplateFavorite -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.settings.recovery.backups' { return Get-WebAdminSettingsBackups -Arguments $arguments }
        'admin.settings.recovery.review' { return New-WebAdminSettingsRecoveryReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.settings.recovery.confirm' { return Complete-WebAdminSettingsRecoveryReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.settings.import.review' { return New-WebAdminSettingsImportReview -Arguments $arguments }
        'admin.settings.import.confirm' { return Complete-WebAdminSettingsImportReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.settings.export' { return Get-WebAdminSettingsExport -Arguments $arguments }
        'admin.settings.review' { return New-WebAdminSettingReview -Arguments $arguments }
        'admin.settings.confirm' { return Complete-WebAdminSettingReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.notifications.coverage' { return Get-WebAdminNotificationCoverage -Arguments $arguments }
        'admin.usage-summary' { return Get-WebUsageSummary -Arguments $arguments }
        'admin.readiness' { return Get-WebShiftReadiness -Arguments $arguments }
        'admin.self-test.readiness' { return Get-WebSelfTestReadiness -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.restart.review' { return Invoke-WebManagedRestart -Action reserve -Arguments $arguments }
        'admin.restart.confirm' { return Invoke-WebManagedRestart -Action confirm -Arguments $arguments }
        'admin.restart.cancel' { return Invoke-WebManagedRestart -Action cancel -Arguments $arguments }
        'admin.restart.accept' { return Invoke-WebManagedRestart -Action ack -Arguments $arguments }
        'admin.restart.status' { return Invoke-WebManagedRestart -Action status -Arguments $arguments }
        'admin.restart.readiness' { return Get-WebRestartReadiness -Arguments $arguments }
        'admin.overview' { return Get-WebAdminOverview -Arguments $arguments }
        'help.operator' { return Invoke-WebOperatorHelp -Arguments $arguments }
        'shift.notices' { return Invoke-WebShiftNotice -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'telegram.access.revoke.review' { return New-WebTelegramRevokeReview -Arguments $arguments }
        'telegram.access.revoke.confirm' { return Complete-WebTelegramRevokeReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'telegram.access.suspended-operators' { return Get-WebSuspendedTelegramOperators -Arguments $arguments }
        'telegram.access.suspension.review' { return New-WebTelegramSuspensionReview -Arguments $arguments }
        'telegram.access.suspension.confirm' { return Complete-WebTelegramSuspensionReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'telegram.access.history' { return Get-WebAccessHistoryPage -Arguments $arguments }
        'telegram.access.alias.review' { return New-WebTelegramAliasReview -Arguments $arguments }
        'telegram.access.alias.confirm' { return Complete-WebTelegramAliasReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'telegram.access.operator-activity' { return Get-WebTelegramOperatorActivity -Arguments $arguments }
        'telegram.access.presence' { return Get-WebTelegramPresence -Arguments $arguments }
        'telegram.delivery.quarantine' { return Get-WebTelegramDeliveryQuarantine -Arguments $arguments }
        'telegram.delivery.quarantine.reset.review' { return New-WebTelegramQuarantineResetReview -Arguments $arguments }
        'telegram.delivery.quarantine.reset.confirm' { return Complete-WebTelegramQuarantineResetReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'telegram.access.blocked' { return Get-WebBlockedAccessPage -Arguments $arguments }
        'telegram.access.unblock.review' { return New-WebTelegramUnblockReview -Arguments $arguments }
        'telegram.access.unblock.confirm' { return Complete-WebTelegramUnblockReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.announcements.list' { return Get-WebAnnouncementPage -Arguments $arguments }
        'admin.announcements.queue.review' { return New-WebAnnouncementReview -Arguments $arguments }
        'admin.announcements.queue.confirm' { return Complete-WebAnnouncementReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.announcements.cancel.review' { return New-WebAnnouncementCancelReview -Arguments $arguments }
        'admin.announcements.cancel.confirm' { return Complete-WebAnnouncementCancelReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.operation-metrics' { return Get-WebOperationMetrics -Arguments $arguments }
        'admin.engine-health' { return Get-WebEngineHealth -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'admin.diagnostics.bundle' { return Get-WebDiagnosticBundle -Arguments $arguments }
        'admin.diagnostics.runtime-files' { return Get-WebRuntimeFileDiagnostics -Arguments $arguments }
        'schedule.executions' { return Get-WebScheduleExecutionPage -Arguments $arguments }
        'schedule.hold.review' { return New-WebScheduleHoldReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'schedule.hold.confirm' { return Complete-WebScheduleHoldReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'reports.templates' { return Get-WebTemplateReport -Arguments $arguments }
        'reports.weekly' { return Get-WebWeeklyReport -Arguments $arguments }
        'reports.handover.acknowledge' { return Invoke-WebShiftHandoverAcknowledgement -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'reports.handover' { return Get-WebShiftHandoverReport -Arguments $arguments }
        'reports.ticker' { return Get-WebTickerReport -Arguments $arguments }
        'reports.bulletins' { return Get-WebBulletinReport -Arguments $arguments }
        'reports.work-summary' { return Get-WebWorkSummary -Arguments $arguments }
        'shift.history' { return Invoke-WebShiftHistory -Arguments $arguments }
        'shift.operation-reference' { return Get-WebOperationReferenceLookup -Arguments $arguments }
        'air.maintenance' { return Invoke-WebAirMaintenance -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.emergency-hide' { return Invoke-WebEmergencyHide -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.timer' { return Invoke-WebAirTimer -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.text' { return Invoke-WebAirText -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.rollback' { return Invoke-WebAirRollback -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.rerun' { return Invoke-WebAirRerun -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'schedule.templates' { return Invoke-WebTemplateSchedule -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'telegram.access.requests' { return Get-WebTelegramAccessRequests -Arguments $arguments }
        'admin.layerNames' { return Get-WebLayerNames -Arguments $arguments }
        'admin.layerName.review' { return New-WebLayerNameReview -Arguments $arguments }
        'admin.layerName.confirm' { return Complete-WebLayerNameReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'telegram.access.review' { return New-WebTelegramAccessDecisionReview -Arguments $arguments }
        'telegram.access.decide' { return Invoke-WebTelegramAccessDecision -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'telegram.access.role' { return Set-WebTelegramAccessRole -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.presets' { return Get-WebTemplatePresets -Arguments $arguments }
        'air.preset-change' { return Invoke-WebTemplatePresetChange -Arguments $arguments }
        'air.rehearsal' { return Invoke-WebTemplateRehearsal -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.show' { return Invoke-WebAirShow -Arguments $arguments }
        'air.template-issues' { return Invoke-WebTemplateIssue -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.template-backups' { return Invoke-WebTemplateBackup -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.template-registry-export' { return Invoke-WebTemplateRegistryExport -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.template-registry-import' { return Invoke-WebTemplateRegistryImport -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.templateMaxAir' { return Get-WebTemplateMaxAir -Arguments $arguments }
        'air.templateMaxAir.review' { return New-WebTemplateMaxAirReview -Arguments $arguments }
        'air.templateMaxAir.confirm' { return Complete-WebTemplateMaxAirReview -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.layer-removal' { return Invoke-WebLayerRemoval -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.programme' { return Get-WebProgrammeNowNext -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.layer-comparison' { return Get-WebLayerComparison -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.layer-adoption.review' { return Invoke-WebLayerAdoption -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.layer-adoption.confirm' { return Invoke-WebLayerAdoption -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) -ApplyReview }
        'air.layer-forget.review' { return Invoke-WebLayerForget -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.layer-forget.confirm' { return Invoke-WebLayerForget -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) -ApplyReview }
        'air.layer-replacement.review' { return Invoke-WebLayerReplacement -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'air.layer-replacement.confirm' { return Invoke-WebLayerReplacement -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) -ApplyReview }
        'air.hide' { return Invoke-WebAirHide -Arguments $arguments }
        'air.exit' { return Invoke-WebAirExit -Arguments $arguments }
        'content.list' { return Get-WebContentPage -Arguments $arguments }
        'urgent.write' { return Invoke-WebUrgentWrite -Arguments $arguments }
        'urgent.timing' { return Invoke-WebUrgentTiming -Arguments $arguments }
        'urgent.playback' { return Invoke-WebUrgentPlayback -Arguments $arguments }
        'urgent.manual' { return Invoke-WebUrgentManual -Arguments $arguments }
        'ticker.edit' { return Invoke-WebTickerEdit -Arguments $arguments }
        'ticker.txt' { return Start-WebTickerTxtRequest -Entry $Entry }
        'ticker.sets' { return Invoke-WebTickerSets -Arguments $arguments }
        'ticker.backups' { return Invoke-WebTickerBackups -Arguments $arguments }
        'ticker.sheet' { return Start-WebTickerSheetRequest -Entry $Entry }
        'bulletin.edit' { return Invoke-WebBulletinEdit -Arguments $arguments }
        'bulletin.scene-images' { return Invoke-WebBulletinSceneImages -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'bulletin.management' { return Invoke-WebBulletinManagement -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'bulletin.afterUrgent' { return Invoke-WebBulletinAfterUrgent -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'bulletin.preview' { return Get-WebBulletinPreview -Arguments $arguments }
        'bulletin.playback' { return Invoke-WebBulletinPlayback -Arguments $arguments }
        'bulletin.preview-image' { return Get-WebBulletinPreview -Arguments $arguments -Image }
        'bulletin.schedule' { return Invoke-WebBulletinSchedule -Arguments $arguments }
        'bulletin.photo' { return Start-WebBulletinPhotoRequest -Entry $Entry }
        'bulletin.paste' { return Invoke-WebBulletinPaste -Arguments $arguments }
        'board.list' { return Get-WebProgrammeBoards -Arguments $arguments }
        'board.edit' { return Invoke-WebProgrammeBoardEdit -Arguments $arguments }
        'board.delete' { return Remove-WebProgrammeBoard -Arguments $arguments }
        'board.paste' { return Invoke-WebProgrammeBoardPaste -Arguments $arguments }
        'board.air' { return Invoke-WebProgrammeBoardAir -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'relay.destination.review' { return Invoke-WebRelayDestination -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) }
        'relay.destination.confirm' { return Invoke-WebRelayDestination -Arguments $arguments -Deadline ([long](Get-JsonProp $Entry 'Deadline')) -ApplyReview }
        'relay.control' { return Invoke-WebRelayControl -Arguments $arguments }
        'media.capture' { return Invoke-WebCapture -Arguments $arguments }
    }
    return @{ ok = $false; error = 'unknown_op' }
}

function Remove-ExpiredWebCaptures {
    $now = Get-Date
    foreach ($id in @($script:WebCaptureRecords.Keys)) {
        $capture = $script:WebCaptureRecords[$id]
        if ($capture.State -eq 'pending' -or $capture.ExpiresAt -gt $now) { continue }
        Remove-Item -LiteralPath (Get-WebCaptureFilePath -Capture $capture) -Force -ErrorAction SilentlyContinue
        $script:WebCaptureRecords.Remove($id)
    }
}

function Invoke-WebCapture {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    Remove-ExpiredWebCaptures
    $action = [string](Get-JsonProp $Arguments 'action')
    switch ($action) {
        'start' {
            $kind = [string](Get-JsonProp $Arguments 'kind')
            if ($kind -cnotin 'photo', 'clip') { return @{ ok = $false; error = 'capture_invalid' } }
            $actorRecords = @($script:WebCaptureRecords.Values | Where-Object Actor -eq $actor)
            if ($actorRecords.Count -ge 4) { return @{ ok = $false; error = 'capture_actor_capacity' } }
            if ($script:WebCaptureRecords.Count -ge 12) { return @{ ok = $false; error = 'capture_capacity' } }
            $capture = @{
                Id = [guid]::NewGuid().ToString('N'); Actor = $actor; Kind = $kind
                State = 'pending'; Source = ''; CompletedAt = $null; ExpiresAt = $null
            }
            $outcome = Request-OutputCapture -ChatId $actor -UserId $actor -Kind $kind -WebCapture $capture
            if ($outcome.Code -eq 'cached') {
                Complete-WebOutputCapture -Capture $capture -Path $script:LastSnapshotFile -SourceIsPrimary $script:LastSnapshotSourceIsPrimary
                if ($capture.State -eq 'ready') { $capture.CompletedAt = $script:LastSnapshotAt }
            }
            elseif ($outcome.Code -ne 'pending') { return @{ ok = $false; error = $outcome.Code } }
            $script:WebCaptureRecords[$capture.Id] = $capture
        }
        { $_ -in 'status', 'file' } {
            $id = [string](Get-JsonProp $Arguments 'id')
            $capture = $script:WebCaptureRecords[$id]
            if (-not $capture -or $capture.Actor -ne $actor) { return @{ ok = $false; error = 'not_found' } }
            if ($capture.State -eq 'ready' -and -not (Test-Path -LiteralPath (Get-WebCaptureFilePath -Capture $capture) -PathType Leaf)) {
                return @{ ok = $false; error = 'not_found' }
            }
            if ($action -eq 'file') {
                if ($capture.State -ne 'ready') { return @{ ok = $false; error = 'not_found' } }
                return @{ ok = $true; data = @{ kind = $capture.Kind; path = Get-WebCaptureFilePath -Capture $capture } }
            }
        }
        default { return @{ ok = $false; error = 'capture_invalid' } }
    }
    return @{ ok = $true; data = @{
        id = $capture.Id; state = $capture.State; kind = $capture.Kind; source = $capture.Source
        completedAt = ConvertTo-AirStatusWidgetEpoch $capture.CompletedAt
        expiresAt = ConvertTo-AirStatusWidgetEpoch $capture.ExpiresAt
    } }
}

function Get-WebRelayControlState {
    $enabled = [bool](Get-Setting 'EnableLiveRelay')
    $source = Get-ActiveLiveStreamConfig
    $inputUrl = [string](Get-JsonProp $source 'SourceUrl')
    $destination = [string](Get-JsonProp $source 'RtmpDestination')
    $configured = -not ([string]::IsNullOrWhiteSpace($inputUrl) -or [string]::IsNullOrWhiteSpace($destination))
    $process = Get-RunningRelayProcess -ReadOnly -RequireTimestamp
    $unverified = -not $process -and [bool](Get-RunningRelayProcess -ReadOnly)
    $retry = [bool]$script:RelayState.ShouldRun
    $state = if ($unverified) { 'unverified' }
    elseif ($retry -and (Get-JsonProp $script:RelayState 'SourceRestartPending')) { 'switching' }
    elseif ($script:RelayState.VerifyAt) { 'starting' }
    elseif ($process) { 'running' }
    elseif ($retry) { 'retrying' }
    elseif (-not $enabled) { 'disabled' }
    elseif (Get-JsonProp $script:RelayState 'StartFailed') { 'failed' }
    else { 'stopped' }

    # Bind the operator's review to the exact process and station input. The
    # opaque value must not reveal credentials embedded in either URL.
    $processIdentity = if ($process) { "$($process.Id)|$($process.StartTime.ToUniversalTime().Ticks)" } else { '' }
    $generation = [long](Get-JsonProp $script:RelayState 'Revision')
    $reviewed = ConvertTo-Json -Compress -InputObject @($state, $enabled, $configured, $retry, $generation, $processIdentity, $inputUrl, $destination)
    $revision = [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData($script:WebRelayReviewKey, [Text.Encoding]::UTF8.GetBytes($reviewed)))
    return @{
        Process = $process
        Data = @{
            state = $state; revision = $revision; enabled = $enabled; configured = $configured
            canStart = $state -in 'stopped', 'failed' -and $configured
            canStop = -not $unverified -and ([bool]$process -or $retry)
            canEditDestination = $state -in 'stopped', 'disabled', 'failed' -and -not (Test-Path -LiteralPath $relayPidFile)
            outcome = ''
        }
    }
}

function Invoke-WebRelayControl {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -notin 'status', 'start', 'stop') { return @{ ok = $false; error = 'relay_invalid' } }
    $current = Get-WebRelayControlState
    if ($action -eq 'status') { return @{ ok = $true; data = $current.Data } }
    if ((Get-JsonProp $Arguments 'revision') -cne $current.Data.revision) {
        return @{ ok = $false; error = 'relay_stale' }
    }
    if ($action -eq 'start') {
        if (-not $current.Data.canStart) { return @{ ok = $false; error = 'relay_unavailable' } }
        $operation = Start-LiveRelayOperation -UserId $actor
        if ($operation.Code -eq 'failed') { return @{ ok = $false; error = 'relay_start_failed' } }
        if ($operation.Code -ne 'starting') { return @{ ok = $false; error = 'relay_stale' } }
    }
    else {
        if (-not $current.Data.canStop) { return @{ ok = $false; error = 'relay_unavailable' } }
        $operation = Stop-LiveRelayOperation -UserId $actor -Process $current.Process
        if ($operation.Code -eq 'failed') { return @{ ok = $false; error = 'relay_stop_failed' } }
    }
    $updated = (Get-WebRelayControlState).Data
    $updated.outcome = $operation.Code
    return @{ ok = $true; data = $updated }
}

function Update-WebChannel {
    <# The tick step: follows the setting, publishes state, answers requests. #>
    $wanted = [bool](Get-Setting 'WebAccessEnabled')
    if ($wanted -and -not (Test-WebChannelActive)) { Start-WebChannel }
    elseif (-not $wanted -and (Test-WebChannelActive)) { Stop-WebChannel }
    if (Test-WebChannelActive) { Publish-WebChannelState }
    Invoke-WebChannelRequests
    if (Test-WebChannelActive) { Update-WebLoginExpiry }
}

function Wait-WebChannelSignal {
    <# Sleeps until a request arrives or the time runs out, whichever is
       first - which is what makes a browser click land without waiting for
       the next long poll to return. #>
    param([int]$Milliseconds)
    if (Test-WebChannelActive) { [void]$script:WebChannel.Shared.Signal.WaitOne($Milliseconds) }
    else { Start-Sleep -Milliseconds $Milliseconds }
}

function Invoke-WebChannelPump {
    <# One pass of the work that must not wait for Telegram: web requests
       always, and the tick when its time has come. Called while a long poll
       is in flight and through the polling backoff. #>
    param([Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Clock, [Parameter(Mandatory)][hashtable]$Schedule)
    Wait-WebChannelSignal -Milliseconds 200
    Publish-WebChannelState
    Invoke-WebChannelRequests
    if ($Clock.Elapsed.TotalSeconds -ge $Schedule.NextTickSeconds) {
        Invoke-BridgeTick | Out-Null
        Write-BridgeLivenessStamp
        $Schedule.NextTickSeconds = $Clock.Elapsed.TotalSeconds + [Math]::Max(1, (Get-EffectivePollTimeout))
    }
}

function Wait-BridgeBackoff {
    <# The polling backoff. With the web channel closed this is the plain
       sleep it always was; open, the browser keeps working while Telegram is
       unreachable, and so does the tick. #>
    param([Parameter(Mandatory)][int]$Seconds)
    if (-not (Test-WebChannelActive)) { Start-Sleep -Seconds $Seconds; return }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $schedule = @{ NextTickSeconds = [double][Math]::Max(1, (Get-EffectivePollTimeout)) }
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) { Invoke-WebChannelPump -Clock $clock -Schedule $schedule }
}

function Invoke-TelegramPollWithPump {
    <# getUpdates on its own runspace while this thread keeps serving the web
       channel. The tick still runs right after the poll in the main loop;
       here it runs only if the poll overruns its own timeout - a slow network
       that would otherwise have frozen every engine on air with it. #>
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][int]$DeadlineSeconds, [Parameter(Mandatory)][int]$TimeoutSeconds)
    $poll = Start-BridgeTelegramPoll -Uri $Uri -TimeoutSec $DeadlineSeconds
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $schedule = @{ NextTickSeconds = [double]($TimeoutSeconds + 1) }
    $result = $null
    try {
        while (-not $poll.Handle.IsCompleted) { Invoke-WebChannelPump -Clock $clock -Schedule $schedule }
        $result = Receive-BridgeTelegramPoll -Poll $poll
        $poll = $null
    }
    finally { if ($poll) { Stop-BridgeTelegramPoll -Poll $poll } }
    if (-not $result.Ok) { throw [string]$result.Error }
    return $result.Response
}

# ------------------------------------------------------------------ sign-in

function Register-WebLoginRequest {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $code = [string](Get-JsonProp $Arguments 'code')
    if ($code -notmatch '^\d{6}$') { return @{ ok = $false; error = 'bad_code' } }
    if ($script:WebLoginRequests.ContainsKey($code)) { return @{ ok = $false; error = 'code_in_use' } }
    if ($script:WebLoginRequests.Count -ge $script:WebLoginMaxPending) { return @{ ok = $false; error = 'too_many' } }
    $script:WebLoginRequests[$code] = @{
        Code = $code
        Address = Format-AirStatusWidgetField -Text ([string](Get-JsonProp $Arguments 'address')) -MaximumLength 64
        Agent = Format-AirStatusWidgetField -Text ([string](Get-JsonProp $Arguments 'agent')) -MaximumLength 120
        ExpiresAt = (Get-Date).AddMinutes($script:WebLoginLifetimeMinutes)
        State = 'pending'
        RequestedBy = 0L
        UserId = 0L
    }
    return @{ ok = $true; data = @{ botUsername = $script:WebBotUsername; expiresInSeconds = $script:WebLoginLifetimeMinutes * 60 } }
}

function Get-WebLoginRequestState {
    <# An approved request is handed out once and then forgotten, so the same
       approval cannot open a second session. #>
    param([AllowEmptyString()][string]$Code)
    $request = $script:WebLoginRequests[$Code]
    if (-not $request -or $request.ExpiresAt -le (Get-Date)) {
        if ($request) { $script:WebLoginRequests.Remove($Code) }
        return @{ ok = $true; data = @{ state = 'expired' } }
    }
    if ($request.State -eq 'approved') {
        $script:WebLoginRequests.Remove($Code)
        return @{ ok = $true; data = @{ state = 'approved'; userId = [long]$request.UserId } }
    }
    if ($request.State -eq 'denied') { $script:WebLoginRequests.Remove($Code) }
    return @{ ok = $true; data = @{ state = [string]$request.State } }
}

function Update-WebLoginExpiry {
    $now = Get-Date
    foreach ($code in @($script:WebLoginRequests.Keys)) {
        if ($script:WebLoginRequests[$code].ExpiresAt -le $now) { $script:WebLoginRequests.Remove($code) }
    }
}

function Get-WebLoginCodeFromCommand {
    <# '/web 123456', or '/start web-123456' from the page's t.me link. #>
    param([AllowEmptyString()][string]$Command, [AllowEmptyString()][string]$ArgText)
    $argument = $ArgText.Trim()
    if ($Command -eq 'web' -and $argument -match '^\d{6}$') { return $argument }
    if ($Command -eq 'start' -and $argument -match '^web-(\d{6})$') { return $Matches[1] }
    return ''
}

function Request-WebLoginApproval {
    <# The operator typed the code in Telegram. Not approved yet: a link can
       be sent to someone else, so they confirm on a message that shows where
       the request came from. #>
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-WebChannelActive)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'web.disabled')
        return
    }
    $request = $script:WebLoginRequests[$Code]
    if (-not $request -or $request.State -ne 'pending' -or $request.ExpiresAt -le (Get-Date) -or
        ($request.RequestedBy -ne 0 -and $request.RequestedBy -ne $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'web.login.unknown')
        return
    }
    $request.RequestedBy = $UserId
    $text = T 'web.login.confirm' $Code (ConvertTo-TelegramHtmlText $request.Address) (ConvertTo-TelegramHtmlText $request.Agent)
    $buttons = @{ inline_keyboard = @(, @((New-Button (T 'web.login.approve') "web:ok:$Code" -Style success), (New-Button (T 'web.login.deny') "web:no:$Code" -Style danger))) }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML -ReplyMarkup $buttons
}

function Complete-WebLoginApproval {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][bool]$Approve,
        [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [int]$MessageId = 0)
    $request = $script:WebLoginRequests[$Code]
    $text = ''
    if (-not $request -or $request.State -ne 'pending' -or $request.ExpiresAt -le (Get-Date)) { $text = T 'web.login.expired' }
    elseif ($request.RequestedBy -ne $UserId) { $text = T 'web.login.notYours' }
    elseif ($Approve) {
        $request.State = 'approved'
        $request.UserId = $UserId
        Write-BridgeLog "Web sign-in approved for $(Format-UserAuditActor -UserId $UserId) from $($request.Address)" 'WARN'
        $text = T 'web.login.approved' $Code
    }
    else {
        $request.State = 'denied'
        Write-BridgeLog "Web sign-in denied by $(Format-UserAuditActor -UserId $UserId) for a request from $($request.Address)" 'WARN'
        $text = T 'web.login.denied' $Code
    }
    if ($MessageId -le 0 -or -not (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ParseMode HTML)) {
        Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML
    }
}

# ------------------------------------------------------------- web accounts

function Grant-WebOnlyAccount {
    <# A browser-only account becomes a bridge user like any other, so every
       permission check the bot makes applies to it unchanged. Appointing an
       administrator stays the owner's call, as it is in the bot. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    $target = [long](Get-JsonProp $Arguments 'userId')
    $role = [string](Get-JsonProp $Arguments 'role')
    $name = Format-AirStatusWidgetField -Text ([string](Get-JsonProp $Arguments 'name')) -MaximumLength 48
    if (-not (Test-WebOnlyUserId -UserId $target)) { return @{ ok = $false; error = 'not_web_only' } }
    if ($role -notin @('operator', 'admin') -or [string]::IsNullOrWhiteSpace($name)) { return @{ ok = $false; error = 'bad_request' } }
    if (-not (Test-Admin -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if ($role -eq 'admin' -and -not (Test-Owner -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'owner_only' } }
    $lists = @('AllowedUserIds')
    if ($role -eq 'admin') { $lists += 'AdminUserIds' }
    foreach ($listName in $lists) {
        $members = @(@(Get-JsonProp $config $listName) | Where-Object { [long]$_ -ne $target }) + $target
        $config | Add-Member -NotePropertyName $listName -NotePropertyValue $members -Force
    }
    Set-UserAlias -TargetUserId $target -Alias $name | Out-Null
    Save-Config
    Write-BridgeLog "Web-only account $(Format-UserAuditActor -UserId $target) granted $role by $(Format-UserAuditActor -UserId $actor)" 'WARN'
    Publish-WebChannelState -Force
    return @{ ok = $true }
}

function Revoke-WebOnlyAccount {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    $target = [long](Get-JsonProp $Arguments 'userId')
    if (-not (Test-WebOnlyUserId -UserId $target)) { return @{ ok = $false; error = 'not_web_only' } }
    if (-not (Test-Admin -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $result = Revoke-AuthorizedUser -TargetUserId $target
    if (-not $result.Success) { return @{ ok = $false; error = 'refused'; message = [string]$result.Error } }
    Set-UserAlias -TargetUserId $target -Alias '' | Out-Null
    Write-BridgeLog "Web-only account $target revoked by $(Format-UserAuditActor -UserId $actor)" 'WARN'
    Publish-WebChannelState -Force
    return @{ ok = $true }
}

# ------------------------------------------------------------- air operations

function Get-WebSceneItem {
    param([string]$Root, [string]$RelativePath, [switch]$IncludeHidden)

    # The configured root is trusted. Reject links at every descendant so a
    # junction cannot turn this picker into a browser for the rest of the host.
    $cursor = Get-Item -LiteralPath $Root -Force:$IncludeHidden -ErrorAction SilentlyContinue
    if (-not $cursor -or -not $cursor.PSIsContainer) { return }
    if (-not $RelativePath) { return $cursor }
    if ($RelativePath.Length -gt 1024) { return }
    foreach ($segment in $RelativePath.Split('/')) {
        if (-not $cursor.PSIsContainer -or -not $segment -or $segment -in '.', '..' -or
            $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
            $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return }
        $cursor = Get-Item -LiteralPath (Join-Path $cursor.FullName $segment) -Force:$IncludeHidden -ErrorAction SilentlyContinue
        if (-not $cursor -or ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
    }
    return $cursor
}

function Get-WebSceneFolder {
    param([string]$Root, [string]$Folder, [int]$Page, [string]$Search)
    $target = Get-WebSceneItem -Root $Root -RelativePath $folder
    if (-not $target -or -not $target.PSIsContainer) { return @{ ok = $false; error = 'scene_not_found' } }
    try {
        $children = @(Get-ChildItem -LiteralPath $target.FullName -ErrorAction Stop | Where-Object {
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and ($_.PSIsContainer -or $_.Extension -ieq '.cintitle') -and
                $_.Name.Contains($search, [StringComparison]::OrdinalIgnoreCase) -and
                [Environment]::ExpandEnvironmentVariables($_.FullName) -ceq $_.FullName
        } | Sort-Object -Property @{ Expression = { -not $_.PSIsContainer } }, Name)
    }
    catch { return @{ ok = $false; error = 'scene_not_found' } }
    $window = Get-BridgePageWindow -ItemCount $children.Count -Page $page -PageSize 24
    $prefix = if ($folder) { "$folder/" } else { '' }
    $entries = @(foreach ($child in @($children | Select-Object -Skip $window.StartIndex -First 24)) {
        @{ name = $child.Name; path = "$prefix$($child.Name)"; folder = $child.PSIsContainer }
    })
    return @{ ok = $true; data = @{ folder = $folder; entries = $entries; page = $window.Page; pageCount = $window.PageCount } }
}

function Get-WebSceneWorkerScript {
    # Copy the two filesystem readers, not the bridge or its session state.
    $itemReader = ${function:Get-WebSceneItem}.ToString()
    $folderReader = ${function:Get-WebSceneFolder}.ToString()
    $replacementReader = ${function:Get-WebSceneReplacementArtifact}.ToString()
    return @"
param(`$root, `$request, `$pagingModule)
function Get-WebSceneItem { $itemReader }
function Get-WebSceneFolder { $folderReader }
function Get-WebSceneReplacementArtifact { $replacementReader }
`$ErrorActionPreference = 'Stop'
if (`$request.Action -ceq 'browse') {
    Import-Module `$pagingModule
    return Get-WebSceneFolder -Root `$root -Folder `$request.RelativePath -Page `$request.Page -Search `$request.Search
}
if (`$request.Action -clike 'replace-*') {
    return Get-WebSceneReplacementArtifact -Root `$root -RelativePath `$request.RelativePath -SceneModule `$request.SceneModule
}
`$scene = Get-WebSceneItem -Root `$root -RelativePath `$request.RelativePath
if (`$scene -and -not `$scene.PSIsContainer -and `$scene.Extension -ieq '.cintitle' -and
    [Environment]::ExpandEnvironmentVariables(`$scene.FullName) -ceq `$scene.FullName) {
    return @{ FullName = `$scene.FullName; WriteTicks = `$scene.LastWriteTimeUtc.Ticks; Length = `$scene.Length }
}
return @{}
"@
}

function Test-WebSceneCatalogueAccess {
    param([long]$Actor)
    return ((Test-Authorized -ChatId $Actor -UserId $Actor) -and (Test-Admin -ChatId $Actor -UserId $Actor) -and
        (Get-Setting 'EnableFullTemplateManagement'))
}

function Get-WebSceneCatalogueRoot {
    return [Environment]::ExpandEnvironmentVariables([string](Get-Setting 'TemplateBasePath')).Trim()
}

function Start-WebSceneRequest {
    param([System.Collections.IDictionary]$Arguments, [hashtable]$Entry)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-WebSceneCatalogueAccess -Actor $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if ($script:WebSceneRequest) { return @{ ok = $false; error = 'bridge_busy' } }
    $root = Get-WebSceneCatalogueRoot
    if (-not [IO.Path]::IsPathFullyQualified($root)) { return @{ ok = $false; error = 'scene_folder_missing' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $invalid = @{ ok = $false; error = 'scene_definition_invalid' }
    if ($action -ceq 'browse') {
        $page = 0
        [int]::TryParse([string](Get-JsonProp $Arguments 'page'), [ref]$page) | Out-Null
        $search = ([string](Get-JsonProp $Arguments 'search')).Trim()
        if ($search.Length -gt 120) { return $invalid }
        $query = @{ Action = $action; RelativePath = [string](Get-JsonProp $Arguments 'folder'); Page = $page; Search = $search }
        return Start-WebSceneWorker -Entry $Entry -Root $root -Actor $actor -Query $query
    }
    if ($action -cnotin 'review', 'register') { return $invalid }

    $submitted = Get-JsonProp $Arguments 'definition'
    $key = ([string](Get-JsonProp $submitted 'key')).Trim()
    $file = [string](Get-JsonProp $submitted 'file')
    $description = ([string](Get-JsonProp $submitted 'description')).Trim()
    $category = ([string](Get-JsonProp $submitted 'category')).Trim()
    $fields = @(Get-JsonProp $submitted 'fields' | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() })
    $layer = 0
    if ($key -notmatch '^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$' -or $description.Length -gt 120 -or $category.Length -gt 60 -or
        -not [int]::TryParse([string](Get-JsonProp $submitted 'layer'), [ref]$layer) -or $layer -le 0 -or
        $fields.Count -gt 40 -or @($fields | Where-Object { -not $_ -or $_.Length -gt 100 }).Count -gt 0 -or
        @($fields | Sort-Object -Unique).Count -ne $fields.Count) { return $invalid }

    $query = @{ Action = $action; RelativePath = $file; Key = $key; Layer = $layer; Description = $description
        Category = $category; Fields = $fields; Review = [string](Get-JsonProp $Arguments 'review') }
    return Start-WebSceneWorker -Entry $Entry -Root $root -Actor $actor -Query $query
}

function Start-WebSceneWorker {
    param([hashtable]$Entry, [string]$Root, [long]$Actor, [hashtable]$Query)
    $pipeline = [powershell]::Create()
    try {
        $pagingModule = Join-Path $moduleRoot 'BridgeUiPaging.psm1'
        [void]$pipeline.AddScript((Get-WebSceneWorkerScript)).AddArgument($Root).AddArgument($Query).AddArgument($pagingModule)
        $invocation = $pipeline.BeginInvoke()
        $script:WebSceneRequest = @{ Pipeline = $pipeline; Invocation = $invocation; Entry = $Entry; Query = $Query
            Root = $Root; Actor = $Actor; Reported = $false }
    }
    catch {
        $pipeline.Dispose()
        return @{ ok = $false; error = 'scene_not_found' }
    }
}

function Stop-WebSceneRequest {
    param([string]$Code)
    $pending = $script:WebSceneRequest
    if (-not $pending -or $pending.Reported) { return }
    $pending.Reported = $true
    [void]$pending.Entry.Reply.TrySetResult((@{ ok = $false; error = $Code } | ConvertTo-Json -Compress))
    # Dispose only after the I/O really ends. Stopping an SMB call may itself
    # wait, and an expired request must not open a second worker behind it.
    try { [void]$pending.Pipeline.BeginStop($null, $null) }
    catch { Write-BridgeLog 'Could not cancel the scene directory read.' 'DEBUG' }
}

function Update-WebSceneRequest {
    $pending = $script:WebSceneRequest
    if (-not $pending) { return }
    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $pending.Entry.Deadline) {
        Stop-WebSceneRequest -Code 'bridge_busy'
    }
    if (-not $pending.Invocation.IsCompleted) { return }
    $script:WebSceneRequest = $null
    try {
        if ($pending.Reported) { return }
        $result = @($pending.Pipeline.EndInvoke($pending.Invocation) | Select-Object -First 1)
        $reply = if (-not (Test-WebSceneCatalogueAccess -Actor $pending.Actor)) { @{ ok = $false; error = 'forbidden' } }
        elseif ((Get-WebSceneCatalogueRoot) -cne $pending.Root) { @{ ok = $false; error = 'scene_registry_stale' } }
        elseif (-not $result.Count) { @{ ok = $false; error = 'scene_not_found' } }
        elseif ($pending.Query.Action -ceq 'browse') { $result[0] }
        elseif ($pending.Query.Action -clike 'replace-*') {
            Complete-WebTemplateSceneReplacement -Pending $pending -Scene $result[0]
        }
        else { Complete-WebTemplateRegistration -Pending $pending -Scene $result[0] }
    }
    catch { $reply = @{ ok = $false; error = 'scene_not_found' } }
    finally { $pending.Pipeline.Dispose() }
    [void]$pending.Entry.Reply.TrySetResult(($reply | ConvertTo-Json -Depth 6 -Compress))
}

function Complete-WebTemplateRegistration {
    param([hashtable]$Pending, [hashtable]$Scene)
    $query = $Pending.Query
    $actor = $Pending.Actor
    $key = $query.Key
    $layer = $query.Layer
    $stale = @{ ok = $false; error = 'scene_registry_stale' }
    if (-not (Get-JsonProp $Scene 'FullName')) {
        if ($query.Action -ceq 'register') { return $stale }
        return @{ ok = $false; error = 'scene_not_found' }
    }
    $store = Get-TemplateStore
    if ($store.Map.ContainsKey($key) -or $key -in @(Get-JsonProp $store 'InvalidKeys')) {
        if ($query.Action -ceq 'register') { return $stale }
        return @{ ok = $false; error = 'scene_key_taken' }
    }
    $shared = @($store.Map.Values | Where-Object { $_.Layer -eq $layer } | ForEach-Object { $_.Key } | Sort-Object)
    $fingerprint = ConvertTo-Json -InputObject @($key, $scene.FullName, $scene.WriteTicks, $scene.Length,
        $layer, $query.Description, $query.Category, $query.Fields, $shared) -Depth 5 -Compress
    if ($query.Action -ceq 'review') {
        $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebTemplateCatalogueReviews
        return @{ ok = $true; data = @{ preview = @{
            review = $token; key = $key; file = $query.RelativePath; layer = $layer; description = $query.Description
            category = $query.Category; fields = $query.Fields; sharedTemplates = $shared
        } } }
    }
    $review = Use-WebAirReview -Actor $actor -Token $query.Review -Reviews $script:WebTemplateCatalogueReviews
    if (-not $review -or $review.Fingerprint -cne $fingerprint) { return $stale }
    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $Pending.Entry.Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $written = Save-TemplateDefinitionChange -TemplateKey $key -Action create -Definition @{
        path = $scene.FullName; layer = $layer; description = $query.Description; category = $query.Category; fields = $query.Fields
    }
    if (-not $written.Success) { return @{ ok = $false; error = 'scene_registry_failed' } }
    Add-AuditEntry (T 'atpl.savedAudit' 'create' $key (Format-UserAuditActor -UserId $actor))
    return @{ ok = $true; data = @{} }
}

function Get-WebTemplateDefinitionView {
    param([string]$Key, $Entry, [string]$Revision)
    $fields = @(foreach ($field in @(Get-JsonProp $Entry 'fields' | Where-Object { $null -ne $_ })) {
        $name = if ($field -is [string]) { $field } else { [string](Get-JsonProp $field 'name') }
        $limit = 0
        [int]::TryParse([string](Get-JsonProp $field 'maxLength'), [ref]$limit) | Out-Null
        @{
            name = $name; label = [string](Get-JsonProp $field 'label'); type = [string](Get-JsonProp $field 'type')
            required = (Get-JsonProp $field 'required') -eq $true; sensitive = (Get-JsonProp $field 'sensitive') -eq $true
            maxLength = $limit
        }
    })
    $layer = 0
    [int]::TryParse([string](Get-JsonProp $Entry 'layer'), [ref]$layer) | Out-Null
    return @{
        key = $Key; revision = $Revision; file = [IO.Path]::GetFileName([string](Get-JsonProp $Entry 'path'))
        layer = $layer; device = [string](Get-JsonProp $Entry 'device')
        description = [string](Get-JsonProp $Entry 'description'); category = [string](Get-JsonProp $Entry 'category')
        presetCount = @(Get-JsonProp $Entry 'presets' | Where-Object { $null -ne $_ }).Count; fields = $fields
        reminderMinutes = [int](ConvertTo-TemplateReminderMinutes -Value (Get-JsonProp $Entry 'reminderMinutes'))
    }
}

function ConvertTo-WebTemplateDefinitionChanges {
    param($Requested, $Current, $Existing)
    $invalid = @{ error = 'scene_definition_invalid' }
    if ($Requested -isnot [System.Collections.IDictionary]) { return $invalid }
    $description = ([string](Get-JsonProp $Requested 'description')).Trim()
    $category = ([string](Get-JsonProp $Requested 'category')).Trim()
    $layer = 0
    if ($description.Length -gt [math]::Max(120, $Current.description.Length) -or
        $category.Length -gt [math]::Max(60, $Current.category.Length) -or
        -not [int]::TryParse([string](Get-JsonProp $Requested 'layer'), [ref]$layer) -or
        ($layer -ne $Current.layer -and ($layer -le 0 -or $Current.device))) { return $invalid }

    $reminder = Get-JsonProp $Requested 'reminderMinutes'
    if ($null -ne $reminder) {
        if ($reminder -isnot [int] -and $reminder -isnot [long]) { return @{ error = 'scene_definition_reminder_range' } }
        $reminder = ConvertTo-TemplateReminderMinutes -Value $reminder
        if ($null -eq $reminder) { return @{ error = 'scene_definition_reminder_range' } }
    }
    $fields = @(Get-JsonProp $Requested 'fields' | Where-Object { $null -ne $_ })
    if ($fields.Count -gt [math]::Max(40, $Current.fields.Count)) { return $invalid }
    $names = @($fields | ForEach-Object { ([string](Get-JsonProp $_ 'name')).Trim() })
    if (@($names | Sort-Object -Unique).Count -ne $names.Count) { return $invalid }
    if ($Current.presetCount -gt 0 -and ($names -join "`n") -cne (@($Current.fields | ForEach-Object { $_.name }) -join "`n")) {
        return @{ error = 'scene_definition_preset_fields' }
    }

    $oldByName = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($field in @(Get-JsonProp $Existing 'fields' | Where-Object { $null -ne $_ })) {
        $oldName = if ($field -is [string]) { $field } else { [string](Get-JsonProp $field 'name') }
        if ($oldName) { $oldByName[$oldName] = $field }
    }
    $updatedFields = @(for ($index = 0; $index -lt $fields.Count; $index++) {
        $field = $fields[$index]
        $name = $names[$index]
        $label = ([string](Get-JsonProp $field 'label')).Trim()
        $limit = 0
        $rawLimit = Get-JsonProp $field 'maxLength'
        if (-not $name -or $name -match '[\r\n]' -or ($name.Length -gt 100 -and -not $oldByName.ContainsKey($name)) -or
            $label.Length -gt 120 -or ($null -ne $rawLimit -and -not [int]::TryParse([string]$rawLimit, [ref]$limit)) -or $limit -lt 0) { return $invalid }
        # Keep field types and any other properties supplied by the registry.
        $updated = [ordered]@{ name = $name }
        if ($oldByName.ContainsKey($name) -and $oldByName[$name] -isnot [string]) {
            foreach ($property in $oldByName[$name].PSObject.Properties) { $updated[$property.Name] = $property.Value }
        }
        $updated['label'] = $label
        $updated['maxLength'] = $limit
        $updated['required'] = (Get-JsonProp $field 'required') -eq $true
        $updated['sensitive'] = (Get-JsonProp $field 'sensitive') -eq $true
        $updated
    })
    $changes = @{ description = $description; category = $category; fields = $updatedFields }
    if ($layer -ne $Current.layer) { $changes.layer = $layer }
    $view = @{
        path = Get-JsonProp $Existing 'path'; device = $Current.device; layer = $layer
        description = $description; category = $category; fields = $updatedFields; presets = Get-JsonProp $Existing 'presets'
        reminderMinutes = $Current.reminderMinutes
    }
    if ($null -ne $reminder) {
        $changes.reminderMinutes = $reminder
        $view.reminderMinutes = $reminder
        # The editor roundtrips projected values. Preserve legacy encodings
        # when a reminder edit leaves those other controls alone.
        foreach ($name in 'description', 'category') {
            if ([string]::Equals([string](Get-JsonProp $Requested $name), $Current[$name], [StringComparison]::Ordinal)) {
                $changes.Remove($name)
                $view[$name] = $Current[$name]
            }
        }
        $projected = Get-WebTemplateDefinitionView -Key $Current.key -Entry $view -Revision $Current.revision
        if ([string]::Equals((ConvertTo-Json -InputObject $projected.fields -Compress),
                (ConvertTo-Json -InputObject $Current.fields -Compress), [StringComparison]::Ordinal)) {
            $changes.Remove('fields')
            $view.fields = Get-JsonProp $Existing 'fields'
        }
    }
    return @{ changes = $changes; after = (Get-WebTemplateDefinitionView -Key $Current.key -Entry $view -Revision $Current.revision) }
}

function Invoke-WebTemplateDefinition {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-WebSceneCatalogueAccess -Actor $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $key = [string](Get-JsonProp $Arguments 'key')
    $action = [string](Get-JsonProp $Arguments 'action')
    if (-not $key -or $action -cnotin 'inspect', 'review-edit', 'edit', 'review-delete', 'delete') {
        return @{ ok = $false; error = 'scene_definition_invalid' }
    }
    try {
        $raw = Get-Content -LiteralPath (Get-TemplateRegistryFilePath) -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $item = Get-JsonProp $raw $key
    }
    catch { return @{ ok = $false; error = 'scene_registry_failed' } }
    if (-not $item) { return @{ ok = $false; error = 'scene_not_found' } }
    $revision = Get-TemplatePresetRevision -TemplateKey $key -Entry $item
    $definition = Get-WebTemplateDefinitionView -Key $key -Entry $item -Revision $revision
    if ($action -ceq 'inspect') { return @{ ok = $true; data = @{ definition = $definition } } }
    $stale = @{ ok = $false; error = 'scene_registry_stale' }
    if ([string](Get-JsonProp $Arguments 'revision') -cne $revision) { return $stale }
    $mode = if ($action -clike '*delete') { 'delete' } else { 'edit' }
    $blocker = Get-TemplateDefinitionBlocker -TemplateKey $key -Delete:($mode -eq 'delete')
    if ($blocker) { return @{ ok = $false; error = $blocker } }
    $changes = @{}
    $after = $null
    if ($mode -eq 'edit') {
        $submission = ConvertTo-WebTemplateDefinitionChanges -Requested (Get-JsonProp $Arguments 'changes') -Current $definition -Existing $item
        $errorCode = [string](Get-JsonProp $submission 'error')
        if ($errorCode) { return @{ ok = $false; error = $errorCode } }
        $changes = $submission.changes
        $after = $submission.after
        if ($changes.ContainsKey('layer')) {
            $blocker = Get-TemplateDefinitionBlocker -TemplateKey $key -CheckSchedules
            if ($blocker) { return @{ ok = $false; error = $blocker } }
        }
    }
    $fingerprint = ConvertTo-Json -InputObject @($key, $revision, $mode, $after, $changes.ContainsKey('reminderMinutes')) -Depth 8 -Compress
    if ($action -clike 'review-*') {
        $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebTemplateManagementReviews
        return @{ ok = $true; data = @{ preview = @{ review = $token; before = $definition; after = $after } } }
    }
    $approved = Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTemplateManagementReviews
    if (-not $approved -or $approved.Fingerprint -cne $fingerprint) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $saved = Save-TemplateDefinitionChange -TemplateKey $key -Action $mode -Definition $changes -ExpectedRevision $revision -Deadline $Deadline
    if (-not $saved.Success) {
        $code = [string](Get-JsonProp $saved 'Code')
        return @{ ok = $false; error = ($code ? $code : 'scene_registry_failed') }
    }
    Add-AuditEntry (T 'atpl.savedAudit' $mode $key (Format-UserAuditActor -UserId $actor))
    return @{ ok = $true; data = @{} }
}

function Get-WebTemplateFields {
    param([Parameter(Mandatory)][hashtable]$Template)
    # The registry parser has already resolved each field's label and template limit.
    for ($index = 0; $index -lt $Template.Fields.Count; $index++) {
        $name = $Template.Fields[$index]
        $label = $Template.FieldLabels[$index]
        $limit = Get-EffectiveFieldLimit -FieldLimit $Template.FieldLimits[$index]
        [ordered]@{
            name = $name
            label = $label ? $label : $name
            required = $Template.FieldRequired[$index]
            maxLength = ($limit -gt 0) ? $limit : $null
            sensitive = Test-TemplateFieldSensitive -Template $Template -Index $index -Name $name
        }
    }
}

function Get-WebTemplates {
    $store = Get-TemplateStore
    if (-not $store -or -not $store.Map) { return @{ ok = $true; data = @() } }

    $disabledKeys = @(Get-BridgeKeyList -Value (Get-Setting 'DisabledTemplateKeys'))
    $templates = [System.Collections.Generic.List[object]]::new()

    foreach ($key in $store.Order) {
        $item = $store.Map[$key]

        $templates.Add([ordered]@{
            key = [string]$key
            name = $item.Description ? $item.Description : $key
            layer = $item.Layer
            category = $item.Category
            disabled = ($key -in $disabledKeys)
            fields = @(Get-WebTemplateFields -Template $item)
        })
    }

    return @{ ok = $true; data = $templates.ToArray() }
}

function Get-WebPresetTemplateAccess {
    param([long]$Actor, [string]$Key)
    if (-not (Test-Authorized -ChatId $Actor -UserId $Actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not $Key) { return @{ ok = $false; error = 'not_found' } }
    $template = (Get-TemplateStore).Map[$Key]
    if (-not $template) { return @{ ok = $false; error = 'not_found' } }
    if (-not (Test-TemplateAccess -Key $template.Key -Layer ([int]$template.Layer) -ChatId $Actor -UserId $Actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    return @{ ok = $true; template = $template }
}

function Get-WebPresetPage {
    param($Template, [int]$Page, [bool]$CanManage)
    $fields = @(Get-WebTemplateFields -Template $Template)
    $presets = @(Get-JsonProp $Template 'Presets')
    $window = Get-BridgePageWindow -ItemCount $presets.Count -Page $Page
    $items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $preset = $presets[$index]
            $values = Get-TemplatePresetValues -Template $Template -Preset $preset
            $hiddenFields = @(foreach ($field in $fields) {
                    if ($field.sensitive -and $values.ContainsKey($field.name)) {
                        $values.Remove($field.name)
                        $field.name
                    }
                })
            @{ index = $index; name = Get-NewsScreenLine ([string]$preset.Name) 80; values = $values; hiddenFields = $hiddenFields }
        })
    return @{
        items = $items; fields = $fields; page = $window.Page; pageCount = $window.PageCount
        lastValues = Get-WebLastTemplateText -Template $Template -Fields $fields
        revision = [string](Get-JsonProp $Template 'PresetRevision'); canManage = $CanManage
    }
}

function Get-WebTemplatePresets {
    param([System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    $access = Get-WebPresetTemplateAccess -Actor $actor -Key ([string](Get-JsonProp $Arguments 'key'))
    if (-not $access.ok) { return $access }
    $canManage = Test-Admin -ChatId $actor -UserId $actor
    return @{ ok = $true; data = Get-WebPresetPage -Template $access.template -Page ([int](Get-JsonProp $Arguments 'page')) -CanManage $canManage }
}

function Invoke-WebTemplatePresetChange {
    param([System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    $access = Get-WebPresetTemplateAccess -Actor $actor -Key ([string](Get-JsonProp $Arguments 'key'))
    if (-not $access.ok) { return $access }
    if (-not (Test-Admin -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $template = $access.template
    $revision = [string](Get-JsonProp $Arguments 'revision')
    if (-not $revision -or $revision -cne [string](Get-JsonProp $template 'PresetRevision')) {
        return @{ ok = $false; error = 'preset_stale' }
    }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin @('create', 'edit', 'rename', 'delete')) { return @{ ok = $false; error = 'preset_invalid' } }
    $index = if ($action -eq 'create') { -1 } else { Get-JsonProp $Arguments 'index' }
    $preset = if (($index -is [int] -or $index -is [long]) -and $index -ge 0 -and $index -le [int]::MaxValue) {
        Get-TemplatePreset -Template $template -Index $index
    }
    if ($action -ne 'create' -and -not $preset) { return @{ ok = $false; error = 'preset_stale' } }
    $name = ([string](Get-JsonProp $Arguments 'name')).Trim()
    if ($action -in @('create', 'rename')) {
        if (-not $name -or $name.Length -gt 80 -or $name -match '[\p{Cc}]') { return @{ ok = $false; error = 'preset_invalid_name' } }
        for ($position = 0; $position -lt $template.Presets.Count; $position++) {
            if (($action -eq 'create' -or $position -ne $index) -and [string]$template.Presets[$position].Name -eq $name) {
                return @{ ok = $false; error = 'preset_duplicate' }
            }
        }
    }
    $values = @()
    if ($action -in @('create', 'edit')) {
        $entered = Get-JsonProp $Arguments 'values'
        if ($entered -isnot [System.Collections.IDictionary]) { return @{ ok = $false; error = 'preset_invalid' } }
        $fields = @(Get-WebTemplateFields -Template $template)
        foreach ($key in $entered.Keys) {
            if ($key -cnotin $template.Fields -or $entered[$key] -isnot [string]) { return @{ ok = $false; error = 'preset_invalid' } }
            $field = $fields | Where-Object { $_.name -ceq $key } | Select-Object -First 1
            try { [void][System.Xml.XmlConvert]::VerifyXmlChars([string]$entered[$key]) } catch { return @{ ok = $false; error = 'preset_invalid' } }
            if ($field.maxLength -and (Get-TextElementCount -Text $entered[$key]) -gt $field.maxLength) {
                return @{ ok = $false; error = 'preset_too_long' }
            }
        }
        $previous = @(Get-JsonProp $preset 'Values')
        $length = [Math]::Max($fields.Count, $previous.Count)
        $values = @(for ($position = 0; $position -lt $length; $position++) {
                if ($position -lt $fields.Count -and $entered.Contains($fields[$position].name)) {
                    $entered[$fields[$position].name]
                }
                elseif ($position -lt $previous.Count) { [string]$previous[$position] }
                else { '' }
            })
    }
    $result = Save-TemplatePresetChange -TemplateKey $template.Key -Action $action -ExpectedRevision $revision -PresetIndex ([int]$index) -Name $name -Values $values
    if (Get-JsonProp $result 'Stale') { return @{ ok = $false; error = 'preset_stale' } }
    if (-not $result.Success) { return @{ ok = $false; error = 'preset_save_failed' } }
    Add-AuditEntry "Web template preset $action / $($template.Key) - $(Format-UserAuditActor -UserId $actor)"
    $updated = (Get-TemplateStore).Map[$template.Key]
    return @{ ok = $true; data = Get-WebPresetPage -Template $updated -Page ([int](Get-JsonProp $Arguments 'page')) -CanManage $true }
}

function Invoke-WebAirShow {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    $key = [string](Get-JsonProp $Arguments 'key')
    $rawVars = Get-JsonProp $Arguments 'variables'
    $autoHide = [int](Get-JsonProp $Arguments 'autoHideSeconds')

    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($key)) {
        return @{ ok = $false; error = 'refused'; data = (T 'air.templateUnknown' (ConvertTo-TelegramHtmlText -Text $key)) }
    }
    if ($autoHide -lt 0 -or $autoHide -gt 86400) {
        return @{ ok = $false; error = 'bad_duration' }
    }

    $template = $store.Map[$key]
    $variables = @{}
    $hiddenPresetFields = @()
    $presetIndex = Get-JsonProp $Arguments 'presetIndex'
    if ($null -ne $presetIndex) {
        $access = Get-WebPresetTemplateAccess -Actor $actor -Key $key
        if (-not $access.ok) { return $access }
        $template = $access.template
        $revision = [string](Get-JsonProp $Arguments 'presetRevision')
        $preset = if (($presetIndex -is [int] -or $presetIndex -is [long]) -and $presetIndex -ge 0 -and $presetIndex -le [int]::MaxValue) {
            Get-TemplatePreset -Template $template -Index $presetIndex
        }
        if (-not $preset -or -not $revision -or $revision -cne [string](Get-JsonProp $template 'PresetRevision') -or
            $revision -cne (Get-TemplatePresetRegistryRevision -TemplateKey $template.Key)) {
            return @{ ok = $false; error = 'preset_stale' }
        }
        $variables = Get-TemplatePresetValues -Template $template -Preset $preset
        $hiddenPresetFields = @(Get-WebTemplateFields -Template $template | Where-Object { $_.sensitive -and $variables.ContainsKey($_.name) } |
                ForEach-Object { $_.name })
    }
    if ($rawVars -is [System.Collections.IDictionary]) {
        foreach ($k in $rawVars.Keys) {
            if ($k -notin $template.Fields) { return @{ ok = $false; error = 'refused' } }
            $variables[[string]$k] = [string]$rawVars[$k]
        }
    }
    foreach ($field in Get-WebTemplateFields -Template $template) {
        $value = [string]$variables[$field.name]
        if ($field.required -and [string]::IsNullOrWhiteSpace($value)) {
            return @{ ok = $false; error = 'refused'; data = (T 'flow.fieldRequiredNoEmpty') }
        }
        $length = Get-TextElementCount -Text $value
        if ($field.maxLength -and $length -gt $field.maxLength) {
            if ($field.name -in $hiddenPresetFields) { return @{ ok = $false; error = 'preset_invalid' } }
            return @{ ok = $false; error = 'refused'; data = (T 'flow.textTooLong' $length $field.maxLength) }
        }
    }

    $result = Invoke-ShowTemplateResult -Key $key -Variables $variables -ChatId $actor -UserId $actor -AutoHideSeconds $autoHide
    if (-not (Get-JsonProp $result 'Success')) {
        return @{ ok = $false; error = 'refused'; data = [string](Get-JsonProp $result 'Error') }
    }

    Publish-WebChannelState -Force
    return @{ ok = $true }
}

function Invoke-WebAirHide {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    $layer = [int](Get-JsonProp $Arguments 'layer')

    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    if (Get-Setting 'ConfirmLayerRemoval') { return @{ ok = $false; error = 'layer_review_required' } }

    $success = Invoke-HideLayer -Layer $layer -ChatId $actor -UserId $actor -Quiet -CaptureRollback
    if (-not $success) {
        return @{ ok = $false; error = 'refused' }
    }

    Publish-WebChannelState -Force
    return @{ ok = $true }
}

function Invoke-WebAirExit {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    $layer = [int](Get-JsonProp $Arguments 'layer')

    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    if (Get-Setting 'ConfirmLayerRemoval') { return @{ ok = $false; error = 'layer_review_required' } }

    $success = Invoke-ExitLayer -Layer $layer -ChatId $actor -UserId $actor
    if (-not $success) {
        return @{ ok = $false; error = 'refused' }
    }

    Publish-WebChannelState -Force
    return @{ ok = $true }
}

function Test-WebEditorialSearch {
    param([string[]]$Values, [string]$Search)
    if (-not $Search) { return $true }
    $compare = [Globalization.CultureInfo]::GetCultureInfo('ar').CompareInfo
    $comparison = [Globalization.CompareOptions]::IgnoreCase -bor [Globalization.CompareOptions]::IgnoreNonSpace
    foreach ($value in $Values) {
        if ($null -ne $value -and $compare.IndexOf($value.Replace('ـ', ''), $Search, $comparison) -ge 0) { return $true }
    }
    return $false
}

function Get-WebContentPage {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $view = [string](Get-JsonProp $Arguments 'view')
    $entries = @()
    $selected = @()
    $currentUrgentId = ''
    $revision = $null
    $fields = @()
    switch ($view) {
        'urgent' {
            if (-not (Test-UrgentBoardAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
            $entries = @(Get-UrgentProperty $script:UrgentBoard 'Items' @())
            $selected = @(Get-UrgentSelectedIds -ChatId $actor)
            $currentUrgentId = Get-UrgentCurrentItemId -ReadOnly
            $revision = [int](Get-JsonProp $script:UrgentBoard 'Revision')
            $fields = @(Get-WebUrgentFields)
        }
        'bulletins' {
            if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
            $entries = @(Get-JsonProp $script:MojazLibrary 'Bulletins' | Where-Object { $null -ne $_ })
        }
        'ticker' {
            if (-not (Get-Setting 'EnableNewsTickerManagement')) { return @{ ok = $false; error = 'content_disabled' } }
            $snapshot = Get-NewsTickerConfiguredSnapshot
            if (-not $snapshot.Success) { return @{ ok = $false; error = 'content_unreadable' } }
            $entries = @($snapshot.Items)
        }
        default { return @{ ok = $false; error = 'bad_view' } }
    }

    $search = ([string](Get-JsonProp $Arguments 'search')).Trim().Replace('ـ', '')
    $order = [string](Get-JsonProp $Arguments 'order')
    if ($search.Length -gt 120 -or ($order -and $order -notin 'sequence', 'title-asc', 'title-desc')) {
        return @{ ok = $false; error = 'bad_view' }
    }
    $filteredEntries = @(for ($sourceIndex = 0; $sourceIndex -lt $entries.Count; $sourceIndex++) {
            $source = $entries[$sourceIndex]
            $title = switch ($view) {
                'urgent' { [string](Get-JsonProp $source 'Text') }
                'bulletins' { [string](Get-JsonProp $source 'Name') }
                'ticker' { [string]$source }
            }
            $searchValues = @($title)
            if ($search -and $view -eq 'urgent') { $searchValues += @( (Get-UrgentItemVariables -Item $source).Values ) }
            if (Test-WebEditorialSearch -Values $searchValues -Search $search) {
                @{ Entry = $source; Title = $title; Position = $sourceIndex + 1 }
            }
        })
    if ($order -in 'title-asc', 'title-desc') {
        $filteredEntries = @($filteredEntries | Sort-Object -Property Title -Stable -Culture ar -Descending:($order -eq 'title-desc'))
    }
    $window = Get-BridgePageWindow -ItemCount $filteredEntries.Count -Page ([int](Get-JsonProp $Arguments 'page'))
    $items = @(
        for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $match = $filteredEntries[$index]
            $entry = $match.Entry
            switch ($view) {
                'urgent' {
                    $id = [string](Get-JsonProp $entry 'Id')
                    $state = if ($id -and $id -ceq $currentUrgentId) { 'on_air' }
                    elseif (-not (Get-UrgentProperty $entry 'Enabled' $true)) { 'disabled' }
                    elseif ($selected -contains $id) { 'selected' }
                    else { 'ready' }
                    @{
                        id = $id
                        title = [string](Get-JsonProp $entry 'Text')
                        position = $match.Position
                        enabled = [bool](Get-UrgentProperty $entry 'Enabled' $true)
                        state = $state
                        values = Get-UrgentItemVariables -Item $entry
                        timing = @{
                            intervalSeconds = [int](Get-UrgentProperty $entry 'IntervalSeconds' 0)
                            repeats = [int](Get-UrgentProperty $entry 'Repeats' 0)
                            mode = [string](Get-UrgentProperty $entry 'Mode' '')
                        }
                    }
                }
                'bulletins' {
                    $state = if (Test-MojazOnAir -Bulletin $entry) { 'on_air' } else { 'saved' }
                    $rows = @(Get-JsonProp $entry 'Rows' | Where-Object { $null -ne $_ }).Count
                    @{ id = [string](Get-JsonProp $entry 'Id'); title = Get-NewsScreenLine -Text $match.Title -Length 120
                        position = $match.Position; state = $state; rows = $rows }
                }
                'ticker' { @{ title = Get-NewsScreenLine -Text $match.Title -Length 240; position = $match.Position; state = 'published' } }
            }
        }
    )
    return @{ ok = $true; data = @{
        items = $items; page = $window.Page; pageCount = $window.PageCount; total = $filteredEntries.Count; collectionTotal = $entries.Count
        revision = $revision; fields = $fields
    } }
}

function Get-WebBulletinFields {
    param([Parameter(Mandatory)]$Bulletin)
    $key = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    $prompts = @(Get-MojazRowFieldPrompts -TemplateKey $key)
    if ($key -eq $script:MojazTemplateKey -and -not $prompts.Count) {
        # The bot's built-in bulletin always sends these three variables.
        # Its saved rows remain editable even when the scene is unreadable.
        foreach ($field in @(
                @{ name = $script:MojazTitleVariable; labelKey = 'mojaz.col.title'; kind = 'text' }
                @{ name = $script:MojazTextVariable; labelKey = 'mojaz.col.story'; kind = 'text' }
                @{ name = $script:MojazImageVariable; labelKey = 'mojaz.col.image'; kind = 'media' }
            )) {
            $label = Get-MojazFieldLabel -TemplateKey $key -FieldName $field.name
            if ($label -eq $field.name) { $label = T $field.labelKey }
            @{ name = $field.name; label = $label; kind = $field.kind }
        }
        return
    }
    foreach ($prompt in $prompts) {
        $label = [string]$prompt.Label
        $kind = [string]$prompt.Kind
        if ($prompt.Name -eq $script:MojazImageVariable -and $kind -eq 'media') {
            if ($label -eq $prompt.Name) { $label = T 'mojaz.col.image' }
        }
        @{ name = [string]$prompt.Name; label = $label; kind = $kind }
    }
}

function Get-WebBulletinImageField {
    param([object[]]$Fields)
    foreach ($field in $Fields) {
        if ($field.kind -eq 'media' -and $field.name -eq $script:MojazImageVariable) { return $field.name }
    }
}

function Get-WebBulletinRowView {
    param($Row, [object[]]$Fields, [string]$ImageField, [switch]$BuiltIn)
    $values = @{}
    $playoutValues = if ($BuiltIn) { Get-MojazRowVariables -Row $Row }
    $media = @(
        foreach ($field in $Fields) {
            $value = if ($BuiltIn -and $field.name -in $script:MojazTitleVariable, $script:MojazTextVariable, $script:MojazImageVariable) {
                $playoutValues[$field.name]
            }
            else { Get-MojazRowFieldValue -Row $Row -FieldName $field.name -Kind $field.kind }
            if ($field.kind -eq 'text') { $values[$field.name] = $value }
            elseif ($value) { $field.name }
        }
    )
    return @{ id = [string](Get-JsonProp $Row 'Id'); values = $values; media = $media; skipped = Test-MojazRowSkipped -Row $Row
        imageMode = $(if ($ImageField) { Get-MojazRowImageMode -Row $Row }) }
}

function Get-WebBulletinEditor {
    param([Parameter(Mandatory)]$Bulletin, [int]$Page)
    $fields = @(Get-WebBulletinFields -Bulletin $Bulletin)
    $designKey = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    $builtIn = $designKey -eq $script:MojazTemplateKey
    $rows = @(Get-JsonProp $Bulletin 'Rows' | Where-Object { $null -ne $_ })
    $imageField = Get-WebBulletinImageField -Fields $fields
    $imageChoices = @(
        if ($imageField) {
            $seenImages = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            for ($index = 0; $index -lt $rows.Count -and $seenImages.Count -lt 8; $index++) {
                $sourceImage = [string](Get-JsonProp $rows[$index] 'Image')
                if ($sourceImage -and $seenImages.Add($sourceImage)) {
                    @{ rowId = [string](Get-JsonProp $rows[$index] 'Id'); rowNumber = $index + 1 }
                }
            }
        }
    )
    $window = Get-BridgePageWindow -ItemCount $rows.Count -Page $Page
    $items = @(
        for ($position = $window.StartIndex; $position -le $window.EndIndex; $position++) {
            Get-WebBulletinRowView -Row $rows[$position] -Fields $fields -ImageField $imageField -BuiltIn:$builtIn
        }
    )
    $canPlay = Test-MojazBulletinPlaybackDesign -Bulletin $Bulletin
    $photoFields = @(foreach ($field in $fields) {
            if ($field.kind -eq 'media' -and (Get-WebBulletinPhotoDestination -Bulletin $Bulletin -Field $field.name)) { $field.name }
        })
    return @{
        id = [string](Get-JsonProp $Bulletin 'Id'); name = [string](Get-JsonProp $Bulletin 'Name')
        design = $designKey; playbackSupported = $canPlay
        headlinePaste = Test-WebBulletinHeadlineFormat -Fields $fields
        timing = $(if ($canPlay -or (Get-MojazBulletinSceneTiming -Bulletin $Bulletin)) { Get-WebBulletinTiming -Bulletin $Bulletin })
        revision = [int](Get-JsonProp $Bulletin 'Revision'); onAir = Test-MojazOnAir -Bulletin $Bulletin
        fields = $fields; rows = $items; page = $window.Page; pageCount = $window.PageCount; total = $rows.Count
        imageField = $imageField; imageChoices = $imageChoices
        canUploadPhoto = [bool]($imageField -and $imageField -cin $photoFields); photoFields = $photoFields
    }
}

function Resolve-WebBulletinPreviewImage {
    param([string]$SceneRoot, [string]$Reference)
    if (-not $SceneRoot -or -not $Reference) { return }
    try {
        $path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Reference.Trim()), $SceneRoot)
        $relative = [IO.Path]::GetRelativePath($SceneRoot, $path)
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '^\.\.(?:[\\/]|$)' -or $relative.Contains(':') -or
            [IO.Path]::GetExtension($relative) -notin '.png', '.jpg', '.jpeg', '.bmp', '.gif', '.webp') { return }
        return @{ root = $SceneRoot; path = $path }
    }
    catch { return }
}

function Get-WebBulletinPreview {
    param([System.Collections.IDictionary]$Arguments, [switch]$Image, [switch]$PlanOnly)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    if (-not $id) { return @{ ok = $false; error = 'not_found' } }
    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
    if (-not $bulletin) { return @{ ok = $false; error = 'not_found' } }
    if ((Get-JsonProp $Arguments 'revision') -ne (Get-JsonProp $bulletin 'Revision')) { return @{ ok = $false; error = 'bulletin_stale' } }
    $fields = @(Get-WebBulletinFields -Bulletin $bulletin)
    $imageField = Get-WebBulletinImageField -Fields $fields
    $rows = @(Get-JsonProp $bulletin 'Rows' | Where-Object { $null -ne $_ })
    $window = Get-BridgePageWindow -ItemCount $rows.Count -Page ([int](Get-JsonProp $Arguments 'page'))
    $supported = Test-MojazBulletinPlaybackDesign -Bulletin $bulletin
    $sceneTiming = Get-MojazBulletinSceneTiming -Bulletin $bulletin
    $plan = if ($supported -or $sceneTiming) {
        (Get-MojazResolvedRunSnapshot -Bulletin $bulletin).Value
    }
    $designKey = Get-MojazBulletinDesignKey -Bulletin $bulletin
    $design = Get-JsonProp (Get-TemplateStore).Map $designKey
    $scenePath = [string](Get-JsonProp $design 'Path')
    $sceneRoot = if ([IO.Path]::IsPathFullyQualified($scenePath)) { Split-Path -Parent $scenePath } else { '' }
    $templateImage = if (($imageField -or $supported) -and $sceneRoot) { Get-MojazTemplateImage -Path $scenePath } else { '' }
    $stampJson = ConvertTo-Json -Compress -Depth 8 -InputObject @(
        $designKey,
        @($fields | ForEach-Object { @($_.name, $_.kind, $_.label) }),
        $supported, $sceneTiming, (Get-JsonProp $plan 'Plan'), (Get-JsonProp $plan 'ExitAtSeconds'), $scenePath, (Get-JsonProp $design 'Layer'), $templateImage
    )
    $stamp = [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData($script:WebBulletinPreviewKey, [Text.Encoding]::UTF8.GetBytes($stampJson)))
    $expectedStamp = [string](Get-JsonProp $Arguments 'stamp')
    if (($expectedStamp -or $Image -or $PlanOnly) -and $expectedStamp -cne $stamp) { return @{ ok = $false; error = 'bulletin_stale' } }
    if ($PlanOnly) {
        return @{ ok = $true; data = @{
            Snapshot = $plan; TemplateImage = $templateImage; ScenePath = $scenePath; Layer = Get-JsonProp $design 'Layer'
            DesignFields = @($fields | ForEach-Object { @{ Name = $_.name; Kind = $_.kind } })
            OutroSeconds = Get-JsonProp $sceneTiming 'OutroSeconds'
        } }
    }
    $steps = @{}
    foreach ($step in @(Get-JsonProp $plan 'Plan')) {
        if ($step -and $step.RowId) { $steps[[string]$step.RowId] = $step }
    }
    $savedImages = @(if ($imageField) { Get-MojazEffectiveImages -Rows $rows -TemplateImage $templateImage })
    $plannedImages = @(if ($imageField -and $plan) { Get-MojazEffectiveImages -Rows @($plan.Rows) -TemplateImage $templateImage })
    if ($Image) {
        $fieldName = [string](Get-JsonProp $Arguments 'field')
        $rowId = [string](Get-JsonProp $Arguments 'rowId')
        if (-not $rowId -or $fieldName -cnotin @($fields | Where-Object { $_.kind -eq 'media' } | ForEach-Object { $_.name })) {
            return @{ ok = $false; error = 'not_found' }
        }
        $imageIndex = (Get-MojazRowNumber -Bulletin $bulletin -RowId $rowId) - 1
        if ($imageIndex -lt 0) { return @{ ok = $false; error = 'not_found' } }
        $step = $steps[$rowId]
        $reference = if ($fieldName -cne $imageField) { Get-MojazRowFieldValue -Row $rows[$imageIndex] -FieldName $fieldName }
            elseif ($step) { $plannedImages[$step.Index] }
            else { $savedImages[$imageIndex] }
        $file = Resolve-WebBulletinPreviewImage -SceneRoot $sceneRoot -Reference $reference
        if (-not $file) { return @{ ok = $false; error = 'not_found' } }
        return @{ ok = $true; data = $file }
    }
    $items = @(
        for ($position = $window.StartIndex; $position -le $window.EndIndex; $position++) {
            $row = $rows[$position]
            $step = $steps[[string](Get-JsonProp $row 'Id')]
            # Skipped rows can transfer their picture choice to the next
            # played row. The shared run snapshot has already resolved it.
            if ($step) { $row = $plan.Rows[$step.Index] }
            $view = Get-WebBulletinRowView -Row $row -Fields $fields -ImageField $imageField -BuiltIn:($designKey -eq $script:MojazTemplateKey)
            $view['number'] = $position + 1
            $view['startSeconds'] = Get-JsonProp $step 'AtSeconds'
            if ($step -and $imageField) {
                $view.media = @($view.media | Where-Object { $_ -ne $imageField })
                if ($view.imageMode -eq 'new' -and (Get-JsonProp $row 'Image')) { $view.media += $imageField }
                if ($step.Index -eq 0 -and $view.imageMode -eq 'inherit') { $view.imageMode = 'template' }
            }
            $view['imageFields'] = @(
                if ($sceneRoot) {
                    foreach ($mediaField in $view.media) {
                        if ($mediaField -cne $imageField -and (Resolve-WebBulletinPreviewImage -SceneRoot $sceneRoot -Reference (Get-MojazRowFieldValue -Row $row -FieldName $mediaField))) { $mediaField }
                    }
                    if ($imageField) {
                        $reference = if ($step) { $plannedImages[$step.Index] } else { $savedImages[$position] }
                        if (Resolve-WebBulletinPreviewImage -SceneRoot $sceneRoot -Reference $reference) { $imageField }
                    }
                }
            )
            $view
        }
    )
    return @{ ok = $true; data = @{
        revision = [int](Get-JsonProp $bulletin 'Revision'); stamp = $stamp; fields = $fields; rows = $items
        page = $window.Page; pageCount = $window.PageCount; total = $rows.Count
        playbackSupported = $supported; plannedCount = $steps.Count; exitSeconds = Get-JsonProp $plan 'ExitAtSeconds'; imageField = $imageField
    } }
}

function Get-WebBulletinTiming {
    param([Parameter(Mandatory)]$Bulletin)
    $scene = Get-MojazBulletinSceneTiming -Bulletin $Bulletin
    $framesPerSecond = Get-MojazFps -Bulletin $Bulletin
    $intro = [int](Get-JsonProp $Bulletin 'IntroExtraFrames')
    if ($intro -le 0 -and [double](Get-JsonProp $Bulletin 'IntroExtraSeconds') -gt 0) {
        $intro = [int][math]::Round([double](Get-JsonProp $Bulletin 'IntroExtraSeconds') * $framesPerSecond)
    }
    $last = [int](Get-JsonProp $Bulletin 'LastRowFrames')
    if ($last -le 0 -and [double](Get-JsonProp $Bulletin 'LastRowSeconds') -gt 0) {
        $last = [int][math]::Round([double](Get-JsonProp $Bulletin 'LastRowSeconds') * $framesPerSecond)
    }
    return @{
        delayFrames = Get-MojazDelayFrames -Bulletin $Bulletin
        introExtraFrames = $intro; lastRowFrames = $last
        syncToLoop = Test-MojazSyncToLoop -Bulletin $Bulletin
        loopFrames = [int](Get-JsonProp $scene 'LoopFrames'); fps = $framesPerSecond
        effectiveIntroFrames = Get-MojazIntroFrames -Bulletin $Bulletin
        effectiveLastFrames = Get-MojazLastRowFrames -Bulletin $Bulletin
        fitNote = Get-MojazBulletinLoopFitNote -Bulletin $Bulletin
    }
}

function ConvertTo-WebBulletinRowArguments {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Cells)
    $row = @{ Fields = @{} }
    foreach ($key in $Cells.Keys) {
        if ($key -eq $script:MojazTitleVariable) { $row.Title = $Cells[$key]; $row.Fields[$key] = '' }
        elseif ($key -eq $script:MojazTextVariable) { $row.Text = $Cells[$key]; $row.Fields[$key] = '' }
        else { $row.Fields[$key] = $Cells[$key] }
    }
    return $row
}

function Read-WebBulletinRowArguments {
    param($Values, [object[]]$Fields, [switch]$RequireStory)
    if ($Values -isnot [System.Collections.IDictionary] -or $Values.Count -ne $Fields.Count) { return }
    $cells = @{}
    foreach ($field in $Fields) {
        $value = Get-JsonProp $Values $field.name
        if ($value -isnot [string] -or $value.Length -gt 4096) { return }
        # The bot's row commands normalize invisible characters before the
        # values reach air. Apply that same normalization before checking
        # for an empty title/story or validating the remaining XML text.
        $value = ConvertTo-MojazRowText -Text $value
        try { [void][System.Xml.XmlConvert]::VerifyXmlChars($value) }
        catch { return }
        $cells[$field.name] = $value
    }
    if ($RequireStory -and (-not $cells[$script:MojazTitleVariable] -or -not $cells[$script:MojazTextVariable])) { return }
    return (ConvertTo-WebBulletinRowArguments -Cells $cells)
}

function Read-WebBulletinPaste {
    param([string]$Text, [string]$Format, [object[]]$Fields)
    if ($Format -eq 'headlines') {
        foreach ($line in ($Text -split '\r?\n')) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parsed = ConvertFrom-MojazPasteText -Text $line
            $values = if ($parsed.Rows.Count -eq 1) {
                @{ $script:MojazTitleVariable = $parsed.Rows[0].Title; $script:MojazTextVariable = $parsed.Rows[0].Text }
            }
            @{ values = $values }
        }
        return
    }
    Read-WebTablePaste -Text $Text -Fields $Fields
}

function Read-WebTablePaste {
    param([string]$Text, [object[]]$Fields)
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new([IO.StringReader]::new($Text))
    try {
        $parser.SetDelimiters("`t")
        $parser.TrimWhiteSpace = $false
        while (-not $parser.EndOfData) {
            $values = $null
            try {
                $cells = $parser.ReadFields()
                if ($cells.Length -eq $Fields.Count) {
                    $values = @{}
                    for ($column = 0; $column -lt $Fields.Count; $column++) { $values[$Fields[$column].name] = $cells[$column] }
                }
            }
            catch [Microsoft.VisualBasic.FileIO.MalformedLineException] { $values = $null }
            @{ values = $values }
        }
    }
    finally { $parser.Dispose() }
}

function Invoke-WebBulletinPaste {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
    if (-not $bulletin) { return @{ ok = $false; error = 'not_found' } }
    $revision = Get-JsonProp $Arguments 'revision'
    if ($revision -ne $bulletin.Revision) { return @{ ok = $false; error = 'bulletin_stale' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    $format = [string](Get-JsonProp $Arguments 'format')
    $pasteText = [string](Get-JsonProp $Arguments 'text')
    if ($action -notin 'preview', 'commit' -or $format -notin 'table', 'headlines' -or
        [string]::IsNullOrWhiteSpace($pasteText) -or $pasteText.Length -gt 8000) {
        return @{ ok = $false; error = 'bulletin_paste_invalid' }
    }
    try { [void][System.Xml.XmlConvert]::VerifyXmlChars($pasteText) }
    catch { return @{ ok = $false; error = 'bulletin_paste_invalid' } }

    $fields = @(Get-WebBulletinFields -Bulletin $bulletin | Where-Object { $_.kind -eq 'text' })
    if (-not $fields.Count -or ($format -eq 'headlines' -and -not (Test-WebBulletinHeadlineFormat -Fields $fields))) {
        return @{ ok = $false; error = 'bulletin_invalid' }
    }
    $pasted = @(Read-WebBulletinPaste -Text $pasteText -Format $format -Fields $fields | Select-Object -First 41)
    if ($pasted.Count -gt 40) { return @{ ok = $false; error = 'bulletin_paste_invalid' } }
    $skipped = [System.Collections.Generic.List[int]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($record = 0; $record -lt $pasted.Count; $record++) {
        $filled = Get-MojazFieldValues -Fields $pasted[$record].values
        if ($filled.Count -eq 0 -or @($filled.Values | Where-Object { $_.Length -gt 4096 }).Count -gt 0) {
            $skipped.Add($record + 1)
            continue
        }
        $cells = [ordered]@{}
        foreach ($field in $fields) { $cells[$field.name] = [string]$filled[$field.name] }
        $rows.Add($cells)
    }

    $columns = @(foreach ($field in $fields) { , @($field.name, $field.label, $field.kind) })
    $design = Get-MojazBulletinDesignKey -Bulletin $bulletin
    $reviewed = ConvertTo-Json -Depth 6 -Compress -InputObject @(
        $actor, $id, $revision, $format, $design, $columns, $rows.ToArray(), $skipped.ToArray()
    )
    $review = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($reviewed)))
    if ($action -eq 'preview') {
        return @{ ok = $true; data = @{ preview = @{
                    review = $review; fields = $fields; rows = $rows.ToArray(); skippedLines = $skipped.ToArray()
                } } }
    }
    if ((Get-JsonProp $Arguments 'review') -cne $review) { return @{ ok = $false; error = 'bulletin_stale' } }
    if (-not $rows.Count) { return @{ ok = $false; error = 'bulletin_paste_invalid' } }
    $rowArguments = @(foreach ($cells in $rows) {
            $rowArgs = ConvertTo-WebBulletinRowArguments -Cells $cells
            $rowArgs.Fields = Get-MojazFieldValues -Fields $rowArgs.Fields
            if (-not $rowArgs.Fields.Count) { $rowArgs.Remove('Fields') }
            $rowArgs
        })
    $result = Add-MojazBulletinRows -Library $script:MojazLibrary -BulletinId $id -Rows $rowArguments -UserId $actor
    if (-not $result.Success) { return @{ ok = $false; error = 'bulletin_refused'; data = [string]$result.Error } }
    if (-not (Invoke-MojazEdit -Result $result -ChatId $actor -Quiet)) {
        return @{ ok = $false; error = 'bulletin_save_failed' }
    }
    Add-AuditEntry "Web bulletin paste ($($rows.Count) rows) by $(Format-UserAuditActor -UserId $actor) ($id)"
    $saved = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
    $window = Get-BridgePageWindow -ItemCount @($saved.Rows).Count -Page ([int]::MaxValue)
    return @{ ok = $true; data = @{ savedPage = $window.Page } }
}

function Test-WebBulletinHeadlineFormat {
    param([object[]]$Fields)
    $names = @($Fields | Where-Object { $_.kind -eq 'text' } | ForEach-Object { $_.name })
    return $names.Count -eq 2 -and $script:MojazTitleVariable -in $names -and $script:MojazTextVariable -in $names
}

function Invoke-WebBulletinEdit {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'designs') {
        $designs = @(
            if (Get-Setting 'MojazMultiDesign') {
                foreach ($design in Get-MojazUsableDesigns) {
                    @{ key = $design.Key; label = $(if ($design.Description) { $design.Description } else { $design.Key }) }
                }
            }
        )
        return @{ ok = $true; data = @{ designs = $designs } }
    }
    $id = [string](Get-JsonProp $Arguments 'id')
    $page = [int](Get-JsonProp $Arguments 'page')
    $name = ([string](Get-JsonProp $Arguments 'name')).Trim()
    if ($action -in 'create', 'copy', 'rename' -and (-not $name -or $name.Length -gt 120)) {
        return @{ ok = $false; error = 'bulletin_invalid' }
    }
    $editArgs = @{ Library = $script:MojazLibrary; UserId = $actor }
    if ($action -eq 'create') {
        $designKey = [string](Get-JsonProp $Arguments 'design')
        if ($designKey -and (
                -not (Get-Setting 'MojazMultiDesign') -or
                $designKey -notin @(Get-MojazUsableDesigns | ForEach-Object { $_.Key })
            )) { return @{ ok = $false; error = 'bulletin_invalid' } }
        $result = Add-MojazBulletin @editArgs -Name $name -DelayFrames (Get-MojazDelayFrames) -TemplateKey $designKey
    }
    else {
        if (-not $id) { return @{ ok = $false; error = 'not_found' } }
        $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
        if (-not $bulletin) { return @{ ok = $false; error = 'not_found' } }
        if ($action -eq 'read') { return @{ ok = $true; data = Get-WebBulletinEditor -Bulletin $bulletin -Page $page } }
        if ((Get-JsonProp $Arguments 'revision') -ne (Get-JsonProp $bulletin 'Revision')) {
            return @{ ok = $false; error = 'bulletin_stale' }
        }
        $editArgs.BulletinId = $id
        $rowId = [string](Get-JsonProp $Arguments 'rowId')
        if ($action -in 'update', 'up', 'down', 'skip', 'remove' -and -not $rowId) {
            return @{ ok = $false; error = 'bulletin_invalid' }
        }
        switch ($action) {
            'copy' { $result = Copy-MojazBulletin @editArgs -Name $name }
            'rename' { $result = Rename-MojazBulletin @editArgs -Name $name }
            'design' {
                if (-not (Get-Setting 'MojazMultiDesign')) { return @{ ok = $false; error = 'bulletin_invalid' } }
                $result = Get-MojazBulletinDesignChange -BulletinId $id -TemplateKey ([string](Get-JsonProp $Arguments 'design')) -UserId $actor
                if ($result.ErrorCode -eq 'on_air') { return @{ ok = $false; error = 'bulletin_on_air' } }
                if ($result.ErrorCode -eq 'design_collision') { return @{ ok = $false; error = 'bulletin_design_collision' } }
            }
            'timing' {
                if (-not (Test-MojazBulletinPlaybackDesign -Bulletin $bulletin) -and -not (Get-MojazBulletinSceneTiming -Bulletin $bulletin)) {
                    return @{ ok = $false; error = 'bulletin_invalid' }
                }
                $timing = Get-JsonProp $Arguments 'timing'
                $sync = Get-JsonProp $timing 'syncToLoop'
                $timingArgs = @{}
                foreach ($setting in @('delayFrames', 'introExtraFrames', 'lastRowFrames')) {
                    $frameCount = Get-JsonProp $timing $setting
                    if ($null -eq $frameCount) { continue }
                    if (($frameCount -isnot [int] -and $frameCount -isnot [long]) -or $frameCount -lt 0 -or $frameCount -gt [int]::MaxValue) {
                        return @{ ok = $false; error = 'bulletin_invalid' }
                    }
                    $timingArgs[$setting] = [int]$frameCount
                }
                if ($null -ne $sync) {
                    if ($sync -isnot [bool]) { return @{ ok = $false; error = 'bulletin_invalid' } }
                    $timingArgs.SyncToLoop = $sync
                }
                if (-not $timingArgs.Count) { return @{ ok = $false; error = 'bulletin_invalid' } }
                $result = Set-MojazBulletinTiming @editArgs @timingArgs
            }
            'skip' { $result = Switch-MojazBulletinRowSkip @editArgs -RowId $rowId }
            'remove' { $result = Remove-MojazBulletinRow @editArgs -RowId $rowId }
            { $_ -in 'up', 'down' } { $result = Move-MojazBulletinRow @editArgs -RowId $rowId -Direction $action }
            { $_ -in 'add', 'update' } {
                $values = Get-JsonProp $Arguments 'values'
                $allFields = @(Get-WebBulletinFields -Bulletin $bulletin)
                $fields = @($allFields | Where-Object { $_.kind -eq 'text' })
                $imageField = Get-WebBulletinImageField -Fields $allFields
                $imageMode = [string](Get-JsonProp $Arguments 'imageMode')
                $imageSource = [string](Get-JsonProp $Arguments 'imageSourceRowId')
                $requireStory = $action -eq 'add' -and (Get-MojazBulletinDesignKey -Bulletin $bulletin) -eq $script:MojazTemplateKey -and
                    (Test-WebBulletinHeadlineFormat -Fields $fields)
                $rowArgs = Read-WebBulletinRowArguments -Values $values -Fields $fields -RequireStory:$requireStory
                if (-not $rowArgs -or ($fields.Count -eq 0 -and -not $imageMode)) { return @{ ok = $false; error = 'bulletin_invalid' } }
                if ($imageMode -or $imageSource) {
                    if (-not $imageField -or $imageMode -cnotin 'inherit', 'template', 'reuse' -or ($imageSource -and $imageMode -cne 'reuse')) {
                        return @{ ok = $false; error = 'bulletin_image_invalid' }
                    }
                    $rowArgs.Image = ''
                    $rowArgs.ImageMode = $imageMode
                    if ($imageMode -ceq 'reuse') {
                        if (-not $imageSource) { return @{ ok = $false; error = 'bulletin_image_invalid' } }
                        $sourceRow = @(Get-JsonProp $bulletin 'Rows') | Where-Object { [string](Get-JsonProp $_ 'Id') -ceq $imageSource } | Select-Object -First 1
                        $rowArgs.Image = [string](Get-JsonProp $sourceRow 'Image')
                        if (-not $rowArgs.Image) { return @{ ok = $false; error = 'bulletin_image_invalid' } }
                        $rowArgs.ImageMode = 'new'
                    }
                    # Older bulletin designs could also carry a picture under
                    # the same field in the value bag. The explicit choice wins.
                    $rowArgs.Fields[$imageField] = ''
                    $rowArgs.AllowImageOnly = $fields.Count -eq 0
                }
                # Clear stale design aliases for the names the bot edits directly.
                $designFields = $rowArgs.Fields
                $rowArgs.Remove('Fields')
                if ($action -eq 'add') {
                    $filled = Get-MojazFieldValues -Fields $designFields
                    if ($filled.Count -gt 0) { $rowArgs.Fields = $filled }
                    $result = Add-MojazBulletinRow @editArgs @rowArgs
                }
                else { $result = Set-MojazBulletinRow @editArgs @rowArgs -RowId $rowId -DesignFields $designFields }
            }
            default { return @{ ok = $false; error = 'bulletin_invalid' } }
        }
    }
    if (-not $result.Success) {
        return @{ ok = $false; error = 'bulletin_refused'; data = [string]$result.Error }
    }
    if (-not (Invoke-MojazEdit -Result $result -ChatId $actor -Quiet)) {
        return @{ ok = $false; error = 'bulletin_save_failed' }
    }
    $saved = if ($action -in 'create', 'copy') { @(Get-JsonProp $script:MojazLibrary 'Bulletins')[-1] }
    else { Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id }
    if ($action -eq 'add') { $page = [int]::MaxValue }
    if ($action -in 'up', 'down') {
        $page = Get-MojazRowPage -Rows @(Get-JsonProp $saved 'Rows' | Where-Object { $null -ne $_ }) -RowId $rowId -PageSize 20
    }
    Add-AuditEntry "Web bulletin $action by $(Format-UserAuditActor -UserId $actor) ($([string]$saved.Id))"
    return @{ ok = $true; data = Get-WebBulletinEditor -Bulletin $saved -Page $page }
}

function Test-WebBulletinPlayoutAccess {
    param($Bulletin, [long]$Actor)
    if (-not (Test-MojazBulletinPlaybackDesign -Bulletin $Bulletin)) { return $false }
    $template = Get-MojazPlaybackTemplate -Bulletin $Bulletin
    if (-not $template) { return $false }
    $key = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    $layer = [int](Get-JsonProp $template 'Layer')
    return ((Test-TemplateAccess -Key $key -Layer $layer -ChatId $Actor -UserId $Actor).Allowed -and
        (Test-TemplateShowPolicy -Key $key -Layer $layer -IsAdmin:(Test-Admin -ChatId $Actor -UserId $Actor)).Allowed)
}

function Get-WebBulletinPlaybackState {
    param([string]$Id, [bool]$CanStart)
    $playback = $script:MojazPlayback
    $run = $null
    if ([string](Get-JsonProp $playback 'BulletinId') -ceq $Id -and (Get-JsonProp $playback 'OperationId')) {
        $run = @{
            id = [string](Get-JsonProp $playback 'OperationId')
            state = if (-not (Get-MojazRunSceneStamp -Playback $playback)) { 'scene_unconfirmed' }
                elseif (Get-JsonProp $playback 'FieldsBlocked') { 'fields_blocked' }
                elseif (Get-JsonProp $playback 'StopFailed') { 'stop_unconfirmed' }
                else { 'playing' }
            row = [int](Get-JsonProp $playback 'Index') + 1
            rowCount = @(Get-JsonProp $playback 'Rows').Count
        }
    }
    $canQueueAfterUrgent = $CanStart -and -not $run -and (Test-MojazUrgentOnAir)
    return @{ run = $run; canStart = $CanStart; busy = [bool]$playback; canQueueAfterUrgent = $canQueueAfterUrgent }
}

function Invoke-WebBulletinPlayback {
    param([System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    if (-not $id) { return @{ ok = $false; error = 'not_found' } }
    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
    if (-not $bulletin) { return @{ ok = $false; error = 'not_found' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $canStart = Test-WebBulletinPlayoutAccess -Bulletin $bulletin -Actor $actor
    if ($action -eq 'status') { return @{ ok = $true; data = Get-WebBulletinPlaybackState -Id $id -CanStart $canStart } }
    if ($action -notin 'review', 'start', 'stop') { return @{ ok = $false; error = 'bulletin_invalid' } }
    if ($action -eq 'start') {
        $pending = Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebBulletinPlaybackReviews
        if (-not $pending) { return @{ ok = $false; error = 'bulletin_playback_stale' } }
    }
    if (-not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'bulletin_playback_unavailable' } }
    if ($action -eq 'stop') {
        $run = $script:MojazPlayback
        $runId = [string](Get-JsonProp $Arguments 'runId')
        if (-not $runId -or $runId -cne [string](Get-JsonProp $run 'OperationId') -or $id -cne [string](Get-JsonProp $run 'BulletinId')) {
            return @{ ok = $false; error = 'bulletin_playback_stale' }
        }
        $layer = Get-MojazRunLayer -Playback $run
        if ($layer -le 0) { return @{ ok = $false; error = 'bulletin_playback_unavailable' } }
        if (-not (Test-TemplateAccess -Key (Get-MojazRunDesignKey -Playback $run) -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
            return @{ ok = $false; error = 'forbidden' }
        }
        $expected = Get-MojazRunSceneStamp -Playback $run
        $observed = Read-MojazLayerStamp -Layer $layer
        if (-not $expected -or $expected -cne $observed) { return @{ ok = $false; error = 'bulletin_playback_stale' } }
        if (-not (Stop-MojazPlayback -ChatId $actor -UserId $actor -ExpectedLayerStamp $expected -Quiet)) {
            return @{ ok = $false; error = 'bulletin_stop_unconfirmed' }
        }
        Publish-WebChannelState -Force
        return @{ ok = $true; data = Get-WebBulletinPlaybackState -Id $id -CanStart $canStart }
    }
    if (-not $canStart) { return @{ ok = $false; error = 'bulletin_playback_unavailable' } }
    $layer = [int](Get-JsonProp (Get-MojazPlaybackTemplate -Bulletin $bulletin) 'Layer')
    if ($layer -le 0) { return @{ ok = $false; error = 'bulletin_playback_unavailable' } }
    if ($script:MojazPlayback) { return @{ ok = $false; error = 'bulletin_on_air' } }
    if (Test-MojazUrgentOnAir) { return @{ ok = $false; error = 'bulletin_urgent_active' } }
    $preview = Get-WebBulletinPreview -Arguments $Arguments -PlanOnly
    if (-not $preview.ok) { return $preview }
    $plan = $preview.data
    if (-not $plan.Snapshot) { return @{ ok = $false; error = 'bulletin_playback_empty' } }
    if ($null -ne $plan.Layer -and $plan.Layer -ne $layer) { return @{ ok = $false; error = 'bulletin_playback_stale' } }
    if ((Get-MojazBulletinDesignKey -Bulletin $bulletin) -ne $script:MojazTemplateKey -and
        -not (Test-MojazAlternateFieldIsolation -Layer $layer -Fields $plan.DesignFields)) {
        return @{ ok = $false; error = 'bulletin_fields_busy' }
    }
    $observed = Read-MojazLayerStamp -Layer $layer
    if (-not $observed) { return @{ ok = $false; error = 'bulletin_layer_unknown' } }
    $ticker = Get-MojazTickerReview
    if ((Get-JsonProp $ticker 'Layer') -eq $layer) { $ticker = $null }
    $fingerprint = "$id|$(Get-JsonProp $Arguments 'revision')|$(Get-JsonProp $Arguments 'stamp')|$layer|$observed|$(Get-JsonProp $ticker 'Layer')|$(Get-JsonProp $ticker 'Stamp')"
    if ($action -eq 'review') {
        $review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebBulletinPlaybackReviews
        return @{ ok = $true; data = @{ canStart = $true; busy = $false; review = $review; layer = $layer
                replacing = $observed -ne 'empty'; pausesTicker = [bool]$ticker } }
    }
    if ($pending.Fingerprint -cne $fingerprint) { return @{ ok = $false; error = 'bulletin_playback_stale' } }
    $plan.Layer = $layer
    $plan.LayerStamp = $observed
    $plan.Ticker = $ticker
    if (-not (Start-MojazPlayback -ChatId $actor -UserId $actor -Bulletin $bulletin -ReviewedPlan $plan)) {
        return @{ ok = $false; error = 'bulletin_playback_refused' }
    }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = Get-WebBulletinPlaybackState -Id $id -CanStart $canStart }
}

function Get-WebBulletinSchedules {
    param([string]$BulletinId, [int]$Page, [bool]$CanSchedule)
    $entries = @(
        foreach ($entry in $script:MojazSchedules) {
            if ((Get-JsonProp $entry 'BulletinId') -ne $BulletinId) { continue }
            $time = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse([string](Get-JsonProp $entry 'ScheduledAt'), [ref]$time)) { continue }
            $status = [string](Get-JsonProp $entry 'Status')
            $reason = if ($status -eq 'failed') { Get-JsonProp $entry 'LastError' } else { Get-JsonProp $entry 'DelayReason' }
            @{ id = [string](Get-JsonProp $entry 'Id'); scheduledAtMs = $time.ToUnixTimeMilliseconds(); status = $status
                canCancel = $status -in 'scheduled', 'queued'; reason = [string]$reason }
        }
    )
    $ordered = @($entries | Sort-Object @{ Expression = { if ($_.canCancel) { 0 } else { 1 } } },
        @{ Expression = { if ($_.canCancel) { $_.scheduledAtMs } else { -$_.scheduledAtMs } } })
    $window = Get-BridgePageWindow -ItemCount $ordered.Count -Page $Page
    return @{ canSchedule = $CanSchedule; page = $window.Page; pageCount = $window.PageCount
        items = @(for ($i = $window.StartIndex; $i -le $window.EndIndex; $i++) { $ordered[$i] }) }
}

function Invoke-WebBulletinSchedule {
    param([System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    if (-not $id) { return @{ ok = $false; error = 'not_found' } }
    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
    if (-not $bulletin) { return @{ ok = $false; error = 'not_found' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $page = [int](Get-JsonProp $Arguments 'page')
    $canSchedule = Test-WebBulletinPlayoutAccess -Bulletin $bulletin -Actor $actor
    switch ($action) {
        'list' {}
        'add' {
            if (-not $canSchedule) { return @{ ok = $false; error = 'bulletin_schedule_unavailable' } }
            if ((Get-JsonProp $Arguments 'revision') -ne (Get-JsonProp $bulletin 'Revision')) { return @{ ok = $false; error = 'bulletin_stale' } }
            $now = [datetimeoffset]::Now
            $clock = Get-SystemClockStatus -Now $now
            if (-not $clock.Success) { return @{ ok = $false; error = 'bulletin_schedule_clock' } }
            $stamp = Get-JsonProp $Arguments 'scheduledAtMs'
            if ($stamp -isnot [long] -and $stamp -isnot [int]) { return @{ ok = $false; error = 'bulletin_schedule_invalid' } }
            try { $when = [datetimeoffset]::FromUnixTimeMilliseconds($stamp).ToLocalTime() }
            catch { return @{ ok = $false; error = 'bulletin_schedule_invalid' } }
            if ($when -le $now) { return @{ ok = $false; error = 'bulletin_schedule_invalid' } }
            $existing = Get-MojazBulletinSchedules -BulletinId $id | Where-Object {
                [long](Get-JsonProp $_ 'CreatedBy') -eq $actor -and [datetimeoffset](Get-JsonProp $_ 'ScheduledAt') -eq $when
            } | Select-Object -First 1
            if (-not $existing) {
                if (-not (Add-MojazSchedule -BulletinId $id -ScheduledAt $when -ChatId $actor -UserId $actor -FromWeb)) {
                    return @{ ok = $false; error = 'bulletin_schedule_save_failed' }
                }
                Add-AuditEntry (T 'mjz.slotAudit' $($when.ToLocalTime().ToString('HH:mm')) $(Format-UserAuditActor -UserId $actor))
            }
            $page = 0
        }
        'cancel' {
            $scheduleId = [string](Get-JsonProp $Arguments 'scheduleId')
            if (-not $scheduleId -or $scheduleId -notin @(Get-MojazBulletinSchedules -BulletinId $id | ForEach-Object { $_.Id })) {
                return @{ ok = $false; error = 'bulletin_schedule_stale' }
            }
            $outcome = Remove-MojazPendingSchedule -ScheduleId $scheduleId
            if ($outcome -ne 'cancelled') { return @{ ok = $false; error = 'bulletin_schedule_save_failed' } }
            Add-AuditEntry (T 'mjz.slotCancelledAudit' $(Format-UserAuditActor -UserId $actor))
        }
        default { return @{ ok = $false; error = 'bulletin_schedule_invalid' } }
    }
    return @{ ok = $true; data = Get-WebBulletinSchedules -BulletinId $id -Page $page -CanSchedule $canSchedule }
}

function Get-WebBulletinPhotoDestination {
    param($Bulletin, [string]$Field)
    $design = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    if ($Field -cne $script:MojazImageVariable) {
        $template = Get-MojazPlaybackTemplate -Bulletin $Bulletin
        if (-not (Test-MojazDesignTemplate -Key $design -Template $template)) { return $null }
        $scene = [string](Get-JsonProp $template 'Path')
        $designDirectory = Get-MojazDesignUploadDirectory -Scene $scene
        if ($designDirectory) { return @{ Directory = $designDirectory; Scene = $scene } }
        return $null
    }
    $directory = Get-MojazUploadDirectory
    if (-not $directory -or -not (Test-MojazUploadDirectoryPath -Directory $directory)) { return $null }
    $scenePath = ''
    if ($design -ne $script:MojazTemplateKey) {
        $scenePath = [string](Get-JsonProp (Get-TemplateStore).Map[$design] 'Path')
        if (-not $scenePath -or (Join-Path (Split-Path -Parent $scenePath) 'Mojaz\bot') -ne $directory) { return $null }
    }
    return @{ Directory = $directory; Scene = $scenePath }
}

function Get-WebBulletinPhotoAdmission {
    param([System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    $rowId = [string](Get-JsonProp $Arguments 'rowId')
    $newRow = Get-JsonProp $Arguments 'createRow'
    $createRow = $newRow -is [bool] -and $newRow
    if (-not $id -or (-not $rowId -and -not $createRow)) { return @{ ok = $false; error = 'not_found' } }
    if ($createRow -and $rowId) { return @{ ok = $false; error = 'bulletin_photo_invalid' } }
    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
    if (-not $bulletin) { return @{ ok = $false; error = 'not_found' } }
    if ((Get-JsonProp $Arguments 'revision') -ne (Get-JsonProp $bulletin 'Revision')) { return @{ ok = $false; error = 'bulletin_stale' } }
    if (-not $createRow -and $rowId -cnotin @(Get-JsonProp $bulletin 'Rows' | ForEach-Object { [string](Get-JsonProp $_ 'Id') })) {
        return @{ ok = $false; error = 'not_found' }
    }
    $fields = @(Get-WebBulletinFields -Bulletin $bulletin)
    $rowArguments = @{}
    $values = Get-JsonProp $Arguments 'values'
    if ($null -ne $values) {
        if (-not $createRow) { return @{ ok = $false; error = 'bulletin_invalid' } }
        $textFields = @($fields | Where-Object { $_.kind -eq 'text' })
        $requireStory = (Get-MojazBulletinDesignKey -Bulletin $bulletin) -eq $script:MojazTemplateKey -and
            (Test-WebBulletinHeadlineFormat -Fields $textFields)
        $rowArguments = Read-WebBulletinRowArguments -Values $values -Fields $textFields -RequireStory:$requireStory
        if (-not $rowArguments) { return @{ ok = $false; error = 'bulletin_invalid' } }
        $rowArguments.Fields = Get-MojazFieldValues -Fields $rowArguments.Fields
        if (-not $rowArguments.Fields.Count) { $rowArguments.Remove('Fields') }
    }
    $requested = [string](Get-JsonProp $Arguments 'field')
    $field = if ($requested) { $requested } else { Get-WebBulletinImageField -Fields $fields }
    if (-not $field -or $field -cnotin @($fields | Where-Object { $_.kind -eq 'media' } | ForEach-Object { $_.name })) {
        return @{ ok = $false; error = 'bulletin_photo_unavailable' }
    }
    $destination = Get-WebBulletinPhotoDestination -Bulletin $bulletin -Field $field
    if (-not $destination) { return @{ ok = $false; error = 'bulletin_photo_unavailable' } }
    $size = if ($field -ceq $script:MojazImageVariable) { Get-MojazImageSize -Path $destination.Scene }
    else {
        $key = Get-MojazBulletinDesignKey -Bulletin $bulletin
        $prompt = Get-MojazRowFieldPrompts -TemplateKey $key | Where-Object { $_.Name -ceq $field } | Select-Object -First 1
        if ((Get-JsonProp $prompt 'Width') -gt 0 -and (Get-JsonProp $prompt 'Height') -gt 0) {
            @{ Width = $prompt.Width; Height = $prompt.Height }
        }
    }
    return @{ ok = $true; Actor = $actor; BulletinId = $id; RowId = $rowId; Directory = $destination.Directory
        Size = $size; Scene = $destination.Scene; Field = $field; CreateRow = $createRow; RowArguments = $rowArguments }
}

function Start-WebBulletinPhotoRequest {
    param([Parameter(Mandatory)][hashtable]$Entry)
    $arguments = Get-JsonProp $Entry.Request 'args'
    if ($arguments -isnot [System.Collections.IDictionary]) { return @{ ok = $false; error = 'bulletin_photo_invalid' } }
    $admission = Get-WebBulletinPhotoAdmission -Arguments $arguments
    if (-not $admission.ok) { return $admission }
    $action = Get-JsonProp $arguments 'action'
    if ($action -ceq 'prepare') {
        return @{ ok = $true; data = @{ directory = $script:mojazWebUploadDirectory; maximumBytes = 10MB } }
    }
    $upload = [string](Get-JsonProp $arguments 'upload')
    if ($action -cne 'apply' -or $upload -cnotmatch '^[a-f0-9]{32}$') { return @{ ok = $false; error = 'bulletin_photo_invalid' } }
    if ($script:WebBulletinPhotoRequest) { return @{ ok = $false; error = 'bulletin_photo_busy' } }
    $sourcePath = Join-Path $script:mojazWebUploadDirectory "web-$upload.image"
    $source = Get-Item -LiteralPath $sourcePath -ErrorAction SilentlyContinue
    if (-not $source -or $source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $source.Length) {
        return @{ ok = $false; error = 'bulletin_photo_invalid' }
    }
    if ($source.Length -gt 10MB) { return @{ ok = $false; error = 'bulletin_photo_size' } }
    $name = "mojaz-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8)).png"
    $path = Join-Path $admission.Directory $name
    $pipeline = [powershell]::Create()
    try {
        # Image decoding must not block the playout tick. Only the bridge
        # thread can change the bulletin after the worker returns.
        $pipeline.AddScript(${function:Convert-MojazPicture}.ToString()).AddParameter('SourcePath', $sourcePath).AddParameter('DestinationPath', $path).
            AddParameter('Size', $admission.Size).AddParameter('SharedUpload') | Out-Null
        $invocation = $pipeline.BeginInvoke()
        $script:WebBulletinPhotoRequest = @{ Entry = $Entry; Arguments = $arguments; Admission = $admission; Name = $name
            Path = $path; Pipeline = $pipeline; Invocation = $invocation; Stopping = $false; Saved = $false }
    }
    catch {
        $pipeline.Dispose()
        return @{ ok = $false; error = 'bulletin_save_failed' }
    }
}

function Stop-WebBulletinPhotoRequest {
    param([string]$ErrorCode)
    $pending = $script:WebBulletinPhotoRequest
    if (-not $pending -or $pending.Stopping) { return }
    $pending.Stopping = $true
    [void]$pending.Entry.Reply.TrySetResult(('{"ok":false,"error":"' + $ErrorCode + '"}'))
    if (-not $pending.Invocation.IsCompleted) {
        try { [void]$pending.Pipeline.BeginStop($null, $null) }
        catch { Write-BridgeLog 'The bulletin photo worker ended while cancellation was requested.' 'DEBUG' }
    }
}

function Update-WebBulletinPhotoRequest {
    $pending = $script:WebBulletinPhotoRequest
    if (-not $pending) { return }
    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $pending.Entry.Deadline) {
        Stop-WebBulletinPhotoRequest -ErrorCode 'bulletin_photo_timeout'
    }
    if (-not $pending.Invocation.IsCompleted) { return }
    $script:WebBulletinPhotoRequest = $null
    try {
        if ($pending.Stopping) { return }
        $result = @($pending.Pipeline.EndInvoke($pending.Invocation))
        $answer = @{ ok = $false; error = 'bulletin_photo_invalid' }
        if ($result.Count -eq 1 -and $result[0] -eq $true -and -not $pending.Pipeline.HadErrors) {
            $answer = Complete-WebBulletinPhotoRequest -Pending $pending
        }
        [void]$pending.Entry.Reply.TrySetResult(($answer | ConvertTo-Json -Compress -Depth 6))
    }
    catch {
        $code = if ($pending.Saved) { 'bridge_outcome_unknown' } else { 'bulletin_photo_invalid' }
        [void]$pending.Entry.Reply.TrySetResult(('{"ok":false,"error":"' + $code + '"}'))
    }
    finally {
        $pending.Pipeline.Dispose()
        if (-not $pending.Saved) { Remove-Item -LiteralPath $pending.Path -ErrorAction SilentlyContinue }
    }
}

function Complete-WebBulletinPhotoRequest {
    param([hashtable]$Pending)
    $admission = Get-WebBulletinPhotoAdmission -Arguments $Pending.Arguments
    if (-not $admission.ok) { return $admission }
    if ($admission.Directory -ne $Pending.Admission.Directory -or $admission.Scene -ne $Pending.Admission.Scene -or
        $admission.Field -cne $Pending.Admission.Field -or
        (Get-JsonProp $admission.Size 'Width') -ne (Get-JsonProp $Pending.Admission.Size 'Width') -or
        (Get-JsonProp $admission.Size 'Height') -ne (Get-JsonProp $Pending.Admission.Size 'Height')) {
        return @{ ok = $false; error = 'bulletin_stale' }
    }
    $canonical = $admission.Field -ceq $script:MojazImageVariable
    $attachment = if ($canonical) { @{ ImageMode = 'new'; Image = ".\Mojaz\bot\$($Pending.Name)" } }
    else { @{ MediaField = $admission.Field; MediaPath = $Pending.Path } }
    if ($admission.CreateRow) {
        $result = Add-MojazBulletinRows -Library $script:MojazLibrary -BulletinId $admission.BulletinId -UserId $admission.Actor `
            -Rows @($attachment + $admission.RowArguments + @{ AllowImageOnly = $true })
    }
    else {
        if ($canonical) { $attachment.DesignFields = @{ $script:MojazImageVariable = '' } }
        $result = Set-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $admission.BulletinId -RowId $admission.RowId `
            -UserId $admission.Actor @attachment
    }
    if (-not (Invoke-MojazEdit -Result $result -ChatId $admission.Actor -Quiet)) { return @{ ok = $false; error = 'bulletin_save_failed' } }
    $Pending.Saved = $true
    Add-AuditEntry "Web bulletin photo attached by $(Format-UserAuditActor -UserId $admission.Actor) ($($admission.BulletinId))"
    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $admission.BulletinId
    $rows = @(Get-JsonProp $bulletin 'Rows')
    $rowId = if ($admission.CreateRow) { [string](Get-JsonProp $rows[-1] 'Id') } else { $admission.RowId }
    $page = Get-MojazRowPage -Rows $rows -RowId $rowId -PageSize 20
    return @{ ok = $true; data = Get-WebBulletinEditor -Bulletin $bulletin -Page $page }
}

function Get-WebUrgentFields {
    $maxLength = Get-SettingInt 'UrgentBoardMaxTextLength' 300
    $isFirst = $true
    foreach ($field in Get-WebTemplateFields -Template (Get-UrgentTemplate)) {
        $field.required = $isFirst -or $field.required
        $field.maxLength = if ($field.maxLength) { [math]::Min($maxLength, [int]$field.maxLength) } else { $maxLength }
        $field
        $isFirst = $false
    }
}

function Get-WebUrgentTimingState {
    $defaults = Get-UrgentBoardDefaults
    $state = [ordered]@{
        intervalSeconds = $defaults.IntervalSeconds; repeats = $defaults.Repeats; totalSeconds = $defaults.TotalSeconds
        exitGapSeconds = Get-SettingInt 'UrgentExitGapSeconds' 0; mode = $defaults.Mode; repeatMode = $defaults.RepeatMode
    }
    $snapshot = ConvertTo-Json -Compress -InputObject $state
    $state['revision'] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($snapshot)))
    $state['floorSeconds'] = Get-UrgentFloorSeconds
    $state['canEdit'] = -not (Test-UrgentBoardTimingBusy)
    $state['bounds'] = @{}
    foreach ($kind in 'interval', 'repeats', 'total', 'gap') {
        $spec = Get-UrgentNumberSpec -Kind "d$kind"
        $state.bounds[$kind] = @{ minimum = $spec.Minimum; maximum = $spec.Maximum }
    }
    return $state
}

function Invoke-WebUrgentTiming {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-UrgentBoardAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
    $state = Get-WebUrgentTimingState
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'status') { return @{ ok = $true; data = $state } }
    if ($action -ne 'save') { return @{ ok = $false; error = 'urgent_timing_invalid' } }
    if (-not $state.canEdit) { return @{ ok = $false; error = 'urgent_timing_active' } }
    if ([string](Get-JsonProp $Arguments 'revision') -cne $state.revision) { return @{ ok = $false; error = 'urgent_stale' } }

    $field = [string](Get-JsonProp $Arguments 'field')
    $value = Get-JsonProp $Arguments 'option'
    if ($state.bounds.ContainsKey($field)) {
        $spec = Get-UrgentNumberSpec -Kind "d$($field.ToLowerInvariant())"
        $name = $spec.Setting
        $value = Get-JsonProp $Arguments 'number'
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt $spec.Minimum -or $value -gt $spec.Maximum) {
            return @{ ok = $false; error = 'urgent_timing_invalid' }
        }
    }
    elseif ($field -eq 'mode' -and $value -is [string] -and (Test-UrgentMode -Mode $value)) { $name = 'UrgentBoardMode' }
    elseif ($field -eq 'order' -and $value -is [string] -and (Test-UrgentRepeatMode -RepeatMode $value)) { $name = 'UrgentBoardRepeatMode' }
    else { return @{ ok = $false; error = 'urgent_timing_invalid' } }

    if (-not (Set-UrgentBoardSetting -ChatId $actor -Name $name -Value $value -Quiet)) {
        return @{ ok = $false; error = 'urgent_timing_save_failed' }
    }
    Add-AuditEntry "Web urgent timing $name updated by $(Format-UserAuditActor -UserId $actor)"
    return @{ ok = $true; data = Get-WebUrgentTimingState }
}

function Invoke-WebUrgentWrite {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-UrgentBoardAvailable)) { return @{ ok = $false; error = 'content_disabled' } }

    $board = $script:UrgentBoard
    if ((Get-JsonProp $Arguments 'revision') -ne (Get-JsonProp $board 'Revision')) {
        return @{ ok = $false; error = 'urgent_stale' }
    }
    $action = [string](Get-JsonProp $Arguments 'action')
    $id = [string](Get-JsonProp $Arguments 'id')
    if ($action -ne 'add' -and (-not $id -or -not (Get-UrgentItem -Board $board -ItemId $id))) {
        return @{ ok = $false; error = 'not_found' }
    }
    $row = Get-JsonProp $Arguments 'row'
    $result = $null
    switch ($action) {
        { $_ -in 'add', 'update' } {
            $values = Get-JsonProp $row 'values'
            $enabled = Get-JsonProp $row 'enabled'
            $fields = @(Get-WebUrgentFields)
            if ($fields.Count -eq 0 -or $values -isnot [System.Collections.IDictionary] -or $enabled -isnot [bool]) {
                return @{ ok = $false; error = 'urgent_invalid' }
            }
            if ($values.Count -ne $fields.Count) { return @{ ok = $false; error = 'urgent_stale' } }
            $cells = [System.Collections.Generic.List[string]]::new()
            $extra = @{}
            foreach ($field in $fields) {
                if (-not $values.Contains($field.name)) { return @{ ok = $false; error = 'urgent_stale' } }
                $cell = ([string]$values[$field.name] -replace '\s+', ' ').Trim()
                if ($field.required -and -not $cell) { return @{ ok = $false; error = 'urgent_invalid' } }
                try { [void][System.Xml.XmlConvert]::VerifyXmlChars($cell) }
                catch { return @{ ok = $false; error = 'urgent_invalid' } }
                if ($cell.Length -gt $field.maxLength) {
                    return @{ ok = $false; error = 'refused'; data = (T 'flow.textTooLong' $cell.Length $field.maxLength) }
                }
                if ($cells.Count -ge 2) { $extra[$field.name] = $cell }
                $cells.Add($cell)
            }
            $text = $cells[0]
            $heading = if ($cells.Count -gt 1) { $cells[1] } else { '' }
            $maxLength = Get-SettingInt 'UrgentBoardMaxTextLength' 300
            if ($action -eq 'add') {
                # Apply the same title and enabled validation as an edit before
                # persisting the new row and its final revision together.
                $result = Add-UrgentItem -Board $board -Text $text -MaxItems (Get-SettingInt 'UrgentBoardMaxItems' 40) -MaxLength $maxLength -UserId $actor
                if (-not $result.Success) { return @{ ok = $false; error = 'refused'; data = [string]$result.Error } }
                $board = $result.Value
                $id = $board.Items[-1].Id
            }
            $changes = [ordered]@{ Text = $text; Enabled = $enabled }
            if ($cells.Count -gt 1) { $changes.Title = $heading }
            foreach ($field in $changes.Keys) {
                $result = Set-UrgentItem -Board $board -ItemId $id -Field $field -Value $changes[$field] -MaxLength $maxLength -UserId $actor
                if (-not $result.Success) { return @{ ok = $false; error = 'refused'; data = [string]$result.Error } }
                $board = $result.Value
            }
            Set-JsonProp (Get-UrgentItem -Board $board -ItemId $id) 'ExtraFields' $extra
        }
        'timing' {
            $timing = Get-JsonProp $Arguments 'timing'
            $interval = Get-JsonProp $timing 'intervalSeconds'
            $repeat = Get-JsonProp $timing 'repeats'
            $mode = Get-JsonProp $timing 'mode'
            if (($interval -isnot [int] -and $interval -isnot [long]) -or
                ($repeat -isnot [int] -and $repeat -isnot [long]) -or $mode -isnot [string]) {
                return @{ ok = $false; error = 'urgent_invalid' }
            }
            $changes = [ordered]@{ IntervalSeconds = $interval; Repeats = $repeat; Mode = $mode }
            foreach ($field in $changes.Keys) {
                $result = Set-UrgentItem -Board $board -ItemId $id -Field $field -Value $changes[$field] -UserId $actor
                if (-not $result.Success) { return @{ ok = $false; error = 'refused'; data = [string]$result.Error } }
                $board = $result.Value
            }
        }
        'up' { $result = Move-UrgentItem -Board $board -ItemId $id -Delta -1 }
        'down' { $result = Move-UrgentItem -Board $board -ItemId $id -Delta 1 }
        'remove' { $result = Remove-UrgentItem -Board $board -ItemId $id }
        default { return @{ ok = $false; error = 'urgent_invalid' } }
    }
    if (-not $result.Success) { return @{ ok = $false; error = 'refused'; data = [string]$result.Error } }
    if (-not (Invoke-UrgentEdit -Result $result -ChatId $actor -Quiet)) { return @{ ok = $false; error = 'urgent_save_failed' } }
    Add-AuditEntry "Web urgent $action by $(Format-UserAuditActor -UserId $actor) ($id)"
    return @{ ok = $true }
}

function Get-WebTickerSheetAdmission {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-NewsSheetPullAccess -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Get-Setting 'EnableNewsTickerManagement')) { return @{ ok = $false; error = 'content_disabled' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $target = [string](Get-JsonProp $Arguments 'target')
    if ($action -cnotin 'preview', 'apply' -or $target -cnotin 'draft', 'air') { return @{ ok = $false; error = 'ticker_sheet_invalid' } }
    if ($action -eq 'apply' -and [string](Get-JsonProp $Arguments 'review') -cnotmatch '^[A-F0-9]{64}$') {
        return @{ ok = $false; error = 'ticker_sheet_invalid' }
    }
    if (Get-NewsSheetPullLockDenial -ChatId $actor -UserId $actor) { return @{ ok = $false; error = 'ticker_locked' } }
    $url = [string](Get-Setting 'NewsSheetCsvUrl')
    $path = [string](Get-Setting 'NewsFilePath')
    $separator = [string](Get-Setting 'NewsItemSeparator')
    if (-not $path -or -not $separator -or -not $url) { return @{ ok = $false; error = 'ticker_sheet_unconfigured' } }
    return @{
        ok = $true; Actor = $actor; Url = $url; Path = $path; Separator = $separator
        Action = $action; Target = $target; ByteLimit = Get-SettingInt 'NewsImportMaxBytes' 1
    }
}

function Start-WebTickerSheetRequest {
    param([Parameter(Mandatory)][hashtable]$Entry)
    $arguments = Get-JsonProp $Entry.Request 'args'
    if ($arguments -isnot [System.Collections.IDictionary]) { return @{ ok = $false; error = 'ticker_sheet_invalid' } }
    $admission = Get-WebTickerSheetAdmission -Arguments $arguments
    if (-not $admission.ok) { return $admission }
    if ($script:WebTickerSheetRequest) { return @{ ok = $false; error = 'ticker_sheet_busy' } }
    $transfer = Start-NewsSheetCsvDownload -Url $admission.Url -TimeoutSeconds ([math]::Min(8, (Get-SettingInt 'NewsSheetTimeoutSeconds' 1))) `
        -MaxBytes $admission.ByteLimit
    if ($transfer.Error) { return @{ ok = $false; error = 'ticker_sheet_unavailable' } }
    $script:WebTickerSheetRequest = @{ Entry = $Entry; Arguments = $arguments; Transfer = $transfer; Admission = $admission }
}

function Stop-WebTickerSheetRequest {
    param([string]$ErrorCode)
    $pending = $script:WebTickerSheetRequest
    if (-not $pending) { return }
    $script:WebTickerSheetRequest = $null
    $client = Get-JsonProp $pending.Transfer 'Client'
    if ($client) {
        if ($pending.Transfer.Task.IsCompletedSuccessfully) { $pending.Transfer.Task.Result.Dispose() }
        $client.Dispose()
    }
    [void]$pending.Entry.Reply.TrySetResult((@{ ok = $false; error = $ErrorCode } | ConvertTo-Json -Compress))
}

function Update-WebTickerSheetRequest {
    $pending = $script:WebTickerSheetRequest
    if (-not $pending) { return }
    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $pending.Entry.Deadline) {
        Stop-WebTickerSheetRequest -ErrorCode 'ticker_sheet_unavailable'
        return
    }
    if (-not $pending.Transfer.Task.IsCompleted) { return }
    $script:WebTickerSheetRequest = $null
    try {
        $download = Receive-NewsSheetCsvDownload -Transfer $pending.Transfer
        $admission = Get-WebTickerSheetAdmission -Arguments $pending.Arguments
        if (-not $admission.ok) { $answer = $admission }
        elseif ($admission.Url -cne $pending.Admission.Url -or $admission.ByteLimit -ne $pending.Admission.ByteLimit) {
            $answer = @{ ok = $false; error = 'ticker_sheet_stale' }
        }
        else {
            $answer = Invoke-WebTickerSheet -Admission $admission -Arguments $pending.Arguments -Download $download -Deadline $pending.Entry.Deadline
        }
    }
    catch {
        Write-BridgeLog 'The web ticker sheet request could not be completed.' 'WARN'
        $answer = @{ ok = $false; error = 'ticker_sheet_unavailable' }
    }
    [void]$pending.Entry.Reply.TrySetResult(($answer | ConvertTo-Json -Compress -Depth 6))
}

function Invoke-WebTickerSheet {
    param([hashtable]$Admission, [System.Collections.IDictionary]$Arguments, $Download, [long]$Deadline)
    $actor = $Admission.Actor
    $draft = Get-NewsTickerDraft -UserId $actor
    $target = $Admission.Target
    $path = $Admission.Path
    $separator = $Admission.Separator
    if (-not $download.Success) { return @{ ok = $false; error = 'ticker_sheet_unavailable' } }
    $source = @(ConvertFrom-NewsSheetCsv -Csv $download.Csv | ForEach-Object { Get-CleanNewsItemText -Text $_ } | Where-Object { $_ })
    if (-not $source.Count -or @($source | Where-Object { $_.Contains($separator, [StringComparison]::Ordinal) }).Count) {
        return @{ ok = $false; error = 'ticker_sheet_invalid' }
    }
    $limits = @{ Separator = $separator; MaxItemLength = Get-SettingInt 'NewsMaxItemLength' 1; MaxItems = Get-SettingInt 'NewsMaxItems' 1 }
    $parsed = ConvertFrom-NewsTickerText -Text (ConvertTo-NewsTickerText -Items $source -Separator $separator) @limits
    if (-not $parsed.Success -or -not $parsed.Items.Count) { return @{ ok = $false; error = 'ticker_sheet_invalid' } }

    $current = Get-NewsTickerSnapshot -Path $path @limits -MaximumBytes 8MB
    if (-not $current.Success -and $target -eq 'air') { return @{ ok = $false; error = 'content_unreadable' } }
    $before = if ($target -eq 'air') { @($current.Items) } else { @($draft.Items) }
    $summary = Get-NewsSheetChangeSummary -Before $before -After $parsed.Items
    $draftRevision = Get-NewsTickerDraftRevision -Draft $draft
    $reviewed = ConvertTo-Json -Compress -Depth 5 -InputObject @(
        'sheet', $actor, $target, $Admission.Url, $path, $current.Hash, $draftRevision, $separator, $limits.MaxItemLength, $limits.MaxItems, $parsed.Items
    )
    $token = Get-NewsTickerReviewToken $reviewed
    $scheduled = [bool](Get-NewsPublishAt -Draft $draft)
    if ($Admission.Action -eq 'preview') {
        return @{ ok = $true; data = @{
                review = $token; items = @($parsed.Items); currentItems = @($before)
                identical = -not $summary.Changed; cancelsSchedule = $scheduled
            } }
    }
    if ($token -cne [string](Get-JsonProp $Arguments 'review') -or -not $summary.Changed) {
        return @{ ok = $false; error = 'ticker_sheet_stale' }
    }
    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'ticker_sheet_unavailable' } }
    if ($target -eq 'draft') {
        if (-not (Set-NewsTickerDraftItems -Draft $draft -Items $parsed.Items -ClearSchedule)) {
            return @{ ok = $false; error = 'ticker_sheet_save_failed' }
        }
    }
    else {
        $plan = @{ Path = $path; ExpectedHash = $current.Hash; Limits = $limits; Preview = @{ items = $parsed.Items; cancelsSchedule = $scheduled } }
        $outcome = Invoke-NewsTickerReviewedPublish -Plan $plan -Actor $actor -SheetSummary $summary
        if ($outcome) {
            $failure = switch ($outcome) {
                'ticker_backup_stale' { 'ticker_sheet_stale' }
                'ticker_backup_schedule_cancelled' { 'ticker_sheet_schedule_cancelled' }
                default { 'ticker_sheet_save_failed' }
            }
            return @{ ok = $false; error = $failure }
        }
    }
    return @{ ok = $true; data = @{} }
}

function Invoke-WebTickerBackups {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-NewsTickerBackupAccess -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Get-Setting 'EnableNewsTickerManagement')) { return @{ ok = $false; error = 'content_disabled' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -notin 'list', 'preview', 'restore') { return @{ ok = $false; error = 'ticker_backup_invalid' } }
    $files = @(Get-NewsTickerBackupFiles)
    if ($action -eq 'list') {
        $page = [int](Get-JsonProp $Arguments 'page')
        $window = Get-BridgePageWindow -ItemCount $files.Count -Page $page -PageSize 8
        return @{ ok = $true; data = @{
                list = @{
                    total = $files.Count; page = $window.Page; pageCount = $window.PageCount
                    items = @(for ($row = $window.StartIndex; $row -le $window.EndIndex; $row++) {
                            $file = $files[$row]
                            @{ id = Get-NewsTickerReviewToken "file:$($file.FullName)"; savedAt = ([datetimeoffset]$file.LastWriteTimeUtc).ToUnixTimeMilliseconds() }
                        })
                }
            } }
    }

    $id = [string](Get-JsonProp $Arguments 'id')
    $backupFile = $files | Where-Object { (Get-NewsTickerReviewToken "file:$($_.FullName)") -ceq $id } | Select-Object -First 1
    if (-not $backupFile) { return @{ ok = $false; error = 'ticker_backup_stale' } }
    $plan = Get-NewsTickerBackupReview -File $backupFile -Actor $actor
    if (-not $plan) { return @{ ok = $false; error = 'ticker_backup_unreadable' } }
    if ($action -eq 'preview') { return @{ ok = $true; data = @{ preview = $plan.Preview } } }
    if ($plan.Preview.review -cne [string](Get-JsonProp $Arguments 'review') -or $plan.Preview.identical) {
        return @{ ok = $false; error = 'ticker_backup_stale' }
    }
    $outcome = Invoke-NewsTickerReviewedPublish -Plan $plan -Actor $actor
    if ($outcome) { return @{ ok = $false; error = $outcome } }
    return @{ ok = $true; data = @{} }
}

function Get-WebTickerSetsState {
    param([long]$Actor)
    $draft = Get-NewsTickerDraft -UserId $Actor
    return @{
        draftRevision = if ($draft) { Get-NewsTickerDraftRevision -Draft $draft } else { $null }
        maxSets = $script:NewsSetsMax
        items = @(for ($index = 0; $index -lt [math]::Min($script:NewsSets.Count, $script:NewsSetsMax); $index++) {
                $set = $script:NewsSets[$index]
                @{
                    index = $index; name = Get-NewsScreenLine -Text ([string]$set.Name) -Length 40
                    revision = Get-NewsSetRevision -Set $set; count = @($set.Items).Count
                    canManage = Test-NewsSetManageAccess -Set $set -ChatId $Actor -UserId $Actor
                }
            })
    }
}

function Invoke-WebTickerSets {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Get-Setting 'EnableNewsTickerManagement')) { return @{ ok = $false; error = 'content_disabled' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'status') { return @{ ok = $true; data = Get-WebTickerSetsState -Actor $actor } }
    if ($action -notin 'save', 'replace', 'load', 'delete') { return @{ ok = $false; error = 'ticker_set_invalid' } }

    if ($action -ne 'delete') {
        $draft = Get-NewsTickerDraft -UserId $actor
        if (-not $draft -or (Test-NewsTickerDraftOpen -Draft $draft)) { return @{ ok = $false; error = 'ticker_locked' } }
        if ((Get-NewsTickerDraftRevision -Draft $draft) -cne [string](Get-JsonProp $Arguments 'draftRevision')) {
            return @{ ok = $false; error = 'ticker_stale' }
        }
        if ($action -in 'save', 'replace' -and @($draft.Items).Count -eq 0) { return @{ ok = $false; error = 'ticker_set_invalid' } }
    }
    if ($action -eq 'save') {
        $name = Get-NormalizedNewsSetName -Name ([string](Get-JsonProp $Arguments 'name'))
        if (-not $name) { return @{ ok = $false; error = 'ticker_set_invalid' } }
        if (@($script:NewsSets | Where-Object { $_.Name -ceq $name }).Count) { return @{ ok = $false; error = 'ticker_set_exists' } }
        if ($script:NewsSets.Count -ge $script:NewsSetsMax) { return @{ ok = $false; error = 'ticker_set_full' } }
        $saved = Save-NewsSetFromDraft -UserId $actor -Name $name
    }
    else {
        $rawIndex = Get-JsonProp $Arguments 'index'
        if (($rawIndex -isnot [int] -and $rawIndex -isnot [long]) -or $rawIndex -lt 0 -or $rawIndex -ge [math]::Min($script:NewsSetsMax, $script:NewsSets.Count)) {
            return @{ ok = $false; error = 'ticker_set_stale' }
        }
        $index = [int]$rawIndex
        $set = $script:NewsSets[$index]
        if ((Get-NewsSetRevision -Set $set) -cne [string](Get-JsonProp $Arguments 'revision')) { return @{ ok = $false; error = 'ticker_set_stale' } }
        if ($action -ne 'load' -and -not (Test-NewsSetManageAccess -Set $set -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
        switch ($action) {
            'replace' { $saved = Save-NewsSetFromDraft -UserId $actor -Name ([string]$set.Name) -ReplaceIndex $index }
            'load' { $saved = Use-NewsSet -UserId $actor -Index $index }
            'delete' {
                $saved = Remove-NewsSet -ChatId $actor -UserId $actor -Index $index
            }
        }
    }
    if (-not $saved) { return @{ ok = $false; error = 'ticker_set_save_failed' } }
    return @{ ok = $true; data = Get-WebTickerSetsState -Actor $actor }
}

function Get-WebTickerLockState {
    param([long]$Actor, $Draft)
    if (-not $Draft -or (Test-NewsTickerDraftOpen -Draft $Draft)) { return $null }
    $owner = [long](Get-JsonProp $Draft 'OwnerUserId')
    $request = $script:NewsLockRequest
    $pending = $request -and (Test-NewsLockRequestDraft -Request $request -Draft $Draft)
    if ($owner -eq $Actor -and -not $pending) { return $null }
    $waiting = $pending -and [long]$request.RequesterUserId -eq $Actor
    $canReply = $pending -and $owner -eq $Actor
    return @{
        revision = if ($owner -ne $Actor) { Get-NewsTickerDraftRevision -Draft $Draft } else { $null }
        canRequest = $owner -gt 0 -and $owner -ne $Actor -and -not $pending
        canForce = $owner -ne $Actor -and (Test-Admin -ChatId $Actor -UserId $Actor)
        waiting = $waiting
        preservesAtDeadline = $canReply -and [bool](Get-JsonProp $request 'PreserveDraft')
        response = if ($canReply) { [string](Get-JsonProp $request 'Id') } else { $null }
        requester = if ($canReply) { Get-NewsScreenLine (Get-UserDisplayName -UserId ([long]$request.RequesterUserId)) 64 } else { $null }
        expiresAt = if ($waiting -or $canReply) { ([datetimeoffset]$request.RequestedAt).AddMinutes((Get-SettingInt 'NewsLockRequestMinutes' 1)).ToString('o') } else { $null }
    }
}

function Get-WebTickerEditorState {
    param([Parameter(Mandatory)][long]$Actor, [int]$PausedPage = 1)
    $draft = Get-NewsTickerDraft
    $data = @{
        state = 'available'; draft = $null; owner = ''; maxItemLength = Get-SettingInt 'NewsMaxItemLength' 1
        canRestore = Test-NewsTickerBackupAccess -ChatId $Actor -UserId $Actor
        canPullSheet = $false
        lock = Get-WebTickerLockState -Actor $Actor -Draft $draft
    }
    if ($draft -and -not (Test-NewsTickerDraftOpen -Draft $draft)) {
        $owner = [long](Get-JsonProp $draft 'OwnerUserId')
        $isOwner = $owner -eq $Actor
        $shareId = [string](Get-JsonProp $draft 'WebShareId')
        $shared = $owner -gt 0 -and $shareId -cmatch '^[a-f0-9]{32}$'
        if (-not $isOwner -and -not $shared) {
            $data.state = 'locked'
            if ($owner -gt 0) { $data.owner = Get-NewsScreenLine (Get-UserDisplayName -UserId $owner) 64 }
        }
        else {
            $data.state = 'editing'
            $data.canPullSheet = $isOwner -and [bool](Get-Setting 'NewsSheetCsvUrl') -and (Test-NewsSheetPullAccess -ChatId $Actor -UserId $Actor)
            $pausedTotal = if ($isOwner) { $script:NewsPaused.Count } else { 0 }
            $window = Get-BridgePageWindow -ItemCount $pausedTotal -Page ([math]::Max(1, $PausedPage) - 1) -PageSize 10
            $pausedItems = @(for ($pausedIndex = $window.StartIndex; $pausedIndex -le $window.EndIndex; $pausedIndex++) {
                    $script:NewsPaused[$pausedIndex]
                })
            $data.draft = @{
                revision = Get-NewsTickerDraftRevision -Draft $draft
                items = @(Get-JsonProp $draft 'Items' | Where-Object { $null -ne $_ })
                scheduledAt = Get-NewsPublishAt -Draft $draft
                canRemove = $isOwner -and (Test-NewsTickerDeleteAccess -ChatId $Actor -UserId $Actor)
                canClear = $isOwner -and (Test-NewsTickerClearAccess -ChatId $Actor -UserId $Actor)
                maxItems = Get-SettingInt 'NewsMaxItems' 1
                paused = @{ items = $pausedItems; page = $window.Page + 1; pageCount = $window.PageCount; total = $pausedTotal; offset = $window.StartIndex }
            }
            if ($shared) {
                $data.draft.sharedDraftKey = $shareId
                $data.draft.rowKeys = @(Get-JsonProp $draft 'WebRowKeys')
                $data.draft.canManage = $isOwner
                if (-not $isOwner) {
                    $data.lock = $null
                    $data.owner = Get-NewsScreenLine (Get-UserDisplayName -UserId $owner) 64
                }
            }
        }
        return $data
    }
    $reservation = Get-NewsLockReservation
    if ($reservation -and [long]$reservation.UserId -ne $Actor) {
        $data.state = 'locked'
        $data.owner = Get-NewsScreenLine (Get-UserDisplayName -UserId ([long]$reservation.UserId)) 64
    }
    elseif ($draft) { $data.state = 'open' }
    return $data
}

function Get-WebTickerTxtAdmission {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Get-Setting 'EnableNewsTickerManagement')) { return @{ ok = $false; error = 'content_disabled' } }
    $draft = Get-NewsTickerDraft -UserId $actor
    if (-not $draft -or (Test-NewsTickerDraftOpen -Draft $draft)) { return @{ ok = $false; error = 'ticker_locked' } }
    $revision = Get-NewsTickerDraftRevision -Draft $draft
    if ($revision -cne [string](Get-JsonProp $Arguments 'revision')) { return @{ ok = $false; error = 'ticker_stale' } }
    return @{ ok = $true; actor = $actor; draft = $draft; revision = $revision }
}

function Get-WebTickerTxtLimits {
    return @{
        Separator = [string](Get-Setting 'NewsItemSeparator')
        MaximumBytes = Get-SettingInt 'NewsImportMaxBytes' 1
        MaxItemLength = Get-SettingInt 'NewsMaxItemLength' 1
        MaxItems = Get-SettingInt 'NewsMaxItems' 1
    }
}

function Start-WebTickerTxtRequest {
    param([Parameter(Mandatory)][hashtable]$Entry)
    $arguments = Get-JsonProp $Entry.Request 'args'
    if ($arguments -isnot [System.Collections.IDictionary]) { return @{ ok = $false; error = 'ticker_txt_invalid' } }
    $admission = Get-WebTickerTxtAdmission -Arguments $arguments
    if (-not $admission.ok) { return $admission }
    $action = [string](Get-JsonProp $arguments 'action')
    $maximum = Get-SettingInt 'NewsImportMaxBytes' 1
    if ($action -eq 'prepare') {
        return @{ ok = $true; data = @{ directory = $script:newsImportDirectory; maximumBytes = $maximum } }
    }
    $upload = [string](Get-JsonProp $Arguments 'upload')
    if ($action -notin 'preview', 'apply' -or $upload -cnotmatch '^[a-f0-9]{32}$') { return @{ ok = $false; error = 'ticker_txt_invalid' } }
    if ($script:WebTickerTxtRequest) { return @{ ok = $false; error = 'ticker_txt_busy' } }
    $path = Join-Path $script:newsImportDirectory "web-$upload.txt"
    $file = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $file -or $file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return @{ ok = $false; error = 'ticker_txt_invalid' }
    }
    if ($file.Length -gt $maximum) { return @{ ok = $false; error = 'ticker_txt_size' } }
    $limits = Get-WebTickerTxtLimits
    if (-not $limits.Separator) { return @{ ok = $false; error = 'ticker_txt_invalid' } }
    # Decoding the upload can outlast a playout tick. The worker reads only
    # the staged file and settings snapshot; the bridge still owns all writes.
    $pipeline = [powershell]::Create()
    try {
        $pipeline.AddCommand('Import-Module').AddParameter('Name', $script:WebTickerTxtModule).AddParameter('ErrorAction', 'Stop').AddStatement().AddCommand('Get-NewsTickerSnapshot').AddParameters($limits).AddParameter('Path', $path).AddParameter('SharedUpload') | Out-Null
        $invocation = $pipeline.BeginInvoke()
        $script:WebTickerTxtRequest = @{ Entry = $Entry; Arguments = $arguments; Limits = $limits; Pipeline = $pipeline; Invocation = $invocation; Stopping = $false }
    }
    catch {
        $pipeline.Dispose()
        return @{ ok = $false; error = 'ticker_txt_save_failed' }
    }
}

function Update-WebTickerTxtRequest {
    $pending = $script:WebTickerTxtRequest
    if (-not $pending) { return }
    $expired = [Diagnostics.Stopwatch]::GetTimestamp() -ge $pending.Entry.Deadline
    if ($expired -and -not $pending.Stopping) {
        $pending.Stopping = $true
        [void]$pending.Entry.Reply.TrySetResult('{"ok":false,"error":"ticker_txt_timeout"}')
        if (-not $pending.Invocation.IsCompleted) {
            try { [void]$pending.Pipeline.BeginStop($null, $null) }
            catch { Write-BridgeLog 'The ticker TXT worker ended while cancellation was requested.' 'DEBUG' }
        }
    }
    if (-not $pending.Invocation.IsCompleted) { return }
    $script:WebTickerTxtRequest = $null
    try {
        if ($pending.Stopping) { return }
        $result = @($pending.Pipeline.EndInvoke($pending.Invocation))
        $answer = if ($result.Count -eq 1) { Complete-WebTickerTxtRequest -Pending $pending -Snapshot $result[0] }
                  else { @{ ok = $false; error = 'ticker_txt_invalid' } }
        [void]$pending.Entry.Reply.TrySetResult(($answer | ConvertTo-Json -Compress -Depth 6))
    }
    catch {
        [void]$pending.Entry.Reply.TrySetResult('{"ok":false,"error":"ticker_txt_invalid"}')
    }
    finally { $pending.Pipeline.Dispose() }
}

function Complete-WebTickerTxtRequest {
    param([hashtable]$Pending, $Snapshot)
    $admission = Get-WebTickerTxtAdmission -Arguments $Pending.Arguments
    if (-not $admission.ok) { return $admission }
    $limits = Get-WebTickerTxtLimits
    foreach ($key in $limits.Keys) {
        if ($limits[$key] -cne $Pending.Limits[$key]) { return @{ ok = $false; error = 'ticker_stale' } }
    }
    $draft = $admission.draft
    $actor = $admission.actor
    $action = [string](Get-JsonProp $Pending.Arguments 'action')
    if (-not $snapshot.Success -or -not $snapshot.Exists) { return @{ ok = $false; error = 'ticker_txt_invalid' } }
    if (-not $snapshot.Items.Count) { return @{ ok = $false; error = 'ticker_txt_empty' } }
    $items = ConvertTo-Json -Compress -InputObject @($snapshot.Items)
    $identical = $items -ceq (ConvertTo-Json -Compress -InputObject @($draft.Items))
    $token = Get-NewsTickerReviewToken (ConvertTo-Json -Compress -Depth 4 -InputObject @('ticker-txt', $actor, $admission.revision, $snapshot.Hash, $limits.Separator, $items))
    if ($action -eq 'preview') {
        return @{ ok = $true; data = @{
                review = $token; items = @($snapshot.Items); currentItems = @($draft.Items); duplicates = $snapshot.DuplicateCount
                identical = $identical; cancelsSchedule = -not $identical -and $null -ne (Get-NewsPublishAt -Draft $draft)
            } }
    }
    if ($token -cne [string](Get-JsonProp $Pending.Arguments 'review')) { return @{ ok = $false; error = 'ticker_stale' } }
    if ([Diagnostics.Stopwatch]::GetTimestamp() -ge $Pending.Entry.Deadline) { return @{ ok = $false; error = 'ticker_txt_timeout' } }
    if (-not $identical -and -not (Set-NewsTickerDraftItems -Draft $draft -Items $snapshot.Items -ClearSchedule)) {
        return @{ ok = $false; error = 'ticker_txt_save_failed' }
    }
    if (-not $identical) { Add-AuditEntry "Web ticker TXT imported by $(Format-UserAuditActor -UserId $actor)" }
    return @{ ok = $true }
}

function Invoke-WebTickerPaste {
    param([long]$Actor, [System.Collections.IDictionary]$Draft, [System.Collections.IDictionary]$Arguments, [int]$PausedPage)
    $copy = [string](Get-JsonProp $Arguments 'text')
    if ([string]::IsNullOrWhiteSpace($copy) -or $copy.Length -gt 8000) { return @{ ok = $false; error = 'ticker_paste_invalid' } }
    $separator = [string](Get-Setting 'NewsItemSeparator')
    if (-not $separator -or $copy.Contains($separator, [StringComparison]::Ordinal)) {
        return @{ ok = $false; error = 'ticker_paste_separator' }
    }
    $parsed = Get-NewsPasteParse -Text $copy
    foreach ($item in $parsed.Items) {
        if ($item.Contains($separator, [StringComparison]::Ordinal)) { return @{ ok = $false; error = 'ticker_paste_separator' } }
    }
    $plan = Get-NewsPastePlan -UserId $Actor -Items $parsed.Items
    $atTop = [bool](Get-Setting 'NewNewsItemAtTop')
    $duplicates = $parsed.DuplicateCount + $plan.AlreadyInDraft
    $tooLong = @($parsed.TooLong).Count
    $reviewed = ConvertTo-Json -Compress -Depth 4 -InputObject @(
        'ticker-paste', $Actor, (Get-NewsTickerDraftRevision -Draft $Draft), $atTop, $plan.New, $duplicates, $tooLong, $plan.NoRoom
    )
    $token = Get-NewsTickerReviewToken $reviewed
    if ((Get-JsonProp $Arguments 'action') -eq 'preview_paste') {
        $state = Get-WebTickerEditorState -Actor $Actor -PausedPage $PausedPage
        $state.paste = @{
            review = $token; items = @($plan.New); duplicates = $duplicates; tooLong = $tooLong; noRoom = $plan.NoRoom; atTop = $atTop
        }
        return @{ ok = $true; data = $state }
    }
    if ($token -cne [string](Get-JsonProp $Arguments 'review')) { return @{ ok = $false; error = 'ticker_stale' } }
    if (-not $plan.New.Count) { return @{ ok = $false; error = 'ticker_paste_invalid' } }
    if ((Add-NewsTickerDraftItems -UserId $Actor -Items $plan.New) -ne $plan.New.Count) {
        return @{ ok = $false; error = 'ticker_invalid' }
    }
    return @{ ok = $true; data = Get-WebTickerEditorState -Actor $Actor -PausedPage $PausedPage }
}

function Invoke-WebTickerLock {
    param([long]$Actor, [System.Collections.IDictionary]$Arguments, [int]$PausedPage)
    $action = [string](Get-JsonProp $Arguments 'action')
    $draft = Get-NewsTickerDraft
    if ($action -eq 'force_release' -and -not (Test-Admin -ChatId $Actor -UserId $Actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    if (-not $draft -or (Test-NewsTickerDraftOpen -Draft $draft)) { return @{ ok = $false; error = 'ticker_stale' } }
    $owner = [long](Get-JsonProp $draft 'OwnerUserId')
    $request = $script:NewsLockRequest
    if ($action -in 'approve_lock', 'deny_lock') {
        if ($Actor -ne $owner) { return @{ ok = $false; error = 'forbidden' } }
        $replyTo = [string](Get-JsonProp $Arguments 'review')
        if ($replyTo -cnotmatch '^[a-f0-9]{32}$' -or -not $request -or
            -not (Test-NewsLockRequestDraft -Request $request -Draft $draft) -or
            [string](Get-JsonProp $request 'Id') -cne $replyTo) {
            return @{ ok = $false; error = 'ticker_stale' }
        }
        if ($action -eq 'deny_lock') {
            Complete-NewsLockRelease -Denied | Out-Null
            $saved = -not $script:NewsLockRequest
        }
        else {
            if (-not (Test-NewsLockRequesterAuthorized -Request $request)) {
                Complete-NewsLockRelease -Denied | Out-Null
                return @{ ok = $false; error = 'ticker_stale' }
            }
            $saved = Open-NewsTickerDraftToAll -ChatId $Actor -UserId $Actor
        }
    }
    else {
        if ($owner -le 0 -or $owner -eq $Actor -or
            (Get-NewsTickerDraftRevision -Draft $draft) -cne [string](Get-JsonProp $Arguments 'revision')) {
            return @{ ok = $false; error = 'ticker_stale' }
        }
        if ($action -eq 'force_release') {
            $saved = Open-NewsTickerDraftToAll -ChatId $Actor -UserId $Actor -Force
        }
        else {
            if ($request -and (Test-NewsLockRequestDraft -Request $request -Draft $draft) -and [long]$request.RequesterUserId -ne $Actor) {
                return @{ ok = $false; error = 'ticker_lock_pending' }
            }
            $saved = Request-NewsLockRelease -ChatId $Actor -UserId $Actor -FromWeb
        }
    }
    if (-not $saved) { return @{ ok = $false; error = 'ticker_lock_save_failed' } }
    return @{ ok = $true; data = Get-WebTickerEditorState -Actor $Actor -PausedPage $PausedPage }
}

function Invoke-WebSharedTickerContribution {
    param([long]$Actor, [System.Collections.IDictionary]$Draft, [System.Collections.IDictionary]$Arguments, [int]$PausedPage)
    $review = [string](Get-JsonProp $Arguments 'review')
    if ($review -cnotmatch '^[a-f0-9]{32}$') { return @{ ok = $false; error = 'ticker_stale' } }
    $copy = [string](Get-JsonProp $Arguments 'text')
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'add') {
        if ($review -cne (Get-JsonProp $Draft 'WebShareId')) { return @{ ok = $false; error = 'ticker_stale' } }
        if (@($Draft.Items).Count -ge (Get-SettingInt 'NewsMaxItems' 1)) { return @{ ok = $false; error = 'ticker_full' } }
        $saved = Add-NewsTickerDraftItem -UserId $Actor -Text $copy -Draft $Draft -SkipDuplicate
    }
    else {
        $index = [Array]::IndexOf([string[]]@(Get-JsonProp $Draft 'WebRowKeys'), $review)
        if ($index -lt 0) { return @{ ok = $false; error = 'ticker_stale' } }
        $saved = Update-NewsTickerDraftItem -UserId $Actor -Index $index -Text $copy -Draft $Draft
    }
    if (-not $saved) { return @{ ok = $false; error = 'ticker_invalid' } }
    Add-AuditEntry "Web ticker shared headline ($action) by $(Format-UserAuditActor -UserId $Actor)"
    return @{ ok = $true; data = Get-WebTickerEditorState -Actor $Actor -PausedPage $PausedPage }
}

function Invoke-WebTickerEdit {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Get-Setting 'EnableNewsTickerManagement')) { return @{ ok = $false; error = 'content_disabled' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    $pausedPage = [int](Get-JsonProp $Arguments 'pausedPage')
    if ($action -eq 'status') { return @{ ok = $true; data = Get-WebTickerEditorState -Actor $actor -PausedPage $pausedPage } }
    if ($action -in 'request_lock', 'approve_lock', 'deny_lock', 'force_release') {
        return Invoke-WebTickerLock -Actor $actor -Arguments $Arguments -PausedPage $pausedPage
    }
    if ($action -in 'start', 'start_shared') {
        $state = Get-WebTickerEditorState -Actor $actor
        if ($state.state -eq 'locked') { return @{ ok = $false; error = 'ticker_locked' } }
        if ($state.state -eq 'editing' -and $action -eq 'start_shared') {
            if (Get-JsonProp $state.draft 'sharedDraftKey') { return @{ ok = $true; data = $state } }
            return @{ ok = $false; error = 'ticker_stale' }
        }
        $started = Start-NewsTickerDraft -ChatId $actor -UserId $actor -ShareOnWeb:($action -eq 'start_shared')
        if (-not $started.Success) { return @{ ok = $false; error = 'ticker_start_failed' } }
        return @{ ok = $true; data = Get-WebTickerEditorState -Actor $actor }
    }

    $draft = Get-NewsTickerDraft
    if (-not $draft -or (Test-NewsTickerDraftOpen -Draft $draft)) { return @{ ok = $false; error = 'ticker_locked' } }
    $isOwner = [long](Get-JsonProp $draft 'OwnerUserId') -eq $actor
    $shareId = [string](Get-JsonProp $draft 'WebShareId')
    if ($shareId -cmatch '^[a-f0-9]{32}$' -and $action -in 'add', 'update' -and
        (-not $isOwner -or (Get-JsonProp $Arguments 'review'))) {
        if (-not $isOwner -and (Get-NewsPublishAt -Draft $draft)) { return @{ ok = $false; error = 'ticker_scheduled_readonly' } }
        return Invoke-WebSharedTickerContribution -Actor $actor -Draft $draft -Arguments $Arguments -PausedPage $pausedPage
    }
    if (-not $isOwner) { return @{ ok = $false; error = 'ticker_locked' } }
    if ((Get-NewsTickerDraftRevision -Draft $draft) -cne [string](Get-JsonProp $Arguments 'revision')) {
        return @{ ok = $false; error = 'ticker_stale' }
    }
    if ($action -eq 'share') {
        if ($script:NewsLockRequest -and (Test-NewsLockRequestDraft -Request $script:NewsLockRequest -Draft $draft)) {
            return @{ ok = $false; error = 'ticker_lock_pending' }
        }
        if (-not (Enable-NewsTickerWebSharing -UserId $actor)) { return @{ ok = $false; error = 'ticker_lock_save_failed' } }
        return @{ ok = $true; data = Get-WebTickerEditorState -Actor $actor -PausedPage $pausedPage }
    }
    if ($action -in 'preview_paste', 'apply_paste') {
        return Invoke-WebTickerPaste -Actor $actor -Draft $draft -Arguments $Arguments -PausedPage $pausedPage
    }
    if ($action -eq 'review_conflict') {
        $live = Get-NewsTickerConfiguredSnapshot
        if (-not $live.Success) { return @{ ok = $false; error = 'content_unreadable' } }
        $state = Get-WebTickerEditorState -Actor $actor
        $state.conflict = @{ review = [string]$live.Hash; items = @($live.Items) }
        return @{ ok = $true; data = $state }
    }
    if ($action -in 'publish', 'append', 'replace') {
        if ($action -eq 'publish') { $result = Publish-NewsTickerDraft -UserId $actor }
        else {
            $review = Get-JsonProp $Arguments 'review'
            if ($null -eq $review) { return @{ ok = $false; error = 'ticker_conflict' } }
            $result = Resolve-NewsPublishConflict -UserId $actor -Mode $action -ExpectedHash ([string]$review)
        }
        if (-not $result.Success) {
            if ($result.Conflict) { return @{ ok = $false; error = 'ticker_conflict' } }
            return @{ ok = $false; error = 'ticker_publish_failed' }
        }
        $state = Get-WebTickerEditorState -Actor $actor
        $state.sheetFailed = [bool](Get-JsonProp $result 'SheetAttempted') -and -not [bool](Get-JsonProp $result 'SheetSaved')
        return @{ ok = $true; data = $state }
    }

    $rawIndex = Get-JsonProp $Arguments 'index'
    $index = if ($null -eq $rawIndex) { -1 } else { [int]$rawIndex }
    $copy = [string](Get-JsonProp $Arguments 'text')
    $saved = $false
    switch ($action) {
        'add' {
            if (@($draft.Items).Count -ge (Get-SettingInt 'NewsMaxItems' 1)) { return @{ ok = $false; error = 'ticker_full' } }
            $saved = Add-NewsTickerDraftItem -UserId $actor -Text $copy
        }
        'update' { $saved = Update-NewsTickerDraftItem -UserId $actor -Index $index -Text $copy }
        'remove' {
            if (-not (Test-NewsTickerDeleteAccess -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
            $saved = Remove-NewsTickerDraftItem -ChatId $actor -UserId $actor -Index $index
        }
        'clear' {
            if (-not (Test-NewsTickerClearAccess -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
            $saved = Clear-NewsTickerDraftItems -ChatId $actor -UserId $actor
            if ($saved) { Add-AuditEntry "Web ticker draft cleared by $(Format-UserAuditActor -UserId $actor)" }
        }
        'discard' {
            $saved = Remove-NewsTickerDraft -RequireRemoved
            if ($saved) {
                Resolve-NewsLockRequestOnRelease -Draft $draft -Text (T 'news.youMayEdit' '') | Out-Null
                Add-AuditEntry "Web ticker draft discarded by $(Format-UserAuditActor -UserId $actor)"
            }
        }
        'up' { $saved = Move-NewsTickerDraftItem -UserId $actor -Index $index -Delta -1 }
        'down' { $saved = Move-NewsTickerDraftItem -UserId $actor -Index $index -Delta 1 }
        'move' {
            $destination = Get-JsonProp $Arguments 'destination'
            if (($destination -isnot [int] -and $destination -isnot [long]) -or $destination -lt 0 -or $destination -ge @($draft.Items).Count) {
                return @{ ok = $false; error = 'ticker_invalid' }
            }
            $saved = Set-NewsTickerDraftItemPosition -UserId $actor -Index $index -Destination ([int]$destination)
        }
        'pause' { $saved = Suspend-NewsTickerDraftItem -UserId $actor -Index $index }
        'resume' {
            if ($index -lt 0 -or $index -ge $script:NewsPaused.Count -or
                -not [string]::Equals($script:NewsPaused[$index], $copy, [StringComparison]::Ordinal)) {
                return @{ ok = $false; error = 'ticker_stale' }
            }
            if (@($draft.Items).Count -ge (Get-SettingInt 'NewsMaxItems' 1) -and [Array]::IndexOf([string[]]@($draft.Items), $copy) -lt 0) {
                return @{ ok = $false; error = 'ticker_full' }
            }
            $saved = Resume-NewsPausedItem -UserId $actor -Index $index
        }
        'schedule' {
            $stamp = Get-JsonProp $Arguments 'publishAtMs'
            if ($stamp -isnot [int] -and $stamp -isnot [long]) { return @{ ok = $false; error = 'ticker_schedule_invalid' } }
            try { $at = [datetimeoffset]::FromUnixTimeMilliseconds($stamp) }
            catch { return @{ ok = $false; error = 'ticker_schedule_invalid' } }
            if ($at -le [datetimeoffset]::UtcNow) { return @{ ok = $false; error = 'ticker_schedule_invalid' } }
            $saved = Set-NewsPublishAt -UserId $actor -At $at
        }
        'unschedule' { $saved = Clear-NewsPublishAt -UserId $actor }
        'handover' { $saved = Open-NewsTickerDraftToAll -ChatId $actor -UserId $actor }
        default { return @{ ok = $false; error = 'ticker_invalid' } }
    }
    if (-not $saved) { return @{ ok = $false; error = 'ticker_invalid' } }
    return @{ ok = $true; data = Get-WebTickerEditorState -Actor $actor -PausedPage $pausedPage }
}

function Get-WebUrgentRun {
    $run = $script:UrgentBoardRun
    if (-not $run) { return $null }
    $steps = @(Get-JsonProp $run 'Steps')
    $step = [int](Get-JsonProp $run 'Step')
    $state = if (Get-JsonProp $run 'StopFailed') { 'stop_unconfirmed' }
        elseif (Get-JsonProp $run 'Paused') { 'paused' }
        else { 'playing' }
    return @{
        id = [string](Get-JsonProp $run 'OperationId')
        state = $state
        step = $step
        stepCount = $steps.Count
        current = if ($step -ge 0 -and $step -lt $steps.Count) { Get-NewsScreenLine ([string](Get-JsonProp $steps[$step] 'Text')) 160 } else { '' }
        next = if ($step + 1 -lt $steps.Count) { Get-NewsScreenLine ([string](Get-JsonProp $steps[$step + 1] 'Text')) 160 } else { '' }
    }
}

function Get-WebLayerStatus {
    param([int]$Layer, [int]$TimeoutSec = 0, [switch]$RequireConsistentIdentity)
    if ($TimeoutSec -le 0) { $TimeoutSec = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1 }
    return Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $Layer -TimeoutSec $TimeoutSec -RequireConsistentIdentity:$RequireConsistentIdentity
}

$script:WebLayerComparisonNextProbe = 0L

function Get-WebLayerComparison {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-LayersScreenAccess -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    # Include tracked layers whose template was removed. The native comparison
    # discovers external scenes on configured layers and rechecks orphan records.
    $known = @((@(Get-KnownLayers) + @($script:OnAir.Keys)) | ForEach-Object { [int]$_ } |
        Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    $requested = Get-JsonProp $Arguments 'layer'
    if ($null -eq $requested) {
        return @{ ok = $true; data = @{ layers = @(
            foreach ($layer in $known) { @{ layer = $layer; name = Get-WebLayerNameSafe -Layer $layer } }
        ) } }
    }
    $layer = 0
    if (-not [int]::TryParse([string]$requested, [ref]$layer) -or $layer -notin $known) {
        return @{ ok = $false; error = 'layer_comparison_missing' }
    }
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($Deadline -gt 0 -and $now -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    if ($now -lt $script:WebLayerComparisonNextProbe) { return @{ ok = $false; error = 'layer_comparison_busy' } }
    try {
        # This optional diagnostic must not delay the playout loop by a full
        # station sweep. It performs one bounded status request per inspection.
        $status = Get-WebLayerStatus -Layer $layer -TimeoutSec 2
    }
    finally {
        $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency
    }

    $tracked = $script:OnAir[$layer]
    $active = Get-JsonProp $status 'IsOnAir'
    $disposition = 'failed'
    if ((Get-JsonProp $status 'Success') -eq $true -and $active -is [bool]) {
        # Use the pure decision, never the reconciliation executor. The latter
        # can restore urgent board playout when an active layer goes empty.
        $decision = Resolve-BridgeCinegyLayerState -Layer $layer -TrackedRecord $tracked -Status $status -DiscoverExternal
        $disposition = $decision.Action
    }
    else { $active = $null }
    $trackedId = ([string](Get-JsonProp $tracked 'ActiveId')).Trim().Trim('{', '}')
    $reportedId = ([string](Get-JsonProp $status 'ActiveId')).Trim().Trim('{', '}')
    $canReviewReplace = $disposition -ceq 'update' -and (Get-JsonProp $tracked 'Source') -ceq 'cinegy' -and
        -not (Get-JsonProp $tracked 'ActiveIdConfirmed') -and $trackedId -and $reportedId -and $trackedId -ne $reportedId
    $canReviewForget = $disposition -ceq 'remove' -and (Get-JsonProp $tracked 'Source') -ceq 'cinegy' -and
        $null -ne (Get-WebExplicitCinegyFiller -Status $status)
    return @{ ok = $true; data = @{
        layer = $layer; tracked = $null -ne $tracked; engineActive = $active; canReviewForget = $canReviewForget; canReviewReplace = [bool]$canReviewReplace
        disposition = $disposition; observedAt = [datetimeoffset]::UtcNow.ToUnixTimeMilliseconds()
    } }
}

$script:WebLayerAdoptionReviews = @{}

function Get-WebLocalLayerReviewDevice {
    param([int]$Layer, [switch]$AllowTracked)
    if ($Layer -notin @(Get-KnownLayers) -or (Get-Setting 'SceneMode') -ne 'Single' -or
        (Test-AirRunActive) -or $script:BoardsLive.Count -gt 0 -or $script:UrgentManualLive.Count -gt 0 -or
        @($script:AutoHideQueue | Where-Object Layer -EQ $Layer).Count -gt 0 -or
        @($script:TemplateReminderQueue | Where-Object Layer -EQ $Layer).Count -gt 0) { return '' }
    if (-not $AllowTracked -and ($script:OnAir.ContainsKey($Layer) -or
            @($script:OnAirScenes | Where-Object Layer -EQ $Layer).Count -gt 0)) { return '' }

    $device = [string](Resolve-AirGfxDevice -Layer $Layer).StatusPath
    if ($device -cnotmatch '^gfx_[a-z0-9_]{1,32}$') { return '' }
    $testLayer = Get-SettingInt 'TemplateTestLayer' 0
    if ($testLayer -gt 0 -and (Resolve-AirGfxDevice -Layer $testLayer).StatusPath -ceq $device) { return '' }
    foreach ($other in @(Get-KnownLayers; $script:OnAir.Keys)) {
        if ($other -gt 0 -and $other -ne $Layer -and (Resolve-AirGfxDevice -Layer ([int]$other)).StatusPath -ceq $device) { return '' }
    }
    return $device
}

function Get-WebExternalLayerAdoptionRecord {
    param([int]$Layer, [string]$Device, $Status)

    $decision = Resolve-BridgeCinegyLayerState -Layer $layer -Status $status -DiscoverExternal
    if ($decision.Action -cne 'add') { return }
    # Only use a current registered key. A raw engine item name may contain a
    # local path and the normal on-air projection is visible to web operators.
    $key = [string]$decision.Record.Key
    $registered = (Get-TemplateStore).Map[$key]
    if (-not $registered -or [int](Get-JsonProp $registered 'Layer') -ne $layer -or
        (Get-JsonProp $registered 'Key') -cne $key -or $key -in $script:MojazTemplateKey, $script:MojazUrgentKey -or
        (Get-JsonProp $registered 'Bulletin') -or (Test-PermanentGraphicAutoHideProtected -Key $key -Layer $layer) -or
        (Test-PermanentGraphicAutoHideProtected -Layer $layer)) { return }
    $declaredDevice = [string](Get-JsonProp $registered 'Device')
    if ($declaredDevice -and (Resolve-AirGfxDevice -Layer $layer -Device $declaredDevice).StatusPath -cne $device) {
        return
    }
    return @{ Key = $key; Record = $decision.Record; Definition = $registered; DeclaredDevice = $declaredDevice }
}

function Invoke-WebLayerAdoption {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline, [switch]$ApplyReview)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-LayersScreenAccess -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $layer = 0
    if (-not [int]::TryParse([string](Get-JsonProp $Arguments 'layer'), [ref]$layer) -or $layer -le 0) {
        return @{ ok = $false; error = 'layer_comparison_missing' }
    }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($Deadline -gt 0 -and $now -ge $Deadline) { return $busy }
    if ($now -lt $script:WebLayerComparisonNextProbe) { return @{ ok = $false; error = 'layer_comparison_busy' } }
    $unavailable = @{ ok = $false; error = if ($ApplyReview) { 'layer_adoption_stale' } else { 'layer_adoption_unavailable' } }
    $approval = if ($ApplyReview) {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebLayerAdoptionReviews
    }
    if ($ApplyReview -and (-not $approval -or $approval.Layer -ne $layer)) { return $unavailable }
    $device = Get-WebLocalLayerReviewDevice -Layer $layer
    $disk = Get-OnAirDiscoveryDiskRevision
    if (-not $device -or -not $disk -or ($ApplyReview -and $approval.Disk -cne $disk)) { return $unavailable }

    try {
        $status = Get-WebLayerStatus -Layer $layer -TimeoutSec 2
    }
    finally {
        $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $stamp = Get-CinegyLayerReviewStamp -Status $status
    $activeEventId = [guid]::Empty
    if ($stamp -cnotmatch '^active:(.+)$' -or -not [guid]::TryParse($Matches[1], [ref]$activeEventId) -or $activeEventId -eq [guid]::Empty) {
        return $unavailable
    }
    $started = Get-CinegyStatusStartTicks -Status $status
    if ($started -le 0) { return $unavailable }
    $adoption = Get-WebExternalLayerAdoptionRecord -Layer $layer -Device $device -Status $status
    if (-not $adoption) { return $unavailable }
    $key = $adoption.Key
    $declaredDevice = $adoption.DeclaredDevice
    if (-not (Test-TemplateAccess -Key $key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $fingerprint = ConvertTo-Json -Compress -InputObject @($layer, $device, $stamp, $started, $key, $declaredDevice, $disk,
        [string]$config.AirServerAddress, [int]$config.AirChannelNumber)
    if (-not $ApplyReview) {
        $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebLayerAdoptionReviews
        $review = $script:WebLayerAdoptionReviews[$actor]
        $review.Layer = $layer
        $review.Disk = $disk
        $maximumExpiry = [datetimeoffset]::UtcNow.AddMinutes(2)
        if ($review.ExpiresAt -gt $maximumExpiry) { $review.ExpiresAt = $maximumExpiry }
        return @{ ok = $true; data = @{ review = $token; layer = $layer; templateKey = $key } }
    }
    if ($approval.Fingerprint -cne $fingerprint) { return $unavailable }
    $remaining = ($approval.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
    if ($remaining -le 0) { return $unavailable }
    $writeDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
    if ($Deadline -gt 0) { $writeDeadline = [math]::Min($Deadline, $writeDeadline) }
    $adoption.Record.Remove('CinegyEventName')
    $result = Save-ReviewedOnAirDiscovery -Layer $layer -Record $adoption.Record -ExpectedDisk $disk -Deadline $writeDeadline
    if ($result -ceq 'stale') { return $unavailable }
    if ($result -ceq 'expired') { return $busy }
    if ($result -cne 'saved') { return @{ ok = $false; error = 'layer_adoption_save_failed' } }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ layer = $layer; adopted = $true } }
}

$script:WebLayerForgetReviews = @{}

function Get-WebExplicitCinegyFiller {
    param($Status)
    if ((Get-JsonProp $Status 'Success') -ne $true -or (Get-JsonProp $Status 'IsOnAir') -isnot [bool] -or
        (Get-JsonProp $Status 'IsOnAir') -or (Get-JsonProp $Status 'OffAirReason') -cne 'empty-item') { return }

    # Success and ActiveId from /status alone cannot establish which item
    # /status/active described if a scene changed between the two reads.
    try {
        $item = ([xml][string](Get-JsonProp $Status 'ActiveXml')).SelectSingleNode('/Item')
        if (-not $item -or $item.GetAttribute('IsEmpty') -notmatch '^(y|yes|true|1)$' -or
            -not $item.HasAttribute('ScheduledAt')) { return }
        $statusId = [guid]::Empty
        $itemId = [guid]::Empty
        if (-not [guid]::TryParse([string](Get-JsonProp $Status 'ActiveId'), [ref]$statusId) -or
            -not [guid]::TryParse($item.GetAttribute('Id'), [ref]$itemId) -or
            $itemId -eq [guid]::Empty -or $itemId -ne $statusId) { return }
        $started = Get-CinegyStatusStartTicks -Status $Status
        if ($started -gt 0) { return @{ Id = $itemId; Started = $started } }
    }
    catch { return }
}

function Get-WebExternalLayerForgetTarget {
    param([int]$Layer, [string]$Device)
    if ($script:LastSuccessfulLayerShows.ContainsKey($Layer) -or $script:RollbackCandidates.ContainsKey($Layer)) { return }
    $record = $script:OnAir[$Layer]
    $scenes = @($script:OnAirScenes | Where-Object Layer -EQ $Layer)
    if (-not $record -or $scenes.Count -ne 1 -or (Get-JsonProp $record 'Source') -cne 'cinegy' -or
        (Get-JsonProp $record 'ActiveIdConfirmed') -or (Get-JsonProp $record 'UserId') -gt 0 -or
        (Get-JsonProp $record 'ChatId') -gt 0 -or (Get-JsonProp $record 'AirCopy') -or
        $null -ne (Get-JsonProp $record 'Values')) { return }
    $scene = $scenes[0]
    $key = [string](Get-JsonProp $record 'Key')
    $recordEvent = [guid]::Empty
    if (-not $key -or $scene.Source -cne 'cinegy' -or $scene.Key -cne $key -or
        $scene.ActiveIdConfirmed -or $scene.UserId -ne 0 -or $scene.ChatId -ne 0 -or
        $scene.ActiveId -cne (Get-JsonProp $record 'ActiveId') -or
        -not [guid]::TryParse($scene.ActiveId, [ref]$recordEvent) -or $recordEvent -eq [guid]::Empty) { return }

    $store = Get-TemplateStore
    $definition = $store.Map[$key]
    if (-not $definition -or (Get-JsonProp $definition 'Key') -cne $key -or
        [int](Get-JsonProp $definition 'Layer') -ne $Layer -or $key -in $script:MojazTemplateKey, $script:MojazUrgentKey -or
        (Get-JsonProp $definition 'Bulletin') -or (Test-PermanentGraphicAutoHideProtected -Key $key -Layer $Layer) -or
        (Test-PermanentGraphicAutoHideProtected -Layer $Layer)) { return }
    foreach ($entry in $store.Map.Values) {
        $otherLayer = [int](Get-JsonProp $entry 'Layer')
        $declared = [string](Get-JsonProp $entry 'Device')
        if ($otherLayer -le 0 -or -not $declared) { continue }
        $sameDevice = (Resolve-AirGfxDevice -Layer $otherLayer -Device $declared).StatusPath -ceq $Device
        if ($sameDevice -ne ($otherLayer -eq $Layer)) { return }
    }

    $state = Read-ReviewedOnAirDocument
    if (-not $state -or $state.Revision -ceq 'missing') { return }
    $persisted = @($state.Scenes | Where-Object Layer -EQ $Layer)
    if ($persisted.Count -ne 1 -or $persisted[0].SceneId -cne $scene.SceneId -or $persisted[0].Key -cne $key -or
        $persisted[0].ActiveId -cne $scene.ActiveId -or $persisted[0].Source -cne 'cinegy' -or
        $persisted[0].ActiveIdConfirmed -or $persisted[0].UserId -ne 0 -or $persisted[0].ChatId -ne 0) { return }
    return @{ Key = $key; SceneId = $scene.SceneId; Event = $recordEvent; Disk = $state.Revision
        Local = Get-LayerRemovalFingerprint -Layer $Layer; RegisteredPath = [string](Get-JsonProp $definition 'Path')
        DefinitionRevision = [string](Get-JsonProp $definition 'PresetRevision'); Document = $state; Scene = $scene; PersistedScene = $persisted[0] }
}

function Invoke-WebLayerForget {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline, [switch]$ApplyReview)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-LayersScreenAccess -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $layer = 0
    if (-not [int]::TryParse([string](Get-JsonProp $Arguments 'layer'), [ref]$layer) -or $layer -le 0) {
        return @{ ok = $false; error = 'layer_comparison_missing' }
    }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($Deadline -gt 0 -and $now -ge $Deadline) { return $busy }
    if ($now -lt $script:WebLayerComparisonNextProbe) { return @{ ok = $false; error = 'layer_comparison_busy' } }
    $unavailable = @{ ok = $false; error = if ($ApplyReview) { 'layer_forget_stale' } else { 'layer_forget_unavailable' } }
    $approval = if ($ApplyReview) {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebLayerForgetReviews
    }
    if ($ApplyReview -and (-not $approval -or $approval.Layer -ne $layer)) { return $unavailable }
    $device = Get-WebLocalLayerReviewDevice -Layer $layer -AllowTracked
    if (-not $device) { return $unavailable }
    $target = Get-WebExternalLayerForgetTarget -Layer $layer -Device $device
    if (-not $target -or -not $target.Local -or ($ApplyReview -and $approval.Disk -cne $target.Disk)) { return $unavailable }
    if (-not (Test-TemplateAccess -Key $target.Key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }

    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    try { $status = Get-WebLayerStatus -Layer $layer -TimeoutSec 2 }
    finally {
        $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $filler = Get-WebExplicitCinegyFiller -Status $status
    if (-not $filler -or $target.Event -eq $filler.Id) { return $unavailable }
    $fingerprint = ConvertTo-Json -Compress -InputObject @($layer, $device, $filler.Id, $filler.Started, $target.Local,
        $target.SceneId, $target.Disk, $target.RegisteredPath, [string]$config.AirServerAddress, [int]$config.AirChannelNumber)
    if (-not $ApplyReview) {
        $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebLayerForgetReviews
        $review = $script:WebLayerForgetReviews[$actor]
        $review.Layer = $layer
        $review.Disk = $target.Disk
        $expiry = [datetimeoffset]::UtcNow.AddMinutes(2)
        if ($review.ExpiresAt -gt $expiry) { $review.ExpiresAt = $expiry }
        return @{ ok = $true; data = @{ review = $token; layer = $layer; templateKey = $target.Key } }
    }
    if ($approval.Fingerprint -cne $fingerprint) { return $unavailable }
    $remaining = ($approval.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
    if ($remaining -le 0) { return $unavailable }
    $writeDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
    if ($Deadline -gt 0) { $writeDeadline = [math]::Min($Deadline, $writeDeadline) }
    $result = Save-ReviewedOnAirForget -Layer $layer -SceneId $target.SceneId -ExpectedDisk $target.Disk -Deadline $writeDeadline
    if ($result -ceq 'stale') { return $unavailable }
    if ($result -ceq 'expired') { return $busy }
    if ($result -cne 'saved') { return @{ ok = $false; error = 'layer_forget_save_failed' } }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ layer = $layer; forgotten = $true } }
}

$script:WebLayerReplacementReviews = @{}

function Test-WebLayerReplacementSchedule {
    param([int]$Layer, $Store)

    $keys = @(Get-UpcomingScheduleEvents | ForEach-Object { [string](Get-JsonProp $_ 'TemplateKey') })
    $keys += @($script:MojazSchedules | Where-Object { (Get-JsonProp $_ 'Status') -in 'scheduled', 'queued', 'running' } |
        ForEach-Object { Get-MojazRunDesignKey -Playback $_ })
    foreach ($key in $keys) {
        if ($key -and [int](Get-JsonProp $Store.Map[$key] 'Layer') -eq $Layer) { return $true }
    }
    return $false
}

function Get-WebLayerLedgerTime {
    param($Value)

    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) { return [datetimeoffset]$Value }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
}

function Get-WebLayerReplacementTarget {
    param([int]$Layer, [string]$Device)

    $target = Get-WebExternalLayerForgetTarget -Layer $Layer -Device $Device
    if (-not $target -or -not $target.Local -or -not $target.DefinitionRevision -or
        $target.Scene.TemplatePath -or $target.PersistedScene.TemplatePath -or
        $target.Scene.LastVerifiedAtUtc -cne $target.PersistedScene.LastVerifiedAtUtc) { return }
    $record = $script:OnAir[$Layer]
    if ([long](Get-JsonProp $record 'UserId') -ne 0 -or [long](Get-JsonProp $record 'ChatId') -ne 0 -or
        (Get-JsonProp $record 'TemplatePath') -or $script:PostShowQueue.Count -gt 0) { return }

    # A ledger extension may contain authority the current canonical projection
    # does not understand. Peers keep their extensions, but never discard an
    # unknown field on the row being replaced.
    try {
        $document = ConvertFrom-Json -InputObject $target.Document.Json -AsHashtable -Depth 16 -ErrorAction Stop
        $rows = @($document.Scenes | Where-Object { $_.SceneId -ceq $target.SceneId })
        if ($rows.Count -ne 1) { return }
        $allowed = 'SceneId', 'Layer', 'Key', 'At', 'UserId', 'ChatId', 'ActiveId', 'ActiveIdConfirmed', 'Source', 'TemplatePath', 'LastVerifiedAtUtc'
        if (@($rows[0].Keys | Where-Object { $_ -cnotin $allowed }).Count -gt 0) { return }
        $originalTime = Get-WebLayerLedgerTime $rows[0]['At']
        $memoryTime = Get-WebLayerLedgerTime $target.Scene.At
        $projectionTime = Get-WebLayerLedgerTime (Get-JsonProp $record 'At')
        if (-not $originalTime -or $originalTime -ne $memoryTime -or $memoryTime -ne $projectionTime) { return }
    }
    catch { return }
    return $target
}

function Get-WebReplacementActiveIdentity {
    param($Status)

    if ((Get-JsonProp $Status 'Success') -ne $true -or (Get-JsonProp $Status 'IsOnAir') -isnot [bool] -or
        -not (Get-JsonProp $Status 'IsOnAir') -or -not (Get-JsonProp $Status 'ActiveTemplateName')) { return }
    try {
        $item = ([xml][string](Get-JsonProp $Status 'ActiveXml')).SelectSingleNode('/Item')
        $reportedId = [guid]::Empty
        $detailId = [guid]::Empty
        if (-not $item -or $item.GetAttribute('IsEmpty') -match '^(y|yes|true|1)$' -or -not $item.HasAttribute('ScheduledAt') -or
            -not [guid]::TryParse([string](Get-JsonProp $Status 'ActiveId'), [ref]$reportedId) -or
            -not [guid]::TryParse($item.GetAttribute('Id'), [ref]$detailId) -or $detailId -eq [guid]::Empty -or
            $detailId -ne $reportedId) { return }
        $started = Get-CinegyStatusStartTicks -Status $Status
        if ($started -gt 0) { return @{ Id = $detailId; Started = $started } }
    }
    catch { return }
}

function Invoke-WebLayerReplacement {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline, [switch]$ApplyReview)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-LayersScreenAccess -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $layer = 0
    if (-not [int]::TryParse([string](Get-JsonProp $Arguments 'layer'), [ref]$layer) -or $layer -le 0) {
        return @{ ok = $false; error = 'layer_comparison_missing' }
    }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($Deadline -gt 0 -and $now -ge $Deadline) { return $busy }
    if ($now -lt $script:WebLayerComparisonNextProbe) { return @{ ok = $false; error = 'layer_comparison_busy' } }
    $unavailable = @{ ok = $false; error = if ($ApplyReview) { 'layer_replacement_stale' } else { 'layer_replacement_unavailable' } }
    $approval = if ($ApplyReview) {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebLayerReplacementReviews
    }
    if ($ApplyReview -and (-not $approval -or $approval.Layer -ne $layer)) { return $unavailable }
    $device = Get-WebLocalLayerReviewDevice -Layer $layer -AllowTracked
    if (-not $device) { return $unavailable }
    $target = Get-WebLayerReplacementTarget -Layer $layer -Device $device
    if (-not $target -or ($ApplyReview -and $approval.Disk -cne $target.Disk)) { return $unavailable }
    if (-not (Test-TemplateAccess -Key $target.Key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $store = Get-TemplateStore
    if (Test-WebLayerReplacementSchedule -Layer $layer -Store $store) { return $unavailable }

    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    try { $status = Get-WebLayerStatus -Layer $layer -TimeoutSec 2 -RequireConsistentIdentity }
    finally {
        $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $identity = Get-WebReplacementActiveIdentity -Status $status
    if (-not $identity -or $target.Event -eq $identity.Id) { return $unavailable }
    $adoption = Get-WebExternalLayerAdoptionRecord -Layer $layer -Device $device -Status $status
    if (-not $adoption -or -not (Get-JsonProp $adoption.Definition 'PresetRevision') -or
        $target.Key -cne (Format-WebTemplateReportLabel -Text $target.Key) -or
        $adoption.Key -cne (Format-WebTemplateReportLabel -Text $adoption.Key)) { return $unavailable }
    if (-not (Test-TemplateAccess -Key $adoption.Key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $fingerprint = ConvertTo-Json -Compress -InputObject @($layer, $device, $target.SceneId, $target.Event, $target.Local, $target.Disk,
        $target.RegisteredPath, $target.DefinitionRevision, $identity.Id, $identity.Started, $adoption.Key, $adoption.DeclaredDevice,
        [string](Get-JsonProp $adoption.Definition 'Path'), [string](Get-JsonProp $adoption.Definition 'PresetRevision'),
        [string]$config.AirServerAddress, [int]$config.AirChannelNumber)
    if (-not $ApplyReview) {
        $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebLayerReplacementReviews
        $review = $script:WebLayerReplacementReviews[$actor]
        $review.Layer = $layer
        $review.Disk = $target.Disk
        $expiry = [datetimeoffset]::UtcNow.AddMinutes(2)
        if ($review.ExpiresAt -gt $expiry) { $review.ExpiresAt = $expiry }
        return @{ ok = $true; data = @{ review = $token; layer = $layer; oldTemplateKey = $target.Key; templateKey = $adoption.Key } }
    }
    if ($approval.Fingerprint -cne $fingerprint) { return $unavailable }
    $remaining = ($approval.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
    if ($remaining -le 0) { return $unavailable }
    $writeDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
    if ($Deadline -gt 0) { $writeDeadline = [math]::Min($Deadline, $writeDeadline) }

    # The engine observation authorizes only a new local external row. The old
    # row never lends its record identity, flags, authorship or editorial data.
    $adoption.Record.Remove('CinegyEventName')
    $result = Save-ReviewedOnAirReplacement -Layer $layer -SceneId $target.SceneId -Record $adoption.Record -ExpectedDisk $target.Disk -Deadline $writeDeadline
    if ($result -ceq 'stale') { return $unavailable }
    if ($result -ceq 'expired') { return $busy }
    if ($result -cne 'saved') { return @{ ok = $false; error = 'layer_replacement_save_failed' } }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ layer = $layer; replaced = $true } }
}

function Get-WebUrgentLayerStatus {
    param([int]$Layer, [switch]$RequireConsistentIdentity)
    return Get-WebLayerStatus -Layer $Layer -RequireConsistentIdentity:$RequireConsistentIdentity
}

function Get-WebUrgentManualLive {
    param([long]$Actor)
    $control = Get-UrgentManualControl -ChatId $Actor -UserId $Actor
    if (-not $control) { return $null }
    return @{ itemId = [string]$control.State.ItemId; layer = $control.Layer; review = $control.Token }
}

function New-WebAirReview {
    param([long]$Actor, [string]$Fingerprint, [hashtable]$Reviews = $script:WebUrgentManualReviews)
    $now = [datetimeoffset]::UtcNow
    foreach ($entry in @($Reviews.GetEnumerator())) {
        if ($entry.Value.ExpiresAt -le $now) { $Reviews.Remove($entry.Key) | Out-Null }
    }
    $token = [guid]::NewGuid().ToString('N')
    $Reviews[$Actor] = @{
        Token = $token; Fingerprint = $Fingerprint
        ExpiresAt = $now.AddMinutes((Get-SettingInt 'PendingStateTimeoutMinutes' 1))
    }
    return $token
}

function Use-WebAirReview {
    param([long]$Actor, [string]$Token, [hashtable]$Reviews = $script:WebUrgentManualReviews)
    $pending = $Reviews[$Actor]
    if (-not $pending -or $Token -cne $pending.Token) { return }
    $Reviews.Remove($Actor) | Out-Null
    if ($pending.ExpiresAt -gt [datetimeoffset]::UtcNow) { return $pending }
}

function Get-WebTemplateRehearsalLayer {
    param([long]$Actor, [string]$Key)
    $layer = Get-SettingInt 'TemplateTestLayer' 0
    if ($layer -le 0 -or -not (Test-Admin -ChatId $Actor -UserId $Actor) -or
        -not (Get-Setting 'EnableFullTemplateManagement') -or
        [string](Get-Setting 'SceneMode') -eq 'Multi' -or
        (Test-PermanentGraphicAutoHideProtected -Layer $layer) -or
        -not (Test-TemplateAccess -Key $Key -Layer $layer -ChatId $Actor -UserId $Actor).Allowed) {
        return 0
    }
    $testDevice = (Resolve-AirGfxDevice -Layer $layer).StatusPath
    foreach ($knownLayer in @(Get-KnownLayers)) {
        if ([int]$knownLayer -eq $layer -or (Resolve-AirGfxDevice -Layer $knownLayer).StatusPath -eq $testDevice) { return 0 }
    }
    return $layer
}

function Invoke-WebTemplateRehearsal {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor) -or
        -not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $action = [string](Get-JsonProp $Arguments 'action')
    $key = [string](Get-JsonProp $Arguments 'key')
    if (-not $key -or $action -cnotin @('preview', 'start')) { return @{ ok = $false; error = 'rehearsal_invalid' } }
    $stale = @{ ok = $false; error = 'rehearsal_stale' }
    if ($action -eq 'start') {
        $pending = Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTemplateRehearsalReviews
        if (-not $pending) { return $stale }
    }
    $template = (Get-TemplateStore).Map[$key]
    if (-not $template) { return $stale }
    if (-not (Test-TemplateAccess -Key $template.Key -Layer ([int]$template.Layer) -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $layer = Get-WebTemplateRehearsalLayer -Actor $actor -Key $template.Key
    if ($layer -le 0 -or $layer -eq [int]$template.Layer) {
        $reason = if ([string](Get-Setting 'SceneMode') -eq 'Multi') { 'rehearsal_multi' } else { 'rehearsal_unavailable' }
        return @{ ok = $false; error = $reason }
    }
    $path = [string](Get-JsonProp $template 'Path')
    $file = if ($path) { Get-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    if (-not $file -or $file.PSIsContainer) { return @{ ok = $false; error = 'rehearsal_unavailable' } }

    $seconds = [math]::Min(300, (Get-SettingInt 'TemplateTestAutoHideSeconds' 3))
    $cap = Get-EffectiveAutoHideSeconds -Key $template.Key
    if ($cap -gt 0) { $seconds = [math]::Min($seconds, $cap) }
    $types = Get-TemplateFieldTypeOverrides -Template $template
    $defaultType = [string](Get-Setting 'AirVariableType')
    $media = @(Get-BoardMediaFields -TemplateKey $template.Key)
    $variables = @{}
    $reviewFields = @(foreach ($field in Get-WebTemplateFields -Template $template) {
            if ($field.name -in $media) { continue }
            $type = $types[$field.name] ?? $defaultType
            $sample = switch ($type) {
                'Bool' { 'false' }
                'Float' { '0' }
                default { if ($field.maxLength -and $field.maxLength -lt 4) { 'TEST'.Substring(0, $field.maxLength) } else { 'TEST' } }
            }
            $variables[$field.name] = $sample
            @{ label = $field.label; value = $sample }
        })
    $device = (Resolve-AirGfxDevice -Layer $layer).StatusPath
    $fingerprint = ConvertTo-Json -Compress -Depth 10 -InputObject @(
        $template.Key, [int]$template.Layer, $path, $file.LastWriteTimeUtc.Ticks, $file.Length,
        $layer, $device, $seconds, $defaultType, $types, $variables, $reviewFields
    )
    if ($action -eq 'start' -and $pending.Fingerprint -cne $fingerprint) { return $stale }
    $stamp = Get-CinegyLayerReviewStamp -Status (Get-WebLayerStatus -Layer $layer)
    if (-not $stamp) { return @{ ok = $false; error = 'rehearsal_unverified' } }
    if ($stamp -cne 'empty') { return @{ ok = $false; error = 'rehearsal_busy' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    if ($action -eq 'preview') {
        return @{ ok = $true; data = @{ preview = @{
                    review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebTemplateRehearsalReviews
                    layer = $layer; autoHideSeconds = $seconds; fields = $reviewFields
                } } }
    }
    return Invoke-WebIsolatedRehearsal -Template $template -Layer $layer -Variables $variables -Types $types -DefaultType $defaultType -Seconds $seconds -Actor $actor
}

function Invoke-WebUrgentRehearsal {
    param([long]$Actor, [System.Collections.IDictionary]$Arguments)
    if (-not (Test-Admin -ChatId $Actor -UserId $Actor)) { return @{ ok = $false; error = 'forbidden' } }
    $preview = (Get-JsonProp $Arguments 'action') -eq 'rehearse-preview'
    if (-not $preview) {
        $pending = Use-WebAirReview -Actor $Actor -Token ([string](Get-JsonProp $Arguments 'review'))
        if (-not $pending) { return @{ ok = $false; error = 'urgent_stale' } }
    }
    if (-not (Test-UrgentBoardAvailable)) {
        return @{ ok = $false; error = 'urgent_rehearsal_unavailable' }
    }
    $itemId = [string](Get-JsonProp $Arguments 'itemId')
    if (-not $itemId) { return @{ ok = $false; error = 'urgent_invalid' } }
    $item = Get-UrgentItem -Board $script:UrgentBoard -ItemId $itemId
    $template = Get-UrgentTemplate
    if (-not $item -or -not $template -or -not (Get-UrgentProperty $item 'Enabled' $true)) {
        return @{ ok = $false; error = 'urgent_stale' }
    }
    if (-not (Test-TemplateAccess -Key $template.Key -Layer ([int]$template.Layer) -ChatId $Actor -UserId $Actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $layer = Get-WebTemplateRehearsalLayer -Actor $Actor -Key $template.Key
    if ($layer -le 0 -or $layer -eq [int]$template.Layer) {
        return @{ ok = $false; error = 'urgent_rehearsal_unavailable' }
    }
    $stamp = Get-CinegyLayerReviewStamp -Status (Get-WebUrgentLayerStatus -Layer $layer)
    if (-not $stamp) { return @{ ok = $false; error = 'refused'; data = (T 'cfg.trialLayerUnsure' $layer) } }
    if ($stamp -cne 'empty') { return @{ ok = $false; error = 'urgent_rehearsal_busy' } }

    $seconds = [math]::Min(300, (Get-SettingInt 'TemplateTestAutoHideSeconds' 3))
    $cap = Get-EffectiveAutoHideSeconds -Key $template.Key
    if ($cap -gt 0) { $seconds = [math]::Min($seconds, $cap) }
    $variables = Get-UrgentItemVariables -Item $item
    $reviewed = ConvertTo-Json -Compress -Depth 12 -InputObject @(
        'rehearsal', $Actor, $itemId, (Get-JsonProp $script:UrgentBoard 'Revision'), $template, $layer, $seconds, $variables
    )
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($reviewed)))
    if ($preview) {
        return @{ ok = $true; data = @{ preview = @{
            review = New-WebAirReview -Actor $Actor -Fingerprint $fingerprint
            layer = $layer; values = $variables; autoHideSeconds = $seconds; rehearsal = $true
            replacesGraphic = $false; stopsRun = $false; stopsBulletin = $false; graphicName = ''
        } } }
    }
    if ($pending.Fingerprint -cne $fingerprint) { return @{ ok = $false; error = 'urgent_stale' } }
    $types = Get-TemplateFieldTypeOverrides -Template $template
    $played = Invoke-WebIsolatedRehearsal -Template $template -Layer $layer -Variables $variables -Types $types -DefaultType ([string](Get-Setting 'AirVariableType')) -Seconds $seconds -Actor $Actor
    if (-not $played.ok) { return @{ ok = $false; error = 'urgent_rehearsal_failed' } }
    $played.data.rehearsalStarted = $true
    return $played
}

function Invoke-WebIsolatedRehearsal {
    param($Template, [int]$Layer, [hashtable]$Variables, [hashtable]$Types, [string]$DefaultType, [int]$Seconds, [long]$Actor)
    # Only the direct SHOW addresses the test device without shared postbox
    # writes or taking over the urgent and bulletin engines.
    $address = @{ AirServerAddress = $config.AirServerAddress; AirChannelNumber = $config.AirChannelNumber }
    $startedAt = [datetimeoffset]::Now
    $result = Show-TitlerTemplate @address -Layer $Layer -TemplatePath ([string]$Template.Path) -Variables $Variables -Types $Types -DefaultType $DefaultType -TimeoutSec (Get-AirTimeout)
    if (-not (Get-JsonProp $result 'Success')) { return @{ ok = $false; error = 'rehearsal_failed' } }
    $requestedId = [string](Get-JsonProp $result 'EventId')
    $identity = Get-VerifiedCinegyShowIdentity -Key $Template.Key -TemplatePath ([string]$Template.Path) -Layer $Layer `
        -ExpectedActiveId $requestedId -RequireEventIdentity
    $timerSaved = $false
    # Another operator may have placed the same template after SHOW. A name
    # match alone must not give this rehearsal ownership of that scene.
    if ($identity.Success -and $requestedId -and
        ([string]$identity.ActiveId).Trim().Trim('{', '}') -eq $requestedId.Trim().Trim('{', '}')) {
        $key = "[TEST] $($Template.Key)"
        Set-OnAirShownRecord -Layer $Layer -Record @{
            Key = $key; At = $startedAt; UserId = $Actor; ActiveId = [string]$identity.ActiveId
            ActiveIdConfirmed = $true; Source = 'BotTest'
        }
        Save-OnAirState
        # Allow an expired deadline to become due on the next tick once identity is verified.
        $timerSaved = Set-AutoHideTimer -Layer $Layer -Seconds $Seconds -Deadline ($startedAt.AddSeconds($Seconds)) -ChatId $Actor -UserId $Actor `
            -TemplateKey $key -ActiveId ([string]$identity.ActiveId) -ActiveIdConfirmed $true -SingleSceneOnly
    }
    Add-AuditEntry (T 'cfg.templateTestAudit' $Template.Key $Layer $(Format-UserAuditActor -UserId $Actor))
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ autoHideFailed = -not $timerSaved } }
}

function Invoke-WebUrgentManual {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'status') {
        return @{ ok = $true; data = @{ live = Get-WebUrgentManualLive -Actor $actor; noticeId = Get-UrgentWebNoticeForActor -Actor $actor } }
    }
    if (-not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if ($action -in 'rehearse-preview', 'rehearse') { return Invoke-WebUrgentRehearsal -Actor $actor -Arguments $Arguments }
    $review = [string](Get-JsonProp $Arguments 'review')
    if ($action -eq 'hide') {
        $outcome = Invoke-UrgentManualHide -ChatId $actor -UserId $actor -Token $review -Quiet -VerifyEngine
        if ($outcome -cne 'hidden') { return @{ ok = $false; error = $outcome } }
        return @{ ok = $true; data = @{} }
    }
    if ($action -notin 'options', 'preview', 'show') { return @{ ok = $false; error = 'urgent_invalid' } }
    $pending = $null
    if ($action -eq 'show') {
        $pending = Use-WebAirReview -Actor $actor -Token $review
        if (-not $pending) { return @{ ok = $false; error = 'urgent_stale' } }
    }
    if (-not (Test-UrgentBoardAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
    $itemId = [string](Get-JsonProp $Arguments 'itemId')
    if (-not $itemId) { return @{ ok = $false; error = 'urgent_invalid' } }
    $item = Get-UrgentItem -Board $script:UrgentBoard -ItemId $itemId
    if (-not $item -or -not (Get-UrgentProperty $item 'Enabled' $true)) { return @{ ok = $false; error = 'urgent_stale' } }
    $template = Get-UrgentTemplate
    $layer = [int]$template.Layer
    if (-not (Test-TemplateAccess -Key $template.Key -Layer $layer -ChatId $actor -UserId $actor).Allowed) { return @{ ok = $false; error = 'forbidden' } }
    if ($action -eq 'options') {
        $timing = Get-UrgentEffectiveTiming -Item $item -Defaults (Get-UrgentBoardDefaults) -FloorSeconds (Get-UrgentFloorSeconds)
        $choices = @(Get-AutoHideChoices) + @([int][math]::Ceiling($timing.HoldSeconds))
        return @{ ok = $true; data = @{
            durations = @($choices | Where-Object { $_ -gt 0 -and $_ -le 86400 } | Sort-Object -Unique)
            canRehearse = (Get-WebTemplateRehearsalLayer -Actor $actor -Key $template.Key) -gt 0
        } }
    }
    $policy = Test-TemplateShowPolicy -Key $template.Key -Layer $layer -IsAdmin:(Test-Admin -ChatId $actor -UserId $actor)
    if (-not $policy.Allowed) { return @{ ok = $false; error = 'refused'; data = $policy.Reason } }
    $duration = Get-JsonProp $Arguments 'autoHideSeconds'
    if (($duration -isnot [int] -and $duration -isnot [long]) -or $duration -lt 0 -or $duration -gt 86400) {
        return @{ ok = $false; error = 'urgent_invalid' }
    }
    $status = Get-WebUrgentLayerStatus -Layer $layer
    $stamp = Get-CinegyLayerReviewStamp -Status $status
    if (-not $stamp) { return @{ ok = $false; error = 'refused'; data = (T 'air.layerCheckFailed') } }
    $variables = Get-UrgentItemVariables -Item $item
    $effective = Get-EffectiveAutoHideSeconds -Key $template.Key -RequestedSeconds $duration
    $reviewed = ConvertTo-Json -Compress -Depth 12 -InputObject @(
        'programme', $actor, $itemId, (Get-JsonProp $script:UrgentBoard 'Revision'), $template, $stamp, $duration, $effective, $variables,
        [bool]$script:UrgentBoardRun, (Get-JsonProp $script:UrgentBoardRun 'OperationId'),
        [bool]$script:MojazPlayback, (Get-JsonProp $script:MojazPlayback 'OperationId')
    )
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($reviewed)))
    if ($action -eq 'preview') {
        $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint
        return @{ ok = $true; data = @{ preview = @{
            review = $token; layer = $layer; values = $variables; autoHideSeconds = $effective
            replacesGraphic = $stamp -ne 'empty'; stopsRun = [bool]$script:UrgentBoardRun
            stopsBulletin = [bool]$script:MojazPlayback
            graphicName = Get-NewsScreenLine ([string](Get-JsonProp $status 'ActiveName')) 100
        } } }
    }
    if ($pending.Fingerprint -cne $fingerprint) { return @{ ok = $false; error = 'urgent_stale' } }
    $result = Invoke-ShowTemplateResult -Key $template.Key -Variables $variables -ChatId $actor -UserId $actor `
        -AutoHideSeconds $duration -ExpectedLayerStamp $stamp -RequireEventIdentity -ManualUrgent
    if (-not (Get-JsonProp $result 'Success')) { return @{ ok = $false; error = 'refused'; data = [string](Get-JsonProp $result 'Error') } }
    $confirmed = Set-UrgentManualLiveState -ChatId $actor -UserId $actor -ItemId $itemId -Layer $layer -Result $result `
        -AutoHideSeconds $effective -FromWeb
    return @{ ok = $true; data = @{
        live = Get-WebUrgentManualLive -Actor $actor
        sceneConfirmed = $null -ne $confirmed
        autoHideFailed = $effective -gt 0 -and -not (Get-JsonProp $result 'AutoHideArmed')
    } }
}

function Invoke-WebUrgentPlayback {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'status') { return @{ ok = $true; data = @{ run = Get-WebUrgentRun } } }

    $template = Get-UrgentTemplate
    if (-not $template) { return @{ ok = $false; error = 'content_disabled' } }
    $layer = [int]$template.Layer
    $access = Test-TemplateAccess -Key $script:MojazUrgentKey -Layer $layer -ChatId $actor -UserId $actor
    if (-not $access.Allowed) { return @{ ok = $false; error = 'forbidden' } }
    if ($action -in 'preview', 'start', 'preview-selected', 'start-selected') {
        if (-not (Test-UrgentBoardAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
        if ($script:UrgentBoardRun -or $script:MojazPlayback) { return @{ ok = $false; error = 'urgent_air_busy' } }
        $policy = Test-TemplateShowPolicy -Key $script:MojazUrgentKey -Layer $layer -IsAdmin:(Test-Admin -ChatId $actor -UserId $actor)
        if (-not $policy.Allowed) { return @{ ok = $false; error = 'refused'; data = $policy.Reason } }
        $ids = @(Get-JsonProp $Arguments 'selectedIds' | Where-Object { $null -ne $_ })
        $requiresSelection = $action -in 'preview-selected', 'start-selected'
        if ($requiresSelection -and $ids.Count -eq 0) { return @{ ok = $false; error = 'urgent_stale' } }
        if ($ids.Count -gt 40) { return @{ ok = $false; error = 'urgent_invalid' } }
        $modeOverride = Get-JsonProp $Arguments 'mode'
        if ($null -ne $modeOverride) {
            if ($modeOverride -isnot [string] -or -not (Test-UrgentMode -Mode $modeOverride)) {
                return @{ ok = $false; error = 'urgent_invalid' }
            }
            $modeOverride = $modeOverride.ToLowerInvariant()
        }
        $selectedOnly = $ids.Count -gt 0
        $result = New-UrgentBoardPlan -ChatId $actor -SelectedIds $ids -SelectedOnly:$selectedOnly -ModeOverride $modeOverride
        if (-not $result.Success) { return @{ ok = $false; error = 'refused'; data = [string]$result.Error } }
        $plan = $result.Value
        if ($selectedOnly) {
            $plannedIds = @($plan.Steps.ItemId | Sort-Object -Unique)
            if ($plannedIds.Count -ne $ids.Count -or @($ids | Where-Object { $_ -cnotin $plannedIds }).Count) {
                return @{ ok = $false; error = 'urgent_stale' }
            }
        }
        $live = Get-WebUrgentLayerStatus -Layer $layer
        $stamp = Get-CinegyLayerReviewStamp -Status $live
        if (-not $stamp) { return @{ ok = $false; error = 'refused'; data = (T 'air.layerCheckFailed') } }
        # Recompute at confirmation on the bridge thread. The fingerprint includes
        # the full plan and scene identity so a change cannot silently go on air.
        $reviewed = [ordered]@{
            actor = $actor; revision = Get-UrgentProperty $script:UrgentBoard 'Revision' 0
            template = $template; scene = $stamp; plan = $plan; selectedOnly = $selectedOnly; mode = $modeOverride
        } | ConvertTo-Json -Depth 12 -Compress
        $review = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($reviewed)))
        if ($action -in 'preview', 'preview-selected') {
            return @{ ok = $true; data = @{ preview = @{
                review = $review; totalSeconds = $plan.TotalSeconds; itemCount = $plan.ItemCount; stepCount = $plan.StepCount
                layer = $layer; replacesGraphic = $stamp -ne 'empty'
                graphicName = Get-NewsScreenLine ([string](Get-JsonProp $live 'ActiveName')) 100
                notes = @($plan.Notes)
                steps = @($plan.Steps | Select-Object -First 20 | ForEach-Object {
                    @{ text = Get-NewsScreenLine $_.Text 160; startSeconds = $_.VisibleAtSeconds; holdSeconds = $_.HoldSeconds }
                })
            } } }
        }
        if ($review -cne [string](Get-JsonProp $Arguments 'review')) { return @{ ok = $false; error = 'urgent_stale' } }
        if (-not (Start-UrgentBoardRun -ChatId $actor -UserId $actor -ReviewedPlan $plan -ExpectedLayerStamp $stamp -SelectedOnly:$selectedOnly -Quiet -ModeOverride $modeOverride)) {
            return @{ ok = $false; error = 'refused' }
        }
        Publish-WebChannelState -Force
        return @{ ok = $true; data = @{ run = Get-WebUrgentRun } }
    }

    $run = Get-WebUrgentRun
    if (-not $run -or -not $run.id -or $run.id -cne [string](Get-JsonProp $Arguments 'runId')) {
        return @{ ok = $false; error = 'urgent_stale' }
    }
    $boundLayer = Get-JsonProp $script:UrgentBoardRun 'Layer'
    if ($null -ne $boundLayer -and [int]$boundLayer -ne $layer) { return @{ ok = $false; error = 'urgent_stale' } }
    $layerEmpty = $false
    if ($action -in 'skip', 'stop') {
        $observed = Get-CinegyLayerReviewStamp -Status (Get-WebUrgentLayerStatus -Layer $layer)
        $layerEmpty = $observed -eq 'empty'
        $record = $script:OnAir[$layer]
        $expected = Get-CinegyLayerReviewStamp -Status @{
            Success = $true; IsOnAir = $true; ActiveId = Get-JsonProp $record 'ActiveId'
        }
        if ((-not $layerEmpty -or $action -ne 'stop') -and (
            -not $observed -or $observed -cne $expected -or (Get-JsonProp $record 'Key') -ne $script:MojazUrgentKey
        )) { return @{ ok = $false; error = 'urgent_stale' } }
    }
    $success = $false
    switch ($action) {
        'pause' { $success = Suspend-UrgentBoardRun -ChatId $actor -UserId $actor }
        'resume' { $success = Resume-UrgentBoardRun -ChatId $actor -UserId $actor }
        'skip' {
            if ((Get-JsonProp $Arguments 'step') -ne $run.step) { return @{ ok = $false; error = 'urgent_stale' } }
            $success = Move-UrgentBoardNext -ChatId $actor -UserId $actor
        }
        'stop' {
            if (-not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
            $success = Stop-UrgentBoardRun -ChatId $actor -UserId $actor -Reason 'manual' -NoExit:$layerEmpty -Quiet
        }
        default { return @{ ok = $false; error = 'urgent_invalid' } }
    }
    Publish-WebChannelState -Force
    if (-not $success) {
        if (Get-JsonProp $script:UrgentBoardRun 'StopFailed') { return @{ ok = $false; error = 'urgent_stop_unconfirmed' } }
        return @{ ok = $false; error = 'refused' }
    }
    return @{ ok = $true; data = @{ run = Get-WebUrgentRun } }
}
