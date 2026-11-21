function Format-WebTickerReportTime {
    param($Timestamp)
    if ($null -eq $Timestamp) { return '' }
    return ([datetimeoffset]([datetime]$Timestamp)).ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-WebTickerDayTally {
    param($Tally)
    $breakdown = [string](Get-JsonProp $Tally 'Breakdown')
    $display = if ($breakdown) { $breakdown } else { [string](Get-JsonProp $Tally 'Single') }
    $pieces = @($display -split ' · ' | Where-Object {
            $_ -and $_ -notmatch '[/\\]|(?i)\b(?:file|smb):|[A-Za-z]:|^\s*\d+(?:\s+\d+)?\s*$'
        })
    return Format-WebShiftHistoryField -Text ($pieces -join ' · ') -MaximumLength 160
}

function Get-WebTickerReport {
    param([System.Collections.IDictionary]$Arguments)
    $request = Get-WebReportScope -Arguments $Arguments
    if (-not $request.ok) { return $request }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin '', 'list', 'export') { return @{ ok = $false; error = 'report_invalid' } }
    $report = Get-NewsReportDays -Period $request.period -OnlyUserId $request.onlyUser
    # Only the label projection changes. The formatter and JSON table both
    # inherit the audited days, counts and edit order from the Bot reader.
    $days = @(foreach ($day in @($report.Days)) {
            [ordered]@{
                Date = $day.Date; Publishes = [int]$day.Publishes; Items = [int]$day.Items
                Counts = @($day.Counts); First = $day.First; Last = $day.Last
                Tally = @{ Single = Get-WebTickerDayTally -Tally $day.Tally; Breakdown = '' }
            }
        })
    if ($action -ceq 'export') {
        $report.Days = $days
        return @{ ok = $true; data = @{
                html = ConvertTo-NewsReportHtml -Data $report
                days = $days.Count; publishes = [int]$report.Publishes; truncated = [bool]$report.Truncated
            } }
    }
    return @{ ok = $true; data = [ordered]@{
            period = $request.period; scope = $request.scope
            publishes = [int]$report.Publishes; items = [int]$report.Items; silentDays = [int]$report.SilentDays
            lastPublishedAt = Format-WebTickerReportTime -Timestamp $report.LastPublishedAt
            truncated = [bool]$report.Truncated
            days = @(foreach ($day in $days) {
                    [ordered]@{
                        date = ([datetime]$day.Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                        publishes = $day.Publishes; items = $day.Items
                        first = Format-WebTickerReportTime -Timestamp $day.First
                        last = Format-WebTickerReportTime -Timestamp $day.Last
                        range = Get-NewsCountRange -Counts $day.Counts
                        edits = Get-NewsEditTrail -Counts $day.Counts
                        operators = $day.Tally.Single
                    }
                })
        } }
}
