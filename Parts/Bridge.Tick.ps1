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

function Update-AutoHideQueue {
    if ($script:AutoHideQueue.Count -eq 0) { return }
    $due = @($script:AutoHideQueue | Where-Object { (Get-Date) -ge $_.At })
    foreach ($item in $due) {
        $script:AutoHideQueue.Remove($item) | Out-Null
        Write-BridgeLog "Auto-hiding layer $($item.Layer) (timed show by user $($item.UserId))"
        if (Invoke-HideLayer -Layer ([int]$item.Layer) -ChatId ([long]$item.ChatId) -UserId ([long]$item.UserId) -Quiet) {
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⏱ تم الإخفاء التلقائي للطبقة $($item.Layer)."
        }
        else {
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⚠️ فشل الإخفاء التلقائي للطبقة $($item.Layer) - أخفها يدويًا."
        }
    }
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
    if (-not (Test-Path -LiteralPath $script:auditFile)) { return @() }
    $records = foreach ($line in @(Get-Content -LiteralPath $script:auditFile -Tail $MaxLines -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    }
    return @($records)
}

function Get-MissedEventsText {
    <#
        What happened while nobody was looking.

        After a restart, or after a night away, the operator has no idea what
        the channel did. The audit trail holds it all but reads like a
        machine log; this collapses it into the few sentences a human needs
        before taking over a shift.
    #>
    param([int]$Hours = 12)
    $since = (Get-Date).ToUniversalTime().AddHours(-[math]::Max(1, $Hours))
    $records = @(Read-AuditRecords | Where-Object {
            $stamp = [datetime]::MinValue
            [datetime]::TryParse([string]$_.timestampUtc, [ref]$stamp) -and $stamp.ToUniversalTime() -ge $since
        })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("🕘 ماذا فاتني — آخر $Hours ساعة")
    if ($records.Count -eq 0) {
        $lines.Add('')
        $lines.Add('لا شيء مسجّل في هذه الفترة.')
        return ($lines -join "`n")
    }

    $byAction = $records | Group-Object -Property action
    $lines.Add('')
    foreach ($group in ($byAction | Sort-Object Count -Descending)) {
        $label = if ([string]::IsNullOrWhiteSpace($group.Name)) { 'أخرى' } else { $group.Name }
        $lines.Add("• $label — $($group.Count)")
    }

    $failures = @($records | Where-Object { [string]$_.result -eq 'failed' })
    if ($failures.Count -gt 0) {
        $lines.Add('')
        $lines.Add("❌ عمليات فاشلة: $($failures.Count)")
        foreach ($failure in @($failures | Select-Object -Last 3)) {
            $lines.Add("  - $($failure.action) طبقة $($failure.layer): $($failure.message)")
        }
    }
    $lines.Add('')
    $lines.Add("الوضع الآن: $(if ($script:OnAir.Count -eq 0) { 'لا شيء على الهواء' } else { "$($script:OnAir.Count) مشهدًا على الهواء" })")
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

    if ($hits.Count -eq 0) { return "لا يوجد سجل لاستخدام '$needle' ضمن ما هو محفوظ." }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("👤 من استخدم '$needle'")
    $lines.Add('')
    foreach ($hit in $hits) {
        $stamp = [datetime]::MinValue
        $when = if ([datetime]::TryParse([string]$hit.timestampUtc, [ref]$stamp)) { $stamp.ToLocalTime().ToString('MM-dd HH:mm') } else { '؟' }
        $lines.Add("• $when — $(Get-UserDisplayName -UserId ([long]$hit.userId)) — $($hit.action) ($($hit.result))")
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
    Add-AuditEntry "📝 سبب الإلغاء: $(Get-CancelReasonLabel -Reason $Reason) - user $UserId"
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
    if ($stale.Count -eq 0) { return }

    foreach ($item in $stale) { $script:StaleOnAirAlerted.Add([int]$item.Layer) | Out-Null }
    $lines = @($stale | ForEach-Object { "• طبقة $($_.Layer) · $($_.Key) — منذ $($_.Hours) ساعة" })
    Write-BridgeLog "Stale on-air record(s) reported to administrators: $(@($stale | ForEach-Object { $_.Layer }) -join ', ')" 'WARN'
    Send-AdminBroadcast -Urgent -Text ("⚠️ سجلات على الهواء منذ وقت طويل — تحقّق من الشاشة:`n" + ($lines -join "`n") +
        "`nإن كانت الشاشة خالية فاضغط إخفاء على الطبقة لتصفية السجل.")
}

function Get-CinegyStateCheckInterval {
    <# Configured interval, widened while Air is unreachable. See
       Get-BridgeCinegyStateBackoff for why the widening exists. #>
    $interval = Get-SettingInt 'CinegyStateCheckSeconds' 1
    return [Math]::Max($interval, [int]$script:RuntimeState.Monitoring.CinegyStateBackoffSeconds)
}

function Update-CinegyStateWatchdog {
    $now = Get-Date
    if (($now - $script:RuntimeState.Monitoring.LastCinegyStateCheck).TotalSeconds -lt (Get-CinegyStateCheckInterval)) { return }
    $script:RuntimeState.Monitoring.LastCinegyStateCheck = $now

    $sync = Update-OnAirStateFromCinegy -Reason 'watchdog' `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)

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
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    $newState = if (-not $telemetry.Success -or $null -eq $telemetry.Healthy) { 'unreachable' }
    elseif ($telemetry.Healthy) { 'healthy' }
    else { 'unhealthy' }

    $oldState = $script:RuntimeState.Monitoring.CinegyHealthState; $history = $script:HealthHistory.Cinegy
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

function Invoke-BridgeTick {
    <# Everything time-based happens here, between long-polls. Each helper is
       cheap and non-blocking; any failure is logged rather than allowed to
       kill the loop. #>
    foreach ($step in @('Update-PostShowQueue', 'Update-SnapshotJobs', 'Update-RelayWatchdog', 'Update-AutoHideQueue', 'Update-ScheduleQueue', 'Update-PendingExpiry', 'Update-SnapshotCleanup', 'Update-UploadCleanup', 'Update-OutputBlackWatchdog', 'Save-UsageCounts', 'Save-UserProfiles', 'Update-CinegyStateWatchdog', 'Update-StaleOnAirWatchdog', 'Update-CinegyHealthWatchdog', 'Update-QuietHoursQueue', 'Update-Heartbeat', 'Update-UsageDigest')) {
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

