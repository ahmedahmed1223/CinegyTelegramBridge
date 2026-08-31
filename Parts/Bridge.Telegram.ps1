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

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$ReplyMarkup,
        [ValidateSet('', 'HTML')][string]$ParseMode = ''
    )
    [string[]]$chunks = @(Split-TelegramText -Text $Text)
    # A split lands wherever the budget runs out, which for HTML can be the
    # middle of a tag - and Telegram rejects that outright. Callers asking for
    # HTML build one message deliberately; if one ever overflows, degrade to
    # plain text rather than lose the whole message to a 400.
    $mode = if ($ParseMode -and $chunks.Count -eq 1) { $ParseMode } else { '' }
    if ($ParseMode -and $chunks.Count -gt 1) {
        Write-BridgeLog "HTML message to $ChatId exceeded one chunk; sent as plain text" "WARN"
    }
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
            if ($request.Error -match '429') { $script:TelegramRateLimitHits++ }
            Write-BridgeLog "Failed to send Telegram message to $ChatId : $($request.Error)" "ERROR"
        }
    }
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
        existing text version as the fallback. A refusal of the method itself
        - the shape being wrong, or an API that does not have it - disables
        rich sending for the rest of the session: without that, every report
        would pay two round trips to discover the same thing again.
    #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][array]$Blocks,
        [hashtable]$ReplyMarkup
    )
    if ($script:RichMessagesUnavailable) { return $false }
    $body = @{
        chat_id = $ChatId
        rich_message = (@{ blocks = $Blocks; is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)
    }
    if ($ReplyMarkup) { $body.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendRichMessage" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if ($request.Success) { return $true }
    if ([string]$request.Error -match '400|404') {
        $script:RichMessagesUnavailable = $true
        Write-BridgeLog "sendRichMessage was refused; using text for the rest of this session: $($request.Error)" 'WARN'
    }
    else {
        Write-BridgeLog "Failed to send a rich message to $ChatId : $($request.Error)" 'WARN'
    }
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
    # Routed through the shared request wrapper like every other send, so a
    # flood-limited acknowledgement honours retry_after instead of being
    # dropped and leaving the operator's button spinning.
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
    $uri = "$apiBase/getUpdates?timeout=$TimeoutSeconds&offset=$Offset"
    $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec ($TimeoutSeconds + 10)
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
        $probe = Invoke-RestMethod -Uri "$apiBase/getUpdates?offset=-1&timeout=0" -Method Get -TimeoutSec 20
        $pending = @(Get-JsonProp $probe 'result')
        if ($pending.Count -eq 0) { return 0 }
        $nextOffset = [long]$pending[-1].update_id + 1
        # Re-requesting with the advanced offset is what actually acknowledges
        # the backlog to Telegram.
        Invoke-RestMethod -Uri "$apiBase/getUpdates?offset=$nextOffset&timeout=0" -Method Get -TimeoutSec 20 | Out-Null
        Write-BridgeLog "Discarded queued Telegram updates from before startup (offset now $nextOffset)" "WARN"
        return $nextOffset
    }
    catch {
        Write-BridgeLog "Could not drain pending updates: $($_.Exception.Message)" "WARN"
        return 0
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
    param([Parameter(Mandatory)][long]$ChatId, [string]$Text = '', [string[]]$Parts = @(), $ReplyMarkup = $null)
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
        Send-TelegramMessage -ChatId $ChatId -Text ([string]$chunks[0]) -ReplyMarkup $ReplyMarkup
        return
    }
    $script:PagedText[$ChatId] = @{ Chunks = $chunks; Index = 0; Markup = $ReplyMarkup }
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

    Send-TelegramMessage -ChatId $ChatId -Text ([string]$chunks[$index]) -ReplyMarkup $markup
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

function Show-MainMenu {
    <# The canonical "get me back to a known state" response: clears any
       half-finished flow, re-pins the persistent keyboard, then shows the
       inline menu. A message can only carry one reply_markup, hence two
       sends. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Intro = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    if (Get-Setting 'EnablePersistentMenuButton') {
        Send-TelegramMessage -ChatId $ChatId -Text "استخدم زر 🏠 القائمة أسفل الشاشة في أي وقت للرجوع إلى هنا." -ReplyMarkup (Get-PersistentReplyKeyboard)
    }
    if ([string]::IsNullOrWhiteSpace($Intro)) { $Intro = Get-MainMenuIntro }
    Send-TelegramMessage -ChatId $ChatId -Text $Intro -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
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

