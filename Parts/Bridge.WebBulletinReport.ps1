function Format-WebBulletinReportLabel {
    param([string]$Text)
    if (-not $Text -or $Text -match '[/\\]|(?i)\b(?:file|smb):|[A-Za-z]:') { return '' }
    return Format-WebShiftHistoryField -Text $Text -MaximumLength 100
}

function Get-WebBulletinReportOperator {
    param([string]$UserId)
    $operatorName = Get-AuditOperatorName -UserId $UserId
    if ($operatorName -eq $UserId) { return '' }
    return Format-WebBulletinReportLabel -Text $operatorName
}

function Format-WebBulletinReportTime {
    param($Timestamp)
    if ($null -eq $Timestamp) { return '' }
    return ([datetimeoffset]([datetime]$Timestamp)).ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-WebBulletinReportExport {
    param([hashtable]$Report, [object[]]$Runs)
    $selected = @($Runs | Select-Object -Last 100)
    $safe = @(foreach ($run in $selected) {
            [pscustomobject]@{
                Name = Format-WebBulletinReportLabel -Text ([string]$run.Name)
                OperatorName = Get-WebBulletinReportOperator -UserId ([string]$run.UserId)
                Rows = [int]$run.Rows
                StartedAt = $run.StartedAt
                EndedAt = $run.EndedAt
                DurationMs = [long]$run.DurationMs
                Kind = if ($run.Kind -eq 'scheduled') { 'scheduled' } else { '' }
            }
        })
    $partialExport = $selected.Count -lt $Runs.Count
    $notes = @(
        if ($Report.Truncated) { Get-ReportTruncationNote -Truncated $true }
        if ($partialExport) { T 'rep.bulletinWebExportCap' $selected.Count $Runs.Count }
    )
    $export = @{
        Label = $Report.Label
        Runs = $safe
        Rows = [int]$(if ($safe.Count -gt 0) { ($safe | Measure-Object -Property Rows -Sum).Sum } else { 0 })
        Operators = @($selected | Group-Object -Property UserId).Count
    }
    return @{ html = ConvertTo-MojazReportHtml -Data $export -Note ($notes -join ' ') -UseProjectedOperatorNames
        count = $safe.Count; total = $Runs.Count; truncated = ($Report.Truncated -or $partialExport) }
}

function Get-WebBulletinReport {
    param([System.Collections.IDictionary]$Arguments)
    $request = Get-WebReportScope -Arguments $Arguments
    if (-not $request.ok) { return $request }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin '', 'list', 'export') { return @{ ok = $false; error = 'report_invalid' } }
    $page = 0
    $rawPage = Get-JsonProp $Arguments 'page'
    if ($null -ne $rawPage -and -not [int]::TryParse([string]$rawPage, [ref]$page)) {
        return @{ ok = $false; error = 'report_invalid' }
    }
    $report = Get-MojazReportData -Period $request.period -OnlyUserId $request.onlyUser
    $runs = @($report.Runs)
    if ($action -ceq 'export') { return @{ ok = $true; data = Get-WebBulletinReportExport -Report $report -Runs $runs } }

    $window = Get-BridgePageWindow -ItemCount $runs.Count -Page $page
    $items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $run = $runs[$runs.Count - $index - 1]
            [ordered]@{
                name = Format-WebBulletinReportLabel -Text ([string]$run.Name)
                operatorName = Get-WebBulletinReportOperator -UserId ([string]$run.UserId)
                started = Format-WebBulletinReportTime -Timestamp $run.StartedAt
                ended = Format-WebBulletinReportTime -Timestamp $run.EndedAt
                duration = $(if ($run.EndedAt) { Get-MojazRunDuration -Run $run } else { '' })
                rows = [int]$run.Rows
                scheduled = $run.Kind -eq 'scheduled'
            }
        })
    return @{ ok = $true; data = [ordered]@{
            period = $request.period; scope = $request.scope; total = $runs.Count; rows = [int]$report.Rows
            operators = [int]$report.Operators; scheduled = [int]$report.Scheduled; truncated = [bool]$report.Truncated
            page = $window.Page; pageCount = $window.PageCount; items = $items
        } }
}
