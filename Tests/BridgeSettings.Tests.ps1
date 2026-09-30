#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeSettings.psm1') -Force
}

Describe 'Bridge settings module' {
    BeforeEach {
        $script:defaults = [ordered]@{ Enabled=$false; Limit=12; Label='default' }
    }

    It 'reads ordered settings without silently substituting defaults' {
        $config = [ordered]@{ Settings = [ordered]@{ Enabled = $true; Limit = 7 } }
        Get-BridgeSetting -Config $config -Defaults $script:defaults -Name Enabled | Should -BeTrue
        Get-BridgeSettingInt -Config $config -Defaults $script:defaults -Name Limit | Should -Be 7
    }

    It 'persists missing settings as dictionary keys and preserves identities' {
        $config = [ordered]@{ Settings = [ordered]@{ Enabled = $true }; AllowedUserIds = @(10); AdminUserIds = @(20) }
        Initialize-BridgeSettings -Config $config -Defaults $script:defaults | Should -BeTrue
        $saved = $config | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $saved.Settings.Enabled | Should -BeTrue
        $saved.Settings.Limit | Should -Be 12
        @($saved.AllowedUserIds) | Should -Be @(10)
        @($saved.AdminUserIds) | Should -Be @(20)
        Initialize-BridgeSettings -Config $config -Defaults $script:defaults | Should -BeFalse
    }

    It 'creates missing settings and identities as serializable keys on a dictionary' {
        $config = @{}
        Initialize-BridgeSettings -Config $config -Defaults $script:defaults | Should -BeTrue
        $config.ContainsKey('Settings') | Should -BeTrue
        $config.ContainsKey('AllowedUserIds') | Should -BeTrue
        $config.ContainsKey('AdminUserIds') | Should -BeTrue
    }

    It 'uses configured values and falls back to schema defaults for missing values' {
        $config = [pscustomobject]@{ Settings=[pscustomobject]@{ Enabled=$true } }

        Get-BridgeSetting -Config $config -Defaults $script:defaults -Name Enabled | Should -BeTrue
        Get-BridgeSetting -Config $config -Defaults $script:defaults -Name Label | Should -Be 'default'
        Get-BridgeSetting -Config $config -Defaults $script:defaults -Name Missing | Should -BeNullOrEmpty
    }

    It 'normalizes invalid and below-minimum integer settings at the requested boundary' {
        $invalid = [pscustomobject]@{ Settings=[pscustomobject]@{ Limit='not-a-number' } }
        $below = [pscustomobject]@{ Settings=[pscustomobject]@{ Limit=-4 } }

        Get-BridgeSettingInt -Config $invalid -Defaults $script:defaults -Name Limit -Minimum 3 | Should -Be 3
        Get-BridgeSettingInt -Config $below -Defaults $script:defaults -Name Limit -Minimum 3 | Should -Be 3
    }

    It 'initializes only missing settings and identity arrays without overwriting configured values' {
        $config = [pscustomobject]@{ Settings=[pscustomobject]@{ Enabled=$true } }

        $changed = Initialize-BridgeSettings -Config $config -Defaults $script:defaults

        $changed | Should -BeTrue
        $config.Settings.Enabled | Should -BeTrue
        $config.Settings.Limit | Should -Be 12
        $config.Settings.Label | Should -Be 'default'
        @($config.AllowedUserIds).Count | Should -Be 0
        @($config.AdminUserIds).Count | Should -Be 0
    }

    It 'reports no change when the complete schema and identity arrays already exist' {
        $config = [pscustomobject]@{
            Settings=[pscustomobject]@{ Enabled=$true; Limit=7; Label='custom' }
            AllowedUserIds=@(10)
            AdminUserIds=@(20)
        }

        Initialize-BridgeSettings -Config $config -Defaults $script:defaults | Should -BeFalse
    }
}
