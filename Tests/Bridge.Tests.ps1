#requires -Version 7
<#
    Bridge.Tests.ps1 — Pester tests for the bridge's pure logic.

    These cover exactly the function-boundary behaviours that produced the
    three bugs that reached production:

      * Split-TelegramText returning a nested array  -> "System.Object[]"
        appeared as the text of every message.
      * Get-FavoriteTemplateKeys returning an empty array -> the caller got
        $null and $null.Count threw under Set-StrictMode.
      * ConvertTo-XmlSafeValue rejecting '' -> pressing ⏭ تخطي crashed the command.

    None of these are visible to static analysis; all three fail loudly here.

    Run:  .\Run-Checks.ps1        (analyzer + tests)
      or: Invoke-Pester .\Tests   (tests only)
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Test runtime isolation' {
    It 'never points on-air persistence at the live logs directory' {
        [IO.Path]::GetFullPath($script:onAirFile) | Should -BeLike "$([IO.Path]::GetFullPath($TestDrive))*"
        [IO.Path]::GetFullPath($script:onAirFile) | Should -Not -BeLike "$([IO.Path]::GetFullPath((Join-Path $script:Root 'logs')))*"
    }
}

Describe 'Split-TelegramText' {
    It 'returns the short message as a plain string, not a nested array' {
        # The System.Object[] regression: the element must be a string.
        $chunks = @(Split-TelegramText -Text 'مرحبا')
        $chunks.Count | Should -Be 1
        $chunks[0] | Should -BeOfType ([string])
        $chunks[0] | Should -Be 'مرحبا'
        "$($chunks[0])" | Should -Not -Match 'System\.Object'
    }

    It 'keeps every chunk within the limit and loses no characters' {
        $text = (1..400 | ForEach-Object { "سطر رقم $_ فيه نص عربي" }) -join "`n"
        $chunks = @(Split-TelegramText -Text $text)
        $chunks.Count | Should -BeGreaterThan 1
        foreach ($c in $chunks) { $c.Length | Should -BeLessOrEqual 3500 }
        ($chunks -join "`n").Replace("`n", '') | Should -Be $text.Replace("`n", '')
    }

    It 'hard-splits a single line longer than the limit' {
        $chunks = @(Split-TelegramText -Text ('x' * 9000))
        foreach ($c in $chunks) { $c.Length | Should -BeLessOrEqual 3500 }
        ($chunks -join '') | Should -Be ('x' * 9000)
    }

    It 'never splits a Unicode surrogate pair or combining text element' {
        $text = ('x' * 3499) + '😀' + 'عَ' + ('y' * 20)
        $chunks = @(Split-TelegramText -Text $text)

        ($chunks -join '') | Should -Be $text
        foreach ($chunk in $chunks) {
            $chunk.Length | Should -BeLessOrEqual 3500
            { [Text.UTF8Encoding]::new($false, $true).GetBytes($chunk) } | Should -Not -Throw
        }
        $chunks[0] | Should -Be ('x' * 3499)
    }
}

Describe 'Unicode-aware field limits' {
    BeforeEach { Mock Send-TelegramMessage { } }

    It 'counts emoji as visible text elements rather than two UTF-16 units' {
        Test-FieldLength -Value '😀😀😀' -ChatId 1 -FieldLimit 3 | Should -BeTrue
        Test-FieldLength -Value '😀😀😀😀' -ChatId 1 -FieldLimit 3 | Should -BeFalse
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match '\(4 حرفًا\).*3' }
    }

    It 'counts an Arabic letter plus its combining mark as one text element' {
        Get-TextElementCount -Text 'عَجَل' | Should -Be 3
    }
}

Describe 'Compact Telegram button labels' {
    It 'shortens a long Arabic template label without changing its callback command' {
        $original = $config.Settings.ButtonTextMaxLength
        try {
            $config.Settings.ButtonTextMaxLength = 18
            $button = New-Button '🔴 إخفاء حركة سلايد طويلة جدًا للمشهد' 'hide:8'

            (Get-TextElementCount -Text $button.text) | Should -BeLessOrEqual 18
            $button.text | Should -Match '…$'
            $button.callback_data | Should -Be 'hide:8'
        }
        finally { $config.Settings.ButtonTextMaxLength = $original }
    }
}

Describe 'Telegram API send reliability' {
    BeforeEach {
        $script:OriginalTelegramRequestTimeoutSeconds = Get-Setting 'TelegramRequestTimeoutSeconds'
        $config.Settings | Add-Member -NotePropertyName TelegramRequestTimeoutSeconds -NotePropertyValue 7 -Force
        Mock Start-Sleep { } -ModuleName BridgeTelegram
        Mock Write-BridgeLog { }
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName TelegramRequestTimeoutSeconds -NotePropertyValue $script:OriginalTelegramRequestTimeoutSeconds -Force
    }

    It 'retries a transient sendMessage failure once with a bounded timeout' {
        $script:TelegramSendAttemptForTest = 0
        Mock Invoke-RestMethod {
            $script:TelegramSendAttemptForTest++
            if ($script:TelegramSendAttemptForTest -eq 1) { throw 'temporary HTTP failure' }
            [pscustomobject]@{ ok = $true }
        } -ModuleName BridgeTelegram

        { Send-TelegramMessage -ChatId 10 -Text 'اختبار' } | Should -Not -Throw

        Should -Invoke Invoke-RestMethod -ModuleName BridgeTelegram -Times 2 -Exactly -ParameterFilter { $Uri -match '/sendMessage$' -and $TimeoutSec -eq 7 }
        Should -Invoke Start-Sleep -ModuleName BridgeTelegram -Times 1 -Exactly
    }

    It 'bounds photo and document uploads with the same timeout' {
        $photo = Join-Path $TestDrive 'frame.jpg'; Set-Content -LiteralPath $photo -Value 'x'
        $document = Join-Path $TestDrive 'diag.zip'; Set-Content -LiteralPath $document -Value 'x'
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } } -ModuleName BridgeTelegram

        Send-TelegramPhoto -ChatId 10 -FilePath $photo
        Send-TelegramDocument -ChatId 10 -FilePath $document | Should -BeTrue

        Should -Invoke Invoke-RestMethod -ModuleName BridgeTelegram -Times 1 -Exactly -ParameterFilter { $Uri -match '/sendPhoto$' -and $TimeoutSec -eq 7 }
        Should -Invoke Invoke-RestMethod -ModuleName BridgeTelegram -Times 1 -Exactly -ParameterFilter { $Uri -match '/sendDocument$' -and $TimeoutSec -eq 7 }
    }

    It 'downloads a Telegram document to an explicit bounded destination' {
        $destination = Join-Path $TestDrive 'imports\templates.json'
        Mock Invoke-RestMethod { [pscustomobject]@{ ok=$true; result=[pscustomobject]@{ file_path='documents/file_1.json' } } }
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '{"safe":true}' -NoNewline }

        Receive-TelegramDocument -FileId 'abc_123' -DestinationPath $destination -MaximumBytes 100 | Should -Be $destination
        Test-Path -LiteralPath $destination | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -match '/file/bot.+/documents/file_1\.json$' -and $TimeoutSec -eq 7 }
    }

    It 'rejects a traversal path returned by Telegram before downloading' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok=$true; result=[pscustomobject]@{ file_path='../config.json' } } }
        Mock Invoke-WebRequest { throw 'must not download' }
        { Receive-TelegramDocument -FileId 'abc' -DestinationPath (Join-Path $TestDrive 'x.json') } | Should -Throw '*مسار*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects an oversized Telegram document before starting its download' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok=$true; result=[pscustomobject]@{ file_path='documents/large.json'; file_size=101 } } }
        Mock Invoke-WebRequest { throw 'must not download' }

        { Receive-TelegramDocument -FileId 'large' -DestinationPath (Join-Path $TestDrive 'large.json') -MaximumBytes 100 } | Should -Throw '*حجم*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'Callback acknowledgement logging' {
    BeforeEach { Mock Write-BridgeLog { } }

    It 'keeps a stale button out of the error log' {
        # 400 is Telegram saying the query is too old or already answered -
        # the operator tapped a button from an earlier screen.
        Mock Invoke-BridgeTelegramRequest { [pscustomobject]@{ Success = $false; Error = 'Response status code does not indicate success: 400 (Bad Request).' } }

        Confirm-TelegramCallback -CallbackQueryId 'q-1'

        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'WARN' -or $Level -eq 'WARN' }
    }

    It 'still reports a failure that is the bridge to answer for' {
        Mock Invoke-BridgeTelegramRequest { [pscustomobject]@{ Success = $false; Error = 'Response status code does not indicate success: 500 (Server Error).' } }

        Confirm-TelegramCallback -CallbackQueryId 'q-2'

        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'ERROR' -or $Level -eq 'ERROR' }
    }
}

Describe 'Version 6 role navigation contracts' {
    It 'preserves page filter and return callback in navigation context' {
        $context = Get-BridgeNavigationContext -Page 3 -Filter 'news' -ReturnCallback 'menu:templates'
        $context.Page | Should -Be 3
        $context.Filter | Should -Be 'news'
        $context.ReturnCallback | Should -Be 'menu:templates'
    }

    It 'builds the role main keyboard through the compatible menu' {
        Mock Test-Admin { $false }
        $callbacks = @((Get-RoleMainKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'menu:templates'
        $callbacks | Should -Contain 'menu:update'
        $callbacks | Should -Contain 'menu:schedule'
        $callbacks | Should -Not -Contain 'menu:settings'
    }

    It 'summarizes cached readiness without performing probes' {
        $summary = Get-BridgeReadinessSummary -Snapshot @{ Telegram = 'connected'; Cinegy = 'healthy'; DiskFreeGB = 8; LastError = '' }
        $summary.Ready | Should -BeTrue
        $summary.Text | Should -Match 'جاهز'
    }
}

Describe 'ConvertTo-ProcessArgumentLine' {
    It 'quotes a path containing spaces' {
        # The ffmpeg exit -22 regression: "D:\cingy cg\..." was split at the space.
        $line = ConvertTo-ProcessArgumentLine -Arguments @('-i', 'D:\cingy cg\logs\snap.jpg')
        $line | Should -Be '-i "D:\cingy cg\logs\snap.jpg"'
    }

    It 'leaves arguments without spaces unquoted' {
        ConvertTo-ProcessArgumentLine -Arguments @('-y', '-frames:v', '1') | Should -Be '-y -frames:v 1'
    }

    It 'represents an empty argument as an empty quoted string' {
        ConvertTo-ProcessArgumentLine -Arguments @('-x', '') | Should -Be '-x ""'
    }

    It 'escapes embedded quotes' {
        ConvertTo-ProcessArgumentLine -Arguments @('say "hi"') | Should -Be '"say \"hi\""'
    }
}

Describe 'Get-JsonProp' {
    It 'returns $null for a missing property instead of throwing under StrictMode' {
        $obj = [pscustomobject]@{ a = 1 }
        Get-JsonProp $obj 'missing' | Should -BeNullOrEmpty
    }

    It 'returns the value when present' {
        Get-JsonProp ([pscustomobject]@{ a = 42 }) 'a' | Should -Be 42
    }

    It 'supports hashtables and a $null object' {
        Get-JsonProp @{ b = 'x' } 'b' | Should -Be 'x'
        Get-JsonProp $null 'anything' | Should -BeNullOrEmpty
    }

    It 'preserves $false rather than treating it as absent' {
        Get-JsonProp ([pscustomobject]@{ flag = $false }) 'flag' | Should -Be $false
    }
}

Describe 'Protect-SensitiveText' {
    It 'redacts a Telegram RTMP stream key' {
        $msg = 'Error opening output rtmp://dc4-1.rtmp.t.me/s/SECRETKEY123: failed'
        $safe = Protect-SensitiveText $msg
        $safe | Should -Not -Match 'SECRETKEY123'
        $safe | Should -Match 'rtmp://\*\*\*'
    }

    It 'redacts a bot token' {
        # Structurally valid but entirely synthetic: 9-digit bot id plus a
        # 30-character token body. A placeholder such as TEST_TOKEN_REDACTED
        # does not exercise the real token-redaction pattern.
        $token = '123456789:' + ('A' * 30)
        (Protect-SensitiveText "token $token here") | Should -Not -Match 'A{30}'
    }

    It 'redacts an SRT passphrase' {
        (Protect-SensitiveText 'srt://host:9000?passphrase=hunter2') | Should -Not -Match 'hunter2'
    }

    It 'leaves ordinary text untouched' {
        Protect-SensitiveText 'تم إظهار عاجل على الطبقة 4' | Should -Be 'تم إظهار عاجل على الطبقة 4'
    }

    It 'handles empty input' {
        Protect-SensitiveText '' | Should -Be ''
    }
}

Describe 'Array-returning helpers' {
    # Dot-sourcing hoists the script's variables into this scope, so they are
    # referenced unqualified - a $script: prefix here would resolve to the test
    # file's own scope, not the bridge's.
    It 'Get-FavoriteTemplateKeys yields a countable array even with no usage history' {
        # The $null.Count regression: an empty return must survive @() wrapping.
        $favs = @(Get-FavoriteTemplateKeys)
        { $favs.Count } | Should -Not -Throw
        $favs.Count | Should -BeGreaterOrEqual 0
    }

    It 'Get-KnownLayers always returns at least one layer' {
        @(Get-KnownLayers).Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-CallbackArg' {
    It 'returns the payload that follows the prefix' {
        Get-CallbackArg -Data 'news:idown:7' -Prefix 'news:idown:' | Should -Be '7'
    }

    It 'does not confuse a longer sibling prefix with a shorter one' {
        # 'news:item:' and 'news:idown:' share a stem; Substring offsets used to
        # be hand-counted here, and getting it wrong shipped a real bug.
        Get-CallbackArg -Data 'news:item:3' -Prefix 'news:item:' | Should -Be '3'
    }

    It 'preserves a payload that itself contains a colon' {
        Get-CallbackArg -Data 'cfg:v:Some:Name' -Prefix 'cfg:v:' | Should -Be 'Some:Name'
    }

    It 'returns an empty string when nothing follows the prefix' {
        Get-CallbackArg -Data 'hide:' -Prefix 'hide:' | Should -Be ''
    }

    It 'throws instead of silently slicing when the prefix does not match' {
        { Get-CallbackArg -Data 'exit:4' -Prefix 'hide:' } | Should -Throw -ExpectedMessage "*does not start with the expected prefix*"
    }
}

Describe 'Callback prefix wiring' {
    BeforeAll {
        $script:CallbackSource = Get-Content -LiteralPath (Join-Path $script:Root 'Parts\Bridge.Callbacks.ps1') -Raw -Encoding utf8
        # Every wildcard switch label in the dispatcher, e.g. 'news:idown:*'.
        $script:HandledPrefixes = @([regex]::Matches($script:CallbackSource, "(?m)^\s*'(?<p>[^']*):\*'\s*\{") |
                ForEach-Object { $_.Groups['p'].Value + ':' } | Sort-Object -Unique)
    }

    It 'no longer parses callback data with hand-counted offsets' {
        # The whole point of Get-CallbackArg: a reintroduced Substring(N) here
        # brings back the off-by-N class this replaced.
        $script:CallbackSource | Should -Not -Match '\$data\.Substring\('
    }

    It 'passes each branch its own prefix rather than a sibling prefix' {
        $mismatched = foreach ($m in [regex]::Matches($script:CallbackSource,
                "(?ms)^\s*'(?<label>[^']*):\*'\s*\{(?<body>.*?)(?=^\s*'|\Z)")) {
            $label = $m.Groups['label'].Value + ':'
            foreach ($u in [regex]::Matches($m.Groups['body'].Value, "Get-CallbackArg \`$data '(?<used>[^']*)'")) {
                if ($u.Groups['used'].Value -ne $label) { "$label used $($u.Groups['used'].Value)" }
            }
        }
        @($mismatched) | Should -BeNullOrEmpty
    }

    It 'has a dispatcher branch for every prefixed button the keyboards emit' {
        $keyboards = Get-Content -LiteralPath (Join-Path $script:Root 'Parts\Bridge.Keyboards.ps1') -Raw -Encoding utf8
        # Buttons carry their callback as New-Button <text> "prefix:$value".
        # The interpolated ones are exactly those a wildcard branch must catch.
        $emitted = @([regex]::Matches($keyboards, '"(?<p>[a-zA-Z][a-zA-Z:]*:)\$') |
                ForEach-Object { $_.Groups['p'].Value } | Sort-Object -Unique)
        $emitted | Should -Not -BeNullOrEmpty
        # A broader branch covers its narrower children the same way
        # switch -Wildcard does: 'tadm:*' answers for 'tadm:edit:...'.
        $orphans = @($emitted | Where-Object {
                $button = $_
                -not ($script:HandledPrefixes | Where-Object { $button.StartsWith($_, [System.StringComparison]::Ordinal) })
            })
        $orphans | Should -BeNullOrEmpty
    }
}

Describe 'Durations read like durations' {
    It 'leaves anything under an hour in minutes' {
        Format-DurationMinutes -Minutes 30 | Should -Be '30 دقيقة'
        Format-DurationMinutes -Minutes 59 | Should -Be '59 دقيقة'
    }

    It 'counts hours the way Arabic counts them' {
        # Dual for two, plural three to ten, singular again from eleven.
        Format-DurationMinutes -Minutes 60 | Should -Be 'ساعة'
        Format-DurationMinutes -Minutes 120 | Should -Be 'ساعتان'
        Format-DurationMinutes -Minutes 300 | Should -Be '5 ساعات'
        Format-DurationMinutes -Minutes 720 | Should -Be '12 ساعة'
    }

    It 'keeps the leftover minutes rather than rounding them away' {
        Format-DurationMinutes -Minutes 90 | Should -Be 'ساعة و30 دقيقة'
    }

    It 'reaches for days once there are enough hours' {
        # 1200 minutes was the complaint: twenty hours, written as a number
        # the reader had to divide.
        Format-DurationMinutes -Minutes 1200 | Should -Be '20 ساعة'
        Format-DurationMinutes -Minutes 1440 | Should -Be 'يوم'
        Format-DurationMinutes -Minutes 2880 | Should -Be 'يومان'
        Format-DurationMinutes -Minutes 1500 | Should -Be 'يوم وساعة'
    }

    It 'says zero plainly' {
        Format-DurationMinutes -Minutes 0 | Should -Be '0 دقيقة'
    }

    It 'counts any noun the way Arabic counts it' {
        # The digest glued one fixed noun onto every number: "8 مرة" and
        # "1 مرات" in the same message.
        Get-ArabicCountNoun -Count 0 -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' | Should -Be '0 مرة'
        Get-ArabicCountNoun -Count 1 -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' | Should -Be '1 مرة'
        Get-ArabicCountNoun -Count 2 -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' | Should -Be 'مرتين'
        Get-ArabicCountNoun -Count 8 -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' | Should -Be '8 مرات'
        Get-ArabicCountNoun -Count 8 -One 'عملية' -Two 'عمليتان' -Few 'عمليات' -Many 'عملية' | Should -Be '8 عمليات'
        Get-ArabicCountNoun -Count 359 -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' | Should -Be '359 مرة'
    }

    It 'says how much of a list the cap hid' {
        Format-CappedTail -Total 10 -Shown 10 | Should -Be ''
        Format-CappedTail -Total 7 -Shown 7 | Should -Be ''
        Format-CappedTail -Total 14 -Shown 10 | Should -Be ' (+4 أخرى)'
    }

    It 'promotes seconds that do not divide evenly by sixty' {
        # Caught in review: promotion only fired on exact multiples of 60, so
        # an uptime of 3661 still read "3661 ثانية" - the very thing the
        # formatter was written to stop, surviving in every value that is not
        # a round minute. Uptime almost never is.
        Format-DurationSeconds -Seconds 3661 | Should -Be 'ساعة ودقيقة'
        # Two units, not three: the formatter names the two largest and stops.
        # "يوم وساعة ودقيقة" is precise and nobody says it, and the minutes are
        # noise beside a day. Promotion itself - the point of this test - is
        # unchanged: 3661 still reads "ساعة ودقيقة" rather than "3661 ثانية".
        Format-DurationSeconds -Seconds 90061 | Should -Be 'يوم وساعة'
        Format-DurationSeconds -Seconds 3599 | Should -Be '59 دقيقة و59 ثانية'
        Format-DurationSeconds -Seconds 61 | Should -Be 'دقيقة وثانية'
    }

    It 'drops leftover seconds once past an hour, and keeps them below it' {
        Format-DurationSeconds -Seconds 3600 | Should -Be 'ساعة'
        Format-DurationSeconds -Seconds 90 | Should -Be 'دقيقة و30 ثانية'
    }

    It 'spells out a minute-valued setting on the settings screen' {
        Format-SettingDisplay -Name 'NewsDraftTimeoutMinutes' -Value 120 | Should -Be 'ساعتان'
    }

    It 'leaves a setting measured in anything else alone' {
        Format-SettingDisplay -Name 'CinegyFrameLossTolerance' -Value 5 | Should -Be '5 إطار'
    }
}

Describe 'Repeat radar' {
    BeforeEach {
        $script:RecentShowTimes = @{}
        Mock Get-SettingInt { 3 } -ParameterFilter { $Name -eq 'RepeatWarningCount' }
        Mock Get-SettingInt { 60 } -ParameterFilter { $Name -eq 'RepeatWarningWindowMinutes' }
    }

    It 'stays quiet for the first two pushes' {
        Test-RepeatedShow -Key 'alpha' | Should -BeFalse
        Test-RepeatedShow -Key 'alpha' | Should -BeFalse
    }

    It 'flags the third push inside the window' {
        # A paste slip or a double tap, not editorial intent.
        Test-RepeatedShow -Key 'alpha' | Out-Null
        Test-RepeatedShow -Key 'alpha' | Out-Null
        Test-RepeatedShow -Key 'alpha' | Should -BeTrue
    }

    It 'forgets pushes that fell outside the window' {
        $now = Get-Date
        Test-RepeatedShow -Key 'alpha' -Now $now.AddMinutes(-90) | Out-Null
        Test-RepeatedShow -Key 'alpha' -Now $now.AddMinutes(-80) | Out-Null
        Test-RepeatedShow -Key 'alpha' -Now $now | Should -BeFalse
    }

    It 'counts each template separately' {
        Test-RepeatedShow -Key 'alpha' | Out-Null
        Test-RepeatedShow -Key 'alpha' | Out-Null
        Test-RepeatedShow -Key 'beta' | Should -BeFalse
    }

    It 'is disabled by a threshold of zero or one' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'RepeatWarningCount' }
        1..5 | ForEach-Object { Test-RepeatedShow -Key 'alpha' | Should -BeFalse }
    }
}

Describe 'One-hand layout and text shortcuts' {
    BeforeEach {
        Mock Get-TemplateStore {
            @{ Order = @('alpha', 'beta'); Map = @{
                    alpha = @{ Key = 'alpha'; Layer = 3 }; beta = @{ Key = 'beta'; Layer = 4 }
                }; Errors = @() }
        }
    }

    It 'splits every row into full-width buttons when enabled' {
        # Thumb-only use cannot reliably hit one of three buttons in a row.
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'OneHandMode' }
        $rows = New-Object System.Collections.ArrayList
        [void]$rows.Add(@(@{ text = 'a' }, @{ text = 'b' }))
        [void]$rows.Add(@(@{ text = 'c' }))
        $keyboard = ConvertTo-OneHandLayout -Keyboard @{ inline_keyboard = $rows.ToArray() }
        @($keyboard.inline_keyboard) | ForEach-Object { @($_).Count | Should -Be 1 }
        @($keyboard.inline_keyboard).Count | Should -Be 3
    }

    It 'leaves the keyboard untouched when disabled' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'OneHandMode' }
        $originalRows = New-Object System.Collections.ArrayList
        [void]$originalRows.Add(@(@{ text = 'a' }, @{ text = 'b' }))
        $original = @{ inline_keyboard = $originalRows.ToArray() }
        @((ConvertTo-OneHandLayout -Keyboard $original).inline_keyboard[0]).Count | Should -Be 2
    }

    It 'resolves an exact template name to its index' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableTextShortcuts' }
        Resolve-TemplateShortcut -Text 'beta' | Should -Be 1
        Resolve-TemplateShortcut -Text 'BETA' | Should -Be 1
    }

    It 'refuses anything that is not an exact match' {
        # A fuzzy match would put the wrong graphic on air from a typo.
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableTextShortcuts' }
        Resolve-TemplateShortcut -Text 'bet' | Should -Be -1
        Resolve-TemplateShortcut -Text 'beta2' | Should -Be -1
        Resolve-TemplateShortcut -Text '  ' | Should -Be -1
    }

    It 'is inert while the setting is off' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableTextShortcuts' }
        Resolve-TemplateShortcut -Text 'beta' | Should -Be -1
    }
}

Describe 'Version 6 Telegram update admission integration' {
    It 'loads the operation policy and initializes a bounded processing ledger' {
        Get-Command Get-BridgeUpdatesForProcessing -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $script:ProcessedUpdateLedger | Should -Not -BeNullOrEmpty
        $script:ProcessedUpdateLedger.Capacity | Should -Be 4096
    }
}

Describe 'Telegram HTML escaping' {
    It 'escapes ampersand before the entities it would otherwise corrupt' {
        # '&' last would turn the '&lt;' just produced into '&amp;lt;'.
        ConvertTo-TelegramHtmlText -Text 'AT&T <b>' | Should -Be 'AT&amp;T &lt;b&gt;'
    }

    It 'leaves ordinary Arabic copy untouched' {
        ConvertTo-TelegramHtmlText -Text 'خبر عاجل: القمة تبدأ' | Should -Be 'خبر عاجل: القمة تبدأ'
    }

    It 'returns an empty string for nothing, rather than throwing' {
        ConvertTo-TelegramHtmlText -Text '' | Should -Be ''
        ConvertTo-TelegramHtmlText -Text $null | Should -Be ''
    }
}

Describe 'Bridge button construction' {
    It 'carries a callback and a style together' {
        $button = New-BridgeButton -Text '🗑 حذف' -CallbackData 'news:delask:0' -Style 'danger'

        $button.text | Should -Be '🗑 حذف'
        $button.callback_data | Should -Be 'news:delask:0'
        $button.style | Should -Be 'danger'
    }

    It 'gives a disabled button no callback, because Telegram treats it as the type' {
        $button = New-BridgeButton -Text '▫️' -CallbackData 'news:noop' -Disabled

        $button.ContainsKey('disabled') | Should -BeTrue
        $button.ContainsKey('callback_data') | Should -BeFalse
    }

    It 'refuses a colour Telegram does not define' {
        { New-BridgeButton -Text 'x' -CallbackData 'y' -Style 'purple' } | Should -Throw
    }

    It 'does not read the styles setting, so building a keyboard stays pure' {
        # The gate belongs at send time. Reading it here made every keyboard
        # test depend on a setting it does not care about.
        Mock Get-Setting { throw 'a button must not read settings' }

        { New-BridgeButton -Text 'x' -CallbackData 'y' -Style 'primary' } | Should -Not -Throw
    }
}

Describe 'A fault that can talk still cannot flood the chat' {
    BeforeEach {
        $script:AlertSuppression = @{}
        Mock Write-BridgeLog { }
        Mock Send-TelegramMessage { }
        Mock Send-AdminBroadcast { }
        Mock Get-SettingInt { 10 } -ParameterFilter { $Name -eq 'AlertMaxPerCausePerHour' }
    }
    AfterAll { $script:AlertSuppression = @{} }

    It 'lets the cap through and holds the rest of the same cause' {
        # The live incident this exists for: a warning arriving on every tick
        # because the mark that should have stopped it was written where
        # nothing could read it. Every specific guard can fail that way; this
        # is the one that does not have to be right about the cause.
        $now = Get-Date
        $sent = 0
        1..50 | ForEach-Object {
            if (-not (Test-BridgeNoticeSuppressed -Cause 'مسودة على وشك الانتهاء' -ChatId 99 -Now $now.AddSeconds($_))) { $sent++ }
        }

        $sent | Should -Be 10
    }

    It 'never lets one chatty fault starve an unrelated alert' {
        # Per cause, never a global budget: an alert about black output must
        # not be swallowed because a draft warning spent the hour's quota.
        $now = Get-Date
        1..40 | ForEach-Object { Test-BridgeNoticeSuppressed -Cause 'مسودة على وشك الانتهاء' -ChatId 99 -Now $now | Out-Null }

        Test-BridgeNoticeSuppressed -Cause 'المخرج أسود' -ChatId 99 -Now $now | Should -BeFalse
    }

    It 'counts a cause per chat, so one operator cannot mute another' {
        $now = Get-Date
        1..40 | ForEach-Object { Test-BridgeNoticeSuppressed -Cause 'نفس السبب' -ChatId 11 -Now $now | Out-Null }

        Test-BridgeNoticeSuppressed -Cause 'نفس السبب' -ChatId 22 -Now $now | Should -BeFalse
    }

    It 'has no cap at all when the setting is zero' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'AlertMaxPerCausePerHour' }
        $now = Get-Date

        $held = @(1..30 | Where-Object { Test-BridgeNoticeSuppressed -Cause 'أي سبب' -ChatId 99 -Now $now })

        $held | Should -BeNullOrEmpty
    }

    It 'says how much it held once the fault goes quiet' {
        # A cap that swallows without a receipt is indistinguishable from a
        # bridge that stopped noticing.
        $now = Get-Date
        1..25 | ForEach-Object { Test-BridgeNoticeSuppressed -Cause 'سبب ثرثار' -ChatId 99 -Now $now.AddSeconds($_) | Out-Null }
        $key = @($script:AlertSuppression.Keys)[0]
        # The hour has rolled over and nothing new has arrived for a while.
        $script:AlertSuppression[$key].Sent = @()
        $script:AlertSuppression[$key].LastAt = $now.AddMinutes(-5)

        Update-AlertSuppressionSweep

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'كُتم' -and $Text -match '15' }
        $script:AlertSuppression.Count | Should -Be 0
    }

    It 'stays silent while the fault is still arriving' {
        # Summarising mid-flood would itself become the flood.
        $now = Get-Date
        1..25 | ForEach-Object { Test-BridgeNoticeSuppressed -Cause 'سبب ثرثار' -ChatId 99 -Now $now.AddSeconds($_) | Out-Null }

        Update-AlertSuppressionSweep

        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
        $script:AlertSuppression.Count | Should -Be 1
    }

    It 'logs every held notice, because the cap is quiet only towards the operator' {
        $now = Get-Date

        1..15 | ForEach-Object { Test-BridgeNoticeSuppressed -Cause 'سبب' -ChatId 99 -Now $now.AddSeconds($_) | Out-Null }

        Should -Invoke Write-BridgeLog -Times 5 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'Alert cap reached' }
    }

    It 'leaves a message the operator asked for alone' {
        # The rule that keeps this safe: only unsolicited notices pass a
        # -Cause. Fifteen graphics put to air in an hour produce fifteen
        # confirmations whose causes are identical once numbers are stripped,
        # and capping those would hide the air itself.
        $now = Get-Date

        $anyHeld = @(1..40 | Where-Object { Test-BridgeNoticeSuppressed -Cause '' -ChatId 99 -Now $now })

        $anyHeld | Should -BeNullOrEmpty
    }
}

Describe 'Reading a possibly-absent property' {
    It 'reads a key out of every dictionary shape the bridge builds' {
        # [ordered]@{} is an OrderedDictionary, not a Hashtable, and exposes no
        # keys as PSObject properties - so a reader testing -is [hashtable]
        # answered $null for every key of a live draft, and only started
        # working after a restart reloaded it as a Hashtable.
        Get-JsonProp ([ordered]@{ OwnerChatId = 41 }) 'OwnerChatId' | Should -Be 41
        Get-JsonProp @{ OwnerChatId = 41 } 'OwnerChatId' | Should -Be 41
        Get-JsonProp ([pscustomobject]@{ OwnerChatId = 41 }) 'OwnerChatId' | Should -Be 41
    }

    It 'also sees a note property added to a dictionary with Add-Member' {
        # Both spellings exist in this codebase. A reader that stopped at the
        # keys could not see the expiry warning's own mark, which turned one
        # warning per draft into one per tick.
        $draft = [ordered]@{ OwnerChatId = 41 }
        $draft | Add-Member -NotePropertyName 'WarnedAt' -NotePropertyValue 'now' -Force

        Get-JsonProp $draft 'WarnedAt' | Should -Be 'now'
    }

    It 'answers nothing for a missing name rather than a real .NET member' {
        # The note-property fallback is restricted to NoteProperty for this:
        # every dictionary has Count and Keys, and a missing key must not
        # start resolving to them.
        Get-JsonProp @{ a = 1 } 'Count' | Should -BeNullOrEmpty
        Get-JsonProp ([ordered]@{ a = 1 }) 'Keys' | Should -BeNullOrEmpty
        Get-JsonProp @{ a = 1 } 'nope' | Should -BeNullOrEmpty
        Get-JsonProp $null 'anything' | Should -BeNullOrEmpty
    }
}

Describe 'Writing a property onto state of either shape' {
    It 'writes a key on a dictionary, where ConvertTo-Json can still see it' {
        # Add-Member on a dictionary adds a note property, and ConvertTo-Json
        # serialises a dictionary's KEYS - so the value was written, saved, and
        # silently gone. That is what turned the draft expiry warning into one
        # message per tick on a live channel.
        foreach ($state in ([ordered]@{ a = 1 }), @{ a = 1 }) {
            Set-JsonProp -Object $state -Name 'WarnedAt' -Value 'now'

            $state.Contains('WarnedAt') | Should -BeTrue
            $reloaded = $state | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
            Get-JsonProp $reloaded 'WarnedAt' | Should -Be 'now'
        }
    }

    It 'writes a note property on a PSCustomObject, which has no keys' {
        $state = [pscustomobject]@{ a = 1 }

        Set-JsonProp -Object $state -Name 'WarnedAt' -Value 'now'

        Get-JsonProp $state 'WarnedAt' | Should -Be 'now'
    }

    It 'overwrites rather than duplicating, whichever shape it is' {
        foreach ($state in ([ordered]@{ a = 1 }), @{ a = 1 }, ([pscustomobject]@{ a = 1 })) {
            Set-JsonProp -Object $state -Name 'Mark' -Value 'first'
            Set-JsonProp -Object $state -Name 'Mark' -Value 'second'

            Get-JsonProp $state 'Mark' | Should -Be 'second'
        }
    }

    It 'clears a mark written in either spelling' {
        # A value written before Set-JsonProp existed may still be sitting on
        # the object as a note property, so both are cleared.
        $state = [ordered]@{ a = 1 }
        $state | Add-Member -NotePropertyName 'Mark' -NotePropertyValue 'old' -Force
        Set-JsonProp -Object $state -Name 'Mark' -Value 'new'

        Remove-JsonProp -Object $state -Name 'Mark'

        Get-JsonProp $state 'Mark' | Should -BeNullOrEmpty
    }

    It 'does nothing to a null object rather than throwing' {
        { Set-JsonProp -Object $null -Name 'x' -Value 1 } | Should -Not -Throw
        { Remove-JsonProp -Object $null -Name 'x' } | Should -Not -Throw
    }
}

Describe 'Reply markup serialisation' {
    BeforeAll {
        $script:StyledMarkup = @{ inline_keyboard = @(
                , @((New-BridgeButton -Text 'انشر' -CallbackData 'news:publish' -Style 'success'),
                    (New-BridgeButton -Text 'رجوع' -CallbackData 'menu'))) }
        # Serialisation honours two settings now, not one: the one-hand pass
        # moved here from the single screen that used to call it. These cases
        # are about colour, so the layout is pinned off and left alone.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'OneHandMode' }
    }

    It 'keeps the colour while the setting is on' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableButtonStyles' }

        ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $script:StyledMarkup | Should -Match '"style":"success"'
    }

    It 'wraps a bare button that was passed where a row belongs' {
        # Telegram answers this shape with 400 "InlineKeyboardButton must be an
        # Object" and drops the WHOLE message, so the operator taps and nothing
        # happens. One such 400 reached bridge.log on 2026-09-14 and named
        # neither screen nor row.
        #
        # Styles ON is the case that matters, and the live default: with them
        # off the colour-stripping pass rebuilds every row and repairs this
        # shape by accident, which is why the fault can hide on one machine
        # and bite on another.
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableButtonStyles' }
        Mock Write-BridgeLog { }
        $flat = @{ inline_keyboard = @(
                (New-BridgeButton -Text 'واحد' -CallbackData 'one'),
                (New-BridgeButton -Text 'اثنان' -CallbackData 'two')) }

        $json = ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $flat

        # Every row is an array of button objects, so Telegram accepts it.
        ($json | ConvertFrom-Json).inline_keyboard | ForEach-Object {
            @($_)[0].callback_data | Should -Not -BeNullOrEmpty
        }
        $json | Should -Match 'one'
        $json | Should -Match 'two'
        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'flattens a row that was nested one level too deep' {
        # The readiness screen shipped exactly this shape: a keyboard literal
        # whose rows carry BOTH a leading comma and a trailing comma joining
        # them turns every row into [[button]] instead of [button], and
        # Telegram refuses the whole message with 400 "InlineKeyboardButton
        # must be an Object".
        #
        # The repair pass was already in place when this reached the air on
        # 2026-09-14 and said nothing, because it tested a cell with
        # $_ -is [pscustomobject] - which is TRUE for anything off a pipeline,
        # arrays included. The buttons are right there, so they are flattened
        # back into a row rather than dropped.
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableButtonStyles' }
        Mock Write-BridgeLog { }
        $nested = @{ inline_keyboard = @(
                , @((New-BridgeButton -Text 'فحص' -CallbackData 'menu:selftest'), (New-BridgeButton -Text 'تسليم' -CallbackData 'menu:handover')),
                , @((New-BridgeButton -Text 'رجوع' -CallbackData 'menu:admintools'))
            ) }

        $rows = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $nested | ConvertFrom-Json).inline_keyboard

        @($rows).Count | Should -Be 2
        @($rows[0]).Count | Should -Be 2
        @($rows[1]).Count | Should -Be 1
        # Every cell is a button object, which is the whole point.
        $rows[0][0].callback_data | Should -Be 'menu:selftest'
        $rows[0][1].callback_data | Should -Be 'menu:handover'
        $rows[1][0].callback_data | Should -Be 'menu:admintools'
        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'still reports a repair when the nested row holds a single button' {
        # Counting cells before and after misses this one - one nested button
        # flattens to one button - and a silent repair is how the fault above
        # stayed invisible. The warning is the only breadcrumb to the caller.
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableButtonStyles' }
        Mock Write-BridgeLog { }
        $nested = @{ inline_keyboard = @(, @(, @((New-BridgeButton -Text 'رجوع' -CallbackData 'menu')))) }

        $rows = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $nested | ConvertFrom-Json).inline_keyboard

        $rows[0][0].callback_data | Should -Be 'menu'
        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'leaves a well-formed keyboard exactly as it was' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableButtonStyles' }
        Mock Write-BridgeLog { }
        $good = @{ inline_keyboard = @(
                , @((New-BridgeButton -Text 'أ' -CallbackData 'a'), (New-BridgeButton -Text 'ب' -CallbackData 'b'))
                , @((New-BridgeButton -Text 'رجوع' -CallbackData 'menu'))) }

        $rows = (ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $good | ConvertFrom-Json).inline_keyboard

        @($rows).Count | Should -Be 2
        @($rows[0]).Count | Should -Be 2
        @($rows[1]).Count | Should -Be 1
        Should -Invoke Write-BridgeLog -Times 0 -Exactly
    }

    It 'drops the colour while the setting is off, keeping everything else' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableButtonStyles' }

        $json = ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $script:StyledMarkup

        $json | Should -Not -Match '"style"'
        $json | Should -Match 'news:publish'
        $json | Should -Match 'menu'
    }

    It 'leaves the caller keyboard alone, so the next render still has the colour' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableButtonStyles' }

        ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $script:StyledMarkup | Out-Null

        @($script:StyledMarkup.inline_keyboard)[0][0].style | Should -Be 'success'
    }
}

Describe 'Button colour policy' {
    It 'colours the act that takes a template off air, not the menu that opens it' {
        $script:OnAir[7] = @{ Key = 'urgent'; Values = @{}; ShownAt = (Get-Date) }
        try {
            $removal = @((Get-AfterShowKeyboard -Layer 7 -ChatId 101 -UserId 101).inline_keyboard | ForEach-Object { @($_) })
            $hide = @($removal | Where-Object { $_['callback_data'] -eq 'hide:7' })[0]
            $exit = @($removal | Where-Object { $_['callback_data'] -eq 'exit:7' })[0]

            $hide.style | Should -Be 'danger'
            $exit.style | Should -Be 'danger'
        }
        finally { $script:OnAir.Remove(7) }
    }

    It 'leaves a menu entry uncoloured, because pressing it removes nothing' {
        # The screen it opens is where the act lives, and colouring both makes
        # neither mean anything.
        $main = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard | ForEach-Object { @($_) })
        $entry = @($main | Where-Object { $_['callback_data'] -eq 'menu:hide' })[0]

        $entry | Should -Not -BeNullOrEmpty
        $entry.ContainsKey('style') | Should -BeFalse
    }

    It 'colours the affirming half of a destructive confirmation and not the cancel' {
        $rows = @((Get-HideAllConfirmKeyboard).inline_keyboard | ForEach-Object { @($_) })
        $yes = @($rows | Where-Object { $_['callback_data'] -eq 'hideall:confirm' })[0]
        $no = @($rows | Where-Object { $_['callback_data'] -eq 'cancel' })[0]

        $yes.style | Should -Be 'danger'
        $no.ContainsKey('style') | Should -BeFalse
    }

    It 'colours the emergency hide-all entry wherever it appears' {
        # F8: the press takes everything off air, so both menu entries wear
        # danger - beside live rows and on the quiet menu alike.
        $script:OnAir[7] = @{ Key = 'urgent'; At = (Get-Date); UserId = 1; Source = 'bridge' }
        try {
            $live = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard | ForEach-Object { @($_) })
            @($live | Where-Object { $_['callback_data'] -eq 'menu:hideall' })[0].style | Should -Be 'danger'
        }
        finally { $script:OnAir.Remove(7) }
        $quiet = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard | ForEach-Object { @($_) })
        @($quiet | Where-Object { $_['callback_data'] -eq 'menu:hideall' })[0].style | Should -Be 'danger'
    }

    It 'uses only the three styles Telegram defines' {
        # A value outside the documented set is rejected for the whole message,
        # so a typo would take a screen off the air rather than mis-colour it.
        $keyboards = @(
            (Get-MainMenuKeyboard -ChatId 101 -UserId 101)
            (Get-HideAllConfirmKeyboard)
            (Get-SettingsKeyboard)
        )
        foreach ($keyboard in $keyboards) {
            foreach ($button in @($keyboard.inline_keyboard | ForEach-Object { @($_) })) {
                if ($button.ContainsKey('style')) {
                    $button.style | Should -BeIn @('danger', 'success', 'primary')
                }
            }
        }
    }
}

Describe 'Callback refusal reaches the button, not the chat' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Send-TelegramMessage { }
        Mock Write-BridgeLog { }
        Mock Request-Approval { $false }
        Mock Update-UserLastActivity { }
    }

    It 'answers an unauthorised press with a dialog instead of a new message' {
        # Telegram allows one answer per press. Spending it on an empty
        # acknowledgement is what forced refusals to arrive as chat messages,
        # which scroll the keyboard away.
        Mock Test-Authorized { $false }
        $callback = [pscustomobject]@{
            id = 'refused'
            from = [pscustomobject]@{ id = 909 }
            message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = 909; type = 'private' } }
            data = 'menu'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $Alert -and $Text -match 'غير مصرح' }
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'still answers a press it ignores, so the spinner cannot hang' {
        Mock Test-Authorized { $true }
        $callback = [pscustomobject]@{
            id = 'group-press'
            from = [pscustomobject]@{ id = 5 }
            message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = -100999; type = 'supergroup' } }
            data = 'menu'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly
    }

    It 'keeps the plain acknowledgement first for a press it will act on' {
        # The reason it came first at all: the spinner must not sit through a
        # slow air operation.
        Mock Test-Authorized { $true }
        Mock Show-NewsTickerManagementScreen { }
        $callback = [pscustomobject]@{
            id = 'allowed'
            from = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = 101; type = 'private' } }
            data = 'menu:news'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { -not $Alert }
    }
}

Describe 'Callback answer text' {
    It 'trims to what Telegram will show rather than losing the end mid-word' {
        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }

        Confirm-TelegramCallback -CallbackQueryId 'x' -Text ('ط' * 400) -Alert

        Should -Invoke Invoke-BridgeTelegramRequest -Times 1 -Exactly -ParameterFilter {
            $Body.text.Length -le 200 -and $Body.text.EndsWith('…') -and $Body.show_alert -eq $true
        }
    }
}

Describe 'Colour survives the safer configuration' {
    It 'colours the hide confirmation, so turning the confirmation on does not weaken the screen' {
        # ConfirmLayerRemoval exists to make hiding harder. If its yes button
        # were plain while the direct hide button is red, the safer setting
        # would hand the operator the weaker screen.
        foreach ($action in 'hide', 'exit') {
            $rows = @((Get-LayerRemovalConfirmKeyboard -Layer 7 -Action $action).inline_keyboard | ForEach-Object { @($_) })
            $yes = @($rows | Where-Object { $_['callback_data'] -eq "${action}go:7" })[0]
            $cancel = @($rows | Where-Object { $_['callback_data'] -eq 'menu' })[0]

            $yes.style | Should -Be 'danger' -Because "the $action confirmation performs the removal"
            $cancel.ContainsKey('style') | Should -BeFalse
        }
    }

    It 'treats resetting one setting exactly as it treats resetting them all' {
        $rows = @((Get-SingleSettingResetConfirmKeyboard -Name 'MaxFieldLength').inline_keyboard | ForEach-Object { @($_) })
        $yes = @($rows | Where-Object { $_['callback_data'] -eq 'cfgrgo:MaxFieldLength' })[0]

        $yes.style | Should -Be 'danger'
    }
}

Describe 'Callback refusal gate' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Send-TelegramMessage { }
        Mock Write-BridgeLog { }
        Mock Test-Authorized { $true }
        Mock Update-UserLastActivity { }
    }

    It 'refuses a restore an operator may not run, instead of doing nothing at all' {
        # Both restore branches used to refuse with a bare break: the press
        # was answered, nothing happened, and nothing said why - which is
        # indistinguishable from a bridge that dropped it.
        Mock Test-Admin { $false }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowOperatorsRestoreNews' }

        Get-CallbackRefusal -Data 'news:restore:0' -ChatId 101 -UserId 101 | Should -Match 'مشرف'
        Get-CallbackRefusal -Data 'news:restoreconfirm:0' -ChatId 101 -UserId 101 | Should -Match 'مشرف'
    }

    It 'allows the same restore once the operator setting is on' {
        Mock Test-Admin { $false }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'AllowOperatorsRestoreNews' }

        Get-CallbackRefusal -Data 'news:restore:0' -ChatId 101 -UserId 101 | Should -BeNullOrEmpty
    }

    It 'covers every sheet callback, not only the two that draw buttons' {
        Mock Test-NewsSheetPullAccess { $false }

        foreach ($data in 'news:sheet', 'news:sheetdraft', 'news:sheetconfirm', 'news:sheetdraftconfirm') {
            Get-CallbackRefusal -Data $data -ChatId 101 -UserId 101 |
                Should -Not -BeNullOrEmpty -Because "$data reaches the pull"
        }
    }

    It 'says nothing about a press it does not govern' {
        Mock Test-NewsSheetPullAccess { $false }
        Mock Test-Admin { $false }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowOperatorsRestoreNews' }

        Get-CallbackRefusal -Data 'menu:news' -ChatId 101 -UserId 101 | Should -BeNullOrEmpty
    }

    It 'answers the refused press on the button and leaves the chat alone' {
        Mock Test-NewsSheetPullAccess { $false }
        $callback = [pscustomobject]@{
            id = 'sheet-refused'
            from = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = 101; type = 'private' } }
            data = 'news:sheet'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly -ParameterFilter { $Alert -and $Text -match 'سحب الشيت' }
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}

Describe 'Copy the operation reference' {
    It 'offers the newest reference as a clipboard button rather than something to retype' {
        Mock Get-UserOperationHistory { @([pscustomobject]@{ OperationId = 'air-5023333b032c476eb48204ca08032a98' }) }

        $rows = @((Get-MyOperationsKeyboard -UserId 101).inline_keyboard | ForEach-Object { @($_) })
        $copy = @($rows | Where-Object { $_.ContainsKey('copy_text') })[0]

        $copy.copy_text.text | Should -Be '5023333b'
        $copy.ContainsKey('callback_data') | Should -BeFalse
    }

    It 'copies the reference of the failure, not of whatever happened last' {
        # The screen prints a reference beside a failure only, so copying the
        # newest operation handed the operator eight characters that appear
        # nowhere on the screen they are reading from.
        Mock Get-UserOperationHistory {
            @(
                [pscustomobject]@{ OperationId = 'air-11111111032c476eb48204ca08032a98'; Result = 'failed' }
                [pscustomobject]@{ OperationId = 'air-22222222032c476eb48204ca08032a98'; Result = 'success' }
            )
        }

        $rows = @((Get-MyOperationsKeyboard -UserId 101).inline_keyboard | ForEach-Object { @($_) })
        $copy = @($rows | Where-Object { $_.ContainsKey('copy_text') })[0]

        $copy.copy_text.text | Should -Be '11111111'
    }

    It 'offers nothing to copy when the operator has no history yet' {
        Mock Get-UserOperationHistory { @() }

        $rows = @((Get-MyOperationsKeyboard -UserId 101).inline_keyboard | ForEach-Object { @($_) })

        @($rows | Where-Object { $_.ContainsKey('copy_text') }).Count | Should -Be 0
    }
}

Describe 'Rich sending never becomes a dependency' {
    BeforeEach {
        Mock Send-TelegramPagedText { }
        Mock Test-Admin { $true }
        Mock Get-BannerReportData { @{ Label = 'اليوم'; Operators = 0; Truncated = $false; Sessions = @() } }
        Reset-RichBlockCapabilities
    }

    It 'falls back to the text report the screen has always sent' {
        Mock Send-TelegramRichMessage { $false }

        Show-Report -ChatId 101 -UserId 101 -Kind banners -Period today

        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly
    }

    It 'does not also send the text version when the rich one worked' {
        Mock Send-TelegramRichMessage { $true }

        Show-Report -ChatId 101 -UserId 101 -Kind banners -Period today

        Should -Invoke Send-TelegramPagedText -Times 0 -Exactly
    }

    It 'builds the news report from blocks too, and still falls back' {
        Mock Get-NewsReportDays { @{ Label = 'اليوم'; Days = @(); Publishes = 0; Items = 0; Truncated = $false; SilentDays = 1; LastPublishedAt = $null } }
        Mock Get-NewsReportText { 'تقرير' }
        Mock Send-TelegramRichMessage { $true }

        Show-Report -ChatId 101 -UserId 101 -Kind news -Period today
        Should -Invoke Send-TelegramPagedText -Times 0 -Exactly

        Mock Send-TelegramRichMessage { $false }
        Show-Report -ChatId 101 -UserId 101 -Kind news -Period today
        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly
    }

    It 'stops trying once the method itself is missing' {
        # A 404 is the method not existing here, so nothing built from blocks
        # will ever work and every screen may as well stop asking.
        Reset-RichBlockCapabilities
        Mock Invoke-BridgeTelegramRequest { @{ Success = $false; Error = 'Response status code does not indicate success: 404 (Not Found).' } }
        Mock Write-BridgeLog { }

        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'paragraph'; text = 'x' }) | Should -BeFalse
        $script:RichMessagesUnavailable | Should -BeTrue

        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'table'; cells = @() }) | Should -BeFalse
        Should -Invoke Invoke-BridgeTelegramRequest -Times 1 -Exactly
    }

    It 'blames a rejected payload on its new block type, not on the session' {
        # One screen reaching for a block type this server does not have used
        # to take the status table, the reports and the news listing down with
        # it until a restart.
        Reset-RichBlockCapabilities
        Mock Write-BridgeLog { }
        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }
        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'paragraph'; text = 'x' }) | Should -BeTrue

        Mock Invoke-BridgeTelegramRequest { @{ Success = $false; Error = 'Response status code does not indicate success: 400 (Bad Request).' } }
        Send-TelegramRichMessage -ChatId 101 -Blocks @(
            @{ type = 'paragraph'; text = 'x' }, @{ type = 'expandable_block_quotation'; text = 'y' }) | Should -BeFalse

        $script:RichMessagesUnavailable | Should -BeFalse
        $script:RichBlockTypesUnavailable.ContainsKey('expandable_block_quotation') | Should -BeTrue
        $script:RichBlockTypesUnavailable.ContainsKey('paragraph') | Should -BeFalse
    }

    It 'keeps sending the block types that already rendered' {
        Reset-RichBlockCapabilities
        Mock Write-BridgeLog { }
        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }
        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'paragraph'; text = 'x' }) | Should -BeTrue

        Mock Invoke-BridgeTelegramRequest { @{ Success = $false; Error = '400 (Bad Request).' } }
        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'thinking'; text = 'y' }) | Should -BeFalse

        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }
        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'paragraph'; text = 'z' }) | Should -BeTrue
    }

    It 'does not spend a round trip on a block type already known to be refused' {
        Reset-RichBlockCapabilities
        $script:RichBlockTypesUnavailable['thinking'] = $true
        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }

        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'thinking'; text = 'y' }) | Should -BeFalse

        Should -Invoke Invoke-BridgeTelegramRequest -Times 0 -Exactly
    }

    It 'disables nothing when every type in the refused payload has rendered before' {
        # Then the fault is this message - its size, a field, a value - and
        # disabling a working block type for it would be a permanent cost.
        Reset-RichBlockCapabilities
        Mock Write-BridgeLog { }
        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }
        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'paragraph'; text = 'x' }) | Should -BeTrue

        Mock Invoke-BridgeTelegramRequest { @{ Success = $false; Error = '400 (Bad Request).' } }
        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'paragraph'; text = 'huge' }) | Should -BeFalse

        @($script:RichBlockTypesUnavailable.Keys).Count | Should -Be 0
        $script:RichMessagesUnavailable | Should -BeFalse
    }

    It 'sees the block types nested in a details block and in a table cell' {
        # Those are the parts most likely to be why a server refused the whole
        # message, so a blame that cannot see them blames the wrong thing.
        $types = @(Get-RichBlockTypes -Blocks @(
                @{ type = 'heading'; text = 'h' }
                @{ type = 'details'; blocks = @(@{ type = 'preformatted'; text = 'p' }) }
                @{ type = 'table'; cells = @(, @(@{ type = 'paragraph'; text = 'c' })) }))

        $types | Should -Contain 'preformatted'
        $types | Should -Contain 'paragraph'
        $types | Should -Contain 'details'
        $types | Should -Contain 'table'
    }

    It 'asks Telegram to lay the table out right-to-left' {
        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }

        Send-TelegramRichMessage -ChatId 101 -Blocks @(@{ type = 'paragraph'; text = 'x' }) | Should -BeTrue

        Should -Invoke Invoke-BridgeTelegramRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*/sendRichMessage' -and $Body.rich_message -match '"is_rtl":true'
        }
    }
}

Describe 'An overlong HTML message loses its markup, not its meaning' {
    It 'strips the tags instead of showing them when it will not fit one send' {
        # The 7.0.0 fallback sent the raw text, so the operator got '<b>' and
        # '<blockquote expandable>' on screen - the very thing the escaping
        # exists to prevent, arriving from the other side.
        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }
        Mock Write-BridgeLog { }
        $long = '<b>عنوان</b> ' + ('<blockquote expandable>' + ('ط' * 4000) + '</blockquote>')

        Send-TelegramMessage -ChatId 101 -Text $long -ParseMode 'HTML'

        Should -Invoke Invoke-BridgeTelegramRequest -ParameterFilter { $Body.text -notmatch '<b>|<blockquote' }
        Should -Invoke Invoke-BridgeTelegramRequest -ParameterFilter { -not $Body.ContainsKey('parse_mode') }
    }

    It 'gives an escaped angle bracket back as the character the operator typed' {
        # Tags out first, entities back second. The other order would turn an
        # escaped '&lt;b&gt;' into a tag and then delete the headline's text.
        ConvertFrom-TelegramHtmlText -Text '<b>خبر &lt;عاجل&gt; &amp; مهم</b>' |
            Should -Be 'خبر <عاجل> & مهم'
    }

    It 'keeps the markup when the message does fit' {
        Mock Invoke-BridgeTelegramRequest { @{ Success = $true } }

        Send-TelegramMessage -ChatId 101 -Text '<b>قصير</b>' -ParseMode 'HTML'

        Should -Invoke Invoke-BridgeTelegramRequest -Times 1 -Exactly -ParameterFilter {
            $Body.parse_mode -eq 'HTML' -and $Body.text -eq '<b>قصير</b>'
        }
    }
}

Describe 'Telegram flood-limit outbox' {
    BeforeEach {
        $script:TelegramOutbox = [System.Collections.Generic.List[hashtable]]::new()
        $script:TelegramOutboxDropped = 0
        $script:TelegramOutboxWorker = $null
        $script:TelegramOutboxActiveItem = $null
        $script:TelegramOutboxNotBefore = [datetime]::MinValue
        $script:TelegramOutboxDirectory = Join-Path $TestDrive 'outbox'
        Mock Start-BridgeTelegramRequestWorker { @{ TestWorker = $true } }
        Mock Receive-BridgeTelegramRequestWorker { $null }
        Mock Stop-BridgeTelegramRequestWorker { }
        Mock Write-BridgeLog { }
    }
    AfterEach { Clear-TelegramOutbox }

    It 'makes room for a warning before it drops a warning' {
        foreach ($number in 1..200) {
            Add-TelegramOutboxItem -Body @{ chat_id = 101; text = "ordinary $number" } -DueAt (Get-Date).AddMinutes(1) -Attempts 0 | Out-Null
        }

        Add-TelegramOutboxItem -Body @{ chat_id = 101; text = '⚠ urgent operator warning' } -DueAt (Get-Date).AddMinutes(1) -Attempts 0 | Should -BeTrue

        $script:TelegramOutbox.Count | Should -Be 200
        @($script:TelegramOutbox | Where-Object { $_.Priority }).Count | Should -Be 1
        $script:TelegramOutboxDropped | Should -Be 1
    }

    It 'keeps one request in flight while later ticks return without another send' {
        foreach ($number in 1..4) {
            Add-TelegramOutboxItem -Body @{ chat_id = 101; text = "ordinary $number" } -DueAt (Get-Date).AddMinutes(-1) -Attempts 0 | Out-Null
        }
        Update-TelegramOutbox
        Update-TelegramOutbox

        Should -Invoke Start-BridgeTelegramRequestWorker -Times 1 -Exactly
        $script:TelegramOutbox.Count | Should -Be 3
        $script:TelegramOutboxActiveItem.Body.text | Should -Be 'ordinary 1'
    }

    It 'sends a due warning ahead of ordinary deferred navigation' {
        Add-TelegramOutboxItem -Body @{ chat_id = 101; text = 'ordinary first' } -DueAt (Get-Date).AddMinutes(-2) -Attempts 0 | Out-Null
        Add-TelegramOutboxItem -Body @{ chat_id = 101; text = '⚠ urgent warning' } -DueAt (Get-Date).AddMinutes(-1) -Attempts 0 | Out-Null
        Update-TelegramOutbox

        $script:TelegramOutboxActiveItem.Body.text | Should -Be '⚠ urgent warning'
    }

    It 'replays a deferred upload through its original Telegram endpoint' {
        Add-TelegramOutboxItem -Uri 'https://api.example/sendPhoto' -Form @{ chat_id = '101'; photo = 'test.jpg' } -DueAt (Get-Date).AddMinutes(-1) -Attempts 0 | Out-Null
        Update-TelegramOutbox

        Should -Invoke Start-BridgeTelegramRequestWorker -Times 1 -Exactly -ParameterFilter {
            $Request.Uri -eq 'https://api.example/sendPhoto' -and $Request.Form.photo -eq 'test.jpg'
        }
    }

    It 'retains an uploaded report after caller cleanup then deletes its owned copy on success' {
        $source = Join-Path $TestDrive 'report.html'
        Set-Content -LiteralPath $source -Value 'report body'
        Add-TelegramOutboxItem -Form @{ document = Get-Item $source } -DueAt (Get-Date).AddMinutes(-1) -Attempts 0 | Should -BeTrue
        $copy = $script:TelegramOutbox[0].Form.document.FullName
        Remove-Item -LiteralPath $source
        Get-Content -LiteralPath $copy -Raw | Should -Match 'report body'
        Update-TelegramOutbox
        Mock Receive-BridgeTelegramRequestWorker { @{ Success = $true; StatusCode = 200; Error = '' } }
        Update-TelegramOutbox
        Test-Path -LiteralPath $copy | Should -BeFalse
    }

    It 'pauses the entire deferred queue after another flood response without copying the file again' {
        $source = Join-Path $TestDrive 'retry.html'
        Set-Content -LiteralPath $source -Value 'report'
        Add-TelegramOutboxItem -Form @{ document = Get-Item $source } -DueAt (Get-Date).AddMinutes(-1) -Attempts 0 | Out-Null
        $copy = $script:TelegramOutbox[0].Form.document.FullName
        Update-TelegramOutbox
        Add-TelegramOutboxItem -Body @{ text = 'next' } -DueAt (Get-Date).AddMinutes(-1) -Attempts 0 | Out-Null
        Mock Receive-BridgeTelegramRequestWorker { @{ Success = $false; StatusCode = 429; RetryAfterMs = 60000; Error = 'flood' } }
        Update-TelegramOutbox
        Update-TelegramOutbox
        Should -Invoke Start-BridgeTelegramRequestWorker -Times 1 -Exactly
        @($script:TelegramOutbox | Where-Object { $_.Form }).Count | Should -Be 1
        Test-Path -LiteralPath $copy | Should -BeTrue
        Clear-TelegramOutbox
        Test-Path -LiteralPath $copy | Should -BeFalse
        Test-Path -LiteralPath $source | Should -BeTrue
    }

    It 'removes the owned upload when queue pressure evicts it' {
        $source = Join-Path $TestDrive 'evicted.html'
        Set-Content -LiteralPath $source -Value 'report'
        Add-TelegramOutboxItem -Form @{ document = Get-Item $source } -DueAt (Get-Date).AddDays(1) -Attempts 0 | Out-Null
        $copy = $script:TelegramOutbox[0].Form.document.FullName
        foreach ($number in 1..200) { Add-TelegramOutboxItem -Body @{ text = "message $number" } -DueAt (Get-Date).AddDays(1) -Attempts 0 | Out-Null }
        Test-Path -LiteralPath $copy | Should -BeFalse
        Test-Path -LiteralPath $source | Should -BeTrue
    }
}

Describe 'The handover screen answers its first question first' {
    BeforeEach {
        $script:OnAir.Clear()
        $script:RuntimeState.Monitoring.CinegyHealthState = 'ok'
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'ok'
    }
    AfterEach { $script:OnAir.Clear() }

    It 'leads with what is on air, not ends with it' {
        # The text version reached it last, after the shows, the removals and
        # the failures - on the one screen somebody opens walking into a
        # gallery, where it is the first thing asked.
        $script:OnAir[7] = @{ Key = 'urgent'; Values = @{}; ShownAt = (Get-Date) }

        $blocks = @(Get-MissedEventsBlocks -Hours 12 -Records @())

        $blocks[0].type | Should -Be 'heading'
        $blocks[1].text | Should -Match 'على الهواء: urgent'
    }

    It 'says the screen is black rather than saying nothing' {
        @(Get-MissedEventsBlocks -Hours 12 -Records @())[1].text | Should -Match 'لا شيء على الهواء'
    }

    It 'keeps failures open and folds the general activity away' {
        # A failure is usually why this screen was opened; the activity log is
        # read only when something needs tracing.
        $records = @(
            [pscustomobject]@{ When = [datetime]'2026-08-31T21:00'; Action = 'SHOW'; Target = 'urgent'; Result = 'failed'; Message = 'انقطع الاتصال'; UserId = '10' }
            [pscustomobject]@{ When = [datetime]'2026-08-31T20:00'; Action = ''; Target = ''; Result = ''; Message = '📰 نُشر شريط الأخبار'; UserId = '10' }
        )
        Mock Get-OperatorTally { @{ Breakdown = ''; Single = 'سامي' } }
        Mock Get-AuditOperatorName { 'سامي' }

        $blocks = @(Get-MissedEventsBlocks -Hours 12 -Records $records)
        $texts = @($blocks | Where-Object { $_.ContainsKey('text') } | ForEach-Object { $_.text })
        $folded = @($blocks | Where-Object { $_.type -eq 'details' })

        @($texts | Where-Object { $_ -match 'انقطع الاتصال' }).Count | Should -Be 1
        $folded.Count | Should -Be 1
        $folded[0].summary | Should -Match 'تستحق الانتباه'
    }

    It 'keeps the shows table to four columns like every other table here' {
        $records = @(
            [pscustomobject]@{ When = [datetime]'2026-08-31T21:00'; Action = 'SHOW'; Target = 'urgent'; Result = 'success'; Message = ''; UserId = '10' }
        )
        Mock Get-OperatorTally { @{ Breakdown = ''; Single = 'سامي' } }

        $table = @(@(Get-MissedEventsBlocks -Hours 12 -Records $records) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[0]).Count | Should -Be 4
    }
}

Describe 'The operation history says what happened before it says what was done' {
    BeforeEach {
        Mock Get-TemplateCategoryLabel { 'أخبار' }
        Mock Get-OperationSentence { "عُرض $Target" }
    }

    It 'leads with a tally, because the question is whether anything failed' {
        # Reading ten rows to find that out is the work this screen exists to
        # save.
        Mock Get-UserOperationHistory {
            @(
                [pscustomobject]@{ At = '2026-08-31T20:00:00'; Action = 'SHOW'; Result = 'success'; Target = 'a'; Values = ''; OperationId = '' }
                [pscustomobject]@{ At = '2026-08-31T21:00:00'; Action = 'SHOW'; Result = 'failed'; Target = 'b'; Values = ''; OperationId = 'air-5023333b032c476eb48204ca08032a98' }
            )
        }

        $blocks = @(Get-MyOperationsBlocks -UserId 101)

        $blocks[0].type | Should -Be 'heading'
        $blocks[1].text | Should -Be 'عمليتان · ✅ 1 · ❌ 1'
    }

    It 'puts the newest first, not last' {
        Mock Get-UserOperationHistory {
            @(
                [pscustomobject]@{ At = '2026-08-31T20:00:00'; Action = 'SHOW'; Result = 'success'; Target = 'قديم'; Values = ''; OperationId = '' }
                [pscustomobject]@{ At = '2026-08-31T21:00:00'; Action = 'SHOW'; Result = 'success'; Target = 'أحدث'; Values = ''; OperationId = '' }
            )
        }

        $texts = @(@(Get-MyOperationsBlocks -UserId 101) | Where-Object { $_.ContainsKey('text') } | ForEach-Object { $_.text })

        @($texts | Where-Object { $_ -match 'أحدث' })[0] | Should -Not -BeNullOrEmpty
        [array]::IndexOf($texts, @($texts | Where-Object { $_ -match 'أحدث' })[0]) |
            Should -BeLessThan ([array]::IndexOf($texts, @($texts | Where-Object { $_ -match 'قديم' })[0]))
    }

    It 'spends one line on a successful operation, not five' {
        Mock Get-UserOperationHistory {
            @([pscustomobject]@{ At = '2026-08-31T21:00:00'; Action = 'SHOW'; Result = 'success'; Target = 'urgent'; Values = ''; OperationId = 'air-5023333b032c476eb48204ca08032a98' })
        }

        $lines = @(Get-MyOperationBlock -Item @(Get-UserOperationHistory -UserId 101)[0])

        @($lines).Count | Should -Be 1
        $lines[0].text | Should -Match 'أخبار'
        # The reference is eight characters of noise on a row that worked.
        $lines[0].text | Should -Not -Match '5023333b'
    }

    It 'brings the reference out only where somebody has to report it' {
        $item = [pscustomobject]@{ At = '2026-08-31T21:00:00'; Action = 'SHOW'; Result = 'failed'; Target = 'urgent'; Values = ''; OperationId = 'air-5023333b032c476eb48204ca08032a98' }

        $lines = @(Get-MyOperationBlock -Item $item)

        @($lines).Count | Should -Be 2
        $lines[1].text | Should -Match '5023333b'
        $lines[1].text | Should -Match 'افحص الاتصال'
    }

    It 'keeps the copy on its own line, because that is what the graphic is known by' {
        $item = [pscustomobject]@{ At = '2026-08-31T21:00:00'; Action = 'SHOW'; Result = 'success'; Target = 'urgent'; Values = 'عاجل: بيان الوزارة'; OperationId = '' }

        $lines = @(Get-MyOperationBlock -Item $item)

        @($lines).Count | Should -Be 2
        $lines[1].text | Should -Be '📝 عاجل: بيان الوزارة'
    }

    It 'shows three and folds the rest' {
        Mock Get-UserOperationHistory {
            @(1..8 | ForEach-Object {
                    [pscustomobject]@{ At = "2026-08-31T{0:00}:00:00" -f (8 + $_); Action = 'SHOW'; Result = 'success'; Target = "t$_"; Values = ''; OperationId = '' }
                })
        }

        $blocks = @(Get-MyOperationsBlocks -UserId 101)
        $folded = @($blocks | Where-Object { $_.type -eq 'details' })[0]

        $folded.summary | Should -Match 'أقدم \(5\)'
        @($blocks | Where-Object { $_.type -eq 'divider' }).Count | Should -Be 3
    }

    It 'promises the copy only on the screen that carries the button' {
        # Both the body and the keyboard ask the same function, so a screen
        # cannot describe a button it does not show.
        Mock Get-UserOperationHistory {
            @([pscustomobject]@{ At = '2026-08-31T21:00:00'; Action = 'SHOW'; Result = 'failed'; Target = 'a'; Values = ''; OperationId = 'air-5023333b032c476eb48204ca08032a98' })
        }

        $notice = @(@(Get-MyOperationsBlocks -UserId 101) | Where-Object { $_.ContainsKey('text') -and [string]$_.text -match 'حافظة جهازك' })
        $keyboard = Get-MyOperationsKeyboard -UserId 101
        $button = @($keyboard.inline_keyboard)[0][0]

        $notice | Should -HaveCount 1
        $notice[0].text | Should -Match 'زر «نسخ مرجع 5023333b»'
        $button.copy_text.text | Should -Be '5023333b'

        # No reference, no button, and so no promise.
        Mock Get-UserOperationHistory {
            @([pscustomobject]@{ At = '2026-08-31T21:00:00'; Action = 'SHOW'; Result = 'success'; Target = 'a'; Values = ''; OperationId = '' })
        }
        @(@(Get-MyOperationsBlocks -UserId 101) | Where-Object { $_.ContainsKey('text') -and [string]$_.text -match 'حافظة جهازك' }) | Should -BeNullOrEmpty
        $plain = Get-MyOperationsKeyboard -UserId 101
        @(@($plain.inline_keyboard) | ForEach-Object { $_ } | Where-Object { $_.ContainsKey('copy_text') }) | Should -BeNullOrEmpty
    }

    It 'falls back to the text screen when rich sending is refused' {
        Mock Send-TelegramRichMessage { $false }
        Mock Get-UserOperationHistory { @() }
        Mock Send-TelegramMessage { }

        Invoke-MyOperationsCommand -ChatId 101 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
    }
}

Describe 'Every button on screen goes somewhere' {
    It 'opens the main menu from the home button, in both spellings' {
        Mock Send-TelegramMessage {}
        Mock Confirm-TelegramCallback {}
        # Refused, so the text path is what runs. Without this the menu's rich
        # attempt escaped the mocks and made a real request to api.telegram.org
        # from inside the gate - two seconds and a 401 per run, for a screen
        # this test is not about.
        Mock Send-TelegramRichMessage { $false }

        # The whitelisted chat from config.example.json: an unauthorized one never reaches the router.
        $chatId = @(Get-JsonProp $config 'AllowedChatIds')[0]
        foreach ($data in @('menu', 'menu:main')) {
            Set-PendingState -ChatId $chatId -State @{ Mode = 'setting_value'; Name = 'MaxFieldLength'; UserId = $chatId }
            Invoke-CallbackQuery -CallbackQuery ([pscustomobject]@{
                    id = '1'; data = $data
                    message = [pscustomobject]@{ chat = [pscustomobject]@{ id = $chatId } }
                    from = [pscustomobject]@{ id = $chatId; first_name = 'x' }
                })
            # 🏠 is what an operator presses to get out of a flow: it must
            # clear what they had half-typed, not answer "unknown option".
            Get-PendingState -ChatId $chatId | Should -BeNullOrEmpty
        }
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly -ParameterFilter { $Text -match 'خيار غير معروف' }
    }

    It 'has a handler for every callback its keyboards emit' {
        # The audit that found the dead home button, kept as a test: a button
        # nothing handles answers «خيار غير معروف» and is only ever found by
        # someone pressing it.
        $source = (Get-ChildItem (Join-Path $script:Root 'Parts/*.ps1') | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
        $router = Get-Content -Raw (Join-Path $script:Root 'Parts/Bridge.Callbacks.ps1')
        $cases = @([regex]::Matches($router, "(?m)^\s{8}'([^']+)' \{") | ForEach-Object { $_.Groups[1].Value })
        $cases += @([regex]::Matches($router, "(?m)^\s{8}\{ \`$_ -in @\(([^)]+)\) \} \{") |
                ForEach-Object { $_.Groups[1].Value -split ',' } | ForEach-Object { $_.Trim().Trim("'") })

        $emitted = @([regex]::Matches($source, "New-Button\s+(?:`"[^`"]*`"|'[^']*')\s+'([a-z][a-zA-Z:]*)'") |
                ForEach-Object { $_.Groups[1].Value }) +
        @([regex]::Matches($source, "callback_data\s*=\s*'([a-z][a-zA-Z:]*)'") | ForEach-Object { $_.Groups[1].Value })

        $dead = @(@($emitted | Sort-Object -Unique) | Where-Object {
                $value = $_
                -not @($cases | Where-Object { $value -like $_ })
            })
        $dead | Should -BeNullOrEmpty
    }
}

Describe 'The heartbeat the hang watchdog reads' {
    BeforeEach {
        $script:livenessFile = Join-Path $TestDrive "bridge-$([guid]::NewGuid().ToString('N')).liveness"
        $script:LivenessWriteFailed = $false
        Mock Write-BridgeLog {}
    }

    It 'writes the stamp and this process id, in that order' {
        # The stamp says the loop turned over; the id is what lets a manager
        # started after the bridge adopt it instead of reporting "stopped"
        # beside a bridge that is plainly on air.
        Write-BridgeLivenessStamp

        $lines = @(Get-Content -LiteralPath $script:livenessFile)
        [datetime]::Parse($lines[0], [cultureinfo]::InvariantCulture, 'RoundtripKind') |
            Should -BeOfType [datetime]
        [int]$lines[1] | Should -Be $PID
    }

    It 'retries a collision instead of announcing it' {
        # The failure this file actually sees is a reader landing on the
        # instant of the write - four in a fortnight on this installation,
        # every one gone by the next loop. Announced, each one reads in the
        # log as though the watchdog had stopped.
        $script:LivenessAttempts = 0
        Mock Set-Content {
            $script:LivenessAttempts++
            if ($script:LivenessAttempts -eq 1) { throw 'The process cannot access the file' }
        }

        Write-BridgeLivenessStamp

        $script:LivenessAttempts | Should -Be 2
        $script:LivenessWriteFailed | Should -BeFalse
        Should -Invoke Write-BridgeLog -Times 0 -Exactly
    }

    It 'says it once when both attempts fail, not once per loop' {
        # A read-only log folder would otherwise repeat this every thirty
        # seconds for as long as the bridge lives, drowning the log it is
        # complaining about.
        Mock Set-Content { throw 'Access to the path is denied' }

        Write-BridgeLivenessStamp
        Write-BridgeLivenessStamp
        Write-BridgeLivenessStamp

        $script:LivenessWriteFailed | Should -BeTrue
        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
            $Message -match 'twice' -and $Message -match 'Access to the path is denied'
        }
    }

    It 'does nothing at all when no heartbeat path is configured' {
        $script:livenessFile = ''
        { Write-BridgeLivenessStamp } | Should -Not -Throw
    }
}

function global:Test-BridgeTelegramHtml {
    <#
        Whether a string is HTML the Bot API will actually accept.

        Written after a screen went out with "<b>…<code>n</code>…</b>" in it.
        That reads as ordinary nesting and is not: bold, italic, underline,
        strikethrough and spoiler entities cannot be combined with code or
        pre, and the API answers the whole message with a 400 rather than
        dropping one entity - which on the phone is a button that does
        nothing.

        Returns the reasons it is not acceptable, empty when it is.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $allowed = @('b', 'strong', 'i', 'em', 'u', 'ins', 's', 'strike', 'del',
        'a', 'code', 'pre', 'span', 'tg-spoiler', 'tg-emoji', 'tg-time', 'blockquote')
    # code and pre may not share characters with any of these.
    $incompatible = @('b', 'strong', 'i', 'em', 'u', 'ins', 's', 'strike', 'del', 'span', 'tg-spoiler')

    $problems = [System.Collections.Generic.List[string]]::new()
    $open = [System.Collections.Generic.List[string]]::new()

    foreach ($match in [regex]::Matches($Text, '<(/?)([a-zA-Z-]+)(\s[^>]*)?>')) {
        $closing = $match.Groups[1].Value -eq '/'
        $name = $match.Groups[2].Value.ToLowerInvariant()
        if ($name -notin $allowed) { $problems.Add("unsupported tag <$name>"); continue }

        if ($closing) {
            if ($open.Count -eq 0) { $problems.Add("</$name> with nothing open"); continue }
            if ($open[$open.Count - 1] -ne $name) {
                $problems.Add("</$name> closes <$($open[$open.Count - 1])>")
                continue
            }
            $open.RemoveAt($open.Count - 1)
            continue
        }

        if ($name -eq 'blockquote' -and $open -contains 'blockquote') {
            $problems.Add('blockquote inside blockquote')
        }
        if ($name -in @('code', 'pre')) {
            foreach ($outer in $open) {
                if ($outer -in $incompatible) { $problems.Add("<$name> inside <$outer>") }
            }
        }
        if ($name -in $incompatible) {
            foreach ($outer in $open) {
                if ($outer -in @('code', 'pre')) { $problems.Add("<$name> inside <$outer>") }
            }
        }
        $open.Add($name)
    }

    foreach ($leftover in $open) { $problems.Add("<$leftover> never closed") }
    return @($problems)
}

Describe 'Every screen sent as HTML is HTML the Bot API accepts' {
    It 'rejects the combination that caused this test to exist' {
        # The validator has to fail on the real fault before it is worth
        # trusting on the screens.
        @(Test-BridgeTelegramHtml -Text '<b>failed: <code>3</code></b>') | Should -Not -BeNullOrEmpty
        @(Test-BridgeTelegramHtml -Text '<blockquote>a<blockquote>b</blockquote></blockquote>') | Should -Not -BeNullOrEmpty
        @(Test-BridgeTelegramHtml -Text '<b>unclosed') | Should -Not -BeNullOrEmpty
        @(Test-BridgeTelegramHtml -Text '<marquee>no</marquee>') | Should -Not -BeNullOrEmpty
        # Side by side is the correct shape, and a blockquote may hold both.
        @(Test-BridgeTelegramHtml -Text '<b>failed:</b> <code>3</code>') | Should -BeNullOrEmpty
        @(Test-BridgeTelegramHtml -Text '<blockquote expandable><b>a</b> <code>4</code></blockquote>') | Should -BeNullOrEmpty
    }

    It 'no source line nests code inside bold, italic, underline or strikethrough' {
        # Caught at the source rather than only on the screens a test happens
        # to render: the combination is easy to write and impossible to see.
        $offenders = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\Parts') -Filter '*.ps1' |
                ForEach-Object {
                    $file = $_.Name
                    @(Get-Content -LiteralPath $_.FullName) |
                        Where-Object { $_ -notmatch '^\s*#' } |
                        Where-Object { $_ -match '<(b|i|u|s|strong|em|ins|del|strike|tg-spoiler)>[^<]*<(code|pre)>' } |
                        ForEach-Object { "$file : $($_.Trim())" }
                })
        $offenders | Should -BeNullOrEmpty
    }

    It 'no keyboard row carries both a leading and a trailing comma' {
        # "        , @((New-Button ...), (New-Button ...)),"
        #
        # A leading comma makes the row an array; a trailing comma then joins
        # it to the next row as ONE comma expression, and every row ends up
        # wrapped a second time - [[button]] where Telegram wants [button].
        # It answers 400 and drops the whole message, so the operator taps and
        # nothing happens.
        #
        # Caught at the source because it is invisible on the screen and the
        # log line names neither the screen nor the row. The send-time repair
        # pass now flattens it, but a screen should not need repairing.
        $offenders = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\Parts') -Filter '*.ps1' |
                ForEach-Object {
                    $file = $_.Name
                    @(Get-Content -LiteralPath $_.FullName) |
                        Where-Object { $_ -notmatch '^\s*#' } |
                        Where-Object { $_ -match '^\s*, @\(.*\),\s*$' } |
                        Where-Object {
                            # A row whose buttons continue on the next line
                            # also ends in a comma, and is fine. It leaves
                            # brackets open; a complete row closes every one
                            # it opened, so the comma after it joins rows.
                            ([regex]::Matches($_, '\(')).Count -eq ([regex]::Matches($_, '\)')).Count
                        } |
                        ForEach-Object { "$file : $($_.Trim())" }
                })
        $offenders | Should -BeNullOrEmpty
    }

    It 'accepts the menu screen, the status screens and the digest as built' {
        # The screens themselves, not only the source pattern: an unbalanced
        # tag or a stray blockquote shows up here and nowhere else.
        $script:OnAir.Clear()
        @(Test-BridgeTelegramHtml -Text (Get-MainMenuIntro -UserId 7275359265)) | Should -BeNullOrEmpty

        $script:OnAir[4] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 1; Source = 'bridge' }
        $script:OnAir[7] = @{ Key = '<b>Logo'; At = (Get-Date); UserId = 1; Source = 'bridge' }
        @(Test-BridgeTelegramHtml -Text (Get-MainMenuIntro -UserId 7275359265)) | Should -BeNullOrEmpty

        # Past four layers the list is capped and a summary line appears -
        # different output, so it is validated too.
        foreach ($layer in 1..7) { $script:OnAir[$layer] = @{ Key = "t$layer"; At = (Get-Date); UserId = 1; Source = 'bridge' } }
        @(Test-BridgeTelegramHtml -Text (Get-MainMenuIntro -UserId 7275359265)) | Should -BeNullOrEmpty
        $script:OnAir.Clear()

        @(Test-BridgeTelegramHtml -Text (Get-RuntimeFileHealthText)) | Should -BeNullOrEmpty
        @(Test-BridgeTelegramHtml -Text (Get-UserActivitySummaryText)) | Should -BeNullOrEmpty
        @(Test-BridgeTelegramHtml -Text (Get-BridgeStatsText)) | Should -BeNullOrEmpty
        @(Test-BridgeTelegramHtml -Text (Get-UsageDigestText)) | Should -BeNullOrEmpty
        @(Test-BridgeTelegramHtml -Text (Get-FavoritesManagementText -UserId 7275359265)) | Should -BeNullOrEmpty
    }

    It 'gives the quote bar one meaning: detail that may be skipped' {
        # A mark that means two things teaches an operator nothing. The block
        # that IS a screen's answer is not quoted; the blocks that are evidence
        # under a verdict are, and fold once they are long enough that
        # scrolling past them costs the verdict its place on the phone.
        Get-UserActivitySummaryText | Should -Not -Match 'blockquote'

        $short = Get-RuntimeFileHealthText -Records @(
            [pscustomobject]@{ Name = 'onair.json'; State = 'healthy'; SizeText = '2 KB'; ModifiedAt = (Get-Date) })
        $short | Should -Match '<blockquote>'
        $short | Should -Not -Match 'expandable'

        $many = @(1..8 | ForEach-Object {
                [pscustomobject]@{ Name = "file$_.json"; State = 'healthy'; SizeText = '2 KB'; ModifiedAt = (Get-Date) } })
        $long = Get-RuntimeFileHealthText -Records $many
        $long | Should -Match '<blockquote expandable>'
        @(Test-BridgeTelegramHtml -Text $long) | Should -BeNullOrEmpty
    }

    It 'accepts the field prompt an operator types into' {
        # templates.json is written by hand, so a '<' can arrive in the key,
        # the label or the Titler variable name - and this screen shows all
        # three at once.
        $state = @{
            Key = '<b>عاجل'; Index = 0
            Fields = @('Ajel.center & co'); Labels = @('<i>العنوان'); Limits = @(0)
        }

        $text = Get-FieldPromptText -State $state
        @(Test-BridgeTelegramHtml -Text $text) | Should -BeNullOrEmpty
        $text | Should -Match '&lt;b&gt;عاجل'
        $text | Should -Match '&lt;i&gt;العنوان'
        $text | Should -Match '&amp;'
        # The variable name is monospace: it is the machine's name for the
        # field, not a label the operator should read as one.
        $text | Should -Match '<code>Ajel.center'

        # A field with no friendly label falls back to the raw name, and that
        # path has to be valid HTML too.
        $bare = Get-FieldPromptText -State @{ Key = 'k'; Index = 0; Fields = @('Ajel.center'); Labels = @(); Limits = @(0) }
        @(Test-BridgeTelegramHtml -Text $bare) | Should -BeNullOrEmpty
    }

    It 'accepts a template preview built from a hostile template' {
        # Key, category, description and field names are all typed by an
        # administrator; a '<' in any of them must come out escaped rather
        # than as a tag that unbalances the message.
        $template = [pscustomobject]@{
            Key = '<b>عاجل'; Layer = 4; Category = 'أخبار & تقارير'
            Description = 'وصف فيه <script> ورمز &'
            Fields = @('العنوان', '<i>النص')
        }

        $text = Get-TemplatePreviewText -Template $template
        @(Test-BridgeTelegramHtml -Text $text) | Should -BeNullOrEmpty
        $text | Should -Match '&lt;b&gt;عاجل'
        $text | Should -Match '&amp;'
        ConvertFrom-TelegramHtmlText $text | Should -Match '<script>'
    }
}

Describe 'Credentials are stripped before anything is shown or logged' {
    It 'redacts a bot token and a stream key out of any text' {
        # The two secrets that live inside a URL the bridge builds: the file
        # download URL carries the bot token in its path, and the relay output
        # URL is rtmp://host/s/<stream key>. Both end up inside library
        # exception messages, and both have a chat and a log to leak into.
        $withToken = Protect-SensitiveText 'GET https://api.telegram.org/file/bot8201739556:AAH0mQ7xKp2LrVnT4sYbZcDeFgHiJkLmNoP/photo.jpg failed'
        $withToken | Should -Not -Match '8201739556:'
        $withToken | Should -Match '\*\*\*BOT_TOKEN\*\*\*'

        $withKey = Protect-SensitiveText 'rtmp://dc.rtmp.t.me/s/2074119156:secretkey: Broken pipe'
        $withKey | Should -Not -Match 'secretkey'
        $withKey | Should -Match 'rtmp://\*\*\*'
    }
}

Describe 'A split page of HTML is still valid HTML' {
    It 'closes what a cut left open and reopens it on the next page' {
        # The banner report runs to 43 KB over a month. The splitter cuts at
        # the character limit knowing nothing about tags, so a cut inside a
        # blockquote left page one unclosed and page two opening nothing -
        # and Telegram answered 400 to both, which is how the reports screen
        # stopped working outright.
        $pages = @(Repair-TelegramHtmlChunks -Chunks @(
                '<blockquote expandable>first half',
                'second half</blockquote>'))

        $pages[0] | Should -Match '</blockquote>$'
        # Reopened with its attribute, not as a plain quote.
        $pages[1] | Should -Match '^<blockquote expandable>'
        foreach ($page in $pages) {
            @(Test-BridgeTelegramHtml -Text $page) | Should -BeNullOrEmpty
        }
    }

    It 'keeps nesting in the order it was cut in' {
        $pages = @(Repair-TelegramHtmlChunks -Chunks @(
                '<blockquote><b>bold start',
                'still bold</b></blockquote>'))
        # Innermost closes first on page one, outermost reopens first on two.
        $pages[0] | Should -Match '</b></blockquote>$'
        $pages[1] | Should -Match '^<blockquote><b>'
        foreach ($page in $pages) { @(Test-BridgeTelegramHtml -Text $page) | Should -BeNullOrEmpty }
    }

    It 'leaves a single page and a balanced pair alone' {
        @(Repair-TelegramHtmlChunks -Chunks @('<b>one page</b>'))[0] | Should -Be '<b>one page</b>'
        $pair = @(Repair-TelegramHtmlChunks -Chunks @('<b>a</b>', '<i>b</i>'))
        $pair[0] | Should -Be '<b>a</b>'
        $pair[1] | Should -Be '<i>b</i>'
    }

    It 'never reopens code or pre, which cannot contain anything' {
        # Reopening one would swallow the rest of the page as literal text.
        $pages = @(Repair-TelegramHtmlChunks -Chunks @('<code>cut here', 'and here</code>'))
        $pages[1] | Should -Not -Match '^<code>'
    }

    It 'survives an empty or absent set' {
        @(Repair-TelegramHtmlChunks -Chunks @()) | Should -BeNullOrEmpty
        @(Repair-TelegramHtmlChunks -Chunks $null) | Should -BeNullOrEmpty
    }
}

Describe 'One oversized screen must not cost the session its tables' {
    BeforeEach { Reset-RichBlockCapabilities; Mock Write-BridgeLog {} }

    It 'refuses to send a payload far larger than anything that renders here' {
        Test-RichPayloadSize -Length 4000 | Should -BeTrue
        Test-RichPayloadSize -Length 45000 | Should -BeFalse
    }

    It 'names the screen and warns while it still fits' {
        # The 7.87 outage was found only after a report had already stopped
        # rendering. Nothing watched the size until it was too late; a screen
        # crosses the limit gradually as a station's day fills up.
        $script:RichPayloadPeak = @{ Length = 0; Screen = '' }
        $script:RichPayloadWarned = @{}
        $warnings = [System.Collections.Generic.List[string]]::new()
        Mock Write-BridgeLog { if ($Level -eq 'WARN') { $warnings.Add($Message) } }

        $blocks = @(@{ type = 'heading'; text = '📊 تقرير الشريط (14)'; size = 3 })
        Register-RichPayloadMeasurement -Blocks $blocks -Length 9000
        # A smaller screen must not displace the peak.
        Register-RichPayloadMeasurement -Blocks @(@{ type = 'heading'; text = 'ℹ️ الحالة' }) -Length 900
        # The same screen with a different count in its heading is the same
        # screen: eight headings carry one, and keying on the text as written
        # made "warned once" mean once per count - a line all day, and a key
        # for every number for as long as the bridge ran.
        Register-RichPayloadMeasurement -Blocks @(@{ type = 'heading'; text = '📊 تقرير الشريط (15)'; size = 3 }) -Length 9100

        $peak = Get-RichPayloadPeak
        $peak.Screen | Should -Be '📊 تقرير الشريط (15)'
        $peak.Length | Should -Be 9100
        # 9100 of 12000, rounded: the figure is for a reader, not a budget.
        $peak.Percent | Should -Be 76
        @($warnings) | Should -HaveCount 1
        $warnings[0] | Should -Match 'تقرير الشريط'
    }

    It 'gives editing the size gate sending has, instead of a 400 that costs a block type' {
        # editMessageText built a rich payload with no size check at all, and
        # the reorder screen re-renders on every press - so it would have paid
        # that price again on every arrow.
        Mock Write-BridgeLog {}
        Mock Invoke-BridgeTelegramRequest { throw 'the payload must never reach the API' }
        $huge = @(@{ type = 'heading'; text = 'ضخم' }, @{ type = 'paragraph'; text = ('x' * 40000) })

        Edit-TelegramRichMessage -ChatId 1 -MessageId 2 -Blocks $huge | Should -BeFalse

        Should -Invoke Invoke-BridgeTelegramRequest -Times 0 -Exactly
        # No type is blamed for what is a size problem.
        Test-RichBlocksSendable -Blocks @(@{ type = 'table'; cells = @() }) | Should -BeTrue
    }

    It 'does not blame a block type when the payload was simply too big' {
        # This is the whole fault: the banner report is the default one and
        # serialised to 45 KB over a month. As the first rich message of a
        # session its refusal found no type "proven yet", blamed all four, and
        # disabled heading, table, paragraph and details until restart - so
        # the status screens, the health centre and the digest all silently
        # lost their tables.
        Resolve-RichSendFailure -ErrorText '400 (Bad Request)' -Context 'sendRichMessage' `
            -PayloadLength 45000 -Blocks @(
                @{ type = 'heading'; text = 'x' }, @{ type = 'table'; cells = @() },
                @{ type = 'paragraph'; text = 'y' }, @{ type = 'details'; summary = 'z'; blocks = @() })

        foreach ($type in @('heading', 'table', 'paragraph', 'details')) {
            $script:RichBlockTypesUnavailable.ContainsKey($type) | Should -BeFalse
        }
        Should -Invoke Write-BridgeLog -ParameterFilter { $Message -match 'size, not a missing capability' }
    }

    It 'still blames an unproven type when the payload was a normal size' {
        # The narrowing exists for a real reason - a server without one block
        # type should lose that block type - and a small refusal still means
        # what it always meant.
        Resolve-RichSendFailure -ErrorText '400 (Bad Request)' -Context 'sendRichMessage' `
            -PayloadLength 900 -Blocks @(@{ type = 'timeline'; text = 'x' })
        $script:RichBlockTypesUnavailable.ContainsKey('timeline') | Should -BeTrue
    }

    It 'keeps the banner report inside what the bridge will send' {
        # The report the whole fault came from. Capped at forty rows for the
        # table; the text version still carries every row.
        Mock Get-BannerReportData {
            @{
                Label = 'شهر'; Operators = 3; Truncated = $false
                Sessions = @(1..300 | ForEach-Object {
                        [pscustomobject]@{
                            UserId = 7; Layer = 4; Target = "بنر رقم $_"
                            Values = 'نص طويل يمثل ما يظهر على الهواء في هذا البنر'
                            StartedAt = (Get-Date).AddMinutes(-$_); EndedAt = (Get-Date).AddMinutes(-$_ + 2)
                        }
                    })
            }
        }

        $json = (@{ blocks = @(Get-BannerReportBlocks -Period 'month'); is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)
        Test-RichPayloadSize -Length $json.Length | Should -BeTrue
        # And it says what it left out rather than pretending 40 is all of it.
        $json | Should -Match 'أحدث 40 من 300'
    }

    It 'keeps a month of bulletins inside it too' {
        # A station running a bulletin every hour makes some seven hundred
        # rows in a month - the same shape as the banner report, and it was
        # the one screen still uncapped after 7.87.
        Mock Get-MojazReportData {
            @{
                Label = 'شهر'; Operators = 4; Rows = 2100; Scheduled = 120; Truncated = $false
                Runs = @(1..700 | ForEach-Object {
                        [pscustomobject]@{
                            Name = "موجز الساعة $_"; UserId = 7; Rows = 3; Kind = 'manual'
                            StartedAt = (Get-Date).AddMinutes(-$_); EndedAt = (Get-Date).AddMinutes(-$_ + 2)
                        }
                    })
            }
        }

        $blocks = @(Get-MojazReportBlocks -Period 'month')
        $json = (@{ blocks = $blocks; is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)

        Test-RichPayloadSize -Length $json.Length | Should -BeTrue
        @($blocks | Where-Object { $_.type -eq 'table' })[0].cells.Count | Should -Be 41
        $json | Should -Match 'صفًّا أقدم غير معروضة'
        # The total still counts the whole window, not the shown rows: it is
        # the answer to "how much ran", and trimming it would understate the
        # month.
        $json | Should -Match 'الإجمالي: 700'
    }

    It 'keeps a library that nothing prunes inside it' {
        $script:MojazLibrary = [pscustomobject]@{
            Bulletins = @(1..250 | ForEach-Object {
                    [pscustomobject]@{ Id = "b$_"; Name = "موجز محفوظ رقم $_"; Revision = 2; Rows = @('a', 'b', 'c') }
                })
        }
        Mock Get-MojazBulletinSchedules { @() }
        Mock Test-MojazOnAir { $false }

        $blocks = @(Get-MojazLibraryBlocks)
        $json = (@{ blocks = $blocks; is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)

        Test-RichPayloadSize -Length $json.Length | Should -BeTrue
        @($blocks | Where-Object { $_.type -eq 'table' })[0].cells.Count | Should -Be 41
        # The heading still counts everything saved, because that is the
        # number the screen is asked for.
        $blocks[0].text | Should -Match '\(250\)'
    }

    It 'keeps a wholly rewritten ticker inside it' {
        # Replacing the strip is every old headline removed and every new one
        # added: two rows per item.
        Mock Get-NewsTickerDraft { @{ Items = @(1..40 | ForEach-Object { "خبر جديد رقم $_ بنص طويل بما يكفي ليشبه خبرًا حقيقيًا" }) } }
        Mock Get-NewsTickerConfiguredSnapshot {
            @{ Success = $true; Items = @(1..40 | ForEach-Object { "خبر قديم رقم $_ بنص طويل بما يكفي ليشبه خبرًا حقيقيًا" }) }
        }

        $blocks = @(Get-NewsPublishReviewBlocks -UserId 101)
        $json = (@{ blocks = $blocks; is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)

        Test-RichPayloadSize -Length $json.Length | Should -BeTrue
        @($blocks | Where-Object { $_.type -eq 'table' })[0].cells.Count | Should -Be 41
        # Additions first: they are what is about to go on air.
        @($blocks | Where-Object { $_.type -eq 'table' })[0].cells[1][0].text | Should -Be '➕'
        $json | Should -Match 'صفًّا أقدم غير معروضة'
    }

    It 'leaves a table that fits exactly as it is' {
        # The cap must not touch the ordinary case, which is every screen on
        # an ordinary day.
        $small = Select-RichTableRows -Items @(1..12)

        @($small.Rows).Count | Should -Be 12
        $small.Hidden | Should -Be 0
        Get-RichTableTrimNote -Hidden 0 -Shown 12 | Should -BeNullOrEmpty
        # And it keeps the newest when it does trim.
        $big = Select-RichTableRows -Items @(1..100)
        @($big.Rows)[-1] | Should -Be 100
        $big.Hidden | Should -Be 60
    }
}

Describe 'Every keyboard row is a row, not a lone button' {
    It 'builds each report keyboard as arrays of arrays' {
        # A one-button row written as $(if (...) { , @($button) }) loses the
        # comma's wrapper to the $( ), and the row arrives as a bare button.
        # Telegram answers "expected an Array of InlineKeyboardButton" - and
        # answers it to the whole message, so the rich table and its text
        # fallback both fail. Every report but تقرير العمل, the one kind with
        # no download row, stopped working.
        foreach ($kind in @('work', 'banners', 'news', 'mojaz')) {
            $rows = @((Get-ReportPeriodKeyboard -Kind $kind -Period 'today').inline_keyboard)
            $rows.Count | Should -BeGreaterThan 0
            foreach ($row in $rows) {
                $row -is [hashtable] | Should -BeFalse -Because "a row of the $kind keyboard is a bare button"
                @($row).Count | Should -BeGreaterThan 0
                foreach ($button in @($row)) { $button.callback_data | Should -Not -BeNullOrEmpty }
            }
        }
    }

    It 'holds for every keyboard the bridge can build without arguments' {
        # Swept rather than listed: the fault is one character of PowerShell
        # and can be written into any of them.
        $builders = @(Get-Command -CommandType Function -Name 'Get-*Keyboard' -ErrorAction SilentlyContinue |
                Where-Object { @($_.Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters }).Count -eq 0 })
        $builders.Count | Should -BeGreaterThan 0

        foreach ($builder in $builders) {
            $keyboard = & $builder.Name
            # ContainsKey, not a property read: a reply keyboard carries
            # "keyboard" instead, and under StrictMode asking for a key that
            # is not there throws rather than answering false.
            if ($keyboard -isnot [hashtable] -or -not $keyboard.ContainsKey('inline_keyboard')) { continue }
            foreach ($row in @($keyboard.inline_keyboard)) {
                $row -is [hashtable] | Should -BeFalse -Because "$($builder.Name) has a row that is a bare button"
            }
        }
    }
}

Describe 'Every screen now has a table to try before its text' {
    It 'gives the menu screen one row per live layer' {
        # The screen an operator opens most, and the last one that had no rich
        # version - so it stayed unlike the rest however its text was arranged.
        $script:OnAir.Clear()
        $script:OnAir[4] = @{ Key = 'Urgent'; At = (Get-Date).AddMinutes(-12); UserId = 777; Source = 'bridge' }
        $script:OnAir[7] = @{ Key = 'Logo'; At = (Get-Date).AddHours(-3); UserId = 0; Source = 'cinegy' }

        $blocks = @(Get-MainMenuIntroBlocks -UserId 777)
        $table = @($blocks | Where-Object { $_.type -eq 'table' })[0]
        # A header row plus one per layer, four columns.
        @($table.cells).Count | Should -Be 3
        @($table.cells[0]).Count | Should -Be 4
        $blocks[0].type | Should -Be 'heading'

        # No cap here: the text version stops at four because each layer costs
        # it two lines, but a table is read down its columns and capping would
        # only hide a live graphic.
        foreach ($layer in 1..9) { $script:OnAir[$layer] = @{ Key = "t$layer"; At = (Get-Date); UserId = 1; Source = 'bridge' } }
        $wide = @(Get-MainMenuIntroBlocks -UserId 777)
        @(@($wide | Where-Object { $_.type -eq 'table' })[0].cells).Count | Should -Be 10
        $script:OnAir.Clear()
    }

    It 'survives a menu record carrying neither a time nor an operator' {
        $script:OnAir.Clear()
        $script:OnAir[2] = @{ Key = 'bare' }
        { Get-MainMenuIntroBlocks -UserId 1 } | Should -Not -Throw
        $script:OnAir.Clear()
    }

    It 'gives the operating numbers and the runtime files a table too' {
        # Neither had a rich builder at all, which is why they looked unlike
        # every other screen no matter how their text was formatted.
        $stats = @(Get-BridgeStatsBlocks)
        @($stats | Where-Object { $_.type -eq 'table' }) | Should -Not -BeNullOrEmpty
        $stats[0].type | Should -Be 'heading'

        $files = @(Get-RuntimeFileHealthBlocks -Records @(
                [pscustomobject]@{ Name = 'broken.json'; State = 'broken'; SizeText = '0 KB'; ModifiedAt = (Get-Date) }
                [pscustomobject]@{ Name = 'ok.json'; State = 'healthy'; SizeText = '2 KB'; ModifiedAt = (Get-Date) }))
        $table = @($files | Where-Object { $_.type -eq 'table' })[0]
        # Faults first: on a screen opened because something is wrong, the
        # wrong thing must not be in row six.
        $table.cells[1][0].text | Should -Be 'broken.json'
    }

    It 'keeps all three inside what the bridge will send' {
        foreach ($blocks in @((Get-MainMenuIntroBlocks -UserId 1), (Get-BridgeStatsBlocks), (Get-RuntimeFileHealthBlocks))) {
            $json = (@{ blocks = @($blocks); is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)
            Test-RichPayloadSize -Length $json.Length | Should -BeTrue
        }
    }
}

Describe 'The usage summary as tables' {
    It 'ranks the templates in one table and the outcomes in another' {
        # Two questions, two tables: which templates carry the work, and how
        # the shift's operations ended. One table would need a column meaning
        # one thing in half its rows and something else in the others.
        $script:UsageCounts = @{ 'عاجل' = 42; 'ticker' = 3 }
        $script:TemplateLastUsed = @{ 'عاجل' = (Get-Date).AddHours(-2).ToString('o') }
        $script:CancelReasons = @{}

        $tables = @(@(Get-UsageDigestBlocks) | Where-Object { $_.type -eq 'table' })
        $tables.Count | Should -Be 2

        # Ranking: header plus one row per template, four columns.
        @($tables[0].cells).Count | Should -Be 3
        @($tables[0].cells[0]).Count | Should -Be 4
        $tables[0].cells[1][1].text | Should -Be 'عاجل'
        # Never used stays a dash rather than an empty cell.
        $tables[0].cells[2][3].text | Should -Be '—'

        # Outcomes: header plus the three the bridge counts.
        @($tables[1].cells).Count | Should -Be 4
    }

    It 'adds a third table only when a cancel reason was recorded' {
        $script:UsageCounts = @{}
        $script:CancelReasons = @{}
        @(@(Get-UsageDigestBlocks) | Where-Object { $_.type -eq 'table' }) | Should -HaveCount 1

        $script:CancelReasons = @{ 'wrong_template' = 3 }
        @(@(Get-UsageDigestBlocks) | Where-Object { $_.type -eq 'table' }) | Should -HaveCount 2
        $script:CancelReasons = @{}
    }

    It 'stays inside what the bridge will send' {
        $script:UsageCounts = @{}
        1..40 | ForEach-Object { $script:UsageCounts["قالب رقم $_"] = $_ }
        $json = (@{ blocks = @(Get-UsageDigestBlocks); is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)
        Test-RichPayloadSize -Length $json.Length | Should -BeTrue
        $script:UsageCounts = @{}
    }
}

Describe 'The list screens get their tables' {
    It 'tables the upcoming schedule, and pages it the way the text does' {
        Mock Get-UpcomingScheduleEvents {
            @(1..12 | ForEach-Object {
                    @{ TemplateKey = "قالب $_"; ScheduledAt = ([datetimeoffset]::Now.AddHours($_)).ToString('o'); Recurrence = 'once'; Id = "s$_" }
                })
        }
        $blocks = @(Get-UpcomingScheduleBlocks -Page 0 -PageSize 8)
        $table = @($blocks | Where-Object { $_.type -eq 'table' })[0]
        # Header plus one page of eight.
        @($table.cells).Count | Should -Be 9
        # The count in the heading is every event, not the page.
        $blocks[0].text | Should -Match '\(12\)'
    }

    It 'tables the pending requests without throwing on a bare record' {
        # These records are written at more than one call site; an absent key
        # would throw under StrictMode on the screen an administrator opens to
        # answer a waiting person.
        $script:PendingApprovals = @{ '55' = @{} ; '66' = @{ Name = 'سامي'; At = (Get-Date).AddMinutes(-9) } }
        $blocks = @(Get-PendingApprovalsBlocks)
        $table = @($blocks | Where-Object { $_.type -eq 'table' })[0]
        @($table.cells).Count | Should -Be 3
        $table.cells[1][1].text | Should -Be '—'
        $table.cells[2][1].text | Should -Be 'سامي'
        $script:PendingApprovals = @{}
    }

    It 'says plainly when a list is empty instead of drawing an empty table' {
        Mock Get-UpcomingScheduleEvents { @() }
        $blocks = @(Get-UpcomingScheduleBlocks)
        @($blocks | Where-Object { $_.type -eq 'table' }) | Should -BeNullOrEmpty
        $blocks[1].text | Should -Match 'لا توجد أحداث'

        $script:PendingApprovals = @{}
        @(@(Get-PendingApprovalsBlocks) | Where-Object { $_.type -eq 'table' }) | Should -BeNullOrEmpty
    }

    It 'returns nothing for a template history with no search term' {
        # The text version answers with an instruction; blocks would be a
        # heading over nothing, so the caller falls through to the text.
        @(Get-TemplateHistoryBlocks -Query '   ') | Should -BeNullOrEmpty
    }
}

Describe 'Editing text starts from the text' {
    It 'shows the current text, tap-to-copy, with a button that copies it' {
        # An editor fixing one word was retyping the headline. No bot can fill
        # a person's input box, so the nearest thing is one tap to the
        # clipboard - given twice: a <code> span, which Telegram makes
        # tap-to-copy, and a copy_text button for anyone who does not know it.
        Mock Send-TelegramMessage { $script:SentText = $Text; $script:SentMarkup = $ReplyMarkup; $script:SentMode = $ParseMode }

        Send-BridgeTextEditPrompt -ChatId 100 -Prompt 'أرسل النص البديل' `
            -Current 'الرئيس يفتتح المعرض' -CancelData 'news:reorder'

        $script:SentMode | Should -Be 'HTML'
        $script:SentText | Should -Match '<code>الرئيس يفتتح المعرض</code>'
        $script:SentText | Should -Match 'صندوق الرسالة'
        $rows = @($script:SentMarkup.inline_keyboard)
        # The copy button carries no callback_data: Telegram does the copy on
        # the device and the bridge never hears the press.
        $rows[0][0].copy_text.text | Should -Be 'الرئيس يفتتح المعرض'
        $rows[0][0].ContainsKey('callback_data') | Should -BeFalse
        $rows[1][0].callback_data | Should -Be 'news:reorder'
    }

    It 'colours the copy button, the only mark it can carry' {
        # No press reaches the bridge, so the button cannot change once sent -
        # its colour is chosen with the message or not at all. Blue is what
        # the bridge paints the action a screen offers.
        $button = New-CopyButton -Text 'نسخ' -Payload 'x'

        $button.style | Should -Be 'primary'
        $button.ContainsKey('callback_data') | Should -BeFalse
        # And it comes off the wire entirely when styles are turned off.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableButtonStyles' }
        # Serialisation reads the layout setting too; a lone button is the
        # same row either way, but the call still needs an answer.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'OneHandMode' }
        ConvertTo-TelegramReplyMarkupJson -ReplyMarkup @{ inline_keyboard = @(, @($button)) } |
            Should -Not -Match 'primary'
    }

    It 'says what the copy button will do, because nothing can be said after it' {
        # copy_text is handled by Telegram on the device: no callback reaches
        # the bridge, so the bot cannot confirm the press afterwards. The
        # notice is written before it, and names the button as labelled.
        Mock Send-TelegramMessage { $script:SentText = $Text; $script:SentMarkup = $ReplyMarkup }

        Send-BridgeTextEditPrompt -ChatId 100 -Prompt 'p' -Current 'الرئيس يفتتح المعرض' -CancelData 'x' `
            -CopyLabel '📋 نسخ العنوان'

        $script:SentText | Should -Match 'زر «نسخ العنوان» ينسخ النص إلى حافظة جهازك'
        # Nothing promised when there is no button to press.
        Send-BridgeTextEditPrompt -ChatId 100 -Prompt 'p' -Current '' -CancelData 'x'
        $script:SentText | Should -Not -Match 'حافظة جهازك'
    }

    It 'escapes the current text and offers no copy button when there is none' {
        Mock Send-TelegramMessage { $script:SentText = $Text; $script:SentMarkup = $ReplyMarkup }

        Send-BridgeTextEditPrompt -ChatId 100 -Prompt 'p' -Current '<b>عاجل' -CancelData 'x'
        $script:SentText | Should -Match '&lt;b&gt;عاجل'
        @(Test-BridgeTelegramHtml -Text $script:SentText) | Should -BeNullOrEmpty

        Send-BridgeTextEditPrompt -ChatId 100 -Prompt 'p' -Current '' -CancelData 'x'
        $script:SentText | Should -Match 'لا يوجد نص حالي'
        @($script:SentMarkup.inline_keyboard) | Should -HaveCount 1
    }
}

Describe 'What will appear on screen is marked as such' {
    It 'puts the on-air copy in code spans and nothing else in them' {
        # The review screen is where an operator decides whether to put this
        # on air, and the copy was indistinguishable from the labels
        # describing it. Telegram gives a bot no text colour; a monospace span
        # is the strongest distinction it has, and it is tap-to-copy too.
        $state = @{
            Key = 'عاجل'; LockLayer = 4; AutoHideSeconds = 0
            Fields = @('Ajel.top', 'Ajel.center'); Labels = @('العنوان', 'النص')
            Values = @{ 'Ajel.top' = 'الرئيس يفتتح المعرض' }
        }

        $text = Format-ShowReviewText -State $state
        @(Test-BridgeTelegramHtml -Text $text) | Should -BeNullOrEmpty
        $text | Should -Match '<code>الرئيس يفتتح المعرض</code>'
        # A field left empty is not dressed as on-air copy.
        $text | Should -Match '<i>\(متروك\)</i>'
        $text | Should -Match 'ما سيظهر على الشاشة'
    }
}

Describe 'Callback failure notice (log-driven)' {
    BeforeEach {
        Mock Write-BridgeLog { }
        Mock Confirm-TelegramCallback { }
        Mock Send-TelegramMessage { }
    }

    It 'tells the operator when a button dies to an unhandled error' {
        $callback = [pscustomobject]@{
            id = 'q1'
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 111 } }
        }
        Send-CallbackFailureNotice -CallbackQuery $callback | Should -BeTrue
        Should -Invoke Confirm-TelegramCallback -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 111 -and $Text -like '*حدث خطأ*' }
    }

    It 'stays silent and throw-proof when the callback carries no chat' {
        Send-CallbackFailureNotice -CallbackQuery ([pscustomobject]@{ id = 'q2' }) | Should -BeFalse
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}

Describe 'Restart-storm notice (log-driven)' {
    BeforeEach {
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-AdminBroadcast { }
        $script:startupHistoryFile = Join-Path $TestDrive 'startup-history.json'
    }

    It 'notifies once when the fourth startup lands inside 24 hours' {
        Register-BridgeStartup
        Register-BridgeStartup
        Register-BridgeStartup
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
        Register-BridgeStartup
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -like '*4 مرات*' }
        Register-BridgeStartup
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
    }

    It 'ignores a corrupt history file instead of failing startup' {
        'not json{{{' | Set-Content -LiteralPath (Join-Path $TestDrive 'startup-history.json')
        { Register-BridgeStartup } | Should -Not -Throw
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'stays silent when the threshold is set to zero' {
        Mock Get-SettingInt { 0 }
        Register-BridgeStartup
        Register-BridgeStartup
        Register-BridgeStartup
        Register-BridgeStartup
        Register-BridgeStartup
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }
}
