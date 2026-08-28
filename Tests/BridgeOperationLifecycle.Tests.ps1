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
}
