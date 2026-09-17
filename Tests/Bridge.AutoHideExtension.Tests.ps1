#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Durable auto-hide and one-time extension' {
    BeforeEach {
        $script:autoHideFile = Join-Path $TestDrive 'autohide.json'
        $script:AutoHideQueue = [Collections.Generic.List[hashtable]]::new()
        $script:OnAir = @{}
        $script:UrgentBoardRun = $null
        $config.Settings | Add-Member TemplateMaxAirSeconds @{ urgent = 120 } -Force
        $config.Settings | Add-Member SensitiveTemplateKeys '' -Force
        $config.Settings | Add-Member TemplateAirExtensionEnabled $true -Force
        $config.Settings | Add-Member TemplateAirExtensionResponseSeconds 30 -Force
        $config.Settings | Add-Member TemplateAirExtensionMaxSeconds 900 -Force
        $script:testNow = [datetimeoffset]::Now
        $script:OnAir[7] = @{ Key = 'urgent'; At = $script:testNow.AddSeconds(-120); ActiveId = 'scene'; UserId = 101; ChatId = 100 }
        Mock Send-TelegramMessage {}
        Mock Edit-TelegramMessageText { $true }
        Mock Invoke-HideLayer { $true }
        Mock Get-TitlerLayerStatus { @{ Success = $true; IsOnAir = $true; ActiveId = 'scene' } }
        Mock Write-BridgeLog {}
        Mock Test-Admin { $false }
        Mock Test-Authorized { $true }
    }

    It 'offers one extension at the cap then hides when the reply window expires' {
        Set-AutoHideTimer -Layer 7 -Seconds 120 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Should -BeTrue
        Update-AutoHideQueue -Now $script:testNow
        $timer = $script:AutoHideQueue[0]
        $timer.Stage | Should -Be 'offer'
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        Update-AutoHideQueue -Now $script:testNow.AddSeconds(31)
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        $script:AutoHideQueue.Count | Should -Be 0
    }

    It 'accepts one publisher extension and rejects reuse then hides after the extension' {
        Set-AutoHideTimer -Layer 7 -Seconds 120 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Out-Null
        Update-AutoHideQueue -Now $script:testNow
        $token = $script:AutoHideQueue[0].Token
        Invoke-TemplateAirExtensionReply -Argument "${token}:extend:300" -ChatId 100 -UserId 999 -Now $script:testNow.AddSeconds(1) | Should -BeFalse
        Invoke-TemplateAirExtensionReply -Argument "${token}:extend:300" -ChatId 100 -UserId 101 -Now $script:testNow.AddSeconds(1) | Should -BeTrue
        $script:AutoHideQueue[0].ExtensionUsed | Should -BeTrue
        Invoke-TemplateAirExtensionReply -Argument "${token}:extend:300" -ChatId 100 -UserId 101 -Now $script:testNow.AddSeconds(2) | Should -BeFalse
        Update-AutoHideQueue -Now $script:testNow.AddSeconds(302)
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }

    It 'restores an unanswered offer and its original deadline from isolated disk' {
        Set-AutoHideTimer -Layer 7 -Seconds 120 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Out-Null
        Update-AutoHideQueue -Now $script:testNow
        $token = $script:AutoHideQueue[0].Token
        $deadline = $script:AutoHideQueue[0].At
        $script:AutoHideQueue.Clear()
        Import-AutoHideQueue
        $script:AutoHideQueue[0].Stage | Should -Be 'offer'
        $script:AutoHideQueue[0].Token | Should -Be $token
        ([datetimeoffset]$script:AutoHideQueue[0].At - [datetimeoffset]$deadline).TotalSeconds | Should -BeLessThan 1
        Invoke-TemplateAirExtensionReply -Argument "${token}:extend:300" -ChatId 100 -UserId 101 -Now $script:testNow.AddSeconds(1) | Should -BeTrue
        $script:AutoHideQueue.Clear()
        Import-AutoHideQueue
        $script:AutoHideQueue[0].ExtensionUsed | Should -BeTrue
    }

    It 'shortens a running show to its cap on explicit admin request only' {
        Set-AutoHideTimer -Layer 7 -Seconds 600 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Out-Null
        $script:AutoHideQueue[0].At = $script:testNow.AddSeconds(600)
        $script:AutoHideQueue[0].ShowAt = $script:testNow.AddSeconds(-120).ToString('o')
        Mock Test-Admin { $false }
        Request-TemplateAirLimitNow -Key urgent -ChatId 100 -UserId 101 | Should -BeFalse
        Mock Test-Admin { $true }
        Request-TemplateAirLimitNow -Key urgent -ChatId 100 -UserId 101 | Should -BeTrue
        $remaining = ([datetimeoffset]$script:AutoHideQueue[0].At - $script:testNow).TotalSeconds
        $remaining | Should -BeLessOrEqual 1
        Request-TemplateAirLimitNow -Key other -ChatId 100 -UserId 101 | Should -BeFalse
    }

    It 'sensitive templates hide at their ceiling with no extension offer' {
        $config.Settings.SensitiveTemplateKeys = 'urgent'
        Set-AutoHideTimer -Layer 7 -Seconds 120 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Out-Null
        Update-AutoHideQueue -Now $script:testNow
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        $script:AutoHideQueue.Count | Should -Be 0
    }

    It 'reaches the extension offer through the real callback path once' {
        Set-AutoHideTimer -Layer 7 -Seconds 120 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Out-Null
        Update-AutoHideQueue -Now $script:testNow
        $token = $script:AutoHideQueue[0].Token
        Mock Confirm-TelegramCallback {}
        $query = @{ id = 'ext-path'; from = @{ id = 101 }; message = @{ message_id = 9; chat = @{ id = 100; type = 'private' } }; data = "airext:${token}:extend:300" }
        Invoke-CallbackQuery $query
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        $script:AutoHideQueue[0].ExtensionUsed | Should -BeTrue
        $query.data = "airext:${token}:extend:300"
        Invoke-CallbackQuery $query
        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $Text -like '*انتهت صلاحية*' }
    }

    It 'hides a paused urgent run at its cap and leaves the run paused' {
        $script:UrgentBoardRun = @{ Layer = 7; Paused = $true; Step = 0; StartedAt = $script:testNow.ToString('o'); ElapsedSeconds = 0 }
        Set-AutoHideTimer -Layer 7 -Seconds 120 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Out-Null
        $script:AutoHideQueue[0].ExtensionUsed = $true
        $script:AutoHideQueue[0].At = $script:testNow
        Update-AutoHideQueue -Now $script:testNow
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        [bool](Get-JsonProp $script:UrgentBoardRun 'Paused') | Should -BeTrue
        $script:UrgentBoardRun.Paused = $false
    }

    It 'hides a frozen failed-stop run at its cap and keeps it retryable' {
        $script:UrgentBoardRun = @{ Layer = 7; Paused = $false; StopFailed = $true; Step = 0; StartedAt = $script:testNow.ToString('o'); ElapsedSeconds = 0 }
        Set-AutoHideTimer -Layer 7 -Seconds 120 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Out-Null
        $script:AutoHideQueue[0].ExtensionUsed = $true
        $script:AutoHideQueue[0].At = $script:testNow
        Update-AutoHideQueue -Now $script:testNow
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        [bool](Get-JsonProp $script:UrgentBoardRun 'StopFailed') | Should -BeTrue
        $script:UrgentBoardRun = $null
    }

    It 'retains failed hide for bounded retry rather than consuming it' {
        $config.Settings.TemplateAirExtensionEnabled = $false
        Set-AutoHideTimer -Layer 7 -Seconds 120 -ChatId 100 -UserId 101 -TemplateKey urgent -ActiveId scene | Should -BeTrue
        Mock Invoke-HideLayer { $false }
        Update-AutoHideQueue -Now $script:testNow
        $script:AutoHideQueue.Count | Should -Be 1
        $timer = $script:AutoHideQueue[0]
        ([datetimeoffset]$timer.RetryAt - $script:testNow).TotalSeconds | Should -BeIn @(5,10,15,30,60)
        Update-AutoHideQueue -Now $script:testNow.AddSeconds(1)
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        Mock Invoke-HideLayer { $true }
        Update-AutoHideQueue -Now $script:testNow.AddMinutes(1)
        $script:AutoHideQueue.Count | Should -Be 0
    }
}
