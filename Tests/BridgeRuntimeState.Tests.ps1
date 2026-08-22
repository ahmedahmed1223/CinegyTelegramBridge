#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeRuntimeState.psm1') -Force
}

Describe 'Bridge runtime state model' {
    It 'creates isolated relay and monitoring state with safe initial values' {
        $first=New-BridgeRuntimeState
        $second=New-BridgeRuntimeState

        $first.Relay.Process | Should -BeNullOrEmpty
        $first.Relay.ShouldRun | Should -BeFalse
        $first.Relay.Restarts | Should -Be 0
        $first.Relay.LastCheck | Should -Be ([datetime]::MinValue)
        $first.Monitoring.CinegyHealthState | Should -Be 'unknown'
        $first.Relay.Restarts=2
        $second.Relay.Restarts | Should -Be 0
    }
}
