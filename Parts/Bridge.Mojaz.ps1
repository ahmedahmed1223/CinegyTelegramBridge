#requires -Version 7
<#
    Bridge.Mojaz.ps1 - the bulletin library.

    A bulletin is a named table of rows: a picture, a title, a story. The
    library holds as many as the newsroom wants, each with its own timing, and
    a run resolves the latest saved revision at the moment it starts.

    The rules that touch neither Telegram, disk nor Cinegy live in
    Modules\BridgeMojaz.psm1 and are tested on their own. What is here is the
    orchestration: persistence, screens, and the walk down the table on air.

    One scene, not one per row. The Mojaz scene animates in, loops, and
    animates out on EXIT, so showing the template again for every story would
    replay the entrance and flash the screen between them. The first row is a
    SHOW; every row after it is written into the running scene through the
    postbox; the last row holds for the outro's own length and then EXIT plays
    it.
#>

# The scene's own variable names, from mojaz.cintitle. Hard-coded on purpose:
# this screen is that template's, and a rename there is a change here.
$script:MojazImageVariable = 'mojaz_img'
$script:MojazTitleVariable = 'title.Text'
$script:MojazTextVariable = 'Subject.Text'

# A file the bridge named itself, and nothing else: the cleanup below deletes
# only names of this exact shape, inside the bulletin's own picture folder.
$script:MojazUploadPattern = '^mojaz-\d{8}-\d{6}-[0-9a-f]{8}\.[A-Za-z0-9]{1,5}$'

# How early the tick takes an interest in the next moment. Longer than the
# poll interval, so a moment is always noticed before it arrives; and it caps
# the blocking wait that lands the send on time.
$script:MojazPreRollSeconds = 1.5

function Get-MojazTemplate {
    <# The registry entry, or $null when this bridge has no Mojaz template -
       which is how the menu knows not to offer the screen at all. #>
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($script:MojazTemplateKey)) { return $null }
    return $store.Map[$script:MojazTemplateKey]
}

function Test-MojazAvailable {
    return $null -ne (Get-MojazTemplate)
}

function Get-MojazStateFile {
    return (Join-Path $logDir 'mojaz.json')
}

function Get-MojazLibraryFile {
    return (Join-Path $logDir 'mojaz-bulletins.json')
}

function Get-MojazSchedulesFile {
    return (Join-Path $logDir 'mojaz-schedules.json')
}

function Save-MojazLibrary {
    <# The caller gives us a candidate. It does not become live until the
       validated atomic write succeeds, so a full disk never creates a state
       that looks saved only until the next restart. #>
    param([Parameter(Mandatory)]$Library)
    if (-not (Write-BridgeValidatedJson -Path (Get-MojazLibraryFile) -Json ($Library | ConvertTo-Json -Depth 20))) {
        Write-BridgeLog 'Could not write the Mojaz bulletin library.' 'WARN'
        return $false
    }
    $script:MojazLibrary = $Library
    return $true
}

function Save-MojazSchedules {
    param([Parameter(Mandatory)]$Schedules)
    $payload = [pscustomobject]@{ SchemaVersion = 1; Schedules = @($Schedules) }
    if (-not (Write-BridgeValidatedJson -Path (Get-MojazSchedulesFile) -Json ($payload | ConvertTo-Json -Depth 12))) {
        Write-BridgeLog 'Could not write the Mojaz schedules.' 'WARN'
        return $false
    }
    $script:MojazSchedules = @($Schedules)
    return $true
}

function ConvertFrom-LegacyMojazPlaylist {
    <# The single table that existed before the library becomes the first
       bulletin in it, timings and inherited pictures intact. #>
    param([Parameter(Mandatory)]$Saved)
    $created = Add-MojazBulletin -Library (New-MojazLibrary) -Name (T 'mjz.current') -UserId 0
    $bulletin = $created.Value.Bulletins[0]
    $delay = 0
    if ([int]::TryParse([string](Get-JsonProp $Saved 'DelaySeconds'), [ref]$delay) -and $delay -ge 1) {
        $bulletin.DelayFrames = [int][math]::Round($delay * (Get-MojazFps))
    }
    $intro = 0
    if ([int]::TryParse([string](Get-JsonProp $Saved 'IntroExtraSeconds'), [ref]$intro) -and $intro -ge 0) {
        $bulletin.IntroExtraFrames = [int][math]::Round($intro * (Get-MojazFps))
    }
    $last = 0
    if ([int]::TryParse([string](Get-JsonProp $Saved 'LastRowSeconds'), [ref]$last) -and $last -ge 0) {
        $bulletin.LastRowFrames = [int][math]::Round($last * (Get-MojazFps))
    }
    $bulletin.Rows = @(foreach ($row in @(Get-JsonProp $Saved 'Rows')) {
            if (-not $row) { continue }
            $image = [string](Get-JsonProp $row 'Image')
            [pscustomobject]@{
                Id = "r_$([guid]::NewGuid().ToString('N').Substring(0,8))"
                ImageMode = $(if ([string]::IsNullOrWhiteSpace($image)) { 'inherit' } else { 'new' })
                Image = $image
                Title = [string](Get-JsonProp $row 'Title')
                Text = [string](Get-JsonProp $row 'Text')
            }
        })
    return $created.Value
}

function Import-MojazLibrary {
    <# Read, or migrate once. The legacy file is archived only after the new
       library is safely on disk, so a failed migration can be retried at the
       next start instead of losing the table. #>
    $script:MojazLibrary = New-MojazLibrary
    $libraryPath = Get-MojazLibraryFile
    if (Test-Path -LiteralPath $libraryPath) {
        try {
            $stored = Read-BridgeValidatedJson -Path $libraryPath
            if ($stored -and $stored.Data) { $script:MojazLibrary = $stored.Data }
        }
        catch { Write-BridgeLog "Could not read the Mojaz bulletin library: $($_.Exception.Message)" 'WARN' }
        return
    }
    $legacyPath = Get-MojazStateFile
    if (-not (Test-Path -LiteralPath $legacyPath)) { return }
    try {
        $legacy = Get-Content -LiteralPath $legacyPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $candidate = ConvertFrom-LegacyMojazPlaylist -Saved $legacy
        if (-not (Save-MojazLibrary -Library $candidate)) { return }
        $archiveName = "mojaz.migrated-$([datetime]::Now.ToString('yyyyMMdd-HHmmss')).json"
        Move-Item -LiteralPath $legacyPath -Destination (Join-Path (Split-Path $legacyPath -Parent) $archiveName) -ErrorAction Stop
        Write-BridgeLog "Migrated the legacy Mojaz playlist to '$archiveName'."
    }
    catch {
        $script:MojazLibrary = New-MojazLibrary
        Write-BridgeLog "Could not migrate mojaz.json: $($_.Exception.Message)" 'WARN'
    }
}

function Import-MojazSchedules {
    $script:MojazSchedules = @()
    $path = Get-MojazSchedulesFile
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $stored = Read-BridgeValidatedJson -Path $path
        if ($stored -and $stored.Data) { $script:MojazSchedules = @(Get-JsonProp $stored.Data 'Schedules') }
    }
    catch { Write-BridgeLog "Could not read Mojaz schedules: $($_.Exception.Message)" 'WARN' }
    # A run that was on air when the bridge stopped is not on air now. Left as
    # 'running' it would block every later appointment forever.
    $stranded = @($script:MojazSchedules | Where-Object { [string](Get-JsonProp $_ 'Status') -eq 'running' })
    if ($stranded.Count -eq 0) { return }
    $candidate = @($script:MojazSchedules | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
    foreach ($entry in @($candidate | Where-Object { [string]$_.Status -eq 'running' })) {
        $entry.Status = 'failed'
        $entry.LastError = 'bridge_restarted'
    }
    Save-MojazSchedules -Schedules $candidate | Out-Null
}

function Get-MojazUploadDirectory {
    <# Beside the scene, not in the bridge's own upload folder: Cinegy reads
       the picture off disk for as long as the graphic is up, and the upload
       sweeper would delete one that is still on air. #>
    $template = Get-MojazTemplate
    if (-not $template) { return '' }
    $root = Split-Path -Path ([string]$template.Path) -Parent
    if (-not $root) { return '' }
    return (Join-Path $root 'Mojaz\bot')
}

# ------------------------------------------------------------------ selection

function Get-MojazSelectedId {
    <# Which bulletin this chat has open. One selection per chat, so two
       operators in two chats edit two bulletins without colliding. #>
    param([Parameter(Mandatory)][long]$ChatId)
    $key = [string]$ChatId
    if ($script:MojazSelections.ContainsKey($key)) { return [string]$script:MojazSelections[$key] }
    return ''
}

function Get-MojazSelected {
    param([Parameter(Mandatory)][long]$ChatId)
    return (Get-MojazBulletin -Library $script:MojazLibrary -BulletinId (Get-MojazSelectedId -ChatId $ChatId))
}

function Invoke-MojazEdit {
    <#
        The one place where an edit becomes a saved fact.

        The module refuses bad edits and the disk refuses full ones; both end
        the same way for the operator - a message saying what happened, and a
        library that has not moved. Nothing else in this file writes the
        library, so there is no path where a screen says "saved" while the file
        disagrees.
    #>
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][long]$ChatId, [switch]$Quiet)
    if (-not $Result.Success) {
        if (-not $Quiet) { Send-TelegramMessage -ChatId $ChatId -Text "❌ $([string]$Result.Error)" }
        return $false
    }
    if (-not (Save-MojazLibrary -Library $Result.Value)) {
        if (-not $Quiet) { Send-TelegramMessage -ChatId $ChatId -Text (T 'mjz.saveFailed') }
        return $false
    }
    return $true
}

# -------------------------------------------------------------------- timing

function Get-MojazTemplateImage {
    <#
        The picture the scene ships with, read from its own declaration:

            <Var Name="mojaz_img" Type="File" Value=".\Mojaz\Pic01.png" />

        Without it there is no way back: an operator who gives one row a
        picture of its own could never return a later row to the template's,
        short of typing the path from memory.

        Cached on write time like the timing, and read separately from it so a
        scene with unusable loop markers still yields its picture.
    #>
    param([string]$Path = '')
    if (-not $Path) {
        $template = Get-MojazTemplate
        if (-not $template) { return '' }
        $Path = [string]$template.Path
    }
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stamp = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTimeUtc
    $key = "$Path|$stamp"
    if ($script:MojazSceneImageKey -eq $key) { return $script:MojazSceneImage }
    $image = ''
    try {
        $document = [xml](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        $variable = @($document.SelectNodes('//Var') | Where-Object { [string]$_.Name -eq $script:MojazImageVariable }) | Select-Object -First 1
        if ($variable) { $image = [string]$variable.Value }
    }
    catch { Write-BridgeLog "Could not read the Mojaz template picture: $($_.Exception.Message)" 'WARN' }
    $script:MojazSceneImageKey = $key
    $script:MojazSceneImage = $image
    return $image
}

function Get-MojazImageSize {
    <#
        How big the picture has to be, asked of the scene rather than guessed.

        The plate that displays it declares its own size:

            <Plate Name="img 01" Size="525.38;291.61" File="${mojaz_img}" />

        A photo from a phone is 4000 pixels wide and the wrong shape; handing
        that to the plate is how a picture ends up not appearing at all.

        The settings win where they are set, because the plate's size is in
        scene units and the picture Titler actually exports is not always the
        same count of pixels - 525x292 on the plate, 538x303 out of the
        exporter. A measured number beats a derived one. Leave them at 0 and
        the plate is read instead, so re-sizing it in Titler still carries.
    #>
    param([string]$Path = '')
    $setWidth = Get-SettingInt 'MojazImageWidth' 0
    $setHeight = Get-SettingInt 'MojazImageHeight' 0
    if ($setWidth -ge 1 -and $setHeight -ge 1) {
        return [pscustomobject]@{ Width = $setWidth; Height = $setHeight }
    }
    if (-not $Path) {
        $template = Get-MojazTemplate
        if (-not $template) { return $null }
        $Path = [string]$template.Path
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stamp = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTimeUtc
    $key = "$Path|$stamp"
    if ($script:MojazImageSizeKey -eq $key) { return $script:MojazImageSize }
    $size = $null
    try {
        $document = [xml](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        $token = '${' + $script:MojazImageVariable + '}'
        # Matched in XPath, not by reading .File off every node: a <Plate>
        # carrying no File attribute threw under Set-StrictMode -Version Latest,
        # so one unrelated plate in the template cost the whole measurement and
        # the bulletin picture silently fell back to a default size.
        $plate = @($document.SelectNodes("//Plate[@File=`"$token`"]")) | Select-Object -First 1
        if ($plate) {
            $parts = ([string]$plate.Size) -split ';'
            if ($parts.Count -ge 2) {
                $width = [int][math]::Round([double]$parts[0])
                $height = [int][math]::Round([double]$parts[1])
                if ($width -ge 1 -and $height -ge 1) {
                    $size = [pscustomobject]@{ Width = $width; Height = $height }
                }
            }
        }
    }
    catch { Write-BridgeLog "Could not read the Mojaz picture size: $($_.Exception.Message)" 'WARN' }
    $script:MojazImageSizeKey = $key
    $script:MojazImageSize = $size
    return $size
}

function Convert-MojazPicture {
    <#
        Check the upload is really a picture, then make it the plate's size.

        Filled and centre-cropped rather than squashed: a phone photo is 16:9
        or 3:4 and the plate is neither, and a stretched face is worse than a
        trimmed one. Saved as PNG, which is what the scene's own picture is.

        Returns $true only when a picture was written.
    #>
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$DestinationPath, $Size)
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    # Throws for anything that is not a picture, which is the check.
    $image = [System.Drawing.Image]::FromFile($SourcePath)
    try {
        $width = if ($Size) { [int]$Size.Width } else { [int]$image.Width }
        $height = if ($Size) { [int]$Size.Height } else { [int]$image.Height }
        $canvas = New-Object System.Drawing.Bitmap($width, $height)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($canvas)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $scale = [math]::Max($width / [double]$image.Width, $height / [double]$image.Height)
                $drawWidth = [double]$image.Width * $scale
                $drawHeight = [double]$image.Height * $scale
                $graphics.DrawImage($image,
                    [single](($width - $drawWidth) / 2), [single](($height - $drawHeight) / 2),
                    [single]$drawWidth, [single]$drawHeight)
            }
            finally { $graphics.Dispose() }
            $canvas.Save($DestinationPath, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $canvas.Dispose() }
    }
    finally { $image.Dispose() }
    return (Test-Path -LiteralPath $DestinationPath)
}

function Get-MojazRowVariables {
    <#
        One row as the scene's variables.

        The image variable is sent only when the row names a picture - its own
        ('new') or the template's ('template'). A row that inherits omits it
        entirely rather than sending an empty path, so the graphic keeps
        whatever picture is already in it: that omission is what lets one
        picture stand for a run of rows.
    #>
    param([Parameter(Mandatory)]$Row, [string]$TemplateImage = '')
    $values = @{
        $script:MojazTitleVariable = [string]$Row.Title
        $script:MojazTextVariable = [string]$Row.Text
    }
    $image = switch (Get-MojazRowImageMode -Row $Row) {
        'new' { [string](Get-JsonProp $Row 'Image') }
        'template' { $TemplateImage }
        default { '' }
    }
    if (-not [string]::IsNullOrWhiteSpace($image)) { $values[$script:MojazImageVariable] = $image }
    return $values
}

function Get-MojazImageMark {
    <# What the table's picture column says about one row. #>
    param($Row, [int]$Index = 0)
    switch (Get-MojazRowImageMode -Row $Row) {
        'new' { return '🖼' }
        'template' { return '▫️' }
        # The first row has nothing above it to inherit from, so inheriting
        # there is the template's own picture, and saying '↑' would be a lie.
        default { return $(if ($Index -eq 0) { '▫️' } else { '↑' }) }
    }
}

function Get-MojazImageLabel {
    param($Row, [int]$Index = 0)
    switch (Get-MojazRowImageMode -Row $Row) {
        'new' { return (T 'mjz.ownPicture') }
        'template' { return (T 'mjz.templatePicture') }
        default { return $(if ($Index -eq 0) { (T 'mjz.templatePicture') } else { (T 'mjz.followsPrevious') }) }
    }
}

function Format-MojazCell {
    param([string]$Text, [int]$Limit = 40)
    $value = ([string]$Text -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return '—' }
    if ($value.Length -gt $Limit) { return $value.Substring(0, $Limit - 1) + '…' }
    return $value
}
