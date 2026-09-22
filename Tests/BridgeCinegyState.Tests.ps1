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

Describe 'An unnamed item is not a claim that a scene is showing' {
    BeforeAll {
        # This engine names nothing it plays. Taken from a live channel: the
        # visible news strip and a bulletin that had already exited were
        # identical in every field it exposes.
        function global:New-TestUnnamedStatus {
            param([string]$ActiveId = '{DCE287A8-A7A8-11F1-96C0-C85EA97266A8}')
            [pscustomobject]@{
                Success = $true; IsOnAir = $true; ActiveId = $ActiveId
                ActiveName = ''; ActiveTemplateName = ''; ActiveDescription = ''
                OutputState = 'Normal'; ClientConnected = $false; ClientIdentity = ''
                Error = ''
                ActiveXml = '<Item Id="' + $ActiveId + '" LogId="{C63E2EC6-8BFA-4133-B414-9FFC760E9C58}" ScheduledAt="2026-09-03T15:05:13.857Z" Duration="24:00:00.000" Clocked="y" ManualEnd="y"/>'
            }
        }
    }

    It 'discovers nothing from an item the engine will not name' {
        # Naming it from the template registry was tried and withdrawn: an
        # exited bulletin leaves an item that reads exactly like a live one, so
        # the bot announced a bulletin that had left the screen hours before.
        (Resolve-BridgeCinegyLayerState -Layer 5 -Status (New-TestUnnamedStatus) -DiscoverExternal).Action |
            Should -Be 'ignore'
    }

    It 'drops a discovered record left over from when it did' {
        # Such a record survives a restart in onair.json, so without this it
        # would claim air for ever.
        $stale = @{ Key = 'Mojaz'; At = (Get-Date); UserId = 0L; ActiveId = '{DCE287A8-A7A8-11F1-96C0-C85EA97266A8}'; Source = 'cinegy' }
        (Resolve-BridgeCinegyLayerState -Layer 5 -TrackedRecord $stale -Status (New-TestUnnamedStatus)).Action |
            Should -Be 'remove'
    }

    It 'never drops what the bridge itself put there' {
        # A bridge-pushed record is the bridge's own knowledge of what it did,
        # and a read that cannot represent an exit is not evidence against it.
        $pushed = @{ Key = 'News-Ticker'; At = (Get-Date); UserId = 7L; ActiveId = '{DCE287A8-A7A8-11F1-96C0-C85EA97266A8}'; Source = 'bridge' }
        (Resolve-BridgeCinegyLayerState -Layer 8 -TrackedRecord $pushed -Status (New-TestUnnamedStatus)).Action |
            Should -Be 'keep'
    }

    It 'keeps a discovered record the engine still names' {
        $named = New-TestUnnamedStatus
        $named.ActiveTemplateName = 'Show L band - New.CinTitle on Layer 4'
        $tracked = @{ Key = 'Show L band - New.CinTitle on Layer 4'; At = (Get-Date); UserId = 0L; ActiveId = '{DCE287A8-A7A8-11F1-96C0-C85EA97266A8}'; Source = 'cinegy' }
        (Resolve-BridgeCinegyLayerState -Layer 4 -TrackedRecord $tracked -Status $named).Action |
            Should -Be 'keep'
    }
}

Describe 'Telling an operator WHY their graphic left the layer' {
    <#
        Reported from the field, verbatim:

            ⚠️ تغيير خارجي في Cinegy
            طبقة الخبر العاجل · طبقة 7: استُبدل خارجيًا
            العنصر الحالي: عنصر غير مسمّى | المعرّف: {B092DCC7-...}

        The bridge's own log line for that same decision said "Cinegy confirmed
        hidden". Two stories from one decision, and the alarming one was wrong:
        an urgent graphic had simply ended, and the spent playlist item stayed
        Active on layer 7 with its Id intact and no name - the exact shape the
        discovery path has refused to treat as a scene for years.

        "Replaced" was derived from "ActualActiveId is not empty", which an
        ended scene satisfies. The operator was told a stranger had taken the
        layer.
    #>
    BeforeAll {
        function global:New-TestSpentItemStatus {
            <# What Cinegy reports on a layer whose graphic has just ended: off
               air, id intact, nothing named. #>
            param([string]$ActiveName = '')
            [pscustomobject]@{
                Success = $true; IsOnAir = $false
                ActiveId = '{B092DCC7-B5D0-11F1-96C5-C85EA97266A8}'
                ActiveName = $ActiveName; ActiveTemplateName = ''; ActiveDescription = ''
                OutputState = 'Normal'; ClientConnected = $false; ClientIdentity = ''
                Error = ''
            }
        }
        $script:TestUrgentRecord = @{
            Key = 'Urgent'; At = (Get-Date); UserId = 7275359265L
            ActiveId = '{AA74CB64-B5D0-11F1-96C5-C85EA97266A8}'; Source = 'bridge'
        }
    }

    It 'does not call an ended graphic an external replacement' {
        $decision = Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $script:TestUrgentRecord -Status (New-TestSpentItemStatus)

        $decision.Action | Should -Be 'remove'
        $decision.Change.Replaced | Should -BeFalse -Because 'an id outlives the scene that owned it; only a NAME is evidence a stranger took the layer'
    }

    It 'treats the placeholder name Item as no name at all' {
        # Cinegy reports "Item" for a spent entry and for an empty layer alike.
        (Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $script:TestUrgentRecord -Status (New-TestSpentItemStatus -ActiveName 'Item')).Change.Replaced |
            Should -BeFalse
    }

    It 'still reports a real replacement, which is the whole point of the notice' {
        # A genuine external take-over must not be softened away by this fix.
        $taken = New-TestSpentItemStatus
        $taken.ActiveName = 'Show L band - New.CinTitle on Layer 7'

        $decision = Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $script:TestUrgentRecord -Status $taken

        $decision.Change.Replaced | Should -BeTrue
        $decision.Change.ActualActiveName | Should -Be 'Show L band - New.CinTitle on Layer 7'
    }

    It 'keeps the id in the change either way, because diagnosis still wants it' {
        (Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $script:TestUrgentRecord -Status (New-TestSpentItemStatus)).Change.ActualActiveId |
            Should -Be '{B092DCC7-B5D0-11F1-96C5-C85EA97266A8}'
    }

    It 'asks one rule, so discovery and removal cannot disagree' {
        # The two paths answered the same question differently for years: this
        # is the rule both now call.
        Test-BridgeCinegyNamedScene -Status (New-TestSpentItemStatus) | Should -BeFalse
        Test-BridgeCinegyNamedScene -Status (New-TestSpentItemStatus -ActiveName 'Item') | Should -BeFalse
        Test-BridgeCinegyNamedScene -Status (New-TestSpentItemStatus -ActiveName 'Lower third.CinTitle on Layer 4') | Should -BeTrue
    }
}

Describe 'Why a layer read as off air' {
    <#
        Asked in the field: an urgent left the air twice in half an hour and
        nobody had touched Cinegy. The audit settled what the bridge did - two
        SHOWs on layer 7 that day and no HIDE, no EXIT - but not what the
        engine had said, because every removal was logged with the same
        sentence, "Cinegy confirmed hidden".

        Get-TitlerLayerStatus reaches IsOnAir = $false two different ways:
        /status carries no active item id at all, in which case /status/active
        is never even called, or the active item is the engine's own filler
        with IsEmpty="y". The first is the engine saying nothing; the second is
        the engine saying nothing is showing. The log could not tell them
        apart, so the one question it exists to answer had no answer.

        The reason is named where it is decided and carried to the line that
        prints it. This costs nothing and cannot change what the bridge does.
    #>
    It 'carries the reason from the status to the change' {
        $status = [pscustomobject]@{
            Success = $true; IsOnAir = $false; OffAirReason = 'empty-item'
            ActiveId = '{684580B2-B668-11F1-96C5-C85EA97266A8}'
            ActiveName = ''; ActiveTemplateName = ''; ActiveDescription = ''
            OutputState = 'Normal'; ClientConnected = $false; ClientIdentity = ''
            Error = ''
        }
        $record = @{ Key = 'Urgent'; UserId = 7275359265L; At = (Get-Date); ActiveId = '{OLD}'; Source = 'bridge' }
        $decision = Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $record -Status $status
        $decision.Action | Should -Be 'remove'
        $decision.Change.OffAirReason | Should -Be 'empty-item'
    }

    It 'says nothing rather than guessing when the status carries no reason' {
        # An older status object, or a caller that built one by hand: the
        # change still resolves, with an empty reason the log renders as
        # "unstated" rather than inventing one of the two.
        $status = [pscustomobject]@{
            Success = $true; IsOnAir = $false
            ActiveId = ''; ActiveName = ''; ActiveTemplateName = ''; ActiveDescription = ''
            OutputState = 'Normal'; ClientConnected = $false; ClientIdentity = ''
            Error = ''
        }
        $record = @{ Key = 'Urgent'; UserId = 1L; At = (Get-Date); ActiveId = ''; Source = 'bridge' }
        (Resolve-BridgeCinegyLayerState -Layer 7 -TrackedRecord $record -Status $status).Change.OffAirReason |
            Should -BeNullOrEmpty
    }
}
