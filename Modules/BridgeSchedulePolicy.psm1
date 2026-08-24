Set-StrictMode -Version Latest

function Test-BridgeQuietHour {
    <#
        Whether a non-urgent notification should be held rather than sent now.

        A bridge that pages at 03:00 about a template it could not verify
        teaches operators to mute it, and a muted bot is worse than a silent
        one: the alert that mattered then arrives to a muted chat. Non-urgent
        traffic is batched overnight and delivered in one message when someone
        is actually awake.

        Windows that cross midnight are the normal case - 23:00 to 06:00 is
        what a night shift really looks like - so the wrap is handled
        explicitly rather than assumed away.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0, 23)][int]$Hour,
        [ValidateRange(0, 23)][int]$StartHour = 1,
        [ValidateRange(0, 23)][int]$EndHour = 6
    )
    if ($StartHour -eq $EndHour) { return $false }
    if ($StartHour -lt $EndHour) { return ($Hour -ge $StartHour -and $Hour -lt $EndHour) }
    return ($Hour -ge $StartHour -or $Hour -lt $EndHour)
}

function Test-BridgeMaintenanceWindow {
    <#
        Whether an automatic maintenance window is open right now.

        Playout machines get patched, restarted and re-cabled on a fixed
        overnight slot. During it the bridge should not be pushing graphics,
        nor raising alarms about an engine that is deliberately down. Same
        midnight-wrapping rule as quiet hours. An unset or malformed window is
        no window at all - it must never fail closed and silently block
        control of a live channel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Now,
        [string]$StartTime = '',
        [string]$EndTime = ''
    )
    if ([string]::IsNullOrWhiteSpace($StartTime) -or [string]::IsNullOrWhiteSpace($EndTime)) { return $false }
    $start = [timespan]::Zero; $end = [timespan]::Zero
    if (-not [timespan]::TryParse($StartTime, [ref]$start)) { return $false }
    if (-not [timespan]::TryParse($EndTime, [ref]$end)) { return $false }
    if ($start -eq $end) { return $false }
    $current = $Now.TimeOfDay
    if ($start -lt $end) { return ($current -ge $start -and $current -lt $end) }
    return ($current -ge $start -or $current -lt $end)
}

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

Export-ModuleMember -Function Test-BridgeQuietHour, Test-BridgeMaintenanceWindow, Get-BridgeScheduleDueState, Get-BridgeScheduleRetryDecision
