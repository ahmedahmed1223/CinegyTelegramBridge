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

function Get-BridgeUpdatesForProcessing {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Updates = @())

    $index = 0
    return @($Updates | ForEach-Object {
            [pscustomobject]@{
                Update = $_
                Priority = Get-BridgeUpdatePriority -Update $_
                OriginalIndex = $index++
            }
        } | Sort-Object Priority, OriginalIndex | ForEach-Object Update)
}

Export-ModuleMember -Function New-BridgeUpdateLedger, Test-BridgeUpdateAdmission, Get-BridgeUpdatesForProcessing
