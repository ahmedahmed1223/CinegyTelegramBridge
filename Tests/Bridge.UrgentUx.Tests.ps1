#requires -Version 7

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Urgent board rendered operator screens' {
    BeforeEach {
        Mock Invoke-WebRequest { throw 'No network in urgent UX tests' } -ModuleName CinegyAirTitler
        Mock Get-UrgentSceneTiming { @{ LoopSeconds = 8; IntroSeconds = 2; OutroSeconds = 2 } }
        Mock Send-TelegramMessage {
            $script:UrgentUxPayload = @{ Method = 'sendMessage'; Text = $Text; ReplyMarkup = $ReplyMarkup; ParseMode = $ParseMode }
        }
        Mock Edit-TelegramMessageText {
            $script:UrgentUxPayload = @{ Method = 'editMessageText'; MessageId = $MessageId; Text = $Text; ReplyMarkup = $ReplyMarkup; ParseMode = $ParseMode }
            $true
        }
        Mock Edit-TelegramRichMessage {
            $script:UrgentUxRichPayload = @{ Method = 'editMessageRich'; MessageId = $MessageId; Blocks = $Blocks; ReplyMarkup = $ReplyMarkup }
            $true
        }
        $script:UrgentUxPayload = $null
        $script:UrgentUxRichPayload = $null
        $script:RichMessagesUnavailable = $false
        $script:UrgentSelections = @{}
        $script:UrgentBoardRun = $null
        $script:UrgentBoard = New-UrgentBoard
        foreach ($entry in @{
            NewsListPageSize = 8; UrgentBoardIntervalSeconds = 8; UrgentBoardRepeats = 1
            UrgentBoardTotalSeconds = 0; UrgentBoardMode = 'text'; UrgentBoardRepeatMode = 'cycle'
            SensitiveTemplateKeys = ''; TemplateMaxAirSeconds = @{}
        }.GetEnumerator()) { Set-JsonProp $config.Settings $entry.Key $entry.Value }
        for ($index = 1; $index -le 12; $index++) {
            $script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text "خبر $index <نص> & تفاصيل" -UserId 1).Value
        }
    }
    AfterEach {
        foreach ($payload in @($script:UrgentUxPayload, $script:UrgentUxRichPayload)) {
            if (-not $payload) { continue }
            # Assert the serialized Telegram shape, not merely a flattened count.
            $wire = $payload | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            foreach ($row in $wire.ReplyMarkup.inline_keyboard) {
                , $row | Should -BeOfType [System.Object[]]
                $row.Count | Should -BeGreaterThan 0
                foreach ($button in $row) {
                    $button.text | Should -Not -BeNullOrEmpty
                    $button.callback_data | Should -Not -BeNullOrEmpty
                    [System.Text.Encoding]::UTF8.GetByteCount($button.callback_data) | Should -BeLessOrEqual 64
                }
            }
            if ($payload.ContainsKey('Text')) { $payload.Text.Length | Should -BeLessOrEqual 4096 }
        }
        if ($env:URGENT_UX_PAYLOAD_PATH) {
            foreach ($payload in @($script:UrgentUxPayload, $script:UrgentUxRichPayload)) {
                if ($payload) { $payload | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath $env:URGENT_UX_PAYLOAD_PATH -Encoding utf8 }
            }
        }
        $script:UrgentBoardRun = $null
    }

    It 'renders current and next run text consistently with safe controls for <State>' -ForEach @(
        @{ State = 'playing'; Paused = $false; StopFailed = $false }
        @{ State = 'paused'; Paused = $true; StopFailed = $false }
        @{ State = 'failed stop'; Paused = $true; StopFailed = $true }
    ) {
        $plan = New-UrgentBoardPlan -ChatId 100
        $script:UrgentBoardRun = @{ Step = 2; Steps = $plan.Value.Steps; Paused = $Paused; StopFailed = $StopFailed }
        Show-UrgentBoardScreen -ChatId 100 -MessageId 77
        $script:RichMessagesUnavailable = $true
        Show-UrgentBoardScreen -ChatId 100 -MessageId 77
        $richText = ($script:UrgentUxRichPayload.Blocks | Where-Object type -eq 'paragraph').text -join "`n"
        $richText | Should -Match 'الحالي: خبر 3 <نص> & تفاصيل'
        $richText | Should -Match 'التالي: خبر 4 <نص> & تفاصيل'
        $script:UrgentUxPayload.Text | Should -Match 'الحالي: خبر 3 &lt;نص&gt; &amp; تفاصيل'
        $script:UrgentUxPayload.Text | Should -Match 'الخبر 3 من 12'
        $buttons = @($script:UrgentUxPayload.ReplyMarkup.inline_keyboard | ForEach-Object { $_ })
        if ($StopFailed) {
            $richText | Should -Match 'تعذّر تأكيد الإيقاف'
            $script:UrgentUxPayload.Text | Should -Match 'أعد محاولة الإيقاف'
            $buttons.callback_data | Should -Not -Contain 'urgentb:resume'
            $buttons.callback_data | Should -Not -Contain 'urgentb:skip'
            @($buttons | Where-Object callback_data -eq 'urgentb:stop')[0].text | Should -Be '🔁 إعادة الإيقاف'
        }
        else {
            $buttons.callback_data | Should -Contain 'urgentb:skip'
            if ($Paused) {
                $richText | Should -Match 'يبقى ظاهرًا'
                $richText | Should -Match 'مؤقّت أمان القالب لا يتوقف'
                $buttons.callback_data | Should -Contain 'urgentb:resume'
            }
            else { $buttons.callback_data | Should -Contain 'urgentb:pause' }
        }
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'explains the effective ceiling consistently on review and fallback for <Policy>' -ForEach @(
        @{ Policy = 'template'; Maximum = 100; Sensitive = ''; SensitiveSeconds = 30; Expected = 'الحد الأقصى للقالب'; Seconds = 100 }
        @{ Policy = 'sensitive'; Maximum = 200; Sensitive = 'Urgent'; SensitiveSeconds = 100; Expected = 'للقالب الحسّاس'; Seconds = 100 }
    ) {
        Set-JsonProp $config.Settings 'TemplateMaxAirSeconds' @{ Urgent = $Maximum }
        Set-JsonProp $config.Settings 'SensitiveTemplateKeys' $Sensitive
        Set-JsonProp $config.Settings 'SensitiveTemplateAutoHideSeconds' $SensitiveSeconds
        Set-JsonProp $config.Settings 'UrgentBoardRepeats' 3
        Show-UrgentReviewScreen -ChatId 100 | Should -BeTrue
        $review = $script:UrgentUxPayload.Text
        $review | Should -Match "سقف التشغيل: $Seconds ث.*$Expected"
        $review | Should -Match 'الفاصل الفعلي: 8 ث'
        $review | Should -Match 'قصّ التكرار من 3 إلى 1'
        $fallback = Get-UrgentBoardText -ChatId 100
        $rich = ((Get-UrgentBoardBlocks -ChatId 100 | Where-Object type -eq 'paragraph').text -join "`n")
        $fallback | Should -Match $Expected
        $rich | Should -Match $Expected
        if ($Policy -eq 'template') {
            $review | Should -Not -Match 'حسّاس'
            $fallback | Should -Not -Match 'حسّاس'
            $rich | Should -Not -Match 'حسّاس'
        }
    }

    It 'clamps page <Page> consistently in fallback text and stable-id keyboards' -ForEach @(
        @{ Page = -10; First = 1; Last = 8; ExpectedPage = 0 }
        @{ Page = 99; First = 9; Last = 12; ExpectedPage = 1 }
    ) {
        Show-UrgentBoardScreen -ChatId 100 -MessageId 77 -Page $Page
        $script:RichMessagesUnavailable = $true
        Show-UrgentBoardScreen -ChatId 100 -MessageId 77 -Page $Page
        $pageText = "المعروض: $First–$Last · صفحة $($ExpectedPage + 1) من 2"
        $script:UrgentUxPayload.Text | Should -Match ([regex]::Escape($pageText))
        ($script:UrgentUxRichPayload.Blocks | Where-Object type -eq 'paragraph').text | Should -Contain $pageText
        $buttons = @($script:UrgentUxPayload.ReplyMarkup.inline_keyboard | ForEach-Object { $_ })
        $picks = @($buttons | Where-Object callback_data -Like 'urgentb:pick:*')
        $picks.Count | Should -Be ($Last - $First + 1)
        $picks[0].callback_data | Should -Be "urgentb:pick:$($script:UrgentBoard.Items[$First - 1].Id)"
        $buttons.callback_data | Should -Contain "urgentb:all:$ExpectedPage"
        $buttons.callback_data | Should -Contain "urgentb:none:$ExpectedPage"
    }

    It 'keeps review in the originating message when its id is supplied' {
        Show-UrgentReviewScreen -ChatId 100 -MessageId 77 | Should -BeTrue
        $script:UrgentUxPayload.Method | Should -Be 'editMessageText'
    }

    It 'shows a Telegram-safe summary and filters without changing the saved order' {
        $before = @($script:UrgentBoard.Items | ForEach-Object { $_.Id })
        $script:UrgentBoard.Items[0].Enabled = $false
        Set-UrgentBoardFilter -ChatId 100 -Filter ready | Should -BeTrue
        $script:RichMessagesUnavailable = $true
        Show-UrgentBoardScreen -ChatId 100 -MessageId 77

        $script:UrgentUxPayload.Text | Should -Match 'الإجمالي 12'
        $script:UrgentUxPayload.Text | Should -Match 'التصفية: ready'
        $script:UrgentUxPayload.Text | Should -Not -Match 'خبر 1'
        $buttons = @($script:UrgentUxPayload.ReplyMarkup.inline_keyboard | ForEach-Object { $_ })
        $buttons.callback_data | Should -Contain 'urgentb:filter:latest'
        foreach ($button in $buttons) {
            [System.Text.Encoding]::UTF8.GetByteCount([string]$button.callback_data) | Should -BeLessOrEqual 64
        }
        @($script:UrgentBoard.Items | ForEach-Object { $_.Id }) | Should -Be $before
        $script:UrgentUxPayload.MessageId | Should -Be 77
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'sorts malformed update timestamps last in the latest filter' {
        $script:UrgentBoard.Items[0].UpdatedAt = 'not-a-timestamp'
        $script:UrgentBoard.Items[1].UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
        Set-UrgentBoardFilter -ChatId 100 -Filter latest | Should -BeTrue

        $latest = @(Get-UrgentVisibleItems -ChatId 100)
        $latest[0].Id | Should -Be $script:UrgentBoard.Items[1].Id
        @($latest).Count | Should -Be 12
    }

    It 'opens a numbered detail with short actions and a return to its board page' {
        Show-UrgentItemScreen -ChatId 100 -Position 10 -MessageId 77
        $script:UrgentUxPayload.Text | Should -Match 'الخبر 11 من 12'
        $script:UrgentUxPayload.Text | Should -Match '&lt;نص&gt; &amp; تفاصيل'
        $script:UrgentUxPayload.Method | Should -Be 'editMessageText'
        $script:UrgentUxPayload.MessageId | Should -Be 77
        $buttons = @($script:UrgentUxPayload.ReplyMarkup.inline_keyboard | ForEach-Object { $_ })
        $buttons.callback_data | Should -Contain 'urgentb:page:1'
        $id = $script:UrgentBoard.Items[10].Id
        @($buttons | Where-Object callback_data -eq "urgentb:mode:$id")[0].text | Should -Be '🎬 نمط العرض'
        $buttons.callback_data | Should -Contain "urgentb:text:$id"
        $buttons.callback_data | Should -Contain "urgentb:interval:$id"
        $buttons.callback_data | Should -Contain "urgentb:repeats:$id"
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}
