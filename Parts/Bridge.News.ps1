#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-NewsTickerConfiguredSnapshot {
    Get-NewsTickerSnapshot -Path ([string](Get-Setting 'NewsFilePath')) -Separator ([string](Get-Setting 'NewsItemSeparator')) `
        -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
}

function Save-NewsTickerDraft {
    if (-not $script:NewsTickerDraft) { return $false }
    try {
        $json = $script:NewsTickerDraft | ConvertTo-Json -Depth 8
        $parent = Split-Path -Parent $script:newsDraftFile
        if (-not (Test-Path -LiteralPath $parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $temp = "$script:newsDraftFile.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($true))
        [IO.File]::Move($temp, $script:newsDraftFile, $true)
        return $true
    } catch { Write-BridgeLog "Could not save news draft: $($_.Exception.Message)" 'ERROR'; return $false }
}

function Import-NewsTickerDraft {
    if (-not (Test-Path -LiteralPath $script:newsDraftFile)) { return }
    try { $script:NewsTickerDraft = Get-Content -LiteralPath $script:newsDraftFile -Raw | ConvertFrom-Json -AsHashtable }
    catch { Write-BridgeLog "Could not load news draft: $($_.Exception.Message)" 'WARN'; $script:NewsTickerDraft = $null }
}

function Get-NewsTickerDraft { param([long]$UserId = 0)
    if (-not $script:NewsTickerDraft) { return $null }
    if ($UserId -and [long]$script:NewsTickerDraft.OwnerUserId -ne $UserId) { return $null }
    return $script:NewsTickerDraft
}

function Test-NewsTickerDraftOpen {
    <#
        Is this draft open to whoever edits next?

        An open draft is one its owner handed over on purpose: it keeps every
        item, and simply belongs to nobody until the next ✏️ adopts it.

        Marked by its own key rather than by OwnerUserId 0. A missing or
        unreadable owner also reads as 0, so that spelling made every draft
        whose owner could not be read look unlocked - a lock that fails open,
        which is worse than no lock because everyone believes there is one.
        An absent IsOpen means closed, so the failure goes the safe way.
    #>
    param($Draft)
    if (-not $Draft) { return $false }
    return [bool](Get-JsonProp $Draft 'IsOpen')
}

function Remove-NewsTickerDraft {
    $script:NewsTickerDraft = $null
    Remove-Item -LiteralPath $script:newsDraftFile -Force -ErrorAction SilentlyContinue
}

function Get-NewsLockReservation {
    <# The short hold that belongs to whoever just won a hand-over.

       A grant only ever emptied the draft slot and told the requester to press
       the start button. Between those two moments the slot was free to
       everyone, so five minutes of negotiation could be lost to whoever
       happened to tap first - including the owner who had just handed it over.
       Expiry is checked on read so nothing has to sweep it. #>
    if (-not $script:NewsLockGrant) { return $null }
    if ((Get-Date) -ge [datetime]$script:NewsLockGrant.ExpiresAt) { $script:NewsLockGrant = $null; return $null }
    return $script:NewsLockGrant
}

function Set-NewsLockReservation {
    param([Parameter(Mandatory)][long]$UserId)
    $seconds = Get-SettingInt 'NewsLockGrantHoldSeconds' 0
    if ($seconds -le 0) { $script:NewsLockGrant = $null; return $null }
    $script:NewsLockGrant = @{ UserId = $UserId; ExpiresAt = (Get-Date).AddSeconds($seconds) }
    return $script:NewsLockGrant
}

function Clear-NewsLockReservation { $script:NewsLockGrant = $null }

function Start-NewsTickerDraft {
    param([long]$ChatId,[long]$UserId)
    $existing = $script:NewsTickerDraft
    if ($existing -and [long]$existing.OwnerUserId -eq $UserId) { return [pscustomobject]@{Success=$true;Draft=$existing;Error=''} }
    if ($existing -and -not (Test-NewsTickerDraftOpen -Draft $existing)) {
        return [pscustomobject]@{Success=$false;Draft=$null;Error=(T 'news.lockedBy' $(Format-UserAuditActor -UserId ([long]$existing.OwnerUserId)))}
    }
    # Past here the slot is this caller's to take: either it is empty, or it
    # holds a draft its owner opened to whoever comes next. The reservation is
    # checked for both, because a hand-over that reserved the slot must not be
    # won by whoever merely happened to be looking at their screen.
    $reservation = Get-NewsLockReservation
    if ($reservation -and [long]$reservation.UserId -ne $UserId) {
        $secondsLeft = [math]::Max(1, [int]([datetime]$reservation.ExpiresAt - (Get-Date)).TotalSeconds)
        return [pscustomobject]@{Success=$false;Draft=$null;Error=(T 'news.lockHeldFor' $(Format-UserAuditActor -UserId ([long]$reservation.UserId)) $(Get-ArabicCountNoun -Count $secondsLeft -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية' -EnglishOne 'second' -EnglishMany 'seconds'))}
    }
    if ($reservation) { Clear-NewsLockReservation }
    if ($existing) {
        # Adopted with its items. The outgoing editor chose to leave the list
        # behind rather than take it with them, so the next one continues it
        # instead of starting again from whatever is on air.
        $existing['OwnerUserId'] = $UserId
        $existing['OwnerChatId'] = $ChatId
        $existing['UpdatedAt'] = (Get-Date).ToString('o')
        foreach ($mark in 'IsOpen', 'HandedOverBy', 'HandedOverChatId', 'HandedOverAt') {
            Remove-JsonProp -Object $existing -Name $mark
        }
        # The idle-expiry warning is addressed to an owner, and this draft has
        # a new one who has not had their window yet.
        Remove-JsonProp -Object $existing -Name 'WarnedAt'
        if (-not (Save-NewsTickerDraft)) {
            Write-BridgeLog 'Adopted news draft could not be saved; it may revert to open on the next start.' 'ERROR'
        }
        Add-AuditEntry (T 'news.adoptedOpenDraft' $(Format-UserAuditActor -UserId $UserId) $(Get-ArabicCountNoun -Count (@($existing.Items).Count) -One 'خبر' -Two 'خبران' -Few 'أخبار' -Many 'خبرًا' -EnglishOne 'headline' -EnglishMany 'headlines'))
        return [pscustomobject]@{Success=$true;Draft=$existing;Error=''}
    }
    $snapshot = Get-NewsTickerConfiguredSnapshot
    if (-not $snapshot.Success) { return [pscustomobject]@{Success=$false;Draft=$null;Error=$snapshot.Error} }
    $script:NewsTickerDraft = [ordered]@{ Id=[guid]::NewGuid().ToString('N');OwnerUserId=$UserId;OwnerChatId=$ChatId;CreatedAt=(Get-Date).ToString('o');UpdatedAt=(Get-Date).ToString('o');BaseHash=$snapshot.Hash;Items=@($snapshot.Items) }
    Save-NewsTickerDraft | Out-Null
    return [pscustomobject]@{Success=$true;Draft=$script:NewsTickerDraft;Error=''}
}

function Resume-ExpiredNewsDraft {
    <#
        D3: reopen an expired news draft with its items. Only its owner's
        button reaches here (the stash is keyed by OwnerChatId), and only
        when no draft is active - taking over somebody else's live draft
        would be theft, not resume. The base hash is re-taken from the live
        file: the world moved while this draft sat idle, and publishing
        refuses on a changed base exactly for that reason. Lands on the
        management screen, never straight to publish.
    #>
    param([long]$ChatId, [long]$UserId)
    $saved = $script:ExpiredNewsDraft
    if (-not $saved -or [long](Get-JsonProp $saved 'OwnerChatId') -ne $ChatId) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'news.noResumableDraft') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if ($script:NewsTickerDraft) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'news.draftActive') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $snapshot = Get-NewsTickerConfiguredSnapshot
    if (-not $snapshot.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'news.resumeFailed' $($snapshot.Error)) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $script:ExpiredNewsDraft = $null
    $script:NewsTickerDraft = [ordered]@{
        Id = [guid]::NewGuid().ToString('N'); OwnerUserId = $UserId; OwnerChatId = $ChatId
        CreatedAt = (Get-Date).ToString('o'); UpdatedAt = (Get-Date).ToString('o')
        BaseHash = $snapshot.Hash; Items = @(@($saved.Items) | ForEach-Object { [string]$_ })
    }
    Save-NewsTickerDraft | Out-Null
    Add-AuditEntry (T 'news.resumedExpiredAudit' $(@($saved.Items).Count) $(Format-UserAuditActor -UserId $UserId))
    Show-NewsTickerManagementScreen -ChatId $ChatId -UserId $UserId
}

function Add-NewsTickerDraftItem { param([long]$UserId,[string]$Text)
    $draft = Get-NewsTickerDraft -UserId $UserId; if (-not $draft) { return $false }
    $parsed = ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems 1
    if (-not $parsed.Success -or @($parsed.Items).Count -ne 1) { return $false }
    # Newest first, because that is what a ticker is for: the item just typed
    # is the one that matters, and appending buried it behind however many
    # older items the draft already held. NewNewsItemAtTop turns it back into
    # an append for a rundown that is ordered by hand.
    $draft.Items = if (Get-Setting 'NewNewsItemAtTop') { @($parsed.Items) + @($draft.Items) }
    else { @($draft.Items) + @($parsed.Items) }
    $draft.UpdatedAt = (Get-Date).ToString('o'); return (Save-NewsTickerDraft)
}

function Update-NewsTickerDraftItem { param([long]$UserId,[int]$Index,[string]$Text)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count) { return $false }
    $parsed = ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems 1
    if (-not $parsed.Success -or @($parsed.Items).Count -ne 1) { return $false }
    $items = @($draft.Items)
    $items[$Index] = $parsed.Items[0]
    $draft.Items = $items
    $draft.UpdatedAt = (Get-Date).ToString('o')
    return (Save-NewsTickerDraft)
}

function Remove-NewsTickerDraftItem { param([long]$ChatId,[long]$UserId,[int]$Index)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count) { return $false }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId) -and -not (Get-Setting 'AllowOperatorsDeleteNews')) { return $false }
    $items = [Collections.Generic.List[string]]::new()
    @($draft.Items) | ForEach-Object { $items.Add([string]$_) }
    $items.RemoveAt($Index)
    $draft.Items = @($items)
    return (Save-NewsTickerDraft)
}

function Move-NewsTickerDraftItem { param([long]$UserId,[int]$Index,[int]$Delta)
    $draft = Get-NewsTickerDraft -UserId $UserId
    $target = $Index + $Delta
    if (-not $draft -or $Index -lt 0 -or $target -lt 0 -or $Index -ge @($draft.Items).Count -or $target -ge @($draft.Items).Count) { return $false }
    $items = @($draft.Items)
    $swap = $items[$target]
    $items[$target] = $items[$Index]
    $items[$Index] = $swap
    $draft.Items = $items
    $draft.UpdatedAt = (Get-Date).ToString('o')
    return (Save-NewsTickerDraft)
}

function Import-NewsTickerTextToDraft { param([long]$UserId,[string]$Text,[ValidateSet('replace','append')][string]$Mode='replace')
    $draft=Get-NewsTickerDraft -UserId $UserId; if (-not $draft) { return [pscustomobject]@{Success=$false;Error=(T 'news.noDraftOfYours')} }
    $parsed=ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if (-not $parsed.Success) { return [pscustomobject]@{Success=$false;Error=($parsed.Errors -join ' ')} }
    $items = if ($Mode -eq 'append') { @($draft.Items)+@($parsed.Items) } else { @($parsed.Items) }
    $validated=ConvertFrom-NewsTickerText -Text (ConvertTo-NewsTickerText -Items $items -Separator ([string](Get-Setting 'NewsItemSeparator'))) -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if (-not $validated.Success) { return [pscustomobject]@{Success=$false;Error=($validated.Errors -join ' ')} }
    $draft.Items = @($validated.Items)
    $draft.UpdatedAt = (Get-Date).ToString('o')
    Save-NewsTickerDraft | Out-Null
    return [pscustomobject]@{Success=$true;Count=$draft.Items.Count;Error=''}
}

function Clear-NewsTickerDraftItems { param([long]$ChatId,[long]$UserId)
    if (-not (Get-NewsTickerDraft -UserId $UserId)) { return $false }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId) -and -not (Get-Setting 'AllowOperatorsClearAllNews')) { return $false }
    $script:NewsTickerDraft.Items = @()
    $script:NewsTickerDraft.UpdatedAt = (Get-Date).ToString('o')
    return (Save-NewsTickerDraft)
}

function Test-NewsSheetWriteConfigured {
    <# Write-back lives in config.json rather than in Settings, next to
       BotToken. The URL and its token together are the permission to rewrite
       the sheet, and Invoke-SettingsExport only ever writes the keys the
       bridge declares in DefaultSettings, so keeping them out of Settings is
       what keeps them out of an exported file forwarded into a chat. #>
    return -not [string]::IsNullOrWhiteSpace([string](Get-JsonProp $config 'NewsSheetWriteUrl'))
}

function Save-NewsSheetItems {
    <# Writes the published ticker back to the sheet, so the sheet stays the
       readable record even when the editing happened in Telegram.

       Posted to a Google Apps Script web app rather than the Sheets API on
       purpose: the API needs OAuth or a service-account key and RS256 JWT
       signing, none of which PowerShell does without dragging in a library.
       A deployed script is one HTTPS POST with a shared secret. #>
    param([AllowNull()][string[]]$Items = @())
    if (-not (Test-NewsSheetWriteConfigured)) {
        return [pscustomobject]@{ Success = $false; Attempted = $false; Error = '' }
    }
    $url = [string](Get-JsonProp $config 'NewsSheetWriteUrl')
    if ($url -notmatch '^https://') {
        return [pscustomobject]@{ Success = $false; Attempted = $false; Error = (T 'news.writeUrlHttps') }
    }
    $payload = @{
        token = [string](Get-JsonProp $config 'NewsSheetWriteToken')
        items = @($Items | ForEach-Object { [string]$_ })
    } | ConvertTo-Json -Depth 4 -Compress
    try {
        $response = Invoke-WebRequest -Uri $url -Method Post -Body $payload `
            -ContentType 'application/json; charset=utf-8' `
            -TimeoutSec (Get-SettingInt 'NewsSheetTimeoutSeconds' 1) `
            -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
        # Apps Script answers 200 for a rejected token too, so the body is the
        # only honest signal that the write actually happened.
        $body = [string]$response.Content
        if ($body -notmatch '"ok"\s*:\s*true') {
            return [pscustomobject]@{ Success = $false; Attempted = $true; Error = (T 'news.sheetRefusedWrite' $(Protect-SensitiveText $body)) }
        }
        return [pscustomobject]@{ Success = $true; Attempted = $true; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Attempted = $true; Error = $_.Exception.Message }
    }
}

function Publish-NewsTickerDraft { param([long]$UserId)
    $draft = Get-NewsTickerDraft -UserId $UserId
    # Carries Conflict so every caller can branch on it uniformly; without it
    # $result.Conflict throws under StrictMode on this path.
    if (-not $draft) { return [pscustomobject]@{Success=$false;Conflict=$false;Error=(T 'news.noDraftOfYours')} }
    $result = Publish-NewsTickerFile -Path ([string](Get-Setting 'NewsFilePath')) -Items @($draft.Items) -ExpectedHash ([string]$draft.BaseHash) -Separator ([string](Get-Setting 'NewsItemSeparator')) -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if ($result.Success) {
        Add-AuditEntry (T 'news.publishedAudit' $(Format-UserAuditActor -UserId $UserId) $(@($draft.Items).Count))
        Write-NewsPublishRecord -UserId $UserId -ItemCount (@($draft.Items).Count)
        # Mirror to the sheet after the ticker is safely on air, never before.
        # A sheet that refuses the write must not undo a publish that already
        # succeeded, so this reports and rolls nothing back.
        $mirror = Save-NewsSheetItems -Items @($draft.Items)
        $result | Add-Member -NotePropertyName 'SheetSaved' -NotePropertyValue ([bool]$mirror.Success) -Force
        $result | Add-Member -NotePropertyName 'SheetError' -NotePropertyValue ([string]$mirror.Error) -Force
        if ($mirror.Attempted -and -not $mirror.Success) {
            Write-BridgeLog "News published but the sheet write-back failed: $($mirror.Error)" 'WARN'
        }
        Send-NewsPublishNotice -UserId $UserId -ItemCount (@($draft.Items).Count)
        Remove-NewsTickerDraft
    }

    return $result
}

function Get-NewsPublishNoticeAudience {
    param([long]$PublisherUserId)
    $scope = [string](Get-Setting 'NewsPublishNotifyScope')
    if ($scope -eq 'none') { return @() }
    $admins = @(Get-AdminNotifyIds | ForEach-Object { [long]$_ })
    $audience = if ($scope -eq 'all') {
        @($admins + @(@(Get-JsonProp $config 'AllowedChatIds') | ForEach-Object { [long]$_ }))
    }
    elseif ($scope -eq 'admins') {
        $admins
    }
    else {
        @($admins + [long]$PublisherUserId)
    }
    return @($audience | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
}

function Send-NewsPublishNotice {
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][int]$ItemCount)
    $actor = Get-UserDisplayName -UserId $UserId
    $text = (T 'news.publishedByHand' ${actor} $ItemCount)
    foreach ($chat in @(Get-NewsPublishNoticeAudience -PublisherUserId $UserId)) {
        # The publisher already receives the detailed success result; avoid
        # sending the same event twice while retaining the setting's audience.
        if ([long]$chat -ne $UserId) {
            Send-TelegramMessage -ChatId ([long]$chat) -Text $text -Cause 'news-publish-manual'
        }
    }
}

function Write-NewsPublishRecord {
    <# A structured sibling to the human audit line above. The reports screen
       needs a count per day per operator, and parsing that back out of an
       Arabic sentence would break the first time someone rewords it. #>
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][int]$ItemCount,
        [ValidateSet('draft', 'sheet', 'auto')][string]$Source = 'draft')
    Write-AuditRecord -OperationId "news-$([guid]::NewGuid().ToString('N'))" -EventName news_publish `
        -Result success -UserId $UserId -Action PUBLISH -Count $ItemCount `
        -Message (T 'news.publishTicker')
    # And to the execution log, which the ticker screen's button opens. Only
    # the automatic sheet sync wrote there, so on a station that publishes by
    # hand - this one, with NewsSheetSyncMode manual - the button always said
    # nothing had run. Every publish passes through here, so it is recorded
    # once, from here, however it was made.
    $counted = Get-ArabicCountNoun -Count $ItemCount -One 'خبر' -Two 'خبران' -Few 'أخبار' -Many 'خبرًا' -EnglishOne 'headline' -EnglishMany 'headlines'
    $label = switch ($Source) {
        'auto' { (T 'tick.sheetSync' $counted) }
        'sheet' { (T 'news.execSheet' $counted) }
        default { (T 'news.execDraft' $counted) }
    }
    Write-BridgeExecutionRecord -Kind 'news' -Result 'success' -Label $label | Out-Null
}

function Resolve-NewsPublishConflict {
    <#
        Rebases a draft onto the ticker file as it is now.

        Another system writes this file too, so a conflict is the normal case
        rather than an accident, and refusing forever would make the bot
        useless for the ticker. What must not happen is a silent overwrite of
        the other writer's work - so this is only ever reached by an explicit
        choice, and it says exactly what will be dropped or kept.

        Mode 'replace' publishes the draft's items over whatever is there.
        Mode 'append' keeps the current live items and adds the draft's after
        them, which is what an operator adding a breaking line actually wants.
    #>
    param(
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][ValidateSet('replace', 'append')][string]$Mode
    )
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) { return [pscustomobject]@{Success=$false;Conflict=$false;Error=(T 'news.noDraftOfYours')} }

    $live = Get-NewsTickerConfiguredSnapshot
    if (-not $live.Success) { return [pscustomobject]@{Success=$false;Conflict=$false;Error=$live.Error} }

    $items = if ($Mode -eq 'append') { @($live.Items) + @($draft.Items) } else { @($draft.Items) }
    # Rebase onto the hash we just read, so the publish below is checked
    # against the file as it is now rather than as it was yesterday.
    $draft.BaseHash = $live.Hash
    $draft.Items = @($items)
    $draft.UpdatedAt = (Get-Date).ToString('o')
    Save-NewsTickerDraft | Out-Null

    Write-BridgeLog "User $UserId rebased the news draft onto the live file ($Mode, $(@($items).Count) item(s))" 'WARN'
    return (Publish-NewsTickerDraft -UserId $UserId)
}

function Save-NewsLockRequest {
    <# Persists the pending hand-over request beside the draft. The request
       used to live only in memory while the draft it is about survives
       restarts on disk: a restart inside the answer window killed the
       request silently, and the requester who was promised an automatic
       grant waited on nothing. No state, no file. #>
    if ([string]::IsNullOrWhiteSpace($script:newsLockRequestFile)) { return $false }
    try {
        if (-not $script:NewsLockRequest) {
            Remove-Item -LiteralPath $script:newsLockRequestFile -Force -ErrorAction SilentlyContinue
            return $true
        }
        $json = $script:NewsLockRequest | ConvertTo-Json -Depth 8
        $parent = Split-Path -Parent $script:newsLockRequestFile
        if (-not (Test-Path -LiteralPath $parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        $temp = "$script:newsLockRequestFile.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($true))
        [IO.File]::Move($temp, $script:newsLockRequestFile, $true)
        return $true
    } catch { Write-BridgeLog "Could not save news lock request: $($_.Exception.Message)" 'ERROR'; return $false }
}

function Import-NewsLockRequest {
    <# Restores a request that outlived a restart. An already-expired window
       is kept, not discarded: the next tick grants it, because silence
       across a restart is still silence. A file that is not a request is
       discarded — a corrupt hand-over must not block the ticker. #>
    if ([string]::IsNullOrWhiteSpace($script:newsLockRequestFile)) { return }
    if (-not (Test-Path -LiteralPath $script:newsLockRequestFile)) { return }
    try {
        $read = Get-Content -LiteralPath $script:newsLockRequestFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not $read -or -not $read.ContainsKey('RequesterUserId') -or -not $read.ContainsKey('OwnerUserId') -or -not $read.ContainsKey('RequestedAt')) {
            throw 'not a lock request'
        }
        $stamp = [datetime]$read['RequestedAt']
        $script:NewsLockRequest = @{
            RequesterUserId = [long]$read['RequesterUserId']; RequesterChatId = [long](Get-JsonProp $read 'RequesterChatId')
            OwnerUserId = [long]$read['OwnerUserId']; OwnerChatId = [long](Get-JsonProp $read 'OwnerChatId')
            RequestedAt = $stamp
        }
        Write-BridgeLog "Restored a pending news lock request from $($read['RequesterUserId']) (requested $stamp)"
    } catch { Write-BridgeLog "Could not load news lock request: $($_.Exception.Message)" 'WARN'; $script:NewsLockRequest = $null }
}

function Request-NewsLockRelease {
    <#
        Asks the current draft owner to hand the ticker over, and takes it if
        they do not answer in time.

        Without this the only way past someone else's draft was an
        administrator forcing it, which is the wrong tool: the usual case is
        an operator who went home with a draft open, and the person who needs
        the ticker now is another operator, not an admin. A silent grab would
        be worse - the owner may be mid-edit - so they get a window to say no,
        and only silence hands it over.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $draft = Get-NewsTickerDraft
    if (-not $draft) { return $false }
    if ([long]$draft.OwnerUserId -eq $UserId) { return $false }
    if (Test-NewsTickerDraftOpen -Draft $draft) {
        # There is nobody left to ask, and a request against an owner of 0
        # would sit until it auto-granted a lock that was never held.
        Send-TelegramMessage -ChatId $ChatId -Text (T 'news.draftAlreadyOpen') -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }

    $minutes = [math]::Max(1, (Get-SettingInt 'NewsLockRequestMinutes' 1))
    $existing = $script:NewsLockRequest
    if ($existing) {
        if ([long]$existing.RequesterUserId -ne $UserId) {
            Send-TelegramMessage -ChatId $ChatId -Text (T 'news.unlockPending' $(Get-UserDisplayName -UserId ([long]$existing.RequesterUserId))) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
            return $false
        }
        # The same requester tapping again used to overwrite the record with a
        # fresh RequestedAt. That pushed the auto-grant back by the full window
        # on every tap, so an impatient operator could wait forever while the
        # owner collected a new ping each time. A repeat tap now only reports
        # how long is left.
        $secondsLeft = [math]::Max(0, [int]([math]::Ceiling(($minutes * 60) - ((Get-Date) - [datetime]$existing.RequestedAt).TotalSeconds)))
        Send-TelegramMessage -ChatId $ChatId -Text (T 'news.yourRequestPending' $(Get-ArabicCountNoun -Count $secondsLeft -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية' -EnglishOne 'second' -EnglishMany 'seconds')) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }

    $script:NewsLockRequest = @{
        RequesterUserId = $UserId; RequesterChatId = $ChatId
        OwnerUserId = [long]$draft.OwnerUserId; OwnerChatId = [long]$draft.OwnerChatId
        RequestedAt = (Get-Date)
    }
    # The auto-grant promise below only holds if the request survives a
    # restart - that is the whole reason this file exists. If the write
    # failed, say so rather than promising something the disk did not accept.
    $requestPersisted = [bool](Save-NewsLockRequest)
    Write-BridgeLog "User $UserId requested the news lock from $($draft.OwnerUserId) (auto-grant in $minutes min)"
    Add-AuditEntry (T 'news.unlockRequestAudit' $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId)) $(Format-UserAuditActor -UserId $UserId))

    if ([long]$draft.OwnerChatId -gt 0) {
        Send-TelegramMessage -ChatId ([long]$draft.OwnerChatId) `
            -Text (T 'news.unlockAsk' $(Get-UserDisplayName -UserId $UserId) $(Get-ArabicCountNoun -Count $minutes -One 'دقيقة' -Two 'دقيقتان' -Few 'دقائق' -Many 'دقيقة' -EnglishOne 'minute' -EnglishMany 'minutes')) `
            -ReplyMarkup @{inline_keyboard=@(,@(
                    @{text=(T 'news.handLock');callback_data='news:lockgrant'},
                    @{text=(T 'news.stillWorking');callback_data='news:lockdeny'}))}
    }
    $persistNote = if ($requestPersisted) { '' } else { "`n$(T news.requestNotSaved)" }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'news.requestSent' $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId)) $(Get-ArabicCountNoun -Count $minutes -One 'دقيقة' -Two 'دقيقتان' -Few 'دقائق' -Many 'دقيقة' -EnglishOne 'minute' -EnglishMany 'minutes') $persistNote) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
    return $true
}

function Complete-NewsLockRelease {
    <# Hands the ticker over. The owner's items are sent back to them as text
       before the draft goes: an unpublished draft is somebody's work, and
       either transferring it to another person or dropping it silently would
       be worse than handing it back. #>
    param([switch]$Denied, [string]$Reason = 'auto')
    $request = $script:NewsLockRequest
    if (-not $request) { return $false }
    $script:NewsLockRequest = $null
    # Clearing the file is what stops a settled request coming back at the next
    # start and granting a lock somebody already handed over or refused.
    if (-not (Save-NewsLockRequest)) {
        Write-BridgeLog 'Settled news lock request could not be cleared from disk; it may be restored on the next start.' 'ERROR'
    }

    if ($Denied) {
        Send-TelegramMessage -ChatId ([long]$request.RequesterChatId) -Text (T 'news.handoverRefused' $(Get-UserDisplayName -UserId ([long]$request.OwnerUserId)))
        Write-BridgeLog "News lock request from $($request.RequesterUserId) was denied by $($request.OwnerUserId)"
        return $false
    }

    $draft = Get-NewsTickerDraft
    if ($draft -and [long]$draft.OwnerUserId -ne [long]$request.OwnerUserId) {
        # The draft changed hands while the window was open - the owner
        # published or cancelled, and somebody uninvolved started a fresh one.
        # Granting here would delete a third party's work to settle an argument
        # they were never part of, so the request dies instead.
        Write-BridgeLog "News lock request from $($request.RequesterUserId) lapsed: the draft moved from $($request.OwnerUserId) to $($draft.OwnerUserId)" 'WARN'
        Send-TelegramMessage -ChatId ([long]$request.RequesterChatId) -Text (T 'news.ownerChanged') `
            -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId ([long]$request.RequesterChatId) -UserId ([long]$request.RequesterUserId))
        return $false
    }
    $items = @(if ($draft) { $draft.Items } else { @() })
    if ($draft -and [long]$request.OwnerChatId -gt 0 -and $items.Count -gt 0) {
        $position = 0
        $body = @($items | ForEach-Object { $position++; "$position. $_" }) -join "`n"
        Send-TelegramMessage -ChatId ([long]$request.OwnerChatId) -Text (T 'news.yourDraftText' $($items.Count) $body)
    }
    if ($draft) { Remove-NewsTickerDraft }

    # Hold the empty slot for the person the hand-over was decided in favour of.
    # Emptying it and asking them to press a button is a race everyone else can
    # win, and losing it silently undoes the whole negotiation.
    Set-NewsLockReservation -UserId ([long]$request.RequesterUserId) | Out-Null

    Write-BridgeLog "News lock handed to $($request.RequesterUserId) ($Reason)" 'WARN'
    Add-AuditEntry (T 'news.lockHandedAudit' $(Get-UserDisplayName -UserId ([long]$request.RequesterUserId)) $Reason)
    if ([long]$request.OwnerChatId -gt 0) {
        Send-TelegramMessage -ChatId ([long]$request.OwnerChatId) -Text (T 'news.lockHandedOver')
    }
    $hold = Get-SettingInt 'NewsLockGrantHoldSeconds' 0
    $holdNote = if ($hold -gt 0) { (T 'news.lockYoursFor' $(Get-ArabicCountNoun -Count $hold -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية' -EnglishOne 'second' -EnglishMany 'seconds')) } else { '' }
    Send-TelegramMessage -ChatId ([long]$request.RequesterChatId) -Text (T 'news.youMayEdit' $holdNote) `
        -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId ([long]$request.RequesterChatId) -UserId ([long]$request.RequesterUserId))
    return $true
}

function Resolve-NewsLockRequestOnRelease {
    <#
        Settles a pending unlock request when the owner releases on their own.

        Whoever asked has been waiting on a window measured in minutes, and
        dropping the slot into a free-for-all would hand it to whoever
        happened to be looking at their screen - the same race
        Get-NewsLockReservation was written to end. So the request is closed in
        their favour and the slot is held for them exactly as a granted
        hand-over holds it.
    #>
    param([Parameter(Mandatory)][long]$OwnerUserId, [Parameter(Mandatory)][string]$Text)
    $request = $script:NewsLockRequest
    if (-not $request -or [long]$request.OwnerUserId -ne $OwnerUserId) { return 0 }
    $script:NewsLockRequest = $null
    if (-not (Save-NewsLockRequest)) {
        Write-BridgeLog 'Settled news lock request could not be cleared from disk; it may be restored on the next start.' 'ERROR'
    }
    $requester = [long]$request.RequesterUserId
    Set-NewsLockReservation -UserId $requester | Out-Null
    $hold = Get-SettingInt 'NewsLockGrantHoldSeconds' 0
    $holdNote = if ($hold -gt 0) { (T 'news.lockYoursFor' $(Get-ArabicCountNoun -Count $hold -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية' -EnglishOne 'second' -EnglishMany 'seconds')) } else { '' }
    Write-BridgeLog "News lock request from $requester settled by the owner's own release"
    Add-AuditEntry (T 'news.unlockSettledAudit' $(Get-UserDisplayName -UserId $requester))
    if ([long]$request.RequesterChatId -gt 0) {
        Send-TelegramMessage -ChatId ([long]$request.RequesterChatId) -Text "$Text$holdNote" `
            -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId ([long]$request.RequesterChatId) -UserId $requester)
    }
    return $requester
}

function Send-NewsDraftReceipt {
    <#
        Hands a draft's items back to a person as text before it goes.

        Every other way a draft ends already does this - the lock hand-over
        since 5.5, the idle expiry since 8.x - except the one an operator
        presses themselves. 🗑 إلغاء المسودة deleted the lot in silence, which
        made it the most dangerous button on the screen and the easiest to
        mis-tap.
    #>
    param([Parameter(Mandatory)][long]$ChatId, $Items, [string]$Header = (T 'news.draftTextBeforeDelete'))
    $list = @($Items)
    if ($ChatId -le 0 -or $list.Count -eq 0) { return $false }
    $numbered = @(for ($i = 0; $i -lt $list.Count; $i++) { "$($i + 1). $($list[$i])" })
    Send-TelegramPagedText -ChatId $ChatId -Text ("$Header`n" + ($numbered -join "`n"))
    return $true
}

function Open-NewsTickerDraftToAll {
    <#
        Hands the draft to whoever edits next, items and all.

        Complete-NewsLockRelease does the opposite - it mails the items back
        to their owner and deletes them - and deliberately so: handing
        somebody's unpublished work to the person who just pressured them for
        it would be worse than losing it. This is the other case entirely. The
        owner decided, and the list they built is the very thing the next
        editor needs, so the draft stays where it is and simply stops
        belonging to anyone.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) { return $false }
    $count = @($draft.Items).Count
    $draft['IsOpen'] = $true
    $draft['OwnerUserId'] = 0
    $draft['OwnerChatId'] = 0
    # Kept so the draft still has somebody to talk to. Nobody owns it, but the
    # expiry warning and the hand-back are addressed to a person, and without
    # this an unclaimed draft would die in silence with its items.
    $draft['HandedOverBy'] = $UserId
    $draft['HandedOverChatId'] = $ChatId
    $draft['HandedOverAt'] = (Get-Date).ToString('o')
    # A fresh idle window for whoever takes it: the expiry clock measures how
    # long a draft sat untouched, and the next editor has not had their turn.
    $draft['UpdatedAt'] = (Get-Date).ToString('o')
    # The window restarts, so the warning owes itself again to whoever holds it.
    Remove-JsonProp -Object $draft -Name 'WarnedAt'
    if (-not (Save-NewsTickerDraft)) {
        Write-BridgeLog 'Opened news draft could not be saved; it may revert to its owner on the next start.' 'ERROR'
    }
    Write-BridgeLog "User $UserId opened the news draft ($count item(s)) to everyone"
    Add-AuditEntry (T 'news.draftOpenedAudit' $(Format-UserAuditActor -UserId $UserId) $(Get-ArabicCountNoun -Count $count -One 'خبر' -Two 'خبران' -Few 'أخبار' -Many 'خبرًا' -EnglishOne 'headline' -EnglishMany 'headlines'))
    Resolve-NewsLockRequestOnRelease -OwnerUserId $UserId `
        -Text (T 'news.draftOpened' $(Get-UserDisplayName -UserId $UserId)) | Out-Null
    return $true
}

function Update-NewsLockRequest {
    <# Grants a pending request once its window has passed. Silence is the
       grant condition: an operator who has gone home cannot answer, and the
       ticker cannot wait for them. #>
    $request = $script:NewsLockRequest
    if (-not $request) { return }
    $minutes = [math]::Max(1, (Get-SettingInt 'NewsLockRequestMinutes' 1))
    if (((Get-Date) - [datetime]$request.RequestedAt).TotalMinutes -lt $minutes) { return }
    Complete-NewsLockRelease -Reason 'no reply within the window' | Out-Null
}

function Get-NewsSheetConfirmPrompt {
    <# One prompt carrying every fact that matters, rather than a generic
       "are you sure" followed by a second warning about the draft owner. Both
       pulls overwrite something, and since the pull is open to operators a
       stray tap must not be enough to rewrite the ticker. #>
    param([ValidateSet('air', 'draft')][string]$Target = 'air')
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Target -eq 'air') {
        $lines.Add((T 'news.confirmSheetPublish'))
        $snapshot = Get-NewsTickerConfiguredSnapshot
        if ($snapshot.Success) { $lines.Add((T 'news.willReplace' $(@($snapshot.Items).Count))) }
    }
    else {
        $lines.Add((T 'news.confirmSheetDraft'))
        $lines.Add((T 'news.nothingUntilPublish'))
    }
    $draft = Get-NewsTickerDraft
    if (Test-NewsTickerDraftOpen -Draft $draft) { $lines.Add((T 'news.openDraftWillBeReplaced' $(@($draft.Items).Count))) }
    elseif ($draft) { $lines.Add((T 'news.draftHeldWillBeReplaced' $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId)))) }
    return ($lines -join "`n")
}

function Get-NewsSheetConfirmKeyboard {
    param([ValidateSet('air', 'draft')][string]$Target = 'air')
    $go = if ($Target -eq 'air') { @{text=(T 'news.yesPublish');callback_data='news:sheetconfirm';style='danger'} }
    else { @{text=(T 'news.yesLoadDraft');callback_data='news:sheetdraftconfirm';style='success'} }
    return @{inline_keyboard=@(,@($go, @{text=(T 'common.cancel');callback_data='news:refresh'}))}
}

function Get-NewsSheetPullLockDenial {
    <# A sheet pull is an edit to the ticker, so it belongs inside the lock
       like every other edit.

       Both pulls rewrite what the newsroom sees: one goes straight to air, the
       other replaces the draft. Neither used to need the lock when no draft
       existed, so any operator with pull access could rewrite the ticker while
       the person who had just published was still looking at it, and the
       buttons sat on the screen inviting exactly that. Holding the lock first
       makes the single-writer rule the whole news screen is built on true of
       the sheet path as well.

       Returns the reason to refuse, or an empty string when the pull is
       allowed - the same shape Get-CallbackRefusal already speaks. #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $draft = Get-NewsTickerDraft
    if (-not $draft) {
        return (T 'news.sheetNeedsLock')
    }
    if (Test-NewsTickerDraftOpen -Draft $draft) {
        return (T 'news.draftUnowned')
    }
    if ([long]$draft.OwnerUserId -ne $UserId) {
        return (T 'news.pullNeedsLock' $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId)))
    }
    return ''
}

function Test-NewsSheetPullAccess {
    <# Who may pull the sheet. Open to every authorised operator by default:
       the content is whatever the newsroom sheet already says, so a pull
       publishes editorial copy rather than anything the presser typed. Set
       AllowOperatorsSheetPull to false to put it back behind the administrator
       bar, the same way the other AllowOperators* news switches work. #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (Test-Admin -ChatId $ChatId -UserId $UserId) { return $true }
    return [bool](Get-Setting 'AllowOperatorsSheetPull')
}

function Get-NewsSheetCsvText {
    <# Downloads the sheet's CSV export. The content ends up on air, so this is
       a trust boundary: https only, a byte cap so a runaway document cannot
       exhaust memory, and a bounded timeout so a hung request cannot stall
       the tick. #>
    param(
        [AllowEmptyString()][string]$Url = '',
        [int]$TimeoutSeconds = 30,
        [int]$MaxBytes = 1048576
    )
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [pscustomobject]@{ Success = $false; Csv = ''; Error = (T 'news.sheetUrlUnset') }
    }
    if ($Url -notmatch '^https://') {
        return [pscustomobject]@{ Success = $false; Csv = ''; Error = (T 'news.sheetUrlHttps') }
    }
    try {
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec ([math]::Max(1, $TimeoutSeconds)) `
            -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
        $bytes = $response.Content -as [byte[]]
        if ($null -eq $bytes) { $bytes = [Text.Encoding]::UTF8.GetBytes([string]$response.Content) }
        if ($bytes.Length -gt $MaxBytes) {
            return [pscustomobject]@{ Success = $false; Csv = ''; Error = (T 'news.sheetTooBig' $MaxBytes) }
        }
        # Sheets serves UTF-8; decoding explicitly keeps Arabic intact whatever
        # the response headers claim.
        $csv = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        return [pscustomobject]@{ Success = $true; Csv = $csv; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Csv = ''; Error = $_.Exception.Message }
    }
}

function Get-NewsSheetChangeSummary {
    <# Order counts: the ticker reads in sequence, so moving the lead story is
       a real change even when the set of headlines is identical. #>
    param([AllowNull()][string[]]$Before = @(), [AllowNull()][string[]]$After = @())
    $previous = @($Before)
    $current = @($After)
    $previousSet = [Collections.Generic.HashSet[string]]::new([string[]]$previous, [StringComparer]::Ordinal)
    $currentSet = [Collections.Generic.HashSet[string]]::new([string[]]$current, [StringComparer]::Ordinal)
    $added = @($current | Where-Object { -not $previousSet.Contains($_) }).Count
    $removed = @($previous | Where-Object { -not $currentSet.Contains($_) }).Count
    $changed = ($previous -join [char]0x001F) -cne ($current -join [char]0x001F)
    return [pscustomobject]@{ Added = $added; Removed = $removed; Changed = $changed; Total = $current.Count }
}

function Get-NewsSheetNoticeText {
    param($Summary, [string]$Trigger = 'auto', [long]$UserId = 0)
    $source = if ($Trigger -eq 'manual' -and $UserId) { (T 'news.byHandBy' $(Get-UserDisplayName -UserId $UserId)) } else { (T 'news.automatically') }
    $lines = @(
        (T 'news.updatedFromSheetAudit' $source)
        (T 'news.nowOnAir' $($Summary.Total))
    )
    if ($Summary.Added -gt 0) { $lines += (T 'news.new' $($Summary.Added)) }
    if ($Summary.Removed -gt 0) { $lines += (T 'news.removed' $($Summary.Removed)) }
    if ($Summary.Added -eq 0 -and $Summary.Removed -eq 0) { $lines += (T 'news.orderOnly') }
    return ($lines -join "`n")
}

function Get-NewsPublishOutcomeText {
    <#
        What the publish did, in both places it lands.

        A publish from Telegram writes the ticker AND mirrors it back to the
        sheet, and the message said only that the ticker was written. So the
        one failure that matters here - the air is right and the sheet is now
        behind - reached the operator as a success, and the sheet stayed wrong
        until somebody happened to read bridge.log.

        Silent about the sheet only when there is no write-back configured:
        a station that never set one should not read a line about it on every
        publish.
    #>
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Lead)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($Lead)
    if ([bool](Get-JsonProp $Result 'SheetSaved')) {
        $lines.Add((T 'news.sheetUpdatedToo'))
    }
    else {
        $reason = [string](Get-JsonProp $Result 'SheetError')
        if ($reason) {
            # Trimmed: this can carry a whole HTTP body from the Apps Script.
            if ($reason.Length -gt 140) { $reason = $reason.Substring(0, 139) + '…' }
            $lines.Add((T 'news.sheetNotUpdated' $reason))
            $lines.Add((T 'news.airAlreadyPublished'))
        }
    }
    return ($lines -join "`n")
}

function Get-NewsSheetNoticeAudience {
    <# Who hears that the ticker changed. Administrators by default: they own
       the sheet and are the ones who would have to undo a bad publish. "all"
       adds every authorised chat, for a newsroom that wants the whole desk to
       see what went out. #>
    param([string]$Scope = '')
    if ([string]::IsNullOrWhiteSpace($Scope)) { $Scope = [string](Get-Setting 'NewsSheetNotifyScope') }
    if ($Scope -eq 'none') { return @() }
    $admins = @(Get-AdminNotifyIds)
    if ($Scope -ne 'all') { return @($admins) }
    $everyone = @(@(Get-JsonProp $config 'AllowedChatIds') | ForEach-Object { [long]$_ })
    return @(@($admins + $everyone) | Sort-Object -Unique)
}

function Send-NewsSheetNotice {
    param([Parameter(Mandatory)][string]$Text, [AllowEmptyString()][string]$Cause = '')
    foreach ($chat in @(Get-NewsSheetNoticeAudience)) {
        Send-TelegramMessage -ChatId ([long]$chat) -Text $Text -Cause $Cause
    }
}

function Invoke-NewsSheetSync {
    <# Pulls the sheet and publishes it through the same validated, atomic
       writer the Telegram screens use, so the sheet cannot race a person:
       one publisher, one backup trail, one hash check.

       An automatic run yields to anyone holding the draft. Overwriting a
       half-typed draft destroys work the operator cannot get back and gives
       them no clue why. A manual run is a deliberate act, so it proceeds -
       but it still names the current owner and asks first. #>
    param(
        [ValidateSet('auto', 'manual')][string]$Trigger = 'manual',
        [ValidateSet('air', 'draft')][string]$Target = 'air',
        [long]$UserId = 0,
        [long]$ChatId = 0,
        [switch]$Confirmed
    )
    $stop = { param([string]$Message, [bool]$Skip = $false, [bool]$Ask = $false)
        [pscustomobject]@{ Success = $false; Skipped = $Skip; Unchanged = $false; Drafted = $false
            NeedsConfirmation = $Ask; Items = @(); Summary = $null; Error = $Message } }
    # A draft belongs to somebody. An unattended run has no owner to give it
    # to, so the review target is a deliberate act by a named person.
    if ($Target -eq 'draft' -and $UserId -le 0) { return (& $stop (T 'news.draftNeedsUser')) }

    $url = [string](Get-Setting 'NewsSheetCsvUrl')
    if ([string]::IsNullOrWhiteSpace($url)) { return (& $stop (T 'news.sheetNotConfigured')) }

    $draft = Get-NewsTickerDraft
    if ($draft) {
        $owner = [long]$draft.OwnerUserId
        if ($Trigger -eq 'auto') {
            $held = if ($owner -gt 0) { "held by user $owner" } else { 'open to everyone' }
            Write-BridgeLog "News sheet sync skipped: draft $held" 'WARN'
            return (& $stop (T 'news.syncSkipped') $true $false)
        }
        if (Test-NewsTickerDraftOpen -Draft $draft) {
            # Nobody's lock is being broken - but somebody's unpublished work
            # still is, so the confirmation stands for everyone.
            if (-not $Confirmed) {
                return (& $stop (T 'news.openDraftWarning') $false $true)
            }
        }
        elseif ($owner -ne $UserId) {
            # Breaking somebody else's lock is an administrator action
            # everywhere else in the news screens, and a sheet pull destroys
            # that draft just as surely as 🔓 إلغاء القفل does. An operator is
            # pointed at the request instead, which the owner answers.
            if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
                return (& $stop (T 'news.draftHeldUseUnlock' $(Get-UserDisplayName -UserId $owner)))
            }
            if (-not $Confirmed) {
                return (& $stop (T 'news.draftHeldConfirmReplaces' $(Get-UserDisplayName -UserId $owner)) $false $true)
            }
        }
    }

    $download = Get-NewsSheetCsvText -Url $url `
        -TimeoutSeconds (Get-SettingInt 'NewsSheetTimeoutSeconds' 1) `
        -MaxBytes (Get-SettingInt 'NewsImportMaxBytes' 1)
    if (-not $download.Success) {
        Write-BridgeLog "News sheet download failed: $($download.Error)" 'ERROR'
        return (& $stop (T 'news.sheetDownloadFailed' $($download.Error)))
    }

    $items = @(ConvertFrom-NewsSheetCsv -Csv $download.Csv)
    if ($items.Count -eq 0) {
        # A sheet that failed to render, or one somebody cleared by accident,
        # must not take the ticker off air with it. Clearing stays a manual,
        # confirmed action on the news screen.
        return (& $stop (T 'news.sheetEmpty'))
    }

    $snapshot = Get-NewsTickerConfiguredSnapshot
    $current = if ($snapshot.Success) { @($snapshot.Items) } else { @() }
    $summary = Get-NewsSheetChangeSummary -Before $current -After $items

    if ($Target -eq 'draft') {
        # Straight into the draft so the sheet can be read, reordered, or
        # corrected before any of it reaches air. Routed through the ordinary
        # draft import so the same length, count, and duplicate rules apply.
        $text = ConvertTo-NewsTickerText -Items $items -Separator ([string](Get-Setting 'NewsItemSeparator'))
        $validated = ConvertFrom-NewsTickerText -Text $text -Separator ([string](Get-Setting 'NewsItemSeparator')) `
            -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
        if (-not $validated.Success) { return (& $stop (T 'news.sheetLoadFailed' $($validated.Error))) }
        # An open draft is adopted by Start-NewsTickerDraft below rather than
        # thrown away: its items are about to be replaced by the sheet either
        # way, but the draft itself is the thing somebody handed over.
        if ($draft -and -not (Test-NewsTickerDraftOpen -Draft $draft) -and [long]$draft.OwnerUserId -ne $UserId) { Remove-NewsTickerDraft }
        if (-not (Get-NewsTickerDraft -UserId $UserId)) {
            $started = Start-NewsTickerDraft -ChatId $ChatId -UserId $UserId
            if (-not $started.Success) { return (& $stop $started.Error) }
        }
        $import = Import-NewsTickerTextToDraft -UserId $UserId -Text $text -Mode replace
        if (-not $import.Success) { return (& $stop (T 'news.sheetLoadFailed' $($import.Error))) }
        return [pscustomobject]@{ Success = $true; Skipped = $false; Unchanged = $false; Drafted = $true
            NeedsConfirmation = $false; Items = $items; Summary = $summary; Error = '' }
    }

    if (-not $summary.Changed) {
        return [pscustomobject]@{ Success = $false; Skipped = $false; Unchanged = $true; Drafted = $false
            NeedsConfirmation = $false; Items = $items; Summary = $summary; Error = '' }
    }

    $result = Publish-NewsTickerFile -Path ([string](Get-Setting 'NewsFilePath')) -Items $items `
        -ExpectedHash ([string]$snapshot.Hash) -Separator ([string](Get-Setting 'NewsItemSeparator')) `
        -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) `
        -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if (-not $result.Success) {
        Write-BridgeLog "News sheet publish failed: $($result.Error)" 'ERROR'
        return (& $stop (T 'news.sheetPublishFailed' $($result.Error)))
    }

    if ($draft) { Remove-NewsTickerDraft }
    $who = if ($Trigger -eq 'manual' -and $UserId) { Get-UserDisplayName -UserId $UserId } else { (T 'news.autoSync') }
    Add-AuditEntry (T 'news.publishedFromSheetAudit' $who $($items.Count))
    Write-NewsPublishRecord -UserId $UserId -ItemCount $items.Count -Source $(if ($Trigger -eq 'auto') { 'auto' } else { 'sheet' })
    Send-NewsSheetNotice -Text (Get-NewsSheetNoticeText -Summary $summary -Trigger $Trigger -UserId $UserId)

    return [pscustomobject]@{ Success = $true; Skipped = $false; Unchanged = $false; Drafted = $false
        NeedsConfirmation = $false; Items = $items; Summary = $summary; Error = '' }
}

function Get-NewsTickerManagementKeyboard { param([long]$ChatId,[long]$UserId)
    $rows = @()
    $draft = Get-NewsTickerDraft
    $reservation = Get-NewsLockReservation
    $isOpen = Test-NewsTickerDraftOpen -Draft $draft
    if ((-not $draft -or $isOpen) -and $reservation -and [long]$reservation.UserId -ne $UserId) {
        # Showing the start button here would be a lie: the reservation refuses
        # it for as long as it lasts. It covers an open draft too - the whole
        # point of reserving is that the person who asked gets first refusal.
        $rows += , @(@{text=(T 'news.heldFor' $(Get-UserDisplayName -UserId ([long]$reservation.UserId)));callback_data='news:refresh'})
    }
    elseif ($isOpen) {
        # Left open on purpose, with its items. Continuing it is the offer,
        # so the button says so rather than saying 'start'.
        $rows += , @(@{text=(T 'news.carryOnDraft' $(@($draft.Items).Count));callback_data='news:start'}, @{text=(T 'news.importTxt');callback_data='news:import'})
    }
    elseif (-not $draft) {
        $rows += , @(@{text=(T 'news.startEditing');callback_data='news:start'}, @{text=(T 'news.importTxt');callback_data='news:import'})
    }
    elseif ([long]$draft.OwnerUserId -eq $UserId) {
        # First, as the bulletin's play is first: it is what the draft is for,
        # and it sat under five other rows. Colour still marks the one place a
        # mis-tap costs work.
        $rows += , @((New-BridgeButton -Text (T 'news.reviewPublish') -CallbackData 'news:publish' -Style 'success'),
            (New-BridgeButton -Text (T 'news.discardDraft') -CallbackData 'news:cancel' -Style 'danger'))
        $rows += , @(@{text=(T 'news.addItem');callback_data='news:add'}, @{text=(T 'news.editOrder');callback_data='news:list'})
        $rows += , @(@{text=(T 'news.importTxt');callback_data='news:import'}, @{text=(T 'news.preview');callback_data='news:preview'})
        if ((Test-Admin -ChatId $ChatId -UserId $UserId) -or (Get-Setting 'AllowOperatorsClearAllNews')) {
            $rows += , @((New-BridgeButton -Text (T 'news.clearAll') -CallbackData 'news:clear' -Style 'danger'))
        }
        # Leaving without publishing, which until now meant destroying the
        # draft or waiting for somebody to ask for it.
        $rows += , @(@{text=(T 'news.handOverDraft');callback_data='news:handover'})
    }
    else {
        $rows += , @(@{text=(T 'news.with' $(Get-UserDisplayName -UserId ([long]$draft.OwnerUserId)));callback_data='news:refresh'})
        $rows += , @(@{text=(T 'news.requestUnlock');callback_data='news:lockrequest'})
        if (Test-Admin -ChatId $ChatId -UserId $UserId) {
            $rows += , @(@{text=(T 'news.forceUnlock');callback_data='news:unlock'})
        }
    }
    if ((Test-Admin -ChatId $ChatId -UserId $UserId) -or (Get-Setting 'AllowOperatorsRestoreNews')) {
        $rows += , @(@{text=(T 'news.backups');callback_data='news:backups'})
    }
    # Drawn only for whoever holds the lock, and refused for anyone else by
    # Get-CallbackRefusal - a button already delivered to a screen can still be
    # pressed after the lock moves, so hiding it is not on its own a rule.
    if ([string]::IsNullOrWhiteSpace((Get-NewsSheetPullLockDenial -ChatId $ChatId -UserId $UserId)) -and
        (Test-NewsSheetPullAccess -ChatId $ChatId -UserId $UserId) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-Setting 'NewsSheetCsvUrl'))) {
        $rows += , @(@{text=(T 'news.pullPublish');callback_data='news:sheet'}, @{text=(T 'news.pullDraft');callback_data='news:sheetdraft'})
    }
    # The automatic sheet sync publishes to air on its own clock and used to
    # report only to bridge.log; this is where whoever owns the ticker asks
    # whether it ran and what it pushed.
    $rows += , @(@{text=(T 'news.executionLog');callback_data='schedule:execlog:news'}, @{text=(T 'news.refresh');callback_data='news:refresh'})
    $rows += , @(@{text=(T 'common.home');callback_data='menu:main'})
    return @{inline_keyboard=$rows}
}

function Edit-TelegramMessageText {
    <# Edits an existing message in place so interactive screens (e.g. the
       news reorder list) never pile up duplicate messages with stale
       buttons. Falls back to returning $false so callers can resend. #>
    param([Parameter(Mandatory)][long]$ChatId,[Parameter(Mandatory)][int]$MessageId,
        [Parameter(Mandatory)][string]$Text,[hashtable]$ReplyMarkup,
        [ValidateSet('', 'HTML')][string]$ParseMode = '')
    $body = @{ chat_id = $ChatId; message_id = $MessageId; text = $Text }
    if ($ParseMode) { $body.parse_mode = $ParseMode }
    if ($ReplyMarkup) { $body.reply_markup = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $ReplyMarkup) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/editMessageText" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 3
    # Unchanged is redrawn: refreshing a screen nothing has changed on is the
    # common case, and treating Telegram's refusal as failure made the caller
    # send a duplicate copy instead.
    if (-not $request.Success -and [string]$request.Error -like '*message is not modified*') { return $true }
    if (-not $request.Success) { Write-BridgeLog "Failed to edit Telegram message ${MessageId}: $($request.Error)" "WARN"; return $false }
    return $true
}

function Show-NewsTickerDeleteConfirm {
    <# Deleting used to happen on the first tap. A news item is text somebody
       typed, and the list is scrolled with a thumb, so a mis-tap silently
       lost work. The confirmation shows the item being removed - the number
       alone is not enough to recognise it. #>
    param([long]$ChatId, [long]$UserId, [int]$Index, [int]$MessageId = 0)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count) { return $false }
    $item = [string]$draft.Items[$Index]
    $preview = if ($item.Length -gt 200) { $item.Substring(0, 200) + '…' } else { $item }
    $text = (T 'news.confirmDelete' $($Index + 1) $(@($draft.Items).Count) $preview)
    $markup = @{inline_keyboard=@(
            , @((New-BridgeButton -Text (T 'news.yesDelete') -CallbackData "news:delete:$Index" -Style 'danger'),
                (New-BridgeButton -Text (T 'common.cancel') -CallbackData "news:item:$Index")))}
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $markup)) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $markup
    return $true
}

function Show-NewsTickerItemScreen { param([long]$ChatId,[long]$UserId,[int]$Index,[int]$MessageId=0)
    <# One message per news item: full text in the body, move/edit/delete
       buttons carrying the item's CURRENT index. Re-rendered in place after
       every move so the buttons can never point at a stale index. #>
    $draft=Get-NewsTickerDraft -UserId $UserId;if(-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count){return}
    $count=@($draft.Items).Count
    # The arrows are disabled rather than hidden at the ends: a row that loses
    # a button changes width, and the screen appears to shift under the thumb
    # between one item and the next.
    $up = if ($Index -gt 0) { New-BridgeButton -Text (T 'news.moveUp') -CallbackData "news:iup:$Index" }
          else { New-BridgeButton -Text (T 'news.moveUp') -Disabled }
    $down = if ($Index -lt ($count - 1)) { New-BridgeButton -Text (T 'news.moveDown') -CallbackData "news:idown:$Index" }
            else { New-BridgeButton -Text (T 'news.moveDown') -Disabled }
    $rows=@(,@($up,$down))
    $rows+=,@((New-BridgeButton -Text (T 'news.edit') -CallbackData "news:edit:$Index"),
        (New-BridgeButton -Text (T 'common.delete') -CallbackData "news:delask:$Index" -Style 'danger'))
    $rows+=,@(@{text=(T 'news.backToOrder');callback_data='news:list'})
    $text=(T 'news.headlineOf' $($Index+1) ${count} $($draft.Items[$Index]))
    if($MessageId-gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup @{inline_keyboard=$rows})){return}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup @{inline_keyboard=$rows}
}

function Get-NewsListLayout {
    <# How the reorder screen renders one item:
         text    - the headline in the message body, a compact button row.
         stacked - the headline on its own button, controls on the row under it.
         inline  - the headline in the row beside its controls.
         compact - one numbered button per item, controls in the item screen;
                   the only shape that fits thirty items on one screen.
       Telegram splits a row's width equally between its buttons, so inline
       gives a headline a quarter of the screen; it stays available because
       it is the most compact of the three. #>
    $layout = [string](Get-Setting 'NewsListLayout')
    if ($layout -notin @('text', 'stacked', 'inline', 'compact')) { return 'text' }
    return $layout
}

function Get-NewsTickerPageSize {
    <#
        How many items one screen of the reorder list may carry.

        NewsListPaged off means "one long list", but that is a cap and not a
        promise: Telegram rejects an over-large keyboard outright, and a
        rejected edit looks exactly like a list that will not update - which
        is how a 38-item draft came to read as "the last items are missing".
        The long list therefore runs to the button budget and still pages
        beyond it, rather than reviving the bug paging was added to fix.

        One helper rather than the same arithmetic in the keyboard, the text
        and the page count: three copies were three chances to disagree about
        where a page ends.
    #>
    # Telegram's practical ceiling is around a hundred buttons. Staying well
    # under it leaves room for the navigation row and the add/back row.
    $buttonBudget = 90
    $perItem = switch (Get-NewsListLayout) { 'stacked' { 5 } 'compact' { 1 } default { 4 } }
    $maxItems = [math]::Max(3, [math]::Floor(($buttonBudget - 5) / $perItem))
    # Compact could fit eighty-five buttons, but every one of them also needs
    # a readable line in the message above, and eighty-five lines share the
    # message budget down to nothing. Forty keeps a line worth reading.
    if ($perItem -eq 1) { $maxItems = [math]::Min($maxItems, 40) }

    if (-not (Get-Setting 'NewsListPaged')) { return $maxItems }
    return [math]::Max(3, [math]::Min($maxItems, (Get-SettingInt 'NewsListPageSize' 10)))
}

function Get-NewsTickerPageCount { param([long]$UserId)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) { return 1 }
    return [math]::Max(1, [math]::Ceiling(@($draft.Items).Count / (Get-NewsTickerPageSize)))
}

function Get-NewsTickerReorderKeyboard { param([long]$UserId, [int]$Page = 0)
    <#
        One row per item on the current page: the numbered label opens the
        editor, arrows move it, the bin deletes it.

        Paginated because Telegram refuses an over-large keyboard outright. A
        38-item draft rendered 152 buttons; the edit was rejected, the resend
        was rejected for the same reason, and the operator simply saw a list
        that would not update - which reads as "the last items are missing".
        Indexes stay absolute, so every move and delete callback is unchanged
        by paging.
    #>
    $draft = Get-NewsTickerDraft -UserId $UserId
    $rows = @()
    if (-not $draft) {
        $rows += , @(@{text=(T 'news.noDraftOfYoursShort'); callback_data='news:refresh'})
        $rows += , @(@{text=(T 'news.backToManage'); callback_data='news:refresh'})
        return @{inline_keyboard=$rows}
    }

    $count = @($draft.Items).Count
    $size = Get-NewsTickerPageSize
    $pages = [math]::Max(1, [math]::Ceiling($count / $size))
    if ($Page -lt 0) { $Page = 0 }
    if ($Page -ge $pages) { $Page = $pages - 1 }
    $first = $Page * $size
    $last = [math]::Min($count - 1, $first + $size - 1)
    $stackedMax = [math]::Max(8, (Get-SettingInt 'NewsListStackedLabelLength' 8))
    $inlineMax = [math]::Max(8, (Get-SettingInt 'NewsListLabelLength' 8))
    $layout = Get-NewsListLayout
    $numbers = @()

    for ($i = $first; $i -le $last; $i++) {
        if ($layout -eq 'stacked') {
            # Telegram gives a button no colour, border or spacing, so the
            # only way to say "these four belong to that headline" is the
            # label itself: the number rides on every control, and the marker
            # alternates so consecutive items read as separate bands.
            $number = $i + 1
            $marker = if ($i % 2 -eq 0) { '▪️' } else { '▫️' }
            $fullLabel = "$marker $number. $($draft.Items[$i])"
            if ($fullLabel.Length -gt $stackedMax) { $fullLabel = $fullLabel.Substring(0, $stackedMax - 1) + '…' }
            $rows += , @(@{text=$fullLabel; callback_data="news:item:$i"})
            $controls = @()
            if ($i -gt 0) { $controls += , (New-BridgeButton -Text "⬆️ $number" -CallbackData "news:up:$i") }
            if ($i -lt ($count - 1)) { $controls += , (New-BridgeButton -Text "⬇️ $number" -CallbackData "news:down:$i") }
            $controls += , (New-BridgeButton -Text "✏️ $number" -CallbackData "news:edit:$i")
            $controls += , (New-BridgeButton -Text "🗑 $number" -CallbackData "news:delask:$i" -Style 'danger')
            $rows += , @($controls)
            continue
        }
        if ($layout -eq 'compact') {
            # One button per item is what makes thirty of them fit: the
            # controls live in the item screen the number opens, and the
            # headline itself is in the message text above.
            $numbers += , @{text="$($i + 1)"; callback_data="news:item:$i"}
            if ($numbers.Count -eq 5) { $rows += , @($numbers); $numbers = @() }
            continue
        }
        if ($layout -eq 'inline') {
            $label = "$($i + 1). $($draft.Items[$i])"
            if ($label.Length -gt $inlineMax) { $label = $label.Substring(0, $inlineMax - 1) + '…' }
            $row = @()
            if ($i -gt 0) { $row += , (New-BridgeButton -Text '⬆️' -CallbackData "news:up:$i") }
            $row += , (New-BridgeButton -Text $label -CallbackData "news:item:$i")
            if ($i -lt ($count - 1)) { $row += , (New-BridgeButton -Text '⬇️' -CallbackData "news:down:$i") }
            $row += , (New-BridgeButton -Text '🗑' -CallbackData "news:delask:$i" -Style 'danger')
            $rows += , @($row)
            continue
        }

        # The headline is in the message text above, not in this button.
        # Telegram splits a row's width equally between its buttons, so a
        # headline sharing a row with three controls only ever got a quarter
        # of the screen and wrapped into three lines. And the row kept a
        # fixed four buttons: dropping the arrow at either end gave those two
        # rows a third of the width each and made them render taller than the
        # rest, which is what read as items of different sizes.
        #
        # The two end placeholders are real disabled buttons now (Bot API
        # 10.3) instead of a live callback pointing at a no-op handler: the
        # first item's ⬆️ and the last item's ⬇️ were pressable, answered,
        # and did nothing, which is indistinguishable from a bridge that
        # dropped the press. 'news:noop' is still routed - buttons live on in
        # messages Telegram already delivered.
        $row = @()
        $row += , (New-BridgeButton -Text "$($i + 1)" -CallbackData "news:item:$i")
        if ($i -gt 0) { $row += , (New-BridgeButton -Text '⬆️' -CallbackData "news:up:$i") }
        else { $row += , (New-BridgeButton -Text '▫️' -Disabled) }
        if ($i -lt ($count - 1)) { $row += , (New-BridgeButton -Text '⬇️' -CallbackData "news:down:$i") }
        else { $row += , (New-BridgeButton -Text '▫️' -Disabled) }
        $row += , (New-BridgeButton -Text '🗑' -CallbackData "news:delask:$i" -Style 'danger')
        $rows += , @($row)
    }

    if ($numbers.Count -gt 0) { $rows += , @($numbers) }

    if ($pages -gt 1) {
        $nav = @()
        if ($Page -gt 0) { $nav += , @{text=(T 'news.prev'); callback_data="news:list:$($Page - 1)"} }
        $nav += , @{text=(T 'news.page' $($Page + 1) $pages); callback_data="news:list:$Page"}
        if ($Page -lt ($pages - 1)) { $nav += , @{text=(T 'news.next'); callback_data="news:list:$($Page + 1)"} }
        $rows += , @($nav)
    }
    $rows += , @(@{text=(T 'news.addItem'); callback_data='news:add'}, @{text=(T 'news.backToManage'); callback_data='news:refresh'})
    return @{inline_keyboard=$rows}
}

function Get-NewsListEscapedLine {
    <#
        One listing line, escaped, guaranteed to fit MaxLength AFTER escaping.

        Shortening the raw headline and escaping the result - rather than
        escaping and then cutting - is the whole point: cutting escaped text
        can land inside '&amp;' and leave '&am', which is not an entity, and
        Telegram rejects the entire message rather than the one line.

        The loop shrinks in proportion to the overshoot, so it converges in a
        step or two even for a headline that is nothing but ampersands.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Item, [Parameter(Mandatory)][int]$MaxLength)
    $raw = $Item
    $ellipsis = ''
    if ($raw.Length -gt $MaxLength) { $raw = $raw.Substring(0, $MaxLength - 1); $ellipsis = '…' }
    $escaped = ConvertTo-TelegramHtmlText -Text $raw
    while (($escaped.Length + $ellipsis.Length) -gt $MaxLength -and $raw.Length -gt 1) {
        $keep = [math]::Floor($raw.Length * ($MaxLength - 1) / $escaped.Length)
        if ($keep -ge $raw.Length) { $keep = $raw.Length - 1 }
        $raw = $raw.Substring(0, [math]::Max(1, $keep))
        $escaped = ConvertTo-TelegramHtmlText -Text $raw
        $ellipsis = '…'
    }
    return "$escaped$ellipsis"
}

function Get-NewsTickerReorderText { param([long]$UserId, [int]$Page = 0)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) { return "$(T news.orderHeading)`n`n$(T news.noDraftWarning)" }

    $count = @($draft.Items).Count
    $size = Get-NewsTickerPageSize
    $pages = [math]::Max(1, [math]::Ceiling($count / $size))
    if ($Page -lt 0) { $Page = 0 }
    if ($Page -ge $pages) { $Page = $pages - 1 }
    $first = $Page * $size + 1
    $last = [math]::Min($count, $first + $size - 1)

    $lines = [System.Collections.Generic.List[string]]::new()
    # Sent with parse_mode=HTML, so every literal < > & below must already be
    # escaped and every headline must go through ConvertTo-TelegramHtmlText.
    $lines.Add((T 'news.orderTitle'))
    $lines.Add((T 'news.headlines' $count))
    if ($pages -gt 1) { $lines.Add((T 'news.showing' $first $last $($Page + 1) $pages)) }
    # Said plainly, because the operator asked for one long list and is
    # getting pages anyway: the reason is Telegram's limit, not the setting
    # being ignored.
    if ($pages -gt 1 -and -not (Get-Setting 'NewsListPaged')) {
        $lines.Add((T 'news.longListLimit' $size))
    }
    $layout = Get-NewsListLayout
    if ($layout -in @('text', 'compact')) {
        # Here rather than in a button: a button shares its row's width with
        # the controls beside it, while this line has the whole message and
        # wraps by itself. Capped so a long draft cannot push the message
        # past what Telegram will send.
        $items = @($draft.Items)
        # The budget is measured AFTER escaping, and against the bridge's own
        # send limit rather than a number of its own. Escaping only ever grows
        # text - one '&' becomes five characters - so a page of headlines like
        # "AT&T" measured before escaping came out at 6000 characters against
        # a 3500 limit, split into two chunks, and lost its parse mode: the
        # operator got '<b>' and '<blockquote expandable>' as visible text.
        # 900 leaves room for the heading, the hint and the quotation tags.
        $pageBudget = [math]::Max(400, $script:TelegramTextLimit - 900)
        $lineMax = [math]::Min(
            [math]::Max(40, (Get-SettingInt 'NewsListLabelLength' 8)),
            [math]::Max(40, [math]::Floor($pageBudget / $size)))
        $lines.Add('')
        # An expandable block quotation (Bot API 7.6) collapses the listing to
        # a few lines with a "show more" of Telegram's own, so a forty-item
        # page no longer pushes its own keyboard off the screen. The character
        # budget still applies: expandable governs height, not length.
        $body = [System.Collections.Generic.List[string]]::new()
        for ($i = $first; $i -le $last; $i++) {
            $body.Add("<b>$i.</b> $(Get-NewsListEscapedLine -Item ([string]$items[$i - 1]) -MaxLength $lineMax)")
        }
        $lines.Add("<blockquote expandable>$($body -join "`n")</blockquote>")
    }

    $lines.Add('')
    $lines.Add($(switch ($layout) {
                'stacked' { (T 'news.orderHintStacked') }
                'inline'  { (T 'news.orderHintInline') }
                'compact' { (T 'news.orderHintCompact') }
                default   { (T 'news.orderHintNumbers') }
            }))
    return ($lines -join "`n")
}

function Get-NewsDraftDiff {
    <#
        What publishing this draft would change, item by item.

        The publish confirmation said "3 items will be replaced", which is a
        count, not a decision: it does not say whether three were reworded or
        three were thrown away and three new ones written. Comparing the two
        lists says which.
    #>
    param([AllowNull()][object[]]$Draft, [AllowNull()][object[]]$Live)
    $draftItems = @(@($Draft) | ForEach-Object { [string]$_ })
    $liveItems = @(@($Live) | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        Added = @($draftItems | Where-Object { $liveItems -notcontains $_ })
        Removed = @($liveItems | Where-Object { $draftItems -notcontains $_ })
        Kept = @($draftItems | Where-Object { $liveItems -contains $_ })
    }
}

function Get-NewsTickerReorderBlocks {
    <#
        The reorder screen as a table.

        The headline and its controls have been apart since 6.9.3 - the text
        in the message body, the buttons underneath - because a button that
        shares a row's width with three others gets a quarter of the screen.
        A table puts the order back in front of the eye as an order: a
        numbered column reads as a running order, which is what this list is.

        The length column is new and is the reason the table earns its place:
        the ticker enforces NewsMaxItemLength and an editor had no way to see
        which headline was near it until the publish was refused.
    #>
    param([long]$UserId, [int]$Page = 0)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) {
        return @(
            @{ type = 'heading'; text = (T 'news.orderHeading'); size = 3 }
            @{ type = 'paragraph'; text = (T 'news.noDraftWarning') }
        )
    }
    $items = @($draft.Items)
    $count = $items.Count
    $size = Get-NewsTickerPageSize
    $pages = [math]::Max(1, [math]::Ceiling($count / $size))
    if ($Page -lt 0) { $Page = 0 }
    if ($Page -ge $pages) { $Page = $pages - 1 }
    $first = $Page * $size + 1
    $last = [math]::Min($count, $first + $size - 1)
    $max = Get-SettingInt 'NewsMaxItemLength' 1

    $blocks = @(@{ type = 'heading'; text = (T 'news.draftOrder' $count); size = 3 })
    if ($pages -gt 1) {
        $blocks += @{ type = 'paragraph'; text = (T 'news.showing2' $first $last $($Page + 1) $pages) }
    }

    $lineMax = [math]::Max(40, (Get-SettingInt 'NewsListLabelLength' 8))
    $cells = @(, @(
            @{ text = '#'; is_header = $true }
            @{ text = (T 'news.col.item'); is_header = $true }
            @{ text = (T 'news.chars'); is_header = $true }
        ))
    for ($i = $first; $i -le $last; $i++) {
        $item = [string]$items[$i - 1]
        $shown = if ($item.Length -gt $lineMax) { $item.Substring(0, $lineMax - 1) + '…' } else { $item }
        # Marked rather than merely counted: a number the editor has to
        # compare against a setting they cannot see is not a warning.
        $length = if ($max -gt 0 -and $item.Length -gt ($max * 0.9)) { "⚠️ $($item.Length)" } else { [string]$item.Length }
        $cells += , @(@{ text = [string]$i }, @{ text = $shown }, @{ text = $length })
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }

    # What is on air right now, under the draft rather than behind a preview
    # button. Deciding whether a draft is ready means comparing it with what
    # it would replace, and that took a round trip through 👁 معاينة and back.
    $snapshot = Get-NewsTickerConfiguredSnapshot
    if ($snapshot.Success) {
        $live = @($snapshot.Items)
        $diff = Get-NewsDraftDiff -Draft $items -Live $live
        $summary = (T 'news.onAirNowCount' $($live.Count) $($diff.Added.Count) $($diff.Removed.Count))
        $inner = @()
        foreach ($line in $diff.Added) { $inner += @{ type = 'paragraph'; text = "➕ $line" } }
        foreach ($line in $diff.Removed) { $inner += @{ type = 'paragraph'; text = "➖ $line" } }
        if ($inner.Count -eq 0) { $inner = @(@{ type = 'paragraph'; text = (T 'news.noDifference') }) }
        $blocks += @{ type = 'details'; summary = $summary; blocks = $inner }
    }

    $blocks += @{ type = 'paragraph'; text = $(switch (Get-NewsListLayout) {
                'stacked' { (T 'news.orderHintStacked') }
                'inline' { (T 'news.orderHintInline') }
                'compact' { (T 'news.orderHintCompact') }
                default { (T 'news.orderHintNumbers') }
            }) }
    return $blocks
}

function Get-NewsPublishReviewBlocks {
    <#
        The publish confirmation, as what would actually change.

        "3 items will be replaced" is a count. An editor about to put copy on
        air is deciding whether these are the right words, and for that they
        need the words.
    #>
    param([long]$UserId)
    $draft = Get-NewsTickerDraft -UserId $UserId
    if (-not $draft) { return @() }
    $snapshot = Get-NewsTickerConfiguredSnapshot
    if (-not $snapshot.Success) { return @() }
    $diff = Get-NewsDraftDiff -Draft @($draft.Items) -Live @($snapshot.Items)

    $blocks = @(@{ type = 'heading'; text = (T 'news.reviewPublishButton'); size = 3 })
    $blocks += @{ type = 'paragraph'
        text = (T 'news.draftVsAir' $(@($draft.Items).Count) $(@($snapshot.Items).Count) $($diff.Added.Count) $($diff.Removed.Count)) }
    if ($diff.Added.Count -eq 0 -and $diff.Removed.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = (T 'news.noChangeOnPublish') }
        return $blocks
    }
    # Replacing a full ticker is every old item removed and every new one
    # added: two rows per headline, and a station's strip runs to forty of
    # them. Capped like the reports, additions first - they are what is about
    # to go on air.
    $changes = @(
        @($diff.Added | ForEach-Object { @{ Mark = '➕'; Line = [string]$_ } })
        @($diff.Removed | ForEach-Object { @{ Mark = '➖'; Line = [string]$_ } })
    )
    # -Items keeps the newest; here the front of the list is what matters, so
    # the list is reversed into it and back out again.
    $trimmed = Select-RichTableRows -Items @($changes)[($changes.Count - 1)..0]
    $shown = @($trimmed.Rows)
    if ($shown.Count -gt 1) { $shown = @($shown[($shown.Count - 1)..0]) }
    $cells = @(, @(@{ text = ''; is_header = $true }, @{ text = (T 'news.col.item'); is_header = $true }))
    foreach ($change in $shown) { $cells += , @(@{ text = $change.Mark }, @{ text = $change.Line }) }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown $shown.Count
    if ($note) { $blocks += @{ type = 'paragraph'; text = $note } }
    if ($diff.Kept.Count -gt 0) {
        $blocks += @{ type = 'details'; summary = (T 'news.noChange' $($diff.Kept.Count))
            blocks = @($diff.Kept | ForEach-Object { @{ type = 'paragraph'; text = "· $_" } }) }
    }
    return $blocks
}

function Show-NewsTickerReorderScreen { param([long]$ChatId,[long]$UserId,[int]$MessageId=0,[int]$Page=0)
    <# Edits the originating message when possible so repeated ⬆️/⬇️ presses
       reuse a single message instead of flooding the chat with stale lists. #>
    $kb = Get-NewsTickerReorderKeyboard -UserId $UserId -Page $Page
    # Blocks first, edited in place exactly as the text version is, so
    # repeated ⬆️/⬇️ presses still reuse one message.
    #
    # Not built at all once rich sending is known to be refused: this screen
    # re-renders on every arrow press and the block version reads the on-air
    # file to compare against it, which is work nobody would see.
    if (-not $script:RichMessagesUnavailable) {
        $blocks = Get-NewsTickerReorderBlocks -UserId $UserId -Page $Page
        if ($MessageId -gt 0) {
            if (Edit-TelegramRichMessage -ChatId $ChatId -MessageId $MessageId -Blocks $blocks -ReplyMarkup $kb) { return }
        }
        elseif (Send-TelegramRichMessage -ChatId $ChatId -Blocks $blocks -ReplyMarkup $kb) { return }
    }
    $text=Get-NewsTickerReorderText -UserId $UserId -Page $Page
    if($MessageId-gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $kb -ParseMode 'HTML')){return}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $kb -ParseMode 'HTML'
}

function Get-NewsTickerBackupFiles {
    <#
        The saved copies, newest first. One reader for the list, the keyboard
        AND the restore, so line 3 in the text is the copy button 3 restores.

        The cap is NewsBackupKeepFiles, which is also what prunes the folder,
        because the two are the same promise seen from two ends. It used to be
        a hard-coded ten while the setting defaulted to twenty: the bridge kept
        twenty copies, offered ten, and an editor reading "كم نسخة يُحتفظ بها
        = 20" could not reach half of what the disk held.
    #>
    return @(Get-ChildItem -LiteralPath $script:newsBackupDirectory -File -Filter '*.txt' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First (Get-SettingInt 'NewsBackupKeepFiles' 1))
}

function Get-NewsTickerBackupByIndex {
    <#
        The saved copy a button names, or $null when the index names none.

        PowerShell reads a negative index from the END of the array, so a
        bounds check that tests only the upper end does not fail on a bad
        index - it restores the OLDEST copy onto the live ticker. The same
        shape was fixed in the template presets; this path is worse, because
        AllowOperatorsRestoreNews opens it beyond administrators.
    #>
    param([int]$Index)
    $files = @(Get-NewsTickerBackupFiles)
    if ($Index -lt 0 -or $Index -ge $files.Count) { return $null }
    return $files[$Index]
}

function Get-NewsTickerBackupsText {
    <#
        Which saved copy is which.

        The screen was one line - (T 'news.pickBackup') - over
        buttons carrying a timestamp each. A timestamp does not say what is
        in that copy, and the press puts its text on air; how many items it
        holds is what an editor recognises a copy by, next to how long ago it
        was saved.
    #>
    $files = @(Get-NewsTickerBackupFiles)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'news.backupsTitle'))
    if ($files.Count -eq 0) {
        $lines.Add((T 'news.noBackups'))
        return ($lines -join "`n")
    }
    $lines.Add((T 'news.backupCount' $($files.Count)))
    $lines.Add('')
    $separator = [string](Get-Setting 'NewsItemSeparator')
    for ($i = 0; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        $age = [int]([math]::Max(0, ((Get-Date) - $file.LastWriteTime).TotalMinutes))
        $count = ''
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            $parsed = ConvertFrom-NewsTickerText -Text $text -Separator $separator `
                -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
            $count = (T 'news.headlineCount' $(@($parsed.Items).Count))
        }
        catch { $count = (T 'news.backupUnreadable') }
        $lines.Add("$($i + 1). <code>$($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))</code>$count")
        $lines.Add((T 'news.indented' $(if ($age -lt 1) { (T 'news.savedNow') } else { (T 'news.ago' $(Format-DurationMinutes -Minutes $age)) })))
    }
    $lines.Add('')
    $lines.Add((T 'news.restoreNote'))
    return ($lines -join "`n")
}

function Get-NewsTickerBackupsKeyboard {
    $rows=@();$files=@(Get-NewsTickerBackupFiles)
    for($i=0;$i-lt $files.Count;$i++){$rows+=,@(@{text="$($i+1). $($files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))";callback_data="news:restore:$i"})};$rows+=,@(@{text=(T 'news.backToManage');callback_data='news:refresh'});return @{inline_keyboard=$rows}
}

function Get-NewsScreenLine { param([string]$Text, [int]$Length = 80)
    # One headline as a line of the screen. Cut by text element, as the
    # bulletin table cuts its cells: eight headlines of up to a thousand
    # characters each made the screen a wall.
    $elements = [Globalization.StringInfo]::new($Text)
    if ($elements.LengthInTextElements -le $Length) { return $Text }
    return $elements.SubstringByTextElements(0, $Length) + '…'
}

function Show-NewsTickerManagementScreen { param([long]$ChatId,[long]$UserId,[int]$MessageId=0)
    <#
        Whoever holds the draft sees the draft - what they are about to
        publish - with what is new against the air marked, and how many live
        headlines publishing would drop. Everyone else sees the live ticker.
        It used to show the live ticker to the draft's owner too, with the
        draft as one line and a count.

        Redrawn in place when a message is given, as the boards screens are;
        a new message per tap left a column of stale screens whose buttons
        still looked live.
    #>
    $snapshot=Get-NewsTickerConfiguredSnapshot
    $mine = Get-NewsTickerDraft -UserId $UserId
    $text=if(-not $snapshot.Success){(T 'news.fileUnreadable' $($snapshot.Error))}
    else {
        $live = @($snapshot.Items)
        $header = (T 'news.manage' $(Get-ArabicCountNoun -Count $live.Count -One 'خبر' -Two 'خبران' -Few 'أخبار' -Many 'خبرًا' -EnglishOne 'headline' -EnglishMany 'headlines'))
        $items = if ($mine) { @($mine.Items) } else { $live }
        $body = ''
        if ($mine) {
            $diff = Get-NewsDraftDiff -Draft $items -Live $live
            $header += (T 'news.draftHeading' @($items).Count @($diff.Added).Count)
            if (@($diff.Removed).Count -gt 0) { $header += "`n" + (T 'news.draftRemoves' @($diff.Removed).Count) }
        }
        if (@($items).Count -gt 0) {
            $n = 0
            $body = (@($items | Select-Object -First 8) | ForEach-Object {
                    $n++
                    $mark = if ($mine -and $live -notcontains [string]$_) { '🆕 ' } else { '' }
                    "$n. $mark$(Get-NewsScreenLine -Text ([string]$_))"
                }) -join "`n"
            $rest = @($items).Count - 8
            $tail = if ($rest -gt 0) { (T 'news.andMore' $(Get-ArabicCountNoun -Count $rest -One 'خبر' -Two 'خبران' -Few 'أخبار' -Many 'خبرًا' -EnglishOne 'headline' -EnglishMany 'headlines')) } else { '' }
            "$header`n`n$body$tail"
        } else { (T 'news.tickerEmpty' $header) }
    }
    if (Test-NewsTickerDraftOpen -Draft $script:NewsTickerDraft) {
        $by = [long](Get-JsonProp $script:NewsTickerDraft 'HandedOverBy')
        $byText = if ($by -gt 0) { (T 'news.handedOverBy' $(Get-UserDisplayName -UserId $by)) } else { '' }
        $text += (T 'news.openDraftLine' $byText $(@($script:NewsTickerDraft.Items).Count))
    }
    elseif($script:NewsTickerDraft -and -not $mine){$text+=(T 'news.lockedDraftLine' $(Get-UserDisplayName -UserId ([long]$script:NewsTickerDraft.OwnerUserId)) $(@($script:NewsTickerDraft.Items).Count))}
    $keyboard = Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard
}

function Get-NewsPasteParse { param([string]$Text)
    ConvertFrom-NewsPasteText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1)
}

function Add-NewsTickerDraftItems {
    <#
        Several headlines into the draft as one block, in the order pasted.

        One at a time through Add-NewsTickerDraftItem would reverse them when
        new items go to the top: the last one pasted would lead. The block
        goes to the top or the end whole, as NewNewsItemAtTop says.

        Items already in the draft are skipped, and the block is cut at
        NewsMaxItems rather than refused whole - the review already told the
        operator how many would fit. Returns how many went in.
    #>
    param([long]$UserId, [string[]]$Items)
    $draft = Get-NewsTickerDraft -UserId $UserId; if (-not $draft) { return 0 }
    $existing = [Collections.Generic.HashSet[string]]::new([string[]]@($draft.Items), [StringComparer]::Ordinal)
    $room = [math]::Max(0, (Get-SettingInt 'NewsMaxItems' 1) - @($draft.Items).Count)
    $block = @(@($Items) | Where-Object { $existing.Add([string]$_) } | Select-Object -First $room)
    if ($block.Count -eq 0) { return 0 }
    $draft.Items = if (Get-Setting 'NewNewsItemAtTop') { @($block) + @($draft.Items) } else { @($draft.Items) + @($block) }
    $draft.UpdatedAt = (Get-Date).ToString('o')
    if (-not (Save-NewsTickerDraft)) { return 0 }
    return $block.Count
}

function Get-NewsPastePlan {
    <# What the review shows and what confirming would do, from one place so
       the two cannot disagree. #>
    param([long]$UserId, [string[]]$Items)
    $draft = Get-NewsTickerDraft -UserId $UserId
    $inDraft = [Collections.Generic.HashSet[string]]::new([string[]]@(if ($draft) { $draft.Items }), [StringComparer]::Ordinal)
    $new = @(@($Items) | Where-Object { -not $inDraft.Contains([string]$_) })
    $room = [math]::Max(0, (Get-SettingInt 'NewsMaxItems' 1) - $inDraft.Count)
    return [pscustomobject]@{
        New = @($new | Select-Object -First $room)
        AlreadyInDraft = @($Items).Count - $new.Count
        NoRoom = [math]::Max(0, $new.Count - $room)
    }
}

function Get-NewsPasteSnippet { param([string]$Text, [int]$Length = 50)
    # Escaped here, because this is the operator's pasted text going into an
    # HTML message, and cut by text element so an emoji is never halved.
    $elements = [Globalization.StringInfo]::new($Text)
    $cut = if ($elements.LengthInTextElements -gt $Length) { $elements.SubstringByTextElements(0, $Length) + '…' } else { $Text }
    return (ConvertTo-TelegramHtmlText -Text $cut)
}

function Show-NewsPasteReview {
    <#
        The review a multi-line paste gets before anything is added.

        Nothing goes into the draft from here: a paste is the one place a
        slip of the thumb can put thirty lines of somebody's chat into the
        ticker, so the count, the skips and the first few headlines are shown
        first. Redrawn in place as more of the paste arrives.
    #>
    param([long]$ChatId, [long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'news_paste_review') { return }
    $items = @($state.Items)
    $plan = Get-NewsPastePlan -UserId $UserId -Items $items
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add((T 'news.paste.found' ($items.Count + @($state.TooLong).Count)))
    $lines.Add((T 'news.paste.new' @($plan.New).Count))
    if ($plan.AlreadyInDraft -gt 0) { $lines.Add((T 'news.paste.inDraft' $plan.AlreadyInDraft)) }
    if ([int]$state.Duplicates -gt 0) { $lines.Add((T 'news.paste.repeated' $([int]$state.Duplicates))) }
    if (@($state.TooLong).Count -gt 0) {
        $lines.Add((T 'news.paste.tooLong' @($state.TooLong).Count (Get-SettingInt 'NewsMaxItemLength' 1)))
        foreach ($long in @($state.TooLong | Select-Object -First 3)) { $lines.Add("   «$(Get-NewsPasteSnippet -Text $long -Length 40)»") }
    }
    if ($plan.NoRoom -gt 0) { $lines.Add((T 'news.paste.noRoom' $plan.NoRoom (Get-SettingInt 'NewsMaxItems' 1))) }
    if (@($plan.New).Count -gt 0) {
        $lines.Add('')
        $position = 0
        foreach ($item in @($plan.New | Select-Object -First 5)) { $position++; $lines.Add("$position. $(Get-NewsPasteSnippet -Text $item)") }
        if (@($plan.New).Count -gt 5) { $lines.Add((T 'news.paste.more' (@($plan.New).Count - 5))) }
    }
    $lines.Add('')
    $lines.Add((T 'news.paste.keepSending'))
    $rows = @()
    if (@($plan.New).Count -gt 0) {
        $where = if (Get-Setting 'NewNewsItemAtTop') { (T 'news.atStart') } else { (T 'news.atEnd') }
        $rows += , @( @{ text = (T 'news.paste.confirm' @($plan.New).Count $where); callback_data = 'news:pasteok'; style = 'success' } )
    }
    $rows += , @( @{ text = (T 'reply.cancelWord'); callback_data = 'news:pastecancel' } )
    $markup = @{ inline_keyboard = $rows }
    $text = $lines -join "`n"
    $messageId = [int]$state.MessageId
    if ($messageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $messageId -Text $text -ReplyMarkup $markup -ParseMode HTML)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ParseMode HTML -ReplyMarkup $markup | Out-Null
    $state.MessageId = [int]$script:LastTelegramMessageId
}

function Add-NewsPasteChunk {
    <#
        More of a paste arriving while its review is open.

        Telegram splits a message past 4096 characters into several, so a
        long paste lands as two or three messages a moment apart. Each joins
        the open batch instead of starting another, and the review redraws.
    #>
    param([long]$ChatId, [long]$UserId, [string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'news_paste_review' -or [long]$state.UserId -ne $UserId) { return }
    $parsed = Get-NewsPasteParse -Text $Value
    $seen = [Collections.Generic.HashSet[string]]::new([string[]]@($state.Items), [StringComparer]::Ordinal)
    $items = [Collections.Generic.List[string]]::new([string[]]@($state.Items))
    $duplicates = [int]$state.Duplicates + [int]$parsed.DuplicateCount
    foreach ($item in @($parsed.Items)) { if ($seen.Add([string]$item)) { $items.Add([string]$item) } else { $duplicates++ } }
    $state.Items = @($items)
    $state.TooLong = @(@($state.TooLong) + @($parsed.TooLong))
    $state.Duplicates = $duplicates
    Show-NewsPasteReview -ChatId $ChatId -UserId $UserId
}

function Complete-NewsPaste {
    <# The review's two buttons. The draft is re-read here, not trusted from
       the review: it may have been published or handed on since. #>
    param([long]$ChatId, [long]$UserId, [switch]$Cancel)
    $state = Get-PendingState -ChatId $ChatId
    $mine = $state -and $state.Mode -eq 'news_paste_review' -and [long]$state.UserId -eq $UserId
    if ($mine) { Clear-PendingState -ChatId $ChatId }
    $text = if ($Cancel) { (T 'news.paste.cancelled') }
    elseif (-not $mine) { (T 'news.paste.gone') }
    elseif (-not (Get-NewsTickerDraft -UserId $UserId)) { (T 'reply.noDraftOfYours') }
    else {
        $added = Add-NewsTickerDraftItems -UserId $UserId -Items @($state.Items)
        $where = if (Get-Setting 'NewNewsItemAtTop') { (T 'news.atStart') } else { (T 'news.atEnd') }
        if ($added -gt 0) { Write-BridgeLog "User $UserId pasted $added headline(s) into the news draft" }
        if ($added -gt 0) { (T 'news.paste.added' $added $where) } else { (T 'news.paste.nothingAdded') }
    }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
}

function Complete-NewsTickerAddText { param([long]$ChatId,[long]$UserId,[string]$Value)
    Clear-PendingState -ChatId $ChatId
    # One headline goes straight in, as it always has. Anything more - several
    # lines, a repeat, a line too long - opens the review instead of failing
    # with "check the text and the limits", which is what a paste used to get.
    $paste = Get-NewsPasteParse -Text $Value
    if (@($paste.Items).Count -ne 1 -or @($paste.TooLong).Count -gt 0 -or [int]$paste.DuplicateCount -gt 0) {
        if (@($paste.Items).Count + @($paste.TooLong).Count -eq 0) {
            Send-TelegramMessage -ChatId $ChatId -Text (T 'news.addFailed') -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
            return
        }
        Set-PendingState -ChatId $ChatId -State @{
            Mode = 'news_paste_review'; UserId = $UserId; StartedAt = (Get-Date)
            Items = @($paste.Items); TooLong = @($paste.TooLong); Duplicates = [int]$paste.DuplicateCount; MessageId = 0
        } | Out-Null
        Show-NewsPasteReview -ChatId $ChatId -UserId $UserId
        return
    }
    $ok=Add-NewsTickerDraftItem -UserId $UserId -Text ([string]@($paste.Items)[0])
    # Says where it landed, so "first" is visible rather than assumed.
    $where = if (Get-Setting 'NewNewsItemAtTop') { (T 'news.atStart') } else { (T 'news.atEnd') }
    Send-TelegramMessage -ChatId $ChatId -Text $(if($ok){(T 'news.added' $where)}else{(T 'news.addFailed')}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
}

function Complete-NewsTickerEditText { param([long]$ChatId,[long]$UserId,[string]$Value)
    $state=Get-PendingState -ChatId $ChatId;if(-not $state -or $state.Mode-ne'news_edit_text'){return};$index=[int]$state.Index;Clear-PendingState -ChatId $ChatId
    $ok=Update-NewsTickerDraftItem -UserId $UserId -Index $index -Text $Value
    Send-TelegramMessage -ChatId $chatId -Text $(if($ok){(T 'news.itemUpdated')}else{(T 'news.editFailed')});Show-NewsTickerReorderScreen -ChatId $chatId -UserId $UserId
}

function Receive-NewsTickerImport { param($Document,[long]$ChatId,[long]$UserId)
    $state=Get-PendingState -ChatId $ChatId
    if(-not $state -or $state.Mode -ne 'news_import_upload' -or [long]$state.UserId -ne $UserId){Send-TelegramMessage -ChatId $ChatId -Text (T 'news.startImportFirst');return}
    $name=[string](Get-JsonProp $Document 'file_name');if([IO.Path]::GetExtension($name) -ine '.txt'){Send-TelegramMessage -ChatId $ChatId -Text (T 'news.txtOnly');return}
    $staged=Join-Path $script:newsImportDirectory ("news-$([guid]::NewGuid().ToString('N')).txt")
    try {
        Receive-TelegramDocument -FileId ([string](Get-JsonProp $Document 'file_id')) -DestinationPath $staged -MaximumBytes (Get-SettingInt 'NewsImportMaxBytes' 1)|Out-Null
        $snapshot=Get-NewsTickerSnapshot -Path $staged -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
        if(-not $snapshot.Success){throw $snapshot.Error}
        $text=ConvertTo-NewsTickerText -Items @($snapshot.Items) -Separator ([string](Get-Setting 'NewsItemSeparator'))
        $result=Import-NewsTickerTextToDraft -UserId $UserId -Text $text -Mode replace
        if(-not $result.Success){throw $result.Error}
        Clear-PendingState -ChatId $ChatId
        Send-TelegramMessage -ChatId $ChatId -Text (T 'news.imported' $($result.Count)) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
    } catch { Send-TelegramMessage -ChatId $ChatId -Text (T 'news.importFailed' $(Protect-SensitiveText $_.Exception.Message)) }
    finally {Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue}
}
