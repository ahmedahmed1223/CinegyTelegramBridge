Set-StrictMode -Version Latest

<#
    The breaking-news board: the table an operator manages, and the plan that
    table becomes when it goes on air.

    Domain only. Nothing here talks to Telegram, to Cinegy, or to the disk -
    every timing this module resolves is handed to it, so the same numbers can
    be printed on a screen and walked by the engine without either of them
    doing the arithmetic a second time.

    The board does not replace the fixed Urgent template. That path is
    untouched and stays the fastest way to put one breaking line on air; this
    is the table for when there are several.
#>

function New-UrgentResult {
    param([bool]$Success, $Value = $null, [string]$ErrorCode = '', [string]$ErrorMessage = '')
    return [pscustomobject]@{ Success = $Success; Value = $Value; ErrorCode = $ErrorCode; Error = $ErrorMessage }
}

function Copy-UrgentValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Get-UrgentProperty {
    <#
        Reads one field off either shape the board can arrive in.

        A hashtable here and a PSCustomObject there is not hypothetical: the
        board is written as objects and read back as objects, but a test or a
        caller builds it as a hashtable, and [ordered]@{} is neither - it is an
        OrderedDictionary, whose keys are not PSObject properties at all. So
        the dictionary case is tested by interface, not by [hashtable].
    #>
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $Default
}

function New-UrgentId {
    return "u_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}

function ConvertTo-UrgentText {
    param([string]$Text)
    return (([string]$Text) -replace '\s+', ' ').Trim()
}

function New-UrgentDefaults {
    <#
        The shape of the newsroom's numbers, with the values the bridge ships.

        The live ones come from the settings - Get-UrgentBoardDefaults builds
        this same shape out of them - so this is the fallback and the contract,
        not a second place where the numbers are kept. A number kept in two
        places is a number that gets edited in one of them.

        An item that leaves a field at zero inherits from here.

        Zero means "inherit" everywhere in this module, and nothing else. It is
        never also the value read when something could not be read: a field
        that means two things is the trap that made every Mojaz draft look
        unlocked, and it is not repeated here.
    #>
    return [pscustomobject]@{
        Mode = 'text'
        IntervalSeconds = 8
        TotalSeconds = 0
        Repeats = 1
        RepeatMode = 'cycle'
    }
}

function New-UrgentBoard {
    <# The file holds the lines and their per-line overrides. It deliberately
       does not hold the table's own numbers: those are settings, editable from
       the settings screen like every other timing in this bridge. #>
    return [pscustomobject]@{
        SchemaVersion = 1
        Items = @()
        Revision = 1
    }
}

function Test-UrgentMode {
    param([string]$Mode)
    return (@('text', 'exit', 'auto_hide') -contains ([string]$Mode).ToLowerInvariant())
}

function Test-UrgentRepeatMode {
    param([string]$RepeatMode)
    return (@('cycle', 'item') -contains ([string]$RepeatMode).ToLowerInvariant())
}

function Get-UrgentItem {
    param($Board, [string]$ItemId)
    foreach ($item in @(Get-UrgentProperty $Board 'Items' @())) {
        if ([string](Get-UrgentProperty $item 'Id' '') -eq $ItemId) { return $item }
    }
    return $null
}

function Get-UrgentItemIndex {
    <# The position, or -1. Callers address items by position on a keyboard -
       callback_data is 64 bytes and a full id does not fit beside a prefix. #>
    param($Board, [string]$ItemId)
    $items = @(Get-UrgentProperty $Board 'Items' @())
    for ($index = 0; $index -lt $items.Count; $index++) {
        if ([string](Get-UrgentProperty $items[$index] 'Id' '') -eq $ItemId) { return $index }
    }
    return -1
}

function ConvertFrom-UrgentPasteText {
    <# Pasted breaking lines: one story per line, cleaned like every story.
       Lines that say nothing are skipped and counted rather than lost. #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ([string]$Text -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $story = ConvertTo-UrgentText -Text $line
        if (-not $story) { $skipped.Add('سطر فارغ') | Out-Null; continue }
        $rows.Add(@{ Text = $story }) | Out-Null
    }
    return [pscustomobject]@{ Rows = @($rows.ToArray()); Skipped = @($skipped.ToArray()) }
}

function Add-UrgentItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Board,
        [Parameter(Mandatory)][string]$Text,
        [string]$Title = '',
        [string]$Mode = '',
        [int]$MaxItems = 40,
        [int]$MaxLength = 300,
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [long]$UserId = 0
    )
    $normalized = ConvertTo-UrgentText -Text $Text
    if ([string]::IsNullOrWhiteSpace($normalized)) { return (New-UrgentResult $false $null 'invalid_text' 'نصّ العاجل مطلوب.') }
    if ($normalized.Length -gt $MaxLength) { return (New-UrgentResult $false $null 'too_long' "نصّ العاجل أطول من $MaxLength حرفًا.") }
    if ($Mode -and -not (Test-UrgentMode -Mode $Mode)) { return (New-UrgentResult $false $null 'invalid_mode' 'نمط العرض غير معروف.') }
    $copy = Copy-UrgentValue $Board
    $items = @(Get-UrgentProperty $copy 'Items' @())
    if ($items.Count -ge $MaxItems) { return (New-UrgentResult $false $null 'full' "الجدول ممتلئ ($MaxItems عاجلًا).") }
    $item = [pscustomobject]@{
        Id = New-UrgentId
        Text = $normalized
        Title = (ConvertTo-UrgentText -Text $Title)
        Mode = ([string]$Mode).ToLowerInvariant()
        IntervalSeconds = 0
        TotalSeconds = 0
        Repeats = 0
        RepeatMode = ''
        Enabled = $true
        CreatedAt = $Now.ToString('o')
        UpdatedAt = $Now.ToString('o')
        UpdatedBy = $UserId
    }
    $copy.Items = @($items + $item)
    $copy.Revision = [int](Get-UrgentProperty $copy 'Revision' 0) + 1
    return (New-UrgentResult $true $copy)
}

function Set-UrgentItem {
    <#
        One edit, one field at a time, and every field validated here rather
        than at the screen that offered it - the screen is one caller of
        several, and a rule written at each caller drifts at each caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Board,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][ValidateSet('Text', 'Title', 'Mode', 'IntervalSeconds', 'TotalSeconds', 'Repeats', 'RepeatMode', 'Enabled')][string]$Field,
        $Value,
        [int]$MaxLength = 300,
        [int]$MaxSeconds = 3600,
        [int]$MaxRepeats = 99,
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [long]$UserId = 0
    )
    $copy = Copy-UrgentValue $Board
    $target = Get-UrgentItem -Board $copy -ItemId $ItemId
    if (-not $target) { return (New-UrgentResult $false $null 'not_found' 'العاجل غير موجود.') }
    # Assigned inside the branches, never as the value of the switch itself: a
    # switch used as an expression writes to the output stream, and the stream
    # unwraps a layer - which is how a row loses the comma that makes it a row.
    $applied = $null
    switch ($Field) {
        'Text' {
            $applied = ConvertTo-UrgentText -Text ([string]$Value)
            if ([string]::IsNullOrWhiteSpace($applied)) { return (New-UrgentResult $false $null 'invalid_text' 'نصّ العاجل مطلوب.') }
            if ($applied.Length -gt $MaxLength) { return (New-UrgentResult $false $null 'too_long' "نصّ العاجل أطول من $MaxLength حرفًا.") }
        }
        'Title' {
            $applied = ConvertTo-UrgentText -Text ([string]$Value)
            if ($applied.Length -gt $MaxLength) { return (New-UrgentResult $false $null 'too_long' "العنوان أطول من $MaxLength حرفًا.") }
        }
        'Mode' {
            $applied = ([string]$Value).ToLowerInvariant()
            if ($applied -and -not (Test-UrgentMode -Mode $applied)) { return (New-UrgentResult $false $null 'invalid_mode' 'نمط العرض غير معروف.') }
        }
        'RepeatMode' {
            $applied = ([string]$Value).ToLowerInvariant()
            if ($applied -and -not (Test-UrgentRepeatMode -RepeatMode $applied)) { return (New-UrgentResult $false $null 'invalid_repeat_mode' 'ترتيب التكرار غير معروف.') }
        }
        'Enabled' { $applied = [bool]$Value }
        'Repeats' {
            $parsed = 0
            if (-not [int]::TryParse([string]$Value, [ref]$parsed) -or $parsed -lt 0 -or $parsed -gt $MaxRepeats) {
                return (New-UrgentResult $false $null 'invalid_number' "عدد التكرارات بين 0 و$MaxRepeats (0 = خذ من الجدول).")
            }
            $applied = $parsed
        }
        default {
            $parsed = 0
            if (-not [int]::TryParse([string]$Value, [ref]$parsed) -or $parsed -lt 0 -or $parsed -gt $MaxSeconds) {
                return (New-UrgentResult $false $null 'invalid_number' "القيمة بالثواني بين 0 و$MaxSeconds (0 = خذ من الجدول).")
            }
            $applied = $parsed
        }
    }
    $target.$Field = $applied
    $target.UpdatedAt = $Now.ToString('o')
    $target.UpdatedBy = $UserId
    $copy.Revision = [int](Get-UrgentProperty $copy 'Revision' 0) + 1
    return (New-UrgentResult $true $copy)
}

function Remove-UrgentItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][string]$ItemId)
    $copy = Copy-UrgentValue $Board
    $items = @(Get-UrgentProperty $copy 'Items' @())
    $kept = @($items | Where-Object { [string](Get-UrgentProperty $_ 'Id' '') -ne $ItemId })
    if ($kept.Count -eq $items.Count) { return (New-UrgentResult $false $null 'not_found' 'العاجل غير موجود.') }
    $copy.Items = $kept
    $copy.Revision = [int](Get-UrgentProperty $copy 'Revision' 0) + 1
    return (New-UrgentResult $true $copy)
}

function Clear-UrgentItems {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Board)
    $copy = Copy-UrgentValue $Board
    $copy.Items = @()
    $copy.Revision = [int](Get-UrgentProperty $copy 'Revision' 0) + 1
    return (New-UrgentResult $true $copy)
}

function Move-UrgentItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][string]$ItemId, [Parameter(Mandatory)][int]$Delta)
    $copy = Copy-UrgentValue $Board
    $items = @(Get-UrgentProperty $copy 'Items' @())
    $index = Get-UrgentItemIndex -Board $copy -ItemId $ItemId
    if ($index -lt 0) { return (New-UrgentResult $false $null 'not_found' 'العاجل غير موجود.') }
    $target = $index + $Delta
    if ($target -lt 0 -or $target -ge $items.Count) { return (New-UrgentResult $false $null 'out_of_range' 'لا يمكن تحريكه أبعد من ذلك.') }
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) { $ordered.Add($item) | Out-Null }
    $moving = $ordered[$index]
    $ordered.RemoveAt($index)
    $ordered.Insert($target, $moving)
    $copy.Items = @($ordered.ToArray())
    $copy.Revision = [int](Get-UrgentProperty $copy 'Revision' 0) + 1
    return (New-UrgentResult $true $copy)
}

function Get-UrgentEffectiveTiming {
    <#
        The one place the four numbers are resolved.

        Every screen prints what this returns and the engine walks what this
        returns, so what the operator was promised and what goes on air cannot
        drift apart. The same check written twice drifts by the second time it
        is edited - this repository has paid for that lesson in four writers of
        one file and six callers of one index.

        FloorSeconds is the shortest a row may be held. The caller derives it
        from the scene itself where the scene says - entrance plus exit is the
        shortest interval that can hide a change - and falls back to a setting
        only when the scene cannot be read.
    #>
    [CmdletBinding()]
    param($Item, $Defaults, [double]$FloorSeconds = 0)
    if (-not $Defaults) { $Defaults = New-UrgentDefaults }
    $defaultMode = [string](Get-UrgentProperty $Defaults 'Mode' 'text')
    if (-not (Test-UrgentMode -Mode $defaultMode)) { $defaultMode = 'text' }
    $defaultRepeatMode = [string](Get-UrgentProperty $Defaults 'RepeatMode' 'cycle')
    if (-not (Test-UrgentRepeatMode -RepeatMode $defaultRepeatMode)) { $defaultRepeatMode = 'cycle' }

    $itemMode = [string](Get-UrgentProperty $Item 'Mode' '')
    $mode = if ($itemMode -and (Test-UrgentMode -Mode $itemMode)) { $itemMode.ToLowerInvariant() } else { $defaultMode }

    $itemInterval = [int](Get-UrgentProperty $Item 'IntervalSeconds' 0)
    $interval = if ($itemInterval -gt 0) { $itemInterval } else { [int](Get-UrgentProperty $Defaults 'IntervalSeconds' 8) }
    if ($interval -lt 1) { $interval = 1 }
    # 0.0 on purpose: [math]::Max(0, $double) binds the int overload and drops
    # the fraction without saying so.
    $held = [math]::Max([double]$interval, [math]::Max(0.0, $FloorSeconds))

    $itemTotal = [int](Get-UrgentProperty $Item 'TotalSeconds' 0)
    $total = if ($itemTotal -gt 0) { $itemTotal } else { [int](Get-UrgentProperty $Defaults 'TotalSeconds' 0) }

    $itemRepeats = [int](Get-UrgentProperty $Item 'Repeats' 0)
    $repeats = if ($itemRepeats -gt 0) { $itemRepeats } else { [int](Get-UrgentProperty $Defaults 'Repeats' 1) }
    if ($repeats -lt 1) { $repeats = 1 }

    $itemRepeatMode = [string](Get-UrgentProperty $Item 'RepeatMode' '')
    $repeatMode = if ($itemRepeatMode -and (Test-UrgentRepeatMode -RepeatMode $itemRepeatMode)) { $itemRepeatMode.ToLowerInvariant() } else { $defaultRepeatMode }

    return [pscustomobject]@{
        Mode = $mode
        ModeInherited = -not ($itemMode -and (Test-UrgentMode -Mode $itemMode))
        IntervalSeconds = $interval
        HoldSeconds = [math]::Round($held, 3)
        IntervalInherited = ($itemInterval -le 0)
        IntervalRaisedToFloor = ($held -gt $interval)
        TotalSeconds = $total
        TotalInherited = ($itemTotal -le 0)
        Repeats = $repeats
        RepeatsInherited = ($itemRepeats -le 0)
        RepeatMode = $repeatMode
        RepeatModeInherited = -not ($itemRepeatMode -and (Test-UrgentRepeatMode -RepeatMode $itemRepeatMode))
    }
}

function Get-UrgentPlayableItems {
    <# Enabled items in table order, optionally narrowed to a selection. The
       selection belongs to one operator's chat, so it arrives as a list of
       ids rather than as a flag on the shared board. #>
    param($Board, [string[]]$SelectedIds = @(), [switch]$SelectedOnly)
    $items = @(@(Get-UrgentProperty $Board 'Items' @()) | Where-Object { [bool](Get-UrgentProperty $_ 'Enabled' $true) })
    if (-not $SelectedOnly) { return $items }
    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($id in @($SelectedIds)) { $wanted.Add([string]$id) | Out-Null }
    return @($items | Where-Object { $wanted.Contains([string](Get-UrgentProperty $_ 'Id' '')) })
}

function New-UrgentRunPlan {
    <#
        The table, turned into moments.

        Every moment is absolute from the start of the run rather than added to
        the one before it, so a slow send delays its own row and no other - the
        same rule the bulletin runs on, and the reason a run can rejoin its own
        schedule after a restart instead of starting over.

        Two orders, because they answer different newsroom questions:

            cycle  ->  1 2 3 4 · 1 2 3 4    the whole board, then again
            item   ->  1 1 · 2 2 · 3 3      each breaking line, then the next

        MaxSeconds is a ceiling, not a target. It carries both the operator's
        own total and the forced hide a sensitive template brings with it, and
        whichever is shorter wins. When it cuts the run short the plan says so
        in Notes, and the screen says it before anything reaches air rather
        than after - a run that quietly played half the table is a run nobody
        can tell from one that played all of it.

        TransitionSeconds is what an exit-mode line costs before it is visible:
        the outro plus the entrance. A text-mode line costs nothing, because
        nothing leaves - the values are written into the scene that is already
        up.
    #>
    [CmdletBinding()]
    param(
        # Empty is an answer this function gives rather than throws: "nothing
        # selected" is an ordinary thing for an operator to do, and it belongs
        # on the screen as a sentence, not in the log as an exception.
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        $Defaults,
        [double]$FloorSeconds = 0,
        [double]$TransitionSeconds = 0,
        [double]$MaxSeconds = 0,
        [string]$MaxReason = ''
    )
    $playable = @($Items)
    if ($playable.Count -lt 1) { return (New-UrgentResult $false $null 'empty' 'لا عواجل محدَّدة.') }
    if (-not $Defaults) { $Defaults = New-UrgentDefaults }

    $timings = @()
    foreach ($item in $playable) {
        $timings += (Get-UrgentEffectiveTiming -Item $item -Defaults $Defaults -FloorSeconds $FloorSeconds)
    }
    # The board's order, not an item's: mixing two orders in one run would mean
    # no single sequence to print. The first item that states one wins, which
    # is what the screen shows beside the button.
    $repeatMode = [string](Get-UrgentProperty $Defaults 'RepeatMode' 'cycle')
    # Cycles is the highest repeat count, not a replacement for each item's
    # effective count. Exhausted items drop out of later rounds.
    $requestedCycles = 1
    foreach ($timing in $timings) {
        if (-not $timing.RepeatModeInherited) { $repeatMode = $timing.RepeatMode; break }
    }
    foreach ($timing in $timings) {
        $requestedCycles = [math]::Max($requestedCycles, [int]$timing.Repeats)
    }
    if (-not (Test-UrgentRepeatMode -RepeatMode $repeatMode)) { $repeatMode = 'cycle' }
    if ($requestedCycles -lt 1) { $requestedCycles = 1 }

    $notes = @()
    $cycles = $requestedCycles
    $trimmedBy = ''
    $ceiling = [math]::Max(0.0, $MaxSeconds)
    # Reduce the repeat cap, never truncate an item-order prefix: even the
    # shortest candidate contains every playable item once. Cost the actual
    # sequence because exhausted items change the mode transitions - but cost
    # it as numbers, not as built steps: the candidates the ceiling rejects
    # were being materialized whole, which turned one plan into one plan per
    # candidate repeat count (a full 40-line table at 99 repeats measured
    # seconds per plan). Steps are built once, for the plan that ships.
    $at = 0.0
    while ($true) {
        # The order the lines actually play in, costed as it plays: the
        # transition rule is the step rule (after the first line, charge it
        # when this line exits or the one before hid itself), so one walk
        # answers both - and this walk carries no steps, only seconds.
        $at = 0.0
        $stepCount = 0
        $previousMode = ''
        if ($repeatMode -eq 'item') {
            for ($position = 0; $position -lt $playable.Count; $position++) {
                $timing = $timings[$position]
                for ($round = 0; $round -lt [math]::Min($cycles, [int]$timing.Repeats); $round++) {
                    $transition = 0.0
                    if ($stepCount -gt 0 -and ($timing.Mode -eq 'exit' -or $previousMode -eq 'auto_hide')) { $transition = [math]::Max(0.0, $TransitionSeconds) }
                    $at += $transition + [double]$timing.HoldSeconds
                    $previousMode = $timing.Mode
                    $stepCount++
                }
            }
        }
        else {
            for ($round = 0; $round -lt $cycles; $round++) {
                for ($position = 0; $position -lt $playable.Count; $position++) {
                    if ($round -ge $timings[$position].Repeats) { continue }
                    $timing = $timings[$position]
                    $transition = 0.0
                    if ($stepCount -gt 0 -and ($timing.Mode -eq 'exit' -or $previousMode -eq 'auto_hide')) { $transition = [math]::Max(0.0, $TransitionSeconds) }
                    $at += $transition + [double]$timing.HoldSeconds
                    $previousMode = $timing.Mode
                    $stepCount++
                }
            }
        }

        if ($ceiling -le 0 -or $at -le $ceiling) { break }
        if ($cycles -eq 1) {
            return (New-UrgentResult $false $null 'no_fit' "دورة واحدة تحتاج $([int][math]::Ceiling($at)) ث، والسقف $([int]$ceiling) ث.")
        }
        $cycles--
    }

    # The candidate repeat counts are settled; build the plan that ships once.
    $sequence = [System.Collections.Generic.List[int]]::new()
    if ($repeatMode -eq 'item') {
        for ($position = 0; $position -lt $playable.Count; $position++) {
            for ($round = 0; $round -lt [math]::Min($cycles, $timings[$position].Repeats); $round++) { $sequence.Add($position) }
        }
    }
    else {
        for ($round = 0; $round -lt $cycles; $round++) {
            for ($position = 0; $position -lt $playable.Count; $position++) {
                if ($round -lt $timings[$position].Repeats) { $sequence.Add($position) }
            }
        }
    }

    $steps = @()
    $at = 0.0
    for ($step = 0; $step -lt $sequence.Count; $step++) {
        $position = $sequence[$step]
        $timing = $timings[$position]
        $item = $playable[$position]
        $transition = 0.0
        if ($step -gt 0 -and ($timing.Mode -eq 'exit' -or $timings[$sequence[$step - 1]].Mode -eq 'auto_hide')) { $transition = [math]::Max(0.0, $TransitionSeconds) }
        $steps += [pscustomobject]@{
            Step = $step
            Position = $position
            ItemId = [string](Get-UrgentProperty $item 'Id' '')
            Text = [string](Get-UrgentProperty $item 'Text' '')
            Title = [string](Get-UrgentProperty $item 'Title' '')
            Mode = $timing.Mode
            AtSeconds = [math]::Round($at, 3)
            TransitionSeconds = [math]::Round($transition, 3)
            VisibleAtSeconds = [math]::Round($at + $transition, 3)
            HoldSeconds = $timing.HoldSeconds
        }
        $at += $transition + [double]$timing.HoldSeconds
    }
    if ($cycles -lt $requestedCycles) {
        $trimmedBy = if ($MaxReason) { $MaxReason } else { 'total' }
        $label = if ($trimmedBy -eq 'autohide') { 'الإخفاء التلقائي للقالب الحسّاس' } else { 'المدة الكلية' }
        $notes += "⚠️ $label قصّ التكرار من $requestedCycles إلى $cycles."
    }

    if ($repeatMode -eq 'item' -and $cycles -gt 1) {
        $repeatedExits = @($timings | Where-Object { $_.Mode -eq 'exit' -and $_.Repeats -gt 1 })
        if ($repeatedExits.Count -gt 0) {
            $notes += '⚠️ ترتيب «كل عاجل مرّات»: عنصر بحركة خروج سيخرج ويعود بالنصّ نفسه.'
        }
    }
    $raised = @($timings | Where-Object { $_.IntervalRaisedToFloor })
    if ($raised.Count -gt 0) {
        $notes += "⏱ رُفع فاصل $($raised.Count) عنصرًا إلى أقصر مدة يسمح بها المشهد ($([math]::Round($FloorSeconds, 1)) ث)."
    }

    return (New-UrgentResult $true ([pscustomobject]@{
                Steps = @($steps)
                StepCount = $steps.Count
                ItemCount = $playable.Count
                Cycles = $cycles
                RequestedCycles = $requestedCycles
                RepeatMode = $repeatMode
                TrimmedBy = $trimmedBy
                TotalSeconds = [math]::Round($at, 3)
                ExitAtSeconds = [math]::Round($at, 3)
                CeilingSeconds = [math]::Round($ceiling, 3)
                Notes = @($notes)
            }))
}

function Get-UrgentPlanSummary {
    <# The one line the operator reads before anything reaches air. Built here
       so the review screen and the log say the same sentence. #>
    param($Plan)
    if (-not $Plan) { return '' }
    $order = if ([string](Get-UrgentProperty $Plan 'RepeatMode' 'cycle') -eq 'item') { 'كل عاجل مرّات ثم التالي' } else { 'الجدول كاملًا ثم يعيد' }
    $total = [double](Get-UrgentProperty $Plan 'TotalSeconds' 0)
    $roundedTotal = [long][math]::Round($total)
    $minutes = [long][math]::Floor($roundedTotal / 60)
    $seconds = [int]($roundedTotal % 60)
    $clock = "$minutes`:$($seconds.ToString('00'))"
    $exits = @(@(Get-UrgentProperty $Plan 'Steps' @()) | Where-Object { [string]$_.Mode -eq 'exit' }).Count
    $parts = @(
        "$([int](Get-UrgentProperty $Plan 'ItemCount' 0)) عاجلًا"
        "$([int](Get-UrgentProperty $Plan 'Cycles' 1)) دورة"
        $order
        "الزمن المتوقّع $clock"
    )
    if ($exits -gt 0) { $parts += "$exits بحركة خروج" }
    return ($parts -join ' · ')
}

Export-ModuleMember -Function New-UrgentBoard, New-UrgentDefaults, New-UrgentId, Get-UrgentProperty, ConvertFrom-UrgentPasteText,
    Add-UrgentItem, Set-UrgentItem, Remove-UrgentItem, Clear-UrgentItems, Move-UrgentItem,
    Get-UrgentItem, Get-UrgentItemIndex, Get-UrgentEffectiveTiming, Get-UrgentPlayableItems,
    New-UrgentRunPlan, Get-UrgentPlanSummary, Test-UrgentMode, Test-UrgentRepeatMode, ConvertTo-UrgentText
