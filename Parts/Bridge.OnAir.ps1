#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Import-UsageCounts {
    if (-not (Test-Path $usageFile)) { return }
    try {
        $raw = Get-Content -Path $usageFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            if ($prop.Value -is [ValueType]) { $script:UsageCounts[$prop.Name] = [int]$prop.Value; continue }
            $script:UsageCounts[$prop.Name] = [int](Get-JsonProp $prop.Value 'Count')
            $lastUsed = [string](Get-JsonProp $prop.Value 'LastUsedUtc')
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($lastUsed, [ref]$parsed)) { $script:TemplateLastUsed[$prop.Name] = $parsed.ToUniversalTime() }
        }
    }
    catch { Write-BridgeLog "Could not read usage.json: $($_.Exception.Message)" "WARN" }
}

function Add-UsageCount {
    <# Counts in memory and marks the file dirty; the actual write is deferred
       to the tick. Writing on every push put synchronous disk I/O directly on
       the on-air path for what is only a button-ordering statistic. #>
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:UsageCounts.ContainsKey($Key)) { $script:UsageCounts[$Key] = 0 }
    $script:UsageCounts[$Key]++
    $script:TemplateLastUsed[$Key] = [datetime]::UtcNow
    $script:UsageDirty = $true
}

function Save-UsageCounts {
    param([switch]$Force)
    if (-not $script:UsageDirty) { return }
    if (-not $Force -and ((Get-Date) - $script:LastUsageFlush).TotalSeconds -lt 60) { return }
    $script:LastUsageFlush = Get-Date
    try {
        $persisted = [ordered]@{}
        foreach ($key in @($script:UsageCounts.Keys | Sort-Object)) {
            $persisted[$key] = [ordered]@{
                Count = [int]$script:UsageCounts[$key]
                LastUsedUtc = if ($script:TemplateLastUsed.ContainsKey($key)) { ([datetime]$script:TemplateLastUsed[$key]).ToUniversalTime().ToString('o') } else { '' }
            }
        }
        # Checked, not assumed: the writer returns $false instead of throwing,
        # so clearing the dirty flag regardless used to record "saved" for a
        # write that never landed - with no log line either way.
        if (-not (Write-BridgeValidatedJson -Path $usageFile -Json ($persisted | ConvertTo-Json -Depth 4))) {
            throw 'Validated JSON write failed.'
        }
        $script:UsageDirty = $false
    }
    catch { Write-BridgeLog "Could not write usage.json: $($_.Exception.Message)" "WARN" }
}

function Sync-OnAirProjection {
    $script:OnAir.Clear()
    foreach ($layer in @($script:OnAirScenes | ForEach-Object { [int]$_.Layer } | Sort-Object -Unique)) {
        $scene = $script:OnAirScenes | Where-Object { [int]$_.Layer -eq $layer } | Select-Object -First 1
        if ($null -eq $scene) { continue }
        $at = Get-Date
        $parsedAt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$scene.At, [ref]$parsedAt)) { $at = $parsedAt }
        $script:OnAir[$layer] = @{ Key = [string]$scene.Key; At = $at; UserId = [long]$scene.UserId; ActiveId = [string]$scene.ActiveId; ActiveIdConfirmed = [bool](Get-JsonProp $scene 'ActiveIdConfirmed'); Source = [string]$scene.Source }
    }
}

function Set-OnAirCanonicalScenes {
    param([Parameter(Mandatory)][object[]]$Scenes)
    $script:OnAirScenes = [System.Collections.Generic.List[object]]::new()
    foreach ($scene in $Scenes) { $script:OnAirScenes.Add($scene) }
    Sync-OnAirProjection
}

function Set-OnAirLayerRecord {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)]$Record)
    if ($null -eq $script:OnAirScenes) { $script:OnAirScenes = [System.Collections.Generic.List[object]]::new() }
    for ($i = $script:OnAirScenes.Count - 1; $i -ge 0; $i--) {
        if ([int]$script:OnAirScenes[$i].Layer -eq $Layer) { $script:OnAirScenes.RemoveAt($i) }
    }
    $atValue = Get-JsonProp $Record 'At'
    $at = if ($atValue -is [datetime]) { $atValue.ToString('o') } elseif ($atValue) { [string]$atValue } else { (Get-Date).ToString('o') }
    $script:OnAirScenes.Add([pscustomobject]@{
            SceneId = "scene-$([guid]::NewGuid().ToString('N'))"; Layer = $Layer; Key = [string](Get-JsonProp $Record 'Key')
            At = $at; UserId = [long](Get-JsonProp $Record 'UserId'); ChatId = [long](Get-JsonProp $Record 'ChatId')
            ActiveId = [string](Get-JsonProp $Record 'ActiveId'); ActiveIdConfirmed = [bool](Get-JsonProp $Record 'ActiveIdConfirmed'); Source = if (Get-JsonProp $Record 'Source') { [string](Get-JsonProp $Record 'Source') } else { 'bridge' }
            TemplatePath = [string](Get-JsonProp $Record 'TemplatePath'); LastVerifiedAtUtc = [string](Get-JsonProp $Record 'LastVerifiedAtUtc')
        })
    $script:OnAir[$Layer] = $Record
}

function Update-OnAirLayerRecord {
    <# Reconciliation changes Cinegy metadata for the scene represented by the
       compatibility projection. It must never erase other canonical scenes on
       the same Multi layer. #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)]$Record)
    if ($null -eq $script:OnAirScenes) { $script:OnAirScenes = [System.Collections.Generic.List[object]]::new() }
    $scene = $script:OnAirScenes | Where-Object { [int]$_.Layer -eq $Layer } | Select-Object -First 1
    if ($null -eq $scene) {
        Set-OnAirLayerRecord -Layer $Layer -Record $Record
        return
    }
    foreach ($name in @('Key', 'At', 'UserId', 'ChatId', 'ActiveId', 'ActiveIdConfirmed', 'Source', 'TemplatePath', 'LastVerifiedAtUtc')) {
        $value = Get-JsonProp $Record $name
        if ($null -ne $value) {
            if ($name -eq 'At' -and $value -is [datetime]) { $value = $value.ToString('o') }
            $scene.$name = $value
        }
    }
    foreach ($candidate in @($script:OnAirScenes | Where-Object { [int]$_.Layer -eq $Layer })) {
        if (-not [object]::ReferenceEquals($candidate, $scene)) { $candidate.ActiveId = '' }
    }
    $script:OnAir[$Layer] = $Record
}

function Set-OnAirShownRecord {
    <# A SHOW replaces the active projection. Single mode deliberately keeps
       one record; Multi keeps the same-layer catalogue but clears stale
       ActiveIds so only the new primary represents Cinegy's current item. #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)]$Record)
    $hasLayerCatalogue = $null -ne $script:OnAirScenes -and
        @($script:OnAirScenes | Where-Object { [int]$_.Layer -eq $Layer }).Count -gt 0
    if ([string](Get-Setting 'SceneMode') -eq 'Multi' -and $hasLayerCatalogue) {
        Update-OnAirLayerRecord -Layer $Layer -Record $Record
        return
    }
    Set-OnAirLayerRecord -Layer $Layer -Record $Record
}

function Remove-OnAirLayerScenes {
    param([Parameter(Mandatory)][int]$Layer)
    if ($null -ne $script:OnAirScenes) {
        for ($i = $script:OnAirScenes.Count - 1; $i -ge 0; $i--) {
            if ([int]$script:OnAirScenes[$i].Layer -eq $Layer) { $script:OnAirScenes.RemoveAt($i) }
        }
    }
    [void]$script:OnAir.Remove($Layer)
}

function Sync-OnAirCanonicalFromProjection {
    if ($null -eq $script:OnAirScenes) { $script:OnAirScenes = [System.Collections.Generic.List[object]]::new() }
    foreach ($layer in @($script:OnAirScenes | ForEach-Object { [int]$_.Layer } | Sort-Object -Unique)) {
        if (-not $script:OnAir.ContainsKey($layer)) { Remove-OnAirLayerScenes -Layer $layer }
    }
    foreach ($layer in @($script:OnAir.Keys)) {
        $record = $script:OnAir[$layer]
        $primary = $script:OnAirScenes | Where-Object { [int]$_.Layer -eq [int]$layer } | Select-Object -First 1
        $sameIdentity = $primary -and
            [string]$primary.ActiveId -eq [string](Get-JsonProp $record 'ActiveId') -and
            [string]$primary.Key -eq [string](Get-JsonProp $record 'Key') -and
            [bool](Get-JsonProp $primary 'ActiveIdConfirmed') -eq [bool](Get-JsonProp $record 'ActiveIdConfirmed')
        if (-not $sameIdentity) { Update-OnAirLayerRecord -Layer ([int]$layer) -Record $record }
    }
}

function Import-OnAirState {
    <# Restores what the bridge believed was live before a restart, so the
       🔴 row and one-tap hide survive a service bounce. Treated as advisory:
       it is the bot's own record, not a query of Air Pro. #>
    try {
        $read = Read-ValidatedJsonState -Path $onAirFile
        if (-not $read) { return }
        $raw = $read.Data
        $sceneState = ConvertTo-BridgeLiveSceneState -Document $raw
        if (-not $sceneState.Success) { throw "invalid live-scene state: $($sceneState.Error)" }
        Set-OnAirCanonicalScenes -Scenes @($sceneState.Scenes)
        # Rewrite a valid legacy file only after it was successfully converted
        # and loaded. Write-ValidatedJsonState creates the backup before its
        # atomic replacement, leaving the primary untouched on any failure.
        if ($raw.PSObject.Properties.Match('Scenes').Count -eq 0) { Save-OnAirState }
        if ($script:OnAir.Count -gt 0) { Write-BridgeLog "Restored on-air record for $($script:OnAir.Count) layer(s) from the previous run" }
    }
    catch { Write-BridgeLog "Could not read onair.json: $($_.Exception.Message)" "WARN" }
}

function Remove-OnAirRecord {
    <#
        Drops the bridge's own record for a layer after the operator has
        successfully removed the graphic from it.

        HIDE makes Cinegy report the layer's active item with IsEmpty="y", so
        reconciling against a status read afterwards correctly clears the
        record. EXIT_SCENE_LOOP does not: the playlist item stays Active under
        the same Id with no IsEmpty marker, so a read after EXIT is
        indistinguishable from a live scene. Reconciliation therefore kept the
        record forever, and the bridge went on claiming a graphic was on air
        long after it had left the screen.

        The bridge just performed the removal and knows what it did; a read
        that cannot represent the change is not evidence against it.
    #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][string]$Reason)
    if (-not $script:OnAir.ContainsKey([int]$Layer)) { return $false }
    Remove-OnAirLayerScenes -Layer $Layer
    $script:OnAirDirty = $true
    Save-OnAirState
    Remove-TemplateRemindersForLayer -Layer $Layer | Out-Null
    Write-BridgeLog "Dropped on-air record for layer $Layer ($Reason)"
    return $true
}

function Save-OnAirState {
    try {
        Write-BridgeLog "Save-OnAirState invoked (in-memory layers: $($script:OnAir.Keys.Count))" "DEBUG"
        $parentDir = Split-Path $onAirFile -Parent
        if (-not (Test-Path -LiteralPath $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Sync-OnAirCanonicalFromProjection
        $canonical = ConvertTo-BridgeLiveSceneState -Document ([pscustomobject]@{ Scenes = @($script:OnAirScenes) })
        if (-not $canonical.Success) { throw "invalid live-scene state: $($canonical.Error)" }
        $json = [ordered]@{ SchemaVersion = 1; Scenes = @($canonical.Scenes) } | ConvertTo-Json -Depth 6
        Write-BridgeLog "Writing validated onair payload (size: $($json.Length) chars)" "DEBUG"
        if (-not (Write-ValidatedJsonState -Path $onAirFile -Json $json)) { throw 'validated state write failed' }
        Write-BridgeLog "Wrote onair.json ($($canonical.Scenes.Count) scene(s)) to $onAirFile" "INFO"
    }
    catch { Write-BridgeLog "Could not write onair.json: $($_.Exception.Message)" "WARN" }
}

function Update-OnAirStateFromCinegy {
    <# Reconciles onair.json with Cinegy's current GFX-layer state. Regular
       watchdog calls verify bridge-tracked layers only. Operator checks pass a
       full dashboard sample with -DiscoverExternal, allowing scenes started
       directly in Cinegy to become hideable without turning onair.json into a
       historical log. Failed queries never add or remove state. #>
    param(
        [string]$Reason = 'manual',
        [object[]]$LayerStatuses = @(),
        [int]$TimeoutSec = 0,
        [switch]$DiscoverExternal
    )
    if ($TimeoutSec -le 0) { $TimeoutSec = Get-AirTimeout }

    $checked = [System.Collections.Generic.List[int]]::new()
    $added = [System.Collections.Generic.List[int]]::new()
    $removed = [System.Collections.Generic.List[int]]::new()
    $failed = [System.Collections.Generic.List[int]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()
    $autoHideDirty = $false
    $templateReminderDirty = $false
    $statusByLayer = @{}
    foreach ($item in @($LayerStatuses)) {
        $itemLayer = 0
        if ([int]::TryParse([string](Get-JsonProp $item 'Layer'), [ref]$itemLayer)) {
            $statusByLayer[$itemLayer] = $item
        }
    }

    foreach ($layer in @($script:OnAir.Keys)) {
        $status = if ($statusByLayer.ContainsKey([int]$layer)) { $statusByLayer[[int]$layer] }
        else {
            Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
                -AirChannelNumber $config.AirChannelNumber -Layer ([int]$layer) -TimeoutSec $TimeoutSec
        }
        $record = $script:OnAir[$layer]
        $decision = Resolve-BridgeCinegyLayerState -Layer ([int]$layer) -TrackedRecord $record -Status $status
        if ($decision.Action -eq 'failed') {
            $failed.Add([int]$layer)
            Write-BridgeLog "Could not verify GFX layer $layer during $Reason sync: $($status.Error)" "WARN"
            # Keep the record: an unavailable engine is not the same as a hidden graphic.
            continue
        }

        $checked.Add([int]$layer)
        if ($decision.Action -eq 'update') {
            Update-OnAirLayerRecord -Layer ([int]$layer) -Record $decision.Record
            $script:OnAirDirty = $true
        }
        elseif ($decision.Action -eq 'remove') {
            # Genuinely hidden (IsEmpty) or replaced off air: drop from the
            # on-air record so onair.json reflects what is live now.
            $changes.Add($decision.Change)
            Remove-OnAirLayerScenes -Layer ([int]$layer)
            # An engine walking this layer has to stop with it. Stop-MojazForLayer
            # and its urgent twin are called by the hide button, by an exit and by
            # a replacing SHOW - every way a layer is taken except this one, which
            # is the way Cinegy takes it.
            #
            # Measured: a bulletin whose layer Cinegy emptied at 18:11:39 went on
            # writing rows until 18:12:59 and then sent its own EXIT to a layer it
            # no longer owned. Send-PostboxValues is channel-wide and takes no
            # layer at all, so those rows went wherever the channel was pointing.
            #
            # The record is already gone above, so neither of these exits again.
            Stop-MojazForLayer -Layer ([int]$layer) | Out-Null
            Stop-UrgentBoardForLayer -Layer ([int]$layer) | Out-Null
            $recordSource = [string](Get-JsonProp $record 'Source')
            if ([string]::IsNullOrWhiteSpace($recordSource)) { $recordSource = 'bridge' }
            # Change is null when a discovered record is dropped for want of a
            # name, so the reason and the engine id are read off it defensively:
            # a log line that throws under StrictMode takes the sync with it.
            $offAirReason = if ($decision.Change) { [string]$decision.Change.OffAirReason } else { '' }
            if ([string]::IsNullOrWhiteSpace($offAirReason)) { $offAirReason = 'unstated' }
            $engineActiveId = if ($decision.Change) { [string]$decision.Change.ActualActiveId } else { '' }
            # The engine's own words, so a graphic that left by itself can be
            # traced to whoever cleared it: the Client node names an attached
            # Cinegy client when there is one, and the active item carries
            # the command that made it. Both were read and thrown away.
            $engineWords = if ($decision.Change) {
                @(
                    "client $(if ([string]::IsNullOrWhiteSpace([string]$decision.Change.ClientXml)) { '(none)' } else { ([string]$decision.Change.ClientXml) -replace '\s+', ' ' })"
                    "active $(if ([string]::IsNullOrWhiteSpace([string]$decision.Change.ActiveXml)) { '(none)' } else { ([string]$decision.Change.ActiveXml) -replace '\s+', ' ' })"
                ) -join ', '
            } else { '' }
            Write-BridgeLog "Cinegy state sync ($Reason) removed on-air record for layer $layer after Cinegy reported it off air ($offAirReason); template '$([string](Get-JsonProp $record 'Key'))', source $recordSource, user $([long](Get-JsonProp $record 'UserId')), expected active id '$([string](Get-JsonProp $record 'ActiveId'))', engine reported '$engineActiveId'$(if ($engineWords) { "; $engineWords" })" "INFO"
            # A stale timer must not hide a different scene that an external
            # controller may put on the same layer later.
            for ($i = $script:AutoHideQueue.Count - 1; $i -ge 0; $i--) {
                if ([int]$script:AutoHideQueue[$i].Layer -eq [int]$layer) {
                    $script:AutoHideQueue.RemoveAt($i)
                    $autoHideDirty = $true
                }
            }
            for ($i = $script:TemplateReminderQueue.Count - 1; $i -ge 0; $i--) {
                if ([int]$script:TemplateReminderQueue[$i].Layer -eq [int]$layer) {
                    $script:TemplateReminderQueue.RemoveAt($i)
                    $templateReminderDirty = $true
                }
            }
            $removed.Add([int]$layer)
        }
    }

    if ($DiscoverExternal) {
        foreach ($item in @($LayerStatuses)) {
            $layer = 0
            if (-not [int]::TryParse([string](Get-JsonProp $item 'Layer'), [ref]$layer)) { continue }
            if ($script:OnAir.ContainsKey($layer)) { continue }
            $decision = Resolve-BridgeCinegyLayerState -Layer $layer -Status $item -DiscoverExternal
            if ($decision.Action -eq 'failed') {
                if (-not $failed.Contains($layer)) { $failed.Add($layer) }
                Write-BridgeLog "Could not discover GFX layer $layer during $Reason comparison: $([string](Get-JsonProp $item 'Error'))" "WARN"
                continue
            }
            if ($decision.Action -ne 'add') { continue }
            Set-OnAirLayerRecord -Layer $layer -Record $decision.Record
            $added.Add($layer)
            $script:OnAirDirty = $true
            Write-BridgeLog "Cinegy state comparison ($Reason) discovered external on-air scene '$([string]$decision.Record.Key)' on layer $layer; added to onair.json for operator hide/exit" "INFO"
        }
    }

    if ($added.Count -gt 0 -or $removed.Count -gt 0 -or $script:OnAirDirty) {
        Save-OnAirState
        $script:OnAirDirty = $false
        if ($removed.Count -gt 0) {
            Write-BridgeLog "Cinegy state sync ($Reason) removed stale layer record(s): $($removed -join ', ')"
        }
    }
    if ($autoHideDirty) { Save-AutoHideQueue | Out-Null }
    if ($templateReminderDirty) { Save-TemplateReminderQueue | Out-Null }

    $suppliedCount = @($LayerStatuses).Count
    if ($failed.Count -eq 0 -and ($checked.Count -gt 0 -or $suppliedCount -gt 0)) {
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = Get-Date
    }

    return [pscustomobject]@{
        Checked = $checked.ToArray()
        Added   = $added.ToArray()
        Removed = $removed.ToArray()
        Failed  = $failed.ToArray()
        Changes = $changes.ToArray()
        LastSuccessfulAt = if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }
    }
}

function Initialize-CinegyOnAirState {
    <# Startup is the highest-risk moment for stale state: read every configured
       GFX layer before accepting operator commands, discover scenes started in
       Cinegy, and preserve any local record whose layer cannot be verified. #>
    $layerStatuses = @(Get-CinegyLayerDashboard)
    $sync = Update-OnAirStateFromCinegy -Reason 'startup' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal
    if ($sync.Failed.Count -gt 0) {
        Write-BridgeLog "Startup Cinegy comparison uncertain; preserved on-air record(s) for unverified layer(s): $($sync.Failed -join ', ')" "WARN"
    }
    else {
        Write-BridgeLog "Startup Cinegy comparison complete (added: $(@($sync.Added).Count); removed: $(@($sync.Removed).Count); checked: $(@($layerStatuses).Count))" "INFO"
    }
    return $sync
}

function Get-CinegyStateFreshness {
    param(
        [AllowNull()][object]$LastSuccessfulAt,
        [int]$FailedCount = 0,
        [datetime]$Now = (Get-Date),
        [int]$StaleAfterSeconds = 45
    )
    if ($FailedCount -gt 0) {
        return [pscustomobject]@{ State = 'unavailable'; Label = (T 'onair.unavailable'); AgeSeconds = $null }
    }
    if ($null -eq $LastSuccessfulAt -or [string]::IsNullOrWhiteSpace([string]$LastSuccessfulAt)) {
        return [pscustomobject]@{ State = 'unknown'; Label = (T 'onair.unknownDot'); AgeSeconds = $null }
    }
    $ageSeconds = [math]::Max(0, [math]::Floor(($Now - ([datetime]$LastSuccessfulAt)).TotalSeconds))
    if ($ageSeconds -gt [math]::Max(1, $StaleAfterSeconds)) {
        # Seconds are the right unit for "45 seconds behind" and a useless one
        # for "372741 ثانية", which is four days nobody will divide out while
        # glancing at a status screen.
        return [pscustomobject]@{ State = 'stale'; Label = (T 'onair.lateSince' $(Format-DurationSeconds -Seconds $ageSeconds)); AgeSeconds = $ageSeconds }
    }
    return [pscustomobject]@{ State = 'connected'; Label = (T 'onair.connected'); AgeSeconds = $ageSeconds }
}

function Format-ExternalCinegyChangeAlert {
    param([Parameter(Mandatory)][object[]]$Changes)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'onair.externalChange'))
    $lines.Add((T 'onair.airServer' $($config.AirServerAddress) $($config.AirChannelNumber)))
    foreach ($change in @($Changes)) {
        # Asked of the decision, not re-derived from the id. An id survives a
        # scene that has simply ended, so "has an id" meant "a stranger took
        # the layer" - the alarming half of a story whose own log line said
        # the layer was confirmed hidden.
        $replaced = [bool](Get-JsonProp $change 'Replaced')
        $state = if ($replaced) { (T 'onair.replacedExternally') } else { (T 'onair.noLongerOnAir') }
        $lines.Add('')
        $lines.Add("$(Get-LayerDisplayName -Layer ([int]$change.Layer)): $state")
        $lines.Add((T 'onair.botTemplate' $($change.TemplateKey)))
        $lines.Add((T 'onair.operatorStarted' $($change.ShowUserId) $($change.ShownAt)))
        $lines.Add((T 'onair.previousId' $($change.ExpectedActiveId)))
        if ($replaced) {
            $name = if ([string]::IsNullOrWhiteSpace([string]$change.ActualActiveName)) { (T 'onair.unnamedItem') } else { $change.ActualActiveName }
            $lines.Add((T 'onair.currentItem' $name $($change.ActualActiveId)))
        }
        if ($change.OutputState) { $lines.Add((T 'onair.outputState' $($change.OutputState))) }
        if ($replaced) {
            $source = if ($change.ClientConnected -and -not [string]::IsNullOrWhiteSpace([string]$change.ClientIdentity)) { (T 'onair.cinegyClient' $($change.ClientIdentity)) } else { (T 'onair.unknownExternalSource') }
            $lines.Add((T 'onair.source' $source))
        }
        else {
            # Naming a "source" for a graphic that simply ran out sent an
            # operator looking for an intruder who was never there.
            $lines.Add((T 'onair.layerEmptyExplain'))
        }
    }
    $lines.Add((T 'onair.stateUpdated'))
    return ($lines -join "`n")
}

function Import-UserFavorites {
    if (-not (Test-Path -LiteralPath $script:userFavoritesFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:userFavoritesFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { $script:UserFavorites[$prop.Name] = @($prop.Value | ForEach-Object { [string]$_ }) }
    }
    catch { Write-BridgeLog "Could not read favorites.json: $($_.Exception.Message)" 'WARN' }
}

function Save-UserFavorites {
    try {
        return (Write-BridgeValidatedJson -Path $script:userFavoritesFile -Json ($script:UserFavorites | ConvertTo-Json -Depth 5))
    }
    catch { Write-BridgeLog "Could not write favorites.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Set-UserFavorite {
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$TemplateKey, [Parameter(Mandatory)][bool]$Enabled)
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($TemplateKey)) { return $false }
    $id = [string]$UserId
    # A typed list, because `$x = if (...) { @(...) } else { @() }` does not
    # survive: an if branch is a pipeline, a pipeline unrolls a zero- or
    # one-element array, and $x lands as $null or a bare String. The `+=` that
    # followed was then string concatenation, so a user's second favourite
    # turned @('a') into 'ab' - one key naming no template, which every reader
    # silently filtered out. Both favourites vanished from the menu and no
    # error was raised anywhere.
    $current = [System.Collections.Generic.List[string]]::new()
    if ($script:UserFavorites.ContainsKey($id)) {
        foreach ($existing in @($script:UserFavorites[$id])) { $current.Add([string]$existing) }
    }
    if ($Enabled) { if (-not $current.Contains($TemplateKey)) { $current.Add($TemplateKey) } }
    else { $current.RemoveAll({ param($k) $k -eq $TemplateKey }) | Out-Null }
    $script:UserFavorites[$id] = $current.ToArray()
    return Save-UserFavorites
}

function Import-UserAliases {
    if (-not (Test-Path -LiteralPath $script:userAliasesFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:userAliasesFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { $script:UserAliases[$prop.Name] = [string]$prop.Value }
    }
    catch { Write-BridgeLog "Could not read user-aliases.json: $($_.Exception.Message)" 'WARN' }
}

function Save-UserAliases {
    try {
        return (Write-BridgeValidatedJson -Path $script:userAliasesFile -Json ($script:UserAliases | ConvertTo-Json -Depth 3))
    }
    catch { Write-BridgeLog "Could not write user-aliases.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Set-UserAlias {
    param([Parameter(Mandatory)][long]$TargetUserId, [AllowEmptyString()][string]$Alias = '')
    if ($TargetUserId -le 0) { return $false }
    $id = [string]$TargetUserId; $clean = $Alias.Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { $script:UserAliases.Remove($id) }
    else { $script:UserAliases[$id] = $clean }
    return Save-UserAliases
}

function Get-TelegramActorName {
    <# The name Telegram already puts on every update, as one string.

       Extracted so the access-request screen and the name the audit log
       records are built by the same rule: they were two copies, and only one
       of them ran. #>
    param($From)
    if (-not $From) { return '' }
    $first = [string](Get-JsonProp $From 'first_name')
    $last = [string](Get-JsonProp $From 'last_name')
    $handle = [string](Get-JsonProp $From 'username')
    $name = (@($first, $last) | Where-Object { $_ }) -join ' '
    if ($handle) { $name = if ($name) { "$name (@$handle)" } else { "@$handle" } }
    return ([string]$name).Trim()
}

function Update-UserNameFromTelegram {
    <#
        Learn an operator's name from the update that just arrived.

        Measured on this station's own audit log: 7 of 8 users had no name,
        and 366 records - 244 air operations and 122 news publishes - named a
        raw id instead of a person. The audit log exists to answer "who", and
        it was answering with a number in 85% of the rows that had a human
        behind them.

        The cause was where the name came from: only an access request ever
        captured one, so anyone an administrator added directly, or who joined
        before that screen existed, stayed a number forever. Telegram sends
        the name with every message and every button press; the bridge threw
        it away each time.

        An administrator's own alias always wins - this only fills a blank -
        and the write happens once per person, when the blank is first filled.
    #>
    param($From, [long]$UserId, [long]$ChatId = 0)
    if ($UserId -le 0 -or -not $From) { return $false }
    # Only for people the bridge actually works for. This ran before any
    # authorization check on both call sites, so every stranger who found the
    # bot - and a bot's @username is public and searchable - had their name
    # stored and the WHOLE alias map re-serialised, with a .bak copy, on the
    # single poll thread that also drives the tick and the auto-hide timers.
    # That is O(n) of disk work per new stranger and O(n²) over a campaign,
    # for names belonging to nobody this bridge will ever name in an audit line.
    #
    # Nothing is lost by waiting: a stranger who matters becomes an access
    # request, and Request-Approval captures their name there through
    # Get-TelegramActorName, bounded by MaxPendingApprovals.
    $actorChat = if ($ChatId -ne 0) { $ChatId } else { $UserId }
    if (-not (Test-Authorized -ChatId $actorChat -UserId $UserId)) { return $false }
    $id = [string]$UserId
    if ($script:UserAliases.ContainsKey($id) -and -not [string]::IsNullOrWhiteSpace([string]$script:UserAliases[$id])) { return $false }
    $name = Get-TelegramActorName -From $From
    if ([string]::IsNullOrWhiteSpace($name) -or $name -eq $id) { return $false }
    # Long enough for a full Arabic name and a handle, short enough that one
    # pasted paragraph as a "last name" cannot stretch every audit line.
    if ($name.Length -gt 80) { $name = $name.Substring(0, 80).Trim() }
    Write-BridgeLog "Learned a display name for user $id from Telegram" 'DEBUG'
    return (Set-UserAlias -TargetUserId $UserId -Alias $name)
}

function Get-UserDisplayName {
    param([Parameter(Mandatory)][long]$UserId)
    $id = [string]$UserId
    if ($script:UserAliases.ContainsKey($id) -and -not [string]::IsNullOrWhiteSpace([string]$script:UserAliases[$id])) { return [string]$script:UserAliases[$id] }
    return $id
}

function Format-UserAuditActor {
    param([Parameter(Mandatory)][long]$UserId)
    $id = [string]$UserId
    $displayName = [string](Get-UserDisplayName -UserId $UserId)
    if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName -eq $id) { return $id }
    $cleanName = Protect-SensitiveText (($displayName -replace '[\r\n]+', ' ').Trim())
    if ([string]::IsNullOrWhiteSpace($cleanName)) { return $id }
    # A bare "(id)" after an Arabic name sits between an RTL run and digits,
    # so bidi resolves the brackets themselves as RTL and mirrors them: the
    # audit line for a hide read ")8201739556(". The marks pin the bracketed
    # id to LTR wherever the line lands - log file, 📜 screen, or audit.jsonl.
    $lrm = [char]0x200E
    return "$cleanName $lrm($id)$lrm"
}

function Get-UserFavoriteSelection {
    <# What the user actually ticked: every stored key that still names a live
       template, uncapped, with no usage-based guessing.

       Get-FavoriteTemplateKeys below answers a different question - what fits
       on the menu row - and using it to decide whether a checkbox is ticked
       made every pick past FavoritesCount unreachable. The key was in the
       store but truncated out of the answer, so the screen showed it
       unticked, the toggle read that as not-a-favourite and tried to add it
       again, and it could never be removed. Selection and display are two
       different lists and have to be read from two different functions. #>
    param([long]$UserId = 0)
    if ($UserId -le 0) { return @() }
    $id = [string]$UserId
    if (-not $script:UserFavorites.ContainsKey($id)) { return @() }
    $store = Get-TemplateStore
    return @($script:UserFavorites[$id] | Where-Object { $store.Map.ContainsKey($_) })
}

function Get-FavoriteTemplateKeys {
    param([long]$UserId = 0)
    $count = Get-SettingInt 'FavoritesCount' 0
    if ($count -le 0) { return @() }
    $store = Get-TemplateStore
    $id = [string]$UserId
    if ($UserId -gt 0 -and $script:UserFavorites.ContainsKey($id)) {
        return @((Get-UserFavoriteSelection -UserId $UserId) | Select-Object -First $count)
    }
    return @(
        $script:UsageCounts.GetEnumerator() |
        Where-Object { $store.Map.ContainsKey($_.Key) } |
        Sort-Object -Property Value -Descending |
        Select-Object -First $count |
        ForEach-Object { $_.Key }
    )
}


function Send-OwnGraphicLeftNotice {
    <#
        Tells whoever put a graphic on air that it is no longer there.

        Reported from the field, and it is the older of the two halves of that
        report: the operator pushed an urgent, it left the air, and nothing on
        their screen said so. The external-change alert existed the whole time
        and went to Send-AdminBroadcast - so the administrators were told, and
        the one person who was mid-task with that graphic was not.

        An operator who is also an administrator is skipped: they have just
        read the same event in the broadcast, and a bot that says a thing
        twice teaches people to read it once.
    #>
    param([Parameter(Mandatory)][object[]]$Changes)
    foreach ($change in @($Changes)) {
        if (-not $change) { continue }
        $userId = [long](Get-JsonProp $change 'ShowUserId')
        if ($userId -le 0) { continue }
        if (Test-Admin -ChatId $userId -UserId $userId) { continue }

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add((T 'onair.yoursLeft' $(ConvertTo-TelegramHtmlText -Text ([string]$change.TemplateKey)) $([int]$change.Layer)))
        $shownAt = Get-JsonProp $change 'ShownAt'
        if ($shownAt -is [datetime] -and $shownAt -gt [datetime]::MinValue) {
            $lines.Add((T 'onair.yoursLeftAfter' $(Format-DurationSeconds -Seconds ([int]((Get-Date) - $shownAt).TotalSeconds))))
        }
        if ([bool](Get-JsonProp $change 'Replaced')) {
            $name = if ([string]::IsNullOrWhiteSpace([string]$change.ActualActiveName)) { (T 'onair.unnamedItem') }
            else { ConvertTo-TelegramHtmlText -Text ([string]$change.ActualActiveName) }
            $lines.Add((T 'onair.yoursReplaced' $name))
        }
        else { $lines.Add((T 'onair.layerEmptyExplain')) }
        Send-TelegramMessage -ChatId $userId -Text ($lines -join "`n") -ParseMode HTML | Out-Null
        # Logged because "was he told?" was once asked of this log and it had
        # no answer: a failed send logs itself, a delivered one did not.
        Write-BridgeLog "Told user $userId that '$($change.TemplateKey)' left layer $([int]$change.Layer)"
    }
}

function Send-OutsideEndRoomNotice {
    <#
        Tells the room a graphic has left the air when the bridge did not
        take it down.

        The room heard it go up - the show notice reaches every chat its
        rule names - but the matching take-down notice was sent only from
        the bridge's own hide. An urgent that Cinegy ended after 24 seconds
        left eleven chats believing it was still on the screen. Same notice,
        same audience, same mute, with one line saying where it ended.

        Only for what the bridge put there (ShowUserId): the show notice was
        never sent for a discovered layer, so there is nothing to close.
    #>
    param([Parameter(Mandatory)][object[]]$Changes)
    foreach ($change in @($Changes)) {
        if (-not $change) { continue }
        $showUserId = [long](Get-JsonProp $change 'ShowUserId')
        if ($showUserId -le 0) { continue }
        $shownAt = Get-JsonProp $change 'ShownAt'
        $since = if ($shownAt -is [datetime]) { $shownAt } else { $null }
        Send-TemplateAirNotice -Key ([string]$change.TemplateKey) -Layer ([int]$change.Layer) `
            -ActorChatId $showUserId -Action hide -OnAirSince $since -EndedOutside | Out-Null
    }
}
