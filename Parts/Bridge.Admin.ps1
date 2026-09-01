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
    $lines.Add("ℹ️ الحالة — v$($script:BridgeVersion)")
    $lines.Add("🕒 $($now.ToString('yyyy-MM-dd HH:mm:ss')) (محلي)")
    $lines.Add($overall)
    # Format-UserAuditActor, not a bare id: it resolves the alias when there is
    # one and pins the bracketed digits to LTR, so an Arabic name followed by
    # an id does not render as ")8201739556(".
    $identityLine = "👤 معرّفك: $(Format-UserAuditActor -UserId $UserId)"
    $lines.Add($identityLine)
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add("🌐 $($config.AirServerAddress) · القناة $($config.AirChannelNumber) · القوالب: $($store.Order.Count)")
    $sharedLayers = Get-JsonProp $store 'SharedLayers'
    if ($sharedLayers -and $sharedLayers.Count -gt 0) {
        $sharedText = @($sharedLayers.Keys | Sort-Object {[int]$_} | ForEach-Object { "طبقة ${_}: $(@($sharedLayers[$_]) -join '، ')" }) -join ' | '
        # Not 'allowed' - a Cinegy GFX layer holds one scene, so templates
        # sharing a layer can never be on air together. Calling that harmless
        # is how a logo and a ticker end up silently evicting each other.
        $lines.Add("⚠️ قوالب تتشارك الطبقة نفسها ولا يمكن عرضها معًا: $sharedText")
    }
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: $($freshness.Label)")
    if ($lastSuccessfulAt) {
        # "منذ 12 ثانية" answers the question being asked - is this current? -
        # which a bare timestamp leaves the reader to work out against a clock.
        # The clock time stays, in brackets, for anyone comparing with a log.
        $checkedAt = [datetime]$lastSuccessfulAt
        $agoSeconds = [math]::Max(0, [int]($now - $checkedAt).TotalSeconds)
        # "منذ 0 ثانية" is a strange way to say "just now".
        $ago = if ($agoSeconds -lt 5) { 'الآن' } else { "منذ $(Format-DurationSeconds -Seconds $agoSeconds)" }
        $lines.Add("🔄 آخر فحص ناجح: $ago ($($checkedAt.ToString('HH:mm:ss')))")
    }
    $lines.Add((Get-OnAirSummary))
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
    if ($store.Errors.Count -gt 0) { $lines.Add("⚠️ " + ($store.Errors -join "`n⚠️ ")) }
    $statusMenu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    # The same lines, reshaped: the verdict as a heading, what is on air
    # as a table, and the machine detail folded under it. The leading
    # lines are skipped because the blocks already carry them.
    # Skip 4: the blocks already carry the title, the clock, the verdict and
    # now the identity line, and repeating them inside the details would print
    # each of those facts twice on one screen.
    $statusBlocks = Get-StatusRichBlocks -Title 'ℹ️ الحالة' -Overall $overall -Identity $identityLine `
        -DetailLines @($lines | Select-Object -Skip 4) -DetailSummary '🔍 تفاصيل الاتصال والتزامن'
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $statusBlocks -ReplyMarkup $statusMenu) { return }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup $statusMenu
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

function Complete-TemplateReminderMinutes {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'template_reminder_minutes' -or [long]$state.UserId -ne $UserId) { return }
    if (-not (Test-TemplateReminderManager -ChatId $ChatId -UserId $UserId)) {
        Clear-PendingState -ChatId $ChatId
        Send-TelegramMessage -ChatId $ChatId -Text 'فقدت صلاحية إدارة تنبيه القالب؛ لم يتم حفظ التغيير.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $minutes = -1
    if (-not [int]::TryParse($Value.Trim(), [ref]$minutes) -or $minutes -lt 0 -or $minutes -gt 1440) {
        Send-TelegramMessage -ChatId $ChatId -Text 'أرسل رقمًا صحيحًا من 0 إلى 1440 دقيقة.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $template = Get-TemplateByIndex -Index ([int]$state.TemplateIndex)
    if (-not $template -or [string]$template.Key -ne [string]$state.TemplateKey) { Clear-PendingState -ChatId $ChatId; Send-TelegramMessage -ChatId $ChatId -Text 'تغيّر القالب؛ افتح تفاصيله مجددًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $ChatId -UserId $UserId); return }
    if ([bool](Get-JsonProp $template 'LongRunning')) { Clear-PendingState -ChatId $ChatId; Send-TelegramMessage -ChatId $ChatId -Text 'القالب أصبح Long run؛ لا يمكن تفعيل تنبيه الظهور له.' -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $UserId); return }
    $result = Save-TemplateReminderMinutes -TemplateKey ([string]$state.TemplateKey) -Minutes $minutes
    Clear-PendingState -ChatId $ChatId
    if (-not $result.Success) { Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ تنبيه القالب: $($result.Error)" -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $UserId); return }
    Add-AuditEntry "🔔 ضبط تنبيه ظهور $($state.TemplateKey) على $minutes دقيقة - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    $message = if ($minutes -eq 0) { '✅ تم إيقاف تنبيه الظهور لهذا القالب.' } else { "✅ تم ضبط تنبيه الظهور بعد $minutes دقيقة." }
    Send-TelegramMessage -ChatId $ChatId -Text $message -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $UserId)
}

function Start-TemplateDefinitionPrompt {
    param([Parameter(Mandatory)][ValidateSet('create', 'edit', 'delete')][string]$Action, [int]$TemplateIndex = -1, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Get-Setting 'EnableFullTemplateManagement')) {
        Send-TelegramMessage -ChatId $ChatId -Text '🔒 التحكم الكامل بالقوالب معطّل من الإعدادات.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $template = if ($TemplateIndex -ge 0) { Get-TemplateByIndex -Index $TemplateIndex } else { $null }
    if ($Action -ne 'create' -and -not $template) { Send-TelegramMessage -ChatId $ChatId -Text 'القالب لم يعد موجودًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard); return }
    if ($Action -eq 'delete') {
        Set-PendingState -ChatId $ChatId -State @{ Mode='template_definition_review'; Action='delete'; TemplateKey=$template.Key; Definition=@{}; UserId=$UserId }
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ مراجعة حذف القالب '$($template.Key)'. لن يُحذف إذا كان على الهواء أو ضمن جدولة قادمة." -ReplyMarkup (Get-TemplateDefinitionReviewKeyboard)
        return
    }
    $example = if ($Action -eq 'create') { '{"key":"new-template","path":"titles/new.cintitle","layer":4,"fields":["Headline.Text"]}' } else { "{`"path`":`"$($template.Path)`",`"layer`":$($template.Layer),`"fields`":[]}" }
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_definition_json'; Action=$Action; TemplateKey=if ($template) { $template.Key } else { '' }; UserId=$UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل تعريف القالب بصيغة JSON في رسالة واحدة.`nمثال:`n$example" -ReplyMarkup (Get-CancelKeyboard)
}

function Start-TemplateCreateWizard {
    <# Guided create flow: asks for key, path, layer and fields one at a
       time instead of requiring a raw JSON document. Ends in the same
       template_definition_review state as the JSON path, so saving, backups
       and validation are shared. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Get-Setting 'EnableFullTemplateManagement')) {
        Send-TelegramMessage -ChatId $ChatId -Text '🔒 التحكم الكامل بالقوالب معطّل من الإعدادات.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_create_key'; Definition=@{}; UserId=$UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "➕ إضافة قالب (1/5)`nأرسل مفتاح القالب - وهو الاسم الذي سيظهر على الزر (أحرف وأرقام ونقاط/شرطات، مثل: Lower3rd):" -ReplyMarkup (Get-CancelKeyboard)
}

function Get-TemplateWizardLayerPrompt {
    "(3/5) أرسل رقم الطبقة (مثل 4 أو 7)،`nأو اسم جهاز Cinegy إن كانت الطبقة بلا رقم (مثل: logo)."
}

function Get-TemplateWizardFieldsPrompt {
    "(4/5) أرسل أسماء الحقول مفصولة بفواصل (مثل: Headline.Text, Subtitle.Text)`nأو أرسل: لا يوجد إذا كان القالب بلا حقول."
}

function Get-TemplateLayerUsage {
    <# Which existing templates already sit on this layer. Said at the moment
       the layer is chosen, not after saving, because two templates sharing a
       layer is a real configuration - a ticker and an alert - but far more
       often it is a typo the operator wants to know about now. #>
    param([Parameter(Mandatory)][int]$Layer)
    $store = Get-TemplateStore
    return @($store.Order | Where-Object { [int]$store.Map[$_].Layer -eq $Layer })
}

function Get-TemplateWizardReviewText {
    param([Parameter(Mandatory)][hashtable]$Definition)
    $read = { param([string]$Name, [string]$Fallback)
        if ($Definition.ContainsKey($Name) -and "$($Definition[$Name])".Trim()) { [string]$Definition[$Name] } else { $Fallback } }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("🔎 مراجعة القالب الجديد '$(& $read 'key' '?')'")
    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("المسار: $(& $read 'path' '?')")
    $resolved = Resolve-TemplateScenePath -Path ([string]$Definition['path'])
    if ($resolved -ne [string]$Definition['path']) { $lines.Add("يُقرأ من: $resolved") }
    $lines.Add($(if ($Definition.ContainsKey('device') -and [string]$Definition['device']) {
                "الجهاز: gfx_$($Definition['device'])"
            }
            else { "الطبقة: $(& $read 'layer' '?')" }))
    $fields = @($Definition['fields'])
    $lines.Add("الحقول: $(if ($fields.Count -gt 0) { $fields -join '، ' } else { 'لا توجد حقول' })")
    $lines.Add("الوصف: $(& $read 'description' 'بلا وصف')")
    $lines.Add("التصنيف: $(& $read 'category' 'غير مصنف')")
    $lines.Add('')
    $lines.Add('لن يُحفظ شيء قبل التأكيد، وستُنشأ نسخة احتياطية من التعريفات الحالية.')
    return ($lines -join "`n")
}

function Complete-TemplateCreateWizardStep {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.UserId -ne [string]$UserId) { return }
    $definition = $state.Definition
    switch ([string]$state.Mode) {
        'template_create_key' {
            $trimmed = $Value.Trim()
            if ($trimmed -notmatch '^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$') {
                Send-TelegramMessage -ChatId $ChatId -Text '❌ مفتاح غير صالح. استخدم أحرفًا وأرقامًا ونقاط/شرطات فقط (حتى 64 حرفًا):' -ReplyMarkup (Get-CancelKeyboard); return
            }
            $existing = Get-JsonProp (Get-Content -LiteralPath (Get-TemplateRegistryFilePath) -Raw | ConvertFrom-Json) $trimmed
            if ($existing) { Send-TelegramMessage -ChatId $ChatId -Text "❌ يوجد قالب بالمفتاح '$trimmed' بالفعل. أرسل مفتاحًا آخر:" -ReplyMarkup (Get-CancelKeyboard); return }
            $definition['key'] = $trimmed
            $state.Mode = 'template_create_path'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
            $baseHint = if ([string](Get-Setting 'TemplateBasePath')) { "`nأو اسم الملف وحده، فمجلد المشاهد مضبوط: $(Get-Setting 'TemplateBasePath')" } else { '' }
            Send-TelegramMessage -ChatId $ChatId -Text ("(2/5) أرسل مسار ملف المشهد كاملًا، مثل:`nC:\Cinegy\Titler\Scenes\Lower3rd.cintitle`nويُقبل أيضًا مسار الشبكة \\nas01\scenes\... و%PROGRAMDATA%\...$baseHint") -ReplyMarkup (Get-CancelKeyboard)
        }
        'template_create_path' {
            $trimmed = $Value.Trim()
            if ($trimmed -match '^(تم|ok)$') {
                if ($definition.ContainsKey('pendingPath')) {
                    $definition['path'] = [string]$definition['pendingPath']; $definition.Remove('pendingPath')
                    $state.Mode = 'template_create_layer'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
                    Send-TelegramMessage -ChatId $ChatId -Text (Get-TemplateWizardLayerPrompt) -ReplyMarkup (Get-CancelKeyboard); return
                }
                Send-TelegramMessage -ChatId $ChatId -Text '❌ لا يوجد مسار معلّق للمتابعة. أرسل مسار ملف القالب أولًا:' -ReplyMarkup (Get-CancelKeyboard); return
            }
            <#
                Any path Cinegy can open is accepted, because the scenes live
                where the station keeps them - C:\Cinegy\Titler\Scenes, a
                mapped drive, or \\nas01\scenes - and never inside this
                project folder.

                The wizard used to demand a relative path under the bridge's
                own directory, so it could not register a single real scene:
                the only way in was the raw JSON screen, which has always
                accepted absolute paths. The restriction bought no safety,
                only a dead end.
            #>
            if ([IO.Path]::GetExtension($trimmed) -ne '.cintitle') {
                Send-TelegramMessage -ChatId $ChatId -Text "❌ يجب أن ينتهي المسار بـ .cintitle، مثل:`nC:\Cinegy\Titler\Scenes\Lower3rd.cintitle" -ReplyMarkup (Get-CancelKeyboard); return
            }
            $resolved = Resolve-TemplateScenePath -Path $trimmed
            if (-not [IO.Path]::IsPathRooted($resolved)) {
                Send-TelegramMessage -ChatId $ChatId -Text "❌ أرسل مسارًا كاملًا، أو اضبط TemplateBasePath من الإعدادات لتكتفي باسم الملف.`nمثال: C:\Cinegy\Titler\Scenes\Lower3rd.cintitle" -ReplyMarkup (Get-CancelKeyboard); return
            }
            if (-not (Test-Path -LiteralPath $resolved)) {
                # Warned, not refused: the scene is often built after the
                # template is registered, and on a network share the bridge
                # may simply not see it from where it runs.
                $definition['pendingPath'] = $trimmed
                $state.Mode = 'template_create_path'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
                Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لا أرى الملف على هذا المسار:`n$resolved`n`nللمتابعة به رغم ذلك أرسل: تم`nأو أرسل مسارًا آخر." -ReplyMarkup (Get-CancelKeyboard); return
            }
            $definition.Remove('pendingPath')
            $definition['path'] = $trimmed
            $state.Mode = 'template_create_layer'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
            Send-TelegramMessage -ChatId $ChatId -Text "✅ الملف موجود.`n$(Get-TemplateWizardLayerPrompt)" -ReplyMarkup (Get-CancelKeyboard)
        }
        'template_create_layer' {
            # A layer number, or a Cinegy device name for the layers that do
            # not have one - the logo sits on gfx_logo, and before this the
            # wizard had no way to say so.
            $trimmed = $Value.Trim()
            $layer = 0
            if ([int]::TryParse($trimmed, [ref]$layer) -and $layer -gt 0) {
                $definition['layer'] = $layer
                $used = @(Get-TemplateLayerUsage -Layer $layer)
                $warning = if ($used.Count -gt 0) { "`n⚠️ الطبقة $layer يستخدمها أيضًا: $($used -join '، ')" } else { '' }
                $state.Mode = 'template_create_fields'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
                Send-TelegramMessage -ChatId $ChatId -Text ((Get-TemplateWizardFieldsPrompt) + $warning) -ReplyMarkup (Get-CancelKeyboard)
                return
            }
            if ($trimmed -match '^[A-Za-z0-9_]{1,32}$') {
                $definition['device'] = $trimmed.ToLowerInvariant()
                $definition['layer'] = 0
                $state.Mode = 'template_create_fields'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
                Send-TelegramMessage -ChatId $ChatId -Text "✅ سيُستخدم الجهاز gfx_$($definition['device']).`n$(Get-TemplateWizardFieldsPrompt)" -ReplyMarkup (Get-CancelKeyboard)
                return
            }
            Send-TelegramMessage -ChatId $ChatId -Text '❌ أرسل رقم طبقة موجبًا (مثل 4) أو اسم جهاز بأحرف إنجليزية (مثل logo):' -ReplyMarkup (Get-CancelKeyboard)
        }
        'template_create_fields' {
            $trimmed = $Value.Trim()
            $fields = @()
            if ($trimmed -notmatch '^(لا\s*يوجد|none)$' -and $trimmed.Length -gt 0) {
                foreach ($part in ($trimmed -split '[,;\n]+')) {
                    $name = $part.Trim()
                    if ($name) { $fields += $name }
                }
                if (@($fields | Where-Object { -not $_ }).Count -gt 0) { $fields = @($fields | Where-Object { $_ }) }
            }
            $definition['fields'] = @($fields)
            $state.Mode = 'template_create_details'; $state.Definition = $definition
            Set-PendingState -ChatId $ChatId -State $state
            Send-TelegramMessage -ChatId $ChatId -Text ("(5/5) الوصف والتصنيف - يظهران في شاشة ℹ️ وفي بحث القوالب." +
                "`nأرسلهما في سطر واحد مفصولين بـ | مثل:`nشريط الأخبار | أخبار`n`nأو أرسل: تخطي") -ReplyMarkup (Get-CancelKeyboard)
        }
        'template_create_details' {
            # Optional, and skippable in one word: an operator adding a
            # template under time pressure should not be blocked by metadata,
            # but the two fields that make the ℹ️ screen and the search useful
            # are worth one prompt.
            $trimmed = $Value.Trim()
            if ($trimmed -notmatch '^(تخطي|تخطى|skip)$' -and $trimmed.Length -gt 0) {
                $parts = @($trimmed -split '\|', 2 | ForEach-Object { $_.Trim() })
                if ($parts[0]) { $definition['description'] = $parts[0] }
                if ($parts.Count -gt 1 -and $parts[1]) { $definition['category'] = $parts[1] }
            }
            $state.Mode = 'template_definition_review'; $state.Action = 'create'
            $state.TemplateKey = [string]$definition['key']; $state.Definition = $definition
            Set-PendingState -ChatId $ChatId -State $state
            Send-TelegramMessage -ChatId $ChatId -Text (Get-TemplateWizardReviewText -Definition $definition) -ReplyMarkup (Get-TemplateDefinitionReviewKeyboard)
        }
    }
}

function Get-TemplateDefinitionComparisonText {
    param($Existing, [Parameter(Mandatory)][hashtable]$Definition)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($name in @('path', 'layer', 'order', 'description', 'category', 'fields')) {
        if (-not $Definition.ContainsKey($name)) { continue }
        [string]$oldJson = if ($Existing) { Get-JsonProp $Existing $name | ConvertTo-Json -Depth 10 -Compress } else { '<غير موجود>' }
        [string]$newJson = $Definition[$name] | ConvertTo-Json -Depth 10 -Compress
        if ([string]::IsNullOrEmpty($oldJson)) { $oldJson = 'null' }
        if ([string]::IsNullOrEmpty($newJson)) { $newJson = 'null' }
        if ($oldJson -ne $newJson) {
            $oldDisplay = if ($oldJson.Length -gt 120) { $oldJson.Substring(0,117) + '...' } else { $oldJson }
            $newDisplay = if ($newJson.Length -gt 120) { $newJson.Substring(0,117) + '...' } else { $newJson }
            $lines.Add("• $name`n  قبل: $oldDisplay`n  بعد: $newDisplay")
        }
    }
    if ($lines.Count -eq 0) { return 'الاختلافات: لا توجد تغييرات فعلية.' }
    return "الاختلافات:`n$($lines -join "`n")"
}

function Complete-TemplateDefinitionJson {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'template_definition_json') { return }
    try { $definition = $Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { Send-TelegramMessage -ChatId $ChatId -Text '❌ JSON غير صالح. أرسل تعريفًا صحيحًا أو ألغِ العملية.' -ReplyMarkup (Get-CancelKeyboard); return }
    $key = [string]$state.TemplateKey
    if ($state.Action -eq 'create') { $key = [string](Get-JsonProp $definition 'key'); $definition.Remove('key') }
    if ([string]::IsNullOrWhiteSpace($key)) { Send-TelegramMessage -ChatId $ChatId -Text '❌ يتطلب القالب الجديد مفتاح key.' -ReplyMarkup (Get-CancelKeyboard); return }
    $state.Mode = 'template_definition_review'; $state.TemplateKey = $key; $state.Definition = $definition
    Set-PendingState -ChatId $ChatId -State $state
    $existing = if ($state.Action -eq 'edit') { Get-JsonProp (Get-Content -LiteralPath (Get-TemplateRegistryFilePath) -Raw | ConvertFrom-Json) $key } else { $null }
    $comparison = Get-TemplateDefinitionComparisonText -Existing $existing -Definition $definition
    Send-TelegramMessage -ChatId $ChatId -Text "🔎 مراجعة $($state.Action) للقالب '$key'`nالمسار: $($definition.path)`nالطبقة: $($definition.layer)`n`n$comparison`n`nلن يُحفظ شيء قبل التأكيد، وستُنشأ نسخة احتياطية من التعريفات الحالية." -ReplyMarkup (Get-TemplateDefinitionReviewKeyboard)
}

function Confirm-TemplateDefinitionChange {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'template_definition_review' -or [long]$state.UserId -ne $UserId) { return }
    Clear-PendingState -ChatId $ChatId
    $result = Save-TemplateDefinitionChange -TemplateKey ([string]$state.TemplateKey) -Action ([string]$state.Action) -Definition ([hashtable]$state.Definition)
    if ($result.Success) { Add-AuditEntry "📚 $($state.Action) قالب $($state.TemplateKey) - بواسطة $(Format-UserAuditActor -UserId $UserId)"; Send-TelegramMessage -ChatId $ChatId -Text '✅ تم حفظ تعريف القالب مع نسخة احتياطية.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
    else { Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ القالب: $($result.Error)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
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
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("📊 الحالة الكاملة — v$($script:BridgeVersion)")
    $lines.Add("🕒 $($now.ToString('yyyy-MM-dd HH:mm:ss')) (محلي)")
    $lines.Add($overall)
    $identityLine = "👤 معرّفك: $(Format-UserAuditActor -UserId $UserId)"
    $lines.Add($identityLine)
    $lines.Add('')
    $lines.Add((Get-OnAirSummary))
    $lines.Add('')
    $lines.Add('🎛 اتصال Cinegy')
    $lines.Add("🌐 $($config.AirServerAddress) · القناة $($config.AirChannelNumber) · القوالب: $($store.Order.Count)")
    $configuredSceneMode = [string](Get-Setting 'SceneMode')
    $sceneCapabilities = Get-CinegySceneCapabilities -SceneItems $layerStatuses -LayerTargetSupported $true
    $sceneMode = Test-BridgeSceneMode -RequestedMode $configuredSceneMode -Capabilities $sceneCapabilities
    $verification = if ($sceneMode.Verified) { 'تم التحقق' } elseif ($configuredSceneMode -eq 'Multi') { 'بانتظار تحقق Cinegy' } else { 'وضع متوافق' }
    $lines.Add("🧩 وضع المشاهد المختار: $configuredSceneMode · $verification")
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: $($freshness.Label)")
    $lines.Add((Format-CinegyLayerDashboard -LayerStatuses $layerStatuses))
    $lines.Add('')
    $lines.Add('🩺 صحة الخدمات')
    $lines.Add($health.Text)
    $lines.Add('')
    $lines.Add($outputMonitor.Text)
    $lines.Add('')
    $lines.Add('⚙️ التشغيل والجدولة')
    $lines.Add("📡 البث المباشر: $(Get-LiveRelayStatusText)")
    $lines.Add("🖼 الصور المعلّقة: $($script:SnapshotJobs.Count) · مؤقتات الإخفاء: $($script:AutoHideQueue.Count) · تنبيهات الظهور: $($script:TemplateReminderQueue.Count)")
    $lines.Add("🗓 الأحداث المجدولة القادمة: $(@(Get-UpcomingScheduleEvents).Count)")
    $lines.Add('')
    $lines.Add('👥 الوصول')
    $lines.Add("🔐 المستخدمون المصرح لهم: $(@(Get-JsonProp $config 'AllowedChatIds').Count) محادثة / $(@(Get-JsonProp $config 'AllowedUserIds').Count) مستخدم")
    $lines.Add("🔔 طلبات الوصول المعلّقة: $($script:PendingApprovals.Count)")
    $lines.Add('')
    if ($sync.Failed.Count -gt 0) {
        $lines.Add("⚠️ تعذّر فحص طبقات Cinegy: $($sync.Failed -join '، ') — تم الاحتفاظ بالحالة السابقة.")
    }
    elseif ($sync.Removed.Count -gt 0) {
        $lines.Add("🔄 أُزيلت الطبقات المخفية خارجيًا: $($sync.Removed -join '، ')")
    }
    else { $lines.Add("✅ حالة Cinegy متزامنة.") }
    if ($store.Errors.Count -gt 0) { $lines.Add("⚠️ " + ($store.Errors -join "`n⚠️ ")) }
    $statusMenu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    # The same lines, reshaped: the verdict as a heading, what is on air
    # as a table, and the machine detail folded under it. The leading
    # lines are skipped because the blocks already carry them.
    # Skip 6 rather than 5: the identity line joined the header block, so the
    # count of lines the blocks already carry moved with it.
    $statusBlocks = Get-StatusRichBlocks -Title '📊 الحالة الكاملة' -Overall $overall -Identity $identityLine `
        -DetailLines @($lines | Select-Object -Skip 6) -DetailSummary '🔍 التفاصيل الكاملة'
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $statusBlocks -ReplyMarkup $statusMenu) { return }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup $statusMenu
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

function Get-RuntimeFileHealthText {
    param([AllowNull()][object[]]$Records = $null)
    if ($null -eq $Records) { $Records = @(Get-RuntimeFileHealth -Files (Get-BridgeRuntimeFiles)) }
    $Records = @($Records)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('🗂 صحة ملفات التشغيل')
    $lines.Add('━━━━━━━━━━━━━━')

    $faults = @($Records | Where-Object { $_.State -in @('broken', 'recoverable') })
    if ($faults.Count -eq 0) {
        $lines.Add('🟢 كل ملفات التشغيل سليمة.')
    }
    else {
        $lines.Add("🔴 ملفات تحتاج انتباهك: $($faults.Count)")
    }
    $lines.Add('')

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
        $lines.Add("$icon $($record.Name)")
        $lines.Add("      $detail")
    }

    if ($faults.Count -gt 0) {
        $lines.Add('')
        $lines.Add('↳ الملف التالف بنسخة احتياطية يُستعاد تلقائيًا عند إعادة التشغيل.')
        $lines.Add('↳ التالف بلا نسخة يبدأ فارغًا؛ خذ نسخة من المجلد قبل إعادة التشغيل إن كان محتواه مهمًا.')
    }
    return ($lines -join "`n")
}

function Invoke-RuntimeFileHealthCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-RuntimeFileHealthText) -ReplyMarkup (Get-HealthCenterKeyboard)
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
        One row per subsystem: the name, a state glyph, and the detail.

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
        'connected' { @{ Name = 'Telegram'; Icon = '🟢'; Detail = 'متصل' } }
        'disconnected' { @{ Name = 'Telegram'; Icon = '🔴'; Detail = 'غير متصل' } }
        default { @{ Name = 'Telegram'; Icon = '🟠'; Detail = 'لم تُحسم الحالة' } }
    }

    $cinegyState = [string]$script:RuntimeState.Monitoring.CinegyHealthState
    $rows += switch ($cinegyState) {
        'healthy' { @{ Name = 'Cinegy'; Icon = '🟢'; Detail = 'سليم' } }
        'unhealthy' { @{ Name = 'Cinegy'; Icon = '🔴'; Detail = 'غير سليم' } }
        default { @{ Name = 'Cinegy'; Icon = '🟠'; Detail = 'الحالة غير معروفة' } }
    }

    $monitorDisabled = (Get-SettingInt 'OutputMonitorMinutes') -le 0
    $monitorFault = [bool]$script:OutputMonitorFailureAlerted -or [bool]$script:OutputBlackAlerted
    $rows += if ($monitorDisabled) { @{ Name = 'مراقبة المخرج'; Icon = '🟢'; Detail = 'معطلة باختيار المشرف' } }
    elseif ($monitorFault) { @{ Name = 'مراقبة المخرج'; Icon = '🔴'; Detail = "إنذار نشط (فشل متتالٍ: $script:OutputMonitorFailureCount)" } }
    else { @{ Name = 'مراقبة المخرج'; Icon = '🟢'; Detail = 'سليمة' } }

    $relay = $script:RuntimeState.Relay
    $rows += if (-not [bool]$relay.ShouldRun) { @{ Name = 'البث المرحّل'; Icon = '🟢'; Detail = 'غير مطلوب' } }
    elseif ($relay.Process -and -not $relay.Process.HasExited) { @{ Name = 'البث المرحّل'; Icon = '🟢'; Detail = 'يعمل' } }
    else { @{ Name = 'البث المرحّل'; Icon = '🔴'; Detail = 'مطلوب لكنه متوقف' } }

    $diskText = if ($null -ne $DiagnosticsSnapshot.DiskFreeGB) { "$($DiagnosticsSnapshot.DiskFreeGB) GB متاح" } else { 'المساحة غير معروفة' }
    $rows += if (@($Warnings).Count -gt 0) { @{ Name = 'التخزين'; Icon = '🟠'; Detail = "$diskText — $(@($Warnings).Count) تحذير" } }
    else { @{ Name = 'التخزين'; Icon = '🟢'; Detail = $diskText } }

    $upcomingCount = @((Get-UpcomingScheduleEvents)).Count
    $rows += if (Get-Setting 'SchedulePaused') { @{ Name = 'الجدولة'; Icon = '🟠'; Detail = "متوقفة مؤقتًا — $upcomingCount حدث قادم" } }
    else { @{ Name = 'الجدولة'; Icon = '🟢'; Detail = "$upcomingCount حدث قادم" } }

    $recentErrors = @()
    foreach ($service in @('Telegram', 'Cinegy')) {
        $history = $script:HealthHistory[$service]
        if ($history.LastErrorAt -and $history.LastError) {
            $recentErrors += "${service}: $(Protect-SensitiveText ([string]$history.LastError))"
        }
    }
    $rows += if ($recentErrors.Count -gt 0) { @{ Name = 'آخر الأخطاء'; Icon = '🟠'; Detail = ($recentErrors -join ' | ') } }
    else { @{ Name = 'آخر الأخطاء'; Icon = '🟢'; Detail = 'لا شيء' } }

    return $rows
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
    $blocks += @{ type = 'paragraph'; text = "📈 الاستخدام: $($usage.OperationsToday) عملية اليوم · $($usage.ActiveOperators) مشغّل · $($usage.OnAirCount) على الهواء" }
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
    return @(
        '🩺 مركز صحة النظام'
        "Bridge v$script:BridgeVersion"
        ''
    ) + @($rows | ForEach-Object { "$($_.Icon) $($_.Name): $($_.Detail)" }) + @(
        "📈 الاستخدام: $($usage.OperationsToday) عملية اليوم · $($usage.ActiveOperators) مشغّل · $($usage.OnAirCount) على الهواء"
    ) -join "`n"
}

function Invoke-HealthCenterCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $healthKeyboard = Get-HealthCenterKeyboard
    # Table first so the state column can be read down; the lines remain
    # the fallback, and they are built from the same rows.
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-BridgeHealthCenterBlocks) -ReplyMarkup $healthKeyboard) { return }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-BridgeHealthCenterText) -ReplyMarkup $healthKeyboard
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
    Send-TelegramMessage -ChatId $ChatId -Text "🧪 مراجعة اختبار القالب '$($template.Key)'`nطبقة التجربة المستقلة: $testLayer`nقيم الحقول: TEST`nالإخفاء التلقائي: $seconds ثانية`n`nسيُفحص أن الطبقة فارغة مباشرة قبل الاختبار." -ReplyMarkup (Get-TemplateTestReviewKeyboard)
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
    catch { return @() }
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

function Invoke-SettingsExport {
    <#
        Exports the Settings block only - never the whole config.

        config.json also holds the bot token and the operator whitelist, so
        sending it as a document would publish both into a chat that is far
        easier to forward than the file on disk. Only keys the bridge itself
        declares in $script:DefaultSettings are written out, so a key added by
        hand cannot smuggle anything into the export either.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $false }
    $payload = [ordered]@{}
    foreach ($name in $script:DefaultSettings.Keys) { $payload[$name] = Get-Setting $name }
    $document = [ordered]@{
        Kind          = 'CinegyTelegramBridge.Settings'
        BridgeVersion = $script:BridgeVersion
        ExportedAt    = (Get-Date).ToString('o')
        Settings      = $payload
    }
    $path = Join-Path $script:logDir "settings-export-$((Get-Date).ToString('yyyyMMdd-HHmmss')).json"
    try {
        # The log directory normally exists, but the export must not depend on
        # some earlier code path having created it first.
        if (-not (Test-Path -LiteralPath $script:logDir)) {
            New-Item -ItemType Directory -Path $script:logDir -Force -ErrorAction Stop | Out-Null
        }
        Set-Content -LiteralPath $path -Value ($document | ConvertTo-Json -Depth 8) -Encoding utf8 -ErrorAction Stop
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر تجهيز ملف الإعدادات: $($_.Exception.Message)" -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    $sent = Send-TelegramDocument -ChatId $ChatId -FilePath $path -Caption "📤 نسخة الإعدادات ($($payload.Count) خيارًا). لا تحتوي التوكن ولا قائمة المستخدمين."
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($sent) { Add-AuditEntry "📤 تصدير الإعدادات - بواسطة $(Format-UserAuditActor -UserId $UserId)" }
    return [bool]$sent
}

function ConvertTo-ImportedSettingValue {
    <# Validate the exact JSON type before a settings import reaches the live
       configuration. In particular, [bool]'false' is $true in PowerShell. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Value)
    $default = $script:DefaultSettings[$Name]
    if ($default -is [bool]) {
        if ($Value -isnot [bool]) { throw "الخيار $Name يجب أن يكون true أو false." }
        return [bool]$Value
    }
    if ($default -is [int]) {
        if ($Value -isnot [int] -and $Value -isnot [long]) { throw "الخيار $Name يجب أن يكون رقمًا صحيحًا." }
        if ([long]$Value -lt 0 -or [long]$Value -gt [int]::MaxValue) { throw "قيمة الخيار $Name خارج الحدود المسموحة." }
        return [int]$Value
    }
    if ($default -is [double]) {
        if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and $Value -isnot [decimal]) { throw "الخيار $Name يجب أن يكون رقمًا." }
        if ([double]$Value -lt 0) { throw "قيمة الخيار $Name خارج الحدود المسموحة." }
        return [double]$Value
    }
    if ($Value -isnot [string]) { throw "الخيار $Name يجب أن يكون نصًا." }
    if ($script:SettingChoices.ContainsKey($Name) -and $script:SettingChoices[$Name] -notcontains $Value) { throw "قيمة الخيار $Name غير مسموحة." }
    return [string]$Value
}

function Set-ImportedSettings {
    param([Parameter(Mandatory)][object[]]$Changes)
    $original = $config.Settings | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $updated = $config.Settings | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    foreach ($change in $Changes) {
        $updated | Add-Member -NotePropertyName ([string]$change.Name) -NotePropertyValue $change.To -Force
    }
    $config | Add-Member -NotePropertyName 'Settings' -NotePropertyValue $updated -Force
    # Save-Config communicates persistence failure through this flag rather
    # than a return value. Clear a stale failure from an earlier operation
    # before attempting this transaction.
    $script:LastConfigSaveFailed = $false
    Save-Config
    if ($script:LastConfigSaveFailed) {
        $config | Add-Member -NotePropertyName 'Settings' -NotePropertyValue $original -Force
        return $false
    }
    return $true
}

function Test-SettingsImport {
    <# Validates an exported settings document before anything is applied, and
       reports what would change. An unknown key is refused rather than
       ignored: silently dropping half an import is how a machine ends up in a
       state nobody can reproduce. #>
    param([Parameter(Mandatory)][string]$Path)
    try { $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { return [pscustomobject]@{ Success = $false; Error = 'الملف ليس JSON صالحًا.'; Changes = @() } }
    if ([string](Get-JsonProp $document 'Kind') -ne 'CinegyTelegramBridge.Settings') {
        return [pscustomobject]@{ Success = $false; Error = 'الملف ليس نسخة إعدادات صادرة عن هذا الجسر.'; Changes = @() }
    }
    $incoming = Get-JsonProp $document 'Settings'
    if (-not $incoming) { return [pscustomobject]@{ Success = $false; Error = 'لا يحتوي الملف على قسم Settings.'; Changes = @() } }

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($property in $incoming.PSObject.Properties) {
        if (-not $script:DefaultSettings.Contains($property.Name)) {
            return [pscustomobject]@{ Success = $false; Error = "خيار غير معروف في الملف: $($property.Name)"; Changes = @() }
        }
        try { $value = ConvertTo-ImportedSettingValue -Name $property.Name -Value $property.Value }
        catch { return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; Changes = @() } }
        $current = Get-Setting $property.Name
        if ([string]$current -eq [string]$value) { continue }
        $changes.Add([pscustomobject]@{ Name = $property.Name; From = $current; To = $value })
    }
    return [pscustomobject]@{ Success = $true; Error = ''; Changes = @($changes) }
}

function Receive-SettingsImport {
    param($Document, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return }
    Clear-PendingState -ChatId $ChatId
    $staged = Join-Path $script:logDir "template-imports/settings-$([guid]::NewGuid().ToString('N')).json"
    try {
        Receive-TelegramDocument -FileId ([string](Get-JsonProp $Document 'file_id')) -DestinationPath $staged -MaximumBytes $script:SettingsImportMaximumBytes | Out-Null
        $validation = Test-SettingsImport -Path $staged
        if (-not $validation.Success) { throw $validation.Error }
        if (@($validation.Changes).Count -eq 0) {
            Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
            Send-TelegramMessage -ChatId $ChatId -Text '✅ الملف مطابق للإعدادات الحالية؛ لا يوجد ما يتغيّر.' -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
            return
        }
        $script:PendingSettingsImport = @{ Path = $staged; UserId = $UserId; Changes = @($validation.Changes) }
        $preview = @($validation.Changes | Select-Object -First 20 | ForEach-Object { "• $($_.Name): $($_.From) ← $($_.To)" })
        $more = if (@($validation.Changes).Count -gt 20) { "`n… و$(@($validation.Changes).Count - 20) خيارًا آخر." } else { '' }
        Send-TelegramMessage -ChatId $ChatId -Text ("⚠️ مراجعة استيراد الإعدادات — $(@($validation.Changes).Count) تغييرًا:`n" + ($preview -join "`n") + $more) `
            -ReplyMarkup @{ inline_keyboard = @(, @(
                    @{ text = '✅ تطبيق'; callback_data = 'cfgimport:apply'; style = 'success' },
                    @{ text = '❌ إلغاء'; callback_data = 'cfgimport:cancel' })) }
    }
    catch {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل استيراد الإعدادات: $($_.Exception.Message)" -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
    }
}

function Confirm-SettingsImport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [switch]$Cancel)
    $pending = $script:PendingSettingsImport
    if (-not $pending -or [long]$pending.UserId -ne $UserId) {
        Send-TelegramMessage -ChatId $ChatId -Text 'انتهت مراجعة الاستيراد أو تغيّرت. ابدأ من جديد.' -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    if ($Cancel) {
        $script:PendingSettingsImport = $null
        Remove-Item -LiteralPath ([string]$pending.Path) -Force -ErrorAction SilentlyContinue
        Send-TelegramMessage -ChatId $ChatId -Text '❌ أُلغي الاستيراد؛ لم يتغيّر شيء.' -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    if (-not (Set-ImportedSettings -Changes @($pending.Changes))) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر حفظ استيراد الإعدادات؛ لم يُطبّق أي تغيير.' -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    $script:PendingSettingsImport = $null
    Remove-Item -LiteralPath ([string]$pending.Path) -Force -ErrorAction SilentlyContinue
    Write-BridgeLog "Admin $UserId imported $(@($pending.Changes).Count) setting(s)" 'WARN'
    Add-AuditEntry "📥 استيراد الإعدادات ($(@($pending.Changes).Count) تغييرًا) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ طُبِّق $(@($pending.Changes).Count) تغييرًا.$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
    return $true
}

function Invoke-BridgeSelfTest {
    <#
        Exercises the whole air path on the isolated test layer and reports
        what Cinegy said at every step: SHOW, read back, EXIT, read back.

        This is the check that was missing. Every individual piece had tests,
        but nothing ever asserted end to end that a scene the bridge put up
        actually came down again - which is how EXIT leaving a permanent
        on-air record reached production and stayed there.

        Refuses to run unless a dedicated test layer is configured and free,
        and always attempts a HIDE afterwards so a failed run cannot leave a
        graphic behind.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return $false }

    $layer = Get-SettingInt 'TemplateTestLayer' 0
    if ($layer -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text '⛔ لا توجد طبقة تجربة. اضبط TemplateTestLayer على طبقة غير مستخدمة أولًا.' -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    $conflict = @(Get-TemplateTestLayerConflict -Layer $layer)
    if ($conflict.Count -gt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ طبقة التجربة $layer مستخدمة في قوالب الإنتاج: $($conflict -join '، ')" -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    $store = Get-TemplateStore
    $template = if ($store.Order.Count -gt 0) { $store.Map[$store.Order[0]] } else { $null }
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text '⛔ لا توجد قوالب مسجّلة لإجراء الفحص.' -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }

    $timeout = Get-AirTimeout
    $monitorTimeout = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1
    $steps = [System.Collections.Generic.List[string]]::new()
    $failed = $false
    $record = {
        param([string]$Name, [bool]$Ok, [string]$Detail)
        $steps.Add("$(if ($Ok) { '✅' } else { '❌' }) $Name$(if ($Detail) { " — $Detail" })")
        if (-not $Ok) { $script:BridgeSelfTestFailed = $true }
    }
    $script:BridgeSelfTestFailed = $false

    $before = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $monitorTimeout
    & $record "قراءة حالة الطبقة $layer" ([bool]$before.Success) $(if ($before.Success) { '' } else { [string]$before.Error })
    if (-not $before.Success -or [bool]$before.IsOnAir) {
        & $record 'الطبقة جاهزة للفحص' $false 'مشغولة أو غير مقروءة؛ لم يُرسل شيء'
        Send-TelegramMessage -ChatId $ChatId -Text ("🧪 فحص المسار الحي — فشل`n" + ($steps -join "`n")) -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }

    $variables = @{}
    foreach ($field in @($template.Fields)) { $variables[[string]$field] = 'SELF-TEST' }
    try {
        $show = Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $layer -TemplatePath ([string]$template.Path) -Variables $variables -Types @{} `
            -DefaultType ([string](Get-Setting 'AirVariableType')) -TimeoutSec $timeout
        & $record 'إرسال SHOW' ([bool]$show.Success) $(if ($show.Success) { '' } else { [string]$show.Error })

        if ($show.Success) {
            $afterShow = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $monitorTimeout
            & $record 'Cinegy يؤكد ظهور المشهد' ([bool]$afterShow.Success -and [bool]$afterShow.IsOnAir) ''

            $exit = Exit-TitlerScene -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $timeout
            & $record 'إرسال EXIT' ([bool]$exit.Success) $(if ($exit.Success) { '' } else { [string]$exit.Error })
        }
    }
    finally {
        # HIDE regardless: EXIT alone can leave the item Active, and a failed
        # run must never leave the test layer occupied.
        $hide = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $timeout
        & $record 'تنظيف الطبقة (HIDE)' ([bool]$hide.Success) $(if ($hide.Success) { '' } else { [string]$hide.Error })
        Remove-OnAirRecord -Layer $layer -Reason 'self-test cleanup' | Out-Null
        $final = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $monitorTimeout
        & $record 'الطبقة فارغة بعد الفحص' ([bool]$final.Success -and -not [bool]$final.IsOnAir) ''
    }

    $failed = [bool]$script:BridgeSelfTestFailed
    $header = if ($failed) { '🧪 فحص المسار الحي — فشل' } else { '🧪 فحص المسار الحي — نجح' }
    Write-BridgeLog "Live self-test on layer $layer by user ${UserId}: $(if ($failed) { 'FAILED' } else { 'passed' })" $(if ($failed) { 'WARN' } else { 'INFO' })
    Add-AuditEntry "🧪 فحص المسار الحي على طبقة $layer - $(if ($failed) { 'فشل' } else { 'نجح' }) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text ("$header`n" + ($steps -join "`n")) -ReplyMarkup (Get-AdminToolsKeyboard -ChatId $ChatId -UserId $UserId)
    return (-not $failed)
}

function Confirm-TemplateTest {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_test_review' -or [long]$state.UserId -ne $UserId) { return }
    Clear-PendingState -ChatId $ChatId
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    $template = Get-TemplateByIndex -Index ([int]$state.TemplateIndex)
    $testLayer = Get-SettingInt 'TemplateTestLayer' 0
    if (-not $template -or $testLayer -le 0 -or $testLayer -ne [int]$state.TestLayer -or
        (@(Get-KnownLayers | ForEach-Object { [int]$_ }) -contains $testLayer)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تغيّر تعريف القالب أو طبقة التجربة. ابدأ المراجعة من جديد.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $testLayer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not $status.Success -or $null -eq $status.IsOnAir) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ تعذر التأكد من فراغ طبقة التجربة $testLayer؛ لم يُرسل شيء." -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    if ([bool]$status.IsOnAir) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ طبقة التجربة $testLayer مشغولة حاليًا؛ أخفها أو اختر طبقة أخرى." -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $variables = @{}
    foreach ($field in @($template.Fields)) { $variables[[string]$field] = 'TEST' }
    $types = @{}
    foreach ($field in @($template.FieldTypes.Keys)) { if ($template.FieldTypes[$field]) { $types[$field] = [string]$template.FieldTypes[$field] } }
    $result = Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $testLayer -TemplatePath ([string]$template.Path) -Variables $variables -Types $types `
        -DefaultType ([string](Get-Setting 'AirVariableType')) -TimeoutSec (Get-AirTimeout)
    if (-not $result.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل اختبار القالب: $($result.Error)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $script:OnAir[$testLayer] = @{ Key="[TEST] $($template.Key)"; At=(Get-Date); UserId=$UserId; ActiveId=[string]$result.EventId; Source='BotTest' }
    Save-OnAirState
    $seconds = [math]::Max(3, [math]::Min(300, [int]$state.AutoHideSeconds))
    $script:AutoHideQueue.Add(@{ Layer=$testLayer; At=(Get-Date).AddSeconds($seconds); ChatId=$ChatId; UserId=$UserId })
    Write-BridgeLog "Admin $UserId tested template '$($template.Key)' on isolated layer $testLayer for $seconds seconds" 'WARN'
    Add-AuditEntry "🧪 اختبار قالب $($template.Key) على طبقة $testLayer - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ بدأ اختبار '$($template.Key)' على طبقة التجربة $testLayer وسيُخفى خلال $seconds ثانية." -ReplyMarkup (Get-AfterShowKeyboard -Layer $testLayer -ChatId $ChatId -UserId $UserId)
}

function Test-TemplateRegistryImport {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $rawText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([Text.Encoding]::UTF8.GetByteCount($rawText) -gt $script:TemplateRegistryImportMaximumBytes) { throw 'الملف أكبر من 10 ميغابايت.' }
        $document = $rawText | ConvertFrom-Json -ErrorAction Stop
        $properties = @($document.PSObject.Properties)
        $maximumTemplates = Get-SettingInt 'TemplateRegistryImportMaxTemplates' 1
        if ($properties.Count -eq 0 -or $properties.Count -gt $maximumTemplates) { throw "يجب أن يحتوي السجل بين قالب واحد و$maximumTemplates قالب." }
        foreach ($property in $properties) {
            if ($property.Name -notmatch '^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$') { throw "مفتاح القالب '$($property.Name)' غير صالح." }
            $entry = $property.Value
            $templatePath = [string](Get-JsonProp $entry 'path')
            if ([string]::IsNullOrWhiteSpace($templatePath) -or -not [IO.Path]::IsPathRooted($templatePath) -or
                -not [IO.Path]::GetExtension($templatePath).Equals('.cintitle', [StringComparison]::OrdinalIgnoreCase)) {
                throw "القالب '$($property.Name)' يحتاج مسارًا مطلقًا لملف .cintitle."
            }
            $layer = 0
            if (-not [int]::TryParse([string](Get-JsonProp $entry 'layer'), [ref]$layer) -or $layer -le 0) {
                throw "القالب '$($property.Name)' يحتاج رقم طبقة موجبًا."
            }
            foreach ($field in @(Get-JsonProp $entry 'fields' | Where-Object { $null -ne $_ })) {
                $fieldName = if ($field -is [string]) { [string]$field } else { [string](Get-JsonProp $field 'name') }
                if ([string]::IsNullOrWhiteSpace($fieldName)) { throw "القالب '$($property.Name)' يحتوي حقلاً بلا اسم." }
            }
        }
        return [pscustomobject]@{ Success=$true; Error=''; Document=$document; Count=$properties.Count }
    }
    catch { return [pscustomobject]@{ Success=$false; Error=Protect-SensitiveText $_.Exception.Message; Document=$null; Count=0 } }
}

function Get-TemplateRegistryImportComparison {
    param([Parameter(Mandatory)]$Current, [Parameter(Mandatory)]$Imported)
    $currentNames = @($Current.PSObject.Properties.Name)
    $importedNames = @($Imported.PSObject.Properties.Name)
    $added = @($importedNames | Where-Object { $currentNames -notcontains $_ })
    $removed = @($currentNames | Where-Object { $importedNames -notcontains $_ })
    $changed = @($importedNames | Where-Object {
        $currentNames -contains $_ -and
        ((Get-JsonProp $Current $_ | ConvertTo-Json -Depth 20 -Compress) -ne (Get-JsonProp $Imported $_ | ConvertTo-Json -Depth 20 -Compress))
    })
    $unchanged = @($importedNames | Where-Object { $currentNames -contains $_ -and $changed -notcontains $_ })
    return [pscustomobject]@{ Added=$added; Removed=$removed; Changed=$changed; Unchanged=$unchanged }
}

function Start-TemplateRegistryImport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Get-Setting 'EnableFullTemplateManagement')) {
        Send-TelegramMessage -ChatId $ChatId -Text '🔒 فعّل إدارة القوالب الكاملة أولاً.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_import_upload'; UserId=$UserId }
    Send-TelegramMessage -ChatId $ChatId -Text '📥 أرسل ملف JSON واحدًا (بحد أقصى 10 ميغابايت). سيُفحص ويُعرض الفرق قبل أي استبدال.' -ReplyMarkup (Get-CancelKeyboard)
}

function Invoke-TemplateRegistryExport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return }
    $path = Get-TemplateRegistryFilePath
    if (Send-TelegramDocument -ChatId $ChatId -FilePath $path -Caption '📤 نسخة تعريفات القوالب. لا تحتوي حالة الهواء أو قيم النصوص المستخدمة.') {
        Add-AuditEntry "📤 تصدير تعريفات القوالب - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    }
}

function Receive-TemplateRegistryImport {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_import_upload' -or [long]$state.UserId -ne $UserId -or
        -not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return }
    $fileName = [string](Get-JsonProp $Document 'file_name')
    $fileSize = [long](Get-JsonProp $Document 'file_size')
    if (-not $fileName.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -or $fileSize -le 0 -or $fileSize -gt $script:TemplateRegistryImportMaximumBytes) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ يجب رفع ملف JSON حجمه بين 1 بايت و10 ميغابايت.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $stagingDirectory = Join-Path $script:logDir 'template-imports'
    $stagedPath = Join-Path $stagingDirectory "staged-$([guid]::NewGuid().ToString('N')).json"
    try {
        Receive-TelegramDocument -FileId ([string](Get-JsonProp $Document 'file_id')) -DestinationPath $stagedPath -MaximumBytes $script:TemplateRegistryImportMaximumBytes | Out-Null
        $validation = Test-TemplateRegistryImport -Path $stagedPath
        if (-not $validation.Success) { throw $validation.Error }
        $current = Get-Content -LiteralPath (Get-TemplateRegistryFilePath) -Raw | ConvertFrom-Json
        $comparison = Get-TemplateRegistryImportComparison -Current $current -Imported $validation.Document
        $state = @{ Mode='template_import_review'; UserId=$UserId; ImportStagedPath=$stagedPath }
        Set-PendingState -ChatId $ChatId -State $state
        $summary = "🔎 مراجعة استيراد القوالب`nالإجمالي: $($validation.Count)`nمضاف: $($comparison.Added.Count)`nمعدّل: $($comparison.Changed.Count)`nمحذوف: $($comparison.Removed.Count)`nبلا تغيير: $($comparison.Unchanged.Count)`n`nلن يُستبدل الملف حتى التأكيد."
        Send-TelegramMessage -ChatId $ChatId -Text $summary -ReplyMarkup @{ inline_keyboard=@(
            , @((New-Button '✅ اعتماد الاستيراد' 'timport:confirm' -Style success), (New-Button '❌ إلغاء' 'menu:templatesadmin'))
        ) }
    }
    catch {
        Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
        Send-TelegramMessage -ChatId $ChatId -Text "❌ رُفض ملف الاستيراد: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
    }
}

function Set-ImportedTemplateRegistry {
    param([Parameter(Mandatory)][string]$StagedPath)
    $path = Get-TemplateRegistryFilePath
    $temporary = "$path.import.tmp"
    try {
        $validation = Test-TemplateRegistryImport -Path $StagedPath
        if (-not $validation.Success) { throw $validation.Error }
        $current = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $comparison = Get-TemplateRegistryImportComparison -Current $current -Imported $validation.Document
        $unsafeKeys = @($comparison.Removed + $comparison.Changed | Sort-Object -Unique)
        $liveKeys = @($script:OnAir.Values | ForEach-Object { [string](Get-JsonProp $_ 'Key') })
        $scheduledKeys = @(Get-UpcomingScheduleEvents | ForEach-Object { [string](Get-JsonProp $_ 'TemplateKey') })
        $blocked = @($unsafeKeys | Where-Object { $liveKeys -contains $_ -or $scheduledKeys -contains $_ })
        if ($blocked.Count -gt 0) { throw "لا يمكن تغيير أو حذف قالب مستخدم على الهواء أو في جدولة قادمة: $($blocked -join '، ')" }
        $backupDirectory = "$path.backups"
        New-Item -ItemType Directory -Path $backupDirectory -Force -ErrorAction Stop | Out-Null
        $backupPath = Join-Path $backupDirectory "templates-import-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
        [IO.File]::WriteAllText($temporary, ($validation.Document | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        $script:TemplateCache = @{ WriteTime=[datetime]::MinValue; Path=''; Map=@{}; Order=@(); Errors=@() }
        return [pscustomobject]@{ Success=$true; Error=''; BackupPath=$backupPath; Comparison=$comparison }
    }
    catch { return [pscustomobject]@{ Success=$false; Error=Protect-SensitiveText $_.Exception.Message; BackupPath=''; Comparison=$null } }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Confirm-TemplateRegistryImport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_import_review' -or [long]$state.UserId -ne $UserId) { return }
    $stagedPath = [string]$state.ImportStagedPath
    $result = Set-ImportedTemplateRegistry -StagedPath $stagedPath
    Clear-PendingState -ChatId $ChatId
    if ($result.Success) {
        Add-AuditEntry "📥 استيراد تعريفات القوالب مع نسخة احتياطية - بواسطة $(Format-UserAuditActor -UserId $UserId)"
        Send-TelegramMessage -ChatId $ChatId -Text '✅ تم استيراد تعريفات القوالب وحفظ نسخة من السجل السابق.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
    }
    else { Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر اعتماد الاستيراد: $($result.Error)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
}

function Get-DiagnosticWarnings {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [int]$DiskFreeWarningGB = 2,
        [int]$RuntimeStorageWarningMB = 100,
        [int]$BackupStorageWarningMB = 50
    )
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Snapshot.DiskFreeGB -and [double]$Snapshot.DiskFreeGB -lt [math]::Max(1, $DiskFreeWarningGB)) {
        $warnings.Add("⚠️ مساحة القرص الحرة منخفضة: $($Snapshot.DiskFreeGB) GB")
    }
    if ([long]$Snapshot.RuntimeStorageBytes -gt ([math]::Max(1, $RuntimeStorageWarningMB) * 1MB)) {
        $warnings.Add("⚠️ حجم السجلات وملفات التشغيل تجاوز $RuntimeStorageWarningMB MB")
    }
    if ([long]$Snapshot.BackupStorageBytes -gt ([math]::Max(1, $BackupStorageWarningMB) * 1MB)) {
        $warnings.Add("⚠️ حجم النسخ الاحتياطية تجاوز $BackupStorageWarningMB MB")
    }
    return $warnings.ToArray()
}

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
    Send-TelegramPagedText -ChatId $ChatId -Text $text -ReplyMarkup (Get-DiagnosticsKeyboard)
}

function Get-DiagnosticsKeyboard {
    return @{ inline_keyboard = @(
        , @((New-Button '🔎 ابحث بمرجع عملية' 'diag:findref'))
        , @((New-Button '📦 حزمة تشخيص منقحة' 'diag:bundle'))
        , @((New-Button '🧹 مسح سجل التشغيل' 'diag:clearruntime'), (New-Button '🧹 مسح سجل التدقيق' 'diag:clearaudit'))
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

function Invoke-AuditCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($script:AuditTrail.Count -eq 0) {
        # Rebuilt from audit.jsonl at startup, so empty no longer means
        # "the process restarted" - it means nothing has happened yet.
        Send-TelegramMessage -ChatId $ChatId -Text "📜 آخر العمليات`n━━━━━━━━━━━━━━`nلا توجد عمليات مسجّلة بعد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $text = "📜 آخر العمليات`n━━━━━━━━━━━━━━`n" + (($script:AuditTrail | Select-Object -Last 20) -join "`n")
    Send-TelegramPagedText -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Request-Approval {
    <# Notifies every admin once per pending chat, with Approve/Reject buttons.
       Capped by MaxPendingApprovals so a publicly-discovered bot cannot flood
       the admins, and entries age out after PendingApprovalExpiryHours. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, $From)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableSelfServiceRequests')) { return $false }
    if ($script:PendingApprovals.ContainsKey($ChatId)) { return $true }

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
    Send-AdminBroadcast -Text "🔔 طلب وصول جديد للبوت`n$($nameLine)رقم المحادثة: $ChatId`nرقم المستخدم: $UserId" -ReplyMarkup (Get-ApprovalKeyboard -TargetChatId $ChatId)
    Write-BridgeLog "Access request from chat $ChatId / user $UserId ($name) sent to admins"
    return $true
}

function Grant-UserAccess {
    param([Parameter(Mandatory)][long]$TargetChatId, [Parameter(Mandatory)][long]$ApprovedBy, [long]$ApproverUserId = 0)
    if ($ApproverUserId -eq 0) { $ApproverUserId = $ApprovedBy }
    $targetUserId = $TargetChatId
    if ($script:PendingApprovals.ContainsKey($TargetChatId)) { $targetUserId = [long]$script:PendingApprovals[$TargetChatId].UserId }

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
    Write-UserApprovalMetadata -TargetUserId $targetUserId -ApprovedByUserId $ApproverUserId | Out-Null

    $script:PendingApprovals.Remove($TargetChatId)
    Write-BridgeLog "User $ApproverUserId approved new user $targetUserId (chat $TargetChatId)"
    Add-AuditEntry "👤 موافقة على $(Format-UserAuditActor -UserId ([long]$targetUserId)) - بواسطة $(Format-UserAuditActor -UserId $ApproverUserId)"
    Send-TelegramMessage -ChatId $ApprovedBy -Text "✅ تمت الموافقة على $TargetChatId وأُضيف إلى المستخدمين المصرح لهم.$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ApprovedBy -UserId $ApproverUserId)
    Send-TelegramMessage -ChatId $TargetChatId -Text "✅ تمت الموافقة على طلبك، يمكنك الآن استخدام البوت." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $TargetChatId -UserId $targetUserId)
}

function Deny-UserAccess {
    param([Parameter(Mandatory)][long]$TargetChatId, [Parameter(Mandatory)][long]$RejectedBy, [long]$RejecterUserId = 0)
    if ($RejecterUserId -eq 0) { $RejecterUserId = $RejectedBy }
    $script:PendingApprovals.Remove($TargetChatId)
    Write-BridgeLog "User $RejecterUserId rejected access request from $TargetChatId"
    Add-AuditEntry "👤 رفض طلب $TargetChatId - بواسطة $(Format-UserAuditActor -UserId $RejecterUserId)"
    Send-TelegramMessage -ChatId $RejectedBy -Text "❌ تم رفض طلب $TargetChatId." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $RejectedBy -UserId $RejecterUserId)
    Send-TelegramMessage -ChatId $TargetChatId -Text "تم رفض طلب الوصول الخاص بك."
}
