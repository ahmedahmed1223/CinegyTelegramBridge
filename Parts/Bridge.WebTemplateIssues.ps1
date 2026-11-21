#requires -Version 7

$script:WebTemplateIssueReviews = @{}

function Get-WebTemplateIssueSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Registry file is unavailable.' }
    for ($directory = $item.Directory; $directory; $directory = $directory.Parent) {
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Registry directory is unavailable.' }
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $script:TemplateRegistryImportMaximumBytes) {
            throw 'Template registry size is outside the supported range.'
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes)
    }
    finally { $stream.Dispose() }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
    $document = ConvertFrom-Json -InputObject $text -NoEnumerate -ErrorAction Stop
    if ($document -isnot [System.Management.Automation.PSCustomObject]) { throw 'Template registry must be an object.' }
    return @{ Document = $document; Text = $text; Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
}

function Get-WebTemplateIssueLayer {
    param($Entry)
    $layer = 0
    $declared = [string](Get-JsonProp $Entry 'device')
    if ($Entry -isnot [System.Management.Automation.PSCustomObject] -or
        -not [int]::TryParse([string](Get-JsonProp $Entry 'layer'), [ref]$layer) -or $layer -le 0 -or
        ($declared -and $declared -notmatch '^[A-Za-z0-9_]{1,32}$')) { return 0 }
    return $layer
}

function Get-WebTemplateIssueLiveBlocker {
    param($Entry, [long]$Deadline = 0)

    $layer = Get-WebTemplateIssueLayer -Entry $Entry
    if ($layer -le 0 -or [string](Get-Setting 'SceneMode') -ne 'Single') { return 'template_issue_layer_unverified' }
    $mapped = [string](Resolve-AirGfxDevice -Layer $layer).StatusPath
    if ($mapped -cnotmatch '^gfx_([a-z0-9_]{1,32})$') { return 'template_issue_layer_unverified' }
    $mappedName = $Matches[1]
    $declaredName = [string](Get-JsonProp $Entry 'device')
    $devices = @(@([string]$layer, $mappedName, $declaredName) | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($existing in $script:OnAir.Keys) {
        $liveLayer = [int]$existing
        $liveDevice = (Resolve-AirGfxDevice -Layer $liveLayer).StatusPath -replace '^gfx_', ''
        if ($layer -eq $liveLayer -or $devices -contains $liveDevice) { return 'scene_definition_live' }
    }
    foreach ($device in $devices) {
        if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return 'bridge_busy' }
        $air = @{ AirServerAddress = $config.AirServerAddress; AirChannelNumber = $config.AirChannelNumber }
        $status = Get-TitlerLayerStatus @air -Layer $layer -Device $device -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $stamp = Get-CinegyLayerReviewStamp -Status $status
        if (-not $stamp) { return 'template_issue_layer_unverified' }
        if ($stamp -cne 'empty') { return 'scene_definition_live' }
    }
    if ((Resolve-AirGfxDevice -Layer $layer).StatusPath -cne $mapped) { return 'template_issue_layer_unverified' }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return 'bridge_busy' }
    return ''
}

function Get-WebTemplateIssueEntry {
    param($Property, [string]$Registry)

    if ($null -eq $Property) { return }
    $key = [string]$Property.Name
    $entry = $Property.Value
    $issue = Get-TemplateRegistryEntryIssue -Entry $entry
    if (-not $issue.Code) { return }
    $keyBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject @($Registry, $key)))
    $id = [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData($script:TemplatePresetRevisionKey, $keyBytes))
    $name = if ($key -match '^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$') { $key } else { '' }
    $layer = Get-WebTemplateIssueLayer -Entry $entry
    return @{ id = $id; name = $name; reason = $issue.Code; layer = $layer; canReview = [bool]$name -and $layer -gt 0 }
}

function Invoke-WebTemplateIssue {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-TemplateReminderManager -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $id = [string](Get-JsonProp $Arguments 'id')
    if ($action -cnotin 'list', 'preview', 'delete' -or ($action -cne 'list' -and $id -cnotmatch '^[A-F0-9]{64}$')) {
        return @{ ok = $false; error = 'template_issue_invalid' }
    }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $stale = @{ ok = $false; error = 'scene_registry_stale' }
    $approval = if ($action -ceq 'delete') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTemplateIssueReviews
    }
    if ($action -ceq 'delete' -and -not $approval) { return $stale }

    try {
        $path = [IO.Path]::GetFullPath((Get-TemplateRegistryFilePath))
        $snapshot = Get-WebTemplateIssueSnapshot -Path $path
        $invalid = @(Get-InvalidTemplateEntries | Select-Object -First 81)
        if ($action -ceq 'list') {
            $items = @(foreach ($entry in ($invalid | Select-Object -First 80)) {
                Get-WebTemplateIssueEntry -Property $snapshot.Document.PSObject.Properties[[string]$entry.Key] -Registry $path
            })
            return @{ ok = $true; data = @{ items = $items; truncated = $invalid.Count -gt 80 } }
        }
        $selected = $null
        foreach ($item in ($invalid | Select-Object -First 80)) {
            $property = $snapshot.Document.PSObject.Properties[[string]$item.Key]
            $issue = Get-WebTemplateIssueEntry -Property $property -Registry $path
            if ($issue -and $issue.id -ceq $id) { $selected = $issue; break }
        }
        if (-not $selected) { return $stale }
        if (-not $selected.canReview) { return @{ ok = $false; error = 'template_issue_layer_unverified' } }
        $key = $property.Name
        $entry = $property.Value
        $revision = Get-TemplatePresetRevision -TemplateKey $key -Entry $entry
        if (-not $revision) { return $stale }
        $device = [string](Resolve-AirGfxDevice -Layer $selected.layer).StatusPath
        $fingerprint = ConvertTo-Json -InputObject @($id, $revision, $snapshot.Hash, $selected.reason, $device,
            [string](Get-Setting 'SceneMode'), [string]$config.AirServerAddress, [int]$config.AirChannelNumber) -Compress
        if ($action -ceq 'preview') {
            $blocker = Get-TemplateDefinitionBlocker -TemplateKey $key -Delete
            if (-not $blocker) { $blocker = Get-WebTemplateIssueLiveBlocker -Entry $entry -Deadline $Deadline }
            if ($blocker) { return @{ ok = $false; error = $blocker } }
            $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebTemplateIssueReviews
            return @{ ok = $true; data = @{ preview = @{ issue = $selected; review = $token } } }
        }
        if ($approval.Fingerprint -cne $fingerprint) { return $stale }
        $remaining = ($approval.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
        if ($remaining -le 0) { return $stale }
        $writeDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
        if ($Deadline -gt 0) { $writeDeadline = [math]::Min($Deadline, $writeDeadline) }
        $guard = @{ ExpectedRevision = $revision; ExpectedRegistryHash = $snapshot.Hash; Deadline = $writeDeadline; RemoveInvalid = $true }
        $saved = Save-TemplateDefinitionChange @guard -TemplateKey $key -Action delete
        if (-not $saved.Success) {
            $code = [string](Get-JsonProp $saved 'Code')
            return @{ ok = $false; error = ($code ? $code : 'scene_registry_failed') }
        }
        Add-AuditEntry (T 'cb.invalidDeletedAudit' $key $(Format-UserAuditActor -UserId $actor))
        Publish-WebChannelState -Force
        return @{ ok = $true; data = @{ deleted = $true } }
    }
    catch { return @{ ok = $false; error = 'scene_registry_failed' } }
}
