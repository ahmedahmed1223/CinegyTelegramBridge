#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Looking something up after the fact: an operation by its reference, a
    diagnostics bundle, the join secret, and granting access.

    Split out of Bridge.Admin.ps1, which had grown to 2149 lines holding five
    unrelated administrator jobs at once. Nothing moved between scopes -
    dot-sourced parts share one.
#>

function Test-OperationReference {
    <# Whether Value is shaped like what Get-OperationReference produces.

       Separate from the lookup because a single function cannot report both
       "not a reference" and "no such operation": PowerShell collapses an
       empty array to $null on return exactly as it does an absent value, so
       the two answers arrived indistinguishable and a rotated-away log was
       reported as a malformed reference. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Reference)
    return ([string]$Reference).Trim().ToLowerInvariant() -match '^[0-9a-f]{8}$'
}

function Find-OperationByReference {
    <#
        The AIR_OP lines whose correlation id starts with Reference.

        This is deliberately NOT a log search. The runtime log is the least
        redacted thing the bridge writes - that is why the diagnostic bundle
        exists as a separate, scrubbed export - so a screen that returned
        arbitrary matching lines would be a way to read it a keyword at a
        time. Reference must therefore be exactly the eight hex characters
        Get-OperationReference produces, and only structured AIR_OP records
        are ever returned.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Reference, [string]$Path = '', [int]$MaxLines = 20)
    if (-not (Test-OperationReference -Reference $Reference)) { return @() }
    $wanted = $Reference.Trim().ToLowerInvariant()
    $file = if ($Path) { $Path } else { $script:logPath }
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { return @() }
    try {
        return @(Get-Content -LiteralPath $file -ErrorAction Stop |
                Where-Object { $_ -like "*AIR_OP id=air-$wanted*" } |
                Select-Object -Last $MaxLines)
    }
    catch {
        Write-BridgeLog "Could not read the runtime log for a reference lookup: $($_.Exception.Message)" 'WARN'
        return @()
    }
}

function Start-OperationReferenceLookup {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'operation_reference'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل مرجع العملية — ثمانية أحرف، مثل 5023333b.`nينسخه المشغّل من 🧾 عملياتي." -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-OperationReferenceLookup {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Value = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'operation_reference') { return }
    Clear-PendingState -ChatId $ChatId
    # Checked again here, not only when the button was drawn: this reads the
    # runtime log, and the screen may have been opened before a role changed.
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text '🔎 البحث بالمرجع للمشرف وحده.'
        return
    }
    # The null check has to come before the @() wrap - @($null) is a one-item
    # array holding $null, which would read as a hit - and the wrap has to
    # come before .Count, because PowerShell unwraps a one-item array on
    # return: exactly one matching AIR_OP line made this a [string], and
    # .Count on a string throws under StrictMode. Which is what it did.
    if (-not (Test-OperationReference -Reference $Value)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ ليس مرجعًا: يتكوّن من ثمانية أحرف من 0-9 و a-f.' -ReplyMarkup (Get-DiagnosticsKeyboard)
        return
    }
    # @() because PowerShell unwraps a one-item array on return, and .Count on
    # the [string] that produced is what threw in production.
    $lines = @(Find-OperationByReference -Reference $Value)
    $text = if ($lines.Count -eq 0) {
        "🔎 لا سجل بالمرجع $($Value.Trim()).`nقد يكون السجل دُوِّر أو مُسح."
    }
    else {
        "🔎 المرجع $($Value.Trim()) — $($lines.Count) سطرًا:`n`n" + ($lines -join "`n")
    }
    # A log line is columns held together by spaces, so it is the one thing on
    # these screens a proportional font actively breaks: id=, action= and
    # result= stop lining up between rows and the eye loses the column it was
    # following. 'pre' is what monowidth exists for.
    $lookupKeyboard = Get-DiagnosticsKeyboard
    if ($lines.Count -gt 0) {
        $lookupBlocks = @(
            @{ type = 'heading'; text = "🔎 المرجع $($Value.Trim()) — $($lines.Count) سطرًا"; size = 3 }
            @{ type = 'pre'; text = ($lines -join "`n") }
        )
        if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $lookupBlocks -ReplyMarkup $lookupKeyboard) { return }
    }
    Send-TelegramPagedText -ChatId $ChatId -Text $text -ReplyMarkup $lookupKeyboard
}

function Get-DiagnosticsKeyboard {
    return @{ inline_keyboard = @(
        , @((New-Button '🔎 ابحث بمرجع عملية' 'diag:findref'))
        , @((New-Button '📦 حزمة تشخيص منقحة' 'diag:bundle'))
        , @((New-Button '🧹 مسح سجل التشغيل' 'diag:clearruntime' -Style danger), (New-Button '🧹 مسح سجل التدقيق' 'diag:clearaudit' -Style danger))
        , @((New-Button '🏠 القائمة' 'menu:main'))
    ) }
}

function New-DiagnosticBundle {
    $bundleDirectory = Join-Path $script:logDir 'diagnostics'
    New-Item -ItemType Directory -Path $bundleDirectory -Force -ErrorAction Stop | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $stagingDirectory = Join-Path $bundleDirectory "staging-$id"
    $bundlePath = Join-Path $bundleDirectory "cinegy-bridge-diagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$($id.Substring(0,8)).zip"
    New-Item -ItemType Directory -Path $stagingDirectory -Force -ErrorAction Stop | Out-Null
    try {
        $snapshot = Get-BridgeDiagnosticsSnapshot
        $warnings = @(Get-DiagnosticWarnings -Snapshot $snapshot `
            -DiskFreeWarningGB (Get-SettingInt 'DiskFreeWarningGB' 1) `
            -RuntimeStorageWarningMB (Get-SettingInt 'RuntimeStorageWarningMB' 1) `
            -BackupStorageWarningMB (Get-SettingInt 'BackupStorageWarningMB' 1))
        $summary = [ordered]@{
            generatedAtUtc      = [DateTime]::UtcNow.ToString('o')
            bridgeVersion       = $script:BridgeVersion
            powershellVersion   = [string]$PSVersionTable.PSVersion
            uptimeSeconds       = [long]([timespan]$snapshot.Uptime).TotalSeconds
            processor           = Protect-DiagnosticText ([string]$snapshot.Processor)
            workingSetMB        = $snapshot.WorkingSetMB
            privateMemoryMB     = $snapshot.PrivateMemoryMB
            diskFreeGB          = $snapshot.DiskFreeGB
            runtimeStorageBytes = $snapshot.RuntimeStorageBytes
            backupStorageBytes  = $snapshot.BackupStorageBytes
            airOperations       = $snapshot.AirOperations
            warnings            = @($warnings | ForEach-Object { Protect-DiagnosticText $_ })
        }
        $summaryPath = Join-Path $stagingDirectory 'summary.json'
        [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

        $recentPath = Join-Path $stagingDirectory 'recent-runtime.log'
        $recentLines = if (Test-Path -LiteralPath $script:logPath) { @(Get-Content -LiteralPath $script:logPath -Tail 200 -ErrorAction SilentlyContinue) } else { @() }
        $safeLines = @($recentLines | ForEach-Object { Protect-DiagnosticText ([string]$_) })
        [IO.File]::WriteAllLines($recentPath, [string[]]$safeLines, [Text.UTF8Encoding]::new($false))

        Compress-Archive -LiteralPath $summaryPath, $recentPath -DestinationPath $bundlePath -CompressionLevel Optimal -ErrorAction Stop
        return $bundlePath
    }
    finally {
        if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-DiagnosticBundleCommand {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'هذا الخيار للمشرفين فقط.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $bundlePath = $null
    try {
        $bundlePath = New-DiagnosticBundle
        if (Send-TelegramDocument -ChatId $ChatId -FilePath $bundlePath -Caption '📦 حزمة تشخيص منقحة: لا تحتوي الإعدادات أو حالة الهواء أو معرفات المستخدمين.') {
            Add-AuditEntry "📦 تنزيل حزمة تشخيص منقحة - بواسطة $(Format-UserAuditActor -UserId $UserId)"
        }
        else {
            Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذر إرسال حزمة التشخيص.' -ReplyMarkup (Get-DiagnosticsKeyboard)
        }
    }
    catch {
        Write-BridgeLog "Diagnostic bundle creation failed: $($_.Exception.Message)" 'ERROR'
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذر إنشاء حزمة التشخيص.' -ReplyMarkup (Get-DiagnosticsKeyboard)
    }
    finally {
        if ($bundlePath -and (Test-Path -LiteralPath $bundlePath)) { Remove-Item -LiteralPath $bundlePath -Force -ErrorAction SilentlyContinue }
    }
}

function Request-DiagnosticLogClear {
    param(
        [Parameter(Mandatory)][ValidateSet('runtime', 'audit')][string]$Kind,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId
    )
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'diagnostic_log_clear'; Kind = $Kind; UserId = $UserId }
    $label = if ($Kind -eq 'runtime') { 'سجل التشغيل الحالي وكل نسخه المدورة' } else { 'سجل التدقيق الدائم' }
    Send-TelegramMessage -ChatId $ChatId -Text "⚠️ هل تريد مسح $label؟`nلا يؤثر هذا على onair.json أو القوالب الموجودة على الهواء." -ReplyMarkup @{
        inline_keyboard = @(
            , @((New-Button '⚠️ نعم، امسح' 'diag:clearconfirm' -Style danger), (New-Button '❌ إلغاء' 'menu:diagnostics'))
        )
    }
}

function Clear-DiagnosticLog {
    param(
        [Parameter(Mandatory)][ValidateSet('runtime', 'audit')][string]$Kind,
        [Parameter(Mandatory)][long]$UserId
    )
    try {
        if ($Kind -eq 'runtime') {
            foreach ($file in @(Get-ChildItem -LiteralPath $script:logDir -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
            [IO.File]::WriteAllText($script:logPath, '', [Text.UTF8Encoding]::new($false))
        }
        else {
            [IO.File]::WriteAllText($script:auditFile, '', [Text.UTF8Encoding]::new($false))
        }
        $operationId = "audit-$([guid]::NewGuid().ToString('N'))"
        Write-AuditRecord -OperationId $operationId -EventName log_clear -Result success -UserId $UserId -Action CLEAR -Target $Kind -Message 'administrator confirmed log cleanup'
        Write-BridgeLog "Administrator user $UserId cleared $Kind log history" 'WARN'
        return $true
    }
    catch {
        Write-BridgeLog "Failed to clear $Kind log history: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Invoke-DiagnosticsCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "هذا الأمر مخصص للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $store = Get-TemplateStore
    $telemetry = Get-AirTelemetryStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    $relayState = if ($script:RelayState.ShouldRun) { 'مطلوب التشغيل' } else { 'متوقف' }
    $diagnostics = Get-BridgeDiagnosticsSnapshot
    $buildText = if ($diagnostics.BuildTimeUtc) { ([datetime]$diagnostics.BuildTimeUtc).ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' } else { 'غير معروف' }
    $uptime = [timespan]$diagnostics.Uptime
    $fileText = ($diagnostics.FileSizes.GetEnumerator() | ForEach-Object { "$($_.Key)=$([math]::Round([double]$_.Value / 1KB, 1))KB" }) -join ' | '
    $diskText = if ($null -ne $diagnostics.DiskFreeGB) { "$($diagnostics.DiskFreeGB) GB" } else { 'غير معروف' }
    $diagnosticWarnings = @(Get-DiagnosticWarnings -Snapshot $diagnostics `
        -DiskFreeWarningGB (Get-SettingInt 'DiskFreeWarningGB' 1) `
        -RuntimeStorageWarningMB (Get-SettingInt 'RuntimeStorageWarningMB' 1) `
        -BackupStorageWarningMB (Get-SettingInt 'BackupStorageWarningMB' 1))
    $text = @(
        "🧪 تشخيص Cinegy Telegram Bridge",
        "Bridge: v$script:BridgeVersion | PowerShell $($PSVersionTable.PSVersion)",
        "وقت البناء: $buildText | مدة التشغيل: $(Format-DurationSeconds -Seconds ([int]$uptime.TotalSeconds))",
        "المعالج: $($diagnostics.Processor)",
        "الذاكرة: Working $($diagnostics.WorkingSetMB) MB | Private $($diagnostics.PrivateMemoryMB) MB",
        "مساحة القرص الحرة: $diskText",
        "أحجام الملفات: $fileText",
        "عمليات الهواء: نجاح $($diagnostics.AirOperations.Success) | فشل $($diagnostics.AirOperations.Failed) | محظور $($diagnostics.AirOperations.Blocked)",
        "Cinegy: $($config.AirServerAddress) / قناة $($config.AirChannelNumber)",
        "القوالب: $(@($store.Order).Count) | تحذيرات القوالب: $(@($store.Errors).Count)",
        "المحادثات المعلقة: $($script:PendingState.Count) | أقفال الطبقات: $($script:LayerLocks.Count)",
        "طابور postbox: $($script:PostShowQueue.Count) | مؤقتات الإخفاء: $($script:AutoHideQueue.Count)",
        "الأحداث المجدولة القادمة: $(@(Get-UpcomingScheduleEvents).Count) | ملف الجدولة: $script:scheduleFile",
        "لقطات قيد التنفيذ: $($script:SnapshotJobs.Count) | relay: $relayState",
        "حالة Cinegy المحلية: $($script:RuntimeState.Monitoring.CinegyHealthState)",
        "",
        (Format-CinegyTelemetryStatus -Telemetry $telemetry)
    ) -join "`n"
    if ($diagnosticWarnings.Count -gt 0) { $text += "`n`n" + ($diagnosticWarnings -join "`n") }
    Send-TelegramMessage -ChatId $ChatId -Text (Protect-SensitiveText $text) -ReplyMarkup (Get-DiagnosticsKeyboard)
}

function Get-AuditTrailStamp {
    <# The stamp a trail line begins with, or a dash when the line is missing
       or shaped unexpectedly - a period line must never be the thing that
       takes down the screen it describes. #>
    param([AllowNull()][string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return '—' }
    if ($Line -match '^(\d{2}-\d{2} \d{2}:\d{2}:\d{2}|\d{2}:\d{2}:\d{2})') { return $Matches[1] }
    return '—'
}

function Get-AuditScreenKeyboard {
    <# The way from the raw trail to the operations log. A supervisor looking
       for what went out yesterday opens 📜 first - it is the screen named
       "the log" - and until now it was a dead end of fixed length. #>
    # No parameters: every button here is the same for whoever opens it, and
    # a parameter kept "for symmetry" is a parameter that will be trusted.
    param()
    return @{ inline_keyboard = @(
            , @((New-Button '📅 سجل العمليات بالساعات' 'oplog:48'))
            , @((New-Button '🏠 القائمة' 'menu:main'))
        ) }
}

function Invoke-AuditCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($script:AuditTrail.Count -eq 0) {
        # Rebuilt from audit.jsonl at startup, so empty no longer means
        # "the process restarted" - it means nothing has happened yet.
        Send-TelegramMessage -ChatId $ChatId -Text "📜 آخر العمليات`n━━━━━━━━━━━━━━`nلا توجد عمليات مسجّلة بعد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    # The period first. This screen shows a fixed number of lines, not a
    # window of time, so how far back it reaches depends entirely on how busy
    # the station has been - which the reader cannot know and had no way to
    # ask.
    $shown = @($script:AuditTrail | Select-Object -Last 20)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('📜 آخر العمليات')
    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("الفترة: $(Get-AuditTrailStamp -Line @($shown)[0]) ← $(Get-AuditTrailStamp -Line @($shown)[-1])")
    $lines.Add("المعروض: $($shown.Count) من $($script:AuditTrail.Count) سطرًا محفوظة")
    $lines.Add('')
    $lines.AddRange([string[]]$shown)
    Send-TelegramPagedText -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-AuditScreenKeyboard)
}

function Request-Approval {
    <# Notifies every admin once per pending chat, with Approve/Reject buttons.
       Capped by MaxPendingApprovals so a publicly-discovered bot cannot flood
       the admins, and entries age out after PendingApprovalExpiryHours. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, $From)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableSelfServiceRequests')) { return $false }
    if ($script:PendingApprovals.ContainsKey($ChatId)) { return $true }
    if (Test-ChatBlocked -ChatId $ChatId) {
        Write-BridgeLog "Dropped access request from blocked chat $ChatId" 'WARN'
        return $false
    }
    # The code is asked for before the queue, so a stranger without it never
    # reaches an administrator's screen at all.
    if (-not [string]::IsNullOrWhiteSpace([string](Get-Setting 'JoinSecret')) -and -not (Test-AccessSecretPassed -ChatId $ChatId)) {
        Request-JoinSecret -ChatId $ChatId -UserId $UserId | Out-Null
        return $false
    }
    if (-not (Test-AccessRequestAllowed -ChatId $ChatId)) { return $false }

    $max = Get-SettingInt 'MaxPendingApprovals' 1
    if ($script:PendingApprovals.Count -ge $max) {
        Write-BridgeLog "Dropped access request from $ChatId - pending queue full ($max)" "WARN"
        return $false
    }

    $firstName = Get-JsonProp $From 'first_name'
    $lastName = Get-JsonProp $From 'last_name'
    $username = Get-JsonProp $From 'username'
    $name = (@($firstName, $lastName) | Where-Object { $_ }) -join ' '
    if ($username) { $name = if ($name) { "$name (@$username)" } else { "@$username" } }

    $script:PendingApprovals[$ChatId] = @{ Name = $name; ChatId = $ChatId; UserId = $UserId; RequestedAt = (Get-Date) }

    if (@(Get-JsonProp $config 'AdminChatIds').Count -eq 0) {
        Write-BridgeLog "Access request from $ChatId but no AdminChatIds configured to notify" "WARN"
        return $true
    }
    $nameLine = if ($name) { "الاسم: $name`n" } else { "" }
    # The request is queued either way; this decides only whether it also
    # interrupts somebody. A busy public bot can leave them to 👤 طلبات الوصول.
    if (Get-Setting 'NotifyAdminsOnAccessRequest') {
        Send-AdminBroadcast -Text "🔔 طلب وصول جديد للبوت`n$($nameLine)رقم المحادثة: $ChatId`nرقم المستخدم: $UserId" -ReplyMarkup (Get-ApprovalKeyboard -TargetChatId $ChatId)
    }
    Write-BridgeLog "Access request from chat $ChatId / user $UserId ($name) sent to admins"
    # When it was asked, as data: the decision rows are only half an answer
    # without it - "approved at 11:09" says nothing about whether anyone was
    # kept waiting.
    Write-AuditRecord -OperationId "access-$([guid]::NewGuid().ToString('N'))" -EventName 'access' `
        -Result 'requested' -UserId $UserId -ChatId $ChatId -Action 'request' `
        -Target ([string]$UserId) -Message ([string]$name)
    # Asked after the admins are told, never before: a requester who never
    # answers still has a request waiting, which is the point of the queue.
    # What they send replaces the Telegram handle as the name the roster shows.
    if (Get-Setting 'AskRequesterName') {
        # Out-Null on both: whatever they emit would ride out on this
        # function's return value, and the caller reads that as "queued".
        Set-PendingState -ChatId $ChatId -State @{ Mode = 'access_request_name'; UserId = $UserId } | Out-Null
        Send-TelegramMessage -ChatId $ChatId -Text '📝 أرسل اسمك كما تريده أن يظهر للمشرفين (مثل: أحمد - قسم الأخبار).' | Out-Null
    }
    return $true
}

function Request-JoinSecret {
    <# Asked once per chat per day, and never told what the code is for
       beyond that the bot is closed - the prompt is the whole hint. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'join_secret'; UserId = $UserId } | Out-Null
    Send-TelegramMessage -ChatId $ChatId -Text '🔑 هذا البوت مغلق. أرسل رمز الانضمام للمتابعة.' | Out-Null
    return $true
}

function Complete-JoinSecret {
    <#
        The code a stranger sends before any administrator hears of them.

        Wrong codes are counted, not explained: after JoinSecretMaxAttempts in
        one day the chat is blocked and told nothing more, because a refusal
        that reports how close a guess came is a guessing game.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [AllowEmptyString()][string]$Value = '', $From)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'join_secret') { return $false }
    if (Test-ChatBlocked -ChatId $ChatId) { Clear-PendingState -ChatId $ChatId; return $false }
    if (-not (Test-JoinSecret -Provided $Value)) {
        $entry = Add-AccessAttempt -ChatId $ChatId -Kind secret
        $max = Get-SettingInt 'JoinSecretMaxAttempts' 0
        if ($max -gt 0 -and [int]$entry.SecretFails -ge $max) {
            Clear-PendingState -ChatId $ChatId
            Block-AccessChat -ChatId $ChatId -Reason 'join_secret' | Out-Null
            return $false
        }
        Send-TelegramMessage -ChatId $ChatId -Text '❌ الرمز غير صحيح.' | Out-Null
        return $false
    }
    Clear-PendingState -ChatId $ChatId
    Set-AccessSecretPassed -ChatId $ChatId | Out-Null
    Write-BridgeLog "Chat $ChatId passed the join code"
    $queued = Request-Approval -ChatId $ChatId -UserId $UserId -From $From
    if (-not $queued) { Send-TelegramMessage -ChatId $ChatId -Text 'تعذّر تسجيل طلبك الآن. حاول لاحقًا.' | Out-Null }
    return $queued
}

function Complete-AccessRequestName {
    <#
        The name a requester gives for themselves, which becomes their alias
        the moment access is granted - so no administrator types it in.

        Guarded rather than trusted: this is the one flow a chat with no
        access can reach, so it does nothing unless that chat really is
        waiting in the queue, and the text is capped and stripped of the
        characters that would break a roster line or an audit entry.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'access_request_name') { return $false }
    if (-not $script:PendingApprovals.ContainsKey($ChatId)) {
        Clear-PendingState -ChatId $ChatId
        return $false
    }
    $clean = ([string]$Value -replace '[
	]+', ' ').Trim()
    if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60) }
    if ([string]::IsNullOrWhiteSpace($clean)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ الاسم فارغ. أرسل اسمك.'
        return $false
    }
    Clear-PendingState -ChatId $ChatId
    $script:PendingApprovals[$ChatId].Name = $clean
    Write-BridgeLog "Access requester $ChatId gave the name '$clean'"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ وصل اسمك: $clean`nطلبك عند المشرفين، وستصلك رسالة فور الموافقة."
    Send-AdminBroadcast -Text "📝 طلب الوصول من $ChatId باسم: $clean" -ReplyMarkup (Get-ApprovalKeyboard -TargetChatId $ChatId)
    return $true
}

function Grant-UserAccess {
    param([Parameter(Mandatory)][long]$TargetChatId, [Parameter(Mandatory)][long]$ApprovedBy, [long]$ApproverUserId = 0)
    if ($ApproverUserId -eq 0) { $ApproverUserId = $ApprovedBy }
    $targetUserId = $TargetChatId
    $requestedName = ''
    $pendingRecord = $null
    if ($script:PendingApprovals.ContainsKey($TargetChatId)) {
        $pendingRecord = $script:PendingApprovals[$TargetChatId]
        $targetUserId = [long]$pendingRecord.UserId
        $requestedName = [string]$pendingRecord.Name
    }

    # Idempotent: the approval buttons sit in a message that stays tappable,
    # and two admins (or one double-tap) previously re-ran the whole flow and
    # re-notified the new user.
    if ((Test-Authorized -ChatId $TargetChatId -UserId $targetUserId) -and -not $script:PendingApprovals.ContainsKey($TargetChatId)) {
        Send-TelegramMessage -ChatId $ApprovedBy -Text "ℹ️ $TargetChatId مصرّح له بالفعل." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ApprovedBy -UserId $ApproverUserId)
        return
    }

    $changed = $false
    if (@(Get-JsonProp $config 'AllowedChatIds') -notcontains $TargetChatId) {
        $config.AllowedChatIds = @(Get-JsonProp $config 'AllowedChatIds') + $TargetChatId
        $changed = $true
    }
    if ($targetUserId -ne 0 -and (@(Get-JsonProp $config 'AllowedUserIds') -notcontains $targetUserId)) {
        $config.AllowedUserIds = @(Get-JsonProp $config 'AllowedUserIds') + $targetUserId
        $changed = $true
    }
    if ($changed) { Save-Config }
    $requestedAt = if ($pendingRecord) { Get-JsonProp $pendingRecord 'RequestedAt' } else { $null }
    Write-UserApprovalMetadata -TargetUserId $targetUserId -ApprovedByUserId $ApproverUserId -RequestedAt $requestedAt | Out-Null

    $script:PendingApprovals.Remove($TargetChatId)
    Write-BridgeLog "User $ApproverUserId approved new user $targetUserId (chat $TargetChatId)"
    # Every administrator hears who was let in and by whom. One approval on
    # this installation was made in a minute by one of three, and the other
    # two learned of it from a colleague - a grant of on-air control that
    # nobody but its author saw. Not urgent: it is a record, and a record can
    # wait for the quiet-hours digest.
    $approverName = Format-UserAuditActor -UserId $ApproverUserId
    $grantedName = if ($requestedName) { "$requestedName ‎($targetUserId)‎" } else { [string]$targetUserId }
    Send-AdminBroadcast -Text "👤 مُنح الوصول: $grantedName — بواسطة $approverName" 
    # The name the person gave for themselves becomes their alias here, which
    # is the whole reason for asking: the roster and every audit line read it
    # from the first minute, with no administrator typing it in. An alias
    # already set is left alone - somebody chose that one deliberately.
    if ($requestedName -and -not $script:UserAliases.ContainsKey([string]$targetUserId)) {
        if (Set-UserAlias -TargetUserId ([long]$targetUserId) -Alias $requestedName) {
            Write-BridgeLog "Adopted '$requestedName' as the alias for user $targetUserId from their access request"
        }
    }
    Add-AuditEntry "👤 موافقة على $(Format-UserAuditActor -UserId ([long]$targetUserId)) - بواسطة $(Format-UserAuditActor -UserId $ApproverUserId)"
    # And as data, not only as an Arabic sentence. The screen that answers
    # "who let this person in, and when" cannot be built by parsing prose:
    # every audit line here carried the whole decision inside one message
    # string, with its structured fields left empty.
    Write-AuditRecord -OperationId "access-$([guid]::NewGuid().ToString('N'))" -EventName 'access' `
        -Result 'approved' -UserId $ApproverUserId -ChatId $TargetChatId -Action 'approve' `
        -Target ([string]$targetUserId) -Message ([string]$requestedName)
    Send-TelegramMessage -ChatId $ApprovedBy -Text "✅ تمت الموافقة على $TargetChatId وأُضيف إلى المستخدمين المصرح لهم.$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ApprovedBy -UserId $ApproverUserId)
    Send-TelegramMessage -ChatId $TargetChatId -Text "✅ تمت الموافقة على طلبك، يمكنك الآن استخدام البوت." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $TargetChatId -UserId $targetUserId)
}

function Deny-UserAccess {
    param([Parameter(Mandatory)][long]$TargetChatId, [Parameter(Mandatory)][long]$RejectedBy, [long]$RejecterUserId = 0)
    if ($RejecterUserId -eq 0) { $RejecterUserId = $RejectedBy }
    $script:PendingApprovals.Remove($TargetChatId)
    Clear-PendingState -ChatId $TargetChatId
    # Rejection used to remove the request and nothing else, so the same chat
    # could ask again a second later, for ever.
    $blocked = [bool](Get-Setting 'BlockRejectedRequesters') -and (Block-AccessChat -ChatId $TargetChatId -Reason 'rejected' -ByUserId $RejecterUserId)
    Write-BridgeLog "User $RejecterUserId rejected access request from $TargetChatId (blocked=$blocked)"
    Add-AuditEntry "👤 رفض طلب $TargetChatId - بواسطة $(Format-UserAuditActor -UserId $RejecterUserId)"
    # A rejection leaves nothing behind anywhere else - no profile, no roster
    # entry - so without this row the screen would show only the people who
    # were let in, which is the half of the history nobody needs to ask about.
    Write-AuditRecord -OperationId "access-$([guid]::NewGuid().ToString('N'))" -EventName 'access' `
        -Result 'rejected' -UserId $RejecterUserId -ChatId $TargetChatId -Action 'reject' `
        -Target ([string]$TargetChatId) -Message $(if ($blocked) { 'blocked' } else { '' })
    $note = if ($blocked) { " وحُظرت المحادثة من الطلب مجددًا." } else { "" }
    Send-TelegramMessage -ChatId $RejectedBy -Text "❌ تم رفض طلب $TargetChatId.$note" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $RejectedBy -UserId $RejecterUserId)
    Send-TelegramMessage -ChatId $TargetChatId -Text "تم رفض طلب الوصول الخاص بك."
}
