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
        $persisted | ConvertTo-Json -Depth 4 | Set-Content -Path $usageFile -Encoding utf8 -ErrorAction Stop
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
        $script:OnAir[$layer] = @{ Key = [string]$scene.Key; At = $at; UserId = [long]$scene.UserId; ActiveId = [string]$scene.ActiveId; Source = [string]$scene.Source }
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
            ActiveId = [string](Get-JsonProp $Record 'ActiveId'); Source = if (Get-JsonProp $Record 'Source') { [string](Get-JsonProp $Record 'Source') } else { 'bridge' }
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
    foreach ($name in @('Key', 'At', 'UserId', 'ChatId', 'ActiveId', 'Source', 'TemplatePath', 'LastVerifiedAtUtc')) {
        $value = Get-JsonProp $Record $name
        if ($null -ne $value) {
            if ($name -eq 'At' -and $value -is [datetime]) { $value = $value.ToString('o') }
            $scene.$name = $value
        }
    }
    $script:OnAir[$Layer] = $Record
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
            [string]$primary.Key -eq [string](Get-JsonProp $record 'Key')
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

function Test-OnAirTemplateMatch {
    param(
        [string]$TemplateKey,
        [string]$ActiveName,
        [bool]$HasTrackedId = $false
    )
    if ([string]::IsNullOrWhiteSpace($ActiveName)) {
        return $HasTrackedId
    }
    if ([string]::IsNullOrWhiteSpace($TemplateKey)) { return $false }

    $cleanActive = $ActiveName.Trim()
    $cleanKey = $TemplateKey.Trim()

    if ($cleanActive -ieq $cleanKey -or
        $cleanActive -like "*$cleanKey*" -or
        $cleanKey -like "*$cleanActive*") {
        return $true
    }

    $store = Get-TemplateStore
    $tpl = Get-JsonProp $store.Map $TemplateKey

    if ($tpl) {
        $tplPath = [string](Get-JsonProp $tpl 'path')
        if (-not [string]::IsNullOrWhiteSpace($tplPath)) {
            $fileName = [System.IO.Path]::GetFileName($tplPath)
            $fileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($tplPath)
            if ($cleanActive -ieq $fileName -or
                $cleanActive -ieq $fileNameNoExt -or
                $cleanActive -like "*$fileNameNoExt*" -or
                $fileNameNoExt -like "*$cleanActive*") {
                return $true
            }
        }
    }
    return $false
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
            $recordSource = [string](Get-JsonProp $record 'Source')
            if ([string]::IsNullOrWhiteSpace($recordSource)) { $recordSource = 'bridge' }
            Write-BridgeLog "Cinegy state sync ($Reason) removed on-air record for layer $layer after Cinegy confirmed hidden; template '$([string](Get-JsonProp $record 'Key'))', source $recordSource, user $([long](Get-JsonProp $record 'UserId'))" "INFO"
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
        return [pscustomobject]@{ State = 'unavailable'; Label = '🔴 غير متاح'; AgeSeconds = $null }
    }
    if ($null -eq $LastSuccessfulAt -or [string]::IsNullOrWhiteSpace([string]$LastSuccessfulAt)) {
        return [pscustomobject]@{ State = 'unknown'; Label = '⚪ غير معروف'; AgeSeconds = $null }
    }
    $ageSeconds = [math]::Max(0, [math]::Floor(($Now - ([datetime]$LastSuccessfulAt)).TotalSeconds))
    if ($ageSeconds -gt [math]::Max(1, $StaleAfterSeconds)) {
        # Seconds are the right unit for "45 seconds behind" and a useless one
        # for "372741 ثانية", which is four days nobody will divide out while
        # glancing at a status screen.
        return [pscustomobject]@{ State = 'stale'; Label = "🟠 متأخر منذ $(Format-DurationSeconds -Seconds $ageSeconds)"; AgeSeconds = $ageSeconds }
    }
    return [pscustomobject]@{ State = 'connected'; Label = '🟢 متصل'; AgeSeconds = $ageSeconds }
}

function Format-ExternalCinegyChangeAlert {
    param([Parameter(Mandatory)][object[]]$Changes)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('⚠️ تغيير خارجي في Cinegy')
    $lines.Add("خادم Air: $($config.AirServerAddress) | القناة: $($config.AirChannelNumber)")
    foreach ($change in @($Changes)) {
        $replaced = -not [string]::IsNullOrWhiteSpace([string]$change.ActualActiveId)
        $state = if ($replaced) { 'استُبدل خارجيًا' } else { 'أُخفي' }
        $lines.Add('')
        $lines.Add("$(Get-LayerDisplayName -Layer ([int]$change.Layer)): $state")
        $lines.Add("القالب الذي كان يعرضه البوت: $($change.TemplateKey)")
        $lines.Add("المشغّل: $($change.ShowUserId) | بدأ: $($change.ShownAt)")
        $lines.Add("المعرّف السابق: $($change.ExpectedActiveId)")
        if ($replaced) {
            $name = if ([string]::IsNullOrWhiteSpace([string]$change.ActualActiveName)) { 'عنصر غير مسمّى' } else { $change.ActualActiveName }
            $lines.Add("العنصر الحالي: $name | المعرّف: $($change.ActualActiveId)")
        }
        if ($change.OutputState) { $lines.Add("حالة الخرج: $($change.OutputState)") }
        $source = if ($change.ClientConnected -and -not [string]::IsNullOrWhiteSpace([string]$change.ClientIdentity)) { "عميل Cinegy: $($change.ClientIdentity)" } else { 'مصدر خارجي غير معرّف' }
        $lines.Add("المصدر: $source")
    }
    $lines.Add('تم تحديث حالة البوت وإلغاء أي مؤقت مرتبط.')
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
        $temporary = "$($script:userFavoritesFile).tmp"
        $script:UserFavorites | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:userFavoritesFile -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write favorites.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Set-UserFavorite {
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$TemplateKey, [Parameter(Mandatory)][bool]$Enabled)
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($TemplateKey)) { return $false }
    $id = [string]$UserId
    $current = if ($script:UserFavorites.ContainsKey($id)) { @($script:UserFavorites[$id]) } else { @() }
    if ($Enabled) { if ($current -notcontains $TemplateKey) { $current += $TemplateKey } }
    else { $current = @($current | Where-Object { $_ -ne $TemplateKey }) }
    $script:UserFavorites[$id] = $current
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
        $temporary = "$($script:userAliasesFile).tmp"
        $script:UserAliases | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:userAliasesFile -Force -ErrorAction Stop
        return $true
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
    return "$cleanName ($id)"
}

function Get-FavoriteTemplateKeys {
    param([long]$UserId = 0)
    $count = Get-SettingInt 'FavoritesCount' 0
    if ($count -le 0) { return @() }
    $store = Get-TemplateStore
    $id = [string]$UserId
    if ($UserId -gt 0 -and $script:UserFavorites.ContainsKey($id)) {
        return @($script:UserFavorites[$id] | Where-Object { $store.Map.ContainsKey($_) } | Select-Object -First $count)
    }
    return @(
        $script:UsageCounts.GetEnumerator() |
        Where-Object { $store.Map.ContainsKey($_.Key) } |
        Sort-Object -Property Value -Descending |
        Select-Object -First $count |
        ForEach-Object { $_.Key }
    )
}

