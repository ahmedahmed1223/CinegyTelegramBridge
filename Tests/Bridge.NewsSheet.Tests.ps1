#requires -Version 7
<#
    Bridge.NewsSheet.Tests.ps1 - pulling the ticker from a Google Sheets CSV
    export, and the rules about who wins when a person is editing.

    The shared setup lives in Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Google Sheets CSV parsing' {
    It 'takes one item per row from the first column' {
        $items = @(ConvertFrom-NewsSheetCsv -Csv "خبر أول`r`nخبر ثانٍ`r`nخبر ثالث")
        $items.Count | Should -Be 3
        $items[0] | Should -Be 'خبر أول'
        $items[2] | Should -Be 'خبر ثالث'
    }

    It 'keeps a comma that lives inside a quoted cell' {
        # The old script appended " |" to raw lines, so a cell containing a
        # comma reached air still wrapped in its CSV quotes.
        $items = @(ConvertFrom-NewsSheetCsv -Csv '"القدس, عاصمة فلسطين"')
        $items.Count | Should -Be 1
        $items[0] | Should -Be 'القدس, عاصمة فلسطين'
    }

    It 'keeps only the first column when the sheet has more' {
        $items = @(ConvertFrom-NewsSheetCsv -Csv "الخبر,ملاحظة داخلية`r`nخبر ثانٍ,ملاحظة أخرى")
        $items | Should -Be @('الخبر', 'خبر ثانٍ')
    }

    It 'drops blank rows instead of publishing empty ticker items' {
        $items = @(ConvertFrom-NewsSheetCsv -Csv "خبر`r`n`r`n   `r`nخبر آخر")
        $items | Should -Be @('خبر', 'خبر آخر')
    }

    It 'returns nothing for an empty sheet rather than throwing' {
        @(ConvertFrom-NewsSheetCsv -Csv '') | Should -BeNullOrEmpty
        @(ConvertFrom-NewsSheetCsv -Csv "`r`n") | Should -BeNullOrEmpty
    }

    It 'trims the stray whitespace a spreadsheet leaves behind' {
        @(ConvertFrom-NewsSheetCsv -Csv '  خبر مسافات  ') | Should -Be @('خبر مسافات')
    }
}

Describe 'News sheet change summary' {
    It 'counts what was added and removed' {
        $summary = Get-NewsSheetChangeSummary -Before @('a', 'b') -After @('b', 'c', 'd')
        $summary.Added | Should -Be 2
        $summary.Removed | Should -Be 1
        $summary.Changed | Should -BeTrue
    }

    It 'reports no change when the sheet matches what is already on air' {
        (Get-NewsSheetChangeSummary -Before @('a', 'b') -After @('a', 'b')).Changed | Should -BeFalse
    }

    It 'treats a reordering as a change' {
        (Get-NewsSheetChangeSummary -Before @('a', 'b') -After @('b', 'a')).Changed | Should -BeTrue
    }
}

Describe 'News sheet sync rules' {
    BeforeEach {
        $script:NewsTickerDraft = $null
        Mock Get-Setting {
            switch ($Name) {
                'NewsSheetCsvUrl' { 'https://docs.google.com/spreadsheets/d/x/export?format=csv' }
                'NewsSheetSyncMode' { 'auto' }
                'NewsFilePath' { Join-Path $TestDrive 'news.txt' }
                'NewsItemSeparator' { '|' }
                'NewsSheetNotifyAdmins' { $true }
                default { '' }
            }
        }
        Mock Get-NewsSheetCsvText { [pscustomobject]@{ Success = $true; Csv = "خبر أول`r`nخبر ثانٍ"; Error = '' } }
        Mock Publish-NewsTickerFile { [pscustomobject]@{ Success = $true; Conflict = $false; BackupPath = ''; Hash = 'h2'; Error = '' } }
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('قديم'); Hash = 'h1'; Error = '' } }
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
    }

    It 'publishes the sheet straight to the on-air file' {
        $result = Invoke-NewsSheetSync -Trigger auto
        $result.Success | Should -BeTrue
        Should -Invoke Publish-NewsTickerFile -Times 1 -Exactly
    }

    It 'skips an automatic sync while an operator holds the draft' {
        # The operator is mid-sentence. Overwriting loses their work and they
        # would never learn why.
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; Items = @('يحرر') }
        $result = Invoke-NewsSheetSync -Trigger auto
        $result.Success | Should -BeFalse
        $result.Skipped | Should -BeTrue
        Should -Invoke Publish-NewsTickerFile -Times 0 -Exactly
    }

    It 'lets a manual sync proceed once the administrator confirmed it' {
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; Items = @('يحرر') }
        $result = Invoke-NewsSheetSync -Trigger manual -UserId 101 -Confirmed
        $result.Success | Should -BeTrue
        Should -Invoke Publish-NewsTickerFile -Times 1 -Exactly
    }

    It 'asks before a manual sync would discard another operator draft' {
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; Items = @('يحرر') }
        $result = Invoke-NewsSheetSync -Trigger manual -UserId 101
        $result.Success | Should -BeFalse
        $result.NeedsConfirmation | Should -BeTrue
        Should -Invoke Publish-NewsTickerFile -Times 0 -Exactly
    }

    It 'does not republish when the sheet says exactly what is already on air' {
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('خبر أول', 'خبر ثانٍ'); Hash = 'h1'; Error = '' } }
        $result = Invoke-NewsSheetSync -Trigger auto
        $result.Unchanged | Should -BeTrue
        Should -Invoke Publish-NewsTickerFile -Times 0 -Exactly
    }

    It 'refuses to run at all without a configured sheet url' {
        Mock Get-Setting { '' }
        $result = Invoke-NewsSheetSync -Trigger manual -UserId 101
        $result.Success | Should -BeFalse
        Should -Invoke Publish-NewsTickerFile -Times 0 -Exactly
    }

    It 'reports the download failure instead of publishing an empty ticker' {
        Mock Get-NewsSheetCsvText { [pscustomobject]@{ Success = $false; Csv = ''; Error = 'تعذّر الاتصال' } }
        $result = Invoke-NewsSheetSync -Trigger auto
        $result.Success | Should -BeFalse
        Should -Invoke Publish-NewsTickerFile -Times 0 -Exactly
    }

    It 'refuses an empty sheet rather than clearing the ticker silently' {
        # A sheet that failed to render, or one somebody emptied by accident,
        # must not take the ticker down with it.
        Mock Get-NewsSheetCsvText { [pscustomobject]@{ Success = $true; Csv = ''; Error = '' } }
        $result = Invoke-NewsSheetSync -Trigger auto
        $result.Success | Should -BeFalse
        Should -Invoke Publish-NewsTickerFile -Times 0 -Exactly
    }

    It 'tells the administrators what changed after a successful publish' {
        Invoke-NewsSheetSync -Trigger auto | Out-Null
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $Text -match 'الشيت' }
    }
}

Describe 'News sheet download guard' {
    It 'rejects a url that is not https' {
        $result = Get-NewsSheetCsvText -Url 'http://docs.google.com/x' -TimeoutSeconds 5 -MaxBytes 1024
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'https'
    }

    It 'rejects an empty url without attempting a request' {
        (Get-NewsSheetCsvText -Url '' -TimeoutSeconds 5 -MaxBytes 1024).Success | Should -BeFalse
    }
}

Describe 'News sheet operator surface' {
    BeforeEach { $script:NewsTickerDraft = $null }

    It 'offers the manual pull from the news management screen' {
        Mock Get-Setting { if ($Name -eq 'NewsSheetCsvUrl') { 'https://docs.google.com/x' } else { '' } }
        Mock Test-Admin { $true }
        @((Get-NewsTickerManagementKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) |
            Should -Contain 'news:sheet'
    }

    It 'hides the button when no sheet is configured' {
        Mock Get-Setting { '' }
        Mock Test-Admin { $true }
        @((Get-NewsTickerManagementKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) |
            Should -Not -Contain 'news:sheet'
    }
}
