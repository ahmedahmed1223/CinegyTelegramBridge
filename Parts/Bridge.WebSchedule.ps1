$script:WebTemplateScheduleReviews = @{}
$script:WebScheduleHoldReviews = @{}

function ConvertTo-WebTemplateScheduleItem {
    param([hashtable]$Entry, [long]$Actor = 0, [array]$MaterialItems = @())

    $at = Resolve-ScheduleAnchorTime -ScheduleEntry $Entry -Items $MaterialItems
    $zone = [string](Get-JsonProp $Entry 'TimeZoneId')
    if (-not $zone) { $zone = [TimeZoneInfo]::Local.Id }
    if ([string](Get-JsonProp $Entry 'AnchorMaterialId')) { $at = $at.ToLocalTime() }
    return [ordered]@{
        id = [string]$Entry.Id
        key = [string]$Entry.TemplateKey
        layer = [int](Get-JsonProp $Entry 'Layer')
        scheduledAtMs = $at.ToUnixTimeMilliseconds()
        stationTime = $at.ToString('yyyy-MM-dd HH:mm zzz', [Globalization.CultureInfo]::InvariantCulture)
        stationTimeZone = $zone
        recurrence = [string]$Entry.Recurrence
        recurrenceUntil = [string](Get-JsonProp $Entry 'RecurrenceUntil')
        revision = if ($Actor -gt 0) { Get-ScheduledShowEventRevision -ScheduleEntry $Entry } else { '' }
        canManage = [bool]($Actor -gt 0 -and (Test-ScheduledShowEventOwnership -ScheduleEntry $Entry -ChatId $Actor -UserId $Actor))
        anchorMaterialId = [string](Get-JsonProp $Entry 'AnchorMaterialId')
        anchorOffsetSeconds = [int](Get-JsonProp $Entry 'AnchorOffsetSeconds')
    }
}

function Get-WebTemplateSchedulePage {
    param([int]$Page, [long]$Actor)

    $entries = @(Get-UpcomingScheduleEvents)
    $materials = @()
    if ($entries | Where-Object { Get-JsonProp $_ 'AnchorMaterialId' } | Select-Object -First 1) {
        $materials = @(Get-CachedMaterialSchedule)
        $entries = @($entries | Sort-Object -Property { Resolve-ScheduleAnchorTime -ScheduleEntry $_ -Items $materials }, Id)
    }
    $window = Get-BridgePageWindow -ItemCount $entries.Count -Page $Page -PageSize 12
    $items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            ConvertTo-WebTemplateScheduleItem -Entry $entries[$index] -Actor $Actor -MaterialItems $materials
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
        materialsEnabled = [bool](Get-Setting 'EnableMaterialSchedule')
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

    # Both clients can move an appointment, but an edit preserves who will
    # execute it and which authorization rule that original booking used.
    if ((Get-JsonProp $ScheduleEntry 'Source') -ne 'web') { return $true }
    $actor = [long](Get-JsonProp $ScheduleEntry 'UserId')
    $chat = [long](Get-JsonProp $ScheduleEntry 'ChatId')
    return ($actor -gt 0 -and $chat -eq $actor -and (Test-Authorized -ChatId $chat -UserId $actor))
}

function Get-WebTemplateScheduleOriginal {
    param([long]$Actor, [string]$Id, [string]$Revision)

    $entry = Get-PendingScheduledShowEvent -Id $Id
    if (-not $entry) { return @{ ok = $false; error = 'schedule_stale' } }
    if (-not (Test-ScheduledShowEventOwnership -ScheduleEntry $entry -ChatId $Actor -UserId $Actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    if (-not $Revision -or (Get-ScheduledShowEventRevision -ScheduleEntry $entry) -cne $Revision) {
        return @{ ok = $false; error = 'schedule_stale' }
    }
    return @{ ok = $true; entry = $entry }
}

function Get-WebTemplateScheduleContext {
    param([long]$Actor, [string]$Key, [datetimeoffset]$ScheduledAt, [string]$ExcludeId,
        [AllowEmptyCollection()][array]$MaterialItems)

    $target = Get-WebTemplateScheduleTarget -Actor $Actor -Key $Key
    if (-not $target.ok) { return $target }
    $template = $target.template
    $fields = @(Get-WebTemplateFields -Template $template)
    if ($null -eq $MaterialItems -and (Get-UpcomingScheduleEvents | Where-Object {
                Get-JsonProp $_ 'AnchorMaterialId'
            } | Select-Object -First 1)) {
        $MaterialItems = @(Get-CachedMaterialSchedule)
    }
    $conflicts = @(Get-ScheduleLayerConflicts -Layer ([int]$template.Layer) -ScheduledAt $ScheduledAt -ExcludeId $ExcludeId `
            -WindowMinutes (Get-SettingInt 'ScheduleConflictWindowMinutes' 2) -MaterialItems $MaterialItems |
            Sort-Object -Property { Resolve-ScheduleAnchorTime -ScheduleEntry $_ -Items $MaterialItems }, Id | ForEach-Object {
                ConvertTo-WebTemplateScheduleItem -Entry $_ -MaterialItems $MaterialItems
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

function Get-WebTemplateScheduleMoment {
    param([System.Collections.IDictionary]$Arguments, [hashtable]$Original, [string]$Recurrence, [datetimeoffset]$Now)

    $invalid = @{ ok = $false; error = 'schedule_invalid' }
    $requestedId = Get-JsonProp $Arguments 'anchorMaterialId'
    $anchorId = if ($null -eq $requestedId) { [string](Get-JsonProp $Original 'AnchorMaterialId') } else { [string]$requestedId }
    $offsetText = Get-JsonProp $Arguments 'anchorOffsetSeconds'
    if ($null -eq $offsetText -and $anchorId -eq [string](Get-JsonProp $Original 'AnchorMaterialId')) {
        $offsetText = Get-JsonProp $Original 'AnchorOffsetSeconds'
    }
    $offset = 0
    if ($null -ne $offsetText -and -not [int]::TryParse([string]$offsetText, [ref]$offset)) { return $invalid }
    if ($anchorId) {
        if ($Recurrence -ne 'once') { return @{ ok = $false; error = 'schedule_material_invalid' } }
        $anchor = Get-WebScheduleMaterialAnchor -MaterialId $anchorId -OffsetSeconds $offset -Now $Now
        if (-not $anchor.ok) { return $anchor }
        return @{ ok = $true; at = $anchor.at; materialId = $anchor.id; materialName = $anchor.name; offset = $offset; items = $anchor.items }
    }

    $time = Get-JsonProp $Arguments 'time'
    if ($time -isnot [string] -or -not $time.Trim() -or $time.Length -gt 64 -or $offset -ne 0) { return $invalid }
    $parsed = ConvertFrom-OperatorScheduleTime -Text $time -Now $Now
    if (-not $parsed.Success) { return @{ ok = $false; error = 'schedule_invalid_time'; data = $parsed.Error } }
    return @{ ok = $true; at = $parsed.ScheduledAt; materialId = ''; materialName = ''; offset = 0; items = $null }
}

function Get-WebTemplateScheduleFieldInput {
    param($Requested, [System.Collections.IDictionary]$Context)

    $invalid = @{ ok = $false; error = 'schedule_invalid_fields' }
    if ($null -ne $Requested -and $Requested -isnot [System.Collections.IDictionary]) { return $invalid }
    $values = @{}
    if ($Requested) {
        foreach ($name in $Requested.Keys) {
            if ($name -notin $Context.template.Fields -or $Requested[$name] -isnot [string] -or $values.ContainsKey($name)) { return $invalid }
            $values[$name] = $Requested[$name]
        }
    }
    $visible = @()
    foreach ($field in $Context.fields) {
        $value = [string]$values[$field.name]
        if (($field.required -and [string]::IsNullOrWhiteSpace($value)) -or
            ($field.maxLength -and (Get-TextElementCount -Text $value) -gt $field.maxLength)) { return $invalid }
        $visible += @{
            name = $field.name
            label = $field.label
            sensitive = $field.sensitive
            value = if ($field.sensitive) { $null } else { $value }
        }
    }
    return @{ ok = $true; values = $values; fields = $visible }
}

function Invoke-WebTemplateScheduleReview {
    param([long]$Actor, [System.Collections.IDictionary]$Arguments)

    $operation = [string](Get-JsonProp $Arguments 'operation')
    if (-not $operation) { $operation = 'create' }
    $invalid = @{ ok = $false; error = 'schedule_invalid' }
    if ($operation -cnotin @('create', 'edit', 'copy', 'cancel')) { return $invalid }
    if ($operation -ne 'cancel' -and ((Get-Setting 'MaintenanceMode') -or (Test-MaintenanceWindowActive))) {
        return @{ ok = $false; error = 'schedule_maintenance' }
    }
    $original = $null
    $id = [string](Get-JsonProp $Arguments 'scheduleId')
    $revision = [string](Get-JsonProp $Arguments 'revision')
    if ($operation -ne 'create') {
        $current = Get-WebTemplateScheduleOriginal -Actor $Actor -Id $id -Revision $revision
        if (-not $current.ok) { return $current }
        $original = $current.entry
        if ($operation -eq 'edit' -and -not (Test-WebScheduledShowAccess -ScheduleEntry $original)) {
            return @{ ok = $false; error = 'forbidden' }
        }
    }

    if ($operation -eq 'cancel') {
        $entry = $original
        $materials = if (Get-JsonProp $entry 'AnchorMaterialId') { @(Get-CachedMaterialSchedule) } else { @() }
        $context = @{ conflicts = @(); fingerprint = '' }
        $visible = @()
        $anchorName = ''
    }
    else {
        $clock = Get-SystemClockStatus
        if (-not $clock.Success) { return @{ ok = $false; error = 'schedule_clock' } }
        $key = [string](Get-JsonProp $Arguments 'key')
        $recurrence = [string](Get-JsonProp $Arguments 'recurrence')
        $requestedValues = Get-JsonProp $Arguments 'variables'
        $until = Get-JsonProp $Arguments 'recurrenceUntil'
        if ($original) {
            $key = [string]$original.TemplateKey
            $recurrence = [string]$original.Recurrence
            $requestedValues = Get-JsonProp $original 'Values'
            if ($null -eq $until) { $until = Get-JsonProp $original 'RecurrenceUntil' }
        }
        if ($recurrence -cnotin @('once', 'daily', 'weekly')) { return $invalid }
        $moment = Get-WebTemplateScheduleMoment -Arguments $Arguments -Original $original -Recurrence $recurrence -Now $clock.Now
        if (-not $moment.ok) { return $moment }
        if ($until) {
            $endDate = [datetime]::MinValue
            if ($recurrence -eq 'once' -or -not [datetime]::TryParseExact([string]$until, 'yyyy-MM-dd',
                    [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$endDate) -or
                $endDate.Date -lt $moment.at.Date) { return @{ ok = $false; error = 'schedule_invalid_end' } }
        }
        $excludeId = if ($operation -eq 'edit') { $id } else { '' }
        $context = Get-WebTemplateScheduleContext -Actor $Actor -Key $key -ScheduledAt $moment.at -ExcludeId $excludeId -MaterialItems $moment.items
        if (-not $context.ok) { return $context }
        $validated = Get-WebTemplateScheduleFieldInput -Requested $requestedValues -Context $context
        if (-not $validated.ok) { return $validated }
        $entry = New-ScheduledShowEvent -TemplateKey $context.template.Key -Layer ([int]$context.template.Layer) -Values $validated.values `
            -ScheduledAt $moment.at -Recurrence $recurrence -RecurrenceUntil ([string]$until) -ChatId $Actor -UserId $Actor `
            -AnchorMaterialId $moment.materialId -AnchorOffsetSeconds $moment.offset
        $entry.Source = 'web'
        $materials = @($moment.items | Where-Object { $null -ne $_ })
        $visible = $validated.fields
        $anchorName = $moment.materialName
    }

    $review = New-WebAirReview -Actor $Actor -Fingerprint $context.fingerprint -Reviews $script:WebTemplateScheduleReviews
    $script:WebTemplateScheduleReviews[$Actor].Plan = @{
        entry = $entry; operation = $operation; id = $id; revision = $revision; anchorName = $anchorName
    }
    $data = ConvertTo-WebTemplateScheduleItem -Entry $entry -MaterialItems $materials
    foreach ($itemKey in 'id', 'revision', 'canManage') { $data.Remove($itemKey) }
    $data.review = $review
    $data.operation = $operation
    $data.anchorMaterialName = $anchorName
    $data.conflicts = @($context.conflicts | Select-Object -First 12)
    $data.conflictCount = $context.conflicts.Count
    $data.fields = $visible
    return @{ ok = $true; data = $data }
}

function Invoke-WebTemplateScheduleConfirmation {
    param([long]$Actor, [string]$Review, [long]$Deadline)

    $stale = @{ ok = $false; error = 'schedule_stale' }
    if (-not $Review) { return $stale }
    $pending = Use-WebAirReview -Actor $Actor -Token $Review -Reviews $script:WebTemplateScheduleReviews
    if (-not $pending) { return $stale }
    $plan = $pending.Plan
    $entry = $plan.entry
    if ($plan.operation -ne 'create') {
        $current = Get-WebTemplateScheduleOriginal -Actor $Actor -Id $plan.id -Revision $plan.revision
        if (-not $current.ok) { return $current }
        if ($plan.operation -eq 'edit' -and -not (Test-WebScheduledShowAccess -ScheduleEntry $current.entry)) {
            return @{ ok = $false; error = 'forbidden' }
        }
    }
    if ($plan.operation -ne 'cancel') {
        if ((Get-Setting 'MaintenanceMode') -or (Test-MaintenanceWindowActive)) {
            return @{ ok = $false; error = 'schedule_maintenance' }
        }
        $clock = Get-SystemClockStatus
        if (-not $clock.Success) { return @{ ok = $false; error = 'schedule_clock' } }
        $at = [datetimeoffset]$entry.ScheduledAt
        if ($at -le $clock.Now -or $entry.TimeZoneId -cne $clock.TimeZoneId) { return $stale }
        $materials = $null
        if ($entry.AnchorMaterialId) {
            $anchor = Get-WebScheduleMaterialAnchor -MaterialId $entry.AnchorMaterialId -OffsetSeconds $entry.AnchorOffsetSeconds -Now $clock.Now
            if (-not $anchor.ok) { return $anchor }
            if ($anchor.at -ne $at -or $anchor.name -cne $plan.anchorName) {
                return @{ ok = $false; error = 'schedule_material_stale' }
            }
            $materials = $anchor.items
        }
        $excludeId = if ($plan.operation -eq 'edit') { $plan.id } else { '' }
        $context = Get-WebTemplateScheduleContext -Actor $Actor -Key $entry.TemplateKey -ScheduledAt $at -ExcludeId $excludeId -MaterialItems $materials
        if (-not $context.ok -and $context.error -eq 'forbidden') { return $context }
        if (-not $context.ok -or $context.fingerprint -cne $pending.Fingerprint) { return $stale }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    if ($plan.operation -in 'edit', 'cancel') {
        $result = Invoke-ScheduledShowEventMutation -Operation $plan.operation -EventId $plan.id -ExpectedRevision $plan.revision -Plan $entry
        if (-not $result.ok) { return $result }
    }
    elseif (-not (Add-ScheduledShowEvent -ScheduleEntry $entry)) {
        return @{ ok = $false; error = 'schedule_save_failed' }
    }
    $label = switch ($plan.operation) { 'edit' { T 'sch.edit' } 'cancel' { T 'sch.delete' } default { T 'sch.create' } }
    Add-AuditEntry (T 'sch.scheduledAudit' $label $entry.TemplateKey $entry.Recurrence (Format-UserAuditActor -UserId $Actor))
    return @{ ok = $true; data = Get-WebTemplateSchedulePage -Page 0 -Actor $Actor }
}

function Invoke-WebTemplateSchedule {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    switch ([string](Get-JsonProp $Arguments 'action')) {
        { $_ -in 'list', 'materials' } {
            $page = 0
            $rawPage = Get-JsonProp $Arguments 'page'
            if ($null -ne $rawPage -and -not [int]::TryParse([string]$rawPage, [ref]$page)) {
                return @{ ok = $false; error = 'schedule_invalid' }
            }
            if ($_ -eq 'materials') { return Get-WebScheduleMaterialPage -Page $page }
            return @{ ok = $true; data = Get-WebTemplateSchedulePage -Page $page -Actor $actor }
        }
        'review' { return Invoke-WebTemplateScheduleReview -Actor $actor -Arguments $Arguments }
        'confirm' {
            return Invoke-WebTemplateScheduleConfirmation -Actor $actor -Review ([string](Get-JsonProp $Arguments 'review')) -Deadline $Deadline
        }
        default { return @{ ok = $false; error = 'schedule_invalid' } }
    }
}


function Get-WebScheduleHoldSnapshot {
    $paused = Get-Setting 'SchedulePaused'
    $maintenance = Get-Setting 'MaintenanceMode'
    if ($paused -isnot [bool] -or $maintenance -isnot [bool]) { return $null }

    # This is the template queue gated by SchedulePaused. In particular, no
    # material-feed lookup or scheduler tick is needed to review that gate.
    $revisions = @(Get-UpcomingScheduleEvents | ForEach-Object { Get-ScheduledShowEventRevision -ScheduleEntry $_ } | Sort-Object)
    return @{
        paused = $paused; maintenance = $maintenance; pendingAppointments = $revisions.Count
        fingerprint = ConvertTo-Json -InputObject @($paused, $maintenance, $revisions) -Compress
    }
}

function New-WebScheduleHoldReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = Get-WebAdminSettingActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    $desired = Get-JsonProp $Arguments 'paused'
    if ($desired -isnot [bool]) { return @{ ok = $false; error = 'schedule_hold_invalid' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $state = Get-WebScheduleHoldSnapshot
    if (-not $state) { return @{ ok = $false; error = 'schedule_hold_unavailable' } }
    if ($desired -eq $state.paused) { return @{ ok = $false; error = 'schedule_hold_stale' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }

    $token = New-WebAirReview -Actor $actor -Fingerprint $state.fingerprint -Reviews $script:WebScheduleHoldReviews
    $script:WebScheduleHoldReviews[$actor].Paused = $desired
    return @{ ok = $true; data = @{
        review = $token; currentlyPaused = $state.paused; paused = $desired
        pendingAppointments = $state.pendingAppointments; maintenance = $state.maintenance
    } }
}

function Complete-WebScheduleHoldReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = Get-WebAdminSettingActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $stale = @{ ok = $false; error = 'schedule_hold_stale' }
    $reviewed = Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebScheduleHoldReviews
    if (-not $reviewed) { return $stale }
    $state = Get-WebScheduleHoldSnapshot
    if (-not $state -or $reviewed.Fingerprint -cne $state.fingerprint -or $reviewed.Paused -eq $state.paused) { return $stale }

    $secondsLeft = ($reviewed.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
    if ($secondsLeft -le 0) { return $stale }
    $writeDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($secondsLeft * [Diagnostics.Stopwatch]::Frequency)
    if ($Deadline -gt 0) { $writeDeadline = [math]::Min($Deadline, $writeDeadline) }
    $expected = @{ SchedulePaused = $state.paused; MaintenanceMode = $state.maintenance }
    $patch = @(@{ Name = 'SchedulePaused'; From = $state.paused; To = [bool]$reviewed.Paused })
    if (-not (Set-ImportedSettings -Changes $patch -ReviewedExpected $expected -Deadline $writeDeadline)) {
        if ($script:LastConfigSaveConflict) { return $stale }
        return @{ ok = $false; error = 'schedule_hold_save_failed' }
    }
    Add-AuditEntry (T 'kb.settingAudit' 'SchedulePaused' $reviewed.Paused (Format-UserAuditActor -UserId $actor)) | Out-Null
    return @{ ok = $true; data = @{
        paused = [bool]$reviewed.Paused; pendingAppointments = $state.pendingAppointments; maintenance = $state.maintenance
    } }
}
