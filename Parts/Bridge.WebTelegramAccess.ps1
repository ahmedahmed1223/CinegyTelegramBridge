#requires -Version 7

$script:WebTelegramAccessReviews = @{}

function Get-WebTelegramAccessAdministrator {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0) { return }
    if ((Test-Authorized -ChatId $actor -UserId $actor) -and (Test-Admin -ChatId $actor -UserId $actor)) {
        return $actor
    }
}

function Get-WebTelegramAccessRequest {
    param([long]$ChatId, [datetime]$Now, [int]$ExpiryHours)
    if ($ChatId -le 0 -or (Test-WebOnlyUserId -UserId $ChatId)) { return }
    $record = $script:PendingApprovals[$ChatId]
    if ($null -eq $record) { return }

    $userId = [long](Get-JsonProp $record 'UserId')
    $requestedAt = Get-JsonProp $record 'RequestedAt'
    if ($ChatId -ne [long](Get-JsonProp $record 'ChatId') -or $userId -le 0 -or
        (Test-WebOnlyUserId -UserId $userId) -or $requestedAt -isnot [datetime]) { return }
    $expiresAt = $requestedAt.AddHours($ExpiryHours)
    # The pump can handle web work before the tick has discarded expired requests.
    if ($Now -ge $expiresAt) { return }
    return @{
        record = $record
        view = [ordered]@{
            chatId = $ChatId
            userId = $userId
            name = [string](Get-JsonProp $record 'Name')
            requestedAt = $requestedAt.ToUniversalTime().ToString('o')
            expiresAt = $expiresAt.ToUniversalTime().ToString('o')
        }
    }
}

function Get-WebTelegramAccessRequests {
    param([System.Collections.IDictionary]$Arguments)
    if (-not (Get-WebTelegramAccessAdministrator -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $page = 0
    $pageSize = 20
    $requestedPage = Get-JsonProp $Arguments 'page'
    $requestedSize = Get-JsonProp $Arguments 'pageSize'
    if (($null -ne $requestedPage -and -not [int]::TryParse([string]$requestedPage, [ref]$page)) -or $page -lt 0 -or
        ($null -ne $requestedSize -and -not [int]::TryParse([string]$requestedSize, [ref]$pageSize)) -or
        $pageSize -lt 1 -or $pageSize -gt 100) { return @{ ok = $false; error = 'bad_request' } }

    $expiryHours = Get-SettingInt 'PendingApprovalExpiryHours' 1
    $now = Get-Date
    $views = @(foreach ($chatId in @($script:PendingApprovals.Keys | Sort-Object)) {
            $request = Get-WebTelegramAccessRequest -ChatId ([long]$chatId) -Now $now -ExpiryHours $expiryHours
            if ($request) { $request.view }
        })
    $window = Get-BridgePageWindow -ItemCount $views.Count -Page $page -PageSize $pageSize
    $items = @(if ($views.Count -gt 0) { $views[$window.StartIndex..$window.EndIndex] })
    return @{ ok = $true; data = @{
            requests = $items; page = $window.Page; pageSize = $pageSize; total = $views.Count
            rejectionBlocks = [bool](Get-Setting 'BlockRejectedRequesters')
        } }
}

function Get-WebTelegramAccessDecision {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebTelegramAccessAdministrator -Arguments $Arguments
    if (-not $actor) { return @{ error = 'forbidden' } }
    $chatId = 0L
    $decision = [string](Get-JsonProp $Arguments 'decision')
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'chatId'), [ref]$chatId) -or $chatId -le 0 -or
        (Test-WebOnlyUserId -UserId $chatId) -or $decision -cnotin 'approve', 'deny') {
        return @{ error = 'bad_request' }
    }
    $request = Get-WebTelegramAccessRequest -ChatId $chatId -Now (Get-Date) -ExpiryHours (Get-SettingInt 'PendingApprovalExpiryHours' 1)
    if (-not $request) { return @{ error = 'access_request_stale' } }
    $rejectionBlocks = $decision -ceq 'deny' -and [bool](Get-Setting 'BlockRejectedRequesters')
    return @{
        actor = $actor; decision = $decision; request = $request; rejectionBlocks = $rejectionBlocks
        fingerprint = ConvertTo-Json -InputObject @($decision, $request.view, $rejectionBlocks) -Depth 3 -Compress
    }
}

function New-WebTelegramAccessDecisionReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebTelegramAccessDecision -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebTelegramAccessReviews
    # A request can be recreated with the same chat ID and otherwise identical data.
    $script:WebTelegramAccessReviews[$candidate.actor].Record = $candidate.request.record
    return @{ ok = $true; data = @{
            request = $candidate.request.view; decision = $candidate.decision
            rejectionBlocks = $candidate.rejectionBlocks; review = $token
        } }
}

function Invoke-WebTelegramAccessDecision {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebTelegramAccessDecision -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTelegramAccessReviews
    if (-not $review -or $review.Fingerprint -cne $candidate.fingerprint -or
        -not [object]::ReferenceEquals($review.Record, $candidate.request.record)) {
        return @{ ok = $false; error = 'access_request_stale' }
    }

    $target = $candidate.request.view
    if ($candidate.decision -ceq 'approve') {
        Grant-UserAccess -TargetChatId $target.chatId -ApprovedBy $candidate.actor -ApproverUserId $candidate.actor | Out-Null
    }
    else {
        Deny-UserAccess -TargetChatId $target.chatId -RejectedBy $candidate.actor -RejecterUserId $candidate.actor | Out-Null
    }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ chatId = $target.chatId; userId = $target.userId; decision = $candidate.decision } }
}

function Set-WebTelegramAccessRole {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $actor = Get-WebTelegramAccessAdministrator -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-Owner -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'owner_only' } }
    $targetId = 0L
    $role = [string](Get-JsonProp $Arguments 'role')
    $expectedRole = [string](Get-JsonProp $Arguments 'expectedRole')
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'userId'), [ref]$targetId) -or $targetId -le 0 -or
        (Test-WebOnlyUserId -UserId $targetId) -or $role -cnotin 'operator', 'admin' -or
        $expectedRole -cnotin 'operator', 'admin' -or $role -ceq $expectedRole) {
        return @{ ok = $false; error = 'bad_request' }
    }
    $target = Get-AuthorizedUsers | Where-Object UserId -eq $targetId | Select-Object -First 1
    if (-not $target -or $target.Role -cne $expectedRole) { return @{ ok = $false; error = 'access_role_stale' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $makeAdmin = $role -ceq 'admin'
    $result = Set-AdminRole -TargetUserId $targetId -IsAdmin $makeAdmin
    if (-not $result.Success) { return @{ ok = $false; error = 'access_role_refused'; message = [string]$result.Error } }

    $action = if ($makeAdmin) { (T 'reply.promoteToAdmin') } else { (T 'reply.demoteToOperator') }
    $notice = if ($makeAdmin) { (T 'reply.youWerePromoted') } else { (T 'reply.youWereDemoted') }
    Write-BridgeLog "Owner $actor performed '$action' on user $targetId from the web" 'WARN'
    Add-AuditEntry (T 'cb.roleAudit' $action $(Format-UserAuditActor -UserId $targetId) $(Format-UserAuditActor -UserId $actor)) | Out-Null
    Publish-WebChannelState -Force
    $menu = @{ scope = @{ type = 'chat'; chat_id = $targetId } }
    $method = 'deleteMyCommands'
    if ($makeAdmin) {
        $method = 'setMyCommands'
        $menu.commands = @($script:BotCommandList | ForEach-Object { @{ command = $_.command; description = $_.description } })
    }
    Add-TelegramOutboxItem -Uri "$apiBase/$method" -Body $menu -DueAt (Get-Date) -Attempts 0 | Out-Null
    Send-TelegramMessage -ChatId $targetId -Text $notice -Deferred | Out-Null
    return @{ ok = $true; data = @{ userId = $targetId; role = $role } }
}
