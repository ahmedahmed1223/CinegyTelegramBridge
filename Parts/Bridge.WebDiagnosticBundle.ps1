function ConvertTo-WebDiagnosticTimelineEntry {
    param([string]$Line)

    $match = [regex]::Match($Line, '\A(?<at>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) \[(?<severity>INFO|WARN|ERROR)\] (?<event>.*)\z')
    if (-not $match.Success) { return }
    $at = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($match.Groups['at'].Value, 'yyyy-MM-dd HH:mm:ss',
            [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$at)) { return }

    $severity = $match.Groups['severity'].Value.ToLowerInvariant()
    $message = $match.Groups['event'].Value
    $action = ''
    $outcome = ''
    $category = switch -Regex ($message) {
        '\AAIR_OP id=air-[a-f0-9]{32} action=(SHOW|HIDE|EXIT|UPDATE) result=(success|failed|blocked)(?:\s|$)' {
            $action = $Matches[1].ToUpperInvariant()
            $outcome = $Matches[2].ToLowerInvariant()
            'air'
            break
        }
        '\A(?:Cinegy |Titler )' { 'cinegy'; break }
        '\ATelegram ' { 'telegram'; break }
        '\A(?:Output monitor|Output brightness)' { 'feed'; break }
        '\A(?:Live relay |Relay |User [0-9]+ (?:started live relay|requested live relay stop))' { 'relay'; break }
        '\A(?:Scheduled |Could not (?:write|read) schedule\.json|Could not append schedule execution)' { 'schedule'; break }
        '\A(?:Web channel |Bridge starting|Bridge stopped|Tick step )' { 'runtime'; break }
        default { if ($severity -in 'warn', 'error') { 'other' } }
    }
    if (-not $category) { return }
    return @{ atMs = ([datetimeoffset]$at).ToUnixTimeMilliseconds(); severity = $severity; category = $category; action = $action; outcome = $outcome }
}

function Read-WebDiagnosticTimeline {
    param([string]$Path)

    # Reading a byte window avoids Get-Content -Tail scanning an oversized
    # runtime line or entire file on the same thread as air-control commands.
    $byteLimit = 128KB
    $lineLimit = 200
    $lines = @()
    $truncated = $false
    $state = 'missing'
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $state = 'unavailable'
        }
        else {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
            try {
                $length = $stream.Length
                $size = [int][math]::Min($length, [long]$byteLimit)
                $offset = $length - $size
                [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
                $bytes = [byte[]]::new($size)
                $stream.ReadExactly($bytes)
                $text = [Text.Encoding]::UTF8.GetString($bytes)
                $lines = @($text.TrimStart([char]0xfeff) -split '\r?\n')
                if ($offset -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
                $lines = @($lines | Where-Object { $_ })
                $truncated = $offset -gt 0 -or $lines.Count -gt $lineLimit
                $state = 'available'
            }
            finally { $stream.Dispose() }
        }
    }
    catch [System.Management.Automation.ItemNotFoundException] { $state = 'missing' }
    catch { $state = 'unavailable' }

    return @{ state = $state; truncated = $truncated; byteLimit = $byteLimit; lineLimit = $lineLimit; items = @(
            $lines | Select-Object -Last $lineLimit | ForEach-Object { ConvertTo-WebDiagnosticTimelineEntry -Line $_ }
        ) }
}

function Get-WebDiagnosticBundle {
    param([System.Collections.IDictionary]$Arguments, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $metrics = Get-BridgeDiagnosticResources
    return @{ ok = $true; data = @{
            schemaVersion = 1
            generatedAtMs = $Now.ToUnixTimeMilliseconds()
            bridgeVersion = $script:BridgeVersion
            powershellVersion = [string]$PSVersionTable.PSVersion
            uptimeSeconds = [long][math]::Max(0.0, $metrics.Uptime.TotalSeconds)
            workingSetMB = [double]$metrics.WorkingSetMB
            privateMemoryMB = [double]$metrics.PrivateMemoryMB
            diskFreeGB = $metrics.DiskFreeGB
            lowDisk = $null -ne $metrics.DiskFreeGB -and $metrics.DiskFreeGB -lt (Get-SettingInt 'DiskFreeWarningGB' 1)
            airOperations = @{ success = $metrics.AirOperations.Success; failed = $metrics.AirOperations.Failed; blocked = $metrics.AirOperations.Blocked }
            runtimeFiles = (Get-WebRuntimeFileDiagnostics -Arguments $Arguments -Now $Now).data
            timeline = Read-WebDiagnosticTimeline -Path $script:logPath
        } }
}
