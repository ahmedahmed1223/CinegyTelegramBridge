$script:WebTemplateRegistryExportReviews = @{}

function Get-WebTemplateRegistryExportFile {
    $configured = Get-TemplateRegistryFilePath
    if ($configured -notmatch '^[A-Za-z]:[\\/]' -or -not [IO.Path]::IsPathFullyQualified($configured)) { return }
    $registry = [IO.Path]::GetFullPath($configured)
    $root = [IO.Path]::GetPathRoot($registry)
    if ([IO.DriveInfo]::new($root).DriveType -notin 'Fixed', 'Removable', 'Ram') { return }
    $relative = [IO.Path]::GetRelativePath($root, $registry).Replace('\', '/')
    # Check the drive-to-file chain before the next segment is ever opened.
    $file = Get-WebSceneItem -Root $root -RelativePath $relative -IncludeHidden
    if ($file -is [IO.FileInfo] -and $file.Extension -ieq '.json') { return $file }
}

function Invoke-WebTemplateRegistryExport {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-WebSceneCatalogueAccess -Actor $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin 'prepare', 'review', 'download') { return @{ ok = $false; error = 'template_registry_export_invalid' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    if ($action -ceq 'prepare') { return Get-WebTemplateRegistryTransferPolicy }
    $stale = @{ ok = $false; error = 'template_registry_export_stale' }
    $review = if ($action -ceq 'download') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTemplateRegistryExportReviews
    }
    if ($action -ceq 'download' -and -not $review) { return $stale }
    try {
        $file = Get-WebTemplateRegistryExportFile
        if (-not $file) { return @{ ok = $false; error = 'template_registry_export_unavailable' } }
        if ($file.Length -gt $script:TemplateRegistryImportMaximumBytes) { return @{ ok = $false; error = 'template_registry_export_size' } }
        $bytes = Read-TemplateRegistryBackupBytes -Path $file.FullName
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        $fingerprint = ConvertTo-Json -InputObject @($file.FullName, $digest) -Compress
        if ($action -ceq 'download') {
            if ($review.Fingerprint -cne $fingerprint -or $review.ExpiresAt -le [datetimeoffset]::UtcNow) { return $stale }
            if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
            $destination = Get-WebTemplateRegistryTransferFile -Id ([string](Get-JsonProp $Arguments 'transferId')) -Kind download
            if (-not $destination) { return @{ ok = $false; error = 'template_registry_transfer_unavailable' } }
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.File]::Open($destination.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Write, $share)
            try {
                if ($stream.Length -ne 0) { return @{ ok = $false; error = 'template_registry_transfer_unavailable' } }
                if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
            Add-AuditEntry (T 'cfg.templateExportAudit' (Format-UserAuditActor -UserId $actor))
            return @{ ok = $true; data = @{ bytes = $bytes.Length; sha256 = $digest } }
        }

        # Verify that the exported bytes are compatible with the existing
        # registry validator. Definitions are parsed and never dereferenced.
        try {
            $document = ConvertFrom-TemplateRegistryBackupBytes -Bytes $bytes
            $count = Get-TemplateRegistryValidatedCount -Document $document
            $null = Get-WebTemplateBackupLayout -Document $document
        }
        catch { return @{ ok = $false; error = 'template_registry_export_invalid' } }
        if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
        return @{ ok = $true; data = @{
                review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebTemplateRegistryExportReviews
                templates = $count; bytes = $bytes.Length
            } }
    }
    catch { return @{ ok = $false; error = 'template_registry_export_unavailable' } }
}
