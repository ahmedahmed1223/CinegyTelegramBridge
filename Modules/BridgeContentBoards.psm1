Import-Module (Join-Path $PSScriptRoot 'BridgeAirText.psm1')
Set-StrictMode -Version Latest

<#
    Programme content boards: a named table of prepared rows bound to one
    programme's template.

    A producer writes the texts ahead of the show; an operator in the gallery
    picks a row and puts it on air. Nothing here plays a sequence - there is no
    engine in this feature at all, deliberately, because the workflow it serves
    is choose-and-show, and a third run-plan implementation beside the bulletin
    and the breaking-news board is the duplication AGENTS.md warns about.

    Domain only. Nothing here talks to Telegram, to Cinegy, or to the disk. The
    scene's fields are handed in rather than read here, so the same list can be
    drawn on a screen and validated against without either side reading the
    .cintitle a second time.
#>

function New-BoardResult {
    param([bool]$Success, $Value = $null, [string]$ErrorCode = '', [string]$ErrorMessage = '')
    return [pscustomobject]@{ Success = $Success; Value = $Value; ErrorCode = $ErrorCode; Error = $ErrorMessage }
}

function Get-BoardProperty {
    <#
        Reads one field off either shape a board can arrive in.

        Written as objects and read back as objects, but a test or a caller
        builds one as a hashtable - and [ordered]@{} is neither, being an
        OrderedDictionary whose keys are not PSObject properties at all. So the
        dictionary case is tested by interface, not by [hashtable].
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

function Copy-BoardValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    return ($Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function New-BoardId {
    # Eight hex, not a full GUID. callback_data is capped at 64 BYTES, and a
    # row button carries both ids: "boards:i:b_1a2b3c4d:i_5e6f7a8b:text" is 37.
    # Two full GUIDs would be 78 before the prefix - which is exactly how the
    # mojazdesign: buttons came to exceed the cap and refuse the whole message.
    return "b_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}

function New-BoardItemId {
    return "i_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}

function ConvertTo-BoardText {
    # Every board value passes here - add, edit, paste, the board's name - so
    # the invisible characters a paste carries are dropped here, once.
    param([string]$Text)
    return ((Remove-BridgeInvisibleText -Text ([string]$Text)) -replace '\s+', ' ').Trim()
}

function Test-BoardEditRole {
    param([string]$Role)
    return (@('all', 'admin', 'owner') -contains ([string]$Role).ToLowerInvariant())
}

function New-ContentBoard {
    <#
        A named table bound to one programme template.

        The fields are NOT stored. They are read from the scene every time they
        are needed, so a scene re-cut in Titler re-shapes the table with nothing
        to update here - and there is no second copy of the field list to drift
        from the first.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        # AllowEmptyString, so an empty key is REFUSED with a named reason
        # rather than throwing a binding exception. This module's contract is
        # that a caller gets a result object it can put on a screen; a binder
        # that throws first hands them something they cannot show anyone.
        [Parameter(Mandatory)][AllowEmptyString()][string]$TemplateKey,
        [long]$UserId = 0,
        [string]$EditRole = 'all',
        [int]$MaxNameLength = 60
    )
    $cleanName = ConvertTo-BoardText -Text $Name
    if ([string]::IsNullOrWhiteSpace($cleanName)) {
        return (New-BoardResult $false $null 'invalid_name' 'اسم الجدول مطلوب.')
    }
    if ($cleanName.Length -gt $MaxNameLength) {
        return (New-BoardResult $false $null 'name_too_long' "اسم الجدول أطول من $MaxNameLength حرفًا.")
    }
    if ([string]::IsNullOrWhiteSpace($TemplateKey)) {
        return (New-BoardResult $false $null 'invalid_template' 'لا بدّ من قالب للجدول.')
    }
    if (-not (Test-BoardEditRole -Role $EditRole)) {
        return (New-BoardResult $false $null 'invalid_role' 'صلاحية التحرير غير معروفة.')
    }
    return (New-BoardResult $true ([pscustomobject]@{
                Id = New-BoardId
                Name = $cleanName
                TemplateKey = [string]$TemplateKey
                # 'all' by default: a table nobody may fill is a feature that is
                # dead on delivery. A station that wants the producer/operator
                # split raises this to 'admin' deliberately.
                EditRole = ([string]$EditRole).ToLowerInvariant()
                CreatedAt = [datetimeoffset]::Now.ToString('o')
                CreatedByUserId = [long]$UserId
                Revision = 1
                Items = @()
            }))
}

function Get-BoardItem {
    param($Board, [Parameter(Mandatory)][string]$ItemId)
    foreach ($item in @(Get-BoardProperty $Board 'Items' @())) {
        if ([string](Get-BoardProperty $item 'Id' '') -eq $ItemId) { return $item }
    }
    return $null
}

function Get-BoardItemPosition {
    param($Board, [Parameter(Mandatory)][string]$ItemId)
    $items = @(Get-BoardProperty $Board 'Items' @())
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ([string](Get-BoardProperty $items[$i] 'Id' '') -eq $ItemId) { return $i }
    }
    return -1
}

function Update-ContentBoard {
    <#
        Every change to a board goes through here: a copy is changed and
        returned, and the board handed in is never touched.

        The run this feature does not have is exactly why that still matters -
        a caller that mutated the live board would leave a half-applied table
        on screen when the change was refused a line later.
    #>
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][scriptblock]$Change, [long]$UserId = 0)
    $copy = Copy-BoardValue -Value $Board
    $outcome = & $Change $copy
    if ($outcome -is [pscustomobject] -and $outcome.PSObject.Properties.Match('Success').Count -gt 0 -and -not $outcome.Success) {
        return $outcome
    }
    $copy.Revision = [int](Get-BoardProperty $copy 'Revision' 0) + 1
    $copy | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue ([datetimeoffset]::Now.ToString('o')) -Force
    $copy | Add-Member -NotePropertyName UpdatedByUserId -NotePropertyValue ([long]$UserId) -Force
    return (New-BoardResult $true $copy)
}

function Set-BoardEditRole {
    <#
        Who may fill this board: 'all', 'admin' or 'owner'.

        New-ContentBoard took this at birth and nothing could change it
        afterwards, so a board created open stayed open forever - and the
        screen had no way to say otherwise. A role you can set once and never
        correct is a role nobody dares set.
    #>
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][string]$Role, [long]$UserId = 0)
    if (-not (Test-BoardEditRole -Role $Role)) { return (New-BoardResult $false $null 'invalid_role') }
    $roleValue = ([string]$Role).ToLowerInvariant()
    return (Update-ContentBoard -Board $Board -UserId $UserId -Change {
            param($copy)
            $copy | Add-Member -NotePropertyName EditRole -NotePropertyValue $roleValue -Force
        })
}

function Add-BoardItem {
    <#
        One prepared row.

        Values are keyed by the scene's own variable names. A value for a
        variable the scene does not declare is refused rather than stored: a
        table that silently holds fields nothing will ever send is a table
        whose producer believes work is done that is not.
    #>
    param(
        [Parameter(Mandatory)]$Board,
        [Parameter(Mandatory)][hashtable]$Values,
        # AllowEmptyCollection for the same reason: a scene declaring no text
        # field is a real case here - two of this station's four templates
        # declare none at all - and it is answered, not thrown.
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TextFields,
        [long]$UserId = 0,
        [int]$MaxItems = 100,
        [int]$MaxFieldLength = 500
    )
    if (@($TextFields).Count -lt 1) {
        return (New-BoardResult $false $null 'no_fields' 'هذا المشهد لا يعلن حقلًا نصّيًا واحدًا.')
    }
    $items = @(Get-BoardProperty $Board 'Items' @())
    if ($items.Count -ge $MaxItems) {
        return (New-BoardResult $false $null 'full' "بلغ الجدول سقفه ($MaxItems صفًّا).")
    }
    $clean = @{}
    $filled = 0
    foreach ($field in $TextFields) {
        $raw = if ($Values.ContainsKey($field)) { ConvertTo-BoardText -Text ([string]$Values[$field]) } else { '' }
        if ($raw.Length -gt $MaxFieldLength) {
            return (New-BoardResult $false $null 'too_long' "قيمة «$field» أطول من $MaxFieldLength حرفًا.")
        }
        $clean[$field] = $raw
        if ($raw) { $filled++ }
    }
    # An entirely empty row is not a row. It reaches air as a blank graphic,
    # which reads to the gallery as a fault rather than as a choice.
    if ($filled -lt 1) {
        return (New-BoardResult $false $null 'empty' 'لا بدّ من ملء حقل واحد على الأقل.')
    }
    return (Update-ContentBoard -Board $Board -UserId $UserId -Change {
            param($board)
            $board.Items = @(@($board.Items) + [pscustomobject]@{
                    Id = New-BoardItemId
                    Values = [pscustomobject]$clean
                    Enabled = $true
                    UpdatedAt = [datetimeoffset]::Now.ToString('o')
                    UpdatedByUserId = [long]$UserId
                })
        })
}

function Set-BoardItemField {
    param(
        [Parameter(Mandatory)]$Board,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string[]]$TextFields,
        [long]$UserId = 0,
        [int]$MaxFieldLength = 500
    )
    if ($TextFields -notcontains $Field) {
        return (New-BoardResult $false $null 'unknown_field' 'هذا الحقل لم يعد في المشهد.')
    }
    $clean = ConvertTo-BoardText -Text $Value
    if ($clean.Length -gt $MaxFieldLength) {
        return (New-BoardResult $false $null 'too_long' "القيمة أطول من $MaxFieldLength حرفًا.")
    }
    if (-not (Get-BoardItem -Board $Board -ItemId $ItemId)) {
        return (New-BoardResult $false $null 'missing_item' 'الصفّ غير موجود.')
    }
    return (Update-ContentBoard -Board $Board -UserId $UserId -Change {
            param($board)
            foreach ($item in @($board.Items)) {
                if ([string]$item.Id -ne $ItemId) { continue }
                $item.Values | Add-Member -NotePropertyName $Field -NotePropertyValue $clean -Force
                $item.UpdatedAt = [datetimeoffset]::Now.ToString('o')
                $item.UpdatedByUserId = [long]$UserId
            }
        })
}

function Set-BoardItemEnabled {
    <# Enabled is the only thing it says: a disabled row cannot be shown. There
       is no run here for it to be excluded from, so it means one thing and not
       two - the trap that made every bulletin draft look unlocked. #>
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][string]$ItemId, [bool]$Enabled, [long]$UserId = 0)
    if (-not (Get-BoardItem -Board $Board -ItemId $ItemId)) {
        return (New-BoardResult $false $null 'missing_item' 'الصفّ غير موجود.')
    }
    # Copied to a distinctly named local first: the Change block is invoked with
    # & and so reads this function's variables by dynamic scope, which AGENTS.md
    # says to make visible rather than rely on quietly.
    $enabledValue = $Enabled
    return (Update-ContentBoard -Board $Board -UserId $UserId -Change {
            param($board)
            foreach ($item in @($board.Items)) {
                if ([string]$item.Id -ne $ItemId) { continue }
                $item.Enabled = $enabledValue
                $item.UpdatedAt = [datetimeoffset]::Now.ToString('o')
                $item.UpdatedByUserId = [long]$UserId
            }
        })
}

function Move-BoardItem {
    <# Order is the array's own order, not a stored number beside it. A second
       source of truth for position drifts from the first at the next insert. #>
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][string]$ItemId, [Parameter(Mandatory)][int]$Delta, [long]$UserId = 0)
    $position = Get-BoardItemPosition -Board $Board -ItemId $ItemId
    if ($position -lt 0) { return (New-BoardResult $false $null 'missing_item' 'الصفّ غير موجود.') }
    $items = @(Get-BoardProperty $Board 'Items' @())
    $target = $position + $Delta
    if ($target -lt 0 -or $target -ge $items.Count) {
        return (New-BoardResult $false $null 'at_edge' 'الصفّ في طرف الجدول.')
    }
    return (Update-ContentBoard -Board $Board -UserId $UserId -Change {
            param($board)
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($item in @($board.Items)) { $list.Add($item) | Out-Null }
            $moving = $list[$position]
            $list.RemoveAt($position)
            $list.Insert($target, $moving)
            $board.Items = @($list.ToArray())
        })
}

function Remove-BoardItem {
    param([Parameter(Mandatory)]$Board, [Parameter(Mandatory)][string]$ItemId, [long]$UserId = 0)
    if (-not (Get-BoardItem -Board $Board -ItemId $ItemId)) {
        return (New-BoardResult $false $null 'missing_item' 'الصفّ غير موجود.')
    }
    return (Update-ContentBoard -Board $Board -UserId $UserId -Change {
            param($board)
            $board.Items = @(@($board.Items) | Where-Object { [string]$_.Id -ne $ItemId })
        })
}

function Get-BoardItemValues {
    <#
        The values this row sends, as the scene's own field names.

        Only the fields the scene still declares. A value stored for a variable
        that has since been cut from the scene is KEPT on disk and simply not
        sent: destroying a producer's text because a designer moved a variable
        punishes the wrong person. The screen says the field is no longer there.
    #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string[]]$TextFields)
    $values = @{}
    $stored = Get-BoardProperty $Item 'Values' $null
    foreach ($field in $TextFields) {
        $values[$field] = [string](Get-BoardProperty $stored $field '')
    }
    return $values
}

function Get-BoardOrphanFields {
    <# Fields the row carries that the scene no longer declares, so a screen can
       say so instead of leaving a producer wondering where their text went. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string[]]$TextFields)
    $stored = Get-BoardProperty $Item 'Values' $null
    if ($null -eq $stored) { return @() }
    $names = if ($stored -is [System.Collections.IDictionary]) { @($stored.Keys) } else { @($stored.PSObject.Properties.Name) }
    return @($names | Where-Object { $TextFields -notcontains $_ } | Sort-Object)
}

function ConvertFrom-BoardPasteText {
    <#
        A producer's pasted block into rows.

        One line per row, fields in the scene's own order separated by a pipe -
        and with a single field there is no separator to get wrong at all.

        Refuses nothing silently: the caller is handed what parsed AND what was
        dropped, because "23 rows added" with no mention of the seven that were
        not is the shape of a screen an operator stops believing.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string[]]$TextFields,
        [string]$Separator = '|'
    )
    $rows = [System.Collections.Generic.List[hashtable]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ([string]$Text -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $parts = @($trimmed -split ([regex]::Escape($Separator)))
        if ($parts.Count -gt $TextFields.Count) {
            $skipped.Add("سطر فيه $($parts.Count) حقلًا والمشهد يعلن $($TextFields.Count)") | Out-Null
            continue
        }
        $values = @{}
        $filled = 0
        for ($i = 0; $i -lt $TextFields.Count; $i++) {
            $value = if ($i -lt $parts.Count) { ConvertTo-BoardText -Text $parts[$i] } else { '' }
            $values[$TextFields[$i]] = $value
            if ($value) { $filled++ }
        }
        if ($filled -lt 1) { continue }
        $rows.Add($values) | Out-Null
    }
    return [pscustomobject]@{ Rows = @($rows.ToArray()); Skipped = @($skipped.ToArray()) }
}

Export-ModuleMember -Function New-BoardResult, Get-BoardProperty, Copy-BoardValue, New-BoardId,
New-BoardItemId, ConvertTo-BoardText, Test-BoardEditRole, New-ContentBoard, Get-BoardItem,
Get-BoardItemPosition, Update-ContentBoard, Set-BoardEditRole, Add-BoardItem, Set-BoardItemField, Set-BoardItemEnabled,
Move-BoardItem, Remove-BoardItem, Get-BoardItemValues, Get-BoardOrphanFields, ConvertFrom-BoardPasteText
