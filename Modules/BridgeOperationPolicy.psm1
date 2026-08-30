Set-StrictMode -Version Latest

function New-BridgeUpdateLedger {
    [CmdletBinding()]
    param([ValidateRange(1, 65536)][int]$Capacity = 4096)

    return @{
        Capacity = $Capacity
        Seen = [System.Collections.Generic.HashSet[long]]::new()
        Order = [System.Collections.Generic.Queue[long]]::new()
    }
}

function Test-BridgeUpdateAdmission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Ledger,
        [Parameter(Mandatory)][long]$UpdateId
    )

    if ($Ledger.Seen.Contains($UpdateId)) { return $false }
    while ($Ledger.Order.Count -ge [int]$Ledger.Capacity) {
        $expired = $Ledger.Order.Dequeue()
        [void]$Ledger.Seen.Remove($expired)
    }
    [void]$Ledger.Seen.Add($UpdateId)
    $Ledger.Order.Enqueue($UpdateId)
    return $true
}

function Get-BridgeUpdatePriority {
    param([Parameter(Mandatory)]$Update)
    $callback = $Update.PSObject.Properties['callback_query']
    $data = ''
    if ($callback -and $callback.Value) {
        $dataProperty = $callback.Value.PSObject.Properties['data']
        if ($dataProperty) { $data = [string]$dataProperty.Value }
    }

    if ($data -match '^(hide:|hidego:|exit:|exitgo:|menu:hideall$|hideall:)') { return 0 }
    if ($data -match '^(tpl:|showgo:|timed:|timer:|update:|rollback:|preset:)') { return 1 }
    return 2
}

function Get-BridgeUpdateScope {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Update)

    $callback = $Update.PSObject.Properties['callback_query']
    if (-not $callback -or -not $callback.Value) {
        return [pscustomobject]@{ Kind = 'unknown'; Layer = $null }
    }
    $dataProperty = $callback.Value.PSObject.Properties['data']
    $data = if ($dataProperty) { [string]$dataProperty.Value } else { '' }
    if ($data -match '^(menu:hideall|hideall:)$') {
        return [pscustomobject]@{ Kind = 'global'; Layer = $null }
    }
    if ($data -match '^(?:hide|hidego|exit|exitgo|showgo):(?<layer>\d+)$') {
        return [pscustomobject]@{ Kind = 'layer'; Layer = [int]$Matches.layer }
    }
    return [pscustomobject]@{ Kind = 'unknown'; Layer = $null }
}

function Test-BridgeIndependentUpdateScopes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )
    return $Left.Kind -eq 'layer' -and $Right.Kind -eq 'layer' -and [int]$Left.Layer -ne [int]$Right.Layer
}

function Get-BridgeUpdatesForProcessing {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Updates = @())

    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($update in $Updates) {
        $candidate = [pscustomobject]@{
            Update = $update
            Priority = Get-BridgeUpdatePriority -Update $update
            Scope = Get-BridgeUpdateScope -Update $update
        }
        $insertAt = $ordered.Count
        if ($candidate.Priority -eq 0) {
            while ($insertAt -gt 0) {
                $previous = $ordered[$insertAt - 1]
                if ($previous.Priority -eq 0 -or -not (Test-BridgeIndependentUpdateScopes -Left $candidate.Scope -Right $previous.Scope)) { break }
                $insertAt--
            }
        }
        $ordered.Insert($insertAt, $candidate)
    }
    return @($ordered | ForEach-Object Update)
}

Export-ModuleMember -Function New-BridgeUpdateLedger, Test-BridgeUpdateAdmission, Get-BridgeUpdateScope, Get-BridgeUpdatesForProcessing
