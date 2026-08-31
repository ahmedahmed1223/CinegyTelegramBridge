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
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
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

Describe 'News draft expiry' {
    BeforeEach {
        $script:NewsTickerDraft = $null
        Mock Write-BridgeLog {}
        Mock Send-TelegramMessage {}
        Mock Remove-NewsTickerDraft { $script:NewsTickerDraft = $null }
        Mock Get-SettingInt { 30 } -ParameterFilter { $Name -eq 'NewsDraftTimeoutMinutes' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

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

Describe 'News lock hand-over' {
    BeforeEach {
        $script:NewsLockRequest = $null
        $script:NewsTickerDraft = @{ OwnerUserId = 20; OwnerChatId = 20; Items = @('أ', 'ب'); UpdatedAt = (Get-Date).ToString('o') }
        Mock Send-TelegramMessage {}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Get-UserDisplayName { "user$UserId" }
        Mock Get-NewsTickerManagementKeyboard { @{ inline_keyboard = @() } }
        Mock Remove-NewsTickerDraft { $script:NewsTickerDraft = $null }
        Mock Get-SettingInt { 5 } -ParameterFilter { $Name -eq 'NewsLockRequestMinutes' }
    }
    AfterAll { $script:NewsTickerDraft = $null; $script:NewsLockRequest = $null }

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
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.callback_data } }) -contains 'news:item:2'
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
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        foreach ($i in 0..2) { $flat | Should -Contain "news:delask:$i" }
    }

    It 'routes through the same confirmation the item screen uses' {
        # A second delete path would be a second place for a thumb to lose
        # typed work.
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $flat | Should -Not -Contain 'news:delete:0'
    }

    It 'keeps the move and edit controls alongside it' {
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $middle = @($rows[1] | ForEach-Object { $_.callback_data })
        $middle | Should -Contain 'news:up:1'
        $middle | Should -Contain 'news:item:1'
        $middle | Should -Contain 'news:down:1'
        $middle | Should -Contain 'news:delask:1'
    }

    It 'shows nothing to delete when there is no draft' {
        $script:NewsTickerDraft = $null
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
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
        $middle = @($rows[1] | ForEach-Object { $_.callback_data })
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
        $controls = @($rows[3] | ForEach-Object { $_.callback_data })
        $controls | Should -Contain 'news:up:1'
        $controls | Should -Contain 'news:down:1'
        $controls | Should -Contain 'news:edit:1'
        $controls | Should -Contain 'news:delask:1'
    }

    It 'omits the move it cannot make, at either end' {
        Mock Get-Setting { 'stacked' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        @($rows[1] | ForEach-Object { $_.callback_data }) | Should -Not -Contain 'news:up:0'
        @($rows[5] | ForEach-Object { $_.callback_data }) | Should -Not -Contain 'news:down:2'
    }

    It 'shows more of a long headline when it owns the row' {
        Mock Get-Setting { 'stacked' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $stacked = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[2][0].text
        Mock Get-Setting { 'text' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        $inline = @(@((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[1] | Where-Object { $_.callback_data -eq 'news:item:1' })[0].text
        $stacked.Length | Should -BeGreaterThan $inline.Length
    }

    It 'still deletes through the confirmation in both layouts' {
        foreach ($layout in @('text', 'stacked', 'inline')) {
            Mock Get-Setting { $layout } -ParameterFilter { $Name -eq 'NewsListLayout' }
            $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
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
        @($rows[0] | ForEach-Object { $_.callback_data }) | Should -Contain 'news:noop'
        @($rows[2] | ForEach-Object { $_.callback_data }) | Should -Contain 'news:noop'
    }

    It 'carries the headline in the message text, uncut, instead of a button' {
        $text = Get-NewsTickerReorderText -UserId 42

        $text | Should -Match ([regex]::Escape('2. خبر ثانٍ طويل جدًا يتجاوز أي حدّ كان يُقصّ عنده في زر ضيق'))
        @(@((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[1] |
            Where-Object { $_.callback_data -eq 'news:item:1' })[0].text | Should -Be '2'
    }

    It 'keeps the listing inside one Telegram message for a full page' {
        $script:NewsTickerDraft.Items = @(1..21 | ForEach-Object { "خبر رقم $_ " + ('ط' * 400) })
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }

        (Get-NewsTickerReorderText -UserId 42).Length | Should -BeLessThan 4096
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
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

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
                    ForEach-Object { @($_) | ForEach-Object { $_.callback_data } } |
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
                ForEach-Object { @($_) } | Where-Object { $_.callback_data -like 'news:item:*' })
        $labels[0].text | Should -Be '21'
        $labels[0].callback_data | Should -Be 'news:item:20'
    }

    It 'offers forward and back only where they exist' {
        $firstPage = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 0).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $firstPage | Should -Not -Contain 'news:list:-1'
        $firstPage | Should -Contain 'news:list:1'

        $lastPage = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 3).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $lastPage | Should -Contain 'news:list:2'
        $lastPage | Should -Not -Contain 'news:list:4'
    }

    It 'clamps a page number that is out of range instead of rendering nothing' {
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 99).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $flat | Should -Contain 'news:item:37'
    }

    It 'shows no pager at all when everything fits on one page' {
        $script:NewsTickerDraft.Items = @('واحد', 'اثنان')
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 0).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        ($flat -join ' ') | Should -Not -Match 'news:list:'
    }

    It 'states the range and total in the heading' {
        $text = Get-NewsTickerReorderText -UserId 42 -Page 1
        $text | Should -Match 'الأخبار: 38'
        $text | Should -Match '11'
        $text | Should -Match 'صفحة 2 من 4'
    }

    It 'keeps the move controls absolute, so paging never moves the wrong item' {
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 1).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
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

    It 'offers exactly the three shapes, and falls back to text for anything else' {
        $script:SettingChoices['NewsListLayout'] | Should -Be @('text', 'stacked', 'inline')

        Mock Get-Setting { 'nonsense' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        Get-NewsListLayout | Should -Be 'text'
    }

    It 'puts the headline in the row itself when inline is chosen' {
        Mock Get-Setting { 'inline' } -ParameterFilter { $Name -eq 'NewsListLayout' }
        Mock Get-SettingInt { 24 } -ParameterFilter { $Name -eq 'NewsListLabelLength' }
        Mock Get-SettingInt { 10 } -ParameterFilter { $Name -eq 'NewsListPageSize' }
        Mock Get-SettingInt { 60 } -ParameterFilter { $Name -eq 'NewsListStackedLabelLength' }

        $label = @(@((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[1] |
            Where-Object { $_.callback_data -eq 'news:item:1' })[0].text

        $label | Should -Match 'خبر ثانٍ'
        Get-NewsTickerReorderText -UserId 42 | Should -Not -Match '2\. خبر ثانٍ'
    }

    It 'reaches every item in all three shapes' {
        foreach ($layout in @('text', 'stacked', 'inline')) {
            Mock Get-Setting { $layout } -ParameterFilter { $Name -eq 'NewsListLayout' }
            $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
            foreach ($i in 0..2) { $flat | Should -Contain "news:item:$i" }
        }
    }
}
