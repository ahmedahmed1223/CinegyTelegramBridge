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
