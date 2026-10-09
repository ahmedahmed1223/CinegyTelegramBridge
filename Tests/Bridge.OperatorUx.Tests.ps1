#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Operator screens after the desktop usability review' {
    It 'waits a full minute before recovering a missing permanent graphic' {
        Mock Get-Setting { $true }
        Mock Get-TemplateStore { @{ Map = @{ logo = @{ Layer = 9; LongRunning = $true; Fields = @() } } } }
        Mock Get-TitlerLayerStatus { @{ Success = $true; IsOnAir = $false } }
        Mock Get-AdminNotifyIds { 100 }
        Mock Invoke-ShowTemplateResult { @{ Success = $true } }
        Mock Send-AdminBroadcast {}
        $script:MissingGraphicState = @{ logo = @{ RecoveryToken = 'test'; RecoveryDue = [datetime]'2026-10-09T12:01:00'; RecoveryLayer = 9; RecoveryPath = ''; Suppressed = $false } }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:00:59')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $Key -eq 'logo' }
    }
    It 'renders HTML administrator notices instead of exposing their tags' {
        Mock Test-QuietHoursActive { $false }
        Mock Add-BridgeAlertOccurrence { '' }
        Mock Test-BridgeNoticeSuppressed { $false }
        Mock Get-AdminNotifyIds { 100 }
        Mock Send-TelegramMessage {}
        Send-AdminBroadcast -Text '<b>📊 ملخص الاستخدام</b>' -ParseMode HTML
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ParseMode -eq 'HTML' -and $Text -eq '<b>📊 ملخص الاستخدام</b>' }
    }
    It 'resolves an uploaded relative image beside its bulletin template instead of the bridge' {
        $script:PreviewSceneRoot = Join-Path $TestDrive 'scene'
        $script:PreviewImagePath = Join-Path $script:PreviewSceneRoot 'Mojaz\bot\preview.png'
        New-Item -ItemType Directory -Path (Split-Path $script:PreviewImagePath) -Force | Out-Null
        Set-Content -LiteralPath $script:PreviewImagePath -Value 'test'
        Mock Get-MojazSelected { [pscustomobject]@{ Id = 'b1'; TemplateKey = 'Other'; Rows = @([pscustomobject]@{ Id = 'r1' }) } }
        Mock Get-TemplateStore { @{ Map = @{ Other = @{ Path = (Join-Path $script:PreviewSceneRoot 'Other.cintitle') } } } }
        Mock Get-MojazTemplateImage { '' }
        Mock Get-MojazEffectiveImages { '.\Mojaz\bot\preview.png' }
        Mock Send-TelegramPhoto {}
        Mock Send-TelegramMessage {}
        Show-MojazRowImage -RowId 'r1' -ChatId 100
        Should -Invoke Send-TelegramPhoto -Times 1 -Exactly -ParameterFilter { $FilePath -eq $script:PreviewImagePath }
        Should -Invoke Send-TelegramMessage -Times 0
    }
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

Describe 'Permanent graphic recovery guards' {
    BeforeEach {
        Mock Get-Setting { $true }
        Mock Get-TemplateStore { @{ Order = @('logo'); Map = @{ logo = @{ Layer = 9; Path = 'logo.cintitle'; LongRunning = $true; Fields = @() } } } }
        Mock Get-TitlerLayerStatus { @{ Success = $true; IsOnAir = $false } }
        Mock Get-AdminNotifyIds { 100 }
        Mock Invoke-ShowTemplateResult { @{ Success = $true } }
        Mock Send-AdminBroadcast {}
        Mock Send-TelegramMessage {}
        Mock Test-CallbackAdmin { $true }
        $script:LastSuccessfulLayerShows = @{}
        $script:MissingGraphicState = @{ logo = @{ Misses = 2; Alerted = $true; RecoveryToken = 'current'; RecoveryDue = [datetime]'2026-10-09T12:01:00'; RecoveryLayer = 9; RecoveryPath = 'logo.cintitle'; Suppressed = $false } }
    }
    It 'never replaces an occupied layer' {
        Mock Get-TitlerLayerStatus { @{ Success = $true; IsOnAir = $true } }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'does not treat an unreachable engine as an empty layer' {
        Mock Get-TitlerLayerStatus { @{ Success = $false; IsOnAir = $false } }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'requires an explicit empty status rather than an absent field' {
        Mock Get-TitlerLayerStatus { @{ Success = $true } }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'honours the keep-hidden reply and ignores a second press' {
        Resolve-GraphicRecoveryResponse -Token current -Action keep -ChatId 100 -UserId 100
        Resolve-GraphicRecoveryResponse -Token current -Action show -ChatId 100 -UserId 100
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:02:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'ignores old incident buttons' {
        Resolve-GraphicRecoveryResponse -Token old -Action show -ChatId 100 -UserId 100
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'does not let an operator cancel or force recovery' {
        Mock Test-CallbackAdmin { $false }
        Resolve-GraphicRecoveryResponse -Token current -Action keep -ChatId 200 -UserId 200
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 1
    }
    It 'drops pending recovery when the setting is disabled' {
        Mock Get-Setting { $false }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'cancels after deliberate layer removal' {
        Stop-GraphicRecoveryForLayer -Layer 9
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'refuses changed template paths rather than showing a replacement design' {
        Mock Get-TemplateStore { @{ Map = @{ logo = @{ Layer = 9; Path = 'changed.cintitle'; LongRunning = $true; Fields = @() } } } }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'does not invent values for a data-driven permanent graphic' {
        Mock Get-TemplateStore { @{ Map = @{ logo = @{ Layer = 9; Path = 'logo.cintitle'; LongRunning = $true; Fields = @('Headline') } } } }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'reuses the last successful values for a data-driven graphic' {
        $script:LastSuccessfulLayerShows[9] = @{ Key = 'logo'; Variables = @{ Headline = 'last approved' } }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -ParameterFilter { $Variables.Headline -eq 'last approved' -and $RequireEmptyLayer }
    }
    It 'keeps each incident independent and attempts it only once' {
        $script:MissingGraphicState['other'] = @{ RecoveryToken = 'other'; RecoveryDue = [datetime]'2026-10-09T12:03:00'; RecoveryLayer = 8; RecoveryPath = ''; Suppressed = $false }
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:01:00')
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:02:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
    }
    It 'never arms a countdown for an undelivered warning' {
        $script:MissingGraphicState = @{}
        Mock Get-SettingInt { 1 }
        Update-MissingGraphicWatchdog -LayerStatuses @(@{ Layer = 9; Success = $true; IsOnAir = $false })
        Update-GraphicRecoveryQueue -Now ([datetime]'2099-01-01')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
    It 'arms only after delivery and cancels when the graphic returns' {
        $script:MissingGraphicState = @{}
        Mock Get-SettingInt { 1 }
        Mock Get-Date { [datetime]'2026-10-09T12:00:00' }
        Mock Send-TelegramMessage { $script:LastTelegramMessageId = 42 }
        Update-MissingGraphicWatchdog -LayerStatuses @(@{ Layer = 9; Success = $true; IsOnAir = $false })
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:00:59')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
        Update-MissingGraphicWatchdog -LayerStatuses @(@{ Layer = 9; Success = $true; IsOnAir = $true })
        Update-GraphicRecoveryQueue -Now ([datetime]'2026-10-09T12:02:00')
        Should -Invoke Invoke-ShowTemplateResult -Times 0
    }
}
