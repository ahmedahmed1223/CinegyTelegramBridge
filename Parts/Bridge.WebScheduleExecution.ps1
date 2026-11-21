function Get-WebScheduleExecutionReason {
    param([string]$Reason)

    # The file can contain exception details and local paths. The web screen
    # describes known outcomes without repeating engine output or row values.
    switch ($Reason) {
        'not_authorized' { return 'not_authorized' }
        'playback_target_changed' { return 'playback_target_changed' }
        'playback_start_failed' { return 'playback_start_failed' }
        'draft handed over' { return 'draft_handed_over' }
        default { return 'execution_failed' }
    }
}

function ConvertTo-WebScheduleExecutionItem {
    param([Parameter(Mandatory)]$Record)

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $ranAt = [datetimeoffset]::MinValue
    $dueAt = [datetimeoffset]::MinValue
    $ranKnown = [datetimeoffset]::TryParse([string]$Record.Timestamp, $culture, [Globalization.DateTimeStyles]::None, [ref]$ranAt)
    $dueKnown = [datetimeoffset]::TryParse([string]$Record.ScheduledAt, $culture, [Globalization.DateTimeStyles]::None, [ref]$dueAt)
    $label = Protect-SensitiveText ([string]$Record.TemplateKey)
    $label = [regex]::Replace($label, '(?i)(?:https?|file)://[^\s"''<>]+', '[link]')
    $label = [regex]::Replace($label,
        '(?i)\b(token|secret|password|passphrase|api[-_]?key|access[-_]?key)(\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|[^\s&;,]+)', '$1$2***')
    $label = ([regex]::Replace($label, '[\p{Cc}\p{Cf}]', ' ')).Trim()
    if ($label.Length -gt 120) {
        $label = $label.Substring(0, (Get-SafeTextPrefixLength -Text $label -MaximumCodeUnits 120))
    }
    return [ordered]@{
        kind = [string]$Record.Kind
        label = $label
        layer = [int]$Record.Layer
        result = [string]$Record.Result
        attempt = [int]$Record.Attempt
        durationMs = [long]$Record.DurationMs
        ranAtMs = if ($ranKnown) { $ranAt.ToUnixTimeMilliseconds() } else { $null }
        dueAtMs = if ($dueKnown) { $dueAt.ToUnixTimeMilliseconds() } else { $null }
        ranAtStation = if ($ranKnown) { $ranAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz', $culture) } else { '' }
        dueAtStation = if ($dueKnown) { $dueAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz', $culture) } else { '' }
        delaySeconds = if ($ranKnown -and $dueKnown) { [long][math]::Round(($ranAt - $dueAt).TotalSeconds) } else { $null }
        reason = if ([string]$Record.Result -eq 'failed') { Get-WebScheduleExecutionReason -Reason $Record.Error } else { '' }
    }
}

function Get-WebScheduleExecutionPage {
    param([System.Collections.IDictionary]$Arguments)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }

    $kind = [string](Get-JsonProp $Arguments 'kind')
    $result = [string](Get-JsonProp $Arguments 'result')
    if (-not $kind) { $kind = 'all' }
    if (-not $result) { $result = 'all' }
    $page = 0
    $rawPage = Get-JsonProp $Arguments 'page'
    if ($kind -cnotin @('all', 'show', 'mojaz', 'news') -or $result -cnotin @('all', 'success', 'failed') -or
        ($null -ne $rawPage -and -not [int]::TryParse([string]$rawPage, [ref]$page))) {
        return @{ ok = $false; error = 'schedule_execution_invalid' }
    }

    $readLimit = 120
    $recent = @(Get-ScheduleExecutionHistory -TailLines $readLimit)
    $records = @($recent | Where-Object {
            [string]$_.Kind -in 'show', 'mojaz', 'news' -and [string]$_.Result -in 'success', 'failed' -and
            ($kind -eq 'all' -or [string]$_.Kind -eq $kind) -and ($result -eq 'all' -or [string]$_.Result -eq $result)
        })
    $window = Get-BridgePageWindow -ItemCount $records.Count -Page $page -PageSize 12
    $items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            ConvertTo-WebScheduleExecutionItem -Record $records[$index]
        })
    return @{ ok = $true; data = @{
            items = $items
            page = $window.Page
            pageCount = $window.PageCount
            total = $records.Count
            readLimit = $readLimit
            stationTimeZone = [TimeZoneInfo]::Local.Id
        } }
}
