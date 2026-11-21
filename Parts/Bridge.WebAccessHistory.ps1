#requires -Version 7

function Get-WebAccessHistoryPage {
    param([System.Collections.IDictionary]$Arguments)
    if (-not (Get-WebTelegramAccessAdministrator -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $page = 0
    $pageSize = 20
    $requestedPage = Get-JsonProp $Arguments 'page'
    $requestedSize = Get-JsonProp $Arguments 'pageSize'
    $decision = [string](Get-JsonProp $Arguments 'decision')
    if (-not $decision) { $decision = 'all' }
    if (($null -ne $requestedPage -and -not [int]::TryParse([string]$requestedPage, [ref]$page)) -or $page -lt 0 -or
        ($null -ne $requestedSize -and -not [int]::TryParse([string]$requestedSize, [ref]$pageSize)) -or
        $pageSize -lt 1 -or $pageSize -gt 40 -or $decision -cnotin 'all', 'approved', 'rejected') {
        return @{ ok = $false; error = 'bad_request' }
    }

    $history = Get-AccessHistoryData -DecisionsOnly
    $visible = @(foreach ($row in $history.Rows) {
            if ($decision -cne 'all' -and $row.State -cne $decision) { continue }
            $subject = 0L
            if (-not [long]::TryParse($row.UserId, [ref]$subject) -or $subject -eq 0 -or (Test-WebOnlyUserId -UserId $subject)) { continue }
            $decidedAt = ConvertTo-AirStatusWidgetEpoch $row.DecidedAt
            if ($decidedAt -le 0) { continue }
            $requestedAt = ConvertTo-AirStatusWidgetEpoch $row.RequestedAt
            $decider = 0L
            $hasDecider = [long]::TryParse($row.DecidedByUserId, [ref]$decider) -and $decider -gt 0
            [ordered]@{
                userId = $subject.ToString([Globalization.CultureInfo]::InvariantCulture)
                decision = $row.State
                decidedAt = $decidedAt
                decidedByUserId = if ($hasDecider) { $decider.ToString([Globalization.CultureInfo]::InvariantCulture) }
                requestedAt = if ($requestedAt -gt 0) { $requestedAt }
            }
        })
    $window = Get-BridgePageWindow -ItemCount $visible.Count -Page $page -PageSize $pageSize
    $items = @(if ($visible.Count -gt 0) { $visible[$window.StartIndex..$window.EndIndex] })
    return @{ ok = $true; data = @{
            items = $items; page = $window.Page; pageSize = $pageSize; total = $visible.Count; truncated = $history.Truncated
        } }
}
