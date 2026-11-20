#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    The design contract and the timings: which fields a scene offers, what
    the operator filled in, and how a row hold sits against the loop the
    scene plays.

    Split out of Bridge.Mojaz.ps1, which had grown to 2733 lines - three times
    the size this repository asks a file to stay under, and past the point
    where the file's own table of contents fits on a screen. Nothing moved
    between scopes: dot-sourced parts share one, so this is the same text in
    four places instead of one.
#>

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
            catch { [pscustomobject]@{ Usable = $false; Reason = (T 'mjd.sceneUnreadable'); Fields = @(); SupportsRows = $false } }
        }
        else { [pscustomobject]@{ Usable = $false; Reason = (T 'mjd.sceneMissing'); Fields = @(); SupportsRows = $false } }
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

function Get-MojazFieldLabel {
    <#
        What to call a field when asking somebody to fill it.

        The scene declares the contract; it cannot declare Arabic. So the
        wording comes from the template registry's own fields list - the same
        one every ordinary template already uses for its prompts - and falls
        back to the variable's name, which is at least true.
    #>
    param([Parameter(Mandatory)][string]$TemplateKey, [Parameter(Mandatory)][string]$FieldName)
    $template = (Get-TemplateStore).Map[$TemplateKey]
    $declaredFields = @(Get-JsonProp $template 'Fields')
    $labels = @(Get-JsonProp $template 'FieldLabels')
    for ($i = 0; $i -lt $declaredFields.Count; $i++) {
        $declared = $declaredFields[$i]
        if ($declared -is [string]) {
            if ($declared -ne $FieldName) { continue }
            $label = if ($i -lt $labels.Count) { [string]$labels[$i] } else { '' }
        }
        else {
            if ([string](Get-JsonProp $declared 'Name') -ne $FieldName) { continue }
            $label = [string](Get-JsonProp $declared 'Label')
        }
        if ($label) { return $label }
    }
    return $FieldName
}

function Get-MojazRowFieldPrompts {
    <#
        What a row on this design asks for, in the order it will be asked.

        The registry's order wins where it says one, because that order is
        editorial - headline before story - and the scene lists its variables
        in whatever order they were declared, which is not the same thing.
        Fields the registry does not mention follow, so a variable added in
        Titler and not yet named still gets asked for rather than vanishing.

        A variable no element consumes is left out: filling it would put the
        value nowhere.
    #>
    param([Parameter(Mandatory)][string]$TemplateKey)
    $fields = @(Get-MojazDesignFields -TemplateKey $TemplateKey | Where-Object { $_.Consumed })
    if ($fields.Count -eq 0) { return @() }
    $declaredOrder = @(@(Get-JsonProp ((Get-TemplateStore).Map[$TemplateKey]) 'Fields') |
            ForEach-Object { if ($_ -is [string]) { $_ } else { [string](Get-JsonProp $_ 'Name') } } |
            Where-Object { $_ })
    $ordered = @()
    foreach ($name in $declaredOrder) {
        $match = @($fields | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
        if ($match.Count -gt 0) { $ordered += $match[0] }
    }
    foreach ($field in $fields) {
        if ($ordered | Where-Object { $_.Name -eq $field.Name }) { continue }
        $ordered += $field
    }
    return @($ordered | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Name
                Kind = [string]$_.Kind
                Label = Get-MojazFieldLabel -TemplateKey $TemplateKey -FieldName ([string]$_.Name)
                Width = [int]$_.Width
                Height = [int]$_.Height
            }
        })
}

function Get-MojazRowFieldValue {
    <#
        One field's value on one row.

        A row written for the built-in design has no field bag at all - it has
        the three properties it has always had - so those three names read
        from where they have always lived. Anything else reads from the bag.
        This is what lets a bulletin written before designs existed play on a
        design without being rewritten.
    #>
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$FieldName, [string]$Kind)
    $media = Get-JsonProp $Row 'MediaFields'
    if ($Kind -ne 'text' -and $media) {
        $attachment = if ($media -is [System.Collections.IDictionary]) { [string]$media[$FieldName] }
        else { [string]$media.PSObject.Properties[$FieldName]?.Value }
        if ($attachment) { return $attachment }
    }
    $bag = Get-JsonProp $Row 'Fields'
    if ($bag) {
        # Scene variable names can contain literal brackets. Properties.Match
        # treats them as wildcards, which would make a saved cell appear empty.
        $value = if ($bag -is [System.Collections.IDictionary]) { [string]$bag[$FieldName] }
        else { [string]$bag.PSObject.Properties[$FieldName]?.Value }
        if ($value) { return $value }
    }
    switch ($FieldName) {
        $script:MojazImageVariable { return [string](Get-JsonProp $Row 'Image') }
        $script:MojazTitleVariable { return [string](Get-JsonProp $Row 'Title') }
        $script:MojazTextVariable { return [string](Get-JsonProp $Row 'Text') }
        default { return '' }
    }
}

function Get-MojazRowValues {
    <# Everything this design asks for, as it stands on this row: what to send
       to the postbox, and what to show an editor who is filling it in. #>
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$TemplateKey)
    $values = [ordered]@{}
    foreach ($prompt in @(Get-MojazRowFieldPrompts -TemplateKey $TemplateKey)) {
        $values[$prompt.Name] = Get-MojazRowFieldValue -Row $Row -FieldName $prompt.Name -Kind $prompt.Kind
    }
    return $values
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
    if ($media -gt 0) { $parts += (T 'mjd.media' $media) }
    if ($text -gt 0) { $parts += (T 'mjd.text' $text) }
    if ($parts.Count -eq 0) { $parts += (T 'mjd.noFields') }
    $parts += $(if ($Design.SupportsRows) { (T 'mjd.manyHeadlines') } else { (T 'mjd.oneHeadline') })
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
        if ($window.HasPrevious) { $pager += (New-Button (T 'common.previous') "mojazdesignpage:$($window.Page - 1)") }
        $pager += (New-Button "$($window.Page + 1)/$($window.PageCount)" "mojazdesignpage:$($window.Page)")
        if ($window.HasNext) { $pager += (New-Button (T 'common.next') "mojazdesignpage:$($window.Page + 1)") }
        $rows += , $pager
    }
    $rows += , @( (New-Button (T 'common.cancel') 'menu:mojaz') )
    return @{ inline_keyboard = $rows }
}

function Show-MojazDesignScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$Page = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -ParseMode HTML -ReplyMarkup (Get-MojazDesignKeyboard -Page $Page) -Text (T 'mjd.screen')
}

function Get-MojazBulletinDesignChange {
    <# Binds a bulletin to a design, refusing while it is on air: changing the
       scene under a running bulletin would leave the rows being written into
       variables the new design has never heard of. #>
    param([Parameter(Mandatory)][string]$BulletinId, [Parameter(Mandatory)][AllowEmptyString()][string]$TemplateKey, [long]$UserId)
    if ([string](Get-JsonProp $script:MojazPlayback 'BulletinId') -eq $BulletinId) {
        return [pscustomobject]@{ Success = $false; ErrorCode = 'on_air'; Error = (T 'mjd.notWhileOnAir') }
    }
    $designs = @(Get-MojazUsableDesigns)
    $design = @($designs | Where-Object { $_.Key -eq $TemplateKey } | Select-Object -First 1)
    if ($design.Count -eq 0) {
        return [pscustomobject]@{ Success = $false; ErrorCode = 'design_missing'; Error = (T 'mjd.designGone') }
    }
    $savedBulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $BulletinId
    $rows = @(Get-JsonProp $savedBulletin 'Rows')
    $fieldKinds = @{}
    $savedKinds = Get-JsonProp $savedBulletin 'DesignFieldKinds'
    if ($savedKinds -is [System.Collections.IDictionary]) {
        foreach ($name in $savedKinds.Keys) { $fieldKinds[$name] = [string]$savedKinds[$name] }
    }
    elseif ($savedKinds) {
        foreach ($property in $savedKinds.PSObject.Properties) {
            $fieldKinds[$property.Name] = [string]$property.Value
        }
    }
    # A value can survive several designs with no matching column. Remember its
    # kind so a later text field cannot display an attachment path as text.
    foreach ($field in Get-MojazRowFieldPrompts -TemplateKey (Get-MojazBulletinDesignKey -Bulletin $savedBulletin)) {
        if (-not $fieldKinds.ContainsKey($field.Name)) { $fieldKinds[$field.Name] = $field.Kind }
    }
    $fieldKinds[$script:MojazImageVariable] = 'media'
    foreach ($field in $design[0].Fields) {
        if (-not $field.Consumed -or $fieldKinds[$field.Name] -eq $field.Kind) { continue }
        $previousKind = $fieldKinds[$field.Name]
        if (-not $previousKind) {
            # Older bulletins may already have dormant fields whose kind was
            # never saved. Only an unambiguous catalogue can identify them.
            $otherKind = $designs.Fields | Where-Object { $_.Consumed -and $_.Name -eq $field.Name -and $_.Kind -ne $field.Kind } | Select-Object -First 1
            if (-not $otherKind) { continue }
        }
        if ($rows | Where-Object { Get-MojazRowFieldValue -Row $_ -FieldName $field.Name } | Select-Object -First 1) {
            return [pscustomobject]@{ Success = $false; ErrorCode = 'design_collision'; Error = (T 'mjd.fieldKindCollision') }
        }
        $fieldKinds.Remove($field.Name)
    }
    return Set-MojazBulletinTemplate -Library $script:MojazLibrary -BulletinId $BulletinId -TemplateKey $design[0].Key -DesignFieldKinds $fieldKinds -UserId $UserId
}

function Set-MojazBulletinDesign {
    param([Parameter(Mandatory)][string]$BulletinId, [Parameter(Mandatory)][string]$TemplateKey,
        [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $result = Get-MojazBulletinDesignChange -BulletinId $BulletinId -TemplateKey $TemplateKey -UserId $UserId
    if ($result.ErrorCode -in 'on_air', 'design_missing', 'design_collision') {
        Send-TelegramMessage -ChatId $ChatId -Text $result.Error | Out-Null
        return $false
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

function Get-MojazPlaybackTemplate {
    param($Bulletin)
    $key = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    if ($key -eq $script:MojazTemplateKey) { return Get-MojazTemplate }
    return (Get-TemplateStore).Map[$key]
}

function Test-MojazBulletinPlaybackDesign {
    param([Parameter(Mandatory)]$Bulletin)
    $key = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    if ($key -ne $script:MojazTemplateKey) {
        if (-not (Get-Setting 'MojazMultiDesign')) { return $false }
        $template = Get-MojazPlaybackTemplate -Bulletin $Bulletin
        if (-not (Test-MojazDesignTemplate -Key $key -Template $template)) { return $false }
        if ([int](Get-JsonProp $template 'Layer') -le 0) { return $false }
        $timing = Get-MojazBulletinSceneTiming -Bulletin $Bulletin
        $fields = @(Get-MojazRowFieldPrompts -TemplateKey $key)
        if (-not $timing -or -not $fields.Count) { return $false }
        $included = @(Get-JsonProp $Bulletin 'Rows' | Where-Object { $_ -and -not (Get-JsonProp $_ 'Skipped') })
        # Canonical row images were stored relative to the built-in scene.
        # Reusing them from a different root would open an unrelated file.
        if ($fields | Where-Object { $_.Name -eq $script:MojazImageVariable -and $_.Kind -eq 'media' }) {
            $relativeImage = @(Get-JsonProp $Bulletin 'Rows' | Where-Object {
                    $reference = [string](Get-JsonProp $_ 'Image')
                    $reference -and -not [IO.Path]::IsPathFullyQualified($reference)
                }).Count -gt 0
            if ($relativeImage) {
                $builtInPath = [string](Get-JsonProp (Get-MojazTemplate) 'Path')
                if (-not $builtInPath -or (Split-Path -Parent $builtInPath) -ne (Split-Path -Parent ([string]$template.Path))) { return $false }
            }
        }
        return ([int]$timing.LoopFrames -gt 0 -or $included.Count -le 1)
    }
    $supported = @($script:MojazTitleVariable, $script:MojazTextVariable, $script:MojazImageVariable)
    return @(Get-MojazRowFieldPrompts -TemplateKey $key | Where-Object { $_.Name -notin $supported }).Count -eq 0
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
    param([string]$Path = '', [switch]$AllowNonLooping)
    if (-not $Path) {
        $template = Get-MojazTemplate
        if (-not $template) { return $null }
        $Path = [string]$template.Path
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stamp = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTimeUtc
    $key = "$Path|$stamp|$AllowNonLooping"
    # Keyed by path, not a single slot. Two scenes are read now - the bulletin's
    # and the breaking-news board's - and a one-slot cache is not a cache when
    # two callers alternate: each call would evict the other's entry and re-read
    # the file from disk, on the path that draws a screen.
    if ($script:MojazSceneTimingCache.ContainsKey($key)) { return $script:MojazSceneTimingCache[$key] }
    $timing = $null
    try {
        $document = [xml](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        $scene = $document.SelectSingleNode('/*[local-name()="Scene"] | /*[local-name()="CinegyTitler"]/*[local-name()="Scene"]')
        $fps = [double](Get-JsonProp $scene 'Fps')
        $startMarker = Get-JsonProp $scene 'LoopStartFrame'
        $endMarker = Get-JsonProp $scene 'LoopEndFrame'
        $loopStart = [double]$startMarker
        $loopEnd = [double]$endMarker
        $duration = [double](Get-JsonProp $scene 'Duration')
        $hasClock = $fps -gt 0 -and [double]::IsFinite($fps) -and $duration -gt 0 -and [double]::IsFinite($duration)
        if ($hasClock -and -not [string]::IsNullOrWhiteSpace([string]$startMarker) -and
            -not [string]::IsNullOrWhiteSpace([string]$endMarker) -and
            $loopStart -ge 0 -and $loopEnd -gt $loopStart -and $duration -ge $loopEnd) {
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
        elseif ($hasClock -and $AllowNonLooping) {
            $timing = [pscustomobject]@{
                Fps = $fps; IntroFrames = 0; LoopFrames = 0; OutroFrames = 0
                IntroSeconds = 0.0; LoopSeconds = 0.0; OutroSeconds = 0.0
            }
        }
    }
    catch { Write-BridgeLog "Could not read the scene timing of '$Path': $($_.Exception.Message)" 'WARN' }
    # Bounded on purpose: this only ever holds one entry per scene file per
    # write time, and a scene re-cut all day would otherwise grow it forever.
    if ($script:MojazSceneTimingCache.Count -gt 16) { $script:MojazSceneTimingCache.Clear() }
    $script:MojazSceneTimingCache[$key] = $timing
    return $timing
}

function Get-MojazBulletinSceneTiming {
    param($Bulletin)
    $key = Get-MojazBulletinDesignKey -Bulletin $Bulletin
    if ($key -eq $script:MojazTemplateKey) { return Get-MojazSceneTiming }
    $template = (Get-TemplateStore).Map[$key]
    if (-not $template -or -not (Test-MojazDesignTemplate -Key $key -Template $template)) { return $null }
    $scenePath = [string](Get-JsonProp $template 'Path')
    if ($scenePath) { return Get-MojazSceneTiming -Path $scenePath -AllowNonLooping }
}

function Get-MojazFps {
    <#
        The frame rate every frame count here is measured against.

        The scene's own rate first - it is the thing being timed, and it
        cannot be wrong about itself. The channel's configured rate only when
        the scene cannot be read, which is the case the setting exists for.
    #>
    param($Bulletin)
    $timing = Get-MojazBulletinSceneTiming -Bulletin $Bulletin
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
        if ($legacy -gt 0) { return [int][math]::Round($legacy * (Get-MojazFps -Bulletin $Bulletin)) }
    }
    $default = Get-SettingInt 'MojazRowFrames' 0
    if ($default -gt 0) { return $default }
    return [int][math]::Round(8 * (Get-MojazFps -Bulletin $Bulletin))
}

function Get-MojazLoopFitNote {
    <#
        Says out loud what a row hold does against the scene's own loop.

        Both numbers were already on the bulletin screen - the hold, and the
        template's loop length - and nobody compared them. A bulletin held 1500
        frames against a 750-frame loop played every headline twice on air, and
        read to the operator as a bulletin stuck on one item. The screen showed
        both figures and left the arithmetic to a person watching a live
        transmission.

        Silent when the two already agree, when there is no scene timing to
        compare against, and when the bulletin syncs to the loop - that setting
        takes its pace from the loop and cannot drift from it.
    #>
    param([int]$DelayFrames, [int]$LoopFrames)
    if ($LoopFrames -le 0 -or $DelayFrames -le 0) { return '' }

    # Two frames of slack: a hold typed in seconds and converted back lands a
    # frame either side of the loop without meaning anything different.
    $remainder = $DelayFrames % $LoopFrames
    $aligned = ($remainder -le 2) -or (($LoopFrames - $remainder) -le 2)

    if ($aligned) {
        $times = [int][math]::Round($DelayFrames / $LoopFrames)
        if ($times -le 1) { return '' }
        $framesText = Get-ArabicCountNoun -Count $LoopFrames -One 'إطار' -Two 'إطاران' -Few 'إطارات' -Many 'إطارًا' -EnglishOne 'frame' -EnglishMany 'frames'
        $timesText = Get-ArabicCountNoun -Count $times -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' -EnglishOne 'time' -EnglishMany 'times'
        return (T 'mjd.durationMultiple' $times $framesText $timesText $framesText)
    }
    return (T 'mjd.durationMismatch' $(Get-ArabicCountNoun -Count $LoopFrames -One 'إطار' -Two 'إطاران' -Few 'إطارات' -Many 'إطارًا' -EnglishOne 'frame' -EnglishMany 'frames') $LoopFrames)
}

function Get-MojazBulletinLoopFitNote {
    <# The note for one bulletin, with the scene timing looked up for it. #>
    param($Bulletin)
    if (Test-MojazSyncToLoop -Bulletin $Bulletin) { return '' }
    $timing = Get-MojazBulletinSceneTiming -Bulletin $Bulletin
    if (-not $timing) { return '' }
    return (Get-MojazLoopFitNote -DelayFrames (Get-MojazDelayFrames -Bulletin $Bulletin) `
            -LoopFrames ([int](Get-JsonProp $timing 'LoopFrames')))
}

function Get-MojazDelaySeconds {
    param($Bulletin)
    return [math]::Round((Get-MojazDelayFrames -Bulletin $Bulletin) / (Get-MojazFps -Bulletin $Bulletin), 3)
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
        if ($legacy -gt 0) { return [int][math]::Round($legacy * (Get-MojazFps -Bulletin $Bulletin)) }
    }
    $default = Get-SettingInt 'MojazIntroExtraFrames' 0
    if ($default -gt 0) { return $default }
    return (Get-MojazSceneFrames -Which intro -Bulletin $Bulletin)
}

function Get-MojazSceneFrames {
    <# The scene's own entrance or exit in frames. Derived from its seconds
       when the frames are not there, so a caller holding an older timing -
       or a test standing in for one - still gets an answer. #>
    param([Parameter(Mandatory)][ValidateSet('intro', 'outro')][string]$Which, $Bulletin)
    $timing = Get-MojazBulletinSceneTiming -Bulletin $Bulletin
    if (-not $timing) { return 0 }
    $name = if ($Which -eq 'intro') { 'IntroFrames' } else { 'OutroFrames' }
    $frames = [int](Get-JsonProp $timing $name)
    if ($frames -gt 0) { return $frames }
    $seconds = [double](Get-JsonProp $timing $(if ($Which -eq 'intro') { 'IntroSeconds' } else { 'OutroSeconds' }))
    if ($seconds -le 0) { return 0 }
    return [int][math]::Round($seconds * (Get-MojazFps -Bulletin $Bulletin))
}

function Get-MojazIntroSeconds {
    param($Bulletin)
    return [math]::Round((Get-MojazIntroFrames -Bulletin $Bulletin) / (Get-MojazFps -Bulletin $Bulletin), 3)
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
        if ($legacy -gt 0) { return [int][math]::Round($legacy * (Get-MojazFps -Bulletin $Bulletin)) }
    }
    $default = Get-SettingInt 'MojazLastRowFrames' 0
    if ($default -gt 0) { return $default }
    $sceneFrames = Get-MojazSceneFrames -Which outro -Bulletin $Bulletin
    if ($sceneFrames -gt 0) { return $sceneFrames }
    # Half the dwell, in frames, when the scene has no exit to copy.
    return [int][math]::Max((Get-MojazFps -Bulletin $Bulletin), [math]::Floor((Get-MojazDelayFrames -Bulletin $Bulletin) / 2))
}

function Get-MojazLastRowSeconds {
    param($Bulletin)
    return [math]::Round((Get-MojazLastRowFrames -Bulletin $Bulletin) / (Get-MojazFps -Bulletin $Bulletin), 3)
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
    $timing = Get-MojazBulletinSceneTiming -Bulletin $Bulletin
    if (-not (Test-MojazSyncToLoop -Bulletin $Bulletin)) {
        return (T 'mjd.syncOff')
    }
    if (-not $timing -or [double]$timing.LoopSeconds -le 0) {
        return (T 'mjd.syncWantedNoLoop')
    }
    $loop = [double]$timing.LoopSeconds
    $line = (T 'mjd.syncExplain' $loop $($timing.IntroSeconds))
    if ($loop -ge 30) {
        $line += (T 'mjd.loopLong' $loop)
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
    $timing = Get-MojazBulletinSceneTiming -Bulletin $Bulletin
    if ((Test-MojazSyncToLoop -Bulletin $Bulletin) -and $timing -and [double]$timing.LoopSeconds -gt 0) {
        # The loop owns the pace here, so quoting the dwell would be a lie.
        $plan = New-MojazLoopPlan -SceneTiming $timing -RowCount $rows.Count -OffsetSeconds ((Get-SettingInt 'MojazSyncOffsetMs' 400) / 1000.0)
        $total = [int][math]::Ceiling([double]$plan.ExitOffset + [double]$timing.OutroSeconds)
        return (T 'mjd.oneLoopPerRow' $($timing.LoopSeconds) $(Format-DurationSeconds -Seconds $total) $(Get-MojazSyncText -Bulletin $Bulletin))
    }
    $delay = Get-MojazDelaySeconds -Bulletin $Bulletin
    $intro = Get-MojazIntroSeconds -Bulletin $Bulletin
    $last = Get-MojazLastRowSeconds -Bulletin $Bulletin
    $total = ($delay * [math]::Max(0, $rows.Count - 1)) + $intro + $last
    $line = (T 'mjd.framesPerRow' $(Get-MojazDelayFrames -Bulletin $Bulletin) $delay $(Get-MojazIntroFrames -Bulletin $Bulletin) $(Get-MojazLastRowFrames -Bulletin $Bulletin) $(Format-DurationSeconds -Seconds ([int][math]::Ceiling($total))))
    $timing = Get-MojazBulletinSceneTiming -Bulletin $Bulletin
    if ($timing) {
        $line += (T 'mjd.fromTemplate' $(Get-MojazSceneFrames -Which intro -Bulletin $Bulletin) $([int](Get-JsonProp $timing 'LoopFrames')) $(Get-MojazSceneFrames -Which outro -Bulletin $Bulletin) $(Get-MojazFps -Bulletin $Bulletin))
        # Directly under the two figures it compares, because that is where an
        # operator was left to do the arithmetic themselves.
        $fit = Get-MojazBulletinLoopFitNote -Bulletin $Bulletin
        if ($fit) { $line += "`n$fit" }
    }
    if (Test-MojazSyncToLoop -Bulletin $Bulletin) {
        $loopSeconds = if ($timing) { [double](Get-JsonProp $timing 'LoopSeconds') } else { 0 }
        $line += (T 'mjd.syncOn')
        if ($loopSeconds -gt 0) {
            $line += (T 'mjd.paceBecomesLoop' $(Format-DurationSeconds -Seconds ([int][math]::Round($loopSeconds))))
        }
        $line += '.'
    }
    return $line
}
