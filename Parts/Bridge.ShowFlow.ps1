#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-LayerLockNotice {
    <#
        Describes an editing lock held by someone else: who, and for how long.

        The raw owner id told an operator nothing they could act on. Two people
        on the same channel - one on a phone, one at the desk - hit this
        routinely, and "المستخدم 7275359265" does not tell you whether to wait
        or to call across the room. Returns '' when the layer is free or held
        by the asker themselves.
    #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$UserId)
    if (-not $script:LayerLocks.ContainsKey($Layer)) { return '' }
    $lock = $script:LayerLocks[$Layer]
    if ([long]$lock.UserId -eq $UserId) { return '' }
    $held = if ($lock.StartedAt -is [datetime]) { Format-Duration -Seconds ([int]((Get-Date) - $lock.StartedAt).TotalSeconds) } else { 'فترة' }
    return "⚠️ $(Get-UserDisplayName -UserId ([long]$lock.UserId)) يجهّز '$($lock.Key)' على الطبقة $Layer منذ $held."
}

function Lock-GfxLayer {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][string]$Key
    )
    if ($script:LayerLocks.ContainsKey($Layer)) {
        $existing = $script:LayerLocks[$Layer]
        if ([long]$existing.ChatId -ne $ChatId -or [long]$existing.UserId -ne $UserId) {
            return [pscustomobject]@{
                Success = $false
                OwnerChatId = [long]$existing.ChatId
                OwnerUserId = [long]$existing.UserId
                Key = [string]$existing.Key
            }
        }
    }
    $script:LayerLocks[$Layer] = @{
        ChatId = $ChatId; UserId = $UserId; Key = $Key; StartedAt = (Get-Date)
    }
    return [pscustomobject]@{ Success = $true; OwnerChatId = $ChatId; OwnerUserId = $UserId; Key = $Key }
}

function Unlock-GfxLayer {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Layer = 0)
    foreach ($candidate in @($script:LayerLocks.Keys)) {
        if (($Layer -le 0 -or [int]$candidate -eq $Layer) -and [long]$script:LayerLocks[$candidate].ChatId -eq $ChatId) {
            $script:LayerLocks.Remove($candidate)
        }
    }
}

function Set-PendingState {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    Set-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId -State $State
    if ([string]$State.Mode -in @('show_fields', 'show_review')) { Save-DraftStates }
}

function Get-PendingState {
    <# Returns the pending flow for a chat, or $null if there is none or it has
       aged out. Expiry is checked on read as well as on the tick so a stale
       entry can never be consumed. #>
    param([Parameter(Mandatory)][long]$ChatId)
    $timeout = Get-SettingInt 'PendingStateTimeoutMinutes' 1
    $result=Get-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId -TimeoutMinutes $timeout
    if (-not $result.State) { return $null }
    if ($result.Expired) {
        Complete-PendingStateCleanup -ChatId $ChatId -State $result.State
        return $null
    }
    return $result.State
}

function Complete-PendingStateCleanup {
    param([Parameter(Mandatory)][long]$ChatId,[Parameter(Mandatory)][hashtable]$State)
    if ($State.ContainsKey('LockLayer')) { Unlock-GfxLayer -ChatId $ChatId -Layer ([int]$State.LockLayer) }
    if ($State.ContainsKey('ImportStagedPath') -and (Test-Path -LiteralPath ([string]$State.ImportStagedPath))) {
        Remove-Item -LiteralPath ([string]$State.ImportStagedPath) -Force -ErrorAction SilentlyContinue
    }
    if ([string]$State.Mode -in @('show_fields', 'show_review')) { Save-DraftStates }
}

function Clear-PendingState {
    param([Parameter(Mandatory)][long]$ChatId)
    $state=Remove-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId
    if ($state) { Complete-PendingStateCleanup -ChatId $ChatId -State $state }
    # The moment they finished is the moment anything held for them is worth
    # reading. Here rather than at each of the dozen places a flow can end,
    # because this is the one they all pass through.
    Send-HeldAirNotices -ChatId $ChatId | Out-Null
}

function Clear-PendingStatesForUser {
    param([Parameter(Mandatory)][long]$UserId)
    foreach ($entry in @($script:PendingState.GetEnumerator())) {
        if ([long](Get-JsonProp $entry.Value 'UserId') -eq $UserId) {
            Clear-PendingState -ChatId ([long]$entry.Key)
        }
    }
}

function Test-PendingStateAdmission {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if ([long](Get-JsonProp $State 'UserId') -ne $UserId) { return $false }
    $mode = [string](Get-JsonProp $State 'Mode')
    if ($mode -in @('access_request_name', 'join_secret', 'announcement_text')) { return $true }
    if (-not (Test-Authorized -ChatId $ChatId -UserId $UserId)) { return $false }
    $adminModes = @('setting_value','setting_text','settings_search','stream_url','layer_name','user_alias_edit','template_definition_json','preset_admin_name','preset_admin_values')
    # The wizard is matched by prefix rather than listed: template_create_ has
    # four steps, and a fifth would have been added to the switch that consumes
    # them without anyone remembering this list. Its sibling that edits the same
    # definitions as raw JSON was here from the start; the wizard that writes
    # them a field at a time was not.
    if (($mode -in $adminModes -or $mode -like 'template_create_*') -and -not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $false }
    return $true
}


function Start-ShowFlow {
    <# Entry point for every SHOW source. ReviewImmediately is used when values
       already came from a preset or typed command; required missing fields
       still force the ordinary field-entry flow. #>
    param(
        [Parameter(Mandatory)][int]$TemplateIndex,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [int]$AutoHideSeconds = 0,
        [hashtable]$InitialValues = @{},
        [switch]$ReviewImmediately
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    $t = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $t) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب غير معروف (ربما تغيّر ملف القوالب). افتح 📋 القوالب من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $policy = Test-TemplateShowPolicy -Key ([string]$t.Key) -Layer ([int]$t.Layer) -IsAdmin:(Test-Admin -ChatId $ChatId -UserId $UserId)
    if (-not $policy.Allowed) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لا يمكن تجهيز العرض: $($policy.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $AutoHideSeconds = Get-EffectiveAutoHideSeconds -Key ([string]$t.Key) -RequestedSeconds $AutoHideSeconds
    $lock = Lock-GfxLayer -Layer ([int]$t.Layer) -ChatId $ChatId -UserId $UserId -Key ([string]$t.Key)
    if (-not $lock.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "$(Get-LayerLockNotice -Layer ([int]$t.Layer) -UserId $UserId)`nانتظر أو اختر قالبًا على طبقة أخرى." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $replacementContext = Get-LayerShowContext -Layer ([int]$t.Layer)
    $draftValues = @{}
    foreach ($name in $InitialValues.Keys) { $draftValues[[string]$name] = [string]$InitialValues[$name] }
    $required = @(Get-JsonProp $t 'FieldRequired' | Where-Object { $null -ne $_ })
    $canReviewImmediately = [bool]$ReviewImmediately
    if ($canReviewImmediately) {
        for ($i = 0; $i -lt $t.Fields.Count; $i++) {
            if ($i -lt $required.Count -and [bool]$required[$i]) {
                $fieldName = [string]$t.Fields[$i]
                if (-not $draftValues.ContainsKey($fieldName) -or [string]::IsNullOrWhiteSpace([string]$draftValues[$fieldName])) {
                    $canReviewImmediately = $false
                    break
                }
            }
        }
    }
    if ($t.Fields.Count -eq 0 -or $canReviewImmediately) {
        $state = @{
            Mode = 'show_review'; Key = $t.Key; Fields = @($t.Fields); Labels = @($t.FieldLabels)
            Limits = @($t.FieldLimits); Required = $required
            Sensitives = @(Get-JsonProp $t 'FieldSensitive' | Where-Object { $null -ne $_ })
            Index = 0; Values = $draftValues; UserId = $UserId; AutoHideSeconds = $AutoHideSeconds
            LockLayer = [int]$t.Layer; ReplacementContext = $replacementContext
        }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text (Format-ShowReviewText -State $state) -ParseMode HTML -ReplyMarkup (Get-ShowReviewKeyboard -HasFields)
        return
    }
    $state = @{
        Mode = 'show_fields'; Key = $t.Key; Fields = @($t.Fields); Labels = @($t.FieldLabels)
        Limits = @($t.FieldLimits)
        Required = $required
        Sensitives = @(Get-JsonProp $t 'FieldSensitive' | Where-Object { $null -ne $_ })
        Index = 0; Values = $draftValues; UserId = $UserId; AutoHideSeconds = $AutoHideSeconds
        LockLayer = [int]$t.Layer; ReplacementContext = $replacementContext
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text (Get-FieldPromptText -State $state) -ParseMode HTML -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
}

function Resume-ShowFlow {
    <# Called for each text reply (or the ⏭ skip button) while a show_fields
       flow is pending. Advances one field, or fires the template once full.

       -Skip omits the field from the variable set entirely rather than sending
       an empty string, so the scene keeps whatever text it was designed with
       instead of being blanked. #>
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "", [switch]$Skip)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $isRequired = $state.Required -and $state.Index -lt @($state.Required).Count -and [bool]$state.Required[$state.Index]
    if ($isRequired -and ($Skip -or [string]::IsNullOrWhiteSpace($Value))) {
        $message = if ($Skip) { "❌ هذا الحقل مطلوب ولا يمكن تخطيه." } else { "❌ هذا الحقل مطلوب ولا يمكن تركه فارغًا." }
        Send-TelegramMessage -ChatId $ChatId -Text $message -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
        return
    }
    if (-not $Skip) {
        # Re-prompt rather than push oversized text: a pasted paragraph would
        # otherwise go straight to air and wreck the graphic's layout.
        $limit = 0
        if ($state.Limits -and $state.Index -lt @($state.Limits).Count) { $limit = [int]$state.Limits[$state.Index] }
        if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-FieldPromptKeyboard -State $state))) { return }
        $fieldName = [string]$state.Fields[$state.Index]
        $state.Values[$fieldName] = $Value
        $isSensitive = Test-SensitiveFieldName -FieldName $fieldName
        if ($state.ContainsKey('Sensitives') -and $state.Index -lt @($state.Sensitives).Count) {
            $isSensitive = $isSensitive -or [bool]$state.Sensitives[$state.Index]
        }
        Add-RecentFieldValue -UserId ([long]$state.UserId) -FieldName $fieldName -Value $Value -Sensitive:$isSensitive
    }
    $state.Index++

    if ($state.Index -ge $state.Fields.Count) {
        $state.Mode = 'show_review'
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text (Format-ShowReviewText -State $state) -ParseMode HTML -ReplyMarkup (Get-ShowReviewKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text (Get-FieldPromptText -State $state) -ParseMode HTML -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
}

function Format-ShowReviewText {
    param([Parameter(Mandatory)][hashtable]$State)
    $lines = [System.Collections.Generic.List[string]]::new()
    # parse_mode=HTML, and one rule runs through it: anything that will
    # appear on the television is a <code> span. Nothing else on this screen
    # is, so the copy about to go out is unmistakable from the labels
    # describing it - on the one screen where an operator is deciding whether
    # to put it on air. Telegram has no text colour for a bot to use; a
    # monospace span is the strongest distinction it does have, and it is
    # tap-to-copy as well.
    $lines.Add("<b>🔎 مراجعة قبل الإرسال</b>")
    $lines.Add("القالب: <b>$(ConvertTo-TelegramHtmlText ([string]$State.Key))</b> · الطبقة <code>$($State.LockLayer)</code>")
    $context = Get-JsonProp $State 'ReplacementContext'
    if ($context -and -not [bool](Get-JsonProp $context 'IsKnown')) {
        $lines.Add("<b>⚠️ تعذّر التحقق من حداثة حالة الطبقة</b>؛ راجع شاشة الحالة قبل التأكيد عند الشك.")
    }
    if ($context -and [bool](Get-JsonProp $context 'IsOnAir')) {
        $currentKey = [string](Get-JsonProp $context 'Key')
        if ([string]::IsNullOrWhiteSpace($currentKey)) { $currentKey = 'مشهد غير مسمّى' }
        $currentUserId = [long](Get-JsonProp $context 'UserId')
        $sourceText = if ([string](Get-JsonProp $context 'Source') -eq 'cinegy') { 'Cinegy Air' } elseif ($currentUserId -gt 0) { "المستخدم $(Get-UserDisplayName -UserId $currentUserId)" } else { 'Bot' }
        $lines.Add("<b>⚠️ سيتم استبدال القالب الحالي</b>: $(ConvertTo-TelegramHtmlText $currentKey) ($(ConvertTo-TelegramHtmlText $sourceText))")
    }
    # A structural clash, distinct from the runtime one above: these templates
    # can never be on air together, whether or not the layer is busy right now.
    $sharedLayers = Get-JsonProp (Get-TemplateStore) 'SharedLayers'
    $layerKey = [string]$State.LockLayer
    if ($sharedLayers -and $sharedLayers.Contains($layerKey)) {
        $siblings = @(@($sharedLayers[$layerKey]) | Where-Object { $_ -ne [string]$State.Key })
        if ($siblings.Count -gt 0) {
            $lines.Add("<b>⚠️ هذه الطبقة يتشاركها أيضًا</b>: $(ConvertTo-TelegramHtmlText ($siblings -join '، ')) — لا يمكن عرضها مع هذا القالب في الوقت نفسه.")
        }
    }
    if ($State.AutoHideSeconds -gt 0) { $lines.Add("الإخفاء التلقائي: <code>$($State.AutoHideSeconds)</code> ثانية") }
    $lines.Add("")
    $lines.Add("📺 <b>ما سيظهر على الشاشة:</b>")
    for ($i = 0; $i -lt @($State.Fields).Count; $i++) {
        $name = [string]$State.Fields[$i]
        $label = $name
        if ($State.Labels -and $i -lt @($State.Labels).Count -and $State.Labels[$i]) { $label = [string]$State.Labels[$i] }
        # A left field is not on-air copy, so it is not dressed as any: it
        # says so in italics rather than sitting in a code span pretending to
        # be text that will appear.
        if ($State.Values.ContainsKey($name)) {
            $lines.Add("$(ConvertTo-TelegramHtmlText $label):`n<code>$(ConvertTo-TelegramHtmlText ([string]$State.Values[$name]))</code>")
        }
        else {
            $lines.Add("$(ConvertTo-TelegramHtmlText $label): <i>(متروك)</i>")
        }
    }
    $lines.Add("")
    $lines.Add("<i>لن يُرسل شيء إلى Cinegy حتى تضغط تأكيد الإرسال.</i>")
    return ($lines -join "`n")
}

function Get-EffectiveFieldLimit {
    <# Resolution order: per-field maxLength -> per-template maxLength -> the
       global MaxFieldLength setting. A graphic's usable text length depends on
       its design, so one global number is a floor, not the whole answer. #>
    param([int]$FieldLimit = 0)
    if ($FieldLimit -gt 0) { return $FieldLimit }
    return (Get-SettingInt 'MaxFieldLength' 0)
}

function Test-FieldLength {
    <# Returns $true when the text is short enough to put on air, otherwise
       tells the operator and returns $false. The pending flow is deliberately
       left intact so they can simply retype the value. #>
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][long]$ChatId,
        [int]$FieldLimit = 0,
        [hashtable]$ReplyMarkup
    )
    $max = Get-EffectiveFieldLimit -FieldLimit $FieldLimit
    $visibleLength = Get-TextElementCount -Text $Value
    if ($max -le 0 -or $visibleLength -le $max) { return $true }
    if (-not $ReplyMarkup) { $ReplyMarkup = Get-FieldPromptKeyboard }
    Send-TelegramMessage -ChatId $ChatId -Text "❌ النص طويل جدًا ($visibleLength حرفًا) والحد الأقصى $max حرفًا. أرسل نصًا أقصر." -ReplyMarkup $ReplyMarkup
    return $false
}

function Get-FieldPromptText {
    <# Shows the operator-friendly label when templates.json provides one,
       falling back to the raw variable name (e.g. "Ajel.center") otherwise. #>
    param([Parameter(Mandatory)][hashtable]$State)
    $index = [int]$State.Index
    $name = [string]$State.Fields[$index]
    $label = $name
    if ($State.Labels -and $index -lt @($State.Labels).Count -and $State.Labels[$index]) {
        $label = "$($State.Labels[$index])`n($name)"
    }
    # Tell the operator the limit up front rather than rejecting after typing.
    $limit = 0
    if ($State.Limits -and $index -lt @($State.Limits).Count) { $limit = [int]$State.Limits[$index] }
    $limit = Get-EffectiveFieldLimit -FieldLimit $limit
    # parse_mode=HTML. Four lines, in the order the question is actually
    # asked: which template, how far through, what this field is, and what to
    # do about it.
    #
    # The last line is the one that was missing. Every other screen in the
    # bridge answers a button press with more buttons, so an operator who has
    # just pressed one waits for the next - and this is the single screen that
    # wants typing instead. It said "أرسل نص الحقل" inside a sentence about the
    # template and left the rest implied.
    #
    # Progress is drawn rather than counted: ▰▰▱ is read without arithmetic,
    # and "2/3" beside it stays for anyone who wants the number. Capped so a
    # template with twenty fields cannot draw a bar wider than the screen.
    $total = @($State.Fields).Count
    $step = $index + 1
    $bar = if ($total -gt 0 -and $total -le 12) {
        ('▰' * $step) + ('▱' * [math]::Max(0, $total - $step))
    }
    else { '' }
    $progress = if ($bar) { "$bar  $step/$total" } else { "$step/$total" }

    # Template key, label and variable name all come from templates.json, which
    # an administrator writes by hand, so all three are escaped.
    #
    # The label is what the operator reads; the raw variable name under it is
    # <code>, because it is a Titler identifier like "Ajel.center" and
    # monospace is what says "the machine's name for this, not a label".
    $shownLabel = if ($label -eq $name) {
        "✏️ <b>$(ConvertTo-TelegramHtmlText $name)</b>"
    }
    else {
        "✏️ <b>$(ConvertTo-TelegramHtmlText ([string]$State.Labels[$index]))</b>`n     <code>$(ConvertTo-TelegramHtmlText $name)</code>"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("📋 <b>$(ConvertTo-TelegramHtmlText ([string]$State.Key))</b>")
    $lines.Add("<i>$progress</i>")
    $lines.Add('')
    $lines.Add($shownLabel)
    if ($limit -gt 0) { $lines.Add("     <i>الحد: $limit حرفًا</i>") }
    $lines.Add('')
    $lines.Add('⌨️ <b>اكتب النص في صندوق الرسالة بالأسفل وأرسله.</b>')
    return ($lines -join "`n")
}

function Sync-LayerAfterOperatorAction {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][string]$Reason)
    $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    return Update-OnAirStateFromCinegy -Reason $Reason -LayerStatuses @($status) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
}

function Invoke-HideLayer {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [switch]$Quiet,
        [switch]$MaintenanceOverride
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext -Action HIDE -Layer $Layer -UserId $UserId
    # Read before anything runs: the operation clears the layer, and the
    # answer to "what did I just take down" is only available beforehand.
    $outgoing = if ($script:OnAir.ContainsKey($Layer)) { $script:OnAir[$Layer] } else { $null }
    $outgoingKey = if ($outgoing) { [string](Get-JsonProp $outgoing 'Key') } else { '' }
    $outgoingCopy = if ($outgoing) { [string](Get-JsonProp $outgoing 'AirCopy') } else { '' }
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId -EmergencyOverride:$MaintenanceOverride)) {
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -Target $outgoingKey -Values $outgoingCopy -ErrorText 'maintenance mode'
        return $false
    }
    # A bulletin walking this layer has to stop with it, or it keeps writing
    # rows into a scene nobody can see.
    # After the gate, not before it. A blocked HIDE sends nothing to Cinegy,
    # so a bulletin stopped here was stopped for an operation that never
    # happened - recorded as finished, ticker recalled, scene possibly still
    # walking rows on air.
    Stop-MojazForLayer -Layer $Layer | Out-Null
    $rollbackSnapshot = $null
    if (-not $Quiet -and (Get-Setting 'EnableSafeRollback')) {
        $preHideStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $rollbackSnapshot = Get-CorrelatedLayerSnapshot -Layer $Layer -LiveStatus $preHideStatus
    }
    Start-AirOperation -Operation $operation -Action HIDE -Layer $Layer -UserId $UserId
    $result = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-AirTimeout)
    if ($result.Success) {
        if ($rollbackSnapshot) { Set-RollbackCandidate -Layer $Layer -RestoreSnapshot $rollbackSnapshot -ExpectedState hidden -ActorUserId $UserId }
        Sync-LayerAfterOperatorAction -Layer $Layer -Reason 'after-hide' | Out-Null
        $actor = Format-UserAuditActor -UserId $UserId
        Write-BridgeLog "User $actor hid layer $Layer"
        Add-AuditEntry "🙈 إخفاء طبقة $Layer - بواسطة $actor"
        # The room is told a graphic came off for the same reason it is told
        # one went on: what is on screen changed. Sent even for a quiet hide -
        # an auto-hide timer taking a strap down is exactly the change nobody
        # in the gallery watched happen.
        Send-TemplateAirNotice -Key $outgoingKey -Layer $Layer -ActorChatId $ChatId -ActorName $actor `
            -Copy $outgoingCopy -Action hide -OnAirSince (Get-JsonProp $outgoing 'At') | Out-Null
        # Said as it is, not as it was asked for. Cinegy accepted the HIDE, but
        # the read-back that follows can fail, and the record is deliberately
        # kept when it does - losing track of a graphic that may still be on
        # screen is the worse mistake. That left the operator holding two
        # answers at once: "✅ hidden" over a keyboard still offering
        # "🔴 hide layer 7", which reads as a bug in the bridge rather than as
        # what it is, an unconfirmed state.
        if (-not $Quiet) {
            $unconfirmed = $script:OnAir.ContainsKey($Layer)
            $hideText = if ($unconfirmed) {
                "🕓 أُرسل أمر إخفاء الطبقة $Layer وقبِله Cinegy، لكن لم يُؤكَّد رفعها بعد.`nتبقى معروضة هنا كأنها على الهواء حتى يصل التأكيد."
            }
            else { "✅ تم إخفاء الطبقة $Layer." }
            Send-TelegramMessage -ChatId $ChatId -Text $hideText -ReplyMarkup (Get-AfterLayerRemovalKeyboard -Layer $Layer -ChatId $ChatId -UserId $UserId)
        }
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -Target $outgoingKey -Values $outgoingCopy
    }
    elseif (-not $Quiet) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل إخفاء الطبقة $Layer : $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    if (-not $result.Success) {
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -Target $outgoingKey -Values $outgoingCopy -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Invoke-ExitLayer {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext -Action EXIT -Layer $Layer -UserId $UserId
    # Read before anything runs: the operation clears the layer, and the
    # answer to "what did I just take down" is only available beforehand.
    $outgoing = if ($script:OnAir.ContainsKey($Layer)) { $script:OnAir[$Layer] } else { $null }
    $outgoingKey = if ($outgoing) { [string](Get-JsonProp $outgoing 'Key') } else { '' }
    $outgoingCopy = if ($outgoing) { [string](Get-JsonProp $outgoing 'AirCopy') } else { '' }
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -Target $outgoingKey -Values $outgoingCopy -ErrorText 'maintenance mode'
        return $false
    }
    # A bulletin walking this layer has to stop with it, or it keeps writing
    # rows into a scene nobody can see. After the gate, for the same reason as
    # the hide above.
    Stop-MojazForLayer -Layer $Layer | Out-Null
    $rollbackSnapshot = $null
    if (Get-Setting 'EnableSafeRollback') {
        $preExitStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $rollbackSnapshot = Get-CorrelatedLayerSnapshot -Layer $Layer -LiveStatus $preExitStatus
    }
    Start-AirOperation -Operation $operation -Action EXIT -Layer $Layer -UserId $UserId
    $result = Exit-TitlerScene -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-AirTimeout)
    if ($result.Success) {
        if ($rollbackSnapshot) { Set-RollbackCandidate -Layer $Layer -RestoreSnapshot $rollbackSnapshot -ExpectedState hidden -ActorUserId $UserId }
        # Dropped directly rather than reconciled: Cinegy keeps the playlist
        # item Active after EXIT_SCENE_LOOP, so a status read here cannot tell
        # an exited scene from a live one and would preserve the record for
        # ever. See Remove-OnAirRecord.
        Remove-OnAirRecord -Layer $Layer -Reason 'after-exit' | Out-Null
        $actor = Format-UserAuditActor -UserId $UserId
        Write-BridgeLog "User $actor exited scene on layer $Layer"
        Add-AuditEntry "🚪 خروج من مشهد طبقة $Layer - بواسطة $actor"
        Send-TemplateAirNotice -Key $outgoingKey -Layer $Layer -ActorChatId $ChatId -ActorName $actor `
            -Copy $outgoingCopy -Action hide -OnAirSince (Get-JsonProp $outgoing 'At') | Out-Null
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم الخروج من المشهد على الطبقة $Layer." -ReplyMarkup (Get-AfterLayerRemovalKeyboard -Layer $Layer -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -Target $outgoingKey -Values $outgoingCopy
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل الخروج من المشهد على الطبقة $Layer : $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -Target $outgoingKey -Values $outgoingCopy -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Start-SafeRollbackReview {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $candidate = Get-RollbackCandidate -Layer $Layer -UserId $UserId
    if (-not $candidate) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد تراجع صالح لهذه الطبقة، أو انتهت مدته.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $snapshot = $candidate.Restore
    $expected = if ([string]$candidate.ExpectedState -eq 'hidden') { 'يجب أن تبقى الطبقة فارغة' } else { 'يجب أن يبقى المشهد الحالي نفسه دون تغيير خارجي' }
    Set-PendingState -ChatId $ChatId -State @{ Mode='safe_rollback_review'; UserId=$UserId; Layer=$Layer; CandidateId=[string]$candidate.Id }
    Send-TelegramMessage -ChatId $ChatId -Text "↩️ مراجعة التراجع الآمن`nالطبقة: $Layer`nسيُستعاد القالب: $($snapshot.Key)`nشرط التنفيذ: $expected`nتنتهي الصلاحية: $(([datetime]$candidate.ExpiresAt).ToString('HH:mm:ss'))`n`nسيُفحص Cinegy مباشرة بعد التأكيد." -ReplyMarkup (Get-RollbackReviewKeyboard -Layer $Layer)
}

function Confirm-SafeRollback {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'safe_rollback_review' -or [long]$state.UserId -ne $UserId -or [int]$state.Layer -ne $Layer) { return }
    $candidate = Get-RollbackCandidate -Layer $Layer -UserId $UserId
    Clear-PendingState -ChatId $ChatId
    if (-not $candidate -or [string]$candidate.Id -ne [string]$state.CandidateId) {
        Send-TelegramMessage -ChatId $ChatId -Text 'انتهى أو تغير مرشح التراجع. لم يُرسل شيء.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    $lock = Lock-GfxLayer -Layer $Layer -ChatId $ChatId -UserId $UserId -Key ([string]$candidate.Restore.Key)
    if (-not $lock.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الطبقة قيد عملية أخرى؛ لم يُنفذ التراجع.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try {
        $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $safe = $status.Success -and $null -ne $status.IsOnAir
        if ($safe -and [string]$candidate.ExpectedState -eq 'hidden') { $safe = -not [bool]$status.IsOnAir }
        elseif ($safe) {
            $activeId = [string](Get-JsonProp $status 'ActiveId')
            $safe = [bool]$status.IsOnAir -and -not [string]::IsNullOrWhiteSpace($activeId) -and $activeId -eq [string]$candidate.ExpectedActiveId
        }
        if (-not $safe) {
            $script:RollbackCandidates.Remove($Layer) | Out-Null
            Send-TelegramMessage -ChatId $ChatId -Text '⛔ تغيرت حالة Cinegy أو تعذر التحقق منها؛ أُلغي التراجع ولم يُرسل شيء.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
            return
        }
        $restore = $candidate.Restore
        # Undoing a push onto a previously empty layer means clearing it again,
        # not restoring a scene that was never there.
        if ([string](Get-JsonProp $restore 'Action') -eq 'hide') {
            $hidden = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress `
                -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-AirTimeout)
            if ($hidden.Success) {
                Remove-OnAirRecord -Layer $Layer -Reason 'undo of show onto an empty layer' | Out-Null
                $actor = Format-UserAuditActor -UserId $UserId
                Add-AuditEntry "↩️ تراجع: أُزيل $($restore.Key) من طبقة $Layer - بواسطة $actor"
                Write-BridgeLog "User $actor undid the show of '$($restore.Key)' on layer $Layer" 'WARN'
                # Asked now, not later: in ten seconds they will have moved on.
                $script:PendingCancelReason = @{ UserId = $UserId; Key = [string]$restore.Key; At = (Get-Date) }
                Send-TelegramMessage -ChatId $ChatId -Text "↩️ أُزيل '$($restore.Key)' من الطبقة $Layer.
ما السبب؟ (اختياري)" -ReplyMarkup (Get-CancelReasonKeyboard)
            }
            else {
                Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر التراجع: $($hidden.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
            }
            return
        }
        $result = Invoke-ShowTemplateResult -Key ([string]$restore.Key) -Variables ([hashtable]$restore.Variables) -ChatId $ChatId -UserId $UserId
        if ($result -and $result.Success) {
            $actor = Format-UserAuditActor -UserId $UserId
            Add-AuditEntry "↩️ تراجع آمن إلى $($restore.Key) على طبقة $Layer - بواسطة $actor"
            Write-BridgeLog "User $actor safely rolled layer $Layer back to '$($restore.Key)'" 'WARN'
        }
    }
    finally { Unlock-GfxLayer -ChatId $ChatId -Layer $Layer }
}

function Invoke-HideAllLayers {
    <# Emergency "get it off air" button - hides only the layers selected by
       the administrator. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $maintenanceOverride = Test-Admin -ChatId $ChatId -UserId $UserId
    $layers = @(Get-HideAllTargetLayers)
    if ($layers.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لا توجد طبقات محددة لإخفاء الكل. يضبطها المشرف من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $ok = @(); $failed = @()
    foreach ($l in $layers) {
        if (Invoke-HideLayer -Layer $l -ChatId $ChatId -UserId $UserId -Quiet -MaintenanceOverride:$maintenanceOverride) { $ok += $l } else { $failed += $l }
    }
    $script:AutoHideQueue.Clear()
    $actor = Format-UserAuditActor -UserId $UserId
    Write-BridgeLog "User $actor triggered HIDE ALL (ok: $($ok -join ','); failed: $($failed -join ','))" "WARN"
    Add-AuditEntry "🚨 إخفاء الكل - بواسطة $actor"
    $text = "🚨 تم إخفاء الطبقات: $($ok -join ', ')"
    if ($failed.Count -gt 0) { $text += "`n❌ فشلت: $($failed -join ', ')" }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Invoke-SetValues {
    param([Parameter(Mandatory)][hashtable]$Values, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext -Action UPDATE -UserId $UserId
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',') -ErrorText 'maintenance mode'
        return $false
    }
    Start-AirOperation -Operation $operation -Action UPDATE -UserId $UserId
    $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Values $Values -TimeoutSec (Get-AirTimeout)
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air POSTBOX XML: $($result.Xml)" }
    if ($result.Success) {
        $actor = Format-UserAuditActor -UserId $UserId
        Write-BridgeLog "User $actor set values: $($Values.Keys -join ', ')"
        Add-AuditEntry "✏️ تحديث $($Values.Keys -join ', ') - بواسطة $actor"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم التحديث: $($Values.Keys -join ', ')" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',') -Values (Format-AuditTemplateValues -Variables $Values)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل التحديث: $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',') -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Start-UpdateFieldPrompt {
    param([Parameter(Mandatory)][string]$FieldName, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$FieldLimit = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'update_field'; Field = $FieldName; UserId = $UserId; FieldLimit = $FieldLimit }
    $limit = Get-EffectiveFieldLimit -FieldLimit $FieldLimit
    $limitText = if ($limit -gt 0) { " (الحد: $limit حرفًا)" } else { "" }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل القيمة الجديدة لـ '$FieldName'$limitText`:" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-UpdateField {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $limit = 0
    if ($state.ContainsKey('FieldLimit')) { $limit = [int]$state.FieldLimit }
    if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-CancelKeyboard))) { return }
    Clear-PendingState -ChatId $ChatId
    Invoke-SetValues -Values @{ $state.Field = $Value } -ChatId $ChatId -UserId $state.UserId
}

function Set-LayerAutoHide {
    <# Attaches (or replaces) an auto-hide timer on a layer that is already on
       air. Replacing rather than stacking matters: two timers on one layer
       would hide it twice, the second one possibly killing a later graphic. #>
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][int]$Seconds,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($Seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "المدة يجب أن تكون أكبر من صفر." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $current = if ($script:OnAir.ContainsKey($Layer)) { $script:OnAir[$Layer] } else { $null }
    if ($null -eq $current) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لا يوجد مشهد مسجّل على الطبقة $Layer؛ لم يُضبط المؤقت." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $currentKey = [string](Get-JsonProp $current 'Key')
    $templatePath = ''
    $store = Get-TemplateStore
    if ($store.Map.ContainsKey($currentKey)) { $templatePath = [string](Get-JsonProp $store.Map[$currentKey] 'Path') }
    $expectedActiveId = ''
    if ($script:LastSuccessfulLayerShows.ContainsKey($Layer)) {
        $lastShow = $script:LastSuccessfulLayerShows[$Layer]
        if ([string](Get-JsonProp $lastShow 'Key') -ieq $currentKey -and
            [bool](Get-JsonProp $lastShow 'ActiveIdConfirmed')) {
            $expectedActiveId = [string](Get-JsonProp $lastShow 'ActiveId')
        }
    }
    if ([string]::IsNullOrWhiteSpace($expectedActiveId) -and
        [bool](Get-JsonProp $current 'ActiveIdConfirmed')) {
        $expectedActiveId = [string](Get-JsonProp $current 'ActiveId')
    }
    $identity = Get-VerifiedCinegyShowIdentity -Key $currentKey -TemplatePath $templatePath -Layer $Layer `
        -ExpectedActiveId $expectedActiveId -AllowAnonymousActiveId
    if (-not $identity.Success) {
        Write-BridgeLog "Refused auto-hide timer on layer $Layer because live identity could not be verified: $($identity.Error)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لم يُضبط المؤقت: تعذّر ربط المشهد الحالي بهوية Cinegy مؤكدة. أخفه يدويًا عند الحاجة." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $current.ActiveId = [string]$identity.ActiveId
    $current.ActiveIdConfirmed = $true
    Save-OnAirState
    $timerSaved = Set-AutoHideTimer -Layer $Layer -Seconds $Seconds -ChatId $ChatId -UserId $UserId `
        -TemplateKey $currentKey -ActiveId ([string]$identity.ActiveId) -ActiveIdConfirmed $true
    $actor = Format-UserAuditActor -UserId $UserId
    Write-BridgeLog "User $actor set an auto-hide timer of $Seconds s on layer $Layer"
    Add-AuditEntry "⏱ مؤقت $Seconds ث على طبقة $Layer - بواسطة $actor"
    $timerText = if ($timerSaved) {
        "⏱ سيتم إخفاء الطبقة $Layer بعد $(Format-Duration -Seconds $Seconds)."
    }
    else {
        "⚠️ ضُبط مؤقت الطبقة $Layer داخل الجسر، لكن تعذّر حفظه ليستمر بعد إعادة التشغيل."
    }
    Send-TelegramMessage -ChatId $ChatId -Text $timerText -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Complete-TimedShowCustom {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $seconds = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$seconds) -or $seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ أرسل رقمًا صحيحًا أكبر من صفر (بالثواني)." -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Start-ShowFlow -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $state.UserId -AutoHideSeconds $seconds
}

function Complete-LayerTimerCustom {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $seconds = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$seconds) -or $seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ أرسل رقمًا صحيحًا أكبر من صفر (بالثواني)." -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Set-LayerAutoHide -Layer ([int]$state.Layer) -Seconds $seconds -ChatId $ChatId -UserId $state.UserId
}

function Invoke-RepeatLastShow {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:LastShow.ContainsKey($ChatId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "لا يوجد إظهار سابق لإعادته." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $last = $script:LastShow[$ChatId]
    $templateIndex = Get-TemplateIndex -Key ([string]$last.Key)
    if ($templateIndex -lt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب السابق لم يعد موجودًا في ملف القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    Start-ShowFlow -TemplateIndex $templateIndex -ChatId $ChatId -UserId $UserId -InitialValues $last.Variables
}

function Get-MyOperationsCopyReference {
    <#
        The reference this screen offers to copy, or '' when it offers none.

        The reference is eight hex characters an operator quotes to an
        administrator so one grep finds the line. It was printed in the
        message and had to be retyped off a phone, one character wrong being
        one grep that finds nothing; copy_text puts it on the clipboard.
        Only the newest one gets a button - ten of them would bury the two
        controls under a wall of hex.

        The newest *failed* one when there is one: a reference is printed on
        screen only beside a failure, and that failure is what gets reported.
        Copying the reference of a successful operation instead handed the
        operator eight characters that appear nowhere on the screen they are
        reading from.

        Its own function because the message body has to say what the button
        does and the body is built in another file. Two copies of this choice
        would drift into a screen promising a button it does not have.
    #>
    param([Parameter(Mandatory)][long]$UserId)
    $history = @(Get-UserOperationHistory -UserId $UserId | Select-Object -Last 10)
    # Get-JsonProp, not $_.Result: a history entry carries only the fields
    # its writer knew, and StrictMode turns a missing one into a crash on the
    # screen an operator opens to report a crash.
    $troubled = @($history | Where-Object { [string](Get-JsonProp $_ 'Result') -notin @('', 'success') })
    $latest = @(@(if ($troubled.Count -gt 0) { $troubled } else { $history }) | Select-Object -Last 1)
    if ($latest.Count -eq 0) { return '' }
    return [string](Get-OperationReference -OperationId ([string]$latest[0].OperationId))
}

function Get-MyOperationsCopyLabel {
    <# What the button says, so the notice can name it exactly. #>
    param([Parameter(Mandatory)][string]$Reference)
    return "نسخ مرجع $Reference"
}

function Get-MyOperationsKeyboard {
    param([Parameter(Mandatory)][long]$UserId)
    $rows = @()
    $reference = Get-MyOperationsCopyReference -UserId $UserId
    if ($reference) {
        # Through the shared helper rather than a hand-built hashtable, so
        # there is one place that knows what a copy button looks like.
        $rows += , @((New-CopyButton -Text "📋 $(Get-MyOperationsCopyLabel -Reference $reference)" -Payload $reference))
    }
    if ($script:LastShowAttempts.ContainsKey([string]$UserId)) {
        $rows += , @((New-Button '🔁 إعادة محاولة آمنة' 'ops:retry'))
    }
    # The window that reaches past this screen. What is above comes from
    # memory - twenty entries a person, and only since the last restart - so
    # a supervisor asking what went out last night was shown this morning.
    $rows += , @((New-Button '📅 سجل 48 ساعة' 'oplog:48'))
    $rows += , @((New-Button '🔄 تحديث' 'menu:myops'), (New-Button '🏠 القائمة' 'menu:main'))
    return @{ inline_keyboard = $rows }
}

function Test-NewsTickerFilePathSetting {
    param([AllowEmptyString()][string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) { return $false }
    if (-not [IO.Path]::GetExtension($Path).Equals('.txt', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    try { [void][IO.Path]::GetFullPath($Path); return $true } catch { return $false }
}

function Get-TemplateCategoryLabel {
    <# The template's own category, when it still exists. A history entry can
       outlive the template it names, so a missing one is normal and silent. #>
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $index = Get-TemplateIndex -Key $Key
    if ($index -lt 0) { return '' }
    $template = Get-TemplateByIndex -Index $index
    if (-not $template) { return '' }
    return [string](Get-JsonProp $template 'Category')
}

function Get-OperationSentence {
    <# Operator-facing wording for one control action. This screen is read by
       the people pressing the buttons, not by whoever opens bridge.log, so it
       says «عرض» rather than SHOW and never prints a millisecond count. #>
    param([string]$Action, [string]$Result, [string]$Target, [int]$Layer)
    $verb = switch ($Action) {
        'SHOW' { 'عرض' }
        'HIDE' { 'إخفاء' }
        'EXIT' { 'خروج' }
        'UPDATE' { 'تحديث' }
        default { $Action }
    }
    $phrase = switch ($Result) {
        'success' { $verb }
        'blocked' { "رُفض $verb" }
        default { "فشل $verb" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Target)) { $phrase += " «$Target»" }
    if ($Layer -gt 0) { $phrase += " على الطبقة $Layer" }
    return $phrase
}

function Get-OperationReference {
    <# The short half of the AIR_OP correlation id. An operator reporting a
       problem can quote this and an administrator can find the exact line in
       the log with it; the full 32-hex id is unreadable on a phone and nobody
       would retype it. Eight hex characters is 4 billion values against a
       history of at most a few thousand operations. #>
    param([string]$OperationId)
    if ([string]::IsNullOrWhiteSpace($OperationId)) { return '' }
    $hex = $OperationId -replace '^air-', ''
    if ($hex.Length -lt 8) { return '' }
    return $hex.Substring(0, 8)
}

function Invoke-MyOperationsCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    # Structured list first; the text below is what it falls back to.
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-MyOperationsBlocks -UserId $UserId) `
            -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)) { return }
    $history = @(Get-UserOperationHistory -UserId $UserId | Select-Object -Last 10)
    if ($history.Count -eq 0) {
        # Not "منذ آخر تشغيل" any more: the history is rebuilt from audit.jsonl
        # at startup, so an empty screen now genuinely means nothing was done.
        Send-TelegramMessage -ChatId $ChatId -Text "🧾 آخر عملياتك`n━━━━━━━━━━━━━━`nلم تُسجَّل لك أي عملية بعد." -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('🧾 آخر عملياتك')
    $lines.Add('━━━━━━━━━━━━━━')
    foreach ($item in $history) {
        $icon = switch ([string]$item.Result) {
            'success' { '✅' }
            'blocked' { '⛔' }
            default { '❌' }
        }
        $stamp = ([datetime]$item.At).ToString('HH:mm')
        $lines.Add("$icon $stamp — $(Get-OperationSentence -Action ([string]$item.Action) -Result ([string]$item.Result) -Target ([string]$item.Target) -Layer ([int]$item.Layer))")

        # What the operator can recognise the graphic by: its category, and
        # above all the text that actually reached the screen.
        $category = Get-TemplateCategoryLabel -Key ([string]$item.Target)
        if ($category) { $lines.Add("      🏷 $category") }
        $onAirText = [string](Get-JsonProp $item 'Values')
        if ($onAirText) { $lines.Add("      📝 $onAirText") }

        # The link back to the log. Shown for every operation, not just
        # failures: when an operator asks "what happened at 21:40" the
        # reference is what turns that into one grep.
        $reference = Get-OperationReference -OperationId ([string]$item.OperationId)
        if ($reference) { $lines.Add("      🔖 مرجع $reference") }

        $advice = switch ([string]$item.Result) {
            'failed' { 'افحص الاتصال ثم أعد المحاولة' }
            'blocked' { 'راجع صلاحيتك أو حالة Cinegy' }
            default { '' }
        }
        if ($advice) { $lines.Add("      ↳ $advice") }
    }
    $copyReference = Get-MyOperationsCopyReference -UserId $UserId
    if ($copyReference) {
        $lines.Add('')
        $lines.Add((Get-CopyButtonNotice -Label (Get-MyOperationsCopyLabel -Reference $copyReference) `
                    -Hint 'أرسله للمشرف مع وصف ما حدث.'))
    }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
}

function Invoke-RetryLastShowAttempt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $key = [string]$UserId
    if (-not $script:LastShowAttempts.ContainsKey($key)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا توجد محاولة عرض قابلة للمراجعة.' -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    $attempt = $script:LastShowAttempts[$key]
    $templateIndex = Get-TemplateIndex -Key ([string]$attempt.Key)
    if ($templateIndex -lt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text 'القالب المستخدم في المحاولة لم يعد موجودًا.' -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    Start-ShowFlow -TemplateIndex $templateIndex -ChatId $ChatId -UserId $UserId `
        -InitialValues $attempt.Variables -AutoHideSeconds ([int]$attempt.AutoHideSeconds) -ReviewImmediately
}

function Invoke-PresetShow {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $t = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $t -or $PresetIndex -ge $t.Presets.Count) {
        Send-TelegramMessage -ChatId $ChatId -Text "النص الجاهز غير موجود." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $preset = $t.Presets[$PresetIndex]
    $variables = @{}
    for ($i = 0; $i -lt $t.Fields.Count -and $i -lt $preset.Values.Count; $i++) {
        $variables[[string]$t.Fields[$i]] = [string]$preset.Values[$i]
    }
    Start-ShowFlow -TemplateIndex $TemplateIndex -ChatId $ChatId -UserId $UserId -InitialValues $variables -ReviewImmediately
}

function Show-PresetAdminTemplate {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب لم يعد موجودًا." -ReplyMarkup (Get-PresetAdminTemplatesKeyboard)
        return
    }
    Send-TelegramMessage -ChatId $ChatId -Text "⚡ النصوص الجاهزة للقالب '$($template.Key)'`nاختر نصًا لإدارته أو أنشئ نصًا جديدًا:" -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $TemplateIndex)
}

function Show-PresetAdminReview {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    $actionLabel = switch ([string]$State.Action) {
        'create' { 'إنشاء' }; 'edit' { 'تعديل القيم' }; 'rename' { 'إعادة تسمية' }; 'delete' { 'حذف' }
    }
    $lines = @("🔎 مراجعة تغيير النص الجاهز", "العملية: $actionLabel", "القالب: $($State.TemplateKey)")
    if ($State.Name) { $lines += "الاسم: $($State.Name)" }
    if ($State.Action -in @('create', 'edit')) {
        for ($i = 0; $i -lt @($State.Fields).Count; $i++) {
            $value = if ($i -lt @($State.Values).Count) { [string]$State.Values[$i] } else { '' }
            $lines += "• $($State.Fields[$i]): $value"
        }
    }
    $lines += ''
    $lines += 'لن يُعدّل ملف القوالب حتى تضغط حفظ التغيير.'
    $State.Mode = 'preset_admin_review'
    Set-PendingState -ChatId $ChatId -State $State
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-PresetReviewKeyboard)
}

function Start-PresetAdminCreate {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { return }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'preset_admin_name'; Action = 'create'; TemplateIndex = $TemplateIndex
        TemplateKey = [string]$template.Key; PresetIndex = -1; UserId = $UserId
        Fields = @($template.Fields); Values = @(); Name = ''; Index = 0
    }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل اسم النص الجاهز الجديد للقالب '$($template.Key)':" -ReplyMarkup (Get-CancelKeyboard)
}

function Start-PresetAdminEditValues {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template -or $PresetIndex -lt 0 -or $PresetIndex -ge @($template.Presets).Count) { return }
    $state = @{
        Mode = 'preset_admin_values'; Action = 'edit'; TemplateIndex = $TemplateIndex
        TemplateKey = [string]$template.Key; PresetIndex = $PresetIndex; UserId = $UserId
        Fields = @($template.Fields); Values = @(); Name = [string]$template.Presets[$PresetIndex].Name; Index = 0
    }
    if ($state.Fields.Count -eq 0) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل (1/$($state.Fields.Count)):`n$($state.Fields[0])" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-PresetAdminText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    if ($state.Mode -eq 'preset_admin_name') {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            Send-TelegramMessage -ChatId $ChatId -Text "الاسم لا يمكن أن يكون فارغًا." -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.Name = $Value.Trim()
        if ($state.Action -eq 'rename') { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        $state.Mode = 'preset_admin_values'
        if ($state.Fields.Count -eq 0) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل (1/$($state.Fields.Count)):`n$($state.Fields[0])" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    if ($state.Mode -eq 'preset_admin_values') {
        $state.Values = @($state.Values) + @([string]$Value)
        $state.Index = [int]$state.Index + 1
        if ($state.Index -ge $state.Fields.Count) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل ($($state.Index + 1)/$($state.Fields.Count)):`n$($state.Fields[$state.Index])" -ReplyMarkup (Get-CancelKeyboard)
    }
}

function Confirm-PresetAdminChange {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'preset_admin_review' -or [long]$state.UserId -ne $UserId) {
        Send-TelegramMessage -ChatId $ChatId -Text "انتهت مراجعة التغيير. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $templateIndex = [int]$state.TemplateIndex
    $result = Save-TemplatePresetChange -TemplateKey ([string]$state.TemplateKey) -PresetIndex ([int]$state.PresetIndex) -Action ([string]$state.Action) -Name ([string]$state.Name) -Values @($state.Values)
    Clear-PendingState -ChatId $ChatId
    if ($result.Success) {
        Write-BridgeLog "Admin $UserId applied preset $($state.Action) to template '$($state.TemplateKey)'"
        Add-AuditEntry "⚡ Preset $($state.Action) / $($state.TemplateKey) - admin $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم حفظ تغيير النص الجاهز، وأُنشئت نسخة احتياطية." -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $templateIndex)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ التغيير: $($result.Error)" -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $templateIndex)
    }
}

function Invoke-TemplatesCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $store = Get-TemplateStore
    if ($store.Order.Count -eq 0) {
        $text = "لا توجد قوالب معرّفة حاليًا."
        if ($store.Errors.Count -gt 0) { $text += "`n⚠️ " + ($store.Errors -join "`n⚠️ ") }
        Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $lines = foreach ($key in $store.Order) {
        $t = $store.Map[$key]
        "$($t.Key) (طبقة $($t.Layer)): $($t.Description)  الحقول: $($t.Fields -join ', ')"
    }
    $text = ($lines -join "`n")
    if ($store.Errors.Count -gt 0) { $text += "`n`n⚠️ " + ($store.Errors -join "`n⚠️ ") }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}
