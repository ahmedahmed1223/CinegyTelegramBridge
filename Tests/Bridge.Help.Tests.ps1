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
        Mock Test-Admin { $false }
        $operator = @(Get-HelpRichBlocks -ChatId 202 -UserId 202 | Where-Object { $_.type -eq 'details' })
        Mock Test-Admin { $true }
        $admin = @(Get-HelpRichBlocks -ChatId 101 -UserId 101 | Where-Object { $_.type -eq 'details' })

        $operator.Count | Should -BeLessThan $admin.Count
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
    BeforeEach { Mock Test-Admin { $true } }

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
