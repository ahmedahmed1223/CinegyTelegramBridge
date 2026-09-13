#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    What the bridge says about itself: the full status, the health centre, the
    runtime-file health screen, and the supervisor that relaunches it.

    Split out of Bridge.Admin.ps1, which had grown to 2149 lines holding five
    unrelated administrator jobs at once. Nothing moved between scopes -
    dot-sourced parts share one.
#>

function Get-CinegyExposureWarning {
    <#
        Says so when the configured Cinegy address is not on a private network.

        The Cinegy HTTP interface has no authentication of any kind - no key,
        no password, no header - so reaching the port IS the authority to put
        graphics on air and to black the output. The bridge being the only
        gateway is a mitigation, not a boundary: anything that talks to the
        port directly passes no check at all.

        A hostname is judged as nothing rather than guessed at: resolving it
        would put a DNS lookup on a status screen, and a wrong guess here
        either cries wolf or reassures falsely. Only a literal public IPv4
        address is called out, because that one is certain.
    #>
    param([AllowEmptyString()][string]$Address = '')
    if ([string]::IsNullOrWhiteSpace($Address)) { return '' }
    $hostPart = @((($Address -replace '^[A-Za-z][A-Za-z0-9+.-]*://', '') -split '[/:]')) | Select-Object -First 1
    $parsed = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse([string]$hostPart, [ref]$parsed)) { return '' }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return '' }
    $octet = $parsed.GetAddressBytes()
    $isPrivate = ($octet[0] -eq 10) -or ($octet[0] -eq 127) -or
        ($octet[0] -eq 192 -and $octet[1] -eq 168) -or
        ($octet[0] -eq 169 -and $octet[1] -eq 254) -or
        ($octet[0] -eq 172 -and $octet[1] -ge 16 -and $octet[1] -le 31)
    if ($isPrivate) { return '' }
    return '🔓 عنوان Cinegy خارج النطاقات الخاصة. واجهة Cinegy بلا مصادقة: من يصل إلى المنفذ يتحكم بالهواء. أبقِ المنفذ داخل شبكة البثّ.'
}

function Get-CinegyVersionAwarenessNote {
    <#
        Names the gap between the Cinegy engine actually installed and the
        product-documentation version any new capability gets designed
        against, so a feature built from the published HTTP API docs is not
        assumed to exist on an older engine without being measured first.

        docs/REVIEW-2026-09-10.md hit exactly this: the reference docs were
        Air 26.2, the station ran 22.12, and two backlog items (T-10, T-18)
        turned on that gap once it was measured against the live device
        instead of assumed from the docs. $ReferenceDocVersion is that same
        baseline; bump it in one place when the docs used for design change,
        rather than hunting every place the number was typed.

        Silent when there is no identity to read yet, or when it already
        matches - so the line only appears when it says something new.
    #>
    param([object[]]$LayerStatuses = @(), [string]$ReferenceDocVersion = '26.2')
    $identity = ''
    foreach ($status in @($LayerStatuses)) {
        $candidate = [string](Get-JsonProp $status 'ClientIdentity')
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $identity = $candidate; break }
    }
    if ([string]::IsNullOrWhiteSpace($identity)) { return '' }
    if ($identity -notmatch '(?<Version>\d+\.\d+)(?:\.\d+){0,3}') { return '' }
    $installed = [string]$Matches.Version
    if ($installed -eq $ReferenceDocVersion) { return '' }
    return "📄 توثيق Cinegy المرجعي مبنيّ على $ReferenceDocVersion، والمثبَّت هنا $installed ($(ConvertTo-TelegramHtmlText $identity)) — قِس أي قدرة جديدة على الجهاز قبل بنائها، فقد لا تكون موجودة بعد."
}

function Invoke-FullStatusCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-StatusViewer -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "هذا الفحص متاح للمشرف والمالك فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $store = Get-TemplateStore
    $layerStatuses = @(Get-CinegyLayerDashboard)
    $sync = Update-OnAirStateFromCinegy -Reason 'full-status' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal
    $health = Get-HealthStatusReport
    $outputMonitor = Get-OutputMonitorStatus -Probe
    # Overall status line derived from the live signals so a quick glance at
    # the top of the message tells the operator whether anything needs attention.
    if ($sync.Failed.Count -gt 0) {
        $overall = "🔴 لا يمكن فحص بعض الطبقات"
    }
    elseif (-not $health.Telemetry.Success) {
        $overall = "🟠 Cinegy غير متاح"
    }
    elseif ($script:OnAir.Count -gt 0) {
        $overall = "🟠 طبقات على الهواء"
    }
    else {
        $overall = "🟢 كل شيء سليم"
    }

    $now = Get-Date
    # One rule between sections, the same one ℹ️ الحالة uses. Thirty-odd lines
    # separated only by blank ones read as a single column: the eye finds no
    # edge, so the section it wants is found by scrolling past everything.
    $sep = '━━━━━━━━━━━━━━━━━'
    $lines = [System.Collections.Generic.List[string]]::new()
    # parse_mode=HTML, same reasoning as ℹ️ الحالة: this screen is thirty-odd
    # lines long and went out as one flat column, so the six section
    # headings are bold and every figure an operator quotes is a
    # tap-to-copy <code> span. Anything a person typed - a template name,
    # an alias, a store error - is escaped, because a single "<" in a
    # template name would cost the whole screen a 400.
    $lines.Add("<b>📊 الحالة الكاملة</b> — <code>v$($script:BridgeVersion)</code>")
    $clockLine = "🕒 <code>$($now.ToString('yyyy-MM-dd HH:mm:ss'))</code> (محلي)"
    $lines.Add($clockLine)
    $lines.Add("<b>$overall</b>")
    $identityLine = "👤 معرّفك: $(ConvertTo-TelegramHtmlText (Format-UserAuditActor -UserId $UserId))"
    $lines.Add($identityLine)
    $lines.Add('')
    $lines.Add((ConvertTo-TelegramHtmlText (Get-OnAirSummary)))
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add('<b>🎛 اتصال Cinegy</b>')
    $lines.Add("🌐 <code>$(ConvertTo-TelegramHtmlText ([string]$config.AirServerAddress))</code> · القناة <code>$($config.AirChannelNumber)</code> · القوالب: <code>$($store.Order.Count)</code>")
    $configuredSceneMode = [string](Get-Setting 'SceneMode')
    $sceneCapabilities = Get-CinegySceneCapabilities -SceneItems $layerStatuses -LayerTargetSupported $true
    $sceneMode = Test-BridgeSceneMode -RequestedMode $configuredSceneMode -Capabilities $sceneCapabilities
    $verification = if ($sceneMode.Verified) { 'تم التحقق' } elseif ($configuredSceneMode -eq 'Multi') { 'بانتظار تحقق Cinegy' } else { 'وضع متوافق' }
    $exposure = Get-CinegyExposureWarning -Address ([string]$config.AirServerAddress)
    if ($exposure) { $lines.Add($exposure) }
    $versionNote = Get-CinegyVersionAwarenessNote -LayerStatuses $layerStatuses
    if ($versionNote) { $lines.Add($versionNote) }
    $material = Get-AirMaterialNowNext
    if ($material) { $lines.Add($material) }
    $lines.Add("🧩 وضع المشاهد المختار: <code>$(ConvertTo-TelegramHtmlText $configuredSceneMode)</code> · $verification")
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: <b>$(ConvertTo-TelegramHtmlText ([string]$freshness.Label))</b>")
    $lines.Add((ConvertTo-TelegramHtmlText (Format-CinegyLayerDashboard -LayerStatuses $layerStatuses)))
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add('<b>🩺 صحة الخدمات</b>')
    $lines.Add((ConvertTo-TelegramHtmlText ([string]$health.Text)))
    $lines.Add('')
    $lines.Add((ConvertTo-TelegramHtmlText ([string]$outputMonitor.Text)))
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add('<b>⚙️ التشغيل والجدولة</b>')
    $lines.Add("📡 البث المباشر: $(ConvertTo-TelegramHtmlText (Get-LiveRelayStatusText))")
    $lines.Add("🖼 الصور المعلّقة: <code>$($script:SnapshotJobs.Count)</code> · مؤقتات الإخفاء: <code>$($script:AutoHideQueue.Count)</code> · تنبيهات الظهور: <code>$($script:TemplateReminderQueue.Count)</code>")
    $lines.Add("🗓 الأحداث المجدولة القادمة: <code>$(@(Get-UpcomingScheduleEvents).Count)</code>")
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add('<b>👥 الوصول</b>')
    $lines.Add("🔐 المستخدمون المصرح لهم: <code>$(@(Get-JsonProp $config 'AllowedChatIds').Count)</code> محادثة / <code>$(@(Get-JsonProp $config 'AllowedUserIds').Count)</code> مستخدم")
    $lines.Add("🔔 طلبات الوصول المعلّقة: <code>$($script:PendingApprovals.Count)</code>")
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add('<b>🔄 التزامن</b>')
    if ($sync.Failed.Count -gt 0) {
        $lines.Add("⚠️ تعذّر فحص طبقات Cinegy: $($sync.Failed -join '، ') — تم الاحتفاظ بالحالة السابقة.")
    }
    elseif ($sync.Removed.Count -gt 0) {
        $lines.Add("🔄 أُزيلت الطبقات المخفية خارجيًا: $($sync.Removed -join '، ')")
    }
    else { $lines.Add("✅ حالة Cinegy متزامنة.") }
    if ($store.Errors.Count -gt 0) { $lines.Add("⚠️ " + (ConvertTo-TelegramHtmlText ($store.Errors -join "`n⚠️ "))) }
    $statusMenu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    # The same lines, reshaped: the verdict and the identity as the header,
    # the programme and the on-air layers next, and the rest in the sections
    # the text screen already names - unfolded, because this screen is read
    # when something is wrong.
    # Skip 6 rather than 5: the identity line joined the header block, so the
    # count of lines the blocks already carry moved with it.
    $statusBlocks = Get-StatusRichBlocks -Title '📊 الحالة الكاملة' -Overall $overall `
        -Identity (ConvertFrom-TelegramHtmlText $identityLine) -Clock $clockLine -Highlights @($material) `
        -DetailLines @($lines | Select-Object -Skip 6)
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $statusBlocks -ReplyMarkup $statusMenu) { return }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup $statusMenu
}

function Invoke-HealthCommand {
    <# Backward-compatible typed alias. Health is no longer a separate public
       screen; administrators receive it inside the full status report. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Invoke-FullStatusCommand -ChatId $ChatId -UserId $UserId
}

function Get-BridgeDiagnosticsSnapshot {
    $process = Get-Process -Id $PID
    $scriptFile = Join-Path $scriptRoot 'TelegramBridge.ps1'
    $buildTime = if (Test-Path -LiteralPath $scriptFile) { (Get-Item -LiteralPath $scriptFile).LastWriteTimeUtc } else { $null }
    $fileSizes = [ordered]@{}
    foreach ($path in @($ConfigPath, (Get-TemplateRegistryFilePath), $onAirFile, $script:scheduleFile, $script:scheduleExecutionFile, $script:auditFile, $logPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }
        $name = [IO.Path]::GetFileName([string]$path)
        $fileSizes[$name] = if (Test-Path -LiteralPath $path) { [long](Get-Item -LiteralPath $path).Length } else { 0L }
    }
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($scriptRoot)).TrimEnd('\', '/')
    $driveName = $root.TrimEnd(':')
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    $runtimeStorageBytes = 0L
    foreach ($runtimeFile in @(Get-ChildItem -LiteralPath $script:logDir -File -ErrorAction SilentlyContinue)) {
        $length = Get-JsonProp $runtimeFile 'Length'
        if ($null -ne $length) { $runtimeStorageBytes += [long]$length }
    }
    $backupStorageBytes = 0L
    foreach ($backupDir in @("$ConfigPath.backups", "$(Get-TemplateRegistryFilePath).backups")) {
        if (Test-Path -LiteralPath $backupDir) {
            foreach ($backupFile in @(Get-ChildItem -LiteralPath $backupDir -File -Recurse -ErrorAction SilentlyContinue)) {
                $length = Get-JsonProp $backupFile 'Length'
                if ($null -ne $length) { $backupStorageBytes += [long]$length }
            }
        }
    }
    return [pscustomobject]@{
        BuildTimeUtc  = $buildTime
        ProcessStart  = $process.StartTime
        Uptime        = (Get-Date) - $process.StartTime
        Processor     = if ($env:PROCESSOR_IDENTIFIER) { $env:PROCESSOR_IDENTIFIER } else { [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() }
        WorkingSetMB  = [math]::Round($process.WorkingSet64 / 1MB, 1)
        PrivateMemoryMB = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
        DiskFreeGB    = if ($drive) { [math]::Round([double]$drive.Free / 1GB, 2) } else { $null }
        RuntimeStorageBytes = $runtimeStorageBytes
        BackupStorageBytes = $backupStorageBytes
        FileSizes     = $fileSizes
        AirOperations = [pscustomobject]@{
            Success = [int]$script:AirOperationCounters.Success
            Failed  = [int]$script:AirOperationCounters.Failed
            Blocked = [int]$script:AirOperationCounters.Blocked
        }
    }
}

function Get-BridgeRuntimeFiles {
    <# The state files an operator would actually miss. Deliberately not every
       file under logs/: bridge.log and the audit trail are append-only text
       whose health is a different question, and listing twenty rows would bury
       the one that matters. #>
    return @(
        @{ Name = 'onair.json'; Path = $script:onAirFile }
        @{ Name = 'schedule.json'; Path = $script:scheduleFile }
        @{ Name = 'autohide.json'; Path = $script:autoHideFile }
        @{ Name = 'template-reminders.json'; Path = $script:templateReminderFile }
        @{ Name = 'drafts.json'; Path = $script:draftsFile }
        @{ Name = 'news-draft.json'; Path = $script:newsDraftFile }
        @{ Name = 'favorites.json'; Path = $script:userFavoritesFile }
        @{ Name = 'user-profiles.json'; Path = $script:userProfilesFile }
    )
}

function Get-RuntimeFileHealth {
    <# Reads each state file and says whether it would survive a restart.
       "absent" is not a fault: a bridge that never scheduled anything has no
       schedule.json, and colouring that red would train the administrator to
       ignore the screen. A corrupt file with a .bak beside it is recoverable
       because Read-BridgeValidatedJson falls back to that backup on load. #>
    param([Parameter(Mandatory)][object[]]$Files)
    $records = foreach ($file in $Files) {
        $path = [string]$file.Path
        $exists = $path -and (Test-Path -LiteralPath $path -PathType Leaf)
        $valid = $false
        $sizeKB = 0
        $sizeText = ''
        $modified = $null
        if ($exists) {
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($item) {
                $sizeKB = [math]::Round($item.Length / 1KB, 1)
                $sizeText = if ($item.Length -lt 1KB) { "$($item.Length) بايت" } else { "$sizeKB KB" }
                $modified = $item.LastWriteTime
            }
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                try { $null = $raw | ConvertFrom-Json -ErrorAction Stop; $valid = $true }
                catch { $valid = $false }
            }
        }
        $hasBackup = $path -and (Test-Path -LiteralPath "$path.bak" -PathType Leaf)
        $state = if (-not $exists) { 'absent' }
        elseif ($valid) { 'healthy' }
        elseif ($hasBackup) { 'recoverable' }
        else { 'broken' }
        [pscustomobject]@{
            Name = [string]$file.Name; Path = $path; Exists = [bool]$exists; Valid = [bool]$valid
            HasBackup = [bool]$hasBackup; SizeKB = $sizeKB; SizeText = $sizeText; ModifiedAt = $modified; State = $state
        }
    }
    return @($records)
}

function Get-RuntimeFileHealthBlocks {
    <#
        The runtime files as a table, one row per file.

        The other health screen has had a table since 10.1 and this one never
        did, so two halves of the same question looked like different
        products. A file, a state and a sentence about it is three columns.

        Every file gets a row here rather than the healthy ones being folded
        away as they are in the text: a table is read down its state column,
        so eight quiet rows cost nothing to skip, and hiding them would mean
        the screen could not answer "is anything missing" without being
        opened twice.
    #>
    param([AllowNull()][object[]]$Records = $null)
    if ($null -eq $Records) { $Records = @(Get-RuntimeFileHealth -Files (Get-BridgeRuntimeFiles)) }
    $Records = @($Records)

    $faults = @($Records | Where-Object { $_.State -in @('broken', 'recoverable') })
    $verdict = if ($faults.Count -eq 0) { '🟢 كل ملفات التشغيل سليمة.' } else { "🔴 ملفات تحتاج انتباهك: $($faults.Count)" }

    $blocks = @(
        @{ type = 'heading'; text = '🗂 صحة ملفات التشغيل'; size = 3 }
        @{ type = 'paragraph'; text = $verdict }
    )
    if ($Records.Count -eq 0) { return $blocks }

    $cells = @(, @(
            @{ text = 'الملف'; is_header = $true }
            @{ text = 'الحالة'; is_header = $true }
            @{ text = 'التفصيل'; is_header = $true }
        ))
    # Faults first, for the reason the health centre puts them first: on a
    # screen opened because something is wrong, the wrong thing should not be
    # in row six.
    $ordered = @($faults) + @($Records | Where-Object { $_.State -notin @('broken', 'recoverable') })
    foreach ($record in $ordered) {
        $icon = switch ([string]$record.State) {
            'healthy' { '🟢' }
            'absent' { '⚪️' }
            'recoverable' { '🟠' }
            default { '🔴' }
        }
        $detail = switch ([string]$record.State) {
            'healthy' { "$($record.SizeText) · آخر كتابة $(([datetime]$record.ModifiedAt).ToString('HH:mm'))" }
            'absent' { 'لم يُكتب بعد — لا شيء لاستعادته' }
            'recoverable' { 'تالف، لكن توجد نسخة احتياطية يستعيدها الجسر عند الإقلاع' }
            default { 'تالف ولا توجد نسخة احتياطية' }
        }
        $cells += , @(@{ text = [string]$record.Name }, @{ text = $icon }, @{ text = $detail })
    }
    $blocks += @{ type = 'table'; cells = $cells }
    if ($faults.Count -gt 0) {
        $blocks += @{ type = 'paragraph'; text = 'الملف التالف بنسخة احتياطية يُستعاد تلقائيًا عند إعادة التشغيل؛ والتالف بلا نسخة يبدأ فارغًا.' }
    }
    return $blocks
}

function Get-RuntimeFileHealthText {
    param([AllowNull()][object[]]$Records = $null)
    if ($null -eq $Records) { $Records = @(Get-RuntimeFileHealth -Files (Get-BridgeRuntimeFiles)) }
    $Records = @($Records)
    $lines = [System.Collections.Generic.List[string]]::new()
    # parse_mode=HTML. The verdict is the only line that has to be read here -
    # everything under it is the evidence for it - so it is bold, and the file
    # list becomes a blockquote instead of a row of "━━━" drawn above it.
    $lines.Add('<b>🗂 صحة ملفات التشغيل</b>')

    $faults = @($Records | Where-Object { $_.State -in @('broken', 'recoverable') })
    if ($faults.Count -eq 0) {
        $lines.Add('<b>🟢 كل ملفات التشغيل سليمة.</b>')
    }
    else {
        # Side by side, not one inside the other: bold, italic, underline,
        # strikethrough and spoiler entities cannot be combined with code or
        # pre, so <b>…<code>n</code>…</b> is not a nesting Telegram will
        # accept - it is a message the API refuses outright, which reads on the
        # phone as the screen never arriving.
        $lines.Add("<b>🔴 ملفات تحتاج انتباهك:</b> <code>$($faults.Count)</code>")
    }
    $lines.Add('')

    $fileLines = [System.Collections.Generic.List[string]]::new()
    $quietLines = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $Records) {
        $icon = switch ([string]$record.State) {
            'healthy' { '🟢' }
            'absent' { '⚪️' }
            'recoverable' { '🟠' }
            default { '🔴' }
        }
        $detail = switch ([string]$record.State) {
            'healthy' { "$($record.SizeText) · آخر كتابة $(([datetime]$record.ModifiedAt).ToString('HH:mm'))" }
            'absent' { 'لم يُكتب بعد — لا شيء لاستعادته' }
            'recoverable' { 'تالف، لكن توجد نسخة احتياطية يستعيدها الجسر عند الإقلاع' }
            default { 'تالف ولا توجد نسخة احتياطية' }
        }
        # A file that is fine, or has simply never been written, costs one
        # line and no explanation. Only the ones needing something get the
        # second line saying what.
        #
        # Sixteen lines of "لم يُكتب بعد" gave a healthy install the same weight
        # on screen as a broken one, which is the opposite of what a health
        # screen is for.
        if ([string]$record.State -in @('healthy', 'absent')) {
            $quietLines.Add("$icon <code>$(ConvertTo-TelegramHtmlText ([string]$record.Name))</code>")
            continue
        }
        # The file name is <code>: it is a path an administrator retypes or
        # copies into a shell, and monospace keeps it left-to-right whole.
        $fileLines.Add("$icon <code>$(ConvertTo-TelegramHtmlText ([string]$record.Name))</code>")
        $fileLines.Add("      <i>$(ConvertTo-TelegramHtmlText $detail)</i>")
    }
    # Expandable past a handful, because folding is the one thing the quote
    # gives that spacing cannot: the verdict above it and the advice below it
    # both stay on the first screen of a phone instead of being scrolled past.
    # Two lines per file, so the threshold is counted in files.
    # What needs attention first, and outside the quote: it is this screen's
    # answer, not evidence under one. The rest is folded away behind a count.
    if ($fileLines.Count -gt 0) { $lines.Add($fileLines -join "`n") }
    if ($quietLines.Count -gt 0) {
        if ($fileLines.Count -gt 0) { $lines.Add('') }
        $lines.Add("<b>سليمة أو لم تُكتب بعد ($($quietLines.Count)):</b>")
        $tag = if ($quietLines.Count -gt 5) { '<blockquote expandable>' } else { '<blockquote>' }
        $lines.Add("$tag$($quietLines -join "`n")</blockquote>")
    }

    if ($faults.Count -gt 0) {
        $lines.Add('')
        $lines.Add('<i>↳ الملف التالف بنسخة احتياطية يُستعاد تلقائيًا عند إعادة التشغيل.</i>')
        $lines.Add('<i>↳ التالف بلا نسخة يبدأ فارغًا؛ خذ نسخة من المجلد قبل إعادة التشغيل إن كان محتواه مهمًا.</i>')
    }
    return ($lines -join "`n")
}

function Invoke-RuntimeFileHealthCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $keyboard = Get-HealthCenterKeyboard
    # Table first, text as the fallback - the shape every other screen here
    # uses, and the reason this one used to look unlike them.
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-RuntimeFileHealthBlocks) -ReplyMarkup $keyboard) { return }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-RuntimeFileHealthText) -ParseMode HTML -ReplyMarkup $keyboard
}

function Get-BridgeUsageMetrics {
    <# Counted from the in-memory operation history the 🧾 screen already
       reads, so opening the health centre never touches disk or Cinegy. That
       history is capped at 20 per user and rebuilt from audit.jsonl at
       startup, so these are "recent", not lifetime, totals. #>
    $operations = 0
    $operators = 0
    $today = (Get-Date).Date
    foreach ($key in @($script:UserOperationHistory.Keys)) {
        $userOps = @(@($script:UserOperationHistory[$key]) | Where-Object { ([datetime]$_.At).Date -eq $today })
        if ($userOps.Count -gt 0) { $operators++; $operations += $userOps.Count }
    }
    $uptime = (Get-Date) - $script:BridgeStartedAt
    return [pscustomobject]@{
        OperationsToday = $operations
        ActiveOperators = $operators
        OnAirCount      = @($script:OnAir.Keys).Count
        UptimeText      = Format-DurationMinutes -Minutes ([int][math]::Max(0, $uptime.TotalMinutes))
    }
}

function Get-BridgeHealthRows {
    <#
        One row per subsystem: the name, a state glyph, a glyph for the
        subsystem itself, and the detail.

        The state glyph and the identity glyph are different jobs. A column of
        seven 🟢 says everything is fine and nothing about which row is which;
        📡 🎛 👁 📶 💾 📅 ⚠️ are told apart at a glance and at arm's length,
        which is how this screen is actually read.

        Extracted so the text screen and the block screen cannot drift into
        disagreeing about whether something is healthy - the same reason the
        two digest screens read the audit log through one function.

        The glyph is its own field rather than part of the sentence because a
        table can then give it a column of its own, and a column of glyphs is
        what makes the one red line findable without reading the other six.
    #>
    param($DiagnosticsSnapshot, [AllowNull()][object[]]$Warnings)
    $rows = @()

    $telegramState = [string]$script:RuntimeState.Monitoring.TelegramConnectionState
    $rows += switch ($telegramState) {
        'connected' { @{ Name = 'Telegram'; Glyph = '📡'; Icon = '🟢'; Detail = 'متصل' } }
        'disconnected' { @{ Name = 'Telegram'; Glyph = '📡'; Icon = '🔴'; Detail = 'غير متصل' } }
        default { @{ Name = 'Telegram'; Glyph = '📡'; Icon = '🟠'; Detail = 'لم تُحسم الحالة' } }
    }

    $cinegyState = [string]$script:RuntimeState.Monitoring.CinegyHealthState
    $rows += switch ($cinegyState) {
        'healthy' { @{ Name = 'Cinegy'; Glyph = '🎛'; Icon = '🟢'; Detail = 'سليم' } }
        'unhealthy' { @{ Name = 'Cinegy'; Glyph = '🎛'; Icon = '🔴'; Detail = 'غير سليم' } }
        default { @{ Name = 'Cinegy'; Glyph = '🎛'; Icon = '🟠'; Detail = 'الحالة غير معروفة' } }
    }

    $monitorDisabled = (Get-SettingInt 'OutputMonitorMinutes') -le 0
    $monitorFault = [bool]$script:OutputMonitorFailureAlerted -or [bool]$script:OutputBlackAlerted
    $rows += if ($monitorDisabled) { @{ Name = 'مراقبة المخرج'; Glyph = '👁'; Icon = '🟢'; Detail = 'معطلة باختيار المشرف' } }
    elseif ($monitorFault) { @{ Name = 'مراقبة المخرج'; Glyph = '👁'; Icon = '🔴'; Detail = "إنذار نشط (فشل متتالٍ: $script:OutputMonitorFailureCount)" } }
    else { @{ Name = 'مراقبة المخرج'; Glyph = '👁'; Icon = '🟢'; Detail = 'سليمة' } }

    $relay = $script:RuntimeState.Relay
    $rows += if (-not [bool]$relay.ShouldRun) { @{ Name = 'البث المرحّل'; Glyph = '📶'; Icon = '🟢'; Detail = 'غير مطلوب' } }
    elseif ($relay.Process -and -not $relay.Process.HasExited) { @{ Name = 'البث المرحّل'; Glyph = '📶'; Icon = '🟢'; Detail = 'يعمل' } }
    else { @{ Name = 'البث المرحّل'; Glyph = '📶'; Icon = '🔴'; Detail = 'مطلوب لكنه متوقف' } }

    $diskText = if ($null -ne $DiagnosticsSnapshot.DiskFreeGB) { "$($DiagnosticsSnapshot.DiskFreeGB) GB متاح" } else { 'المساحة غير معروفة' }
    $rows += if (@($Warnings).Count -gt 0) { @{ Name = 'التخزين'; Glyph = '💾'; Icon = '🟠'; Detail = "$diskText — $(Get-ArabicCountNoun -Count (@($Warnings).Count) -One 'تحذير' -Two 'تحذيران' -Few 'تحذيرات' -Many 'تحذيرًا')" } }
    else { @{ Name = 'التخزين'; Glyph = '💾'; Icon = '🟢'; Detail = $diskText } }

    $upcomingCount = @((Get-UpcomingScheduleEvents)).Count
    $upcomingText = Get-ArabicCountNoun -Count $upcomingCount -One 'حدث' -Two 'حدثان' -Few 'أحداث' -Many 'حدثًا'
    $rows += if (Get-Setting 'SchedulePaused') { @{ Name = 'الجدولة'; Glyph = '📅'; Icon = '🟠'; Detail = "متوقفة مؤقتًا — $upcomingText قادم" } }
    else { @{ Name = 'الجدولة'; Glyph = '📅'; Icon = '🟢'; Detail = "$upcomingText قادم" } }

    $recentErrors = @()
    foreach ($service in @('Telegram', 'Cinegy')) {
        $history = $script:HealthHistory[$service]
        if ($history.LastErrorAt -and $history.LastError) {
            $recentErrors += "${service}: $(Protect-SensitiveText ([string]$history.LastError))"
        }
    }
    $rows += if ($recentErrors.Count -gt 0) { @{ Name = 'آخر الأخطاء'; Glyph = '⚠️'; Icon = '🟠'; Detail = ($recentErrors -join ' | ') } }
    else { @{ Name = 'آخر الأخطاء'; Glyph = '⚠️'; Icon = '🟢'; Detail = 'لا شيء' } }

    return $rows
}

function Save-HealthSnapshot {
    <#
        Writes the same rows "🩺 مركز صحة النظام" shows an admin to
        logs/health-snapshot.json, throttled like Save-UsageCounts (60s, not
        every tick) since disk-free and file-size checks are not free.

        BridgeManager is a separate .NET process that only ever sees this
        process's uptime (from manager.log) and template usage counts - it has
        no way to know Telegram disconnected, Cinegy went unhealthy, or the
        output monitor has an active alarm while the process itself stays up.
        This file is that bridge, read-only, no new port or IPC.
    #>
    if (((Get-Date) - $script:LastHealthSnapshotFlush).TotalSeconds -lt 60) { return }
    $script:LastHealthSnapshotFlush = Get-Date
    try {
        $diagnostics = Get-BridgeDiagnosticsSnapshot
        $warnings = @(Get-DiagnosticWarnings -Snapshot $diagnostics `
                -DiskFreeWarningGB (Get-SettingInt 'DiskFreeWarningGB' 1) `
                -RuntimeStorageWarningMB (Get-SettingInt 'RuntimeStorageWarningMB' 1) `
                -BackupStorageWarningMB (Get-SettingInt 'BackupStorageWarningMB' 1))
        $rows = @(Get-BridgeHealthRows -DiagnosticsSnapshot $diagnostics -Warnings $warnings)
        $payload = [ordered]@{
            GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Rows         = @($rows | ForEach-Object { [ordered]@{ Name = [string]$_.Name; Icon = [string]$_.Icon; Detail = [string]$_.Detail } })
        }
        Write-BridgeValidatedJson -Path $script:healthSnapshotFile -Json ($payload | ConvertTo-Json -Depth 4) | Out-Null
    }
    catch { Write-BridgeLog "Could not write health-snapshot.json: $($_.Exception.Message)" "WARN" }
}

function Get-BridgeHealthCenterBlocks {
    <#
        The health screen as a table, so the state column can be read down.

        Seven sentences each beginning with a coloured circle is a paragraph
        the eye has to parse one line at a time. A column of them is scanned
        in one movement, which is the whole job of this screen: find the red
        one. The detail keeps its own column rather than being folded away -
        a health screen that hides why something is red is a screen that has
        to be opened twice.
    #>
    param($DiagnosticsSnapshot = $null, [AllowNull()][object[]]$Warnings = $null)
    if ($null -eq $DiagnosticsSnapshot) { $DiagnosticsSnapshot = Get-BridgeDiagnosticsSnapshot }
    if (-not $PSBoundParameters.ContainsKey('Warnings')) {
        $Warnings = @(Get-DiagnosticWarnings -Snapshot $DiagnosticsSnapshot `
                -DiskFreeWarningGB (Get-SettingInt 'DiskFreeWarningGB' 1) `
                -RuntimeStorageWarningMB (Get-SettingInt 'RuntimeStorageWarningMB' 1) `
                -BackupStorageWarningMB (Get-SettingInt 'BackupStorageWarningMB' 1))
    }
    $rows = @(Get-BridgeHealthRows -DiagnosticsSnapshot $DiagnosticsSnapshot -Warnings @($Warnings))

    $blocks = @(@{ type = 'heading'; text = '🩺 مركز صحة النظام'; size = 3 })
    $blocks += @{ type = 'paragraph'; text = "Bridge v$script:BridgeVersion" }

    # Faults first. On a screen opened because something is wrong, the wrong
    # thing should not be in row six.
    $faults = @($rows | Where-Object { $_.Icon -ne '🟢' })
    $healthy = @($rows | Where-Object { $_.Icon -eq '🟢' })
    $cells = @(, @(
            @{ text = 'النظام'; is_header = $true }
            @{ text = 'الحالة'; is_header = $true }
            @{ text = 'التفصيل'; is_header = $true }
        ))
    foreach ($row in ($faults + $healthy)) {
        $cells += , @(@{ text = [string]$row.Name }, @{ text = [string]$row.Icon }, @{ text = [string]$row.Detail })
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }

    $usage = Get-BridgeUsageMetrics
    $operationsText = Get-ArabicCountNoun -Count $usage.OperationsToday -One 'عملية' -Two 'عمليتان' -Few 'عمليات' -Many 'عملية'
    $operatorsText = Get-ArabicCountNoun -Count $usage.ActiveOperators -One 'مشغّل' -Two 'مشغّلان' -Few 'مشغّلين' -Many 'مشغّلًا'
    $blocks += @{ type = 'paragraph'; text = "📈 الاستخدام: $operationsText اليوم · $operatorsText · $($usage.OnAirCount) على الهواء" }
    return $blocks
}

function Get-BridgeHealthCenterText {
    <# The same rows the block screen renders, as lines. Both read
       Get-BridgeHealthRows so the two can never disagree about whether
       something is healthy. #>
    param(
        $DiagnosticsSnapshot = $null,
        [AllowNull()][object[]]$Warnings = $null
    )
    if ($null -eq $DiagnosticsSnapshot) { $DiagnosticsSnapshot = Get-BridgeDiagnosticsSnapshot }
    if (-not $PSBoundParameters.ContainsKey('Warnings')) {
        $Warnings = @(Get-DiagnosticWarnings -Snapshot $DiagnosticsSnapshot `
                -DiskFreeWarningGB (Get-SettingInt 'DiskFreeWarningGB' 1) `
                -RuntimeStorageWarningMB (Get-SettingInt 'RuntimeStorageWarningMB' 1) `
                -BackupStorageWarningMB (Get-SettingInt 'BackupStorageWarningMB' 1))
    }
    $rows = @(Get-BridgeHealthRows -DiagnosticsSnapshot $DiagnosticsSnapshot -Warnings @($Warnings))
    $usage = Get-BridgeUsageMetrics
    # parse_mode=HTML. Each row is a name and a verdict, and in flat text the
    # name was indistinguishable from the verdict beside it; bold on the name
    # is what lets the column be read down. Row names and details come from
    # Get-BridgeHealthRows, built out of settings and paths the station
    # controls, so both are escaped.
    # Same shape as 🗂 صحة ملفات التشغيل: what needs attention is the
    # screen's answer and stays outside the quote, and what is fine is folded
    # behind a count. Order inside each group is untouched - sorting the whole
    # list by severity would move Cinegy off the second row and cost an
    # operator the place they have learned to look.
    # Ordinary text at full size, not a <pre> table. A monospace block does
    # align its columns, and Telegram draws it two sizes down - which on a
    # phone costs more legibility than the alignment buys. The reports
    # screens never used one, and they are the ones that read well.
    #
    # The rhythm comes from every line opening with the same two glyph slots
    # instead: state, then identity. That is a column the eye follows without
    # any character having been counted.
    #
    # Get-JsonProp, not .Contains: these rows arrive as hashtables from
    # Get-BridgeHealthRows and as PSCustomObjects from anything built out of
    # JSON, and only this helper reads both without throwing under StrictMode.
    $render = {
        param($row)
        $glyph = [string](Get-JsonProp $row 'Glyph')
        $lead = if ($glyph) { "$([string]$row.Icon) $glyph" } else { [string]$row.Icon }
        "$lead <b>$(ConvertTo-TelegramHtmlText ([string]$row.Name))</b> — $(ConvertTo-TelegramHtmlText ([string]$row.Detail))"
    }
    $problemRows = @($rows | Where-Object { [string]$_.Icon -ne '🟢' } | ForEach-Object { & $render $_ })
    $healthyRows = @($rows | Where-Object { [string]$_.Icon -eq '🟢' } | ForEach-Object { & $render $_ })
    # The verdict the seven rows already imply, said once at the top. This
    # screen is opened to answer one question - is anything wrong? - and it
    # answered only by making the operator read every row and notice a colour.
    # The rows stay underneath as the evidence for it.
    #
    # Read off the icons the rows carry rather than recomputed, so the heading
    # and the rows can never disagree about the same reading.
    $icons = @($rows | ForEach-Object { [string]$_.Icon })
    $verdict = if ($icons -contains '🔴') { '🔴 عطلٌ يحتاج تدخلًا' }
    elseif ($icons -contains '🟠') { '🟠 يحتاج مراجعة' }
    else { '🟢 كل شيء سليم' }

    return @(
        '<b>🩺 مركز صحة النظام</b>'
        "🕒 <code>$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))</code> · Bridge <code>v$script:BridgeVersion</code>"
        "<b>$verdict</b>"
        ''
        $(if ($problemRows.Count -gt 0) { "<b>⚠️ يحتاج انتباهك ($($problemRows.Count))</b>`n$($problemRows -join "`n")`n" })
        $(if ($healthyRows.Count -gt 0) {
                $tag = if ($healthyRows.Count -gt 5) { '<blockquote expandable>' } else { '<blockquote>' }
                "<b>✅ سليم ($($healthyRows.Count))</b>`n$tag$($healthyRows -join "`n")</blockquote>"
            })
        ''
        "<b>📈 الاستخدام</b>: <code>$($usage.OperationsToday)</code> عملية اليوم · <code>$($usage.ActiveOperators)</code> مشغّل · <code>$($usage.OnAirCount)</code> على الهواء"
    ) -join "`n"
}

function Show-EngineHealthScreen {
    <#
        F9: one screen answering "is the engine itself well" - verdict first,
        then dropped frames as a delta since the last look (the raw counter
        is cumulative since engine start and reads as a scare), the license
        state, and what is playing underneath.

        Opt-in behind EnableEngineHealth, off by default: it measures the box
        on every open, and an unasked measurement is load without a reader.
        All three reads are GETs; nothing here changes air.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableEngineHealth')) {
        Send-TelegramMessage -ChatId $ChatId -Text 'شاشة صحة المحرك معطلة افتراضيًا. يفعّلها المشرف من الإعدادات (صحة المحرك) إن أرادها.' -ReplyMarkup (Get-HealthCenterKeyboard)
        return
    }
    $timeout = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1
    $telemetry = Get-AirTelemetryStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
    $video = Get-AirVideoStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<b>🖥 صحة المحرك</b>')
    if (-not $telemetry.Success) {
        $lines.Add('⚠️ تعذّر قراءة عدادات المحرك من القناة.')
    }
    else {
        $dropped = [long]$telemetry.DroppedCount
        $deltaLine = ''
        if ($script:LastEngineDropped -ge 0 -and $dropped -ge $script:LastEngineDropped) {
            $delta = $dropped - $script:LastEngineDropped
            if ($delta -gt 0) { $deltaLine = " (+$delta منذ آخر فحص)" }
        }
        $script:LastEngineDropped = $dropped
        $verdict = if ($telemetry.Healthy -eq $false) { '🔴 تحذير' }
        elseif ([long]$telemetry.NoInputSignal -gt 0) { '🟠 بلا إشارة دخل' }
        else { '🟢 سليم' }
        $lines.Add("<b>$verdict</b>")
        $lines.Add("🎞 الإطارات — المخرَجة: $($telemetry.OutputCount) · الساقطة: $dropped$deltaLine")
        $lines.Add("⏱ متوسط القراءة: $($telemetry.AverageReadTime)ms · أخطاء القراءة: $($telemetry.MaxReadErrorRate)%")
    }
    $license = [string](Get-JsonProp $video 'License')
    if (-not [string]::IsNullOrWhiteSpace($license)) {
        $safeLicense = ConvertTo-TelegramHtmlText $license
        $licenseLine = if ($license -eq 'Licensed') { "📄 الترخيص: $safeLicense" } else { "📄 الترخيص: <b>$safeLicense</b> — تحقق من ترخيص المحرك" }
        $lines.Add($licenseLine)
    }
    $material = Get-AirMaterialNowNext -TimeoutSec $timeout
    if ($material) { $lines.Add(''); $lines.Add($material) }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup (Get-HealthCenterKeyboard)
}

function Invoke-HealthCenterCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $healthKeyboard = Get-HealthCenterKeyboard
    # Table first so the state column can be read down; the lines remain
    # the fallback, and they are built from the same rows.
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-BridgeHealthCenterBlocks) -ReplyMarkup $healthKeyboard) { return }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-BridgeHealthCenterText) -ParseMode HTML -ReplyMarkup $healthKeyboard
}

function Start-TemplateTestReview {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId) -or -not (Get-Setting 'EnableFullTemplateManagement')) { return }
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { Send-TelegramMessage -ChatId $ChatId -Text 'القالب لم يعد موجودًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard); return }
    $testLayer = Get-SettingInt 'TemplateTestLayer' 0
    if ($testLayer -le 0) { Send-TelegramMessage -ChatId $ChatId -Text 'طبقة تجربة القوالب معطلة. اضبط TemplateTestLayer أولاً.' -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex); return }
    if (@(Get-KnownLayers | ForEach-Object { [int]$_ }) -contains $testLayer) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ طبقة التجربة $testLayer مستخدمة كطبقة إنتاج في سجل القوالب. اختر طبقة مستقلة." -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex)
        return
    }
    $seconds = [math]::Min(300, (Get-SettingInt 'TemplateTestAutoHideSeconds' 3))
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_test_review'; UserId=$UserId; TemplateIndex=$TemplateIndex; TestLayer=$testLayer; AutoHideSeconds=$seconds }
    Send-TelegramMessage -ChatId $ChatId -Text "🧪 مراجعة اختبار القالب '$($template.Key)'`nطبقة التجربة المستقلة: $testLayer`nقيم الحقول: TEST`nالإخفاء التلقائي: $(Get-ArabicCountNoun -Count $seconds -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية')`n`nسيُفحص أن الطبقة فارغة مباشرة قبل الاختبار." -ReplyMarkup (Get-TemplateTestReviewKeyboard)
}

function Get-BridgeSupervisor {
    <#
        Works out whether something will start the bridge again if it exits.

        This is the whole safety question behind a restart button. Under the
        NSSM service (AppExit Default Restart) or the scheduled task
        (RestartCount 999) exiting is a restart. Started by hand from a
        console it is just an outage - on a playout machine, with nobody
        necessarily in the room, and no way back in through the bot that
        just stopped.

        Returns Name and Supervised; walks the parent process because that is
        the only thing that actually distinguishes the cases.

        Supervised = $false is not the end of the answer any more: the bridge
        can also put itself back (see Get-BridgeRelaunchCommand), which is the
        only route available when it was started by hand from a terminal.
    #>
    try {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId = $($current.ParentProcessId)" -ErrorAction Stop
        $name = [string]$parent.Name
    }
    catch { return [pscustomobject]@{ Name = 'unknown'; Supervised = $false } }

    switch -Wildcard ($name) {
        'nssm*' { return [pscustomobject]@{ Name = $name; Supervised = $true } }
        'services.exe' { return [pscustomobject]@{ Name = $name; Supervised = $true } }
        'svchost.exe' { return [pscustomobject]@{ Name = $name; Supervised = $true } }   # Task Scheduler
        'taskeng.exe' { return [pscustomobject]@{ Name = $name; Supervised = $true } }
        default { return [pscustomobject]@{ Name = $name; Supervised = $false } }
    }
}

function Get-OtherBridgeProcess {
    <#
        Every other process running this same script.

        Matched on this bridge's complete -File path. Matching only the
        TelegramBridge.ps1 name can stop an unrelated checkout or station.

        Own PID excluded, for the obvious reason.
    #>
    try {
        $scriptPath = [string]$script:BridgeLaunch.ScriptPath
        if ([string]::IsNullOrWhiteSpace($scriptPath)) { return @() }
        $pathPattern = [regex]::Escape([IO.Path]::GetFullPath($scriptPath))
        $filePattern = '(?i)(?:^|\s)-File\s+(?:"' + $pathPattern + '"|' + $pathPattern + ')(?=\s|$)'
        return @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction Stop |
                Where-Object { [int]$_.ProcessId -ne $PID -and [string]$_.CommandLine -match $filePattern } |
                ForEach-Object {
                    [pscustomobject]@{
                        ProcessId   = [int]$_.ProcessId
                        StartedAt   = $_.CreationDate
                        CommandLine = [string]$_.CommandLine
                    }
                })
    }
    catch {
        # Said out loud, because the caller turns an empty answer into a
        # specific claim - "the lock is held by a console that ran one and
        # stayed open" - and that sentence is wrong when the truth is that the
        # query itself failed. Fail open on the list, never on the wording.
        Write-Host "  (could not enumerate bridge processes: $($_.Exception.Message))"
        return @()
    }
}

function Get-BridgeRelaunchCommand {
    <#
        Rebuilds the command that started this process, so the bridge can put
        itself back without a service behind it.

        Started by hand from a terminal - which is how this is run during a
        shift, from the VS Code console - nothing external will restart it, so
        before this the restart button simply refused. It now relaunches
        itself and the operator gets the same bridge back in the same window.

        The paths are rebuilt from known-good values rather than parsed out of
        Win32_Process.CommandLine: re-quoting a path containing a space is the
        one thing a command-line round trip reliably gets wrong, and this
        bridge lives in "D:\cingy cg\". The raw command line is read only to
        carry the host flags across, where a wrong answer costs nothing.

        Returns $null when the pieces are not there - dot-sourced in the test
        suite, for instance - so the caller can decline instead of launching
        something that is not this bridge.
    #>
    $exe = [Environment]::ProcessPath
    if ([string]::IsNullOrWhiteSpace($exe) -or -not (Test-Path -LiteralPath $exe)) { return $null }
    if (-not $script:BridgeLaunch) { return $null }
    $scriptPath = [string]$script:BridgeLaunch.ScriptPath
    if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) { return $null }

    $raw = ''
    try { $raw = [string](Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).CommandLine }
    catch { $raw = '' }

    # Quoted here rather than left to Start-Process: -ArgumentList joins an
    # array with spaces and adds no quotes of its own, so an unquoted
    # "D:\cingy cg\...\TelegramBridge.ps1" arrives at the new process as
    # "-File D:\cingy" and the restart dies with "not recognized as the name
    # of a script file". Confirmed by running it, not by reading the docs.
    $quote = { param([string]$Value)
        if ($Value -match '[\s"]') { '"' + ($Value -replace '"', '\"') + '"' } else { $Value } }

    $arguments = @()
    foreach ($flag in @('-NoProfile', '-NonInteractive', '-NoLogo')) {
        if ($raw -match "(?i)(^|\s)$flag\b") { $arguments += $flag }
    }
    $arguments += @('-File', (& $quote $scriptPath), '-ConfigPath', (& $quote ([string]$script:BridgeLaunch.ConfigPath)))
    if (-not [string]::IsNullOrWhiteSpace([string]$script:BridgeLaunch.RuntimePath)) {
        $arguments += @('-RuntimePath', (& $quote ([string]$script:BridgeLaunch.RuntimePath)))
    }
    if ($script:BridgeLaunch.AllowMultipleInstances) { $arguments += '-AllowMultipleInstances' }
    $requireSingleInstance = $false
    if ($script:BridgeLaunch -is [System.Collections.IDictionary]) {
        if ($script:BridgeLaunch.Contains('RequireSingleInstance')) {
            $requireSingleInstance = [bool]$script:BridgeLaunch['RequireSingleInstance']
        }
    }
    else {
        $property = $script:BridgeLaunch.PSObject.Properties['RequireSingleInstance']
        if ($property) { $requireSingleInstance = [bool]$property.Value }
    }
    if ($requireSingleInstance) { $arguments += '-RequireSingleInstance' }

    return [pscustomobject]@{
        FilePath         = $exe
        Arguments        = $arguments
        WorkingDirectory = [string]$script:BridgeLaunch.WorkingDirectory
    }
}

function Request-BridgeRestart {
    <# Shows what will happen and who is expected to bring the bridge back,
       then asks. Never restarts on the first tap. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $false }
    if (-not (Get-Setting 'AllowRemoteRestart')) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ إعادة التشغيل من البوت معطّلة.`nفعّل AllowRemoteRestart من الإعدادات، وتأكد أولًا أن الجسر يعمل كخدمة أو كمهمة مجدولة تعيد تشغيله." -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    $supervisor = Get-BridgeSupervisor
    # Who brings it back, in order of preference: an external supervisor if
    # there is one, otherwise the bridge relaunches itself. Only when neither
    # is possible is the button refused, because exiting then really would be
    # an outage with no way back in through the bot that just stopped.
    $relaunch = if ($supervisor.Supervised) { $null } else { Get-BridgeRelaunchCommand }
    if (-not $supervisor.Supervised -and -not $relaunch) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لا توجد وسيلة لإعادة تشغيل الجسر (العملية الأصل: $($supervisor.Name))، ولا يمكن إعادة بناء أمر التشغيل.`nالخروج الآن يعني توقف البوت نهائيًا بلا وسيلة لإعادته من هنا." -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    $who = if ($supervisor.Supervised) { $supervisor.Name } else { 'الجسر نفسه' }
    $live = if ($script:OnAir.Count -gt 0) { "`n⚠️ يوجد $($script:OnAir.Count) مشهدًا مسجّلًا على الهواء. إعادة التشغيل لا تغيّر ما هو على الشاشة، لكن البوت لن يستجيب لثوانٍ." } else { '' }
    Send-TelegramMessage -ChatId $ChatId -Text ("♻️ تأكيد إعادة تشغيل الجسر`nستتوقف الاستجابة بضع ثوانٍ ثم يعيده $who تلقائيًا.$live") `
        -ReplyMarkup @{ inline_keyboard = @(, @(
                @{ text = '✅ نعم، أعد التشغيل'; callback_data = 'restart:confirm'; style = 'danger' },
                @{ text = '❌ إلغاء'; callback_data = 'menu:admintools' })) }
    return $true
}

function Confirm-BridgeRestart {
    <# Signals the polling loop to leave. Exiting through the loop rather than
       calling exit here matters: the script's finally block stops snapshot
       jobs and the relay, saves counters, and releases the single-instance
       mutex. Killing the process from inside a callback would skip all of it
       and the replacement instance would find the mutex still held. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $false }
    if (-not (Get-Setting 'AllowRemoteRestart')) { return $false }
    Write-BridgeLog "Administrator $UserId requested a restart from Telegram" 'WARN'
    Add-AuditEntry "♻️ إعادة تشغيل الجسر - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text '♻️ يُعاد التشغيل الآن… أرسل /بدء بعد قليل للتأكد من عودته.'
    # Decided here rather than at exit. Under a supervisor the bridge must NOT
    # start its own replacement: the supervisor starts one too, and two bridges
    # long-polling one bot token means button presses vanish into whichever
    # instance happened to receive them.
    $script:RestartSelfRelaunch = -not (Get-BridgeSupervisor).Supervised
    $script:RestartRequested = $true
    return $true
}
