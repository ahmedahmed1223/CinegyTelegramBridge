#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeSchedulePolicy.psm1') -Force
}

Describe 'Schedule execution policy' {
    It 'uses the scheduled time before a retry and blocks a completed occurrence' {
        $scheduled=[datetimeoffset]'2026-08-22T10:00:00+00:00'
        $event=@{Id='evt-1';ScheduledAt=$scheduled.ToString('o');NextAttemptAt='';CompletedExecutionKey=''}

        $due=Get-BridgeScheduleDueState -ScheduleEntry $event -Now $scheduled
        $due.IsDue | Should -BeTrue
        $due.ExecutionKey | Should -Be "evt-1|$($scheduled.ToString('o'))"

        $event.CompletedExecutionKey=$due.ExecutionKey
        (Get-BridgeScheduleDueState -ScheduleEntry $event -Now $scheduled.AddHours(1)).IsDue | Should -BeFalse
    }

    It 'uses NextAttemptAt as the retry due time' {
        $scheduled=[datetimeoffset]'2026-08-22T10:00:00+00:00'
        $retry=$scheduled.AddMinutes(2)
        $event=@{Id='evt-2';ScheduledAt=$scheduled.ToString('o');NextAttemptAt=$retry.ToString('o');CompletedExecutionKey=''}

        (Get-BridgeScheduleDueState -ScheduleEntry $event -Now $retry.AddSeconds(-1)).IsDue | Should -BeFalse
        (Get-BridgeScheduleDueState -ScheduleEntry $event -Now $retry).IsDue | Should -BeTrue
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
