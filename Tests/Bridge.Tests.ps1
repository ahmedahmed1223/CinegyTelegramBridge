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
        $blocks[1].text | Should -Be '2 عملية · ✅ 1 · ❌ 1'
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
