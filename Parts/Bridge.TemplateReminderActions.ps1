#requires -Version 7

$script:TemplateReminderSnoozeMinutes = 5
$script:TemplateReminderWebWindowMinutes = 5

function Publish-WebTemplateReminder {
    param([hashtable]$Item, [int]$Index, [datetimeoffset]$Now)
    $visible = $Item.Clone()
    if (-not [string](Get-JsonProp $visible 'ReminderId')) {
        $visible.ReminderId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    }
    $visible.Stage = 'web-visible'
    $visible.At = $Now.AddMinutes($script:TemplateReminderWebWindowMinutes)
    $visible.FollowUpMinutes = 0
    $script:TemplateReminderQueue[$Index] = $visible
    if (-not (Save-TemplateReminderQueue)) {
        $script:TemplateReminderQueue[$Index] = $Item
        return
    }
    return $visible
}

function Get-CurrentTemplateReminderActions {
    param([long]$UserId, [datetimeoffset]$Now = [datetimeoffset]::Now, [switch]$IncludeWebVisible)
    if ($UserId -le 0) { return }
    foreach ($item in $script:TemplateReminderQueue) {
        if ([long](Get-JsonProp $item 'UserId') -ne $UserId) { continue }
        $stage = [string](Get-JsonProp $item 'Stage')
        if ($stage -ne 'followup' -and (-not $IncludeWebVisible -or $stage -ne 'web-visible')) { continue }
        $id = [string](Get-JsonProp $item 'ReminderId')
        $deadline = [datetimeoffset]::MinValue
        if ($id -cnotmatch '^[A-Za-z0-9_-]{1,48}$' -or
            -not [datetimeoffset]::TryParse([string](Get-JsonProp $item 'At'), [ref]$deadline) -or $deadline -le $Now) { continue }
        if ((Get-TemplateReminderTargetDecision -Reminder $item).ShouldNotify) { $item }
    }
}

function Set-TemplateReminderSnooze {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ReminderId, [Parameter(Mandatory)][long]$UserId,
        [datetimeoffset]$Now = [datetimeoffset]::Now, [switch]$IncludeWebVisible)

    if ($ReminderId -cnotmatch '^[A-Za-z0-9_-]{1,48}$') { return @{ ok = $false; error = 'not_found' } }
    $item = Get-CurrentTemplateReminderActions -UserId $UserId -Now $Now -IncludeWebVisible:$IncludeWebVisible |
        Where-Object { [string](Get-JsonProp $_ 'ReminderId') -ceq $ReminderId } | Select-Object -First 1
    if (-not $item) { return @{ ok = $false; error = 'not_found' } }

    # Stage the replacement as one row so the persisted queue, both clients
    # and any old chat buttons agree on the current reminder identity.
    $index = $script:TemplateReminderQueue.IndexOf($item)
    $replacement = $item.Clone()
    $replacement.ReminderId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $replacement.Stage = 'initial'
    $replacement.At = $Now.AddMinutes($script:TemplateReminderSnoozeMinutes)
    $replacement.Minutes = [int][math]::Clamp(([long](Get-JsonProp $item 'Minutes') + $script:TemplateReminderSnoozeMinutes), 1L, 1440L)
    $script:TemplateReminderQueue[$index] = $replacement
    if (-not (Save-TemplateReminderQueue)) {
        $script:TemplateReminderQueue[$index] = $item
        return @{ ok = $false; error = 'persistence' }
    }
    return @{ ok = $true }
}
