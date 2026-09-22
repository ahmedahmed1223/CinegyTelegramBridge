#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-SystemClockStatus {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    $zone = [System.TimeZoneInfo]::Local
    $reasonable = $Now.Year -ge 2024 -and $Now.Year -le 2100 -and -not [string]::IsNullOrWhiteSpace($zone.Id)
    return [pscustomobject]@{
        Success = $reasonable; Now = $Now; TimeZoneId = $zone.Id
        Offset = $Now.Offset; Error = if ($reasonable) { '' } else { 'System clock or timezone is not reasonable.' }
    }
}

function Set-ScheduleMoment {
    <# What happens once a moment is settled, whichever way it was chosen.

       Shared by the typed path and the picker so the two cannot drift: an
       edit flow goes straight to review, a new one goes on to recurrence,
       and both echo the moment back in full before anything is saved. #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][datetimeoffset]$ScheduledAt,
        [Parameter(Mandatory)][string]$TimeZoneId
    )
    $State.ScheduledAt = $ScheduledAt.ToString('o'); $State.TimeZoneId = $TimeZoneId
    if ($State.ContainsKey('MutationAction')) {
        Show-ScheduleReview -ChatId $ChatId -State $State
        return
    }
    $State.Mode = 'schedule_recurrence'; Set-PendingState -ChatId $ChatId -State $State
    Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.timeRead' $($ScheduledAt.ToString('yyyy-MM-dd HH:mm zzz')) $TimeZoneId) -ReplyMarkup (Get-ScheduleRecurrenceKeyboard)
}

function Get-ScheduleCalendarKeyboard {
    <#
        A month of days as buttons.

        Telegram has no date field, so this is the nearest thing: a grid the
        thumb picks from instead of eleven characters typed into a phone in
        the middle of a shift. Days already past are rendered disabled (Bot
        API 10.3) rather than left out, because a month with holes in it
        stops reading as a calendar - the row a date sits on is how the eye
        finds it.

        Month is 'yyyy-MM'. Weekday headers are disabled buttons for the same
        reason: they must occupy a column without being pressable.
    #>
    param([Parameter(Mandatory)][string]$Month, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $first = [datetime]::ParseExact("$Month-01", 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $today = $Now.DateTime.Date
    $rows = @()
    $rows += , @((New-BridgeButton -Text $first.ToString('yyyy / MM') -Disabled))
    $rows += , @((T 'sch.day.sun'), (T 'sch.day.mon'), (T 'sch.day.tue'), (T 'sch.day.wed'), (T 'sch.day.thu'), (T 'sch.day.fri'), (T 'sch.day.sat') | ForEach-Object { New-BridgeButton -Text $_ -Disabled })

    # Sunday-first, matching the weekday header above it.
    $week = @()
    for ($blank = 0; $blank -lt [int]$first.DayOfWeek; $blank++) { $week += , (New-BridgeButton -Text '·' -Disabled) }
    for ($day = 1; $day -le [datetime]::DaysInMonth($first.Year, $first.Month); $day++) {
        $date = $first.AddDays($day - 1)
        $week += , $(if ($date -lt $today) { New-BridgeButton -Text '·' -Disabled }
            else { New-BridgeButton -Text "$day" -CallbackData "schday:$($date.ToString('yyyy-MM-dd'))" })
        if ($week.Count -eq 7) { $rows += , @($week); $week = @() }
    }
    if ($week.Count -gt 0) {
        while ($week.Count -lt 7) { $week += , (New-BridgeButton -Text '·' -Disabled) }
        $rows += , @($week)
    }

    # Back only where there is somewhere to go: the month containing today is
    # the earliest one that can hold a future date.
    $nav = @()
    if ($first -gt $today) { $nav += , (New-BridgeButton -Text (T 'sch.prev') -CallbackData "schcal:$($first.AddMonths(-1).ToString('yyyy-MM'))") }
    $nav += , (New-BridgeButton -Text (T 'sch.next') -CallbackData "schcal:$($first.AddMonths(1).ToString('yyyy-MM'))")
    $rows += , @($nav)
    $rows += , @((New-BridgeButton -Text (T 'sch.cancel') -CallbackData 'cancel'))
    return @{ inline_keyboard = $rows; KeepRows = $true }
}

function Get-ScheduleHourKeyboard {
    <# The chosen day's hours, six to a row. Hours already gone today are
       disabled for the same reason past days are: the grid keeps its shape. #>
    param([Parameter(Mandatory)][string]$Date, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $day = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $isToday = $day -eq $Now.DateTime.Date
    $rows = @(, @((New-BridgeButton -Text (T 'sch.pickHour' $Date) -Disabled)))
    $row = @()
    for ($hour = 0; $hour -lt 24; $hour++) {
        # An hour is still choosable while any of its minutes are ahead.
        $spent = $isToday -and $hour -lt $Now.Hour
        $row += , $(if ($spent) { New-BridgeButton -Text '·' -Disabled }
            else { New-BridgeButton -Text ('{0:00}' -f $hour) -CallbackData "schhour:${Date}:$hour" })
        if ($row.Count -eq 6) { $rows += , @($row); $row = @() }
    }
    $rows += , @((New-BridgeButton -Text (T 'sch.backDate') -CallbackData "schcal:$($day.ToString('yyyy-MM'))"),
        (New-BridgeButton -Text (T 'sch.cancel') -CallbackData 'cancel'))
    return @{ inline_keyboard = $rows; KeepRows = $true }
}

function Get-ScheduleMinuteKeyboard {
    <# Five-minute steps: a playout cue is written to the minute, and sixty
       buttons would be a wall nobody reads. Anything finer is still typed. #>
    param([Parameter(Mandatory)][string]$Date, [Parameter(Mandatory)][int]$Hour, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $day = [datetime]::ParseExact($Date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $rows = @(, @((New-BridgeButton -Text (T 'sch.pickMinute' $Date $('{0:00}' -f $Hour)) -Disabled)))
    $row = @()
    for ($minute = 0; $minute -lt 60; $minute += 5) {
        $moment = $day.AddHours($Hour).AddMinutes($minute)
        $row += , $(if ($moment -le $Now.DateTime) { New-BridgeButton -Text '·' -Disabled }
            else { New-BridgeButton -Text ('{0:00}' -f $minute) -CallbackData "schmin:${Date}:${Hour}:$minute" })
        if ($row.Count -eq 6) { $rows += , @($row); $row = @() }
    }
    $rows += , @((New-BridgeButton -Text (T 'sch.backHour') -CallbackData "schday:$Date"),
        (New-BridgeButton -Text (T 'sch.cancel') -CallbackData 'cancel'))
    return @{ inline_keyboard = $rows; KeepRows = $true }
}

function Get-ScheduleTimePromptKeyboard {
    <# Offered with the typed prompt: the three offsets that cover most cues,
       and the calendar for everything else. Typing still works - the picker
       is another way in, not a replacement. #>
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    return @{ inline_keyboard = @(
            , @((New-BridgeButton -Text (T 'sch.plus15') -CallbackData 'schrel:15'),
                (New-BridgeButton -Text (T 'sch.plus30') -CallbackData 'schrel:30'),
                (New-BridgeButton -Text (T 'sch.plus60') -CallbackData 'schrel:60'))
            , @((New-BridgeButton -Text (T 'sch.calendar') -CallbackData "schcal:$($Now.ToString('yyyy-MM'))"))
            , @((New-BridgeButton -Text (T 'sch.cancel') -CallbackData 'cancel'))
        ) }
}

function Set-BridgeChosenMoment {
    <# The day/hour/minute picker and the "+15" buttons are shared by the
       template scheduling and the bulletin's "start later", because asking
       for a moment twice in two different ways is how two answers to the same
       question drift apart. Only where the answer goes differs. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][datetimeoffset]$ScheduledAt,
        # Demanded here because the template branch demands it: a dispatcher
        # that accepts less than its callee only moves the failure later.
        [Parameter(Mandatory)][string]$TimeZoneId)
    if ([string](Get-JsonProp $State 'Mode') -eq 'mojaz_start_at') {
        Complete-MojazLaterAt -ChatId $ChatId -ScheduledAt $ScheduledAt | Out-Null
        return
    }
    Set-ScheduleMoment -ChatId $ChatId -State $State -ScheduledAt $ScheduledAt -TimeZoneId $TimeZoneId
}

function Test-ScheduleClockParts {
    <# 25:00 and 21:70 parse as digits and then silently become tomorrow or
       the next hour if handed to AddHours/AddMinutes, so they are refused
       before arithmetic rather than accepted as something else. #>
    param([Parameter(Mandatory)][string]$Hour, [Parameter(Mandatory)][string]$Minute)
    return ([int]$Hour -le 23 -and [int]$Minute -le 59)
}

function ConvertTo-BridgeLatinDigits {
    <# Arabic-Indic and Persian digits as ASCII.

       An operator writing Arabic types on an Arabic keyboard, which produces
       ٢١:٤٥, and every date parser in .NET's invariant culture refuses it.
       The schedule screen was therefore unusable without switching keyboard
       layouts to enter the one field that is pure digits. #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $builder = [System.Text.StringBuilder]::new()
    foreach ($char in $Text.ToCharArray()) {
        $code = [int]$char
        if ($code -ge 0x0660 -and $code -le 0x0669) { [void]$builder.Append([char](48 + $code - 0x0660)) }      # ٠-٩
        elseif ($code -ge 0x06F0 -and $code -le 0x06F9) { [void]$builder.Append([char](48 + $code - 0x06F0)) }   # ۰-۹
        else { [void]$builder.Append($char) }
    }
    return $builder.ToString()
}

function Get-ScheduleTimeHint {
    <# Kept in one place because the prompt, the re-prompt after a rejection
       and the help chapter all have to describe the same accepted forms. #>
    return (T 'sch.acceptedForms')
}

function ConvertFrom-OperatorScheduleTime {
    <#
        The moment an operator meant.

        The strict YYYY-MM-DD HH:mm still works and is still what the review
        screen echoes back. What changed is that it is no longer the only
        thing accepted: a bare 21:45 is what somebody standing in a gallery
        actually types, and demanding eleven more characters of it - on a
        phone, in the middle of a shift - bought nothing but typos.

        A bare time rolls to tomorrow once today's has passed, because a
        schedule entry is refused in the past anyway: the operator would
        otherwise be told "must be in the future" for a time they plainly
        meant tonight.
    #>
    param([Parameter(Mandatory)][string]$Text, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $clock = Get-SystemClockStatus -Now $Now
    if (-not $clock.Success) { return $clock }
    $localTime = [datetime]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    # Digits first, then separators: '/' and '.' are what a numeric keypad
    # offers, and rejecting them taught nothing.
    $value = (ConvertTo-BridgeLatinDigits -Text $Text).Trim()
    $value = [regex]::Replace($value, '\s+', ' ')
    $today = $Now.DateTime.Date

    if ($value -match '^(?:\+|بعد\s*)(\d{1,4})$') {
        $localTime = $Now.DateTime.AddMinutes([int]$Matches[1])
        # Seconds would make the review screen echo a time nobody typed.
        $localTime = $localTime.AddSeconds(-$localTime.Second).AddMilliseconds(-$localTime.Millisecond)
    }
    elseif ($value -match '^(اليوم|غدا|غدًا|غداً|بكرة|بكره)\s+(\d{1,2}):(\d{2})$') {
        $day = if ($Matches[1] -eq (T 'sch.today')) { $today } else { $today.AddDays(1) }
        if (-not (Test-ScheduleClockParts -Hour $Matches[2] -Minute $Matches[3])) {
            return [pscustomobject]@{ Success = $false; Error = (T 'sch.outOfRange' $(Get-ScheduleTimeHint)); TimeZoneId = $clock.TimeZoneId }
        }
        $localTime = $day.AddHours([int]$Matches[2]).AddMinutes([int]$Matches[3])
    }
    elseif ($value -match '^(\d{1,2}):(\d{2})$') {
        if (-not (Test-ScheduleClockParts -Hour $Matches[1] -Minute $Matches[2])) {
            return [pscustomobject]@{ Success = $false; Error = (T 'sch.outOfRange' $(Get-ScheduleTimeHint)); TimeZoneId = $clock.TimeZoneId }
        }
        $localTime = $today.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
        if ($localTime -le $Now.DateTime) { $localTime = $localTime.AddDays(1) }
    }
    else {
        $normalized = $value -replace '[./]', '-'
        $formats = @('yyyy-MM-dd HH:mm', 'yyyy-M-d H:mm', 'MM-dd HH:mm', 'M-d H:mm')
        $parsedAny = $false
        foreach ($format in $formats) {
            if ([datetime]::TryParseExact($normalized, $format, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$localTime)) {
                # A day-and-month form has no year, so .NET supplies the
                # current one; that is what was meant unless it is already
                # behind us, in which case it is next year's date.
                if ($format -notlike 'yyyy*' -and $localTime -le $Now.DateTime) { $localTime = $localTime.AddYears(1) }
                $parsedAny = $true
                break
            }
        }
        if (-not $parsedAny) {
            return [pscustomobject]@{ Success = $false; Error = (T 'sch.notUnderstood' $(Get-ScheduleTimeHint)); TimeZoneId = $clock.TimeZoneId }
        }
    }
    $localTime = [datetime]::SpecifyKind($localTime, [System.DateTimeKind]::Unspecified)
    $zone = [System.TimeZoneInfo]::Local
    if ($zone.IsInvalidTime($localTime) -or $zone.IsAmbiguousTime($localTime)) {
        return [pscustomobject]@{ Success = $false; Error = (T 'sch.ambiguousTime'); TimeZoneId = $zone.Id }
    }
    $scheduledAt = [datetimeoffset]::new($localTime, $zone.GetUtcOffset($localTime))
    if ($scheduledAt -le $Now) {
        return [pscustomobject]@{ Success = $false; Error = (T 'sch.mustBeFuture'); TimeZoneId = $zone.Id }
    }
    return [pscustomobject]@{ Success = $true; ScheduledAt = $scheduledAt; TimeZoneId = $zone.Id; Error = '' }
}

function New-ScheduledShowEvent {
    param(
        [Parameter(Mandatory)][string]$TemplateKey,
        [int]$Layer = 0,
        [hashtable]$Values = @{},
        [Parameter(Mandatory)][datetimeoffset]$ScheduledAt,
        [Parameter(Mandatory)][ValidateSet('once', 'daily', 'weekly')][string]$Recurrence,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId,
        [string]$RecurrenceUntil = '',
        [string]$AnchorMaterialId = '',
        [int]$AnchorOffsetSeconds = 0
    )
    if ($AnchorOffsetSeconds -lt 0) { $AnchorOffsetSeconds = 0 }
    return @{
        Id = [guid]::NewGuid().ToString(); TemplateKey = $TemplateKey; Layer = $Layer; Values = $Values
        ScheduledAt = $ScheduledAt.ToString('o'); TimeZoneId = [System.TimeZoneInfo]::Local.Id
        Recurrence = $Recurrence; Status = 'pending'; ChatId = $ChatId; UserId = $UserId
        CreatedAt = [datetimeoffset]::Now.ToString('o'); ExecutionKey = ''
        CompletedExecutionKey = ''; StartedAt = ''; CompletedAt = ''; LastResult = ''
        AttemptCount = 0; NextAttemptAt = ''; RecurrenceUntil = $RecurrenceUntil
        NotificationExecutionKey = ''; LastTemplateCheckAt = ''; LastTemplateCheckStatus = ''
        # T-52: optional anchor to channel material. Empty AnchorMaterialId
        # means wall-clock time; otherwise the effective moment is the
        # material's start plus AnchorOffsetSeconds, re-resolved from the
        # rundown so a shifted programme carries the graphic with it.
        AnchorMaterialId = $AnchorMaterialId; AnchorOffsetSeconds = $AnchorOffsetSeconds
    }
}

function Save-ScheduleEvents {
    try {
        $json = ConvertTo-Json -InputObject @($script:ScheduleEvents.ToArray()) -Depth 8
        if (-not (Write-ValidatedJsonState -Path $script:scheduleFile -Json $json)) { throw 'validated state write failed' }
        return $true
    }
    catch {
        Write-BridgeLog "Could not write schedule.json: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Write-BridgeExecutionRecord {
    <#
        One execution log for everything the bridge fires on a clock.

        Scheduled graphics wrote here from the start; scheduled bulletins and
        the automatic news sheet sync wrote nowhere an operator could read -
        a bulletin's outcome lived on its schedule record and died with it,
        and the sync said its piece to bridge.log alone. Same file, same
        reader, one Kind field, so "what fired, when, and did it work" is one
        screen rather than three half-answers.

        Kind is absent from every record written before this, so the reader
        treats a missing Kind as 'show' rather than discarding history.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('show', 'mojaz', 'news')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('success', 'failed')][string]$Result,
        [string]$EventId = '',
        [string]$ExecutionKey = '',
        [string]$Label = '',
        [int]$Layer = 0,
        [string]$ScheduledAt = '',
        [long]$DurationMs = 0,
        [int]$Attempt = 1,
        [string]$ErrorText = ''
    )
    try {
        $record = [ordered]@{
            Timestamp    = [datetimeoffset]::Now.ToString('o')
            Kind         = $Kind
            EventId      = $EventId
            ExecutionKey = $ExecutionKey
            TemplateKey  = $Label
            Layer        = $Layer
            ScheduledAt  = $ScheduledAt
            Attempt      = $Attempt
            Result       = $Result
            DurationMs   = $DurationMs
            Error        = if ($ErrorText) { Protect-SensitiveText $ErrorText } else { '' }
        }
        Add-Content -LiteralPath $script:scheduleExecutionFile -Value ($record | ConvertTo-Json -Compress -Depth 4) -Encoding utf8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-BridgeLog "Could not append schedule execution log: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Write-ScheduleExecutionEntry {
    <# The scheduled-graphic caller, unchanged for its callers: it still takes
       the schedule entry it already has and writes Kind 'show'. #>
    param(
        [Parameter(Mandatory)][hashtable]$ScheduleEntry,
        [Parameter(Mandatory)][ValidateSet('success', 'failed')][string]$Result,
        [Parameter(Mandatory)][long]$DurationMs,
        [int]$Attempt = 1,
        [string]$ErrorText = ''
    )
    return (Write-BridgeExecutionRecord -Kind 'show' -Result $Result `
            -EventId ([string]$ScheduleEntry.Id) -ExecutionKey ([string]$ScheduleEntry.ExecutionKey) `
            -Label ([string]$ScheduleEntry.TemplateKey) -Layer ([int](Get-JsonProp $ScheduleEntry 'Layer')) `
            -ScheduledAt ([string]$ScheduleEntry.ScheduledAt) -DurationMs $DurationMs `
            -Attempt $Attempt -ErrorText $ErrorText)
}

function Get-ScheduleExecutionHistory {
    <#
        The execution log as records, newest first.

        Write-ScheduleExecutionEntry has been appending every fired occurrence
        since the feature shipped - the time, the template, the layer, the
        moment it was DUE against the moment it ran, the attempt number, the
        result, the duration, and the redacted reason on failure. Nothing ever
        read it back: the only consumer in the tree was a file-size row on the
        diagnostics screen, so "why did that scheduled graphic not appear?"
        was answerable only by opening a .jsonl by hand.

        Tail-read like the audit trail, because this file grows for the life of
        the station and a screen must not parse a year to show ten rows.
    #>
    param([ValidateRange(1, 500)][int]$TailLines = 120)
    $records = @()
    if ([string]::IsNullOrWhiteSpace($script:scheduleExecutionFile)) { return $records }
    if (-not (Test-Path -LiteralPath $script:scheduleExecutionFile)) { return $records }
    try {
        foreach ($line in @(Get-Content -LiteralPath $script:scheduleExecutionFile -Tail $TailLines -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            # One torn line is one row lost, never the whole screen.
            try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if (-not $record) { continue }
            # Records written before the log covered bulletins and the sheet
            # sync carry no Kind at all - they are all scheduled graphics.
            $kind = [string](Get-JsonProp $record 'Kind')
            if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'show' }
            $records += [pscustomobject]@{
                Timestamp   = [string](Get-JsonProp $record 'Timestamp')
                Kind        = $kind
                TemplateKey = [string](Get-JsonProp $record 'TemplateKey')
                Layer       = [int](Get-JsonProp $record 'Layer')
                ScheduledAt = [string](Get-JsonProp $record 'ScheduledAt')
                Attempt     = [int](Get-JsonProp $record 'Attempt')
                Result      = [string](Get-JsonProp $record 'Result')
                DurationMs  = [long](Get-JsonProp $record 'DurationMs')
                Error       = [string](Get-JsonProp $record 'Error')
            }
        }
    }
    catch { Write-BridgeLog "Could not read schedule-execution.jsonl: $($_.Exception.Message)" 'WARN' }
    [array]::Reverse($records)
    return @($records)
}

function Get-ScheduleExecutionRows {
    <# Shared by the rich screen and its text fallback, so the two cannot
       disagree about what ran. #>
    param([ValidateRange(1, 500)][int]$TailLines = 120, [ValidateSet('', 'show', 'mojaz', 'news')][string]$Kind = '')
    $rows = @()
    foreach ($record in @(Get-ScheduleExecutionHistory -TailLines $TailLines)) {
        if ($Kind -and [string]$record.Kind -ne $Kind) { continue }
        $mark = if ([string]$record.Result -eq 'success') { '✅' } else { '❌' }
        $ranAt = [datetimeoffset]::MinValue
        $when = if ([datetimeoffset]::TryParse([string]$record.Timestamp, [ref]$ranAt)) {
            $ranAt.ToLocalTime().ToString('MM-dd HH:mm')
        }
        else { '—' }
        $delay = Get-ScheduleExecutionDelaySeconds -Record $record
        $lateness = if ($null -eq $delay) { '—' }
        elseif ($delay -le 2) { (T 'sch.onTime') }
        else { (T 'sch.late' $(Format-DurationSeconds -Seconds $delay)) }
        $attempt = if ([int]$record.Attempt -gt 1) { (T 'sch.attempt' $($record.Attempt)) } else { '' }
        # The kind glyph and the result glyph are different jobs: a column of
        # ✅ says nothing about which line is a bulletin and which a strap.
        $kindGlyph = switch ([string]$record.Kind) { 'mojaz' { '📑' } 'news' { '📰' } default { '▶️' } }
        $rows += [pscustomobject]@{
            Mark      = $mark
            KindGlyph = $kindGlyph
            Kind      = [string]$record.Kind
            When      = $when
            Template  = [string]$record.TemplateKey
            Layer     = [int]$record.Layer
            Lateness  = "$lateness$attempt"
            Error     = [string]$record.Error
        }
    }
    return @($rows)
}

function Get-ScheduleExecutionHeading {
    param([string]$Kind = '')
    switch ($Kind) {
        'mojaz' { return (T 'sch.mojazExecLog') }
        'news' { return (T 'sch.newsExecLog') }
        default { return (T 'sch.execLog') }
    }
}

function Get-ScheduleExecutionBlocks {
    param([ValidateRange(1, 500)][int]$TailLines = 120, [ValidateSet('', 'show', 'mojaz', 'news')][string]$Kind = '')
    $rows = @(Get-ScheduleExecutionRows -TailLines $TailLines -Kind $Kind)
    $blocks = @(@{ type = 'heading'; text = (Get-ScheduleExecutionHeading -Kind $Kind); size = 3 })
    if ($rows.Count -eq 0) {
        return $blocks + @(@{ type = 'paragraph'; text = (T 'sch.nothingRunYet') })
    }
    $failed = @($rows | Where-Object { $_.Mark -eq '❌' }).Count
    $verdict = if ($failed -eq 0) { (T 'sch.allPassed' $(Get-ArabicCountNoun -Count $rows.Count -One 'تنفيذ' -Two 'تنفيذان' -Few 'تنفيذات' -Many 'تنفيذًا' -EnglishOne 'execution' -EnglishMany 'executions')) }
    else { (T 'sch.someFailed' $(Get-ArabicCountNoun -Count $rows.Count -One 'تنفيذ' -Two 'تنفيذان' -Few 'تنفيذات' -Many 'تنفيذًا' -EnglishOne 'execution' -EnglishMany 'executions') $failed) }
    $blocks += @{ type = 'paragraph'; text = $verdict }

    $trimmed = Select-RichTableRows -Items $rows
    $cells = @(, @(
            @{ text = (T 'sch.col.time'); is_header = $true }
            @{ text = (T 'sch.col.template'); is_header = $true }
            @{ text = (T 'sch.col.result'); is_header = $true }
            @{ text = (T 'sch.col.delay'); is_header = $true }
        ))
    foreach ($row in @($trimmed.Rows)) {
        $what = if ([string]$row.Kind -eq 'show') { (T 'sch.nameLayer' $([string]$row.Template) $($row.Layer)) }
        else { [string]$row.Template }
        $cells += , @(
            @{ text = [string]$row.When }
            @{ text = "$([string]$row.KindGlyph) $what" }
            @{ text = [string]$row.Mark }
            @{ text = [string]$row.Lateness }
        )
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown @($trimmed.Rows).Count
    if ($note) { $blocks += @{ type = 'paragraph'; text = $note } }

    # The reason belongs under the table, not squeezed into a column: it is the
    # one thing the operator opened this screen to read.
    foreach ($row in @($rows | Where-Object { $_.Mark -eq '❌' -and $_.Error } | Select-Object -First 3)) {
        $blocks += @{ type = 'paragraph'; text = "❌ $($row.Template): $($row.Error)" }
    }
    return $blocks
}

function Get-ScheduleExecutionText {
    <# The plain fallback for an API that will not take the rich blocks. #>
    param([ValidateRange(1, 500)][int]$TailLines = 120, [ValidateSet('', 'show', 'mojaz', 'news')][string]$Kind = '')
    $rows = @(Get-ScheduleExecutionRows -TailLines $TailLines -Kind $Kind)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$(Get-ScheduleExecutionHeading -Kind $Kind)</b>")
    if ($rows.Count -eq 0) {
        $lines.Add((T 'sch.nothingRunYetHtml'))
        return ($lines -join "`n")
    }
    $trimmed = Select-RichTableRows -Items $rows
    foreach ($row in @($trimmed.Rows)) {
        $what = if ([string]$row.Kind -eq 'show') { (T 'sch.nameLayer' $(ConvertTo-TelegramHtmlText ([string]$row.Template)) $($row.Layer)) }
        else { ConvertTo-TelegramHtmlText ([string]$row.Template) }
        $line = "$($row.Mark) <code>$($row.When)</code> · $($row.KindGlyph) $what · $(ConvertTo-TelegramHtmlText ([string]$row.Lateness))"
        $lines.Add($line)
        if ($row.Mark -eq '❌' -and $row.Error) { $lines.Add("   ↳ $(ConvertTo-TelegramHtmlText ([string]$row.Error))") }
    }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown @($trimmed.Rows).Count
    if ($note) { $lines.Add($note) }
    return ($lines -join "`n")
}

function Show-ScheduleExecutionScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [ValidateSet('', 'show', 'mojaz', 'news')][string]$Kind = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    $refresh = if ($Kind) { "schedule:execlog:$Kind" } else { 'schedule:execlog' }
    # Back to where the operator came from, not always to the schedule menu.
    #
    # Assigned inside the branches rather than returned out of the switch. A
    # switch used as an expression writes its result to the output stream,
    # which unrolls one level - so the leading comma that makes this a ROW was
    # stripped, and $rows += $back appended a bare button where a row belongs.
    # Telegram refuses the whole message for that, and the mojaz and news
    # screens were doing it on every open.
    $back = @()
    switch ($Kind) {
        'mojaz' { $back = @( (New-Button (T 'sch.backToTimes') 'mojaz:times') ) }
        'news' { $back = @( (New-Button (T 'sch.backToNews') 'menu:news') ) }
        default { $back = @( (New-Button (T 'sch.upcoming') 'schedule:list'), (New-Button (T 'sch.backToScheduling') 'menu:schedule') ) }
    }
    $rows = @(, @( (New-Button (T 'sch.refresh') $refresh) ))
    # Only from the all-kinds screen: a filtered one already answers its own
    # question, and three more buttons under it would just be noise.
    if (-not $Kind) { $rows += , @( (New-Button (T 'sch.bulletin') 'schedule:execlog:mojaz'), (New-Button (T 'sch.news') 'schedule:execlog:news') ) }
    $rows += , $back
    $keyboard = @{ inline_keyboard = $rows }
    if (-not (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-ScheduleExecutionBlocks -Kind $Kind) -ReplyMarkup $keyboard)) {
        Send-TelegramPagedText -ChatId $ChatId -Text (Get-ScheduleExecutionText -Kind $Kind) -ParseMode HTML -ReplyMarkup $keyboard
    }
}

function Get-ScheduleExecutionDelaySeconds {
    <# How late the occurrence actually ran. The number the screen exists for:
       a graphic that fired four minutes after its slot did appear, and saying
       only "success" hides that. Empty when either stamp is unreadable. #>
    param([Parameter(Mandatory)][object]$Record)
    $ranAt = [datetimeoffset]::MinValue
    $dueAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Record.Timestamp, [ref]$ranAt)) { return $null }
    if (-not [datetimeoffset]::TryParse([string]$Record.ScheduledAt, [ref]$dueAt)) { return $null }
    return [int][math]::Round(($ranAt - $dueAt).TotalSeconds)
}

function Update-ScheduleExecutionLogTrim {
    <# The file had no bound at all: appended on every occurrence, rotated by
       nothing, read by nothing. Kept to the newest ExecutionLogKeepRecords so
       a station running for years does not carry its whole scheduling history
       on every disk check. Zero keeps everything - "never trim" is a real
       answer for a record somebody may want to audit. Runs from the tick,
       throttled like its neighbours. #>
    if (((Get-Date) - $script:LastScheduleExecutionTrim).TotalHours -lt 12) { return }
    $script:LastScheduleExecutionTrim = Get-Date
    if ([string]::IsNullOrWhiteSpace($script:scheduleExecutionFile)) { return }
    if (-not (Test-Path -LiteralPath $script:scheduleExecutionFile)) { return }
    $keep = Get-SettingInt 'ExecutionLogKeepRecords' 0
    if ($keep -le 0) { return }
    try {
        $all = @(Get-Content -LiteralPath $script:scheduleExecutionFile -ErrorAction Stop)
        if ($all.Count -le $keep) { return }
        $kept = @($all | Select-Object -Last $keep)
        $temporary = "$($script:scheduleExecutionFile).$([guid]::NewGuid().ToString('N')).tmp"
        Set-Content -LiteralPath $temporary -Value $kept -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:scheduleExecutionFile -Force -ErrorAction Stop
        Write-BridgeLog "Trimmed schedule-execution.jsonl from $($all.Count) to $($kept.Count) line(s)."
    }
    catch { Write-BridgeLog "Could not trim schedule-execution.jsonl: $($_.Exception.Message)" 'WARN' }
}

function Update-ScheduleHistoryTrim {
    <#
        Drops finished occurrences from schedule.json.

        Events become 'completed'/'failed' and were never removed - the only
        Remove in the file is the failed-add rollback. The whole list is
        re-serialised on every tick that changes anything, so the station's
        entire scheduling history was being rewritten to disk for the life of
        the installation. Pending and interrupted events are never touched:
        those are still owed to somebody.
    #>
    if (((Get-Date) - $script:LastScheduleHistoryTrim).TotalHours -lt 12) { return }
    $script:LastScheduleHistoryTrim = Get-Date
    $days = Get-SettingInt 'ScheduleHistoryKeepDays' 0
    if ($days -le 0) { return }
    $cutoff = [datetimeoffset]::Now.AddDays(-$days)
    $doomed = @()
    foreach ($entry in @($script:ScheduleEvents)) {
        if ([string](Get-JsonProp $entry 'Status') -notin @('completed', 'failed')) { continue }
        $stamp = [datetimeoffset]::MinValue
        # No readable moment means no evidence it is old - keep it.
        if (-not [datetimeoffset]::TryParse([string](Get-JsonProp $entry 'ScheduledAt'), [ref]$stamp)) { continue }
        if ($stamp -lt $cutoff) { $doomed += $entry }
    }
    if ($doomed.Count -eq 0) { return }
    foreach ($entry in $doomed) { $script:ScheduleEvents.Remove($entry) | Out-Null }
    if (Save-ScheduleEvents) {
        Write-BridgeLog "Trimmed $($doomed.Count) finished schedule occurrence(s) older than $days day(s)."
    }
}

function Import-ScheduleEvents {
    try {
        $read = Read-ValidatedJsonState -Path $script:scheduleFile -AsHashtable
        if (-not $read) { return }
        $raw = $read.Data
        # Built aside and assigned at the end: the live list used to be emptied
        # here, before the loop, so an entry that threw below left it empty and
        # the next Add-ScheduledShowEvent rewrote schedule.json from nothing.
        $restored = [System.Collections.Generic.List[hashtable]]::new()
        $recovered = $false
        $skipped = 0
        foreach ($scheduleEntry in @($raw)) {
            if (-not $scheduleEntry -or -not $scheduleEntry.ContainsKey('Id')) { continue }
            # Status and ScheduledAt are read straight off the entry here and in
            # every screen downstream, and a missing hashtable key THROWS under
            # Set-StrictMode -Version Latest. The catch is outside this loop, so
            # one entry from an older build used to take every future scheduled
            # graphic with it - permanently. Skip that one entry instead.
            if (-not $scheduleEntry.ContainsKey('Status') -or -not $scheduleEntry.ContainsKey('ScheduledAt')) {
                $skipped++
                continue
            }
            if ([string]$scheduleEntry.Status -eq 'running') {
                # The command may already have reached Cinegy before the crash.
                # Never replay that occurrence automatically.
                $scheduleEntry.Status = 'interrupted'
                $scheduleEntry.LastResult = 'Bridge restarted while occurrence was running; not replayed.'
                $recovered = $true
            }
            $restored.Add($scheduleEntry)
        }
        $script:ScheduleEvents = $restored
        if ($skipped -gt 0) {
            Write-BridgeLog "Skipped $skipped unreadable schedule entry(ies); $($restored.Count) restored." 'WARN'
        }
        if ($recovered) { Save-ScheduleEvents | Out-Null }
    }
    catch { Write-BridgeLog "Could not read schedule.json: $($_.Exception.Message)" "ERROR" }
}

function Add-ScheduledShowEvent {
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)
    $script:ScheduleEvents.Add($ScheduleEntry)
    if (Save-ScheduleEvents) { return $true }
    $script:ScheduleEvents.Remove($ScheduleEntry) | Out-Null
    return $false
}

function Get-CachedMaterialSchedule {
    <#
        The rundown for anchor resolution, fetched at most once per five
        minutes. Update-ScheduleQueue runs every tick; a GET per tick would
        turn a quiet loop into a chatty one. Callers get the last good list
        when the channel is unreachable, and an empty list when nothing was
        ever fetched - resolution then falls back to the stored wall-clock
        moment rather than breaking the event.
    #>
    $now = [datetimeoffset]::Now
    if ($script:MaterialScheduleCache -and (($now - $script:MaterialScheduleCacheAt).TotalMinutes -lt 5)) {
        return @($script:MaterialScheduleCache)
    }
    $timeout = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1
    $schedule = Get-AirMaterialSchedule -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
    if ($schedule -and $schedule.Success) {
        $script:MaterialScheduleCache = @($schedule.Items)
        $script:MaterialScheduleCacheAt = $now
        return @($schedule.Items)
    }
    return @($script:MaterialScheduleCache)
}

function Resolve-ScheduleAnchorTime {
    <#
        The effective moment of an event: wall-clock by default, or the
        anchored material's start plus offset. Pure over the given items, so
        the queue behaviour is testable without touching the network.
    #>
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry, [array]$Items = @())
    $stored = [datetimeoffset](Get-JsonProp $ScheduleEntry 'ScheduledAt')
    $anchorId = [string](Get-JsonProp $ScheduleEntry 'AnchorMaterialId')
    if ([string]::IsNullOrWhiteSpace($anchorId)) { return $stored }
    $offset = 0
    [int]::TryParse([string](Get-JsonProp $ScheduleEntry 'AnchorOffsetSeconds'), [ref]$offset) | Out-Null
    if ($offset -lt 0) { $offset = 0 }
    $bare = $anchorId.Trim('{', '}')
    $match = @($Items | Where-Object { ([string](Get-JsonProp $_ 'Id')).Trim('{', '}') -eq $bare }) | Select-Object -First 1
    if (-not $match) { return $stored }
    return ([datetimeoffset](Get-JsonProp $match 'ScheduledAt')).AddSeconds($offset)
}

function Get-ScheduleAnchorLabel {
    <#
        One line for review and list screens, or '' when unanchored. Shows the
        material name when the rundown has it, so the operator sees what the
        graphic is tied to rather than a guid.
    #>
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry, [array]$Items = @())
    $anchorId = [string](Get-JsonProp $ScheduleEntry 'AnchorMaterialId')
    if ([string]::IsNullOrWhiteSpace($anchorId)) { return '' }
    $offset = 0
    [int]::TryParse([string](Get-JsonProp $ScheduleEntry 'AnchorOffsetSeconds'), [ref]$offset) | Out-Null
    if ($offset -lt 0) { $offset = 0 }
    $bare = $anchorId.Trim('{', '}')
    $match = @($Items | Where-Object { ([string](Get-JsonProp $_ 'Id')).Trim('{', '}') -eq $bare }) | Select-Object -First 1
    $name = if ($match) { [string](Get-JsonProp $match 'Name') } else { '' }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = (T 'sch.materialGone') }
    $after = if ($offset -eq 0) { (T 'sch.withStart') } elseif ($offset -lt 60) { (T 'sch.secondsAfterStart' $offset) } else { (T 'sch.minutesAfterStart' $([int]($offset / 60))) }
    return (T 'sch.linkedTo' $after $name)
}

function Get-ScheduledTemplateStatus {
    <# Resolve the template again when the timer fires. A schedule stores the
       stable key and captured values, not a stale copy of the template
       definition; an operator may have edited or disabled it since creation. #>
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)
    $key = [string](Get-JsonProp $ScheduleEntry 'TemplateKey')
    if ([string]::IsNullOrWhiteSpace($key)) {
        return [pscustomobject]@{ Success = $false; State = 'invalid'; Key = ''; Layer = 0; Path = ''; Error = (T 'sch.noTemplateKey') }
    }
    try {
        $store = Get-TemplateStore
        $map = Get-JsonProp $store 'Map'
        if (-not $map -or -not $map.ContainsKey($key)) {
            $invalidKeys = @(Get-JsonProp $store 'InvalidKeys' | Where-Object { $null -ne $_ })
            if (@($invalidKeys | Where-Object { [string]$_ -eq $key }).Count -gt 0) {
                return [pscustomobject]@{
                    Success = $false; State = 'invalid'; Key = $key; Layer = 0; Path = ''
                    Error = (T 'sch.templateInvalidAtRun' $key)
                }
            }
            return [pscustomobject]@{
                Success = $false; State = 'missing'; Key = $key; Layer = 0; Path = ''
                Error = (T 'sch.templateMissingAtRun' $key)
            }
        }
        $template = $map[$key]
        $layer = 0
        [int]::TryParse([string](Get-JsonProp $template 'Layer'), [ref]$layer) | Out-Null
        $path = [string](Get-JsonProp $template 'Path')
        if ($layer -le 0 -or [string]::IsNullOrWhiteSpace($path)) {
            return [pscustomobject]@{
                Success = $false; State = 'invalid'; Key = $key; Layer = $layer; Path = $path
                Error = (T 'sch.templateIncompleteAtRun' $key)
            }
        }
        return [pscustomobject]@{ Success = $true; State = 'ready'; Key = $key; Layer = $layer; Path = $path; Error = '' }
    }
    catch {
        return [pscustomobject]@{
            Success = $false; State = 'error'; Key = $key; Layer = 0; Path = ''
            Error = (T 'sch.templateCheckFailed' $key $($_.Exception.Message))
        }
    }
}

function Update-ScheduleQueue {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    if (Get-Setting 'MaintenanceMode') { return }
    if (Get-Setting 'SchedulePaused') { return }
    foreach ($scheduleEntry in @($script:ScheduleEvents)) {
        if ([string]$scheduleEntry.Status -ne 'pending') { continue }
        # T-52: an anchored event fires off the material's current start,
        # not the wall-clock snapshot taken at creation. The due check runs
        # against a copy carrying the resolved moment, so the stored event
        # keeps its anchor metadata for the next tick.
        $effectiveAt = Resolve-ScheduleAnchorTime -ScheduleEntry $scheduleEntry -Items (Get-CachedMaterialSchedule)
        $scheduledAt = $effectiveAt
        $occurrenceKey = "$($scheduleEntry.Id)|$($effectiveAt.ToString('o'))"
        $notifyMinutes = Get-SettingInt 'SchedulePreNotifyMinutes' 0
        $minutesUntil = ($scheduledAt - $Now).TotalMinutes
        if ($notifyMinutes -gt 0 -and $minutesUntil -gt 0 -and $minutesUntil -le $notifyMinutes -and
            [string](Get-JsonProp $scheduleEntry 'NotificationExecutionKey') -ne $occurrenceKey) {
            $roundedMinutes = [math]::Max(1, [math]::Ceiling($minutesUntil))
            Send-TelegramMessage -ChatId ([long]$scheduleEntry.ChatId) -Text (T 'sch.eventSoon' $($scheduleEntry.TemplateKey) $(Get-ArabicCountNoun -Count $roundedMinutes -One 'دقيقة' -Two 'دقيقتان' -Few 'دقائق' -Many 'دقيقة' -EnglishOne 'minute' -EnglishMany 'minutes') $(Format-ScheduleEvent -ScheduleEntry $scheduleEntry))
            $scheduleEntry.NotificationExecutionKey = $occurrenceKey
            Save-ScheduleEvents | Out-Null
        }
        $dueState = Get-BridgeScheduleDueState -ScheduleEntry (@{ Id = $scheduleEntry.Id; ScheduledAt = $effectiveAt.ToString('o'); NextAttemptAt = [string](Get-JsonProp $scheduleEntry 'NextAttemptAt'); CompletedExecutionKey = [string](Get-JsonProp $scheduleEntry 'CompletedExecutionKey') }) -Now $Now
        if (-not $dueState.IsDue) { continue }
        $executionKey=$dueState.ExecutionKey

        $scheduleEntry.Status = 'running'; $scheduleEntry.ExecutionKey = $executionKey
        $scheduleEntry.StartedAt = $Now.ToString('o')
        if (-not (Save-ScheduleEvents)) { $scheduleEntry.Status = 'pending'; continue }

        $priorAttempts = 0
        [int]::TryParse([string](Get-JsonProp $scheduleEntry 'AttemptCount'), [ref]$priorAttempts) | Out-Null
        $templateStatus = Get-ScheduledTemplateStatus -ScheduleEntry $scheduleEntry
        $scheduleEntry.LastTemplateCheckAt = $Now.ToString('o')
        $scheduleEntry.LastTemplateCheckStatus = [string]$templateStatus.State
        # Warn before a scheduled event overwrites a graphic that is live now.
        # The conflict check at creation time only compares scheduled events
        # against each other; it cannot know what an operator put up by hand
        # in the meantime, which is the case that actually loses a graphic.
        $targetLayer = [int]$templateStatus.Layer
        if ($targetLayer -gt 0 -and $script:OnAir.ContainsKey($targetLayer) -and (Get-Setting 'NotifyOnScheduleOverwrite')) {
            $displaced = $script:OnAir[$targetLayer]
            Send-AdminBroadcast -Text ((T 'sch.replacesOnAir') +
                (T 'sch.layerSwap' ${targetLayer} $($displaced.Key) $($scheduleEntry.TemplateKey)))
            Write-BridgeLog "Scheduled '$($scheduleEntry.TemplateKey)' is overwriting live '$($displaced.Key)' on layer $targetLayer" 'WARN'
        }

        $executionTimer = [System.Diagnostics.Stopwatch]::StartNew()
        if ($templateStatus.Success) {
            # Invoke-ShowTemplateResult performs the second, live Cinegy layer
            # verification immediately before SHOW. This first check guards
            # against a template registry that changed since scheduling.
            $result = Invoke-ShowTemplateResult -Key ([string]$scheduleEntry.TemplateKey) -Variables $scheduleEntry.Values -ChatId ([long]$scheduleEntry.ChatId) -UserId ([long]$scheduleEntry.UserId)
        }
        else {
            Write-BridgeLog "Scheduled template check failed for '$($scheduleEntry.TemplateKey)': $($templateStatus.Error)" 'WARN'
            Send-TelegramMessage -ChatId ([long]$scheduleEntry.ChatId) -Text (T 'sch.didNotRun' $($templateStatus.Error))
            $result = [pscustomobject]@{ Success = $false; Error = $templateStatus.Error }
        }
        $executionTimer.Stop()
        $executionResult = if ($result -and $result.Success) { 'success' } else { 'failed' }
        $executionError = if ($executionResult -eq 'failed') { if ($result) { [string]$result.Error } else { 'SHOW returned no result.' } } else { '' }
        Write-ScheduleExecutionEntry -ScheduleEntry $scheduleEntry -Result $executionResult -DurationMs $executionTimer.ElapsedMilliseconds -Attempt ($priorAttempts + 1) -ErrorText $executionError | Out-Null
        if ($result -and $result.Success) {
            $scheduleEntry.CompletedExecutionKey = $executionKey
            $scheduleEntry.CompletedAt = [datetimeoffset]::Now.ToString('o')
            $scheduleEntry.LastResult = 'success'
            $scheduleEntry.NextAttemptAt = ''
            if ([string]$scheduleEntry.Recurrence -eq 'once') {
                $scheduleEntry.Status = 'completed'
            }
            else {
                $days = if ([string]$scheduleEntry.Recurrence -eq 'daily') { 1 } else { 7 }
                do { $scheduledAt = Get-NextLocalOccurrence -Occurrence $scheduledAt -Days $days -TimeZoneId ([string]$scheduleEntry.TimeZoneId) } while ($scheduledAt -le $Now)
                $scheduleEntry.ScheduledAt = $scheduledAt.ToString('o')
                $untilText = [string](Get-JsonProp $scheduleEntry 'RecurrenceUntil')
                $pastEnd = $false
                if (-not [string]::IsNullOrWhiteSpace($untilText)) {
                    $untilDate = [datetime]::MinValue
                    if ([datetime]::TryParse($untilText, [ref]$untilDate)) { $pastEnd = $scheduledAt.Date -gt $untilDate.Date }
                }
                $scheduleEntry.Status = if ($pastEnd) { 'completed' } else { 'pending' }
                $scheduleEntry.ExecutionKey = ''; $scheduleEntry.AttemptCount = 0; $scheduleEntry.NotificationExecutionKey = ''
            }
        }
        else {
            $scheduleEntry.LastResult = if ($result) { [string]$result.Error } else { 'SHOW returned no result.' }
            $maxRetries = Get-SettingInt 'ScheduleMaxRetries' 0
            $priorAttemptCount=0
            [int]::TryParse([string](Get-JsonProp $scheduleEntry 'AttemptCount'),[ref]$priorAttemptCount)|Out-Null
            $retry=Get-BridgeScheduleRetryDecision -PriorAttemptCount $priorAttemptCount -MaxRetries $maxRetries `
                -BaseSeconds (Get-SettingInt 'ScheduleRetryDelaySeconds' 30) -Factor (Get-SettingInt 'ScheduleRetryBackoffFactor' 2) `
                -MaxDelaySeconds (Get-SettingInt 'ScheduleRetryMaxDelaySeconds' 300) -Now $Now
            $scheduleEntry.AttemptCount=$retry.AttemptCount
            if ($retry.ShouldRetry) {
                $scheduleEntry.Status = 'pending'; $scheduleEntry.ExecutionKey = ''
                $scheduleEntry.NextAttemptAt = $retry.NextAttemptAt.ToString('o')
                Write-BridgeLog "Scheduled event $($scheduleEntry.Id) SHOW failed; retry $($retry.AttemptCount)/$maxRetries at $($scheduleEntry.NextAttemptAt): $($scheduleEntry.LastResult)" 'WARN'
            }
            else {
                $scheduleEntry.Status = 'failed'; $scheduleEntry.NextAttemptAt = ''
            }
        }
        Save-ScheduleEvents | Out-Null
    }
}

function Get-NextLocalOccurrence {
    param([Parameter(Mandatory)][datetimeoffset]$Occurrence, [Parameter(Mandatory)][int]$Days, [Parameter(Mandatory)][string]$TimeZoneId)
    try { $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId) }
    catch { $zone = [System.TimeZoneInfo]::Local }
    $local = [System.TimeZoneInfo]::ConvertTime($Occurrence, $zone).DateTime.AddDays($Days)
    $local = [datetime]::SpecifyKind($local, [System.DateTimeKind]::Unspecified)
    # A recurring wall-clock time inside a spring-forward gap is moved to the
    # first valid minute. For a repeated autumn hour choose the standard-time
    # offset so the occurrence is deterministic and never fires twice.
    while ($zone.IsInvalidTime($local)) { $local = $local.AddMinutes(1) }
    $offset = if ($zone.IsAmbiguousTime($local)) {
        @($zone.GetAmbiguousTimeOffsets($local) | Sort-Object TotalMinutes | Select-Object -First 1)[0]
    }
    else { $zone.GetUtcOffset($local) }
    return [datetimeoffset]::new($local, $offset)
}

function Get-UpcomingScheduleEvents {
    return @($script:ScheduleEvents | Where-Object { [string]$_.Status -eq 'pending' } | Sort-Object { [datetimeoffset]$_.ScheduledAt })
}

function Stop-ScheduledShowEvent {
    param([Parameter(Mandatory)][string]$Id)
    $scheduleEntry = @($script:ScheduleEvents | Where-Object { [string]$_.Id -eq $Id }) | Select-Object -First 1
    if (-not $scheduleEntry -or [string]$scheduleEntry.Status -ne 'pending') { return $false }
    $scheduleEntry.Status = 'cancelled'; $scheduleEntry.LastResult = 'cancelled by operator'
    return (Save-ScheduleEvents)
}

function Format-ScheduleEventHtml {
    <#
        One upcoming event, for a message sent with parse_mode=HTML.

        A tg-time entity (Bot API 9.5) carries the instant rather than a
        rendering of it, so every reader sees the weekday, date and time in
        their own timezone and language. The station's zone stays alongside
        it because a playout schedule is written in station time and an
        operator reading from elsewhere needs both, not a silent conversion.

        Separate from Format-ScheduleEvent rather than replacing it: that one
        has four other callers that send plain text, and turning them all
        into HTML at once is how a template key with a '<' in it takes down a
        screen.

        'wdt' is weekday + short date + short time, from the documented
        format grammar r|w?[dD]?[tT]?. TemplateKey is typed by an
        administrator, so it is escaped like any other human text.
    #>
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)
    $recurrence = switch ([string]$ScheduleEntry.Recurrence) { 'daily' { (T 'sch.daily') }; 'weekly' { (T 'sch.weekly') }; default { (T 'sch.once') } }
    $at = [datetimeoffset]$ScheduleEntry.ScheduledAt
    $zone = [string](Get-JsonProp $ScheduleEntry 'TimeZoneId')
    if ([string]::IsNullOrWhiteSpace($zone)) { $zone = [System.TimeZoneInfo]::Local.Id }
    $key = ConvertTo-TelegramHtmlText -Text ([string]$ScheduleEntry.TemplateKey)
    # The element's own text is what a client too old for tg-time shows, so it
    # has to read correctly on its own.
    $fallback = ConvertTo-TelegramHtmlText -Text ($at.ToString('yyyy-MM-dd HH:mm'))
    $stamp = "<tg-time unix=`"$($at.ToUnixTimeSeconds())`" format=`"wdt`">$fallback</tg-time>"
    $text = "<b>$key</b> — $stamp — $(ConvertTo-TelegramHtmlText -Text $zone) — $recurrence"
    $anchor = Get-ScheduleAnchorLabel -ScheduleEntry $ScheduleEntry -Items (Get-CachedMaterialSchedule)
    if ($anchor) { $text += "`n$(ConvertTo-TelegramHtmlText -Text $anchor)" }
    return $text
}

function Format-ScheduleEvent {
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)
    $recurrence = switch ([string]$ScheduleEntry.Recurrence) { 'daily' { (T 'sch.daily') }; 'weekly' { (T 'sch.weekly') }; default { (T 'sch.once') } }
    $at = [datetimeoffset]$ScheduleEntry.ScheduledAt
    $zone = [string](Get-JsonProp $ScheduleEntry 'TimeZoneId')
    if ([string]::IsNullOrWhiteSpace($zone)) { $zone = [System.TimeZoneInfo]::Local.Id }
    $text = "$($ScheduleEntry.TemplateKey) — $($at.ToString('yyyy-MM-dd HH:mm zzz')) — $zone — $recurrence"
    $anchor = Get-ScheduleAnchorLabel -ScheduleEntry $ScheduleEntry -Items (Get-CachedMaterialSchedule)
    if ($anchor) { $text += "`n$anchor" }
    return $text
}

function Start-ScheduleMutationFlow {
    param(
        [Parameter(Mandatory)][ValidateSet('copy', 'edit')][string]$Action,
        [Parameter(Mandatory)][string]$EventId,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId
    )
    $entry = @($script:ScheduleEvents | Where-Object { [string]$_.Id -eq $EventId -and [string]$_.Status -eq 'pending' }) | Select-Object -First 1
    if (-not $entry) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.eventGone') -ReplyMarkup (Get-ScheduleMenuKeyboard)
        return
    }
    if ([long]$entry.UserId -ne $UserId -and -not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.yourEventsOnly') -ReplyMarkup (Get-ScheduleMenuKeyboard)
        return
    }
    $values = @{}
    foreach ($name in $entry.Values.Keys) { $values[[string]$name] = [string]$entry.Values[$name] }
    $state = @{
        Mode = 'schedule_time'; MutationAction = $Action; OriginalEventId = $EventId
        TemplateKey = [string]$entry.TemplateKey; Layer = [int](Get-JsonProp $entry 'Layer')
        Fields = @($values.Keys); Values = $values; Recurrence = [string]$entry.Recurrence
        TimeZoneId = [string]$entry.TimeZoneId; RecurrenceUntil = [string](Get-JsonProp $entry 'RecurrenceUntil'); UserId = $UserId
        AnchorMaterialId = [string](Get-JsonProp $entry 'AnchorMaterialId')
        AnchorOffsetSeconds = [string](Get-JsonProp $entry 'AnchorOffsetSeconds')
    }
    Set-PendingState -ChatId $ChatId -State $state
    $verb = if ($Action -eq 'copy') { (T 'sch.copyEvent') } else { (T 'sch.editEventTime') }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.sendNewTime' $verb $(([datetimeoffset]$entry.ScheduledAt).ToString('yyyy-MM-dd HH:mm zzz')) $($entry.TimeZoneId)) -ReplyMarkup (Get-CancelKeyboard)
}

function Start-ScheduleShowFlow {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    Clear-PendingState -ChatId $ChatId
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { return }
    $state = @{
        Mode = 'schedule_fields'; TemplateIndex = $TemplateIndex; TemplateKey = [string]$template.Key; Layer = [int]$template.Layer
        Fields = @($template.Fields); Labels = @($template.FieldLabels); Limits = @($template.FieldLimits)
        Required = @(Get-JsonProp $template 'FieldRequired' | Where-Object { $null -ne $_ })
        Values = @{}; Index = 0; UserId = $UserId
    }
    if ($state.Fields.Count -eq 0) {
        $state.Mode = 'schedule_time'; Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.whenToShow' $(Get-ScheduleTimeHint) $([datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm zzz')) $([System.TimeZoneInfo]::Local.Id)) -ReplyMarkup (Get-ScheduleTimePromptKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.firstField' $($state.Fields.Count) $($state.Fields[0])) -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-ScheduleText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    if ($state.Mode -eq 'schedule_end_date') {
        $endDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($Value.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$endDate)) {
            Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.sendEndDate') -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        if ($endDate.Date -lt ([datetimeoffset]$state.ScheduledAt).Date) {
            Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.endBeforeStart') -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.RecurrenceUntil = $endDate.ToString('yyyy-MM-dd')
        Show-ScheduleReview -ChatId $ChatId -State $state
        return
    }
    if ($state.Mode -eq 'schedule_fields') {
        $required = $state.Index -lt @($state.Required).Count -and [bool]$state.Required[$state.Index]
        if ($required -and [string]::IsNullOrWhiteSpace($Value)) {
            Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.fieldRequired') -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $limit = if ($state.Index -lt @($state.Limits).Count) { [int]$state.Limits[$state.Index] } else { 0 }
        if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-CancelKeyboard))) { return }
        $state.Values[[string]$state.Fields[$state.Index]] = $Value
        $state.Index = [int]$state.Index + 1
        if ($state.Index -lt $state.Fields.Count) {
            Set-PendingState -ChatId $ChatId -State $state
            Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.field' $($state.Index + 1) $($state.Fields.Count) $($state.Fields[$state.Index])) -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.Mode = 'schedule_time'; Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.whenToShow' $(Get-ScheduleTimeHint) $([datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm zzz')) $([System.TimeZoneInfo]::Local.Id)) -ReplyMarkup (Get-ScheduleTimePromptKeyboard)
        return
    }
    if ($state.Mode -eq 'schedule_time') {
        $parsed = ConvertFrom-OperatorScheduleTime -Text $Value
        if (-not $parsed.Success) {
            Send-TelegramMessage -ChatId $ChatId -Text "❌ $($parsed.Error)" -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        Set-ScheduleMoment -ChatId $ChatId -State $state -ScheduledAt $parsed.ScheduledAt -TimeZoneId $parsed.TimeZoneId
    }
}

function Show-ScheduleReview {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    $recurrence = switch ([string]$State.Recurrence) { 'daily' { (T 'sch.daily') }; 'weekly' { (T 'sch.weekly') }; default { (T 'sch.once') } }
    $reviewTitle = if ($State.ContainsKey('MutationAction')) {
        if ([string]$State.MutationAction -eq 'copy') { (T 'sch.reviewCopy') } else { (T 'sch.reviewEdit') }
    } else { (T 'sch.review') }
    $lines = @(
        $reviewTitle, (T 'sch.template' $($State.TemplateKey)),
        (T 'sch.time' $(([datetimeoffset]$State.ScheduledAt).ToString('yyyy-MM-dd HH:mm zzz'))), (T 'sch.zone' $($State.TimeZoneId)), (T 'sch.repeat' $recurrence)
    )
    $anchorLine = Get-ScheduleAnchorLabel -ScheduleEntry $State -Items (Get-CachedMaterialSchedule)
    if ($anchorLine) { $lines += $anchorLine }
    if ([string]$State.Recurrence -ne 'once') {
        $until = [string](Get-JsonProp $State 'RecurrenceUntil')
        $lines += (T 'sch.repeatEnds' $(if ($until) { $until } else { (T 'sch.noEndDate') }))
    }
    foreach ($field in @($State.Fields)) { $lines += "• $field`: $($State.Values[[string]$field])" }
    $conflicts = @(Get-ScheduleLayerConflicts -Layer ([int]$State.Layer) -ScheduledAt ([datetimeoffset]$State.ScheduledAt) `
        -WindowMinutes (Get-SettingInt 'ScheduleConflictWindowMinutes' 2))
    if ($conflicts.Count -gt 0) {
        $lines += ''
        $lines += (T 'sch.possibleClash' $($State.Layer))
        foreach ($conflict in $conflicts) { $lines += "• $(Format-ScheduleEvent -ScheduleEntry $conflict)" }
    }
    $lines += ''; $lines += (T 'sch.notSavedUntilConfirm')
    $State.Mode = 'schedule_review'; Set-PendingState -ChatId $ChatId -State $State
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-ScheduleReviewKeyboard -State $State)
}

function Get-ScheduleAnchorChoices {
    <#
        Materials the operator can tie a one-off event to: items whose end
        is still ahead, soonest first, capped so the picker stays a screen
        rather than a rundown. Slim shapes only - the pending state carries
        them, and it is persisted to disk.
    #>
    param([array]$Items = @(), [int]$MaxChoices = 12)
    $now = [datetimeoffset]::Now
    $choices = @()
    foreach ($item in @($Items | Sort-Object { [datetimeoffset](Get-JsonProp $_ 'ScheduledAt') })) {
        $start = [datetimeoffset](Get-JsonProp $item 'ScheduledAt')
        $duration = [timespan]::Zero
        try { $duration = [timespan](Get-JsonProp $item 'Duration') } catch { $duration = [timespan]::Zero }
        if (($start + $duration) -le $now) { continue }
        $choices += @(@{
                Id = [string](Get-JsonProp $item 'Id')
                Name = [string](Get-JsonProp $item 'Name')
                ScheduledAt = $start.ToString('o')
            })
        if ($choices.Count -ge $MaxChoices) { break }
    }
    return $choices
}

function Get-ScheduleAnchorPickerKeyboard {
    param([Parameter(Mandatory)][array]$Choices)
    $rows = @()
    for ($i = 0; $i -lt $Choices.Count; $i++) {
        $at = ([datetimeoffset]$Choices[$i].ScheduledAt).ToLocalTime().ToString('HH:mm')
        $name = [string]$Choices[$i].Name
        if ($name.Length -gt 28) { $name = $name.Substring(0, 28) + '…' }
        $rows += , @((New-Button "$at $name" "schanchor:$i"))
    }
    $rows += , @((New-Button (T 'sch.back') 'schedule:anchorback'))
    return @{ inline_keyboard = $rows }
}

function Get-ScheduleAnchorOffsetKeyboard {
    $rows = @(
        , @((New-Button (T 'sch.after30s') 'schoff:30'), (New-Button (T 'sch.after1m') 'schoff:60'))
        , @((New-Button (T 'sch.after5m') 'schoff:300'), (New-Button (T 'sch.atMaterialStart') 'schoff:0'))
        , @((New-Button (T 'sch.back') 'schedule:anchorback'))
    )
    return @{ inline_keyboard = $rows }
}

function Confirm-ScheduledShow {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $UserId) { return }
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    $scheduleEntry = $null
    $saved = $false
    if ($state.ContainsKey('MutationAction') -and [string]$state.MutationAction -eq 'edit') {
        $scheduleEntry = @($script:ScheduleEvents | Where-Object { [string]$_.Id -eq [string]$state.OriginalEventId -and [string]$_.Status -eq 'pending' }) | Select-Object -First 1
        if ($scheduleEntry) {
            $previous = @{
                ScheduledAt = [string]$scheduleEntry.ScheduledAt; TimeZoneId = [string]$scheduleEntry.TimeZoneId
                ExecutionKey = [string]$scheduleEntry.ExecutionKey; CompletedExecutionKey = [string]$scheduleEntry.CompletedExecutionKey
                NextAttemptAt = [string]$scheduleEntry.NextAttemptAt; AttemptCount = [int]$scheduleEntry.AttemptCount
                RecurrenceUntil = [string](Get-JsonProp $scheduleEntry 'RecurrenceUntil')
                AnchorMaterialId = [string](Get-JsonProp $scheduleEntry 'AnchorMaterialId')
                AnchorOffsetSeconds = [string](Get-JsonProp $scheduleEntry 'AnchorOffsetSeconds')
            }
            $scheduleEntry.ScheduledAt = [string]$state.ScheduledAt; $scheduleEntry.TimeZoneId = [string]$state.TimeZoneId
            $scheduleEntry.RecurrenceUntil = [string](Get-JsonProp $state 'RecurrenceUntil')
            $scheduleEntry.ExecutionKey = ''; $scheduleEntry.CompletedExecutionKey = ''; $scheduleEntry.NextAttemptAt = ''; $scheduleEntry.AttemptCount = 0
            # An anchor survives an edit only while it still means something:
            # a recurring event re-anchored to "today's programme" would fire
            # off a stale material, so changing the recurrence clears it.
            if ([string]$state.Recurrence -eq 'once' -and [string]$scheduleEntry.Recurrence -eq 'once') {
                $scheduleEntry.AnchorMaterialId = [string](Get-JsonProp $state 'AnchorMaterialId')
                $scheduleEntry.AnchorOffsetSeconds = [string](Get-JsonProp $state 'AnchorOffsetSeconds')
            }
            else {
                $scheduleEntry.AnchorMaterialId = ''; $scheduleEntry.AnchorOffsetSeconds = 0
            }
            $saved = Save-ScheduleEvents
            if (-not $saved) {
                foreach ($name in $previous.Keys) { $scheduleEntry[$name] = $previous[$name] }
            }
        }
    }
    else {
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey ([string]$state.TemplateKey) -Layer ([int]$state.Layer) -Values $state.Values -ScheduledAt ([datetimeoffset]$state.ScheduledAt) -Recurrence ([string]$state.Recurrence) -ChatId $ChatId -UserId $UserId -RecurrenceUntil ([string](Get-JsonProp $state 'RecurrenceUntil')) -AnchorMaterialId ([string](Get-JsonProp $state 'AnchorMaterialId')) -AnchorOffsetSeconds ([int](Get-JsonProp $state 'AnchorOffsetSeconds'))
        $saved = Add-ScheduledShowEvent -ScheduleEntry $scheduleEntry
    }
    Clear-PendingState -ChatId $ChatId
    if ($saved) {
        $auditAction = if ($state.ContainsKey('MutationAction')) { [string]$state.MutationAction } else { 'created' }
        $auditLabel = switch ($auditAction) { 'updated' { (T 'sch.edit') } 'deleted' { (T 'sch.delete') } default { (T 'sch.create') } }
        Add-AuditEntry (T 'sch.scheduledAudit' $auditLabel $($scheduleEntry.TemplateKey) $($scheduleEntry.Recurrence) $(Format-UserAuditActor -UserId $UserId))
        Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.saved' $(Format-ScheduleEvent -ScheduleEntry $scheduleEntry)) -ReplyMarkup (Get-ScheduleMenuKeyboard)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'sch.saveFailed') -ReplyMarkup (Get-ScheduleMenuKeyboard)
    }
}

function Test-SensitiveFieldName {
    param([Parameter(Mandatory)][string]$FieldName)
    return ($FieldName -match '(?i)(password|passphrase|token|secret|stream[._-]?key|كلمة[ _-]?مرور|رمز[ _-]?سري)')
}

function Get-RecentFieldKey {
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$FieldName)
    return "$UserId|$FieldName"
}

function Save-RecentFieldValues {
    try {
        $json = ConvertTo-Json -InputObject $script:RecentFieldValues -Depth 4
        Write-BridgeValidatedJson -Path $script:recentValuesFile -Json $json | Out-Null
    }
    catch { Write-BridgeLog "Could not write recent-values.json: $($_.Exception.Message)" "WARN" }
}

function Import-RecentFieldValues {
    if (-not (Test-Path -LiteralPath $script:recentValuesFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:recentValuesFile -Raw | ConvertFrom-Json -AsHashtable
        $script:RecentFieldValues.Clear()
        foreach ($key in $raw.Keys) {
            $script:RecentFieldValues[[string]$key] = @($raw[$key] | ForEach-Object { [string]$_ })
        }
    }
    catch { Write-BridgeLog "Could not read recent-values.json: $($_.Exception.Message)" "WARN" }
}

function Get-RecentFieldValues {
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$FieldName)
    $key = Get-RecentFieldKey -UserId $UserId -FieldName $FieldName
    if (-not $script:RecentFieldValues.ContainsKey($key)) { return @() }
    return @($script:RecentFieldValues[$key])
}

function Add-RecentFieldValue {
    param(
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][string]$FieldName,
        [AllowEmptyString()][string]$Value,
        [switch]$Sensitive
    )
    if ($Sensitive -or (Test-SensitiveFieldName -FieldName $FieldName) -or [string]::IsNullOrWhiteSpace($Value)) { return }
    $limit = Get-SettingInt 'RecentValuesPerField' 1
    if ($limit -le 0) { return }
    $key = Get-RecentFieldKey -UserId $UserId -FieldName $FieldName
    $values = @($Value) + @(Get-RecentFieldValues -UserId $UserId -FieldName $FieldName | Where-Object { $_ -cne $Value })
    $script:RecentFieldValues[$key] = @($values | Select-Object -First $limit)
    Save-RecentFieldValues
}

function Save-DraftStates {
    <# Only SHOW preparation is recoverable. Short-lived prompts such as raw
       settings or stream URLs are deliberately never written to disk. #>
    try {
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($chatId in $script:PendingState.Keys) {
            $state = $script:PendingState[$chatId]
            if ([string]$state.Mode -notin @('show_fields', 'show_review')) { continue }
            $copy = @{}
            foreach ($name in $state.Keys) { $copy[$name] = $state[$name] }
            if ($copy.StartedAt -is [datetime]) { $copy.StartedAt = $copy.StartedAt.ToString('o') }
            $entries.Add(@{ ChatId = [long]$chatId; State = $copy })
        }
        $json = ConvertTo-Json -InputObject @($entries.ToArray()) -Depth 8
        Write-BridgeValidatedJson -Path $script:draftsFile -Json $json | Out-Null
    }
    catch { Write-BridgeLog "Could not write drafts.json: $($_.Exception.Message)" "WARN" }
}

function Import-DraftStates {
    if (-not (Test-Path -LiteralPath $script:draftsFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:draftsFile -Raw | ConvertFrom-Json -AsHashtable
        $timeout = Get-SettingInt 'PendingStateTimeoutMinutes' 1
        foreach ($entry in @($raw)) {
            if (-not $entry -or -not $entry.ContainsKey('State')) { continue }
            $state = $entry.State
            if ([string]$state.Mode -notin @('show_fields', 'show_review')) { continue }
            $startedAt = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$state.StartedAt, [ref]$startedAt)) { continue }
            if (((Get-Date) - $startedAt).TotalMinutes -ge $timeout) { continue }
            if ((Get-TemplateIndex -Key ([string]$state.Key)) -lt 0) { continue }
            $chatId = [long]$entry.ChatId
            $layer = [int]$state.LockLayer
            $lock = Lock-GfxLayer -Layer $layer -ChatId $chatId -UserId ([long]$state.UserId) -Key ([string]$state.Key)
            if (-not $lock.Success) { continue }
            $state.StartedAt = $startedAt
            $script:PendingState[$chatId] = $state
            # Told, not just logged. A restored draft is a flow waiting to eat
            # the next thing this operator types: they did not see the restart,
            # so a message they send about something else becomes the text of a
            # breaking-news banner. The log line went to whoever reads the log,
            # which during a shift is nobody.
            $restoredKey = ConvertTo-TelegramHtmlText ([string]$state.Key)
            Send-TelegramMessage -ChatId $chatId `
                -Text (T 'sch.draftSurvivedRestart' $restoredKey) `
                -ParseMode HTML -ReplyMarkup (Get-CancelKeyboard)
        }
        if ($script:PendingState.Count -gt 0) {
            Write-BridgeLog "Restored $($script:PendingState.Count) operator draft(s) from the previous run"
        }
        Save-DraftStates
    }
    catch { Write-BridgeLog "Could not read drafts.json: $($_.Exception.Message)" "WARN" }
}

