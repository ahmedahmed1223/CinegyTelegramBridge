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
        if ([int](Get-JsonProp $request 'StatusCode') -eq 429) {
            $script:TelegramRateLimitHits++
            $retryMs = [math]::Max(1000, [int](Get-JsonProp $request 'RetryAfterMs'))
            return (Add-TelegramOutboxItem -Uri "$apiBase/sendDocument" -Form $form -DueAt (Get-Date).AddMilliseconds($retryMs) -Attempts 0)
        }
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
        $json = $script:UserProfiles | ConvertTo-Json -Depth 5
        if (-not (Write-BridgeValidatedJson -Path $script:userProfilesFile -Json $json)) {
            throw 'Validated JSON write failed.'
        }
        $script:UserProfilesDirty = $false; $script:LastUserProfilesFlush = Get-Date
        return $true
    }
    catch { Write-BridgeLog "Could not write user-profiles.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Update-DeadChatsSweep {
    <#
        P6: a quarantine that sits for thirty days is a decision nobody will
        ever make - the operator moved on, the chat moved on. It leaves with
        an audit line, not silently, and the file is rewritten only when
        something actually left.

        Throttled like every other tick watchdog: the only step in
        Invoke-BridgeTick that scanned its whole collection and parsed a date
        per entry on every single tick instead of every few minutes.
    #>
    if (((Get-Date) - $script:LastDeadChatsSweep).TotalMinutes -lt 10) { return }
    $script:LastDeadChatsSweep = Get-Date
    $cutoff = (Get-Date).AddDays(-30)
    $removed = @()
    foreach ($id in @($script:DeadChats.Keys)) {
        $stamp = [datetime]::MinValue
        if ([datetime]::TryParse([string](Get-JsonProp $script:DeadChats[$id] 'Since'), [ref]$stamp) -and $stamp -lt $cutoff) {
            $script:DeadChats.Remove($id)
            $removed += $id
        }
    }
    if ($removed.Count -eq 0) { return }
    Save-DeadChats | Out-Null
    foreach ($id in $removed) { Add-AuditEntry "💀 أُرشفت محادثة ميتة $id بعد 30 يومًا بلا قرار" }
    Write-BridgeLog "Archived $($removed.Count) dead chat(s) stale past 30 days"
}

function Import-DeadChats {
    if (-not (Test-Path -LiteralPath $script:deadChatsFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:deadChatsFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            $script:DeadChats[$prop.Name] = @{
                Since = [string](Get-JsonProp $prop.Value 'Since'); LastError = [string](Get-JsonProp $prop.Value 'LastError')
                Strikes = [int](Get-JsonProp $prop.Value 'Strikes')
            }
        }
    }
    catch { Write-BridgeLog "Could not read dead-chats.json: $($_.Exception.Message)" 'WARN' }
}

function Save-DeadChats {
    try {
        $json = $script:DeadChats | ConvertTo-Json -Depth 5
        if (-not (Write-BridgeValidatedJson -Path $script:deadChatsFile -Json $json)) {
            throw 'Validated JSON write failed.'
        }
        return $true
    }
    catch { Write-BridgeLog "Could not write dead-chats.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Test-DeadChat {
    param([Parameter(Mandatory)][long]$ChatId)
    return $script:DeadChats.ContainsKey([string]$ChatId)
}

function Register-TelegramSendFailure {
    <#
        D1: three strikes from Telegram itself, then quarantine. Only 401 and
        403 count: a 400 is the bridge's own malformed message, and
        quarantining on it would hide our bugs behind a roster. A 429 is a
        capacity problem with its own retry queue, not a dead chat.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [int]$StatusCode = 0, [string]$ErrorText = '')
    if ($StatusCode -notin @(401, 403)) { return }
    $id = [string]$ChatId
    if ($script:DeadChats.ContainsKey($id)) { return }
    $strikes = 0
    [int]::TryParse([string]$script:DeadChatStrikes[$id], [ref]$strikes) | Out-Null
    $strikes++
    if ($strikes -lt 3) {
        $script:DeadChatStrikes[$id] = $strikes
        return
    }
    $script:DeadChatStrikes.Remove($id) | Out-Null
    $short = $ErrorText.Trim()
    if ($short.Length -gt 160) { $short = $short.Substring(0, 160) + '…' }
    $script:DeadChats[$id] = @{ Since = (Get-Date).ToString('o'); LastError = $short; Strikes = $strikes }
    Save-DeadChats | Out-Null
    $name = Get-UserDisplayName -UserId $ChatId
    $isAdmin = Test-Admin -ChatId $ChatId -UserId $ChatId
    Write-BridgeLog "Chat $ChatId quarantined as dead after $strikes delivery failures ($StatusCode)" 'WARN'
    Add-AuditEntry "💀 محادثة ميتة: $name ($ChatId) — أُوقف الإرسال لها بعد $(Get-ArabicCountNoun -Count $strikes -One 'إخفاق' -Two 'إخفاقان' -Few 'إخفاقات' -Many 'إخفاقًا' -EnglishOne 'failure' -EnglishMany 'failures')"
    # An admin that stops receiving is itself an outage: everyone else hears
    # urgently, because a held quiet-hours digest about missing alerts is how
    # a dead admin stays dead unnoticed.
    $keyboard = @{ inline_keyboard = @(, @((New-Button '✅ إعادة تفعيل' "deadchat:un:$ChatId"))) }
    Send-AdminBroadcast -Text "💀 المحادثة «$name» ($ChatId) لا تستقبل من البوت ($StatusCode) — أُوقف الإرسال لها. أعد التفعيل بعد إصلاحها أو اسحب صلاحيتها من شاشة المستخدمين." `
        -ReplyMarkup $keyboard -Urgent:$isAdmin
}

function Restore-DeadChat {
    <#
        Releases a chat back to live sending. Strikes restart from zero: if
        the block is still there, three fresh failures re-quarantine it and
        say so again, rather than trusting a button press over Telegram.
    #>
    param([Parameter(Mandatory)][long]$ChatId)
    $id = [string]$ChatId
    $script:DeadChats.Remove($id) | Out-Null
    $script:DeadChatStrikes.Remove($id) | Out-Null
    Save-DeadChats | Out-Null
    Write-BridgeLog "Chat $ChatId released from dead-chat quarantine by administrator"
    Add-AuditEntry "💀 أُعيد تفعيل المحادثة $ChatId"
}

function Test-DeadChatDelivery {
    <#
        One-shot reachability probe for a quarantined chat. Bypasses the
        Test-DeadChat send guard on purpose: the whole point is asking
        Telegram once whether the block is gone. A success restores the chat
        exactly like the manual button; a failure only refreshes LastError
        and answers the tapping administrator - no broadcast, no strikes -
        so a wrong guess costs one message, not another outage notice.
    #>
    param([Parameter(Mandatory)][long]$TargetChatId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $id = [string]$TargetChatId
    if (-not $script:DeadChats.ContainsKey($id)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'هذه المحادثة ليست محجورة الآن.' -ReplyMarkup (Get-UsersAdminKeyboard -ViewerUserId $UserId)
        return
    }
    $probe = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendMessage" -Method Post `
        -Body @{ chat_id = $TargetChatId; text = '🔔 اختبار استلام من البوت — تجاهل هذه الرسالة.' } `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 1
    if ($probe.Success) {
        Restore-DeadChat -ChatId $TargetChatId
        Add-AuditEntry "🔍 اختبار المحادثة $TargetChatId ناجح — أُعيد التفعيل بواسطة $(Format-UserAuditActor -UserId $UserId)"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ المحادثة $TargetChatId تستقبل — أُعيد تفعيلها."
    }
    else {
        $short = ([string]$probe.Error).Trim()
        if ($short.Length -gt 160) { $short = $short.Substring(0, 160) + '…' }
        $script:DeadChats[$id].LastError = $short
        Save-DeadChats | Out-Null
        Write-BridgeLog "Dead-chat probe to $TargetChatId failed: $($probe.Error)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "❌ ما زالت لا تستقبل — بقيت محجورة.`n$short"
    }
    Show-DeadChatsScreen -ChatId $ChatId -UserId $UserId
}

function Show-DeadChatsScreen {
    <#
        D1: the quarantine roster. Each row names who stopped receiving, when,
        and why - with a release button beside it (T-12's rule: a warning
        carries its fix) and a revoke for the ones that should never come
        back. Releasing restarts strikes from zero rather than trusting the
        button: three fresh failures re-quarantine and say so again.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $ids = @($script:DeadChats.Keys | Sort-Object { [long]$_ })
    $back = @{ inline_keyboard = @(, @((New-Button '⬅️ المستخدمون' 'menu:usersadmin'))) }
    if ($ids.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text '💀 لا محادثات ميتة — كل القائمة تستقبل.' -ReplyMarkup $back
        return
    }
    # Buttons grow three per chat, so the rows are paged like the users roster -
    # the text itself already pages through Send-TelegramPagedText, but the
    # keyboard would not, and the paging gate fails exactly that.
    $window = Get-BridgePageWindow -ItemCount $ids.Count -Page $Page -PageSize 5
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>💀 محادثات ميتة ($($ids.Count))</b>")
    $rows = @()
    foreach ($index in $window.StartIndex..$window.EndIndex) {
        $id = [string]$ids[$index]
        $target = 0L
        [long]::TryParse($id, [ref]$target) | Out-Null
        $entry = $script:DeadChats[$id]
        $since = ''
        $stamp = [datetime]::MinValue
        if ([datetime]::TryParse([string](Get-JsonProp $entry 'Since'), [ref]$stamp)) { $since = $stamp.ToString('MM-dd HH:mm') }
        $name = ConvertTo-TelegramHtmlText (Get-UserDisplayName -UserId $target)
        $why = ConvertTo-TelegramHtmlText ([string](Get-JsonProp $entry 'LastError'))
        $lines.Add("• $name (<code>$id</code>) · منذ $since`n  $why")
        $rows += , @((New-Button '✅ إعادة تفعيل' "deadchat:un:$target"), (New-Button '🔍 اختبار' "deadchat:probe:$target"), (New-Button '⛔ سحب الصلاحية' "deadchat:revoke:$target"))
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button '⬅️ السابق' "deadchat:page:$($window.Page - 1)") }
        if ($window.HasNext) { $pager += (New-Button 'التالي ➡️' "deadchat:page:$($window.Page + 1)") }
        $rows += , $pager
    }
    $rows += , @((New-Button '⬅️ المستخدمون' 'menu:usersadmin'))
    Send-TelegramPagedText -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup @{ inline_keyboard = $rows } -ParseMode HTML
}

function Write-UserApprovalMetadata {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ApprovedByUserId,
        [AllowNull()]$RequestedAt = $null)
    # RequestedAt as well as AddedAt: the pair is the wait, and the wait is
    # what an administrator is judging when they look back at how requests
    # were handled. It lives here rather than only in the audit file because
    # this is the record that outlives log rotation.
    $asked = if ($RequestedAt -is [datetime]) { $RequestedAt.ToString('o') } else { [string]$RequestedAt }
    $script:UserProfiles[[string]$TargetUserId] = @{ AddedAt = (Get-Date).ToString('o'); AddedByUserId = $ApprovedByUserId; LastActivityAt = $null; RequestedAt = $asked }
    $script:UserProfilesDirty = $true
    return Save-UserProfiles -Force
}

function Test-AirNoticeMuted {
    <# Whether this person asked not to hear about graphics going on air.
       Their own answer, kept in their profile beside when they were added: it
       survives a restart, and it is not a setting an administrator has to
       maintain on their behalf. #>
    param([Parameter(Mandatory)][long]$UserId)
    $id = [string]$UserId
    if (-not $script:UserProfiles.ContainsKey($id)) { return $false }
    return [bool](Get-JsonProp $script:UserProfiles[$id] 'MutedAirNotices')
}

function Set-AirNoticeMuted {
    <# Sets or clears it, creating the profile if this is the first thing
       anyone has recorded about them. #>
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][bool]$Muted)
    $id = [string]$UserId
    if (-not $script:UserProfiles.ContainsKey($id)) {
        $script:UserProfiles[$id] = @{ AddedAt = ''; AddedByUserId = 0L; LastActivityAt = '' }
    }
    Set-JsonProp -Object $script:UserProfiles[$id] -Name 'MutedAirNotices' -Value $Muted
    $script:UserProfilesDirty = $true
    Save-UserProfiles -Force | Out-Null
    return $Muted
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
    <# Through the validated writer like every other state file: the old
       hand-rolled temp+move used a shared .tmp name, never read the file back,
       and left no .bak - so a truncated write moved straight into place and
       Import-AccessGuard forgot every blocked chat on the next start. #>
    try {
        $json = $script:AccessGuard | ConvertTo-Json -Depth 5
        if (-not (Write-BridgeValidatedJson -Path $script:accessGuardFile -Json $json)) {
            throw 'Validated JSON write failed.'
        }
        return $true
    }
    catch { Write-BridgeLog "Could not write access-guard.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Test-ChatBlocked {
    param([Parameter(Mandatory)][long]$ChatId)
    return $script:AccessGuard.Blocked.ContainsKey([string]$ChatId)
}

function Update-AccessGuardSweep {
    <#
        Forgets a blocked stranger after AccessGuardKeepDays.

        Nothing ever left this file except by a manual unblock, so a bot that
        strangers find accumulates one entry per stranger for the life of the
        installation. Zero keeps them forever, which is the right answer for a
        station that wants a permanent deny list - so the default forgets, and
        turning it off is a decision rather than an oversight.
    #>
    if (((Get-Date) - $script:LastAccessGuardSweep).TotalHours -lt 12) { return }
    $script:LastAccessGuardSweep = Get-Date
    $days = Get-SettingInt 'AccessGuardKeepDays' 0
    if ($days -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$days)
    $removed = @()
    foreach ($id in @($script:AccessGuard.Blocked.Keys)) {
        $stamp = [datetime]::MinValue
        # Unreadable stamp means no evidence it is old - keep the block.
        if (-not [datetime]::TryParse([string](Get-JsonProp $script:AccessGuard.Blocked[$id] 'At'), [ref]$stamp)) { continue }
        if ($stamp -lt $cutoff) { $removed += $id }
    }
    # Attempts is swept on its own evidence, not on Blocked's. Every chat that
    # ever knocked gets an Attempts entry - written before the rate limit is
    # even tested - while only the ones an administrator rejected reach Blocked.
    # So the loop above could never reach the common case: a stranger who is
    # never blocked had no removal path at all, and the docstring's own
    # complaint ("one entry per stranger for the life of the installation") was
    # fixed for the smaller half of the problem.
    #
    # Get-AccessAttempt already treats an entry older than its 24h window as
    # spent, so anything past the cutoff is carrying no decision.
    $staleAttempts = @()
    foreach ($id in @($script:AccessGuard.Attempts.Keys)) {
        if ($script:AccessGuard.Blocked.Contains($id)) { continue }
        $firstAt = [datetime]::MinValue
        if (-not [datetime]::TryParse([string](Get-JsonProp $script:AccessGuard.Attempts[$id] 'FirstAt'), [ref]$firstAt)) { continue }
        if ($firstAt -lt $cutoff) { $staleAttempts += $id }
    }
    if ($removed.Count -eq 0 -and $staleAttempts.Count -eq 0) { return }
    foreach ($id in $removed) {
        $script:AccessGuard.Blocked.Remove($id)
        $script:AccessGuard.Attempts.Remove($id)
    }
    foreach ($id in $staleAttempts) { $script:AccessGuard.Attempts.Remove($id) }
    if (Save-AccessGuard) {
        $parts = @()
        if ($removed.Count -gt 0) { $parts += "$($removed.Count) access block(s)" }
        if ($staleAttempts.Count -gt 0) { $parts += "$($staleAttempts.Count) spent attempt record(s)" }
        Write-BridgeLog "Forgot $($parts -join ' and ') older than $days day(s)."
    }
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
    <# Same validated writer as every other state file. A torn write here is
       an authorization regression, not just lost state: Import-DisabledUsers
       warns and moves on, so every disabled account comes back enabled. #>
    try {
        $json = $script:DisabledUserIds | ConvertTo-Json -Depth 3
        if (-not (Write-BridgeValidatedJson -Path $script:disabledUsersFile -Json $json)) {
            throw 'Validated JSON write failed.'
        }
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
    # Through the formatter, not "$ageMinutes د". An account last seen on
    # Thursday read as "منذ 4320 د" - a number the reader has to divide twice
    # before it means anything, on the very screen where they are deciding
    # whether someone still needs access.
    $ago = Format-DurationMinutes -Minutes $ageMinutes
    if ($ageMinutes -lt $ActiveWithinMinutes) {
        return [pscustomobject]@{ State = 'recent'; Label = "🟢 نشط حديثًا · منذ $ago"; AgeMinutes = $ageMinutes }
    }
    return [pscustomobject]@{ State = 'idle'; Label = "🟠 خامل · منذ $ago"; AgeMinutes = $ageMinutes }
}

function Get-UserActivitySummaryText {
    param([datetime]$Now = (Get-Date))
    $windowMinutes = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))
    $lines = [System.Collections.Generic.List[string]]::new()
    # parse_mode=HTML. The caveat under the title is the whole reason this
    # screen can mislead - "متصل" here means "spoke to the bot recently", not
    # "online" - so it is italic and set apart from the list rather than
    # reading as one more line of it. Aliases are typed by an administrator
    # and escaped like any other human text.
    $lines.Add("<b>👥 نشاط المستخدمين التقريبي</b> · النافذة <code>$windowMinutes</code> د")
    $lines.Add('<i>Telegram لا يوفّر حالة اتصال لحظية؛ الحالة مبنية على آخر تفاعل مع البوت.</i>')
    $rows = @(@(Get-AuthorizedUsers) | ForEach-Object {
            $activity = Get-UserActivityStatus -LastActivityAt ([string]$_.LastActivityAt) -Now $Now -ActiveWithinMinutes $windowMinutes
            "• <b>$(ConvertTo-TelegramHtmlText ([string]$_.Alias))</b>: $(ConvertTo-TelegramHtmlText ([string]$activity.Label))"
        })
    # Not quoted: this list is the whole screen, not evidence under a verdict
    # the screen has already given. The bar is reserved for detail an operator
    # may skip, and a bar around the only thing here would teach them nothing
    # - the one job a consistent mark has.
    if ($rows.Count -gt 0) {
        $lines.Add('')
        $lines.Add($rows -join "`n")
    }
    return ($lines -join "`n")
}

function Get-UserActivityDetailText {
    param([Parameter(Mandatory)][long]$TargetUserId, [datetime]$Now = (Get-Date))
    $user = @(Get-AuthorizedUsers | Where-Object { [long]$_.UserId -eq $TargetUserId } | Select-Object -First 1)
    if ($user.Count -eq 0) { return '<i>المستخدم لم يعد ضمن قائمة المصرح لهم.</i>' }
    $windowMinutes = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))
    $activity = Get-UserActivityStatus -LastActivityAt ([string]$user[0].LastActivityAt) -Now $Now -ActiveWithinMinutes $windowMinutes
    return "<b>👤 $(ConvertTo-TelegramHtmlText ([string]$user[0].Alias))</b>`n$(ConvertTo-TelegramHtmlText ([string]$activity.Label))`n<i>الحالة تقريبية حسب آخر تفاعل مع البوت؛ Telegram لا يوفّر اتصالًا لحظيًا للبوت.</i>"
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

    # Both lists, because they answer two halves of one question:
    # AdminUserIds is who may decide, AdminChatIds is who is told there is
    # something to decide. Keeping the second frozen made every promotion
    # produce an administrator who could approve a stranger into the on-air
    # controls and was never sent a single request - which is what happened
    # here, and was found only when the person it happened to mentioned that
    # he had never seen one.
    #
    # The original caution still holds and is what the > 0 test is for: a
    # group chat's id is negative, so no promotion can turn one into an
    # audience for administrator notices. A private chat's id is the user's
    # own id, which is the only kind being added.
    $chatIds = @(@(@(Get-JsonProp $config 'AdminChatIds') | ForEach-Object { [long]$_ }) + @($updated) |
            Where-Object { $_ -gt 0 } | Where-Object { $updated -contains $_ } | Sort-Object -Unique)
    $config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @($updated) -Force
    $config | Add-Member -NotePropertyName 'AdminChatIds' -NotePropertyValue @($chatIds) -Force
    Save-Config
    return [pscustomobject]@{ Success = $true; Error = '' }
}

function Repair-AdminChatIds {
    <#
        Brings AdminChatIds up to date with AdminUserIds, once, at startup.

        Every administrator promoted before this was written is in the roster
        and in no notification list, and cannot discover that by any means
        available to them: what they are missing is messages that were never
        sent. Fixing the promotion path leaves them where they are, so the
        repair has to run over the state that already exists.

        Only ever adds, and only ids that already hold administrator
        authority; a negative id - a group - is never added, for the same
        reason promotion will not add one.

        Returns the ids it added, so the caller can say so in the log rather
        than changing a configuration file silently.
    #>
    $admins = @(@(Get-JsonProp $config 'AdminUserIds') | ForEach-Object { [long]$_ } | Where-Object { $_ -gt 0 })
    $chats = @(@(Get-JsonProp $config 'AdminChatIds') | ForEach-Object { [long]$_ } | Where-Object { $_ -gt 0 })
    $missing = @($admins | Where-Object { $chats -notcontains $_ } | Sort-Object -Unique)
    if ($missing.Count -eq 0) { return @() }
    $config | Add-Member -NotePropertyName 'AdminChatIds' -NotePropertyValue @(@($chats + $missing) | Sort-Object -Unique) -Force
    Save-Config
    return @($missing)
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
