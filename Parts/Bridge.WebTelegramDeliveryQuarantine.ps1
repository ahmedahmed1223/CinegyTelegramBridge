#requires -Version 7

$script:WebTelegramQuarantineReviews = @{}

function Get-WebTelegramQuarantineRow {
    param([long]$ChatId, $Entry)
    $stamp = [datetimeoffset]::MinValue
    $since = if ([datetimeoffset]::TryParse([string](Get-JsonProp $Entry 'Since'), [ref]$stamp)) {
        $stamp.ToUniversalTime().ToString('o')
    }
    $strikes = 0
    [void][int]::TryParse([string](Get-JsonProp $Entry 'Strikes'), [ref]$strikes)
    return [ordered]@{ chatId = $ChatId; since = $since; strikes = [math]::Max(0, $strikes); canReset = $ChatId -gt 0 }
}

function Get-WebTelegramDeliveryQuarantine {
    param([System.Collections.IDictionary]$Arguments)
    if (-not (Get-WebTelegramAccessAdministrator -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $page = 0
    $pageSize = 20
    $requestedPage = Get-JsonProp $Arguments 'page'
    $requestedSize = Get-JsonProp $Arguments 'pageSize'
    if (($null -ne $requestedPage -and -not [int]::TryParse([string]$requestedPage, [ref]$page)) -or $page -lt 0 -or
        ($null -ne $requestedSize -and -not [int]::TryParse([string]$requestedSize, [ref]$pageSize)) -or
        $pageSize -lt 1 -or $pageSize -gt 40) { return @{ ok = $false; error = 'bad_request' } }
    $ids = @(foreach ($key in $script:DeadChats.Keys) {
            $id = 0L
            if ([long]::TryParse([string]$key, [ref]$id) -and $id -ne 0 -and [string]$id -ceq $key -and
                -not (Test-WebOnlyUserId -UserId $id)) { $id }
        })
    $ids = @($ids | Sort-Object)
    $window = Get-BridgePageWindow -ItemCount $ids.Count -Page $page -PageSize $pageSize
    $items = @(if ($ids.Count -gt 0) {
            foreach ($index in $window.StartIndex..$window.EndIndex) {
                $id = $ids[$index]
                Get-WebTelegramQuarantineRow -ChatId $id -Entry $script:DeadChats[[string]$id]
            }
        })
    return @{ ok = $true; data = @{ items = $items; page = $window.Page; pageSize = $pageSize; total = $ids.Count } }
}

function Get-WebTelegramQuarantineResetCandidate {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebTelegramAccessAdministrator -Arguments $Arguments
    if (-not $actor) { return @{ error = 'forbidden' } }
    $id = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'chatId'), [ref]$id) -or $id -eq 0) {
        return @{ error = 'bad_request' }
    }
    if ($id -lt 0 -or (Test-WebOnlyUserId -UserId $id)) { return @{ error = 'telegram_quarantine_protected' } }
    if (-not (Test-DeadChat -ChatId $id)) { return @{ error = 'telegram_quarantine_unavailable' } }
    $entry = $script:DeadChats[[string]$id]
    return @{
        actor = $actor; entry = $entry; target = Get-WebTelegramQuarantineRow -ChatId $id -Entry $entry
        fingerprint = ConvertTo-Json -InputObject @($id, (Get-JsonProp $entry 'Since'), (Get-JsonProp $entry 'Strikes'),
            (Get-JsonProp $entry 'LastError')) -Compress
    }
}

function New-WebTelegramQuarantineResetReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebTelegramQuarantineResetCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebTelegramQuarantineReviews
    $review = $script:WebTelegramQuarantineReviews[$candidate.actor]
    $review.Entry = $candidate.entry
    return @{ ok = $true; data = @{ target = $candidate.target; review = $token; expiresAt = $review.ExpiresAt.ToString('o') } }
}

function Complete-WebTelegramQuarantineResetReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebTelegramQuarantineResetCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTelegramQuarantineReviews
    if (-not $review -or -not [object]::ReferenceEquals($review.Entry, $candidate.entry) -or
        -not [string]::Equals($review.Fingerprint, $candidate.fingerprint, [StringComparison]::Ordinal)) {
        return @{ ok = $false; error = 'telegram_quarantine_stale' }
    }
    $id = $candidate.target.chatId
    if (-not (Restore-DeadChat -ChatId $id -ActorUserId $candidate.actor -PassThru)) {
        return @{ ok = $false; error = 'telegram_quarantine_save_failed' }
    }
    return @{ ok = $true; data = @{ chatId = $id } }
}
