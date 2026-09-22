#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    The screens: the bulletin and its table, the library, the row prompts,
    and the schedule queue that starts a run without anyone present.

    Split out of Bridge.Mojaz.ps1, which had grown to 2733 lines - three times
    the size this repository asks a file to stay under, and past the point
    where the file's own table of contents fits on a screen. Nothing moved
    between scopes: dot-sourced parts share one, so this is the same text in
    four places instead of one.
#>

function Test-MojazOnAir {
    <# Is this the bulletin currently playing? Asked by every screen, so the
       comparison lives in one place. #>
    param($Bulletin)
    if (-not $script:MojazPlayback -or -not $Bulletin) { return $false }
    return ([string]$script:MojazPlayback.BulletinId -eq [string]$Bulletin.Id)
}

# --------------------------------------------------------------- one bulletin

function Get-MojazBlocks {
    <# The table the operator asked for: a row per story, four columns, with
       the copy itself trimmed to fit beside them. #>
    param($Bulletin)
    $name = if ($Bulletin) { [string]$Bulletin.Name } else { (T 'mojaz.word') }
    $rows = @(if ($Bulletin) { @(Get-JsonProp $Bulletin 'Rows') })
    $blocks = @(@{ type = 'heading'; text = "📑 $name"; size = 3 })
    if ($rows.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = (T 'mojaz.emptyAddRow') }
        return $blocks
    }
    $blocks += @{ type = 'paragraph'; text = "$($rows.Count) صفًّا · $(Get-MojazPlanText -Bulletin $Bulletin)" }
    $cells = @(, @(
            @{ text = '#'; is_header = $true }
            @{ text = '🖼'; is_header = $true }
            @{ text = (T 'mojaz.col.title'); is_header = $true }
            @{ text = (T 'mojaz.col.story'); is_header = $true }
        ))
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $cells += , @(
            @{ text = [string]($i + 1) }
            @{ text = (Get-MojazImageMark -Row $rows[$i] -Index $i) }
            @{ text = (Format-MojazCell -Text ([string]$rows[$i].Title) -Limit 24) }
            @{ text = (Format-MojazCell -Text ([string]$rows[$i].Text) -Limit 60) }
        )
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $blocks += @{ type = 'paragraph'; text = (T 'mojaz.imageLegend') }
    if (Test-MojazOnAir -Bulletin $Bulletin) {
        $blocks += @{ type = 'paragraph'; text = "▶️ يعمل الآن: الصف $([int]$script:MojazPlayback.Index + 1) من $(@($script:MojazPlayback.Rows).Count)" }
    }
    $waiting = Get-MojazBulletinScheduleText -BulletinId ([string]$Bulletin.Id)
    if ($waiting) { $blocks += @{ type = 'paragraph'; text = $waiting } }
    return $blocks
}

function Get-MojazText {
    <# The same table as text, for a Telegram that refuses rich blocks. #>
    param($Bulletin)
    $name = if ($Bulletin) { [string]$Bulletin.Name } else { (T 'mojaz.word') }
    $rows = @(if ($Bulletin) { @(Get-JsonProp $Bulletin 'Rows') })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>📑 $(ConvertTo-TelegramHtmlText -Text $name)</b>")
    if ($rows.Count -eq 0) {
        $lines.Add((T 'mojaz.emptyAddRowHtml'))
        return ($lines -join "`n")
    }
    $lines.Add("<i>$($rows.Count) صفًّا · $(ConvertTo-TelegramHtmlText -Text (Get-MojazPlanText -Bulletin $Bulletin))</i>")
    $lines.Add('')
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $picture = Get-MojazImageLabel -Row $rows[$i] -Index $i
        $lines.Add("$($i + 1). <b>$(ConvertTo-TelegramHtmlText -Text (Format-MojazCell -Text ([string]$rows[$i].Title) -Limit 40))</b> · $picture")
        $lines.Add("   $(ConvertTo-TelegramHtmlText -Text (Format-MojazCell -Text ([string]$rows[$i].Text) -Limit 90))")
    }
    if (Test-MojazOnAir -Bulletin $Bulletin) {
        $lines.Add('')
        $lines.Add("▶️ يعمل الآن: الصف $([int]$script:MojazPlayback.Index + 1) من $(@($script:MojazPlayback.Rows).Count)")
    }
    $waiting = Get-MojazBulletinScheduleText -BulletinId ([string]$Bulletin.Id)
    if ($waiting) {
        $lines.Add('')
        $lines.Add("<b>$(ConvertTo-TelegramHtmlText -Text $waiting)</b>")
    }
    return ($lines -join "`n")
}

function Get-MojazRowPage {
    <#
        Which page of the rundown a row sits on, so a screen redrawn after an
        edit opens where the operator was standing.

        Every row-scoped action - move, delete, add, edit - redrew the bulletin
        at page zero, which was invisible while the screen was one page and
        became a lost place the moment it was paged: moving row forty threw the
        view back to row one, every time. Derived from the row id rather than
        remembered per chat, because the position is already in the data and a
        remembered one would go stale the moment somebody else reordered.

        Falls back to the last page when the row is gone - a delete leaves the
        operator beside what it removed, not at the top of a long table.
    #>
    param([AllowEmptyCollection()]$Rows, [string]$RowId, [int]$PageSize = 25, [int]$FallbackIndex = -1)
    $list = @($Rows)
    $index = -1
    if (-not [string]::IsNullOrWhiteSpace($RowId)) {
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ([string]$list[$i].Id -eq $RowId) { $index = $i; break }
        }
    }
    if ($index -lt 0) { $index = $FallbackIndex }
    if ($index -lt 0 -or $list.Count -eq 0 -or $PageSize -le 0) { return 0 }
    if ($index -ge $list.Count) { $index = $list.Count - 1 }
    return [int][math]::Floor($index / $PageSize)
}

function Get-MojazKeyboard {
    param($Bulletin, [int]$Page = 0)
    $rows = @(if ($Bulletin) { @(Get-JsonProp $Bulletin 'Rows') })
    $keyboard = @()
    if (Test-MojazOnAir -Bulletin $Bulletin) {
        $keyboard += , @((New-Button (T 'mojaz.stopExit') 'mojaz:stop' -Style danger))
    }
    elseif ($rows.Count -gt 0) {
        $keyboard += , @(
            (New-Button "▶️ تشغيل ($($rows.Count) صفًّا)" 'mojaz:play' -Style success)
            (New-Button (T 'mojaz.runLater') 'mojaz:later')
        )
    }
    $keyboard += , @(
        (New-Button (T 'mojaz.addRow') 'mojaz:add')
        (New-Button "⏱ المدة: $(Get-MojazDelayFrames -Bulletin $Bulletin) إطار" 'mojaz:delay')
    )
    $keyboard += , @(
        (New-Button "⏩ الأول: +$(Get-MojazIntroFrames -Bulletin $Bulletin) إطار" 'mojaz:intro')
        (New-Button "⏹ الأخير: $(Get-MojazLastRowFrames -Bulletin $Bulletin) إطار" 'mojaz:last')
    )
    $keyboard += , @(
        (New-Button "🎬 مزامنة الظهور: $(if (Test-MojazSyncToLoop -Bulletin $Bulletin) { (T 'mjz.paceFromLoop') } else { (T 'mjz.paceFromDuration') })" 'mojaz:sync')
    )
    # T-12: a warning that already computed the fix should not make the
    # operator retype it. Shown only beside the warning it answers - silent
    # exactly when Get-MojazBulletinLoopFitNote is silent.
    $fitNote = Get-MojazBulletinLoopFitNote -Bulletin $Bulletin
    if ($fitNote) {
        $loopFrames = [int](Get-JsonProp (Get-MojazSceneTiming) 'LoopFrames')
        $keyboard += , @((New-Button "⚡ اجعلها $loopFrames إطارًا" 'mojaz:matchloop' -Style success))
    }
    # A line per row: delete it, or move it up or down the rundown. Numbered
    # like the table above, so the button and the story line up by eye.
    # Twenty-five to a page. A bulletin that long is already past what a
    # phone can work with, so every real one renders exactly as before - the
    # pager row appears only when there is a second page. The numbers stay
    # the rundown's own, not the page's, so button 26 is story 26.
    $rowWindow = Get-BridgePageWindow -ItemCount $rows.Count -Page $Page -PageSize 25
    $rowStart = if ($rowWindow.EndIndex -ge $rowWindow.StartIndex) { [int]$rowWindow.StartIndex } else { 0 }
    $rowEnd = if ($rowWindow.EndIndex -ge $rowWindow.StartIndex) { [int]$rowWindow.EndIndex } else { -1 }
    for ($i = $rowStart; $i -le $rowEnd; $i++) {
        $rowId = [string]$rows[$i].Id
        $line = @(
            (New-Button "✏️ $($i + 1)" "mojaz:row:$rowId")
            (New-Button '🗑' "mojaz:del:$rowId" -Style danger)
        )
        if ($i -gt 0) { $line += (New-Button '⬆️' "mojaz:up:$rowId") }
        if ($i -lt ($rows.Count - 1)) { $line += (New-Button '⬇️' "mojaz:down:$rowId") }
        $keyboard += , $line
    }
    $rowPager = @(Get-BridgePagerButtons -Window $rowWindow -Prefix 'mojazpage')
    if ($rowPager.Count -gt 0) { $keyboard += , $rowPager }
    if ($rows.Count -gt 0) { $keyboard += , @((New-Button (T 'mojaz.clearTable') 'mojaz:clear' -Style danger)) }
    $keyboard += , @(
        (New-Button (T 'mojaz.rename') 'mojaz:rename')
        (New-Button (T 'mojaz.duplicate') 'mojaz:copy')
        (New-Button (T 'mojaz.delete') 'mojaz:drop' -Style danger)
    )
    if ($rows.Count -gt 0) {
        # The table is an index, four columns that fit a phone; this is where
        # the copy can actually be read back before it goes out.
        $keyboard += , @((New-Button (T 'mojaz.previewFull') 'mojaz:preview'))
    }
    $keyboard += , @(
        (New-Button (T 'mojaz.schedules') 'mojaz:times')
        (New-Button (T 'mojaz.refresh') 'mojaz:refresh')
        (New-Button (T 'mojaz.backToLibrary') 'mojaz:back')
    )
    return @{ inline_keyboard = $keyboard }
}

function Get-MojazPreviewText {
    <#
        Every row in full, for reading rather than scanning.

        The table on the bulletin screen trims a title to 24 characters and a
        story to 60, which is what makes it a table - four columns that line
        up on a phone. But it was also the only place the copy appeared, so an
        editor could not read back what they had written to check it. These
        are the same rows with nothing cut.
    #>
    param($Bulletin)
    if (-not $Bulletin) { return '' }
    $rows = @(Get-JsonProp $Bulletin 'Rows')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>👁 معاينة «$(ConvertTo-TelegramHtmlText -Text ([string]$Bulletin.Name))»</b>")
    if ($rows.Count -eq 0) {
        $lines.Add((T 'mojaz.emptyHtml'))
        return ($lines -join "`n")
    }
    $effective = @(Get-MojazEffectiveImages -Rows $rows -TemplateImage (Get-MojazTemplateImage))
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $lines.Add('')
        $lines.Add("<b>$($i + 1) · $(ConvertTo-TelegramHtmlText -Text (Get-MojazImageLabel -Row $rows[$i] -Index $i))</b>")
        $lines.Add("📝 <b>$(ConvertTo-TelegramHtmlText -Text ([string]$rows[$i].Title))</b>")
        $lines.Add("📰 $(ConvertTo-TelegramHtmlText -Text ([string]$rows[$i].Text))")
        if ($effective.Count -gt $i -and $effective[$i]) {
            $lines.Add("🖼 $(ConvertTo-TelegramHtmlText -Text (Split-Path -Path $effective[$i] -Leaf))")
        }
    }
    $lines.Add('')
    $lines.Add("<i>$(ConvertTo-TelegramHtmlText -Text (Get-MojazPlanText -Bulletin $Bulletin))</i>")
    return ($lines -join "`n")
}

function Show-MojazPreviewScreen {
    <# Paged rather than sent whole: ten rows of four hundred characters is
       past what Telegram takes in one message, and a bulletin that long is
       exactly the one worth reading before it goes out. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    Send-TelegramPagedText -ChatId $ChatId -Text (Get-MojazPreviewText -Bulletin $bulletin) -ParseMode HTML `
        -ReplyMarkup @{ inline_keyboard = @(, @((New-Button (T 'mojaz.backToTable') 'mojaz:refresh'))) }
}

function Show-MojazScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0, [string]$FocusRowId = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-MojazAvailable)) {
        Send-TelegramMessage -ChatId $ChatId -Text "قالب '$($script:MojazTemplateKey)' غير موجود في سجل القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    # The bulletin this chat had open can be gone - deleted from another chat.
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    # A row-scoped caller names the row it just touched and the screen finds
    # its page; everything else keeps asking for page zero as before.
    if (-not [string]::IsNullOrWhiteSpace($FocusRowId)) {
        $Page = Get-MojazRowPage -Rows @(Get-JsonProp $bulletin 'Rows') -RowId $FocusRowId
    }
    $keyboard = Get-MojazKeyboard -Bulletin $bulletin -Page $Page
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-MojazBlocks -Bulletin $bulletin) -ReplyMarkup $keyboard) { return }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazText -Bulletin $bulletin) -ParseMode HTML -ReplyMarkup $keyboard
}

# ---------------------------------------------------------------- the library

function Get-MojazLibraryBlocks {
    <# The saved bulletins as a table: rows, revision, what is scheduled, and
       whether one is on air right now - four facts the text has to run
       together on a second line under each name. #>
    $saved = @(Get-JsonProp $script:MojazLibrary 'Bulletins')
    # Nothing prunes the library, so this table grows for as long as the
    # station keeps making bulletins - the one screen here whose row count
    # only ever rises.
    $trimmed = Select-RichTableRows -Items $saved
    $bulletins = @($trimmed.Rows)
    $blocks = @(@{ type = 'heading'; text = "📑 الموجزات المحفوظة ($($saved.Count))"; size = 3 })
    if ($saved.Count -eq 0) {
        return $blocks + @(@{ type = 'paragraph'; text = (T 'mojaz.noneSaved') })
    }
    $cells = @(, @(
            @{ text = (T 'mojaz.word'); is_header = $true }
            @{ text = (T 'mojaz.col.rows'); is_header = $true }
            @{ text = (T 'mojaz.col.review'); is_header = $true }
            @{ text = (T 'mojaz.col.state'); is_header = $true }
        ))
    foreach ($bulletin in $bulletins) {
        $upcoming = @(Get-MojazBulletinSchedules -BulletinId ([string]$bulletin.Id)).Count
        $state = if (Test-MojazOnAir -Bulletin $bulletin) { (T 'mojaz.onAir') }
        elseif ($upcoming -gt 0) { "🕒 $upcoming موعدًا" }
        else { '—' }
        $cells += , @(
            @{ text = [string]$bulletin.Name }
            @{ text = [string]@(Get-JsonProp $bulletin 'Rows').Count }
            @{ text = [string][int]$bulletin.Revision }
            @{ text = $state }
        )
    }
    $blocks += @{ type = 'table'; cells = $cells }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown $bulletins.Count
    if ($note) { $blocks += @{ type = 'paragraph'; text = $note } }
    return $blocks
}

function Get-MojazLibraryText {
    $bulletins = @(Get-JsonProp $script:MojazLibrary 'Bulletins')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'mojaz.libraryTitle'))
    if ($bulletins.Count -eq 0) {
        $lines.Add((T 'mojaz.noneSavedHtml'))
        return ($lines -join "`n")
    }
    $lines.Add("<i>$($bulletins.Count) موجزًا · كل تشغيل يستخدم آخر تحديث محفوظ</i>")
    $lines.Add('')
    for ($index = 0; $index -lt $bulletins.Count; $index++) {
        $bulletin = $bulletins[$index]
        $upcoming = @(Get-MojazBulletinSchedules -BulletinId ([string]$bulletin.Id)).Count
        $lines.Add("$($index + 1). <b>$(ConvertTo-TelegramHtmlText -Text ([string]$bulletin.Name))</b>")
        $detail = "   $(@(Get-JsonProp $bulletin 'Rows').Count) صف · المراجعة $([int]$bulletin.Revision)"
        if ($upcoming -gt 0) { $detail += " · $upcoming موعدًا قادمًا" }
        if (Test-MojazOnAir -Bulletin $bulletin) { $detail += (T 'mojaz.onAirSuffix') }
        $lines.Add($detail)
    }
    return ($lines -join "`n")
}

function Get-MojazLibraryKeyboard {
    <# Paged: a newsroom that keeps its bulletins accumulates them, and a row
       each is eventually more than Telegram will send in one message - so the
       screen would stop opening for exactly the people using it most. #>
    param([int]$Page = 0, [ValidateRange(1, 20)][int]$PageSize = 10)
    $bulletins = @(Get-JsonProp $script:MojazLibrary 'Bulletins')
    $window = Get-BridgePageWindow -ItemCount $bulletins.Count -Page $Page -PageSize $PageSize
    $keyboard = @()
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $bulletin = $bulletins[$index]
            $mark = if (Test-MojazOnAir -Bulletin $bulletin) { '▶️' } else { '📄' }
            $keyboard += , @((New-Button "$mark $([string]$bulletin.Name)" "mojaz:open:$([string]$bulletin.Id)"))
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'mojaz.prev') "mojazpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "mojazpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'mojaz.next') "mojazpage:$($window.Page + 1)") }
        $keyboard += , $pager
    }
    $keyboard += , @((New-Button (T 'mojaz.new') 'mojaz:new' -Style success))
    $keyboard += , @((New-Button (T 'mojaz.schedules') 'mojaz:times'), (New-Button (T 'mojaz.refresh') 'menu:mojaz'), (New-Button (T 'mojaz.home') 'menu:main'))
    return @{ inline_keyboard = $keyboard }
}

function Show-MojazLibraryScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-MojazAvailable)) {
        Send-TelegramMessage -ChatId $ChatId -Text "قالب '$($script:MojazTemplateKey)' غير موجود في سجل القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $script:MojazSelections.Remove([string]$ChatId)
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-MojazLibraryBlocks) -ReplyMarkup (Get-MojazLibraryKeyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazLibraryText) -ParseMode HTML `
        -ReplyMarkup (Get-MojazLibraryKeyboard -Page $Page)
}

function Open-MojazBulletin {
    param([Parameter(Mandatory)][string]$BulletinId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if (-not (Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $BulletinId)) {
        Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId
        return
    }
    $script:MojazSelections[[string]$ChatId] = $BulletinId
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
}

function Start-MojazNamePrompt {
    <# One prompt for the three things that need a name: a new bulletin, a
       rename, and a copy. The mode says which. #>
    param([Parameter(Mandatory)][ValidateSet('new', 'rename', 'copy')][string]$Which,
        [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletinId = Get-MojazSelectedId -ChatId $ChatId
    if ($Which -ne 'new' -and -not $bulletinId) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    # The design comes before the name, because it decides what a row of this
    # bulletin will even be asked for. Only when there is a choice to make:
    # one design is not a choice, and with the option off there is only ever
    # the built-in one.
    if ($Which -eq 'new' -and (Test-MojazDesignChoiceNeeded)) {
        Set-PendingState -ChatId $ChatId -State @{ Mode = 'mojaz_design_new'; UserId = $UserId } | Out-Null
        Show-MojazDesignScreen -ChatId $ChatId -UserId $UserId
        return
    }
    $prompt = switch ($Which) {
        'new' { (T 'mojaz.askNewName') }
        'rename' { (T 'mojaz.askRename') }
        'copy' { (T 'mojaz.askCopyName') }
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = "mojaz_name_$Which"; UserId = $UserId; BulletinId = $bulletinId }
    Send-TelegramMessage -ChatId $ChatId -Text $prompt -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-MojazName {
    param([Parameter(Mandatory)][ValidateSet('new', 'rename', 'copy')][string]$Which,
        [Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne "mojaz_name_$Which") { return }
    $userId = [long]$state.UserId
    $bulletinId = [string](Get-JsonProp $state 'BulletinId')
    $result = switch ($Which) {
        # A new bulletin opens on the newsroom's usual dwell; the ⏱ button
        # changes it for this one without touching the setting.
        'new' {
            # The wizard puts the chosen design in the pending state before
            # asking for the name; with no choice offered this is empty, which
            # is the built-in design.
            Add-MojazBulletin -Library $script:MojazLibrary -Name $Value -DelayFrames (Get-MojazDelayFrames) `
                -TemplateKey ([string](Get-JsonProp $state 'DesignKey')) -UserId $userId
        }
        'rename' { Rename-MojazBulletin -Library $script:MojazLibrary -BulletinId $bulletinId -Name $Value -UserId $userId }
        'copy' { Copy-MojazBulletin -Library $script:MojazLibrary -BulletinId $bulletinId -Name $Value -UserId $userId }
    }
    if (-not $result.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ $([string]$result.Error)" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    if (-not (Save-MojazLibrary -Library $result.Value)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.saveFailed') -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    $actor = Format-UserAuditActor -UserId $userId
    if ($Which -eq 'rename') {
        Add-AuditEntry "📑 إعادة تسمية موجز - بواسطة $actor"
    }
    else {
        # A create and a copy both append, so the new bulletin is the last one.
        $created = @(Get-JsonProp $script:MojazLibrary 'Bulletins')[-1]
        $script:MojazSelections[[string]$ChatId] = [string]$created.Id
        $verb = if ($Which -eq 'new') { (T 'mojaz.actionCreate') } else { (T 'mojaz.actionCopy') }
        Add-AuditEntry "📑 $verb موجز '$([string]$created.Name)' - بواسطة $actor"
    }
    Show-MojazScreen -ChatId $ChatId -UserId $userId
}

function Get-MojazConfirmKeyboard {
    <# The screens that destroy work ask first, and colour only the half that
       destroys - the way every other danger button in the bridge does. #>
    param([Parameter(Mandatory)][string]$Question, [Parameter(Mandatory)][string]$ConfirmData)
    return @{ inline_keyboard = @(, @(
                (New-Button $Question $ConfirmData -Style danger)
                (New-Button (T 'mojaz.undo') 'mojaz:refresh')
            )) }
}

function Remove-MojazBulletinAndSchedules {
    <#
        Deleting a bulletin takes its appointments with it, or takes nothing.

        Two files have to move together. The schedules go first: if that write
        fails nothing has happened yet, and if the library write then fails the
        schedules are put back - so no appointment is ever left pointing at a
        bulletin that no longer exists.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return $false }
    $bulletinId = [string]$bulletin.Id
    if (Test-MojazOnAir -Bulletin $bulletin) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.onAirStopFirst')
        Show-MojazScreen -ChatId $ChatId -UserId $UserId
        return $false
    }
    $removal = Remove-MojazBulletin -Library $script:MojazLibrary -BulletinId $bulletinId
    if (-not $removal.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ $([string]$removal.Error)"
        return $false
    }
    $previousSchedules = @($script:MojazSchedules)
    $keptSchedules = @($previousSchedules | Where-Object { [string](Get-JsonProp $_ 'BulletinId') -ne $bulletinId })
    $cancelled = $previousSchedules.Count - $keptSchedules.Count
    if ($cancelled -gt 0 -and -not (Save-MojazSchedules -Schedules $keptSchedules)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.cancelSchedulesFailed')
        return $false
    }
    if (-not (Save-MojazLibrary -Library $removal.Value)) {
        if ($cancelled -gt 0) { Save-MojazSchedules -Schedules $previousSchedules | Out-Null }
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.deleteFailed')
        return $false
    }
    $note = if ($cancelled -gt 0) { " ومعه $cancelled موعدًا" } else { '' }
    Add-AuditEntry "🗑 حذف موجز '$([string]$bulletin.Name)'$note - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "🗑 حُذف «$([string]$bulletin.Name)»$note."
    Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId
    return $true
}

# --------------------------------------------------------------------- rows

function Get-MojazImageKeyboard {
    <#
        The picture choices, offered the same way whether a row is being
        written or edited: inherit what is already showing, go back to the
        template's own, or take a picture this bulletin already carries
        instead of uploading it a second time.

        Reused pictures are addressed by their position in that list, because
        a callback carries 64 bytes and a path does not fit.
    #>
    param([string]$Cancel = 'mojaz:refresh')
    $keyboard = @(, @(
            (New-Button (T 'mojaz.img.inherit') 'mojaz:img:inherit')
            (New-Button (T 'mojaz.img.template') 'mojaz:img:template')
        ))
    $used = @(Get-MojazUsedImages -Rows @(Get-JsonProp (Get-MojazSelected -ChatId $script:MojazImageChatId) 'Rows'))
    $line = @()
    for ($i = 0; $i -lt $used.Count -and $i -lt 8; $i++) {
        $line += (New-Button "🖼 $(Split-Path -Path $used[$i] -Leaf)" "mojaz:img:use:$i")
        if ($line.Count -eq 2) { $keyboard += , $line; $line = @() }
    }
    if ($line.Count -gt 0) { $keyboard += , $line }
    $keyboard += , @((New-Button (T 'mojaz.cancel') $Cancel))
    return @{ inline_keyboard = $keyboard }
}

function Send-MojazImagePrompt {
    <# One prompt for both flows; the pending mode already says which. #>
    param([Parameter(Mandatory)][long]$ChatId, [string]$Cancel = 'mojaz:refresh')
    $script:MojazImageChatId = $ChatId
    Send-TelegramMessage -ChatId $ChatId -Text (T 'mjz.sendRowPicture') `
        -ReplyMarkup (Get-MojazImageKeyboard -Cancel $Cancel)
}

function Start-MojazRowAdd {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletinId = Get-MojazSelectedId -ChatId $ChatId
    if (-not $bulletinId) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'mojaz_row_image'; UserId = $UserId; BulletinId = $bulletinId; Image = ''; ImageMode = 'inherit'; Title = '' }
    Send-MojazImagePrompt -ChatId $ChatId
}

function Resolve-MojazUsedImage {
    <# The reuse buttons carry a position, not a path. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][int]$Index)
    $used = @(Get-MojazUsedImages -Rows @(Get-JsonProp (Get-MojazSelected -ChatId $ChatId) 'Rows'))
    if ($Index -lt 0 -or $Index -ge $used.Count) { return '' }
    return [string]$used[$Index]
}

function Complete-MojazRowImage {
    <#
        Where every way of naming a picture arrives: a typed path, a photo
        already downloaded by Receive-MojazPhoto, or one of the buttons. The
        pending mode decides whether this is the first step of a new row or an
        edit of one that exists.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '',
        [ValidateSet('new', 'inherit', 'template')][string]$Mode = 'new', [switch]$Skip)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $image = if ($Skip -or $Mode -ne 'new') { '' } else { ([string]$Value).Trim() }
    $imageMode = if ($Skip) { 'inherit' } elseif ($Mode -eq 'new' -and -not $image) { 'inherit' } else { $Mode }
    switch ([string]$state.Mode) {
        'mojaz_row_image' {
            Set-PendingState -ChatId $ChatId -State @{
                Mode = 'mojaz_row_title'; UserId = $state.UserId
                BulletinId = [string](Get-JsonProp $state 'BulletinId')
                Image = $image; ImageMode = $imageMode; Title = ''
            }
            Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.askTitle') -ReplyMarkup (Get-CancelKeyboard)
        }
        'mojaz_edit_image' {
            $userId = [long]$state.UserId
            $rowId = [string](Get-JsonProp $state 'RowId')
            Clear-PendingState -ChatId $ChatId
            $result = Set-MojazBulletinRow -Library $script:MojazLibrary -BulletinId ([string](Get-JsonProp $state 'BulletinId')) `
                -RowId $rowId -Image $image -ImageMode $imageMode -UserId $userId
            Invoke-MojazEdit -Result $result -ChatId $ChatId | Out-Null
            Show-MojazRowScreen -RowId $rowId -ChatId $ChatId -UserId $userId
        }
    }
}

function Get-MojazRowNumber {
    param($Bulletin, [string]$RowId)
    $rows = @(Get-JsonProp $Bulletin 'Rows')
    for ($i = 0; $i -lt $rows.Count; $i++) { if ([string]$rows[$i].Id -eq $RowId) { return ($i + 1) } }
    return 0
}

function Show-MojazRowScreen {
    <# One row on its own, so a typo in the third story is three presses to
       fix instead of deleting it and writing it again. #>
    param([Parameter(Mandatory)][string]$RowId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    $rows = @(Get-JsonProp $bulletin 'Rows')
    $index = (Get-MojazRowNumber -Bulletin $bulletin -RowId $RowId) - 1
    if ($index -lt 0) { Show-MojazScreen -ChatId $ChatId -UserId $UserId; return }
    $row = $rows[$index]
    $lines = @(
        "<b>✏️ الصف $($index + 1) من «$(ConvertTo-TelegramHtmlText -Text ([string]$bulletin.Name))»</b>"
        ''
        "🖼 $(ConvertTo-TelegramHtmlText -Text (Get-MojazImageLabel -Row $row -Index $index))"
        "📝 <b>$(ConvertTo-TelegramHtmlText -Text (Format-MojazCell -Text ([string]$row.Title) -Limit 60))</b>"
        "📰 $(ConvertTo-TelegramHtmlText -Text (Format-MojazCell -Text ([string]$row.Text) -Limit 200))"
    )
    $effective = @(Get-MojazEffectiveImages -Rows $rows -TemplateImage (Get-MojazTemplateImage))
    if ($effective.Count -gt $index -and $effective[$index]) {
        $lines += "<i>ما سيظهر: $(ConvertTo-TelegramHtmlText -Text (Split-Path -Path $effective[$index] -Leaf))</i>"
    }
    # A comma before EVERY row, the way every other keyboard here is written:
    # @() flattens nested arrays, so a row without it is spread into bare
    # buttons and Telegram answers 400.
    $keyboard = @{ inline_keyboard = @(
            , @(
                (New-Button (T 'mojaz.field.image') "mojaz:editimg:$RowId")
                (New-Button (T 'mojaz.field.title') "mojaz:edittitle:$RowId")
                (New-Button (T 'mojaz.field.story') "mojaz:edittext:$RowId")
            )
            , @(
                (New-Button (T 'mojaz.deleteRow') "mojaz:del:$RowId" -Style danger)
                (New-Button (T 'mojaz.backToTable') 'mojaz:refresh')
            )
        ) }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ParseMode HTML -ReplyMarkup $keyboard
}

function Start-MojazRowEdit {
    param([Parameter(Mandatory)][ValidateSet('image', 'title', 'text')][string]$Which,
        [Parameter(Mandatory)][string]$RowId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    $row = @(@(Get-JsonProp $bulletin 'Rows') | Where-Object { [string]$_.Id -eq $RowId }) | Select-Object -First 1
    if (-not $row) { Show-MojazScreen -ChatId $ChatId -UserId $UserId; return }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = "mojaz_edit_$Which"; UserId = $UserId
        BulletinId = [string]$bulletin.Id; RowId = $RowId
    }
    if ($Which -eq 'image') { Send-MojazImagePrompt -ChatId $ChatId -Cancel "mojaz:row:$RowId"; return }
    $current = if ($Which -eq 'title') { [string]$row.Title } else { [string]$row.Text }
    $prompt = if ($Which -eq 'title') { (T 'mojaz.askNewTitle') } else { (T 'mojaz.askNewStory') }
    # The current text used to be prose on the end of a line - readable, but a
    # phone cannot copy it without a careful long press. It is tap-to-copy now.
    Send-BridgeTextEditPrompt -ChatId $ChatId -Prompt $prompt -Current $current -CancelData "mojaz:row:$RowId"
}

function Complete-MojazRowEdit {
    param([Parameter(Mandatory)][ValidateSet('title', 'text')][string]$Which,
        [Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne "mojaz_edit_$Which") { return }
    $value = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        Send-TelegramMessage -ChatId $ChatId -Text $(if ($Which -eq 'title') { (T 'mojaz.titleEmpty') } else { (T 'mojaz.storyEmpty') }) -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $userId = [long]$state.UserId
    $rowId = [string](Get-JsonProp $state 'RowId')
    Clear-PendingState -ChatId $ChatId
    $result = if ($Which -eq 'title') {
        Set-MojazBulletinRow -Library $script:MojazLibrary -BulletinId ([string](Get-JsonProp $state 'BulletinId')) -RowId $rowId -Title $value -UserId $userId
    }
    else {
        Set-MojazBulletinRow -Library $script:MojazLibrary -BulletinId ([string](Get-JsonProp $state 'BulletinId')) -RowId $rowId -Text $value -UserId $userId
    }
    if (Invoke-MojazEdit -Result $result -ChatId $ChatId) {
        Add-AuditEntry "📑 تعديل صف في الموجز - بواسطة $(Format-UserAuditActor -UserId $userId)"
    }
    Show-MojazRowScreen -RowId $rowId -ChatId $ChatId -UserId $userId
}

function Complete-MojazRowTitle {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_row_title') { return }
    $title = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($title)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.titleEmpty') -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'mojaz_row_text'; UserId = $state.UserId
        BulletinId = [string](Get-JsonProp $state 'BulletinId')
        Image = [string]$state.Image; ImageMode = [string](Get-JsonProp $state 'ImageMode'); Title = $title
    }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.askStory') -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-MojazRowText {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_row_text') { return }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.storyEmpty') -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $userId = [long]$state.UserId
    # The row goes to the bulletin this flow started in, not to whatever is
    # selected now: the selection can have moved while the operator typed.
    $bulletinId = [string](Get-JsonProp $state 'BulletinId')
    Clear-PendingState -ChatId $ChatId
    $imageMode = [string](Get-JsonProp $state 'ImageMode')
    if (-not $imageMode) { $imageMode = 'inherit' }
    $result = Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $bulletinId `
        -Image ([string]$state.Image) -ImageMode $imageMode -Title ([string]$state.Title) -Text $text -UserId $userId
    if (Invoke-MojazEdit -Result $result -ChatId $ChatId) {
        Add-AuditEntry "📑 أُضيف صف للموجز - بواسطة $(Format-UserAuditActor -UserId $userId)"
        $script:MojazSelections[[string]$ChatId] = $bulletinId
    }
    # A new row is appended, so the page that holds it is the last one. Adding
    # the forty-first story and being shown the first is the same lost place
    # as a move, one screen over.
    $addedRows = @(Get-JsonProp (Get-MojazSelected -ChatId $ChatId) 'Rows')
    Show-MojazScreen -ChatId $ChatId -UserId $userId -Page (Get-MojazRowPage -Rows $addedRows -RowId '' -FallbackIndex ($addedRows.Count - 1))
}

function Receive-MojazPhoto {
    <#
        A picture sent from the phone, saved beside the scene so Cinegy can
        read it, and handed to the row as the relative path the template's own
        pictures already use.
    #>
    param([Parameter(Mandatory)][string]$FileId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Extension = '.jpg')
    if ($UserId -eq 0) { $UserId = $ChatId }
    $directory = Get-MojazUploadDirectory
    if (-not $directory) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.noImageFolder') -ReplyMarkup (Get-CancelKeyboard)
        return $false
    }
    $safeExtension = if ($Extension -match '^\.[A-Za-z0-9]{1,5}$') { $Extension.ToLowerInvariant() } else { '.jpg' }
    $stem = "mojaz-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    # PNG, like the picture the scene ships with, whatever arrived.
    $name = "$stem.png"
    $destination = Join-Path $directory $name
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "$stem$safeExtension"
    try {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        Receive-TelegramDocument -FileId $FileId -DestinationPath $staging -MaximumBytes (10 * 1024 * 1024) | Out-Null
    }
    catch {
        Write-BridgeLog "Mojaz photo download failed: $(Protect-SensitiveText $_.Exception.Message)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ الصورة: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-CancelKeyboard)
        return $false
    }
    # Only a real picture, and only at the plate's size, reaches the folder
    # Cinegy reads: a file that is not a picture, or is thousands of pixels
    # wide, is a row that shows nothing on air.
    $size = Get-MojazImageSize
    try {
        Convert-MojazPicture -SourcePath $staging -DestinationPath $destination -Size $size | Out-Null
        $measured = if ($size) { "$($size.Width)x$($size.Height)" } else { (T 'mojaz.asIs') }
        Write-BridgeLog "Mojaz picture stored as '$name' ($measured)."
    }
    catch {
        Write-BridgeLog "Mojaz picture rejected: $($_.Exception.Message)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.notAnImage') -ReplyMarkup (Get-CancelKeyboard)
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    }
    # Relative to the scene's root folder, the way the template's own picture
    # paths are written - an absolute path would break if the project moves.
    Complete-MojazRowImage -ChatId $ChatId -Value ".\Mojaz\bot\$name"
    return $true
}

function Remove-MojazRow {
    param([Parameter(Mandatory)][string]$RowId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    # Where the row was, read before it goes, so the redraw lands beside the
    # gap rather than at the top of a long rundown.
    $removedPage = Get-MojazRowPage -Rows @(Get-JsonProp (Get-MojazSelected -ChatId $ChatId) 'Rows') -RowId $RowId
    $result = Remove-MojazBulletinRow -Library $script:MojazLibrary -BulletinId (Get-MojazSelectedId -ChatId $ChatId) -RowId $RowId -UserId $UserId
    Invoke-MojazEdit -Result $result -ChatId $ChatId | Out-Null
    Show-MojazScreen -ChatId $ChatId -UserId $UserId -Page $removedPage
}

function Move-MojazRow {
    param([Parameter(Mandatory)][string]$RowId, [Parameter(Mandatory)][ValidateSet('up', 'down')][string]$Direction,
        [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    $result = Move-MojazBulletinRow -Library $script:MojazLibrary -BulletinId (Get-MojazSelectedId -ChatId $ChatId) -RowId $RowId -Direction $Direction -UserId $UserId
    # Hitting the edge of the table is not worth a message: the screen simply
    # redraws unchanged.
    Invoke-MojazEdit -Result $result -ChatId $ChatId -Quiet | Out-Null
    # Follow the row across a page boundary: a move that pushes it onto the
    # next page must not leave the operator looking at the page it left.
    Show-MojazScreen -ChatId $ChatId -UserId $UserId -FocusRowId $RowId
}

function Clear-MojazRows {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    $result = Clear-MojazBulletinRows -Library $script:MojazLibrary -BulletinId (Get-MojazSelectedId -ChatId $ChatId) -UserId $UserId
    if (Invoke-MojazEdit -Result $result -ChatId $ChatId) {
        Add-AuditEntry "🧹 مسح جدول الموجز - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    }
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
}

# ----------------------------------------------------------- timing prompts

function Start-MojazDelayPrompt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'mojaz_delay'; UserId = $UserId; BulletinId = [string]$bulletin.Id }
    Send-TelegramMessage -ChatId $ChatId `
        -Text "⏱ كم إطارًا يبقى كل صف على الهواء؟`nالحالي: $(Get-MojazDelayFrames -Bulletin $bulletin) إطار ≈ $(Get-MojazDelaySeconds -Bulletin $bulletin) ث · المشهد $(Get-MojazFps) إطارًا في الثانية.$(if ($fit = Get-MojazBulletinLoopFitNote -Bulletin $bulletin) { "`n$fit" })" `
        -ReplyMarkup (Get-CancelKeyboard)
}

function Start-MojazTimingPrompt {
    <# One prompt for both numbers; the mode says which. #>
    param([Parameter(Mandatory)][ValidateSet('intro', 'last')][string]$Which, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    $fps = Get-MojazFps
    $text = if ($Which -eq 'intro') {
        "⏩ كم إطارًا يُضاف إلى الصف الأول وحده (حركة الدخول)؟`nالحالي: $(Get-MojazIntroFrames -Bulletin $bulletin) إطار ≈ $(Get-MojazIntroSeconds -Bulletin $bulletin) ث · المشهد $fps إطارًا في الثانية.`nأرسل 0 لاتّباع القالب."
    }
    else {
        "⏹ كم إطارًا يبقى الصف الأخير قبل أمر الخروج؟`nالحالي: $(Get-MojazLastRowFrames -Bulletin $bulletin) إطار ≈ $(Get-MojazLastRowSeconds -Bulletin $bulletin) ث · المشهد $fps إطارًا في الثانية.`nأرسل 0 لاتّباع القالب."
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = "mojaz_$($Which)_seconds"; UserId = $UserId; BulletinId = [string]$bulletin.Id }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-MojazTiming {
    <# The three numbers a bulletin owns, set the same way: parse it, hand it
       to the module, let the module say whether the range allows it. #>
    param([Parameter(Mandatory)][ValidateSet('delay', 'intro', 'last')][string]$Which,
        [Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $mode = if ($Which -eq 'delay') { 'mojaz_delay' } else { "mojaz_$($Which)_seconds" }
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne $mode) { return }
    $seconds = 0
    if (-not [int]::TryParse((ConvertTo-BridgeLatinDigits -Text ([string]$Value).Trim()), [ref]$seconds)) {
        Send-TelegramMessage -ChatId $ChatId -Text $(if ($Which -eq 'delay') { (T 'mojaz.frames1to15000') } else { (T 'mojaz.frames0to15000') }) -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $bulletinId = [string](Get-JsonProp $state 'BulletinId')
    $userId = [long]$state.UserId
    $result = switch ($Which) {
        'delay' { Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId $bulletinId -DelayFrames $seconds -UserId $userId }
        'intro' { Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId $bulletinId -IntroExtraFrames $seconds -UserId $userId }
        'last' { Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId $bulletinId -LastRowFrames $seconds -UserId $userId }
    }
    if (-not $result.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ $([string]$result.Error)" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    if (-not (Save-MojazLibrary -Library $result.Value)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.saveFailed') -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Show-MojazScreen -ChatId $ChatId -UserId $userId
}

# ------------------------------------------------------------------ schedules

function Switch-MojazSync {
    <# The one button that changes what the bulletin's pace is measured
       against: its own dwell, or the scene's loop. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    $wanted = -not (Test-MojazSyncToLoop -Bulletin $bulletin)
    $result = Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId ([string]$bulletin.Id) -SyncToLoop $wanted -UserId $UserId
    if (Invoke-MojazEdit -Result $result -ChatId $ChatId) {
        Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazSyncText -Bulletin (Get-MojazSelected -ChatId $ChatId)) -ParseMode HTML
    }
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
}

function Set-MojazDelayToLoop {
    <#
        T-12: the loop-fit warning already names the exact number that clears
        it - the loop's own length - and used to leave the operator to retype
        it into the free-text prompt by hand. This is that number, applied
        from the button beside the warning it answers.

        Quiet if there is nothing to fix: no bulletin selected, or no scene
        timing to read a loop length from. Get-MojazBulletinLoopFitNote already
        made that same check before the button was ever shown.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    $timing = Get-MojazSceneTiming
    $loopFrames = if ($timing) { [int](Get-JsonProp $timing 'LoopFrames') } else { 0 }
    if ($loopFrames -gt 0) {
        $result = Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId ([string]$bulletin.Id) -DelayFrames $loopFrames -UserId $UserId
        Invoke-MojazEdit -Result $result -ChatId $ChatId | Out-Null
    }
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
}

function Get-MojazBulletinSchedules {
    <# The appointments still ahead of one bulletin, soonest first. #>
    param([Parameter(Mandatory)][string]$BulletinId)
    return @($script:MojazSchedules | Where-Object {
            [string](Get-JsonProp $_ 'BulletinId') -eq $BulletinId -and
            [string](Get-JsonProp $_ 'Status') -in @('scheduled', 'queued')
        } | Sort-Object { [datetimeoffset](Get-JsonProp $_ 'ScheduledAt') })
}

function Get-MojazBulletinScheduleText {
    <# The wait, said as both the clock time and how long from now - the first
       is what a rundown is written against, the second is what the person
       holding the phone is actually counting. #>
    param([Parameter(Mandatory)][string]$BulletinId)
    $next = @(Get-MojazBulletinSchedules -BulletinId $BulletinId) | Select-Object -First 1
    if (-not $next) { return '' }
    $moment = [datetimeoffset](Get-JsonProp $next 'ScheduledAt')
    if ([string](Get-JsonProp $next 'Status') -eq 'queued') {
        return "⏳ في الانتظار — موعده $($moment.ToString('HH:mm')) مرّ وموجز آخر على الهواء."
    }
    $seconds = [int][math]::Max(0, ($moment - [datetimeoffset]::Now).TotalSeconds)
    return "🕒 يبدأ $($moment.ToString('HH:mm')) — بعد $(Format-DurationSeconds -Seconds $seconds)"
}

function Add-MojazSchedule {
    <# An appointment names the bulletin, not its rows: what plays is whatever
       is saved when the moment arrives. #>
    param(
        [Parameter(Mandatory)][string]$BulletinId,
        [Parameter(Mandatory)][datetimeoffset]$ScheduledAt,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if (-not (Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $BulletinId)) { return $false }
    $schedule = [pscustomobject]@{
        Id = "ms_$([guid]::NewGuid().ToString('N').Substring(0,8))"
        BulletinId = $BulletinId
        ScheduledAt = $ScheduledAt.ToString('o')
        CreatedAt = [datetimeoffset]::Now.ToString('o')
        CreatedBy = $UserId
        ChatId = $ChatId
        Status = 'scheduled'
        DueAt = $null
        StartedAt = $null
        CompletedAt = $null
        DelayReason = ''
        LastError = ''
        NoticedAt = $null
    }
    return (Save-MojazSchedules -Schedules @(@($script:MojazSchedules) + $schedule))
}

function Stop-MojazSchedule {
    param([Parameter(Mandatory)][string]$ScheduleId, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    $kept = @($script:MojazSchedules | Where-Object { [string](Get-JsonProp $_ 'Id') -ne $ScheduleId })
    if ($kept.Count -eq @($script:MojazSchedules).Count) { Show-MojazSchedulesScreen -ChatId $ChatId -UserId $UserId; return }
    if (-not (Save-MojazSchedules -Schedules $kept)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.cancelScheduleFailed')
        return
    }
    Add-AuditEntry "🚫 إلغاء موعد موجز - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-MojazSchedulesScreen -ChatId $ChatId -UserId $UserId
}

function Start-MojazLaterPrompt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'mojaz_start_at'; UserId = $UserId; BulletinId = [string]$bulletin.Id }
    # The same picker the template scheduling offers - the offsets that cover
    # most cues and a calendar for the rest - rather than a second way of
    # asking the same question. Typing still works; the buttons are another
    # way in, not a replacement.
    Send-TelegramMessage -ChatId $ChatId `
        -Text "🕒 متى يبدأ «$([string]$bulletin.Name)»؟`nاختر من الأزرار، أو اكتب: +30 · بعد 90 · 21:45 · غدًا 07:00" `
        -ReplyMarkup (Get-ScheduleTimePromptKeyboard)
}

function Complete-MojazLater {
    <# The same wording the scheduling screen accepts, parsed by the same
       function - one grammar for "when", not two. #>
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_start_at') { return }
    $moment = ConvertFrom-OperatorScheduleTime -Text ([string]$Value)
    if (-not $moment.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ $([string](Get-JsonProp $moment 'Error'))" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Complete-MojazLaterAt -ChatId $ChatId -ScheduledAt ([datetimeoffset]$moment.ScheduledAt) | Out-Null
}

function Complete-MojazLaterAt {
    <# Where a chosen moment becomes an appointment, whether it was typed or
       picked off the calendar. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][datetimeoffset]$ScheduledAt)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_start_at') { return $false }
    $userId = [long]$state.UserId
    $bulletinId = [string](Get-JsonProp $state 'BulletinId')
    if (-not (Add-MojazSchedule -BulletinId $bulletinId -ScheduledAt $ScheduledAt -ChatId $ChatId -UserId $userId)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mojaz.saveScheduleFailed') -ReplyMarkup (Get-CancelKeyboard)
        return $false
    }
    Clear-PendingState -ChatId $ChatId
    Write-BridgeLog "Mojaz playback scheduled for $($ScheduledAt.ToString('yyyy-MM-dd HH:mm')) by $userId"
    Add-AuditEntry "🕒 موعد موجز $($ScheduledAt.ToString('HH:mm')) - بواسطة $(Format-UserAuditActor -UserId $userId)"
    Show-MojazScreen -ChatId $ChatId -UserId $userId
    return $true
}

function Get-MojazSchedulesText {
    $pending = @($script:MojazSchedules | Where-Object { [string](Get-JsonProp $_ 'Status') -in @('scheduled', 'queued', 'running') } |
            Sort-Object { [datetimeoffset](Get-JsonProp $_ 'ScheduledAt') })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'mojaz.schedTitle'))
    if ($pending.Count -eq 0) {
        $lines.Add((T 'mojaz.schedNone'))
        return ($lines -join "`n")
    }
    $lines.Add((T 'mojaz.schedNote'))
    $lines.Add('')
    for ($index = 0; $index -lt $pending.Count; $index++) {
        $entry = $pending[$index]
        $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId ([string](Get-JsonProp $entry 'BulletinId'))
        $name = if ($bulletin) { [string]$bulletin.Name } else { (T 'mojaz.deletedBulletin') }
        $moment = [datetimeoffset](Get-JsonProp $entry 'ScheduledAt')
        $mark = switch ([string](Get-JsonProp $entry 'Status')) {
            'running' { (T 'mojaz.onAir') }
            'queued' { (T 'mojaz.waitingOther') }
            default { (T 'mojaz.scheduled') }
        }
        $lines.Add("$($index + 1). <b>$(ConvertTo-TelegramHtmlText -Text $name)</b> — $($moment.ToString('MM-dd HH:mm'))")
        $lines.Add("   $mark")
    }
    return ($lines -join "`n")
}

function Get-MojazSchedulesKeyboard {
    <# Paged for the same reason as the library: a week of scheduled bulletins
       is a list nobody sized this screen for. #>
    param([int]$Page = 0, [ValidateRange(1, 20)][int]$PageSize = 10)
    $pending = @($script:MojazSchedules | Where-Object { [string](Get-JsonProp $_ 'Status') -in @('scheduled', 'queued') } |
            Sort-Object { [datetimeoffset](Get-JsonProp $_ 'ScheduledAt') })
    $window = Get-BridgePageWindow -ItemCount $pending.Count -Page $Page -PageSize $PageSize
    $keyboard = @()
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $entry = $pending[$index]
            $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId ([string](Get-JsonProp $entry 'BulletinId'))
            $name = if ($bulletin) { [string]$bulletin.Name } else { (T 'mojaz.deletedBulletin') }
            $moment = [datetimeoffset](Get-JsonProp $entry 'ScheduledAt')
            $keyboard += , @((New-Button "🚫 $($moment.ToString('HH:mm')) · $name" "mojaz:unschedule:$([string](Get-JsonProp $entry 'Id'))" -Style danger))
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button (T 'mojaz.prev') "mojazschedpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "mojazschedpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'mojaz.next') "mojazschedpage:$($window.Page + 1)") }
        $keyboard += , $pager
    }
    # A booked moment says what WILL happen; this says what did - whether last
    # night's bulletin actually started, and how late.
    $keyboard += , @((New-Button (T 'mojaz.execLog') 'schedule:execlog:mojaz'))
    $keyboard += , @((New-Button (T 'mojaz.backToLibrary') 'menu:mojaz'), (New-Button (T 'mojaz.home') 'menu:main'))
    return @{ inline_keyboard = $keyboard }
}

function Show-MojazSchedulesScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazSchedulesText) -ParseMode HTML `
        -ReplyMarkup (Get-MojazSchedulesKeyboard -Page $Page)
}

function Set-MojazScheduleStatus {
    <# One writer for a schedule's state, so a transition is never half
       applied: the whole list is rewritten, or none of it is. #>
    param([Parameter(Mandatory)][string]$ScheduleId, [Parameter(Mandatory)][string]$Status, [hashtable]$Fields = @{})
    $candidate = @($script:MojazSchedules | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    $target = @($candidate | Where-Object { [string]$_.Id -eq $ScheduleId }) | Select-Object -First 1
    if (-not $target) { return $false }
    $target.Status = $Status
    foreach ($key in $Fields.Keys) { $target.$key = $Fields[$key] }
    return (Save-MojazSchedules -Schedules $candidate)
}

function Send-MojazScheduleNotices {
    <#
        A word before a booked bulletin starts by itself.

        Marked once it is sent, because the tick runs every second and an
        appointment sits inside the warning window for the whole minute
        before it fires. Zero seconds turns it off.
    #>
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    $lead = Get-SettingInt 'MojazScheduleNoticeSeconds' 0
    if ($lead -le 0) { return }
    foreach ($entry in @($script:MojazSchedules)) {
        if ([string](Get-JsonProp $entry 'Status') -ne 'scheduled') { continue }
        if ([string](Get-JsonProp $entry 'NoticedAt')) { continue }
        $moment = [datetimeoffset](Get-JsonProp $entry 'ScheduledAt')
        $seconds = ($moment - $Now).TotalSeconds
        if ($seconds -gt $lead -or $seconds -lt 0) { continue }
        $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId ([string]$entry.BulletinId)
        $name = if ($bulletin) { [string]$bulletin.Name } else { (T 'mojaz.scheduledBulletin') }
        if (Set-MojazScheduleStatus -ScheduleId ([string]$entry.Id) -Status 'scheduled' -Fields @{ NoticedAt = $Now.ToString('o') }) {
            Send-TelegramMessage -ChatId ([long]$entry.ChatId) `
                -Text "🔔 «$name» يبدأ بعد $(Format-DurationSeconds -Seconds ([int][math]::Max(0, $seconds))) — $($moment.ToString('HH:mm'))."
        }
    }
}

function Update-MojazScheduleQueue {
    <#
        The clock, checked from the tick.

        Only one bulletin may be on air, so an appointment that comes due while
        another is running does not fight for the layer: it is queued, said
        once, and started later in the order the appointments were originally
        due - not the order they happened to be noticed.
    #>
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    Send-MojazScheduleNotices -Now $Now
    $due = @(Get-MojazDueQueue -Schedules $script:MojazSchedules -Now $Now)
    if ($due.Count -eq 0) { return }
    # Two things hold a due bulletin back: another one already on air, and the
    # urgent, which outranks it. Neither is a reason to drop the appointment.
    $blockedByUrgent = Test-MojazUrgentOnAir
    if ($script:MojazPlayback -or $blockedByUrgent) {
        $reason = if ($script:MojazPlayback) { 'active_bulletin' } else { 'urgent_on_air' }
        foreach ($entry in $due) {
            if ([string](Get-JsonProp $entry 'Status') -ne 'scheduled') { continue }
            $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId ([string]$entry.BulletinId)
            $waitingName = if ($bulletin) { [string]$bulletin.Name } else { (T 'mojaz.theScheduled') }
            $because = if ($script:MojazPlayback) {
                $activeName = if ([string]$script:MojazPlayback.BulletinName) { [string]$script:MojazPlayback.BulletinName } else { (T 'mojaz.theCurrent') }
                "«$activeName» ما زال على الهواء"
            }
            else { (T 'mojaz.urgentOnAir') }
            if (Set-MojazScheduleStatus -ScheduleId ([string]$entry.Id) -Status 'queued' -Fields @{ DueAt = $Now.ToString('o'); DelayReason = $reason }) {
                Send-TelegramMessage -ChatId ([long]$entry.ChatId) -Text "⏳ تأخّر «$waitingName» لأن $because. سيبدأ بعد انتهائه."
            }
        }
        return
    }
    $next = $due[0]
    $scheduleId = [string]$next.Id
    $bulletinForLog = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId ([string]$next.BulletinId)
    if (-not (Set-MojazScheduleStatus -ScheduleId $scheduleId -Status 'running' -Fields @{ StartedAt = $Now.ToString('o') })) { return }
    $script:MojazSelections[[string]$next.ChatId] = [string]$next.BulletinId
    # -Force: the urgent check above has already been made, and nobody is
    # watching a scheduled start to answer a question.
    # Logged where scheduled graphics are logged. The outcome used to live on
    # the schedule record alone and die with it, so nothing could answer "did
    # last night's bulletin actually start, and how late?" after the fact.
    $bulletinName = if ($bulletinForLog) { [string]$bulletinForLog.Name } else { [string]$next.BulletinId }
    if (-not (Start-MojazPlayback -ChatId ([long]$next.ChatId) -UserId ([long]$next.CreatedBy) -ScheduleId $scheduleId -Force)) {
        Set-MojazScheduleStatus -ScheduleId $scheduleId -Status 'failed' -Fields @{ LastError = 'playback_start_failed' } | Out-Null
        Write-BridgeExecutionRecord -Kind 'mojaz' -Result 'failed' -EventId $scheduleId -Label $bulletinName `
            -ScheduledAt ([string](Get-JsonProp $next 'ScheduledAt')) -ErrorText 'playback_start_failed' | Out-Null
    }
    else {
        Write-BridgeExecutionRecord -Kind 'mojaz' -Result 'success' -EventId $scheduleId -Label $bulletinName `
            -ScheduledAt ([string](Get-JsonProp $next 'ScheduledAt')) | Out-Null
    }
}
