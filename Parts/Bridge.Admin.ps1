#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-AirTimeout {
    <# Air Pro sits on localhost or the local LAN, so the module's 10s default
       is far too generous: every graphics command blocks the single polling
       loop for its full timeout, and 🚨 إخفاء الكل multiplies that by the
       number of layers - on the one button that gets pressed in a crisis. #>
    $value = Get-SettingInt 'AirCommandTimeoutSeconds' 1
    if ($value -le 0) { $value = 3 }
    return $value
}

function Get-OnAirSummary {
    <# Shows the bridge's tracked layers after they have been reconciled with
       Cinegy. Externally started scenes cannot be named reliably, but a scene
       hidden outside the bridge is removed by Update-OnAirStateFromCinegy. #>
    if ($script:OnAir.Count -eq 0) { return "📺 المشاهد النشطة`n• لا توجد مشاهد على الهواء حسب آخر فحص." }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'adm.activeScenes'))
    foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
        $info = $script:OnAir[$layer]
        # A ticker up since yesterday used to read "1560 دقيقة".
        $age = [math]::Max(0, [int]((Get-Date) - $info.At).TotalSeconds)
        $ageText = Format-DurationSeconds -Seconds $age
        $source = [string](Get-JsonProp $info 'Source')
        if ($source -eq 'cinegy') {
            $eventName = [string](Get-JsonProp $info 'CinegyEventName')
            $detail = "   المصدر: Cinegy Air · منذ $ageText"
            if ($eventName) { $detail += " · الحدث: $eventName" }
            $lines.Add("🟣 $(Get-LayerDisplayName -Layer ([int]$layer)) · $($info.Key)")
            $lines.Add($detail)
        }
        else {
            $operator = if ($null -ne $info.UserId -and [long]$info.UserId -gt 0) { Get-UserDisplayName -UserId ([long]$info.UserId) } else { (T 'adm.unknown') }
            $lines.Add("🔵 $(Get-LayerDisplayName -Layer ([int]$layer)) · $($info.Key)")
            $lines.Add("   المصدر: Bot · المستخدم: $operator · منذ $ageText")
        }
    }
    return ($lines -join "`n")
}

function Get-OnAirTableBlocks {
    <#
        What is on air, as a table.

        This is the one genuinely tabular thing on a status screen - a layer,
        what is on it, since when - and it was a run-on sentence. Four
        columns, like every other table here, because Telegram divides the
        width evenly and a fifth would take a fifth of the phone.
    #>
    param([datetime]$Now = (Get-Date))
    if ($script:OnAir.Count -eq 0) {
        return @(@{ type = 'paragraph'; text = (T 'adm.nothingOnAir') })
    }
    $cells = @(, @(
            @{ text = (T 'adm.col.layer'); is_header = $true }
            @{ text = (T 'adm.col.template'); is_header = $true }
            @{ text = (T 'adm.col.since'); is_header = $true }
            @{ text = (T 'adm.col.operator'); is_header = $true }
        ))
    foreach ($layer in @($script:OnAir.Keys | Sort-Object)) {
        $record = $script:OnAir[$layer]
        $atValue = Get-JsonProp $record 'At'
        $since = if ($atValue) {
            $at = [datetime]$atValue
            $seconds = [math]::Max(0, [int]($Now - $at).TotalSeconds)
            # "منذ 0 ثانية" is a strange way to say it just went up.
            if ($seconds -lt 5) { (T 'adm.now') } else { Format-DurationSeconds -Seconds $seconds }
        }
        else { '—' }
        $who = Get-AuditOperatorName -UserId ([string](Get-JsonProp $record 'UserId'))
        $cells += , @(
            @{ text = [string]$layer }
            @{ text = [string](Get-JsonProp $record 'Key') }
            @{ text = $since }
            @{ text = $(if ($who) { $who } else { '—' }) }
        )
    }
    return @(@{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true })
}

function Get-AirMaterialNowNext {
    <#
        What the channel is playing and what it has cued, as one line.

        The bridge has always known what IT put on air and nothing about the
        programme underneath, so "is this the right moment for the strap" was a
        question answered by opening Cinegy. Two short reads answer it here.

        Returns '' rather than an error line when the channel cannot be
        reached: this sits on a status screen that already reports Cinegy
        health above it, and a second failure notice in the same screen reads
        as two faults.
    #>
    param([int]$TimeoutSec = 0)
    if ($TimeoutSec -le 0) { $TimeoutSec = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1 }
    $status = Get-AirVideoStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $TimeoutSec
    if (-not $status.Success) { return '' }
    if (-not $status.ActiveId -and -not $status.CuedId) { return '' }

    $schedule = Get-AirMaterialSchedule -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $TimeoutSec
    $byId = @{}
    foreach ($item in @($schedule.Items)) { $byId[[string]$item.Id.Trim('{', '}')] = $item }

    $describe = {
        param([string]$Id, [switch]$WithRemaining)
        if (-not $Id) { return '' }
        if (-not $byId.ContainsKey($Id)) { return (T 'adm.materialNotScheduled') }
        $item = $byId[$Id]
        $text = ConvertTo-TelegramHtmlText ([string]$item.Name)
        if ($WithRemaining -and $item.Duration -gt [timespan]::Zero) {
            $left = ($item.ScheduledAt + $item.Duration) - [datetimeoffset]::Now
            # Only while it is plausible: a schedule that has drifted would
            # otherwise report a programme ending three hours ago.
            if ($left -gt [timespan]::Zero -and $left -lt $item.Duration) {
                $text += " · تبقّى <code>$([int]$left.TotalMinutes) د</code>"
            }
        }
        return $text
    }

    $now = [string](& $describe $status.ActiveId -WithRemaining)
    $next = [string](& $describe $status.CuedId)
    $parts = @()
    if ($now) { $parts += "▶️ الجاري: $now" }
    if ($next) { $parts += "⏭ التالي: $next" }
    if ($parts.Count -eq 0) { return '' }
    return ($parts -join "`n")
}

function Show-MaterialScheduleScreen {
    <#
        What the channel is scheduled to play today.

        The bridge could always say what IT put on air and nothing about the
        material underneath, so an operator deciding whether a moment suited a
        strap opened Cinegy to find out. This is that list, with the item now
        playing marked.

        Trimmed like every table here: twenty-four items was a measured day on
        this station, and a day is not every day.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $timeout = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1
    $schedule = Get-AirMaterialSchedule -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
    $keyboard = @{ inline_keyboard = @(, @((New-Button (T 'adm.refresh') 'menu:material'), (New-Button (T 'adm.menu') 'menu'))) }
    if (-not $schedule.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'adm.materialUnreadable') -ReplyMarkup $keyboard
        return
    }
    $items = @($schedule.Items)
    if ($items.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'adm.noMaterial') -ReplyMarkup $keyboard
        return
    }
    $status = Get-AirVideoStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
    $activeId = [string]$status.ActiveId

    $trimmed = Select-RichTableRows -Items $items
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'adm.materialTitle'))
    foreach ($item in @($trimmed.Rows)) {
        $bare = ([string]$item.Id).Trim('{', '}')
        $mark = if ($bare -eq $activeId) { '▶️' } else { '•' }
        $lines.Add("$mark <code>$($item.ScheduledAt.ToLocalTime().ToString('HH:mm'))</code> $(ConvertTo-TelegramHtmlText ([string]$item.Name))")
    }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown @($trimmed.Rows).Count
    if ($note) { $lines.Add($note) }
    Send-TelegramPagedText -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup $keyboard -ParseMode HTML
}

function Get-HandoverAutoSummary {
    <#
        F7: the three lines the receiver would otherwise miss. Failures are
        read newest-first from the in-memory audit trail (already stamped and
        carrying their own markup, so they are used as-is, trimmed to one
        screen line each); then the single most repeated alert cause, which
        arrives escaped because it is derived from raw alert text.
    #>
    $found = @()
    # The stamp is "HH:mm:ss" today and "MM-dd HH:mm:ss" older, so the emoji
    # is matched within the line's head rather than after one token.
    $failures = @(@($script:AuditTrail) | Where-Object { $_ -match '^.{0,18}[❌⛔⚠️]' } | Select-Object -Last 2)
    [array]::Reverse($failures)
    foreach ($entry in $failures) {
        $line = [string]$entry
        if ($line.Length -gt 140) { $line = $line.Substring(0, 140) + '…' }
        $found += $line
    }
    $topCause = $null
    $topCount = 0
    foreach ($cause in @($script:AlertHistory.Keys)) {
        $times = @(@($script:AlertHistory[$cause]) | Where-Object { $_ -is [datetime] })
        if ($times.Count -ge 3 -and $times.Count -gt $topCount) {
            $topCount = $times.Count
            $topCause = [string]$cause
        }
    }
    if ($topCause -and $found.Count -lt 3) {
        $found += "🔁 يتكرر: $(ConvertTo-TelegramHtmlText $topCause) ($(Get-ArabicCountNoun -Count $topCount -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' -EnglishOne 'time' -EnglishMany 'times'))"
    }
    return @($found | Select-Object -First 3)
}

function Get-DisabledGuardLines {
    <#
        Which protections are switched off right now, each said as its
        consequence rather than its setting name.

        The readiness screen below reads runtime state - what is on air, what
        is pending, which chats are quarantined - and answers "is the station
        clean". It never read configuration, so a shift could begin on a
        bridge with safe rollback off and no test layer and nothing anywhere
        said so. Three of these ship off by default (EnableSafeRollback,
        TemplateTestLayer, EnableDpapiSecrets), which is the whole reason this
        exists: a protection nobody was told about is a protection nobody has.

        Each line leads with the RESULT - "no undo after a wrong graphic" is
        something an operator can act on, where "EnableSafeRollback is off" is
        a lookup. The setting name follows so it can be found and flipped.

        EnableRawCommand is deliberately NOT here even though it is a
        protected setting: it defaults to on and is admin-gated, so its line
        would appear on every station forever and be acted on by none. This
        screen dies the day it becomes wallpaper, and the repository has paid
        for that lesson once already in the notification rules.

        The table is fixed, so the output is bounded by construction: it
        cannot grow with station data the way a template or user table can,
        and so needs no trim note.
    #>
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($guard in @(
            @{ Name = 'MaintenanceMode'; WeakWhen = $true; Text = (T 'adm.maintenanceOn') }
            @{ Name = 'SchedulePaused'; WeakWhen = $true; Text = (T 'adm.schedulePaused') }
            @{ Name = 'EnableSafeRollback'; WeakWhen = $false; Text = (T 'adm.noRollback') }
            @{ Name = 'ConfirmLayerRemoval'; WeakWhen = $false; Text = (T 'adm.hideNoConfirm') }
            @{ Name = 'RequireUserLevelAuth'; WeakWhen = $false; Text = (T 'adm.chatLevelAuth') }
            @{ Name = 'EnableFullTemplateManagement'; WeakWhen = $true; Text = (T 'adm.templateEditOpen') }
            @{ Name = 'BlockRejectedRequesters'; WeakWhen = $false; Text = (T 'adm.rejectedCanRetry') }
            @{ Name = 'LeaveUnknownGroups'; WeakWhen = $false; Text = (T 'adm.staysInGroups') }
            @{ Name = 'EnableDpapiSecrets'; WeakWhen = $false; Text = (T 'adm.tokenPlaintext') }
            @{ Name = 'NotifyAdminsOnMissingGraphic'; WeakWhen = $false; Text = (T 'adm.noMissingGraphicAlert') }
            @{ Name = 'EnableTextChecks'; WeakWhen = $false; Text = (T 'adm.noSpellWarnings') }
        )) {
        if ([bool](Get-Setting $guard.Name) -eq [bool]$guard.WeakWhen) {
            $lines.Add("• $($guard.Text) <code>$($guard.Name)</code>")
        }
    }
    # The one number in the list: 0 disables template testing entirely, so
    # there is nowhere to try a template outside the programme.
    if ((Get-SettingInt 'TemplateTestLayer') -le 0) {
        $lines.Add((T 'adm.noTestLayer'))
    }
    return $lines.ToArray()
}

function Show-ShiftReadinessScreen {
    <#
        P5: the incoming shift starts from certainty, not from flipping
        through screens. Read-only aggregation of what the bridge already
        knows: layers on air, open drafts, quarantined chats, pinned faults,
        quiet state. The live probe stays the existing selftest behind its
        own button - this screen never touches the air itself.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'adm.readinessTitle'))
    $onAir = @($script:OnAir.Keys).Count
    $lines.Add($(if ($onAir -gt 0) { "🟠 طبقات على الهواء الآن: <code>$onAir</code> — راجعها قبل أن تلمس شيئًا." } else { (T 'adm.nothingOnAirGreen') }))
    $pending = @($script:PendingState.Keys).Count
    $lines.Add($(if ($pending -gt 0) { "⏳ عمليات معلقة بانتظار أصحابها: <code>$pending</code>." } else { (T 'adm.noPending') }))
    $lines.Add($(
            if (Test-NewsTickerDraftOpen -Draft $script:NewsTickerDraft) { (T 'adm.draftUnowned') }
            elseif ($script:NewsTickerDraft) { "📰 مسودة شريط مفتوحة ($(Format-UserAuditActor -UserId ([long](Get-JsonProp $script:NewsTickerDraft 'OwnerUserId'))))." }
            else { (T 'adm.noDraft') }))
    $dead = @($script:DeadChats.Keys).Count
    $lines.Add($(if ($dead -gt 0) { "💀 محادثات محجورة بانتظار قرار: <code>$dead</code>." } else { (T 'adm.noQuarantined') }))
    $pins = @($script:PinnedRecurrences.Keys).Count
    $lines.Add($(if ($pins -gt 0) { "📌 أعطال مثبّتة لم تُحل: <code>$pins</code>." } else { (T 'adm.noStandingFaults') }))
    $lines.Add($(if (Test-QuietHoursActive) { (T 'adm.quietOn') } else { (T 'adm.alertsDirect') }))
    $ready = ($onAir -eq 0 -and $pending -eq 0 -and -not $script:NewsTickerDraft -and $dead -eq 0 -and $pins -eq 0)
    $lines.Add('')
    $lines.Add($(if ($ready) { (T 'adm.readyVerdict') } else { (T 'adm.notCleanVerdict') }))
    # Kept out of $ready on purpose: a switched-off guard is a standing
    # choice about how this station is configured, not dirt left by the
    # outgoing shift. Folding it into the verdict would mean a bridge running
    # its own defaults never reads clean, and a verdict that is never green
    # stops being read.
    $guards = @(Get-DisabledGuardLines)
    $lines.Add('')
    if ($guards.Count -gt 0) {
        $lines.Add("🛡 <b>حمايات معطّلة</b> (<code>$($guards.Count)</code>) — اختيار إعداد، لا عطل:")
        foreach ($guard in $guards) { $lines.Add($guard) }
        $lines.Add((T 'adm.changedInSettings'))
    }
    else { $lines.Add((T 'adm.noProtectionOff')) }
    $keyboard = @{ inline_keyboard = @(
        , @((New-Button (T 'adm.livePathCheck') 'menu:selftest'), (New-Button (T 'adm.handover') 'menu:handover'))
        , @((New-Button (T 'adm.backToTools') 'menu:admintools'))
    ) }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup $keyboard
}

function Show-ShiftHandoverScreen {
    <#
        Everything a shift change needs, on one screen.

        Asked how handovers happen here, the station said shifts exist but the
        handover is usually spoken - which is exactly where what nobody
        mentions gets lost. This does not replace the conversation; it gives it
        a checklist and leaves a record.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'adm.handoverTitle'))
    $lines.Add("🕒 <code>$((Get-Date).ToString('yyyy-MM-dd HH:mm'))</code>")

    $material = Get-AirMaterialNowNext
    if ($material) { $lines.Add(''); $lines.Add($material) }

    $lines.Add('')
    if ($script:OnAir.Count -eq 0) { $lines.Add((T 'adm.nothingFromBridge')) }
    else {
        $lines.Add((T 'adm.onAirNow'))
        foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
            $record = $script:OnAir[$layer]
            $since = ''
            $at = Get-JsonProp $record 'At'
            if ($at) {
                $stamp = [datetime]::MinValue
                if ([datetime]::TryParse([string]$at, [ref]$stamp)) {
                    $since = " · منذ $(Format-Duration -Seconds ([int]((Get-Date) - $stamp).TotalSeconds))"
                }
            }
            $who = [long](Get-JsonProp $record 'UserId')
            $byText = if ($who -gt 0) { " · $(ConvertTo-TelegramHtmlText (Get-UserDisplayName -UserId $who))" } else { '' }
            $lines.Add("• طبقة $layer · $(ConvertTo-TelegramHtmlText ([string](Get-JsonProp $record 'Key')))$since$byText")
        }
    }

    $upcoming = @(Get-UpcomingScheduleEvents | Select-Object -First 5)
    $lines.Add('')
    if ($upcoming.Count -eq 0) { $lines.Add((T 'adm.noUpcoming')) }
    else {
        $lines.Add((T 'adm.upcomingTitle'))
        foreach ($entry in $upcoming) {
            $at = [datetimeoffset]$entry.ScheduledAt
            $lines.Add("• <code>$($at.ToLocalTime().ToString('MM-dd HH:mm'))</code> $(ConvertTo-TelegramHtmlText ([string]$entry.TemplateKey))")
        }
    }

    # Drafts belong here more than anywhere. A half-written headline in
    # somebody else's chat is invisible to the person taking over, and it will
    # swallow their next message if they inherit the handset.
    $drafts = @(foreach ($chat in @($script:PendingState.Keys)) {
            $state = $script:PendingState[$chat]
            if ([string]$state.Mode -notin @('show_fields', 'show_review')) { continue }
            "• $(ConvertTo-TelegramHtmlText ([string]$state.Key)) · $(ConvertTo-TelegramHtmlText (Get-UserDisplayName -UserId ([long](Get-JsonProp $state 'UserId'))))"
        })
    $lines.Add('')
    if ($drafts.Count -gt 0) {
        $lines.Add((T 'adm.openDraftsTitle'))
        foreach ($draft in $drafts) { $lines.Add($draft) }
    }
    else { $lines.Add((T 'adm.noOpenDrafts')) }

    # F7: the handover writes itself. The receiver reads what is on air, what
    # is coming and what is half-written above; what they would otherwise
    # miss is what went wrong and what keeps going wrong. At most three
    # lines, newest failure first, then the most repeated cause.
    $autoSummary = @(Get-HandoverAutoSummary)
    if ($autoSummary.Count -gt 0) {
        $lines.Add('')
        $lines.Add((T 'adm.autoImportant'))
        foreach ($line in $autoSummary) { $lines.Add($line) }
    }

    $lines.Add('')
    $lines.Add((T 'adm.handoverNote'))
    $keyboard = @{ inline_keyboard = @(
            , @((New-Button (T 'adm.handedOver') 'handover:done' -Style success))
            , @((New-Button (T 'adm.refresh') 'menu:handover'), (New-Button (T 'adm.menu') 'menu'))
        ) }
    Send-TelegramPagedText -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup $keyboard -ParseMode HTML
}

function Get-StatusRichBlocks {
    <#
        A status screen as blocks: the verdict, who is asking, what the
        channel is playing, what the bridge has on air, and the machine detail
        below it in named sections.

        The lines are passed in rather than rebuilt, so the block screen and
        the text screen cannot disagree - they are the same strings. Only the
        shape differs: the verdict gets a heading, the on-air layers get a
        table, and the rest becomes the detail nobody reads unless the
        verdict says to.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Overall,
        [AllowNull()][object[]]$DetailLines = $null,
        [AllowEmptyString()][string]$Identity = '',
        [AllowEmptyString()][string]$Clock = '',
        [AllowNull()][object[]]$Highlights = $null
    )
    $blocks = @(@{ type = 'heading'; text = "$Title — v$($script:BridgeVersion)"; size = 3 })
    $blocks += @{ type = 'paragraph'; text = $Overall }
    # Above the fold rather than inside the collapsed detail: the id is what
    # an operator is asked for when requesting access or reporting a fault,
    # and a fact you have to expand a section to reach is a fact people
    # screenshot wrongly. It is kept out of the details list so it appears
    # exactly once on the screen.
    if (-not [string]::IsNullOrWhiteSpace($Identity)) {
        $blocks += @{ type = 'paragraph'; text = $Identity }
    }
    if (-not [string]::IsNullOrWhiteSpace($Clock)) {
        $blocks += @{ type = 'paragraph'; text = (ConvertFrom-TelegramHtmlText $Clock) }
    }
    # What the channel is playing sits with the identity rather than in the
    # detail: it answers "is this the right moment" and it was reaching this
    # screen folded away, which is the same as not reaching it.
    $lead = @(@($Highlights) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($line in $lead) { $blocks += @{ type = 'paragraph'; text = (ConvertFrom-TelegramHtmlText $line) } }
    $blocks += @{ type = 'divider' }
    $blocks += @(Get-OnAirTableBlocks)
    # Nothing is folded any more. The detail used to live under one disclosure
    # triangle, and this screen is read while something is wrong: a screen that
    # must be opened before it can be read gets screenshotted half empty.
    #
    # The lines arrive as they were written for the text screen, tags and all,
    # so the two screens cannot drift apart - the same strings are reshaped.
    # That is also what makes the sections detectable: a line that is nothing
    # but bold text was a section heading, and a rule of box-drawing
    # characters was a separator. Both would otherwise strip down to
    # paragraphs and the screen would lose every edge it had.
    foreach ($raw in @($DetailLines)) {
        $text = [string]$raw
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($lead -contains $text) { continue }
        $isRule = $text -match '^[─-╿\-_=]+$'
        $heading = [regex]::Match($text, '^<b>(?<t>.+)</b>$')
        if ($isRule -or $heading.Success) {
            # Two dividers in a row render as a double rule with nothing
            # between them, which reads as a missing section.
            if (@($blocks)[-1].type -ne 'divider') { $blocks += @{ type = 'divider' } }
            if ($heading.Success) {
                $blocks += @{ type = 'heading'; text = (ConvertFrom-TelegramHtmlText $heading.Groups['t'].Value); size = 4 }
            }
            continue
        }
        $blocks += @{ type = 'paragraph'; text = (ConvertFrom-TelegramHtmlText $text) }
    }
    return $blocks
}

function Invoke-StatusCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (Test-UserDisabled -UserId $UserId) { return $false }
    $store = Get-TemplateStore
    $layerStatuses = @(Get-CinegyLayerDashboard)
    $sync = Update-OnAirStateFromCinegy -Reason 'status' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal

    # Quick overall line so a non-admin glance shows whether anything is off.
    if ($sync.Failed.Count -gt 0) {
        $overall = (T 'adm.someLayersUnchecked')
    }
    elseif ($script:OnAir.Count -gt 0) {
        $overall = (T 'adm.layersOnAir')
    }
    else {
        $overall = (T 'adm.allWell')
    }

    $sep = '━━━━━━━━━━━━━━━━━'
    $now = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()
    # Built as parse_mode=HTML from here down. This fallback is the screen an
    # operator actually reads - sendRichMessage is Bot API 10.1 and most
    # servers refuse it - so it is the design rather than a degraded copy, and
    # it was going out as one flat undifferentiated column of text.
    #
    # <code> on the clock, the address and the counts is not decoration: it
    # renders monospace and left-to-right, which stops digits reordering
    # against the Arabic around them, and Telegram makes each one tap-to-copy
    # for an operator quoting it in a fault report.
    $lines.Add("<b>ℹ️ الحالة</b> — <code>v$($script:BridgeVersion)</code>")
    $clockLine = "🕒 <code>$($now.ToString('yyyy-MM-dd HH:mm:ss'))</code> (محلي)"
    $lines.Add($clockLine)
    $lines.Add("<b>$overall</b>")
    # Format-UserAuditActor, not a bare id: it resolves the alias when there is
    # one and pins the bracketed digits to LTR, so an Arabic name followed by
    # an id does not render as ")8201739556(".
    $identityLine = "👤 معرّفك: $(ConvertTo-TelegramHtmlText (Format-UserAuditActor -UserId $UserId))"
    $lines.Add($identityLine)
    $lines.Add('')
    $lines.Add($sep)
    # Named sections rather than one column: the same grammar the full status
    # uses, so an operator moving between the two screens reads one layout.
    $lines.Add((T 'adm.channelAndMaterial'))
    $lines.Add("🌐 <code>$(ConvertTo-TelegramHtmlText ([string]$config.AirServerAddress))</code> · القناة <code>$($config.AirChannelNumber)</code> · القوالب: <code>$($store.Order.Count)</code>")
    # The programme under the graphics. Placed with the channel line because
    # it answers the same question - what is this channel doing right now -
    # and above the layer detail, because it is the context the layers sit in.
    $material = Get-AirMaterialNowNext
    if ($material) { $lines.Add($material) }
    $sharedLayers = Get-JsonProp $store 'SharedLayers'
    if ($sharedLayers -and $sharedLayers.Count -gt 0) {
        $sharedText = ConvertTo-TelegramHtmlText (@($sharedLayers.Keys | Sort-Object {[int]$_} | ForEach-Object { "طبقة ${_}: $(@($sharedLayers[$_]) -join '، ')" }) -join ' | ')
        # Not 'allowed' - a Cinegy GFX layer holds one scene, so templates
        # sharing a layer can never be on air together. Calling that harmless
        # is how a logo and a ticker end up silently evicting each other.
        $lines.Add("⚠️ قوالب تتشارك الطبقة نفسها ولا يمكن عرضها معًا: $sharedText")
    }
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: <b>$(ConvertTo-TelegramHtmlText ([string]$freshness.Label))</b>")
    if ($lastSuccessfulAt) {
        # "منذ 12 ثانية" answers the question being asked - is this current? -
        # which a bare timestamp leaves the reader to work out against a clock.
        # The clock time stays, in brackets, for anyone comparing with a log.
        $checkedAt = [datetime]$lastSuccessfulAt
        $agoSeconds = [math]::Max(0, [int]($now - $checkedAt).TotalSeconds)
        # "منذ 0 ثانية" is a strange way to say "just now".
        $ago = if ($agoSeconds -lt 5) { (T 'adm.now') } else { "منذ $(Format-DurationSeconds -Seconds $agoSeconds)" }
        $lines.Add("🔄 آخر فحص ناجح: <i>$ago</i> (<code>$($checkedAt.ToString('HH:mm:ss'))</code>)")
    }
    $lines.Add((ConvertTo-TelegramHtmlText (Get-OnAirSummary)))
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add((T 'adm.syncTitle'))
    if ($sync.Failed.Count -gt 0) {
        $lines.Add("⚠️ تعذّر فحص طبقات Cinegy: $($sync.Failed -join '، ') — تم الاحتفاظ بالحالة السابقة.")
    }
    elseif ($sync.Removed.Count -gt 0) {
        $lines.Add("🔄 تم تحديث الحالة وأُزيلت الطبقات المخفية خارجيًا: $($sync.Removed -join '، ')")
    }
    else {
        $lines.Add((T 'adm.syncedWithCinegy'))
    }
    if ($store.Errors.Count -gt 0) { $lines.Add("⚠️ " + (ConvertTo-TelegramHtmlText ($store.Errors -join "`n⚠️ "))) }
    $statusMenu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    # The same lines, reshaped: the verdict as a heading, what is on air
    # as a table, and the machine detail folded under it. The leading
    # lines are skipped because the blocks already carry them.
    # Skip 4: the blocks already carry the title, the clock, the verdict and
    # now the identity line, and repeating them inside the details would print
    # each of those facts twice on one screen.
    # The block renderer lays text out itself and has no tag syntax, so the
    # HTML is stripped back on the way in rather than kept as a second
    # parallel copy that would drift from the one operators actually read.
    $statusBlocks = Get-StatusRichBlocks -Title (T 'adm.status') -Overall $overall `
        -Identity (ConvertFrom-TelegramHtmlText $identityLine) -Clock $clockLine -Highlights @($material) `
        -DetailLines @($lines | Select-Object -Skip 4)
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $statusBlocks -ReplyMarkup $statusMenu) { return }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup $statusMenu
}

function Request-HideAllConfirmation {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    $layers = @(Get-HideAllTargetLayers)
    if ($layers.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'adm.noHideAllLayers') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'hide_all_review'; UserId = $UserId; Layers = $layers
    }
    $labels = @($layers | ForEach-Object { Get-LayerDisplayName -Layer ([int]$_) })
    Send-TelegramMessage -ChatId $ChatId -Text "⚠️ سيتم إخفاء الطبقات المحددة: $($labels -join '، '). هل أنت متأكد؟" -ReplyMarkup (Get-HideAllConfirmKeyboard)
}

function Get-HealthStatusReport {
    $telegramWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $telegramOk = $false
    $telegramError = ''
    try {
        $probe = Invoke-RestMethod -Uri "$apiBase/getMe" -Method Get -TimeoutSec 3
        $telegramOk = [bool](Get-JsonProp $probe 'ok')
        if (-not $telegramOk) { $telegramError = (T 'adm.invalidReply') }
    }
    catch { $telegramError = $_.Exception.Message }
    $telegramWatch.Stop()

    $cinegyWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $telemetry = Get-AirTelemetryStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    $cinegyWatch.Stop()

    $checkedAt = Get-Date
    if ($telegramOk) { $script:HealthHistory.Telegram.LastSuccess = $checkedAt }
    else {
        $script:HealthHistory.Telegram.LastError = Protect-SensitiveText $telegramError
        $script:HealthHistory.Telegram.LastErrorAt = $checkedAt
    }
    if ($telemetry.Success) { $script:HealthHistory.Cinegy.LastSuccess = $checkedAt }
    else {
        $script:HealthHistory.Cinegy.LastError = [string](Get-JsonProp $telemetry 'Error')
        if ([string]::IsNullOrWhiteSpace($script:HealthHistory.Cinegy.LastError)) { $script:HealthHistory.Cinegy.LastError = (T 'adm.unreachable') }
        $script:HealthHistory.Cinegy.LastErrorAt = $checkedAt
    }

    $telegramLine = if ($telegramOk) { "✅ Telegram: $($telegramWatch.ElapsedMilliseconds)ms" }
    else { "❌ Telegram: $($telegramWatch.ElapsedMilliseconds)ms — $(Protect-SensitiveText $telegramError)" }
    $cinegyLine = if ($telemetry.Success) { "✅ Cinegy: $($cinegyWatch.ElapsedMilliseconds)ms" }
    else { "❌ Cinegy: $($cinegyWatch.ElapsedMilliseconds)ms — تعذّر الوصول" }
    $historyLines = foreach ($service in @('Telegram', 'Cinegy')) {
        $history = $script:HealthHistory[$service]
        $lastSuccess = if ($history.LastSuccess) { ([datetime]$history.LastSuccess).ToString('yyyy-MM-dd HH:mm:ss') } else { (T 'adm.none') }
        $lastError = if ($history.LastErrorAt) {
            "$($history.LastError) — $(([datetime]$history.LastErrorAt).ToString('yyyy-MM-dd HH:mm:ss'))"
        }
        else { (T 'adm.none') }
        $failureCount = [int]$history.FailureCount
        $outage = if ($history.OutageStartedAt) { ([datetime]$history.OutageStartedAt).ToString('yyyy-MM-dd HH:mm:ss') } else { (T 'adm.none') }
        "$service — آخر نجاح: $lastSuccess | آخر خطأ: $lastError | فشل متتالٍ: $failureCount | بداية الانقطاع: $outage"
    }
    $historyText = $historyLines -join "`n"
    $text = @(
        (T 'adm.serviceHealth'),
        $telegramLine,
        $cinegyLine,
        "",
        $historyText,
        "",
        (Format-CinegyTelemetryStatus -Telemetry $telemetry)
    ) -join "`n"
    return [pscustomobject]@{ Text = $text; Telemetry = $telemetry }
}

function Show-TemplateAdminDetail {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'adm.templateGone') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $lines = @(
        "📚 تفاصيل القالب: $($template.Key)",
        "المسار: $($template.Path)",
        "الطبقة: $($template.Layer)",
        "الترتيب: $($template.Order)",
        "الوصف: $($template.Description)",
        "الحقول: $(if (@($template.Fields).Count -gt 0) { $template.Fields -join '، ' } else { 'لا توجد' })",
        "النصوص الجاهزة: $(@($template.Presets).Count)"
    )
    $reminderText = if ([bool](Get-JsonProp $template 'LongRunning')) {
        (T 'adm.disabledLongRun')
    }
    elseif ([int](Get-JsonProp $template 'ReminderMinutes') -gt 0) {
        "بعد $([int](Get-JsonProp $template 'ReminderMinutes')) دقيقة للشخص الذي أظهر القالب."
    }
    else { (T 'adm.disabledDot') }
    $lines += "🔔 تنبيه الظهور: $reminderText"
    if ((Test-Admin -ChatId $ChatId -UserId $UserId) -and (Get-Setting 'EnableFullTemplateManagement')) {
        $lines += (T 'adm.fullTemplateControl')
    }
    else {
        $lines += (T 'adm.templateEditAdminOnly')
    }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex -ChatId $ChatId -UserId $UserId)
}

function Start-TemplateReminderMinutesPrompt {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-TemplateReminderManager -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'adm.lostNoticeRight') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { Send-TelegramMessage -ChatId $ChatId -Text (T 'adm.templateGone') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $ChatId -UserId $UserId); return }
    if ([bool](Get-JsonProp $template 'LongRunning')) {
        Send-TelegramMessage -ChatId $ChatId -Text "🔔 '$($template.Key)' قالب Long run يعمل 24/7، لذلك تنبيه الظهور الشخصي معطّل." -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex -ChatId $ChatId -UserId $UserId)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'template_reminder_minutes'; TemplateIndex = $TemplateIndex; TemplateKey = [string]$template.Key; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "🔔 أرسل مدة التنبيه لقالب '$($template.Key)' بالدقائق من 0 إلى 1440.`nأرسل 0 لإيقاف التنبيه." -ReplyMarkup (Get-CancelKeyboard)
}
