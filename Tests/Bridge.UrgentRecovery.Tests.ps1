#requires -Version 7

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Urgent playback recovery safety' {
    BeforeEach {
        Mock Get-UrgentRunFile { Join-Path $TestDrive 'urgent-recovery.json' }
        Mock Get-UrgentTemplate { @{ Layer = 7; Path = 'unused.cintitle'; Fields = @('Headline.Text') } }
        Mock Write-BridgeLog {}
        Mock Write-UrgentRunEnd {}
        Mock Show-UrgentBoardScreen {}
        Mock Send-TelegramMessage {}
        Mock Send-AdminBroadcast {}
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { @{ Success = $true; Xml = '' } }
        Mock Show-TitlerTemplate { @{ Success = $true } }
        Mock Exit-TitlerScene { @{ Success = $true } }
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'UrgentSyncLeadMs' }
        Mock Get-AirTimeout { 1 }
        Mock Start-Sleep {}
        $script:MojazUrgentKey = 'Urgent'
        $script:OnAir = @{ 7 = @{ Key = 'Urgent' } }
        $script:UrgentBoardRun = @{
            Step = 0; ChatId = [long]100; UserId = [long]101
            Clock = [System.Diagnostics.Stopwatch]::new(); ClockOffset = 0.0
            StartedAt = (Get-Date).ToString('o'); Paused = $false; StopFailed = $false
            ExitAtSeconds = 30.0; BoardRevision = 1; OperationId = 'urgent-recovery'; Summary = 'test'
            Steps = @(
                @{ Step = 0; AtSeconds = 0; Mode = 'text'; Text = 'first'; Title = '' }
                @{ Step = 1; AtSeconds = 10; Mode = 'text'; Text = 'second'; Title = '' }
                @{ Step = 2; AtSeconds = 20; Mode = 'text'; Text = 'third'; Title = '' }
            )
        }
    }
    AfterEach {
        $script:UrgentBoardRun = $null
        $script:OnAir = @{}
    }

    It 'does not announce completion when the final exit fails' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'UrgentBoardNotifyOnFinish' }
        Mock Invoke-ExitLayer { $false }
        $script:UrgentBoardRun.Step = 2
        $script:UrgentBoardRun.ClockOffset = 31

        Update-UrgentBoardRun

        Should -Invoke Send-TelegramMessage -Times 0 -Exactly -ParameterFilter { $Text -eq '⏹ انتهى جدول العواجل وخرج عن الهواء.' }
        $script:UrgentBoardRun.StopFailed | Should -BeTrue
        Should -Invoke Write-UrgentRunEnd -Times 0 -Exactly
    }

    It 'keeps its state after <Label>' -ForEach @(
        @{ Label = 'a thrown exit'; Throws = $true }
        @{ Label = 'a vanished template'; Throws = $false }
    ) {
        if ($Throws) { Mock Invoke-ExitLayer { throw 'Cinegy hung up' } }
        else { Mock Get-UrgentTemplate { $null } }

        Stop-UrgentBoardRun -ChatId 100 -UserId 101 -Quiet | Should -BeFalse

        $script:UrgentBoardRun | Should -Not -BeNullOrEmpty
        $script:UrgentBoardRun.StopFailed | Should -BeTrue
        $script:UrgentBoardRun.Clock.IsRunning | Should -BeFalse
        $script:UrgentBoardRun.Paused | Should -BeTrue
        Test-Path -LiteralPath (Get-UrgentRunFile) | Should -BeTrue
    }

    It 'keeps an expired restore retryable after <Label>' -ForEach @(
        @{ Label = 'exit returns false'; Throws = $false }
        @{ Label = 'exit throws'; Throws = $true }
    ) {
        $script:UrgentBoardRun.ClockOffset = 40
        Save-UrgentRunState | Should -BeTrue
        $script:UrgentBoardRun = $null
        if ($Throws) { Mock Invoke-ExitLayer { throw 'offline' } }
        else { Mock Invoke-ExitLayer { $false } }

        Restore-UrgentBoardRun | Should -BeFalse

        $script:UrgentBoardRun.StopFailed | Should -BeTrue
        $script:UrgentBoardRun.Paused | Should -BeTrue
        $script:UrgentBoardRun.Clock.IsRunning | Should -BeFalse
        $saved = Get-Content -LiteralPath (Get-UrgentRunFile) -Raw | ConvertFrom-Json
        $saved.StopFailed | Should -BeTrue
        $saved.Paused | Should -BeTrue
        Update-UrgentBoardRun
        Should -Invoke Send-PostboxValues -Times 0 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
        Mock Invoke-ExitLayer { $true }
        Stop-UrgentBoardRun -Quiet | Should -BeTrue
        Test-Path -LiteralPath (Get-UrgentRunFile) | Should -BeFalse
        $script:UrgentBoardRun | Should -BeNullOrEmpty
    }

    It 'sends the first overdue line after restoring the persisted last-sent step' {
        $script:UrgentBoardRun.ClockOffset = 22
        Save-UrgentRunState | Should -BeTrue
        $script:UrgentBoardRun = $null

        Restore-UrgentBoardRun | Should -BeTrue

        $script:UrgentBoardRun.Step | Should -Be 0
        Should -Invoke Send-PostboxValues -Times 0 -Exactly
        Update-UrgentBoardRun
        Should -Invoke Send-PostboxValues -Times 1 -Exactly -ParameterFilter { $Values['Headline.Text'] -eq 'second' }
        $script:UrgentBoardRun.Step | Should -Be 1
    }

    It 'announces completion only after a successful exit' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'UrgentBoardNotifyOnFinish' }
        Mock Invoke-ExitLayer {
            Should -Invoke Send-TelegramMessage -Times 0 -Exactly -ParameterFilter { $Text -eq '⏹ انتهى جدول العواجل وخرج عن الهواء.' }
            return $true
        }
        $script:UrgentBoardRun.Step = 2
        $script:UrgentBoardRun.ClockOffset = 31

        Update-UrgentBoardRun

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -eq '⏹ انتهى جدول العواجل وخرج عن الهواء.' }
        $script:UrgentBoardRun | Should -BeNullOrEmpty
    }

    It 'keeps a failed stop frozen through another disk restore until a successful retry' {
        Mock Invoke-ExitLayer { $false }
        Stop-UrgentBoardRun -Quiet | Should -BeFalse
        $script:UrgentBoardRun = $null

        Restore-UrgentBoardRun | Should -BeTrue

        $script:UrgentBoardRun.StopFailed | Should -BeTrue
        $script:UrgentBoardRun.Paused | Should -BeTrue
        $script:UrgentBoardRun.Clock.IsRunning | Should -BeFalse
        Resume-UrgentBoardRun -ChatId 100 | Should -BeFalse
        Move-UrgentBoardNext -ChatId 100 | Should -BeFalse
        Update-UrgentBoardRun
        Should -Invoke Send-PostboxValues -Times 0 -Exactly
        Mock Invoke-ExitLayer { $true }
        Stop-UrgentBoardRun -Quiet | Should -BeTrue
        Test-Path -LiteralPath (Get-UrgentRunFile) | Should -BeFalse
    }

    It 'retains a retryable run when template lookup itself throws' {
        Mock Get-UrgentTemplate { throw 'registry unreadable' }

        Stop-UrgentBoardRun -Quiet | Should -BeFalse

        $script:UrgentBoardRun.StopFailed | Should -BeTrue
        Test-Path -LiteralPath (Get-UrgentRunFile) | Should -BeTrue
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'rejects an out-of-range persisted step <Index>' -ForEach @(@{ Index = -1 }, @{ Index = 3 }) {
        $script:UrgentBoardRun.Step = $Index
        Save-UrgentRunState | Should -BeTrue
        $script:UrgentBoardRun = $null

        Restore-UrgentBoardRun | Should -BeFalse

        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'retains the durable snapshot while exit calls back into layer stop' {
        Save-UrgentRunState | Should -BeTrue
        Mock Invoke-ExitLayer {
            Test-Path -LiteralPath (Get-UrgentRunFile) | Should -BeTrue
            Stop-UrgentBoardForLayer -Layer 7 | Should -BeFalse
            return $true
        }

        Stop-UrgentBoardRun -Quiet | Should -BeTrue

        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Get-UrgentRunFile) | Should -BeFalse
        Should -Invoke Write-UrgentRunEnd -Times 1 -Exactly
    }

    It 'does not attach a restored run to <Label> at elapsed <Elapsed>' -ForEach @(
        @{ Label = 'another template'; Record = @{ Key = 'Other' }; Elapsed = 12 }
        @{ Label = 'an unidentified record'; Record = @{ At = 'unknown' }; Elapsed = 12 }
        @{ Label = 'another template'; Record = @{ Key = 'Other' }; Elapsed = 40 }
    ) {
        $script:UrgentBoardRun.ClockOffset = $Elapsed
        Save-UrgentRunState | Should -BeTrue
        $script:UrgentBoardRun = $null
        $script:OnAir[7] = $Record

        Restore-UrgentBoardRun | Should -BeFalse

        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Get-UrgentRunFile) | Should -BeFalse
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
        Should -Invoke Send-PostboxValues -Times 0 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }
}
