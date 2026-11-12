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
        kind = if ($ForMenu) { 'r:m' } else { 'r:c' }
        refresh = T 'airwidget.refresh'
        waiting = T 'airwidget.waiting'
        denied = if ($ForMenu) { T 'airwidget.menuActionExpired' } else { T 'airwidget.denied' }
        failed = if ($ForMenu) { T 'airwidget.menuRefreshFailed' } else { T 'airwidget.refreshFailed' }
        expired = T 'airwidget.expired'
        unconfirmed = T 'airwidget.unconfirmed'
        empty = T 'airwidget.empty'
        more = if ($ForMenu) { T 'airwidget.menuMore' '{0}' } else { T 'airwidget.more' '{0}' }
        checked = T 'airwidget.checked' '{0}'
        age = T 'airwidget.age' '{0}'
        onAirFor = T 'airwidget.onAirFor' '{0}'
        hidesIn = T 'airwidget.hidesIn' '{0}'
        healthy = T 'airwidget.healthy'
        unhealthy = T 'airwidget.unhealthy'
        unreachable = T 'airwidget.unreachable'
        unknown = T 'airwidget.unknown'
    }
    $html = @'
<style>
  h3, p { margin: 0 0 8px; }
  .detail { color: var(--tg-theme-hint-color); font-size: .9em; font-variant-numeric: tabular-nums; }
  #freshness { color: var(--tg-theme-destructive-text-color); }
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
  let live = [];

  function clock(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const two = (n) => String(n).padStart(2, '0');
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor(total % 3600 / 60);
    return (hours ? hours + ':' + two(minutes) : String(minutes)) + ':' + two(total % 60);
  }

  function put(node, text) {
    if (node.textContent !== text) node.textContent = text;
    node.hidden = !text;
  }

  // Runs every second from the device clock. The bridge sends instants, not
  // rendered durations, so a ticking counter costs no Telegram traffic.
  function tick() {
    const now = Date.now();
    const expired = state && now >= state.expires;
    const fresh = state && now < state.freshUntil && !expired;
    put(element('freshness'), expired ? copy.expired : (fresh ? '' : copy.unconfirmed));
    const age = state && state.lastAt ? ' · ' + format(copy.age, clock(now - state.lastAt)) : '';
    put(element('checked'), format(copy.checked, state && state.last ? state.last : '—') + age);
    if (state && !state.rows.length) fill('layers', fresh ? copy.empty : '');
    for (const [node, row] of live) {
      const parts = [];
      // A counter that keeps running over an unconfirmed reading would claim
      // more than the bridge knows.
      if (fresh && row.at) parts.push(format(copy.onAirFor, clock(now - row.at)));
      if (fresh && row.hide > now) parts.push(format(copy.hidesIn, clock(row.hide - now)));
      if (row.by) parts.push(row.by);
      put(node, parts.join(' · '));
    }
    element('refresh').disabled = pending || !widget;
    return !fresh;
  }

  function draw(data) {
    state = data ? JSON.parse(data) : null;
    fill('health', state ? (copy[state.health] || copy.unknown) : copy.unknown);
    const layers = element('layers');
    layers.textContent = '';
    live = [];
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
        const detail = document.createElement('p');
        detail.className = 'detail';
        scene.appendChild(name);
        scene.appendChild(detail);
        live.push([detail, row]);
        item.appendChild(number);
        item.appendChild(scene);
        layers.appendChild(item);
      }
    }
    fill('more', state && state.hidden ? format(copy.more, state.hidden) : '');
    element('more').hidden = !state || !state.hidden;
    tick();
  }

  function showFeedback(text) {
    fill('feedback', text);
    element('feedback').hidden = !text;
  }

  function buzz(type) {
    try { widget.HapticFeedback.notificationOccurred(type); } catch {}
  }

  // Telegram allows the private-chat original one request when it appears on
  // screen without a tap. A tap must reach widget.request synchronously, so
  // nothing before it in this function may await.
  async function ask(tapped) {
    if (pending || !widget) return;
    pending = true;
    tick();
    if (tapped) showFeedback(copy.waiting);
    try {
      const answer = await widget.request(copy.kind);
      if (answer.result) draw(answer.result);
      if (tapped) {
        showFeedback(answer.result ? '' : copy.denied);
        buzz(answer.result ? 'success' : 'error');
      }
    } catch {
      if (tapped) {
        showFeedback(copy.failed);
        buzz('error');
      }
    } finally {
      pending = false;
      tick();
    }
  }

  // Only a card that is showing something stale asks on its own; a card the
  // bridge is still pushing to already has the newest state.
  function wake() {
    if (tick()) ask(false);
  }

  element('card').dir = copy.direction;
  for (const id of ['intro', 'channel', 'actor']) {
    fill(id, copy[id]);
    element(id).hidden = !copy[id];
  }
  fill('title', copy.title);
  fill('refresh', copy.refresh);
  element('refresh').addEventListener('click', () => { ask(true); });
  if (widget) {
    // A pushed state is the newest word: a "refresh failed" left over from
    // an answer that never arrived would contradict the data under it.
    widget.onEvent('chatDataChanged', () => { draw(widget.chatData); if (!pending) showFeedback(''); });
    widget.onEvent('activated', wake);
  }
  draw(widget ? widget.chatData : null);
  if (widget) widget.ready();
  wake();
  setInterval(tick, 1000);
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

function ConvertTo-AirStatusWidgetEpoch {
    param($Moment)
    # Show and timer instants arrive as DateTime, DateTimeOffset, or the 'o'
    # string a restored state file left behind. Zero means "not known".
    $instant = [datetimeoffset]::MinValue
    try {
        if ($Moment -is [datetimeoffset]) { $instant = $Moment }
        elseif ($Moment -is [datetime]) { $instant = [datetimeoffset]$Moment }
        elseif (-not [datetimeoffset]::TryParse([string]$Moment, [ref]$instant)) { return 0 }
    }
    catch { return 0 }
    return [Math]::Max(0L, $instant.ToUnixTimeMilliseconds())
}

function Get-AirStatusWidgetData {
    param([Parameter(Mandatory)][datetime]$ExpiresAt, [switch]$ForMenu)
    $monitoring = $script:RuntimeState.Monitoring
    $snapshot = [ordered]@{
        expires = ([datetimeoffset]$ExpiresAt).ToUnixTimeMilliseconds()
        freshUntil = 0
        last = ''
        lastAt = 0
        health = [string]$monitoring.CinegyHealthState
        rows = @()
        hidden = $script:OnAir.Count
    }
    $lastRead = $monitoring.LastCinegyStateSuccess
    if ($lastRead -gt [datetime]::MinValue) {
        $snapshot.last = $lastRead.ToString('yyyy-MM-dd HH:mm:ss')
        $snapshot.lastAt = ConvertTo-AirStatusWidgetEpoch $lastRead
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
        # Instants rather than rendered text: the card counts from them every
        # second on the device, and the state stays byte-identical between
        # real changes, so no edit is spent on a clock.
        $startedAt = ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $record 'At')
        if ($startedAt -gt 0) { $row.at = $startedAt }
        $layerTimer = @($script:AutoHideQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq [int]$layer }) | Select-Object -First 1
        $hideAt = if ($layerTimer) { ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $layerTimer 'At') } else { 0 }
        if ($hideAt -gt 0) { $row.hide = $hideAt }
        if ($ForMenu) {
            $operator = switch ([string](Get-JsonProp $record 'Source')) {
                'cinegy' { T 'onair.external' }
                'BotTest' { T 'onair.templateTest' }
                default {
                    $actorId = [long](Get-JsonProp $record 'UserId')
                    if ($actorId -gt 0) { Get-UserDisplayName -UserId $actorId }
                }
            }
            if ($operator) { $row.by = Format-AirStatusWidgetField -Text $operator -MaximumLength 28 }
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

function Get-MainMenuWidgetStaleLayers {
    <#
        The layers whose menu buttons no longer name what is on air, plus the
        ones already greyed out: a disabled button never comes back to life,
        because the operator has to reopen the menu to see what it would do.
    #>
    param([Parameter(Mandatory)][hashtable]$Card, [Parameter(Mandatory)][datetime]$Now)
    $stale = @($Card.StaleLayers)
    foreach ($layer in @($Card.LayerFingerprints.Keys)) {
        $recorded = [string]$Card.LayerFingerprints[$layer]
        if ($layer -notin $stale -and
            (-not $recorded -or $Card.ExpiresAt -le $Now -or $recorded -cne (Get-LayerRemovalFingerprint -Layer $layer))) {
            $stale += [int]$layer
        }
    }
    return @($stale | Sort-Object)
}

function Get-MainMenuWidgetKeyboard {
    <#
        The menu's keyboard with the stale layers' buttons disabled in place.
        Same rows, same order, same labels: nothing moves under the thumb, and
        no button is ever pointed at a scene other than the one it named.
    #>
    param([Parameter(Mandatory)][hashtable]$Card, [AllowEmptyCollection()][int[]]$StaleLayers = @())
    $rows = @()
    foreach ($keyboardRow in $Card.Keyboard.inline_keyboard) {
        $row = @()
        foreach ($button in $keyboardRow) {
            if ((Get-JsonProp $button 'callback_data') -match '^(?:hide|timer):(\d+):menu$' -and [int]$Matches[1] -in $StaleLayers) {
                $button = New-BridgeButton -Text $button.text -Disabled
            }
            $row += $button
        }
        $rows += , $row
    }
    return @{ inline_keyboard = $rows }
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
            if ((Get-JsonProp $button 'callback_data') -match '^(hide|timer):(\d+)$') {
                $layerAction = $Matches[1]
                $layer = [int]$Matches[2]
                if (-not $fingerprints.ContainsKey($layer)) { $fingerprints[$layer] = Get-LayerRemovalFingerprint -Layer $layer }
                $button = $button.Clone()
                $button.callback_data += ':menu'
                # The panel above counts the timer down live; a number frozen
                # into the label at send time would contradict it within a second.
                if ($layerAction -eq 'timer' -and
                    @($script:AutoHideQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq $layer -and (ConvertTo-AirStatusWidgetEpoch (Get-JsonProp $_ 'At')) -gt ([datetimeoffset]$Now).ToUnixTimeMilliseconds() }).Count -gt 0) {
                    $button.text = T 'menu.timerExtendLive'
                }
            }
            $widgetRow += $button
        }
        $widgetRows += , $widgetRow
    }
    $card = @{ MessageId = 0; ExpiresAt = $expiresAt; LastData = $data; NextAt = $Now.AddSeconds(5); ForMenu = $true
        LayerFingerprints = $fingerprints; Keyboard = @{ inline_keyboard = $widgetRows }; StaleLayers = @() }
    # A layer with no fingerprint can never be confirmed, so its buttons would
    # be refused on every press. They are sent disabled instead.
    $card.StaleLayers = @(Get-MainMenuWidgetStaleLayers -Card $card -Now $Now)
    $html = Get-AirStatusWidgetHtml -ForMenu -Intro $Intro -UserId $UserId
    $messageId = Send-AirStatusWidgetMessage -ChatId $ChatId -Html $html -Data $data -Caption ($captionLines -join "`n") `
        -Keyboard (Get-MainMenuWidgetKeyboard -Card $card -StaleLayers $card.StaleLayers)
    if ($messageId -le 0) { return $false }
    $card.MessageId = $messageId
    $script:MainMenuWidgets[$ChatId] = $card
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
    $kind = [string](Get-JsonProp $Query 'data')
    $forMenu = $kind -ceq 'r:m'
    if ($chatId -gt 0 -and $chatId -eq $userId -and $messageId -gt 0 -and
        (Get-JsonProp $chat 'type') -ceq 'private' -and
        (Get-JsonProp (Get-JsonProp $Query 'type') 'type') -ceq 'data' -and
        ($forMenu -or $kind -ceq 'r:c') -and
        (Test-Authorized -ChatId $chatId -UserId $userId) -and ($forMenu -or (Test-StatusViewer -ChatId $chatId -UserId $userId))) {
        $registry = if ($forMenu) { $script:MainMenuWidgets } else { $script:AirStatusWidgets }
        $card = $registry[$chatId]
        # A card the bridge stopped tracking - expired, or forgotten by a
        # restart - comes back when its owner looks at it or taps refresh.
        # An older message never takes the slot from a newer card that is
        # still live: one card per chat keeps the edit traffic bounded.
        if (-not $card -or $card.MessageId -eq $messageId -or $card.ExpiresAt -le $Now) {
            $expiresAt = $Now.AddMinutes(30)
            if ($card -and $card.MessageId -eq $messageId) {
                $card.ExpiresAt = $expiresAt
                $card.NextAt = $Now
            }
            else {
                # No fingerprints: a revived menu's hide and timer buttons stay
                # refused, because nothing recorded what their labels named.
                $registry[$chatId] = @{ MessageId = $messageId; ExpiresAt = $expiresAt; LastData = ''
                    NextAt = $Now; ForMenu = $forMenu; LayerFingerprints = @{} }
            }
            $body.data = Get-AirStatusWidgetData -ExpiresAt $expiresAt -ForMenu:$forMenu
        }
    }
    # An empty answer tells an unauthorised or superseded card that it cannot refresh.
    #
    # Sent from a worker, not from here. This runs on the polling thread, and
    # a card now asks on its own whenever it appears on screen: a slow answer
    # must not hold the air clock. The longer timeout is affordable for the
    # same reason; Telegram accepts an answer for fifteen seconds.
    Receive-AirStatusWidgetAnswers -Now $Now
    # ponytail: four answers in flight. A fifth query goes unanswered and its
    # card reports a failed refresh; raise the cap if one chat ever needs more.
    if ($script:AirStatusWidgetAnswers.Count -ge 4) {
        Write-BridgeLog "Air status widget query from chat $chatId left unanswered: four answers are already in flight" 'WARN'
        return
    }
    $worker = Start-BridgeTelegramRequestWorker -Request @{
        Uri = "$apiBase/answerWidgetQuery"
        Method = 'Post'
        TimeoutSec = [Math]::Min(10, (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1))
        Body = $body
    }
    # The request text is the widget's own and untrusted: only a known value is
    # ever written to the log.
    $script:AirStatusWidgetAnswers.Add(@{
            Worker = $worker; ChatId = $chatId; StartedAt = $Now
            Kind = if ($kind -cin @('r:m', 'r:c', 'refresh')) { $kind } else { 'other' }
            DataBytes = if ($body.ContainsKey('data')) { [Text.Encoding]::UTF8.GetByteCount($body.data) } else { 0 }
        })
}

function Receive-AirStatusWidgetAnswers {
    <#
        Collects finished answers and says why one failed. Three failed in a
        row on the station with a log line that named neither the status nor
        Telegram's reason, so the cause could not be told from a timeout.
    #>
    param([datetime]$Now = (Get-Date))
    foreach ($answer in @($script:AirStatusWidgetAnswers)) {
        $request = Receive-BridgeTelegramRequestWorker -Worker $answer.Worker
        if (-not $request) { continue }
        $script:AirStatusWidgetAnswers.Remove($answer) | Out-Null
        if ($request.Success) { continue }
        $elapsed = [int]($Now - $answer.StartedAt).TotalMilliseconds
        Write-BridgeLog ("Air status widget answerWidgetQuery failed for chat $($answer.ChatId) " +
            "(HTTP $([int](Get-JsonProp $request 'StatusCode')), request '$($answer.Kind)', $($answer.DataBytes) data byte(s), " +
            "collected ${elapsed} ms after the query): $(Get-JsonProp $request 'Error')") 'WARN'
    }
}

function Update-AirStatusWidgets {
    param([datetime]$Now = (Get-Date))
    Receive-AirStatusWidgetAnswers -Now $Now
    if ($script:AirStatusWidgets.Count -eq 0 -and $script:MainMenuWidgets.Count -eq 0 -and -not $script:AirStatusWidgetUpdate) { return }
    foreach ($registry in @($script:AirStatusWidgets, $script:MainMenuWidgets)) {
        foreach ($chatId in @($registry.Keys)) {
            $card = $registry[$chatId]
            $expired = $card.ExpiresAt -le $Now
            # An expired menu is kept a few minutes longer, only to grey out
            # the layer buttons it would now refuse.
            $owesKeyboard = $expired -and $card.ContainsKey('Keyboard') -and $card.ExpiresAt.AddMinutes(5) -gt $Now -and
                @($card.LayerFingerprints.Keys).Count -gt @($card.StaleLayers).Count
            if (($expired -and -not $owesKeyboard) -or
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
                if ($update.ContainsKey('StaleLayers')) { $card.StaleLayers = $update.StaleLayers }
                else { $card.LastData = $update.Data }
            }
            elseif ($statusCode -eq 429) { $card.NextAt = $script:TelegramOutboxNotBefore }
            elseif ($statusCode -in @(400, 401, 403, 404)) {
                $registry.Remove($update.ChatId)
                Write-BridgeLog "Air status widget edit stopped for chat $($update.ChatId) (HTTP $statusCode)" 'DEBUG'
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
        $pendingUpdate = @{ ChatId = $entry.Key; MessageId = $card.MessageId; ForMenu = $card.ForMenu }
        $request = $null
        # The keyboard before the panel: a button that still looks pressable
        # over a scene it no longer names matters more than a late counter.
        if ($card.ContainsKey('Keyboard')) {
            $staleLayers = @(Get-MainMenuWidgetStaleLayers -Card $card -Now $Now)
            if ($staleLayers.Count -gt @($card.StaleLayers).Count) {
                $request = @{
                    Uri = "$apiBase/editMessageReplyMarkup"
                    Body = @{ chat_id = $entry.Key; message_id = $card.MessageId
                        reply_markup = ConvertTo-TelegramReplyMarkupJson -ReplyMarkup (Get-MainMenuWidgetKeyboard -Card $card -StaleLayers $staleLayers) }
                }
                $pendingUpdate.StaleLayers = $staleLayers
                $card.NextAt = $Now.AddSeconds(1)
            }
        }
        if (-not $request) {
            if ($card.ExpiresAt -le $Now) { continue }
            $data = Get-AirStatusWidgetData -ExpiresAt $card.ExpiresAt -ForMenu:$card.ForMenu
            if ([string]::Equals($data, $card.LastData, [StringComparison]::Ordinal)) { continue }
            $request = @{
                Uri = "$apiBase/editMessageWidgetData"
                Body = @{ chat_id = $entry.Key; message_id = $card.MessageId; chat_data = $data }
            }
            $pendingUpdate.Data = $data
        }
        $request.Method = 'Post'
        $request.TimeoutSec = Get-SettingInt 'TelegramRequestTimeoutSeconds' 1
        $pendingUpdate.Worker = Start-BridgeTelegramRequestWorker -Request $request
        $script:AirStatusWidgetUpdate = $pendingUpdate
        break
    }
}
