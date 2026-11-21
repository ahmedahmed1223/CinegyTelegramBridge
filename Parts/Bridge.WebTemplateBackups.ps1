#requires -Version 7

$script:WebTemplateBackupReviews = @{}

function Test-WebTemplateBackupPath {
    param([Parameter(Mandatory)][string]$Path)

    $entry = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($entry) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
        $entry = if ($entry -is [IO.FileInfo]) { $entry.Directory } else { $entry.Parent }
    }
    return $true
}

function Get-WebTemplateBackupId {
    param([string]$Registry, [string]$Name)
    $material = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject @($Registry, $Name)))
    return [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData($script:TemplatePresetRevisionKey, $material))
}

function Get-WebTemplateBackupLayout {
    param($Document, [switch]$ValidateCandidate)
    $layout = @{}
    foreach ($property in $Document.PSObject.Properties) {
        $key = $property.Name
        $definition = $property.Value
        $layer = 0
        $file = [string](Get-JsonProp $definition 'path')
        $device = [string](Get-JsonProp $definition 'device')
        if ($key -notmatch '^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$' -or
            $definition -isnot [System.Management.Automation.PSCustomObject] -or
            [IO.Path]::GetExtension($file) -ine '.cintitle' -or
            -not [int]::TryParse([string](Get-JsonProp $definition 'layer'), [ref]$layer) -or $layer -le 0 -or
            ($device -and $device -notmatch '^[A-Za-z0-9_]{1,32}$')) { throw 'Registry contains an invalid template definition.' }
        if ($ValidateCandidate) {
            if (-not [IO.Path]::IsPathRooted((Resolve-TemplateScenePath -Path $file))) {
                throw 'Registry contains an unresolved template path.'
            }
            foreach ($field in @(Get-JsonProp $definition 'fields' | Where-Object { $null -ne $_ })) {
                $fieldName = if ($field -is [string]) { $field } else { [string](Get-JsonProp $field 'name') }
                if ([string]::IsNullOrWhiteSpace($fieldName)) { throw 'Registry contains an unnamed template field.' }
            }
        }
        $layout[$key] = @{ Layer = $layer; Device = $device.ToLowerInvariant() }
    }
    return $layout
}

function Get-WebTemplateBackupBlocker {
    param($Current, $Candidate)

    $before = Get-WebTemplateBackupLayout -Document $Current
    $after = Get-WebTemplateBackupLayout -Document $Candidate -ValidateCandidate
    if ($after.Count -gt (Get-SettingInt 'TemplateRegistryImportMaxTemplates' 1)) { return 'template_backup_invalid' }
    $comparison = Get-TemplateRegistryImportComparison -Current $Current -Imported $Candidate
    $changed = @($comparison.Added) + @($comparison.Removed) + @($comparison.Changed)
    if (-not $changed.Count) { return 'template_backup_identical' }

    # Changing a layer's named-device declaration can retarget an unchanged
    # peer. Treat both versions of each affected layer and alias as in scope.
    $layers = [Collections.Generic.HashSet[int]]::new()
    $devices = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($definitionKey in $changed) {
        foreach ($layout in @($before, $after)) {
            $item = $layout[$definitionKey]
            if (-not $item) { continue }
            $null = $layers.Add([int]$item.Layer)
            $null = $devices.Add([string]$item.Layer)
            if ($item.Device) { $null = $devices.Add([string]$item.Device) }
        }
    }
    $affected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $changed) { $null = $affected.Add([string]$key) }
    do {
        $count = $layers.Count + $devices.Count
        foreach ($layout in @($before, $after)) {
            foreach ($item in $layout.GetEnumerator()) {
                if ($layers.Contains([int]$item.Value.Layer) -or $devices.Contains([string]$item.Value.Device) -or
                    $devices.Contains([string]$item.Value.Layer)) {
                    $null = $affected.Add([string]$item.Key)
                    $null = $layers.Add([int]$item.Value.Layer)
                    $null = $devices.Add([string]$item.Value.Layer)
                    if ($item.Value.Device) { $null = $devices.Add([string]$item.Value.Device) }
                }
            }
        }
    } while ($layers.Count + $devices.Count -gt $count)

    $testLayer = Get-SettingInt 'TemplateTestLayer' 0
    if ($testLayer -gt 0) {
        $testDevice = (Resolve-AirGfxDevice -Layer $testLayer).StatusPath -replace '^gfx_', ''
        if ($layers.Contains($testLayer) -or $devices.Contains($testDevice)) { return 'scene_definition_alias' }
    }
    foreach ($entry in $script:OnAir.GetEnumerator()) {
        $liveLayer = [int]$entry.Key
        $liveDevice = (Resolve-AirGfxDevice -Layer $liveLayer).StatusPath -replace '^gfx_', ''
        if ($layers.Contains($liveLayer) -or $devices.Contains($liveDevice)) { return 'scene_definition_live' }
    }
    $layerByDevice = @{}
    foreach ($group in @($after.Values | Group-Object Layer)) {
        $groupLayer = [int]$group.Name
        $declared = @($group.Group.Device | Where-Object { $_ } | Sort-Object -Unique)
        if ($declared.Count -gt 1 -and $layers.Contains($groupLayer)) { return 'scene_definition_alias' }
        $effective = if ($declared.Count) { [string]$declared[0] } else { $group.Name }
        if ($layerByDevice.ContainsKey($effective) -and
            ($layers.Contains($groupLayer) -or $layers.Contains($layerByDevice[$effective]))) { return 'scene_definition_alias' }
        $layerByDevice[$effective] = $groupLayer
    }
    foreach ($key in $affected) {
        $blocker = Get-TemplateDefinitionBlocker -TemplateKey $key -Delete
        if ($blocker) { return $blocker }
    }
    return ''
}

function Invoke-WebTemplateBackup {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-WebSceneCatalogueAccess -Actor $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $id = [string](Get-JsonProp $Arguments 'id')
    if ($action -cnotin 'list', 'preview', 'restore' -or ($action -cne 'list' -and $id -cnotmatch '^[A-F0-9]{64}$')) {
        return @{ ok = $false; error = 'template_backup_invalid' }
    }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $stale = @{ ok = $false; error = 'template_backup_stale' }
    $approved = if ($action -ceq 'restore') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTemplateBackupReviews
    }
    if ($action -ceq 'restore' -and -not $approved) { return $stale }

    try {
        $registry = [IO.Path]::GetFullPath((Get-TemplateRegistryFilePath))
        $directory = "$registry.backups"
        if ((Test-Path -LiteralPath $directory) -and -not (Test-WebTemplateBackupPath -Path $directory)) {
            return @{ ok = $false; error = 'template_backup_unavailable' }
        }
        $files = @(Get-TemplateBackupFiles -Path $registry | Where-Object {
            $_.Name -cmatch '^templates-[0-9]{8}-[0-9]{6}-[0-9]{3}-[a-f0-9]{8}\.json$' -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $_.Length -gt 0 -and $_.Length -le $script:TemplateRegistryImportMaximumBytes
        } | Select-Object -First 81)
        if ($action -ceq 'list') {
            return @{ ok = $true; data = @{
                backups = @(foreach ($file in ($files | Select-Object -First 80)) {
                    @{ id = Get-WebTemplateBackupId -Registry $registry -Name $file.Name; bytes = $file.Length
                        savedAt = ([datetimeoffset]$file.LastWriteTimeUtc).ToUnixTimeMilliseconds() }
                })
                truncated = $files.Count -gt 80
            } }
        }
        $selected = $files | Select-Object -First 80 | Where-Object {
            (Get-WebTemplateBackupId -Registry $registry -Name $_.Name) -ceq $id
        } | Select-Object -First 1
        if (-not $selected -or -not (Test-WebTemplateBackupPath -Path $selected.FullName) -or
            -not (Test-WebTemplateBackupPath -Path $registry)) { return $stale }
        $currentBytes = Read-TemplateRegistryBackupBytes -Path $registry
        $backupBytes = Read-TemplateRegistryBackupBytes -Path $selected.FullName
        $currentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($currentBytes))
        $backupHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($backupBytes))
        $fingerprint = ConvertTo-Json -InputObject @($id, $currentHash, $backupHash) -Compress
        if ($action -ceq 'restore' -and $approved.Fingerprint -cne $fingerprint) { return $stale }
        $current = ConvertFrom-TemplateRegistryBackupBytes -Bytes $currentBytes
        $candidate = ConvertFrom-TemplateRegistryBackupBytes -Bytes $backupBytes
        $blocker = Get-WebTemplateBackupBlocker -Current $current -Candidate $candidate
        if ($blocker) { return @{ ok = $false; error = $blocker } }
        if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }

        if ($action -ceq 'preview') {
            $comparison = Get-TemplateRegistryImportComparison -Current $current -Imported $candidate
            return @{ ok = $true; data = @{ preview = @{
                id = $id; added = @($comparison.Added); changed = @($comparison.Changed); removed = @($comparison.Removed)
                review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebTemplateBackupReviews
            } } }
        }
        $remaining = ($approved.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
        if ($remaining -le 0) { return $stale }
        $restoreDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
        if ($Deadline -gt 0) { $restoreDeadline = [math]::Min($Deadline, $restoreDeadline) }
        $restored = Restore-TemplateRegistryBackup -BackupPath $selected.FullName -Path $registry -ReviewedBytes $backupBytes `
            -ExpectedRegistryHash $currentHash -Deadline $restoreDeadline
        if (-not $restored.Success) {
            $code = [string](Get-JsonProp $restored 'Code')
            return @{ ok = $false; error = ($code ? $code : 'template_backup_unavailable') }
        }
        Add-AuditEntry (T 'cb.templateRestoreAudit' $(Format-UserAuditActor -UserId $actor))
        Publish-WebChannelState -Force
        return @{ ok = $true; data = @{ restored = $true } }
    }
    catch {
        return @{ ok = $false; error = 'template_backup_unavailable' }
    }
}
