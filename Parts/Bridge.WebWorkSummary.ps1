#requires -Version 7

function Get-WebReportScope {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $isAdmin = Test-Admin -ChatId $actor -UserId $actor
    $scope = [string](Get-JsonProp $Arguments 'scope')
    $period = [string](Get-JsonProp $Arguments 'period')
    if (-not $period) { $period = 'today' }
    if (-not $scope) { $scope = if ($isAdmin) { 'all' } else { 'mine' } }
    if ($scope -cnotin 'mine', 'all' -or $period -cnotin 'today', 'yesterday', 'week', 'month') {
        return @{ ok = $false; error = 'report_invalid' }
    }
    if ($scope -ceq 'all' -and -not $isAdmin) { return @{ ok = $false; error = 'forbidden' } }
    $onlyUser = if ($scope -ceq 'mine') { $actor } else { 0L }
    return @{ ok = $true; scope = $scope; period = $period; onlyUser = $onlyUser }
}

function Get-WebWorkSummary {
    param([System.Collections.IDictionary]$Arguments)
    $request = Get-WebReportScope -Arguments $Arguments
    if (-not $request.ok) { return $request }

    # The same bounded report classifies blocked and failed air operations
    # separately. Keep its detailed audit rows and labels inside the bridge.
    $report = Get-WorkReportData -Period $request.period -OnlyUserId $request.onlyUser
    $totals = $report.Totals
    return @{ ok = $true; data = [ordered]@{
            period = $request.period; scope = $request.scope; truncated = [bool]$report.Truncated
            operators = [int]$totals.Operators; operations = [int]$totals.Total; successful = [int]$totals.Success
            blocked = [int]$totals.Blocked; failed = [int]$totals.Failed; shows = [int]$totals.OnAir
        } }
}
