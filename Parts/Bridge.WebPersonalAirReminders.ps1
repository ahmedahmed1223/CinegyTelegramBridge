#requires -Version 7

function Get-WebPersonalAirReminderActor {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if ([long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -and $actor -gt 0 -and
        (Test-Authorized -ChatId $actor -UserId $actor)) { return $actor }
}

function Get-WebPersonalAirReminderView {
    param([long]$Actor)
    $items = @(foreach ($item in @(Get-CurrentTemplateReminderActions -UserId $Actor -IncludeWebVisible | Sort-Object { [datetimeoffset]$_.At })) {
            $key = [string](Get-JsonProp $item 'TemplateKey')
            @{
                id = [string](Get-JsonProp $item 'ReminderId')
                layer = [int](Get-JsonProp $item 'Layer')
                templateLabel = Get-NewsScreenLine -Text (Protect-SensitiveText ($key -replace '[\p{Cc}\p{Zl}\p{Zp}]', ' ')) -Length 80
                elapsedMinutes = [math]::Clamp([int](Get-JsonProp $item 'Minutes'), 1, 1440)
                followUpAt = ([datetimeoffset](Get-JsonProp $item 'At')).ToUniversalTime().ToString('o')
                expiresSilently = [string](Get-JsonProp $item 'Stage') -eq 'web-visible'
            }
        })
    return @{ items = $items; snoozeMinutes = $script:TemplateReminderSnoozeMinutes }
}

function Get-WebPersonalAirReminders {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebPersonalAirReminderActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    return @{ ok = $true; data = Get-WebPersonalAirReminderView -Actor $actor }
}

function Invoke-WebPersonalAirReminderAction {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $actor = Get-WebPersonalAirReminderActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($id -cnotmatch '^[A-Za-z0-9_-]{1,48}$' -or $action -cnotin 'acknowledge', 'snooze') {
        return @{ ok = $false; error = 'reminder_invalid' }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    if ($action -ceq 'snooze') {
        $result = Set-TemplateReminderSnooze -ReminderId $id -UserId $actor -IncludeWebVisible
    }
    else {
        $reason = ''
        $confirmed = Confirm-TemplateReminder -ReminderId $id -UserId $actor -FailureReason ([ref]$reason) -RequireCurrent
        $result = @{ ok = $confirmed; error = $reason }
    }
    if (-not $result.ok) {
        $code = if ($result.error -ceq 'persistence') { 'reminder_save_failed' } else { 'reminder_stale' }
        return @{ ok = $false; error = $code }
    }
    return @{ ok = $true; data = Get-WebPersonalAirReminderView -Actor $actor }
}
