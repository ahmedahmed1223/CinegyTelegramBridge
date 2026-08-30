#requires -Version 7
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeUiPaging.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeLiveScenes.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeOperationPolicy.psm1') -Force
}

Describe 'Version 6 measured scale acceptance' {
    It 'pages one thousand templates in under one second' {
        $elapsed = (Measure-Command { 1..1000 | ForEach-Object { Get-BridgePageWindow -ItemCount 1000 -Page ($_ % 50) -PageSize 20 } | Out-Null }).TotalMilliseconds
        $elapsed | Should -BeLessThan 1000 -Because "page calculations took $elapsed ms"
        (Get-BridgePageWindow -ItemCount 1000 -Page 0 -PageSize 20).EndIndex | Should -Be 19
    }

    It 'looks up shared-layer catalog records in under one second' {
        $scenes = @(0..999 | ForEach-Object { [pscustomobject]@{ SceneId = "scene-$_"; Layer = ($_ % 20); Key = "template-$_" } })
        $state = (ConvertTo-BridgeLiveSceneState -Document @{ Scenes = $scenes })
        $elapsed = (Measure-Command { 1..100 | ForEach-Object { Get-BridgeLiveScenesForLayer -State $state -Layer 7 | Out-Null } }).TotalMilliseconds
        $elapsed | Should -BeLessThan 1000 -Because "shared-layer lookups took $elapsed ms"
        @(Get-BridgeLiveScenesForLayer -State $state -Layer 7).Count | Should -Be 50
    }

    It 'admits emergency layer actions before independent known-layer work' {
        $updates = @(
            [pscustomobject]@{ update_id = 1; callback_query = [pscustomobject]@{ data = 'showgo:8' } },
            [pscustomobject]@{ update_id = 2; callback_query = [pscustomobject]@{ data = 'hide:7' } },
            [pscustomobject]@{ update_id = 3; callback_query = [pscustomobject]@{ data = 'menu:settings' } }
        )
        $ordered = @(Get-BridgeUpdatesForProcessing -Updates $updates)
        $ordered[0].callback_query.data | Should -Be 'hide:7'
    }
}
