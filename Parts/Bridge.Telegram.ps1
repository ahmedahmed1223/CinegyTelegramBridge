#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function ConvertTo-TelegramHtmlText {
    <# Escapes text that will be sent with parse_mode=HTML.

       Every news headline, template name and operator display name is typed
       by a person. An unescaped '<' turns the rest of that message into an
       unclosed tag and Telegram rejects the whole send with a 400 - which on
       the reorder screen reads as "the list will not update", the exact
       failure paging was added to fix.

       '&' goes first: escaping it after '<' would turn the '&lt;' just
       produced into '&amp;lt;'. Telegram names only four supported entities
       (&lt; &gt; &amp; &quot;), so nothing else may be emitted. #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function ConvertFrom-TelegramHtmlText {
    <# The readable text inside a message the bridge built as HTML.

       Used only when an HTML message turns out to be too long for one send
       and has to degrade: without it the operator got '<b>' and '<blockquote
       expandable>' as visible text, which is the same failure the escaping
       was added to prevent, arriving from the other direction.

       Stripping tags before unescaping entities is the whole trick. Doing it
       the other way round would turn an escaped '&lt;b&gt;' - a headline that
       genuinely contains '<b>' - into a tag and then delete it. #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $stripped = [regex]::Replace($Text, '<[^>]+>', '')
    return $stripped.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&amp;', '&')
}

function New-BridgeButton {
    <#
        One inline-keyboard button.

        Exists because Bot API 9.4 added 'style' and 10.3 added 'disabled',
        and both are worth applying in one place rather than at the ~40 sites
        that build a button by hand.

        Style is one of Telegram's three documented values - danger (red),
        success (green), primary (blue) - and needs no Premium. Clients older
        than the field ignore it, so the label must still carry the meaning on
        its own: style sharpens a screen, it never explains it.

        -Disabled renders a button that does nothing. Telegram counts
        'disabled' as the button's type, so it replaces callback_data rather
        than joining it - which is the point: the placeholder it succeeds
        carried a real callback ('news:noop') and was therefore pressable.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$CallbackData,
        [ValidateSet('', 'danger', 'success', 'primary')][string]$Style = '',
        [switch]$Disabled
    )
    $button = @{ text = $Text }
    if ($Disabled) { $button.disabled = @{} }
    elseif ($CallbackData) { $button.callback_data = $CallbackData }
    if ($Style) { $button.style = $Style }
    return $button
}

function Test-TelegramButtonObject {
    <#
        Is this one button object, as opposed to a row, a string, or a number?

        Deliberately NOT `$Value -is [pscustomobject]`. [pscustomobject] is an
        alias for PSObject, and anything arriving from a pipeline is wrapped in
        one - so `$_ -is [pscustomobject]` inside a Where-Object is TRUE for an
        array, a string, an int, everything. Written that way, the guard below
        accepted a nested array as a button and passed the malformed keyboard
        straight through to Telegram, which is how the readiness screen still
        lost its whole message on 2026-09-14 with the repair pass already in
        place and silent. PSCustomObject (the real type) does not have that
        problem.
    #>
    param($Value)
    return ($Value -is [hashtable] -or $Value -is [System.Management.Automation.PSCustomObject])
}

function Expand-TelegramButtonRow {
    <#
        The button objects inside a row, however deeply the caller nested it.

        The @() flattening trap in AGENTS.md produces a row wrapped one level
        too deep, and the buttons are sitting right there - so flatten rather
        than drop the row and leave the operator a screen with no way out.
        Anything that is not a button and not a collection (a stray string, an
        int) is dropped, because Telegram refuses the whole message over it.
    #>
    param($Row)
    foreach ($item in @($Row)) {
        if ($null -eq $item) { continue }
        if (Test-TelegramButtonObject -Value $item) { $item; continue }
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            Expand-TelegramButtonRow -Row $item
        }
    }
}

function ConvertTo-ValidInlineKeyboard {
    <#
        Repairs a keyboard whose rows are not arrays of button objects.

        Telegram answers such a keyboard with 400 "can't parse
        InlineKeyboardButton: InlineKeyboardButton must be an Object" and
        refuses the WHOLE message - the operator taps a button and simply
        nothing happens, while the only trace is one line in bridge.log that
        names neither the screen nor the row. The @() flattening trap in
        AGENTS.md ("فاصلة قبل كل صف") produces exactly this shape, and a
        screen built from a collection that turns out empty can produce it
        too.

        Repaired here rather than refused: a menu missing one malformed row
        still gets the operator where they were going, and the log line names
        how many rows were wrong so the caller can be found. One chokepoint,
        because every screen in the bridge passes through this function.
    #>
    param([AllowEmptyCollection()][object[]]$Rows = @())
    $fixed = @()
    # What was wrong with each row, so the warning is a diagnosis rather than
    # a count. A bare "repaired 1 row" says nothing a maintainer can act on.
    $notes = [System.Collections.Generic.List[string]]::new()
    $index = -1
    foreach ($row in $Rows) {
        $index++
        if ($null -eq $row) { $notes.Add("row $index was null"); continue }
        # A bare button where a row belongs - wrap it instead of dropping it.
        if (Test-TelegramButtonObject -Value $row) {
            $fixed += , @($row)
            $notes.Add("row $index was a bare button, not a row")
            continue
        }
        $cells = @(Expand-TelegramButtonRow -Row $row)
        # Counted on shape, not on length: a row holding a single nested
        # button flattens to the same count it came in with, and comparing
        # counts let exactly that case repair itself in silence.
        foreach ($item in @($row)) {
            if (Test-TelegramButtonObject -Value $item) { continue }
            $what = if ($null -eq $item) { 'null' } else { $item.GetType().Name }
            # What was NESTED, not just that something was. "row 0 held Object[]"
            # appeared thirteen times over a month and named no screen: every
            # keyboard builder can produce an Object[], so the note narrowed
            # nothing and the fault survived a full re-read of the SHOW path.
            # The callback_data inside identifies the screen on the first
            # occurrence, because no two screens share a prefix.
            $inner = ''
            if ($null -ne $item -and $item -isnot [System.Collections.IDictionary]) {
                $datas = @(@($item) | ForEach-Object {
                        if ($_ -is [System.Collections.IDictionary] -and $_.Contains('callback_data')) { [string]$_['callback_data'] }
                        elseif ($null -eq $_) { '<null>' }
                        else { "<$($_.GetType().Name)>" }
                    } | Select-Object -First 4)
                if ($datas.Count -gt 0) { $inner = " containing [$($datas -join ', ')]" }
            }
            $notes.Add("row $index held $what where a button belongs$inner")
            break
        }
        if ($cells.Count -eq 0) { $notes.Add("row $index had no buttons at all and was dropped") }
        else { $fixed += , $cells }
    }
    if ($notes.Count -gt 0) {
        # Named, because the first version of this line said only that a row
        # was repaired - and a warning that cannot be traced to a screen is a
        # warning nobody can act on. The send path itself is skipped so the
        # frame reported is the screen that built the keyboard.
        $plumbing = @('ConvertTo-ValidInlineKeyboard', 'ConvertTo-TelegramReplyMarkupJson', 'ConvertTo-OneHandLayout',
            'Send-TelegramMessage', 'Send-TelegramPagedText', 'Edit-TelegramMessageText', 'Send-TelegramPhoto', 'Send-TelegramDocument')
        # The chain, not the first frame. The keyboard BUILDER has already
        # returned by the time its rows are sent, so the nearest frame is only
        # ever the screen that sent it - which is how thirteen warnings all said
        # "from Invoke-ShowTemplateResult" while the malformed row was built
        # somewhere that function merely called and never appeared in the note.
        # Four frames reach past the sender to whatever assembled the screen.
        $chain = @(Get-PSCallStack | Select-Object -Skip 1 |
                Where-Object { $_.Command -and $_.Command -notin $plumbing -and $_.Command -notlike '*.ps1' } |
                Select-Object -First 4 | ForEach-Object { $_.Command })
        $caller = if ($chain.Count -gt 0) { $chain -join ' <- ' } else { 'unknown' }
        Write-BridgeLog "Repaired $($notes.Count) malformed inline keyboard row(s) from $caller before sending ($($notes -join '; ')); a row must be an array of button objects (see the @() flattening trap in AGENTS.md)." 'WARN'
    }
    return , $fixed
}

function ConvertTo-TelegramReplyMarkupJson {
    <# The single place a keyboard becomes wire JSON.

       EnableButtonStyles is honoured here rather than in New-BridgeButton so
       that building a keyboard stays a pure function of the draft - a button
       constructor that reads settings makes every keyboard test depend on a
       setting it does not care about - and so the setting is read once per
       message instead of once per button.

       Styled buttons are rebuilt without the field rather than edited: the
       caller's keyboard is theirs, and stripping it in place would change
       what a re-render sends next time.

       OneHandMode is honoured here for the same reason and in the same way.
       It used to be applied by the one screen that remembered to call
       ConvertTo-OneHandLayout, so an operator who turned it on got a single
       column on the main menu and three-across rows on the fifty-odd screens
       behind it - the fields, the templates, the settings, the bulletin. A
       layout rule every screen has to opt into is a rule most screens miss.
       Only inline keyboards are reshaped; the persistent 🏠/🆘 bar carries
       'keyboard' instead and is left alone. #>
    param([Parameter(Mandatory)][hashtable]$ReplyMarkup)
    $markup = $ReplyMarkup
    if ($markup.ContainsKey('inline_keyboard')) { $markup = ConvertTo-OneHandLayout -Keyboard $markup }
    # KeepRows is a layout instruction to the pass above, not a Bot API field.
    if ($markup.ContainsKey('KeepRows')) {
        $plain = @{}
        foreach ($key in $markup.Keys) { if ($key -ne 'KeepRows') { $plain[$key] = $markup[$key] } }
        $markup = $plain
    }
    if ($markup.ContainsKey('inline_keyboard') -and -not (Get-Setting 'EnableButtonStyles')) {
        $rows = @(foreach ($row in @($markup.inline_keyboard)) {
                , @(foreach ($button in @($row)) {
                        if ($button -is [hashtable] -and $button.ContainsKey('style')) {
                            $plain = @{}
                            foreach ($key in $button.Keys) { if ($key -ne 'style') { $plain[$key] = $button[$key] } }
                            $plain
                        }
                        else { $button }
                    })
            })
        $markup = @{ inline_keyboard = $rows }
    }
    # Last gate before the wire: a malformed row costs the whole message.
    if ($markup.ContainsKey('inline_keyboard')) {
        $rebuilt = @{}
        foreach ($key in $markup.Keys) { $rebuilt[$key] = $markup[$key] }
        $rebuilt['inline_keyboard'] = ConvertTo-ValidInlineKeyboard -Rows @($markup['inline_keyboard'])
        $markup = $rebuilt
    }
    return ($markup | ConvertTo-Json -Depth 10 -Compress)
}

function Get-TelegramMessagePhotoId {
    <#
        The file id of the largest size of a photo message, or '' when the
        message carries no photo at all.

        Written as a function with a test behind it because the obvious
        inline version is wrong in a way that takes the whole bot down:
        @(Get-JsonProp $message 'photo') on a message with no photo is
        @($null) - one element, Count 1 - so a "did a photo arrive" test
        written that way answers yes to every text message ever sent.
    #>
    param($Message)
    $sizes = @(@(Get-JsonProp $Message 'photo') | Where-Object { $_ })
    if ($sizes.Count -eq 0) { return '' }
    return [string](Get-JsonProp $sizes[-1] 'file_id')
}

function Test-RefreshButtonPress {
    <#
        Was the button pressed a 🔄 refresh? Read from the pressed message's own
        keyboard, which Telegram sends with every press, so no screen has to
        declare it and a screen added later is covered on its first day.

        Both languages: the message may have been drawn before the language
        was switched.
    #>
    param($Message, [string]$Data)
    if (-not $Message -or -not $Data) { return $false }
    $labels = @('🔄 تحديث', '🔄 Refresh')
    foreach ($row in @(Get-JsonProp (Get-JsonProp $Message 'reply_markup') 'inline_keyboard')) {
        foreach ($button in @($row)) {
            if ([string](Get-JsonProp $button 'callback_data') -ceq $Data -and [string](Get-JsonProp $button 'text') -in $labels) { return $true }
        }
    }
    return $false
}

function Test-RedrawInPlacePress {
    <#
        Buttons whose answer is the screen they sit on, redrawn: the bulletin's
        row moves and deletes, its pages, its sync and fit-to-loop. They ride
        the refresh mark, so the screen is edited rather than sent again - the
        bulletin never edited its message at all, on a screen worked on for
        minutes at a time. A refusal (❌) replaces the screen and the screen
        follows it, so nothing stale is left either way.
    #>
    param([string]$Data)
    foreach ($prefix in @('mojaz:up:', 'mojaz:down:', 'mojaz:del:', 'mojaz:skip:', 'mojazpage:', 'mojazlib:')) {
        if ($Data.StartsWith($prefix, [StringComparison]::Ordinal)) { return $true }
    }
    return $Data -in @('mojaz:sync', 'mojaz:matchloop')
}

function Clear-RefreshTarget { $script:RefreshTarget = $null }

function Use-RefreshTarget {
    <# The marked message for this chat, once. Unsolicited notices never take
       it: an alert must arrive as a message, not overwrite a screen. #>
    param([long]$ChatId)
    $target = $script:RefreshTarget
    if (-not $target -or [long]$target.ChatId -ne $ChatId) { return 0 }
    $script:RefreshTarget = $null
    return [int]$target.MessageId
}

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$ReplyMarkup,
        [ValidateSet('', 'HTML')][string]$ParseMode = '',
        # Set ONLY by unsolicited notices - anything the tick can send without
        # the operator having asked. A screen, a reply, or a confirmation of
        # something they just pressed must never carry one, or a busy hour on
        # air would start hiding itself. See Test-BridgeNoticeSuppressed.
        [AllowEmptyString()][string]$Cause = ''
    )
    if ($Cause -and (Test-BridgeNoticeSuppressed -Cause $Cause -ChatId $ChatId)) { return }
    # D1: a quarantined chat already proved undeliverable three times. Trying
    # again on every alert is how forty-one failures filled a week of log.
    if (Test-DeadChat -ChatId $ChatId) {
        Write-BridgeLog "Skipping send to quarantined dead chat $ChatId"
        return
    }
    # A 🔄 press redraws its own message. Tried once; anything the edit cannot
    # carry - a photo under the button, a text too long - falls through to a
    # plain send below, as before.
    if (-not $Cause) {
        $refreshId = Use-RefreshTarget -ChatId $ChatId
        if ($refreshId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $refreshId -Text $Text -ReplyMarkup $ReplyMarkup -ParseMode $ParseMode)) {
            $script:LastTelegramMessageId = $refreshId
            return
        }
    }
    # A split lands wherever the budget runs out, which for HTML can be the
    # middle of a tag - and Telegram rejects that outright. Callers asking for
    # HTML build one message deliberately; if one ever overflows, the markup
    # is taken back out and the text is sent plain. Sending it with the tags
    # still in would show the operator '<b>' and '<blockquote expandable>',
    # which is exactly what the escaping exists to prevent.
    $body_text = $Text
    $mode = $ParseMode
    if ($ParseMode -and @(Split-TelegramText -Text $Text).Count -gt 1) {
        $body_text = ConvertFrom-TelegramHtmlText -Text $Text
        $mode = ''
        Write-BridgeLog "HTML message to $ChatId exceeded one chunk; markup removed and sent as text" "WARN"
    }
    [string[]]$chunks = @(Split-TelegramText -Text $body_text)
    # P2: the last sent message id, so a caller can pin or edit what it just
    # said. A script variable, not a return value: a return would leak into
    # the output of every caller that invokes this bare (Set-LayerName
    # returns $true, and a stray 0 in its stream broke exactly that).
    $script:LastTelegramMessageId = 0
    $lastMessageId = 0
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        # [string] cast is deliberate belt-and-braces against anything
        # array-shaped ever reaching the body again.
        $body = @{ chat_id = $ChatId; text = [string]$chunks[$i] }
        if ($mode) { $body.parse_mode = $mode }
        # Only the final chunk carries the keyboard.
        if ($ReplyMarkup -and $i -eq ($chunks.Count - 1)) {
            $body.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup)
        }
        $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendMessage" -Method Post -Body $body `
            -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 3
        if (-not $request.Success) {
            # Counted separately: a flood limit is a capacity problem, not a bug,
            # and telling them apart is the point of /stats.
            if ([int](Get-JsonProp $request 'StatusCode') -eq 429) {
                $script:TelegramRateLimitHits++
                $retryMs = [math]::Max(1000, [int](Get-JsonProp $request 'RetryAfterMs'))
                if (Add-TelegramOutboxItem -Body $body -DueAt (Get-Date).AddMilliseconds($retryMs) -Attempts 0) {
                    Write-BridgeLog "Deferred Telegram message to $ChatId for $retryMs ms after rate limit" "WARN"
                }
                continue
            }
            Write-BridgeLog "Failed to send Telegram message to $ChatId : $($request.Error)" "ERROR"
            Register-TelegramSendFailure -ChatId $ChatId -StatusCode ([int](Get-JsonProp $request 'StatusCode')) -ErrorText ([string]$request.Error)
        }
        else {
            # Get-JsonProp, not direct access: test doubles of the transport
            # carry only Success, and StrictMode turns a missing Response
            # into a failed send.
            $sentId = [int](Get-JsonProp (Get-JsonProp (Get-JsonProp $request 'Response') 'result') 'message_id')
            if ($sentId -gt 0) { $lastMessageId = $sentId }
        }
    }
    $script:LastTelegramMessageId = $lastMessageId
}

function Test-TelegramOutboxPriority {
    <# Send-TelegramMessage has no caller-supplied severity. The bridge's own
       alerts carry one of these stable markers, so reserve the scarce queue
       slots for them before ordinary screen navigation. #>
    param([Parameter(Mandatory)][hashtable]$Body)
    $text = [string](Get-JsonProp $Body 'text')
    return $text -match '(?i)\[ERROR\]|\[WARN\]|❌|⚠|فشل|تحذير'
}

function Add-TelegramOutboxItem {
    <# Bounded in-memory retry queue. It is deliberately not persistent: an
       old interaction after a process restart is less useful than a timely
       current one, and persistence would retain operator-facing text. #>
    param(
        [string]$Uri = "$apiBase/sendMessage",
        [hashtable]$Body,
        [hashtable]$Form,
        [Parameter(Mandatory)][datetime]$DueAt,
        [ValidateRange(0,4)][int]$Attempts
    )
    if (-not $Body -and -not $Form) { throw 'A deferred Telegram request needs a body or form.' }
    $maximumItems = 200
    $priority = if ($Body) { Test-TelegramOutboxPriority -Body $Body } else { $false }
    if ($script:TelegramOutbox.Count -ge $maximumItems) {
        $removeAt = -1
        for ($index = 0; $index -lt $script:TelegramOutbox.Count; $index++) {
            $queuedPriority = [bool](Get-JsonProp $script:TelegramOutbox[$index] 'Priority')
            if (-not $queuedPriority) { $removeAt = $index; break }
        }
        if ($removeAt -lt 0 -and -not $priority) {
            $script:TelegramOutboxDropped++
            return $false
        }
        if ($removeAt -lt 0) { $removeAt = 0 }
        Remove-TelegramOutboxFiles -Item $script:TelegramOutbox[$removeAt]
        $script:TelegramOutbox.RemoveAt($removeAt)
        $script:TelegramOutboxDropped++
        # Log only every 25th discard: a log entry per rejected low-priority
        # notification would itself create the burst this limit contains.
        if (($script:TelegramOutboxDropped % 25) -eq 1) {
            Write-BridgeLog "Telegram deferred-message queue is full; lower-priority message discarded" 'WARN'
        }
    }
    $item = @{ DueAt = $DueAt; Uri = $Uri; Body = $Body; Form = $Form; Attempts = $Attempts; Priority = $priority; OwnedFiles = @(); UploadBytes = 0L }
    if ($Form) {
        $item.Form = $Form.Clone()
        # Callers own the source (report exporters delete theirs in finally).
        # Queue entries own separate copies, bounded across queued + active sends.
        $retainedBytes = 0L
        foreach ($queued in $script:TelegramOutbox) { $retainedBytes += [long](Get-JsonProp $queued 'UploadBytes') }
        if ($script:TelegramOutboxActiveItem) { $retainedBytes += [long]$script:TelegramOutboxActiveItem.UploadBytes }
        try {
            foreach ($field in @($Form.Keys)) {
                if ($Form[$field] -isnot [IO.FileInfo]) { continue }
                $sourceFile = Get-Item -LiteralPath $Form[$field].FullName -ErrorAction Stop
                if (($retainedBytes + $item.UploadBytes + $sourceFile.Length) -gt 64MB) { throw 'Deferred upload storage limit reached.' }
                New-Item -ItemType Directory -Path $script:TelegramOutboxDirectory -Force -ErrorAction Stop | Out-Null
                $copyPath = Join-Path $script:TelegramOutboxDirectory "$([guid]::NewGuid().ToString('N'))-$($sourceFile.Name)"
                $item.OwnedFiles += $copyPath
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $copyPath -ErrorAction Stop
                $copyFile = Get-Item -LiteralPath $copyPath -ErrorAction Stop
                $item.UploadBytes += $copyFile.Length
                if (($retainedBytes + $item.UploadBytes) -gt 64MB) { throw 'Deferred upload storage limit reached.' }
                $item.Form[$field] = $copyFile
            }
        }
        catch {
            Remove-TelegramOutboxFiles -Item $item
            $script:TelegramOutboxDropped++
            Write-BridgeLog 'Could not retain a deferred Telegram upload; request discarded.' 'WARN'
            return $false
        }
    }
    $script:TelegramOutbox.Add($item) | Out-Null
    return $true
}

function Remove-TelegramOutboxFiles {
    param([Parameter(Mandatory)][hashtable]$Item)
    foreach ($ownedFile in @(Get-JsonProp $Item 'OwnedFiles')) {
        if ($ownedFile) { Remove-Item -LiteralPath $ownedFile -Force -ErrorAction SilentlyContinue }
    }
}

function Clear-TelegramOutbox {
    # Shutdown only: cancellation may wait for the HTTP stack, never in tick.
    if ($script:TelegramOutboxWorker) {
        try { Stop-BridgeTelegramRequestWorker -Worker $script:TelegramOutboxWorker }
        catch { Write-BridgeLog 'Could not cancel the deferred Telegram worker during shutdown.' 'WARN' }
        $script:TelegramOutboxWorker = $null
    }
    if ($script:TelegramOutboxActiveItem) {
        Remove-TelegramOutboxFiles -Item $script:TelegramOutboxActiveItem
        $script:TelegramOutboxActiveItem = $null
    }
    foreach ($item in $script:TelegramOutbox) { Remove-TelegramOutboxFiles -Item $item }
    $script:TelegramOutbox.Clear()
    if (Test-Path -LiteralPath $script:TelegramOutboxDirectory) {
        try { [IO.Directory]::Delete($script:TelegramOutboxDirectory, $false) }
        catch { Write-BridgeLog 'Deferred upload directory could not be removed during shutdown.' 'WARN' }
    }
}

function Update-TelegramOutbox {
    if ($script:TelegramOutboxWorker) {
        $request = Receive-BridgeTelegramRequestWorker -Worker $script:TelegramOutboxWorker
        if (-not $request) { return }
        $item = $script:TelegramOutboxActiveItem
        $script:TelegramOutboxWorker = $null
        $script:TelegramOutboxActiveItem = $null
        $flooded = [int](Get-JsonProp $request 'StatusCode') -eq 429
        if ($flooded) {
            $script:TelegramOutboxNotBefore = (Get-Date).AddMilliseconds([math]::Max(1000, [int](Get-JsonProp $request 'RetryAfterMs')))
        }
        if (-not $request.Success -and $flooded -and [int]$item.Attempts -lt 4 -and $script:TelegramOutbox.Count -lt 200) {
            $item.Attempts++
            $item.DueAt = $script:TelegramOutboxNotBefore
            $script:TelegramOutbox.Add($item) | Out-Null
        }
        else {
            Remove-TelegramOutboxFiles -Item $item
            if (-not $request.Success) {
                # Named, because "dropped a request" is a line nobody can act
                # on. An alert to an on-call administrator and a navigation
                # screen produced the same sentence, so the morning after a
                # graphic was missing all night the log could not say which of
                # three administrators never heard about it - the fault had to
                # be reproduced to find out. That is precisely what the
                # AGENTS.md rule about unattributable warnings forbids.
                $droppedChat = [string](Get-JsonProp $item.Body 'chat_id')
                $droppedEndpoint = ([string]$item.Uri -split '/')[-1]
                Write-BridgeLog "Dropped deferred Telegram $droppedEndpoint to chat $droppedChat after $([int]$item.Attempts) attempt(s): $([string](Get-JsonProp $request 'Error'))" 'ERROR'
                # Counted as a real delivery failure like the live path does at
                # the first send, so a chat that has stopped accepting messages
                # reaches the dead-chat quarantine instead of being retried for
                # ever, one anonymous line at a time.
                # The status is passed because the quarantine only counts 401
                # and 403 - a 400 is our own malformed message and must not
                # hide behind a roster. Without it every drop arrived as 0 and
                # counted for nothing.
                if ($droppedChat) {
                    Register-TelegramSendFailure -ChatId ([long]$droppedChat) `
                        -StatusCode ([int](Get-JsonProp $request 'StatusCode')) `
                        -ErrorText ([string](Get-JsonProp $request 'Error')) | Out-Null
                }
            }
        }
    }
    $now = Get-Date
    if ($script:TelegramOutbox.Count -eq 0 -or $now -lt $script:TelegramOutboxNotBefore) { return }
    $dueItems = @($script:TelegramOutbox.ToArray() |
        Where-Object { [datetime]$_.DueAt -le $now } |
        Sort-Object @{ Expression = { [bool](Get-JsonProp $_ 'Priority') }; Descending = $true }, @{ Expression = { [datetime]$_.DueAt }; Descending = $false } |
        Select-Object -First 1)
    if ($dueItems.Count -eq 0) { return }
    $item = $dueItems[0]
    $arguments = @{ Uri = [string]$item.Uri; Method = 'Post'; TimeoutSec = (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1); MaxAttempts = 1 }
    if ($item.Form) { $arguments.Form = $item.Form } else { $arguments.Body = $item.Body }
    # BeginInvoke returns immediately; only this polling thread owns the queue.
    $script:TelegramOutboxWorker = Start-BridgeTelegramRequestWorker -Request $arguments
    $script:TelegramOutboxActiveItem = $item
    $script:TelegramOutbox.Remove($item) | Out-Null
}

function Get-RichBlockTypes {
    <# Every block type a payload uses, including the ones nested inside a
       details block or a table cell - those are the parts most likely to be
       the reason a server refuses the whole message. #>
    param([AllowNull()][array]$Blocks)
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($block in @($Blocks)) {
        if (-not $block) { continue }
        $type = [string](Get-JsonProp $block 'type')
        if (-not [string]::IsNullOrWhiteSpace($type)) { $found.Add($type) }
        foreach ($nested in @(Get-JsonProp $block 'blocks')) {
            foreach ($inner in @(Get-RichBlockTypes -Blocks @($nested))) { $found.Add($inner) }
        }
        foreach ($row in @(Get-JsonProp $block 'cells')) {
            foreach ($inner in @(Get-RichBlockTypes -Blocks @($row))) { $found.Add($inner) }
        }
    }
    return @($found | Sort-Object -Unique)
}

# The largest rich payload seen rendering on this installation is the news
# report at about 4 KB. Anything several times that is not worth a round trip
# which, on the first message of a session, can cost every screen its table
# until the next restart.
$script:RichPayloadLimit = 12000

function Test-RichPayloadSize {
    <#
        Whether a serialized rich_message is worth sending at all.

        Telegram does not document a size for this parameter, so the rule is
        empirical rather than exact: do not send what is far bigger than
        anything that has ever rendered here. Being wrong this way costs one
        screen its table and it falls back to text; being wrong the other way
        cost every screen its table for the rest of the session.
    #>
    param([Parameter(Mandatory)][int]$Length, [int]$Limit = 0)
    if ($Limit -le 0) { $Limit = $script:RichPayloadLimit }
    return $Length -le $Limit
}

# The largest rich payload this run has sent, and the screen it belonged to.
# In memory like the other counters on the operating-numbers screen: it
# answers "is any screen close to losing its table", which is a question about
# this run against this station's data.
$script:RichPayloadPeak = @{ Length = 0; Screen = '' }
$script:RichPayloadWarned = @{}

function Get-RichBlocksTitle {
    <# What to call a payload in a log line: the screen's own heading, which
       every builder puts first. Falls back to the first text of any kind, and
       then to a dash - a name is for the reader, so guessing badly is worse
       than saying nothing. #>
    param([AllowNull()][array]$Blocks)
    foreach ($block in @($Blocks)) {
        if ($block -is [hashtable] -and [string]$block['type'] -eq 'heading' -and $block['text']) { return [string]$block['text'] }
    }
    foreach ($block in @($Blocks)) {
        if ($block -is [hashtable] -and $block['text']) { return [string]$block['text'] }
    }
    return '—'
}

function Register-RichPayloadMeasurement {
    <#
        Records how big a screen's payload was, and warns while it still fits.

        The 7.87 outage was found only after a report had already stopped
        rendering for a whole session. Nothing was watching the size until it
        was too large; a screen crosses the limit gradually, as a station's
        day fills up, and the first person to know was the operator whose
        table vanished.

        Measured for every payload including the ones refused for size - those
        are the interesting ones - and warned once per screen so a busy day
        does not fill the log with the same line.
    #>
    param([AllowNull()][array]$Blocks, [Parameter(Mandatory)][int]$Length)
    $screen = Get-RichBlocksTitle -Blocks $Blocks
    if ($Length -gt [int]$script:RichPayloadPeak.Length) {
        $script:RichPayloadPeak = @{ Length = $Length; Screen = $screen }
    }
    # Warned once per screen, and a screen is its heading with the numbers
    # taken out. Eight headings carry a count or a period in them - "الأحداث
    # القادمة (12)", "تقرير الموجزات - هذا الأسبوع" - so keying on the heading
    # as written made "once" mean once per count: the log would repeat the
    # same warning all day, and the table of warned screens would gain a key
    # every time a number changed, for as long as the bridge ran.
    $key = ($screen -replace '\d+', '') -replace '\s+', ' '
    # 70%: far enough below the limit that there is time to cap a table, and
    # high enough that an ordinary screen never trips it.
    $threshold = [int]($script:RichPayloadLimit * 0.7)
    if ($Length -ge $threshold -and -not $script:RichPayloadWarned.ContainsKey($key)) {
        $script:RichPayloadWarned[$key] = $true
        $percent = [int](($Length * 100) / $script:RichPayloadLimit)
        Write-BridgeLog "Rich payload for '$screen' is $Length characters, $percent% of the limit - cap its rows before it loses its table" 'WARN'
    }
}

function Get-RichPayloadPeak {
    <# The biggest payload of this run, as a screen name, a size and a
       percentage of the limit - what the operating-numbers screen shows. #>
    $length = [int]$script:RichPayloadPeak.Length
    return [pscustomobject]@{
        Length = $length
        Screen = [string]$script:RichPayloadPeak.Screen
        Percent = if ($script:RichPayloadLimit -gt 0) { [int](($length * 100) / $script:RichPayloadLimit) } else { 0 }
    }
}

function ConvertTo-RichMessagePayload {
    <# The rich_message parameter, serialised once and measured on the way
       past. Both senders go through here so a payload cannot be built without
       being counted - which is how editMessageText came to carry no size
       check at all while sendRichMessage had one. #>
    param([Parameter(Mandatory)][array]$Blocks)
    $rich = (@{ blocks = $Blocks; is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)
    Register-RichPayloadMeasurement -Blocks $Blocks -Length $rich.Length
    return $rich
}

function Test-RichBlocksSendable {
    <# Whether this payload is worth a round trip at all. #>
    param([AllowNull()][array]$Blocks)
    if ($script:RichMessagesUnavailable) { return $false }
    foreach ($type in @(Get-RichBlockTypes -Blocks $Blocks)) {
        if ($script:RichBlockTypesUnavailable.ContainsKey($type)) { return $false }
    }
    return $true
}

function Register-RichBlocksAccepted {
    <# A type that has rendered once is a type this server has. That record is
       what lets a later refusal be blamed on the new thing in the payload
       rather than on everything in it. #>
    param([AllowNull()][array]$Blocks)
    foreach ($type in @(Get-RichBlockTypes -Blocks $Blocks)) { $script:RichBlockTypesProven[$type] = $true }
}

function Register-RichBlocksRejected {
    <#
        Narrows a refusal to the smallest thing it can honestly be blamed on.

        A 400 says the payload was wrong, not which part, and switching the
        whole session off for it meant one screen reaching for a block type
        this server does not have took the status table, the reports and the
        news listing down with it until a restart. So only the types that have
        never rendered here are blamed: adopting a new block risks that block
        and nothing else.

        When every type in the payload has already rendered before, the fault
        is in this particular message - its size, a field, a value - and not
        in a capability. Nothing is disabled then, or one oversized report
        would permanently cost the bridge a block type that works.
    #>
    param([AllowNull()][array]$Blocks)
    $unproven = @(Get-RichBlockTypes -Blocks $Blocks | Where-Object { -not $script:RichBlockTypesProven.ContainsKey($_) })
    if ($unproven.Count -eq 0) { return @() }
    foreach ($type in $unproven) { $script:RichBlockTypesUnavailable[$type] = $true }
    return $unproven
}

function Reset-RichBlockCapabilities {
    $script:RichMessagesUnavailable = $false
    $script:RichBlockTypesProven = @{}
    $script:RichBlockTypesUnavailable = @{}
}

function Resolve-RichSendFailure {
    <# The two refusals mean different things. A 404 is the method missing, so
       nothing built from blocks will ever work here and the session-wide stop
       is both correct and the cheap answer. A 400 is this payload. #>
    param([Parameter(Mandatory)][string]$ErrorText, [AllowNull()][array]$Blocks, [Parameter(Mandatory)][string]$Context,
        [int]$PayloadLength = 0)
    if ($ErrorText -match '404') {
        $script:RichMessagesUnavailable = $true
        Write-BridgeLog "$Context is not available here; using text for the rest of this session: $ErrorText" 'WARN'
        return
    }
    if ($ErrorText -match '400') {
        # A large payload is refused for being large. Blaming the block types
        # in it would disable them for every later screen, which is how a
        # single oversized report took the tables off the status screens, the
        # health centre and the digest until the bridge was restarted.
        if ($PayloadLength -gt 0 -and -not (Test-RichPayloadSize -Length $PayloadLength)) {
            Write-BridgeLog "$Context refused a $PayloadLength-character payload; that is a size, not a missing capability, so nothing was disabled: $ErrorText" 'WARN'
            return
        }
        $blamed = @(Register-RichBlocksRejected -Blocks $Blocks)
        if ($blamed.Count -gt 0) {
            Write-BridgeLog "$Context refused a payload using $($blamed -join ', '); those block types are disabled for this session: $ErrorText" 'WARN'
        }
        else {
            Write-BridgeLog "$Context refused this message, but every block type in it has rendered before, so nothing was disabled: $ErrorText" 'WARN'
        }
        return
    }
    Write-BridgeLog "$Context failed: $ErrorText" 'WARN'
}

function Send-TelegramRichMessage {
    <#
        A message built from blocks (Bot API 10.1) rather than from text with
        tags in it: a real table, with a header row Telegram lays out, instead
        of columns lined up by hand with spaces that a proportional font on a
        phone then fails to line up at all.

        is_rtl is passed because every screen in this bridge is Arabic, and a
        table laid out left-to-right puts the first column where the reader's
        eye arrives last.

        Returns $false rather than throwing, so every caller keeps its
        existing text version as the fallback. A refusal is remembered so the
        next screen does not pay a round trip to discover the same thing -
        but only as narrowly as it can honestly be read: see
        Resolve-RichSendFailure.
    #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][array]$Blocks,
        [hashtable]$ReplyMarkup
    )
    if (-not (Test-RichBlocksSendable -Blocks $Blocks)) { return $false }
    # A 🔄 press redraws its own message, rich screens included.
    $refreshId = Use-RefreshTarget -ChatId $ChatId
    if ($refreshId -gt 0 -and (Edit-TelegramRichMessage -ChatId $ChatId -MessageId $refreshId -Blocks $Blocks -ReplyMarkup $ReplyMarkup)) {
        $script:LastTelegramMessageId = $refreshId
        return $true
    }
    $rich = ConvertTo-RichMessagePayload -Blocks $Blocks
    # Not sent at all when it is far larger than anything that renders here.
    # The text fallback covers this screen, and no block type is blamed for
    # what is a size problem - which is how one big report cost every other
    # screen its table for a whole session.
    if (-not (Test-RichPayloadSize -Length $rich.Length)) {
        Write-BridgeLog "A rich message of $($rich.Length) characters is past what this bridge sends; using text for this screen only" 'DEBUG'
        return $false
    }
    $body = @{ chat_id = $ChatId; rich_message = $rich }
    if ($ReplyMarkup) { $body.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendRichMessage" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if ($request.Success) {
        Register-RichBlocksAccepted -Blocks $Blocks
        return $true
    }
    if ([int](Get-JsonProp $request 'StatusCode') -eq 429) {
        $script:TelegramRateLimitHits++
        # $false, so the caller's text fallback runs NOW. This used to queue
        # the rich send and answer $true, which is the caller's signal that the
        # screen arrived - so the mandatory plain-text version was skipped.
        # When the queue was full the item was dropped without a log line, and
        # even when it was accepted a later terminal failure discarded it long
        # after the fallback had been skipped. An operator pressing 📊 during an
        # on-air fault got nothing at all, and nothing in the log named their
        # chat or their screen.
        #
        # Send-TelegramMessage already owns deferral - retry_after, the priority
        # rules, the per-chat log line - so the text fallback is deferred
        # properly by the one place that knows how. Two deferral paths is the
        # guard written twice that AGENTS.md says will drift.
        return $false
    }
    Resolve-RichSendFailure -ErrorText ([string]$request.Error) -Blocks $Blocks -Context 'sendRichMessage' -PayloadLength $rich.Length
    return $false
}

function Edit-TelegramRichMessage {
    <#
        Replaces a sent rich message in place (Bot API 10.1's rich_message on
        editMessageText).

        The reorder screen re-renders on every ⬆️/⬇️ press, so without this a
        rich version of it would leave a new message behind for each one - the
        pile of stale keyboards that editing in place was introduced to stop.

        Returns $false rather than throwing, so a caller keeps its text
        version as the fallback, and a refusal is narrowed and remembered
        exactly as Send-TelegramRichMessage does.
    #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][int]$MessageId,
        [Parameter(Mandatory)][array]$Blocks,
        [hashtable]$ReplyMarkup
    )
    if (-not (Test-RichBlocksSendable -Blocks $Blocks)) { return $false }
    $rich = ConvertTo-RichMessagePayload -Blocks $Blocks
    # The same gate sending has had since 7.87, which this never got: an
    # oversized edit is a 400 like any other, and a 400 here narrows or
    # disables a block type for the rest of the session. The reorder screen
    # re-renders on every press, so it would have paid that price repeatedly.
    if (-not (Test-RichPayloadSize -Length $rich.Length)) {
        Write-BridgeLog "A rich edit of $($rich.Length) characters is past what this bridge sends; using text for this screen only" 'DEBUG'
        return $false
    }
    $body = @{
        chat_id = $ChatId
        message_id = $MessageId
        rich_message = $rich
    }
    if ($ReplyMarkup) { $body.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/editMessageText" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    # Unchanged is redrawn, as in Edit-TelegramMessageText.
    if ($request.Success -or [string]$request.Error -like '*message is not modified*') {
        Register-RichBlocksAccepted -Blocks $Blocks
        return $true
    }
    if ([int](Get-JsonProp $request 'StatusCode') -eq 429) {
        $script:TelegramRateLimitHits++
        # $false, so the caller's text fallback runs NOW. This used to queue
        # the rich send and answer $true, which is the caller's signal that the
        # screen arrived - so the mandatory plain-text version was skipped.
        # When the queue was full the item was dropped without a log line, and
        # even when it was accepted a later terminal failure discarded it long
        # after the fallback had been skipped. An operator pressing 📊 during an
        # on-air fault got nothing at all, and nothing in the log named their
        # chat or their screen.
        #
        # Send-TelegramMessage already owns deferral - retry_after, the priority
        # rules, the per-chat log line - so the text fallback is deferred
        # properly by the one place that knows how. Two deferral paths is the
        # guard written twice that AGENTS.md says will drift.
        return $false
    }
    Resolve-RichSendFailure -ErrorText ([string]$request.Error) -Blocks $Blocks -Context 'editMessageText' -PayloadLength $rich.Length
    return $false
}

function Send-TelegramPhoto {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Caption,
        [hashtable]$ReplyMarkup
    )
    if (Test-DeadChat -ChatId $ChatId) {
        Write-BridgeLog "Skipping photo send to quarantined dead chat $ChatId"
        return
    }
    $form = @{ chat_id = "$ChatId"; photo = Get-Item -Path $FilePath }
    if ($Caption) { $form.caption = $Caption }
    if ($ReplyMarkup) { $form.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendPhoto" -Method Post -Form $form `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 3
    if (-not $request.Success) {
        if ([int](Get-JsonProp $request 'StatusCode') -eq 429) {
            $script:TelegramRateLimitHits++
            $retryMs = [math]::Max(1000, [int](Get-JsonProp $request 'RetryAfterMs'))
            Add-TelegramOutboxItem -Uri "$apiBase/sendPhoto" -Form $form -DueAt (Get-Date).AddMilliseconds($retryMs) -Attempts 0 | Out-Null
            return
        }
        Write-BridgeLog "Failed to send Telegram photo to $ChatId : $($request.Error)" "ERROR"
        Register-TelegramSendFailure -ChatId $ChatId -StatusCode ([int](Get-JsonProp $request 'StatusCode')) -ErrorText ([string]$request.Error)
        Send-TelegramMessage -ChatId $ChatId -Text (T 'tg.photoFailed' $($request.Error))
    }
}

function Send-TelegramVideo {
    <#
        The same shape as Send-TelegramPhoto, against sendVideo.

        supports_streaming lets a client start playing before the whole file
        has arrived, which is the difference between a clip that plays on tap
        and one that downloads first - and the bot is sending seconds of
        video, not a film.

        Telegram takes 50 MB per file. A few seconds of a broadcast stream
        does not come close, and the clip length is capped where it is asked
        for rather than checked here.
    #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Caption,
        [hashtable]$ReplyMarkup
    )
    if (Test-DeadChat -ChatId $ChatId) {
        Write-BridgeLog "Skipping video send to quarantined dead chat $ChatId"
        return
    }
    $form = @{ chat_id = "$ChatId"; video = Get-Item -Path $FilePath; supports_streaming = 'true' }
    if ($Caption) { $form.caption = $Caption }
    if ($ReplyMarkup) { $form.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendVideo" -Method Post -Form $form `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 3
    if (-not $request.Success) {
        if ([int](Get-JsonProp $request 'StatusCode') -eq 429) {
            $script:TelegramRateLimitHits++
            $retryMs = [math]::Max(1000, [int](Get-JsonProp $request 'RetryAfterMs'))
            Add-TelegramOutboxItem -Uri "$apiBase/sendVideo" -Form $form -DueAt (Get-Date).AddMilliseconds($retryMs) -Attempts 0 | Out-Null
            return
        }
        Write-BridgeLog "Failed to send Telegram video to $ChatId : $($request.Error)" "ERROR"
        Register-TelegramSendFailure -ChatId $ChatId -StatusCode ([int](Get-JsonProp $request 'StatusCode')) -ErrorText ([string]$request.Error)
        Send-TelegramMessage -ChatId $ChatId -Text (T 'tg.videoFailed' $($request.Error))
    }
}

function Confirm-TelegramCallback {
    <# Acknowledges a button press so Telegram stops showing the loading
       spinner on the client. Optional Text shows a small toast. #>
    param([Parameter(Mandatory)][string]$CallbackQueryId, [string]$Text, [switch]$Alert)
    $body = @{ callback_query_id = $CallbackQueryId }
    # Telegram truncates past 200 characters; cutting it here keeps the end of
    # the sentence rather than letting the client drop it mid-word.
    if ($Text) { $body.text = if ($Text.Length -gt 200) { $Text.Substring(0, 199) + '…' } else { $Text } }
    # A toast fades in about three seconds and is easy to miss on a phone held
    # at arm's length in a gallery. A refusal has to be read to be acted on,
    # so it gets a dialog the operator dismisses.
    if ($Alert) { $body.show_alert = $true }
    # The shared wrapper reports Telegram's retry_after consistently. A
    # callback acknowledgement is deliberately not put in the message outbox:
    # Telegram may expire its query before the delay, so a late answer cannot
    # reliably clear the client's spinner and must not block this tick.
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/answerCallbackQuery" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if (-not $request.Success) {
        # A 400 here is Telegram saying the query is too old or already
        # answered - the operator tapped a stale button. Logging that as an
        # error buries the failures that are actually the bridge's.
        $level = if ([string]$request.Error -like '*400 (Bad Request)*') { 'WARN' } else { 'ERROR' }
        Write-BridgeLog "Failed to answer callback query $CallbackQueryId : $($request.Error)" $level
    }
}

function Send-CallbackFailureNotice {
    <#
        The main loop's last resort: a button that died to an unhandled
        error used to cost the operator silence (seven 'Sum' failures in the
        log with nothing on any screen). Best-effort and throw-proof - this
        runs inside a catch, so it must never throw itself. Returns $true
        when the operator was told.
    #>
    param($CallbackQuery)
    try {
        $queryId = [string](Get-JsonProp $CallbackQuery 'id')
        if ($queryId) { Confirm-TelegramCallback -CallbackQueryId $queryId | Out-Null }
        $peer = Get-JsonProp (Get-JsonProp $CallbackQuery 'message') 'chat'
        $target = 0L
        if (-not [long]::TryParse([string](Get-JsonProp $peer 'id'), [ref]$target) -or $target -eq 0) { return $false }
        Send-TelegramMessage -ChatId $target -Text (T 'tg.requestFailed') | Out-Null
        return $true
    }
    catch {
        Write-BridgeLog "Callback failure notice itself failed: $($_.Exception.Message)" 'DEBUG'
        return $false
    }
}

function Get-TelegramUpdates {
    <# Returns the update array, never $null. Telegram can reply with
       ok:false (409 Conflict when a second poller exists, or after a token
       revoke) and StrictMode would otherwise throw on the missing 'result'
       property, turning a clear condition into a confusing crash loop.

       Deliberately NOT routed through Invoke-BridgeTelegramRequest, unlike
       every send: the polling loop already IS this call's retry policy, with
       its own exponential backoff to 60s. Retrying inside a retry would
       square the delay and stall the bridge on a transient blip. It therefore
       throws and lets the loop decide. #>
    param([long]$Offset, [int]$TimeoutSeconds)
    $allowed = '%5B%22message%22%2C%22callback_query%22%5D'
    $uri = "$apiBase/getUpdates?timeout=$TimeoutSeconds&offset=$Offset&allowed_updates=$allowed"
    # The transport deadline has to clear the long poll with room to spare,
    # because it also covers connection setup and the trip home. Ten seconds
    # over a fifteen-second poll was cutting live requests off mid-answer.
    $margin = [Math]::Max(5, (Get-SettingInt 'TelegramPollMarginSeconds' 10))
    $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec ($TimeoutSeconds + $margin)
    if (-not (Get-JsonProp $response 'ok')) {
        $desc = [string](Get-JsonProp $response 'description')
        throw "Telegram getUpdates rejected the request: $desc"
    }
    return @(Get-JsonProp $response 'result')
}

function Clear-PendingTelegramUpdates {
    <# Telegram holds undelivered updates for up to 24 hours. Without this, a
       button press that arrived while the bridge was down is delivered - and
       executed - the moment it restarts. On a playout system that means a
       graphic going on air by itself, possibly during a completely different
       programme. Confirming everything queued at startup is the safe default;
       an operator who still wants the action simply presses again.

       Returns the offset to start polling from. #>
    try {
        $allowed = '%5B%22message%22%2C%22callback_query%22%5D'
        $probe = Invoke-RestMethod -Uri "$apiBase/getUpdates?offset=-1&timeout=0&allowed_updates=$allowed" -Method Get -TimeoutSec 20
        $pending = @(Get-JsonProp $probe 'result')
        if ($pending.Count -eq 0) { return 0 }
        $nextOffset = [long]$pending[-1].update_id + 1
        # Re-requesting with the advanced offset is what actually acknowledges
        # the backlog to Telegram.
        Invoke-RestMethod -Uri "$apiBase/getUpdates?offset=$nextOffset&timeout=0&allowed_updates=$allowed" -Method Get -TimeoutSec 20 | Out-Null
        Write-BridgeLog "Discarded queued Telegram updates from before startup (offset now $nextOffset)" "WARN"
        return $nextOffset
    }
    catch {
        Write-BridgeLog "Could not drain pending updates: $($_.Exception.Message)" "WARN"
        # Zero is a valid empty-backlog offset. A distinct failure value keeps
        # startup from processing stale commands after a transient outage.
        return -1
    }
}

function Get-BridgeAlertCause {
    <#
        What an alert is about, as a key: its first line, without tags and
        without any number in it.

        The numbers are what differ between one occurrence and the next - a
        layer, a count, a clock time - so they are exactly what must not be
        part of the identity of the cause, or every occurrence looks new.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $first = @($Text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if (@($first).Count -eq 0) { return '' }
    $clean = ConvertFrom-TelegramHtmlText ([string]@($first)[0])
    return (($clean -replace '\d+', '#').Trim())
}

function Add-BridgeAlertOccurrence {
    <#
        Records that this alert happened, and says so when it is not the first
        time.

        Measured on this station's own log: 707 of 752 warning and error lines
        belong to a cause that had already appeared three times or more, and
        one of them - the output capture failing - repeated 22 times across a
        fortnight without anyone acting on it. Every alert arrived looking
        like the first, so each was read as a one-off and none as a fault
        with a cause.

        Only failures are counted. A heartbeat or a digest repeating is the
        system working, and marking that as a recurrence would teach the
        counter to be ignored.

        The table lives in memory: a restart forgets, which is the right
        trade for a screenful of state, and the window that matters is hours
        rather than weeks.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [datetime]$Now = (Get-Date))
    # No Minimum argument: Get-SettingInt's second positional is a floor, and a
    # floor of six would clamp a deliberate zero back up and make the off
    # switch unreachable. The default value lives in $script:DefaultSettings.
    $hours = Get-SettingInt 'RepeatAlertWindowHours'
    if ($hours -le 0) { return '' }
    if ($Text -notmatch '^\s*(⚠|🔴|❌|📼|🟠)') { return '' }
    $cause = Get-BridgeAlertCause -Text $Text
    if ([string]::IsNullOrWhiteSpace($cause)) { return '' }
    $cutoff = $Now.AddHours(-$hours)
    $seen = [System.Collections.Generic.List[datetime]]::new()
    if ($script:AlertHistory.ContainsKey($cause)) {
        foreach ($at in @($script:AlertHistory[$cause])) { if ($at -gt $cutoff) { $seen.Add($at) } }
    }
    $seen.Add($Now)
    $script:AlertHistory[$cause] = $seen.ToArray()
    # Causes that stopped happening are dropped, so a long uptime does not
    # grow this table by one entry per distinct fault forever.
    foreach ($key in @($script:AlertHistory.Keys)) {
        if (@(@($script:AlertHistory[$key]) | Where-Object { $_ -gt $cutoff }).Count -eq 0) { $script:AlertHistory.Remove($key) }
    }
    if ($seen.Count -lt 3) { return '' }
    $span = Format-DurationSeconds -Seconds ([int]($Now - $seen[0]).TotalSeconds)
    return (T 'tg.repeat' $($seen.Count) $span $($seen[0].ToString('HH:mm')))
}

function Sync-PinnedRecurrence {
    <#
        P2: a chronic fault gets a fixed place. The third occurrence of a
        cause pins the alert in every admin chat; later ones edit the pinned
        message with the new count instead of adding another drifting line.
        No new setting: RepeatAlertWindowHours=0 already disables recurrence
        counting, and with no counting there is nothing to pin.
    #>
    param([Parameter(Mandatory)][string]$Cause, [Parameter(Mandatory)][string]$Text,
        [hashtable]$SentMessageIds = @{})
    $count = @(@($script:AlertHistory[$Cause]) | Where-Object { $_ }).Count
    if ($count -lt 3) { return }
    if (-not $script:PinnedRecurrences.ContainsKey($Cause)) {
        $pinned = @{}
        foreach ($chatId in @($SentMessageIds.Keys)) {
            $messageId = [int]$SentMessageIds[$chatId]
            if ($messageId -le 0) { continue }
            if (Add-TelegramMessagePin -ChatId ([long]$chatId) -MessageId $messageId) { $pinned[[long]$chatId] = $messageId }
        }
        if ($pinned.Count -gt 0) {
            $script:PinnedRecurrences[$Cause] = $pinned
            Write-BridgeLog "Pinned recurring alert '$Cause' in $($pinned.Count) admin chat(s)"
        }
        return
    }
    foreach ($chatId in @($script:PinnedRecurrences[$Cause].Keys)) {
        # Plain, like the broadcast that created it: Send-AdminBroadcast
        # sends without a parse mode, and an edit that renders the tags
        # would show a different message than the one pinned.
        Edit-TelegramMessageText -ChatId ([long]$chatId) -MessageId ([int]$script:PinnedRecurrences[$Cause][$chatId]) -Text $Text | Out-Null
    }
}

function Add-TelegramMessagePin {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][int]$MessageId)
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/pinChatMessage" -Method Post -Body @{ chat_id = $ChatId; message_id = $MessageId } `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if (-not $request.Success) { Write-BridgeLog "Failed to pin message $MessageId in $ChatId : $($request.Error)" "WARN"; return $false }
    return $true
}

function Update-PinnedRecurrenceSweep {
    <#
        P2: unpins what stopped recurring. AlertHistory prunes causes that
        went quiet past the window; a pin whose cause is gone is a solved
        fault still nailed to the top of the chat, so it comes down with a
        log line, not another message.
    #>
    foreach ($cause in @($script:PinnedRecurrences.Keys)) {
        if ($script:AlertHistory.ContainsKey($cause)) { continue }
        foreach ($chatId in @($script:PinnedRecurrences[$cause].Keys)) {
            $body = @{ chat_id = ([long]$chatId); message_id = ([int]$script:PinnedRecurrences[$cause][$chatId]) }
            Invoke-BridgeTelegramRequest -Uri "$apiBase/unpinChatMessage" -Method Post -Body $body `
                -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2 | Out-Null
        }
        $script:PinnedRecurrences.Remove($cause)
        Write-BridgeLog "Unpinned resolved recurring alert '$cause'"
    }
}

function Test-BridgeNoticeSuppressed {
    <#
        Has this cause said enough for one hour?

        The last resort against a fault that can talk. Every guard before this
        one is specific - a cooldown here, a WarnedAt mark there - and each was
        correct until the day it was not: a mark written where nothing could
        read it turned one expiry warning into one per tick on a live channel,
        and the only thing that eventually stopped it was Telegram's own 429.

        Counted PER CAUSE, never globally. A global budget spent by one chatty
        fault would swallow the unrelated alert that mattered, which is the
        opposite of the point. Numbers are already stripped from a cause by
        Get-BridgeAlertCause, so every repeat of one fault shares one key
        however much its layer or its countdown differ.

        Opt-in, and deliberately so: this must never reach a message the
        operator asked for. An operator putting fifteen graphics to air in an
        hour produces fifteen confirmations whose causes are identical once the
        numbers are stripped, and capping those would hide the air itself.
        Only unsolicited notices pass a -Cause.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Cause, [long]$ChatId = 0, [datetime]$Now = (Get-Date))
    $max = Get-SettingInt 'AlertMaxPerCausePerHour'
    if ($max -le 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($Cause)) { return $false }

    $key = "$ChatId|$Cause"
    $cutoff = $Now.AddHours(-1)
    $record = if ($script:AlertSuppression.ContainsKey($key)) { $script:AlertSuppression[$key] } else { $null }
    $seen = [System.Collections.Generic.List[datetime]]::new()
    if ($record) { foreach ($at in @($record.Sent)) { if ($at -gt $cutoff) { $seen.Add($at) } } }

    if ($seen.Count -lt $max) {
        $seen.Add($Now)
        $script:AlertSuppression[$key] = @{
            Sent = $seen.ToArray(); Held = if ($record) { [int]$record.Held } else { 0 }
            Cause = $Cause; ChatId = $ChatId; LastAt = $Now
        }
        return $false
    }

    # Over the cap. Held rather than dropped: the count is what the summary
    # reports when the hour rolls over, so nothing disappears unmentioned.
    # A plain statement: PowerShell parses a parenthesised if here but runs it
    # as a command, so the arithmetic never happens.
    $held = 0
    if ($record) { $held = [int]$record.Held }
    $held++
    $script:AlertSuppression[$key] = @{
        Sent = $seen.ToArray(); Held = $held; Cause = $Cause; ChatId = $ChatId; LastAt = $Now
    }
    # Logged every time. The cap is quiet towards the operator, never towards
    # whoever maintains the bridge.
    Write-BridgeLog "Alert cap reached for cause '$Cause' (chat $ChatId): $max in the last hour, holding #$held" 'WARN'
    return $true
}

function Update-AlertSuppressionSweep {
    <# Says how much was held once the hour has rolled over and the fault has
       gone quiet. A cap that swallows without a receipt is indistinguishable
       from a bridge that stopped noticing. #>
    $max = Get-SettingInt 'AlertMaxPerCausePerHour'
    $now = Get-Date
    $cutoff = $now.AddHours(-1)
    foreach ($key in @($script:AlertSuppression.Keys)) {
        $record = $script:AlertSuppression[$key]
        $live = @(@($record.Sent) | Where-Object { $_ -gt $cutoff })
        # Still inside its hour, or still arriving: nothing to summarise yet.
        if ($live.Count -ge $max -and $max -gt 0) { continue }
        if ([datetime]$record.LastAt -gt $now.AddMinutes(-2)) { continue }
        $held = [int]$record.Held
        $script:AlertSuppression.Remove($key)
        if ($held -le 0) { continue }
        $chat = [long]$record.ChatId
        $text = (T 'tg.muted' $(Get-ArabicCountNoun -Count $held -One 'تنبيه' -Two 'تنبيهان' -Few 'تنبيهات' -Many 'تنبيهًا' -EnglishOne 'alert' -EnglishMany 'alerts')) +
        (T 'tg.cause' $(ConvertTo-TelegramHtmlText $([string]$record.Cause)))
        Write-BridgeLog "Held $held alert(s) for cause '$($record.Cause)' (chat $chat) after the hourly cap" 'WARN'
        if ($chat -gt 0) { Send-TelegramMessage -ChatId $chat -Text $text -ParseMode HTML }
        else { Send-AdminBroadcast -Text $text }
    }
}

function Send-AdminBroadcast {
    <#
        -Urgent bypasses quiet hours. Everything meaning the channel is wrong
        right now - a black output, a graphic that will not come off - must be
        urgent. Everything that can wait until someone is awake should not be:
        a bot that pages at 03:00 about a template it could not verify gets
        muted, and a muted bot is worse than a silent one, because the alert
        that mattered then arrives to a muted chat.
    #>
    param([Parameter(Mandatory)][string]$Text, [hashtable]$ReplyMarkup, [switch]$Urgent)
    # Counted here rather than at each of the twenty call sites that raise an
    # alarm: they all pass through this one function, and a guard in one place
    # cannot be forgotten by the twenty-first.
    $repeat = Add-BridgeAlertOccurrence -Text $Text
    $repeatCause = ''
    if ($repeat) {
        $Text = "$Text`n$repeat"
        # P2: the cause is read from the first line, which the appended
        # recurrence line does not change.
        $repeatCause = Get-BridgeAlertCause -Text $Text
    }
    if (-not $Urgent -and (Test-QuietHoursActive)) {
        $script:QuietHoursQueue.Add(@{ At = (Get-Date); Text = $Text }) | Out-Null
        # Capped, because the digest is one Telegram message and Telegram stops
        # at 4096 characters. A long night with a chatty source would otherwise
        # grow both the file and a message that cannot be delivered at all. The
        # oldest go first and the count is kept, so the morning still says how
        # many there were rather than quietly showing fewer.
        $held = $script:QuietHoursQueue.Count
        if ($held -gt $script:QuietHoursQueueMax) {
            $script:QuietHoursQueue.RemoveRange(0, $held - $script:QuietHoursQueueMax)
            $script:QuietHoursDropped = [int]$script:QuietHoursDropped + ($held - $script:QuietHoursQueueMax)
        }
        Save-QuietHoursQueue | Out-Null
        Write-BridgeLog "Held a non-urgent admin notice for the morning digest (queue: $($script:QuietHoursQueue.Count))"
        return
    }
    # Capped once for the whole broadcast, not once per administrator: the
    # alert is one event, and counting it three times because three people
    # are listening would reach the cap three times faster.
    if (Test-BridgeNoticeSuppressed -Cause (Get-BridgeAlertCause -Text $Text)) { return }
    $sentIds = @{}
    foreach ($adminId in @(Get-AdminNotifyIds)) {
        Send-TelegramMessage -ChatId $adminId -Text $Text -ReplyMarkup $ReplyMarkup | Out-Null
        $sentIds[$adminId] = [int]$script:LastTelegramMessageId
    }
    # The first line names the notice without its detail. Without this the
    # log could say a notice failed but never that one went.
    $firstLine = (($Text -split "`n")[0]) -replace '<[^>]+>', ''
    Write-BridgeLog "Admin notice sent to $($sentIds.Count) administrator(s): $(Protect-SensitiveText -Text $firstLine)" 
    if ($repeatCause) { Sync-PinnedRecurrence -Cause $repeatCause -Text $Text -SentMessageIds $sentIds }
}

function Get-AdminNotifyIds {
    <#
        Everyone who should hear an administrator notice.

        Both lists, not AdminChatIds alone. They are meant to agree and
        nothing made them: on this installation AdminUserIds carried a third
        administrator who was in no chat list, so he could approve a stranger
        into the on-air controls and was never told one had asked. An access
        request reached two of the three, one approved inside a minute, and
        the third learned of it from a colleague.

        A private chat's id is the user's own id, which is why one list can
        stand in for the other here. An administrator who has never opened a
        chat with the bot cannot be messaged at all - that send fails and is
        logged, which is itself the answer to "why does he never hear
        anything".
    #>
    $ids = @(@(Get-JsonProp $config 'AdminChatIds') + @(Get-JsonProp $config 'AdminUserIds'))
    return @($ids | ForEach-Object { [long]$_ } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
}

function Get-AdminListMismatch {
    <# The administrators one list holds and the other does not, in both
       directions. An id with authority and no notice hears nothing; an id
       with notice and no authority is told about decisions it cannot make. #>
    $chats = @(@(Get-JsonProp $config 'AdminChatIds') | ForEach-Object { [long]$_ } | Where-Object { $_ -gt 0 })
    $users = @(@(Get-JsonProp $config 'AdminUserIds') | ForEach-Object { [long]$_ } | Where-Object { $_ -gt 0 })
    return [pscustomobject]@{
        # Held authority, missing from the notices - the one that hurt.
        Unnotified = @($users | Where-Object { $chats -notcontains $_ } | Sort-Object -Unique)
        # Notified without authority - confusing rather than harmful.
        Unauthorized = @($chats | Where-Object { $users -notcontains $_ } | Sort-Object -Unique)
    }
}

function Save-QuietHoursQueue {
    <# Held notices outlive a restart, because being held is not the same as
       being unimportant - it is the opposite of being sent. A bridge restarted
       at 03:00 used to drop everything it was holding, and nobody ever learned
       those notices existed: they were never delivered, and the only trace was
       a log line written hours earlier saying the queue had grown. #>
    $path = Join-Path $script:logDir 'quiet-hours-queue.json'
    try {
        $entries = foreach ($item in @($script:QuietHoursQueue)) {
            @{ At = ([datetimeoffset]$item.At).ToString('o'); Text = [string]$item.Text }
        }
        return (Write-BridgeValidatedJson -Path $path -Json (ConvertTo-Json -InputObject @($entries) -Depth 4))
    }
    catch { Write-BridgeLog "Could not save the quiet-hours queue: $($_.Exception.Message)" 'WARN'; return $false }
}

function Import-QuietHoursQueue {
    $path = Join-Path $script:logDir 'quiet-hours-queue.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $read = Read-BridgeValidatedJson -Path $path -AsHashtable
        if (-not ($read -and $read.Data)) { return }
        foreach ($entry in @($read.Data)) {
            if (-not ($entry -is [System.Collections.IDictionary]) -or -not $entry.Contains('At')) { continue }
            $at = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$entry['At'], [ref]$at)) { continue }
            $script:QuietHoursQueue.Add(@{ At = $at; Text = [string]$entry['Text'] }) | Out-Null
        }
        if ($script:QuietHoursQueue.Count -gt 0) {
            Write-BridgeLog "Restored $($script:QuietHoursQueue.Count) notice(s) held from the previous run's quiet hours"
        }
    }
    catch { Write-BridgeLog "Could not read quiet-hours-queue.json: $($_.Exception.Message)" 'WARN' }
}

function Test-QuietHoursActive {
    # P4: a manual two-hour quiet sits beside the scheduled window. One
    # predicate, so the broadcast hold, the morning digest and every other
    # caller behave identically for both - including delivery of everything
    # held the moment the manual window ends.
    if ((Get-Date) -lt $script:ManualQuietUntil) { return $true }
    if (-not (Get-Setting 'QuietHoursEnabled')) { return $false }
    return (Test-BridgeQuietHour -Hour ((Get-Date).Hour) `
            -StartHour (Get-SettingInt 'QuietHoursStart' 0) -EndHour (Get-SettingInt 'QuietHoursEnd' 0))
}

function Update-QuietHoursQueue {
    <# Delivers everything held overnight as one message once the window has
       passed. One message rather than a burst: twenty notifications at 07:00
       is the same wall of noise the batching was meant to avoid. #>
    if ($script:QuietHoursQueue.Count -eq 0) { return }
    if (Test-QuietHoursActive) { return }
    $held = @($script:QuietHoursQueue)
    $script:QuietHoursQueue.Clear()
    Save-QuietHoursQueue | Out-Null
    $dropped = [int]$script:QuietHoursDropped
    $script:QuietHoursDropped = 0
    $headline = if ($dropped -gt 0) { (T 'tg.heldAlertsDropped' $($held.Count) $dropped) }
    else { (T 'tg.heldAlerts' $($held.Count)) }
    $lines = @($headline) + @($held | ForEach-Object {
            "• $($_.At.ToString('HH:mm')) — $(($_.Text -split "`n")[0])"
        })
    Write-BridgeLog "Flushed $($held.Count) quiet-hours notice(s)"
    foreach ($adminId in @(Get-JsonProp $config 'AdminChatIds')) {
        if ($adminId) { Send-TelegramMessage -ChatId ([long]$adminId) -Text ($lines -join "`n") }
    }
}

function Repair-TelegramHtmlChunks {
    <#
        Makes every page of a split HTML message valid on its own.

        Split-TelegramText cuts at Telegram's character limit and knows
        nothing about tags, so a cut inside a <blockquote> leaves page one
        with it unclosed and page two with a </blockquote> that opens
        nothing. Telegram answers 400 to both - which is how the reports
        screen stopped working outright: the banner report runs to 43 KB over
        a month, thirteen pages, every one of them refused.

        Each page is closed off at its end and the same tags reopened at the
        start of the next, outermost first, so the nesting survives the cut.
        The opening tag is remembered whole, so "<blockquote expandable>"
        comes back expandable rather than as a plain quote.

        Only tags that can legally wrap several lines are tracked. pre and
        code are deliberately not among them: they cannot contain other
        entities, so reopening one would swallow the rest of the page.
    #>
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][string[]]$Chunks)
    $pages = @(@($Chunks) | Where-Object { $null -ne $_ })
    if ($pages.Count -le 1) { return $pages }

    $spanning = @('blockquote', 'b', 'strong', 'i', 'em', 'u', 'ins', 's', 'strike', 'del', 'tg-spoiler')

    $repaired = [System.Collections.Generic.List[string]]::new()
    $open = [System.Collections.Generic.List[string]]::new()   # full opening tags, outermost first

    foreach ($page in $pages) {
        # Whatever the previous page left open is reopened here, in the order
        # that keeps the nesting identical to what it was before the cut.
        $prefix = if ($open.Count -gt 0) { ($open -join '') } else { '' }
        $body = $prefix + $page

        $open.Clear()
        foreach ($match in [regex]::Matches($body, '<(/?)([a-zA-Z-]+)(\s[^>]*)?>')) {
            $name = $match.Groups[2].Value.ToLowerInvariant()
            if ($name -notin $spanning) { continue }
            if ($match.Groups[1].Value -eq '/') {
                for ($i = $open.Count - 1; $i -ge 0; $i--) {
                    if ($open[$i] -match "^<$([regex]::Escape($name))(\s|>)") { $open.RemoveAt($i); break }
                }
            }
            else { $open.Add($match.Value) }
        }

        # Close what this page leaves open, innermost first.
        $suffix = ''
        for ($i = $open.Count - 1; $i -ge 0; $i--) {
            if ($open[$i] -match '^<([a-zA-Z-]+)') { $suffix += "</$($Matches[1].ToLowerInvariant())>" }
        }
        $repaired.Add($body + $suffix)
    }
    return @($repaired)
}

function New-CopyButton {
    <#
        A button that puts text on the clipboard (copy_text, Bot API 7.11).

        It carries no callback_data: Telegram performs the copy on the device
        and the bridge never hears about the press, which is why it is the one
        button here without one - and why this button cannot change after
        being pressed. Nothing arrives to change it: its label and its colour
        can only be chosen when the message is sent. Checked against the Bot
        API changelog through 10.3, the newest at the time of writing.

        So the colour is spent on saying what the button *is* rather than
        what it did. Blue is the bridge's colour for the action a screen
        offers; the copy button was the last one on these screens wearing
        none, which left the one button that behaves unlike every other
        looking exactly like them.
    #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][AllowEmptyString()][string]$Payload)
    # copy_text.text is capped at 256 characters by the Bot API, and a payload
    # over it does not truncate - Telegram refuses the WHOLE sendMessage with
    # 400. That matters here more than it looks: these buttons ride on edit
    # prompts, so the refused message is the prompt itself, and the pending
    # input state has already been armed. The operator sees nothing happen,
    # then types - and their next message is taken as the new value for a
    # field they never saw the prompt for. With UrgentBoardMaxTextLength at
    # its default of 300, a perfectly ordinary breaking line does this.
    #
    # $null rather than a truncated button: half a headline on the clipboard
    # is worse than no button, and every caller already prints the value in a
    # <code> block, which Telegram copies on tap.
    if ([string]$Payload -and $Payload.Length -gt 256) { return $null }
    # Not through New-BridgeButton: that one builds a button around a
    # callback, the single thing this button must not have. Clients older
    # than 9.4 ignore the style, and ConvertTo-TelegramReplyMarkupJson strips
    # it when button styles are turned off.
    return @{ text = $Text; copy_text = @{ text = [string]$Payload }; style = 'primary' }
}

function Get-CopyButtonNotice {
    <#
        The line that tells the reader what the copy button will do.

        It is written before the press because nothing can be written after
        one: copy_text (Bot API 7.11) is handled by Telegram on the device and
        sends the bridge no callback, so the bot cannot know the button was
        pressed and cannot answer it. Telegram's own client shows a brief
        confirmation; this line is what makes that confirmation expected
        rather than a surprise, and says where the copied text is meant to go.

        Shared so the promise is worded the same on every screen that makes
        it - a screen wording it differently is a screen an operator stops
        trusting.
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$Hint = (T 'tg.pasteWhereNeeded')
    )
    return (T 'tg.copyButton' $Label $Hint)
}

function Send-BridgeTextEditPrompt {
    <#
        Ask for replacement text, starting from the text being replaced.

        An editor fixing one word in a headline was retyping the headline. No
        bot can fill a person's input box - Telegram does not offer it - so
        the nearest thing is one tap to the clipboard, and this gives it twice
        over: the current text sits in a <code> span, which Telegram makes
        tap-to-copy, and a 📋 button copies it outright for anyone who does
        not know that.

        The current text is shown whole even when it is long. A truncated
        "current" is worse than none: an editor who copies it loses the tail
        without being told, which is the mistake this screen exists to
        prevent.
    #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Current,
        [Parameter(Mandatory)][string]$CancelData,
        [string]$CopyLabel = (T 'tg.copyCurrentText')
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$(ConvertTo-TelegramHtmlText $Prompt)</b>")
    $rows = @()
    # Declared before the branch: Set-StrictMode throws on an unassigned
    # variable, and the notice below asks about it whether or not there was
    # a current value at all.
    $copyButton = $null
    if ([string]::IsNullOrWhiteSpace($Current)) {
        $lines.Add((T 'tg.noCurrentText'))
    }
    else {
        $lines.Add('')
        $lines.Add((T 'tg.currentTextTapToCopy'))
        $lines.Add("<code>$(ConvertTo-TelegramHtmlText $Current)</code>")
        # Only when there is a button: over 256 characters New-CopyButton
        # declines, and a row holding $null is the malformed shape the repair
        # guard exists to catch.
        $copyButton = New-CopyButton -Text $CopyLabel -Payload $Current
        if ($copyButton) { $rows += , @($copyButton) }
    }
    $lines.Add('')
    $lines.Add((T 'tg.typeNewText'))
    if ($copyButton) {
        # Named after the button as it is actually labelled, minus its emoji:
        # a notice pointing at a button that reads something else is worse
        # than no notice.
        $notice = Get-CopyButtonNotice -Label ($CopyLabel -replace '^[^\p{L}]+', '') -Hint (T 'tg.pasteThenEdit')
        $lines.Add("<i>$(ConvertTo-TelegramHtmlText $notice)</i>")
    }
    $rows += , @((New-Button (T 'common.cancel') $CancelData))
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup @{ inline_keyboard = $rows }
}

function Send-TelegramPagedText {
    <#
        Sends a long screen as its first part plus a 📄 المزيد button.

        Send-TelegramMessage already splits past Telegram's 4096 characters,
        but it fires every part at once: the operator gets four messages they
        did not ask for and has to scroll up to find the beginning. Here the
        rest waits until it is wanted, which for the audit log and the release
        notes is usually never.

        Short text is sent untouched, so nothing gains a button it does not
        need.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [string]$Text = '', [string[]]$Parts = @(), $ReplyMarkup = $null,
        [ValidateSet('', 'HTML')][string]$ParseMode = '')
    # -Parts lets the caller break the text where it means something - the
    # release notes split after the third version, not mid-sentence at
    # whatever character the limit happens to fall on. Each part is still run
    # through the splitter, because a caller's idea of a part can itself be
    # longer than Telegram will take.
    $source = if ($Parts.Count -gt 0) { $Parts } else { @($Text) }
    $chunks = @($source | Where-Object { $_ } | ForEach-Object { Split-TelegramText -Text $_ })
    # Nothing to say is not an error, and it is not a message either. Telegram
    # rejects an empty body, and indexing an empty array throws before it even
    # gets that far.
    if ($chunks.Count -eq 0) { return }
    if ($chunks.Count -eq 1) {
        Send-TelegramMessage -ChatId $ChatId -Text ([string]$chunks[0]) -ReplyMarkup $ReplyMarkup -ParseMode $ParseMode
        return
    }
    # The mode travels with the pages: 📄 المزيد arrives on a later turn, and a
    # part sent without it would show the operator its own tags.
    # A page ending mid-blockquote is a page Telegram refuses, and so is the
    # one after it. Repaired before they are stored, so 📄 المزيد hands out
    # valid pages on every later turn too.
    if ($ParseMode -eq 'HTML') {
        $chunks = @(Repair-TelegramHtmlChunks -Chunks $chunks)
        # Repair adds the reopened and closing tags, which can push a page
        # that was already at the limit past it. Rather than send something
        # Telegram will refuse, the markup comes out and the text goes plain -
        # the same degrade Send-TelegramMessage makes for the same reason.
        if (@($chunks | Where-Object { $_.Length -gt $script:TelegramTextLimit }).Count -gt 0) {
            Write-BridgeLog "A paged HTML screen did not fit once its pages were closed off; markup removed and sent as text" 'WARN'
            $chunks = @(@($source | Where-Object { $_ } |
                        ForEach-Object { Split-TelegramText -Text (ConvertFrom-TelegramHtmlText -Text $_) }))
            $ParseMode = ''
        }
    }
    $script:PagedText[$ChatId] = @{ Chunks = $chunks; Index = 0; Markup = $ReplyMarkup; ParseMode = $ParseMode }
    Send-TelegramPagedChunk -ChatId $ChatId | Out-Null
}

function Send-TelegramPagedChunk {
    <# Sends the part now due, and hands the caller's own keyboard back with
       the last one so the screen ends where it would have ended anyway. #>
    param([Parameter(Mandatory)][long]$ChatId)
    if (-not $script:PagedText.ContainsKey($ChatId)) { return $false }
    $state = $script:PagedText[$ChatId]
    $chunks = @($state.Chunks)
    $index = [int]$state.Index
    if ($index -ge $chunks.Count) { $script:PagedText.Remove($ChatId); return $false }

    $isLast = $index -eq ($chunks.Count - 1)
    $markup = if ($isLast) { $state.Markup }
    else { @{ inline_keyboard = @(, @((New-Button (T 'tg.more' $($index + 2) $($chunks.Count)) 'more:next'))) } }

    $mode = if ($state.ContainsKey('ParseMode')) { [string]$state['ParseMode'] } else { '' }
    Send-TelegramMessage -ChatId $ChatId -Text ([string]$chunks[$index]) -ReplyMarkup $markup -ParseMode $mode
    if ($isLast) { $script:PagedText.Remove($ChatId) } else { $state.Index = $index + 1 }
    return $true
}

function Register-BotCommands {
    <# Populates Telegram's ☰ Menu button so a brand-new chat, or a user who
       lost the inline keyboard, always has a visible way in. Failures here are
       never fatal - the bot works fine without the menu. #>
    <#
        Scoped, because Telegram otherwise shows one global list to everybody:
        ⚙️ الإعدادات, 📜 سجل and the diagnostics commands were advertised to
        every operator and refused only once tapped. The default scope now
        carries what an operator can actually use, and each administrator's
        own chat gets the full list. A demoted administrator has their chat
        scope deleted, so they fall back to the operator menu instead of
        keeping a list of commands that will now refuse them.
    #>
    try {
        $payload = { param($Commands)
            @($Commands | ForEach-Object { @{ command = $_.command; description = $_.description } }) }
        # ContainsKey, not $_.Admin: reading a key a hashtable does not have
        # throws under StrictMode, and every operator command lacks this one.
        $operatorCommands = @($script:BotCommandList | Where-Object { -not ($_.ContainsKey('Admin') -and $_.Admin) })

        $body = @{ commands = (& $payload $operatorCommands) } | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod -Uri "$apiBase/setMyCommands" -Method Post -Body $body -ContentType 'application/json; charset=utf-8' | Out-Null

        $menuBody = @{ menu_button = @{ type = 'commands' } } | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod -Uri "$apiBase/setChatMenuButton" -Method Post -Body $menuBody -ContentType 'application/json; charset=utf-8' | Out-Null

        # One call per authorized user. Bounded by the whitelist - a handful of
        # people on a playout channel - and it runs only at startup and after a
        # role change.
        $adminCount = 0
        foreach ($user in @(Get-AuthorizedUsers)) {
            $scope = @{ type = 'chat'; chat_id = [long]$user.UserId }
            try {
                if ($user.Role -in @('owner', 'admin')) {
                    $adminCount++
                    $scoped = @{ commands = (& $payload $script:BotCommandList); scope = $scope } | ConvertTo-Json -Depth 5 -Compress
                    Invoke-RestMethod -Uri "$apiBase/setMyCommands" -Method Post -Body $scoped -ContentType 'application/json; charset=utf-8' | Out-Null
                }
                else {
                    $scoped = @{ scope = $scope } | ConvertTo-Json -Depth 5 -Compress
                    Invoke-RestMethod -Uri "$apiBase/deleteMyCommands" -Method Post -Body $scoped -ContentType 'application/json; charset=utf-8' | Out-Null
                }
            }
            catch { Write-BridgeLog "Could not scope bot commands for $($user.UserId): $($_.Exception.Message)" 'DEBUG' }
        }

        Write-BridgeLog "Registered $($operatorCommands.Count) operator commands, and all $($script:BotCommandList.Count) for $adminCount administrator(s)"
    }
    catch {
        Write-BridgeLog "Could not register bot commands: $($_.Exception.Message)" "WARN"
    }
}

function Get-PersistentReplyKeyboard {
    $buttons = @(@{ text = $script:MenuHotword }, @{ text = $script:HelpHotword })
    if (Get-Setting 'EnableNewsTickerManagement') { $buttons += @{ text = $script:NewsHotword } }
    return @{
        keyboard        = @( , $buttons )
        resize_keyboard = $true
        is_persistent   = $true
    }
}

function Show-MainMenuScreen {
    <# The menu screen without the pinned-keyboard bookkeeping Show-MainMenu
       does - what the two "back to the menu" callbacks want. One function, so
       the rich-then-text decision is made in a single place. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $keyboard = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks @(Get-MainMenuIntroBlocks -UserId $UserId) -ReplyMarkup $keyboard) { return }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-MainMenuIntro -UserId $UserId) -ParseMode HTML -ReplyMarkup $keyboard
}

function Show-MainMenu {
    <# The canonical "get me back to a known state" response: clears any
       half-finished flow, re-pins the persistent keyboard, then shows the
       inline menu. A message can only carry one reply_markup, hence two
       sends. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Intro = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    # Once per chat, not once per menu press. Telegram keeps a reply keyboard
    # pinned until it is replaced, so re-sending it every time bought nothing
    # and cost the operator a data-free message at the top of the screen on
    # every single press - the menu they opened for an answer led with a line
    # telling them the menu exists.
    if ((Get-Setting 'EnablePersistentMenuButton') -and -not $script:PersistentKeyboardPinned.ContainsKey($ChatId)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'tg.useHomeButton') -ReplyMarkup (Get-PersistentReplyKeyboard)
        $script:PersistentKeyboardPinned[$ChatId] = $true
    }
    # An -Intro leads the screen, it does not replace it. "أهلاً! اختر من
    # القائمة:" on its own is the data-free line this screen was rebuilt to
    # stop showing, and /بدء and /إلغاء were the two doors still leading to it.
    $status = Get-MainMenuIntro -UserId $UserId
    $text = if ([string]::IsNullOrWhiteSpace($Intro)) { $status } else { "$Intro`n`n$status" }
    $keyboard = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    # Table first, text as the fallback - the shape every other screen uses.
    # An -Intro leads the blocks the way it leads the text, so /بدء and /إلغاء
    # keep their greeting above the state rather than instead of it.
    $blocks = @()
    if (-not [string]::IsNullOrWhiteSpace($Intro)) { $blocks += @{ type = 'paragraph'; text = $Intro } }
    $blocks += @(Get-MainMenuIntroBlocks -UserId $UserId)
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $blocks -ReplyMarkup $keyboard) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML -ReplyMarkup $keyboard
}

function Import-UserProfiles {
    if (-not (Test-Path -LiteralPath $script:userProfilesFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:userProfilesFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            # Every stored field is carried, not a chosen three. The reader used
            # to whitelist AddedAt/AddedByUserId/LastActivityAt while Save-UserProfiles
            # serialised the whole map - so MutedAirNotices and RequestedAt were
            # written, saved, and then silently dropped on the next start. An
            # operator who muted air notices was un-muted by any restart, the
            # mute screen still showed them as muted, and the first
            # Update-UserLastActivity wrote the truncated map back over the file.
            # The .bak is a copy of that same truncated content, so nothing could
            # recover it. AGENTS.md says the mute is kept in the user's file and
            # survives; this is what makes that true.
            $entry = @{}
            foreach ($field in $prop.Value.PSObject.Properties) { $entry[$field.Name] = $field.Value }
            # The three the bridge reads with a type still get their type, so a
            # value that came back from JSON as something else cannot surprise a
            # caller that assumes [long] or [string].
            $entry['AddedAt'] = [string](Get-JsonProp $prop.Value 'AddedAt')
            $entry['AddedByUserId'] = [long](Get-JsonProp $prop.Value 'AddedByUserId')
            $entry['LastActivityAt'] = [string](Get-JsonProp $prop.Value 'LastActivityAt')
            $script:UserProfiles[$prop.Name] = $entry
        }
    }
    catch { Write-BridgeLog "Could not read user-profiles.json: $($_.Exception.Message)" 'WARN' }
}

