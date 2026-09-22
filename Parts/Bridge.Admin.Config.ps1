#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Configuration in and out: exporting settings, importing them with a
    reviewed comparison first, the self-test, and the template registry.

    Split out of Bridge.Admin.ps1, which had grown to 2149 lines holding five
    unrelated administrator jobs at once. Nothing moved between scopes -
    dot-sourced parts share one.
#>

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
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر تجهيز ملف الإعدادات: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-AdminToolsKeyboard)
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
    # Refused here rather than at the screen: a setting can be changed by an
    # import, by a restore, and by two screens, and a rule enforced at one
    # door is a rule with three ways round it.
    if ($script:SettingConstraints.ContainsKey($Name)) {
        $bounds = $script:SettingConstraints[$Name]
        $number = 0
        if ([int]::TryParse([string]$Value, [ref]$number)) {
            if ($null -ne $bounds.Minimum -and $number -lt [int]$bounds.Minimum) {
                throw "$Name لا يقلّ عن $($bounds.Minimum)."
            }
            if ($null -ne $bounds.Maximum -and $number -gt [int]$bounds.Maximum) {
                throw "$Name لا يزيد عن $($bounds.Maximum)."
            }
        }
    }
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
    catch { return [pscustomobject]@{ Success = $false; Error = (T 'cfg.notJson'); Changes = @() } }
    if ([string](Get-JsonProp $document 'Kind') -ne 'CinegyTelegramBridge.Settings') {
        return [pscustomobject]@{ Success = $false; Error = (T 'cfg.notOurExport'); Changes = @() }
    }
    $incoming = Get-JsonProp $document 'Settings'
    if (-not $incoming) { return [pscustomobject]@{ Success = $false; Error = (T 'cfg.noSettingsSection'); Changes = @() } }

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
            Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.identical') -ReplyMarkup (Get-AdminToolsKeyboard)
            return
        }
        $script:PendingSettingsImport = @{ Path = $staged; UserId = $UserId; Changes = @($validation.Changes) }
        # Masked by name like every other settings screen. Today nothing in`r`n        # Settings is a real credential, so this is a latch for the next one`r`n        # rather than a leak being closed - the single-setting change screen`r`n        # already masks and this one did not, and a rule enforced in one of two`r`n        # equivalent places is the rule that drifts.`r`n        $preview = @($validation.Changes | Select-Object -First 20 | ForEach-Object { "• $($_.Name): $(Protect-SettingDisplayValue -Name $_.Name -Value $_.From) ← $(Protect-SettingDisplayValue -Name $_.Name -Value $_.To)" })
        $more = if (@($validation.Changes).Count -gt 20) { "`n… و$(@($validation.Changes).Count - 20) خيارًا آخر." } else { '' }
        Send-TelegramMessage -ChatId $ChatId -Text ("⚠️ مراجعة استيراد الإعدادات — $(@($validation.Changes).Count) تغييرًا:`n" + ($preview -join "`n") + $more) `
            -ReplyMarkup @{ inline_keyboard = @(, @(
                    @{ text = (T 'cfg.apply'); callback_data = 'cfgimport:apply'; style = 'success' },
                    @{ text = (T 'common.cancel'); callback_data = 'cfgimport:cancel' })) }
    }
    catch {
        Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل استيراد الإعدادات: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-AdminToolsKeyboard)
    }
}

function Confirm-SettingsImport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [switch]$Cancel)
    $pending = $script:PendingSettingsImport
    if (-not $pending -or [long]$pending.UserId -ne $UserId) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.reviewExpired') -ReplyMarkup (Get-AdminToolsKeyboard)
        return $false
    }
    if ($Cancel) {
        $script:PendingSettingsImport = $null
        Remove-Item -LiteralPath ([string]$pending.Path) -Force -ErrorAction SilentlyContinue
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.importCancelled') -ReplyMarkup (Get-AdminToolsKeyboard)
        return $false
    }
    if (-not (Set-ImportedSettings -Changes @($pending.Changes))) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.importNotSaved') -ReplyMarkup (Get-AdminToolsKeyboard)
        return $false
    }
    $script:PendingSettingsImport = $null
    Remove-Item -LiteralPath ([string]$pending.Path) -Force -ErrorAction SilentlyContinue
    Write-BridgeLog "Admin $UserId imported $(@($pending.Changes).Count) setting(s)" 'WARN'
    Add-AuditEntry "📥 استيراد الإعدادات ($(@($pending.Changes).Count) تغييرًا) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ طُبِّق $(@($pending.Changes).Count) تغييرًا.$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-AdminToolsKeyboard)
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.noTrialLayer') -ReplyMarkup (Get-AdminToolsKeyboard)
        return $false
    }
    $conflict = @(Get-TemplateTestLayerConflict -Layer $layer)
    if ($conflict.Count -gt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ طبقة التجربة $layer مستخدمة في قوالب الإنتاج: $($conflict -join (T 'common.comma'))" -ReplyMarkup (Get-AdminToolsKeyboard)
        return $false
    }
    $store = Get-TemplateStore
    $template = if ($store.Order.Count -gt 0) { $store.Map[$store.Order[0]] } else { $null }
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.noTemplatesToCheck') -ReplyMarkup (Get-AdminToolsKeyboard)
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
        & $record (T 'cfg.layerReady') $false (T 'cfg.layerBusy')
        Send-TelegramMessage -ChatId $ChatId -Text ((T 'cfg.pathCheckFailedNl') + ($steps -join "`n")) -ReplyMarkup (Get-AdminToolsKeyboard)
        return $false
    }

    $variables = @{}
    foreach ($field in @($template.Fields)) { $variables[[string]$field] = 'SELF-TEST' }
    try {
        $show = Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $layer -TemplatePath ([string]$template.Path) -Variables $variables -Types @{} `
            -DefaultType ([string](Get-Setting 'AirVariableType')) -TimeoutSec $timeout
        & $record (T 'cfg.sendShow') ([bool]$show.Success) $(if ($show.Success) { '' } else { [string]$show.Error })

        if ($show.Success) {
            $afterShow = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $monitorTimeout
            & $record (T 'cfg.cinegyConfirms') ([bool]$afterShow.Success -and [bool]$afterShow.IsOnAir) ''

            $exit = Exit-TitlerScene -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $timeout
            & $record (T 'cfg.sendExit') ([bool]$exit.Success) $(if ($exit.Success) { '' } else { [string]$exit.Error })
        }
    }
    finally {
        # HIDE regardless: EXIT alone can leave the item Active, and a failed
        # run must never leave the test layer occupied.
        $hide = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $timeout
        & $record (T 'cfg.cleanLayer') ([bool]$hide.Success) $(if ($hide.Success) { '' } else { [string]$hide.Error })
        Remove-OnAirRecord -Layer $layer -Reason 'self-test cleanup' | Out-Null
        $final = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer -TimeoutSec $monitorTimeout
        & $record (T 'cfg.layerEmptyAfter') ([bool]$final.Success -and -not [bool]$final.IsOnAir) ''
    }

    $failed = [bool]$script:BridgeSelfTestFailed
    $header = if ($failed) { (T 'cfg.pathCheckFailed') } else { (T 'cfg.pathCheckPassed') }
    Write-BridgeLog "Live self-test on layer $layer by user ${UserId}: $(if ($failed) { 'FAILED' } else { 'passed' })" $(if ($failed) { 'WARN' } else { 'INFO' })
    Add-AuditEntry "🧪 فحص المسار الحي على طبقة $layer - $(if ($failed) { (T 'cfg.failed') } else { (T 'cfg.passed') }) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text ("$header`n" + ($steps -join "`n")) -ReplyMarkup (Get-AdminToolsKeyboard)
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.templateChanged') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
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
    Send-TelegramMessage -ChatId $ChatId -Text "✅ بدأ اختبار '$($template.Key)' على طبقة التجربة $testLayer وسيُخفى خلال $(Get-ArabicCountNoun -Count $seconds -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية' -EnglishOne 'second' -EnglishMany 'seconds')." -ReplyMarkup (Get-AfterShowKeyboard -Layer $testLayer -ChatId $ChatId -UserId $UserId)
}

function Test-TemplateRegistryImport {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $rawText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([Text.Encoding]::UTF8.GetByteCount($rawText) -gt $script:TemplateRegistryImportMaximumBytes) { throw (T 'cfg.fileTooBig') }
        $document = $rawText | ConvertFrom-Json -ErrorAction Stop
        $properties = @($document.PSObject.Properties)
        $maximumTemplates = Get-SettingInt 'TemplateRegistryImportMaxTemplates' 1
        if ($properties.Count -eq 0 -or $properties.Count -gt $maximumTemplates) { throw "يجب أن يحتوي السجل بين قالب واحد و$(Get-ArabicCountNoun -Count $maximumTemplates -One 'قالب' -Two 'قالبان' -Few 'قوالب' -Many 'قالبًا' -EnglishOne 'template' -EnglishMany 'templates')." }
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.enableFullTemplates') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_import_upload'; UserId=$UserId }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.sendJsonFile') -ReplyMarkup (Get-CancelKeyboard)
}

function Invoke-TemplateRegistryExport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return }
    $path = Get-TemplateRegistryFilePath
    if (Send-TelegramDocument -ChatId $ChatId -FilePath $path -Caption (T 'cfg.exportNote')) {
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.uploadJsonSize') -ReplyMarkup (Get-CancelKeyboard)
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
            , @((New-Button (T 'cfg.approveImport') 'timport:confirm' -Style success), (New-Button (T 'common.cancel') 'menu:templatesadmin'))
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
        if ($blocked.Count -gt 0) { throw "لا يمكن تغيير أو حذف قالب مستخدم على الهواء أو في جدولة قادمة: $($blocked -join (T 'common.comma'))" }
        $backupPath = Backup-TemplateRegistryFile -Path $path
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'cfg.importedTemplates') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
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
    # Two lists that are meant to agree, and nothing checked that they did:
    # an administrator with authority and no notices approved nothing because
    # he was never asked, while the request was decided by someone else in a
    # minute. It is silent by nature - the missing person cannot notice what
    # never reaches them - so the screen has to say it.
    $mismatch = Get-AdminListMismatch
    if (@($mismatch.Unnotified).Count -gt 0) {
        $warnings.Add("⚠️ مشرفون بلا إشعارات (في AdminUserIds لا AdminChatIds): $(@($mismatch.Unnotified) -join (T 'common.comma'))")
    }
    if (@($mismatch.Unauthorized).Count -gt 0) {
        $warnings.Add("⚠️ يصلهم إشعار المشرفين بلا صلاحية مشرف: $(@($mismatch.Unauthorized) -join (T 'common.comma'))")
    }
    return $warnings.ToArray()
}
