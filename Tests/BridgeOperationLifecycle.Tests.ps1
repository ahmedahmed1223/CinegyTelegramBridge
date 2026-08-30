#requires -Version 7

BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeOperationLifecycle.psm1') -Force }

Describe 'Bridge operation lifecycle' {
    It 'creates a queued record with a bounded opaque id' {
        $operation = New-BridgeOperationRecord -Action HIDE -Layer 7 -ActorId 10
        $operation.State | Should -Be 'queued'
        $operation.OperationId | Should -Match '^op-[a-f0-9]{12}$'
    }

    It 'rejects an invalid state transition' {
        $operation = New-BridgeOperationRecord -Action SHOW -Layer 7 -ActorId 10
        { Set-BridgeOperationState -Operation $operation -State succeeded } | Should -Throw
    }

    It 'resolves scene tokens only for their matching layer before expiry' {
        $store = @{}
        $token = New-BridgeSceneCallbackToken -Store $store -SceneId 'scene-a' -Layer 7 -Now ([datetime]'2026-08-28T12:00:00Z')
        (Resolve-BridgeSceneCallbackToken -Store $store -Token $token -Layer 7 -Now ([datetime]'2026-08-28T12:01:00Z')).SceneId | Should -Be 'scene-a'
        (Resolve-BridgeSceneCallbackToken -Store $store -Token $token -Layer 8 -Now ([datetime]'2026-08-28T12:01:00Z')) | Should -BeNullOrEmpty
    }

    It 'classifies every supported Cinegy mutation as layer exclusive' {
        (Get-BridgeOperationScope -Action 'show').Scope | Should -Be 'LayerExclusive'
        (Get-BridgeOperationScope -Action 'hide-layer').Scope | Should -Be 'LayerExclusive'
        (Get-BridgeOperationScope -Action 'exit-layer').Scope | Should -Be 'LayerExclusive'
        { Get-BridgeOperationScope -Action 'scene-hide' } | Should -Throw
    }

    It 'formats a concise Arabic status with its correlation id' {
        $operation = New-BridgeOperationRecord -Action SHOW -Layer 7 -ActorId 10
        $text = Get-BridgeOperationStatusText -Operation $operation
        $text | Should -Match ([regex]::Escape($operation.OperationId))
        $text | Should -Match 'قيد الانتظار'
    }

    It 'retains a real correlation id through running and terminal lifecycle states' {
        $ledger = New-BridgeOperationLedger -Capacity 2

        $operation = Start-BridgeOperation -Ledger $ledger -OperationId 'air-correlation-1' -Action SHOW -Layer 7 -ActorId 10
        $operation.State | Should -Be 'running'
        (Complete-BridgeOperation -Ledger $ledger -OperationId 'air-correlation-1' -Result success).State | Should -Be 'succeeded'
        (Get-BridgeOperationRecord -Ledger $ledger -OperationId 'air-correlation-1').ActorId | Should -Be 10
    }

    It 'keeps a blocked queued operation unstarted and records its eventual layer' {
        $ledger = New-BridgeOperationLedger

        Queue-BridgeOperation -Ledger $ledger -OperationId 'air-queued-1' -Action SHOW -Layer 0 -ActorId 10 | Out-Null
        (Complete-BridgeOperation -Ledger $ledger -OperationId 'air-queued-1' -Result blocked -ErrorText 'maintenance mode').State | Should -Be 'failed'
        $blocked = Get-BridgeOperationRecord -Ledger $ledger -OperationId 'air-queued-1'
        $blocked.StartedAtUtc | Should -BeNullOrEmpty

        Queue-BridgeOperation -Ledger $ledger -OperationId 'air-queued-2' -Action SHOW -Layer 0 -ActorId 10 | Out-Null
        $started = Start-BridgeOperation -Ledger $ledger -OperationId 'air-queued-2' -Action SHOW -Layer 7 -ActorId 10
        $started.State | Should -Be 'running'
        $started.Layer | Should -Be 7
        $started.StartedAtUtc | Should -Not -BeNullOrEmpty
        @($ledger.Records | Where-Object OperationId -eq 'air-queued-2').Count | Should -Be 1
        $ledger.Records.Count | Should -BeLessOrEqual $ledger.Capacity
    }

    It 'bounds retained lifecycle records without changing terminal results' {
        $ledger = New-BridgeOperationLedger -Capacity 1
        Start-BridgeOperation -Ledger $ledger -OperationId 'air-old' -Action HIDE -Layer 7 | Out-Null
        Complete-BridgeOperation -Ledger $ledger -OperationId 'air-old' -Result failed -ErrorText 'network' | Out-Null
        Start-BridgeOperation -Ledger $ledger -OperationId 'air-new' -Action EXIT -Layer 7 | Out-Null

        Get-BridgeOperationRecord -Ledger $ledger -OperationId 'air-old' | Should -BeNullOrEmpty
        (Get-BridgeOperationRecord -Ledger $ledger -OperationId 'air-new').State | Should -Be 'running'
    }
}
