Set-StrictMode -Version Latest

function Get-BridgeRelayWatchdogDecision {
    [CmdletBinding()]
    param(
        [switch]$ShouldRun,
        [switch]$HasRunningProcess,
        [switch]$AutoRestart,
        [int]$Restarts,
        [int]$MaxRestarts,
        [datetime]$LastCheck,
        [int]$IntervalSeconds,
        [datetime]$Now=(Get-Date)
    )
    $safeRestarts=[math]::Max(0,$Restarts)
    if(-not $ShouldRun){return [pscustomobject]@{Action='idle';Restarts=$safeRestarts;CheckedAt=$LastCheck}}
    $interval=[math]::Max(1,$IntervalSeconds)
    if(($Now-$LastCheck).TotalSeconds -lt $interval){return [pscustomobject]@{Action='wait';Restarts=$safeRestarts;CheckedAt=$LastCheck}}
    if($HasRunningProcess){return [pscustomobject]@{Action='running';Restarts=$safeRestarts;CheckedAt=$Now}}
    if(-not $AutoRestart){return [pscustomobject]@{Action='stay_down';Restarts=$safeRestarts;CheckedAt=$Now}}
    $maximum=[math]::Max(0,$MaxRestarts)
    if($safeRestarts -ge $maximum){return [pscustomobject]@{Action='give_up';Restarts=$safeRestarts;CheckedAt=$Now}}
    return [pscustomobject]@{Action='restart';Restarts=($safeRestarts+1);CheckedAt=$Now}
}

Export-ModuleMember -Function Get-BridgeRelayWatchdogDecision
