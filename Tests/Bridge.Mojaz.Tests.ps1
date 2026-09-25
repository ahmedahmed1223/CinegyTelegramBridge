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
    # The tests read better in seconds; the bulletin stores frames, so the
    # helper converts at the boundary rather than every call site doing it.
    $bulletin.DelayFrames = [int]($DelaySeconds * 25)
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

    It 'refuses a dwell outside one frame to ten minutes' {
        foreach ($value in @('0', '15001')) {
            Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_delay'; UserId = 101; BulletinId = [string]$script:bulletin.Id }
            Complete-MojazTiming -Which delay -ChatId 100 -Value $value
            # Refused: the prompt is still open and the number has not moved.
            Get-PendingState -ChatId 100 | Should -Not -BeNullOrEmpty
        }

        Set-PendingState -ChatId 100 -State @{ Mode = 'mojaz_delay'; UserId = 101; BulletinId = [string]$script:bulletin.Id }
        Complete-MojazTiming -Which delay -ChatId 100 -Value '175'

        # 175 frames is the seven seconds this used to be typed as.
        [int](Get-MojazSelected -ChatId 100).DelayFrames | Should -Be 175
        Get-MojazDelaySeconds -Bulletin (Get-MojazSelected -ChatId 100) | Should -Be 7
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
        # This bridge has a Mojaz scene, which is what a bulletin plays on.
        # Without it Start-MojazPlayback reads (Get-MojazTemplate).Layer off
        # $null and throws under Set-StrictMode - and the SHOW below is mocked,
        # so nothing else in the setup notices the scene is missing. That is how
        # these tests have been red since the anchor landed in 8.19.0.
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        # No engine round trip here: these tests are not about the anchor, and
        # an unmocked one would reach for Cinegy over HTTP.
        Mock Get-CinegyLayerStartedAtUtc { $null }
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
        $config.Settings | Add-Member -NotePropertyName 'MojazIntroExtraFrames' -NotePropertyValue 50 -Force

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
        # This bridge has a Mojaz scene, which is what a bulletin plays on.
        # Without it Start-MojazPlayback reads (Get-MojazTemplate).Layer off
        # $null and throws under Set-StrictMode - and the SHOW below is mocked,
        # so nothing else in the setup notices the scene is missing. That is how
        # these tests have been red since the anchor landed in 8.19.0.
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        # No engine round trip here: these tests are not about the anchor, and
        # an unmocked one would reach for Cinegy over HTTP.
        Mock Get-CinegyLayerStartedAtUtc { $null }
        $script:bulletin = New-TestMojazLibrary -DelaySeconds 8
    }

    It 'falls back to the setting and to half the dwell until told otherwise' {
        # The scene is the first source; these are what is used without one.
        Mock Get-MojazSceneTiming { $null }
        $config.Settings | Add-Member -NotePropertyName 'MojazIntroExtraFrames' -NotePropertyValue 50 -Force

        Get-MojazIntroSeconds -Bulletin $script:bulletin | Should -Be 2
        Get-MojazLastRowSeconds -Bulletin $script:bulletin | Should -Be 4
    }

    It 'takes the bulletin its own numbers, and zero puts the default back' {
        Mock Get-MojazSceneTiming { $null }
        # Frames now: 125 and 300 are the five and twelve seconds these used
        # to be typed as, at 25 fps.
        foreach ($pair in @(@('intro', '125'), @('last', '300'))) {
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
        Complete-MojazTiming -Which last -ChatId 100 -Value '15001'

        [int](Get-JsonProp (Get-MojazSelected -ChatId 100) 'LastRowFrames') | Should -Be 0
        Get-PendingState -ChatId 100 | Should -Not -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match '❌' }
    }

    It 'holds the last row for the number it was given' {
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazSceneTiming { $null }
        $script:MojazLibrary.Bulletins[0].Rows = @((New-TestMojazRow -Title 'أ'), (New-TestMojazRow -Title 'ب'))
        $script:MojazLibrary.Bulletins[0].LastRowFrames = 375

        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null
        Step-TestMojazPlayback

        ([double]$script:MojazPlayback.ExitAtSeconds - [double]$script:MojazPlayback.Plan[1].AtSeconds) | Should -Be 15
    }
}

Describe 'Timing read from the scene itself' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        $script:bulletin = New-TestMojazLibrary -DelaySeconds 20
        $script:MojazSceneTimingCache.Clear()
        # One settings object for the whole suite: these tests are about what
        # the scene says, so the newsroom defaults that outrank it are cleared.
        $config.Settings | Add-Member -NotePropertyName 'MojazIntroExtraFrames' -NotePropertyValue 0 -Force
        $config.Settings | Add-Member -NotePropertyName 'MojazLastRowFrames' -NotePropertyValue 0 -Force
        $config.Settings | Add-Member -NotePropertyName 'BroadcastFps' -NotePropertyValue '25' -Force
    }
    AfterAll { $script:MojazSceneTimingCache.Clear() }

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

    It 'uses the scene frames exactly, with no rounding to whole seconds' {
        # Rounding up used to add most of a second to the entrance and a
        # quarter to the exit. The animation is cut in frames; so is this.
        Mock Get-MojazSceneTiming {
            [pscustomobject]@{ Fps = 25; IntroFrames = 30; LoopFrames = 1500; OutroFrames = 168
                IntroSeconds = 1.2; LoopSeconds = 60; OutroSeconds = 6.72 }
        }

        Get-MojazIntroFrames -Bulletin $script:bulletin | Should -Be 30
        Get-MojazLastRowFrames -Bulletin $script:bulletin | Should -Be 168
        Get-MojazIntroSeconds -Bulletin $script:bulletin | Should -Be 1.2
        Get-MojazLastRowSeconds -Bulletin $script:bulletin | Should -Be 6.72
    }

    It 'answers in frames for a scene that states only seconds' {
        # An older cached timing, or a stand-in for one, still has to work.
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 60; OutroSeconds = 6.72 } }

        Get-MojazIntroFrames -Bulletin $script:bulletin | Should -Be 30
        Get-MojazLastRowFrames -Bulletin $script:bulletin | Should -Be 168
    }

    It 'still lets the bulletin override what the scene says' {
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 60; OutroSeconds = 6.72 } }
        $script:bulletin.IntroExtraFrames = 125
        $script:bulletin.LastRowFrames = 375

        Get-MojazIntroSeconds -Bulletin $script:bulletin | Should -Be 5
        Get-MojazLastRowSeconds -Bulletin $script:bulletin | Should -Be 15
    }

    It 'falls back to the setting and half the dwell when the scene cannot be read' {
        # 50 frames at 25 fps is the two seconds this used to be written as.
        $config.Settings | Add-Member -NotePropertyName 'MojazIntroExtraFrames' -NotePropertyValue 50 -Force
        $config.Settings | Add-Member -NotePropertyName 'BroadcastFps' -NotePropertyValue '25' -Force
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
        # The legacy file spoke seconds; the library speaks frames, so the
        # migration converts rather than dropping what was set.
        $bulletin.DelayFrames | Should -Be 300
        $bulletin.IntroExtraFrames | Should -Be 75
        $bulletin.LastRowFrames | Should -Be 125
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
        # This bridge has a Mojaz scene, which is what a bulletin plays on.
        # Without it Start-MojazPlayback reads (Get-MojazTemplate).Layer off
        # $null and throws under Set-StrictMode - and the SHOW below is mocked,
        # so nothing else in the setup notices the scene is missing. That is how
        # these tests have been red since the anchor landed in 8.19.0.
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        # No engine round trip here: these tests are not about the anchor, and
        # an unmocked one would reach for Cinegy over HTTP.
        Mock Get-CinegyLayerStartedAtUtc { $null }
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
        # This bridge has a Mojaz scene, which is what a bulletin plays on.
        # Without it Start-MojazPlayback reads (Get-MojazTemplate).Layer off
        # $null and throws under Set-StrictMode - and the SHOW below is mocked,
        # so nothing else in the setup notices the scene is missing. That is how
        # these tests have been red since the anchor landed in 8.19.0.
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        # No engine round trip here: these tests are not about the anchor, and
        # an unmocked one would reach for Cinegy over HTTP.
        Mock Get-CinegyLayerStartedAtUtc { $null }
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
        # This bridge has a Mojaz scene, which is what a bulletin plays on.
        # Without it Start-MojazPlayback reads (Get-MojazTemplate).Layer off
        # $null and throws under Set-StrictMode - and the SHOW below is mocked,
        # so nothing else in the setup notices the scene is missing. That is how
        # these tests have been red since the anchor landed in 8.19.0.
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        # No engine round trip here: these tests are not about the anchor, and
        # an unmocked one would reach for Cinegy over HTTP.
        Mock Get-CinegyLayerStartedAtUtc { $null }
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
        # This bridge has a Mojaz scene, which is what a bulletin plays on.
        # Without it Start-MojazPlayback reads (Get-MojazTemplate).Layer off
        # $null and throws under Set-StrictMode - and the SHOW below is mocked,
        # so nothing else in the setup notices the scene is missing. That is how
        # these tests have been red since the anchor landed in 8.19.0.
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        # No engine round trip here: these tests are not about the anchor, and
        # an unmocked one would reach for Cinegy over HTTP.
        Mock Get-CinegyLayerStartedAtUtc { $null }
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

    It 'shows the button only while a bulletin is really up' {
        # It used to sit in the menu permanently so its place could be learned,
        # greyed when there was nothing to hide - but offering to take
        # something off air when nothing is on air reads as a claim that
        # something is.
        Test-MojazOnAirLayer | Should -BeFalse
        $resting = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard | ForEach-Object { @($_) } |
                Where-Object { $_['callback_data'] -eq 'mojaz:hide' })
        @($resting).Count | Should -Be 0

        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        Test-MojazOnAirLayer | Should -BeTrue
        $live = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard | ForEach-Object { @($_) } |
                Where-Object { $_['callback_data'] -eq 'mojaz:hide' })
        @($live).Count | Should -Be 1
        [string]$live[0]['style'] | Should -Be 'danger'
    }

    It 'offers it for a scene left on the layer after a run ended' {
        $script:OnAir = @{ 5 = [pscustomobject]@{ Key = 'Mojaz'; Source = 'bridge' } }

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

Describe 'Booking a bulletin the way the templates are booked' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Get-MojazSceneTiming { $null }
        $script:bulletin = New-TestMojazLibrary -Rows @((New-TestMojazRow -Id 'r_1' -Title 'أ'))
    }
    AfterAll { $script:MojazSchedules = @(); $script:MojazPlayback = $null }

    It 'offers the same picker the template scheduling offers' {
        # Not a second way of asking the same question: the offsets and the
        # calendar come from one keyboard, so both flows stay in step.
        Start-MojazLaterPrompt -ChatId 100 -UserId 101

        Should -Invoke Send-TelegramMessage -ParameterFilter {
            $callbacks = @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
            $callbacks -contains 'schrel:30' -and @($callbacks | Where-Object { $_ -like 'schcal:*' }).Count -eq 1
        }
    }

    It 'books the moment the picker chose' {
        Start-MojazLaterPrompt -ChatId 100 -UserId 101
        $state = Get-PendingState -ChatId 100
        $moment = [datetimeoffset]::Now.AddMinutes(30)

        Set-BridgeChosenMoment -ChatId 100 -State $state -ScheduledAt $moment -TimeZoneId 'Asia/Baghdad'

        @($script:MojazSchedules).Count | Should -Be 1
        [string]$script:MojazSchedules[0].BulletinId | Should -Be ([string]$script:bulletin.Id)
        # The flow is finished, not left waiting for a typed time as well.
        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty
    }

    It 'still books a time that was typed rather than picked' {
        Start-MojazLaterPrompt -ChatId 100 -UserId 101

        Complete-MojazLater -ChatId 100 -Value '+30'

        @($script:MojazSchedules).Count | Should -Be 1
    }

    It 'sends a picked moment for a template to the template flow, not this one' {
        Mock Set-ScheduleMoment {}
        $state = @{ Mode = 'schedule_time'; UserId = 101 }

        Set-BridgeChosenMoment -ChatId 100 -State $state -ScheduledAt ([datetimeoffset]::Now.AddMinutes(30)) -TimeZoneId 'Asia/Baghdad'

        Should -Invoke Set-ScheduleMoment -Times 1 -Exactly
        @($script:MojazSchedules).Count | Should -Be 0
    }
}

Describe 'Telling the operator without being asked' {
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
        $config.Settings | Add-Member -NotePropertyName 'MojazNotifyOnFinish' -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName 'MojazScheduleNoticeSeconds' -NotePropertyValue 60 -Force
        $config.Settings | Add-Member -NotePropertyName 'MojazHidesTicker' -NotePropertyValue $false -Force
        $script:bulletin = New-TestMojazLibrary -DelaySeconds 4 -Rows @(
            (New-TestMojazRow -Id 'r_1' -Title 'أ')
            (New-TestMojazRow -Id 'r_2' -Title 'ب')
        )
        $script:OnAir = @{}
    }
    AfterAll { $script:MojazPlayback = $null; $script:MojazSchedules = @(); $script:OnAir = @{} }

    It 'says so when the bulletin ends by itself' {
        # The one ending nothing else announces: it finishes minutes after the
        # operator stopped watching the screen.
        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Out-Null
        foreach ($step in 1..2) { Step-TestMojazPlayback }

        $script:MojazPlayback | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'وخرج عن الهواء' }
    }

    It 'stays quiet about the ending when the option is off' {
        $config.Settings | Add-Member -NotePropertyName 'MojazNotifyOnFinish' -NotePropertyValue $false -Force
        Start-MojazPlayback -ChatId 100 -UserId 101 -Force | Out-Null
        foreach ($step in 1..2) { Step-TestMojazPlayback }

        Should -Invoke Send-TelegramMessage -Times 0 -Exactly -ParameterFilter { $Text -match 'وخرج عن الهواء' }
    }

    It 'warns once before a booked bulletin starts, not every second' {
        $id = [string]$script:bulletin.Id
        $script:MojazSchedules = @([pscustomobject]@{
                Id = 'ms_soon'; BulletinId = $id; ScheduledAt = '2026-09-04T08:00:00+03:00'; CreatedAt = '2026-09-03T08:00:00+03:00'
                CreatedBy = 101; ChatId = 100; Status = 'scheduled'; DueAt = $null; StartedAt = $null; CompletedAt = $null
                DelayReason = ''; LastError = ''; NoticedAt = $null
            })

        # Too early for a word.
        Send-MojazScheduleNotices -Now ([datetimeoffset]'2026-09-04T07:58:00+03:00')
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly -ParameterFilter { $Text -match 'يبدأ بعد' }

        # Inside the minute, twice.
        Send-MojazScheduleNotices -Now ([datetimeoffset]'2026-09-04T07:59:30+03:00')
        Send-MojazScheduleNotices -Now ([datetimeoffset]'2026-09-04T07:59:45+03:00')

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'يبدأ بعد' }
        [string]$script:MojazSchedules[0].NoticedAt | Should -Not -BeNullOrEmpty
    }

    It 'sends no warning when the lead is zero' {
        $config.Settings | Add-Member -NotePropertyName 'MojazScheduleNoticeSeconds' -NotePropertyValue 0 -Force
        $script:MojazSchedules = @([pscustomobject]@{
                Id = 'ms_soon'; BulletinId = [string]$script:bulletin.Id; ScheduledAt = '2026-09-04T08:00:00+03:00'
                CreatedAt = '2026-09-03T08:00:00+03:00'; CreatedBy = 101; ChatId = 100; Status = 'scheduled'
                DueAt = $null; StartedAt = $null; CompletedAt = $null; DelayReason = ''; LastError = ''; NoticedAt = $null
            })

        Send-MojazScheduleNotices -Now ([datetimeoffset]'2026-09-04T07:59:30+03:00')

        Should -Invoke Send-TelegramMessage -Times 0 -Exactly -ParameterFilter { $Text -match 'يبدأ بعد' }
    }
}

Describe 'Reading the bulletin back before it goes out' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramPagedText {}
        Mock Send-TelegramRichMessage { $false }
        Mock Get-MojazSceneTiming { $null }
        Mock Get-MojazTemplateImage { '.\Mojaz\Pic01.png' }
        $script:long = 'خبر طويل ' * 40
        $script:bulletin = New-TestMojazLibrary -Rows @(
            (New-TestMojazRow -Id 'r_1' -Title 'عنوان طويل جدًّا يتجاوز أربعة وعشرين حرفًا بكثير' -Text $script:long -Image '.\Mojaz\bot\a.jpg')
            (New-TestMojazRow -Id 'r_2' -Title 'الثاني' -Text 'نص قصير')
        )
    }

    It 'cuts nothing, where the table cuts at 24 and 60' {
        $preview = Get-MojazPreviewText -Bulletin (Get-MojazSelected -ChatId 100)

        $preview | Should -Match 'يتجاوز أربعة وعشرين حرفًا بكثير'
        $preview | Should -Match ([regex]::Escape($script:long.Trim()))
        $preview | Should -Not -Match '…'
    }

    It 'says which picture each row will really show' {
        $preview = Get-MojazPreviewText -Bulletin (Get-MojazSelected -ChatId 100)

        $preview | Should -Match 'a\.jpg'
        # The second row inherits, so it shows the first row's picture.
        @([regex]::Matches($preview, 'a\.jpg')).Count | Should -Be 2
    }

    It 'is offered from the bulletin screen, and pages itself' {
        $callbacks = @((Get-MojazKeyboard -Bulletin (Get-MojazSelected -ChatId 100)).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $callbacks | Should -Contain 'mojaz:preview'

        Show-MojazPreviewScreen -ChatId 100 -UserId 101

        # Paged, because ten rows of four hundred characters is past what
        # Telegram takes in one message.
        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly -ParameterFilter { $ParseMode -eq 'HTML' }
    }

    It 'offers no preview button for an empty table' {
        New-TestMojazLibrary | Out-Null
        $callbacks = @((Get-MojazKeyboard -Bulletin (Get-MojazSelected -ChatId 100)).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })

        $callbacks | Should -Not -Contain 'mojaz:preview'
    }

    It 'escapes copy that would otherwise break the markup' {
        $script:MojazLibrary.Bulletins[0].Rows = @((New-TestMojazRow -Title '<b>خطر</b>' -Text 'قوس > وآخر <'))

        $preview = Get-MojazPreviewText -Bulletin (Get-MojazSelected -ChatId 100)

        $preview | Should -Match '&lt;b&gt;خطر'
        $preview | Should -Not -Match '<b>خطر'
    }
}

Describe 'A bulletin that was on air when the bridge restarted' {
    BeforeEach {
        Mock Write-BridgeLog { }
        Mock Send-AdminBroadcast { $true }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = ''; Error = '' } }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{RESTORED}' } }
        Mock Request-MojazTickerReturn { $true }
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        $script:MojazPlayback = $null
        $script:OnAir = @{ 5 = @{ Key = 'Mojaz'; Source = 'bridge' } }
        Clear-MojazPlaybackState
    }
    AfterAll { $script:MojazPlayback = $null; $script:OnAir = @{}; Clear-MojazPlaybackState }

    function global:Write-TestPlaybackState {
        param([datetime]$StartedAt, [double]$ExitAtSeconds = 80, [string]$ActiveId = '{RESTORED}',
            [bool]$ActiveIdConfirmed = $true, [string]$AirStartedAt = '')
        [ordered]@{
            StartedAt = $StartedAt.ToString('o'); BulletinId = 'b_1'; BulletinName = 'موجز المساء'
            ScheduleId = ''; OperationId = 'mojaz-test'; ChatId = 100; UserId = 101; ActiveId = $ActiveId; ActiveIdConfirmed = $ActiveIdConfirmed
            AirStartedAt = $AirStartedAt
            ExitAtSeconds = $ExitAtSeconds; SyncToLoop = $false
            Rows = @(1..4 | ForEach-Object { @{ Id = "r_$_"; Title = "عنوان $_"; Text = 'نص'; ImageMode = 'inherit'; Image = '' } })
            Plan = @(0..3 | ForEach-Object { @{ Index = $_; RowId = "r_$($_ + 1)"; AtSeconds = ($_ * 20.0); HoldSeconds = 20 } })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-MojazPlaybackFile) -Encoding utf8
    }

    It 'leaves the layer untouched when recovery cannot prove scene ownership (<Reason>, <Elapsed>s)' -ForEach @(
        foreach ($elapsed in @(50, 500)) {
            @{ Reason='replacement'; Elapsed=$elapsed; SavedId='{RESTORED}'; Confirmed=$true; LiveId='{NEW}'; Success=$true }
            @{ Reason='status failure'; Elapsed=$elapsed; SavedId='{RESTORED}'; Confirmed=$true; LiveId='{RESTORED}'; Success=$false }
            @{ Reason='missing live identity'; Elapsed=$elapsed; SavedId='{RESTORED}'; Confirmed=$true; LiveId=''; Success=$true }
            @{ Reason='missing saved identity'; Elapsed=$elapsed; SavedId=''; Confirmed=$true; LiveId='{RESTORED}'; Success=$true }
            @{ Reason='unconfirmed saved identity'; Elapsed=$elapsed; SavedId='{RESTORED}'; Confirmed=$false; LiveId='{RESTORED}'; Success=$true }
        }
    ) {
        $now = [datetime]'2026-01-02T12:00:00Z'
        Write-TestPlaybackState -StartedAt $now.AddSeconds(-$Elapsed) -ActiveId $SavedId -ActiveIdConfirmed $Confirmed
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$Success; IsOnAir=$true; ActiveId=$LiveId } }

        Restore-MojazPlayback -Now $now | Should -BeFalse
        $script:MojazPlayback | Should -BeNullOrEmpty
        Should -Invoke Send-PostboxValues -Times 0 -Exactly
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
        Should -Invoke Request-MojazTickerReturn -Times 0 -Exactly
        Test-Path -LiteralPath (Get-MojazPlaybackFile) | Should -BeFalse
    }

    It 'uses the supplied recovery time with the engine start and accepts normalized identity' {
        $now = [datetime]'2026-01-02T12:00:00Z'
        Write-TestPlaybackState -StartedAt $now.AddSeconds(-500) -AirStartedAt $now.AddSeconds(-50).ToString('o')
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId=' restored ' } }

        Restore-MojazPlayback -Now $now | Should -BeTrue
        $script:MojazPlayback.Index | Should -Be 2
        $script:MojazPlayback.ClockOffset | Should -Be 50
        Should -Invoke Send-PostboxValues -Times 1 -Exactly
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'picks the run up at the row the clock says, not at the first' {
        # This is the incident: the bridge was restarted three minutes into a
        # bulletin, the scene kept looping on the row it was on, and nothing
        # was left to write the next row or send the exit.
        Write-TestPlaybackState -StartedAt (Get-Date).AddSeconds(-50)

        Restore-MojazPlayback | Should -BeTrue
        $script:MojazPlayback | Should -Not -BeNullOrEmpty
        # 50s in, with a row every 20s: rows at 0, 20 and 40 have gone.
        $script:MojazPlayback.Index | Should -Be 2
        Should -Invoke Send-PostboxValues -Times 1 -Exactly -ParameterFilter { $Values['title.Text'] -eq 'عنوان 3' }
        # A range, not a number: this is measured against a wall clock and
        # the second it lands in depends on how long the test itself took.
        [double]$script:MojazPlayback.ClockOffset | Should -BeGreaterOrEqual 50
        [double]$script:MojazPlayback.ClockOffset | Should -BeLessThan 60
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'persists and restores the template image used by later rows' {
        $script:MojazPlayback = @{
            Index=0; ChatId=1L; UserId=2L; Clock=[Diagnostics.Stopwatch]::StartNew(); ClockOffset=0.0
            Rows=@((New-TestMojazRow -Title 'أول'), (New-TestMojazRow -Title 'ثانٍ'))
            Plan=@(@{AtSeconds=0.0},@{AtSeconds=20.0}); ExitAtSeconds=40.0; SyncToLoop=$false
            BulletinId='b'; BulletinName='نشرة'; ScheduleId=''; OperationId='op'; StartedAt=(Get-Date).ToString('o')
            TemplateImage='.\Mojaz\Pic01.png'; ActiveId='{A}'; ActiveIdConfirmed=$true
        }
        Save-MojazPlaybackState | Should -BeTrue
        $saved = Get-Content -LiteralPath (Get-MojazPlaybackFile) -Raw | ConvertFrom-Json
        $saved.TemplateImage | Should -Be '.\Mojaz\Pic01.png'
        $saved.ActiveId | Should -Be '{A}'
    }

    It 'takes off a bulletin that is already past its end' {
        Write-TestPlaybackState -StartedAt (Get-Date).AddSeconds(-500)

        Restore-MojazPlayback | Should -BeTrue
        $script:MojazPlayback | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 5 }
    }

    It 'leaves a layer alone when the bulletin is no longer what is on it' {
        # Somebody dealt with it while the bridge was down. Touching that layer
        # now would take off whatever took its place.
        $script:OnAir = @{ 5 = @{ Key = 'Urgent'; Source = 'bridge' } }
        Write-TestPlaybackState -StartedAt (Get-Date).AddSeconds(-500)

        Restore-MojazPlayback | Should -BeFalse
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'does nothing at all when no run was in flight' {
        Restore-MojazPlayback | Should -BeFalse
        $script:MojazPlayback | Should -BeNullOrEmpty
    }

    It 'drops the file once it has been acted on, so it resumes only once' {
        Write-TestPlaybackState -StartedAt (Get-Date).AddSeconds(-500)
        Restore-MojazPlayback | Out-Null
        # The resume rewrites it only when the run continues; an ended one goes.
        Test-Path -LiteralPath (Get-MojazPlaybackFile) | Should -BeFalse
    }
}

Describe 'Choosing which design a bulletin plays on' {
    BeforeEach {
        Mock Send-TelegramMessage { $true }
        Mock Write-BridgeLog { }
        $config.Settings | Add-Member -NotePropertyName 'MojazMultiDesign' -NotePropertyValue $true -Force
        $script:MojazPlayback = $null
        $script:MojazDesignCache = @{}
        # Two designs: the news one, and a single-video report with no loop.
        $newsScene = Join-Path $TestDrive 'news.cintitle'
        $videoScene = Join-Path $TestDrive 'report.cintitle'
        Set-Content -LiteralPath $newsScene -Encoding utf8 -Value '<Scene LoopStartFrame="30" LoopEndFrame="1530"><Var Name="mojaz_img" Type="File" /><Var Name="title.Text" Type="String" /><Plate Size="525.38;291.61" File="${mojaz_img}" /><Text Size="400;81" Text="${title.Text}" /></Scene>'
        Set-Content -LiteralPath $videoScene -Encoding utf8 -Value '<Scene><Var Name="clip" Type="File" /><Plate Size="1920.00;1080.00" File="${clip}" /></Scene>'
        Mock Get-TemplateStore {
            @{
                Order = @('Mojaz', 'Mojaz-Report', 'Urgent')
                Map = @{
                    'Mojaz' = @{ Key = 'Mojaz'; Path = $newsScene; Layer = 5 }
                    'Mojaz-Report' = @{ Key = 'Mojaz-Report'; Path = $videoScene; Layer = 5; Bulletin = $true }
                    # Not a design: nobody marked it as one.
                    'Urgent' = @{ Key = 'Urgent'; Path = $newsScene; Layer = 7 }
                }
            }
        }
    }
    AfterAll { $config.Settings | Add-Member -NotePropertyName 'MojazMultiDesign' -NotePropertyValue $false -Force }

    It 'offers only the templates declared as designs' {
        $keys = @(Get-MojazDesigns).Key
        $keys | Should -Contain 'Mojaz'
        $keys | Should -Contain 'Mojaz-Report'
        # A loop and a text field do not make a template a bulletin design.
        $keys | Should -Not -Contain 'Urgent'
    }

    It 'reads each design its own fields, and says which can walk rows' {
        $designs = @(Get-MojazDesigns)
        $news = $designs | Where-Object Key -eq 'Mojaz'
        $report = $designs | Where-Object Key -eq 'Mojaz-Report'

        @($news.Fields).Count | Should -Be 2
        $news.SupportsRows | Should -BeTrue
        # One video, no loop: a single story, and it says so rather than
        # being refused.
        @($report.Fields).Count | Should -Be 1
        $report.Usable | Should -BeTrue
        $report.SupportsRows | Should -BeFalse
    }

    It 'keeps a design that cannot be read, with the reason' {
        Mock Get-TemplateStore {
            @{ Order = @('Mojaz-Gone'); Map = @{ 'Mojaz-Gone' = @{ Key = 'Mojaz-Gone'; Path = 'D:\nowhere\missing.cintitle'; Layer = 5; Bulletin = $true } } }
        }
        $design = @(Get-MojazDesigns)[0]
        $design.Usable | Should -BeFalse
        $design.Reason | Should -Match 'غير موجود'
    }

    It 'asks which design only when there is a choice to make' {
        Test-MojazDesignChoiceNeeded | Should -BeTrue

        # One design is not a choice.
        Mock Get-TemplateStore { @{ Order = @('Mojaz'); Map = @{ 'Mojaz' = @{ Key = 'Mojaz'; Path = (Join-Path $TestDrive 'news.cintitle'); Layer = 5 } } } }
        Test-MojazDesignChoiceNeeded | Should -BeFalse
    }

    It 'never asks while the option is off' {
        $config.Settings | Add-Member -NotePropertyName 'MojazMultiDesign' -NotePropertyValue $false -Force
        Test-MojazDesignChoiceNeeded | Should -BeFalse
        $config.Settings | Add-Member -NotePropertyName 'MojazMultiDesign' -NotePropertyValue $true -Force
    }

    It 'asks for the design before the name when creating' {
        Clear-PendingState -ChatId 100
        Start-MojazNamePrompt -Which new -ChatId 100 -UserId 101

        (Get-PendingState -ChatId 100).Mode | Should -Be 'mojaz_design_new'
        Should -Invoke Send-TelegramMessage -ParameterFilter {
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) -contains 'mojazdesign:Mojaz-Report'
        }
    }

    It 'refuses to swap the design of a bulletin that is on air' {
        # The rows being written would land in variables the new design has
        # never heard of.
        $script:MojazPlayback = @{ BulletinId = 'b_live' }
        Set-MojazBulletinDesign -BulletinId 'b_live' -TemplateKey 'Mojaz-Report' -ChatId 100 -UserId 101 | Should -BeFalse
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'على الهواء' }
    }

    It 'falls back to the built-in design for a bulletin that names none' {
        Get-MojazBulletinDesignKey -Bulletin ([pscustomobject]@{ Id = 'b_1' }) | Should -Be 'Mojaz'
        Get-MojazBulletinDesignKey -Bulletin ([pscustomobject]@{ Id = 'b_2'; TemplateKey = 'Mojaz-Report' }) | Should -Be 'Mojaz-Report'
    }
}

Describe 'What a row on a design is asked for' {
    BeforeEach {
        $script:MojazDesignCache = @{}
        $scene = Join-Path $TestDrive 'design.cintitle'
        # Declared in the scene in this order: picture, story, headline.
        Set-Content -LiteralPath $scene -Encoding utf8 -Value '<Scene LoopStartFrame="30" LoopEndFrame="1530"><Var Name="mojaz_img" Type="File" /><Var Name="Subject.Text" Type="String" /><Var Name="title.Text" Type="String" /><Var Name="orphan" Type="String" /><Plate Size="525.38;291.61" File="${mojaz_img}" /><Text Size="479;385" Text="${Subject.Text}" /><Text Size="400;81" Text="${title.Text}" /></Scene>'
        Mock Get-TemplateStore {
            @{
                Order = @('Mojaz')
                Map = @{ 'Mojaz' = @{
                        Key = 'Mojaz'; Path = $scene; Layer = 5
                        # The registry says the editorial order and the words.
                        Fields = @(
                            @{ Name = 'title.Text'; Label = 'العنوان' }
                            @{ Name = 'Subject.Text'; Label = 'الخبر' }
                        )
                    } }
            }
        }
    }

    It 'asks in the registry order, not the order the scene happens to declare' {
        # The scene lists the story before the headline; an editor writes the
        # headline first.
        @(Get-MojazRowFieldPrompts -TemplateKey 'Mojaz').Name |
            Should -Be @('title.Text', 'Subject.Text', 'mojaz_img')
    }

    It 'uses the registry wording and falls back to the variable name' {
        $prompts = @(Get-MojazRowFieldPrompts -TemplateKey 'Mojaz')
        ($prompts | Where-Object Name -eq 'title.Text').Label | Should -Be 'العنوان'
        # Nobody named the picture, so it is asked for by the only true name
        # available rather than by an invented one.
        ($prompts | Where-Object Name -eq 'mojaz_img').Label | Should -Be 'mojaz_img'
    }

    It 'leaves out a variable no element consumes' {
        # Filling it would put the value nowhere on screen.
        @(Get-MojazRowFieldPrompts -TemplateKey 'Mojaz').Name | Should -Not -Contain 'orphan'
    }

    It 'carries the media size the design was drawn for' {
        $picture = @(Get-MojazRowFieldPrompts -TemplateKey 'Mojaz') | Where-Object Name -eq 'mojaz_img'
        $picture.Kind | Should -Be 'media'
        $picture.Width | Should -Be 525
        $picture.Height | Should -Be 292
    }

    It 'reads a row written before designs existed' {
        # No field bag at all - the three properties it has always had. This
        # is what lets an old bulletin play on a design without a rewrite.
        $row = [pscustomobject]@{ Id = 'r_1'; Title = 'عنوان'; Text = 'خبر'; Image = 'D:\pics\a.png'; ImageMode = 'new' }
        Get-MojazRowFieldValue -Row $row -FieldName 'title.Text' | Should -Be 'عنوان'
        Get-MojazRowFieldValue -Row $row -FieldName 'Subject.Text' | Should -Be 'خبر'
        Get-MojazRowFieldValue -Row $row -FieldName 'mojaz_img' | Should -Be 'D:\pics\a.png'
    }

    It 'prefers the field bag when the row has one' {
        $row = [pscustomobject]@{
            Id = 'r_1'; Title = 'قديم'; Text = 'قديم'; Image = ''; ImageMode = 'inherit'
            Fields = [pscustomobject]@{ 'title.Text' = 'جديد'; 'source.Text' = 'وكالة' }
        }
        Get-MojazRowFieldValue -Row $row -FieldName 'title.Text' | Should -Be 'جديد'
        # A field this design does not ask for is still readable, so moving
        # the bulletin back finds it.
        Get-MojazRowFieldValue -Row $row -FieldName 'source.Text' | Should -Be 'وكالة'
        # And one nobody filled reads empty rather than throwing.
        Get-MojazRowFieldValue -Row $row -FieldName 'nothing' | Should -Be ''
    }

    It 'gives the whole row as the design sees it' {
        $row = [pscustomobject]@{ Id = 'r_1'; Title = 'عنوان'; Text = 'خبر'; Image = ''; ImageMode = 'inherit' }
        $values = Get-MojazRowValues -Row $row -TemplateKey 'Mojaz'
        @($values.Keys) | Should -Be @('title.Text', 'Subject.Text', 'mojaz_img')
        $values['title.Text'] | Should -Be 'عنوان'
    }
}

Describe 'Timing the bulletin from the engine rather than the bridge' {
    BeforeEach { Mock Write-BridgeLog { } }

    function global:New-TestLayerStatusXml {
        param([datetime]$StartedAtUtc, [switch]$NoSchedule)
        $item = if ($NoSchedule) { '<Item Id="{A}" />' }
        else { '<Item Id="{A}" LogId="{B}" ScheduledAt="' + $StartedAtUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + '" Duration="24:00:00.000" />' }
        [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{A}'; ActiveXml = $item }
    }

    It 'reads the moment the engine says the item went on air' {
        $started = [datetime]::UtcNow.AddSeconds(-3)
        Mock Get-TitlerLayerStatus { New-TestLayerStatusXml -StartedAtUtc $started }

        $read = Get-CinegyLayerStartedAtUtc -Layer 5
        $read | Should -Not -BeNullOrEmpty
        # Parsed as UTC, not reinterpreted as local: an hours-out anchor would
        # put every write outside the fade.
        [math]::Abs(($read - $started).TotalSeconds) | Should -BeLessThan 1
    }

    It 'says nothing when the engine gives no schedule' {
        Mock Get-TitlerLayerStatus { New-TestLayerStatusXml -StartedAtUtc ([datetime]::UtcNow) -NoSchedule }
        Get-CinegyLayerStartedAtUtc -Layer 5 | Should -BeNullOrEmpty

        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $false; ActiveXml = '' } }
        Get-CinegyLayerStartedAtUtc -Layer 5 | Should -BeNullOrEmpty
    }

    It 'turns a believable moment into the run offset' {
        $now = [datetime]::UtcNow
        Get-MojazAirClockOffset -StartedAtUtc $now.AddSeconds(-2) -Now $now | Should -BeGreaterThan 1.5
        Get-MojazAirClockOffset -StartedAtUtc $now.AddSeconds(-2) -Now $now | Should -BeLessThan 2.5
    }

    It 'refuses an anchor that cannot be this show' {
        $now = [datetime]::UtcNow
        # That layer has held something for an hour: it is not what was just
        # sent, and anchoring to it moves every write out of the fade.
        Get-MojazAirClockOffset -StartedAtUtc $now.AddHours(-1) -Now $now | Should -Be 0
        # And clocks that disagree about the present.
        Get-MojazAirClockOffset -StartedAtUtc $now.AddSeconds(30) -Now $now | Should -Be 0
        # And nothing at all.
        Get-MojazAirClockOffset -StartedAtUtc $null -Now $now | Should -Be 0
    }
}

Describe 'The timing anchor reports what it did' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        # This bridge has a Mojaz scene, which is what a bulletin plays on.
        # Without it Start-MojazPlayback reads (Get-MojazTemplate).Layer off
        # $null and throws under Set-StrictMode - and the SHOW below is mocked,
        # so nothing else in the setup notices the scene is missing. That is how
        # these tests have been red since the anchor landed in 8.19.0.
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'D:\cingy cg\mojaz.cintitle'; Layer = 5 } }
        Mock Write-AuditRecord {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Get-MojazSceneTiming { $null }
        Mock Write-BridgeLog { }
        $config.Settings | Add-Member -NotePropertyName 'MojazAnchorToAirClock' -NotePropertyValue $true -Force
        $script:MojazPlayback = $null
        New-TestMojazLibrary -DelaySeconds 4 -Rows @((New-TestMojazRow -Title 'أول'), (New-TestMojazRow -Title 'ثانٍ')) | Out-Null
    }
    AfterAll { $script:MojazPlayback = $null; Clear-MojazPlaybackState }

    It 'records the offset it applied when the engine gives a start moment' {
        # The engine says the scene began 600ms ago - the SHOW round trip -
        # so the run is timed from there and the log says so.
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{A}'
                ActiveXml = '<Item Id="{A}" LogId="{B}" ScheduledAt="' + [datetime]::UtcNow.AddMilliseconds(-600).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + '" />' }
        }

        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        [double]$script:MojazPlayback.ClockOffset | Should -BeGreaterThan 0.4
        [double]$script:MojazPlayback.ClockOffset | Should -BeLessThan 1.0
        Should -Invoke Write-BridgeLog -ParameterFilter { $Message -match "timed from Cinegy" }
    }

    It 'says plainly when it fell back to the local clock' {
        # Silence here is what made "anchored" and "fell back" look identical
        # from outside.
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{A}'; ActiveXml = '<Item Id="{A}" />' } }

        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        [double]$script:MojazPlayback.ClockOffset | Should -Be 0
        Should -Invoke Write-BridgeLog -ParameterFilter { $Message -match "timed from the bridge" }
    }

    It 'keeps the engine start with the run, so a restart can use it' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{A}'
                ActiveXml = '<Item Id="{A}" LogId="{B}" ScheduledAt="' + [datetime]::UtcNow.AddMilliseconds(-400).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + '" />' }
        }

        Start-MojazPlayback -ChatId 100 -UserId 101 | Out-Null

        [string]$script:MojazPlayback.AirStartedAt | Should -Not -BeNullOrEmpty
    }
}

Describe 'Warning when the row hold does not fit the scene loop' {
    # A live bulletin held every row 1500 frames against a 750-frame loop, so
    # each headline played twice and read on air as a bulletin stuck on one
    # item. Both numbers were already on the screen; nobody compared them.

    It 'says how many times a headline will repeat' {
        $note = Get-MojazLoopFitNote -DelayFrames 1500 -LoopFrames 750
        $note | Should -Match '2 أضعاف'
        $note | Should -Match '750'
    }

    It 'stays quiet when the hold is exactly one loop' {
        Get-MojazLoopFitNote -DelayFrames 750 -LoopFrames 750 | Should -BeNullOrEmpty
    }

    It 'allows a frame either side, because a hold typed in seconds lands there' {
        Get-MojazLoopFitNote -DelayFrames 751 -LoopFrames 750 | Should -BeNullOrEmpty
        Get-MojazLoopFitNote -DelayFrames 749 -LoopFrames 750 | Should -BeNullOrEmpty
    }

    It 'warns differently when the hold cuts the animation mid-way' {
        # Not a repeat count - there is no whole number of loops to report -
        # so the note has to name the other failure: a headline swapped while
        # the scene is still moving.
        $note = Get-MojazLoopFitNote -DelayFrames 1100 -LoopFrames 750
        $note | Should -Match 'منتصف الحركة'
        $note | Should -Not -Match 'أضعاف'
    }

    It 'says nothing when there is no timing to compare against' {
        Get-MojazLoopFitNote -DelayFrames 1500 -LoopFrames 0 | Should -BeNullOrEmpty
        Get-MojazLoopFitNote -DelayFrames 0 -LoopFrames 750 | Should -BeNullOrEmpty
    }

    It 'stays quiet for a bulletin that syncs to the loop' {
        # That setting takes its pace from the loop and cannot drift from it,
        # so the warning would be telling the operator to fix what is already
        # correct - the fastest way to teach them to ignore warnings.
        New-TestMojazLibrary -DelaySeconds 60 | Out-Null
        $bulletin = $script:MojazLibrary.Bulletins[0]
        Mock Get-MojazSceneTiming { [pscustomobject]@{ LoopFrames = 750; LoopSeconds = 30 } }

        # The bulletin object has no SyncToLoop until the setter adds it, so
        # the test turns the setting on the way the screen does.
        $synced = Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId ([string]$bulletin.Id) -SyncToLoop $true -UserId 1
        Get-MojazBulletinLoopFitNote -Bulletin $synced.Value.Bulletins[0] | Should -BeNullOrEmpty
        Get-MojazBulletinLoopFitNote -Bulletin $bulletin | Should -Match 'أضعاف'
    }
}

Describe 'Fixing the loop-fit warning from its own button (T-12)' {
    # A guidance message told the operator the exact fix - "اجعلها 750 إطارًا
    # أو فعّل مزامنة الظهور" - and left them to retype the number by hand.
    # The screen already knows the loop length; the button applies it.
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Get-MojazSceneTiming { [pscustomobject]@{ LoopFrames = 750; LoopSeconds = 30 } }
        $script:bulletin = New-TestMojazLibrary -DelaySeconds 60
    }

    It 'offers the quick-fix button beside the warning it answers' {
        $callbacks = @((Get-MojazKeyboard -Bulletin $script:bulletin).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $callbacks | Should -Contain 'mojaz:matchloop'
    }

    It 'names the exact frame count in the button label' {
        $button = @((Get-MojazKeyboard -Bulletin $script:bulletin).inline_keyboard | ForEach-Object { @($_) }) | Where-Object { $_.callback_data -eq 'mojaz:matchloop' }
        $button.text | Should -Match '750'
    }

    It 'does not offer the button once the hold already fits the loop' {
        # Set-MojazBulletinTiming hands back a candidate library; it only
        # becomes $script:MojazLibrary once Invoke-MojazEdit saves it. Reading
        # the candidate directly is the pattern the sync tests above already use.
        $result = Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId ([string]$script:bulletin.Id) -DelayFrames 750 -UserId 1
        $callbacks = @((Get-MojazKeyboard -Bulletin $result.Value.Bulletins[0]).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $callbacks | Should -Not -Contain 'mojaz:matchloop'
    }

    It 'does not offer the button once the bulletin syncs to the loop instead' {
        $result = Set-MojazBulletinTiming -Library $script:MojazLibrary -BulletinId ([string]$script:bulletin.Id) -SyncToLoop $true -UserId 1
        $callbacks = @((Get-MojazKeyboard -Bulletin $result.Value.Bulletins[0]).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $callbacks | Should -Not -Contain 'mojaz:matchloop'
    }

    It 'sets the delay to the loop length and clears the warning' {
        Set-MojazDelayToLoop -ChatId 100 -UserId 101

        $updated = Get-MojazSelected -ChatId 100
        Get-MojazDelayFrames -Bulletin $updated | Should -Be 750
        Get-MojazBulletinLoopFitNote -Bulletin $updated | Should -BeNullOrEmpty
    }

    It 'does nothing when there is no scene timing to read a loop length from' {
        Mock Get-MojazSceneTiming { $null }

        Set-MojazDelayToLoop -ChatId 100 -UserId 101

        Get-MojazDelayFrames -Bulletin (Get-MojazSelected -ChatId 100) | Should -Be 1500
    }
}

Describe 'A paged rundown keeps the operators place' {
    BeforeEach {
        $script:PagedRows = @(0..59 | ForEach-Object { [pscustomobject]@{ Id = "row-$_"; Title = "عنوان $_"; Text = "نصّ $_" } })
    }

    It 'finds the page a row sits on rather than always answering zero' {
        # The shape this was built for: every row-scoped action redrew at page
        # zero, which was invisible while the rundown was one page and became
        # a lost place the moment it was paged.
        Get-MojazRowPage -Rows $script:PagedRows -RowId 'row-0'  | Should -Be 0
        Get-MojazRowPage -Rows $script:PagedRows -RowId 'row-24' | Should -Be 0
        Get-MojazRowPage -Rows $script:PagedRows -RowId 'row-25' | Should -Be 1
        Get-MojazRowPage -Rows $script:PagedRows -RowId 'row-59' | Should -Be 2
    }

    It 'follows a row across the page boundary it was moved over' {
        # Row 24 is the last on page one; moving it down puts it on page two,
        # and the redraw has to go with it.
        Get-MojazRowPage -Rows $script:PagedRows -RowId 'row-25' | Should -Be 1
    }

    It 'lands beside the gap when the row it was given is gone' {
        # A delete names a row that no longer exists; the fallback is where it
        # was, not the top of a sixty-row table.
        Get-MojazRowPage -Rows $script:PagedRows -RowId 'row-deleted' -FallbackIndex 40 | Should -Be 1
    }

    It 'answers zero for an empty rundown instead of dividing by nothing' {
        Get-MojazRowPage -Rows @() -RowId 'row-0' | Should -Be 0
        Get-MojazRowPage -Rows $script:PagedRows -RowId '' | Should -Be 0
    }

    It 'clamps a fallback past the end rather than paging past the table' {
        Get-MojazRowPage -Rows $script:PagedRows -RowId '' -FallbackIndex 999 | Should -Be 2
    }
}

Describe 'A replacing SHOW takes the layer from the engine walking it' {
    <#
        Stop-MojazForLayer and Stop-UrgentBoardForLayer had exactly two callers
        in the whole tree - Invoke-HideLayer and Invoke-ExitLayer. Their own
        docstrings list "the hide button, an exit, hide-all" and a replacing
        SHOW is not among them, so the SHOW funnel stopped nothing unless the
        key was the urgent one.

        The cost was not the stale engine itself. The bulletin kept writing
        rows through the postbox - which is channel-wide and carries no layer -
        into a scene it no longer owned, and then at its planned end sent
        EXIT_SCENE_LOOP to that layer and pulled the REPLACING graphic off air
        minutes later, logged against the bulletin's operator, with nothing on
        any screen saying why.

        This drives the broken shape: a bulletin on layer 5, then a different
        template shown on layer 5.
    #>
    BeforeEach {
        $script:MojazPlayback = $null
        $registry = New-TempTemplateFile -Json @'
{
  "Mojaz": { "path": "C:\\mojaz.cintitle", "layer": 5, "order": 1 },
  "Guest": { "path": "C:\\guest.cintitle", "layer": 5, "order": 2 },
  "Other": { "path": "C:\\other.cintitle", "layer": 6, "order": 3 }
}
'@
        $script:TestRegistry = $registry
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Test-Admin { $true }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = ''; Error = '' } }
        Mock Update-OnAirStateFromCinegy { }
        Mock Get-CorrelatedLayerSnapshot { $null }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = ''; EventId = '{guid}'; Xml = '' } }
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = '' } }
        # The run-end bookkeeping is not what is under test here; Stop-MojazForLayer itself is.
        Mock Write-MojazRunEnd { }
        Mock Request-MojazTickerReturn { $false }
        Mock Send-TemplateAirNotice { }
    }
    AfterEach {
        $script:MojazPlayback = $null
        if ($script:TestRegistry) { Remove-Item $script:TestRegistry -Force -ErrorAction SilentlyContinue }
    }

    It 'stops the bulletin when another template claims its layer' {
        $script:MojazPlayback = @{ Index = 0; Plan = @(); ExitAtSeconds = 600; StartedAt = (Get-Date); ChatId = 100; UserId = 101; ScheduleId = '' }

        Invoke-ShowTemplateResult -Key 'Guest' -ChatId 100 -UserId 101 | Out-Null

        # Without the stop, this engine would still be armed - and would send
        # EXIT_SCENE_LOOP to layer 5 at its planned end, taking 'Guest' off air.
        $script:MojazPlayback | Should -BeNullOrEmpty
    }

    It 'leaves a bulletin on another layer running' {
        # The guard must answer "who owns THIS layer", not "is anything running".
        $script:MojazPlayback = @{ Index = 0; Plan = @(); ExitAtSeconds = 600; StartedAt = (Get-Date); ChatId = 100; UserId = 101; ScheduleId = '' }

        Invoke-ShowTemplateResult -Key 'Other' -ChatId 100 -UserId 101 | Out-Null

        $script:MojazPlayback | Should -Not -BeNullOrEmpty
    }

    It 'sends the replacing graphic anyway - the stop is not a refusal' {
        $script:MojazPlayback = @{ Index = 0; Plan = @(); ExitAtSeconds = 600; StartedAt = (Get-Date); ChatId = 100; UserId = 101; ScheduleId = '' }

        Invoke-ShowTemplateResult -Key 'Guest' -ChatId 100 -UserId 101 | Out-Null

        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly
    }
}

Describe 'A bulletin whose exit was never confirmed is frozen, not finished' {
    <#
        Stop-MojazPlayback sent its EXIT to Out-Null and deleted the state file
        BEFORE the attempt. So an unreachable Cinegy left the scene looping its
        last headline for ever - no engine behind it, no retry, and no file for
        a restart to recover from. The schedule said `completed`, the operator
        was told "خرج عن الهواء", and a second later the news strip came back on
        top of the frozen bulletin: the overlap the stand-down exists to avoid.

        The urgent board had solved this already (Set-UrgentRunStopFailed); the
        bulletin is the sibling that never got the fix.
    #>
    BeforeEach {
        $script:MojazPlayback = $null
        $script:MojazTickerReturn = $null
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-MojazRunEnd { }
        Mock Request-MojazTickerReturn { $false }
        Mock Show-MojazScreen { }
        Mock Update-MojazPendingUrgent { $true }
        Mock Write-BridgeValidatedJson { $true }
        Mock Get-MojazTemplate { @{ Key = 'Mojaz'; Path = 'C:\mojaz.cintitle'; Layer = 5 } }
        Mock Clear-MojazPlaybackState { $script:ClearedState = $true }
        $script:ClearedState = $false
    }
    AfterEach { $script:MojazPlayback = $null; $script:MojazTickerReturn = $null }

    It 'keeps the run and its state file when the exit is refused' {
        Mock Invoke-ExitLayer { $false }
        $script:MojazPlayback = @{ Index = 2; Rows = @(); Plan = @(); ExitAtSeconds = 60; ChatId = 100; UserId = 101; ScheduleId = ''; Clock = [System.Diagnostics.Stopwatch]::StartNew() }

        Stop-MojazPlayback -Quiet | Should -BeFalse

        # Erasing the run would strand the bulletin on air with nothing to retry.
        $script:MojazPlayback | Should -Not -BeNullOrEmpty
        [bool]$script:MojazPlayback.StopFailed | Should -BeTrue
        $script:ClearedState | Should -BeFalse
    }

    It 'does not recall the news strip over a scene that never left' {
        Mock Invoke-ExitLayer { $false }
        $script:MojazPlayback = @{ Index = 2; Rows = @(); Plan = @(); ExitAtSeconds = 60; ChatId = 100; UserId = 101; ScheduleId = ''; Clock = [System.Diagnostics.Stopwatch]::StartNew() }

        Stop-MojazPlayback -Quiet | Out-Null

        Should -Invoke Request-MojazTickerReturn -Times 0 -Exactly
    }

    It 'writes no completed schedule record for a run that did not end' {
        Mock Invoke-ExitLayer { $false }
        Mock Set-MojazScheduleStatus { $true }
        $script:MojazPlayback = @{ Index = 2; Rows = @(); Plan = @(); ExitAtSeconds = 60; ChatId = 100; UserId = 101; ScheduleId = 'sched-1'; Clock = [System.Diagnostics.Stopwatch]::StartNew() }

        Stop-MojazPlayback -Quiet | Out-Null

        Should -Invoke Set-MojazScheduleStatus -Times 0 -Exactly
    }

    It 'stops writing rows into a scene whose state nobody established' {
        # The frozen run stays in memory so its stop button still works, but the
        # engine may not guess at the scene by writing to it.
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        $script:MojazPlayback = @{
            Index = 0; Rows = @(1, 2); Plan = @(@{ AtSeconds = 0 }, @{ AtSeconds = 0 })
            ExitAtSeconds = 0; ChatId = 100; UserId = 101; ScheduleId = ''; StopFailed = $true
            Clock = [System.Diagnostics.Stopwatch]::StartNew(); ClockOffset = 999
        }

        Update-MojazPlayback

        Should -Invoke Send-PostboxValues -Times 0 -Exactly
    }

    It 'settles the run normally when the exit is confirmed' {
        Mock Invoke-ExitLayer { $true }
        $script:MojazPlayback = @{ Index = 2; Rows = @(); Plan = @(); ExitAtSeconds = 60; ChatId = 100; UserId = 101; ScheduleId = ''; Clock = [System.Diagnostics.Stopwatch]::StartNew() }

        Stop-MojazPlayback -Quiet | Should -BeTrue

        $script:MojazPlayback | Should -BeNullOrEmpty
        $script:ClearedState | Should -BeTrue
        Should -Invoke Request-MojazTickerReturn -Times 1 -Exactly
    }
}

Describe 'The promise to put the news strip back survives a restart' {
    <#
        Hide-MojazTicker recorded the promise in memory only. A restart during a
        bulletin resumed the run correctly and ended it correctly - and then
        Request-MojazTickerReturn found nothing to arm, so the strip, a
        permanent graphic the channel carries all day, stayed off air with
        nothing that would ever return it. The bridge reported a clean ending.
    #>
    It 'writes the ticker-return promise into the run state' {
        $script:MojazTickerReturn = @{ At = $null; ChatId = 100; UserId = 101 }
        $script:MojazPlayback = @{
            StartedAt = (Get-Date).ToString('o'); BulletinId = 'b1'; BulletinName = 'n'
            ChatId = 100; UserId = 101; ExitAtSeconds = 60; SyncToLoop = $false
            Rows = @(); Plan = @()
        }
        $captured = ''
        Mock Write-BridgeValidatedJson { $script:CapturedJson = $Json; $true }
        try {
            Save-MojazPlaybackState | Out-Null
            $captured = $script:CapturedJson
        }
        finally { $script:MojazPlayback = $null; $script:MojazTickerReturn = $null }

        ($captured | ConvertFrom-Json).TickerReturnChatId | Should -Be 100
    }
}

Describe 'Reading a scene''s fields for real' {
    <#
        Every other test that touches Get-MojazDesignFields mocks it, so its
        own body was covered by nothing - which is how it shipped unable to run
        at all (see the $script: declaration guard in Bridge.Tests.ps1). These
        two call it for real.

        They do NOT reproduce the original crash: under Pester the function's
        $script: scope is not the one StrictMode trips on, so the bug is
        invisible here however it is written. The structural guard is what
        catches that; this is coverage of the path itself.
    #>
    It 'answers for a scene whose file exists' {
        $scene = Join-Path $TestDrive 'design.cintitle'
        Set-Content -LiteralPath $scene -Value '<scene />' -Encoding UTF8
        # A pscustomobject, which is what ConvertFrom-Json gives the real
        # registry - a hashtable here makes Get-JsonProp answer empty and the
        # function returns before it reaches anything worth testing.
        Mock Get-TemplateStore { @{ Order = @('Design'); Map = @{ 'Design' = [pscustomobject]@{ Key = 'Design'; Path = $scene; Layer = 6 } } } }

        { Get-MojazDesignFields -TemplateKey 'Design' } | Should -Not -Throw
    }

    It 'answers the same on the second call, which is the cache doing its job' {
        $scene = Join-Path $TestDrive 'cached.cintitle'
        Set-Content -LiteralPath $scene -Value '<scene />' -Encoding UTF8
        Mock Get-TemplateStore { @{ Order = @('Design'); Map = @{ 'Design' = [pscustomobject]@{ Key = 'Design'; Path = $scene; Layer = 6 } } } }

        $first = @(Get-MojazDesignFields -TemplateKey 'Design')
        $second = @(Get-MojazDesignFields -TemplateKey 'Design')

        @($second).Count | Should -Be @($first).Count
    }

    It 'answers empty for a template whose scene file is not there' {
        Mock Get-TemplateStore { @{ Order = @('Gone'); Map = @{ 'Gone' = [pscustomobject]@{ Key = 'Gone'; Path = 'Z:
owhere\gone.cintitle'; Layer = 6 } } } }

        @(Get-MojazDesignFields -TemplateKey 'Gone') | Should -BeNullOrEmpty
    }
}

Describe 'The bulletin screen redraws in place' {
    <#
        None of the bulletin screens ever edited their message: every ⬆️ ⬇️
        🗑, every page, every sync toggle sent a new copy of a screen that is
        worked on for minutes at a time. And the library's pager shared the
        rows' prefix, so its next page opened the selected bulletin instead.
    #>
    BeforeEach {
        $script:RefreshTarget = $null
        $script:MojazPress = { param([string]$Data) [pscustomobject]@{ id = 'm'; from = [pscustomobject]@{ id = 101 }; data = $Data
                message = [pscustomobject]@{ message_id = 31; chat = [pscustomobject]@{ id = 101; type = 'private' } } } }
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-MojazAvailable { $true }
        Mock Move-MojazRow { $script:seenMojazTarget = $script:RefreshTarget }
        Mock Show-MojazLibraryScreen { $script:seenLibraryPage = $Page }
        Mock Show-MojazScreen { }
    }
    AfterEach { $script:RefreshTarget = $null }

    It 'marks the screen a row move was pressed on' {
        $script:seenMojazTarget = $null
        Invoke-CallbackQuery -CallbackQuery (& $script:MojazPress 'mojaz:up:r1')
        $script:seenMojazTarget.MessageId | Should -Be 31
    }

    It 'pages the library as the library, not as the open bulletin' {
        $script:seenLibraryPage = -1
        Invoke-CallbackQuery -CallbackQuery (& $script:MojazPress 'mojazlib:2')
        $script:seenLibraryPage | Should -Be 2
        Should -Invoke Show-MojazScreen -Times 0
    }

    It 'gives the library pager its own prefix' {
        $saved = $script:MojazLibrary
        try {
            $script:MojazLibrary = [pscustomobject]@{ Bulletins = @(1..30 | ForEach-Object { [pscustomobject]@{ Id = "b$_"; Name = "نشرة $_"; Rows = @() } }) }
            $data = @((Get-MojazLibraryKeyboard -Page 0).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
            @($data | Where-Object { $_ -like 'mojazpage:*' }) | Should -BeNullOrEmpty
            $data | Should -Contain 'mojazlib:1'
        }
        finally { $script:MojazLibrary = $saved }
    }
}

Describe 'The bulletin screens show a row sitting out' {
    BeforeEach {
        $script:RefreshTarget = $null
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-MojazAvailable { $true }
        Mock Switch-MojazRowSkip { $script:skipTarget = $script:RefreshTarget; $script:skipRow = $RowId }
    }

    It 'routes the pause button and redraws the row where it was pressed' {
        $script:skipTarget = $null
        Invoke-CallbackQuery -CallbackQuery ([pscustomobject]@{ id = 's'; from = [pscustomobject]@{ id = 101 }; data = 'mojaz:skip:r9'
                message = [pscustomobject]@{ message_id = 12; chat = [pscustomobject]@{ id = 101; type = 'private' } } })
        $script:skipRow | Should -Be 'r9'
        $script:skipTarget.MessageId | Should -Be 12
    }

    It 'marks a skipped row in the table and on its button' {
        $bulletin = [pscustomobject]@{ Id = 'b1'; Name = 'م'; Rows = @(
                [pscustomobject]@{ Id = 'r1'; Title = 'أ'; Text = 'خ'; Image = '' }
                [pscustomobject]@{ Id = 'r2'; Title = 'ب'; Text = 'خ'; Image = ''; Skipped = $true }) }
        (Get-MojazText -Bulletin $bulletin) | Should -Match '⏸ 2\.'
        $labels = @((Get-MojazKeyboard -Bulletin $bulletin).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['text'] })
        $labels | Should -Contain '⏸ 2'
        $labels | Should -Contain '✏️ 1'
    }
}

Describe 'Pasting rows into a bulletin' {
    BeforeEach {
        $script:MojazLibraryBackup = $script:MojazLibrary
        $lib = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'المسائي').Value
        $script:MojazLibrary = $lib
        $script:pasteBulletin = [string]$lib.Bulletins[0].Id
        $script:MojazSelections['101'] = $script:pasteBulletin
        Mock Save-MojazLibrary { $script:MojazLibrary = $Library; $true }
        Mock Send-TelegramMessage { }
        Mock Show-MojazScreen { }
        Mock Add-AuditEntry { }
        Clear-PendingState -ChatId 101
    }
    AfterEach { $script:MojazLibrary = $script:MojazLibraryBackup; Clear-PendingState -ChatId 101 }

    It 'adds nothing until the review is confirmed, then every row in order' {
        Start-MojazRowPaste -ChatId 101 -UserId 101
        Add-RowPasteChunk -ChatId 101 -UserId 101 -Value "أ | قصة أ`nب | قصة ب"
        @($script:MojazLibrary.Bulletins[0].Rows).Count | Should -Be 0
        Complete-RowPaste -ChatId 101 -UserId 101
        @($script:MojazLibrary.Bulletins[0].Rows | ForEach-Object { [string]$_.Title }) | Should -Be @('أ', 'ب')
        @($script:MojazLibrary.Bulletins[0].Rows | ForEach-Object { Get-MojazRowImageMode -Row $_ }) | Should -Be @('inherit', 'inherit')
    }

    It 'refuses a bulletin whose design names its own fields' {
        $script:MojazLibrary.Bulletins[0] | Add-Member -NotePropertyName TemplateKey -NotePropertyValue 'OtherDesign' -Force
        Start-MojazRowPaste -ChatId 101 -UserId 101
        Get-PendingState -ChatId 101 | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -eq (T 'mjz.pasteBuiltInOnly') }
    }

    It 'offers the paste button beside add' {
        $data = @((Get-MojazKeyboard -Bulletin $script:MojazLibrary.Bulletins[0]).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $data | Should -Contain 'mojaz:paste'
        $data | Should -Contain 'mojaz:add'
        $data | Should -Contain 'mojaz:delay'
    }
}
