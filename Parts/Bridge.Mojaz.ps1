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
    if ([int]::TryParse([string](Get-JsonProp $Saved 'DelaySeconds'), [ref]$delay) -and $delay -ge 1) { $bulletin.DelaySeconds = $delay }
    $intro = 0
    if ([int]::TryParse([string](Get-JsonProp $Saved 'IntroExtraSeconds'), [ref]$intro) -and $intro -ge 0) { $bulletin.IntroExtraSeconds = $intro }
    $last = 0
    if ([int]::TryParse([string](Get-JsonProp $Saved 'LastRowSeconds'), [ref]$last) -and $last -ge 0) { $bulletin.LastRowSeconds = $last }
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
            $timing = [pscustomobject]@{
                Fps = $fps
                IntroSeconds = [math]::Round($loopStart / $fps, 2)
                LoopSeconds = [math]::Round(($loopEnd - $loopStart) / $fps, 2)
                OutroSeconds = [math]::Round(($duration - $loopEnd) / $fps, 2)
            }
        }
    }
    catch { Write-BridgeLog "Could not read the Mojaz scene timing: $($_.Exception.Message)" 'WARN' }
    $script:MojazSceneTimingKey = $key
    $script:MojazSceneTiming = $timing
    return $timing
}

function Get-MojazIntroSeconds {
    <# What the first row gets on top of its dwell, because the entrance
       animation is playing over it. The bulletin's own number when it has
       one, else the scene's, else the setting. #>
    param($Bulletin)
    if ($Bulletin -and [int](Get-JsonProp $Bulletin 'IntroExtraSeconds') -gt 0) { return [int]$Bulletin.IntroExtraSeconds }
    $timing = Get-MojazSceneTiming
    # Rounded up: a second short here replaces the first story's text while
    # the graphic is still sliding in.
    if ($timing) { return [int][math]::Ceiling([double]$timing.IntroSeconds) }
    return (Get-SettingInt 'MojazIntroExtraSeconds' 0)
}

function Get-MojazLastRowSeconds {
    <# How long the last row holds before EXIT: the outro's own length, so the
       last story stays readable for exactly as long as the graphic takes to
       leave. Half the dwell only when the scene cannot say. #>
    param($Bulletin)
    if ($Bulletin -and [int](Get-JsonProp $Bulletin 'LastRowSeconds') -gt 0) { return [int]$Bulletin.LastRowSeconds }
    $timing = Get-MojazSceneTiming
    if ($timing -and [double]$timing.OutroSeconds -gt 0) { return [int][math]::Ceiling([double]$timing.OutroSeconds) }
    $delay = if ($Bulletin) { [int](Get-JsonProp $Bulletin 'DelaySeconds') } else { 8 }
    return [math]::Max(1, [int][math]::Floor($delay / 2))
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
    $delay = [int]$Bulletin.DelaySeconds
    $intro = Get-MojazIntroSeconds -Bulletin $Bulletin
    $last = Get-MojazLastRowSeconds -Bulletin $Bulletin
    $total = ($delay * [math]::Max(0, $rows.Count - 1)) + $intro + $last
    $line = "كل صف $delay ث · الأول +$intro ث لحركة الدخول · الأخير $last ث ثم خروج · الإجمالي ≈ $(Format-DurationSeconds -Seconds $total)"
    $timing = Get-MojazSceneTiming
    if ($timing) {
        $line += "`nمن القالب: دخول $($timing.IntroSeconds) ث · لوب $($timing.LoopSeconds) ث · خروج $($timing.OutroSeconds) ث"
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
        (New-Button "⏱ المدة: $(if ($Bulletin) { [int]$Bulletin.DelaySeconds } else { 0 }) ث" 'mojaz:delay')
    )
    $keyboard += , @(
        (New-Button "⏩ الأول: +$(Get-MojazIntroSeconds -Bulletin $Bulletin) ث" 'mojaz:intro')
        (New-Button "⏹ الأخير: $(Get-MojazLastRowSeconds -Bulletin $Bulletin) ث" 'mojaz:last')
    )
    $keyboard += , @(
        (New-Button "🎬 مزامنة الظهور: $(if (Test-MojazSyncToLoop -Bulletin $Bulletin) { 'نعم' } else { 'لا' })" 'mojaz:sync')
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
    $keyboard += , @(
        (New-Button '🕒 المواعيد' 'mojaz:times')
        (New-Button '🔄 تحديث' 'mojaz:refresh')
        (New-Button '⬅️ الموجزات' 'mojaz:back')
    )
    return @{ inline_keyboard = $keyboard }
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
    $keyboard = @()
    foreach ($bulletin in @(Get-JsonProp $script:MojazLibrary 'Bulletins')) {
        $mark = if (Test-MojazOnAir -Bulletin $bulletin) { '▶️' } else { '📄' }
        $keyboard += , @((New-Button "$mark $([string]$bulletin.Name)" "mojaz:open:$([string]$bulletin.Id)"))
    }
    $keyboard += , @((New-Button '➕ موجز جديد' 'mojaz:new' -Style success))
    $keyboard += , @((New-Button '🕒 المواعيد' 'mojaz:times'), (New-Button '🔄 تحديث' 'menu:mojaz'), (New-Button '🏠 القائمة' 'menu:main'))
    return @{ inline_keyboard = $keyboard }
}

function Show-MojazLibraryScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-MojazAvailable)) {
        Send-TelegramMessage -ChatId $ChatId -Text "قالب '$($script:MojazTemplateKey)' غير موجود في سجل القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $script:MojazSelections.Remove([string]$ChatId)
    Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazLibraryText) -ParseMode HTML -ReplyMarkup (Get-MojazLibraryKeyboard)
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
        'new' { Add-MojazBulletin -Library $script:MojazLibrary -Name $Value -DelaySeconds (Get-SettingInt 'MojazRowSeconds' 8) -UserId $userId }
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
    $name = "mojaz-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))$safeExtension"
    $destination = Join-Path $directory $name
    try {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
        Receive-TelegramDocument -FileId $FileId -DestinationPath $destination -MaximumBytes (10 * 1024 * 1024) | Out-Null
    }
    catch {
        Write-BridgeLog "Mojaz photo download failed: $($_.Exception.Message)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ الصورة: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-CancelKeyboard)
        return $false
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
    Send-TelegramMessage -ChatId $ChatId -Text "⏱ كم ثانية يبقى كل صف على الهواء؟ (1-600)`nالحالي: $([int]$bulletin.DelaySeconds) ث" -ReplyMarkup (Get-CancelKeyboard)
}

function Start-MojazTimingPrompt {
    <# One prompt for both numbers; the mode says which. #>
    param([Parameter(Mandatory)][ValidateSet('intro', 'last')][string]$Which, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $bulletin = Get-MojazSelected -ChatId $ChatId
    if (-not $bulletin) { Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId; return }
    $text = if ($Which -eq 'intro') {
        "⏩ كم ثانية تُضاف إلى الصف الأول وحده (حركة الدخول)؟ (0-600)`nالحالي: $(Get-MojazIntroSeconds -Bulletin $bulletin) ث · أرسل 0 لاتّباع القالب."
    }
    else {
        "⏹ كم ثانية يبقى الصف الأخير قبل أمر الخروج؟ (0-600)`nالحالي: $(Get-MojazLastRowSeconds -Bulletin $bulletin) ث · أرسل 0 لاتّباع القالب."
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
        Send-TelegramMessage -ChatId $ChatId -Text $(if ($Which -eq 'delay') { '❌ أرسل رقمًا بين 1 و600.' } else { '❌ أرسل رقمًا بين 0 و600.' }) -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $bulletinId = [string](Get-JsonProp $state 'BulletinId')
    $userId = [long]$state.UserId
    $result = switch ($Which) {
        'delay' { Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId $bulletinId -DelaySeconds $seconds -UserId $userId }
        'intro' { Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId $bulletinId -IntroExtraSeconds $seconds -UserId $userId }
        'last' { Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId $bulletinId -LastRowSeconds $seconds -UserId $userId }
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
    Send-TelegramMessage -ChatId $ChatId -Text "🕒 متى يبدأ «$([string]$bulletin.Name)»؟`nمثل: +30 (بعد 30 دقيقة) · بعد 90 · 21:45 · غدًا 07:00" -ReplyMarkup (Get-CancelKeyboard)
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
    $userId = [long]$state.UserId
    $bulletinId = [string](Get-JsonProp $state 'BulletinId')
    $scheduledAt = [datetimeoffset]$moment.ScheduledAt
    if (-not (Add-MojazSchedule -BulletinId $bulletinId -ScheduledAt $scheduledAt -ChatId $ChatId -UserId $userId)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذّر حفظ الموعد. لم يتغيّر شيء.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Write-BridgeLog "Mojaz playback scheduled for $($scheduledAt.ToString('yyyy-MM-dd HH:mm')) by $userId"
    Add-AuditEntry "🕒 موعد موجز $($scheduledAt.ToString('HH:mm')) - بواسطة $(Format-UserAuditActor -UserId $userId)"
    Show-MojazScreen -ChatId $ChatId -UserId $userId
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
    $pending = @($script:MojazSchedules | Where-Object { [string](Get-JsonProp $_ 'Status') -in @('scheduled', 'queued') } |
            Sort-Object { [datetimeoffset](Get-JsonProp $_ 'ScheduledAt') })
    $keyboard = @()
    foreach ($entry in $pending) {
        $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId ([string](Get-JsonProp $entry 'BulletinId'))
        $name = if ($bulletin) { [string]$bulletin.Name } else { 'موجز محذوف' }
        $moment = [datetimeoffset](Get-JsonProp $entry 'ScheduledAt')
        $keyboard += , @((New-Button "🚫 $($moment.ToString('HH:mm')) · $name" "mojaz:unschedule:$([string](Get-JsonProp $entry 'Id'))" -Style danger))
    }
    $keyboard += , @((New-Button '⬅️ الموجزات' 'menu:mojaz'), (New-Button '🏠 القائمة' 'menu:main'))
    return @{ inline_keyboard = $keyboard }
}

function Show-MojazSchedulesScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-MojazSchedulesText) -ParseMode HTML -ReplyMarkup (Get-MojazSchedulesKeyboard)
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

function Update-MojazScheduleQueue {
    <#
        The clock, checked from the tick.

        Only one bulletin may be on air, so an appointment that comes due while
        another is running does not fight for the layer: it is queued, said
        once, and started later in the order the appointments were originally
        due - not the order they happened to be noticed.
    #>
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    $due = @(Get-MojazDueQueue -Schedules $script:MojazSchedules -Now $Now)
    if ($due.Count -eq 0) { return }
    if ($script:MojazPlayback) {
        foreach ($entry in $due) {
            if ([string](Get-JsonProp $entry 'Status') -ne 'scheduled') { continue }
            $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId ([string]$entry.BulletinId)
            $waitingName = if ($bulletin) { [string]$bulletin.Name } else { 'الموجز المجدول' }
            $activeName = if ([string]$script:MojazPlayback.BulletinName) { [string]$script:MojazPlayback.BulletinName } else { 'الموجز الحالي' }
            if (Set-MojazScheduleStatus -ScheduleId ([string]$entry.Id) -Status 'queued' -Fields @{ DueAt = $Now.ToString('o'); DelayReason = 'active_bulletin' }) {
                Send-TelegramMessage -ChatId ([long]$entry.ChatId) -Text "⏳ تأخّر «$waitingName» لأن «$activeName» ما زال على الهواء. سيبدأ بعد انتهائه."
            }
        }
        return
    }
    $next = $due[0]
    $scheduleId = [string]$next.Id
    if (-not (Set-MojazScheduleStatus -ScheduleId $scheduleId -Status 'running' -Fields @{ StartedAt = $Now.ToString('o') })) { return }
    $script:MojazSelections[[string]$next.ChatId] = [string]$next.BulletinId
    if (-not (Start-MojazPlayback -ChatId ([long]$next.ChatId) -UserId ([long]$next.CreatedBy) -ScheduleId $scheduleId)) {
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
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$ScheduleId = '')
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
    $schedule = if ($ScheduleId) { [pscustomobject]@{ Id = $ScheduleId } } else { $null }
    $syncOffset = (Get-SettingInt 'MojazSyncOffsetMs' 400) / 1000.0
    # Resolve the two timings here rather than leaving the module to guess:
    # these are the same numbers the screen printed, so what plays is what the
    # plan line promised. The saved bulletin is not touched - the copy carries
    # them into the snapshot, which owns the timing for this run alone.
    $resolved = $bulletin | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $resolved.IntroExtraSeconds = Get-MojazIntroSeconds -Bulletin $bulletin
    $resolved.LastRowSeconds = Get-MojazLastRowSeconds -Bulletin $bulletin
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
        BulletinRevision = [int]$snapshot.BulletinRevision
        ScheduleId = $ScheduleId
        TemplateImage = $templateImage
    }
    Write-BridgeLog "Mojaz playback started by $UserId ($($rows.Count) rows, $([int]$bulletin.DelaySeconds) s each)"
    Add-AuditEntry "📑 تشغيل «$([string]$snapshot.BulletinName)» ($($rows.Count) صفًّا) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-MojazScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Stop-MojazPlayback {
    <# Ends the bulletin the way it ends itself: EXIT, so the scene plays its
       outro instead of being cut. #>
    param([long]$ChatId = 0, [long]$UserId = 0, [switch]$Quiet)
    if (-not $script:MojazPlayback) { return $false }
    $playback = $script:MojazPlayback
    $script:MojazPlayback = $null
    $template = Get-MojazTemplate
    if ($template) {
        $chat = if ($ChatId -gt 0) { $ChatId } else { [long]$playback.ChatId }
        $user = if ($UserId -gt 0) { $UserId } else { [long]$playback.UserId }
        Invoke-ExitLayer -Layer ([int]$template.Layer) -ChatId $chat -UserId $user | Out-Null
    }
    if ([string]$playback.ScheduleId) {
        Set-MojazScheduleStatus -ScheduleId ([string]$playback.ScheduleId) -Status 'completed' -Fields @{ CompletedAt = [datetimeoffset]::Now.ToString('o') } | Out-Null
    }
    if (-not $Quiet -and $ChatId -gt 0) { Show-MojazScreen -ChatId $ChatId -UserId $UserId }
    return $true
}

function Get-MojazElapsedSeconds {
    <# How long this run has been going, by a clock that cannot step. #>
    if (-not $script:MojazPlayback) { return 0.0 }
    return ([double]$script:MojazPlayback.Clock.Elapsed.TotalSeconds + [double]$script:MojazPlayback.ClockOffset)
}

function Test-MojazOnAirLayer {
    <# Is the bulletin's layer occupied - by a run, or by a scene left up
       after one? #>
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
    if ([string]$playback.ScheduleId) {
        Set-MojazScheduleStatus -ScheduleId ([string]$playback.ScheduleId) -Status 'completed' -Fields @{ CompletedAt = [datetimeoffset]::Now.ToString('o') } | Out-Null
    }
    Write-BridgeLog "Mojaz playback ended: layer $Layer was taken off air."
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
    param([int]$MinimumAgeHours = 24)
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
