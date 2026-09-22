#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-TemplateRegistryFilePath {
    $configured = [string]$config.TemplateRegistryPath
    if ([System.IO.Path]::IsPathRooted($configured)) { return $configured }
    return (Join-Path $scriptRoot $configured)
}

function Backup-TemplateRegistryFile {
    <#
        One timestamped copy of templates.json before it is rewritten, and
        the pruning that keeps the folder from growing forever.

        Four writers took this backup with four copies of the same six lines,
        and only ONE of them pruned - so a station that edited template
        definitions, reminder minutes or imported a registry filled
        templates.json.backups without limit, and the only thing that ever
        noticed was the storage warning in the health screen, which offered
        nothing to do about it. Pruning in one place is why this is a
        function rather than a fifth copy.

        Returns the backup path, or '' when there was no file to copy - a
        first write has nothing to preserve and must not fail over it.
    #>
    param([string]$Path = (Get-TemplateRegistryFilePath))
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $backupDirectory = "$Path.backups"
    New-Item -ItemType Directory -Path $backupDirectory -Force -ErrorAction Stop | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupPath = Join-Path $backupDirectory "templates-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop
    # Shares ConfigBackupKeepFiles rather than adding a setting of its own:
    # both answer the same operator question - how many undo steps this
    # bridge keeps - and a second number would only ever be set wrong.
    $keep = Get-SettingInt 'ConfigBackupKeepFiles' 1
    if ($keep -gt 0) {
        foreach ($old in @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc, Name -Descending | Select-Object -Skip $keep)) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    return $backupPath
}

function Get-TemplateBackupFiles {
    <# The saved registries, newest first. One reader for the list, the
       keyboard and the restore, so the row pressed is the file read - the
       same rule Get-ConfigBackupFiles states next door. #>
    param([string]$Path = (Get-TemplateRegistryFilePath))
    $backupDirectory = "$Path.backups"
    if (-not (Test-Path -LiteralPath $backupDirectory)) { return @() }
    return @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc, Name -Descending)
}

function Save-TemplatePresetChange {
    <# Mutates only the presets array of one template. A timestamped backup is
       taken first and the final JSON replaces the original atomically. #>
    param(
        [Parameter(Mandatory)][string]$TemplateKey,
        [Parameter(Mandatory)][ValidateSet('create', 'rename', 'edit', 'delete')][string]$Action,
        [int]$PresetIndex = -1,
        [string]$Name = '',
        [object[]]$Values = @()
    )
    $path = Get-TemplateRegistryFilePath
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $template = Get-JsonProp $raw $TemplateKey
        if (-not $template) { throw "Template '$TemplateKey' was not found." }
        $presets = @(Get-JsonProp $template 'presets' | Where-Object { $null -ne $_ })

        if ($Action -eq 'create') {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Preset name is empty.' }
            if (@($presets | Where-Object { [string](Get-JsonProp $_ 'name') -eq $Name }).Count -gt 0) {
                throw "Preset '$Name' already exists."
            }
            $presets += [pscustomobject]@{ name = $Name.Trim(); values = @($Values | ForEach-Object { [string]$_ }) }
        }
        else {
            if ($PresetIndex -lt 0 -or $PresetIndex -ge $presets.Count) { throw 'Preset index is no longer valid.' }
            switch ($Action) {
                'rename' {
                    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Preset name is empty.' }
                    $presets[$PresetIndex] | Add-Member -NotePropertyName name -NotePropertyValue $Name.Trim() -Force
                }
                'edit' {
                    $presets[$PresetIndex] | Add-Member -NotePropertyName values -NotePropertyValue @($Values | ForEach-Object { [string]$_ }) -Force
                }
                'delete' {
                    $presets = @($presets | Where-Object { $_ -ne $presets[$PresetIndex] })
                }
            }
        }
        $template | Add-Member -NotePropertyName presets -NotePropertyValue @($presets) -Force

        $backupPath = Backup-TemplateRegistryFile -Path $path


        $temporary = "$path.tmp"
        $raw | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        $script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }
        return [pscustomobject]@{ Success = $true; Error = ''; BackupPath = $backupPath }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; BackupPath = '' }
    }
}

function Restore-TemplateRegistryBackup {
    <#
        Puts a saved templates.json back, refusing the cases that would take
        a graphic off air or break a booked event.

        Every writer here has kept a timestamped copy since the registry
        screens were built, and there was no way to get one back: the copies
        accumulated and an administrator who deleted the wrong template had
        to find the folder on the server. The config screens have had exactly
        this for releases (Restore-ConfigBackup), and this mirrors it
        deliberately rather than inventing a second shape.

        The two refusals are the ones Set-ImportedTemplateRegistry already
        makes, for the same reason: restoring a registry from before a
        template existed REMOVES that template, and a removed template that
        is on air right now leaves a graphic on screen the bridge can no
        longer name or hide by key.
    #>
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [string]$Path = (Get-TemplateRegistryFilePath)
    )
    $restoreTemporary = "$Path.restore.tmp"
    try {
        if (-not (Test-Path -LiteralPath $BackupPath)) { throw (T 'tpl.backupFileMissing') }
        $candidate = Get-Content -LiteralPath $BackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $candidate -or @($candidate.PSObject.Properties.Name).Count -eq 0) {
            throw (T 'tpl.backupEmpty')
        }
        $current = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $comparison = Get-TemplateRegistryImportComparison -Current $current -Imported $candidate
        $unsafeKeys = @(@($comparison.Removed) + @($comparison.Changed) | Sort-Object -Unique)
        $liveKeys = @($script:OnAir.Values | ForEach-Object { [string](Get-JsonProp $_ 'Key') })
        $scheduledKeys = @(Get-UpcomingScheduleEvents | ForEach-Object { [string](Get-JsonProp $_ 'TemplateKey') })
        $blocked = @($unsafeKeys | Where-Object { $liveKeys -contains $_ -or $scheduledKeys -contains $_ })
        if ($blocked.Count -gt 0) {
            throw "لا يمكن تغيير أو حذف قالب على الهواء أو في جدولة قادمة: $($blocked -join (T 'common.comma'))"
        }
        # The registry as it stands becomes a backup of its own first, so the
        # restore itself is undoable. A one-way undo is a trap.
        Backup-TemplateRegistryFile -Path $Path | Out-Null
        Copy-Item -LiteralPath $BackupPath -Destination $restoreTemporary -Force -ErrorAction Stop
        Move-Item -LiteralPath $restoreTemporary -Destination $Path -Force -ErrorAction Stop
        $script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }
        return [pscustomobject]@{ Success = $true; Error = ''; Comparison = $comparison }
    }
    catch {
        Remove-Item -LiteralPath $restoreTemporary -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Success = $false; Error = Protect-SensitiveText $_.Exception.Message; Comparison = $null }
    }
}

function Get-TemplateStore {
    <# Returns @{ Map; Order; Errors }. Cached on the file's LastWriteTimeUtc,
       so editing templates.json takes effect immediately without a restart,
       but a single button press no longer re-parses the file a dozen times.
       Order is sorted by the optional "order" field then by key, so button
       positions stay stable between renders (hashtable order is not). #>
    $path = Get-TemplateRegistryFilePath
    if (-not (Test-Path $path)) {
        return @{ Map = @{}; Order = @(); Errors = @("ملف القوالب غير موجود: $path"); InvalidKeys = @(); SharedLayers = @{} }
    }
    return Get-TemplateStoreParsed -Path $path
}

function Resolve-TemplateScenePath {
    <#
        Turns whatever an operator wrote into a path Cinegy can open.

        Every ordinary Windows form is accepted: a drive path, a mapped drive,
        a UNC share such as \\nas01\scenes\Lower3rd.cintitle - those already
        worked - plus %PROGRAMDATA%-style environment variables, which did
        not, because the check ran before expansion and a path starting with
        '%' is not rooted.

        A bare name or a relative path resolves against TemplateBasePath, so a
        station with one scenes folder can write "Lower3rd.cintitle" and stop
        repeating the same prefix in every entry. With that setting empty the
        old rule stands: relative paths are refused rather than guessed at
        from the bridge's working directory, which a service and a console
        do not agree on.
    #>
    param([string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }

    $resolved = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([IO.Path]::IsPathRooted($resolved)) { return $resolved }

    $base = [Environment]::ExpandEnvironmentVariables([string](Get-Setting 'TemplateBasePath')).Trim()
    if ([string]::IsNullOrWhiteSpace($base) -or -not [IO.Path]::IsPathRooted($base)) { return $resolved }
    return [IO.Path]::Combine($base, $resolved)
}

function Get-TemplateStoreParsed {
    <# The parse and cache half of Get-TemplateStore, split out only so the
       path resolver above could sit between them as its own function. #>
    param([Parameter(Mandatory)][string]$Path)
    $path = $Path
    $writeTime = (Get-Item $path).LastWriteTimeUtc
    if ($script:TemplateCache.Path -eq $path -and $script:TemplateCache.WriteTime -eq $writeTime) {
        return $script:TemplateCache
    }

    $map = @{}
    $errors = [System.Collections.Generic.List[string]]::new()
    $invalidKeys = [System.Collections.Generic.List[string]]::new()
    $layerTemplates = @{}
    try {
        $raw = Get-Content -Path $path -Raw | ConvertFrom-Json
    }
    catch {
        # Cache the failure too, keyed on the same write time: otherwise a
        # malformed templates.json is re-parsed and re-logged on every single
        # call - dozens of times per button press.
        $script:TemplateCache = @{
            WriteTime = $writeTime; Path = $path; Map = @{}; Order = @()
            Errors    = @("تعذّر قراءة templates.json: $($_.Exception.Message)")
            InvalidKeys = @(); SharedLayers = @{}
        }
        Write-BridgeLog "Template registry unreadable: $($_.Exception.Message)" "ERROR"
        return $script:TemplateCache
    }

    foreach ($prop in $raw.PSObject.Properties) {
        $key = $prop.Name
        $entry = $prop.Value
        $tplPath = Get-JsonProp $entry 'path'
        $layerRaw = Get-JsonProp $entry 'layer'
        $layer = 0
        if ([string]::IsNullOrWhiteSpace([string]$tplPath)) {
            $errors.Add("القالب '$key' بلا حقل path - تم تخطيه.")
            $invalidKeys.Add($key)
            continue
        }
        $tplPath = Resolve-TemplateScenePath -Path ([string]$tplPath)
        if (-not [IO.Path]::IsPathRooted([string]$tplPath)) {
            $errors.Add("القالب '$key(T 'tpl.pathNotAbsolute')$tplPath' - اضبط TemplateBasePath أو اكتب مسارًا كاملًا.")
            $invalidKeys.Add($key)
            continue
        }
        if (-not [IO.Path]::GetExtension([string]$tplPath).Equals('.cintitle', [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("القالب '$key' يجب أن يشير إلى ملف .cintitle - تم تخطيه.")
            $invalidKeys.Add($key)
            continue
        }
        if (-not [int]::TryParse([string]$layerRaw, [ref]$layer)) {
            $errors.Add("القالب '$key' بلا حقل layer صالح - تم تخطيه.")
            $invalidKeys.Add($key)
            continue
        }
        $order = 1000
        $parsedOrder = 0
        if ([int]::TryParse([string](Get-JsonProp $entry 'order'), [ref]$parsedOrder)) { $order = $parsedOrder }

        $presets = @()
        foreach ($p in @(Get-JsonProp $entry 'presets')) {
            if (-not $p) { continue }
            $presets += , @{
                Name   = [string](Get-JsonProp $p 'name')
                Values = @(Get-JsonProp $p 'values' | Where-Object { $null -ne $_ })
            }
        }

        # A "fields" entry may be either a plain variable name, or an object
        # { "name": "Ajel.center", "label": "نص العاجل" } so operators are
        # prompted with something human instead of a scene variable name.
        # The Where-Object is load-bearing: an absent "fields" key makes
        # Get-JsonProp emit a single $null, and a bare @() around that yields a
        # one-element array holding $null - i.e. a phantom field the operator
        # would be prompted to fill in.
        # Optional per-template default, e.g. a ticker that tolerates more text
        # than a lower-third. 0 means "use the global MaxFieldLength setting".
        $templateLimit = 0
        $parsedLimit = 0
        if ([int]::TryParse([string](Get-JsonProp $entry 'maxLength'), [ref]$parsedLimit) -and $parsedLimit -gt 0) {
            $templateLimit = $parsedLimit
        }

        $fieldNames = @()
        $fieldLabels = @()
        $fieldLimits = @()
        $fieldRequired = @()
        $fieldSensitive = @()
        # Name -> Cinegy variable type override (Text|String|Bool|Float).
        # Empty means "use the AirVariableType setting".
        $fieldTypes = @{}
        foreach ($f in @(Get-JsonProp $entry 'fields' | Where-Object { $null -ne $_ })) {
            if ($f -is [string]) {
                $fieldNames += $f
                $fieldLabels += ''
                $fieldLimits += $templateLimit
                $fieldRequired += $false
                $fieldSensitive += $false
            }
            else {
                $fname = [string](Get-JsonProp $f 'name')
                if ([string]::IsNullOrWhiteSpace($fname)) {
                    $errors.Add("القالب '$key' فيه حقل بلا اسم - تم تخطيه.")
                    continue
                }
                $fieldNames += $fname
                $fieldLabels += [string](Get-JsonProp $f 'label')
                $fieldRequired += ((Get-JsonProp $f 'required') -eq $true)
                $fieldSensitive += ((Get-JsonProp $f 'sensitive') -eq $true)
                $fieldTypes[$fname] = [string](Get-JsonProp $f 'type')
                # Per-field limit wins over the template default, which wins
                # over the global setting.
                $fieldLimit = $templateLimit
                $parsedField = 0
                if ([int]::TryParse([string](Get-JsonProp $f 'maxLength'), [ref]$parsedField) -and $parsedField -gt 0) {
                    $fieldLimit = $parsedField
                }
                $fieldLimits += $fieldLimit
            }
        }

        # Optional: names the Cinegy device carrying this template, for layers
        # Air Pro does not address by number - the logo is one. The numeric
        # layer is still what the bridge keys its own bookkeeping on, so it
        # must stay unique even when a device name is given.
        $deviceName = [string](Get-JsonProp $entry 'device')
        if ($deviceName -and $deviceName -notmatch '^[A-Za-z0-9_]{1,32}$') {
            $errors.Add("القالب '$key(T 'tpl.badDeviceName')$deviceName' - تم تجاهل الاسم.")
            $deviceName = ''
        }

        $reminderMinutes = 0
        $parsedReminderMinutes = 0
        $rawReminderMinutes = [string](Get-JsonProp $entry 'reminderMinutes')
        if (-not [string]::IsNullOrWhiteSpace($rawReminderMinutes)) {
            if (-not [int]::TryParse($rawReminderMinutes, [ref]$parsedReminderMinutes) -or $parsedReminderMinutes -lt 0 -or $parsedReminderMinutes -gt 1440) {
                $errors.Add("القالب '$key' فيه reminderMinutes غير صالح؛ استخدم 0 إلى 1440 دقيقة.")
            }
            else { $reminderMinutes = $parsedReminderMinutes }
        }

        $map[$key] = @{
            Key         = $key
            Path        = [string]$tplPath
            Layer       = $layer
            Device      = $deviceName
            # A ticker or a logo lives on air all day by design. Marked here,
            # it is exempt from the "on air suspiciously long" alert.
            LongRunning = [bool](Get-JsonProp $entry 'longRunning')
            # 0 disables the personal elapsed-time reminder for this template.
            ReminderMinutes = $reminderMinutes
            Fields      = $fieldNames
            FieldLabels = $fieldLabels
            FieldLimits = $fieldLimits
            FieldRequired = $fieldRequired
            FieldSensitive = $fieldSensitive
            FieldTypes  = $fieldTypes
            MaxLength   = $templateLimit
            Description = [string](Get-JsonProp $entry 'description')
            Category    = [string](Get-JsonProp $entry 'category')
            Order       = $order
            Presets     = $presets
        }
        $layerKey = [string]$layer
        if (-not $layerTemplates.ContainsKey($layerKey)) { $layerTemplates[$layerKey] = @() }
        $layerTemplates[$layerKey] = @($layerTemplates[$layerKey]) + $key
    }

    # Script-block sort expressions: -Property 'Name' resolves ambiguously
    # against a [hashtable]'s own members, so address the entries explicitly.
    $ordered = @($map.Values | Sort-Object -Property @{ Expression = { $_.Order } }, @{ Expression = { $_.Key } } | ForEach-Object { $_.Key })
    $sharedLayers = @{}
    foreach ($layerKey in $layerTemplates.Keys) {
        if (@($layerTemplates[$layerKey]).Count -gt 1) { $sharedLayers[$layerKey] = @($layerTemplates[$layerKey] | Sort-Object) }
    }

    $script:TemplateCache = @{
        WriteTime = $writeTime
        Path      = $path
        Map       = $map
        Order     = $ordered
        Errors    = @($errors)
        InvalidKeys = $invalidKeys.ToArray()
        SharedLayers = $sharedLayers
    }
    # Tell the Cinegy module which layers are named, so every existing call
    # site can keep passing a plain layer number.
    $deviceMap = @{}
    foreach ($templateKey in $map.Keys) {
        $deviceName = [string]$map[$templateKey].Device
        if (-not [string]::IsNullOrWhiteSpace($deviceName)) { $deviceMap[[int]$map[$templateKey].Layer] = $deviceName }
    }
    Set-AirLayerDeviceMap -Map $deviceMap

    foreach ($e in $errors) { Write-BridgeLog "Template registry: $e" "WARN" }
    return $script:TemplateCache
}

function Get-InvalidTemplateEntries {
    <#
        D2: the registry entries skipped at every load, paired with why.
        Reasons come from the store's own error lines, matched on the quoted
        key they all carry - so the screen explains rather than repeats the
        log's eternal "skipped" warning, and each row offers its deletion.
    #>
    $store = Get-TemplateStore
    $entries = @()
    # Get-JsonProp, not direct access: mocked stores in tests carry only the
    # keys their test cares about, and StrictMode turns a missing InvalidKeys
    # into a failed catalogue render.
    foreach ($key in @(Get-JsonProp $store 'InvalidKeys' | Where-Object { $null -ne $_ })) {
        $name = [string]$key
        $reason = @(Get-JsonProp $store 'Errors' | Where-Object { [string]$_ -match "'$([regex]::Escape($name))'" } | Select-Object -First 1)
        if (-not $reason) { $reason = (T 'tpl.invalid') }
        $entries += [pscustomobject]@{ Key = $name; Reason = [string]$reason }
    }
    return $entries
}

function Get-TemplateLastAirMap {
    <#
        P3: when each template last went on air, from the permanent audit
        trail (not the 20-per-user in-memory history, which forgets by
        design). Reads only the tail: the catalogue renders on tap, and a
        full-file scan on every tap would tax the playout disk for a list
        nobody scrolls past the recent entries of anyway.
    #>
    param([int]$TailLines = 2000)
    $map = @{}
    if (-not (Test-Path -LiteralPath $script:auditFile)) { return $map }
    try {
        $lines = @(Get-Content -LiteralPath $script:auditFile -Tail $TailLines -ErrorAction Stop)
    }
    catch { return $map }
    foreach ($line in $lines) {
        if ($line -notmatch '"action":"SHOW"') { continue }
        if ($line -notmatch '"result":"success"') { continue }
        $target = ''
        $at = ''
        if ($line -match '"target":"([^"]*)"') { $target = $Matches[1] }
        if ($line -match '"timestampUtc":"([^"]*)"') { $at = $Matches[1] }
        if ([string]::IsNullOrWhiteSpace($target) -or [string]::IsNullOrWhiteSpace($at)) { continue }
        try { $stamp = [datetime]$at } catch { continue }
        if (-not $map.ContainsKey($target) -or $stamp -gt $map[$target]) { $map[$target] = $stamp }
    }
    return $map
}

function Format-TemplateLastAir {
    param($Stamp)
    if (-not $Stamp) { return (T 'tpl.neverAired') }
    try { $at = [datetime]$Stamp } catch { return (T 'tpl.neverAired') }
    # UTC on both sides: tick subtraction across DateTime Kinds does not
    # convert, and a Local-minus-Utc age would gain the whole timezone.
    $age = (Get-Date).ToUniversalTime() - $at.ToUniversalTime()
    if ($age.TotalMinutes -lt 60) { return "قبل $([math]::Max(1, [int]$age.TotalMinutes)) د" }
    if ($age.TotalHours -lt 24) { return "قبل $([int]$age.TotalHours) س" }
    if ($age.TotalDays -lt 7) { return "قبل $(Get-ArabicCountNoun -Count ([int]$age.TotalDays) -One 'يوم' -Two 'يومان' -Few 'أيام' -Many 'يومًا' -EnglishOne 'day' -EnglishMany 'days')" }
    return $at.ToLocalTime().ToString('yyyy-MM-dd')
}

function Get-TemplateByIndex {
    param([Parameter(Mandatory)][int]$Index)
    $store = Get-TemplateStore
    if ($Index -lt 0 -or $Index -ge $store.Order.Count) { return $null }
    return $store.Map[$store.Order[$Index]]
}

function Get-TemplatePreset {
    <#
        One saved text set of a template, or $null when the index names none.

        Five callers indexed $template.Presets after checking the UPPER bound
        only, and PowerShell reads a negative index from the END of the array:
        Presets[-1] is the last preset, so an out-of-range index did not fail,
        it quietly selected the wrong entry - the wrong text on air for
        'preset:', and the wrong preset deleted for 'pad:'. Two other callers
        (Start-PresetAdminEditValues, Save-TemplatePresetChange) did check
        both bounds, which is how a guard drifts: written twice, remembered
        once.

        Nothing reachable sends a negative index today - the bridge builds
        every one of those buttons itself from a loop over the presets - so
        this is the bound that was missing rather than a hole that was open.
        It is here, once, so the two halves cannot disagree again.
    #>
    param($Template, [int]$Index)
    if (-not $Template) { return $null }
    $presets = @($Template.Presets)
    if ($Index -lt 0 -or $Index -ge $presets.Count) { return $null }
    return $presets[$Index]
}

function Get-TemplateIndex {
    param([Parameter(Mandatory)][string]$Key)
    $store = Get-TemplateStore
    return [array]::IndexOf($store.Order, $Key)
}

function Get-TemplateTestLayerConflict {
    <# Names the registered templates that already live on a candidate test
       layer, or $null when the layer is free.

       TemplateTestLayer exists so a template can be pushed somewhere harmless
       before it is trusted on air. Pointing it at a layer a real template
       already uses defeats that entirely: the "test" goes out on the same
       layer as programme graphics, which is the exact accident the setting was
       added to avoid. 0 disables testing and never conflicts.

       Always returns an array, never $null: a caller writing @(...) around a
       $null return gets a one-element array holding $null, whose .Count is 1,
       so "no conflict" would read as "conflict" and block every free layer. #>
    param([Parameter(Mandatory)][int]$Layer)
    if ($Layer -le 0) { return @() }
    $store = Get-TemplateStore
    return @($store.Map.Keys | Where-Object { [int]$store.Map[$_].Layer -eq $Layer } | Sort-Object)
}

function Get-KnownLayers {
    $store = Get-TemplateStore
    $layers = @($store.Map.Values | ForEach-Object { $_.Layer } | Sort-Object -Unique)
    if ($layers.Count -eq 0) { $layers = 1..8 }
    return $layers
}

function Save-TemplateDefinitionChange {
    param(
        [Parameter(Mandatory)][string]$TemplateKey,
        [Parameter(Mandatory)][ValidateSet('edit', 'create', 'delete')][string]$Action,
        [hashtable]$Definition = @{}
    )
    $path = Get-TemplateRegistryFilePath
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $existing = Get-JsonProp $raw $TemplateKey
        if ($Action -eq 'create' -and $existing) { throw "يوجد قالب بالمفتاح '$TemplateKey' بالفعل." }
        if ($Action -ne 'create' -and -not $existing) { throw "القالب '$TemplateKey' غير موجود." }
        if ($Action -eq 'delete') {
            if (@($script:OnAir.Values | Where-Object { [string](Get-JsonProp $_ 'Key') -eq $TemplateKey }).Count -gt 0) { throw (T 'tpl.cannotDeleteOnAir') }
            if (@(Get-UpcomingScheduleEvents | Where-Object { [string](Get-JsonProp $_ 'TemplateKey') -eq $TemplateKey }).Count -gt 0) { throw (T 'tpl.cannotDeleteScheduled') }
            $raw.PSObject.Properties.Remove($TemplateKey)
        }
        else {
            $templatePath = [string](Get-JsonProp $Definition 'path')
            $layer = 0
            if ([string]::IsNullOrWhiteSpace($templatePath)) { throw (T 'tpl.pathEmpty') }
            if (-not [int]::TryParse([string](Get-JsonProp $Definition 'layer'), [ref]$layer) -or $layer -le 0) { throw (T 'tpl.layerPositive') }
            $root = [IO.Path]::GetFullPath($scriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $resolved = [IO.Path]::GetFullPath((Join-Path $scriptRoot $templatePath))
            if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw (T 'tpl.pathInsideProject') }
            $fields = @(Get-JsonProp $Definition 'fields')
            foreach ($field in $fields) {
                $fieldName = if ($field -is [string]) { $field } else { [string](Get-JsonProp $field 'name') }
                if ([string]::IsNullOrWhiteSpace([string]$fieldName)) { throw (T 'tpl.fieldNoName') }
            }
            if ($Action -eq 'create') { $target = [pscustomobject]@{}; $raw | Add-Member -NotePropertyName $TemplateKey -NotePropertyValue $target }
            else { $target = $existing }
            foreach ($name in @('path', 'layer', 'order', 'description', 'category', 'fields', 'reminderMinutes')) {
                if ($Definition.ContainsKey($name)) { $target | Add-Member -NotePropertyName $name -NotePropertyValue $Definition[$name] -Force }
            }
        }
        $backupPath = Backup-TemplateRegistryFile -Path $path

        $temporary = "$path.tmp"
        $raw | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        $script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }
        return [pscustomobject]@{ Success = $true; Error = ''; BackupPath = $backupPath }
    }
    catch { return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; BackupPath = '' } }
}

function Save-TemplateReminderMinutes {
    <# Updates only the per-template elapsed-time reminder setting. The
       registry backup and atomic replacement follow the existing template
       mutation contract so one button cannot leave a partial JSON file. #>
    param([Parameter(Mandatory)][string]$TemplateKey, [Parameter(Mandatory)][int]$Minutes)
    if ($Minutes -lt 0 -or $Minutes -gt 1440) {
        return [pscustomobject]@{ Success = $false; Error = (T 'tpl.durationRange'); BackupPath = '' }
    }
    $path = Get-TemplateRegistryFilePath
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $template = Get-JsonProp $raw $TemplateKey
        if (-not $template) { throw "القالب '$TemplateKey' غير موجود." }
        $backupPath = Backup-TemplateRegistryFile -Path $path

        $template | Add-Member -NotePropertyName reminderMinutes -NotePropertyValue $Minutes -Force
        $temporary = "$path.tmp"
        $raw | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        $script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }
        return [pscustomobject]@{ Success = $true; Error = ''; BackupPath = $backupPath }
    }
    catch { return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; BackupPath = '' } }
}

function Get-HideAllTargetLayers {
    <# "all" preserves the established default. An empty or invalid selection
       deliberately hides nothing, so a bad configuration cannot widen scope. #>
    $known = @((Get-KnownLayers | ForEach-Object { [int]$_ }) | Sort-Object -Unique)
    $raw = [string](Get-Setting 'HideAllLayers')
    if ($raw.Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) { return $known }

    $selected = @()
    foreach ($part in ($raw -split '[,;\s]+')) {
        $layer = 0
        if ([int]::TryParse($part.Trim(), [ref]$layer) -and $known -contains $layer) { $selected += $layer }
    }
    return @($selected | Sort-Object -Unique)
}

function Get-CinegyLayerDashboard {
    <# Takes one read-only snapshot of every GFX layer referenced by the
       configured templates. Each returned status carries its Layer number so
       the same sample can be formatted and reused for reconciliation. #>
    foreach ($layer in (Get-KnownLayers)) {
        $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
            -AirChannelNumber $config.AirChannelNumber -Layer ([int]$layer) `
            -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $status | Add-Member -NotePropertyName Layer -NotePropertyValue ([int]$layer) -Force
        Write-Output $status
    }
}

function Format-CinegyLayerDashboard {
    param([Parameter(Mandatory)][object[]]$LayerStatuses)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'tpl.layerState'))
    $lines.Add((T 'tpl.layerActions'))
    $lines.Add('')

    foreach ($status in @($LayerStatuses | Sort-Object Layer)) {
        $layer = [int]$status.Layer
        if (-not $status.Success) {
            $lines.Add("⚠️ $(Get-LayerDisplayName -Layer $layer): غير معروف")
            continue
        }
        if (-not $status.IsOnAir) {
            $lines.Add("⚪ $(Get-LayerDisplayName -Layer $layer): مخفية")
            continue
        }

        $trackedKey = ''
        if ($script:OnAir.ContainsKey($layer)) {
            $trackedId = [string](Get-JsonProp $script:OnAir[$layer] 'ActiveId')
            $actualId = [string](Get-JsonProp $status 'ActiveId')
            if (-not [string]::IsNullOrWhiteSpace($trackedId) -and
                $trackedId.Trim().Trim('{', '}').Equals($actualId.Trim().Trim('{', '}'), [System.StringComparison]::OrdinalIgnoreCase)) {
                $trackedKey = [string](Get-JsonProp $script:OnAir[$layer] 'Key')
            }
        }

        $trackedSource = if ($script:OnAir.ContainsKey($layer)) { [string](Get-JsonProp $script:OnAir[$layer] 'Source') } else { '' }
        if ($trackedKey -and $trackedSource -ne 'cinegy') {
            $lines.Add("🔴 $(Get-LayerDisplayName -Layer $layer): $trackedKey")
        }
        else {
            $activeName = [string](Get-JsonProp $status 'ActiveTemplateName')
            if ([string]::IsNullOrWhiteSpace($activeName)) { $activeName = [string](Get-JsonProp $status 'ActiveName') }
            if ([string]::IsNullOrWhiteSpace($activeName)) { $activeName = (T 'tpl.unnamedScene') }
            $lines.Add("🟠 $(Get-LayerDisplayName -Layer $layer): $activeName (خارجي)")
        }
    }

    $metadata = @($LayerStatuses | Where-Object { $_.Success } | Select-Object -First 1)
    if ($metadata.Count -gt 0) {
        $meta = $metadata[0]
        $parts = [System.Collections.Generic.List[string]]::new()
        $outputState = [string](Get-JsonProp $meta 'OutputState')
        $licenseState = [string](Get-JsonProp $meta 'LicenseState')
        $clientIdentity = [string](Get-JsonProp $meta 'ClientIdentity')
        $clientConnected = [bool](Get-JsonProp $meta 'ClientConnected')
        if ($outputState) { $parts.Add("الخرج $outputState") }
        if ($licenseState) { $parts.Add("الترخيص $licenseState") }
        if ($clientConnected) {
            if (-not $clientIdentity) { $clientIdentity = (T 'tpl.connected') }
            $parts.Add("العميل $clientIdentity")
        }
        else { $parts.Add((T 'tpl.clientOffline')) }
        if ($parts.Count -gt 0) { $lines.Add('• ' + ($parts -join ' | ')) }
    }
    return ($lines -join "`n")
}

function Format-CinegyTelemetryStatus {
    param([Parameter(Mandatory)]$Telemetry)
    if (-not $Telemetry.Success) {
        return (T 'tpl.healthUnknownMetrics')
    }
    if ($null -eq $Telemetry.Healthy) {
        return (T 'tpl.healthUnknownSamples')
    }
    $summary = "العينات $($Telemetry.SampleCount)، الخرج $($Telemetry.OutputCount)، الساقط $($Telemetry.DroppedCount)، فقد الإدخال $($Telemetry.NoInputSignal)، أخطاء القراءة $($Telemetry.MaxReadErrorRate)%، متوسط القراءة $($Telemetry.AverageReadTime)ms، Heartbeat $($Telemetry.MaxHeartbeat)ms"
    if ($Telemetry.Healthy) { return "💚 صحة Cinegy: سليمة — $summary" }
    return "🔴 صحة Cinegy: تحذير — $summary"
}

