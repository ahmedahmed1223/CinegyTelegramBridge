#requires -Version 7

function Get-AirStatusWidgetHtml {
    # Telegram runs this document inside its Widget SDK, without external assets.
    # Only translations are embedded here. Scene names enter the DOM as text.
    $copy = [ordered]@{
        direction = if ((Get-BridgeLanguage) -eq 'ar') { 'rtl' } else { 'ltr' }
        title = T 'airwidget.title'
        refresh = T 'airwidget.refresh'
        waiting = T 'airwidget.waiting'
        denied = T 'airwidget.denied'
        failed = T 'airwidget.refreshFailed'
        expired = T 'airwidget.expired'
        unconfirmed = T 'airwidget.unconfirmed'
        empty = T 'airwidget.empty'
        more = T 'airwidget.more' '{0}'
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
  #layers p { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  #layers { margin: 10px 0; }
</style>
<section id="card">
  <h3 id="title"></h3>
  <p id="health"></p>
  <p id="checked" class="detail"></p>
  <p id="freshness"></p>
  <div id="layers"></div>
  <p id="more" class="detail"></p>
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
        const item = document.createElement('p');
        item.textContent = `${row.layer} · ${row.name}`;
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

function Get-AirStatusWidgetData {
    param([Parameter(Mandatory)][datetime]$ExpiresAt)
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
    foreach ($layer in ($script:OnAir.Keys | Sort-Object | Select-Object -First 5)) {
        $sceneName = ([string](Get-JsonProp $script:OnAir[$layer] 'Key') -replace '[\p{Cc}\u202A-\u202E\u2066-\u2069]', ' ').Trim()
        if ($sceneName.Length -gt 48) { $sceneName = $sceneName.Substring(0, (Get-SafeTextPrefixLength -Text $sceneName -MaximumCodeUnits 48)) + '…' }
        if (-not $sceneName) { $sceneName = '—' }
        $snapshot.rows += @{ layer = [int]$layer; name = $sceneName }
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
    $body = @{
        chat_id = $ChatId
        html = Get-AirStatusWidgetHtml
        chat_data = $data
        caption = (T 'airwidget.caption') + "`n" + (T 'airwidget.initialSnapshot' $lastRead)
        protect_content = $true
        allow_queries = $true
        reply_markup = ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $textStatusKeyboard
    }
    # One attempt for this optional view. Retrying a send after an ambiguous
    # timeout can create two cards, and the operator already has the text view.
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendWidget" -Method Post -Body $body `
        -TimeoutSec ([Math]::Min(3, (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1)))
    $response = Get-JsonProp $request 'Response'
    $messageId = [int](Get-JsonProp (Get-JsonProp $response 'result') 'message_id')
    if ($request.Success -and (Get-JsonProp $response 'ok') -and $messageId -gt 0) {
        $script:AirStatusWidgets[$ChatId] = @{ MessageId = $messageId; ExpiresAt = $expiresAt; LastData = $data; NextAt = $Now.AddSeconds(5) }
        return
    }

    $statusCode = [int](Get-JsonProp $request 'StatusCode')
    Write-BridgeLog "Air status widget sendWidget failed for chat $ChatId (HTTP $statusCode); sending text snapshot" 'WARN'
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
    $card = $script:AirStatusWidgets[$chatId]
    if ($card -and $card.ExpiresAt -gt $Now -and $card.MessageId -eq $messageId -and
        $chatId -eq $userId -and (Get-JsonProp $chat 'type') -ceq 'private' -and
        (Get-JsonProp (Get-JsonProp $Query 'type') 'type') -ceq 'data' -and
        (Get-JsonProp $Query 'data') -ceq 'refresh' -and
        (Test-Authorized -ChatId $chatId -UserId $userId) -and (Test-StatusViewer -ChatId $chatId -UserId $userId)) {
        $body.data = Get-AirStatusWidgetData -ExpiresAt $card.ExpiresAt
    }
    # An empty answer tells an expired or unauthorised card that it cannot refresh.
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/answerWidgetQuery" -Method Post -Body $body `
        -TimeoutSec ([Math]::Min(3, (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1)))
    if (-not $request.Success) { Write-BridgeLog "Air status widget answerWidgetQuery failed for chat $chatId" 'DEBUG' }
}

function Update-AirStatusWidgets {
    param([datetime]$Now = (Get-Date))
    if ($script:AirStatusWidgets.Count -eq 0 -and -not $script:AirStatusWidgetUpdate) { return }
    foreach ($chatId in @($script:AirStatusWidgets.Keys)) {
        if ($script:AirStatusWidgets[$chatId].ExpiresAt -le $Now -or
            -not (Test-Authorized -ChatId $chatId -UserId $chatId) -or
            -not (Test-StatusViewer -ChatId $chatId -UserId $chatId)) {
            $script:AirStatusWidgets.Remove($chatId)
        }
    }
    $update = $script:AirStatusWidgetUpdate
    if ($update) {
        $request = Receive-BridgeTelegramRequestWorker -Worker $update.Worker
        if (-not $request) { return }
        $script:AirStatusWidgetUpdate = $null
        $card = $script:AirStatusWidgets[$update.ChatId]
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
                $script:AirStatusWidgets.Remove($update.ChatId)
                Write-BridgeLog "Air status widget editMessageWidgetData stopped for chat $($update.ChatId) (HTTP $statusCode)" 'DEBUG'
            }
            else { $card.NextAt = $Now.AddSeconds(30) }
        }
    }
    if ($Now -lt $script:TelegramOutboxNotBefore) { return }

    # Keep one edit in flight. The polling thread can keep servicing the air
    # clock, and a retry re-reads the newest state rather than replaying an old one.
    $due = @($script:AirStatusWidgets.GetEnumerator() | Where-Object { $_.Value.NextAt -le $Now } |
        Sort-Object { $_.Value.NextAt })
    foreach ($entry in $due) {
        $card = $entry.Value
        $card.NextAt = $Now.AddSeconds(5)
        $data = Get-AirStatusWidgetData -ExpiresAt $card.ExpiresAt
        if ([string]::Equals($data, $card.LastData, [StringComparison]::Ordinal)) { continue }
        $worker = Start-BridgeTelegramRequestWorker -Request @{
            Uri = "$apiBase/editMessageWidgetData"
            Method = 'Post'
            TimeoutSec = Get-SettingInt 'TelegramRequestTimeoutSeconds' 1
            Body = @{ chat_id = $entry.Key; message_id = $card.MessageId; chat_data = $data }
        }
        $script:AirStatusWidgetUpdate = @{ Worker = $worker; ChatId = $entry.Key; MessageId = $card.MessageId; Data = $data }
        break
    }
}
