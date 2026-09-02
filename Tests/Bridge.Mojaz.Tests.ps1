#requires -Version 7
<#
    Bridge.Mojaz.Tests.ps1 - the Mojaz bulletin: the table, and the playback
    that walks it.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'The Mojaz table' {
    BeforeEach {
        Mock Save-MojazPlaylist { $true }
        $script:MojazRows = @(); $script:MojazDelaySeconds = 4; $script:MojazPlayback = $null
    }

    It 'keeps rows in the order they were written' {
        Add-MojazRow -Image '.\Mojaz\bot\a.jpg' -Title 'أول' -Text 'خبر أول' | Out-Null
        Add-MojazRow -Image '' -Title 'ثانٍ' -Text 'خبر ثانٍ' | Out-Null

        $rows = @(Get-MojazRows)

        $rows.Count | Should -Be 2
        [string]$rows[0].Title | Should -Be 'أول'
        [string]$rows[1].Title | Should -Be 'ثانٍ'
    }

    It 'deletes by position, not by value' {
        # Two identical rows are legitimate - the same strap twice in a
        # bulletin - and a value match would take both.
        Add-MojazRow -Image '' -Title 'مكرر' -Text 'نص' | Out-Null
        Add-MojazRow -Image '' -Title 'مكرر' -Text 'نص' | Out-Null

        Remove-MojazRow -Index 0 | Out-Null

        @(Get-MojazRows).Count | Should -Be 1
    }

    It 'omits the picture variable for a row that has none' {
        # An empty path would blank the graphic; leaving the variable out keeps
        # the picture the scene already carries.
        $withPicture = Get-MojazRowVariables -Row @{ Image = '.\Mojaz\bot\a.jpg'; Title = 'ع'; Text = 'ن' }
        $without = Get-MojazRowVariables -Row @{ Image = ''; Title = 'ع'; Text = 'ن' }

        $withPicture.ContainsKey('mojaz_img') | Should -BeTrue
        $without.ContainsKey('mojaz_img') | Should -BeFalse
        $without['title.Text'] | Should -Be 'ع'
        $without['Subject.Text'] | Should -Be 'ن'
    }

    It 'refuses a dwell outside one second to ten minutes' {
        Set-MojazDelaySeconds -Seconds 0 | Should -BeFalse
        Set-MojazDelaySeconds -Seconds 601 | Should -BeFalse
        Set-MojazDelaySeconds -Seconds 7 | Should -BeTrue
        $script:MojazDelaySeconds | Should -Be 7
    }

    It 'says the table is empty rather than drawing an empty one' {
        Get-MojazText | Should -Match 'الجدول فارغ'
        @(Get-MojazBlocks | Where-Object { $_.type -eq 'table' }) | Should -BeNullOrEmpty
    }

    It 'draws one table row per story, with a picture mark' {
        Add-MojazRow -Image '.\Mojaz\bot\a.jpg' -Title 'أول' -Text 'خبر' | Out-Null
        Add-MojazRow -Image '' -Title 'ثانٍ' -Text 'خبر' | Out-Null

        $table = @(Get-MojazBlocks | Where-Object { $_.type -eq 'table' })[0]

        # Header plus a row each.
        @($table.cells).Count | Should -Be 3
        @($table.cells[1] | ForEach-Object { $_.text }) | Should -Contain '✅'
        @($table.cells[2] | ForEach-Object { $_.text }) | Should -Contain '—'
    }
}

Describe 'Playing the Mojaz bulletin' {
    BeforeEach {
        Mock Save-MojazPlaylist { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        $script:MojazRows = @(); $script:MojazDelaySeconds = 4; $script:MojazPlayback = $null
        Add-MojazRow -Image '.\Mojaz\bot\a.jpg' -Title 'أول' -Text 'خبر أول' | Out-Null
        Add-MojazRow -Image '' -Title 'ثانٍ' -Text 'خبر ثانٍ' | Out-Null
        Add-MojazRow -Image '' -Title 'ثالث' -Text 'خبر ثالث' | Out-Null
    }
    AfterAll { $script:MojazPlayback = $null; $script:MojazRows = @() }

    It 'shows the first row and gives it the entrance animation on top of its dwell' {
        $config.Settings | Add-Member -NotePropertyName 'MojazIntroExtraSeconds' -NotePropertyValue 2 -Force

        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeTrue

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $wait = ([datetime]$script:MojazPlayback.NextAt - (Get-Date)).TotalSeconds
        # 4 second dwell + 2 second entrance, give or take the test's own time.
        $wait | Should -BeGreaterThan 5
        $wait | Should -BeLessThan 6.5
    }

    It 'changes the following rows through the postbox, not with another show' {
        # Another SHOW would replay the entrance animation and flash the
        # screen between stories; the postbox writes into the running scene.
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        $script:MojazPlayback.NextAt = (Get-Date).AddSeconds(-1)

        Update-MojazPlayback

        Should -Invoke Send-PostboxValues -Times 1 -Exactly
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        [int]$script:MojazPlayback.Index | Should -Be 1
    }

    It 'leaves the last row up for half the dwell, then exits' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        foreach ($step in 1..2) {
            $script:MojazPlayback.NextAt = (Get-Date).AddSeconds(-1)
            Update-MojazPlayback
        }

        [int]$script:MojazPlayback.Index | Should -Be 2
        $wait = ([datetime]$script:MojazPlayback.NextAt - (Get-Date)).TotalSeconds
        $wait | Should -BeGreaterThan 1
        $wait | Should -BeLessThan 2.5

        $script:MojazPlayback.NextAt = (Get-Date).AddSeconds(-1)
        Update-MojazPlayback

        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
        $script:MojazPlayback | Should -BeNullOrEmpty
    }

    It 'stops the bulletin when a row fails rather than carrying on blind' {
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $false; Error = 'no route'; Xml = '' } }
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        $script:MojazPlayback.NextAt = (Get-Date).AddSeconds(-1)

        Update-MojazPlayback

        $script:MojazPlayback | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
    }

    It 'does not start a second run over a running one' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeFalse
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
    }

    It 'refuses to play an empty table' {
        $script:MojazRows = @(); $script:MojazDelaySeconds = 4; $script:MojazPlayback = $null
        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeFalse
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
}

Describe 'The Mojaz screen is reachable and complete' {
    It 'is offered in the menu only where the template exists' {
        Mock Test-MojazAvailable { $true }
        @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard | ForEach-Object { @($_) } |
                ForEach-Object { $_['callback_data'] }) | Should -Contain 'menu:mojaz'

        Mock Test-MojazAvailable { $false }
        @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard | ForEach-Object { @($_) } |
                ForEach-Object { $_['callback_data'] }) | Should -Not -Contain 'menu:mojaz'
    }

    It 'saves uploaded pictures beside the scene, not in the swept upload folder' {
        # The bridge deletes its own uploads on a timer, which would take a
        # picture that is still on air with it.
        Mock Get-MojazTemplate { @{ Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }

        $directory = Get-MojazUploadDirectory

        $directory | Should -Match 'Mojaz'
        $directory | Should -Match 'bot$'
    }
}
