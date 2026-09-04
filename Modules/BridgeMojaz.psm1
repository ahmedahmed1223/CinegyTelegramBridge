Set-StrictMode -Version Latest

function New-MojazResult {
    param([bool]$Success, $Value = $null, [string]$ErrorCode = '', [string]$ErrorMessage = '')
    return [pscustomobject]@{ Success = $Success; Value = $Value; ErrorCode = $ErrorCode; Error = $ErrorMessage }
}

function Copy-MojazValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Get-MojazProperty {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $Default
}

function ConvertTo-MojazName {
    param([string]$Name)
    return (([string]$Name).Trim() -replace '\s+', ' ')
}

function New-MojazId {
    param([Parameter(Mandatory)][ValidateSet('b', 'r', 'run', 'ms')][string]$Prefix)
    return "$Prefix`_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}

function New-MojazLibrary {
    return [pscustomobject]@{ SchemaVersion = 2; Bulletins = @() }
}

function Test-MojazNameAvailable {
    param($Library, [string]$Name, [string]$ExceptId = '')
    $candidate = (ConvertTo-MojazName -Name $Name).ToLowerInvariant()
    foreach ($bulletin in @(Get-MojazProperty $Library 'Bulletins' @())) {
        if ([string](Get-MojazProperty $bulletin 'Id' '') -eq $ExceptId) { continue }
        if ((ConvertTo-MojazName -Name ([string](Get-MojazProperty $bulletin 'Name' ''))).ToLowerInvariant() -eq $candidate) { return $false }
    }
    return $true
}

function Add-MojazBulletin {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$Name,
        [int]$DelayFrames = 200,
        # Which design plays this bulletin. Empty is the built-in one, which
        # is what every existing bulletin says and what the option ships off.
        [string]$TemplateKey = '',
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $normalized = ConvertTo-MojazName -Name $Name
    if ([string]::IsNullOrWhiteSpace($normalized)) { return (New-MojazResult $false $null 'invalid_name' 'اسم الموجز مطلوب.') }
    if (-not (Test-MojazNameAvailable -Library $Library -Name $normalized)) { return (New-MojazResult $false $null 'duplicate_name' 'يوجد موجز بهذا الاسم.') }
    $copy = Copy-MojazValue $Library
    $bulletins = @($copy.Bulletins)
    $bulletin = [pscustomobject]@{
        Id = New-MojazId -Prefix b; Name = $normalized; Revision = 1
        CreatedAt = $Now.ToString('o'); UpdatedAt = $Now.ToString('o'); UpdatedBy = $UserId
        # Frames, like the two timings beside it: one unit for the whole
        # bulletin rather than seconds here and frames there.
        TemplateKey = ([string]$TemplateKey).Trim()
        DelayFrames = [math]::Min(15000, [math]::Max(1, $DelayFrames))
        IntroExtraFrames = 0; LastRowFrames = 0; Rows = @()
    }
    $copy.Bulletins = @($bulletins + $bulletin)
    return (New-MojazResult $true $copy)
}

function Copy-MojazBulletin {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [Parameter(Mandatory)][string]$Name, [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $normalized = ConvertTo-MojazName -Name $Name
    if ([string]::IsNullOrWhiteSpace($normalized)) { return (New-MojazResult $false $null 'invalid_name' 'اسم الموجز مطلوب.') }
    if (-not (Test-MojazNameAvailable -Library $Library -Name $normalized)) { return (New-MojazResult $false $null 'duplicate_name' 'يوجد موجز بهذا الاسم.') }
    $source = @((Get-MojazProperty $Library 'Bulletins' @()) | Where-Object { [string]$_.Id -eq $BulletinId }) | Select-Object -First 1
    if (-not $source) { return (New-MojazResult $false $null 'not_found' 'الموجز غير موجود.') }
    $copy = Copy-MojazValue $Library
    $newBulletin = Copy-MojazValue $source
    $newBulletin.Id = New-MojazId -Prefix b
    $newBulletin.Name = $normalized
    $newBulletin.Revision = 1
    $newBulletin.CreatedAt = $Now.ToString('o')
    $newBulletin.UpdatedAt = $Now.ToString('o')
    $newBulletin.UpdatedBy = $UserId
    $copy.Bulletins = @(@($copy.Bulletins) + $newBulletin)
    return (New-MojazResult $true $copy)
}

function Rename-MojazBulletin {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [Parameter(Mandatory)][string]$Name, [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $normalized = ConvertTo-MojazName -Name $Name
    if ([string]::IsNullOrWhiteSpace($normalized)) { return (New-MojazResult $false $null 'invalid_name' 'اسم الموجز مطلوب.') }
    if (-not (Test-MojazNameAvailable -Library $Library -Name $normalized -ExceptId $BulletinId)) { return (New-MojazResult $false $null 'duplicate_name' 'يوجد موجز بهذا الاسم.') }
    $copy = Copy-MojazValue $Library
    $target = @($copy.Bulletins | Where-Object { [string]$_.Id -eq $BulletinId }) | Select-Object -First 1
    if (-not $target) { return (New-MojazResult $false $null 'not_found' 'الموجز غير موجود.') }
    $target.Name = $normalized
    $target.Revision = [int]$target.Revision + 1
    $target.UpdatedAt = $Now.ToString('o')
    $target.UpdatedBy = $UserId
    return (New-MojazResult $true $copy)
}

function New-MojazLoopPlan {
    <#
        When each row should be written, if the write is to be hidden by the
        scene's own fade.

        The scene loops LoopStart..LoopEnd, and at the wrap the content jumps
        to zero opacity and fades back in over the entrance frames. That fade
        is a window in which the text can be replaced without anyone seeing it
        change: written a moment after the wrap, the new row is already there
        by the time the picture is visible again.

        The first wrap is LoopEnd/Fps after SHOW - the entrance plus one whole
        loop - and every wrap after it is one loop apart. So this only lines up
        when the loop is as long as a story should stay: re-cut LoopEndFrame in
        Titler and the bulletin's pace follows it.

        The exit is placed ON the wrap rather than after it, because EXIT jumps
        the scene to LoopEnd, where the content is still at full opacity - a
        seamless join, where a moment later it would flash back before fading.
    #>
    [CmdletBinding()]
    param($SceneTiming, [Parameter(Mandatory)][int]$RowCount, [double]$OffsetSeconds = 0.4)
    if (-not $SceneTiming -or $RowCount -lt 1) { return $null }
    $loop = [double](Get-MojazProperty $SceneTiming 'LoopSeconds' 0)
    $entrance = [double](Get-MojazProperty $SceneTiming 'IntroSeconds' 0)
    if ($loop -le 0) { return $null }
    # Aiming past the fade would show the change; clamp into it. The literals
    # are 0.0 on purpose: an int 0 picks [math]::Max(int,int) and truncates
    # the offset to nothing without saying so.
    $offset = [math]::Max(0.0, [math]::Min([double]$OffsetSeconds, [math]::Max(0.0, $entrance - 0.1)))
    $firstWrap = $entrance + $loop
    $writes = @(0.0)
    for ($index = 1; $index -lt $RowCount; $index++) {
        $writes += [math]::Round($firstWrap + (($index - 1) * $loop) + $offset, 3)
    }
    return [pscustomobject]@{
        LoopSeconds = $loop
        FadeSeconds = $entrance
        OffsetSeconds = $offset
        WriteOffsets = $writes
        ExitOffset = [math]::Round($firstWrap + (($RowCount - 1) * $loop), 3)
    }
}

function New-MojazRunSnapshot {
    <#
        Every row gets an absolute moment measured from the start of the run,
        never a delay measured from the previous send: a row that goes out late
        must not push every row behind it later still.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Bulletin, $SceneTiming = $null, $Schedule = $null,
        [double]$OffsetSeconds = 0.4, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $rows = @(Copy-MojazValue @(Get-MojazProperty $Bulletin 'Rows' @()))
    if ($rows.Count -eq 0) { return (New-MojazResult $false $null 'empty_bulletin' 'الموجز بلا صفوف.') }
    $delay = [math]::Max(1, [int](Get-MojazProperty $Bulletin 'DelaySeconds' 8))
    # Doubles, not ints: these come from frame counts divided by a frame
    # rate, and rounding 1.2 seconds down to 1 was throwing away a fifth of
    # the entrance animation.
    # An outright hold, set by the operator, from the moment the scene is up
    # until EXIT. A bulletin of several stories is timed by its rows; one that
    # carries a single story - a video report - has nothing to walk through,
    # and asking somebody to express "keep it up for forty seconds" as a row
    # dwell plus an intro plus a last-row hold is asking them to do arithmetic
    # to say something simple. Zero leaves the row timing in charge.
    $holdOverride = [double](Get-MojazProperty $Bulletin 'HoldSeconds' 0)
    $introOverride = [double](Get-MojazProperty $Bulletin 'IntroExtraSeconds' 0)
    $lastOverride = [double](Get-MojazProperty $Bulletin 'LastRowSeconds' 0)
    $intro = if ($introOverride -gt 0) { $introOverride } elseif ($SceneTiming) { [double](Get-MojazProperty $SceneTiming 'IntroSeconds' 0) } else { 0.0 }
    $last = if ($lastOverride -gt 0) { $lastOverride } elseif ($SceneTiming -and [double](Get-MojazProperty $SceneTiming 'OutroSeconds' 0) -gt 0) { [double](Get-MojazProperty $SceneTiming 'OutroSeconds' 0) } else { [math]::Max(1.0, [math]::Floor($delay / 2)) }
    # Asking for sync is not the same as getting it: a scene with no usable
    # loop falls back to the dwell rather than refusing to play.
    $loopPlan = $null
    if ([bool](Get-MojazProperty $Bulletin 'SyncToLoop' $false)) {
        $loopPlan = New-MojazLoopPlan -SceneTiming $SceneTiming -RowCount $rows.Count -OffsetSeconds $OffsetSeconds
    }
    $plan = @()
    $at = 0.0
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $hold = if ($rows.Count -eq 1) { $delay + $intro + $last } elseif ($index -eq 0) { $delay + $intro } elseif ($index -eq ($rows.Count - 1)) { $last } else { $delay }
        $moment = if ($loopPlan) { [double]@($loopPlan.WriteOffsets)[$index] } else { $at }
        $plan += [pscustomobject]@{
            Index = $index
            RowId = [string](Get-MojazProperty $rows[$index] 'Id' '')
            HoldSeconds = [int][math]::Round($hold)
            AtSeconds = $moment
        }
        $at += $hold
    }
    $exitAt = if ($holdOverride -gt 0) { $holdOverride } elseif ($loopPlan) { [double]$loopPlan.ExitOffset } else { $at }
    # The hold is the whole run, so a row may not be scheduled past it: a plan
    # that writes after the scene has been told to leave writes into nothing.
    if ($holdOverride -gt 0) { $plan = @($plan | Where-Object { [double]$_.AtSeconds -lt $holdOverride }) }
    $snapshot = [pscustomobject]@{
        Id = New-MojazId -Prefix run
        BulletinId = [string](Get-MojazProperty $Bulletin 'Id' '')
        BulletinName = [string](Get-MojazProperty $Bulletin 'Name' '')
        BulletinRevision = [int](Get-MojazProperty $Bulletin 'Revision' 1)
        ScheduleId = [string](Get-MojazProperty $Schedule 'Id' '')
        StartedAt = $Now.ToString('o')
        Rows = $rows; Plan = $plan
        SyncToLoop = [bool]$loopPlan
        LoopSeconds = $(if ($loopPlan) { [double]$loopPlan.LoopSeconds } else { 0 })
        FadeSeconds = $(if ($loopPlan) { [double]$loopPlan.FadeSeconds } else { 0 })
        HoldSeconds = $holdOverride
        ExitAtSeconds = $exitAt
        TotalSeconds = [int][math]::Ceiling($exitAt)
    }
    return (New-MojazResult $true $snapshot)
}

function Get-MojazDueQueue {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Schedules, [datetimeoffset]$Now = [datetimeoffset]::Now)
    return @($Schedules | Where-Object {
            [string](Get-MojazProperty $_ 'Status' '') -in @('scheduled', 'queued') -and
            [datetimeoffset](Get-MojazProperty $_ 'ScheduledAt') -le $Now
        } | Sort-Object @{ Expression = { [datetimeoffset]$_.ScheduledAt } },
            @{ Expression = { [datetimeoffset]$_.CreatedAt } },
            @{ Expression = { [string]$_.Id } })
}

function Update-MojazBulletinIn {
    <#
        Every edit is the same three moves: clone the library, find the
        bulletin, bump its revision. Only the middle step differs, so it is
        the only part a caller writes. Nothing mutates what was handed in -
        an edit that fails leaves the caller's library exactly as it was.

        A -Change block is run with & here, so it reads this function's
        variables, not its author's: name anything it closes over distinctly
        ($doomedRowId, not $target) or it silently picks up the local below.
    #>
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [Parameter(Mandatory)][scriptblock]$Change,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $copy = Copy-MojazValue $Library
    $target = @(@(Get-MojazProperty $copy 'Bulletins' @()) | Where-Object { [string]$_.Id -eq $BulletinId }) | Select-Object -First 1
    if (-not $target) { return (New-MojazResult $false $null 'not_found' 'الموجز غير موجود.') }
    $refusal = & $Change $target
    if ($refusal -is [pscustomobject] -and $refusal.PSObject.Properties.Match('ErrorCode').Count -gt 0) { return $refusal }
    $target.Revision = [int]$target.Revision + 1
    $target.UpdatedAt = $Now.ToString('o')
    $target.UpdatedBy = $UserId
    return (New-MojazResult $true $copy)
}

function Get-MojazRowImageMode {
    <# A row written before the modes existed says only whether it has a path,
       and that is exactly what the two original modes meant. #>
    param($Row)
    $mode = [string](Get-MojazProperty $Row 'ImageMode' '')
    if ($mode -in @('new', 'inherit', 'template')) { return $mode }
    return $(if ([string](Get-MojazProperty $Row 'Image' '')) { 'new' } else { 'inherit' })
}

function Get-MojazEffectiveImages {
    <#
        The picture each row actually puts on screen, in order.

        Only 'new' and 'template' send the image variable; 'inherit' leaves it
        out, so whatever is already in the scene stays - which is how one
        picture stands for a run of rows. The first row inherits from the
        scene itself, so a bulletin that never sets a picture shows the
        template's own throughout.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Rows, [string]$TemplateImage = '')
    $current = $TemplateImage
    $effective = @()
    foreach ($row in @($Rows)) {
        switch (Get-MojazRowImageMode -Row $row) {
            'new' { $current = [string](Get-MojazProperty $row 'Image' '') }
            'template' { $current = $TemplateImage }
        }
        $effective += $current
    }
    return $effective
}

function Get-MojazUsedImages {
    <# The distinct pictures this bulletin already carries, in the order they
       first appear - what the screen offers instead of a second upload. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Rows)
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($row in @($Rows)) {
        $image = [string](Get-MojazProperty $row 'Image' '')
        if ($image -and -not $seen.Contains($image)) { $seen.Add($image) }
    }
    return $seen.ToArray()
}

function Get-MojazFieldValues {
    <# The filled entries of a field bag, whatever shape it arrived in - a
       hashtable from the bridge, a PSCustomObject once it has been through
       JSON. Blank values are not entries: an untouched field is not data. #>
    [CmdletBinding()]
    param($Fields)
    if (-not $Fields) { return @{} }
    $values = @{}
    $pairs = if ($Fields -is [hashtable]) {
        @($Fields.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $Fields[$_] } })
    }
    else {
        @($Fields.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
    }
    foreach ($pair in $pairs) {
        $text = ([string]$pair.Value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $values[$pair.Name] = $text
    }
    return $values
}

function Add-MojazBulletinRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [string]$Image = '', [string]$Title = '', [string]$Text = '',
        # The design's own fields, keyed by the scene's variable names. Absent
        # for the built-in design, whose three are named above and unchanged.
        $Fields,
        [ValidateSet('', 'new', 'inherit', 'template')][string]$ImageMode = '',
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $rowTitle = ([string]$Title).Trim()
    $rowText = ([string]$Text).Trim()
    # A design carries whatever fields it declares, so emptiness is "nothing
    # in any of them" rather than "no title and no story". The old rule was
    # the news design's shape, and it would have refused a row on a
    # video-only design outright.
    # Resolved out here and given a name of its own, because the -Change
    # block below is invoked with & and is therefore dynamically scoped:
    # $PSBoundParameters inside it is Update-MojazBulletinIn's, not this
    # function's, so asking it there always answers no.
    $rowFields = if ($PSBoundParameters.ContainsKey('Fields')) { Get-MojazFieldValues -Fields $Fields } else { $null }
    if ($null -ne $rowFields) {
        # Not @($hashtable).Count - that wraps the table in a one-element
        # array and answers 1 however empty the table is.
        if ($rowFields.Count -eq 0) {
            return (New-MojazResult $false $null 'empty_row' 'الصف فارغ: لم يُملأ أي حقل من حقول التصميم.')
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($rowTitle) -and [string]::IsNullOrWhiteSpace($rowText)) {
        return (New-MojazResult $false $null 'empty_row' 'الصف بلا عنوان ولا نص.')
    }
    $rowImage = ([string]$Image).Trim()
    # Given a mode, take it; otherwise a path means 'new' and none means
    # 'inherit', which is what the caller is saying either way.
    $rowMode = if ($ImageMode) { $ImageMode } elseif ($rowImage) { 'new' } else { 'inherit' }
    if ($rowMode -ne 'new') { $rowImage = '' }
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            $row = [pscustomobject]@{
                Id = New-MojazId -Prefix r
                ImageMode = $rowMode
                Image = $rowImage; Title = $rowTitle; Text = $rowText
            }
            # Carried alongside the built-in three rather than instead of
            # them: a bulletin moved from one design to another keeps what the
            # new design has no field for, so moving it back loses nothing.
            if ($null -ne $rowFields) {
                $bag = [pscustomobject]@{}
                foreach ($entry in $rowFields.GetEnumerator()) {
                    $bag | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
                }
                $row | Add-Member -NotePropertyName Fields -NotePropertyValue $bag -Force
            }
            $bulletin.Rows = @(@(Get-MojazProperty $bulletin 'Rows' @()) + $row)
        })
}

function Set-MojazBulletinRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [Parameter(Mandatory)][string]$RowId, [string]$Title, [string]$Text, [string]$Image,
        [ValidateSet('', 'new', 'inherit', 'template')][string]$ImageMode = '',
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $fields = $PSBoundParameters
    $editedRowId = $RowId
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            $row = @(@(Get-MojazProperty $bulletin 'Rows' @()) | Where-Object { [string]$_.Id -eq $editedRowId }) | Select-Object -First 1
            if (-not $row) { return (New-MojazResult $false $null 'row_not_found' 'الصف غير موجود.') }
            if ($fields.ContainsKey('Title')) { $row.Title = ([string]$Title).Trim() }
            if ($fields.ContainsKey('Text')) { $row.Text = ([string]$Text).Trim() }
            if ($fields.ContainsKey('Image') -or $fields.ContainsKey('ImageMode')) {
                $path = ([string]$Image).Trim()
                $mode = if ($ImageMode) { $ImageMode } elseif ($path) { 'new' } else { 'inherit' }
                $row.ImageMode = $mode
                $row.Image = $(if ($mode -eq 'new') { $path } else { '' })
            }
            if ([string]::IsNullOrWhiteSpace([string]$row.Title) -and [string]::IsNullOrWhiteSpace([string]$row.Text)) {
                return (New-MojazResult $false $null 'empty_row' 'الصف بلا عنوان ولا نص.')
            }
        })
}

function Remove-MojazBulletinRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [Parameter(Mandatory)][string]$RowId,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $doomedRowId = $RowId
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            $rows = @(Get-MojazProperty $bulletin 'Rows' @())
            # By id, never by value: two identical rows are legitimate and a
            # value match would drop both.
            $kept = @($rows | Where-Object { [string]$_.Id -ne $doomedRowId })
            if ($kept.Count -eq $rows.Count) { return (New-MojazResult $false $null 'row_not_found' 'الصف غير موجود.') }
            $bulletin.Rows = $kept
        })
}

function Move-MojazBulletinRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [Parameter(Mandatory)][string]$RowId, [Parameter(Mandatory)][ValidateSet('up', 'down')][string]$Direction,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $wanted = $RowId
    $step = if ($Direction -eq 'up') { -1 } else { 1 }
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($row in @(Get-MojazProperty $bulletin 'Rows' @())) { $rows.Add($row) }
            $index = -1
            for ($i = 0; $i -lt $rows.Count; $i++) { if ([string]$rows[$i].Id -eq $wanted) { $index = $i; break } }
            if ($index -lt 0) { return (New-MojazResult $false $null 'row_not_found' 'الصف غير موجود.') }
            $destination = $index + $step
            if ($destination -lt 0 -or $destination -ge $rows.Count) { return (New-MojazResult $false $null 'at_edge' 'الصف في طرف الجدول.') }
            $moved = $rows[$index]
            $rows.RemoveAt($index)
            $rows.Insert($destination, $moved)
            $bulletin.Rows = $rows.ToArray()
        })
}

function Clear-MojazBulletinRows {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            $bulletin.Rows = @()
        })
}

function Set-MojazBulletinTiming {
    <# 0 for either override means "follow the scene", which is what the loop
       markers in the .cintitle already answer. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [int]$DelayFrames, [int]$IntroExtraFrames, [int]$LastRowFrames, [int]$HoldFrames,
        [nullable[bool]]$SyncToLoop,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $fields = $PSBoundParameters
    if ($fields.ContainsKey('DelayFrames') -and ($DelayFrames -lt 1 -or $DelayFrames -gt 15000)) {
        return (New-MojazResult $false $null 'out_of_range' 'المدة بين ١ و١٥٠٠٠ إطار.')
    }
    if ($fields.ContainsKey('HoldFrames') -and ($HoldFrames -lt 0 -or $HoldFrames -gt 90000)) {
        return (New-MojazResult $false $null 'out_of_range' 'مدة البقاء بين ٠ و٩٠٠٠٠ إطار (٠ = تتبع الصفوف).')
    }
    # Frames, because that is the unit the animation is cut in. Ten minutes
    # at 25 fps is the ceiling, which is far past anything a bulletin needs.
    if ($fields.ContainsKey('IntroExtraFrames') -and ($IntroExtraFrames -lt 0 -or $IntroExtraFrames -gt 15000)) {
        return (New-MojazResult $false $null 'out_of_range' 'زمن الدخول بين ٠ و١٥٠٠٠ إطار.')
    }
    if ($fields.ContainsKey('LastRowFrames') -and ($LastRowFrames -lt 0 -or $LastRowFrames -gt 15000)) {
        return (New-MojazResult $false $null 'out_of_range' 'زمن الخروج بين ٠ و١٥٠٠٠ إطار.')
    }
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            foreach ($pair in @(@('DelayFrames', $DelayFrames), @('IntroExtraFrames', $IntroExtraFrames), @('LastRowFrames', $LastRowFrames), @('HoldFrames', $HoldFrames))) {
                if (-not $fields.ContainsKey($pair[0])) { continue }
                # Bulletins written before frames existed carry neither field.
                if ($bulletin.PSObject.Properties.Match($pair[0]).Count -eq 0) {
                    $bulletin | Add-Member -NotePropertyName $pair[0] -NotePropertyValue ([int]$pair[1])
                }
                else { $bulletin.$($pair[0]) = [int]$pair[1] }
            }
            if ($fields.ContainsKey('SyncToLoop')) {
                # Bulletins written before the loop mode existed have no such
                # property, so it is added rather than assigned.
                if ($bulletin.PSObject.Properties.Match('SyncToLoop').Count -eq 0) {
                    $bulletin | Add-Member -NotePropertyName 'SyncToLoop' -NotePropertyValue ([bool]$SyncToLoop)
                }
                else { $bulletin.SyncToLoop = [bool]$SyncToLoop }
            }
        })
}

function Remove-MojazBulletin {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId)
    $copy = Copy-MojazValue $Library
    $bulletins = @(Get-MojazProperty $copy 'Bulletins' @())
    $kept = @($bulletins | Where-Object { [string]$_.Id -ne $BulletinId })
    if ($kept.Count -eq $bulletins.Count) { return (New-MojazResult $false $null 'not_found' 'الموجز غير موجود.') }
    $copy.Bulletins = $kept
    return (New-MojazResult $true $copy)
}

function Get-MojazBulletin {
    param($Library, [string]$BulletinId)
    if (-not $BulletinId) { return $null }
    return (@(@(Get-MojazProperty $Library 'Bulletins' @()) | Where-Object { [string]$_.Id -eq $BulletinId }) | Select-Object -First 1)
}

function Test-BridgeSceneUsable {
    <#
        May a bulletin play on this scene at all?

        Deliberately narrow, and narrower than the rule this replaced. That one
        demanded a picture, a title and a story - the shape of the news
        bulletin that happened to be built first - which would have refused a
        design that is a single video, and a video-only bulletin is a
        perfectly good bulletin.

        Only two things are true of every design:

          - something to fill. A variable that no element consumes is not a
            field; a scene with none has nothing for a row to change.
        A loop is reported, not required: SupportsRows says whether the scene
        can hold while row after row is written into it. Without one the design
        still works - it carries a single story, which is what a video report
        is - so the caller offers one row and an operator-set moment to leave.

        Everything else - whether it wants a headline, a picture, both, or
        neither - is the design's business, to be discovered and asked for,
        never required.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Xml)
    $fields = @(Get-BridgeSceneFields -Xml $Xml | Where-Object { $_.Consumed })
    if ($fields.Count -eq 0) {
        return [pscustomobject]@{ Usable = $false; Reason = 'لا يحمل هذا المشهد حقلًا واحدًا يُحدَّث، فلا شيء يعرضه الموجز.'; Fields = @(); SupportsRows = $false }
    }
    $start = [regex]::Match($Xml, 'LoopStartFrame\s*=\s*"([0-9]+)"')
    $end = [regex]::Match($Xml, 'LoopEndFrame\s*=\s*"([0-9]+)"')
    $hasLoop = $start.Success -and $end.Success -and [int]$end.Groups[1].Value -gt [int]$start.Groups[1].Value
    # A loop is what lets one scene hold while row after row is written into
    # it. A design without one is not thereby unusable - it is a design that
    # carries ONE story: a video report is a single item, and it enters, plays
    # and leaves. Refusing it was the third time I mistook the news design's
    # shape for the shape of every bulletin.
    return [pscustomobject]@{ Usable = $true; Reason = ''; Fields = $fields; SupportsRows = $hasLoop }
}

function Get-BridgeSceneFields {
    <#
        What a Cinegy scene asks to be given, read from the scene itself.

        A bulletin design declares its own contract and there is no reason to
        mirror that declaration by hand in JSON: a hand-written copy drifts the
        first time somebody renames a variable in Cinegy, and it drifts
        silently - the bulletin goes to air with an empty box and nothing
        complains. So the scene is the single source of truth for WHICH fields
        exist and WHAT SHAPE each one is.

            <Var  Name="mojaz_img"  Type="File" />
            <Plate Name="img 01" Size="525.38;291.61" File="${mojaz_img}">

        The variable gives the name and the type; the element that consumes it
        gives the kind and, for media, the exact pixel size the design was
        drawn for - which is a better number than any global setting, because
        it is this design's number.

        What the scene CANNOT say is what to call a field in Arabic, what order
        to ask in, or whether it may be left empty. Those are editorial and
        come from the template registry. This returns the contract, not the
        wording.

        A variable no element consumes is still returned, with Consumed false:
        it is a field an operator would be asked to fill whose value would then
        appear nowhere, and the caller should say so rather than hide it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Xml)

    if ([string]::IsNullOrWhiteSpace($Xml)) { return @() }
    $fields = [System.Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($Xml, '<Var\s[^>]*?/?>')) {
        $declaration = $match.Value
        $name = [regex]::Match($declaration, 'Name\s*=\s*"([^"]*)"')
        if (-not $name.Success -or [string]::IsNullOrWhiteSpace($name.Groups[1].Value)) { continue }
        $variable = $name.Groups[1].Value
        $type = [regex]::Match($declaration, 'Type\s*=\s*"([^"]*)"')
        $declaredType = if ($type.Success) { $type.Groups[1].Value } else { 'String' }

        # The element that reads ${variable}. Escaped, because a variable name
        # may hold a dot - 'title.Text' is the common case here, and an
        # unescaped dot would match a different variable's element.
        $consumer = [regex]::Match($Xml, '<(?<element>[A-Za-z]+)\s[^>]*\$\{' + [regex]::Escape($variable) + '\}[^>]*>')
        $element = if ($consumer.Success) { $consumer.Groups['element'].Value } else { '' }

        $width = 0.0
        $height = 0.0
        if ($consumer.Success) {
            $size = [regex]::Match($consumer.Value, 'Size\s*=\s*"([0-9.]+)\s*;\s*([0-9.]+)"')
            if ($size.Success) {
                [void][double]::TryParse($size.Groups[1].Value, [ref]$width)
                [void][double]::TryParse($size.Groups[2].Value, [ref]$height)
            }
        }

        $fields.Add([pscustomobject]@{
                Name     = $variable
                Type     = $declaredType
                # 'media' rather than 'image': every scene here holds its
                # pictures and its movies in the same Plate with a file
                # source, so the scene cannot tell the two apart and neither
                # can this. What arrives decides, and the caller bounds it.
                Kind     = if ($declaredType -eq 'File') { 'media' } else { 'text' }
                Element  = $element
                Consumed = $consumer.Success
                Width    = [int][math]::Round($width)
                Height   = [int][math]::Round($height)
            })
    }
    return @($fields)
}

Export-ModuleMember -Function New-MojazLibrary, Add-MojazBulletin, Copy-MojazBulletin,
    Get-MojazRowImageMode, Get-MojazEffectiveImages, Get-MojazUsedImages,
    Rename-MojazBulletin, Remove-MojazBulletin, Get-MojazBulletin, New-MojazRunSnapshot, New-MojazLoopPlan, Get-MojazDueQueue,
    Add-MojazBulletinRow, Set-MojazBulletinRow, Remove-MojazBulletinRow, Move-MojazBulletinRow,
    Clear-MojazBulletinRows, Set-MojazBulletinTiming, Get-BridgeSceneFields, Test-BridgeSceneUsable, Get-MojazFieldValues
