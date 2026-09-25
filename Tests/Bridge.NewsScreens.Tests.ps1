#requires -Version 7
<#
    Bridge.NewsScreens.Tests.ps1 - News ticker screens, drafts, locks, and publishing.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'News ticker management' {
    BeforeEach {
        $script:OriginalNewsSettings = @{}
        foreach ($name in @('EnableNewsTickerManagement','NewsFilePath','NewsItemSeparator','NewsMaxItemLength','NewsMaxItems','AllowOperatorsDeleteNews','AllowOperatorsRestoreNews','AllowOperatorsClearAllNews')) {
            $script:OriginalNewsSettings[$name] = Get-JsonProp $config.Settings $name
        }
        $script:NewsLivePath = Join-Path $TestDrive 'news.txt'
        [IO.File]::WriteAllText($script:NewsLivePath, "خبر أول |`r`nخبر ثان |`r`n", [Text.UTF8Encoding]::new($true))
        $config.Settings | Add-Member EnableNewsTickerManagement $true -Force
        $config.Settings | Add-Member NewsFilePath $script:NewsLivePath -Force
        $config.Settings | Add-Member NewsItemSeparator '|' -Force
        $config.Settings | Add-Member NewsMaxItemLength 500 -Force
        $config.Settings | Add-Member NewsMaxItems 100 -Force
        $config.Settings | Add-Member AllowOperatorsDeleteNews $false -Force
        $config.Settings | Add-Member AllowOperatorsRestoreNews $false -Force
        $config.Settings | Add-Member AllowOperatorsClearAllNews $false -Force
        $script:newsDraftFile = Join-Path $TestDrive 'news-draft.json'
        $script:newsBackupDirectory = Join-Path $TestDrive 'news-backups'
        $script:NewsTickerDraft = $null
        Mock Send-TelegramMessage { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $false }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
    }

    AfterEach { $script:NewsTickerDraft = $null }

    It 'adds a permanent news-management button when the feature is enabled' {
        $keyboard = Get-PersistentReplyKeyboard
        @($keyboard.keyboard[0].text) | Should -Contain '📰 إدارة شريط الأخبار'
    }

    It 'shows news management inside the main inline menu' {
        $keyboard = Get-MainMenuKeyboard -ChatId 101 -UserId 101
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $callbacks | Should -Contain 'menu:news'
    }

    It 'shows the current news file as a clearly named administrator setting' {
        $keyboard = Get-SettingsCategoryKeyboard -Category 'news' -Page 0
        $labels = @($keyboard.inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.text } })
        @($labels | Where-Object { $_ -like '📰 ملف الأخبار*' }).Count | Should -Be 1
    }

    It 'accepts only an absolute txt path for the news file setting' {
        Test-NewsTickerFilePathSetting -Path 'news.txt' | Should -BeFalse
        Test-NewsTickerFilePathSetting -Path 'D:\ticker\news.json' | Should -BeFalse
        Test-NewsTickerFilePathSetting -Path 'D:\ticker\news.txt' | Should -BeTrue
    }

    It 'does not save an invalid news file path submitted through settings' {
        $before = [string](Get-Setting 'NewsFilePath')
        Mock Save-Config { }
        Set-PendingState -ChatId 101 -State @{ Mode='setting_text'; Name='NewsFilePath'; UserId=101 }

        Complete-SettingText -ChatId 101 -Value 'relative\news.txt'

        Get-Setting 'NewsFilePath' | Should -Be $before
        $config.Settings.NewsFilePath = $before
    }

    It 'allows one user to hold the draft lock and reports the live items' {
        $first = Start-NewsTickerDraft -ChatId 101 -UserId 101
        $second = Start-NewsTickerDraft -ChatId 202 -UserId 202

        $first.Success | Should -BeTrue
        $first.Draft.Items | Should -Be @('خبر أول','خبر ثان')
        $second.Success | Should -BeFalse
        $second.Error | Should -Match '101'
    }

    It 'keeps manual changes in the draft until reviewed publish' {
        $before = (Get-FileHash $script:NewsLivePath -Algorithm SHA256).Hash
        Start-NewsTickerDraft -ChatId 101 -UserId 101 | Out-Null
        Add-NewsTickerDraftItem -UserId 101 -Text 'خبر ثالث' | Should -BeTrue

        (Get-FileHash $script:NewsLivePath -Algorithm SHA256).Hash | Should -Be $before
        # Newest first: the item just typed leads the ticker.
        (Get-NewsTickerDraft -UserId 101).Items | Should -Be @('خبر ثالث','خبر أول','خبر ثان')
        (Publish-NewsTickerDraft -UserId 101).Success | Should -BeTrue
        (Get-NewsTickerSnapshot -Path $script:NewsLivePath -Separator '|').Items | Should -Be @('خبر ثالث','خبر أول','خبر ثان')
        Get-NewsTickerDraft | Should -BeNullOrEmpty
    }

    It 'appends instead when NewNewsItemAtTop is turned off' {
        # A rundown ordered by hand wants the old behaviour back. Set through
        # the config rather than a filtered mock of Get-Setting, which would
        # need a default mock for every other setting the flow reads.
        $config.Settings | Add-Member -NotePropertyName 'NewNewsItemAtTop' -NotePropertyValue $false -Force
        try {
            Start-NewsTickerDraft -ChatId 101 -UserId 101 | Out-Null

            Add-NewsTickerDraftItem -UserId 101 -Text 'خبر ثالث' | Should -BeTrue

            (Get-NewsTickerDraft -UserId 101).Items | Should -Be @('خبر أول', 'خبر ثان', 'خبر ثالث')
        }
        finally { $config.Settings.PSObject.Properties.Remove('NewNewsItemAtTop') }
    }

    It 'imports separator or line based TXT content into the draft without publishing' {
        Start-NewsTickerDraft -ChatId 101 -UserId 101 | Out-Null
        $result = Import-NewsTickerTextToDraft -UserId 101 -Text "مستورد أول`r`nمستورد ثان" -Mode replace

        $result.Success | Should -BeTrue
        (Get-NewsTickerDraft -UserId 101).Items | Should -Be @('مستورد أول','مستورد ثان')
        (Get-NewsTickerSnapshot -Path $script:NewsLivePath -Separator '|').Items | Should -Be @('خبر أول','خبر ثان')
    }

    It 'keeps clear-all unavailable to an operator unless explicitly enabled' {
        Start-NewsTickerDraft -ChatId 101 -UserId 101 | Out-Null
        Clear-NewsTickerDraftItems -ChatId 101 -UserId 101 | Should -BeFalse
        $config.Settings.AllowOperatorsClearAllNews = $true
        Clear-NewsTickerDraftItems -ChatId 101 -UserId 101 | Should -BeTrue
        (Get-NewsTickerDraft -UserId 101).Items.Count | Should -Be 0
    }
}

Describe 'News reorder callback acknowledgement' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Update-UserLastActivity { }
        Mock Get-NewsTickerDraft { [pscustomobject]@{ Items = @('one', 'two', 'three') } }
        Mock Show-NewsTickerReorderScreen { }
        Mock Show-NewsTickerItemScreen { }
        Mock Send-TelegramMessage { }
    }

    It 'acknowledges a successful reorder button exactly once' {
        Mock Move-NewsTickerDraftItem { $true }
        $callback = [pscustomobject]@{
            id = 'news-reorder-success'
            from = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ message_id = 55; chat = [pscustomobject]@{ id = 101; type = 'private' } }
            data = 'news:up:1'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $CallbackQueryId -eq 'news-reorder-success' }
        Should -Invoke Show-NewsTickerReorderScreen -Times 1 -Exactly
    }

    It 'acknowledges a reorder boundary button exactly once' {
        Mock Move-NewsTickerDraftItem { $false }
        $callback = [pscustomobject]@{
            id = 'news-reorder-boundary'
            from = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ message_id = 56; chat = [pscustomobject]@{ id = 101; type = 'private' } }
            data = 'news:up:0'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $CallbackQueryId -eq 'news-reorder-boundary' }
        Should -Invoke Show-NewsTickerReorderScreen -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 101 -and $Text -match 'أول القائمة' }
    }

    It 'acknowledges a successful item-screen reorder exactly once' {
        Mock Move-NewsTickerDraftItem { $true }
        $callback = [pscustomobject]@{
            id = 'news-item-reorder-success'
            from = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ message_id = 57; chat = [pscustomobject]@{ id = 101; type = 'private' } }
            data = 'news:idown:1'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $CallbackQueryId -eq 'news-item-reorder-success' }
        Should -Invoke Show-NewsTickerItemScreen -Times 1 -Exactly -ParameterFilter { $Index -eq 2 -and -not $CallbackQueryId }
    }

    It 'acknowledges an item-screen reorder boundary exactly once' {
        Mock Move-NewsTickerDraftItem { $false }
        $callback = [pscustomobject]@{
            id = 'news-item-reorder-boundary'
            from = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ message_id = 58; chat = [pscustomobject]@{ id = 101; type = 'private' } }
            data = 'news:iup:0'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $CallbackQueryId -eq 'news-item-reorder-boundary' }
        Should -Invoke Show-NewsTickerItemScreen -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 101 -and $Text -match 'أول القائمة' }
    }
}

Describe 'News draft resume callback acknowledgement' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Update-UserLastActivity { }
        Mock Resume-ExpiredNewsDraft { }
    }

    It 'acknowledges an expired draft resume exactly once' {
        $callback = [pscustomobject]@{
            id = 'news-resume-once'
            from = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ message_id = 59; chat = [pscustomobject]@{ id = 101; type = 'private' } }
            data = 'news:resume'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $CallbackQueryId -eq 'news-resume-once' }
        Should -Invoke Resume-ExpiredNewsDraft -Times 1 -Exactly -ParameterFilter { $ChatId -eq 101 -and $UserId -eq 101 }
    }
}

Describe 'News draft expiry' {
    BeforeEach {
        $script:NewsTickerDraft = $null
        Mock Write-BridgeLog {}
        Mock Send-TelegramMessage {}
        Mock Remove-NewsTickerDraft { $script:NewsTickerDraft = $null }
        Mock Get-SettingInt { 30 } -ParameterFilter { $Name -eq 'NewsDraftTimeoutMinutes' }
        # The warn path reads other bounded numbers on its way out.
        Mock Get-SettingInt { 10 }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'warns once about a draft about to expire, not once per tick' {
        # The tick runs about every second. Written as a note property, the
        # WarnedAt mark neither survived Save-NewsTickerDraft nor was seen by
        # Get-JsonProp reading the dictionary - so the operator was told the
        # same thing every second until the draft died. On a live channel that
        # is not a bug in a screen, it is a flood in the chat the alarms use.
        Mock Save-NewsTickerDraft { $true }
        $script:NewsTickerDraft = [ordered]@{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ', 'ب')
            # Inside the warn window, still short of the timeout.
            UpdatedAt = (Get-Date).AddMinutes(-28).ToString('o'); BaseHash = 'OLD'
        }

        1..10 | ForEach-Object { Update-NewsDraftExpiry }

        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'على وشك الانتهاء' }
    }

    It 'keeps the warning mark where a save and a reload can still find it' {
        # A note property is not serialised with a dictionary, so a restart
        # used to forget the draft had been warned about and start again.
        Mock Save-NewsTickerDraft { $true }
        $script:NewsTickerDraft = [ordered]@{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ')
            UpdatedAt = (Get-Date).AddMinutes(-28).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry
        $reloaded = $script:NewsTickerDraft | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable

        [string](Get-JsonProp $reloaded 'WarnedAt') | Should -Not -BeNullOrEmpty
    }

    It 'lets an extension actually extend, so pressing مدّد ends the warning' {
        # Written as a note property, the extension left the UpdatedAt KEY at
        # its old value: the draft stayed exactly as idle as it was, and the
        # warning kept arriving however many times the button was pressed.
        Mock Save-NewsTickerDraft { $true }
        $script:NewsTickerDraft = [ordered]@{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ')
            UpdatedAt = (Get-Date).AddMinutes(-28).ToString('o'); BaseHash = 'OLD'
        }
        Update-NewsDraftExpiry
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'على وشك الانتهاء' }

        # Exactly what the news:draft:extend handler does.
        $script:NewsTickerDraft['UpdatedAt'] = (Get-Date).ToString('o')
        $script:NewsTickerDraft.Remove('WarnedAt')
        1..5 | ForEach-Object { Update-NewsDraftExpiry }

        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'على وشك الانتهاء' }
    }

    It 'drops a draft left open past the timeout' {
        # Reproduces the live incident: a draft started yesterday could never
        # publish, because the live file had moved on and the hash guard
        # refused every attempt. The operator saw their edits never appear.
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ', 'ب')
            UpdatedAt = (Get-Date).AddHours(-20).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        $script:NewsTickerDraft | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'انتهت صلاحية' }
    }

    It 'tells the owner how many items were lost, so the loss is not silent' {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ', 'ب', 'ج')
            UpdatedAt = (Get-Date).AddHours(-5).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match '3 خبرًا' }
    }

    It 'hands the items back instead of only counting them' {
        # An unpublished draft is somebody's work. Telling an operator that 28
        # items were lost, without the text, is worse than useless - the lock
        # hand-over has returned it since 5.5 and an expiry destroys as much.
        Mock Send-TelegramPagedText {}
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('خبر أول', 'خبر ثان')
            UpdatedAt = (Get-Date).AddHours(-5).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly -ParameterFilter {
            $Text -match '1\. خبر أول' -and $Text -match '2\. خبر ثان'
        }
    }

    It 'leaves a draft that is still being worked on' {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ')
            UpdatedAt = (Get-Date).AddMinutes(-5).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
    }

    It 'is disabled by a zero timeout' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'NewsDraftTimeoutMinutes' }
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ')
            UpdatedAt = (Get-Date).AddDays(-2).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
    }

    It 'does nothing when there is no draft at all' {
        { Update-NewsDraftExpiry } | Should -Not -Throw
    }

    It 'leaves a draft whose timestamp cannot be read, rather than guessing' {
        $script:NewsTickerDraft = @{ OwnerUserId = 42; OwnerChatId = 42; Items = @('أ'); UpdatedAt = 'not-a-date' }
        Update-NewsDraftExpiry
        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
    }
}

Describe 'News publish conflict reporting' {
    It 'reports a conflict as a conflict, with a way forward' {
        # "لم يتم النشر" alone left operators retrying the same doomed publish
        # and concluding the bot ignored their edits.
        Mock Get-NewsTickerDraft { $null }
        $result = Publish-NewsTickerDraft -UserId 42
        $result.Success | Should -BeFalse
        # Every caller branches on Conflict, so it must exist on every path.
        $result.PSObject.Properties.Name | Should -Contain 'Conflict'
    }
}

Describe 'Manual news publish notifications' {
    BeforeEach {
        $script:OriginalPublishNotifyScope = Get-JsonProp $config.Settings 'NewsPublishNotifyScope'
        $config.Settings | Add-Member -NotePropertyName 'NewsPublishNotifyScope' -NotePropertyValue 'admins_and_publisher' -Force
        Mock Get-AdminNotifyIds { @(101, 202) }
        Mock Get-UserDisplayName { 'المشغّل' }
        Mock Send-TelegramMessage { }
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName 'NewsPublishNotifyScope' -NotePropertyValue $script:OriginalPublishNotifyScope -Force
    }

    It 'notifies administrators by default and does not duplicate the publisher result' {
        Send-NewsPublishNotice -UserId 101 -ItemCount 3

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 202 -and $Text -match 'نُشر شريط الأخبار يدويًا' -and $Text -match '3'
        }
    }

    It 'supports disabling or widening the manual publish audience' {
        $config.Settings.NewsPublishNotifyScope = 'none'
        Send-NewsPublishNotice -UserId 101 -ItemCount 1
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly

        $config.Settings.NewsPublishNotifyScope = 'all'
        $config.AllowedChatIds = @(101, 202, 303)
        Send-NewsPublishNotice -UserId 101 -ItemCount 1
        Should -Invoke Send-TelegramMessage -Times 2 -Exactly
    }
}

Describe 'News lock hand-over' {
    BeforeEach {
        $script:NewsLockRequest = $null
        $script:NewsLockGrant = $null
        $script:newsLockRequestFile = Join-Path $TestDrive 'news-lock-request.json'
        $script:NewsTickerDraft = @{ OwnerUserId = 20; OwnerChatId = 20; Items = @('أ', 'ب'); UpdatedAt = (Get-Date).ToString('o') }
        Mock Send-TelegramMessage {}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Get-UserDisplayName { "user$UserId" }
        Mock Get-NewsTickerManagementKeyboard { @{ inline_keyboard = @() } }
        Mock Remove-NewsTickerDraft { $script:NewsTickerDraft = $null }
        Mock Get-SettingInt { 5 } -ParameterFilter { $Name -eq 'NewsLockRequestMinutes' }
        Mock Get-SettingInt { 120 } -ParameterFilter { $Name -eq 'NewsLockGrantHoldSeconds' }
    }
    AfterAll { $script:NewsTickerDraft = $null; $script:NewsLockRequest = $null; $script:NewsLockGrant = $null }

    It 'asks the owner rather than taking the draft outright' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Should -BeTrue
        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 20 -and $Text -match 'يطلب' }
    }

    It 'refuses a request from the owner themselves' {
        Request-NewsLockRelease -ChatId 20 -UserId 20 | Should -BeFalse
    }

    It 'refuses a second requester while one is pending' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Request-NewsLockRelease -ChatId 22 -UserId 22 | Should -BeFalse
    }

    It 'hands over when the owner agrees, returning their text first' {
        # An unpublished draft is somebody's work; dropping it silently or
        # handing it to another person would both be worse than giving it back.
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null

        Complete-NewsLockRelease -Reason 'granted by the owner' | Should -BeTrue

        $script:NewsTickerDraft | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 20 -and $Text -match 'نصّ مسودتك' }
    }

    It 'keeps the draft when the owner says they are still working' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null

        Complete-NewsLockRelease -Denied | Should -BeFalse

        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
        $script:NewsLockRequest | Should -BeNullOrEmpty
    }

    It 'grants automatically once the window passes, because silence cannot wait' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        $script:NewsLockRequest.RequestedAt = (Get-Date).AddMinutes(-10)

        Update-NewsLockRequest

        $script:NewsTickerDraft | Should -BeNullOrEmpty
        $script:NewsLockRequest | Should -BeNullOrEmpty
    }

    It 'waits while the window is still open' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Update-NewsLockRequest
        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
    }

    It 'survives a restart inside the window, then grants for the requester' {
        # The request lived only in memory while the draft it is about
        # survives restarts on disk: a restart inside the answer window
        # killed it silently, and the promised automatic grant never came.
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Test-Path -LiteralPath $script:newsLockRequestFile | Should -BeTrue

        # A restart: memory gone, disk kept.
        $script:NewsLockRequest = $null
        Import-NewsLockRequest
        [long]$script:NewsLockRequest.RequesterUserId | Should -Be 21
        [long]$script:NewsLockRequest.OwnerUserId | Should -Be 20

        # The window passes with no reply from the holder: the lock goes to
        # the requester, the holder's text handed back, the draft gone.
        $script:NewsLockRequest.RequestedAt = (Get-Date).AddMinutes(-10)
        Update-NewsLockRequest
        $script:NewsTickerDraft | Should -BeNullOrEmpty
        $script:NewsLockRequest | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 20 -and $Text -match 'نصّ مسودتك' }
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 21 -and $Text -match 'بإمكانك التحرير' }
    }

    It 'clears the persisted request once the hand-over settles' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Complete-NewsLockRelease -Reason 'granted by the owner' | Out-Null
        Test-Path -LiteralPath $script:newsLockRequestFile | Should -BeFalse
    }

    It 'discards a corrupt persisted request instead of blocking the ticker' {
        [IO.File]::WriteAllText($script:newsLockRequestFile, 'not json{{{', [Text.UTF8Encoding]::new($true))
        Import-NewsLockRequest
        $script:NewsLockRequest | Should -BeNullOrEmpty
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Should -BeTrue
    }
}

Describe 'Handing the draft to whoever edits next' {
    BeforeEach {
        $script:NewsLockRequest = $null
        $script:NewsLockGrant = $null
        $script:newsLockRequestFile = Join-Path $TestDrive 'news-lock-request.json'
        $script:newsDraftFile = Join-Path $TestDrive 'news-draft.json'
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 20; OwnerChatId = 20; Items = @('أ', 'ب'); UpdatedAt = (Get-Date).ToString('o') }
        Mock Send-TelegramMessage {}
        Mock Send-TelegramPagedText {}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Get-UserDisplayName { "user$UserId" }
        Mock Get-NewsTickerManagementKeyboard { @{ inline_keyboard = @() } }
        Mock Get-SettingInt { 5 } -ParameterFilter { $Name -eq 'NewsLockRequestMinutes' }
        Mock Get-SettingInt { 120 } -ParameterFilter { $Name -eq 'NewsLockGrantHoldSeconds' }
    }
    AfterAll { $script:NewsTickerDraft = $null; $script:NewsLockRequest = $null; $script:NewsLockGrant = $null }

    It 'keeps every item and leaves the draft owned by nobody' {
        # The point of the button: until now the only ways out of a draft were
        # publishing it or destroying it, so an editor leaving mid-shift took
        # the newsroom's list with them.
        Open-NewsTickerDraftToAll -ChatId 20 -UserId 20 | Should -BeTrue

        @($script:NewsTickerDraft.Items).Count | Should -Be 2
        [long]$script:NewsTickerDraft.OwnerUserId | Should -Be 0
        Test-NewsTickerDraftOpen -Draft $script:NewsTickerDraft | Should -BeTrue
    }

    It 'lets the next editor adopt it with the list intact' {
        Open-NewsTickerDraftToAll -ChatId 20 -UserId 20 | Out-Null

        $taken = Start-NewsTickerDraft -ChatId 31 -UserId 31

        $taken.Success | Should -BeTrue
        @($script:NewsTickerDraft.Items) | Should -Be @('أ', 'ب')
        [long]$script:NewsTickerDraft.OwnerUserId | Should -Be 31
        # Every trace of the open state is gone, or the next reader still sees
        # a draft that belongs to nobody.
        Test-NewsTickerDraftOpen -Draft $script:NewsTickerDraft | Should -BeFalse
    }

    It 'treats a draft with no IsOpen marker as locked, not open' {
        # The first spelling of this used OwnerUserId 0 as the marker, and an
        # owner that could not be read is also 0 - so every draft looked
        # unlocked and the second user to press ✏️ simply took it. A lock
        # that fails open is worse than no lock, because everyone trusts it.
        Test-NewsTickerDraftOpen -Draft @{ Items = @('أ') } | Should -BeFalse
        Test-NewsTickerDraftOpen -Draft ([ordered]@{ OwnerUserId = 20 }) | Should -BeFalse
        Test-NewsTickerDraftOpen -Draft $null | Should -BeFalse
    }

    It 'reads an ordered draft the same as a rehydrated one' {
        # A live draft is [ordered]@{} and a restored one is a Hashtable. They
        # must answer identically, or the rule changes at every restart.
        $live = [ordered]@{ OwnerUserId = 0; IsOpen = $true; Items = @() }
        $restored = @{ OwnerUserId = 0; IsOpen = $true; Items = @() }

        Test-NewsTickerDraftOpen -Draft $live | Should -BeTrue
        Test-NewsTickerDraftOpen -Draft $restored | Should -BeTrue
    }

    It 'settles a pending request in the requester favour and holds the slot' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Should -BeTrue

        Open-NewsTickerDraftToAll -ChatId 20 -UserId 20 | Should -BeTrue

        $script:NewsLockRequest | Should -BeNullOrEmpty
        [long]$script:NewsLockGrant.UserId | Should -Be 21
        # A bystander must not win a hand-over somebody else waited out.
        (Start-NewsTickerDraft -ChatId 99 -UserId 99).Success | Should -BeFalse
        (Start-NewsTickerDraft -ChatId 21 -UserId 21).Success | Should -BeTrue
    }

    It 'refuses an unlock request against a draft that is already open' {
        Open-NewsTickerDraftToAll -ChatId 20 -UserId 20 | Out-Null

        Request-NewsLockRelease -ChatId 21 -UserId 21 | Should -BeFalse

        # Nobody is left to answer it, and an unanswered request auto-grants a
        # lock that was never held.
        $script:NewsLockRequest | Should -BeNullOrEmpty
    }

    It 'hands the words back before a discard deletes them' {
        Send-NewsDraftReceipt -ChatId 20 -Items @($script:NewsTickerDraft.Items) | Should -BeTrue

        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly -ParameterFilter { $Text -match 'أ' -and $Text -match 'ب' }
    }

    It 'sends no receipt for an empty draft or a chat that cannot be reached' {
        Send-NewsDraftReceipt -ChatId 20 -Items @() | Should -BeFalse
        Send-NewsDraftReceipt -ChatId 0 -Items @('أ') | Should -BeFalse

        Should -Invoke Send-TelegramPagedText -Times 0 -Exactly
    }
}

Describe 'News lock under simultaneous requests' {
    BeforeEach {
        $script:NewsLockRequest = $null
        $script:NewsLockGrant = $null
        $script:NewsTickerDraft = @{ OwnerUserId = 20; OwnerChatId = 20; Items = @('أ', 'ب'); UpdatedAt = (Get-Date).ToString('o') }
        Mock Send-TelegramMessage {}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Get-UserDisplayName { "user$UserId" }
        Mock Format-UserAuditActor { "user$UserId" }
        Mock Get-NewsTickerManagementKeyboard { @{ inline_keyboard = @() } }
        Mock Remove-NewsTickerDraft { $script:NewsTickerDraft = $null }
        Mock Save-NewsTickerDraft { $true }
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('حي'); Hash = 'H'; Error = '' } }
        Mock Get-SettingInt { 5 } -ParameterFilter { $Name -eq 'NewsLockRequestMinutes' }
        Mock Get-SettingInt { 120 } -ParameterFilter { $Name -eq 'NewsLockGrantHoldSeconds' }
    }
    AfterAll { $script:NewsTickerDraft = $null; $script:NewsLockRequest = $null; $script:NewsLockGrant = $null }

    It 'does not re-arm the countdown when the same requester taps again' {
        # A repeat tap used to overwrite RequestedAt, pushing the auto-grant
        # back a full window each time, so an impatient operator waited forever
        # while the owner collected a fresh ping on every press.
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Should -BeTrue
        $script:NewsLockRequest.RequestedAt = (Get-Date).AddMinutes(-4)
        $firstRequestedAt = [datetime]$script:NewsLockRequest.RequestedAt

        Request-NewsLockRelease -ChatId 21 -UserId 21 | Should -BeFalse

        [datetime]$script:NewsLockRequest.RequestedAt | Should -Be $firstRequestedAt
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 20 -and $Text -match 'يطلب' }
    }

    It 'still auto-grants on schedule after repeated taps' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        $script:NewsLockRequest.RequestedAt = (Get-Date).AddMinutes(-6)
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null

        Update-NewsLockRequest

        $script:NewsTickerDraft | Should -BeNullOrEmpty
        $script:NewsLockRequest | Should -BeNullOrEmpty
    }

    It 'holds the freed slot for the granted requester so a bystander cannot take it' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Complete-NewsLockRelease -Reason 'granted by the owner' | Should -BeTrue

        $bystander = Start-NewsTickerDraft -ChatId 99 -UserId 99
        $bystander.Success | Should -BeFalse
        $script:NewsTickerDraft | Should -BeNullOrEmpty

        $winner = Start-NewsTickerDraft -ChatId 21 -UserId 21
        $winner.Success | Should -BeTrue
        [long]$script:NewsTickerDraft.OwnerUserId | Should -Be 21
    }

    It 'releases the hold once it expires, so nobody is locked out for good' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Complete-NewsLockRelease -Reason 'granted by the owner' | Out-Null
        $script:NewsLockGrant.ExpiresAt = (Get-Date).AddSeconds(-1)

        (Start-NewsTickerDraft -ChatId 99 -UserId 99).Success | Should -BeTrue
        $script:NewsLockGrant | Should -BeNullOrEmpty
    }

    It 'clears the hold when the granted requester actually starts editing' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Complete-NewsLockRelease -Reason 'granted by the owner' | Out-Null

        (Start-NewsTickerDraft -ChatId 21 -UserId 21).Success | Should -BeTrue

        $script:NewsLockGrant | Should -BeNullOrEmpty
    }

    It 'refuses to delete a draft that changed hands while the window was open' {
        # A published, cancelled, or admin-unlocked draft can be replaced by
        # somebody uninvolved. Granting then would destroy a third party's work
        # to settle an argument they were never part of.
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        $script:NewsTickerDraft = @{ OwnerUserId = 30; OwnerChatId = 30; Items = @('جديد'); UpdatedAt = (Get-Date).ToString('o') }

        Complete-NewsLockRelease -Reason 'no reply within the window' | Should -BeFalse

        [long]$script:NewsTickerDraft.OwnerUserId | Should -Be 30
        $script:NewsLockRequest | Should -BeNullOrEmpty
        $script:NewsLockGrant | Should -BeNullOrEmpty
    }

    It 'keeps the second requester out while the first request is live' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Should -BeTrue
        Request-NewsLockRelease -ChatId 22 -UserId 22 | Should -BeFalse

        [long]$script:NewsLockRequest.RequesterUserId | Should -Be 21
        [long]$script:NewsTickerDraft.OwnerUserId | Should -Be 20
    }

    It 'lets only the first of two simultaneous starts take the draft' {
        # The poll loop hands updates to one handler at a time, so a burst
        # arriving together is still resolved in order; the second must lose.
        $script:NewsTickerDraft = $null

        (Start-NewsTickerDraft -ChatId 41 -UserId 41).Success | Should -BeTrue
        $second = Start-NewsTickerDraft -ChatId 42 -UserId 42

        $second.Success | Should -BeFalse
        [long]$script:NewsTickerDraft.OwnerUserId | Should -Be 41
    }
}

Describe 'News publish conflict resolution' {
    BeforeEach {
        $script:NewsTickerDraft = @{ OwnerUserId = 20; OwnerChatId = 20; Items = @('جديد'); BaseHash = 'STALE'; UpdatedAt = (Get-Date).ToString('o') }
        Mock Write-BridgeLog {}
        Mock Save-NewsTickerDraft { $true }
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('قائم١', 'قائم٢'); Hash = 'CURRENT'; Error = '' } }
        Mock Publish-NewsTickerDraft { [pscustomobject]@{ Success = $true; Conflict = $false; Error = '' } }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'appends to what the other system wrote, keeping both' {
        # Another system writes this file too, so a conflict is the normal
        # case; refusing forever would make the bot useless for the ticker.
        Resolve-NewsPublishConflict -UserId 20 -Mode append | Out-Null

        @($script:NewsTickerDraft.Items) | Should -Be @('قائم١', 'قائم٢', 'جديد')
        $script:NewsTickerDraft.BaseHash | Should -Be 'CURRENT'
    }

    It 'replaces only when that is explicitly chosen' {
        Resolve-NewsPublishConflict -UserId 20 -Mode replace | Out-Null

        @($script:NewsTickerDraft.Items) | Should -Be @('جديد')
        $script:NewsTickerDraft.BaseHash | Should -Be 'CURRENT'
    }

    It 'refuses when the live file cannot be read, rather than guessing' {
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $false; Items = @(); Hash = ''; Error = 'binary data' } }
        (Resolve-NewsPublishConflict -UserId 20 -Mode append).Success | Should -BeFalse
    }

    It 'refuses when the caller does not own the draft' {
        (Resolve-NewsPublishConflict -UserId 99 -Mode append).Success | Should -BeFalse
    }
}

Describe 'News item delete confirmation' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر أول', 'خبر ثانٍ', 'خبر ثالث')
        }
        Mock Send-TelegramMessage {}
        Mock Edit-TelegramMessageText { $false }
        Mock Test-Admin { $true }
        Mock Save-NewsTickerDraft { $true }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'shows the item text, because a number alone is not recognisable' {
        # The list is scrolled with a thumb; a mis-tap used to lose typed work
        # on the first press.
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index 1 | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'خبر ثانٍ' -and $Text -match 'تأكيد حذف' }
    }

    It 'deletes nothing until the confirmation is answered' {
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index 1 | Out-Null
        @($script:NewsTickerDraft.Items).Count | Should -Be 3
    }

    It 'removes exactly the confirmed item once accepted' {
        Remove-NewsTickerDraftItem -ChatId 42 -UserId 42 -Index 1 | Should -BeTrue
        @($script:NewsTickerDraft.Items) | Should -Be @('خبر أول', 'خبر ثالث')
    }

    It 'offers a cancel that returns to the item rather than the list' {
        # Cancelling should leave the operator where they were.
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index 2 | Out-Null
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } }) -contains 'news:item:2'
        }
    }

    It 'refuses an index that is not in the draft' {
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index 9 | Should -BeFalse
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index -1 | Should -BeFalse
    }

    It 'refuses when the asker does not own the draft' {
        Show-NewsTickerDeleteConfirm -ChatId 99 -UserId 99 -Index 0 | Should -BeFalse
    }
}

Describe 'Delete from the reorder list' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر أول', 'خبر ثانٍ', 'خبر ثالث')
        }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'offers a delete on every row' {
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        foreach ($i in 0..2) { $flat | Should -Contain "news:delask:$i" }
    }

    It 'routes through the same confirmation the item screen uses' {
        # A second delete path would be a second place for a thumb to lose
        # typed work.
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $flat | Should -Not -Contain 'news:delete:0'
    }

    It 'keeps the move and edit controls alongside it' {
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $middle = @($rows[1] | ForEach-Object { $_['callback_data'] })
        $middle | Should -Contain 'news:up:1'
        $middle | Should -Contain 'news:item:1'
        $middle | Should -Contain 'news:down:1'
        $middle | Should -Contain 'news:delask:1'
    }

    It 'shows nothing to delete when there is no draft' {
        $script:NewsTickerDraft = $null
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        ($flat -join ' ') | Should -Not -Match 'delask'
    }
}

Describe 'News list layout' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر قصير', 'خبر ثانٍ طويل جدًا يتجاوز حدّ التسمية المختصرة بكثير جدًا فعلًا', 'خبر ثالث')
        }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListPaged' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'keeps everything on one row by default' {
        Mock Get-Setting { 'text' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $middle = @($rows[1] | ForEach-Object { $_['callback_data'] })
        $middle | Should -Contain 'news:up:1'
        $middle | Should -Contain 'news:item:1'
        $middle | Should -Contain 'news:delask:1'
    }

    It 'gives the headline its own row when stacked' {
        # A 24-character label tells you nothing about a long headline, which
        # is the whole point of the alternative layout.
        Mock Get-Setting { 'stacked' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        @($rows[2]).Count | Should -Be 1
        @($rows[2])[0].callback_data | Should -Be 'news:item:1'
    }

    It 'puts move, edit and delete on the row beneath it' {
        Mock Get-Setting { 'stacked' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $controls = @($rows[3] | ForEach-Object { $_['callback_data'] })
        $controls | Should -Contain 'news:up:1'
        $controls | Should -Contain 'news:down:1'
        $controls | Should -Contain 'news:edit:1'
        $controls | Should -Contain 'news:delask:1'
    }

    It 'omits the move it cannot make, at either end' {
        Mock Get-Setting { 'stacked' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        @($rows[1] | ForEach-Object { $_['callback_data'] }) | Should -Not -Contain 'news:up:0'
        @($rows[5] | ForEach-Object { $_['callback_data'] }) | Should -Not -Contain 'news:down:2'
    }

    It 'shows more of a long headline when it owns the row' {
        Mock Get-Setting { 'stacked' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $stacked = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[2][0].text
        Mock Get-Setting { 'text' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $inline = @(@((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[1] | Where-Object { $_['callback_data'] -eq 'news:item:1' })[0].text
        $stacked.Length | Should -BeGreaterThan $inline.Length
    }

    It 'still deletes through the confirmation in both layouts' {
        foreach ($layout in @('text', 'stacked', 'inline')) {
            Mock Get-Setting { $layout } -ParameterFilter { $Name -eq 'NewsListLayout' }
            $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
            $flat | Should -Not -Contain 'news:delete:1'
            $flat | Should -Contain 'news:delask:1'
        }
    }
}

Describe 'News list row geometry' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر أول', 'خبر ثانٍ طويل جدًا يتجاوز أي حدّ كان يُقصّ عنده في زر ضيق', 'خبر ثالث')
        }
        Mock Get-Setting { 'text' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListPaged' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'gives every row the same four buttons, including the two ends' {
        # Telegram splits a row's width equally, so a row of three buttons
        # renders wider than a row of four - which is what made the first and
        # last items look bigger than the rest.
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        foreach ($index in 0..2) { @($rows[$index]).Count | Should -Be 4 }
    }

    It 'makes the two end placeholders inert instead of merely pointless' {
        # They used to carry a live callback into a no-op handler: pressable,
        # acknowledged, and doing nothing - which reads exactly like a press
        # the bridge dropped. Bot API 10.3 lets a button say it is disabled.
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $first = @($rows[0] | Where-Object { $_.text -eq '▫️' })
        $last = @($rows[2] | Where-Object { $_.text -eq '▫️' })

        @($first).Count | Should -Be 1
        @($last).Count | Should -Be 1
        $first[0].ContainsKey('disabled') | Should -BeTrue
        $first[0].ContainsKey('callback_data') | Should -BeFalse
        $last[0].ContainsKey('disabled') | Should -BeTrue
    }

    It 'carries the headline in the message text, uncut, instead of a button' {
        $text = Get-NewsTickerReorderText -UserId 42

        $text | Should -Match ([regex]::Escape('<b>2.</b> خبر ثانٍ طويل جدًا يتجاوز أي حدّ كان يُقصّ عنده في زر ضيق'))
        @(@((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[1] |
            Where-Object { $_['callback_data'] -eq 'news:item:1' })[0].text | Should -Be '2'
    }

    It 'keeps the listing inside one Telegram message for a full page' {
        # Against the limit the bridge actually sends at, not Telegram's 4096:
        # everything between the two used to pass here and split on the wire.
        $script:NewsTickerDraft.Items = @(1..21 | ForEach-Object { "خبر رقم $_ " + ('ط' * 400) })
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }

        @(Split-TelegramText -Text (Get-NewsTickerReorderText -UserId 42)).Count | Should -Be 1
    }

    It 'still fits when escaping expands every headline it lists' {
        # Escaping only grows text: one '&' becomes five characters. Measuring
        # the budget before escaping put a page of "AT&T" headlines at 6000
        # characters against a 3500 limit, which split the message and dropped
        # its parse mode - so the operator saw the raw <b> and <blockquote>
        # tags instead of a list.
        $script:NewsTickerDraft.Items = @(1..21 | ForEach-Object { 'AT&T ' * 120 })
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }

        @(Split-TelegramText -Text (Get-NewsTickerReorderText -UserId 42)).Count | Should -Be 1
    }
}

Describe 'News listing line escaping' {
    It 'measures its length after escaping, not before' {
        $line = Get-NewsListEscapedLine -Item ('&' * 200) -MaxLength 60

        $line.Length | Should -BeLessOrEqual 60
    }

    It 'never cuts an entity in half, which would void the whole message' {
        foreach ($max in 41..60) {
            $line = Get-NewsListEscapedLine -Item ('&' * 500) -MaxLength $max
            # A trailing '&am' or '&amp' is not an entity; Telegram rejects it.
            $line.TrimEnd('…') | Should -Match '^(&amp;)*$'
        }
    }

    It 'leaves a short headline exactly as typed, apart from escaping' {
        Get-NewsListEscapedLine -Item 'خبر <عاجل> & مهم' -MaxLength 120 |
            Should -Be 'خبر &lt;عاجل&gt; &amp; مهم'
    }

    It 'handles an empty headline rather than throwing' {
        Get-NewsListEscapedLine -Item '' -MaxLength 40 | Should -Be ''
    }
}

Describe 'News list paging' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @(1..38 | ForEach-Object { "خبر رقم $_" })
        }
        Mock Get-Setting { 'text' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListPaged' }
        Mock Get-SettingInt { 10 } -ParameterFilter { $Name -eq 'NewsListPageSize' }
        Mock Get-SettingInt { 24 } -ParameterFilter { $Name -eq 'NewsListLabelLength' }
        Mock Get-SettingInt { 60 } -ParameterFilter { $Name -eq 'NewsListStackedLabelLength' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'puts the whole draft on one screen when paging is off and it fits' {
        # What "one long list" is for: a normal-sized draft, no page buttons,
        # everything reachable without flipping.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }
        $script:NewsTickerDraft.Items = @(1..12 | ForEach-Object { "خبر رقم $_" })

        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        @($flat | Where-Object { $_ -like 'news:item:*' }).Count | Should -Be 12
        $flat | Should -Not -Contain 'news:list:1'
    }

    It 'still pages a draft too big for one keyboard, and says why' {
        # The option cannot repeal Telegram's limit. Silently truncating, or
        # sending a keyboard that gets rejected, are both worse than paging
        # and saying so.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }

        $buttons = (@((Get-NewsTickerReorderKeyboard -UserId 42 -Page 0).inline_keyboard |
                    ForEach-Object { @($_).Count } | Measure-Object -Sum).Sum)

        $buttons | Should -BeLessThan 100
        (Get-NewsTickerPageCount -UserId 42) | Should -BeGreaterThan 1
        Get-NewsTickerReorderText -UserId 42 | Should -Match 'القائمة الطويلة مفعّلة'
    }

    It 'fits fewer items per screen when each one owns two rows' {
        # The stacked layout spends an extra button per item, so the same
        # budget buys fewer of them.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }
        $inline = Get-NewsTickerPageSize
        Mock Get-Setting { 'stacked' } -ParameterFilter { $Name -eq 'NewsListLayout' }

        (Get-NewsTickerPageSize) | Should -BeLessThan $inline
    }

    It 'reaches every item across the pages, including the last' {
        # 38 items rendered 152 buttons in one keyboard. Telegram refused it,
        # the resend was refused too, and the list silently stopped updating -
        # which read as the last items being missing.
        $seen = @()
        foreach ($page in 0..((Get-NewsTickerPageCount -UserId 42) - 1)) {
            $seen += @((Get-NewsTickerReorderKeyboard -UserId 42 -Page $page).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } } |
                    Where-Object { $_ -like 'news:item:*' })
        }
        @($seen | Sort-Object -Unique).Count | Should -Be 38
        $seen | Should -Contain 'news:item:37'
    }

    It 'keeps every page well inside the button limit' {
        foreach ($page in 0..3) {
            $buttons = (@((Get-NewsTickerReorderKeyboard -UserId 42 -Page $page).inline_keyboard |
                        ForEach-Object { @($_).Count } | Measure-Object -Sum).Sum)
            $buttons | Should -BeLessThan 100
        }
    }

    It 'numbers items by their real position, not their position on the page' {
        $labels = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 2).inline_keyboard |
                ForEach-Object { @($_) } | Where-Object { $_['callback_data'] -like 'news:item:*' })
        $labels[0].text | Should -Be '21'
        $labels[0].callback_data | Should -Be 'news:item:20'
    }

    It 'offers forward and back only where they exist' {
        $firstPage = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 0).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $firstPage | Should -Not -Contain 'news:list:-1'
        $firstPage | Should -Contain 'news:list:1'

        $lastPage = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 3).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $lastPage | Should -Contain 'news:list:2'
        $lastPage | Should -Not -Contain 'news:list:4'
    }

    It 'clamps a page number that is out of range instead of rendering nothing' {
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 99).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $flat | Should -Contain 'news:item:37'
    }

    It 'shows no pager at all when everything fits on one page' {
        $script:NewsTickerDraft.Items = @('واحد', 'اثنان')
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 0).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        ($flat -join ' ') | Should -Not -Match 'news:list:'
    }

    It 'states the range and total in the heading' {
        $text = Get-NewsTickerReorderText -UserId 42 -Page 1
        $text | Should -Match ([regex]::Escape('الأخبار: <b>38</b>'))
        $text | Should -Match '11'
        $text | Should -Match 'صفحة 2 من 4'
    }

    It 'keeps the move controls absolute, so paging never moves the wrong item' {
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 1).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $flat | Should -Contain 'news:up:10'
        $flat | Should -Contain 'news:delask:10'
    }
}

Describe 'News list layout choice' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر أول', 'خبر ثانٍ', 'خبر ثالث')
        }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListPaged' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'offers exactly the four shapes, and falls back to text for anything else' {
        $script:SettingChoices['NewsListLayout'] | Should -Be @('text', 'stacked', 'inline', 'compact')

        Mock Get-Setting { 'nonsense' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        Get-NewsListLayout | Should -Be 'text'
    }

    It 'puts the headline in the row itself when inline is chosen' {
        Mock Get-Setting { 'inline' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        Mock Get-SettingInt { 24 } -ParameterFilter { $Name -eq 'NewsListLabelLength' }
        Mock Get-SettingInt { 10 } -ParameterFilter { $Name -eq 'NewsListPageSize' }
        Mock Get-SettingInt { 60 } -ParameterFilter { $Name -eq 'NewsListStackedLabelLength' }

        $label = @(@((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[1] |
            Where-Object { $_['callback_data'] -eq 'news:item:1' })[0].text

        $label | Should -Match 'خبر ثانٍ'
        Get-NewsTickerReorderText -UserId 42 | Should -Not -Match '2\. خبر ثانٍ'
    }

    It 'reaches every item in all four shapes' {
        foreach ($layout in @('text', 'stacked', 'inline', 'compact')) {
            Mock Get-Setting { $layout } -ParameterFilter { $Name -eq 'NewsListLayout' }
            $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
            foreach ($i in 0..2) { $flat | Should -Contain "news:item:$i" }
        }
    }
}

Describe 'Compact and stacked shapes' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @(1..30 | ForEach-Object { "خبر رقم $_" })
        }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'fits thirty items on one compact screen, five numbers to a row' {
        Mock Get-Setting { 'compact' } -ParameterFilter { $Name -eq 'NewsListLayout' }

        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $flat = @($rows | ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        foreach ($i in 0..29) { $flat | Should -Contain "news:item:$i" }
        $flat | Should -Not -Contain 'news:list:1'
        @($rows[0]).Count | Should -Be 5
        (@($rows | ForEach-Object { @($_).Count } | Measure-Object -Sum).Sum) | Should -BeLessThan 100
    }

    It 'cannot fit thirty in any shape that carries per-item controls' {
        foreach ($layout in @('text', 'stacked', 'inline')) {
            Mock Get-Setting { $layout } -ParameterFilter { $Name -eq 'NewsListLayout' }
            (Get-NewsTickerPageCount -UserId 42) | Should -BeGreaterThan 1
        }
    }

    It 'carries the item number on every stacked control' {
        Mock Get-Setting { 'stacked' } -ParameterFilter { $Name -eq 'NewsListLayout' }

        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)

        # Telegram gives buttons no colour or spacing, so the number is what
        # says which headline these four belong to.
        foreach ($button in @($rows[3])) { $button.text | Should -Match '2$' }
        @($rows[2])[0].text | Should -Match '^▫️ 2\.'
        @($rows[0])[0].text | Should -Match '^▪️ 1\.'
    }
}

Describe 'News reorder screen as HTML' {
    BeforeAll {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('شركة AT&T <b>عاجل</b>', 'خبر عادي')
        }
        Mock Get-Setting { 'text' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListPaged' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'escapes a headline that contains markup, instead of losing the whole send to a 400' {
        # A headline is typed by a person and goes on air. One stray '<' used
        # to be harmless; under parse_mode=HTML it makes Telegram reject the
        # message, which on this screen reads as a list that will not update.
        $text = Get-NewsTickerReorderText -UserId 42

        $text | Should -Match ([regex]::Escape('AT&amp;T &lt;b&gt;عاجل&lt;/b&gt;'))
        $text | Should -Not -Match ([regex]::Escape('<b>عاجل'))
    }

    It 'wraps the listing in an expandable quotation so a long page keeps its keyboard on screen' {
        $text = Get-NewsTickerReorderText -UserId 42

        $text | Should -Match ([regex]::Escape('<blockquote expandable>'))
        $text | Should -Match ([regex]::Escape('</blockquote>'))
    }

    It 'falls back to HTML, not to text that merely looks like it' {
        # Blocks are tried first now; the HTML version is what catches a
        # refusal, and it has to keep its parse mode when it does.
        $script:RichMessagesUnavailable = $true
        Mock Edit-TelegramMessageText { $true }

        try { Show-NewsTickerReorderScreen -ChatId 42 -UserId 42 -MessageId 7 }
        finally { $script:RichMessagesUnavailable = $false }

        Should -Invoke Edit-TelegramMessageText -Times 1 -Exactly -ParameterFilter { $ParseMode -eq 'HTML' }
    }

    It 'edits the rich screen in place rather than leaving a message per press' {
        Mock Get-NewsTickerReorderBlocks { @(@{ type = 'paragraph'; text = 'x' }) }
        Mock Edit-TelegramRichMessage { $true }
        Mock Edit-TelegramMessageText { $true }
        Mock Send-TelegramMessage { }

        Show-NewsTickerReorderScreen -ChatId 42 -UserId 42 -MessageId 7

        Should -Invoke Edit-TelegramRichMessage -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}

Describe 'The draft is shown against what it would replace' {
    BeforeAll {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر باقٍ', 'خبر جديد')
        }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'names what would be added and what would go, not just how many' {
        # "3 items will be replaced" is a count. An editor about to put copy
        # on air is deciding whether these are the right words.
        $diff = Get-NewsDraftDiff -Draft @('خبر باقٍ', 'خبر جديد') -Live @('خبر باقٍ', 'خبر قديم')

        @($diff.Added) | Should -Be @('خبر جديد')
        @($diff.Removed) | Should -Be @('خبر قديم')
        @($diff.Kept) | Should -Be @('خبر باقٍ')
    }

    It 'reports no difference when the draft matches the air' {
        $diff = Get-NewsDraftDiff -Draft @('أ', 'ب') -Live @('أ', 'ب')

        @($diff.Added).Count | Should -Be 0
        @($diff.Removed).Count | Should -Be 0
        @($diff.Kept).Count | Should -Be 2
    }

    It 'treats an empty air as everything being added' {
        $diff = Get-NewsDraftDiff -Draft @('أ') -Live @()

        @($diff.Added) | Should -Be @('أ')
        @($diff.Removed).Count | Should -Be 0
    }

    It 'puts the running order in a table, with the length of each item' {
        # The ticker enforces NewsMaxItemLength and an editor had no way to
        # see which headline was near it until the publish was refused.
        Mock Get-NewsTickerConfiguredSnapshot { @{ Success = $false; Items = @() } }

        $blocks = @(Get-NewsTickerReorderBlocks -UserId 42)
        $table = @($blocks | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[0]).Count | Should -Be 3
        @($table.cells[1])[0].text | Should -Be '1'
        @($table.cells[1])[2].text | Should -Be '8'
    }

    It 'flags a headline that is close to the limit rather than only counting it' {
        Mock Get-NewsTickerConfiguredSnapshot { @{ Success = $false; Items = @() } }
        $script:NewsTickerDraft.Items = @('ط' * 95)
        try {
            $config.Settings | Add-Member -NotePropertyName NewsMaxItemLength -NotePropertyValue 100 -Force
            $table = @(@(Get-NewsTickerReorderBlocks -UserId 42) | Where-Object { $_.type -eq 'table' })[0]

            @($table.cells[1])[2].text | Should -Match '⚠️'
        }
        finally { $script:NewsTickerDraft.Items = @('خبر باقٍ', 'خبر جديد') }
    }

    It 'folds the on-air comparison under the draft instead of behind a preview button' {
        Mock Get-NewsTickerConfiguredSnapshot { @{ Success = $true; Items = @('خبر باقٍ', 'خبر قديم') } }

        $folded = @(@(Get-NewsTickerReorderBlocks -UserId 42) | Where-Object { $_.type -eq 'details' })[0]
        $texts = @($folded.blocks | ForEach-Object { $_.text })

        $folded.summary | Should -Match '\+1 −1'
        @($texts | Where-Object { $_ -eq '➕ خبر جديد' }).Count | Should -Be 1
        @($texts | Where-Object { $_ -eq '➖ خبر قديم' }).Count | Should -Be 1
    }

    It 'says the publish would change nothing rather than drawing an empty table' {
        Mock Get-NewsTickerConfiguredSnapshot { @{ Success = $true; Items = @('خبر باقٍ', 'خبر جديد') } }

        $blocks = @(Get-NewsPublishReviewBlocks -UserId 42)

        @($blocks | Where-Object { $_.type -eq 'table' }).Count | Should -Be 0
        @($blocks | Where-Object { $_.text -match 'لن يغيّر' }).Count | Should -Be 1
    }

    It 'reviews a publish as the words it changes' {
        Mock Get-NewsTickerConfiguredSnapshot { @{ Success = $true; Items = @('خبر باقٍ', 'خبر قديم') } }

        $blocks = @(Get-NewsPublishReviewBlocks -UserId 42)
        $table = @($blocks | Where-Object { $_.type -eq 'table' })[0]
        $marks = @($table.cells | Select-Object -Skip 1 | ForEach-Object { @($_)[0].text })

        $marks | Should -Contain '➕'
        $marks | Should -Contain '➖'
        @($blocks | Where-Object { $_.type -eq 'details' })[0].summary | Should -Match 'بلا تغيير \(1\)'
    }
}

Describe 'Expired news draft resume (D3)' {
    BeforeEach {
        $script:NewsTickerDraft = $null
        $script:ExpiredNewsDraft = $null
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-TelegramMessage { }
        Mock Save-NewsTickerDraft { $true }
        Mock Show-NewsTickerManagementScreen { }
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Hash = 'fresh'; Items = @('حي'); Error = '' } }
    }

    It 'reopens an expired draft with its items on a fresh base' {
        $script:ExpiredNewsDraft = @{ Items = @('أ', 'ب'); OwnerUserId = 7; OwnerChatId = 8; At = (Get-Date) }
        Resume-ExpiredNewsDraft -ChatId 8 -UserId 7
        $script:NewsTickerDraft.Items.Count | Should -Be 2
        $script:NewsTickerDraft.BaseHash | Should -Be 'fresh'
        $script:ExpiredNewsDraft | Should -BeNullOrEmpty
        Should -Invoke Show-NewsTickerManagementScreen -Times 1 -Exactly
    }

    It 'refuses when another draft is already active' {
        $script:NewsTickerDraft = [ordered]@{ Items = @('حي') }
        $script:ExpiredNewsDraft = @{ Items = @('أ'); OwnerUserId = 7; OwnerChatId = 8; At = (Get-Date) }
        Resume-ExpiredNewsDraft -ChatId 8 -UserId 7
        $script:NewsTickerDraft.Items.Count | Should -Be 1
        $script:ExpiredNewsDraft | Should -Not -BeNullOrEmpty
    }

    It 'refuses a resume tap from a different chat' {
        $script:ExpiredNewsDraft = @{ Items = @('أ'); OwnerUserId = 7; OwnerChatId = 8; At = (Get-Date) }
        Resume-ExpiredNewsDraft -ChatId 9 -UserId 9
        $script:NewsTickerDraft | Should -BeNullOrEmpty
    }
}

Describe 'News ticker backups: what is kept is what is offered' {
    BeforeEach {
        $script:newsBackupDirectory = Join-Path $TestDrive 'news-backups-reach'
        New-Item -ItemType Directory -Path $script:newsBackupDirectory -Force | Out-Null
        Get-ChildItem -LiteralPath $script:newsBackupDirectory -File | Remove-Item -Force
        $config.Settings | Add-Member NewsBackupKeepFiles 20 -Force
        $config.Settings | Add-Member NewsItemSeparator '|' -Force
        $config.Settings | Add-Member NewsMaxItemLength 500 -Force
        $config.Settings | Add-Member NewsMaxItems 100 -Force
        # Sixteen copies, oldest first, each with its own write time so the
        # newest-first order is real rather than incidental.
        for ($copy = 0; $copy -lt 16; $copy++) {
            $backupFile = Join-Path $script:newsBackupDirectory "news-$($copy.ToString('00')).txt"
            Set-Content -LiteralPath $backupFile -Value "خبر النسخة $copy" -Encoding utf8
            (Get-Item -LiteralPath $backupFile).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(-100 + $copy)
        }
    }

    It 'offers every copy it keeps, not a hard-coded ten' {
        # The live shape: the setting kept twenty and every screen showed ten,
        # so half the copies on disk could not be reached from any screen.
        @(Get-NewsTickerBackupFiles).Count | Should -Be 16
    }

    It 'still stops at the number the setting keeps' {
        $config.Settings | Add-Member NewsBackupKeepFiles 5 -Force

        @(Get-NewsTickerBackupFiles).Count | Should -Be 5
    }

    It 'refuses a negative index instead of restoring the oldest copy' {
        # PowerShell reads [-1] from the end, so the upper-bound-only check
        # this replaced would have put the OLDEST copy on the live ticker.
        Get-NewsTickerBackupByIndex -Index -1 | Should -BeNullOrEmpty
        Get-NewsTickerBackupByIndex -Index 16 | Should -BeNullOrEmpty
    }

    It 'restores the copy the screen numbered, reading the same list the screen read' {
        $listed = @(Get-NewsTickerBackupFiles)
        $picked = Get-NewsTickerBackupByIndex -Index 2

        $picked.FullName | Should -Be $listed[2].FullName
        # Newest first: copy 15 was written last.
        (Get-Content -LiteralPath (Get-NewsTickerBackupByIndex -Index 0).FullName -Raw).Trim() | Should -Be 'خبر النسخة 15'
    }

    It 'declares a range, because this number now sizes a screen' {
        $script:SettingConstraints['NewsBackupKeepFiles'].Minimum | Should -Be 1
        $script:SettingConstraints['NewsBackupKeepFiles'].Maximum | Should -Be 30
    }
}

Describe 'Pasting several headlines at once' {
    <#
        "Add a headline" took exactly one. A paste of several lines was
        refused with "check the text and the limits", and the only way to add
        many was the .txt import, which replaces the draft. The same button
        now takes one or many; many get a review before anything is added.
    #>
    BeforeEach {
        $script:PasteOriginal = @{}
        foreach ($name in 'NewsItemSeparator', 'NewsMaxItemLength', 'NewsMaxItems', 'NewNewsItemAtTop') { $script:PasteOriginal[$name] = Get-JsonProp $config.Settings $name }
        $config.Settings | Add-Member NewsItemSeparator '|' -Force
        $config.Settings | Add-Member NewsMaxItemLength 60 -Force
        $config.Settings | Add-Member NewsMaxItems 5 -Force
        $config.Settings | Add-Member NewNewsItemAtTop $true -Force
        $script:NewsTickerDraft = @{ OwnerUserId = 42; OwnerChatId = 42; Items = @('قديم'); UpdatedAt = (Get-Date).ToString('o') }
        Clear-PendingState -ChatId 42
        $script:pasteSent = [Collections.Generic.List[object]]::new()
        Mock Send-TelegramMessage { $script:pasteSent.Add([pscustomobject]@{ Text = $Text; Markup = $ReplyMarkup }) }
        Mock Edit-TelegramMessageText { $script:pasteSent.Add([pscustomobject]@{ Text = $Text; Markup = $ReplyMarkup }); $true }
        Mock Save-NewsTickerDraft { $true }
        Mock Write-BridgeLog { }
        Mock Get-NewsTickerManagementKeyboard { @{ inline_keyboard = @() } }
    }
    AfterEach {
        foreach ($name in $script:PasteOriginal.Keys) { $config.Settings | Add-Member $name $script:PasteOriginal[$name] -Force }
        $script:NewsTickerDraft = $null
        Clear-PendingState -ChatId 42
    }

    It 'still adds a single headline straight away, cleaned of a list marker' {
        Complete-NewsTickerAddText -ChatId 42 -UserId 42 -Value '1. خبر واحد'
        $script:NewsTickerDraft.Items | Should -Be @('خبر واحد', 'قديم')
        Get-PendingState -ChatId 42 | Should -BeNullOrEmpty
    }

    It 'adds nothing until the review is confirmed' {
        Complete-NewsTickerAddText -ChatId 42 -UserId 42 -Value "أ`nب`nج"
        $script:NewsTickerDraft.Items | Should -Be @('قديم')
        (Get-PendingState -ChatId 42).Mode | Should -Be 'news_paste_review'
        $script:pasteSent[-1].Text | Should -BeLike '*3*'
    }

    It 'adds the block in the order pasted, at the top, on confirm' {
        Complete-NewsTickerAddText -ChatId 42 -UserId 42 -Value "أ`nب`nج"
        Complete-NewsPaste -ChatId 42 -UserId 42
        $script:NewsTickerDraft.Items | Should -Be @('أ', 'ب', 'ج', 'قديم') -Because 'adding one at a time to the top would have reversed them'
    }

    It 'skips what the draft already holds and stops at the item limit' {
        # Limit 5, one already in the draft: room for four.
        Complete-NewsTickerAddText -ChatId 42 -UserId 42 -Value "قديم`nأ`nب`nج`nد`nهـ"
        $script:pasteSent[-1].Text | Should -BeLike "*$(T 'news.paste.inDraft' 1)*"
        $script:pasteSent[-1].Text | Should -BeLike "*$(T 'news.paste.noRoom' 1 5)*"
        Complete-NewsPaste -ChatId 42 -UserId 42
        $script:NewsTickerDraft.Items | Should -Be @('أ', 'ب', 'ج', 'د', 'قديم')
    }

    It 'names a line too long instead of refusing the whole paste' {
        $long = 'ك' * 80
        Complete-NewsTickerAddText -ChatId 42 -UserId 42 -Value "قصير`n$long"
        $script:pasteSent[-1].Text | Should -BeLike "*$(T 'news.paste.tooLong' 1 60)*"
        Complete-NewsPaste -ChatId 42 -UserId 42
        $script:NewsTickerDraft.Items | Should -Be @('قصير', 'قديم')
    }

    It 'joins a paste Telegram split across messages into one batch' {
        Complete-NewsTickerAddText -ChatId 42 -UserId 42 -Value "أ`nب"
        Add-NewsPasteChunk -ChatId 42 -UserId 42 -Value "ب`nج"
        @((Get-PendingState -ChatId 42).Items) | Should -Be @('أ', 'ب', 'ج')
        Should -Invoke Edit-TelegramMessageText -Times 0 -Because 'the first review was sent through the mock, which records no message id'
        Complete-NewsPaste -ChatId 42 -UserId 42
        $script:NewsTickerDraft.Items | Should -Be @('أ', 'ب', 'ج', 'قديم')
    }

    It 'escapes pasted HTML in the review, so a headline cannot break the message' {
        Complete-NewsTickerAddText -ChatId 42 -UserId 42 -Value "<b>خبر</b> & آخر`nثان"
        $script:pasteSent[-1].Text | Should -BeLike '*&lt;b&gt;خبر&lt;/b&gt; &amp; آخر*'
    }

    It 'cancels without adding' {
        Complete-NewsTickerAddText -ChatId 42 -UserId 42 -Value "أ`nب"
        Complete-NewsPaste -ChatId 42 -UserId 42 -Cancel
        $script:NewsTickerDraft.Items | Should -Be @('قديم')
        Get-PendingState -ChatId 42 | Should -BeNullOrEmpty
    }

    It 'refuses a stale confirm from someone whose review is not open' {
        Complete-NewsPaste -ChatId 42 -UserId 42
        $script:NewsTickerDraft.Items | Should -Be @('قديم')
        $script:pasteSent[-1].Text | Should -Be (T 'news.paste.gone')
    }

    It 'routes the review buttons' {
        Mock Complete-NewsPaste { }
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        foreach ($data in 'news:pasteok', 'news:pastecancel') {
            Invoke-CallbackQuery -CallbackQuery ([pscustomobject]@{ id = 'p'; from = [pscustomobject]@{ id = 42 }; data = $data
                    message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = 42; type = 'private' } } })
        }
        Should -Invoke Complete-NewsPaste -Times 1 -ParameterFilter { -not $Cancel }
        Should -Invoke Complete-NewsPaste -Times 1 -ParameterFilter { $Cancel }
    }
}

Describe 'The ticker execution log records every publish' {
    <#
        The ticker screen's execution-log button opens the log filtered to
        the ticker. Only the automatic sheet sync wrote there, and this
        station publishes by hand, so the button always said nothing had run.
    #>
    BeforeEach {
        Mock Write-AuditRecord { }
        Mock Write-BridgeExecutionRecord { $true }
    }

    It 'records a draft published from Telegram' {
        Write-NewsPublishRecord -UserId 42 -ItemCount 7
        Should -Invoke Write-BridgeExecutionRecord -Times 1 -ParameterFilter { $Kind -eq 'news' -and $Result -eq 'success' -and $Label -like "$(T 'news.execDraft' '*')" }
    }

    It 'records a manual sheet pull and an automatic one apart' {
        Write-NewsPublishRecord -UserId 42 -ItemCount 3 -Source sheet
        Write-NewsPublishRecord -UserId 0 -ItemCount 3 -Source auto
        Should -Invoke Write-BridgeExecutionRecord -Times 1 -ParameterFilter { $Label -like "$(T 'news.execSheet' '*')" }
        Should -Invoke Write-BridgeExecutionRecord -Times 1 -ParameterFilter { $Label -like "$(T 'tick.sheetSync' '*')" }
    }

    It 'writes one line, not two, when the automatic sync publishes' {
        Mock Get-Setting { 'auto' } -ParameterFilter { $Name -eq 'NewsSheetSyncMode' }
        Mock Get-Setting { 'https://sheet.example/x.csv' } -ParameterFilter { $Name -eq 'NewsSheetCsvUrl' }
        Mock Get-SettingInt { 5 }
        Mock Invoke-NewsSheetSync { Write-NewsPublishRecord -UserId 0 -ItemCount 2 -Source auto; [pscustomobject]@{ Success = $true; Items = @('a', 'b'); Unchanged = $false; Skipped = $false; Error = '' } }
        Mock Write-BridgeLog { }
        $script:NewsSheetLastSyncAt = $null
        Update-NewsSheetSync
        Should -Invoke Write-BridgeExecutionRecord -Times 1 -Exactly
    }
}

Describe 'The news management screen shows what is being worked on' {
    <#
        Measured against the bulletin and boards screens. The news screen sent
        a new message on every tap, listed the live ticker while the operator
        edited a draft (the draft was one line with a count), put publish
        under five other rows, and printed each headline whole - eight of up
        to a thousand characters.
    #>
    BeforeEach {
        $script:NewsTickerDraft = $null
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('على الهواء', 'سيُحذف'); Error = '' } }
        Mock Send-TelegramMessage { }
        Mock Edit-TelegramMessageText { $true }
        Mock Test-Admin { $false }
        Mock Get-NewsLockReservation { $null }
    }
    AfterEach { $script:NewsTickerDraft = $null }

    It 'redraws the screen it was pressed on, as text when the table is refused' {
        # The refresh mark must survive a refused table so the text fallback
        # still lands on the same message.
        Mock Send-TelegramRichMessage { $false }
        Mock Send-TelegramMessage { $script:targetAtText = $script:RefreshTarget }
        $script:targetAtText = $null
        Show-NewsTickerManagementScreen -ChatId 42 -UserId 42 -MessageId 7
        $script:targetAtText.MessageId | Should -Be 7 -Because 'the text version is what consumes the mark and edits message 7'
        $script:RefreshTarget = $null
    }

    It 'redraws the screen it was pressed on as a table' {
        Mock Edit-TelegramRichMessage { $true }
        Show-NewsTickerManagementScreen -ChatId 42 -UserId 42 -MessageId 7
        Should -Invoke Edit-TelegramRichMessage -Times 1 -ParameterFilter { $MessageId -eq 7 -and @($Blocks | Where-Object { $_.type -eq 'table' }).Count -eq 1 }
        Should -Invoke Send-TelegramMessage -Times 0
    }

    It 'keeps the refresh mark when a rich edit is refused, for the text that follows' {
        Mock Edit-TelegramRichMessage { $false }
        Mock Test-RichBlocksSendable { $true }
        Mock ConvertTo-RichMessagePayload { '{}' }
        Mock Test-RichPayloadSize { $false }
        $script:RefreshTarget = @{ ChatId = 42; MessageId = 7 }
        Send-TelegramRichMessage -ChatId 42 -Blocks @(@{ type = 'paragraph'; text = 'x' }) | Should -BeFalse
        $script:RefreshTarget.MessageId | Should -Be 7
        $script:RefreshTarget = $null
    }

    It 'shows the owner their draft, marking what is new against the air' {
        $script:NewsTickerDraft = @{ OwnerUserId = 42; OwnerChatId = 42; Items = @('جديد', 'على الهواء'); UpdatedAt = (Get-Date).ToString('o') }
        Show-NewsTickerManagementScreen -ChatId 42 -UserId 42
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter {
            $Text -like '*🆕 جديد*' -and $Text -like '*على الهواء*' -and $Text -like "*$(T 'news.draftRemoves' 1)*" -and $Text -notlike '*سيُحذف*'
        }
    }

    It 'still shows the live ticker to someone without the draft' {
        $script:NewsTickerDraft = @{ OwnerUserId = 99; OwnerChatId = 99; Items = @('مسودة غيري'); UpdatedAt = (Get-Date).ToString('o') }
        Show-NewsTickerManagementScreen -ChatId 42 -UserId 42
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $Text -like '*سيُحذف*' -and $Text -notlike '*مسودة غيري*' }
    }

    It 'cuts a long headline on the screen' {
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('ك' * 500); Error = '' } }
        Show-NewsTickerManagementScreen -ChatId 42 -UserId 42
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $Text.Length -lt 300 -and $Text -like '*…*' }
    }

    It 'puts publish first for the draft owner' {
        $script:NewsTickerDraft = @{ OwnerUserId = 42; OwnerChatId = 42; Items = @('أ'); UpdatedAt = (Get-Date).ToString('o') }
        $first = @(@((Get-NewsTickerManagementKeyboard -ChatId 42 -UserId 42).inline_keyboard)[0] | ForEach-Object { $_['callback_data'] })
        $first | Should -Contain 'news:publish'
    }

    It 'passes the pressed message through refresh and the main-menu door' {
        Mock Show-NewsTickerManagementScreen { }
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        foreach ($data in 'news:refresh', 'menu:news') {
            Invoke-CallbackQuery -CallbackQuery ([pscustomobject]@{ id = 'n'; from = [pscustomobject]@{ id = 42 }; data = $data
                    message = [pscustomobject]@{ message_id = 55; chat = [pscustomobject]@{ id = 42; type = 'private' } } })
        }
        Should -Invoke Show-NewsTickerManagementScreen -Times 2 -Exactly -ParameterFilter { $MessageId -eq 55 }
    }
}

Describe 'Pausing a headline without deleting it' {
    <#
        Borrowed from the programme boards' on/off row. A headline taken off
        the ticker for an hour was deleted and typed again. It now goes to a
        shelf that outlives the draft - the draft is removed on publish - and
        comes back from there.
    #>
    BeforeEach {
        $script:newsPausedFile = Join-Path $TestDrive 'news-paused.json'
        Remove-Item -LiteralPath $script:newsPausedFile -ErrorAction SilentlyContinue
        $script:NewsPaused = [System.Collections.Generic.List[string]]::new()
        $script:NewsTickerDraft = @{ OwnerUserId = 42; OwnerChatId = 42; Items = @('أ', 'ب', 'ج'); UpdatedAt = (Get-Date).ToString('o') }
        Mock Save-NewsTickerDraft { $true }
        Mock Send-TelegramMessage { }
        Mock Edit-TelegramMessageText { $true }
        Mock Write-BridgeLog { }
    }
    AfterEach { $script:NewsTickerDraft = $null; $script:NewsPaused = [System.Collections.Generic.List[string]]::new() }

    It 'moves a headline from the draft to the shelf, and keeps it across a restart' {
        Suspend-NewsTickerDraftItem -UserId 42 -Index 1 | Should -BeTrue
        $script:NewsTickerDraft.Items | Should -Be @('أ', 'ج')
        @($script:NewsPaused) | Should -Be @('ب')
        $script:NewsPaused = [System.Collections.Generic.List[string]]::new()
        Import-NewsPaused
        @($script:NewsPaused) | Should -Be @('ب')
    }

    It 'says so in the log when the shelf cannot be written' {
        Mock Write-BridgeValidatedJson { $false }
        Save-NewsPaused | Should -BeFalse
        Should -Invoke Write-BridgeLog -Times 1 -ParameterFilter { $Message -like '*news-paused.json*' -and $Level -eq 'WARN' }
    }

    It 'brings a paused headline back into a draft' {
        Suspend-NewsTickerDraftItem -UserId 42 -Index 1 | Out-Null
        $config.Settings | Add-Member NewNewsItemAtTop $true -Force
        Resume-NewsPausedItem -UserId 42 -Index 0 | Should -BeTrue
        $script:NewsTickerDraft.Items | Should -Be @('ب', 'أ', 'ج')
        @($script:NewsPaused).Count | Should -Be 0
    }

    It 'refuses to pause from a draft that is not yours' {
        Suspend-NewsTickerDraftItem -UserId 7 -Index 0 | Should -BeFalse
        $script:NewsTickerDraft.Items.Count | Should -Be 3
    }

    It 'offers the shelf on the management screen only when it holds something' {
        Mock Get-NewsLockReservation { $null }
        Mock Test-Admin { $false }
        $none = @((Get-NewsTickerManagementKeyboard -ChatId 42 -UserId 42).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $none | Should -Not -Contain 'news:paused'
        Suspend-NewsTickerDraftItem -UserId 42 -Index 0 | Out-Null
        $some = @((Get-NewsTickerManagementKeyboard -ChatId 42 -UserId 42).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $some | Should -Contain 'news:paused'
    }

    It 'puts the pause button on a headline''s own screen' {
        Show-NewsTickerItemScreen -ChatId 42 -UserId 42 -Index 0
        Should -Invoke Send-TelegramMessage -ParameterFilter { @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) -contains 'news:pause:0' }
    }
}

Describe 'The paused shelf pages' {
    It 'shows ten to a page with a pager, and the second page from its button' {
        $script:NewsPaused = [System.Collections.Generic.List[string]]::new()
        1..25 | ForEach-Object { $script:NewsPaused.Add("خبر $_") }
        Mock Send-TelegramMessage { $script:pausedMarkup = $ReplyMarkup }
        Show-NewsPausedScreen -ChatId 42 -Page 1
        $data = @($script:pausedMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $data | Should -Contain 'news:unpause:10'
        $data | Should -Not -Contain 'news:unpause:0'
        $data | Should -Contain 'news:pausedp:2'
        $script:NewsPaused = [System.Collections.Generic.List[string]]::new()
    }
}

Describe 'Publishing the ticker at a set time' {
    <#
        Borrowed from the bulletin's "run later": prepare the evening ticker
        in the afternoon and let it go out at 18:00. The time rides the draft
        itself, and the tick publishes through Publish-NewsTickerDraft - one
        publish path, with its conflict check, audit, sheet mirror and notice.
    #>
    BeforeEach {
        $script:NewsTickerDraft = @{ OwnerUserId = 42; OwnerChatId = 42; Items = @('أ'); BaseHash = 'h'; UpdatedAt = (Get-Date).ToString('o') }
        Mock Save-NewsTickerDraft { $true }
        Mock Send-TelegramMessage { }
        Mock Add-AuditEntry { }
        Mock Write-BridgeLog { }
        Mock Write-BridgeExecutionRecord { $true }
    }
    AfterEach { $script:NewsTickerDraft = $null }

    It 'sets a publish time on the owner''s draft, and only in the future' {
        Set-NewsPublishAt -UserId 42 -At ([datetimeoffset]::Now.AddMinutes(30)) | Should -BeTrue
        [string]$script:NewsTickerDraft.PublishAt | Should -Not -BeNullOrEmpty
        Set-NewsPublishAt -UserId 42 -At ([datetimeoffset]::Now.AddMinutes(-5)) | Should -BeFalse
        Set-NewsPublishAt -UserId 7 -At ([datetimeoffset]::Now.AddMinutes(30)) | Should -BeFalse -Because 'not their draft'
    }

    It 'publishes through the normal path when the time comes, not before' {
        Mock Publish-NewsTickerDraft { [pscustomobject]@{ Success = $true; Conflict = $false; Error = '' } }
        $script:NewsTickerDraft.PublishAt = [datetimeoffset]::Now.AddMinutes(10).ToString('o')
        Update-NewsScheduledPublish
        Should -Invoke Publish-NewsTickerDraft -Times 0
        $script:NewsTickerDraft.PublishAt = [datetimeoffset]::Now.AddSeconds(-1).ToString('o')
        Update-NewsScheduledPublish
        Should -Invoke Publish-NewsTickerDraft -Times 1 -ParameterFilter { $UserId -eq 42 }
    }

    It 'tells the owner and keeps the draft when the ticker moved on meanwhile' {
        Mock Publish-NewsTickerDraft { [pscustomobject]@{ Success = $false; Conflict = $true; Error = 'changed' } }
        $script:NewsTickerDraft.PublishAt = [datetimeoffset]::Now.AddSeconds(-1).ToString('o')
        Update-NewsScheduledPublish
        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
        $script:NewsTickerDraft.ContainsKey('PublishAt') | Should -BeFalse -Because 'a failed time is cleared, not retried every tick'
        Should -Invoke Send-TelegramMessage -ParameterFilter { $ChatId -eq 42 }
        Should -Invoke Write-BridgeExecutionRecord -ParameterFilter { $Kind -eq 'news' -and $Result -eq 'failed' }
    }

    It 'does not publish a draft handed over to everyone on the scheduler''s behalf' {
        Mock Publish-NewsTickerDraft { }
        $script:NewsTickerDraft.IsOpen = $true
        $script:NewsTickerDraft.PublishAt = [datetimeoffset]::Now.AddSeconds(-1).ToString('o')
        Update-NewsScheduledPublish
        Should -Invoke Publish-NewsTickerDraft -Times 0
        $script:NewsTickerDraft.ContainsKey('PublishAt') | Should -BeFalse
    }

    It 'does not expire a draft that is waiting for its time' {
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'NewsDraftTimeoutMinutes' }
        Mock Remove-NewsTickerDraft { $script:removedScheduled = $true }
        $script:removedScheduled = $false
        $script:NewsTickerDraft.UpdatedAt = (Get-Date).AddHours(-3).ToString('o')
        $script:NewsTickerDraft.PublishAt = [datetimeoffset]::Now.AddHours(1).ToString('o')
        Update-NewsDraftExpiry
        $script:removedScheduled | Should -BeFalse
    }

    It 'offers the time on the owner''s screen, and its cancel once set' {
        Mock Get-NewsLockReservation { $null }
        Mock Test-Admin { $false }
        $before = @((Get-NewsTickerManagementKeyboard -ChatId 42 -UserId 42).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $before | Should -Contain 'news:later'
        $script:NewsTickerDraft.PublishAt = [datetimeoffset]::Now.AddHours(1).ToString('o')
        $after = @((Get-NewsTickerManagementKeyboard -ChatId 42 -UserId 42).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $after | Should -Contain 'news:latercancel'
    }
}

Describe 'Saved ticker sets' {
    <#
        Borrowed from the bulletin's library. A station that runs a normal
        ticker and an election ticker rebuilt one from the other by hand, or
        dug through the backups. A set is a named list of headlines kept apart
        from the draft, which is removed on publish.
    #>
    BeforeEach {
        $script:newsSetsFile = Join-Path $TestDrive 'news-sets.json'
        Remove-Item -LiteralPath $script:newsSetsFile -ErrorAction SilentlyContinue
        $script:NewsSets = [System.Collections.Generic.List[object]]::new()
        $script:NewsTickerDraft = @{ OwnerUserId = 42; OwnerChatId = 42; Items = @('أ', 'ب'); UpdatedAt = (Get-Date).ToString('o') }
        Mock Save-NewsTickerDraft { $true }
        Mock Send-TelegramMessage { $script:setsMarkup = $ReplyMarkup }
        Mock Edit-TelegramMessageText { $script:setsMarkup = $ReplyMarkup; $true }
        Mock Add-AuditEntry { }
        Mock Write-BridgeLog { }
        Mock Test-Admin { $false }
    }
    AfterEach { $script:NewsTickerDraft = $null; $script:NewsSets = [System.Collections.Generic.List[object]]::new() }

    It 'saves the draft under a name, and keeps it across a restart' {
        Save-NewsSetFromDraft -UserId 42 -Name 'الانتخابات' | Should -BeTrue
        $script:NewsSets = [System.Collections.Generic.List[object]]::new()
        Import-NewsSets
        $script:NewsSets[0].Name | Should -Be 'الانتخابات'
        @($script:NewsSets[0].Items) | Should -Be @('أ', 'ب')
    }

    It 'replaces a set of the same name rather than keeping two' {
        Save-NewsSetFromDraft -UserId 42 -Name 'عادي' | Out-Null
        $script:NewsTickerDraft.Items = @('ج')
        Save-NewsSetFromDraft -UserId 42 -Name 'عادي' | Out-Null
        $script:NewsSets.Count | Should -Be 1
        @($script:NewsSets[0].Items) | Should -Be @('ج')
    }

    It 'loads a set into the owner''s draft, and only theirs' {
        Save-NewsSetFromDraft -UserId 42 -Name 'عادي' | Out-Null
        $script:NewsTickerDraft.Items = @('غيره')
        Use-NewsSet -UserId 7 -Index 0 | Should -BeFalse
        Use-NewsSet -UserId 42 -Index 0 | Should -BeTrue
        $script:NewsTickerDraft.Items | Should -Be @('أ', 'ب')
    }

    It 'lets only the saver or an administrator delete a set' {
        Save-NewsSetFromDraft -UserId 42 -Name 'عادي' | Out-Null
        Remove-NewsSet -ChatId 7 -UserId 7 -Index 0 | Should -BeFalse
        $script:NewsSets.Count | Should -Be 1
        Remove-NewsSet -ChatId 42 -UserId 42 -Index 0 | Should -BeTrue
        $script:NewsSets.Count | Should -Be 0
    }

    It 'refuses a twenty-first set, and an empty name' {
        1..20 | ForEach-Object { Save-NewsSetFromDraft -UserId 42 -Name "م $_" | Out-Null }
        Save-NewsSetFromDraft -UserId 42 -Name 'زائدة' | Should -BeFalse
        Save-NewsSetFromDraft -UserId 42 -Name "`u{200F} " | Should -BeFalse
    }

    It 'lists the sets paged, with load and a confirmed delete' {
        1..12 | ForEach-Object { $script:NewsSets.Add([pscustomobject]@{ Name = "م $_"; Items = @('x'); SavedBy = 42; SavedAt = '' }) }
        Show-NewsSetsScreen -ChatId 42 -UserId 42 -Page 0
        $data = @($script:setsMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $data | Should -Contain 'news:setload:0'
        $data | Should -Contain 'news:setdelask:0'
        $data | Should -Contain 'news:setsp:1'
        $data | Should -Contain 'news:setsave'
    }
}
