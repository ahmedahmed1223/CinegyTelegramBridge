#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Per-template maximum on-air lifetime' {
    BeforeEach {
        $config.Settings | Add-Member TemplateMaxAirSeconds @{ urgent = 120 } -Force
        $config.Settings | Add-Member SensitiveTemplateKeys '' -Force
    }
    AfterEach {
        $config.Settings | Add-Member TemplateMaxAirSeconds @{} -Force
        $config.Settings | Add-Member SensitiveTemplateKeys '' -Force
    }
    It 'lets only an admin save a template cap with button state' {
        Mock Test-Admin { $true }
        Mock Save-Config { $script:LastConfigSaveFailed = $false }
        Mock Send-TelegramMessage {}
        Mock Edit-TelegramMessageText { $true }
        Mock Get-TemplateStore { @{ Order = @('urgent'); Map = @{ urgent = @{ Key = 'urgent' } } } }
        Show-TemplateMaxAirEditor -ChatId 100 -UserId 101
        $state = Get-PendingState -ChatId 100
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):item:0" | Out-Null
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):set:180" | Should -BeTrue
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 180
        Mock Test-Admin { $false }
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):set:600" | Should -BeFalse
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 180
    }

    It 'opens the admin editor through the actual settings callback' {
        Mock Test-Admin { $true }
        Mock Test-Authorized { $true }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserNameFromTelegram {}
        Mock Update-UserLastActivity {}
        Mock Send-TelegramMessage {}
        Mock Edit-TelegramMessageText { $true }
        Mock Save-Config { $script:LastConfigSaveFailed = $false }
        Mock Get-TemplateStore { @{ Order = @('urgent'); Map = @{ urgent = @{ Key = 'urgent' } } } }
        $query = @{ id = 'cap-test'; from = @{ id = 101 }; message = @{ message_id = 42; chat = @{ id = 100; type = 'private' } }; data = 'cfg:s:TemplateMaxAirSeconds' }
        Invoke-CallbackQuery $query
        $state = Get-PendingState -ChatId 100
        $state.Mode | Should -Be 'template_max_air'
        $query.data = "tmax:$($state.Token):item:0"
        Invoke-CallbackQuery $query
        $query.data = "tmax:$($state.Token):set:180"
        Invoke-CallbackQuery $query
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 180
    }

    It 'does not extend a running template beyond its original maximum deadline' {
        Mock Save-AutoHideQueue { $true }
        $now = [datetimeoffset]::Now
        $script:AutoHideQueue.Clear()
        $script:OnAir[7] = @{ Key = 'urgent'; At = $now.AddSeconds(-100); ActiveId = 'cap-scene' }
        Set-AutoHideTimer -Layer 7 -Seconds 600 -ChatId 100 -TemplateKey urgent -ActiveId 'cap-scene' | Should -BeTrue
        $timer = @($script:AutoHideQueue)[0]
        ([datetimeoffset]$timer.At - $now).TotalSeconds | Should -BeLessOrEqual 21
        $script:AutoHideQueue.Clear()
        $script:OnAir.Remove(7)
    }

    It 'requires a fresh confirmation before disabling a cap and rolls back failed saves' {
        Mock Test-Admin { $true }
        Mock Save-Config { $script:LastConfigSaveFailed = $false }
        Mock Send-TelegramMessage {}
        Mock Get-TemplateStore { @{ Order = @('urgent'); Map = @{ urgent = @{ Key = 'urgent' } } } }
        Show-TemplateMaxAirEditor -ChatId 100 -UserId 101
        $state = Get-PendingState -ChatId 100
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):item:0" | Out-Null
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):disable:yes" | Should -BeFalse
        Mock Save-Config { $script:LastConfigSaveFailed = $true }
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):set:600" | Should -BeFalse
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 120
        Mock Save-Config { $script:LastConfigSaveFailed = $false }
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):disable:ask" | Out-Null
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):disable:yes" | Should -BeTrue
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 0
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):disable:yes" | Should -BeFalse
    }

    It 'rejects a previous template screen after selecting another template' {
        Mock Test-Admin { $true }
        Mock Save-Config { $script:LastConfigSaveFailed = $false }
        Mock Send-TelegramMessage {}
        Mock Get-TemplateStore { @{ Order = @('urgent', 'other'); Map = @{ urgent = @{}; other = @{} } } }
        Show-TemplateMaxAirEditor -ChatId 100 -UserId 101
        $state = Get-PendingState -ChatId 100
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):item:0" | Out-Null
        $oldToken = [string]$state.Token
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):page:0" | Out-Null
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):item:1" | Out-Null
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "${oldToken}:set:600" | Should -BeFalse
        Get-EffectiveAutoHideSeconds -Key other | Should -Be 0
    }

    It 'offers the dedicated editor rather than a numeric stepper in settings' {
        $buttons = @()
        for ($page = 0; $page -lt 10; $page++) {
            $keyboard = Get-SettingsCategoryKeyboard -Category templates -Page $page
            $buttons += @($keyboard.inline_keyboard | ForEach-Object { $_ })
        }
        @($buttons | Where-Object callback_data -eq 'cfg:s:TemplateMaxAirSeconds').Count | Should -BeGreaterThan 0
        @($buttons | Where-Object callback_data -eq 'cfg:v:TemplateMaxAirSeconds').Count | Should -Be 0
    }

    It 'caps a requested 600 seconds at the selected template maximum of 120' {
        Get-EffectiveAutoHideSeconds -Key urgent -RequestedSeconds 600 | Should -Be 120
        Get-EffectiveAutoHideSeconds -Key other -RequestedSeconds 600 | Should -Be 600
        Get-EffectiveAutoHideSeconds -Key other | Should -Be 0
    }
}

Describe 'Typing a custom maximum air time' {
    <#
        Reported: the custom button answered with an error and the ceiling
        could not be typed. The button's action, 'custom', was missing from
        the pattern every tmax: button is checked against, so it was refused
        as expired before its own branch ran. And a duration typed on an
        Arabic keyboard ("٩٠") matched \d but threw on [int].
    #>
    BeforeEach {
        $config.Settings | Add-Member TemplateMaxAirSeconds @{} -Force
        Mock Test-Admin { $true }
        Mock Save-Config { $script:LastConfigSaveFailed = $false }
        Mock Send-TelegramMessage {}
        Mock Edit-TelegramMessageText { $true }
        Mock Get-TemplateStore { @{ Order = @('urgent'); Map = @{ urgent = @{ Key = 'urgent' } } } }
        Show-TemplateMaxAirEditor -ChatId 100 -UserId 101
        $state = Get-PendingState -ChatId 100
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($state.Token):item:0" | Out-Null
        $script:tmaxToken = (Get-PendingState -ChatId 100).Token
    }
    AfterEach {
        $config.Settings | Add-Member TemplateMaxAirSeconds @{} -Force
        Clear-PendingState -ChatId 100
    }

    It 'asks for the amount instead of calling the button expired' {
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($script:tmaxToken):custom:ask" | Out-Null
        (Get-PendingState -ChatId 100).Mode | Should -Be 'template_max_air_custom'
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -eq (T 'kb.sendDuration') }
        Should -Invoke Send-TelegramMessage -Times 0 -ParameterFilter { $Text -eq (T 'kb.buttonsExpired') }
    }

    It 'saves minutes:seconds typed after the button' {
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($script:tmaxToken):custom:ask" | Out-Null
        Complete-TemplateMaxAirCustom -ChatId 100 -Value '2:30'
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 150
    }

    It 'reads a duration typed in Arabic-Indic digits' {
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($script:tmaxToken):custom:ask" | Out-Null
        Complete-TemplateMaxAirCustom -ChatId 100 -Value '٩٠'
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 90
    }

    It 'ignores text that arrives when this prompt is not the one waiting' {
        Complete-TemplateMaxAirCustom -ChatId 100 -Value '90'
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 0
    }

    It 'refuses a custom value from someone no longer an administrator' {
        Invoke-TemplateMaxAirPick -ChatId 100 -UserId 101 -Argument "$($script:tmaxToken):custom:ask" | Out-Null
        Mock Test-Admin { $false }
        Complete-TemplateMaxAirCustom -ChatId 100 -Value '90'
        Get-EffectiveAutoHideSeconds -Key urgent | Should -Be 0
    }
}
