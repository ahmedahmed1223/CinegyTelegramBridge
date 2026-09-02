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
        [int]$DelaySeconds = 8,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $normalized = ConvertTo-MojazName -Name $Name
    if ([string]::IsNullOrWhiteSpace($normalized)) { return (New-MojazResult $false $null 'invalid_name' 'اسم الموجز مطلوب.') }
    if (-not (Test-MojazNameAvailable -Library $Library -Name $normalized)) { return (New-MojazResult $false $null 'duplicate_name' 'يوجد موجز بهذا الاسم.') }
    $copy = Copy-MojazValue $Library
    $bulletins = @($copy.Bulletins)
    $bulletin = [pscustomobject]@{
        Id = New-MojazId -Prefix b; Name = $normalized; Revision = 1
        CreatedAt = $Now.ToString('o'); UpdatedAt = $Now.ToString('o'); UpdatedBy = $UserId
        DelaySeconds = [math]::Min(600, [math]::Max(1, $DelaySeconds))
        IntroExtraSeconds = 0; LastRowSeconds = 0; Rows = @()
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

function New-MojazRunSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Bulletin, $SceneTiming = $null, $Schedule = $null,
        [datetimeoffset]$Now = [datetimeoffset]::Now)
    $rows = @(Copy-MojazValue @(Get-MojazProperty $Bulletin 'Rows' @()))
    if ($rows.Count -eq 0) { return (New-MojazResult $false $null 'empty_bulletin' 'الموجز بلا صفوف.') }
    $delay = [math]::Max(1, [int](Get-MojazProperty $Bulletin 'DelaySeconds' 8))
    $introOverride = [int](Get-MojazProperty $Bulletin 'IntroExtraSeconds' 0)
    $lastOverride = [int](Get-MojazProperty $Bulletin 'LastRowSeconds' 0)
    $intro = if ($introOverride -gt 0) { $introOverride } elseif ($SceneTiming) { [int][math]::Ceiling([double](Get-MojazProperty $SceneTiming 'IntroSeconds' 0)) } else { 0 }
    $last = if ($lastOverride -gt 0) { $lastOverride } elseif ($SceneTiming -and [double](Get-MojazProperty $SceneTiming 'OutroSeconds' 0) -gt 0) { [int][math]::Ceiling([double](Get-MojazProperty $SceneTiming 'OutroSeconds' 0)) } else { [math]::Max(1, [int][math]::Floor($delay / 2)) }
    $plan = @()
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $hold = if ($rows.Count -eq 1) { $delay + $intro + $last } elseif ($index -eq 0) { $delay + $intro } elseif ($index -eq ($rows.Count - 1)) { $last } else { $delay }
        $plan += [pscustomobject]@{ Index = $index; RowId = [string](Get-MojazProperty $rows[$index] 'Id' ''); HoldSeconds = [int]$hold }
    }
    $snapshot = [pscustomobject]@{
        Id = New-MojazId -Prefix run
        BulletinId = [string](Get-MojazProperty $Bulletin 'Id' '')
        BulletinName = [string](Get-MojazProperty $Bulletin 'Name' '')
        BulletinRevision = [int](Get-MojazProperty $Bulletin 'Revision' 1)
        ScheduleId = [string](Get-MojazProperty $Schedule 'Id' '')
        StartedAt = $Now.ToString('o')
        Rows = $rows; Plan = $plan
        TotalSeconds = [int](($plan | Measure-Object -Property HoldSeconds -Sum).Sum)
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

function Add-MojazBulletinRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [string]$Image = '', [string]$Title = '', [string]$Text = '',
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $rowTitle = ([string]$Title).Trim()
    $rowText = ([string]$Text).Trim()
    if ([string]::IsNullOrWhiteSpace($rowTitle) -and [string]::IsNullOrWhiteSpace($rowText)) {
        return (New-MojazResult $false $null 'empty_row' 'الصف بلا عنوان ولا نص.')
    }
    $rowImage = ([string]$Image).Trim()
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            # ponytail: two image modes. 'inherit' omits the variable so the
            # scene keeps whatever picture is already in it; 'new' sends a
            # path. A third 'default' mode needs a default in the template
            # record - add it when a template actually carries one.
            $row = [pscustomobject]@{
                Id = New-MojazId -Prefix r
                ImageMode = $(if ($rowImage) { 'new' } else { 'inherit' })
                Image = $rowImage; Title = $rowTitle; Text = $rowText
            }
            $bulletin.Rows = @(@(Get-MojazProperty $bulletin 'Rows' @()) + $row)
        })
}

function Set-MojazBulletinRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library, [Parameter(Mandatory)][string]$BulletinId,
        [Parameter(Mandatory)][string]$RowId, [string]$Title, [string]$Text, [string]$Image,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $fields = $PSBoundParameters
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            $row = @(@(Get-MojazProperty $bulletin 'Rows' @()) | Where-Object { [string]$_.Id -eq $RowId }) | Select-Object -First 1
            if (-not $row) { return (New-MojazResult $false $null 'row_not_found' 'الصف غير موجود.') }
            if ($fields.ContainsKey('Title')) { $row.Title = ([string]$Title).Trim() }
            if ($fields.ContainsKey('Text')) { $row.Text = ([string]$Text).Trim() }
            if ($fields.ContainsKey('Image')) {
                $row.Image = ([string]$Image).Trim()
                $row.ImageMode = $(if ($row.Image) { 'new' } else { 'inherit' })
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
        [int]$DelaySeconds, [int]$IntroExtraSeconds, [int]$LastRowSeconds,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [long]$UserId = 0)
    $fields = $PSBoundParameters
    if ($fields.ContainsKey('DelaySeconds') -and ($DelaySeconds -lt 1 -or $DelaySeconds -gt 600)) {
        return (New-MojazResult $false $null 'out_of_range' 'المدة بين ١ و٦٠٠ ثانية.')
    }
    if ($fields.ContainsKey('IntroExtraSeconds') -and ($IntroExtraSeconds -lt 0 -or $IntroExtraSeconds -gt 600)) {
        return (New-MojazResult $false $null 'out_of_range' 'زمن الدخول بين ٠ و٦٠٠ ثانية.')
    }
    if ($fields.ContainsKey('LastRowSeconds') -and ($LastRowSeconds -lt 0 -or $LastRowSeconds -gt 600)) {
        return (New-MojazResult $false $null 'out_of_range' 'زمن الخروج بين ٠ و٦٠٠ ثانية.')
    }
    return (Update-MojazBulletinIn -Library $Library -BulletinId $BulletinId -Now $Now -UserId $UserId -Change {
            param($bulletin)
            if ($fields.ContainsKey('DelaySeconds')) { $bulletin.DelaySeconds = $DelaySeconds }
            if ($fields.ContainsKey('IntroExtraSeconds')) { $bulletin.IntroExtraSeconds = $IntroExtraSeconds }
            if ($fields.ContainsKey('LastRowSeconds')) { $bulletin.LastRowSeconds = $LastRowSeconds }
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

Export-ModuleMember -Function New-MojazLibrary, Add-MojazBulletin, Copy-MojazBulletin,
    Rename-MojazBulletin, Remove-MojazBulletin, Get-MojazBulletin, New-MojazRunSnapshot, Get-MojazDueQueue,
    Add-MojazBulletinRow, Set-MojazBulletinRow, Remove-MojazBulletinRow, Move-MojazBulletinRow,
    Clear-MojazBulletinRows, Set-MojazBulletinTiming
