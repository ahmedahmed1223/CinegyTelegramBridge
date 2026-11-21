$script:WebBulletinSceneImageReviews = @{}

function Get-WebBulletinSceneImageContext {
    param([System.Collections.IDictionary]$Arguments)
    $actor = [long](Get-JsonProp $Arguments 'actor')
    if (-not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    $rowId = [string](Get-JsonProp $Arguments 'rowId')
    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
    if (-not $bulletin -or -not $rowId) { return @{ ok = $false; error = 'not_found' } }
    $revision = [int](Get-JsonProp $bulletin 'Revision')
    if ($revision -ne (Get-JsonProp $Arguments 'revision')) { return @{ ok = $false; error = 'bulletin_stale' } }
    $rows = @(Get-JsonProp $bulletin 'Rows')
    if ($rowId -cnotin @($rows | ForEach-Object { [string](Get-JsonProp $_ 'Id') })) { return @{ ok = $false; error = 'not_found' } }
    $field = Get-WebBulletinImageField -Fields @(Get-WebBulletinFields -Bulletin $bulletin)
    if (-not $field) { return @{ ok = $false; error = 'bulletin_scene_images_unavailable' } }
    $scene = [string](Get-JsonProp (Get-MojazPlaybackTemplate -Bulletin $bulletin) 'Path')
    try {
        if (-not [IO.Path]::IsPathFullyQualified($scene) -or [IO.Path]::GetExtension($scene) -ine '.cintitle') {
            return @{ ok = $false; error = 'bulletin_scene_images_unavailable' }
        }
        $file = [IO.FileInfo]::new([IO.Path]::GetFullPath($scene))
        if (-not $file.Exists -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return @{ ok = $false; error = 'bulletin_scene_images_unavailable' }
        }
        for ($directory = $file.Directory; $directory; $directory = $directory.Parent) {
            if (-not $directory.Exists -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                return @{ ok = $false; error = 'bulletin_scene_images_unavailable' }
            }
        }
        return @{ ok = $true; actor = $actor; id = $id; rowId = $rowId; revision = $revision
            scene = $file.FullName; directory = $file.Directory; field = $field }
    }
    catch { return @{ ok = $false; error = 'bulletin_scene_images_unavailable' } }
}

function Get-WebBulletinSceneRaster {
    param([IO.FileInfo]$File, [IO.DirectoryInfo]$Directory)
    try {
        if ($File.DirectoryName -cne $Directory.FullName -or $File.Name.Length -gt 150 -or
            $File.Name -match '[:%/\\\p{Cc}\p{Cf}]' -or $File.Extension -notin '.png', '.jpg', '.jpeg', '.gif', '.bmp') { return }
        $File.Refresh()
        if (-not $File.Exists -or ($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $File.Length -lt 12 -or $File.Length -gt 10MB) { return }
        $length = $File.Length
        $written = $File.LastWriteTimeUtc.Ticks
        $created = $File.CreationTimeUtc.Ticks
        $stream = [IO.File]::Open($File.FullName, 'Open', 'Read', 'Read')
        try {
            if ($stream.Length -ne $length) { return }
            $header = [byte[]]::new(12)
            $stream.ReadExactly($header, 0, $header.Length)
        }
        finally { $stream.Dispose() }
        $magic = [Convert]::ToHexString($header)
        $valid = switch ($File.Extension.ToLowerInvariant()) {
            '.png' { $magic.StartsWith('89504E470D0A1A0A', [StringComparison]::Ordinal) }
            { $_ -in '.jpg', '.jpeg' } { $magic.StartsWith('FFD8FF', [StringComparison]::Ordinal) }
            '.gif' { $magic -match '^47494638(37|39)61' }
            '.bmp' { $magic.StartsWith('424D', [StringComparison]::Ordinal) }
        }
        $File.Refresh()
        if (-not $valid -or -not $File.Exists -or ($File.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $File.Length -ne $length -or $File.LastWriteTimeUtc.Ticks -ne $written -or $File.CreationTimeUtc.Ticks -ne $created) { return }
        return @{ name = $File.Name; bytes = $length; written = $written; created = $created }
    }
    catch { return }
}

function Get-WebBulletinSceneImagePage {
    param([hashtable]$Context, [int]$Page, [long]$Deadline)
    $candidates = [System.Collections.Generic.List[object]]::new()
    $seen = 0
    $truncated = $false
    try {
        foreach ($entry in $Context.directory.EnumerateFileSystemInfos()) {
            if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
                return @{ ok = $false; error = 'bridge_busy' }
            }
            if (++$seen -gt 200) { $truncated = $true; break }
            if ($entry -isnot [IO.FileInfo]) { continue }
            $raster = Get-WebBulletinSceneRaster -File $entry -Directory $Context.directory
            if ($raster) { $candidates.Add($raster) }
        }
    }
    catch { return @{ ok = $false; error = 'bulletin_scene_images_unavailable' } }
    $sorted = @($candidates | Sort-Object { $_.name })
    $window = Get-BridgePageWindow -ItemCount $sorted.Count -Page $Page
    $pageFiles = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) { $sorted[$index] })
    $selection = ''
    if ($pageFiles.Count -gt 0) {
        $snapshot = [ordered]@{ id = $Context.id; row = $Context.rowId; revision = $Context.revision
            scene = $Context.scene; field = $Context.field; files = $pageFiles }
        $selection = New-WebAirReview -Actor $Context.actor -Fingerprint (ConvertTo-Json $snapshot -Depth 4 -Compress) -Reviews $script:WebBulletinSceneImageReviews
    }
    return @{ ok = $true; data = @{
            selection = $selection; page = $window.Page; pageCount = $window.PageCount; truncated = $truncated
            items = @(for ($slot = 0; $slot -lt $pageFiles.Count; $slot++) {
                    @{ slot = $slot; label = $pageFiles[$slot].name; bytes = $pageFiles[$slot].bytes }
                })
        } }
}

function Invoke-WebBulletinSceneImages {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)
    $context = Get-WebBulletinSceneImageContext -Arguments $Arguments
    if (-not $context.ok) { return $context }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'list') {
        return Get-WebBulletinSceneImagePage -Context $context -Page ([int](Get-JsonProp $Arguments 'page')) -Deadline $Deadline
    }
    if ($action -ne 'apply') { return @{ ok = $false; error = 'bulletin_photo_invalid' } }
    $slot = Get-JsonProp $Arguments 'slot'
    if (($slot -isnot [int] -and $slot -isnot [long]) -or $slot -lt 0 -or $slot -ge 20) {
        return @{ ok = $false; error = 'bulletin_photo_invalid' }
    }
    $review = Use-WebAirReview -Actor $context.actor -Token ([string](Get-JsonProp $Arguments 'selection')) -Reviews $script:WebBulletinSceneImageReviews
    if (-not $review) { return @{ ok = $false; error = 'bulletin_scene_image_stale' } }
    $snapshot = ConvertFrom-Json -InputObject $review.Fingerprint -AsHashtable
    if ($snapshot.id -cne $context.id -or $snapshot.row -cne $context.rowId -or $snapshot.revision -ne $context.revision -or
        $snapshot.scene -cne $context.scene -or $snapshot.field -cne $context.field -or $slot -ge $snapshot.files.Count) {
        return @{ ok = $false; error = 'bulletin_scene_image_stale' }
    }
    $expected = $snapshot.files[$slot]
    $file = [IO.FileInfo]::new([IO.Path]::Combine($context.directory.FullName, [string]$expected.name))
    $raster = Get-WebBulletinSceneRaster -File $file -Directory $context.directory
    if (-not $raster -or $raster.bytes -ne $expected.bytes -or $raster.written -ne $expected.written -or $raster.created -ne $expected.created) {
        return @{ ok = $false; error = 'bulletin_scene_image_stale' }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $result = Set-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $context.id -RowId $context.rowId `
        -UserId $context.actor -ImageMode 'new' -Image ('.\' + $file.Name) -DesignFields @{ $context.field = '' }
    if (-not (Invoke-MojazEdit -Result $result -ChatId $context.actor -Quiet)) { return @{ ok = $false; error = 'bulletin_save_failed' } }
    Add-AuditEntry "Web existing bulletin picture attached by $(Format-UserAuditActor -UserId $($context.actor)) ($($context.id))"
    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $context.id
    $page = Get-MojazRowPage -Rows @(Get-JsonProp $bulletin 'Rows') -RowId $context.rowId -PageSize 20
    return @{ ok = $true; data = Get-WebBulletinEditor -Bulletin $bulletin -Page $page }
}
