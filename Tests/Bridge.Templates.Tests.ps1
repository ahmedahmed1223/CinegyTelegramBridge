#requires -Version 7
<#
    Bridge.Templates.Tests.ps1 - Template catalogue, registry, and the SHOW field flow.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Per-user editable favourites' {
    BeforeEach {
        $script:UserFavorites = @{}
        $script:userFavoritesFile = Join-Path $TestDrive 'favorites.json'
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{ urgent = 1; lowerthird = 2 }; Order = @('urgent', 'lowerthird'); Errors = @() }
        }
    }

    It 'keeps manually selected favourites isolated by user id' {
        Set-UserFavorite -UserId 101 -TemplateKey 'urgent' -Enabled $true | Should -BeTrue
        Set-UserFavorite -UserId 202 -TemplateKey 'lowerthird' -Enabled $true | Should -BeTrue
        @(Get-FavoriteTemplateKeys -UserId 101) | Should -Be @('urgent')
        @(Get-FavoriteTemplateKeys -UserId 202) | Should -Be @('lowerthird')
    }

    It 'removes a favourite without changing another users selection' {
        Set-UserFavorite -UserId 101 -TemplateKey 'urgent' -Enabled $true | Out-Null
        Set-UserFavorite -UserId 202 -TemplateKey 'urgent' -Enabled $true | Out-Null
        Set-UserFavorite -UserId 101 -TemplateKey 'urgent' -Enabled $false | Should -BeTrue
        @(Get-FavoriteTemplateKeys -UserId 101).Count | Should -Be 0
        @(Get-FavoriteTemplateKeys -UserId 202) | Should -Be @('urgent')
    }

    It 'rejects a template key that is not in the catalogue' {
        Set-UserFavorite -UserId 101 -TemplateKey 'missing' -Enabled $true | Should -BeFalse
        @(Get-FavoriteTemplateKeys -UserId 101).Count | Should -Be 0
    }

    It 'keeps a second favourite as its own entry instead of concatenating it onto the first' {
        # `$x = if (...) { @(...) } else { @() }` unrolls, so $x arrived as a
        # String and the `+=` that followed was string concatenation: two
        # favourites became the single key 'urgentlowerthird', which names no
        # template, so every reader filtered it out and the user's whole
        # selection disappeared without an error anywhere.
        Set-UserFavorite -UserId 101 -TemplateKey 'urgent' -Enabled $true | Out-Null
        Set-UserFavorite -UserId 101 -TemplateKey 'lowerthird' -Enabled $true | Out-Null

        @($script:UserFavorites['101']).Count | Should -Be 2
        @(Get-FavoriteTemplateKeys -UserId 101) | Should -Be @('urgent', 'lowerthird')
    }

    It 'survives a round trip through favorites.json with more than one favourite' {
        Set-UserFavorite -UserId 101 -TemplateKey 'urgent' -Enabled $true | Out-Null
        Set-UserFavorite -UserId 101 -TemplateKey 'lowerthird' -Enabled $true | Should -BeTrue

        $script:UserFavorites = @{}
        Import-UserFavorites

        @(Get-FavoriteTemplateKeys -UserId 101) | Should -Be @('urgent', 'lowerthird')
    }

    It 'ignores a corrupted concatenated key left behind by the old writer' {
        # Existing favorites.json files carry the damage; they must degrade to
        # "nothing selected", never to a phantom favourite.
        $script:UserFavorites['101'] = @('urgentlowerthird')

        @(Get-UserFavoriteSelection -UserId 101).Count | Should -Be 0
        Set-UserFavorite -UserId 101 -TemplateKey 'urgent' -Enabled $true | Should -BeTrue
        @(Get-FavoriteTemplateKeys -UserId 101) | Should -Be @('urgent')
    }

    Context 'when the selection is larger than the menu can show' {
        BeforeEach {
            Mock Get-TemplateStore {
                [pscustomobject]@{ Map = @{ a = 1; b = 2; c = 3 }; Order = @('a', 'b', 'c'); Errors = @() }
            }
            Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'FavoritesCount' }
        }

        It 'still reports every pick as selected, so a pick past the cap can be undone' {
            # Reading the capped menu list to decide the tick left the third
            # pick permanently stuck: it never showed selected, so each tap
            # re-added a key that was already stored.
            @('a', 'b', 'c') | ForEach-Object { Set-UserFavorite -UserId 101 -TemplateKey $_ -Enabled $true | Out-Null }

            @(Get-UserFavoriteSelection -UserId 101) | Should -Be @('a', 'b', 'c')
            @(Get-FavoriteTemplateKeys -UserId 101) | Should -Be @('a', 'b')
        }

        It 'removes a pick that sits past the cap' {
            @('a', 'b', 'c') | ForEach-Object { Set-UserFavorite -UserId 101 -TemplateKey $_ -Enabled $true | Out-Null }

            $selected = @(Get-UserFavoriteSelection -UserId 101) -contains 'c'
            $selected | Should -BeTrue
            Set-UserFavorite -UserId 101 -TemplateKey 'c' -Enabled (-not $selected) | Should -BeTrue

            @(Get-UserFavoriteSelection -UserId 101) | Should -Be @('a', 'b')
        }

        It 'ticks nothing before the user has picked, rather than ticking the usage guesses' {
            # The menu falls back to most-used templates, but the management
            # screen must not claim the user chose them.
            $script:UsageCounts = @{ a = 9; b = 4 }

            @(Get-UserFavoriteSelection -UserId 101).Count | Should -Be 0
            @(Get-FavoriteTemplateKeys -UserId 101) | Should -Be @('a', 'b')
        }

        It 'drops a key whose template has left the catalogue' {
            Set-UserFavorite -UserId 101 -TemplateKey 'a' -Enabled $true | Out-Null
            $script:UserFavorites['101'] = @('a', 'deleted')

            @(Get-UserFavoriteSelection -UserId 101) | Should -Be @('a')
        }

        It 'returns an empty array for an unknown user without touching the store' {
            @(Get-UserFavoriteSelection -UserId 999).Count | Should -Be 0
            @(Get-UserFavoriteSelection -UserId 0).Count | Should -Be 0
        }
    }
}

Describe 'Template search categories and last-used metadata' {
    BeforeEach {
        $script:TemplateLastUsed = @{}
        Mock Get-TemplateStore {
            @{
                Order = @('lowerthird', 'urgent', 'weather')
                Map = @{
                    lowerthird = @{ Key='lowerthird'; Layer=5; Category='أسماء'; Description='اسم الضيف'; Fields=@('Name'); Presets=@() }
                    urgent = @{ Key='urgent'; Layer=7; Category='أخبار'; Description='خبر عاجل'; Fields=@('Headline'); Presets=@() }
                    weather = @{ Key='weather'; Layer=8; Category='أخبار'; Description='درجات الحرارة'; Fields=@(); Presets=@() }
                }
                Errors=@(); InvalidKeys=@(); SharedLayers=@{}
            }
        }
        Mock Send-TelegramMessage { }
    }

    It 'lists unique categories and retains original template indexes in a filtered keyboard' {
        @(Get-TemplateCategories) | Should -Be @('أخبار', 'أسماء')
        $keyboard = Get-TemplatesKeyboard -Prefix tpl -Category 'أخبار'
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'tpl:1'
        $callbacks | Should -Contain 'tpl:2'
        $callbacks | Should -Not -Contain 'tpl:0'
    }

    It 'searches key description and category without case sensitivity' {
        $keyboard = Get-TemplatesKeyboard -Prefix tpl -Query 'URGENT'
        $labels = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object text)
        ($labels -join ' ') | Should -Match 'urgent'
        ($labels -join ' ') | Should -Not -Match 'weather'

        $categorySearch = Get-TemplatesKeyboard -Prefix tpl -Query 'أخبار'
        $categoryCallbacks = @($categorySearch.inline_keyboard | ForEach-Object { $_ } | ForEach-Object callback_data)
        $categoryCallbacks | Should -Contain 'tpl:1'
        $categoryCallbacks | Should -Contain 'tpl:2'
    }

    It 'shows the last successful use time and completes a private search flow' {
        $script:TemplateLastUsed['urgent'] = [datetime]'2026-08-22T12:34:00Z'
        (Get-TemplateLastUsedLabel -Key urgent) | Should -Match '08-22'

        Start-TemplateSearch -ChatId 10 -UserId 20
        (Get-PendingState -ChatId 10).Mode | Should -Be 'template_search'
        Complete-TemplateSearch -ChatId 10 -Value 'urgent'
        Get-PendingState -ChatId 10 | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 2 -Exactly
    }

    It 'provides a non-mutating preview before selecting a template' {
        $preview = Get-TemplatePreviewText -Template (Get-TemplateStore).Map.urgent
        $preview | Should -Match 'أخبار|خبر عاجل|Headline|طبقة: 7'
        $keyboard = Get-TemplatesKeyboard -Prefix tpl
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'tplinfo:1'
        (Get-TemplatePreviewKeyboard -TemplateIndex 1).inline_keyboard[0][0].callback_data | Should -Be 'tpl:1'
    }
}

Describe 'Administrator template registry import and export' {
    BeforeEach {
        $script:OriginalTemplateRegistryPathForImport = $config.TemplateRegistryPath
        $script:OriginalLogDirForImport = $script:logDir
        $script:OriginalFullTemplateManagementForImport = $config.Settings.EnableFullTemplateManagement
        $config.Settings.EnableFullTemplateManagement = $true
        $script:logDir = $TestDrive
        $script:PendingState.Clear()
        $script:OnAir = @{}
        $script:ScheduleEvents = [Collections.Generic.List[object]]::new()
        $script:TemplateCache = @{ WriteTime=[datetime]::MinValue; Path=''; Map=@{}; Order=@(); Errors=@() }
        $script:ImportRegistryPath = Join-Path $TestDrive 'templates.json'
        Remove-Item -LiteralPath "$($script:ImportRegistryPath).backups" -Recurse -Force -ErrorAction SilentlyContinue
        $config.TemplateRegistryPath = $script:ImportRegistryPath
        $script:CurrentRegistry = [ordered]@{
            alpha = [ordered]@{ path='C:\Scenes\Alpha.cintitle'; layer=1; fields=@('Title') }
            beta = [ordered]@{ path='C:\Scenes\Beta.cintitle'; layer=2; fields=@() }
        }
        $script:ImportedRegistry = [ordered]@{
            alpha = [ordered]@{ path='C:\Scenes\Alpha.cintitle'; layer=1; fields=@('Title') }
            gamma = [ordered]@{ path='C:\Scenes\Gamma.cintitle'; layer=3; category='أخبار'; fields=@() }
        }
        $script:CurrentRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:ImportRegistryPath
        $script:IncomingPath = Join-Path $TestDrive 'incoming.json'
        $script:ImportedRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:IncomingPath
        Mock Test-Admin { $true }
        $script:ImportSentTexts = [Collections.Generic.List[string]]::new()
        Mock Send-TelegramMessage { $script:ImportSentTexts.Add([string]$Text) | Out-Null }
        Mock Send-TelegramDocument { $true }
        Mock Add-AuditEntry { }
    }

    AfterEach {
        $config.TemplateRegistryPath = $script:OriginalTemplateRegistryPathForImport
        $script:logDir = $script:OriginalLogDirForImport
        $config.Settings.EnableFullTemplateManagement = $script:OriginalFullTemplateManagementForImport
    }

    It 'validates a bounded registry and rejects unsafe definitions' {
        (Test-TemplateRegistryImport -Path $script:IncomingPath).Success | Should -BeTrue
        $invalidPath = Join-Path $TestDrive 'invalid.json'
        @{ bad = @{ path='relative.cintitle'; layer=0; fields=@() } } | ConvertTo-Json -Depth 5 | Set-Content $invalidPath
        $invalid = Test-TemplateRegistryImport -Path $invalidPath
        $invalid.Success | Should -BeFalse
        $invalid.Error | Should -Match 'مسار|طبقة'
    }

    It 'accepts more than 200 templates when the configured import limit allows them' {
        $hadLimit = $config.Settings.PSObject.Properties.Match('TemplateRegistryImportMaxTemplates').Count -gt 0
        $previousLimit = if ($hadLimit) { $config.Settings.TemplateRegistryImportMaxTemplates } else { $null }
        try {
            $config.Settings | Add-Member -NotePropertyName 'TemplateRegistryImportMaxTemplates' -NotePropertyValue 250 -Force
            $largeRegistry = [ordered]@{}
            foreach ($index in 1..201) {
                $largeRegistry["template$index"] = [ordered]@{ path="C:\Scenes\Template$index.cintitle"; layer=$index; fields=@() }
            }
            $path = Join-Path $TestDrive 'over-200-templates.json'
            $largeRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8

            $result = Test-TemplateRegistryImport -Path $path
            $result.Success | Should -BeTrue -Because $result.Error
            $result.Count | Should -Be 201
        }
        finally {
            if ($hadLimit) {
                $config.Settings | Add-Member -NotePropertyName 'TemplateRegistryImportMaxTemplates' -NotePropertyValue $previousLimit -Force
            }
            else {
                [void]$config.Settings.PSObject.Properties.Remove('TemplateRegistryImportMaxTemplates')
            }
        }
    }

    It 'computes additions removals changes and unchanged definitions' {
        $comparison = Get-TemplateRegistryImportComparison -Current ($script:CurrentRegistry | ConvertTo-Json -Depth 10 | ConvertFrom-Json) `
            -Imported ($script:ImportedRegistry | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $comparison.Added | Should -Be @('gamma')
        $comparison.Removed | Should -Be @('beta')
        $comparison.Unchanged | Should -Be @('alpha')
        $comparison.Changed.Count | Should -Be 0
    }

    It 'applies atomically with a backup only after validation' {
        $result = Set-ImportedTemplateRegistry -StagedPath $script:IncomingPath
        $result.Success | Should -BeTrue -Because $result.Error
        Test-Path -LiteralPath $result.BackupPath | Should -BeTrue
        $saved = Get-Content -LiteralPath $script:ImportRegistryPath -Raw | ConvertFrom-Json
        $saved.PSObject.Properties.Name | Should -Contain 'gamma'
        $saved.PSObject.Properties.Name | Should -Not -Contain 'beta'
    }

    It 'blocks changing or removing a template that is live or scheduled' {
        $script:OnAir[2] = @{ Key='beta'; UserId=10 }
        $result = Set-ImportedTemplateRegistry -StagedPath $script:IncomingPath
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'الهواء|جدولة'
        Test-Path -LiteralPath "$($script:ImportRegistryPath).backups" | Should -BeFalse
    }

    It 'stages an uploaded document and requires confirmation before replacement' {
        Mock Receive-TelegramDocument {
            New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null
            Copy-Item -LiteralPath $script:IncomingPath -Destination $DestinationPath
            return $DestinationPath
        }
        Start-TemplateRegistryImport -ChatId 100 -UserId 100
        Receive-TemplateRegistryImport -Document ([pscustomobject]@{ file_name='templates.json'; file_size=500; file_id='safe-id' }) -ChatId 100 -UserId 100
        $state = Get-PendingState -ChatId 100
        $state.Mode | Should -Be 'template_import_review' -Because ($script:ImportSentTexts -join ' | ')
        Test-Path -LiteralPath $state.ImportStagedPath | Should -BeTrue
        (Get-Content -LiteralPath $script:ImportRegistryPath -Raw) | Should -Match 'beta'
    }

    It 'accepts a large template registry upload up to the 10 MB limit' {
        $script:CapturedTemplateImportMaximum = 0
        $largeRegistry = [ordered]@{
            alpha = [ordered]@{ path='C:\Scenes\Alpha.cintitle'; layer=1; fields=@('Title'); description=[string]::new([char]'x', 1100000) }
            gamma = [ordered]@{ path='C:\Scenes\Gamma.cintitle'; layer=3; category='أخبار'; fields=@() }
        }
        $largeRegistry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:IncomingPath -Encoding utf8
        $actualBytes = (Get-Item -LiteralPath $script:IncomingPath).Length
        $actualBytes | Should -BeGreaterThan 1048576
        Mock Receive-TelegramDocument {
            $script:CapturedTemplateImportMaximum = $MaximumBytes
            New-Item -ItemType Directory -Path (Split-Path -Parent $DestinationPath) -Force | Out-Null
            Copy-Item -LiteralPath $script:IncomingPath -Destination $DestinationPath
            return $DestinationPath
        }

        Start-TemplateRegistryImport -ChatId 100 -UserId 100
        Receive-TemplateRegistryImport -Document ([pscustomobject]@{ file_name='templates.json'; file_size=$actualBytes; file_id='large-id' }) -ChatId 100 -UserId 100

        $script:CapturedTemplateImportMaximum | Should -Be 10485760
        (Get-PendingState -ChatId 100).Mode | Should -Be 'template_import_review'
    }

    It 'exports only to an administrator through the existing document sender' {
        Invoke-TemplateRegistryExport -ChatId 100 -UserId 100
        Should -Invoke Send-TelegramDocument -Times 1 -Exactly -ParameterFilter { $FilePath -eq $script:ImportRegistryPath }
        Should -Invoke Add-AuditEntry -Times 1 -Exactly
    }
}

Describe 'Isolated template test layer and definition comparison' {
    BeforeEach {
        $script:OriginalTestLayer = $config.Settings.TemplateTestLayer
        $script:OriginalTestSeconds = $config.Settings.TemplateTestAutoHideSeconds
        $script:OriginalFullManagementForTest = $config.Settings.EnableFullTemplateManagement
        $config.Settings.TemplateTestLayer = 9
        $config.Settings.TemplateTestAutoHideSeconds = 7
        $config.Settings.EnableFullTemplateManagement = $true
        $script:PendingState.Clear(); $script:OnAir=@{}; $script:AutoHideQueue=[Collections.Generic.List[object]]::new()
        Mock Test-Admin { $true }
        Mock Get-TemplateStore {
            @{ Order=@('alpha'); Map=@{ alpha=@{ Key='alpha'; Path='C:\Scenes\Alpha.cintitle'; Layer=5; Fields=@('Title'); FieldTypes=@{}; Description='test' } }; Errors=@() }
        }
        Mock Send-TelegramMessage { }
        Mock Save-OnAirState { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$false } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success=$true; EventId='test-event'; Error='' } }
    }

    AfterEach {
        $config.Settings.TemplateTestLayer = $script:OriginalTestLayer
        $config.Settings.TemplateTestAutoHideSeconds = $script:OriginalTestSeconds
        $config.Settings.EnableFullTemplateManagement = $script:OriginalFullManagementForTest
    }

    It 'refuses to use a production template layer as the test layer' {
        $config.Settings.TemplateTestLayer = 5
        Start-TemplateTestReview -TemplateIndex 0 -ChatId 10 -UserId 10
        Get-PendingState -ChatId 10 | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'طبقة إنتاج' }
    }

    It 'requires review then verifies the layer is empty before any SHOW' {
        Start-TemplateTestReview -TemplateIndex 0 -ChatId 10 -UserId 10
        (Get-PendingState -ChatId 10).Mode | Should -Be 'template_test_review'
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true } }

        Confirm-TemplateTest -ChatId 10 -UserId 10
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
        $script:OnAir.ContainsKey(9) | Should -BeFalse
    }

    It 'shows only on the isolated layer and always creates an automatic hide deadline' {
        Start-TemplateTestReview -TemplateIndex 0 -ChatId 10 -UserId 10
        Confirm-TemplateTest -ChatId 10 -UserId 10

        Should -Invoke Show-TitlerTemplate -Times 1 -Exactly -ParameterFilter { $Layer -eq 9 -and $Variables.Title -eq 'TEST' }
        $script:OnAir[9].Source | Should -Be 'BotTest'
        $script:AutoHideQueue.Count | Should -Be 1
        [int](($script:AutoHideQueue[0].At - (Get-Date)).TotalSeconds) | Should -BeLessOrEqual 7
        Should -Invoke Save-OnAirState -Times 1 -Exactly
    }

    It 'shows field-level before and after differences before an edit is saved' {
        $existing = [pscustomobject]@{ path='C:\Scenes\Alpha.cintitle'; layer=5; description='قديم'; fields=@('Title') }
        $definition = @{ path='C:\Scenes\Alpha.cintitle'; layer=6; description='جديد'; fields=@('Title') }
        $text = Get-TemplateDefinitionComparisonText -Existing $existing -Definition $definition
        $text | Should -Match 'layer|description|قبل|بعد'
        $text | Should -Not -Match 'path.*قبل'
    }
}

Describe 'Template registry parsing' {
    It 'accepts both plain-string and labelled field definitions' {
        $file = New-TempTemplateFile -Json @'
{
  "a": { "path": "C:\\x.cintitle", "layer": 3, "order": 1, "fields": ["Plain.Text"] },
  "b": { "path": "C:\\y.cintitle", "layer": 4, "order": 2,
         "fields": [ { "name": "Ajel.center", "label": "نص العاجل" } ] }
}
'@
        try {
            $store = Get-TemplateStore
            $store.Order.Count | Should -Be 2
            $store.Map['a'].Fields[0] | Should -Be 'Plain.Text'
            $store.Map['a'].FieldLabels[0] | Should -Be ''
            $store.Map['b'].Fields[0] | Should -Be 'Ajel.center'
            $store.Map['b'].FieldLabels[0] | Should -Be 'نص العاجل'
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'makes an explicit owner inherit administrator permissions without promoting an administrator to owner' {
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(202) -Force
        try {
            Test-Admin -ChatId 202 -UserId 202 | Should -BeTrue
            Test-Owner -ChatId 101 -UserId 101 | Should -BeFalse
        }
        finally { $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force }
    }

    It 'loads a per-template reminder duration in minutes' {
        $file = New-TempTemplateFile -Json '{ "urgent": { "path": "C:\\x.cintitle", "layer": 3, "reminderMinutes": 15 } }'
        try {
            (Get-TemplateStore).Map['urgent'].ReminderMinutes | Should -Be 15
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'parses required fields without making legacy string fields mandatory' {
        $file = New-TempTemplateFile -Json @'
{
  "urgent": {
    "path": "C:\\x.cintitle", "layer": 3,
    "fields": [
      { "name": "Headline.Text", "label": "العنوان", "required": true },
      "Optional.Text"
    ]
  }
}
'@
        try {
            $template = (Get-TemplateStore).Map['urgent']
            @(Get-JsonProp $template 'FieldRequired') | Should -Be @($true, $false)
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'skips templates missing path or layer instead of crashing' {
        $file = New-TempTemplateFile -Json @'
{
  "good":    { "path": "C:\\x.cintitle", "layer": 3 },
  "nopath":  { "layer": 3 },
  "nolayer": { "path": "C:\\y.cintitle" }
}
'@
        try {
            $store = Get-TemplateStore
            $store.Order | Should -Be @('good')
            $store.Errors.Count | Should -Be 2
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'gives an absent fields key an empty array, not a phantom null field' {
        $file = New-TempTemplateFile -Json '{ "solo": { "path": "C:\\x.cintitle", "layer": 2 } }'
        try {
            (Get-TemplateStore).Map['solo'].Fields.Count | Should -Be 0
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'resolves field limits: field maxLength beats template beats global' {
        $file = New-TempTemplateFile -Json @'
{
  "t": { "path": "C:\\x.cintitle", "layer": 1, "maxLength": 120,
         "fields": [ { "name": "A.Text", "maxLength": 40 },
                     { "name": "B.Text" },
                     "C.Text" ] }
}
'@
        try {
            $t = (Get-TemplateStore).Map['t']
            $t.FieldLimits[0] | Should -Be 40    # field override
            $t.FieldLimits[1] | Should -Be 120   # template default
            $t.FieldLimits[2] | Should -Be 120   # plain string inherits template
            Get-EffectiveFieldLimit -FieldLimit 40 | Should -Be 40
            Get-EffectiveFieldLimit -FieldLimit 0  | Should -Be (Get-SettingInt 'MaxFieldLength' 0)
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'falls back to the global limit when no maxLength is declared' {
        $file = New-TempTemplateFile -Json '{ "t": { "path": "C:\\x.cintitle", "layer": 1, "fields": ["A.Text"] } }'
        try {
            (Get-TemplateStore).Map['t'].FieldLimits[0] | Should -Be 0
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'orders deterministically by order then key' {
        $file = New-TempTemplateFile -Json @'
{
  "zebra": { "path": "C:\\z.cintitle", "layer": 1, "order": 1 },
  "alpha": { "path": "C:\\a.cintitle", "layer": 2, "order": 5 },
  "beta":  { "path": "C:\\b.cintitle", "layer": 3, "order": 1 }
}
'@
        try {
            (Get-TemplateStore).Order | Should -Be @('beta', 'zebra', 'alpha')
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts multiple templates on one layer and reports the shared layer as information' {
        $file = New-TempTemplateFile -Json @'
{
  "headline": { "path": "C:\\headline.cintitle", "layer": 4 },
  "breaking": { "path": "C:\\breaking.cintitle", "layer": 4 }
}
'@
        try {
            $store = Get-TemplateStore
            $store.Order.Count | Should -Be 2
            @($store.SharedLayers['4']) | Sort-Object | Should -Be @('breaking', 'headline')
            $store.Errors.Count | Should -Be 0
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }

    It 'excludes invalid template path formats and exposes their keys to health reporting' {
        $file = New-TempTemplateFile -Json @'
{
  "good": { "path": "C:\\valid.cintitle", "layer": 3 },
  "relative": { "path": "titles\\relative.cintitle", "layer": 4 },
  "wrongext": { "path": "C:\\wrong.txt", "layer": 5 }
}
'@
        try {
            $store = Get-TemplateStore
            $store.Order | Should -Be @('good')
            @($store.InvalidKeys) | Sort-Object | Should -Be @('relative', 'wrongext')
            $store.Errors -join ' ' | Should -Match 'relative.*مسار|wrongext.*cintitle'
        }
        finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Template definition storage' {
    BeforeEach {
        $script:OriginalTemplateRegistryPathForDefinitionTest = $config.TemplateRegistryPath
        $script:DefinitionRegistryPathForTest = New-TempTemplateFile -Json '{ "urgent": { "path": "titles/urgent.cintitle", "layer": 4, "fields": ["Headline.Text"] } }'
        $script:OnAir.Clear()
        Mock Get-UpcomingScheduleEvents { @() }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:DefinitionRegistryPathForTest -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$($script:DefinitionRegistryPathForTest).backups" -Recurse -Force -ErrorAction SilentlyContinue
        $config.TemplateRegistryPath = $script:OriginalTemplateRegistryPathForDefinitionTest
        $script:OnAir.Clear()
    }

    It 'writes a validated definition edit atomically with a backup' {
        $result = Save-TemplateDefinitionChange -TemplateKey 'urgent' -Action edit -Definition @{ path = 'titles/urgent.cintitle'; layer = 5; fields = @('Headline.Text') }
        $saved = Get-Content -LiteralPath $script:DefinitionRegistryPathForTest -Raw | ConvertFrom-Json

        $result.Success | Should -BeTrue
        $saved.urgent.layer | Should -Be 5
        Test-Path -LiteralPath $result.BackupPath | Should -BeTrue
    }

    It 'rejects deleting an on-air template' {
        $script:OnAir[4] = @{ Key = 'urgent'; At = Get-Date; UserId = 10; ActiveId = '{A}' }

        $result = Save-TemplateDefinitionChange -TemplateKey 'urgent' -Action delete

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'على الهواء'
    }
}

Describe 'Template create wizard' {
    BeforeEach {
        $script:OriginalTemplateRegistryPathForWizardTest = $config.TemplateRegistryPath
        $script:OriginalFullTemplateManagementForWizard = $config.Settings.EnableFullTemplateManagement
        $config.Settings.EnableFullTemplateManagement = $true
        $script:WizardRegistryPathForTest = New-TempTemplateFile -Json '{ "urgent": { "path": "titles/urgent.cintitle", "layer": 4, "fields": ["Headline.Text"] } }'
        Clear-PendingState -ChatId 77
        Mock Send-TelegramMessage { }
    }

    AfterEach {
        Remove-Item -LiteralPath $script:WizardRegistryPathForTest -Force -ErrorAction SilentlyContinue
        $config.TemplateRegistryPath = $script:OriginalTemplateRegistryPathForWizardTest
        $config.Settings.EnableFullTemplateManagement = $script:OriginalFullTemplateManagementForWizard
        Clear-PendingState -ChatId 77
    }

    It 'walks key, path, layer and fields into a reviewable create definition' {
        Start-TemplateCreateWizard -ChatId 77 -UserId 77
        Get-PendingState -ChatId 77 | Select-Object -ExpandProperty Mode | Should -Be 'template_create_key'

        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'new-template'
        Get-PendingState -ChatId 77 | Select-Object -ExpandProperty Mode | Should -Be 'template_create_path'

        # An absolute path, because that is where scenes actually live. The
        # wizard used to demand a path inside the project folder, so it could
        # not register a single real scene.
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'C:\Cinegy\Titler\Scenes\new.cintitle'
        Get-PendingState -ChatId 77 | Select-Object -ExpandProperty Mode | Should -Be 'template_create_path'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'تم'
        Get-PendingState -ChatId 77 | Select-Object -ExpandProperty Mode | Should -Be 'template_create_layer'

        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value '4'
        Get-PendingState -ChatId 77 | Select-Object -ExpandProperty Mode | Should -Be 'template_create_fields'

        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'Headline.Text, Subtitle.Text'
        Get-PendingState -ChatId 77 | Select-Object -ExpandProperty Mode | Should -Be 'template_create_details'

        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'الاسم السفلي | أسماء'
        $state = Get-PendingState -ChatId 77
        $state.Mode | Should -Be 'template_definition_review'
        $state.Action | Should -Be 'create'
        $state.TemplateKey | Should -Be 'new-template'
        $state.Definition['path'] | Should -Be 'C:\Cinegy\Titler\Scenes\new.cintitle'
        $state.Definition['layer'] | Should -Be 4
        @($state.Definition['fields']).Count | Should -Be 2
        $state.Definition['description'] | Should -Be 'الاسم السفلي'
        $state.Definition['category'] | Should -Be 'أسماء'
    }

    It 'takes a device name where the layer has no number' {
        # The logo sits on gfx_logo. Before this the wizard had no way to say
        # so, and the only route was the raw JSON screen.
        Start-TemplateCreateWizard -ChatId 77 -UserId 77
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'station-logo'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'C:\Scenes\logo.cintitle'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'تم'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'logo'

        $state = Get-PendingState -ChatId 77
        $state.Mode | Should -Be 'template_create_fields'
        $state.Definition['device'] | Should -Be 'logo'
    }

    It 'lets the description and category be skipped in one word' {
        Start-TemplateCreateWizard -ChatId 77 -UserId 77
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'quick'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'C:\Scenes\q.cintitle'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'تم'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value '5'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'لا يوجد'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'تخطي'

        $state = Get-PendingState -ChatId 77
        $state.Mode | Should -Be 'template_definition_review'
        $state.Definition.ContainsKey('description') | Should -BeFalse
    }

    It 'refuses a path that is not a scene file' {
        Start-TemplateCreateWizard -ChatId 77 -UserId 77
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'bad-path'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'C:\Scenes\notes.txt'

        (Get-PendingState -ChatId 77).Mode | Should -Be 'template_create_path'
    }

    It 'refuses a bare file name when no scenes folder is configured' {
        # Guessing from the working directory would resolve differently for a
        # service and for a console.
        Start-TemplateCreateWizard -ChatId 77 -UserId 77
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'relative-one'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'new.cintitle'

        (Get-PendingState -ChatId 77).Mode | Should -Be 'template_create_path'
    }

    It 'rejects a duplicate key without leaving the step' {
        Start-TemplateCreateWizard -ChatId 77 -UserId 77
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'urgent'
        (Get-PendingState -ChatId 77).Mode | Should -Be 'template_create_key'
    }

    It 'accepts an empty field list via لا يوجد' {
        Start-TemplateCreateWizard -ChatId 77 -UserId 77
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'plain'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'C:\Cinegy\Titler\Scenes\plain.cintitle'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'تم'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value '9'
        Complete-TemplateCreateWizardStep -ChatId 77 -UserId 77 -Value 'لا يوجد'
        $state = Get-PendingState -ChatId 77
        @($state.Definition['fields']).Count | Should -Be 0
    }
}

Describe 'Template catalogue administration' {
    BeforeEach {
        Mock Send-TelegramMessage { }
        Mock Test-Admin { $true }
        # The function reads the template store; do not depend on the live
        # templates.json (it is machine-local and not committed to the repo,
        # so it is absent on CI and the index-0 lookup returns $null there).
        # Seed a stable fake so the assertion is deterministic everywhere.
        Mock Get-TemplateByIndex -ParameterFilter { $Index -eq 0 } -MockWith {
            [pscustomobject]@{
                Key         = 'urgent'
                Path        = 'titles/urgent.cintitle'
                Layer       = 4
                Order       = 1
                Description = 'قالب عاجل للاختبار'
                Fields      = @('Headline.Text')
                Presets     = @()
            }
        }
    }

    It 'shows read-only template details while full management is disabled' {
        $config.Settings | Add-Member -NotePropertyName 'EnableFullTemplateManagement' -NotePropertyValue $false -Force
        Show-TemplateAdminDetail -TemplateIndex 0 -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'المسار' -and $Text -match 'الطبقة' -and $Text -match 'تعديل تعريف القالب'
        }
    }

    It 'lets an administrator choose the default scene mode from constrained settings' {
        $original = Get-Setting 'SceneMode'
        Mock Save-Config { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-TelegramMessage { }
        Mock Get-CinegyLayerDashboard { @([pscustomobject]@{ Success = $true; ActiveId = '{ACTIVE}' }) }

        try {
            $script:SettingChoices['SceneMode'] | Should -Be @('Single', 'Multi')
            Set-SettingChoice -Name 'SceneMode' -Index 1 -ChatId 100 -UserId 100
            Get-Setting 'SceneMode' | Should -Be 'Multi'
        }
        finally { $config.Settings | Add-Member -NotePropertyName 'SceneMode' -NotePropertyValue $original -Force }
    }

    It 'lets an explicit owner who is not an administrator open a template reminder' {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $false }
        Mock Test-Owner { $true }
        Mock Start-TemplateReminderMinutesPrompt { }
        $callback = [pscustomobject]@{
            id      = 'owner-template-reminder-1'
            from    = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 101 } }
            data    = 'tadm:reminder:0'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Start-TemplateReminderMinutesPrompt -Times 1 -Exactly -ParameterFilter {
            $TemplateIndex -eq 0 -and $ChatId -eq 101 -and $UserId -eq 101
        }
    }

    It 'does not save reminder minutes after the editor loses admin and owner roles' {
        Mock Test-Admin { $false }
        Mock Test-Owner { $false }
        Mock Save-TemplateReminderMinutes { [pscustomobject]@{ Success = $true; Error = '' } }
        Set-PendingState -ChatId 100 -State @{
            Mode = 'template_reminder_minutes'; TemplateIndex = 0; TemplateKey = 'urgent'; UserId = 100L
        }

        Complete-TemplateReminderMinutes -ChatId 100 -UserId 100 -Value '15'

        Should -Invoke Save-TemplateReminderMinutes -Times 0 -Exactly
        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'صلاحية' }
    }
}

Describe 'Persistent personal template reminders' {
    BeforeEach {
        $script:OriginalTemplateReminderFileForTest = $script:templateReminderFile
        $script:templateReminderFile = Join-Path $TestDrive 'template-reminders.json'
        $script:TemplateReminderQueue = [System.Collections.Generic.List[hashtable]]::new()
        $script:OnAir = @{}
        Mock Write-BridgeLog { }
        Mock Send-TelegramMessage { }
        Mock Get-TemplateStore {
            @{ Map = @{ Urgent = @{ Key = 'Urgent'; ReminderMinutes = 15; LongRunning = $false } }; Order = @('Urgent'); Errors = @() }
        }
        $config.Settings | Add-Member -NotePropertyName 'TemplateReminderFollowUpMinutes' -NotePropertyValue 5 -Force
    }

    AfterEach {
        $script:TemplateReminderQueue = [System.Collections.Generic.List[hashtable]]::new()
        $script:OnAir = @{}
        $script:templateReminderFile = $script:OriginalTemplateReminderFileForTest
    }

    It 'restores a reminder and alerts the operator who showed the same scene directly' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-1'; At = $now.DateTime; UserId = 2L }
        $script:TemplateReminderQueue.Add(@{
                Layer = 7; At = $now.AddMinutes(15).ToString('o'); ChatId = 2L; UserId = 2L
                TemplateKey = 'Urgent'; ActiveId = 'show-1'; Minutes = 15
            })
        Save-TemplateReminderQueue | Should -BeTrue
        $script:TemplateReminderQueue.Clear()

        Import-TemplateReminderQueue
        Update-TemplateReminderQueue -Now $now.AddMinutes(14)

        $script:TemplateReminderQueue.Count | Should -Be 1
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly

        Update-TemplateReminderQueue -Now $now.AddMinutes(15)

        $script:TemplateReminderQueue.Count | Should -Be 1
        $script:TemplateReminderQueue[0].Stage | Should -Be 'followup'
        [datetimeoffset]$script:TemplateReminderQueue[0].At | Should -Be $now.AddMinutes(20)
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 2 -and $Text -match '15' -and $Text -match 'Urgent' -and
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) -match '^remack:'
        }
    }

    It 'sends one follow-up only when the owner did not acknowledge' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-1'; At = $now.DateTime; UserId = 2L }
        $script:TemplateReminderQueue.Add(@{ ReminderId='abc123'; Stage='initial'; Layer=7; At=$now; ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='show-1'; Minutes=15 })

        Update-TemplateReminderQueue -Now $now
        Update-TemplateReminderQueue -Now $now.AddMinutes(5)
        Update-TemplateReminderQueue -Now $now.AddMinutes(10)

        Should -Invoke Send-TelegramMessage -Times 2 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'متابعة' }
        $script:TemplateReminderQueue.Count | Should -Be 0
    }

    It 'does not send or lose a due reminder when consuming it cannot be persisted' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key='Urgent'; ActiveId='engine-1'; At=$now.DateTime; UserId=2L }
        $script:TemplateReminderQueue.Add(@{ ReminderId='abc123'; Stage='initial'; Layer=7; At=$now; ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='engine-1'; ActiveIdConfirmed=$true; Minutes=15 })
        Mock Save-TemplateReminderQueue { $false }

        Update-TemplateReminderQueue -Now $now

        $script:TemplateReminderQueue.Count | Should -Be 1
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'restores a pending follow-up with its acknowledgement identity after restart' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:TemplateReminderQueue.Add(@{
                ReminderId='abc123'; Stage='followup'; Layer=7; At=$now.AddMinutes(5)
                ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='engine-1'
                ActiveIdConfirmed=$true; Minutes=15; FollowUpMinutes=5
            })

        Save-TemplateReminderQueue | Should -BeTrue
        $script:TemplateReminderQueue.Clear()
        Import-TemplateReminderQueue

        $script:TemplateReminderQueue.Count | Should -Be 1
        $script:TemplateReminderQueue[0].ReminderId | Should -Be 'abc123'
        $script:TemplateReminderQueue[0].Stage | Should -Be 'followup'
        $script:TemplateReminderQueue[0].ActiveIdConfirmed | Should -BeTrue
        $script:TemplateReminderQueue[0].FollowUpMinutes | Should -Be 5
    }

    It 'allows only the notified user to acknowledge and cancel the follow-up' {
        Mock Save-TemplateReminderQueue { $true }
        $script:TemplateReminderQueue.Add(@{ ReminderId='abc123'; Stage='followup'; Layer=7; At=[datetimeoffset]::Now.AddMinutes(5); ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='show-1'; Minutes=15 })

        Confirm-TemplateReminder -ReminderId 'abc123' -UserId 3 | Should -BeFalse
        $script:TemplateReminderQueue.Count | Should -Be 1
        Confirm-TemplateReminder -ReminderId 'abc123' -UserId 2 | Should -BeTrue
        $script:TemplateReminderQueue.Count | Should -Be 0
    }

    It 'rolls back acknowledgement when the cancellation cannot be persisted' {
        Mock Save-TemplateReminderQueue { $false }
        $script:TemplateReminderQueue.Add(@{ ReminderId='abc123'; Stage='followup'; Layer=7; At=[datetimeoffset]::Now.AddMinutes(5); ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='show-1'; Minutes=15 })

        Confirm-TemplateReminder -ReminderId 'abc123' -UserId 2 | Should -BeFalse

        $script:TemplateReminderQueue.Count | Should -Be 1
        $script:TemplateReminderQueue[0].ReminderId | Should -Be 'abc123'
    }

    It 'enforces reminder ownership through the Telegram callback dispatcher' {
        Mock Save-TemplateReminderQueue { $true }
        Mock Test-Authorized { $true }
        Mock Test-TelegramPrivateChat { $true }
        Mock Confirm-TelegramCallback { }
        Mock Update-UserLastActivity { }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard=@() } }
        $script:TemplateReminderQueue.Add(@{ ReminderId='abc123'; Stage='followup'; Layer=7; At=[datetimeoffset]::Now.AddMinutes(5); ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='show-1'; Minutes=15 })
        $foreign = [pscustomobject]@{ id='cb-foreign'; data='remack:abc123'; from=[pscustomobject]@{ id=3L }; message=[pscustomobject]@{ message_id=1; chat=[pscustomobject]@{ id=3L; type='private' } } }
        $owner = [pscustomobject]@{ id='cb-owner'; data='remack:abc123'; from=[pscustomobject]@{ id=2L }; message=[pscustomobject]@{ message_id=2; chat=[pscustomobject]@{ id=2L; type='private' } } }

        Invoke-CallbackQuery -CallbackQuery $foreign
        $script:TemplateReminderQueue.Count | Should -Be 1
        Invoke-CallbackQuery -CallbackQuery $owner
        $script:TemplateReminderQueue.Count | Should -Be 0
    }

    It 'does not retain a follow-up when the administrator disables it' {
        $config.Settings.TemplateReminderFollowUpMinutes = 0
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-1'; At = $now.DateTime; UserId = 2L }
        $script:TemplateReminderQueue.Add(@{ ReminderId='abc123'; Stage='initial'; Layer=7; At=$now; ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='show-1'; Minutes=15 })

        Update-TemplateReminderQueue -Now $now

        $script:TemplateReminderQueue.Count | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
    }

    It 'targets the initiating user instead of the Telegram group' {
        Mock Save-TemplateReminderQueue { $true }
        $template = @{ Key = 'Urgent'; Layer = 7; LongRunning = $false; ReminderMinutes = 15 }

        Set-TemplateReminder -Template $template -ChatId 900 -UserId 202 -ActiveId 'show-1' | Should -BeTrue

        $script:TemplateReminderQueue.Count | Should -Be 1
        $script:TemplateReminderQueue[0].ChatId | Should -Be 202
        $script:TemplateReminderQueue[0].UserId | Should -Be 202
    }

    It 'does not queue a reminder for a long-running template' {
        $template = @{ Key = 'Logo'; Layer = 2; LongRunning = $true; ReminderMinutes = 15 }

        Set-TemplateReminder -Template $template -ChatId 101 -UserId 2 -ActiveId 'logo-1' | Should -BeFalse

        $script:TemplateReminderQueue.Count | Should -Be 0
    }

    It 'cancels a saved reminder when its template setting is changed to disabled' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-1'; At = $now.DateTime; UserId = 2L }
        $script:TemplateReminderQueue.Add(@{
                Layer = 7; At = $now.AddMinutes(-1); ChatId = 101L; UserId = 2L
                TemplateKey = 'Urgent'; ActiveId = 'show-1'; Minutes = 15
            })
        Mock Get-TemplateStore { @{ Map = @{ Urgent = @{ Key = 'Urgent'; ReminderMinutes = 0; LongRunning = $false } }; Order = @('Urgent'); Errors = @() } }

        Update-TemplateReminderQueue -Now $now

        $script:TemplateReminderQueue.Count | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'discards a due reminder when the layer now has a replacement scene' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-new'; At = $now.DateTime; UserId = 3L }
        $script:TemplateReminderQueue.Add(@{
                Layer = 7; At = $now.AddMinutes(-1); ChatId = 101L; UserId = 2L
                TemplateKey = 'Urgent'; ActiveId = 'show-old'; Minutes = 15
            })

        Update-TemplateReminderQueue -Now $now

        $script:TemplateReminderQueue.Count | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}

Describe 'Required template fields' {
    BeforeEach {
        $script:LayerLocks.Clear()
        Clear-PendingState -ChatId 30
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'
                Layer = 4
                Fields = @('Headline.Text')
                FieldLabels = @('العنوان')
                FieldLimits = @(80)
                FieldRequired = @($true)
            }
        }
        Mock Send-TelegramMessage { }
        Mock Invoke-ShowTemplateResult { }
    }

    AfterEach {
        Clear-PendingState -ChatId 30
        $script:LayerLocks.Clear()
    }

    It 'keeps the operator on a required field when empty text is submitted' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 30 -UserId 40
        Resume-ShowFlow -ChatId 30 -Value ''

        $state = Get-PendingState -ChatId 30
        $state | Should -Not -BeNullOrEmpty
        $state.Index | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 30 -and $Text -match 'مطلوب'
        }
    }

    It 'does not allow the skip button to bypass a required field' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 30 -UserId 40
        Resume-ShowFlow -ChatId 30 -Skip

        $state = Get-PendingState -ChatId 30
        $state | Should -Not -BeNullOrEmpty
        $state.Index | Should -Be 0
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
}

Describe 'Operator field progress' {
    It 'shows the current field number and total field count' {
        $state = @{
            Key = 'lower-third'
            Fields = @('First.Text', 'Second.Text', 'Third.Text', 'Fourth.Text')
            Labels = @('', '', '', '')
            Limits = @(0, 0, 0, 0)
            Index = 1
        }

        Get-FieldPromptText -State $state | Should -Match '\(2/4\)'
    }
}

Describe 'SHOW review gate' {
    BeforeEach {
        $script:LayerLocks.Clear()
        Clear-PendingState -ChatId 50
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'
                Layer = 4
                Fields = @('Headline.Text')
                FieldLabels = @('العنوان')
                FieldLimits = @(80)
                FieldRequired = @($true)
            }
        }
        Mock Send-TelegramMessage { }
        Mock Invoke-ShowTemplateResult { }
        Mock Get-LayerShowContext { [pscustomobject]@{ IsKnown = $true; IsOnAir = $false; Key = ''; UserId = 0; Source = '' } }
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
    }

    AfterEach {
        Clear-PendingState -ChatId 50
        $script:LayerLocks.Clear()
    }

    It 'does not send SHOW when the final field is entered before confirmation' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60
        Resume-ShowFlow -ChatId 50 -Value 'خبر عاجل'

        $state = Get-PendingState -ChatId 50
        $state | Should -Not -BeNullOrEmpty
        $state.Mode | Should -Be 'show_review'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'reviews a template with no fields instead of sending it immediately' {
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'logo'
                Layer = 2
                Fields = @()
                FieldLabels = @()
                FieldLimits = @()
                FieldRequired = @()
            }
        }

        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60

        $state = Get-PendingState -ChatId 50
        $state | Should -Not -BeNullOrEmpty
        $state.Mode | Should -Be 'show_review'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'warns in the review when SHOW will replace the current layer scene' {
        Mock Get-LayerShowContext {
            [pscustomobject]@{ IsKnown = $true; IsOnAir = $true; Key = 'old-title'; UserId = 77; Source = 'bridge' }
        }

        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60
        Resume-ShowFlow -ChatId 50 -Value 'خبر عاجل'

        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter {
            $Text -match 'سيتم استبدال' -and $Text -match 'old-title' -and $Text -match '77'
        }
    }

    It 'warns when the live layer cannot be verified before review' {
        Mock Get-LayerShowContext {
            [pscustomobject]@{ IsKnown = $false; IsOnAir = $false; Key = ''; UserId = 0; Source = '' }
        }

        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60
        Resume-ShowFlow -ChatId 50 -Value 'خبر عاجل'

        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $Text -match 'تعذّر التحقق.*الطبقة' }
    }

    It 'sends the reviewed values only after the operator confirms' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60
        Resume-ShowFlow -ChatId 50 -Value 'خبر عاجل'
        $callback = [pscustomobject]@{
            id = 'confirm-show-1'
            from = [pscustomobject]@{ id = 60 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 50 } }
            data = 'show:confirm'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Get-PendingState -ChatId 50 | Should -BeNullOrEmpty
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
            $Key -eq 'urgent' -and $ChatId -eq 50 -and $UserId -eq 60 -and $Variables['Headline.Text'] -eq 'خبر عاجل'
        }
    }

    It 'releases the preparation lock even when Cinegy fails during confirmed SHOW' {
        Mock Invoke-ShowTemplateResult { throw 'Cinegy disconnected' }
        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60
        Resume-ShowFlow -ChatId 50 -Value 'خبر عاجل'
        $callback = [pscustomobject]@{
            id = 'confirm-show-failure'
            from = [pscustomobject]@{ id = 60 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 50 } }
            data = 'show:confirm'
        }

        { Invoke-CallbackQuery -CallbackQuery $callback } | Should -Throw '*disconnected*'

        Get-PendingState -ChatId 50 | Should -BeNullOrEmpty
        $script:LayerLocks.ContainsKey(4) | Should -BeFalse
    }

    It 'returns from review to field editing without sending SHOW' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60
        Resume-ShowFlow -ChatId 50 -Value 'خبر عاجل'
        $callback = [pscustomobject]@{
            id = 'edit-show-1'
            from = [pscustomobject]@{ id = 60 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 50 } }
            data = 'show:edit'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        $state = Get-PendingState -ChatId 50
        $state.Mode | Should -Be 'show_fields'
        $state.Index | Should -Be 0
        $state.Values['Headline.Text'] | Should -Be 'خبر عاجل'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'moves to the previous field without losing entered values' {
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'lower-third'; Layer = 4
                Fields = @('First.Text', 'Second.Text')
                FieldLabels = @('الأول', 'الثاني')
                FieldLimits = @(80, 80)
                FieldRequired = @($false, $false)
            }
        }
        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60
        Resume-ShowFlow -ChatId 50 -Value 'القيمة الأولى'
        $callback = [pscustomobject]@{
            id = 'previous-field-1'
            from = [pscustomobject]@{ id = 60 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 50 } }
            data = 'show:back'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        $state = Get-PendingState -ChatId 50
        $state.Index | Should -Be 0
        $state.Values['First.Text'] | Should -Be 'القيمة الأولى'
    }

    It 'previews entered values without advancing or sending SHOW' {
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'lower-third'; Layer = 4
                Fields = @('First.Text', 'Second.Text')
                FieldLabels = @('الأول', 'الثاني')
                FieldLimits = @(80, 80)
                FieldRequired = @($false, $false)
            }
        }
        Start-ShowFlow -TemplateIndex 0 -ChatId 50 -UserId 60
        Resume-ShowFlow -ChatId 50 -Value 'القيمة الأولى'
        $callback = [pscustomobject]@{
            id = 'preview-draft-1'
            from = [pscustomobject]@{ id = 60 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 50 } }
            data = 'show:preview'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        (Get-PendingState -ChatId 50).Index | Should -Be 1
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 50 -and $Text -match 'معاينة المسودة'
        }
    }
}

Describe 'Direct SHOW entry review gates' {
    BeforeEach {
        $script:LayerLocks.Clear()
        Clear-PendingState -ChatId 51
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'; Layer = 4
                Fields = @('Headline.Text')
                FieldLabels = @('العنوان')
                FieldLimits = @(80)
                FieldRequired = @($true)
                Presets = @([pscustomobject]@{ Name = 'جاهز'; Values = @('خبر جاهز') })
            }
        }
        Mock Get-TemplateIndex { 0 }
        Mock Get-TemplateStore {
            [pscustomobject]@{
                Map = @{
                    urgent = [pscustomobject]@{
                        Key = 'urgent'; Layer = 4
                        Fields = @('Headline.Text')
                        FieldLabels = @('العنوان')
                        FieldLimits = @(80)
                        FieldRequired = @($true)
                    }
                }
            }
        }
        Mock Send-TelegramMessage { }
        Mock Invoke-ShowTemplateResult { }
    }

    AfterEach {
        Clear-PendingState -ChatId 51
        $script:LayerLocks.Clear()
    }

    It 'reviews a preset instead of sending it directly to Cinegy' {
        Invoke-PresetShow -TemplateIndex 0 -PresetIndex 0 -ChatId 51 -UserId 61

        $state = Get-PendingState -ChatId 51
        $state.Mode | Should -Be 'show_review'
        $state.Values['Headline.Text'] | Should -Be 'خبر جاهز'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'reviews a complete typed show command instead of sending it directly' {
        Invoke-ShowCommand -ArgText 'urgent | خبر مكتوب' -ChatId 51 -UserId 61

        $state = Get-PendingState -ChatId 51
        $state.Mode | Should -Be 'show_review'
        $state.Values['Headline.Text'] | Should -Be 'خبر مكتوب'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
}

Describe 'Persistent operator drafts' {
    BeforeEach {
        $script:OriginalDraftsFileForTest = $script:draftsFile
        $script:draftsFile = Join-Path $TestDrive 'drafts.json'
        $script:PendingState.Clear()
        $script:LayerLocks.Clear()
        Mock Get-TemplateIndex { 0 }
        Mock Write-BridgeLog { }
    }

    AfterEach {
        $script:PendingState.Clear()
        $script:LayerLocks.Clear()
        $script:draftsFile = $script:OriginalDraftsFileForTest
    }

    It 'restores an independent show draft and its layer lock after restart' {
        Set-PendingState -ChatId 71 -State @{
            Mode = 'show_fields'; Key = 'urgent'; UserId = 81; LockLayer = 4
            Fields = @('Headline.Text'); Labels = @('العنوان'); Limits = @(80)
            Required = @($true); Index = 0; Values = @{ 'Headline.Text' = 'مسودة' }
            AutoHideSeconds = 0
        }
        $script:PendingState.Clear()
        $script:LayerLocks.Clear()

        Import-DraftStates

        $state = Get-PendingState -ChatId 71
        $state.Values['Headline.Text'] | Should -Be 'مسودة'
        $script:LayerLocks[4].UserId | Should -Be 81
    }

    It 'removes a saved draft when the operator cancels it' {
        Set-PendingState -ChatId 72 -State @{
            Mode = 'show_review'; Key = 'urgent'; UserId = 82; LockLayer = 5
            Fields = @(); Labels = @(); Limits = @(); Required = @()
            Index = 0; Values = @{}; AutoHideSeconds = 0
        }

        Clear-PendingState -ChatId 72
        $saved = @(Get-Content -LiteralPath $script:draftsFile -Raw | ConvertFrom-Json)

        $saved.Count | Should -Be 0
    }
}

Describe 'Recent field values' {
    BeforeEach {
        $script:OriginalRecentValuesFileForTest = $script:recentValuesFile
        $script:recentValuesFile = Join-Path $TestDrive 'recent-values.json'
        $script:RecentFieldValues.Clear()
        Mock Get-SettingInt {
            if ($Name -eq 'RecentValuesPerField') { return 2 }
            return 1
        }
        Mock Write-BridgeLog { }
    }

    AfterEach {
        $script:RecentFieldValues.Clear()
        $script:recentValuesFile = $script:OriginalRecentValuesFileForTest
    }

    It 'keeps unique newest values per user and field and restores them from disk' {
        Add-RecentFieldValue -UserId 81 -FieldName 'Headline.Text' -Value 'الأول'
        Add-RecentFieldValue -UserId 81 -FieldName 'Headline.Text' -Value 'الثاني'
        Add-RecentFieldValue -UserId 81 -FieldName 'Headline.Text' -Value 'الأول'
        Add-RecentFieldValue -UserId 81 -FieldName 'Headline.Text' -Value 'الثالث'

        Get-RecentFieldValues -UserId 81 -FieldName 'Headline.Text' | Should -Be @('الثالث', 'الأول')
        $script:RecentFieldValues.Clear()
        Import-RecentFieldValues
        Get-RecentFieldValues -UserId 81 -FieldName 'Headline.Text' | Should -Be @('الثالث', 'الأول')
    }

    It 'never stores explicitly sensitive values or secret-like field names' {
        Add-RecentFieldValue -UserId 81 -FieldName 'Caption.Text' -Value 'سر' -Sensitive
        Add-RecentFieldValue -UserId 81 -FieldName 'BotToken' -Value '123:ABC'

        $script:RecentFieldValues.Count | Should -Be 0
    }

    It 'shows recent values as indexed quick choices without putting text in callback data' {
        Add-RecentFieldValue -UserId 81 -FieldName 'Headline.Text' -Value 'خبر سابق'
        $state = @{
            UserId = 81; Index = 0; Fields = @('Headline.Text'); Values = @{}
            Sensitives = @($false)
        }

        $keyboard = Get-FieldPromptKeyboard -State $state
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_ })

        @($buttons.text) | Should -Contain '🕘 خبر سابق'
        @($buttons.callback_data) | Should -Contain 'recent:0'
        (@($buttons.callback_data) -join '|') | Should -Not -Match 'خبر سابق'
    }
}

Describe 'Repeat last show with editing' {
    BeforeEach {
        $script:LayerLocks.Clear()
        Clear-PendingState -ChatId 90
        Mock Get-TemplateStore {
            [pscustomobject]@{
                Map = @{ urgent = [pscustomobject]@{ Layer = 4; Path = 'D:\CG\urgent.cintitle'; FieldTypes = @{} } }
            }
        }
        Mock Show-TitlerTemplate {
            [pscustomobject]@{ Success = $true; EventId = '{CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC}'; Xml = '<Request/>' }
        }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = ''; Error = '' }
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(4); Added = @(); Removed = @(); Failed = @(); LastSuccessfulAt = Get-Date }
        }
        Mock Save-OnAirState { }
        Mock Add-UsageCount { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Get-AfterShowKeyboard { @{ inline_keyboard = @() } }
        Mock Send-TelegramMessage { }
        Invoke-ShowTemplateResult -Key 'urgent' -Variables @{ 'Headline.Text' = 'الخبر السابق' } -ChatId 90 -UserId 90
        $PostShowQueue.Clear()
        $OnAir.Clear()
        Mock Get-TemplateIndex { 0 }
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'; Layer = 4
                Fields = @('Headline.Text')
                FieldLabels = @('العنوان')
                FieldLimits = @(80)
                FieldRequired = @($true)
            }
        }
        Mock Invoke-ShowTemplateResult { }
    }

    AfterEach {
        Clear-PendingState -ChatId 90
        $script:LayerLocks.Clear()
    }

    It 'opens the previous values for editing instead of immediately resending them' {
        Invoke-RepeatLastShow -ChatId 90 -UserId 90

        Should -Invoke Get-TemplateIndex -Times 1 -Exactly
        Should -Invoke Get-TemplateByIndex -Times 1 -Exactly
        $state = Get-PendingState -ChatId 90
        $state | Should -Not -BeNullOrEmpty
        $state.Mode | Should -Be 'show_fields'
        $state.Values['Headline.Text'] | Should -Be 'الخبر السابق'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
}

Describe 'Template test layer safety' {
    It 'reports no conflict when testing is disabled' {
        Get-TemplateTestLayerConflict -Layer 0 | Should -BeNullOrEmpty
    }

    It 'names the production templates already occupying a candidate layer' {
        Mock Get-TemplateStore {
            @{ Map = @{ 'lower-third' = @{ Layer = 3 }; 'ticker' = @{ Layer = 8 }; 'bug' = @{ Layer = 3 } }; Order = @(); Errors = @() }
        }

        $conflict = @(Get-TemplateTestLayerConflict -Layer 3)

        $conflict | Should -Be @('bug', 'lower-third')
    }

    It 'reports a free layer as safe to test on' {
        Mock Get-TemplateStore {
            @{ Map = @{ 'lower-third' = @{ Layer = 3 } }; Order = @(); Errors = @() }
        }

        Get-TemplateTestLayerConflict -Layer 9 | Should -BeNullOrEmpty
    }

    It 'refuses to point the test layer at a production layer' {
        # Without this the "safe" test push goes out on the same layer as
        # programme graphics, which is what the setting exists to prevent.
        Mock Get-TemplateStore {
            @{ Map = @{ 'lower-third' = @{ Layer = 3 } }; Order = @(); Errors = @() }
        }
        Mock Set-Setting {}
        Mock Send-TelegramMessage {}
        Mock Get-SettingsKeyboard { @{ inline_keyboard = @() } }
        Set-PendingState -ChatId 100 -State @{ Mode = 'setting_value'; Name = 'TemplateTestLayer'; UserId = 100 }

        Complete-SettingValue -ChatId 100 -Value '3'

        Should -Invoke Set-Setting -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'lower-third' }
    }

    It 'accepts a free layer through the same path' {
        Mock Get-TemplateStore {
            @{ Map = @{ 'lower-third' = @{ Layer = 3 } }; Order = @(); Errors = @() }
        }
        Mock Set-Setting {}
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Get-SettingsKeyboard { @{ inline_keyboard = @() } }
        Set-PendingState -ChatId 100 -State @{ Mode = 'setting_value'; Name = 'TemplateTestLayer'; UserId = 100 }

        Complete-SettingValue -ChatId 100 -Value '9'

        Should -Invoke Set-Setting -Times 1 -Exactly -ParameterFilter { $Name -eq 'TemplateTestLayer' -and $Value -eq 9 }
    }
}

Describe 'Template scene paths' {
    BeforeEach { Mock Get-Setting { '' } -ParameterFilter { $Name -eq 'TemplateBasePath' } }

    It 'accepts a UNC share, which is how a shared scenes folder is reached' {
        Resolve-TemplateScenePath -Path '\\nas01\scenes\Lower3rd.cintitle' | Should -Be '\\nas01\scenes\Lower3rd.cintitle'
    }

    It 'expands an environment variable before deciding the path is relative' {
        # The check ran before expansion, and a path starting with '%' is not
        # rooted - so %PROGRAMDATA% templates were rejected outright.
        Resolve-TemplateScenePath -Path '%PROGRAMDATA%\Cinegy\A.cintitle' |
            Should -Be ([Environment]::ExpandEnvironmentVariables('%PROGRAMDATA%\Cinegy\A.cintitle'))
    }

    It 'resolves a bare file name against the scenes folder' {
        Mock Get-Setting { 'D:\Scenes' } -ParameterFilter { $Name -eq 'TemplateBasePath' }

        Resolve-TemplateScenePath -Path 'Lower3rd.cintitle' | Should -Be 'D:\Scenes\Lower3rd.cintitle'
    }

    It 'leaves an absolute path alone even when a base folder is set' {
        Mock Get-Setting { 'D:\Scenes' } -ParameterFilter { $Name -eq 'TemplateBasePath' }

        Resolve-TemplateScenePath -Path 'C:\Cinegy\A.cintitle' | Should -Be 'C:\Cinegy\A.cintitle'
    }

    It 'still refuses a relative path when no base folder is configured' {
        # Guessing from the working directory would resolve differently for a
        # service and for a console, which is worse than refusing.
        Resolve-TemplateScenePath -Path 'Lower3rd.cintitle' | Should -Be 'Lower3rd.cintitle'
        [IO.Path]::IsPathRooted((Resolve-TemplateScenePath -Path 'Lower3rd.cintitle')) | Should -BeFalse
    }

    It 'ignores a base folder that is itself relative' {
        Mock Get-Setting { 'Scenes' } -ParameterFilter { $Name -eq 'TemplateBasePath' }

        Resolve-TemplateScenePath -Path 'A.cintitle' | Should -Be 'A.cintitle'
    }
}

Describe 'Template button labels' {
    BeforeEach {
        $script:LayerLocks = @{}
        $script:OnAir = @{}
        Mock Get-TemplateStore {
            @{
                Order = @('News-Ticker')
                Map   = @{ 'News-Ticker' = [pscustomobject]@{
                        Key         = 'News-Ticker'; Layer = 8; Category = 'أخبار'
                        Description = 'شريط الأخبار'; Fields = @('text'); Device = ''; Presets = @()
                    }
                }
            }
        }
        $script:TemplateUsage = @{ 'News-Ticker' = @{ Count = 4; LastUsed = (Get-Date).ToUniversalTime().ToString('o') } }
    }

    It 'carries the name alone, with no layer number or timestamp' {
        # Reported as "random text and numbers in the button names": the label
        # used to append the layer and the last-used time, which overran
        # ButtonTextMaxLength and cut the date mid-way - "News-Ticker (طبقة 8)
        # . 08-25..." reads as noise, not as information.
        $keyboard = Get-TemplatesKeyboard -Prefix 'tpl'
        $label = $keyboard.inline_keyboard[0][0].text

        $label | Should -Be 'News-Ticker'
        $label | Should -Not -Match '\d'
    }

    It 'moves the detail onto the preview screen, where there is room' {
        $preview = Get-TemplatePreviewText -Template (Get-TemplateStore).Map['News-Ticker']

        $preview | Should -Match 'طبقة'
        $preview | Should -Match 'أخبار'
        $preview | Should -Match 'شريط الأخبار'
    }
}

Describe 'Shared-layer templates' {
    BeforeEach {
        Mock Get-TemplateStore {
            @{ Order = @('logo', 'News-Ticker'); Errors = @(); InvalidKeys = @()
                Map = @{ logo = @{ Key = 'logo'; Layer = 8 }; 'News-Ticker' = @{ Key = 'News-Ticker'; Layer = 8 } }
                SharedLayers = @{ '8' = @('News-Ticker', 'logo') } }
        }
        Mock Get-UserDisplayName { 'أحمد' }
    }

    It 'warns at review that a shared layer cannot carry both templates' {
        # A Cinegy GFX layer holds one scene. logo and News-Ticker both sit on
        # layer 8, so showing either silently evicts the other - the operator
        # has to know that before confirming, not after.
        $state = @{ Key = 'logo'; LockLayer = 8; Fields = @(); Values = @{}; AutoHideSeconds = 0 }
        $text = Format-ShowReviewText -State $state
        $text | Should -Match 'News-Ticker'
        $text | Should -Match 'لا يمكن عرضها'
    }

    It 'does not name the template against itself' {
        $state = @{ Key = 'logo'; LockLayer = 8; Fields = @(); Values = @{}; AutoHideSeconds = 0 }
        $text = Format-ShowReviewText -State $state
        ([regex]::Matches($text, 'logo')).Count | Should -Be 1
    }

    It 'stays silent for a layer only one template uses' {
        Mock Get-TemplateStore {
            @{ Order = @('Urgent'); Errors = @(); InvalidKeys = @()
                Map = @{ Urgent = @{ Key = 'Urgent'; Layer = 7 } }; SharedLayers = @{} }
        }
        $state = @{ Key = 'Urgent'; LockLayer = 7; Fields = @(); Values = @{}; AutoHideSeconds = 0 }
        Format-ShowReviewText -State $state | Should -Not -Match 'يتشاركها'
    }

    It 'lets templates on different layers be on air together' {
        # The capability exists and is per layer: what cannot happen is two
        # templates on the SAME layer, which is a Cinegy constraint.
        $script:OnAir = @{}
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }
        $script:OnAir[8] = @{ Key = 'News-Ticker'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        $script:OnAir.Count | Should -Be 2
        (Get-OnAirShareText) | Should -Match 'Urgent'
        (Get-OnAirShareText) | Should -Match 'News-Ticker'
        $script:OnAir = @{}
    }
}

Describe 'Template device field' {
    It 'reads a device name and registers it for its layer' {
        Mock Get-JsonProp { 'logo' } -ParameterFilter { $Name -eq 'device' }
        # The store maps layer -> device so every existing Cinegy call keeps
        # passing a plain number.
        $store = Get-TemplateStore
        $store | Should -Not -BeNullOrEmpty
    }
}
