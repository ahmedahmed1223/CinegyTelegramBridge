#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Update-PendingExpiry {
    $stateTimeout = Get-SettingInt 'PendingStateTimeoutMinutes' 1
    foreach ($chatId in @($script:PendingState.Keys)) {
        $state = $script:PendingState[$chatId]
        if (((Get-Date) - $state.StartedAt).TotalMinutes -ge $stateTimeout) {
            Clear-PendingState -ChatId ([long]$chatId)
            Write-BridgeLog "Expired abandoned '$($state.Mode)' flow for chat $chatId" "WARN"
            Send-TelegramMessage -ChatId ([long]$chatId) -Text "⌛ انتهت مهلة الإدخال ولم يُنفّذ شيء. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId ([long]$chatId))
        }
    }

    $approvalTimeout = Get-SettingInt 'PendingApprovalExpiryHours' 1
    foreach ($chatId in @($script:PendingApprovals.Keys)) {
        if (((Get-Date) - $script:PendingApprovals[$chatId].RequestedAt).TotalHours -ge $approvalTimeout) {
            $script:PendingApprovals.Remove($chatId)
            Write-BridgeLog "Expired stale access request from $chatId"
        }
    }

    # Rides along here because it is the same kind of housekeeping - who may
    # still use the bot - and it rate-limits itself to once a day.
    Update-DormantUsers | Out-Null
}

function Update-PostShowQueue {
    <# Fires the deferred postbox write that follows a SHOW. Failures are
       logged but never surfaced to the operator: the SHOW itself already
       succeeded and was already confirmed in chat. #>
    if ($script:PostShowQueue.Count -eq 0) { return }
    $due = @($script:PostShowQueue | Where-Object { (Get-Date) -ge $_.At })
    foreach ($item in $due) {
        $script:PostShowQueue.Remove($item) | Out-Null
        $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress `
            -AirChannelNumber $config.AirChannelNumber -Values $item.Values -TimeoutSec (Get-AirTimeout)
        if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air post-show POSTBOX ($($item.Key)): success=$($result.Success) $($result.Xml)" }
        if (-not $result.Success) {
            Write-BridgeLog "Post-show postbox write failed for '$($item.Key)': $($result.Error)" "WARN"
        }
    }
}

function Save-AutoHideQueue {
    try {
        $payload = @($script:AutoHideQueue | ForEach-Object {
                $at = [datetimeoffset]$_.At
                [ordered]@{
                    Layer       = [int](Get-JsonProp $_ 'Layer')
                    At          = $at.ToString('o')
                    ChatId      = [long](Get-JsonProp $_ 'ChatId')
                    UserId      = [long](Get-JsonProp $_ 'UserId')
                    TemplateKey = [string](Get-JsonProp $_ 'TemplateKey')
                    ActiveId    = [string](Get-JsonProp $_ 'ActiveId')
                    ActiveIdConfirmed = [bool](Get-JsonProp $_ 'ActiveIdConfirmed')
                }
            })
        $json = ConvertTo-Json -InputObject $payload -Depth 4
        if (-not (Write-ValidatedJsonState -Path $script:autoHideFile -Json $json)) { throw 'validated state write failed' }
        return $true
    }
    catch {
        Write-BridgeLog "Could not write autohide.json: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Import-AutoHideQueue {
    try {
        $read = Read-ValidatedJsonState -Path $script:autoHideFile -AsHashtable
        if (-not $read) { return }
        $restored = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($raw in @($read.Data)) {
            if (-not $raw) { continue }
            $layer = 0
            if (-not [int]::TryParse([string](Get-JsonProp $raw 'Layer'), [ref]$layer) -or $layer -le 0) { continue }
            $at = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse([string](Get-JsonProp $raw 'At'), [ref]$at)) { continue }
            $restored.Add(@{
                    Layer       = $layer
                    At          = $at
                    ChatId      = [long](Get-JsonProp $raw 'ChatId')
                    UserId      = [long](Get-JsonProp $raw 'UserId')
                    TemplateKey = [string](Get-JsonProp $raw 'TemplateKey')
                    ActiveId    = [string](Get-JsonProp $raw 'ActiveId')
                    ActiveIdConfirmed = [bool](Get-JsonProp $raw 'ActiveIdConfirmed')
                })
        }
        $script:AutoHideQueue = $restored
        Write-BridgeLog "Restored $($script:AutoHideQueue.Count) auto-hide timer(s) from autohide.json."
    }
    catch { Write-BridgeLog "Could not read autohide.json: $($_.Exception.Message)" 'WARN' }
}

function Set-AutoHideTimer {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][int]$Seconds,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [string]$TemplateKey = '',
        [string]$ActiveId = '',
        [bool]$ActiveIdConfirmed = $false
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($Seconds -le 0) { return $false }
    $previous = @($script:AutoHideQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq $Layer })
    for ($i = $script:AutoHideQueue.Count - 1; $i -ge 0; $i--) {
        if ([int](Get-JsonProp $script:AutoHideQueue[$i] 'Layer') -eq $Layer) { $script:AutoHideQueue.RemoveAt($i) }
    }
    $timer = @{
            Layer       = $Layer
            At          = [datetimeoffset]::Now.AddSeconds($Seconds)
            ChatId      = $ChatId
            UserId      = $UserId
            TemplateKey = $TemplateKey
            ActiveId    = $ActiveId
            ActiveIdConfirmed = $ActiveIdConfirmed
        }
    $script:AutoHideQueue.Add($timer)
    if (Save-AutoHideQueue) { return $true }
    $script:AutoHideQueue.Remove($timer) | Out-Null
    foreach ($oldTimer in $previous) { $script:AutoHideQueue.Add($oldTimer) }
    return $false
}

function Get-AutoHideTargetDecision {
    param(
        [Parameter(Mandatory)][hashtable]$Timer,
        [AllowNull()]$LiveStatus = $null
    )
    $layer = [int](Get-JsonProp $Timer 'Layer')
    if (-not $script:OnAir.ContainsKey($layer)) {
        return [pscustomobject]@{ ShouldHide = $false; Reason = "الطبقة $layer لم تعد مسجلة على الهواء." }
    }
    $current = $script:OnAir[$layer]
    $timerId = [string](Get-JsonProp $Timer 'ActiveId')
    $currentId = [string](Get-JsonProp $current 'ActiveId')
    if ($timerId -and $currentId -and
        -not $timerId.Trim().Trim('{', '}').Equals($currentId.Trim().Trim('{', '}'), [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ShouldHide = $false; Reason = "الطبقة $layer تغيّرت منذ ضبط المؤقت." }
    }
    $timerKey = [string](Get-JsonProp $Timer 'TemplateKey')
    $currentKey = [string](Get-JsonProp $current 'Key')
    if ($timerKey -and $currentKey -and
        -not $timerKey.Equals($currentKey, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ShouldHide = $false; Reason = "القالب على الطبقة $layer تغيّر منذ ضبط المؤقت." }
    }
    if ($null -ne $LiveStatus) {
        if (-not [bool](Get-JsonProp $LiveStatus 'Success')) {
            return [pscustomobject]@{ ShouldHide = $false; Reason = "تعذّر التحقق من حالة Cinegy للطبقة $layer." }
        }
        if ($LiveStatus.IsOnAir -ne $true) {
            return [pscustomobject]@{ ShouldHide = $false; Reason = "الطبقة $layer لم تعد على الهواء." }
        }
        $liveId = ([string](Get-JsonProp $LiveStatus 'ActiveId')).Trim().Trim('{', '}')
        $savedId = $timerId.Trim().Trim('{', '}')
        if ([string]::IsNullOrWhiteSpace($liveId) -or
            [string]::IsNullOrWhiteSpace($savedId) -or
            -not $liveId.Equals($savedId, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ ShouldHide = $false; Reason = "الطبقة $layer تغيّرت منذ ضبط المؤقت." }
        }
    }
    return [pscustomobject]@{ ShouldHide = $true; Reason = '' }
}

function Update-AutoHideQueue {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    if ($script:AutoHideQueue.Count -eq 0) { return }
    $due = @($script:AutoHideQueue | Where-Object { [datetimeoffset]$_.At -le $Now })
    foreach ($item in $due) {
        $index = $script:AutoHideQueue.IndexOf($item)
        $script:AutoHideQueue.RemoveAt($index)
        if (-not (Save-AutoHideQueue)) {
            $script:AutoHideQueue.Insert($index, $item)
            Write-BridgeLog "Deferred due auto-hide on layer $($item.Layer): could not persist timer consumption." 'WARN'
            continue
        }
        $decision = Get-AutoHideTargetDecision -Timer $item
        if ($decision.ShouldHide -and [bool](Get-JsonProp $item 'ActiveIdConfirmed')) {
            $liveStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
                -AirChannelNumber $config.AirChannelNumber -Layer ([int]$item.Layer) `
                -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
            $decision = Get-AutoHideTargetDecision -Timer $item -LiveStatus $liveStatus
        }
        if (-not $decision.ShouldHide) {
            Write-BridgeLog "Skipped stale auto-hide timer on layer $($item.Layer): $($decision.Reason)" 'WARN'
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⚠️ لم يُنفَّذ المؤقت للطبقة $($item.Layer): $($decision.Reason)"
            continue
        }
        Write-BridgeLog "Auto-hiding layer $($item.Layer) (timed show by user $($item.UserId))"
        if (Invoke-HideLayer -Layer ([int]$item.Layer) -ChatId ([long]$item.ChatId) -UserId ([long]$item.UserId) -Quiet) {
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⏱ تم الإخفاء التلقائي للطبقة $($item.Layer)."
        }
        else {
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⚠️ فشل الإخفاء التلقائي للطبقة $($item.Layer) - أخفها يدويًا."
        }
    }
}

function Save-TemplateReminderQueue {
    try {
        $payload = @($script:TemplateReminderQueue | ForEach-Object {
                [ordered]@{
                    ReminderId  = [string](Get-JsonProp $_ 'ReminderId')
                    Stage       = [string](Get-JsonProp $_ 'Stage')
                    Layer       = [int](Get-JsonProp $_ 'Layer')
                    At          = ([datetimeoffset](Get-JsonProp $_ 'At')).ToString('o')
                    ChatId      = [long](Get-JsonProp $_ 'ChatId')
                    UserId      = [long](Get-JsonProp $_ 'UserId')
                    TemplateKey = [string](Get-JsonProp $_ 'TemplateKey')
                    ActiveId    = [string](Get-JsonProp $_ 'ActiveId')
                    ActiveIdConfirmed = [bool](Get-JsonProp $_ 'ActiveIdConfirmed')
                    Minutes     = [int](Get-JsonProp $_ 'Minutes')
                    FollowUpMinutes = [int](Get-JsonProp $_ 'FollowUpMinutes')
                }
            })
        $json = ConvertTo-Json -InputObject $payload -Depth 4
        if (-not (Write-ValidatedJsonState -Path $script:templateReminderFile -Json $json)) { throw 'validated state write failed' }
        return $true
    }
    catch {
        Write-BridgeLog "Could not write template-reminders.json: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Import-TemplateReminderQueue {
    try {
        $read = Read-ValidatedJsonState -Path $script:templateReminderFile -AsHashtable
        if (-not $read) { return }
        $restored = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($raw in @($read.Data)) {
            $layer = 0; $minutes = 0; $at = [datetimeoffset]::MinValue
            if (-not $raw -or
                -not [int]::TryParse([string](Get-JsonProp $raw 'Layer'), [ref]$layer) -or $layer -le 0 -or
                -not [int]::TryParse([string](Get-JsonProp $raw 'Minutes'), [ref]$minutes) -or $minutes -le 0 -or $minutes -gt 1440 -or
                -not [datetimeoffset]::TryParse([string](Get-JsonProp $raw 'At'), [ref]$at)) { continue }
            $reminderId = [string](Get-JsonProp $raw 'ReminderId')
            if ([string]::IsNullOrWhiteSpace($reminderId)) { $reminderId = ([guid]::NewGuid().ToString('N')).Substring(0, 12) }
            $stage = [string](Get-JsonProp $raw 'Stage')
            if ($stage -notin @('initial', 'followup')) { $stage = 'initial' }
            $restored.Add(@{
                    ReminderId = $reminderId; Stage = $stage
                    Layer = $layer; At = $at; ChatId = [long](Get-JsonProp $raw 'ChatId'); UserId = [long](Get-JsonProp $raw 'UserId')
                    TemplateKey = [string](Get-JsonProp $raw 'TemplateKey'); ActiveId = [string](Get-JsonProp $raw 'ActiveId'); Minutes = $minutes
                    ActiveIdConfirmed = [bool](Get-JsonProp $raw 'ActiveIdConfirmed')
                    FollowUpMinutes = [int](Get-JsonProp $raw 'FollowUpMinutes')
                })
        }
        $script:TemplateReminderQueue = $restored
        Write-BridgeLog "Restored $($script:TemplateReminderQueue.Count) personal template reminder(s) from template-reminders.json."
    }
    catch { Write-BridgeLog "Could not read template-reminders.json: $($_.Exception.Message)" 'WARN' }
}

function Remove-TemplateRemindersForLayer {
    param([Parameter(Mandatory)][int]$Layer)
    $removed = $false
    for ($i = $script:TemplateReminderQueue.Count - 1; $i -ge 0; $i--) {
        if ([int](Get-JsonProp $script:TemplateReminderQueue[$i] 'Layer') -eq $Layer) {
            $script:TemplateReminderQueue.RemoveAt($i)
            $removed = $true
        }
    }
    if ($removed) { Save-TemplateReminderQueue | Out-Null }
    return $removed
}

function Set-TemplateReminder {
    param(
        [Parameter(Mandatory)][hashtable]$Template,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [string]$ActiveId = '',
        [bool]$ActiveIdConfirmed = $false
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $layer = [int](Get-JsonProp $Template 'Layer')
    $minutes = [int](Get-JsonProp $Template 'ReminderMinutes')
    if ($layer -le 0) { return $false }
    $previous = @($script:TemplateReminderQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq $layer })
    for ($i = $script:TemplateReminderQueue.Count - 1; $i -ge 0; $i--) {
        if ([int](Get-JsonProp $script:TemplateReminderQueue[$i] 'Layer') -eq $layer) { $script:TemplateReminderQueue.RemoveAt($i) }
    }
    if ([bool](Get-JsonProp $Template 'LongRunning') -or $minutes -le 0) {
        if (Save-TemplateReminderQueue) { return $false }
        foreach ($item in $previous) { $script:TemplateReminderQueue.Add($item) }
        return $false
    }
    $script:TemplateReminderQueue.Add(@{
            # Deliver to the person who launched the template, not to the
            # originating group. In a private chat both ids are identical.
            ReminderId = ([guid]::NewGuid().ToString('N')).Substring(0, 12); Stage = 'initial'
            Layer = $layer; At = [datetimeoffset]::Now.AddMinutes($minutes); ChatId = $UserId; UserId = $UserId
            TemplateKey = [string](Get-JsonProp $Template 'Key'); ActiveId = $ActiveId; Minutes = $minutes
            ActiveIdConfirmed = $ActiveIdConfirmed; FollowUpMinutes = 0
        })
    if (Save-TemplateReminderQueue) { return $true }
    $script:TemplateReminderQueue.RemoveAt($script:TemplateReminderQueue.Count - 1)
    foreach ($item in $previous) { $script:TemplateReminderQueue.Add($item) }
    Save-TemplateReminderQueue | Out-Null
    return $false
}

function Get-TemplateReminderTargetDecision {
    param([Parameter(Mandatory)][hashtable]$Reminder)
    $layer = [int](Get-JsonProp $Reminder 'Layer')
    if (-not $script:OnAir.ContainsKey($layer)) { return [pscustomobject]@{ ShouldNotify = $false; Reason = 'لم تعد الطبقة على الهواء.' } }
    $current = $script:OnAir[$layer]
    $savedId = [string](Get-JsonProp $Reminder 'ActiveId')
    $currentId = [string](Get-JsonProp $current 'ActiveId')
    if ($savedId -and $currentId -and -not $savedId.Trim().Trim('{', '}').Equals($currentId.Trim().Trim('{', '}'), [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ShouldNotify = $false; Reason = 'تغيّر المشهد على الطبقة.' }
    }
    $savedKey = [string](Get-JsonProp $Reminder 'TemplateKey')
    $currentKey = [string](Get-JsonProp $current 'Key')
    if ($savedKey -and $currentKey -and -not $savedKey.Equals($currentKey, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ShouldNotify = $false; Reason = 'تغيّر القالب على الطبقة.' }
    }
    $store = Get-TemplateStore
    if ($store.Map.ContainsKey($savedKey)) {
        $template = $store.Map[$savedKey]
        if ([bool](Get-JsonProp $template 'LongRunning')) {
            return [pscustomobject]@{ ShouldNotify = $false; Reason = 'القالب أصبح Long run.' }
        }
        if ([int](Get-JsonProp $template 'ReminderMinutes') -le 0) {
            return [pscustomobject]@{ ShouldNotify = $false; Reason = 'أُوقف تنبيه الظهور للقالب.' }
        }
    }
    return [pscustomobject]@{ ShouldNotify = $true; Reason = '' }
}

function Update-TemplateReminderQueue {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    if ($script:TemplateReminderQueue.Count -eq 0) { return }
    foreach ($item in @($script:TemplateReminderQueue | Where-Object { [datetimeoffset](Get-JsonProp $_ 'At') -le $Now })) {
        $index = $script:TemplateReminderQueue.IndexOf($item)
        $script:TemplateReminderQueue.RemoveAt($index)
        if (-not (Save-TemplateReminderQueue)) {
            $script:TemplateReminderQueue.Insert($index, $item)
            Write-BridgeLog "Deferred due personal reminder '$([string](Get-JsonProp $item 'ReminderId'))': could not persist queue consumption." 'WARN'
            continue
        }
        $decision = Get-TemplateReminderTargetDecision -Reminder $item
        if (-not $decision.ShouldNotify) {
            Write-BridgeLog "Discarded personal reminder for '$($item.TemplateKey)' on layer $($item.Layer): $($decision.Reason)"
            continue
        }
        $stage = [string](Get-JsonProp $item 'Stage')
        if ($stage -eq 'followup') {
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "🔔 متابعة: لم يتم تأكيد معالجة تنبيه '$($item.TemplateKey)' على الطبقة $($item.Layer)، وما زال ظاهرًا."
            Write-BridgeLog "Sent personal reminder follow-up for '$($item.TemplateKey)' to user $($item.UserId)."
            continue
        }
        $reminderId = [string](Get-JsonProp $item 'ReminderId')
        if ([string]::IsNullOrWhiteSpace($reminderId)) { $reminderId = ([guid]::NewGuid().ToString('N')).Substring(0, 12); $item.ReminderId = $reminderId }
        $ackKeyboard = @{ inline_keyboard = @(, @((New-Button '✅ تمت المعالجة' "remack:$reminderId"))) }
        Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⏰ تنبيه: مرّت $($item.Minutes) دقيقة منذ إظهار '$($item.TemplateKey)' على الطبقة $($item.Layer)، وما زال ظاهرًا." -ReplyMarkup $ackKeyboard
        Write-BridgeLog "Sent personal reminder for '$($item.TemplateKey)' to user $($item.UserId)."
        $followUpMinutes = [math]::Min(1440, (Get-SettingInt 'TemplateReminderFollowUpMinutes' 0))
        if ($followUpMinutes -gt 0) {
            $item.Stage = 'followup'
            $item.FollowUpMinutes = $followUpMinutes
            $item.At = $Now.AddMinutes($followUpMinutes)
            $script:TemplateReminderQueue.Add($item)
            Save-TemplateReminderQueue | Out-Null
        }
    }
}

function Confirm-TemplateReminder {
    param(
        [Parameter(Mandatory)][string]$ReminderId,
        [Parameter(Mandatory)][long]$UserId,
        [ref]$FailureReason
    )
    if ($null -ne $FailureReason) { $FailureReason.Value = '' }
    $item = @($script:TemplateReminderQueue | Where-Object {
            [string](Get-JsonProp $_ 'ReminderId') -eq $ReminderId -and [long](Get-JsonProp $_ 'UserId') -eq $UserId
        } | Select-Object -First 1)
    if ($item.Count -eq 0) {
        if ($null -ne $FailureReason) { $FailureReason.Value = 'not_found' }
        return $false
    }
    $index = $script:TemplateReminderQueue.IndexOf($item[0])
    $script:TemplateReminderQueue.RemoveAt($index)
    if (-not (Save-TemplateReminderQueue)) {
        $script:TemplateReminderQueue.Insert($index, $item[0])
        if ($null -ne $FailureReason) { $FailureReason.Value = 'persistence' }
        Write-BridgeLog "Could not persist acknowledgement for personal template reminder '$ReminderId'; restored pending follow-up." 'WARN'
        return $false
    }
    Write-BridgeLog "User $UserId acknowledged personal template reminder '$ReminderId'."
    return $true
}

function Update-Heartbeat {
    if (-not (Get-Setting 'HeartbeatEnabled')) { return }
    $now = Get-Date
    if ($now.Date -eq $script:LastHeartbeatDate) { return }
    if ($now.Hour -ne (Get-SettingInt 'HeartbeatHour' 0)) { return }
    $script:LastHeartbeatDate = $now.Date
    $store = Get-TemplateStore
    Send-AdminBroadcast -Text "💚 الجسر يعمل. القوالب: $($store.Order.Count)، البث: $(Get-LiveRelayStatusText)"
    Write-BridgeLog "Heartbeat sent to admins"
}

function Get-BridgeStatsText {
    <# Operational numbers an administrator asks for when something feels off:
       how long this instance has been up, what it has done, and whether
       Telegram has been throttling it. Uptime is the one that matters most -
       a bridge that has been up for eleven minutes has been restarting. #>
    $now = Get-Date
    $uptime = $now - $script:BridgeStartedAt
    $counters = $script:AirOperationCounters
    $total = [int]$counters.Success + [int]$counters.Failed + [int]$counters.Blocked

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("📈 أرقام التشغيل — v$($script:BridgeVersion)")
    $lines.Add('')
    $lines.Add("مدة التشغيل: $([int]$uptime.TotalDays) ي $($uptime.Hours) س $($uptime.Minutes) د")
    $lines.Add("منذ: $($script:BridgeStartedAt.ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add('')
    $lines.Add("عمليات الهواء: $total (✅ $($counters.Success) · ❌ $($counters.Failed) · ⛔ $($counters.Blocked))")
    $lines.Add("رسائل رفضها Telegram لتجاوز الحد (429): $($script:TelegramRateLimitHits)")
    $lines.Add("رسائل مؤجلة أسقطها حد طابور Telegram: $($script:TelegramOutboxDropped)")
    $lines.Add("اتصال Telegram: $($script:RuntimeState.Monitoring.TelegramConnectionState)")
    $lines.Add("صحة Cinegy: $($script:RuntimeState.Monitoring.CinegyHealthState)")

    $lastBeat = if ($script:LastHeartbeatDate -gt [datetime]::MinValue) { $script:LastHeartbeatDate.ToString('yyyy-MM-dd') } else { 'لم تُرسل بعد' }
    $lines.Add("آخر نبضة يومية: $lastBeat")
    $lines.Add("مشاهد مسجّلة على الهواء: $($script:OnAir.Count)")
    return ($lines -join "`n")
}

function Get-OnAirShareText {
    <# A plain-text summary an operator can forward to the director instead of
       retyping what is up. Deliberately plain: it has to survive being pasted
       into another app, so no buttons and no layout that depends on Telegram. #>
    $now = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("حالة الهواء — $($now.ToString('yyyy-MM-dd HH:mm'))")
    if ($script:OnAir.Count -eq 0) { $lines.Add('لا شيء على الهواء.') }
    else {
        foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
            $record = $script:OnAir[$layer]
            $age = if ($record.At -is [datetime]) { " (منذ $(Format-Duration -Seconds ([int]($now - $record.At).TotalSeconds)))" } else { '' }
            $lines.Add("- طبقة ${layer}: $($record.Key)$age")
        }
    }
    $lines.Add("Cinegy: $($script:RuntimeState.Monitoring.CinegyHealthState)")
    return ($lines -join "`n")
}

function Read-AuditRecords {
    <# Reads recent audit entries. audit.jsonl is already the permanent,
       structured record of every control action, so /digest and /who read it
       rather than inventing a second log to drift out of sync with it. #>
    param([int]$MaxLines = 500)
    # Reads back into the archives when the active file is short. Without
    # this the first digest after a rotation would report an empty morning:
    # the history did not go anywhere, it only changed file.
    $lines = @()
    if (Test-Path -LiteralPath $script:auditFile) {
        $lines = @(Get-Content -LiteralPath $script:auditFile -Tail $MaxLines -ErrorAction SilentlyContinue)
    }
    if ($lines.Count -lt $MaxLines) {
        foreach ($archive in @(Get-AuditArchiveFiles)) {
            $needed = $MaxLines - $lines.Count
            if ($needed -le 0) { break }
            $lines = @(@(Get-Content -LiteralPath $archive.FullName -Tail $needed -ErrorAction SilentlyContinue)) + $lines
        }
    }

    $records = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    }
    return @($records)
}

function Get-AuditOperatorName {
    <# Audit user ids arrive as strings and are sometimes absent. Returns an
       empty string rather than a misleading "0" so callers can omit the name
       instead of naming nobody. #>
    param([string]$UserId)
    $parsed = 0L
    if (-not [long]::TryParse($UserId, [ref]$parsed) -or $parsed -eq 0) { return '' }
    return [string](Get-UserDisplayName -UserId $parsed)
}

function Get-OperatorTally {
    <# Who did it, and how many each. One operator is named inline; several are
       broken down, because "20×" alone does not tell a supervisor taking over
       whether one person was busy or four collided on the same graphic. #>
    param([object[]]$Records)
    $byUser = @(@($Records) | Group-Object -Property UserId | Sort-Object Count -Descending)
    $named = @($byUser | Where-Object { Get-AuditOperatorName -UserId ([string]$_.Name) })
    if ($named.Count -eq 0) { return @{ Single = ''; Breakdown = '' } }
    if ($named.Count -eq 1) {
        return @{ Single = (Get-AuditOperatorName -UserId ([string]$named[0].Name)); Breakdown = '' }
    }
    $parts = foreach ($entry in $named) {
        "$(Get-AuditOperatorName -UserId ([string]$entry.Name)) $($entry.Count)"
    }
    return @{ Single = ''; Breakdown = ($parts -join ' · ') }
}

function Get-MissedEventsBlocks {
    <#
        The handover screen as blocks, with what is on air FIRST.

        The text version ends on it, after the shows, the removals, the
        notable activity and the failures. That is the wrong order for the
        one screen somebody opens while walking into a gallery: the first
        question is always what is on the screen right now, and it was the
        last line they reached.

        Failures stay open for the same reason - a failure is usually why
        this screen was opened at all - while the general activity, read only
        when something needs tracing, folds away.
    #>
    param([int]$Hours = 12, [AllowNull()][object[]]$Records = $null)
    # Wrapped around the whole if: the expression emits its result to the
    # pipeline, which unwraps a one-item array back to a scalar, and .Count
    # on that throws under StrictMode.
    $records = @(if ($null -ne $Records) { $Records } else { Get-MissedEventsRecords -Hours $Hours })

    $blocks = @(@{ type = 'heading'; text = "🕘 ماذا فاتني — آخر $Hours ساعة"; size = 3 })
    # On air first: it is the question this screen is opened to answer.
    $blocks += @{ type = 'paragraph'; text = $(if ($script:OnAir.Count -eq 0) { '⚫️ لا شيء على الهواء الآن' }
            else { "🔴 على الهواء: $(@($script:OnAir.Keys | Sort-Object | ForEach-Object { $script:OnAir[$_].Key }) -join '، ')" }) }
    $blocks += @{ type = 'divider' }

    if ($records.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لا شيء مسجّل في هذه الفترة.' }
        return $blocks
    }

    $airOps = @($records | Where-Object { $_.Action -in @('SHOW', 'HIDE', 'EXIT') })
    $shows = @($airOps | Where-Object { $_.Action -eq 'SHOW' -and $_.Target })
    if ($shows.Count -gt 0) {
        $blocks += @{ type = 'heading'; text = "📺 ما عُرض — $($shows.Count)"; size = 5 }
        # Four columns, as everywhere else here: the width is divided evenly,
        # so a fifth would cost the graphic's name a fifth of the screen.
        $cells = @(, @(
                @{ text = 'القالب'; is_header = $true }
                @{ text = 'مرات'; is_header = $true }
                @{ text = 'آخرها'; is_header = $true }
                @{ text = 'المشغّل'; is_header = $true }
            ))
        foreach ($group in ($shows | Group-Object -Property Target | Sort-Object Count -Descending | Select-Object -First 8)) {
            $tally = Get-OperatorTally -Records @($group.Group)
            $who = if ($tally.Breakdown) { [string]$tally.Breakdown } elseif ($tally.Single) { [string]$tally.Single } else { '—' }
            $cells += , @(
                @{ text = [string]$group.Name }
                @{ text = [string]$group.Count }
                @{ text = @($group.Group)[-1].When.ToString('HH:mm') }
                @{ text = $who }
            )
        }
        $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    }

    $removals = @($airOps | Where-Object { $_.Action -in @('HIDE', 'EXIT') })
    if ($removals.Count -gt 0) {
        $newest = @($removals)[-1]
        $lastWho = Get-AuditOperatorName -UserId $newest.UserId
        $line = "🙈 إخفاء وخروج: $($removals.Count) — آخرها $($newest.When.ToString('HH:mm'))"
        if ($lastWho) { $line += " — $lastWho" }
        $blocks += @{ type = 'paragraph'; text = $line }
    }

    # Failures stay open: they are usually why the screen was opened.
    $failures = @($records | Where-Object { $_.Result -eq 'failed' })
    $blocked = @($records | Where-Object { $_.Result -eq 'blocked' })
    if ($failures.Count -gt 0 -or $blocked.Count -gt 0) {
        $blocks += @{ type = 'heading'; text = "⚠️ فشل: $($failures.Count) · مرفوض: $($blocked.Count)"; size = 5 }
        foreach ($failure in @($failures | Select-Object -Last 3)) {
            $detail = if ($failure.Message) { $failure.Message } else { 'بلا تفصيل' }
            $blocks += @{ type = 'paragraph'; text = "$($failure.When.ToString('HH:mm')) — $($failure.Action) $($failure.Target): $detail" }
        }
    }

    $activity = @($records | Where-Object { -not $_.Action -and $_.Message })
    $notable = @($activity | Where-Object { $_.Message -match '📰|⚙️|👤|🔓|🚨|♻️' })
    if ($notable.Count -gt 0) {
        $inner = @(@($notable | Select-Object -Last 8) | ForEach-Object {
                @{ type = 'paragraph'; text = "$($_.When.ToString('HH:mm')) — $($_.Message)" }
            })
        $blocks += @{ type = 'details'; summary = "📌 أحداث تستحق الانتباه ($($notable.Count))"; blocks = $inner }
    }

    $blocks += @{ type = 'divider' }
    $blocks += @{ type = 'paragraph'; text = "Cinegy: $($script:RuntimeState.Monitoring.CinegyHealthState) · Telegram: $($script:RuntimeState.Monitoring.TelegramConnectionState)" }
    return $blocks
}

function Get-MissedEventsRecords {
    <# The window's audit records, normalised. Extracted so the text screen
       and the block screen read exactly the same set - two readers of one
       log that filter it separately are two answers waiting to disagree. #>
    param([int]$Hours = 12)
    $since = (Get-Date).ToUniversalTime().AddHours(-[math]::Max(1, $Hours))
    return @(Read-AuditRecords -MaxLines 1500 | ForEach-Object {
            $record = $_
            $when = Read-AuditRecordStamp -Record $record
            if (-not $when -or $when.ToUniversalTime() -lt $since) { return }
            [pscustomobject]@{
                When    = $when
                Action  = (Get-AuditRecordField -Record $record -Name 'action')
                Target  = (Get-AuditRecordField -Record $record -Name 'target')
                Result  = (Get-AuditRecordField -Record $record -Name 'result')
                Message = (Get-AuditRecordField -Record $record -Name 'message')
                UserId  = (Get-AuditRecordField -Record $record -Name 'userId')
            }
        })
}

function Get-MissedEventsText {
    <#
        What happened while nobody was looking.

        The first version counted verbs - "SHOW 23, other 73" - which tells an
        operator taking over a shift nothing: not which graphic, not who, not
        when, and the largest bucket was simply everything without an action
        field. This answers what is actually asked at a handover: what went to
        air, who did it, what failed, and what is up right now.
    #>
    param([int]$Hours = 12)
    # One reader for both screens: records are written by a dozen call
    # sites and carry only the fields each cares about, so under StrictMode
    # a record without an "action" key would take down the whole digest -
    # which is exactly the screen opened when something has already gone
    # wrong. Two readers filtering one log separately are two answers
    # waiting to disagree.
    $records = @(Get-MissedEventsRecords -Hours $Hours)

    # parse_mode=HTML. This is the screen an operator opens at handover, and
    # it was one flat column of forty-odd lines with two rows of "━━━" drawn
    # across it. The section headings are bold so the four questions it
    # answers - what went to air, what came off, what is worth knowing, what
    # failed - can be found without reading every line, and each clock time is
    # a <code> span so the digits stay left-to-right beside the Arabic.
    #
    # Everything a person typed is escaped: template names, operator display
    # names, and the audit messages, which are free text from a dozen call
    # sites.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>🕘 ماذا فاتني</b> — آخر <code>$Hours</code> ساعة")
    if ($records.Count -eq 0) {
        $lines.Add('<i>لا شيء مسجّل في هذه الفترة.</i>')
        return ($lines -join "`n")
    }



    # Grouped by graphic rather than by verb: an operator cares which template
    # moved, not that eleven HIDEs happened to something unnamed.
    $airOps = @($records | Where-Object { $_.Action -in @('SHOW', 'HIDE', 'EXIT') })
    $shows = @($airOps | Where-Object { $_.Action -eq 'SHOW' -and $_.Target })
    if ($shows.Count -gt 0) {
        $operatorCount = @($shows | Group-Object -Property UserId).Count
        $lines.Add('')
        $header = "<b>📺 ما عُرض</b> — <code>$($shows.Count)</code> عرضًا"
        if ($operatorCount -gt 1) { $header += " · <code>$operatorCount</code> مشغّلين" }
        $lines.Add($header)
        foreach ($group in ($shows | Group-Object -Property Target | Sort-Object Count -Descending | Select-Object -First 6)) {
            $newest = @($group.Group)[-1]
            $stampText = $newest.When.ToString('HH:mm')
            $times = if ($group.Count -gt 1) { "<code>$($group.Count)×</code> · آخرها <code>$stampText</code>" } else { "<code>$stampText</code>" }
            $tally = Get-OperatorTally -Records @($group.Group)
            $target = ConvertTo-TelegramHtmlText ([string]$group.Name)
            if ($tally.Breakdown) {
                # Several people touched the same graphic: "20×" alone hides
                # whether one operator was busy or four collided on it.
                $lines.Add("• <b>$target</b> — $times")
                $lines.Add("   ↳ <i>$(ConvertTo-TelegramHtmlText ([string]$tally.Breakdown))</i>")
            }
            else {
                $lines.Add("• <b>$target</b> — $times — <i>$(ConvertTo-TelegramHtmlText ([string]$tally.Single))</i>")
            }
        }
    }

    $removals = @($airOps | Where-Object { $_.Action -in @('HIDE', 'EXIT') })
    if ($removals.Count -gt 0) {
        $newest = @($removals)[-1]
        $lastWho = Get-AuditOperatorName -UserId $newest.UserId
        $line = "<b>🙈 إخفاء وخروج</b>: <code>$($removals.Count)</code> — آخرها <code>$($newest.When.ToString('HH:mm'))</code>"
        if ($lastWho) { $line += " — <i>$(ConvertTo-TelegramHtmlText ([string]$lastWho))</i>" }
        $lines.Add($line)
        $removalTally = Get-OperatorTally -Records $removals
        if ($removalTally.Breakdown) { $lines.Add("   ↳ <i>$(ConvertTo-TelegramHtmlText ([string]$removalTally.Breakdown))</i>") }
    }

    # Activity lines are already written for a human, so they are shown rather
    # than counted.
    $activity = @($records | Where-Object { -not $_.Action -and $_.Message })
    $notable = @($activity | Where-Object { $_.Message -match '📰|⚙️|👤|🔓|🚨|♻️' })
    if ($notable.Count -gt 0) {
        $lines.Add('')
        $lines.Add('<b>📌 أحداث تستحق الانتباه</b>')
        # A blockquote, because this is quoted material - lines the bridge
        # wrote elsewhere, shown here rather than summarised. Telegram draws
        # the bar, which is what marks them as not this screen's own words.
        $noted = @(@($notable | Select-Object -Last 5) | ForEach-Object {
                "• <code>$($_.When.ToString('HH:mm'))</code> — $(ConvertTo-TelegramHtmlText ([string]$_.Message))"
            })
        $lines.Add("<blockquote>$($noted -join "`n")</blockquote>")
    }

    $failures = @($records | Where-Object { $_.Result -eq 'failed' })
    $blocked = @($records | Where-Object { $_.Result -eq 'blocked' })
    if ($failures.Count -gt 0 -or $blocked.Count -gt 0) {
        $lines.Add('')
        # Kept apart on purpose: a rejection is a permission answer and a
        # failure is a fault, and they were one number until 7.68.0.
        # Bold and code side by side rather than nested: the two cannot be
        # combined on the same characters, and Telegram refuses the whole
        # message rather than dropping one of them.
        $lines.Add("<b>⚠️ فشل:</b> <code>$($failures.Count)</code> · <b>مرفوض:</b> <code>$($blocked.Count)</code>")
        foreach ($failure in @($failures | Select-Object -Last 3)) {
            $detail = if ($failure.Message) { [string]$failure.Message } else { 'بلا تفصيل' }
            $lines.Add("• <code>$($failure.When.ToString('HH:mm'))</code> — $(ConvertTo-TelegramHtmlText ([string]$failure.Action)) <b>$(ConvertTo-TelegramHtmlText ([string]$failure.Target))</b>: $(ConvertTo-TelegramHtmlText $detail)")
        }
    }

    # What is true right now, under everything that already happened - the
    # digest is read at a handover, and the last thing the person taking over
    # needs is the current state, not the history.
    $lines.Add('')
    $nowLine = if ($script:OnAir.Count -eq 0) { '⚫️ لا شيء على الهواء الآن' }
    else {
        $live = @($script:OnAir.Keys | Sort-Object | ForEach-Object { ConvertTo-TelegramHtmlText ([string]$script:OnAir[$_].Key) })
        "🔴 <b>على الهواء</b>: $($live -join '، ')"
    }
    $lines.Add("<blockquote>$nowLine
Cinegy: <code>$(ConvertTo-TelegramHtmlText ([string]$script:RuntimeState.Monitoring.CinegyHealthState))</code> · Telegram: <code>$(ConvertTo-TelegramHtmlText ([string]$script:RuntimeState.Monitoring.TelegramConnectionState))</code></blockquote>")
    return ($lines -join "`n")
}

function Get-TemplateHistoryText {
    <# Who used a template, and when. The answer already exists in the audit
       trail; it just was not reachable without opening a file on the playout
       machine, which nobody does mid-shift. #>
    param([Parameter(Mandatory)][string]$Query, [int]$MaxResults = 10)
    $needle = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($needle)) { return 'اكتب اسم القالب بعد الأمر، مثل: /who الانتخابات' }

    $hits = @(Read-AuditRecords -MaxLines 2000 | Where-Object {
            [string]$_.target -and ([string]$_.target).IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        } | Select-Object -Last $MaxResults)

    # parse_mode=HTML, and the needle is escaped before anything else: it is
    # typed straight into the chat by whoever ran /who, so it is the most
    # directly person-shaped string on any screen here.
    $needleHtml = ConvertTo-TelegramHtmlText $needle
    if ($hits.Count -eq 0) { return "<i>لا يوجد سجل لاستخدام «$needleHtml» ضمن ما هو محفوظ.</i>" }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>👤 من استخدم «$needleHtml»</b>")
    $lines.Add('')
    foreach ($hit in $hits) {
        $stamp = [datetime]::MinValue
        $when = if ([datetime]::TryParse([string]$hit.timestampUtc, [ref]$stamp)) { $stamp.ToLocalTime().ToString('MM-dd HH:mm') } else { '؟' }
        $lines.Add("• <code>$when</code> — <b>$(ConvertTo-TelegramHtmlText (Get-UserDisplayName -UserId ([long]$hit.userId)))</b> — $(ConvertTo-TelegramHtmlText ([string]$hit.action)) (<i>$(ConvertTo-TelegramHtmlText ([string]$hit.result))</i>)")
    }
    return ($lines -join "`n")
}

function Test-RepeatedShow {
    <#
        Flags a template pushed unusually often in a short window.

        Three of the same graphic within an hour is almost always a paste
        slip or a double tap, not editorial intent - a common newsroom error
        that nobody notices until it is on air twice. Asking costs a tap and
        catches it; it never blocks the push.
    #>
    param([Parameter(Mandatory)][string]$Key, [datetime]$Now = (Get-Date))
    $threshold = Get-SettingInt 'RepeatWarningCount' 0
    if ($threshold -le 1) { return $false }
    $windowMinutes = [math]::Max(1, (Get-SettingInt 'RepeatWarningWindowMinutes' 1))

    if (-not $script:RecentShowTimes.ContainsKey($Key)) { $script:RecentShowTimes[$Key] = @() }
    $cutoff = $Now.AddMinutes(-$windowMinutes)
    $times = @(@($script:RecentShowTimes[$Key]) | Where-Object { $_ -is [datetime] -and $_ -ge $cutoff })
    $times += $Now
    $script:RecentShowTimes[$Key] = $times
    return ($times.Count -ge $threshold)
}

function Update-NewsDraftExpiry {
    <#
        Drops a news draft that has gone stale, and says why.

        A draft records the hash of the live ticker file when it was started,
        and publishing refuses if the file changed since - correctly, because
        publishing would otherwise silently discard whatever was written in
        between. But nothing ever expired the draft, so one left open
        overnight became permanently unpublishable: every attempt was refused
        as a conflict, and the operator saw their edits simply never appear.

        NewsDraftTimeoutMinutes existed as a setting and was read by nothing.
        It is enforced here.
    #>
    $timeout = Get-SettingInt 'NewsDraftTimeoutMinutes' 0
    if ($timeout -le 0) { return }
    $draft = $script:NewsTickerDraft
    if (-not $draft) { return }

    $updatedAt = [datetime]::MinValue
    $stamp = [string](Get-JsonProp $draft 'UpdatedAt')
    if (-not [datetime]::TryParse($stamp, [ref]$updatedAt)) { return }
    if (((Get-Date) - $updatedAt).TotalMinutes -lt $timeout) { return }

    $owner = [long](Get-JsonProp $draft 'OwnerChatId')
    $items = @(Get-JsonProp $draft 'Items')
    $count = $items.Count
    Remove-NewsTickerDraft
    Write-BridgeLog "Expired an abandoned news draft ($count item(s), idle for $timeout+ minutes)" 'WARN'
    if ($owner -gt 0) {
        Send-TelegramMessage -ChatId $owner -Text "⌛ انتهت صلاحية مسودة شريط الأخبار ($count خبرًا) بعد $(Format-DurationMinutes -Minutes $timeout) بلا تعديل، ولم يُنشر شيء.`nابدأ مسودة جديدة لتعمل على النص الحالي."
        # Handed back, not merely counted. An unpublished draft is somebody's
        # work, and telling an operator how many items they just lost is worse
        # than useless. The lock hand-over has returned the text since 5.5,
        # and an expiry destroys exactly as much.
        if ($count -gt 0) {
            $numbered = @(for ($i = 0; $i -lt $count; $i++) { "$($i + 1). $($items[$i])" })
            Send-TelegramPagedText -ChatId $owner -Text ("📝 أخبار المسودة المنتهية، انسخها إن أردت:`n" + ($numbered -join "`n"))
        }
    }
}

function Get-CancelReasonLabel {
    param([Parameter(Mandatory)][string]$Reason)
    switch ($Reason) {
        'template' { 'قالب خاطئ' }
        'timing' { 'توقيت خاطئ' }
        'director' { 'طلب المخرج' }
        'other' { 'سبب آخر' }
        default { $Reason }
    }
}

function Get-CancelReasonKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button '🎬 قالب خاطئ' 'cancelreason:template'), (New-Button '⏱ توقيت خاطئ' 'cancelreason:timing') )
            , @( (New-Button '🎧 طلب المخرج' 'cancelreason:director'), (New-Button '❔ سبب آخر' 'cancelreason:other') )
            , @( (New-Button 'تخطٍّ' 'menu') )
        ) }
}

function Save-CancelReasons {
    $path = Join-Path $script:logDir 'cancel-reasons.json'
    try { return (Write-BridgeValidatedJson -Path $path -Json ($script:CancelReasons | ConvertTo-Json -Depth 4)) }
    catch { Write-BridgeLog "Could not save cancel reasons: $($_.Exception.Message)" 'WARN'; return $false }
}

function Import-CancelReasons {
    $path = Join-Path $script:logDir 'cancel-reasons.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $read = Read-BridgeValidatedJson -Path $path -AsHashtable
        if ($read -and $read.Data) { $script:CancelReasons = [hashtable]$read.Data }
    }
    catch { Write-BridgeLog "Could not read cancel-reasons.json: $($_.Exception.Message)" 'WARN' }
}

function Add-CancelReason {
    <#
        Records why an operator pulled something straight back off air.

        An undo count on its own says the shift went badly; it does not say
        what to fix. Separating "wrong template" from "wrong timing" from "the
        director asked" is the difference between a training gap, a rundown
        problem, and ordinary editorial change - and only the operator knows
        which, for about ten seconds after they press undo.

        Counts only. No field text, no user ids, nothing that would turn the
        file into a second audit log.
    #>
    param([Parameter(Mandatory)][string]$Reason, [Parameter(Mandatory)][long]$UserId, [string]$Key = '')
    if (-not $script:CancelReasons.ContainsKey($Reason)) { $script:CancelReasons[$Reason] = 0 }
    $script:CancelReasons[$Reason] = [int]$script:CancelReasons[$Reason] + 1
    Write-BridgeLog "Cancel reason '$Reason' recorded for '$Key' by user $UserId"
    Add-AuditEntry "📝 سبب الإلغاء: $(Get-CancelReasonLabel -Reason $Reason) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Save-CancelReasons | Out-Null
}

function Get-UsageDigestText {
    <# What the shift actually did, from counters the bridge already keeps.
       Meant to be read on a phone, so it is a handful of lines: the busiest
       templates, the operation totals, and anything that got refused. #>
    param([int]$TopCount = 5)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('📊 ملخص الاستخدام')

    $ranked = @($script:UsageCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopCount)
    if ($ranked.Count -eq 0) { $lines.Add('• لم تُستخدم أي قوالب بعد.') }
    else {
        $lines.Add('')
        $lines.Add('الأكثر استخدامًا:')
        $rank = 0
        foreach ($item in $ranked) {
            $rank++
            $lastUsed = if ($script:TemplateLastUsed.ContainsKey($item.Key)) {
                " · آخر مرة $(([datetime]$script:TemplateLastUsed[$item.Key]).ToLocalTime().ToString('MM-dd HH:mm'))"
            }
            else { '' }
            $lines.Add("$rank. $($item.Key) — $($item.Value)$lastUsed")
        }
    }

    $counters = $script:AirOperationCounters
    $total = [int]$counters.Success + [int]$counters.Failed + [int]$counters.Blocked
    $lines.Add('')
    $lines.Add("عمليات الهواء منذ آخر تشغيل: $total")
    # The scheduled weekly digest cannot use the process counters: a restart
    # at handover made a quiet week look empty. Audit is the durable source.
    $week = Get-ReportRecords -From ((Get-Date).Date.AddDays(-6)) -To (Get-Date) -EventName 'air_control'
    $weeklyOperations = @($week.Records).Count
    $completedDays = 7
    $dailyAverage = [math]::Round($weeklyOperations / $completedDays, 1)
    $lines.Add("تقدير أسبوعي: $weeklyOperations عملية في آخر 7 أيام · متوسط $dailyAverage يوميًا")
    $lines.Add("✅ ناجحة $($counters.Success) · ❌ فاشلة $($counters.Failed) · ⛔ مرفوضة $($counters.Blocked)")
    if ([int]$counters.Failed -gt 0 -or [int]$counters.Blocked -gt 0) {
        $lines.Add('راجع 📜 السجل لمعرفة سبب الفشل أو الرفض.')
    }
    if ($script:CancelReasons.Count -gt 0) {
        $lines.Add('')
        $lines.Add('أسباب التراجع المسجّلة:')
        foreach ($reason in ($script:CancelReasons.Keys | Sort-Object)) {
            $lines.Add("• $(Get-CancelReasonLabel -Reason $reason): $($script:CancelReasons[$reason])")
        }
    }
    return ($lines -join "`n")
}

function Update-UsageDigest {
    <# Sends the digest to administrators on a chosen weekday, at the same hour
       the daily heartbeat uses. Guarded by date like the heartbeat, so a
       restart during that hour cannot send it twice. #>
    if (-not (Get-Setting 'UsageDigestEnabled')) { return }
    $now = Get-Date
    if ($now.Date -eq $script:LastUsageDigestDate) { return }
    if ([int]$now.DayOfWeek -ne (Get-SettingInt 'UsageDigestDayOfWeek' 0)) { return }
    if ($now.Hour -ne (Get-SettingInt 'HeartbeatHour' 0)) { return }
    $script:LastUsageDigestDate = $now.Date
    Send-AdminBroadcast -Text (Get-UsageDigestText)
    Write-BridgeLog 'Usage digest sent to admins'
}

function Update-StaleOnAirWatchdog {
    <# Tells the administrators when the bridge has been claiming a graphic is
       on air for implausibly long, so a record that outlived its scene is
       noticed in minutes rather than discovered by someone looking at the
       output. Alerts once per layer; the flag clears when the record goes. #>
    $threshold = Get-SettingInt 'StaleOnAirAlertHours' 0
    if ($threshold -le 0) { return }
    $now = Get-Date
    if (($now - $script:RuntimeState.Monitoring.LastStaleOnAirCheck).TotalMinutes -lt 5) { return }
    $script:RuntimeState.Monitoring.LastStaleOnAirCheck = $now

    # Drop flags for layers that are no longer tracked, so a re-shown layer
    # can alert again later instead of staying silent for ever.
    foreach ($layer in @($script:StaleOnAirAlerted)) {
        if (-not $script:OnAir.ContainsKey([int]$layer)) { $script:StaleOnAirAlerted.Remove([int]$layer) | Out-Null }
    }

    $stale = @(Get-BridgeStaleOnAirLayers -OnAir $script:OnAir -Now $now `
            -ThresholdHours $threshold -AlreadyAlerted @($script:StaleOnAirAlerted))
    # Filtered after the time arithmetic, not before: only a candidate is worth
    # a Cinegy round trip, and there are rarely more than one or two.
    $stale = @($stale | Where-Object { -not (Test-LongRunningOnAir -Layer $_.Layer -Key $_.Key) })
    if ($stale.Count -eq 0) { return }

    foreach ($item in $stale) { $script:StaleOnAirAlerted.Add([int]$item.Layer) | Out-Null }
    $lines = @($stale | ForEach-Object { "• طبقة $($_.Layer) · $($_.Key) — منذ $($_.Hours) ساعة" })
    Write-BridgeLog "Stale on-air record(s) reported to administrators: $(@($stale | ForEach-Object { $_.Layer }) -join ', ')" 'WARN'
    Send-AdminBroadcast -Urgent -Text ("⚠️ سجلات على الهواء منذ وقت طويل — تحقّق من الشاشة:`n" + ($lines -join "`n") +
        "`nإن كانت الشاشة خالية فاضغط إخفاء على الطبقة لتصفية السجل.")
}

function Test-LongRunningOnAir {
    <#
        Is this graphic meant to stay up, rather than forgotten up there?

        The staleness alert measured elapsed time alone, so the news ticker -
        genuinely on air, its Active Id matching the record exactly - was
        reported to administrators as a stale record five times over two days.
        An alert that cries wolf on correct behaviour teaches operators to
        ignore it, which costs more than the alert ever saved.

        Two independent answers, either of which is enough:

          * The template says so. An operator who knows the ticker runs all
            day can mark it LongRunning and never think about it again.
          * Cinegy says so. The engine already carries the item's intended
            Duration - a ticker is scheduled as 24:00:00 with ManualEnd - and
            that is the authoritative answer, needing no configuration and
            unable to drift out of date.

        Anything Cinegy cannot answer stays stale-able: an unreachable engine
        must never silence the alert, because "cannot check" and "fine" are
        different things.
    #>
    param([Parameter(Mandatory)][int]$Layer, [string]$Key = '')

    $template = $null
    $store = Get-TemplateStore
    if ($Key -and $store.Map.ContainsKey($Key)) {
        $template = $store.Map[$Key]
        if ($template.ContainsKey('LongRunning') -and [bool]$template.LongRunning) { return $true }
    }
    if (-not (Get-Setting 'RespectCinegyItemDuration')) { return $false }

    try {
        $device = if ($template -and $template.ContainsKey('Device')) { [string]$template.Device } else { '' }
        $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
            -AirChannelNumber $config.AirChannelNumber -Layer $Layer -Device $device `
            -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        if (-not $status.Success -or -not $status.IsOnAir) { return $false }

        $declared = [int]$status.ActiveDurationSeconds
        if ($declared -le 0) { return $false }
        if (-not $script:OnAir.ContainsKey($Layer)) { return $false }
        $record = $script:OnAir[$Layer]
        if ($record.At -isnot [datetime]) { return $false }
        return ((Get-Date) - $record.At).TotalSeconds -lt $declared
    }
    catch {
        Write-BridgeLog "Could not read the declared duration for layer ${Layer}: $($_.Exception.Message)" 'DEBUG'
        return $false
    }
}

function Get-CinegyStateCheckInterval {
    <# Configured interval, widened while Air is unreachable. See
       Get-BridgeCinegyStateBackoff for why the widening exists. #>
    $interval = Get-SettingInt 'CinegyStateCheckSeconds' 1
    return [Math]::Max($interval, [int]$script:RuntimeState.Monitoring.CinegyStateBackoffSeconds)
}

function Get-BridgePermanentGraphics {
    <#
        The graphics that are meant to be on air all the time.

        Declared already, and nowhere new: a template marked longRunning is one
        nobody expects to take down - the channel logo, the news strip - which
        is exactly the set worth noticing the absence of. A second setting
        listing them again would be a second place to forget.
    #>
    $store = Get-TemplateStore
    $graphics = foreach ($key in @($store.Order)) {
        $template = $store.Map[$key]
        if (-not [bool](Get-JsonProp $template 'LongRunning')) { continue }
        $layer = [int](Get-JsonProp $template 'Layer')
        if ($layer -le 0) { continue }
        [pscustomobject]@{ Key = [string]$key; Layer = $layer }
    }
    return @($graphics)
}

function Update-MissingGraphicWatchdog {
    <#
        Says when the logo or the strip is not on air.

        Asked of Cinegy, never of onair.json: the point is to catch a graphic
        that is gone, and it does not matter in the slightest whether it went
        from this bot or from somebody's hand in Air. The bridge's own record
        could only ever describe what the bridge itself did.

        Confirmed before it speaks, because a permanent graphic is legitimately
        down for the seconds it takes to replace one, and an alert on every
        such moment is an alert nobody reads. It says so once when it goes and
        once when it returns: a repeating alarm for a state somebody is already
        dealing with is noise.
    #>
    param([object[]]$LayerStatuses = @())
    if (-not (Get-Setting 'NotifyAdminsOnMissingGraphic')) { return }
    $required = @(Get-BridgePermanentGraphics)
    if ($required.Count -eq 0) { return }
    # Reuse the sweep the layer watchdog has already paid for; read again only
    # when it had nothing to hand over.
    $statuses = @($LayerStatuses)
    if ($statuses.Count -eq 0) { $statuses = @(Get-CinegyLayerDashboard) }
    if ($statuses.Count -eq 0) { return }
    $byLayer = @{}
    foreach ($status in $statuses) {
        $statusLayer = 0
        if ([int]::TryParse([string](Get-JsonProp $status 'Layer'), [ref]$statusLayer)) { $byLayer[$statusLayer] = $status }
    }
    $threshold = [math]::Max(1, (Get-SettingInt 'MissingGraphicConfirmChecks' 2))
    foreach ($graphic in $required) {
        $status = $byLayer[[int]$graphic.Layer]
        # An engine that did not answer is not a graphic that is missing.
        if (-not $status -or -not [bool](Get-JsonProp $status 'Success')) { continue }
        $key = [string]$graphic.Key
        $state = if ($script:MissingGraphicState.ContainsKey($key)) { $script:MissingGraphicState[$key] } else { @{ Misses = 0; Alerted = $false } }
        if ([bool](Get-JsonProp $status 'IsOnAir')) {
            if ([bool]$state.Alerted) {
                Send-AdminBroadcast -Text "✅ عاد «$key» إلى الهواء على $(Get-LayerDisplayName -Layer ([int]$graphic.Layer))." | Out-Null
                Write-BridgeLog "The permanent graphic '$key' is back on layer $($graphic.Layer)."
            }
            $script:MissingGraphicState[$key] = @{ Misses = 0; Alerted = $false }
            continue
        }
        $state.Misses = [int]$state.Misses + 1
        if (-not [bool]$state.Alerted -and [int]$state.Misses -ge $threshold) {
            $state.Alerted = $true
            Write-BridgeLog "The permanent graphic '$key' is not on air on layer $($graphic.Layer) after $($state.Misses) check(s)." 'WARN'
            Send-AdminBroadcast -Text "⚠️ «$key» ليس على الهواء على $(Get-LayerDisplayName -Layer ([int]$graphic.Layer)).`nيُفترض أن يبقى دائمًا؛ أعِده من 📋 القوالب أو من 🎚 الطبقات." | Out-Null
        }
        $script:MissingGraphicState[$key] = $state
    }
}

function Update-CinegyStateWatchdog {
    $now = Get-Date
    if (($now - $script:RuntimeState.Monitoring.LastCinegyStateCheck).TotalSeconds -lt (Get-CinegyStateCheckInterval)) { return }
    $script:RuntimeState.Monitoring.LastCinegyStateCheck = $now

    # With no dashboard and no -DiscoverExternal this verified only the layers
    # the bridge had put up itself, so a graphic somebody started in Cinegy
    # after startup - the news strip, most often - never appeared in the menu
    # and could not be hidden from it. Startup discovered such layers and the
    # status screen discovered them; nothing in between did.
    $discover = [bool](Get-Setting 'DiscoverExternalLayers')
    $layerStatuses = if ($discover) { @(Get-CinegyLayerDashboard) } else { @() }
    $sync = Update-OnAirStateFromCinegy -Reason 'watchdog' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal:$discover
    # Handed the sweep this function has already paid for.
    Update-MissingGraphicWatchdog -LayerStatuses $layerStatuses

    # A layer that could not be verified means the engine did not answer. With
    # nothing tracked there is no request to fail, which counts as reachable.
    $previousBackoff = [int]$script:RuntimeState.Monitoring.CinegyStateBackoffSeconds
    $reachable = @($sync.Failed).Count -eq 0
    $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds = Get-BridgeCinegyStateBackoff `
        -BaseIntervalSeconds (Get-SettingInt 'CinegyStateCheckSeconds' 1) `
        -CurrentBackoffSeconds $previousBackoff -Reachable:$reachable `
        -MaximumSeconds (Get-SettingInt 'CinegyStateBackoffMaxSeconds' 1)
    $newBackoff = [int]$script:RuntimeState.Monitoring.CinegyStateBackoffSeconds
    if ($newBackoff -ne $previousBackoff) {
        $detail = if ($newBackoff -gt 0) { "widened layer reconciliation to ${newBackoff}s after $(@($sync.Failed).Count) unverifiable layer(s)" }
        else { 'restored the configured layer reconciliation interval' }
        Write-BridgeLog "Cinegy state watchdog $detail"
    }

    if ($sync.Removed.Count -gt 0 -and (Get-Setting 'NotifyAdminsOnExternalChange')) {
        Send-AdminBroadcast -Text (Format-ExternalCinegyChangeAlert -Changes @($sync.Changes))
    }
}

function Update-CinegyHealthWatchdog {
    $now = Get-Date
    $interval = Get-SettingInt 'CinegyHealthCheckSeconds' 1
    if (($now - $script:RuntimeState.Monitoring.LastCinegyHealthCheck).TotalSeconds -lt $interval) { return }
    $script:RuntimeState.Monitoring.LastCinegyHealthCheck = $now

    $telemetry = Get-AirTelemetryStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) `
        -FrameLossTolerance (Get-SettingInt 'CinegyFrameLossTolerance' 0) `
        -FrameLossTolerancePercent ([double](Get-Setting 'CinegyFrameLossTolerancePercent')) `
        -ReadErrorRateTolerance ([double](Get-Setting 'CinegyReadErrorRateTolerance'))
    $reading = if (-not $telemetry.Success -or $null -eq $telemetry.Healthy) { 'unreachable' }
    elseif ($telemetry.Healthy) { 'healthy' }
    else { 'unhealthy' }

    $oldState = $script:RuntimeState.Monitoring.CinegyHealthState; $history = $script:HealthHistory.Cinegy

    <#
        One reading does not change the state; several agreeing ones do.

        The tolerance added in 5.6.1 filters the values, and this filters the
        verdict - two different jobs. Even inside tolerance the channel kept
        crossing the line and back, so the log took 332 health transitions,
        23 of them today, on an engine that was fine every time anybody
        looked. A monitor that changes its mind every minute is one operators
        stop reading, which costs more than the outage it was watching for.

        CinegyHealthConfirmChecks readings must agree before the state moves.
        The first reading of a run still counts immediately, because a bridge
        that has just started has no history to be steady about.
    #>
    $confirm = [math]::Max(1, (Get-SettingInt 'CinegyHealthConfirmChecks' 1))
    if ($reading -ne $oldState -and $oldState -ne 'unknown' -and $confirm -gt 1) {
        if ([string]$history.PendingState -eq $reading) { $history.PendingCount = [int]$history.PendingCount + 1 }
        else { $history.PendingState = $reading; $history.PendingCount = 1 }

        if ([int]$history.PendingCount -lt $confirm) {
            Write-BridgeLog "Cinegy reported $reading ($($history.PendingCount)/$confirm) - holding at $oldState" 'DEBUG'
            return
        }
    }
    $history.PendingState = ''; $history.PendingCount = 0

    $newState = $reading
    if ($newState -ne $oldState) { Write-BridgeLog "Cinegy health changed from $oldState to $newState" }
    $script:RuntimeState.Monitoring.CinegyHealthState = $newState
    if ($newState -eq 'healthy') {
        $shouldRecover = [bool]$history.AlertSent
        $history.LastSuccess = $now; $history.FailureCount = 0; $history.OutageStartedAt = $null; $history.AlertSent = $false
        if ($shouldRecover -and (Get-Setting 'NotifyAdminsOnCinegyHealth')) { Send-AdminBroadcast -Text "💚 تعافت صحة Cinegy وعادت القياسات إلى الحالة السليمة." }
        return
    }
    if ([int]$history.FailureCount -eq 0) { $history.OutageStartedAt = $now }
    $history.FailureCount = [int]$history.FailureCount + 1; $history.LastErrorAt = $now
    $history.LastError = if ($newState -eq 'unreachable') { 'تعذّر الوصول' } else { 'قياسات غير سليمة' }
    $threshold = [Math]::Max(1, (Get-SettingInt 'HealthFailureAlertThreshold' 1))
    if ([int]$history.FailureCount -ge $threshold -and -not [bool]$history.AlertSent -and (Get-Setting 'NotifyAdminsOnCinegyHealth')) {
        $history.AlertSent = $true
        $started = ([datetime]$history.OutageStartedAt).ToString('yyyy-MM-dd HH:mm:ss')
        $detail = if ($newState -eq 'unhealthy') { Format-CinegyTelemetryStatus -Telemetry $telemetry } else { 'تعذّر الوصول إلى قياسات صحة Cinegy. تحقق من Air والاتصال بالشبكة.' }
        Send-AdminBroadcast -Text "🔴 تحذير صحة Cinegy بعد $($history.FailureCount) حالات فشل متتالية`nبداية الانقطاع: $started`n$detail"
    }
}

function Set-TelegramConnectionState {
    param([Parameter(Mandatory)][bool]$Connected, [string]$ErrorMessage = '')
    $newState = if ($Connected) { 'connected' } else { 'disconnected' }
    $oldState = $script:RuntimeState.Monitoring.TelegramConnectionState; $history = $script:HealthHistory.Telegram; $now = Get-Date
    if ($newState -ne $oldState) { Write-BridgeLog "Telegram connection changed from $oldState to $newState" }
    $script:RuntimeState.Monitoring.TelegramConnectionState = $newState
    if ($Connected) {
        $shouldRecover = [bool]$history.AlertSent
        $history.LastSuccess = $now; $history.FailureCount = 0; $history.OutageStartedAt = $null; $history.AlertSent = $false
        if ($shouldRecover) { Send-AdminBroadcast -Text "✅ استعاد البوت اتصال Telegram وعادت دورة التحديث للعمل." }
        return
    }
    if ([int]$history.FailureCount -eq 0) { $history.OutageStartedAt = $now }
    $history.FailureCount = [int]$history.FailureCount + 1
    $history.LastError = Protect-SensitiveText $ErrorMessage; $history.LastErrorAt = $now
    $threshold = [Math]::Max(1, (Get-SettingInt 'HealthFailureAlertThreshold' 1))
    if ([int]$history.FailureCount -ge $threshold -and -not [bool]$history.AlertSent) {
        $history.AlertSent = $true
        $started = ([datetime]$history.OutageStartedAt).ToString('yyyy-MM-dd HH:mm:ss')
        Send-AdminBroadcast -Text "⚠️ فُقد اتصال Telegram بعد $($history.FailureCount) حالات فشل متتالية`nبداية الانقطاع: $started`n$($history.LastError)"
    }
}

function Send-BridgeStartupNotification {
    Send-AdminBroadcast -Text "🟢 بدأ تشغيل Cinegy Telegram Bridge v$script:BridgeVersion`nAir: $($config.AirServerAddress) / قناة $($config.AirChannelNumber)"
}

function Update-NewsSheetSync {
    <# Automatic mode only. The interval is measured from the last attempt, not
       the last success, so an unreachable sheet is retried on the same cadence
       instead of hammering the network every tick. #>
    if ([string](Get-Setting 'NewsSheetSyncMode') -ne 'auto') { return }
    if ([string]::IsNullOrWhiteSpace([string](Get-Setting 'NewsSheetCsvUrl'))) { return }
    $minutes = Get-SettingInt 'NewsSheetSyncMinutes' 1
    if ($minutes -le 0) { return }
    if ($script:NewsSheetLastSyncAt -and ((Get-Date) - $script:NewsSheetLastSyncAt).TotalMinutes -lt $minutes) { return }
    $script:NewsSheetLastSyncAt = Get-Date
    $result = Invoke-NewsSheetSync -Trigger auto
    if ($result.Success) {
        Write-BridgeLog "News sheet sync published $(@($result.Items).Count) item(s)"
    }
    elseif (-not $result.Unchanged -and -not $result.Skipped) {
        Write-BridgeLog "News sheet sync did not publish: $($result.Error)" 'WARN'
    }
}

function Invoke-BridgeTick {
    <# Everything time-based happens here, between long-polls. Each helper is
       cheap and non-blocking; any failure is logged rather than allowed to
       kill the loop. #>
    foreach ($step in @('Update-TelegramOutbox', 'Update-PostShowQueue', 'Update-SnapshotJobs', 'Update-RelayWatchdog', 'Update-AutoHideQueue', 'Update-TemplateReminderQueue', 'Update-ScheduleQueue', 'Update-MojazScheduleQueue', 'Update-MojazPlayback', 'Update-MojazTickerReturn', 'Update-PendingExpiry', 'Update-NewsDraftExpiry', 'Update-NewsLockRequest', 'Update-NewsSheetSync', 'Update-SnapshotCleanup', 'Update-UploadCleanup', 'Update-MojazImageCleanup', 'Update-OutputBlackWatchdog', 'Save-UsageCounts', 'Save-UserProfiles', 'Update-CinegyStateWatchdog', 'Update-StaleOnAirWatchdog', 'Update-CinegyHealthWatchdog', 'Update-QuietHoursQueue', 'Update-AnnouncementQueue', 'Update-Heartbeat', 'Update-UsageDigest')) {
        try { & $step | Out-Null }
        catch { Write-BridgeLog "Tick step $step failed: $($_.Exception.Message)" "ERROR" }
    }
}

function Get-BasePollTimeout {
    $value = 0
    if (-not [int]::TryParse([string](Get-JsonProp $config 'PollTimeoutSeconds'), [ref]$value) -or $value -le 0) { $value = 30 }
    return $value
}

function Get-EffectivePollTimeout {
    <# Long-poll for the configured time normally, but collapse to 1 second
       whenever async work is outstanding so a finished snapshot or a dead
       relay is noticed within a second instead of up to 30. #>
    if ($script:PostShowQueue.Count -gt 0) { return 1 }
    # A bulletin on air has a moment to hit every few seconds, and the write
    # has to land inside a fade that lasts about a second. Polling for the
    # configured half-minute would miss every one of them.
    if ($script:MojazPlayback) { return 1 }
    if ($script:SnapshotJobs.Count -gt 0 -or $script:AutoHideQueue.Count -gt 0 -or $script:RelayState.VerifyAt) { return 1 }
    $base = Get-BasePollTimeout
    $upcoming = @(Get-UpcomingScheduleEvents)
    if ($upcoming.Count -gt 0) {
        $secondsToEvent = [int][Math]::Ceiling((([datetimeoffset]$upcoming[0].ScheduledAt) - [datetimeoffset]::Now).TotalSeconds)
        $base = [Math]::Min($base, [Math]::Max(1, $secondsToEvent))
    }
    if ($script:RelayState.ShouldRun) { return [Math]::Min($base, (Get-SettingInt 'RelayWatchdogSeconds' 5)) }
    # Follows the widened interval while Air is unreachable, so a dead engine
    # does not keep the long-poll short for nothing.
    $base = [Math]::Min($base, (Get-CinegyStateCheckInterval))
    return [Math]::Min($base, (Get-SettingInt 'CinegyHealthCheckSeconds' 1))
}

