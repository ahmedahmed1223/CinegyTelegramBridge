#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function ConvertTo-OneHandLayout {
    <#
        Splits every row into single, full-width buttons.

        An operator holding the phone in one hand, thumb only, cannot reliably
        hit one of three buttons sharing a row - and the row that matters most
        is the live-layer row, pressed under time pressure. Applied as a final
        pass over a finished keyboard so no individual screen has to know
        about it.
    #>
    param([Parameter(Mandatory)][hashtable]$Keyboard)
    if (-not (Get-Setting 'OneHandMode')) { return $Keyboard }
    # A grid is not a stack of rows that happen to share a line. In a calendar
    # the row a date sits on is how the eye finds it, and an hour picker read
    # as twenty-seven stacked buttons is not a picker at all - moving this pass
    # to send time turned October into forty-six rows. Those screens say so for
    # themselves; every other keyboard is still split.
    if ($Keyboard.ContainsKey('KeepRows') -and $Keyboard.KeepRows) { return $Keyboard }
    $rows = @()
    foreach ($row in @($Keyboard.inline_keyboard)) {
        foreach ($button in @($row)) { $rows += , @($button) }
    }
    return @{ inline_keyboard = $rows }
}

function New-Button {
    <#
        -Style is Bot API 9.4's button colour. Where it is used is a policy,
        not a taste, because a screen where everything is coloured says
        nothing:

          danger  - the press takes something off air, destroys typed work,
                    or overwrites live state: hide, exit scene, delete,
                    clear, revoke, restore, restart, and the affirming half
                    of any confirmation of those.
          success - the press commits what the operator just authored: send
                    on air, save, apply, confirm an import or a schedule.
          (none)  - navigation, cancel, and every menu entry that only opens
                    the screen where the act actually happens.

        A cancel stays uncoloured on purpose: colouring both halves of a
        confirmation leaves the thumb with no signal at all.

        The setting that turns colours off is honoured at send time, in
        ConvertTo-TelegramReplyMarkupJson, not here.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Data,
        # An https page Telegram opens inside itself. When given, it
        # replaces the callback data rather than joining it.
        [AllowEmptyString()][string]$WebAppUrl = '',
        [int]$MaxTextLength = -1,
        [ValidateSet('', 'danger', 'success', 'primary')][string]$Style = ''
    )
    $maxLength = if ($MaxTextLength -ge 0) { $MaxTextLength } else { Get-SettingInt 'ButtonTextMaxLength' }
    $displayText = $Text
    if ($maxLength -gt 1 -and (Get-TextElementCount -Text $Text) -gt $maxLength) {
        $info = [Globalization.StringInfo]::new($Text)
        $displayText = $info.SubstringByTextElements(0, $maxLength - 1).TrimEnd() + '…'
    }
    # A Mini App button carries a URL instead of callback data: Telegram
    # opens the page inside itself and sends the bot nothing, so there is
    # no callback to answer and the two are mutually exclusive.
    $button = if ($WebAppUrl) { @{ text = $displayText; web_app = @{ url = $WebAppUrl } } }
    else { @{ text = $displayText; callback_data = $Data } }
    if ($Style) { $button.style = $Style }
    return $button
}

function Get-MainMenuKeyboard {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $rows = @()

    # What is on air comes FIRST, before anything that puts more on air.
    # This menu is what an operator opens when a wrong graphic is live, and
    # every row above the fix is a row they must scroll past to reach it.
    if ($script:OnAir.Count -gt 0) {
        foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
            $liveRow = @()
            # Per-layer status: show if template is on air with AirCopy preview
            $onAirKey = $script:OnAir[$layer].Key
            $onAirCopy = [string](Get-JsonProp $script:OnAir[$layer] 'AirCopy')
            $hideLabel = if (-not [string]::IsNullOrWhiteSpace($onAirCopy)) {
                T 'menu.hideLive.copy' $layer $onAirKey $onAirCopy
            } else {
                T 'menu.hideLive' $layer $onAirKey
            }
            $liveRow += (New-Button $hideLabel "hide:$layer" -Style danger)
            # Quick +30s extension button for live layers
            if (Get-Setting 'EnableTimedShow') {
                $pending = @($script:AutoHideQueue | Where-Object { [int]$_.Layer -eq [int]$layer })
                $timerLabel = if ($pending.Count -gt 0) {
                    $remaining = [int](($pending[0].At - (Get-Date)).TotalSeconds)
                    T 'menu.timerExtend' $remaining
                } else {
                    T 'menu.timer'
                }
                $liveRow += (New-Button $timerLabel "timer:$layer")
            }
            $rows += , $liveRow
        }
        # A frame from the actual output, next to what the bridge believes is
        # on air - so the operator can check the claim without leaving the chat.
        $onAirTools = @()
        if ($script:LastShow.ContainsKey($ChatId)) {
            $lastKey = [string](Get-JsonProp $script:LastShow[$ChatId] 'Key')
            $onAirTools += (New-Button (T 'menu.reshow' $lastKey) "menu:repeat")
        }
        if (Get-Setting 'EnableHideAll') { $onAirTools += (New-Button (T 'menu.hideAll') "menu:hideall" -Style danger) }
        if (Get-Setting 'EnableSnapshot') { $onAirTools += (New-Button (T 'menu.snapshotNow') "menu:snapshot") }
        $onAirTools += (New-Button (T 'menu.copyStatus') "menu:sharestatus")
        $rows += , $onAirTools
    }

    # A bulletin does not come off with the plain hide above it: that would cut
    # the scene and leave the run walking a table nobody can see. Its own
    # button stops the run and leaves by EXIT, so the outro plays.
    #
    # Only while a bulletin is actually up. It used to sit here permanently,
    # greyed when there was nothing to take off, so its place could be learned
    # - but a button offering to hide something when nothing is on air reads as
    # a claim that something is, which is the confusion it was meant to end.
    if ((Test-MojazAvailable) -and (Test-MojazOnAirLayer)) {
        $rows += , @( (New-Button (T 'menu.hideMojaz') "mojaz:hide" -Style danger) )
    }

    # Same reasoning for a breaking-news board that is walking its table: the
    # plain hide above would cut the scene and leave the run writing lines into
    # something nobody can see. Only while a run is actually up.
    if ($script:UrgentBoardRun) {
        $rows += , @( (New-Button (T 'menu.stopUrgent') "urgentb:stop" -Style danger) )
    }

    # A rollback used to be reachable only from the message that offered it,
    # so navigating away lost it for the rest of its window. The fastest human
    # error is pressing the wrong template; undo has to survive a tap on the
    # wrong thing afterwards.
    foreach ($layer in ($script:RollbackCandidates.Keys | Sort-Object)) {
        $candidate = Get-RollbackCandidate -Layer ([int]$layer) -UserId $UserId
        if (-not $candidate) { continue }
        $secondsLeft = [int](([datetime]$candidate.ExpiresAt) - (Get-Date)).TotalSeconds
        if ($secondsLeft -le 0) { continue }
        $rows += , @( (New-Button (T 'menu.rollback' $layer $secondsLeft) "rollback:$layer") )
    }

    $templateRow = @( (New-Button (T 'menu.templates') "menu:templates") )
    # Layers are the raw controls - hide, exit, push to a bare layer number -
    # and a newsroom may want them kept to whoever owns the rundown.
    if (Test-LayersScreenAccess -ChatId $ChatId -UserId $UserId) {
        $layerStatus = if ($script:OnAir.Count -gt 0) { '🔴' } else { '🟢' }
        $templateRow += (New-Button (T 'menu.layers' $layerStatus) "menu:layers")
    }
    $rows += , $templateRow
    # Paired rather than stacked, and paired by meaning rather than to save
    # space: these two answer the same question at two depths. Sixteen rows
    # for an administrator is a wall on a phone, and every row above the live
    # controls is a row to scroll past while a wrong graphic is on air.
    # OneHandMode splits every pair back apart for a thumb, as before.
    $statusRow = @( (New-Button (T 'menu.status') "menu:status") )
    if (Test-StatusViewer -ChatId $ChatId -UserId $UserId) {
        $statusRow += (New-Button (T 'menu.fullStatus') "menu:fullstatus")
    }
    $rows += , $statusRow

    # The channel's own material and the shift change, both optional because a
    # station that does neither should not carry the buttons.
    $shiftRow = @()
    if (Get-Setting 'EnableMaterialSchedule') { $shiftRow += (New-Button (T 'menu.material') 'menu:material') }
    if (Get-Setting 'EnableShiftHandover') { $shiftRow += (New-Button (T 'menu.handover') 'menu:handover') }
    if ($shiftRow.Count -gt 0) { $rows += , $shiftRow }

    if (Get-Setting 'EnableFavorites') {
        # @() is mandatory, not decoration: a PowerShell function that returns
        # an empty array emits ZERO objects, so an unwrapped assignment yields
        # $null and $null.Count throws under Set-StrictMode. Same rule applies
        # to every array-returning helper called below.
        $favs = @(Get-FavoriteTemplateKeys -UserId $UserId)
        if ($favs.Count -gt 0) {
            $favRow = @()
            foreach ($key in $favs) {
                $idx = Get-TemplateIndex -Key $key
                if ($idx -ge 0) { $favRow += (New-Button (T 'menu.favourite' $key) "tpl:$idx") }
            }
            if ($favRow.Count -gt 0) { $rows += , $favRow }
        }
        $rows += , @( (New-Button (T 'menu.favourites') "menu:favorites") )
    }

    $rows += , @( (New-Button (T 'menu.hideLayer') "menu:hide"), (New-Button (T 'menu.exitScene') "menu:exit") )

    # Live layers and the emergency hide are rendered at the top of this
    # keyboard instead of here; see the on-air block above.
    $thirdRow = @()
    if ((Get-Setting 'EnableHideAll') -and $script:OnAir.Count -eq 0) {
        $thirdRow += (New-Button (T 'menu.hideAll') "menu:hideall" -Style danger)
    }
    if ($script:OnAir.Count -eq 0 -and $script:LastShow.ContainsKey($ChatId)) {
        $thirdRow += (New-Button (T 'menu.repeatEdit') "menu:repeat")
    }
    if ($thirdRow.Count -gt 0) { $rows += , $thirdRow }

    $fourthRow = @( (New-Button (T 'menu.updateText') "menu:update") )
    if (Get-Setting 'EnableTimedShow') { $fourthRow += (New-Button (T 'menu.timedShow') "menu:timed") }
    $rows += , $fourthRow
    $rows += , @( (New-Button (T 'menu.schedule') 'menu:schedule'), (New-Button (T 'menu.reports') 'menu:reports') )
    $rows += , @( (New-Button (T 'menu.myOps') 'menu:myops'), (New-Button (T 'menu.digest') 'menu:digest') )
    # Each management button on its own row: one tap, no crowding.
    # Order: News Ticker first (daily driver), then Mojaz (bulletin), then Urgent (breaking news).
    if (Get-Setting 'EnableNewsTickerManagement') { $rows += , @( (New-Button (T 'menu.news') 'menu:news') ) }
    if (Test-MojazAvailable) { $rows += , @( (New-Button (T 'menu.mojaz') 'menu:mojaz') ) }
    if (Test-UrgentBoardAvailable) { $rows += , @( (New-Button (T 'menu.urgent') 'urgentb:open') ) }
    # One door however many programmes there are. A button per board would
    # grow this menu without a bound, and the menu is already sixteen rows.
    if (Test-BoardsAvailable) { $rows += , @( (New-Button (T 'menu.boards') 'boards:open') ) }

    # 📡 beside 📸: both answer "what is actually going out", and the watch
    # is where that answer keeps its history. It moved here from the
    # administration tools, where an operator watching a feed that keeps
    # dropping had to go through a door meant for configuration.
    #
    # No row is added in the common case: help and what's-new pair up.
    if (Get-Setting 'EnableSnapshot') {
        $rows += , @( (New-Button (T 'menu.snapshot') "menu:snapshot"), (New-Button (T 'feed.watch') 'menu:feedwatch') )
    }
    else {
        $rows += , @( (New-Button (T 'feed.watch') 'menu:feedwatch') )
    }
    $rows += , @( (New-Button (T 'menu.help') "menu:help"), (New-Button (T 'menu.whatsNew') "menu:whatsnew") )

    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
        $pendingCount = $script:PendingApprovals.Count
        $pendingLabel = if ($pendingCount -gt 0) { T 'menu.pending.count' $pendingCount } else { T 'menu.pending' }
        # Settings and access requests stay one tap away because they are used
        # during a shift. The rest is configuration an operator opens rarely,
        # and five permanent rows of it pushed the live controls off screen.
        $rows += , @( (New-Button (T 'menu.settings') "menu:settings"), (New-Button $pendingLabel "menu:pending") )
        $rows += , @( (New-Button (T 'menu.adminTools') "menu:admintools") )
    }
    return @{ inline_keyboard = $rows }
}

function Get-RoleMainKeyboard {
    <# Stable Version 6 entry point; authorization remains in the compatible
       menu builder so existing role and owner rules stay authoritative. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
}

function Get-BridgeNavigationContext {
    param([int]$Page = 0, [string]$Filter = '', [string]$ReturnCallback = 'menu')
    return [pscustomobject]@{ Page = [math]::Max(0, $Page); Filter = $Filter; ReturnCallback = $ReturnCallback }
}

function Get-BridgeReadinessSummary {
    <# Summarizes an already captured snapshot. This function intentionally
       performs no Telegram, Cinegy, disk, or relay probe. #>
    param([Parameter(Mandatory)]$Snapshot)
    $telegram = if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains('Telegram')) { [string]$Snapshot['Telegram'] } elseif ($Snapshot.PSObject.Properties['Telegram']) { [string]$Snapshot.Telegram } else { 'unknown' }
    $cinegy = if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains('Cinegy')) { [string]$Snapshot['Cinegy'] } elseif ($Snapshot.PSObject.Properties['Cinegy']) { [string]$Snapshot.Cinegy } else { 'unknown' }
    $diskFree = if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains('DiskFreeGB')) { [double]$Snapshot['DiskFreeGB'] } elseif ($Snapshot.PSObject.Properties['DiskFreeGB']) { [double]$Snapshot.DiskFreeGB } else { 0 }
    $lastError = if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains('LastError')) { [string]$Snapshot['LastError'] } elseif ($Snapshot.PSObject.Properties['LastError']) { [string]$Snapshot.LastError } else { '' }
    $ready = $telegram -eq 'connected' -and $cinegy -eq 'healthy' -and $diskFree -gt 1 -and [string]::IsNullOrWhiteSpace($lastError)
    $label = if ($ready) { (T 'kb.readyToRun') } else { (T 'kb.needsReview') }
    return [pscustomobject]@{ Ready = $ready; Text = (T 'kb.readinessLine' $label $telegram $cinegy $diskFree) }
}

function Get-MainMenuIntroBlocks {
    <#
        The menu screen as a table, one row per live layer.

        It is the screen an operator opens most and the last one with no rich
        version, so it stayed unlike the rest however its text was arranged.
        What is on air is rows of columns - layer, template, how long, whose -
        which is a table by nature; in text those four facts have to be run
        together across two lines each.

        The verdict is the heading, because it is the one thing that has to
        land before anything is read.

        Every layer gets a row. The text version caps at four because each
        costs it two lines; a table is read down its columns, so a cap would
        only hide a live graphic for no gain.
    #>
    param([long]$UserId = 0)
    $freshness = Get-CinegyStateFreshness `
        -LastSuccessfulAt $(if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }) `
        -StaleAfterSeconds ([math]::Max(1, (Get-SettingInt 'CinegyStateCheckSeconds' 1) * 3))
    $age = switch ($freshness.State) {
        'connected' { (T 'kb.checkedAgo' $($freshness.AgeSeconds)) }
        'stale' { (T 'kb.lastCheckAgo' $($freshness.AgeSeconds)) }
        'unavailable' { (T 'onair.checkFailed') }
        default { (T 'onair.notChecked') }
    }
    $verdict = if ($freshness.State -ne 'connected') { (T 'onair.unconfirmed') }
    elseif ($script:OnAir.Count -gt 0) { (T 'onair.layersUp') }
    else { (T 'onair.allWell') }

    $blocks = @(@{ type = 'heading'; text = $verdict; size = 3 })

    if ($script:OnAir.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = (T 'onair.none') }
    }
    else {
        $cells = @(, @(
                @{ text = (T 'kb.col.layer'); is_header = $true }
                @{ text = (T 'kb.col.template'); is_header = $true }
                @{ text = (T 'kb.col.since'); is_header = $true }
                @{ text = (T 'kb.col.operator'); is_header = $true }
            ))
        foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
            $record = $script:OnAir[$layer]
            # Guarded: these records are written at a dozen call sites and
            # carry only what each one cares about, so under StrictMode an
            # absent key would take down the screen an operator opens when
            # something has already gone wrong.
            $since = if ($record.ContainsKey('At') -and $record.At -is [datetime]) {
                Format-Duration -Seconds ([int]((Get-Date) - $record.At).TotalSeconds)
            }
            else { '—' }
            $source = if ($record.ContainsKey('Source')) { [string]$record.Source } else { 'bridge' }
            $who = switch ($source) {
                'cinegy' { 'Cinegy' }
                'BotTest' { (T 'kb.test') }
                default {
                    $name = if ($record.ContainsKey('UserId')) { Get-UserDisplayName -UserId ([long]$record.UserId) } else { '' }
                    if ($name) { $name } else { '—' }
                }
            }
            $cells += , @(
                @{ text = [string]$layer }
                @{ text = [string]$record.Key }
                @{ text = $since }
                @{ text = $who }
            )
        }
        $blocks += @{ type = 'table'; cells = $cells }
    }

    $blocks += @{ type = 'paragraph'; text = "🔄 $age" }
    $blocks += @{ type = 'paragraph'; text = (T 'kb.engineChannel' $($config.AirServerAddress) $($config.AirChannelNumber)) }
    if ($UserId -gt 0) { $blocks += @{ type = 'paragraph'; text = "👤 $(Format-UserAuditActor -UserId $UserId)" } }
    return $blocks
}

function Get-MainMenuIntro {
    param([long]$UserId = 0)
    <#
        The screen above the main menu, built as parse_mode=HTML.

        It used to read (T 'menu.pickFromList'), which tells the operator nothing
        they cannot already see, and then as flat text - one undifferentiated
        column an operator had to read line by line to find the one fact they
        opened the menu for.

        HTML earns its place three times here rather than for decoration:
        the verdict is bold because it is the one line that must land in a
        glance; every number an operator quotes or copies - layer, channel,
        engine address - is a <code> span, which Telegram renders monospace,
        makes tap-to-copy, and keeps left-to-right so digits stop reordering
        against the Arabic around them; and the freshness line is italic so
        it reads as a footnote to the air block rather than another claim.

        Everything typed by a person - a template name, an operator's display
        name - is escaped. An unescaped "<" in a template name would make
        Telegram reject the whole menu with a 400, which reads on the phone
        as the menu button doing nothing.
    #>
    $freshness = Get-CinegyStateFreshness `
        -LastSuccessfulAt $(if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }) `
        -StaleAfterSeconds ([math]::Max(1, (Get-SettingInt 'CinegyStateCheckSeconds' 1) * 3))
    # How old the claim is matters as much as the claim: a stale 'on air' that
    # looks identical to a fresh one is what let an exited scene go unnoticed.
    $age = switch ($freshness.State) {
        'connected' { (T 'kb.checkedAgo' $($freshness.AgeSeconds)) }
        'stale' { (T 'kb.lastCheckAgo' $($freshness.AgeSeconds)) }
        'unavailable' { (T 'onair.checkFailed') }
        default { (T 'onair.notChecked') }
    }
    # The air block is a <blockquote>, not two drawn lines around it.
    #
    # The screen was already sent as HTML but spent the markup on emphasis
    # alone, so it still read as one flat column with "━━━" scratched across
    # it twice. A blockquote is the structure itself: Telegram draws the bar
    # and the indent, which is what separating a block actually means, and the
    # verdict above it and the machine line below it are then outside
    # something rather than merely between two rows of dashes.
    #
    # Expandable once the list is long. A gallery with several layers up
    # pushed the engine and the operator line off the bottom of the screen,
    # and those are the two lines an operator quotes when reporting the very
    # fault they are looking at.

    # The same verdict wording as ℹ️ الحالة, but read off the stored freshness
    # rather than a live Cinegy sweep: this screen opens on every menu press
    # and must not pay for a round trip to the engine each time.
    #
    # Green is claimed only on a confirmed reading. Anything else - stale,
    # unreachable, or never checked at all - is an unknown, and a bridge that
    # has not yet reached Cinegy once saying "all clear" is the same false
    # comfort as a stale "on air" that reads like a fresh one.
    $verdict = if ($freshness.State -ne 'connected') { (T 'onair.unconfirmed') }
    elseif ($script:OnAir.Count -gt 0) { (T 'onair.layersUp') }
    else { (T 'onair.allWell') }

    $air = [System.Collections.Generic.List[string]]::new()
    if ($script:OnAir.Count -eq 0) { $air.Add((T 'onair.none')) }
    else {
        $air.Add((T 'kb.onAirCount' $($script:OnAir.Count)))
        # One layer per line, and under each the two facts an operator asks
        # about a graphic they did not put up themselves: how long it has been
        # there, and whose it is. Both were already recorded - the confirmation
        # screen has printed them for releases - and the screen an operator
        # actually lands on did not.
        #
        # Capped, because each layer costs two lines now. Nothing is lost by
        # it: the keyboard under this message carries a hide button for every
        # live layer, named, so the full list is always one glance below.
        $layers = @($script:OnAir.Keys | Sort-Object)
        $shown = @($layers | Select-Object -First 4)
        foreach ($layer in $shown) {
            $record = $script:OnAir[$layer]
            $air.Add((T 'kb.layerRow' $layer $(ConvertTo-TelegramHtmlText ([string]$record.Key))))

            $detail = [System.Collections.Generic.List[string]]::new()
            # Guarded: these records are written by a dozen call sites and
            # carry only the fields each one cares about, so under StrictMode
            # an absent key would take the menu down - the screen an operator
            # opens when something has already gone wrong.
            if ($record.ContainsKey('At') -and $record.At -is [datetime]) {
                $detail.Add((T 'kb.ago' $(Format-Duration -Seconds ([int]((Get-Date) - $record.At).TotalSeconds))))
            }
            $source = if ($record.ContainsKey('Source')) { [string]$record.Source } else { 'bridge' }
            $detail.Add($(switch ($source) {
                        'cinegy' { (T 'onair.external') }
                        'BotTest' { (T 'onair.templateTest') }
                        default {
                            $who = if ($record.ContainsKey('UserId')) { Get-UserDisplayName -UserId ([long]$record.UserId) } else { '' }
                            if ($who) { $who } else { (T 'adm.unknown') }
                        }
                    }))
            $air.Add("   ↳ <i>$(ConvertTo-TelegramHtmlText ($detail -join ' · '))</i>")
        }
        if ($layers.Count -gt $shown.Count) {
            $air.Add((T 'kb.andMoreHideBelow' $($layers.Count - $shown.Count)))
        }
    }
    $air.Add("🔄 <i>$age</i>")

    $lines = [System.Collections.Generic.List[string]]::new()
    # Bold, not an emoji alone: the emoji carries the colour, the weight
    # carries the priority, and the two together survive a phone glanced at
    # from arm's length in a gallery.
    #
    # Separated by blank lines rather than wrapped in a <blockquote>. The
    # quote gave the block a heavy bar down its side, which reads as material
    # taken from somewhere else - and this is the screen's own answer, on the
    # screen an operator opens dozens of times a shift. A blank line above and
    # below groups it just as well and carries no such claim.
    $lines.Add("<b>$verdict</b>")
    $lines.Add('')
    $lines.Add($air -join "`n")
    $lines.Add('')
    $lines.Add((T 'kb.engineChannelHtml' $(ConvertTo-TelegramHtmlText ([string]$config.AirServerAddress)) $($config.AirChannelNumber)))
    # Format-UserAuditActor, the same helper ℹ️ الحالة uses, so one operator is
    # written one way on both screens - and so the bracketed id stays pinned
    # LTR after an Arabic name instead of rendering as ")8201739556(".
    if ($UserId -gt 0) { $lines.Add("👤 $(ConvertTo-TelegramHtmlText (Format-UserAuditActor -UserId $UserId))") }
    return ($lines -join "`n")
}

function Get-LayerRemovalSummary {
    <# Describes exactly what is about to be taken off air, so a confirmation
       says "lower-third, on air 4 د, pushed by Ahmed" rather than the layer
       number alone. A layer number is not something an operator can check
       against the screen under pressure; a template name is. #>
    param([Parameter(Mandatory)][int]$Layer)
    if (-not $script:OnAir.ContainsKey([int]$Layer)) {
        return (T 'onair.noRecord' $Layer)
    }
    $record = $script:OnAir[[int]$Layer]
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((T 'kb.layerPair' $Layer $($record.Key)))
    if ($record.At -is [datetime]) {
        $parts.Add((T 'kb.onAirSince' $(Format-Duration -Seconds ([int]((Get-Date) - $record.At).TotalSeconds))))
    }
    # What it says, when the operator has asked to be shown it. A layer
    # number and a template name identify the graphic; the copy is what tells
    # an operator whether this is the strap they meant to take off.
    if (Get-Setting 'ShowOnAirTextOnRemoval') {
        $copy = [string](Get-JsonProp $record 'ScreenCopy')
        if ($copy) { $parts.Add((T 'onair.text' $copy)) }
        else { $parts.Add((T 'onair.textUnknown')) }
    }
    $source = if ($record.ContainsKey('Source')) { [string]$record.Source } else { 'bridge' }
    $parts.Add($(switch ($source) {
                'cinegy' { (T 'onair.sourceExternal') }
                'BotTest' { (T 'onair.sourceTest') }
                default { (T 'kb.sentBy' $(Get-UserDisplayName -UserId ([long]$record.UserId))) }
            }))
    return ($parts -join "`n")
}

function Get-LayerRemovalConfirmKeyboard {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][ValidateSet('hide', 'exit')][string]$Action)
    $label = if ($Action -eq 'hide') { (T 'confirm.hideYes') } else { (T 'confirm.exitYes') }
    return @{ inline_keyboard = @(
            # Red here too, or turning ConfirmLayerRemoval ON - the safer
            # setting - would hand the operator the weaker screen.
            , @( (New-Button $label "${Action}go:$Layer" -Style danger), (New-Button (T 'common.cancel') 'menu') )
        ) }
}

function Get-AdminToolsKeyboard {
    <#
        The rarely-used administrator surface, split out of the main menu so
        a live-layer row is never pushed below the fold by configuration.

        Was one flat wall of ~15 buttons mixing user management, content,
        diagnostics, and dangerous system actions - no grouping despite the
        settings screen already solving exactly this with category tabs
        (Get-SettingsKeyboard). This is that same picker pattern, reused
        rather than reinvented: four categories here, the tools themselves
        unchanged in Get-AdminToolsCategoryKeyboard below. Takes no ChatId/
        UserId - unlike the category screen, this picker is the same for
        every administrator, so callers pass none (matches Get-SettingsKeyboard).
    #>
    $categories = @(
        @{ Key = 'users'; Icon = '👥'; Label = (T 'kb.usersAndRights') }
        @{ Key = 'content'; Icon = '📚'; Label = (T 'kb.contentAndTemplates') }
        @{ Key = 'health'; Icon = '🩺'; Label = (T 'kb.healthAndDiagnostics') }
        @{ Key = 'system'; Icon = '⚙️'; Label = (T 'kb.systemAndFeed') }
    )
    # Two to a row like the settings picker, not one per line: four stacked
    # rows plus a back row is five screens' worth of thumb travel for four
    # choices, and OneHandMode splits pairs back apart when that is wanted.
    $rows = @()
    $pair = @()
    foreach ($category in $categories) {
        $pair += (New-Button "$($category.Icon) $($category.Label)" "admintools:$($category.Key)")
        if ($pair.Count -eq 2) { $rows += , $pair; $pair = @() }
    }
    if ($pair.Count -gt 0) { $rows += , $pair }
    $rows += , @( (New-Button (T 'common.home') 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Get-AdminToolsCategoryKeyboard {
    <# The tools inside one Get-AdminToolsKeyboard category - the same
       buttons the flat wall used to carry, just grouped by what they touch. #>
    param([Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $rows = @()
    switch ($Category) {
        'users' {
            $rows += , @( (New-Button (T 'kb.manageUsers') "menu:usersadmin"), (New-Button (T 'kb.userActivity') "menu:userpresence") )
        }
        'content' {
            $rows += , @( (New-Button (T 'kb.templatesAndSettings') "menu:templatesadmin"), (New-Button (T 'kb.readyTexts') "menu:presetsadmin") )
            if (Get-Setting 'EnableAnnouncements') { $rows += , @( (New-Button (T 'kb.notices') "menu:announcements") ) }
        }
        'health' {
            $rows += , @( (New-Button (T 'kb.shiftReadiness') "menu:readiness") )
            $rows += , @( (New-Button (T 'kb.systemHealth') "menu:healthcenter"), (New-Button (T 'kb.runNumbers') "menu:stats") )
            $rows += , @( (New-Button (T 'kb.livePathCheck') "menu:selftest"), (New-Button (T 'kb.usageSummary') "menu:usagedigest") )
            $adminRow = @( (New-Button (T 'kb.log') "menu:audit"), (New-Button (T 'kb.diagnostics') "menu:diagnostics") )
            if (Get-Setting 'EnableRawCommand') { $adminRow += (New-Button (T 'kb.rawCommand') "menu:rawcmd") }
            $rows += , $adminRow
        }
        'system' {
            if (Get-Setting 'EnableLiveRelay') {
                $relayRunning = [bool](Get-RunningRelayProcess)
                $relayLabel = if ($relayRunning) { (T 'kb.stopFeed') } else { (T 'kb.startFeed') }
                $relayData = if ($relayRunning) { "menu:stream:stop" } else { "menu:stream:start" }
                $rows += , @( (New-Button $relayLabel $relayData), (New-Button (T 'kb.feedLink') "menu:stream:seturl") )
            }
            $rows += , @( (New-Button (T 'kb.exportSettings') "menu:cfgexport"), (New-Button (T 'kb.importSettings') "menu:cfgimport") )
            if (Get-Setting 'AllowRemoteRestart') { $rows += , @( (New-Button (T 'kb.restartBridge') "menu:restart" -Style danger) ) }
        }
    }
    # Home beside back: two levels down, the menu was two taps away, and the
    # menu is where the live controls are.
    $rows += , @( (New-Button (T 'kb.backToAdminTools') "menu:admintools"), (New-Button (T 'common.home') 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Get-HealthCenterKeyboard {
    $rows = @(
        , @((New-Button (T 'common.refresh') 'menu:healthcenter'), (New-Button (T 'kb.fullState') 'menu:fullstatus'))
        , @((New-Button (T 'kb.diagnostics') 'menu:diagnostics'), (New-Button (T 'kb.runtimeFiles') 'health:files'))
    )
    # F9: the button exists only when the screen does. An opt-in feature
    # must not advertise itself to whoever never asked for it.
    if (Get-Setting 'EnableEngineHealth') {
        $rows += , @((New-Button (T 'kb.engineHealth') 'menu:enginehealth'))
    }
    $rows += , @((New-Button (T 'kb.backToAdminTools') 'menu:admintools'))
    return @{ inline_keyboard = $rows }
}

function Get-TemplateCategories {
    $store = Get-TemplateStore
    return @($store.Order | ForEach-Object { ([string]$store.Map[$_].Category).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-TemplateLastUsedLabel {
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:TemplateLastUsed.ContainsKey($Key)) { return '' }
    return " · 🕘 $(([datetime]$script:TemplateLastUsed[$Key]).ToLocalTime().ToString('MM-dd HH:mm'))"
}

function Get-TemplatesKeyboard {
    <# Prefix selects what tapping a template does: tpl = show now,
       tplT = show with auto-hide, updtpl = pick a field to update.

       A template the operator may not put on air is left out rather than
       offered and then refused: a list that shows what pressing it will
       reject teaches people to press and see, which is the opposite of a
       permission. Called without a user nothing is filtered - that is the
       registry's own view of itself. #>
    param([string]$Prefix = 'tpl', [string]$Category = '', [string]$Query = '', [switch]$BrowseControls,
        [long]$ChatId = 0, [long]$UserId = 0, [int]$Page = 0, [int]$PageSize = 20)
    $store = Get-TemplateStore
    $rows = @()
    if ($BrowseControls -and $Prefix -eq 'tpl') {
        $rows += , @((New-Button (T 'common.search') 'menu:templatesearch'), (New-Button (T 'templates.categories') 'menu:templatecategories'))
    }
    # Which templates qualify, gathered before any button is built: this list
    # is what the page window measures, and it is the registry - it grows with
    # the station. Measured at 300 templates the unpaged keyboard was 301 rows
    # and 29 KB of reply_markup, which Telegram will not send.
    $qualified = @(for ($i = 0; $i -lt $store.Order.Count; $i++) {
            $candidate = $store.Map[$store.Order[$i]]
            if ($Category -and -not ([string]$candidate.Category).Equals($Category, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($Query) {
                $haystack = "$($candidate.Key) $($candidate.Description) $($candidate.Category)"
                if ($haystack.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            }
            if ($ChatId -gt 0 -and -not (Test-TemplateAccess -Key ([string]$candidate.Key) -Layer ([int]$candidate.Layer) -ChatId $ChatId -UserId $UserId).Allowed) { continue }
            $i
        })
    $matched = @($qualified).Count
    # A search is narrowed by the operator's own words, and its callback
    # cannot carry them back - the query lives only in the message that asked
    # for it. So search results are capped rather than paged, and the cap
    # says what it hid instead of pretending to be the whole answer.
    $pageIndexes = if ($Query) { @(@($qualified) | Select-Object -First $PageSize) }
    else {
        $window = Get-BridgePageWindow -ItemCount $matched -Page $Page -PageSize $PageSize
        if ($window.EndIndex -ge $window.StartIndex) { @(@($qualified)[$window.StartIndex..$window.EndIndex]) } else { @() }
    }
    foreach ($i in @($pageIndexes)) {
        $t = $store.Map[$store.Order[$i]]
        # A lock badge here is the early warning: the operator sees the clash
        # before typing a single field, instead of after.
        $lockBadge = if ((Get-Setting 'ShowLayerLockBadge') -and $script:LayerLocks.ContainsKey([int]$t.Layer)) { '🔒 ' } else { '' }
        # The name only. The label used to carry the layer number and a
        # timestamp, which pushed it past ButtonTextMaxLength and left the
        # button reading "News-Ticker (طبقة 8) · 🕘 08-25…" - a half-cut date
        # that looks like noise. Layer, category and last use are all on the
        # ℹ️ screen, which has room for them.
        $templateRow = @((New-Button "$lockBadge$($t.Key)" "$Prefix`:$i"))
        if ($Prefix -eq 'tpl') { $templateRow += (New-Button 'ℹ️' "tplinfo:$i") }
        $rows += , $templateRow
        # Presets are only meaningful for an immediate show.
        if ($Prefix -eq 'tpl') {
            $presetRow = @()
            for ($p = 0; $p -lt $t.Presets.Count; $p++) {
                $presetRow += (New-Button "  ⚡ $($t.Presets[$p].Name)" "preset:$i`:$p")
                if ($presetRow.Count -eq 2) { $rows += , $presetRow; $presetRow = @() }
            }
            if ($presetRow.Count -gt 0) { $rows += , $presetRow }
        }
    }
    if ($matched -eq 0) {
        $rows += , @( (New-Button $(if ($Query -or $Category) { (T 'templates.noMatch') } else { (T 'templates.noneDefined') }) "menu:templates") )
    }
    elseif ($Query) {
        $hiddenResults = $matched - @($pageIndexes).Count
        if ($hiddenResults -gt 0) {
            $rows += , @( (New-Button (T 'kb.narrowSearch' $hiddenResults) 'menu:templatesearch') )
        }
    }
    else {
        # A category view pages by the category's own position, because the
        # name is free text and callback_data is capped at 64 bytes.
        $pagerPrefix = if ($Category) {
            $categoryIndex = [array]::IndexOf(@(Get-TemplateCategories), $Category)
            if ($categoryIndex -ge 0) { "tplcatpg:$categoryIndex" } else { '' }
        }
        else { "tplpage:$Prefix" }
        if ($pagerPrefix) {
            $pager = @(Get-BridgePagerButtons -Window $window -Prefix $pagerPrefix)
            if ($pager.Count -gt 0) { $rows += , $pager }
        }
    }
    $rows += , @( (New-Button (T 'kb.back') "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateCategoriesKeyboard {
    param([int]$Page = 0)
    $categories = @(Get-TemplateCategories)
    $rows = @()
    $window = Get-BridgePageWindow -ItemCount $categories.Count -Page $Page -PageSize 20
    if ($window.EndIndex -ge $window.StartIndex) {
        for ($i = $window.StartIndex; $i -le $window.EndIndex; $i++) { $rows += , @((New-Button "🗂 $($categories[$i])" "tplcat:$i")) }
    }
    $pager = @(Get-BridgePagerButtons -Window $window -Prefix 'tplcatpage')
    if ($pager.Count -gt 0) { $rows += , $pager }
    if ($categories.Count -eq 0) { $rows += , @((New-Button (T 'templates.noCategories') 'menu:templates')) }
    $rows += , @((New-Button (T 'templates.all') 'menu:templates'), (New-Button (T 'kb.back') 'menu'))
    return @{ inline_keyboard = $rows }
}

function Get-TemplatePreviewText {
    param([Parameter(Mandatory)]$Template)
    $category = if ([string]::IsNullOrWhiteSpace([string]$Template.Category)) { (T 'templates.uncategorised') } else { [string]$Template.Category }
    $description = if ([string]::IsNullOrWhiteSpace([string]$Template.Description)) { (T 'templates.noDescription') } else { [string]$Template.Description }
    $fields = if (@($Template.Fields).Count -eq 0) { (T 'templates.noFields') } else { @($Template.Fields) -join (T 'common.comma') }
    $lastUsed = if ($script:TemplateLastUsed.ContainsKey([string]$Template.Key)) {
        ([datetime]$script:TemplateLastUsed[[string]$Template.Key]).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    else { (T 'templates.neverUsed') }
    $device = [string](Get-JsonProp $Template 'Device')
    # A device-backed template has no meaningful layer number - the number is
    # only the bridge's internal key - so showing it would be the same noise
    # the button just lost.
    $where = if ($device) { (T 'templates.deviceLayer' $device) } else { (T 'templates.layerOf' $Template.Layer) }
    $uses = if ($script:UsageCounts.ContainsKey([string]$Template.Key)) { Get-ArabicCountNoun -Count ([int]$script:UsageCounts[[string]$Template.Key]) -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' -EnglishOne 'time' -EnglishMany 'times' } else { (T 'templates.neverUsedShort') }
    $live = if ($script:OnAir.ContainsKey([int]$Template.Layer)) { (T 'templates.liveNow') } else { (T 'templates.notShowing') }

    $lines = [System.Collections.Generic.List[string]]::new()
    # parse_mode=HTML. This screen is read just before something goes to air,
    # so the two facts that decide that - which template, and whether it is
    # already up - carry the weight and the rest is the detail behind them.
    # Key, category, description and field names are all typed by an
    # administrator, so all of them are escaped.
    $lines.Add("ℹ️ <b>$(ConvertTo-TelegramHtmlText ([string]$Template.Key))</b>")
    $lines.Add("<b>$live</b>")
    $lines.Add((T 'kb.templateQuote' $(ConvertTo-TelegramHtmlText $where) $(ConvertTo-TelegramHtmlText $category) $(ConvertTo-TelegramHtmlText $fields)))
    $lines.Add((ConvertTo-TelegramHtmlText $description))
    $lines.Add('')
    $lines.Add((T 'kb.usageLast' $(ConvertTo-TelegramHtmlText $uses) $(ConvertTo-TelegramHtmlText $lastUsed)))
    return ($lines -join "`n")
}

function Get-TemplatePreviewKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    return @{ inline_keyboard = @(
        , @((New-Button (T 'templates.choose') "tpl:$TemplateIndex"))
        , @((New-Button (T 'templates.back') 'menu:templates'))
    ) }
}

function Start-TemplateSearch {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'template_search'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'templates.searchPrompt') -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-TemplateSearch {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_search') { return }
    Clear-PendingState -ChatId $ChatId
    $query = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($query)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'templates.searchEmpty') -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -BrowseControls)
        return
    }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.searchResults' $query) -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -Query $query -BrowseControls)
}

function Get-RetryDelaySeconds {
    <#
        NOT the backoff the scheduler runs on. The live one is
        Get-BridgeScheduleRetryDecision in Modules/BridgeSchedulePolicy.psm1,
        called from Bridge.Schedule.ps1, and that is what reads
        ScheduleRetryDelaySeconds, ScheduleRetryBackoffFactor and
        ScheduleRetryMaxDelaySeconds.

        Nothing in the product calls this copy - only its tests do - and the
        two formulas are identical today, which is precisely what makes it a
        trap rather than merely spare: an edit here passes its tests, ships,
        and changes nothing on air. This bridge has already paid for that
        shape once, in a keyboard guard that looked live and was inert for two
        releases.

        Change the policy module. Delete this with the next release that
        touches this file for a reason of its own - deleting it on its own
        account would be spending a release on tidiness.
    #>
    param([int]$BaseSeconds, [int]$Attempt, [int]$Factor = 2, [int]$MaxSeconds = 300)
    $base = [math]::Max(1, $BaseSeconds)
    $safeAttempt = [math]::Min(31, [math]::Max(1, $Attempt))
    $safeFactor = [math]::Max(1, $Factor)
    $cap = [math]::Max(1, $MaxSeconds)
    $calculated = [double]$base * [math]::Pow([double]$safeFactor, [double]($safeAttempt - 1))
    return [int][math]::Min([double]$cap, $calculated)
}

function Get-ScheduleLayerConflicts {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][datetimeoffset]$ScheduledAt,
        [int]$WindowMinutes = 2,
        [string]$ExcludeId = ''
    )
    if ($Layer -le 0) { return @() }
    $window = [math]::Max(0, $WindowMinutes)
    foreach ($entry in @($script:ScheduleEvents)) {
        if ([string]$entry.Status -ne 'pending' -or ([string]$entry.Id -eq $ExcludeId -and $ExcludeId)) { continue }
        $entryLayer = 0
        [int]::TryParse([string](Get-JsonProp $entry 'Layer'), [ref]$entryLayer) | Out-Null
        if ($entryLayer -le 0) {
            $store = Get-TemplateStore
            $entryKey = [string]$entry.TemplateKey
            if ($store.Map.ContainsKey($entryKey)) { $entryLayer = [int]$store.Map[$entryKey].Layer }
        }
        if ($entryLayer -ne $Layer) { continue }
        $distance = [math]::Abs((([datetimeoffset]$entry.ScheduledAt) - $ScheduledAt).TotalMinutes)
        if ($distance -le $window) { Write-Output $entry }
    }
}

function Get-AuthorizedUsersText {
    <#
        The roster, read rather than tapped.

        The screen was four buttons per person and no text: the alias three
        times over, and never the user id - the one thing that identifies
        them in the log, in an operation reference, and in the access request
        that was just approved. Ten people made forty buttons and no list.

        The alias is written by an administrator, so it is escaped like any
        other text that did not come from here.
    #>
    param([int]$Page = 0, [ValidateRange(1, 15)][int]$PageSize = 10)
    $users = @(Get-AuthorizedUsers)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'kb.authorisedUsers'))
    if ($users.Count -eq 0) {
        $lines.Add((T 'kb.nobodyYet'))
        return ($lines -join "`n")
    }
    $window = Get-BridgePageWindow -ItemCount $users.Count -Page $Page -PageSize $PageSize
    $admins = @($users | Where-Object { $_.Role -ne 'operator' }).Count
    $disabled = @($users | Where-Object { $_.Disabled }).Count
    $tally = (T 'kb.withAdminRight' $(Get-ArabicCountNoun -Count $users.Count -One 'مستخدم' -Two 'مستخدمان' -Few 'مستخدمين' -Many 'مستخدمًا' -EnglishOne 'user' -EnglishMany 'users') $admins)
    if ($disabled -gt 0) { $tally += (T 'kb.disabledCount' $disabled) }
    if ($window.PageCount -gt 1) { $tally += (T 'kb.pageOf' $($window.Page + 1) $($window.PageCount)) }
    $lines.Add("<i>$tally</i>")
    $lines.Add('')
    $activityWindow = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))
    foreach ($index in $window.StartIndex..$window.EndIndex) {
        $user = $users[$index]
        $role = switch ([string]$user.Role) { 'owner' { (T 'kb.owner') } 'admin' { (T 'kb.admin') } default { (T 'kb.operator') } }
        $state = if ($user.Disabled) { (T 'kb.disabled') } else { (T 'kb.enabled') }
        $alias = [string]$user.Alias
        # Get-UserDisplayName falls back to the id, and printing it twice on
        # two lines says nothing twice - and hides that nobody named them.
        if ($alias -eq [string]$user.UserId) { $alias = (T 'kb.noWorkingName') }
        if ($alias.Length -gt 32) { $alias = $alias.Substring(0, 31) + '…' }
        $lines.Add("$($index + 1). <b>$(ConvertTo-TelegramHtmlText -Text $alias)</b> · $role · $state")
        $activity = Get-UserActivityStatus -LastActivityAt ([string]$user.LastActivityAt) -ActiveWithinMinutes $activityWindow
        $lines.Add("   <code>$([long]$user.UserId)</code> · $(ConvertTo-TelegramHtmlText -Text ([string]$activity.Label))")
        # P7: during an incident, who touched the air last matters more than
        # their role. The latest entry of their own operation history, one
        # line, from memory - nothing new is stored for this.
        $lastOp = @(Get-UserOperationHistory -UserId ([long]$user.UserId) | Select-Object -Last 1)
        if ($lastOp.Count -gt 0) {
            $ago = ''
            try {
                $mins = [int](((Get-Date).ToUniversalTime() - ([datetime]$lastOp[0].At).ToUniversalTime()).TotalMinutes)
                if ($mins -lt 1) { $ago = (T 'kb.now') }
                elseif ($mins -lt 60) { $ago = (T 'kb.minutesAgo' $mins) }
                elseif ($mins -lt 1440) { $ago = (T 'kb.hoursAgo' $([int]($mins / 60))) }
                else { $ago = ([datetime]$lastOp[0].At).ToLocalTime().ToString('MM-dd HH:mm') }
            }
            catch { $ago = '' }
            $what = "$([string]$lastOp[0].Action) $([string]$lastOp[0].Target)".Trim()
            if ($what) { $lines.Add((T 'kb.lastAction' $(ConvertTo-TelegramHtmlText -Text $what) $(if ($ago) { " · $ago" }))) }
        }
    }
    return ($lines -join "`n")
}

function Get-UsersAdminKeyboard {
    <#
        One row per person, not five.

        The screen drew the toggle, the alias, the activity, the role change
        and the revoke button for every user on the page - ten people made
        fifty rows, and finding one person meant scrolling past nine others'
        buttons with a revoke among them. The list names people; pressing one
        opens their card, where those buttons live.
    #>
    param(
        [long]$ViewerUserId = 0,
        [int]$Page = 0,
        [ValidateRange(1, 15)][int]$PageSize = 10
    )
    $rows = @()
    $users = @(Get-AuthorizedUsers)
    $window = Get-BridgePageWindow -ItemCount $users.Count -Page $Page -PageSize $PageSize
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $user = $users[$index]
            $role = switch ([string]$user.Role) { 'owner' { '👑' } 'admin' { '🛡️' } default { '👤' } }
            $state = if ($user.Disabled) { '⛔' } else { '✅' }
            # Their own row is marked: whoever is about to disable somebody
            # should be able to see when that somebody is them.
            $you = if ($ViewerUserId -gt 0 -and [long]$user.UserId -eq $ViewerUserId) { (T 'kb.you') } else { '' }
            $rows += , @((New-Button "$($index + 1). $state $role $($user.Alias)$you" "usr:card:$($user.UserId):$($window.Page)"))
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'common.previous') "userspage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "userspage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'common.next') "userspage:$($window.Page + 1)") }
        $rows += , $pager
    }
    # D1: the quarantine roster surfaces here rather than hiding in the log.
    $deadCount = @($script:DeadChats.Keys).Count
    if ($deadCount -gt 0) {
        $rows += , @((New-Button (T 'kb.deadChats' $deadCount) 'menu:deadchats'))
    }
    $rows += , @((New-Button (T 'kb.back') 'menu'))
    return @{ inline_keyboard = $rows }
}

function Show-UsersAdminScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -le 0) { $UserId = $ChatId }
    $roleLine = if (Test-Owner -ChatId $ChatId -UserId $UserId) {
        (T 'kb.ownerMayPromote')
    }
    else { '' }
    $text = (Get-AuthorizedUsersText -Page $Page) +
    (T 'kb.tapNameForCard') +
    (T 'kb.activityIsRough' $roleLine)
    Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML `
        -ReplyMarkup (Get-UsersAdminKeyboard -ViewerUserId $UserId -Page $Page)
}

function Get-UserCardText {
    <#
        One person, in full - the screen the roster's one-line rows lead to.

        It carries what the list has no room for: when they were added and by
        whom, and how long they have been silent, which is what an
        administrator wants before deciding whether to disable them.
    #>
    param([Parameter(Mandatory)][long]$TargetUserId)
    $found = @(Get-AuthorizedUsers | Where-Object { [long]$_.UserId -eq $TargetUserId } | Select-Object -First 1)
    if ($found.Count -eq 0) { return (T 'kb.userGoneHtml') }
    $user = $found[0]
    $role = switch ([string]$user.Role) { 'owner' { (T 'kb.bridgeOwner') } 'admin' { (T 'kb.admin') } default { (T 'kb.operatorTag') } }
    $state = if ($user.Disabled) { (T 'kb.disabled') } else { (T 'kb.enabled') }
    $alias = [string]$user.Alias
    if ($alias -eq [string]$user.UserId) { $alias = (T 'kb.noWorkingName') }
    if ($alias.Length -gt 40) { $alias = $alias.Substring(0, 39) + '…' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$(ConvertTo-TelegramHtmlText -Text $alias)</b>")
    $lines.Add("<code>$([long]$user.UserId)</code> · $role · $state")
    $lines.Add('')
    $activityWindow = [math]::Min(1440, (Get-SettingInt 'UserActivityRecentMinutes' 1))
    $activity = Get-UserActivityStatus -LastActivityAt ([string]$user.LastActivityAt) -ActiveWithinMinutes $activityWindow
    $lines.Add("📈 $(ConvertTo-TelegramHtmlText -Text ([string]$activity.Label))")
    $idle = Get-UserIdleDays -User $user
    if ($idle -ge 0) { $lines.Add((T 'kb.noExchangeFor' $idle)) }
    $addedAt = [datetime]::MinValue
    if ([datetime]::TryParse([string]$user.AddedAt, [ref]$addedAt)) {
        $by = if ([long]$user.AddedByUserId -gt 0) { (T 'kb.by' $(ConvertTo-TelegramHtmlText -Text (Get-UserDisplayName -UserId ([long]$user.AddedByUserId)))) } else { '' }
        $lines.Add((T 'kb.addedOn' $($addedAt.ToString('yyyy-MM-dd')) $by))
    }
    return ($lines -join "`n")
}

function Get-UserCardKeyboard {
    <# The buttons that used to sit on every roster row, on the one card they
       belong to - so a press cannot land on the wrong person. #>
    param([Parameter(Mandatory)][long]$TargetUserId, [long]$ViewerUserId = 0, [int]$Page = 0)
    $found = @(Get-AuthorizedUsers | Where-Object { [long]$_.UserId -eq $TargetUserId } | Select-Object -First 1)
    $rows = @()
    if ($found.Count -gt 0) {
        $user = $found[0]
        $rows += , @($(if ($user.Disabled) {
                    (New-Button (T 'kb.reEnable') "usr:toggle:$TargetUserId" -Style success)
                }
                else {
                    (New-Button (T 'kb.disableTemporarily') "usr:toggle:$TargetUserId")
                }))
        $rows += , @( (New-Button (T 'kb.workingName') "usr:alias:$TargetUserId"), (New-Button (T 'kb.activityDetail') "usr:activity:$TargetUserId") )
        # No role button on the owner's card: there is nothing to promote them
        # to, and demoting them is refused anyway.
        if ($ViewerUserId -gt 0 -and (Test-Owner -ChatId $ViewerUserId -UserId $ViewerUserId) -and [string]$user.Role -ne 'owner') {
            $rows += , @($(if ([string]$user.Role -eq 'admin') {
                        (New-Button (T 'kb.demoteToOperator') "usr:demote:$TargetUserId")
                    }
                    else {
                        (New-Button (T 'kb.promoteToAdmin') "usr:promote:$TargetUserId")
                    }))
        }
        $rows += , @((New-Button (T 'kb.revoke') "usr:revoke:$TargetUserId" -Style danger))
    }
    $rows += , @((New-Button (T 'kb.backToUserList') "userspage:$Page"))
    return @{ inline_keyboard = $rows }
}

function Show-UserCardScreen {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -le 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-UserCardText -TargetUserId $TargetUserId) -ParseMode HTML `
        -ReplyMarkup (Get-UserCardKeyboard -TargetUserId $TargetUserId -ViewerUserId $UserId -Page $Page)
}

function Start-UserAliasEdit {
    param(
        [Parameter(Mandatory)][long]$TargetUserId,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$AdminUserId
    )
    if (-not (Test-Admin -ChatId $ChatId -UserId $AdminUserId)) { return }
    if (@(Get-AuthorizedUsers | Where-Object UserId -eq $TargetUserId).Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.userGone') -ReplyMarkup (Get-UsersAdminKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode='user_alias_edit'; TargetUserId=$TargetUserId; UserId=$AdminUserId }
    $current = Get-UserDisplayName -UserId $TargetUserId
    Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.workingNamePrompt' $TargetUserId $current) -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-UserAliasEdit {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$AdminUserId,
        [AllowEmptyString()][string]$Value = ''
    )
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'user_alias_edit' -or [long]$state.UserId -ne $AdminUserId) { return $false }
    $target = [long]$state.TargetUserId
    $alias = $Value.Trim()
    if ($alias -eq '-') { $alias = '' }
    if ([string]::IsNullOrWhiteSpace($alias)) { $alias = '' }
    if (-not (Set-UserAlias -TargetUserId $target -Alias $alias)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.nameNotSaved') -ReplyMarkup (Get-UsersAdminKeyboard)
        return $false
    }
    Clear-PendingState -ChatId $ChatId
    $action = if ($alias) { (T 'kb.aliasSet' $alias) } else { (T 'kb.clearAlias') }
    Write-BridgeLog "Admin $AdminUserId updated alias for user ${target}: $action"
    Add-AuditEntry (T 'kb.userAudit' $action $(Format-UserAuditActor -UserId ([long]$target)) $(Format-UserAuditActor -UserId $AdminUserId))
    Show-UsersAdminScreen -ChatId $ChatId
    return $true
}

function Get-FavoritesManagementText {
    <# The tick marks alone cannot explain two states the user can be in:
       having picked nothing (the menu row is then guessed from usage), and
       having picked more than FavoritesCount (only the first few reach the
       menu). Both used to look like the screen was ignoring the taps. #>
    param([Parameter(Mandatory)][long]$UserId)
    $selected = @(Get-UserFavoriteSelection -UserId $UserId)
    $count = Get-SettingInt 'FavoritesCount' 0
    $lines = [System.Collections.Generic.List[string]]::new()
    # parse_mode=HTML. The line under the title is the whole point of this
    # screen - it explains the two states the tick marks cannot - so it is
    # italic and reads as an explanation rather than a second instruction.
    #
    # The counts stay inside the italic as plain digits rather than <code>:
    # italic and code cannot be combined on the same characters, and breaking
    # the sentence into three spans to buy monospace would cost the sentence.
    $lines.Add((T 'kb.pickFavourites'))
    if ($count -le 0) {
        $lines.Add((T 'kb.favouritesZero'))
    }
    elseif ($selected.Count -eq 0) {
        $lines.Add((T 'kb.noFavouritesYet' $(Get-ArabicCountNoun -Count $count -One 'قالب' -Two 'قالبان' -Few 'قوالب' -Many 'قالبًا' -EnglishOne 'template' -EnglishMany 'templates')))
    }
    elseif ($selected.Count -gt $count) {
        $lines.Add((T 'kb.tooManyFavourites' $(Get-ArabicCountNoun -Count $selected.Count -One 'قالب' -Two 'قالبان' -Few 'قوالب' -Many 'قالبًا' -EnglishOne 'template' -EnglishMany 'templates') $count))
    }
    return ($lines -join "`n")
}

function Get-BridgePagerButtons {
    <#
        The previous/position/next row for a paged keyboard, or nothing at all
        when there is only one page.

        Get-TemplateAdminCatalogueKeyboard grew this row by hand and three
        more screens were about to copy it. One builder because the shape is
        the contract: the middle button shows "page of pages" and does
        nothing, which is what stops an operator pressing it to find out.
    #>
    param([Parameter(Mandatory)]$Window, [Parameter(Mandatory)][string]$Prefix)
    if ([int]$Window.PageCount -le 1) { return @() }
    $pager = @()
    if ($Window.HasPrevious) { $pager += (New-Button (T 'common.previous') "${Prefix}:$([int]$Window.Page - 1)") }
    $pager += (New-Button "$([int]$Window.Page + 1)/$([int]$Window.PageCount)" "${Prefix}:$([int]$Window.Page)")
    if ($Window.HasNext) { $pager += (New-Button (T 'common.next') "${Prefix}:$([int]$Window.Page + 1)") }
    return $pager
}

function Get-FavoritesManagementKeyboard {
    param([Parameter(Mandatory)][long]$UserId, [int]$Page = 0)
    # Get-UserFavoriteSelection, not Get-FavoriteTemplateKeys: the tick has to
    # follow what is stored, or a pick past FavoritesCount shows unticked and
    # the toggle can never turn it back off.
    $store = Get-TemplateStore; $selected = @(Get-UserFavoriteSelection -UserId $UserId); $rows = @()
    # One row per template in the whole registry, so this grows with the
    # station. Paged like its sibling catalogue rather than trusted to stay
    # small: the index in favtoggle stays the registry position, so a toggle
    # on page three still names the template its label showed.
    $window = Get-BridgePageWindow -ItemCount $store.Order.Count -Page $Page -PageSize 20
    if ($window.EndIndex -ge $window.StartIndex) {
        for ($i = $window.StartIndex; $i -le $window.EndIndex; $i++) {
            $key = [string]$store.Order[$i]
            $mark = if ($selected -contains $key) { '✅' } else { '▫️' }
            $rows += , @((New-Button "$mark $key" "favtoggle:$i"))
        }
    }
    $rows += , @(Get-BridgePagerButtons -Window $window -Prefix 'favpage')
    $rows = @($rows | Where-Object { @($_).Count -gt 0 })
    $rows += , @((New-Button (T 'kb.back') 'menu'))
    return @{ inline_keyboard = $rows }
}

function Get-LayersKeyboard {
    param([Parameter(Mandatory)][string]$Prefix)
    $rows = @()
    $row = @()
    foreach ($l in (Get-KnownLayers)) {
        $row += (New-Button (Get-LayerDisplayName -Layer $l) "$Prefix`:$l")
        if ($row.Count -eq 4) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button (T 'kb.back') "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-PresetAdminTemplatesKeyboard {
    param([int]$Page = 0)
    $store = Get-TemplateStore
    $rows = @()
    $window = Get-BridgePageWindow -ItemCount $store.Order.Count -Page $Page -PageSize 20
    if ($window.EndIndex -ge $window.StartIndex) {
        for ($i = $window.StartIndex; $i -le $window.EndIndex; $i++) {
            $template = $store.Map[$store.Order[$i]]
            $rows += , @( (New-Button "$($template.Key) ($(@($template.Presets).Count))" "padm:$i") )
        }
    }
    $pager = @(Get-BridgePagerButtons -Window $window -Prefix 'padmpage')
    if ($pager.Count -gt 0) { $rows += , $pager }
    $rows += , @( (New-Button (T 'adm.menu') 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-PresetAdminKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex, [int]$Page = 0)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    $rows = @()
    if ($template) {
        # An administrator adds these one at a time and rarely deletes, so the
        # list only ever grows. Paged at the same size as its sibling screens:
        # a template with fewer than twenty presets renders exactly as before,
        # since the pager row appears only when there is a second page.
        $presetWindow = Get-BridgePageWindow -ItemCount @($template.Presets).Count -Page $Page -PageSize 20
        if ($presetWindow.EndIndex -ge $presetWindow.StartIndex) {
            for ($i = $presetWindow.StartIndex; $i -le $presetWindow.EndIndex; $i++) {
                $rows += , @( (New-Button "⚡ $($template.Presets[$i].Name)" "pa:$TemplateIndex`:$i") )
            }
        }
        $presetPager = @(Get-BridgePagerButtons -Window $presetWindow -Prefix "papage:$TemplateIndex")
        if ($presetPager.Count -gt 0) { $rows += , $presetPager }
        $rows += , @( (New-Button (T 'kb.newReadyText') "pac:$TemplateIndex") )
    }
    $rows += , @( (New-Button (T 'templates.back') 'menu:presetsadmin') )
    return @{ inline_keyboard = $rows }
}

function Get-PresetActionKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex)
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'kb.editValues') "pae:$TemplateIndex`:$PresetIndex"), (New-Button (T 'common.rename') "par:$TemplateIndex`:$PresetIndex") )
            , @( (New-Button (T 'common.delete') "pad:$TemplateIndex`:$PresetIndex" -Style danger), (New-Button (T 'kb.back') "padm:$TemplateIndex") )
        ) }
}

function Get-PresetReviewKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'common.saveChange') 'presetadmin:confirm' -Style success), (New-Button (T 'common.cancel') 'cancel') )
        ) }
}

function Get-ScheduleMenuKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'kb.addSchedule') 'schedule:new'), (New-Button (T 'sch.upcoming') 'schedule:list') )
            , @( (New-Button (T 'sch.execLog') 'schedule:execlog'), (New-Button (T 'adm.menu') 'menu') )
        ) }
}

function Get-ScheduleRecurrenceKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'sch.once') 'schrec:once'), (New-Button (T 'sch.daily') 'schrec:daily'), (New-Button (T 'sch.weekly') 'schrec:weekly') )
            , @( (New-Button (T 'common.cancel') 'cancel') )
        ) }
}

function Get-ScheduleReviewKeyboard {
    param([hashtable]$State)
    $rows = @()
    if ($State -and [string]$State.Recurrence -ne 'once') {
        $rows += , @((New-Button (T 'kb.setRepeatEnd') 'schedule:setend'), (New-Button (T 'kb.noEnd') 'schedule:clearend'))
    }
    # T-52: anchoring only makes sense for a single firing. A daily anchor
    # to "today's 15:00 programme" is a wall-clock time wearing a costume.
    if ($State -and [string]$State.Recurrence -eq 'once') {
        if ([string](Get-JsonProp $State 'AnchorMaterialId')) {
            $rows += , @((New-Button (T 'kb.unlinkItem') 'schedule:unanchor'))
        }
        else {
            $rows += , @((New-Button (T 'kb.linkItem') 'schedule:anchor'))
        }
    }
    $rows += , @((New-Button (T 'kb.confirmSchedule') 'schedule:confirm' -Style success), (New-Button (T 'common.cancel') 'cancel'))
    return @{ inline_keyboard = $rows }
}

function Get-UpcomingScheduleBlocks {
    <#
        The upcoming events as a table.

        The text version carries a tg-time entity per event, so each reader
        sees the moment in their own zone. A table cell cannot hold an entity,
        so the station's own time is written out instead - which is the time a
        playout schedule is actually written in - and the text version stays
        the one that adapts.
    #>
    param([int]$Page = 0, [ValidateRange(1, 15)][int]$PageSize = 8)
    $events = @(Get-UpcomingScheduleEvents)
    $blocks = @(@{ type = 'heading'; text = (T 'kb.upcomingCount' $($events.Count)); size = 3 })
    if ($events.Count -eq 0) {
        return $blocks + @(@{ type = 'paragraph'; text = (T 'kb.noUpcoming') })
    }
    $window = Get-BridgePageWindow -ItemCount $events.Count -Page $Page -PageSize $PageSize
    if ($window.PageCount -gt 1) {
        $blocks += @{ type = 'paragraph'; text = (T 'kb.page' $($window.Page + 1) $($window.PageCount)) }
    }
    $cells = @(, @(
            @{ text = (T 'kb.col.template'); is_header = $true }
            @{ text = (T 'kb.col.when'); is_header = $true }
            @{ text = (T 'kb.col.repeat'); is_header = $true }
        ))
    foreach ($index in $window.StartIndex..$window.EndIndex) {
        $entry = $events[$index]
        $at = [datetimeoffset]$entry.ScheduledAt
        $recurrence = switch ([string]$entry.Recurrence) { 'daily' { (T 'sch.daily') }; 'weekly' { (T 'sch.weekly') }; default { (T 'sch.once') } }
        $cells += , @(
            @{ text = [string]$entry.TemplateKey }
            @{ text = $at.ToString('MM-dd HH:mm') }
            @{ text = $recurrence }
        )
    }
    return $blocks + @(@{ type = 'table'; cells = $cells })
}

function Get-UpcomingScheduleText {
    <#
        The upcoming events, as one page of them.

        HTML so each event carries a tg-time entity: the reader sees the
        weekday, date and time in their own timezone rather than in the
        bridge's. It is paged with the keyboard below and for the same reason -
        a fortnight of daily events overran a Telegram message, and the list
        arrived stripped of its markup.
    #>
    param([int]$Page = 0, [ValidateRange(1, 15)][int]$PageSize = 8)
    $events = @(Get-UpcomingScheduleEvents)
    if ($events.Count -eq 0) { return (T 'kb.noUpcoming') }
    $window = Get-BridgePageWindow -ItemCount $events.Count -Page $Page -PageSize $PageSize
    $heading = (T 'kb.upcomingCount2' $($events.Count))
    if ($window.PageCount -gt 1) { $heading += (T 'kb.pageOf' $($window.Page + 1) $($window.PageCount)) }
    $lines = @($heading)
    foreach ($index in $window.StartIndex..$window.EndIndex) {
        $lines += "• $(Format-ScheduleEventHtml -ScheduleEntry $events[$index])"
    }
    return ($lines -join "`n")
}

function Get-UpcomingScheduleKeyboard {
    <# Three buttons per event, so this filled a message faster than any other
       list here: a fortnight of daily events was already past what Telegram
       will send, and the screen stopped opening. #>
    param([int]$Page = 0, [ValidateRange(1, 15)][int]$PageSize = 8)
    $events = @(Get-UpcomingScheduleEvents)
    $window = Get-BridgePageWindow -ItemCount $events.Count -Page $Page -PageSize $PageSize
    $rows = @()
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $scheduleEntry = $events[$index]
            $at = [datetimeoffset]$scheduleEntry.ScheduledAt
            $rows += , @(
                (New-Button "✏️ $($scheduleEntry.TemplateKey) $($at.ToString('MM-dd HH:mm'))" "schededit:$($scheduleEntry.Id)"),
                (New-Button (T 'kb.copy') "schedcopy:$($scheduleEntry.Id)"),
                (New-Button '🗑' "schcancel:$($scheduleEntry.Id)")
            )
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'common.previous') "schedupage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "schedupage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'common.next') "schedupage:$($window.Page + 1)") }
        $rows += , $pager
    }
    $rows += , @( (New-Button (T 'sch.backToScheduling') 'menu:schedule') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerDashboardKeyboard {
    param([Parameter(Mandatory)][object[]]$LayerStatuses)
    $rows = @()
    $row = @()
    foreach ($status in @($LayerStatuses | Sort-Object Layer)) {
        $layer = [int]$status.Layer
        if (-not $status.Success) {
            $button = New-Button (T 'kb.checkAndCompare' $(Get-LayerDisplayName -Layer $layer)) 'menu:layers'
        }
        elseif ($status.IsOnAir) {
            $button = New-Button (T 'kb.hide' $(Get-LayerDisplayName -Layer $layer)) "hide:$layer" -Style danger
        }
        else {
            $button = New-Button (T 'kb.refreshHidden' $(Get-LayerDisplayName -Layer $layer)) 'menu:layers'
        }
        $row += $button
        if ($row.Count -eq 2) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button (T 'layer.compare') 'menu:layers'), (New-Button (T 'kb.back') 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-FieldsKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    $t = Get-TemplateByIndex -Index $TemplateIndex
    $rows = @()
    if ($t) {
        for ($f = 0; $f -lt $t.Fields.Count; $f++) {
            $label = [string]$t.Fields[$f]
            if ($f -lt @($t.FieldLabels).Count -and $t.FieldLabels[$f]) { $label = [string]$t.FieldLabels[$f] }
            $rows += , @( (New-Button $label "updf:$TemplateIndex`:$f") )
        }
    }
    $rows += , @( (New-Button (T 'kb.back') "menu:update") )
    return @{ inline_keyboard = $rows }
}

function Get-AfterShowKeyboard {
    <# Shown with the "on air" confirmation: hide/exit that exact layer without
       hunting through menus, plus the usual main menu underneath. #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $menu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    $first = @( (New-Button (T 'layer.hideThis' $Layer) "hide:$Layer" -Style danger), (New-Button (T 'layer.exit') "exit:$Layer" -Style danger) )
    # Quick timer adjustment buttons: +30s, +1m, -30s, -1m
    $timerAdjust = @(
        (New-Button (T 'timer.plus30') "timeradd:${Layer}:30"),
        (New-Button (T 'timer.plus1m') "timeradd:${Layer}:60"),
        (New-Button (T 'timer.minus30') "timeradd:${Layer}:-30"),
        (New-Button (T 'timer.minus1m') "timeradd:${Layer}:-60")
    )
    # Keep each button collection as one keyboard row. A comma inside the
    # array literal lets PowerShell unwrap the collections and produces the
    # malformed Object[] row that the Telegram repair guard has been reporting.
    $rows = @()
    $rows += , $first
    $rows += , $timerAdjust
    if (Get-RollbackCandidate -Layer $Layer -UserId $UserId) { $rows += , @((New-Button (T 'layer.rollbackSafe') "rollback:$Layer")) }
    $rows += $menu.inline_keyboard
    return @{ inline_keyboard = $rows }
}

function Get-AfterLayerRemovalKeyboard {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $menu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    $rows = @()
    if (Get-RollbackCandidate -Layer $Layer -UserId $UserId) { $rows += , @((New-Button (T 'layer.rollbackRestore') "rollback:$Layer" -Style danger)) }
    $rows += $menu.inline_keyboard
    return @{ inline_keyboard=$rows }
}

function Get-RollbackReviewKeyboard {
    param([Parameter(Mandatory)][int]$Layer)
    return @{ inline_keyboard=@(
        , @((New-Button (T 'layer.rollbackConfirm') "rollbackconfirm:$Layer" -Style success), (New-Button (T 'common.cancel') 'menu'))
    ) }
}

function Get-CancelKeyboard {
    return @{ inline_keyboard = @( , @( (New-Button (T 'common.cancel') "cancel") ) ) }
}

function Get-NoticeKeyboard {
    <#
        One way back, for a message that answers a press the reader cannot act
        on: a refusal, or a flow that ended under them.

        The whole main menu used to be attached to these. Seventeen rows under
        "this is for administrators only" push the sentence itself off a phone
        screen, and not one of the seventeen is what the reader wanted next -
        they wanted the thing they were just refused. A single button closes
        the screen without burying the reason it appeared.
    #>
    param([string]$BackData = 'menu')
    return @{ inline_keyboard = @( , @( (New-Button (T 'adm.menu') $BackData) ) ) }
}

function Get-FieldPromptKeyboard {
    param([hashtable]$State)
    $rows = @()
    if ($State -and $State.Fields -and [int]$State.Index -lt @($State.Fields).Count) {
        $index = [int]$State.Index
        $fieldName = [string]$State.Fields[$index]
        $isSensitive = Test-SensitiveFieldName -FieldName $fieldName
        if ($State.ContainsKey('Sensitives') -and $index -lt @($State.Sensitives).Count) {
            $isSensitive = $isSensitive -or [bool]$State.Sensitives[$index]
        }
        if (-not $isSensitive) {
            $recent = @(Get-RecentFieldValues -UserId ([long]$State.UserId) -FieldName $fieldName)
            for ($i = 0; $i -lt $recent.Count; $i++) {
                $label = [string]$recent[$i]
                if ($label.Length -gt 32) { $label = $label.Substring(0, 29) + '...' }
                $rows += , @( (New-Button "🕘 $label" "recent:$i") )
            }
        }
    }
    $row = @()
    if ($State -and [int]$State.Index -gt 0) { $row += (New-Button (T 'common.previous') "show:back") }
    if ($State -and $State.Values.Count -gt 0) { $row += (New-Button (T 'confirm.preview') "show:preview") }
    $row += (New-Button (T 'confirm.skip') "skip")
    $row += (New-Button (T 'common.cancel') "cancel")
    $rows += , $row
    return @{ inline_keyboard = $rows }
}

function Get-ShowReviewKeyboard {
    param([switch]$HasFields)
    $row = @( (New-Button (T 'confirm.send') "show:confirm" -Style success) )
    if ($HasFields) { $row += (New-Button (T 'confirm.edit') "show:edit") }
    return @{ inline_keyboard = @( , $row; , @( (New-Button (T 'common.cancel') "cancel") ) ) }
}

function Get-HideAllConfirmKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'confirm.hideAllYes') "hideall:confirm" -Style danger), (New-Button (T 'common.cancel') "cancel") )
        ) }
}

function Get-ApprovalKeyboard {
    <#
        The first tap asks; the second grants.

        Every consequential action in this bridge confirms - hiding a layer,
        restarting, clearing a log - and the one that hands a stranger the
        on-air controls did not. An administrator here reported an approval he
        had no memory of making, and a single stray tap on a message sitting
        in a chat is exactly how that happens, leaving nothing behind that
        would remind him.
    #>
    param([Parameter(Mandatory)][long]$TargetChatId)
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'confirm.approve') "approve:confirm:$TargetChatId" -Style success), (New-Button (T 'confirm.reject') "reject:$TargetChatId") )
            , @( (New-Button (T 'common.home') 'menu:main') )
        ) }
}

function Get-AccessGrantConfirmKeyboard {
    <# The second tap, named for what it does rather than "نعم": a button
       that says «امنح الوصول» cannot be pressed absent-mindedly and read as
       something else afterwards. #>
    param([Parameter(Mandatory)][long]$TargetChatId)
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'confirm.grantYes') "approve:$TargetChatId" -Style danger) )
            , @( (New-Button (T 'confirm.undo') 'menu:pending') )
        ) }
}

function Get-AccessHistoryRows {
    <#
        Who asked for access, who decided, and when - newest first.

        Built from two sources because neither is complete on its own. The
        audit file carries every decision including the rejections, which
        leave no other trace at all; the user profiles carry the approvals
        made before decisions were recorded as data, and outlive log rotation.
        A request approved today appears once, from the audit.

        Waiting requests are included as their own state: an administrator
        reviewing how requests were handled needs the ones that were not.
    #>
    param([int]$Days = 30)
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($record in @((Get-ReportRecords -From ((Get-Date).Date.AddDays(-$Days)) -EventName 'access').Records |
            Sort-Object -Property When -Descending)) {
        $result = [string]$record.Result
        if ($result -eq 'requested') { continue }   # the ask, paired below
        $subject = [string]$record.Target
        $key = "$subject/$result"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $rows.Add([pscustomobject]@{
                UserId      = $subject
                Name        = [string]$record.Values
                State       = $(if ($result -eq 'approved') { 'approved' } else { 'rejected' })
                DecidedAt   = $record.When
                DecidedBy   = [string](Get-AuditOperatorName -UserId ([string]$record.UserId))
                RequestedAt = $null
            })
    }

    # The approvals that predate the structured records, from the roster.
    foreach ($id in @($script:UserProfiles.Keys)) {
        if ($seen.ContainsKey("$id/approved")) { continue }
        # $entry, not $profile: $profile is a PowerShell automatic variable,
        # and assigning to it has effects nobody reading this would expect.
        $entry = $script:UserProfiles[$id]
        $addedAt = [string](Get-JsonProp $entry 'AddedAt')
        if ([string]::IsNullOrWhiteSpace($addedAt)) { continue }
        $added = [datetime]::MinValue
        if (-not [datetime]::TryParse($addedAt, [ref]$added)) { continue }
        $askedAt = [string](Get-JsonProp $entry 'RequestedAt')
        $asked = [datetime]::MinValue
        $rows.Add([pscustomobject]@{
                UserId      = [string]$id
                Name        = [string](Get-UserDisplayName -UserId ([long]$id))
                State       = 'approved'
                DecidedAt   = $added
                DecidedBy   = [string](Get-AuditOperatorName -UserId ([string](Get-JsonProp $entry 'AddedByUserId')))
                RequestedAt = $(if ([datetime]::TryParse($askedAt, [ref]$asked)) { $asked } else { $null })
            })
    }

    # Still waiting, which is a state and not an absence.
    foreach ($id in @($script:PendingApprovals.Keys)) {
        $record = $script:PendingApprovals[$id]
        $rows.Add([pscustomobject]@{
                UserId      = [string]$id
                Name        = [string](Get-JsonProp $record 'Name')
                State       = 'pending'
                DecidedAt   = $null
                DecidedBy   = ''
                RequestedAt = (Get-JsonProp $record 'RequestedAt')
            })
    }

    return @($rows | Sort-Object -Property @{ Expression = { if ($_.DecidedAt) { $_.DecidedAt } else { Get-Date } } } -Descending)
}

function Get-AccessHistoryStateLabel {
    <# The three states, named. #>
    param([Parameter(Mandatory)][string]$State)
    switch ($State) {
        'approved' { return (T 'kb.accepted') }
        'rejected' { return (T 'kb.refused') }
        default { return (T 'kb.awaitingDecision') }
    }
}

function Get-AccessHistoryBlocks {
    <# The history as a table: who, what was decided, by whom, and when. #>
    param([int]$Days = 30)
    $rows = @(Get-AccessHistoryRows -Days $Days)
    $blocks = @(@{ type = 'heading'; text = (T 'kb.pastRequestsDays' $Days); size = 3 })
    if ($rows.Count -eq 0) {
        return $blocks + @(@{ type = 'paragraph'; text = (T 'kb.noRequestsInPeriod') })
    }
    $pending = @($rows | Where-Object { $_.State -eq 'pending' }).Count
    $approved = @($rows | Where-Object { $_.State -eq 'approved' }).Count
    $rejected = @($rows | Where-Object { $_.State -eq 'rejected' }).Count
    $blocks += @{ type = 'paragraph'; text = "✅ $approved · ❌ $rejected · ⏳ $pending" }

    $trimmed = Select-RichTableRows -Items $rows
    $cells = @(, @(
            @{ text = (T 'kb.col.requester'); is_header = $true }
            @{ text = (T 'kb.col.status'); is_header = $true }
            @{ text = (T 'kb.col.decision'); is_header = $true }
            @{ text = (T 'kb.col.by'); is_header = $true }
        ))
    foreach ($row in @($trimmed.Rows)) {
        $name = if ($row.Name) { "$($row.Name) · $($row.UserId)" } else { [string]$row.UserId }
        $when = if ($row.DecidedAt) { ([datetime]$row.DecidedAt).ToString('MM-dd HH:mm') } else { '—' }
        # The wait beside the decision where there is one: two dates in a
        # four-column table are unreadable, and the gap is the fact.
        if ($row.RequestedAt -and $row.DecidedAt) {
            $waited = [int]((([datetime]$row.DecidedAt) - ([datetime]$row.RequestedAt)).TotalMinutes)
            if ($waited -ge 1) { $when += (T 'kb.after' $(Format-DurationMinutes -Minutes $waited)) }
        }
        elseif ($row.State -eq 'pending' -and $row.RequestedAt) {
            $when = (T 'kb.askedAgo' $(Format-DurationMinutes -Minutes ([int](((Get-Date) - ([datetime]$row.RequestedAt)).TotalMinutes))))
        }
        $cells += , @(
            @{ text = $name }
            @{ text = (Get-AccessHistoryStateLabel -State $row.State) }
            @{ text = $when }
            @{ text = $(if ($row.DecidedBy) { $row.DecidedBy } else { '—' }) }
        )
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown @($trimmed.Rows).Count
    if ($note) { $blocks += @{ type = 'paragraph'; text = $note } }
    # Said plainly rather than left to be discovered: what predates this
    # screen comes from the roster, which records who was let in and never
    # who was turned away.
    $blocks += @{ type = 'paragraph'; text = (T 'kb.oldRefusalsNote') }
    return $blocks
}

function Get-AccessHistoryText {
    <# The fallback, in the reports' shape. #>
    param([int]$Days = 30)
    $rows = @(Get-AccessHistoryRows -Days $Days)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'kb.pastRequestsDaysHtml' $Days))
    if ($rows.Count -eq 0) {
        $lines.Add((T 'kb.noRequestsInPeriodHtml'))
        return ($lines -join "`n")
    }
    $lines.Add('')
    $entries = @(foreach ($row in $rows) {
            $name = if ($row.Name) { ConvertTo-TelegramHtmlText ([string]$row.Name) } else { [string]$row.UserId }
            $when = if ($row.DecidedAt) { ([datetime]$row.DecidedAt).ToString('MM-dd HH:mm') } else { '—' }
            $by = if ($row.DecidedBy) { (T 'kb.by' $(ConvertTo-TelegramHtmlText ([string]$row.DecidedBy))) } else { '' }
            "$(Get-AccessHistoryStateLabel -State $row.State) $name <code>$($row.UserId)</code> · $when$by"
        })
    $tag = if ($entries.Count -gt 3) { '<blockquote expandable>' } else { '<blockquote>' }
    $lines.Add("$tag$($entries -join "`n")</blockquote>")
    return ($lines -join "`n")
}

function Get-AccessHistoryKeyboard {
    param()
    return @{ inline_keyboard = @(
            , @((New-Button (T 'kb.pendingRequests') 'menu:pending'))
            , @((New-Button (T 'common.home') 'menu:main'))
        ) }
}

function Invoke-AccessHistoryCommand {
    <# Table first, text when the table cannot be sent. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Days = 30)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $keyboard = Get-AccessHistoryKeyboard
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-AccessHistoryBlocks -Days $Days) -ReplyMarkup $keyboard) { return }
    Send-TelegramPagedText -ChatId $ChatId -Text (Get-AccessHistoryText -Days $Days) -ParseMode HTML -ReplyMarkup $keyboard
}

function Get-PendingApprovalsBlocks {
    <#
        Who is asking for control of the on-air graphics, as a table.

        An administrator granting the ability to put graphics on air is
        comparing three things across the requests - the id, the name the
        stranger chose, and how long ago they asked - which is a table rather
        than a paragraph each.
    #>
    param([int]$Page = 0, [ValidateRange(1, 40)][int]$PageSize = 20)
    $ids = @($script:PendingApprovals.Keys | Sort-Object { [long]$_ })
    $blocks = @(@{ type = 'heading'; text = (T 'kb.pendingRequestsCount' $($ids.Count)); size = 3 })
    if ($ids.Count -eq 0) {
        return $blocks + @(@{ type = 'paragraph'; text = (T 'kb.noRequestsNow') })
    }
    $window = Get-BridgePageWindow -ItemCount $ids.Count -Page $Page -PageSize $PageSize
    $cells = @(, @(
            @{ text = (T 'kb.col.id'); is_header = $true }
            @{ text = (T 'kb.col.name'); is_header = $true }
            @{ text = (T 'kb.col.since'); is_header = $true }
        ))
    foreach ($index in $window.StartIndex..$window.EndIndex) {
        $id = $ids[$index]
        $record = $script:PendingApprovals[$id]
        # Guarded: the record is written at more than one call site, and an
        # absent key would throw under StrictMode on the screen an
        # administrator opens to answer a waiting person.
        $name = [string](Get-JsonProp $record 'Name')
        if (-not $name) { $name = '—' }
        $askedAt = Get-JsonProp $record 'At'
        $since = if ($askedAt -is [datetime]) {
            Format-Duration -Seconds ([int]((Get-Date) - $askedAt).TotalSeconds)
        }
        else { '—' }
        $cells += , @(@{ text = [string]$id }, @{ text = $name }, @{ text = $since })
    }
    return $blocks + @(@{ type = 'table'; cells = $cells })
}

function Get-PendingApprovalsText {
    <#
        Who is asking for control of the on-air graphics, and since when.

        The screen said "طلبات الوصول المعلّقة:" and then a row of buttons
        carrying a name - a name the requester chose, and nothing else. An
        administrator granting the ability to put graphics on air could not
        see the user id they were granting it to, when it was asked for, or
        that the request expires on its own.

        The name is the one piece of text on this screen that a stranger
        wrote, so it is escaped and capped like any other untrusted input.
    #>
    param([int]$Page = 0, [ValidateRange(1, 40)][int]$PageSize = 20)
    $ids = @($script:PendingApprovals.Keys | Sort-Object { [long]$_ })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'kb.pendingRequestsTitle'))
    if ($ids.Count -eq 0) {
        $lines.Add((T 'kb.noRequestsNowHtml'))
        return ($lines -join "`n")
    }
    $window = Get-BridgePageWindow -ItemCount $ids.Count -Page $Page -PageSize $PageSize
    $expiryHours = Get-SettingInt 'PendingApprovalExpiryHours' 1
    $lines.Add((T 'kb.requestCount' $($ids.Count) $(if ($window.PageCount -gt 1) { (T 'kb.pageOf' $($window.Page + 1) $($window.PageCount)) })))
    $lines.Add('')
    foreach ($index in $window.StartIndex..$window.EndIndex) {
        $id = $ids[$index]
        $info = $script:PendingApprovals[$id]
        $name = [string](Get-JsonProp $info 'Name')
        if ($name.Length -gt 40) { $name = $name.Substring(0, 39) + '…' }
        $shown = if ($name) { ConvertTo-TelegramHtmlText -Text $name } else { (T 'common.noName') }
        $lines.Add("$($index + 1). <b>$shown</b>")
        $lines.Add((T 'kb.userChat' $([long](Get-JsonProp $info 'UserId')) $([long]$id)))
        $requestedAt = Get-JsonProp $info 'RequestedAt'
        if ($requestedAt) {
            $elapsed = [int]([math]::Max(0, ((Get-Date) - [datetime]$requestedAt).TotalMinutes))
            $line = (T 'kb.agoIndented' $(Format-DurationMinutes -Minutes $elapsed))
            if ($expiryHours -gt 0) {
                $left = [int]([math]::Max(0, ($expiryHours * 60) - $elapsed))
                $line += (T 'kb.expiresAfter' $(Format-DurationMinutes -Minutes $left))
            }
            $lines.Add($line)
        }
    }
    return ($lines -join "`n")
}

function Get-PendingKeyboard {
    param([int]$Page = 0, [ValidateRange(1, 40)][int]$PageSize = 20)
    # The history sits on this screen because this is where the question is
    # asked: the administrator looking at who is waiting is the same person
    # who wants to know who was let in last week, and by whom.
    $rows = @(, @((New-Button (T 'kb.pastRequests') 'access:history')))
    $ids = @($script:PendingApprovals.Keys | Sort-Object { [long]$_ })
    $window = Get-BridgePageWindow -ItemCount $ids.Count -Page $Page -PageSize $PageSize
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
        $id = $ids[$index]
        $info = $script:PendingApprovals[$id]
        $label = if ($info.Name) { "$($info.Name)" } else { "$id" }
        $rows += , @( (New-Button "✅ $($index + 1). $label" "approve:$id" -Style success), (New-Button "❌" "reject:$id") )
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'common.previous') "pendingpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "pendingpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'common.next') "pendingpage:$($window.Page + 1)") }
        $rows += , $pager
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button (T 'kb.noPendingNow') "menu") ) }
    $rows += , @( (New-Button (T 'kb.blocked') "menu:blocked"), (New-Button (T 'kb.back') "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-BlockedAccessReasonText {
    param([string]$Reason)
    switch ($Reason) {
        'rejected' { return (T 'kb.adminRefused') }
        'join_secret' { return (T 'kb.repeatedBadCode') }
        default { return (T 'kb.noReasonRecorded') }
    }
}

function Get-BlockedChatsText {
    <#
        The chats that may no longer ask, and why.

        Blocking is silent towards the blocked chat on purpose, so this screen
        is the only record an administrator has of it - it carries the reason
        and the date, because a list of bare numbers cannot be reviewed.
    #>
    param([int]$Page = 0, [ValidateRange(1, 40)][int]$PageSize = 20)
    $blocked = @(Get-BlockedAccessChats)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'kb.blockedChats'))
    if ($blocked.Count -eq 0) {
        $lines.Add((T 'kb.noBlockedChat'))
        return ($lines -join "`n")
    }
    $window = Get-BridgePageWindow -ItemCount $blocked.Count -Page $Page -PageSize $PageSize
    $lines.Add((T 'kb.italicPair' $(Get-ArabicCountNoun -Count $blocked.Count -One 'محادثة' -Two 'محادثتان' -Few 'محادثات' -Many 'محادثة' -EnglishOne 'chat' -EnglishMany 'chats') $(if ($window.PageCount -gt 1) { (T 'kb.pageOf' $($window.Page + 1) $($window.PageCount)) })))
    $lines.Add('')
    foreach ($index in $window.StartIndex..$window.EndIndex) {
        $entry = $blocked[$index]
        $lines.Add("$($index + 1). <code>$($entry.ChatId)</code>")
        $line = "   $(Get-BlockedAccessReasonText -Reason $entry.Reason)"
        $at = [datetime]::MinValue
        if ([datetime]::TryParse($entry.At, [ref]$at)) { $line += " · $($at.ToString('yyyy-MM-dd HH:mm'))" }
        if ($entry.By -gt 0) { $line += (T 'kb.by' $(ConvertTo-TelegramHtmlText -Text (Get-UserDisplayName -UserId $entry.By))) }
        $lines.Add($line)
    }
    return ($lines -join "`n")
}

function Get-BlockedChatsKeyboard {
    param([int]$Page = 0, [ValidateRange(1, 40)][int]$PageSize = 20)
    $rows = @()
    $blocked = @(Get-BlockedAccessChats)
    $window = Get-BridgePageWindow -ItemCount $blocked.Count -Page $Page -PageSize $PageSize
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $rows += , @( (New-Button (T 'kb.unblock' $($blocked[$index].ChatId)) "unblock:$($blocked[$index].ChatId)") )
        }
    }
    $rows += , @( (New-Button (T 'kb.pendingRequests') "menu:pending"), (New-Button (T 'kb.back') "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-SettingCategoryDefinitions {
    <# Translated at read time for the same reason the setting labels are: the
       definitions are built at load and the language changes while the bridge
       runs. Untranslated entries keep their Arabic. #>
    return @(foreach ($definition in $script:SettingCategoryDefinitions) {
            [pscustomobject]@{
                Key = $definition.Key
                Label = (TF "settingCategory.$($definition.Key).label" ([string]$definition.Label))
                Icon = $definition.Icon
                Summary = (TF "settingCategory.$($definition.Key).summary" ([string]$definition.Summary))
            }
        })
}

function Get-SettingNavigationMetadata {
    <#
        The label is translated HERE, at read time, not in the schema.

        $script:SettingSchema is built once when the bridge loads, and the
        language is changed from a button while it runs - so a label baked in
        at load would stay in whichever language the bridge started in. The key
        is derived from the setting's own name, and the schema's Arabic label is
        the fallback, so a setting nobody has translated yet reads exactly as it
        always did rather than showing a bare key.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $record = @($script:SettingSchema | Where-Object Name -eq $Name)
    if ($record.Count -ne 1) { return [pscustomobject]@{ Name = $Name; Category = 'advanced'; Label = $Name } }
    $translated = TF "setting.$Name.label" ([string]$record[0].Label)
    if ($translated -eq [string]$record[0].Label) { return $record[0] }
    # A copy, never the schema record itself: mutating it would leave the
    # bridge stuck in whatever language was asked for first.
    $copy = [pscustomobject]@{}
    foreach ($property in $record[0].PSObject.Properties) { $copy | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force }
    $copy.Label = $translated
    return $copy
}

function Get-SettingsInCategory {
    param([Parameter(Mandatory)][string]$Category)
    foreach ($record in @($script:SettingSchema)) {
        if ($record.Category -eq $Category) { $record.Name }
    }
}

function Get-SettingsResetConfirmKeyboard {
    <# The affirming half is coloured, the cancel is not: colouring both
       leaves the thumb with no signal. #>
    return @{ inline_keyboard = @(
            , @((New-Button (T 'confirm.resetYes') 'cfg:resetconfirm' -Style danger), (New-Button (T 'common.cancel') 'menu:settings'))
        ) }
}

function Get-SettingsCategoryPageNames {
    <# The settings on one page of a category. Shared, so the text above the
       keyboard describes the same eight settings the buttons under it act
       on - two slices of one list are two answers waiting to disagree. #>
    param(
        [Parameter(Mandatory)][string]$Category,
        [ValidateRange(0, [int]::MaxValue)][int]$Page = 0,
        [ValidateRange(1, 20)][int]$PageSize = 8
    )
    $names = @(Get-SettingsInCategory -Category $Category)
    if ($names.Count -eq 0) { return @() }
    $pageCount = [math]::Max(1, [int][math]::Ceiling($names.Count / [double]$PageSize))
    $safePage = [math]::Min($Page, $pageCount - 1)
    $start = $safePage * $PageSize
    $end = [math]::Min($start + $PageSize - 1, $names.Count - 1)
    return @($names[$start..$end])
}

function Get-SettingsKeyboard {
    $rows = @()
    $categoryRow = @()
    foreach ($category in @(Get-SettingCategoryDefinitions)) {
        $categoryRow += (New-Button "$($category.Icon) $($category.Label)" "cfgcat:$($category.Key):0")
        if ($categoryRow.Count -eq 2) {
            $rows += , $categoryRow
            $categoryRow = @()
        }
    }
    if ($categoryRow.Count -gt 0) { $rows += , $categoryRow }

    $rows += , @((New-Button (T 'settings.search') 'cfg:search'), (New-Button (T 'settings.modifiedOnly') 'cfglist:modified:0'))
    $rows += , @((New-Button (T 'settings.simple') 'cfglist:simple:0'), (New-Button (T 'settings.advanced') 'cfglist:advanced:0'))

    $scope = [string](Get-Setting 'HideAllLayers')
    $scopeLabel = if ($scope.Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) { T 'settings.hideAllScope.all' } elseif ($scope.Trim()) { T 'settings.hideAllScope.some' $scope } else { T 'settings.hideAllScope.none' }
    $rows += , @( (New-Button (T 'settings.hideAllScope' $scopeLabel) 'menu:hideallsettings') )
    $rows += , @( (New-Button (T 'settings.layerNames') 'menu:layernames') )
    # The language row sits here rather than only inside 🛠 خيارات متقدمة,
    # because the first thing somebody who cannot read the screen needs is the
    # control that changes the screen - and they cannot read their way to it.
    # The button names the language it switches TO, not the one in force.
    $rows += , @( (New-Button (T 'lang.button') 'cfg:lang') )
    $rows += , @( (New-Button (T 'settings.backups') "menu:backups"), (New-Button (T 'settings.reset') "cfg:reset" -Style danger) )
    $rows += , @( (New-Button (T 'kb.back') "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-SettingsListKeyboard {
    param([AllowEmptyCollection()][object[]]$Records = @(), [string]$Mode = 'simple', [int]$Page = 0, [int]$PageSize = 8)
    $items = @($Records)
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize $PageSize
    $rows = @()
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $record = $items[$index]
            $name = [string]$record.Name
            $value = Get-Setting $name
            $action = if ($script:DefaultSettings[$name] -is [bool]) { "cfg:t:$name" } elseif ($name -eq 'TemplateMaxAirSeconds' -or $script:DefaultSettings[$name] -is [string]) { "cfg:s:$name" } else { "cfg:v:$name" }
            $rows += , @((New-Button "$($record.Label) = $(Protect-SettingDisplayValue -Name $name -Value $value)" $action), (New-Button '↩️' "cfgr:$name"))
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button '⬅️' "cfglist:${Mode}:$($window.Page - 1)") }
        if ($window.HasNext) { $pager += (New-Button '➡️' "cfglist:${Mode}:$($window.Page + 1)") }
        $rows += , $pager
    }
    if ($items.Count -eq 0) { $rows += , @((New-Button (T 'common.noResults') 'menu:settings')) }
    $rows += , @((New-Button (T 'kb.backToSettings') 'menu:settings'))
    return @{ inline_keyboard = $rows }
}

function Get-SingleSettingResetConfirmKeyboard {
    param([Parameter(Mandatory)][string]$Name)
    return @{ inline_keyboard = @(, @((New-Button (T 'kb.resetThisSetting') "cfgrgo:$Name" -Style danger), (New-Button (T 'common.cancel') 'menu:settings'))) }
}

function Get-SettingsCategoryKeyboard {
    param(
        [Parameter(Mandatory)][string]$Category,
        [ValidateRange(0, [int]::MaxValue)][int]$Page = 0,
        [ValidateRange(1, 20)][int]$PageSize = 8
    )
    $definition = @($script:SettingCategoryDefinitions | Where-Object { $_.Key -eq $Category })
    if ($definition.Count -ne 1) { return (Get-SettingsKeyboard) }

    $names = @(Get-SettingsInCategory -Category $Category)
    $pageCount = [math]::Max(1, [int][math]::Ceiling($names.Count / [double]$PageSize))
    $safePage = [math]::Min($Page, $pageCount - 1)
    $rows = @()

    if ($names.Count -gt 0) {
        foreach ($name in @(Get-SettingsCategoryPageNames -Category $Category -Page $Page -PageSize $PageSize)) {
            $value = Get-Setting $name
            $metadata = Get-SettingNavigationMetadata -Name $name
            if ($name -eq 'HideAllLayers') {
                $scope = [string]$value
                $scopeLabel = if ($scope.Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) {
                    (T 'kb.allKnownLayers')
                }
                elseif ($scope.Trim()) { (T 'kb.layers' $scope) }
                else { (T 'kb.noLayersChosen') }
                $rows += , @( (New-Button "🚨 $($metadata.Label) · $scopeLabel" 'menu:hideallsettings' -MaxTextLength 64) )
            }
            elseif ($name -eq 'LayerNames') {
                $namedLayers = @([string]$value -split ';' | Where-Object { $_.Trim() -match '^\d+\s*=\s*.+$' }).Count
                $rows += , @( (New-Button (T 'kb.namedLayers' $($metadata.Label) $namedLayers) 'menu:layernames' -MaxTextLength 64) )
            }
            elseif ($script:DefaultSettings[$name] -is [bool]) {
                $mark = if ($value) { '✅' } else { '❌' }
                $state = if ($value) { (T 'kb.on') } else { (T 'kb.off') }
                $lock = if ($script:ProtectedSettings -contains $name) { '🔒 ' } else { '' }
                $rows += , @( (New-Button "$mark $lock$($metadata.Label) · $state" "cfg:t:$name" -MaxTextLength 64) )
            }
            elseif ($name -eq 'TemplateMaxAirSeconds') {
                $rows += , @((New-Button "⏱ $($metadata.Label)" 'cfg:s:TemplateMaxAirSeconds'))
            }
            elseif ($script:DefaultSettings[$name] -is [string]) {
                $prefix = if ($name -eq 'NewsFilePath') { (T 'kb.newsFile') } else { "🔤 $($metadata.Label)" }
                $rows += , @( (New-Button "$prefix · $(Protect-SettingDisplayValue -Name $name -Value $value)" "cfg:s:$name" -MaxTextLength 64) )
            }
            else {
                $display = Format-SettingDisplay -Name $name -Value $value
                $rows += , @( (New-Button "🔢 $($metadata.Label) · $display" "cfg:v:$name" -MaxTextLength 64) )
            }
        }
    }

    if ($pageCount -gt 1) {
        $navigation = @()
        if ($safePage -gt 0) { $navigation += (New-Button (T 'common.previous') "cfgcat:$Category`:$($safePage - 1)") }
        $navigation += (New-Button "$($safePage + 1)/$pageCount" "cfgcat:$Category`:$safePage")
        if ($safePage + 1 -lt $pageCount) { $navigation += (New-Button (T 'common.next') "cfgcat:$Category`:$($safePage + 1)") }
        $rows += , $navigation
    }
    # P4: manual quiet lives with its scheduled sibling. A setting would
    # persist across restarts and lie about it; a two-hour window that dies
    # with the process fails loud.
    if ($Category -eq 'monitoring') {
        if ((Get-Date) -lt $script:ManualQuietUntil) {
            $rows += , @((New-Button (T 'kb.quietUntil' $($script:ManualQuietUntil.ToString('HH:mm'))) 'quiet:off'))
        }
        else {
            $rows += , @((New-Button (T 'kb.quietTwoHours') 'quiet:on'))
        }
    }
    $rows += , @( (New-Button (T 'kb.backToSettingsSections') 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateAdminCatalogueText {
    <#
        P3: the catalogue names the template and its layer on the button;
        the text beside it says when it last went on air - the never-aired
        ones are the deletion candidates, the daily ones earn the shortcut.
        Same window as the keyboard, so text and buttons never disagree.
    #>
    param([int]$Page = 0, [int]$PageSize = 20)
    $store = Get-TemplateStore
    $window = Get-BridgePageWindow -ItemCount $store.Order.Count -Page $Page -PageSize $PageSize
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'kb.pickTemplateToRead'))
    if ($window.EndIndex -ge $window.StartIndex) {
        $lastAir = Get-TemplateLastAirMap
        for ($i = $window.StartIndex; $i -le $window.EndIndex; $i++) {
            $key = [string]$store.Order[$i]
            $when = if ($lastAir.ContainsKey($key)) { Format-TemplateLastAir -Stamp $lastAir[$key] } else { (T 'tpl.neverAired') }
            $lines.Add((T 'kb.lastAired' $(ConvertTo-TelegramHtmlText $key) $when))
        }
    }
    return ($lines -join "`n")
}

function Get-TemplateAdminCatalogueKeyboard {
    param(
        [long]$ChatId = 0,
        [long]$UserId = 0,
        [int]$Page = 0,
        [ValidateRange(1, 40)][int]$PageSize = 20
    )
    if ($UserId -eq 0 -and $ChatId -ne 0) { $UserId = $ChatId }
    $canAdminister = ($ChatId -eq 0) -or (Test-Admin -ChatId $ChatId -UserId $UserId)
    $store = Get-TemplateStore
    $rows = @()
    $window = Get-BridgePageWindow -ItemCount $store.Order.Count -Page $Page -PageSize $PageSize
    if ($window.EndIndex -ge $window.StartIndex) {
    for ($i = $window.StartIndex; $i -le $window.EndIndex; $i++) {
        $template = $store.Map[$store.Order[$i]]
        $rows += , @( (New-Button (T 'kb.nameAndLayer' $($template.Key) $($template.Layer)) "tadm:$i") )
    }
    }
    if ($canAdminister) {
        $transferRow = @((New-Button (T 'kb.exportJson') 'timport:export'))
        if (Get-Setting 'EnableFullTemplateManagement') { $transferRow += (New-Button (T 'kb.importJson') 'timport:start') }
        $rows += , $transferRow
        # Beside import/export because it undoes them, and every other writer
        # of the registry too. Shown only when there is something to restore:
        # a button that opens an empty screen teaches nothing but its own
        # emptiness.
        $backupCount = @(Get-TemplateBackupFiles).Count
        if ($backupCount -gt 0) {
            $rows += , @( (New-Button (T 'kb.templateBackupsCount' $backupCount) 'tplbak:list') )
        }
    }
    if ($canAdminister -and (Get-Setting 'EnableFullTemplateManagement')) {
        $rows += , @( (New-Button (T 'kb.addTemplate') 'tadm:create') )
        $rows += , @( (New-Button (T 'kb.addViaJson') 'tadm:createjson') )
        # D2: the "skipped" warning as a work list, beside the tools that
        # create the entries it cleans up.
        $invalidCount = @(Get-InvalidTemplateEntries).Count
        if ($invalidCount -gt 0) {
            $rows += , @( (New-Button (T 'kb.invalidTemplatesCount' $invalidCount) 'tpladmin:invalid') )
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'common.previous') "tadmpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "tadmpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'common.next') "tadmpage:$($window.Page + 1)") }
        $rows += , $pager
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button (T 'templates.noValid') 'menu') ) }
    $rows += , @( (New-Button (T 'adm.menu') 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateAdminDetailKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex, [long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0 -and $ChatId -ne 0) { $UserId = $ChatId }
    $canAdminister = ($ChatId -eq 0) -or (Test-Admin -ChatId $ChatId -UserId $UserId)
    $canManageReminder = ($ChatId -eq 0) -or (Test-TemplateReminderManager -ChatId $ChatId -UserId $UserId)
    $rows = @()
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if ($canManageReminder -and $template -and -not [bool](Get-JsonProp $template 'LongRunning')) {
        $rows += , @( (New-Button (T 'kb.appearAlert') "tadm:reminder:$TemplateIndex") )
    }
    if ($canAdminister -and (Get-Setting 'EnableFullTemplateManagement')) {
        $rows += , @( (New-Button (T 'kb.editDefinition') "tadm:edit:$TemplateIndex"), (New-Button (T 'kb.deleteTemplate') "tadm:delete:$TemplateIndex" -Style danger) )
        if ((Get-SettingInt 'TemplateTestLayer' 0) -gt 0) { $rows += , @((New-Button (T 'kb.testOnTrialLayer') "tadm:test:$TemplateIndex")) }
    }
    $rows += , @( (New-Button (T 'templates.back') 'menu:templatesadmin') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateDefinitionReviewKeyboard {
    return @{ inline_keyboard = @(
        , @( (New-Button (T 'common.saveChange') 'tadm:confirm' -Style success), (New-Button (T 'common.cancel') 'menu:templatesadmin') )
    ) }
}

function Get-HideAllLayerSettingsKeyboard {
    $selected = @(Get-HideAllTargetLayers)
    $allMode = ([string](Get-Setting 'HideAllLayers')).Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)
    $rows = @()
    foreach ($layer in @(Get-KnownLayers | ForEach-Object { [int]$_ } | Sort-Object -Unique)) {
        $mark = if ($allMode -or $selected -contains $layer) { '✅' } else { '⬜' }
        $rows += , @( (New-Button (T 'kb.countLayer' $mark $layer) "hideallcfg:toggle:$layer") )
    }
    $rows += , @( (New-Button (T 'kb.selectAllLayers') 'hideallcfg:all'), (New-Button (T 'kb.selectNoLayers') 'hideallcfg:none') )
    $rows += , @( (New-Button (T 'kb.backToSettings') 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerNamesKeyboard {
    $rows = @()
    foreach ($layer in @(Get-KnownLayers | ForEach-Object { [int]$_ } | Sort-Object -Unique)) {
        $rows += , @( (New-Button "🏷️ $(Get-LayerDisplayName -Layer $layer)" "layername:$layer") )
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button (T 'kb.noLayersDefined') 'menu:settings') ) }
    $rows += , @( (New-Button (T 'kb.backToSettings') 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerNameEditKeyboard {
    param([Parameter(Mandatory)][int]$Layer)
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'kb.clearName') "layername:clear:$Layer" -Style danger) )
            , @( (New-Button (T 'kb.backToLayerNames') 'menu:layernames'), (New-Button (T 'common.cancel') 'menu:settings') )
        ) }
}

function Get-TemplateBackupsText {
    <# Which saved registry is which. Age is what tells an administrator
       whether a copy predates the edit being undone, so it is here beside
       the timestamp rather than left to arithmetic. #>
    param([string]$Path = (Get-TemplateRegistryFilePath))
    $files = @(Get-TemplateBackupFiles -Path $Path)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'kb.templateBackups'))
    if ($files.Count -eq 0) {
        $lines.Add((T 'kb.noTemplateBackups'))
        return ($lines -join "`n")
    }
    $lines.Add((T 'kb.backupCount' $($files.Count)))
    $lines.Add('')
    for ($i = 0; $i -lt $files.Count; $i++) {
        $age = [int]([math]::Max(0.0, ((Get-Date) - $files[$i].LastWriteTime).TotalMinutes))
        $lines.Add((T 'kb.backupRow' $($i + 1) $($files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm')) $(if ($age -lt 1) { (T 'kb.now') } else { (T 'kb.ago' $(Format-DurationMinutes -Minutes $age)) })))
    }
    $lines.Add('')
    $lines.Add((T 'kb.restoreShowsDiff'))
    return ($lines -join "`n")
}

function Get-TemplateBackupsKeyboard {
    param([string]$Path = (Get-TemplateRegistryFilePath))
    $files = @(Get-TemplateBackupFiles -Path $Path)
    $rows = @()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $rows += , @( (New-Button "$($i + 1). 🗄 $($files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))" "tplbak:restore:$i" -Style danger) )
    }
    if ($files.Count -eq 0) { $rows += , @( (New-Button (T 'kb.noBackupsKept') 'menu:templatesadmin') ) }
    $rows += , @( (New-Button (T 'kb.back') 'menu:templatesadmin') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateRestoreConfirmKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'kb.yesRestoreThis') 'tplbak:confirm' -Style danger), (New-Button (T 'common.cancel') 'tplbak:list') )
        ) }
}

function Get-TemplateRestorePreviewText {
    <#
        What the restore will do, named template by template.

        A count says something will change and nothing about whether it is
        the change being undone; the names are the only thing an
        administrator can check against what they remember doing. The lists
        are capped because a restore across a large registry would otherwise
        put every key on one screen and cross the payload limit.
    #>
    param([Parameter(Mandatory)]$Comparison, [Parameter(Mandatory)][datetime]$BackupTime)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'kb.confirmTemplateRestore'))
    $lines.Add((T 'kb.backupIs' $($BackupTime.ToString('yyyy-MM-dd HH:mm'))))
    $lines.Add('')
    foreach ($group in @(
            @{ Label = (T 'kb.willBeDeleted'); Keys = @($Comparison.Removed) }
            @{ Label = (T 'kb.willChange'); Keys = @($Comparison.Changed) }
            @{ Label = (T 'kb.willBeAdded'); Keys = @($Comparison.Added) }
        )) {
        if (@($group.Keys).Count -eq 0) { continue }
        $shown = @(@($group.Keys) | Select-Object -First 10)
        $line = "$($group.Label) (<code>$(@($group.Keys).Count)</code>): $(ConvertTo-TelegramHtmlText ($shown -join (T 'common.comma')))"
        if (@($group.Keys).Count -gt $shown.Count) { $line += (T 'kb.andOthers' $(@($group.Keys).Count - $shown.Count)) }
        $lines.Add($line)
    }
    if (@($Comparison.Removed).Count -eq 0 -and @($Comparison.Changed).Count -eq 0 -and @($Comparison.Added).Count -eq 0) {
        $lines.Add((T 'kb.noDifference'))
    }
    $lines.Add('')
    $lines.Add((T 'kb.restoreIsUndoable'))
    return ($lines -join "`n")
}

function Get-ConfigBackupFiles {
    <#
        The saved configurations, newest first.

        One reader for the list, the keyboard and the restore itself, so the
        row that is pressed is the file that is read. It also stops the
        listing being written three times with an if-expression: that hands
        back a single file as the file and no files as $null, and the .Count
        each caller does on it then throws - on the empty screen, which is
        exactly where nobody is watching.
    #>
    param([string]$Path = $ConfigPath)
    $backupDirectory = "$Path.backups"
    if (-not (Test-Path -LiteralPath $backupDirectory)) { return @() }
    return @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc, Name -Descending)
}

function Get-ConfigBackupsText {
    <# Which saved configuration is which. The buttons carried a timestamp
       and nothing else; how long ago it was written is what tells an
       administrator whether it predates the change they are undoing. #>
    param([string]$Path = $ConfigPath)
    $files = @(Get-ConfigBackupFiles -Path $Path)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'kb.settingsBackups'))
    if ($files.Count -eq 0) {
        $lines.Add((T 'kb.noSettingsBackups'))
        return ($lines -join "`n")
    }
    $lines.Add((T 'kb.backupCount' $($files.Count)))
    $lines.Add('')
    for ($i = 0; $i -lt $files.Count; $i++) {
        $age = [int]([math]::Max(0, ((Get-Date) - $files[$i].LastWriteTime).TotalMinutes))
        $lines.Add((T 'kb.backupRow' $($i + 1) $($files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm')) $(if ($age -lt 1) { (T 'kb.now') } else { (T 'kb.ago' $(Format-DurationMinutes -Minutes $age)) })))
    }
    $lines.Add('')
    $lines.Add((T 'kb.settingsRestoreNote'))
    return ($lines -join "`n")
}

function Get-ConfigBackupsKeyboard {
    param([string]$Path = $ConfigPath)
    $files = @(Get-ConfigBackupFiles -Path $Path)
    $rows = @()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $label = $files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $rows += , @( (New-Button "$($i + 1). 🗄 $label" "cfg:restore:$i" -Style danger) )
    }
    if ($files.Count -eq 0) { $rows += , @( (New-Button (T 'kb.noBackupsKept') 'menu:settings') ) }
    $rows += , @( (New-Button (T 'kb.back') 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-ConfigRestoreConfirmKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'kb.yesRestoreBackup') 'cfg:restoreconfirm' -Style danger), (New-Button (T 'common.cancel') 'menu:backups') )
        ) }
}

function Get-SettingConfirmKeyboard {
    param([Parameter(Mandatory)][string]$Name)
    return @{ inline_keyboard = @( , @( (New-Button (T 'kb.yesDisableProtection') "cfgc:$Name" -Style danger), (New-Button (T 'common.cancel') "menu:settings") ) ) }
}

function Get-AutoHideChoices {
    <# Quick-pick durations, parsed from the AutoHidePresetSeconds setting so
       an admin can retune them without touching code. Bad entries are ignored
       rather than breaking the keyboard. #>
    $raw = [string](Get-Setting 'AutoHidePresetSeconds')
    $values = @()
    foreach ($part in ($raw -split '[,;\s]+')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -gt 0) { $values += $n }
    }
    if ($values.Count -eq 0) { $values = @(5, 10, 15, 30, 60) }
    return @($values | Sort-Object -Unique)
}

function Format-Duration {
    <# Kept for its callers, but it no longer counts in minutes for ever: a
       ticker on air since yesterday read as "1560 د", a number the reader has
       to divide twice. Format-DurationSeconds does the counting now. #>
    param([int]$Seconds)
    return (Format-DurationSeconds -Seconds $Seconds)
}

function Get-DurationKeyboard {
    <# Shared duration picker. Prefix 'dur' targets a template about to be
       shown; 'tlay' targets a layer that is already on air. The default is
       marked so the common case stays one tap. #>
    param(
        [Parameter(Mandatory)][ValidateSet('dur', 'tlay')][string]$Prefix,
        [Parameter(Mandatory)][string]$Token,
        [string]$BackData = 'menu'
    )
    $default = Get-SettingInt 'AutoHideDefaultSeconds' 0
    $rows = @()
    $row = @()
    foreach ($sec in (Get-AutoHideChoices)) {
        $mark = if ($sec -eq $default) { "⭐ " } else { "" }
        $row += (New-Button "$mark$(Format-Duration -Seconds $sec)" "$Prefix`:$Token`:$sec")
        if ($row.Count -eq 3) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button (T 'kb.anotherDuration') "$Prefix`:$Token`:c") )
    $rows += , @( (New-Button (T 'kb.back') $BackData) )
    return @{ inline_keyboard = $rows }
}

function Get-SettingChoiceKeyboard {
    <# String settings are picked from a fixed list rather than typed, so a
       typo cannot quietly break graphics. Index-based callback data keeps it
       inside the 64-byte budget. #>
    param([Parameter(Mandatory)][string]$Name)
    $rows = @()
    $choices = @($script:SettingChoices[$Name])
    $current = [string](Get-Setting $Name)
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $mark = if ($choices[$i] -eq $current) { "✅ " } else { "" }
        $rows += , @( (New-Button "$mark$($choices[$i])" "cfgs:$Name`:$i") )
    }
    $rows += , @( (New-Button (T 'kb.back') "menu:settings") )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateNotifyLabel {
    <# A scope as a person reads it. #>
    param([Parameter(Mandatory)][string]$Scope)
    switch ($Scope) {
        'all' { return (T 'kb.everyone') }
        'admins' { return (T 'kb.adminsOnly') }
        default { return (T 'kb.nobody') }
    }
}

function Get-TemplateNotifyMap {
    <#
        The notification rules as a map, template to scope.

        Read from the one setting rather than kept beside it: the setting is
        what an administrator can still edit by hand, export, and read in a
        backup, and a second copy of the same fact is a second thing to keep
        in step.
    #>
    $map = [ordered]@{}
    foreach ($rule in (([string](Get-Setting 'TemplateNotifyRules')) -split ',')) {
        $parts = @($rule -split '=', 2 | ForEach-Object { $_.Trim() })
        $name = [string]$parts[0]
        if (-not $name) { continue }
        $scope = if ($parts.Count -gt 1) { ([string]$parts[1]).ToLowerInvariant() } else { 'all' }
        if ($scope -notin @('none', 'admins', 'all')) { $scope = 'all' }
        $map[$name] = $scope
    }
    return $map
}

function Set-TemplateNotifyRule {
    <#
        Sets one template's scope and writes the setting back.

        Rules for templates the registry no longer has are kept: a template
        renamed this morning and restored this afternoon should not have lost
        the newsroom's decision about it in between, and dropping a line
        nobody asked to drop is how a settings screen loses trust.
    #>
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][ValidateSet('none', 'admins', 'all')][string]$Scope)
    $map = Get-TemplateNotifyMap
    $map[$Key] = $Scope
    $rules = @(foreach ($name in $map.Keys) {
            if ([string]$map[$name] -eq 'none') { continue }   # silence is the default; no need to store it
            "$name=$($map[$name])"
        })
    Set-Setting -Name 'TemplateNotifyRules' -Value ($rules -join ', ')
    return $Scope
}

function Get-TemplateNotifyKeyboard {
    <#
        Every template, each showing what it will do when it goes on air, and
        each a button that cycles: nobody, administrators, everyone.

        Typing "Urgent=all, Banner=admins" is a syntax to remember, a template
        name to spell exactly, and a scope word in a language the screen does
        not otherwise use - three ways to be silently wrong for a setting
        whose whole purpose is that somebody hears. Tapping cannot misspell a
        template that exists, and shows the current answer for every one of
        them at once.

        Paged like the other pickers, and addressed by absolute position: a
        callback carries 64 bytes and a template name does not always fit in
        what is left.
    #>
    param([int]$Page = 0, [ValidateRange(2, 40)][int]$PageSize = 12)
    $keys = @(@((Get-TemplateStore).Order) | ForEach-Object { [string]$_ })
    $map = Get-TemplateNotifyMap
    $rows = @()
    $window = Get-BridgePageWindow -ItemCount $keys.Count -Page $Page -PageSize $PageSize
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $key = $keys[$index]
            $scope = if ($map.Contains($key)) { [string]$map[$key] } else { 'none' }
            $rows += , @((New-Button "$key — $(Get-TemplateNotifyLabel -Scope $scope)" "tnfy:c:$index"))
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.Page -gt 0) { $pager += New-Button (T 'common.previous') "tnfy:p:$($window.Page - 1)" }
        if ($window.Page -lt $window.PageCount - 1) { $pager += New-Button (T 'common.next') "tnfy:p:$($window.Page + 1)" }
        if ($pager.Count -gt 0) { $rows += , @($pager) }
    }
    $rows += , @((New-Button (T 'kb.back') 'menu:settings'))
    return @{ inline_keyboard = $rows }
}

function Show-TemplateNotifyEditor {
    <# The screen. Re-drawn in place on every tap so the list does not grow a
       copy of itself down the chat with each change. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $lines = @(
        (T 'kb.showNoticeByTemplate')
        (T 'kb.tapToCycle')
        (T 'kb.noticeCarries')
    )
    $text = $lines -join "`n"
    $keyboard = Get-TemplateNotifyKeyboard -Page $Page
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ParseMode HTML -ReplyMarkup $keyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML -ReplyMarkup $keyboard
}

function Show-TemplateMaxAirEditor {
    param([long]$ChatId, [long]$UserId = 0, [int]$MessageId = 0, [int]$Page = 0, [switch]$KeepState)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-CallbackAdmin -ChatId $ChatId -UserId $UserId)) { return }
    $state = Get-PendingState -ChatId $ChatId
    if (-not $KeepState -or -not $state -or [string](Get-JsonProp $state 'Mode') -ne 'template_max_air') {
        $state = @{ Mode = 'template_max_air'; UserId = $UserId; StartedAt = (Get-Date)
            Token = [guid]::NewGuid().ToString('N').Substring(0,12); Keys = @((Get-TemplateStore).Order); Key = ''; ConfirmDisable = $false }
        Set-PendingState -ChatId $ChatId -State $state
    }
    $prefix = "tmax:$($state.Token)"
    $rows = @()
    $text = (T 'kb.perTemplateCeiling')
    if (-not $state.Key) {
        $window = Get-BridgePageWindow -ItemCount @($state.Keys).Count -Page $Page -PageSize 8
        if ($window.EndIndex -ge $window.StartIndex) {
            foreach ($index in $window.StartIndex..$window.EndIndex) {
                $key = [string]$state.Keys[$index]
                $maximum = [int](Get-JsonProp (Get-Setting 'TemplateMaxAirSeconds') $key)
                $label = if ($maximum -gt 0) { (T 'kb.seconds' $maximum) } else { (T 'common.notSet') }
                $rows += , @((New-Button "$key — $label" "${prefix}:item:$index"))
            }
        }
        $nav = @()
        if ($window.HasPrevious) { $nav += New-Button (T 'common.previous') "${prefix}:page:$($window.Page - 1)" }
        if ($window.HasNext) { $nav += New-Button (T 'common.next') "${prefix}:page:$($window.Page + 1)" }
        if ($nav.Count) { $rows += , $nav }
    }
    else {
        $current = [int](Get-JsonProp (Get-Setting 'TemplateMaxAirSeconds') ([string]$state.Key))
        $shownKey = [string]$state.Key
        if ($shownKey.Length -gt 100) { $shownKey = $shownKey.Substring(0,100) }
        $text = (T 'kb.ceilingScreen' $shownKey $current)
        $rows += , @((New-Button (T 'kb.thirtySeconds') "${prefix}:set:30"), (New-Button (T 'kb.oneMinute') "${prefix}:set:60"), (New-Button (T 'kb.twoMinutes') "${prefix}:set:120"))
        $rows += , @((New-Button (T 'kb.threeMinutes') "${prefix}:set:180"), (New-Button (T 'kb.fiveMinutes') "${prefix}:set:300"), (New-Button (T 'kb.tenMinutes') "${prefix}:set:600"))
        $rows += , @((New-Button (T 'kb.minusTenSeconds') "${prefix}:delta:-10"), (New-Button (T 'kb.plusTenSeconds') "${prefix}:delta:10"))
        $rows += , @((New-Button (T 'kb.minusOneSecond') "${prefix}:delta:-1"), (New-Button (T 'kb.plusOneSecond') "${prefix}:delta:1"))
        $rows += , @((New-Button (T 'kb.customAmount') "${prefix}:custom:ask"))
        if ($state.ConfirmDisable) {
            $text += (T 'kb.confirmCeilingRemoval')
            $rows += , @((New-Button (T 'kb.yesRemoveCeiling') "${prefix}:disable:yes" -Style danger))
        }
        else { $rows += , @((New-Button (T 'kb.removeCeiling') "${prefix}:disable:ask")) }
        $rows += , @((New-Button (T 'templates.back') "${prefix}:page:0"), (New-Button (T 'kb.applyNow') "${prefix}:now:yes"))
        $text += (T 'kb.applyNowExplain')
        $text += (T 'kb.customAmountExplain')
    }
    $rows += , @((New-Button (T 'kb.backToSettings') 'menu:settings'))
    $keyboard = @{ inline_keyboard = $rows }
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard
}

function Invoke-TemplateMaxAirPick {
    param([long]$ChatId, [long]$UserId = 0, [string]$Argument, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-CallbackAdmin -ChatId $ChatId -UserId $UserId)) { return $false }
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string](Get-JsonProp $state 'Mode') -ne 'template_max_air' -or
        [long](Get-JsonProp $state 'UserId') -ne $UserId -or
        $Argument -notmatch '^([a-f0-9]{12}):(item|page|set|delta|disable|now):(-?[0-9]{1,4}|ask|yes)$' -or
        $Matches[1] -cne [string](Get-JsonProp $state 'Token')) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.buttonsExpired')
        return $false
    }
    $action = $Matches[2]; $value = $Matches[3]; $page = 0
    $state.StartedAt = Get-Date
    if ($action -in @('page','item')) {
        $index = 0
        if (-not [int]::TryParse($value, [ref]$index) -or $index -lt 0) { return $false }
        $state.ConfirmDisable = $false
        $state.Token = [guid]::NewGuid().ToString('N').Substring(0,12)
        if ($action -eq 'page') { $state.Key = ''; $page = $index }
        else {
            if ($index -ge @($state.Keys).Count) { return $false }
            $state.Key = [string]$state.Keys[$index]
        }
    }
    else {
        $key = [string]$state.Key
        if (-not $key -or -not (Get-TemplateStore).Map.ContainsKey($key)) { return $false }
        if ($action -eq 'now') {
            if ($value -ne 'yes') { return $false }
            if (Request-TemplateAirLimitNow -Key $key -ChatId $ChatId -UserId $UserId) {
                Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.currentShowShortened' $key)
            }
            else { Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.noShowOverCeiling') }
        }
        elseif ($action -eq 'custom') {
            if ($value -eq 'ask') {
                Set-PendingState -ChatId $ChatId -State @{ Mode = 'template_max_air_custom'; UserId = $UserId; Key = $key; StartedAt = (Get-Date) }
                Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.sendDuration')
            }
            return $false
        }
        elseif ($action -eq 'disable' -and $value -eq 'ask') { $state.ConfirmDisable = $true }
        else {
            $seconds = 0
            if ($action -eq 'disable') {
                if ($value -ne 'yes' -or -not $state.ConfirmDisable) { return $false }
            }
            else {
                if (-not [int]::TryParse($value, [ref]$seconds)) { return $false }
                if ($action -eq 'delta') {
                    if ($seconds -notin @(-10,-1,1,10)) { return $false }
                    $seconds += [int](Get-JsonProp (Get-Setting 'TemplateMaxAirSeconds') $key)
                    $seconds = [math]::Max(1,[math]::Min(3600,$seconds))
                }
                if ($seconds -lt 1 -or $seconds -gt 3600) { return $false }
            }
            $previous = Get-Setting 'TemplateMaxAirSeconds'
            $map = @{}
            if ($previous) { $map = ($previous | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable) }
            if ($seconds -eq 0) { $map.Remove($key) } else { $map[$key] = $seconds }
            $script:LastConfigSaveFailed = $false
            Set-Setting -Name TemplateMaxAirSeconds -Value $map
            if ($script:LastConfigSaveFailed) {
                Set-JsonProp $config.Settings 'TemplateMaxAirSeconds' $previous
                Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.ceilingNotSaved')
                return $false
            }
            $state.ConfirmDisable = $false
            Write-BridgeLog "Template maximum on-air policy updated by $UserId to $seconds seconds."
        }
    }
    Show-TemplateMaxAirEditor -ChatId $ChatId -UserId $UserId -MessageId $MessageId -Page $page -KeepState
    return $true
}

function Get-SettingBounds {
    <# What this number may be, as a pair. An undeclared setting is bounded
       only below zero: no setting here means anything negative, and a minus
       sign typed into a timeout has never once been intended. #>
    param([Parameter(Mandatory)][string]$Name)
    $minimum = 0
    $maximum = [int]::MaxValue
    if ($script:SettingConstraints.ContainsKey($Name)) {
        $bounds = $script:SettingConstraints[$Name]
        if ($null -ne $bounds.Minimum) { $minimum = [int]$bounds.Minimum }
        if ($null -ne $bounds.Maximum) { $maximum = [int]$bounds.Maximum }
    }
    return [pscustomobject]@{ Minimum = $minimum; Maximum = $maximum }
}

function Get-SettingStep {
    <#
        How much one tap moves this number.

        From its own size rather than a table: a poll interval of 1 second
        wants to move by one, a retention of 5000 lines does not want fifty
        taps to reach 5500. Rounded to something a person would say - 1, 5,
        10, 100, 1000 - which keeps every setting about the same number of
        taps from anywhere it is likely to go.
    #>
    param([Parameter(Mandatory)][int]$Value)
    $magnitude = [math]::Abs($Value)
    if ($magnitude -le 20) { return 1 }
    if ($magnitude -le 120) { return 5 }
    if ($magnitude -le 1000) { return 10 }
    if ($magnitude -le 10000) { return 100 }
    return 1000
}

function Get-SettingStepperKeyboard {
    <# Minus and plus around the value, then the three answers people actually
       want - the default, the floor, the ceiling - and a way back to typing
       for the one person in ten who knows the exact number they need. #>
    param([Parameter(Mandatory)][string]$Name)
    $current = [int](Get-Setting $Name)
    $bounds = Get-SettingBounds -Name $Name
    # A range small enough to show whole is shown whole. An hour of the day
    # has twenty-four possible answers and a weekday has seven; stepping to
    # them one tap at a time is arithmetic in place of a choice.
    if (($bounds.Maximum - $bounds.Minimum) -le 23 -and $script:SettingConstraints.ContainsKey($Name)) {
        return Get-SettingSmallRangeKeyboard -Name $Name
    }
    $step = Get-SettingStep -Value $current
    $rows = @()
    $rows += , @(
        (New-Button "➖ $step" "num:${Name}:-$step")
        (New-Button "$current" "num:${Name}:noop")
        (New-Button "➕ $step" "num:${Name}:+$step")
    )
    $presets = @()
    $default = [int]$script:DefaultSettings[$Name]
    if ($current -ne $default) { $presets += New-Button (T 'kb.defaultIs' $default) "num:${Name}:def" }
    if ($script:SettingConstraints.ContainsKey($Name)) {
        if ($current -ne $bounds.Minimum) { $presets += New-Button (T 'kb.lowest' $($bounds.Minimum)) "num:${Name}:min" }
        if ($current -ne $bounds.Maximum -and $bounds.Maximum -lt [int]::MaxValue) { $presets += New-Button (T 'kb.highest' $($bounds.Maximum)) "num:${Name}:max" }
    }
    for ($index = 0; $index -lt $presets.Count; $index += 2) {
        $pair = @($presets[$index])
        if ($index + 1 -lt $presets.Count) { $pair += $presets[$index + 1] }
        $rows += , @($pair)
    }
    $rows += , @((New-Button (T 'common.typeNumber') "num:${Name}:type"), (New-Button (T 'kb.back') 'menu:settings'))
    return @{ inline_keyboard = $rows }
}

function Get-SettingRangeLabel {
    <# A value as it is read rather than as it is stored: a weekday by its
       name, an hour as a clock time, anything else as itself. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Value)
    if ($Name -match 'DayOfWeek') {
        $days = @((T 'day.sunday'), (T 'day.monday'), (T 'day.tuesday'), (T 'day.wednesday'), (T 'day.thursday'), (T 'day.friday'), (T 'day.saturday'))
        if ($Value -ge 0 -and $Value -lt $days.Count) { return $days[$Value] }
    }
    if ($Name -match 'Hour') { return ('{0:00}:00' -f $Value) }
    return [string]$Value
}

function Get-SettingSmallRangeKeyboard {
    <# Every value the setting may hold, the current one marked. Six to a row,
       so a full day of hours is four rows and still legible on a phone. #>
    param([Parameter(Mandatory)][string]$Name)
    $bounds = Get-SettingBounds -Name $Name
    $current = [int](Get-Setting $Name)
    $buttons = @(foreach ($value in $bounds.Minimum..$bounds.Maximum) {
            $label = Get-SettingRangeLabel -Name $Name -Value $value
            if ($value -eq $current) { $label = "• $label" }
            New-Button $label "num:${Name}:=$value"
        })
    $perRow = if ($Name -match 'DayOfWeek') { 4 } else { 6 }
    $rows = @()
    for ($index = 0; $index -lt $buttons.Count; $index += $perRow) {
        $rows += , @($buttons[$index..([math]::Min($index + $perRow - 1, $buttons.Count - 1))])
    }
    $rows += , @((New-Button (T 'kb.back') 'menu:settings'))
    return @{ inline_keyboard = $rows; KeepRows = $true }
}

function Show-SettingTimePicker {
    <#
        A time of day, picked from a clock face rather than typed.

        MaintenanceWindowStart and MaintenanceWindowEnd are stored as "HH:mm"
        and were free text: "8:00", "٨:٠٠", "20.00" and an empty string all
        looked like an answer while the window silently did nothing.

        Two taps: the hour, then the quarter. Quarters rather than every
        minute because a maintenance window is agreed in quarters, and sixty
        buttons is not a screen.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0,
        [int]$Hour = -1, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $label = if ($script:SettingNavigationLabels.Contains($Name)) { [string]$script:SettingNavigationLabels[$Name] } else { $Name }
    $current = [string](Get-Setting $Name)
    $shown = if ($current) { $current } else { (T 'kb.notSet') }
    $rows = @()
    if ($Hour -lt 0) {
        $buttons = @(foreach ($hour in 0..23) { New-Button ('{0:00}' -f $hour) "tm:${Name}:$hour" })
        for ($index = 0; $index -lt $buttons.Count; $index += 6) {
            $rows += , @($buttons[$index..([math]::Min($index + 5, $buttons.Count - 1))])
        }
        # Emptying it is a real answer: no window at all is how maintenance
        # mode is left off, and it had no button.
        $rows += , @((New-Button (T 'kb.noTiming') "tm:${Name}:clear"))
        $text = (T 'kb.pickHour' $(ConvertTo-TelegramHtmlText $label) $shown)
    }
    else {
        $buttons = @(foreach ($minute in @(0, 15, 30, 45)) { New-Button ('{0:00}:{1:00}' -f $Hour, $minute) "tm:${Name}:${Hour}:$minute" })
        $rows += , @($buttons)
        $rows += , @((New-Button (T 'kb.anotherHour') "tm:${Name}:pick"))
        $text = (T 'kb.pickMinute' $(ConvertTo-TelegramHtmlText $label) $('{0:00}' -f $Hour))
    }
    $rows += , @((New-Button (T 'kb.back') 'menu:settings'))
    $keyboard = @{ inline_keyboard = $rows; KeepRows = $true }
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ParseMode HTML -ReplyMarkup $keyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML -ReplyMarkup $keyboard
}

function Set-SettingTime {
    <# Writes "HH:mm", or empties the setting. #>
    param([Parameter(Mandatory)][string]$Name, [int]$Hour = -1, [int]$Minute = 0, [long]$UserId = 0)
    $value = if ($Hour -lt 0) { '' } else { '{0:00}:{1:00}' -f $Hour, $Minute }
    Set-Setting -Name $Name -Value $value
    Write-BridgeLog "User $UserId set $Name = $value"
    $shown = if ($value) { $value } else { (T 'kb.noTimingPlain') }
    Add-AuditEntry (T 'kb.settingAudit' $Name $shown $(Format-UserAuditActor -UserId $UserId))
    return $value
}

function Show-SettingStepper {
    <#
        A number set by tapping.

        Ninety of this bridge's settings are integers and every one of them
        asked an operator to type a number into a phone keyboard, read back a
        prompt to check the units, and get the digits right first time - while
        standing in a gallery. The value moves by a tap now, and the screen
        shows the range it may move in.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bounds = Get-SettingBounds -Name $Name
    # Read directly: Get-BridgeMapValue lives inside the schema module and is
    # not exported, so calling it here would have thrown on the first tap.
    $display = if ($script:SettingDisplayMetadata.Contains($Name)) { $script:SettingDisplayMetadata[$Name] } else { @{} }
    $unit = if ($display -and $display.Contains('Unit')) { [string]$display['Unit'] } else { '' }
    $label = if ($script:SettingNavigationLabels.Contains($Name)) { [string]$script:SettingNavigationLabels[$Name] } else { $Name }
    $unitPart = if ($unit) { " $unit" } else { '' }
    $rangePart = if ($script:SettingConstraints.ContainsKey($Name)) { (T 'kb.range' $($bounds.Minimum) $($bounds.Maximum)) } else { '' }
    $lines = @(
        "⚙️ <b>$(ConvertTo-TelegramHtmlText $label)</b>"
        "<code>$Name</code>"
        (T 'kb.value' $(Get-Setting $Name) $unitPart)
        (T 'kb.default' $($script:DefaultSettings[$Name]) $rangePart)
    )
    $text = $lines -join "`n"
    $keyboard = Get-SettingStepperKeyboard -Name $Name
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ParseMode HTML -ReplyMarkup $keyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML -ReplyMarkup $keyboard
}

function Set-SettingNumber {
    <#
        Applies one tap, clamped.

        Clamped rather than refused: the person pressing ➕ at the ceiling
        means "as high as it goes", and an error in reply to a button that
        should not have been offered is the screen's fault, not theirs.
        Returns the value it settled on.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Operation, [long]$UserId = 0)
    $bounds = Get-SettingBounds -Name $Name
    $current = [int](Get-Setting $Name)
    $target = switch -Regex ($Operation) {
        '^def$' { [int]$script:DefaultSettings[$Name]; break }
        '^min$' { [int]$bounds.Minimum; break }
        '^max$' { [int]$bounds.Maximum; break }
        '^=\d+$' { [int]($Operation.Substring(1)); break }
        '^[+-]\d+$' { $current + [int]$Operation; break }
        default { $current }
    }
    $target = [math]::Max([int]$bounds.Minimum, [math]::Min([int]$bounds.Maximum, [int]$target))
    if ($target -eq $current) { return $current }
    Set-Setting -Name $Name -Value $target
    Write-BridgeLog "User $UserId set $Name = $target"
    Add-AuditEntry (T 'kb.settingAudit' $Name $target $(Format-UserAuditActor -UserId $UserId))
    return $target
}

# Settings whose value is a set of things the bridge already knows: template
# keys, or layer numbers. Typed, a misspelling reads as "not in the list", so
# a permission quietly protects nothing; picked from what exists it cannot be
# mistyped at all.
$script:SettingPickers = @{
    AdminOnlyTemplateKeys = 'template'
    OwnerOnlyTemplateKeys = 'template'
    AdminOnlyLayers       = 'layer'
    OwnerOnlyLayers       = 'layer'
    # These three were typed, and they are the same kind of list as the four
    # above. A misspelled key in a permission list reads as "not in the list",
    # so the permission quietly protects nothing and nobody finds out until
    # somebody uses what they should not have been able to use.
    DisabledTemplateKeys  = 'template'
    SensitiveTemplateKeys = 'template'
    ReservedLayers        = 'layer'
    # A list of durations, which is a list like the others: typed, it was a
    # comma-separated string where one stray character silently dropped a
    # preset from every hide-timer screen.
    AutoHidePresetSeconds = 'seconds'
}

function Get-SettingPickItems {
    <# What this setting can hold, as it is stored and as it reads. A layer is
       stored as its number but shown by its name, so the administrator picks
       the logo rather than remembering that the logo is layer 9. #>
    param([Parameter(Mandatory)][string]$Name)
    if ([string]$script:SettingPickers[$Name] -eq 'seconds') {
        # The durations a station actually uses, from a strap that blinks to
        # one that holds a quarter of an hour.
        return @(5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600, 900 | ForEach-Object {
                @{ Value = [string]$_; Label = [string](Format-DurationSeconds -Seconds $_) } })
    }
    if ([string]$script:SettingPickers[$Name] -eq 'layer') {
        return @(Get-KnownLayers | ForEach-Object { [int]$_ } | Sort-Object -Unique | ForEach-Object {
                @{ Value = [string]$_; Label = [string](Get-LayerDisplayName -Layer $_) } })
    }
    return @(@((Get-TemplateStore).Order) | ForEach-Object { @{ Value = [string]$_; Label = [string]$_ } })
}

function Get-SettingPickKeyboard {
    <#
        Every candidate, ticked where it is already in the list. Addressed by
        position, because a callback carries 64 bytes and a name does not
        always fit in what is left.

        Paged, and two to a row: a registry of a hundred templates drew a
        hundred rows into one message, which Telegram will not send - so the
        screen that says who may use a template stopped opening on exactly the
        installations big enough to need it.
    #>
    param([Parameter(Mandatory)][string]$Name, [int]$Page = 0, [ValidateRange(2, 40)][int]$PageSize = 20)
    $chosen = @(Get-BridgeKeyList -Value (Get-Setting $Name))
    $items = @(Get-SettingPickItems -Name $Name)
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize $PageSize
    $keyboard = @()
    $pair = @()
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $value = [string]$items[$index].Value
            $mark = if (@($chosen | Where-Object { $_.Equals($value, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { '✅' } else { '⬜' }
            # The page rides along so a tick returns to the page it was on
            # instead of throwing the administrator back to the first.
            $pair += (New-Button "$mark $([string]$items[$index].Label)" "cfgpick:$Name`:$index`:$($window.Page)")
            if ($pair.Count -eq 2) { $keyboard += , $pair; $pair = @() }
        }
    }
    if ($pair.Count -gt 0) { $keyboard += , $pair }
    if ($items.Count -eq 0) { $keyboard += , @((New-Button (T 'kb.noItemsDefined') 'cfgcat:templates')) }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'common.previous') "cfgpickpage:$Name`:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "cfgpickpage:$Name`:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'common.next') "cfgpickpage:$Name`:$($window.Page + 1)") }
        $keyboard += , $pager
    }
    if ($chosen.Count -gt 0) { $keyboard += , @((New-Button (T 'kb.emptyTheList') "cfgpickclear:$Name" -Style danger)) }
    $keyboard += , @((New-Button (T 'common.done') 'cfgcat:templates'))
    return @{ inline_keyboard = $keyboard }
}

function Get-SettingPickText {
    param([Parameter(Mandatory)][string]$Name, [int]$Page = 0, [ValidateRange(2, 40)][int]$PageSize = 20)
    $chosen = @(Get-BridgeKeyList -Value (Get-Setting $Name))
    # The same Arabic name the settings screen shows, falling back to the key
    # itself rather than to nothing.
    $label = if ($script:SettingNavigationLabels.ContainsKey($Name)) { [string]$script:SettingNavigationLabels[$Name] } else { $Name }
    $lines = @("<b>$(ConvertTo-TelegramHtmlText -Text $label)</b>")
    $lines += if ($chosen.Count -eq 0) {
        (T 'kb.nothingChosen')
    }
    else { (T 'kb.chosen' $($chosen.Count) $(ConvertTo-TelegramHtmlText -Text ($chosen -join (T 'common.comma')))) }
    $window = Get-BridgePageWindow -ItemCount (@(Get-SettingPickItems -Name $Name)).Count -Page $Page -PageSize $PageSize
    if ($window.PageCount -gt 1) { $lines += (T 'kb.pageHtml' $($window.Page + 1) $($window.PageCount)) }
    $lines += ''
    $lines += (T 'kb.tapToToggle')
    return ($lines -join "`n")
}

function Show-SettingPicker {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    Send-TelegramMessage -ChatId $ChatId -Text (Get-SettingPickText -Name $Name -Page $Page) -ParseMode HTML `
        -ReplyMarkup (Get-SettingPickKeyboard -Name $Name -Page $Page)
}

function Switch-SettingPick {
    <# One item in or out of the list, saved the way a typed value is saved so
       the log and the audit trail read alike either way. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $items = @(Get-SettingPickItems -Name $Name)
    if ($Index -lt 0 -or $Index -ge $items.Count) { Show-SettingPicker -Name $Name -ChatId $ChatId -UserId $UserId -Page $Page; return }
    $value = [string]$items[$Index].Value
    $existing = @(Get-BridgeKeyList -Value ([string](Get-Setting $Name)))
    $chosen = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $existing) {
        if (-not $item.Equals($value, [StringComparison]::OrdinalIgnoreCase)) { $chosen.Add($item) }
    }
    if ($chosen.Count -eq $existing.Count) { $chosen.Add($value) }
    $stored = ($chosen -join ', ')
    Set-Setting -Name $Name -Value $stored
    Write-BridgeLog "User $UserId set $Name = $stored"
    Add-AuditEntry (T 'kb.settingAudit' $Name $stored $(Format-UserAuditActor -UserId $UserId))
    Show-SettingPicker -Name $Name -ChatId $ChatId -UserId $UserId -Page $Page
}

function Clear-SettingPick {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-Setting -Name $Name -Value ''
    Write-BridgeLog "User $UserId cleared $Name"
    Add-AuditEntry (T 'kb.emptiedAudit' $Name $(Format-UserAuditActor -UserId $UserId))
    Show-SettingPicker -Name $Name -ChatId $ChatId -UserId $UserId
}

function Show-SettingChoices {
    <# String settings come in three flavours: a constrained list
       (AirVariableType) gets a pick-list, a set of templates or layers gets
       them to tick through, and anything else a free-text prompt. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    # A time of day is two taps on a clock, not a string typed in a format
    # nobody is told.
    if ($Name -in @('MaintenanceWindowStart', 'MaintenanceWindowEnd')) {
        Show-SettingTimePicker -Name $Name -ChatId $ChatId -UserId $UserId
        return
    }
    # Not through $script:SettingPickers: that picker ticks a value in or out
    # of a list, and this one has three states per template rather than two.
    if ($Name -eq 'TemplateMaxAirSeconds') {
        Show-TemplateMaxAirEditor -ChatId $ChatId -UserId $UserId
        return
    }
    if ($Name -eq 'TemplateNotifyRules') {
        Show-TemplateNotifyEditor -ChatId $ChatId -UserId $UserId
        return
    }
    if ($script:SettingPickers.ContainsKey($Name)) {
        Show-SettingPicker -Name $Name -ChatId $ChatId -UserId $UserId
        return
    }
    if ($script:SettingChoices.ContainsKey($Name)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.chooseValueFor' $Name) -ReplyMarkup (Get-SettingChoiceKeyboard -Name $Name)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'setting_text'; Name = $Name; UserId = $UserId }
    # Deliberately NOT masked here, unlike the settings lists and the import
    # preview. This prompt is reached only by opening that one setting on
    # purpose, and a join code is a value the administrator has to be able to
    # read in order to hand it to the person they are letting in - masking it
    # everywhere would leave no way to recover it but to overwrite it. The
    # lists are a different case: there the value is shown to somebody who came
    # to look at something else, and it stays in the transcript afterwards.
    $prompt = if ($Name -eq 'NewsFilePath') {
        (T 'kb.sendNewsPath' $(Get-Setting $Name) $($script:DefaultSettings[$Name]))
    }
    else { (T 'kb.sendNewValue' $Name $(Get-Setting $Name) $($script:DefaultSettings[$Name])) }
    Send-TelegramMessage -ChatId $ChatId -Text $prompt -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-SettingText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'common.valueEmpty') -ReplyMarkup (Get-SettingsKeyboard)
        Clear-PendingState -ChatId $ChatId
        return
    }
    if ($state.Name -eq 'NewsFilePath' -and -not (Test-NewsTickerFilePathSetting -Path $trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.needAbsoluteTxtPath') -ReplyMarkup (Get-SettingsKeyboard)
        Clear-PendingState -ChatId $ChatId
        return
    }
    # A credential cannot be emptied by sending nothing - the check above
    # refuses that - so a lone dash means "no code any more".
    if ($trimmed -eq '-' -and [string]$state.Name -match '(?i)token|secret|password|apikey') { $trimmed = '' }
    Clear-PendingState -ChatId $ChatId
    $previous = Get-Setting $state.Name
    Set-Setting -Name $state.Name -Value $trimmed
    # The log and the audit trail are read by more people than the one who
    # typed this, so a credential is recorded by its length, never its text.
    $shownFrom = Format-ConfigDiffValue -Name ([string]$state.Name) -Value $previous
    $shownTo = Format-ConfigDiffValue -Name ([string]$state.Name) -Value $trimmed
    Write-BridgeLog "User $($state.UserId) set $($state.Name) = $shownTo"
    Add-AuditEntry (T 'kb.settingAudit' $($state.Name) $shownTo $(Format-UserAuditActor -UserId ([long]$state.UserId)))
    Send-TelegramMessage -ChatId $ChatId -Text (Get-SettingChangeText -Name ([string]$state.Name) -From $shownFrom -To $shownTo) -ParseMode HTML -ReplyMarkup (Get-SettingsKeyboard)
}

function Set-SettingChoice {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $choices = @($script:SettingChoices[$Name])
    if ($Index -lt 0 -or $Index -ge $choices.Count) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'common.badChoice') -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    if ($Name -eq 'SceneMode' -and [string]$choices[$Index] -eq 'Multi') {
        try {
            $statuses = @(Get-CinegyLayerDashboard)
            $capabilities = Get-CinegySceneCapabilities -SceneItems $statuses -LayerTargetSupported $true
            $mode = Test-BridgeSceneMode -RequestedMode Multi -Capabilities $capabilities
            if ($mode.Mode -ne 'Multi') {
                Send-TelegramMessage -ChatId $ChatId -Text "⛔ $($mode.Error)" -ReplyMarkup (Get-SettingsKeyboard)
                return
            }
        }
        catch {
            Send-TelegramMessage -ChatId $ChatId -Text (T 'kb.multiSceneUnavailable') -ReplyMarkup (Get-SettingsKeyboard)
            return
        }
    }
    $previous = Get-Setting $Name
    Set-Setting -Name $Name -Value $choices[$Index]
    Write-BridgeLog "User $UserId set $Name = $($choices[$Index])"
    Add-AuditEntry (T 'kb.settingAudit' $Name $($choices[$Index]) $(Format-UserAuditActor -UserId $UserId))
    Send-TelegramMessage -ChatId $ChatId -Text (Get-SettingChangeText -Name $Name -From $previous -To $choices[$Index]) -ParseMode HTML -ReplyMarkup (Get-SettingsKeyboard)
}
