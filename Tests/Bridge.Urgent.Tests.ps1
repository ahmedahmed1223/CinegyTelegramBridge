#requires -Version 7

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

function global:New-TestUrgentTemplate {
    <#
        A registry with an Urgent scene on layer 7, which is what makes the
        board available at all.

        The path is rooted through GetTempPath rather than written as C:\... :
        the registry drops any template whose path is not absolute, and a
        hard-coded Windows path makes every test in this file pass on the
        playout machine and fail everywhere else. The file need not exist - the
        scene timing is mocked in every test that reads it.
    #>
    param([int]$Layer = 7)
    New-TempTemplateFile -Json (@{
            Urgent = @{
                description = 'breaking'
                path        = (Join-Path ([System.IO.Path]::GetTempPath()) 'Urgent.cintitle')
                layer       = $Layer
                fields      = @('Headline.Text', 'Kicker.Text')
            }
        } | ConvertTo-Json -Depth 6) | Out-Null
}

function global:New-TestUrgentBoard {
    <# A board of three lines, table defaults, nothing selected. #>
    param([int]$Count = 3, [int]$IntervalSeconds = 10)
    $board = New-UrgentBoard
    # The table's own numbers are settings now, not fields on the file.
    $config.Settings | Add-Member -NotePropertyName 'UrgentBoardIntervalSeconds' -NotePropertyValue $IntervalSeconds -Force
    $config.Settings | Add-Member -NotePropertyName 'UrgentBoardRepeats' -NotePropertyValue 1 -Force
    $config.Settings | Add-Member -NotePropertyName 'UrgentBoardTotalSeconds' -NotePropertyValue 0 -Force
    $config.Settings | Add-Member -NotePropertyName 'UrgentBoardMode' -NotePropertyValue 'text' -Force
    $config.Settings | Add-Member -NotePropertyName 'UrgentBoardRepeatMode' -NotePropertyValue 'cycle' -Force
    for ($index = 1; $index -le $Count; $index++) {
        $board = (Add-UrgentItem -Board $board -Text "عاجل $index" -UserId 1).Value
    }
    $script:UrgentBoard = $board
    $script:UrgentSelections = @{}
    $script:UrgentBoardRun = $null
    $script:UrgentBoardStarting = $false
    return $board
}

function global:Step-TestUrgentRun {
    <# Wait out the next moment without waiting: the run measures itself
       with a stopwatch, and ClockOffset is there so a test can move time
       instead of sleeping through it. #>
    $index = [int]$script:UrgentBoardRun.Step
    $steps = @($script:UrgentBoardRun.Steps)
    $moment = if ($index -ge ($steps.Count - 1)) {
        [double]$script:UrgentBoardRun.ExitAtSeconds
    }
    else { [double]$steps[$index + 1].AtSeconds }
    $script:UrgentBoardRun.ClockOffset = $moment + 1
    Update-UrgentBoardRun
}

Describe 'The breaking-news board and the fixed urgent template' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Edit-TelegramMessageText { $true }
        Mock Add-AuditEntry {}
        Mock Get-MojazSceneTiming { $null }
        New-TestUrgentTemplate
        New-TestUrgentBoard | Out-Null
        $config.Settings | Add-Member -NotePropertyName 'EnableUrgentBoard' -NotePropertyValue $true -Force
    }
    AfterEach { $script:UrgentBoardRun = $null }

    It 'offers its button only where the scene exists and the newsroom asked for it' {
        $on = ConvertTo-Json (Get-MainMenuKeyboard -ChatId 100 -UserId 100) -Depth 8
        $config.Settings | Add-Member -NotePropertyName 'EnableUrgentBoard' -NotePropertyValue $false -Force
        $off = ConvertTo-Json (Get-MainMenuKeyboard -ChatId 100 -UserId 100) -Depth 8

        $on | Should -Match 'urgmenu:open'
        $off | Should -Not -Match 'urgmenu:open'
    }

    It 'sends a fresh board when entered from the menu, even with an older board on record' {
        $script:UrgentHomeMessage[[long]100] = 55
        $script:RefreshTarget = @{ ChatId = 100; MessageId = 55 }
        Mock Send-TelegramRichMessage { $script:LastTelegramMessageId = 77; $true }
        Mock Edit-TelegramRichMessage { $true }
        Mock Edit-TelegramMessageText { $true }
        try {
            Show-UrgentBoardScreen -ChatId 100 -UserId 100 -Fresh
            Should -Invoke Edit-TelegramRichMessage -Times 0 -Exactly
            Should -Invoke Edit-TelegramMessageText -Times 0 -Exactly
            Should -Invoke Send-TelegramRichMessage -Times 1 -Exactly
            $script:UrgentHomeMessage[[long]100] | Should -Be 77 -Because 'the fresh screen is the one the chat works on now'
            $script:RefreshTarget | Should -BeNullOrEmpty
        }
        finally { $script:UrgentHomeMessage.Clear(); $script:RefreshTarget = $null }
    }

    It 'clears the previous kicker when the next story has no title' {
        $values = Get-UrgentItemVariables -Item $script:UrgentBoard.Items[0]
        $values.ContainsKey('Kicker.Text') | Should -BeTrue
        $values['Kicker.Text'] | Should -Be ''
    }

    It 'shows a disabled line as disabled on the fallback text too' {
        $id = [string]$script:UrgentBoard.Items[0].Id
        $script:UrgentBoard = (Set-UrgentItem -Board $script:UrgentBoard -ItemId $id -Field Enabled -Value $false).Value
        Get-UrgentBoardText -ChatId 100 | Should -Match '⛔'
    }

    It 'leaves the fixed urgent template exactly where it was' {
        # The board is a second consumer of this scene, not a replacement. With
        # the board switched off the old path must still be the same call it
        # always was.
        $config.Settings | Add-Member -NotePropertyName 'EnableUrgentBoard' -NotePropertyValue $false -Force
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = ''; Error = '' } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true; EventId = '{x}' } }
        Mock Update-OnAirStateFromCinegy { }

        Invoke-ShowTemplateResult -Key 'Urgent' -Variables @{ 'Headline.Text' = 'خبر' } -ChatId 100 -UserId 100 | Out-Null

        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly
    }

    It 'primes the postbox before SHOW on the ordinary pipeline too' {
        $script:AirOrder = @()
        $config.Settings | Add-Member -NotePropertyName 'SetValuesAfterShow' -NotePropertyValue $true -Force
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = ''; Error = '' } }
        Mock Send-PostboxValues { $script:AirOrder += 'postbox'; [pscustomobject]@{ Success = $true; Xml = ''; Error = '' } }
        Mock Show-TitlerTemplate { $script:AirOrder += 'show'; [pscustomobject]@{ Success = $true; EventId = '{x}' } }
        Mock Update-OnAirStateFromCinegy { }

        Invoke-ShowTemplateResult -Key 'Urgent' -Variables @{ 'Headline.Text' = 'خبر' } -ChatId 100 -UserId 100 | Out-Null

        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly
        @($script:AirOrder)[0] | Should -Be 'postbox' -Because 'the previous story must be gone from the postbox before the scene loads'
    }

    It 'pages the board keyboard rather than growing one row per line' {
        New-TestUrgentBoard -Count 30 | Out-Null

        $rows = @((Get-UrgentBoardKeyboard -ChatId 100).inline_keyboard)

        # Every row is a row: a flattened cell would mean the comma before the
        # row was lost, and Telegram answers that with 400.
        foreach ($row in $rows) { , $row | Should -BeOfType [System.Object[]] }
        # Mojaz-style layout: story text on its own row + action buttons below = 2 rows per story
        # With page size 10 that's 20 story rows + nav + controls = ~26 rows
        $rows.Count | Should -BeLessThan 35
        (ConvertTo-Json $rows -Depth 8) | Should -Match 'urgentb:page:1'
        # Each story spans two rows: text row (pick) + action row (read/actions)
        $storyTextRows = @($rows | Where-Object { @($_ | ForEach-Object { $_['callback_data'] }) -like 'urgentb:pick:*' })
        $actionRows = @($rows | Where-Object { @($_ | ForEach-Object { $_['callback_data'] }) -like 'urgread:*' })
        $storyTextRows.Count | Should -Be $actionRows.Count
    }

    It 'numbers the table with the same numbers as the buttons on that page' {
        # The keyboard pages and the table did not, so page two listed the
        # buttons for lines 9-16 above a table that still started at line 1.
        # Every number an operator reads would have pointed at the wrong line.
        New-TestUrgentBoard -Count 20 | Out-Null
        $size = Get-UrgentBoardPageSize
        $first = $size + 1

        $text = Get-UrgentBoardText -ChatId 100 -Page 1
        $keyboard = ConvertTo-Json (Get-UrgentBoardKeyboard -ChatId 100 -Page 1) -Depth 8

        $text | Should -Match "$first\. ✏️ عاجل $first"
        $text | Should -Not -Match 'عاجل 1 —'
        $keyboard | Should -Match "$first\. عاجل $first" 
    }

    It 'keeps one chat''s ticks out of another chat''s run' {
        # Selection is an operator's act, not a property of the shared table.
        $items = @($script:UrgentBoard.Items)
        Set-UrgentSelectedIds -ChatId 100 -Ids @([string]$items[0].Id)
        Set-UrgentSelectedIds -ChatId 200 -Ids @([string]$items[1].Id, [string]$items[2].Id)

        @(Get-UrgentSelectedIds -ChatId 100).Count | Should -Be 1
        @(Get-UrgentSelectedIds -ChatId 200).Count | Should -Be 2
        @(New-UrgentBoardPlan -ChatId 200 -SelectedOnly).Value.ItemCount | Should -Be 2
    }

    It 'forgets a tick whose line has been deleted' {
        $items = @($script:UrgentBoard.Items)
        Set-UrgentSelectedIds -ChatId 100 -Ids @([string]$items[0].Id, [string]$items[1].Id)
        $script:UrgentBoard = (Remove-UrgentItem -Board $script:UrgentBoard -ItemId ([string]$items[0].Id)).Value

        @(Get-UrgentSelectedIds -ChatId 100).Count | Should -Be 1
    }

    It 'recovers the backup file when the primary is missing' {
        Mock Write-BridgeLog {}
        $script:UrgentBoard = (Set-UrgentItem -Board $script:UrgentBoard -ItemId ([string]$script:UrgentBoard.Items[0].Id) -Field Text -Value 'من النسخة الاحتياطية').Value
        $backupPath = Join-Path $TestDrive 'backup-only.json'
        Mock Get-UrgentBoardFile { Join-Path $TestDrive 'backup-only.json' }
        Set-Content -LiteralPath "$backupPath.bak" -Value ($script:UrgentBoard | ConvertTo-Json -Depth 20) -Encoding utf8

        Import-UrgentBoard

        @($script:UrgentBoard.Items)[0].Text | Should -Be 'من النسخة الاحتياطية'
    }

    It 'refuses a well-formed file that is not a board' {
        Mock Write-BridgeLog {}
        Set-Content -LiteralPath (Get-UrgentBoardFile) -Value '{"unexpected":true}' -Encoding utf8

        Import-UrgentBoard

        @($script:UrgentBoard.Items).Count | Should -Be 0
        Should -Invoke Write-BridgeLog -ParameterFilter { $Level -eq 'WARN' }
    }
}

Describe 'Running the breaking-news board' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Edit-TelegramMessageText { $true }
        Mock Add-AuditEntry {}
        Mock Write-AuditRecord {}
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-ExitLayer { $true }
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $true; Xml = '' } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true } }
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $true } }
        Mock Get-MojazSceneTiming { $null }
        New-TestUrgentTemplate
        New-TestUrgentBoard -Count 3 -IntervalSeconds 10 | Out-Null
        $config.Settings | Add-Member -NotePropertyName 'EnableUrgentBoard' -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName 'SensitiveTemplateKeys' -NotePropertyValue '' -Force
        $script:MojazPlayback = $null
    }
    AfterEach { $script:UrgentBoardRun = $null; $script:MojazPlayback = $null }

    It 'works the board on one message: a typed reply comes back to the screen it left' {
        $script:UrgentHomeMessage.Clear()
        Mock Send-TelegramRichMessage { $script:LastTelegramMessageId = 55; $true }
        Mock Edit-TelegramRichMessage { $true }
        try {
            Show-UrgentBoardScreen -ChatId 100 -UserId 101
            $script:UrgentHomeMessage[[long]100] | Should -Be 55

            # No message id in hand - the way Complete-UrgentBoardText calls it
            # after a typed story - and still the same message is redrawn.
            Show-UrgentBoardScreen -ChatId 100 -UserId 101
            Should -Invoke Edit-TelegramRichMessage -Times 1 -Exactly -ParameterFilter { $MessageId -eq 55 }
            Should -Invoke Send-TelegramRichMessage -Times 1 -Exactly

            Show-UrgentItemScreen -ChatId 100 -Position 0
            Should -Invoke Edit-TelegramMessageText -Times 1 -ParameterFilter { $MessageId -eq 55 }
            Should -Invoke Send-TelegramMessage -Times 0 -Exactly

            # Every urgent button rides the refresh mark, so its answer edits the pressed message.
            Test-RedrawInPlacePress -Data 'urgentb:add' | Should -BeTrue
            Test-RedrawInPlacePress -Data 'urgsingle:u_0000000a:t' | Should -BeTrue
            Test-RedrawInPlacePress -Data 'menu:main' | Should -BeFalse
        }
        finally { $script:UrgentHomeMessage.Clear() }
    }

    It 'answers a hide from the board with one redraw that says so' {
        Mock Test-Authorized { $true }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserNameFromTelegram {}
        Mock Update-UserLastActivity {}
        Mock Stop-UrgentCurrentAir { $true }
        Mock Show-UrgentBoardScreen {}
        $q = @{ id='h'; from=@{ id=101 }; message=@{ message_id=9; chat=@{ id=100; type='private' } }; data='urgentb:hide' }

        Invoke-CallbackQuery $q

        Should -Invoke Stop-UrgentCurrentAir -Times 1 -Exactly -ParameterFilter { $Quiet }
        Should -Invoke Show-UrgentBoardScreen -Times 1 -Exactly -ParameterFilter { $MessageId -eq 9 -and $Notice -eq (T 'urgent.hiddenByYou') }
    }

    It 'records a new rich message as home only when the send reported an id' {
        $script:UrgentHomeMessage.Clear()
        $script:LastTelegramMessageId = 999
        Mock Send-TelegramRichMessage { $true }
        try {
            Show-UrgentBoardScreen -ChatId 100 -UserId 101
            $script:UrgentHomeMessage.ContainsKey([long]100) | Should -BeFalse -Because 'a stale id must never aim a later edit at another message'
        }
        finally { $script:UrgentHomeMessage.Clear(); $script:LastTelegramMessageId = 0 }
    }

    It 'takes a story added mid-run onto the end of the run, and plays it' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        $before = @($script:UrgentBoardRun.Steps).Count
        $exitBefore = [double]$script:UrgentBoardRun.ExitAtSeconds
        $added = (Add-UrgentItem -Board $script:UrgentBoard -Text 'عاجل جديد' -UserId 101).Value
        $script:UrgentBoard = $added
        $item = @($added.Items)[-1]

        Add-UrgentRunStep -Item $item | Should -Be ($before + 1)

        $steps = @($script:UrgentBoardRun.Steps)
        $steps.Count | Should -Be ($before + 1)
        $steps[-1].Text | Should -Be 'عاجل جديد'
        $steps[-1].AtSeconds | Should -Be $exitBefore -Because 'it starts where the run used to end'
        [double]$script:UrgentBoardRun.ExitAtSeconds | Should -BeGreaterThan $exitBefore
        (Get-UrgentRunStatusText) | Should -Match "من $($before + 1)"

        # A hand-picked run does not grow by itself.
        $script:UrgentBoardRun.Scope = 'selected'
        Add-UrgentRunStep -Item $item | Should -Be 0
    }

    It 'plays in the order the newest-first view shows' {
        $items = @($script:UrgentBoard.Items)
        $items[0].UpdatedAt = (Get-Date).AddMinutes(-30).ToString('o')
        $items[1].UpdatedAt = (Get-Date).AddMinutes(-10).ToString('o')
        $items[2].UpdatedAt = (Get-Date).ToString('o')
        Set-UrgentBoardFilter -ChatId 100 -Filter 'latest' | Out-Null
        try {
            $plan = (New-UrgentBoardPlan -ChatId 100).Value
            @($plan.Steps | ForEach-Object { $_.Text }) | Should -Be @('عاجل 3', 'عاجل 2', 'عاجل 1')
        }
        finally { Set-UrgentBoardFilter -ChatId 100 -Filter 'all' | Out-Null }
    }

    It 'sends the next line before moving the skip pointer' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Move-UrgentBoardNext -ChatId 100 | Should -BeTrue
        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly -ParameterFilter { $Variables['Headline.Text'] -eq 'عاجل 2' }
        $script:UrgentBoardRun.Step | Should -Be 1
        (Get-UrgentElapsedSeconds) | Should -BeLessThan 11
    }

    It 'pauses from the button without hiding and resumes the frozen clock' {
        Mock Confirm-TelegramCallback {}
        Mock Update-UserNameFromTelegram {}
        Mock Update-UserLastActivity {}
        Mock Test-Authorized { $true }
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Invoke-TestUrgentNumberCallback -Data 'urgentb:pause'
        $script:UrgentBoardRun.Clock.IsRunning | Should -BeFalse
        Get-UrgentBoardText -ChatId 100 | Should -Match 'متوقف مؤقتًا'
        Step-TestUrgentRun
        $script:UrgentBoardRun.Step | Should -Be 0
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
        Invoke-TestUrgentNumberCallback -Data 'urgentb:resume'
        $script:UrgentBoardRun.Clock.IsRunning | Should -BeTrue
        Step-TestUrgentRun
        $script:UrgentBoardRun.Step | Should -Be 1
    }

    It 'refuses playback controls when template access is denied' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Mock Test-TemplateAccess { @{ Allowed = $false; Reason = 'ممنوع' } }
        Move-UrgentBoardNext -ChatId 100 -UserId 102 | Should -BeFalse
        Suspend-UrgentBoardRun -ChatId 100 -UserId 102 | Should -BeFalse
        Resume-UrgentBoardRun -ChatId 100 -UserId 102 | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
        $script:UrgentBoardRun.Step | Should -Be 0
    }

    It 'stops on the last skipped line without showing anything else' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        $script:UrgentBoardRun.Step = 2
        Move-UrgentBoardNext -ChatId 100 -UserId 101 | Should -BeTrue
        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'does not claim a failed skip was displayed' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Mock Show-TitlerTemplate { @{ Success = $false; Error = 'offline' } }
        Move-UrgentBoardNext -ChatId 100 -UserId 101 | Should -BeFalse
        $script:UrgentBoardRun | Should -BeNullOrEmpty
    }

    It 'keeps a failed stop paused and available for another stop attempt' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Mock Invoke-ExitLayer { $false }
        Stop-UrgentBoardRun -ChatId 100 -UserId 101 -Quiet | Should -BeFalse
        $script:UrgentBoardRun | Should -Not -BeNullOrEmpty
        $script:UrgentBoardRun.Clock.IsRunning | Should -BeFalse
        Step-TestUrgentRun
        Should -Invoke Send-PostboxValues -Times 0 -Exactly
    }

    It 'does not resume or skip after an unconfirmed exit' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Mock Invoke-ExitLayer { $false }
        Stop-UrgentBoardRun -ChatId 100 -UserId 101 -Quiet | Out-Null
        Resume-UrgentBoardRun -ChatId 100 -UserId 101 | Should -BeFalse
        Move-UrgentBoardNext -ChatId 100 -UserId 101 | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'puts the first line up through the ordinary pipeline' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Should -BeTrue

        # Not a direct SHOW: maintenance mode, the layer policy, the live
        # Cinegy check and the audit trail all live on that path.
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        [int]$script:UrgentBoardRun.Step | Should -Be 0
        @($script:UrgentBoardRun.Steps).Count | Should -Be 3
    }

    It 'does not stop itself with the show that starts it' {
        # The rule "a manual urgent stops a running board" reads the same
        # template key this SHOW carries. Without the starting flag the board
        # would kill itself the instant it reached air - and only after it was
        # already on air, leaving a line up with no engine behind it.
        #
        # The mock re-enters the way the real SHOW funnel does. Asserting only
        # on the flag's value after the run made this pass with the guard
        # deleted: Invoke-ShowTemplateResult is mocked for this Describe, so
        # Stop-UrgentBoardForManualUrgent was never reached and the flag was
        # never read. That is the 8.27.0 pattern AGENTS.md names - a guard
        # tested on a state, just not the one it was written for.
        Mock Invoke-ShowTemplateResult {
            $script:SelfStopAnswer = Stop-UrgentBoardForManualUrgent -ChatId 100 -UserId 101
            [pscustomobject]@{ Success = $true }
        }
        $script:SelfStopAnswer = $null

        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Should -BeTrue

        # The opening SHOW asked the board to stand down and was refused.
        $script:SelfStopAnswer | Should -BeFalse
        $script:UrgentBoardRun | Should -Not -BeNullOrEmpty
        $script:UrgentBoardStarting | Should -BeFalse
    }

    It 'stands down when somebody sends a single urgent over it' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null

        Stop-UrgentBoardForManualUrgent -ChatId 100 -UserId 102 | Should -BeTrue

        $script:UrgentBoardRun | Should -BeNullOrEmpty
        # Told, not silent: a table that stopped without a word reads as a
        # table that finished.
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -like '*توقّف جدول العواجل*' }
        # The caller is putting its own graphic up; exiting here would play an
        # outro over it.
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'ends when its layer is taken off air by something else' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null

        Stop-UrgentBoardForLayer -Layer 7 | Should -BeTrue

        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'ignores a layer that is not its own' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null

        Stop-UrgentBoardForLayer -Layer 4 | Should -BeFalse

        $script:UrgentBoardRun | Should -Not -BeNullOrEmpty
    }

    It 'primes the postbox with the line before its scene loads' {
        $script:AirOrder = @()
        Mock Send-PostboxValues { $script:AirOrder += 'postbox'; [pscustomobject]@{ Success = $true; Xml = ''; Error = '' } }
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Show-TitlerTemplate { $script:AirOrder += 'show'; [pscustomobject]@{ Success = $true; Error = ''; EventId = 'e' } }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{NEW}'; ActiveDurationSeconds = 86400; ActiveManualEnd = $true; Error = '' } }
        Mock Update-OnAirStateFromCinegy { }
        Mock Write-BridgeLog { }
        $config.Settings | Add-Member SetValuesAfterShow $true -Force
        $script:PostShowQueue.Clear()
        try {
            Show-UrgentBoardScene -Template (Get-UrgentTemplate) -Values @{ Text = 'الخبر الثاني' } | Out-Null
            $script:AirOrder | Should -Be @('postbox', 'show') -Because 'the scene initialises from what the postbox already holds'
        }
        finally { $script:PostShowQueue.Clear(); $script:OnAir.Remove(7) }
    }

    It 'writes every re-shown line through the postbox and moves the record to the new item' {
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = ''; EventId = 'e' } }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{NEW}'; ActiveDurationSeconds = 86400; ActiveManualEnd = $true; Error = '' } }
        Mock Write-BridgeLog { }
        $config.Settings | Add-Member SetValuesAfterShow $true -Force
        $script:PostShowQueue.Clear()
        $script:OnAir[7] = @{ Key = $script:MojazUrgentKey; At = (Get-Date); UserId = 101; ActiveId = '{FIRST}'; Source = 'bridge' }
        try {
            $shown = Show-UrgentBoardScene -Template (Get-UrgentTemplate) -Values @{ Text = 'الخبر الثاني' }

            $shown.Success | Should -BeTrue
            $script:OnAir[7].ActiveId | Should -Be '{NEW}' -Because 'the watchdog must expect the item the engine made for this line'
            $script:PostShowQueue.Count | Should -Be 1 -Because 'the scene honours the postbox, not SHOW variables'
            $script:PostShowQueue[0].ActiveId | Should -Be '{NEW}'
            $script:PostShowQueue[0].Values.Text | Should -Be 'الخبر الثاني'
        }
        finally { $script:PostShowQueue.Clear(); $script:OnAir.Remove(7) }
    }

    It 'confirms a manual stop on the pressed message' {
        Mock Invoke-ExitLayer { $true }
        Mock Edit-TelegramRichMessage { $script:StopBlocks = $Blocks; $true }
        $script:StopBlocks = $null
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null

        Stop-UrgentBoardRun -ChatId 100 -UserId 101 -Reason 'manual' -MessageId 9 | Should -BeTrue

        Should -Invoke Edit-TelegramRichMessage -Times 1 -ParameterFilter { $MessageId -eq 9 }
        @($script:StopBlocks)[0].text | Should -Be (T 'urgp.stoppedByYou')
        $script:UrgentBoardRun | Should -BeNullOrEmpty
    }

    It 'puts the current line back once when its layer goes empty mid-run, then gives up' {
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = ''; EventId = 'e' } }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{BACK}'; ActiveDurationSeconds = 86400; ActiveManualEnd = $true; Error = '' } }
        Mock Write-BridgeLog { }
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        $line = [string](Get-JsonProp @($script:UrgentBoardRun.Steps)[0] 'Text')

        Restore-UrgentBoardLine -Layer 7 | Should -Be '{BACK}'

        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly -ParameterFilter { $Layer -eq 7 -and ($Variables.Values -contains $line) }
        $script:UrgentBoardRun | Should -Not -BeNullOrEmpty -Because 'the run keeps its clock'
        Should -Invoke Write-BridgeLog -Times 1 -ParameterFilter { $Message -like '*went empty during line 1 of*put back as item {BACK}*' }

        # The same line emptied again: leave it, so the run ends as before.
        Restore-UrgentBoardLine -Layer 7 | Should -Be ''
        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly
        Restore-UrgentBoardLine -Layer 4 | Should -Be ''
    }

    It 'writes a text-mode line into the running scene and never shows it again' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Step-TestUrgentRun

        Should -Invoke Send-PostboxValues -Times 1 -Exactly
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        Should -Invoke Exit-TitlerScene -Times 0 -Exactly
        [int]$script:UrgentBoardRun.Step | Should -Be 1
    }

    It 'hides an auto-hide line at its deadline even when the next line uses text mode' {
        $id = [string]$script:UrgentBoard.Items[0].Id
        $edited = Set-UrgentItem -Board $script:UrgentBoard -ItemId $id -Field Mode -Value 'auto_hide'
        $edited.Success | Should -BeTrue
        $script:UrgentBoard = $edited.Value
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Should -BeTrue
        Step-TestUrgentRun
        Should -Invoke Exit-TitlerScene -Times 1 -Exactly
        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly -ParameterFilter { $Variables['Headline.Text'] -eq 'عاجل 2' }
        # Not the text-mode path: the one postbox write is the pre-show prime of the new line (8.71.8).
        Should -Invoke Send-PostboxValues -Times 1 -Exactly -ParameterFilter { $Values['Headline.Text'] -eq 'عاجل 2' }
    }

    It 'takes an exit-mode line out and brings it back' {
        $items = @($script:UrgentBoard.Items)
        $script:UrgentBoard = (Set-UrgentItem -Board $script:UrgentBoard -ItemId ([string]$items[1].Id) -Field Mode -Value 'exit').Value

        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Step-TestUrgentRun

        Should -Invoke Exit-TitlerScene -Times 1 -Exactly
        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly
        Should -Invoke Send-PostboxValues -Times 1 -Exactly -ParameterFilter { $Values['Headline.Text'] -eq 'عاجل 2' }
    }

    It 'stops at the first failed line instead of walking a table nobody can see' {
        Mock Send-PostboxValues { [pscustomobject]@{ Success = $false; Error = 'لا اتصال'; Xml = '' } }
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null

        Step-TestUrgentRun

        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -like '*توقّف جدول العواجل عند الخطوة 2*لا اتصال*' }
    }

    It 'exits at the end of the run and says so once' {
        # No board message on record from an earlier test, so the notice
        # arrives as a send rather than an edit of message 9.
        $script:UrgentHomeMessage.Clear()
        $config.Settings | Add-Member -NotePropertyName 'UrgentBoardNotifyOnFinish' -NotePropertyValue $true -Force
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null
        Step-TestUrgentRun
        Step-TestUrgentRun
        Step-TestUrgentRun

        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -like '*انتهى جدول العواجل*' }
    }

    It 'refuses to start a second run on top of the first' {
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null

        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Should -BeFalse

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
    }

    It 'refuses to start underneath a running bulletin' {
        $script:MojazPlayback = @{ ChatId = 100 }

        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Should -BeFalse

        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'keeps the long poll at one second while a run is live' {
        # The engine is timed in tenths of a second. Without this the tick that
        # drives it would be called up to thirty seconds late, every window
        # would be missed, and every unit test would still pass.
        Start-UrgentBoardRun -ChatId 100 -UserId 101 | Out-Null

        Test-AirRunActive | Should -BeTrue
        Get-EffectivePollTimeout | Should -Be 1
    }
}

Describe 'What can cut a board run short' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        Mock Get-MojazSceneTiming { $null }
        New-TestUrgentTemplate
        New-TestUrgentBoard -Count 2 -IntervalSeconds 10 | Out-Null
        $config.Settings | Add-Member -NotePropertyName 'EnableUrgentBoard' -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName 'SensitiveTemplateKeys' -NotePropertyValue '' -Force
    }

    It 'treats the forced hide of a sensitive template as the ceiling on the whole run' {
        # Listing Urgent as sensitive is a reasonable thing for a newsroom to
        # do, and it means every SHOW of it carries a timer. A board that
        # ignored it would keep writing lines into a scene that had been hidden
        # underneath it, with nothing on any screen saying so.
        $config.Settings | Add-Member -NotePropertyName 'SensitiveTemplateKeys' -NotePropertyValue 'Urgent' -Force
        $config.Settings | Add-Member -NotePropertyName 'SensitiveTemplateAutoHideSeconds' -NotePropertyValue 45 -Force
        $config.Settings | Add-Member -NotePropertyName 'UrgentBoardRepeats' -NotePropertyValue 5 -Force

        $ceiling = Get-UrgentRunCeiling -Items @($script:UrgentBoard.Items)
        $plan = New-UrgentBoardPlan -ChatId 100

        $ceiling.Reason | Should -Be 'autohide'
        $ceiling.Seconds | Should -Be 45
        $plan.Value.Cycles | Should -Be 2
        $plan.Value.TrimmedBy | Should -Be 'autohide'
        @($plan.Value.Notes) -join ' ' | Should -Match 'الإخفاء التلقائي'
    }

    It 'refuses the run outright when not even one pass fits under that hide' {
        $config.Settings | Add-Member -NotePropertyName 'SensitiveTemplateKeys' -NotePropertyValue 'Urgent' -Force
        $config.Settings | Add-Member -NotePropertyName 'SensitiveTemplateAutoHideSeconds' -NotePropertyValue 5 -Force

        $plan = New-UrgentBoardPlan -ChatId 100

        $plan.Success | Should -BeFalse
        $plan.ErrorCode | Should -Be 'no_fit'
    }

    It 'takes the operator''s own total when it is the shorter of the two' {
        $config.Settings | Add-Member -NotePropertyName 'SensitiveTemplateKeys' -NotePropertyValue 'Urgent' -Force
        $config.Settings | Add-Member -NotePropertyName 'SensitiveTemplateAutoHideSeconds' -NotePropertyValue 300 -Force
        $config.Settings | Add-Member -NotePropertyName 'UrgentBoardTotalSeconds' -NotePropertyValue 60 -Force

        $ceiling = Get-UrgentRunCeiling -Items @($script:UrgentBoard.Items)

        $ceiling.Seconds | Should -Be 60
        $ceiling.Reason | Should -Be 'total'
    }
}

Describe 'The board and the scene it plays on' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Add-AuditEntry {}
        New-TestUrgentTemplate
        New-TestUrgentBoard -Count 2 | Out-Null
        $config.Settings | Add-Member -NotePropertyName 'EnableUrgentBoard' -NotePropertyValue $true -Force
    }

    It 'says on the board itself when the scene has no loop to hide a text change in' {
        # A breaking strap cut as entrance-hold-exit has no fade to write
        # inside, so "text only" would swap the words in front of the viewer.
        # The operator has to learn this before writing eight lines in that
        # mode, not after pressing play.
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1; LoopSeconds = 0; OutroSeconds = 1 } }

        Test-UrgentSceneLoop | Should -BeFalse
        (Get-UrgentBoardText -ChatId 100) | Should -Match 'بلا حلقة'
    }

    It 'says nothing of the sort when the scene does loop' {
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1; LoopSeconds = 8; OutroSeconds = 1 } }

        Test-UrgentSceneLoop | Should -BeTrue
        (Get-UrgentBoardText -ChatId 100) | Should -Not -Match 'بلا حلقة'
    }

    It 'takes the shortest usable interval from the scene, not from the settings' {
        Mock Get-MojazSceneTiming { [pscustomobject]@{ Fps = 25; IntroSeconds = 1.5; LoopSeconds = 8; OutroSeconds = 2 } }
        $config.Settings | Add-Member -NotePropertyName 'UrgentMinIntervalSeconds' -NotePropertyValue 4 -Force

        # Entrance plus exit: the least time a change can take without being
        # seen. Re-cutting the scene in Titler re-times the board.
        Get-UrgentFloorSeconds | Should -Be 3.5
        Get-UrgentTransitionSeconds | Should -Be 3.5
    }

    It 'falls back to the setting only when the scene cannot be read' {
        Mock Get-MojazSceneTiming { $null }
        $config.Settings | Add-Member -NotePropertyName 'UrgentMinIntervalSeconds' -NotePropertyValue 6 -Force

        Get-UrgentFloorSeconds | Should -Be 6
    }

    It 'maps a line onto the field names the scene declares' {
        $item = @{ Text = 'خبر عاجل'; Title = 'كسر' }

        $values = Get-UrgentItemVariables -Item $item

        $values['Headline.Text'] | Should -Be 'خبر عاجل'
        $values['Kicker.Text'] | Should -Be 'كسر'
    }

    It 'reads two scenes without either evicting the other from the cache' {
        # One cache slot is not a cache when two callers alternate: each call
        # would evict the other and re-read the file, on the path that draws a
        # screen.
        $first = Join-Path $TestDrive 'a.cintitle'
        $second = Join-Path $TestDrive 'b.cintitle'
        Set-Content -LiteralPath $first -Encoding utf8 -Value '<CinegyTitler><Scene Fps="25" LoopStartFrame="25" LoopEndFrame="225" Duration="250" /></CinegyTitler>'
        Set-Content -LiteralPath $second -Encoding utf8 -Value '<CinegyTitler><Scene Fps="25" LoopStartFrame="50" LoopEndFrame="150" Duration="200" /></CinegyTitler>'
        $script:MojazSceneTimingCache.Clear()

        Get-MojazSceneTiming -Path $first | Out-Null
        Get-MojazSceneTiming -Path $second | Out-Null

        $script:MojazSceneTimingCache.Count | Should -Be 2
        [double](Get-MojazSceneTiming -Path $first).LoopSeconds | Should -Be 8
        [double](Get-MojazSceneTiming -Path $second).LoopSeconds | Should -Be 4
    }
}

Describe 'A board run that outlived a restart' {
    BeforeEach {
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-AdminBroadcast {}
        Mock Invoke-ExitLayer { $true }
        Mock Write-AuditRecord {}
        Mock Get-MojazSceneTiming { $null }
        New-TestUrgentTemplate
        New-TestUrgentBoard -Count 3 -IntervalSeconds 10 | Out-Null
        $script:UrgentBoardRun = $null
    }
    AfterEach { $script:UrgentBoardRun = $null; Clear-UrgentRunState }

    It 'rejoins its own schedule where the clock says it should be' {
        $started = (Get-Date).AddSeconds(-12)
        $state = [pscustomobject]@{
            SchemaVersion = 1; StartedAt = $started.ToString('o'); ChatId = 100; UserId = 101
            Step = 0; ExitAtSeconds = 30; BoardRevision = 1; OperationId = 'urgent-x'; Summary = 's'
            Steps = @(
                [pscustomobject]@{ Step = 0; AtSeconds = 0; Mode = 'text'; Text = 'أ' }
                [pscustomobject]@{ Step = 1; AtSeconds = 10; Mode = 'text'; Text = 'ب' }
                [pscustomobject]@{ Step = 2; AtSeconds = 20; Mode = 'text'; Text = 'ج' }
            )
        }
        Set-Content -LiteralPath (Get-UrgentRunFile) -Value ($state | ConvertTo-Json -Depth 8) -Encoding utf8
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date) }

        Restore-UrgentBoardRun | Should -BeTrue

        # Twelve seconds in: the second line is the one that should be up.
        [int]$script:UrgentBoardRun.Step | Should -Be 1
        [double]$script:UrgentBoardRun.ClockOffset | Should -BeGreaterThan 11
        $script:OnAir.Remove(7)
    }

    It 'keeps a paused run frozen across a restart' {
        $now = [datetime]'2026-09-17T12:00:00'
        $state = @{
            SchemaVersion = 2; StartedAt = $now.AddMinutes(-10).ToString('o'); SavedAt = $now.AddMinutes(-5).ToString('o')
            ElapsedSeconds = 4; Paused = $true; ChatId = 100; UserId = 101
            Step = 0; ExitAtSeconds = 30; BoardRevision = 1; OperationId = 'urgent-x'; Summary = 's'
            Steps = @(@{ Step = 0; AtSeconds = 0; Mode = 'text'; Text = 'أ' }, @{ Step = 1; AtSeconds = 10; Mode = 'text'; Text = 'ب' })
        }
        Set-Content -LiteralPath (Get-UrgentRunFile) -Value ($state | ConvertTo-Json -Depth 8) -Encoding utf8
        $script:OnAir[7] = @{ Key = 'Urgent'; At = $now }
        Restore-UrgentBoardRun -Now $now | Should -BeTrue
        $script:UrgentBoardRun.Clock.IsRunning | Should -BeFalse
        Get-UrgentElapsedSeconds | Should -Be 4
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
        $script:OnAir.Remove(7)
    }

    It 'drops a run whose layer somebody already dealt with' {
        $state = [pscustomobject]@{
            SchemaVersion = 1; StartedAt = (Get-Date).ToString('o'); ChatId = 100; UserId = 101
            Step = 0; ExitAtSeconds = 30; BoardRevision = 1; OperationId = 'urgent-x'; Summary = 's'
            Steps = @([pscustomobject]@{ Step = 0; AtSeconds = 0; Mode = 'text'; Text = 'أ' })
        }
        Set-Content -LiteralPath (Get-UrgentRunFile) -Value ($state | ConvertTo-Json -Depth 8) -Encoding utf8
        $script:OnAir.Remove(7)

        Restore-UrgentBoardRun | Should -BeFalse

        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'takes a scene off air when the run it belonged to is long past its end' {
        $state = [pscustomobject]@{
            SchemaVersion = 1; StartedAt = (Get-Date).AddMinutes(-10).ToString('o'); ChatId = 100; UserId = 101
            Step = 0; ExitAtSeconds = 30; BoardRevision = 1; OperationId = 'urgent-x'; Summary = 's'
            Steps = @([pscustomobject]@{ Step = 0; AtSeconds = 0; Mode = 'text'; Text = 'أ' })
        }
        Set-Content -LiteralPath (Get-UrgentRunFile) -Value ($state | ConvertTo-Json -Depth 8) -Encoding utf8
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date) }

        Restore-UrgentBoardRun | Should -BeFalse

        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
        $script:UrgentBoardRun | Should -BeNullOrEmpty
        $script:OnAir.Remove(7)
    }
}

function global:Invoke-TestUrgentNumberCallback {
    param([string]$Data, [long]$UserId = 101, [int]$MessageId = 42)
    Invoke-CallbackQuery -CallbackQuery @{
        id = 'urgent-number-test'; data = $Data
        from = @{ id = $UserId; first_name = 'Test' }
        message = @{ message_id = $MessageId; chat = @{ id = [long]100; type = 'private' } }
    }
}

Describe 'Editing the board from its buttons' {
    BeforeEach {
        Mock Invoke-RestMethod { throw 'offline test: no HTTP' }
        Mock Invoke-WebRequest { throw 'offline test: no HTTP' }
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'offline test: no Cinegy' }
        Mock Save-Config {}
        Mock Write-BridgeLog {}
        Mock Confirm-TelegramCallback {}
        Mock Update-UserNameFromTelegram {}
        Mock Update-UserLastActivity {}
        Mock Test-Authorized { $true }
        Mock Write-BridgeValidatedJson { $true }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Edit-TelegramMessageText { $true }
        Mock Add-AuditEntry {}
        Mock Get-MojazSceneTiming { $null }
        New-TestUrgentTemplate
        New-TestUrgentBoard -Count 3 | Out-Null
        $config.Settings | Add-Member -NotePropertyName 'EnableUrgentBoard' -NotePropertyValue $true -Force
    }

    It 'keeps a pending text edit attached to its original story after reordering' {
        $original = [string]$script:UrgentBoard.Items[1].Id
        Invoke-TestUrgentNumberCallback "urgentb:text:$($script:UrgentBoard.Items[1].Id)"
        $script:UrgentBoard = (Remove-UrgentItem -Board $script:UrgentBoard -ItemId ([string]$script:UrgentBoard.Items[0].Id)).Value
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value 'edited B' | Should -BeTrue
        (Get-UrgentItem -Board $script:UrgentBoard -ItemId $original).Text | Should -Be 'edited B'
        $script:UrgentBoard.Items[1].Text | Should -Be 'عاجل 3'
    }

    It 'keeps an old delete keyboard attached to its story after a move' {
        $id = [string]$script:UrgentBoard.Items[0].Id
        $keyboard = Get-UrgentItemKeyboard -Position 0
        @($keyboard.inline_keyboard | ForEach-Object { $_ } | Where-Object { $_.callback_data -eq "urgsingle:$id" }).Count | Should -Be 1
        $action = @($keyboard.inline_keyboard | ForEach-Object { $_ } | Where-Object { $_.callback_data -like 'urgentb:itemdel:*' })[0].callback_data
        $script:UrgentBoard = (Move-UrgentItem -Board $script:UrgentBoard -ItemId $id -Delta 1).Value
        Invoke-TestUrgentNumberCallback $action
        Get-UrgentItem -Board $script:UrgentBoard -ItemId $id | Should -BeNullOrEmpty
        $script:UrgentBoard.Items[0].Text | Should -Be 'عاجل 2'
    }

    It 'marks selected and disabled stories and offers selected stories for on-air playback' {
        $id = [string]$script:UrgentBoard.Items[0].Id
        $script:UrgentBoard.Items[1].Enabled = $false
        Set-UrgentSelectedIds -ChatId 100 -Ids @($id)

        $keyboard = Get-UrgentBoardKeyboard -ChatId 100
        $json = $keyboard | ConvertTo-Json -Depth 10

        $json | Should -Match '✅ ☑ 1\.'
        $json | Should -Match '⛔ ☐ 2\.'
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        @($buttons | Where-Object { $_.callback_data -like 'urgread:*' -and $_.text -eq '👁 قراءة' }).Count | Should -BeGreaterThan 0
        @($buttons | Where-Object { $_.callback_data -like 'urgentb:item:*' -and $_.text -eq '⚙️ إجراءات' }).Count | Should -BeGreaterThan 0
        @($buttons | Where-Object { $_.callback_data -like 'urgsingle:*' -and $_.text -eq '🚨 تشغيل على الهواء' }).Count | Should -BeGreaterThan 0
        $json | Should -Not -Match '"text": "👁 قراءة"[\s\S]*?"style": "primary"'
        $json | Should -Not -Match '"text": "⚙️ إجراءات"[\s\S]*?"style": "primary"'
    }

    It 'renders the selected story page from the active filter position' {
        $config.Settings | Add-Member -NotePropertyName NewsListPageSize -NotePropertyValue 8 -Force
        for ($index = 0; $index -lt 12; $index++) {
            $script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text "خبر إضافي $index" -UserId 1).Value
        }
        for ($index = 0; $index -lt 6; $index++) {
            $script:UrgentBoard.Items[$index].Enabled = $false
        }
        Set-UrgentBoardFilter -ChatId 100 -Filter ready | Should -BeTrue
        Mock Show-UrgentBoardScreen { $script:SelectedUrgentPage = $Page }

        $visible = @(Get-UrgentVisibleItems -ChatId 100)
        $target = $visible[4]
        $targetId = [string](Get-JsonProp $target 'Id')
        Invoke-TestUrgentNumberCallback "urgentb:pick:$targetId"

        $script:SelectedUrgentPage | Should -Be 0
    }

    It 'reports a failed default save and restores the previous value' {
        Mock Save-Config { $script:LastConfigSaveFailed = $true }
        Set-UrgentBoardSetting -ChatId 100 -Name UrgentBoardIntervalSeconds -Value 25 | Should -BeFalse
        Get-SettingInt 'UrgentBoardIntervalSeconds' 8 | Should -Be 10
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -like '*تعذّر حفظ*' }
    }

    It 'explains the actual scene floor on the interval picker' {
        Mock Get-UrgentFloorSeconds { 4.5 }
        $id = [string]$script:UrgentBoard.Items[0].Id
        $script:UrgentBoard = (Set-UrgentItem -Board $script:UrgentBoard -ItemId $id -Field IntervalSeconds -Value 1).Value
        Invoke-TestUrgentNumberCallback "urgentb:interval:$id"
        Should -Invoke Edit-TelegramMessageText -ParameterFilter { $Text -like '*4.5*' -and $Text -like '*المشهد*' }
    }

    It 'handles pre-upgrade selection and deletion buttons without throwing' {
        foreach ($action in @('urgentb:all', 'urgentb:none', 'urgentb:delconfirm', 'urgentb:all:bad', 'urgentb:itemdel:0')) {
            { Invoke-TestUrgentNumberCallback $action } | Should -Not -Throw
        }
        @($script:UrgentBoard.Items).Count | Should -Be 3
    }

    It 'ignores malformed action suffixes without changing selection' {
        $id = [string]$script:UrgentBoard.Items[0].Id
        Set-UrgentSelectedIds -ChatId 100 -Ids @($id)
        foreach ($action in @('urgentb:alljunk', 'urgentb:nonejunk', 'urgentb:delconfirmjunk')) {
            { Invoke-TestUrgentNumberCallback $action } | Should -Not -Throw
            @(Get-UrgentSelectedIds -ChatId 100) | Should -HaveCount 1
            @(Get-UrgentSelectedIds -ChatId 100)[0] | Should -Be $id
        }
    }

    It 'keeps selection on the displayed page' {
        New-TestUrgentBoard -Count 20 | Out-Null
        Mock Show-UrgentBoardScreen {}
        $size = Get-UrgentBoardPageSize
        Invoke-TestUrgentNumberCallback "urgentb:pick:$($script:UrgentBoard.Items[$size].Id)"
        Should -Invoke Show-UrgentBoardScreen -Times 1 -Exactly -ParameterFilter { $Page -eq 1 }
    }

    It 'keeps select-all and clear-all on the displayed page' {
        New-TestUrgentBoard -Count 20 | Out-Null
        $keyboard = Get-UrgentBoardKeyboard -ChatId 100 -Page 1
        Mock Show-UrgentBoardScreen {}
        foreach ($action in @('all', 'none')) {
            $button = @($keyboard.inline_keyboard | ForEach-Object { $_ } | Where-Object { $_.callback_data -like "urgentb:${action}*" })[0]
            Invoke-TestUrgentNumberCallback $button.callback_data
        }
        Should -Invoke Show-UrgentBoardScreen -Times 2 -Exactly -ParameterFilter { $Page -eq 1 }
    }

    It 'switches one line through all three display modes' {
        Invoke-UrgentItemModeSwitch -ChatId 100 -UserId 101 -Position 0 | Should -BeTrue

        [string]$script:UrgentBoard.Items[0].Mode | Should -Be 'exit'

        Invoke-UrgentItemModeSwitch -ChatId 100 -UserId 101 -Position 0 | Out-Null

        [string]$script:UrgentBoard.Items[0].Mode | Should -Be 'auto_hide'
        Invoke-UrgentItemModeSwitch -ChatId 100 -UserId 101 -Position 0 | Out-Null
        [string]$script:UrgentBoard.Items[0].Mode | Should -Be 'text'
    }

    It 'puts an overridden number back to the table''s own' {
        $id = [string]$script:UrgentBoard.Items[0].Id
        $script:UrgentBoard = (Set-UrgentItem -Board $script:UrgentBoard -ItemId $id -Field IntervalSeconds -Value 25).Value

        Invoke-UrgentItemReset -ChatId 100 -UserId 101 -Position 0 -Field IntervalSeconds | Should -BeTrue

        [int]$script:UrgentBoard.Items[0].IntervalSeconds | Should -Be 0
        (Get-UrgentEffectiveTiming -Item $script:UrgentBoard.Items[0] -Defaults (Get-UrgentBoardDefaults)).IntervalInherited | Should -BeTrue
    }

    It 'saves a per-line interval override typed by the operator and keeps it on screen' {
        $position = 0
        $itemId = [string]$script:UrgentBoard.Items[$position].Id
        Set-PendingState -ChatId 100 -State @{ Mode = 'urgent_item_interval'; UserId = 101; Position = $position; StartedAt = (Get-Date) }
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value '25' | Should -BeTrue

        $stored = Get-UrgentItem -Board $script:UrgentBoard -ItemId $itemId
        [int]$stored.IntervalSeconds | Should -Be 25
        (Get-UrgentEffectiveTiming -Item $stored -Defaults (Get-UrgentBoardDefaults)).IntervalSeconds | Should -Be 25
    }

    It 'rejects a non-numeric interval typed by the operator and keeps the chat waiting' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'urgent_item_interval'; UserId = 101; Position = 0; StartedAt = (Get-Date) }
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value 'ثمانية' | Out-Null

        [int]$script:UrgentBoard.Items[0].IntervalSeconds | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -like '*بين 0 و3600*' }
    }

    It 'changes eight to twenty-five through the actual default interval buttons and settings' {
        New-TestUrgentBoard -IntervalSeconds 8 | Out-Null
        Invoke-TestUrgentNumberCallback 'urgentb:dinterval'
        $pending = Get-PendingState -ChatId 100
        $pending.Mode | Should -Be 'urgent_number_picker'
        Test-PendingStateAdmission -State $pending -ChatId 100 -UserId 101 | Should -BeTrue
        Invoke-TestUrgentNumberCallback "urgentb:num:$($pending.Token):+10"
        Invoke-TestUrgentNumberCallback "urgentb:num:$($pending.Token):+5"
        Invoke-TestUrgentNumberCallback "urgentb:num:$($pending.Token):+1"
        Invoke-TestUrgentNumberCallback "urgentb:num:$($pending.Token):+1"
        (Get-SettingInt 'UrgentBoardIntervalSeconds' 8) | Should -Be 25
        (Get-UrgentBoardDefaults).IntervalSeconds | Should -Be 25
        Should -Invoke Save-Config -Times 4 -Exactly
        Should -Invoke Edit-TelegramMessageText -ParameterFilter { $MessageId -eq 42 -and $Text -like '*25*' }
        Invoke-TestUrgentNumberCallback "urgentb:num:$($pending.Token):done"
        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty
    }

    It 'keeps a per-item picker on the item that owns the token and lands on that item, not a neighbour' {
        New-TestUrgentBoard -Count 3 -IntervalSeconds 10 | Out-Null
        Invoke-TestUrgentNumberCallback "urgentb:interval:$($script:UrgentBoard.Items[1].Id)"
        $pending = Get-PendingState -ChatId 100
        $pending.Mode | Should -Be 'urgent_number_picker'
        $itemId = [string]$script:UrgentBoard.Items[1].Id
        Invoke-TestUrgentNumberCallback "urgentb:num:$($pending.Token):+10"
        Invoke-TestUrgentNumberCallback "urgentb:num:$($pending.Token):+5"
        $stored = Get-UrgentItem -Board $script:UrgentBoard -ItemId $itemId
        [int]$stored.IntervalSeconds | Should -Be 25
        @(0, 2) | ForEach-Object { [int](Get-UrgentItem -Board $script:UrgentBoard -ItemId ([string]$script:UrgentBoard.Items[$_].Id)).IntervalSeconds | Should -Be 0 }
        (Get-UrgentEffectiveTiming -Item $stored -Defaults (Get-UrgentBoardDefaults)).IntervalSeconds | Should -Be 25
    }

    It 'refuses a pick from a stale token instead of moving the wrong item' {
        New-TestUrgentBoard -Count 2 | Out-Null
        Invoke-TestUrgentNumberCallback "urgentb:interval:$($script:UrgentBoard.Items[0].Id)"
        Invoke-TestUrgentNumberCallback "urgentb:num:000000000000:+10"
        [int]$script:UrgentBoard.Items[0].IntervalSeconds | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -like '*انتهت صلاحية*' }
    }

    It 'still accepts a valid legacy numeric pending flow through admission and completion' {
        New-TestUrgentBoard -IntervalSeconds 8 | Out-Null
        Set-PendingState -ChatId 100 -State @{ Mode = 'urgent_default_interval'; UserId = 101; StartedAt = (Get-Date) }
        Test-PendingStateAdmission -State (Get-PendingState -ChatId 100) -ChatId 100 -UserId 101 | Should -BeTrue
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value '25' | Should -BeTrue
        (Get-UrgentBoardDefaults).IntervalSeconds | Should -Be 25
        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty
    }

    It 'does not report success or save an unparseable default interval which reads back as eight' {
        New-TestUrgentBoard -IntervalSeconds 8 | Out-Null
        Invoke-TestUrgentNumberCallback 'urgentb:dinterval'
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value '٢٥' | Should -BeFalse
        [string](Get-Setting 'UrgentBoardIntervalSeconds') | Should -Be '8'
        Should -Invoke Save-Config -Times 0 -Exactly
    }

    It 'switches the table between the two repeat orders, through the settings door' {
        Mock Save-Config {}

        Invoke-UrgentDefaultSwitch -ChatId 100 -Field RepeatMode | Should -BeTrue

        [string](Get-UrgentBoardDefaults).RepeatMode | Should -Be 'item'
        (Get-Setting 'UrgentBoardRepeatMode') | Should -Be 'item'
    }

    It 'refuses a table number outside its declared range instead of clamping it' {
        Mock Save-Config {}
        $before = Get-SettingInt 'UrgentBoardRepeats' 1
        Set-PendingState -ChatId 100 -State @{ Mode = 'urgent_default_repeats'; UserId = 101; StartedAt = (Get-Date) }

        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value '500' | Out-Null

        (Get-SettingInt 'UrgentBoardRepeats' 1) | Should -Be $before
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -like '*لا يزيد عن*' }
    }

    It 'binds delete confirmation to the shown selection and consumes it once' {
        $items = @($script:UrgentBoard.Items)
        Set-UrgentSelectedIds -ChatId 100 -Ids @([string]$items[0].Id)
        Show-UrgentDeleteConfirm -ChatId 100 | Out-Null
        $confirmation = Get-PendingState -ChatId 100
        Set-UrgentSelectedIds -ChatId 100 -Ids @([string]$items[2].Id)
        $token = [string](Get-JsonProp $confirmation 'Token')
        Invoke-UrgentSelectedDelete -ChatId 100 -UserId 101 -Token $token | Should -BeTrue
        Get-UrgentItem -Board $script:UrgentBoard -ItemId $items[0].Id | Should -BeNullOrEmpty
        Get-UrgentItem -Board $script:UrgentBoard -ItemId $items[2].Id | Should -Not -BeNullOrEmpty
        Invoke-UrgentSelectedDelete -ChatId 100 -UserId 101 -Token $token | Should -BeFalse
    }

    It 'deletes everything ticked in one save, not one save per line' {
        $items = @($script:UrgentBoard.Items)
        Set-UrgentSelectedIds -ChatId 100 -Ids @([string]$items[0].Id, [string]$items[2].Id)

        Show-UrgentDeleteConfirm -ChatId 100 | Out-Null
        Invoke-UrgentSelectedDelete -ChatId 100 -UserId 101 -Token ([string](Get-PendingState -ChatId 100).Token) | Should -BeTrue

        @($script:UrgentBoard.Items).Count | Should -Be 1
        [string]$script:UrgentBoard.Items[0].Text | Should -Be 'عاجل 2'
        @(Get-UrgentSelectedIds -ChatId 100).Count | Should -Be 0
        Should -Invoke Write-BridgeValidatedJson -Times 1 -Exactly
    }

    It 'adds a typed line and refuses an empty one without swallowing the next message' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'urgent_add_text'; UserId = 101; StartedAt = (Get-Date) }
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value 'خبر مكتوب' | Should -BeTrue

        @($script:UrgentBoard.Items).Count | Should -Be 4
        # The pending state is cleared before the value is used, so a refusal
        # does not leave the chat waiting to swallow whatever is typed next.
        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty

        Set-PendingState -ChatId 100 -State @{ Mode = 'urgent_add_text'; UserId = 101; StartedAt = (Get-Date) }
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value '   ' | Should -BeFalse

        @($script:UrgentBoard.Items).Count | Should -Be 4
        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty
    }

    It 'escapes a line somebody typed before it reaches a screen' {
        $script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text '<b>وسم</b> & علامة').Value

        (Get-UrgentBoardText -ChatId 100) | Should -Match '&lt;b&gt;وسم&lt;/b&gt; &amp; علامة'
    }
}

Describe 'Urgent board persistence on an isolated real disk' {
    BeforeEach {
        Mock Get-UrgentBoardFile { Join-Path $TestDrive 'actual-board.json' }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramRichMessage { $false }
        Mock Write-BridgeLog {}
        Mock Get-MojazSceneTiming { $null }
        New-TestUrgentTemplate
        New-TestUrgentBoard -IntervalSeconds 8 | Out-Null
    }

    It 'persists a picker interval for a separate PowerShell process and reload' {
        Start-UrgentNumberPicker -ChatId 100 -UserId 101 -Kind interval -Position 0
        $pending = Get-PendingState -ChatId 100
        foreach ($delta in @('+10', '+5', '+1', '+1')) {
            Invoke-UrgentNumberPick -ChatId 100 -UserId 101 -Argument "$($pending.Token):$delta" | Should -BeTrue
        }
        $file = (Get-UrgentBoardFile).Replace("'", "''")
        $command = "(Get-Content -LiteralPath '$file' -Raw | ConvertFrom-Json).Items[0].IntervalSeconds"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $output = & (Get-Process -Id $PID).Path -NoProfile -EncodedCommand $encoded
        $LASTEXITCODE | Should -Be 0
        [int]($output -join '') | Should -Be 25
        $script:UrgentBoard = New-UrgentBoard
        Import-UrgentBoard
        $script:UrgentBoard.Items[0].IntervalSeconds | Should -Be 25
    }

    It 'saves the default interval to an isolated configuration file' {
        $originalPath = $script:ConfigPath
        $script:ConfigPath = Join-Path $TestDrive 'settings-save.json'
        Set-Variable -Name ConfigPath -Value $script:ConfigPath -Scope Local
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:ConfigPath -Encoding utf8
        Mock Protect-BridgeConfigurationAcl {}
        try {
            Set-UrgentBoardSetting -ChatId 100 -Name UrgentBoardIntervalSeconds -Value 25 | Should -BeTrue
            (Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json).Settings.UrgentBoardIntervalSeconds | Should -Be 25
        }
        finally { $script:ConfigPath = $originalPath }
    }

    It 'rolls back the default interval when the real config write fails' {
        $originalPath = $script:ConfigPath
        $script:ConfigPath = Join-Path $TestDrive 'settings-locked.json'
        Set-Variable -Name ConfigPath -Value $script:ConfigPath -Scope Local
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:ConfigPath -Encoding utf8
        Mock Protect-BridgeConfigurationAcl {}
        # Block creation of the backup directory, without locking or reading production files.
        Set-Content -LiteralPath "$($script:ConfigPath).backups" -Value 'blocked' -Encoding utf8
        try {
            Set-UrgentBoardSetting -ChatId 100 -Name UrgentBoardIntervalSeconds -Value 25 | Should -BeFalse
            Get-SettingInt 'UrgentBoardIntervalSeconds' 8 | Should -Be 8
            (Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json).Settings.UrgentBoardIntervalSeconds | Should -Be 8
        }
        finally { $script:ConfigPath = $originalPath }
    }

    It 'does not publish an edit when the actual board file is locked' {
        Save-UrgentBoard -Board $script:UrgentBoard | Should -BeTrue
        $id = [string]$script:UrgentBoard.Items[0].Id
        $candidate = Set-UrgentItem -Board $script:UrgentBoard -ItemId $id -Field IntervalSeconds -Value 25
        $lock = [IO.File]::Open((Get-UrgentBoardFile), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { Invoke-UrgentEdit -Result $candidate -ChatId 100 | Should -BeFalse }
        finally { $lock.Dispose() }
        $script:UrgentBoard.Items[0].IntervalSeconds | Should -Be 0
        (Get-Content -LiteralPath (Get-UrgentBoardFile) -Raw | ConvertFrom-Json).Items[0].IntervalSeconds | Should -Be 0
    }
}
