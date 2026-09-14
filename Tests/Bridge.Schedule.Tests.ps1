#requires -Version 7
<#
    Bridge.Schedule.Tests.ps1 - Scheduled shows, conflicts, retries, and quiet hours.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Reliable schedule store and executor' {
    BeforeEach {
        $script:OriginalScheduleMaxRetries = Get-Setting 'ScheduleMaxRetries'
        $script:OriginalScheduleRetryDelaySeconds = Get-Setting 'ScheduleRetryDelaySeconds'
        $script:OriginalSchedulePaused = Get-Setting 'SchedulePaused'
        $script:OriginalSchedulePreNotifyMinutes = Get-Setting 'SchedulePreNotifyMinutes'
        $config.Settings | Add-Member -NotePropertyName ScheduleMaxRetries -NotePropertyValue 0 -Force
        $config.Settings | Add-Member -NotePropertyName ScheduleRetryDelaySeconds -NotePropertyValue 30 -Force
        $config.Settings | Add-Member -NotePropertyName SchedulePaused -NotePropertyValue $false -Force
        $config.Settings | Add-Member -NotePropertyName SchedulePreNotifyMinutes -NotePropertyValue 0 -Force
        $script:OriginalScheduleFileForTest = $script:scheduleFile
        $script:OriginalScheduleExecutionFileForTest = $script:scheduleExecutionFile
        $script:scheduleFile = Join-Path $TestDrive 'schedule.json'
        $script:scheduleExecutionFile = Join-Path $TestDrive 'schedule-execution.jsonl'
        Remove-Item -LiteralPath $script:scheduleExecutionFile -Force -ErrorAction SilentlyContinue
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Get-TemplateStore {
            [pscustomobject]@{
                Map = @{
                    urgent = [pscustomobject]@{
                        Key = 'urgent'; Path = 'C:\Scenes\Urgent.cintitle'; Layer = 4
                        Fields = @('Headline.Text'); FieldTypes = @{}; LongRunning = $false
                    }
                }
                Order = @('urgent'); Errors = @(); InvalidKeys = @(); SharedLayers = @{}
            }
        }
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName ScheduleMaxRetries -NotePropertyValue $script:OriginalScheduleMaxRetries -Force
        $config.Settings | Add-Member -NotePropertyName ScheduleRetryDelaySeconds -NotePropertyValue $script:OriginalScheduleRetryDelaySeconds -Force
        $config.Settings | Add-Member -NotePropertyName SchedulePaused -NotePropertyValue $script:OriginalSchedulePaused -Force
        $config.Settings | Add-Member -NotePropertyName SchedulePreNotifyMinutes -NotePropertyValue $script:OriginalSchedulePreNotifyMinutes -Force
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        $script:scheduleFile = $script:OriginalScheduleFileForTest
        $script:scheduleExecutionFile = $script:OriginalScheduleExecutionFileForTest
    }

    It 'persists and restores a pending event with a stable id and timezone' {
        $at = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{ 'Headline.Text' = 'مجدول' } -ScheduledAt $at -Recurrence once -ChatId 1 -UserId 2
        Add-ScheduledShowEvent -ScheduleEntry $scheduleEntry | Should -BeTrue
        $id = $scheduleEntry.Id
        $script:ScheduleEvents.Clear()

        Import-ScheduleEvents

        $script:ScheduleEvents.Count | Should -Be 1
        $script:ScheduleEvents[0].Id | Should -Be $id
        $script:ScheduleEvents[0].TimeZoneId | Should -Not -BeNullOrEmpty
    }

    It 'restores a pending event after a simulated restart and executes it at its timer once' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{ 'Headline.Text' = 'بعد إعادة التشغيل' } `
            -ScheduledAt $now.AddMinutes(5) -Recurrence once -ChatId 1 -UserId 2
        Add-ScheduledShowEvent -ScheduleEntry $scheduleEntry | Should -BeTrue

        # A fresh bridge process starts with an empty in-memory queue and imports
        # the durable schedule before its first timer tick.
        $script:ScheduleEvents.Clear()
        Import-ScheduleEvents
        Update-ScheduleQueue -Now $now.AddMinutes(4)

        $script:ScheduleEvents[0].Status | Should -Be 'pending'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly

        Update-ScheduleQueue -Now $now.AddMinutes(5)
        Update-ScheduleQueue -Now $now.AddMinutes(6)

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $script:ScheduleEvents[0].Status | Should -Be 'completed'
        $script:ScheduleEvents[0].LastTemplateCheckStatus | Should -Be 'ready'
        $persisted = Get-Content -LiteralPath $script:scheduleFile -Raw | ConvertFrom-Json
        $persisted[0].LastTemplateCheckStatus | Should -Be 'ready'
    }

    It 'checks the current template registry at timer execution and does not SHOW a missing template' {
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{}; Order = @(); Errors = @('القالب غير موجود'); InvalidKeys = @(); SharedLayers = @{} }
        }
        Mock Send-TelegramMessage { }
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} `
            -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now

        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        $scheduleEntry.LastTemplateCheckStatus | Should -Be 'missing'
        $scheduleEntry.Status | Should -Be 'failed'
        $scheduleEntry.LastResult | Should -Match 'غير موجود'
    }

    It 'restores scheduled events from the last validated backup when the primary JSON is corrupt' {
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt ([datetimeoffset]'2026-08-21T10:00:00+03:00') -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($entry)
        Save-ScheduleEvents | Should -BeTrue
        Test-Path -LiteralPath "$($script:scheduleFile).bak" | Should -BeTrue
        Set-Content -LiteralPath $script:scheduleFile -Value '[broken-json'
        $script:ScheduleEvents.Clear()

        Import-ScheduleEvents

        $script:ScheduleEvents.Count | Should -Be 1
        $script:ScheduleEvents[0].Id | Should -Be $entry.Id
        { Get-Content -LiteralPath $script:scheduleFile -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'copies an event to a new reviewed time without changing the original' {
        Mock Send-TelegramMessage { }
        $originalAt = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Layer 4 -Values @{ Headline = 'copy' } -ScheduledAt $originalAt -Recurrence daily -ChatId 101 -UserId 101
        $script:ScheduleEvents.Add($entry)

        Start-ScheduleMutationFlow -Action copy -EventId $entry.Id -ChatId 101 -UserId 101
        Complete-ScheduleText -ChatId 101 -Value '2099-08-22 11:30'
        Confirm-ScheduledShow -ChatId 101 -UserId 101

        $script:ScheduleEvents.Count | Should -Be 2
        $script:ScheduleEvents[0].Id | Should -Be $entry.Id
        $script:ScheduleEvents[0].ScheduledAt | Should -Be $originalAt.ToString('o')
        $copy = @($script:ScheduleEvents | Where-Object Id -ne $entry.Id)[0]
        $copy.TemplateKey | Should -Be 'urgent'
        $copy.Values.Headline | Should -Be 'copy'
        $copy.Recurrence | Should -Be 'daily'
    }

    It 'edits only the reviewed event time and preserves its stable id' {
        Mock Send-TelegramMessage { }
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Layer 4 -Values @{} -ScheduledAt ([datetimeoffset]'2099-08-21T10:00:00+03:00') -Recurrence once -ChatId 101 -UserId 101
        $script:ScheduleEvents.Add($entry)

        Start-ScheduleMutationFlow -Action edit -EventId $entry.Id -ChatId 101 -UserId 101
        Complete-ScheduleText -ChatId 101 -Value '2099-08-23 12:45'
        Confirm-ScheduledShow -ChatId 101 -UserId 101

        $script:ScheduleEvents.Count | Should -Be 1
        $script:ScheduleEvents[0].Id | Should -Be $entry.Id
        ([datetimeoffset]$script:ScheduleEvents[0].ScheduledAt).ToString('yyyy-MM-dd HH:mm') | Should -Be '2099-08-23 12:45'
        $script:ScheduleEvents[0].TimeZoneId | Should -Be ([System.TimeZoneInfo]::Local.Id)
    }

    It 'includes the timezone id in event summaries' {
        $entry = New-ScheduledShowEvent -TemplateKey urgent -ScheduledAt ([datetimeoffset]'2099-08-21T10:00:00+03:00') -Recurrence once -ChatId 1 -UserId 1
        Format-ScheduleEvent -ScheduleEntry $entry | Should -Match ([regex]::Escape([System.TimeZoneInfo]::Local.Id))
    }

    It 'executes a one-time event once and never repeats it on later ticks' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now
        Update-ScheduleQueue -Now $now.AddMinutes(1)

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $scheduleEntry.Status | Should -Be 'completed'
        $scheduleEntry.CompletedExecutionKey | Should -Be $scheduleEntry.ExecutionKey
    }

    It 'keeps due events pending while scheduling is paused' {
        $config.Settings | Add-Member -NotePropertyName SchedulePaused -NotePropertyValue $true -Force
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey urgent -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($entry)

        Update-ScheduleQueue -Now $now

        $entry.Status | Should -Be 'pending'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'sends one advance notification per occurrence without executing early' {
        $config.Settings | Add-Member -NotePropertyName SchedulePreNotifyMinutes -NotePropertyValue 10 -Force
        Mock Send-TelegramMessage { }
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey urgent -ScheduledAt $now.AddMinutes(5) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($entry)

        Update-ScheduleQueue -Now $now
        Update-ScheduleQueue -Now $now.AddMinutes(1)

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 1 -and $Text -match 'بعد.*دقائق|قريب' }
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'completes a recurring event when its next occurrence exceeds the end date' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey urgent -ScheduledAt $now.AddMinutes(-1) -Recurrence daily -ChatId 1 -UserId 2 -RecurrenceUntil '2099-08-21'
        $script:ScheduleEvents.Add($entry)

        Update-ScheduleQueue -Now $now

        $entry.Status | Should -Be 'completed'
        $entry.LastResult | Should -Be 'success'
    }

    It 'writes a content-free JSONL execution result for each attempt' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Layer 4 -Values @{ 'Headline.Text' = 'secret editorial text' } -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now

        $line = Get-Content -LiteralPath $script:scheduleExecutionFile -Raw
        $record = $line | ConvertFrom-Json
        $record.EventId | Should -Be $scheduleEntry.Id
        $record.TemplateKey | Should -Be 'urgent'
        $record.Layer | Should -Be 4
        $record.Result | Should -Be 'success'
        $record.DurationMs | Should -BeGreaterOrEqual 0
        $line | Should -Not -Match 'secret editorial text|Headline.Text'
    }

    It 'advances a daily event only after successful completion' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence daily -ChatId 1 -UserId 2
        $oldAt = $scheduleEntry.ScheduledAt
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $scheduleEntry.Status | Should -Be 'pending'
        ([datetimeoffset]$scheduleEntry.ScheduledAt) | Should -BeGreaterThan ([datetimeoffset]$oldAt)
        ([datetimeoffset]$scheduleEntry.ScheduledAt) | Should -BeGreaterThan $now
    }

    It 'advances a weekly event by seven local calendar days' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence weekly -ChatId 1 -UserId 2
        $oldAt = [datetimeoffset]$scheduleEntry.ScheduledAt
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now

        ([datetimeoffset]$scheduleEntry.ScheduledAt).Date | Should -Be $oldAt.AddDays(7).Date
        $scheduleEntry.Status | Should -Be 'pending'
    }

    It 'does not replay an occurrence left running across a restart' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $scheduleEntry.Status = 'running'; $scheduleEntry.ExecutionKey = "$($scheduleEntry.Id)|$($scheduleEntry.ScheduledAt)"
        $script:ScheduleEvents.Add($scheduleEntry)
        Save-ScheduleEvents | Should -BeTrue
        $script:ScheduleEvents.Clear()

        Import-ScheduleEvents
        Update-ScheduleQueue -Now $now

        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        $script:ScheduleEvents[0].Status | Should -Be 'interrupted'
    }

    It 'retries a failed occurrence only after the configured delay' {
        $config.Settings | Add-Member -NotePropertyName ScheduleMaxRetries -NotePropertyValue 1 -Force
        $config.Settings | Add-Member -NotePropertyName ScheduleRetryDelaySeconds -NotePropertyValue 30 -Force
        $script:ScheduledShowCall = 0
        Mock Invoke-ShowTemplateResult {
            $script:ScheduledShowCall++
            if ($script:ScheduledShowCall -eq 1) { return [pscustomobject]@{ Success = $false; Error = 'timeout' } }
            return [pscustomobject]@{ Success = $true; Error = '' }
        }
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now
        Update-ScheduleQueue -Now $now.AddSeconds(20)
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $scheduleEntry.Status | Should -Be 'pending'
        $scheduleEntry.AttemptCount | Should -Be 1
        $scheduleEntry.LastResult | Should -Be 'timeout'

        Update-ScheduleQueue -Now $now.AddSeconds(31)
        Should -Invoke Invoke-ShowTemplateResult -Times 2 -Exactly
        $scheduleEntry.Status | Should -Be 'completed'
    }

    It 'parses only a clear future local time and reports the timezone' {
        $now = [datetimeoffset]'2026-08-20T20:00:00+03:00'
        $parsed = ConvertFrom-OperatorScheduleTime -Text '2026-08-21 09:30' -Now $now
        $past = ConvertFrom-OperatorScheduleTime -Text '2026-08-19 09:30' -Now $now

        $parsed.Success | Should -BeTrue
        $parsed.TimeZoneId | Should -Not -BeNullOrEmpty
        $past.Success | Should -BeFalse
    }

    It 'cancels a pending event persistently' {
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt ([datetimeoffset]::Now.AddHours(1)) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Stop-ScheduledShowEvent -Id $scheduleEntry.Id | Should -BeTrue

        $scheduleEntry.Status | Should -Be 'cancelled'
        @(Get-UpcomingScheduleEvents).Count | Should -Be 0
    }

    It 'does not approve a schedule mutation when atomic replacement fails' {
        '[]' | Set-Content -LiteralPath $script:scheduleFile -Encoding utf8
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt ([datetimeoffset]::Now.AddHours(1)) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)
        Mock Move-Item { throw 'disk failure' } -ModuleName BridgeStorage

        Save-ScheduleEvents | Should -BeFalse

        (Get-Content -LiteralPath $script:scheduleFile -Raw).Trim() | Should -Be '[]'
    }
}

Describe 'Schedule layer conflict detection' {
    BeforeEach { $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new() }
    AfterEach { $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new() }

    It 'detects a pending event on the same layer inside the conflict window' {
        $at = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $existing = New-ScheduledShowEvent -TemplateKey 'ticker' -Layer 4 -Values @{} -ScheduledAt $at -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($existing)

        $conflicts = @(Get-ScheduleLayerConflicts -Layer 4 -ScheduledAt $at.AddMinutes(1) -WindowMinutes 2)

        $conflicts.Count | Should -Be 1
        $conflicts[0].Id | Should -Be $existing.Id
    }

    It 'does not treat another layer at the same time as a conflict' {
        $at = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $script:ScheduleEvents.Add((New-ScheduledShowEvent -TemplateKey 'logo' -Layer 8 -Values @{} -ScheduledAt $at -Recurrence once -ChatId 1 -UserId 2))

        @(Get-ScheduleLayerConflicts -Layer 4 -ScheduledAt $at -WindowMinutes 2).Count | Should -Be 0
    }
}

Describe 'Bounded retry backoff' {
    It 'grows exponentially and never exceeds the configured cap' {
        Get-RetryDelaySeconds -BaseSeconds 10 -Attempt 1 -Factor 2 -MaxSeconds 25 | Should -Be 10
        Get-RetryDelaySeconds -BaseSeconds 10 -Attempt 2 -Factor 2 -MaxSeconds 25 | Should -Be 20
        Get-RetryDelaySeconds -BaseSeconds 10 -Attempt 3 -Factor 2 -MaxSeconds 25 | Should -Be 25
    }

    It 'normalizes unsafe values to a positive bounded delay' {
        Get-RetryDelaySeconds -BaseSeconds 0 -Attempt 0 -Factor 0 -MaxSeconds 0 | Should -Be 1
    }
}

Describe 'Telegram schedule review flow' {
    BeforeEach {
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        Clear-PendingState -ChatId 111
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'; Layer = 4; Fields = @('Headline.Text'); FieldLabels = @('العنوان')
                FieldLimits = @(80); FieldRequired = @($true)
            }
        }
        Mock Send-TelegramMessage { }
        Mock Add-ScheduledShowEvent { $true }
        Mock Add-AuditEntry { }
    }

    AfterEach {
        Clear-PendingState -ChatId 111
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
    }

    It 'shows same-layer timing conflicts before schedule confirmation' {
        $at = [datetimeoffset]::Now.AddHours(3)
        $script:ScheduleEvents.Add((New-ScheduledShowEvent -TemplateKey 'ticker' -Layer 4 -Values @{} -ScheduledAt $at -Recurrence once -ChatId 1 -UserId 2))
        $state = @{
            TemplateKey = 'urgent'; Layer = 4; Fields = @(); Values = @{}; ScheduledAt = $at.AddMinutes(1).ToString('o')
            TimeZoneId = [System.TimeZoneInfo]::Local.Id; Recurrence = 'once'; UserId = 121
        }

        Show-ScheduleReview -ChatId 111 -State $state

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تعارض محتمل.*الطبقة 4' -and $Text -match 'ticker'
        }
    }

    It 'collects values time and recurrence and saves only after confirmation' {
        Start-ScheduleShowFlow -TemplateIndex 0 -ChatId 111 -UserId 121
        Complete-ScheduleText -ChatId 111 -Value 'خبر الغد'
        $futureText = [datetimeoffset]::Now.AddHours(2).ToString('yyyy-MM-dd HH:mm')
        Complete-ScheduleText -ChatId 111 -Value $futureText
        $state = Get-PendingState -ChatId 111
        $state.Mode | Should -Be 'schedule_recurrence'
        $state.Recurrence = 'once'
        Show-ScheduleReview -ChatId 111 -State $state

        Should -Invoke Add-ScheduledShowEvent -Times 0 -Exactly
        Confirm-ScheduledShow -ChatId 111 -UserId 121

        Should -Invoke Add-ScheduledShowEvent -Times 1 -Exactly -ParameterFilter {
            $ScheduleEntry.TemplateKey -eq 'urgent' -and $ScheduleEntry.Values['Headline.Text'] -eq 'خبر الغد' -and $ScheduleEntry.Recurrence -eq 'once'
        }
    }
}

Describe 'Quiet hours delivery' {
    BeforeEach {
        $script:QuietHoursQueue = [System.Collections.Generic.List[object]]::new()
        Mock Send-TelegramMessage {}
        Mock Write-BridgeLog {}
        Mock Test-QuietHoursActive { $true }
    }
    AfterAll { $script:QuietHoursQueue = [System.Collections.Generic.List[object]]::new() }

    It 'holds a routine notice instead of paging at 03:00' {
        Send-AdminBroadcast -Text 'قالب لم يُتحقق منه'
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
        $script:QuietHoursQueue.Count | Should -Be 1
    }

    It 'keeps what it is holding across a restart' {
        # Being held is the opposite of being unimportant: these were withheld
        # on purpose. In memory alone, a 03:00 restart dropped every one of
        # them and left no trace but a log line written hours earlier.
        Send-AdminBroadcast -Text 'قالب لم يُتحقق منه'
        Send-AdminBroadcast -Text 'مساحة القرص منخفضة'
        $script:QuietHoursQueue.Count | Should -Be 2

        $script:QuietHoursQueue.Clear()
        Import-QuietHoursQueue

        $script:QuietHoursQueue.Count | Should -Be 2
        @($script:QuietHoursQueue | ForEach-Object { $_.Text }) | Should -Contain 'مساحة القرص منخفضة'
    }

    It 'stops growing without bound, and says how many it shed' {
        # The digest is one Telegram message and Telegram stops at 4096
        # characters. A long night with a chatty source grew both the file and
        # a message that could not be delivered at all. Oldest go first, and
        # the count survives so the morning does not quietly show fewer.
        $original = $script:QuietHoursQueueMax
        try {
            $script:QuietHoursQueueMax = 3
            1..6 | ForEach-Object { Send-AdminBroadcast -Text "تنبيه $_" }

            $script:QuietHoursQueue.Count | Should -Be 3
            @($script:QuietHoursQueue | ForEach-Object { $_.Text }) | Should -Contain 'تنبيه 6'
            @($script:QuietHoursQueue | ForEach-Object { $_.Text }) | Should -Not -Contain 'تنبيه 1'

            Mock Test-QuietHoursActive { $false }
            Update-QuietHoursQueue
            Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'وسقط 3 أقدم منها' }
        }
        finally { $script:QuietHoursQueueMax = $original; $script:QuietHoursDropped = 0 }
    }

    It 'still sends an urgent one immediately' {
        # A black output means the channel is wrong right now.
        Send-AdminBroadcast -Text 'المخرج أسود' -Urgent
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
        $script:QuietHoursQueue.Count | Should -Be 0
    }

    It 'delivers everything held as one message once the window passes' {
        Send-AdminBroadcast -Text 'أول'
        Send-AdminBroadcast -Text 'ثانٍ'
        Mock Test-QuietHoursActive { $false }

        Update-QuietHoursQueue

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'أول' -and $Text -match 'ثانٍ' }
        $script:QuietHoursQueue.Count | Should -Be 0
    }

    It 'keeps holding while the window is still open' {
        Send-AdminBroadcast -Text 'أول'
        Update-QuietHoursQueue
        $script:QuietHoursQueue.Count | Should -Be 1
    }
}

Describe 'Upcoming events carry the instant, not a rendering of it' {
    BeforeAll {
        $script:Entry = @{
            TemplateKey = 'urgent'; Recurrence = 'daily'
            ScheduledAt = '2026-09-01T21:45:00+03:00'; TimeZoneId = 'Arab Standard Time'
        }
    }

    It 'emits a tg-time entity with the unix instant and the documented format' {
        # 'wdt' is weekday + short date + short time, from the grammar
        # r|w?[dD]?[tT]? - so each reader gets their own timezone and language.
        $html = Format-ScheduleEventHtml -ScheduleEntry $script:Entry
        $expected = ([datetimeoffset]'2026-09-01T21:45:00+03:00').ToUnixTimeSeconds()

        $html | Should -Match ([regex]::Escape("<tg-time unix=`"$expected`" format=`"wdt`">"))
        $html | Should -Match ([regex]::Escape('</tg-time>'))
    }

    It 'keeps a readable time inside the element for a client that ignores it' {
        Format-ScheduleEventHtml -ScheduleEntry $script:Entry | Should -Match '2026-09-01 21:45'
    }

    It 'keeps the station zone beside it rather than converting silently' {
        Format-ScheduleEventHtml -ScheduleEntry $script:Entry | Should -Match 'Arab Standard Time'
    }

    It 'escapes a template key an administrator typed with markup in it' {
        $entry = $script:Entry.Clone()
        $entry.TemplateKey = 'a<b>&c'

        $html = Format-ScheduleEventHtml -ScheduleEntry $entry

        $html | Should -Match ([regex]::Escape('a&lt;b&gt;&amp;c'))
    }

    It 'leaves the plain formatter alone, because four callers still send text' {
        Format-ScheduleEvent -ScheduleEntry $script:Entry | Should -Not -Match '<'
    }
}

Describe 'Entering a schedule time the way an operator types it' {
    BeforeAll { $script:Ref = [datetimeoffset]::new(2026, 9, 1, 14, 0, 0, [datetimeoffset]::Now.Offset) }

    It 'takes a bare time as today' {
        $parsed = ConvertFrom-OperatorScheduleTime -Text '21:45' -Now $script:Ref

        $parsed.Success | Should -BeTrue
        $parsed.ScheduledAt.ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-09-01 21:45'
    }

    It 'rolls a bare time that has already gone to tomorrow' {
        # Otherwise the operator is told "must be in the future" about a time
        # they obviously meant for tonight's next bulletin.
        $parsed = ConvertFrom-OperatorScheduleTime -Text '09:00' -Now $script:Ref

        $parsed.Success | Should -BeTrue
        $parsed.ScheduledAt.ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-09-02 09:00'
    }

    It 'understands اليوم and غدًا' {
        (ConvertFrom-OperatorScheduleTime -Text 'اليوم 21:45' -Now $script:Ref).ScheduledAt.ToString('yyyy-MM-dd HH:mm') |
            Should -Be '2026-09-01 21:45'
        foreach ($word in 'غدًا', 'غدا', 'بكرة') {
            (ConvertFrom-OperatorScheduleTime -Text "$word 06:00" -Now $script:Ref).ScheduledAt.ToString('yyyy-MM-dd HH:mm') |
                Should -Be '2026-09-02 06:00'
        }
    }

    It 'takes a relative offset in minutes' {
        $parsed = ConvertFrom-OperatorScheduleTime -Text '+30' -Now $script:Ref

        $parsed.ScheduledAt.ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-09-01 14:30'
        (ConvertFrom-OperatorScheduleTime -Text 'بعد 90' -Now $script:Ref).ScheduledAt.ToString('HH:mm') | Should -Be '15:30'
    }

    It 'accepts the Arabic-Indic digits an Arabic keyboard produces' {
        # Without this the one field that is pure digits could not be typed
        # without switching keyboard layouts.
        $parsed = ConvertFrom-OperatorScheduleTime -Text '٢١:٤٥' -Now $script:Ref

        $parsed.Success | Should -BeTrue
        $parsed.ScheduledAt.ToString('HH:mm') | Should -Be '21:45'
    }

    It 'takes a day and month, and reads a past one as next year' {
        (ConvertFrom-OperatorScheduleTime -Text '09-15 21:45' -Now $script:Ref).ScheduledAt.ToString('yyyy-MM-dd HH:mm') |
            Should -Be '2026-09-15 21:45'
        (ConvertFrom-OperatorScheduleTime -Text '01-05 21:45' -Now $script:Ref).ScheduledAt.ToString('yyyy-MM-dd') |
            Should -Be '2027-01-05'
    }

    It 'still takes the full form, and its slash and dot spellings' {
        foreach ($text in '2026-09-15 21:45', '2026/09/15 21:45', '2026.09.15 21:45') {
            (ConvertFrom-OperatorScheduleTime -Text $text -Now $script:Ref).ScheduledAt.ToString('yyyy-MM-dd HH:mm') |
                Should -Be '2026-09-15 21:45'
        }
    }

    It 'refuses a clock reading that is not one, instead of rolling it over' {
        # 25:00 handed to AddHours silently becomes 01:00 tomorrow.
        foreach ($text in '25:00', '21:70') {
            (ConvertFrom-OperatorScheduleTime -Text $text -Now $script:Ref).Success | Should -BeFalse
        }
    }

    It 'still refuses a past moment and says what it accepts' {
        $parsed = ConvertFrom-OperatorScheduleTime -Text '2020-01-01 10:00' -Now $script:Ref
        $parsed.Success | Should -BeFalse

        (ConvertFrom-OperatorScheduleTime -Text 'الليلة' -Now $script:Ref).Error | Should -Match '21:45'
    }
}

Describe 'Picking a date and time instead of typing one' {
    BeforeAll { $script:Ref = [datetimeoffset]::new(2026, 9, 15, 14, 30, 0, [datetimeoffset]::Now.Offset) }

    It 'lays the month out as weeks under a weekday header' {
        $rows = @((Get-ScheduleCalendarKeyboard -Month '2026-09' -Now $script:Ref).inline_keyboard)

        @($rows[1]).Count | Should -Be 7
        foreach ($row in $rows[2..($rows.Count - 3)]) { @($row).Count | Should -Be 7 }
    }

    It 'disables a day that has gone rather than dropping it out of the grid' {
        # A month with holes in it stops reading as a calendar: the row a date
        # sits on is how the eye finds it.
        $flat = @((Get-ScheduleCalendarKeyboard -Month '2026-09' -Now $script:Ref).inline_keyboard | ForEach-Object { @($_) })
        $callbacks = @($flat | ForEach-Object { $_['callback_data'] })

        $callbacks | Should -Not -Contain 'schday:2026-09-14'
        $callbacks | Should -Contain 'schday:2026-09-15'
        $callbacks | Should -Contain 'schday:2026-09-30'
        @($flat | Where-Object { $_.ContainsKey('disabled') }).Count | Should -BeGreaterThan 7
    }

    It 'offers no way back past the month that holds today' {
        $callbacks = @((Get-ScheduleCalendarKeyboard -Month '2026-09' -Now $script:Ref).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })

        $callbacks | Should -Not -Contain 'schcal:2026-08'
        $callbacks | Should -Contain 'schcal:2026-10'
    }

    It 'keeps every hour of a future day, and only the spent ones of today' {
        $today = @((Get-ScheduleHourKeyboard -Date '2026-09-15' -Now $script:Ref).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $later = @((Get-ScheduleHourKeyboard -Date '2026-09-16' -Now $script:Ref).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })

        $today | Should -Not -Contain 'schhour:2026-09-15:13'
        $today | Should -Contain 'schhour:2026-09-15:14'
        $later | Should -Contain 'schhour:2026-09-16:0'
    }

    It 'steps the minutes by five and refuses one already gone' {
        $callbacks = @((Get-ScheduleMinuteKeyboard -Date '2026-09-15' -Hour 14 -Now $script:Ref).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })

        $callbacks | Should -Not -Contain 'schmin:2026-09-15:14:30'
        $callbacks | Should -Contain 'schmin:2026-09-15:14:35'
        $callbacks | Should -Not -Contain 'schmin:2026-09-15:14:36'
    }

    It 'offers the common offsets and the calendar beside the typed prompt' {
        $callbacks = @((Get-ScheduleTimePromptKeyboard -Now $script:Ref).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })

        $callbacks | Should -Contain 'schrel:30'
        $callbacks | Should -Contain 'schcal:2026-09'
    }
}

Describe 'Material-anchored scheduling (T-52)' {
    BeforeEach {
        $script:OriginalScheduleFileForAnchor = $script:scheduleFile
        $script:OriginalScheduleExecutionFileForAnchor = $script:scheduleExecutionFile
        $script:scheduleFile = Join-Path $TestDrive 'schedule.json'
        $script:scheduleExecutionFile = Join-Path $TestDrive 'schedule-execution.jsonl'
        Remove-Item -LiteralPath $script:scheduleExecutionFile -Force -ErrorAction SilentlyContinue
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-TelegramMessage { }
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Get-TemplateStore {
            [pscustomobject]@{
                Map = @{
                    urgent = [pscustomobject]@{
                        Key = 'urgent'; Path = 'C:\Scenes\Urgent.cintitle'; Layer = 4
                        Fields = @('Headline.Text'); FieldTypes = @{}; LongRunning = $false
                    }
                }
                Order = @('urgent'); Errors = @(); InvalidKeys = @(); SharedLayers = @{}
            }
        }
    }

    AfterEach {
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        $script:scheduleFile = $script:OriginalScheduleFileForAnchor
        $script:scheduleExecutionFile = $script:OriginalScheduleExecutionFileForAnchor
    }

    It 'passes wall-clock events through unchanged' {
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} `
            -ScheduledAt ([datetimeoffset]'2099-08-21T10:00:00+03:00') -Recurrence once -ChatId 1 -UserId 2
        Resolve-ScheduleAnchorTime -ScheduleEntry $entry -Items @() |
            Should -Be ([datetimeoffset]'2099-08-21T10:00:00+03:00')
    }

    It 'fires off the material start plus offset' {
        # The director's "thirty seconds into the segment", not 15:00 sharp.
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} `
            -ScheduledAt ([datetimeoffset]'2099-08-21T10:00:00+03:00') -Recurrence once -ChatId 1 -UserId 2 `
            -AnchorMaterialId '{11111111-1111-1111-1111-111111111111}' -AnchorOffsetSeconds 30
        $items = @(@{
                Id = '{11111111-1111-1111-1111-111111111111}'; Name = 'الفقرة المسائية'
                ScheduledAt = ([datetimeoffset]'2099-08-21T15:00:00+03:00').ToString('o')
                Duration = [timespan]::FromHours(1)
            })
        Resolve-ScheduleAnchorTime -ScheduleEntry $entry -Items $items |
            Should -Be ([datetimeoffset]'2099-08-21T15:00:30+03:00')
    }

    It 'falls back to the stored moment when the material left the rundown' {
        # A deleted programme must not delete the graphic with it: the event
        # keeps the snapshot taken at creation and says so on screen.
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} `
            -ScheduledAt ([datetimeoffset]'2099-08-21T10:00:00+03:00') -Recurrence once -ChatId 1 -UserId 2 `
            -AnchorMaterialId '{22222222-2222-2222-2222-222222222222}' -AnchorOffsetSeconds 30
        Resolve-ScheduleAnchorTime -ScheduleEntry $entry -Items @() |
            Should -Be ([datetimeoffset]'2099-08-21T10:00:00+03:00')
        Get-ScheduleAnchorLabel -ScheduleEntry $entry -Items @() | Should -Match 'لم تعد في الجدول'
    }

    It 'offers only materials that have not ended yet' {
        $now = [datetimeoffset]::Now
        $items = @(
            @{ Id = '{a}'; Name = 'انتهت'; ScheduledAt = $now.AddHours(-2).ToString('o'); Duration = [timespan]::FromHours(1) }
            @{ Id = '{b}'; Name = 'جارية'; ScheduledAt = $now.AddMinutes(-10).ToString('o'); Duration = [timespan]::FromHours(1) }
            @{ Id = '{c}'; Name = 'قادمة'; ScheduledAt = $now.AddHours(1).ToString('o'); Duration = [timespan]::FromHours(1) }
        )
        $choices = @(Get-ScheduleAnchorChoices -Items $items)
        $choices.Count | Should -Be 2
        $choices[0].Name | Should -Be 'جارية'
        $choices[1].Name | Should -Be 'قادمة'
    }

    It 'fires an anchored event at the material time, not the stored one' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{ 'Headline.Text' = 'مربوط' } `
            -ScheduledAt $now.AddHours(2) -Recurrence once -ChatId 1 -UserId 2 `
            -AnchorMaterialId '{33333333-3333-3333-3333-333333333333}' -AnchorOffsetSeconds 30
        Add-ScheduledShowEvent -ScheduleEntry $entry | Should -BeTrue
        $items = @(@{
                Id = '{33333333-3333-3333-3333-333333333333}'; Name = 'الفقرة'
                ScheduledAt = $now.AddMinutes(1).ToString('o'); Duration = [timespan]::FromHours(1)
            })
        Mock Get-CachedMaterialSchedule { @($items) }
        Update-ScheduleQueue -Now $now.AddMinutes(2)
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $script:ScheduleEvents[0].Status | Should -Be 'completed'
    }

    It 'holds an anchored event while its material slides later' {
        # The wall-clock snapshot says fire; the rundown says the programme
        # moved. The rundown wins, and the graphic waits with it.
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{ 'Headline.Text' = 'مؤجل مع المادة' } `
            -ScheduledAt $now.AddMinutes(5) -Recurrence once -ChatId 1 -UserId 2 `
            -AnchorMaterialId '{44444444-4444-4444-4444-444444444444}' -AnchorOffsetSeconds 30
        Add-ScheduledShowEvent -ScheduleEntry $entry | Should -BeTrue
        $items = @(@{
                Id = '{44444444-4444-4444-4444-444444444444}'; Name = 'الفقرة'
                ScheduledAt = $now.AddHours(2).ToString('o'); Duration = [timespan]::FromHours(1)
            })
        Mock Get-CachedMaterialSchedule { @($items) }
        Update-ScheduleQueue -Now $now.AddMinutes(6)
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        $script:ScheduleEvents[0].Status | Should -Be 'pending'
    }
}

Describe 'The schedule execution log finally has a reader' {
    # Write-ScheduleExecutionEntry has appended every fired occurrence since
    # scheduling shipped, and nothing ever read it back - the only consumer in
    # the tree was a file-size row on the diagnostics screen.
    BeforeEach {
        $script:OriginalExecFileForReader = $script:scheduleExecutionFile
        $script:scheduleExecutionFile = Join-Path $TestDrive 'exec-reader.jsonl'
        Remove-Item -LiteralPath $script:scheduleExecutionFile -Force -ErrorAction SilentlyContinue
        Mock Write-BridgeLog { }
    }

    AfterEach { $script:scheduleExecutionFile = $script:OriginalExecFileForReader }

    It 'reads newest first and measures how late each occurrence ran' {
        $due = [datetimeoffset]'2026-09-14T09:00:00+03:00'
        @(
            (@{ Timestamp = $due.AddSeconds(1).ToString('o'); EventId = 'e1'; TemplateKey = 'urgent'; Layer = 4
                ScheduledAt = $due.ToString('o'); Attempt = 1; Result = 'success'; DurationMs = 120; Error = '' } | ConvertTo-Json -Compress)
            (@{ Timestamp = $due.AddMinutes(4).ToString('o'); EventId = 'e2'; TemplateKey = 'logo'; Layer = 9
                ScheduledAt = $due.ToString('o'); Attempt = 2; Result = 'failed'; DurationMs = 900; Error = 'Cinegy timeout' } | ConvertTo-Json -Compress)
        ) | Set-Content -LiteralPath $script:scheduleExecutionFile -Encoding utf8

        $records = @(Get-ScheduleExecutionHistory)

        @($records).Count | Should -Be 2
        $records[0].TemplateKey | Should -Be 'logo'   # newest first
        Get-ScheduleExecutionDelaySeconds -Record $records[0] | Should -Be 240
        Get-ScheduleExecutionDelaySeconds -Record $records[1] | Should -Be 1
    }

    It 'loses one torn line, not the whole screen' {
        $due = [datetimeoffset]'2026-09-14T09:00:00+03:00'
        @(
            '{not json at all'
            (@{ Timestamp = $due.ToString('o'); EventId = 'e1'; TemplateKey = 'urgent'; Layer = 4
                ScheduledAt = $due.ToString('o'); Attempt = 1; Result = 'success'; DurationMs = 10; Error = '' } | ConvertTo-Json -Compress)
        ) | Set-Content -LiteralPath $script:scheduleExecutionFile -Encoding utf8

        @(Get-ScheduleExecutionHistory).Count | Should -Be 1
    }

    It 'says plainly when nothing has run rather than drawing an empty table' {
        $blocks = @(Get-ScheduleExecutionBlocks)
        ($blocks | Where-Object { $_.type -eq 'table' }) | Should -BeNullOrEmpty
        ($blocks | Where-Object { $_.type -eq 'paragraph' }).text | Should -Match 'لم يُنفَّذ'
    }

    It 'puts the failure reason where the operator is looking' {
        $due = [datetimeoffset]'2026-09-14T09:00:00+03:00'
        (@{ Timestamp = $due.ToString('o'); EventId = 'e1'; TemplateKey = 'urgent'; Layer = 4
            ScheduledAt = $due.ToString('o'); Attempt = 1; Result = 'failed'; DurationMs = 10
            Error = 'Cinegy refused the scene' } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $script:scheduleExecutionFile -Encoding utf8

        $text = Get-ScheduleExecutionText
        $text | Should -Match 'Cinegy refused the scene'
        @(Get-ScheduleExecutionBlocks | Where-Object { $_.type -eq 'paragraph' -and $_.text -match 'Cinegy refused' }).Count | Should -Be 1
    }

    It 'trims a log that grew without any bound, keeping the newest lines' {
        $due = [datetimeoffset]'2026-09-14T09:00:00+03:00'
        $lines = @(1..2100 | ForEach-Object {
                @{ Timestamp = $due.ToString('o'); EventId = "e$_"; TemplateKey = "t$_"; Layer = 4
                    ScheduledAt = $due.ToString('o'); Attempt = 1; Result = 'success'; DurationMs = 1; Error = '' } | ConvertTo-Json -Compress
            })
        $lines | Set-Content -LiteralPath $script:scheduleExecutionFile -Encoding utf8
        $script:LastScheduleExecutionTrim = [datetime]::MinValue

        Update-ScheduleExecutionLogTrim

        $after = @(Get-Content -LiteralPath $script:scheduleExecutionFile)
        $after.Count | Should -Be 2000
        $after[-1] | Should -Match '"EventId":"e2100"'
    }

    It 'does not rewrite the file again within the throttle window' {
        $script:LastScheduleExecutionTrim = (Get-Date)
        Set-Content -LiteralPath $script:scheduleExecutionFile -Value 'untouched' -Encoding utf8

        Update-ScheduleExecutionLogTrim

        (Get-Content -LiteralPath $script:scheduleExecutionFile -Raw).Trim() | Should -Be 'untouched'
    }
}
