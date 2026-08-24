#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeInstall.psm1') -Force

    function New-ReadyConfig {
        param([hashtable]$Settings = @{})
        [pscustomobject]@{
            BotToken       = '123456789:AAExampleTokenValueForTestsOnly1234567'
            AdminChatIds   = @(122238225)
            AllowedChatIds = @(122238225, 962418094)
            Settings       = [pscustomobject]$Settings
        }
    }
    function Invoke-Readiness {
        param($Config, [hashtable]$Overrides = @{})
        $splat = @{
            Config = $Config; RunAsAccount = 'SYSTEM'; HasPowerShell7 = $true
            HasFfmpeg = $true; TemplatesReadable = $true
        }
        foreach ($key in $Overrides.Keys) { $splat[$key] = $Overrides[$key] }
        return Get-BridgeReadinessReport @splat
    }
}

Describe 'Install readiness' {
    It 'accepts a complete configuration' {
        $report = Invoke-Readiness -Config (New-ReadyConfig)
        $report.Ok | Should -BeTrue
        $report.Errors | Should -BeNullOrEmpty
    }

    It 'refuses a missing or unparsable config without inspecting further' {
        $report = Invoke-Readiness -Config $null
        $report.Ok | Should -BeFalse
        @($report.Errors).Count | Should -Be 1
    }

    It 'refuses a missing PowerShell 7' {
        (Invoke-Readiness -Config (New-ReadyConfig) -Overrides @{ HasPowerShell7 = $false }).Ok | Should -BeFalse
    }

    It 'refuses the placeholder token shipped in config.example.json' {
        $config = New-ReadyConfig
        $config.BotToken = 'REPLACE_WITH_YOUR_BOT_TOKEN'
        (Invoke-Readiness -Config $config).Ok | Should -BeFalse
    }

    It 'refuses a configuration with no administrator' {
        # Without one, nobody can administer the bot or receive its alerts -
        # including the alert saying something is wrong.
        $config = New-ReadyConfig
        $config.AdminChatIds = @()
        (Invoke-Readiness -Config $config).Ok | Should -BeFalse
    }

    It 'refuses an unreadable template registry' {
        $report = Invoke-Readiness -Config (New-ReadyConfig) -Overrides @{ TemplatesReadable = $false; TemplatesError = 'invalid JSON' }
        $report.Ok | Should -BeFalse
        $report.Errors -join ' ' | Should -Match 'invalid JSON'
    }

    It 'refuses DPAPI secrets protected for a different account than the service runs as' {
        # This is the trap the whole check exists for: CurrentUser DPAPI is
        # unreadable by SYSTEM, so the bridge would start, fail to decrypt, and
        # be restarted for ever while looking Running.
        $config = New-ReadyConfig -Settings @{ EnableDpapiSecrets = $true }
        $report = Invoke-Readiness -Config $config -Overrides @{ ProtectedBy = 'PLAYOUT\operator' }
        $report.Ok | Should -BeFalse
        $report.Errors -join ' ' | Should -Match 'SYSTEM'
    }

    It 'accepts DPAPI secrets protected by the very account the service uses' {
        $config = New-ReadyConfig -Settings @{ EnableDpapiSecrets = $true }
        $report = Invoke-Readiness -Config $config -Overrides @{ ProtectedBy = 'NT AUTHORITY\SYSTEM' }
        $report.Ok | Should -BeTrue
    }

    It 'ignores the account question entirely when DPAPI is off' {
        $report = Invoke-Readiness -Config (New-ReadyConfig -Settings @{ EnableDpapiSecrets = $false })
        $report.Ok | Should -BeTrue
    }

    It 'warns about a missing ffmpeg without blocking the install' {
        # It only costs snapshots and the relay; refusing to install would be
        # worse than saying so.
        $config = New-ReadyConfig -Settings @{ EnableSnapshot = $true }
        $report = Invoke-Readiness -Config $config -Overrides @{ HasFfmpeg = $false }
        $report.Ok | Should -BeTrue
        $report.Warnings -join ' ' | Should -Match 'ffmpeg'
    }

    It 'stays quiet about ffmpeg when nothing needs it' {
        $report = Invoke-Readiness -Config (New-ReadyConfig) -Overrides @{ HasFfmpeg = $false }
        $report.Warnings | Should -BeNullOrEmpty
    }

    It 'warns, but does not block, when no operators are whitelisted yet' {
        $config = New-ReadyConfig
        $config.AllowedChatIds = @()
        $report = Invoke-Readiness -Config $config
        $report.Ok | Should -BeTrue
        $report.Warnings | Should -Not -BeNullOrEmpty
    }
}

Describe 'Post-start verdict' {
    It 'calls a single clean start healthy' {
        (Get-BridgeStartVerdict -State 'Running' -StartupLinesSinceLaunch 1 -SawTelegramConnection).Healthy | Should -BeTrue
    }

    It 'calls a stopped service unhealthy' {
        (Get-BridgeStartVerdict -State 'Stopped' -StartupLinesSinceLaunch 1).Healthy | Should -BeFalse
    }

    It 'catches a crash loop that reports Running' {
        # Repeated restarts are the failure mode a plain status check misses:
        # the supervisor keeps it Running most times you look.
        $verdict = Get-BridgeStartVerdict -State 'Running' -StartupLinesSinceLaunch 4
        $verdict.Healthy | Should -BeFalse
        $verdict.Reason | Should -Match 'crashing'
    }

    It 'catches a service that is up while the bridge never started' {
        (Get-BridgeStartVerdict -State 'Running' -StartupLinesSinceLaunch 0).Healthy | Should -BeFalse
    }

    It 'passes a started bridge that has not connected yet, but says so' {
        $verdict = Get-BridgeStartVerdict -State 'Running' -StartupLinesSinceLaunch 1
        $verdict.Healthy | Should -BeTrue
        $verdict.Reason | Should -Match 'no Telegram connection'
    }
}
