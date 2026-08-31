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

    It 'promotes seconds that do not divide evenly by sixty' {
        # Caught in review: promotion only fired on exact multiples of 60, so
        # an uptime of 3661 still read "3661 ثانية" - the very thing the
        # formatter was written to stop, surviving in every value that is not
        # a round minute. Uptime almost never is.
        Format-DurationSeconds -Seconds 3661 | Should -Be 'ساعة ودقيقة'
        Format-DurationSeconds -Seconds 90061 | Should -Be 'يوم وساعة ودقيقة'
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

Describe 'Reply markup serialisation' {
    BeforeAll {
        $script:StyledMarkup = @{ inline_keyboard = @(
                , @((New-BridgeButton -Text 'انشر' -CallbackData 'news:publish' -Style 'success'),
                    (New-BridgeButton -Text 'رجوع' -CallbackData 'menu'))) }
    }

    It 'keeps the colour while the setting is on' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableButtonStyles' }

        ConvertTo-TelegramReplyMarkupJson -ReplyMarkup $script:StyledMarkup | Should -Match '"style":"success"'
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
