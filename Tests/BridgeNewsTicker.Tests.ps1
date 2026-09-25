#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeNewsTicker.psm1') -Force

    # Should -Be compares strings through the culture, and culture comparison
    # IGNORES the very characters these tests exist for - a direction mark,
    # a zero-width space, a BOM. Written with Should -Be, a cleaning test
    # passed with the cleaning removed. Ordinal, element by element.
    function global:Assert-OrdinalEqual {
        param([Parameter(ValueFromPipeline)]$Actual, [Parameter(Mandatory)]$Expected)
        begin { $got = [System.Collections.Generic.List[string]]::new() }
        process { foreach ($item in @($Actual)) { $got.Add([string]$item) } }
        end {
            $want = @($Expected | ForEach-Object { [string]$_ })
            $shown = ($got | ForEach-Object { ($_.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ' }) -join ' | '
            $got.Count | Should -Be $want.Count -Because "the items were: $shown"
            for ($i = 0; $i -lt $want.Count; $i++) {
                [string]::Equals($got[$i], $want[$i], [StringComparison]::Ordinal) | Should -BeTrue -Because "item $i was '$($got[$i])' ($shown), expected '$($want[$i])'"
            }
        }
    }
}

Describe 'News ticker text model' {
    It 'parses Arabic separator items while dropping empty and duplicate entries' {
        $result = ConvertFrom-NewsTickerText -Text "خبر أول |`r`nخبر ثان |`r`n |`r`nخبر أول |" -Separator '|'

        $result.Success | Should -BeTrue
        $result.Items | Should -Be @('خبر أول','خبر ثان')
        $result.EmptyCount | Should -Be 1
        $result.DuplicateCount | Should -Be 1
    }

    It 'uses non-empty lines when an imported file has no configured separator' {
        $result = ConvertFrom-NewsTickerText -Text "خبر أول`r`n`r`nخبر ثان" -Separator '|'

        $result.Items | Should -Be @('خبر أول','خبر ثان')
        $result.EmptyCount | Should -Be 1
    }

    It 'rejects item and collection limits instead of truncating editorial text' {
        (ConvertFrom-NewsTickerText -Text '12345|' -Separator '|' -MaxItemLength 4).Success | Should -BeFalse
        (ConvertFrom-NewsTickerText -Text 'أ|ب|ج|' -Separator '|' -MaxItems 2).Success | Should -BeFalse
    }

    It 'serializes each item with the configured separator and a stable newline' {
        ConvertTo-NewsTickerText -Items @('خبر أول','خبر ثان') -Separator '||' |
            Should -Be "خبر أول ||`r`nخبر ثان ||`r`n"
    }
}

Describe 'Safe news ticker persistence' {
    BeforeEach {
        $script:NewsPath = Join-Path $TestDrive 'news.txt'
        $script:BackupPath = Join-Path $TestDrive 'backups'
        [IO.File]::WriteAllText($script:NewsPath, "قديم |`r`n", [Text.UTF8Encoding]::new($true))
    }

    It 'reads UTF-8 BOM content and returns a reproducible SHA-256 snapshot' {
        $first = Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|'
        $second = Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|'

        $first.Success | Should -BeTrue
        $first.Items | Should -Be @('قديم')
        $first.Hash | Should -Be $second.Hash
        $first.Hash | Should -Match '^[A-F0-9]{64}$'
    }

    It 'publishes atomically with BOM and preserves the old file as a backup' {
        $before = Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|'
        $result = Publish-NewsTickerFile -Path $script:NewsPath -Items @('جديد','ثان') `
            -ExpectedHash $before.Hash -Separator '|' -BackupDirectory $script:BackupPath -BackupKeepFiles 3

        $result.Success | Should -BeTrue
        Test-Path -LiteralPath $result.BackupPath | Should -BeTrue
        (Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|').Items | Should -Be @('جديد','ثان')
        $bytes = [IO.File]::ReadAllBytes($script:NewsPath)
        $bytes[0..2] | Should -Be @(0xEF,0xBB,0xBF)
    }

    It 'refuses to overwrite a file changed after the draft snapshot' {
        $before = Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|'
        [IO.File]::WriteAllText($script:NewsPath, "خارجي |`r`n", [Text.UTF8Encoding]::new($true))

        $result = Publish-NewsTickerFile -Path $script:NewsPath -Items @('مسودة') `
            -ExpectedHash $before.Hash -Separator '|' -BackupDirectory $script:BackupPath

        $result.Success | Should -BeFalse
        $result.Conflict | Should -BeTrue
        (Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|').Items | Should -Be @('خارجي')
    }

    It 'restores a selected backup while backing up the current file first' {
        $original = Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|'
        $published = Publish-NewsTickerFile -Path $script:NewsPath -Items @('حالي') `
            -ExpectedHash $original.Hash -Separator '|' -BackupDirectory $script:BackupPath
        $currentHash = (Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|').Hash

        $restored = Restore-NewsTickerBackup -Path $script:NewsPath -BackupPath $published.BackupPath `
            -ExpectedHash $currentHash -Separator '|' -BackupDirectory $script:BackupPath

        $restored.Success | Should -BeTrue
        (Get-NewsTickerSnapshot -Path $script:NewsPath -Separator '|').Items | Should -Be @('قديم')
    }
}

Describe 'What a pasted headline cannot carry onto the ticker' {
    <#
        Text copied out of WhatsApp, a browser or Word arrives carrying
        characters nobody typed: direction marks that reorder the words on
        air, zero-width joiners, soft hyphens, non-breaking spaces, a line
        break inside one headline. Every entry path - add, edit, paste,
        import, the sheet - parses through ConvertFrom-NewsTickerText, so the
        cleaning lives there once.
    #>
    It 'drops direction and zero-width controls, keeping the words' {
        $dirty = "`u{200F}شهيد`u{200E} في `u{202A}غزة`u{202C} `u{2067}الآن`u{2069}`u{FEFF}`u{00AD}"
        (ConvertFrom-NewsTickerText -Text $dirty -Separator '|').Items | Assert-OrdinalEqual -Expected @('شهيد في غزة الآن')
    }

    It 'turns tabs, non-breaking and repeated spaces into one space' {
        (ConvertFrom-NewsTickerText -Text "خبر`t `u{00A0}عاجل  من   الميدان" -Separator '|').Items | Assert-OrdinalEqual -Expected @('خبر عاجل من الميدان')
    }

    It 'keeps an emoji sequence joined' {
        # U+200D holds a family or flag emoji together; stripping it would
        # split one picture into several.
        $emoji = "خبر `u{1F468}`u{200D}`u{1F469}`u{200D}`u{1F467}"
        (ConvertFrom-NewsTickerText -Text $emoji -Separator '|').Items | Assert-OrdinalEqual -Expected @($emoji)
    }

    It 'never lets a line break survive inside one item' {
        # In separator mode a part can span lines; on air that is a broken strap.
        (ConvertFrom-NewsTickerText -Text "سطر أول`r`nتكملة |" -Separator '|').Items | Assert-OrdinalEqual -Expected @('سطر أول تكملة')
    }

    It 'treats an item that is only invisible characters as empty' {
        $parsed = ConvertFrom-NewsTickerText -Text "`u{200F}`u{200E}`nخبر" -Separator '|'
        $parsed.Items | Assert-OrdinalEqual -Expected @('خبر')
    }
}

Describe 'Splitting a paste into headlines' {
    It 'takes one headline per line, in the order pasted' {
        $parsed = ConvertFrom-NewsPasteText -Text "الأول`nالثاني`n`nالثالث" -Separator '|'
        $parsed.Items | Assert-OrdinalEqual -Expected @('الأول', 'الثاني', 'الثالث')
    }

    It 'splits on the separator instead when the paste carries one' {
        (ConvertFrom-NewsPasteText -Text "أ | ب | ج |" -Separator '|').Items | Assert-OrdinalEqual -Expected @('أ', 'ب', 'ج')
    }

    It 'strips the numbering and bullets a copied list brings' {
        $paste = "1. الأول`n2) الثاني`n٣- الثالث`n- الرابع`n• الخامس`n* السادس`n▪️ السابع"
        (ConvertFrom-NewsPasteText -Text $paste -Separator '|').Items |
            Should -Be @('الأول', 'الثاني', 'الثالث', 'الرابع', 'الخامس', 'السادس', 'السابع')
    }

    It 'leaves a headline that merely starts with a number alone' {
        # "3 شهداء" is news, not a list marker: no punctuation after the digit.
        (ConvertFrom-NewsPasteText -Text "3 شهداء في غزة`n2026 عام الأسرى" -Separator '|').Items |
            Should -Be @('3 شهداء في غزة', '2026 عام الأسرى')
    }

    It 'reports a repeated line once and counts the repeat' {
        $parsed = ConvertFrom-NewsPasteText -Text "خبر`nخبر`nآخر" -Separator '|'
        $parsed.Items | Assert-OrdinalEqual -Expected @('خبر', 'آخر')
        $parsed.DuplicateCount | Should -Be 1
    }

    It 'sets a too-long headline aside by name instead of failing the whole paste' {
        $long = 'ك' * 30
        $parsed = ConvertFrom-NewsPasteText -Text "قصير`n$long" -Separator '|' -MaxItemLength 20
        $parsed.Items | Assert-OrdinalEqual -Expected @('قصير')
        @($parsed.TooLong) | Assert-OrdinalEqual -Expected @($long)
    }
}
