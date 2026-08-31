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
                'NewsSheetNotifyScope' { 'admins' }
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

Describe 'News sheet pulled into the draft for review' {
    BeforeEach {
        $script:NewsTickerDraft = $null
        Mock Get-Setting {
            switch ($Name) {
                'NewsSheetCsvUrl' { 'https://docs.google.com/spreadsheets/d/x/export?format=csv' }
                'NewsFilePath' { Join-Path $TestDrive 'news.txt' }
                'NewsItemSeparator' { '|' }
                'NewsMaxItemLength' { 1000 }
                'NewsMaxItems' { 200 }
                'NewsSheetNotifyScope' { 'admins' }
                default { '' }
            }
        }
        Mock Get-SettingInt { if ($Name -eq 'NewsMaxItems') { 200 } elseif ($Name -eq 'NewsMaxItemLength') { 1000 } else { 1 } }
        Mock Get-NewsSheetCsvText { [pscustomobject]@{ Success = $true; Csv = "خبر أول`r`nخبر ثانٍ"; Error = '' } }
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('قديم'); Hash = 'h1'; Error = '' } }
        Mock Publish-NewsTickerFile { [pscustomobject]@{ Success = $true; Conflict = $false; BackupPath = ''; Hash = 'h2'; Error = '' } }
        Mock Save-NewsTickerDraft { $true }
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
    }

    It 'fills the draft and puts nothing on air' {
        $result = Invoke-NewsSheetSync -Trigger manual -Target draft -UserId 101 -ChatId 101
        $result.Success | Should -BeTrue
        $result.Drafted | Should -BeTrue
        Should -Invoke Publish-NewsTickerFile -Times 0 -Exactly
        @((Get-NewsTickerDraft -UserId 101).Items) | Should -Be @('خبر أول', 'خبر ثانٍ')
    }

    It 'replaces what the draft held rather than appending to it' {
        Invoke-NewsSheetSync -Trigger manual -Target draft -UserId 101 -ChatId 101 | Out-Null
        Invoke-NewsSheetSync -Trigger manual -Target draft -UserId 101 -ChatId 101 | Out-Null
        @((Get-NewsTickerDraft -UserId 101).Items).Count | Should -Be 2
    }

    It 'pulls into the draft even when the sheet matches what is on air' {
        # Unchanged only means there is nothing to publish; the operator asked
        # for a draft to work from, so they still get one.
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('خبر أول', 'خبر ثانٍ'); Hash = 'h1'; Error = '' } }
        (Invoke-NewsSheetSync -Trigger manual -Target draft -UserId 101 -ChatId 101).Drafted | Should -BeTrue
    }

    It 'refuses a draft pull with no named owner' {
        (Invoke-NewsSheetSync -Trigger manual -Target draft -UserId 0 -ChatId 0).Success | Should -BeFalse
    }

    It 'asks before taking over another operator draft' {
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; Items = @('يحرر') }
        $result = Invoke-NewsSheetSync -Trigger manual -Target draft -UserId 101 -ChatId 101
        $result.NeedsConfirmation | Should -BeTrue
        $result.Success | Should -BeFalse
    }

    It 'offers both the publish and the review pull on the news screen' {
        Mock Test-Admin { $true }
        $callbacks = @((Get-NewsTickerManagementKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'news:sheet'
        $callbacks | Should -Contain 'news:sheetdraft'
    }
}

Describe 'News sheet notice audience' {
    BeforeEach {
        $config | Add-Member -NotePropertyName 'AdminChatIds' -NotePropertyValue @(11) -Force
        $config | Add-Member -NotePropertyName 'AllowedChatIds' -NotePropertyValue @(11, 22, 33) -Force
    }

    It 'tells nobody when the scope is none' {
        @(Get-NewsSheetNoticeAudience -Scope 'none') | Should -BeNullOrEmpty
    }

    It 'tells only the administrators by default' {
        @(Get-NewsSheetNoticeAudience -Scope 'admins') | Should -Be @(11)
    }

    It 'tells every authorised chat once when the scope is all' {
        $audience = @(Get-NewsSheetNoticeAudience -Scope 'all')
        $audience | Should -Be @(11, 22, 33)
        @($audience | Where-Object { $_ -eq 11 }).Count | Should -Be 1
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
