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
