#requires -Version 7
<#
    Bridge.SettingsScreens.Tests.ps1 - Settings screens, backups, presets, and import/export.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Version 6 settings discovery controls' {
    It 'exposes search modified simple and advanced views from settings home' {
        $callbacks = @((Get-SettingsKeyboard).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'cfg:search'
        $callbacks | Should -Contain 'cfglist:modified:0'
        $callbacks | Should -Contain 'cfglist:simple:0'
        $callbacks | Should -Contain 'cfglist:advanced:0'
    }

    It 'resets exactly one known setting after confirmation' {
        Mock Set-Setting {}
        Mock Send-TelegramMessage {}
        Reset-SingleSettingToDefault -Name 'MaxFieldLength' -ChatId 100 -UserId 101 -Confirmed
        Should -Invoke Set-Setting -Times 1 -Exactly -ParameterFilter { $Name -eq 'MaxFieldLength' -and $Value -eq $script:DefaultSettings['MaxFieldLength'] }
    }

    It 'asks before resetting a single setting instead of writing it' {
        Mock Set-Setting {}
        Mock Send-TelegramMessage {}
        Reset-SingleSettingToDefault -Name 'MaxFieldLength' -ChatId 100 -UserId 101
        Should -Invoke Set-Setting -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) -contains 'cfgrgo:MaxFieldLength'
        }
    }

    It 'ignores a reset for a name that is not a known setting' {
        Mock Set-Setting {}
        Mock Send-TelegramMessage {}
        Reset-SingleSettingToDefault -Name 'NotASetting' -ChatId 100 -UserId 101 -Confirmed
        Should -Invoke Set-Setting -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'routes the typed search term to the search list and clears the prompt' {
        Mock Send-TelegramMessage {}
        Start-SettingsSearch -ChatId 100 -UserId 101
        (Get-PendingState -ChatId 100).Mode | Should -Be 'settings_search'
        Complete-SettingsSearch -ChatId 100 -Value '  MaxFieldLength  '
        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty
        # The screen now names the term and counts what it found, so the
        # term is in the title rather than the last thing on the screen.
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match '«​MaxFieldLength»' -or $Text -match '«MaxFieldLength»' }
    }

    It 'lists only the settings the schema search matches' {
        Mock Send-TelegramMessage {}
        @(Find-BridgeSettings -Schema $script:SettingSchema -Query 'MaxFieldLength').Count | Should -Be 1
        Show-SettingsListScreen -Mode search -Query 'MaxFieldLength' -ChatId 100 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) -contains 'cfg:v:MaxFieldLength'
        }
    }

    It 'ignores a search completion when no search prompt is pending' {
        Mock Send-TelegramMessage {}
        Clear-PendingState -ChatId 100
        Complete-SettingsSearch -ChatId 100 -Value 'MaxFieldLength'
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}

Describe 'Settings access' {
    It 'falls back to the declared default for an unset key' {
        Get-SettingInt 'MaxFieldLength' 1 | Should -BeGreaterThan 0
    }

    It 'returns 0 for an unknown key rather than throwing' {
        Get-SettingInt 'NoSuchSettingAtAll' 0 | Should -Be 0
    }

    It 'declares every protected setting as a real boolean setting' {
        $ProtectedSettings | Should -Not -BeNullOrEmpty
        foreach ($name in $ProtectedSettings) {
            $DefaultSettings.Contains($name) | Should -BeTrue -Because "$name must exist in DefaultSettings"
            $DefaultSettings[$name] | Should -BeOfType ([bool])
        }
    }

    It 'exposes every declared setting through Get-Setting' {
        foreach ($name in $DefaultSettings.Keys) {
            { Get-Setting $name } | Should -Not -Throw
        }
    }

    It 'renders units and Arabic purpose for numeric administrator settings' {
        Format-SettingDisplay -Name 'CinegyStateCheckSeconds' -Value 15 | Should -Be '15 ثانية'
        Format-SettingDisplay -Name 'ConfigBackupKeepFiles' -Value 10 | Should -Be '10 ملفات'
        $prompt = Get-SettingPromptText -Name 'SnapshotRetentionMinutes'
        $prompt | Should -Match 'مدة الاحتفاظ'
        $prompt | Should -Match '30 دقيقة'
    }

    It 'formats an operator-friendly configured layer name while retaining its number' {
        $original = Get-Setting 'LayerNames'
        $config.Settings | Add-Member -NotePropertyName 'LayerNames' -NotePropertyValue '7=عاجل;8=شريط الأخبار' -Force

        try {
            Get-LayerDisplayName -Layer 7 | Should -Be 'عاجل · طبقة 7'
            Get-LayerDisplayName -Layer 8 | Should -Be 'شريط الأخبار · طبقة 8'
            Get-LayerDisplayName -Layer 4 | Should -Be 'طبقة 4'
        }
        finally { $config.Settings | Add-Member -NotePropertyName 'LayerNames' -NotePropertyValue $original -Force }
    }

    It 'stores one selected layer name without requiring a compound settings string' {
        $original = Get-Setting 'LayerNames'
        $config.Settings | Add-Member -NotePropertyName 'LayerNames' -NotePropertyValue '' -Force
        Mock Save-Config { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-TelegramMessage { }

        try {
            Set-LayerName -Layer 7 -Name 'عاجل' -ChatId 42 -UserId 42

            Get-Setting 'LayerNames' | Should -Be '7=عاجل'
            Get-LayerDisplayName -Layer 7 | Should -Be 'عاجل · طبقة 7'
        }
        finally { $config.Settings | Add-Member -NotePropertyName 'LayerNames' -NotePropertyValue $original -Force }
    }
}

Describe 'Configuration backups' {
    BeforeEach {
        $script:OriginalConfigPathForTest = $script:ConfigPath
        $script:ConfigPath = Join-Path $TestDrive 'config.json'
        Remove-Item -LiteralPath "$($script:ConfigPath).backups" -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $script:Root 'config.example.json') -Destination $script:ConfigPath
        Mock Write-BridgeLog { }
    }

    AfterEach { $script:ConfigPath = $script:OriginalConfigPathForTest }

    It 'creates a timestamped recoverable copy before saving configuration changes' {
        Save-Config -Path $script:ConfigPath

        $backupDirectory = "$($script:ConfigPath).backups"
        Test-Path -LiteralPath $backupDirectory | Should -BeTrue
        @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json').Count | Should -Be 1
    }

    It 'prunes old configuration backups beyond the retention limit' {
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'ConfigBackupKeepFiles' }

        1..4 | ForEach-Object { Save-Config -Path $script:ConfigPath }

        $backupDirectory = "$($script:ConfigPath).backups"
        @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json').Count | Should -Be 2
    }

    It 'restores a validated backup while preserving the current file as another backup' {
        Save-Config -Path $script:ConfigPath
        $backupDirectory = "$($script:ConfigPath).backups"
        $selectedBackup = Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' | Select-Object -First 1
        Set-Content -LiteralPath $script:ConfigPath -Value '{ "marker": "changed" }' -Encoding utf8

        $result = Restore-ConfigBackup -BackupPath $selectedBackup.FullName -Path $script:ConfigPath

        $result.Success | Should -BeTrue
        $restored = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        (Get-JsonProp $restored 'BotToken') | Should -Not -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json').Count | Should -BeGreaterThan 1
    }

    It 'lists saved versions as restore buttons for the admin interface' {
        Save-Config -Path $script:ConfigPath
        Save-Config -Path $script:ConfigPath

        $keyboard = Get-ConfigBackupsKeyboard -Path $script:ConfigPath
        $callbackData = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_['callback_data'] })

        $callbackData | Should -Contain 'cfg:restore:0'
        $callbackData | Should -Contain 'cfg:restore:1'
    }

    It 'summarizes changed top-level settings before restoring a backup' {
        Save-Config -Path $script:ConfigPath
        $backupDirectory = "$($script:ConfigPath).backups"
        $selectedBackup = Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' | Select-Object -First 1
        Set-Content -LiteralPath $script:ConfigPath -Value '{ "marker": "changed" }' -Encoding utf8
        (Get-JsonProp (Get-Content -LiteralPath $selectedBackup.FullName -Raw | ConvertFrom-Json) 'BotToken') | Should -Not -BeNullOrEmpty
        (Get-JsonProp (Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json) 'marker') | Should -Be 'changed'

        $summary = Get-ConfigDifferenceSummary -CurrentPath $script:ConfigPath -BackupPath $selectedBackup.FullName

        $summary | Should -Match 'BotToken'
        $summary | Should -Match 'marker'
    }

    It 'shows what each changed setting would become, never a credential value' {
        $current = Join-Path $TestDrive 'diff-current.json'
        $backup = Join-Path $TestDrive 'diff-backup.json'
        Set-Content -LiteralPath $current -Value '{ "BotToken": "1234:AAAA", "AdminChatIds": [1, 2, 3], "AirServerAddress": "10.0.0.1" }' -Encoding utf8
        Set-Content -LiteralPath $backup -Value '{ "BotToken": "9999:BBBBBB", "AdminChatIds": [7], "AirServerAddress": "10.0.0.1" }' -Encoding utf8

        $rows = Get-ConfigDifferenceRows -CurrentPath $current -BackupPath $backup

        @($rows | ForEach-Object Name) | Should -Not -Contain 'AirServerAddress'
        $token = $rows | Where-Object { $_.Name -eq 'BotToken' }
        $token.Current | Should -Not -Match 'AAAA'
        $token.Backup | Should -Not -Match 'BBBB'
        $token.Current | Should -Match '9'
        $ids = $rows | Where-Object { $_.Name -eq 'AdminChatIds' }
        $ids.Current | Should -Match '3'
        $ids.Backup | Should -Match '1'
    }

    It 'renders the restore confirmation as a table of current against backup' {
        $current = Join-Path $TestDrive 'blocks-current.json'
        $backup = Join-Path $TestDrive 'blocks-backup.json'
        Set-Content -LiteralPath $current -Value '{ "AirServerAddress": "10.0.0.1" }' -Encoding utf8
        Set-Content -LiteralPath $backup -Value '{ "AirServerAddress": "10.0.0.9" }' -Encoding utf8

        $blocks = @(Get-ConfigRestoreBlocks -CurrentPath $current -BackupPath $backup -BackupName 'config.bak.json')

        $blocks[0].text | Should -Match 'config.bak.json'
        $table = $blocks | Where-Object { $_.type -eq 'table' }
        $table | Should -Not -BeNullOrEmpty
        @($table.cells[1] | ForEach-Object text) | Should -Contain '10.0.0.9'
    }

    It 'says a backup would change nothing rather than drawing an empty table' {
        $same = Join-Path $TestDrive 'same-current.json'
        $copy = Join-Path $TestDrive 'same-backup.json'
        Set-Content -LiteralPath $same -Value '{ "AirServerAddress": "10.0.0.1" }' -Encoding utf8
        Copy-Item -LiteralPath $same -Destination $copy

        $blocks = @(Get-ConfigRestoreBlocks -CurrentPath $same -BackupPath $copy -BackupName 'config.bak.json')

        @($blocks | Where-Object { $_.type -eq 'table' }) | Should -BeNullOrEmpty
        ($blocks | Where-Object { $_.type -eq 'paragraph' }).text | Should -Match 'لا اختلافات'
    }
}

Describe 'Configuration migration' {
    It 'adds new defaults while preserving unknown settings from an older release' {
        $settings = Get-JsonProp $config 'Settings'
        $settings | Add-Member -NotePropertyName 'LegacyCustomSetting' -NotePropertyValue 'keep-me' -Force
        $settings.PSObject.Properties.Remove('ConfigBackupKeepFiles')
        Mock Save-Config { }

        Initialize-Settings

        (Get-JsonProp $settings 'ConfigBackupKeepFiles') | Should -Be 10
        (Get-JsonProp $settings 'LegacyCustomSetting') | Should -Be 'keep-me'
        Should -Invoke Save-Config -Times 1 -Exactly
    }
}

Describe 'Telegram preset management storage' {
    BeforeEach {
        $script:OriginalTemplateRegistryPathForTest = $config.TemplateRegistryPath
        $script:PresetRegistryPathForTest = Join-Path $TestDrive 'templates.json'
        @{
            urgent = @{
                path = 'D:\CG\urgent.cintitle'; layer = 4
                fields = @('Headline.Text')
                presets = @(@{ name = 'قديم'; values = @('قيمة قديمة') })
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PresetRegistryPathForTest -Encoding utf8
        $config.TemplateRegistryPath = $script:PresetRegistryPathForTest
        $script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }
        Mock Get-SettingInt { 10 }
    }

    AfterEach {
        $config.TemplateRegistryPath = $script:OriginalTemplateRegistryPathForTest
        $script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }
    }

    It 'creates a preset atomically and makes a timestamped backup' {
        $result = Save-TemplatePresetChange -TemplateKey 'urgent' -Action create -Name 'جديد' -Values @('قيمة جديدة')
        $saved = Get-Content -LiteralPath $script:PresetRegistryPathForTest -Raw | ConvertFrom-Json

        $result.Success | Should -BeTrue
        @($saved.urgent.presets.name) | Should -Contain 'جديد'
        @(Get-ChildItem -LiteralPath "$($script:PresetRegistryPathForTest).backups" -Filter '*.json').Count | Should -Be 1
    }

    It 'renames edits and deletes an existing preset by index' {
        Save-TemplatePresetChange -TemplateKey 'urgent' -PresetIndex 0 -Action rename -Name 'مُعاد' | Out-Null
        Save-TemplatePresetChange -TemplateKey 'urgent' -PresetIndex 0 -Action edit -Values @('معدلة') | Out-Null
        $edited = Get-Content -LiteralPath $script:PresetRegistryPathForTest -Raw | ConvertFrom-Json
        $edited.urgent.presets[0].name | Should -Be 'مُعاد'
        $edited.urgent.presets[0].values[0] | Should -Be 'معدلة'

        $result = Save-TemplatePresetChange -TemplateKey 'urgent' -PresetIndex 0 -Action delete
        $saved = Get-Content -LiteralPath $script:PresetRegistryPathForTest -Raw | ConvertFrom-Json

        $result.Success | Should -BeTrue
        @($saved.urgent.presets).Count | Should -Be 0
    }
}

Describe 'Telegram preset management flow' {
    BeforeEach {
        Clear-PendingState -ChatId 91
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'; Layer = 4
                Fields = @('Headline.Text'); FieldLabels = @('العنوان')
                Presets = @([pscustomobject]@{ Name = 'قديم'; Values = @('قيمة') })
            }
        }
        Mock Send-TelegramMessage { }
        Mock Save-TemplatePresetChange { [pscustomobject]@{ Success = $true; Error = ''; BackupPath = 'backup.json' } }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
    }

    AfterEach { Clear-PendingState -ChatId 91 }

    It 'reviews a new preset before saving it and commits only after confirmation' {
        Start-PresetAdminCreate -TemplateIndex 0 -ChatId 91 -UserId 101
        Complete-PresetAdminText -ChatId 91 -Value 'عاجل جاهز'
        Complete-PresetAdminText -ChatId 91 -Value 'النص النهائي'

        (Get-PendingState -ChatId 91).Mode | Should -Be 'preset_admin_review'
        Should -Invoke Save-TemplatePresetChange -Times 0 -Exactly

        Confirm-PresetAdminChange -ChatId 91 -UserId 101

        Get-PendingState -ChatId 91 | Should -BeNullOrEmpty
        Should -Invoke Save-TemplatePresetChange -Times 1 -Exactly -ParameterFilter {
            $TemplateKey -eq 'urgent' -and $Action -eq 'create' -and $Name -eq 'عاجل جاهز' -and $Values[0] -eq 'النص النهائي'
        }
    }
}

Describe 'DPAPI activation through administrator settings' {
    BeforeEach {
        $script:OriginalConfigForDpapi = $config
        $script:OriginalReferencesForDpapi = $script:SecretReferences
        $script:OriginalStoreForDpapi = $script:SecretStorePath
        $script:OriginalConfigPathForDpapi = $script:ConfigPath
        $config = (Get-Content -LiteralPath (Join-Path $script:Root 'config.example.json') -Raw | ConvertFrom-Json)
        $script:ConfigPath = Join-Path $TestDrive 'config.json'
        $script:SecretStorePath = Join-Path $TestDrive 'secrets.dpapi.json'
        $script:SecretReferences = @{}
        Copy-Item -LiteralPath (Join-Path $script:Root 'config.example.json') -Destination $script:ConfigPath
        Mock Write-BridgeLog { }
    }

    AfterEach {
        $script:config = $script:OriginalConfigForDpapi
        $script:SecretReferences = $script:OriginalReferencesForDpapi
        $script:SecretStorePath = $script:OriginalStoreForDpapi
        $script:ConfigPath = $script:OriginalConfigPathForDpapi
    }

    It 'leaves plaintext behavior unchanged while the option is disabled' {
        Save-Config -Path $script:ConfigPath
        $saved = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        $saved.Settings.EnableDpapiSecrets | Should -BeFalse
        $saved.BotToken | Should -Be $config.BotToken
        Test-Path -LiteralPath $script:SecretStorePath | Should -BeFalse
    }

    It 'moves secrets to DPAPI when enabled and restores plaintext persistence when disabled' {
        $config.Settings.EnableDpapiSecrets = $true
        Save-Config -Path $script:ConfigPath

        $encrypted = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        $encrypted.BotToken | Should -Be 'dpapi:BotToken'
        $encrypted.LiveStream.SourceUrl | Should -Match '^dpapi:'
        Test-Path -LiteralPath $script:SecretStorePath | Should -BeTrue
        (Get-Content -LiteralPath $script:SecretStorePath -Raw) | Should -Not -Match [regex]::Escape([string]$config.BotToken)

        $config.Settings.EnableDpapiSecrets = $false
        Save-Config -Path $script:ConfigPath
        $plain = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
        $plain.BotToken | Should -Be $config.BotToken
        $plain.LiveStream.SourceUrl | Should -Be $config.LiveStream.SourceUrl
    }
}

Describe 'Admin configuration backup menu' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-CallbackAdmin { $true }
        Mock Get-ConfigBackupsKeyboard { @{ inline_keyboard = @() } }
        Mock Send-TelegramMessage { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
    }

    It 'opens the saved configuration versions from the admin menu' {
        $callback = [pscustomobject]@{
            id = 'backups-menu-1'
            from = [pscustomobject]@{ id = 100 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100 } }
            data = 'menu:backups'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Get-ConfigBackupsKeyboard -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'نسخ الإعدادات' }
    }

    It 'requires confirmation after an admin selects a backup version' {
        Mock Test-Path { $true }
        Mock Get-ChildItem {
            [pscustomobject]@{ FullName = 'C:\safe\config-backup.json'; Name = 'config-backup.json'; LastWriteTimeUtc = Get-Date }
        }
        $callback = [pscustomobject]@{
            id = 'backup-select-1'
            from = [pscustomobject]@{ id = 100 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100 } }
            data = 'cfg:restore:0'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        $state = Get-PendingState -ChatId 100
        $state.Mode | Should -Be 'config_restore'
        $state.BackupPath | Should -Be 'C:\safe\config-backup.json'
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تأكيد استعادة' }
    }

    It 'restores the selected backup only after the admin confirms' {
        Set-PendingState -ChatId 100 -State @{
            Mode = 'config_restore'; UserId = 100; BackupPath = 'C:\safe\config-backup.json'
        }
        Mock Restore-ConfigBackup { [pscustomobject]@{ Success = $true; Error = '' } }
        $callback = [pscustomobject]@{
            id = 'backup-confirm-1'
            from = [pscustomobject]@{ id = 100 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100 } }
            data = 'cfg:restoreconfirm'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Restore-ConfigBackup -Times 1 -Exactly -ParameterFilter { $BackupPath -eq 'C:\safe\config-backup.json' }
        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تمت استعادة' }
    }
}

Describe 'Settings export and import' {
    BeforeEach {
        $script:PendingSettingsImport = $null
        Mock Test-Admin { $true }
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Get-AdminToolsKeyboard { @{ inline_keyboard = @() } }
        Mock Get-ConfigSaveWarning { '' }
    }

    It 'never puts the bot token or the whitelist into the exported document' {
        # config.json holds both; a document is far easier to forward than the
        # file on disk, so the export must carry settings and nothing else.
        $script:ExportedPath = ''
        Mock Send-TelegramDocument { $script:ExportedPath = $FilePath; $true }
        Mock Remove-Item {}

        Invoke-SettingsExport -ChatId 100 -UserId 100 | Should -BeTrue

        $body = Get-Content -LiteralPath $script:ExportedPath -Raw
        $body | Should -Not -Match 'BotToken'
        $body | Should -Not -Match 'AllowedChatIds'
        $body | Should -Not -Match 'AdminChatIds'
        ($body | ConvertFrom-Json).Kind | Should -Be 'CinegyTelegramBridge.Settings'
    }

    It 'refuses a document that is not one of ours' {
        $path = Join-Path $TestDrive 'foreign.json'
        Set-Content -LiteralPath $path -Value '{"Kind":"something.else","Settings":{}}' -Encoding utf8
        (Test-SettingsImport -Path $path).Success | Should -BeFalse
    }

    It 'refuses invalid JSON rather than importing nothing silently' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Value '{not json' -Encoding utf8
        (Test-SettingsImport -Path $path).Success | Should -BeFalse
    }

    It 'refuses an unknown key instead of dropping it' {
        # Applying half an import leaves a machine in a state nobody can
        # reproduce from the file they thought they applied.
        $path = Join-Path $TestDrive 'unknown.json'
        Set-Content -LiteralPath $path -Value '{"Kind":"CinegyTelegramBridge.Settings","Settings":{"NotARealSetting":1}}' -Encoding utf8
        $result = Test-SettingsImport -Path $path
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'NotARealSetting'
    }

    It 'lists only the keys that actually differ' {
        $path = Join-Path $TestDrive 'diff.json'
        $current = Get-Setting 'AirCommandTimeoutSeconds'
        Set-Content -LiteralPath $path -Encoding utf8 -Value (@{
                Kind = 'CinegyTelegramBridge.Settings'
                Settings = @{ AirCommandTimeoutSeconds = $current; MaxFieldLength = 999 }
            } | ConvertTo-Json -Depth 5)

        $result = Test-SettingsImport -Path $path
        $result.Success | Should -BeTrue
        @($result.Changes).Count | Should -Be 1
        $result.Changes[0].Name | Should -Be 'MaxFieldLength'
    }

    It 'refuses a string where a boolean setting is required' {
        $path = Join-Path $TestDrive 'wrong-type.json'
        Set-Content -LiteralPath $path -Encoding utf8 -Value '{"Kind":"CinegyTelegramBridge.Settings","Settings":{"EnableLiveRelay":"false"}}'

        $result = Test-SettingsImport -Path $path
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'EnableLiveRelay'
    }

    It 'accepts a large settings import up to the 10 MB limit' {
        $script:CapturedSettingsImportMaximum = 0
        Mock Receive-TelegramDocument {
            $script:CapturedSettingsImportMaximum = $MaximumBytes
            New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null
            @{ Kind = 'CinegyTelegramBridge.Settings'; Settings = @{ MaxFieldLength = 999 } } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $DestinationPath -Encoding utf8
            return $DestinationPath
        }

        Receive-SettingsImport -Document ([pscustomobject]@{ file_id='large-settings-id' }) -ChatId 100 -UserId 100

        $script:CapturedSettingsImportMaximum | Should -Be 10485760
        $script:PendingSettingsImport | Should -Not -BeNullOrEmpty
    }

    It 'applies nothing until the administrator confirms' {
        Mock Set-Setting {}
        $script:PendingSettingsImport = @{ Path = (Join-Path $TestDrive 'p.json'); UserId = 100
            Changes = @([pscustomobject]@{ Name = 'MaxFieldLength'; From = 400; To = 999 }) }
        Mock Remove-Item {}

        Confirm-SettingsImport -ChatId 100 -UserId 100 -Cancel | Should -BeFalse
        Should -Invoke Set-Setting -Times 0 -Exactly
    }

    It 'applies every listed change through one atomic configuration save once confirmed' {
        $oldMaximum = $config.Settings.MaxFieldLength
        $oldDelay = $config.Settings.PostShowDelayMs
        Mock Save-Config { $script:LastConfigSaveFailed = $false }
        Mock Remove-Item {}
        $script:PendingSettingsImport = @{ Path = (Join-Path $TestDrive 'p.json'); UserId = 100
            Changes = @(
                [pscustomobject]@{ Name = 'MaxFieldLength'; From = 400; To = 999 }
                [pscustomobject]@{ Name = 'PostShowDelayMs'; From = 400; To = 250 }) }

        Confirm-SettingsImport -ChatId 100 -UserId 100 | Should -BeTrue
        $config.Settings.MaxFieldLength | Should -Be 999
        $config.Settings.PostShowDelayMs | Should -Be 250
        Should -Invoke Save-Config -Times 1 -Exactly
        $config.Settings.MaxFieldLength = $oldMaximum
        $config.Settings.PostShowDelayMs = $oldDelay
    }

    It 'rolls back the in-memory settings when the atomic save fails' {
        $oldMaximum = $config.Settings.MaxFieldLength
        Mock Save-Config { $script:LastConfigSaveFailed = $true }
        Mock Remove-Item {}
        $script:PendingSettingsImport = @{ Path = (Join-Path $TestDrive 'failed.json'); UserId = 100
            Changes = @([pscustomobject]@{ Name = 'MaxFieldLength'; From = $oldMaximum; To = 999 }) }

        Confirm-SettingsImport -ChatId 100 -UserId 100 | Should -BeFalse
        $config.Settings.MaxFieldLength | Should -Be $oldMaximum
        Should -Invoke Save-Config -Times 1 -Exactly
    }

    It 'will not let a different administrator confirm someone else review' {
        Mock Set-Setting {}
        $script:PendingSettingsImport = @{ Path = 'p.json'; UserId = 100; Changes = @() }

        Confirm-SettingsImport -ChatId 200 -UserId 200 | Should -BeFalse
        Should -Invoke Set-Setting -Times 0 -Exactly
    }
}

Describe 'Version 6 settings navigation schema' {
    It 'leads the release notes with the version actually running' {
        $script:BridgeVersion | Should -Be '8.13.0'
        @(Get-WhatsNewSections)[0].Version | Should -Be '8.13.0'
    }

    It 'presents the operational setting categories in a stable order' {
        $definitions = @(Get-SettingCategoryDefinitions)

        @($definitions.Key) | Should -Be @(
            'security', 'onair', 'templates', 'news',
            'schedule', 'monitoring', 'storage', 'notifications', 'advanced'
        )
    }

    It 'gives protected authentication settings an Arabic operational identity' {
        $metadata = Get-SettingNavigationMetadata -Name 'RequireUserLevelAuth'

        $metadata.Category | Should -Be 'security'
        $metadata.Label | Should -Be 'التحقق من هوية المستخدم'
    }

    It 'keeps every default setting reachable from exactly one category' {
        $allSettings = foreach ($category in @(Get-SettingCategoryDefinitions)) {
            @(Get-SettingsInCategory -Category $category.Key)
        }

        @($allSettings).Count | Should -Be $script:DefaultSettings.Count
        @($allSettings | Sort-Object -Unique).Count | Should -Be $script:DefaultSettings.Count
        foreach ($name in $script:DefaultSettings.Keys) {
            @($allSettings) | Should -Contain $name
        }
    }

    It 'opens settings on category choices instead of every technical setting' {
        $keyboard = Get-SettingsKeyboard
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })

        $callbacks | Should -Contain 'cfgcat:security:0'
        $callbacks | Should -Contain 'cfgcat:monitoring:0'
        $callbacks | Should -Not -Contain 'cfg:t:RequireUserLevelAuth'
    }

    It 'limits a category page to eight setting actions and provides paging' {
        $keyboard = Get-SettingsCategoryKeyboard -Category 'monitoring' -Page 0 -PageSize 8
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $settingCallbacks = @($callbacks | Where-Object { $_ -match '^cfg:(t|v|s):' })

        $settingCallbacks.Count | Should -Be 8
        $callbacks | Should -Contain 'cfgcat:monitoring:1'
        $callbacks | Should -Contain 'menu:settings'
    }

    It 'uses the existing protected toggle callback behind an Arabic label' {
        $keyboard = Get-SettingsCategoryKeyboard -Category 'security' -Page 0
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        $button = @($buttons | Where-Object { $_['callback_data'] -eq 'cfg:t:RequireUserLevelAuth' })[0]

        $button.text | Should -Match 'التحقق من هوية المستخدم'
        $button.text | Should -Match '🔒'
    }

    It 'gives every setting in every category a real Arabic label' {
        $unlabelled = @($script:SettingSchema | Where-Object {
                $_.Label -eq $_.Name -or $_.Label -notmatch '[\u0600-\u06FF]'
            })

        @($unlabelled | ForEach-Object Name) | Should -Be @()
    }

    It 'uses a full row and a readable current value for every setting inside a category' {
        $original = Get-Setting 'RequireUserLevelAuth'
        try {
            $config.Settings | Add-Member -NotePropertyName RequireUserLevelAuth -NotePropertyValue $false -Force
            $keyboard = Get-SettingsCategoryKeyboard -Category 'security' -Page 0
            $row = @($keyboard.inline_keyboard | Where-Object {
                    @($_ | Where-Object callback_data -eq 'cfg:t:RequireUserLevelAuth').Count -gt 0
                })[0]
            $button = @($row)[0]

            @($row).Count | Should -Be 1
            $button.text | Should -Be '❌ 🔒 التحقق من هوية المستخدم · معطّل'
        }
        finally {
            $config.Settings | Add-Member -NotePropertyName RequireUserLevelAuth -NotePropertyValue $original -Force
        }
    }

    It 'shows formatted units and summaries for special settings inside categories' {
        $originalTimeout = Get-Setting 'CinegyMonitorTimeoutSeconds'
        $originalLayers = Get-Setting 'HideAllLayers'
        try {
            $config.Settings | Add-Member -NotePropertyName CinegyMonitorTimeoutSeconds -NotePropertyValue 3 -Force
            $config.Settings | Add-Member -NotePropertyName HideAllLayers -NotePropertyValue '2,4,7' -Force

            $monitoring = Get-SettingsCategoryKeyboard -Category 'monitoring' -Page 0 -PageSize 20
            $timeout = @($monitoring.inline_keyboard | ForEach-Object { @($_) } |
                    Where-Object callback_data -eq 'cfg:v:CinegyMonitorTimeoutSeconds')[0]
            $onAir = Get-SettingsCategoryKeyboard -Category 'onair' -Page 0 -PageSize 20
            $hideAll = @($onAir.inline_keyboard | ForEach-Object { @($_) } |
                    Where-Object callback_data -eq 'menu:hideallsettings')[0]

            $timeout.text | Should -Match '· 3 ثانية'
            $hideAll.text | Should -Match '· طبقات: 2,4,7'
        }
        finally {
            $config.Settings | Add-Member -NotePropertyName CinegyMonitorTimeoutSeconds -NotePropertyValue $originalTimeout -Force
            $config.Settings | Add-Member -NotePropertyName HideAllLayers -NotePropertyValue $originalLayers -Force
        }
    }

    It 'caps a long full-row setting value instead of creating an unbounded button' {
        $original = Get-Setting 'TemplateBasePath'
        try {
            $config.Settings | Add-Member -NotePropertyName TemplateBasePath -NotePropertyValue ('D:\' + ('very-long-folder\' * 10)) -Force
            # Every page, not a fixed one: which page a setting lands on is an
            # accident of how many others share its category, and pinning it
            # here made adding any setting look like a capping regression.
            $button = @(0..4 | ForEach-Object {
                    @((Get-SettingsCategoryKeyboard -Category 'templates' -Page $_ -PageSize 8).inline_keyboard) |
                        ForEach-Object { @($_) }
                } | Where-Object { $_['callback_data'] -eq 'cfg:s:TemplateBasePath' })[0]
            $button | Should -Not -BeNullOrEmpty

            (Get-TextElementCount -Text $button.text) | Should -BeLessOrEqual 64
            $button.text | Should -Match '…$'
        }
        finally { $config.Settings | Add-Member -NotePropertyName TemplateBasePath -NotePropertyValue $original -Force }
    }

    It 'shows a named category page with its requested page number' {
        Mock Send-TelegramMessage {}
        Mock Get-SettingsCategoryKeyboard { @{ inline_keyboard = @() } }

        Show-SettingsCategoryScreen -Category 'monitoring' -Page 2 -ChatId 100 -UserId 101

        Should -Invoke Get-SettingsCategoryKeyboard -Times 1 -Exactly -ParameterFilter {
            $Category -eq 'monitoring' -and $Page -eq 2
        }
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 100 -and $Text -match 'المراقبة والتنبيهات'
        }
    }

    Context 'category callbacks' {
        BeforeEach {
            Mock Confirm-TelegramCallback {}
            Mock Test-TelegramPrivateChat { $true }
            Mock Test-Authorized { $true }
            Mock Update-UserLastActivity {}
            Mock Show-SettingsCategoryScreen {}
        }

        It 'routes a valid category page callback for an administrator' {
            Mock Test-CallbackAdmin { $true }
            $callback = [pscustomobject]@{
                id = 'settings-category-admin'
                from = [pscustomobject]@{ id = 101 }
                message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100; type = 'private' } }
                data = 'cfgcat:monitoring:2'
            }

            Invoke-CallbackQuery -CallbackQuery $callback

            Should -Invoke Show-SettingsCategoryScreen -Times 1 -Exactly -ParameterFilter {
                $Category -eq 'monitoring' -and $Page -eq 2 -and $ChatId -eq 100 -and $UserId -eq 101
            }
        }

        It 'does not open a category page for a non-administrator' {
            Mock Test-CallbackAdmin { $false }
            $callback = [pscustomobject]@{
                id = 'settings-category-operator'
                from = [pscustomobject]@{ id = 101 }
                message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100; type = 'private' } }
                data = 'cfgcat:security:0'
            }

            Invoke-CallbackQuery -CallbackQuery $callback

            Should -Invoke Show-SettingsCategoryScreen -Times 0 -Exactly
        }
    }
}

Describe 'Settings are explained, not just listed' {
    It 'declares a range only for settings that actually exist' {
        # Four constraints were written against names no setting ever had -
        # MaxNewsItems for NewsMaxItems, AuditMaxLines for AuditMaxSizeMB, and
        # two more. Set-Setting looks the bounds up by name, finds nothing, and
        # lets the number through, so the screen printed a range under a field
        # that would have accepted two billion. A misspelt guard is not a
        # weaker guard; it is no guard, and it looks exactly like one.
        $orphans = @(@($script:SettingConstraints.Keys) | Where-Object { -not $script:DefaultSettings.Contains($_) })
        $orphans | Should -BeNullOrEmpty
    }

    It 'gives every setting a description an administrator can act on' {
        $undocumented = @(@($script:DefaultSettings.Keys) | Where-Object {
                $metadata = Get-JsonProp $script:SettingDisplayMetadata $_
                -not ($metadata -and (Get-JsonProp $metadata 'Description'))
            })
        # A setting nobody can explain is a setting nobody should change.
        $undocumented | Should -BeNullOrEmpty
    }

    It 'gives every setting a short name of its own for its button' {
        # Without one the schema falls back to the description, so the button
        # became a sentence and the screen a wall of them. The name goes on
        # the button; the description goes on the line above it.
        $unnamed = @(@($script:DefaultSettings.Keys) | Where-Object { -not $script:SettingNavigationLabels.ContainsKey($_) })
        $unnamed | Should -BeNullOrEmpty
    }

    It 'keeps every setting name short enough to read beside its value' {
        $tooLong = @(@($script:DefaultSettings.Keys) | Where-Object {
                ([string](Get-SettingNavigationMetadata -Name $_).Label).Length -gt 32
            })
        $tooLong | Should -BeNullOrEmpty
    }

    It 'gives every category the sentence its screen opens with' {
        foreach ($category in @(Get-SettingCategoryDefinitions)) {
            [string]$category.Summary | Should -Not -BeNullOrEmpty
        }
    }

    It 'describes exactly the settings whose buttons are on that page' {
        Mock Send-TelegramMessage {}
        Show-SettingsCategoryScreen -Category 'news' -Page 0 -ChatId 100 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ParseMode -eq 'HTML' -and
            $Text -match 'شريط الأخبار' -and
            # One page, one slice: the text lines and the buttons are the same
            # eight settings.
            (@($Text -split "`n" | Where-Object { $_ -like '•*' }).Count -eq
                @(Get-SettingsCategoryPageNames -Category 'news' -Page 0).Count)
        }
    }
}

Describe 'The technical changelog' {
    It 'offers the file on the release notes screen' {
        $callbacks = @((Get-WhatsNewKeyboard -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $callbacks | Should -Contain 'menu:changelog'
    }

    It 'ships beside the bridge, so the button has something to send' {
        Test-Path -LiteralPath (Join-Path $script:Root 'CHANGELOG.md') | Should -BeTrue
    }
}

Describe 'Settings list and search screens' {
    It 'says how many matched and explains each one on the page' {
        Mock Send-TelegramMessage {}
        Show-SettingsListScreen -Mode modified -ChatId 100 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ParseMode -eq 'HTML' -and $Text -match 'الإعدادات المعدّلة' -and $Text -match 'إعدادًا'
        }
    }

    It 'says a search found nothing instead of showing a bare title' {
        # An empty result is also the shape that unwraps to $null, so this
        # covers the crash as well as the wording.
        Mock Send-TelegramMessage {}
        Show-SettingsListScreen -Mode search -Query 'zzzznotasetting' -ChatId 100 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'لا إعداد يطابق' }
    }

    It 'describes exactly the settings on the page the keyboard draws' {
        Mock Send-TelegramMessage {}
        Show-SettingsListScreen -Mode advanced -Page 0 -ChatId 100 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            @($Text -split "`n" | Where-Object { $_ -like '•*' }).Count -eq 8
        }
    }
}

Describe 'Confirming a settings change' {
    It 'names the setting the way the screens do, and says what it was' {
        Mock Send-TelegramMessage {}
        Mock Save-Config {}
        Invoke-SettingToggle -Name 'EnableSnapshot' -ChatId 100 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ParseMode -eq 'HTML' -and
            $Text -match 'التقاط لقطات البث' -and $Text -match 'مفعّل' -and $Text -match 'معطّل' -and
            # The JSON key belongs in the log, not on a screen whose buttons,
            # lists and search results are all Arabic.
            $Text -notmatch 'EnableSnapshot'
        }
    }

    It 'says what a single reset would change it from and to' {
        Mock Send-TelegramMessage {}
        Mock Save-Config {}
        Set-Setting -Name 'MaxFieldLength' -Value 500
        Reset-SingleSettingToDefault -Name 'MaxFieldLength' -ChatId 100 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'طول نص الحقل' -and $Text -match '500' -and
            $Text -match [regex]::Escape([string]$script:DefaultSettings['MaxFieldLength'])
        }
    }
}

Describe 'Restoring every default asks first' {
    It 'writes nothing on the first press and names what it would undo' {
        Mock Send-TelegramMessage {}
        Mock Save-Config {}
        Set-Setting -Name 'MaxFieldLength' -Value 500

        Reset-SettingsToDefault -ChatId 100 -UserId 101

        # The one button that rewrites every setting at once used to do it on
        # a single tap.
        (Get-Setting 'MaxFieldLength') | Should -Be 500
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'طول نص الحقل' -and
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) -contains 'cfg:resetconfirm'
        }
    }

    It 'restores them once confirmed' {
        Mock Send-TelegramMessage {}
        Mock Save-Config {}
        Set-Setting -Name 'MaxFieldLength' -Value 500

        Reset-SettingsToDefault -ChatId 100 -UserId 101 -Confirmed

        (Get-Setting 'MaxFieldLength') | Should -Be $script:DefaultSettings['MaxFieldLength']
    }

    It 'colours the affirming half and leaves the cancel plain' {
        $buttons = @((Get-SettingsResetConfirmKeyboard).inline_keyboard | ForEach-Object { @($_) })
        $yes = @($buttons | Where-Object { $_['callback_data'] -eq 'cfg:resetconfirm' })[0]
        $no = @($buttons | Where-Object { $_['callback_data'] -eq 'menu:settings' })[0]

        $yes['style'] | Should -Be 'danger'
        $no.ContainsKey('style') | Should -BeFalse
    }
}

Describe 'The configuration backups list' {
    It 'says there are none rather than showing a bare title' {
        $missing = Join-Path $TestDrive 'no-such-config.json'

        Get-ConfigBackupsText -Path $missing | Should -Match 'لا نسخ محفوظة'
        # The listing used to be an if-expression per caller: no files came
        # back as $null and the .Count each did on it threw - on this screen.
        @(Get-ConfigBackupFiles -Path $missing).Count | Should -Be 0
        { Get-ConfigBackupsKeyboard -Path $missing } | Should -Not -Throw
    }

    It 'numbers each saved copy with its age, matching the buttons' {
        $configPath = Join-Path $TestDrive 'aged-config.json'
        $backupDirectory = "$configPath.backups"
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $backupDirectory 'config-one.json')

        $text = Get-ConfigBackupsText -Path $configPath

        $text | Should -Match '1\.'
        $text | Should -Match 'نسخة'
        @((Get-ConfigBackupsKeyboard -Path $configPath).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { [string]$_['text'] } |
                Where-Object { $_ -like '1.*' }).Count | Should -Be 1
    }
}

Describe 'The on-air notice is set by tapping, not by typing' {
    BeforeEach {
        Mock Get-TemplateStore { @{ Order = @('Urgent', 'Banner', 'Lower3') } }
        Mock Set-Setting { $script:Rules = [string]$Value }
        Mock Get-Setting { $script:Rules } -ParameterFilter { $Name -eq 'TemplateNotifyRules' }
        $script:Rules = 'Urgent=all, Banner=admins'
    }

    It 'shows every template with what it will do' {
        # Typing "Urgent=all, Banner=admins" is a syntax to remember, a name
        # to spell exactly, and a scope word - three ways to be silently wrong
        # about a setting whose whole point is that somebody hears.
        $labels = @(@(Get-TemplateNotifyKeyboard).inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text })

        @($labels | Where-Object { $_ -match '^Urgent' })[0] | Should -Match 'الجميع'
        @($labels | Where-Object { $_ -match '^Banner' })[0] | Should -Match 'المشرفون'
        # Never named, so nobody hears about it.
        @($labels | Where-Object { $_ -match '^Lower3' })[0] | Should -Match 'لا أحد'
    }

    It 'cycles one template without touching the others' {
        [void](Set-TemplateNotifyRule -Key 'Lower3' -Scope 'admins')

        $map = Get-TemplateNotifyMap
        $map['Lower3'] | Should -Be 'admins'
        $map['Urgent'] | Should -Be 'all'
        $map['Banner'] | Should -Be 'admins'
    }

    It 'drops a rule that means silence rather than storing it' {
        [void](Set-TemplateNotifyRule -Key 'Banner' -Scope 'none')
        $script:Rules | Should -Not -Match 'Banner'
        $script:Rules | Should -Match 'Urgent=all'
    }

    It 'keeps a rule for a template the registry no longer has' {
        # Renamed this morning, restored this afternoon: the newsroom's
        # decision should survive the gap.
        $script:Rules = 'Urgent=all, Retired=admins'
        [void](Set-TemplateNotifyRule -Key 'Urgent' -Scope 'admins')
        $script:Rules | Should -Match 'Retired=admins'
    }

    It 'opens the editor instead of asking for a string' {
        Mock Show-TemplateNotifyEditor { $script:Opened = $true }
        Mock Send-TelegramMessage { }
        $script:Opened = $false

        Show-SettingChoices -Name 'TemplateNotifyRules' -ChatId 101 -UserId 101

        $script:Opened | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}

Describe 'A number is set by tapping, and cannot leave its range' {
    It 'moves by a step that suits the size of the number' {
        # A poll interval of 1 second wants to move by one; a retention of
        # 5000 lines does not want fifty taps to reach 5500.
        Get-SettingStep -Value 3 | Should -Be 1
        Get-SettingStep -Value 60 | Should -Be 5
        Get-SettingStep -Value 500 | Should -Be 10
        Get-SettingStep -Value 5000 | Should -Be 100
        Get-SettingStep -Value 200000 | Should -Be 1000
    }

    It 'clamps at the ceiling instead of refusing the tap' {
        # Pressing plus at the top means "as high as it goes", and an error in
        # reply to a button that should not have been offered is the screen's
        # fault rather than the operator's.
        Mock Set-Setting { $script:Applied = $Value }
        Mock Get-Setting { 300 } -ParameterFilter { $Name -eq 'CinegyStateCheckSeconds' }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }

        Set-SettingNumber -Name 'CinegyStateCheckSeconds' -Operation '+10' -UserId 1 | Should -Be 300
    }

    It 'refuses an out-of-range write wherever it comes from' {
        # The guard is in Set-Setting, not on the screen: an import and a
        # restore write settings too.
        { Set-Setting -Name 'CinegyStateCheckSeconds' -Value 0 } | Should -Throw
        { Set-Setting -Name 'QuietHoursStart' -Value 25 } | Should -Throw
        { Set-Setting -Name 'CinegyStateCheckSeconds' -Value 5 } | Should -Not -Throw
    }

    It 'shows a whole day of hours rather than stepping to them' {
        $labels = @(@(Get-SettingStepperKeyboard -Name 'HeartbeatHour').inline_keyboard |
            ForEach-Object { $_ } | ForEach-Object { $_.text })

        @($labels | Where-Object { $_ -match '^•? ?0[0-9]:00$' }).Count | Should -BeGreaterThan 5
        $labels | Should -Contain '23:00'
        # And a weekday by its name.
        @(@(Get-SettingStepperKeyboard -Name 'UsageDigestDayOfWeek').inline_keyboard |
            ForEach-Object { $_ } | ForEach-Object { $_.text }) | Should -Contain 'الخميس'
    }

    It 'picks a maintenance window from a clock, and can empty it' {
        Mock Send-TelegramMessage { $script:Markup = $ReplyMarkup }
        Show-SettingTimePicker -Name 'MaintenanceWindowStart' -ChatId 101 -UserId 101
        $data = @($script:Markup.inline_keyboard) | ForEach-Object { $_ } | ForEach-Object { $_.callback_data }

        $data | Should -Contain 'tm:MaintenanceWindowStart:23'
        # No window at all is how maintenance is left off, and it needs a button.
        $data | Should -Contain 'tm:MaintenanceWindowStart:clear'

        Mock Set-Setting { $script:Written = $Value }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Set-SettingTime -Name 'MaintenanceWindowStart' -Hour 23 -Minute 30 -UserId 1 | Should -Be '23:30'
        Set-SettingTime -Name 'MaintenanceWindowStart' -UserId 1 | Should -Be ''
    }

    It 'gives the three typed lists the pickers that already existed' {
        # A misspelled key in a permission list reads as "not in the list", so
        # the permission quietly protects nothing.
        foreach ($name in 'DisabledTemplateKeys', 'SensitiveTemplateKeys') {
            $script:SettingPickers[$name] | Should -Be 'template'
        }
        $script:SettingPickers['ReservedLayers'] | Should -Be 'layer'
        $script:SettingPickers['AutoHidePresetSeconds'] | Should -Be 'seconds'
        # And the durations read as durations rather than as bare numbers.
        @(Get-SettingPickItems -Name 'AutoHidePresetSeconds')[0].Label | Should -Not -Be '5'
    }

    It 'offers the separator instead of asking for a character' {
        $script:SettingChoices['NewsItemSeparator'] | Should -Contain '|'
        $script:SettingChoices['NewsItemSeparator'] | Should -Contain '•'
    }
}
