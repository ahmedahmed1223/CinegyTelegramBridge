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

    It 'refreshes the display name of an already tracked external Cinegy scene' {
        $tracked=@{
            Key='Cinegy Type Layer 8 On';ActiveId='external-2';UserId=0;
            At='2026-08-22T10:00:00Z';Source='cinegy'
        }
        $status=[pscustomobject]@{
            Success=$true;IsOnAir=$true;ActiveId='external-2';
            ActiveName='Cinegy Type Layer 8 On';ActiveTemplateName='ticker';Layer=8
        }

        $result=Resolve-BridgeCinegyLayerState -Layer 8 -TrackedRecord $tracked -Status $status

        $result.Action | Should -Be 'update'
        $result.Record.Key | Should -Be 'ticker'
        $result.Record.CinegyEventName | Should -Be 'Cinegy Type Layer 8 On'
        $tracked.Key | Should -Be 'Cinegy Type Layer 8 On'
    }
}

Describe 'Cinegy state reconciliation backoff' {
    It 'asks for no extra wait while the engine answers' {
        Get-BridgeCinegyStateBackoff -BaseIntervalSeconds 15 -CurrentBackoffSeconds 60 -Reachable | Should -Be 0
    }

    It 'starts backing off at twice the configured interval on the first failure' {
        Get-BridgeCinegyStateBackoff -BaseIntervalSeconds 15 -CurrentBackoffSeconds 0 | Should -Be 30
    }

    It 'doubles on each consecutive failure' {
        Get-BridgeCinegyStateBackoff -BaseIntervalSeconds 15 -CurrentBackoffSeconds 30 -MaximumSeconds 600 | Should -Be 60
    }

    It 'never exceeds the ceiling' {
        Get-BridgeCinegyStateBackoff -BaseIntervalSeconds 15 -CurrentBackoffSeconds 45 -MaximumSeconds 60 | Should -Be 60
        Get-BridgeCinegyStateBackoff -BaseIntervalSeconds 15 -CurrentBackoffSeconds 60 -MaximumSeconds 60 | Should -Be 60
    }

    It 'clears immediately on the first success rather than decaying' {
        # An operator fixing Air should get normal responsiveness back at once.
        Get-BridgeCinegyStateBackoff -BaseIntervalSeconds 15 -CurrentBackoffSeconds 60 -MaximumSeconds 60 -Reachable | Should -Be 0
    }
}

Describe 'Stale on-air detection' {
    BeforeAll { $script:Now = [datetime]'2026-08-23T18:00:00' }

    It 'reports a bridge record older than the threshold' {
        $onAir = @{ 7 = @{ Key = 'Urgent'; At = $script:Now.AddHours(-7); Source = 'bridge' } }
        $stale = @(Get-BridgeStaleOnAirLayers -OnAir $onAir -Now $script:Now -ThresholdHours 6)
        $stale.Count | Should -Be 1
        $stale[0].Layer | Should -Be 7
        $stale[0].Key | Should -Be 'Urgent'
        $stale[0].Hours | Should -Be 7
    }

    It 'leaves a recent record alone' {
        $onAir = @{ 7 = @{ Key = 'Urgent'; At = $script:Now.AddHours(-1); Source = 'bridge' } }
        @(Get-BridgeStaleOnAirLayers -OnAir $onAir -Now $script:Now -ThresholdHours 6) | Should -BeNullOrEmpty
    }

    It 'ignores Cinegy-owned scenes, which are legitimately up for days' {
        $onAir = @{ 8 = @{ Key = 'ticker'; At = $script:Now.AddDays(-3); Source = 'cinegy' } }
        @(Get-BridgeStaleOnAirLayers -OnAir $onAir -Now $script:Now -ThresholdHours 6) | Should -BeNullOrEmpty
    }

    It 'does not report a layer that was already alerted' {
        $onAir = @{ 7 = @{ Key = 'Urgent'; At = $script:Now.AddHours(-9); Source = 'bridge' } }
        @(Get-BridgeStaleOnAirLayers -OnAir $onAir -Now $script:Now -ThresholdHours 6 -AlreadyAlerted @(7)) | Should -BeNullOrEmpty
    }

    It 'is disabled by a zero threshold' {
        $onAir = @{ 7 = @{ Key = 'Urgent'; At = $script:Now.AddDays(-2); Source = 'bridge' } }
        @(Get-BridgeStaleOnAirLayers -OnAir $onAir -Now $script:Now -ThresholdHours 0) | Should -BeNullOrEmpty
    }

    It 'treats a record with no Source as bridge-pushed' {
        $onAir = @{ 7 = @{ Key = 'Urgent'; At = $script:Now.AddHours(-8) } }
        @(Get-BridgeStaleOnAirLayers -OnAir $onAir -Now $script:Now -ThresholdHours 6) | Should -HaveCount 1
    }
}

Describe 'External discovery needs positive evidence' {
    BeforeAll { $script:Now = [datetime]'2026-08-24T19:00:00' }

    It 'refuses to invent a scene for an anonymous placeholder item' {
        # Reproduces the live incident: on startup the bridge claimed layer 7
        # was on air while the screen was blank. A spent item stays Active,
        # briefly with no IsEmpty at all, reporting Cinegy's placeholder name.
        $status = [pscustomobject]@{
            Success = $true; IsOnAir = $true; ActiveId = '{F649F66B-9FC7-11F1-96C0-C85EA97266A8}'
            ActiveName = 'Item'; ActiveDescription = ''; ActiveTemplateName = ''
        }
        $decision = Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $null -Status $status -Now $script:Now -DiscoverExternal
        $decision.Action | Should -Be 'ignore'
    }

    It 'refuses an item with no name at all' {
        $status = [pscustomobject]@{
            Success = $true; IsOnAir = $true; ActiveId = '{F649F66B-0000-0000-0000-000000000000}'
            ActiveName = ''; ActiveDescription = ''; ActiveTemplateName = ''
        }
        (Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $null -Status $status -Now $script:Now -DiscoverExternal).Action | Should -Be 'ignore'
    }

    It 'still discovers a genuinely named external scene' {
        # A real scene always describes itself, e.g. "Show ticker.cintitle on layer 8".
        $status = [pscustomobject]@{
            Success = $true; IsOnAir = $true; ActiveId = '{BC14F2F9-9E38-11F1-96C0-C85EA97266A8}'
            ActiveName = 'Cinegy Type Layer 8 On'; ActiveDescription = 'Show ticker.cintitle on layer 8'
            ActiveTemplateName = 'ticker'
        }
        $decision = Resolve-BridgeCinegyLayerState -Layer 8 -TrackedRecord $null -Status $status -Now $script:Now -DiscoverExternal
        $decision.Action | Should -Be 'add'
        $decision.Record.Key | Should -Be 'ticker'
    }

    It 'never removes a tracked record just because the name went anonymous' {
        # The asymmetry is deliberate: ambiguity must not add, and must not
        # delete something an operator may still be able to see.
        $tracked = @{ Key = 'lower-third'; At = $script:Now; UserId = 42; ActiveId = '{AAA}'; Source = 'bridge' }
        $status = [pscustomobject]@{
            Success = $true; IsOnAir = $true; ActiveId = '{AAA}'
            ActiveName = 'Item'; ActiveDescription = ''; ActiveTemplateName = ''
        }
        $decision = Resolve-BridgeCinegyLayerState -Layer 3 -TrackedRecord $tracked -Status $status -Now $script:Now
        $decision.Action | Should -Not -Be 'remove'
    }
}
