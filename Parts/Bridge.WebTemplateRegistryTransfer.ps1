function Get-WebTemplateRegistryTransferDirectory {
    param([switch]$Create)
    $configured = $script:logDir
    if ($configured -notmatch '^[A-Za-z]:[\\/]' -or -not [IO.Path]::IsPathFullyQualified($configured)) { return }
    $runtime = [IO.Path]::GetFullPath($configured)
    $drive = [IO.Path]::GetPathRoot($runtime)
    if ([IO.DriveInfo]::new($drive).DriveType -notin 'Fixed', 'Removable', 'Ram') { return }
    $relative = if ($runtime -ieq $drive) { '' } else { [IO.Path]::GetRelativePath($drive, $runtime).Replace('\', '/') }
    $folder = Get-WebSceneItem -Root $drive -RelativePath $relative -IncludeHidden
    if ($folder -isnot [IO.DirectoryInfo]) { return }
    $stage = Join-Path $folder.FullName 'web-registry-transfer'
    $directory = $null
    try { $directory = Get-Item -LiteralPath $stage -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] {
        if ($Create) { $directory = New-Item -Path $stage -ItemType Directory -ErrorAction Stop }
    }
    if ($directory -is [IO.DirectoryInfo] -and -not ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return $directory
    }
}

function Get-WebTemplateRegistryTransferPolicy {
    try {
        $directory = Get-WebTemplateRegistryTransferDirectory -Create
        if ($directory) {
            return @{ ok = $true; data = @{
                    directory = $directory.FullName; maximumBytes = $script:TemplateRegistryImportMaximumBytes
                } }
        }
    }
    catch { return @{ ok = $false; error = 'template_registry_transfer_unavailable' } }
    return @{ ok = $false; error = 'template_registry_transfer_unavailable' }
}

function Get-WebTemplateRegistryTransferFile {
    param([string]$Id, [ValidateSet('upload', 'download')][string]$Kind)
    if ($Id -cnotmatch '^[a-f0-9]{32}$') { return }
    $directory = Get-WebTemplateRegistryTransferDirectory
    if (-not $directory) { return }
    $file = Get-Item -LiteralPath (Join-Path $directory.FullName "$Kind-$Id.json") -Force -ErrorAction SilentlyContinue
    if ($file -is [IO.FileInfo] -and -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $file }
}
