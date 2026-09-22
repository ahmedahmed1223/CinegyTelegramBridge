#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    The template administrator surface: the create wizard, the reminder
    minutes, and reviewing a definition before it is written.

    Split out of Bridge.Admin.ps1, which had grown to 2149 lines holding five
    unrelated administrator jobs at once. Nothing moved between scopes -
    dot-sourced parts share one.
#>

function Complete-TemplateReminderMinutes {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'template_reminder_minutes' -or [long]$state.UserId -ne $UserId) { return }
    if (-not (Test-TemplateReminderManager -ChatId $ChatId -UserId $UserId)) {
        Clear-PendingState -ChatId $ChatId
        Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.alertRightLost') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $minutes = -1
    if (-not [int]::TryParse($Value.Trim(), [ref]$minutes) -or $minutes -lt 0 -or $minutes -gt 1440) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.sendMinutes') -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $template = Get-TemplateByIndex -Index ([int]$state.TemplateIndex)
    if (-not $template -or [string]$template.Key -ne [string]$state.TemplateKey) { Clear-PendingState -ChatId $ChatId; Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.templateChanged') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $ChatId -UserId $UserId); return }
    if ([bool](Get-JsonProp $template 'LongRunning')) { Clear-PendingState -ChatId $ChatId; Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.nowLongRun') -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $UserId); return }
    $result = Save-TemplateReminderMinutes -TemplateKey ([string]$state.TemplateKey) -Minutes $minutes
    Clear-PendingState -ChatId $ChatId
    if (-not $result.Success) { Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ تنبيه القالب: $($result.Error)" -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $UserId); return }
    $minutesText = Get-ArabicCountNoun -Count $minutes -One 'دقيقة' -Two 'دقيقتان' -Few 'دقائق' -Many 'دقيقة' -EnglishOne 'minute' -EnglishMany 'minutes'
    Add-AuditEntry "🔔 ضبط تنبيه ظهور $($state.TemplateKey) على $minutesText - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    $message = if ($minutes -eq 0) { (T 'atpl.alertStopped') } else { "✅ تم ضبط تنبيه الظهور بعد $minutesText." }
    Send-TelegramMessage -ChatId $ChatId -Text $message -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $UserId)
}

function Show-InvalidTemplatesScreen {
    <#
        D2: the "skipped" warning as a work list. Every invalid registry entry
        with the reason it was skipped and a delete button beside it - the
        deletion reuses Save-TemplateDefinitionChange, so its guards (on air,
        scheduled) and its backup apply unchanged.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $entries = @(Get-InvalidTemplateEntries)
    $back = @{ inline_keyboard = @(, @((New-Button (T 'templates.back') 'menu:templatesadmin'))) }
    if ($entries.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.noInvalidTemplates') -ReplyMarkup $back
        return
    }
    # Paged like every keyboard built from a growing collection. The delete
    # index stays global over the full list (not per page): ask/go re-resolve
    # it live, so a page turn between taps still lands on the right entry.
    $window = Get-BridgePageWindow -ItemCount $entries.Count -Page $Page -PageSize 5
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>🧹 قوالب غير صالحة ($($entries.Count))</b>")
    $lines.Add((T 'atpl.skippedNote'))
    $rows = @()
    foreach ($i in $window.StartIndex..$window.EndIndex) {
        $lines.Add("• <b>$(ConvertTo-TelegramHtmlText $entries[$i].Key)</b> — $(ConvertTo-TelegramHtmlText $entries[$i].Reason)")
        $rows += , @((New-Button "🗑 حذف $($entries[$i].Key)" "tplinv:ask:$i"))
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'common.previous') "tplinv:page:$($window.Page - 1)") }
        if ($window.HasNext) { $pager += (New-Button (T 'common.next') "tplinv:page:$($window.Page + 1)") }
        $rows += , $pager
    }
    $rows += , @((New-Button (T 'templates.back') 'menu:templatesadmin'))
    Send-TelegramPagedText -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup @{ inline_keyboard = $rows } -ParseMode HTML
}

function Start-TemplateDefinitionPrompt {
    param([Parameter(Mandatory)][ValidateSet('create', 'edit', 'delete')][string]$Action, [int]$TemplateIndex = -1, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Get-Setting 'EnableFullTemplateManagement')) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.fullControlOff') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $template = if ($TemplateIndex -ge 0) { Get-TemplateByIndex -Index $TemplateIndex } else { $null }
    if ($Action -ne 'create' -and -not $template) { Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.templateGone') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard); return }
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.fullControlOff') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_create_key'; Definition=@{}; UserId=$UserId }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.add1') -ReplyMarkup (Get-CancelKeyboard)
}

function Get-TemplateWizardLayerPrompt {
    (T 'atpl.add3')
}

function Get-TemplateWizardFieldsPrompt {
    (T 'atpl.add4')
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
    $lines.Add("الحقول: $(if ($fields.Count -gt 0) { $fields -join (T 'common.comma') } else { (T 'atpl.noFields') })")
    $lines.Add("الوصف: $(& $read 'description' (T 'atpl.noDescription'))")
    $lines.Add("التصنيف: $(& $read 'category' (T 'atpl.uncategorised'))")
    $lines.Add('')
    $lines.Add((T 'atpl.nothingSavedYet'))
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
                Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.badKey') -ReplyMarkup (Get-CancelKeyboard); return
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
                Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.noPendingPath') -ReplyMarkup (Get-CancelKeyboard); return
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
                Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.needCintitle') -ReplyMarkup (Get-CancelKeyboard); return
            }
            $resolved = Resolve-TemplateScenePath -Path $trimmed
            if (-not [IO.Path]::IsPathRooted($resolved)) {
                Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.needFullPath') -ReplyMarkup (Get-CancelKeyboard); return
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
                $warning = if ($used.Count -gt 0) { "`n⚠️ الطبقة $layer يستخدمها أيضًا: $($used -join (T 'common.comma'))" } else { '' }
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
            Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.needLayerOrDevice') -ReplyMarkup (Get-CancelKeyboard)
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
            Send-TelegramMessage -ChatId $ChatId -Text ((T 'atpl.add5') +
                (T 'atpl.add5Example')) -ReplyMarkup (Get-CancelKeyboard)
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
        [string]$oldJson = if ($Existing) { Get-JsonProp $Existing $name | ConvertTo-Json -Depth 10 -Compress } else { (T 'atpl.missing') }
        [string]$newJson = $Definition[$name] | ConvertTo-Json -Depth 10 -Compress
        if ([string]::IsNullOrEmpty($oldJson)) { $oldJson = 'null' }
        if ([string]::IsNullOrEmpty($newJson)) { $newJson = 'null' }
        if ($oldJson -ne $newJson) {
            $oldDisplay = if ($oldJson.Length -gt 120) { $oldJson.Substring(0,117) + '...' } else { $oldJson }
            $newDisplay = if ($newJson.Length -gt 120) { $newJson.Substring(0,117) + '...' } else { $newJson }
            $lines.Add("• $name`n  قبل: $oldDisplay`n  بعد: $newDisplay")
        }
    }
    if ($lines.Count -eq 0) { return (T 'atpl.noRealChanges') }
    return "الاختلافات:`n$($lines -join "`n")"
}

function Complete-TemplateDefinitionJson {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'template_definition_json') { return }
    try { $definition = $Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.badJson') -ReplyMarkup (Get-CancelKeyboard); return }
    $key = [string]$state.TemplateKey
    if ($state.Action -eq 'create') { $key = [string](Get-JsonProp $definition 'key'); $definition.Remove('key') }
    if ([string]::IsNullOrWhiteSpace($key)) { Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.needKey') -ReplyMarkup (Get-CancelKeyboard); return }
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
    if ($result.Success) { Add-AuditEntry "📚 $($state.Action) قالب $($state.TemplateKey) - بواسطة $(Format-UserAuditActor -UserId $UserId)"; Send-TelegramMessage -ChatId $ChatId -Text (T 'atpl.savedWithBackup') -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
    else { Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ القالب: $($result.Error)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
}
