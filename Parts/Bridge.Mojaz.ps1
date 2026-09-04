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
    $created = Add-MojazBulletin -Library (New-MojazLibrary) -Name 'الموجز الحالي' -UserId 0
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
        if (-not $Quiet) { Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر الحفظ. لم يتغيّر شيء؛ تحقّق من مساحة القرص والسجل.' }
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
        $plate = @($document.SelectNodes('//Plate') | Where-Object { [string]$_.File -eq $token }) | Select-Object -First 1
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
        'new' { return '🖼 صورة خاصة' }
        'template' { return '▫️ صورة القالب' }
        default { return $(if ($Index -eq 0) { '▫️ صورة القالب' } else { '↑ يتبع الصف السابق' }) }
    }
}

function Format-MojazCell {
    param([string]$Text, [int]$Limit = 40)
    $value = ([string]$Text -replace '[\r\n]+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return '—' }
    if ($value.Length -gt $Limit) { return $value.Substring(0, $Limit - 1) + '…' }
    return $value
}

function Get-MojazDesignFields {
    <#
        The fields a design asks for, read from its own scene file.

        Cached on path plus write time exactly as the scene's clock is: this
        opens a file, and the bulletin screens ask for it on every draw.
        Re-saving the scene in Titler invalidates the entry by itself.

        Returns an empty list rather than throwing for a path that cannot be
        read - a design whose file has moved is a design with no fields, which
        the caller reports instead of crashing on.
    #>
    param([string]$TemplateKey = '')
    $template = if ($TemplateKey) { (Get-TemplateStore).Map[$TemplateKey] } else { Get-MojazTemplate }
    if (-not $template) { return @() }
    $path = [string](Get-JsonProp $template 'Path')
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }
    try { $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks } catch { return @() }
    $key = "$path|$stamp"
    if ($null -eq $script:MojazDesignCache) { $script:MojazDesignCache = @{} }
    if ($script:MojazDesignCache.ContainsKey($key)) { return @($script:MojazDesignCache[$key]) }
    try { $fields = @(Get-BridgeSceneFields -Xml (Get-Content -LiteralPath $path -Raw)) }
    catch {
        Write-BridgeLog "Could not read the fields of '$path': $($_.Exception.Message)" 'WARN'
        return @()
    }
    $script:MojazDesignCache[$key] = $fields
    return @($fields)
}

function Test-MojazDesignTemplate {
    <# Is this template offered as a bulletin design at all?

       Declared, not guessed: a scene cannot say "I am a bulletin", and every
       template with a loop and a text field is not one. The built-in key is a
       design by definition, so nothing existing has to be relabelled. #>
    param([Parameter(Mandatory)][string]$Key, $Template = $null)
    if ($Key -eq $script:MojazTemplateKey) { return $true }
    if (-not $Template) { $Template = (Get-TemplateStore).Map[$Key] }
    if (-not $Template) { return $false }
    return [bool](Get-JsonProp $Template 'Bulletin')
}

function Get-MojazDesigns {
    <#
        The designs a bulletin may be bound to, each with what its scene
        declares and whether it can walk rows.

        A design whose scene cannot be read, or has nothing to fill, is
        returned marked unusable rather than silently dropped: an operator who
        marked a template as a bulletin design and cannot find it in the list
        deserves to be told why.
    #>
    $store = Get-TemplateStore
    $designs = foreach ($key in @($store.Order)) {
        $template = $store.Map[$key]
        if (-not (Test-MojazDesignTemplate -Key $key -Template $template)) { continue }
        $path = [string](Get-JsonProp $template 'Path')
        $verdict = if ($path -and (Test-Path -LiteralPath $path)) {
            try { Test-BridgeSceneUsable -Xml (Get-Content -LiteralPath $path -Raw) }
            catch { [pscustomobject]@{ Usable = $false; Reason = 'تعذّرت قراءة ملف المشهد.'; Fields = @(); SupportsRows = $false } }
        }
        else { [pscustomobject]@{ Usable = $false; Reason = 'ملف المشهد غير موجود في مساره.'; Fields = @(); SupportsRows = $false } }
        [pscustomobject]@{
            Key = [string]$key
            Layer = [int](Get-JsonProp $template 'Layer')
            Description = [string](Get-JsonProp $template 'Description')
            Usable = [bool]$verdict.Usable
            Reason = [string]$verdict.Reason
            SupportsRows = [bool]$verdict.SupportsRows
            Fields = @($verdict.Fields)
        }
    }
    return @($designs)
}

function Get-MojazUsableDesigns {
    return @(Get-MojazDesigns | Where-Object { $_.Usable })
}

function Test-MojazDesignChoiceNeeded {
    <# Ask only when there is something to ask. One design is not a choice,
       and the option being off means the built-in one is the only design
       there is. #>
    if (-not (Get-Setting 'MojazMultiDesign')) { return $false }
    return (@(Get-MojazUsableDesigns).Count -gt 1)
}

function Format-MojazDesignSummary {
    <# What a design is, in the one line a button has room for: what it asks
       to be given, and whether it walks a list or carries one story. #>
    param([Parameter(Mandatory)]$Design)
    $media = @($Design.Fields | Where-Object { $_.Kind -eq 'media' }).Count
    $text = @($Design.Fields | Where-Object { $_.Kind -eq 'text' }).Count
    $parts = @()
    if ($media -gt 0) { $parts += "$media وسائط" }
    if ($text -gt 0) { $parts += "$text نص" }
    if ($parts.Count -eq 0) { $parts += 'بلا حقول' }
    $parts += $(if ($Design.SupportsRows) { 'عدة أخبار' } else { 'خبر واحد' })
    return ($parts -join ' · ')
}

function Get-MojazDesignKeyboard {
    <# The designs, and the reason beside any that cannot be used - a design
       an operator declared and cannot select is a question, and the screen
       answers it rather than leaving a gap. #>
    param([int]$Page = 0, [ValidateRange(1, 20)][int]$PageSize = 8)
    $designs = @(Get-MojazDesigns)
    $window = Get-BridgePageWindow -ItemCount $designs.Count -Page $Page -PageSize $PageSize
    $rows = @()
    if ($window.EndIndex -ge $window.StartIndex) {
        foreach ($index in $window.StartIndex..$window.EndIndex) {
            $design = $designs[$index]
            if ($design.Usable) {
                $rows += , @( (New-Button "🎬 $($design.Key) · $(Format-MojazDesignSummary -Design $design)" "mojazdesign:$($design.Key)") )
            }
            else {
                $rows += , @( (New-Button "⛔ $($design.Key) — $($design.Reason)" 'menu:mojaz') )
            }
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button '⬅️ السابق' "mojazdesignpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "mojazdesignpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button 'التالي ➡️' "mojazdesignpage:$($window.Page + 1)") }
        $rows += , $pager
    }
    $rows += , @( (New-Button '❌ إلغاء' 'menu:mojaz') )
    return @{ inline_keyboard = $rows }
}

function Show-MojazDesignScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -ParseMode HTML -ReplyMarkup (Get-MojazDesignKeyboard -Page $Page) -Text @"
🎬 <b>تصميم الموجز</b>

اختر التصميم الذي تُبثّ عليه هذه النشرة.
<i>الحقول تُقرأ من المشهد نفسه، فما يطلبه التصميم هو ما ستُسأل عنه.</i>
"@
}

function Set-MojazBulletinDesign {
    <# Binds a bulletin to a design, refusing while it is on air: changing the
       scene under a running bulletin would leave the rows being written into
       variables the new design has never heard of. #>
    param([Parameter(Mandatory)][string]$BulletinId, [Parameter(Mandatory)][string]$TemplateKey,
        [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($script:MojazPlayback -and [string]$script:MojazPlayback.BulletinId -eq $BulletinId) {
        Send-TelegramMessage -ChatId $ChatId -Text '⛔ لا يُبدَّل تصميم موجز وهو على الهواء. أوقفه أولًا.' | Out-Null
        return $false
    }
    $design = @(Get-MojazUsableDesigns | Where-Object { $_.Key -eq $TemplateKey } | Select-Object -First 1)
    if ($design.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text '⛔ هذا التصميم غير صالح أو لم يعد موجودًا.' | Out-Null
        return $false
    }
    $result = Update-MojazBulletinIn -Library $script:MojazLibrary -BulletinId $BulletinId -UserId $UserId -Change {
        param($bulletin)
        $bulletin | Add-Member -NotePropertyName TemplateKey -NotePropertyValue $TemplateKey -Force
    }
    Invoke-MojazEdit -Result $result -ChatId $ChatId | Out-Null
    return [bool]$result.Success
}

function Get-MojazBulletinDesignKey {
    <# Which design plays this bulletin: its own, or the built-in one. Every
       bulletin written before designs existed says nothing, and nothing means
       the one they were all written for. #>
    param($Bulletin)
    $key = [string](Get-JsonProp $Bulletin 'TemplateKey')
    if ($key) { return $key }
    return [string]$script:MojazTemplateKey
}

function Get-MojazSceneTiming {
    <#
        The scene's own clock, read from the .cintitle rather than guessed.

        A Cinegy scene says where its loop starts and ends, and those two
        markers are exactly the three durations this screen needs:

            0            -> LoopStartFrame   the entrance animation
            LoopStart    -> LoopEnd          the part that repeats
            LoopEnd      -> Duration         the exit animation

        So the extra the first row needs is not a number somebody guessed in
        the settings - it is LoopStartFrame / Fps - and the hold before EXIT
        is the outro's own length. Re-timing the scene in Titler re-times the
        bulletin, with nothing to update here.

        Cached on path plus write time, the way the template store is: this is
        read every time the screen is drawn.
    #>
    param([string]$Path = '')
    if (-not $Path) {
        $template = Get-MojazTemplate
        if (-not $template) { return $null }
        $Path = [string]$template.Path
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stamp = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTimeUtc
    $key = "$Path|$stamp"
    if ($script:MojazSceneTimingKey -eq $key) { return $script:MojazSceneTiming }
    $timing = $null
    try {
        $scene = ([xml](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)).CinegyTitler.Scene
        $fps = [double]$scene.Fps
        $loopStart = [double]$scene.LoopStartFrame
        $loopEnd = [double]$scene.LoopEndFrame
        $duration = [double]$scene.Duration
        # A scene with no loop, or a nonsense one, is not a timing source.
        if ($fps -gt 0 -and $loopEnd -gt $loopStart -and $duration -ge $loopEnd) {
            # Frames are what the scene is cut in and what the operator sets;
            # the seconds beside them are for reading, and for the clock.
            $timing = [pscustomobject]@{
                Fps = $fps
                IntroFrames = [int]$loopStart
                LoopFrames = [int]($loopEnd - $loopStart)
                OutroFrames = [int]($duration - $loopEnd)
                IntroSeconds = [math]::Round($loopStart / $fps, 3)
                LoopSeconds = [math]::Round(($loopEnd - $loopStart) / $fps, 3)
                OutroSeconds = [math]::Round(($duration - $loopEnd) / $fps, 3)
            }
        }
    }
    catch { Write-BridgeLog "Could not read the Mojaz scene timing: $($_.Exception.Message)" 'WARN' }
    $script:MojazSceneTimingKey = $key
    $script:MojazSceneTiming = $timing
    return $timing
}

function Get-MojazFps {
    <#
        The frame rate every frame count here is measured against.

        The scene's own rate first - it is the thing being timed, and it
        cannot be wrong about itself. The channel's configured rate only when
        the scene cannot be read, which is the case the setting exists for.
    #>
    $timing = Get-MojazSceneTiming
    if ($timing -and [double](Get-JsonProp $timing 'Fps') -gt 0) { return [double]$timing.Fps }
    $configured = 0.0
    if ([double]::TryParse([string](Get-Setting 'BroadcastFps'), [ref]$configured) -and $configured -gt 0) { return $configured }
    return 25.0
}

function Get-MojazDelayFrames {
    <# How long each row holds, in frames. The bulletin's own number, then the
       newsroom's default. Seconds are derived, so one unit describes the
       whole bulletin instead of seconds here and frames beside it. #>
    param($Bulletin)
    if ($Bulletin) {
        $own = [int](Get-JsonProp $Bulletin 'DelayFrames')
        if ($own -gt 0) { return $own }
        # Written before frames existed: its seconds still mean something.
        $legacy = [double](Get-JsonProp $Bulletin 'DelaySeconds')
        if ($legacy -gt 0) { return [int][math]::Round($legacy * (Get-MojazFps)) }
    }
    $default = Get-SettingInt 'MojazRowFrames' 0
    if ($default -gt 0) { return $default }
    return [int][math]::Round(8 * (Get-MojazFps))
}

function Get-MojazDelaySeconds {
    param($Bulletin)
    return [math]::Round((Get-MojazDelayFrames -Bulletin $Bulletin) / (Get-MojazFps), 3)
}

function Get-MojazIntroFrames {
    <#
        What the first row gets on top of its dwell, in frames - the unit the
        entrance animation is actually cut in.

        The bulletin's own number first, then the newsroom's default, then the
        scene's own entrance. Seconds are derived from this, never the other
        way round: a fifth of a second is five frames, and rounding it to a
        whole second used to replace the first story while the graphic was
        still sliding in.
    #>
    param($Bulletin)
    if ($Bulletin) {
        $own = [int](Get-JsonProp $Bulletin 'IntroExtraFrames')
        if ($own -gt 0) { return $own }
        # Written before frames existed: its seconds still mean something.
        $legacy = [double](Get-JsonProp $Bulletin 'IntroExtraSeconds')
        if ($legacy -gt 0) { return [int][math]::Round($legacy * (Get-MojazFps)) }
    }
    $default = Get-SettingInt 'MojazIntroExtraFrames' 0
    if ($default -gt 0) { return $default }
    return (Get-MojazSceneFrames -Which intro)
}

function Get-MojazSceneFrames {
    <# The scene's own entrance or exit in frames. Derived from its seconds
       when the frames are not there, so a caller holding an older timing -
       or a test standing in for one - still gets an answer. #>
    param([Parameter(Mandatory)][ValidateSet('intro', 'outro')][string]$Which)
    $timing = Get-MojazSceneTiming
    if (-not $timing) { return 0 }
    $name = if ($Which -eq 'intro') { 'IntroFrames' } else { 'OutroFrames' }
    $frames = [int](Get-JsonProp $timing $name)
    if ($frames -gt 0) { return $frames }
    $seconds = [double](Get-JsonProp $timing $(if ($Which -eq 'intro') { 'IntroSeconds' } else { 'OutroSeconds' }))
    if ($seconds -le 0) { return 0 }
    return [int][math]::Round($seconds * (Get-MojazFps))
}

function Get-MojazIntroSeconds {
    param($Bulletin)
    return [math]::Round((Get-MojazIntroFrames -Bulletin $Bulletin) / (Get-MojazFps), 3)
}

function Get-MojazLastRowFrames {
    <# How long the last row holds before EXIT, in frames: the outro's own
       length, so the last story stays readable for exactly as long as the
       graphic takes to leave. Half the dwell only when the scene cannot
       say. #>
    param($Bulletin)
    if ($Bulletin) {
        $own = [int](Get-JsonProp $Bulletin 'LastRowFrames')
        if ($own -gt 0) { return $own }
        $legacy = [double](Get-JsonProp $Bulletin 'LastRowSeconds')
        if ($legacy -gt 0) { return [int][math]::Round($legacy * (Get-MojazFps)) }
    }
    $default = Get-SettingInt 'MojazLastRowFrames' 0
    if ($default -gt 0) { return $default }
    $sceneFrames = Get-MojazSceneFrames -Which outro
    if ($sceneFrames -gt 0) { return $sceneFrames }
    # Half the dwell, in frames, when the scene has no exit to copy.
    return [int][math]::Max((Get-MojazFps), [math]::Floor((Get-MojazDelayFrames -Bulletin $Bulletin) / 2))
}

function Get-MojazLastRowSeconds {
    param($Bulletin)
    return [math]::Round((Get-MojazLastRowFrames -Bulletin $Bulletin) / (Get-MojazFps), 3)
}

function Test-MojazSyncToLoop {
    param($Bulletin)
    if (-not $Bulletin) { return $false }
    return [bool](Get-JsonProp $Bulletin 'SyncToLoop')
}

function Get-MojazSyncText {
    <#
        What the sync is doing, or why it cannot.

        The scene hides its own content at every loop wrap and fades it back
        in, so a row written just after the wrap is never seen changing. That
        only works when one loop is one story, which is a cut in Titler and
        not something this screen can do - so when the loop is long it says so
        plainly rather than quietly running rows at a minute each.
    #>
    param($Bulletin)
    $timing = Get-MojazSceneTiming
    if (-not (Test-MojazSyncToLoop -Bulletin $Bulletin)) {
        return '🎬 المزامنة متوقّفة: يتغيّر الصف في منتصف الثبات، بلا حركة تُخفيه.'
    }
    if (-not $timing -or [double]$timing.LoopSeconds -le 0) {
        return '⚠️ المزامنة مطلوبة لكن القالب لا يعطي لوبًا صالحًا، فيعمل الموجز بالمدّة المكتوبة.'
    }
    $loop = [double]$timing.LoopSeconds
    $line = "🎬 مزامنة مع حركة الظهور: كل صف يبقى لوبًا كاملًا ($loop ث) ويتبدّل داخل ظهورٍ مدّته $($timing.IntroSeconds) ث."
    if ($loop -ge 30) {
        $line += "`n⚠️ اللوب طويل، فالصف يبقى $loop ث. لتسريعه قصِّر LoopEndFrame في Titler."
    }
    return $line
}

function Get-MojazPlanText {
    <# How long the bulletin runs, in the same words the screen used to ask
       for the dwell. #>
    param($Bulletin)
    if (-not $Bulletin) { return '' }
    $rows = @(Get-JsonProp $Bulletin 'Rows')
    if ($rows.Count -eq 0) { return '' }
    $timing = Get-MojazSceneTiming
    if ((Test-MojazSyncToLoop -Bulletin $Bulletin) -and $timing -and [double]$timing.LoopSeconds -gt 0) {
        # The loop owns the pace here, so quoting the dwell would be a lie.
        $plan = New-MojazLoopPlan -SceneTiming $timing -RowCount $rows.Count -OffsetSeconds ((Get-SettingInt 'MojazSyncOffsetMs' 400) / 1000.0)
        $total = [int][math]::Ceiling([double]$plan.ExitOffset + [double]$timing.OutroSeconds)
        return "كل صف لوب واحد ($($timing.LoopSeconds) ث) · الإجمالي ≈ $(Format-DurationSeconds -Seconds $total)`n$(Get-MojazSyncText -Bulletin $Bulletin)"
    }
    $delay = Get-MojazDelaySeconds -Bulletin $Bulletin
    $intro = Get-MojazIntroSeconds -Bulletin $Bulletin
    $last = Get-MojazLastRowSeconds -Bulletin $Bulletin
    $total = ($delay * [math]::Max(0, $rows.Count - 1)) + $intro + $last
    $line = "كل صف $(Get-MojazDelayFrames -Bulletin $Bulletin) إطار ($delay ث) · الأول +$(Get-MojazIntroFrames -Bulletin $Bulletin) إطار لحركة الدخول · الأخير $(Get-MojazLastRowFrames -Bulletin $Bulletin) إطار ثم خروج · الإجمالي ≈ $(Format-DurationSeconds -Seconds ([int][math]::Ceiling($total)))"
    $timing = Get-MojazSceneTiming
    if ($timing) {
        $line += "`nمن القالب: دخول $(Get-MojazSceneFrames -Which intro) إطار · لوب $([int](Get-JsonProp $timing 'LoopFrames')) إطار · خروج $(Get-MojazSceneFrames -Which outro) إطار (‏$(Get-MojazFps) إطارًا/ث)"
    }
    if (Test-MojazSyncToLoop -Bulletin $Bulletin) {
        $loopSeconds = if ($timing) { [double](Get-JsonProp $timing 'LoopSeconds') } else { 0 }
        $line += "`n🎬 المزامنة مفعّلة: كل خبر يُكتب داخل فيضة اللوب فلا يُرى وهو يتبدّل"
        if ($loopSeconds -gt 0) {
            $line += "، والإيقاع يصير طول اللوب ($(Format-DurationSeconds -Seconds ([int][math]::Round($loopSeconds)))) لا المدة أعلاه"
        }
        $line += '.'
    }
    return $line
}

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
    $name = if ($Bulletin) { [string]$Bulletin.Name } else { 'الموجز' }
    $rows = @(if ($Bulletin) { @(Get-JsonProp $Bulletin 'Rows') })
    $blocks = @(@{ type = 'heading'; text = "📑 $name"; size = 3 })
    if ($rows.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'الجدول فارغ. أضف صفًّا: صورة، عنوان، خبر.' }
        return $blocks
    }
    $blocks += @{ type = 'paragraph'; text = "$($rows.Count) صفًّا · $(Get-MojazPlanText -Bulletin $Bulletin)" }
    $cells = @(, @(
            @{ text = '#'; is_header = $true }
            @{ text = '🖼'; is_header = $true }
            @{ text = 'العنوان'; is_header = $true }
            @{ text = 'الخبر'; is_header = $true }
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
    $blocks += @{ type = 'paragraph'; text = '🖼 صورة خاصة · ↑ يتبع الصف السابق · ▫️ صورة القالب' }
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
    $name = if ($Bulletin) { [string]$Bulletin.Name } else { 'الموجز' }
    $rows = @(if ($Bulletin) { @(Get-JsonProp $Bulletin 'Rows') })
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>📑 $(ConvertTo-TelegramHtmlText -Text $name)</b>")
    if ($rows.Count -eq 0) {
        $lines.Add('<i>الجدول فارغ. أضف صفًّا: صورة، عنوان، خبر.</i>')
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

function Get-MojazKeyboard {
    param($Bulletin)
    $rows = @(if ($Bulletin) { @(Get-JsonProp $Bulletin 'Rows') })
    $keyboard = @()
    if (Test-MojazOnAir -Bulletin $Bulletin) {
        $keyboard += , @((New-Button '⏹ إيقاف وخروج' 'mojaz:stop' -Style danger))
    }
    elseif ($rows.Count -gt 0) {
        $keyboard += , @(
            (New-Button "▶️ تشغيل ($($rows.Count) صفًّا)" 'mojaz:play' -Style success)
            (New-Button '🕒 تشغيل لاحقًا' 'mojaz:later')
        )
    }
    $keyboard += , @(
        (New-Button '➕ إضافة صف' 'mojaz:add')
        (New-Button "⏱ المدة: $(Get-MojazDelayFrames -Bulletin $Bulletin) إطار" 'mojaz:delay')
    )
    $keyboard += , @(
        (New-Button "⏩ الأول: +$(Get-MojazIntroFrames -Bulletin $Bulletin) إطار" 'mojaz:intro')
        (New-Button "⏹ الأخير: $(Get-MojazLastRowFrames -Bulletin $Bulletin) إطار" 'mojaz:last')
    )
    $keyboard += , @(
        (New-Button "🎬 مزامنة الظهور: $(if (Test-MojazSyncToLoop -Bulletin $Bulletin) { 'نعم · الإيقاع من اللوب' } else { 'لا · الإيقاع من المدة' })" 'mojaz:sync')
    )
    # A line per row: delete it, or move it up or down the rundown. Numbered
    # like the table above, so the button and the story line up by eye.
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $rowId = [string]$rows[$i].Id
        $line = @(
            (New-Button "✏️ $($i + 1)" "mojaz:row:$rowId")
            (New-Button '🗑' "mojaz:del:$rowId" -Style danger)
        )
        if ($i -gt 0) { $line += (New-Button '⬆️' "mojaz:up:$rowId") }
        if ($i -lt ($rows.Count - 1)) { $line += (New-Button '⬇️' "mojaz:down:$rowId") }
        $keyboard += , $line
    }
    if ($rows.Count -gt 0) { $keyboard += , @((New-Button '🧹 مسح الجدول' 'mojaz:clear' -Style danger)) }
    $keyboard += , @(
        (New-Button '✏️ إعادة تسمية' 'mojaz:rename')
        (New-Button '📋 نسخة منه' 'mojaz:copy')
        (New-Button '🗑 حذف الموجز' 'mojaz:drop' -Style danger)
    )
    if ($rows.Count -gt 0) {
        # The table is an index, four columns that fit a phone; this is where
        # the copy can actually be read back before it goes out.
        $keyboard += , @((New-Button '👁 معاينة النص كاملًا' 'mojaz:preview'))
    }
    $keyboard += , @(
        (New-Button '🕒 المواعيد' 'mojaz:times')
        (New-Button '🔄 تحديث' 'mojaz:refresh')
        (New-Button '⬅️ الموجزات' 'mojaz:back')
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
        $lines.Add('<i>الجدول فارغ.</i>')
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
        -ReplyMarkup @{ inline_keyboard = @(, @((New-Button '⬅️ الجدول' 'mojaz:refresh'))) }
}

function Show-MojazScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-MojazAvailable)) {
        Send-TelegramMessage -ChatId $ChatId -Text "قالب '$($script:MojazTemplateKey)' غير موجود في سجل القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    # The bulletin this chat had open can be gone - deleted from another chat.
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    $keyboard = Get-MojazKeyboard -Bulletin $bulletin
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-MojazBlocks -Bulletin $bulletin) -ReplyMarkup $keyboard) { return }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazText -Bulletin $bulletin) -ParseMode HTML -ReplyMarkup $keyboard
}

# ---------------------------------------------------------------- the library

function Get-MojazLibraryText {
    $bulletins = @(Get-JsonProp $script:MojazLibrary 'Bulletins')
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<b>📑 الموجزات المحفوظة</b>')
    if ($bulletins.Count -eq 0) {
        $lines.Add('<i>لا توجد موجزات محفوظة. أنشئ موجزًا ثم أضف صفوفه.</i>')
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
        if (Test-MojazOnAir -Bulletin $bulletin) { $detail += ' · ▶️ على الهواء' }
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
        if ($window.HasPrevious) { $pager += (New-Button '⬅️ السابق' "mojazpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "mojazpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button 'التالي ➡️' "mojazpage:$($window.Page + 1)") }
        $keyboard += , $pager
    }
    $keyboard += , @((New-Button '➕ موجز جديد' 'mojaz:new' -Style success))
    $keyboard += , @((New-Button '🕒 المواعيد' 'mojaz:times'), (New-Button '🔄 تحديث' 'menu:mojaz'), (New-Button '🏠 القائمة' 'menu:main'))
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
        'new' { '📝 أرسل اسم الموجز الجديد، مثل: الموجز الصباحي.' }
        'rename' { '✏️ أرسل الاسم الجديد لهذا الموجز.' }
        'copy' { '📋 أرسل اسم النسخة الجديدة.' }
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
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر الحفظ. لم يتغيّر شيء؛ تحقّق من مساحة القرص والسجل.' -ReplyMarkup (Get-CancelKeyboard)
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
        $verb = if ($Which -eq 'new') { 'إنشاء' } else { 'نسخ' }
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
                (New-Button '↩️ تراجع' 'mojaz:refresh')
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
        Send-TelegramMessage -ChatId $ChatId -Text '❌ هذا الموجز على الهواء الآن. أوقفه أولًا.'
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
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر إلغاء مواعيد هذا الموجز، فلم يُحذف شيء.'
        return $false
    }
    if (-not (Save-MojazLibrary -Library $removal.Value)) {
        if ($cancelled -gt 0) { Save-MojazSchedules -Schedules $previousSchedules | Out-Null }
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر حذف الموجز. لم يتغيّر شيء؛ تحقّق من مساحة القرص والسجل.'
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
            (New-Button '↑ يتبع السابق' 'mojaz:img:inherit')
            (New-Button '▫️ صورة القالب' 'mojaz:img:template')
        ))
    $used = @(Get-MojazUsedImages -Rows @(Get-JsonProp (Get-MojazSelected -ChatId $script:MojazImageChatId) 'Rows'))
    $line = @()
    for ($i = 0; $i -lt $used.Count -and $i -lt 8; $i++) {
        $line += (New-Button "🖼 $(Split-Path -Path $used[$i] -Leaf)" "mojaz:img:use:$i")
        if ($line.Count -eq 2) { $keyboard += , $line; $line = @() }
    }
    if ($line.Count -gt 0) { $keyboard += , $line }
    $keyboard += , @((New-Button '❌ إلغاء' $Cancel))
    return @{ inline_keyboard = $keyboard }
}

function Send-MojazImagePrompt {
    <# One prompt for both flows; the pending mode already says which. #>
    param([Parameter(Mandatory)][long]$ChatId, [string]$Cancel = 'mojaz:refresh')
    $script:MojazImageChatId = $ChatId
    Send-TelegramMessage -ChatId $ChatId -Text "🖼 أرسل صورة الصف (كصورة أو كملف)، أو أرسل مسارًا مثل ‎.\Mojaz\Pic01.png‎`nأو اختر أحد الأزرار." `
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
            Send-TelegramMessage -ChatId $ChatId -Text '📝 أرسل عنوان الصف (مثل: قطاع غزة).' -ReplyMarkup (Get-CancelKeyboard)
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
                (New-Button '🖼 الصورة' "mojaz:editimg:$RowId")
                (New-Button '📝 العنوان' "mojaz:edittitle:$RowId")
                (New-Button '📰 النص' "mojaz:edittext:$RowId")
            )
            , @(
                (New-Button '🗑 حذف الصف' "mojaz:del:$RowId" -Style danger)
                (New-Button '⬅️ الجدول' 'mojaz:refresh')
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
    $prompt = if ($Which -eq 'title') { '📝 أرسل العنوان الجديد.' } else { '📰 أرسل نص الخبر الجديد.' }
    Send-TelegramMessage -ChatId $ChatId -Text "$prompt`nالحالي: $current" `
        -ReplyMarkup @{ inline_keyboard = @(, @((New-Button '❌ إلغاء' "mojaz:row:$RowId"))) }
}

function Complete-MojazRowEdit {
    param([Parameter(Mandatory)][ValidateSet('title', 'text')][string]$Which,
        [Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne "mojaz_edit_$Which") { return }
    $value = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        Send-TelegramMessage -ChatId $ChatId -Text $(if ($Which -eq 'title') { '❌ العنوان فارغ. أرسل عنوانًا.' } else { '❌ نص الخبر فارغ. أرسل النص.' }) -ReplyMarkup (Get-CancelKeyboard)
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
        Send-TelegramMessage -ChatId $ChatId -Text '❌ العنوان فارغ. أرسل عنوانًا.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'mojaz_row_text'; UserId = $state.UserId
        BulletinId = [string](Get-JsonProp $state 'BulletinId')
        Image = [string]$state.Image; ImageMode = [string](Get-JsonProp $state 'ImageMode'); Title = $title
    }
    Send-TelegramMessage -ChatId $ChatId -Text '📰 أرسل نص الخبر.' -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-MojazRowText {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'mojaz_row_text') { return }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ نص الخبر فارغ. أرسل النص.' -ReplyMarkup (Get-CancelKeyboard)
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
    Show-MojazScreen -ChatId $ChatId -UserId $userId
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
        Send-TelegramMessage -ChatId $ChatId -Text '❌ لا يمكن تحديد مجلد الصور: القالب غير موجود.' -ReplyMarkup (Get-CancelKeyboard)
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
        Write-BridgeLog "Mojaz photo download failed: $($_.Exception.Message)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ الصورة: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-CancelKeyboard)
        return $false
    }
    # Only a real picture, and only at the plate's size, reaches the folder
    # Cinegy reads: a file that is not a picture, or is thousands of pixels
    # wide, is a row that shows nothing on air.
    $size = Get-MojazImageSize
    try {
        Convert-MojazPicture -SourcePath $staging -DestinationPath $destination -Size $size | Out-Null
        $measured = if ($size) { "$($size.Width)x$($size.Height)" } else { 'كما هي' }
        Write-BridgeLog "Mojaz picture stored as '$name' ($measured)."
    }
    catch {
        Write-BridgeLog "Mojaz picture rejected: $($_.Exception.Message)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text '❌ هذا الملف ليس صورة يمكن قراءتها. أرسل صورة (JPG أو PNG).' -ReplyMarkup (Get-CancelKeyboard)
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
    $result = Remove-MojazBulletinRow -Library $script:MojazLibrary -BulletinId (Get-MojazSelectedId -ChatId $ChatId) -RowId $RowId -UserId $UserId
    Invoke-MojazEdit -Result $result -ChatId $ChatId | Out-Null
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
}

function Move-MojazRow {
    param([Parameter(Mandatory)][string]$RowId, [Parameter(Mandatory)][ValidateSet('up', 'down')][string]$Direction,
        [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    $result = Move-MojazBulletinRow -Library $script:MojazLibrary -BulletinId (Get-MojazSelectedId -ChatId $ChatId) -RowId $RowId -Direction $Direction -UserId $UserId
    # Hitting the edge of the table is not worth a message: the screen simply
    # redraws unchanged.
    Invoke-MojazEdit -Result $result -ChatId $ChatId -Quiet | Out-Null
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
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
        -Text "⏱ كم إطارًا يبقى كل صف على الهواء؟`nالحالي: $(Get-MojazDelayFrames -Bulletin $bulletin) إطار ≈ $(Get-MojazDelaySeconds -Bulletin $bulletin) ث · المشهد $(Get-MojazFps) إطارًا في الثانية." `
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
        Send-TelegramMessage -ChatId $ChatId -Text $(if ($Which -eq 'delay') { '❌ أرسل عدد إطارات بين 1 و15000.' } else { '❌ أرسل عدد إطارات بين 0 و15000.' }) -ReplyMarkup (Get-CancelKeyboard)
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
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر الحفظ. لم يتغيّر شيء؛ تحقّق من مساحة القرص والسجل.' -ReplyMarkup (Get-CancelKeyboard)
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
        Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazSyncText -Bulletin (Get-MojazSelected -ChatId $ChatId))
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
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر إلغاء الموعد. لم يتغيّر شيء.'
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
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر حفظ الموعد. لم يتغيّر شيء.' -ReplyMarkup (Get-CancelKeyboard)
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
    $lines.Add('<b>🕒 مواعيد الموجزات</b>')
    if ($pending.Count -eq 0) {
        $lines.Add('<i>لا مواعيد. افتح موجزًا واضغط «تشغيل لاحقًا».</i>')
        return ($lines -join "`n")
    }
    $lines.Add('<i>الموعد يستخدم آخر تحديث محفوظ للموجز، لا نسخته وقت الحجز</i>')
    $lines.Add('')
    for ($index = 0; $index -lt $pending.Count; $index++) {
        $entry = $pending[$index]
        $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId ([string](Get-JsonProp $entry 'BulletinId'))
        $name = if ($bulletin) { [string]$bulletin.Name } else { 'موجز محذوف' }
        $moment = [datetimeoffset](Get-JsonProp $entry 'ScheduledAt')
        $mark = switch ([string](Get-JsonProp $entry 'Status')) {
            'running' { '▶️ على الهواء' }
            'queued' { '⏳ في الانتظار — موجز آخر كان يعمل' }
            default { '🕒 مجدول' }
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
            $name = if ($bulletin) { [string]$bulletin.Name } else { 'موجز محذوف' }
            $moment = [datetimeoffset](Get-JsonProp $entry 'ScheduledAt')
            $keyboard += , @((New-Button "🚫 $($moment.ToString('HH:mm')) · $name" "mojaz:unschedule:$([string](Get-JsonProp $entry 'Id'))" -Style danger))
        }
    }
    if ($window.PageCount -gt 1) {
        $pager = @()
        if ($window.HasPrevious) { $pager += (New-Button '⬅️ السابق' "mojazschedpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "mojazschedpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button 'التالي ➡️' "mojazschedpage:$($window.Page + 1)") }
        $keyboard += , $pager
    }
    $keyboard += , @((New-Button '⬅️ الموجزات' 'menu:mojaz'), (New-Button '🏠 القائمة' 'menu:main'))
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
        $name = if ($bulletin) { [string]$bulletin.Name } else { 'موجز مجدول' }
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
            $waitingName = if ($bulletin) { [string]$bulletin.Name } else { 'الموجز المجدول' }
            $because = if ($script:MojazPlayback) {
                $activeName = if ([string]$script:MojazPlayback.BulletinName) { [string]$script:MojazPlayback.BulletinName } else { 'الموجز الحالي' }
                "«$activeName» ما زال على الهواء"
            }
            else { 'العاجل على الهواء' }
            if (Set-MojazScheduleStatus -ScheduleId ([string]$entry.Id) -Status 'queued' -Fields @{ DueAt = $Now.ToString('o'); DelayReason = $reason }) {
                Send-TelegramMessage -ChatId ([long]$entry.ChatId) -Text "⏳ تأخّر «$waitingName» لأن $because. سيبدأ بعد انتهائه."
            }
        }
        return
    }
    $next = $due[0]
    $scheduleId = [string]$next.Id
    if (-not (Set-MojazScheduleStatus -ScheduleId $scheduleId -Status 'running' -Fields @{ StartedAt = $Now.ToString('o') })) { return }
    $script:MojazSelections[[string]$next.ChatId] = [string]$next.BulletinId
    # -Force: the urgent check above has already been made, and nobody is
    # watching a scheduled start to answer a question.
    if (-not (Start-MojazPlayback -ChatId ([long]$next.ChatId) -UserId ([long]$next.CreatedBy) -ScheduleId $scheduleId -Force)) {
        Set-MojazScheduleStatus -ScheduleId $scheduleId -Status 'failed' -Fields @{ LastError = 'playback_start_failed' } | Out-Null
    }
}

# ------------------------------------------------------------------ playback

function Start-MojazPlayback {
    <#
        Shows the first row, then leaves the rest to the tick.

        The run works from a snapshot taken here and never reads the saved
        bulletin again, so editing or even deleting the table mid-bulletin
        changes what plays next time, not what is on air now.

        The show goes through the ordinary pipeline so this screen cannot skip
        maintenance mode, the layer policy, the live Cinegy check or the audit
        trail - a bulletin is still a graphic going on air.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$ScheduleId = '', [switch]$Force)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($script:MojazPlayback) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الموجز يعمل بالفعل.'
        return $false
    }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الموجز غير موجود.'
        return $false
    }
    # The urgent outranks the bulletin, so starting one underneath it is a
    # decision the operator makes rather than one this screen makes for them.
    # A scheduled start never reaches here while the urgent is up: the queue
    # holds it, and passes -Force once the air is clear.
    if (-not $Force -and (Test-MojazUrgentOnAir)) {
        Send-TelegramMessage -ChatId $ChatId `
            -Text "🚨 العاجل على الهواء الآن.`nمتى يبدأ «$([string]$bulletin.Name)»؟" `
            -ReplyMarkup (Get-MojazUrgentWaitKeyboard)
        return $false
    }
    $schedule = if ($ScheduleId) { [pscustomobject]@{ Id = $ScheduleId } } else { $null }
    $syncOffset = (Get-SettingInt 'MojazSyncOffsetMs' 400) / 1000.0
    # Resolve the two timings here rather than leaving the module to guess:
    # these are the same numbers the screen printed, so what plays is what the
    # plan line promised. The saved bulletin is not touched - the copy carries
    # them into the snapshot, which owns the timing for this run alone.
    $resolved = $bulletin | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    # Added rather than assigned: a bulletin stores frames now, so these
    # seconds exist only on this copy, for the module to plan with.
    foreach ($pair in @(
            @('DelaySeconds', (Get-MojazDelaySeconds -Bulletin $bulletin)),
            @('IntroExtraSeconds', (Get-MojazIntroSeconds -Bulletin $bulletin)),
            @('LastRowSeconds', (Get-MojazLastRowSeconds -Bulletin $bulletin)))) {
        if ($resolved.PSObject.Properties.Match($pair[0]).Count -eq 0) {
            $resolved | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]
        }
        else { $resolved.$($pair[0]) = $pair[1] }
    }
    $snapshotResult = New-MojazRunSnapshot -Bulletin $resolved -SceneTiming (Get-MojazSceneTiming) -Schedule $schedule -OffsetSeconds $syncOffset
    if (-not $snapshotResult.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الجدول فارغ.' -ReplyMarkup (Get-MojazKeyboard -Bulletin $bulletin)
        return $false
    }
    $snapshot = $snapshotResult.Value
    $rows = @($snapshot.Rows)
    # The template's picture is part of the snapshot too: a row set to
    # "template" must show the picture the scene had when the run started,
    # not one edited into it half way through.
    $templateImage = Get-MojazTemplateImage
    $result = Invoke-ShowTemplateResult -Key $script:MojazTemplateKey -Variables (Get-MojazRowVariables -Row $rows[0] -TemplateImage $templateImage) -ChatId $ChatId -UserId $UserId
    if (-not $result -or -not $result.Success) {
        $reason = if ($result) { [string](Get-JsonProp $result 'Error') } else { 'تعذّر العرض' }
        Send-TelegramMessage -ChatId $ChatId -Text "❌ لم يبدأ الموجز: $reason" -ReplyMarkup (Get-MojazKeyboard -Bulletin $bulletin)
        return $false
    }
    $script:MojazPlayback = @{
        Index = 0; ChatId = $ChatId; UserId = $UserId
        # Monotonic, and started the moment the scene is actually up: every
        # row's moment is measured from here, so a slow send delays that row
        # and no other. ClockOffset exists so a test can move time.
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
        ClockOffset = 0.0
        Rows = $rows
        Plan = @($snapshot.Plan)
        ExitAtSeconds = [double]$snapshot.ExitAtSeconds
        SyncToLoop = [bool]$snapshot.SyncToLoop
        BulletinId = [string]$snapshot.BulletinId
        BulletinName = [string]$snapshot.BulletinName
        # Wall clock, not the stopwatch: after a restart the stopwatch is gone
        # and this is the only thing that says how far in the run had got.
        StartedAt = (Get-Date).ToString('o')
        BulletinRevision = [int]$snapshot.BulletinRevision
        ScheduleId = $ScheduleId
        TemplateImage = $templateImage
    }
    # Now that the bulletin is really on air, the strip stands down: they
    # share the bottom of the screen, and it returns when this ends.
    Hide-MojazTicker -ChatId $ChatId -UserId $UserId | Out-Null
    # The permanent trail. A bulletin reached air as a plain air_control SHOW
    # of the Mojaz scene, which says a graphic went up and nothing about which
    # bulletin it was, how many stories it carried, or whether a person or a
    # schedule started it - so a report had nothing to report.
    $script:MojazPlayback.OperationId = "mojaz-$([guid]::NewGuid().ToString('N'))"
    Write-AuditRecord -OperationId ([string]$script:MojazPlayback.OperationId) -EventName mojaz_run -Result started `
        -UserId $UserId -UserName (Get-UserDisplayName -UserId $UserId) -ChatId $ChatId -Action START `
        -Layer ([int](Get-MojazTemplate).Layer) -Target ([string]$snapshot.BulletinName) -Count ($rows.Count) `
        -Values $(if ([string]$snapshot.ScheduleId) { 'scheduled' } else { 'manual' })
    Save-MojazPlaybackState | Out-Null
    Write-BridgeLog "Mojaz playback started by $UserId ($($rows.Count) rows, $(Get-MojazDelayFrames -Bulletin $bulletin) frames each)"
    Add-AuditEntry "📑 تشغيل «$([string]$snapshot.BulletinName)» ($($rows.Count) صفًّا) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Write-MojazRunEnd {
    <#
        Closes the run that Start-MojazPlayback opened, so a report can say how
        long a bulletin actually held the screen and not merely that it began.

        Called from BOTH endings - the bulletin's own stop, and the layer being
        taken by something else - because a run closed in only one of them
        would sit in the report reading "still on air" for ever.
    #>
    param([Parameter(Mandatory)]$Playback, [long]$UserId = 0, [long]$ChatId = 0)
    $user = if ($UserId -gt 0) { $UserId } else { [long](Get-JsonProp $Playback 'UserId') }
    $chat = if ($ChatId -gt 0) { $ChatId } else { [long](Get-JsonProp $Playback 'ChatId') }
    # The playback's own monotonic clock, which is the number the newsroom asks
    # about: the two audit stamps would also count a slow write between them.
    $clock = Get-JsonProp $Playback 'Clock'
    $ranMs = if ($clock) { [long]([double]$clock.Elapsed.TotalMilliseconds + [double](Get-JsonProp $Playback 'ClockOffset') * 1000) } else { 0 }
    Write-AuditRecord -OperationId ([string](Get-JsonProp $Playback 'OperationId')) -EventName mojaz_run -Result completed `
        -UserId $user -UserName (Get-UserDisplayName -UserId $user) -ChatId $chat -Action END `
        -Target ([string](Get-JsonProp $Playback 'BulletinName')) -Count (@(Get-JsonProp $Playback 'Rows').Count) `
        -DurationMs $ranMs -Values $(if ([string](Get-JsonProp $Playback 'ScheduleId')) { 'scheduled' } else { 'manual' })
}

function Stop-MojazPlayback {
    <# Ends the bulletin the way it ends itself: EXIT, so the scene plays its
       outro instead of being cut. #>
    param([long]$ChatId = 0, [long]$UserId = 0, [switch]$Quiet)
    if (-not $script:MojazPlayback) { return $false }
    $playback = $script:MojazPlayback
    $script:MojazPlayback = $null
    Clear-MojazPlaybackState
    $template = Get-MojazTemplate
    if ($template) {
        $chat = if ($ChatId -gt 0) { $ChatId } else { [long]$playback.ChatId }
        $user = if ($UserId -gt 0) { $UserId } else { [long]$playback.UserId }
        Invoke-ExitLayer -Layer ([int]$template.Layer) -ChatId $chat -UserId $user | Out-Null
    }
    Write-MojazRunEnd -Playback $playback -UserId $UserId -ChatId $ChatId
    if ([string]$playback.ScheduleId) {
        Set-MojazScheduleStatus -ScheduleId ([string]$playback.ScheduleId) -Status 'completed' -Fields @{ CompletedAt = [datetimeoffset]::Now.ToString('o') } | Out-Null
    }
    # The bulletin is off, so the strip may come back - after the outro.
    Request-MojazTickerReturn | Out-Null
    if (-not $Quiet -and $ChatId -gt 0) { Show-MojazScreen -ChatId $ChatId -UserId $UserId }
    # An urgent that agreed to wait for this bulletin goes out now.
    Update-MojazPendingUrgent | Out-Null
    return $true
}

function Get-MojazElapsedSeconds {
    <# How long this run has been going, by a clock that cannot step. #>
    if (-not $script:MojazPlayback) { return 0.0 }
    return ([double]$script:MojazPlayback.Clock.Elapsed.TotalSeconds + [double]$script:MojazPlayback.ClockOffset)
}

function Get-MojazUrgentTemplate {
    <# The template that outranks the bulletin. Named here for the same reason
       the bulletin's own key is: this is that newsroom's arrangement, and a
       rename in the registry is a change here. #>
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($script:MojazUrgentKey)) { return $null }
    return $store.Map[$script:MojazUrgentKey]
}

function Test-MojazUrgentOnAir {
    $template = Get-MojazUrgentTemplate
    if (-not $template) { return $false }
    return $script:OnAir.ContainsKey([int]$template.Layer)
}

function Get-MojazTickerTemplate {
    <# The news strip, which shares the bulletin's segment. #>
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($script:MojazTickerKey)) { return $null }
    return $store.Map[$script:MojazTickerKey]
}

function Hide-MojazTicker {
    <#
        The bulletin and the strip share the bottom of the screen, so the strip
        stands down while a bulletin is on air and comes back after it.

        Taken off by EXIT rather than a cut, so it leaves the way it was drawn
        to leave. Only a strip that was actually up is remembered for return:
        putting one on air that nobody had asked for would be this screen
        deciding what the channel looks like.
    #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    $script:MojazTickerReturn = $null
    if (-not (Get-Setting 'MojazHidesTicker')) { return $false }
    $template = Get-MojazTickerTemplate
    if (-not $template) { return $false }
    $layer = [int]$template.Layer
    if (-not $script:OnAir.ContainsKey($layer)) { return $false }
    $chat = if ($ChatId -gt 0) { $ChatId } else { [long](Get-JsonProp $script:OnAir[$layer] 'ChatId') }
    if ($chat -le 0) { return $false }
    Write-BridgeLog "Mojaz starting: standing the news strip down from layer $layer."
    if (-not (Invoke-ExitLayer -Layer $layer -ChatId $chat -UserId $UserId)) { return $false }
    $script:MojazTickerReturn = @{ At = $null; ChatId = $chat; UserId = $UserId }
    return $true
}

function Request-MojazTickerReturn {
    <#
        The bulletin is over; the strip goes back, but not this instant.

        The scene is still playing its outro, and putting the strip back
        underneath it would have both on screen for those few seconds - the
        overlap the stand-down existed to avoid. So the moment is booked and
        the tick carries it out, which also keeps this off the stack of
        whatever ended the bulletin.
    #>
    if (-not $script:MojazTickerReturn) { return $false }
    $timing = Get-MojazSceneTiming
    $after = if ($timing -and [double]$timing.OutroSeconds -gt 0) { [double]$timing.OutroSeconds } else { 1.0 }
    $script:MojazTickerReturn.At = (Get-Date).AddSeconds($after)
    return $true
}

function Update-MojazTickerReturn {
    <# Puts the strip back when its moment arrives. Called from the tick. #>
    if (-not $script:MojazTickerReturn -or -not $script:MojazTickerReturn.At) { return }
    if ((Get-Date) -lt [datetime]$script:MojazTickerReturn.At) { return }
    $pending = $script:MojazTickerReturn
    $script:MojazTickerReturn = $null
    $template = Get-MojazTickerTemplate
    if (-not $template) { return }
    Write-BridgeLog 'Mojaz finished: putting the news strip back.'
    Invoke-ShowTemplateResult -Key $script:MojazTickerKey -Variables @{} `
        -ChatId ([long]$pending.ChatId) -UserId ([long]$pending.UserId) | Out-Null
}

function Clear-MojazForUrgent {
    <#
        The urgent wins, always.

        Anything that puts the urgent on air takes the bulletin off first -
        including a scheduled or automated one, which is why this lives in the
        show pipeline and not behind a button. The operator is told, not
        asked: the moment an urgent goes out is the wrong moment for a
        question. The asking happens earlier, before the send.
    #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if (-not $script:MojazPlayback) { return $false }
    $name = [string]$script:MojazPlayback.BulletinName
    Stop-MojazPlayback -UserId $UserId -Quiet | Out-Null
    Write-BridgeLog 'Mojaz pulled: the urgent template takes the air.'
    Add-AuditEntry "🚨 سُحب الموجز «$name» لصالح العاجل - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    if ($ChatId -gt 0) { Send-TelegramMessage -ChatId $ChatId -Text "🚨 خرج «$name» ليفسح المجال للعاجل." }
    return $true
}

function Set-MojazPendingUrgent {
    <# An urgent held back until the bulletin finishes. Held in memory only:
       it is a wait of a minute or two, and a bridge that restarts in the
       middle of one has no bulletin left to wait for. #>
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Variables = @{},
        [int]$AutoHideSeconds = 0, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    $script:MojazPendingUrgent = @{
        Key = $Key; Variables = $Variables; AutoHideSeconds = $AutoHideSeconds
        ChatId = $ChatId; UserId = $UserId
    }
}

function Update-MojazPendingUrgent {
    <# Called where a run ends, however it ends. #>
    if (-not $script:MojazPendingUrgent) { return $false }
    $pending = $script:MojazPendingUrgent
    $script:MojazPendingUrgent = $null
    Send-TelegramMessage -ChatId ([long]$pending.ChatId) -Text '▶️ انتهى الموجز — يُرسل العاجل الآن.'
    Invoke-ShowTemplateResult -Key ([string]$pending.Key) -Variables ([hashtable]$pending.Variables) `
        -ChatId ([long]$pending.ChatId) -UserId ([long]$pending.UserId) -AutoHideSeconds ([int]$pending.AutoHideSeconds) | Out-Null
    return $true
}

function Get-MojazUrgentConflictKeyboard {
    <# Asked before the urgent goes out, while a bulletin is running. "Now" is
       first because that is what an urgent usually means. #>
    return @{ inline_keyboard = @(
            , @( (New-Button '🚨 الآن — يخرج الموجز' 'urgent:now' -Style danger) )
            , @( (New-Button '⏳ بعد انتهاء الموجز' 'urgent:after') )
            , @( (New-Button '❌ إلغاء' 'cancel') )
        ) }
}

function Get-MojazUrgentWaitKeyboard {
    <# Asked before the bulletin starts, while the urgent is on air. Waiting
       is first here: the bulletin is the thing that yields. #>
    return @{ inline_keyboard = @(
            , @( (New-Button '⏳ بعد خروج العاجل' 'mojaz:playafter' -Style success) )
            , @( (New-Button '▶️ ابدأ الآن رغم العاجل' 'mojaz:playnow') )
            , @( (New-Button '❌ إلغاء' 'mojaz:refresh') )
        ) }
}

function Start-MojazAfterUrgent {
    <#
        "Start once the urgent is gone", booked as an ordinary appointment due
        now. The queue already knows how to hold a due bulletin while the air
        is busy and start it the moment it clears, so this needs no waiting
        machinery of its own - and it survives a restart, and can be cancelled
        from the appointments screen like any other.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return $false }
    if (-not (Add-MojazSchedule -BulletinId ([string]$bulletin.Id) -ScheduledAt ([datetimeoffset]::Now) -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر حجز الموعد. لم يتغيّر شيء.'
        return $false
    }
    Add-AuditEntry "⏳ تأجيل «$([string]$bulletin.Name)» إلى ما بعد العاجل - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "⏳ سيبدأ «$([string]$bulletin.Name)» فور خروج العاجل."
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Send-MojazPendingUrgentNow {
    <# The urgent goes out at once; the pipeline pulls the bulletin off as it
       passes through. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:MojazPendingUrgent) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد عاجل بانتظار الإرسال.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    $pending = $script:MojazPendingUrgent
    $script:MojazPendingUrgent = $null
    Invoke-ShowTemplateResult -Key ([string]$pending.Key) -Variables ([hashtable]$pending.Variables) `
        -ChatId $ChatId -UserId $UserId -AutoHideSeconds ([int]$pending.AutoHideSeconds) | Out-Null
    return $true
}

function Confirm-MojazPendingUrgent {
    <# It waits. The bulletin's own ending sends it. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:MojazPendingUrgent) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد عاجل بانتظار الإرسال.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    Add-AuditEntry "⏳ تأجيل العاجل إلى ما بعد الموجز - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text '⏳ ينتظر العاجل انتهاء الموجز، ثم يخرج وحده.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $true
}

function Test-MojazOnAirLayer {
    <# Is the bulletin's layer occupied - by a run, or by a scene the bridge
       itself put there and has not taken down? #>
    $template = Get-MojazTemplate
    if (-not $template) { return $false }
    if ($script:MojazPlayback) { return $true }
    return $script:OnAir.ContainsKey([int]$template.Layer)
}

function Stop-MojazForLayer {
    <#
        The bulletin's layer is being taken off air by something that is not
        this screen - the hide button on the main menu, an exit, hide-all.

        The run has to end with it. Left alone it would keep writing rows into
        a scene nobody can see and then send an EXIT of its own, long after the
        operator believed it was gone. The caller is already removing the
        layer, so this does not exit again - it only closes the run.
    #>
    param([Parameter(Mandatory)][int]$Layer)
    if (-not $script:MojazPlayback) { return $false }
    $template = Get-MojazTemplate
    if (-not $template -or [int]$template.Layer -ne $Layer) { return $false }
    $playback = $script:MojazPlayback
    $script:MojazPlayback = $null
    Clear-MojazPlaybackState
    Write-MojazRunEnd -Playback $playback
    if ([string]$playback.ScheduleId) {
        Set-MojazScheduleStatus -ScheduleId ([string]$playback.ScheduleId) -Status 'completed' -Fields @{ CompletedAt = [datetimeoffset]::Now.ToString('o') } | Out-Null
    }
    Write-BridgeLog "Mojaz playback ended: layer $Layer was taken off air."
    Request-MojazTickerReturn | Out-Null
    return $true
}

function Hide-MojazOnAir {
    <# The main menu's way out of a bulletin: stop the run if there is one, and
       leave by EXIT so the scene plays its outro instead of being cut. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $template = Get-MojazTemplate
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد قالب للموجز.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    if ($script:MojazPlayback) {
        # Stop-MojazPlayback exits the layer itself.
        Stop-MojazPlayback -UserId $UserId -Quiet | Out-Null
    }
    elseif ($script:OnAir.ContainsKey([int]$template.Layer)) {
        Invoke-ExitLayer -Layer ([int]$template.Layer) -ChatId $ChatId -UserId $UserId | Out-Null
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text 'الموجز ليس على الهواء.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return $false
    }
    Add-AuditEntry "⏹ إخفاء الموجز - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text '⏹ خرج الموجز.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $true
}

function Get-MojazPlaybackFile {
    return (Join-Path $logDir 'mojaz-playback.json')
}

function Save-MojazPlaybackState {
    <#
        The run, on disk, so a restart does not abandon a bulletin on air.

        Everything else the bridge holds survives a restart - what is on air,
        the auto-hide timers, the reminders, the schedule - and the bulletin
        playback was the one exception. When the bridge went down mid-run the
        scene stayed exactly where it was, looping, with nobody left to write
        the next row into it or to send the EXIT that ends it; an operator had
        to take it off by hand.

        Written once at the start, not on every row: the plan holds absolute
        moments measured from StartedAt, so where a run has got to is a
        subtraction, not a thing to keep writing down.
    #>
    if (-not $script:MojazPlayback) { return $false }
    try {
        $playback = $script:MojazPlayback
        $state = [ordered]@{
            StartedAt = [string]$playback.StartedAt
            BulletinId = [string]$playback.BulletinId
            BulletinName = [string]$playback.BulletinName
            ScheduleId = [string](Get-JsonProp $playback 'ScheduleId')
            OperationId = [string](Get-JsonProp $playback 'OperationId')
            ChatId = [long]$playback.ChatId
            UserId = [long]$playback.UserId
            ExitAtSeconds = [double]$playback.ExitAtSeconds
            SyncToLoop = [bool]$playback.SyncToLoop
            Rows = @($playback.Rows)
            Plan = @($playback.Plan)
        }
        $path = Get-MojazPlaybackFile
        $temporary = "$path.tmp"
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write mojaz-playback.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Clear-MojazPlaybackState {
    Remove-Item -LiteralPath (Get-MojazPlaybackFile) -Force -ErrorAction SilentlyContinue
}

function Restore-MojazPlayback {
    <#
        Picks a bulletin back up where the clock says it should be.

        The plan's moments are absolute from the start of the run, which is
        what makes this possible at all: elapsed time alone says which row is
        due, so the run rejoins its own schedule instead of restarting.

        Three endings. The layer is no longer the bulletin's - somebody dealt
        with it already - so the file is dropped. The run is past its exit -
        the scene is looping with nobody to end it - so it is ended. Otherwise
        it resumes, and the administrators are told either way, because a
        bulletin that carried on across a restart is not something to discover
        from the screen.
    #>
    param([datetime]$Now = (Get-Date))
    $path = Get-MojazPlaybackFile
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch {
        Write-BridgeLog "Could not read mojaz-playback.json: $($_.Exception.Message)" 'WARN'
        Clear-MojazPlaybackState
        return $false
    }
    Clear-MojazPlaybackState
    $startedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string](Get-JsonProp $state 'StartedAt'), [ref]$startedAt)) { return $false }
    $template = Get-MojazTemplate
    if (-not $template) { return $false }
    $layer = [int]$template.Layer
    # Only if the bulletin's scene is still the thing on that layer. Anything
    # else means it has already been dealt with, and this must not touch a
    # layer that now belongs to something else.
    if (-not $script:OnAir.ContainsKey($layer) -or
        [string](Get-JsonProp $script:OnAir[$layer] 'Key') -ne [string]$script:MojazTemplateKey) {
        return $false
    }
    $elapsed = ($Now - $startedAt).TotalSeconds
    $exitAt = [double](Get-JsonProp $state 'ExitAtSeconds')
    $name = [string](Get-JsonProp $state 'BulletinName')
    $chat = [long](Get-JsonProp $state 'ChatId')
    $user = [long](Get-JsonProp $state 'UserId')
    if ($elapsed -ge $exitAt) {
        Write-BridgeLog "A bulletin ('$name') was still on air after a restart and past its end; taking it off." 'WARN'
        Invoke-ExitLayer -Layer $layer -ChatId $chat -UserId $user | Out-Null
        Request-MojazTickerReturn | Out-Null
        Send-AdminBroadcast -Text "⏹ كان الموجز «$name» على الهواء لحظة إعادة التشغيل وقد تجاوز وقت خروجه، فأُخرج الآن." | Out-Null
        return $true
    }
    $rows = @(Get-JsonProp $state 'Plan')
    $index = @($rows | Where-Object { [double](Get-JsonProp $_ 'AtSeconds') -le $elapsed }).Count - 1
    if ($index -lt 0) { $index = 0 }
    $script:MojazPlayback = @{
        Index = $index; ChatId = $chat; UserId = $user
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
        # The run rejoins its own timeline: the clock starts at zero now, and
        # the offset carries everything that happened before the restart.
        ClockOffset = $elapsed
        Rows = @(Get-JsonProp $state 'Rows')
        Plan = @(Get-JsonProp $state 'Plan')
        ExitAtSeconds = $exitAt
        SyncToLoop = [bool](Get-JsonProp $state 'SyncToLoop')
        BulletinId = [string](Get-JsonProp $state 'BulletinId')
        BulletinName = $name
        ScheduleId = [string](Get-JsonProp $state 'ScheduleId')
        OperationId = [string](Get-JsonProp $state 'OperationId')
        StartedAt = [string](Get-JsonProp $state 'StartedAt')
    }
    Save-MojazPlaybackState | Out-Null
    Write-BridgeLog "Resumed the bulletin '$name' after a restart at row $($index + 1) of $(@($script:MojazPlayback.Rows).Count), $([int]$elapsed)s in."
    Send-AdminBroadcast -Text "▶️ استُؤنف الموجز «$name» بعد إعادة التشغيل عند الصف $($index + 1)." | Out-Null
    return $true
}

function Update-MojazPlayback {
    <#
        One step of the bulletin, called from the tick.

        Rows after the first are pushed through the postbox, which is what
        changes a running scene's values without restarting it.

        Each moment is absolute, measured from the start of the run, so a slow
        send delays its own row and none of the ones behind it. The tick is
        about a second apart - too coarse for a fade that lasts just over a
        second - so once a moment is close this waits out the remainder itself
        and sends on time. That blocks the bot for at most PreRoll, once per
        row, which is the price of landing inside the window.
    #>
    if (-not $script:MojazPlayback) { return }
    $rows = @($script:MojazPlayback.Rows)
    $index = [int]$script:MojazPlayback.Index
    $isLast = ($index -ge ($rows.Count - 1))
    $moment = if ($isLast) { [double]$script:MojazPlayback.ExitAtSeconds } else { [double]$script:MojazPlayback.Plan[$index + 1].AtSeconds }
    # Sent early by the measured round trip, so it arrives at the moment
    # rather than after it. Calibrate against air, not against theory.
    $target = $moment - ((Get-SettingInt 'MojazSyncLeadMs' 120) / 1000.0)
    if ((Get-MojazElapsedSeconds) -lt ($target - $script:MojazPreRollSeconds)) { return }
    $remaining = $target - (Get-MojazElapsedSeconds)
    if ($remaining -gt 0) {
        Start-Sleep -Milliseconds ([int][math]::Min(($script:MojazPreRollSeconds * 1000), ($remaining * 1000)))
    }
    if ($isLast) {
        Write-BridgeLog "Mojaz playback finished after $($rows.Count) row(s)"
        # Every other way a bulletin ends says so already - a button press, an
        # urgent taking over, a failed row. This is the one that finishes on
        # its own minutes after the operator stopped watching.
        if (Get-Setting 'MojazNotifyOnFinish') {
            $finishedName = [string]$script:MojazPlayback.BulletinName
            Send-TelegramMessage -ChatId ([long]$script:MojazPlayback.ChatId) -Text "⏹ انتهى «$finishedName» وخرج عن الهواء."
        }
        Stop-MojazPlayback -Quiet | Out-Null
        return
    }
    $index++
    $values = Get-MojazRowVariables -Row $rows[$index] -TemplateImage ([string](Get-JsonProp $script:MojazPlayback 'TemplateImage'))
    $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Values $values -TimeoutSec (Get-AirTimeout)
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Mojaz POSTBOX XML: $($result.Xml)" }
    if (-not $result.Success) {
        Write-BridgeLog "Mojaz row $($index + 1) failed: $($result.Error)" 'WARN'
        Send-TelegramMessage -ChatId ([long]$script:MojazPlayback.ChatId) -Text "❌ توقّف الموجز عند الصف $($index + 1): $($result.Error)"
        Stop-MojazPlayback -Quiet | Out-Null
        return
    }
    $script:MojazPlayback.Index = $index
}

function Update-MojazImageCleanup {
    <#
        Pictures whose row is gone.

        Deleting a row does not delete its picture, because the same file may
        be on air in the run that is playing, or referenced by another
        bulletin. So the sweep is deliberately narrow: only files this bridge
        named itself, only inside the bulletin's own picture folder, only when
        no saved row and no running snapshot mentions them, and only once they
        are a day old - long enough that a picture uploaded for a row still
        being written is never taken out from under it.
    #>
    param([int]$MinimumAgeHours = 0, [switch]$Force)
    # Once an hour, not once a tick. This walks a directory, and it was doing
    # so on the polling thread every time round the loop - for a job whose
    # whole premise is that nothing has touched those files in a day.
    if (-not $Force -and $script:LastMojazImageSweep -and ((Get-Date) - $script:LastMojazImageSweep).TotalMinutes -lt 60) { return 0 }
    $script:LastMojazImageSweep = Get-Date
    if ($MinimumAgeHours -le 0) { $MinimumAgeHours = Get-SettingInt 'MojazImageKeepHours' 24 }
    # Zero turns the sweep off: a newsroom that wants to keep every picture it
    # ever uploaded is allowed to.
    if ($MinimumAgeHours -le 0) { return 0 }
    $directory = Get-MojazUploadDirectory
    if (-not $directory -or -not (Test-Path -LiteralPath $directory)) { return 0 }
    $referenced = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($bulletin in @(Get-JsonProp $script:MojazLibrary 'Bulletins')) {
        foreach ($row in @(Get-JsonProp $bulletin 'Rows')) {
            $image = [string](Get-JsonProp $row 'Image')
            if ($image) { $referenced.Add((Split-Path -Path $image -Leaf)) | Out-Null }
        }
    }
    if ($script:MojazPlayback) {
        foreach ($row in @($script:MojazPlayback.Rows)) {
            $image = [string](Get-JsonProp $row 'Image')
            if ($image) { $referenced.Add((Split-Path -Path $image -Leaf)) | Out-Null }
        }
    }
    $cutoff = (Get-Date).AddHours(-1 * [math]::Max(1, $MinimumAgeHours))
    $removed = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -notmatch $script:MojazUploadPattern) { continue }
        if ($referenced.Contains($file.Name)) { continue }
        if ($file.LastWriteTime -gt $cutoff) { continue }
        try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $removed++ }
        catch { Write-BridgeLog "Could not remove the orphaned Mojaz picture '$($file.Name)': $($_.Exception.Message)" 'WARN' }
    }
    if ($removed -gt 0) { Write-BridgeLog "Removed $removed orphaned Mojaz picture(s)." }
    return $removed
}
