#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeNewsTicker.psm1') -Force
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
