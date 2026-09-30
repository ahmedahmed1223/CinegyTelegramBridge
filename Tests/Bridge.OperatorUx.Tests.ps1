#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Operator screens after the desktop usability review' {
    It 'shows the same eight bulletin stories in the table and its buttons' {
        Mock Get-MojazSceneTiming { $null }
        Mock Get-MojazTemplateImage { '' }
        Mock Get-MojazBulletinScheduleText { '' }
        $script:MojazPlayback = $null
        $rows = @(1..12 | ForEach-Object { [pscustomobject]@{ Id = "r$_"; Title = "خبر $_"; Text = 'نص'; Image = ''; ImageMode = 'inherit' } })
        $bulletin = [pscustomobject]@{ Id = 'b1'; Name = 'الصباح'; Rows = $rows }
        $table = @(Get-MojazBlocks -Bulletin $bulletin -Page 1 | Where-Object type -EQ 'table')[0]
        @($table.cells).Count | Should -Be 5
        [string]$table.cells[1][0].text | Should -Be '9'
        Get-MojazText -Bulletin $bulletin -Page 1 | Should -Not -Match '(?m)^1\. <b>'
    }
    It 'limits breaking news to four stories beside its selection and reading controls' {
        Mock Get-SettingInt { 10 } -ParameterFilter { $Name -eq 'NewsListPageSize' }
        Get-UrgentBoardPageSize | Should -Be 4
    }
    It 'keeps content controls on the compact home screen and moves reports into its secondary menu' {
        $compact = @((Get-MainMenuKeyboard -ChatId 100 -Compact).inline_keyboard | ForEach-Object { @($_) })
        $secondary = @((Get-MainMenuKeyboard -ChatId 100 -Secondary).inline_keyboard | ForEach-Object { @($_) })
        @($compact.callback_data) | Should -Contain 'menu:more'
        @($compact.callback_data) | Should -Not -Contain 'menu:reports'
        @($secondary.callback_data) | Should -Contain 'menu:reports'
        @($secondary.callback_data) | Should -Contain 'menu:main'
    }
    It 'previews the effective bulletin image without changing air or saving data' {
        Mock Get-MojazSelected { [pscustomobject]@{ Id = 'b1'; Name = 'الصباح'; Rows = @([pscustomobject]@{ Id = 'r1'; Title = 'خبر'; Text = 'نص' }) } }
        Mock Get-MojazTemplateImage { '' }
        Mock Get-MojazEffectiveImages { Join-Path $TestDrive 'preview.png' }
        Mock Send-TelegramPhoto {}
        Mock Send-TelegramMessage {}
        Mock Invoke-ShowTemplateResult {}
        Mock Save-MojazLibrary {}
        Set-Content -LiteralPath (Join-Path $TestDrive 'preview.png') -Value 'test'
        Show-MojazRowImage -RowId 'r1' -ChatId 100
        Should -Invoke Send-TelegramPhoto -Times 1 -Exactly
        Should -Invoke Invoke-ShowTemplateResult -Times 0
        Should -Invoke Save-MojazLibrary -Times 0
    }
    It 'keeps bulletin row actions in details and shows eight rows on a page' {
        Mock Get-MojazSceneTiming { $null }
        $script:MojazPlayback = $null
        $rows = @(1..10 | ForEach-Object { [pscustomobject]@{ Id = "r$_"; Title = 'عنوان'; Text = 'خبر'; ImageMode = 'inherit'; Image = '' } })
        $bulletin = [pscustomobject]@{ Id = 'b1'; Name = 'الصباح'; Rows = $rows; DelayFrames = 100; IntroFrames = 0; LastRowFrames = 0; SyncToLoop = $false }
        $buttons = @((Get-MojazKeyboard -Bulletin $bulletin).inline_keyboard | ForEach-Object { @($_) })
        @($buttons | Where-Object callback_data -Like 'mojaz:row:*').Count | Should -Be 8
        @($buttons.callback_data) | Should -Not -Contain 'mojaz:del:r1'
        @($buttons.callback_data) | Should -Contain 'mojaz:tools'
    }
    It 'summarizes feed outages without exposing command errors on the ordinary screen' {
        Mock Get-OutputMonitorStatus { [pscustomobject]@{ ActiveSource = 'primary'; PrimaryState = 'failed' } }
        Mock Get-FfmpegPath { 'ffmpeg' }
        Mock Get-BridgeOpenOutage { $null }
        Mock Get-BridgeOutageSummary { [pscustomobject]@{ Count = 1; WindowHours = 24; TotalSeconds = 10; LastGoodAt = $null } }
        $script:StreamOutages = @{ Outages = @([pscustomobject]@{ StartedAt = '2026-09-30T10:00:00'; EndedAt = '2026-09-30T10:00:10'; Kind = 'unreachable'; Source = 'https://source/'; Cause = 'ffmpeg: Error opening input https://source/' }) }
        $text = Get-FeedWatchText
        $text | Should -Not -Match 'Error opening|https://source/'
        Get-FeedWatchText -Details | Should -Match 'Error opening'
    }
    It 'shows changed setting names without HTML tags in the rich weekly report' {
        Mock Get-WeeklyReportData { [pscustomobject]@{
            Label = 'week'; NearLimit = $false; IdleTemplates = @(); Repeats = @()
            ChangedSettings = @('MaxFieldLength'); TickerPublishes = 0
            UrgentRunsStarted = 0; UrgentStoriesPlayed = 0; Truncated = $false
        } }
        $json = @(Get-WeeklyReportBlocks) | ConvertTo-Json -Depth 12
        $json | Should -Not -Match '<code>'
        $json | Should -Match 'MaxFieldLength'
    }
    It 'renders authored guide emphasis without escaped tags or Markdown markers' {
        $text = Format-HelpHtmlLine -Line '📐 **جدول**: <b>حقول</b>'
        $text | Should -Not -Match '&lt;b&gt;|\*\*'
        $text | Should -Match 'جدول.*حقول'
    }
    It 'renders release notes without literal emphasis markers' {
        Mock Get-WhatsNewSections { @{ Version = 'test'; Items = @('**تغيير** +++') } }
        Get-WhatsNewText | Should -Not -Match '\*\*|\+\+\+'
    }
    It 'tells an operator to ask an administrator when there are no programme boards' {
        Mock Get-ContentBoards { @() }
        Mock Test-Admin { $false }
        Mock Send-TelegramMessage {}
        Show-BoardsScreen -ChatId 100 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter {
            $Text -match 'المشرف' -and $Text -notmatch 'الإنشاء خطوتان'
        }
    }
    It 'shows eight news backups at a time while preserving their global restore indices' {
        Mock Get-NewsTickerBackupFiles { 1..20 | ForEach-Object { [pscustomobject]@{
            LastWriteTime = [datetime]'2026-09-30'; FullName = 'unused'
        } } }
        $buttons = @((Get-NewsTickerBackupsKeyboard -Page 1).inline_keyboard | ForEach-Object { @($_) })
        @($buttons | Where-Object callback_data -Like 'news:restore:*').Count | Should -Be 8
        @($buttons.callback_data) | Should -Contain 'news:restore:8'
        @($buttons.callback_data) | Should -Not -Contain 'news:restore:0'
    }
    It 'reuses the current message for read-only navigation but not an air command' {
        foreach ($data in @('menu:main', 'menu:templates', 'help:ch:boards', 'mojaz:row:r1', 'newsbackpage:1')) {
            Test-RedrawInPlacePress -Data $data | Should -BeTrue
        }
        Test-RedrawInPlacePress -Data 'mojaz:play' | Should -BeFalse
    }
    It 'translates connection states in the handover digest' {
        $script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'connected'
        $record = [pscustomobject]@{ Action = ''; Message = ''; Result = ''; When = [datetime]'2026-09-30'; Target = ''; UserId = '0' }
        $json = @(Get-MissedEventsBlocks -Records @($record)) | ConvertTo-Json -Depth 12
        $json | Should -Not -Match 'healthy|connected'
    }
}
