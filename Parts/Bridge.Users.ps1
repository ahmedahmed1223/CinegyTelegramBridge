#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Send-TelegramDocument {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Caption = ''
    )
    try { $form = @{ chat_id = "$ChatId"; document = Get-Item -LiteralPath $FilePath -ErrorAction Stop } }
    catch { Write-BridgeLog "Failed to send Telegram document to $ChatId : $($_.Exception.Message)" 'ERROR'; return $false }
    if ($Caption) { $form.caption = $Caption }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendDocument" -Method Post -Form $form `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 3
    if (-not $request.Success) {
        Write-BridgeLog "Failed to send Telegram document to $ChatId : $($request.Error)" 'ERROR'
        return $false
    }
    return $true
}

function Receive-TelegramDocument {
    param(
        [Parameter(Mandatory)][string]$FileId,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaximumBytes = 1048576
    )
    $metadata = Invoke-RestMethod -Uri "$apiBase/getFile?file_id=$([uri]::EscapeDataString($FileId))" -Method Get `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1)
    if (-not (Get-JsonProp $metadata 'ok')) { throw 'Telegram رفض طلب معلومات الملف.' }
    $result = Get-JsonProp $metadata 'result'
    $remotePath = [string](Get-JsonProp $result 'file_path')
    if ([string]::IsNullOrWhiteSpace($remotePath) -or $remotePath.Contains('..') -or $remotePath -notmatch '^[A-Za-z0-9_./-]+$') {
        throw 'Telegram أعاد مسار ملف غير صالح.'
    }
    $reportedSize = Get-JsonProp $result 'file_size'
    if ($null -ne $reportedSize -and ([long]$reportedSize -le 0 -or [long]$reportedSize -gt $MaximumBytes)) {
        throw "حجم ملف الاستيراد غير صالح ($reportedSize بايت)."
    }
    $directory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Invoke-WebRequest -Uri "https://api.telegram.org/file/bot$($config.BotToken)/$remotePath" -OutFile $DestinationPath `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) | Out-Null
    $length = (Get-Item -LiteralPath $DestinationPath -ErrorAction Stop).Length
    if ($length -le 0 -or $length -gt $MaximumBytes) {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        throw "حجم ملف الاستيراد غير صالح ($length بايت)."
    }
    return $DestinationPath
}

function Save-UserProfiles {
    param([switch]$Force)
    if (-not $script:UserProfilesDirty) { return $true }
    if (-not $Force -and ((Get-Date) - $script:LastUserProfilesFlush).TotalSeconds -lt 60) { return $true }
    try {
        $temporary = "$($script:userProfilesFile).tmp"
        $script:UserProfiles | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:userProfilesFile -Force -ErrorAction Stop
        $script:UserProfilesDirty = $false; $script:LastUserProfilesFlush = Get-Date
        return $true
    }
    catch { Write-BridgeLog "Could not write user-profiles.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Write-UserApprovalMetadata {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ApprovedByUserId)
    $script:UserProfiles[[string]$TargetUserId] = @{ AddedAt = (Get-Date).ToString('o'); AddedByUserId = $ApprovedByUserId; LastActivityAt = $null }
    $script:UserProfilesDirty = $true
    return Save-UserProfiles -Force
}

function Update-UserLastActivity {
    param([Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Authorized -ChatId $UserId -UserId $UserId)) { return $false }
    $id = [string]$UserId
    if (-not $script:UserProfiles.ContainsKey($id)) { $script:UserProfiles[$id] = @{ AddedAt = ''; AddedByUserId = 0L; LastActivityAt = '' } }
    $script:UserProfiles[$id].LastActivityAt = (Get-Date).ToString('o'); $script:UserProfilesDirty = $true
    Save-UserProfiles | Out-Null
    return $true
}

function Import-AccessGuard {
    <#
        Who has been turned away, and who has been knocking.

        A public bot is found by strangers. Rejecting one used to remove the
        request and nothing else, so the same chat could ask again a second
        later, for ever - MaxPendingApprovals caps how long the queue gets,
        never how many times one person may join it.
    #>
    $script:AccessGuard = @{ Blocked = @{}; Attempts = @{} }
    if (-not (Test-Path -LiteralPath $script:accessGuardFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:accessGuardFile -Raw | ConvertFrom-Json
        foreach ($section in @('Blocked', 'Attempts')) {
            $saved = Get-JsonProp $raw $section
            if (-not $saved) { continue }
            foreach ($prop in $saved.PSObject.Properties) { $script:AccessGuard[$section][$prop.Name] = $prop.Value }
        }
        Write-BridgeLog "Restored $($script:AccessGuard.Blocked.Count) blocked chat(s) from access-guard.json"
    }
    catch { Write-BridgeLog "Could not read access-guard.json: $($_.Exception.Message)" 'WARN' }
}

function Save-AccessGuard {
    try {
        $temporary = "$($script:accessGuardFile).tmp"
        $script:AccessGuard | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:accessGuardFile -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write access-guard.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Test-ChatBlocked {
    param([Parameter(Mandatory)][long]$ChatId)
    return $script:AccessGuard.Blocked.ContainsKey([string]$ChatId)
}

function Block-AccessChat {
    <# Silently, always. Telling someone they are blocked tells them the bot
       is worth a second account. #>
    param([Parameter(Mandatory)][long]$ChatId, [string]$Reason = '', [long]$ByUserId = 0)
    $script:AccessGuard.Blocked[[string]$ChatId] = @{ At = (Get-Date).ToString('o'); By = $ByUserId; Reason = $Reason }
    Write-BridgeLog "Access blocked for chat $ChatId ($Reason) by $ByUserId"
    # Silent towards the blocked chat, never towards the administrators: a
    # block nobody is told about is one nobody knows to lift. Only the guard's
    # own blocks announce themselves - a rejection an administrator just made
    # is not news to them.
    if ($ByUserId -le 0 -and (Get-Setting 'NotifyAdminsOnBlockedChat')) {
        Send-AdminBroadcast -Text "🚫 حُظرت المحادثة $ChatId تلقائيًا ($(Get-BlockedAccessReasonText -Reason $Reason)).`nارفع الحظر من 👤 طلبات الوصول ← 🚫 المحظورون." | Out-Null
    }
    return (Save-AccessGuard)
}

function Unblock-AccessChat {
    <# Clears the day's attempt count too: letting someone back in means
       letting them ask, not letting them meet a stale limit. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$ByUserId = 0)
    if (-not (Test-ChatBlocked -ChatId $ChatId)) { return $false }
    $script:AccessGuard.Blocked.Remove([string]$ChatId)
    $script:AccessGuard.Attempts.Remove([string]$ChatId)
    Write-BridgeLog "Access unblocked for chat $ChatId by $ByUserId"
    return (Save-AccessGuard)
}

function Get-BlockedAccessChats {
    return @($script:AccessGuard.Blocked.Keys | Sort-Object { [long]$_ } | ForEach-Object {
            $record = $script:AccessGuard.Blocked[$_]
            [pscustomobject]@{
                ChatId = [long]$_
                At     = [string](Get-JsonProp $record 'At')
                By     = [long](Get-JsonProp $record 'By')
                Reason = [string](Get-JsonProp $record 'Reason')
            }
        })
}

function Get-AccessAttempt {
    <# One rolling day per chat. The window restarts rather than sliding: a
       counter that never resets turns one busy afternoon into a permanent
       refusal nobody chose. #>
    param([Parameter(Mandatory)][long]$ChatId, [datetime]$Now = (Get-Date))
    $saved = $script:AccessGuard.Attempts[[string]$ChatId]
    if ($saved) {
        $firstAt = [datetime]::MinValue
        if ([datetime]::TryParse([string](Get-JsonProp $saved 'FirstAt'), [ref]$firstAt) -and ($Now - $firstAt).TotalHours -lt 24) {
            return @{
                FirstAt      = [string](Get-JsonProp $saved 'FirstAt')
                Requests     = [int](Get-JsonProp $saved 'Requests')
                SecretFails  = [int](Get-JsonProp $saved 'SecretFails')
                SecretPassed = [bool](Get-JsonProp $saved 'SecretPassed')
            }
        }
    }
    return @{ FirstAt = $Now.ToString('o'); Requests = 0; SecretFails = 0; SecretPassed = $false }
}

function Add-AccessAttempt {
    param([Parameter(Mandatory)][long]$ChatId, [ValidateSet('request', 'secret')][string]$Kind = 'request', [datetime]$Now = (Get-Date))
    $entry = Get-AccessAttempt -ChatId $ChatId -Now $Now
    if ($Kind -eq 'request') { $entry.Requests = [int]$entry.Requests + 1 } else { $entry.SecretFails = [int]$entry.SecretFails + 1 }
    $script:AccessGuard.Attempts[[string]$ChatId] = $entry
    Save-AccessGuard | Out-Null
    return $entry
}

function Set-AccessSecretPassed {
    <# Remembered so the code is asked for once, not again on every message
       sent while the request waits in the queue. #>
    param([Parameter(Mandatory)][long]$ChatId, [datetime]$Now = (Get-Date))
    $entry = Get-AccessAttempt -ChatId $ChatId -Now $Now
    $entry.SecretPassed = $true
    $script:AccessGuard.Attempts[[string]$ChatId] = $entry
    return (Save-AccessGuard)
}

function Test-AccessSecretPassed {
    param([Parameter(Mandatory)][long]$ChatId, [datetime]$Now = (Get-Date))
    return [bool](Get-AccessAttempt -ChatId $ChatId -Now $Now).SecretPassed
}

function Test-JoinSecret {
    <# An empty setting is not a secret that everything matches: it means the
       check is off, and nothing passes it. #>
    param([AllowEmptyString()][string]$Provided = '')
    $expected = [string](Get-Setting 'JoinSecret')
    if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
    return ([string]$Provided).Trim().Equals($expected.Trim(), [System.StringComparison]::Ordinal)
}

function Test-AccessRequestAllowed {
    <#
        May this chat put a request in front of the administrators at all?

        Blocked chats never may. Everyone else gets a few tries a day: the
        point is not to stop a colleague who mistyped, it is to stop one
        stranger from filling the queue by tapping start.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [datetime]$Now = (Get-Date))
    if (Test-ChatBlocked -ChatId $ChatId) { return $false }
    $max = Get-SettingInt 'MaxAccessRequestsPerDay' 0
    if ($max -le 0) { return $true }
    $entry = Add-AccessAttempt -ChatId $ChatId -Kind request -Now $Now
    if ([int]$entry.Requests -le $max) { return $true }
    Write-BridgeLog "Access request from $ChatId dropped: $($entry.Requests) in 24h, limit $max" 'WARN'
    return $false
}

function Get-UnauthorizedReplyText {
    <# What an unauthorized chat is told, in one place because two callers
       say it. Empty means say nothing: the join-code prompt has already gone
       out, and a second line contradicting it only confuses. #>
    param([Parameter(Mandatory)][long]$ChatId, [bool]$Queued)
    if ($Queued) { return 'غير مصرح لك باستخدام هذا البوت بعد. تم إرسال طلب وصول إلى المشرف - ستصلك رسالة فور الموافقة.' }
    $state = Get-PendingState -ChatId $ChatId
    if ($state -and [string]$state.Mode -eq 'join_secret') { return '' }
    return 'غير مصرح لك باستخدام هذا البوت. تواصل مع المشرف مباشرة.'
}

function Get-UserIdleDays {
    <# Silence measured from the last interaction, or from the day access was
       granted when there has never been one. A user with neither date is not
       counted: no record is not evidence of absence. #>
    param([Parameter(Mandatory)]$User, [datetime]$Now = (Get-Date))
    $stamp = [string](Get-JsonProp $User 'LastActivityAt')
    if ([string]::IsNullOrWhiteSpace($stamp)) { $stamp = [string](Get-JsonProp $User 'AddedAt') }
    if ([string]::IsNullOrWhiteSpace($stamp)) { return -1 }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($stamp, [ref]$parsed)) { return -1 }
    return [int][math]::Floor(($Now - $parsed).TotalDays)
}

function Get-DormantUsers {
    <# Owners are never listed: the account that cannot be locked out is the
       one a timer must not sweep away. #>
    param([datetime]$Now = (Get-Date))
    $days = Get-SettingInt 'DormantUserDays' 0
    if ($days -le 0) { return @() }
    return @(Get-AuthorizedUsers | Where-Object {
            [string]$_.Role -ne 'owner' -and -not $_.Disabled -and (Get-UserIdleDays -User $_ -Now $Now) -ge $days
        })
}

function Update-DormantUsers {
    <# Once a day at most: this is a report about months of silence and
       nothing in it is urgent. #>
    param([datetime]$Now = (Get-Date), [switch]$Force)
    $days = Get-SettingInt 'DormantUserDays' 0
    if ($days -le 0) { return @() }
    if (-not $Force -and $script:LastDormantSweep -and ($Now - $script:LastDormantSweep).TotalHours -lt 24) { return @() }
    $script:LastDormantSweep = $Now
    $dormant = @(Get-DormantUsers -Now $Now)
    if ($dormant.Count -eq 0) { return @() }
    $auto = [bool](Get-Setting 'AutoDisableDormantUsers')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("😴 مستخدمون بلا نشاط منذ $days يومًا أو أكثر:")
    foreach ($user in $dormant) {
        $disabled = if ($auto -and (Set-UserDisabled -TargetUserId ([long]$user.UserId) -Disabled $true)) { ' · تم تعطيله' } else { '' }
        $lines.Add("• $($user.Alias) ($($user.UserId)) · $(Get-UserIdleDays -User $user -Now $Now) يومًا$disabled")
    }
    $lines.Add($(if ($auto) { 'أعد التفعيل من 👥 المستخدمين عند الحاجة.' } else { 'التعطيل التلقائي مغلق؛ فعّل AutoDisableDormantUsers إن أردته.' }))
    Send-AdminBroadcast -Text ($lines -join "`n") | Out-Null
    Write-BridgeLog "Dormant sweep: $($dormant.Count) user(s) idle $days+ days, auto-disable=$auto"
    return $dormant
}

function Exit-UnknownGroupChat {
    <# The bridge is a one-to-one tool. Added to a group it used to sit there
       ignoring every message - present, silent, and readable by whoever had
       added it. It leaves instead, once, and says where it had been. #>
    param($Chat)
    if (-not (Get-Setting 'LeaveUnknownGroups')) { return $false }
    if ([string](Get-JsonProp $Chat 'type') -notin @('group', 'supergroup', 'channel')) { return $false }
    $groupId = [long](Get-JsonProp $Chat 'id')
    # A group somebody deliberately whitelisted is not unknown.
    if (@(Get-JsonProp $config 'AllowedChatIds') -contains $groupId) { return $false }
    if ($script:LeftGroupChats.ContainsKey([string]$groupId)) { return $false }
    $script:LeftGroupChats[[string]$groupId] = $true
    $title = ([string](Get-JsonProp $Chat 'title') -replace '[\r\n\t]+', ' ').Trim()
    if ($title.Length -gt 60) { $title = $title.Substring(0, 60) }
    $result = Invoke-BridgeTelegramRequest -Uri "$apiBase/leaveChat" -Method Post -Body @{ chat_id = "$groupId" } `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1)
    if (-not $result.Success) {
        Write-BridgeLog "Could not leave unknown chat $groupId : $($result.Error)" 'WARN'
        return $false
    }
    Write-BridgeLog "Left unknown chat $groupId ($title)"
    Send-AdminBroadcast -Text "🚪 غادر البوت محادثة جماعية غير معروفة: $title ($groupId)" | Out-Null
    return $true
}

function Import-DisabledUsers {
    if (-not (Test-Path -LiteralPath $script:disabledUsersFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:disabledUsersFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { if ([bool]$prop.Value) { $script:DisabledUserIds[$prop.Name] = $true } }
    }
    catch { Write-BridgeLog "Could not read disabled-users.json: $($_.Exception.Message)" 'WARN' }
}

function Save-DisabledUsers {
    try {
        $temporary = "$($script:disabledUsersFile).tmp"
        $script:DisabledUserIds | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:disabledUsersFile -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write disabled-users.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Set-UserDisabled {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][bool]$Disabled)
    if ($TargetUserId -le 0) { return $false }
    if ($Disabled) {
        $adminIds = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
        $activeAdmins = @($adminIds | Where-Object { -not (Test-UserDisabled -UserId ([long]$_)) })
        if ($adminIds -contains $TargetUserId -and $activeAdmins.Count -le 1) { return $false }
    }
    if ($Disabled -and (Get-OwnerIds) -contains $TargetUserId) { return $false }
    if ($Disabled) {
        $script:DisabledUserIds[[string]$TargetUserId] = $true
        Clear-PendingStatesForUser -UserId $TargetUserId
    }
    else { $script:DisabledUserIds.Remove([string]$TargetUserId) }
    return Save-DisabledUsers
}

function Test-UserDisabled {
    param([Parameter(Mandatory)][long]$UserId)
    return $script:DisabledUserIds.ContainsKey([string]$UserId)
}

function Revoke-AuthorizedUser {
    param([Parameter(Mandatory)][long]$TargetUserId)
    if ((Get-OwnerIds) -contains $TargetUserId) {
        return [pscustomobject]@{ Success = $false; Error = 'لا يمكن سحب صلاحية المالك.' }
    }
    $admins = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
    if ($admins -contains $TargetUserId -and $admins.Count -le 1) { return [pscustomobject]@{ Success = $false; Error = 'لا يمكن سحب صلاحية آخر مشرف.' } }
    foreach ($name in @('AllowedChatIds', 'AllowedUserIds', 'AdminChatIds', 'AdminUserIds')) {
        $remaining = @(@(Get-JsonProp $config $name) | Where-Object { [long]$_ -ne $TargetUserId })
        $config | Add-Member -NotePropertyName $name -NotePropertyValue $remaining -Force
    }
    $script:DisabledUserIds.Remove([string]$TargetUserId)
    Clear-PendingStatesForUser -UserId $TargetUserId
    $script:UserProfiles.Remove([string]$TargetUserId); $script:UserProfilesDirty = $true
    Save-DisabledUsers | Out-Null; Save-UserProfiles -Force | Out-Null; Save-Config
    return [pscustomobject]@{ Success = $true; Error = '' }
}

function Get-AuthorizedUsers {
    $ids = @(@(Get-JsonProp $config 'AllowedUserIds') + @(Get-JsonProp $config 'AllowedChatIds') + @(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') |
            Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
    $adminIds = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Sort-Object -Unique)
    $ownerIds = @(Get-OwnerIds)
    return @($ids | ForEach-Object {
            $id = [long]$_
            [pscustomobject]@{
                UserId = $id; Alias = Get-UserDisplayName -UserId $id
                Role = if ($ownerIds -contains $id) { 'owner' } elseif ($adminIds -contains $id) { 'admin' } else { 'operator' }
                Disabled = Test-UserDisabled -UserId $id
                AddedAt = if ($script:UserProfiles.ContainsKey([string]$id)) { [string]$script:UserProfiles[[string]$id].AddedAt } else { '' }
                AddedByUserId = if ($script:UserProfiles.ContainsKey([string]$id)) { [long]$script:UserProfiles[[string]$id].AddedByUserId } else { 0L }
                LastActivityAt = if ($script:UserProfiles.ContainsKey([string]$id)) { [string]$script:UserProfiles[[string]$id].LastActivityAt } else { '' }
            }
        })
}

function Request-UserRevocation {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$AdminUserId)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'user_revoke'; TargetUserId = $TargetUserId; UserId = $AdminUserId }
    Send-TelegramMessage -ChatId $ChatId -Text "⚠️ تأكيد سحب صلاحية $(Get-UserDisplayName -UserId $TargetUserId) ($TargetUserId)؟" `
        -ReplyMarkup @{ inline_keyboard = @(, @((New-Button '✅ نعم، اسحب الصلاحية' 'usr:revokeconfirm' -Style danger), (New-Button '❌ إلغاء' 'menu:usersadmin'))) }
}

function Test-Authorized {
    <# In a private chat chat.id == user.id, so the historical AllowedChatIds
       list keeps working untouched. In a group they differ, and with
       RequireUserLevelAuth on (the default) the sender must be listed in
       AllowedUserIds explicitly - whitelisting a group no longer implicitly
       authorizes every member of it. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return Test-BridgeAuthorized -ChatId $ChatId -UserId $UserId `
        -AllowedUserIds @(Get-JsonProp $config 'AllowedUserIds') -AllowedChatIds @(Get-JsonProp $config 'AllowedChatIds') `
        -DisabledUserIds @($script:DisabledUserIds.Keys) -RequireUserLevelAuth:([bool](Get-Setting 'RequireUserLevelAuth'))
}

function Test-Admin {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    # Role hierarchy: owner > administrator > operator. An explicit owner
    # inherits every administrator permission without needing a duplicate id
    # in AdminUserIds; administrator-only users never inherit owner powers.
    if (Test-BridgeOwner -ChatId $ChatId -UserId $UserId `
            -OwnerUserIds @(Get-JsonProp $config 'OwnerUserIds') `
            -AdminUserIds @(Get-JsonProp $config 'AdminUserIds') -AdminChatIds @(Get-JsonProp $config 'AdminChatIds')) {
        return $true
    }
    return Test-BridgeAdministrator -ChatId $ChatId -UserId $UserId `
        -AdminUserIds @(Get-JsonProp $config 'AdminUserIds') -AdminChatIds @(Get-JsonProp $config 'AdminChatIds') `
        -RequireUserLevelAuth:([bool](Get-Setting 'RequireUserLevelAuth'))
}

function Get-UserActivityStatus {
    param([AllowEmptyString()][string]$LastActivityAt = '', [datetime]$Now = (Get-Date), [ValidateRange(1, 1440)][int]$ActiveWithinMinutes = 5)
    $last = [datetime]::MinValue
    if ([string]::IsNullOrWhiteSpace($LastActivityAt) -or -not [datetime]::TryParse($LastActivityAt, [ref]$last)) {
        return [pscustomobject]@{ State = 'unknown'; Label = '⚪ النشاط غير معروف'; AgeMinutes = $null }
    }
    $ageMinutes = [math]::Max(0, [int][math]::Floor(($Now - $last).TotalMinutes))
    if ($ageMinutes -lt $ActiveWithinMinutes) {
        return [pscustomobject]@{ State = 'recent'; Label = "🟢 نشط حديثًا · منذ $ageMinutes د"; AgeMinutes = $ageMinutes }
    }
    return [pscustomobject]@{ State = 'idle'; Label = "🟠 خامل · منذ $ageMinutes د"; AgeMinutes = $ageMinutes }
}

function Get-UserActivitySummaryText {
    param([datetime]$Now = (Get-Date))
    $windowMinutes = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("👥 نشاط المستخدمين التقريبي · النافذة $windowMinutes د")
    $lines.Add('Telegram لا يوفّر حالة اتصال لحظية؛ الحالة مبنية على آخر تفاعل مع البوت.')
    foreach ($user in @(Get-AuthorizedUsers)) {
        $activity = Get-UserActivityStatus -LastActivityAt ([string]$user.LastActivityAt) -Now $Now -ActiveWithinMinutes $windowMinutes
        $lines.Add("• $($user.Alias): $($activity.Label)")
    }
    return ($lines -join "`n")
}

function Get-UserActivityDetailText {
    param([Parameter(Mandatory)][long]$TargetUserId, [datetime]$Now = (Get-Date))
    $user = @(Get-AuthorizedUsers | Where-Object { [long]$_.UserId -eq $TargetUserId } | Select-Object -First 1)
    if ($user.Count -eq 0) { return 'المستخدم لم يعد ضمن قائمة المصرح لهم.' }
    $windowMinutes = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))
    $activity = Get-UserActivityStatus -LastActivityAt ([string]$user[0].LastActivityAt) -Now $Now -ActiveWithinMinutes $windowMinutes
    return "👤 $($user[0].Alias)`n$($activity.Label)`nالحالة تقريبية حسب آخر تفاعل مع البوت؛ Telegram لا يوفّر اتصالًا لحظيًا للبوت."
}

function Test-StatusViewer {
    <# Full status is operationally useful to the owner as well as an
       administrator, but it must not widen access to mutating admin tools. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return [bool]((Test-Admin -ChatId $ChatId -UserId $UserId) -or
        (Test-Owner -ChatId $ChatId -UserId $UserId))
}

function Test-TemplateReminderManager {
    <# Template reminder policy is intentionally narrower than full template
       administration: both administrators and the configured owner may set it. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return [bool]((Test-Admin -ChatId $ChatId -UserId $UserId) -or
        (Test-Owner -ChatId $ChatId -UserId $UserId))
}

function Get-OwnerIds {
    return @(Get-BridgeOwnerIds -OwnerUserIds @(Get-JsonProp $config 'OwnerUserIds') `
            -AdminUserIds @(Get-JsonProp $config 'AdminUserIds') -AdminChatIds @(Get-JsonProp $config 'AdminChatIds'))
}

function Test-Owner {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return Test-BridgeOwner -ChatId $ChatId -UserId $UserId `
        -OwnerUserIds @(Get-JsonProp $config 'OwnerUserIds') `
        -AdminUserIds @(Get-JsonProp $config 'AdminUserIds') -AdminChatIds @(Get-JsonProp $config 'AdminChatIds')
}

function Test-OwnerConfiguration {
    <#
        Says so at startup when OwnerUserIds names someone who cannot use the
        bot.

        Naming an owner who is not in the whitelist locks the station out of
        the role entirely, and silently: the named owner is refused at every
        screen because authorization is checked first, and the administrator
        who held the role by default no longer does. Nobody can appoint
        anyone, and nothing says why.

        Reports rather than corrects. Quietly ignoring a configured owner
        would be its own surprise, and config is meant to win.
    #>
    $configured = @(@(Get-JsonProp $config 'OwnerUserIds') | Where-Object { [long]$_ -gt 0 } | ForEach-Object { [long]$_ })
    if ($configured.Count -eq 0) { return @() }

    $warnings = @()
    foreach ($id in $configured) {
        if (-not (Test-Authorized -ChatId $id -UserId $id)) {
            $warnings += "OwnerUserIds names $id, who is not authorized to use the bot - that owner cannot appoint anyone."
        }
    }
    return @($warnings)
}

function Set-AdminRole {
    <#
        Appoints or removes an administrator. Owners only - the caller checks
        that, because the refusal belongs in the chat rather than in here.

        An administrator can restart the bridge, rewrite every setting and
        revoke other users, so the guards below are not ceremony:

          * The last administrator cannot be demoted. The revoke path has
            refused that since long before this existed, and a demotion is
            the same loss by another route.
          * An owner cannot be demoted at all. Otherwise two owners could
            strip each other and the bridge would be left with nobody able to
            appoint anyone.
          * Only an already-authorized user can be promoted, so promotion
            never doubles as a way in.
    #>
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][bool]$IsAdmin)
    if ($TargetUserId -le 0) { return [pscustomobject]@{ Success = $false; Error = 'معرّف مستخدم غير صالح.' } }

    $admins = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') |
            Where-Object { [long]$_ -gt 0 } | ForEach-Object { [long]$_ } | Sort-Object -Unique)

    if ($IsAdmin) {
        if ($admins -contains $TargetUserId) { return [pscustomobject]@{ Success = $false; Error = 'هذا المستخدم مشرف بالفعل.' } }
        $authorized = @(@(Get-JsonProp $config 'AllowedUserIds') + @(Get-JsonProp $config 'AllowedChatIds') |
                Where-Object { [long]$_ -gt 0 } | ForEach-Object { [long]$_ })
        if ($authorized -notcontains $TargetUserId) { return [pscustomobject]@{ Success = $false; Error = 'لا يمكن ترقية مستخدم غير مصرّح له.' } }
        $updated = @($admins + $TargetUserId | Sort-Object -Unique)
    }
    else {
        if ($admins -notcontains $TargetUserId) { return [pscustomobject]@{ Success = $false; Error = 'هذا المستخدم ليس مشرفًا.' } }
        if ((Get-OwnerIds) -contains $TargetUserId) { return [pscustomobject]@{ Success = $false; Error = 'لا يمكن خفض صلاحية المالك.' } }
        if ($admins.Count -le 1) { return [pscustomobject]@{ Success = $false; Error = 'لا يمكن خفض آخر مشرف.' } }
        $updated = @($admins | Where-Object { $_ -ne $TargetUserId })
    }

    # AdminUserIds carries the roster. AdminChatIds keeps only ids it already
    # held, so a promotion can never quietly authorize a whole group chat.
    $chatIds = @(@(Get-JsonProp $config 'AdminChatIds') | Where-Object { [long]$_ -gt 0 } |
            ForEach-Object { [long]$_ } | Where-Object { $updated -contains $_ })
    $config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @($updated) -Force
    $config | Add-Member -NotePropertyName 'AdminChatIds' -NotePropertyValue @($chatIds) -Force
    Save-Config
    return [pscustomobject]@{ Success = $true; Error = '' }
}

function Request-AdminRoleChange {
    <# Never on the first tap: the role carries restart and settings control. #>
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$OwnerUserId, [Parameter(Mandatory)][bool]$IsAdmin)
    $alias = Get-UserDisplayName -UserId $TargetUserId
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'user_role'; TargetUserId = $TargetUserId; UserId = $OwnerUserId; IsAdmin = $IsAdmin }
    $text = if ($IsAdmin) {
        "⚠️ ترقية $alias ($TargetUserId) إلى مشرف؟`nسيستطيع تغيير كل الإعدادات وإعادة تشغيل الجسر وسحب صلاحيات المستخدمين."
    }
    else { "⚠️ خفض $alias ($TargetUserId) إلى مشغّل؟`nستُسحب منه أدوات الإدارة كلها." }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup @{ inline_keyboard = @(, @(
                (New-Button '✅ تأكيد' 'usr:roleconfirm' -Style success), (New-Button '❌ إلغاء' 'menu:usersadmin'))) }
}

function Test-TelegramPrivateChat {
    <# This bridge is intentionally operated through one-to-one chats only.
       Telegram always supplies chat.type; the positive-id fallback keeps old
       saved/test callback payloads compatible without authorizing groups. #>
    param($Chat)
    return Test-BridgePrivateChat -Chat $Chat
}
