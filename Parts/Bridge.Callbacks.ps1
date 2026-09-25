#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Test-CallbackAdmin {
    <# Guard used by every admin-only callback branch. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (Test-Admin -ChatId $ChatId -UserId $UserId) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'reply.adminOnly') -ReplyMarkup (Get-NoticeKeyboard)
    return $false
}

function Test-CallbackStatusViewer {
    <# The full status is read-only, so the owner may inspect it even when they
       are not listed among the day-to-day administrators. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (Test-StatusViewer -ChatId $ChatId -UserId $UserId) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'reply.checkAdminOwner') -ReplyMarkup (Get-NoticeKeyboard)
    return $false
}

function Test-CallbackTemplateReminderManager {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (Test-TemplateReminderManager -ChatId $ChatId -UserId $UserId) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'reply.noticeAdminOwner') -ReplyMarkup (Get-NoticeKeyboard)
    return $false
}

function Test-CallbackOwner {
    <# Guard for the owner-only branches: appointing and removing
       administrators. Separate from Test-CallbackAdmin because being an
       administrator is precisely what it does not entitle you to grant. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (Test-Owner -ChatId $ChatId -UserId $UserId) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'reply.ownerOnlyAdmins') -ReplyMarkup (Get-NoticeKeyboard)
    return $false
}

function Get-CallbackRefusal {
    <#
        The reason a press is refused, or '' when it is allowed.

        It lives above the acknowledgement because Telegram accepts one answer
        per press: a refusal decided further down, after the acknowledgement
        has been spent, can only arrive as a new chat message - and the two
        restore branches did not even manage that, refusing with a bare break
        so the press did nothing visible at all. Every check here is a
        settings or role lookup already held in memory.

        The handlers keep their own copies of these checks. Telegram leaves
        buttons live in messages it has already delivered, so a screen drawn
        before a permission changed can still be pressed, and the rule has
        always been that a button is both not drawn and not honoured.
    #>
    param([string]$Data, [long]$ChatId, [long]$UserId)
    if ($Data -like 'news:sheet*') {
        if (-not (Test-NewsSheetPullAccess -ChatId $ChatId -UserId $UserId)) {
            return (T 'reply.sheetPullDenied')
        }
        # Permission says who may ever pull; the lock says who may pull now.
        # Both pulls rewrite the ticker, so neither belongs to an operator who
        # is not the current writer - including when nobody is.
        $lockDenial = Get-NewsSheetPullLockDenial -ChatId $ChatId -UserId $UserId
        if (-not [string]::IsNullOrWhiteSpace($lockDenial)) { return $lockDenial }
    }
    if ($Data -like 'news:restore*' -and -not (Test-Admin -ChatId $ChatId -UserId $UserId) `
            -and -not (Get-Setting 'AllowOperatorsRestoreNews')) {
        return (T 'reply.newsRestoreAdminOnly')
    }
    return ''
}

function Invoke-CallbackQuery {
    param($CallbackQuery)

    # message is absent when the originating message is too old for Telegram to
    # still have it, so it cannot be dereferenced blindly under StrictMode.
    $fromObj = Get-JsonProp $CallbackQuery 'from'
    $userId = if ($fromObj) { [long](Get-JsonProp $fromObj 'id') } else { 0 }
    $msgObj = Get-JsonProp $CallbackQuery 'message'
    $chatId = if ($msgObj) { [long]$msgObj.chat.id } else { $userId }
    $data = [string](Get-JsonProp $CallbackQuery 'data')
    # Set per press and cleared by the next press and by every tick, so it
    # can never outlive the reply it is for.
    $script:RefreshTarget = if ($msgObj -and ((Test-RefreshButtonPress -Message $msgObj -Data $data) -or (Test-RedrawInPlacePress -Data $data))) {
        @{ ChatId = $chatId; MessageId = [int](Get-JsonProp $msgObj 'message_id') }
    } else { $null }

    # The guards run BEFORE the acknowledgement, and every one of them still
    # answers the query on its way out.
    #
    # Telegram accepts exactly one answerCallbackQuery per press. Answering
    # first - as this did - spent that one answer on an empty acknowledgement,
    # which left a refusal no way to reach the button and forced it to arrive
    # as a new chat message instead: the keyboard scrolls away and the
    # operator has to find it again. These checks are in-memory and cost
    # nothing, so running them first loses none of the reason the
    # acknowledgement came first, which is that the spinner must not sit
    # through a slow air operation.
    if ($chatId -eq 0) {
        Write-BridgeLog "Ignoring callback with neither a message nor a sender" "WARN"
        Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id
        return
    }

    if ($msgObj -and -not (Test-TelegramPrivateChat -Chat $msgObj.chat)) {
        Write-BridgeLog "Ignoring callback from non-private chat $chatId" "WARN"
        Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id
        return
    }

    if (-not (Test-Authorized -ChatId $chatId -UserId $userId)) {
        Write-BridgeLog "Rejected callback from unauthorized chat $chatId / user $userId" "WARN"
        $queued = Request-Approval -ChatId $chatId -UserId $userId -From $fromObj
        $msg = Get-UnauthorizedReplyText -ChatId $chatId -Queued $queued
        # On the button, not as a message: an unauthorised press should not
        # leave anything behind in a chat its sender may not read again. An
        # empty reason means the join-code prompt has just gone out instead.
        if ($msg) { Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text $msg -Alert }
        else { Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id }
        return
    }

    # Button presses too, not messages only: an operator who works entirely
    # from the keyboards would otherwise never be named. Placed after the
    # private-chat and authorization gates rather than at the top, because a
    # name is learned only for people this bridge works for - and a group
    # press should cost nothing at all before it is turned away.
    Update-UserNameFromTelegram -From $fromObj -UserId $userId -ChatId $chatId | Out-Null

    $refusal = Get-CallbackRefusal -Data $data -ChatId $chatId -UserId $userId
    if ($refusal) {
        Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text $refusal -Alert
        return
    }

    Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id
    Update-UserLastActivity -UserId $userId | Out-Null

    if ($data -match '^urgentb:(all|none|page)(?::|$)') {
        if ($data -notmatch '^urgentb:(all|none|page)(?::([0-9]{1,6}))?$') {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.urgentExpired')
            return
        }
        $urgentPageAction = $Matches[1]
        $urgentPage = if ($Matches.ContainsKey(2)) { [int]$Matches[2] } else { 0 }
        $data = "urgentb:${urgentPageAction}:$urgentPage"
    }
    if ($data -eq 'urgentb:delconfirm') {
        Invoke-UrgentSelectedDelete -ChatId $chatId -UserId $userId | Out-Null
        return
    }
    # Resolve stable story IDs only after admission. Old positional buttons
    # cannot prove which story they meant and are deliberately refused.
    if ($data -match '^urgentb:(pick|item|text|title|interval|repeats|mode|modereset|intervalreset|repeatsreset|enable|up|down|itemdel):(.+)$') {
        $urgentAction = $Matches[1]
        $urgentId = $Matches[2]
        $urgentPosition = -1
        $urgentItems = @(Get-UrgentProperty $script:UrgentBoard 'Items' @())
        for ($urgentIndex = 0; $urgentIndex -lt $urgentItems.Count; $urgentIndex++) {
            if ([string](Get-UrgentProperty $urgentItems[$urgentIndex] 'Id' '') -ceq $urgentId) { $urgentPosition = $urgentIndex; break }
        }
        if ($urgentPosition -lt 0) {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.urgentChanged')
            return
        }
        $data = "urgentb:${urgentAction}:$urgentPosition"
    }

    switch -Wildcard ($data) {
        'urgmode:*' {
            $mode = Get-CallbackArg $data 'urgmode:'
            if ($mode -in @('manual','auto')) {
                # The operator's own, not the chat's: two people sharing a
                # group each keep the way they work, and it follows them home.
                $script:UrgentManualMode[[long]$userId] = ($mode -eq 'manual')
                $modeSaved = Save-UrgentManualState
                Write-BridgeLog "User $userId set the urgent board to $mode mode (chat $chatId, saved: $modeSaved)"
                Show-UrgentBoardScreen -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            }
            break
        }
        'urgread:*' {
            $argument = Get-CallbackArg $data 'urgread:'
            if ($argument -match '^(u_[a-f0-9]{8}):([0-9]{1,6})$') {
                Show-UrgentReader -ChatId $chatId -UserId $userId -ItemId $Matches[1] -Page ([int]$Matches[2]) -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            }
            break
        }
        'urgsingle:*' {
            # ':t' is the timed button - the same review, with a hide time.
            if ((Get-CallbackArg $data 'urgsingle:') -match '^(u_[a-f0-9]{8})(:t)?$') {
                Show-UrgentManualConfirm -ChatId $chatId -UserId $userId -ItemId $Matches[1] -MessageId ([int](Get-JsonProp $msgObj 'message_id')) -Timed:([bool]$Matches[2])
            }
            break
        }
        'urgmanual:*' {
            if (-not (Invoke-UrgentManualAction -ChatId $chatId -UserId $userId -Argument (Get-CallbackArg $data 'urgmanual:'))) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.urgentItemChanged')
            }
            break
        }
        'tmax:*' { Invoke-TemplateMaxAirPick -ChatId $chatId -UserId $userId -Argument (Get-CallbackArg $data 'tmax:') -MessageId ([int](Get-JsonProp $msgObj 'message_id')) | Out-Null; break }
        'menu:news' { Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id')); break }
        'news:refresh' { Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id')); break }
        'news:resume' {
            Resume-ExpiredNewsDraft -ChatId $chatId -UserId $userId
            break
        }
        'news:sheetdraft' {
            if (-not (Test-NewsSheetPullAccess -ChatId $chatId -UserId $userId)) { Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sheetPullDeniedShort'); break }
            Send-TelegramMessage -ChatId $chatId -Text (Get-NewsSheetConfirmPrompt -Target draft) -ReplyMarkup (Get-NewsSheetConfirmKeyboard -Target draft)
            break
        }
        'news:sheetdraftconfirm' {
            if (-not (Test-NewsSheetPullAccess -ChatId $chatId -UserId $userId)) { Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sheetPullDeniedShort'); break }
            $sync = Invoke-NewsSheetSync -Trigger manual -Target draft -UserId $userId -ChatId $chatId -Confirmed
            $text = if ($sync.Success) { (T 'cb.draftLoaded' $(@($sync.Items).Count)) } else { "❌ $($sync.Error)" }
            Send-TelegramMessage -ChatId $chatId -Text $text
            Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId
            break
        }
        'news:sheet' {
            if (-not (Test-NewsSheetPullAccess -ChatId $chatId -UserId $userId)) { Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sheetPullDeniedShort'); break }
            Send-TelegramMessage -ChatId $chatId -Text (Get-NewsSheetConfirmPrompt -Target air) -ReplyMarkup (Get-NewsSheetConfirmKeyboard -Target air)
            break
        }
        'news:sheetconfirm' {
            if (-not (Test-NewsSheetPullAccess -ChatId $chatId -UserId $userId)) { Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sheetPullDeniedShort'); break }
            $sync = Invoke-NewsSheetSync -Trigger manual -Target air -UserId $userId -ChatId $chatId -Confirmed
            $text = if ($sync.Success) { "✅ $(Get-NewsSheetNoticeText -Summary $sync.Summary -Trigger manual -UserId $userId)" }
            elseif ($sync.Unchanged) { (T 'reply.sheetMatchesAir') }
            else { "❌ $($sync.Error)" }
            Send-TelegramMessage -ChatId $chatId -Text $text
            Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId
            break
        }
        'news:start' {
            $result=Start-NewsTickerDraft -ChatId $chatId -UserId $userId
            if(-not $result.Success){Send-TelegramMessage -ChatId $chatId -Text "🔒 $($result.Error)" -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId)}else{Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId};break
        }
        'news:add' {
            if(-not(Get-NewsTickerDraft -UserId $userId)){Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noDraftOfYours');break}
            Set-PendingState -ChatId $chatId -State @{Mode='news_add_text';UserId=$userId;StartedAt=(Get-Date)}
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sendNewStory');break
        }
        'news:sets' { Show-NewsSetsScreen -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id')); break }
        'news:setsp:*' {
            $setsPage = 0
            if ([int]::TryParse((Get-CallbackArg $data 'news:setsp:'), [ref]$setsPage) -and $setsPage -ge 0) {
                Show-NewsSetsScreen -ChatId $chatId -UserId $userId -Page $setsPage -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            }
            break
        }
        'news:setload:*' {
            $setIndex = -1
            [int]::TryParse((Get-CallbackArg $data 'news:setload:'), [ref]$setIndex) | Out-Null
            $loaded = Use-NewsSet -UserId $userId -Index $setIndex
            Send-TelegramMessage -ChatId $chatId -Text $(if ($loaded) { (T 'news.sets.loaded') } else { (T 'news.sets.loadRefused') }) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'news:setdelask:*' {
            $setIndex = -1
            if ([int]::TryParse((Get-CallbackArg $data 'news:setdelask:'), [ref]$setIndex)) {
                Show-NewsSetsScreen -ChatId $chatId -UserId $userId -Page ([math]::Floor([math]::Max(0, $setIndex) / 8)) -ConfirmDelete $setIndex -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            }
            break
        }
        'news:setdel:*' {
            $setIndex = -1
            [int]::TryParse((Get-CallbackArg $data 'news:setdel:'), [ref]$setIndex) | Out-Null
            if (-not (Remove-NewsSet -ChatId $chatId -UserId $userId -Index $setIndex)) { Send-TelegramMessage -ChatId $chatId -Text (T 'news.sets.deleteRefused') }
            Show-NewsSetsScreen -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'news:setsave' {
            if (-not (Get-NewsTickerDraft -UserId $userId)) { Show-NewsSetsScreen -ChatId $chatId -UserId $userId; break }
            Set-PendingState -ChatId $chatId -State @{ Mode = 'news_set_name'; UserId = $userId; StartedAt = (Get-Date) }
            Send-TelegramMessage -ChatId $chatId -Text (T 'news.sets.namePrompt') -ReplyMarkup (Get-CancelKeyboard)
            break
        }
        'news:later' {
            if (-not (Get-NewsTickerDraft -UserId $userId)) { Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId; break }
            Set-PendingState -ChatId $chatId -State @{ Mode = 'news_publish_at'; UserId = $userId; StartedAt = (Get-Date) }
            $laterKeyboard = @{ inline_keyboard = @(
                    , @( @{ text = (T 'news.later.in' 15); callback_data = 'news:laterin:15' }, @{ text = (T 'news.later.in' 30); callback_data = 'news:laterin:30' }, @{ text = (T 'news.later.in' 60); callback_data = 'news:laterin:60' } )
                    , @( @{ text = (T 'reply.cancelWord'); callback_data = 'news:refresh' } )) }
            Send-TelegramMessage -ChatId $chatId -Text (T 'news.later.prompt') -ReplyMarkup $laterKeyboard
            break
        }
        'news:laterin:*' {
            $laterMinutes = 0
            if ([int]::TryParse((Get-CallbackArg $data 'news:laterin:'), [ref]$laterMinutes) -and $laterMinutes -in @(15, 30, 60)) {
                Clear-PendingState -ChatId $chatId
                Complete-NewsPublishAtMoment -ChatId $chatId -UserId $userId -At ([datetimeoffset]::Now.AddMinutes($laterMinutes))
            }
            break
        }
        'news:latercancel' {
            Clear-NewsPublishAt -UserId $userId | Out-Null
            Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'news:pause:*' {
            $pauseIndex = 0
            if ([int]::TryParse((Get-CallbackArg $data 'news:pause:'), [ref]$pauseIndex) -and (Suspend-NewsTickerDraftItem -UserId $userId -Index $pauseIndex)) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'news.paused.done') -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId)
            }
            else { Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId }
            break
        }
        'news:pausedp:*' {
            $pausedPage = 0
            if ([int]::TryParse((Get-CallbackArg $data 'news:pausedp:'), [ref]$pausedPage) -and $pausedPage -ge 0) {
                Show-NewsPausedScreen -ChatId $chatId -Page $pausedPage -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            }
            break
        }
        'news:paused' { Show-NewsPausedScreen -ChatId $chatId -MessageId ([int](Get-JsonProp $msgObj 'message_id')); break }
        'news:unpause:*' {
            $unpauseIndex = 0
            if ([int]::TryParse((Get-CallbackArg $data 'news:unpause:'), [ref]$unpauseIndex)) { Resume-NewsPausedItem -UserId $userId -Index $unpauseIndex | Out-Null }
            Show-NewsPausedScreen -ChatId $chatId -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'news:pasteok' { Complete-NewsPaste -ChatId $chatId -UserId $userId; break }
        'news:pastecancel' { Complete-NewsPaste -ChatId $chatId -UserId $userId -Cancel; break }
        'news:preview' {
            $draft=Get-NewsTickerDraft -UserId $userId;if(-not $draft){Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId;break}
            $position=0;$preview=@($draft.Items|ForEach-Object {$position++;"$position. $_"}) -join "`n"
            # Paged, not concatenated. At the configured maxima - NewsMaxItems
            # 200 by NewsMaxItemLength 1000 - this one tap built a 200,000
            # character message, which Send-TelegramMessage split into about
            # fifty back-to-back sends: past Telegram's per-chat rate limit, so
            # the tail 429'd into the outbox and came back minutes later
            # interleaved with whatever the editor did next. The keyboard rode
            # only on the last chunk, so the buttons were under a wall of text
            # the editor had to scroll up through. Paging puts the first page
            # and the keyboard together, with 📄 المزيد for the rest.
            Send-TelegramPagedText -ChatId $chatId -Text (T 'cb.draftPreview' $(@($draft.Items).Count) $preview) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break
        }
        'news:publish' {
            $draft=Get-NewsTickerDraft -UserId $userId;if(-not $draft){Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId;break}
            # The words, not a count: an editor about to put copy on air is
            # deciding whether these are the right ones.
            $publishMarkup = @{inline_keyboard=@(,@(@{text=(T 'reply.yesPublish');callback_data='news:publishconfirm';style='success'},@{text=(T 'reply.cancelWord');callback_data='news:refresh'}))}
            $publishBlocks = @(Get-NewsPublishReviewBlocks -UserId $userId)
            if ($publishBlocks.Count -gt 0 -and (Send-TelegramRichMessage -ChatId $chatId -Blocks $publishBlocks -ReplyMarkup $publishMarkup)) { break }
            $publishConfirm = @{ inline_keyboard = @(, @(
                        @{ text = (T 'reply.yesPublish'); callback_data = 'news:publishconfirm'; style = 'success' }
                        @{ text = (T 'reply.cancelWord'); callback_data = 'news:refresh' }
                    )) }
            Send-TelegramMessage -ChatId $chatId -Text (T 'cb.confirmPublish' $(@($draft.Items).Count)) -ReplyMarkup $publishConfirm
            break
        }
        'news:publishconfirm' {
            $result=Publish-NewsTickerDraft -UserId $userId
            # A conflict is not a failure to report and forget: it means the
            # live file moved on, and the operator's only way forward is a
            # fresh draft. Saying just (T 'reply.notPublished') left people retrying the
            # same doomed publish and concluding their edits were ignored.
            if ($result.Success) {
                Send-TelegramMessage -ChatId $chatId -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId) `
                    -Text (Get-NewsPublishOutcomeText -Result $result -Lead (T 'reply.tickerPublished'))
            }
            elseif ($result.Conflict) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.newsFileChangedOutside') -ReplyMarkup @{inline_keyboard=@(
                        , @(@{text=(T 'reply.appendMine');callback_data='news:rebaseappend'})
                        , @(@{text=(T 'reply.replaceAll');callback_data='news:rebasereplace';style='danger'})
                        , @(@{text=(T 'reply.cancel');callback_data='news:refresh'}))}
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.notPublished' $($result.Error)) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'news:list' { Show-NewsTickerReorderScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id);break }
        # The reorder rows keep a fixed four buttons so every row renders the
        # same width; the end rows have no arrow to offer and carry this
        # instead. The tap is already acknowledged, so there is nothing to do.
        'news:noop' { break }
        'news:list:*' { Show-NewsTickerReorderScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id) -Page ([int](Get-CallbackArg $data 'news:list:'));break }
        'news:item:*' {
            $i=[int](Get-CallbackArg $data 'news:item:');Show-NewsTickerItemScreen -ChatId $chatId -UserId $userId -Index $i;break
        }
        'news:edit:*' {
            $i = [int](Get-CallbackArg $data 'news:edit:')
            Set-PendingState -ChatId $chatId -State @{Mode='news_edit_text';UserId=$userId;Index=$i;StartedAt=(Get-Date)}
            # The item being replaced, so a one-word correction is not a
            # retyped headline. This screen said only (T 'reply.sendReplacementColon')
            # and showed nothing at all.
            $draft = Get-NewsTickerDraft -UserId $userId
            $current = if ($draft -and $i -ge 0 -and $i -lt @($draft.Items).Count) { [string]@($draft.Items)[$i] } else { '' }
            Send-BridgeTextEditPrompt -ChatId $chatId -Prompt (T 'reply.sendReplacement') -Current $current -CancelData 'news:reorder'
            break
        }
        'news:delask:*' {
            Show-NewsTickerDeleteConfirm -ChatId $chatId -UserId $userId -Index ([int](Get-CallbackArg $data 'news:delask:')) -MessageId ([int]$msgObj.message_id) | Out-Null
            break
        }
        'news:delete:*' {
            $i = [int](Get-CallbackArg $data 'news:delete:')
            # The bounds live in Remove-NewsTickerDraftItem, which refuses an
            # index outside the draft - so this reads its answer rather than
            # repeating the check and risking the two drifting apart.
            $ok = Remove-NewsTickerDraftItem -ChatId $chatId -UserId $userId -Index $i
            if ($ok) {
                $backToOrder = @{ inline_keyboard = @(, @( @{ text = (T 'reply.backToOrder'); callback_data = 'news:list' } )) }
                Edit-TelegramMessageText -ChatId $chatId -MessageId ([int]$msgObj.message_id) -Text (T 'reply.headlineDeleted') -ReplyMarkup $backToOrder | Out-Null
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.deleteNotAllowed')
            }
            break
        }
        'news:up:*' {
            $i=[int](Get-CallbackArg $data 'news:up:')
            if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta -1){Show-NewsTickerReorderScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id)}
            else{Send-TelegramMessage -ChatId $chatId -Text (T 'reply.alreadyFirst')};break
        }
        'news:down:*' {
            $i=[int](Get-CallbackArg $data 'news:down:')
            if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta 1){Show-NewsTickerReorderScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id)}
            else{Send-TelegramMessage -ChatId $chatId -Text (T 'reply.alreadyLast')};break
        }
        'news:iup:*' {
            $i=[int](Get-CallbackArg $data 'news:iup:')
            if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta -1){Show-NewsTickerItemScreen -ChatId $chatId -UserId $userId -Index ($i-1) -MessageId ([int]$msgObj.message_id)}
            else{Send-TelegramMessage -ChatId $chatId -Text (T 'reply.alreadyFirst')};break
        }
        'news:idown:*' {
            $i=[int](Get-CallbackArg $data 'news:idown:')
            if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta 1){Show-NewsTickerItemScreen -ChatId $chatId -UserId $userId -Index ($i+1) -MessageId ([int]$msgObj.message_id)}
            else{Send-TelegramMessage -ChatId $chatId -Text (T 'reply.alreadyLast')};break
        }
        'news:rebaseappend' {
            $result = Resolve-NewsPublishConflict -UserId $userId -Mode append
            Send-TelegramMessage -ChatId $chatId -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId) `
                -Text $(if ($result.Success) { Get-NewsPublishOutcomeText -Result $result -Lead (T 'reply.appended') } else { (T 'cb.notPublished' $($result.Error)) })
            break
        }
        'news:rebasereplace' {
            $result = Resolve-NewsPublishConflict -UserId $userId -Mode replace
            Send-TelegramMessage -ChatId $chatId -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId) `
                -Text $(if ($result.Success) { Get-NewsPublishOutcomeText -Result $result -Lead (T 'reply.replaced') } else { (T 'cb.notPublished' $($result.Error)) })
            break
        }
        'news:lockrequest' { Request-NewsLockRelease -ChatId $chatId -UserId $userId | Out-Null; break }
        'news:lockgrant' {
            $pending = $script:NewsLockRequest
            if ($pending -and [long]$pending.OwnerUserId -eq $userId) { Complete-NewsLockRelease -Reason 'granted by the owner' | Out-Null }
            break
        }
        'news:lockdeny' {
            $pending = $script:NewsLockRequest
            if ($pending -and [long]$pending.OwnerUserId -eq $userId) { Complete-NewsLockRelease -Denied | Out-Null }
            Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId
            break
        }
        'news:unlock' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                # Four pieces of one act - drop the draft, release the lock,
                # forget any queued request, and redraw - so a half-done
                # unlock cannot leave a reservation nobody can see or clear.
                Remove-NewsTickerDraft
                Clear-NewsLockReservation
                $script:NewsLockRequest = $null
                Save-NewsLockRequest | Out-Null
                Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId
            }
            break
        }
        'news:clear' {
            $clearConfirm = @{ inline_keyboard = @(, @(
                        @{ text = (T 'reply.yesClearDraft'); callback_data = 'news:clearconfirm'; style = 'danger' }
                        @{ text = (T 'reply.cancelWord'); callback_data = 'news:refresh' }
                    )) }
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.confirmClearDraft') -ReplyMarkup $clearConfirm
            break
        }
        'news:clearconfirm' {
            $ok = Clear-NewsTickerDraftItems -ChatId $chatId -UserId $userId
            $clearedText = if ($ok) { (T 'reply.draftCleared') } else { (T 'reply.notAllowed') }
            Send-TelegramMessage -ChatId $chatId -Text $clearedText -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'news:backups' { Send-TelegramMessage -ChatId $chatId -Text (Get-NewsTickerBackupsText) -ParseMode HTML -ReplyMarkup (Get-NewsTickerBackupsKeyboard);break }
        'news:restore:*' {
            if (-not (Test-Admin -ChatId $chatId -UserId $userId) -and -not (Get-Setting 'AllowOperatorsRestoreNews')) { break }
            $i = [int](Get-CallbackArg $data 'news:restore:')
            $restoreConfirm = @{ inline_keyboard = @(, @(
                        @{ text = (T 'reply.restore'); callback_data = "news:restoreconfirm:$i"; style = 'danger' }
                        @{ text = (T 'reply.cancelWord'); callback_data = 'news:backups' }
                    )) }
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.confirmRestore') -ReplyMarkup $restoreConfirm
            break
        }
        'news:restoreconfirm:*' {
            if (-not (Test-Admin -ChatId $chatId -UserId $userId) -and -not (Get-Setting 'AllowOperatorsRestoreNews')) { break }
            # Through the shared reader, not a second copy of its query. The
            # two agreed only by coincidence, and the moment one of them
            # learned the NewsBackupKeepFiles cap the numbering would have
            # split: button 12 on the screen restoring a different copy, or
            # none. Get-NewsTickerBackupByIndex also carries the lower bound
            # this path was missing.
            $i = [int](Get-CallbackArg $data 'news:restoreconfirm:')
            $chosenBackup = Get-NewsTickerBackupByIndex -Index $i
            if (-not $chosenBackup) { break }
            $live=Get-NewsTickerConfiguredSnapshot;$result=Restore-NewsTickerBackup -Path ([string](Get-Setting 'NewsFilePath')) -BackupPath $chosenBackup.FullName -ExpectedHash $live.Hash -Separator ([string](Get-Setting 'NewsItemSeparator')) -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
            if($result.Success){Remove-NewsTickerDraft;Add-AuditEntry (T 'cb.tickerRestoreAudit' $(Format-UserAuditActor -UserId $userId))};Send-TelegramMessage -ChatId $chatId -Text $(if($result.Success){(T 'reply.restored')}else{(T 'cb.restoreFailed' $($result.Error))}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break
        }
        'news:handover' {
            if (Open-NewsTickerDraftToAll -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.draftHandedOver')
            }
            Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId; break
        }
        'news:cancel' {
            $doomed = Get-NewsTickerDraft -UserId $userId
            if ($doomed) {
                # Handed back before it goes: discarding is the one draft
                # ending that used to cost every typed word in silence.
                Send-NewsDraftReceipt -ChatId $chatId -Items $doomed.Items | Out-Null
                Remove-NewsTickerDraft
            }
            Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId; break
        }
        'news:import' {
            $started=Start-NewsTickerDraft -ChatId $chatId -UserId $userId;if(-not $started.Success){Send-TelegramMessage -ChatId $chatId -Text $started.Error;break}
            Set-PendingState -ChatId $chatId -State @{Mode='news_import_upload';UserId=$userId;StartedAt=(Get-Date)}
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sendTxt');break
        }
        # Both spellings: seven screens send 'menu:main' on their 🏠 button -
        # the diagnostics screen, quick start, both report screens, a help
        # chapter, the help index and 🧾 عملياتي - and only 'menu' was
        # handled. The press fell to the default branch, which answered
        # «خيار غير معروف.» and, worse, left any half-finished input
        # pending: the home button is what an operator presses to get out of
        # a flow, and it was the one press that did not clear it.
        'menu:mojaz' { Clear-PendingState -ChatId $chatId; Show-MojazLibraryScreen -ChatId $chatId -UserId $userId; break }
        'mojaz:back' { Clear-PendingState -ChatId $chatId; Show-MojazLibraryScreen -ChatId $chatId -UserId $userId; break }
        'mojaz:new' { Start-MojazNamePrompt -Which new -ChatId $chatId -UserId $userId; break }
        'mojaz:rename' { Start-MojazNamePrompt -Which rename -ChatId $chatId -UserId $userId; break }
        'mojaz:copy' { Start-MojazNamePrompt -Which copy -ChatId $chatId -UserId $userId; break }
        'mojaz:open:*' { Clear-PendingState -ChatId $chatId; Open-MojazBulletin -BulletinId (Get-CallbackArg $data 'mojaz:open:') -ChatId $chatId -UserId $userId; break }
        'mojaz:refresh' { Clear-PendingState -ChatId $chatId; Show-MojazScreen -ChatId $chatId -UserId $userId; break }
        'mojaz:add' { Start-MojazRowAdd -ChatId $chatId -UserId $userId; break }
        'mojaz:paste' { Start-MojazRowPaste -ChatId $chatId -UserId $userId; break }
        'rows:pasteok' { Complete-RowPaste -ChatId $chatId -UserId $userId; break }
        'rows:pastecancel' { Complete-RowPaste -ChatId $chatId -UserId $userId -Cancel; break }
        'mojaz:skipimage' { Complete-MojazRowImage -ChatId $chatId -Skip; break }
        'mojaz:img:inherit' { Complete-MojazRowImage -ChatId $chatId -Mode inherit; break }
        'mojaz:img:template' { Complete-MojazRowImage -ChatId $chatId -Mode template; break }
        'mojaz:img:use:*' {
            $slot = 0
            if ([int]::TryParse((Get-CallbackArg $data 'mojaz:img:use:'), [ref]$slot)) {
                $reused = Resolve-MojazUsedImage -ChatId $chatId -Index $slot
                if ($reused) { Complete-MojazRowImage -ChatId $chatId -Mode new -Value $reused }
            }
            break
        }
        'mojaz:row:*' { Clear-PendingState -ChatId $chatId; Show-MojazRowScreen -RowId (Get-CallbackArg $data 'mojaz:row:') -ChatId $chatId -UserId $userId; break }
        'mojaz:editimg:*' { Start-MojazRowEdit -Which image -RowId (Get-CallbackArg $data 'mojaz:editimg:') -ChatId $chatId -UserId $userId; break }
        'mojaz:edittitle:*' { Start-MojazRowEdit -Which title -RowId (Get-CallbackArg $data 'mojaz:edittitle:') -ChatId $chatId -UserId $userId; break }
        'mojaz:edittext:*' { Start-MojazRowEdit -Which text -RowId (Get-CallbackArg $data 'mojaz:edittext:') -ChatId $chatId -UserId $userId; break }
        'mojaz:delay' { Start-MojazDelayPrompt -ChatId $chatId -UserId $userId; break }
        'mojaz:intro' { Start-MojazTimingPrompt -Which intro -ChatId $chatId -UserId $userId; break }
        'mojaz:last' { Start-MojazTimingPrompt -Which last -ChatId $chatId -UserId $userId; break }
        'mojaz:later' { Start-MojazLaterPrompt -ChatId $chatId -UserId $userId; break }
        'mojaz:sync' { Switch-MojazSync -ChatId $chatId -UserId $userId; break }
        'mojaz:matchloop' { Set-MojazDelayToLoop -ChatId $chatId -UserId $userId; break }
        'mojaz:preview' { Clear-PendingState -ChatId $chatId; Show-MojazPreviewScreen -ChatId $chatId -UserId $userId; break }
        'mojaz:times' { Clear-PendingState -ChatId $chatId; Show-MojazSchedulesScreen -ChatId $chatId -UserId $userId; break }
        'mojaz:unschedule:*' { Stop-MojazSchedule -ScheduleId (Get-CallbackArg $data 'mojaz:unschedule:') -ChatId $chatId -UserId $userId; break }
        'mojaz:play' { Start-MojazPlayback -ChatId $chatId -UserId $userId | Out-Null; break }
        'mojaz:playnow' { Start-MojazPlayback -ChatId $chatId -UserId $userId -Force | Out-Null; break }
        'mojaz:playafter' { Start-MojazAfterUrgent -ChatId $chatId -UserId $userId | Out-Null; break }
        'urgent:now' { Send-MojazPendingUrgentNow -ChatId $chatId -UserId $userId | Out-Null; break }
        'urgent:after' { Confirm-MojazPendingUrgent -ChatId $chatId -UserId $userId | Out-Null; break }
        'mojaz:stop' { Stop-MojazPlayback -ChatId $chatId -UserId $userId | Out-Null; break }

        # ------------------------------------------------- the breaking-news board
        #
        # Prefixed 'urgentb:' rather than 'urgent:' because 'urgent:' is
        # already the bulletin's "now or after" pair above, and two features
        # sharing a prefix is how a stale button from one ends up answered by
        # the other. Items are addressed by position: callback_data is 64
        # bytes and an id does not fit beside a prefix and a page.
        'airext:*' {
            $argument = Get-CallbackArg -Data $data -Prefix 'airext:'
            $ok = Invoke-TemplateAirExtensionReply -Argument $argument -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id)
            if (-not $ok) { Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text (T 'reply.extensionExpired') -Alert }
            else { Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id }
            break
        }
        'boards:open' { Clear-PendingState -ChatId $chatId; Show-BoardsScreen -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id')); break }
        'boards:noop' { break }
        'boards:page:*' { Show-BoardsScreen -ChatId $chatId -UserId $userId -Page ([int](Get-CallbackArg $data 'boards:page:')) -MessageId ([int](Get-JsonProp $msgObj 'message_id')); break }
        'boards:b:*' { Show-BoardScreen -BoardId ([string](Get-CallbackArg $data 'boards:b:')) -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id')); break }
        'boards:bp:*' {
            $parts = @([string](Get-CallbackArg $data 'boards:bp:') -split ':')
            Show-BoardScreen -BoardId $parts[0] -ChatId $chatId -UserId $userId -Page ([int]$parts[1]) -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'boards:i:*' {
            $parts = @([string](Get-CallbackArg $data 'boards:i:') -split ':')
            Show-BoardItemScreen -BoardId $parts[0] -ItemId $parts[1] -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'boards:show:*' {
            $parts = @([string](Get-CallbackArg $data 'boards:show:') -split ':')
            Show-BoardItemOnAir -BoardId $parts[0] -ItemId $parts[1] -ChatId $chatId -UserId $userId | Out-Null
            Show-BoardItemScreen -BoardId $parts[0] -ItemId $parts[1] -ChatId $chatId -UserId $userId
            break
        }
        'boards:hide:*' {
            $parts = @([string](Get-CallbackArg $data 'boards:hide:') -split ':')
            $hideBoard = Get-ContentBoard -BoardId $parts[0]
            if ($hideBoard) {
                $hideTemplate = (Get-TemplateStore).Map[[string](Get-BoardProperty $hideBoard 'TemplateKey' '')]
                # Through Invoke-HideLayer, which since 8.50.0 asks the same
                # per-layer permission the hide BUTTON asks. A protected layer
                # stays protected from here too, with no line written for it.
                if ($hideTemplate -and (Invoke-HideLayer -Layer ([int]$hideTemplate.Layer) -ChatId $chatId -UserId $userId -Quiet)) {
                    Clear-BoardItemLive -Layer ([int]$hideTemplate.Layer)
                }
            }
            Show-BoardItemScreen -BoardId $parts[0] -ItemId $parts[1] -ChatId $chatId -UserId $userId
            break
        }
        'boards:en:*' {
            $parts = @([string](Get-CallbackArg $data 'boards:en:') -split ':')
            $enBoard = Get-ContentBoard -BoardId $parts[0]
            if ($enBoard) {
                $enItem = Get-BoardItem -Board $enBoard -ItemId $parts[1]
                $enNow = -not [bool](Get-BoardProperty $enItem 'Enabled' $true)
                Invoke-BoardEdit -Result (Set-BoardItemEnabled -Board $enBoard -ItemId $parts[1] -Enabled $enNow -UserId $userId) `
                    -BoardId $parts[0] -ItemId $parts[1] -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id')) | Out-Null
            }
            break
        }
        'boards:mv:*' {
            $parts = @([string](Get-CallbackArg $data 'boards:mv:') -split ':')
            $mvBoard = Get-ContentBoard -BoardId $parts[0]
            if ($mvBoard) {
                Invoke-BoardEdit -Result (Move-BoardItem -Board $mvBoard -ItemId $parts[1] -Delta ([int]$parts[2]) -UserId $userId) `
                    -BoardId $parts[0] -ItemId $parts[1] -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id')) | Out-Null
            }
            break
        }
        'boards:rm:*' {
            $parts = @([string](Get-CallbackArg $data 'boards:rm:') -split ':')
            $rmBoard = Get-ContentBoard -BoardId $parts[0]
            if ($rmBoard -and (Test-BoardEditAllowed -Board $rmBoard -ChatId $chatId -UserId $userId)) {
                Invoke-BoardEdit -Result (Remove-BoardItem -Board $rmBoard -ItemId $parts[1] -UserId $userId) `
                    -BoardId $parts[0] -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id')) | Out-Null
            }
            break
        }
        'boards:f:*' {
            $parts = @([string](Get-CallbackArg $data 'boards:f:') -split ':')
            $fBoard = Get-ContentBoard -BoardId $parts[0]
            if ($fBoard -and (Test-BoardEditAllowed -Board $fBoard -ChatId $chatId -UserId $userId)) {
                $fFields = @(Get-BoardTextFields -TemplateKey ([string](Get-BoardProperty $fBoard 'TemplateKey' '')))
                $fIndex = [int]$parts[2]
                if ($fIndex -ge 0 -and $fIndex -lt $fFields.Count) {
                    $fItem = Get-BoardItem -Board $fBoard -ItemId $parts[1]
                    Set-PendingState -ChatId $chatId -State @{ Mode = 'board_field'; UserId = $userId; BoardId = $parts[0]; ItemId = $parts[1]; FieldIndex = $fIndex; StartedAt = (Get-Date) }
                    Send-BridgeTextEditPrompt -ChatId $chatId -Prompt (T 'cb.sendValueFor' $($fFields[$fIndex])) `
                        -Current ([string](Get-BoardProperty (Get-BoardProperty $fItem 'Values' $null) $fFields[$fIndex] '')) -CancelData "boards:i:$($parts[0]):$($parts[1])"
                }
            }
            break
        }
        'boards:add:*' {
            $addId = [string](Get-CallbackArg $data 'boards:add:')
            $addBoard = Get-ContentBoard -BoardId $addId
            if ($addBoard -and (Test-BoardEditAllowed -Board $addBoard -ChatId $chatId -UserId $userId)) {
                $addFields = @(Get-BoardTextFields -TemplateKey ([string](Get-BoardProperty $addBoard 'TemplateKey' '')))
                Set-PendingState -ChatId $chatId -State @{ Mode = 'board_add'; UserId = $userId; BoardId = $addId; StartedAt = (Get-Date) }
                $addHint = if ($addFields.Count -gt 1) { (T 'cb.sendRow' $($addFields -join ' | ')) } else { (T 'reply.sendRowText') }
                Send-TelegramMessage -ChatId $chatId -Text $addHint -ReplyMarkup (Get-CancelKeyboard)
            }
            break
        }
        'boards:paste:*' {
            $pasteId = [string](Get-CallbackArg $data 'boards:paste:')
            $pasteBoard = Get-ContentBoard -BoardId $pasteId
            if ($pasteBoard -and (Test-BoardEditAllowed -Board $pasteBoard -ChatId $chatId -UserId $userId)) {
                $pasteFields = @(Get-BoardTextFields -TemplateKey ([string](Get-BoardProperty $pasteBoard 'TemplateKey' '')))
                Set-PendingState -ChatId $chatId -State @{ Mode = 'board_paste'; UserId = $userId; BoardId = $pasteId; StartedAt = (Get-Date) }
                $pasteHint = @((T 'reply.pasteRows'))
                if ($pasteFields.Count -gt 1) { $pasteHint += (T 'cb.fieldsInSceneOrder' $($pasteFields -join ' | ')) }
                # Said before the paste, not after it is truncated: Telegram caps
                # one inbound message at 4096 characters, so a long block arrives
                # cut and the producer would never know which rows were lost.
                $pasteHint += (T 'reply.pasteLimit')
                Send-TelegramMessage -ChatId $chatId -Text ($pasteHint -join "`n") -ReplyMarkup (Get-CancelKeyboard)
            }
            break
        }
        'boards:new' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-BoardTemplatePicker -ChatId $chatId -MessageId ([int](Get-JsonProp $msgObj 'message_id')) }
            break
        }
        'boards:pickp:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-BoardTemplatePicker -ChatId $chatId -Page ([int](Get-CallbackArg $data 'boards:pickp:')) -MessageId ([int](Get-JsonProp $msgObj 'message_id')) }
            break
        }
        'boards:pick:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            # Resolved against the same list the button was drawn from, because
            # the button carries a position: a template key is free text and an
            # Arabic one would not fit the 64-byte callback cap.
            $candidates = @(Get-BoardEligibleTemplates)
            $pickIndex = [int](Get-CallbackArg $data 'boards:pick:')
            if ($pickIndex -lt 0 -or $pickIndex -ge $candidates.Count) { break }
            $picked = $candidates[$pickIndex]
            if (-not $picked.Usable) {
                Send-TelegramMessage -ChatId $chatId -Text "⛔ $($picked.Reason)"
                break
            }
            if (@(Get-ContentBoards).Count -ge (Get-SettingInt 'MaxContentBoards' 1)) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'boards.full' (Get-SettingInt 'MaxContentBoards' 1))
                break
            }
            Set-PendingState -ChatId $chatId -State @{ Mode = 'board_new_name'; UserId = $userId; TemplateKey = [string]$picked.Key; StartedAt = (Get-Date) }
            # The name is what every operator sees on the button forever after,
            # and the chosen template is confirmed back here because this is the
            # last screen before it is fixed for good.
            $pickLines = @(
                (T 'boards.picked' (ConvertTo-TelegramHtmlText ([string]$picked.Key)))
                (T 'boards.picked.fields' (ConvertTo-TelegramHtmlText (@($picked.TextFields) -join ' · ')))
                ''
                (T 'boards.name.prompt')
                (T 'boards.name.example')
            )
            Send-TelegramMessage -ChatId $chatId -Text ($pickLines -join "`n") -ParseMode 'HTML' -ReplyMarkup (Get-CancelKeyboard)
            break
        }
        'boards:role:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $roleId = [string](Get-CallbackArg $data 'boards:role:')
            $roleBoard = Get-ContentBoard -BoardId $roleId
            if (-not $roleBoard) { break }
            # Cycles rather than opening a screen: three values, and the button
            # already shows which one is current.
            $nextRole = switch ([string](Get-BoardProperty $roleBoard 'EditRole' 'all')) {
                'all' { 'admin' }
                'admin' { 'owner' }
                default { 'all' }
            }
            $roleResult = Set-BoardEditRole -Board $roleBoard -Role $nextRole -UserId $userId
            if ($roleResult.Success -and (Save-ContentBoard -Board $roleResult.Value)) {
                Add-AuditEntry (T 'cb.fillRightAudit' $([string](Get-BoardProperty $roleBoard 'Name' '')) $nextRole $(Format-UserAuditActor -UserId $userId))
            }
            Show-BoardScreen -BoardId $roleId -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'boards:del:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $delId = [string](Get-CallbackArg $data 'boards:del:')
            $delBoard = Get-ContentBoard -BoardId $delId
            if ($delBoard) {
                # Confirmed, because this is a producer's prepared work and not a
                # setting that can be typed again in a moment.
                Send-TelegramMessage -ChatId $chatId -Text (T 'boards.deleteConfirm' (ConvertTo-TelegramHtmlText ([string](Get-BoardProperty $delBoard 'Name' ''))) @(Get-BoardProperty $delBoard 'Items' @()).Count) `
                    -ParseMode 'HTML' -ReplyMarkup @{ inline_keyboard = @(, @((New-Button (T 'boards.deleteYes') "boards:delgo:$delId" -Style danger), (New-Button (T 'common.back') "boards:b:$delId"))) }
            }
            break
        }
        'boards:delgo:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $delGoId = [string](Get-CallbackArg $data 'boards:delgo:')
            $delGoBoard = Get-ContentBoard -BoardId $delGoId
            if ($delGoBoard) {
                Add-AuditEntry (T 'cb.boardDeletedAudit' $([string](Get-BoardProperty $delGoBoard 'Name' '')) $(Format-UserAuditActor -UserId $userId))
                Remove-ContentBoardFile -BoardId $delGoId
            }
            Show-BoardsScreen -ChatId $chatId -UserId $userId
            break
        }
        'urgentb:open' { Clear-PendingState -ChatId $chatId; Show-UrgentBoardScreen -ChatId $chatId -UserId $userId; break }
        # The dispatcher acknowledges every admitted callback before entering
        # the action switch. A noop must not answer the same query twice.
        'urgentb:noop' { break }
        'urgentb:filter:*' {
            if (Set-UrgentBoardFilter -ChatId $chatId -Filter (Get-CallbackArg $data 'urgentb:filter:')) {
                Show-UrgentBoardScreen -ChatId $chatId -UserId $userId -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            }
            break
        }
        'urgentb:page:*' {
            Show-UrgentBoardScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id) -Page ([int](Get-CallbackArg $data 'urgentb:page:'))
            break
        }
        'urgentb:pick:*' {
            $originalPosition = [int](Get-CallbackArg $data 'urgentb:pick:')
            $item = Get-UrgentItemByPosition -Position $originalPosition
            if ($item) { Switch-UrgentSelection -ChatId $chatId -ItemId ([string](Get-UrgentProperty $item 'Id' '')) | Out-Null }
            $visibleItems = @(Get-UrgentVisibleItems -ChatId $chatId)
            $visiblePosition = -1
            if ($item) {
                $itemId = [string](Get-UrgentProperty $item 'Id' '')
                for ($visibleIndex = 0; $visibleIndex -lt $visibleItems.Count; $visibleIndex++) {
                    if ([string](Get-UrgentProperty $visibleItems[$visibleIndex] 'Id' '') -ceq $itemId) {
                        $visiblePosition = $visibleIndex
                        break
                    }
                }
            }
            $pagePosition = if ($visiblePosition -ge 0) { $visiblePosition } else { $originalPosition }
            $page = [int][math]::Floor($pagePosition / (Get-UrgentBoardPageSize))
            Show-UrgentBoardScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id) -Page $page
            break
        }
        'urgentb:all:*' {
            Set-UrgentSelectedIds -ChatId $chatId -Ids @(@(Get-UrgentVisibleItems -ChatId $chatId) | Where-Object { [bool](Get-UrgentProperty $_ 'Enabled' $true) } | ForEach-Object { [string](Get-UrgentProperty $_ 'Id' '') })
            Show-UrgentBoardScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id) -Page ([int](Get-CallbackArg $data 'urgentb:all:'))
            break
        }
        'urgentb:none:*' {
            Set-UrgentSelectedIds -ChatId $chatId -Ids @()
            Show-UrgentBoardScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id) -Page ([int](Get-CallbackArg $data 'urgentb:none:'))
            break
        }
        'urgentb:add' {
            Set-PendingState -ChatId $chatId -State @{ Mode = 'urgent_add_text'; UserId = $userId; StartedAt = (Get-Date) }
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sendNewUrgent')
            break
        }
        'urgentb:item:*' {
            Show-UrgentItemScreen -ChatId $chatId -Position ([int](Get-CallbackArg $data 'urgentb:item:')) -MessageId ([int]$msgObj.message_id)
            break
        }
        'urgentb:text:*' {
            $position = [int](Get-CallbackArg $data 'urgentb:text:')
            $item = Get-UrgentItemByPosition -Position $position
            if (-not $item) { Show-UrgentBoardScreen -ChatId $chatId -UserId $userId; break }
            Set-PendingState -ChatId $chatId -State @{ Mode = 'urgent_item_text'; UserId = $userId; ItemId = [string](Get-UrgentProperty $item 'Id' ''); StartedAt = (Get-Date) }
            Send-BridgeTextEditPrompt -ChatId $chatId -Prompt (T 'reply.sendUrgentReplacement') -Current ([string](Get-UrgentProperty $item 'Text' '')) -CancelData 'urgentb:open'
            break
        }
        'urgentb:title:*' {
            $position = [int](Get-CallbackArg $data 'urgentb:title:')
            $item = Get-UrgentItemByPosition -Position $position
            if (-not $item) { Show-UrgentBoardScreen -ChatId $chatId -UserId $userId; break }
            Set-PendingState -ChatId $chatId -State @{ Mode = 'urgent_item_title'; UserId = $userId; ItemId = [string](Get-UrgentProperty $item 'Id' ''); StartedAt = (Get-Date) }
            Send-BridgeTextEditPrompt -ChatId $chatId -Prompt (T 'reply.sendUrgentTitle') -Current ([string](Get-UrgentProperty $item 'Title' '')) -CancelData 'urgentb:open'
            break
        }
        'urgentb:interval:*' {
            $position = [int](Get-CallbackArg $data 'urgentb:interval:')
            Start-UrgentNumberPicker -ChatId $chatId -UserId $userId -Kind interval -Position $position -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'urgentb:repeats:*' {
            $position = [int](Get-CallbackArg $data 'urgentb:repeats:')
            Start-UrgentNumberPicker -ChatId $chatId -UserId $userId -Kind repeats -Position $position -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'urgentb:mode:*' {
            $position = [int](Get-CallbackArg $data 'urgentb:mode:')
            Invoke-UrgentItemModeSwitch -ChatId $chatId -UserId $userId -Position $position | Out-Null
            break
        }
        'urgentb:modereset:*' { Invoke-UrgentItemReset -ChatId $chatId -UserId $userId -Position ([int](Get-CallbackArg $data 'urgentb:modereset:')) -Field Mode | Out-Null; break }
        'urgentb:intervalreset:*' { Invoke-UrgentItemReset -ChatId $chatId -UserId $userId -Position ([int](Get-CallbackArg $data 'urgentb:intervalreset:')) -Field IntervalSeconds | Out-Null; break }
        'urgentb:repeatsreset:*' { Invoke-UrgentItemReset -ChatId $chatId -UserId $userId -Position ([int](Get-CallbackArg $data 'urgentb:repeatsreset:')) -Field Repeats | Out-Null; break }
        'urgentb:enable:*' { Invoke-UrgentItemEnableSwitch -ChatId $chatId -UserId $userId -Position ([int](Get-CallbackArg $data 'urgentb:enable:')) | Out-Null; break }
        'urgentb:up:*' { Invoke-UrgentItemMove -ChatId $chatId -UserId $userId -Position ([int](Get-CallbackArg $data 'urgentb:up:')) -Delta -1 | Out-Null; break }
        'urgentb:down:*' { Invoke-UrgentItemMove -ChatId $chatId -UserId $userId -Position ([int](Get-CallbackArg $data 'urgentb:down:')) -Delta 1 | Out-Null; break }
        'urgentb:itemdel:*' { Invoke-UrgentItemDelete -ChatId $chatId -UserId $userId -Position ([int](Get-CallbackArg $data 'urgentb:itemdel:')) | Out-Null; break }
        'urgentb:delask' { Show-UrgentDeleteConfirm -ChatId $chatId | Out-Null; break }
        'urgentb:delconfirm:*' { Invoke-UrgentSelectedDelete -ChatId $chatId -UserId $userId -Token (Get-CallbackArg $data 'urgentb:delconfirm:') | Out-Null; break }
        'urgentb:timing' { Clear-PendingState -ChatId $chatId; Show-UrgentTimingScreen -ChatId $chatId -MessageId ([int]$msgObj.message_id); break }
        'urgentb:dinterval' {
            Start-UrgentNumberPicker -ChatId $chatId -UserId $userId -Kind dinterval -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'urgentb:drepeats' {
            Start-UrgentNumberPicker -ChatId $chatId -UserId $userId -Kind drepeats -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'urgentb:dgap' {
            Start-UrgentNumberPicker -ChatId $chatId -UserId $userId -Kind dgap -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'urgentb:dtotal' {
            Start-UrgentNumberPicker -ChatId $chatId -UserId $userId -Kind dtotal -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'urgentb:dmanualhide' {
            Start-UrgentNumberPicker -ChatId $chatId -UserId $userId -Kind dmanualhide -MessageId ([int](Get-JsonProp $msgObj 'message_id'))
            break
        }
        'urgentb:num:*' { Invoke-UrgentNumberPick -ChatId $chatId -UserId $userId -Argument (Get-CallbackArg $data 'urgentb:num:') -MessageId ([int](Get-JsonProp $msgObj 'message_id')) | Out-Null; break }
        'urgentb:dorder' { Invoke-UrgentDefaultSwitch -ChatId $chatId -Field RepeatMode | Out-Null; break }
        'urgentb:dmode' { Invoke-UrgentDefaultSwitch -ChatId $chatId -Field Mode | Out-Null; break }
        'urgentb:review:sel' { Show-UrgentReviewScreen -ChatId $chatId -UserId $userId -SelectedOnly | Out-Null; break }
        'urgentb:review:all' { Show-UrgentReviewScreen -ChatId $chatId -UserId $userId | Out-Null; break }
        'urgentb:play:sel' { Start-UrgentBoardRun -ChatId $chatId -UserId $userId -SelectedOnly | Out-Null; break }
        'urgentb:play:all' { Start-UrgentBoardRun -ChatId $chatId -UserId $userId | Out-Null; break }
        'urgentb:stop' { Stop-UrgentBoardRun -ChatId $chatId -UserId $userId -Reason 'manual' | Out-Null; break }
        'urgentb:pause' { Suspend-UrgentBoardRun -ChatId $chatId -UserId $userId | Out-Null; Show-UrgentBoardScreen -ChatId $chatId -UserId $userId; break }
        'urgentb:resume' { Resume-UrgentBoardRun -ChatId $chatId -UserId $userId | Out-Null; Show-UrgentBoardScreen -ChatId $chatId -UserId $userId; break }
        'urgentb:skip' { Move-UrgentBoardNext -ChatId $chatId -UserId $userId | Out-Null; Show-UrgentBoardScreen -ChatId $chatId -UserId $userId; break }
        'urgentb:next' {
            $ready = @(Get-UrgentVisibleItems -ChatId $chatId | Where-Object { [bool](Get-UrgentProperty $_ 'Enabled' $true) -and -not (Test-UrgentItemOnAir -Item $_) })
            if ($ready.Count -eq 0) { Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noReadyUrgent') }
            else {
                Set-UrgentSelectedIds -ChatId $chatId -Ids @([string](Get-JsonProp $ready[0] 'Id'))
                Start-UrgentBoardRun -ChatId $chatId -UserId $userId -SelectedOnly | Out-Null
            }
            break
        }
        'urgentb:hide' {
            if (-not (Stop-UrgentCurrentAir -ChatId $chatId -UserId $userId)) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noRunToStop')
            }
            break
        }
        'mojaz:hide' { Clear-PendingState -ChatId $chatId; Hide-MojazOnAir -ChatId $chatId -UserId $userId | Out-Null; break }
        'mojaz:skip:*' { Switch-MojazRowSkip -RowId (Get-CallbackArg $data 'mojaz:skip:') -ChatId $chatId -UserId $userId; break }
        'mojaz:del:*' { Remove-MojazRow -RowId (Get-CallbackArg $data 'mojaz:del:') -ChatId $chatId -UserId $userId; break }
        'mojaz:up:*' { Move-MojazRow -RowId (Get-CallbackArg $data 'mojaz:up:') -Direction up -ChatId $chatId -UserId $userId; break }
        'mojaz:down:*' { Move-MojazRow -RowId (Get-CallbackArg $data 'mojaz:down:') -Direction down -ChatId $chatId -UserId $userId; break }
        'mojaz:clear' {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.confirmClearRows') `
                -ReplyMarkup (Get-MojazConfirmKeyboard -Question (T 'reply.yesClearRows') -ConfirmData 'mojaz:clearconfirm')
            break
        }
        'mojaz:clearconfirm' { Clear-MojazRows -ChatId $chatId -UserId $userId; break }
        'mojaz:drop' {
            $doomed = Get-MojazSelected -ChatId $chatId
            if (-not $doomed) { Show-MojazLibraryScreen -ChatId $chatId -UserId $userId; break }
            $waiting = @(Get-MojazBulletinSchedules -BulletinId ([string]$doomed.Id)).Count
            $warning = (T 'cb.confirmBoardDelete' $([string]$doomed.Name) $(@(Get-JsonProp $doomed 'Rows').Count))
            if ($waiting -gt 0) { $warning += (T 'cb.andCancelSlots' $waiting) }
            Send-TelegramMessage -ChatId $chatId -Text $warning `
                -ReplyMarkup (Get-MojazConfirmKeyboard -Question (T 'reply.yesDeleteBulletin') -ConfirmData 'mojaz:dropconfirm')
            break
        }
        'mojaz:dropconfirm' { Remove-MojazBulletinAndSchedules -ChatId $chatId -UserId $userId | Out-Null; break }
        { $_ -in @('menu', 'menu:main') } {
            Clear-PendingState -ChatId $chatId
            Show-MainMenuScreen -ChatId $chatId -UserId $userId
            break
        }
        'cancel' {
            Clear-PendingState -ChatId $chatId
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.cancelled') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'show:confirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_review' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.reviewExpired') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $key = [string]$state.Key
            $variables = $state.Values
            $autoHideSeconds = [int]$state.AutoHideSeconds
            Clear-PendingState -ChatId $chatId
            # Sending the urgent over a running bulletin is a choice, and this
            # is the last moment it can be offered. The pipeline itself never
            # asks - an automated urgent must not wait on a question.
            if ($key -eq $script:MojazUrgentKey -and $script:MojazPlayback) {
                Set-MojazPendingUrgent -Key $key -Variables $variables -AutoHideSeconds $autoHideSeconds -ChatId $chatId -UserId $userId
                Send-TelegramMessage -ChatId $chatId `
                    -Text (T 'cb.bulletinOnAirWhen' $([string]$script:MojazPlayback.BulletinName)) `
                    -ReplyMarkup (Get-MojazUrgentConflictKeyboard)
                break
            }
            Invoke-ShowTemplateResult -Key $key -Variables $variables -ChatId $chatId -UserId $userId -AutoHideSeconds $autoHideSeconds
            break
        }
        'show:edit' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_review' -or [long]$state.UserId -ne $userId -or @($state.Fields).Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noEditableReview') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $state.Mode = 'show_fields'
            $state.Index = 0
            Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text (Get-FieldPromptText -State $state) -ParseMode HTML -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'show:back' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId -or [int]$state.Index -le 0) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noPreviousStep') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $state.Index = [int]$state.Index - 1
            Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text (Get-FieldPromptText -State $state) -ParseMode HTML -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'show:preview' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId -or $state.Values.Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.nothingToPreview') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $preview = (T 'cb.currentDraftPreview' $(Format-ShowReviewText -State $state))
            Send-TelegramMessage -ChatId $chatId -Text $preview -ParseMode HTML -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'hideall:confirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'hide_all_review' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.hideAllExpired') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            Clear-PendingState -ChatId $chatId
            Invoke-HideAllLayers -ChatId $chatId -UserId $userId
            break
        }
        'skip' { Resume-ShowFlow -ChatId $chatId -Skip; break }
        'recent:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.inputDraftExpired') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $recentIndex = [int]((Get-CallbackArg $data 'recent:'))
            $fieldName = [string]$state.Fields[[int]$state.Index]
            $values = @(Get-RecentFieldValues -UserId $userId -FieldName $fieldName)
            if ($recentIndex -lt 0 -or $recentIndex -ge $values.Count) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.recentValueGone') -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
                break
            }
            Resume-ShowFlow -ChatId $chatId -Value ([string]$values[$recentIndex])
            break
        }
        'menu:templates' {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickTemplate') -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'tpl' -BrowseControls -ChatId $chatId -UserId $userId)
            break
        }
        'menu:templatesearch' {
            Start-TemplateSearch -ChatId $chatId -UserId $userId
            break
        }
        'menu:templatecategories' {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickCategory') -ReplyMarkup (Get-TemplateCategoriesKeyboard)
            break
        }
        'tplcat:*' {
            $categories = @(Get-TemplateCategories)
            $categoryIndex = [int](Get-CallbackArg $data 'tplcat:')
            if ($categoryIndex -lt 0 -or $categoryIndex -ge $categories.Count) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.categoryGone') -ReplyMarkup (Get-TemplateCategoriesKeyboard)
                break
            }
            $category = [string]$categories[$categoryIndex]
            Send-TelegramMessage -ChatId $chatId -Text (T 'cb.templatesOf' $category) -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -Category $category -BrowseControls -ChatId $chatId -UserId $userId)
            break
        }
        'tplinfo:*' {
            $templateIndex = [int](Get-CallbackArg $data 'tplinfo:')
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.templateGone') -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -BrowseControls -ChatId $chatId -UserId $userId)
                break
            }
            Send-TelegramMessage -ChatId $chatId -Text (Get-TemplatePreviewText -Template $template) -ParseMode HTML -ReplyMarkup (Get-TemplatePreviewKeyboard -TemplateIndex $templateIndex)
            break
        }
        'menu:favorites' {
            Send-TelegramMessage -ChatId $chatId -Text (Get-FavoritesManagementText -UserId $userId) -ParseMode HTML -ReplyMarkup (Get-FavoritesManagementKeyboard -UserId $userId)
            break
        }
        'favtoggle:*' {
            $template = Get-TemplateByIndex -Index ([int](Get-CallbackArg $data 'favtoggle:'))
            if (-not $template) { break }
            # The stored selection decides the direction of the toggle, not the
            # capped menu list: reading the capped list made a pick past
            # FavoritesCount permanently unremovable, because it never appeared
            # selected and every tap re-added a key that was already there.
            $selected = @(Get-UserFavoriteSelection -UserId $userId) -contains [string]$template.Key
            if (Set-UserFavorite -UserId $userId -TemplateKey ([string]$template.Key) -Enabled (-not $selected)) {
                $action = if ($selected) { (T 'reply.removedFrom') } else { (T 'reply.addedTo') }
                Add-AuditEntry (T 'cb.favouritesAudit' $($template.Key) $action $(Format-UserAuditActor -UserId $userId))
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.favouritesResult' $($template.Key) $action $(Get-FavoritesManagementText -UserId $userId)) -ReplyMarkup (Get-FavoritesManagementKeyboard -UserId $userId)
            }
            else {
                # A failed write used to be silent, so the tick simply did not
                # move and the user tapped again against a full or locked disk.
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.favouritesSaveFailed') -ReplyMarkup (Get-FavoritesManagementKeyboard -UserId $userId)
            }
            break
        }
        'menu:timed' {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickTemplateThenHide') -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'tplT' -ChatId $chatId -UserId $userId)
            break
        }
        'menu:hide' {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickLayerToHide') -ReplyMarkup (Get-LayersKeyboard -Prefix 'hide')
            break
        }
        'menu:exit' {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickLayerToExit') -ReplyMarkup (Get-LayersKeyboard -Prefix 'exit')
            break
        }
        'menu:hideall' {
            Request-HideAllConfirmation -ChatId $chatId -UserId $userId
            break
        }
        'menu:repeat' { Invoke-RepeatLastShow -ChatId $chatId -UserId $userId; break }
        'menu:myops' { Invoke-MyOperationsCommand -ChatId $chatId -UserId $userId; break }
        'menu:reports' { Show-ReportsMenu -ChatId $chatId -UserId $userId; break }
        'rep:banners:*' { Show-Report -ChatId $chatId -UserId $userId -Kind banners -Period (Get-CallbackArg $data 'rep:banners:'); break }
        'rep:news:*' { Show-Report -ChatId $chatId -UserId $userId -Kind news -Period (Get-CallbackArg $data 'rep:news:'); break }
        'rep:mojaz:*' { Show-Report -ChatId $chatId -UserId $userId -Kind mojaz -Period (Get-CallbackArg $data 'rep:mojaz:'); break }
        'rep:work:*' { Show-Report -ChatId $chatId -UserId $userId -Kind work -Period (Get-CallbackArg $data 'rep:work:'); break }
        'weekly:open' { Show-WeeklyReport -ChatId $chatId; break }
        'repdl:mojaz:*' { Export-BridgeReport -ChatId $chatId -UserId $userId -Kind mojaz -Period (Get-CallbackArg $data 'repdl:mojaz:'); break }
        'repdl:banners:*' { Export-BridgeReport -ChatId $chatId -UserId $userId -Kind banners -Period (Get-CallbackArg $data 'repdl:banners:'); break }
        'repdl:news:*' { Export-BridgeReport -ChatId $chatId -UserId $userId -Kind news -Period (Get-CallbackArg $data 'repdl:news:'); break }
        'ops:retry' { Invoke-RetryLastShowAttempt -ChatId $chatId -UserId $userId; break }
        'notice:mute' {
            [void](Set-AirNoticeMuted -UserId $userId -Muted $true)
            Write-BridgeLog "User $userId muted their on-air notices"
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noticesOff') `
                -ReplyMarkup @{ inline_keyboard = @(, @((New-Button (T 'reply.noticesBackButton') 'notice:unmute'))) }
            break
        }
        'notice:unmute' {
            [void](Set-AirNoticeMuted -UserId $userId -Muted $false)
            Write-BridgeLog "User $userId resumed their on-air notices"
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noticesOn') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'tnfy:c:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $index = -1
                if ([int]::TryParse((Get-CallbackArg $data 'tnfy:c:'), [ref]$index)) {
                    $keys = @(@((Get-TemplateStore).Order) | ForEach-Object { [string]$_ })
                    if ($index -ge 0 -and $index -lt $keys.Count) {
                        $key = $keys[$index]
                        $map = Get-TemplateNotifyMap
                        $current = if ($map.Contains($key)) { [string]$map[$key] } else { 'none' }
                        # none -> admins -> all -> none: widening by one tap,
                        # and back to silence without hunting for an off button.
                        $next = switch ($current) { 'none' { 'admins' } 'admins' { 'all' } default { 'none' } }
                        [void](Set-TemplateNotifyRule -Key $key -Scope $next)
                        Write-BridgeLog "User $userId set the on-air notice for '$key' to $next"
                        $page = [int][math]::Floor($index / 12)
                        Show-TemplateNotifyEditor -ChatId $chatId -UserId $userId -Page $page -MessageId ([int]$msgObj.message_id)
                    }
                }
            }
            break
        }
        'tnfy:p:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $page = 0
                if ([int]::TryParse((Get-CallbackArg $data 'tnfy:p:'), [ref]$page)) {
                    Show-TemplateNotifyEditor -ChatId $chatId -UserId $userId -Page $page -MessageId ([int]$msgObj.message_id)
                }
            }
            break
        }
        'access:history' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Invoke-AccessHistoryCommand -ChatId $chatId -UserId $userId
            }
            break
        }
        'oplog:all:day:*' {
            $day = [datetime]::MinValue
            if (Get-BridgeLogDay -Value (Get-CallbackArg $data 'oplog:all:day:') -Result ([ref]$day)) {
                Invoke-OperationLogCommand -ChatId $chatId -UserId $userId -Day $day -AllUsers
            }
            break
        }
        'oplog:day:*' {
            $day = [datetime]::MinValue
            if (Get-BridgeLogDay -Value (Get-CallbackArg $data 'oplog:day:') -Result ([ref]$day)) {
                Invoke-OperationLogCommand -ChatId $chatId -UserId $userId -Day $day
            }
            break
        }
        'mojazpage:*' {
            $mojazPage = 0
            if ([int]::TryParse((Get-CallbackArg $data 'mojazpage:'), [ref]$mojazPage) -and $mojazPage -ge 0) {
                Show-MojazScreen -ChatId $chatId -UserId $userId -Page $mojazPage
            }
            break
        }
        'papage:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $paParts = @((Get-CallbackArg $data 'papage:') -split ':')
                $paTemplate = -1
                $paPage = 0
                if ($paParts.Count -ge 2 -and
                    [int]::TryParse($paParts[0], [ref]$paTemplate) -and
                    [int]::TryParse($paParts[1], [ref]$paPage) -and $paPage -ge 0) {
                    Show-PresetAdminTemplate -TemplateIndex $paTemplate -ChatId $chatId -Page $paPage
                }
            }
            break
        }
        'tplpage:*' {
            $tplPageParts = @((Get-CallbackArg $data 'tplpage:') -split ':')
            $tplPage = 0
            if ($tplPageParts.Count -ge 2 -and $tplPageParts[0] -in @('tpl', 'tplT', 'updtpl') -and
                [int]::TryParse($tplPageParts[1], [ref]$tplPage) -and $tplPage -ge 0) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickTemplateShort') -ReplyMarkup (Get-TemplatesKeyboard -Prefix $tplPageParts[0] -BrowseControls -ChatId $chatId -UserId $userId -Page $tplPage)
            }
            break
        }
        'tplcatpg:*' {
            $catPageParts = @((Get-CallbackArg $data 'tplcatpg:') -split ':')
            $catIndex = -1
            $catPage = 0
            if ($catPageParts.Count -ge 2 -and
                [int]::TryParse($catPageParts[0], [ref]$catIndex) -and
                [int]::TryParse($catPageParts[1], [ref]$catPage) -and $catPage -ge 0) {
                $knownCategories = @(Get-TemplateCategories)
                if ($catIndex -ge 0 -and $catIndex -lt $knownCategories.Count) {
                    $pagedCategory = [string]$knownCategories[$catIndex]
                    Send-TelegramMessage -ChatId $chatId -Text (T 'cb.templatesOf' $pagedCategory) -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -Category $pagedCategory -BrowseControls -ChatId $chatId -UserId $userId -Page $catPage)
                }
            }
            break
        }
        'favpage:*' {
            $favPage = 0
            if ([int]::TryParse((Get-CallbackArg $data 'favpage:'), [ref]$favPage) -and $favPage -ge 0) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-FavoritesManagementText -UserId $userId) -ParseMode HTML -ReplyMarkup (Get-FavoritesManagementKeyboard -UserId $userId -Page $favPage)
            }
            break
        }
        'padmpage:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $presetPage = 0
                if ([int]::TryParse((Get-CallbackArg $data 'padmpage:'), [ref]$presetPage) -and $presetPage -ge 0) {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'cb.manageReadyTexts') -ReplyMarkup (Get-PresetAdminTemplatesKeyboard -Page $presetPage)
                }
            }
            break
        }
        'tplcatpage:*' {
            $categoryPage = 0
            if ([int]::TryParse((Get-CallbackArg $data 'tplcatpage:'), [ref]$categoryPage) -and $categoryPage -ge 0) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickCategory') -ReplyMarkup (Get-TemplateCategoriesKeyboard -Page $categoryPage)
            }
            break
        }
        'oplogcsv:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $csvParts = @((Get-CallbackArg $data 'oplogcsv:') -split ':')
            $csvHours = 48
            if ($csvParts.Count -lt 2 -or -not [int]::TryParse($csvParts[0], [ref]$csvHours) -or $csvHours -notin $script:OperationLogWindows) { break }
            $csvUserId = 0L
            $csvTarget = ''
            $csvPicked = 0L
            # A flag rather than `break` inside this switch: `break` there
            # leaves the INNER switch and carries on to the export, so a
            # malformed filter argument would have exported EVERY operation
            # instead of none - wider than the button promised, which is the
            # one direction an export must never fail in.
            $csvReady = $true
            switch ($csvParts[1]) {
                'mine' { $csvUserId = $userId }
                'all' { }
                'u' {
                    $pickedForCsv = 0L
                    if ($csvParts.Count -ge 3 -and [long]::TryParse($csvParts[2], [ref]$pickedForCsv) -and $pickedForCsv -gt 0) { $csvUserId = $pickedForCsv; $csvPicked = $pickedForCsv }
                    else { $csvReady = $false }
                }
                't' {
                    $csvTemplateIndex = -1
                    $csvTemplate = $null
                    if ($csvParts.Count -ge 3 -and [int]::TryParse($csvParts[2], [ref]$csvTemplateIndex)) {
                        $csvTemplate = Get-TemplateByIndex -Index $csvTemplateIndex
                    }
                    # A template that left the registry between the screen and
                    # the button must export nothing, not everything.
                    if ($csvTemplate) { $csvTarget = [string]$csvTemplate.Key } else { $csvReady = $false }
                }
                default { $csvReady = $false }
            }
            if ($csvReady) {
                Export-OperationLogCsv -ChatId $chatId -UserId $userId -Hours $csvHours -OnlyUserId $csvUserId -OnlyTarget $csvTarget -PickedUserId $csvPicked
            }
            break
        }
        'oplogpick:*' {
            $pickHours = 48
            if ([int]::TryParse((Get-CallbackArg $data 'oplogpick:'), [ref]$pickHours) -and $pickHours -in $script:OperationLogWindows) {
                # Built over the same records the operator is looking at, and
                # over THEIR scope: an operator picking from a list of names
                # they are not allowed to read would leak the roster this
                # screen exists to keep to administrators.
                $pickScope = if (Test-Admin -ChatId $chatId -UserId $userId) { 0 } else { $userId }
                $pickOptions = Get-OperationLogFilterOptions -Hours $pickHours -OnlyUserId $pickScope
                Send-TelegramMessage -ChatId $chatId -Text (Get-OperationLogFilterText -Options $pickOptions) -ParseMode HTML -ReplyMarkup (Get-OperationLogFilterKeyboard -Options $pickOptions)
            }
            break
        }
        'oplogu:*' {
            $userFilterParts = @((Get-CallbackArg $data 'oplogu:') -split ':')
            $userFilterHours = 48
            $pickedOperator = 0L
            if ($userFilterParts.Count -ge 2 -and
                [int]::TryParse($userFilterParts[0], [ref]$userFilterHours) -and
                $userFilterHours -in $script:OperationLogWindows -and
                [long]::TryParse($userFilterParts[1], [ref]$pickedOperator) -and $pickedOperator -gt 0) {
                Invoke-OperationLogCommand -ChatId $chatId -UserId $userId -Hours $userFilterHours -PickedUserId $pickedOperator
            }
            break
        }
        'oplogt:*' {
            $targetFilterParts = @((Get-CallbackArg $data 'oplogt:') -split ':')
            $targetFilterHours = 48
            $targetFilterIndex = -1
            if ($targetFilterParts.Count -ge 2 -and
                [int]::TryParse($targetFilterParts[0], [ref]$targetFilterHours) -and
                $targetFilterHours -in $script:OperationLogWindows -and
                [int]::TryParse($targetFilterParts[1], [ref]$targetFilterIndex)) {
                $filterTemplate = Get-TemplateByIndex -Index $targetFilterIndex
                if ($filterTemplate) {
                    # An administrator filtering by template asks about the
                    # template, not about themselves - so the operator scope
                    # widens with the same guard the all-users button uses.
                    if (Test-Admin -ChatId $chatId -UserId $userId) {
                        Invoke-OperationLogCommand -ChatId $chatId -UserId $userId -Hours $targetFilterHours -OnlyTarget ([string]$filterTemplate.Key) -AllUsers
                    }
                    else {
                        Invoke-OperationLogCommand -ChatId $chatId -UserId $userId -Hours $targetFilterHours -OnlyTarget ([string]$filterTemplate.Key)
                    }
                }
            }
            break
        }
        'oplog:all:*' {
            $hours = 48
            if ([int]::TryParse((Get-CallbackArg $data 'oplog:all:'), [ref]$hours) -and $hours -in $script:OperationLogWindows) {
                Invoke-OperationLogCommand -ChatId $chatId -UserId $userId -Hours $hours -AllUsers
            }
            break
        }
        'oplog:*' {
            # A window this build does not offer is ignored rather than
            # clamped: it can only come from an older keyboard, and answering
            # with a window different from the one the label promised is worse
            # than not answering.
            $hours = 48
            if ([int]::TryParse((Get-CallbackArg $data 'oplog:'), [ref]$hours) -and $hours -in $script:OperationLogWindows) {
                Invoke-OperationLogCommand -ChatId $chatId -UserId $userId -Hours $hours
            }
            break
        }
        'menu:update' {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickTemplateField') -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'updtpl' -ChatId $chatId -UserId $userId)
            break
        }
        'menu:snapshot' { Start-SnapshotJob -ChatId $chatId -UserId $userId; break }
        'menu:clip' { Start-SnapshotJob -ChatId $chatId -UserId $userId -Kind clip; break }
        'menu:feedwatch' { Show-FeedWatchScreen -ChatId $chatId; break }
        # The probe costs one frame grab, so it is a press rather than
        # something the plain open does on every visit.
        'menu:feedwatch:probe' { Show-FeedWatchScreen -ChatId $chatId -Probe -MessageId ([int](Get-JsonProp $msgObj 'message_id')); break }
        'menu:status' { Invoke-StatusCommand -ChatId $chatId -UserId $userId; break }
        'menu:material' { Show-MaterialScheduleScreen -ChatId $chatId -UserId $userId; break }
        'menu:handover' { Show-ShiftHandoverScreen -ChatId $chatId -UserId $userId; break }
        'handover:done' {
            # Recorded, not merely acknowledged: a spoken handover leaves
            # nothing behind, and "who had it when" is the first question
            # asked after anything goes wrong overnight.
            Add-AuditEntry (T 'cb.handoverAudit' $(Format-UserAuditActor -UserId $userId))
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.handoverRecorded') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'menu:fullstatus' {
            if (Test-CallbackStatusViewer -ChatId $chatId -UserId $userId) { Invoke-FullStatusCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:health' {
            # Backward-compatible callback for messages created before 3.0.
            if (Test-CallbackStatusViewer -ChatId $chatId -UserId $userId) { Invoke-FullStatusCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:diagnostics' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-DiagnosticsCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:healthcenter' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-HealthCenterCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:enginehealth' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-EngineHealthScreen -ChatId $chatId -UserId $userId }
            break
        }
        'health:files' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-RuntimeFileHealthCommand -ChatId $chatId -UserId $userId }
            break
        }
        'diag:findref' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-OperationReferenceLookup -ChatId $chatId -UserId $userId }
            break
        }
        'diag:bundle' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-DiagnosticBundleCommand -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearruntime' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-DiagnosticLogClear -Kind runtime -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearaudit' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-DiagnosticLogClear -Kind audit -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearconfirm' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -ne 'diagnostic_log_clear' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.clearExpired') -ReplyMarkup (Get-DiagnosticsKeyboard)
                break
            }
            $kind = [string]$state.Kind
            Clear-PendingState -ChatId $chatId
            if (Clear-DiagnosticLog -Kind $kind -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.logCleared') -ReplyMarkup (Get-DiagnosticsKeyboard)
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.logClearFailed') -ReplyMarkup (Get-DiagnosticsKeyboard)
            }
            break
        }
        'menu:layers' {
            # A hidden button is not a closed door: someone with the old
            # callback in their chat history can still press it.
            if (-not (Test-LayersScreenAccess -ChatId $chatId -UserId $userId)) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.layersScreenDenied') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $layerStatuses = @(Get-CinegyLayerDashboard)
            $comparison = Update-OnAirStateFromCinegy -Reason 'operator-check' -LayerStatuses $layerStatuses `
                -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal
            $comparisonText = @(
                (T 'cb.compareResult' $(@($comparison.Added).Count) $(@($comparison.Removed).Count) $(@($comparison.Failed).Count)),
                (Format-CinegyLayerDashboard -LayerStatuses $layerStatuses)
            ) -join "`n`n"
            Send-TelegramMessage -ChatId $chatId -Text $comparisonText -ReplyMarkup (Get-LayerDashboardKeyboard -LayerStatuses $layerStatuses)
            break
        }
        { $_ -in @((T 'reply.nameWord'), 'alias') } { Invoke-UserAliasCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        'menu:refreshstatus' {
            if (Test-CallbackStatusViewer -ChatId $chatId -UserId $userId) {
                Invoke-FullStatusCommand -ChatId $chatId -UserId $userId
            }
            break
        }
        { $_ -in @('menu:help', 'help:home') } {
            Send-TelegramMessage -ChatId $chatId -Text (Get-HelpHomeText -ChatId $chatId -UserId $userId) -ReplyMarkup (Get-HelpHomeKeyboard -ChatId $chatId -UserId $userId) -ParseMode HTML
            break
        }
        'help:quickstart' {
            Send-TelegramMessage -ChatId $chatId -Text (Get-QuickStartText -ChatId $chatId -UserId $userId) -ReplyMarkup @{inline_keyboard=@(,@(@{text=(T 'reply.helpIndex');callback_data='help:home'},@{text=(T 'reply.menu');callback_data='menu:main'}))}
            break
        }
        'help:full' {
            # One message with the chapters collapsed, so the whole manual is
            # on screen without scrolling past the chapters nobody wanted.
            # The paged text remains the fallback it always was.
            $helpKeyboard = Get-HelpHomeKeyboard -ChatId $chatId -UserId $userId
            $helpBlocks = Get-HelpRichBlocks -ChatId $chatId -UserId $userId
            if (-not (Send-TelegramRichMessage -ChatId $chatId -Blocks $helpBlocks -ReplyMarkup $helpKeyboard)) {
                Send-TelegramPagedText -ChatId $chatId -Text (Get-HelpText -ChatId $chatId -UserId $userId) -ReplyMarkup $helpKeyboard -ParseMode HTML
            }
            break
        }
        'help:ch:*' {
            $chapterKey = Get-CallbackArg $data 'help:ch:'
            $chapterText = Get-HelpChapterText -Key $chapterKey -ChatId $chatId -UserId $userId
            if ([string]::IsNullOrWhiteSpace($chapterText)) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-HelpHomeText -ChatId $chatId -UserId $userId) -ReplyMarkup (Get-HelpHomeKeyboard -ChatId $chatId -UserId $userId) -ParseMode HTML
                break
            }
            Send-TelegramMessage -ChatId $chatId -Text $chapterText -ReplyMarkup (Get-HelpChapterKeyboard -Key $chapterKey -ChatId $chatId -UserId $userId) -ParseMode HTML
            break
        }
        'menu:audit' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-AuditCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:settings' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-SettingsScreen -ChatId $chatId -UserId $userId }
            break
        }
        'quiet:on' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $script:ManualQuietUntil = (Get-Date).AddHours(2)
                Add-AuditEntry (T 'cb.quietUntilAudit' $($script:ManualQuietUntil.ToString('HH:mm')) $(Format-UserAuditActor -UserId $userId))
                Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text (T 'reply.quietTwoHours')
                Show-SettingsCategoryScreen -Category 'notifications' -Group 0 -Page 0 -ChatId $chatId -UserId $userId
            }
            break
        }
        'quiet:off' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $script:ManualQuietUntil = [datetime]::MinValue
                Add-AuditEntry (T 'cb.quietCancelledAudit' $(Format-UserAuditActor -UserId $userId))
                Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text (T 'reply.quietEnded')
                Show-SettingsCategoryScreen -Category 'notifications' -Group 0 -Page 0 -ChatId $chatId -UserId $userId
            }
            break
        }
        'cfgcat:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $category = ''
                $page = 0
                if ($data -match '^cfgcat:([a-z]+):(\d+)$' -and [int]::TryParse($Matches[2], [ref]$page)) {
                    $category = $Matches[1]
                    Show-SettingsCategoryScreen -Category $category -Page $page -ChatId $chatId -UserId $userId
                }
                else {
                    Show-SettingsScreen -ChatId $chatId -UserId $userId
                }
            }
            break
        }
        'cfgsub:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                if ($data -match '^cfgsub:([a-z]+):(\d{1,2}):(\d{1,4})$') {
                    Show-SettingsCategoryScreen -Category $Matches[1] -Group ([int]$Matches[2]) -Page ([int]$Matches[3]) -ChatId $chatId -UserId $userId
                }
                else { Show-SettingsScreen -ChatId $chatId -UserId $userId }
            }
            break
        }
        'cfg:search' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-SettingsSearch -ChatId $chatId -UserId $userId }
            break
        }
        'cfg:lang' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            # Two languages, so a toggle rather than a screen. Written through
            # Set-Setting like any other setting, so it is validated against
            # $script:SettingChoices, saved, and audited by the one path that
            # already does all three.
            $nextLanguage = if ((Get-BridgeLanguage) -eq 'ar') { 'en' } else { 'ar' }
            Set-Setting -Name 'Language' -Value $nextLanguage
            Write-BridgeLog "User $userId set Language = $nextLanguage"
            Add-AuditEntry (T 'cb.languageAudit' $nextLanguage $(Format-UserAuditActor -UserId $userId))
            # Announced in the NEW language, which is the only way an operator
            # who pressed it by mistake can tell that it worked.
            Send-TelegramMessage -ChatId $chatId -Text (T 'lang.changed')
            Show-SettingsScreen -ChatId $chatId -UserId $userId
            break
        }
        'cfglist:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                if ($data -match '^cfglist:(simple|advanced|modified):(\d+)$') { Show-SettingsListScreen -Mode $Matches[1] -Page ([int]$Matches[2]) -ChatId $chatId -UserId $userId }
            }
            break
        }
        'cfgrgo:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Reset-SingleSettingToDefault -Name (Get-CallbackArg $data 'cfgrgo:') -ChatId $chatId -UserId $userId -Confirmed }
            break
        }
        'cfgpick:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                # <setting>:<index> - the setting names itself so one callback
                # serves all four permission lists.
                $parts = ([string](Get-CallbackArg $data 'cfgpick:')) -split ':'
                $pick = 0
                $pickPage = 0
                if ($parts.Count -ge 3) { [int]::TryParse($parts[2], [ref]$pickPage) | Out-Null }
                if ($parts.Count -ge 2 -and [int]::TryParse($parts[1], [ref]$pick)) {
                    Switch-SettingPick -Name ([string]$parts[0]) -Index $pick -ChatId $chatId -UserId $userId -Page ([math]::Max(0, $pickPage))
                }
            }
            break
        }
        'cfgpickpage:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $parts = ([string](Get-CallbackArg $data 'cfgpickpage:')) -split ':'
                $pickPage = 0
                if ($parts.Count -ge 2 -and [int]::TryParse($parts[1], [ref]$pickPage) -and $pickPage -ge 0) {
                    Show-SettingPicker -Name ([string]$parts[0]) -ChatId $chatId -UserId $userId -Page $pickPage
                }
            }
            break
        }
        'cfgpickclear:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Clear-SettingPick -Name (Get-CallbackArg $data 'cfgpickclear:') -ChatId $chatId -UserId $userId }
            break
        }
        'cfgr:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Reset-SingleSettingToDefault -Name (Get-CallbackArg $data 'cfgr:') -ChatId $chatId -UserId $userId }
            break
        }
        'cancelreason:*' {
            $pending = $script:PendingCancelReason
            if ($pending -and [long]$pending.UserId -eq $userId) {
                Add-CancelReason -Reason (Get-CallbackArg $data 'cancelreason:') -UserId $userId -Key ([string]$pending.Key)
                $script:PendingCancelReason = $null
                Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text (T 'reply.recordedThanks')
            }
            Show-MainMenuScreen -ChatId $chatId -UserId $userId
            break
        }
        'menu:digest' {
            $digestHours = Get-SettingInt 'MissedEventsHours' 1
            $digestMenu = Get-MainMenuKeyboard -ChatId $chatId -UserId $userId
            if (Send-TelegramRichMessage -ChatId $chatId -Blocks (Get-MissedEventsBlocks -Hours $digestHours) -ReplyMarkup $digestMenu) { break }
            Send-TelegramMessage -ChatId $chatId -Text (Get-MissedEventsText -Hours $digestHours) -ParseMode HTML -ReplyMarkup $digestMenu
            break
        }
        'menu:sharestatus' {
            # Sent as its own message with no keyboard, so a long-press copies just
            # the summary rather than the surrounding chrome.
            Send-TelegramMessage -ChatId $chatId -Text (Get-OnAirShareText)
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.copyAndSend') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'menu:stats' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $statsKeyboard = Get-AdminToolsKeyboard
                if (-not (Send-TelegramRichMessage -ChatId $chatId -Blocks (Get-BridgeStatsBlocks) -ReplyMarkup $statsKeyboard)) {
                    Send-TelegramMessage -ChatId $chatId -Text (Get-BridgeStatsText) -ParseMode HTML -ReplyMarkup $statsKeyboard
                }
            }
            break
        }
        'menu:changelog' {
            $changelogPath = Join-Path $scriptRoot 'CHANGELOG.md'
            if (Test-Path -LiteralPath $changelogPath) {
                if (-not (Send-TelegramDocument -ChatId $chatId -FilePath $changelogPath -Caption (T 'reply.fullChangelog'))) {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sendFileFailed') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                }
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.changelogMissing') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'menu:whatsnew' {
            Send-TelegramPagedText -ChatId $chatId -Parts (Get-WhatsNewParts) -ReplyMarkup (Get-WhatsNewKeyboard -ChatId $chatId -UserId $userId) -ParseMode HTML
            break
        }
        'menu:restart' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-BridgeRestart -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'restart:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-BridgeRestart -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'menu:cfgexport' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-SettingsExport -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'menu:cfgimport' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'settings_import_upload'; UserId = $userId; StartedAt = (Get-Date) }
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sendSettingsFile') -ReplyMarkup (Get-CancelKeyboard)
            }
            break
        }
        'cfgimport:apply' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-SettingsImport -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'cfgimport:cancel' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-SettingsImport -ChatId $chatId -UserId $userId -Cancel | Out-Null }
            break
        }
        'menu:usagedigest' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $usageKeyboard = Get-AdminToolsKeyboard
                if (-not (Send-TelegramRichMessage -ChatId $chatId -Blocks (Get-UsageDigestBlocks) -ReplyMarkup $usageKeyboard)) {
                    Send-TelegramMessage -ChatId $chatId -Text (Get-UsageDigestText) -ParseMode HTML -ReplyMarkup $usageKeyboard
                }
            }
            break
        }
        'menu:selftest' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-BridgeSelfTest -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'menu:readiness' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-ShiftReadinessScreen -ChatId $chatId -UserId $userId }
            break
        }
        'menu:admintools' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.adminTools') -ReplyMarkup (Get-AdminToolsKeyboard)
            }
            break
        }
        'admintools:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $category = Get-CallbackArg $data 'admintools:'
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.adminTools') -ReplyMarkup (Get-AdminToolsCategoryKeyboard -Category $category -ChatId $chatId -UserId $userId)
            }
            break
        }
        'menu:announcements' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-AnnouncementsScreen -ChatId $chatId -UserId $userId }
            break
        }
        'annpage:*' {
            $page = 0
            if ((Test-CallbackAdmin -ChatId $chatId -UserId $userId) -and
                [int]::TryParse((Get-CallbackArg $data 'annpage:'), [ref]$page) -and $page -ge 0) {
                Show-AnnouncementsScreen -ChatId $chatId -UserId $userId -Page $page
            }
            break
        }
        'ann:new' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-AnnouncementCompose -ChatId $chatId -UserId $userId }
            break
        }
        'annopt:send' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Complete-AnnouncementSend -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'annopt:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Switch-AnnouncementOption -Option (Get-CallbackArg $data 'annopt:') -ChatId $chatId | Out-Null
            }
            break
        }
        'anncancel:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Stop-BridgeAnnouncement -AnnouncementId (Get-CallbackArg $data 'anncancel:') -UserId $userId | Out-Null
                Show-AnnouncementsScreen -ChatId $chatId -UserId $userId
            }
            break
        }
        'annack:*' {
            # Any authorized user, not only an administrator: this is the
            # button on the notice they were sent.
            if (Confirm-AnnouncementRead -AnnouncementId (Get-CallbackArg $data 'annack:') -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.thanksRecorded') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'menu:usersadmin' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-UsersAdminScreen -ChatId $chatId -UserId $userId }
            break
        }
        'menu:deadchats' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-DeadChatsScreen -ChatId $chatId -UserId $userId }
            break
        }
        'deadchat:un:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $target = 0L
            if ([long]::TryParse((Get-CallbackArg $data 'deadchat:un:'), [ref]$target) -and $target -gt 0) {
                Restore-DeadChat -ChatId $target
                Show-DeadChatsScreen -ChatId $chatId -UserId $userId
            }
            break
        }
        'deadchat:probe:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $target = 0L
            if ([long]::TryParse((Get-CallbackArg $data 'deadchat:probe:'), [ref]$target) -and $target -gt 0) {
                Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id | Out-Null
                Test-DeadChatDelivery -TargetChatId $target -ChatId $chatId -UserId $userId
            }
            break
        }
        'deadchat:revoke:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $target = 0L
            if ([long]::TryParse((Get-CallbackArg $data 'deadchat:revoke:'), [ref]$target) -and $target -gt 0) {
                $result = Revoke-AuthorizedUser -TargetUserId $target
                if ($result -and $result.Success) {
                    Restore-DeadChat -ChatId $target
                    Add-AuditEntry (T 'cb.deadChatRevokedAudit' $target $(Format-UserAuditActor -UserId $userId))
                    Show-DeadChatsScreen -ChatId $chatId -UserId $userId
                }
                else {
                    $why = if ($result) { [string]$result.Error } else { (T 'reply.pullFailed') }
                    Send-TelegramMessage -ChatId $chatId -Text "❌ $why" -ReplyMarkup (Get-UsersAdminKeyboard -ViewerUserId $userId)
                }
            }
            break
        }
        'deadchat:page:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $page = 0
                [int]::TryParse((Get-CallbackArg $data 'deadchat:page:'), [ref]$page) | Out-Null
                if ($page -lt 0) { $page = 0 }
                Show-DeadChatsScreen -ChatId $chatId -UserId $userId -Page $page
            }
            break
        }
        'userspage:*' {
            $page = 0
            if ((Test-CallbackAdmin -ChatId $chatId -UserId $userId) -and
                [int]::TryParse((Get-CallbackArg $data 'userspage:'), [ref]$page) -and $page -ge 0) {
                Show-UsersAdminScreen -ChatId $chatId -UserId $userId -Page $page
            }
            break
        }
        'usr:card:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                # <userId>:<page> - the page rides along so the card's back
                # button returns to the page the roster was on.
                $parts = ([string](Get-CallbackArg $data 'usr:card:')) -split ':'
                $cardUserId = 0L
                $cardPage = 0
                if ($parts.Count -ge 2) { [int]::TryParse($parts[1], [ref]$cardPage) | Out-Null }
                if ([long]::TryParse([string]$parts[0], [ref]$cardUserId) -and $cardUserId -gt 0) {
                    Show-UserCardScreen -TargetUserId $cardUserId -ChatId $chatId -UserId $userId -Page ([math]::Max(0, $cardPage))
                }
            }
            break
        }
        'usr:activity:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $targetUserId = [long](Get-CallbackArg $data 'usr:activity:')
                Send-TelegramMessage -ChatId $chatId -Text (Get-UserActivityDetailText -TargetUserId $targetUserId) -ParseMode HTML `
                    -ReplyMarkup (Get-UsersAdminKeyboard -ViewerUserId $userId)
            }
            break
        }
        'usr:toggle:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $target = [long](Get-CallbackArg $data 'usr:toggle:'); $disabled = Test-UserDisabled -UserId $target
            if (Set-UserDisabled -TargetUserId $target -Disabled (-not $disabled)) {
                $action = if ($disabled) { (T 'reply.reEnable') } else { (T 'reply.disableWord') }
                Write-BridgeLog "Admin $userId changed user $target state: $action"
                Add-AuditEntry (T 'cb.userAudit' $action $(Format-UserAuditActor -UserId $target) $(Format-UserAuditActor -UserId $userId))
                Show-UsersAdminScreen -ChatId $chatId -UserId $userId
            }
            break
        }
        'usr:alias:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Start-UserAliasEdit -TargetUserId ([long](Get-CallbackArg $data 'usr:alias:')) -ChatId $chatId -AdminUserId $userId
            }
            break
        }
        'usr:revoke:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-UserRevocation -TargetUserId ([long](Get-CallbackArg $data 'usr:revoke:')) -ChatId $chatId -AdminUserId $userId }
            break
        }
        'usr:revokeconfirm' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'user_revoke' -or [long]$state.UserId -ne $userId) { break }
            $target = [long]$state.TargetUserId; Clear-PendingState -ChatId $chatId
            $result = Revoke-AuthorizedUser -TargetUserId $target
            if ($result.Success) {
                Write-BridgeLog "Admin $userId revoked user $target" 'WARN'
                Add-AuditEntry (T 'cb.userRevokedAudit' $(Format-UserAuditActor -UserId $target) $(Format-UserAuditActor -UserId $userId))
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.userRevoked' $target) -ReplyMarkup (Get-UsersAdminKeyboard)
            }
            else { Send-TelegramMessage -ChatId $chatId -Text "❌ $($result.Error)" -ReplyMarkup (Get-UsersAdminKeyboard) }
            break
        }
        'usr:promote:*' {
            if (-not (Test-CallbackOwner -ChatId $chatId -UserId $userId)) { break }
            Request-AdminRoleChange -TargetUserId ([long](Get-CallbackArg $data 'usr:promote:')) -ChatId $chatId -OwnerUserId $userId -IsAdmin $true
            break
        }
        'usr:demote:*' {
            if (-not (Test-CallbackOwner -ChatId $chatId -UserId $userId)) { break }
            Request-AdminRoleChange -TargetUserId ([long](Get-CallbackArg $data 'usr:demote:')) -ChatId $chatId -OwnerUserId $userId -IsAdmin $false
            break
        }
        'usr:roleconfirm' {
            # Re-checked here, not only when the button was drawn: ownership
            # can have been reconfigured between the two taps.
            if (-not (Test-CallbackOwner -ChatId $chatId -UserId $userId)) { break }
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'user_role' -or [long]$state.UserId -ne $userId) { break }
            $target = [long]$state.TargetUserId; $makeAdmin = [bool]$state.IsAdmin
            Clear-PendingState -ChatId $chatId
            $result = Set-AdminRole -TargetUserId $target -IsAdmin $makeAdmin
            if ($result.Success) {
                $what = if ($makeAdmin) { (T 'reply.promoteToAdmin') } else { (T 'reply.demoteToOperator') }
                Write-BridgeLog "Owner $userId performed '$what' on user $target" 'WARN'
                Add-AuditEntry (T 'cb.roleAudit' $what $(Format-UserAuditActor -UserId $target) $(Format-UserAuditActor -UserId $userId))
                # So the ☰ menu matches the new role straight away, rather
                # than still offering ⚙️ الإعدادات to someone just demoted.
                Register-BotCommands
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.roleDone' $what $(Get-UserDisplayName -UserId $target))
                # Told to their face: a role change applied silently is one the
                # person only discovers when a button stops working.
                Send-TelegramMessage -ChatId $target -Text $(if ($makeAdmin) {
                        (T 'reply.youWerePromoted')
                    }
                    else { (T 'reply.youWereDemoted') })
            }
            else { Send-TelegramMessage -ChatId $chatId -Text "❌ $($result.Error)" }
            Show-UsersAdminScreen -ChatId $chatId -UserId $userId
            break
        }
        'more:next' {
            # Nothing waiting is not an error: the operator tapped an old
            # message after the bridge restarted, and saying so is kinder than
            # silence.
            if (-not (Send-TelegramPagedChunk -ChatId $chatId)) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.nothingMoreToShow') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'menu:layernames' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-LayerNamesScreen -ChatId $chatId -UserId $userId }
            break
        }
        'menu:hideallsettings' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-HideAllLayerSettings -ChatId $chatId -UserId $userId }
            break
        }
        'menu:schedule' {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.schedulingIntro') -ReplyMarkup (Get-ScheduleMenuKeyboard)
            break
        }
        'schedule:new' {
            $clock = Get-SystemClockStatus
            if (-not $clock.Success) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.clockInvalid') -ReplyMarkup (Get-ScheduleMenuKeyboard)
                break
            }
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickTemplateToSchedule') -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'schtpl' -ChatId $chatId -UserId $userId)
            break
        }
        'schedule:execlog' {
            # Every fired occurrence has been logged since scheduling shipped;
            # until now the only way to read it was opening the .jsonl by hand.
            Show-ScheduleExecutionScreen -ChatId $chatId -UserId $userId
            break
        }
        'schedule:execlog:*' {
            # Same screen filtered, reached from the bulletin schedules and the
            # ticker management screens where the question actually gets asked.
            $execKind = Get-CallbackArg $data 'schedule:execlog:'
            if ($execKind -notin @('show', 'mojaz', 'news')) { $execKind = '' }
            Show-ScheduleExecutionScreen -ChatId $chatId -UserId $userId -Kind $execKind
            break
        }
        'schedule:list' {
            if (-not (Send-TelegramRichMessage -ChatId $chatId -Blocks (Get-UpcomingScheduleBlocks) -ReplyMarkup (Get-UpcomingScheduleKeyboard))) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-UpcomingScheduleText) -ParseMode 'HTML' `
                    -ReplyMarkup (Get-UpcomingScheduleKeyboard)
            }
            break
        }
        'schedupage:*' {
            $page = 0
            if ([int]::TryParse((Get-CallbackArg $data 'schedupage:'), [ref]$page) -and $page -ge 0) {
                if (-not (Send-TelegramRichMessage -ChatId $chatId -Blocks (Get-UpcomingScheduleBlocks -Page $page) -ReplyMarkup (Get-UpcomingScheduleKeyboard -Page $page))) {
                    Send-TelegramMessage -ChatId $chatId -Text (Get-UpcomingScheduleText -Page $page) -ParseMode 'HTML' `
                        -ReplyMarkup (Get-UpcomingScheduleKeyboard -Page $page)
                }
            }
            break
        }
        # The date/time picker. Every branch re-renders in place so the
        # calendar, the hours and the minutes reuse one message instead of
        # leaving three stale grids behind.
        'schcal:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -notin @('schedule_time', 'mojaz_start_at')) { break }
            Edit-TelegramMessageText -ChatId $chatId -MessageId ([int]$msgObj.message_id) `
                -Text (T 'reply.pickDay') -ReplyMarkup (Get-ScheduleCalendarKeyboard -Month (Get-CallbackArg $data 'schcal:')) | Out-Null
            break
        }
        'schday:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -notin @('schedule_time', 'mojaz_start_at')) { break }
            $day = [string](Get-CallbackArg $data 'schday:')
            Edit-TelegramMessageText -ChatId $chatId -MessageId ([int]$msgObj.message_id) `
                -Text (T 'cb.pickHour' $day) -ReplyMarkup (Get-ScheduleHourKeyboard -Date $day) | Out-Null
            break
        }
        'schhour:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -notin @('schedule_time', 'mojaz_start_at')) { break }
            $parts = ([string](Get-CallbackArg $data 'schhour:')) -split ':'
            Edit-TelegramMessageText -ChatId $chatId -MessageId ([int]$msgObj.message_id) `
                -Text (T 'cb.pickMinute' $($parts[0]) $($parts[1])) -ReplyMarkup (Get-ScheduleMinuteKeyboard -Date $parts[0] -Hour ([int]$parts[1])) | Out-Null
            break
        }
        'schmin:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -notin @('schedule_time', 'mojaz_start_at')) { break }
            $parts = ([string](Get-CallbackArg $data 'schmin:')) -split ':'
            # Through the same parser the typed path uses, so the picker
            # cannot produce a moment the parser would have refused - a past
            # minute, or one inside a daylight-saving gap.
            $parsed = ConvertFrom-OperatorScheduleTime -Text ("{0} {1:00}:{2:00}" -f $parts[0], [int]$parts[1], [int]$parts[2])
            if (-not $parsed.Success) {
                Send-TelegramMessage -ChatId $chatId -Text "❌ $($parsed.Error)" -ReplyMarkup (Get-ScheduleTimePromptKeyboard)
                break
            }
            Set-BridgeChosenMoment -ChatId $chatId -State $state -ScheduledAt $parsed.ScheduledAt -TimeZoneId $parsed.TimeZoneId
            break
        }
        'schrel:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -notin @('schedule_time', 'mojaz_start_at')) { break }
            $parsed = ConvertFrom-OperatorScheduleTime -Text "+$(Get-CallbackArg $data 'schrel:')"
            if (-not $parsed.Success) {
                Send-TelegramMessage -ChatId $chatId -Text "❌ $($parsed.Error)" -ReplyMarkup (Get-ScheduleTimePromptKeyboard)
                break
            }
            Set-BridgeChosenMoment -ChatId $chatId -State $state -ScheduledAt $parsed.ScheduledAt -TimeZoneId $parsed.TimeZoneId
            break
        }
        'schtpl:*' {
            Start-ScheduleShowFlow -TemplateIndex ([int](Get-CallbackArg $data 'schtpl:')) -ChatId $chatId -UserId $userId
            break
        }
        'schrec:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_recurrence' -or [long]$state.UserId -ne $userId) { break }
            $state.Recurrence = (Get-CallbackArg $data 'schrec:')
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schedule:confirm' {
            Confirm-ScheduledShow -ChatId $chatId -UserId $userId
            break
        }
        # T-52: tie a one-off event to channel material instead of wall-clock
        # time. The picker carries positions, not names: callback_data is
        # capped at 64 bytes and a material name alone can exceed it.
        'schedule:anchor' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $userId -or [string]$state.Recurrence -ne 'once') { break }
            $timeout = Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1
            $rundown = Get-AirMaterialSchedule -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -TimeoutSec $timeout
            if (-not $rundown -or -not $rundown.Success) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.materialUnreadable') -ReplyMarkup (Get-ScheduleReviewKeyboard -State $state)
                break
            }
            $choices = @(Get-ScheduleAnchorChoices -Items @($rundown.Items))
            if ($choices.Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noUpcomingMaterial') -ReplyMarkup (Get-ScheduleReviewKeyboard -State $state)
                break
            }
            $state.AnchorChoices = @($choices)
            $state.Mode = 'schedule_anchor'; Set-PendingState -ChatId $chatId -State $state
            Edit-TelegramMessageText -ChatId $chatId -MessageId ([int]$msgObj.message_id) `
                -Text (T 'reply.pickMaterial') -ReplyMarkup (Get-ScheduleAnchorPickerKeyboard -Choices $choices) | Out-Null
            break
        }
        'schanchor:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_anchor' -or [long]$state.UserId -ne $userId) { break }
            $index = -1
            if (-not [int]::TryParse((Get-CallbackArg $data 'schanchor:'), [ref]$index)) { break }
            $choices = @($state.AnchorChoices)
            if ($index -lt 0 -or $index -ge $choices.Count) { break }
            $state.AnchorMaterialId = [string]$choices[$index].Id
            $state.AnchorMaterialName = [string]$choices[$index].Name
            $state.Mode = 'schedule_anchor_offset'; Set-PendingState -ChatId $chatId -State $state
            $safeName = ConvertTo-TelegramHtmlText ([string]$choices[$index].Name)
            Edit-TelegramMessageText -ChatId $chatId -MessageId ([int]$msgObj.message_id) `
                -Text (T 'cb.itemWhenGraphic' $safeName) -ReplyMarkup (Get-ScheduleAnchorOffsetKeyboard) | Out-Null
            break
        }
        'schoff:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_anchor_offset' -or [long]$state.UserId -ne $userId) { break }
            $offset = -1
            if (-not [int]::TryParse((Get-CallbackArg $data 'schoff:'), [ref]$offset) -or $offset -lt 0) { break }
            $choices = @($state.AnchorChoices)
            $match = @($choices | Where-Object { [string]$_.Id -eq [string]$state.AnchorMaterialId }) | Select-Object -First 1
            if (-not $match) {
                $state.AnchorMaterialId = ''; $state.AnchorOffsetSeconds = 0
                $state.Mode = 'schedule_review'; Set-PendingState -ChatId $chatId -State $state
                Show-ScheduleReview -ChatId $chatId -State $state
                break
            }
            $state.AnchorOffsetSeconds = $offset
            $resolved = ([datetimeoffset]$match.ScheduledAt).AddSeconds($offset)
            $state.ScheduledAt = $resolved.ToString('o')
            $state.Mode = 'schedule_review'; Set-PendingState -ChatId $chatId -State $state
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schedule:anchorback' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -notin @('schedule_anchor', 'schedule_anchor_offset') -or [long]$state.UserId -ne $userId) { break }
            $state.AnchorMaterialId = ''; $state.AnchorOffsetSeconds = 0
            $state.Mode = 'schedule_review'; Set-PendingState -ChatId $chatId -State $state
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schedule:unanchor' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $userId) { break }
            $state.AnchorMaterialId = ''; $state.AnchorOffsetSeconds = 0
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schedule:setend' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $userId -or [string]$state.Recurrence -eq 'once') { break }
            $state.Mode = 'schedule_end_date'; Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sendEndDate') -ReplyMarkup (Get-CancelKeyboard)
            break
        }
        'schedule:clearend' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $userId) { break }
            $state.RecurrenceUntil = ''
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schededit:*' {
            Start-ScheduleMutationFlow -Action edit -EventId (Get-CallbackArg $data 'schededit:') -ChatId $chatId -UserId $userId
            break
        }
        'schedcopy:*' {
            Start-ScheduleMutationFlow -Action copy -EventId (Get-CallbackArg $data 'schedcopy:') -ChatId $chatId -UserId $userId
            break
        }
        'schcancel:*' {
            $eventId = (Get-CallbackArg $data 'schcancel:')
            $scheduleEntry = @(Get-UpcomingScheduleEvents | Where-Object { [string]$_.Id -eq $eventId }) | Select-Object -First 1
            if (-not $scheduleEntry) { break }
            Set-PendingState -ChatId $chatId -State @{ Mode = 'schedule_cancel'; EventId = $eventId; UserId = $userId }
            Send-TelegramMessage -ChatId $chatId -Text (T 'cb.confirmEventCancel' $(Format-ScheduleEvent -ScheduleEntry $scheduleEntry)) -ReplyMarkup @{ inline_keyboard = @(, @((New-Button (T 'reply.yesCancel') 'schedule:cancelconfirm' -Style danger), (New-Button (T 'cb.back') 'schedule:list'))) }
            break
        }
        'schedule:cancelconfirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_cancel' -or [long]$state.UserId -ne $userId) { break }
            $cancelled = Stop-ScheduledShowEvent -Id ([string]$state.EventId)
            Clear-PendingState -ChatId $chatId
            $text = if ($cancelled) { (T 'reply.eventCancelled') } else { (T 'reply.eventCancelFailed') }
            Send-TelegramMessage -ChatId $chatId -Text $text -ReplyMarkup (Get-ScheduleMenuKeyboard)
            break
        }
        'menu:presetsadmin' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.manageReadyTexts') -ReplyMarkup (Get-PresetAdminTemplatesKeyboard)
            }
            break
        }
        'menu:templatesadmin' {
            if (Test-CallbackTemplateReminderManager -ChatId $chatId -UserId $userId) {
                $pendingImport = Get-PendingState -ChatId $chatId
                if ($pendingImport -and [string]$pendingImport.Mode -like 'template_import_*') { Clear-PendingState -ChatId $chatId }
                Send-TelegramMessage -ChatId $chatId -Text (Get-TemplateAdminCatalogueText) -ParseMode HTML -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        # D2: delete an invalid registry entry. Positional over a live
        # re-read: the registry can change between taps, so every step
        # re-resolves and a stale index lands back on the list, not on the
        # wrong template. Guards and backup ride inside
        # Save-TemplateDefinitionChange.
        'tpladmin:invalid' {
            if (Test-CallbackTemplateReminderManager -ChatId $chatId -UserId $userId) { Show-InvalidTemplatesScreen -ChatId $chatId -UserId $userId }
            break
        }
        'tplinv:page:*' {
            if (Test-CallbackTemplateReminderManager -ChatId $chatId -UserId $userId) {
                $page = 0
                [int]::TryParse((Get-CallbackArg $data 'tplinv:page:'), [ref]$page) | Out-Null
                if ($page -lt 0) { $page = 0 }
                Show-InvalidTemplatesScreen -ChatId $chatId -UserId $userId -Page $page
            }
            break
        }
        'tplinv:ask:*' {
            if (-not (Test-CallbackTemplateReminderManager -ChatId $chatId -UserId $userId)) { break }
            $index = -1
            $entries = @(Get-InvalidTemplateEntries)
            if (-not [int]::TryParse((Get-CallbackArg $data 'tplinv:ask:'), [ref]$index) -or $index -lt 0 -or $index -ge $entries.Count) {
                Show-InvalidTemplatesScreen -ChatId $chatId -UserId $userId
                break
            }
            $key = [string]$entries[$index].Key
            Send-TelegramMessage -ChatId $chatId -Text (T 'cb.confirmInvalidDelete' $key $(ConvertTo-TelegramHtmlText $entries[$index].Reason)) -ReplyMarkup @{ inline_keyboard = @(, @((New-Button (T 'reply.yesDelete') "tplinv:go:$index" -Style danger), (New-Button (T 'reply.back') 'tpladmin:invalid'))) }
            break
        }
        'tplinv:go:*' {
            if (-not (Test-CallbackTemplateReminderManager -ChatId $chatId -UserId $userId)) { break }
            $index = -1
            $entries = @(Get-InvalidTemplateEntries)
            if (-not [int]::TryParse((Get-CallbackArg $data 'tplinv:go:'), [ref]$index) -or $index -lt 0 -or $index -ge $entries.Count) {
                Show-InvalidTemplatesScreen -ChatId $chatId -UserId $userId
                break
            }
            $key = [string]$entries[$index].Key
            $result = Save-TemplateDefinitionChange -TemplateKey $key -Action delete
            if ($result -and $result.Success) {
                Add-AuditEntry (T 'cb.invalidDeletedAudit' $key $(Format-UserAuditActor -UserId $userId))
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.deletedWithBackup' $key)
            }
            else {
                $why = if ($result) { [string]$result.Error } else { (T 'reply.deleteFailed') }
                Send-TelegramMessage -ChatId $chatId -Text "❌ $why"
            }
            Show-InvalidTemplatesScreen -ChatId $chatId -UserId $userId
            break
        }
        'tadmpage:*' {
            $page = 0
            if ((Test-CallbackTemplateReminderManager -ChatId $chatId -UserId $userId) -and
                [int]::TryParse((Get-CallbackArg $data 'tadmpage:'), [ref]$page) -and $page -ge 0) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-TemplateAdminCatalogueText -Page $page) -ParseMode HTML -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $chatId -UserId $userId -Page $page)
            }
            break
        }
        'timport:export' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-TemplateRegistryExport -ChatId $chatId -UserId $userId }
            break
        }
        'timport:start' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-TemplateRegistryImport -ChatId $chatId -UserId $userId }
            break
        }
        'timport:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-TemplateRegistryImport -ChatId $chatId -UserId $userId }
            break
        }
        'tadm:*' {
            $token = (Get-CallbackArg $data 'tadm:')
            if ($token -match '^reminder:(\d+)$') {
                if (Test-CallbackTemplateReminderManager -ChatId $chatId -UserId $userId) {
                    Start-TemplateReminderMinutesPrompt -TemplateIndex ([int]$Matches[1]) -ChatId $chatId -UserId $userId
                }
            }
            elseif ($token -match '^\d+$') {
                if (Test-CallbackTemplateReminderManager -ChatId $chatId -UserId $userId) {
                    Show-TemplateAdminDetail -TemplateIndex ([int]$token) -ChatId $chatId -UserId $userId
                }
            }
            elseif (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                if ($token -eq 'create') { Start-TemplateCreateWizard -ChatId $chatId -UserId $userId }
                elseif ($token -eq 'createjson') { Start-TemplateDefinitionPrompt -Action create -ChatId $chatId -UserId $userId }
                elseif ($token -eq 'confirm') { Confirm-TemplateDefinitionChange -ChatId $chatId -UserId $userId }
                elseif ($token -eq 'testconfirm') { Confirm-TemplateTest -ChatId $chatId -UserId $userId }
                elseif ($token -match '^test:(\d+)$') { Start-TemplateTestReview -TemplateIndex ([int]$Matches[1]) -ChatId $chatId -UserId $userId }
                elseif ($token -match '^(edit|delete):(\d+)$') { Start-TemplateDefinitionPrompt -Action $Matches[1] -TemplateIndex ([int]$Matches[2]) -ChatId $chatId -UserId $userId }
            }
            break
        }
        'padm:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Show-PresetAdminTemplate -TemplateIndex ([int](Get-CallbackArg $data 'padm:')) -ChatId $chatId
            }
            break
        }
        'pa:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            $chosenPreset = Get-TemplatePreset -Template $template -Index $presetIndex
            if (-not $chosenPreset) { break }
            Send-TelegramMessage -ChatId $chatId -Text (T 'cb.pickAction' $($chosenPreset.Name)) -ReplyMarkup (Get-PresetActionKeyboard -TemplateIndex $templateIndex -PresetIndex $presetIndex)
            break
        }
        'pac:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Start-PresetAdminCreate -TemplateIndex ([int](Get-CallbackArg $data 'pac:')) -ChatId $chatId -UserId $userId
            }
            break
        }
        'pae:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            Start-PresetAdminEditValues -TemplateIndex ([int]$presetParts[1]) -PresetIndex ([int]$presetParts[2]) -ChatId $chatId -UserId $userId
            break
        }
        'par:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            $chosenPreset = Get-TemplatePreset -Template $template -Index $presetIndex
            if (-not $chosenPreset) { break }
            Set-PendingState -ChatId $chatId -State @{
                Mode = 'preset_admin_name'; Action = 'rename'; TemplateIndex = $templateIndex
                TemplateKey = [string]$template.Key; PresetIndex = $presetIndex; UserId = $userId
                Fields = @($template.Fields); Values = @(); Name = [string]$chosenPreset.Name; Index = 0
            }
            Send-TelegramMessage -ChatId $chatId -Text (T 'cb.sendNewNameFor' $($chosenPreset.Name)) -ReplyMarkup (Get-CancelKeyboard)
            break
        }
        'pad:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            $chosenPreset = Get-TemplatePreset -Template $template -Index $presetIndex
            if (-not $chosenPreset) { break }
            Show-PresetAdminReview -ChatId $chatId -State @{
                Mode = 'preset_admin_review'; Action = 'delete'; TemplateIndex = $templateIndex
                TemplateKey = [string]$template.Key; PresetIndex = $presetIndex; UserId = $userId
                Fields = @($template.Fields); Values = @($chosenPreset.Values)
                Name = [string]$chosenPreset.Name; Index = 0
            }
            break
        }
        'presetadmin:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Confirm-PresetAdminChange -ChatId $chatId -UserId $userId
            }
            break
        }
        'menu:backups' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-ConfigBackupsText) -ParseMode HTML -ReplyMarkup (Get-ConfigBackupsKeyboard)
            }
            break
        }
        'menu:rawcmd' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.rawCommandUsage') -ReplyMarkup (Get-CancelKeyboard)
            }
            break
        }
        'menu:pending' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $pendingKeyboard = Get-PendingKeyboard
                if (-not (Send-TelegramRichMessage -ChatId $chatId -Blocks (Get-PendingApprovalsBlocks) -ReplyMarkup $pendingKeyboard)) {
                    Send-TelegramMessage -ChatId $chatId -Text (Get-PendingApprovalsText) -ParseMode HTML -ReplyMarkup $pendingKeyboard
                }
            }
            break
        }
        'menu:blocked' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-BlockedChatsText) -ParseMode HTML -ReplyMarkup (Get-BlockedChatsKeyboard)
            }
            break
        }
        'unblock:*' {
            $target = 0L
            if ((Test-CallbackAdmin -ChatId $chatId -UserId $userId) -and
                [long]::TryParse((Get-CallbackArg $data 'unblock:'), [ref]$target) -and $target -ne 0) {
                if (Unblock-AccessChat -ChatId $target -ByUserId $userId) {
                    Add-AuditEntry (T 'cb.unblockAudit' $target $(Format-UserAuditActor -UserId $userId))
                }
                Send-TelegramMessage -ChatId $chatId -Text (Get-BlockedChatsText) -ParseMode HTML -ReplyMarkup (Get-BlockedChatsKeyboard)
            }
            break
        }
        'mojazdesign:*' {
            # Chosen during creation, or swapped later on an existing one.
            $designKey = [string](Get-CallbackArg $data 'mojazdesign:')
            $designState = Get-PendingState -ChatId $chatId
            if ($designState -and [string]$designState.Mode -eq 'mojaz_design_new') {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'mojaz_name_new'; UserId = $userId; DesignKey = $designKey } | Out-Null
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sendBulletinName') -ReplyMarkup (Get-CancelKeyboard)
            }
            elseif ($designState -and [string]$designState.Mode -eq 'mojaz_design_set') {
                Clear-PendingState -ChatId $chatId
                Set-MojazBulletinDesign -BulletinId ([string]$designState.BulletinId) -TemplateKey $designKey -ChatId $chatId -UserId $userId | Out-Null
            }
            break
        }
        'mojazdesignpage:*' {
            $page = 0
            if ([int]::TryParse((Get-CallbackArg $data 'mojazdesignpage:'), [ref]$page) -and $page -ge 0) {
                Show-MojazDesignScreen -ChatId $chatId -UserId $userId -Page $page
            }
            break
        }
        'mojazlib:*' {
            $page = 0
            if ([int]::TryParse((Get-CallbackArg $data 'mojazlib:'), [ref]$page) -and $page -ge 0) {
                Show-MojazLibraryScreen -ChatId $chatId -UserId $userId -Page $page
            }
            break
        }
        'mojazschedpage:*' {
            $page = 0
            if ([int]::TryParse((Get-CallbackArg $data 'mojazschedpage:'), [ref]$page) -and $page -ge 0) {
                Show-MojazSchedulesScreen -ChatId $chatId -UserId $userId -Page $page
            }
            break
        }
        'menu:userpresence' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-UserActivitySummaryText) -ParseMode HTML -ReplyMarkup (Get-AdminToolsKeyboard)
            }
            break
        }
        'pendingpage:*' {
            $page = 0
            if ((Test-CallbackAdmin -ChatId $chatId -UserId $userId) -and
                [int]::TryParse((Get-CallbackArg $data 'pendingpage:'), [ref]$page) -and $page -ge 0) {
                Send-TelegramMessage -ChatId $chatId -Text (Get-PendingApprovalsText -Page $page) -ParseMode HTML -ReplyMarkup (Get-PendingKeyboard -Page $page)
            }
            break
        }
        'menu:stream:start' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-LiveRelay -ChatId $chatId -UserId $userId }
            break
        }
        'menu:stream:stop' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Stop-LiveRelay -ChatId $chatId -UserId $userId }
            break
        }
        'menu:stream:seturl' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-StreamUrlPrompt -ChatId $chatId -UserId $userId }
            break
        }
        'tplT:*' {
            # Pick the duration first, then collect the field text; the show
            # fires as soon as the last field is entered.
            $idx = [int]((Get-CallbackArg $data 'tplT:'))
            $t = Get-TemplateByIndex -Index $idx
            $name = if ($t) { $t.Key } else { '' }
            Send-TelegramMessage -ChatId $chatId -Text (T 'cb.autoHideFor' $name) -ReplyMarkup (Get-DurationKeyboard -Prefix 'dur' -Token "$idx" -BackData 'menu:timed')
            break
        }
        'dur:*' {
            $parts = $data -split ':'
            $idx = [int]$parts[1]
            if ($parts[2] -eq 'c') {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'timed_custom'; TemplateIndex = $idx; UserId = $userId }
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.sendSeconds') -ReplyMarkup (Get-CancelKeyboard)
            }
            else {
                Start-ShowFlow -TemplateIndex $idx -ChatId $chatId -UserId $userId -AutoHideSeconds ([int]$parts[2])
            }
            break
        }
        'timer:*' {
            $layer = [int]((Get-CallbackArg $data 'timer:'))
            Send-TelegramMessage -ChatId $chatId -Text (T 'cb.autoHideLayer' $layer) -ReplyMarkup (Get-DurationKeyboard -Prefix 'tlay' -Token "$layer")
            break
        }
        'tlay:*' {
            $parts = $data -split ':'
            $layer = [int]$parts[1]
            if ($parts[2] -eq 'c') {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'layer_timer_custom'; Layer = $layer; UserId = $userId }
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.sendSecondsForLayer' $layer) -ReplyMarkup (Get-CancelKeyboard)
            }
            else {
                Set-LayerAutoHide -Layer $layer -Seconds ([int]$parts[2]) -ChatId $chatId -UserId $userId
            }
            break
        }
        'timeradd:*' {
            $parts = $data -split ':'
            $layer = [int]$parts[1]
            $adjustSeconds = [int]$parts[2]
            $pending = @($script:AutoHideQueue | Where-Object { [int]$_.Layer -eq $layer })
            if ($pending.Count -gt 0) {
                $currentRemaining = [int](($pending[0].At - (Get-Date)).TotalSeconds)
                $newSeconds = [math]::Max(5, $currentRemaining + $adjustSeconds)
                Set-LayerAutoHide -Layer $layer -Seconds $newSeconds -ChatId $chatId -UserId $userId
            } else {
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.noTimerForLayer' $layer) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'tpl:*' {
            $idx = [int]((Get-CallbackArg $data 'tpl:'))
            Start-ShowFlow -TemplateIndex $idx -ChatId $chatId -UserId $userId
            break
        }
        'preset:*' {
            $parts = $data -split ':'
            Invoke-PresetShow -TemplateIndex ([int]$parts[1]) -PresetIndex ([int]$parts[2]) -ChatId $chatId -UserId $userId
            break
        }
        'remsnooze:*' {
            $reminderId = Get-CallbackArg $data 'remsnooze:'
            $item = @($script:TemplateReminderQueue | Where-Object {
                [string](Get-JsonProp $_ 'ReminderId') -eq $reminderId -and [long](Get-JsonProp $_ 'UserId') -eq $userId
            } | Select-Object -First 1)
            if ($item.Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.alertExpiredOrOther') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $item.Stage = 'initial'
            $item.At = [datetimeoffset]::Now.AddMinutes(5)
            $item.Minutes = [int](Get-JsonProp $item 'Minutes') + 5
            if (Save-TemplateReminderQueue) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.reminderSet') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            } else {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.reminderSaveFailed') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            break
        }
        'rollbackconfirm:*' { Confirm-SafeRollback -Layer ([int](Get-CallbackArg $data 'rollbackconfirm:')) -ChatId $chatId -UserId $userId; break }
        'remack:*' {
            $failureReason = ''
            $acknowledged = Confirm-TemplateReminder -ReminderId (Get-CallbackArg $data 'remack:') -UserId $userId -FailureReason ([ref]$failureReason)
            $message = if ($acknowledged) { (T 'reply.handledRecorded') }
            elseif ($failureReason -eq 'persistence') { (T 'reply.handledSaveFailed') }
            else { (T 'reply.alertExpiredOrOther') }
            Send-TelegramMessage -ChatId $chatId -Text $message -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'rollback:*' { Start-SafeRollbackReview -Layer ([int](Get-CallbackArg $data 'rollback:')) -ChatId $chatId -UserId $userId; break }
        # A confirmed removal names the template, not just the layer number:
        # a layer number is not something an operator can check against the
        # screen under pressure. Off by default so the emergency path keeps
        # its single tap.
        'hidego:*' {
            Confirm-LayerRemoval -TicketId (Get-CallbackArg $data 'hidego:') -Action hide -ChatId $chatId -UserId $userId
            break
        }
        'exitgo:*' {
            Confirm-LayerRemoval -TicketId (Get-CallbackArg $data 'exitgo:') -Action exit -ChatId $chatId -UserId $userId
            break
        }
        'hide:*' {
            $targetLayer = [int](Get-CallbackArg $data 'hide:')
            $onAirKey = if ($script:OnAir.ContainsKey($targetLayer)) { [string](Get-JsonProp $script:OnAir[$targetLayer] 'Key') } else { '' }
            $access = Test-TemplateAccess -Key $onAirKey -Layer $targetLayer -ChatId $chatId -UserId $userId
            if (-not $access.Allowed) {
                Send-TelegramMessage -ChatId $chatId -Text "⛔ $($access.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            # Confirms only what is actually on air. Asking before hiding an
            # empty layer is friction that buys nothing, and friction on a
            # path that does not matter is how operators learn to tap through
            # the confirmation that does.
            if ((Get-Setting 'ConfirmLayerRemoval') -and $script:OnAir.ContainsKey($targetLayer)) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.confirmHide' $(Get-LayerRemovalSummary -Layer $targetLayer)) -ReplyMarkup (Get-LayerRemovalConfirmKeyboard -Layer $targetLayer -Action hide -ChatId $chatId -UserId $userId)
            }
            else { Invoke-HideLayer -Layer $targetLayer -ChatId $chatId -UserId $userId | Out-Null }
            break
        }
        'exit:*' {
            $targetLayer = [int](Get-CallbackArg $data 'exit:')
            $onAirKey = if ($script:OnAir.ContainsKey($targetLayer)) { [string](Get-JsonProp $script:OnAir[$targetLayer] 'Key') } else { '' }
            $access = Test-TemplateAccess -Key $onAirKey -Layer $targetLayer -ChatId $chatId -UserId $userId
            if (-not $access.Allowed) {
                Send-TelegramMessage -ChatId $chatId -Text "⛔ $($access.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            if ((Get-Setting 'ConfirmLayerRemoval') -and $script:OnAir.ContainsKey($targetLayer)) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.confirmExit' $(Get-LayerRemovalSummary -Layer $targetLayer)) -ReplyMarkup (Get-LayerRemovalConfirmKeyboard -Layer $targetLayer -Action exit -ChatId $chatId -UserId $userId)
            }
            else { Invoke-ExitLayer -Layer $targetLayer -ChatId $chatId -UserId $userId }
            break
        }
        'updtpl:*' {
            $idx = [int]((Get-CallbackArg $data 'updtpl:'))
            $t = Get-TemplateByIndex -Index $idx
            if (-not $t -or $t.Fields.Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.noUpdatableFields') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.pickField') -ReplyMarkup (Get-FieldsKeyboard -TemplateIndex $idx)
            }
            break
        }
        'updf:*' {
            $parts = $data -split ':'
            $t = Get-TemplateByIndex -Index ([int]$parts[1])
            $fieldIdx = [int]$parts[2]
            if (-not $t -or $fieldIdx -ge $t.Fields.Count) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.fieldGone') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            else {
                $fieldLimit = 0
                if ($fieldIdx -lt @($t.FieldLimits).Count) { $fieldLimit = [int]$t.FieldLimits[$fieldIdx] }
                Start-UpdateFieldPrompt -FieldName ([string]$t.Fields[$fieldIdx]) -ChatId $chatId -UserId $userId -FieldLimit $fieldLimit
            }
            break
        }
        'approve:confirm:*' {
            # Before 'approve:*', which would otherwise swallow this: the
            # switch takes the first pattern that matches.
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $target = [long](Get-CallbackArg $data 'approve:confirm:')
                $pending = $(if ($script:PendingApprovals.ContainsKey($target)) { $script:PendingApprovals[$target] } else { $null })
                $name = if ($pending) { [string](Get-JsonProp $pending 'Name') } else { '' }
                $who = if ($name) { "$name ‎($target)‎" } else { [string]$target }
                Send-TelegramMessage -ChatId $chatId -ParseMode HTML `
                    -Text (T 'cb.confirmGrant' $(ConvertTo-TelegramHtmlText $who)) `
                    -ReplyMarkup (Get-AccessGrantConfirmKeyboard -TargetChatId $target)
            }
            break
        }
        'approve:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Grant-UserAccess -TargetChatId ([long](Get-CallbackArg $data 'approve:')) -ApprovedBy $chatId -ApproverUserId $userId
            }
            break
        }
        'news:draft:extend' {
            # Touching the draft is the extension: the expiry measures idleness
            # from UpdatedAt, so saying "keep it" is the same act as editing it.
            $draft = Get-NewsTickerDraft -UserId $userId
            if ($draft) {
                # Through Set-JsonProp: written with Add-Member this extension
                # left the UpdatedAt key at its old value, so the draft stayed
                # exactly as idle as it was and the warning kept arriving
                # however many times the button was pressed.
                Set-JsonProp -Object $draft -Name 'UpdatedAt' -Value ((Get-Date).ToString('o'))
                Remove-JsonProp -Object $draft -Name 'WarnedAt'
                Save-NewsTickerDraft | Out-Null
                Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text (T 'reply.draftExtended')
            }
            else {
                Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text (T 'reply.noDraft') -Alert
            }
            break
        }
        'diag:copy' {
            # P1: no admin gate needed - this only re-sends a diagnosis that
            # was already broadcast to every admin, back to the tapper alone.
            Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id | Out-Null
            $copy = $script:LastFailureDiagnosisPlain
            $age = if ($copy) { ((Get-Date) - [datetime](Get-JsonProp $copy 'At')).TotalMinutes } else { 9999 }
            if ($copy -and $age -lt 30) {
                Send-TelegramMessage -ChatId $chatId -Text ([string](Get-JsonProp $copy 'Text'))
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.snapshotExpired') -ReplyMarkup (Get-NoticeKeyboard)
            }
            break
        }
        'flow:resume' {
            # D3: the expiry message's way back. No admin gate: the stash is
            # keyed by this chat and only reopens that chat's own draft.
            Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id | Out-Null
            Resume-ExpiredFlow -ChatId $chatId -UserId $userId
            break
        }
        'flow:extend' {
            # The minute's warning, answered. The clock restarts from now
            # rather than being switched off: the flow still has to end if the
            # person really has walked away.
            $state = Get-PendingState -ChatId $chatId
            if ($state) {
                $state.StartedAt = Get-Date
                $state.Remove('WarnedAt')
                Set-PendingState -ChatId $chatId -State $state
                Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text (T 'reply.timeoutExtended')
            }
            else {
                Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text (T 'reply.noOperation') -Alert
            }
            break
        }
        'reject:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Deny-UserAccess -TargetChatId ([long](Get-CallbackArg $data 'reject:')) -RejectedBy $chatId -RejecterUserId $userId
            }
            break
        }
        'whynot:*' {
            $failedTemplate = Get-TemplateByIndex -Index ([int](Get-CallbackArg $data 'whynot:'))
            if (-not $failedTemplate) {
                Send-TelegramMessage -ChatId $chatId -Text (T 'reply.templateNoLongerExists') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            Send-TelegramMessage -ChatId $chatId -Text (Get-ShowFailureDiagnosisText -Key ([string]$failedTemplate.Key) -ChatId $chatId -UserId $userId) -ParseMode HTML -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'tplbak:list' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Clear-PendingState -ChatId $chatId
                Send-TelegramMessage -ChatId $chatId -Text (Get-TemplateBackupsText) -ParseMode HTML -ReplyMarkup (Get-TemplateBackupsKeyboard)
            }
            break
        }
        'tplbak:restore:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $backups = @(Get-TemplateBackupFiles)
                $chosen = [int](Get-CallbackArg $data 'tplbak:restore:')
                if ($chosen -lt 0 -or $chosen -ge $backups.Count) {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'reply.backupGone') -ParseMode HTML -ReplyMarkup (Get-TemplateBackupsKeyboard)
                    break
                }
                # Addressed by position, not by file name: callback_data is
                # capped at 64 bytes and these names carry a timestamp and a
                # guid.
                $chosenFile = $backups[$chosen]
                $preview = $null
                try {
                    $saved = Get-Content -LiteralPath $chosenFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $live = Get-Content -LiteralPath (Get-TemplateRegistryFilePath) -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $preview = Get-TemplateRegistryImportComparison -Current $live -Imported $saved
                }
                catch {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'cb.backupUnreadable' $(Protect-SensitiveText $_.Exception.Message)) -ParseMode HTML -ReplyMarkup (Get-TemplateBackupsKeyboard)
                    break
                }
                Clear-PendingState -ChatId $chatId
                Set-PendingState -ChatId $chatId -State @{
                    Mode = 'template_restore'; UserId = $userId; BackupPath = $chosenFile.FullName
                } | Out-Null
                Send-TelegramMessage -ChatId $chatId -Text (Get-TemplateRestorePreviewText -Comparison $preview -BackupTime $chosenFile.LastWriteTime) -ParseMode HTML -ReplyMarkup (Get-TemplateRestoreConfirmKeyboard)
            }
            break
        }
        'tplbak:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $restoreState = Get-PendingState -ChatId $chatId
                if (-not $restoreState -or $restoreState.Mode -ne 'template_restore' -or [long]$restoreState.UserId -ne $userId) {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'reply.restoreExpired') -ParseMode HTML -ReplyMarkup (Get-TemplateBackupsKeyboard)
                    break
                }
                $restoreFrom = [string]$restoreState.BackupPath
                Clear-PendingState -ChatId $chatId
                $outcome = Restore-TemplateRegistryBackup -BackupPath $restoreFrom
                if ($outcome.Success) {
                    Write-BridgeLog "Admin user $userId restored template registry backup '$([System.IO.Path]::GetFileName($restoreFrom))'" 'WARN'
                    Add-AuditEntry (T 'cb.templateRestoreAudit' $(Format-UserAuditActor -UserId $userId))
                    Send-TelegramMessage -ChatId $chatId -Text (T 'reply.templatesRestored') -ParseMode HTML -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard -ChatId $chatId -UserId $userId)
                }
                else {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'cb.restoreFailed' $($outcome.Error)) -ParseMode HTML -ReplyMarkup (Get-TemplateBackupsKeyboard)
                }
            }
            break
        }
        'cfg:restoreconfirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $state = Get-PendingState -ChatId $chatId
                if (-not $state -or $state.Mode -ne 'config_restore' -or [long]$state.UserId -ne $userId) {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'cb.restoreExpired') -ReplyMarkup (Get-ConfigBackupsKeyboard)
                    break
                }
                $backupPath = [string]$state.BackupPath
                Clear-PendingState -ChatId $chatId
                $restore = Restore-ConfigBackup -BackupPath $backupPath
                if ($restore.Success) {
                    Write-BridgeLog "Admin user $userId restored configuration backup '$([System.IO.Path]::GetFileName($backupPath))'" "WARN"
                    Add-AuditEntry (T 'cb.settingsRestoreAudit' $(Format-UserAuditActor -UserId $userId))
                    Send-TelegramMessage -ChatId $chatId -Text (T 'reply.settingsRestored') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                }
                else {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'cb.restoreFailed' $($restore.Error)) -ReplyMarkup (Get-ConfigBackupsKeyboard)
                }
            }
            break
        }
        'cfg:restore:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $files = @(Get-ConfigBackupFiles -Path $ConfigPath)
                $index = [int](Get-CallbackArg $data 'cfg:restore:')
                if ($index -lt 0 -or $index -ge $files.Count) {
                    Send-TelegramMessage -ChatId $chatId -Text (T 'cb.backupGone') -ReplyMarkup (Get-ConfigBackupsKeyboard)
                    break
                }
                Clear-PendingState -ChatId $chatId
                Set-PendingState -ChatId $chatId -State @{
                    Mode = 'config_restore'; UserId = $userId; BackupPath = $files[$index].FullName
                }
                # The names of the changed settings said something changed but
                # not what it would become. The table says both, with anything
                # that reads like a credential shown as a length.
                $restoreBlocks = @(Get-ConfigRestoreBlocks -CurrentPath $ConfigPath -BackupPath $files[$index].FullName -BackupName $files[$index].Name)
                $restoreKeyboard = Get-ConfigRestoreConfirmKeyboard
                if ($restoreBlocks.Count -gt 0) {
                    $restoreBlocks += @{ type = 'paragraph'; text = (T 'reply.restoreNote') }
                    if (Send-TelegramRichMessage -ChatId $chatId -Blocks $restoreBlocks -ReplyMarkup $restoreKeyboard) { break }
                }
                $differenceSummary = Get-ConfigDifferenceSummary -CurrentPath $ConfigPath -BackupPath $files[$index].FullName
                Send-TelegramMessage -ChatId $chatId -Text (T 'cb.confirmRestore' $($files[$index].Name) $differenceSummary) -ReplyMarkup $restoreKeyboard
            }
            break
        }
        'cfg:reset' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Reset-SettingsToDefault -ChatId $chatId -UserId $userId }
            break
        }
        'cfg:resetconfirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Reset-SettingsToDefault -ChatId $chatId -UserId $userId -Confirmed }
            break
        }
        'hideallcfg:all' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -SelectAll -ChatId $chatId -UserId $userId }
            break
        }
        'hideallcfg:none' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -ClearAll -ChatId $chatId -UserId $userId }
            break
        }
        'hideallcfg:toggle:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -Layer ([int](Get-CallbackArg $data 'hideallcfg:toggle:')) -ChatId $chatId -UserId $userId }
            break
        }
        'layername:clear:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $layerText = $data -replace '^layername:clear:', ''
                if ([string]::IsNullOrWhiteSpace($layerText)) { break }
                $layer = 0
                if (-not [int]::TryParse($layerText, [ref]$layer)) { break }
                Clear-PendingState -ChatId $chatId
                Set-LayerName -Layer $layer -Name '' -ChatId $chatId -UserId $userId | Out-Null
            }
            break
        }
        'layername:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $layerText = $data -replace '^layername:', ''
                if ([string]::IsNullOrWhiteSpace($layerText)) { break }
                $layer = 0
                if (-not [int]::TryParse($layerText, [ref]$layer)) { break }
                if (@(Get-KnownLayers | ForEach-Object { [int]$_ }) -contains $layer) { Start-LayerNamePrompt -Layer $layer -ChatId $chatId -UserId $userId }
            }
            break
        }
        'cfg:t:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-SettingToggle -Name (Get-CallbackArg $data 'cfg:t:') -ChatId $chatId -UserId $userId }
            break
        }
        'cfgc:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Invoke-SettingToggle -Name (Get-CallbackArg $data 'cfgc:') -ChatId $chatId -UserId $userId -Confirmed
            }
            break
        }
        'tm:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $parts = @((Get-CallbackArg $data 'tm:') -split ':')
                $timeName = [string]$parts[0]
                if ($timeName -in @('MaintenanceWindowStart', 'MaintenanceWindowEnd')) {
                    $timeMessageId = [int]$msgObj.message_id
                    $tail = if ($parts.Count -gt 1) { [string]$parts[1] } else { '' }
                    $hour = -1
                    if ($tail -eq 'clear') {
                        [void](Set-SettingTime -Name $timeName -UserId $userId)
                        Show-SettingTimePicker -Name $timeName -ChatId $chatId -UserId $userId -MessageId $timeMessageId
                    }
                    elseif ($tail -eq 'pick') {
                        Show-SettingTimePicker -Name $timeName -ChatId $chatId -UserId $userId -MessageId $timeMessageId
                    }
                    elseif ([int]::TryParse($tail, [ref]$hour) -and $hour -ge 0 -and $hour -le 23) {
                        $minute = -1
                        if ($parts.Count -gt 2 -and [int]::TryParse([string]$parts[2], [ref]$minute)) {
                            [void](Set-SettingTime -Name $timeName -Hour $hour -Minute $minute -UserId $userId)
                            Show-SettingTimePicker -Name $timeName -ChatId $chatId -UserId $userId -MessageId $timeMessageId
                        }
                        else {
                            # The hour is chosen; the minute is the next tap.
                            Show-SettingTimePicker -Name $timeName -ChatId $chatId -UserId $userId -Hour $hour -MessageId $timeMessageId
                        }
                    }
                }
            }
            break
        }
        'num:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                # name:operation, and a setting name cannot contain a colon.
                $rest = Get-CallbackArg $data 'num:'
                $split = $rest.LastIndexOf(':')
                if ($split -gt 0) {
                    $name = $rest.Substring(0, $split)
                    $operation = $rest.Substring($split + 1)
                    if ($script:DefaultSettings.Contains($name)) {
                        if ($operation -eq 'type') {
                            Set-PendingState -ChatId $chatId -State @{ Mode = 'setting_value'; Name = $name; UserId = $userId }
                            Send-TelegramMessage -ChatId $chatId -Text (Get-SettingPromptText -Name $name) -ParseMode HTML -ReplyMarkup (Get-CancelKeyboard)
                        }
                        elseif ($operation -ne 'noop') {
                            [void](Set-SettingNumber -Name $name -Operation $operation -UserId $userId)
                            Show-SettingStepper -Name $name -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id)
                        }
                    }
                }
            }
            break
        }
        'cfg:v:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-SettingValuePrompt -Name (Get-CallbackArg $data 'cfg:v:') -ChatId $chatId -UserId $userId }
            break
        }
        'cfg:s:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $settingName = (Get-CallbackArg $data 'cfg:s:')
                if ($settingName -eq 'LayerNames') { Show-LayerNamesScreen -ChatId $chatId -UserId $userId }
                else { Show-SettingChoices -Name $settingName -ChatId $chatId -UserId $userId }
            }
            break
        }
        'cfgs:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $parts = $data -split ':'
                Set-SettingChoice -Name $parts[1] -Index ([int]$parts[2]) -ChatId $chatId -UserId $userId
            }
            break
        }
        default {
            Send-TelegramMessage -ChatId $chatId -Text (T 'reply.unknownOption') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
        }
    }
}
