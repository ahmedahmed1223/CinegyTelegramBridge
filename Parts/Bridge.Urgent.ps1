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

function Test-UrgentTitleSupported {
    <#
        Whether this scene has anywhere to put a title.

        Get-UrgentItemVariables maps values by POSITION, not by name: the
        scene's first declared field carries the line and the second carries
        the title. A scene that declares one field - which is how a plain
        breaking strap is usually built - therefore drops the title on the
        floor, silently, at the moment the values are built.

        Everything else about the title worked: it was stored, it survived a
        restart, it appeared on the item card with its 🏷, and it counted as a
        change. Only the part that matters was missing, and nothing said so.
        Asked when the screen is drawn, like Test-UrgentSceneLoop below, so the
        operator learns it before typing a title rather than after wondering
        why it never showed.
    #>
    $template = Get-UrgentTemplate
    if (-not $template) { return $false }
    return (@(Get-JsonProp $template 'Fields').Count -gt 1)
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
    <# What an exit-mode line costs before it is visible: the outro plays, the
       station's chosen blank gap passes, then the entrance. The scene part is
       read from the scene, so re-cutting it in Titler re-times the board with
       nothing to update here; the gap is the one part a person chooses.

       The gap belongs in this number and not only in the engine: the plan
       measures every line's moment from it, and the floor under an interval
       comes from it. A gap the arithmetic did not know about would put the
       next line's moment inside its own blank period. #>
    $gap = [math]::Max(0.0, [double](Get-SettingInt 'UrgentExitGapSeconds' 0))
    $timing = Get-UrgentSceneTiming
    if (-not $timing) { return [math]::Round($gap, 3) }
    return [math]::Round([double](Get-JsonProp $timing 'OutroSeconds') + [double](Get-JsonProp $timing 'IntroSeconds') + $gap, 3)
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
        if (-not $Quiet) { Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.saveFailed') }
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
        return (T 'urg.templateCeiling')
    }
    return (T 'urg.sensitiveAutoHide')
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
        $result.Value.Notes = @($result.Value.Notes | ForEach-Object { $_.Replace((T 'urg.sensitiveAutoHide'), $label) })
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
    if ($Mode -eq 'exit') { return (T 'urgent.mode.exit') }
    if ($Mode -eq 'auto_hide') { return (T 'urgent.mode.autoHide') }
    return (T 'urgent.mode.text')
}

function Get-UrgentBoardPageSize {
    return [math]::Max(1, [math]::Min(10, (Get-SettingInt 'NewsListPageSize' 8)))
}

function Get-UrgentBoardFilter {
    param([Parameter(Mandatory)][long]$ChatId)
    $value = if ($script:UrgentBoardFilters.ContainsKey([string]$ChatId)) {
        [string]$script:UrgentBoardFilters[[string]$ChatId]
    } else { 'all' }
    if ($value -notin @('all', 'ready', 'selected', 'air', 'disabled', 'latest')) { return 'all' }
    return $value
}

function Set-UrgentBoardFilter {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Filter)
    if ($Filter -notin @('all', 'ready', 'selected', 'air', 'disabled', 'latest')) { return $false }
    if ($PSCmdlet.ShouldProcess("chat $ChatId", "set urgent board filter to $Filter")) {
        $script:UrgentBoardFilters[[string]$ChatId] = $Filter
    }
    return $true
}

function Get-UrgentCurrentItemId {
    $template = Get-UrgentTemplate
    if (-not $template) { return '' }
    if ($script:UrgentBoardRun) {
        $steps = @(Get-JsonProp $script:UrgentBoardRun 'Steps')
        $step = [int](Get-JsonProp $script:UrgentBoardRun 'Step')
        if ($step -ge 0 -and $step -lt $steps.Count) {
            return [string](Get-JsonProp $steps[$step] 'Id')
        }
    }
    foreach ($entry in @($script:UrgentManualLive.Values)) {
        if ([int](Get-UrgentProperty $entry 'Layer' 0) -eq [int]$template.Layer) {
            return [string](Get-JsonProp $entry 'ItemId')
        }
    }
    return ''
}

function Test-UrgentItemOnAir {
    param([Parameter(Mandatory)]$Item)
    $id = [string](Get-JsonProp $Item 'Id')
    return $id -and $id -ceq (Get-UrgentCurrentItemId)
}

function Get-UrgentItemStateLabel {
    param([Parameter(Mandatory)]$Item, [string[]]$Selected = @())
    $id = [string](Get-JsonProp $Item 'Id')
    if (-not [bool](Get-UrgentProperty $Item 'Enabled' $true)) { return (T 'urgent.state.disabled') }
    if (Test-UrgentItemOnAir -Item $Item) { return (T 'urgent.state.onAir') }
    if ($Selected -contains $id) { return (T 'urgent.state.selected') }
    return (T 'urgent.state.ready')
}

function Get-UrgentVisibleItems {
    param([Parameter(Mandatory)][long]$ChatId)
    $items = @(Get-UrgentProperty $script:UrgentBoard 'Items' @())
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    $filter = Get-UrgentBoardFilter -ChatId $ChatId
    if ($filter -eq 'all') { return $items }
    if ($filter -eq 'latest') {
        return @($items | Sort-Object {
                $stamp = [datetimeoffset]::MinValue
                [datetimeoffset]::TryParse([string](Get-UrgentProperty $_ 'UpdatedAt' ''), [ref]$stamp) | Out-Null
                $stamp
            } -Descending)
    }
    return @($items | Where-Object {
        $enabled = [bool](Get-UrgentProperty $_ 'Enabled' $true)
        $isSelected = $selected -contains [string](Get-JsonProp $_ 'Id')
        $onAir = Test-UrgentItemOnAir -Item $_
        switch ($filter) {
            'ready' { $enabled -and -not $onAir }
            'selected' { $isSelected }
            'air' { $onAir }
            'disabled' { -not $enabled }
        }
    })
}

function Get-UrgentRelativeTime {
    param([object]$Value)
    $when = [datetimeoffset]::MinValue
    if (-not $Value -or -not [datetimeoffset]::TryParse([string]$Value, [ref]$when)) { return (T 'urgent.updatedUnknown') }
    # 0.0, not 0: [math]::Max(0, <double>) binds the Int32 overload, which
    # rounds the seconds instead of clamping them - and throws outright on an
    # UpdatedAt far enough from now to overflow an Int32, taking the whole
    # board screen with it. The trap is in the AGENTS.md table and this was its
    # last site in the tree.
    $seconds = [math]::Max(0.0, ([datetimeoffset]::Now - $when).TotalSeconds)
    if ($seconds -lt 60) { return (T 'urgent.lessThanMinute') }
    if ($seconds -lt 3600) { return (T 'urg.minutesAgo' $([int][math]::Floor($seconds / 60))) }
    if ($seconds -lt 86400) { return (T 'urg.hoursAgo' $([int][math]::Floor($seconds / 3600))) }
    return (T 'urg.daysAgo' $([int][math]::Floor($seconds / 86400)))
}

function Get-UrgentBoardSummary {
    param([Parameter(Mandatory)][long]$ChatId)
    $items = @(Get-UrgentProperty $script:UrgentBoard 'Items' @())
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    $enabled = @($items | Where-Object { [bool](Get-UrgentProperty $_ 'Enabled' $true) })
    $disabled = $items.Count - $enabled.Count
    $onAir = 0
    foreach ($summaryItem in $items) {
        if (Test-UrgentItemOnAir -Item $summaryItem) { $onAir++ }
    }
    return (T 'urg.counts' $($items.Count) $($enabled.Count - $onAir) $onAir $disabled $($selected.Count))
}

function Get-UrgentBoardKeyboard {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Page = 0)
    $items = @(Get-UrgentVisibleItems -ChatId $ChatId)
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize (Get-UrgentBoardPageSize)
    $manual = $script:UrgentManualMode.ContainsKey($ChatId) -and [bool]$script:UrgentManualMode[$ChatId]
    $rows = @()
    $filter = Get-UrgentBoardFilter -ChatId $ChatId
    $filterLabel = switch ($filter) {
        'ready' { (T 'urgent.filter.ready') }; 'selected' { (T 'urgent.filter.selected') }; 'air' { (T 'urgent.filter.onAir') };         'disabled' { (T 'urgent.filter.disabled') }; 'latest' { (T 'urgent.filter.newest') }; default { (T 'urgent.filter.all') }
    }
    $rows += , @((New-Button "📊 $filterLabel — $([string](Get-UrgentBoardSummary -ChatId $ChatId))" 'urgentb:noop'))
    $rows += , @((New-Button (T 'urgent.filter.section') 'urgentb:noop'))
    $rows += , @(
        (New-Button (T 'urgent.filter.all') 'urgentb:filter:all' -Style $(if ($filter -eq 'all') { 'primary' } else { '' }))
        (New-Button (T 'urgent.state.ready') 'urgentb:filter:ready' -Style $(if ($filter -eq 'ready') { 'primary' } else { '' }))
        (New-Button (T 'urgent.state.onAir') 'urgentb:filter:air' -Style $(if ($filter -eq 'air') { 'primary' } else { '' }))
    )
    $rows += , @(
        (New-Button (T 'urgent.state.selected') 'urgentb:filter:selected' -Style $(if ($filter -eq 'selected') { 'primary' } else { '' }))
        (New-Button (T 'urgent.state.disabled') 'urgentb:filter:disabled' -Style $(if ($filter -eq 'disabled') { 'primary' } else { '' }))
        (New-Button (T 'urgent.filter.newestButton') 'urgentb:filter:latest' -Style $(if ($filter -eq 'latest') { 'primary' } else { '' }))
    )
    # Telegram has no divider or disabled-button primitive in InlineKeyboardMarkup.
    # A noop row is the compatible visual separator; its callback is answered
    # immediately so tapping the rule never leaves a loading spinner.
    $rows += , @((New-Button '━━━━━━━━━━━━━━━━' 'urgentb:noop'))

    # Mode selector — single button toggles between manual and auto
    $rows += , @((New-Button (T 'urg.manualMode' $(if($manual){'✅ '})) 'urgmode:manual'), (New-Button (T 'urg.autoMode' $(if(-not $manual){'✅ '})) 'urgmode:auto'))

    # T-12: كل تحذير يحمل زر حلّه
    if (-not (Test-UrgentSceneLoop)) {
        $rows += , @( (New-Button (T 'urgent.noLoopFixNow') 'urgentb:timing' -Style primary) )
    }
    $ceiling = Get-UrgentRunCeiling -Items $items
    if ([int]$ceiling.AutoHideSeconds -gt 0) {
        $rows += , @( (New-Button (T 'urg.autoHideAfter' $($ceiling.AutoHideSeconds)) 'urgentb:timing' -Style primary) )
    }

    if ($items.Count -gt 0) {
        $rows += , @((New-Button (T 'urgent.rowsDivider') 'urgentb:noop'))
        for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $item = $items[$index]
            $id = [string](Get-UrgentProperty $item 'Id' '')
            $tick = if ($selected -contains $id) { '☑' } else { '☐' }
            $text = [string](Get-UrgentProperty $item 'Text' '')
            $label = if ($text.Length -gt 30) { $text.Substring(0, 29) + '…' } else { $text }
            $enabled = [bool](Get-UrgentProperty $item 'Enabled')
            $onAir = Test-UrgentItemOnAir -Item $item
            $stateMark = (Get-UrgentItemStateLabel -Item $item -Selected $selected).Substring(0, 2).Trim()

            # Story text on its own row (full-width, Mojaz style)
            $rowStyle = if (-not $enabled) { 'danger' } elseif ($selected -contains $id) { 'primary' } else { $null }
            $rows += , @((New-Button "$stateMark $tick $($index + 1). $label · $(Get-UrgentRelativeTime (Get-JsonProp $item 'UpdatedAt'))" "urgentb:pick:$id" -Style $rowStyle))

            # Action buttons below: read + settings
            $actionRow = @(
                (New-Button (T 'urgent.read') "urgread:${id}:0")
                (New-Button (T 'urgent.actions') "urgentb:item:$id")
            )
            if ($selected -contains $id -and -not $onAir -and $enabled) {
                $actionRow += (New-Button (T 'urgent.runOnAir') "urgsingle:$id" -Style success)
            }
            $rows += , $actionRow
            if ($onAir) {
                $rows += , @((New-Button (T 'urgent.stopCurrent') 'urgentb:hide' -Style danger))
            }
        }
    }
    if ($window.PageCount -gt 1) {
        $nav = @()
        if ($window.HasPrevious) { $nav += (New-Button (T 'common.previous') "urgentb:page:$($window.Page - 1)") }
        $nav += (New-Button "$($window.Page + 1)/$($window.PageCount)" 'urgentb:noop')
        if ($window.HasNext) { $nav += (New-Button (T 'common.next') "urgentb:page:$($window.Page + 1)") }
        $rows += , $nav
    }
    # Table-level controls
    $rows += , @(
        (New-Button (T 'urgent.add') 'urgentb:add')
        (New-Button (T 'urgent.selectAll') "urgentb:all:$($window.Page)")
        (New-Button (T 'urgent.clearSelection') "urgentb:none:$($window.Page)")
    )
    $rows += , @(
        (New-Button (T 'urgent.timings') 'urgentb:timing')
        (New-Button (T 'urgent.deleteSelected') 'urgentb:delask' -Style danger)
    )
    # Play only where there is something to play and nothing already playing.
    if ($script:UrgentBoardRun) {
        if ([bool](Get-JsonProp $script:UrgentBoardRun 'StopFailed')) {
            $rows += , @( (New-Button (T 'urgent.retryStop') 'urgentb:stop' -Style danger) )
        }
        else {
            $rows += , @( (New-Button (T 'urgent.stopRun') 'urgentb:stop' -Style danger) )
            if ([bool](Get-JsonProp $script:UrgentBoardRun 'Paused')) {
                $pauseButton = New-Button (T 'urgent.resume') 'urgentb:resume'
            }
            else { $pauseButton = New-Button (T 'urgent.pause') 'urgentb:pause' }
            $rows += , @( (New-Button (T 'urgent.skipCurrent') 'urgentb:skip'), $pauseButton )
        }
    }
    elseif ($items.Count -gt 0 -and -not $manual) {
        $playRow = @()
        if ($selected.Count -gt 0) { $playRow += (New-Button (T 'urg.playChosen' $($selected.Count)) 'urgentb:review:sel' -Style success) }
        $playRow += (New-Button (T 'urgent.playAll') 'urgentb:review:all' -Style success)
        $rows += , $playRow
        $rows += , @((New-Button (T 'urgent.playNextReady') 'urgentb:next' -Style success))
    }
    $rows += , @( (New-Button (T 'urg.refresh') 'urgentb:open'), (New-Button (T 'adm.menu') 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Get-UrgentRunStatusText {
    if (-not $script:UrgentBoardRun) { return '' }
    $run = $script:UrgentBoardRun
    $failed = [bool](Get-JsonProp $run 'StopFailed')
    $status = if ($failed) { (T 'urgent.stopUnconfirmed') }
        elseif ([bool](Get-JsonProp $run 'Paused')) { (T 'urgent.pausedNote') }
        else { (T 'urgent.running') }
    $steps = @(Get-JsonProp $run 'Steps')
    $position = [int](Get-JsonProp $run 'Step')
    $lines = @($status)
    if ($position -ge 0 -and $position -lt $steps.Count) {
        $lines += (T 'urg.headlineOf' $($position + 1) $($steps.Count))
        # Read the immutable run snapshot, not the board being edited meanwhile.
        $current = [string](Get-JsonProp $steps[$position] 'Text')
        if ($current.Length -gt 120) { $current = $current.Substring(0, 119) + '…' }
        $lines += (T 'urg.current' $current)
        if ($position + 1 -lt $steps.Count) {
            $next = [string](Get-JsonProp $steps[$position + 1] 'Text')
            if ($next.Length -gt 120) { $next = $next.Substring(0, 119) + '…' }
            $lines += (T 'urg.next' $next)
        }
        else { $lines += (T 'urgent.nextEnd') }
    }
    return ($lines -join "`n")
}

function Get-UrgentBoardBlocks {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Page = 0)
    $board = $script:UrgentBoard
    $defaults = Get-UrgentBoardDefaults
    $items = @(Get-UrgentVisibleItems -ChatId $ChatId)
    $allItems = @(Get-UrgentProperty $board 'Items' @())
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    $blocks = @(@{ type = 'heading'; text = (T 'urg.title' $($allItems.Count)); size = 3 })
    $blocks += @{ type = 'paragraph'; text = (T 'urg.filter' $(Get-UrgentBoardSummary -ChatId $ChatId) $(Get-UrgentBoardFilter -ChatId $ChatId)) }
    $runStatus = Get-UrgentRunStatusText
    if ($runStatus) { $blocks += @{ type = 'paragraph'; text = $runStatus } }

    $order = if ([string](Get-UrgentProperty $defaults 'RepeatMode' 'cycle') -eq 'item') { (T 'urg.pairPattern') } else { (T 'urg.roundPattern') }
    $total = [int](Get-UrgentProperty $defaults 'TotalSeconds' 0)
    $totalText = if ($total -gt 0) { (T 'urg.seconds' $total) } else { (T 'urgent.noCeiling') }
    $blocks += @{ type = 'paragraph'; text = (T 'urg.defaults' $(Get-UrgentModeLabel -Mode ([string](Get-UrgentProperty $defaults 'Mode' 'text'))) $([int](Get-UrgentProperty $defaults 'IntervalSeconds' 8)) $([int](Get-UrgentProperty $defaults 'Repeats' 1)) $order $totalText) }

    # Said on the board, not only when a run is refused: an operator writing
    # lines in a mode this scene cannot hide should find out now.
    if (-not (Test-UrgentSceneLoop)) {
        $blocks += @{ type = 'paragraph'; text = (T 'urgent.noLoopUseExit') }
    }
    $ceiling = Get-UrgentRunCeiling -Items $items
    if ([int]$ceiling.AutoHideSeconds -gt 0) {
        $blocks += @{ type = 'paragraph'; text = (T 'urg.autoHideWarning' $(Get-UrgentAutoHideLabel -Seconds $ceiling.AutoHideSeconds) $([int]$ceiling.AutoHideSeconds)) }
    }

    if ($items.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = (T 'urgent.emptyPress') }
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
        $blocks += @{ type = 'paragraph'; text = (T 'urg.showing' $($window.StartIndex + 1) $($window.EndIndex + 1) $($window.Page + 1) $($window.PageCount)) }
    }
    $cells = @(, @(
            @{ text = '#'; is_header = $true }
            @{ text = (T 'urgent.col.item'); is_header = $true }
            @{ text = (T 'urgent.col.mode'); is_header = $true }
            @{ text = (T 'urgent.col.interval'); is_header = $true }
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
        $interval = if ($timing.IntervalInherited) { (T 'urg.seconds' $($timing.HoldSeconds)) } else { (T 'urg.secondsStar' $($timing.HoldSeconds)) }
        $cells += , @(@{ text = "$mark $position" }, @{ text = $shown }, @{ text = $mode }, @{ text = $interval })
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $note = Get-RichTableTrimNote -Hidden ([int]$trimmed.Hidden) -Shown (@($trimmed.Rows).Count)
    if ($note) { $blocks += @{ type = 'paragraph'; text = $note } }
    $blocks += @{ type = 'paragraph'; text = (T 'urgent.legend') }
    return $blocks
}

function Get-UrgentBoardText {
    <# The fallback every rich screen owes its reader. Same facts, no table. #>
    param([Parameter(Mandatory)][long]$ChatId, [int]$Page = 0)
    $board = $script:UrgentBoard
    $defaults = Get-UrgentBoardDefaults
    $items = @(Get-UrgentVisibleItems -ChatId $ChatId)
    $allItems = @(Get-UrgentProperty $board 'Items' @())
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    $lines = @((T 'urg.titleHtml' $($allItems.Count)))
    $lines += (ConvertTo-TelegramHtmlText -Text (T 'urg.filter' $(Get-UrgentBoardSummary -ChatId $ChatId) $(Get-UrgentBoardFilter -ChatId $ChatId)))
    $runStatus = Get-UrgentRunStatusText
    if ($runStatus) { $lines += (ConvertTo-TelegramHtmlText -Text $runStatus) }
    $lines += (T 'urg.defaultsShort' $([int](Get-UrgentProperty $defaults 'IntervalSeconds' 8)) $([int](Get-UrgentProperty $defaults 'Repeats' 1)))
    if (-not (Test-UrgentSceneLoop)) { $lines += (T 'urgent.noLoopShort') }
    $ceiling = Get-UrgentRunCeiling -Items $items
    if ([int]$ceiling.AutoHideSeconds -gt 0) {
        $lines += (T 'urg.autoHideWarning' $(Get-UrgentAutoHideLabel -Seconds $ceiling.AutoHideSeconds) $([int]$ceiling.AutoHideSeconds))
    }
    if ($items.Count -eq 0) {
        $lines += (T 'urgent.empty')
        return ($lines -join "`n")
    }
    $window = Get-BridgePageWindow -ItemCount $items.Count -Page $Page -PageSize (Get-UrgentBoardPageSize)
    $trimmed = Select-RichTableRows -Items @($items[$window.StartIndex..$window.EndIndex])
    if ($window.PageCount -gt 1) {
        $lines += (T 'urg.showing' $($window.StartIndex + 1) $($window.EndIndex + 1) $($window.Page + 1) $($window.PageCount))
    }
    $position = $window.StartIndex
    foreach ($item in @($trimmed.Rows)) {
        $position++
        $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults -FloorSeconds (Get-UrgentFloorSeconds)
        $tick = if ($selected -contains [string](Get-UrgentProperty $item 'Id' '')) { '☑' } else { '☐' }
        $mark = (Get-UrgentItemStateLabel -Item $item -Selected $selected).Split(' ')[0]
        $mode = if ($timing.Mode -eq 'exit') { '🚪' } elseif ($timing.Mode -eq 'auto_hide') { '🙈' } else { '✏️' }
        # Escaped because a breaking line is text somebody typed, and this
        # message is sent as HTML.
        $safe = ConvertTo-TelegramHtmlText -Text ([string](Get-UrgentProperty $item 'Text' ''))
        $lines += (T 'urg.row' $mark $tick $position $mode $safe $($timing.HoldSeconds) $(Get-UrgentRelativeTime (Get-JsonProp $item 'UpdatedAt')))
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
    if (-not $item) { return @{ inline_keyboard = @(, @( (New-Button (T 'urgent.back') 'urgentb:open') )) } }
    $defaults = Get-UrgentBoardDefaults
    $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults -FloorSeconds (Get-UrgentFloorSeconds)
    $itemId = [string](Get-UrgentProperty $item 'Id' '')
    if (Test-UrgentItemOnAir -Item $item) {
        $rows += , @( (New-Button (T 'urgent.liveNow') 'urgentb:noop' -Style primary), (New-Button (T 'urgent.stopThis') 'urgentb:hide' -Style danger) )
    }
    else {
        $rows += , @( (New-Button (T 'urgent.runOnAir') "urgsingle:$itemId" -Style success) )
    }
    # The title button is offered only where the scene can carry one - or where
    # a title is already stored, so one written before the scene was simplified
    # can still be cleared. A control that cannot do the thing it names is
    # worse than a missing one: it is a promise the screen does not keep.
    $textRow = @( (New-Button (T 'urgent.editText') "urgentb:text:$itemId") )
    if ((Test-UrgentTitleSupported) -or [string](Get-UrgentProperty $item 'Title' '')) {
        $textRow += (New-Button (T 'urgent.title') "urgentb:title:$itemId")
    }
    $rows += , $textRow
    $modeRow = @( (New-Button (T 'urgent.displayMode') "urgentb:mode:$itemId") )
    if (-not $timing.ModeInherited) { $modeRow += (New-Button (T 'urgent.fromBoard') "urgentb:modereset:$itemId") }
    $rows += , $modeRow
    $intervalRow = @( (New-Button (T 'urg.gap' $($timing.IntervalSeconds)) "urgentb:interval:$itemId") )
    if (-not $timing.IntervalInherited) { $intervalRow += (New-Button (T 'urgent.fromBoard') "urgentb:intervalreset:$itemId") }
    $rows += , $intervalRow
    $repeatRow = @( (New-Button (T 'urg.repeat' $($timing.Repeats)) "urgentb:repeats:$itemId") )
    if (-not $timing.RepeatsInherited) { $repeatRow += (New-Button (T 'urgent.fromBoard') "urgentb:repeatsreset:$itemId") }
    $rows += , $repeatRow
    $enabled = [bool](Get-UrgentProperty $item 'Enabled' $true)
    $toggle = if ($enabled) { (T 'urgent.disable') } else { (T 'urgent.enable') }
    $rows += , @( (New-Button $toggle "urgentb:enable:$itemId"), (New-Button (T 'common.delete') "urgentb:itemdel:$itemId" -Style danger) )
    $rows += , @( (New-Button (T 'urgent.moveUp') "urgentb:up:$itemId"), (New-Button (T 'urgent.moveDown') "urgentb:down:$itemId") )
    $boardPage = [int][math]::Floor($Position / (Get-UrgentBoardPageSize))
    $rows += , @( (New-Button (T 'urgent.back') "urgentb:page:$boardPage") )
    return @{ inline_keyboard = $rows }
}

function Get-UrgentLiveStamp {
    param([int]$Layer)
    if (-not $script:OnAir.ContainsKey($Layer)) { return '' }
    $live = $script:OnAir[$Layer]
    # Serialize the original timestamp without dropping sub-second precision.
    $at = Get-JsonProp $live 'At'
    $when = if ($at -is [datetime] -or $at -is [datetimeoffset]) { $at.ToString('o') } else { [string]$at }
    return (@([string](Get-JsonProp $live 'Key'),[string](Get-JsonProp $live 'ActiveId'),$when) | ConvertTo-Json -Compress)
}

function Show-UrgentManualConfirm {
    param([long]$ChatId, [long]$UserId, [string]$ItemId, [int]$MessageId = 0)
    if (-not (Test-Authorized -ChatId $ChatId -UserId $UserId)) { return }
    $item = @(Get-UrgentProperty $script:UrgentBoard 'Items' @()) | Where-Object { [string](Get-JsonProp $_ 'Id') -ceq $ItemId } | Select-Object -First 1
    $template = Get-UrgentTemplate
    if (-not $template -or -not $item -or -not [bool](Get-JsonProp $item 'Enabled')) { return }
    $state = @{ Mode='urgent_manual_confirm'; Token=[guid]::NewGuid().ToString('N').Substring(0,12)
        UserId=$UserId; StartedAt=Get-Date; ItemId=$ItemId; Layer=[int]$template.Layer
        Key=[string]$template.Key; Text=[string](Get-JsonProp $item 'Text'); Title=[string](Get-JsonProp $item 'Title')
        LiveStamp=(Get-UrgentLiveStamp -Layer ([int]$template.Layer)); HadRun=[bool]$script:UrgentBoardRun }
    Set-PendingState -ChatId $ChatId -State $state | Out-Null
    $text = "$(T urgent.manualSingle)`n$(T urgent.manualRules)"
    if ($state.LiveStamp) {
        $currentId = Get-UrgentCurrentItemId
        $currentItem = @(Get-UrgentProperty $script:UrgentBoard 'Items' @()) |
            Where-Object { [string](Get-JsonProp $_ 'Id') -ceq $currentId } | Select-Object -First 1
        $currentText = if ($currentItem) { [string](Get-UrgentProperty $currentItem 'Text' '') } else { (T 'urgent.sceneUnknown') }
        if ($currentText.Length -gt 120) { $currentText = $currentText.Substring(0, 119) + '…' }
        $text += (T 'urg.willReplaceHeadline' $currentText $($state.Text))
    }
    if ($state.HadRun) { $text += (T 'urg.boardStopsFirst') }
    $manualHide = Get-SettingInt 'UrgentManualAutoHideSeconds' 0
    if ($manualHide -gt 0) { $text += "`n" + (T 'air.autoHideAfter' $(Format-DurationSeconds -Seconds $manualHide)) }
    if (-not $state.LiveStamp) { $text += "`n`n$($state.Text)" }
    if ($text.Length -gt 3900) { $text = $text.Substring(0,3800) + (T 'urg.readFullText') }
    $markup = @{ inline_keyboard = @(
        , @((New-Button (T 'urgent.showThisOne') "urgmanual:show:$($state.Token)" -Style success))
        , @((New-Button (T 'urgent.backNoShow') "urgread:${ItemId}:0"))
    ) }
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $markup)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $markup
}

function Invoke-UrgentManualAction {
    param([long]$ChatId, [long]$UserId, [string]$Argument)
    if (-not (Test-Authorized -ChatId $ChatId -UserId $UserId) -or
        -not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId) -or
        $Argument -notmatch '^(show|hide):([a-f0-9]{12})$') { return $false }
    $action = $Matches[1]; $token = $Matches[2]
    $state = if ($action -eq 'hide') { $script:UrgentManualLive[$ChatId] } else { Get-PendingState -ChatId $ChatId }
    if (-not $state -or [long](Get-JsonProp $state 'UserId') -ne $UserId -or
        [string](Get-JsonProp $state 'Token') -cne $token) { return $false }
    if ($action -eq 'hide') {
        if ([string](Get-JsonProp $state 'Mode') -ne 'urgent_manual_live' -or
            [string]$state.LiveStamp -cne (Get-UrgentLiveStamp -Layer ([int]$state.Layer))) { return $false }
        $liveKey = [string](Get-JsonProp $script:OnAir[[int]$state.Layer] 'Key')
        if (-not (Test-TemplateAccess -Key $liveKey -Layer ([int]$state.Layer) -ChatId $ChatId -UserId $UserId).Allowed) { return $false }
        if (-not (Invoke-HideLayer -Layer ([int]$state.Layer) -ChatId $ChatId -UserId $UserId)) { return $false }
        $script:UrgentManualLive.Remove($ChatId) | Out-Null
        Save-UrgentManualState | Out-Null
        return $true
    }

    if ([string](Get-JsonProp $state 'Mode') -ne 'urgent_manual_confirm') { return $false }
    $item = @(Get-UrgentProperty $script:UrgentBoard 'Items' @()) | Where-Object { [string](Get-JsonProp $_ 'Id') -ceq $state.ItemId } | Select-Object -First 1
    $template = Get-UrgentTemplate
    if (-not $item -or -not $template -or -not [bool](Get-JsonProp $item 'Enabled') -or
        [string](Get-JsonProp $item 'Text') -cne $state.Text -or [string](Get-JsonProp $item 'Title') -cne $state.Title -or
        [int]$template.Layer -ne [int]$state.Layer -or [string]$template.Key -cne $state.Key -or
        $state.LiveStamp -cne (Get-UrgentLiveStamp -Layer ([int]$state.Layer)) -or
        [bool]$state.HadRun -ne [bool]$script:UrgentBoardRun) { return $false }
    $access = Test-TemplateAccess -Key ([string]$template.Key) -Layer ([int]$template.Layer) -ChatId $ChatId -UserId $UserId
    $policy = Test-TemplateShowPolicy -Key ([string]$template.Key) -Layer ([int]$template.Layer) -IsAdmin:(Test-Admin -ChatId $ChatId -UserId $UserId)
    if (-not $access.Allowed -or -not $policy.Allowed) { return $false }
    # Consume confirmation BEFORE any air command; retry requires a fresh review.
    Clear-PendingState -ChatId $ChatId
    if ($script:UrgentBoardRun -and -not (Stop-UrgentBoardRun -ChatId $ChatId -UserId $UserId -Quiet)) { return $false }
    # The board's own auto-hide, or none: a story shown alone used to stay
    # up until somebody remembered it, which is how an urgent ran eleven hours.
    $manualHide = Get-SettingInt 'UrgentManualAutoHideSeconds' 0
    $result = Invoke-ShowTemplateResult -Key ([string]$template.Key) -Variables (Get-UrgentItemVariables -Item $item) -ChatId $ChatId -UserId $UserId -AutoHideSeconds $manualHide
    if (-not [bool](Get-JsonProp $result 'Success')) { return $false }
    $stamp = Get-UrgentLiveStamp -Layer ([int]$template.Layer)
    if (-not $stamp) { return $true }
    $liveState = @{ Mode='urgent_manual_live'; Token=[guid]::NewGuid().ToString('N').Substring(0,12)
        StartedAt=Get-Date; UserId=$UserId; ItemId=[string](Get-JsonProp $state 'ItemId')
        Layer=[int]$template.Layer; LiveStamp=$stamp }
    $script:UrgentManualLive[$ChatId] = $liveState
    Save-UrgentManualState | Out-Null
    $shownText = (T 'urgent.shownAlone')
    if ($manualHide -gt 0) { $shownText += "`n" + (T 'air.autoHideAfter' $(Format-DurationSeconds -Seconds $manualHide)) }
    Send-TelegramMessage -ChatId $ChatId -Text $shownText -ReplyMarkup @{
        inline_keyboard = @(
            , @((New-Button (T 'urgent.hideShown') "urgmanual:hide:$($liveState.Token)" -Style danger))
            , @((New-Button (T 'urgent.pickAnother') "urgread:$($state.ItemId):0"))
        )
    }
    return $true
}

function Stop-UrgentCurrentAir {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if ($script:UrgentBoardRun) {
        return (Stop-UrgentBoardRun -ChatId $ChatId -UserId $UserId -Reason 'manual_hide')
    }
    foreach ($entry in @($script:UrgentManualLive.GetEnumerator())) {
        $liveState = $entry.Value
        if ([long](Get-UrgentProperty $liveState 'UserId' 0) -ne $UserId) { continue }
        $token = [string](Get-UrgentProperty $liveState 'Token' '')
        if ($token -and (Invoke-UrgentManualAction -ChatId $ChatId -UserId $UserId -Argument "hide:$token")) {
            return $true
        }
    }
    return $false
}

function Split-UrgentReaderText {
    param([AllowEmptyString()][string]$Text)
    # Plain-text reader: preserve every character, including whitespace.
    if (-not $Text.Length) { return '' }
    for ($offset = 0; $offset -lt $Text.Length;) {
        $size = [math]::Min(2800, $Text.Length - $offset)
        if ($offset + $size -lt $Text.Length -and [char]::IsHighSurrogate($Text[$offset + $size - 1])) { $size-- }
        $Text.Substring($offset, $size)
        $offset += $size
    }
}

function Show-UrgentReader {
    param([long]$ChatId, [long]$UserId = 0, [string]$ItemId, [int]$Page = 0, [int]$MessageId = 0)
    $pending = Get-PendingState -ChatId $ChatId
    if ($pending -and [string](Get-JsonProp $pending 'Mode') -eq 'urgent_manual_confirm') { Clear-PendingState -ChatId $ChatId }
    $items = @(Get-UrgentProperty $script:UrgentBoard 'Items' @())
    $position = -1
    for ($i=0; $i -lt $items.Count; $i++) {
        if ([string](Get-JsonProp $items[$i] 'Id') -ceq $ItemId) { $position = $i; break }
    }
    if ($position -lt 0) { Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.itemGone'); return }
    $item = $items[$position]
    $body = [string](Get-JsonProp $item 'Text')
    $title = [string](Get-JsonProp $item 'Title')
    if ($title) { $body = "$title`n`n$body" }
    $chunks = @(Split-UrgentReaderText -Text $body)
    $readerWindow = Get-BridgePageWindow -ItemCount $chunks.Count -Page $Page -PageSize 1
    $pageIndex = $readerWindow.Page
    $text = (T 'urg.readFull' $($position+1) $($items.Count) $($chunks[$pageIndex]))
    $rows = @()
    if ($chunks.Count -gt 1) {
        $text += (T 'urg.part' $($pageIndex+1) $($chunks.Count))
        $nav = @()
        if ($pageIndex -gt 0) { $nav += New-Button (T 'urgent.prevPart') "urgread:${ItemId}:$($pageIndex-1)" }
        if ($pageIndex+1 -lt $chunks.Count) { $nav += New-Button (T 'urgent.restOfText') "urgread:${ItemId}:$($pageIndex+1)" }
        $rows += , $nav
    }
    $storyNav = @()
    if ($position -gt 0) { $storyNav += New-Button (T 'urgent.prevItem') "urgread:$($items[$position-1].Id):0" }
    if ($position+1 -lt $items.Count) { $storyNav += New-Button (T 'urgent.nextItem') "urgread:$($items[$position+1].Id):0" }
    if ($storyNav.Count) { $rows += , $storyNav }
    if ($UserId -gt 0 -and [bool](Get-JsonProp $item 'Enabled')) { $rows += , @((New-Button (T 'urgent.showAlone') "urgsingle:$ItemId" -Style success)) }
    $rows += , @((New-Button (T 'urgent.editAndSettings') "urgentb:item:$ItemId"))
    $rows += , @((New-Button (T 'urgent.backToBoard') "urgentb:page:$([int][math]::Floor($position / (Get-UrgentBoardPageSize)))"))
    $markup = @{ inline_keyboard = $rows }
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $markup)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $markup
}

function Show-UrgentItemScreen {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Position, [int]$MessageId = 0)
    $item = Get-UrgentItemByPosition -Position $Position
    if (-not $item) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.notFound') -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return
    }
    $defaults = Get-UrgentBoardDefaults
    $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults -FloorSeconds (Get-UrgentFloorSeconds)
    $itemCount = @(Get-UrgentProperty $script:UrgentBoard 'Items' @()).Count
    $lines = @((T 'urg.headlineOfHtml' $(Get-UrgentItemStateLabel -Item $item -Selected @(Get-UrgentSelectedIds -ChatId $ChatId)) $($Position + 1) $itemCount))
    $lines += (ConvertTo-TelegramHtmlText -Text ([string](Get-UrgentProperty $item 'Text' '')))
    $title = [string](Get-UrgentProperty $item 'Title' '')
    if ($title) {
        $lines += "🏷 $(ConvertTo-TelegramHtmlText -Text $title)"
        # Said where the title is shown, not somewhere else: this line is the
        # only place an operator sees a title they believe is going on air.
        if (-not (Test-UrgentTitleSupported)) {
            $lines += (T 'urgent.noTitleField')
        }
    }
    $lines += ''
    $lines += (T 'urg.mode' $(Get-UrgentModeLabel -Mode $timing.Mode) $(if ($timing.ModeInherited) { (T 'urg.fromTheBoard') } else { '' }))
    $lines += (T 'urg.gapLine' $($timing.HoldSeconds) $(if ($timing.IntervalInherited) { (T 'urg.fromTheBoard') } else { '' }))
    $lines += (T 'urg.repeatLine' $($timing.Repeats) $(if ($timing.RepeatsInherited) { (T 'urg.fromTheBoard') } else { '' }))
    if ($timing.IntervalRaisedToFloor) { $lines += (T 'urg.gapRaised' $($timing.HoldSeconds)) }
    if ($timing.Mode -eq 'text' -and -not (Test-UrgentSceneLoop)) { $lines += (T 'urgent.noLoopSwap') }
    $disabledReason = [string](Get-UrgentProperty $item 'DisabledReason' '')
    if (-not [bool](Get-UrgentProperty $item 'Enabled' $true)) {
        $lines += (T 'urg.disabledReason' $(if ($disabledReason) { ConvertTo-TelegramHtmlText -Text $disabledReason } else { (T 'urgent.manualDisable') }))
    }
    $lines += (T 'urg.lastEdit' $(Get-UrgentRelativeTime (Get-JsonProp $item 'UpdatedAt')))
    $keyboard = Get-UrgentItemKeyboard -Position $Position
    $text = $lines -join "`n"
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML')) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard -ParseMode 'HTML'
}

function Get-UrgentTimingKeyboard {
    param()
    $defaults = Get-UrgentBoardDefaults
    $repeatMode = [string](Get-UrgentProperty $defaults 'RepeatMode' 'cycle')
    $orderLabel = if ($repeatMode -eq 'item') { (T 'urgent.orderItem') } else { (T 'urgent.orderCycle') }
    $total = [int](Get-UrgentProperty $defaults 'TotalSeconds' 0)
    $totalLabel = if ($total -gt 0) { (T 'urg.totalDuration' $total) } else { (T 'urgent.totalNone') }
    $rows = @()
    $rows += , @( (New-Button (T 'urg.gap' $([int](Get-UrgentProperty $defaults 'IntervalSeconds' 8))) 'urgentb:dinterval') )
    $rows += , @( (New-Button (T 'urg.repeat' $([int](Get-UrgentProperty $defaults 'Repeats' 1))) 'urgentb:drepeats') )
    $rows += , @( (New-Button $orderLabel 'urgentb:dorder') )
    $rows += , @( (New-Button $totalLabel 'urgentb:dtotal') )
    $rows += , @( (New-Button (T 'urg.defaultMode' $(Get-UrgentModeLabel -Mode ([string](Get-UrgentProperty $defaults 'Mode' 'text')))) 'urgentb:dmode') )
    # Beside the timings it belongs with. It governs only exit mode, so the
    # label says which gap it is rather than leaving an operator in text mode
    # wondering why nothing changed.
    $gap = Get-SettingInt 'UrgentExitGapSeconds' 0
    $gapLabel = if ($gap -gt 0) { (T 'urg.gapBetween' $gap) } else { (T 'urgent.gapSceneOnly') }
    $rows += , @( (New-Button $gapLabel 'urgentb:dgap') )
    # The one timing the board's run does not use: it belongs to the story
    # shown alone, which until now stayed up until somebody pressed hide.
    $manualHide = Get-SettingInt 'UrgentManualAutoHideSeconds' 0
    $manualHideLabel = if ($manualHide -gt 0) { (T 'urg.manualHideAfter' $manualHide) } else { (T 'urgent.manualHideNone') }
    $rows += , @( (New-Button $manualHideLabel 'urgentb:dmanualhide') )
    $rows += , @( (New-Button (T 'urgent.back') 'urgentb:open') )
    return @{ inline_keyboard = $rows }
}

function Show-UrgentTimingScreen {
    param([Parameter(Mandatory)][long]$ChatId, [int]$MessageId = 0)
    $lines = @((T 'urgent.timings.title'), '')
    $lines += (T 'urgent.timings.intro')
    $lines += ''
    $lines += (T 'urgent.timings.order')
    $lines += (T 'urgent.timings.gap')
    $floor = Get-UrgentFloorSeconds
    $lines += (T 'urg.shortestGap' $([math]::Round($floor, 1)))
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urg.didNotStart' $([string]$plan.Error)) -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $scope = if ($SelectedOnly) { (T 'urgent.scopeSelected') } else { (T 'urgent.scopeWhole') }
    $lines = @((T 'urg.reviewBeforePlay' $scope), '')
    $lines += (Get-UrgentPlanSummary -Plan $plan.Value)
    $holds = @($plan.Value.Steps | ForEach-Object { [double]$_.HoldSeconds } | Sort-Object -Unique)
    $holdLabel = if ($holds.Count -eq 1) { "$($holds[0])" } else { "$($holds[0])–$($holds[-1])" }
    $lines += (T 'urg.actualGap' $holdLabel)
    $items = @(Get-UrgentPlayableItems -Board $script:UrgentBoard -SelectedIds (Get-UrgentSelectedIds -ChatId $ChatId) -SelectedOnly:$SelectedOnly)
    $ceiling = Get-UrgentRunCeiling -Items $items
    if ($ceiling.Seconds -gt 0) {
        $reason = if ($ceiling.Reason -eq 'autohide') { Get-UrgentAutoHideLabel -Seconds $ceiling.AutoHideSeconds } else { (T 'urgent.totalLabel') }
        $lines += (T 'urg.runCeiling' $($ceiling.Seconds) $reason)
    }
    foreach ($note in @(Get-UrgentProperty $plan.Value 'Notes' @())) { $lines += $note }
    if (-not (Test-UrgentSceneLoop)) {
        $textSteps = @(@(Get-UrgentProperty $plan.Value 'Steps' @()) | Where-Object { [string]$_.Mode -eq 'text' })
        if ($textSteps.Count -gt 0) { $lines += (T 'urg.updateWithoutLoop' $($textSteps.Count)) }
    }
    $data = if ($SelectedOnly) { 'urgentb:play:sel' } else { 'urgentb:play:all' }
    $rows = @()
    $rows += , @( (New-Button (T 'urgent.startNow') $data -Style success) )
    if (-not (Test-UrgentSceneLoop) -and $textSteps.Count -gt 0) {
        $rows += , @( (New-Button (T 'urgent.fixLoop') 'urgentb:timing' -Style primary) )
    }
    $rows += , @( (New-Button (T 'kb.back') 'urgentb:open') )
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.notFound') -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.notFound') -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.notFound') -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.notFound') -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.notFound') -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $result = Remove-UrgentItem -Board $script:UrgentBoard -ItemId ([string](Get-UrgentProperty $item 'Id' ''))
    if (-not (Invoke-UrgentEdit -Result $result -ChatId $ChatId)) { return $false }
    Add-AuditEntry (T 'urg.deletedAudit' $(Format-UserAuditActor -UserId $UserId))
    Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Show-UrgentDeleteConfirm {
    <# Deleting what is ticked is a destructive act on somebody else's work as
       often as on your own, so it says how many and asks. #>
    param([Parameter(Mandatory)][long]$ChatId)
    $selected = @(Get-UrgentSelectedIds -ChatId $ChatId)
    if ($selected.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.nothingToDelete') -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $rows = @()
    $token = [guid]::NewGuid().ToString('N').Substring(0, 12)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'urgent_delete_confirm'; Token = $token; ItemIds = @($selected); StartedAt = (Get-Date) }
    $rows += , @( (New-Button (T 'urg.delete' $($selected.Count)) "urgentb:delconfirm:$token" -Style danger) )
    $rows += , @( (New-Button (T 'kb.back') 'urgentb:open') )
    Send-TelegramMessage -ChatId $ChatId -Text (T 'urg.confirmDelete' $($selected.Count)) -ReplyMarkup @{ inline_keyboard = $rows }
    return $true
}

function Invoke-UrgentSelectedDelete {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Token = '')
    if ($UserId -eq 0) { $UserId = $ChatId }
    $confirmation = Get-PendingState -ChatId $ChatId
    if (-not $Token -or -not $confirmation -or [string](Get-JsonProp $confirmation 'Mode') -ne 'urgent_delete_confirm' -or
        $Token -cne [string](Get-JsonProp $confirmation 'Token')) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.deleteExpired')
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.saveFailed')
        return $false
    }
    Set-UrgentSelectedIds -ChatId $ChatId -Ids @()
    Add-AuditEntry (T 'urg.deletedManyAudit' $removed $(Format-UserAuditActor -UserId $UserId))
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
        if ($Name -in @('UrgentBoardIntervalSeconds', 'UrgentBoardRepeats', 'UrgentBoardTotalSeconds', 'UrgentManualAutoHideSeconds')) {
            $number = 0
            if (-not [int]::TryParse([string]$Value, [ref]$number)) { throw (T 'urgent.pickNumberButton') }
            $Value = $number
        }
        $previousSettings = (Get-JsonProp $config 'Settings') | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $script:LastConfigSaveFailed = $false
        Set-Setting -Name $Name -Value $Value
        if ($script:LastConfigSaveFailed) {
            Set-JsonProp $config 'Settings' $previousSettings
            throw (T 'urgent.settingSaveFailed')
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
    param([Parameter(Mandatory)][ValidateSet('interval', 'repeats', 'dinterval', 'drepeats', 'dtotal', 'dgap', 'dmanualhide')][string]$Kind)
    $spec = @{ Field = 'IntervalSeconds'; Setting = ''; Label = (T 'urgent.num.itemInterval'); Minimum = 0; Maximum = 3600; Zero = (T 'urgent.num.inherited') }
    switch ($Kind) {
        'repeats' { $spec.Field = 'Repeats'; $spec.Label = (T 'urgent.num.itemRepeats'); $spec.Maximum = 99 }
        'dinterval' { $spec.Setting = 'UrgentBoardIntervalSeconds'; $spec.Label = (T 'urgent.num.boardInterval'); $spec.Minimum = 1 }
        'drepeats' { $spec.Setting = 'UrgentBoardRepeats'; $spec.Field = 'Repeats'; $spec.Label = (T 'urgent.num.boardRepeats'); $spec.Minimum = 1 }
        'dtotal' { $spec.Setting = 'UrgentBoardTotalSeconds'; $spec.Field = 'TotalSeconds'; $spec.Label = (T 'urgent.num.total'); $spec.Zero = (T 'urgent.noCeiling') }
        # A board timing, so it is set where the board's timings are. It was
        # registered only under the general settings screen, which is a long
        # way from the table it governs - and an operator looking for it in
        # إدارة العواجل did not find it, which is how this was reported.
        'dgap' { $spec.Setting = 'UrgentExitGapSeconds'; $spec.Field = ''; $spec.Label = (T 'urgent.num.gap'); $spec.Zero = (T 'urgent.num.sceneOnly') }
        'dmanualhide' { $spec.Setting = 'UrgentManualAutoHideSeconds'; $spec.Field = ''; $spec.Label = (T 'urgent.num.manualHide'); $spec.Zero = (T 'urgent.num.hideButtonOnly') }
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
    $text = (T 'urg.numberScreen' $($spec.Label) $valueLabel $($spec.Minimum) $($spec.Maximum))
    if (-not $spec.Setting) {
        $effective = Get-UrgentEffectiveTiming -Item $item -Defaults (Get-UrgentBoardDefaults) -FloorSeconds (Get-UrgentFloorSeconds)
        $effectiveField = if ($spec.Field -eq 'IntervalSeconds') { 'HoldSeconds' } else { $spec.Field }
        $text += (T 'urg.actualValue' $(Get-UrgentProperty $effective $effectiveField 0))
        if ($spec.Field -eq 'IntervalSeconds' -and $effective.IntervalRaisedToFloor) {
            $text += (T 'urg.gapRaisedNl' $($effective.HoldSeconds))
        }
    }
    $prefix = "urgentb:num:$($State.Token)"
    $rows = @()
    $rows += , @((New-Button '−10' "${prefix}:-10"), (New-Button '−5' "${prefix}:-5"), (New-Button '−1' "${prefix}:-1"))
    $rows += , @((New-Button '+1' "${prefix}:+1"), (New-Button '+5' "${prefix}:+5"), (New-Button '+10' "${prefix}:+10"))
    if ($spec.Maximum -gt 99) { $rows += , @((New-Button '−60' "${prefix}:-60"), (New-Button '+60' "${prefix}:+60")) }
    $minLabel = if ($spec.Minimum -eq 0) { "↩️ $($spec.Zero)" } else { (T 'urg.lowest' $($spec.Minimum)) }
    $rows += , @((New-Button $minLabel "${prefix}:min"), (New-Button (T 'urg.highest' $($spec.Maximum)) "${prefix}:max"))
    $rows += , @((New-Button (T 'urgent.num.doneBack') "${prefix}:done"))
    $keyboard = @{ inline_keyboard = $rows }
    if ($MessageId -gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $keyboard)) { return }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $keyboard
}

function Start-UrgentNumberPicker {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0,
        [Parameter(Mandatory)][ValidateSet('interval', 'repeats', 'dinterval', 'drepeats', 'dtotal', 'dgap', 'dmanualhide')][string]$Kind,
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.num.expired')
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
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgent.notFound') -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
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
