function Get-PendingScheduledShowEvent {
    param([string]$Id)

    if (-not $Id) { return }
    foreach ($entry in $script:ScheduleEvents) {
        if ([string]$entry.Id -ceq $Id -and [string]$entry.Status -eq 'pending') { return $entry }
    }
}

function Get-ScheduledShowEventRevision {
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)

    # The revision covers shared timing changes and execution transitions.
    # Captured values can contain passwords and do not enter the public digest.
    $parts = @(
        foreach ($key in 'Id', 'MutationId', 'TemplateKey', 'Layer', 'ScheduledAt', 'TimeZoneId', 'Recurrence',
            'RecurrenceUntil', 'AnchorMaterialId', 'AnchorOffsetSeconds', 'Status', 'ChatId', 'UserId',
            'Source', 'ExecutionKey', 'CompletedExecutionKey', 'NextAttemptAt', 'AttemptCount') {
            [string](Get-JsonProp $ScheduleEntry $key)
        }
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $parts -Compress))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Test-ScheduledShowEventOwnership {
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry, [long]$ChatId, [long]$UserId)

    return ($UserId -gt 0 -and ([long](Get-JsonProp $ScheduleEntry 'UserId') -eq $UserId -or
            (Test-Admin -ChatId $ChatId -UserId $UserId)))
}

function Invoke-ScheduledShowEventMutation {
    param(
        [Parameter(Mandatory)][ValidateSet('edit', 'cancel')][string]$Operation,
        [Parameter(Mandatory)][string]$EventId,
        [Parameter(Mandatory)][string]$ExpectedRevision,
        [hashtable]$Plan
    )

    $current = Get-PendingScheduledShowEvent -Id $EventId
    if (-not $current -or (Get-ScheduledShowEventRevision -ScheduleEntry $current) -cne $ExpectedRevision) {
        return @{ ok = $false; error = 'schedule_stale' }
    }

    # Swap one copy into the canonical list for the existing atomic writer.
    # Restoring the original object also restores truly absent legacy keys.
    $candidate = $current.Clone()
    if ($Operation -eq 'cancel') {
        $candidate.Status = 'cancelled'
        $candidate.LastResult = 'cancelled by operator'
    }
    else {
        if (-not $Plan) { return @{ ok = $false; error = 'schedule_invalid' } }
        $candidate.ScheduledAt = [string]$Plan.ScheduledAt
        $candidate.TimeZoneId = [string]$Plan.TimeZoneId
        $candidate.RecurrenceUntil = [string](Get-JsonProp $Plan 'RecurrenceUntil')
        $candidate.AnchorMaterialId = ''
        $candidate.AnchorOffsetSeconds = 0
        if ([string]$current.Recurrence -eq 'once') {
            $candidate.AnchorMaterialId = [string](Get-JsonProp $Plan 'AnchorMaterialId')
            $candidate.AnchorOffsetSeconds = [int](Get-JsonProp $Plan 'AnchorOffsetSeconds')
        }
        $candidate.ExecutionKey = ''
        $candidate.CompletedExecutionKey = ''
        $candidate.NotificationExecutionKey = ''
        $candidate.NextAttemptAt = ''
        $candidate.AttemptCount = 0
        $candidate.StartedAt = ''
        $candidate.CompletedAt = ''
        $candidate.LastResult = ''
    }
    $candidate.MutationId = [guid]::NewGuid().ToString('N')
    $position = $script:ScheduleEvents.IndexOf($current)
    $script:ScheduleEvents[$position] = $candidate
    if (-not (Save-ScheduleEvents)) {
        $script:ScheduleEvents[$position] = $current
        return @{ ok = $false; error = 'schedule_save_failed' }
    }
    # Preserve the entry references already held by the Bot and scheduler.
    # Publish the changes to them only after the atomic save has succeeded.
    foreach ($entryKey in $candidate.Keys) { $current[$entryKey] = $candidate[$entryKey] }
    $script:ScheduleEvents[$position] = $current
    return @{ ok = $true; entry = $current }
}
