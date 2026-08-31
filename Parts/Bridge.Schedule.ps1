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

function ConvertFrom-OperatorScheduleTime {
    param([Parameter(Mandatory)][string]$Text, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $clock = Get-SystemClockStatus -Now $Now
    if (-not $clock.Success) { return $clock }
    $localTime = [datetime]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [datetime]::TryParseExact($Text.Trim(), 'yyyy-MM-dd HH:mm', $culture, [System.Globalization.DateTimeStyles]::None, [ref]$localTime)) {
        return [pscustomobject]@{ Success = $false; Error = 'استخدم الصيغة YYYY-MM-DD HH:mm'; TimeZoneId = $clock.TimeZoneId }
    }
    $localTime = [datetime]::SpecifyKind($localTime, [System.DateTimeKind]::Unspecified)
    $zone = [System.TimeZoneInfo]::Local
    if ($zone.IsInvalidTime($localTime) -or $zone.IsAmbiguousTime($localTime)) {
        return [pscustomobject]@{ Success = $false; Error = 'الوقت غير واضح بسبب تغيير التوقيت المحلي؛ اختر وقتًا آخر.'; TimeZoneId = $zone.Id }
    }
    $scheduledAt = [datetimeoffset]::new($localTime, $zone.GetUtcOffset($localTime))
    if ($scheduledAt -le $Now) {
        return [pscustomobject]@{ Success = $false; Error = 'يجب أن يكون الموعد في المستقبل.'; TimeZoneId = $zone.Id }
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
        [string]$RecurrenceUntil = ''
    )
    return @{
        Id = [guid]::NewGuid().ToString(); TemplateKey = $TemplateKey; Layer = $Layer; Values = $Values
        ScheduledAt = $ScheduledAt.ToString('o'); TimeZoneId = [System.TimeZoneInfo]::Local.Id
        Recurrence = $Recurrence; Status = 'pending'; ChatId = $ChatId; UserId = $UserId
        CreatedAt = [datetimeoffset]::Now.ToString('o'); ExecutionKey = ''
        CompletedExecutionKey = ''; StartedAt = ''; CompletedAt = ''; LastResult = ''
        AttemptCount = 0; NextAttemptAt = ''; RecurrenceUntil = $RecurrenceUntil
        NotificationExecutionKey = ''; LastTemplateCheckAt = ''; LastTemplateCheckStatus = ''
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

function Write-ScheduleExecutionEntry {
    param(
        [Parameter(Mandatory)][hashtable]$ScheduleEntry,
        [Parameter(Mandatory)][ValidateSet('success', 'failed')][string]$Result,
        [Parameter(Mandatory)][long]$DurationMs,
        [int]$Attempt = 1,
        [string]$ErrorText = ''
    )
    try {
        $record = [ordered]@{
            Timestamp    = [datetimeoffset]::Now.ToString('o')
            EventId      = [string]$ScheduleEntry.Id
            ExecutionKey = [string]$ScheduleEntry.ExecutionKey
            TemplateKey  = [string]$ScheduleEntry.TemplateKey
            Layer        = [int](Get-JsonProp $ScheduleEntry 'Layer')
            ScheduledAt  = [string]$ScheduleEntry.ScheduledAt
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

function Import-ScheduleEvents {
    try {
        $read = Read-ValidatedJsonState -Path $script:scheduleFile -AsHashtable
        if (-not $read) { return }
        $raw = $read.Data
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        $recovered = $false
        foreach ($scheduleEntry in @($raw)) {
            if (-not $scheduleEntry -or -not $scheduleEntry.ContainsKey('Id')) { continue }
            if ([string]$scheduleEntry.Status -eq 'running') {
                # The command may already have reached Cinegy before the crash.
                # Never replay that occurrence automatically.
                $scheduleEntry.Status = 'interrupted'
                $scheduleEntry.LastResult = 'Bridge restarted while occurrence was running; not replayed.'
                $recovered = $true
            }
            $script:ScheduleEvents.Add($scheduleEntry)
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

function Get-ScheduledTemplateStatus {
    <# Resolve the template again when the timer fires. A schedule stores the
       stable key and captured values, not a stale copy of the template
       definition; an operator may have edited or disabled it since creation. #>
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)
    $key = [string](Get-JsonProp $ScheduleEntry 'TemplateKey')
    if ([string]::IsNullOrWhiteSpace($key)) {
        return [pscustomobject]@{ Success = $false; State = 'invalid'; Key = ''; Layer = 0; Path = ''; Error = 'الحدث المجدول بلا مفتاح قالب.' }
    }
    try {
        $store = Get-TemplateStore
        $map = Get-JsonProp $store 'Map'
        if (-not $map -or -not $map.ContainsKey($key)) {
            $invalidKeys = @(Get-JsonProp $store 'InvalidKeys' | Where-Object { $null -ne $_ })
            if (@($invalidKeys | Where-Object { [string]$_ -eq $key }).Count -gt 0) {
                return [pscustomobject]@{
                    Success = $false; State = 'invalid'; Key = $key; Layer = 0; Path = ''
                    Error = "القالب '$key' غير صالح عند وقت التنفيذ."
                }
            }
            return [pscustomobject]@{
                Success = $false; State = 'missing'; Key = $key; Layer = 0; Path = ''
                Error = "القالب '$key' غير موجود عند وقت التنفيذ."
            }
        }
        $template = $map[$key]
        $layer = 0
        [int]::TryParse([string](Get-JsonProp $template 'Layer'), [ref]$layer) | Out-Null
        $path = [string](Get-JsonProp $template 'Path')
        if ($layer -le 0 -or [string]::IsNullOrWhiteSpace($path)) {
            return [pscustomobject]@{
                Success = $false; State = 'invalid'; Key = $key; Layer = $layer; Path = $path
                Error = "القالب '$key' غير صالح عند وقت التنفيذ (المسار أو الطبقة غير مكتملة)."
            }
        }
        return [pscustomobject]@{ Success = $true; State = 'ready'; Key = $key; Layer = $layer; Path = $path; Error = '' }
    }
    catch {
        return [pscustomobject]@{
            Success = $false; State = 'error'; Key = $key; Layer = 0; Path = ''
            Error = "تعذّر فحص القالب '$key' عند وقت التنفيذ: $($_.Exception.Message)"
        }
    }
}

function Update-ScheduleQueue {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    if (Get-Setting 'MaintenanceMode') { return }
    if (Get-Setting 'SchedulePaused') { return }
    foreach ($scheduleEntry in @($script:ScheduleEvents)) {
        if ([string]$scheduleEntry.Status -ne 'pending') { continue }
        $scheduledAt = [datetimeoffset]$scheduleEntry.ScheduledAt
        $occurrenceKey = "$($scheduleEntry.Id)|$($scheduledAt.ToString('o'))"
        $notifyMinutes = Get-SettingInt 'SchedulePreNotifyMinutes' 0
        $minutesUntil = ($scheduledAt - $Now).TotalMinutes
        if ($notifyMinutes -gt 0 -and $minutesUntil -gt 0 -and $minutesUntil -le $notifyMinutes -and
            [string](Get-JsonProp $scheduleEntry 'NotificationExecutionKey') -ne $occurrenceKey) {
            $roundedMinutes = [math]::Max(1, [math]::Ceiling($minutesUntil))
            Send-TelegramMessage -ChatId ([long]$scheduleEntry.ChatId) -Text "⏰ الحدث المجدول '$($scheduleEntry.TemplateKey)' سيُعرض بعد نحو $roundedMinutes دقائق.`n$(Format-ScheduleEvent -ScheduleEntry $scheduleEntry)"
            $scheduleEntry.NotificationExecutionKey = $occurrenceKey
            Save-ScheduleEvents | Out-Null
        }
        $dueState=Get-BridgeScheduleDueState -ScheduleEntry $scheduleEntry -Now $Now
        if(-not $dueState.IsDue){continue}
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
            Send-AdminBroadcast -Text ("⚠️ حدث مجدول يستبدل مشهدًا على الهواء`n" +
                "الطبقة ${targetLayer}: '$($displaced.Key)' ← '$($scheduleEntry.TemplateKey)'")
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
            Send-TelegramMessage -ChatId ([long]$scheduleEntry.ChatId) -Text "⛔ لم يتم تشغيل الموعد: $($templateStatus.Error)"
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
    $recurrence = switch ([string]$ScheduleEntry.Recurrence) { 'daily' { 'يومي' }; 'weekly' { 'أسبوعي' }; default { 'مرة واحدة' } }
    $at = [datetimeoffset]$ScheduleEntry.ScheduledAt
    $zone = [string](Get-JsonProp $ScheduleEntry 'TimeZoneId')
    if ([string]::IsNullOrWhiteSpace($zone)) { $zone = [System.TimeZoneInfo]::Local.Id }
    $key = ConvertTo-TelegramHtmlText -Text ([string]$ScheduleEntry.TemplateKey)
    # The element's own text is what a client too old for tg-time shows, so it
    # has to read correctly on its own.
    $fallback = ConvertTo-TelegramHtmlText -Text ($at.ToString('yyyy-MM-dd HH:mm'))
    $stamp = "<tg-time unix=`"$($at.ToUnixTimeSeconds())`" format=`"wdt`">$fallback</tg-time>"
    return "<b>$key</b> — $stamp — $(ConvertTo-TelegramHtmlText -Text $zone) — $recurrence"
}

function Format-ScheduleEvent {
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)
    $recurrence = switch ([string]$ScheduleEntry.Recurrence) { 'daily' { 'يومي' }; 'weekly' { 'أسبوعي' }; default { 'مرة واحدة' } }
    $at = [datetimeoffset]$ScheduleEntry.ScheduledAt
    $zone = [string](Get-JsonProp $ScheduleEntry 'TimeZoneId')
    if ([string]::IsNullOrWhiteSpace($zone)) { $zone = [System.TimeZoneInfo]::Local.Id }
    return "$($ScheduleEntry.TemplateKey) — $($at.ToString('yyyy-MM-dd HH:mm zzz')) — $zone — $recurrence"
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
        Send-TelegramMessage -ChatId $ChatId -Text 'الحدث لم يعد متاحًا للنسخ أو التعديل.' -ReplyMarkup (Get-ScheduleMenuKeyboard)
        return
    }
    if ([long]$entry.UserId -ne $UserId -and -not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'يمكنك تعديل أحداثك فقط.' -ReplyMarkup (Get-ScheduleMenuKeyboard)
        return
    }
    $values = @{}
    foreach ($name in $entry.Values.Keys) { $values[[string]$name] = [string]$entry.Values[$name] }
    $state = @{
        Mode = 'schedule_time'; MutationAction = $Action; OriginalEventId = $EventId
        TemplateKey = [string]$entry.TemplateKey; Layer = [int](Get-JsonProp $entry 'Layer')
        Fields = @($values.Keys); Values = $values; Recurrence = [string]$entry.Recurrence
        TimeZoneId = [string]$entry.TimeZoneId; RecurrenceUntil = [string](Get-JsonProp $entry 'RecurrenceUntil'); UserId = $UserId
    }
    Set-PendingState -ChatId $ChatId -State $state
    $verb = if ($Action -eq 'copy') { 'نسخ الحدث إلى موعد جديد' } else { 'تعديل موعد الحدث' }
    Send-TelegramMessage -ChatId $ChatId -Text "📅 $verb`nالموعد الحالي: $(([datetimeoffset]$entry.ScheduledAt).ToString('yyyy-MM-dd HH:mm zzz'))`nالمنطقة: $($entry.TimeZoneId)`nأرسل الموعد الجديد بصيغة YYYY-MM-DD HH:mm" -ReplyMarkup (Get-CancelKeyboard)
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
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل موعد العرض بصيغة YYYY-MM-DD HH:mm`nالوقت الحالي: $([datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm zzz'))`nالمنطقة: $([System.TimeZoneInfo]::Local.Id)" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text "📅 قيمة الحقل (1/$($state.Fields.Count)):`n$($state.Fields[0])" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-ScheduleText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    if ($state.Mode -eq 'schedule_end_date') {
        $endDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($Value.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$endDate)) {
            Send-TelegramMessage -ChatId $ChatId -Text '❌ أرسل تاريخ الانتهاء بصيغة YYYY-MM-DD.' -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        if ($endDate.Date -lt ([datetimeoffset]$state.ScheduledAt).Date) {
            Send-TelegramMessage -ChatId $ChatId -Text '❌ تاريخ الانتهاء يجب ألا يسبق أول موعد.' -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.RecurrenceUntil = $endDate.ToString('yyyy-MM-dd')
        Show-ScheduleReview -ChatId $ChatId -State $state
        return
    }
    if ($state.Mode -eq 'schedule_fields') {
        $required = $state.Index -lt @($state.Required).Count -and [bool]$state.Required[$state.Index]
        if ($required -and [string]::IsNullOrWhiteSpace($Value)) {
            Send-TelegramMessage -ChatId $ChatId -Text "هذا الحقل إلزامي ولا يمكن تركه فارغًا." -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $limit = if ($state.Index -lt @($state.Limits).Count) { [int]$state.Limits[$state.Index] } else { 0 }
        if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-CancelKeyboard))) { return }
        $state.Values[[string]$state.Fields[$state.Index]] = $Value
        $state.Index = [int]$state.Index + 1
        if ($state.Index -lt $state.Fields.Count) {
            Set-PendingState -ChatId $ChatId -State $state
            Send-TelegramMessage -ChatId $ChatId -Text "📅 قيمة الحقل ($($state.Index + 1)/$($state.Fields.Count)):`n$($state.Fields[$state.Index])" -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.Mode = 'schedule_time'; Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل موعد العرض بصيغة YYYY-MM-DD HH:mm`nالوقت الحالي: $([datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm zzz'))`nالمنطقة: $([System.TimeZoneInfo]::Local.Id)" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    if ($state.Mode -eq 'schedule_time') {
        $parsed = ConvertFrom-OperatorScheduleTime -Text $Value
        if (-not $parsed.Success) {
            Send-TelegramMessage -ChatId $ChatId -Text "❌ $($parsed.Error)`nأرسل الموعد بصيغة YYYY-MM-DD HH:mm" -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.ScheduledAt = $parsed.ScheduledAt.ToString('o'); $state.TimeZoneId = $parsed.TimeZoneId
        if ($state.ContainsKey('MutationAction')) {
            Show-ScheduleReview -ChatId $ChatId -State $state
            return
        }
        $state.Mode = 'schedule_recurrence'; Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "فُهم الموعد: $($parsed.ScheduledAt.ToString('yyyy-MM-dd HH:mm zzz'))`nالمنطقة: $($parsed.TimeZoneId)`nاختر التكرار:" -ReplyMarkup (Get-ScheduleRecurrenceKeyboard)
    }
}

function Show-ScheduleReview {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    $recurrence = switch ([string]$State.Recurrence) { 'daily' { 'يومي' }; 'weekly' { 'أسبوعي' }; default { 'مرة واحدة' } }
    $reviewTitle = if ($State.ContainsKey('MutationAction')) {
        if ([string]$State.MutationAction -eq 'copy') { '🔎 مراجعة نسخة الحدث' } else { '🔎 مراجعة تعديل موعد الحدث' }
    } else { '🔎 مراجعة الجدولة' }
    $lines = @(
        $reviewTitle, "القالب: $($State.TemplateKey)",
        "الموعد: $(([datetimeoffset]$State.ScheduledAt).ToString('yyyy-MM-dd HH:mm zzz'))", "المنطقة: $($State.TimeZoneId)", "التكرار: $recurrence"
    )
    if ([string]$State.Recurrence -ne 'once') {
        $until = [string](Get-JsonProp $State 'RecurrenceUntil')
        $lines += "نهاية التكرار: $(if ($until) { $until } else { 'بدون تاريخ انتهاء' })"
    }
    foreach ($field in @($State.Fields)) { $lines += "• $field`: $($State.Values[[string]$field])" }
    $conflicts = @(Get-ScheduleLayerConflicts -Layer ([int]$State.Layer) -ScheduledAt ([datetimeoffset]$State.ScheduledAt) `
        -WindowMinutes (Get-SettingInt 'ScheduleConflictWindowMinutes' 2))
    if ($conflicts.Count -gt 0) {
        $lines += ''
        $lines += "⚠️ تعارض محتمل على الطبقة $($State.Layer):"
        foreach ($conflict in $conflicts) { $lines += "• $(Format-ScheduleEvent -ScheduleEntry $conflict)" }
    }
    $lines += ''; $lines += 'لن يُحفظ الحدث حتى تضغط تأكيد الجدولة.'
    $State.Mode = 'schedule_review'; Set-PendingState -ChatId $ChatId -State $State
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-ScheduleReviewKeyboard -State $State)
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
            }
            $scheduleEntry.ScheduledAt = [string]$state.ScheduledAt; $scheduleEntry.TimeZoneId = [string]$state.TimeZoneId
            $scheduleEntry.RecurrenceUntil = [string](Get-JsonProp $state 'RecurrenceUntil')
            $scheduleEntry.ExecutionKey = ''; $scheduleEntry.CompletedExecutionKey = ''; $scheduleEntry.NextAttemptAt = ''; $scheduleEntry.AttemptCount = 0
            $saved = Save-ScheduleEvents
            if (-not $saved) {
                foreach ($name in $previous.Keys) { $scheduleEntry[$name] = $previous[$name] }
            }
        }
    }
    else {
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey ([string]$state.TemplateKey) -Layer ([int]$state.Layer) -Values $state.Values -ScheduledAt ([datetimeoffset]$state.ScheduledAt) -Recurrence ([string]$state.Recurrence) -ChatId $ChatId -UserId $UserId -RecurrenceUntil ([string](Get-JsonProp $state 'RecurrenceUntil'))
        $saved = Add-ScheduledShowEvent -ScheduleEntry $scheduleEntry
    }
    Clear-PendingState -ChatId $ChatId
    if ($saved) {
        $auditAction = if ($state.ContainsKey('MutationAction')) { [string]$state.MutationAction } else { 'created' }
        $auditLabel = switch ($auditAction) { 'updated' { 'تعديل' } 'deleted' { 'حذف' } default { 'إنشاء' } }
        Add-AuditEntry "📅 جدولة: $auditLabel $($scheduleEntry.TemplateKey) / $($scheduleEntry.Recurrence) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم حفظ الجدولة.`n$(Format-ScheduleEvent -ScheduleEntry $scheduleEntry)" -ReplyMarkup (Get-ScheduleMenuKeyboard)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ ملف الجدولة، لذلك لم يُعتمد الحدث." -ReplyMarkup (Get-ScheduleMenuKeyboard)
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
        $temporary = "$script:recentValuesFile.tmp"
        $json = ConvertTo-Json -InputObject $script:RecentFieldValues -Depth 4
        Set-Content -LiteralPath $temporary -Value $json -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:recentValuesFile -Force -ErrorAction Stop
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
        $temporary = "$script:draftsFile.tmp"
        Set-Content -LiteralPath $temporary -Value $json -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:draftsFile -Force -ErrorAction Stop
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
        }
        if ($script:PendingState.Count -gt 0) {
            Write-BridgeLog "Restored $($script:PendingState.Count) operator draft(s) from the previous run"
        }
        Save-DraftStates
    }
    catch { Write-BridgeLog "Could not read drafts.json: $($_.Exception.Message)" "WARN" }
}

