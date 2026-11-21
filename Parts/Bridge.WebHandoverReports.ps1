function Get-WebHandoverTimezoneStamp {
    param($Timestamp)
    if ($null -eq $Timestamp) { return '' }
    return ([datetimeoffset]([datetime]$Timestamp)).ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-WebWeeklyReport {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $report = Get-WeeklyReportData
    $settings = @($report.ChangedSettings | Sort-Object)
    $idle = @($report.IdleTemplates)
    return @{ ok = $true; data = [ordered]@{
            from = Get-WebHandoverTimezoneStamp -Timestamp $report.From
            through = Get-WebHandoverTimezoneStamp -Timestamp $report.To
            tickerPublishes = [int]$report.TickerPublishes
            tickerLast = Get-WebHandoverTimezoneStamp -Timestamp $report.TickerLastAt
            urgentRuns = [int]$report.UrgentRunsStarted
            urgentStories = [int]$report.UrgentStoriesPlayed
            nearLimit = [bool]$report.NearLimit
            peakScreen = Format-WebTemplateReportLabel -Text ([string]$report.PeakScreen)
            peakPercent = [int]$report.PeakPercent
            idleCount = $idle.Count
            idle = @($idle | Select-Object -First 5 | ForEach-Object { Format-WebTemplateReportLabel -Text ([string]$_) } | Where-Object { $_ })
            repeatCounts = @($report.Repeats | Select-Object -First 5 | ForEach-Object { [int]$_.Count })
            changedCount = $settings.Count
            changed = @($settings | Where-Object { [string]$_ -cmatch '^[A-Za-z][A-Za-z0-9_.-]{0,79}$' } | Select-Object -First 12)
            truncated = [bool]$report.Truncated
        } }
}

function Get-WebShiftHandoverReport {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $hours = Get-SettingInt 'MissedEventsHours' 1
    $window = Get-MissedEventsWindow -Hours $hours
    $records = @($window.Records)
    $air = @($records | Where-Object { $_.Action -in 'SHOW', 'HIDE', 'EXIT' })
    $shows = @($air | Where-Object { $_.Action -eq 'SHOW' -and $_.Target })
    $removals = @($air | Where-Object { $_.Action -in 'HIDE', 'EXIT' })
    $failures = @($records | Where-Object { $_.Result -eq 'failed' })
    $blocked = @($records | Where-Object { $_.Result -eq 'blocked' })
    $notable = @($records | Where-Object { -not $_.Action -and $_.Message -match '📰|⚙️|👤|🔓|🚨|♻️' })
    $showGroups = @($shows | Group-Object -Property Target | Sort-Object Count -Descending)
    $layerNumbers = @($script:OnAir.Keys | Sort-Object)
    $lastRemoval = $removals | Select-Object -Last 1
    return @{ ok = $true; data = [ordered]@{
            hours = $hours; truncated = [bool]$window.Truncated
            connection = Get-OperatorConnectionSummary
            activeCount = $layerNumbers.Count
            active = @(foreach ($layer in @($layerNumbers | Select-Object -First 20)) {
                    @{ layer = [int]$layer; name = Format-WebTemplateReportLabel -Text ([string](Get-JsonProp $script:OnAir[$layer] 'Key')) }
                })
            showCount = $shows.Count; hiddenGroups = [math]::Max(0, $showGroups.Count - 8)
            shows = @(foreach ($group in @($showGroups | Select-Object -First 8)) {
                    @{
                        name = Format-WebTemplateReportLabel -Text ([string]$group.Name); count = $group.Count
                        last = Get-WebHandoverTimezoneStamp -Timestamp $group.Group[-1].When
                        operators = Get-WebTickerDayTally -Tally (Get-OperatorTally -Records @($group.Group))
                    }
                })
            removalCount = $removals.Count
            lastRemoval = Get-WebHandoverTimezoneStamp -Timestamp (Get-JsonProp $lastRemoval 'When')
            failureCount = $failures.Count; blockedCount = $blocked.Count; notableCount = $notable.Count
            recentFailures = @(foreach ($failure in @($failures | Select-Object -Last 3 | Sort-Object When -Descending)) {
                    @{
                        when = Get-WebHandoverTimezoneStamp -Timestamp $failure.When
                        action = $(if ($failure.Action -in 'SHOW', 'HIDE', 'EXIT') { [string]$failure.Action } else { '' })
                        name = Format-WebTemplateReportLabel -Text ([string]$failure.Target)
                    }
                })
        } }
}
