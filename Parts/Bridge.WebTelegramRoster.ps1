#requires -Version 7

$script:WebTelegramRevokeReviews = @{}

function Get-WebTelegramRevokeTarget {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ error = 'forbidden' }
    }
    $id = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'userId'), [ref]$id) -or $id -le 0) {
        return @{ error = 'bad_request' }
    }
    if (Test-WebOnlyUserId -UserId $id) { return @{ error = 'telegram_user_protected' } }

    $user = Get-AuthorizedUsers | Where-Object UserId -eq $id | Select-Object -First 1
    if (-not $user -or $user.Disabled -or -not (Test-Authorized -ChatId $id -UserId $id)) {
        return @{ error = 'telegram_user_unavailable' }
    }
    if ($user.Role -cne 'operator') { return @{ error = 'telegram_user_protected' } }
    $target = [ordered]@{ id = $id; name = [string]$user.Alias; role = [string]$user.Role }
    return @{
        actor = $actor; target = $target
        fingerprint = ConvertTo-Json -InputObject @($target, $user.AddedAt, $user.AddedByUserId) -Depth 3 -Compress
    }
}

function New-WebTelegramRevokeReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebTelegramRevokeTarget -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebTelegramRevokeReviews
    return @{ ok = $true; data = @{ target = $candidate.target; review = $token } }
}

function Complete-WebTelegramRevokeReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebTelegramRevokeTarget -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTelegramRevokeReviews
    if (-not $review -or $review.Fingerprint -cne $candidate.fingerprint) { return @{ ok = $false; error = 'telegram_user_stale' } }

    $targetId = $candidate.target.id
    $actor = $candidate.actor
    $auditActor = Format-UserAuditActor -UserId $actor
    $auditTarget = Format-UserAuditActor -UserId $targetId
    $result = Revoke-AuthorizedUser -TargetUserId $targetId
    if (-not $result.Success) { return @{ ok = $false; error = 'telegram_user_protected' } }
    $persisted = -not $script:LastConfigSaveFailed
    $outcome = if ($persisted) { 'revoked' } else { 'revoked_runtime_only' }
    Write-BridgeLog "Admin $actor revoked Telegram user $targetId from the web (persisted=$persisted)" 'WARN'
    Add-AuditEntry (T 'cb.userRevokedAudit' $auditTarget $auditActor) | Out-Null
    $audit = @{
        OperationId = "access-$([guid]::NewGuid().ToString('N'))"; EventName = 'authorization'
        Result = $outcome; UserId = $actor; ChatId = $targetId; Action = 'revoke'; Target = [string]$targetId
    }
    Write-AuditRecord @audit | Out-Null
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ userId = $targetId; persisted = $persisted } }
}
