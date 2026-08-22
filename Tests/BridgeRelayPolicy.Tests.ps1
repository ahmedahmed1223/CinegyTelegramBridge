#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeRelayPolicy.psm1') -Force
}

Describe 'Live relay watchdog policy' {
    It 'does nothing when relay is not requested or the watchdog interval has not elapsed' {
        $now=[datetime]'2026-08-22T10:00:00Z'
        (Get-BridgeRelayWatchdogDecision -ShouldRun:$false -HasRunningProcess:$false -AutoRestart -Restarts 0 -MaxRestarts 3 -LastCheck $now.AddMinutes(-1) -IntervalSeconds 5 -Now $now).Action | Should -Be 'idle'
        (Get-BridgeRelayWatchdogDecision -ShouldRun -HasRunningProcess:$false -AutoRestart -Restarts 0 -MaxRestarts 3 -LastCheck $now.AddSeconds(-2) -IntervalSeconds 5 -Now $now).Action | Should -Be 'wait'
    }

    It 'reports a healthy relay without changing the restart count' {
        $now=[datetime]'2026-08-22T10:00:00Z'
        $result=Get-BridgeRelayWatchdogDecision -ShouldRun -HasRunningProcess -AutoRestart -Restarts 1 -MaxRestarts 3 -LastCheck $now.AddSeconds(-10) -IntervalSeconds 5 -Now $now
        $result.Action | Should -Be 'running'
        $result.Restarts | Should -Be 1
    }

    It 'stays down when auto restart is disabled and gives up at the maximum' {
        $now=[datetime]'2026-08-22T10:00:00Z'
        (Get-BridgeRelayWatchdogDecision -ShouldRun -HasRunningProcess:$false -AutoRestart:$false -Restarts 0 -MaxRestarts 3 -LastCheck $now.AddSeconds(-10) -IntervalSeconds 5 -Now $now).Action | Should -Be 'stay_down'
        (Get-BridgeRelayWatchdogDecision -ShouldRun -HasRunningProcess:$false -AutoRestart -Restarts 3 -MaxRestarts 3 -LastCheck $now.AddSeconds(-10) -IntervalSeconds 5 -Now $now).Action | Should -Be 'give_up'
    }

    It 'increments the count exactly once when a restart is allowed' {
        $now=[datetime]'2026-08-22T10:00:00Z'
        $result=Get-BridgeRelayWatchdogDecision -ShouldRun -HasRunningProcess:$false -AutoRestart -Restarts 1 -MaxRestarts 3 -LastCheck $now.AddSeconds(-10) -IntervalSeconds 5 -Now $now
        $result.Action | Should -Be 'restart'
        $result.Restarts | Should -Be 2
        $result.CheckedAt | Should -Be $now
    }
}
