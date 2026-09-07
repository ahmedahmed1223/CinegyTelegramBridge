#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-AirTimeout {
    <# Air Pro sits on localhost or the local LAN, so the module's 10s default
       is far too generous: every graphics command blocks the single polling
       loop for its full timeout, and 🚨 إخفاء الكل multiplies that by the
       number of layers - on the one button that gets pressed in a crisis. #>
    $value = Get-SettingInt 'AirCommandTimeoutSeconds' 1
    if ($value -le 0) { $value = 3 }
    return $value
}

function Get-OnAirSummary {
    <# Shows the bridge's tracked layers after they have been reconciled with
       Cinegy. Externally started scenes cannot be named reliably, but a scene
       hidden outside the bridge is removed by Update-OnAirStateFromCinegy. #>
    if ($script:OnAir.Count -eq 0) { return "📺 المشاهد النشطة`n• لا توجد مشاهد على الهواء حسب آخر فحص." }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('📺 المشاهد النشطة')
    foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
        $info = $script:OnAir[$layer]
        # A ticker up since yesterday used to read "1560 دقيقة".
        $age = [math]::Max(0, [int]((Get-Date) - $info.At).TotalSeconds)
        $ageText = Format-DurationSeconds -Seconds $age
        $source = [string](Get-JsonProp $info 'Source')
        if ($source -eq 'cinegy') {
            $eventName = [string](Get-JsonProp $info 'CinegyEventName')
            $detail = "   المصدر: Cinegy Air · منذ $ageText"
            if ($eventName) { $detail += " · الحدث: $eventName" }
            $lines.Add("🟣 $(Get-LayerDisplayName -Layer ([int]$layer)) · $($info.Key)")
            $lines.Add($detail)
        }
        else {
            $operator = if ($null -ne $info.UserId -and [long]$info.UserId -gt 0) { Get-UserDisplayName -UserId ([long]$info.UserId) } else { 'غير معروف' }
            $lines.Add("🔵 $(Get-LayerDisplayName -Layer ([int]$layer)) · $($info.Key)")
            $lines.Add("   المصدر: Bot · المستخدم: $operator · منذ $ageText")
        }
    }
    return ($lines -join "`n")
}

function Get-OnAirTableBlocks {
    <#
        What is on air, as a table.

        This is the one genuinely tabular thing on a status screen - a layer,
        what is on it, since when - and it was a run-on sentence. Four
        columns, like every other table here, because Telegram divides the
        width evenly and a fifth would take a fifth of the phone.
    #>
    param([datetime]$Now = (Get-Date))
    if ($script:OnAir.Count -eq 0) {
        return @(@{ type = 'paragraph'; text = '⚫️ لا شيء على الهواء' })
    }
    $cells = @(, @(
            @{ text = 'الطبقة'; is_header = $true }
            @{ text = 'القالب'; is_header = $true }
            @{ text = 'منذ'; is_header = $true }
            @{ text = 'المشغّل'; is_header = $true }
        ))
    foreach ($layer in @($script:OnAir.Keys | Sort-Object)) {
        $record = $script:OnAir[$layer]
        $atValue = Get-JsonProp $record 'At'
        $since = if ($atValue) {
            $at = [datetime]$atValue
            $seconds = [math]::Max(0, [int]($Now - $at).TotalSeconds)
            # "منذ 0 ثانية" is a strange way to say it just went up.
            if ($seconds -lt 5) { 'الآن' } else { Format-DurationSeconds -Seconds $seconds }
        }
        else { '—' }
        $who = Get-AuditOperatorName -UserId ([string](Get-JsonProp $record 'UserId'))
        $cells += , @(
            @{ text = [string]$layer }
            @{ text = [string](Get-JsonProp $record 'Key') }
            @{ text = $since }
            @{ text = $(if ($who) { $who } else { '—' }) }
        )
    }
    return @(@{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true })
}

function Get-StatusRichBlocks {
    <#
        A status screen as blocks: the verdict, what is on air, and the
        machine detail folded under it.

        The lines are passed in rather than rebuilt, so the block screen and
        the text screen cannot disagree - they are the same strings. Only the
        shape differs: the verdict gets a heading, the on-air layers get a
        table, and the rest becomes the detail nobody reads unless the
        verdict says to.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Overall,
        [AllowNull()][object[]]$DetailLines = $null,
        [string]$DetailSummary = '🔍 التفاصيل',
        [AllowEmptyString()][string]$Identity = ''
    )
    $blocks = @(@{ type = 'heading'; text = "$Title — v$($script:BridgeVersion)"; size = 3 })
    $blocks += @{ type = 'paragraph'; text = $Overall }
    # Above the fold rather than inside the collapsed detail: the id is what
    # an operator is asked for when requesting access or reporting a fault,
    # and a fact you have to expand a section to reach is a fact people
    # screenshot wrongly. It is kept out of the details list so it appears
    # exactly once on the screen.
    if (-not [string]::IsNullOrWhiteSpace($Identity)) {
        $blocks += @{ type = 'paragraph'; text = $Identity }
    }
    $blocks += @{ type = 'divider' }
    $blocks += @(Get-OnAirTableBlocks)
    # Blank separators are a text-screen device; as blocks they would be empty
    # paragraphs, which render as gaps that look like something failed.
    $detail = @(@($DetailLines) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { @{ type = 'paragraph'; text = [string]$_ } })
    if ($detail.Count -gt 0) {
        $blocks += @{ type = 'details'; summary = $DetailSummary; blocks = $detail }
    }
    return $blocks
}

function Invoke-StatusCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (Test-UserDisabled -UserId $UserId) { return $false }
    $store = Get-TemplateStore
    $layerStatuses = @(Get-CinegyLayerDashboard)
    $sync = Update-OnAirStateFromCinegy -Reason 'status' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal

    # Quick overall line so a non-admin glance shows whether anything is off.
    if ($sync.Failed.Count -gt 0) {
        $overall = "🟠 تعذّر فحص بعض الطبقات"
    }
    elseif ($script:OnAir.Count -gt 0) {
        $overall = "🟠 طبقات على الهواء"
    }
    else {
        $overall = "🟢 كل شيء سليم"
    }

    $sep = '━━━━━━━━━━━━━━━━━'
    $now = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()
    # Built as parse_mode=HTML from here down. This fallback is the screen an
    # operator actually reads - sendRichMessage is Bot API 10.1 and most
    # servers refuse it - so it is the design rather than a degraded copy, and
    # it was going out as one flat undifferentiated column of text.
    #
    # <code> on the clock, the address and the counts is not decoration: it
    # renders monospace and left-to-right, which stops digits reordering
    # against the Arabic around them, and Telegram makes each one tap-to-copy
    # for an operator quoting it in a fault report.
    $lines.Add("<b>ℹ️ الحالة</b> — <code>v$($script:BridgeVersion)</code>")
    $lines.Add("🕒 <code>$($now.ToString('yyyy-MM-dd HH:mm:ss'))</code> (محلي)")
    $lines.Add("<b>$overall</b>")
    # Format-UserAuditActor, not a bare id: it resolves the alias when there is
    # one and pins the bracketed digits to LTR, so an Arabic name followed by
    # an id does not render as ")8201739556(".
    $identityLine = "👤 معرّفك: $(ConvertTo-TelegramHtmlText (Format-UserAuditActor -UserId $UserId))"
    $lines.Add($identityLine)
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add("🌐 <code>$(ConvertTo-TelegramHtmlText ([string]$config.AirServerAddress))</code> · القناة <code>$($config.AirChannelNumber)</code> · القوالب: <code>$($store.Order.Count)</code>")
    $sharedLayers = Get-JsonProp $store 'SharedLayers'
    if ($sharedLayers -and $sharedLayers.Count -gt 0) {
        $sharedText = ConvertTo-TelegramHtmlText (@($sharedLayers.Keys | Sort-Object {[int]$_} | ForEach-Object { "طبقة ${_}: $(@($sharedLayers[$_]) -join '، ')" }) -join ' | ')
        # Not 'allowed' - a Cinegy GFX layer holds one scene, so templates
        # sharing a layer can never be on air together. Calling that harmless
        # is how a logo and a ticker end up silently evicting each other.
        $lines.Add("⚠️ قوالب تتشارك الطبقة نفسها ولا يمكن عرضها معًا: $sharedText")
    }
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: <b>$(ConvertTo-TelegramHtmlText ([string]$freshness.Label))</b>")
    if ($lastSuccessfulAt) {
        # "منذ 12 ثانية" answers the question being asked - is this current? -
        # which a bare timestamp leaves the reader to work out against a clock.
        # The clock time stays, in brackets, for anyone comparing with a log.
        $checkedAt = [datetime]$lastSuccessfulAt
        $agoSeconds = [math]::Max(0, [int]($now - $checkedAt).TotalSeconds)
        # "منذ 0 ثانية" is a strange way to say "just now".
        $ago = if ($agoSeconds -lt 5) { 'الآن' } else { "منذ $(Format-DurationSeconds -Seconds $agoSeconds)" }
        $lines.Add("🔄 آخر فحص ناجح: <i>$ago</i> (<code>$($checkedAt.ToString('HH:mm:ss'))</code>)")
    }
    $lines.Add((ConvertTo-TelegramHtmlText (Get-OnAirSummary)))
    $lines.Add('')
    $lines.Add($sep)
    if ($sync.Failed.Count -gt 0) {
        $lines.Add("⚠️ تعذّر فحص طبقات Cinegy: $($sync.Failed -join '، ') — تم الاحتفاظ بالحالة السابقة.")
    }
    elseif ($sync.Removed.Count -gt 0) {
        $lines.Add("🔄 تم تحديث الحالة وأُزيلت الطبقات المخفية خارجيًا: $($sync.Removed -join '، ')")
    }
    else {
        $lines.Add("✅ الحالة متزامنة مع Cinegy.")
    }
    if ($store.Errors.Count -gt 0) { $lines.Add("⚠️ " + (ConvertTo-TelegramHtmlText ($store.Errors -join "`n⚠️ "))) }
    $statusMenu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    # The same lines, reshaped: the verdict as a heading, what is on air
    # as a table, and the machine detail folded under it. The leading
    # lines are skipped because the blocks already carry them.
    # Skip 4: the blocks already carry the title, the clock, the verdict and
    # now the identity line, and repeating them inside the details would print
    # each of those facts twice on one screen.
    # The block renderer lays text out itself and has no tag syntax, so the
    # HTML is stripped back on the way in rather than kept as a second
    # parallel copy that would drift from the one operators actually read.
    $statusBlocks = Get-StatusRichBlocks -Title 'ℹ️ الحالة' -Overall $overall `
        -Identity (ConvertFrom-TelegramHtmlText $identityLine) `
        -DetailLines @($lines | Select-Object -Skip 4 | ForEach-Object { ConvertFrom-TelegramHtmlText ([string]$_) }) `
        -DetailSummary '🔍 تفاصيل الاتصال والتزامن'
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $statusBlocks -ReplyMarkup $statusMenu) { return }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup $statusMenu
}

function Request-HideAllConfirmation {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    $layers = @(Get-HideAllTargetLayers)
    if ($layers.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لا توجد طبقات محددة لإخفاء الكل. يضبطها المشرف من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'hide_all_review'; UserId = $UserId; Layers = $layers
    }
    $labels = @($layers | ForEach-Object { Get-LayerDisplayName -Layer ([int]$_) })
    Send-TelegramMessage -ChatId $ChatId -Text "⚠️ سيتم إخفاء الطبقات المحددة: $($labels -join '، '). هل أنت متأكد؟" -ReplyMarkup (Get-HideAllConfirmKeyboard)
}

function Get-HealthStatusReport {
    $telegramWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $telegramOk = $false
    $telegramError = ''
    try {
        $probe = Invoke-RestMethod -Uri "$apiBase/getMe" -Method Get -TimeoutSec 3
        $telegramOk = [bool](Get-JsonProp $probe 'ok')
        if (-not $telegramOk) { $telegramError = 'رد غير صالح' }
    }
    catch { $telegramError = $_.Exception.Message }
    $telegramWatch.Stop()

    $cinegyWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $telemetry = Get-AirTelemetryStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    $cinegyWatch.Stop()

    $checkedAt = Get-Date
    if ($telegramOk) { $script:HealthHistory.Telegram.LastSuccess = $checkedAt }
    else {
        $script:HealthHistory.Telegram.LastError = Protect-SensitiveText $telegramError
        $script:HealthHistory.Telegram.LastErrorAt = $checkedAt
    }
    if ($telemetry.Success) { $script:HealthHistory.Cinegy.LastSuccess = $checkedAt }
    else {
        $script:HealthHistory.Cinegy.LastError = [string](Get-JsonProp $telemetry 'Error')
        if ([string]::IsNullOrWhiteSpace($script:HealthHistory.Cinegy.LastError)) { $script:HealthHistory.Cinegy.LastError = 'تعذّر الوصول' }
        $script:HealthHistory.Cinegy.LastErrorAt = $checkedAt
    }

    $telegramLine = if ($telegramOk) { "✅ Telegram: $($telegramWatch.ElapsedMilliseconds)ms" }
    else { "❌ Telegram: $($telegramWatch.ElapsedMilliseconds)ms — $(Protect-SensitiveText $telegramError)" }
    $cinegyLine = if ($telemetry.Success) { "✅ Cinegy: $($cinegyWatch.ElapsedMilliseconds)ms" }
    else { "❌ Cinegy: $($cinegyWatch.ElapsedMilliseconds)ms — تعذّر الوصول" }
    $historyLines = foreach ($service in @('Telegram', 'Cinegy')) {
        $history = $script:HealthHistory[$service]
        $lastSuccess = if ($history.LastSuccess) { ([datetime]$history.LastSuccess).ToString('yyyy-MM-dd HH:mm:ss') } else { 'لا يوجد' }
        $lastError = if ($history.LastErrorAt) {
            "$($history.LastError) — $(([datetime]$history.LastErrorAt).ToString('yyyy-MM-dd HH:mm:ss'))"
        }
        else { 'لا يوجد' }
        $failureCount = [int]$history.FailureCount
        $outage = if ($history.OutageStartedAt) { ([datetime]$history.OutageStartedAt).ToString('yyyy-MM-dd HH:mm:ss') } else { 'لا يوجد' }
        "$service — آخر نجاح: $lastSuccess | آخر خطأ: $lastError | فشل متتالٍ: $failureCount | بداية الانقطاع: $outage"
    }
    $historyText = $historyLines -join "`n"
    $text = @(
        "💚 صحة الخدمات",
        $telegramLine,
        $cinegyLine,
        "",
        $historyText,
        "",
        (Format-CinegyTelemetryStatus -Telemetry $telemetry)
    ) -join "`n"
    return [pscustomobject]@{ Text = $text; Telemetry = $telemetry }
}

function Show-TemplateAdminDetail {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text 'القالب لم يعد موجودًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $lines = @(
        "📚 تفاصيل القالب: $($template.Key)",
        "المسار: $($template.Path)",
        "الطبقة: $($template.Layer)",
        "الترتيب: $($template.Order)",
        "الوصف: $($template.Description)",
        "الحقول: $(if (@($template.Fields).Count -gt 0) { $template.Fields -join '، ' } else { 'لا توجد' })",
        "النصوص الجاهزة: $(@($template.Presets).Count)"
    )
    $reminderText = if ([bool](Get-JsonProp $template 'LongRunning')) {
        'معطّل للقالب Long run (يعمل 24/7).'
    }
    elseif ([int](Get-JsonProp $template 'ReminderMinutes') -gt 0) {
        "بعد $([int](Get-JsonProp $template 'ReminderMinutes')) دقيقة للشخص الذي أظهر القالب."
    }
    else { 'معطّل.' }
    $lines += "🔔 تنبيه الظهور: $reminderText"
    if ((Test-Admin -ChatId $ChatId -UserId $UserId) -and (Get-Setting 'EnableFullTemplateManagement')) {
        $lines += '✅ التحكم الكامل بالقوالب مفعّل. اختر عملية التعديل من الأزرار.'
    }
    else {
        $lines += '🔒 تعديل تعريف القالب مخصص للمشرف. يمكنك قراءة التعريف وإدارة تنبيه الظهور.'
    }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex -ChatId $ChatId -UserId $UserId)
}

function Start-TemplateReminderMinutesPrompt {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-TemplateReminderManager -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'فقدت صلاحية إدارة تنبيه القالب.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { Send-TelegramMessage -ChatId $ChatId -Text 'القالب لم يعد موجودًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $ChatId -UserId $UserId); return }
    if ([bool](Get-JsonProp $template 'LongRunning')) {
        Send-TelegramMessage -ChatId $ChatId -Text "🔔 '$($template.Key)' قالب Long run يعمل 24/7، لذلك تنبيه الظهور الشخصي معطّل." -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex -ChatId $ChatId -UserId $UserId)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'template_reminder_minutes'; TemplateIndex = $TemplateIndex; TemplateKey = [string]$template.Key; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "🔔 أرسل مدة التنبيه لقالب '$($template.Key)' بالدقائق من 0 إلى 1440.`nأرسل 0 لإيقاف التنبيه." -ReplyMarkup (Get-CancelKeyboard)
}
