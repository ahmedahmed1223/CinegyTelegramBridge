#requires -Version 7

$script:WebTelegramAliasReviews = @{}

function Get-WebTelegramAliasCandidate {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebTelegramAccessAdministrator -Arguments $Arguments
    if (-not $actor) { return @{ error = 'forbidden' } }
    $id = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'userId'), [ref]$id) -or $id -le 0) {
        return @{ error = 'bad_request' }
    }
    if (Test-WebOnlyUserId -UserId $id) { return @{ error = 'telegram_user_protected' } }
    $user = Get-AuthorizedUsers | Where-Object UserId -eq $id | Select-Object -First 1
    if (-not $user -or $user.Disabled) { return @{ error = 'telegram_user_unavailable' } }
    if ($user.Role -cne 'operator') { return @{ error = 'telegram_user_protected' } }
    if (-not (Test-Authorized -ChatId $id -UserId $id)) { return @{ error = 'telegram_user_unavailable' } }
    $key = [string]$id
    $target = [ordered]@{ id = $id; name = [string]$user.Alias; alias = [string]$script:UserAliases[$key] }
    return @{
        actor = $actor; target = $target
        fingerprint = ConvertTo-Json -InputObject @($target, $script:UserAliases.ContainsKey($key), $user.Role, $user.AddedAt, $user.AddedByUserId) -Compress -Depth 3
    }
}

function New-WebTelegramAliasReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebTelegramAliasCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $value = Get-JsonProp $Arguments 'alias'
    if ($value -isnot [string]) { return @{ ok = $false; error = 'bad_request' } }
    $edit = Get-UserWorkingNameEdit -Value $value
    if (-not $edit.ok) { return $edit }
    if ([string]::Equals($edit.alias, $candidate.target.alias, [StringComparison]::Ordinal)) {
        return @{ ok = $false; error = 'telegram_alias_unchanged' }
    }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebTelegramAliasReviews
    $review = $script:WebTelegramAliasReviews[$candidate.actor]
    $review.Alias = $edit.alias
    return @{ ok = $true; data = @{ target = $candidate.target; alias = $edit.alias; review = $token; expiresAt = $review.ExpiresAt.ToString('o') } }
}

function Complete-WebTelegramAliasReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebTelegramAliasCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTelegramAliasReviews
    if (-not $review -or -not [string]::Equals($review.Fingerprint, $candidate.fingerprint, [StringComparison]::Ordinal)) {
        return @{ ok = $false; error = 'telegram_alias_stale' }
    }

    $id = $candidate.target.id
    $saved = Set-UserWorkingName -TargetUserId $id -Value $review.Alias
    if (-not $saved.ok) { return $saved }
    Write-UserWorkingNameAudit -TargetUserId $id -AdminUserId $candidate.actor -Alias $saved.alias
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ userId = $id; name = Get-UserDisplayName -UserId $id; alias = $saved.alias } }
}
