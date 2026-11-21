$script:WebTemplateScheduleReviews = @{}

function ConvertTo-WebTemplateScheduleItem {
    param([System.Collections.IDictionary]$Entry)

    $at = [datetimeoffset]$Entry.ScheduledAt
    $zone = [string](Get-JsonProp $Entry 'TimeZoneId')
    if (-not $zone) { $zone = [TimeZoneInfo]::Local.Id }
    return [ordered]@{
        id = [string]$Entry.Id
        key = [string]$Entry.TemplateKey
        layer = [int](Get-JsonProp $Entry 'Layer')
        scheduledAtMs = $at.ToUnixTimeMilliseconds()
        stationTime = $at.ToString('yyyy-MM-dd HH:mm zzz', [Globalization.CultureInfo]::InvariantCulture)
        stationTimeZone = $zone
        recurrence = [string]$Entry.Recurrence
        recurrenceUntil = [string](Get-JsonProp $Entry 'RecurrenceUntil')
    }
}

function Get-WebTemplateSchedulePage {
    param([int]$Page)

    $entries = @(Get-UpcomingScheduleEvents)
    $window = Get-BridgePageWindow -ItemCount $entries.Count -Page $Page -PageSize 12
    $items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            ConvertTo-WebTemplateScheduleItem -Entry $entries[$index]
        })
    $clock = Get-SystemClockStatus
    return @{
        items = $items
        page = $window.Page
        pageCount = $window.PageCount
        total = $entries.Count
        stationTimeZone = $clock.TimeZoneId
        stationOffsetMinutes = [int]$clock.Offset.TotalMinutes
        stationTime = $clock.Now.ToString('yyyy-MM-dd HH:mm zzz', [Globalization.CultureInfo]::InvariantCulture)
        clockValid = $clock.Success
        paused = [bool](Get-Setting 'SchedulePaused')
    }
}

function Get-WebTemplateScheduleTarget {
    param([long]$Actor, [string]$Key)

    if (-not $Key) { return @{ ok = $false; error = 'schedule_invalid' } }
    $store = Get-TemplateStore
    $template = Get-JsonProp (Get-JsonProp $store 'Map') $Key
    $layer = [int](Get-JsonProp $template 'Layer')
    $path = [string](Get-JsonProp $template 'Path')
    if ($layer -le 0 -or -not $path) { return @{ ok = $false; error = 'schedule_template_unavailable' } }
    $access = Test-TemplateAccess -Key $template.Key -Layer $layer -ChatId $Actor -UserId $Actor
    $policy = Test-TemplateShowPolicy -Key $template.Key -Layer $layer -IsAdmin:(Test-Admin -ChatId $Actor -UserId $Actor)
    if (-not $access.Allowed -or -not $policy.Allowed) { return @{ ok = $false; error = 'forbidden' } }

    return @{ ok = $true; template = $template }
}

function Test-WebScheduledShowAccess {
    param([System.Collections.IDictionary]$ScheduleEntry)

    # Legacy appointments have no source marker. The caller checks this gate
    # before notices or an overwrite warning, while still on the bridge thread.
    if ((Get-JsonProp $ScheduleEntry 'Source') -ne 'web') { return $true }
    $actor = [long](Get-JsonProp $ScheduleEntry 'UserId')
    $chat = [long](Get-JsonProp $ScheduleEntry 'ChatId')
    return ($actor -gt 0 -and $chat -eq $actor -and (Test-Authorized -ChatId $chat -UserId $actor))
}

function Get-WebTemplateScheduleReviewContext {
    param([long]$Actor, [string]$Key, [datetimeoffset]$ScheduledAt)

    $target = Get-WebTemplateScheduleTarget -Actor $Actor -Key $Key
    if (-not $target.ok) { return $target }
    $template = $target.template
    $fields = @(Get-WebTemplateFields -Template $template)
    $conflicts = @(Get-ScheduleLayerConflicts -Layer ([int]$template.Layer) -ScheduledAt $ScheduledAt `
            -WindowMinutes (Get-SettingInt 'ScheduleConflictWindowMinutes' 2) | Sort-Object -Property ScheduledAt, Id | ForEach-Object {
            ConvertTo-WebTemplateScheduleItem -Entry $_
        })
    $fingerprint = ConvertTo-Json -Depth 8 -Compress -InputObject ([ordered]@{
            key = $template.Key
            layer = $template.Layer
            path = $template.Path
            device = [string](Get-JsonProp $template 'Device')
            definition = [string](Get-JsonProp $template 'PresetRevision')
            fields = $fields
            conflicts = $conflicts
        })
    return @{ ok = $true; template = $template; fields = $fields; conflicts = $conflicts; fingerprint = $fingerprint }
}

function Invoke-WebTemplateScheduleReview {
    param([long]$Actor, [System.Collections.IDictionary]$Arguments)

    $key = [string](Get-JsonProp $Arguments 'key')
    $time = Get-JsonProp $Arguments 'time'
    $recurrence = [string](Get-JsonProp $Arguments 'recurrence')
    $until = [string](Get-JsonProp $Arguments 'recurrenceUntil')
    $invalid = @{ ok = $false; error = 'schedule_invalid' }
    if ($time -isnot [string] -or -not $time.Trim() -or $time.Length -gt 64 -or
        $recurrence -cnotin @('once', 'daily', 'weekly')) { return $invalid }

    $clock = Get-SystemClockStatus
    if (-not $clock.Success) { return @{ ok = $false; error = 'schedule_clock' } }
    $parsed = ConvertFrom-OperatorScheduleTime -Text $time -Now $clock.Now
    if (-not $parsed.Success) { return @{ ok = $false; error = 'schedule_invalid_time'; data = $parsed.Error } }
    if ($until) {
        $endDate = [datetime]::MinValue
        if ($recurrence -eq 'once' -or -not [datetime]::TryParseExact($until, 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$endDate) -or
            $endDate.Date -lt $parsed.ScheduledAt.Date) { return @{ ok = $false; error = 'schedule_invalid_end' } }
    }

    $context = Get-WebTemplateScheduleReviewContext -Actor $Actor -Key $key -ScheduledAt $parsed.ScheduledAt
    if (-not $context.ok) { return $context }
    $template = $context.template
    $rawValues = Get-JsonProp $Arguments 'variables'
    if ($null -ne $rawValues -and $rawValues -isnot [System.Collections.IDictionary]) { return $invalid }
    $values = @{}
    if ($null -ne $rawValues) {
        foreach ($name in $rawValues.Keys) {
            if ($name -notin $template.Fields -or $rawValues[$name] -isnot [string] -or $values.ContainsKey($name)) {
                return @{ ok = $false; error = 'schedule_invalid_fields' }
            }
            $values[$name] = $rawValues[$name]
        }
    }

    $visibleFields = @()
    foreach ($field in $context.fields) {
        $value = [string]$values[$field.name]
        if (($field.required -and [string]::IsNullOrWhiteSpace($value)) -or
            ($field.maxLength -and (Get-TextElementCount -Text $value) -gt $field.maxLength)) {
            return @{ ok = $false; error = 'schedule_invalid_fields' }
        }
        $visibleFields += @{
            name = $field.name
            label = $field.label
            sensitive = $field.sensitive
            value = if ($field.sensitive) { $null } else { $value }
        }
    }

    $entry = New-ScheduledShowEvent -TemplateKey $template.Key -Layer ([int]$template.Layer) -Values $values `
        -ScheduledAt $parsed.ScheduledAt -Recurrence $recurrence -RecurrenceUntil $until -ChatId $Actor -UserId $Actor
    $entry.Source = 'web'
    $review = New-WebAirReview -Actor $Actor -Fingerprint $context.fingerprint -Reviews $script:WebTemplateScheduleReviews
    # Keep the selected time and field values server-side. Replaying a typed
    # relative offset during confirmation would silently move the graphic.
    $script:WebTemplateScheduleReviews[$Actor].Entry = $entry
    $data = ConvertTo-WebTemplateScheduleItem -Entry $entry
    $data.Remove('id')
    $data.review = $review
    $data.conflicts = @($context.conflicts | Select-Object -First 12)
    $data.conflictCount = $context.conflicts.Count
    $data.fields = $visibleFields
    return @{ ok = $true; data = $data }
}

function Invoke-WebTemplateSchedule {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'list') {
        $page = 0
        if ($Arguments.Contains('page') -and -not [int]::TryParse([string](Get-JsonProp $Arguments 'page'), [ref]$page)) {
            return @{ ok = $false; error = 'schedule_invalid' }
        }
        return @{ ok = $true; data = Get-WebTemplateSchedulePage -Page $page }
    }
    if ($action -notin @('review', 'confirm')) { return @{ ok = $false; error = 'schedule_invalid' } }
    if ((Get-Setting 'MaintenanceMode') -or (Test-MaintenanceWindowActive)) {
        return @{ ok = $false; error = 'schedule_maintenance' }
    }
    if ($action -eq 'review') { return Invoke-WebTemplateScheduleReview -Actor $actor -Arguments $Arguments }

    $stale = @{ ok = $false; error = 'schedule_stale' }
    $review = [string](Get-JsonProp $Arguments 'review')
    if (-not $review) { return $stale }
    $pending = Use-WebAirReview -Actor $actor -Token $review -Reviews $script:WebTemplateScheduleReviews
    if (-not $pending) { return $stale }
    $entry = $pending.Entry
    $clock = Get-SystemClockStatus
    if (-not $clock.Success) { return @{ ok = $false; error = 'schedule_clock' } }
    if ([datetimeoffset]$entry.ScheduledAt -le $clock.Now -or $entry.TimeZoneId -cne $clock.TimeZoneId) { return $stale }
    $context = Get-WebTemplateScheduleReviewContext -Actor $actor -Key $entry.TemplateKey -ScheduledAt ([datetimeoffset]$entry.ScheduledAt)
    if (-not $context.ok -and $context.error -eq 'forbidden') { return $context }
    if (-not $context.ok -or $context.fingerprint -cne $pending.Fingerprint) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    if (-not (Add-ScheduledShowEvent -ScheduleEntry $entry)) {
        return @{ ok = $false; error = 'schedule_save_failed' }
    }

    Add-AuditEntry (T 'sch.scheduledAudit' (T 'sch.create') $entry.TemplateKey $entry.Recurrence (Format-UserAuditActor -UserId $actor))
    return @{ ok = $true; data = Get-WebTemplateSchedulePage -Page 0 }
}
