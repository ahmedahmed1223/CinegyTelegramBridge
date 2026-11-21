function Get-WebProgrammeNowNext {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $ticks = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($Deadline -gt 0 -and $ticks -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    if ($ticks -lt $script:WebLayerComparisonNextProbe) { return @{ ok = $false; error = 'layer_comparison_busy' } }

    try {
        # An explicit status read can reuse the rundown already obtained by the schedule screen.
        # A stale or incomplete cache never determines what Cinegy has cued.
        $cachedItems = @()
        if ($script:MaterialScheduleCacheAt -is [datetimeoffset]) {
            $cacheAge = ([datetimeoffset]::Now - $script:MaterialScheduleCacheAt).TotalSeconds
            if ($cacheAge -ge 0 -and $cacheAge -le 5) { $cachedItems = $script:MaterialScheduleCache }
        }
        $snapshot = Get-AirProgrammeNowNextData -TimeoutSec 1 -CachedItems $cachedItems -Deadline $Deadline
    }
    finally {
        $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }

    $project = {
        param($Programme)
        if (-not $Programme) { return $null }
        $item = $Programme.Item
        return @{
            listed = [bool]$item
            label = if ($item) { Format-WebTemplateReportLabel -Text ([string]$item.Name) } else { '' }
            startsAtMs = if ($item -and $item.ScheduledAt -gt [datetimeoffset]::MinValue) { $item.ScheduledAt.ToUnixTimeMilliseconds() } else { $null }
            durationSeconds = if ($item -and $item.Duration -gt [timespan]::Zero) { $item.Duration.TotalSeconds } else { $null }
            remainingSeconds = if ($Programme.Remaining) { $Programme.Remaining.TotalSeconds } else { $null }
        }
    }
    return @{ ok = $true; data = @{
            checkedAtMs = [datetimeoffset]::Now.ToUnixTimeMilliseconds()
            statusAvailable = $snapshot.StatusAvailable
            scheduleAvailable = $snapshot.ScheduleAvailable
            current = & $project $snapshot.Current
            cued = & $project $snapshot.Cued
        } }
}

function Get-WebScheduleMaterialSnapshot {
    if (-not (Get-Setting 'EnableMaterialSchedule')) {
        return @{ ok = $false; error = 'schedule_material_disabled' }
    }

    $timeout = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1
    $result = Get-AirMaterialSchedule -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
    if (-not (Get-JsonProp $result 'Success')) {
        return @{ ok = $false; error = 'schedule_material_unavailable' }
    }
    $items = @(Get-JsonProp $result 'Items' | Where-Object { $null -ne $_ })
    $script:MaterialScheduleCache = $items
    $script:MaterialScheduleCacheAt = [datetimeoffset]::Now
    return @{ ok = $true; items = $items }
}

function Get-WebScheduleMaterialPage {
    param([int]$Page)

    $snapshot = Get-WebScheduleMaterialSnapshot
    if (-not $snapshot.ok) { return $snapshot }
    $timeout = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1
    $status = Get-AirVideoStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
    $activeId = ([string](Get-JsonProp $status 'ActiveId')).Trim('{', '}')
    $now = [datetimeoffset]::Now
    $window = Get-BridgePageWindow -ItemCount $snapshot.items.Count -Page $Page -PageSize 12
    $items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $entry = $snapshot.items[$index]
            $id = ([string](Get-JsonProp $entry 'Id')).Trim('{', '}')
            $name = [string](Get-JsonProp $entry 'Name')
            $start = ([datetimeoffset](Get-JsonProp $entry 'ScheduledAt')).ToLocalTime()
            $duration = [timespan](Get-JsonProp $entry 'Duration')
            @{
                id = $id
                name = if ($name.Length -gt 160) { $name.Substring(0, (Get-SafeTextPrefixLength -Text $name -MaximumCodeUnits 160)) } else { $name }
                startsAtMs = $start.ToUnixTimeMilliseconds()
                stationTime = $start.ToString('yyyy-MM-dd HH:mm zzz', [Globalization.CultureInfo]::InvariantCulture)
                durationSeconds = $duration.TotalSeconds
                active = [bool]($activeId -and $id -eq $activeId)
                canAnchor = [bool]($id -and ($start + $duration) -gt $now -and $start.AddSeconds(300) -gt $now)
            }
        })
    return @{ ok = $true; data = @{
            items = $items
            page = $window.Page
            pageCount = $window.PageCount
            total = $snapshot.items.Count
            activeKnown = [bool](Get-JsonProp $status 'Success')
            stationTimeZone = [TimeZoneInfo]::Local.Id
        } }
}

function Get-WebScheduleMaterialAnchor {
    param([string]$MaterialId, [int]$OffsetSeconds, [datetimeoffset]$Now)

    if ($MaterialId.Length -gt 80 -or $OffsetSeconds -notin 0, 30, 60, 300) {
        return @{ ok = $false; error = 'schedule_material_invalid' }
    }
    $snapshot = Get-WebScheduleMaterialSnapshot
    if (-not $snapshot.ok) { return $snapshot }
    $id = $MaterialId.Trim('{', '}')
    $matching = @($snapshot.items | Where-Object {
            ([string](Get-JsonProp $_ 'Id')).Trim('{', '}') -eq $id
        })
    if (-not $id -or $matching.Count -ne 1) { return @{ ok = $false; error = 'schedule_material_stale' } }
    $choice = Get-ScheduleAnchorChoices -Items $matching | Select-Object -First 1
    if (-not $choice) { return @{ ok = $false; error = 'schedule_material_stale' } }

    $entry = @{ ScheduledAt = $choice.ScheduledAt; AnchorMaterialId = $id; AnchorOffsetSeconds = $OffsetSeconds }
    $at = (Resolve-ScheduleAnchorTime -ScheduleEntry $entry -Items $matching).ToLocalTime()
    if ($at -le $Now) { return @{ ok = $false; error = 'schedule_material_stale' } }
    $name = [string]$choice.Name
    return @{
        ok = $true
        id = $id
        name = if ($name.Length -gt 160) { $name.Substring(0, (Get-SafeTextPrefixLength -Text $name -MaximumCodeUnits 160)) } else { $name }
        at = $at
        items = $snapshot.items
    }
}
