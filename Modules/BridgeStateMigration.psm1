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
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
        return $result
    }
    catch { return [pscustomobject]@{ Success = $false; Version = 0; Data = $null; Error = $_.Exception.Message } }
}

Export-ModuleMember -Function ConvertTo-BridgeStateEnvelope, Invoke-BridgeStateMigration, Invoke-BridgeStateFileMigration
