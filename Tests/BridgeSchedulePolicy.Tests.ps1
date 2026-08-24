#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeSchedulePolicy.psm1') -Force
}

Describe 'Schedule execution policy' {
    It 'uses the scheduled time before a retry and blocks a completed occurrence' {
        $scheduled=[datetimeoffset]'2026-08-22T10:00:00+00:00'
        $scheduleEntry=@{Id='evt-1';ScheduledAt=$scheduled.ToString('o');NextAttemptAt='';CompletedExecutionKey=''}

        $due=Get-BridgeScheduleDueState -ScheduleEntry $scheduleEntry -Now $scheduled
        $due.IsDue | Should -BeTrue
        $due.ExecutionKey | Should -Be "evt-1|$($scheduled.ToString('o'))"

        $scheduleEntry.CompletedExecutionKey=$due.ExecutionKey
        (Get-BridgeScheduleDueState -ScheduleEntry $scheduleEntry -Now $scheduled.AddHours(1)).IsDue | Should -BeFalse
    }

    It 'uses NextAttemptAt as the retry due time' {
        $scheduled=[datetimeoffset]'2026-08-22T10:00:00+00:00'
        $retry=$scheduled.AddMinutes(2)
        $scheduleEntry=@{Id='evt-2';ScheduledAt=$scheduled.ToString('o');NextAttemptAt=$retry.ToString('o');CompletedExecutionKey=''}

        (Get-BridgeScheduleDueState -ScheduleEntry $scheduleEntry -Now $retry.AddSeconds(-1)).IsDue | Should -BeFalse
        (Get-BridgeScheduleDueState -ScheduleEntry $scheduleEntry -Now $retry).IsDue | Should -BeTrue
    }

    It 'calculates bounded exponential retries and then a terminal failure' {
        $now=[datetimeoffset]'2026-08-22T10:00:00+00:00'

        $retry=Get-BridgeScheduleRetryDecision -PriorAttemptCount 1 -MaxRetries 3 -BaseSeconds 30 -Factor 2 -MaxDelaySeconds 50 -Now $now
        $retry.AttemptCount | Should -Be 2
        $retry.ShouldRetry | Should -BeTrue
        $retry.DelaySeconds | Should -Be 50
        $retry.NextAttemptAt | Should -Be $now.AddSeconds(50)

        $terminal=Get-BridgeScheduleRetryDecision -PriorAttemptCount 3 -MaxRetries 3 -BaseSeconds 30 -Factor 2 -MaxDelaySeconds 300 -Now $now
        $terminal.AttemptCount | Should -Be 4
        $terminal.ShouldRetry | Should -BeFalse
        $terminal.NextAttemptAt | Should -BeNullOrEmpty
    }
}

Describe 'Quiet hours and maintenance windows' {
    It 'holds non-urgent notices inside a same-day window' {
        Test-BridgeQuietHour -Hour 3 -StartHour 1 -EndHour 6 | Should -BeTrue
        Test-BridgeQuietHour -Hour 9 -StartHour 1 -EndHour 6 | Should -BeFalse
    }

    It 'handles a window that crosses midnight, which is what a night shift is' {
        Test-BridgeQuietHour -Hour 23 -StartHour 22 -EndHour 6 | Should -BeTrue
        Test-BridgeQuietHour -Hour 2 -StartHour 22 -EndHour 6 | Should -BeTrue
        Test-BridgeQuietHour -Hour 12 -StartHour 22 -EndHour 6 | Should -BeFalse
    }

    It 'treats the boundary hours consistently: start is in, end is out' {
        Test-BridgeQuietHour -Hour 1 -StartHour 1 -EndHour 6 | Should -BeTrue
        Test-BridgeQuietHour -Hour 6 -StartHour 1 -EndHour 6 | Should -BeFalse
    }

    It 'is disabled when start and end are the same hour' {
        Test-BridgeQuietHour -Hour 3 -StartHour 4 -EndHour 4 | Should -BeFalse
    }

    It 'opens a maintenance window between its times' {
        $now = [datetime]'2026-08-24T04:45:00'
        Test-BridgeMaintenanceWindow -Now $now -StartTime '04:30' -EndTime '05:00' | Should -BeTrue
    }

    It 'closes it outside them' {
        $now = [datetime]'2026-08-24T06:00:00'
        Test-BridgeMaintenanceWindow -Now $now -StartTime '04:30' -EndTime '05:00' | Should -BeFalse
    }

    It 'handles a maintenance window that crosses midnight' {
        Test-BridgeMaintenanceWindow -Now ([datetime]'2026-08-24T23:30:00') -StartTime '23:00' -EndTime '01:00' | Should -BeTrue
        Test-BridgeMaintenanceWindow -Now ([datetime]'2026-08-24T00:30:00') -StartTime '23:00' -EndTime '01:00' | Should -BeTrue
        Test-BridgeMaintenanceWindow -Now ([datetime]'2026-08-24T12:00:00') -StartTime '23:00' -EndTime '01:00' | Should -BeFalse
    }

    It 'never fails closed on an unset or malformed window' {
        # Failing closed would silently block control of a live channel.
        $now = [datetime]'2026-08-24T04:45:00'
        Test-BridgeMaintenanceWindow -Now $now -StartTime '' -EndTime '' | Should -BeFalse
        Test-BridgeMaintenanceWindow -Now $now -StartTime 'not-a-time' -EndTime '05:00' | Should -BeFalse
        Test-BridgeMaintenanceWindow -Now $now -StartTime '04:30' -EndTime '04:30' | Should -BeFalse
    }
}
