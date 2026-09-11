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

        $backupDir = "$path.backups"
        New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $backupPath = Join-Path $backupDir "templates-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
        $keep = Get-SettingInt 'ConfigBackupKeepFiles' 1
        if ($keep -gt 0) {
            @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip $keep) |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }

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
            $errors.Add("القالب '$key' له مسار غير مطلق '$tplPath' - اضبط TemplateBasePath أو اكتب مسارًا كاملًا.")
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
            $errors.Add("القالب '$key' فيه اسم جهاز غير صالح '$deviceName' - تم تجاهل الاسم.")
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
        if (-not $reason) { $reason = 'غير صالح' }
        $entries += [pscustomobject]@{ Key = $name; Reason = [string]$reason }
    }
    return $entries
}

function Get-TemplateByIndex {
    param([Parameter(Mandatory)][int]$Index)
    $store = Get-TemplateStore
    if ($Index -lt 0 -or $Index -ge $store.Order.Count) { return $null }
    return $store.Map[$store.Order[$Index]]
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
            if (@($script:OnAir.Values | Where-Object { [string](Get-JsonProp $_ 'Key') -eq $TemplateKey }).Count -gt 0) { throw 'لا يمكن حذف قالب على الهواء.' }
            if (@(Get-UpcomingScheduleEvents | Where-Object { [string](Get-JsonProp $_ 'TemplateKey') -eq $TemplateKey }).Count -gt 0) { throw 'لا يمكن حذف قالب مرتبط بجدولة قادمة.' }
            $raw.PSObject.Properties.Remove($TemplateKey)
        }
        else {
            $templatePath = [string](Get-JsonProp $Definition 'path')
            $layer = 0
            if ([string]::IsNullOrWhiteSpace($templatePath)) { throw 'مسار القالب فارغ.' }
            if (-not [int]::TryParse([string](Get-JsonProp $Definition 'layer'), [ref]$layer) -or $layer -le 0) { throw 'رقم الطبقة يجب أن يكون موجبًا.' }
            $root = [IO.Path]::GetFullPath($scriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $resolved = [IO.Path]::GetFullPath((Join-Path $scriptRoot $templatePath))
            if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'مسار القالب يجب أن يكون داخل مجلد المشروع.' }
            $fields = @(Get-JsonProp $Definition 'fields')
            foreach ($field in $fields) {
                $fieldName = if ($field -is [string]) { $field } else { [string](Get-JsonProp $field 'name') }
                if ([string]::IsNullOrWhiteSpace([string]$fieldName)) { throw 'يوجد حقل بلا اسم صالح.' }
            }
            if ($Action -eq 'create') { $target = [pscustomobject]@{}; $raw | Add-Member -NotePropertyName $TemplateKey -NotePropertyValue $target }
            else { $target = $existing }
            foreach ($name in @('path', 'layer', 'order', 'description', 'category', 'fields', 'reminderMinutes')) {
                if ($Definition.ContainsKey($name)) { $target | Add-Member -NotePropertyName $name -NotePropertyValue $Definition[$name] -Force }
            }
        }
        $backupDir = "$path.backups"
        New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        $backupPath = Join-Path $backupDir "templates-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
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
        return [pscustomobject]@{ Success = $false; Error = 'المدة يجب أن تكون من 0 إلى 1440 دقيقة.'; BackupPath = '' }
    }
    $path = Get-TemplateRegistryFilePath
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $template = Get-JsonProp $raw $TemplateKey
        if (-not $template) { throw "القالب '$TemplateKey' غير موجود." }
        $backupDir = "$path.backups"
        New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        $backupPath = Join-Path $backupDir "templates-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
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
    $lines.Add('🎚 حالة طبقات Cinegy:')
    $lines.Add('الإجراءات: 🙈 إخفاء = يخفي الطبقة فورًا | 🔄 تحديث = يعيد فحص كل الطبقات')
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
            if ([string]::IsNullOrWhiteSpace($activeName)) { $activeName = 'مشهد غير مسمّى' }
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
            if (-not $clientIdentity) { $clientIdentity = 'متصل' }
            $parts.Add("العميل $clientIdentity")
        }
        else { $parts.Add('العميل غير متصل') }
        if ($parts.Count -gt 0) { $lines.Add('• ' + ($parts -join ' | ')) }
    }
    return ($lines -join "`n")
}

function Format-CinegyTelemetryStatus {
    param([Parameter(Mandatory)]$Telemetry)
    if (-not $Telemetry.Success) {
        return "⚠️ صحة Cinegy: غير معروفة (تعذّر قراءة metrics)"
    }
    if ($null -eq $Telemetry.Healthy) {
        return "⚠️ صحة Cinegy: غير معروفة (لا توجد عينات)"
    }
    $summary = "العينات $($Telemetry.SampleCount)، الخرج $($Telemetry.OutputCount)، الساقط $($Telemetry.DroppedCount)، فقد الإدخال $($Telemetry.NoInputSignal)، أخطاء القراءة $($Telemetry.MaxReadErrorRate)%، متوسط القراءة $($Telemetry.AverageReadTime)ms، Heartbeat $($Telemetry.MaxHeartbeat)ms"
    if ($Telemetry.Healthy) { return "💚 صحة Cinegy: سليمة — $summary" }
    return "🔴 صحة Cinegy: تحذير — $summary"
}

