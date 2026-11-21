#requires -Version 7

$script:WebTelegramSuspensionReviews = @{}

function Get-WebTelegramSuspensionItem {
    param($User)
    return [ordered]@{ id = [long]$User.UserId; name = [string]$User.Alias; disabled = [bool]$User.Disabled }
}

function Get-WebSuspendedTelegramOperators {
    param([System.Collections.IDictionary]$Arguments)
    if (-not (Get-WebTelegramAccessAdministrator -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $page = 0
    $pageSize = 20
    $requestedPage = Get-JsonProp $Arguments 'page'
    $requestedSize = Get-JsonProp $Arguments 'pageSize'
    if (($null -ne $requestedPage -and -not [int]::TryParse([string]$requestedPage, [ref]$page)) -or $page -lt 0 -or
        ($null -ne $requestedSize -and -not [int]::TryParse([string]$requestedSize, [ref]$pageSize)) -or
        $pageSize -lt 1 -or $pageSize -gt 40) { return @{ ok = $false; error = 'bad_request' } }
    # Disabled users stay out of the sign-in roster. Only this administrative
    # view reads their underlying membership to make restoration possible.
    $users = @(Get-AuthorizedUsers | Where-Object { $_.Disabled -and $_.Role -ceq 'operator' -and -not (Test-WebOnlyUserId -UserId $_.UserId) })
    $window = Get-BridgePageWindow -ItemCount $users.Count -Page $page -PageSize $pageSize
    $items = @(if ($users.Count -gt 0) {
            foreach ($index in $window.StartIndex..$window.EndIndex) { Get-WebTelegramSuspensionItem -User $users[$index] }
        })
    return @{ ok = $true; data = @{ items = $items; page = $window.Page; pageSize = $pageSize; total = $users.Count } }
}

function Get-WebTelegramSuspensionCandidate {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebTelegramAccessAdministrator -Arguments $Arguments
    if (-not $actor) { return @{ error = 'forbidden' } }
    $id = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'userId'), [ref]$id) -or $id -le 0) {
        return @{ error = 'bad_request' }
    }
    if (Test-WebOnlyUserId -UserId $id) { return @{ error = 'telegram_user_protected' } }
    $user = Get-AuthorizedUsers | Where-Object UserId -eq $id | Select-Object -First 1
    if (-not $user) { return @{ error = 'telegram_user_unavailable' } }
    if ($user.Role -cne 'operator') { return @{ error = 'telegram_user_protected' } }
    if (-not $user.Disabled -and -not (Test-Authorized -ChatId $id -UserId $id)) {
        return @{ error = 'telegram_user_unavailable' }
    }
    $target = Get-WebTelegramSuspensionItem -User $user
    return @{
        actor = $actor; target = $target
        fingerprint = ConvertTo-Json -InputObject @($target, $user.Role, $user.AddedAt, $user.AddedByUserId) -Compress -Depth 3
    }
}

function New-WebTelegramSuspensionReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebTelegramSuspensionCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $desired = Get-JsonProp $Arguments 'disabled'
    if ($desired -isnot [bool]) { return @{ ok = $false; error = 'bad_request' } }
    if ($desired -eq $candidate.target.disabled) { return @{ ok = $false; error = 'telegram_suspension_stale' } }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebTelegramSuspensionReviews
    $script:WebTelegramSuspensionReviews[$candidate.actor].Desired = $desired
    return @{ ok = $true; data = @{ target = $candidate.target; disabled = $desired; review = $token } }
}

function Complete-WebTelegramSuspensionReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebTelegramSuspensionCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTelegramSuspensionReviews
    if (-not $review -or $review.Fingerprint -cne $candidate.fingerprint) { return @{ ok = $false; error = 'telegram_suspension_stale' } }

    $id = $candidate.target.id
    $desired = [bool]$review.Desired
    $persisted = Set-UserDisabled -TargetUserId $id -Disabled $desired
    if (-not $persisted -and -not $desired) {
        # An unsuccessful restore must leave the existing denial in force.
        $script:DisabledUserIds[[string]$id] = $true
        return @{ ok = $false; error = 'telegram_suspension_save_failed' }
    }
    if ((Test-UserDisabled -UserId $id) -ne $desired) { return @{ ok = $false; error = 'telegram_user_protected' } }
    $action = if ($desired) { 'suspend' } else { 'restore' }
    $result = if (-not $persisted) { 'suspended_runtime_only' } elseif ($desired) { 'suspended' } else { 'restored' }
    $label = if ($desired) { (T 'reply.disableWord') } else { (T 'reply.reEnable') }
    $actor = $candidate.actor
    Write-BridgeLog "Admin $actor ran $action for Telegram user $id from the web (persisted=$persisted)" 'WARN'
    Add-AuditEntry (T 'cb.userAudit' $label (Format-UserAuditActor -UserId $id) (Format-UserAuditActor -UserId $actor)) | Out-Null
    $audit = @{
        OperationId = "access-$([guid]::NewGuid().ToString('N'))"; EventName = 'authorization'
        Result = $result; UserId = $actor; ChatId = $id; Action = $action; Target = [string]$id
    }
    Write-AuditRecord @audit | Out-Null
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ userId = $id; disabled = $desired; persisted = [bool]$persisted } }
}
