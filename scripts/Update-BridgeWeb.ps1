#requires -Version 7
[CmdletBinding(DefaultParameterSetName = 'Release')]
param(
    [Parameter(Mandatory)][string]$BridgeRoot,
    [Parameter(Mandatory, ParameterSetName = 'Release')][string]$ReleaseZip,
    [Parameter(Mandatory, ParameterSetName = 'Release')][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedSha256,
    [Parameter(Mandatory, ParameterSetName = 'Release')][semver]$RunningBridgeVersion,
    [Parameter(Mandatory, ParameterSetName = 'Rollback')][string]$RollbackDirectory
)

$ErrorActionPreference = 'Stop'
$webExe = 'CinegyBridge.Web.exe'
$backupManifest = 'web-backup-manifest.json'
$webFilePattern = '^(?:CinegyBridge\.Web\.exe|wwwroot/(?:index\.html|favicon\.svg|assets/(?!(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])\.)[A-Za-z0-9_-][A-Za-z0-9_.-]*\.(?:css|js|mjs|woff2?|svg|webp|png|jpe?g|ico|wasm))(?:\.(?:br|gz))?)$'

function Assert-PlainPath {
    param([string]$Path)
    $entry = Get-Item -LiteralPath $Path -Force
    while ($null -ne $entry) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Update paths cannot pass through a link: $($entry.FullName)" }
        $entry = if ($entry -is [IO.FileInfo]) { $entry.Directory } else { $entry.Parent }
    }
}

function Get-WebFileManifest {
    param([string]$Directory)

    Assert-PlainPath $Directory
    $exePath = Join-Path $Directory $webExe
    $rootFiles = @(if (Test-Path -LiteralPath $exePath) { Get-Item -LiteralPath $exePath -Force })
    $staticRoot = Join-Path $Directory 'wwwroot'

    # Refuse a custom wwwroot before moving it. Overrides beside it and
    # runtime files under logs are outside both rename operations.
    if (Test-Path -LiteralPath $staticRoot) {
        Assert-PlainPath $staticRoot
        if (-not (Test-Path -LiteralPath $staticRoot -PathType Container)) { throw 'The web installation has no wwwroot directory.' }
        foreach ($entry in Get-ChildItem -LiteralPath $staticRoot -Force) {
            Assert-PlainPath $entry.FullName
            if (-not $entry.PSIsContainer) { $rootFiles += $entry; continue }
            if ($entry.Name -cne 'assets') { throw "Unexpected directory in the installed wwwroot: $($entry.Name)" }
            $rootFiles += @(Get-ChildItem -LiteralPath $entry.FullName -Force)
        }
    }

    foreach ($file in $rootFiles) {
        $name = [IO.Path]::GetRelativePath($Directory, $file.FullName).Replace('\', '/')
        if ($file.PSIsContainer -or $name -cnotmatch $webFilePattern) { throw "Unexpected file in the installed web assets: $name" }
        Assert-PlainPath $file.FullName
        [ordered]@{ Name = $name; Length = $file.Length; SHA256 = (Get-FileHash -LiteralPath $file.FullName).Hash }
    }
}

function Test-WebPayloadComplete {
    param([string[]]$Names)
    return ($Names -ccontains $webExe) -and ($Names -ccontains 'wwwroot/index.html') -and [bool]($Names -clike 'wwwroot/assets/*.js')
}

function Assert-WebManifest {
    param([object[]]$Files)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Files) {
        $name = [string]$file.Name
        if ($name -cnotmatch $webFilePattern -or -not $names.Add($name) -or
            [string]$file.SHA256 -notmatch '^[0-9a-f]{64}$' -or [long]$file.Length -le 0) {
            throw "Invalid or duplicate web payload entry: $name"
        }
    }
    if (-not (Test-WebPayloadComplete @($names))) {
        throw 'The web payload must contain the server, the client index and its JavaScript assets.'
    }
}

function Assert-WebPayload {
    param([string]$Directory, [object[]]$Expected)
    Assert-WebManifest $Expected
    $actual = @(Get-WebFileManifest $Directory)
    if ($actual.Count -ne $Expected.Count) { throw 'The number of staged web files does not match the manifest.' }
    $byName = @{}
    foreach ($file in $actual) { $byName[$file.Name] = $file }
    foreach ($file in $Expected) {
        $received = $byName[$file.Name]
        if (-not $received -or $received.Length -ne $file.Length -or $received.SHA256 -ne $file.SHA256) {
            throw "Web payload hash or size mismatch: $($file.Name)"
        }
    }
}

function Copy-WebReleasePayload {
    param([string]$ArchivePath, [string]$Destination, [string]$ArchiveHash, [semver]$RunningVersion, [semver]$InstalledVersion)

    # Hold the stream open for both hashing and extraction so the archive can
    # neither be overwritten nor replaced between those operations.
    $stream = [IO.File]::Open($ArchivePath, 'Open', 'Read', 'Read')
    try {
        if ((Get-FileHash -InputStream $stream).Hash -ne $ArchiveHash) { throw 'The release ZIP SHA-256 does not match.' }
        $stream.Position = 0
        $archive = [IO.Compression.ZipArchive]::new($stream, 'Read', $true)
        try {
            $entries = @{}
            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace('\', '/')
                if ($name -cne 'release-manifest.json' -and -not $name.StartsWith('dist/web/', [StringComparison]::Ordinal)) { continue }
                if ($entries.ContainsKey($name)) { throw "Duplicate web release entry: $name" }
                $entries[$name] = $entry
            }
            if (-not $entries.ContainsKey('release-manifest.json')) { throw 'The ZIP has no release manifest.' }
            $reader = [IO.StreamReader]::new($entries['release-manifest.json'].Open())
            try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable }
            finally { $reader.Dispose() }
            if ($manifest.Product -cne 'CinegyTelegramBridge') { throw 'The ZIP is not a CinegyTelegramBridge release.' }
            $minimum = [semver]([string]($manifest.MinimumWebBridgeVersion ?? $manifest.Version))
            if ($RunningVersion -lt $minimum -or $InstalledVersion -lt $minimum) {
                throw "The web release requires bridge $minimum or newer. Manager reports $RunningVersion and the installed scripts are $InstalledVersion."
            }

            $files = @(foreach ($file in $manifest.Files) {
                $name = ([string]$file.Name).Replace('\', '/')
                if ($name.StartsWith('dist/web/', [StringComparison]::Ordinal)) {
                    @{ Name = $name.Substring(9); Length = $file.Length; SHA256 = $file.SHA256 }
                }
            })
            Assert-WebManifest $files
            foreach ($file in $files) {
                $entry = $entries["dist/web/$($file.Name)"]
                if (-not $entry -or $entry.Length -ne $file.Length) { throw "Web release entry missing or incorrect: $($file.Name)" }
                $path = Join-Path $Destination $file.Name
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
            }
            Assert-WebPayload $Destination $files
            return [string]$manifest.Version
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Copy-WebPayloadFiles {
    param([string]$Source, [string]$Destination, [object[]]$Files)
    foreach ($file in $Files) {
        $path = Join-Path $Destination $file.Name
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $Source $file.Name) -Destination $path
    }
    Assert-WebPayload $Destination $Files
}

function Assert-WebStopped {
    param([string]$Executable)
    foreach ($process in Get-Process -Name 'CinegyBridge.Web' -ErrorAction SilentlyContinue) {
        try {
            if (-not $process.HasExited -and (-not $process.Path -or $process.Path -eq $Executable)) {
                throw 'Stop the web server from the Manager web window, then retry the update.'
            }
        }
        finally { $process.Dispose() }
    }
}

function Switch-WebPayload {
    param([string]$Current, [string]$Stage, [string]$Recovery)

    $currentExe = Join-Path $Current $webExe
    $currentStatic = Join-Path $Current 'wwwroot'
    $retired = Join-Path $Stage 'retired'
    [IO.Directory]::CreateDirectory($retired) | Out-Null
    $retiredExe = Join-Path $retired $webExe
    $retiredStatic = Join-Path $retired 'wwwroot'
    $stageStatic = Join-Path $Stage 'wwwroot'
    Assert-WebStopped $currentExe
    $oldExeMoved = $false
    $oldStaticMoved = $false
    $newStaticMoved = $false
    try {
        # The manager discovers the server by this path each time it starts.
        # Publish the new executable last to avoid exposing a mixed version.
        if ([IO.File]::Exists($currentExe)) {
            [IO.File]::Move($currentExe, $retiredExe)
            $oldExeMoved = $true
        }
        if ([IO.Directory]::Exists($currentStatic)) {
            [IO.Directory]::Move($currentStatic, $retiredStatic)
            $oldStaticMoved = $true
        }
        [IO.Directory]::Move($stageStatic, $currentStatic)
        $newStaticMoved = $true
        [IO.File]::Move((Join-Path $Stage $webExe), $currentExe)
    }
    catch {
        $installFailure = $_
        try {
            if ($newStaticMoved) { [IO.Directory]::Move($currentStatic, $stageStatic) }
            if ($oldStaticMoved) { [IO.Directory]::Move($retiredStatic, $currentStatic) }
            if ($oldExeMoved) { [IO.File]::Move($retiredExe, $currentExe) }
        }
        catch { throw "The update failed and some web files could not be restored. Keep the server stopped and recover from '$Recovery'. $($_.Exception.Message)" }
        throw $installFailure
    }
}

$root = (Resolve-Path -LiteralPath $BridgeRoot).ProviderPath
Assert-PlainPath $root
$bridgeScript = Join-Path $root 'TelegramBridge.ps1'
if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf)) {
    throw 'BridgeRoot must be an existing bridge installation.'
}
Assert-PlainPath $bridgeScript
if ($PSCmdlet.ParameterSetName -eq 'Release') {
    $versionLine = Select-String -LiteralPath $bridgeScript -Pattern '^\$script:BridgeVersion = ''([^'']+)''' | Select-Object -First 1
    if (-not $versionLine) { throw 'Could not determine the version of the installed bridge scripts.' }
    $installedBridgeVersion = [semver]$versionLine.Matches[0].Groups[1].Value
}
$dist = Join-Path $root 'dist'
$web = Join-Path $dist 'web'
Assert-PlainPath $web
Assert-WebStopped (Join-Path $web $webExe)

# The exclusive handle serializes updates and rollbacks for this installation.
$lockPath = Join-Path $dist '.web-update.lock'
if (Test-Path -LiteralPath $lockPath) { Assert-PlainPath $lockPath }
$updateLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $backupRoot = Join-Path $dist 'web-backups'
    if (Test-Path -LiteralPath $backupRoot) { Assert-PlainPath $backupRoot }
    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    $transactionId = [guid]::NewGuid().ToString('N')
    $backup = Join-Path $backupRoot $transactionId
    $stage = Join-Path $backupRoot "$transactionId-stage"
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    try {
        $version = ''
        if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
            $source = (Resolve-Path -LiteralPath $RollbackDirectory).ProviderPath
            if ([IO.Path]::GetDirectoryName($source) -ne $backupRoot -or [IO.Path]::GetFileName($source) -cnotmatch '^[a-f0-9]{32}$') {
                throw 'Choose a rollback folder printed by this updater for the same bridge installation.'
            }
            $metadataPath = Join-Path $source $backupManifest
            Assert-PlainPath $metadataPath
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -AsHashtable
            if ($metadata.Product -cne 'CinegyTelegramBridge.Web') { throw 'This directory is not a web update backup.' }
            Assert-WebPayload $source @($metadata.Files)
            Copy-WebPayloadFiles $source $stage @($metadata.Files)
        } else {
            $archivePath = (Resolve-Path -LiteralPath $ReleaseZip).ProviderPath
            $version = Copy-WebReleasePayload $archivePath $stage $ExpectedSha256 $RunningBridgeVersion $installedBridgeVersion
        }

        $previous = @(Get-WebFileManifest $web)
        if (Test-WebPayloadComplete @($previous.Name)) {
            Copy-WebPayloadFiles $web $backup $previous
            @{ Product = 'CinegyTelegramBridge.Web'; Files = $previous } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backup $backupManifest) -Encoding UTF8
            Write-Host "Previous web files: $backup"
        } elseif ($PSCmdlet.ParameterSetName -ne 'Rollback') {
            throw 'The current web payload is incomplete. Restore the previous web backup first.'
        } else {
            $backup = $null
        }
        Switch-WebPayload $web $stage ($backup ?? $source)
        [pscustomobject]@{ Version = $version; WebDirectory = $web; BackupDirectory = $backup }
    }
    finally {
        # Only this invocation's freshly created staging directory is disposable.
        if (([IO.Path]::GetDirectoryName($stage) -eq $backupRoot) -and (Test-Path -LiteralPath $stage -PathType Container)) {
            Assert-PlainPath $stage
            [IO.Directory]::Delete($stage, $true)
        }
    }
}
finally { $updateLock.Dispose() }
