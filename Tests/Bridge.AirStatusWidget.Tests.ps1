#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Telegram air monitoring card' {
    BeforeEach {
        $script:AirStatusWidgets = @{}
        $script:MainMenuWidgets = @{}
        $script:AirStatusWidgetUnavailable = $false
        $script:AirStatusWidgetUpdate = $null
        $script:AirStatusWidgetAnswers = [Collections.Generic.List[hashtable]]::new()
        $script:TelegramOutboxNotBefore = [datetime]::MinValue
        $script:RuntimeState = New-BridgeRuntimeState
        $script:OnAir = @{ 4 = @{ Key = 'Urgent' } }
        $script:AutoHideQueue = [Collections.Generic.List[hashtable]]::new()
        $script:widgetNow = [datetime]'2026-11-11T14:00:00'
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = $script:widgetNow
        $script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
        Mock Test-Authorized { $true }
        Mock Test-StatusViewer { $true }
        Mock Confirm-TelegramCallback { }
        Mock Update-UserNameFromTelegram { }
        Mock Update-UserLastActivity { }
        Mock Write-BridgeLog { }
        Mock Send-TelegramMessage { }
        Mock Invoke-BridgeTelegramRequest {
            [pscustomobject]@{ Success = $true; Response = @{ ok = $true; result = @{ message_id = 76 } } }
        }
        Mock Start-BridgeTelegramRequestWorker { @{ Simulated = $true } }
        Mock Receive-BridgeTelegramRequestWorker { [pscustomobject]@{ Success = $true; Response = @{ ok = $true; result = $true } } }
    }

    It 'opens from a private callback and sends a protected read-only widget' {
        Invoke-CallbackQuery @{ id = 'open'; from = @{ id = 101 }; message = @{ chat = @{ id = 101; type = 'private' } }; data = 'menu:airwidget' }

        Should -Invoke Invoke-BridgeTelegramRequest -Exactly -Times 1 -ParameterFilter {
            $Uri -like '*/sendWidget' -and $Body.chat_id -eq 101 -and $Body.protect_content -and
                $Body.html -match 'chatDataChanged' -and $Body.html -match "showFeedback\(''\)" -and $Body.html -match 'widget\.request\(copy\.kind\)' -and $Body.html -match '"kind":"r:c"' -and
                $Body.caption -and $Body.allow_queries -and -not $Body.ContainsKey('public_data')
        }
        $script:AirStatusWidgets[[long]101].MessageId | Should -Be 76
    }

    It 'rejects operators and group presses before sending a card' {
        Mock Test-StatusViewer { $false }
        Invoke-CallbackQuery @{ id = 'operator'; from = @{ id = 101 }; message = @{ chat = @{ id = 101; type = 'private' } }; data = 'menu:airwidget' }
        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $CallbackQueryId -eq 'operator' -and $Alert }

        Mock Test-StatusViewer { $true }
        Invoke-CallbackQuery @{ id = 'group'; from = @{ id = 101 }; message = @{ chat = @{ id = -100101; type = 'supergroup' } }; data = 'menu:airwidget' }
        Should -Invoke Invoke-BridgeTelegramRequest -Exactly -Times 0
    }

    It 'sends a text snapshot when Telegram refuses the widget' {
        Mock Invoke-BridgeTelegramRequest { [pscustomobject]@{ Success = $false; StatusCode = 404 } }
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow

        Should -Invoke Send-TelegramMessage -Exactly -Times 1 -ParameterFilter { $ChatId -eq 101 -and $Text -match 'Urgent' -and $Text -match '14:00:00' }
        $script:AirStatusWidgets.Count | Should -Be 0
    }

    It 'edits the original message for a new state and skips unchanged data' {
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(5)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 0

        $script:OnAir[4].Key = 'Next'
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(10)
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(15)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/editMessageWidgetData' -and $Request.Body.chat_id -eq 101 -and
                $Request.Body.message_id -eq 76 -and $Request.Body.chat_data -match 'Next'
        }
        $script:AirStatusWidgets[[long]101].LastData | Should -Match 'Next'
    }

    It 'honors Telegram retry-after and sends the latest state after the delay' {
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow
        $script:OnAir[4].Key = 'First change'
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(5)
        Mock Receive-BridgeTelegramRequestWorker { [pscustomobject]@{ Success = $false; StatusCode = 429; RetryAfterMs = 20000 } }
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(10)

        $script:OnAir[4].Key = 'Latest change'
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(29)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(30)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter { $Request.Body.chat_data -match 'Latest change' }
    }

    It 'stops refreshing after expiry or a role change' {
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow
        Show-AirStatusWidget -ChatId 102 -UserId 102 -Now $script:widgetNow.AddMinutes(5)
        Mock Test-StatusViewer { $false } -ParameterFilter { $ChatId -eq 102 }
        $script:OnAir[4].Key = 'Changed'
        Update-AirStatusWidgets -Now $script:widgetNow.AddMinutes(30)

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 0
        $script:AirStatusWidgets.Count | Should -Be 0
    }

    It 'bounds UTF-8 data, counts hidden layers, and flags an unsuccessful check' {
        $script:OnAir.Clear()
        foreach ($layer in 1..12) { $script:OnAir[$layer] = @{ Key = ('📰' * 150) } }
        $script:RuntimeState.Monitoring.LastCinegyStateFailedCount = 1
        $encoded = Get-AirStatusWidgetData -ExpiresAt $script:widgetNow.AddMinutes(30)
        $snapshot = $encoded | ConvertFrom-Json

        [Text.Encoding]::UTF8.GetByteCount($encoded) | Should -BeLessOrEqual 1024
        $snapshot.rows.Count | Should -BeGreaterThan 0
        $snapshot.rows[0].name.Length | Should -BeLessOrEqual 49
        ($snapshot.rows.Count + $snapshot.hidden) | Should -Be 12
        $snapshot.freshUntil | Should -Be 0
    }

    It 'answers an HTML refresh with the latest data only for the active private card' {
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow
        $script:OnAir[4].Key = 'Current title'
        $query = @{ id = 'refresh-1'; from = @{ id = 101 }; chat = @{ id = 101; type = 'private' }
            message_id = 76; type = @{ type = 'data' }; data = 'r:c' }

        Invoke-AirStatusWidgetQuery -Query $query -Now $script:widgetNow.AddSeconds(5)
        $query.id = 'refresh-2'
        $query.message_id = 75
        Invoke-AirStatusWidgetQuery -Query $query -Now $script:widgetNow.AddSeconds(5)
        $query.id = 'refresh-3'
        $query.message_id = 76
        Mock Test-StatusViewer { $false }
        Invoke-AirStatusWidgetQuery -Query $query -Now $script:widgetNow.AddSeconds(5)

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/answerWidgetQuery' -and $Request.Body.widget_query_id -eq 'refresh-1' -and $Request.Body.data -match 'Current title'
        }
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 2 -ParameterFilter {
            $Request.Uri -like '*/answerWidgetQuery' -and $Request.Body.widget_query_id -in @('refresh-2', 'refresh-3') -and
                -not $Request.Body.ContainsKey('data')
        }
    }

    It 'requests widget queries from the first long poll' {
        Mock Invoke-RestMethod { @{ ok = $true; result = @() } }
        Get-TelegramUpdates -Offset 0 -TimeoutSeconds 1 | Out-Null

        Should -Invoke Invoke-RestMethod -Exactly -Times 1 -ParameterFilter {
            [Uri]::UnescapeDataString([string]$Uri) -like '*allowed_updates=[[]"message","callback_query","widget_query"[]]'
        }
    }

    It 'puts a live header and the existing menu buttons in one message for a regular operator' {
        Mock Test-StatusViewer { $false }
        Mock Send-TelegramRichMessage { $true }
        Show-MainMenuScreen -ChatId 101 -UserId 101 -Intro 'Welcome'

        Should -Invoke Invoke-BridgeTelegramRequest -Exactly -Times 1 -ParameterFilter {
            $Uri -like '*/sendWidget' -and $Body.html -match 'Welcome' -and
                $Body.caption -match 'Urgent' -and $Body.reply_markup -match 'menu:status'
        }
        Should -Invoke Send-TelegramRichMessage -Exactly -Times 0
        $script:MainMenuWidgets[[long]101].MessageId | Should -Be 76
        $script:AirStatusWidgets.Count | Should -Be 0
    }

    It 'keeps the current menu screen as the fallback if Telegram refuses the live header' {
        Mock Invoke-BridgeTelegramRequest { [pscustomobject]@{ Success = $false; StatusCode = 404 } }
        Mock Send-TelegramRichMessage { $false }
        Show-MainMenuScreen -ChatId 101 -UserId 101 -Intro 'Welcome'

        Should -Invoke Send-TelegramMessage -Exactly -Times 1 -ParameterFilter {
            $Text -match 'Welcome' -and $Text -match 'Urgent' -and
                @($ReplyMarkup.inline_keyboard | ForEach-Object { $_ } | ForEach-Object callback_data) -contains 'menu:status'
        }
        $script:MainMenuWidgets.Count | Should -Be 0
    }

    It 'updates the menu header even without a status-viewer role and never replaces its keyboard' {
        Mock Test-StatusViewer { $false }
        Show-MainMenuScreen -ChatId 101 -UserId 101
        $openedAt = $script:MainMenuWidgets[[long]101].ExpiresAt.AddMinutes(-30)
        $script:OnAir[4].Key = 'Next'
        Update-AirStatusWidgets -Now $openedAt.AddSeconds(6)

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/editMessageWidgetData' -and $Request.Body.message_id -eq 76 -and
                $Request.Body.chat_data -match 'Next' -and -not $Request.Body.ContainsKey('reply_markup')
        }
        $query = @{ id = 'menu-refresh'; from = @{ id = 101 }; chat = @{ id = 101; type = 'private' }
            message_id = 76; type = @{ type = 'data' }; data = 'r:m' }
        Invoke-AirStatusWidgetQuery -Query $query -Now $openedAt.AddSeconds(7)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/answerWidgetQuery' -and $Request.Body.widget_query_id -eq 'menu-refresh' -and $Request.Body.data -match 'Next'
        }
    }

    It 'continues updating both the main menu and the detailed card in the same chat' {
        Mock Invoke-BridgeTelegramRequest {
            [pscustomobject]@{ Success = $true; Response = @{ ok = $true; result = @{ message_id = 77 } } }
        } -ParameterFilter { $Uri -like '*/sendWidget' -and $Body.reply_markup -match 'menu:more' }
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow
        $keyboard = Get-MainMenuKeyboard -ChatId 101 -UserId 101 -Compact
        Send-MainMenuWidget -ChatId 101 -UserId 101 -Keyboard $keyboard -Now $script:widgetNow | Should -BeTrue

        $script:OnAir[4].Key = 'Next'
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(5)
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(6)

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter { $Request.Body.message_id -eq 76 }
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter { $Request.Body.message_id -eq 77 }
    }

    It 'opens a menu action without trying to edit a widget as a text screen' {
        Invoke-CallbackQuery @{ id = 'more'; from = @{ id = 101 }; message = @{
                chat = @{ id = 101; type = 'private' }; message_id = 76; widget = @{ html = '<p>Menu</p>' }
            }; data = 'menu:more' }

        $script:RefreshTarget | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Exactly -Times 1 -ParameterFilter { $Text -eq (T 'menu.moreTitle') }
    }

    It 'refuses an old hide button if the live header now shows a different scene' {
        $script:OnAir[4].At = $script:widgetNow
        Show-MainMenuScreen -ChatId 101 -UserId 101
        $script:OnAir[4].Key = 'Replacement'
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Invoke-HideLayer { throw 'a stale press must not reach playout' }
        Invoke-CallbackQuery @{ id = 'old-hide'; from = @{ id = 101 }; message = @{
                chat = @{ id = 101; type = 'private' }; message_id = 76
            }; data = 'hide:4:menu' }

        Should -Invoke Invoke-HideLayer -Exactly -Times 0
        Should -Invoke Confirm-TelegramCallback -Exactly -Times 1 -ParameterFilter { $CallbackQueryId -eq 'old-hide' -and $Alert }
    }

    It 'brings a menu the bridge forgot back to life when it asks, without trusting its old layer buttons' {
        Mock Test-StatusViewer { $false }
        $query = @{ id = 'revive'; from = @{ id = 101 }; chat = @{ id = 101; type = 'private' }
            message_id = 90; type = @{ type = 'data' }; data = 'r:m' }
        Invoke-AirStatusWidgetQuery -Query $query -Now $script:widgetNow

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/answerWidgetQuery' -and $Request.Body.widget_query_id -eq 'revive' -and $Request.Body.data -match 'Urgent'
        }
        $script:MainMenuWidgets[[long]101].MessageId | Should -Be 90
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(1)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/editMessageWidgetData' -and $Request.Body.message_id -eq 90
        }

        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Invoke-HideLayer { throw 'a revived menu must not reach playout' }
        Invoke-CallbackQuery @{ id = 'revived-hide'; from = @{ id = 101 }; message = @{
                chat = @{ id = 101; type = 'private' }; message_id = 90
            }; data = 'hide:4:menu' }
        Should -Invoke Invoke-HideLayer -Exactly -Times 0
        Should -Invoke Confirm-TelegramCallback -Exactly -Times 1 -ParameterFilter { $CallbackQueryId -eq 'revived-hide' -and $Alert }
    }

    It 'resumes an expired card on its own request and keeps it for another half hour' {
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow
        $later = $script:widgetNow.AddMinutes(45)
        $query = @{ id = 'resume'; from = @{ id = 101 }; chat = @{ id = 101; type = 'private' }
            message_id = 76; type = @{ type = 'data' }; data = 'r:c' }
        Invoke-AirStatusWidgetQuery -Query $query -Now $later

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/answerWidgetQuery' -and $Request.Body.widget_query_id -eq 'resume' -and $Request.Body.ContainsKey('data')
        }
        $script:AirStatusWidgets[[long]101].ExpiresAt | Should -Be $later.AddMinutes(30)
        Update-AirStatusWidgets -Now $later.AddSeconds(1)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter { $Request.Body.message_id -eq 76 }
    }

    It 'gives no data and tracks nothing for a request it cannot place' {
        $base = @{ from = @{ id = 101 }; chat = @{ id = 101; type = 'private' }; message_id = 90; type = @{ type = 'data' }; data = 'r:c' }
        $legacy = $base.Clone(); $legacy.id = 'legacy'; $legacy.data = 'refresh'
        $group = $base.Clone(); $group.id = 'group'; $group.chat = @{ id = -100101; type = 'supergroup' }
        $other = $base.Clone(); $other.id = 'other'; $other.from = @{ id = 202 }
        $wallet = $base.Clone(); $wallet.id = 'wallet'; $wallet.type = @{ type = 'sign_data' }
        foreach ($query in @($legacy, $group, $other, $wallet)) { Invoke-AirStatusWidgetQuery -Query $query -Now $script:widgetNow }
        Mock Test-StatusViewer { $false }
        $operator = $base.Clone(); $operator.id = 'operator'
        Invoke-AirStatusWidgetQuery -Query $operator -Now $script:widgetNow
        Mock Test-Authorized { $false }
        $stranger = $base.Clone(); $stranger.id = 'stranger'; $stranger.data = 'r:m'
        Invoke-AirStatusWidgetQuery -Query $stranger -Now $script:widgetNow

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 6 -ParameterFilter {
            $Request.Uri -like '*/answerWidgetQuery' -and -not $Request.Body.ContainsKey('data')
        }
        $script:AirStatusWidgets.Count | Should -Be 0
        $script:MainMenuWidgets.Count | Should -Be 0
    }

    It 'sends instants for the on-air and auto-hide counters, so a running clock never costs an edit' {
        $shownAt = [datetimeoffset]'2026-11-11T13:58:00+00:00'
        $script:OnAir = @{
            4 = @{ Key = 'Urgent'; At = $shownAt.LocalDateTime }
            5 = @{ Key = 'Ticker'; At = $shownAt.ToString('o') }
            6 = @{ Key = 'Logo' }
        }
        $script:AutoHideQueue.Add(@{ Layer = 4; At = $shownAt.AddMinutes(5) })
        $script:AutoHideQueue.Add(@{ Layer = 5; At = 'not a time' })
        $first = Get-AirStatusWidgetData -ExpiresAt $script:widgetNow.AddMinutes(30)
        $rows = @(($first | ConvertFrom-Json).rows)

        $rows[0].at | Should -Be $shownAt.ToUnixTimeMilliseconds()
        $rows[0].hide | Should -Be $shownAt.AddMinutes(5).ToUnixTimeMilliseconds()
        $rows[1].at | Should -Be $shownAt.ToUnixTimeMilliseconds()
        $rows[1].PSObject.Properties.Name | Should -Not -Contain 'hide'
        $rows[2].PSObject.Properties.Name | Should -Not -Contain 'at'
        ($first | ConvertFrom-Json).lastAt | Should -Be ([datetimeoffset]$script:widgetNow).ToUnixTimeMilliseconds()
        Get-AirStatusWidgetData -ExpiresAt $script:widgetNow.AddMinutes(30) | Should -BeExactly $first
    }

    It 'keeps the HTML inside the limits Telegram enforces, with the longest Arabic header a menu can carry' {
        Mock Get-BridgeLanguage { 'ar' }
        $html = Get-AirStatusWidgetHtml -ForMenu -Intro ('مرحبًا ' * 40) -UserId 101
        $bytes = [Text.Encoding]::UTF8.GetBytes($html)
        $packed = [IO.MemoryStream]::new()
        $zlib = [IO.Compression.ZLibStream]::new($packed, [IO.Compression.CompressionLevel]::SmallestSize)
        $zlib.Write($bytes, 0, $bytes.Length)
        $zlib.Dispose()

        $html | Should -Not -Match "`0"
        $bytes.Length | Should -BeLessOrEqual 32768
        # ponytail: .NET's SmallestSize stands in for the server's zlib level 9;
        # the margin below covers the difference between the two encoders.
        $packed.ToArray().Length | Should -BeLessOrEqual 3900
    }

    It 'greys out a layer''s buttons in place when its scene changes, and moves nothing else' {
        Mock Test-StatusViewer { $false }
        $script:OnAir = @{ 4 = @{ Key = 'Urgent'; At = $script:widgetNow }; 5 = @{ Key = 'Ticker'; At = $script:widgetNow } }
        $keyboard = Get-MainMenuKeyboard -ChatId 101 -UserId 101 -Compact
        Send-MainMenuWidget -ChatId 101 -UserId 101 -Keyboard $keyboard -Now $script:widgetNow | Should -BeTrue
        $sent = $script:MainMenuWidgets[[long]101].Keyboard.inline_keyboard

        $script:OnAir[4].Key = 'Replacement'
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(5)

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/editMessageReplyMarkup' -and $Request.Body.message_id -eq 76
        }
        $edited = (Get-MainMenuWidgetKeyboard -Card $script:MainMenuWidgets[[long]101] -StaleLayers 4).inline_keyboard
        $edited.Count | Should -Be $sent.Count
        for ($rowIndex = 0; $rowIndex -lt $sent.Count; $rowIndex++) {
            @($edited[$rowIndex]).Count | Should -Be @($sent[$rowIndex]).Count
            for ($cell = 0; $cell -lt @($sent[$rowIndex]).Count; $cell++) {
                $before = @($sent[$rowIndex])[$cell]
                $after = @($edited[$rowIndex])[$cell]
                $after.text | Should -BeExactly $before.text
                if ($before.callback_data -match '^(hide|timer):4:menu$') {
                    $after.ContainsKey('disabled') | Should -BeTrue
                    $after.ContainsKey('callback_data') | Should -BeFalse
                }
                else { $after.callback_data | Should -BeExactly $before.callback_data }
            }
        }
        @($sent | ForEach-Object { $_ } | Where-Object { $_.callback_data -match '^(hide|timer):4:menu$' }).Count | Should -Be 2

        # The panel follows on the next pass, and the keyboard is not sent twice.
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(6)
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(7)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter { $Request.Uri -like '*/editMessageReplyMarkup' }
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/editMessageWidgetData' -and $Request.Body.chat_data -match 'Replacement'
        }
        $script:MainMenuWidgets[[long]101].StaleLayers | Should -Be @(4)
    }

    It 'greys out every layer button once when the menu expires, then lets the menu go' {
        Mock Test-StatusViewer { $false }
        $script:OnAir = @{ 4 = @{ Key = 'Urgent'; At = $script:widgetNow } }
        Show-MainMenuScreen -ChatId 101 -UserId 101
        $expiresAt = $script:MainMenuWidgets[[long]101].ExpiresAt

        Update-AirStatusWidgets -Now $expiresAt.AddSeconds(1)
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/editMessageReplyMarkup' -and $Request.Body.reply_markup -match '"disabled"' -and
                $Request.Body.reply_markup -notmatch 'hide:4'
        }
        Update-AirStatusWidgets -Now $expiresAt.AddSeconds(2)
        Update-AirStatusWidgets -Now $expiresAt.AddSeconds(3)
        $script:MainMenuWidgets.Count | Should -Be 0
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1
    }

    It 'sends a layer button disabled from the start when nothing could ever confirm it' {
        Mock Test-StatusViewer { $false }
        Show-MainMenuScreen -ChatId 101 -UserId 101

        Should -Invoke Invoke-BridgeTelegramRequest -Exactly -Times 1 -ParameterFilter {
            $Uri -like '*/sendWidget' -and $Body.reply_markup -match '"disabled"' -and $Body.reply_markup -notmatch 'hide:4'
        }
    }

    It 'leaves the countdown to the panel instead of freezing a number into the timer button' {
        Mock Test-StatusViewer { $false }
        $script:OnAir = @{ 4 = @{ Key = 'Urgent'; At = (Get-Date) } }
        $script:AutoHideQueue.Add(@{ Layer = 4; At = (Get-Date).AddSeconds(90) })
        Show-MainMenuScreen -ChatId 101 -UserId 101

        $timer = @($script:MainMenuWidgets[[long]101].Keyboard.inline_keyboard | ForEach-Object { $_ } |
            Where-Object { $_.callback_data -eq 'timer:4:menu' })
        $timer.Count | Should -Be 1
        $timer[0].text | Should -BeExactly (T 'menu.timerExtendLive')
        $timer[0].text | Should -Not -Match '\d{2}\s'
    }

    It 'answers from a worker so a slow Telegram never holds the polling thread, and says why an answer failed' {
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow
        Mock Receive-BridgeTelegramRequestWorker {
            [pscustomobject]@{ Success = $false; StatusCode = 400; Error = 'Bad Request: query is too old' }
        }
        $query = @{ id = 'slow'; from = @{ id = 101 }; chat = @{ id = 101; type = 'private' }
            message_id = 76; type = @{ type = 'data' }; data = 'r:c' }
        Invoke-AirStatusWidgetQuery -Query $query -Now $script:widgetNow.AddSeconds(1)

        Should -Invoke Invoke-BridgeTelegramRequest -Exactly -Times 0 -ParameterFilter { $Uri -like '*/answerWidgetQuery' }
        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 1 -ParameterFilter {
            $Request.Uri -like '*/answerWidgetQuery' -and $Request.TimeoutSec -ge 1 -and $Request.TimeoutSec -le 10
        }
        Update-AirStatusWidgets -Now $script:widgetNow.AddSeconds(2)
        Should -Invoke Write-BridgeLog -Exactly -Times 1 -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'answerWidgetQuery failed' -and $Message -match 'HTTP 400' -and
                $Message -match 'query is too old' -and $Message -match "request 'r:c'"
        }
        $script:AirStatusWidgetAnswers.Count | Should -Be 0
    }

    It 'never writes a widget''s own request text to the log, and stops at four answers in flight' {
        Mock Receive-BridgeTelegramRequestWorker { $null }
        $query = @{ from = @{ id = 101 }; chat = @{ id = 101; type = 'private' }
            message_id = 76; type = @{ type = 'data' }; data = "x`n2026-01-01 [ERROR] forged" }
        foreach ($index in 1..5) { $query.id = "q$index"; Invoke-AirStatusWidgetQuery -Query $query -Now $script:widgetNow }

        Should -Invoke Start-BridgeTelegramRequestWorker -Exactly -Times 4
        $script:AirStatusWidgetAnswers.Kind | Sort-Object -Unique | Should -Be 'other'
        Should -Invoke Write-BridgeLog -Exactly -Times 1 -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'left unanswered' }
        Should -Invoke Write-BridgeLog -Exactly -Times 0 -ParameterFilter { $Message -match 'forged' }
    }

    It 'reads a stored show time month-first whatever the station culture is' {
        $previous = [cultureinfo]::CurrentCulture
        try {
            [cultureinfo]::CurrentCulture = [cultureinfo]'en-GB'
            $expected = ([datetimeoffset][datetime]::new(2026, 11, 12, 11, 6, 48, [DateTimeKind]::Local)).ToUnixTimeMilliseconds()
            ConvertTo-AirStatusWidgetEpoch '11/12/2026 11:06:48' | Should -Be $expected
        }
        finally { [cultureinfo]::CurrentCulture = $previous }
    }

    It 'says why Telegram refused a widget, with the sizes it limits' {
        Mock Invoke-BridgeTelegramRequest {
            [pscustomobject]@{ Success = $false; StatusCode = 400; Error = 'Bad Request: INPUT_MEDIA_WIDGET_TOO_LARGE' }
        }
        Show-AirStatusWidget -ChatId 101 -UserId 101 -Now $script:widgetNow

        Should -Invoke Write-BridgeLog -Exactly -Times 1 -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'sendWidget failed' -and $Message -match 'HTTP 400' -and
                $Message -match 'INPUT_MEDIA_WIDGET_TOO_LARGE' -and $Message -match 'html \d+ bytes' -and $Message -match 'state \d+ bytes'
        }
    }
}
