#requires -Version 7

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\Modules\BridgeLiveScenes.psm1'
    Import-Module $modulePath -Force
    Import-Module (Join-Path $PSScriptRoot '..\Modules\CinegyAirTitler.psm1') -Force
}

Describe 'Bridge live scene state' {
    It 'migrates a legacy one-record-per-layer document into canonical scenes' {
        $legacy = [pscustomobject]@{
            '7' = [pscustomobject]@{
                Key = 'lower-third'
                At = '2026-08-28T12:00:00.0000000Z'
                UserId = 10
                ActiveId = 'cinegy-77'
                Source = 'bridge'
            }
        }

        $result = ConvertTo-BridgeLiveSceneState -Document $legacy

        $result.Success | Should -BeTrue
        $result.Scenes.Count | Should -Be 1
        $result.Scenes[0].Layer | Should -Be 7
        $result.Scenes[0].Key | Should -Be 'lower-third'
        $result.Scenes[0].SceneId | Should -Match '^legacy-'
    }

    It 'retains multiple active scene records on the same layer in canonical state' {
        $document = [pscustomobject]@{
            SchemaVersion = 1
            Scenes = @(
                [pscustomobject]@{ SceneId = 'scene-a'; Layer = 7; Key = 'lower-third'; At = '2026-08-28T12:00:00Z'; UserId = 10; ActiveId = 'a'; Source = 'bridge' }
                [pscustomobject]@{ SceneId = 'scene-b'; Layer = 7; Key = 'ticker'; At = '2026-08-28T12:01:00Z'; UserId = 10; ActiveId = 'b'; Source = 'bridge' }
            )
        }

        $state = ConvertTo-BridgeLiveSceneState -Document $document
        $layerScenes = Get-BridgeLiveScenesForLayer -State $state -Layer 7

        $state.Success | Should -BeTrue
        $layerScenes.Count | Should -Be 2
        @($layerScenes.SceneId) | Should -Be @('scene-a', 'scene-b')
        (Get-BridgeLiveScenes -State $state).Count | Should -Be 2
        (Get-BridgeLiveScene -State $state -SceneId 'scene-b').Key | Should -Be 'ticker'
        (Get-BridgePrimarySceneForLayer -State $state -Layer 7).SceneId | Should -Be 'scene-a'
    }

    It 'rejects canonical state with duplicate or blank scene identities' {
        $document = [pscustomobject]@{
            Scenes = @(
                [pscustomobject]@{ SceneId = 'scene-a'; Layer = 7; Key = 'lower-third' }
                [pscustomobject]@{ SceneId = 'SCENE-A'; Layer = 7; Key = 'ticker' }
            )
        }

        $result = ConvertTo-BridgeLiveSceneState -Document $document

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'duplicate'
    }

    It 'preserves the canonical optional audit fields while migrating legacy state' {
        $templatePath = Join-Path 'C:\Titles' 'clock.cintitle'
        $legacy = @{ '9' = @{ Key = 'clock'; ActiveId = 'cinegy-9'; ChatId = 22; TemplatePath = $templatePath; LastVerifiedAtUtc = '2026-08-28T12:00:00Z' } }

        $state = ConvertTo-BridgeLiveSceneState -Document $legacy

        $state.Scenes[0].ChatId | Should -Be 22
        $state.Scenes[0].TemplatePath | Should -Be $templatePath
        $state.Scenes[0].LastVerifiedAtUtc | Should -Be '2026-08-28T12:00:00Z'
    }

    It 'enables Multi catalog mode when Cinegy exposes layer control and active item identity' {
        $unidentified = Get-CinegySceneCapabilities -SceneItems @([pscustomobject]@{ Success = $true; Name = 'one' }) -LayerTargetSupported $true
        $verified = Get-CinegySceneCapabilities -SceneItems @([pscustomobject]@{ Success = $true; ActiveId = 'item-one' }) -LayerTargetSupported $true

        (Test-BridgeSceneMode -RequestedMode Multi -Capabilities $unidentified).Mode | Should -Be 'Single'
        (Test-BridgeSceneMode -RequestedMode Multi -Capabilities $verified).Mode | Should -Be 'Multi'
        $verified.Semantics | Should -Be 'LayerCatalog'
        $verified.CanTargetScene | Should -BeFalse
        $verified.Verified | Should -BeTrue
    }
}
