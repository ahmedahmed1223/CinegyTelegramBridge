#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Resolve-TemplateShortcut {
    <# Maps typed text to a template index, or -1. Exact, case-insensitive
       match on the template key only: anything looser risks putting the wrong
       graphic on air because someone mistyped. #>
    param([string]$Text)
    if (-not (Get-Setting 'EnableTextShortcuts')) { return -1 }
    $needle = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($needle)) { return -1 }
    $store = Get-TemplateStore
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        if (([string]$store.Order[$i]).Equals($needle, [System.StringComparison]::OrdinalIgnoreCase)) { return $i }
    }
    return -1
}

function Show-SettingsScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text "⚙️ الإعدادات`nاختر قسمًا. تظهر الخيارات الشائعة أولًا، وتبقى الإعدادات التقنية في «خيارات متقدمة»." -ReplyMarkup (Get-SettingsKeyboard)
}

function Get-SettingsExplainedLines {
    <#
        The settings on a screen, each as its name and what it does.

        The buttons carry a name and a value and no room for more, so what a
        setting actually does had nowhere to appear - it was written down in
        the metadata and shown only on the prompt for a number. These lines
        are that explanation, above the buttons they describe.
    #>
    param([AllowEmptyCollection()][string[]]$Names = @())
    return @(foreach ($name in @($Names)) {
            $metadata = Get-SettingNavigationMetadata -Name $name
            $description = [string](Get-JsonProp (Get-JsonProp $script:SettingDisplayMetadata $name) 'Description')
            $line = "• <b>$(ConvertTo-TelegramHtmlText -Text ([string]$metadata.Label))</b>"
            # A setting without a short name of its own falls back to its
            # description; printing it twice says nothing twice.
            if ($description -and $description -ne [string]$metadata.Label) {
                $line += " — $(ConvertTo-TelegramHtmlText -Text $description)"
            }
            $line
        })
}

function Get-SettingValueDisplay {
    <# A setting's value in the words its own screen uses: a switch reads
       مفعّل/معطّل there, not True/False. #>
    param([Parameter(Mandatory)][string]$Name, $Value)
    if ($script:DefaultSettings[$Name] -is [bool]) {
        return $(if ([bool]$Value) { 'مفعّل' } else { 'معطّل' })
    }
    $text = [string](Format-SettingDisplay -Name $Name -Value $Value)
    return $(if ([string]::IsNullOrWhiteSpace($text)) { '(فارغ)' } else { $text })
}

function Get-SettingChangeText {
    <#
        The confirmation of a change, in the words the rest of the screens
        use.

        It used to read "✅ AuditTemplateValues = True": the key from the
        JSON file and the value as PowerShell prints it, on a screen whose
        buttons, list lines and search results are all Arabic. And it said
        what the setting is now without saying what it was, so an
        administrator who mistapped had nothing to undo it back to.
    #>
    param([Parameter(Mandatory)][string]$Name, $From, $To)
    $label = [string](Get-SettingNavigationMetadata -Name $Name).Label
    $lines = @(
        "✅ <b>$(ConvertTo-TelegramHtmlText -Text $label)</b>"
        "من «$(ConvertTo-TelegramHtmlText -Text (Get-SettingValueDisplay -Name $Name -Value $From))» إلى «$(ConvertTo-TelegramHtmlText -Text (Get-SettingValueDisplay -Name $Name -Value $To))»"
    )
    $warning = [string](Get-ConfigSaveWarning)
    if ($warning) { $lines += (ConvertTo-TelegramHtmlText -Text $warning.Trim()) }
    return ($lines -join "`n")
}

function Show-SettingsCategoryScreen {
    param(
        [Parameter(Mandatory)][string]$Category,
        [ValidateRange(0, [int]::MaxValue)][int]$Page = 0,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $definition = @($script:SettingCategoryDefinitions | Where-Object { $_.Key -eq $Category })
    if ($definition.Count -ne 1) {
        Show-SettingsScreen -ChatId $ChatId -UserId $UserId
        return
    }
    $title = "$($definition[0].Icon) $($definition[0].Label)"
    # The buttons carry a label and a value; neither says what the setting
    # does, and a label alone left the reader guessing which of eight screens
    # held what they came for. The summary answers that, and each line under
    # it explains the button below it.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>⚙️ الإعدادات ← $(ConvertTo-TelegramHtmlText -Text $title)</b>")
    $summary = [string](Get-JsonProp $definition[0] 'Summary')
    if ($summary) { $lines.Add("<i>$(ConvertTo-TelegramHtmlText -Text $summary)</i>") }
    $lines.Add('')
    foreach ($line in @(Get-SettingsExplainedLines -Names @(Get-SettingsCategoryPageNames -Category $Category -Page $Page))) {
        $lines.Add($line)
    }
    $lines.Add('')
    $lines.Add('اضغط خيارًا لتبديله أو تغيير قيمته.')
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup (Get-SettingsCategoryKeyboard -Category $Category -Page $Page)
}

function Show-HideAllLayerSettings {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $layers = @(Get-HideAllTargetLayers)
    $scopeText = if ($layers.Count -gt 0) { $layers -join '، ' } else { 'لا توجد طبقات محددة' }
    Send-TelegramMessage -ChatId $ChatId -Text "🚨 طبقات إخفاء الكل الحالية: $scopeText`nاضغط طبقة لتضمينها أو استبعادها. هذا التحديد هو فقط ما سيخفيه زر الطوارئ." -ReplyMarkup (Get-HideAllLayerSettingsKeyboard)
}

function Show-LayerNamesScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text "🏷️ أسماء الطبقات`nاختر طبقة، ثم أرسل اسمًا واحدًا واضحًا لها. لا تحتاج إلى كتابة رموز أو أرقام بصيغة خاصة." -ReplyMarkup (Get-LayerNamesKeyboard)
}

function Set-LayerName {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [AllowEmptyString()][string]$Name = '',
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $trimmed = $Name.Trim()
    if ($trimmed.Length -gt 60 -or $trimmed.IndexOfAny([char[]]';=') -ge 0) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ الاسم يجب أن يكون حتى 60 حرفًا، ولا يحتوي على ; أو =. لم يتغيّر شيء.' -ReplyMarkup (Get-LayerNameEditKeyboard -Layer $Layer)
        return $false
    }

    $names = [ordered]@{}
    foreach ($pair in @([string](Get-Setting 'LayerNames') -split ';')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        if ($parts.Count -lt 2) { continue }
        $number = 0
        if ([int]::TryParse($parts[0].Trim(), [ref]$number) -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
            $key = [string]$number
            $names[$key] = $parts[1].Trim()
        }
    }
    $layerKey = [string]$Layer
    if ([string]::IsNullOrWhiteSpace($trimmed)) { $names.Remove($layerKey) | Out-Null }
    else { $names[$layerKey] = $trimmed }

    $stored = @($names.Keys | Sort-Object { [int]$_ } | ForEach-Object { "$_=$($names[$_])" }) -join ';'
    Set-Setting -Name 'LayerNames' -Value $stored
    $action = if ([string]::IsNullOrWhiteSpace($trimmed)) { 'cleared' } else { "set to '$trimmed'" }
    Write-BridgeLog "User $UserId $action layer $Layer name"
    Add-AuditEntry "🏷️ اسم طبقة $Layer $action - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    $message = if ([string]::IsNullOrWhiteSpace($trimmed)) { "✅ تم مسح اسم طبقة $Layer." } else { "✅ تم حفظ الاسم: $(Get-LayerDisplayName -Layer $Layer)" }
    Send-TelegramMessage -ChatId $ChatId -Text "$message$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-LayerNamesKeyboard)
    return $true
}

function Start-LayerNamePrompt {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'layer_name'; Layer = $Layer; UserId = $UserId }
    $current = Get-LayerName -Layer $Layer
    $currentText = if ($current) { "الاسم الحالي: $current" } else { 'لا يوجد اسم حاليًا.' }
    Send-TelegramMessage -ChatId $ChatId -Text "🏷️ طبقة $Layer`n$currentText`nأرسل الاسم الجديد فقط." -ReplyMarkup (Get-LayerNameEditKeyboard -Layer $Layer)
}

function Complete-LayerName {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'layer_name') { return }
    Clear-PendingState -ChatId $ChatId
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ الاسم فارغ. استخدم زر «مسح الاسم» إن أردت حذفه.' -ReplyMarkup (Get-LayerNameEditKeyboard -Layer ([int]$state.Layer))
        return
    }
    Set-LayerName -Layer ([int]$state.Layer) -Name $Value -ChatId $ChatId -UserId ([long]$state.UserId) | Out-Null
}

function Set-HideAllLayerSelection {
    param(
        [int]$Layer = 0,
        [switch]$SelectAll,
        [switch]$ClearAll,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $known = @((Get-KnownLayers | ForEach-Object { [int]$_ }) | Sort-Object -Unique)
    if ($SelectAll) { $value = 'all' }
    elseif ($ClearAll) { $value = '' }
    else {
        if ($known -notcontains $Layer) {
            Send-TelegramMessage -ChatId $ChatId -Text "هذه الطبقة لم تعد ضمن القوالب المعرّفة." -ReplyMarkup (Get-HideAllLayerSettingsKeyboard)
            return
        }
        $selected = @(Get-HideAllTargetLayers)
        if (([string](Get-Setting 'HideAllLayers')).Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) { $selected = $known }
        if ($selected -contains $Layer) { $selected = @($selected | Where-Object { $_ -ne $Layer }) }
        else { $selected += $Layer }
        $value = (@($selected | Sort-Object -Unique) -join ',')
    }
    Set-Setting -Name 'HideAllLayers' -Value $value
    Write-BridgeLog "User $UserId changed HideAllLayers to '$value'" "WARN"
    Add-AuditEntry "🚨 طبقات إخفاء الكل = $value - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-HideAllLayerSettings -ChatId $ChatId -UserId $UserId
}

function Invoke-SettingToggle {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [switch]$Confirmed)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:DefaultSettings.Contains($Name)) {
        Send-TelegramMessage -ChatId $ChatId -Text "إعداد غير معروف: $Name" -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    $new = -not [bool](Get-Setting $Name)

    # Only *weakening* a protected setting needs confirmation; re-enabling
    # protection should stay a single tap.
    if (-not $Confirmed -and -not $new -and $script:ProtectedSettings -contains $Name) {
        $protectedLabel = [string](Get-SettingNavigationMetadata -Name $Name).Label
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ «$protectedLabel» إعداد حماية. تعطيله يوسّع من يستطيع التحكم بالهواء.`nهل أنت متأكد؟" -ReplyMarkup (Get-SettingConfirmKeyboard -Name $Name)
        return
    }
    Set-Setting -Name $Name -Value $new
    Write-BridgeLog "User $UserId set $Name = $new"
    Add-AuditEntry "⚙️ $Name = $new - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text (Get-SettingChangeText -Name $Name -From (-not $new) -To $new) -ParseMode HTML -ReplyMarkup (Get-SettingsKeyboard)
}

function Start-SettingValuePrompt {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:DefaultSettings.Contains($Name)) {
        Send-TelegramMessage -ChatId $ChatId -Text "إعداد غير معروف: $Name" -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'setting_value'; Name = $Name; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-SettingPromptText -Name $Name) -ParseMode HTML -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-SettingValue {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    Clear-PendingState -ChatId $ChatId
    $parsed = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$parsed)) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ القيمة يجب أن تكون رقمًا صحيحًا. لم يتغيّر شيء." -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    if ($parsed -lt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ القيمة لا يمكن أن تكون سالبة." -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    if ($state.Name -eq 'TemplateTestLayer') {
        $conflict = @(Get-TemplateTestLayerConflict -Layer $parsed)
        if ($conflict.Count -gt 0) {
            Send-TelegramMessage -ChatId $ChatId -Text "❌ الطبقة $parsed مستخدمة في قوالب الإنتاج: $($conflict -join '، ')`nاختر طبقة غير مستخدمة، وإلا خرجت التجربة على الهواء. لم يتغيّر شيء." -ReplyMarkup (Get-SettingsKeyboard)
            return
        }
    }
    $previous = Get-Setting $state.Name
    Set-Setting -Name $state.Name -Value $parsed
    Write-BridgeLog "User $($state.UserId) set $($state.Name) = $parsed"
    Add-AuditEntry "⚙️ $($state.Name) = $parsed - بواسطة $(Format-UserAuditActor -UserId ([long]$state.UserId))"
    Send-TelegramMessage -ChatId $ChatId -Text (Get-SettingChangeText -Name ([string]$state.Name) -From $previous -To $parsed) -ParseMode HTML -ReplyMarkup (Get-SettingsKeyboard)
}

function Reset-SettingsToDefault {
    <#
        Asks first, because this is the one button that rewrites every
        setting at once. Every sibling - clear the log, revoke access,
        restore a backup, delete a template - stops to confirm; this one
        overwrote the news file path, the sheet URL and every threshold on a
        single mistap, and said so only afterwards.

        The question names what would actually be undone: how many settings
        differ from their defaults, and the first few by name.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [switch]$Confirmed)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $Confirmed) {
        $values = @{}
        foreach ($name in $script:DefaultSettings.Keys) { $values[$name] = Get-Setting $name }
        $modified = @(Get-ModifiedBridgeSettings -Schema $script:SettingSchema -Values $values)
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('<b>♻️ استعادة كل الإعدادات الافتراضية؟</b>')
        if ($modified.Count -eq 0) {
            $lines.Add('<i>لا إعداد يخالف الافتراضي الآن، فلن يتغيّر شيء.</i>')
        }
        else {
            $lines.Add("<i>$($modified.Count) إعدادًا ستعود إلى قيمتها الأصلية:</i>")
            $lines.Add('')
            foreach ($line in @(Get-SettingsExplainedLines -Names @($modified | Select-Object -First 8 | ForEach-Object { [string]$_.Name }))) {
                $lines.Add($line)
            }
            if ($modified.Count -gt 8) { $lines.Add("… و$($modified.Count - 8) غيرها.") }
        }
        $lines.Add('')
        $lines.Add('تُحفظ نسخة من الإعدادات الحالية قبل الكتابة، وتجدها في 🗄 نسخ الإعدادات.')
        Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup (Get-SettingsResetConfirmKeyboard)
        return
    }
    $settings = [pscustomobject]@{}
    foreach ($name in $script:DefaultSettings.Keys) {
        $settings | Add-Member -NotePropertyName $name -NotePropertyValue $script:DefaultSettings[$name] -Force
    }
    $config | Add-Member -NotePropertyName 'Settings' -NotePropertyValue $settings -Force
    Save-Config
    Write-BridgeLog "User $UserId reset all settings to defaults" "WARN"
    Add-AuditEntry "♻️ استعادة الإعدادات الافتراضية - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "♻️ تمت استعادة جميع الإعدادات الافتراضية." -ReplyMarkup (Get-SettingsKeyboard)
}

function Show-SettingsListScreen {
    param([Parameter(Mandatory)][ValidateSet('simple','advanced','modified','search')][string]$Mode, [int]$Page = 0, [string]$Query = '', [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    # Wrapped: a switch is a pipeline, and a pipeline hands back a single
    # match as the match itself - .Count on which throws, on the empty-search
    # screen of all places.
    $records = @(switch ($Mode) {
        'simple' { @(Get-BridgeSettingsForMode -Schema $script:SettingSchema) }
        'advanced' { @($script:SettingSchema) }
        'modified' {
            $values = @{}; foreach ($name in $script:DefaultSettings.Keys) { $values[$name] = Get-Setting $name }
            @(Get-ModifiedBridgeSettings -Schema $script:SettingSchema -Values $values)
        }
        'search' { @(Find-BridgeSettings -Schema $script:SettingSchema -Query $Query) }
    })
    $title = switch ($Mode) { 'simple' { '🧭 الإعدادات المبسطة' }; 'advanced' { '🛠 كل الإعدادات' }; 'modified' { '📝 الإعدادات المعدّلة' }; default { "🔎 نتائج البحث عن «$Query»" } }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$(ConvertTo-TelegramHtmlText -Text $title)</b>")
    if ($records.Count -eq 0) {
        # A title over an empty keyboard read as a screen that had failed to
        # load. This says the search found nothing, and where to look instead.
        $lines.Add('<i>لا إعداد يطابق. جرّب كلمة أقصر، أو افتح 📝 المعدّل فقط أو أحد الأبواب.</i>')
    }
    else {
        # The same page the keyboard is about to draw, so the lines and the
        # buttons under them are the same settings.
        $window = Get-BridgePageWindow -ItemCount $records.Count -Page $Page -PageSize 8
        $shown = @($records[$window.StartIndex..$window.EndIndex] | ForEach-Object { [string]$_.Name })
        $lines.Add("<i>$($records.Count) إعدادًا$(if ($window.PageCount -gt 1) { " · صفحة $($window.Page + 1) من $($window.PageCount)" })</i>")
        $lines.Add('')
        foreach ($line in @(Get-SettingsExplainedLines -Names $shown)) { $lines.Add($line) }
    }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup (Get-SettingsListKeyboard -Records $records -Mode $Mode -Page $Page)
}

function Start-SettingsSearch {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'settings_search'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text 'أرسل اسم الإعداد أو وصفه بالعربية:' -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-SettingsSearch {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'settings_search') { return }
    Clear-PendingState -ChatId $ChatId
    Show-SettingsListScreen -Mode search -Query $Value.Trim() -ChatId $ChatId -UserId ([long]$state.UserId)
}

function Reset-SingleSettingToDefault {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [switch]$Confirmed)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:DefaultSettings.Contains($Name)) { return }
    if (-not $Confirmed) {
        $resetLabel = [string](Get-SettingNavigationMetadata -Name $Name).Label
        $current = Get-SettingValueDisplay -Name $Name -Value (Get-Setting $Name)
        $default = Get-SettingValueDisplay -Name $Name -Value $script:DefaultSettings[$Name]
        Send-TelegramMessage -ChatId $ChatId -Text "↩️ إعادة «$resetLabel» وحده إلى الافتراضي؟`nالآن: $current`nسيصير: $default" -ReplyMarkup (Get-SingleSettingResetConfirmKeyboard -Name $Name)
        return
    }
    $previousValue = Get-Setting $Name
    Set-Setting -Name $Name -Value $script:DefaultSettings[$Name]
    Add-AuditEntry "↩️ إعادة إعداد $Name - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text (Get-SettingChangeText -Name $Name -From $previousValue -To $script:DefaultSettings[$Name]) -ParseMode HTML -ReplyMarkup (Get-SettingsKeyboard)
}

function Invoke-AdminRawCommand {
    <# /أمر <Device> <Cmd> [Op1 ...] - admin-only escape hatch for Device/Cmd
       pairs not wrapped by a dedicated command. Typed only, since Device/Cmd
       are arbitrary. Confirm values against Cinegy's Air Remote docs before
       relying on this for anything beyond graphics layers. #>
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableRawCommand')) {
        Send-TelegramMessage -ChatId $ChatId -Text "الأمر الخام معطّل من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "هذا الأمر مخصص للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $parts = $ArgText -split '\s+', 3
    if ($parts.Count -lt 2) {
        Send-TelegramMessage -ChatId $ChatId -Text "الاستخدام: /أمر Device Cmd [Op1]" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $device = $parts[0]; $cmd = $parts[1]; $op1 = if ($parts.Count -gt 2) { $parts[2] } else { "" }
    $result = Send-AirCommand -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Device $device -Cmd $cmd -Op1 $op1 -TimeoutSec (Get-AirTimeout)
    if ($result.Success) {
        Write-BridgeLog "User $UserId (admin) sent raw command Device=$device Cmd=$cmd"
        Add-AuditEntry "🛠 أمر خام $device/$cmd - بواسطة $(Format-UserAuditActor -UserId $UserId)"
        Send-TelegramMessage -ChatId $ChatId -Text "تم الإرسال: Device=$device Cmd=$cmd" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "فشل: $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
}

function Invoke-ShowCommand {
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $parts = @($ArgText -split '\|' | ForEach-Object { $_.Trim() })
    if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) {
        Send-TelegramMessage -ChatId $ChatId -Text "الاستخدام: /عرض اسم_القالب | نص الحقل الأول | ..." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $key = $parts[0]
    $fieldValues = @()
    if ($parts.Count -gt 1) { $fieldValues = @($parts[1..($parts.Count - 1)]) }

    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($key)) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب '$key' غير معروف. استخدم زر 📋 القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $fields = @($store.Map[$key].Fields)
    if ($fieldValues.Count -gt $fields.Count) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب '$key' يحتوي على $($fields.Count) حقل/حقول فقط: $($fields -join ', ')" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $limits = @($store.Map[$key].FieldLimits)
    $variables = @{}
    for ($i = 0; $i -lt $fieldValues.Count; $i++) {
        $limit = 0
        if ($i -lt $limits.Count) { $limit = [int]$limits[$i] }
        if (-not (Test-FieldLength -Value ([string]$fieldValues[$i]) -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId))) { return }
        $variables[[string]$fields[$i]] = $fieldValues[$i]
    }
    $templateIndex = Get-TemplateIndex -Key $key
    Start-ShowFlow -TemplateIndex $templateIndex -ChatId $ChatId -UserId $UserId -InitialValues $variables -ReviewImmediately
}

function Invoke-HideCommand {
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $layer = 0
    if (-not [int]::TryParse($ArgText.Trim(), [ref]$layer)) {
        Send-TelegramMessage -ChatId $ChatId -Text "اختر الطبقة:" -ReplyMarkup (Get-LayersKeyboard -Prefix 'hide')
        return
    }
    Invoke-HideLayer -Layer $layer -ChatId $ChatId -UserId $UserId | Out-Null
}

function Invoke-ExitCommand {
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $layer = 0
    if (-not [int]::TryParse($ArgText.Trim(), [ref]$layer)) {
        Send-TelegramMessage -ChatId $ChatId -Text "اختر الطبقة:" -ReplyMarkup (Get-LayersKeyboard -Prefix 'exit')
        return
    }
    Invoke-ExitLayer -Layer $layer -ChatId $ChatId -UserId $UserId
}

function Invoke-SetCommand {
    <# Pairs are pipe-separated so values may contain spaces:
       /تحديث Line1.Text=Home Team | Line2.Text=Away Team #>
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $pairs = @($ArgText -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '=' })
    if ($pairs.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "الاستخدام: /تحديث الاسم=القيمة [| الاسم٢=القيمة٢ ...]" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $values = @{}
    foreach ($pair in $pairs) {
        $idx = $pair.IndexOf('=')
        $values[$pair.Substring(0, $idx).Trim()] = $pair.Substring($idx + 1)
    }
    Invoke-SetValues -Values $values -ChatId $ChatId -UserId $UserId
}

function Invoke-UserAliasCommand {
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'هذا الخيار للمشرفين فقط.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if ($ArgText -notmatch '^\s*(\d+)\s*(.*)$') {
        Send-TelegramMessage -ChatId $ChatId -Text "الاستخدام: /alias USER_ID الاسم`nلحذف الاسم: /alias USER_ID -"
        return
    }
    $targetUserId = [long]$Matches[1]; $alias = $Matches[2].Trim()
    if ($alias -eq '-') { $alias = '' }
    if (Set-UserAlias -TargetUserId $targetUserId -Alias $alias) {
        $result = if ($alias) { "✅ تم تعيين اسم المستخدم $targetUserId إلى: $alias" } else { "✅ تم حذف الاسم المستعار للمستخدم $targetUserId" }
        Write-BridgeLog "Admin $(Get-UserDisplayName -UserId $UserId) updated alias for user $targetUserId"
        Add-AuditEntry "👤 اسم بديل للمستخدم $(Format-UserAuditActor -UserId ([long]$targetUserId)) عُدّل بواسطة $(Format-UserAuditActor -UserId $UserId)"
        Send-TelegramMessage -ChatId $ChatId -Text $result -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    else { Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذر حفظ الاسم المستعار.' }
}

function Invoke-BridgeCommand {
    <# Named Invoke-BridgeCommand rather than Invoke-Command so it does not
       shadow PowerShell's built-in remoting cmdlet. #>
    param([string]$Text, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, $From)
    if ($UserId -eq 0) { $UserId = $ChatId }

    if (-not (Test-Authorized -ChatId $ChatId -UserId $UserId)) {
        Write-BridgeLog "Rejected message from unauthorized chat $ChatId / user $UserId" "WARN"
        $queued = Request-Approval -ChatId $ChatId -UserId $UserId -From $From
        $msg = Get-UnauthorizedReplyText -ChatId $ChatId -Queued $queued
        if ($msg) { Send-TelegramMessage -ChatId $ChatId -Text $msg }
        return
    }
    Update-UserLastActivity -UserId $UserId | Out-Null

    $text = $Text.Trim()
    if ($text -notmatch '^/(\S+)\s*(.*)$') {
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل /بدء لعرض القائمة الرئيسية." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    # Telegram appends @BotName to commands in groups.
    $command = ($Matches[1] -replace '@.*$', '').ToLowerInvariant()
    $argText = $Matches[2]

    switch ($command) {
        { $_ -in @('بدء', 'start') } { Show-MainMenu -ChatId $ChatId -UserId $UserId -Intro "أهلاً! اختر من القائمة:" }
        { $_ -in @('قائمة', 'القائمة', 'menu') } { Show-MainMenu -ChatId $ChatId -UserId $UserId }
        { $_ -in @('الغاء', 'إلغاء', 'cancel') } { Show-MainMenu -ChatId $ChatId -UserId $UserId -Intro "❌ تم إلغاء أي عملية معلّقة. اختر من القائمة:" }
        { $_ -in @('مساعدة', 'help') } { Send-TelegramMessage -ChatId $ChatId -Text (Get-HelpHomeText -ChatId $ChatId -UserId $UserId) -ReplyMarkup (Get-HelpHomeKeyboard -ChatId $ChatId -UserId $UserId) -ParseMode HTML }
        { $_ -in @('الجديد', 'whatsnew') } { Send-TelegramPagedText -ChatId $ChatId -Parts (Get-WhatsNewParts) -ReplyMarkup (Get-WhatsNewKeyboard -ChatId $ChatId -UserId $UserId) -ParseMode HTML }
        { $_ -in @('digest', 'ملخص') } { Send-TelegramMessage -ChatId $ChatId -Text (Get-MissedEventsText -Hours (Get-SettingInt 'MissedEventsHours' 1)) -ParseMode HTML -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
        { $_ -like 'who*' -or $_ -like 'من *' } {
            if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { Send-TelegramMessage -ChatId $ChatId -Text 'هذا الأمر للمشرفين فقط.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
            else {
                $query = ($_ -replace '^(who|من)\s*', '').Trim()
                Send-TelegramMessage -ChatId $ChatId -Text (Get-TemplateHistoryText -Query $query) -ParseMode HTML -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
            }
        }
        { $_ -in @('stats', 'uptime', 'ارقام') } {
            if (Test-Admin -ChatId $ChatId -UserId $UserId) { Send-TelegramMessage -ChatId $ChatId -Text (Get-BridgeStatsText) -ParseMode HTML -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
            else { Send-TelegramMessage -ChatId $ChatId -Text 'هذا الأمر للمشرفين فقط.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
        }
        { $_ -in @('قوالب', 'templates') } { Invoke-TemplatesCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('عرض', 'show') } { Invoke-ShowCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        { $_ -in @('اخفاء', 'إخفاء', 'hide') } { Invoke-HideCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        { $_ -in @('اخفاءالكل', 'hideall') } { Request-HideAllConfirmation -ChatId $ChatId -UserId $UserId }
        { $_ -in @('خروج', 'exit') } { Invoke-ExitCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        { $_ -in @('تحديث', 'set') } { Invoke-SetCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        { $_ -in @('حالة', 'status') } { Invoke-StatusCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('عملياتي', 'myoperations', 'myops') } { Invoke-MyOperationsCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('صحة', 'health', 'fullstatus') } { Invoke-HealthCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('تشخيص', 'diagnostics', 'diag') } { Invoke-DiagnosticsCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('حزمةتشخيص', 'diagbundle') } { Invoke-DiagnosticBundleCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('صورة', 'snapshot') } { Start-SnapshotJob -ChatId $ChatId -UserId $UserId }
        { $_ -in @('جدولة', 'schedule') } { Send-TelegramMessage -ChatId $ChatId -Text "📅 الجدولة:" -ReplyMarkup (Get-ScheduleMenuKeyboard) }
        { $_ -in @('سجل', 'audit') } {
            if (Test-Admin -ChatId $ChatId -UserId $UserId) { Invoke-AuditCommand -ChatId $ChatId -UserId $UserId }
            else { Send-TelegramMessage -ChatId $ChatId -Text "هذا الخيار للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
        }
        { $_ -in @('اعدادات', 'إعدادات', 'settings') } {
            if (Test-Admin -ChatId $ChatId -UserId $UserId) { Show-SettingsScreen -ChatId $ChatId -UserId $UserId }
            else { Send-TelegramMessage -ChatId $ChatId -Text "هذا الخيار للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
        }
        { $_ -in @('امر', 'أمر', 'cmd') } { Invoke-AdminRawCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        default {
            # A bare template name is treated as "show this", which saves an
            # operator who knows the rundown three taps through the menus.
            # Off by default and exact-match only: a fuzzy match here would
            # put the wrong graphic on air from a typo.
            $shortcut = Resolve-TemplateShortcut -Text $command
            if ($shortcut -ge 0) { Start-ShowFlow -TemplateIndex $shortcut -ChatId $ChatId -UserId $UserId; return }
            Send-TelegramMessage -ChatId $ChatId -Text "أمر غير معروف '/$command'. استخدم الأزرار أدناه:" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        }
    }
}
