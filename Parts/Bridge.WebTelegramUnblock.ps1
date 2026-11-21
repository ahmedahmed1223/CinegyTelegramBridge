#requires -Version 7

$script:WebTelegramUnblockReviews = @{}

function Get-WebTelegramUnblockAdmin {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if ([long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -and $actor -gt 0 -and
        (Test-Authorized -ChatId $actor -UserId $actor) -and (Test-Admin -ChatId $actor -UserId $actor)) {
        return $actor
    }
}

function Get-WebBlockedAccessItem {
    param($BlockedChat)
    $reason = [string]$BlockedChat.Reason
    if ($reason -cnotin 'rejected', 'join_secret') { $reason = 'unknown' }
    return [ordered]@{
        chatId = [long]$BlockedChat.ChatId; blockedAt = ConvertTo-AirStatusWidgetEpoch $BlockedChat.At
        reason = $reason
        blockedBy = if ($BlockedChat.By -gt 0) { [string](Get-UserDisplayName -UserId $BlockedChat.By) } else { '' }
    }
}

function Get-WebBlockedAccessPage {
    param([System.Collections.IDictionary]$Arguments)
    if (-not (Get-WebTelegramUnblockAdmin -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $page = 0
    $pageSize = 20
    $requestedPage = Get-JsonProp $Arguments 'page'
    $requestedSize = Get-JsonProp $Arguments 'pageSize'
    if (($null -ne $requestedPage -and -not [int]::TryParse([string]$requestedPage, [ref]$page)) -or $page -lt 0 -or
        ($null -ne $requestedSize -and -not [int]::TryParse([string]$requestedSize, [ref]$pageSize)) -or
        $pageSize -lt 1 -or $pageSize -gt 40) { return @{ ok = $false; error = 'bad_request' } }
    $blocked = @(Get-BlockedAccessChats | Where-Object { $_.ChatId -ne 0 -and -not (Test-WebOnlyUserId -UserId $_.ChatId) })
    $window = Get-BridgePageWindow -ItemCount $blocked.Count -Page $page -PageSize $pageSize
    $items = @(if ($blocked.Count -gt 0) {
            foreach ($index in $window.StartIndex..$window.EndIndex) { Get-WebBlockedAccessItem -BlockedChat $blocked[$index] }
        })
    return @{ ok = $true; data = @{ items = $items; page = $window.Page; pageSize = $pageSize; total = $blocked.Count } }
}

function Get-WebTelegramUnblockCandidate {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebTelegramUnblockAdmin -Arguments $Arguments
    if (-not $actor) { return @{ error = 'forbidden' } }
    $id = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'chatId'), [ref]$id) -or $id -eq 0 -or
        (Test-WebOnlyUserId -UserId $id)) { return @{ error = 'bad_request' } }
    $record = $script:AccessGuard.Blocked[[string]$id]
    if (-not $record) { return @{ error = 'access_blocked_stale' } }
    $blockedChat = [pscustomobject]@{
        ChatId = $id; At = [string](Get-JsonProp $record 'At')
        By = [long](Get-JsonProp $record 'By'); Reason = [string](Get-JsonProp $record 'Reason')
    }
    return @{
        actor = $actor; record = $record; item = Get-WebBlockedAccessItem -BlockedChat $blockedChat
        fingerprint = ConvertTo-Json -InputObject @($id, $blockedChat.At, $blockedChat.By, $blockedChat.Reason) -Compress
    }
}

function New-WebTelegramUnblockReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebTelegramUnblockCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebTelegramUnblockReviews
    $script:WebTelegramUnblockReviews[$candidate.actor].Record = $candidate.record
    return @{ ok = $true; data = @{ item = $candidate.item; review = $token } }
}

function Complete-WebTelegramUnblockReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebTelegramUnblockCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTelegramUnblockReviews
    if (-not $review -or $review.Fingerprint -cne $candidate.fingerprint -or
        -not [object]::ReferenceEquals($review.Record, $candidate.record)) {
        return @{ ok = $false; error = 'access_blocked_stale' }
    }
    $id = $candidate.item.chatId
    $key = [string]$id
    $hadAttempt = $script:AccessGuard.Attempts.ContainsKey($key)
    $attempt = $script:AccessGuard.Attempts[$key]
    if (-not (Unblock-AccessChat -ChatId $id -ByUserId $candidate.actor)) {
        # The Bot writer removes both entries before saving. Restore access
        # denial immediately if it cannot be changed on disk.
        $script:AccessGuard.Blocked[$key] = $candidate.record
        if ($hadAttempt) { $script:AccessGuard.Attempts[$key] = $attempt }
        return @{ ok = $false; error = 'access_unblock_save_failed' }
    }
    $actor = $candidate.actor
    Add-AuditEntry (T 'cb.unblockAudit' $id (Format-UserAuditActor -UserId $actor)) | Out-Null
    $audit = @{
        OperationId = "access-$([guid]::NewGuid().ToString('N'))"; EventName = 'authorization'
        Result = 'unblocked'; UserId = $actor; ChatId = $id; Action = 'unblock'; Target = $key
    }
    Write-AuditRecord @audit | Out-Null
    return @{ ok = $true; data = @{ chatId = $id } }
}
