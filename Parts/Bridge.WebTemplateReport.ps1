function Format-WebTemplateReportLabel {
    param([string]$Text)
    if (-not $Text -or $Text -match '[/\\]|(?i)\b(?:file|smb):|[A-Za-z]:') { return '' }
    return Format-WebShiftHistoryField -Text $Text -MaximumLength 100
}

function ConvertTo-WebTemplateReportSession {
    param($Session)
    $userId = [string]$Session.UserId
    $who = Get-AuditOperatorName -UserId $userId
    return [ordered]@{
        Target = Format-WebTemplateReportLabel -Text ([string]$Session.Target)
        OperatorName = $(if ($who -ne $userId) { Format-WebTemplateReportLabel -Text $who } else { '' })
        Layer = [int]$Session.Layer
        StartedAt = $Session.StartedAt
        EndedAt = $Session.EndedAt
        EndedBy = [string]$Session.EndedBy
    }
}

function Format-WebTemplateReportTime {
    param($Timestamp)
    if ($null -eq $Timestamp) { return '' }
    return ([datetimeoffset]([datetime]$Timestamp)).ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-WebTemplateReportExport {
    param([hashtable]$Report, [object[]]$Sessions)
    $selected = @($Sessions | Select-Object -Last 100)
    $partialExport = $selected.Count -lt $Sessions.Count
    $notes = @(
        if ($Report.Truncated) { Get-ReportTruncationNote -Truncated $true }
        if ($partialExport) { T 'rep.templateWebExportCap' $selected.Count $Sessions.Count }
    )
    $projection = @{
        Label = $Report.Label
        Sessions = @($selected | ForEach-Object { ConvertTo-WebTemplateReportSession -Session $_ })
        Operators = @($selected | Group-Object -Property UserId).Count
    }
    return @{
        html = ConvertTo-BannerReportHtml -Data $projection -Note ($notes -join ' ') -SummaryOnly
        count = $selected.Count; total = $Sessions.Count; truncated = ($Report.Truncated -or $partialExport)
    }
}

function Get-WebTemplateReport {
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
    $report = Get-BannerReportData -Period $request.period -OnlyUserId $request.onlyUser
    $sessions = @($report.Sessions)
    if ($action -ceq 'export') { return @{ ok = $true; data = Get-WebTemplateReportExport -Report $report -Sessions $sessions } }

    $window = Get-BridgePageWindow -ItemCount $sessions.Count -Page $page
    $items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $session = ConvertTo-WebTemplateReportSession -Session $sessions[$sessions.Count - $index - 1]
            [ordered]@{
                name = $session.Target; operatorName = $session.OperatorName; layer = $session.Layer
                started = Format-WebTemplateReportTime -Timestamp $session.StartedAt
                ended = Format-WebTemplateReportTime -Timestamp $session.EndedAt
                duration = $(if ($session.EndedAt) { Get-BannerSessionDuration -Session $session } else { '' })
                endedBy = $session.EndedBy
            }
        })
    return @{ ok = $true; data = [ordered]@{
            period = $request.period; scope = $request.scope; total = $sessions.Count; operators = [int]$report.Operators
            withoutEnd = @($sessions | Where-Object { -not $_.EndedAt }).Count
            truncated = [bool]$report.Truncated; page = $window.Page; pageCount = $window.PageCount; items = $items
        } }
}
