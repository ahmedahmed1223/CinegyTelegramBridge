#requires -Version 7
<#
    Smoke test for the onair.json persistence fix WITHOUT touching the live
    Cinegy/Telegram servers AND without writing to any real file.

    Strategy: instead of fighting PowerShell's scope rules for the internal
    $onAirFile variable, we mock Save-OnAirState/Import-OnAirState so the
    in-memory $OnAir hashtable is the single source of truth - exactly what
    the production code mutates. This isolates the regression we care about:
    a template on air must survive a sync that reports a different ActiveId,
    and must only be dropped when Cinegy reports the layer genuinely hidden.

    Run:  pwsh -File ./run_smoke.ps1
#>

BeforeDiscovery {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\CinegyAirTitler.psm1'
    Import-Module $modulePath -Force
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'TelegramBridge.ps1') -LoadOnly -ConfigPath 'config.example.json' -RuntimePath $TestDrive

    Mock Send-TelegramMessage { }
    Mock Write-BridgeLog { }
    # Persist in-memory only: mirror what the real Save/Import do, but to a
    # script-scoped hashtable so we never touch disk or fight $onAirFile scope.
    $script:Disk = @{}
    Mock Save-OnAirState {
        $script:Disk = @{}
        foreach ($k in $script:OnAir.Keys) { $script:Disk[$k] = $script:OnAir[$k] }
    }
    Mock Import-OnAirState {
        $script:OnAir = @{}
        foreach ($k in $script:Disk.Keys) { $script:OnAir[$k] = $script:Disk[$k] }
    }
}

AfterAll {
    $script:Disk = @{}
}

Describe 'OnAir persistence smoke test (no live server, no disk)' {

    BeforeEach { $script:OnAir.Clear(); $script:Disk.Clear() }
    AfterEach { $script:OnAir.Clear(); $script:Disk.Clear() }

    It 'keeps a pushed template recorded when Cinegy reports a different ActiveId but is on air' {
        # 1) Successful push tracked with the bot's own EventId.
        $script:OnAir[7] = @{
            Key     = 'بنر عاجل'
            At      = (Get-Date)
            UserId  = 7275359265
            ActiveId = '{BOT-EVENT-GUID-1111-2222-3333-444444444444}'
        }
        Save-OnAirState

        # 2) Cinegy: layer ON AIR, but with Cinegy's own id (ignores bot EventId).
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success  = $true
                IsOnAir  = $true
                ActiveId = '{CINEGY-ENGINE-GUID-AAAA-BBBB-CCCC-DDDDDDDDDDDD}'
                ActiveName = 'مسائي On'
                OutputState = 'Normal'; LicenseState = 'Licensed'
                ClientConnected = $true; ClientIdentity = 'Client 1'
            }
        }

        # 3) Sync must NOT drop the record (the production bug we fixed).
        $result = Update-OnAirStateFromCinegy -Reason 'smoke'
        $result.Removed | Should -Be @()
        $script:OnAir.ContainsKey(7) | Should -BeTrue
        $script:OnAir[7].Key | Should -Be 'بنر عاجل'
        # ActiveId is adopted from Cinegy.
        $script:OnAir[7].ActiveId | Should -Be '{CINEGY-ENGINE-GUID-AAAA-BBBB-CCCC-DDDDDDDDDDDD}'
        # The change is persisted to the in-memory mirror.
        $script:Disk.ContainsKey(7) | Should -BeTrue
    }

    It 'persists the live template and survives a reload (Import)' {
        $script:OnAir[7] = @{
            Key     = 'بنر عاجل'
            At      = (Get-Date)
            UserId  = 7275359265
            ActiveId = '{BOT-EVENT-GUID-1111-2222-3333-444444444444}'
        }
        Save-OnAirState

        # Reload from the persisted mirror (simulates a bridge restart).
        $script:OnAir.Clear()
        Import-OnAirState
        $script:OnAir.ContainsKey(7) | Should -BeTrue
        $script:OnAir[7].Key | Should -Be 'بنر عاجل'
    }

    It 'emits an external-change alert payload when a layer is removed as hidden' {
        $script:OnAir[7] = @{
            Key     = 'بنر عاجل'
            At      = (Get-Date)
            UserId  = 7275359265
            ActiveId = '{BOT-EVENT-GUID-1111-2222-3333-444444444444}'
        }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = '' }
        }

        $result = Update-OnAirStateFromCinegy -Reason 'smoke-hide'
        $result.Removed | Should -Be @(7)
        $result.Changes.Count | Should -Be 1
        $result.Changes[0].TemplateKey | Should -Be 'بنر عاجل'
        $result.Changes[0].Layer | Should -Be 7
        $script:OnAir.ContainsKey(7) | Should -BeFalse
    }

    It 'removes the record only when Cinegy genuinely reports the layer hidden' {
        $script:OnAir[7] = @{
            Key     = 'بنر عاجل'
            At      = (Get-Date)
            UserId  = 7275359265
            ActiveId = '{BOT-EVENT-GUID-1111-2222-3333-444444444444}'
        }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = '' }
        }

        $result = Update-OnAirStateFromCinegy -Reason 'smoke-hide2'
        $result.Removed | Should -Be @(7)
        $script:OnAir.ContainsKey(7) | Should -BeFalse
    }

    It 'does not lose the record when the Cinegy query times out' {
        $script:OnAir[7] = @{
            Key     = 'بنر عاجل'
            At      = (Get-Date)
            UserId  = 7275359265
            ActiveId = '{BOT-EVENT-GUID-1111-2222-3333-444444444444}'
        }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $false; IsOnAir = $null; Error = 'timeout' }
        }

        $result = Update-OnAirStateFromCinegy -Reason 'smoke-timeout'
        $result.Failed | Should -Be @(7)
        $script:OnAir.ContainsKey(7) | Should -BeTrue
    }
}
