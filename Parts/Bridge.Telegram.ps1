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

function ConvertTo-TelegramReplyMarkupJson {
    <# The single place a keyboard becomes wire JSON.

       EnableButtonStyles is honoured here rather than in New-BridgeButton so
       that building a keyboard stays a pure function of the draft - a button
       constructor that reads settings makes every keyboard test depend on a
       setting it does not care about - and so the setting is read once per
       message instead of once per button.

       Styled buttons are rebuilt without the field rather than edited: the
       caller's keyboard is theirs, and stripping it in place would change
       what a re-render sends next time. #>
    param([Parameter(Mandatory)][hashtable]$ReplyMarkup)
    $markup = $ReplyMarkup
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

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$ReplyMarkup,
        [ValidateSet('', 'HTML')][string]$ParseMode = ''
    )
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
        }
    }
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
            if (-not $request.Success) { Write-BridgeLog 'Dropped deferred Telegram request after retry failure.' 'ERROR' }
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
    $rich = (@{ blocks = $Blocks; is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)
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
        $retryMs = [math]::Max(1000, [int](Get-JsonProp $request 'RetryAfterMs'))
        Add-TelegramOutboxItem -Uri "$apiBase/sendRichMessage" -Body $body -DueAt (Get-Date).AddMilliseconds($retryMs) -Attempts 0 | Out-Null
        return $true
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
    $body = @{
        chat_id = $ChatId
        message_id = $MessageId
        rich_message = (@{ blocks = $Blocks; is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)
    }
    if ($ReplyMarkup) { $body.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/editMessageText" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if ($request.Success) {
        Register-RichBlocksAccepted -Blocks $Blocks
        return $true
    }
    if ([int](Get-JsonProp $request 'StatusCode') -eq 429) {
        $script:TelegramRateLimitHits++
        $retryMs = [math]::Max(1000, [int](Get-JsonProp $request 'RetryAfterMs'))
        Add-TelegramOutboxItem -Uri "$apiBase/editMessageText" -Body $body -DueAt (Get-Date).AddMilliseconds($retryMs) -Attempts 0 | Out-Null
        return $true
    }
    Resolve-RichSendFailure -ErrorText ([string]$request.Error) -Blocks $Blocks -Context 'editMessageText'
    return $false
}

function Send-TelegramPhoto {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Caption,
        [hashtable]$ReplyMarkup
    )
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
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل إرسال الصورة: $($request.Error)"
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
    if (-not $Urgent -and (Test-QuietHoursActive)) {
        $script:QuietHoursQueue.Add(@{ At = (Get-Date); Text = $Text }) | Out-Null
        Write-BridgeLog "Held a non-urgent admin notice for the morning digest (queue: $($script:QuietHoursQueue.Count))"
        return
    }
    foreach ($adminId in @(Get-JsonProp $config 'AdminChatIds')) {
        if ($adminId) { Send-TelegramMessage -ChatId ([long]$adminId) -Text $Text -ReplyMarkup $ReplyMarkup }
    }
}

function Test-QuietHoursActive {
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
    $lines = @("🌅 تنبيهات مؤجّلة من فترة الهدوء ($($held.Count))") + @($held | ForEach-Object {
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
    else { @{ inline_keyboard = @(, @((New-Button "📄 المزيد ($($index + 2)/$($chunks.Count))" 'more:next'))) } }

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
        Send-TelegramMessage -ChatId $ChatId -Text "استخدم زر 🏠 القائمة أسفل الشاشة في أي وقت للرجوع إلى هنا." -ReplyMarkup (Get-PersistentReplyKeyboard)
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
            $script:UserProfiles[$prop.Name] = @{
                AddedAt = [string](Get-JsonProp $prop.Value 'AddedAt'); AddedByUserId = [long](Get-JsonProp $prop.Value 'AddedByUserId')
                LastActivityAt = [string](Get-JsonProp $prop.Value 'LastActivityAt')
            }
        }
    }
    catch { Write-BridgeLog "Could not read user-profiles.json: $($_.Exception.Message)" 'WARN' }
}

