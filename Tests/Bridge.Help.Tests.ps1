#requires -Version 7
<#
    Bridge.Help.Tests.ps1 - the quick start card, the chapter index, and
    chapter navigation.

    The shared setup lives in Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Quick start card' {
    It 'gets a new operator to air in numbered steps' {
        $text = Get-QuickStartText -ChatId 100 -UserId 101
        $text | Should -Match 'بداية سريعة'
        $text | Should -Match 'القوالب'
        $text | Should -Match 'تأكيد'
    }

    It 'stays one screen so it is read rather than skimmed' {
        # Telegram splits past 4096; a quick start that needs splitting is not
        # a quick start.
        (Get-QuickStartText -ChatId 100 -UserId 101).Length | Should -BeLessThan 4096
    }
}

Describe 'Help chapters' {
    It 'hides the administrator chapter from an operator' {
        Mock Test-Admin { $false }
        @(Get-HelpChapters -ChatId 100 -UserId 202).Key | Should -Not -Contain 'admin'
    }

    It 'shows the administrator chapter to an administrator' {
        Mock Test-Admin { $true }
        @(Get-HelpChapters -ChatId 100 -UserId 101).Key | Should -Contain 'admin'
    }

    It 'keeps every chapter within one Telegram message' {
        Mock Test-Admin { $true }
        foreach ($chapter in @(Get-HelpChapters -ChatId 100 -UserId 101)) {
            (Get-HelpChapterText -Key $chapter.Key -ChatId 100 -UserId 101).Length |
                Should -BeLessThan 4096 -Because "chapter $($chapter.Key) must fit one screen"
        }
    }

    It 'numbers a chapter against the count the reader can actually see' {
        Mock Test-Admin { $false }
        $count = @(Get-HelpChapters -ChatId 100 -UserId 202).Count
        Get-HelpChapterText -Key 'show' -ChatId 100 -UserId 202 | Should -Match "من $count"
    }

    It 'returns nothing for a chapter key that does not exist' {
        Get-HelpChapterText -Key 'nope' -ChatId 100 -UserId 101 | Should -BeNullOrEmpty
    }
}

Describe 'Help index' {
    BeforeEach { Mock Test-Admin { $true } }

    It 'offers the quick start and the full guide' {
        $callbacks = @((Get-HelpHomeKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'help:quickstart'
        $callbacks | Should -Contain 'help:full'
    }

    It 'gives every visible chapter a button' {
        $callbacks = @((Get-HelpHomeKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        foreach ($chapter in @(Get-HelpChapters -ChatId 100 -UserId 101)) {
            $callbacks | Should -Contain "help:ch:$($chapter.Key)"
        }
    }

    It 'does not offer an operator a button to the administrator chapter' {
        Mock Test-Admin { $false }
        @((Get-HelpHomeKeyboard -ChatId 100 -UserId 202).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) |
            Should -Not -Contain 'help:ch:admin'
    }
}

Describe 'Chapter navigation' {
    BeforeEach { Mock Test-Admin { $true } }

    It 'gives the first chapter a next but no previous' {
        $first = @(Get-HelpChapters -ChatId 100 -UserId 101)[0]
        $callbacks = @((Get-HelpChapterKeyboard -Key $first.Key -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        @($callbacks | Where-Object { $_ -like 'help:ch:*' }).Count | Should -Be 1
        $callbacks | Should -Contain 'help:home'
    }

    It 'gives the last chapter a previous but no next' {
        $chapters = @(Get-HelpChapters -ChatId 100 -UserId 101)
        $last = $chapters[$chapters.Count - 1]
        $callbacks = @((Get-HelpChapterKeyboard -Key $last.Key -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        @($callbacks | Where-Object { $_ -like 'help:ch:*' }).Count | Should -Be 1
    }

    It 'walks forward through every chapter and lands on the last one' {
        $chapters = @(Get-HelpChapters -ChatId 100 -UserId 101)
        $key = $chapters[0].Key
        $visited = @($key)
        for ($step = 1; $step -lt $chapters.Count; $step++) {
            $next = @((Get-HelpChapterKeyboard -Key $key -ChatId 100 -UserId 101).inline_keyboard |
                    ForEach-Object { @($_) } | ForEach-Object callback_data |
                    Where-Object { $_ -like 'help:ch:*' })
            $key = ($next[$next.Count - 1] -replace '^help:ch:', '')
            $visited += $key
        }
        $visited | Should -Be @($chapters.Key)
    }

    It 'always offers the way back to the index' {
        foreach ($chapter in @(Get-HelpChapters -ChatId 100 -UserId 101)) {
            @((Get-HelpChapterKeyboard -Key $chapter.Key -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object callback_data) | Should -Contain 'help:home'
        }
    }
}

Describe 'The full guide stays reachable' {
    It 'still builds the one-screen manual behind the full guide button' {
        Mock Test-Admin { $true }
        $text = Get-HelpText -ChatId 100 -UserId 101
        $text | Should -Match 'دليل بوت Cinegy Air'
        $text.Length | Should -BeGreaterThan 1000
    }
}

Describe 'Google Sheets chapter' {
    It 'tells any operator how the sheet and the ticker line up' {
        Mock Test-Admin { $false }

        $text = Get-HelpChapterText -Key 'sheet' -ChatId 100 -UserId 202

        $text | Should -Match 'العمود الأول'
        $text | Should -Match 'سحب إلى المسودة'
    }

    It 'keeps the setup - and where the write token lives - to administrators' {
        Mock Test-Admin { $false }
        Get-HelpChapterText -Key 'sheet' -ChatId 100 -UserId 202 | Should -Not -Match 'config.json'

        Mock Test-Admin { $true }
        Get-HelpChapterText -Key 'sheet' -ChatId 100 -UserId 101 | Should -Match 'config.json'
    }
}

Describe 'The whole manual in one message' {
    It 'gives every chapter a collapsible block under one heading' {
        $blocks = @(Get-HelpRichBlocks -ChatId 101 -UserId 101)
        $details = @($blocks | Where-Object { $_.type -eq 'details' })

        $blocks[0].type | Should -Be 'heading'
        $details.Count | Should -BeGreaterThan 4
        foreach ($block in $details) {
            $block.summary | Should -Not -BeNullOrEmpty
            @($block.blocks).Count | Should -BeGreaterThan 0
        }
    }

    It 'never emits a block that opens onto nothing' {
        # A details control with an empty body reads as a chapter that failed
        # to load.
        foreach ($block in @(Get-HelpRichBlocks -ChatId 101 -UserId 101 | Where-Object { $_.type -eq 'details' })) {
            @($block.blocks | Where-Object { [string]::IsNullOrWhiteSpace($_.text) }).Count | Should -Be 0
        }
    }

    It 'keeps the administrator chapter out of an operator manual' {
        # Asserted on what the operator can read, not on how many blocks each
        # gets. Capping the guide to the payload limit trims from the end for
        # both roles, so the counts can now match while the content differs -
        # and the content is the thing that must not leak.
        Mock Test-Admin { $false }
        $operator = @(Get-HelpRichBlocks -ChatId 202 -UserId 202)
        $titles = @($operator | Where-Object { $_.type -eq 'details' } | ForEach-Object { [string]$_.summary })
        $tail = [string](@($operator)[-1].text)

        foreach ($adminChapter in @('الإعدادات', 'أدوات المشرف', 'من يدخل البوت')) {
            $titles | Should -Not -Contain $adminChapter
            # Nor named in the line that lists what was left out.
            if ($tail) { $tail | Should -Not -Match ([regex]::Escape($adminChapter)) }
        }
    }
}

Describe 'The settings chapter' {
    It 'explains the settings screen to an administrator and to nobody else' {
        Mock Test-Admin { $true }
        $text = Get-HelpChapterText -Key 'settings' -ChatId 101 -UserId 101
        $text | Should -Match 'المعدّل فقط'
        $text | Should -Match 'RequireUserLevelAuth'
        $text | Should -Match 'نسخ الإعدادات'

        Mock Test-Admin { $false }
        Get-HelpChapterText -Key 'settings' -ChatId 202 -UserId 202 | Should -BeNullOrEmpty
    }

    It 'names every settings door the screen actually has' {
        # The chapter said "the eight doors" and listed eight while the code
        # had nine. The one left out was 🔔 الإشعارات - whose own chapter this
        # same manual explains at length. A door nobody names is a door an
        # administrator never opens, and counting them by hand is how the
        # count went stale in the first place.
        Mock Test-Admin { $true }
        $text = Get-HelpChapterText -Key 'settings' -ChatId 101 -UserId 101
        foreach ($category in @(Get-SettingCategoryDefinitions)) {
            # The manual shortens a label - "الأمان والصلاحيات" appears as
            # "الأمان" - so the first word is what has to be there.
            $head = ([string]$category.Label -split ' ')[0]
            $text | Should -Match ([regex]::Escape($head)) -Because "the settings chapter must name the '$($category.Key)' door"
        }
    }

    It 'names every protected setting the guard actually protects' {
        # The list is introduced with "وهي:", which is a claim to be complete.
        # It named five of seven.
        Mock Test-Admin { $true }
        $text = Get-HelpChapterText -Key 'settings' -ChatId 101 -UserId 101
        foreach ($name in @($script:ProtectedSettings)) {
            $text | Should -Match ([regex]::Escape($name)) -Because "$name asks for confirmation, so the manual must say so"
        }
    }

    It 'sets a section head in bold and a real setting name in code' {
        Mock Test-Admin { $true }
        $text = Get-HelpChapterText -Key 'settings' -ChatId 101 -UserId 101
        $text | Should -Match '<b>[^<]*التعديل:</b>'
        $text | Should -Match '<code>EnableRawCommand</code>'
        # A word that is not a setting stays plain: the code style is the
        # reader's promise that the name can be searched for in ⚙️ الإعدادات.
        $text | Should -Not -Match '<code>[^<]*الإعداد'
    }

    It 'keeps every help tag inside one line, because the splitter cuts between them' {
        Mock Test-Admin { $true }
        foreach ($line in ((Get-HelpText -ChatId 101 -UserId 101) -split "`n")) {
            (([regex]::Matches($line, '<[a-z]')).Count) | Should -Be (([regex]::Matches($line, '</[a-z]')).Count)
        }
    }
}

Describe 'The manual covers what the bridge actually grew' {
    BeforeEach {
        Mock Test-Admin { $true }
        # The bulletin chapter is gated on Test-MojazAvailable, which asks the
        # template registry for a 'Mojaz' entry. On a station's own machine
        # templates.json has one and these passed; in CI only
        # templates.example.json exists - and it has no Mojaz - so the chapter
        # was absent and these four failed on EVERY push for weeks while the
        # same command was green on every developer's desk.
        #
        # templates.json is git-ignored on purpose (it holds the station's real
        # scene paths), so a test that reads it is a test that reads a file the
        # gate can never see. The registry is supplied here instead.
        Mock Test-MojazAvailable { $true }
    }

    It 'gives the bulletin a chapter of its own, open to every operator' {
        $chapters = @(Get-HelpChapters -ChatId 100 -UserId 202)
        $chapters.Key | Should -Contain 'mojaz'
        # Not admin-only: writing a bulletin is the operator's job.
        @($chapters | Where-Object { $_.Key -eq 'mojaz' })[0].AdminOnly | Should -BeFalse
    }

    It 'explains the parts an operator cannot guess from the buttons' {
        $body = (@(@(Get-HelpChapters -ChatId 100 -UserId 101) | Where-Object { $_.Key -eq 'mojaz' })[0].Body) -join "`n"

        # The three picture modes, and the one that is easy to misread.
        $body | Should -Match 'صورة خاصة'
        $body | Should -Match 'يتبع السابق'
        $body | Should -Match 'صورة القالب'
        # Why the loop length matters once sync is on.
        $body | Should -Match 'مزامنة الظهور'
        # Who yields to whom.
        $body | Should -Match 'العاجل أولى'
        # A saved appointment plays the latest rows, not the ones booked with.
        $body | Should -Match 'آخر نسخة محفوظة'
    }

    It 'tells an operator every way a ticker draft can end' {
        # Until 8.30.0 the only ways out were publishing or destroying the
        # draft, so the hand-over is the one an operator cannot guess is
        # there - and the discard now returns the text, which changes whether
        # pressing it is safe.
        $body = (@(@(Get-HelpChapters -ChatId 100 -UserId 101) | Where-Object { $_.Key -eq 'news' })[0].Body) -join "`n"

        $body | Should -Match 'سلّم المسودة للتالي'
        $body | Should -Match 'يتابعها أول من يضغط'
        $body | Should -Match 'يُعيد إليك نصّ أخبارها'
        # The automatic sheet sync publishes to air on its own clock; the log
        # is where an operator finds out whether it did.
        $body | Should -Match 'سجل التنفيذ'
        # A draft left alone does not survive forever, and that is worth
        # knowing before leaving one open.
        $body | Should -Match 'تنتهي صلاحيتها'
    }

    It 'tells an operator the bulletin keeps an execution log too' {
        $body = (@(@(Get-HelpChapters -ChatId 100 -UserId 101) | Where-Object { $_.Key -eq 'mojaz' })[0].Body) -join "`n"

        $body | Should -Match 'سجل التنفيذ'
    }

    It 'explains the appearance sync once, not twice' {
        # It was written out in full and then again three lines later, which
        # cost the one-screen guide a whole chapter of its budget.
        $body = @(@(Get-HelpChapters -ChatId 100 -UserId 101) | Where-Object { $_.Key -eq 'mojaz' })[0].Body

        @($body | Where-Object { $_ -match '^🎬 مزامنة الظهور' }).Count | Should -Be 1
    }

    It 'tells administrators how the show and hide permissions read' {
        $body = (@(@(Get-HelpChapters -ChatId 100 -UserId 101) | Where-Object { $_.Key -eq 'settings' })[0].Body) -join "`n"

        $body | Should -Match 'قوالب للمشرفين'
        $body | Should -Match 'طبقات للمالك'
        # The two rules that are not obvious: empty means everyone, and an
        # automatic hide is never refused.
        $body | Should -Match 'فارغٌ يعني للجميع'
        $body | Should -Match 'الإخفاء الآلي لا يُمنع'
    }
}


Describe 'The rich guide fits the message it is sent in' {
    # It never did. Every chapter at once measured 115% of the payload limit
    # for an operator and 182% for an administrator, so Send-TelegramRichMessage
    # refused it every time and the reader always got the paged-text fallback -
    # the collapsible chapters this screen exists for had not once rendered.
    # The only sign was one warning line in bridge.log, which AGENTS.md says to
    # watch after every addition to a rich screen, and which nobody watched.
    It 'stays under the payload limit for an operator' {
        Mock Test-Admin { $false }
        $payload = ConvertTo-RichMessagePayload -Blocks (Get-HelpRichBlocks -ChatId 101 -UserId 101)
        Test-RichPayloadSize -Length $payload.Length | Should -BeTrue -Because "the operator guide is $($payload.Length) characters"
    }

    It 'stays under the payload limit for an administrator, who has three more chapters' {
        Mock Test-Admin { $true }
        Mock Test-StatusViewer { $true }
        $payload = ConvertTo-RichMessagePayload -Blocks (Get-HelpRichBlocks -ChatId 101 -UserId 101)
        Test-RichPayloadSize -Length $payload.Length | Should -BeTrue -Because "the administrator guide is $($payload.Length) characters"
    }

    It 'spends the budget it has instead of stopping at the first chapter that does not fit' {
        # The manual is bigger than one message and has been for a long time.
        # Stopping at the first overflow left more than a thousand characters
        # unused and dropped 🆘 حين يحدث خطأ - the chapter most worth having on
        # screen - to keep the run contiguous. Order is kept; gaps are named.
        Mock Test-Admin { $false }
        $blocks = @(Get-HelpRichBlocks -ChatId 101 -UserId 101)
        $shown = @($blocks | Where-Object { $_.type -eq 'details' } | ForEach-Object { [string]$_.summary })
        $all = @(Get-HelpChapters -ChatId 101 -UserId 101 | ForEach-Object { [string]$_.Title })

        $shown.Count | Should -BeLessThan $all.Count -Because 'this test is about what happens when it does not all fit'
        @($shown | Where-Object { $_ -match 'حين يحدث خطأ' }).Count | Should -Be 1
        # Kept in the manual's own order, so a chapter never appears before one
        # that precedes it.
        $positions = @($shown | ForEach-Object { $all.IndexOf($_) })
        @($positions | Sort-Object) -join ',' | Should -Be ($positions -join ',')
    }

    It 'names the chapters it had to leave out rather than stopping silently' {
        Mock Test-Admin { $true }
        Mock Test-StatusViewer { $true }
        $blocks = @(Get-HelpRichBlocks -ChatId 101 -UserId 101)
        $shown = @($blocks | Where-Object { $_.type -eq 'details' } | ForEach-Object { [string]$_.summary })
        $all = @(Get-HelpChapters -ChatId 101 -UserId 101 | ForEach-Object { [string]$_.Title })
        if ($shown.Count -lt $all.Count) {
            $tail = [string](@($blocks)[-1].text)
            $tail | Should -Match 'بقية الأبواب'
            foreach ($missing in @($all | Where-Object { $shown -notcontains $_ })) {
                $tail | Should -Match ([regex]::Escape($missing))
            }
        }
    }
}

Describe 'The manual carries only what the station has' {
    BeforeEach { Mock Test-Admin { $false } }

    It 'measures the complete manual with the urgent board enabled' {
        Mock Test-UrgentBoardAvailable { $true }
        $blocks = @(Get-HelpRichBlocks -ChatId 101 -UserId 101)
        $payload = ConvertTo-RichMessagePayload -Blocks $blocks
        Write-Host "HELP_MEASURE length=$($payload.Length) tail=$([string]$blocks[-1].text)"
        Test-RichPayloadSize -Length $payload.Length | Should -BeTrue
    }

    It 'offers the breaking-news board chapter only where the board exists' {
        # 8.40.0 shipped 1200 lines of feature with no chapter at all; and a
        # chapter about a scene this station has not got is dead text that
        # costs a live chapter its place on the one screen.
        Mock Test-UrgentBoardAvailable { $true }
        @(Get-HelpChapters -ChatId 1 -UserId 1).Key | Should -Contain 'urgent'

        Mock Test-UrgentBoardAvailable { $false }
        @(Get-HelpChapters -ChatId 1 -UserId 1).Key | Should -Not -Contain 'urgent'
    }

    It 'drops the bulletin chapter on a bridge without the bulletin scene' {
        Mock Test-MojazAvailable { $false }
        @(Get-HelpChapters -ChatId 1 -UserId 1).Key | Should -Not -Contain 'mojaz'
    }

    It 'keeps the chapter you open when something is broken on the screen' {
        # AGENTS.md names 🆘 حين يحدث خطأ the chapter most worth having on
        # screen, and it has been squeezed off once before. Adding the board
        # chapter pushed it off again until it was moved up beside the
        # emergency chapter it belongs with.
        Mock Test-UrgentBoardAvailable { $true }
        Mock Test-MojazAvailable { $true }
        $shown = @(Get-HelpRichBlocks -ChatId 1 -UserId 1 | Where-Object { $_.type -eq 'details' } | ForEach-Object { [string]$_.summary })

        $shown | Should -Contain '🆘 حين يحدث خطأ'
        $shown | Should -Contain '🚨 جدول العواجل'
    }

    It 'stays inside the payload limit it is measured against' {
        Mock Test-UrgentBoardAvailable { $true }
        Mock Test-MojazAvailable { $true }
        Mock Test-Admin { $true }

        (ConvertTo-RichMessagePayload -Blocks (Get-HelpRichBlocks -ChatId 1 -UserId 1)).Length | Should -BeLessThan 12000
    }
}

Describe 'The manual exists in both languages, chapter for chapter' {
    <#
        The manual is the one thing that is NOT in the catalogue: a chapter is
        forty lines of prose with live settings interpolated mid-sentence, and
        the number lands in a different clause in English than in Arabic.
        Bridge.Help.En.ps1 duplicates the structure deliberately.

        That trade is only safe with this guard. A chapter added to one
        language and not the other, or renamed in one, fails here by name -
        which is the whole reason the duplication is allowed to exist.
    #>
    BeforeEach {
        $script:OriginalHelpLanguage = Get-Setting 'Language'
        Mock Test-Admin { $true }
        Mock Test-StatusViewer { $true }
        Mock Test-UrgentBoardAvailable { $true }
        Mock Test-MojazAvailable { $true }
        Mock Test-BoardsAvailable { $true }
    }
    AfterEach {
        $config.Settings | Add-Member -NotePropertyName 'Language' -NotePropertyValue $script:OriginalHelpLanguage -Force
    }

    It 'defines exactly the same chapter keys, in the same order' {
        $arabic = @((Get-HelpChaptersAr -ChatId 101 -UserId 101).Key)
        $english = @((Get-HelpChaptersEn -ChatId 101 -UserId 101).Key)

        $english | Should -Be $arabic -Because "a chapter in one language only is a chapter half the station cannot read"
    }

    It 'keeps AdminOnly identical, so a language cannot leak an admin chapter' {
        $arabic = @(Get-HelpChaptersAr -ChatId 101 -UserId 101)
        $english = @(Get-HelpChaptersEn -ChatId 101 -UserId 101)

        for ($i = 0; $i -lt $arabic.Count; $i++) {
            [bool]$english[$i].AdminOnly | Should -Be ([bool]$arabic[$i].AdminOnly) -Because "chapter '$($arabic[$i].Key)' must be for the same audience in both"
        }
    }

    It 'gives every English chapter a title and a body' {
        foreach ($chapter in @(Get-HelpChaptersEn -ChatId 101 -UserId 101)) {
            [string]$chapter.Title | Should -Not -BeNullOrEmpty
            @($chapter.Body).Count | Should -BeGreaterThan 0 -Because "chapter '$($chapter.Key)' would open as a blank screen"
        }
    }

    It 'writes the English chapters in English' {
        # A chapter copied across and not translated is the failure this
        # duplication invites, and it looks fine until somebody reads it.
        $arabicLetters = [regex]'[\u0600-\u06FF]'
        foreach ($chapter in @(Get-HelpChaptersEn -ChatId 101 -UserId 101)) {
            $arabicLetters.IsMatch([string]$chapter.Title) | Should -BeFalse -Because "the English title of '$($chapter.Key)' still carries Arabic"
            $arabicLetters.IsMatch((@($chapter.Body) -join ' ')) | Should -BeFalse -Because "the English body of '$($chapter.Key)' still carries Arabic"
        }
    }

    It 'serves the English manual when the bridge is set to English' {
        $config.Settings | Add-Member -NotePropertyName 'Language' -NotePropertyValue 'en' -Force
        @(Get-HelpChapters -ChatId 101 -UserId 101)[0].Title | Should -Be '▶️ Putting a template on air'
        Get-QuickStartText -ChatId 101 -UserId 101 | Should -Match 'Quick start'

        $config.Settings | Add-Member -NotePropertyName 'Language' -NotePropertyValue 'ar' -Force
        @(Get-HelpChapters -ChatId 101 -UserId 101)[0].Title | Should -Be '▶️ نشر قالب'
        Get-QuickStartText -ChatId 101 -UserId 101 | Should -Match 'بداية سريعة'
    }
}

Describe 'The release notes in English' {
    <#
        The notes are a pair like the manual, and a shorter one on purpose:
        248 releases written for one Arabic station about screens as they
        were is not what an English operator opens this screen for. The ten
        newest are what anyone reads, and CHANGELOG.md ships beside the
        release for the rest.

        What that shape invites is drift. The English half is written by hand
        beside the Arabic, so a release cut without it silently leaves an
        English operator one release behind, reading "what's new" that is not.
    #>
    BeforeAll {
        $script:OriginalNotesLanguage = [string](Get-JsonProp $config.Settings 'Language')
    }
    AfterEach {
        $config.Settings | Add-Member -NotePropertyName 'Language' -NotePropertyValue $script:OriginalNotesLanguage -Force
    }

    It 'covers the newest Arabic releases, in the same order' {
        $config.Settings | Add-Member -NotePropertyName 'Language' -NotePropertyValue 'ar' -Force
        $arabic = @(Get-WhatsNewSections)
        $english = @(Get-WhatsNewSectionsEn)

        $english.Count | Should -BeGreaterThan 0
        @($english.Version) | Should -Be @($arabic | Select-Object -First $english.Count).Version -Because 'the English half must be the newest releases, not a set of its own'
    }

    It 'carries every note of the releases it covers' {
        $config.Settings | Add-Member -NotePropertyName 'Language' -NotePropertyValue 'ar' -Force
        $arabic = @(Get-WhatsNewSections)
        $english = @(Get-WhatsNewSectionsEn)

        for ($i = 0; $i -lt $english.Count; $i++) {
            @($english[$i].Items).Count | Should -Be @($arabic[$i].Items).Count -Because "release $($english[$i].Version) must say the same number of things in both languages"
        }
    }

    It 'writes the English notes in English' {
        $arabicLetters = [regex]'[\u0600-\u06FF]'
        foreach ($section in @(Get-WhatsNewSectionsEn)) {
            $arabicLetters.IsMatch((@($section.Items) -join ' ')) | Should -BeFalse -Because "release $($section.Version) still carries Arabic in its English notes"
        }
    }

    It 'serves the English notes when the bridge is set to English' {
        $config.Settings | Add-Member -NotePropertyName 'Language' -NotePropertyValue 'en' -Force
        $sections = @(Get-WhatsNewSections)
        $sections.Count | Should -Be @(Get-WhatsNewSectionsEn).Count
        [regex]'[\u0600-\u06FF]' | ForEach-Object { $_.IsMatch((@($sections[0].Items) -join ' ')) } | Should -BeFalse
    }
}
