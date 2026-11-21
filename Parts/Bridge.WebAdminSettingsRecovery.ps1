#requires -Version 7

$script:WebAdminSettingsRecoveryReviews = @{}
$script:WebAdminSettingsBackupKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)

function Get-WebAdminSettingsBackupFiles {
    $backupDirectory = Get-Item -LiteralPath "$script:ConfigPath.backups" -Force -ErrorAction SilentlyContinue
    $previous = Get-Item -LiteralPath "$script:ConfigPath.bak" -Force -ErrorAction SilentlyContinue
    if ($previous -is [IO.FileInfo] -and $previous.Length -gt 0 -and $previous.Length -le 4MB -and
        -not ($previous.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        @{ file = $previous; kind = 'previous' }
    }
    if ($backupDirectory -isnot [IO.DirectoryInfo] -or ($backupDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }

    foreach ($file in @(Get-ConfigBackupFiles -Path $script:ConfigPath)) {
        if ($file -isnot [IO.FileInfo] -or $file.Length -le 0 -or $file.Length -gt 4MB -or
            ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $file.DirectoryName -cne $backupDirectory.FullName -or
            $file.Name -cnotmatch '^(config|pre-restore)-[0-9]{8}-[0-9]{6}-[0-9]{3}(?:-[0-9a-f]{8})?\.json$') { continue }
        $kind = if ($file.Name.StartsWith('pre-restore-', [StringComparison]::Ordinal)) { 'before-restore' } else { 'automatic' }
        @{ file = $file; kind = $kind }
    }
}

function Get-WebAdminSettingsBackupId {
    param([long]$Actor, [IO.FileInfo]$File)

    $fingerprint = ConvertTo-Json -InputObject @($Actor, $File.FullName, $File.Length, $File.CreationTimeUtc.Ticks, $File.LastWriteTimeUtc.Ticks) -Compress
    $payload = [Text.Encoding]::UTF8.GetBytes($fingerprint)
    return [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData($script:WebAdminSettingsBackupKey, $payload)).ToLowerInvariant()
}

function Get-WebAdminSettingsBackups {
    param([System.Collections.IDictionary]$Arguments)

    $actor = Get-WebAdminSettingActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }

    $entries = @(Get-WebAdminSettingsBackupFiles | Select-Object -First 21)
    $items = @(foreach ($entry in ($entries | Select-Object -First 20)) {
            @{
                id = Get-WebAdminSettingsBackupId -Actor $actor -File $entry.file
                savedAt = ([datetimeoffset]$entry.file.LastWriteTimeUtc).ToUnixTimeMilliseconds()
                kind = $entry.kind
            }
        })
    return @{ ok = $true; data = @{ items = $items; truncated = $entries.Count -gt 20 } }
}

function Read-WebAdminSettingsBackup {
    param([IO.FileInfo]$File)

    try {
        $File.Refresh()
        if (-not $File.Exists -or ($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            ($File.Directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
        $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            if ($stream.Length -ne $File.Length -or $stream.Length -gt 4MB) { return }
            $identity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))
            $stream.Position = 0
            $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true, 4096, $true)
            try { $raw = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
        $documentOptions = [System.Text.Json.JsonDocumentOptions]@{
            AllowTrailingCommas = $true
            CommentHandling = [System.Text.Json.JsonCommentHandling]::Skip
            MaxDepth = 100
        }
        $document = [System.Text.Json.JsonDocument]::Parse($raw, $documentOptions)
        try {
            if ($document.RootElement.ValueKind -ne 'Object') { return }
            $sections = @($document.RootElement.EnumerateObject() | Where-Object Name -ieq 'Settings')
            if ($sections.Count -ne 1 -or $sections[0].Name -cne 'Settings' -or $sections[0].Value.ValueKind -ne 'Object') { return }
            $allowed = @(Get-WebAdminEditableSettingId)
            $values = [ordered]@{}
            foreach ($property in $sections[0].Value.EnumerateObject()) {
                if ($property.Name -cnotin $allowed) { continue }
                if ($values.Contains($property.Name)) { return }
                $value = $property.Value
                switch ($value.ValueKind) {
                    'True' { $values[$property.Name] = $true }
                    'False' { $values[$property.Name] = $false }
                    'Number' {
                        $number = 0
                        if (-not $value.TryGetInt32([ref]$number)) { return }
                        $values[$property.Name] = $number
                    }
                    default { return }
                }
            }
            if (-not $values.Count) { return }
            return @{ values = $values; hash = $identity }
        }
        finally { $document.Dispose() }
    }
    catch { return }
}

function New-WebAdminSettingsRecoveryReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = Get-WebAdminSettingActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    $script:WebAdminSettingsRecoveryReviews.Remove($actor)
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }

    $source = [string](Get-JsonProp $Arguments 'source')
    $id = [string](Get-JsonProp $Arguments 'backup')
    $version = @{ diskHash = ''; sourcePath = ''; sourceHash = '' }
    if ($source -ceq 'defaults' -and -not $id) {
        $values = [ordered]@{}
        foreach ($row in @(Get-WebAdminEditableSettingSchema)) { $values[$row.Metadata.Name] = $row.Metadata.Default }
    }
    elseif ($source -ceq 'backup' -and $id -cmatch '^[0-9a-f]{64}$') {
        $entry = Get-WebAdminSettingsBackupFiles | Select-Object -First 20 | Where-Object {
            (Get-WebAdminSettingsBackupId -Actor $actor -File $_.file) -ceq $id
        } | Select-Object -First 1
        if (-not $entry) { return @{ ok = $false; error = 'setting_stale' } }
        $payload = Read-WebAdminSettingsBackup -File $entry.file
        if (-not $payload) { return @{ ok = $false; error = 'settings_backup_invalid' } }
        $version.sourcePath = $entry.file.FullName
        $version.sourceHash = $payload.hash
        $values = $payload.values
    }
    else { return @{ ok = $false; error = 'setting_invalid' } }

    $plan = Get-WebAdminSettingsImportPlan -Requested $values
    if ($plan.ContainsKey('error')) { return @{ ok = $false; error = $plan.error } }
    $version.diskHash = Get-ConfigDiskFingerprint -Path $script:ConfigPath
    if (-not $version.diskHash) { return @{ ok = $false; error = 'setting_save_failed' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }

    $changes = @(Get-WebAdminSettingsImportChanges -Plan $plan)
    $token = $null
    if ($changes.Count) {
        $token = New-WebAirReview -Actor $actor -Fingerprint $plan.fingerprint -Reviews $script:WebAdminSettingsRecoveryReviews
        $pending = $script:WebAdminSettingsRecoveryReviews[$actor]
        $pending.Desired = $plan.after
        $pending.Version = $version
        $pending.Source = $source
    }
    return @{ ok = $true; data = @{ changes = $changes; review = $token } }
}

function Complete-WebAdminSettingsRecoveryReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = Get-WebAdminSettingActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $approved = Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAdminSettingsRecoveryReviews
    if (-not $approved) { return @{ ok = $false; error = 'setting_stale' } }
    $result = Save-WebAdminSettingsImportPlan -Actor $actor -Approved $approved -Deadline $Deadline -Version $approved.Version
    if ($result.ok) { Write-BridgeLog "User $actor applied a reviewed Web settings recovery ($($approved.Source))." }
    return $result
}
