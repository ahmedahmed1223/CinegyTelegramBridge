#requires -Version 7

function Get-AirStatusWidgetHtml {
    param([switch]$ForMenu, [string]$Intro = '', [long]$UserId = 0)
    # Telegram runs this document inside its Widget SDK, without external assets.
    # Only translations are embedded here. Scene names enter the DOM as text.
    $copy = [ordered]@{
        direction = if ((Get-BridgeLanguage) -eq 'ar') { 'rtl' } else { 'ltr' }
        title = if ($ForMenu) { T 'airwidget.menuTitle' } else { T 'airwidget.title' }
        intro = Format-AirStatusWidgetField -Text (ConvertFrom-TelegramHtmlText $Intro) -MaximumLength 128
        channel = if ($ForMenu) { Format-AirStatusWidgetField -Text (T 'kb.engineChannel' $config.AirServerAddress $config.AirChannelNumber) -MaximumLength 112 } else { '' }
        actor = if ($ForMenu) { "👤 $(Format-AirStatusWidgetField -Text (Format-UserAuditActor -UserId $UserId) -MaximumLength 96)" } else { '' }
        refresh = T 'airwidget.refresh'
        waiting = T 'airwidget.waiting'
        denied = if ($ForMenu) { T 'airwidget.menuActionExpired' } else { T 'airwidget.denied' }
        failed = if ($ForMenu) { T 'airwidget.menuRefreshFailed' } else { T 'airwidget.refreshFailed' }
        expired = T 'airwidget.expired'
        unconfirmed = T 'airwidget.unconfirmed'
        empty = T 'airwidget.empty'
        more = if ($ForMenu) { T 'airwidget.menuMore' '{0}' } else { T 'airwidget.more' '{0}' }
        checked = T 'airwidget.checked' '{0}'
        healthy = T 'airwidget.healthy'
        unhealthy = T 'airwidget.unhealthy'
        unreachable = T 'airwidget.unreachable'
        unknown = T 'airwidget.unknown'
    }
    $html = @'
<style>
  h3, p { margin: 0 0 8px; }
  .detail { color: var(--tg-theme-hint-color); font-size: .9em; }
  .row { display: flex; align-items: flex-start; gap: 8px; border-top: 1px solid var(--tg-theme-section-separator-color); padding: 5px 0; }
  .number { color: var(--tg-theme-accent-text-color); font-weight: bold; min-width: 1.25em; }
  .scene { min-width: 0; }
  .scene p { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; margin: 0; }
  #layers { margin: 10px 0; }
</style>
<section id="card">
  <p id="intro" hidden></p>
  <h3 id="title"></h3>
  <p id="health"></p>
  <p id="checked" class="detail"></p>
  <p id="freshness"></p>
  <div id="layers"></div>
  <p id="more" class="detail"></p>
  <p id="channel" class="detail" hidden></p>
  <p id="actor" class="detail" hidden></p>
  <button id="refresh" type="button"></button>
  <p id="feedback" class="detail" hidden></p>
</section>
<script>
  const copy = WIDGET_COPY;
  const widget = window.TelegramWidget;
  const element = (id) => document.getElementById(id);
  const fill = (id, text) => { element(id).textContent = text; };
  const format = (text, value) => text.replace('{0}', () => String(value));
  let state = null;
  let pending = false;

  function showFreshness() {
    const now = Date.now();
    const expired = state && now >= state.expires;
    const fresh = state && now < state.freshUntil && !expired;
    const warning = expired ? copy.expired : (fresh ? '' : copy.unconfirmed);
    fill('freshness', warning);
    element('freshness').hidden = !warning;
    if (state && !state.rows.length) fill('layers', fresh ? copy.empty : '');
    element('refresh').disabled = pending || expired || !widget;
  }

  function draw(data) {
    state = data ? JSON.parse(data) : null;
    fill('health', state ? (copy[state.health] || copy.unknown) : copy.unknown);
    fill('checked', format(copy.checked, state && state.last ? state.last : '—'));
    const layers = element('layers');
    layers.textContent = '';
    if (state && state.rows.length) {
      for (const row of state.rows) {
        const item = document.createElement('div');
        item.className = 'row';
        const number = document.createElement('span');
        number.className = 'number';
        number.textContent = String(row.layer);
        const scene = document.createElement('div');
        scene.className = 'scene';
        const name = document.createElement('p');
        name.textContent = row.name;
        scene.appendChild(name);
        if (row.detail) {
          const detail = document.createElement('p');
          detail.className = 'detail';
          detail.textContent = row.detail;
          scene.appendChild(detail);
        }
        item.appendChild(number);
        item.appendChild(scene);
        layers.appendChild(item);
      }
    }
    fill('more', state && state.hidden ? format(copy.more, state.hidden) : '');
    element('more').hidden = !state || !state.hidden;
    showFreshness();
  }

  function showFeedback(text) {
    fill('feedback', text);
    element('feedback').hidden = !text;
  }

  element('card').dir = copy.direction;
  for (const id of ['intro', 'channel', 'actor']) {
    fill(id, copy[id]);
    element(id).hidden = !copy[id];
  }
  fill('title', copy.title);
  fill('refresh', copy.refresh);
  element('refresh').addEventListener('click', async () => {
    pending = true;
    showFreshness();
    showFeedback(copy.waiting);
    try {
      const answer = await widget.request('refresh');
      if (answer.result) draw(answer.result);
      showFeedback(answer.result ? '' : copy.denied);
    } catch {
      showFeedback(copy.failed);
    } finally {
      pending = false;
      showFreshness();
    }
  });
  if (widget) {
    widget.onEvent('chatDataChanged', () => draw(widget.chatData));
    widget.onEvent('activated', showFreshness);
  }
  draw(widget ? widget.chatData : null);
  if (widget) widget.ready();
  setInterval(showFreshness, 1000);
</script>
'@
    return $html.Replace('WIDGET_COPY', ($copy | ConvertTo-Json -Compress -EscapeHandling EscapeHtml))
}

function Format-AirStatusWidgetField {
    param([AllowEmptyString()][string]$Text, [int]$MaximumLength)
    $clean = ($Text -replace '[\p{Cc}\u202A-\u202E\u2066-\u2069]', ' ').Trim()
    if ($clean.Length -le $MaximumLength) { return $clean }
    return $clean.Substring(0, (Get-SafeTextPrefixLength -Text $clean -MaximumCodeUnits $MaximumLength)) + '…'
}

function Get-AirStatusWidgetData {
    param([Parameter(Mandatory)][datetime]$ExpiresAt, [switch]$ForMenu)
    $monitoring = $script:RuntimeState.Monitoring
    $snapshot = [ordered]@{
        expires = ([datetimeoffset]$ExpiresAt).ToUnixTimeMilliseconds()
        freshUntil = 0
        last = ''
        health = [string]$monitoring.CinegyHealthState
        rows = @()
        hidden = $script:OnAir.Count
    }
    $lastRead = $monitoring.LastCinegyStateSuccess
    if ($lastRead -gt [datetime]::MinValue) {
        $snapshot.last = $lastRead.ToString('yyyy-MM-dd HH:mm:ss')
        if ($monitoring.LastCinegyStateFailedCount -eq 0) {
            $staleAfter = Get-SettingInt 'CinegyStateStaleSeconds' 45
            $snapshot.freshUntil = ([datetimeoffset]$lastRead.AddSeconds($staleAfter)).ToUnixTimeMilliseconds()
        }
    }
    $maximumRows = if ($ForMenu) { 4 } else { 5 }
    foreach ($layer in ($script:OnAir.Keys | Sort-Object | Select-Object -First $maximumRows)) {
        $record = $script:OnAir[$layer]
        $sceneName = Format-AirStatusWidgetField -Text ([string](Get-JsonProp $record 'Key')) -MaximumLength 48
        if (-not $sceneName) { $sceneName = '—' }
        $row = @{ layer = [int]$layer; name = $sceneName }
        if ($ForMenu) {
            $started = Get-JsonProp $record 'At'
            $operator = switch ([string](Get-JsonProp $record 'Source')) {
                'cinegy' { T 'onair.external' }
                'BotTest' { T 'onair.templateTest' }
                default {
                    $actorId = [long](Get-JsonProp $record 'UserId')
                    if ($actorId -gt 0) { Get-UserDisplayName -UserId $actorId }
                }
            }
            $details = @()
            if ($started -is [datetime]) {
                if ($started.Kind -eq [DateTimeKind]::Utc) { $started = $started.ToLocalTime() }
                $details += (T 'airwidget.menuSince' $started.ToString('HH:mm'))
            }
            if ($operator) { $details += (Format-AirStatusWidgetField -Text $operator -MaximumLength 28) }
            if ($details.Count -gt 0) { $row.detail = $details -join ' · ' }
        }
        $snapshot.rows += $row
        $snapshot.hidden--
    }
    $json = $snapshot | ConvertTo-Json -Compress
    # Telegram measures the encoded UTF-8 state, including JSON escaping.
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt 1024 -and $snapshot.rows.Count -gt 0) {
        $snapshot.rows = @($snapshot.rows | Select-Object -First ($snapshot.rows.Count - 1))
        $snapshot.hidden++
        $json = $snapshot | ConvertTo-Json -Compress
    }
    return $json
}

function Send-AirStatusWidgetMessage {
    param([long]$ChatId, [string]$Html, [string]$Data, [string]$Caption, [hashtable]$Keyboard)
    if ($script:AirStatusWidgetUnavailable) { return 0 }
    $body = @{
        chat_id = $ChatId
        html = $Html
        chat_data = $Data
        caption = $Caption
        protect_content = $true
        allow_queries = $true
        reply_markup = ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $Keyboard
    }
    # A retry after an ambiguous timeout could create two menus.
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendWidget" -Method Post -Body $body `
        -TimeoutSec ([Math]::Min(3, (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1)))
    $response = Get-JsonProp $request 'Response'
    $messageId = [int](Get-JsonProp (Get-JsonProp $response 'result') 'message_id')
    if ($request.Success -and (Get-JsonProp $response 'ok') -and $messageId -gt 0) { return $messageId }

    $statusCode = [int](Get-JsonProp $request 'StatusCode')
    if ($statusCode -eq 404 -and (Get-JsonProp $request 'Error') -match 'not found') { $script:AirStatusWidgetUnavailable = $true }
    Write-BridgeLog "Air status widget sendWidget failed for chat $ChatId (HTTP $statusCode); using the existing screen" 'WARN'
    return 0
}

function Send-MainMenuWidget {
    param([long]$ChatId, [long]$UserId, [string]$Intro = '', [hashtable]$Keyboard, [datetime]$Now = (Get-Date))
    if ($script:AirStatusWidgetUnavailable -or $Now -lt $script:TelegramOutboxNotBefore -or $ChatId -le 0 -or $ChatId -ne $UserId -or
        -not (Test-Authorized -ChatId $ChatId -UserId $UserId)) { return $false }

    $expiresAt = $Now.AddMinutes(30)
    $data = Get-AirStatusWidgetData -ExpiresAt $expiresAt -ForMenu
    $snapshot = ConvertFrom-Json -InputObject $data
    # Clients without widgets read the caption. Keep it short so clients that
    # render the panel do not also show a second copy of every layer row.
    $captionLines = @((T 'airwidget.menuCaption'))
    if ($snapshot.freshUntil -le ([datetimeoffset]$Now).ToUnixTimeMilliseconds()) { $captionLines += (T 'airwidget.unconfirmed') }
    elseif ($snapshot.rows.Count -eq 0) { $captionLines += (T 'airwidget.empty') }
    if ($snapshot.rows.Count -gt 0) {
        $firstLayer = $snapshot.rows[0]
        $captionLines += "$($firstLayer.layer) · $($firstLayer.name)"
        $otherLayers = $snapshot.rows.Count - 1 + $snapshot.hidden
        if ($otherLayers -gt 0) { $captionLines += (T 'airwidget.menuMore' $otherLayers) }
    }
    if (-not [string]::IsNullOrWhiteSpace($Intro)) {
        $captionLines = @((Format-AirStatusWidgetField -Text (ConvertFrom-TelegramHtmlText $Intro) -MaximumLength 128)) + $captionLines
    }
    # The live panel and the keyboard have separate Telegram lifetimes. Pin
    # layer actions to what their labels actually named when the menu opened.
    $fingerprints = @{}
    $widgetRows = @()
    foreach ($keyboardRow in $Keyboard.inline_keyboard) {
        $widgetRow = @()
        foreach ($button in $keyboardRow) {
            if ((Get-JsonProp $button 'callback_data') -match '^(?:hide|timer):(\d+)$') {
                $layer = [int]$Matches[1]
                if (-not $fingerprints.ContainsKey($layer)) { $fingerprints[$layer] = Get-LayerRemovalFingerprint -Layer $layer }
                $button = $button.Clone()
                $button.callback_data += ':menu'
            }
            $widgetRow += $button
        }
        $widgetRows += , $widgetRow
    }
    $html = Get-AirStatusWidgetHtml -ForMenu -Intro $Intro -UserId $UserId
    $messageId = Send-AirStatusWidgetMessage -ChatId $ChatId -Html $html -Data $data -Caption ($captionLines -join "`n") -Keyboard @{ inline_keyboard = $widgetRows }
    if ($messageId -le 0) { return $false }
    $script:MainMenuWidgets[$ChatId] = @{ MessageId = $messageId; ExpiresAt = $expiresAt; LastData = $data
        NextAt = $Now.AddSeconds(5); ForMenu = $true; LayerFingerprints = $fingerprints }
    $script:LastTelegramMessageId = $messageId
    if ($script:RefreshTarget -and $script:RefreshTarget.ChatId -eq $ChatId) { Clear-RefreshTarget }
    return $true
}

function Show-AirStatusWidget {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [datetime]$Now = (Get-Date))
    if ($ChatId -le 0 -or $ChatId -ne $UserId -or
        -not (Test-Authorized -ChatId $ChatId -UserId $UserId) -or
        -not (Test-StatusViewer -ChatId $ChatId -UserId $UserId)) { return }

    $expiresAt = $Now.AddMinutes(30)
    $data = Get-AirStatusWidgetData -ExpiresAt $expiresAt
    $snapshot = ConvertFrom-Json -InputObject $data
    $lastRead = if ($snapshot.last) { $snapshot.last } else { '—' }
    $lines = @((T "airwidget.$($snapshot.health)"), (T 'airwidget.checked' $lastRead))
    if ($snapshot.freshUntil -le ([datetimeoffset]$Now).ToUnixTimeMilliseconds()) { $lines += (T 'airwidget.unconfirmed') }
    elseif ($snapshot.rows.Count -eq 0) { $lines += (T 'airwidget.empty') }
    foreach ($row in $snapshot.rows) { $lines += "$($row.layer) · $($row.name)" }
    if ($snapshot.hidden -gt 0) { $lines += (T 'airwidget.more' $snapshot.hidden) }
    $textSnapshot = $lines -join "`n"
    $textStatusKeyboard = @{ inline_keyboard = @(, @((New-Button (T 'airwidget.textStatus') 'menu:fullstatus'))) }
    $caption = (T 'airwidget.caption') + "`n" + (T 'airwidget.initialSnapshot' $lastRead)
    $messageId = Send-AirStatusWidgetMessage -ChatId $ChatId -Html (Get-AirStatusWidgetHtml) -Data $data -Caption $caption -Keyboard $textStatusKeyboard
    if ($messageId -gt 0) {
        $script:AirStatusWidgets[$ChatId] = @{ MessageId = $messageId; ExpiresAt = $expiresAt; LastData = $data; NextAt = $Now.AddSeconds(5); ForMenu = $false }
        return
    }

    Send-TelegramMessage -ChatId $ChatId -Text ((T 'airwidget.textFallback') + "`n" + $textSnapshot) -ReplyMarkup $textStatusKeyboard
}

function Invoke-AirStatusWidgetQuery {
    param([Parameter(Mandatory)]$Query, [datetime]$Now = (Get-Date))
    $queryId = [string](Get-JsonProp $Query 'id')
    if (-not $queryId) { return }
    $body = @{ widget_query_id = $queryId }
    $chat = Get-JsonProp $Query 'chat'
    $chatId = [long](Get-JsonProp $chat 'id')
    $userId = [long](Get-JsonProp (Get-JsonProp $Query 'from') 'id')
    $messageId = [int](Get-JsonProp $Query 'message_id')
    $card = $script:MainMenuWidgets[$chatId]
    if (-not $card -or $card.MessageId -ne $messageId) { $card = $script:AirStatusWidgets[$chatId] }
    if ($card -and $card.ExpiresAt -gt $Now -and $card.MessageId -eq $messageId -and
        $chatId -eq $userId -and (Get-JsonProp $chat 'type') -ceq 'private' -and
        (Get-JsonProp (Get-JsonProp $Query 'type') 'type') -ceq 'data' -and
        (Get-JsonProp $Query 'data') -ceq 'refresh' -and
        (Test-Authorized -ChatId $chatId -UserId $userId) -and ($card.ForMenu -or (Test-StatusViewer -ChatId $chatId -UserId $userId))) {
        $body.data = Get-AirStatusWidgetData -ExpiresAt $card.ExpiresAt -ForMenu:$card.ForMenu
    }
    # An empty answer tells an expired or unauthorised card that it cannot refresh.
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/answerWidgetQuery" -Method Post -Body $body `
        -TimeoutSec ([Math]::Min(3, (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1)))
    if (-not $request.Success) { Write-BridgeLog "Air status widget answerWidgetQuery failed for chat $chatId" 'DEBUG' }
}

function Update-AirStatusWidgets {
    param([datetime]$Now = (Get-Date))
    if ($script:AirStatusWidgets.Count -eq 0 -and $script:MainMenuWidgets.Count -eq 0 -and -not $script:AirStatusWidgetUpdate) { return }
    foreach ($registry in @($script:AirStatusWidgets, $script:MainMenuWidgets)) {
        foreach ($chatId in @($registry.Keys)) {
            $card = $registry[$chatId]
            if ($card.ExpiresAt -le $Now -or
                -not (Test-Authorized -ChatId $chatId -UserId $chatId) -or
                (-not $card.ForMenu -and -not (Test-StatusViewer -ChatId $chatId -UserId $chatId))) {
                $registry.Remove($chatId)
            }
        }
    }
    $update = $script:AirStatusWidgetUpdate
    if ($update) {
        $request = Receive-BridgeTelegramRequestWorker -Worker $update.Worker
        if (-not $request) { return }
        $script:AirStatusWidgetUpdate = $null
        $registry = if ($update.ForMenu) { $script:MainMenuWidgets } else { $script:AirStatusWidgets }
        $card = $registry[$update.ChatId]
        $statusCode = [int](Get-JsonProp $request 'StatusCode')
        if ($statusCode -eq 429) {
            $retryAt = $Now.AddMilliseconds([Math]::Max(1000, [int](Get-JsonProp $request 'RetryAfterMs')))
            if ($script:TelegramOutboxNotBefore -lt $retryAt) { $script:TelegramOutboxNotBefore = $retryAt }
        }
        # A send can replace the card while an older edit is in flight.
        if ($card -and $card.MessageId -eq $update.MessageId) {
            if (($request.Success -and (Get-JsonProp (Get-JsonProp $request 'Response') 'ok')) -or
                ((Get-JsonProp $request 'Error') -match 'message is not modified|MESSAGE_NOT_MODIFIED')) {
                $card.LastData = $update.Data
            }
            elseif ($statusCode -eq 429) { $card.NextAt = $script:TelegramOutboxNotBefore }
            elseif ($statusCode -in @(400, 401, 403, 404)) {
                $registry.Remove($update.ChatId)
                Write-BridgeLog "Air status widget editMessageWidgetData stopped for chat $($update.ChatId) (HTTP $statusCode)" 'DEBUG'
            }
            else { $card.NextAt = $Now.AddSeconds(30) }
        }
    }
    if ($Now -lt $script:TelegramOutboxNotBefore) { return }

    # Keep one edit in flight. The polling thread can keep servicing the air
    # clock, and a retry re-reads the newest state rather than replaying an old one.
    $entries = @($script:AirStatusWidgets.GetEnumerator()) + @($script:MainMenuWidgets.GetEnumerator())
    $due = @($entries | Where-Object { $_.Value.NextAt -le $Now } |
        Sort-Object { $_.Value.NextAt })
    foreach ($entry in $due) {
        $card = $entry.Value
        $card.NextAt = $Now.AddSeconds(5)
        $data = Get-AirStatusWidgetData -ExpiresAt $card.ExpiresAt -ForMenu:$card.ForMenu
        if ([string]::Equals($data, $card.LastData, [StringComparison]::Ordinal)) { continue }
        $worker = Start-BridgeTelegramRequestWorker -Request @{
            Uri = "$apiBase/editMessageWidgetData"
            Method = 'Post'
            TimeoutSec = Get-SettingInt 'TelegramRequestTimeoutSeconds' 1
            Body = @{ chat_id = $entry.Key; message_id = $card.MessageId; chat_data = $data }
        }
        $script:AirStatusWidgetUpdate = @{ Worker = $worker; ChatId = $entry.Key; MessageId = $card.MessageId; Data = $data; ForMenu = $card.ForMenu }
        break
    }
}
