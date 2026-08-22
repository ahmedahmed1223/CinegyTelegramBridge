#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeFlowState.psm1') -Force
}

Describe 'Interactive flow state store' {
    It 'stores a flow with the supplied start time and retrieves it before expiry' {
        $store=@{}; $now=[datetime]'2026-08-22T10:00:00Z'; $state=@{Mode='show_fields';UserId=10}

        Set-BridgePendingFlow -Store $store -ChatId 10 -State $state -Now $now
        $result=Get-BridgePendingFlow -Store $store -ChatId 10 -TimeoutMinutes 5 -Now $now.AddMinutes(4)

        $result.Expired | Should -BeFalse
        $result.State.Mode | Should -Be 'show_fields'
        $result.State.StartedAt | Should -Be $now
    }

    It 'removes and reports a flow at the timeout boundary' {
        $store=@{}; $now=[datetime]'2026-08-22T10:00:00Z'
        Set-BridgePendingFlow -Store $store -ChatId 10 -State @{Mode='show_review'} -Now $now

        $result=Get-BridgePendingFlow -Store $store -ChatId 10 -TimeoutMinutes 5 -Now $now.AddMinutes(5)

        $result.Expired | Should -BeTrue
        $result.State.Mode | Should -Be 'show_review'
        $store.ContainsKey(10) | Should -BeFalse
    }

    It 'returns the removed state so the bridge can release associated resources' {
        $store=@{10=@{Mode='template_import_review';ImportStagedPath='staged.json'}}

        $removed=Remove-BridgePendingFlow -Store $store -ChatId 10

        $removed.ImportStagedPath | Should -Be 'staged.json'
        $store.ContainsKey(10) | Should -BeFalse
    }
}
