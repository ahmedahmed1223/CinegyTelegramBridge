#requires -Version 7
Set-StrictMode -Version Latest

function New-BridgeOperationRecord {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][int]$Layer, [long]$ActorId = 0, [string]$SceneId = '')
    $scope = Get-BridgeOperationScope -Action $Action
    [pscustomobject]@{ OperationId = "op-$(([guid]::NewGuid().ToString('N')).Substring(0,12))"; Action = $scope.Action; TargetScope = $scope.Scope; Layer = $Layer; SceneId = $SceneId; ActorId = $ActorId; State = 'queued'; QueuedAtUtc = [datetime]::UtcNow; StartedAtUtc = $null; EndedAtUtc = $null; Result = ''; Error = '' }
}

function Set-BridgeOperationState {
    param([Parameter(Mandatory)]$Operation, [Parameter(Mandatory)][ValidateSet('queued','running','succeeded','warning','failed')][string]$State)
    $allowed = @{ queued = @('running','failed'); running = @('succeeded','warning','failed'); succeeded = @(); warning = @(); failed = @() }
    if ($allowed[$Operation.State] -notcontains $State) { throw "Invalid operation transition '$($Operation.State)' -> '$State'." }
    $Operation.State = $State
    if ($State -eq 'running') { $Operation.StartedAtUtc = [datetime]::UtcNow } else { $Operation.EndedAtUtc = [datetime]::UtcNow }
    return $Operation
}

function New-BridgeOperationLedger {
    param([ValidateRange(1, 4096)][int]$Capacity = 4096)
    return @{ Capacity = $Capacity; Records = [System.Collections.Generic.List[object]]::new() }
}

function Queue-BridgeOperation {
    param(
        [Parameter(Mandatory)][hashtable]$Ledger,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][int]$Layer,
        [long]$ActorId = 0,
        [string]$SceneId = ''
    )
    while ($Ledger.Records.Count -ge [int]$Ledger.Capacity) { $Ledger.Records.RemoveAt(0) }
    $operation = New-BridgeOperationRecord -Action $Action -Layer $Layer -ActorId $ActorId -SceneId $SceneId
    $operation.OperationId = $OperationId
    $Ledger.Records.Add($operation)
    return $operation
}

function Start-BridgeOperation {
    param(
        [Parameter(Mandatory)][hashtable]$Ledger,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][int]$Layer,
        [long]$ActorId = 0,
        [string]$SceneId = ''
    )
    $operation = Get-BridgeOperationRecord -Ledger $Ledger -OperationId $OperationId
    if ($null -eq $operation) {
        $operation = Queue-BridgeOperation -Ledger $Ledger -OperationId $OperationId -Action $Action -Layer $Layer -ActorId $ActorId -SceneId $SceneId
    }
    else {
        $operation.Layer = $Layer
        $operation.ActorId = $ActorId
        if ($SceneId) { $operation.SceneId = $SceneId }
    }
    Set-BridgeOperationState -Operation $operation -State running | Out-Null
    return $operation
}

function Complete-BridgeOperation {
    param(
        [Parameter(Mandatory)][hashtable]$Ledger,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][ValidateSet('success','failed','blocked','warning')][string]$Result,
        [string]$ErrorText = ''
    )
    $operation = $Ledger.Records | Where-Object { $_.OperationId -eq $OperationId } | Select-Object -Last 1
    if ($null -eq $operation) { return $null }
    $terminal = switch ($Result) { 'success' { 'succeeded' }; 'warning' { 'warning' }; default { 'failed' } }
    Set-BridgeOperationState -Operation $operation -State $terminal | Out-Null
    $operation.Result = $Result
    $operation.Error = $ErrorText
    return $operation
}

function Get-BridgeOperationRecord {
    param([Parameter(Mandatory)][hashtable]$Ledger, [Parameter(Mandatory)][string]$OperationId)
    return $Ledger.Records | Where-Object { $_.OperationId -eq $OperationId } | Select-Object -Last 1
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
    $supported = @('show', 'hide', 'hide-layer', 'exit', 'exit-layer', 'replace', 'clear', 'hide-all', 'update')
    if ($normalized -notin $supported) { throw "Unsupported Cinegy operation '$Action'." }
    return [pscustomobject]@{ Action = $normalized; Scope = 'LayerExclusive'; SerializedByLayer = $true }
}

function Get-BridgeOperationStatusText {
    param([Parameter(Mandatory)]$Operation)
    $labels = @{ queued = 'قيد الانتظار'; running = 'قيد التنفيذ'; succeeded = 'اكتملت'; warning = 'اكتملت بتحذير'; failed = 'فشلت' }
    $label = if ($labels.ContainsKey([string]$Operation.State)) { $labels[[string]$Operation.State] } else { [string]$Operation.State }
    return "🔖 $($Operation.OperationId) · الطبقة $($Operation.Layer) · $label"
}

Export-ModuleMember -Function New-BridgeOperationRecord, Set-BridgeOperationState, New-BridgeOperationLedger, Queue-BridgeOperation, Start-BridgeOperation, Complete-BridgeOperation, Get-BridgeOperationRecord, New-BridgeSceneCallbackToken, Resolve-BridgeSceneCallbackToken, Get-BridgeOperationScope, Get-BridgeOperationStatusText
