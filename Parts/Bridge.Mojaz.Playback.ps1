#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    The run on air: starting it, walking the table, the urgent handling that
    interrupts it, and the state that survives a restart mid-bulletin.

    Split out of Bridge.Mojaz.ps1, which had grown to 2733 lines - three times
    the size this repository asks a file to stay under, and past the point
    where the file's own table of contents fits on a screen. Nothing moved
    between scopes: dot-sourced parts share one, so this is the same text in
    four places instead of one.
#>

# ------------------------------------------------------------------ playback

function Start-MojazPlayback {
    <#
        Shows the first row, then leaves the rest to the tick.

        The run works from a snapshot taken here and never reads the saved
        bulletin again, so editing or even deleting the table mid-bulletin
        changes what plays next time, not what is on air now.

        The show goes through the ordinary pipeline so this screen cannot skip
        maintenance mode, the layer policy, the live Cinegy check or the audit
        trail - a bulletin is still a graphic going on air.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$ScheduleId = '', [switch]$Force)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($script:MojazPlayback) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الموجز يعمل بالفعل.'
        return $false
    }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الموجز غير موجود.'
        return $false
    }
    # The urgent outranks the bulletin, so starting one underneath it is a
    # decision the operator makes rather than one this screen makes for them.
    # A scheduled start never reaches here while the urgent is up: the queue
    # holds it, and passes -Force once the air is clear.
    if (-not $Force -and (Test-MojazUrgentOnAir)) {
        Send-TelegramMessage -ChatId $ChatId `
            -Text "🚨 العاجل على الهواء الآن.`nمتى يبدأ «$([string]$bulletin.Name)»؟" `
            -ReplyMarkup (Get-MojazUrgentWaitKeyboard)
        return $false
    }
    $schedule = if ($ScheduleId) { [pscustomobject]@{ Id = $ScheduleId } } else { $null }
    $syncOffset = (Get-SettingInt 'MojazSyncOffsetMs' 400) / 1000.0
    # Resolve the two timings here rather than leaving the module to guess:
    # these are the same numbers the screen printed, so what plays is what the
    # plan line promised. The saved bulletin is not touched - the copy carries
    # them into the snapshot, which owns the timing for this run alone.
    $resolved = $bulletin | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    # Added rather than assigned: a bulletin stores frames now, so these
    # seconds exist only on this copy, for the module to plan with.
    foreach ($pair in @(
            @('DelaySeconds', (Get-MojazDelaySeconds -Bulletin $bulletin)),
            @('IntroExtraSeconds', (Get-MojazIntroSeconds -Bulletin $bulletin)),
            @('LastRowSeconds', (Get-MojazLastRowSeconds -Bulletin $bulletin)))) {
        if ($resolved.PSObject.Properties.Match($pair[0]).Count -eq 0) {
            $resolved | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]
        }
        else { $resolved.$($pair[0]) = $pair[1] }
    }
    $snapshotResult = New-MojazRunSnapshot -Bulletin $resolved -SceneTiming (Get-MojazSceneTiming) -Schedule $schedule -OffsetSeconds $syncOffset
    if (-not $snapshotResult.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الجدول فارغ.' -ReplyMarkup (Get-MojazKeyboard -Bulletin $bulletin)
        return $false
    }
    $snapshot = $snapshotResult.Value
    $rows = @($snapshot.Rows)
    # The template's picture is part of the snapshot too: a row set to
    # "template" must show the picture the scene had when the run started,
    # not one edited into it half way through.
    $templateImage = Get-MojazTemplateImage
    $result = Invoke-ShowTemplateResult -Key $script:MojazTemplateKey -Variables (Get-MojazRowVariables -Row $rows[0] -TemplateImage $templateImage) -ChatId $ChatId -UserId $UserId
    if (-not $result -or -not $result.Success) {
        $reason = if ($result) { [string](Get-JsonProp $result 'Error') } else { 'تعذّر العرض' }
        Send-TelegramMessage -ChatId $ChatId -Text "❌ لم يبدأ الموجز: $reason" -ReplyMarkup (Get-MojazKeyboard -Bulletin $bulletin)
        return $false
    }
    # Asked once, before the state is built: it is an HTTP round trip on the
    # path a bulletin takes to air, and asking twice would double both the
    # delay and the chance of it failing. $template is not in scope inside the
    # table below, which is why this is resolved out here and named.
    $airStartedAt = if (Get-Setting 'MojazAnchorToAirClock') { Get-CinegyLayerStartedAtUtc -Layer ([int](Get-MojazTemplate).Layer) } else { $null }
    $airOffset = Get-MojazAirClockOffset -StartedAtUtc $airStartedAt
    # Refused by the rule above means refused here too: an anchor not good
    # enough to time this run is not good enough to resume it either.
    if ($airOffset -le 0) { $airStartedAt = $null }
    # Said out loud, once per run. A feature whose whole claim is millisecond
    # accuracy has to report what it actually did: without this the log shows
    # a refusal but never an acceptance, so "the anchor was used" and "the
    # engine said nothing and we fell back" look identical from the outside.
    if ($airStartedAt) {
        Write-BridgeLog "Bulletin timed from Cinegy's own start: offset $([math]::Round($airOffset * 1000))ms (the SHOW round trip), fade window $([math]::Round((Get-MojazSceneFrames -Which intro) / (Get-MojazFps) * 1000))ms."
    }
    elseif (Get-Setting 'MojazAnchorToAirClock') {
        Write-BridgeLog "Bulletin timed from the bridge's own clock: Cinegy gave no usable start moment for this SHOW." 'WARN'
    }
    $script:MojazPlayback = @{
        Index = 0; ChatId = $ChatId; UserId = $UserId
        # Monotonic, and started the moment the scene is actually up: every
        # row's moment is measured from here, so a slow send delays that row
        # and no other. ClockOffset exists so a test can move time.
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
        # Anchored to the engine's own start moment when it gave one, so the
        # SHOW's round trip is not counted as part of the scene.
        ClockOffset = $airOffset
        AirStartedAt = $(if ($airStartedAt) { $airStartedAt.ToString('o') } else { '' })
        Rows = $rows
        Plan = @($snapshot.Plan)
        ExitAtSeconds = [double]$snapshot.ExitAtSeconds
        SyncToLoop = [bool]$snapshot.SyncToLoop
        BulletinId = [string]$snapshot.BulletinId
        BulletinName = [string]$snapshot.BulletinName
        # Wall clock, not the stopwatch: after a restart the stopwatch is gone
        # and this is the only thing that says how far in the run had got.
        StartedAt = (Get-Date).ToString('o')
        BulletinRevision = [int]$snapshot.BulletinRevision
        ScheduleId = $ScheduleId
        TemplateImage = $templateImage
        ActiveId = [string](Get-JsonProp $result 'ActiveId')
        ActiveIdConfirmed = [bool](Get-JsonProp $result 'ActiveIdConfirmed')
    }
    # Now that the bulletin is really on air, the strip stands down: they
    # share the bottom of the screen, and it returns when this ends.
    Hide-MojazTicker -ChatId $ChatId -UserId $UserId | Out-Null
    # The permanent trail. A bulletin reached air as a plain air_control SHOW
    # of the Mojaz scene, which says a graphic went up and nothing about which
    # bulletin it was, how many stories it carried, or whether a person or a
    # schedule started it - so a report had nothing to report.
    $script:MojazPlayback.OperationId = "mojaz-$([guid]::NewGuid().ToString('N'))"
    Write-AuditRecord -OperationId ([string]$script:MojazPlayback.OperationId) -EventName mojaz_run -Result started `
        -UserId $UserId -UserName (Get-UserDisplayName -UserId $UserId) -ChatId $ChatId -Action START `
        -Layer ([int](Get-MojazTemplate).Layer) -Target ([string]$snapshot.BulletinName) -Count ($rows.Count) `
        -Values $(if ([string]$snapshot.ScheduleId) { 'scheduled' } else { 'manual' })
    Save-MojazPlaybackState | Out-Null
    Write-BridgeLog "Mojaz playback started by $UserId ($($rows.Count) rows, $(Get-MojazDelayFrames -Bulletin $bulletin) frames each)"
    # On the record too: "every headline played twice" is a question asked
    # after the bulletin, when the screen that warned is long gone.
    $fitNote = Get-MojazBulletinLoopFitNote -Bulletin $bulletin
    if ($fitNote) { Write-BridgeLog "Mojaz row hold does not fit the scene loop: $fitNote" 'WARN' }
    Add-AuditEntry "📑 تشغيل «$([string]$snapshot.BulletinName)» ($($rows.Count) صفًّا) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Write-MojazRunEnd {
    <#
        Closes the run that Start-MojazPlayback opened, so a report can say how
        long a bulletin actually held the screen and not merely that it began.

        Called from BOTH endings - the bulletin's own stop, and the layer being
        taken by something else - because a run closed in only one of them
        would sit in the report reading "still on air" for ever.
    #>
    param([Parameter(Mandatory)]$Playback, [long]$UserId = 0, [long]$ChatId = 0)
    $user = if ($UserId -gt 0) { $UserId } else { [long](Get-JsonProp $Playback 'UserId') }
    $chat = if ($ChatId -gt 0) { $ChatId } else { [long](Get-JsonProp $Playback 'ChatId') }
    # The playback's own monotonic clock, which is the number the newsroom asks
    # about: the two audit stamps would also count a slow write between them.
    $clock = Get-JsonProp $Playback 'Clock'
    $ranMs = if ($clock) { [long]([double]$clock.Elapsed.TotalMilliseconds + [double](Get-JsonProp $Playback 'ClockOffset') * 1000) } else { 0 }
    Write-AuditRecord -OperationId ([string](Get-JsonProp $Playback 'OperationId')) -EventName mojaz_run -Result completed `
        -UserId $user -UserName (Get-UserDisplayName -UserId $user) -ChatId $chat -Action END `
        -Target ([string](Get-JsonProp $Playback 'BulletinName')) -Count (@(Get-JsonProp $Playback 'Rows').Count) `
        -DurationMs $ranMs -Values $(if ([string](Get-JsonProp $Playback 'ScheduleId')) { 'scheduled' } else { 'manual' })
}

function Stop-MojazPlayback {
    <# Ends the bulletin the way it ends itself: EXIT, so the scene plays its
       outro instead of being cut. #>
    param([long]$ChatId = 0, [long]$UserId = 0, [switch]$Quiet)
    if (-not $script:MojazPlayback) { return $false }
    $playback = $script:MojazPlayback
    $script:MojazPlayback = $null
    Clear-MojazPlaybackState
    $template = Get-MojazTemplate
    if ($template) {
        $chat = if ($ChatId -gt 0) { $ChatId } else { [long]$playback.ChatId }
        $user = if ($UserId -gt 0) { $UserId } else { [long]$playback.UserId }
        Invoke-ExitLayer -Layer ([int]$template.Layer) -ChatId $chat -UserId $user | Out-Null
    }
    Write-MojazRunEnd -Playback $playback -UserId $UserId -ChatId $ChatId
    if ([string]$playback.ScheduleId) {
        Set-MojazScheduleStatus -ScheduleId ([string]$playback.ScheduleId) -Status 'completed' -Fields @{ CompletedAt = [datetimeoffset]::Now.ToString('o') } | Out-Null
    }
    # The bulletin is off, so the strip may come back - after the outro.
    Request-MojazTickerReturn | Out-Null
    if (-not $Quiet -and $ChatId -gt 0) { Show-MojazScreen -ChatId $ChatId -UserId $UserId }
    # An urgent that agreed to wait for this bulletin goes out now.
    Update-MojazPendingUrgent | Out-Null
    return $true
}

function Get-CinegyLayerStartedAtUtc {
    <#
        When the engine says the item on this layer actually went on air.

        The active item carries ScheduledAt to the millisecond, in the
        engine's own reckoning, and it does not move while the scene loops - a
        logo shown three days ago still reports the moment it started. That
        makes it the one true zero for anything timed against the scene.

        The bridge's own clock starts when the SHOW request returns, which is
        a round trip later and jittered by whatever the poll loop was doing.
        Inside a fade of 1.2 seconds that has been good enough; it is still
        the wrong zero, and it is unavailable altogether to a bridge that has
        just restarted.

        Returns $null when the engine will not say - a blocked endpoint, a
        layer that is not up - and $null means "use the local clock", which is
        what every run did before this.
    #>
    param([Parameter(Mandatory)][int]$Layer, [int]$TimeoutSec = 0)
    if ($TimeoutSec -le 0) { $TimeoutSec = Get-AirTimeout }
    try {
        $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
            -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec $TimeoutSec
    }
    catch { return $null }
    if (-not $status -or -not [bool](Get-JsonProp $status 'Success')) { return $null }
    $xml = [string](Get-JsonProp $status 'ActiveXml')
    if ([string]::IsNullOrWhiteSpace($xml)) { return $null }
    $match = [regex]::Match($xml, 'ScheduledAt\s*=\s*"([^"]+)"')
    if (-not $match.Success) { return $null }
    $at = [datetime]::MinValue
    # RoundtripKind so the trailing Z is honoured rather than read as local
    # time, which would put the anchor hours out.
    if (-not [datetime]::TryParse($match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { return $null }
    return $at.ToUniversalTime()
}

function Get-MojazAirClockOffset {
    <#
        How far into the scene the engine says we already are, used as the
        run's starting offset so every moment afterwards is measured from the
        engine's zero rather than the bridge's.

        Takes the moment rather than reading it, so the rule lives in one
        place and the caller pays for exactly one round trip.

        Refused when it is not believable: a negative offset means the two
        clocks disagree about the present, and a large one means the item on
        that layer is not the one just shown. Either way the local clock is
        used, because a wrong anchor moves every write out of the fade, which
        is worse than the small error it was meant to remove.
    #>
    param([AllowNull()]$StartedAtUtc, [double]$MaximumSeconds = 10.0, [datetime]$Now = [datetime]::UtcNow)
    if (-not $StartedAtUtc) { return 0.0 }
    $offset = ($Now - ([datetime]$StartedAtUtc).ToUniversalTime()).TotalSeconds
    if ($offset -lt 0 -or $offset -gt $MaximumSeconds) {
        Write-BridgeLog "Ignoring the engine's start time - it is $([math]::Round($offset, 2))s away, which is not this SHOW." 'WARN'
        return 0.0
    }
    return $offset
}

function Get-MojazElapsedSeconds {
    <# How long this run has been going, by a clock that cannot step. #>
    if (-not $script:MojazPlayback) { return 0.0 }
    return ([double]$script:MojazPlayback.Clock.Elapsed.TotalSeconds + [double]$script:MojazPlayback.ClockOffset)
}

function Get-MojazUrgentTemplate {
    <# The template that outranks the bulletin. Named here for the same reason
       the bulletin's own key is: this is that newsroom's arrangement, and a
       rename in the registry is a change here. #>
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($script:MojazUrgentKey)) { return $null }
    return $store.Map[$script:MojazUrgentKey]
}

function Test-MojazUrgentOnAir {
    $template = Get-MojazUrgentTemplate
    if (-not $template) { return $false }
    return $script:OnAir.ContainsKey([int]$template.Layer)
}

function Get-MojazTickerTemplate {
    <# The news strip, which shares the bulletin's segment. #>
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($script:MojazTickerKey)) { return $null }
    return $store.Map[$script:MojazTickerKey]
}

function Hide-MojazTicker {
    <#
        The bulletin and the strip share the bottom of the screen, so the strip
        stands down while a bulletin is on air and comes back after it.

        Taken off by EXIT rather than a cut, so it leaves the way it was drawn
        to leave. Only a strip that was actually up is remembered for return:
        putting one on air that nobody had asked for would be this screen
        deciding what the channel looks like.
    #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    $script:MojazTickerReturn = $null
    if (-not (Get-Setting 'MojazHidesTicker')) { return $false }
    $template = Get-MojazTickerTemplate
    if (-not $template) { return $false }
    $layer = [int]$template.Layer
    if (-not $script:OnAir.ContainsKey($layer)) { return $false }
    $chat = if ($ChatId -gt 0) { $ChatId } else { [long](Get-JsonProp $script:OnAir[$layer] 'ChatId') }
    if ($chat -le 0) { return $false }
    Write-BridgeLog "Mojaz starting: standing the news strip down from layer $layer."
    if (-not (Invoke-ExitLayer -Layer $layer -ChatId $chat -UserId $UserId)) { return $false }
    $script:MojazTickerReturn = @{ At = $null; ChatId = $chat; UserId = $UserId }
    return $true
}

function Request-MojazTickerReturn {
    <#
        The bulletin is over; the strip goes back, but not this instant.

        The scene is still playing its outro, and putting the strip back
        underneath it would have both on screen for those few seconds - the
        overlap the stand-down existed to avoid. So the moment is booked and
        the tick carries it out, which also keeps this off the stack of
        whatever ended the bulletin.
    #>
    if (-not $script:MojazTickerReturn) { return $false }
    $timing = Get-MojazSceneTiming
    $after = if ($timing -and [double]$timing.OutroSeconds -gt 0) { [double]$timing.OutroSeconds } else { 1.0 }
    $script:MojazTickerReturn.At = (Get-Date).AddSeconds($after)
    return $true
}

function Update-MojazTickerReturn {
    <# Puts the strip back when its moment arrives. Called from the tick. #>
    if (-not $script:MojazTickerReturn -or -not $script:MojazTickerReturn.At) { return }
    if ((Get-Date) -lt [datetime]$script:MojazTickerReturn.At) { return }
    $pending = $script:MojazTickerReturn
    $script:MojazTickerReturn = $null
    $template = Get-MojazTickerTemplate
    if (-not $template) { return }
    Write-BridgeLog 'Mojaz finished: putting the news strip back.'
    Invoke-ShowTemplateResult -Key $script:MojazTickerKey -Variables @{} `
        -ChatId ([long]$pending.ChatId) -UserId ([long]$pending.UserId) | Out-Null
}

function Clear-MojazForUrgent {
    <#
        The urgent wins, always.

        Anything that puts the urgent on air takes the bulletin off first -
        including a scheduled or automated one, which is why this lives in the
        show pipeline and not behind a button. The operator is told, not
        asked: the moment an urgent goes out is the wrong moment for a
        question. The asking happens earlier, before the send.
    #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if (-not $script:MojazPlayback) { return $false }
    $name = [string]$script:MojazPlayback.BulletinName
    Stop-MojazPlayback -UserId $UserId -Quiet | Out-Null
    Write-BridgeLog 'Mojaz pulled: the urgent template takes the air.'
    Add-AuditEntry "🚨 سُحب الموجز «$name» لصالح العاجل - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    if ($ChatId -gt 0) { Send-TelegramMessage -ChatId $ChatId -Text "🚨 خرج «$name» ليفسح المجال للعاجل." }
    return $true
}

function Set-MojazPendingUrgent {
    <# An urgent held back until the bulletin finishes. Held in memory only:
       it is a wait of a minute or two, and a bridge that restarts in the
       middle of one has no bulletin left to wait for. #>
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Variables = @{},
        [int]$AutoHideSeconds = 0, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    $script:MojazPendingUrgent = @{
        Key = $Key; Variables = $Variables; AutoHideSeconds = $AutoHideSeconds
        ChatId = $ChatId; UserId = $UserId
    }
}

function Update-MojazPendingUrgent {
    <# Called where a run ends, however it ends. #>
    if (-not $script:MojazPendingUrgent) { return $false }
    $pending = $script:MojazPendingUrgent
    $script:MojazPendingUrgent = $null
    Send-TelegramMessage -ChatId ([long]$pending.ChatId) -Text '▶️ انتهى الموجز — يُرسل العاجل الآن.'
    Invoke-ShowTemplateResult -Key ([string]$pending.Key) -Variables ([hashtable]$pending.Variables) `
        -ChatId ([long]$pending.ChatId) -UserId ([long]$pending.UserId) -AutoHideSeconds ([int]$pending.AutoHideSeconds) | Out-Null
    return $true
}

function Get-MojazUrgentConflictKeyboard {
    <# Asked before the urgent goes out, while a bulletin is running. "Now" is
       first because that is what an urgent usually means. #>
    return @{ inline_keyboard = @(
            , @( (New-Button '🚨 الآن — يخرج الموجز' 'urgent:now' -Style danger) )
            , @( (New-Button '⏳ بعد انتهاء الموجز' 'urgent:after') )
            , @( (New-Button '❌ إلغاء' 'cancel') )
        ) }
}

function Get-MojazUrgentWaitKeyboard {
    <# Asked before the bulletin starts, while the urgent is on air. Waiting
       is first here: the bulletin is the thing that yields. #>
    return @{ inline_keyboard = @(
            , @( (New-Button '⏳ بعد خروج العاجل' 'mojaz:playafter' -Style success) )
            , @( (New-Button '▶️ ابدأ الآن رغم العاجل' 'mojaz:playnow') )
            , @( (New-Button '❌ إلغاء' 'mojaz:refresh') )
        ) }
}

function Start-MojazAfterUrgent {
    <#
        "Start once the urgent is gone", booked as an ordinary appointment due
        now. The queue already knows how to hold a due bulletin while the air
        is busy and start it the moment it clears, so this needs no waiting
        machinery of its own - and it survives a restart, and can be cancelled
        from the appointments screen like any other.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return $false }
    if (-not (Add-MojazSchedule -BulletinId ([string]$bulletin.Id) -ScheduledAt ([datetimeoffset]::Now) -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر حجز الموعد. لم يتغيّر شيء.'
        return $false
    }
    Add-AuditEntry "⏳ تأجيل «$([string]$bulletin.Name)» إلى ما بعد العاجل - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "⏳ سيبدأ «$([string]$bulletin.Name)» فور خروج العاجل."
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Send-MojazPendingUrgentNow {
    <# The urgent goes out at once; the pipeline pulls the bulletin off as it
       passes through. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:MojazPendingUrgent) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد عاجل بانتظار الإرسال.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    $pending = $script:MojazPendingUrgent
    $script:MojazPendingUrgent = $null
    Invoke-ShowTemplateResult -Key ([string]$pending.Key) -Variables ([hashtable]$pending.Variables) `
        -ChatId $ChatId -UserId $UserId -AutoHideSeconds ([int]$pending.AutoHideSeconds) | Out-Null
    return $true
}

function Confirm-MojazPendingUrgent {
    <# It waits. The bulletin's own ending sends it. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:MojazPendingUrgent) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد عاجل بانتظار الإرسال.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    Add-AuditEntry "⏳ تأجيل العاجل إلى ما بعد الموجز - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text '⏳ ينتظر العاجل انتهاء الموجز، ثم يخرج وحده.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $true
}

function Test-MojazOnAirLayer {
    <# Is the bulletin's layer occupied - by a run, or by a scene the bridge
       itself put there and has not taken down? #>
    $template = Get-MojazTemplate
    if (-not $template) { return $false }
    if ($script:MojazPlayback) { return $true }
    return $script:OnAir.ContainsKey([int]$template.Layer)
}

function Stop-MojazForLayer {
    <#
        The bulletin's layer is being taken off air by something that is not
        this screen - the hide button on the main menu, an exit, hide-all.

        The run has to end with it. Left alone it would keep writing rows into
        a scene nobody can see and then send an EXIT of its own, long after the
        operator believed it was gone. The caller is already removing the
        layer, so this does not exit again - it only closes the run.
    #>
    param([Parameter(Mandatory)][int]$Layer)
    if (-not $script:MojazPlayback) { return $false }
    $template = Get-MojazTemplate
    if (-not $template -or [int]$template.Layer -ne $Layer) { return $false }
    $playback = $script:MojazPlayback
    $script:MojazPlayback = $null
    Clear-MojazPlaybackState
    Write-MojazRunEnd -Playback $playback
    if ([string]$playback.ScheduleId) {
        Set-MojazScheduleStatus -ScheduleId ([string]$playback.ScheduleId) -Status 'completed' -Fields @{ CompletedAt = [datetimeoffset]::Now.ToString('o') } | Out-Null
    }
    Write-BridgeLog "Mojaz playback ended: layer $Layer was taken off air."
    Request-MojazTickerReturn | Out-Null
    return $true
}

function Hide-MojazOnAir {
    <# The main menu's way out of a bulletin: stop the run if there is one, and
       leave by EXIT so the scene plays its outro instead of being cut. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $template = Get-MojazTemplate
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد قالب للموجز.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    if ($script:MojazPlayback) {
        # Stop-MojazPlayback exits the layer itself.
        Stop-MojazPlayback -UserId $UserId -Quiet | Out-Null
    }
    elseif ($script:OnAir.ContainsKey([int]$template.Layer)) {
        Invoke-ExitLayer -Layer ([int]$template.Layer) -ChatId $ChatId -UserId $UserId | Out-Null
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text 'الموجز ليس على الهواء.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    Add-AuditEntry "⏹ إخفاء الموجز - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text '⏹ خرج الموجز.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $true
}

function Get-MojazPlaybackFile {
    return (Join-Path $logDir 'mojaz-playback.json')
}

function Save-MojazPlaybackState {
    <#
        The run, on disk, so a restart does not abandon a bulletin on air.

        Everything else the bridge holds survives a restart - what is on air,
        the auto-hide timers, the reminders, the schedule - and the bulletin
        playback was the one exception. When the bridge went down mid-run the
        scene stayed exactly where it was, looping, with nobody left to write
        the next row into it or to send the EXIT that ends it; an operator had
        to take it off by hand.

        Written once at the start, not on every row: the plan holds absolute
        moments measured from StartedAt, so where a run has got to is a
        subtraction, not a thing to keep writing down.
    #>
    if (-not $script:MojazPlayback) { return $false }
    try {
        $playback = $script:MojazPlayback
        $state = [ordered]@{
            StartedAt = [string]$playback.StartedAt
            BulletinId = [string]$playback.BulletinId
            BulletinName = [string]$playback.BulletinName
            ScheduleId = [string](Get-JsonProp $playback 'ScheduleId')
            OperationId = [string](Get-JsonProp $playback 'OperationId')
            AirStartedAt = [string](Get-JsonProp $playback 'AirStartedAt')
            TemplateImage = [string](Get-JsonProp $playback 'TemplateImage')
            ActiveId = [string](Get-JsonProp $playback 'ActiveId')
            ActiveIdConfirmed = [bool](Get-JsonProp $playback 'ActiveIdConfirmed')
            ChatId = [long]$playback.ChatId
            UserId = [long]$playback.UserId
            ExitAtSeconds = [double]$playback.ExitAtSeconds
            SyncToLoop = [bool]$playback.SyncToLoop
            Rows = @($playback.Rows)
            Plan = @($playback.Plan)
        }
        return (Write-BridgeValidatedJson -Path (Get-MojazPlaybackFile) -Json ($state | ConvertTo-Json -Depth 8))
    }
    catch { Write-BridgeLog "Could not write mojaz-playback.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Clear-MojazPlaybackState {
    Remove-Item -LiteralPath (Get-MojazPlaybackFile) -Force -ErrorAction SilentlyContinue
}

function Restore-MojazPlayback {
    <#
        Picks a bulletin back up where the clock says it should be.

        The plan's moments are absolute from the start of the run, which is
        what makes this possible at all: elapsed time alone says which row is
        due, so the run rejoins its own schedule instead of restarting.

        Three endings. The layer is no longer the bulletin's - somebody dealt
        with it already - so the file is dropped. The run is past its exit -
        the scene is looping with nobody to end it - so it is ended. Otherwise
        it resumes, and the administrators are told either way, because a
        bulletin that carried on across a restart is not something to discover
        from the screen.
    #>
    param([datetime]$Now = (Get-Date))
    $path = Get-MojazPlaybackFile
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch {
        Write-BridgeLog "Could not read mojaz-playback.json: $($_.Exception.Message)" 'WARN'
        Clear-MojazPlaybackState
        return $false
    }
    Clear-MojazPlaybackState
    $startedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string](Get-JsonProp $state 'StartedAt'), [ref]$startedAt)) { return $false }
    $template = Get-MojazTemplate
    if (-not $template) { return $false }
    $layer = [int]$template.Layer
    # Only if the bulletin's scene is still the thing on that layer. Anything
    # else means it has already been dealt with, and this must not touch a
    # layer that now belongs to something else.
    if (-not $script:OnAir.ContainsKey($layer) -or
        [string](Get-JsonProp $script:OnAir[$layer] 'Key') -ne [string]$script:MojazTemplateKey) {
        return $false
    }
    $elapsed = ($Now - $startedAt).TotalSeconds
    # The engine's own start beats the bridge's note of it: it survives the
    # restart intact, and it is what the scene's loop is actually running to.
    $engineStart = [datetime]::MinValue
    if ([datetime]::TryParse([string](Get-JsonProp $state 'AirStartedAt'), [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$engineStart)) {
        $fromEngine = ($Now.ToUniversalTime() - $engineStart.ToUniversalTime()).TotalSeconds
        if ($fromEngine -ge 0) { $elapsed = $fromEngine }
    }
    $exitAt = [double](Get-JsonProp $state 'ExitAtSeconds')
    $name = [string](Get-JsonProp $state 'BulletinName')
    $chat = [long](Get-JsonProp $state 'ChatId')
    $user = [long](Get-JsonProp $state 'UserId')
    # A template key can be reused by a newer run. Both postbox writes and exit
    # must belong to the engine identity confirmed for this saved run, never
    # the unconfirmed client EventId retained when SHOW verification failed.
    $expectedId = ([string](Get-JsonProp $state 'ActiveId')).Trim().Trim('{', '}')
    $live = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $layer -TimeoutSec (Get-AirTimeout)
    $liveId = ([string](Get-JsonProp $live 'ActiveId')).Trim().Trim('{', '}')
    if (-not [bool](Get-JsonProp $state 'ActiveIdConfirmed') -or
        -not [bool](Get-JsonProp $live 'Success') -or -not $expectedId -or -not $liveId -or
        -not $liveId.Equals($expectedId, [StringComparison]::OrdinalIgnoreCase)) {
        Write-BridgeLog "Refused to restore bulletin '$name': live scene identity could not be matched." 'WARN'
        Send-AdminBroadcast -Text "⚠️ لم يُستأنف الموجز «$name» أو يُخرج بعد إعادة التشغيل لأن هوية المشهد على الطبقة تغيّرت أو تعذّر التحقق منها." | Out-Null
        return $false
    }
    if ($elapsed -ge $exitAt) {
        Write-BridgeLog "A bulletin ('$name') was still on air after a restart and past its end; taking it off." 'WARN'
        Invoke-ExitLayer -Layer $layer -ChatId $chat -UserId $user | Out-Null
        Request-MojazTickerReturn | Out-Null
        Send-AdminBroadcast -Text "⏹ كان الموجز «$name» على الهواء لحظة إعادة التشغيل وقد تجاوز وقت خروجه، فأُخرج الآن." | Out-Null
        return $true
    }
    $rows = @(Get-JsonProp $state 'Plan')
    $index = @($rows | Where-Object { [double](Get-JsonProp $_ 'AtSeconds') -le $elapsed }).Count - 1
    if ($index -lt 0) { $index = 0 }
    $script:MojazPlayback = @{
        Index = $index; ChatId = $chat; UserId = $user
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
        # The run rejoins its own timeline: the clock starts at zero now, and
        # the offset carries everything that happened before the restart.
        ClockOffset = $elapsed
        Rows = @(Get-JsonProp $state 'Rows')
        Plan = @(Get-JsonProp $state 'Plan')
        ExitAtSeconds = $exitAt
        SyncToLoop = [bool](Get-JsonProp $state 'SyncToLoop')
        BulletinId = [string](Get-JsonProp $state 'BulletinId')
        BulletinName = $name
        ScheduleId = [string](Get-JsonProp $state 'ScheduleId')
        OperationId = [string](Get-JsonProp $state 'OperationId')
        StartedAt = [string](Get-JsonProp $state 'StartedAt')
        AirStartedAt = [string](Get-JsonProp $state 'AirStartedAt')
        TemplateImage = [string](Get-JsonProp $state 'TemplateImage')
        ActiveId = [string](Get-JsonProp $state 'ActiveId')
        ActiveIdConfirmed = [bool](Get-JsonProp $state 'ActiveIdConfirmed')
    }
    $currentValues = Get-MojazRowVariables -Row $script:MojazPlayback.Rows[$index] `
        -TemplateImage ([string]$script:MojazPlayback.TemplateImage)
    $resumeResult = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Values $currentValues -TimeoutSec (Get-AirTimeout)
    if (-not $resumeResult.Success) {
        Write-BridgeLog "Could not restore bulletin '$name' row $($index + 1): $($resumeResult.Error)" 'WARN'
        $script:MojazPlayback = $null
        return $false
    }
    Save-MojazPlaybackState | Out-Null
    Write-BridgeLog "Resumed the bulletin '$name' after a restart at row $($index + 1) of $(@($script:MojazPlayback.Rows).Count), $([int]$elapsed)s in."
    Send-AdminBroadcast -Text "▶️ استُؤنف الموجز «$name» بعد إعادة التشغيل عند الصف $($index + 1)." | Out-Null
    return $true
}

function Update-MojazPlayback {
    <#
        One step of the bulletin, called from the tick.

        Rows after the first are pushed through the postbox, which is what
        changes a running scene's values without restarting it.

        Each moment is absolute, measured from the start of the run, so a slow
        send delays its own row and none of the ones behind it. The tick is
        about a second apart - too coarse for a fade that lasts just over a
        second - so once a moment is close this waits out the remainder itself
        and sends on time. That blocks the bot for at most PreRoll, once per
        row, which is the price of landing inside the window.
    #>
    if (-not $script:MojazPlayback) { return }
    $rows = @($script:MojazPlayback.Rows)
    $index = [int]$script:MojazPlayback.Index
    $isLast = ($index -ge ($rows.Count - 1))
    $moment = if ($isLast) { [double]$script:MojazPlayback.ExitAtSeconds } else { [double]$script:MojazPlayback.Plan[$index + 1].AtSeconds }
    # Sent early by the measured round trip, so it arrives at the moment
    # rather than after it. Calibrate against air, not against theory.
    $target = $moment - ((Get-SettingInt 'MojazSyncLeadMs' 120) / 1000.0)
    if ((Get-MojazElapsedSeconds) -lt ($target - $script:MojazPreRollSeconds)) { return }
    $remaining = $target - (Get-MojazElapsedSeconds)
    if ($remaining -gt 0) {
        Start-Sleep -Milliseconds ([int][math]::Min(($script:MojazPreRollSeconds * 1000), ($remaining * 1000)))
    }
    if ($isLast) {
        Write-BridgeLog "Mojaz playback finished after $($rows.Count) row(s)"
        # Every other way a bulletin ends says so already - a button press, an
        # urgent taking over, a failed row. This is the one that finishes on
        # its own minutes after the operator stopped watching.
        if (Get-Setting 'MojazNotifyOnFinish') {
            $finishedName = [string]$script:MojazPlayback.BulletinName
            Send-TelegramMessage -ChatId ([long]$script:MojazPlayback.ChatId) -Text "⏹ انتهى «$finishedName» وخرج عن الهواء."
        }
        Stop-MojazPlayback -Quiet | Out-Null
        return
    }
    $index++
    $values = Get-MojazRowVariables -Row $rows[$index] -TemplateImage ([string](Get-JsonProp $script:MojazPlayback 'TemplateImage'))
    $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Values $values -TimeoutSec (Get-AirTimeout)
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Mojaz POSTBOX XML: $($result.Xml)" }
    if (-not $result.Success) {
        Write-BridgeLog "Mojaz row $($index + 1) failed: $($result.Error)" 'WARN'
        Send-TelegramMessage -ChatId ([long]$script:MojazPlayback.ChatId) -Text "❌ توقّف الموجز عند الصف $($index + 1): $($result.Error)"
        Stop-MojazPlayback -Quiet | Out-Null
        return
    }
    $script:MojazPlayback.Index = $index
}

function Update-MojazImageCleanup {
    <#
        Pictures whose row is gone.

        Deleting a row does not delete its picture, because the same file may
        be on air in the run that is playing, or referenced by another
        bulletin. So the sweep is deliberately narrow: only files this bridge
        named itself, only inside the bulletin's own picture folder, only when
        no saved row and no running snapshot mentions them, and only once they
        are a day old - long enough that a picture uploaded for a row still
        being written is never taken out from under it.
    #>
    param([int]$MinimumAgeHours = 0, [switch]$Force)
    # Once an hour, not once a tick. This walks a directory, and it was doing
    # so on the polling thread every time round the loop - for a job whose
    # whole premise is that nothing has touched those files in a day.
    if (-not $Force -and $script:LastMojazImageSweep -and ((Get-Date) - $script:LastMojazImageSweep).TotalMinutes -lt 60) { return 0 }
    $script:LastMojazImageSweep = Get-Date
    if ($MinimumAgeHours -le 0) { $MinimumAgeHours = Get-SettingInt 'MojazImageKeepHours' 48 }
    # Zero turns the sweep off: a newsroom that wants to keep every picture it
    # ever uploaded is allowed to.
    if ($MinimumAgeHours -le 0) { return 0 }
    $directory = Get-MojazUploadDirectory
    if (-not $directory -or -not (Test-Path -LiteralPath $directory)) { return 0 }
    $referenced = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($bulletin in @(Get-JsonProp $script:MojazLibrary 'Bulletins')) {
        foreach ($row in @(Get-JsonProp $bulletin 'Rows')) {
            $image = [string](Get-JsonProp $row 'Image')
            if ($image) { $referenced.Add((Split-Path -Path $image -Leaf)) | Out-Null }
        }
    }
    if ($script:MojazPlayback) {
        foreach ($row in @($script:MojazPlayback.Rows)) {
            $image = [string](Get-JsonProp $row 'Image')
            if ($image) { $referenced.Add((Split-Path -Path $image -Leaf)) | Out-Null }
        }
    }
    $cutoff = (Get-Date).AddHours(-1 * [math]::Max(1, $MinimumAgeHours))
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -notmatch $script:MojazUploadPattern) { continue }
        if ($referenced.Contains($file.Name)) { continue }
        if ($file.LastWriteTime -gt $cutoff) { continue }
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $removed++ }
        catch { Write-BridgeLog "Could not remove the orphaned Mojaz picture '$($file.Name)': $($_.Exception.Message)" 'WARN' }
    }
    if ($removed -gt 0) { Write-BridgeLog "Removed $removed orphaned Mojaz picture(s)." }
    return $removed
}
