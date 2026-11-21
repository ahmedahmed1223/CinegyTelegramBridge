#requires -Version 7

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
