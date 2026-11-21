$script:WebTemplateRegistryImportReviews = @{}

function Get-WebTemplateImportLocalPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Length -gt 1024 -or $Path -match '%|[\p{Cc}\p{Cf}]' -or
        -not [IO.Path]::IsPathFullyQualified($Path)) { return }
    $normalized = $Path.Replace('/', '\')
    $remaining = $normalized.Substring(3).TrimEnd('\')
    if ($remaining) {
        foreach ($segment in $remaining.Split('\')) {
            if (-not $segment -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
                $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                $segment -match '^(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') { return }
        }
    }
    try { return [IO.Path]::GetFullPath($normalized) }
    catch { return }
}

function Get-WebTemplateImportSceneProof {
    param($Current, $Candidate, [string]$Catalogue, [long]$Deadline)
    $paths = [ordered]@{}
    $root = Get-WebTemplateImportLocalPath -Path $Catalogue
    foreach ($property in $Candidate.PSObject.Properties) {
        $previous = Get-JsonProp $Current $property.Name
        $path = [string](Get-JsonProp $property.Value 'path')
        if ($previous -and [string](Get-JsonProp $previous 'path') -ceq $path) { continue }
        $candidate = Get-WebTemplateImportLocalPath -Path $path
        if (-not $root -or -not $candidate -or [IO.Path]::GetExtension($candidate) -ine '.cintitle' -or
            -not $candidate.StartsWith(($root.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            return @{ ok = $false; error = 'template_registry_import_path' }
        }
        $paths[$property.Name] = $candidate
        if ($paths.Count -gt 40) { return @{ ok = $false; error = 'template_registry_import_path_count' } }
    }

    # Check every submitted path lexically before opening any catalogue item.
    if (-not $paths.Count) { return @{ ok = $true; items = @() } }
    $drive = [IO.Path]::GetPathRoot($root)
    if ([IO.DriveInfo]::new($drive).DriveType -notin 'Fixed', 'Removable', 'Ram') {
        return @{ ok = $false; error = 'template_registry_import_path' }
    }
    $proof = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $paths.GetEnumerator()) {
        if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
        $relative = [IO.Path]::GetRelativePath($drive, $entry.Value).Replace('\', '/')
        $file = Get-WebSceneItem -Root $drive -RelativePath $relative -IncludeHidden
        if ($file -isnot [IO.FileInfo] -or $file.FullName -ine $entry.Value) {
            return @{ ok = $false; error = 'template_registry_import_path' }
        }
        $proof.Add(@($entry.Key, $relative, $file.Length, $file.CreationTimeUtc.Ticks, $file.LastWriteTimeUtc.Ticks))
    }
    return @{ ok = $true; items = $proof.ToArray() }
}

function Invoke-WebTemplateRegistryImport {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-WebSceneCatalogueAccess -Actor $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin 'prepare', 'review', 'confirm') { return @{ ok = $false; error = 'template_registry_import_invalid' } }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    if ($action -ceq 'prepare') { return Get-WebTemplateRegistryTransferPolicy }
    $stale = @{ ok = $false; error = 'template_registry_import_stale' }
    $review = if ($action -ceq 'confirm') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTemplateRegistryImportReviews
    }
    if ($action -ceq 'confirm' -and -not $review) { return $stale }
    try {
        $upload = Get-WebTemplateRegistryTransferFile -Id ([string](Get-JsonProp $Arguments 'transferId')) -Kind upload
        if (-not $upload) { return @{ ok = $false; error = 'template_registry_transfer_unavailable' } }
        if ($upload.Length -gt $script:TemplateRegistryImportMaximumBytes) { return @{ ok = $false; error = 'template_registry_import_size' } }
        # The server still owns its write handle with read-only sharing.
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $bytes = Read-TemplateRegistryBackupBytes -Path $upload.FullName -Share $share
        $candidate = ConvertFrom-TemplateRegistryBackupBytes -Bytes $bytes
    }
    catch { return @{ ok = $false; error = 'template_registry_import_invalid' } }
    try {
        $registry = Get-WebTemplateRegistryExportFile
        if (-not $registry) { return @{ ok = $false; error = 'template_registry_import_unavailable' } }
        $currentBytes = Read-TemplateRegistryBackupBytes -Path $registry.FullName
        $current = ConvertFrom-TemplateRegistryBackupBytes -Bytes $currentBytes
        $currentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($currentBytes))
        $candidateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        $root = Get-WebSceneCatalogueRoot
        $requestStamp = @($registry.FullName, $currentHash, $candidateHash, $root)
        # A changed upload or registry must fail before any file proof.
        if ($review) {
            $expected = ConvertFrom-Json -InputObject $review.Fingerprint -AsHashtable
            if ($expected.request -cne (ConvertTo-Json -InputObject $requestStamp -Compress)) { return $stale }
        }
        try { $count = Get-TemplateRegistryValidatedCount -Document $candidate -Current $current }
        catch { return @{ ok = $false; error = 'template_registry_import_invalid' } }
        $proof = Get-WebTemplateImportSceneProof -Current $current -Candidate $candidate -Catalogue $root -Deadline $Deadline
        if (-not $proof.ok) { return $proof }
        $fingerprint = ConvertTo-Json -InputObject ([ordered]@{
            request = (ConvertTo-Json -InputObject $requestStamp -Compress); proofs = $proof.items
        }) -Depth 5 -Compress
        if ($review -and ($review.Fingerprint -cne $fingerprint -or $review.ExpiresAt -le [datetimeoffset]::UtcNow)) { return $stale }
        try { $blocker = Get-WebTemplateBackupBlocker -Current $current -Candidate $candidate }
        catch { return @{ ok = $false; error = 'template_registry_import_invalid' } }
        if ($blocker) { return @{ ok = $false; error = $blocker } }
        if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
        $changes = Get-TemplateRegistryImportComparison -Current $current -Imported $candidate
        if ($action -ceq 'review') {
            return @{ ok = $true; data = @{
                    review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebTemplateRegistryImportReviews
                    templates = $count; added = $changes.Added.Count; changed = $changes.Changed.Count
                    removed = $changes.Removed.Count; unchanged = $changes.Unchanged.Count
                } }
        }
        # The shared atomic writer backs up beside the registry. Reject a
        # redirected backup directory before the writer can enter it.
        try { $backupDir = Get-Item -LiteralPath "$($registry.FullName).backups" -Force -ErrorAction Stop }
        catch [System.Management.Automation.ItemNotFoundException] { $backupDir = $null }
        if ($backupDir -and ($backupDir -isnot [IO.DirectoryInfo] -or ($backupDir.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            return @{ ok = $false; error = 'template_registry_import_unavailable' }
        }
        $remaining = ($review.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
        if ($remaining -le 0) { return $stale }
        $commitDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
        if ($Deadline -gt 0) { $commitDeadline = [math]::Min($Deadline, $commitDeadline) }
        $result = Restore-TemplateRegistryBackup -Path $registry.FullName -ReviewedBytes $bytes -ExpectedRegistryHash $currentHash -Deadline $commitDeadline
        if (-not $result.Success) {
            $code = [string](Get-JsonProp $result 'Code')
            if ($code -eq 'template_backup_stale') { return $stale }
            return @{ ok = $false; error = ($code ? $code : 'template_registry_import_unavailable') }
        }
        Add-AuditEntry (T 'cfg.templateImportAudit' (Format-UserAuditActor -UserId $actor))
        return @{ ok = $true }
    }
    catch { return @{ ok = $false; error = 'template_registry_import_unavailable' } }
}
