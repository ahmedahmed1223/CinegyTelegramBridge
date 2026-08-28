#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeOperationPolicy.psm1') -Force
}

Describe 'Telegram update admission policy' {
    It 'admits one update id only once while it remains in the ledger' {
        $ledger = New-BridgeUpdateLedger -Capacity 4

        Test-BridgeUpdateAdmission -Ledger $ledger -UpdateId 10 | Should -BeTrue
        Test-BridgeUpdateAdmission -Ledger $ledger -UpdateId 10 | Should -BeFalse
        Test-BridgeUpdateAdmission -Ledger $ledger -UpdateId 11 | Should -BeTrue
    }

    It 'evicts the oldest id when the bounded ledger reaches capacity' {
        $ledger = New-BridgeUpdateLedger -Capacity 2
        1, 2, 3 | ForEach-Object { Test-BridgeUpdateAdmission -Ledger $ledger -UpdateId $_ | Out-Null }

        Test-BridgeUpdateAdmission -Ledger $ledger -UpdateId 1 | Should -BeTrue
        Test-BridgeUpdateAdmission -Ledger $ledger -UpdateId 3 | Should -BeFalse
    }

    It 'puts emergency removal before show and administration while preserving ties' {
        $updates = @(
            [pscustomobject]@{ update_id = 1; callback_query = [pscustomobject]@{ data = 'menu:settings' } }
            [pscustomobject]@{ update_id = 2; callback_query = [pscustomobject]@{ data = 'tpl:4' } }
            [pscustomobject]@{ update_id = 3; callback_query = [pscustomobject]@{ data = 'hide:7' } }
            [pscustomobject]@{ update_id = 4; callback_query = [pscustomobject]@{ data = 'exit:8' } }
        )

        @((Get-BridgeUpdatesForProcessing -Updates $updates).update_id) | Should -Be @(3, 4, 2, 1)
    }
}
