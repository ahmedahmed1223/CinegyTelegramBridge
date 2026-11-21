#requires -Version 7

function Get-WebTelegramPresence {
    param([System.Collections.IDictionary]$Arguments, [datetime]$Now = (Get-Date))

    if (-not (Get-WebTelegramAccessAdministrator -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $page = 0
    $requestedPage = Get-JsonProp $Arguments 'page'
    $query = [string](Get-JsonProp $Arguments 'q')
    if (($null -ne $requestedPage -and -not [int]::TryParse([string]$requestedPage, [ref]$page)) -or
        $page -lt 0 -or $query.Length -gt 80) { return @{ ok = $false; error = 'bad_request' } }
    $query = $query.Trim()
    $recentMinutes = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))

    # This reflects Telegram interactions recorded by the bridge, including
    # historical activity for suspended roster members. Browser identities
    # have their own session view and do not supply Telegram presence.
    $visible = @(foreach ($user in @(Get-AuthorizedUsers)) {
        if (Test-WebOnlyUserId -UserId $user.UserId) { continue }
        $name = if ([string]$user.Alias -ceq [string]$user.UserId) { '' }
        else { Format-WebShiftHistoryField -Text ([string]$user.Alias) -MaximumLength 80 }
        if ($query -and $name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

        $activity = Get-UserActivityStatus -LastActivityAt ([string]$user.LastActivityAt) -Now $Now -ActiveWithinMinutes $recentMinutes
        $stamp = ConvertTo-AirStatusWidgetEpoch $activity.LastActivityAt
        [ordered]@{
            name = $name; role = [string]$user.Role; disabled = [bool]$user.Disabled; state = [string]$activity.State
            lastSeenAt = if ($stamp -gt 0) { $stamp } else { $null }
        }
    })
    $ordered = @($visible | Sort-Object -Stable -Property @{ Expression = { $_.lastSeenAt }; Descending = $true },
        @{ Expression = { $_.name } })
    $pageSize = 15
    $window = Get-BridgePageWindow -ItemCount $ordered.Count -Page $page -PageSize $pageSize
    return @{ ok = $true; data = @{
        page = $window.Page; pageSize = $pageSize; pageCount = $window.PageCount; total = $ordered.Count
        recentMinutes = $recentMinutes; capturedAt = ConvertTo-AirStatusWidgetEpoch $Now
        items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) { $ordered[$index] })
    } }
}

function Get-WebTelegramOperatorActivity {
    param([System.Collections.IDictionary]$Arguments, [datetime]$Now = (Get-Date))
    if (-not (Get-WebTelegramAccessAdministrator -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $id = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'userId'), [ref]$id) -or $id -le 0) {
        return @{ ok = $false; error = 'bad_request' }
    }
    if (Test-WebOnlyUserId -UserId $id) { return @{ ok = $false; error = 'telegram_user_protected' } }
    $user = Get-AuthorizedUsers | Where-Object UserId -eq $id | Select-Object -First 1
    if (-not $user -or $user.Disabled) { return @{ ok = $false; error = 'telegram_user_unavailable' } }
    if ($user.Role -cne 'operator') { return @{ ok = $false; error = 'telegram_user_protected' } }
    if (-not (Test-Authorized -ChatId $id -UserId $id)) { return @{ ok = $false; error = 'telegram_user_unavailable' } }

    $recentMinutes = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))
    $activity = Get-UserActivityStatus -LastActivityAt ([string]$user.LastActivityAt) -Now $Now -ActiveWithinMinutes $recentMinutes
    $report = Get-WorkReportData -Period 'today' -OnlyUserId $id
    $totals = $report.Totals

    # Work report rows can contain editorial values, error messages and
    # template keys. Send scalar aggregates only, so report changes stay local.
    return @{ ok = $true; data = [ordered]@{
            userId = $id; state = [string]$activity.State; ageMinutes = $activity.AgeMinutes
            recentMinutes = $recentMinutes
            today = [ordered]@{
                operations = [int]$totals.Total; successful = [int]$totals.Success
                blocked = [int]$totals.Blocked; failed = [int]$totals.Failed; shows = [int]$totals.OnAir
                truncated = [bool]$report.Truncated
            }
        } }
}
