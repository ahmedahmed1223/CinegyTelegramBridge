#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeCinegyState.psm1') -Force
}

Describe 'Cinegy layer reconciliation policy' {
    It 'keeps a tracked record when live status is unavailable' {
        $tracked=@{Key='headline';ActiveId='old';UserId=10;At='2026-08-22T10:00:00Z';Source='bridge'}
        $status=[pscustomobject]@{Success=$false;IsOnAir=$null;ActiveId='';Error='timeout';Layer=7}

        $result=Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $tracked -Status $status

        $result.Action | Should -Be 'failed'
        $result.Record | Should -Be $tracked
    }

    It 'adopts Cinegy active id without deleting a tracked scene that is on air' {
        $tracked=@{Key='headline';ActiveId='bot-event';UserId=10;At='2026-08-22T10:00:00Z';Source='bridge'}
        $status=[pscustomobject]@{Success=$true;IsOnAir=$true;ActiveId='{cinegy-active}';Layer=7}

        $result=Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $tracked -Status $status

        $result.Action | Should -Be 'update'
        $result.Record.ActiveId | Should -Be '{cinegy-active}'
        $tracked.ActiveId | Should -Be 'bot-event'
    }

    It 'removes a tracked scene only after Cinegy confirms the layer is not on air' {
        $tracked=@{Key='headline';ActiveId='old';UserId=10;At='2026-08-22T10:00:00Z';Source='bridge'}
        $status=[pscustomobject]@{Success=$true;IsOnAir=$false;ActiveId='';ActiveName='';OutputState='empty';ClientConnected=$true;ClientIdentity='air';Layer=7}

        $result=Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $tracked -Status $status

        $result.Action | Should -Be 'remove'
        $result.Change.TemplateKey | Should -Be 'headline'
        $result.Change.ExpectedActiveId | Should -Be 'old'
    }

    It 'discovers an untracked on-air scene as a Cinegy-owned record only when requested' {
        $status=[pscustomobject]@{Success=$true;IsOnAir=$true;ActiveId='external-1';ActiveName='Scheduled lower third';Layer=8}
        $now=[datetime]'2026-08-22T10:00:00Z'

        $ignored=Resolve-BridgeCinegyLayerState -Layer 8 -Status $status -Now $now
        $added=Resolve-BridgeCinegyLayerState -Layer 8 -Status $status -DiscoverExternal -Now $now

        $ignored.Action | Should -Be 'ignore'
        $added.Action | Should -Be 'add'
        $added.Record.Source | Should -Be 'cinegy'
        $added.Record.Key | Should -Be 'Scheduled lower third'
        $added.Record.At | Should -Be $now
    }

    It 'prefers the extracted template name over the generic Cinegy layer event name' {
        $status=[pscustomobject]@{
            Success=$true;IsOnAir=$true;ActiveId='external-2';
            ActiveName='Cinegy Type Layer 8 On';ActiveTemplateName='ticker';Layer=8
        }

        $added=Resolve-BridgeCinegyLayerState -Layer 8 -Status $status -DiscoverExternal

        $added.Record.Key | Should -Be 'ticker'
        $added.Record.CinegyEventName | Should -Be 'Cinegy Type Layer 8 On'
    }
}
