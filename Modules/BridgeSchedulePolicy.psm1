Set-StrictMode -Version Latest

function Get-SchedulePolicyProperty {
    param($Object,[Parameter(Mandatory)][string]$Name)
    if($null -eq $Object){return $null}
    if($Object -is [hashtable]){if($Object.ContainsKey($Name)){return $Object[$Name]};return $null}
    if($Object.PSObject.Properties.Match($Name).Count -gt 0){return $Object.$Name}
    return $null
}

function Get-BridgeScheduleDueState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ScheduleEntry,[datetimeoffset]$Now=[datetimeoffset]::Now)
    $scheduledAt=[datetimeoffset](Get-SchedulePolicyProperty $ScheduleEntry ScheduledAt)
    $executionKey="$([string](Get-SchedulePolicyProperty $ScheduleEntry Id))|$($scheduledAt.ToString('o'))"
    $retryText=[string](Get-SchedulePolicyProperty $ScheduleEntry NextAttemptAt)
    $dueAt=if([string]::IsNullOrWhiteSpace($retryText)){$scheduledAt}else{[datetimeoffset]$retryText}
    $completed=[string](Get-SchedulePolicyProperty $ScheduleEntry CompletedExecutionKey) -eq $executionKey
    return [pscustomobject]@{ScheduledAt=$scheduledAt;DueAt=$dueAt;ExecutionKey=$executionKey;IsDue=(-not $completed -and $dueAt -le $Now);Completed=$completed}
}

function Get-BridgeScheduleRetryDecision {
    [CmdletBinding()]
    param(
        [int]$PriorAttemptCount,
        [int]$MaxRetries,
        [int]$BaseSeconds,
        [int]$Factor=2,
        [int]$MaxDelaySeconds=300,
        [datetimeoffset]$Now=[datetimeoffset]::Now
    )
    $attempt=[math]::Max(0,$PriorAttemptCount)+1
    $retry=$attempt -le [math]::Max(0,$MaxRetries)
    if(-not $retry){return [pscustomobject]@{AttemptCount=$attempt;ShouldRetry=$false;DelaySeconds=0;NextAttemptAt=$null}}
    $base=[math]::Max(1,$BaseSeconds);$safeFactor=[math]::Max(1,$Factor);$cap=[math]::Max(1,$MaxDelaySeconds)
    $safeAttempt=[math]::Min(31,[math]::Max(1,$attempt))
    $delay=[int][math]::Min([double]$cap,[double]$base*[math]::Pow([double]$safeFactor,[double]($safeAttempt-1)))
    return [pscustomobject]@{AttemptCount=$attempt;ShouldRetry=$true;DelaySeconds=$delay;NextAttemptAt=$Now.AddSeconds($delay)}
}

Export-ModuleMember -Function Get-BridgeScheduleDueState, Get-BridgeScheduleRetryDecision
