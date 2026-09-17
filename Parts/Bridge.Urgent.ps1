#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    The breaking-news board: the table an operator manages, the scene it will
    play on, and the screens that show both.

    The board does not replace the single Urgent template. Pressing that
    template's own button still does exactly what it did before this file
    existed - one line, one SHOW, no engine - and that path is untouched. This
    is the second consumer of the same scene, for when there are several lines
    and they should walk.

    The run itself lives in Bridge.Urgent.Playback.ps1, split from here before
    either file was written rather than after one of them reached 2700 lines.
#>

# --------------------------------------------------------------- the scene

function Get-UrgentTemplate {
    <# The registry entry for the breaking-news scene, or $null. It is the
       same key the fixed urgent button uses - one scene, two ways to drive
       it - so the key is read from one variable rather than spelled twice. #>
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($script:MojazUrgentKey)) { return $null }
    return $store.Map[$script:MojazUrgentKey]
}

function Test-UrgentBoardAvailable {
    <# Two conditions, both required. A button that opens a screen for a scene
       this bridge does not have is a promise it cannot keep, and the setting
       is what keeps the whole feature out of a newsroom that did not ask for
       it. #>
    if (-not (Get-Setting 'EnableUrgentBoard')) { return $false }
    return ($null -ne (Get-UrgentTemplate))
}

function Get-UrgentBoardFile {
    return (Join-Path $logDir 'urgent-board.json')
}

function Get-UrgentSceneTiming {
    <# The breaking-news scene's own clock, read by the same reader the
       bulletin uses. Passing the path is the whole reason that reader takes
       one. #>
    $template = Get-UrgentTemplate
    if (-not $template) { return $null }
    return (Get-MojazSceneTiming -Path ([string]$template.Path))
}

function Test-UrgentSceneLoop {
    <#
        Whether this scene can hide a text change at all.

        "Text only" works by writing the new words during the fade at the loop
        wrap, where they are invisible until the picture comes back. A scene
        cut without a loop - entrance, hold, exit, which is how a breaking
        strap is often built - has no such moment, so the words would visibly
        swap in front of the viewer.

        Asked when the screen is drawn, not when the run starts: the operator
        has to know before they write eight lines in a mode that cannot carry
        them, not after they press play.
    #>
    $timing = Get-UrgentSceneTiming
    if (-not $timing) { return $false }
    return ([double](Get-JsonProp $timing 'LoopSeconds') -gt 0)
}

function Get-UrgentTransitionSeconds {
    <# What an exit-mode line costs before it is visible: the outro plays, then
       the entrance. Read from the scene, so re-cutting it in Titler re-times
       the board with nothing to update here. #>
    $timing = Get-UrgentSceneTiming
    if (-not $timing) { return 0.0 }
    return [math]::Round([double](Get-JsonProp $timing 'OutroSeconds') + [double](Get-JsonProp $timing 'IntroSeconds'), 3)
}

function Get-UrgentFloorSeconds {
    <#
        The shortest a line may be held.

        Derived from the scene where the scene can be read - entrance plus exit
        is the least time a change can take without being seen - and only then
        from the setting. A number in the settings is a guess about a scene
        nobody has measured; the scene cannot be wrong about itself.
    #>
    $transition = Get-UrgentTransitionSeconds
    if ($transition -gt 0) { return $transition }
    return [double](Get-SettingInt 'UrgentMinIntervalSeconds' 4)
}

function Get-UrgentBoardDefaults {
    <#
        The newsroom's own numbers for the board.

        They live in the settings, where every other timing in this bridge
        lives, and not in the board file: a number kept in two places is a
        number that will be edited in one of them and read from the other. An
        item that leaves a field at zero inherits from here.
    #>
    $mode = [string](Get-Setting 'UrgentBoardMode')
    if (-not (Test-UrgentMode -Mode $mode)) { $mode = 'text' }
    $repeatMode = [string](Get-Setting 'UrgentBoardRepeatMode')
    if (-not (Test-UrgentRepeatMode -RepeatMode $repeatMode)) { $repeatMode = 'cycle' }
    return [pscustomobject]@{
        Mode = $mode
        IntervalSeconds = Get-SettingInt 'UrgentBoardIntervalSeconds' 8
        TotalSeconds = Get-SettingInt 'UrgentBoardTotalSeconds' 0
        Repeats = Get-SettingInt 'UrgentBoardRepeats' 1
        RepeatMode = $repeatMode
    }
}

# -------------------------------------------------------------- persistence

function Save-UrgentBoard {
    <# The caller gives us a candidate. It does not become live until the
       validated atomic write succeeds, so a full disk never leaves a board
       that looks saved only until the next restart. #>
    param([Parameter(Mandatory)]$Board)
    if (-not (Write-BridgeValidatedJson -Path (Get-UrgentBoardFile) -Json ($Board | ConvertTo-Json -Depth 12))) {
        Write-BridgeLog 'Could not write the urgent board.' 'WARN'
        return $false
    }
    $script:UrgentBoard = $Board
    return $true
}

function Import-UrgentBoard {
    $script:UrgentBoard = New-UrgentBoard
    $path = Get-UrgentBoardFile
    # The shared reader can recover a backup even when the primary is absent.
    try {
        $stored = Read-BridgeValidatedJson -Path $path
        if ($stored -and $stored.Data) {
            $candidate = $stored.Data
            $itemsProperty = $candidate.PSObject.Properties['Items']
            $revision = 0
            if (-not $itemsProperty -or $itemsProperty.Value -isnot [array] -or
                -not [int]::TryParse([string](Get-JsonProp $candidate 'Revision'), [ref]$revision) -or $revision -lt 1 -or
                [string](Get-JsonProp $candidate 'SchemaVersion') -ne '1') { throw 'Invalid urgent board structure.' }
            $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $itemsProperty.Value) {
                $id = [string](Get-JsonProp $entry 'Id')
                if ($id -notmatch '^u_[a-f0-9]{8}$' -or -not $ids.Add($id) -or
                    [string]::IsNullOrWhiteSpace([string](Get-JsonProp $entry 'Text'))) { throw 'Invalid urgent item identity or text.' }
                foreach ($field in @('Title', 'Mode', 'IntervalSeconds', 'TotalSeconds', 'Repeats', 'RepeatMode', 'Enabled', 'UpdatedAt', 'UpdatedBy')) {
                    if (-not $entry.PSObject.Properties[$field]) { throw "Missing urgent item field: $field" }
                }
                foreach ($field in @('IntervalSeconds', 'TotalSeconds', 'Repeats')) {
                    $number = 0
                    $maximum = if ($field -eq 'Repeats') { 99 } else { 3600 }
                    if (-not [int]::TryParse([string](Get-JsonProp $entry $field), [ref]$number) -or $number -lt 0 -or $number -gt $maximum) { throw 'Invalid urgent timing.' }
                }
                if ($entry.Enabled -isnot [bool] -or ($entry.Mode -and -not (Test-UrgentMode $entry.Mode)) -or
                    ($entry.RepeatMode -and -not (Test-UrgentRepeatMode $entry.RepeatMode))) { throw 'Invalid urgent mode or enabled flag.' }
            }
            $script:UrgentBoard = $candidate
        }
    }
    catch { Write-BridgeLog "Could not read the urgent board: $($_.Exception.Message)" 'WARN' }
}

function Invoke-UrgentEdit {
    <#
        The one place an edit becomes a saved fact.

        The module refuses bad edits and the disk refuses impossible ones; both
        end the same way for the operator - a sentence saying what happened and
        a board that has not moved.
    #>
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][long]$ChatId, [switch]$Quiet)
    if (-not $Result.Success) {
        if (-not $Quiet) { Send-TelegramMessage -ChatId $ChatId -Text "⚠️ $([string]$Result.Error)" }
        return $false
    }
    if (-not (Save-UrgentBoard -Board $Result.Value)) {
        if (-not $Quiet) { Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر حفظ جدول العواجل.' }
        return $false
    }
    return $true
}

# ---------------------------------------------------------------- selection

function Get-UrgentSelectedIds {
    <# What this chat has ticked. One selection per chat, so two operators in
       two chats never play each other's ticks - the bulletin's own selection
       is kept this way for the same reason. #>
    param([Parameter(Mandatory)][long]$ChatId)
    $key = [string]$ChatId
    if (-not $script:UrgentSelections.ContainsKey($key)) { return @() }
    # Ids that have since been deleted are dropped here rather than at every
    # reader: a tick pointing at nothing is not a selection.
    $live = @(@(Get-UrgentProperty $script:UrgentBoard 'Items' @()) | ForEach-Object { [string](Get-UrgentProperty $_ 'Id' '') })
    return @(@($script:UrgentSelections[$key]) | Where-Object { $live -contains $_ })
}

function Set-UrgentSelectedIds {
    param([Parameter(Mandatory)][long]$ChatId, [string[]]$Ids = @())
    $script:UrgentSelections[[string]$ChatId] = @($Ids)
}

function Switch-UrgentSelection {
    <# One tick on or off. Named for what it does to one item; selecting all is
       its own button. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$ItemId)
    $current = @(Get-UrgentSelectedIds -ChatId $ChatId)
    if ($current -contains $ItemId) {
        Set-UrgentSelectedIds -ChatId $ChatId -Ids @($current | Where-Object { $_ -ne $ItemId })
        return $false
    }
    Set-UrgentSelectedIds -ChatId $ChatId -Ids @($current + $ItemId)
    return $true
}

function Get-UrgentItemByPosition {
    <# Screens address items by position: callback_data is 64 bytes and a full
       id does not fit beside a prefix and a page number. #>
    param([int]$Position)
    $items = @(Get-UrgentProperty $script:UrgentBoard 'Items' @())
    if ($Position -lt 0 -or $Position -ge $items.Count) { return $null }
    return $items[$Position]
}

# --------------------------------------------------------------- the plan

function Get-UrgentRunCeiling {
    <#
        The shortest ceiling that applies to this run, and which one it was.

        Two things can end a run before its repeats do. The operator's own
        total is one. The other is the forced hide a sensitive template carries:
        list Urgent in SensitiveTemplateKeys - an entirely reasonable thing for
        a newsroom to do - and every SHOW of it comes with a timer of at most
        SensitiveTemplateAutoHideSeconds. Without this, a board would keep
        writing values into a scene that had been hidden underneath it thirty
        seconds in, and nothing on any screen would say so.
    #>
    param([object[]]$Items = @())
    $defaults = Get-UrgentBoardDefaults
    $requested = [int](Get-UrgentProperty $defaults 'TotalSeconds' 0)
    foreach ($item in @($Items)) {
        $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults
        if (-not $timing.TotalInherited) { $requested = [int]$timing.TotalSeconds; break }
    }
    $autoHide = Get-EffectiveAutoHideSeconds -Key $script:MojazUrgentKey -RequestedSeconds 0
    $seconds = 0.0
    $reason = ''
    if ($requested -gt 0) { $seconds = [double]$requested; $reason = 'total' }
    if ($autoHide -gt 0 -and ($seconds -le 0 -or $autoHide -lt $seconds)) {
        $seconds = [double]$autoHide
        $reason = 'autohide'
    }
    return [pscustomobject]@{ Seconds = $seconds; Reason = $reason; AutoHideSeconds = $autoHide }
}

function Get-UrgentAutoHideLabel {
    param([int]$Seconds)
    # The shared duration helper is authoritative; identify which configured
    # policy supplied that value without changing the planner's reason contract.
    $maximum = 0
    $raw = Get-JsonProp (Get-Setting 'TemplateMaxAirSeconds') $script:MojazUrgentKey
    if ([int]::TryParse([string]$raw, [ref]$maximum) -and $maximum -gt 0 -and $maximum -eq $Seconds) {
        return 'الحد الأقصى للقالب'
    }
    return 'الإخفاء التلقائي للقالب الحسّاس'
}

function New-UrgentBoardPlan {
    <#
        The board, costed against this scene and this template's rules.

        Everything the module cannot know is resolved here and handed to it:
        the floor the scene sets, what a transition costs, and the ceiling. The
        arithmetic itself stays in one place, so the sentence on the review
        screen and the moments the engine walks come from the same call.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [switch]$SelectedOnly)
    $board = $script:UrgentBoard
    $items = @(Get-UrgentPlayableItems -Board $board -SelectedIds (Get-UrgentSelectedIds -ChatId $ChatId) -SelectedOnly:$SelectedOnly)
    $ceiling = Get-UrgentRunCeiling -Items $items
    $result = New-UrgentRunPlan -Items $items -Defaults (Get-UrgentBoardDefaults) `
        -FloorSeconds (Get-UrgentFloorSeconds) -TransitionSeconds (Get-UrgentTransitionSeconds) `
        -MaxSeconds $ceiling.Seconds -MaxReason $ceiling.Reason
    if ($result.Success -and $ceiling.Reason -eq 'autohide') {
        $label = Get-UrgentAutoHideLabel -Seconds $ceiling.AutoHideSeconds
        $result.Value.Notes = @($result.Value.Notes | ForEach-Object { $_.Replace('الإخفاء التلقائي للقالب الحسّاس', $label) })
    }
    return $result
}

function Get-UrgentItemVariables {
    <#
        One breaking line, as the scene's own field names.

        Mapped by the order the template declares its fields: the first field
        carries the line, the second the kicker when the scene has one. The
        board deliberately does not invent field names - a scene names its own,
        and the registry is where a station says what they are.
    #>
    param($Item)
    $template = Get-UrgentTemplate
    $values = @{}
    if (-not $template) { return $values }
    $fields = @(Get-JsonProp $template 'Fields')
    if ($fields.Count -lt 1) { return $values }
    $values[[string]$fields[0]] = [string](Get-UrgentProperty $Item 'Text' '')
    $title = [string](Get-UrgentProperty $Item 'Title' '')
    # An omitted field retains the preceding story's title on text updates.
    if ($fields.Count -gt 1) { $values[[string]$fields[1]] = $title }
    return $values
}

# ----------------------------------------------------------------- screens

function Get-UrgentNextMode {
    param([string]$Mode)
    switch ($Mode) {
        'text' { return 'exit' }
        'exit' { return 'auto_hide' }
        default { return 'text' }
    }
}

function Get-UrgentModeLabel {
    param([string]$Mode)
    if ($Mode -eq 'exit') { return '🚪 مع حركة خروج' }
    if ($Mode -eq 'auto_hide') { return '🙈 إخفاء بعد المدة' }
    return '✏️ تحديث نص'
}

function Get-UrgentBoardPageSize {
    return [math]::Max(1, [math]::Min(10, (Get-SettingInt 'NewsListPageSize' 8)))
}

function Get-UrgentBoardKeyboard {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Page = 0)
    $board = $script:UrgentBoard
    $items = @(Get-UrgentProperty $board 'Items' @())
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize (Get-UrgentBoardPageSize)
    $rows = @()
    if ($items.Count -gt 0) {
        for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $item = $items[$index]
            $id = [string](Get-UrgentProperty $item 'Id' '')
            $tick = if ($selected -contains $id) { '☑' } else { '☐' }
            $text = [string](Get-UrgentProperty $item 'Text' '')
            $label = if ($text.Length -gt 22) { $text.Substring(0, 21) + '…' } else { $text }
            $row = @(
                (New-Button "$tick $($index + 1). $label" "urgentb:pick:$id")
                (New-Button '⚙️' "urgentb:item:$id")
            )
            $rows += , $row
        }
    }
    if ($window.PageCount -gt 1) {
        $nav = @()
        if ($window.HasPrevious) { $nav += (New-Button '⬅️ السابق' "urgentb:page:$($window.Page - 1)") }
        $nav += (New-Button "$($window.Page + 1)/$($window.PageCount)" 'urgentb:noop')
        if ($window.HasNext) { $nav += (New-Button 'التالي ➡️' "urgentb:page:$($window.Page + 1)") }
        $rows += , $nav
    }
    $rows += , @(
        (New-Button '➕ إضافة' 'urgentb:add')
        (New-Button '☑ تحديد الكل' "urgentb:all:$($window.Page)")
        (New-Button '☐ إلغاء التحديد' "urgentb:none:$($window.Page)")
    )
    $rows += , @(
        (New-Button '⚙️ توقيتات الجدول' 'urgentb:timing')
        (New-Button '🗑 حذف المحدَّد' 'urgentb:delask' -Style danger)
    )
    # Play only where there is something to play and nothing already playing.
    # A button that refuses is a button that teaches the operator to distrust
    # the screen.
    if ($script:UrgentBoardRun) {
        if ([bool](Get-JsonProp $script:UrgentBoardRun 'StopFailed')) {
            $rows += , @( (New-Button '🔁 إعادة الإيقاف' 'urgentb:stop' -Style danger) )
        }
        else {
            $rows += , @( (New-Button '⏹ إيقاف التشغيل' 'urgentb:stop' -Style danger) )
            if ([bool](Get-JsonProp $script:UrgentBoardRun 'Paused')) {
                $pauseButton = New-Button '▶️ استئناف' 'urgentb:resume'
            }
            else { $pauseButton = New-Button '⏸ مؤقت' 'urgentb:pause' }
            $rows += , @( (New-Button '⏭ تخطي الحالي' 'urgentb:skip'), $pauseButton )
        }
    }
    elseif ($items.Count -gt 0) {
        $playRow = @()
        if ($selected.Count -gt 0) { $playRow += (New-Button "▶️ تشغيل المحدَّد ($($selected.Count))" 'urgentb:review:sel' -Style success) }
        $playRow += (New-Button '⏭ تشغيل الكل' 'urgentb:review:all' -Style success)
        $rows += , $playRow
    }
    $rows += , @( (New-Button '🔄 تحديث' 'urgentb:open'), (New-Button '⬅️ القائمة' 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Get-UrgentRunStatusText {
    if (-not $script:UrgentBoardRun) { return '' }
    $run = $script:UrgentBoardRun
    $failed = [bool](Get-JsonProp $run 'StopFailed')
    $status = if ($failed) { '⚠️ تعذّر تأكيد الإيقاف؛ التشغيل مجمّد وحالة الهواء غير مؤكدة. أعد محاولة الإيقاف، لا الاستئناف.' }
        elseif ([bool](Get-JsonProp $run 'Paused')) { '⏸ متوقف مؤقتًا؛ العاجل يبقى ظاهرًا. مؤقّت أمان القالب لا يتوقف.' }
        else { '▶️ يعمل' }
    $steps = @(Get-JsonProp $run 'Steps')
    $position = [int](Get-JsonProp $run 'Step')
    $lines = @($status)
    if ($position -ge 0 -and $position -lt $steps.Count) {
        $lines += "الخبر $($position + 1) من $($steps.Count)"
        # Read the immutable run snapshot, not the board being edited meanwhile.
        $current = [string](Get-JsonProp $steps[$position] 'Text')
        if ($current.Length -gt 120) { $current = $current.Substring(0, 119) + '…' }
        $lines += "الحالي: $current"
        if ($position + 1 -lt $steps.Count) {
            $next = [string](Get-JsonProp $steps[$position + 1] 'Text')
            if ($next.Length -gt 120) { $next = $next.Substring(0, 119) + '…' }
            $lines += "التالي: $next"
        }
        else { $lines += 'التالي: نهاية الجدول' }
    }
    return ($lines -join "`n")
}

function Get-UrgentBoardBlocks {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Page = 0)
    $board = $script:UrgentBoard
    $defaults = Get-UrgentBoardDefaults
    $items = @(Get-UrgentProperty $board 'Items' @())
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    $blocks = @(@{ type = 'heading'; text = "🚨 العواجل — $($items.Count) عاجلًا"; size = 3 })
    $runStatus = Get-UrgentRunStatusText
    if ($runStatus) { $blocks += @{ type = 'paragraph'; text = $runStatus } }

    $order = if ([string](Get-UrgentProperty $defaults 'RepeatMode' 'cycle') -eq 'item') { '١ ١ · ٢ ٢' } else { '١ ٢ ٣ · ١ ٢ ٣' }
    $total = [int](Get-UrgentProperty $defaults 'TotalSeconds' 0)
    $totalText = if ($total -gt 0) { "$total ث" } else { 'بلا سقف' }
    $blocks += @{ type = 'paragraph'; text = "الافتراضي: $(Get-UrgentModeLabel -Mode ([string](Get-UrgentProperty $defaults 'Mode' 'text'))) · فاصل $([int](Get-UrgentProperty $defaults 'IntervalSeconds' 8)) ث · $([int](Get-UrgentProperty $defaults 'Repeats' 1)) دورة ($order) · المدة $totalText" }

    # Said on the board, not only when a run is refused: an operator writing
    # lines in a mode this scene cannot hide should find out now.
    if (-not (Test-UrgentSceneLoop)) {
        $blocks += @{ type = 'paragraph'; text = '⚠️ مشهد العاجل بلا حلقة: «تحديث نص» سيُرى وهو يتبدّل. استعمل «مع حركة خروج».' }
    }
    $ceiling = Get-UrgentRunCeiling -Items $items
    if ([int]$ceiling.AutoHideSeconds -gt 0) {
        $blocks += @{ type = 'paragraph'; text = "⚠️ $(Get-UrgentAutoHideLabel -Seconds $ceiling.AutoHideSeconds): يُخفى تلقائيًا بعد $([int]$ceiling.AutoHideSeconds) ث؛ قد ينتهي الجدول قبل ذلك." }
    }

    if ($items.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'الجدول فارغ. اضغط ➕ إضافة.' }
        return $blocks
    }

    # The same window the keyboard is showing, so the numbers in the table are
    # the numbers on the buttons. Trimmed as well as paged: the page size is a
    # setting an administrator can raise, and Select-RichTableRows is the cap
    # that stops a table quietly losing its own rows past the payload limit.
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize (Get-UrgentBoardPageSize)
    # Named $windowItems, not $page: PowerShell variable names do not
    # distinguish case, so $page would overwrite the $Page parameter this
    # function was called with - and the second reader of it gets an array
    # where an int is due.
    $windowItems = @($items[$window.StartIndex..$window.EndIndex])
    $trimmed = Select-RichTableRows -Items $windowItems
    if ($window.PageCount -gt 1) {
        $blocks += @{ type = 'paragraph'; text = "المعروض: $($window.StartIndex + 1)–$($window.EndIndex + 1) · صفحة $($window.Page + 1) من $($window.PageCount)" }
    }
    $cells = @(, @(
            @{ text = '#'; is_header = $true }
            @{ text = 'العاجل'; is_header = $true }
            @{ text = 'العرض'; is_header = $true }
            @{ text = 'الفاصل'; is_header = $true }
        ))
    $position = $window.StartIndex
    foreach ($item in @($trimmed.Rows)) {
        $position++
        $id = [string](Get-UrgentProperty $item 'Id' '')
        $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults -FloorSeconds (Get-UrgentFloorSeconds)
        $tick = if ($selected -contains $id) { '☑' } else { '☐' }
        $mark = if ([bool](Get-UrgentProperty $item 'Enabled' $true)) { $tick } else { '⛔' }
        $text = [string](Get-UrgentProperty $item 'Text' '')
        $shown = if ($text.Length -gt 60) { $text.Substring(0, 59) + '…' } else { $text }
        $mode = if ($timing.Mode -eq 'exit') { '🚪' } elseif ($timing.Mode -eq 'auto_hide') { '🙈' } else { '✏️' }
        $interval = if ($timing.IntervalInherited) { "$($timing.HoldSeconds) ث" } else { "$($timing.HoldSeconds) ث ✱" }
        $cells += , @(@{ text = "$mark $position" }, @{ text = $shown }, @{ text = $mode }, @{ text = $interval })
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown (@($trimmed.Rows).Count)
    if ($note) { $blocks += @{ type = 'paragraph'; text = $note } }
    $blocks += @{ type = 'paragraph'; text = '✱ = قيمة خاصة بالعنصر · ⛔ = معطَّل · التحديد يخصّ محادثتك وحدها.' }
    return $blocks
}

function Get-UrgentBoardText {
    <# The fallback every rich screen owes its reader. Same facts, no table. #>
    param([Parameter(Mandatory)][long]$ChatId, [int]$Page = 0)
    $board = $script:UrgentBoard
    $defaults = Get-UrgentBoardDefaults
    $items = @(Get-UrgentProperty $board 'Items' @())
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    $lines = @("🚨 <b>العواجل</b> — $($items.Count) عاجلًا")
    $runStatus = Get-UrgentRunStatusText
    if ($runStatus) { $lines += (ConvertTo-TelegramHtmlText -Text $runStatus) }
    $lines += "الافتراضي: فاصل $([int](Get-UrgentProperty $defaults 'IntervalSeconds' 8)) ث · $([int](Get-UrgentProperty $defaults 'Repeats' 1)) دورة"
    if (-not (Test-UrgentSceneLoop)) { $lines += '⚠️ مشهد العاجل بلا حلقة: «تحديث نص» سيُرى وهو يتبدّل.' }
    $ceiling = Get-UrgentRunCeiling -Items $items
    if ([int]$ceiling.AutoHideSeconds -gt 0) {
        $lines += "⚠️ $(Get-UrgentAutoHideLabel -Seconds $ceiling.AutoHideSeconds): يُخفى تلقائيًا بعد $([int]$ceiling.AutoHideSeconds) ث؛ قد ينتهي الجدول قبل ذلك."
    }
    if ($items.Count -eq 0) {
        $lines += 'الجدول فارغ.'
        return ($lines -join "`n")
    }
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize (Get-UrgentBoardPageSize)
    $trimmed = Select-RichTableRows -Items @($items[$window.StartIndex..$window.EndIndex])
    if ($window.PageCount -gt 1) {
        $lines += "المعروض: $($window.StartIndex + 1)–$($window.EndIndex + 1) · صفحة $($window.Page + 1) من $($window.PageCount)"
    }
    $position = $window.StartIndex
    foreach ($item in @($trimmed.Rows)) {
        $position++
        $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults -FloorSeconds (Get-UrgentFloorSeconds)
        $enabled = [bool](Get-UrgentProperty $item 'Enabled' $true)
        $tick = if (-not $enabled) { '⛔' } elseif ($selected -contains [string](Get-UrgentProperty $item 'Id' '')) { '☑' } else { '☐' }
        $mode = if ($timing.Mode -eq 'exit') { '🚪' } elseif ($timing.Mode -eq 'auto_hide') { '🙈' } else { '✏️' }
        # Escaped because a breaking line is text somebody typed, and this
        # message is sent as HTML.
        $safe = ConvertTo-TelegramHtmlText -Text ([string](Get-UrgentProperty $item 'Text' ''))
        $lines += "$tick $position. $mode $safe — $($timing.HoldSeconds) ث"
    }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown (@($trimmed.Rows).Count)
    if ($note) { $lines += $note }
    return ($lines -join "`n")
}

function Show-UrgentBoardScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$MessageId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $keyboard = Get-UrgentBoardKeyboard -ChatId $ChatId -Page $Page
    if (-not $script:RichMessagesUnavailable) {
        $blocks = Get-UrgentBoardBlocks -ChatId $ChatId -Page $Page
        if ($MessageId -gt 0) {
            if (Edit-TelegramRichMessage -ChatId $ChatId -MessageId $MessageId -Blocks $blocks -ReplyMarkup $keyboard) { return }
        }
        elseif (Send-TelegramRichMessage -ChatId $ChatId -Blocks $blocks -ReplyMarkup $keyboard) { return }
    }
    $text = Get-UrgentBoardText -ChatId $ChatId -Page $Page
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML')) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
}

function Get-UrgentItemKeyboard {
    <# One item's own screen. Every override carries the button that puts it
       back to the table's value, because "inherited" and "happens to be the
       same number" must be tellable apart by looking. #>
    param([Parameter(Mandatory)][int]$Position)
    $item = Get-UrgentItemByPosition -Position $Position
    $rows = @()
    if (-not $item) { return @{ inline_keyboard = @(, @( (New-Button '⬅️ العواجل' 'urgentb:open') )) } }
    $defaults = Get-UrgentBoardDefaults
    $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults -FloorSeconds (Get-UrgentFloorSeconds)
    $itemId = [string](Get-UrgentProperty $item 'Id' '')
    $rows += , @( (New-Button '✏️ تعديل النص' "urgentb:text:$itemId"), (New-Button '🏷 العنوان' "urgentb:title:$itemId") )
    $modeRow = @( (New-Button '🎬 نمط العرض' "urgentb:mode:$itemId") )
    if (-not $timing.ModeInherited) { $modeRow += (New-Button '↩️ من الجدول' "urgentb:modereset:$itemId") }
    $rows += , $modeRow
    $intervalRow = @( (New-Button "⏱ الفاصل: $($timing.IntervalSeconds) ث" "urgentb:interval:$itemId") )
    if (-not $timing.IntervalInherited) { $intervalRow += (New-Button '↩️ من الجدول' "urgentb:intervalreset:$itemId") }
    $rows += , $intervalRow
    $repeatRow = @( (New-Button "🔁 التكرار: $($timing.Repeats)" "urgentb:repeats:$itemId") )
    if (-not $timing.RepeatsInherited) { $repeatRow += (New-Button '↩️ من الجدول' "urgentb:repeatsreset:$itemId") }
    $rows += , $repeatRow
    $enabled = [bool](Get-UrgentProperty $item 'Enabled' $true)
    $toggle = if ($enabled) { '⛔ تعطيل' } else { '✅ تفعيل' }
    $rows += , @( (New-Button $toggle "urgentb:enable:$itemId"), (New-Button '🗑 حذف' "urgentb:itemdel:$itemId" -Style danger) )
    $rows += , @( (New-Button '⬆️ أعلى' "urgentb:up:$itemId"), (New-Button '⬇️ أسفل' "urgentb:down:$itemId") )
    $boardPage = [int][math]::Floor($Position / (Get-UrgentBoardPageSize))
    $rows += , @( (New-Button '⬅️ العواجل' "urgentb:page:$boardPage") )
    return @{ inline_keyboard = $rows }
}

function Show-UrgentItemScreen {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Position, [int]$MessageId = 0)
    $item = Get-UrgentItemByPosition -Position $Position
    if (-not $item) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ العاجل غير موجود.' -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return
    }
    $defaults = Get-UrgentBoardDefaults
    $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults -FloorSeconds (Get-UrgentFloorSeconds)
    $itemCount = @(Get-UrgentProperty $script:UrgentBoard 'Items' @()).Count
    $lines = @("🚨 <b>الخبر $($Position + 1) من $itemCount</b>")
    $lines += (ConvertTo-TelegramHtmlText -Text ([string](Get-UrgentProperty $item 'Text' '')))
    $title = [string](Get-UrgentProperty $item 'Title' '')
    if ($title) { $lines += "🏷 $(ConvertTo-TelegramHtmlText -Text $title)" }
    $lines += ''
    $lines += "العرض: $(Get-UrgentModeLabel -Mode $timing.Mode)$(if ($timing.ModeInherited) { ' (من الجدول)' } else { '' })"
    $lines += "الفاصل: $($timing.HoldSeconds) ث$(if ($timing.IntervalInherited) { ' (من الجدول)' } else { '' })"
    $lines += "التكرار: $($timing.Repeats)$(if ($timing.RepeatsInherited) { ' (من الجدول)' } else { '' })"
    if ($timing.IntervalRaisedToFloor) { $lines += "⚠️ رُفع الفاصل إلى $($timing.HoldSeconds) ث: أقصر ممّا يسمح به المشهد." }
    if ($timing.Mode -eq 'text' -and -not (Test-UrgentSceneLoop)) { $lines += '⚠️ هذا المشهد بلا حلقة: التبديل سيُرى.' }
    $keyboard = Get-UrgentItemKeyboard -Position $Position
    $text = $lines -join "`n"
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML')) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
}

function Get-UrgentTimingKeyboard {
    param()
    $defaults = Get-UrgentBoardDefaults
    $repeatMode = [string](Get-UrgentProperty $defaults 'RepeatMode' 'cycle')
    $orderLabel = if ($repeatMode -eq 'item') { 'الترتيب: كل عاجل مرّات (١ ١ · ٢ ٢)' } else { 'الترتيب: الجدول كاملًا (١ ٢ ٣ · ١ ٢ ٣)' }
    $total = [int](Get-UrgentProperty $defaults 'TotalSeconds' 0)
    $totalLabel = if ($total -gt 0) { "⏳ المدة الكلية: $total ث" } else { '⏳ المدة الكلية: بلا سقف' }
    $rows = @()
    $rows += , @( (New-Button "⏱ الفاصل: $([int](Get-UrgentProperty $defaults 'IntervalSeconds' 8)) ث" 'urgentb:dinterval') )
    $rows += , @( (New-Button "🔁 التكرار: $([int](Get-UrgentProperty $defaults 'Repeats' 1))" 'urgentb:drepeats') )
    $rows += , @( (New-Button $orderLabel 'urgentb:dorder') )
    $rows += , @( (New-Button $totalLabel 'urgentb:dtotal') )
    $rows += , @( (New-Button "🎬 النمط الافتراضي: $(Get-UrgentModeLabel -Mode ([string](Get-UrgentProperty $defaults 'Mode' 'text')))" 'urgentb:dmode') )
    $rows += , @( (New-Button '⬅️ العواجل' 'urgentb:open') )
    return @{ inline_keyboard = $rows }
}

function Show-UrgentTimingScreen {
    param([Parameter(Mandatory)][long]$ChatId, [int]$MessageId = 0)
    $lines = @('⚙️ <b>توقيتات جدول العواجل</b>', '')
    $lines += 'هذه قيم الجدول. كل عاجل يستطيع تجاوزها من شاشته، وما لم يتجاوزها يأخذها من هنا.'
    $lines += ''
    $lines += 'الترتيب: «الجدول كاملًا» يعيد الجدول من أوّله (١ ٢ ٣ · ١ ٢ ٣)، و«كل عاجل مرّات» يكرّر العاجل ثم ينتقل (١ ١ · ٢ ٢).'
    $floor = Get-UrgentFloorSeconds
    $lines += "أقصر فاصل يسمح به هذا المشهد: $([math]::Round($floor, 1)) ث."
    $keyboard = Get-UrgentTimingKeyboard
    $text = $lines -join "`n"
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML')) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
}

function Show-UrgentReviewScreen {
    <#
        The last screen before anything reaches air.

        It exists because every number on it can be cut by something the
        operator did not set: a scene that raises a short interval, a total
        that trims the repeats, a sensitive template that hides the whole thing
        at thirty seconds. A run that quietly played half the table is
        indistinguishable from one that played all of it.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [switch]$SelectedOnly, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $plan = New-UrgentBoardPlan -ChatId $ChatId -SelectedOnly:$SelectedOnly
    if (-not $plan.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لم يبدأ التشغيل: $([string]$plan.Error)" -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $scope = if ($SelectedOnly) { 'المحدَّد' } else { 'الجدول كاملًا' }
    $lines = @("▶️ <b>مراجعة قبل التشغيل</b> — $scope", '')
    $lines += (Get-UrgentPlanSummary -Plan $plan.Value)
    $holds = @($plan.Value.Steps | ForEach-Object { [double]$_.HoldSeconds } | Sort-Object -Unique)
    $holdLabel = if ($holds.Count -eq 1) { "$($holds[0])" } else { "$($holds[0])–$($holds[-1])" }
    $lines += "الفاصل الفعلي: $holdLabel ث"
    $items = @(Get-UrgentPlayableItems -Board $script:UrgentBoard -SelectedIds (Get-UrgentSelectedIds -ChatId $ChatId) -SelectedOnly:$SelectedOnly)
    $ceiling = Get-UrgentRunCeiling -Items $items
    if ($ceiling.Seconds -gt 0) {
        $reason = if ($ceiling.Reason -eq 'autohide') { Get-UrgentAutoHideLabel -Seconds $ceiling.AutoHideSeconds } else { 'المدة الكلية' }
        $lines += "سقف التشغيل: $($ceiling.Seconds) ث — $reason"
    }
    foreach ($note in @(Get-UrgentProperty $plan.Value 'Notes' @())) { $lines += $note }
    if (-not (Test-UrgentSceneLoop)) {
        $textSteps = @(@(Get-UrgentProperty $plan.Value 'Steps' @()) | Where-Object { [string]$_.Mode -eq 'text' })
        if ($textSteps.Count -gt 0) { $lines += "⚠️ $($textSteps.Count) سطرًا بنمط «تحديث نص» على مشهد بلا حلقة: سيُرى التبديل." }
    }
    $data = if ($SelectedOnly) { 'urgentb:play:sel' } else { 'urgentb:play:all' }
    $rows = @()
    $rows += , @( (New-Button '🚨 ابدأ الآن' $data -Style success) )
    $rows += , @( (New-Button '⬅️ رجوع' 'urgentb:open') )
    $text = $lines -join "`n"
    $keyboard = @{ inline_keyboard = $rows }
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML')) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
    return $true
}

# ------------------------------------------------------------ button edits

function Invoke-UrgentItemEdit {
    <#
        Every one-press edit to one item goes through here.

        Written once because the six buttons around it differ only in which
        field they set and what they redraw afterwards. Six copies of
        "find the item, apply, save, redraw" is six places for the position
        lookup to drift - and the fourth copy is always the one that forgets
        the bounds check.
    #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$Field,
        $Value
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $item = Get-UrgentItemByPosition -Position $Position
    if (-not $item) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ العاجل غير موجود.' -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $result = Set-UrgentItem -Board $script:UrgentBoard -ItemId ([string](Get-UrgentProperty $item 'Id' '')) `
        -Field $Field -Value $Value -MaxLength (Get-SettingInt 'UrgentBoardMaxTextLength' 300) -UserId $UserId
    if (-not (Invoke-UrgentEdit -Result $result -ChatId $ChatId)) { return $false }
    Show-UrgentItemScreen -ChatId $ChatId -Position $Position
    return $true
}

function Invoke-UrgentItemModeSwitch {
    # Keep both original modes available; the third mode hides this line at its deadline.
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [Parameter(Mandatory)][int]$Position)
    $item = Get-UrgentItemByPosition -Position $Position
    if (-not $item) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ العاجل غير موجود.' -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $timing = Get-UrgentEffectiveTiming -Item $item -Defaults (Get-UrgentBoardDefaults)
    $next = Get-UrgentNextMode -Mode $timing.Mode
    return (Invoke-UrgentItemEdit -ChatId $ChatId -UserId $UserId -Position $Position -Field 'Mode' -Value $next)
}

function Invoke-UrgentItemReset {
    <# Back to the table's value. An override and a coincidence must be
       tellable apart, so clearing one is its own act rather than typing the
       same number the table already has. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][ValidateSet('Mode', 'IntervalSeconds', 'Repeats', 'RepeatMode')][string]$Field)
    $blank = if ($Field -in @('Mode', 'RepeatMode')) { '' } else { 0 }
    return (Invoke-UrgentItemEdit -ChatId $ChatId -UserId $UserId -Position $Position -Field $Field -Value $blank)
}

function Invoke-UrgentItemEnableSwitch {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [Parameter(Mandatory)][int]$Position)
    $item = Get-UrgentItemByPosition -Position $Position
    if (-not $item) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ العاجل غير موجود.' -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $next = -not [bool](Get-UrgentProperty $item 'Enabled' $true)
    return (Invoke-UrgentItemEdit -ChatId $ChatId -UserId $UserId -Position $Position -Field 'Enabled' -Value $next)
}

function Invoke-UrgentItemMove {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [Parameter(Mandatory)][int]$Position, [Parameter(Mandatory)][int]$Delta)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $item = Get-UrgentItemByPosition -Position $Position
    if (-not $item) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ العاجل غير موجود.' -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $result = Move-UrgentItem -Board $script:UrgentBoard -ItemId ([string](Get-UrgentProperty $item 'Id' '')) -Delta $Delta
    if (-not (Invoke-UrgentEdit -Result $result -ChatId $ChatId)) { return $false }
    # The item moved, so the screen that was open is now about its neighbour.
    Show-UrgentItemScreen -ChatId $ChatId -Position ($Position + $Delta)
    return $true
}

function Invoke-UrgentItemDelete {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [Parameter(Mandatory)][int]$Position)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $item = Get-UrgentItemByPosition -Position $Position
    if (-not $item) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ العاجل غير موجود.' -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $result = Remove-UrgentItem -Board $script:UrgentBoard -ItemId ([string](Get-UrgentProperty $item 'Id' ''))
    if (-not (Invoke-UrgentEdit -Result $result -ChatId $ChatId)) { return $false }
    Add-AuditEntry "🗑 حذف عاجل من الجدول - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Show-UrgentDeleteConfirm {
    <# Deleting what is ticked is a destructive act on somebody else's work as
       often as on your own, so it says how many and asks. #>
    param([Parameter(Mandatory)][long]$ChatId)
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    if ($selected.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لم تحدّد شيئًا لحذفه.' -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $rows = @()
    $token = [guid]::NewGuid().ToString('N').Substring(0, 12)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'urgent_delete_confirm'; Token = $token; ItemIds = @($selected); StartedAt = (Get-Date) }
    $rows += , @( (New-Button "🗑 احذف $($selected.Count)" "urgentb:delconfirm:$token" -Style danger) )
    $rows += , @( (New-Button '⬅️ رجوع' 'urgentb:open') )
    Send-TelegramMessage -ChatId $ChatId -Text "🗑 حذف $($selected.Count) عاجلًا من الجدول؟" -ReplyMarkup @{ inline_keyboard = $rows }
    return $true
}

function Invoke-UrgentSelectedDelete {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Token = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    $confirmation = Get-PendingState -ChatId $ChatId
    if (-not $Token -or -not $confirmation -or [string](Get-JsonProp $confirmation 'Mode') -ne 'urgent_delete_confirm' -or
        $Token -cne [string](Get-JsonProp $confirmation 'Token')) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ انتهت صلاحية تأكيد الحذف. حدّد العواجل وأكّد من جديد.'
        return $false
    }
    $selected = @(Get-JsonProp $confirmation 'ItemIds')
    Clear-PendingState -ChatId $ChatId
    if ($selected.Count -eq 0) {
        Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId
        return $false
    }
    # Applied to one candidate and saved once: saving per item would leave the
    # board half-deleted if the disk refused half way through.
    $candidate = $script:UrgentBoard
    $removed = 0
    foreach ($id in $selected) {
        $result = Remove-UrgentItem -Board $candidate -ItemId $id
        if ($result.Success) { $candidate = $result.Value; $removed++ }
    }
    if ($removed -eq 0) {
        Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId
        return $false
    }
    if (-not (Save-UrgentBoard -Board $candidate)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر حفظ جدول العواجل.'
        return $false
    }
    Set-UrgentSelectedIds -ChatId $ChatId -Ids @()
    Add-AuditEntry "🗑 حذف $removed عاجلًا من الجدول - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Set-UrgentBoardSetting {
    <#
        One of the table's own numbers, through the bridge's single settings
        door - which is where the range check lives, and refuses rather than
        clamps. A second validator here would be a second rule to keep in step.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Name, $Value)
    try {
        # Set-Setting checks bounds only when TryParse succeeds. Never persist
        # numeric text it cannot parse: Get-SettingInt would silently read 8.
        if ($Name -in @('UrgentBoardIntervalSeconds', 'UrgentBoardRepeats', 'UrgentBoardTotalSeconds')) {
            $number = 0
            if (-not [int]::TryParse([string]$Value, [ref]$number)) { throw 'اختر قيمة رقمية صحيحة من الأزرار.' }
            $Value = $number
        }
        $previousSettings = (Get-JsonProp $config 'Settings') | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $script:LastConfigSaveFailed = $false
        Set-Setting -Name $Name -Value $Value
        if ($script:LastConfigSaveFailed) {
            Set-JsonProp $config 'Settings' $previousSettings
            throw 'تعذّر حفظ الإعداد؛ بقيت القيمة السابقة.'
        }
    }
    catch {
        # Redacted on the way out, like every other exception this bridge shows
        # a chat: a chat is the widest audience it has, and redaction costs
        # nothing on a message that carries no credential.
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ $(Protect-SensitiveText $_.Exception.Message)"
        return $false
    }
    return $true
}

function Invoke-UrgentDefaultSwitch {
    # The same mode cycle as the item screen, and a separate repeat-order toggle.
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][ValidateSet('Mode', 'RepeatMode')][string]$Field)
    $defaults = Get-UrgentBoardDefaults
    $next = ''
    if ($Field -eq 'Mode') {
        $next = Get-UrgentNextMode -Mode ([string]$defaults.Mode)
    }
    else {
        $next = if ([string]$defaults.RepeatMode -eq 'item') { 'cycle' } else { 'item' }
    }
    if (-not (Set-UrgentBoardSetting -ChatId $ChatId -Name "UrgentBoard$Field" -Value $next)) { return $false }
    Show-UrgentTimingScreen -ChatId $ChatId
    return $true
}

# ------------------------------------------------------------- numeric input

function Get-UrgentNumberSpec {
    param([Parameter(Mandatory)][ValidateSet('interval', 'repeats', 'dinterval', 'drepeats', 'dtotal')][string]$Kind)
    $spec = @{ Field = 'IntervalSeconds'; Setting = ''; Label = 'فاصل هذا العاجل (ثانية)'; Minimum = 0; Maximum = 3600; Zero = 'من الجدول' }
    switch ($Kind) {
        'repeats' { $spec.Field = 'Repeats'; $spec.Label = 'تكرار هذا العاجل'; $spec.Maximum = 99 }
        'dinterval' { $spec.Setting = 'UrgentBoardIntervalSeconds'; $spec.Label = 'فاصل الجدول (ثانية)'; $spec.Minimum = 1 }
        'drepeats' { $spec.Setting = 'UrgentBoardRepeats'; $spec.Field = 'Repeats'; $spec.Label = 'تكرار الجدول'; $spec.Minimum = 1 }
        'dtotal' { $spec.Setting = 'UrgentBoardTotalSeconds'; $spec.Field = 'TotalSeconds'; $spec.Label = 'المدة الكلية (ثانية)'; $spec.Zero = 'بلا سقف' }
    }
    if ($spec.Setting) {
        $bounds = Get-SettingBounds -Name $spec.Setting
        $spec.Minimum = [int]$bounds.Minimum
        $spec.Maximum = [int]$bounds.Maximum
    }
    return $spec
}

function Show-UrgentNumberPicker {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State, [int]$MessageId = 0)
    $spec = Get-UrgentNumberSpec -Kind $State.Kind
    $current = 0
    if ($spec.Setting) { $current = Get-SettingInt $spec.Setting ([int]$script:DefaultSettings[$spec.Setting]) }
    else {
        $item = Get-UrgentItem -Board $script:UrgentBoard -ItemId $State.ItemId
        if (-not $item) { Clear-PendingState -ChatId $ChatId; Show-UrgentBoardScreen -ChatId $ChatId; return }
        $current = [int](Get-UrgentProperty $item $spec.Field 0)
    }
    $valueLabel = if ($current -eq 0) { "0 — $($spec.Zero)" } else { [string]$current }
    $text = "🔢 $($spec.Label)`nالقيمة: $valueLabel`nالمدى: $($spec.Minimum)–$($spec.Maximum)`nاختر بالأزرار؛ كل ضغطة تُحفظ فورًا."
    if (-not $spec.Setting) {
        $effective = Get-UrgentEffectiveTiming -Item $item -Defaults (Get-UrgentBoardDefaults) -FloorSeconds (Get-UrgentFloorSeconds)
        $effectiveField = if ($spec.Field -eq 'IntervalSeconds') { 'HoldSeconds' } else { $spec.Field }
        $text += "`nالقيمة الفعلية: $(Get-UrgentProperty $effective $effectiveField 0)"
        if ($spec.Field -eq 'IntervalSeconds' -and $effective.IntervalRaisedToFloor) {
            $text += "`n⚠️ رُفع الفاصل إلى $($effective.HoldSeconds) ث: أقصر ممّا يسمح به المشهد."
        }
    }
    $prefix = "urgentb:num:$($State.Token)"
    $rows = @()
    $rows += , @((New-Button '−10' "${prefix}:-10"), (New-Button '−5' "${prefix}:-5"), (New-Button '−1' "${prefix}:-1"))
    $rows += , @((New-Button '+1' "${prefix}:+1"), (New-Button '+5' "${prefix}:+5"), (New-Button '+10' "${prefix}:+10"))
    if ($spec.Maximum -gt 99) { $rows += , @((New-Button '−60' "${prefix}:-60"), (New-Button '+60' "${prefix}:+60")) }
    $minLabel = if ($spec.Minimum -eq 0) { "↩️ $($spec.Zero)" } else { "الأدنى: $($spec.Minimum)" }
    $rows += , @((New-Button $minLabel "${prefix}:min"), (New-Button "الأقصى: $($spec.Maximum)" "${prefix}:max"))
    $rows += , @((New-Button '✅ تمّ / رجوع' "${prefix}:done"))
    $keyboard = @{ inline_keyboard = $rows }
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard
}

function Start-UrgentNumberPicker {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0,
        [Parameter(Mandatory)][ValidateSet('interval', 'repeats', 'dinterval', 'drepeats', 'dtotal')][string]$Kind,
        [int]$Position = -1, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    $spec = Get-UrgentNumberSpec -Kind $Kind
    $itemId = ''
    if (-not $spec.Setting) {
        $item = Get-UrgentItemByPosition -Position $Position
        if (-not $item) { Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId; return }
        $itemId = [string](Get-UrgentProperty $item 'Id' '')
    }
    # The short nonce rejects older keyboards; the saved id, not the displayed
    # position, keeps repeated taps on the same item after a concurrent move.
    $state = @{ Mode = 'urgent_number_picker'; Kind = $Kind; ItemId = $itemId; UserId = $UserId
        Token = [guid]::NewGuid().ToString('N').Substring(0, 12); StartedAt = (Get-Date) }
    Set-PendingState -ChatId $ChatId -State $state
    Show-UrgentNumberPicker -ChatId $ChatId -State $state -MessageId $MessageId
}

function Invoke-UrgentNumberPick {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Argument, [int]$MessageId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string](Get-JsonProp $state 'Mode') -ne 'urgent_number_picker' -or
        [long](Get-JsonProp $state 'UserId') -ne $UserId -or
        $Argument -notmatch '^([a-f0-9]{12}):(done|min|max|[+-](?:1|5|10|60))$' -or
        $Matches[1] -cne [string](Get-JsonProp $state 'Token')) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ انتهت صلاحية هذه الأزرار. افتح شاشة الرقم من جديد.'
        return $false
    }
    $operation = $Matches[2]
    $spec = Get-UrgentNumberSpec -Kind $state.Kind
    $item = $null
    if (-not $spec.Setting) {
        $item = Get-UrgentItem -Board $script:UrgentBoard -ItemId $state.ItemId
        if (-not $item) { Clear-PendingState -ChatId $ChatId; Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId; return $false }
    }
    if ($operation -eq 'done') {
        Clear-PendingState -ChatId $ChatId
        if ($spec.Setting) { Show-UrgentTimingScreen -ChatId $ChatId -MessageId $MessageId }
        else { Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId -MessageId $MessageId }
        return $true
    }
    $current = if ($spec.Setting) { Get-SettingInt $spec.Setting ([int]$script:DefaultSettings[$spec.Setting]) } else { [int](Get-UrgentProperty $item $spec.Field 0) }
    $base = $current
    if ($item -and $current -eq 0 -and $operation -notin @('min', 'max')) {
        $base = [int](Get-UrgentProperty (Get-UrgentEffectiveTiming -Item $item -Defaults (Get-UrgentBoardDefaults)) $spec.Field 0)
    }
    $target = switch ($operation) {
        'min' { $spec.Minimum }
        'max' { $spec.Maximum }
        default { $base + [int]$operation }
    }
    $target = [math]::Max([int]$spec.Minimum, [math]::Min([int]$spec.Maximum, [int]$target))
    $saved = $true
    if ($target -ne $current) {
        if ($spec.Setting) { $saved = Set-UrgentBoardSetting -ChatId $ChatId -Name $spec.Setting -Value $target }
        else {
            $result = Set-UrgentItem -Board $script:UrgentBoard -ItemId $state.ItemId -Field $spec.Field -Value $target -UserId $UserId
            $saved = Invoke-UrgentEdit -Result $result -ChatId $ChatId
        }
    }
    $state.StartedAt = Get-Date
    Show-UrgentNumberPicker -ChatId $ChatId -State $state -MessageId $MessageId
    return $saved
}

# ------------------------------------------------------------- typed input

function Complete-UrgentBoardText {
    <#
        Everything the board asks an operator to type, in one place.

        A flag is cleared before the value is used, not after: a pending state
        left standing on a refused value would swallow the operator's next
        message too.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Value = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return $false }
    $mode = [string]$state.Mode
    $position = if ($state.ContainsKey('Position')) { [int]$state.Position } else { -1 }
    Clear-PendingState -ChatId $ChatId
    $board = $script:UrgentBoard
    $savedItemId = [string](Get-JsonProp $state 'ItemId')
    $item = if ($savedItemId) { Get-UrgentItem -Board $board -ItemId $savedItemId }
        elseif ($mode -in @('urgent_item_interval', 'urgent_item_repeats') -and $position -ge 0) { Get-UrgentItemByPosition -Position $position }
        else { $null }
    $itemId = if ($item) { [string](Get-UrgentProperty $item 'Id' '') } else { '' }
    $maxLength = Get-SettingInt 'UrgentBoardMaxTextLength' 300
    $result = $null
    switch ($mode) {
        'urgent_add_text' {
            $result = Add-UrgentItem -Board $board -Text $Value -MaxItems (Get-SettingInt 'UrgentBoardMaxItems' 40) -MaxLength $maxLength -UserId $UserId
        }
        'urgent_item_text' {
            if (-not $itemId) { break }
            $result = Set-UrgentItem -Board $board -ItemId $itemId -Field Text -Value $Value -MaxLength $maxLength -UserId $UserId
        }
        'urgent_item_title' {
            if (-not $itemId) { break }
            $result = Set-UrgentItem -Board $board -ItemId $itemId -Field Title -Value $Value -MaxLength $maxLength -UserId $UserId
        }
        'urgent_item_interval' {
            if (-not $itemId) { break }
            $result = Set-UrgentItem -Board $board -ItemId $itemId -Field IntervalSeconds -Value $Value -UserId $UserId
        }
        'urgent_item_repeats' {
            if (-not $itemId) { break }
            $result = Set-UrgentItem -Board $board -ItemId $itemId -Field Repeats -Value $Value -UserId $UserId
        }
        # The table's own numbers are settings, so they are written through
        # Set-Setting and answered on the timing screen rather than the board.
        'urgent_default_interval' {
            $saved = Set-UrgentBoardSetting -ChatId $ChatId -Name 'UrgentBoardIntervalSeconds' -Value $Value
            Show-UrgentTimingScreen -ChatId $ChatId
            return $saved
        }
        'urgent_default_repeats' {
            $saved = Set-UrgentBoardSetting -ChatId $ChatId -Name 'UrgentBoardRepeats' -Value $Value
            Show-UrgentTimingScreen -ChatId $ChatId
            return $saved
        }
        'urgent_default_total' {
            $saved = Set-UrgentBoardSetting -ChatId $ChatId -Name 'UrgentBoardTotalSeconds' -Value $Value
            Show-UrgentTimingScreen -ChatId $ChatId
            return $saved
        }
        default { return $false }
    }
    if (-not $result) {
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ العاجل غير موجود.' -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    if (-not (Invoke-UrgentEdit -Result $result -ChatId $ChatId)) { return $false }
    if ($position -ge 0) {
        Show-UrgentItemScreen -ChatId $ChatId -Position $position
        return $true
    }
    Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId
    return $true
}
