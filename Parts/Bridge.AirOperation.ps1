#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    One audited air operation: the context it carries, the maintenance and
    permission gates it passes, the verification against what Cinegy actually
    reports, and the record written when it lands.

    Split out of Bridge.ShowFlow.ps1, which had grown to 2733 lines by
    accumulating three things that are not the show flow: the release notes,
    the operator manual, and the audited air operation underneath every push.
    Nothing moved between scopes - dot-sourced parts share one.
#>

function New-AirOperationContext {
    param([Parameter(Mandatory)][ValidateSet('SHOW', 'HIDE', 'EXIT', 'UPDATE')][string]$Action, [int]$Layer = 0, [long]$UserId = 0)
    $id = "air-$([guid]::NewGuid().ToString('N'))"
    Add-BridgeOperation -Ledger $script:BridgeOperationLedger -OperationId $id -Action $Action -Layer $Layer -ActorId $UserId | Out-Null
    return [pscustomobject]@{
        Id        = $id
        Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Start-AirOperation {
    param([Parameter(Mandatory)]$Operation, [Parameter(Mandatory)][ValidateSet('SHOW', 'HIDE', 'EXIT', 'UPDATE')][string]$Action, [int]$Layer = 0, [long]$UserId = 0)
    Start-BridgeOperation -Ledger $script:BridgeOperationLedger -OperationId $Operation.Id -Action $Action -Layer $Layer -ActorId $UserId | Out-Null
}

function Get-TemplateTestReviewKeyboard {
    return @{ inline_keyboard = @(
        , @((New-Button '🧪 نعم، اختبر القالب' 'tadm:testconfirm' -Style success), (New-Button '❌ إلغاء' 'menu:templatesadmin'))
    ) }
}

function Format-OnAirScreenCopy {
    <#
        What the graphic actually says, short enough for a confirmation.

        A field the template marks sensitive is named but never quoted: the
        point is to let an operator recognise what is on screen before taking
        it off, and a name is enough for that where the value would be a leak.
    #>
    param([string]$Key = '', [hashtable]$Variables = @{}, [int]$MaxChars = 200)
    if ($null -eq $Variables -or $Variables.Count -eq 0) { return '' }
    $sensitive = @()
    $store = Get-TemplateStore
    if ($Key -and $store.Map.ContainsKey($Key)) {
        $sensitive = @(Get-JsonProp $store.Map[$Key] 'FieldSensitive' | Where-Object { $null -ne $_ })
    }
    $parts = foreach ($name in @($Variables.Keys | Sort-Object)) {
        if (@($sensitive | Where-Object { [string]$_ -eq [string]$name }).Count -gt 0) {
            "${name}: •••"
            continue
        }
        $value = ([string]$Variables[$name] -replace '[\r\n]+', ' ').Trim()
        if ($value) { "${name}: $value" }
    }
    $text = (@($parts) -join ' · ')
    if ($MaxChars -gt 0 -and $text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + '…' }
    return $text
}

function Format-AuditTemplateValues {
    <# The text that actually reached the screen, folded into one short line
       for the audit record. Without it a report can only say which template
       ran, never what it said - and audit.jsonl is the only permanent record.

       Capped and switchable: this file is archived and never deleted, so the
       operator decides whether on-air copy belongs in it forever. #>
    param([hashtable]$Variables = @{})
    if (-not (Get-Setting 'AuditTemplateValues')) { return '' }
    if ($null -eq $Variables -or $Variables.Count -eq 0) { return '' }
    $parts = foreach ($name in @($Variables.Keys | Sort-Object)) {
        $value = ([string]$Variables[$name] -replace '[\r\n]+', ' ').Trim()
        if ($value) { "${name}: $value" }
    }
    $text = (@($parts) -join ' | ')
    $max = Get-SettingInt 'AuditTemplateValuesMaxChars' 1
    if ($text.Length -gt $max) { $text = $text.Substring(0, $max) + '…' }
    return $text
}

function Write-AirOperationResult {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][ValidateSet('SHOW', 'HIDE', 'EXIT', 'UPDATE')][string]$Action,
        [Parameter(Mandatory)][ValidateSet('success', 'failed', 'blocked')][string]$Result,
        [Parameter(Mandatory)][long]$DurationMs,
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][long]$ChatId,
        [int]$Layer = 0,
        [string]$Target = '',
        [string]$ErrorText = '',
        [string]$Values = ''
    )
    $cleanTarget = ($Target -replace '[\r\n]+', ' ').Replace('"', "'")
    $cleanError = ($ErrorText -replace '[\r\n]+', ' ').Replace('"', "'")
    $displayName = [string](Get-UserDisplayName -UserId $UserId)
    $cleanUserName = if ($displayName -eq [string]$UserId) { '' } else {
        Protect-SensitiveText ((($displayName -replace '[\r\n]+', ' ').Trim()).Replace('"', "'"))
    }
    $message = "AIR_OP id=$OperationId action=$Action result=$Result durationMs=$DurationMs user=$UserId chat=$ChatId layer=$Layer target=`"$cleanTarget`""
    if ($cleanUserName) { $message += " userName=`"$cleanUserName`"" }
    if (-not [string]::IsNullOrWhiteSpace($cleanError)) { $message += " error=`"$cleanError`"" }
    $level = if ($Result -eq 'success') { 'INFO' } else { 'WARN' }
    $counterName = switch ($Result) { 'success' { 'Success' }; 'failed' { 'Failed' }; default { 'Blocked' } }
    $script:AirOperationCounters[$counterName] = [int]$script:AirOperationCounters[$counterName] + 1
    Complete-BridgeOperation -Ledger $script:BridgeOperationLedger -OperationId $OperationId -Result $Result -ErrorText $ErrorText | Out-Null
    Add-UserOperationHistory -OperationId $OperationId -Action $Action -Result $Result -DurationMs $DurationMs -UserId $UserId -Layer $Layer -Target $Target -Values $Values
    Write-AuditRecord -OperationId $OperationId -EventName air_control -Result $Result -UserId $UserId -UserName $cleanUserName -ChatId $ChatId -Action $Action -Layer $Layer -Target $Target -DurationMs $DurationMs -Message $ErrorText -Values $Values
    Write-BridgeLog $message $level
}

function Get-TemplateNotifyScope {
    <#
        Who should hear that this template went on air: none, admins, or every
        authorised chat.

        Read from one setting an administrator can edit from a phone -
        "Urgent=all, Banner=admins" - rather than from a rule the bridge
        invents. "عاجل" on one station is "Breaking" on another, and which
        graphics are worth interrupting a room for is a newsroom's decision,
        not a program's.

        A name written without a scope means all: someone who bothered to list
        a template wants somebody told, and the safe reading of an incomplete
        rule is the one that informs rather than the one that silences.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return 'none' }
    foreach ($rule in (([string](Get-Setting 'TemplateNotifyRules')) -split ',')) {
        $parts = @($rule -split '=', 2 | ForEach-Object { $_.Trim() })
        $name = [string]$parts[0]
        if (-not $name) { continue }
        if (-not [string]::Equals($name, $Key, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $scope = if ($parts.Count -gt 1) { ([string]$parts[1]).ToLowerInvariant() } else { 'all' }
        if ($scope -in @('none', 'admins', 'all')) { return $scope }
        return 'all'
    }
    return 'none'
}

function Get-TemplateNoticeAudience {
    <# Who hears it, minus the person who did it: they are looking at their own
       confirmation, and a second message telling them what they just did is
       the kind of noise that gets a bot muted. #>
    param([Parameter(Mandatory)][string]$Scope, [long]$ActorChatId = 0)
    if ($Scope -eq 'none') { return @() }
    $ids = if ($Scope -eq 'all') {
        @(@(Get-JsonProp $config 'AllowedChatIds') | ForEach-Object { [long]$_ })
    }
    else { @(Get-AdminNotifyIds) }
    return @($ids | Where-Object { $_ -gt 0 -and $_ -ne $ActorChatId } | Sort-Object -Unique)
}

function Send-TemplateAirNotice {
    <#
        Tells the room that a graphic is on air: which, what it says, who put
        it there, and how long it stays.

        The copy is the point. "عاجل على الطبقة 7" tells a newsroom that
        something happened; the sentence that is on the screen tells them
        whether it is the one they are already handling, which is the only
        version anybody can act on. The duration is the second question they
        ask, and answering it in the same message saves the reply.

        Silent unless a template was named: a station shows dozens of graphics
        a day, and a bot that reports each one is a bot people mute - and a
        muted bot loses the message that mattered.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key,
        [int]$Layer = 0,
        [long]$ActorChatId = 0,
        [AllowEmptyString()][string]$ActorName = '',
        [AllowEmptyString()][string]$Copy = '',
        [int]$AutoHideSeconds = 0,
        [ValidateSet('show', 'hide')][string]$Action = 'show',
        [AllowNull()]$OnAirSince = $null
    )
    $scope = Get-TemplateNotifyScope -Key $Key
    $audience = @(Get-TemplateNoticeAudience -Scope $scope -ActorChatId $ActorChatId)
    if ($audience.Count -eq 0) { return 0 }
    if (-not (Test-AirNoticeDue -Key $Key -Layer $Layer -Action $Action)) { return 0 }

    $lines = [System.Collections.Generic.List[string]]::new()
    $layerPart = if ($Layer -gt 0) { " · طبقة $Layer" } else { '' }
    $heading = if ($Action -eq 'hide') { '⚫️ <b>رُفع عن الهواء</b>' } else { '🔴 <b>على الهواء الآن</b>' }
    $lines.Add("$heading — $(ConvertTo-TelegramHtmlText $Key)$layerPart")
    if (-not [string]::IsNullOrWhiteSpace($Copy)) {
        # In a code span, like every other place the on-air copy appears: it is
        # what will be read on television, and it is not a label.
        $lines.Add("<code>$(ConvertTo-TelegramHtmlText $Copy)</code>")
    }
    if ($Action -eq 'hide') {
        # How long it was up, which is the question a take-down raises: a
        # strap that ran four minutes was read; one that ran four seconds was
        # a mistake somebody has already corrected.
        if ($OnAirSince -is [datetime]) {
            $lines.Add("⏱ بقي $(Format-DurationSeconds -Seconds ([int]((Get-Date) - $OnAirSince).TotalSeconds))")
        }
    }
    else {
        $lines.Add($(if ($AutoHideSeconds -gt 0) { "⏱ يُخفى تلقائيًا بعد $(Format-DurationSeconds -Seconds $AutoHideSeconds)" } else { '⏱ يبقى حتى يُخفى يدويًا' }))
    }
    if ($ActorName) { $lines.Add("👤 $(ConvertTo-TelegramHtmlText $ActorName)") }
    $text = $lines -join "`n"
    $markup = Get-AirNoticeMuteKeyboard
    # $delivered, not $sent: a mock in a test can resolve a bare name up the
    # call stack, and a common one here collides with the caller's.
    $delivered = 0
    foreach ($chatId in $audience) {
        # Muted per person, checked here rather than when the audience is
        # built: the audience is who the newsroom decided should hear, and
        # this is one person's own answer to it.
        if (Test-AirNoticeMuted -UserId $chatId) { continue }
        if (Send-AirNoticeOrHold -ChatId $chatId -Text $text -Markup $markup) { $delivered++ }
    }
    # Whoever is preparing this same graphic hears about it differently, and
    # regardless of their mute: this is not news about the channel, it is news
    # about the thing in their hands.
    Send-AirCollisionWarning -Key $Key -Layer $Layer -ActorChatId $ActorChatId -ActorName $ActorName -Action $Action | Out-Null
    Write-BridgeLog "Air notice ($Action) for '$Key' sent to $delivered chat(s) (scope: $scope)"
    return $delivered
}

# Notices that arrived while somebody was in the middle of typing, waiting
# for them to finish.
$script:AirNoticeHeld = @{}

function Send-AirNoticeOrHold {
    <#
        Sends the notice, unless the person is mid-sentence.

        An editor typing the third headline of a ticker does not lose their
        place to an incoming message - the flow is state on the server, not
        the last thing in the chat - but the prompt they were reading scrolls
        away, and on a phone that is the same thing. Somebody entering a
        bulletin row, a banner's copy or an urgent headline is doing the work
        the notice is about; interrupting them to describe it is the worst
        moment there is.

        Held rather than dropped: what went on air is still worth knowing
        when they look up. Delivered by Send-HeldAirNotices the moment the
        flow ends.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Text, [hashtable]$Markup)
    if (-not (Get-PendingState -ChatId $ChatId)) {
        Send-TelegramMessage -ChatId $ChatId -Text $Text -ParseMode HTML -ReplyMarkup $Markup
        return $true
    }
    if (-not $script:AirNoticeHeld.ContainsKey($ChatId)) {
        $script:AirNoticeHeld[$ChatId] = [System.Collections.Generic.List[string]]::new()
    }
    # Capped: a long flow during a busy hour must not end in a wall of
    # messages, which is its own kind of interruption.
    if ($script:AirNoticeHeld[$ChatId].Count -lt 5) { $script:AirNoticeHeld[$ChatId].Add($Text) }
    return $false
}

function Send-HeldAirNotices {
    <# Everything that happened while they were typing, in one message. #>
    param([Parameter(Mandatory)][long]$ChatId)
    if (-not $script:AirNoticeHeld.ContainsKey($ChatId)) { return 0 }
    $pending = @($script:AirNoticeHeld[$ChatId])
    $script:AirNoticeHeld.Remove($ChatId)
    if ($pending.Count -eq 0) { return 0 }
    $header = if ($pending.Count -eq 1) { '📣 <b>حدث أثناء انشغالك:</b>' } else { "📣 <b>حدث أثناء انشغالك ($($pending.Count)):</b>" }
    $body = (@($header) + $pending) -join "`n`n"
    Send-TelegramMessage -ChatId $ChatId -Text $body -ParseMode HTML -ReplyMarkup (Get-AirNoticeMuteKeyboard)
    return $pending.Count
}

function Send-AirCollisionWarning {
    <#
        Tells whoever is preparing this graphic that it has just gone out
        without them.

        The layer lock stops two people starting a flow on the same layer,
        but nothing stopped a preset, a schedule or a second operator on
        another layer from publishing the very template somebody is typing
        into - and the first they knew was their own text failing to appear,
        or worse, replacing what was already right.

        Sent whatever their mute says: a mute means "do not tell me what the
        channel is doing", not "do not tell me my work has been overtaken".
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Key,
        [int]$Layer = 0,
        [long]$ActorChatId = 0,
        [AllowEmptyString()][string]$ActorName = '',
        [string]$Action = 'show'
    )
    if ([string]::IsNullOrWhiteSpace($Key)) { return 0 }
    $warned = 0
    foreach ($entry in @($script:PendingState.GetEnumerator())) {
        $chatId = [long]$entry.Key
        if ($chatId -eq $ActorChatId) { continue }
        $state = $entry.Value
        $stateKey = [string](Get-JsonProp $state 'Key')
        $stateLayer = [int](Get-JsonProp $state 'LockLayer')
        # The same template, or the same layer - either way what they are
        # preparing is about to land on top of something new.
        $sameTemplate = $stateKey -and [string]::Equals($stateKey, $Key, [System.StringComparison]::OrdinalIgnoreCase)
        $sameLayer = $Layer -gt 0 -and $stateLayer -eq $Layer
        if (-not ($sameTemplate -or $sameLayer)) { continue }
        $verb = if ($Action -eq 'hide') { 'رُفع عن الهواء' } else { 'عُرض على الهواء' }
        $who = if ($ActorName) { " بواسطة $(ConvertTo-TelegramHtmlText $ActorName)" } else { '' }
        Send-TelegramMessage -ChatId $chatId -ParseMode HTML `
            -Text "⚠️ <b>$(ConvertTo-TelegramHtmlText $Key) $verb$who أثناء تجهيزك.</b>`nراجع ما أعددته قبل الإرسال — قد يكون ما على الشاشة قد تغيّر."
        $warned++
    }
    if ($warned -gt 0) { Write-BridgeLog "Warned $warned operator(s) preparing '$Key' that it just changed on air" }
    return $warned
}

# The last time each template said something, so a burst of pushes is not a
# burst of messages.
$script:AirNoticeLastSent = @{}

function Test-AirNoticeDue {
    <#
        Whether this notice should go out, or whether the room has just been
        told the same thing.

        An operator correcting a headline pushes the same template three
        times in twenty seconds; as far as the room is concerned the strap
        changed once, and three identical interruptions is how a notification
        becomes something people turn off. The window is short - half a
        minute - because the same graphic going up again minutes later is
        news again.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Key, [int]$Layer = 0, [string]$Action = 'show')
    $signature = "$Action|$Key|$Layer"
    $now = Get-Date
    if ($script:AirNoticeLastSent.ContainsKey($signature)) {
        $elapsed = ($now - $script:AirNoticeLastSent[$signature]).TotalSeconds
        if ($elapsed -lt 30) { return $false }
    }
    $script:AirNoticeLastSent[$signature] = $now
    return $true
}

function Get-AirNoticeMuteKeyboard {
    <# One button, on every notice: the person being interrupted can stop
       being interrupted without hunting for a settings screen. A bot with no
       way out is a bot muted at the operating system level, and then the
       alert that mattered is gone too. #>
    return @{ inline_keyboard = @(, @((New-Button '🔕 أوقف تنبيهاتي' 'notice:mute'))) }
}

function Test-MaintenanceWindowActive {
    <# The nightly slot when the playout machine is patched or re-cabled. An
       unset or malformed window is no window: this must never fail closed and
       silently block control of a live channel. #>
    return (Test-BridgeMaintenanceWindow -Now (Get-Date) `
            -StartTime ([string](Get-Setting 'MaintenanceWindowStart')) `
            -EndTime ([string](Get-Setting 'MaintenanceWindowEnd')))
}

function Test-MaintenanceControl {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [switch]$EmergencyOverride)
    $manual = [bool](Get-Setting 'MaintenanceMode')
    $scheduled = Test-MaintenanceWindowActive
    if (-not $manual -and -not $scheduled) { return $true }
    # The emergency override still works during a scheduled window: a machine
    # being patched is no reason an administrator cannot pull a graphic that
    # is wrongly on air.
    if ($EmergencyOverride -and (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $true }
    $reason = if ($scheduled -and -not $manual) {
        "🛠 نافذة الصيانة المجدولة مفتوحة ($([string](Get-Setting 'MaintenanceWindowStart'))–$([string](Get-Setting 'MaintenanceWindowEnd')))؛ أوامر الهواء متوقفة حتى نهايتها."
    }
    else { '🛠 وضع الصيانة مفعّل؛ أوامر التحكم في الهواء متوقفة مؤقتًا.' }
    Send-TelegramMessage -ChatId $ChatId -Text $reason -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $false
}

function Get-BridgeKeyList {
    <# One reading of the comma-or-newline lists these settings are written
       in, so every list behaves the same way. #>
    param([string]$Value = '')
    return @([string]$Value -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-BridgeListContains {
    param([string]$Value = '', [string]$Item = '')
    if (-not $Item) { return $false }
    return (@(Get-BridgeKeyList -Value $Value | Where-Object { $_.Equals($Item, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
}

function Get-TemplateAccessLevel {
    <#
        Who may put this graphic on air, and take it off: 'all', 'admin' or
        'owner'.

        A template can be named directly, and so can the layer it sits on - a
        station logo is protected by where it lives as much as by what it is.
        Where both apply the stricter wins, because a permission that loosens
        when you add a second rule is not a permission.

        Everything unnamed is 'all', which is what every template was before
        any of these lists existed.
    #>
    param([string]$Key = '', [int]$Layer = 0)
    $layerText = if ($Layer -gt 0) { [string]$Layer } else { '' }
    if ((Test-BridgeListContains -Value (Get-Setting 'OwnerOnlyTemplateKeys') -Item $Key) -or
        (Test-BridgeListContains -Value (Get-Setting 'OwnerOnlyLayers') -Item $layerText)) { return 'owner' }
    if ((Test-BridgeListContains -Value (Get-Setting 'AdminOnlyTemplateKeys') -Item $Key) -or
        (Test-BridgeListContains -Value (Get-Setting 'AdminOnlyLayers') -Item $layerText)) { return 'admin' }
    return 'all'
}

function Test-LayersScreenAccess {
    <# Who may open the layers screen, in the same words the other permissions
       use: everyone, administrators, or the owner. It is a screen of raw
       controls - hide, exit, push to a bare layer number - so a newsroom that
       wants its operators working through templates alone can close it. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    switch ([string](Get-Setting 'LayersScreenAccess')) {
        'owner' { return (Test-Owner -ChatId $ChatId -UserId $UserId) }
        'admin' { return (Test-Admin -ChatId $ChatId -UserId $UserId) }
    }
    return $true
}

function Test-TemplateAccess {
    <# The same question for showing and for hiding: taking a protected
       graphic off air changes the screen as much as putting it on. #>
    param([string]$Key = '', [int]$Layer = 0, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $level = Get-TemplateAccessLevel -Key $Key -Layer $Layer
    $what = if ($Key) { "القالب '$Key'" } else { "الطبقة $Layer" }
    if ($level -eq 'owner') {
        if (Test-Owner -ChatId $ChatId -UserId $UserId) { return [pscustomobject]@{ Allowed = $true; Reason = ''; Level = $level } }
        return [pscustomobject]@{ Allowed = $false; Reason = "$what لمالك الجسر وحده."; Level = $level }
    }
    if ($level -eq 'admin') {
        if (Test-Admin -ChatId $ChatId -UserId $UserId) { return [pscustomobject]@{ Allowed = $true; Reason = ''; Level = $level } }
        return [pscustomobject]@{ Allowed = $false; Reason = "$what للمشرفين وحدهم."; Level = $level }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = ''; Level = $level }
}

function Test-TemplateShowPolicy {
    <# A reserved layer normally carries something that must not be disturbed -
       a station logo, a clock, a permanent ticker. Administrators may still
       push to one deliberately, since they are who reserved it; operators
       cannot. Pass -IsAdmin only where the caller has actually checked. #>
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][int]$Layer, [switch]$IsAdmin)
    $reserved = @()
    foreach ($part in ([string](Get-Setting 'ReservedLayers') -split '[,;\s]+')) {
        $parsedLayer = 0
        if ([int]::TryParse($part.Trim(), [ref]$parsedLayer) -and $parsedLayer -gt 0) { $reserved += $parsedLayer }
    }
    if ($reserved -contains $Layer -and -not $IsAdmin) {
        return [pscustomobject]@{ Allowed = $false; Reason = "الطبقة $Layer محجوزة إداريًا."; Warning = '' }
    }
    if ($reserved -contains $Layer) {
        return [pscustomobject]@{ Allowed = $true; Reason = ''; Warning = "⚠️ الطبقة $Layer محجوزة — تتجاوزها بصلاحية المشرف." }
    }
    $disabled = @([string](Get-Setting 'DisabledTemplateKeys') -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (@($disabled | Where-Object { $_.Equals($Key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        return [pscustomobject]@{ Allowed = $false; Reason = "القالب '$Key' معطّل مؤقتًا."; Warning = '' }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = ''; Warning = '' }
}

function Get-EffectiveAutoHideSeconds {
    param(
        [Parameter(Mandatory)][string]$Key,
        [int]$RequestedSeconds = 0
    )
    $sensitiveKeys = @([string](Get-Setting 'SensitiveTemplateKeys') -split '[,;\r\n]+' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $isSensitive = @($sensitiveKeys | Where-Object { $_.Equals($Key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    $seconds = [math]::Max(0, $RequestedSeconds)
    $templateMaximum = 0
    $rawMaximum = Get-JsonProp (Get-Setting 'TemplateMaxAirSeconds') $Key
    if (-not [int]::TryParse([string]$rawMaximum, [ref]$templateMaximum)) { $templateMaximum = 0 }
    $limits = @($templateMaximum)
    if ($isSensitive) { $limits += Get-SettingInt 'SensitiveTemplateAutoHideSeconds' 1 }
    foreach ($limit in $limits) {
        if ($limit -gt 0 -and ($seconds -eq 0 -or $limit -lt $seconds)) { $seconds = $limit }
    }
    return $seconds
}

function Copy-ShowVariables {
    param([hashtable]$Variables = @{})
    $copy = @{}
    foreach ($name in $Variables.Keys) { $copy[[string]$name] = [string]$Variables[$name] }
    return $copy
}

function Set-RollbackCandidate {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][hashtable]$RestoreSnapshot,
        [Parameter(Mandatory)][ValidateSet('replace','hidden')][string]$ExpectedState,
        [string]$ExpectedActiveId = '',
        [Parameter(Mandatory)][long]$ActorUserId
    )
    if (-not (Get-Setting 'EnableSafeRollback')) { return }
    $window = [math]::Max(10, [math]::Min(900, (Get-SettingInt 'RollbackWindowSeconds' 10)))
    $script:RollbackCandidates[$Layer] = @{
        Id=[guid]::NewGuid().ToString('N'); Layer=$Layer; Restore=$RestoreSnapshot
        ExpectedState=$ExpectedState; ExpectedActiveId=$ExpectedActiveId
        ActorUserId=$ActorUserId; CreatedAt=(Get-Date); ExpiresAt=(Get-Date).AddSeconds($window)
    }
}

function Get-RollbackCandidate {
    param([Parameter(Mandatory)][int]$Layer, [long]$UserId = 0)
    if (-not (Get-Setting 'EnableSafeRollback')) { return $null }
    if (-not $script:RollbackCandidates.ContainsKey($Layer)) { return $null }
    $candidate = $script:RollbackCandidates[$Layer]
    if ((Get-Date) -ge [datetime]$candidate.ExpiresAt) { $script:RollbackCandidates.Remove($Layer) | Out-Null; return $null }
    if ($UserId -gt 0 -and [long]$candidate.ActorUserId -ne $UserId -and -not (Test-Admin -ChatId $UserId -UserId $UserId)) { return $null }
    return $candidate
}

function Get-CorrelatedLayerSnapshot {
    param([Parameter(Mandatory)][int]$Layer, $LiveStatus)
    if (-not $script:LastSuccessfulLayerShows.ContainsKey($Layer) -or -not $LiveStatus -or
        -not $LiveStatus.Success -or $LiveStatus.IsOnAir -ne $true) { return $null }
    $snapshot = $script:LastSuccessfulLayerShows[$Layer]
    $activeId = [string](Get-JsonProp $LiveStatus 'ActiveId')
    if ([string]::IsNullOrWhiteSpace($activeId) -or $activeId -ne [string]$snapshot.ActiveId) { return $null }
    return $snapshot
}

function Get-VerifiedCinegyShowIdentity {
    <#
        Resolve the engine's active item while the successful SHOW operation is
        still in hand. This is the only safe moment to translate Cinegy's
        client EventId into its engine ActiveId: a later watchdog observation
        may already describe a replacement and must never inherit old work.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$TemplatePath = '',
        [Parameter(Mandatory)][int]$Layer,
        [AllowEmptyString()][string]$ExpectedPreviousActiveId = '',
        [AllowEmptyString()][string]$ExpectedActiveId = '',
        [switch]$AllowAnonymousActiveId
    )
    $failed = { param([string]$Reason) [pscustomobject]@{ Success=$false; ActiveId=''; Error=$Reason } }
    $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -Layer $Layer `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not [bool](Get-JsonProp $status 'Success') -or -not [bool](Get-JsonProp $status 'IsOnAir')) {
        return (& $failed 'لم يؤكد Cinegy أن المشهد على الهواء بعد SHOW.')
    }
    $activeId = [string](Get-JsonProp $status 'ActiveId')
    $normalizedId = $activeId.Trim().Trim('{', '}')
    if ([string]::IsNullOrWhiteSpace($normalizedId) -or $normalizedId -eq '00000000-0000-0000-0000-000000000000') {
        return (& $failed 'لم يعرض Cinegy معرّفًا نشطًا صالحًا.')
    }

    $expectedPreviousId = ([string]$ExpectedPreviousActiveId).Trim().Trim('{', '}')
    $expectedCurrentId = ([string]$ExpectedActiveId).Trim().Trim('{', '}')

    # Prefer the filename parsed from Cinegy's active-item description. Falling
    # back to ActiveName is allowed only as an exact name, never a substring.
    $reported = [string](Get-JsonProp $status 'ActiveTemplateName')
    if ([string]::IsNullOrWhiteSpace($reported)) { $reported = [string](Get-JsonProp $status 'ActiveName') }
    if ([string]::IsNullOrWhiteSpace($reported)) {
        # Some Cinegy items expose a valid engine identity but no Name or
        # Description. Accept that shape only when the id itself proves the
        # relation: it is either the already-confirmed id for a manual timer,
        # or a new id observed immediately after this bridge's SHOW.
        if ($AllowAnonymousActiveId -and
            ((-not [string]::IsNullOrWhiteSpace($expectedCurrentId) -and
              $normalizedId.Equals($expectedCurrentId, [StringComparison]::OrdinalIgnoreCase)) -or
             (-not [string]::IsNullOrWhiteSpace($expectedPreviousId) -and
              -not $normalizedId.Equals($expectedPreviousId, [StringComparison]::OrdinalIgnoreCase)))) {
            return [pscustomobject]@{ Success=$true; ActiveId=$activeId; Error=''; IdentitySource='active-id-correlation' }
        }
        return (& $failed 'لم يعرض Cinegy اسم قالب يمكن مطابقته.')
    }
    $reported = $reported.Trim()
    $reportedWithoutExtension = [IO.Path]::GetFileNameWithoutExtension($reported)
    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expected.Add($Key.Trim()) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($TemplatePath)) {
        $expected.Add([IO.Path]::GetFileName($TemplatePath).Trim()) | Out-Null
        $expected.Add([IO.Path]::GetFileNameWithoutExtension($TemplatePath).Trim()) | Out-Null
    }
    if (-not ($expected.Contains($reported) -or $expected.Contains($reportedWithoutExtension))) {
        return (& $failed "اسم المشهد الذي أعاده Cinegy لا يطابق '$Key'.")
    }
    return [pscustomobject]@{ Success=$true; ActiveId=$activeId; Error=''; IdentitySource='template-name' }
}

function Invoke-ShowTemplateResult {
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Variables = @{},
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [int]$AutoHideSeconds = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $AutoHideSeconds = Get-EffectiveAutoHideSeconds -Key $Key -RequestedSeconds $AutoHideSeconds
    $operation = New-AirOperationContext -Action SHOW -UserId $UserId
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target $Key -Values (Format-AuditTemplateValues -Variables $Variables) -ErrorText 'maintenance mode'
        return [pscustomobject]@{ Success = $false; Error = 'وضع الصيانة مفعّل.' }
    }
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($Key)) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب '$Key' غير معروف." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target $Key -Values (Format-AuditTemplateValues -Variables $Variables) -ErrorText 'unknown template'
        return
    }
    $template = $store.Map[$Key]
    $attemptVariables = @{}
    foreach ($variableName in $Variables.Keys) { $attemptVariables[[string]$variableName] = [string]$Variables[$variableName] }
    $script:LastShowAttempts[[string]$UserId] = @{
        Key = $Key; Variables = $attemptVariables; AutoHideSeconds = $AutoHideSeconds
    }
    $access = Test-TemplateAccess -Key $Key -Layer ([int]$template.Layer) -ChatId $ChatId -UserId $UserId
    if (-not $access.Allowed) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لم يتم الإرسال: $($access.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -Values (Format-AuditTemplateValues -Variables $Variables) -ErrorText ([string]$access.Reason)
        return [pscustomobject]@{ Success = $false; Error = [string]$access.Reason }
    }
    $policy = Test-TemplateShowPolicy -Key $Key -Layer ([int]$template.Layer) -IsAdmin:(Test-Admin -ChatId $ChatId -UserId $UserId)
    if (-not $policy.Allowed) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لم يتم الإرسال: $($policy.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -Values (Format-AuditTemplateValues -Variables $Variables) -ErrorText ([string]$policy.Reason)
        return [pscustomobject]@{ Success = $false; Error = [string]$policy.Reason }
    }

    # SHOW is the only operation that can replace visible content. Verify the
    # target layer immediately before mutating it; an unreachable Cinegy must
    # never be interpreted as an empty or safe layer.
    $layerStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -Layer ([int]$template.Layer) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not $layerStatus.Success) {
        $errorText = [string](Get-JsonProp $layerStatus 'Error')
        Write-BridgeLog "Blocked SHOW '$Key' on layer $($template.Layer): live Cinegy verification failed: $errorText" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لم يتم الإرسال: تعذّر التحقق من حالة طبقة Cinegy $($template.Layer). أعد فحص الحالة ثم حاول مجددًا." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -Values (Format-AuditTemplateValues -Variables $Variables) -ErrorText $errorText
        return [pscustomobject]@{ Success = $false; Error = 'تعذّر التحقق من حالة طبقة Cinegy.' }
    }
    $layerStatus | Add-Member -NotePropertyName Layer -NotePropertyValue ([int]$template.Layer) -Force
    Update-OnAirStateFromCinegy -Reason 'before-show' -LayerStatuses @($layerStatus) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal | Out-Null
    $previousSnapshot = Get-CorrelatedLayerSnapshot -Layer ([int]$template.Layer) -LiveStatus $layerStatus

    # The urgent outranks the bulletin, whatever put it on air - a button, a
    # schedule, a rollback. Every SHOW passes here, so the rule is stated once.
    #
    # Below the gates, not above them. It used to run the moment the template
    # was resolved, so an operator allowed on the bot but not on this template
    # took the bulletin off air and was THEN refused their urgent: a request
    # that changed the channel by being denied. Nothing that alters the air may
    # run before the answer to "may they" is known - and now that includes an
    # unreachable Cinegy, which is refused above.
    if ($Key -eq $script:MojazUrgentKey) {
        Clear-MojazForUrgent -ChatId $ChatId -UserId $UserId | Out-Null
        # And the board, which plays on this same scene. The older, simpler
        # path wins: an operator reaching for the single urgent button during a
        # board run is asking for that one line, now.
        #
        # This is skipped while the board's own opening SHOW is in flight -
        # that SHOW carries this very key, so without the flag the board would
        # be stopped by the command that starts it.
        Stop-UrgentBoardForManualUrgent -ChatId $ChatId -UserId $UserId | Out-Null
    }

    # A scene that is already loaded on the layer keeps running with the values
    # it was started with, so a second SHOW can leave the PREVIOUS text on air.
    # Taking the layer down first forces the scene to initialise with the new
    # variables. (To change text without re-firing the animation, use the
    # ✏️ تحديث نص button, which writes to the live postbox instead.)
    $operationStarted = $false
    if ((Get-Setting 'ReshowClearsLayer') -and $script:OnAir.ContainsKey([int]$template.Layer)) {
        Start-AirOperation -Operation $operation -Action SHOW -Layer ([int]$template.Layer) -UserId $UserId
        $operationStarted = $true
        $clear = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $template.Layer -TimeoutSec (Get-AirTimeout)
        # Reported whether or not the XML log is on. This clear exists because
        # a scene already loaded keeps the values it started with, so a failed
        # clear is the exact condition under which the NEXT line puts the new
        # text nowhere and leaves the previous headline on air - and it was
        # visible only to someone who had turned on a debug setting.
        if (-not $clear.Success) {
            Write-BridgeLog "Pre-show clear of layer $($template.Layer) failed before showing '$Key': $($clear.Error). The scene may keep its previous values." 'WARN'
        }
        elseif (Get-Setting 'LogAirXml') { Write-BridgeLog "Air pre-show HIDE on layer $($template.Layer): success=$($clear.Success)" }
    }

    # Only pass through explicit per-field type overrides; everything else
    # takes the AirVariableType default.
    $types = @{}
    foreach ($name in @($template.FieldTypes.Keys)) {
        if ($template.FieldTypes[$name]) { $types[$name] = [string]$template.FieldTypes[$name] }
    }
    $defaultType = [string](Get-Setting 'AirVariableType')
    if ([string]::IsNullOrWhiteSpace($defaultType)) { $defaultType = 'Text' }

    if (-not $operationStarted) { Start-AirOperation -Operation $operation -Action SHOW -Layer ([int]$template.Layer) -UserId $UserId }
    $result = Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $template.Layer -TemplatePath $template.Path -Variables $Variables `
        -Types $types -DefaultType $defaultType -TimeoutSec (Get-AirTimeout)

    # Air Pro answers 200 OK even when it does not recognise a variable name,
    # so "Success" only means the request was accepted - not that the text
    # landed. Turn on LogAirXml to see exactly what was transmitted.
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air SHOW XML: $($result.Xml)" }

    if ($result.Success) {
        # T-15: the "before" of before/after. The last cached frame is
        # inherently pre-show - nothing captures during the SHOW itself - so
        # it is kept by reference when fresh, never re-taken: a synchronous
        # grab here would hold a live show for its whole timeout. The "after"
        # is taken on demand when the rollback review opens.
        $beforeFile = [string]$script:LastSnapshotFile
        if (-not [string]::IsNullOrWhiteSpace($beforeFile) -and (Test-Path -LiteralPath $beforeFile) -and
            ((Get-Date) - [datetime]$script:LastSnapshotAt).TotalMinutes -le 15) {
            $script:RollbackBeforeFiles[[int]$template.Layer] = $beforeFile
        }
        else {
            $script:RollbackBeforeFiles.Remove([int]$template.Layer) | Out-Null
        }
        # T-16: settle the flow clock. Only a flow this operator opened counts:
        # scheduled fires and retries carry no FlowStartedAt and must not
        # flatter a template's average with their waiting time.
        $flowState = Get-PendingState -ChatId $ChatId
        $flowStartText = if ($flowState) { [string](Get-JsonProp $flowState 'FlowStartedAt') } else { '' }
        $flowStart = [datetime]::MinValue
        if (-not [string]::IsNullOrWhiteSpace($flowStartText) -and [datetime]::TryParse($flowStartText, [ref]$flowStart)) {
            $seconds = [math]::Max(0, [int]((Get-Date) - $flowStart).TotalSeconds)
            $timingKey = [string]$Key
            $prior = $script:ShowFlowTimings[$timingKey]
            $count = 0; $total = 0
            if ($prior) {
                [int]::TryParse([string](Get-JsonProp $prior 'Count'), [ref]$count) | Out-Null
                [int]::TryParse([string](Get-JsonProp $prior 'TotalSeconds'), [ref]$total) | Out-Null
            }
            $script:ShowFlowTimings[$timingKey] = @{ Count = ($count + 1); TotalSeconds = ($total + $seconds) }
        }
        $reminderMinutes = [int](Get-JsonProp $template 'ReminderMinutes')
        $activeId = [string]$result.EventId
        $activeIdConfirmed = $false
        # Capture Cinegy's engine id for every successful SHOW. The old bridge
        # kept the client EventId, which happened to work until Cinegy returned
        # a different identity. An anonymous active item is accepted only when
        # its engine id changed from the pre-SHOW item.
        $identity = Get-VerifiedCinegyShowIdentity -Key $Key -TemplatePath ([string](Get-JsonProp $template 'Path')) `
            -Layer ([int]$template.Layer) -ExpectedPreviousActiveId ([string](Get-JsonProp $layerStatus 'ActiveId')) `
            -AllowAnonymousActiveId
        if ($identity.Success) { $activeId = [string]$identity.ActiveId; $activeIdConfirmed = $true }
        if ($previousSnapshot) {
            Set-RollbackCandidate -Layer ([int]$template.Layer) -RestoreSnapshot $previousSnapshot `
                -ExpectedState replace -ExpectedActiveId $activeId -ActorUserId $UserId
        }
        elseif ($layerStatus.Success -and $false -eq [bool]$layerStatus.IsOnAir) {
            # Pushing onto a layer that was genuinely EMPTY used to leave
            # nothing to undo, which is the commonest mistake there is: the
            # wrong template, on a layer that had nothing on it. Undoing that
            # means taking it back off, so the restore is a hide.
            #
            # Only when the layer was verifiably empty. If correlation failed -
            # something the bridge cannot identify was on that layer - a hide
            # would silently discard it rather than restore anything, so no
            # undo is offered and the operator decides deliberately.
            Set-RollbackCandidate -Layer ([int]$template.Layer) `
                -RestoreSnapshot @{ Key = [string]$Key; Action = 'hide' } `
                -ExpectedState replace -ExpectedActiveId $activeId -ActorUserId $UserId
        }
        else { $script:RollbackCandidates.Remove([int]$template.Layer) | Out-Null }
        # Three of the same graphic in an hour is almost always a paste slip or
        # a double tap. Asked after the push, never before: blocking a repeat
        # that was deliberate would be worse than the mistake it prevents.
        if (Test-RepeatedShow -Key ([string]$Key)) {
            Send-TelegramMessage -ChatId $ChatId -Text "🔁 تكرار غير معتاد: عُرض '$Key' عدة مرات خلال فترة قصيرة.`nهل هذا مقصود؟ إن لم يكن، اضغط ↩️ تراجع من القائمة."
        }
        $script:LastSuccessfulLayerShows[[int]$template.Layer] = @{
            Key=$Key; Variables=(Copy-ShowVariables -Variables $Variables); UserId=$UserId; ChatId=$ChatId
            ActiveId=$activeId; ActiveIdConfirmed=$activeIdConfirmed; At=(Get-Date)
        }
        $script:LastShow[$ChatId] = @{ Key = $Key; Variables = $Variables }
        Set-OnAirShownRecord -Layer ([int]$template.Layer) -Record @{
            Key = $Key; At = (Get-Date); UserId = $UserId; ActiveId = $activeId
            ActiveIdConfirmed = $activeIdConfirmed
            # The copy travels with the record so that taking it off air can
            # say what came off. Until now hide and exit recorded a layer
            # number and nothing else, and the history could only report that
            # something was hidden - never which strap.
            AirCopy = (Format-AuditTemplateValues -Variables $Variables)
            # What it says, for whoever is about to take it off. Kept apart
            # from AirCopy on purpose: that one is gated by the audit setting
            # because audit.jsonl is archived for ever, while this is read
            # once on a confirmation screen and thrown away with the record.
            ScreenCopy = (Format-OnAirScreenCopy -Key $Key -Variables $Variables)
        }
        Save-OnAirState
        Add-UsageCount -Key $Key
        $actor = Format-UserAuditActor -UserId $UserId
        Write-BridgeLog "User $actor (chat $ChatId) pushed template '$Key' (layer $($template.Layer))"
        Add-AuditEntry "▶ $Key (طبقة $($template.Layer)) - بواسطة $actor"
        # The room hears about the templates it asked to hear about, with what
        # they say and how long they stay.
        Send-TemplateAirNotice -Key $Key -Layer ([int]$template.Layer) -ActorChatId $ChatId `
            -ActorName $actor -Copy (Format-OnAirScreenCopy -Key $Key -Variables $Variables) `
            -AutoHideSeconds $AutoHideSeconds | Out-Null

        # Belt and braces: also write the values through the postbox, which is
        # the channel this scene actually honours.
        if ((Get-Setting 'SetValuesAfterShow') -and $Variables.Count -gt 0) {
            $delay = Get-SettingInt 'PostShowDelayMs' 0
            # Stamped with what is on the layer now, so the write can prove at
            # fire time that it is still addressing the same scene.
            $liveScene = if ($script:OnAir.ContainsKey([int]$template.Layer)) { $script:OnAir[[int]$template.Layer] } else { $null }
            $script:PostShowQueue.Add(@{
                    At = (Get-Date).AddMilliseconds($delay); Values = $Variables
                    Layer = [int]$template.Layer; Key = $Key
                    ActiveId = if ($liveScene) { [string](Get-JsonProp $liveScene 'ActiveId') } else { '' }
                })
        }

        $suffix = ""
        if ($AutoHideSeconds -gt 0) {
            $timerSaved = $activeIdConfirmed -and (Set-AutoHideTimer -Layer ([int]$template.Layer) -Seconds $AutoHideSeconds `
                    -ChatId $ChatId -UserId $UserId -TemplateKey $Key -ActiveId $activeId -ActiveIdConfirmed $true)
            $suffix = if (-not $activeIdConfirmed) {
                " ⚠️ لم يُضبط الإخفاء التلقائي لأن Cinegy لم يؤكد هوية المشهد؛ أخفه يدويًا."
            }
            elseif ($timerSaved) {
                " سيُخفى تلقائيًا بعد $(Get-ArabicCountNoun -Count $AutoHideSeconds -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية')."
            }
            else {
                " ⚠️ تعذّر حفظ مؤقت الإخفاء؛ أخفه يدويًا."
            }
        }
        if (-not [bool](Get-JsonProp $template 'LongRunning') -and $reminderMinutes -gt 0) {
            if (-not $activeIdConfirmed) {
                $suffix += ' ⚠️ لم يُضبط تنبيه الظهور لأن Cinegy لم يؤكد هوية المشهد.'
            }
            elseif (Set-TemplateReminder -Template $template -ChatId $ChatId -UserId $UserId -ActiveId $activeId -ActiveIdConfirmed $true) {
                $suffix += " سيصل إليك تنبيه شخصي بعد $(Get-ArabicCountNoun -Count $reminderMinutes -One 'دقيقة' -Two 'دقيقتان' -Few 'دقائق' -Many 'دقيقة') إذا بقي القالب ظاهرًا."
            }
            else {
                $suffix += ' ⚠️ تعذّر حفظ تنبيه ظهور القالب لإعادة التشغيل.'
            }
        }
        else {
            # A new SHOW replaces the visible scene on its layer, so any old
            # operator reminder for that layer must never reach the wrong person.
            Remove-TemplateRemindersForLayer -Layer ([int]$template.Layer) | Out-Null
        }
        # A one-tap hide right where the operator is looking: previously taking
        # something back off air meant going 🙈 -> pick layer, which is several
        # taps too many when a wrong graphic is live.
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم إظهار '$Key' على الهواء (طبقة $($template.Layer)).$suffix" -ReplyMarkup (Get-AfterShowKeyboard -Layer ([int]$template.Layer) -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -Values (Format-AuditTemplateValues -Variables $Variables)
    }
    else {
        Write-BridgeLog "User $(Format-UserAuditActor -UserId $UserId) failed to push template '$Key': $($result.Error)" "ERROR"
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -Values (Format-AuditTemplateValues -Variables $Variables) -ErrorText ([string]$result.Error)
        # The error text names the symptom; the button names the cause. It is
        # here rather than on the status screen because this message is where
        # the operator already is when they need it.
        $failureMenu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
        # Addressed by position because callback_data is capped at 64 bytes
        # and a template key is free text. Read from the store this function
        # already holds rather than re-reading it: a failure path that throws
        # while reporting a failure replaces one fault with two, and the
        # operator loses the message that was about to tell them what broke.
        # Get-JsonProp rather than .ContainsKey or .Order directly: the store
        # is a hashtable in the bridge and a PSCustomObject in places that
        # build one, and Set-StrictMode throws on the missing property while
        # PSCustomObject has no ContainsKey at all. @() then turns an absent
        # Order into an empty array, whose IndexOf is -1 - no button, no throw.
        $failureIndex = [array]::IndexOf(@(Get-JsonProp $store 'Order'), $Key)
        if ($failureIndex -ge 0) {
            $failureMenu.inline_keyboard = @(, @( (New-Button '🔍 لماذا لم يظهر؟' "whynot:$failureIndex") )) + @($failureMenu.inline_keyboard)
        }
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل إظهار '$Key': $($result.Error)" -ReplyMarkup $failureMenu
    }
    return $result
}

function Get-ShowFailureDiagnosisLines {
    <#
        Why a template did not reach the screen, answered from what the
        bridge already knows, in the order an operator would ask.

        A failure said one thing - the error the push came back with - and
        that sentence is usually the symptom, not the cause: "الطلب انتهت
        مهلته" does not say whether Cinegy is down, the scene file moved, or
        the layer is held by somebody else. The operator's next move was to
        open the status screen, the layers screen and the template screen and
        assemble the answer, mid-shift, from three places.

        AGENTS.md has this lesson written down for the log - "إن عجزت عن
        إعادة إنتاج عطل من السجل فاجعل السجل يقول أكثر". This is the same
        move aimed at the person instead of the file.

        Read-only by construction: it queries nothing and sends nothing. Every
        line comes from cached state, configuration, or the file system, so it
        can never itself change what is on air - which is the one thing a
        diagnosis run during a live fault must not do.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [long]$ChatId = 0,
        [long]$UserId = 0,
        [datetime]$Now = (Get-Date)
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($Key)) {
        $lines.Add("❌ القالب <code>$(ConvertTo-TelegramHtmlText $Key)</code> لم يعد في سجل القوالب — حُذف أو أُعيدت تسميته.")
        return $lines.ToArray()
    }
    $template = $store.Map[$Key]
    $layer = [int]$template.Layer

    # 1. Cinegy first: when it is unreachable every other answer is noise.
    $lastSuccess = if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccess -FailedCount 0 -Now $Now `
        -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add($(switch ([string]$freshness.State) {
                'connected' { '✅ Cinegy يستجيب، وحالة الطبقات حديثة.' }
                'stale' { "⚠️ حالة Cinegy متأخرة ($(ConvertTo-TelegramHtmlText ([string]$freshness.Label))) — قد يكون المحرّك مشغولًا أو الشبكة بطيئة." }
                default { '❌ لا حالة حديثة من Cinegy — تحقّق من عنوان المحرّك ومن الشبكة قبل أي شيء آخر.' }
            }))

    # 2. The scene file, the cause a status screen never shows: a moved or
    # renamed .cintitle fails the push with a message about the push.
    $scenePath = Resolve-TemplateScenePath -Path ([string]$template.Path)
    if ([string]::IsNullOrWhiteSpace($scenePath)) {
        $lines.Add('❌ لا مسار مشهد لهذا القالب في سجل القوالب.')
    }
    elseif (Test-Path -LiteralPath $scenePath) {
        $lines.Add('✅ ملف المشهد موجود في مساره.')
    }
    else {
        $lines.Add("❌ ملف المشهد غير موجود: <code>$(ConvertTo-TelegramHtmlText $scenePath)</code> — نُقل أو أُعيدت تسميته أو تعذّر الوصول إلى المشاركة.")
    }

    # 3. Who is holding the layer, and what is standing on it.
    if ($script:LayerLocks.ContainsKey($layer)) {
        $holder = [long](Get-JsonProp $script:LayerLocks[$layer] 'UserId')
        $lines.Add("⚠️ الطبقة $layer محجوزة الآن لـ$(ConvertTo-TelegramHtmlText (Get-UserDisplayName -UserId $holder)) — انتظر أو اطلب منه الإنهاء.")
    }
    elseif ($script:OnAir.ContainsKey($layer)) {
        $lines.Add("ℹ️ الطبقة $layer عليها الآن <code>$(ConvertTo-TelegramHtmlText ([string](Get-JsonProp $script:OnAir[$layer] 'Key')))</code> — العرض يستبدله لا يُضاف فوقه.")
    }
    else {
        $lines.Add("✅ الطبقة $layer خالية.")
    }

    # 4. Whether the bridge refused before Cinegy was ever asked. Access is
    # checked with the caller's own ids so the answer is about THIS operator,
    # not about an administrator reading over their shoulder.
    if ($ChatId -gt 0) {
        $access = Test-TemplateAccess -Key $Key -Layer $layer -ChatId $ChatId -UserId $UserId
        $lines.Add($(if ($access.Allowed) { '✅ هذا القالب مسموح لك.' } else { "⛔ القالب ممنوع عليك: $(ConvertTo-TelegramHtmlText ([string]$access.Reason))" }))
    }

    # 5. The two switches that stop everything, named rather than left to be
    # discovered on the settings screen.
    if ([bool](Get-Setting 'MaintenanceMode')) { $lines.Add('🛠 وضع الصيانة مفعّل — كل أوامر الهواء موقوفة.') }
    elseif (Test-MaintenanceWindowActive) { $lines.Add('🛠 نافذة الصيانة المجدولة مفتوحة الآن — أوامر الهواء موقوفة حتى نهايتها.') }

    # 6. A sibling on the same layer can never be up with it, and the clash
    # reads as a mysterious replacement rather than a rule.
    $sharedLayers = Get-JsonProp $store 'SharedLayers'
    if ($sharedLayers -and $sharedLayers.Contains([string]$layer)) {
        $siblings = @(@($sharedLayers[[string]$layer]) | Where-Object { $_ -ne $Key })
        if ($siblings.Count -gt 0) {
            $lines.Add("ℹ️ يتشارك الطبقة $layer أيضًا: $(ConvertTo-TelegramHtmlText ($siblings -join '، ')) — لا يظهر اثنان منها معًا.")
        }
    }
    return $lines.ToArray()
}

function Get-ShowFailureDiagnosisText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [long]$ChatId = 0,
        [long]$UserId = 0,
        [datetime]$Now = (Get-Date)
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>🔍 لماذا لم يظهر '$(ConvertTo-TelegramHtmlText $Key)'؟</b>")
    $lines.Add('')
    foreach ($line in @(Get-ShowFailureDiagnosisLines -Key $Key -ChatId $ChatId -UserId $UserId -Now $Now)) { $lines.Add($line) }
    $lines.Add('')
    $lines.Add('<i>فحص قراءة فقط: لم يُرسل شيء إلى Cinegy لإعداد هذه الشاشة.</i>')
    return ($lines -join "`n")
}

function Get-LayerShowContext {
    param([Parameter(Mandatory)][int]$Layer, [datetime]$Now = (Get-Date))
    $record = if ($script:OnAir.ContainsKey($Layer)) { $script:OnAir[$Layer] } else { $null }
    $lastSuccess = if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccess -FailedCount 0 -Now $Now `
        -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    return [pscustomobject]@{
        IsKnown = ($freshness.State -eq 'connected')
        IsOnAir = ($null -ne $record)
        Key      = if ($record) { [string](Get-JsonProp $record 'Key') } else { '' }
        UserId   = if ($record) { [long](Get-JsonProp $record 'UserId') } else { 0L }
        Source   = if ($record) { [string](Get-JsonProp $record 'Source') } else { '' }
    }
}
