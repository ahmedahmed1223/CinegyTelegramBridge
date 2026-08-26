#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$ReplyMarkup
    )
    [string[]]$chunks = @(Split-TelegramText -Text $Text)
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        # [string] cast is deliberate belt-and-braces against anything
        # array-shaped ever reaching the body again.
        $body = @{ chat_id = $ChatId; text = [string]$chunks[$i] }
        # Only the final chunk carries the keyboard.
        if ($ReplyMarkup -and $i -eq ($chunks.Count - 1)) {
            $body.reply_markup = ($ReplyMarkup | ConvertTo-Json -Depth 10 -Compress)
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

function Send-TelegramPhoto {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Caption,
        [hashtable]$ReplyMarkup
    )
    $form = @{ chat_id = "$ChatId"; photo = Get-Item -Path $FilePath }
    if ($Caption) { $form.caption = $Caption }
    if ($ReplyMarkup) { $form.reply_markup = ($ReplyMarkup | ConvertTo-Json -Depth 10 -Compress) }
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
    param([Parameter(Mandatory)][string]$CallbackQueryId, [string]$Text)
    $body = @{ callback_query_id = $CallbackQueryId }
    if ($Text) { $body.text = $Text }
    # Routed through the shared request wrapper like every other send, so a
    # flood-limited acknowledgement honours retry_after instead of being
    # dropped and leaving the operator's button spinning.
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/answerCallbackQuery" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if (-not $request.Success) {
        Write-BridgeLog "Failed to answer callback query $CallbackQueryId : $($request.Error)" "ERROR"
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

