#requires -Version 7
<#
    Bridge.Mojaz.Tests.ps1 - the bulletin library: the tables, what is saved,
    and the playback that walks one of them.

    The pure rules are covered in BridgeMojaz.Tests.ps1. What is tested here is
    the orchestration on top of them - screens, persistence, the schedule
    queue, and the walk on air.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

function global:New-TestMojazLibrary {
    <# A library with one bulletin, opened in chat 100. Every screen and every
       edit below starts from this. #>
    param([int]$DelaySeconds = 4, [object[]]$Rows = @())
    $created = Add-MojazBulletin -Library (New-MojazLibrary) -Name 'الصباحي' -UserId 1
    $script:MojazLibrary = $created.Value
    $bulletin = $script:MojazLibrary.Bulletins[0]
    $bulletin.DelaySeconds = $DelaySeconds
    $bulletin.Rows = @($Rows)
    $script:MojazSelections = @{ '100' = [string]$bulletin.Id }
    $script:MojazSchedules = @()
    $script:MojazPlayback = $null
    return $bulletin
}

function global:New-TestMojazRow {
    param([string]$Id = '', [string]$Title = 'ع', [string]$Text = 'ن', [string]$Image = '')
    if (-not $Id) { $Id = "r_$([guid]::NewGuid().ToString('N').Substring(0,8))" }
    return [pscustomobject]@{
        Id = $Id
        ImageMode = $(if ($Image) { 'new' } else { 'inherit' })
        Image = $Image; Title = $Title; Text = $Text
    }
}

function global:Step-TestMojazPlayback {
    <# Wait out the next moment without actually waiting: the run measures
       itself with a stopwatch, and ClockOffset is there so a test can move
       time instead of sleeping through it. #>
    $index = [int]$script:MojazPlayback.Index
    $rows = @($script:MojazPlayback.Rows)
    $moment = if ($index -ge ($rows.Count - 1)) {
        [double]$script:MojazPlayback.ExitAtSeconds
    }
    else { [double]$script:MojazPlayback.Plan[$index + 1].AtSeconds }
    $script:MojazPlayback.ClockOffset = $moment + 1
    Update-MojazPlayback
}

Describe 'The bulletin table' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Get-MojazSceneTiming { $null }
        $script:bulletin = New-TestMojazLibrary
    }

    It 'keeps rows in the order they were written' {
        $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $script:bulletin.Id -Image '.\Mojaz\bot\a.jpg' -Title 'أول' -Text 'خبر أول').Value
        $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $script:bulletin.Id -Title 'ثانٍ' -Text 'خبر ثانٍ').Value

        $rows = @((Get-MojazSelected -ChatId 100).Rows)

        $rows.Count | Should -Be 2
        [string]$rows[0].Title | Should -Be 'أول'
        [string]$rows[1].Title | Should -Be 'ثانٍ'
    }

    It 'deletes the row that was pressed, not its identical twin' {
        # Two identical rows are legitimate - the same strap twice in a
        # bulletin - and a value match would take both.
        $first = New-TestMojazRow -Title 'مكرر' -Text 'نص'
        $second = New-TestMojazRow -Title 'مكرر' -Text 'نص'
        $script:MojazLibrary.Bulletins[0].Rows = @($first, $second)

        Remove-MojazRow -RowId ([string]$first.Id) -ChatId 100 -UserId 101

        $rows = @((Get-MojazSelected -ChatId 100).Rows)
        $rows.Count | Should -Be 1
        [string]$rows[0].Id | Should -Be ([string]$second.Id)
    }

    It 'moves a row up the rundown from its button' {
        $first = New-TestMojazRow -Title 'أ'
        $second = New-TestMojazRow -Title 'ب'
        $script:MojazLibrary.Bulletins[0].Rows = @($first, $second)

        Move-MojazRow -RowId ([string]$second.Id) -Direction up -ChatId 100 -UserId 101

        [string]@((Get-MojazSelected -ChatId 100).Rows)[0].Title | Should -Be 'ب'
    }

    It 'omits the picture variable for a row that has none' {
        # An empty path would blank the graphic; leaving the variable out keeps
        # the picture the scene already carries.
        $withPicture = Get-MojazRowVariables -Row (New-TestMojazRow -Image '.\Mojaz\bot\a.jpg')
        $without = Get-MojazRowVariables -Row (New-TestMojazRow)

        $withPicture.ContainsKey('mojaz_img') | Should -BeTrue
        $without.ContainsKey('mojaz_img') | Should -BeFalse
        $without['title.Text'] | Should -Be 'ع'
        $without['Subject.Text'] | Should -Be 'ن'
    }

    It 'refuses a dwell outside one second to ten minutes' {
        foreach ($value in @('0', '601')) {
            Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_delay'; UserId = 101; BulletinId = [string]$script:bulletin.Id }
            Complete-MojazTiming -Which delay -ChatId 100 -Value $value
            # Refused: the prompt is still open and the number has not moved.
            Get-PendingState -ChatId 100 | Should -Not -BeNullOrEmpty
        }

        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_delay'; UserId = 101; BulletinId = [string]$script:bulletin.Id }
        Complete-MojazTiming -Which delay -ChatId 100 -Value '7'

        [int](Get-MojazSelected -ChatId 100).DelaySeconds | Should -Be 7
    }

    It 'says the table is empty rather than drawing an empty one' {
        Get-MojazText -Bulletin $script:bulletin | Should -Match 'الجدول فارغ'
        @(Get-MojazBlocks -Bulletin $script:bulletin | Where-Object { $_.type -eq 'table' }) | Should -BeNullOrEmpty
    }

    It 'draws one table row per story, with a picture mark' {
        $script:MojazLibrary.Bulletins[0].Rows = @(
            (New-TestMojazRow -Title 'أول' -Image '.\Mojaz\bot\a.jpg')
            (New-TestMojazRow -Title 'ثانٍ')
        )
        $table = @(Get-MojazBlocks -Bulletin (Get-MojazSelected -ChatId 100) | Where-Object { $_.type -eq 'table' })[0]

        # Header plus a row each, and the picture column says which of the
        # three modes each row is in.
        @($table.cells).Count | Should -Be 3
        @($table.cells[1] | ForEach-Object { $_.text }) | Should -Contain '🖼'
        @($table.cells[2] | ForEach-Object { $_.text }) | Should -Contain '↑'
    }

    It 'calls the first row the template picture, not an inheritance' {
        # There is nothing above the first row to inherit from, so saying it
        # follows the previous one would be a lie.
        $script:MojazLibrary.Bulletins[0].Rows = @((New-TestMojazRow -Title 'أول'))
        $table = @(Get-MojazBlocks -Bulletin (Get-MojazSelected -ChatId 100) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[1] | ForEach-Object { $_.text }) | Should -Contain '▫️'
        Get-MojazText -Bulletin (Get-MojazSelected -ChatId 100) | Should -Match 'صورة القالب'
    }

    It 'writes an added row into the library, so a restart reads it back' {
        # The bug this exists for: the editor used to write rows to a separate
        # file the library never read, and every row added after the migration
        # disappeared at the next start.
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_row_text'; UserId = 101; BulletinId = [string]$script:bulletin.Id; Image = ''; Title = 'عنوان' }

        Complete-MojazRowText -ChatId 100 -Value 'نص الخبر'

        $saved = @((Get-MojazSelected -ChatId 100).Rows)
        $saved.Count | Should -Be 1
        [string]$saved[0].Title | Should -Be 'عنوان'
        Should -Invoke Write-BridgeValidatedJson -Times 1 -Exactly
    }

    It 'puts a row in the bulletin its flow started in, not the one opened since' {
        $script:MojazLibrary = (Add-MojazBulletin -Library $script:MojazLibrary -Name 'المسائي' -UserId 1).Value
        $otherId = [string]$script:MojazLibrary.Bulletins[1].Id
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_row_text'; UserId = 101; BulletinId = [string]$script:bulletin.Id; Image = ''; Title = 'عنوان' }
        # The operator opened another bulletin while typing the story.
        $script:MojazSelections['100'] = $otherId

        Complete-MojazRowText -ChatId 100 -Value 'نص'

        @($script:MojazLibrary.Bulletins[0].Rows).Count | Should -Be 1
        @($script:MojazLibrary.Bulletins[1].Rows).Count | Should -Be 0
    }

    It 'keeps the table when the save fails, and says so' {
        $script:MojazLibrary.Bulletins[0].Rows = @((New-TestMojazRow -Title 'موجود'))
        Mock Write-BridgeValidatedJson { $false }
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_row_text'; UserId = 101; BulletinId = [string]$script:bulletin.Id; Image = ''; Title = 'جديد' }

        Complete-MojazRowText -ChatId 100 -Value 'نص'

        @((Get-MojazSelected -ChatId 100).Rows).Count | Should -Be 1
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'تعذّر الحفظ' }
    }
}

Describe 'Playing a bulletin' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazSceneTiming { $null }
        New-TestMojazLibrary -DelaySeconds 4 -Rows @(
            (New-TestMojazRow -Title 'أول' -Image '.\Mojaz\bot\a.jpg')
            (New-TestMojazRow -Title 'ثانٍ')
            (New-TestMojazRow -Title 'ثالث')
        ) | Out-Null
    }
    AfterAll { $script:MojazPlayback = $null }

    It 'shows the first row and gives it the entrance animation on top of its dwell' {
        $config.Settings | Add-Member -NotePropertyName 'MojazIntroExtraSeconds' -NotePropertyValue 2 -Force

        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeTrue

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        # 4 second dwell + 2 second entrance, as an absolute moment measured
        # from the start of the run rather than a delay from the last send.
        [double]$script:MojazPlayback.Plan[1].AtSeconds | Should -Be 6
    }

    It 'changes the following rows through the postbox, not with another show' {
        # Another SHOW would replay the entrance animation and flash the
        # screen between stories; the postbox writes into the running scene.
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        Step-TestMojazPlayback

        Should -Invoke Send-PostboxValues -Times 1 -Exactly
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        [int]$script:MojazPlayback.Index | Should -Be 1
    }

    It 'leaves the last row up for half the dwell, then exits' {
        # With no scene to read, half the dwell is the documented fallback.
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        foreach ($step in 1..2) {
            Step-TestMojazPlayback
        }

        [int]$script:MojazPlayback.Index | Should -Be 2
        # Half the 4 second dwell between the last row and the exit.
        ([double]$script:MojazPlayback.ExitAtSeconds - [double]$script:MojazPlayback.Plan[2].AtSeconds) | Should -Be 2

        Step-TestMojazPlayback

        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
        $script:MojazPlayback | Should -BeNullOrEmpty
    }

    It 'stops the bulletin when a row fails rather than carrying on blind' {
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $false; Error = 'no route'; Xml = '' } }
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        Step-TestMojazPlayback

        $script:MojazPlayback | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
    }

    It 'does not start a second run over a running one' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeFalse
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
    }

    It 'refuses to play an empty table' {
        New-TestMojazLibrary | Out-Null
        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeFalse
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'refuses to play when no bulletin is open' {
        $script:MojazSelections = @{}
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

    It 'offers a way back to the library and the usual editing buttons' {
        Mock Get-MojazSceneTiming { $null }
        Mock Write-BridgeValidatedJson { $true }
        $bulletin = New-TestMojazLibrary -Rows @((New-TestMojazRow))
        $callbacks = @((Get-MojazKeyboard -Bulletin $bulletin).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })

        foreach ($expected in @('mojaz:back', 'mojaz:add', 'mojaz:rename', 'mojaz:copy', 'mojaz:drop', 'mojaz:times', 'mojaz:play')) {
            $callbacks | Should -Contain $expected
        }
    }
}

Describe 'Telling a photo message from every other message' {
    It 'answers with nothing for a message that carries no photo' {
        # The bug this exists for: @(Get-JsonProp $message 'photo') on a text
        # message is @($null) - Count 1 - so "did a photo arrive" answered yes
        # to every message, and the bot replied to /start and /menu with
        # "لا يُنتظر منك صورة الآن" instead of opening the menu.
        Get-TelegramMessagePhotoId -Message ([pscustomobject]@{ text = '/start' }) | Should -BeNullOrEmpty
        Get-TelegramMessagePhotoId -Message ([pscustomobject]@{ photo = @() }) | Should -BeNullOrEmpty
        Get-TelegramMessagePhotoId -Message ([pscustomobject]@{ document = [pscustomobject]@{ file_id = 'd' } }) | Should -BeNullOrEmpty
    }

    It 'takes the largest size Telegram offers' {
        $message = [pscustomobject]@{ photo = @(
                [pscustomobject]@{ file_id = 'thumb' }
                [pscustomobject]@{ file_id = 'full' }
            ) }

        Get-TelegramMessagePhotoId -Message $message | Should -Be 'full'
    }
}

Describe 'Adjusting the bulletin timings' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        $script:bulletin = New-TestMojazLibrary -DelaySeconds 8
    }

    It 'falls back to the setting and to half the dwell until told otherwise' {
        # The scene is the first source; these are what is used without one.
        Mock Get-MojazSceneTiming { $null }
        $config.Settings | Add-Member -NotePropertyName 'MojazIntroExtraSeconds' -NotePropertyValue 2 -Force

        Get-MojazIntroSeconds -Bulletin $script:bulletin | Should -Be 2
        Get-MojazLastRowSeconds -Bulletin $script:bulletin | Should -Be 4
    }

    It 'takes the bulletin its own numbers, and zero puts the default back' {
        Mock Get-MojazSceneTiming { $null }
        foreach ($pair in @(@('intro', '5'), @('last', '12'))) {
            Set-PendingState -ChatId 100 -State @{ Mode = "mojaz_$($pair[0])_seconds"; UserId = 101; BulletinId = [string]$script:bulletin.Id }
            Complete-MojazTiming -Which $pair[0] -ChatId 100 -Value $pair[1]
        }
        Get-MojazIntroSeconds -Bulletin (Get-MojazSelected -ChatId 100) | Should -Be 5
        Get-MojazLastRowSeconds -Bulletin (Get-MojazSelected -ChatId 100) | Should -Be 12

        foreach ($which in @('intro', 'last')) {
            Set-PendingState -ChatId 100 -State @{ Mode = "mojaz_$($which)_seconds"; UserId = 101; BulletinId = [string]$script:bulletin.Id }
            Complete-MojazTiming -Which $which -ChatId 100 -Value '0'
        }
        Get-MojazLastRowSeconds -Bulletin (Get-MojazSelected -ChatId 100) | Should -Be 4
    }

    It 'refuses a timing outside its range and keeps the prompt open' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_last_seconds'; UserId = 101; BulletinId = [string]$script:bulletin.Id }
        Complete-MojazTiming -Which last -ChatId 100 -Value '601'

        [int](Get-MojazSelected -ChatId 100).LastRowSeconds | Should -Be 0
        Get-PendingState -ChatId 100 | Should -Not -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match '❌' }
    }

    It 'holds the last row for the number it was given' {
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazSceneTiming { $null }
        $script:MojazLibrary.Bulletins[0].Rows = @((New-TestMojazRow -Title 'أ'), (New-TestMojazRow -Title 'ب'))
        $script:MojazLibrary.Bulletins[0].LastRowSeconds = 15

        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        Step-TestMojazPlayback

        ([double]$script:MojazPlayback.ExitAtSeconds - [double]$script:MojazPlayback.Plan[1].AtSeconds) | Should -Be 15
    }
}

Describe 'Timing read from the scene itself' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        $script:bulletin = New-TestMojazLibrary -DelaySeconds 20
        $script:MojazSceneTiming = $null; $script:MojazSceneTimingKey = ''
    }
    AfterAll { $script:MojazSceneTiming = $null; $script:MojazSceneTimingKey = '' }

    It 'turns the loop markers into the entrance, the loop and the exit' {
        # The three durations a bulletin needs are already written in the
        # scene: 0 -> LoopStart is the entrance, LoopStart -> LoopEnd repeats,
        # LoopEnd -> Duration is the exit.
        $scene = Join-Path $TestDrive 'timing.cintitle'
        '<CinegyTitler Version="2.4"><Scene Fps="25.000" Duration="1698" LoopStartFrame="30" LoopEndFrame="1530" /></CinegyTitler>' |
            Set-Content -LiteralPath $scene -Encoding utf8

        $timing = Get-MojazSceneTiming -Path $scene

        $timing.IntroSeconds | Should -Be 1.2
        $timing.LoopSeconds | Should -Be 60
        $timing.OutroSeconds | Should -Be 6.72
    }

    It 'rounds each up into whole seconds, so nothing is clipped' {
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 60; OutroSeconds = 6.72 } }

        Get-MojazIntroSeconds -Bulletin $script:bulletin | Should -Be 2
        Get-MojazLastRowSeconds -Bulletin $script:bulletin | Should -Be 7
    }

    It 'still lets the bulletin override what the scene says' {
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 60; OutroSeconds = 6.72 } }
        $script:bulletin.IntroExtraSeconds = 5
        $script:bulletin.LastRowSeconds = 15

        Get-MojazIntroSeconds -Bulletin $script:bulletin | Should -Be 5
        Get-MojazLastRowSeconds -Bulletin $script:bulletin | Should -Be 15
    }

    It 'falls back to the setting and half the dwell when the scene cannot be read' {
        $config.Settings | Add-Member -NotePropertyName 'MojazIntroExtraSeconds' -NotePropertyValue 2 -Force
        Mock Get-MojazSceneTiming { $null }

        Get-MojazIntroSeconds -Bulletin $script:bulletin | Should -Be 2
        Get-MojazLastRowSeconds -Bulletin $script:bulletin | Should -Be 10
    }

    It 'refuses a scene whose markers make no sense' {
        $scene = Join-Path $TestDrive 'broken.cintitle'
        '<CinegyTitler><Scene Fps="0" Duration="10" LoopStartFrame="9" LoopEndFrame="2" /></CinegyTitler>' |
            Set-Content -LiteralPath $scene -Encoding utf8

        Get-MojazSceneTiming -Path $scene | Should -BeNullOrEmpty
    }
}

Describe 'Persisting and migrating the Mojaz library' {
    BeforeEach {
        $script:MojazLibrary = New-MojazLibrary
        $script:MojazSchedules = @()
        Mock Write-BridgeLog {}
    }

    It 'keeps the previous in-memory library when an atomic save fails' {
        $original = Add-MojazBulletin -Library (New-MojazLibrary) -Name 'قديم' -UserId 1
        $script:MojazLibrary = $original.Value
        Mock Write-BridgeValidatedJson { $false }
        $candidate = Add-MojazBulletin -Library $script:MojazLibrary -Name 'جديد' -UserId 2

        Save-MojazLibrary -Library $candidate.Value | Should -BeFalse

        $script:MojazLibrary.Bulletins.Count | Should -Be 1
        $script:MojazLibrary.Bulletins[0].Name | Should -Be 'قديم'
    }

    It 'publishes the candidate in memory only after the validated write succeeds' {
        Mock Write-BridgeValidatedJson { $true }
        $candidate = Add-MojazBulletin -Library (New-MojazLibrary) -Name 'صباحي' -UserId 1

        Save-MojazLibrary -Library $candidate.Value | Should -BeTrue

        $script:MojazLibrary.Bulletins.Count | Should -Be 1
        $script:MojazLibrary.Bulletins[0].Name | Should -Be 'صباحي'
    }

    It 'migrates the old singleton and preserves timings rows and inherited images' {
        $legacy = Join-Path $TestDrive 'mojaz.json'
        @{
            DelaySeconds = 12; IntroExtraSeconds = 3; LastRowSeconds = 5
            Rows = @(
                @{ Image = ''; Title = 'أ'; Text = 'الأول' }
                @{ Image = '.\Mojaz\bot\b.jpg'; Title = 'ب'; Text = 'الثاني' }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $legacy -Encoding utf8
        Mock Get-MojazStateFile { $legacy }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'mojaz-bulletins.json' }
        Mock Write-BridgeValidatedJson { $true }

        Import-MojazLibrary

        $script:MojazLibrary.Bulletins.Count | Should -Be 1
        $bulletin = $script:MojazLibrary.Bulletins[0]
        $bulletin.Name | Should -Be 'الموجز الحالي'
        $bulletin.DelaySeconds | Should -Be 12
        $bulletin.IntroExtraSeconds | Should -Be 3
        $bulletin.LastRowSeconds | Should -Be 5
        $bulletin.Rows[0].ImageMode | Should -Be 'inherit'
        $bulletin.Rows[1].ImageMode | Should -Be 'new'
        Test-Path -LiteralPath $legacy | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'mojaz.migrated-*.json').Count | Should -Be 1
    }

    It 'leaves the legacy file and empty library when migration cannot be saved' {
        $legacy = Join-Path $TestDrive 'mojaz.json'
        @{ DelaySeconds = 8; Rows = @(@{ Image = ''; Title = 'أ'; Text = 'خبر' }) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $legacy -Encoding utf8
        Mock Get-MojazStateFile { $legacy }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'mojaz-bulletins.json' }
        Mock Write-BridgeValidatedJson { $false }

        Import-MojazLibrary

        Test-Path -LiteralPath $legacy | Should -BeTrue
        $script:MojazLibrary.Bulletins.Count | Should -Be 0
    }

    It 'does not leave an appointment running across a restart' {
        # Nothing is on air after a restart, and a schedule stuck at 'running'
        # would hold the queue closed forever.
        $path = Join-Path $TestDrive 'mojaz-schedules.json'
        '{}' | Set-Content -LiteralPath $path -Encoding utf8
        Mock Get-MojazSchedulesFile { $path }
        Mock Read-BridgeValidatedJson {
            [pscustomobject]@{ Data = [pscustomobject]@{ Schedules = @(
                        [pscustomobject]@{ Id = 'ms_1'; BulletinId = 'b_1'; Status = 'running'; ScheduledAt = '2026-09-02T08:00:00+03:00'; LastError = '' }
                    ) } }
        }
        Mock Write-BridgeValidatedJson { $true }

        Import-MojazSchedules

        $script:MojazSchedules[0].Status | Should -Be 'failed'
        $script:MojazSchedules[0].LastError | Should -Be 'bridge_restarted'
    }
}

Describe 'The named Mojaz library screen' {
    BeforeEach {
        $script:MojazLibrary = New-MojazLibrary
        $script:MojazSchedules = @()
        $script:MojazSelections = @{}
        $script:MojazPlayback = $null
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Write-BridgeValidatedJson { $true }
    }

    It 'shows an empty-library action instead of the old singleton table' {
        $text = Get-MojazLibraryText
        $callbacks = @((Get-MojazLibraryKeyboard).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_.callback_data })

        $text | Should -Match 'لا توجد موجزات محفوظة'
        $callbacks | Should -Contain 'mojaz:new'
    }

    It 'lists each saved bulletin with rows and upcoming schedule count' {
        $morning = Add-MojazBulletin -Library $script:MojazLibrary -Name 'الصباحي' -UserId 1
        $script:MojazLibrary = $morning.Value
        $script:MojazLibrary.Bulletins[0].Rows = @((New-TestMojazRow -Id 'r_1' -Title 'أ' -Text 'خبر'))
        $id = $script:MojazLibrary.Bulletins[0].Id
        $script:MojazSchedules = @(
            [pscustomobject]@{ Id = 'ms_1'; BulletinId = $id; Status = 'scheduled'; ScheduledAt = '2026-09-03T08:00:00+03:00' }
            [pscustomobject]@{ Id = 'ms_2'; BulletinId = $id; Status = 'cancelled'; ScheduledAt = '2026-09-03T09:00:00+03:00' }
        )

        $text = Get-MojazLibraryText
        $callbacks = @((Get-MojazLibraryKeyboard).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_.callback_data })

        $text | Should -Match 'الصباحي'
        $text | Should -Match '1 صف'
        $text | Should -Match '1 موعدًا قادمًا'
        $callbacks | Should -Contain "mojaz:open:$id"
    }

    It 'does not announce a created bulletin when persistence fails' {
        Mock Write-BridgeValidatedJson { $false }
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_name_new'; UserId = 101; BulletinId = '' }

        Complete-MojazName -Which new -ChatId 100 -Value 'الصباحي'

        $script:MojazLibrary.Bulletins.Count | Should -Be 0
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'تعذّر الحفظ' }
    }

    It 'refuses a second bulletin with the same name' {
        $script:MojazLibrary = (Add-MojazBulletin -Library $script:MojazLibrary -Name 'الصباحي' -UserId 1).Value
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_name_new'; UserId = 101; BulletinId = '' }

        Complete-MojazName -Which new -ChatId 100 -Value '  الصباحي  '

        $script:MojazLibrary.Bulletins.Count | Should -Be 1
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'يوجد موجز بهذا الاسم' }
    }

    It 'copies a bulletin without sharing its rows' {
        $script:MojazLibrary = (Add-MojazBulletin -Library $script:MojazLibrary -Name 'الصباحي' -UserId 1).Value
        $id = [string]$script:MojazLibrary.Bulletins[0].Id
        $script:MojazLibrary.Bulletins[0].Rows = @((New-TestMojazRow -Title 'أ'))
        $script:MojazSelections['100'] = $id
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_name_copy'; UserId = 101; BulletinId = $id }

        Complete-MojazName -Which copy -ChatId 100 -Value 'المسائي'

        $script:MojazLibrary.Bulletins.Count | Should -Be 2
        @($script:MojazLibrary.Bulletins[1].Rows).Count | Should -Be 1
        # The copy is what the chat now has open.
        Get-MojazSelectedId -ChatId 100 | Should -Be ([string]$script:MojazLibrary.Bulletins[1].Id)
    }
}

Describe 'Deleting a bulletin' {
    BeforeEach {
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Write-BridgeValidatedJson { $true }
        Mock Invoke-ExitLayer { $true }
        Mock Get-MojazSceneTiming { $null }
        $script:bulletin = New-TestMojazLibrary -Rows @((New-TestMojazRow -Title 'أ'))
    }
    AfterAll { $script:MojazPlayback = $null; $script:MojazSchedules = @() }

    It 'takes the bulletin and its appointments together' {
        $id = [string]$script:bulletin.Id
        $script:MojazSchedules = @(
            [pscustomobject]@{ Id = 'ms_1'; BulletinId = $id; Status = 'scheduled'; ScheduledAt = '2026-09-03T08:00:00+03:00' }
            [pscustomobject]@{ Id = 'ms_2'; BulletinId = 'b_other'; Status = 'scheduled'; ScheduledAt = '2026-09-03T09:00:00+03:00' }
        )

        Remove-MojazBulletinAndSchedules -ChatId 100 -UserId 101 | Should -BeTrue

        $script:MojazLibrary.Bulletins.Count | Should -Be 0
        @($script:MojazSchedules).Count | Should -Be 1
        [string]$script:MojazSchedules[0].Id | Should -Be 'ms_2'
        Get-MojazSelectedId -ChatId 100 | Should -BeNullOrEmpty
    }

    It 'refuses while that bulletin is on air' {
        $script:MojazPlayback = @{ BulletinId = [string]$script:bulletin.Id; BulletinName = 'الصباحي'; Rows = @(1); Index = 0 }

        Remove-MojazBulletinAndSchedules -ChatId 100 -UserId 101 | Should -BeFalse

        $script:MojazLibrary.Bulletins.Count | Should -Be 1
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'على الهواء' }
    }

    It 'puts the appointments back when the library write fails' {
        # Both files move together or neither does: an appointment pointing at
        # a bulletin that no longer exists would fire into nothing.
        $id = [string]$script:bulletin.Id
        $script:MojazSchedules = @([pscustomobject]@{ Id = 'ms_1'; BulletinId = $id; Status = 'scheduled'; ScheduledAt = '2026-09-03T08:00:00+03:00' })
        # The schedules write succeeds, the library write behind it fails, and
        # the write that puts the schedules back succeeds.
        Mock Write-BridgeValidatedJson -ParameterFilter { $Path -match 'bulletins' } -MockWith { $false }
        Mock Write-BridgeValidatedJson -ParameterFilter { $Path -match 'schedules' } -MockWith { $true }

        Remove-MojazBulletinAndSchedules -ChatId 100 -UserId 101 | Should -BeFalse

        $script:MojazLibrary.Bulletins.Count | Should -Be 1
        @($script:MojazSchedules).Count | Should -Be 1
    }
}

Describe 'Named bulletin playback isolation' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazSceneTiming { $null }
        New-TestMojazLibrary -DelaySeconds 4 -Rows @(
            (New-TestMojazRow -Id 'r_1' -Title 'أ' -Text 'الأول')
            (New-TestMojazRow -Id 'r_2' -Title 'ب' -Text 'الثاني')
            (New-TestMojazRow -Id 'r_3' -Title 'ج' -Text 'الثالث')
        ) | Out-Null
    }
    AfterAll { $script:MojazPlayback = $null }

    It 'shows the entrance once and updates every later row only through postbox' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeTrue
        foreach ($step in 1..2) {
            Step-TestMojazPlayback
        }

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        Should -Invoke Send-PostboxValues -Times 2 -Exactly
    }

    It 'finishes from its snapshot even when the saved bulletin is edited or cleared' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        $script:MojazLibrary.Bulletins[0].Rows = @()

        foreach ($step in 1..2) {
            Step-TestMojazPlayback
        }

        [int]$script:MojazPlayback.Index | Should -Be 2
        $script:MojazPlayback.Rows.Count | Should -Be 3
        Should -Invoke Send-PostboxValues -Times 2 -Exactly
    }
}

Describe 'Reusable Mojaz schedules and overlap prevention' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Get-MojazSceneTiming { $null }
        $script:bulletin = New-TestMojazLibrary -DelaySeconds 8 -Rows @((New-TestMojazRow -Id 'r_1' -Title 'أ' -Text 'خبر'))
        $script:MojazSelections = @{}
    }
    AfterAll { $script:MojazPlayback = $null; $script:MojazSchedules = @() }

    It 'allows several appointments to reference the same saved bulletin' {
        $id = [string]$script:bulletin.Id

        Add-MojazSchedule -BulletinId $id -ScheduledAt ([datetimeoffset]'2026-09-03T08:00:00+03:00') -ChatId 100 -UserId 101 | Should -BeTrue
        Add-MojazSchedule -BulletinId $id -ScheduledAt ([datetimeoffset]'2026-09-03T18:00:00+03:00') -ChatId 100 -UserId 101 | Should -BeTrue

        $script:MojazSchedules.Count | Should -Be 2
        @($script:MojazSchedules.BulletinId | Select-Object -Unique).Count | Should -Be 1
    }

    It 'books the appointment instead of holding it in memory' {
        # A promise kept only in memory is lost on restart; an appointment on
        # disk is not.
        $script:MojazSelections['100'] = [string]$script:bulletin.Id
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_start_at'; UserId = 101; BulletinId = [string]$script:bulletin.Id }

        Complete-MojazLater -ChatId 100 -Value '+30'

        @($script:MojazSchedules).Count | Should -Be 1
        [string]$script:MojazSchedules[0].Status | Should -Be 'scheduled'
        # Nothing on air yet: it is a promise, not a show.
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        Get-MojazBulletinScheduleText -BulletinId ([string]$script:bulletin.Id) | Should -Match 'يبدأ'
    }

    It 'refuses a time it cannot read, and books nothing' {
        $script:MojazSelections['100'] = [string]$script:bulletin.Id
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_start_at'; UserId = 101; BulletinId = [string]$script:bulletin.Id }

        Complete-MojazLater -ChatId 100 -Value 'قريبًا'

        @($script:MojazSchedules).Count | Should -Be 0
        Get-PendingState -ChatId 100 | Should -Not -BeNullOrEmpty
    }

    It 'can be called off before it fires' {
        $id = [string]$script:bulletin.Id
        Add-MojazSchedule -BulletinId $id -ScheduledAt ([datetimeoffset]::Now.AddMinutes(30)) -ChatId 100 -UserId 101 | Out-Null

        Stop-MojazSchedule -ScheduleId ([string]$script:MojazSchedules[0].Id) -ChatId 100 -UserId 101

        @($script:MojazSchedules).Count | Should -Be 0
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'waits until the moment, then plays' {
        $id = [string]$script:bulletin.Id
        $script:MojazSchedules = @([pscustomobject]@{
                Id = 'ms_due'; BulletinId = $id; ScheduledAt = '2026-09-02T08:00:00+03:00'; CreatedAt = '2026-09-01T08:00:00+03:00'
                CreatedBy = 101; ChatId = 100; Status = 'scheduled'; DueAt = $null; StartedAt = $null; CompletedAt = $null; DelayReason = ''; LastError = ''
            })

        Update-MojazScheduleQueue -Now ([datetimeoffset]'2026-09-02T07:00:00+03:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly

        Update-MojazScheduleQueue -Now ([datetimeoffset]'2026-09-02T08:00:01+03:00')

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        [string]$script:MojazSchedules[0].Status | Should -Be 'running'
        $script:MojazPlayback | Should -Not -BeNullOrEmpty
    }

    It 'queues a due appointment while another bulletin is running and sends one delay notice' {
        $id = [string]$script:bulletin.Id
        $script:MojazSchedules = @([pscustomobject]@{
                Id = 'ms_due'; BulletinId = $id; ScheduledAt = '2026-09-02T08:00:00+03:00'; CreatedAt = '2026-09-01T08:00:00+03:00'
                CreatedBy = 101; ChatId = 100; Status = 'scheduled'; DueAt = $null; StartedAt = $null; CompletedAt = $null; DelayReason = ''; LastError = ''
            })
        $script:MojazPlayback = @{ BulletinId = 'b_other'; BulletinName = 'الجارى'; Rows = @(1); Index = 0 }

        Update-MojazScheduleQueue -Now ([datetimeoffset]'2026-09-02T09:00:00+03:00')
        Update-MojazScheduleQueue -Now ([datetimeoffset]'2026-09-02T09:01:00+03:00')

        $script:MojazSchedules[0].Status | Should -Be 'queued'
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'ما زال على الهواء' }
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'starts the oldest queued appointment after the active run has ended using the latest rows' {
        $id = [string]$script:bulletin.Id
        $script:MojazSchedules = @([pscustomobject]@{
                Id = 'ms_due'; BulletinId = $id; ScheduledAt = '2026-09-02T08:00:00+03:00'; CreatedAt = '2026-09-01T08:00:00+03:00'
                CreatedBy = 101; ChatId = 100; Status = 'queued'; DueAt = '2026-09-02T08:00:00+03:00'; StartedAt = $null; CompletedAt = $null; DelayReason = 'active_bulletin'; LastError = ''
            })
        $script:MojazLibrary.Bulletins[0].Rows[0].Title = 'آخر تحديث'

        Update-MojazScheduleQueue -Now ([datetimeoffset]'2026-09-02T09:00:00+03:00')

        $script:MojazSchedules[0].Status | Should -Be 'running'
        $script:MojazPlayback.Rows[0].Title | Should -Be 'آخر تحديث'
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
    }
}

Describe 'Cleaning up orphaned bulletin pictures' {
    BeforeEach {
        Mock Write-BridgeLog {}
        Mock Write-BridgeValidatedJson { $true }
        # A folder of its own per test: TestDrive lives for the whole file, and
        # one test's leftovers would be the next one's orphans.
        $script:pictures = Join-Path $TestDrive "pictures-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        New-Item -ItemType Directory -Path $script:pictures -Force | Out-Null
        Mock Get-MojazUploadDirectory { $script:pictures }
        $script:MojazPlayback = $null
    }
    AfterAll { $script:MojazPlayback = $null }

    It 'removes only the bridge-named files that no row and no run still wants' {
        $used = Join-Path $script:pictures 'mojaz-20260901-120000-aaaaaaaa.jpg'
        $onAir = Join-Path $script:pictures 'mojaz-20260901-120000-bbbbbbbb.jpg'
        $orphan = Join-Path $script:pictures 'mojaz-20260901-120000-cccccccc.jpg'
        $foreign = Join-Path $script:pictures 'newsroom-logo.png'
        foreach ($file in @($used, $onAir, $orphan, $foreign)) {
            'x' | Set-Content -LiteralPath $file -Encoding utf8
            (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddDays(-3)
        }
        New-TestMojazLibrary -Rows @((New-TestMojazRow -Image ".\Mojaz\bot\$(Split-Path $used -Leaf)")) | Out-Null
        $script:MojazPlayback = @{ BulletinId = 'b_x'; Rows = @((New-TestMojazRow -Image ".\Mojaz\bot\$(Split-Path $onAir -Leaf)")) }

        Update-MojazImageCleanup | Should -Be 1

        Test-Path -LiteralPath $used | Should -BeTrue
        Test-Path -LiteralPath $onAir | Should -BeTrue
        Test-Path -LiteralPath $foreign | Should -BeTrue
        Test-Path -LiteralPath $orphan | Should -BeFalse
    }

    It 'leaves a picture uploaded for a row still being written' {
        $fresh = Join-Path $script:pictures 'mojaz-20260902-120000-dddddddd.jpg'
        'x' | Set-Content -LiteralPath $fresh -Encoding utf8
        New-TestMojazLibrary | Out-Null

        Update-MojazImageCleanup | Should -Be 0

        Test-Path -LiteralPath $fresh | Should -BeTrue
    }
}

Describe 'Editing a row that already exists' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Get-MojazSceneTiming { $null }
        Mock Get-MojazTemplateImage { '.\Mojaz\Pic01.png' }
        $script:bulletin = New-TestMojazLibrary -Rows @(
            (New-TestMojazRow -Id 'r_1' -Title 'الأول' -Text 'خبر أول' -Image '.\Mojaz\bot\a.jpg')
            (New-TestMojazRow -Id 'r_2' -Title 'الثاني' -Text 'خبر ثانٍ')
        )
    }

    It 'changes the story without disturbing the title or the picture' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_edit_text'; UserId = 101; BulletinId = [string]$script:bulletin.Id; RowId = 'r_1' }

        Complete-MojazRowEdit -Which text -ChatId 100 -Value 'خبر معدَّل'

        $row = @((Get-MojazSelected -ChatId 100).Rows)[0]
        [string]$row.Text | Should -Be 'خبر معدَّل'
        [string]$row.Title | Should -Be 'الأول'
        [string]$row.Image | Should -Be '.\Mojaz\bot\a.jpg'
    }

    It 'refuses an empty title and leaves the row as it was' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_edit_title'; UserId = 101; BulletinId = [string]$script:bulletin.Id; RowId = 'r_1' }

        Complete-MojazRowEdit -Which title -ChatId 100 -Value '   '

        [string]@((Get-MojazSelected -ChatId 100).Rows)[0].Title | Should -Be 'الأول'
        Get-PendingState -ChatId 100 | Should -Not -BeNullOrEmpty
    }

    It 'puts a row back on the template picture' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_edit_image'; UserId = 101; BulletinId = [string]$script:bulletin.Id; RowId = 'r_1' }

        Complete-MojazRowImage -ChatId 100 -Mode template

        $row = @((Get-MojazSelected -ChatId 100).Rows)[0]
        [string]$row.ImageMode | Should -Be 'template'
        [string]$row.Image | Should -BeNullOrEmpty
        (Get-MojazRowVariables -Row $row -TemplateImage '.\Mojaz\Pic01.png')['mojaz_img'] | Should -Be '.\Mojaz\Pic01.png'
    }

    It 'makes a row follow the one above it, sending no picture at all' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_edit_image'; UserId = 101; BulletinId = [string]$script:bulletin.Id; RowId = 'r_1' }

        Complete-MojazRowImage -ChatId 100 -Mode inherit

        $row = @((Get-MojazSelected -ChatId 100).Rows)[0]
        [string]$row.ImageMode | Should -Be 'inherit'
        (Get-MojazRowVariables -Row $row -TemplateImage '.\Mojaz\Pic01.png').ContainsKey('mojaz_img') | Should -BeFalse
    }

    It 'reuses a picture the bulletin already carries instead of a second upload' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_edit_image'; UserId = 101; BulletinId = [string]$script:bulletin.Id; RowId = 'r_2' }

        $reused = Resolve-MojazUsedImage -ChatId 100 -Index 0
        $reused | Should -Be '.\Mojaz\bot\a.jpg'
        Complete-MojazRowImage -ChatId 100 -Mode new -Value $reused

        $row = @((Get-MojazSelected -ChatId 100).Rows)[1]
        [string]$row.ImageMode | Should -Be 'new'
        [string]$row.Image | Should -Be '.\Mojaz\bot\a.jpg'
    }

    It 'offers the picture, the title and the story on the row screen' {
        Show-MojazRowScreen -RowId 'r_1' -ChatId 100 -UserId 101

        Should -Invoke Send-TelegramMessage -ParameterFilter {
            $callbacks = @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
            $callbacks -contains 'mojaz:editimg:r_1' -and $callbacks -contains 'mojaz:edittitle:r_1' -and $callbacks -contains 'mojaz:edittext:r_1'
        }
    }
}

Describe 'The picture the scene ships with' {
    BeforeEach { $script:MojazSceneImage = ''; $script:MojazSceneImageKey = '' }
    AfterAll { $script:MojazSceneImage = ''; $script:MojazSceneImageKey = '' }

    It 'reads the default from the variable the scene declares' {
        $scene = Join-Path $TestDrive 'picture.cintitle'
        '<CinegyTitler><Scene Fps="25"><Var Name="mojaz_img" Type="File" Value=".\Mojaz\Pic01.png" /><Var Name="title.Text" Value="x" /></Scene></CinegyTitler>' |
            Set-Content -LiteralPath $scene -Encoding utf8

        Get-MojazTemplateImage -Path $scene | Should -Be '.\Mojaz\Pic01.png'
    }

    It 'answers with nothing when the scene declares no such picture' {
        $scene = Join-Path $TestDrive 'nopicture.cintitle'
        '<CinegyTitler><Scene Fps="25"><Var Name="title.Text" Value="x" /></Scene></CinegyTitler>' |
            Set-Content -LiteralPath $scene -Encoding utf8

        Get-MojazTemplateImage -Path $scene | Should -BeNullOrEmpty
    }
}

function global:Assert-MojazKeyboardShape {
    <# Telegram wants an array of arrays. A bare button where a row should be
       is a 400, and the shape that produces it - a leading comma on the first
       row of a multi-row literal - reads exactly like the correct single-row
       idiom, so it is worth asserting rather than eyeballing. #>
    param($Markup, [string]$Because)
    foreach ($row in $Markup.inline_keyboard) {
        ($row -is [hashtable]) | Should -BeFalse -Because "$Because has a bare button where a row should be"
        @($row).Count | Should -BeGreaterThan 0 -Because "$Because has an empty row"
        foreach ($button in @($row)) {
            $button.ContainsKey('text') | Should -BeTrue -Because "$Because has a row entry that is not a button"
            $button.ContainsKey('callback_data') | Should -BeTrue -Because "$Because has a button with no callback"
        }
    }
}

Describe 'Every Mojaz keyboard is shaped the way Telegram wants' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Get-MojazSceneTiming { $null }
        Mock Get-MojazTemplateImage { '.\Mojaz\Pic01.png' }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        $script:bulletin = New-TestMojazLibrary -Rows @(
            (New-TestMojazRow -Id 'r_1' -Title 'أ' -Image '.\Mojaz\bot\a.jpg')
            (New-TestMojazRow -Id 'r_2' -Title 'ب')
        )
        $script:MojazSchedules = @(
            [pscustomobject]@{ Id = 'ms_1'; BulletinId = [string]$script:bulletin.Id; Status = 'scheduled'; ScheduledAt = '2026-09-03T08:00:00+03:00' }
        )
    }

    It 'builds every screen keyboard as rows of buttons' {
        Assert-MojazKeyboardShape -Markup (Get-MojazKeyboard -Bulletin $script:bulletin) -Because 'the bulletin screen'
        Assert-MojazKeyboardShape -Markup (Get-MojazLibraryKeyboard) -Because 'the library screen'
        Assert-MojazKeyboardShape -Markup (Get-MojazSchedulesKeyboard) -Because 'the schedules screen'
        Assert-MojazKeyboardShape -Markup (Get-MojazImageKeyboard) -Because 'the picture chooser'
        Assert-MojazKeyboardShape -Markup (Get-MojazConfirmKeyboard -Question 'q' -ConfirmData 'mojaz:dropconfirm') -Because 'the confirmation'
    }

    It 'builds the row screen keyboard as rows of buttons' {
        # The bug this exists for: a leading comma on the first of two rows
        # flattened the second into bare buttons, and every press of ✏️
        # answered with a 400 in the log and nothing on the phone.
        $script:sent = $null
        Mock Send-TelegramMessage { $script:sent = $ReplyMarkup }

        Show-MojazRowScreen -RowId 'r_1' -ChatId 100 -UserId 101

        $script:sent | Should -Not -BeNullOrEmpty
        Assert-MojazKeyboardShape -Markup $script:sent -Because 'the row screen'
    }
}

Describe 'Hiding the change behind the scene fade' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazTemplateImage { '' }
        # The scene re-cut so one loop is one story: entrance 1.2 s, loop 8 s.
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 8; OutroSeconds = 6.72 } }
        $script:bulletin = New-TestMojazLibrary -DelaySeconds 30 -Rows @(
            (New-TestMojazRow -Id 'r_1' -Title 'أ')
            (New-TestMojazRow -Id 'r_2' -Title 'ب')
        )
    }
    AfterAll { $script:MojazPlayback = $null }

    It 'turns on from its button and says what it means' {
        Test-MojazSyncToLoop -Bulletin (Get-MojazSelected -ChatId 100) | Should -BeFalse

        Switch-MojazSync -ChatId 100 -UserId 101

        Test-MojazSyncToLoop -Bulletin (Get-MojazSelected -ChatId 100) | Should -BeTrue
        Get-MojazSyncText -Bulletin (Get-MojazSelected -ChatId 100) | Should -Match 'لوبًا كاملًا'
        # The dwell no longer decides the pace, so the plan must not quote it.
        Get-MojazPlanText -Bulletin (Get-MojazSelected -ChatId 100) | Should -Match 'كل صف لوب واحد'
    }

    It 'warns instead of silently running a row for a whole minute' {
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 60; OutroSeconds = 6.72 } }
        Switch-MojazSync -ChatId 100 -UserId 101

        Get-MojazSyncText -Bulletin (Get-MojazSelected -ChatId 100) | Should -Match 'اللوب طويل'
    }

    It 'takes the run moments from the loop, not from the dwell' {
        Switch-MojazSync -ChatId 100 -UserId 101

        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeTrue

        $script:MojazPlayback.SyncToLoop | Should -BeTrue
        # The second row is written 0.4 s after the first wrap at 9.2 s, well
        # inside the 1.2 s fade - and nowhere near the bulletin's 30 s dwell.
        [double]$script:MojazPlayback.Plan[1].AtSeconds | Should -Be 9.6
        [double]$script:MojazPlayback.ExitAtSeconds | Should -Be 17.2
    }

    It 'still plays when sync is asked for but the scene has no loop' {
        Switch-MojazSync -ChatId 100 -UserId 101
        Mock Get-MojazSceneTiming { $null }

        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeTrue

        $script:MojazPlayback.SyncToLoop | Should -BeFalse
        Get-MojazSyncText -Bulletin (Get-MojazSelected -ChatId 100) | Should -Match 'لا يعطي لوبًا صالحًا'
    }

    It 'keeps the loop fast enough to hit the fade while a bulletin is on air' {
        # The bug this exists for: the poll timeout knew about snapshots and
        # relays but not about a bulletin, so the tick could be half a minute
        # apart and miss every window.
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        Get-EffectivePollTimeout | Should -Be 1
    }
}

Describe 'Taking the bulletin off air from the main menu' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazSceneTiming { $null }
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        New-TestMojazLibrary -DelaySeconds 4 -Rows @(
            (New-TestMojazRow -Id 'r_1' -Title 'أ')
            (New-TestMojazRow -Id 'r_2' -Title 'ب')
        ) | Out-Null
        $script:OnAir = @{}
    }
    AfterAll { $script:MojazPlayback = $null; $script:OnAir = @{} }

    It 'keeps the button in the main menu whether or not the bulletin is up' {
        # It stays in one place so the operator can learn where it is; only
        # its colour follows what is actually on air.
        Test-MojazOnAirLayer | Should -BeFalse
        $resting = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard | ForEach-Object { @($_) } |
                Where-Object { $_['callback_data'] -eq 'mojaz:hide' })
        @($resting).Count | Should -Be 1
        $resting[0].ContainsKey('style') | Should -BeFalse

        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        Test-MojazOnAirLayer | Should -BeTrue
        $live = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard | ForEach-Object { @($_) } |
                Where-Object { $_['callback_data'] -eq 'mojaz:hide' })
        @($live).Count | Should -Be 1
        [string]$live[0]['style'] | Should -Be 'danger'
    }

    It 'offers it for a scene left on the layer after a run ended' {
        $script:OnAir = @{ 5 = [pscustomobject]@{ Key = 'Mojaz' } }

        Test-MojazOnAirLayer | Should -BeTrue
    }

    It 'stops the run and leaves by exit, not by a cut' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        Hide-MojazOnAir -ChatId 100 -UserId 101 | Should -BeTrue

        $script:MojazPlayback | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
    }

    It 'says so rather than exiting a layer that is already clear' {
        Hide-MojazOnAir -ChatId 100 -UserId 101 | Should -BeFalse

        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'ليس على الهواء' }
    }

    It 'ends the run when the layer is taken by anything else' {
        # The bug this exists for: the plain hide and exit buttons knew nothing
        # about a bulletin, so the run kept writing rows into a hidden scene
        # and sent an exit of its own long afterwards.
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        Stop-MojazForLayer -Layer 5 | Should -BeTrue

        $script:MojazPlayback | Should -BeNullOrEmpty
    }

    It 'leaves a run alone when a different layer comes down' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        Stop-MojazForLayer -Layer 7 | Should -BeFalse

        $script:MojazPlayback | Should -Not -BeNullOrEmpty
    }
}

Describe 'Checking and sizing an uploaded picture' {
    BeforeEach {
        Mock Write-BridgeLog {}
        $script:MojazImageSize = $null; $script:MojazImageSizeKey = ''
        # 0 means "ask the scene", which is what the plate tests are about.
        $config.Settings | Add-Member -NotePropertyName 'MojazImageWidth' -NotePropertyValue 0 -Force
        $config.Settings | Add-Member -NotePropertyName 'MojazImageHeight' -NotePropertyValue 0 -Force
    }
    AfterAll { $script:MojazImageSize = $null; $script:MojazImageSizeKey = '' }

    It 'takes the size from the plate that shows the picture' {
        # Not a number in a setting: the scene says how big its own plate is.
        $scene = Join-Path $TestDrive 'plate.cintitle'
        @'
<CinegyTitler><Scene Fps="25">
<Plate Name="bg" Size="1920.00;1080.00" Source="File" File=".\Mojaz\bg.png" />
<Plate Name="img 01" Size="525.38;291.61" Source="File" File="${mojaz_img}" />
</Scene></CinegyTitler>
'@ | Set-Content -LiteralPath $scene -Encoding utf8

        $size = Get-MojazImageSize -Path $scene

        $size.Width | Should -Be 525
        $size.Height | Should -Be 292
    }

    It 'takes the exporter measurement over the plate when it is given' {
        # The plate is 525x292 in scene units; Titler exports 538x303. The
        # measured number is the one the picture has to match.
        $config.Settings | Add-Member -NotePropertyName 'MojazImageWidth' -NotePropertyValue 538 -Force
        $config.Settings | Add-Member -NotePropertyName 'MojazImageHeight' -NotePropertyValue 303 -Force
        $scene = Join-Path $TestDrive 'measured.cintitle'
        '<CinegyTitler><Scene Fps="25"><Plate Name="img 01" Size="525.38;291.61" Source="File" File="${mojaz_img}" /></Scene></CinegyTitler>' |
            Set-Content -LiteralPath $scene -Encoding utf8

        $size = Get-MojazImageSize -Path $scene

        $size.Width | Should -Be 538
        $size.Height | Should -Be 303
    }

    It 'answers with nothing when no plate carries the picture' {
        $scene = Join-Path $TestDrive 'noplate.cintitle'
        '<CinegyTitler><Scene Fps="25"><Plate Name="bg" Size="10;10" File=".\a.png" /></Scene></CinegyTitler>' |
            Set-Content -LiteralPath $scene -Encoding utf8

        Get-MojazImageSize -Path $scene | Should -BeNullOrEmpty
    }

    It 'fills the plate exactly, cropping rather than squashing' {
        Add-Type -AssemblyName System.Drawing
        $source = Join-Path $TestDrive 'phone.jpg'
        $wide = New-Object System.Drawing.Bitmap(1600, 900)
        $wide.Save($source, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $wide.Dispose()
        $destination = Join-Path $TestDrive 'sized.png'

        Convert-MojazPicture -SourcePath $source -DestinationPath $destination -Size ([pscustomobject]@{ Width = 525; Height = 292 }) | Should -BeTrue

        $result = [System.Drawing.Image]::FromFile($destination)
        try {
            $result.Width | Should -Be 525
            $result.Height | Should -Be 292
        }
        finally { $result.Dispose() }
    }

    It 'refuses a file that is not a picture' {
        $notAPicture = Join-Path $TestDrive 'notes.txt'
        'this is not a picture' | Set-Content -LiteralPath $notAPicture -Encoding utf8
        $destination = Join-Path $TestDrive 'rejected.png'

        { Convert-MojazPicture -SourcePath $notAPicture -DestinationPath $destination -Size $null } | Should -Throw
        Test-Path -LiteralPath $destination | Should -BeFalse
    }
}

Describe 'The urgent and the bulletin, and which one yields' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazSceneTiming { $null }
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        Mock Get-MojazUrgentTemplate { @{ Key = 'Urgent'; Path = 'D:\cingy cg\urgent.cintitle'; Layer = 7 } }
        New-TestMojazLibrary -DelaySeconds 4 -Rows @(
            (New-TestMojazRow -Id 'r_1' -Title 'أ')
            (New-TestMojazRow -Id 'r_2' -Title 'ب')
        ) | Out-Null
        $script:OnAir = @{}
        $script:MojazPendingUrgent = $null
    }
    AfterAll { $script:MojazPlayback = $null; $script:OnAir = @{}; $script:MojazPendingUrgent = $null }

    It 'asks instead of starting a bulletin under a live urgent' {
        $script:OnAir = @{ 7 = [pscustomobject]@{ Key = 'Urgent' } }

        Start-MojazPlayback -ChatId 100 -UserId 101 | Should -BeFalse

        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -ParameterFilter {
            $Text -match 'العاجل على الهواء' -and
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) -contains 'mojaz:playafter'
        }
    }

    It 'starts anyway when the operator says so' {
        $script:OnAir = @{ 7 = [pscustomobject]@{ Key = 'Urgent' } }

        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Should -BeTrue
    }

    It 'books a bulletin that agreed to wait, and holds it while the urgent is up' {
        $script:OnAir = @{ 7 = [pscustomobject]@{ Key = 'Urgent' } }

        Start-MojazAfterUrgent -ChatId 100 -UserId 101 | Should -BeTrue
        @($script:MojazSchedules).Count | Should -Be 1

        # Due now, but the urgent still holds the air.
        Update-MojazScheduleQueue -Now ([datetimeoffset]::Now.AddMinutes(1))
        [string]$script:MojazSchedules[0].Status | Should -Be 'queued'
        [string]$script:MojazSchedules[0].DelayReason | Should -Be 'urgent_on_air'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly

        # The urgent leaves; nobody has to press anything.
        $script:OnAir = @{}
        Update-MojazScheduleQueue -Now ([datetimeoffset]::Now.AddMinutes(2))

        [string]$script:MojazSchedules[0].Status | Should -Be 'running'
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
    }

    It 'pulls a running bulletin off when the urgent goes out' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        $script:MojazPlayback | Should -Not -BeNullOrEmpty

        Clear-MojazForUrgent -ChatId 100 -UserId 101 | Should -BeTrue

        $script:MojazPlayback | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
    }

    It 'sends a held urgent the moment the bulletin ends' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        Set-MojazPendingUrgent -Key 'Urgent' -Variables @{ 'text' = 'خبر عاجل' } -ChatId 100 -UserId 101

        Stop-MojazPlayback -ChatId 100 -UserId 101 -Quiet | Out-Null

        $script:MojazPendingUrgent | Should -BeNullOrEmpty
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $Key -eq 'Urgent' }
    }

    It 'sends the held urgent at once when the operator will not wait' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        Set-MojazPendingUrgent -Key 'Urgent' -Variables @{ 'text' = 'خبر' } -ChatId 100 -UserId 101

        Send-MojazPendingUrgentNow -ChatId 100 -UserId 101 | Should -BeTrue

        $script:MojazPendingUrgent | Should -BeNullOrEmpty
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $Key -eq 'Urgent' }
    }

    It 'leaves the bulletin alone when something other than the urgent goes out' {
        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        Clear-MojazForUrgent -ChatId 100 -UserId 101 | Out-Null
        $script:MojazPlayback | Should -BeNullOrEmpty

        # A second call with nothing running is a no-op, not an error.
        Clear-MojazForUrgent -ChatId 100 -UserId 101 | Should -BeFalse
    }
}

Describe 'The strip stands down for the bulletin and comes back after it' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 8; OutroSeconds = 6.72 } }
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        Mock Get-MojazTickerTemplate { @{ Key = 'News-Ticker'; Path = 'D:\cingy cg\ticker.cintitle'; Layer = 8 } }
        Mock Get-MojazUrgentTemplate { @{ Key = 'Urgent'; Path = 'D:\cingy cg\Urgent-Mov.cintitle'; Layer = 7 } }
        $config.Settings | Add-Member -NotePropertyName 'MojazHidesTicker' -NotePropertyValue $true -Force
        New-TestMojazLibrary -DelaySeconds 4 -Rows @((New-TestMojazRow -Id 'r_1' -Title 'أ')) | Out-Null
        # The strip and the logo are up, as they are before a bulletin.
        $script:OnAir = @{
            8 = [pscustomobject]@{ Key = 'News-Ticker'; ChatId = 100 }
            9 = [pscustomobject]@{ Key = 'logo'; ChatId = 100 }
        }
        $script:MojazTickerReturn = $null
        $script:MojazPendingUrgent = $null
    }
    AfterAll {
        $script:MojazPlayback = $null; $script:OnAir = @{}; $script:MojazTickerReturn = $null
        # One settings object for the suite: put it back rather than leaving
        # it on for whatever runs next.
        $config.Settings | Add-Member -NotePropertyName 'MojazHidesTicker' -NotePropertyValue $false -Force
    }

    It 'takes the strip off as the bulletin goes up, and leaves the logo alone' {
        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Should -BeTrue

        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 8 }
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly -ParameterFilter { $Layer -eq 9 }
        $script:MojazTickerReturn | Should -Not -BeNullOrEmpty
    }

    It 'puts it back after the bulletin, once the outro has run' {
        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Out-Null
        Stop-MojazPlayback -ChatId 100 -UserId 101 -Quiet | Out-Null

        # Booked, not done: the scene is still playing its way out.
        $script:MojazTickerReturn.At | Should -Not -BeNullOrEmpty
        Update-MojazTickerReturn
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly -ParameterFilter { $Key -eq 'News-Ticker' }

        $script:MojazTickerReturn.At = (Get-Date).AddSeconds(-1)
        Update-MojazTickerReturn

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $Key -eq 'News-Ticker' }
        $script:MojazTickerReturn | Should -BeNullOrEmpty
    }

    It 'brings it back when the urgent cuts the bulletin short as well' {
        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Out-Null

        Clear-MojazForUrgent -ChatId 100 -UserId 101 | Out-Null

        $script:MojazTickerReturn.At | Should -Not -BeNullOrEmpty
    }

    It 'never puts back a strip that was not on air to begin with' {
        # Otherwise the bulletin decides what the channel looks like.
        $script:OnAir = @{ 9 = [pscustomobject]@{ Key = 'logo'; ChatId = 100 } }

        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Out-Null
        Stop-MojazPlayback -ChatId 100 -UserId 101 -Quiet | Out-Null
        Update-MojazTickerReturn

        $script:MojazTickerReturn | Should -BeNullOrEmpty
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly -ParameterFilter { $Key -eq 'News-Ticker' }
    }

    It 'leaves the strip alone when the setting is off' {
        $config.Settings | Add-Member -NotePropertyName 'MojazHidesTicker' -NotePropertyValue $false -Force

        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Out-Null

        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly -ParameterFilter { $Layer -eq 8 }
        $script:MojazTickerReturn | Should -BeNullOrEmpty
    }

    It 'books the return when the bulletin layer is pulled by hand too' {
        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Out-Null

        Stop-MojazForLayer -Layer 5 | Should -BeTrue

        $script:MojazTickerReturn.At | Should -Not -BeNullOrEmpty
    }
}
