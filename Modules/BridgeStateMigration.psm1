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

Export-ModuleMember -Function ConvertTo-BridgeStateEnvelope, Invoke-BridgeStateMigration
