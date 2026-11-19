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
                            $item = @{ Request = $request; Reply = $null; Done = [System.Threading.ManualResetEventSlim]::new($false) }
                            $Shared.Queue.Enqueue($item)
                            [void]$Shared.Signal.Set()
                            $reply = if ($item.Done.Wait(15000)) { [string]$item.Reply } else { '{"ok":false,"error":"bridge_busy"}' }
                            $item.Done.Dispose()
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
        $pending.Reply = '{"ok":false,"error":"channel_closed"}'
        $pending.Done.Set()
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
        layers = @($layers)
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
        $answer = $null
        try { $answer = Invoke-WebChannelOperation -Request $item.Request }
        catch {
            Write-BridgeLog "Web channel operation failed: $($_.Exception.Message)" 'ERROR'
            $answer = @{ ok = $false; error = 'internal' }
        }
        $item.Reply = ($answer | ConvertTo-Json -Compress -Depth 6)
        $item.Done.Set()
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
    }
    return @{ ok = $false; error = 'unknown_op' }
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
