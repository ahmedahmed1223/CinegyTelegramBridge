Set-StrictMode -Version Latest

function Find-BridgePendingFlowKey {
    param([Parameter(Mandatory)][hashtable]$Store, [Parameter(Mandatory)][long]$ChatId)
    if ($Store.ContainsKey($ChatId)) { return $ChatId }
    $text=[string]$ChatId
    if ($Store.ContainsKey($text)) { return $text }
    foreach ($candidate in @($Store.Keys)) {
        $numeric=0L
        if ([long]::TryParse([string]$candidate,[ref]$numeric) -and $numeric -eq $ChatId) { return $candidate }
    }
    return $null
}

function Set-BridgePendingFlow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][hashtable]$State,
        [datetime]$Now=(Get-Date)
    )
    $State.StartedAt=$Now
    $Store[$ChatId]=$State
}

function Get-BridgePendingFlow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Store,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][ValidateRange(1,1440)][int]$TimeoutMinutes,
        [datetime]$Now=(Get-Date)
    )
    $key=Find-BridgePendingFlowKey -Store $Store -ChatId $ChatId
    if ($null -eq $key) { return [pscustomobject]@{State=$null;Expired=$false} }
    $state=$Store[$key]
    if (($Now-[datetime]$state.StartedAt).TotalMinutes -ge $TimeoutMinutes) {
        $Store.Remove($key)
        return [pscustomobject]@{State=$state;Expired=$true}
    }
    return [pscustomobject]@{State=$state;Expired=$false}
}

function Remove-BridgePendingFlow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Store,[Parameter(Mandatory)][long]$ChatId)
    $key=Find-BridgePendingFlowKey -Store $Store -ChatId $ChatId
    if ($null -eq $key) { return $null }
    $state=$Store[$key]
    $Store.Remove($key)
    return $state
}

Export-ModuleMember -Function Set-BridgePendingFlow, Get-BridgePendingFlow, Remove-BridgePendingFlow
