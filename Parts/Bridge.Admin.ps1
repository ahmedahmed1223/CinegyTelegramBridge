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
        $age = [math]::Max(0, [int]((Get-Date) - $info.At).TotalSeconds)
        $ageText = if ($age -ge 60) { "$([int]($age / 60)) دقيقة" } else { "$age ثانية" }
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
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add("🌐 $($config.AirServerAddress) · القناة $($config.AirChannelNumber) · القوالب: $($store.Order.Count)")
    $sharedLayers = Get-JsonProp $store 'SharedLayers'
    if ($sharedLayers -and $sharedLayers.Count -gt 0) {
        $sharedText = @($sharedLayers.Keys | Sort-Object {[int]$_} | ForEach-Object { "طبقة ${_}: $(@($sharedLayers[$_]) -join '، ')" }) -join ' | '
        $lines.Add("ℹ️ طبقات مشتركة بين عدة قوالب (مسموح): $sharedText")
    }
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: $($freshness.Label)")
    if ($lastSuccessfulAt) {
        $lines.Add("🔄 آخر فحص ناجح: $(([datetime]$lastSuccessfulAt).ToString('yyyy-MM-dd HH:mm:ss'))")
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
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
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
        Send-TelegramMessage -ChatId $ChatId -Text 'القالب لم يعد موجودًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
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
    if (Get-Setting 'EnableFullTemplateManagement') {
        $lines += '✅ التحكم الكامل بالقوالب مفعّل. اختر عملية التعديل من الأزرار.'
    }
    else {
        $lines += '🔒 التحكم الكامل معطّل. يمكنك القراءة وإدارة النصوص الجاهزة فقط.'
    }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex)
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
    Send-TelegramMessage -ChatId $ChatId -Text "➕ إضافة قالب (1/4)`nأرسل مفتاح القالب (أحرف إنجليزية وأرقام ونقاط/شرطات، مثل: new-template):" -ReplyMarkup (Get-CancelKeyboard)
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
            Send-TelegramMessage -ChatId $ChatId -Text "(2/4) أرسل مسار ملف القالب نسبةً إلى مجلد المشروع، مثل:`ntitles/new.cintitle" -ReplyMarkup (Get-CancelKeyboard)
        }
        'template_create_path' {
            $trimmed = $Value.Trim().Replace('/', '\')
            if ($trimmed -match '^(تم|ok)$') {
                if ($definition.ContainsKey('pendingPath')) {
                    $definition['path'] = ([string]$definition['pendingPath']).Replace('\', '/'); $definition.Remove('pendingPath')
                    $state.Mode = 'template_create_layer'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
                    Send-TelegramMessage -ChatId $ChatId -Text '(3/4) أرسل رقم الطبقة (رقم موجب، مثل 4 أو 7):' -ReplyMarkup (Get-CancelKeyboard); return
                }
                Send-TelegramMessage -ChatId $ChatId -Text '❌ لا يوجد مسار معلّق للمتابعة. أرسل مسار ملف القالب أولًا:' -ReplyMarkup (Get-CancelKeyboard); return
            }
            if ([IO.Path]::IsPathRooted($trimmed) -or [IO.Path]::GetExtension($trimmed) -ne '.cintitle') {
                Send-TelegramMessage -ChatId $ChatId -Text "❌ أرسل مسارًا نسبيًا ينتهي بـ .cintitle، مثل:`ntitles/new.cintitle" -ReplyMarkup (Get-CancelKeyboard); return
            }
            $root = [IO.Path]::GetFullPath($scriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $resolved = [IO.Path]::GetFullPath((Join-Path $scriptRoot $trimmed))
            if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                Send-TelegramMessage -ChatId $ChatId -Text '❌ المسار يجب أن يبقى داخل مجلد المشروع. أرسل مسارًا نسبيًا:' -ReplyMarkup (Get-CancelKeyboard); return
            }
            if (-not (Test-Path -LiteralPath $resolved)) {
                $definition['pendingPath'] = $trimmed
                $state.Mode = 'template_create_path'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
                Send-TelegramMessage -ChatId $ChatId -Text "⚠️ الملف غير موجود بعد: $trimmed`nللمتابعة بهذا المسار أرسل: تم`nأو أرسل مسارًا آخر لإعادة الإدخال." -ReplyMarkup (Get-CancelKeyboard); return
            }
            $definition.Remove('pendingPath')
            $definition['path'] = $trimmed.Replace('\', '/')
            $state.Mode = 'template_create_layer'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
            Send-TelegramMessage -ChatId $ChatId -Text '(3/4) أرسل رقم الطبقة (رقم موجب، مثل 4 أو 7):' -ReplyMarkup (Get-CancelKeyboard)
        }
        'template_create_layer' {
            $layer = 0
            if (-not [int]::TryParse($Value.Trim(), [ref]$layer) -or $layer -le 0) {
                Send-TelegramMessage -ChatId $ChatId -Text '❌ أرسل رقم طبقة موجبًا (مثل 4):' -ReplyMarkup (Get-CancelKeyboard); return
            }
            $definition['layer'] = $layer
            $state.Mode = 'template_create_fields'; $state.Definition = $definition; Set-PendingState -ChatId $ChatId -State $state
            Send-TelegramMessage -ChatId $ChatId -Text "(4/4) أرسل أسماء الحقول مفصولة بفواصل (مثل: Headline.Text, Subtitle.Text)`nأو أرسل: لا يوجد إذا كان القالب بلا حقول." -ReplyMarkup (Get-CancelKeyboard)
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
            $state.Mode = 'template_definition_review'; $state.Action = 'create'
            $state.TemplateKey = [string]$definition['key']; $state.Definition = $definition
            Set-PendingState -ChatId $ChatId -State $state
            $fieldsLabel = if (@($fields).Count -gt 0) { @($fields) -join '، ' } else { 'لا توجد حقول' }
            Send-TelegramMessage -ChatId $ChatId -Text "🔎 مراجعة القالب الجديد '$($state.TemplateKey)'`nالمسار: $($definition['path'])`nالطبقة: $($definition['layer'])`nالحقول: $fieldsLabel`n`nلن يُحفظ شيء قبل التأكيد، وستُنشأ نسخة احتياطية من التعريفات الحالية." -ReplyMarkup (Get-TemplateDefinitionReviewKeyboard)
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
    if ($result.Success) { Add-AuditEntry "📚 $($state.Action) قالب $($state.TemplateKey) - user $UserId"; Send-TelegramMessage -ChatId $ChatId -Text '✅ تم حفظ تعريف القالب مع نسخة احتياطية.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
    else { Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ القالب: $($result.Error)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
}

function Invoke-FullStatusCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "هذا الأمر مخصص للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $store = Get-TemplateStore
    $layerStatuses = @(Get-CinegyLayerDashboard)
    $sync = Update-OnAirStateFromCinegy -Reason 'full-status' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal
    $health = Get-HealthStatusReport
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
    $lines.Add('')
    $lines.Add((Get-OnAirSummary))
    $lines.Add('')
    $lines.Add('🎛 اتصال Cinegy')
    $lines.Add("🌐 $($config.AirServerAddress) · القناة $($config.AirChannelNumber) · القوالب: $($store.Order.Count)")
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: $($freshness.Label)")
    $lines.Add((Format-CinegyLayerDashboard -LayerStatuses $layerStatuses))
    $lines.Add('')
    $lines.Add('🩺 صحة الخدمات')
    $lines.Add($health.Text)
    $lines.Add('')
    $lines.Add('⚙️ التشغيل والجدولة')
    $lines.Add("📡 البث المباشر: $(Get-LiveRelayStatusText)")
    $lines.Add("🖼 الصور المعلّقة: $($script:SnapshotJobs.Count) · مؤقتات الإخفاء: $($script:AutoHideQueue.Count)")
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
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
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
    Add-AuditEntry "🧪 اختبار قالب $($template.Key) على طبقة $testLayer - user $UserId"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ بدأ اختبار '$($template.Key)' على طبقة التجربة $testLayer وسيُخفى خلال $seconds ثانية." -ReplyMarkup (Get-AfterShowKeyboard -Layer $testLayer -ChatId $ChatId -UserId $UserId)
}

function Test-TemplateRegistryImport {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $rawText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([Text.Encoding]::UTF8.GetByteCount($rawText) -gt 1048576) { throw 'الملف أكبر من 1 ميغابايت.' }
        $document = $rawText | ConvertFrom-Json -ErrorAction Stop
        $properties = @($document.PSObject.Properties)
        if ($properties.Count -eq 0 -or $properties.Count -gt 200) { throw 'يجب أن يحتوي السجل بين قالب واحد و200 قالب.' }
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
    Send-TelegramMessage -ChatId $ChatId -Text '📥 أرسل ملف JSON واحدًا (بحد أقصى 1 ميغابايت). سيُفحص ويُعرض الفرق قبل أي استبدال.' -ReplyMarkup (Get-CancelKeyboard)
}

function Invoke-TemplateRegistryExport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return }
    $path = Get-TemplateRegistryFilePath
    if (Send-TelegramDocument -ChatId $ChatId -FilePath $path -Caption '📤 نسخة تعريفات القوالب. لا تحتوي حالة الهواء أو قيم النصوص المستخدمة.') {
        Add-AuditEntry "📤 تصدير تعريفات القوالب - user $UserId"
    }
}

function Receive-TemplateRegistryImport {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_import_upload' -or [long]$state.UserId -ne $UserId -or
        -not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return }
    $fileName = [string](Get-JsonProp $Document 'file_name')
    $fileSize = [long](Get-JsonProp $Document 'file_size')
    if (-not $fileName.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -or $fileSize -le 0 -or $fileSize -gt 1048576) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ يجب رفع ملف JSON حجمه بين 1 بايت و1 ميغابايت.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $stagingDirectory = Join-Path $script:logDir 'template-imports'
    $stagedPath = Join-Path $stagingDirectory "staged-$([guid]::NewGuid().ToString('N')).json"
    try {
        Receive-TelegramDocument -FileId ([string](Get-JsonProp $Document 'file_id')) -DestinationPath $stagedPath -MaximumBytes 1048576 | Out-Null
        $validation = Test-TemplateRegistryImport -Path $stagedPath
        if (-not $validation.Success) { throw $validation.Error }
        $current = Get-Content -LiteralPath (Get-TemplateRegistryFilePath) -Raw | ConvertFrom-Json
        $comparison = Get-TemplateRegistryImportComparison -Current $current -Imported $validation.Document
        $state = @{ Mode='template_import_review'; UserId=$UserId; ImportStagedPath=$stagedPath }
        Set-PendingState -ChatId $ChatId -State $state
        $summary = "🔎 مراجعة استيراد القوالب`nالإجمالي: $($validation.Count)`nمضاف: $($comparison.Added.Count)`nمعدّل: $($comparison.Changed.Count)`nمحذوف: $($comparison.Removed.Count)`nبلا تغيير: $($comparison.Unchanged.Count)`n`nلن يُستبدل الملف حتى التأكيد."
        Send-TelegramMessage -ChatId $ChatId -Text $summary -ReplyMarkup @{ inline_keyboard=@(
            , @((New-Button '✅ اعتماد الاستيراد' 'timport:confirm'), (New-Button '❌ إلغاء' 'menu:templatesadmin'))
        ) }
    }
    catch {
        Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
        Send-TelegramMessage -ChatId $ChatId -Text "❌ رُفض ملف الاستيراد: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
    }
}

function Apply-TemplateRegistryImport {
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
    $result = Apply-TemplateRegistryImport -StagedPath $stagedPath
    Clear-PendingState -ChatId $ChatId
    if ($result.Success) {
        Add-AuditEntry "📥 استيراد تعريفات القوالب مع نسخة احتياطية - user $UserId"
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

function Get-DiagnosticsKeyboard {
    return @{ inline_keyboard = @(
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
            Add-AuditEntry "📦 تنزيل حزمة تشخيص منقحة - user $UserId"
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
            , @((New-Button '⚠️ نعم، امسح' 'diag:clearconfirm'), (New-Button '❌ إلغاء' 'menu:diagnostics'))
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
        "وقت البناء: $buildText | مدة التشغيل: $([int]$uptime.TotalHours)س $($uptime.Minutes)د",
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
        Send-TelegramMessage -ChatId $ChatId -Text "لا توجد عمليات مسجّلة منذ آخر تشغيل." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $text = "📜 آخر العمليات:`n" + (($script:AuditTrail | Select-Object -Last 20) -join "`n")
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
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
    Record-UserApprovalMetadata -TargetUserId $targetUserId -ApprovedByUserId $ApproverUserId | Out-Null

    $script:PendingApprovals.Remove($TargetChatId)
    Write-BridgeLog "User $ApproverUserId approved new user $targetUserId (chat $TargetChatId)"
    Add-AuditEntry "👤 موافقة على $targetUserId - by $ApproverUserId"
    Send-TelegramMessage -ChatId $ApprovedBy -Text "✅ تمت الموافقة على $TargetChatId وأُضيف إلى المستخدمين المصرح لهم.$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ApprovedBy -UserId $ApproverUserId)
    Send-TelegramMessage -ChatId $TargetChatId -Text "✅ تمت الموافقة على طلبك، يمكنك الآن استخدام البوت." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $TargetChatId -UserId $targetUserId)
}

function Deny-UserAccess {
    param([Parameter(Mandatory)][long]$TargetChatId, [Parameter(Mandatory)][long]$RejectedBy, [long]$RejecterUserId = 0)
    if ($RejecterUserId -eq 0) { $RejecterUserId = $RejectedBy }
    $script:PendingApprovals.Remove($TargetChatId)
    Write-BridgeLog "User $RejecterUserId rejected access request from $TargetChatId"
    Add-AuditEntry "👤 رفض طلب $TargetChatId - by $RejecterUserId"
    Send-TelegramMessage -ChatId $RejectedBy -Text "❌ تم رفض طلب $TargetChatId." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $RejectedBy -UserId $RejecterUserId)
    Send-TelegramMessage -ChatId $TargetChatId -Text "تم رفض طلب الوصول الخاص بك."
}

