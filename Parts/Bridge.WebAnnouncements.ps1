#requires -Version 7

$script:WebAnnouncementReviews = @{}

function Get-WebAnnouncementAdmin {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if ([long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -and $actor -gt 0 -and
        (Test-Authorized -ChatId $actor -UserId $actor) -and (Test-Admin -ChatId $actor -UserId $actor)) {
        return $actor
    }
}

function Get-WebAnnouncementOptions {
    return @{
        enabled = [bool](Get-Setting 'EnableAnnouncements')
        maxLength = [math]::Min(3000, (Get-AnnouncementTextLimit))
        defaultExpiryHours = [math]::Min(720, (Get-SettingInt 'AnnouncementDefaultExpiryHours' 24))
    }
}

function Get-WebAnnouncementItem {
    param($Announcement, [datetime]$Now)
    $status = if (Test-AnnouncementLive -Announcement $Announcement -Now $Now) {
        if (Get-JsonProp $Announcement 'FirstDeliveryQueued') { 'queued' } else { 'active' }
    }
    elseif ((Get-JsonProp $Announcement 'Status') -eq 'cancelled') { 'cancelled' }
    else { 'expired' }
    $text = [string](Get-JsonProp $Announcement 'Text')
    if ($text.Length -gt 3000) { $text = $text.Substring(0, 2999) + '…' }
    return [ordered]@{
        id = [string](Get-JsonProp $Announcement 'Id'); text = $text
        scope = [string](Get-JsonProp $Announcement 'Scope')
        status = $status
        createdAt = ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $Announcement 'CreatedAt')
        expiresAt = ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $Announcement 'ExpiresAt')
        lastSentAt = ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $Announcement 'LastSentAt')
        repeatHours = [int](Get-JsonProp $Announcement 'RepeatHours')
        requireAck = [bool](Get-JsonProp $Announcement 'RequireAck'); pinned = [bool](Get-JsonProp $Announcement 'Pinned')
        readCount = [int](Get-AnnouncementReadCount -Announcement $Announcement)
    }
}

function Get-WebAnnouncementPage {
    param([System.Collections.IDictionary]$Arguments, [datetime]$Now = (Get-Date))
    if (-not (Get-WebAnnouncementAdmin -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $page = 0
    $pageSize = 8
    $requestedPage = Get-JsonProp $Arguments 'page'
    $requestedSize = Get-JsonProp $Arguments 'pageSize'
    if (($null -ne $requestedPage -and -not [int]::TryParse([string]$requestedPage, [ref]$page)) -or $page -lt 0 -or
        ($null -ne $requestedSize -and -not [int]::TryParse([string]$requestedSize, [ref]$pageSize)) -or
        $pageSize -lt 1 -or $pageSize -gt 20) { return @{ ok = $false; error = 'bad_request' } }
    $options = Get-WebAnnouncementOptions
    $all = @($script:Announcements | Sort-Object -Property { ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $_ 'CreatedAt') } -Descending)
    $window = Get-BridgePageWindow -ItemCount $all.Count -Page $page -PageSize $pageSize
    $items = @(if ($all.Count -gt 0) {
            foreach ($index in $window.StartIndex..$window.EndIndex) { Get-WebAnnouncementItem -Announcement $all[$index] -Now $Now }
        })
    return @{ ok = $true; data = @{
            items = $items; page = $window.Page; pageSize = $pageSize; total = $all.Count
            enabled = $options.enabled; maxLength = $options.maxLength; defaultExpiryHours = $options.defaultExpiryHours
        } }
}

function Get-WebAnnouncementCandidate {
    param([System.Collections.IDictionary]$Arguments, [long]$Actor)
    $options = Get-WebAnnouncementOptions
    if (-not $options.enabled) { return @{ error = 'announcement_disabled' } }
    $text = ConvertTo-AnnouncementText -Text ([string](Get-JsonProp $Arguments 'text'))
    $scope = [string](Get-JsonProp $Arguments 'scope')
    $expiry = Get-JsonProp $Arguments 'expiryHours'
    $repeat = Get-JsonProp $Arguments 'repeatHours'
    $requireAck = Get-JsonProp $Arguments 'requireAck'
    $pinned = Get-JsonProp $Arguments 'pinned'
    if (-not $text -or $text.Length -gt $options.maxLength -or $scope -cnotin 'all', 'admins', 'operators' -or
        ($expiry -isnot [int] -and $expiry -isnot [long]) -or $expiry -notin 0, 1, 6, 24, 72 -or
        ($repeat -isnot [int] -and $repeat -isnot [long]) -or $repeat -notin 0, 1, 3, 6, 12 -or
        $requireAck -isnot [bool] -or $pinned -isnot [bool]) { return @{ error = 'announcement_invalid' } }
    $effectiveExpiry = if ($expiry -eq 0) { $options.defaultExpiryHours } else { [int]$expiry }
    $audience = @(Get-AnnouncementAudience -Announcement @{ Scope = $scope } |
            Where-Object { $_ -ne $Actor -and -not (Test-WebOnlyUserId -UserId $_) -and -not (Test-DeadChat -ChatId $_) } |
            Sort-Object -Unique)
    if ($audience.Count -eq 0) { return @{ error = 'announcement_no_recipients' } }
    $draft = [ordered]@{
        text = $text; scope = $scope; expiryHours = [int]$expiry; repeatHours = [int]$repeat; requireAck = $requireAck; pinned = $pinned
    }
    return @{
        draft = $draft; effectiveExpiry = $effectiveExpiry; audienceCount = $audience.Count
        fingerprint = ConvertTo-Json -InputObject @('queue', $draft, $effectiveExpiry, $audience) -Depth 4 -Compress
    }
}

function New-WebAnnouncementReview {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebAnnouncementAdmin -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    $candidate = Get-WebAnnouncementCandidate -Arguments $Arguments -Actor $actor
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $token = New-WebAirReview -Actor $actor -Fingerprint $candidate.fingerprint -Reviews $script:WebAnnouncementReviews
    $script:WebAnnouncementReviews[$actor].Draft = $candidate.draft
    $draft = $candidate.draft
    return @{ ok = $true; data = @{
            text = $draft.text; scope = $draft.scope; expiryHours = $candidate.effectiveExpiry; repeatHours = $draft.repeatHours
            requireAck = $draft.requireAck; pinned = $draft.pinned; audienceCount = $candidate.audienceCount; review = $token
        } }
}

function Complete-WebAnnouncementReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline, [datetime]$Now = (Get-Date))
    $actor = Get-WebAnnouncementAdmin -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $review = Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAnnouncementReviews
    if (-not $review -or -not (Get-JsonProp $review 'Draft')) { return @{ ok = $false; error = 'announcement_stale' } }
    $candidate = Get-WebAnnouncementCandidate -Arguments $review.Draft -Actor $actor
    if ($candidate.ContainsKey('error') -or $review.Fingerprint -cne $candidate.fingerprint) {
        return @{ ok = $false; error = 'announcement_stale' }
    }
    $draft = $candidate.draft
    $parameters = @{
        Text = $draft.text; CreatedBy = $actor; Scope = $draft.scope
        ExpiryHours = $candidate.effectiveExpiry; RepeatHours = $draft.repeatHours
        RequireAck = $draft.requireAck; Pinned = $draft.pinned; QueueFirstDelivery = $true; Now = $Now
    }
    $announcement = New-BridgeAnnouncement @parameters
    if (-not $announcement) { return @{ ok = $false; error = 'announcement_save_failed' } }
    $id = [string](Get-JsonProp $announcement 'Id')
    $audit = @{ OperationId = $id; EventName = 'announcement'; Result = 'queued'; UserId = $actor; Action = 'queue'; Target = $id }
    Write-AuditRecord @audit | Out-Null
    Write-BridgeLog "Announcement $id queued from the web by $actor"
    return @{ ok = $true; data = (Get-WebAnnouncementItem -Announcement $announcement -Now $Now) }
}

function Get-WebAnnouncementCancelCandidate {
    param([System.Collections.IDictionary]$Arguments, [datetime]$Now)
    $actor = Get-WebAnnouncementAdmin -Arguments $Arguments
    if (-not $actor) { return @{ error = 'forbidden' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    if ($id -cnotmatch '^ann-[0-9a-f]{8}$') { return @{ error = 'bad_request' } }
    $announcement = $script:Announcements | Where-Object { (Get-JsonProp $_ 'Id') -ceq $id } | Select-Object -First 1
    if (-not $announcement -or -not (Test-AnnouncementLive -Announcement $announcement -Now $Now)) {
        return @{ error = 'announcement_stale' }
    }
    $item = Get-WebAnnouncementItem -Announcement $announcement -Now $Now
    return @{
        actor = $actor; announcement = $announcement; item = $item
        fingerprint = ConvertTo-Json -InputObject @('cancel', $id, $item.createdAt, $item.expiresAt, $item.status, $item.scope, $item.text, $item.repeatHours) -Compress
    }
}

function New-WebAnnouncementCancelReview {
    param([System.Collections.IDictionary]$Arguments, [datetime]$Now = (Get-Date))
    $candidate = Get-WebAnnouncementCancelCandidate -Arguments $Arguments -Now $Now
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebAnnouncementReviews
    $script:WebAnnouncementReviews[$candidate.actor].Announcement = $candidate.announcement
    return @{ ok = $true; data = @{ item = $candidate.item; review = $token } }
}

function Complete-WebAnnouncementCancelReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline, [datetime]$Now = (Get-Date))
    $candidate = Get-WebAnnouncementCancelCandidate -Arguments $Arguments -Now $Now
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAnnouncementReviews
    if (-not $review -or $review.Fingerprint -cne $candidate.fingerprint -or
        -not [object]::ReferenceEquals((Get-JsonProp $review 'Announcement'), $candidate.announcement)) {
        return @{ ok = $false; error = 'announcement_stale' }
    }
    $id = $candidate.item.id
    $persisted = Stop-BridgeAnnouncement -AnnouncementId $id -UserId $candidate.actor
    $outcome = if ($persisted) { 'cancelled' } else { 'cancelled_runtime_only' }
    $audit = @{ OperationId = $id; EventName = 'announcement'; Result = $outcome; UserId = $candidate.actor; Action = 'cancel'; Target = $id }
    Write-AuditRecord @audit | Out-Null
    return @{ ok = $true; data = @{
            item = Get-WebAnnouncementItem -Announcement $candidate.announcement -Now $Now; persisted = [bool]$persisted
        } }
}
