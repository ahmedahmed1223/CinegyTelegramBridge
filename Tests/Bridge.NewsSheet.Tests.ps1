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
        Mock Test-Admin { $true }
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; Items = @('يحرر') }
        $result = Invoke-NewsSheetSync -Trigger manual -UserId 101 -Confirmed
        $result.Success | Should -BeTrue
        Should -Invoke Publish-NewsTickerFile -Times 1 -Exactly
    }

    It 'asks before a manual sync would discard another operator draft' {
        Mock Test-Admin { $true }
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
        Mock Test-Admin { $true }
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; Items = @('يحرر') }
        $result = Invoke-NewsSheetSync -Trigger manual -Target draft -UserId 101 -ChatId 101
        $result.NeedsConfirmation | Should -BeTrue
        $result.Success | Should -BeFalse
    }

    It 'offers both the publish and the review pull to the lock holder' {
        Mock Test-Admin { $true }
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 101; OwnerChatId = 100; Items = @('يحرر') }
        $callbacks = @((Get-NewsTickerManagementKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'news:sheet'
        $callbacks | Should -Contain 'news:sheetdraft'
    }
}

Describe 'News sheet notice audience' {
    BeforeEach {
        $config | Add-Member -NotePropertyName 'AdminChatIds' -NotePropertyValue @(11) -Force
        # Both lists, because "the administrators" now means every one of
        # them: an id with authority and no chat entry used to hear nothing.
        $config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @(11) -Force
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

Describe 'The draft lock binds the sheet pull too' {
    BeforeEach {
        Mock Get-Setting {
            switch ($Name) {
                'NewsSheetCsvUrl' { 'https://docs.google.com/x' }
                'AllowOperatorsSheetPull' { $true }
                'NewsItemSeparator' { '|' }
                'NewsFilePath' { Join-Path $TestDrive 'news.txt' }
                default { '' }
            }
        }
        Mock Get-NewsSheetCsvText { [pscustomobject]@{ Success = $true; Csv = "خبر"; Error = '' } }
        Mock Publish-NewsTickerFile { [pscustomobject]@{ Success = $true; Conflict = $false; BackupPath = ''; Hash = 'h2'; Error = '' } }
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('قديم'); Hash = 'h1'; Error = '' } }
        Mock Get-UserDisplayName { "مستخدم $UserId" }
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; Items = @('يحرر') }
    }

    It 'refuses an operator who would destroy another operator draft' {
        # Breaking a lock is an administrator action everywhere else in the
        # news screens; a sheet pull must not be the way around that.
        Mock Test-Admin { $false }
        $result = Invoke-NewsSheetSync -Trigger manual -Target air -UserId 101 -ChatId 101 -Confirmed
        $result.Success | Should -BeFalse
        $result.NeedsConfirmation | Should -BeFalse
        $result.Error | Should -Match 'طلب فكّ القفل'
        Should -Invoke Publish-NewsTickerFile -Times 0 -Exactly
    }

    It 'refuses the review pull to that operator as well' {
        Mock Test-Admin { $false }
        (Invoke-NewsSheetSync -Trigger manual -Target draft -UserId 101 -ChatId 101 -Confirmed).Success | Should -BeFalse
    }

    It 'still lets the owner pull over their own draft' {
        Mock Test-Admin { $false }
        (Invoke-NewsSheetSync -Trigger manual -Target air -UserId 202 -ChatId 202 -Confirmed).Success | Should -BeTrue
    }

    It 'lets an administrator override, as the unlock button does' {
        Mock Test-Admin { $true }
        (Invoke-NewsSheetSync -Trigger manual -Target air -UserId 101 -ChatId 101 -Confirmed).Success | Should -BeTrue
    }

    It 'hides the pull buttons from an operator while somebody else holds the draft' {
        Mock Test-Admin { $false }
        $callbacks = @((Get-NewsTickerManagementKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Not -Contain 'news:sheet'
        $callbacks | Should -Not -Contain 'news:sheetdraft'
        $callbacks | Should -Contain 'news:lockrequest'
    }

    It 'hides them from an administrator who does not hold the lock either' {
        # An administrator pulling over a live draft is the same two-writer
        # situation the lock exists to prevent. The unlock button is still
        # there: take the lock first, then pull.
        Mock Test-Admin { $true }
        $callbacks = @((Get-NewsTickerManagementKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Not -Contain 'news:sheet'
        $callbacks | Should -Not -Contain 'news:sheetdraft'
        $callbacks | Should -Contain 'news:unlock'
    }

    It 'shows them to the operator who does hold the lock' {
        Mock Test-Admin { $false }
        Mock Get-Setting {
            switch ($Name) {
                'NewsSheetCsvUrl' { 'https://docs.google.com/x' }
                'AllowOperatorsSheetPull' { $true }
                default { '' }
            }
        }
        $callbacks = @((Get-NewsTickerManagementKeyboard -ChatId 202 -UserId 202).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'news:sheet'
        $callbacks | Should -Contain 'news:sheetdraft'
    }

    It 'refuses a pull button pressed from a screen drawn before the lock moved' {
        # Hiding a button is not a rule: Telegram keeps old messages alive, so
        # the callback has to refuse it as well.
        Mock Test-Admin { $false }
        Get-CallbackRefusal -Data 'news:sheet' -ChatId 100 -UserId 101 | Should -Match 'القفل'
        Get-CallbackRefusal -Data 'news:sheetdraftconfirm' -ChatId 100 -UserId 101 | Should -Not -BeNullOrEmpty
        Get-CallbackRefusal -Data 'news:sheet' -ChatId 202 -UserId 202 | Should -BeNullOrEmpty
    }
}

Describe 'News sheet pull confirmation' {
    BeforeEach {
        $script:NewsTickerDraft = $null
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('خبر', 'آخر'); Hash = 'h1'; Error = '' } }
        Mock Get-UserDisplayName { "مستخدم $UserId" }
    }

    It 'warns that the publish pull overwrites the ticker, and says how much' {
        $prompt = Get-NewsSheetConfirmPrompt -Target air
        $prompt | Should -Match 'على الهواء'
        $prompt | Should -Match '2 خبرًا'
    }

    It 'makes clear the review pull reaches nothing on air' {
        Get-NewsSheetConfirmPrompt -Target draft | Should -Match 'لن يصل الهواء'
    }

    It 'names the draft owner in the same prompt rather than a second one' {
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; Items = @('يحرر') }
        Get-NewsSheetConfirmPrompt -Target air | Should -Match 'مستخدم 202'
    }

    It 'sends the publish confirmation to the publish callback' {
        @((Get-NewsSheetConfirmKeyboard -Target air).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) |
            Should -Be @('news:sheetconfirm', 'news:refresh')
    }

    It 'sends the review confirmation to the draft callback' {
        @((Get-NewsSheetConfirmKeyboard -Target draft).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) |
            Should -Be @('news:sheetdraftconfirm', 'news:refresh')
    }

    It 'keeps the plain pull callbacks separate from the confirmed ones' {
        # The button on the news screen must not be the one that acts, or the
        # confirmation would be skipped entirely.
        $plain = @('news:sheet', 'news:sheetdraft')
        $confirmed = @('news:sheetconfirm', 'news:sheetdraftconfirm')
        @($plain | Where-Object { $confirmed -contains $_ }) | Should -BeNullOrEmpty
    }
}

Describe 'Publishing writes the ticker back to the sheet' {
    BeforeEach {
        $config | Add-Member -NotePropertyName 'NewsSheetWriteUrl' -NotePropertyValue 'https://script.google.com/macros/s/x/exec' -Force
        $config | Add-Member -NotePropertyName 'NewsSheetWriteToken' -NotePropertyValue 'secret' -Force
        Mock Get-SettingInt { 30 }
    }

    It 'posts the published items and reports success' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"ok":true,"written":2}' } }
        $result = Save-NewsSheetItems -Items @('خبر أول', 'خبر ثانٍ')
        $result.Success | Should -BeTrue
        $result.Attempted | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Body -match 'خبر أول' -and $Body -match 'secret'
        }
    }

    It 'treats a rejected token as a failure even though Apps Script answers 200' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"ok":false,"error":"bad token"}' } }
        $result = Save-NewsSheetItems -Items @('خبر')
        $result.Success | Should -BeFalse
        $result.Attempted | Should -BeTrue
    }

    It 'reports a transport failure without throwing' {
        Mock Invoke-WebRequest { throw 'network down' }
        $result = Save-NewsSheetItems -Items @('خبر')
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'network down'
    }

    It 'does nothing at all when no write url is configured' {
        $config | Add-Member -NotePropertyName 'NewsSheetWriteUrl' -NotePropertyValue '' -Force
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"ok":true}' } }
        $result = Save-NewsSheetItems -Items @('خبر')
        $result.Attempted | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'refuses a write url that is not https' {
        $config | Add-Member -NotePropertyName 'NewsSheetWriteUrl' -NotePropertyValue 'http://script.google.com/x' -Force
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = '{"ok":true}' } }
        (Save-NewsSheetItems -Items @('خبر')).Success | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'keeps the write credentials out of an exported settings file' {
        # Invoke-SettingsExport writes only DefaultSettings keys, which is what
        # keeps the bot token out of a forwarded export. The write token rides
        # the same boundary.
        $script:DefaultSettings.Contains('NewsSheetWriteUrl') | Should -BeFalse
        $script:DefaultSettings.Contains('NewsSheetWriteToken') | Should -BeFalse
    }

    It 'mirrors to the sheet after a Telegram publish succeeds' {
        Mock Publish-NewsTickerFile { [pscustomobject]@{ Success = $true; Conflict = $false; BackupPath = ''; Hash = 'h'; Error = '' } }
        Mock Save-NewsSheetItems { [pscustomobject]@{ Success = $true; Attempted = $true; Error = '' } }
        Mock Add-AuditEntry {}; Mock Write-NewsPublishRecord {}; Mock Get-UserDisplayName { 'محرر' }
        Mock Get-Setting { if ($Name -eq 'NewsFilePath') { Join-Path $TestDrive 'n.txt' } elseif ($Name -eq 'NewsItemSeparator') { '|' } else { '' } }
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 101; BaseHash = 'h'; Items = @('خبر') }
        $result = Publish-NewsTickerDraft -UserId 101
        $result.Success | Should -BeTrue
        $result.SheetSaved | Should -BeTrue
        Should -Invoke Save-NewsSheetItems -Times 1 -Exactly
    }

    It 'does not undo a publish when the sheet write fails' {
        # The ticker is already on air. A refused mirror is reported, never
        # rolled back into taking the news off screen.
        Mock Publish-NewsTickerFile { [pscustomobject]@{ Success = $true; Conflict = $false; BackupPath = ''; Hash = 'h'; Error = '' } }
        Mock Save-NewsSheetItems { [pscustomobject]@{ Success = $false; Attempted = $true; Error = 'رفض' } }
        Mock Add-AuditEntry {}; Mock Write-NewsPublishRecord {}; Mock Get-UserDisplayName { 'محرر' }
        Mock Write-BridgeLog {}
        Mock Get-Setting { if ($Name -eq 'NewsFilePath') { Join-Path $TestDrive 'n.txt' } elseif ($Name -eq 'NewsItemSeparator') { '|' } else { '' } }
        $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 101; BaseHash = 'h'; Items = @('خبر') }
        $result = Publish-NewsTickerDraft -UserId 101
        $result.Success | Should -BeTrue
        $result.SheetSaved | Should -BeFalse
        $result.SheetError | Should -Be 'رفض'
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
    BeforeEach { $script:NewsTickerDraft = [ordered]@{ OwnerUserId = 202; OwnerChatId = 202; Items = @('يحرر') } }

    It 'offers the manual pull to the administrator holding the lock' {
        Mock Get-Setting { if ($Name -eq 'NewsSheetCsvUrl') { 'https://docs.google.com/x' } else { '' } }
        Mock Test-Admin { $true }
        @((Get-NewsTickerManagementKeyboard -ChatId 202 -UserId 202).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) |
            Should -Contain 'news:sheet'
    }

    It 'offers the pull to an operator too, because it is open by default' {
        Mock Test-Admin { $false }
        Mock Get-Setting {
            switch ($Name) {
                'NewsSheetCsvUrl' { 'https://docs.google.com/x' }
                'AllowOperatorsSheetPull' { $true }
                default { '' }
            }
        }
        $callbacks = @((Get-NewsTickerManagementKeyboard -ChatId 202 -UserId 202).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'news:sheet'
        # The review pull travels with it: an operator who may publish the
        # sheet may certainly load it into a draft first.
        $callbacks | Should -Contain 'news:sheetdraft'
    }

    It 'shows neither pull while nobody holds the lock' {
        # The gap the lock rule closes: with no draft open, any operator with
        # pull access could rewrite the ticker straight from the sheet.
        $script:NewsTickerDraft = $null
        Mock Test-Admin { $false }
        Mock Get-Setting {
            switch ($Name) {
                'NewsSheetCsvUrl' { 'https://docs.google.com/x' }
                'AllowOperatorsSheetPull' { $true }
                default { '' }
            }
        }
        $callbacks = @((Get-NewsTickerManagementKeyboard -ChatId 202 -UserId 202).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Not -Contain 'news:sheet'
        $callbacks | Should -Not -Contain 'news:sheetdraft'
        $callbacks | Should -Contain 'news:start'
        Get-CallbackRefusal -Data 'news:sheet' -ChatId 202 -UserId 202 | Should -Match 'بدء التحرير'
    }

    It 'puts the pull back behind the administrator bar when the switch is off' {
        Mock Test-Admin { $false }
        Mock Get-Setting {
            switch ($Name) {
                'NewsSheetCsvUrl' { 'https://docs.google.com/x' }
                'AllowOperatorsSheetPull' { $false }
                default { '' }
            }
        }
        $callbacks = @((Get-NewsTickerManagementKeyboard -ChatId 100 -UserId 202).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Not -Contain 'news:sheet'
        $callbacks | Should -Not -Contain 'news:sheetdraft'
    }

    It 'still lets an administrator pull when operators are barred' {
        Mock Test-Admin { $true }
        Mock Get-Setting {
            switch ($Name) {
                'NewsSheetCsvUrl' { 'https://docs.google.com/x' }
                'AllowOperatorsSheetPull' { $false }
                default { '' }
            }
        }
        Test-NewsSheetPullAccess -ChatId 100 -UserId 101 | Should -BeTrue
    }

    It 'hides the button when no sheet is configured' {
        Mock Get-Setting { '' }
        Mock Test-Admin { $true }
        @((Get-NewsTickerManagementKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) |
            Should -Not -Contain 'news:sheet'
    }
}

Describe 'A publish says what it did in both places' {
    It 'names the air and the sheet when both went through' {
        # The mirror to the sheet was reported nowhere: the one failure that
        # matters here - the air is right and the sheet is now behind - reached
        # the operator as an unqualified success.
        $result = [pscustomobject]@{ Success = $true; SheetSaved = $true; SheetError = '' }

        $text = Get-NewsPublishOutcomeText -Result $result -Lead '✅ نُشر شريط الأخبار على الهواء.'

        $text | Should -Match 'على الهواء'
        $text | Should -Match 'وحُدِّث الشيت'
    }

    It 'says the air is right and the sheet is behind when the mirror failed' {
        $result = [pscustomobject]@{ Success = $true; SheetSaved = $false; SheetError = 'رفض الشيت الكتابة' }

        $text = Get-NewsPublishOutcomeText -Result $result -Lead '✅ نُشر شريط الأخبار على الهواء.'

        $text | Should -Match 'تعذّر تحديث الشيت'
        $text | Should -Match 'رفض الشيت الكتابة'
        # The distinction that stops a needless re-publish.
        $text | Should -Match 'ما على الهواء منشور'
    }

    It 'says nothing about a sheet nobody configured' {
        $result = [pscustomobject]@{ Success = $true; SheetSaved = $false; SheetError = '' }

        $text = Get-NewsPublishOutcomeText -Result $result -Lead '✅ نُشر شريط الأخبار على الهواء.'

        $text | Should -Not -Match 'الشيت'
    }

    It 'trims a sheet error long enough to be a whole HTTP body' {
        $result = [pscustomobject]@{ Success = $true; SheetSaved = $false; SheetError = ('x' * 500) }

        $text = Get-NewsPublishOutcomeText -Result $result -Lead 'lead'

        $text.Length | Should -BeLessThan 400
        $text | Should -Match '…'
    }
}

Describe 'A sheet that stopped answering says so' {
    BeforeEach {
        $script:NewsSheetFailureStreak = 0
        $script:NewsSheetLastSuccessAt = (Get-Date).AddMinutes(-30)
        Mock Write-BridgeLog { }
        Mock Send-NewsSheetNotice { }
        Mock Get-SettingInt { 3 } -ParameterFilter { $Name -eq 'NewsSheetFailureAlertAfter' }
        # Set here, not in the Describe body: a variable there belongs to
        # Pester's discovery pass and is gone by the time a test runs.
        $script:failure = [pscustomobject]@{ Success = $false; Unchanged = $false; Skipped = $false; Error = 'تعذّر تنزيل الشيت' }
    }
    AfterAll { $script:NewsSheetFailureStreak = 0; $script:NewsSheetLastSuccessAt = $null }

    It 'stays quiet for the first misses, because one is weather' {
        1..2 | ForEach-Object { Update-NewsSheetHealthNotice -Result $script:failure }

        Should -Invoke Send-NewsSheetNotice -Times 0 -Exactly
    }

    It 'speaks on the third consecutive failure, with the reason' {
        1..3 | ForEach-Object { Update-NewsSheetHealthNotice -Result $script:failure }

        Should -Invoke Send-NewsSheetNotice -Times 1 -Exactly -ParameterFilter {
            $Text -match 'فشلت' -and $Text -match 'تعذّر تنزيل الشيت' -and $Cause
        }
    }

    It 'repeats only once per further run, not on every sync' {
        # Five minutes between syncs: without this it would be a message every
        # five minutes for as long as the sheet stayed broken.
        1..9 | ForEach-Object { Update-NewsSheetHealthNotice -Result $script:failure }

        Should -Invoke Send-NewsSheetNotice -Times 3 -Exactly
    }

    It 'carries a cause, so the hourly cap applies to it' {
        1..3 | ForEach-Object { Update-NewsSheetHealthNotice -Result $script:failure }

        Should -Invoke Send-NewsSheetNotice -Times 1 -Exactly -ParameterFilter { $Cause -eq 'news-sheet-sync-failing' }
    }

    It 'says it recovered, so the alert is not left hanging' {
        1..3 | ForEach-Object { Update-NewsSheetHealthNotice -Result $script:failure }

        Update-NewsSheetHealthNotice -Result ([pscustomobject]@{ Success = $true; Unchanged = $false; Skipped = $false; Error = '' })

        Should -Invoke Send-NewsSheetNotice -Times 1 -Exactly -ParameterFilter { $Text -match 'عادت مزامنة الشيت' }
        $script:NewsSheetFailureStreak | Should -Be 0
    }

    It 'treats an unchanged sheet as healthy, because it was reached' {
        1..3 | ForEach-Object { Update-NewsSheetHealthNotice -Result $script:failure }

        Update-NewsSheetHealthNotice -Result ([pscustomobject]@{ Success = $false; Unchanged = $true; Skipped = $false; Error = '' })

        $script:NewsSheetFailureStreak | Should -Be 0
    }

    It 'does not count a cycle skipped for an open draft as a failure' {
        # Yielding to somebody's draft is the sync working as designed.
        1..5 | ForEach-Object {
            Update-NewsSheetHealthNotice -Result ([pscustomobject]@{ Success = $false; Unchanged = $false; Skipped = $true; Error = '' })
        }

        $script:NewsSheetFailureStreak | Should -Be 0
        Should -Invoke Send-NewsSheetNotice -Times 0 -Exactly
    }

    It 'stays silent altogether when the threshold is zero' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'NewsSheetFailureAlertAfter' }

        1..20 | ForEach-Object { Update-NewsSheetHealthNotice -Result $script:failure }

        Should -Invoke Send-NewsSheetNotice -Times 0 -Exactly
    }
}
