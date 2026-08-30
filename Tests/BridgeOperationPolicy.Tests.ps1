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

    It 'puts emergency removal before independent show work while preserving unknown barriers and ties' {
        $updates = @(
            [pscustomobject]@{ update_id = 1; callback_query = [pscustomobject]@{ data = 'menu:settings' } }
            [pscustomobject]@{ update_id = 2; callback_query = [pscustomobject]@{ data = 'showgo:7' } }
            [pscustomobject]@{ update_id = 3; callback_query = [pscustomobject]@{ data = 'hide:8' } }
            [pscustomobject]@{ update_id = 4; callback_query = [pscustomobject]@{ data = 'exit:9' } }
        )

        @((Get-BridgeUpdatesForProcessing -Updates $updates).update_id) | Should -Be @(1, 3, 4, 2)
    }

    It 'preserves Telegram order for dependent operations on the same layer' {
        $showThenHide = @(
            [pscustomobject]@{ update_id = 100; callback_query = [pscustomobject]@{ data = 'showgo:7' } }
            [pscustomobject]@{ update_id = 101; callback_query = [pscustomobject]@{ data = 'hide:7' } }
        )
        $hideThenShow = @(
            [pscustomobject]@{ update_id = 200; callback_query = [pscustomobject]@{ data = 'hide:7' } }
            [pscustomobject]@{ update_id = 201; callback_query = [pscustomobject]@{ data = 'showgo:7' } }
        )

        @((Get-BridgeUpdatesForProcessing -Updates $showThenHide).update_id) | Should -Be @(100, 101)
        @((Get-BridgeUpdatesForProcessing -Updates $hideThenShow).update_id) | Should -Be @(200, 201)
    }

    It 'moves an emergency removal ahead only across a known different layer' {
        $updates = @(
            [pscustomobject]@{ update_id = 300; callback_query = [pscustomobject]@{ data = 'showgo:7' } }
            [pscustomobject]@{ update_id = 301; callback_query = [pscustomobject]@{ data = 'hide:8' } }
        )

        @((Get-BridgeUpdatesForProcessing -Updates $updates).update_id) | Should -Be @(301, 300)
    }

    It 'keeps unknown and global updates as causal ordering barriers' {
        $unknownBeforeHide = @(
            [pscustomobject]@{ update_id = 400; message = [pscustomobject]@{ text = '/show custom' } }
            [pscustomobject]@{ update_id = 401; callback_query = [pscustomobject]@{ data = 'hide:8' } }
        )
        $showBeforeHideAll = @(
            [pscustomobject]@{ update_id = 500; callback_query = [pscustomobject]@{ data = 'showgo:7' } }
            [pscustomobject]@{ update_id = 501; callback_query = [pscustomobject]@{ data = 'menu:hideall' } }
        )

        @((Get-BridgeUpdatesForProcessing -Updates $unknownBeforeHide).update_id) | Should -Be @(400, 401)
        @((Get-BridgeUpdatesForProcessing -Updates $showBeforeHideAll).update_id) | Should -Be @(500, 501)
    }
}
