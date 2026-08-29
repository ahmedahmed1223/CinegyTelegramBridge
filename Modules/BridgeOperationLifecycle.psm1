#requires -Version 7
Set-StrictMode -Version Latest

function New-BridgeOperationRecord {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][int]$Layer, [long]$ActorId = 0, [string]$SceneId = '')
    [pscustomobject]@{ OperationId = "op-$(([guid]::NewGuid().ToString('N')).Substring(0,12))"; Action = $Action; Layer = $Layer; SceneId = $SceneId; ActorId = $ActorId; State = 'queued'; QueuedAtUtc = [datetime]::UtcNow; StartedAtUtc = $null; EndedAtUtc = $null; Error = '' }
}

function Set-BridgeOperationState {
    param([Parameter(Mandatory)]$Operation, [Parameter(Mandatory)][ValidateSet('queued','running','succeeded','warning','failed')][string]$State)
    $allowed = @{ queued = @('running','failed'); running = @('succeeded','warning','failed'); succeeded = @(); warning = @(); failed = @() }
    if ($allowed[$Operation.State] -notcontains $State) { throw "Invalid operation transition '$($Operation.State)' -> '$State'." }
    $Operation.State = $State
    if ($State -eq 'running') { $Operation.StartedAtUtc = [datetime]::UtcNow } else { $Operation.EndedAtUtc = [datetime]::UtcNow }
    return $Operation
}

function New-BridgeSceneCallbackToken {
    param([Parameter(Mandatory)][hashtable]$Store, [Parameter(Mandatory)][string]$SceneId, [Parameter(Mandatory)][int]$Layer, [datetime]$Now = [datetime]::UtcNow, [int]$LifetimeSeconds = 300)
    $token = ([guid]::NewGuid().ToString('N')).Substring(0,12)
    $Store[$token] = [pscustomobject]@{ SceneId = $SceneId; Layer = $Layer; ExpiresAtUtc = $Now.ToUniversalTime().AddSeconds($LifetimeSeconds) }
    return $token
}

function Resolve-BridgeSceneCallbackToken {
    param([Parameter(Mandatory)][hashtable]$Store, [Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][int]$Layer, [datetime]$Now = [datetime]::UtcNow)
    if (-not $Store.ContainsKey($Token)) { return $null }
    $entry = $Store[$Token]
    if ($entry.Layer -ne $Layer -or $entry.ExpiresAtUtc -le $Now.ToUniversalTime()) { return $null }
    return $entry
}

function Get-BridgeOperationScope {
    param([Parameter(Mandatory)][string]$Action)
    $normalized = $Action.Trim().ToLowerInvariant()
    $scope = if ($normalized -in @('scene-hide', 'scene-exit', 'scene-update')) { 'SceneSpecific' } else { 'LayerExclusive' }
    return [pscustomobject]@{ Action = $normalized; Scope = $scope; SerializedByLayer = $true }
}

Export-ModuleMember -Function New-BridgeOperationRecord, Set-BridgeOperationState, New-BridgeSceneCallbackToken, Resolve-BridgeSceneCallbackToken, Get-BridgeOperationScope
