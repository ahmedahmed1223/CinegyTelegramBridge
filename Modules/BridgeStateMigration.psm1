Set-StrictMode -Version Latest

function ConvertTo-BridgeStateEnvelope {
    [CmdletBinding()]
    param(
        [AllowNull()]$Data,
        [ValidateRange(0, [int]::MaxValue)][int]$Version
    )
    return [pscustomobject]@{ SchemaVersion = $Version; Data = $Data }
}

function Invoke-BridgeStateMigration {
    [CmdletBinding()]
    param(
        [AllowNull()]$Document,
        [ValidateRange(0, [int]::MaxValue)][int]$TargetVersion,
        [Parameter(Mandatory)][hashtable]$Migrations
    )

    $version = 0
    $data = $Document
    if ($null -ne $Document -and $Document.PSObject.Properties['SchemaVersion'] -and $Document.PSObject.Properties['Data']) {
        $version = [int]$Document.SchemaVersion
        $data = $Document.Data
    }
    if ($version -gt $TargetVersion) {
        return [pscustomobject]@{ Success = $false; Version = $version; Data = $null; Error = "State version $version is newer than supported target $TargetVersion." }
    }

    try {
        while ($version -lt $TargetVersion) {
            if (-not $Migrations.ContainsKey($version)) {
                return [pscustomobject]@{ Success = $false; Version = $version; Data = $null; Error = "Missing migration step for version $version." }
            }
            $data = & $Migrations[$version] $data
            $version++
        }
        return [pscustomobject]@{ Success = $true; Version = $version; Data = $data; Error = '' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Version = $version; Data = $null; Error = $_.Exception.Message }
    }
}

function Invoke-BridgeStateFileMigration {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$TargetVersion, [Parameter(Mandatory)][hashtable]$Migrations)
    try {
        $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $result = Invoke-BridgeStateMigration -Document $document -TargetVersion $TargetVersion -Migrations $Migrations
        if (-not $result.Success) { return $result }
        $envelope = ConvertTo-BridgeStateEnvelope -Data $result.Data -Version $result.Version
        $temporary = "$Path.migrate.tmp"
        $envelope | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
        $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
        $backupPath = "$Path.$stamp.bak"
        Copy-Item -LiteralPath $Path -Destination $backupPath -ErrorAction Stop
        Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
        return [pscustomobject]@{ Success = $true; Version = $result.Version; Data = $result.Data; Error = ''; BackupPath = $backupPath }
    }
    catch {
        $temporary = "$Path.migrate.tmp"
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        return [pscustomobject]@{ Success = $false; Version = 0; Data = $null; Error = $_.Exception.Message; BackupPath = '' }
    }
}

function Get-BridgeRuntimeFileHealth {
    param([Parameter(Mandatory)][string]$Path)
    $healthy = $false
    $schemaVersion = 0
    $errorText = ''
    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($file) {
        try {
            $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($document.PSObject.Properties['SchemaVersion']) { $schemaVersion = [int]$document.SchemaVersion }
            $healthy = $true
        }
        catch { $errorText = $_.Exception.Message }
    }
    else { $errorText = 'File does not exist.' }

    $backup = Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Filter "$([IO.Path]::GetFileName($Path)).*.bak" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $backupHealthy = $false
    if ($backup) {
        try { Get-Content -LiteralPath $backup.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null; $backupHealthy = $true } catch { $backupHealthy = $false }
    }
    return [pscustomobject]@{
        Path = $Path; Healthy = $healthy; SizeBytes = if ($file) { $file.Length } else { 0 }
        LastWriteTimeUtc = if ($file) { $file.LastWriteTimeUtc } else { $null }
        SchemaVersion = $schemaVersion; BackupPath = if ($backup) { $backup.FullName } else { '' }
        BackupHealthy = $backupHealthy; Error = $errorText
    }
}

Export-ModuleMember -Function ConvertTo-BridgeStateEnvelope, Invoke-BridgeStateMigration, Invoke-BridgeStateFileMigration, Get-BridgeRuntimeFileHealth
