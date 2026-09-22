#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Notices an administrator writes for the people who use the bot - a
    maintenance window, a change of practice, "the studio moves to hall 2 at
    six". The audit trail and the log are for what the bridge did; this is for
    what a person needs the others to know, and it is the one message the bot
    sends that nobody asked it for. Which is why every part of it is bounded:
    who sees it, how long it lives, how often it repeats, and whether it stops
    once it has been read.
#>

function Get-AnnouncementsFile {
    return (Join-Path $logDir 'announcements.json')
}

function Import-BridgeAnnouncements {
    $script:Announcements = [System.Collections.Generic.List[object]]::new()
    $path = Get-AnnouncementsFile
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $raw = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($entry in @(Get-JsonProp $raw 'Announcements')) { $script:Announcements.Add($entry) }
        $live = @(Get-ActiveAnnouncements).Count
        if ($live -gt 0) { Write-BridgeLog "Restored $live active announcement(s)." }
    }
    catch { Write-BridgeLog "Could not read announcements.json: $($_.Exception.Message)" 'WARN' }
}

function Save-BridgeAnnouncements {
    try {
        $path = Get-AnnouncementsFile
        $json = [ordered]@{ Announcements = @($script:Announcements) } | ConvertTo-Json -Depth 6
        return (Write-BridgeValidatedJson -Path $path -Json $json)
    }
    catch { Write-BridgeLog "Could not write announcements.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Test-AnnouncementLive {
    <# Still worth showing: not cancelled, and not past its own expiry. #>
    param([Parameter(Mandatory)]$Announcement, [datetime]$Now = (Get-Date))
    if ([string](Get-JsonProp $Announcement 'Status') -ne 'active') { return $false }
    $expires = [string](Get-JsonProp $Announcement 'ExpiresAt')
    if ([string]::IsNullOrWhiteSpace($expires)) { return $true }
    $at = [datetime]::MinValue
    if (-not [datetime]::TryParse($expires, [ref]$at)) { return $true }
    return ($Now -lt $at)
}

function Get-ActiveAnnouncements {
    param([datetime]$Now = (Get-Date))
    return @($script:Announcements | Where-Object { Test-AnnouncementLive -Announcement $_ -Now $Now })
}

function Get-AnnouncementScopeLabel {
    param([Parameter(Mandatory)]$Announcement)
    switch ([string](Get-JsonProp $Announcement 'Scope')) {
        'admins' { return (T 'ann.forAdmins') }
        'operators' { return (T 'ann.forOperators') }
        'user' { return (T 'ann.forWhom' $(Get-UserDisplayName -UserId ([long](Get-JsonProp $Announcement 'TargetUserId')))) }
        default { return (T 'ann.forEveryone') }
    }
}

function Get-AnnouncementAudience {
    <#
        Who this notice is for, as user ids.

        Read from the roster every time rather than frozen at creation: a
        notice that repeats for a day should reach somebody granted access this
        morning, and should stop reaching somebody whose access was revoked at
        noon.
    #>
    param([Parameter(Mandatory)]$Announcement)
    $scope = [string](Get-JsonProp $Announcement 'Scope')
    if ($scope -eq 'user') {
        $target = [long](Get-JsonProp $Announcement 'TargetUserId')
        if ($target -le 0) { return @() }
        return @($target)
    }
    $users = @(Get-AuthorizedUsers | Where-Object { -not $_.Disabled })
    switch ($scope) {
        'admins' { return @($users | Where-Object { [string]$_.Role -ne 'operator' } | ForEach-Object { [long]$_.UserId }) }
        'operators' { return @($users | Where-Object { [string]$_.Role -eq 'operator' } | ForEach-Object { [long]$_.UserId }) }
        default { return @($users | ForEach-Object { [long]$_.UserId }) }
    }
}

function Test-AnnouncementRead {
    param([Parameter(Mandatory)]$Announcement, [Parameter(Mandatory)][long]$UserId)
    $acks = Get-JsonProp $Announcement 'AckBy'
    if (-not $acks) { return $false }
    return -not [string]::IsNullOrWhiteSpace([string](Get-JsonProp $acks ([string]$UserId)))
}

function Get-AnnouncementReadCount {
    param([Parameter(Mandatory)]$Announcement)
    $acks = Get-JsonProp $Announcement 'AckBy'
    if (-not $acks) { return 0 }
    return @($acks.PSObject.Properties).Count
}

function Get-AnnouncementKeyboard {
    param([Parameter(Mandatory)]$Announcement)
    if (-not [bool](Get-JsonProp $Announcement 'RequireAck')) { return $null }
    return @{ inline_keyboard = @(, @( (New-Button (T 'ann.seen') "annack:$([string](Get-JsonProp $Announcement 'Id'))" -Style success) )) }
}

function Format-AnnouncementMessage {
    <# The author's text is the whole message. It was written by an
       administrator, not by the bridge, so it is escaped like any other text
       the bridge did not compose. #>
    param([Parameter(Mandatory)]$Announcement)
    $lines = @((T 'ann.noticeTitle'), '', (ConvertTo-TelegramHtmlText -Text ([string](Get-JsonProp $Announcement 'Text'))))
    $by = [long](Get-JsonProp $Announcement 'CreatedBy')
    if ($by -gt 0) { $lines += @('', (T 'ann.from' $(ConvertTo-TelegramHtmlText -Text (Get-UserDisplayName -UserId $by)))) }
    return ($lines -join "`n")
}

function Send-BridgeAnnouncement {
    <#
        Sends one notice to whoever has not read it yet.

        Never to the author: they wrote it. Never to somebody who has already
        pressed "read", which is the whole point of asking for the press - a
        repeating notice that keeps arriving after you have acted on it is one
        people learn to dismiss unread, and the next one might matter.
    #>
    param([Parameter(Mandatory)]$Announcement, [datetime]$Now = (Get-Date))
    $requireAck = [bool](Get-JsonProp $Announcement 'RequireAck')
    $author = [long](Get-JsonProp $Announcement 'CreatedBy')
    $markup = Get-AnnouncementKeyboard -Announcement $Announcement
    $text = Format-AnnouncementMessage -Announcement $Announcement
    $sent = 0
    foreach ($userId in @(Get-AnnouncementAudience -Announcement $Announcement)) {
        if ($userId -eq $author) { continue }
        if ($requireAck -and (Test-AnnouncementRead -Announcement $Announcement -UserId $userId)) { continue }
        if (Send-TelegramMessage -ChatId $userId -Text $text -ParseMode HTML -ReplyMarkup $markup) { $sent++ }
    }
    $Announcement | Add-Member -NotePropertyName LastSentAt -NotePropertyValue $Now.ToString('o') -Force
    return $sent
}

function New-BridgeAnnouncement {
    <# One notice, bounded on every axis the author can choose. #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][long]$CreatedBy,
        [ValidateSet('all', 'operators', 'admins', 'user')][string]$Scope = 'all',
        [long]$TargetUserId = 0,
        [int]$ExpiryHours = 0,
        [int]$RepeatHours = 0,
        [bool]$RequireAck = $true,
        [bool]$Pinned = $false,
        [datetime]$Now = (Get-Date)
    )
    $clean = ([string]$Text -replace '[\r\n]{3,}', "`n`n").Trim()
    $limit = [math]::Max(20, (Get-SettingInt 'AnnouncementMaxLength' 500))
    if ($clean.Length -gt $limit) { $clean = $clean.Substring(0, $limit) }
    if ($ExpiryHours -le 0) { $ExpiryHours = Get-SettingInt 'AnnouncementDefaultExpiryHours' 24 }
    $announcement = [pscustomobject]@{
        Id           = "ann-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        Text         = $clean
        Scope        = $Scope
        TargetUserId = $TargetUserId
        CreatedAt    = $Now.ToString('o')
        CreatedBy    = $CreatedBy
        RepeatHours  = [math]::Max(0, $RepeatHours)
        ExpiresAt    = $Now.AddHours([math]::Max(1, $ExpiryHours)).ToString('o')
        RequireAck   = $RequireAck
        Pinned       = $Pinned
        LastSentAt   = ''
        AckBy        = [pscustomobject]@{}
        Status       = 'active'
    }
    $script:Announcements.Add($announcement)
    # Finished notices are history, not state: expired and cancelled ones were
    # kept for ever, and every acknowledgement rewrote the whole list. The live
    # ones are always kept; the rest are trimmed oldest-first to the cap.
    Remove-StaleAnnouncements
    Save-BridgeAnnouncements | Out-Null
    return $announcement
}

function Remove-StaleAnnouncements {
    <# Keeps every announcement that can still be shown, and at most
       $script:AnnouncementHistoryMax of the finished ones behind them. #>
    param([datetime]$Now = (Get-Date))
    $live = @($script:Announcements | Where-Object { Test-AnnouncementLive -Announcement $_ -Now $Now })
    $done = @($script:Announcements | Where-Object { -not (Test-AnnouncementLive -Announcement $_ -Now $Now) })
    if ($done.Count -le $script:AnnouncementHistoryMax) { return 0 }
    $keep = @($done | Select-Object -Last $script:AnnouncementHistoryMax)
    $dropped = $done.Count - $keep.Count
    $script:Announcements.Clear()
    foreach ($entry in @($live + $keep)) { $script:Announcements.Add($entry) }
    Write-BridgeLog "Trimmed $dropped finished announcement(s) past the $($script:AnnouncementHistoryMax) kept."
    return $dropped
}

function Confirm-AnnouncementRead {
    param([Parameter(Mandatory)][string]$AnnouncementId, [Parameter(Mandatory)][long]$UserId, [datetime]$Now = (Get-Date))
    $found = @($script:Announcements | Where-Object { [string](Get-JsonProp $_ 'Id') -eq $AnnouncementId } | Select-Object -First 1)
    if ($found.Count -eq 0) { return $false }
    $acks = Get-JsonProp $found[0] 'AckBy'
    if (-not $acks) {
        $acks = [pscustomobject]@{}
        $found[0] | Add-Member -NotePropertyName AckBy -NotePropertyValue $acks -Force
    }
    $acks | Add-Member -NotePropertyName ([string]$UserId) -NotePropertyValue $Now.ToString('o') -Force
    Save-BridgeAnnouncements | Out-Null
    return $true
}

function Stop-BridgeAnnouncement {
    param([Parameter(Mandatory)][string]$AnnouncementId, [long]$UserId = 0)
    $found = @($script:Announcements | Where-Object { [string](Get-JsonProp $_ 'Id') -eq $AnnouncementId } | Select-Object -First 1)
    if ($found.Count -eq 0) { return $false }
    $found[0] | Add-Member -NotePropertyName Status -NotePropertyValue 'cancelled' -Force
    Write-BridgeLog "Announcement $AnnouncementId cancelled by $UserId"
    Add-AuditEntry (T 'ann.stoppedAudit' $AnnouncementId $(Format-UserAuditActor -UserId $UserId))
    return (Save-BridgeAnnouncements)
}

function Update-AnnouncementQueue {
    <#
        Repeats a notice to whoever still has not read it, and retires the ones
        whose time is up. Called from the tick.

        Repetition is deliberately coarse - hours, never minutes - because this
        interrupts people who are working, and a notice that nags is one that
        trains them to dismiss the next unread.
    #>
    param([datetime]$Now = (Get-Date), [switch]$Force)
    if (-not (Get-Setting 'EnableAnnouncements')) { return 0 }
    if (-not $Force -and $script:LastAnnouncementSweep -and ($Now - $script:LastAnnouncementSweep).TotalMinutes -lt 5) { return 0 }
    $script:LastAnnouncementSweep = $Now
    $repeated = 0
    $dirty = $false
    foreach ($announcement in @($script:Announcements)) {
        if (-not (Test-AnnouncementLive -Announcement $announcement -Now $Now)) {
            # Retired in place rather than deleted, so the screen can still say
            # what was sent and who read it.
            if ([string](Get-JsonProp $announcement 'Status') -eq 'active') {
                $announcement | Add-Member -NotePropertyName Status -NotePropertyValue 'expired' -Force
                $dirty = $true
            }
            continue
        }
        $every = [int](Get-JsonProp $announcement 'RepeatHours')
        if ($every -le 0) { continue }
        $at = [datetime]::MinValue
        if ([datetime]::TryParse([string](Get-JsonProp $announcement 'LastSentAt'), [ref]$at) -and
            ($Now - $at).TotalHours -lt $every) { continue }
        # Quiet hours hold a repeat back rather than dropping it: the notice is
        # still live, so the first sweep after the quiet window sends it.
        if (Test-QuietHoursActive) { continue }
        $repeated += Send-BridgeAnnouncement -Announcement $announcement -Now $Now
        $dirty = $true
    }
    if ($dirty) { Save-BridgeAnnouncements | Out-Null }
    return $repeated
}

function Get-AnnouncementsText {
    param([int]$Page = 0, [ValidateRange(1, 20)][int]$PageSize = 8, [datetime]$Now = (Get-Date))
    $all = @($script:Announcements | Sort-Object { [datetime](Get-JsonProp $_ 'CreatedAt') } -Descending)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'ann.screen'))
    if ($all.Count -eq 0) {
        $lines.Add((T 'ann.none'))
        return ($lines -join "`n")
    }
    $window = Get-BridgePageWindow -ItemCount $all.Count -Page $Page -PageSize $PageSize
    $tally = (T 'ann.countLine' $($all.Count) $(@(Get-ActiveAnnouncements -Now $Now).Count))
    if ($window.PageCount -gt 1) { $tally += (T 'ann.page' $($window.Page + 1) $($window.PageCount)) }
    $lines.Add("<i>$tally</i>")
    $lines.Add('')
    foreach ($index in $window.StartIndex..$window.EndIndex) {
        $announcement = $all[$index]
        $text = ([string](Get-JsonProp $announcement 'Text') -replace '[\r\n]+', ' ').Trim()
        if ($text.Length -gt 60) { $text = $text.Substring(0, 59) + '…' }
        $state = switch ([string](Get-JsonProp $announcement 'Status')) {
            'active' { if (Test-AnnouncementLive -Announcement $announcement -Now $Now) { (T 'ann.active') } else { (T 'ann.expired') } }
            'cancelled' { (T 'ann.stopped') }
            default { (T 'ann.expired') }
        }
        $lines.Add("$($index + 1). <b>$(ConvertTo-TelegramHtmlText -Text $text)</b>")
        $detail = (T 'ann.row' $state $(Get-AnnouncementScopeLabel -Announcement $announcement) $(Get-AnnouncementReadCount -Announcement $announcement))
        $every = [int](Get-JsonProp $announcement 'RepeatHours')
        if ($every -gt 0) { $detail += (T 'ann.repeatsEvery' $every) }
        if ([bool](Get-JsonProp $announcement 'Pinned')) { $detail += (T 'ann.pinned') }
        $lines.Add($detail)
    }
    return ($lines -join "`n")
}

function Get-AnnouncementsKeyboard {
    param([int]$Page = 0, [ValidateRange(1, 20)][int]$PageSize = 8, [datetime]$Now = (Get-Date))
    $all = @($script:Announcements | Sort-Object { [datetime](Get-JsonProp $_ 'CreatedAt') } -Descending)
    $window = Get-BridgePageWindow -ItemCount $all.Count -Page $Page -PageSize $PageSize
    $rows = @()
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $announcement = $all[$index]
            if (-not (Test-AnnouncementLive -Announcement $announcement -Now $Now)) { continue }
            $text = ([string](Get-JsonProp $announcement 'Text') -replace '[\r\n]+', ' ').Trim()
            if ($text.Length -gt 24) { $text = $text.Substring(0, 23) + '…' }
            $rows += , @( (New-Button (T 'ann.stopButton' $text) "anncancel:$([string](Get-JsonProp $announcement 'Id'))" -Style danger) )
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'common.previous') "annpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "annpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'common.next') "annpage:$($window.Page + 1)") }
        $rows += , $pager
    }
    $rows += , @( (New-Button (T 'ann.new') 'ann:new' -Style success) )
    $rows += , @( (New-Button (T 'ann.adminTools') 'menu:admintools'), (New-Button (T 'common.home') 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Show-AnnouncementsScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-AnnouncementsText -Page $Page) -ParseMode HTML `
        -ReplyMarkup (Get-AnnouncementsKeyboard -Page $Page)
}

function Start-AnnouncementCompose {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'announcement_text'; UserId = $UserId } | Out-Null
    Send-TelegramMessage -ChatId $ChatId -ParseMode HTML -ReplyMarkup (Get-CancelKeyboard) -Text (T 'ann.newScreen' $(Get-SettingInt 'AnnouncementMaxLength' 500))
}

function Complete-AnnouncementText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'announcement_text') { return $false }
    $clean = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'ann.emptyText') -ReplyMarkup (Get-CancelKeyboard)
        return $false
    }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'announcement_options'; UserId = [long]$state.UserId; Text = $clean
        Scope = 'all'; ExpiryHours = 0; RepeatHours = 0; RequireAck = $true; Pinned = $false
    } | Out-Null
    Show-AnnouncementOptionsScreen -ChatId $ChatId
    return $true
}

function Get-AnnouncementOptionsKeyboard {
    <# Every display choice on one screen, each button showing the value it
       currently holds - so the notice that goes out is the one the screen
       says will go out. #>
    param([Parameter(Mandatory)]$State)
    $scope = switch ([string]$State.Scope) {
        'admins' { (T 'ann.admins') }
        'operators' { (T 'ann.operators') }
        default { (T 'ann.everyone') }
    }
    $expiry = [int]$State.ExpiryHours
    $expiryLabel = if ($expiry -le 0) { (T 'ann.hours' $(Get-SettingInt 'AnnouncementDefaultExpiryHours' 24)) } else { (T 'ann.hours' $expiry) }
    $repeat = [int]$State.RepeatHours
    $repeatLabel = if ($repeat -le 0) { (T 'sch.once') } else { (T 'ann.everyHours' $repeat) }
    return @{ inline_keyboard = @(
            , @( (New-Button (T 'ann.recipients' $scope) 'annopt:scope') )
            , @( (New-Button (T 'ann.duration' $expiryLabel) 'annopt:expiry'), (New-Button (T 'ann.repeat' $repeatLabel) 'annopt:repeat') )
            , @( (New-Button (T 'ann.seenButtonToggle' $(if ([bool]$State.RequireAck) { '✅' } else { '⬜' })) 'annopt:ack'),
                (New-Button (T 'ann.pinToggle' $(if ([bool]$State.Pinned) { '📌' } else { '⬜' })) 'annopt:pin') )
            , @( (New-Button (T 'ann.sendNow') 'annopt:send' -Style success), (New-Button (T 'common.cancel') 'cancel') )
        ) }
}

function Show-AnnouncementOptionsScreen {
    param([Parameter(Mandatory)][long]$ChatId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'announcement_options') { return }
    $preview = ([string]$state.Text -replace '[\r\n]+', ' ').Trim()
    if ($preview.Length -gt 200) { $preview = $preview.Substring(0, 199) + '…' }
    $audience = @(Get-AnnouncementAudience -Announcement ([pscustomobject]@{ Scope = [string]$state.Scope; TargetUserId = 0 })).Count
    Send-TelegramMessage -ChatId $ChatId -ParseMode HTML -ReplyMarkup (Get-AnnouncementOptionsKeyboard -State $state) -Text (T 'ann.review' $(ConvertTo-TelegramHtmlText -Text $preview) $audience)
}

function Switch-AnnouncementOption {
    <# One tap cycles one choice, and the screen is redrawn showing it. #>
    param([Parameter(Mandatory)][string]$Option, [Parameter(Mandatory)][long]$ChatId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'announcement_options') { return $false }
    switch ($Option) {
        'scope' { $state.Scope = switch ([string]$state.Scope) { 'all' { 'operators' } 'operators' { 'admins' } default { 'all' } } }
        'expiry' { $state.ExpiryHours = switch ([int]$state.ExpiryHours) { 0 { 1 } 1 { 6 } 6 { 24 } 24 { 72 } default { 0 } } }
        'repeat' { $state.RepeatHours = switch ([int]$state.RepeatHours) { 0 { 1 } 1 { 3 } 3 { 6 } 6 { 12 } default { 0 } } }
        'ack' { $state.RequireAck = -not [bool]$state.RequireAck }
        'pin' { $state.Pinned = -not [bool]$state.Pinned }
        default { return $false }
    }
    Set-PendingState -ChatId $ChatId -State $state | Out-Null
    Show-AnnouncementOptionsScreen -ChatId $ChatId
    return $true
}

function Complete-AnnouncementSend {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'announcement_options') { return $false }
    if ($UserId -eq 0) { $UserId = [long]$state.UserId }
    Clear-PendingState -ChatId $ChatId
    $announcement = New-BridgeAnnouncement -Text ([string]$state.Text) -CreatedBy $UserId -Scope ([string]$state.Scope) `
        -ExpiryHours ([int]$state.ExpiryHours) -RepeatHours ([int]$state.RepeatHours) `
        -RequireAck ([bool]$state.RequireAck) -Pinned ([bool]$state.Pinned)
    $sent = Send-BridgeAnnouncement -Announcement $announcement
    Save-BridgeAnnouncements | Out-Null
    Write-BridgeLog "Announcement $($announcement.Id) sent to $sent recipient(s) by $UserId"
    Add-AuditEntry (T 'ann.sentAudit' $(Get-AnnouncementScopeLabel -Announcement $announcement) $sent $(Format-UserAuditActor -UserId $UserId))
    Send-TelegramMessage -ChatId $ChatId -Text (T 'ann.delivered' $sent) -ReplyMarkup (Get-AnnouncementsKeyboard)
    return $true
}
