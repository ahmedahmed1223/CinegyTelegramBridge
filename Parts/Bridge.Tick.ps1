#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Add-AbandonedDraft {
    <#
        T-16: every draft that dies on a timer is counted, by label and never
        by content. Three abandoned drafts on one template do not mean a lazy
        operator; they mean a hard template. Called from both expiry paths:
        the input-flow watchdog below and the news-draft expiry.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Label)
    $name = $Label.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'غير مصنّف' }
    $count = 0
    [int]::TryParse([string]$script:AbandonedDrafts[$name], [ref]$count) | Out-Null
    $script:AbandonedDrafts[$name] = $count + 1
}

function Get-AbandonedDraftLabel {
    <# A pending input flow, reduced to what may be counted: the template it
       belonged to, or the kind of work when there is no template. Values,
       aliases and chat ids never leave this function. #>
    param($State)
    if (-not $State) { return 'غير مصنّف' }
    $mode = [string](Get-JsonProp $State 'Mode')
    $key = [string](Get-JsonProp $State 'TemplateKey')
    if ([string]::IsNullOrWhiteSpace($key)) { $key = [string](Get-JsonProp $State 'Key') }
    if ($mode -in @('show_fields', 'show_review', 'schedule_fields', 'schedule_time', 'schedule_recurrence', 'schedule_review') -and -not [string]::IsNullOrWhiteSpace($key)) {
        return "قالب $key"
    }
    if ($mode -like 'news*') { return 'شريط الأخبار' }
    if ($mode -like 'mojaz*') { return 'الموجز' }
    if ($mode -like 'sched*') { return 'الجدولة' }
    if ($mode -eq 'access_request_name') { return 'طلب صلاحية' }
    # Never leak the internal state name: an unmapped mode is a flow the
    # table has not learned yet, not a word for an Arabic report.
    return 'غير مصنّف'
}

function Save-ExpiredFlowSnapshot {
    <#
        D3: keeps one resurrection of an expired show flow. Only show flows
        carry resumable values; the caller decides that. A helper rather than
        inline code: the paging gate reads Update-PendingExpiry's body as
        text and fails any function holding both a keyboard and a loop.
    #>
    param($State, [Parameter(Mandatory)][long]$ChatId)
    $snapshot = @{
        Mode = [string](Get-JsonProp $State 'Mode'); Key = [string](Get-JsonProp $State 'Key')
        Fields = @($State.Fields); Labels = @($State.Labels); Limits = @($State.Limits)
        Required = @($State.Required); Sensitives = @($State.Sensitives)
        Values = @{}; Index = [int]$State.Index; UserId = [long](Get-JsonProp $State 'UserId')
        AutoHideSeconds = [int](Get-JsonProp $State 'AutoHideSeconds')
        LockLayer = [int](Get-JsonProp $State 'LockLayer'); At = (Get-Date)
    }
    foreach ($name in @(if ($State.Values) { $State.Values.Keys } else { @() })) { $snapshot.Values[[string]$name] = [string]$State.Values[$name] }
    $script:ExpiredFlowResume[$ChatId] = $snapshot
}

function New-ExpiredFlowResumeKeyboard {
    # D3: the expiry message's way back, beside the menu. No loop inside -
    # see Save-ExpiredFlowSnapshot for why the two live apart.
    return @{ inline_keyboard = @(, @(@{ text = '↩️ استئناف من حيث توقفت'; callback_data = 'flow:resume' }, @{ text = '⬅️ القائمة'; callback_data = 'menu' })) }
}

function Update-PendingExpiry {
    $stateTimeout = Get-SettingInt 'PendingStateTimeoutMinutes' 1
    foreach ($chatId in @($script:PendingState.Keys)) {
        $state = $script:PendingState[$chatId]
        $elapsed = ((Get-Date) - $state.StartedAt).TotalMinutes
        if ($elapsed -ge $stateTimeout) {
            # D3: keep one resurrection. Only show flows carry resumable
            # values; anything else expires exactly as before.
            $resumeKeyboard = (Get-NoticeKeyboard)
            $mode = [string](Get-JsonProp $state 'Mode')
            $resumeKey = [string](Get-JsonProp $state 'Key')
            if ($mode -in @('show_fields', 'show_review') -and -not [string]::IsNullOrWhiteSpace($resumeKey)) {
                Save-ExpiredFlowSnapshot -State $state -ChatId ([long]$chatId)
                $resumeKeyboard = New-ExpiredFlowResumeKeyboard
            }
            Clear-PendingState -ChatId ([long]$chatId)
            Add-AbandonedDraft -Label (Get-AbandonedDraftLabel -State $state)
            Write-BridgeLog "Expired abandoned '$($state.Mode)' flow for chat $chatId" "WARN"
            Send-TelegramMessage -ChatId ([long]$chatId) -Text "⌛ انتهت مهلة الإدخال ولم يُنفّذ شيء." -ReplyMarkup $resumeKeyboard
            continue
        }
        # A minute's notice, with a way to take more time.
        #
        # An editor writing a headline was cut off mid-sentence and told "the
        # time ran out, start again" - the first he knew of any clock. He was
        # not abandoning the flow; he was being interrupted by the rest of his
        # job. The expiry is still right, because an abandoned flow eats the
        # next message the person sends, but it must not arrive as a surprise.
        if ($stateTimeout -ge 2 -and $elapsed -ge ($stateTimeout - 1) -and -not $state.ContainsKey('WarnedAt')) {
            $state.WarnedAt = Get-Date
            Send-TelegramMessage -ChatId ([long]$chatId) `
                -Text "⏳ لم يصل نصّك بعد، وستُلغى العملية بعد دقيقة. أرسل النص الآن أو اضغط «تمديد»." `
                -ReplyMarkup @{ inline_keyboard = @(, @((New-Button '⏳ تمديد' 'flow:extend'), (New-Button '❌ إلغاء' 'menu:main'))) }
        }
    }

    $approvalTimeout = Get-SettingInt 'PendingApprovalExpiryHours' 1
    foreach ($chatId in @($script:PendingApprovals.Keys)) {
        if (((Get-Date) - $script:PendingApprovals[$chatId].RequestedAt).TotalHours -ge $approvalTimeout) {
            $script:PendingApprovals.Remove($chatId)
            Write-BridgeLog "Expired stale access request from $chatId"
        }
    }

    # Rides along here because it is the same kind of housekeeping - who may
    # still use the bot - and it rate-limits itself to once a day.
    Update-DormantUsers | Out-Null
}

function Update-PostShowQueue {
    <# Fires the deferred postbox write that follows a SHOW. Failures are
       logged but never surfaced to the operator: the SHOW itself already
       succeeded and was already confirmed in chat.

       Addressed to a scene, not to a layer. The write lands up to
       PostShowDelayMs after the SHOW, and a layer can be replaced inside that
       window - so the values of the graphic that just left were being written
       into the one that had taken its place, and the room read the old
       headline under the new scene. The queue entry carries the key and the
       ActiveId it was made for; anything else on that layer now means the
       scene it belonged to is gone, and the write is dropped rather than
       aimed at a stranger. A HIDE or EXIT clears the record too, so those
       cancel a pending write by the same test. #>
    if ($script:PostShowQueue.Count -eq 0) { return }
    $due = @($script:PostShowQueue | Where-Object { (Get-Date) -ge $_.At })
    foreach ($item in $due) {
        $script:PostShowQueue.Remove($item) | Out-Null
        $layer = [int]$item.Layer
        $live = if ($script:OnAir.ContainsKey($layer)) { $script:OnAir[$layer] } else { $null }
        $stillOurs = $null -ne $live -and [string](Get-JsonProp $live 'Key') -eq [string]$item.Key
        if ($stillOurs -and [string]$item.ActiveId) {
            $liveId = [string](Get-JsonProp $live 'ActiveId')
            if ($liveId) { $stillOurs = $liveId -eq [string]$item.ActiveId }
        }
        if (-not $stillOurs) {
            $now = if ($live) { [string](Get-JsonProp $live 'Key') } else { 'nothing' }
            Write-BridgeLog "Dropped the post-show postbox write for '$($item.Key)' on layer $layer : the layer now holds $now." 'WARN'
            continue
        }
        $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress `
            -AirChannelNumber $config.AirChannelNumber -Values $item.Values -TimeoutSec (Get-AirTimeout)
        if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air post-show POSTBOX ($($item.Key)): success=$($result.Success) $($result.Xml)" }
        if (-not $result.Success) {
            Write-BridgeLog "Post-show postbox write failed for '$($item.Key)': $($result.Error)" "WARN"
        }
    }
}

function Save-AutoHideQueue {
    try {
        $payload = @($script:AutoHideQueue | ForEach-Object {
                $at = [datetimeoffset]$_.At
                [ordered]@{
                    Layer       = [int](Get-JsonProp $_ 'Layer')
                    At          = $at.ToString('o')
                    ChatId      = [long](Get-JsonProp $_ 'ChatId')
                    UserId      = [long](Get-JsonProp $_ 'UserId')
                    TemplateKey = [string](Get-JsonProp $_ 'TemplateKey')
                    ActiveId    = [string](Get-JsonProp $_ 'ActiveId')
                    ActiveIdConfirmed = [bool](Get-JsonProp $_ 'ActiveIdConfirmed')
                    Stage = [string](Get-JsonProp $_ 'Stage')
                    Token = [string](Get-JsonProp $_ 'Token')
                    ShowAt = [string](Get-JsonProp $_ 'ShowAt')
                    ExtensionUsed = [bool](Get-JsonProp $_ 'ExtensionUsed')
                    Choice = [int](Get-JsonProp $_ 'Choice')
                    RetryCount = [int](Get-JsonProp $_ 'RetryCount')
                    RetryAt = $(if (Get-JsonProp $_ 'RetryAt') { ([datetimeoffset]$_.RetryAt).ToString('o') } else { '' })
                    NoticeAt = $(if (Get-JsonProp $_ 'NoticeAt') { ([datetimeoffset]$_.NoticeAt).ToString('o') } else { '' })
                }
            })
        $json = ConvertTo-Json -InputObject $payload -Depth 4
        if (-not (Write-ValidatedJsonState -Path $script:autoHideFile -Json $json)) { throw 'validated state write failed' }
        return $true
    }
    catch {
        Write-BridgeLog "Could not write autohide.json: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Import-AutoHideQueue {
    try {
        $read = Read-ValidatedJsonState -Path $script:autoHideFile -AsHashtable
        if (-not $read) { return }
        $restored = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($raw in @($read.Data)) {
            if (-not $raw) { continue }
            $layer = 0
            if (-not [int]::TryParse([string](Get-JsonProp $raw 'Layer'), [ref]$layer) -or $layer -le 0) { continue }
            $at = [datetimeoffset]::MinValue
            if (-not [datetimeoffset]::TryParse([string](Get-JsonProp $raw 'At'), [ref]$at)) { continue }
            $restored.Add(@{
                    Layer       = $layer
                    At          = $at
                    ChatId      = [long](Get-JsonProp $raw 'ChatId')
                    UserId      = [long](Get-JsonProp $raw 'UserId')
                    TemplateKey = [string](Get-JsonProp $raw 'TemplateKey')
                    ActiveId    = [string](Get-JsonProp $raw 'ActiveId')
                    ActiveIdConfirmed = [bool](Get-JsonProp $raw 'ActiveIdConfirmed')
                    Stage = [string](Get-JsonProp $raw 'Stage')
                    Token = [string](Get-JsonProp $raw 'Token')
                    ShowAt = [string](Get-JsonProp $raw 'ShowAt')
                    ExtensionUsed = [bool](Get-JsonProp $raw 'ExtensionUsed')
                    Choice = [int](Get-JsonProp $raw 'Choice')
                    RetryCount = [int](Get-JsonProp $raw 'RetryCount')
                    RetryAt = [string](Get-JsonProp $raw 'RetryAt')
                    NoticeAt = [string](Get-JsonProp $raw 'NoticeAt')
                })
        }
        $script:AutoHideQueue = $restored
        Write-BridgeLog "Restored $($script:AutoHideQueue.Count) auto-hide timer(s) from autohide.json."
    }
    catch { Write-BridgeLog "Could not read autohide.json: $($_.Exception.Message)" 'WARN' }
}

function Set-AutoHideTimer {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][int]$Seconds,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [string]$TemplateKey = '',
        [string]$ActiveId = '',
        [bool]$ActiveIdConfirmed = $false
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($Seconds -le 0) { return $false }
    $deadline = [datetimeoffset]::Now.AddSeconds($Seconds)
    $current = if ($script:OnAir.ContainsKey($Layer)) { $script:OnAir[$Layer] } else { $null }
    $key = if ($current) { [string](Get-JsonProp $current 'Key') } else { $TemplateKey }
    $maximum = if ($key) { Get-EffectiveAutoHideSeconds -Key $key } else { 0 }
    if ($maximum -gt 0) {
        $shownAt = [datetimeoffset]::MinValue
        if (-not $current -or -not [datetimeoffset]::TryParse([string](Get-JsonProp $current 'At'), [ref]$shownAt)) {
            Write-BridgeLog 'Cannot set a capped timer without its show timestamp.' 'WARN'
            return $false
        }
        $maximumAt = $shownAt.AddSeconds($maximum)
        if ($maximumAt -lt $deadline) { $deadline = $maximumAt }
    }
    $previous = @($script:AutoHideQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq $Layer })
    for ($i = $script:AutoHideQueue.Count - 1; $i -ge 0; $i--) {
        if ([int](Get-JsonProp $script:AutoHideQueue[$i] 'Layer') -eq $Layer) { $script:AutoHideQueue.RemoveAt($i) }
    }
    $timer = @{
            Layer       = $Layer
            At          = $deadline
            ChatId      = $ChatId
            UserId      = $UserId
            TemplateKey = $TemplateKey
            ActiveId    = $ActiveId
            ActiveIdConfirmed = $ActiveIdConfirmed
        }
    $script:AutoHideQueue.Add($timer)
    if (Save-AutoHideQueue) { return $true }
    $script:AutoHideQueue.Remove($timer) | Out-Null
    foreach ($oldTimer in $previous) { $script:AutoHideQueue.Add($oldTimer) }
    return $false
}

function Get-AutoHideTargetDecision {
    param(
        [Parameter(Mandatory)][hashtable]$Timer,
        [AllowNull()]$LiveStatus = $null
    )
    $layer = [int](Get-JsonProp $Timer 'Layer')
    if (-not $script:OnAir.ContainsKey($layer)) {
        return [pscustomobject]@{ ShouldHide = $false; Reason = "الطبقة $layer لم تعد مسجلة على الهواء." }
    }
    $current = $script:OnAir[$layer]
    $timerId = [string](Get-JsonProp $Timer 'ActiveId')
    $currentId = [string](Get-JsonProp $current 'ActiveId')
    if ($timerId -and $currentId -and
        -not $timerId.Trim().Trim('{', '}').Equals($currentId.Trim().Trim('{', '}'), [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ShouldHide = $false; Reason = "الطبقة $layer تغيّرت منذ ضبط المؤقت." }
    }
    $timerKey = [string](Get-JsonProp $Timer 'TemplateKey')
    $currentKey = [string](Get-JsonProp $current 'Key')
    if ($timerKey -and $currentKey -and
        -not $timerKey.Equals($currentKey, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ShouldHide = $false; Reason = "القالب على الطبقة $layer تغيّر منذ ضبط المؤقت." }
    }
    if ($null -ne $LiveStatus) {
        if (-not [bool](Get-JsonProp $LiveStatus 'Success')) {
            return [pscustomobject]@{ ShouldHide = $false; Reason = "تعذّر التحقق من حالة Cinegy للطبقة $layer." }
        }
        if ($LiveStatus.IsOnAir -ne $true) {
            return [pscustomobject]@{ ShouldHide = $false; Reason = "الطبقة $layer لم تعد على الهواء." }
        }
        $liveId = ([string](Get-JsonProp $LiveStatus 'ActiveId')).Trim().Trim('{', '}')
        $savedId = $timerId.Trim().Trim('{', '}')
        if ([string]::IsNullOrWhiteSpace($liveId) -or
            [string]::IsNullOrWhiteSpace($savedId) -or
            -not $liveId.Equals($savedId, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ ShouldHide = $false; Reason = "الطبقة $layer تغيّرت منذ ضبط المؤقت." }
        }
    }
    return [pscustomobject]@{ ShouldHide = $true; Reason = '' }
}

function Request-TemplateAirLimitNow {
    <# Admin-only "apply the cap to the show on air right now". Shortens the
       running show's timer to the remaining cap; never lengthens anything and
       never sends an air command itself. #>
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [datetimeoffset]$Now = [datetimeoffset]::Now)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $false }
    $layer = 0
    $found = $false
    foreach ($entry in $script:OnAir.GetEnumerator()) {
        if ([string](Get-JsonProp $entry.Value 'Key') -ieq $Key) { $layer = [int]$entry.Key; $found = $true; break }
    }
    if (-not $found) { return $false }
    $timer = @($script:AutoHideQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq $layer }) | Select-Object -First 1
    if (-not $timer) { return $false }
    $cap = Get-EffectiveAutoHideSeconds -Key $Key
    $shownAt = [datetimeoffset]::MinValue
    if ($cap -le 0 -or -not [datetimeoffset]::TryParse([string](Get-JsonProp $timer 'ShowAt'), [ref]$shownAt)) { return $false }
    $deadline = $shownAt.AddSeconds($cap)
    if ($deadline -ge [datetimeoffset]$timer.At) { return $false }
    $previous = $timer.Clone()
    $timer.Stage = 'hide'; $timer.At = $deadline
    if (-not (Save-AutoHideQueue)) {
        $timer.Clear(); foreach ($key in $previous.Keys) { $timer[$key] = $previous[$key] }
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ تعذّر حفظ التقصير؛ بقي الموعد السابق.'
        return $false
    }
    Write-BridgeLog "Template cap applied now to layer $layer by admin $UserId at $([datetimeoffset]$Now.ToString('o'))."
    return $true
}

function Invoke-TemplateAirExtensionReply {
    param([string]$Argument, [long]$ChatId, [long]$UserId, [int]$MessageId = 0, [datetimeoffset]$Now = [datetimeoffset]::Now)
    if (-not (Test-Authorized -ChatId $ChatId -UserId $UserId) -or
        $Argument -notmatch '^([a-f0-9]{12}):(extend|custom|delta|confirm|hide):(-?[0-9]{1,4})$') { return $false }
    $token = $Matches[1]; $action = $Matches[2]; $value = [int]$Matches[3]
    $timer = @($script:AutoHideQueue | Where-Object { [string](Get-JsonProp $_ 'Token') -ceq $token }) | Select-Object -First 1
    if (-not $timer -or [string](Get-JsonProp $timer 'Stage') -ne 'offer' -or
        $Now -ge [datetimeoffset]$timer.At -or [bool](Get-JsonProp $timer 'ExtensionUsed')) { return $false }
    if ([long]$timer.UserId -ne $UserId -and -not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $false }
    if (-not (Get-AutoHideTargetDecision -Timer $timer).ShouldHide) { return $false }
    $live = $script:OnAir[[int]$timer.Layer]
    if ([datetimeoffset]$timer.ShowAt -ne [datetimeoffset]([string](Get-JsonProp $live 'At'))) { return $false }
    $maximum = [math]::Clamp((Get-SettingInt 'TemplateAirExtensionMaxSeconds' 60),60,3600)
    $previous = $timer.Clone()
    if ($action -eq 'hide') { $timer.Stage = 'hide'; $timer.At = $Now }
    else {
        if (-not (Get-Setting 'TemplateAirExtensionEnabled')) { return $false }
        $sensitive = @([string](Get-Setting 'SensitiveTemplateKeys') -split '[,;\r\n]+' | ForEach-Object { $_.Trim() }) -contains ([string]$timer.TemplateKey)
        if ($sensitive) { return $false }
        if ($action -eq 'delta') {
            if ($value -notin @(-60,-10,10,60)) { return $false }
            $timer.Choice = [math]::Clamp(([int]$timer.Choice + $value),1,$maximum)
        }
        elseif ($action -in @('extend','confirm')) {
            $seconds = if ($action -eq 'confirm') { [int]$timer.Choice } else { $value }
            if ($seconds -lt 1 -or $seconds -gt $maximum) { return $false }
            $timer.Stage = 'extended'; $timer.ExtensionUsed = $true; $timer.At = $Now.AddSeconds($seconds)
        }
    }
    if (-not (Save-AutoHideQueue)) {
        $timer.Clear(); foreach ($key in $previous.Keys) { $timer[$key] = $previous[$key] }
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ تعذّر حفظ الاختيار؛ لم يتغير موعد الإخفاء.'
        return $false
    }
    if ($action -eq 'hide') { Update-AutoHideQueue -Now $Now }
    elseif ($action -in @('custom','delta')) { Show-TemplateAirExtensionOffer -Timer $timer -MessageId $MessageId -Custom }
    else { Send-TelegramMessage -ChatId $ChatId -Text "⏱ تم التمديد مرة واحدة؛ الإخفاء عند $(([datetimeoffset]$timer.At).ToLocalTime().ToString('HH:mm:ss'))." }
    return $true
}

function Show-TemplateAirExtensionOffer {
    param([hashtable]$Timer, [int]$MessageId = 0, [switch]$Custom)
    $prefix = "airext:$($Timer.Token)"
    $text = "⏱ بلغ القالب $($Timer.TemplateKey) حدّه على الهواء.`nتمديد واحد فقط. إذا لم تؤكّد قبل $(([datetimeoffset]$Timer.At).ToLocalTime().ToString('HH:mm:ss')) فسيُخفى تلقائيًا."
    $rows = @()
    if ($Custom) {
        $text += "`nالمدة المختارة: $($Timer.Choice) ثانية. تعديلها لا يمدّد مهلة الرد."
        $rows += , @((New-Button '− دقيقة' "${prefix}:delta:-60"),(New-Button '+ دقيقة' "${prefix}:delta:60"))
        $rows += , @((New-Button '−10 ث' "${prefix}:delta:-10"),(New-Button '+10 ث' "${prefix}:delta:10"))
        $rows += , @((New-Button 'تأكيد التمديد' "${prefix}:confirm:0"))
    }
    else {
        $preset = [math]::Min(300,(Get-SettingInt 'TemplateAirExtensionMaxSeconds' 60))
        $label = if ($preset -eq 300) { '٥ دقائق' } else { "$preset ثانية" }
        $rows += , @((New-Button $label "${prefix}:extend:$preset"),(New-Button 'مدة مخصصة' "${prefix}:custom:0"))
    }
    $rows += , @((New-Button 'إخفاء الآن' "${prefix}:hide:0" -Style danger))
    $markup = @{ inline_keyboard = $rows }
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId ([long]$Timer.ChatId) -MessageId $MessageId -Text $text -ReplyMarkup $markup)) { return }
    Send-TelegramMessage -ChatId ([long]$Timer.ChatId) -Text $text -ReplyMarkup $markup
}

function Update-AutoHideQueue {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    $due = @($script:AutoHideQueue | Where-Object {
        [datetimeoffset]$_.At -le $Now -and
        (-not (Get-JsonProp $_ 'RetryAt') -or [datetimeoffset]$_.RetryAt -le $Now)
    })
    foreach ($item in $due) {
        try {
            $decision = Get-AutoHideTargetDecision -Timer $item
            if ($decision.ShouldHide -and [bool](Get-JsonProp $item 'ActiveIdConfirmed')) {
                $liveStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
                    -AirChannelNumber $config.AirChannelNumber -Layer ([int]$item.Layer) `
                    -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
                if (-not $liveStatus -or -not [bool](Get-JsonProp $liveStatus 'Success')) { throw 'Cinegy status unavailable' }
                $decision = Get-AutoHideTargetDecision -Timer $item -LiveStatus $liveStatus
            }
            if ($decision.ShouldHide -and (Get-Setting 'TemplateAirExtensionEnabled') -and
                -not [bool](Get-JsonProp $item 'ExtensionUsed') -and -not (Get-JsonProp $item 'Stage')) {
                $key = [string](Get-JsonProp $item 'TemplateKey')
                $cap = 0
                [int]::TryParse([string](Get-JsonProp (Get-Setting 'TemplateMaxAirSeconds') $key), [ref]$cap) | Out-Null
                $sensitive = @([string](Get-Setting 'SensitiveTemplateKeys') -split '[,;
\n]+' | ForEach-Object { $_.Trim() }) -contains $key
                $live = $script:OnAir[[int]$item.Layer]
                $shownAt = [datetimeoffset]::MinValue
                if ($cap -gt 0 -and -not $sensitive -and
                    [datetimeoffset]::TryParse([string](Get-JsonProp $live 'At'), [ref]$shownAt) -and
                    [datetimeoffset]$item.At -ge $shownAt.AddSeconds($cap)) {
                    $item.Stage = 'offer'
                    $item.Token = [guid]::NewGuid().ToString('N').Substring(0,12)
                    $item.ShowAt = $shownAt.ToString('o')
                    $item.At = $Now.AddSeconds([math]::Clamp((Get-SettingInt 'TemplateAirExtensionResponseSeconds' 5),5,120))
                    $item.Choice = [math]::Min(300,(Get-SettingInt 'TemplateAirExtensionMaxSeconds' 60))
                    if (-not (Save-AutoHideQueue)) {
                        $item.Stage = 'hide'; $item.At = $Now
                        throw 'Could not persist extension offer'
                    }
                    Show-TemplateAirExtensionOffer -Timer $item
                    continue
                }
            }
            if (-not $decision.ShouldHide) {
                Write-BridgeLog "Skipped stale auto-hide timer on layer $($item.Layer): $($decision.Reason)" 'WARN'
                Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⚠️ لم يُنفَّذ المؤقت للطبقة $($item.Layer): $($decision.Reason)"
            }
            if ($decision.ShouldHide) {
                if (-not (Invoke-HideLayer -Layer ([int]$item.Layer) -ChatId ([long]$item.ChatId) -UserId ([long]$item.UserId) -Quiet)) {
                    throw 'Hide not confirmed'
                }
            }
            $script:AutoHideQueue.Remove($item) | Out-Null
            if (-not (Save-AutoHideQueue)) {
                if (-not $script:AutoHideQueue.Contains($item)) { $script:AutoHideQueue.Add($item) }
                throw 'Could not persist timer settlement'
            }
            if ($decision.ShouldHide) { Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⏱ تم الإخفاء التلقائي للطبقة $($item.Layer)." }
        }
        catch {
            $item.RetryCount = [math]::Min(6, (1 + [int](Get-JsonProp $item 'RetryCount')))
            $item.RetryAt = $Now.AddSeconds([math]::Min(60, 5 * [math]::Pow(2, $item.RetryCount - 1)))
            $noticeAt = Get-JsonProp $item 'NoticeAt'
            if (-not $noticeAt -or $Now -ge ([datetimeoffset]$noticeAt).AddMinutes(1)) {
                $item.NoticeAt = $Now
                Write-BridgeLog "Auto-hide retained for retry on layer $($item.Layer): $($_.Exception.Message)" 'WARN'
                try { Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⚠️ تعذّر تأكيد الإخفاء للطبقة $($item.Layer). ستتكرر المحاولة؛ تحقّق من الهواء." }
                catch { Write-BridgeLog "Could not deliver the auto-hide retry notice for layer $($item.Layer): $($_.Exception.Message)" 'WARN' }
            }
            Save-AutoHideQueue | Out-Null
        }
    }
}

function Save-TemplateReminderQueue {
    try {
        $payload = @($script:TemplateReminderQueue | ForEach-Object {
                [ordered]@{
                    ReminderId  = [string](Get-JsonProp $_ 'ReminderId')
                    Stage       = [string](Get-JsonProp $_ 'Stage')
                    Layer       = [int](Get-JsonProp $_ 'Layer')
                    At          = ([datetimeoffset](Get-JsonProp $_ 'At')).ToString('o')
                    ChatId      = [long](Get-JsonProp $_ 'ChatId')
                    UserId      = [long](Get-JsonProp $_ 'UserId')
                    TemplateKey = [string](Get-JsonProp $_ 'TemplateKey')
                    ActiveId    = [string](Get-JsonProp $_ 'ActiveId')
                    ActiveIdConfirmed = [bool](Get-JsonProp $_ 'ActiveIdConfirmed')
                    Minutes     = [int](Get-JsonProp $_ 'Minutes')
                    FollowUpMinutes = [int](Get-JsonProp $_ 'FollowUpMinutes')
                }
            })
        $json = ConvertTo-Json -InputObject $payload -Depth 4
        if (-not (Write-ValidatedJsonState -Path $script:templateReminderFile -Json $json)) { throw 'validated state write failed' }
        return $true
    }
    catch {
        Write-BridgeLog "Could not write template-reminders.json: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Import-TemplateReminderQueue {
    try {
        $read = Read-ValidatedJsonState -Path $script:templateReminderFile -AsHashtable
        if (-not $read) { return }
        $restored = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($raw in @($read.Data)) {
            $layer = 0; $minutes = 0; $at = [datetimeoffset]::MinValue
            if (-not $raw -or
                -not [int]::TryParse([string](Get-JsonProp $raw 'Layer'), [ref]$layer) -or $layer -le 0 -or
                -not [int]::TryParse([string](Get-JsonProp $raw 'Minutes'), [ref]$minutes) -or $minutes -le 0 -or $minutes -gt 1440 -or
                -not [datetimeoffset]::TryParse([string](Get-JsonProp $raw 'At'), [ref]$at)) { continue }
            $reminderId = [string](Get-JsonProp $raw 'ReminderId')
            if ([string]::IsNullOrWhiteSpace($reminderId)) { $reminderId = ([guid]::NewGuid().ToString('N')).Substring(0, 12) }
            $stage = [string](Get-JsonProp $raw 'Stage')
            if ($stage -notin @('initial', 'followup')) { $stage = 'initial' }
            $restored.Add(@{
                    ReminderId = $reminderId; Stage = $stage
                    Layer = $layer; At = $at; ChatId = [long](Get-JsonProp $raw 'ChatId'); UserId = [long](Get-JsonProp $raw 'UserId')
                    TemplateKey = [string](Get-JsonProp $raw 'TemplateKey'); ActiveId = [string](Get-JsonProp $raw 'ActiveId'); Minutes = $minutes
                    ActiveIdConfirmed = [bool](Get-JsonProp $raw 'ActiveIdConfirmed')
                    FollowUpMinutes = [int](Get-JsonProp $raw 'FollowUpMinutes')
                })
        }
        $script:TemplateReminderQueue = $restored
        Write-BridgeLog "Restored $($script:TemplateReminderQueue.Count) personal template reminder(s) from template-reminders.json."
    }
    catch { Write-BridgeLog "Could not read template-reminders.json: $($_.Exception.Message)" 'WARN' }
}

function Remove-TemplateRemindersForLayer {
    param([Parameter(Mandatory)][int]$Layer)
    $removed = $false
    for ($i = $script:TemplateReminderQueue.Count - 1; $i -ge 0; $i--) {
        if ([int](Get-JsonProp $script:TemplateReminderQueue[$i] 'Layer') -eq $Layer) {
            $script:TemplateReminderQueue.RemoveAt($i)
            $removed = $true
        }
    }
    if ($removed) { Save-TemplateReminderQueue | Out-Null }
    return $removed
}

function Set-TemplateReminder {
    param(
        [Parameter(Mandatory)][hashtable]$Template,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [string]$ActiveId = '',
        [bool]$ActiveIdConfirmed = $false
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $layer = [int](Get-JsonProp $Template 'Layer')
    $minutes = [int](Get-JsonProp $Template 'ReminderMinutes')
    if ($layer -le 0) { return $false }
    $previous = @($script:TemplateReminderQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq $layer })
    for ($i = $script:TemplateReminderQueue.Count - 1; $i -ge 0; $i--) {
        if ([int](Get-JsonProp $script:TemplateReminderQueue[$i] 'Layer') -eq $layer) { $script:TemplateReminderQueue.RemoveAt($i) }
    }
    if ([bool](Get-JsonProp $Template 'LongRunning') -or $minutes -le 0) {
        if (Save-TemplateReminderQueue) { return $false }
        foreach ($item in $previous) { $script:TemplateReminderQueue.Add($item) }
        return $false
    }
    $script:TemplateReminderQueue.Add(@{
            # Deliver to the person who launched the template, not to the
            # originating group. In a private chat both ids are identical.
            ReminderId = ([guid]::NewGuid().ToString('N')).Substring(0, 12); Stage = 'initial'
            Layer = $layer; At = [datetimeoffset]::Now.AddMinutes($minutes); ChatId = $UserId; UserId = $UserId
            TemplateKey = [string](Get-JsonProp $Template 'Key'); ActiveId = $ActiveId; Minutes = $minutes
            ActiveIdConfirmed = $ActiveIdConfirmed; FollowUpMinutes = 0
        })
    if (Save-TemplateReminderQueue) { return $true }
    $script:TemplateReminderQueue.RemoveAt($script:TemplateReminderQueue.Count - 1)
    foreach ($item in $previous) { $script:TemplateReminderQueue.Add($item) }
    Save-TemplateReminderQueue | Out-Null
    return $false
}

function Get-TemplateReminderTargetDecision {
    param([Parameter(Mandatory)][hashtable]$Reminder)
    $layer = [int](Get-JsonProp $Reminder 'Layer')
    if (-not $script:OnAir.ContainsKey($layer)) { return [pscustomobject]@{ ShouldNotify = $false; Reason = 'لم تعد الطبقة على الهواء.' } }
    $current = $script:OnAir[$layer]
    $savedId = [string](Get-JsonProp $Reminder 'ActiveId')
    $currentId = [string](Get-JsonProp $current 'ActiveId')
    if ($savedId -and $currentId -and -not $savedId.Trim().Trim('{', '}').Equals($currentId.Trim().Trim('{', '}'), [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ShouldNotify = $false; Reason = 'تغيّر المشهد على الطبقة.' }
    }
    $savedKey = [string](Get-JsonProp $Reminder 'TemplateKey')
    $currentKey = [string](Get-JsonProp $current 'Key')
    if ($savedKey -and $currentKey -and -not $savedKey.Equals($currentKey, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ ShouldNotify = $false; Reason = 'تغيّر القالب على الطبقة.' }
    }
    $store = Get-TemplateStore
    if ($store.Map.ContainsKey($savedKey)) {
        $template = $store.Map[$savedKey]
        if ([bool](Get-JsonProp $template 'LongRunning')) {
            return [pscustomobject]@{ ShouldNotify = $false; Reason = 'القالب أصبح Long run.' }
        }
        if ([int](Get-JsonProp $template 'ReminderMinutes') -le 0) {
            return [pscustomobject]@{ ShouldNotify = $false; Reason = 'أُوقف تنبيه الظهور للقالب.' }
        }
    }
    return [pscustomobject]@{ ShouldNotify = $true; Reason = '' }
}

function Update-TemplateReminderQueue {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    if ($script:TemplateReminderQueue.Count -eq 0) { return }
    foreach ($item in @($script:TemplateReminderQueue | Where-Object { [datetimeoffset](Get-JsonProp $_ 'At') -le $Now })) {
        $index = $script:TemplateReminderQueue.IndexOf($item)
        $script:TemplateReminderQueue.RemoveAt($index)
        if (-not (Save-TemplateReminderQueue)) {
            $script:TemplateReminderQueue.Insert($index, $item)
            Write-BridgeLog "Deferred due personal reminder '$([string](Get-JsonProp $item 'ReminderId'))': could not persist queue consumption." 'WARN'
            continue
        }
        $decision = Get-TemplateReminderTargetDecision -Reminder $item
        if (-not $decision.ShouldNotify) {
            Write-BridgeLog "Discarded personal reminder for '$($item.TemplateKey)' on layer $($item.Layer): $($decision.Reason)"
            continue
        }
        $stage = [string](Get-JsonProp $item 'Stage')
        if ($stage -eq 'followup') {
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "🔔 متابعة: لم يتم تأكيد معالجة تنبيه '$($item.TemplateKey)' على الطبقة $($item.Layer)، وما زال ظاهرًا."
            Write-BridgeLog "Sent personal reminder follow-up for '$($item.TemplateKey)' to user $($item.UserId)."
            continue
        }
        $reminderId = [string](Get-JsonProp $item 'ReminderId')
        if ([string]::IsNullOrWhiteSpace($reminderId)) { $reminderId = ([guid]::NewGuid().ToString('N')).Substring(0, 12); $item.ReminderId = $reminderId }
        $onAirCopy = ''
        $remainingText = ''
        if ($script:OnAir.ContainsKey([int]$item.Layer)) {
            $onAirCopy = [string](Get-JsonProp $script:OnAir[[int]$item.Layer] 'AirCopy')
            $pending = @($script:AutoHideQueue | Where-Object { [int]$_.Layer -eq [int]$item.Layer })
            if ($pending.Count -gt 0) {
                $remainingSec = [int](($pending[0].At - (Get-Date)).TotalSeconds)
                if ($remainingSec -gt 0) {
                    $remainingText = "`n⏱ يتبقى $(Get-ArabicCountNoun -Count $remainingSec -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية')"
                }
            }
        }
        $reminderText = "⏰ تنبيه: مرّ $(Get-ArabicCountNoun -Count $item.Minutes -One 'دقيقة' -Two 'دقيقتان' -Few 'دقائق' -Many 'دقيقة') منذ إظهار '$($item.TemplateKey)' على الطبقة $($item.Layer)، وما زال ظاهرًا.$remainingText"
        if (-not [string]::IsNullOrWhiteSpace($onAirCopy)) {
            $reminderText += "`n📝 النص: $onAirCopy"
        }
        $ackKeyboard = @{ inline_keyboard = @(, @((New-Button '⏰ ذكّرني لاحقًا' "remsnooze:$reminderId"), (New-Button '🙈 إخفاء القالب' "hidego:$($item.Layer)"))) }
        Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text $reminderText -ReplyMarkup $ackKeyboard
        Write-BridgeLog "Sent personal reminder for '$($item.TemplateKey)' to user $($item.UserId)."
        $followUpMinutes = [math]::Min(1440, (Get-SettingInt 'TemplateReminderFollowUpMinutes' 0))
        if ($followUpMinutes -gt 0) {
            $item.Stage = 'followup'
            $item.FollowUpMinutes = $followUpMinutes
            $item.At = $Now.AddMinutes($followUpMinutes)
            $script:TemplateReminderQueue.Add($item)
            Save-TemplateReminderQueue | Out-Null
        }
    }
}

function Confirm-TemplateReminder {
    param(
        [Parameter(Mandatory)][string]$ReminderId,
        [Parameter(Mandatory)][long]$UserId,
        [ref]$FailureReason
    )
    if ($null -ne $FailureReason) { $FailureReason.Value = '' }
    $item = @($script:TemplateReminderQueue | Where-Object {
            [string](Get-JsonProp $_ 'ReminderId') -eq $ReminderId -and [long](Get-JsonProp $_ 'UserId') -eq $UserId
        } | Select-Object -First 1)
    if ($item.Count -eq 0) {
        if ($null -ne $FailureReason) { $FailureReason.Value = 'not_found' }
        return $false
    }
    $index = $script:TemplateReminderQueue.IndexOf($item[0])
    $script:TemplateReminderQueue.RemoveAt($index)
    if (-not (Save-TemplateReminderQueue)) {
        $script:TemplateReminderQueue.Insert($index, $item[0])
        if ($null -ne $FailureReason) { $FailureReason.Value = 'persistence' }
        Write-BridgeLog "Could not persist acknowledgement for personal template reminder '$ReminderId'; restored pending follow-up." 'WARN'
        return $false
    }
    Write-BridgeLog "User $UserId acknowledged personal template reminder '$ReminderId'."
    return $true
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

function Get-BridgeStatsBlocks {
    <#
        The operating numbers as a real table, label against value.

        This screen never had a rich version at all - it was text however the
        text was formatted, which is why it stayed unlike every other screen
        no matter how the lines were arranged. A label-and-value list is a
        two-column table by nature: the figures belong under each other rather
        than at the end of sentences of different lengths.

        The verdict is a paragraph above the table for the same reason it
        leads the text version: this screen is opened because something feels
        off, and the answer should not have to be assembled from nine rows.
    #>
    $now = Get-Date
    $uptime = $now - $script:BridgeStartedAt
    $counters = $script:AirOperationCounters
    $total = [int]$counters.Success + [int]$counters.Failed + [int]$counters.Blocked
    $verdict = if ($uptime.TotalMinutes -lt 15) { '🟠 التشغيل حديث — قد يكون الجسر يُعاد تشغيله' }
    elseif ([int]$script:TelegramRateLimitHits -gt 0) { '🟠 تيليجرام يحدّ من الإرسال' }
    else { '🟢 تشغيل مستقر' }
    $lastBeat = if ($script:LastHeartbeatDate -gt [datetime]::MinValue) { $script:LastHeartbeatDate.ToString('yyyy-MM-dd') } else { 'لم تُرسل بعد' }

    $rows = @(
        , @('⏱ مدة التشغيل', "$([int]$uptime.TotalDays) ي $($uptime.Hours) س $($uptime.Minutes) د")
        , @('📅 منذ', $script:BridgeStartedAt.ToString('yyyy-MM-dd HH:mm:ss'))
        , @('🎬 عمليات الهواء', "$total  (✅ $($counters.Success) · ❌ $($counters.Failed) · ⛔ $($counters.Blocked))")
        , @('🚦 حدّ تيليجرام (429)', [string]$script:TelegramRateLimitHits)
        , @('📭 أُسقطت من الطابور', [string]$script:TelegramOutboxDropped)
        , @('📡 اتصال Telegram', [string]$script:RuntimeState.Monitoring.TelegramConnectionState)
        , @('🎛 صحة Cinegy', [string]$script:RuntimeState.Monitoring.CinegyHealthState)
        , @('💚 آخر نبضة يومية', $lastBeat)
        , @('🔴 مشاهد على الهواء', [string]$script:OnAir.Count)
    )
    # What is closest to losing its table. A screen crosses the payload limit
    # gradually as the station's day fills up, and until this line the first
    # to know was the operator whose table had already vanished.
    $peak = Get-RichPayloadPeak
    if ($peak.Length -gt 0) {
        $rows += , @('📐 أكبر شاشة أُرسلت', "$($peak.Percent)% من الحدّ · $($peak.Screen)")
    }
    $cells = @(, @(@{ text = 'البند'; is_header = $true }, @{ text = 'القيمة'; is_header = $true }))
    foreach ($row in $rows) { $cells += , @(@{ text = [string]$row[0] }, @{ text = [string]$row[1] }) }

    return @(
        @{ type = 'heading'; text = "📈 أرقام التشغيل — v$script:BridgeVersion"; size = 3 }
        @{ type = 'paragraph'; text = "🕒 $($now.ToString('yyyy-MM-dd HH:mm:ss')) (محلي)" }
        @{ type = 'paragraph'; text = $verdict }
        @{ type = 'table'; cells = $cells }
    )
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
    # parse_mode=HTML. Uptime is the number this screen exists for - a bridge
    # up for eleven minutes has been restarting - so it leads in bold, and
    # every figure is a <code> span: monospace keeps the digits left-to-right
    # against the Arabic, and Telegram makes each tap-to-copy for an
    # administrator quoting them in a fault report.
    #
    # Bold and code sit side by side, never one inside the other: the two
    # cannot be combined on the same characters and the API refuses the whole
    # message if they are.
    # A verdict first, like ℹ️ الحالة and 📊 الحالة الكاملة. This screen was
    # figures only: an administrator opening it because "something feels off"
    # had to already know what a bad number looks like before the screen could
    # answer them. It is judged on uptime, because that is what this screen
    # exists to show - a bridge up for eleven minutes has been restarting -
    # with Telegram's flood limit beside it, the other thing that is wrong
    # while every individual figure still looks ordinary.
    $verdict = if ($uptime.TotalMinutes -lt 15) { '🟠 التشغيل حديث — قد يكون الجسر يُعاد تشغيله' }
    elseif ([int]$script:TelegramRateLimitHits -gt 0) { '🟠 تيليجرام يحدّ من الإرسال' }
    else { '🟢 تشغيل مستقر' }

    $peakMeasurement = Get-RichPayloadPeak
    $peakLine = if ($peakMeasurement.Length -gt 0) {
        "`n📐 أكبر شاشة أُرسلت — $($peakMeasurement.Percent)% من الحدّ · $(ConvertTo-TelegramHtmlText $peakMeasurement.Screen)"
    }
    else { '' }
    $lines.Add("<b>📈 أرقام التشغيل</b> — <code>v$($script:BridgeVersion)</code>")
    $lines.Add("🕒 <code>$($now.ToString('yyyy-MM-dd HH:mm:ss'))</code> (محلي)")
    $lines.Add("<b>$verdict</b>")
    $lastBeat = if ($script:LastHeartbeatDate -gt [datetime]::MinValue) { $script:LastHeartbeatDate.ToString('yyyy-MM-dd') } else { 'لم تُرسل بعد' }

    # Full-size text, each line opening with its own glyph. A <pre> table
    # aligns the values into a column and Telegram draws it two sizes down;
    # on a phone that trade goes the wrong way, and the reports screens - the
    # ones that read well - never used one.
    #
    # The three an administrator opens this screen for come first and alone;
    # the rest is quoted underneath as the detail behind them.
    $lines.Add('')
    $lines.Add("⏱ <b>مدة التشغيل</b> — $([int]$uptime.TotalDays) ي $($uptime.Hours) س $($uptime.Minutes) د")
    $lines.Add("📅 <b>منذ</b> — $($script:BridgeStartedAt.ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add("🎬 <b>عمليات الهواء</b> — $total · ✅ $($counters.Success) · ❌ $($counters.Failed) · ⛔ $($counters.Blocked)")
    $lines.Add('')
    $lines.Add("<blockquote>🚦 حدّ تيليجرام (429) — $($script:TelegramRateLimitHits)
📭 رسائل أُسقطت من الطابور — $($script:TelegramOutboxDropped)
📡 اتصال Telegram — $(ConvertTo-TelegramHtmlText ([string]$script:RuntimeState.Monitoring.TelegramConnectionState))
🎛 صحة Cinegy — $(ConvertTo-TelegramHtmlText ([string]$script:RuntimeState.Monitoring.CinegyHealthState))
💚 آخر نبضة يومية — $lastBeat
🔴 مشاهد على الهواء — $($script:OnAir.Count)$peakLine</blockquote>")
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
    # Reads back into the archives when the active file is short. Without
    # this the first digest after a rotation would report an empty morning:
    # the history did not go anywhere, it only changed file.
    $lines = @()
    if (Test-Path -LiteralPath $script:auditFile) {
        $lines = @(Get-Content -LiteralPath $script:auditFile -Tail $MaxLines -ErrorAction SilentlyContinue)
    }
    if ($lines.Count -lt $MaxLines) {
        foreach ($archive in @(Get-AuditArchiveFiles)) {
            $needed = $MaxLines - $lines.Count
            if ($needed -le 0) { break }
            $lines = @(@(Get-Content -LiteralPath $archive.FullName -Tail $needed -ErrorAction SilentlyContinue)) + $lines
        }
    }

    $records = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    }
    return @($records)
}

function Get-AuditOperatorName {
    <# Audit user ids arrive as strings and are sometimes absent. Returns an
       empty string rather than a misleading "0" so callers can omit the name
       instead of naming nobody. #>
    param([string]$UserId)
    $parsed = 0L
    if (-not [long]::TryParse($UserId, [ref]$parsed) -or $parsed -eq 0) { return '' }
    return [string](Get-UserDisplayName -UserId $parsed)
}

function Get-OperatorTally {
    <# Who did it, and how many each. One operator is named inline; several are
       broken down, because "20×" alone does not tell a supervisor taking over
       whether one person was busy or four collided on the same graphic. #>
    param([object[]]$Records)
    $byUser = @(@($Records) | Group-Object -Property UserId | Sort-Object Count -Descending)
    $named = @($byUser | Where-Object { Get-AuditOperatorName -UserId ([string]$_.Name) })
    if ($named.Count -eq 0) { return @{ Single = ''; Breakdown = '' } }
    if ($named.Count -eq 1) {
        return @{ Single = (Get-AuditOperatorName -UserId ([string]$named[0].Name)); Breakdown = '' }
    }
    $parts = foreach ($entry in $named) {
        "$(Get-AuditOperatorName -UserId ([string]$entry.Name)) $($entry.Count)"
    }
    return @{ Single = ''; Breakdown = ($parts -join ' · ') }
}

function Get-MissedEventsBlocks {
    <#
        The handover screen as blocks, with what is on air FIRST.

        The text version ends on it, after the shows, the removals, the
        notable activity and the failures. That is the wrong order for the
        one screen somebody opens while walking into a gallery: the first
        question is always what is on the screen right now, and it was the
        last line they reached.

        Failures stay open for the same reason - a failure is usually why
        this screen was opened at all - while the general activity, read only
        when something needs tracing, folds away.
    #>
    param([int]$Hours = 12, [AllowNull()][object[]]$Records = $null)
    # Wrapped around the whole if: the expression emits its result to the
    # pipeline, which unwraps a one-item array back to a scalar, and .Count
    # on that throws under StrictMode.
    $records = @(if ($null -ne $Records) { $Records } else { Get-MissedEventsRecords -Hours $Hours })

    $blocks = @(@{ type = 'heading'; text = "🕘 ماذا فاتني — آخر $Hours ساعة"; size = 3 })
    # On air first: it is the question this screen is opened to answer.
    $blocks += @{ type = 'paragraph'; text = $(if ($script:OnAir.Count -eq 0) { '⚫️ لا شيء على الهواء الآن' }
            else { "🔴 على الهواء: $(@($script:OnAir.Keys | Sort-Object | ForEach-Object { $script:OnAir[$_].Key }) -join '، ')" }) }
    $blocks += @{ type = 'divider' }

    if ($records.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لا شيء مسجّل في هذه الفترة.' }
        return $blocks
    }

    $airOps = @($records | Where-Object { $_.Action -in @('SHOW', 'HIDE', 'EXIT') })
    $shows = @($airOps | Where-Object { $_.Action -eq 'SHOW' -and $_.Target })
    if ($shows.Count -gt 0) {
        $blocks += @{ type = 'heading'; text = "📺 ما عُرض — $($shows.Count)"; size = 5 }
        # Four columns, as everywhere else here: the width is divided evenly,
        # so a fifth would cost the graphic's name a fifth of the screen.
        $cells = @(, @(
                @{ text = 'القالب'; is_header = $true }
                @{ text = 'مرات'; is_header = $true }
                @{ text = 'آخرها'; is_header = $true }
                @{ text = 'المشغّل'; is_header = $true }
            ))
        foreach ($group in ($shows | Group-Object -Property Target | Sort-Object Count -Descending | Select-Object -First 8)) {
            $tally = Get-OperatorTally -Records @($group.Group)
            $who = if ($tally.Breakdown) { [string]$tally.Breakdown } elseif ($tally.Single) { [string]$tally.Single } else { '—' }
            $cells += , @(
                @{ text = [string]$group.Name }
                @{ text = [string]$group.Count }
                @{ text = @($group.Group)[-1].When.ToString('HH:mm') }
                @{ text = $who }
            )
        }
        $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    }

    $removals = @($airOps | Where-Object { $_.Action -in @('HIDE', 'EXIT') })
    if ($removals.Count -gt 0) {
        $newest = @($removals)[-1]
        $lastWho = Get-AuditOperatorName -UserId $newest.UserId
        $line = "🙈 إخفاء وخروج: $($removals.Count) — آخرها $($newest.When.ToString('HH:mm'))"
        if ($lastWho) { $line += " — $lastWho" }
        $blocks += @{ type = 'paragraph'; text = $line }
    }

    # Failures stay open: they are usually why the screen was opened.
    $failures = @($records | Where-Object { $_.Result -eq 'failed' })
    $blocked = @($records | Where-Object { $_.Result -eq 'blocked' })
    if ($failures.Count -gt 0 -or $blocked.Count -gt 0) {
        $blocks += @{ type = 'heading'; text = "⚠️ فشل: $($failures.Count) · مرفوض: $($blocked.Count)"; size = 5 }
        foreach ($failure in @($failures | Select-Object -Last 3)) {
            $detail = if ($failure.Message) { $failure.Message } else { 'بلا تفصيل' }
            $blocks += @{ type = 'paragraph'; text = "$($failure.When.ToString('HH:mm')) — $($failure.Action) $($failure.Target): $detail" }
        }
    }

    $activity = @($records | Where-Object { -not $_.Action -and $_.Message })
    $notable = @($activity | Where-Object { $_.Message -match '📰|⚙️|👤|🔓|🚨|♻️' })
    if ($notable.Count -gt 0) {
        $inner = @(@($notable | Select-Object -Last 8) | ForEach-Object {
                @{ type = 'paragraph'; text = "$($_.When.ToString('HH:mm')) — $($_.Message)" }
            })
        $blocks += @{ type = 'details'; summary = "📌 أحداث تستحق الانتباه ($($notable.Count))"; blocks = $inner }
    }

    $blocks += @{ type = 'divider' }
    $blocks += @{ type = 'paragraph'; text = "Cinegy: $($script:RuntimeState.Monitoring.CinegyHealthState) · Telegram: $($script:RuntimeState.Monitoring.TelegramConnectionState)" }
    return $blocks
}

function Get-MissedEventsRecords {
    <# The window's audit records, normalised. Extracted so the text screen
       and the block screen read exactly the same set - two readers of one
       log that filter it separately are two answers waiting to disagree. #>
    param([int]$Hours = 12)
    $since = (Get-Date).ToUniversalTime().AddHours(-[math]::Max(1, $Hours))
    return @(Read-AuditRecords -MaxLines 1500 | ForEach-Object {
            $record = $_
            $when = Read-AuditRecordStamp -Record $record
            if (-not $when -or $when.ToUniversalTime() -lt $since) { return }
            [pscustomobject]@{
                When    = $when
                Action  = (Get-AuditRecordField -Record $record -Name 'action')
                Target  = (Get-AuditRecordField -Record $record -Name 'target')
                Result  = (Get-AuditRecordField -Record $record -Name 'result')
                Message = (Get-AuditRecordField -Record $record -Name 'message')
                UserId  = (Get-AuditRecordField -Record $record -Name 'userId')
            }
        })
}

function Get-MissedEventsText {
    <#
        What happened while nobody was looking.

        The first version counted verbs - "SHOW 23, other 73" - which tells an
        operator taking over a shift nothing: not which graphic, not who, not
        when, and the largest bucket was simply everything without an action
        field. This answers what is actually asked at a handover: what went to
        air, who did it, what failed, and what is up right now.
    #>
    param([int]$Hours = 12)
    # One reader for both screens: records are written by a dozen call
    # sites and carry only the fields each cares about, so under StrictMode
    # a record without an "action" key would take down the whole digest -
    # which is exactly the screen opened when something has already gone
    # wrong. Two readers filtering one log separately are two answers
    # waiting to disagree.
    $records = @(Get-MissedEventsRecords -Hours $Hours)

    # parse_mode=HTML. This is the screen an operator opens at handover, and
    # it was one flat column of forty-odd lines with two rows of "━━━" drawn
    # across it. The section headings are bold so the four questions it
    # answers - what went to air, what came off, what is worth knowing, what
    # failed - can be found without reading every line, and each clock time is
    # a <code> span so the digits stay left-to-right beside the Arabic.
    #
    # Everything a person typed is escaped: template names, operator display
    # names, and the audit messages, which are free text from a dozen call
    # sites.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>🕘 ماذا فاتني</b> — آخر <code>$Hours</code> ساعة")
    if ($records.Count -eq 0) {
        $lines.Add('<i>لا شيء مسجّل في هذه الفترة.</i>')
        return ($lines -join "`n")
    }



    # Grouped by graphic rather than by verb: an operator cares which template
    # moved, not that eleven HIDEs happened to something unnamed.
    $airOps = @($records | Where-Object { $_.Action -in @('SHOW', 'HIDE', 'EXIT') })
    $shows = @($airOps | Where-Object { $_.Action -eq 'SHOW' -and $_.Target })
    if ($shows.Count -gt 0) {
        $operatorCount = @($shows | Group-Object -Property UserId).Count
        $lines.Add('')
        $header = "<b>📺 ما عُرض</b> — <code>$($shows.Count)</code> عرضًا"
        if ($operatorCount -gt 1) { $header += " · <code>$operatorCount</code> مشغّلين" }
        $lines.Add($header)
        foreach ($group in ($shows | Group-Object -Property Target | Sort-Object Count -Descending | Select-Object -First 6)) {
            $newest = @($group.Group)[-1]
            $stampText = $newest.When.ToString('HH:mm')
            $times = if ($group.Count -gt 1) { "<code>$($group.Count)×</code> · آخرها <code>$stampText</code>" } else { "<code>$stampText</code>" }
            $tally = Get-OperatorTally -Records @($group.Group)
            $target = ConvertTo-TelegramHtmlText ([string]$group.Name)
            if ($tally.Breakdown) {
                # Several people touched the same graphic: "20×" alone hides
                # whether one operator was busy or four collided on it.
                $lines.Add("• <b>$target</b> — $times")
                $lines.Add("   ↳ <i>$(ConvertTo-TelegramHtmlText ([string]$tally.Breakdown))</i>")
            }
            else {
                $lines.Add("• <b>$target</b> — $times — <i>$(ConvertTo-TelegramHtmlText ([string]$tally.Single))</i>")
            }
        }
    }

    $removals = @($airOps | Where-Object { $_.Action -in @('HIDE', 'EXIT') })
    if ($removals.Count -gt 0) {
        $newest = @($removals)[-1]
        $lastWho = Get-AuditOperatorName -UserId $newest.UserId
        $line = "<b>🙈 إخفاء وخروج</b>: <code>$($removals.Count)</code> — آخرها <code>$($newest.When.ToString('HH:mm'))</code>"
        if ($lastWho) { $line += " — <i>$(ConvertTo-TelegramHtmlText ([string]$lastWho))</i>" }
        $lines.Add($line)
        $removalTally = Get-OperatorTally -Records $removals
        if ($removalTally.Breakdown) { $lines.Add("   ↳ <i>$(ConvertTo-TelegramHtmlText ([string]$removalTally.Breakdown))</i>") }
    }

    # Activity lines are already written for a human, so they are shown rather
    # than counted.
    $activity = @($records | Where-Object { -not $_.Action -and $_.Message })
    $notable = @($activity | Where-Object { $_.Message -match '📰|⚙️|👤|🔓|🚨|♻️' })
    if ($notable.Count -gt 0) {
        $lines.Add('')
        $lines.Add('<b>📌 أحداث تستحق الانتباه</b>')
        # A blockquote, because this is quoted material - lines the bridge
        # wrote elsewhere, shown here rather than summarised. Telegram draws
        # the bar, which is what marks them as not this screen's own words.
        $noted = @(@($notable | Select-Object -Last 5) | ForEach-Object {
                "• <code>$($_.When.ToString('HH:mm'))</code> — $(ConvertTo-TelegramHtmlText ([string]$_.Message))"
            })
        $lines.Add("<blockquote>$($noted -join "`n")</blockquote>")
    }

    $failures = @($records | Where-Object { $_.Result -eq 'failed' })
    $blocked = @($records | Where-Object { $_.Result -eq 'blocked' })
    if ($failures.Count -gt 0 -or $blocked.Count -gt 0) {
        $lines.Add('')
        # Kept apart on purpose: a rejection is a permission answer and a
        # failure is a fault, and they were one number until 7.68.0.
        # Bold and code side by side rather than nested: the two cannot be
        # combined on the same characters, and Telegram refuses the whole
        # message rather than dropping one of them.
        $lines.Add("<b>⚠️ فشل:</b> <code>$($failures.Count)</code> · <b>مرفوض:</b> <code>$($blocked.Count)</code>")
        foreach ($failure in @($failures | Select-Object -Last 3)) {
            $detail = if ($failure.Message) { [string]$failure.Message } else { 'بلا تفصيل' }
            $lines.Add("• <code>$($failure.When.ToString('HH:mm'))</code> — $(ConvertTo-TelegramHtmlText ([string]$failure.Action)) <b>$(ConvertTo-TelegramHtmlText ([string]$failure.Target))</b>: $(ConvertTo-TelegramHtmlText $detail)")
        }
    }

    # What is true right now, under everything that already happened - the
    # digest is read at a handover, and the last thing the person taking over
    # needs is the current state, not the history.
    $lines.Add('')
    $nowLine = if ($script:OnAir.Count -eq 0) { '⚫️ لا شيء على الهواء الآن' }
    else {
        $live = @($script:OnAir.Keys | Sort-Object | ForEach-Object { ConvertTo-TelegramHtmlText ([string]$script:OnAir[$_].Key) })
        "🔴 <b>على الهواء</b>: $($live -join '، ')"
    }
    $lines.Add("<blockquote>$nowLine
Cinegy: <code>$(ConvertTo-TelegramHtmlText ([string]$script:RuntimeState.Monitoring.CinegyHealthState))</code> · Telegram: <code>$(ConvertTo-TelegramHtmlText ([string]$script:RuntimeState.Monitoring.TelegramConnectionState))</code></blockquote>")
    return ($lines -join "`n")
}

function Get-TemplateHistoryBlocks {
    <# Who used a template, as a table: when, who, what they did and how it
       ended - four columns the text version separates with dashes. #>
    param([Parameter(Mandatory)][string]$Query, [int]$MaxResults = 10)
    $needle = $Query.Trim()
    if ([string]::IsNullOrWhiteSpace($needle)) { return @() }
    $hits = @(Read-AuditRecords -MaxLines 2000 | Where-Object {
            [string]$_.target -and ([string]$_.target).IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        } | Select-Object -Last $MaxResults)

    $blocks = @(@{ type = 'heading'; text = "👤 من استخدم «$needle»"; size = 3 })
    if ($hits.Count -eq 0) {
        return $blocks + @(@{ type = 'paragraph'; text = 'لا يوجد سجل ضمن ما هو محفوظ.' })
    }
    $cells = @(, @(
            @{ text = 'متى'; is_header = $true }
            @{ text = 'المشغّل'; is_header = $true }
            @{ text = 'العملية'; is_header = $true }
            @{ text = 'النتيجة'; is_header = $true }
        ))
    # Capped like every other table here. This one searches the audit trail,
    # so its length is the station's history rather than anything this screen
    # controls - a template used through a busy month returns a table that
    # crosses the payload limit and loses its rows entirely.
    $trimmed = Select-RichTableRows -Items @($hits)
    foreach ($hit in @($trimmed.Rows)) {
        $stamp = [datetime]::MinValue
        $when = if ([datetime]::TryParse([string]$hit.timestampUtc, [ref]$stamp)) { $stamp.ToLocalTime().ToString('MM-dd HH:mm') } else { '؟' }
        $cells += , @(
            @{ text = $when }
            @{ text = [string](Get-UserDisplayName -UserId ([long]$hit.userId)) }
            @{ text = [string]$hit.action }
            @{ text = [string]$hit.result }
        )
    }
    $blocks += @{ type = 'table'; cells = $cells }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown @($trimmed.Rows).Count
    if ($note) { $blocks += @{ type = 'paragraph'; text = $note } }
    return $blocks
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

    # parse_mode=HTML, and the needle is escaped before anything else: it is
    # typed straight into the chat by whoever ran /who, so it is the most
    # directly person-shaped string on any screen here.
    $needleHtml = ConvertTo-TelegramHtmlText $needle
    if ($hits.Count -eq 0) { return "<i>لا يوجد سجل لاستخدام «$needleHtml» ضمن ما هو محفوظ.</i>" }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>👤 من استخدم «$needleHtml»</b>")
    $lines.Add('')
    foreach ($hit in $hits) {
        $stamp = [datetime]::MinValue
        $when = if ([datetime]::TryParse([string]$hit.timestampUtc, [ref]$stamp)) { $stamp.ToLocalTime().ToString('MM-dd HH:mm') } else { '؟' }
        $lines.Add("• <code>$when</code> — <b>$(ConvertTo-TelegramHtmlText (Get-UserDisplayName -UserId ([long]$hit.userId)))</b> — $(ConvertTo-TelegramHtmlText ([string]$hit.action)) (<i>$(ConvertTo-TelegramHtmlText ([string]$hit.result))</i>)")
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

function Save-ExpiredNewsDraftSnapshot {
    <#
        D3: keeps one resurrection before the draft is destroyed. Items only -
        the lock and base hash are re-taken fresh on resume, because the live
        file may have moved while this draft sat idle. A helper rather than
        inline code: the paging gate reads Update-NewsDraftExpiry's body as
        text and fails any function holding both a keyboard and a loop.
    #>
    param($Draft)
    $items = @(Get-JsonProp $Draft 'Items')
    $copy = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) { $copy.Add([string]$item) }
    $script:ExpiredNewsDraft = @{
        Items = @($copy)
        OwnerUserId = [long](Get-JsonProp $Draft 'OwnerUserId'); OwnerChatId = [long](Get-JsonProp $Draft 'OwnerChatId'); At = (Get-Date)
    }
}

function Update-NewsDraftExpiry {
    <#
        Drops a news draft that has gone stale, and says why.

        A draft records the hash of the live ticker file when it was started,
        and publishing refuses if the file changed since - correctly, because
        publishing would otherwise silently discard whatever was written in
        between. But nothing ever expired the draft, so one left open
        overnight became permanently unpublishable: every attempt was refused
        as a conflict, and the operator saw their edits simply never appear.

        NewsDraftTimeoutMinutes existed as a setting and was read by nothing.
        It is enforced here.
    #>
    $timeout = Get-SettingInt 'NewsDraftTimeoutMinutes' 0
    if ($timeout -le 0) { return }
    $draft = $script:NewsTickerDraft
    if (-not $draft) { return }

    $updatedAt = [datetime]::MinValue
    $stamp = [string](Get-JsonProp $draft 'UpdatedAt')
    if (-not [datetime]::TryParse($stamp, [ref]$updatedAt)) { return }
    $owner = [long](Get-JsonProp $draft 'OwnerChatId')
    # An open draft belongs to nobody, so the warning and the hand-back go to
    # whoever opened it. Without this an unclaimed draft expires in total
    # silence and takes its items with it.
    if ($owner -le 0) { $owner = [long](Get-JsonProp $draft 'HandedOverChatId') }
    $elapsed = ((Get-Date) - $updatedAt).TotalMinutes
    if ($elapsed -lt $timeout) {
        # A warning first, with a way to keep it. This expiry does not drop
        # one half-typed field like the flow watchdog does - it throws away a
        # whole strap, every headline in it, and the editor learns of it only
        # from the message saying how many they just lost. Five minutes'
        # notice is what turns that into a decision.
        $warnAt = [math]::Max(1, [math]::Min(5, [int]($timeout / 4)))
        $warned = [string](Get-JsonProp $draft 'WarnedAt')
        if ($owner -gt 0 -and -not $warned -and ($timeout - $elapsed) -le $warnAt) {
            # Through Set-JsonProp, because the draft is a dictionary here
            # and a PSCustomObject elsewhere. Written with Add-Member it was
            # neither saved nor read back, and this mark is the only thing
            # standing between one warning and one every tick.
            Set-JsonProp -Object $draft -Name 'WarnedAt' -Value ((Get-Date).ToString('o'))
            Save-NewsTickerDraft | Out-Null
            $items = @(Get-JsonProp $draft 'Items')
            Send-TelegramMessage -ChatId $owner -ParseMode HTML -Cause 'news-draft-expiry-warning' `
                -Text "⏳ <b>مسودة الشريط ($($items.Count) خبرًا) على وشك الانتهاء</b>`nستُحذف بعد $(Format-DurationMinutes -Minutes ([int][math]::Ceiling($timeout - $elapsed))) بلا تعديل. مدّدها أو انشرها." `
                -ReplyMarkup @{ inline_keyboard = @(, @((New-Button '⏳ تمديد' 'news:draft:extend'), (New-Button '📰 فتح المسودة' 'news:refresh'))) }
        }
        return
    }

    $items = @(Get-JsonProp $draft 'Items')
    $count = $items.Count
    Save-ExpiredNewsDraftSnapshot -Draft $draft
    Remove-NewsTickerDraft
    Add-AbandonedDraft -Label 'شريط الأخبار'
    Write-BridgeLog "Expired an abandoned news draft ($count item(s), idle for $timeout+ minutes)" 'WARN'
    if ($owner -gt 0) {
        # Raw button shapes, not New-Button: this path runs under strict
        # Get-SettingInt mocks in tests, and two static labels need no
        # length policy anyway.
        $resumeRow = @{ inline_keyboard = @(, @(@{ text = '↩️ استئناف المسودة'; callback_data = 'news:resume' }, @{ text = '⬅️ القائمة'; callback_data = 'menu' })) }
        Send-TelegramMessage -ChatId $owner -Text "⌛ انتهت صلاحية مسودة شريط الأخبار ($count خبرًا) بعد $(Format-DurationMinutes -Minutes $timeout) بلا تعديل، ولم يُنشر شيء.`nابدأ مسودة جديدة لتعمل على النص الحالي." -ReplyMarkup $resumeRow
        # Handed back, not merely counted. An unpublished draft is somebody's
        # work, and telling an operator how many items they just lost is worse
        # than useless. The lock hand-over has returned the text since 5.5,
        # and an expiry destroys exactly as much.
        if ($count -gt 0) {
            $numbered = @(for ($i = 0; $i -lt $count; $i++) { "$($i + 1). $($items[$i])" })
            Send-TelegramPagedText -ChatId $owner -Text ("📝 أخبار المسودة المنتهية، انسخها إن أردت:`n" + ($numbered -join "`n"))
        }
    }
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
    Add-AuditEntry "📝 سبب الإلغاء: $(Get-CancelReasonLabel -Reason $Reason) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Save-CancelReasons | Out-Null
}

function Get-UsageDigestBlocks {
    <#
        The usage summary as tables: a ranking, and how the operations ended.

        A ranking is a table in every sense - a position, a name, a count and
        a date belong under each other rather than at the end of sentences of
        different lengths - and the outcome tally is three labels against
        three numbers.

        Two tables rather than one. They answer different questions - which
        templates carry the work, and how the shift's operations ended - and a
        single table would need a column that means one thing in half its rows
        and something else in the others.

        The scheduled weekly digest keeps the text version. It goes out
        through Send-AdminBroadcast, which holds a non-urgent notice for the
        quiet-hours digest and stores only text, so a table would arrive hours
        later as nothing at all.
    #>
    param([int]$TopCount = 5)
    $now = Get-Date
    $counters = $script:AirOperationCounters
    $total = [int]$counters.Success + [int]$counters.Failed + [int]$counters.Blocked
    $week = Get-ReportRecords -From ($now.Date.AddDays(-6)) -To $now -EventName 'air_control'
    $weeklyOperations = @($week.Records).Count
    $dailyAverage = [math]::Round($weeklyOperations / 7, 1)

    $blocks = @(
        @{ type = 'heading'; text = '📊 ملخص الاستخدام'; size = 3 }
        @{ type = 'paragraph'; text = "🕒 $($now.ToString('yyyy-MM-dd HH:mm')) (محلي)" }
        @{ type = 'paragraph'; text = "🎬 منذ آخر تشغيل: $(Get-ArabicCountNoun -Count $total -One 'عملية' -Two 'عمليتان' -Few 'عمليات' -Many 'عملية') · 📆 آخر 7 أيام: $(Get-ArabicCountNoun -Count $weeklyOperations -One 'عملية' -Two 'عمليتان' -Few 'عمليات' -Many 'عملية') · متوسط $dailyAverage يوميًا" }
    )

    $ranked = @($script:UsageCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopCount)
    if ($ranked.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لم تُستخدم أي قوالب بعد.' }
    }
    else {
        $cells = @(, @(
                @{ text = '#'; is_header = $true }
                @{ text = 'القالب'; is_header = $true }
                @{ text = 'مرات'; is_header = $true }
                @{ text = 'آخر مرة'; is_header = $true }
            ))
        $rank = 0
        foreach ($item in $ranked) {
            $rank++
            $lastUsed = if ($script:TemplateLastUsed.ContainsKey($item.Key)) {
                ([datetime]$script:TemplateLastUsed[$item.Key]).ToLocalTime().ToString('MM-dd HH:mm')
            }
            else { '—' }
            $cells += , @(
                @{ text = [string]$rank }
                @{ text = [string]$item.Key }
                @{ text = [string]$item.Value }
                @{ text = $lastUsed }
            )
        }
        $blocks += @{ type = 'table'; cells = $cells }
    }

    $blocks += @{ type = 'table'; cells = @(
            , @(@{ text = 'النتيجة'; is_header = $true }, @{ text = 'العدد'; is_header = $true })
            , @(@{ text = '✅ ناجحة' }, @{ text = [string]$counters.Success })
            , @(@{ text = '❌ فاشلة' }, @{ text = [string]$counters.Failed })
            , @(@{ text = '⛔ مرفوضة' }, @{ text = [string]$counters.Blocked })
        )
    }
    if ([int]$counters.Failed -gt 0 -or [int]$counters.Blocked -gt 0) {
        $blocks += @{ type = 'paragraph'; text = 'راجع 📜 السجل لمعرفة سبب الفشل أو الرفض.' }
    }

    if ($script:CancelReasons.Count -gt 0) {
        $reasonCells = @(, @(@{ text = 'سبب التراجع'; is_header = $true }, @{ text = 'مرات'; is_header = $true }))
        foreach ($reason in ($script:CancelReasons.Keys | Sort-Object)) {
            $reasonCells += , @(
                @{ text = [string](Get-CancelReasonLabel -Reason $reason) }
                @{ text = [string]$script:CancelReasons[$reason] }
            )
        }
        $blocks += @{ type = 'table'; cells = $reasonCells }
    }
    # T-31 on the on-demand rich path: plain lines, because a table cell
    # cannot hold markup and the names here arrive escaped for HTML already.
    $plainNotices = Get-WeeklyNoticesText -AsPlain
    if ($plainNotices) {
        $blocks += @{ type = 'paragraph'; text = $plainNotices }
    }
    # T-16 on the same path.
    $plainTiming = Get-FlowTimingText -AsPlain
    if ($plainTiming) {
        $blocks += @{ type = 'paragraph'; text = $plainTiming }
    }
    return $blocks
}

function Get-WeeklyNoticesText {
    <#
        T-31: what the bridge noticed and nobody read. The bridge measures
        every screen, counts every failure, knows every template's last use
        and records every changed setting - and almost all of it lives in a
        log nobody opens on shift. Folded into the weekly digest rather than
        sent as a second message: one weekly notice gets read, two teach the
        administrator to skip both.

        Names only, never values: a setting's value can be a secret, its name
        cannot. Everything human-typed is escaped; the whole section must pass
        the HTML gate test that renders Get-UsageDigestText.
    #>
    param([switch]$AsPlain)
    $found = [System.Collections.Generic.List[string]]::new()

    # 1. Screens approaching their payload cap.
    try {
        $peak = Get-RichPayloadPeak
        if ($peak -and [int]$peak.Percent -ge 70) {
            $screen = [string]$peak.Screen
            if (-not $AsPlain) { $screen = "<b>$(ConvertTo-TelegramHtmlText $screen)</b>" }
            $found.Add("📐 شاشة قريبة من حدّها: $screen — $($peak.Percent)% من الحدّ.")
        }
    }
    catch { Write-BridgeLog "Weekly notices: payload signal failed: $($_.Exception.Message)" }

    # 2. Templates unused for thirty days (or never).
    try {
        $store = Get-TemplateStore
        $map = Get-JsonProp $store 'Map'
        if ($map) {
            $cutoff = (Get-Date).AddDays(-30)
            $idle = @(foreach ($key in @($map.Keys)) {
                    $name = [string]$key
                    if ($script:TemplateLastUsed.ContainsKey($name)) {
                        if ([datetime]$script:TemplateLastUsed[$name] -ge $cutoff) { continue }
                        $when = ([datetime]$script:TemplateLastUsed[$name]).ToLocalTime().ToString('MM-dd')
                    }
                    else { $when = 'أبدًا' }
                    "$name — $when"
                })
            if (@($idle).Count -gt 0) {
                $shown = if ($AsPlain) { @($idle | Select-Object -First 5) } else { @($idle | Select-Object -First 5 | ForEach-Object { ConvertTo-TelegramHtmlText ([string]$_) }) }
                $extra = @($idle).Count - 5
                $tail = if ($extra -gt 0) { " (+$extra أخرى)" } else { '' }
                $found.Add("🕸 قوالب بلا استعمال منذ شهر: $($shown -join ' · ')$tail")
            }
        }
    }
    catch { Write-BridgeLog "Weekly notices: idle-template signal failed: $($_.Exception.Message)" }

    # 3. Failures repeating under one cause (the T-32 table, weekly view).
    try {
        $foundCauses = @()
        foreach ($cause in @($script:AlertHistory.Keys)) {
            $times = @(@($script:AlertHistory[$cause]) | Where-Object { $_ -is [datetime] })
            if ($times.Count -ge 3) {
                $foundCauses += [pscustomobject]@{ Cause = [string]$cause; Count = $times.Count }
            }
        }
        $repeats = @($foundCauses | Sort-Object Count -Descending | Select-Object -First 5)
        if ($repeats.Count -gt 0) {
            $parts = if ($AsPlain) { @($repeats | ForEach-Object { "$($_.Cause) — $(Get-ArabicCountNoun -Count $_.Count -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة')" }) } else { @($repeats | ForEach-Object { "$(ConvertTo-TelegramHtmlText $_.Cause) — $(Get-ArabicCountNoun -Count $_.Count -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة')" }) }
            $found.Add("🔁 فشل متكرر بنفس السبب: $($parts -join ' · ')")
        }
    }
    catch { Write-BridgeLog "Weekly notices: repeat-failure signal failed: $($_.Exception.Message)" }

    # 4. Settings differing from defaults - names only.
    try {
        $foundChanged = @()
        foreach ($prop in @($script:DefaultSettings.Keys)) {
            $name = [string]$prop
            $def = [string]$script:DefaultSettings[$name]
            $cur = ''
            try { $cur = [string](Get-JsonProp $config.Settings $name) } catch { continue }
            if ($cur -cne $def) { $foundChanged += $name }
        }
        $changed = @($foundChanged | Select-Object -First 10)
        $tail = Format-CappedTail -Total @($foundChanged).Count -Shown @($changed).Count
        if ($changed.Count -gt 0) {
            $safe = if ($AsPlain) { @($changed) } else { @($changed | ForEach-Object { "<code>$(ConvertTo-TelegramHtmlText ([string]$_))</code>" }) }
            $found.Add("⚙️ إعدادات معدّلة عن الافتراضي: $($safe -join ' ')$tail")
        }
    }
    catch { Write-BridgeLog "Weekly notices: changed-settings signal failed: $($_.Exception.Message)" }

    if ($found.Count -eq 0) { return '' }
    $head = if ($AsPlain) { '👁 ما لاحظه الجسر' } else { '<b>👁 ما لاحظه الجسر</b>' }
    return ("$head`n" + ($found -join "`n"))
}

function Get-UsageDigestText {
    <# What the shift actually did, from counters the bridge already keeps.
       Meant to be read on a phone, so it is a handful of lines: the busiest
       templates, the operation totals, and anything that got refused. #>
    param([int]$TopCount = 5)
    $lines = [System.Collections.Generic.List[string]]::new()
    # parse_mode=HTML. Template names are typed by an administrator, so each
    # one is escaped; the ranking sits in a blockquote because it is a list
    # inside a summary rather than the summary itself.
    $lines.Add('<b>📊 ملخص الاستخدام</b>')
    $lines.Add("🕒 <code>$((Get-Date).ToString('yyyy-MM-dd HH:mm'))</code> (محلي)")

    $ranked = @($script:UsageCounts.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopCount)
    if ($ranked.Count -eq 0) { $lines.Add('<i>لم تُستخدم أي قوالب بعد.</i>') }
    else {
        # Cumulative since counting began, not this week's: UsageCounts is
        # persisted across restarts, so its leader can outnumber the weekly
        # operations below without anything being broken. Labelled as such.
        $lines.Add('')
        $lines.Add('<b>🏆 الأكثر استخدامًا</b> (تراكمي)')
        # The reports screens' own vocabulary: the name in bold and the
        # figures after a "·", at full size - where a <pre> ranking would be
        # aligned and small.
        $rank = 0
        $rankLines = @(foreach ($item in $ranked) {
                $rank++
                $uses = Get-ArabicCountNoun -Count ([int]$item.Value) -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة'
                $line = "$rank. <b>$(ConvertTo-TelegramHtmlText ([string]$item.Key))</b> — $uses"
                if ($script:TemplateLastUsed.ContainsKey($item.Key)) {
                    $line += " · آخر مرة $(([datetime]$script:TemplateLastUsed[$item.Key]).ToLocalTime().ToString('MM-dd HH:mm'))"
                }
                $line
            })
        $tag = if ($rankLines.Count -gt 5) { '<blockquote expandable>' } else { '<blockquote>' }
        $lines.Add("$tag$($rankLines -join "`n")</blockquote>")
    }

    $counters = $script:AirOperationCounters
    $total = [int]$counters.Success + [int]$counters.Failed + [int]$counters.Blocked
    # The scheduled weekly digest cannot use the process counters: a restart
    # at handover made a quiet week look empty. Audit is the durable source.
    $week = Get-ReportRecords -From ((Get-Date).Date.AddDays(-6)) -To (Get-Date) -EventName 'air_control'
    $weeklyOperations = @($week.Records).Count
    $completedDays = 7
    $dailyAverage = [math]::Round($weeklyOperations / $completedDays, 1)

    # The same grammar as 🩺 مركز صحة النظام: the figures that answer the
    # screen lead, each line opening with its own glyph, and the outcome
    # breakdown follows as the detail behind them.
    #
    # The breakdown sits directly under its own period, before the weekly
    # line: it counts the in-memory counters since the last restart, and an
    # earlier layout placed it after the weekly figure, where 200 weekly
    # operations against "✅ ناجحة — 8" read as a broken week.
    $lines.Add('')
    $sinceRestart = Get-ArabicCountNoun -Count $total -One 'عملية' -Two 'عمليتان' -Few 'عمليات' -Many 'عملية'
    $lines.Add("🎬 <b>منذ آخر تشغيل</b> — $sinceRestart")
    $lines.Add("<blockquote>✅ ناجحة — $($counters.Success)
❌ فاشلة — $($counters.Failed)
⛔ مرفوضة — $($counters.Blocked)</blockquote>")
    if ([int]$counters.Failed -gt 0 -or [int]$counters.Blocked -gt 0) {
        $lines.Add('<i>راجع 📜 السجل لمعرفة سبب الفشل أو الرفض.</i>')
    }
    $weekOps = Get-ArabicCountNoun -Count $weeklyOperations -One 'عملية' -Two 'عمليتان' -Few 'عمليات' -Many 'عملية'
    $lines.Add("📆 <b>آخر 7 أيام</b> — $weekOps · متوسط $dailyAverage يوميًا")
    $lines.Add('')
    if ($script:CancelReasons.Count -gt 0) {
        $lines.Add('')
        $lines.Add('<b>↩️ أسباب التراجع المسجّلة</b>')
        $reasonLines = @(@($script:CancelReasons.Keys | Sort-Object) | ForEach-Object {
                "$(ConvertTo-TelegramHtmlText (Get-CancelReasonLabel -Reason $_)) — $($script:CancelReasons[$_])"
            })
        $lines.Add("<blockquote>$($reasonLines -join "`n")</blockquote>")
    }
    # T-31: the bridge's own observations ride the same weekly message.
    $notices = Get-WeeklyNoticesText
    if ($notices) { $lines.Add(''); $lines.Add($notices) }
    # T-16: slow templates and abandoned drafts, from the clocks above.
    $timingSection = Get-FlowTimingText
    if ($timingSection) { $lines.Add(''); $lines.Add($timingSection) }
    return ($lines -join "`n")
}

function Get-FlowTimingText {
    <#
        T-16: the slowest templates to reach air, and the drafts that never
        did - from ShowFlowTimings settled on successful SHOWs and
        AbandonedDrafts counted at expiry. Template names are administrator
        text, so each is escaped; the section must pass the HTML gate test
        that renders Get-UsageDigestText.
    #>
    param([switch]$AsPlain)
    $found = [System.Collections.Generic.List[string]]::new()
    $slow = @()
    foreach ($key in @($script:ShowFlowTimings.Keys)) {
        $entry = $script:ShowFlowTimings[$key]
        $count = 0; $total = 0
        [int]::TryParse([string](Get-JsonProp $entry 'Count'), [ref]$count) | Out-Null
        [int]::TryParse([string](Get-JsonProp $entry 'TotalSeconds'), [ref]$total) | Out-Null
        if ($count -le 0) { continue }
        $slow += [pscustomobject]@{ Key = [string]$key; Count = $count; Average = [int]($total / $count) }
    }
    $slow = @($slow | Sort-Object Average -Descending | Select-Object -First 3)
    if ($slow.Count -gt 0) {
        $parts = @($slow | ForEach-Object {
                $name = if ($AsPlain) { $_.Key } else { "<b>$(ConvertTo-TelegramHtmlText $_.Key)</b>" }
                $times = Get-ArabicCountNoun -Count ([int]$_.Count) -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة'
                "$name — متوسط $($_.Average) ث ($times)"
            })
        $found.Add("🐢 الأبطأ وصولًا للهواء: $($parts -join ' · ')")
    }
    $dropped = @($script:AbandonedDrafts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3)
    if ($dropped.Count -gt 0) {
        $parts = @($dropped | ForEach-Object {
                $name = if ($AsPlain) { [string]$_.Key } else { ConvertTo-TelegramHtmlText ([string]$_.Key) }
                "$name — $(Get-ArabicCountNoun -Count ([int]$_.Value) -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة')"
            })
        $found.Add("🗑 مسودات مهجورة: $($parts -join ' · ')")
    }
    if ($found.Count -eq 0) { return '' }
    $head = if ($AsPlain) { '⏱ زمن النشر والمسودات' } else { '<b>⏱ زمن النشر والمسودات</b>' }
    return ("$head`n" + ($found -join "`n"))
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

function Update-MaterialEndWatchdog {
    <#
        F4: "the segment ends in two minutes, get the outro graphic ready."

        Off while MaterialEndAlertMinutes is 0. Reads the rundown directly
        rather than through the anchor cache: a five-minute-old cached end
        time against a two-minute lead alerts late or never. One 4KB GET a
        minute is the price, throttled below.

        Urgent on purpose: a "two minutes left" notice held for quiet hours
        arrives after the segment did. The operator asked for this one by
        setting its minutes above zero. One alert per material, keyed by id,
        so a long outro window does not repeat itself every tick.
    #>
    $lead = Get-SettingInt 'MaterialEndAlertMinutes'
    if ($lead -le 0) { return }
    $now = Get-Date
    if (($now - $script:LastMaterialEndCheck).TotalMinutes -lt 1) { return }
    $script:LastMaterialEndCheck = $now
    $timeout = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1
    $schedule = Get-AirMaterialSchedule -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
    if (-not $schedule -or -not $schedule.Success) { return }
    $at = [datetimeoffset]$now
    # Parsed once, guarded once: the sort below re-reads these fields, and a
    # malformed rundown entry must disqualify itself, not abort the watchdog.
    $candidates = @()
    foreach ($item in @($schedule.Items)) {
        try {
            $start = [datetimeoffset](Get-JsonProp $item 'ScheduledAt')
            $duration = [timespan](Get-JsonProp $item 'Duration')
        }
        catch { continue }
        if ($start -le $at -and ($start + $duration) -gt $at) {
            $candidates += [pscustomobject]@{ Item = $item; End = ($start + $duration) }
        }
    }
    $active = $candidates | Sort-Object End | Select-Object -First 1 | ForEach-Object { $_.Item }
    if (-not $active) { $script:LastMaterialEndAlertId = ''; return }
    $end = ([datetimeoffset](Get-JsonProp $active 'ScheduledAt') + [timespan](Get-JsonProp $active 'Duration'))
    $left = $end - $at
    if ($left.TotalMinutes -gt $lead -or $left.TotalSeconds -le 0) { return }
    $bareId = ([string](Get-JsonProp $active 'Id')).Trim('{', '}')
    if ($script:LastMaterialEndAlertId -eq $bareId) { return }
    $script:LastMaterialEndAlertId = $bareId
    $name = ConvertTo-TelegramHtmlText ([string](Get-JsonProp $active 'Name'))
    $minutes = [math]::Max(1, [int][math]::Ceiling($left.TotalMinutes))
    Send-AdminBroadcast -Text "⏳ المادة «$name» تنتهي بعد نحو $(Get-ArabicCountNoun -Count $minutes -One 'دقيقة' -Two 'دقيقتان' -Few 'دقائق' -Many 'دقيقة') ($($end.ToLocalTime().ToString('HH:mm'))). جهّز غرافيك الختام." -Urgent
    Write-BridgeLog "Material end alert: '$([string](Get-JsonProp $active 'Name'))' ends in $([int]$left.TotalMinutes)m"
}

function Update-MaterialProxyWatchdog {
    <#
        Warns that material about to air has no local copy on the server.

        A proxy here is the server's own copy of the item. Without one the
        channel reads the material from its source while it plays, which makes
        a network or a source server part of the live path rather than a thing
        that mattered earlier in the day.

        Off by default, and deliberately so: measured on this station,
        twenty-two of twenty-four scheduled items carry no local copy. An
        alert that fires on nearly every item is an alert people learn to
        ignore, which costs more than it saves. A station that expects its
        material local before air turns it on and gets a real signal.

        Reports each item once per run. The set clears when the item is no
        longer inside its lead window, so tomorrow's schedule starts clean.
    #>
    if (-not (Get-Setting 'NotifyAdminsOnMissingProxy')) { return }
    $lead = Get-SettingInt 'MaterialProxyLeadMinutes' 1
    if ($lead -le 0) { return }
    $now = Get-Date
    if (($now - $script:RuntimeState.Monitoring.LastMaterialProxyCheck).TotalMinutes -lt 5) { return }
    $script:RuntimeState.Monitoring.LastMaterialProxyCheck = $now

    $schedule = Get-AirMaterialSchedule -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not $schedule.Success) { return }

    $from = [datetimeoffset]$now
    $until = $from.AddMinutes($lead)
    $due = @($schedule.Items | Where-Object { $_.ScheduledAt -gt $from -and $_.ScheduledAt -le $until })

    # Forget anything no longer in the window, so the same item can be
    # reported again if it is rescheduled later.
    $inWindow = @($due | ForEach-Object { [string]$_.Id })
    foreach ($id in @($script:MaterialProxyAlerted)) {
        if ($inWindow -notcontains $id) { $script:MaterialProxyAlerted.Remove($id) | Out-Null }
    }

    $missing = @($due | Where-Object { [int]$_.ProxyProgress -lt 100 -and -not $script:MaterialProxyAlerted.Contains([string]$_.Id) })
    if ($missing.Count -eq 0) { return }
    foreach ($item in $missing) { $script:MaterialProxyAlerted.Add([string]$item.Id) | Out-Null }

    $lines = @($missing | ForEach-Object {
            # Nothing at all reads differently from a copy that stopped part
            # way: the second is a transfer that may still finish, or may be
            # stuck.
            $state = if ([int]$_.ProxyProgress -le 0) { 'بلا نسخة محلية' } else { "النسخ متوقف عند $([int]$_.ProxyProgress)%" }
            "• $($_.ScheduledAt.ToLocalTime().ToString('HH:mm')) · $(ConvertTo-TelegramHtmlText ([string]$_.Name)) — $state"
        })
    Write-BridgeLog "Material due within $lead minute(s) without a complete local copy: $(@($missing | ForEach-Object { $_.Name }) -join ' | ')" 'WARN'
    Send-AdminBroadcast -Urgent -Text ("📼 <b>مادة تقارب موعدها بلا نسخة محلية</b>`n" + ($lines -join "`n") +
        "`nستُقرأ من المصدر أثناء البثّ — تحقّق من المصدر والشبكة، أو أوقف هذا التنبيه من ⚙️ الإعدادات.")
}

function Update-StaleOnAirWatchdog {
    <# Tells the administrators when the bridge has been claiming a graphic is
       on air for implausibly long, so a record that outlived its scene is
       noticed in minutes rather than discovered by someone looking at the
       output.

       Escalates rather than alerting once. Asked what had last gone wrong on
       air, the station answered: a graphic stayed up and was never taken
       down. This alert existed for exactly that and still allowed it, because
       it fired a single message to administrators - whoever missed it missed
       it for good, and the graphic stayed up in silence.

       Three changes follow from that. It repeats on a widening interval while
       the record survives. It tells the operator who put the graphic up, not
       only the administrators, because they are the one who can take it down
       and the one who will recognise it. And it carries the hide button
       itself, so acting on it does not mean finding the layer in a menu.

       The counter clears when the record goes, so a layer shown again later
       starts from silence rather than mid-escalation. #>
    $threshold = Get-SettingInt 'StaleOnAirAlertHours' 0
    if ($threshold -le 0) { return }
    $now = Get-Date
    if (($now - $script:RuntimeState.Monitoring.LastStaleOnAirCheck).TotalMinutes -lt 5) { return }
    $script:RuntimeState.Monitoring.LastStaleOnAirCheck = $now

    # Drop counters for layers that are no longer tracked, so a re-shown layer
    # starts from silence instead of mid-escalation.
    foreach ($layer in @($script:StaleOnAirAlerted.Keys)) {
        if (-not $script:OnAir.ContainsKey([int]$layer)) { $script:StaleOnAirAlerted.Remove([int]$layer) }
    }

    # Layers whose next notice is not due yet are treated as already alerted,
    # which is how the same helper serves both the first notice and the
    # repeats without learning about escalation.
    $silent = @(foreach ($layer in @($script:StaleOnAirAlerted.Keys)) {
            $seen = $script:StaleOnAirAlerted[[int]$layer]
            $step = @($script:StaleOnAirEscalationMinutes)
            $wait = [int]$step[[math]::Min([int]$seen.Count - 1, $step.Count - 1)]
            if (($now - [datetime]$seen.LastAt).TotalMinutes -lt $wait) { [int]$layer }
        })

    $stale = @(Get-BridgeStaleOnAirLayers -OnAir $script:OnAir -Now $now `
            -ThresholdHours $threshold -AlreadyAlerted @($silent))
    # Filtered after the time arithmetic, not before: only a candidate is worth
    # a Cinegy round trip, and there are rarely more than one or two.
    $stale = @($stale | Where-Object { -not (Test-LongRunningOnAir -Layer $_.Layer -Key $_.Key) })
    if ($stale.Count -eq 0) { return }

    foreach ($item in $stale) {
        $layer = [int]$item.Layer
        $seen = if ($script:StaleOnAirAlerted.ContainsKey($layer)) { $script:StaleOnAirAlerted[$layer] } else { @{ Count = 0; LastAt = $now } }
        $script:StaleOnAirAlerted[$layer] = @{ Count = [int]$seen.Count + 1; LastAt = $now }
    }
    $lines = @($stale | ForEach-Object { "• طبقة $($_.Layer) · $($_.Key) — منذ $(Get-ArabicCountNoun -Count $_.Hours -One 'ساعة' -Two 'ساعتان' -Few 'ساعات' -Many 'ساعة')" })
    Write-BridgeLog "Stale on-air record(s) reported: $(@($stale | ForEach-Object { $_.Layer }) -join ', ')" 'WARN'

    # A button on the notice, not an instruction to go and find the layer. The
    # single most useful place in the bridge for the rule that a warning the
    # system can act on should carry the action.
    $keyboard = @{ inline_keyboard = @(@(foreach ($item in $stale) {
                    , @((New-Button "🙈 أخفِ طبقة $($item.Layer) · $($item.Key)" "hide:$($item.Layer)" -Style danger))
                }) + @(, @((New-Button 'ℹ️ الحالة' 'menu:status')))) }

    $repeat = @($stale | Where-Object { [int]$script:StaleOnAirAlerted[[int]$_.Layer].Count -gt 1 })
    $head = if ($repeat.Count -eq $stale.Count -and $stale.Count -gt 0) {
        "⚠️ <b>ما زال على الهواء</b> — تنبيه متكرّر:"
    }
    else { '⚠️ سجلات على الهواء منذ وقت طويل — تحقّق من الشاشة:' }
    $body = "$head`n" + ($lines -join "`n") + "`nإن كانت الشاشة خالية فالإخفاء يصفّي السجل."

    Send-AdminBroadcast -Urgent -Text $body -ReplyMarkup $keyboard

    # And the person who put it there. They are likelier to recognise it than
    # an administrator reading a layer number, and likelier to be holding a
    # phone. Skipped when they are an administrator already, so nobody is told
    # the same thing twice in two messages.
    $adminIds = @(Get-AdminNotifyIds)
    foreach ($item in $stale) {
        $record = if ($script:OnAir.ContainsKey([int]$item.Layer)) { $script:OnAir[[int]$item.Layer] } else { $null }
        if (-not $record) { continue }
        $target = [long](Get-JsonProp $record 'ChatId')
        if ($target -le 0) { $target = [long](Get-JsonProp $record 'UserId') }
        if ($target -le 0 -or $adminIds -contains $target) { continue }
        Send-TelegramMessage -ChatId $target -ParseMode HTML -Cause 'stale-on-air-owner-notice' `
            -Text ("⚠️ <b>ما زال على الهواء</b>`n$(ConvertTo-TelegramHtmlText ([string]$item.Key)) على الطبقة $($item.Layer) منذ $(Get-ArabicCountNoun -Count $item.Hours -One 'ساعة' -Two 'ساعتان' -Few 'ساعات' -Many 'ساعة').`nإن لم يعد مطلوبًا فأخفِه من الزرّ أدناه.") `
            -ReplyMarkup @{ inline_keyboard = @(, @((New-Button "🙈 أخفِ طبقة $($item.Layer)" "hide:$($item.Layer)" -Style danger))) }
    }
}

function Test-LongRunningOnAir {
    <#
        Is this graphic meant to stay up, rather than forgotten up there?

        The staleness alert measured elapsed time alone, so the news ticker -
        genuinely on air, its Active Id matching the record exactly - was
        reported to administrators as a stale record five times over two days.
        An alert that cries wolf on correct behaviour teaches operators to
        ignore it, which costs more than the alert ever saved.

        Two independent answers, either of which is enough:

          * The template says so. An operator who knows the ticker runs all
            day can mark it LongRunning and never think about it again.
          * Cinegy says so. The engine already carries the item's intended
            Duration - a ticker is scheduled as 24:00:00 with ManualEnd - and
            that is the authoritative answer, needing no configuration and
            unable to drift out of date.

        Anything Cinegy cannot answer stays stale-able: an unreachable engine
        must never silence the alert, because "cannot check" and "fine" are
        different things.
    #>
    param([Parameter(Mandatory)][int]$Layer, [string]$Key = '')

    $template = $null
    $store = Get-TemplateStore
    if ($Key -and $store.Map.ContainsKey($Key)) {
        $template = $store.Map[$Key]
        if ($template.ContainsKey('LongRunning') -and [bool]$template.LongRunning) { return $true }
    }
    if (-not (Get-Setting 'RespectCinegyItemDuration')) { return $false }

    try {
        $device = if ($template -and $template.ContainsKey('Device')) { [string]$template.Device } else { '' }
        $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
            -AirChannelNumber $config.AirChannelNumber -Layer $Layer -Device $device `
            -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        if (-not $status.Success -or -not $status.IsOnAir) { return $false }

        $declared = [int]$status.ActiveDurationSeconds
        if ($declared -le 0) { return $false }
        if (-not $script:OnAir.ContainsKey($Layer)) { return $false }
        $record = $script:OnAir[$Layer]
        if ($record.At -isnot [datetime]) { return $false }
        return ((Get-Date) - $record.At).TotalSeconds -lt $declared
    }
    catch {
        Write-BridgeLog "Could not read the declared duration for layer ${Layer}: $($_.Exception.Message)" 'DEBUG'
        return $false
    }
}

function Get-CinegyStateCheckInterval {
    <# Configured interval, widened while Air is unreachable. See
       Get-BridgeCinegyStateBackoff for why the widening exists. #>
    $interval = Get-SettingInt 'CinegyStateCheckSeconds' 1
    return [Math]::Max($interval, [int]$script:RuntimeState.Monitoring.CinegyStateBackoffSeconds)
}

function Get-BridgePermanentGraphics {
    <#
        The graphics that are meant to be on air all the time.

        Declared already, and nowhere new: a template marked longRunning is one
        nobody expects to take down - the channel logo, the news strip - which
        is exactly the set worth noticing the absence of. A second setting
        listing them again would be a second place to forget.
    #>
    $store = Get-TemplateStore
    $graphics = foreach ($key in @($store.Order)) {
        $template = $store.Map[$key]
        if (-not [bool](Get-JsonProp $template 'LongRunning')) { continue }
        $layer = [int](Get-JsonProp $template 'Layer')
        if ($layer -le 0) { continue }
        [pscustomobject]@{ Key = [string]$key; Layer = $layer }
    }
    return @($graphics)
}

function Update-MissingGraphicWatchdog {
    <#
        Says when the logo or the strip is not on air.

        Asked of Cinegy, never of onair.json: the point is to catch a graphic
        that is gone, and it does not matter in the slightest whether it went
        from this bot or from somebody's hand in Air. The bridge's own record
        could only ever describe what the bridge itself did.

        Confirmed before it speaks, because a permanent graphic is legitimately
        down for the seconds it takes to replace one, and an alert on every
        such moment is an alert nobody reads. It says so once when it goes and
        once when it returns: a repeating alarm for a state somebody is already
        dealing with is noise.
    #>
    param([object[]]$LayerStatuses = @())
    if (-not (Get-Setting 'NotifyAdminsOnMissingGraphic')) { return }
    $required = @(Get-BridgePermanentGraphics)
    if ($required.Count -eq 0) { return }
    # Reuse the sweep the layer watchdog has already paid for; read again only
    # when it had nothing to hand over.
    $statuses = @($LayerStatuses)
    if ($statuses.Count -eq 0) { $statuses = @(Get-CinegyLayerDashboard) }
    if ($statuses.Count -eq 0) { return }
    $byLayer = @{}
    foreach ($status in $statuses) {
        $statusLayer = 0
        if ([int]::TryParse([string](Get-JsonProp $status 'Layer'), [ref]$statusLayer)) { $byLayer[$statusLayer] = $status }
    }
    $threshold = [math]::Max(1, (Get-SettingInt 'MissingGraphicConfirmChecks' 2))
    foreach ($graphic in $required) {
        $status = $byLayer[[int]$graphic.Layer]
        # An engine that did not answer is not a graphic that is missing.
        if (-not $status -or -not [bool](Get-JsonProp $status 'Success')) { continue }
        $key = [string]$graphic.Key
        $state = if ($script:MissingGraphicState.ContainsKey($key)) { $script:MissingGraphicState[$key] } else { @{ Misses = 0; Alerted = $false } }
        if ([bool](Get-JsonProp $status 'IsOnAir')) {
            if ([bool]$state.Alerted) {
                Send-AdminBroadcast -Text "✅ عاد «$key» إلى الهواء على $(Get-LayerDisplayName -Layer ([int]$graphic.Layer))." | Out-Null
                Write-BridgeLog "The permanent graphic '$key' is back on layer $($graphic.Layer)."
            }
            $script:MissingGraphicState[$key] = @{ Misses = 0; Alerted = $false }
            continue
        }
        $state.Misses = [int]$state.Misses + 1
        if (-not [bool]$state.Alerted -and [int]$state.Misses -ge $threshold) {
            $state.Alerted = $true
            Write-BridgeLog "The permanent graphic '$key' is not on air on layer $($graphic.Layer) after $($state.Misses) check(s)." 'WARN'
            Send-AdminBroadcast -Text "⚠️ «$key» ليس على الهواء على $(Get-LayerDisplayName -Layer ([int]$graphic.Layer)).`nيُفترض أن يبقى دائمًا؛ أعِده من 📋 القوالب أو من 🎚 الطبقات." | Out-Null
        }
        $script:MissingGraphicState[$key] = $state
    }
}

function Update-CinegyStateWatchdog {
    $now = Get-Date
    if (($now - $script:RuntimeState.Monitoring.LastCinegyStateCheck).TotalSeconds -lt (Get-CinegyStateCheckInterval)) { return }
    $script:RuntimeState.Monitoring.LastCinegyStateCheck = $now

    # With no dashboard and no -DiscoverExternal this verified only the layers
    # the bridge had put up itself, so a graphic somebody started in Cinegy
    # after startup - the news strip, most often - never appeared in the menu
    # and could not be hidden from it. Startup discovered such layers and the
    # status screen discovered them; nothing in between did.
    $discover = [bool](Get-Setting 'DiscoverExternalLayers')
    $layerStatuses = if ($discover) { @(Get-CinegyLayerDashboard) } else { @() }
    $sync = Update-OnAirStateFromCinegy -Reason 'watchdog' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal:$discover
    # Handed the sweep this function has already paid for.
    Update-MissingGraphicWatchdog -LayerStatuses $layerStatuses

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
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) `
        -FrameLossTolerance (Get-SettingInt 'CinegyFrameLossTolerance' 0) `
        -FrameLossTolerancePercent ([double](Get-Setting 'CinegyFrameLossTolerancePercent')) `
        -ReadErrorRateTolerance ([double](Get-Setting 'CinegyReadErrorRateTolerance'))
    $reading = if (-not $telemetry.Success -or $null -eq $telemetry.Healthy) { 'unreachable' }
    elseif ($telemetry.Healthy) { 'healthy' }
    else { 'unhealthy' }

    $oldState = $script:RuntimeState.Monitoring.CinegyHealthState; $history = $script:HealthHistory.Cinegy

    <#
        One reading does not change the state; several agreeing ones do.

        The tolerance added in 5.6.1 filters the values, and this filters the
        verdict - two different jobs. Even inside tolerance the channel kept
        crossing the line and back, so the log took 332 health transitions,
        23 of them today, on an engine that was fine every time anybody
        looked. A monitor that changes its mind every minute is one operators
        stop reading, which costs more than the outage it was watching for.

        CinegyHealthConfirmChecks readings must agree before the state moves.
        The first reading of a run still counts immediately, because a bridge
        that has just started has no history to be steady about.
    #>
    $confirm = [math]::Max(1, (Get-SettingInt 'CinegyHealthConfirmChecks' 1))
    if ($reading -ne $oldState -and $oldState -ne 'unknown' -and $confirm -gt 1) {
        if ([string]$history.PendingState -eq $reading) { $history.PendingCount = [int]$history.PendingCount + 1 }
        else { $history.PendingState = $reading; $history.PendingCount = 1 }

        if ([int]$history.PendingCount -lt $confirm) {
            Write-BridgeLog "Cinegy reported $reading ($($history.PendingCount)/$confirm) - holding at $oldState" 'DEBUG'
            return
        }
    }
    $history.PendingState = ''; $history.PendingCount = 0

    # What the reading actually was, in numbers, kept once and used for both
    # the log line and the screens.
    #
    # "unhealthy" here never meant unreachable: Air answered and its own
    # telemetry crossed a tolerance. Which tolerance, and by how much, was
    # computed only for the admin broadcast and only once the alert threshold
    # was reached - so the log said "Cinegy health changed from healthy to
    # unhealthy" and nothing else, and the only way to learn why was to go and
    # read the metrics by hand while the moment had passed.
    $issues = @(@(Get-JsonProp $telemetry 'Issues') | Where-Object { $_ })
    $why = if ($reading -eq 'unreachable') {
        $err = [string](Get-JsonProp $telemetry 'Error')
        if ($err) { "تعذّر الوصول: $(Protect-SensitiveText $err)" } else { 'تعذّر الوصول' }
    }
    elseif ($issues.Count -gt 0) { "قياسات غير سليمة: $($issues -join '، ')" }
    else {
        "قياسات غير سليمة (الساقط $(Get-JsonProp $telemetry 'DroppedCount') من $(Get-JsonProp $telemetry 'OutputCount')" +
        " · $(Get-JsonProp $telemetry 'DroppedPercent')% · أخطاء القراءة $(Get-JsonProp $telemetry 'MaxReadErrorRate')%)"
    }

    $newState = $reading
    if ($newState -ne $oldState) {
        # The reason on the same line as the change: an operator reading the
        # log after the fact has the numbers that caused it, not just the word.
        $suffix = if ($newState -eq 'healthy') { '' } else { " - $why" }
        Write-BridgeLog "Cinegy health changed from $oldState to $newState$suffix"
    }
    $script:RuntimeState.Monitoring.CinegyHealthState = $newState
    if ($newState -eq 'healthy') {
        # Recovery is announced whenever the state was not healthy before, not
        # only when a warning had already gone out. The warning waits for
        # HealthFailureAlertThreshold consecutive failures, so a dip that
        # cleared just under it left the screens saying "غير سليم" for minutes
        # and then went quiet - and an operator who had looked in the middle of
        # it was never told it was over.
        $wasDown = $oldState -ne 'healthy' -and $oldState -ne 'unknown'
        $wasAlerted = [bool]$history.AlertSent
        $downSince = $history.OutageStartedAt

        $history.LastSuccess = $now; $history.FailureCount = 0; $history.OutageStartedAt = $null; $history.AlertSent = $false

        if ($wasDown -and (Get-Setting 'NotifyAdminsOnCinegyHealth')) {
            # The same shape as the warning: what it is now, in numbers, and
            # how long it was not. A bare "it recovered" leaves an operator
            # deciding whether to go and look anyway.
            # Plain text, like the warning it answers. Send-AdminBroadcast
            # holds a non-urgent notice for the quiet-hours digest and that
            # queue keeps only the text, so a message that needed a parse mode
            # would lose it on the way out hours later.
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('💚 تعافت صحة Cinegy')
            if ($downSince) {
                $seconds = [int]($now - [datetime]$downSince).TotalSeconds
                $lines.Add("استمر الخلل $(Format-DurationSeconds -Seconds $seconds) — من $(([datetime]$downSince).ToString('HH:mm:ss')) إلى $($now.ToString('HH:mm:ss'))")
            }
            # Why it had been unhealthy, kept from the reading that decided it.
            if ($history.LastError) { $lines.Add("السبب كان: $([string]$history.LastError)") }
            $lines.Add((Format-CinegyTelemetryStatus -Telemetry $telemetry))
            if (-not $wasAlerted) {
                # Said plainly, or an operator wonders why they are being told
                # something ended that they were never told had begun.
                $lines.Add('لم يبلغ الخلل حدّ التنبيه، فلم يُرسل تحذير عند بدايته.')
            }
            Send-AdminBroadcast -Text ($lines -join "`n")
        }
        return
    }
    if ([int]$history.FailureCount -eq 0) { $history.OutageStartedAt = $now }
    $history.FailureCount = [int]$history.FailureCount + 1; $history.LastErrorAt = $now
    # The measured reason, not the category. "قياسات غير سليمة" told the
    # ⚠️ آخر الأخطاء row exactly what its own colour already said.
    $history.LastError = $why
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

function Test-TelegramReady {
    return [string]$script:RuntimeState.Monitoring.TelegramConnectionState -eq 'connected'
}

function Test-CinegyReady {
    return [string]$script:RuntimeState.Monitoring.CinegyHealthState -eq 'healthy'
}

function Send-BridgeStartupNotification {
    $airCount = $script:OnAir.Count
    $startupLines = [System.Collections.Generic.List[string]]::new()
    $startupLines.Add("🟢 بدأ تشغيل Cinegy Telegram Bridge v$script:BridgeVersion")
    $startupLines.Add("Air: $($config.AirServerAddress) / قناة $($config.AirChannelNumber)")
    # Connection status — show ⏳ if not yet checked, ✅/❌ after first poll
    $tgState = if ($null -ne $script:RuntimeState -and $null -ne $script:RuntimeState.Monitoring) {
        [string]$script:RuntimeState.Monitoring.TelegramConnectionState
    } else { 'unknown' }
    $cgState = if ($null -ne $script:RuntimeState -and $null -ne $script:RuntimeState.Monitoring) {
        [string]$script:RuntimeState.Monitoring.CinegyHealthState
    } else { 'unknown' }
    $tgStatus = if ($tgState -eq 'connected') { '✅' } elseif ($tgState -in @('', 'unknown')) { '⏳' } else { '❌' }
    $cgStatus = if ($cgState -eq 'healthy') { '✅' } elseif ($cgState -in @('', 'unknown')) { '⏳' } else { '❌' }
    $startupLines.Add("Telegram: $tgStatus | Cinegy: $cgStatus")
    if ($airCount -gt 0) {
        $startupLines.Add("")
        $startupLines.Add("📡 يوجد $airCount مشهدًا لا يزال على الهواء من التشغيل السابق:")
        foreach ($scene in @($script:OnAir.Values)) {
            $key = [string](Get-JsonProp $scene 'Key')
            $layer = [string](Get-JsonProp $scene 'Layer')
            $airCopy = [string](Get-JsonProp $scene 'AirCopy')
            $line = "   • $key — الطبقة $layer"
            if (-not [string]::IsNullOrWhiteSpace($airCopy)) { $line += " — $airCopy" }
            $startupLines.Add($line)
        }
    }
    Send-AdminBroadcast -Text ($startupLines -join "`n")
}

function Update-NewsSheetSync {
    <# Automatic mode only. The interval is measured from the last attempt, not
       the last success, so an unreachable sheet is retried on the same cadence
       instead of hammering the network every tick. #>
    if ([string](Get-Setting 'NewsSheetSyncMode') -ne 'auto') { return }
    if ([string]::IsNullOrWhiteSpace([string](Get-Setting 'NewsSheetCsvUrl'))) { return }
    $minutes = Get-SettingInt 'NewsSheetSyncMinutes' 1
    if ($minutes -le 0) { return }
    if ($script:NewsSheetLastSyncAt -and ((Get-Date) - $script:NewsSheetLastSyncAt).TotalMinutes -lt $minutes) { return }
    $script:NewsSheetLastSyncAt = Get-Date
    $result = Invoke-NewsSheetSync -Trigger auto
    # Logged where the other clock-driven work is logged. This sync publishes
    # to air on its own schedule and said so only to bridge.log, which no
    # operator reads during a shift - an unchanged or skipped pass is not an
    # event and stays out, so the screen shows publishes and failures only.
    if ($result.Success) {
        $count = @($result.Items).Count
        Write-BridgeLog "News sheet sync published $count item(s)"
        Write-BridgeExecutionRecord -Kind 'news' -Result 'success' `
            -Label "مزامنة الشيت · $(Get-ArabicCountNoun -Count $count -One 'خبر' -Two 'خبران' -Few 'أخبار' -Many 'خبرًا')" | Out-Null
    }
    elseif (-not $result.Unchanged -and -not $result.Skipped) {
        Write-BridgeLog "News sheet sync did not publish: $($result.Error)" 'WARN'
        Write-BridgeExecutionRecord -Kind 'news' -Result 'failed' -Label 'مزامنة الشيت' -ErrorText ([string]$result.Error) | Out-Null
    }
    # A sheet that has stopped answering is the one failure nobody sees: this
    # sync publishes to air on its own clock, so an editor whose sheet is
    # unreachable watches the ticker keep showing yesterday and has no reason
    # to suspect anything. It reported only to bridge.log and to a screen you
    # have to open on purpose, which is to say: to nobody, during a shift.
    #
    # A single miss is weather, not news. The alert waits for a run of them.
    Update-NewsSheetHealthNotice -Result $result
}

function Update-NewsSheetHealthNotice {
    <# Tracks the run of consecutive failures and speaks on the threshold, then
       once per further run of that length. -Cause puts it under the hourly
       alert cap, so a sheet broken all night costs a few messages rather than
       one every sync. #>
    param([Parameter(Mandatory)]$Result)
    # Reachable and correct, whether or not it had anything new to say.
    if ($Result.Success -or $Result.Unchanged) {
        $failed = [int]$script:NewsSheetFailureStreak
        $script:NewsSheetFailureStreak = 0
        $script:NewsSheetLastSuccessAt = Get-Date
        if ($failed -ge (Get-SettingInt 'NewsSheetFailureAlertAfter')) {
            $spell = Get-ArabicCountNoun -Count $failed -One 'محاولة' -Two 'محاولتين' -Few 'محاولات' -Many 'محاولة'
            Write-BridgeLog "News sheet sync recovered after $failed consecutive failure(s)"
            Send-NewsSheetNotice -Text "✅ عادت مزامنة الشيت بعد فشل $spell متتالية."
        }
        return
    }
    # A skipped cycle yielded to a draft on purpose; it is not a fault.
    if ($Result.Skipped) { return }

    $script:NewsSheetFailureStreak = [int]$script:NewsSheetFailureStreak + 1
    $after = Get-SettingInt 'NewsSheetFailureAlertAfter'
    if ($after -le 0) { return }
    if (($script:NewsSheetFailureStreak % $after) -ne 0) { return }

    $spell = Get-ArabicCountNoun -Count ([int]$script:NewsSheetFailureStreak) -One 'محاولة' -Two 'محاولتين' -Few 'محاولات' -Many 'محاولة'
    $since = if ($script:NewsSheetLastSuccessAt) {
        "آخر نشر ناجح منذ $(Format-Duration -Seconds ([int]((Get-Date) - $script:NewsSheetLastSuccessAt).TotalSeconds))."
    }
    else { 'ولم تنجح ولا مرة منذ إقلاع الجسر.' }
    $reason = [string]$Result.Error
    if ($reason.Length -gt 140) { $reason = $reason.Substring(0, 139) + '…' }
    Send-NewsSheetNotice -Cause 'news-sheet-sync-failing' -Text (
        "⚠️ مزامنة الشيت فشلت $spell متتالية.`n" +
        "السبب: $reason`n" +
        "$since`n" +
        "الشريط على الهواء ما زال على آخر نص نُشر — تعديلات الشيت لا تصل.")
}

function Invoke-BridgeTick {
    <# Everything time-based happens here, between long-polls. Each helper is
       cheap and non-blocking; any failure is logged rather than allowed to
       kill the loop. #>
    foreach ($step in @('Update-TelegramOutbox', 'Update-PostShowQueue', 'Update-SnapshotJobs', 'Update-RelayWatchdog', 'Update-AutoHideQueue', 'Update-TemplateReminderQueue', 'Update-ScheduleQueue', 'Update-MojazScheduleQueue', 'Update-MojazPlayback', 'Update-UrgentBoardRun', 'Update-MojazTickerReturn', 'Update-PendingExpiry', 'Update-NewsDraftExpiry', 'Update-PinnedRecurrenceSweep', 'Update-DeadChatsSweep', 'Update-NewsLockRequest', 'Update-NewsSheetSync', 'Update-SnapshotCleanup', 'Update-UploadCleanup', 'Update-MojazImageCleanup', 'Update-OutputBlackWatchdog', 'Update-MaterialProxyWatchdog', 'Update-MaterialEndWatchdog', 'Save-UsageCounts', 'Save-UserProfiles', 'Save-HealthSnapshot', 'Update-ScheduleExecutionLogTrim', 'Update-ScheduleHistoryTrim', 'Update-AccessGuardSweep', 'Update-CinegyStateWatchdog', 'Update-StaleOnAirWatchdog', 'Update-CinegyHealthWatchdog', 'Update-AlertSuppressionSweep', 'Update-QuietHoursQueue', 'Update-AnnouncementQueue', 'Update-Heartbeat', 'Update-UsageDigest')) {
        try { & $step | Out-Null }
        catch { Write-BridgeLog "Tick step $step failed: $($_.Exception.Message)" "ERROR" }
    }
}

function Get-BasePollTimeout {
    <# Clamped here rather than in $script:SettingConstraints because this is a
       top-level config key, not a Settings entry, so it never passes through
       Set-Setting's guard. Telegram refuses a getUpdates timeout above 50 and
       answers a hand-edited 3600 with an error on every poll, which reads in
       the log as the bot being down rather than as a bad number. #>
    $value = 0
    if (-not [int]::TryParse([string](Get-JsonProp $config 'PollTimeoutSeconds'), [ref]$value) -or $value -le 0) { $value = 30 }
    if ($value -gt 50) { $value = 50 }
    return $value
}

function Test-AirRunActive {
    <#
        Is anything walking a scene on air right now?

        One question with one answer, because two engines now need the same
        one - the bulletin and the breaking-news board - and the thing that
        reads it is the long-poll timeout. A second copy of this condition is
        a copy that will be updated when a third engine arrives, or will not.
    #>
    if ($script:MojazPlayback) { return $true }
    return ($null -ne $script:UrgentBoardRun)
}

function Get-EffectivePollTimeout {
    <# Long-poll for the configured time normally, but collapse to 1 second
       whenever async work is outstanding so a finished snapshot or a dead
       relay is noticed within a second instead of up to 30. #>
    if ($script:PostShowQueue.Count -gt 0) { return 1 }
    # A bulletin or a breaking-news board on air has a moment to hit every few
    # seconds, and the write has to land inside a fade that lasts about a
    # second. Polling for the configured half-minute would miss every one of
    # them.
    #
    # Asked as one question rather than two: the board was added with its tick
    # step registered and this line forgotten, which left an engine timed to
    # the millisecond being called up to thirty seconds late. Every test still
    # passed - the arithmetic was right, and nothing in the process was wrong
    # except when it ran.
    if (Test-AirRunActive) { return 1 }
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
