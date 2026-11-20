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
        functions. Reads ('status', 'identity') are answered from data the
        bridge thread publishes into $Shared; everything else is queued.
      * The bridge thread drains that queue in Update-WebChannel - from the
        tick, and from the pump that runs while a Telegram long poll is in
        flight - and hands each answer back to the waiting listener.

    Off by default (WebAccessEnabled). Off means no pipe, no pump, and the
    polling loop running exactly as it did before this file existed.
#>

$script:WebChannel = $null
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
$script:WebRelayReviewKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
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
    $script:WebChannel = @{ Shared = $shared; Pool = $pool; Listeners = @($listeners) }
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
    $shared.Roster = Get-WebRoster
}

function Invoke-WebChannelRequests {
    <# Drains what the listeners queued. Bounded per call so a flood of
       requests cannot hold the air clock; the rest wait for the next pass. #>
    param([int]$Limit = 25)
    if (-not (Test-WebChannelActive)) { return }
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
        try { $answer = Invoke-WebChannelOperation -Request $item.Request }
        catch {
            Write-BridgeLog "Web channel operation failed: $($_.Exception.Message)" 'ERROR'
            $answer = @{ ok = $false; error = 'internal' }
        }
        [void]$item.Reply.TrySetResult(($answer | ConvertTo-Json -Compress -Depth 6))
    }
}

function Invoke-WebChannelOperation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request)
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
        'air.show' { return Invoke-WebAirShow -Arguments $arguments }
        'air.hide' { return Invoke-WebAirHide -Arguments $arguments }
        'air.exit' { return Invoke-WebAirExit -Arguments $arguments }
        'content.list' { return Get-WebContentPage -Arguments $arguments }
        'urgent.write' { return Invoke-WebUrgentWrite -Arguments $arguments }
        'urgent.playback' { return Invoke-WebUrgentPlayback -Arguments $arguments }
        'ticker.edit' { return Invoke-WebTickerEdit -Arguments $arguments }
        'bulletin.edit' { return Invoke-WebBulletinEdit -Arguments $arguments }
        'bulletin.paste' { return Invoke-WebBulletinPaste -Arguments $arguments }
        'relay.control' { return Invoke-WebRelayControl -Arguments $arguments }
    }
    return @{ ok = $false; error = 'unknown_op' }
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
    if (-not (Test-WebChannelActive)) { return }
    Publish-WebChannelState
    Invoke-WebChannelRequests
    Update-WebLoginExpiry
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

    $success = Invoke-HideLayer -Layer $layer -ChatId $actor -UserId $actor -Quiet
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

    $success = Invoke-ExitLayer -Layer $layer -ChatId $actor -UserId $actor
    if (-not $success) {
        return @{ ok = $false; error = 'refused' }
    }

    Publish-WebChannelState -Force
    return @{ ok = $true }
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

    $window = Get-BridgePageWindow -ItemCount $entries.Count -Page ([int](Get-JsonProp $Arguments 'page'))
    $items = @(
        for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $entry = $entries[$index]
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
                        enabled = [bool](Get-UrgentProperty $entry 'Enabled' $true)
                        state = $state
                        values = Get-UrgentItemVariables -Item $entry
                    }
                }
                'bulletins' {
                    $state = if (Test-MojazOnAir -Bulletin $entry) { 'on_air' } else { 'saved' }
                    $rows = @(Get-JsonProp $entry 'Rows' | Where-Object { $null -ne $_ }).Count
                    @{ id = [string](Get-JsonProp $entry 'Id'); title = Get-NewsScreenLine -Text ([string](Get-JsonProp $entry 'Name')) -Length 120; state = $state; rows = $rows }
                }
                'ticker' { @{ title = Get-NewsScreenLine -Text ([string]$entry) -Length 240; state = 'published' } }
            }
        }
    )
    return @{ ok = $true; data = @{
        items = $items; page = $window.Page; pageCount = $window.PageCount; total = $entries.Count; revision = $revision; fields = $fields
    } }
}

function Get-WebBulletinFields {
    param([Parameter(Mandatory)]$Bulletin)
    $key = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    foreach ($prompt in Get-MojazRowFieldPrompts -TemplateKey $key) {
        $label = [string]$prompt.Label
        $kind = [string]$prompt.Kind
        if ($prompt.Name -eq $script:MojazImageVariable) {
            $kind = 'media'
            if ($label -eq $prompt.Name) { $label = T 'mojaz.col.image' }
        }
        @{ name = [string]$prompt.Name; label = $label; kind = $kind }
    }
}

function Get-WebBulletinEditor {
    param([Parameter(Mandatory)]$Bulletin, [int]$Page)
    $fields = @(Get-WebBulletinFields -Bulletin $Bulletin)
    $rows = @(Get-JsonProp $Bulletin 'Rows' | Where-Object { $null -ne $_ })
    $window = Get-BridgePageWindow -ItemCount $rows.Count -Page $Page
    $items = @(
        for ($position = $window.StartIndex; $position -le $window.EndIndex; $position++) {
            $row = $rows[$position]
            $values = @{}
            $media = @(
                foreach ($field in $fields) {
                    $value = Get-MojazRowFieldValue -Row $row -FieldName $field.name
                    if ($field.kind -eq 'text') { $values[$field.name] = $value }
                    elseif ($value) { $field.name }
                }
            )
            @{ id = [string](Get-JsonProp $row 'Id'); values = $values; media = $media; skipped = Test-MojazRowSkipped -Row $row }
        }
    )
    $designKey = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    $canPlay = Test-MojazBulletinPlaybackDesign -Bulletin $Bulletin
    return @{
        id = [string](Get-JsonProp $Bulletin 'Id'); name = [string](Get-JsonProp $Bulletin 'Name')
        design = $designKey; playbackSupported = $canPlay
        headlinePaste = Test-WebBulletinHeadlineFormat -Fields $fields
        timing = $(if ($canPlay) { Get-WebBulletinTiming -Bulletin $Bulletin })
        revision = [int](Get-JsonProp $Bulletin 'Revision'); onAir = Test-MojazOnAir -Bulletin $Bulletin
        fields = $fields; rows = $items; page = $window.Page; pageCount = $window.PageCount; total = $rows.Count
    }
}

function Get-WebBulletinTiming {
    param([Parameter(Mandatory)]$Bulletin)
    $scene = Get-MojazSceneTiming
    $framesPerSecond = Get-MojazFps
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
            'timing' {
                if (-not (Test-MojazBulletinPlaybackDesign -Bulletin $bulletin)) {
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
                $fields = @(Get-WebBulletinFields -Bulletin $bulletin | Where-Object { $_.kind -eq 'text' })
                if ($fields.Count -eq 0 -or $values -isnot [System.Collections.IDictionary] -or $values.Count -ne $fields.Count) {
                    return @{ ok = $false; error = 'bulletin_invalid' }
                }
                $cells = @{}
                foreach ($field in $fields) {
                    $value = Get-JsonProp $values $field.name
                    if ($value -isnot [string] -or $value.Length -gt 4096) { return @{ ok = $false; error = 'bulletin_invalid' } }
                    try { [void][System.Xml.XmlConvert]::VerifyXmlChars($value) }
                    catch { return @{ ok = $false; error = 'bulletin_invalid' } }
                    $cells[$field.name] = $value
                }
                $rowArgs = ConvertTo-WebBulletinRowArguments -Cells $cells
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

function Get-WebTickerEditorState {
    param([Parameter(Mandatory)][long]$Actor)
    $draft = Get-NewsTickerDraft
    $data = @{ state = 'available'; draft = $null; owner = ''; maxItemLength = Get-SettingInt 'NewsMaxItemLength' 1 }
    if ($draft -and -not (Test-NewsTickerDraftOpen -Draft $draft)) {
        $owner = [long](Get-JsonProp $draft 'OwnerUserId')
        if ($owner -ne $Actor) {
            $data.state = 'locked'
            if ($owner -gt 0) { $data.owner = Get-NewsScreenLine (Get-UserDisplayName -UserId $owner) 64 }
        }
        else {
            $data.state = 'editing'
            $data.draft = @{
                revision = Get-NewsTickerDraftRevision -Draft $draft
                items = @(Get-JsonProp $draft 'Items' | Where-Object { $null -ne $_ })
                scheduledAt = Get-NewsPublishAt -Draft $draft
                canRemove = Test-NewsTickerDeleteAccess -ChatId $Actor -UserId $Actor
                maxItems = Get-SettingInt 'NewsMaxItems' 1
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

function Invoke-WebTickerEdit {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Get-Setting 'EnableNewsTickerManagement')) { return @{ ok = $false; error = 'content_disabled' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'status') { return @{ ok = $true; data = Get-WebTickerEditorState -Actor $actor } }
    if ($action -eq 'start') {
        if ((Get-WebTickerEditorState -Actor $actor).state -eq 'locked') { return @{ ok = $false; error = 'ticker_locked' } }
        $started = Start-NewsTickerDraft -ChatId $actor -UserId $actor
        if (-not $started.Success) { return @{ ok = $false; error = 'ticker_start_failed' } }
        return @{ ok = $true; data = Get-WebTickerEditorState -Actor $actor }
    }

    $draft = Get-NewsTickerDraft -UserId $actor
    if (-not $draft -or (Test-NewsTickerDraftOpen -Draft $draft)) { return @{ ok = $false; error = 'ticker_locked' } }
    if ((Get-NewsTickerDraftRevision -Draft $draft) -cne [string](Get-JsonProp $Arguments 'revision')) {
        return @{ ok = $false; error = 'ticker_stale' }
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
        'up' { $saved = Move-NewsTickerDraftItem -UserId $actor -Index $index -Delta -1 }
        'down' { $saved = Move-NewsTickerDraftItem -UserId $actor -Index $index -Delta 1 }
        'handover' { $saved = Open-NewsTickerDraftToAll -ChatId $actor -UserId $actor }
        default { return @{ ok = $false; error = 'ticker_invalid' } }
    }
    if (-not $saved) { return @{ ok = $false; error = 'ticker_invalid' } }
    return @{ ok = $true; data = Get-WebTickerEditorState -Actor $actor }
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

function Get-WebUrgentLayerStatus {
    param([int]$Layer)
    return Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
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
    if ($action -in 'preview', 'start') {
        if (-not (Test-UrgentBoardAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
        if ($script:UrgentBoardRun -or $script:MojazPlayback) { return @{ ok = $false; error = 'urgent_air_busy' } }
        $policy = Test-TemplateShowPolicy -Key $script:MojazUrgentKey -Layer $layer -IsAdmin:(Test-Admin -ChatId $actor -UserId $actor)
        if (-not $policy.Allowed) { return @{ ok = $false; error = 'refused'; data = $policy.Reason } }
        $ids = @(Get-JsonProp $Arguments 'selectedIds' | Where-Object { $null -ne $_ })
        if ($ids.Count -gt 40) { return @{ ok = $false; error = 'urgent_invalid' } }
        $selectedOnly = $ids.Count -gt 0
        $result = New-UrgentBoardPlan -ChatId $actor -SelectedIds $ids -SelectedOnly:$selectedOnly
        if (-not $result.Success) { return @{ ok = $false; error = 'refused'; data = [string]$result.Error } }
        $plan = $result.Value
        $live = Get-WebUrgentLayerStatus -Layer $layer
        $stamp = Get-CinegyLayerReviewStamp -Status $live
        if (-not $stamp) { return @{ ok = $false; error = 'refused'; data = (T 'air.layerCheckFailed') } }
        # Recompute at confirmation on the bridge thread. The fingerprint includes
        # the full plan and scene identity so a change cannot silently go on air.
        $reviewed = [ordered]@{
            actor = $actor; revision = Get-UrgentProperty $script:UrgentBoard 'Revision' 0
            template = $template; scene = $stamp; plan = $plan; selectedOnly = $selectedOnly
        } | ConvertTo-Json -Depth 12 -Compress
        $review = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($reviewed)))
        if ($action -eq 'preview') {
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
        if (-not (Start-UrgentBoardRun -ChatId $actor -UserId $actor -ReviewedPlan $plan -ExpectedLayerStamp $stamp -SelectedOnly:$selectedOnly -Quiet)) {
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
