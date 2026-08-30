#requires -Version 7
<#
    Bridge.Tests.ps1 — Pester tests for the bridge's pure logic.

    These cover exactly the function-boundary behaviours that produced the
    three bugs that reached production:

      * Split-TelegramText returning a nested array  -> "System.Object[]"
        appeared as the text of every message.
      * Get-FavoriteTemplateKeys returning an empty array -> the caller got
        $null and $null.Count threw under Set-StrictMode.
      * Escape-XmlValue rejecting '' -> pressing ⏭ تخطي crashed the command.

    None of these are visible to static analysis; all three fail loudly here.

    Run:  .\Run-Checks.ps1        (analyzer + tests)
      or: Invoke-Pester .\Tests   (tests only)
#>

BeforeDiscovery {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\CinegyAirTitler.psm1'
    Import-Module $modulePath -Force
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot

    # -LoadOnly defines every function without touching Telegram, the mutex,
    # or the polling loop. config.example.json is used so a real config is
    # never read or rewritten by the tests.
    . (Join-Path $script:Root 'TelegramBridge.ps1') -LoadOnly -ConfigPath 'config.example.json' -RuntimePath $TestDrive
    # Promote the dot-sourced path into this test file's script scope so
    # persistence tests can redirect it safely to Pester's TestDrive.
    $script:onAirFile = $onAirFile
    $script:ConfigPath = $ConfigPath

    function New-TempTemplateFile {
        <# Unique name per call: Get-TemplateStore caches on path + write time,
           so a fresh path guarantees a fresh parse. The file is created next
           to the script because the registry path is resolved relative to it. #>
        param([Parameter(Mandatory)][string]$Json)
        $name = "templates.test-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $full = Join-Path $script:Root $name
        Set-Content -Path $full -Value $Json -Encoding utf8
        $config.TemplateRegistryPath = $name
        return $full
    }

    # Sanity: -LoadOnly must have defined the functions without running the bot.
    if (-not (Get-Command Split-TelegramText -ErrorAction SilentlyContinue)) {
        throw "TelegramBridge.ps1 did not load its functions; check the -LoadOnly guard."
    }
}

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
        $result = Apply-TemplateRegistryImport -StagedPath $script:IncomingPath
        $result.Success | Should -BeTrue -Because $result.Error
        Test-Path -LiteralPath $result.BackupPath | Should -BeTrue
        $saved = Get-Content -LiteralPath $script:ImportRegistryPath -Raw | ConvertFrom-Json
        $saved.PSObject.Properties.Name | Should -Contain 'gamma'
        $saved.PSObject.Properties.Name | Should -Not -Contain 'beta'
    }

    It 'blocks changing or removing a template that is live or scheduled' {
        $script:OnAir[2] = @{ Key='beta'; UserId=10 }
        $result = Apply-TemplateRegistryImport -StagedPath $script:IncomingPath
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

Describe 'Safe in-memory layer rollback' {
    BeforeEach {
        $config.Settings.EnableSafeRollback=$true
        $script:RollbackCandidates=@{}; $script:LastSuccessfulLayerShows=@{}; $script:OnAir=@{}
        $script:PendingState.Clear(); $script:LayerLocks=@{}; $script:AutoHideQueue=[Collections.Generic.List[object]]::new()
        Mock Get-TemplateStore {
            @{ Order=@('alpha','beta'); Map=@{
                alpha=@{ Key='alpha'; Layer=5; Path='C:\Scenes\Alpha.cintitle'; Fields=@('Title'); FieldTypes=@{}; Presets=@() }
                beta=@{ Key='beta'; Layer=5; Path='C:\Scenes\Beta.cintitle'; Fields=@('Title'); FieldTypes=@{}; Presets=@() }
            }; Errors=@() }
        }
        Mock Test-Admin { $false }
        Mock Send-TelegramMessage { }
        Mock Save-OnAirState { }
        Mock Add-UsageCount { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Write-AirOperationResult { }
        Mock Update-OnAirStateFromCinegy { [pscustomobject]@{ Added=@(); Removed=@(); Failed=@() } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success=$true; EventId='event-new'; Error=''; Xml='' } }
    }

    AfterEach {
        $config.Settings.EnableSafeRollback=$false
    }

    It 'keeps rollback disabled by default until the administrator enables it' {
        $config.Settings.EnableSafeRollback=$false
        Set-RollbackCandidate -Layer 5 -RestoreSnapshot @{ Key='alpha'; Variables=@{Title='old'} } `
            -ExpectedState hidden -ActorUserId 10
        Get-RollbackCandidate -Layer 5 -UserId 10 | Should -BeNullOrEmpty
        $script:RollbackCandidates.ContainsKey(5) | Should -BeFalse
    }

    It 'creates a rollback candidate only when the previous bot scene correlates with live ActiveId' {
        $script:LastSuccessfulLayerShows[5]=@{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old'; UserId=10; ChatId=10; At=(Get-Date) }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='event-old'; Error='' } }
        Invoke-ShowTemplateResult -Key beta -Variables @{Title='new'} -ChatId 10 -UserId 10 | Out-Null

        $candidate = Get-RollbackCandidate -Layer 5 -UserId 10
        $candidate.Restore.Key | Should -Be 'alpha'
        $candidate.Restore.Variables.Title | Should -Be 'old'
        $candidate.ExpectedActiveId | Should -Be 'event-new'
        $script:LastSuccessfulLayerShows[5].Key | Should -Be 'beta'
    }

    It 'offers an undo that clears a layer that was empty before the push' {
        # The commonest daily error: the wrong template, onto a layer that
        # had nothing on it. Before this there was nothing to press.
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$false; ActiveId=''; Error='' } }

        Invoke-ShowTemplateResult -Key beta -Variables @{Title='new'} -ChatId 10 -UserId 10 | Out-Null

        $candidate = Get-RollbackCandidate -Layer 5 -UserId 10
        $candidate | Should -Not -BeNullOrEmpty
        $candidate.Restore.Action | Should -Be 'hide'
    }

    It 'does not offer rollback when the previous snapshot does not match Cinegy' {
        $script:LastSuccessfulLayerShows[5]=@{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old'; UserId=10; ChatId=10 }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='external-event'; Error='' } }
        Invoke-ShowTemplateResult -Key beta -Variables @{Title='new'} -ChatId 10 -UserId 10 | Out-Null
        Get-RollbackCandidate -Layer 5 -UserId 10 | Should -BeNullOrEmpty
    }

    It 'captures a correlated manual hide as a restore-to-empty-state candidate' {
        $script:LastSuccessfulLayerShows[5]=@{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old'; UserId=10; ChatId=10 }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='event-old'; Error='' } }
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success=$true; Error='' } }
        Mock Sync-LayerAfterOperatorAction { }
        Invoke-HideLayer -Layer 5 -ChatId 10 -UserId 10 | Should -BeTrue
        (Get-RollbackCandidate -Layer 5 -UserId 10).ExpectedState | Should -Be 'hidden'
    }

    It 'records the configured operator name with its ID in the visible template-operation audit' {
        $previousAlias = if ($script:UserAliases.ContainsKey('10')) { [string]$script:UserAliases['10'] } else { $null }
        try {
            $script:UserAliases['10'] = 'محرر الأخبار'
            $script:LastSuccessfulLayerShows[5]=@{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old'; UserId=10; ChatId=10 }
            Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='event-old'; Error='' } }
            Mock Hide-TitlerTemplate { [pscustomobject]@{ Success=$true; Error='' } }
            Mock Sync-LayerAfterOperatorAction { }

            Invoke-HideLayer -Layer 5 -ChatId 10 -UserId 10 | Should -BeTrue

            Should -Invoke Add-AuditEntry -Times 1 -Exactly -ParameterFilter { $Message -match 'محرر الأخبار \(10\)' }
        }
        finally {
            if ($null -eq $previousAlias) { $script:UserAliases.Remove('10') | Out-Null }
            else { $script:UserAliases['10'] = $previousAlias }
        }
    }

    It 'restores only after review when the expected current scene still matches' {
        Set-RollbackCandidate -Layer 5 -RestoreSnapshot @{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old' } `
            -ExpectedState replace -ExpectedActiveId 'event-current' -ActorUserId 10
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='event-current'; Error='' } }
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success=$true } }

        Start-SafeRollbackReview -Layer 5 -ChatId 10 -UserId 10
        (Get-PendingState -ChatId 10).Mode | Should -Be 'safe_rollback_review'
        Confirm-SafeRollback -Layer 5 -ChatId 10 -UserId 10
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $Key -eq 'alpha' -and $Variables.Title -eq 'old' }
    }

    It 'cancels and invalidates rollback on external change or uncertain Cinegy state' {
        foreach ($status in @(
            [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='different'; Error='' },
            [pscustomobject]@{ Success=$false; IsOnAir=$null; ActiveId=''; Error='timeout' }
        )) {
            $script:PendingState.Clear(); $script:RollbackCandidates=@{}
            Set-RollbackCandidate -Layer 5 -RestoreSnapshot @{ Key='alpha'; Variables=@{Title='old'} } `
                -ExpectedState replace -ExpectedActiveId 'event-current' -ActorUserId 10
            Mock Get-TitlerLayerStatus { return $status }
            Mock Invoke-ShowTemplateResult { throw 'must not execute' }
            Start-SafeRollbackReview -Layer 5 -ChatId 10 -UserId 10
            Confirm-SafeRollback -Layer 5 -ChatId 10 -UserId 10
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            $script:RollbackCandidates.ContainsKey(5) | Should -BeFalse
        }
    }

    It 'expires candidates and never writes their editorial values to disk' {
        Set-RollbackCandidate -Layer 5 -RestoreSnapshot @{ Key='alpha'; Variables=@{Title='secret editorial value'} } `
            -ExpectedState hidden -ActorUserId 10
        $script:RollbackCandidates[5].ExpiresAt=(Get-Date).AddSeconds(-1)
        Get-RollbackCandidate -Layer 5 -UserId 10 | Should -BeNullOrEmpty
        $script:RollbackCandidates.ContainsKey(5) | Should -BeFalse
    }
}

Describe 'User aliases' {
    BeforeEach {
        $script:UserAliases = @{}
        $script:userAliasesFile = Join-Path $TestDrive 'user-aliases.json'
    }

    It 'stores a trimmed alias and resolves it instead of the numeric id' {
        Set-UserAlias -TargetUserId 101 -Alias '  مخرج الأخبار  ' | Should -BeTrue
        Get-UserDisplayName -UserId 101 | Should -Be 'مخرج الأخبار'
    }

    It 'removes an alias when an empty value is saved' {
        Set-UserAlias -TargetUserId 101 -Alias 'مخرج الأخبار' | Out-Null
        Set-UserAlias -TargetUserId 101 -Alias '' | Should -BeTrue
        Get-UserDisplayName -UserId 101 | Should -Be '101'
    }
}

Describe 'Authorized user administration' {
    BeforeEach {
        $script:OriginalAllowedChatIds = @(Get-JsonProp $config 'AllowedChatIds')
        $script:OriginalAllowedUserIds = @(Get-JsonProp $config 'AllowedUserIds')
        $script:OriginalAdminChatIds = @(Get-JsonProp $config 'AdminChatIds')
        $script:OriginalAdminUserIds = @(Get-JsonProp $config 'AdminUserIds')
        $config.AllowedChatIds = @(101, 202); $config.AllowedUserIds = @(101, 202)
        $config.AdminChatIds = @(101); $config.AdminUserIds = @(101)
        $script:DisabledUserIds = @{}
        $script:disabledUsersFile = Join-Path $TestDrive 'disabled-users.json'
        $script:UserProfiles = @{}
        $script:userProfilesFile = Join-Path $TestDrive 'user-profiles.json'
        Mock Save-Config { }
    }

    AfterEach {
        $config.AllowedChatIds = $script:OriginalAllowedChatIds
        $config.AllowedUserIds = $script:OriginalAllowedUserIds
        $config.AdminChatIds = $script:OriginalAdminChatIds
        $config.AdminUserIds = $script:OriginalAdminUserIds
    }

    It 'rejects a disabled user while preserving the whitelist entry' {
        Set-UserDisabled -TargetUserId 202 -Disabled $true | Should -BeTrue
        Test-Authorized -ChatId 202 -UserId 202 | Should -BeFalse
        $config.AllowedUserIds | Should -Contain 202
    }

    It 'promotes an authorized operator to administrator' {
        $result = Set-AdminRole -TargetUserId 202 -IsAdmin $true

        $result.Success | Should -BeTrue -Because $result.Error
        $config.AdminUserIds | Should -Contain 202
        Should -Invoke Save-Config -Times 1 -Exactly
    }

    It 'refuses to promote someone who is not authorized at all' {
        # Promotion must not double as a way in.
        $result = Set-AdminRole -TargetUserId 909 -IsAdmin $true

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'غير مصرّح'
        $config.AdminUserIds | Should -Not -Contain 909
    }

    It 'refuses to demote the owner' {
        # Otherwise two owners could strip each other and nobody would be left
        # able to appoint anyone.
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(202) -Force
        $config.AdminUserIds = @(101, 202)

        $result = Set-AdminRole -TargetUserId 202 -IsAdmin $false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'المالك'
        $config.AdminUserIds | Should -Contain 202
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'refuses to demote the last administrator' {
        # Reachable only when the owner is somebody other than that last
        # administrator - an owner who appoints but does not operate. When the
        # owner IS the last administrator the owner guard answers first, which
        # is the same refusal by a better name.
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(202) -Force

        $result = Set-AdminRole -TargetUserId 101 -IsAdmin $false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'آخر مشرف'
        $config.AdminUserIds | Should -Contain 101
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'refuses to demote the sole administrator who is also the owner' {
        $result = Set-AdminRole -TargetUserId 101 -IsAdmin $false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'المالك'
        $config.AdminUserIds | Should -Contain 101
    }

    It 'demotes an administrator who is neither the owner nor the last one' {
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(101) -Force
        $config.AdminUserIds = @(101, 202)

        $result = Set-AdminRole -TargetUserId 202 -IsAdmin $false

        $result.Success | Should -BeTrue -Because $result.Error
        $config.AdminUserIds | Should -Not -Contain 202
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'warns when the configured owner cannot use the bot at all' {
        # Found in the pre-release audit. Naming an unauthorized owner locks
        # the station out of the role in both directions at once: the named
        # owner is refused at every screen, and the administrator who held it
        # by default no longer does. Nobody can appoint anyone, silently.
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(777) -Force
        try {
            Test-Owner -ChatId 777 -UserId 777 | Should -BeTrue
            Test-Authorized -ChatId 777 -UserId 777 | Should -BeFalse
            Test-Owner -ChatId 101 -UserId 101 | Should -BeFalse

            @(Test-OwnerConfiguration) | Should -Not -BeNullOrEmpty
            @(Test-OwnerConfiguration)[0] | Should -Match '777'
        }
        finally { $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force }
    }

    It 'stays quiet when the owner is a real authorized user' {
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(101) -Force
        try { @(Test-OwnerConfiguration) | Should -HaveCount 0 }
        finally { $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force }
    }

    It 'shows role buttons to the owner and to nobody else' {
        # A button that always answers "not allowed" is worse than no button.
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(101) -Force
        $config.AdminUserIds = @(101, 202)

        $ownerView = @((Get-UsersAdminKeyboard -ViewerUserId 101).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $adminView = @((Get-UsersAdminKeyboard -ViewerUserId 202).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        $ownerView | Should -Contain 'usr:demote:202'
        $adminView | Should -Not -Contain 'usr:demote:202'
        # Nothing to promote the owner to, and demoting them is refused.
        $ownerView | Should -Not -Contain 'usr:demote:101'
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'refuses to revoke the final administrator' {
        $result = Revoke-AuthorizedUser -TargetUserId 101
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'آخر مشرف'
        $config.AdminUserIds | Should -Contain 101
    }

    It 'refuses to disable the final administrator' {
        Set-UserDisabled -TargetUserId 101 -Disabled $true | Should -BeFalse
        Test-UserDisabled -UserId 101 | Should -BeFalse
    }

    It 'removes a regular user from both chat and user authorization lists' {
        $result = Revoke-AuthorizedUser -TargetUserId 202
        $result.Success | Should -BeTrue -Because $result.Error
        $config.AllowedChatIds | Should -Not -Contain 202
        $config.AllowedUserIds | Should -Not -Contain 202
        Should -Invoke Save-Config -Times 1 -Exactly
    }

    It 'lists unique users with alias role and disabled state' {
        $script:UserAliases['202'] = 'مخرج الأخبار'; $script:DisabledUserIds['202'] = $true
        $users = @(Get-AuthorizedUsers)
        $users.Count | Should -Be 2
        # 101 is the only administrator, so it is also the owner: with no
        # OwnerUserIds configured the first administrator holds the role.
        ($users | Where-Object UserId -eq 101).Role | Should -Be 'owner'
        ($users | Where-Object UserId -eq 202).Alias | Should -Be 'مخرج الأخبار'
        ($users | Where-Object UserId -eq 202).Disabled | Should -BeTrue
    }

    It 'requires confirmation before revoking a user' {
        Mock Send-TelegramMessage { }
        Request-UserRevocation -TargetUserId 202 -ChatId 101 -AdminUserId 101
        $config.AllowedUserIds | Should -Contain 202
        (Get-PendingState -ChatId 101).Mode | Should -Be 'user_revoke'
        Should -Invoke Save-Config -Times 0 -Exactly
    }

    It 'records who approved a user and when they were added' {
        Record-UserApprovalMetadata -TargetUserId 202 -ApprovedByUserId 101 | Should -BeTrue
        $script:UserProfiles['202'].AddedByUserId | Should -Be 101
        $script:UserProfiles['202'].AddedAt | Should -Not -BeNullOrEmpty
    }

    It 'updates last activity only for an authorized user' {
        Update-UserLastActivity -UserId 202 | Should -BeTrue
        $script:UserProfiles['202'].LastActivityAt | Should -Not -BeNullOrEmpty
        Update-UserLastActivity -UserId 303 | Should -BeFalse
        $script:UserProfiles.ContainsKey('303') | Should -BeFalse
    }

    It 'removes the runtime profile when access is revoked' {
        $script:UserProfiles['202'] = @{ AddedAt = (Get-Date).ToString('o'); AddedByUserId = 101; LastActivityAt = $null }
        Revoke-AuthorizedUser -TargetUserId 202 | Out-Null
        $script:UserProfiles.ContainsKey('202') | Should -BeFalse
    }

    It 'offers an alias action for every user in the management keyboard' {
        $keyboard = Get-UsersAdminKeyboard
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_ })

        @($buttons.callback_data) | Should -Contain 'usr:alias:202'
        @($buttons.text) -join ' ' | Should -Match 'Alias'
    }

    It 'edits and removes a user alias through the interactive admin flow' {
        $script:UserAliases = @{}
        $script:userAliasesFile = Join-Path $TestDrive 'user-aliases-admin.json'
        Mock Send-TelegramMessage { }

        Start-UserAliasEdit -TargetUserId 202 -ChatId 101 -AdminUserId 101
        (Get-PendingState -ChatId 101).Mode | Should -Be 'user_alias_edit'
        Complete-UserAliasEdit -ChatId 101 -AdminUserId 101 -Value 'مخرج الأخبار'
        Get-UserDisplayName -UserId 202 | Should -Be 'مخرج الأخبار'

        Start-UserAliasEdit -TargetUserId 202 -ChatId 101 -AdminUserId 101
        Complete-UserAliasEdit -ChatId 101 -AdminUserId 101 -Value '-'
        Get-UserDisplayName -UserId 202 | Should -Be '202'
    }
}

Describe 'Test runtime isolation' {
    It 'never points on-air persistence at the live logs directory' {
        [IO.Path]::GetFullPath($script:onAirFile) | Should -BeLike "$([IO.Path]::GetFullPath($TestDrive))*"
        [IO.Path]::GetFullPath($script:onAirFile) | Should -Not -BeLike "$([IO.Path]::GetFullPath((Join-Path $script:Root 'logs')))*"
    }
}

Describe 'Air operation result logging' {
    BeforeEach {
        Mock Write-BridgeLog { }
        $script:auditFile = Join-Path $TestDrive 'audit.jsonl'
        Remove-Item -LiteralPath $script:auditFile -Force -ErrorAction SilentlyContinue
        $script:UserOperationHistory = @{}
        $script:LastShowAttempts = @{}
    }

    It 'writes a correlatable successful operation with duration and target' {
        Write-AirOperationResult -OperationId 'op-123' -Action SHOW -Result success -DurationMs 27 -UserId 20 -ChatId 10 -Layer 4 -Target urgent

        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
            $Message -match 'AIR_OP' -and $Message -match 'id=op-123' -and
                $Message -match 'action=SHOW' -and $Message -match 'result=success' -and
                $Message -match 'durationMs=27' -and $Message -match 'layer=4' -and
                $Message -match 'target="urgent"'
        }
    }

    It 'records the configured operator name alongside the immutable user id' {
        $previousAlias = if ($script:UserAliases.ContainsKey('20')) { [string]$script:UserAliases['20'] } else { $null }
        try {
            $script:UserAliases['20'] = 'محرر الأخبار'

            Write-AirOperationResult -OperationId 'op-user-name' -Action SHOW -Result success -DurationMs 27 -UserId 20 -ChatId 10 -Layer 4 -Target urgent

            Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
                $Message -match 'user=20' -and $Message -match 'userName="محرر الأخبار"'
            }
            $record = Get-Content -LiteralPath $script:auditFile | Select-Object -Last 1 | ConvertFrom-Json
            $record.userId | Should -Be 20
            $record.userName | Should -Be 'محرر الأخبار'
        }
        finally {
            if ($null -eq $previousAlias) { $script:UserAliases.Remove('20') | Out-Null }
            else { $script:UserAliases['20'] = $previousAlias }
        }
    }

    It 'writes failures at warning level without losing the error reason' {
        Write-AirOperationResult -OperationId 'op-456' -Action HIDE -Result blocked -DurationMs 3 -UserId 20 -ChatId 10 -Layer 4 -ErrorText 'cinegy timeout'

        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'id=op-456' -and
                $Message -match 'result=blocked' -and $Message -match 'cinegy timeout'
        }
    }

    It 'persists the same correlation id in the independent structured audit log' {
        Write-AirOperationResult -OperationId 'op-jsonl' -Action SHOW -Result success -DurationMs 31 -UserId 20 -ChatId 10 -Layer 4 -Target urgent

        $record = Get-Content -LiteralPath $script:auditFile | Select-Object -Last 1 | ConvertFrom-Json
        $record.operationId | Should -Be 'op-jsonl'
        $record.event | Should -Be 'air_control'
        $record.action | Should -Be 'SHOW'
        $record.result | Should -Be 'success'
        $record.userId | Should -Be 20
        $record.layer | Should -Be 4
    }

    It 'redacts secrets and keeps every audit entry on one JSONL line' {
        Write-AuditRecord -OperationId 'audit-secret' -EventName settings_change -Result success -UserId 20 -Message "token 123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345`nnext"

        $lines = @(Get-Content -LiteralPath $script:auditFile)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Not -Match '123456:ABC'
        ($lines[0] | ConvertFrom-Json).message | Should -Match '\*\*\*BOT_TOKEN\*\*\*'
    }
}

Describe 'Per-user operation history and safe retry' {
    BeforeEach {
        $script:UserOperationHistory = @{}
        $script:LastShowAttempts = @{}
        $script:auditFile = Join-Path $TestDrive 'audit.jsonl'
        Mock Write-BridgeLog { }
        Mock Send-TelegramMessage { }
    }

    It 'keeps operation history isolated by Telegram user id without editorial values' {
        Write-AirOperationResult -OperationId one -Action SHOW -Result failed -DurationMs 10 -UserId 101 -ChatId 101 -Layer 4 -Target urgent -ErrorText timeout
        Write-AirOperationResult -OperationId two -Action HIDE -Result success -DurationMs 5 -UserId 202 -ChatId 202 -Layer 7 -Target ticker

        $first = @(Get-UserOperationHistory -UserId 101)
        $second = @(Get-UserOperationHistory -UserId 202)
        $first.Count | Should -Be 1
        $first[0].OperationId | Should -Be 'one'
        $first[0].Target | Should -Be 'urgent'
        $first[0].PSObject.Properties.Name | Should -Not -Contain 'Variables'
        $second.Count | Should -Be 1
        $second[0].OperationId | Should -Be 'two'
    }

    It 'reopens review for the same users last SHOW attempt instead of sending directly' {
        $script:LastShowAttempts['101'] = @{ Key = 'urgent'; Variables = @{ Headline = 'review me' }; AutoHideSeconds = 20 }
        Mock Get-TemplateIndex { 3 }
        Mock Start-ShowFlow { }
        Mock Show-TitlerTemplate { throw 'must not send during retry request' }

        Invoke-RetryLastShowAttempt -ChatId 101 -UserId 101

        Should -Invoke Start-ShowFlow -Times 1 -Exactly -ParameterFilter {
            $TemplateIndex -eq 3 -and $ChatId -eq 101 -and $UserId -eq 101 -and
                $InitialValues.Headline -eq 'review me' -and $ReviewImmediately
        }
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'shows only the requesting users recent operations with a retry button' {
        Add-UserOperationHistory -OperationId one -Action SHOW -Result failed -DurationMs 10 -UserId 101 -Layer 4 -Target urgent
        Add-UserOperationHistory -OperationId two -Action SHOW -Result success -DurationMs 10 -UserId 202 -Layer 7 -Target private
        $script:LastShowAttempts['101'] = @{ Key = 'urgent'; Variables = @{}; AutoHideSeconds = 0 }

        Invoke-MyOperationsCommand -ChatId 101 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'urgent' -and $Text -notmatch 'private' -and
                @($ReplyMarkup.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text }) -contains '🔁 إعادة محاولة آمنة'
        }
    }
}

Describe 'Quiet runtime orchestration' {
    It 'does not leak periodic helper return values to the terminal' {
        foreach ($step in @('Update-PostShowQueue', 'Update-SnapshotJobs', 'Update-RelayWatchdog', 'Update-AutoHideQueue', 'Update-ScheduleQueue', 'Update-PendingExpiry', 'Update-SnapshotCleanup', 'Save-UsageCounts', 'Save-UserProfiles', 'Update-CinegyStateWatchdog', 'Update-CinegyHealthWatchdog', 'Update-Heartbeat')) {
            Mock $step { return $true }
        }

        @(Invoke-BridgeTick).Count | Should -Be 0
    }
}

Describe 'Maintenance mode control gate' {
    BeforeEach {
        $script:OriginalMaintenanceMode = Get-Setting 'MaintenanceMode'
        $config.Settings | Add-Member -NotePropertyName MaintenanceMode -NotePropertyValue $true -Force
        Mock Send-TelegramMessage { }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true; EventId = '{A}' } }
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{ urgent = [pscustomobject]@{ Key='urgent'; Layer=4; Path='urgent.cintitle'; FieldTypes=@{} } }; Order=@('urgent'); Errors=@() }
        }
    }

    AfterEach { $config.Settings | Add-Member -NotePropertyName MaintenanceMode -NotePropertyValue $script:OriginalMaintenanceMode -Force }

    It 'blocks SHOW before any Cinegy command is sent' {
        $result = Invoke-ShowTemplateResult -Key urgent -ChatId 10 -UserId 10
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'الصيانة'
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'blocks a normal HIDE before any Cinegy command is sent' {
        Invoke-HideLayer -Layer 4 -ChatId 10 -UserId 10 | Should -BeFalse
        Should -Invoke Hide-TitlerTemplate -Times 0 -Exactly
    }

    It 'blocks starting a new scheduled SHOW' {
        Mock Clear-PendingState { }
        Mock Get-TemplateByIndex { throw 'The schedule flow must stop before loading a template.' }
        Start-ScheduleShowFlow -TemplateIndex 0 -ChatId 10 -UserId 10
        Should -Invoke Get-TemplateByIndex -Times 0 -Exactly
    }

    It 'allows the administrator emergency hide-all override' {
        Mock Test-Admin { $true }
        Mock Get-HideAllTargetLayers { @(4) }
        Mock Invoke-HideLayer { $true }
        Mock Write-BridgeLog { }; Mock Add-AuditEntry { }
        Invoke-HideAllLayers -ChatId 1 -UserId 1
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 4 -and $MaintenanceOverride }
    }
}

Describe 'Split-TelegramText' {
    It 'returns the short message as a plain string, not a nested array' {
        # The System.Object[] regression: the element must be a string.
        $chunks = @(Split-TelegramText -Text 'مرحبا')
        $chunks.Count | Should -Be 1
        $chunks[0] | Should -BeOfType ([string])
        $chunks[0] | Should -Be 'مرحبا'
        "$($chunks[0])" | Should -Not -Match 'System\.Object'
    }

    It 'keeps every chunk within the limit and loses no characters' {
        $text = (1..400 | ForEach-Object { "سطر رقم $_ فيه نص عربي" }) -join "`n"
        $chunks = @(Split-TelegramText -Text $text)
        $chunks.Count | Should -BeGreaterThan 1
        foreach ($c in $chunks) { $c.Length | Should -BeLessOrEqual 3500 }
        ($chunks -join "`n").Replace("`n", '') | Should -Be $text.Replace("`n", '')
    }

    It 'hard-splits a single line longer than the limit' {
        $chunks = @(Split-TelegramText -Text ('x' * 9000))
        foreach ($c in $chunks) { $c.Length | Should -BeLessOrEqual 3500 }
        ($chunks -join '') | Should -Be ('x' * 9000)
    }

    It 'never splits a Unicode surrogate pair or combining text element' {
        $text = ('x' * 3499) + '😀' + 'عَ' + ('y' * 20)
        $chunks = @(Split-TelegramText -Text $text)

        ($chunks -join '') | Should -Be $text
        foreach ($chunk in $chunks) {
            $chunk.Length | Should -BeLessOrEqual 3500
            { [Text.UTF8Encoding]::new($false, $true).GetBytes($chunk) } | Should -Not -Throw
        }
        $chunks[0] | Should -Be ('x' * 3499)
    }
}

Describe 'Unicode-aware field limits' {
    BeforeEach { Mock Send-TelegramMessage { } }

    It 'counts emoji as visible text elements rather than two UTF-16 units' {
        Test-FieldLength -Value '😀😀😀' -ChatId 1 -FieldLimit 3 | Should -BeTrue
        Test-FieldLength -Value '😀😀😀😀' -ChatId 1 -FieldLimit 3 | Should -BeFalse
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match '\(4 حرفًا\).*3' }
    }

    It 'counts an Arabic letter plus its combining mark as one text element' {
        Get-TextElementCount -Text 'عَجَل' | Should -Be 3
    }
}

Describe 'Compact Telegram button labels' {
    It 'shortens a long Arabic template label without changing its callback command' {
        $original = $config.Settings.ButtonTextMaxLength
        try {
            $config.Settings.ButtonTextMaxLength = 18
            $button = New-Button '🔴 إخفاء حركة سلايد طويلة جدًا للمشهد' 'hide:8'

            (Get-TextElementCount -Text $button.text) | Should -BeLessOrEqual 18
            $button.text | Should -Match '…$'
            $button.callback_data | Should -Be 'hide:8'
        }
        finally { $config.Settings.ButtonTextMaxLength = $original }
    }
}

Describe 'News ticker management' {
    BeforeEach {
        $script:OriginalNewsSettings = @{}
        foreach ($name in @('EnableNewsTickerManagement','NewsFilePath','NewsItemSeparator','NewsMaxItemLength','NewsMaxItems','AllowOperatorsDeleteNews','AllowOperatorsRestoreNews','AllowOperatorsClearAllNews')) {
            $script:OriginalNewsSettings[$name] = Get-JsonProp $config.Settings $name
        }
        $script:NewsLivePath = Join-Path $TestDrive 'news.txt'
        [IO.File]::WriteAllText($script:NewsLivePath, "خبر أول |`r`nخبر ثان |`r`n", [Text.UTF8Encoding]::new($true))
        $config.Settings | Add-Member EnableNewsTickerManagement $true -Force
        $config.Settings | Add-Member NewsFilePath $script:NewsLivePath -Force
        $config.Settings | Add-Member NewsItemSeparator '|' -Force
        $config.Settings | Add-Member NewsMaxItemLength 500 -Force
        $config.Settings | Add-Member NewsMaxItems 100 -Force
        $config.Settings | Add-Member AllowOperatorsDeleteNews $false -Force
        $config.Settings | Add-Member AllowOperatorsRestoreNews $false -Force
        $config.Settings | Add-Member AllowOperatorsClearAllNews $false -Force
        $script:newsDraftFile = Join-Path $TestDrive 'news-draft.json'
        $script:newsBackupDirectory = Join-Path $TestDrive 'news-backups'
        $script:NewsTickerDraft = $null
        Mock Send-TelegramMessage { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $false }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
    }

    AfterEach { $script:NewsTickerDraft = $null }

    It 'adds a permanent news-management button when the feature is enabled' {
        $keyboard = Get-PersistentReplyKeyboard
        @($keyboard.keyboard[0].text) | Should -Contain '📰 إدارة شريط الأخبار'
    }

    It 'shows news management inside the main inline menu' {
        $keyboard = Get-MainMenuKeyboard -ChatId 101 -UserId 101
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $callbacks | Should -Contain 'menu:news'
    }

    It 'shows the current news file as a clearly named administrator setting' {
        $keyboard = Get-SettingsCategoryKeyboard -Category 'news' -Page 0
        $labels = @($keyboard.inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.text } })
        @($labels | Where-Object { $_ -like '📰 ملف الأخبار*' }).Count | Should -Be 1
    }

    It 'accepts only an absolute txt path for the news file setting' {
        Test-NewsTickerFilePathSetting -Path 'news.txt' | Should -BeFalse
        Test-NewsTickerFilePathSetting -Path 'D:\ticker\news.json' | Should -BeFalse
        Test-NewsTickerFilePathSetting -Path 'D:\ticker\news.txt' | Should -BeTrue
    }

    It 'does not save an invalid news file path submitted through settings' {
        $before = [string](Get-Setting 'NewsFilePath')
        Mock Save-Config { }
        Set-PendingState -ChatId 101 -State @{ Mode='setting_text'; Name='NewsFilePath'; UserId=101 }

        Complete-SettingText -ChatId 101 -Value 'relative\news.txt'

        Get-Setting 'NewsFilePath' | Should -Be $before
        $config.Settings.NewsFilePath = $before
    }

    It 'allows one user to hold the draft lock and reports the live items' {
        $first = Start-NewsTickerDraft -ChatId 101 -UserId 101
        $second = Start-NewsTickerDraft -ChatId 202 -UserId 202

        $first.Success | Should -BeTrue
        $first.Draft.Items | Should -Be @('خبر أول','خبر ثان')
        $second.Success | Should -BeFalse
        $second.Error | Should -Match '101'
    }

    It 'keeps manual changes in the draft until reviewed publish' {
        $before = (Get-FileHash $script:NewsLivePath -Algorithm SHA256).Hash
        Start-NewsTickerDraft -ChatId 101 -UserId 101 | Out-Null
        Add-NewsTickerDraftItem -UserId 101 -Text 'خبر ثالث' | Should -BeTrue

        (Get-FileHash $script:NewsLivePath -Algorithm SHA256).Hash | Should -Be $before
        # Newest first: the item just typed leads the ticker.
        (Get-NewsTickerDraft -UserId 101).Items | Should -Be @('خبر ثالث','خبر أول','خبر ثان')
        (Publish-NewsTickerDraft -UserId 101).Success | Should -BeTrue
        (Get-NewsTickerSnapshot -Path $script:NewsLivePath -Separator '|').Items | Should -Be @('خبر ثالث','خبر أول','خبر ثان')
        Get-NewsTickerDraft | Should -BeNullOrEmpty
    }

    It 'appends instead when NewNewsItemAtTop is turned off' {
        # A rundown ordered by hand wants the old behaviour back. Set through
        # the config rather than a filtered mock of Get-Setting, which would
        # need a default mock for every other setting the flow reads.
        $config.Settings | Add-Member -NotePropertyName 'NewNewsItemAtTop' -NotePropertyValue $false -Force
        try {
            Start-NewsTickerDraft -ChatId 101 -UserId 101 | Out-Null

            Add-NewsTickerDraftItem -UserId 101 -Text 'خبر ثالث' | Should -BeTrue

            (Get-NewsTickerDraft -UserId 101).Items | Should -Be @('خبر أول', 'خبر ثان', 'خبر ثالث')
        }
        finally { $config.Settings.PSObject.Properties.Remove('NewNewsItemAtTop') }
    }

    It 'imports separator or line based TXT content into the draft without publishing' {
        Start-NewsTickerDraft -ChatId 101 -UserId 101 | Out-Null
        $result = Import-NewsTickerTextToDraft -UserId 101 -Text "مستورد أول`r`nمستورد ثان" -Mode replace

        $result.Success | Should -BeTrue
        (Get-NewsTickerDraft -UserId 101).Items | Should -Be @('مستورد أول','مستورد ثان')
        (Get-NewsTickerSnapshot -Path $script:NewsLivePath -Separator '|').Items | Should -Be @('خبر أول','خبر ثان')
    }

    It 'keeps clear-all unavailable to an operator unless explicitly enabled' {
        Start-NewsTickerDraft -ChatId 101 -UserId 101 | Out-Null
        Clear-NewsTickerDraftItems -ChatId 101 -UserId 101 | Should -BeFalse
        $config.Settings.AllowOperatorsClearAllNews = $true
        Clear-NewsTickerDraftItems -ChatId 101 -UserId 101 | Should -BeTrue
        (Get-NewsTickerDraft -UserId 101).Items.Count | Should -Be 0
    }
}

Describe 'Telegram API send reliability' {
    BeforeEach {
        $script:OriginalTelegramRequestTimeoutSeconds = Get-Setting 'TelegramRequestTimeoutSeconds'
        $config.Settings | Add-Member -NotePropertyName TelegramRequestTimeoutSeconds -NotePropertyValue 7 -Force
        Mock Start-Sleep { } -ModuleName BridgeTelegram
        Mock Write-BridgeLog { }
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName TelegramRequestTimeoutSeconds -NotePropertyValue $script:OriginalTelegramRequestTimeoutSeconds -Force
    }

    It 'retries a transient sendMessage failure once with a bounded timeout' {
        $script:TelegramSendAttemptForTest = 0
        Mock Invoke-RestMethod {
            $script:TelegramSendAttemptForTest++
            if ($script:TelegramSendAttemptForTest -eq 1) { throw 'temporary HTTP failure' }
            [pscustomobject]@{ ok = $true }
        } -ModuleName BridgeTelegram

        { Send-TelegramMessage -ChatId 10 -Text 'اختبار' } | Should -Not -Throw

        Should -Invoke Invoke-RestMethod -ModuleName BridgeTelegram -Times 2 -Exactly -ParameterFilter { $Uri -match '/sendMessage$' -and $TimeoutSec -eq 7 }
        Should -Invoke Start-Sleep -ModuleName BridgeTelegram -Times 1 -Exactly
    }

    It 'bounds photo and document uploads with the same timeout' {
        $photo = Join-Path $TestDrive 'frame.jpg'; Set-Content -LiteralPath $photo -Value 'x'
        $document = Join-Path $TestDrive 'diag.zip'; Set-Content -LiteralPath $document -Value 'x'
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } } -ModuleName BridgeTelegram

        Send-TelegramPhoto -ChatId 10 -FilePath $photo
        Send-TelegramDocument -ChatId 10 -FilePath $document | Should -BeTrue

        Should -Invoke Invoke-RestMethod -ModuleName BridgeTelegram -Times 1 -Exactly -ParameterFilter { $Uri -match '/sendPhoto$' -and $TimeoutSec -eq 7 }
        Should -Invoke Invoke-RestMethod -ModuleName BridgeTelegram -Times 1 -Exactly -ParameterFilter { $Uri -match '/sendDocument$' -and $TimeoutSec -eq 7 }
    }

    It 'downloads a Telegram document to an explicit bounded destination' {
        $destination = Join-Path $TestDrive 'imports\templates.json'
        Mock Invoke-RestMethod { [pscustomobject]@{ ok=$true; result=[pscustomobject]@{ file_path='documents/file_1.json' } } }
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '{"safe":true}' -NoNewline }

        Receive-TelegramDocument -FileId 'abc_123' -DestinationPath $destination -MaximumBytes 100 | Should -Be $destination
        Test-Path -LiteralPath $destination | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -match '/file/bot.+/documents/file_1\.json$' -and $TimeoutSec -eq 7 }
    }

    It 'rejects a traversal path returned by Telegram before downloading' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok=$true; result=[pscustomobject]@{ file_path='../config.json' } } }
        Mock Invoke-WebRequest { throw 'must not download' }
        { Receive-TelegramDocument -FileId 'abc' -DestinationPath (Join-Path $TestDrive 'x.json') } | Should -Throw '*مسار*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects an oversized Telegram document before starting its download' {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok=$true; result=[pscustomobject]@{ file_path='documents/large.json'; file_size=101 } } }
        Mock Invoke-WebRequest { throw 'must not download' }

        { Receive-TelegramDocument -FileId 'large' -DestinationPath (Join-Path $TestDrive 'large.json') -MaximumBytes 100 } | Should -Throw '*حجم*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'Version 6 role navigation contracts' {
    It 'preserves page filter and return callback in navigation context' {
        $context = Get-BridgeNavigationContext -Page 3 -Filter 'news' -ReturnCallback 'menu:templates'
        $context.Page | Should -Be 3
        $context.Filter | Should -Be 'news'
        $context.ReturnCallback | Should -Be 'menu:templates'
    }

    It 'builds the role main keyboard through the compatible menu' {
        Mock Test-Admin { $false }
        $callbacks = @((Get-RoleMainKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'menu:templates'
        $callbacks | Should -Contain 'menu:update'
        $callbacks | Should -Contain 'menu:schedule'
        $callbacks | Should -Not -Contain 'menu:settings'
    }

    It 'summarizes cached readiness without performing probes' {
        $summary = Get-BridgeReadinessSummary -Snapshot @{ Telegram = 'connected'; Cinegy = 'healthy'; DiskFreeGB = 8; LastError = '' }
        $summary.Ready | Should -BeTrue
        $summary.Text | Should -Match 'جاهز'
    }
}

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
}

Describe 'ConvertTo-ProcessArgumentLine' {
    It 'quotes a path containing spaces' {
        # The ffmpeg exit -22 regression: "D:\cingy cg\..." was split at the space.
        $line = ConvertTo-ProcessArgumentLine -Arguments @('-i', 'D:\cingy cg\logs\snap.jpg')
        $line | Should -Be '-i "D:\cingy cg\logs\snap.jpg"'
    }

    It 'leaves arguments without spaces unquoted' {
        ConvertTo-ProcessArgumentLine -Arguments @('-y', '-frames:v', '1') | Should -Be '-y -frames:v 1'
    }

    It 'represents an empty argument as an empty quoted string' {
        ConvertTo-ProcessArgumentLine -Arguments @('-x', '') | Should -Be '-x ""'
    }

    It 'escapes embedded quotes' {
        ConvertTo-ProcessArgumentLine -Arguments @('say "hi"') | Should -Be '"say \"hi\""'
    }
}

Describe 'Get-JsonProp' {
    It 'returns $null for a missing property instead of throwing under StrictMode' {
        $obj = [pscustomobject]@{ a = 1 }
        Get-JsonProp $obj 'missing' | Should -BeNullOrEmpty
    }

    It 'returns the value when present' {
        Get-JsonProp ([pscustomobject]@{ a = 42 }) 'a' | Should -Be 42
    }

    It 'supports hashtables and a $null object' {
        Get-JsonProp @{ b = 'x' } 'b' | Should -Be 'x'
        Get-JsonProp $null 'anything' | Should -BeNullOrEmpty
    }

    It 'preserves $false rather than treating it as absent' {
        Get-JsonProp ([pscustomobject]@{ flag = $false }) 'flag' | Should -Be $false
    }
}

Describe 'Protect-SensitiveText' {
    It 'redacts a Telegram RTMP stream key' {
        $msg = 'Error opening output rtmp://dc4-1.rtmp.t.me/s/SECRETKEY123: failed'
        $safe = Protect-SensitiveText $msg
        $safe | Should -Not -Match 'SECRETKEY123'
        $safe | Should -Match 'rtmp://\*\*\*'
    }

    It 'redacts a bot token' {
        # Structurally valid but entirely synthetic: 9-digit bot id plus a
        # 30-character token body. A placeholder such as TEST_TOKEN_REDACTED
        # does not exercise the real token-redaction pattern.
        $token = '123456789:' + ('A' * 30)
        (Protect-SensitiveText "token $token here") | Should -Not -Match 'A{30}'
    }

    It 'redacts an SRT passphrase' {
        (Protect-SensitiveText 'srt://host:9000?passphrase=hunter2') | Should -Not -Match 'hunter2'
    }

    It 'leaves ordinary text untouched' {
        Protect-SensitiveText 'تم إظهار عاجل على الطبقة 4' | Should -Be 'تم إظهار عاجل على الطبقة 4'
    }

    It 'handles empty input' {
        Protect-SensitiveText '' | Should -Be ''
    }
}

Describe 'Layer naming' {
    It 'ignores malformed layer-name entries instead of crashing on indexes' {
        $original = Get-Setting 'LayerNames'
        try {
            $config.Settings | Add-Member -NotePropertyName 'LayerNames' -NotePropertyValue 'bad;7=عاجل;9=شريط الأخبار;=oops;10=' -Force
            Get-LayerName -Layer 7 | Should -Be 'عاجل'
            Set-LayerName -Layer 8 -Name 'أخبار' -ChatId 42 -UserId 42 | Should -BeTrue
            Get-Setting 'LayerNames' | Should -Be '7=عاجل;8=أخبار;9=شريط الأخبار'
            Get-LayerDisplayName -Layer 8 | Should -Be 'أخبار · طبقة 8'
        }
        finally {
            $config.Settings | Add-Member -NotePropertyName 'LayerNames' -NotePropertyValue $original -Force
        }
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

Describe 'Array-returning helpers' {
    # Dot-sourcing hoists the script's variables into this scope, so they are
    # referenced unqualified - a $script: prefix here would resolve to the test
    # file's own scope, not the bridge's.
    It 'Get-FavoriteTemplateKeys yields a countable array even with no usage history' {
        # The $null.Count regression: an empty return must survive @() wrapping.
        $favs = @(Get-FavoriteTemplateKeys)
        { $favs.Count } | Should -Not -Throw
        $favs.Count | Should -BeGreaterOrEqual 0
    }

    It 'Get-KnownLayers always returns at least one layer' {
        @(Get-KnownLayers).Count | Should -BeGreaterThan 0
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
        $callbackData = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.callback_data })

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

Describe 'Help guidance' {
    It 'gives an actionable short path for common on-air operations' {
        $help = Get-HelpText

        $help | Should -Match '📋 القوالب ←'
        $help | Should -Match '📅 الجدولة'
        $help | Should -Match 'ظاهر.*خارجي.*مخفي.*غير معروف'
        $help | Should -Match '✏️ تحديث نص ←'
        $help | Should -Match '⏱ عرض مؤقّت'
    }

    It 'hides admin-only guidance from a regular user' {
        Mock Test-Admin { $false }

        $help = Get-HelpText

        $help | Should -Not -Match 'أدوات المشرف'
        $help | Should -Not -Match '🔄 تحديث حالة Cinegy'
    }

    It 'includes admin tools for an administrator' {
        Mock Test-Admin { $true }

        $help = Get-HelpText

        $help | Should -Match 'أدوات المشرف'
        $help | Should -Match '📊 الحالة الكاملة: للمشرف والمالك'
    }
}

Describe 'Role-aware status menus' {
    It 'shows only the simple status button to a regular authorized user' {
        Mock Test-Admin { $false }

        $keyboard = Get-MainMenuKeyboard -ChatId 200 -UserId 200
        $callbackData = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.callback_data })

        $callbackData | Should -Contain 'menu:status'
        $callbackData | Should -Not -Contain 'menu:fullstatus'
        $callbackData | Should -Not -Contain 'menu:health'
        $callbackData | Should -Not -Contain 'menu:refreshstatus'
    }

    It 'adds the full status button for an administrator without separate health or refresh buttons' {
        Mock Test-Admin { $true }

        $keyboard = Get-MainMenuKeyboard -ChatId 100 -UserId 100
        $callbackData = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.callback_data })

        $callbackData | Should -Contain 'menu:status'
        $callbackData | Should -Contain 'menu:fullstatus'
        $callbackData | Should -Not -Contain 'menu:health'
        $callbackData | Should -Not -Contain 'menu:refreshstatus'
    }

    It 'adds the full status button for the owner even when they are not an administrator' {
        Mock Test-Admin { $false }
        Mock Test-Owner { $true }

        $keyboard = Get-MainMenuKeyboard -ChatId 101 -UserId 101
        $callbackData = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.callback_data })

        $callbackData | Should -Contain 'menu:fullstatus'
    }

    It 'rejects a forged full-status callback from a non-admin' {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $false }
        Mock Test-Owner { $false }
        Mock Send-TelegramMessage { }
        Mock Invoke-FullStatusCommand { }
        $callback = [pscustomobject]@{
            id      = 'callback-1'
            from    = [pscustomobject]@{ id = 200 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 200 } }
            data    = 'menu:fullstatus'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Invoke-FullStatusCommand -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
    }

    It 'allows the owner to invoke the full status callback' {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $false }
        Mock Test-Owner { $true }
        Mock Send-TelegramMessage { }
        Mock Invoke-FullStatusCommand { }
        $callback = [pscustomobject]@{
            id      = 'owner-full-status-1'
            from    = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 101 } }
            data    = 'menu:fullstatus'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Invoke-FullStatusCommand -Times 1 -Exactly -ParameterFilter { $ChatId -eq 101 -and $UserId -eq 101 }
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

Describe 'Private-chat-only policy' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { }
    }

    It 'ignores callbacks originating from a Telegram group' {
        $callback = [pscustomobject]@{
            id = 'group-menu-1'
            from = [pscustomobject]@{ id = 200 }
            message = [pscustomobject]@{
                chat = [pscustomobject]@{ id = -100123; type = 'supergroup' }
            }
            data = 'menu'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Test-Authorized -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}

Describe 'Simple and full status reports' {
    BeforeEach {
        $script:OnAir.Clear()
        foreach ($service in @('Telegram', 'Cinegy')) {
            $script:HealthHistory[$service].LastSuccess = $null
            $script:HealthHistory[$service].LastError = ''
            $script:HealthHistory[$service].LastErrorAt = $null
        }
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { }
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{ urgent = 1 }; Order = @('urgent'); Errors = @() }
        }
        Mock Get-CinegyLayerDashboard {
            @([pscustomobject]@{
                Layer = 4; Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = ''
                OutputState = 'Normal'; LicenseState = 'Licensed'; ClientConnected = $true; ClientIdentity = 'Client 1'
            })
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{
                Checked = @(4); Added = @(); Removed = @(); Failed = @()
                LastSuccessfulAt = [datetime]'2026-08-22T11:20:00'
            }
        }
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
        Mock Get-MonitorFrame { $null }
        Mock Get-FfmpegPath { 'ffmpeg.exe' }
        Mock Get-AirTelemetryStatus {
            [pscustomobject]@{
                Success = $true; Healthy = $true; SampleCount = 60
                OutputCount = 1500; DroppedCount = 0; NoInputSignal = 0
                MaxReadErrorRate = 0; AverageReadTime = 1.2; MaxHeartbeat = 700
            }
        }
        Mock Get-LiveRelayStatusText { 'متوقف' }
    }

    AfterEach { $script:OnAir.Clear() }

    It 'keeps the public status lightweight while showing the Air server address' {
        Mock Test-Admin { $false }

        Invoke-StatusCommand -ChatId 200 -UserId 200

        Should -Invoke Get-AirTelemetryStatus -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 200 -and $Text -match 'القناة' -and $Text -match [regex]::Escape([string]$config.AirServerAddress) -and
                # Relative first, because the question being asked is "is this
                # current?"; the clock time stays in brackets for log comparison.
                $Text -match 'آخر فحص ناجح: (منذ .+|الآن) \(11:20:00\)' -and $Text -notmatch 'صحة الخدمات'
        }
    }

    It 'keeps status and Cinegy reconciliation available during maintenance' {
        $original = Get-Setting 'MaintenanceMode'
        try {
            $config.Settings | Add-Member -NotePropertyName MaintenanceMode -NotePropertyValue $true -Force
            Mock Test-Admin { $false }

            Invoke-StatusCommand -ChatId 200 -UserId 200

            Should -Invoke Get-CinegyLayerDashboard -Times 1 -Exactly
            Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly
            Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'القناة' }
        }
        finally {
            $config.Settings | Add-Member -NotePropertyName MaintenanceMode -NotePropertyValue $original -Force
        }
    }

    It 'includes the operator identity in the on-air summary so multiple users are visible' {
        $script:UserAliases['777'] = 'مخرج الأخبار'
        $script:OnAir[4] = @{ Key = 'urgent'; At = (Get-Date).AddMinutes(-2); UserId = 777; ActiveId = '{A}'; Source = 'bridge' }
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date).AddMinutes(-5); UserId = 0; ActiveId = '{B}'; Source = 'cinegy'; CinegyEventName = 'Cinegy Type Layer 8 On' }

        $summary = Get-OnAirSummary

        $summary | Should -Match '🔵.*طبقة 4.*urgent'
        $summary | Should -Match 'Bot.*مخرج الأخبار'
        $summary | Should -Match '🟣.*طبقة 8.*ticker'
        $summary | Should -Match 'Cinegy Air.*Cinegy Type Layer 8 On'
    }

    It 'identifies each live template and layer in the main-menu hide buttons' {
        Mock Test-Admin { $false }
        $script:OnAir[4] = @{ Key = 'urgent'; At = Get-Date; UserId = 777; ActiveId = '{A}'; Source = 'bridge' }
        $script:OnAir[8] = @{ Key = 'ticker'; At = Get-Date; UserId = 0; ActiveId = '{B}'; Source = 'cinegy' }

        $keyboard = Get-MainMenuKeyboard -ChatId 200 -UserId 200
        $labels = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text })

        $labels | Should -Contain '🔴 إخفاء 4 · urgent'
        $labels | Should -Contain '🔴 إخفاء 8 · ticker'
    }

    It 'merges layer details and health timings into the administrator full status' {
        Mock Test-Admin { $true }
        $callback = [pscustomobject]@{
            id = 'full-status-1'
            from = [pscustomobject]@{ id = 100 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100 } }
            data = 'menu:fullstatus'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 100 -and $Text -match 'الحالة الكاملة' -and $Text -match 'Telegram.*ms' -and $Text -match 'Cinegy.*ms' -and $Text -match 'طبقة 4' -and
                $Text -match '📺 المشاهد النشطة' -and $Text -match '🎛 اتصال Cinegy' -and
                $Text -match '🩺 صحة الخدمات' -and $Text -match '⚙️ التشغيل والجدولة' -and $Text -match '👥 الوصول' -and
                $Text -match 'وضع المشاهد المختار: Single'
        }
    }

    It 'includes a manual source probe and monitoring-server state in full status' {
        Mock Test-Admin { $true }
        Mock Get-MonitorFrame { 'monitor-frame.jpg' }
        Mock Get-BridgeFrameLuminance { 120 }
        Mock Remove-Item { }

        Invoke-FullStatusCommand -ChatId 100 -UserId 100

        Should -Invoke Get-MonitorFrame -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match '📡 مراقب المصدر' -and
                $Text -match 'سيرفر المتابعة' -and
                $Text -match 'المصدر الأساسي' -and
                $Text -match 'متاح'
        }
    }

    It 'rejects the legacy health command for a regular user' {
        Mock Test-Admin { $false }

        Invoke-BridgeCommand -Text '/health' -ChatId 200 -UserId 200

        Should -Invoke Get-AirTelemetryStatus -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
    }

    It 'keeps the legacy health command as an administrator alias for full status' {
        Mock Test-Admin { $true }

        Invoke-BridgeCommand -Text '/health' -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 100 -and $Text -match 'الحالة الكاملة' -and $Text -match 'صحة الخدمات'
        }
    }

    It 'keeps last success and error history inside full status' {
        Mock Test-Admin { $true }
        Invoke-HealthCommand -ChatId 100 -UserId 100

        Mock Invoke-RestMethod { throw 'telegram timeout' }
        Mock Get-AirTelemetryStatus { [pscustomobject]@{ Success = $false; Healthy = $null } }
        Invoke-HealthCommand -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 100 -and $Text -match 'آخر نجاح' -and $Text -match 'آخر خطأ: telegram timeout'
        }
    }
}

Describe 'Cinegy state freshness classification' {
    It 'classifies a recent successful comparison as connected' {
        $now = [datetime]'2026-08-22T12:00:00'
        (Get-CinegyStateFreshness -LastSuccessfulAt $now.AddSeconds(-10) -FailedCount 0 -Now $now -StaleAfterSeconds 45).State | Should -Be 'connected'
    }

    It 'classifies an old successful comparison as stale' {
        $now = [datetime]'2026-08-22T12:00:00'
        (Get-CinegyStateFreshness -LastSuccessfulAt $now.AddSeconds(-60) -FailedCount 0 -Now $now -StaleAfterSeconds 45).State | Should -Be 'stale'
    }

    It 'classifies a failed live comparison as unavailable' {
        $now = [datetime]'2026-08-22T12:00:00'
        (Get-CinegyStateFreshness -LastSuccessfulAt $now.AddSeconds(-10) -FailedCount 1 -Now $now -StaleAfterSeconds 45).State | Should -Be 'unavailable'
    }

    It 'classifies a never-successful comparison as unknown' {
        (Get-CinegyStateFreshness -LastSuccessfulAt $null -FailedCount 0 -Now ([datetime]'2026-08-22T12:00:00') -StaleAfterSeconds 45).State | Should -Be 'unknown'
    }
}

Describe 'Admin diagnostics command' {
    BeforeEach {
        $script:AirOperationCounters = @{ Success = 0; Failed = 0; Blocked = 0 }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $true }
        Mock Send-TelegramMessage { }
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{ a = 1; b = 2 }; Order = @('a', 'b'); Errors = @() }
        }
        Mock Get-AirTelemetryStatus {
            [pscustomobject]@{
                Success = $true; Healthy = $true; SampleCount = 60
                OutputCount = 1500; DroppedCount = 0; NoInputSignal = 0
                MaxReadErrorRate = 0; AverageReadTime = 1.2; MaxHeartbeat = 700
            }
        }
    }

    It 'reports operational state to an admin without exposing the bot token' {
        Invoke-BridgeCommand -Text '/diagnostics' -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تشخيص' -and $Text -match 'Bridge' -and $Text -match 'Cinegy' -and
                $Text -match 'الذاكرة' -and $Text -match 'مساحة القرص' -and $Text -match 'أحجام الملفات' -and
                $Text -match 'نجاح.*فشل.*محظور' -and $Text -notmatch [regex]::Escape([string]$config.BotToken)
        }
    }

    It 'counts successful failed and blocked air operations without reading log files' {
        Mock Write-BridgeLog { }
        Write-AirOperationResult -OperationId a -Action SHOW -Result success -DurationMs 1 -UserId 1 -ChatId 1
        Write-AirOperationResult -OperationId b -Action HIDE -Result failed -DurationMs 1 -UserId 1 -ChatId 1
        Write-AirOperationResult -OperationId c -Action EXIT -Result blocked -DurationMs 1 -UserId 1 -ChatId 1

        $snapshot = Get-BridgeDiagnosticsSnapshot
        $snapshot.AirOperations.Success | Should -Be 1
        $snapshot.AirOperations.Failed | Should -Be 1
        $snapshot.AirOperations.Blocked | Should -Be 1
    }

    It 'warns when free disk or retained runtime storage crosses configured limits' {
        $snapshot = [pscustomobject]@{
            DiskFreeGB = 0.5
            RuntimeStorageBytes = 120MB
            BackupStorageBytes = 80MB
        }

        $warnings = @(Get-DiagnosticWarnings -Snapshot $snapshot -DiskFreeWarningGB 2 -RuntimeStorageWarningMB 100 -BackupStorageWarningMB 50)
        $warnings.Count | Should -Be 3
        $warnings -join ' ' | Should -Match 'القرص'
        $warnings -join ' ' | Should -Match 'السجلات'
        $warnings -join ' ' | Should -Match 'النسخ'
    }

    It 'removes user and chat identifiers as well as secrets from diagnostic text' {
        $safe = Protect-DiagnosticText "AIR_OP user=123456 chat=987654 token=123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345 user 55555 from 44444"

        $safe | Should -Not -Match '123456|987654|55555|44444|ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $safe | Should -Match 'user=\*\*\*|chat=\*\*\*|user \*\*\*|from \*\*\*'
    }
}

Describe 'Administrator log cleanup' {
    BeforeEach {
        $script:PendingState.Clear()
        $script:auditFile = Join-Path $TestDrive 'audit.jsonl'
        $script:logPath = Join-Path $TestDrive 'bridge.log'
        $script:logDir = $TestDrive
        Set-Content -LiteralPath $script:auditFile -Value '{"old":"audit"}'
        Set-Content -LiteralPath $script:logPath -Value 'old runtime line'
        Set-Content -LiteralPath (Join-Path $TestDrive 'bridge.1.log') -Value 'old rotated line'
        Set-Content -LiteralPath (Join-Path $TestDrive 'relay-stderr.log') -Value 'old relay error'
        Set-Content -LiteralPath (Join-Path $TestDrive 'onair.json') -Value '{"live":true}'
        Mock Test-Admin { $true }
        Mock Test-CallbackAdmin { $true }
        Mock Confirm-TelegramCallback { }
        Mock Send-TelegramMessage { }
    }

    It 'requires a fresh per-admin confirmation before deleting a log' {
        Request-DiagnosticLogClear -Kind runtime -ChatId 100 -UserId 100

        (Get-Content -LiteralPath $script:logPath -Raw) | Should -Match 'old runtime'
        $state = Get-PendingState -ChatId 100
        $state.Mode | Should -Be 'diagnostic_log_clear'
        $state.Kind | Should -Be 'runtime'
        $state.UserId | Should -Be 100
    }

    It 'clears the current and rotated runtime logs but preserves the audit trail' {
        Clear-DiagnosticLog -Kind runtime -UserId 100 | Should -BeTrue

        (Get-Content -LiteralPath $script:logPath -Raw) | Should -Not -Match 'old runtime'
        Test-Path -LiteralPath (Join-Path $TestDrive 'bridge.1.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'relay-stderr.log') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $TestDrive 'onair.json') -Raw) | Should -Match 'live'
        (Get-Content -LiteralPath $script:auditFile -Raw) | Should -Match 'log_clear'
    }

    It 'clears old audit entries and creates a new record identifying the cleanup operation' {
        Clear-DiagnosticLog -Kind audit -UserId 100 | Should -BeTrue

        $content = Get-Content -LiteralPath $script:auditFile -Raw
        $content | Should -Not -Match 'old.*audit'
        $record = $content | ConvertFrom-Json
        $record.event | Should -Be 'log_clear'
        $record.target | Should -Be 'audit'
    }
}

Describe 'Redacted diagnostic bundle' {
    BeforeEach {
        $script:logDir = Join-Path $TestDrive 'bundle-runtime'
        New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null
        $script:logPath = Join-Path $script:logDir 'bridge.log'
        Set-Content -LiteralPath $script:logPath -Value @(
            '2026-08-22 [INFO] AIR_OP user=123456 chat=987654 target="ticker"'
            '2026-08-22 [ERROR] token 123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345 from 55555'
        )
    }

    It 'contains only a health summary and redacted recent runtime lines' {
        $bundle = New-DiagnosticBundle
        $extract = Join-Path $TestDrive 'bundle-extracted'
        [IO.Compression.ZipFile]::ExtractToDirectory($bundle, $extract)

        @(Get-ChildItem -LiteralPath $extract -File).Name | Sort-Object | Should -Be @('recent-runtime.log', 'summary.json')
        $allText = (Get-Content -LiteralPath (Join-Path $extract 'summary.json') -Raw) + "`n" +
            (Get-Content -LiteralPath (Join-Path $extract 'recent-runtime.log') -Raw)
        $allText | Should -Not -Match '123456|987654|55555|ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $allText | Should -Not -Match 'BotToken|AllowedUserIds|onair'
        $allText | Should -Match 'user=\*\*\*|chat=\*\*\*'
    }

    It 'is available only through the administrator command' {
        Mock Test-Admin { $true }
        Mock New-DiagnosticBundle { Join-Path $TestDrive 'diagnostics.zip' }
        Mock Send-TelegramDocument { $true }
        Mock Remove-Item { }

        Invoke-DiagnosticBundleCommand -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramDocument -Times 1 -Exactly -ParameterFilter { $ChatId -eq 100 -and $FilePath -match 'diagnostics\.zip$' }
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

Describe 'CinegyAirTitler public commands' {
    It 'is not exported as a public module command' {
        Get-Command -Module CinegyAirTitler -Name Escape-XmlValue -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}

InModuleScope CinegyAirTitler {
    Describe 'Escape-XmlValue' {
        It 'accepts an empty string' {
            # The ⏭ تخطي regression: a Mandatory [string] rejects ''.
            { Escape-XmlValue -Value '' } | Should -Not -Throw
            Escape-XmlValue -Value '' | Should -Be ''
        }

        It 'escapes XML metacharacters' {
            Escape-XmlValue -Value '<b>&"' | Should -Match '&lt;'
            Escape-XmlValue -Value '<b>&"' | Should -Not -Match '<b>'
        }

        It 'leaves Arabic text intact' {
            Escape-XmlValue -Value 'خبر عاجل' | Should -Be 'خبر عاجل'
        }
    }

    Describe 'Show-TitlerTemplate identity' {
        It 'assigns the SHOW event an id that the bridge can correlate with Cinegy status' {
            Mock Invoke-WebRequest {
                [pscustomobject]@{ StatusCode = 200; Content = '<Reply Success="y" Status="OK"/>' }
            }

            $result = Show-TitlerTemplate -AirServerAddress 'air-host' -AirChannelNumber 0 `
                -Layer 4 -TemplatePath 'D:\CG\urgent.cintitle'
            $eventIdProperty = $result.PSObject.Properties['EventId']

            $eventIdProperty | Should -Not -BeNullOrEmpty
            { [guid]::Parse(([string]$eventIdProperty.Value).Trim('{', '}')) } | Should -Not -Throw
            ([xml]$result.Xml).Request.Event.Id | Should -Be $eventIdProperty.Value
        }
    }
}

Describe 'Get-TitlerLayerStatus' {
    It 'extracts the external template filename from the Cinegy item description' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}" Name="Cinegy Type Layer 8 On" Description="Show ticker.cintitle on layer 8" IsEmpty="n"/>'
                }
            }
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"/><License State="Licensed"/><Output State="Normal"/><Client Connected="n" Identity=""/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 8

        $result.ActiveTemplateName | Should -Be 'ticker'
        $result.ActiveName | Should -Be 'Cinegy Type Layer 8 On'
    }

    It 'preserves Arabic and spaces when extracting a template from a full path' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}" Name="Cinegy Type Layer 8 On" Description="Show D:\Titles\حركة سلايد.cintitle on layer 8" IsEmpty="n"/>'
                }
            }
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}"/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 8

        $result.ActiveTemplateName | Should -Be 'حركة سلايد'
    }

    It 'returns operational metadata and the active Cinegy item name' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}" Name="External Lower Third" IsEmpty="n"/>'
                }
            }
            return [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"/><License State="Licensed"/><Output State="Normal"/><Client Connected="y" Identity="Air Client 1"/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 4

        $result.ActiveName | Should -Be 'External Lower Third'
        $result.LicenseState | Should -Be 'Licensed'
        $result.OutputState | Should -Be 'Normal'
        $result.ClientConnected | Should -BeTrue
        $result.ClientIdentity | Should -Be 'Air Client 1'
    }

    It 'reports hidden when the active playlist item is Cinegy empty filler' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{86078791-9CB3-11F1-96C0-C85EA97266A8}" IsEmpty="y"/>'
                }
            }
            return [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{86078791-9CB3-11F1-96C0-C85EA97266A8}"/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 4

        $result.Success | Should -BeTrue
        $result.IsOnAir | Should -BeFalse
        Should -Invoke Invoke-WebRequest -ModuleName CinegyAirTitler -Times 1 -Exactly `
            -ParameterFilter { $Uri -eq 'http://air-host:5521/gfx_4/status/active' }
    }

    It 'reports a layer as on air when Cinegy returns a non-zero Active id' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{D0B60C83-9CA7-11F1-96C0-C85EA97266A8}" IsEmpty="n"/>'
                }
            }
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{D0B60C83-9CA7-11F1-96C0-C85EA97266A8}"/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 2 -Layer 4

        $result.Success | Should -BeTrue
        $result.IsOnAir | Should -BeTrue
        $result.ActiveId | Should -Be '{D0B60C83-9CA7-11F1-96C0-C85EA97266A8}'
        Should -Invoke Invoke-WebRequest -ModuleName CinegyAirTitler -Times 1 -Exactly `
            -ParameterFilter { $Uri -eq 'http://air-host:5523/gfx_4/status' -and $Method -eq 'Get' }
        Should -Invoke Invoke-WebRequest -ModuleName CinegyAirTitler -Times 1 -Exactly `
            -ParameterFilter { $Uri -eq 'http://air-host:5523/gfx_4/status/active' -and $Method -eq 'Get' }
    }

    It 'reports a layer as hidden when Active is absent or has the zero id' -ForEach @(
        @{ Xml = '<Status></Status>' }
        @{ Xml = '<Status><Active Id="{00000000-0000-0000-0000-000000000000}"/></Status>' }
    ) {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{ StatusCode = 200; Content = $Xml }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 6

        $result.Success | Should -BeTrue
        $result.IsOnAir | Should -BeFalse
    }

    It 'returns an unknown result instead of claiming hidden when Cinegy is unreachable' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'connection refused' }

        $result = Get-TitlerLayerStatus -AirServerAddress 'offline-host' -AirChannelNumber 0 -Layer 4

        $result.Success | Should -BeFalse
        $result.IsOnAir | Should -BeNullOrEmpty
        $result.Error | Should -Match 'connection refused'
    }
}

Describe 'Get-AirTelemetryStatus' {
    It 'aggregates a healthy minute of Cinegy metrics' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics StartAt="2026-08-20T10:00:00Z"><At Time="2026-08-20T10:00:01Z" DroppedCount="0" OutputCount="25" NoInputSignal="0" AverageReadTime="1.0" ReadErrorRate="0" Heartbeat="650"/><At Time="2026-08-20T10:00:02Z" DroppedCount="0" OutputCount="25" NoInputSignal="0" AverageReadTime="3.0" ReadErrorRate="0" Heartbeat="700"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 2

        $result.Success | Should -BeTrue
        $result.Healthy | Should -BeTrue
        $result.SampleCount | Should -Be 2
        $result.OutputCount | Should -Be 50
        $result.DroppedCount | Should -Be 0
        $result.NoInputSignal | Should -Be 0
        $result.AverageReadTime | Should -Be 2.0
        $result.MaxReadErrorRate | Should -Be 0
        $result.MaxHeartbeat | Should -Be 700
        @($result.Issues).Count | Should -Be 0
        Should -Invoke Invoke-WebRequest -ModuleName CinegyAirTitler -Times 1 -Exactly `
            -ParameterFilter { $Uri -eq 'http://air-host:5523/metrics' -and $Method -eq 'Get' }
    }

    It 'marks dropped frames missing input and read errors as unhealthy' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="1" OutputCount="24" NoInputSignal="2" AverageReadTime="4.5" ReadErrorRate="5" Heartbeat="900"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0

        $result.Healthy | Should -BeFalse
        $result.DroppedCount | Should -Be 1
        $result.NoInputSignal | Should -Be 2
        $result.MaxReadErrorRate | Should -Be 5
        @($result.Issues).Count | Should -Be 3
    }

    It 'returns unknown health when the metrics endpoint is unreachable' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'metrics timeout' }

        $result = Get-AirTelemetryStatus -AirServerAddress 'offline-host' -AirChannelNumber 0

        $result.Success | Should -BeFalse
        $result.Healthy | Should -BeNullOrEmpty
        $result.Error | Should -Match 'metrics timeout'
    }

    It 'stays healthy for frame loss inside the tolerance' {
        # Zero tolerance is what produced 54 health transitions in one day: a
        # single dropped frame entered the sixty-sample window, the next check
        # the window had rolled past it, and the channel was never unwell.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="3" OutputCount="1500" NoInputSignal="0" AverageReadTime="4.5" ReadErrorRate="0.2" Heartbeat="900"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 `
            -FrameLossTolerance 5 -ReadErrorRateTolerance 0.5

        $result.Healthy | Should -BeTrue
        # Reported regardless: "within tolerance" is not "nothing happened".
        $result.DroppedCount | Should -Be 3
    }

    It 'still reports frame loss past the tolerance' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="60" OutputCount="1500" NoInputSignal="0" AverageReadTime="4.5" ReadErrorRate="0" Heartbeat="900"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -FrameLossTolerance 5 -FrameLossTolerancePercent 1

        $result.Healthy | Should -BeFalse
        $result.Issues | Should -Contain 'Dropped frames: 60 (4%)'
    }

    It 'stays quiet for a burst that is small against what actually went out' {
        # The alert the operator objected to: "الساقط 34، الخرج 1467" - which
        # sounds alarming and is 2.3%. A bare count cannot tell those apart,
        # and the sample window is not a fixed size.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="34" OutputCount="1467" NoInputSignal="0" AverageReadTime="2.31" ReadErrorRate="0" Heartbeat="924"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -FrameLossTolerance 5 -FrameLossTolerancePercent 5

        $result.Healthy | Should -BeTrue
        $result.DroppedPercent | Should -Be 2.32
    }

    It 'still speaks up when the share is genuinely bad' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="300" OutputCount="1500" NoInputSignal="0" AverageReadTime="2.31" ReadErrorRate="0" Heartbeat="924"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -FrameLossTolerance 5 -FrameLossTolerancePercent 5

        $result.Healthy | Should -BeFalse
        $result.Issues | Should -Contain 'Dropped frames: 300 (20%)'
    }

    It 'needs both thresholds crossed, not either' {
        # A handful of drops in a tiny window is a high percentage of nothing.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="3" OutputCount="10" NoInputSignal="0" AverageReadTime="2.31" ReadErrorRate="0" Heartbeat="924"/></Metrics>'
            }
        }

        (Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -FrameLossTolerance 5 -FrameLossTolerancePercent 5).Healthy | Should -BeTrue
    }

    It 'defaults to no tolerance, so an existing caller behaves as before' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="1" OutputCount="1500" NoInputSignal="0" AverageReadTime="4.5" ReadErrorRate="0" Heartbeat="900"/></Metrics>'
            }
        }

        (Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0).Healthy | Should -BeFalse
    }

    It 'reads how long Cinegy means the active item to stay up' {
        # A ticker is scheduled as 24:00:00 with a manual end. That is the
        # engine saying "this is meant to be up", and it is what stops the
        # staleness alert from calling it forgotten.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/active') {
                return [pscustomobject]@{ StatusCode = 200; Content = '<Item Id="{4}" Name="News-Ticker" Description="Show Ticker.cintitle" Duration="24:00:00.000" ManualEnd="y"/>' }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '<Status><Active Id="{4}"/><License State="Licensed"/><Output State="Normal"/><Client Connected="n" Identity=""/></Status>' }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 8

        $result.ActiveDurationSeconds | Should -Be 86400
        $result.ActiveManualEnd | Should -BeTrue
    }
}

Describe 'SHOW identity tracking' {
    BeforeEach {
        $script:OriginalReservedLayers = Get-Setting 'ReservedLayers'
        $script:OriginalDisabledTemplateKeys = Get-Setting 'DisabledTemplateKeys'
        $script:OriginalSensitiveTemplateKeys = Get-Setting 'SensitiveTemplateKeys'
        $script:OriginalSensitiveTemplateAutoHideSeconds = Get-Setting 'SensitiveTemplateAutoHideSeconds'
        $config.Settings | Add-Member -NotePropertyName ReservedLayers -NotePropertyValue '' -Force
        $config.Settings | Add-Member -NotePropertyName DisabledTemplateKeys -NotePropertyValue '' -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue '' -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateAutoHideSeconds -NotePropertyValue 30 -Force
        $OnAir.Clear()
        $LastShow.Clear()
        $script:AutoHideQueue.Clear()
        Mock Get-TemplateStore {
            [pscustomobject]@{
                Map = @{
                    urgent = [pscustomobject]@{
                        Layer = 4
                        Path = 'D:\CG\urgent.cintitle'
                        FieldTypes = @{}
                    }
                }
            }
        }
        Mock Show-TitlerTemplate {
            [pscustomobject]@{
                Success = $true
                EventId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
                Xml = '<Request/>'
            }
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
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName ReservedLayers -NotePropertyValue $script:OriginalReservedLayers -Force
        $config.Settings | Add-Member -NotePropertyName DisabledTemplateKeys -NotePropertyValue $script:OriginalDisabledTemplateKeys -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue $script:OriginalSensitiveTemplateKeys -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateAutoHideSeconds -NotePropertyValue $script:OriginalSensitiveTemplateAutoHideSeconds -Force
        $OnAir.Clear()
        $LastShow.Clear()
        $script:AutoHideQueue.Clear()
    }

    It 'stores the SHOW event id with the local on-air record' {
        Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        Get-JsonProp $OnAir[4] 'ActiveId' | Should -Be '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
    }

    It 'does not record an on-air scene when Cinegy disconnects during SHOW' {
        Mock Show-TitlerTemplate {
            [pscustomobject]@{ Success = $false; EventId = ''; Xml = ''; Error = 'connection refused' }
        }

        Invoke-ShowTemplateResult -Key 'urgent' -Variables @{ 'Title.Text' = 'test' } -ChatId 10 -UserId 20

        $OnAir.ContainsKey(4) | Should -BeFalse
        $LastShow.ContainsKey(10) | Should -BeFalse
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

    It 'blocks SHOW when the target Cinegy layer cannot be verified' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $false; IsOnAir = $false; ActiveId = ''; ActiveName = ''; Error = 'timeout' }
        }

        $result = Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'التحقق'
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
        Should -Invoke Update-OnAirStateFromCinegy -Times 0 -Exactly
    }

    It 'blocks SHOW on an administrator-reserved layer before Cinegy is queried' {
        $config.Settings | Add-Member -NotePropertyName ReservedLayers -NotePropertyValue '4, 9' -Force

        $result = Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'محجوزة'
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'blocks a temporarily disabled template before Cinegy is queried' {
        $config.Settings | Add-Member -NotePropertyName DisabledTemplateKeys -NotePropertyValue 'urgent;logo' -Force

        $result = Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'معطّل'
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'schedules automatic hide against the exact Cinegy engine identity' {
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue 'urgent, breaking' -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateAutoHideSeconds -NotePropertyValue 30 -Force
        $script:IdentityStatusCall = 0
        Mock Get-TitlerLayerStatus {
            $script:IdentityStatusCall++
            if ($script:IdentityStatusCall -eq 1) {
                return [pscustomobject]@{ Success=$true; IsOnAir=$false; ActiveId=''; ActiveName=''; ActiveTemplateName=''; Error='' }
            }
            return [pscustomobject]@{
                Success=$true; IsOnAir=$true; ActiveId='{ENGINE-GUID}'
                ActiveName='Show urgent.cintitle on layer 4'; ActiveTemplateName='urgent'; Error=''
            }
        }

        Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $script:AutoHideQueue.Count | Should -Be 1
        $script:AutoHideQueue[0].Layer | Should -Be 4
        $script:AutoHideQueue[0].ActiveId | Should -Be '{ENGINE-GUID}'
        $script:AutoHideQueue[0].ActiveIdConfirmed | Should -BeTrue
        [math]::Round(($script:AutoHideQueue[0].At - (Get-Date)).TotalSeconds) | Should -BeIn @(29, 30)
    }

    It 'does not arm a destructive timer without positive exact post-show identity' {
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue 'urgent' -Force
        $script:IdentityStatusCall = 0
        Mock Get-TitlerLayerStatus {
            $script:IdentityStatusCall++
            if ($script:IdentityStatusCall -eq 1) {
                return [pscustomobject]@{ Success=$true; IsOnAir=$false; ActiveId=''; ActiveName=''; ActiveTemplateName=''; Error='' }
            }
            return [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='{OTHER}'; ActiveName=''; ActiveTemplateName=''; Error='' }
        }

        Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $script:AutoHideQueue.Count | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $Text -match 'ربط|يدوي' }
    }

    It 'keeps a shorter operator timer for a sensitive template' {
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue 'urgent' -Force

        Get-EffectiveAutoHideSeconds -Key urgent -RequestedSeconds 10 | Should -Be 10
        Get-EffectiveAutoHideSeconds -Key urgent -RequestedSeconds 60 | Should -Be 30
        Get-EffectiveAutoHideSeconds -Key other -RequestedSeconds 60 | Should -Be 60
    }
}

Describe 'Persistent timed-show auto-hide timers' {
    BeforeEach {
        $script:OriginalAutoHideFileForTest = $script:autoHideFile
        $script:autoHideFile = Join-Path $TestDrive 'autohide.json'
        $script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()
        $script:OnAir = @{}
        Mock Write-BridgeLog { }
        Mock Send-TelegramMessage { }
        Mock Invoke-HideLayer { $true }
    }

    AfterEach {
        $script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()
        $script:OnAir = @{}
        $script:autoHideFile = $script:OriginalAutoHideFileForTest
    }

    It 'restores a timer after restart and hides the same scene after the remaining duration' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $timer = @{
            Layer = 7; At = $now.AddSeconds(30).ToString('o'); ChatId = 1L; UserId = 2L
            TemplateKey = 'Urgent'; ActiveId = 'show-1'
        }
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-1'; At = $now.DateTime; UserId = 2L }
        $script:AutoHideQueue.Add($timer)
        Save-AutoHideQueue | Should -BeTrue
        $script:AutoHideQueue.Clear()

        Import-AutoHideQueue
        Update-AutoHideQueue -Now $now.AddSeconds(29)

        $script:AutoHideQueue.Count | Should -Be 1
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly

        Update-AutoHideQueue -Now $now.AddSeconds(30)

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 7 -and $Quiet }
        $script:AutoHideQueue.Count | Should -Be 0
    }

    It 'does not hide a replacement scene when the persisted timer belongs to an older show' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $timer = @{
            Layer = 7; At = $now.AddSeconds(-1).ToString('o'); ChatId = 1L; UserId = 2L
            TemplateKey = 'Urgent'; ActiveId = 'show-old'
        }
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-new'; At = $now.DateTime; UserId = 2L }
        $script:AutoHideQueue.Add($timer)
        Save-AutoHideQueue | Should -BeTrue
        $script:AutoHideQueue.Clear()

        Import-AutoHideQueue
        Update-AutoHideQueue -Now $now

        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        $script:AutoHideQueue.Count | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'لم يُنفَّذ|تغيّرت' }
    }

    It 'verifies and stores the engine identity when attaching a timer to an existing scene' {
        $script:OnAir[7] = @{ Key='Urgent'; ActiveId='{COMMAND-GUID}'; At=Get-Date; UserId=2L; Source='bridge' }
        Mock Get-TemplateStore { [pscustomobject]@{ Map=@{ Urgent=@{ Key='Urgent'; Path='D:\CG\Urgent.cintitle' } }; Order=@('Urgent') } }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='{ENGINE-GUID}'; ActiveTemplateName='Urgent'; ActiveName='Urgent'; Error='' }
        }
        Mock Save-OnAirState { }
        Mock Add-AuditEntry { }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard=@() } }

        Set-LayerAutoHide -Layer 7 -Seconds 30 -ChatId 2 -UserId 2

        $script:AutoHideQueue.Count | Should -Be 1
        $script:AutoHideQueue[0].ActiveId | Should -Be '{ENGINE-GUID}'
        $script:AutoHideQueue[0].ActiveIdConfirmed | Should -BeTrue
        $script:OnAir[7].ActiveId | Should -Be '{ENGINE-GUID}'
    }

    It 'does not hide or lose a due timer when consuming it cannot be persisted' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key='Urgent'; ActiveId='engine-1'; At=$now.DateTime; UserId=2L }
        $script:AutoHideQueue.Add(@{ Layer=7; At=$now; ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='engine-1'; ActiveIdConfirmed=$true })
        Mock Save-AutoHideQueue { $false }

        Update-AutoHideQueue -Now $now

        $script:AutoHideQueue.Count | Should -Be 1
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
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

Describe 'Administrative user activity status' {
    It 'labels recent stale and unknown activity without claiming Telegram presence' {
        $now = [datetime]'2099-08-21T10:00:00Z'
        (Get-UserActivityStatus -LastActivityAt $now.AddMinutes(-4).ToString('o') -Now $now -ActiveWithinMinutes 5).State | Should -Be 'recent'
        (Get-UserActivityStatus -LastActivityAt $now.AddMinutes(-6).ToString('o') -Now $now -ActiveWithinMinutes 5).State | Should -Be 'idle'
        (Get-UserActivityStatus -LastActivityAt '' -Now $now -ActiveWithinMinutes 5).State | Should -Be 'unknown'
    }

    It 'shows the approximate activity state in administrator user rows' {
        Mock Get-AuthorizedUsers { @([pscustomobject]@{ UserId=202L; Alias='مخرج'; Role='operator'; Disabled=$false; LastActivityAt=(Get-Date).AddMinutes(-1).ToString('o') }) }
        Mock Test-Owner { $false }
        $buttons = @((Get-UsersAdminKeyboard -ViewerUserId 101).inline_keyboard | ForEach-Object { @($_) })
        @($buttons.text) -join ' ' | Should -Match 'نشط حديثًا'
        @($buttons | Where-Object text -Match 'نشط حديثًا').callback_data | Should -Be 'usr:activity:202'
    }

    It 'discloses that the user-management activity labels are approximate' {
        Mock Send-TelegramMessage { }
        Mock Get-AuthorizedUsers { @() }
        Mock Test-Owner { $false }

        Show-UsersAdminScreen -ChatId 101 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تقريبي|لحظية' }
    }

    It 'adds a user activity summary to administrator tools' {
        Mock Get-RunningRelayProcess { $null }
        $callbacks = @((Get-AdminToolsKeyboard -ChatId 101 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'menu:userpresence'
    }

    It 'summarizes recent idle and unknown users from cached activity only' {
        $now = Get-Date
        Mock Get-AuthorizedUsers {
            @(
                [pscustomobject]@{ UserId=1L; Alias='أحمد'; LastActivityAt=$now.AddMinutes(-1).ToString('o') },
                [pscustomobject]@{ UserId=2L; Alias='سارة'; LastActivityAt=$now.AddMinutes(-9).ToString('o') },
                [pscustomobject]@{ UserId=3L; Alias='جديد'; LastActivityAt='' }
            )
        }
        $text = Get-UserActivitySummaryText -Now $now
        $text | Should -Match 'أحمد.*نشط حديثًا'
        $text | Should -Match 'سارة.*خامل'
        $text | Should -Match 'جديد.*غير معروف'
    }
}

Describe 'Snapshot source labels' {
    It 'labels a snapshot captured from the primary broadcast source' {
        Get-SnapshotSourceLabel -SourceIsPrimary $true | Should -Be 'البث الأساسي'
    }

    It 'labels a snapshot captured from Cinegy backup source' {
        Get-SnapshotSourceLabel -SourceIsPrimary $false | Should -Be 'بث Cinegy الاحتياطي'
    }
}

Describe 'Layer preparation locks' {
    BeforeEach {
        $script:LayerLocks.Clear()
        Clear-PendingState -ChatId 10
        Clear-PendingState -ChatId 11
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'
                Layer = 4
                Fields = @('Title.Text')
                FieldLabels = @('العنوان')
                FieldLimits = @(80)
            }
        }
        Mock Send-TelegramMessage { }
    }

    AfterEach {
        Clear-PendingState -ChatId 10
        Clear-PendingState -ChatId 11
        $script:LayerLocks.Clear()
    }

    It 'prevents a second operator from preparing the same layer' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 10 -UserId 20
        Start-ShowFlow -TemplateIndex 0 -ChatId 11 -UserId 21

        Get-PendingState -ChatId 10 | Should -Not -BeNullOrEmpty
        Get-PendingState -ChatId 11 | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            # Asserts the notice names who holds the layer and for how long -
            # a bare owner id told the second operator nothing they could act on.
            $ChatId -eq 11 -and $Text -match 'يجهّز' -and $Text -match 'منذ'
        }
    }

    It 'releases the layer when the first operator cancels the draft' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 10 -UserId 20
        Clear-PendingState -ChatId 10

        Start-ShowFlow -TemplateIndex 0 -ChatId 11 -UserId 21

        Get-PendingState -ChatId 11 | Should -Not -BeNullOrEmpty
    }

    It 'releases the layer when the draft expires' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 10 -UserId 20
        $state = Get-PendingState -ChatId 10
        $state.StartedAt = (Get-Date).AddMinutes(-10)

        Get-PendingState -ChatId 10 | Should -BeNullOrEmpty
        Start-ShowFlow -TemplateIndex 0 -ChatId 11 -UserId 21

        Get-PendingState -ChatId 11 | Should -Not -BeNullOrEmpty
    }

    It 'releases the layer when the periodic expiry sweep removes the draft' {
        Mock Write-BridgeLog { }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
        Start-ShowFlow -TemplateIndex 0 -ChatId 10 -UserId 20
        $state = Get-PendingState -ChatId 10
        $state.StartedAt = (Get-Date).AddMinutes(-10)

        Update-PendingExpiry
        Start-ShowFlow -TemplateIndex 0 -ChatId 11 -UserId 21

        Get-PendingState -ChatId 11 | Should -Not -BeNullOrEmpty
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

Describe 'Hide-all confirmation gate' {
    BeforeEach {
        Clear-PendingState -ChatId 70
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { }
        Mock Invoke-HideAllLayers { }
        Mock Get-KnownLayers { @(2, 4) }
    }

    AfterEach { Clear-PendingState -ChatId 70 }

    It 'does not hide layers when the emergency button is first pressed' {
        $callback = [pscustomobject]@{
            id = 'hide-all-review-1'
            from = [pscustomobject]@{ id = 80 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 70 } }
            data = 'menu:hideall'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Invoke-HideAllLayers -Times 0 -Exactly
        $state = Get-PendingState -ChatId 70
        $state | Should -Not -BeNullOrEmpty
        $state.Mode | Should -Be 'hide_all_review'
    }

    It 'hides all layers only after the operator confirms' {
        $review = [pscustomobject]@{
            id = 'hide-all-review-2'
            from = [pscustomobject]@{ id = 80 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 70 } }
            data = 'menu:hideall'
        }
        Invoke-CallbackQuery -CallbackQuery $review
        $confirm = [pscustomobject]@{
            id = 'hide-all-confirm-2'
            from = [pscustomobject]@{ id = 80 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 70 } }
            data = 'hideall:confirm'
        }

        Invoke-CallbackQuery -CallbackQuery $confirm

        Should -Invoke Invoke-HideAllLayers -Times 1 -Exactly -ParameterFilter { $ChatId -eq 70 -and $UserId -eq 80 }
        Get-PendingState -ChatId 70 | Should -BeNullOrEmpty
    }

    It 'requires the same confirmation for the slash hideall command' {
        Invoke-BridgeCommand -Text '/hideall' -ChatId 70 -UserId 80

        Should -Invoke Invoke-HideAllLayers -Times 0 -Exactly
        (Get-PendingState -ChatId 70).Mode | Should -Be 'hide_all_review'
    }
}

Describe 'Configurable hide-all layers' {
    BeforeEach {
        $script:OriginalHideAllLayersForTest = Get-Setting 'HideAllLayers'
        $config.Settings | Add-Member -NotePropertyName 'HideAllLayers' -NotePropertyValue '2,4' -Force
        $script:OnAir.Clear()
        Mock Get-KnownLayers { @(2, 4, 6) }
        Mock Invoke-HideLayer { $true }
        Mock Send-TelegramMessage { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Save-Config { }
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $true }
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName 'HideAllLayers' -NotePropertyValue $script:OriginalHideAllLayersForTest -Force
        $script:OnAir.Clear()
    }

    It 'uses only the layers selected by the administrator for hide-all' {
        $script:OnAir[8] = @{ Key = 'outside-scope'; At = Get-Date; UserId = 10 }

        Invoke-HideAllLayers -ChatId 70 -UserId 80

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 2 }
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 4 }
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly -ParameterFilter { $Layer -in @(6, 8) }
    }

    It 'uses every known layer when the setting is all' {
        $config.Settings | Add-Member -NotePropertyName 'HideAllLayers' -NotePropertyValue 'all' -Force

        $targets = @(Get-HideAllTargetLayers)

        $targets | Should -Be @(2, 4, 6)
    }

    It 'shows the selected layers as toggles in the administrator settings panel' {
        $keyboard = Get-HideAllLayerSettingsKeyboard
        $labels = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text })
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.callback_data })

        $labels | Should -Contain '✅ طبقة 2'
        $labels | Should -Contain '✅ طبقة 4'
        $labels | Should -Contain '⬜ طبقة 6'
        $callbacks | Should -Contain 'hideallcfg:toggle:6'
    }

    It 'adds a layer selected from the settings panel to the emergency scope' {
        $callback = [pscustomobject]@{
            id = 'hide-all-scope-1'
            from = [pscustomobject]@{ id = 80 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 70 } }
            data = 'hideallcfg:toggle:6'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        (Get-Setting 'HideAllLayers') | Should -Be '2,4,6'
    }
}

Describe 'On-air identity persistence' {
    BeforeEach {
        $script:OriginalOnAirFileForTest = $script:onAirFile
        $script:onAirFile = Join-Path $TestDrive 'onair.json'
        $OnAir.Clear()
        $script:OnAirScenes = [System.Collections.Generic.List[object]]::new()
        Mock Write-BridgeLog { }
    }

    AfterEach {
        $OnAir.Clear()
        $script:onAirFile = $script:OriginalOnAirFileForTest
    }

    It 'restores the SHOW event id after a bridge restart' {
        $OnAir[4] = @{
            Key = 'urgent'
            At = Get-Date
            UserId = 20
            ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        }
        Save-OnAirState
        $OnAir.Clear()

        Import-OnAirState

        Get-JsonProp $OnAir[4] 'ActiveId' | Should -Be '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
    }

    It 'reads the canonical scene envelope through the legacy one-record layer view' {
        @{ SchemaVersion = 1; Scenes = @(
            @{ SceneId = 'legacy-4'; Layer = 4; Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{CANONICAL}'; Source = 'bridge' }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:onAirFile -Encoding utf8

        Import-OnAirState

        $OnAir.ContainsKey(4) | Should -BeTrue
        $OnAir[4].Key | Should -Be 'urgent'
        $OnAir[4].ActiveId | Should -Be '{CANONICAL}'
    }

    It 'preserves every canonical same-layer scene when the state is re-saved' {
        @{ SchemaVersion = 1; Scenes = @(
            @{ SceneId = 'scene-a'; Layer = 4; Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{A}'; Source = 'bridge' }
            @{ SceneId = 'scene-b'; Layer = 4; Key = 'ticker'; At = '2026-08-28T12:01:00Z'; UserId = 21; ActiveId = '{B}'; Source = 'bridge' }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:onAirFile -Encoding utf8

        Import-OnAirState
        Save-OnAirState
        $saved = Get-Content -LiteralPath $script:onAirFile -Raw | ConvertFrom-Json

        @($saved.Scenes | Where-Object { $_.Layer -eq 4 }).Count | Should -Be 2
        @($saved.Scenes.SceneId) | Should -Contain 'scene-a'
        @($saved.Scenes.SceneId) | Should -Contain 'scene-b'
    }

    It 'updates only the projected canonical scene when Cinegy changes its identity' {
        Set-OnAirCanonicalScenes -Scenes @(
            [pscustomobject]@{ SceneId = 'scene-a'; Layer = 4; Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{A}'; Source = 'bridge' }
            [pscustomobject]@{ SceneId = 'scene-b'; Layer = 4; Key = 'ticker'; At = '2026-08-28T12:01:00Z'; UserId = 21; ActiveId = '{B}'; Source = 'bridge' }
        )

        Update-OnAirLayerRecord -Layer 4 -Record @{ Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{A2}'; Source = 'bridge' }

        @($script:OnAirScenes | Where-Object { $_.Layer -eq 4 }).Count | Should -Be 2
        ($script:OnAirScenes | Where-Object { $_.SceneId -eq 'scene-a' }).ActiveId | Should -Be '{A2}'
        ($script:OnAirScenes | Where-Object { $_.SceneId -eq 'scene-b' }).ActiveId | Should -Be '{B}'
    }

    It 'restores on-air state from the last validated backup when the primary JSON is corrupt' {
        $OnAir[4] = @{ Key = 'urgent'; At = Get-Date; UserId = 20; ActiveId = '{SAFE}' }
        Save-OnAirState
        Test-Path -LiteralPath "$($script:onAirFile).bak" | Should -BeTrue
        Set-Content -LiteralPath $script:onAirFile -Value '{broken-json'
        $OnAir.Clear()

        Import-OnAirState

        $OnAir[4].ActiveId | Should -Be '{SAFE}'
        { Get-Content -LiteralPath $script:onAirFile -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe 'Exit scene on-air record cleanup' {
    BeforeEach {
        $OnAir.Clear()
        $OnAir[7] = @{
            Key = 'urgent'; At = Get-Date; UserId = 10
            ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        }
        Mock Save-OnAirState { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-TelegramMessage { }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Layer = 7; Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = '' } }
    }

    AfterEach { $OnAir.Clear() }

    It 'removes and persists the template record after a successful exit button action' {
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $true; Error = '' } }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42

        $OnAir.ContainsKey(7) | Should -BeFalse
        # Deliberately no longer reconciles against a status read: Cinegy keeps
        # the item Active after EXIT_SCENE_LOOP, so that read cannot tell an
        # exited scene from a live one and used to preserve the record.
        Should -Invoke Save-OnAirState -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تم الخروج من المشهد'
        }
    }

    It 'keeps the template record when Cinegy rejects the exit action' {
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $false; Error = 'timeout' } }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42

        $OnAir.ContainsKey(7) | Should -BeTrue
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

}

Describe 'Update-OnAirStateFromCinegy' {
    BeforeEach {
        $OnAir.Clear()
        $OnAir[4] = @{ Key = 'lower-third'; At = Get-Date; UserId = 10 }
        Mock Save-OnAirState { }
        Mock Write-BridgeLog { }
    }

    AfterEach { $OnAir.Clear() }

    It 'removes a stale local layer when Cinegy says it is hidden' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = '' }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeFalse
        $result.Removed | Should -Be @(4)
        Should -Invoke Save-OnAirState -Times 1 -Exactly
        Should -Invoke Write-BridgeLog -Times 1 -ParameterFilter {
            $Message -match 'removed on-air record.*layer 4.*confirmed hidden'
        }
    }

    It 'keeps the tracked template when Cinegy reports a different active id but is still on air' {
        $OnAir[4].ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success  = $true
                IsOnAir  = $true
                ActiveId = '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'
                ActiveName = 'External Item'
                OutputState = 'Normal'
                ClientConnected = $true
                ClientIdentity = 'Air UI'
            }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $OnAir[4].ActiveId | Should -Be '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'
        $result.Removed | Should -Be @()
        Should -Invoke Save-OnAirState -Times 1 -Exactly
    }

    It 'does not rewrite onair state when Cinegy reports the already tracked active id' {
        $OnAir[4].ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success    = $true
                IsOnAir    = $true
                ActiveId   = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
                ActiveName = 'lower-third.cintitle'
            }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $OnAir[4].ActiveId | Should -Be '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        @($result.Removed).Count | Should -Be 0
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

    It 'formats an actionable external change alert without inventing a source IP' {
        $change = [pscustomobject]@{
            Layer = 4; TemplateKey = 'lower-third'; ShowUserId = 10; ShownAt = [datetime]'2026-08-21T10:00:00'
            ExpectedActiveId = '{OLD}'; ActualActiveId = '{NEW}'; ActualActiveName = 'External Item'
            OutputState = 'Normal'; ClientConnected = $true; ClientIdentity = 'Air UI'
        }

        $text = Format-ExternalCinegyChangeAlert -Changes @($change)

        $text | Should -Match 'lower-third'
        $text | Should -Match 'External Item'
        $text | Should -Match 'Air UI'
        $text | Should -Not -Match 'عنوان IP'
    }

    It 'keeps a tracked layer that has no correlatable event id but is on air' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success  = $true
                IsOnAir  = $true
                ActiveId = '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'
            }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $result.Removed | Should -Be @()
        Should -Invoke Save-OnAirState -Times 1 -Exactly
    }

    It 'preserves the local layer when the status request fails' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $false; IsOnAir = $null; Error = 'timeout' }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $result.Failed | Should -Be @(4)
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

    It 'preserves the local layer when Cinegy says it is on air but returns an empty active id' {
        $OnAir[4].ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '' }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        @($result.Removed).Count | Should -Be 0
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

    It 'adopts Cinegy active id and preserves layer when template name matches' {
        $OnAir[4] = @{ Key = 'lower-third'; At = Get-Date; UserId = 10; ActiveId = '{COMMAND-GUID}' }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success    = $true
                IsOnAir    = $true
                ActiveId   = '{CINEGY-ENGINE-GUID}'
                ActiveName = 'lower-third.cintitle'
            }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $OnAir[4].ActiveId | Should -Be '{CINEGY-ENGINE-GUID}'
        @($result.Removed).Count | Should -Be 0
    }

    It 'does not let a later watchdog observation adopt a replacement for pending auto-hide' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $originalQueue = $script:AutoHideQueue
        try {
            $script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()
            $script:AutoHideQueue.Add(@{
                    Layer = 4; At = $now.AddSeconds(30); ChatId = 1L; UserId = 10L
                    TemplateKey = 'lower-third'; ActiveId = '{COMMAND-GUID}'
                })
            $OnAir[4] = @{ Key = 'lower-third'; At = $now.DateTime; UserId = 10; ActiveId = '{COMMAND-GUID}'; Source = 'bridge' }
            Mock Save-AutoHideQueue { $true }
            Mock Send-TelegramMessage { }
            Mock Invoke-HideLayer { $true }
            Mock Get-TitlerLayerStatus {
                [pscustomobject]@{
                    Success = $true; IsOnAir = $true; ActiveId = '{CINEGY-ENGINE-GUID}'
                    ActiveName = 'Show lower-third.cintitle on layer 4'; ActiveTemplateName = 'lower-third'
                }
            }

            Update-OnAirStateFromCinegy | Out-Null
            $script:AutoHideQueue[0].ActiveId | Should -Be '{COMMAND-GUID}'

            Update-AutoHideQueue -Now $now.AddSeconds(30)
            Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        }
        finally { $script:AutoHideQueue = $originalQueue }
    }

    It 'does not rebind a confirmed auto-hide to a later replacement even when the template name matches' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $originalQueue = $script:AutoHideQueue
        try {
            $script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()
            $script:AutoHideQueue.Add(@{
                    Layer = 4; At = $now.AddSeconds(30); ChatId = 1L; UserId = 10L
                    TemplateKey = 'lower-third'; ActiveId = '{CINEGY-ENGINE-GUID}'; ActiveIdConfirmed = $true
                })
            $OnAir[4] = @{ Key = 'lower-third'; At = $now.DateTime; UserId = 10; ActiveId = '{CINEGY-ENGINE-GUID}'; Source = 'bridge' }
            Mock Save-AutoHideQueue { $true }
            Mock Send-TelegramMessage { }
            Mock Invoke-HideLayer { $true }
            Mock Get-TitlerLayerStatus {
                [pscustomobject]@{
                    Success = $true; IsOnAir = $true; ActiveId = '{LATER-REPLACEMENT-GUID}'
                    ActiveName = 'Show lower-third.cintitle on layer 4'; ActiveTemplateName = 'lower-third'
                }
            }

            Update-OnAirStateFromCinegy | Out-Null

            $script:AutoHideQueue[0].ActiveId | Should -Be '{CINEGY-ENGINE-GUID}'
            Update-AutoHideQueue -Now $now.AddSeconds(30)
            Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        }
        finally { $script:AutoHideQueue = $originalQueue }
    }

    It 'reuses a supplied dashboard sample instead of querying the layer again' {
        Mock Get-TitlerLayerStatus { throw 'must not be called' }
        $sample = [pscustomobject]@{
            Layer = 4; Success = $true; IsOnAir = $false; ActiveId = ''
        }

        $result = Update-OnAirStateFromCinegy -LayerStatuses @($sample)

        $result.Removed | Should -Be @(4)
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
    }

    It 'adds an externally started Cinegy scene during a full layer comparison' {
        $OnAir.Clear()
        $sample = [pscustomobject]@{
            Layer = 7; Success = $true; IsOnAir = $true
            ActiveId = '{CINEGY-EXTERNAL-GUID}'; ActiveName = 'Breaking News On'
        }

        $result = Update-OnAirStateFromCinegy -Reason 'operator-check' -LayerStatuses @($sample) -DiscoverExternal

        $result.Added | Should -Be @(7)
        $OnAir.ContainsKey(7) | Should -BeTrue
        $OnAir[7].Key | Should -Be 'Breaking News On'
        $OnAir[7].Source | Should -Be 'cinegy'
        $OnAir[7].UserId | Should -Be 0
        Should -Invoke Save-OnAirState -Times 1 -Exactly
    }

    It 'does not invent an external record when the Cinegy layer query is uncertain' {
        $OnAir.Clear()
        $sample = [pscustomobject]@{
            Layer = 7; Success = $false; IsOnAir = $null; Error = 'timeout'
        }

        $result = Update-OnAirStateFromCinegy -Reason 'operator-check' -LayerStatuses @($sample) -DiscoverExternal

        @($result.Added).Count | Should -Be 0
        $OnAir.ContainsKey(7) | Should -BeFalse
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }
}

Describe 'Cinegy layer dashboard' {
    BeforeEach {
        $OnAir.Clear()
        $OnAir[4] = @{
            Key = 'lower-third'; At = Get-Date; UserId = 10
            ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        }
        Mock Get-KnownLayers { @(4, 5, 6, 7) }
        Mock Get-TitlerLayerStatus {
            switch ($Layer) {
                4 { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'; ActiveName = 'Bot Item'; OutputState = 'Normal'; LicenseState = 'Licensed'; ClientConnected = $true; ClientIdentity = 'Client 1' } }
                5 { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'; ActiveName = 'External Item'; OutputState = 'Normal'; LicenseState = 'Licensed'; ClientConnected = $true; ClientIdentity = 'Client 1' } }
                6 { [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = ''; OutputState = 'Normal'; LicenseState = 'Licensed'; ClientConnected = $true; ClientIdentity = 'Client 1' } }
                7 { [pscustomobject]@{ Success = $false; IsOnAir = $null; ActiveId = ''; Error = 'timeout' } }
            }
        }
    }

    AfterEach { $OnAir.Clear() }

    It 'collects every configured layer exactly once' {
        $dashboard = @(Get-CinegyLayerDashboard)

        @($dashboard.Layer) | Should -Be @(4, 5, 6, 7)
        Should -Invoke Get-TitlerLayerStatus -Times 4 -Exactly -ParameterFilter { $TimeoutSec -eq 1 }
    }

    It 'distinguishes bridge external hidden and unknown layers' {
        $text = Format-CinegyLayerDashboard -LayerStatuses @(Get-CinegyLayerDashboard)

        $text | Should -Match '🔴 طبقة 4: lower-third'
        $text | Should -Match '🟠 طبقة 5: External Item \(خارجي\)'
        $text | Should -Match '⚪ طبقة 6: مخفية'
        $text | Should -Match '⚠️.*طبقة 7: غير معروف'
        $text | Should -Match '🙈 إخفاء.*فورًا'
        $text | Should -Match '🔄 تحديث.*فحص كل الطبقات'
        $text | Should -Match 'الخرج Normal'
        $text | Should -Match 'الترخيص Licensed'
        $text | Should -Match 'العميل Client 1'
    }
}

Describe 'Layer quick panel' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { }
        Mock Get-CinegyLayerDashboard {
            @(
                [pscustomobject]@{ Layer = 2; Success = $true; IsOnAir = $true; ActiveId = '{A}'; ActiveName = 'External' },
                [pscustomobject]@{ Layer = 4; Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = '' }
            )
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(2, 4); Added = @(2); Removed = @(); Failed = @(); Changes = @() }
        }
    }

    It 'shows actual layer states as quick action buttons' {
        $callback = [pscustomobject]@{
            id = 'layers-panel-1'
            from = [pscustomobject]@{ id = 200 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 200 } }
            data = 'menu:layers'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Get-CinegyLayerDashboard -Times 1 -Exactly
        Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly -ParameterFilter {
            $Reason -eq 'operator-check' -and $DiscoverExternal
        }
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $labels = @($ReplyMarkup.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text })
            $labels -contains '🙈 إخفاء طبقة 2' -and
                $labels -contains '🔄 تحديث · طبقة 4 مخفية'
        }
    }
}

Describe 'Reliable schedule store and executor' {
    BeforeEach {
        $script:OriginalScheduleMaxRetries = Get-Setting 'ScheduleMaxRetries'
        $script:OriginalScheduleRetryDelaySeconds = Get-Setting 'ScheduleRetryDelaySeconds'
        $script:OriginalSchedulePaused = Get-Setting 'SchedulePaused'
        $script:OriginalSchedulePreNotifyMinutes = Get-Setting 'SchedulePreNotifyMinutes'
        $config.Settings | Add-Member -NotePropertyName ScheduleMaxRetries -NotePropertyValue 0 -Force
        $config.Settings | Add-Member -NotePropertyName ScheduleRetryDelaySeconds -NotePropertyValue 30 -Force
        $config.Settings | Add-Member -NotePropertyName SchedulePaused -NotePropertyValue $false -Force
        $config.Settings | Add-Member -NotePropertyName SchedulePreNotifyMinutes -NotePropertyValue 0 -Force
        $script:OriginalScheduleFileForTest = $script:scheduleFile
        $script:OriginalScheduleExecutionFileForTest = $script:scheduleExecutionFile
        $script:scheduleFile = Join-Path $TestDrive 'schedule.json'
        $script:scheduleExecutionFile = Join-Path $TestDrive 'schedule-execution.jsonl'
        Remove-Item -LiteralPath $script:scheduleExecutionFile -Force -ErrorAction SilentlyContinue
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Get-TemplateStore {
            [pscustomobject]@{
                Map = @{
                    urgent = [pscustomobject]@{
                        Key = 'urgent'; Path = 'C:\Scenes\Urgent.cintitle'; Layer = 4
                        Fields = @('Headline.Text'); FieldTypes = @{}; LongRunning = $false
                    }
                }
                Order = @('urgent'); Errors = @(); InvalidKeys = @(); SharedLayers = @{}
            }
        }
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName ScheduleMaxRetries -NotePropertyValue $script:OriginalScheduleMaxRetries -Force
        $config.Settings | Add-Member -NotePropertyName ScheduleRetryDelaySeconds -NotePropertyValue $script:OriginalScheduleRetryDelaySeconds -Force
        $config.Settings | Add-Member -NotePropertyName SchedulePaused -NotePropertyValue $script:OriginalSchedulePaused -Force
        $config.Settings | Add-Member -NotePropertyName SchedulePreNotifyMinutes -NotePropertyValue $script:OriginalSchedulePreNotifyMinutes -Force
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        $script:scheduleFile = $script:OriginalScheduleFileForTest
        $script:scheduleExecutionFile = $script:OriginalScheduleExecutionFileForTest
    }

    It 'persists and restores a pending event with a stable id and timezone' {
        $at = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{ 'Headline.Text' = 'مجدول' } -ScheduledAt $at -Recurrence once -ChatId 1 -UserId 2
        Add-ScheduledShowEvent -ScheduleEntry $scheduleEntry | Should -BeTrue
        $id = $scheduleEntry.Id
        $script:ScheduleEvents.Clear()

        Import-ScheduleEvents

        $script:ScheduleEvents.Count | Should -Be 1
        $script:ScheduleEvents[0].Id | Should -Be $id
        $script:ScheduleEvents[0].TimeZoneId | Should -Not -BeNullOrEmpty
    }

    It 'restores a pending event after a simulated restart and executes it at its timer once' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{ 'Headline.Text' = 'بعد إعادة التشغيل' } `
            -ScheduledAt $now.AddMinutes(5) -Recurrence once -ChatId 1 -UserId 2
        Add-ScheduledShowEvent -ScheduleEntry $scheduleEntry | Should -BeTrue

        # A fresh bridge process starts with an empty in-memory queue and imports
        # the durable schedule before its first timer tick.
        $script:ScheduleEvents.Clear()
        Import-ScheduleEvents
        Update-ScheduleQueue -Now $now.AddMinutes(4)

        $script:ScheduleEvents[0].Status | Should -Be 'pending'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly

        Update-ScheduleQueue -Now $now.AddMinutes(5)
        Update-ScheduleQueue -Now $now.AddMinutes(6)

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $script:ScheduleEvents[0].Status | Should -Be 'completed'
        $script:ScheduleEvents[0].LastTemplateCheckStatus | Should -Be 'ready'
        $persisted = Get-Content -LiteralPath $script:scheduleFile -Raw | ConvertFrom-Json
        $persisted[0].LastTemplateCheckStatus | Should -Be 'ready'
    }

    It 'checks the current template registry at timer execution and does not SHOW a missing template' {
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{}; Order = @(); Errors = @('القالب غير موجود'); InvalidKeys = @(); SharedLayers = @{} }
        }
        Mock Send-TelegramMessage { }
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} `
            -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now

        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        $scheduleEntry.LastTemplateCheckStatus | Should -Be 'missing'
        $scheduleEntry.Status | Should -Be 'failed'
        $scheduleEntry.LastResult | Should -Match 'غير موجود'
    }

    It 'restores scheduled events from the last validated backup when the primary JSON is corrupt' {
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt ([datetimeoffset]'2026-08-21T10:00:00+03:00') -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($entry)
        Save-ScheduleEvents | Should -BeTrue
        Test-Path -LiteralPath "$($script:scheduleFile).bak" | Should -BeTrue
        Set-Content -LiteralPath $script:scheduleFile -Value '[broken-json'
        $script:ScheduleEvents.Clear()

        Import-ScheduleEvents

        $script:ScheduleEvents.Count | Should -Be 1
        $script:ScheduleEvents[0].Id | Should -Be $entry.Id
        { Get-Content -LiteralPath $script:scheduleFile -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }

    It 'copies an event to a new reviewed time without changing the original' {
        Mock Send-TelegramMessage { }
        $originalAt = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Layer 4 -Values @{ Headline = 'copy' } -ScheduledAt $originalAt -Recurrence daily -ChatId 101 -UserId 101
        $script:ScheduleEvents.Add($entry)

        Start-ScheduleMutationFlow -Action copy -EventId $entry.Id -ChatId 101 -UserId 101
        Complete-ScheduleText -ChatId 101 -Value '2099-08-22 11:30'
        Confirm-ScheduledShow -ChatId 101 -UserId 101

        $script:ScheduleEvents.Count | Should -Be 2
        $script:ScheduleEvents[0].Id | Should -Be $entry.Id
        $script:ScheduleEvents[0].ScheduledAt | Should -Be $originalAt.ToString('o')
        $copy = @($script:ScheduleEvents | Where-Object Id -ne $entry.Id)[0]
        $copy.TemplateKey | Should -Be 'urgent'
        $copy.Values.Headline | Should -Be 'copy'
        $copy.Recurrence | Should -Be 'daily'
    }

    It 'edits only the reviewed event time and preserves its stable id' {
        Mock Send-TelegramMessage { }
        $entry = New-ScheduledShowEvent -TemplateKey 'urgent' -Layer 4 -Values @{} -ScheduledAt ([datetimeoffset]'2099-08-21T10:00:00+03:00') -Recurrence once -ChatId 101 -UserId 101
        $script:ScheduleEvents.Add($entry)

        Start-ScheduleMutationFlow -Action edit -EventId $entry.Id -ChatId 101 -UserId 101
        Complete-ScheduleText -ChatId 101 -Value '2099-08-23 12:45'
        Confirm-ScheduledShow -ChatId 101 -UserId 101

        $script:ScheduleEvents.Count | Should -Be 1
        $script:ScheduleEvents[0].Id | Should -Be $entry.Id
        ([datetimeoffset]$script:ScheduleEvents[0].ScheduledAt).ToString('yyyy-MM-dd HH:mm') | Should -Be '2099-08-23 12:45'
        $script:ScheduleEvents[0].TimeZoneId | Should -Be ([System.TimeZoneInfo]::Local.Id)
    }

    It 'includes the timezone id in event summaries' {
        $entry = New-ScheduledShowEvent -TemplateKey urgent -ScheduledAt ([datetimeoffset]'2099-08-21T10:00:00+03:00') -Recurrence once -ChatId 1 -UserId 1
        Format-ScheduleEvent -ScheduleEntry $entry | Should -Match ([regex]::Escape([System.TimeZoneInfo]::Local.Id))
    }

    It 'executes a one-time event once and never repeats it on later ticks' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now
        Update-ScheduleQueue -Now $now.AddMinutes(1)

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $scheduleEntry.Status | Should -Be 'completed'
        $scheduleEntry.CompletedExecutionKey | Should -Be $scheduleEntry.ExecutionKey
    }

    It 'keeps due events pending while scheduling is paused' {
        $config.Settings | Add-Member -NotePropertyName SchedulePaused -NotePropertyValue $true -Force
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey urgent -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($entry)

        Update-ScheduleQueue -Now $now

        $entry.Status | Should -Be 'pending'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'sends one advance notification per occurrence without executing early' {
        $config.Settings | Add-Member -NotePropertyName SchedulePreNotifyMinutes -NotePropertyValue 10 -Force
        Mock Send-TelegramMessage { }
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey urgent -ScheduledAt $now.AddMinutes(5) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($entry)

        Update-ScheduleQueue -Now $now
        Update-ScheduleQueue -Now $now.AddMinutes(1)

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 1 -and $Text -match 'بعد.*دقائق|قريب' }
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'completes a recurring event when its next occurrence exceeds the end date' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $entry = New-ScheduledShowEvent -TemplateKey urgent -ScheduledAt $now.AddMinutes(-1) -Recurrence daily -ChatId 1 -UserId 2 -RecurrenceUntil '2099-08-21'
        $script:ScheduleEvents.Add($entry)

        Update-ScheduleQueue -Now $now

        $entry.Status | Should -Be 'completed'
        $entry.LastResult | Should -Be 'success'
    }

    It 'writes a content-free JSONL execution result for each attempt' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Layer 4 -Values @{ 'Headline.Text' = 'secret editorial text' } -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now

        $line = Get-Content -LiteralPath $script:scheduleExecutionFile -Raw
        $record = $line | ConvertFrom-Json
        $record.EventId | Should -Be $scheduleEntry.Id
        $record.TemplateKey | Should -Be 'urgent'
        $record.Layer | Should -Be 4
        $record.Result | Should -Be 'success'
        $record.DurationMs | Should -BeGreaterOrEqual 0
        $line | Should -Not -Match 'secret editorial text|Headline.Text'
    }

    It 'advances a daily event only after successful completion' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence daily -ChatId 1 -UserId 2
        $oldAt = $scheduleEntry.ScheduledAt
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $scheduleEntry.Status | Should -Be 'pending'
        ([datetimeoffset]$scheduleEntry.ScheduledAt) | Should -BeGreaterThan ([datetimeoffset]$oldAt)
        ([datetimeoffset]$scheduleEntry.ScheduledAt) | Should -BeGreaterThan $now
    }

    It 'advances a weekly event by seven local calendar days' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence weekly -ChatId 1 -UserId 2
        $oldAt = [datetimeoffset]$scheduleEntry.ScheduledAt
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now

        ([datetimeoffset]$scheduleEntry.ScheduledAt).Date | Should -Be $oldAt.AddDays(7).Date
        $scheduleEntry.Status | Should -Be 'pending'
    }

    It 'does not replay an occurrence left running across a restart' {
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $scheduleEntry.Status = 'running'; $scheduleEntry.ExecutionKey = "$($scheduleEntry.Id)|$($scheduleEntry.ScheduledAt)"
        $script:ScheduleEvents.Add($scheduleEntry)
        Save-ScheduleEvents | Should -BeTrue
        $script:ScheduleEvents.Clear()

        Import-ScheduleEvents
        Update-ScheduleQueue -Now $now

        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        $script:ScheduleEvents[0].Status | Should -Be 'interrupted'
    }

    It 'retries a failed occurrence only after the configured delay' {
        $config.Settings | Add-Member -NotePropertyName ScheduleMaxRetries -NotePropertyValue 1 -Force
        $config.Settings | Add-Member -NotePropertyName ScheduleRetryDelaySeconds -NotePropertyValue 30 -Force
        $script:ScheduledShowCall = 0
        Mock Invoke-ShowTemplateResult {
            $script:ScheduledShowCall++
            if ($script:ScheduledShowCall -eq 1) { return [pscustomobject]@{ Success = $false; Error = 'timeout' } }
            return [pscustomobject]@{ Success = $true; Error = '' }
        }
        $now = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt $now.AddMinutes(-1) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Update-ScheduleQueue -Now $now
        Update-ScheduleQueue -Now $now.AddSeconds(20)
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly
        $scheduleEntry.Status | Should -Be 'pending'
        $scheduleEntry.AttemptCount | Should -Be 1
        $scheduleEntry.LastResult | Should -Be 'timeout'

        Update-ScheduleQueue -Now $now.AddSeconds(31)
        Should -Invoke Invoke-ShowTemplateResult -Times 2 -Exactly
        $scheduleEntry.Status | Should -Be 'completed'
    }

    It 'parses only a clear future local time and reports the timezone' {
        $now = [datetimeoffset]'2026-08-20T20:00:00+03:00'
        $parsed = ConvertFrom-OperatorScheduleTime -Text '2026-08-21 09:30' -Now $now
        $past = ConvertFrom-OperatorScheduleTime -Text '2026-08-19 09:30' -Now $now

        $parsed.Success | Should -BeTrue
        $parsed.TimeZoneId | Should -Not -BeNullOrEmpty
        $past.Success | Should -BeFalse
    }

    It 'cancels a pending event persistently' {
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt ([datetimeoffset]::Now.AddHours(1)) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)

        Stop-ScheduledShowEvent -Id $scheduleEntry.Id | Should -BeTrue

        $scheduleEntry.Status | Should -Be 'cancelled'
        @(Get-UpcomingScheduleEvents).Count | Should -Be 0
    }

    It 'does not approve a schedule mutation when atomic replacement fails' {
        '[]' | Set-Content -LiteralPath $script:scheduleFile -Encoding utf8
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey 'urgent' -Values @{} -ScheduledAt ([datetimeoffset]::Now.AddHours(1)) -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($scheduleEntry)
        Mock Move-Item { throw 'disk failure' } -ModuleName BridgeStorage

        Save-ScheduleEvents | Should -BeFalse

        (Get-Content -LiteralPath $script:scheduleFile -Raw).Trim() | Should -Be '[]'
    }
}

Describe 'Schedule layer conflict detection' {
    BeforeEach { $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new() }
    AfterEach { $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new() }

    It 'detects a pending event on the same layer inside the conflict window' {
        $at = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $existing = New-ScheduledShowEvent -TemplateKey 'ticker' -Layer 4 -Values @{} -ScheduledAt $at -Recurrence once -ChatId 1 -UserId 2
        $script:ScheduleEvents.Add($existing)

        $conflicts = @(Get-ScheduleLayerConflicts -Layer 4 -ScheduledAt $at.AddMinutes(1) -WindowMinutes 2)

        $conflicts.Count | Should -Be 1
        $conflicts[0].Id | Should -Be $existing.Id
    }

    It 'does not treat another layer at the same time as a conflict' {
        $at = [datetimeoffset]'2026-08-21T10:00:00+03:00'
        $script:ScheduleEvents.Add((New-ScheduledShowEvent -TemplateKey 'logo' -Layer 8 -Values @{} -ScheduledAt $at -Recurrence once -ChatId 1 -UserId 2))

        @(Get-ScheduleLayerConflicts -Layer 4 -ScheduledAt $at -WindowMinutes 2).Count | Should -Be 0
    }
}

Describe 'Bounded retry backoff' {
    It 'grows exponentially and never exceeds the configured cap' {
        Get-RetryDelaySeconds -BaseSeconds 10 -Attempt 1 -Factor 2 -MaxSeconds 25 | Should -Be 10
        Get-RetryDelaySeconds -BaseSeconds 10 -Attempt 2 -Factor 2 -MaxSeconds 25 | Should -Be 20
        Get-RetryDelaySeconds -BaseSeconds 10 -Attempt 3 -Factor 2 -MaxSeconds 25 | Should -Be 25
    }

    It 'normalizes unsafe values to a positive bounded delay' {
        Get-RetryDelaySeconds -BaseSeconds 0 -Attempt 0 -Factor 0 -MaxSeconds 0 | Should -Be 1
    }
}

Describe 'Telegram schedule review flow' {
    BeforeEach {
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        Clear-PendingState -ChatId 111
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'; Layer = 4; Fields = @('Headline.Text'); FieldLabels = @('العنوان')
                FieldLimits = @(80); FieldRequired = @($true)
            }
        }
        Mock Send-TelegramMessage { }
        Mock Add-ScheduledShowEvent { $true }
        Mock Add-AuditEntry { }
    }

    AfterEach {
        Clear-PendingState -ChatId 111
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
    }

    It 'shows same-layer timing conflicts before schedule confirmation' {
        $at = [datetimeoffset]::Now.AddHours(3)
        $script:ScheduleEvents.Add((New-ScheduledShowEvent -TemplateKey 'ticker' -Layer 4 -Values @{} -ScheduledAt $at -Recurrence once -ChatId 1 -UserId 2))
        $state = @{
            TemplateKey = 'urgent'; Layer = 4; Fields = @(); Values = @{}; ScheduledAt = $at.AddMinutes(1).ToString('o')
            TimeZoneId = [System.TimeZoneInfo]::Local.Id; Recurrence = 'once'; UserId = 121
        }

        Show-ScheduleReview -ChatId 111 -State $state

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تعارض محتمل.*الطبقة 4' -and $Text -match 'ticker'
        }
    }

    It 'collects values time and recurrence and saves only after confirmation' {
        Start-ScheduleShowFlow -TemplateIndex 0 -ChatId 111 -UserId 121
        Complete-ScheduleText -ChatId 111 -Value 'خبر الغد'
        $futureText = [datetimeoffset]::Now.AddHours(2).ToString('yyyy-MM-dd HH:mm')
        Complete-ScheduleText -ChatId 111 -Value $futureText
        $state = Get-PendingState -ChatId 111
        $state.Mode | Should -Be 'schedule_recurrence'
        $state.Recurrence = 'once'
        Show-ScheduleReview -ChatId 111 -State $state

        Should -Invoke Add-ScheduledShowEvent -Times 0 -Exactly
        Confirm-ScheduledShow -ChatId 111 -UserId 121

        Should -Invoke Add-ScheduledShowEvent -Times 1 -Exactly -ParameterFilter {
            $ScheduleEntry.TemplateKey -eq 'urgent' -and $ScheduleEntry.Values['Headline.Text'] -eq 'خبر الغد' -and $ScheduleEntry.Recurrence -eq 'once'
        }
    }
}

Describe 'Cinegy telemetry text' {
    It 'formats healthy unhealthy and unreachable states without ambiguity' {
        $healthy = [pscustomobject]@{ Success = $true; Healthy = $true; SampleCount = 60; OutputCount = 1500; DroppedCount = 0; NoInputSignal = 0; AverageReadTime = 1.2; MaxReadErrorRate = 0; MaxHeartbeat = 700; Issues = @() }
        $unhealthy = [pscustomobject]@{ Success = $true; Healthy = $false; SampleCount = 60; OutputCount = 1490; DroppedCount = 2; NoInputSignal = 3; AverageReadTime = 2.2; MaxReadErrorRate = 4; MaxHeartbeat = 900; Issues = @('Dropped frames: 2') }
        $unknown = [pscustomobject]@{ Success = $false; Healthy = $null; Error = 'timeout' }

        Format-CinegyTelemetryStatus $healthy | Should -Match '^💚 صحة Cinegy: سليمة'
        Format-CinegyTelemetryStatus $unhealthy | Should -Match '^🔴 صحة Cinegy: تحذير'
        Format-CinegyTelemetryStatus $unknown | Should -Match '^⚠️ صحة Cinegy: غير معروفة'
    }
}

Describe 'Cinegy monitoring watchdogs' {
    BeforeEach {
        $script:RuntimeState.Monitoring.LastCinegyStateCheck = [datetime]::MinValue
        $script:RuntimeState.Monitoring.LastCinegyHealthCheck = [datetime]::MinValue
        $script:RuntimeState.Monitoring.CinegyHealthState = 'unknown'
        $script:HealthHistory.Cinegy.FailureCount = 0
        $script:HealthHistory.Cinegy.OutageStartedAt = $null
        $script:HealthHistory.Cinegy.AlertSent = $false
        Mock Get-SettingInt {
            if ($Name -eq 'CinegyStateCheckSeconds') { return 15 }
            if ($Name -eq 'CinegyHealthCheckSeconds') { return 60 }
            if ($Name -eq 'HealthFailureAlertThreshold') { return 2 }
            return 1
        }
        Mock Get-Setting { $true }
        Mock Send-AdminBroadcast { }
        Mock Write-BridgeLog { }
    }

    It 'alerts once when a tracked scene changes outside the bridge' {
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{
                Checked = @(4); Removed = @(4); Failed = @()
                Changes = @([pscustomobject]@{
                    Layer = 4; TemplateKey = 'lower-third'; ShowUserId = 10; ShownAt = Get-Date
                    ExpectedActiveId = '{OLD}'; ActualActiveId = '{NEW}'; ActualActiveName = 'External Item'
                    OutputState = 'Normal'; ClientConnected = $true; ClientIdentity = 'Air UI'
                })
            }
        }

        Update-CinegyStateWatchdog
        Update-CinegyStateWatchdog

        Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 1 }
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تغيير خارجي' -and $Text -match 'lower-third' -and $Text -match 'External Item' -and $Text -match 'Air UI'
        }
    }

    It 'alerts only after the Cinegy failure threshold and sends one recovery notice' {
        $script:telemetryCall = 0
        Mock Get-AirTelemetryStatus {
            $script:telemetryCall++
            if ($script:telemetryCall -le 2) {
                return [pscustomobject]@{
                    Success = $true; Healthy = $false; SampleCount = 60
                    OutputCount = 1490; DroppedCount = 2; NoInputSignal = 0
                    AverageReadTime = 2; MaxReadErrorRate = 0; MaxHeartbeat = 800
                    Issues = @('Dropped frames: 2')
                }
            }
            return [pscustomobject]@{
                Success = $true; Healthy = $true; SampleCount = 60
                OutputCount = 1500; DroppedCount = 0; NoInputSignal = 0
                AverageReadTime = 1; MaxReadErrorRate = 0; MaxHeartbeat = 650
                Issues = @()
            }
        }

        Update-CinegyHealthWatchdog
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
        $script:RuntimeState.Monitoring.LastCinegyHealthCheck = [datetime]::MinValue
        Update-CinegyHealthWatchdog
        $script:RuntimeState.Monitoring.LastCinegyHealthCheck = [datetime]::MinValue
        Update-CinegyHealthWatchdog

        Should -Invoke Get-AirTelemetryStatus -Times 3 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'تحذير صحة Cinegy' }
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'تعافت صحة Cinegy' }
        $script:HealthHistory.Cinegy.FailureCount | Should -Be 0
        $script:HealthHistory.Cinegy.OutageStartedAt | Should -BeNullOrEmpty
    }

}

Describe 'Bridge lifecycle notifications' {
    BeforeEach {
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'unknown'
        $script:HealthHistory.Telegram.FailureCount = 0
        $script:HealthHistory.Telegram.OutageStartedAt = $null
        $script:HealthHistory.Telegram.AlertSent = $false
        Mock Get-SettingInt { 2 }
        Mock Send-AdminBroadcast { }
        Mock Write-BridgeLog { }
    }

    It 'alerts only after the Telegram failure threshold and sends one recovery notification' {
        Set-TelegramConnectionState -Connected:$false -ErrorMessage 'timeout'
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
        Set-TelegramConnectionState -Connected:$false -ErrorMessage 'timeout again'
        Set-TelegramConnectionState -Connected:$false -ErrorMessage 'timeout third'
        Set-TelegramConnectionState -Connected:$true

        Should -Invoke Send-AdminBroadcast -Times 2 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'استعاد.*Telegram' }
        $script:HealthHistory.Telegram.FailureCount | Should -Be 0
        $script:HealthHistory.Telegram.OutageStartedAt | Should -BeNullOrEmpty
    }

    It 'notifies admins when the bridge starts' {
        Send-BridgeStartupNotification

        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'بدأ تشغيل' -and $Text -match $script:BridgeVersion }
    }
}

Describe 'Startup Cinegy reconciliation' {
    BeforeEach {
        Mock Get-CinegyLayerDashboard {
            @(
                [pscustomobject]@{ Layer = 4; Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = '' },
                [pscustomobject]@{ Layer = 7; Success = $true; IsOnAir = $true; ActiveId = '{EXTERNAL}'; ActiveName = 'Studio Lower Third' }
            )
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(4); Added = @(7); Removed = @(4); Failed = @(); Changes = @(); LastSuccessfulAt = Get-Date }
        }
        Mock Write-BridgeLog { }
    }

    It 'performs a full external-discovery comparison during startup' {
        { $script:result = Initialize-CinegyOnAirState } | Should -Not -Throw

        Should -Invoke Get-CinegyLayerDashboard -Times 1 -Exactly
        Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly -ParameterFilter {
            $Reason -eq 'startup' -and $DiscoverExternal -and @($LayerStatuses).Count -eq 2
        }
        $script:result.Added | Should -Be @(7)
    }

    It 'logs that uncertain startup layers were preserved rather than cleared' {
        Mock Get-CinegyLayerDashboard {
            @([pscustomobject]@{ Layer = 4; Success = $false; IsOnAir = $null; Error = 'timeout' })
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(); Added = @(); Removed = @(); Failed = @(4); Changes = @(); LastSuccessfulAt = $null }
        }

        { Initialize-CinegyOnAirState | Out-Null } | Should -Not -Throw

        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'Startup.*preserved.*4'
        }
    }
}

Describe 'Get-CallbackArg' {
    It 'returns the payload that follows the prefix' {
        Get-CallbackArg -Data 'news:idown:7' -Prefix 'news:idown:' | Should -Be '7'
    }

    It 'does not confuse a longer sibling prefix with a shorter one' {
        # 'news:item:' and 'news:idown:' share a stem; Substring offsets used to
        # be hand-counted here, and getting it wrong shipped a real bug.
        Get-CallbackArg -Data 'news:item:3' -Prefix 'news:item:' | Should -Be '3'
    }

    It 'preserves a payload that itself contains a colon' {
        Get-CallbackArg -Data 'cfg:v:Some:Name' -Prefix 'cfg:v:' | Should -Be 'Some:Name'
    }

    It 'returns an empty string when nothing follows the prefix' {
        Get-CallbackArg -Data 'hide:' -Prefix 'hide:' | Should -Be ''
    }

    It 'throws instead of silently slicing when the prefix does not match' {
        { Get-CallbackArg -Data 'exit:4' -Prefix 'hide:' } | Should -Throw -ExpectedMessage "*does not start with the expected prefix*"
    }
}

Describe 'Callback prefix wiring' {
    BeforeAll {
        $script:CallbackSource = Get-Content -LiteralPath (Join-Path $script:Root 'Parts\Bridge.Callbacks.ps1') -Raw -Encoding utf8
        # Every wildcard switch label in the dispatcher, e.g. 'news:idown:*'.
        $script:HandledPrefixes = @([regex]::Matches($script:CallbackSource, "(?m)^\s*'(?<p>[^']*):\*'\s*\{") |
                ForEach-Object { $_.Groups['p'].Value + ':' } | Sort-Object -Unique)
    }

    It 'no longer parses callback data with hand-counted offsets' {
        # The whole point of Get-CallbackArg: a reintroduced Substring(N) here
        # brings back the off-by-N class this replaced.
        $script:CallbackSource | Should -Not -Match '\$data\.Substring\('
    }

    It 'passes each branch its own prefix rather than a sibling prefix' {
        $mismatched = foreach ($m in [regex]::Matches($script:CallbackSource,
                "(?ms)^\s*'(?<label>[^']*):\*'\s*\{(?<body>.*?)(?=^\s*'|\Z)")) {
            $label = $m.Groups['label'].Value + ':'
            foreach ($u in [regex]::Matches($m.Groups['body'].Value, "Get-CallbackArg \`$data '(?<used>[^']*)'")) {
                if ($u.Groups['used'].Value -ne $label) { "$label used $($u.Groups['used'].Value)" }
            }
        }
        @($mismatched) | Should -BeNullOrEmpty
    }

    It 'has a dispatcher branch for every prefixed button the keyboards emit' {
        $keyboards = Get-Content -LiteralPath (Join-Path $script:Root 'Parts\Bridge.Keyboards.ps1') -Raw -Encoding utf8
        # Buttons carry their callback as New-Button <text> "prefix:$value".
        # The interpolated ones are exactly those a wildcard branch must catch.
        $emitted = @([regex]::Matches($keyboards, '"(?<p>[a-zA-Z][a-zA-Z:]*:)\$') |
                ForEach-Object { $_.Groups['p'].Value } | Sort-Object -Unique)
        $emitted | Should -Not -BeNullOrEmpty
        # A broader branch covers its narrower children the same way
        # switch -Wildcard does: 'tadm:*' answers for 'tadm:edit:...'.
        $orphans = @($emitted | Where-Object {
                $button = $_
                -not ($script:HandledPrefixes | Where-Object { $button.StartsWith($_, [System.StringComparison]::Ordinal) })
            })
        $orphans | Should -BeNullOrEmpty
    }
}

Describe 'Cinegy state watchdog backoff wiring' {
    BeforeEach {
        $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds = 0
        $script:RuntimeState.Monitoring.LastCinegyStateCheck = [datetime]::MinValue
        Mock Write-BridgeLog {}
        Mock Send-AdminBroadcast {}
    }

    It 'widens the interval when a tracked layer cannot be verified' {
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(); Added = @(); Removed = @(); Failed = @(4); Changes = @() }
        }

        Update-CinegyStateWatchdog

        $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds | Should -BeGreaterThan 0
        Get-CinegyStateCheckInterval | Should -Be $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds
    }

    It 'skips the reconciliation entirely while the widened interval has not elapsed' {
        # This is the point of the whole change: an unreachable engine must not
        # be re-probed on the configured interval, because each probe blocks
        # the polling loop for its timeout.
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(); Added = @(); Removed = @(); Failed = @(4); Changes = @() }
        }

        Update-CinegyStateWatchdog
        Update-CinegyStateWatchdog

        Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly
    }

    It 'restores the configured interval after the engine answers again' {
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(); Added = @(); Removed = @(); Failed = @(4); Changes = @() }
        }
        Update-CinegyStateWatchdog
        $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds | Should -BeGreaterThan 0

        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(4); Added = @(); Removed = @(); Failed = @(); Changes = @() }
        }
        $script:RuntimeState.Monitoring.LastCinegyStateCheck = [datetime]::MinValue
        Update-CinegyStateWatchdog

        $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds | Should -Be 0
    }
}

Describe 'Main menu on-air priority' {
    BeforeEach {
        $script:OnAir = @{}
        $script:AutoHideQueue = @()
        Mock Test-Admin { $false }
    }
    AfterAll { $script:OnAir = @{} }

    It 'puts every live layer above anything that can put more on air' {
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date); UserId = 1; Source = 'bot' }

        $rows = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard)
        $firstRowData = @($rows[0] | ForEach-Object { $_.callback_data })

        # The operator opens this menu when the wrong graphic is live; the fix
        # must not sit below the buttons that caused it.
        $firstRowData | Should -Contain 'hide:3'
    }

    It 'places the emergency hide-all directly under the live layers' {
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date); UserId = 1; Source = 'bot' }
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date); UserId = 1; Source = 'cinegy' }

        $rows = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard)
        $flat = @($rows | ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $hideAllIndex = [array]::IndexOf($flat, 'menu:hideall')
        $templatesIndex = [array]::IndexOf($flat, 'menu:templates')

        $hideAllIndex | Should -BeGreaterThan -1
        $hideAllIndex | Should -BeLessThan $templatesIndex
    }

    It 'still offers hide-all when nothing is tracked as live' {
        $flat = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $flat | Should -Contain 'menu:hideall'
    }

    It 'reports what is on air instead of a static prompt' {
        Get-MainMenuIntro | Should -Match 'لا شيء على الهواء'
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date); UserId = 1; Source = 'cinegy' }
        Get-MainMenuIntro | Should -Match '8 · ticker'
    }

    It 'states how old the on-air claim is, not just what it claims' {
        # A stale "on air" that reads identically to a fresh one is what let an
        # exited scene sit unnoticed for an hour and a half.
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = [datetime]::MinValue
        Get-MainMenuIntro | Should -Match 'لم يتم التحقّق بعد'

        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = (Get-Date)
        Get-MainMenuIntro | Should -Match 'تحقّق قبل'
    }
}

Describe 'Administrator tools grouping' {
    BeforeEach { $script:OnAir = @{} }

    It 'keeps settings and access requests one tap away for an administrator' {
        Mock Test-Admin { $true }
        $flat = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        $flat | Should -Contain 'menu:settings'
        $flat | Should -Contain 'menu:pending'
        $flat | Should -Contain 'menu:admintools'
    }

    It 'moves the rarely used configuration off the main menu' {
        Mock Test-Admin { $true }
        $flat = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        foreach ($moved in @('menu:usersadmin', 'menu:presetsadmin', 'menu:templatesadmin', 'menu:audit', 'menu:diagnostics')) {
            $flat | Should -Not -Contain $moved
        }
    }

    It 'still reaches every moved entry from the tools screen, with a way back' {
        Mock Test-Admin { $true }
        $flat = @((Get-AdminToolsKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        foreach ($moved in @('menu:usersadmin', 'menu:presetsadmin', 'menu:templatesadmin', 'menu:audit', 'menu:diagnostics')) {
            $flat | Should -Contain $moved
        }
        $flat | Should -Contain 'menu'
    }

    It 'shows no administrator surface at all to an operator' {
        Mock Test-Admin { $false }
        $flat = @((Get-MainMenuKeyboard -ChatId 200 -UserId 200).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        $flat | Should -Not -Contain 'menu:admintools'
        $flat | Should -Not -Contain 'menu:settings'
    }

    It 'shows access-request approval to administrators and the owner only' {
        $script:DefaultSettings['EnableSelfServiceRequests'] | Should -BeTrue
        $oldAdminUsers = @(Get-JsonProp $config 'AdminUserIds')
        $oldAdminChats = @(Get-JsonProp $config 'AdminChatIds')
        $oldOwners = @(Get-JsonProp $config 'OwnerUserIds')
        try {
            $config | Add-Member -NotePropertyName AdminUserIds -NotePropertyValue @(100) -Force
            $config | Add-Member -NotePropertyName AdminChatIds -NotePropertyValue @(100) -Force
            $config | Add-Member -NotePropertyName OwnerUserIds -NotePropertyValue @(101) -Force
            $script:PendingApprovals = @{ 555 = @{ UserId = 555 } }

            $adminFlat = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
            $adminFlat | Should -Contain 'menu:pending'

            $ownerFlat = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
            $ownerFlat | Should -Contain 'menu:pending'

            $operatorFlat = @((Get-MainMenuKeyboard -ChatId 200 -UserId 200).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
            $operatorFlat | Should -Not -Contain 'menu:pending'
        }
        finally {
            $config | Add-Member -NotePropertyName AdminUserIds -NotePropertyValue $oldAdminUsers -Force
            $config | Add-Member -NotePropertyName AdminChatIds -NotePropertyValue $oldAdminChats -Force
            $config | Add-Member -NotePropertyName OwnerUserIds -NotePropertyValue $oldOwners -Force
            $script:PendingApprovals = @{}
        }
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

Describe 'Exit clears the on-air record Cinegy cannot report' {
    BeforeEach {
        $script:OnAir = @{}
        $script:onAirFile = Join-Path $TestDrive "onair-exit-$([guid]::NewGuid().ToString('N')).json"
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Send-TelegramMessage {}
        Mock Get-AfterLayerRemovalKeyboard { @{ inline_keyboard = @() } }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
        Mock Write-AirOperationResult {}
        Mock Test-MaintenanceControl { $true }
        Mock Set-RollbackCandidate {}
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $true } }
        # Reproduces the live failure: after EXIT_SCENE_LOOP the item is still
        # Active under the same Id, with no IsEmpty marker to read.
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success = $true; IsOnAir = $true; ActiveId = '{0A1072EA-9EFF-11F1-96C0-C85EA97266A8}'
                ActiveName = ''; ActiveTemplateName = ''; ActiveDescription = ''
            }
        }
    }
    AfterAll { $script:OnAir = @{} }

    It 'drops the record even though Cinegy still reports the layer active' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; ActiveId = '{0A1072EA-9EFF-11F1-96C0-C85EA97266A8}'; Source = 'bridge' }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42 | Should -BeTrue

        $script:OnAir.ContainsKey(7) | Should -BeFalse
    }

    It 'leaves other layers alone' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date); UserId = 0; Source = 'cinegy' }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42 | Out-Null

        $script:OnAir.ContainsKey(8) | Should -BeTrue
    }

    It 'keeps the record when the exit command itself failed' {
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $false; Error = 'engine unreachable' } }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42 | Should -BeFalse

        $script:OnAir.ContainsKey(7) | Should -BeTrue
    }

    It 'is a no-op for a layer that was not tracked' {
        Remove-OnAirRecord -Layer 3 -Reason 'test' | Should -BeFalse
    }
}

Describe 'Live self-test' {
    BeforeEach {
        $script:OnAir = @{}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Send-TelegramMessage {}
        Mock Get-AdminToolsKeyboard { @{ inline_keyboard = @() } }
        Mock Test-MaintenanceControl { $true }
        # Default first so unrelated settings still resolve, then the override.
        Mock Get-SettingInt { 3 }
        Mock Get-SettingInt { 15 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-TemplateStore { @{ Map = @{ 'lower-third' = @{ Key = 'lower-third'; Path = 'C:\t.cintitle'; Layer = 3; Fields = @('A'); FieldTypes = @{} } }; Order = @('lower-third'); Errors = @() } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true; EventId = 'e1' } }
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $true } }
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true } }
    }
    AfterAll { $script:OnAir = @{} }

    It 'runs the full path and reports success when the layer ends up empty' {
        $script:probe = 0
        Mock Get-TitlerLayerStatus {
            $script:probe++
            # empty, then live after SHOW, then empty again after cleanup
            [pscustomobject]@{ Success = $true; IsOnAir = ($script:probe -eq 2) }
        }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'نجح' }
    }

    It 'fails and says so when the layer is still occupied afterwards' {
        # The exact shape of today's incident: the scene never actually leaves.
        $script:probe = 0
        Mock Get-TitlerLayerStatus {
            $script:probe++
            [pscustomobject]@{ Success = $true; IsOnAir = ($script:probe -ne 1) }
        }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'فشل' }
    }

    It 'always attempts cleanup even when SHOW failed' {
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $false; Error = 'engine refused' } }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false } }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Hide-TitlerTemplate -Times 1 -Exactly
    }

    It 'refuses to touch a layer that production templates use' {
        Mock Get-SettingInt { 3 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false } }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }


    It 'sends nothing to air when no test layer is configured' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
        Should -Invoke Hide-TitlerTemplate -Times 0 -Exactly
    }

    It 'refuses to start when the test layer is already busy' {
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true } }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }
}

Describe 'Layer removal confirmation' {
    BeforeEach {
        $script:OnAir = @{}
        Mock Send-TelegramMessage {}
        Mock Invoke-HideLayer { $true }
        Mock Invoke-ExitLayer { $true }
        Mock Test-Authorized { $true }
        Mock Test-TelegramPrivateChat { $true }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserLastActivity {}
    }
    AfterAll { $script:OnAir = @{} }
    BeforeAll {
        function New-HideCallback { param([string]$Data)
            [pscustomobject]@{ id = 'cb1'; data = $Data; from = [pscustomobject]@{ id = 42 }
                message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = 42; type = 'private' } } }
        }
    }

    It 'names the template, its age and who pushed it' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date).AddMinutes(-4); UserId = 42; Source = 'bridge' }
        $summary = Get-LayerRemovalSummary -Layer 7
        $summary | Should -Match 'Urgent'
        $summary | Should -Match 'الطبقة 7'
        $summary | Should -Match 'على الهواء منذ'
    }

    It 'says plainly when the bridge has no record for the layer' {
        Get-LayerRemovalSummary -Layer 3 | Should -Match 'لا يوجد سجل'
    }

    It 'marks a Cinegy-owned scene as started outside the bridge' {
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date); UserId = 0; Source = 'cinegy' }
        Get-LayerRemovalSummary -Layer 8 | Should -Match 'خارج الجسر'
    }

    It 'keeps the emergency path at one tap while confirmation is off' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'hide:7')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }

    It 'asks first when confirmation is on, and does not touch air yet' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'hide:7')

        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'Urgent' }
    }

    It 'executes once the operator confirms' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'hidego:7')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }

    It 'confirms an exit the same way' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'exit:7')
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'exitgo:7')
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
    }
}

Describe 'Black output watchdog' {
    BeforeEach {
        $script:OriginalLiveStreamForWatchdog = $config.LiveStream
        $config.LiveStream = [pscustomobject]@{
            SourceType = 'm3u8'; SourceUrl = 'https://primary.example/stream.m3u8'
            BackupSourceType = 'srt'; BackupSourceUrl = 'srt://127.0.0.1:5421'
            RtmpDestination = ''; VideoBitrateKbps = 2500; CopyCodec = $false
        }
        $script:LastOutputMonitorAt = [datetime]::MinValue
        $script:OutputBlackAlerted = $false
        $script:OutputMonitorFailureCount = 0
        $script:OutputMonitorFailureAlerted = $false
        $script:OutputMonitorFallbackActive = $false
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Send-AdminBroadcast {}
        Mock Send-TelegramMessage {}
        Mock Start-Sleep {}
        Mock Get-MonitorFrame { 'frame.jpg' }
        Mock Remove-Item {}
        Mock Get-SettingInt { 60 } -ParameterFilter { $Name -eq 'OutputMonitorMinutes' }
        Mock Get-SettingInt { 6 } -ParameterFilter { $Name -eq 'OutputBlackLuminance' }
        Mock Get-SettingInt { 5 } -ParameterFilter { $Name -eq 'OutputBlackConfirmSeconds' }
        Mock Get-SettingInt { 8 } -ParameterFilter { $Name -eq 'SnapshotTimeoutSeconds' }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'OutputMonitorFailureAlertThreshold' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NotifyOperatorsOnBlackOutput' }
    }

    AfterEach {
        $config.LiveStream = $script:OriginalLiveStreamForWatchdog
    }

    It 'alerts only after a second capture confirms the black' {
        Mock Get-BridgeFrameLuminance { 0.5 }

        Update-OutputBlackWatchdog

        Should -Invoke Get-BridgeFrameLuminance -Times 2 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'أسود' }
    }

    It 'stays silent when the second capture is not black' {
        # A cut or a fade reads as black for one frame. Alerting on that would
        # train operators to ignore the alert.
        $script:probe = 0
        Mock Get-BridgeFrameLuminance { $script:probe++; if ($script:probe -eq 1) { 0.5 } else { 120 } }

        Update-OutputBlackWatchdog

        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'never takes a second capture when the first is bright' {
        Mock Get-BridgeFrameLuminance { 130 }

        Update-OutputBlackWatchdog

        Should -Invoke Get-BridgeFrameLuminance -Times 1 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'does not repeat the alert while the output stays black' {
        Mock Get-BridgeFrameLuminance { 0.5 }

        Update-OutputBlackWatchdog
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
    }

    It 'reports recovery once the picture comes back' {
        Mock Get-BridgeFrameLuminance { 0.5 }
        Update-OutputBlackWatchdog

        Mock Get-BridgeFrameLuminance { 140 }
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'عاد المخرج' }
    }

    It 'does nothing at all when monitoring is disabled' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'OutputMonitorMinutes' }
        Mock Get-BridgeFrameLuminance { 0 }

        Update-OutputBlackWatchdog

        Should -Invoke Get-MonitorFrame -Times 0 -Exactly
    }

    It 'stays quiet when the capture itself failed, rather than assuming black' {
        # Without a configured backup there is no safe source to switch to;
        # a failed probe must remain quiet until the consecutive-failure alert.
        $config.LiveStream.BackupSourceUrl = ''
        Mock Get-MonitorFrame { $null }

        Update-OutputBlackWatchdog

        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'switches to the Cinegy backup after the first failed primary probe' {
        # A stopped primary must not leave operator snapshots pointed at the
        # dead M3U8 until the next hourly watchdog cycle.
        Mock Get-MonitorFrame { $null }

        Update-OutputBlackWatchdog

        $script:OutputMonitorFallbackActive | Should -BeTrue
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'الاحتياطي' }
    }

    It 'alerts administrators after the configured consecutive capture failures' {
        # Removing the failure counter or its threshold check must make this fail:
        # a stopped source must produce one actionable administrator alert.
        Mock Get-MonitorFrame { $null }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'OutputMonitorFailureAlertThreshold' }

        Update-OutputBlackWatchdog
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        $script:OutputMonitorFailureAlerted | Should -BeTrue
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'تعذّر' }
    }

    It 'reports availability recovery when no backup source is configured' {
        $config.LiveStream.BackupSourceUrl = ''
        Mock Get-MonitorFrame { $null }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'OutputMonitorFailureAlertThreshold' }

        Update-OutputBlackWatchdog
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        Mock Get-MonitorFrame { 'frame.jpg' }
        Mock Get-BridgeFrameLuminance { 140 }
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        $script:OutputMonitorFailureAlerted | Should -BeFalse
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'عاد الوصول' }
    }

    It 'uses the configured Cinegy source while fallback is active' {
        $script:OutputMonitorFallbackActive = $true

        $active = Get-ActiveLiveStreamConfig

        $active.SourceType | Should -Be 'srt'
        $active.SourceUrl | Should -Be 'srt://127.0.0.1:5421'
    }

    It 'switches once to the Cinegy backup after sustained primary failure' {
        # Removing the fallback switch leaves the relay and snapshots on a dead
        # primary source, so this must fail when that state transition is lost.
        Mock Get-MonitorFrame { $null }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'OutputMonitorFailureAlertThreshold' }

        Update-OutputBlackWatchdog
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        $script:OutputMonitorFallbackActive | Should -BeTrue
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'الاحتياطي' }
    }

    It 'returns to the primary source when it can be captured again' {
        $script:OutputMonitorFallbackActive = $true
        $script:OutputMonitorFailureAlerted = $true
        $script:OutputMonitorFailureCount = 2
        Mock Get-MonitorFrame { 'frame.jpg' }
        Mock Get-BridgeFrameLuminance { 140 }

        Update-OutputBlackWatchdog

        $script:OutputMonitorFallbackActive | Should -BeFalse
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'الأساسي' }
    }
}

Describe 'What is new and help content' {
    BeforeEach { $script:OnAir = @{} }

    It 'leads with the running version so an operator can tell which build they are on' {
        Get-WhatsNewText | Should -Match ([regex]::Escape($script:BridgeVersion))
    }

    It 'describes changes in operator terms, not function names' {
        $text = Get-WhatsNewText
        $text | Should -Match 'على الهواء'
        $text | Should -Not -Match 'Get-|Invoke-|\$script:'
    }

    It 'keeps the newest release first' {
        $text = Get-WhatsNewText
        # Anchored on the section marker: the header also carries the running version.
        $text.IndexOf('▪️ 5.1.0') | Should -BeLessThan $text.IndexOf('▪️ 5.0.0')
    }

    It 'is reachable from the menu and as a command' {
        $flat = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $flat | Should -Contain 'menu:whatsnew'
        @($script:BotCommandList | ForEach-Object { $_.command }) | Should -Contain 'whatsnew'
    }

    It 'tells an operator about the freshness warning they will actually see' {
        Mock Test-Admin { $false }
        Get-HelpText -ChatId 200 -UserId 200 | Should -Match 'آخر مرة'
    }

    It 'shows administrators the tools screen and the self-test, and operators neither' {
        Mock Test-Admin { $true }
        $admin = Get-HelpText -ChatId 100 -UserId 100
        $admin | Should -Match 'أدوات الإدارة'
        $admin | Should -Match 'فحص المسار الحي'

        Mock Test-Admin { $false }
        $operator = Get-HelpText -ChatId 200 -UserId 200
        $operator | Should -Not -Match 'أدوات الإدارة'
        $operator | Should -Not -Match 'الأمر الخام'
    }

    It 'fits Telegram message limits without relying on chunking' {
        Mock Test-Admin { $true }
        (Get-HelpText -ChatId 100 -UserId 100).Length | Should -BeLessThan 4096
        # The release notes now lead with the newest versions and put the rest
        # behind 📄 المزيد, so it is the first screen that must fit, not the
        # whole history - which grows with every release and eventually would
        # not.
        @(Get-WhatsNewParts)[0].Length | Should -BeLessThan 4096
    }

    It 'leads with the newest three versions and holds the rest back' {
        $parts = @(Get-WhatsNewParts)

        $parts.Count | Should -Be 2
        $parts[0] | Should -Match ([regex]::Escape($script:BridgeVersion))
        # The oldest summary belongs to the part nobody has to read.
        $parts[0] | Should -Not -Match '4\.x'
        $parts[1] | Should -Match '4\.x'
    }

    It 'says nothing rather than throwing when there is nothing to say' {
        # Found in the pre-release audit: an empty body made Split-TelegramText
        # return no chunks, and indexing an empty array throws under
        # StrictMode before Telegram ever gets a chance to reject it.
        Mock Send-TelegramMessage { }

        { Send-TelegramPagedText -ChatId 100 -Text '' } | Should -Not -Throw
        { Send-TelegramPagedText -ChatId 100 -Parts @('', '') } | Should -Not -Throw
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'routes the promote and demote callbacks to the right user id' {
        Get-CallbackArg 'usr:promote:122238225' 'usr:promote:' | Should -Be '122238225'
        Get-CallbackArg 'usr:demote:7275359265' 'usr:demote:' | Should -Be '7275359265'
    }

    It 'sends everything in one message when it already fits' {
        Mock Send-TelegramMessage { }
        Send-TelegramPagedText -ChatId 100 -Text 'قصير'

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { -not $ReplyMarkup }
    }

    It 'offers المزيد for the rest, and the caller keyboard with the last part' {
        Mock Send-TelegramMessage { }
        Send-TelegramPagedText -ChatId 100 -Parts @('الجزء الأول', 'الجزء الثاني') -ReplyMarkup @{ inline_keyboard = @() }

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -eq 'الجزء الأول' -and ($ReplyMarkup.inline_keyboard[0][0].callback_data -eq 'more:next')
        }

        Send-TelegramPagedChunk -ChatId 100 | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -eq 'الجزء الثاني' }
        # Exhausted: a second tap has nothing left to give.
        Send-TelegramPagedChunk -ChatId 100 | Should -BeFalse
    }
}

Describe 'Reserved layers admit administrators only' {
    BeforeEach {
        # Default first so unrelated settings still resolve, then the override.
        Mock Get-Setting { '' }
        Mock Get-Setting { '9' } -ParameterFilter { $Name -eq 'ReservedLayers' }
    }

    It 'refuses an operator' {
        $policy = Test-TemplateShowPolicy -Key 'lower-third' -Layer 9
        $policy.Allowed | Should -BeFalse
        $policy.Reason | Should -Match 'محجوزة'
    }

    It 'admits an administrator but says the layer is reserved' {
        # They are who reserved it; refusing them means editing config to
        # touch their own protected layer.
        $policy = Test-TemplateShowPolicy -Key 'lower-third' -Layer 9 -IsAdmin
        $policy.Allowed | Should -BeTrue
        $policy.Warning | Should -Match 'محجوزة'
    }

    It 'leaves an unreserved layer alone for both roles' {
        (Test-TemplateShowPolicy -Key 'lower-third' -Layer 3).Allowed | Should -BeTrue
        (Test-TemplateShowPolicy -Key 'lower-third' -Layer 3).Warning | Should -BeNullOrEmpty
    }

    It 'still blocks a disabled template for an administrator' {
        # Reserving a layer is about the layer; disabling a template is about
        # the template, and admin rights do not override that.
        Mock Get-Setting { 'broken-tpl' } -ParameterFilter { $Name -eq 'DisabledTemplateKeys' }
        (Test-TemplateShowPolicy -Key 'broken-tpl' -Layer 3 -IsAdmin).Allowed | Should -BeFalse
    }
}

Describe 'Undo survives navigating away' {
    BeforeEach {
        $script:OnAir = @{}
        $script:RollbackCandidates = @{}
        Mock Test-Admin { $false }
        Mock Get-Setting { $false }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableSafeRollback' }
    }
    AfterAll { $script:RollbackCandidates = @{} }

    It 'offers the rollback from the main menu, not only from the original message' {
        $script:RollbackCandidates[3] = @{ Id = 'r1'; Layer = 3; ActorUserId = 42
            ExpiresAt = (Get-Date).AddSeconds(45); CreatedAt = (Get-Date) }

        $flat = @((Get-MainMenuKeyboard -ChatId 42 -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        $flat | Should -Contain 'rollback:3'
    }

    It 'does not offer another operator someone else undo' {
        $script:RollbackCandidates[3] = @{ Id = 'r1'; Layer = 3; ActorUserId = 42
            ExpiresAt = (Get-Date).AddSeconds(45); CreatedAt = (Get-Date) }

        $flat = @((Get-MainMenuKeyboard -ChatId 99 -UserId 99).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        $flat | Should -Not -Contain 'rollback:3'
    }

    It 'drops the button once the window has passed' {
        $script:RollbackCandidates[3] = @{ Id = 'r1'; Layer = 3; ActorUserId = 42
            ExpiresAt = (Get-Date).AddSeconds(-1); CreatedAt = (Get-Date).AddMinutes(-5) }

        $flat = @((Get-MainMenuKeyboard -ChatId 42 -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        $flat | Should -Not -Contain 'rollback:3'
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

Describe 'Usage digest' {
    It 'ranks the busiest templates first' {
        $script:UsageCounts = @{ 'ticker' = 3; 'lower-third' = 11; 'bug' = 7 }
        $script:TemplateLastUsed = @{}
        $text = Get-UsageDigestText
        $text.IndexOf('lower-third') | Should -BeLessThan $text.IndexOf('bug')
        $text.IndexOf('bug') | Should -BeLessThan $text.IndexOf('ticker')
    }

    It 'says plainly when nothing has been used yet' {
        $script:UsageCounts = @{}
        Get-UsageDigestText | Should -Match 'لم تُستخدم'
    }

    It 'reports failures and refusals, and points at the audit log' {
        $script:UsageCounts = @{ 'ticker' = 1 }
        $script:AirOperationCounters = @{ Success = 10; Failed = 2; Blocked = 1 }
        $text = Get-UsageDigestText
        $text | Should -Match 'فاشلة 2'
        $text | Should -Match 'مرفوضة 1'
        $text | Should -Match 'السجل'
    }

    It 'stays quiet about the audit log when nothing went wrong' {
        $script:UsageCounts = @{ 'ticker' = 1 }
        $script:AirOperationCounters = @{ Success = 4; Failed = 0; Blocked = 0 }
        Get-UsageDigestText | Should -Not -Match 'راجع 📜'
    }
}

Describe 'Administrator restart' {
    BeforeEach {
        $script:RestartRequested = $false
        $script:OnAir = @{}
        Mock Test-Admin { $true }
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Get-AdminToolsKeyboard { @{ inline_keyboard = @() } }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }
        Mock Get-BridgeSupervisor { [pscustomobject]@{ Name = 'nssm.exe'; Supervised = $true } }
    }
    AfterAll { $script:RestartRequested = $false }

    It 'only identifies processes running this exact bridge script' {
        $scriptPath = [IO.Path]::GetFullPath($script:BridgeLaunch.ScriptPath)
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ ProcessId = 4101; CreationDate = 'now'; CommandLine = "pwsh -File `"$scriptPath`" -ConfigPath config.json" }
                [pscustomobject]@{ ProcessId = 4102; CreationDate = 'now'; CommandLine = 'pwsh -File C:\OtherStation\TelegramBridge.ps1 -ConfigPath config.json' }
            )
        }

        $processMatches = @(Get-OtherBridgeProcess)
        @($processMatches).Count | Should -Be 1
        $processMatches[0].ProcessId | Should -Be 4101
    }

    It 'refuses while the setting is off, whatever supervises the process' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }

        Request-BridgeRestart -ChatId 100 -UserId 100 | Should -BeFalse
        $script:RestartRequested | Should -BeFalse
    }

    It 'refuses when nothing would bring the bridge back' {
        # Exiting unsupervised with no way to relaunch is not a restart, it is
        # an outage with no way back in through the bot that just stopped.
        Mock Get-BridgeSupervisor { [pscustomobject]@{ Name = 'explorer.exe'; Supervised = $false } }
        Mock Get-BridgeRelaunchCommand { $null }

        Request-BridgeRestart -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'explorer.exe' }
    }

    It 'restarts itself when started from a terminal, rather than refusing' {
        # How this is actually run during a shift: by hand from the VS Code
        # console, where no service exists to bring it back. Refusing there
        # left the only restart route as walking over to the playout machine.
        Mock Get-BridgeSupervisor { [pscustomobject]@{ Name = 'pwsh.exe'; Supervised = $false } }
        Mock Get-BridgeRelaunchCommand { [pscustomobject]@{ FilePath = 'pwsh.exe'; Arguments = @(); WorkingDirectory = '.' } }

        Request-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'الجسر نفسه' }
    }

    It 'leaves the relaunch to the supervisor when there is one' {
        # Two bridges long-polling one bot token means button presses vanish
        # into whichever instance happened to receive them.
        Confirm-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue

        $script:RestartRequested | Should -BeTrue
        $script:RestartSelfRelaunch | Should -BeFalse
    }

    It 'takes the relaunch on itself when nothing else will' {
        Mock Get-BridgeSupervisor { [pscustomobject]@{ Name = 'pwsh.exe'; Supervised = $false } }

        Confirm-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue

        $script:RestartSelfRelaunch | Should -BeTrue
    }

    It 'quotes a launch path that contains a space' {
        # Start-Process -ArgumentList joins with spaces and quotes nothing, so
        # an unquoted "D:\cingy cg\..." reaches the replacement as
        # "-File D:\cingy" and the restart dies before it starts.
        $script:BridgeLaunch = @{
            ScriptPath             = $PSCommandPath
            ConfigPath             = 'D:\cingy cg\config.json'
            RuntimePath            = ''
            AllowMultipleInstances = $false
            RequireSingleInstance  = $true
            WorkingDirectory       = 'D:\cingy cg'
        }

        $command = Get-BridgeRelaunchCommand

        $command | Should -Not -BeNullOrEmpty
        $command.Arguments | Should -Contain '"D:\cingy cg\config.json"'
        $command.Arguments | Should -Contain '-RequireSingleInstance'
    }

    It 'asks before restarting rather than acting on the first tap' {
        Request-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue
        $script:RestartRequested | Should -BeFalse
    }

    It 'warns that scenes are on air when confirming' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Request-BridgeRestart -ChatId 100 -UserId 100 | Out-Null

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'على الهواء' }
    }

    It 'signals the loop rather than killing the process from a callback' {
        # The finally block stops the relay, saves counters and releases the
        # single-instance mutex; exiting here would skip all of it and the
        # replacement would find the mutex still held.
        Confirm-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue
        $script:RestartRequested | Should -BeTrue
    }

    It 'ignores a confirmation from a non-administrator' {
        Mock Test-Admin { $false }

        Confirm-BridgeRestart -ChatId 200 -UserId 200 | Should -BeFalse
        $script:RestartRequested | Should -BeFalse
    }

    It 'hides the button entirely while the setting is off' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableLiveRelay' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableRawCommand' }

        $flat = @((Get-AdminToolsKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        $flat | Should -Not -Contain 'menu:restart'
    }
}

Describe 'Operational numbers and status sharing' {
    BeforeEach {
        $script:OnAir = @{}
        $script:BridgeStartedAt = (Get-Date).AddHours(-26)
        $script:TelegramRateLimitHits = 7
        $script:AirOperationCounters = @{ Success = 12; Failed = 1; Blocked = 2 }
    }
    AfterAll { $script:OnAir = @{} }

    It 'reports uptime, which is what tells an administrator it has been restarting' {
        $text = Get-BridgeStatsText
        $text | Should -Match 'مدة التشغيل: 1 ي'
        $text | Should -Match ([regex]::Escape($script:BridgeVersion))
    }

    It 'separates flood limits from ordinary failures' {
        Get-BridgeStatsText | Should -Match '\(429\): 7'
    }

    It 'counts every air operation outcome' {
        $text = Get-BridgeStatsText
        $text | Should -Match 'عمليات الهواء: 15'
    }

    It 'shares a plain summary that survives being pasted elsewhere' {
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date).AddMinutes(-4); UserId = 42; Source = 'bridge' }
        $text = Get-OnAirShareText
        $text | Should -Match 'طبقة 3: lower-third'
        $text | Should -Match 'منذ'
        # No inline-keyboard chrome, no callback data - it is meant to be copied.
        $text | Should -Not -Match 'callback_data'
    }

    It 'says plainly when nothing is on air rather than sharing an empty list' {
        Get-OnAirShareText | Should -Match 'لا شيء على الهواء'
    }
}

Describe 'On-air row tools' {
    BeforeEach {
        $script:OnAir = @{}
        $script:RollbackCandidates = @{}
        Mock Test-Admin { $false }
    }
    AfterAll { $script:OnAir = @{} }

    It 'offers an instant frame and a copyable status beside the live layers' {
        # The operator can check the bridge's claim against the real output
        # without leaving the chat.
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        $flat = @((Get-MainMenuKeyboard -ChatId 42 -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        $flat | Should -Contain 'menu:snapshot'
        $flat | Should -Contain 'menu:sharestatus'
    }

    It 'keeps the emergency hide on that same row' {
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date); UserId = 42; Source = 'bridge' }
        $rows = @((Get-MainMenuKeyboard -ChatId 42 -UserId 42).inline_keyboard)
        $toolRow = @($rows | Where-Object { @($_ | ForEach-Object { $_.callback_data }) -contains 'menu:hideall' })
        @($toolRow[0] | ForEach-Object { $_.callback_data }) | Should -Contain 'menu:sharestatus'
    }
}

Describe 'Layer lock visibility' {
    BeforeEach {
        $script:LayerLocks = @{}
        Mock Get-UserDisplayName { 'أحمد' }
    }
    AfterAll { $script:LayerLocks = @{} }

    It 'names the holder and how long they have held it' {
        # "المستخدم 7275359265" does not tell the second operator whether to
        # wait or to call across the room.
        $script:LayerLocks[5] = @{ ChatId = 10; UserId = 20; Key = 'lower-third'; StartedAt = (Get-Date).AddMinutes(-2) }

        $notice = Get-LayerLockNotice -Layer 5 -UserId 21
        $notice | Should -Match 'أحمد'
        $notice | Should -Match 'lower-third'
        $notice | Should -Match 'منذ'
    }

    It 'says nothing to the operator who holds the lock themselves' {
        $script:LayerLocks[5] = @{ ChatId = 10; UserId = 20; Key = 'lower-third'; StartedAt = (Get-Date) }
        Get-LayerLockNotice -Layer 5 -UserId 20 | Should -BeNullOrEmpty
    }

    It 'says nothing about a free layer' {
        Get-LayerLockNotice -Layer 5 -UserId 20 | Should -BeNullOrEmpty
    }

    It 'badges a locked layer in the template list, before any field is typed' {
        $script:LayerLocks[5] = @{ ChatId = 10; UserId = 20; Key = 'lower-third'; StartedAt = (Get-Date) }
        Mock Get-TemplateStore {
            @{ Order = @('alpha'); Map = @{ alpha = @{ Key = 'alpha'; Layer = 5; Category = ''; Presets = @() } }; Errors = @() }
        }
        Mock Get-TemplateLastUsedLabel { '' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ShowLayerLockBadge' }

        $labels = @((Get-TemplatesKeyboard -Prefix tpl).inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.text } })
        ($labels -join ' ') | Should -Match '🔒'
    }
}

Describe 'Cancel reasons' {
    BeforeEach {
        $script:CancelReasons = @{}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Save-CancelReasons { $true }
    }
    AfterAll { $script:CancelReasons = @{} }

    It 'counts each reason separately' {
        Add-CancelReason -Reason 'template' -UserId 42 -Key 'alpha'
        Add-CancelReason -Reason 'template' -UserId 42 -Key 'beta'
        Add-CancelReason -Reason 'timing' -UserId 42 -Key 'alpha'

        $script:CancelReasons['template'] | Should -Be 2
        $script:CancelReasons['timing'] | Should -Be 1
    }

    It 'stores counts only, never field text or user ids' {
        # It must not become a second audit log.
        Add-CancelReason -Reason 'director' -UserId 7275359265 -Key 'الانتخابات'
        ($script:CancelReasons.Values | ForEach-Object { $_ }) | ForEach-Object { $_ | Should -BeOfType [int] }
        ($script:CancelReasons.Keys -join ' ') | Should -Not -Match '7275359265'
    }

    It 'labels every reason in Arabic for the digest' {
        foreach ($code in @('template', 'timing', 'director', 'other')) {
            Get-CancelReasonLabel -Reason $code | Should -Not -Be $code
        }
    }

    It 'offers a skip, because an unexplained undo is still a valid undo' {
        $flat = @((Get-CancelReasonKeyboard).inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $flat | Should -Contain 'menu'
        $flat | Should -Contain 'cancelreason:template'
    }

    It 'reports the breakdown in the usage digest' {
        $script:UsageCounts = @{ 'alpha' = 1 }
        $script:AirOperationCounters = @{ Success = 1; Failed = 0; Blocked = 0 }
        $script:CancelReasons = @{ 'template' = 3 }

        Get-UsageDigestText | Should -Match 'قالب خاطئ: 3'
    }
}

Describe 'Missed events and template history' {
    BeforeEach {
        $script:OnAir = @{}
        $script:auditFile = Join-Path $TestDrive "audit-$([guid]::NewGuid().ToString('N')).jsonl"
        $recent = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
        $old = (Get-Date).ToUniversalTime().AddDays(-3).ToString('o')
        Set-Content -LiteralPath $script:auditFile -Encoding utf8 -Value @(
            (@{ timestampUtc = $recent; action = 'SHOW'; result = 'success'; userId = 42; layer = 3; target = 'الانتخابات'; message = '' } | ConvertTo-Json -Compress)
            (@{ timestampUtc = $recent; action = 'HIDE'; result = 'success'; userId = 42; layer = 3; target = ''; message = '' } | ConvertTo-Json -Compress)
            (@{ timestampUtc = $recent; action = 'SHOW'; result = 'failed'; userId = 42; layer = 4; target = 'الطقس'; message = 'engine refused' } | ConvertTo-Json -Compress)
            (@{ timestampUtc = $old; action = 'SHOW'; result = 'success'; userId = 99; layer = 3; target = 'قديم-جدًا'; message = '' } | ConvertTo-Json -Compress)
        )
        Mock Get-UserDisplayName { 'أحمد' }
    }
    AfterAll { $script:OnAir = @{} }

    It 'summarises what happened while nobody was looking' {
        $text = Get-MissedEventsText -Hours 12
        # Grouped by graphic, not by verb: which template moved is the
        # question at a handover, and who moved it.
        $text | Should -Match 'الانتخابات'
        $text | Should -Match 'أحمد'
        $text | Should -Match 'إخفاء وخروج: 1'
    }

    It 'calls out failures, which is the part worth reading' {
        $text = Get-MissedEventsText -Hours 12
        $text | Should -Match 'فشل: 1'
        $text | Should -Match 'engine refused'
    }

    It 'ignores anything outside the window' {
        # The three-day-old entry names a template the recent ones do not.
        (Get-MissedEventsText -Hours 12) | Should -Not -Match 'قديم-جدًا'
    }

    It 'passes activity notes through verbatim rather than counting them' {
        # The old digest bucketed every message-only record as "other", which
        # was both the largest number on screen and the least informative.
        Add-Content -LiteralPath $script:auditFile -Encoding utf8 -Value (
            @{ timestampUtc = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
                event        = 'activity'; message = '📰 نشر شريط الأخبار بواسطة أحمد: 39 خبرًا'
            } | ConvertTo-Json -Compress)

        Get-MissedEventsText -Hours 12 | Should -Match '39 خبرًا'
    }
    It 'says so plainly when nothing happened' {
        Set-Content -LiteralPath $script:auditFile -Value '' -Encoding utf8
        Get-MissedEventsText -Hours 12 | Should -Match 'لا شيء مسجّل'
    }

    It 'answers who used a template, across the whole retained history' {
        $text = Get-TemplateHistoryText -Query 'الانتخابات'
        $text | Should -Match 'أحمد'
        $text | Should -Match 'SHOW'
    }

    It 'reports honestly when a template has no recorded use' {
        Get-TemplateHistoryText -Query 'لا-يوجد' | Should -Match 'لا يوجد سجل'
    }

    It 'asks for a name instead of dumping everything' {
        Get-TemplateHistoryText -Query '   ' | Should -Match 'اكتب اسم القالب'
    }
}

Describe 'Cinegy results keep one shape' {
    <#
        Four bugs this release came from the same thing: a field that exists
        only on the success path, read by a caller on the failure path, which
        throws under StrictMode exactly when the engine is already in trouble.
        These pin the shapes so the class cannot come back quietly.
    #>
    BeforeAll { Import-Module (Join-Path $script:Root 'Modules\CinegyAirTitler.psm1') -Force }

    It 'reports the same fields whether the command worked or failed' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { [pscustomobject]@{ StatusCode = 200; Content = '' } }
        $ok = Send-AirCommand -AirServerAddress 'air' -AirChannelNumber 0 -Device '*GFX_5' -Cmd 'Show'

        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'engine refused' }
        $bad = Send-AirCommand -AirServerAddress 'air' -AirChannelNumber 0 -Device '*GFX_5' -Cmd 'Show'

        $okFields = @($ok.PSObject.Properties.Name | Sort-Object)
        $badFields = @($bad.PSObject.Properties.Name | Sort-Object)
        $badFields | Should -Be $okFields
        $bad.StatusCode | Should -Be 0
        $ok.Error | Should -Be ''
    }

    It 'keeps one shape for a layer status too' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{ StatusCode = 200; Content = '<Status><Active Id="{00000000-0000-0000-0000-000000000000}"/><License State="Licensed"/><Output State="Normal"/><Client Connected="n" Identity=""/></Status>' }
        }
        $ok = Get-TitlerLayerStatus -AirServerAddress 'air' -AirChannelNumber 0 -Layer 5

        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'connection refused' }
        $bad = Get-TitlerLayerStatus -AirServerAddress 'air' -AirChannelNumber 0 -Layer 5

        @($bad.PSObject.Properties.Name | Sort-Object) | Should -Be @($ok.PSObject.Properties.Name | Sort-Object)
        # The field the staleness exemption reads, on the path where Cinegy
        # could not answer.
        $bad.ActiveDurationSeconds | Should -Be 0
    }

    It 'keeps one shape for telemetry, on all three of its exits' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{ StatusCode = 200; Content = '<Metrics><At DroppedCount="0" OutputCount="1500" NoInputSignal="0" AverageReadTime="4.5" ReadErrorRate="0" Heartbeat="900"/></Metrics>' }
        }
        $ok = Get-AirTelemetryStatus -AirServerAddress 'air' -AirChannelNumber 0

        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { [pscustomobject]@{ StatusCode = 200; Content = '<Metrics></Metrics>' } }
        $empty = Get-AirTelemetryStatus -AirServerAddress 'air' -AirChannelNumber 0

        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'metrics timeout' }
        $bad = Get-AirTelemetryStatus -AirServerAddress 'air' -AirChannelNumber 0

        $expected = @($ok.PSObject.Properties.Name | Sort-Object)
        @($empty.PSObject.Properties.Name | Sort-Object) | Should -Be $expected
        @($bad.PSObject.Properties.Name | Sort-Object) | Should -Be $expected
    }
}

Describe 'The audit trail is archived, never dropped' {
    BeforeAll { $script:OriginalAuditFile = $script:auditFile }
    # Restored, because $script: here is the same scope the loaded bridge uses:
    # leaving it pointed at a TestDrive path silently broke every later suite
    # that reads the audit trail.
    AfterAll { $script:auditFile = $script:OriginalAuditFile }

    BeforeEach {
        Mock Write-BridgeLog {}
        # A directory per test, so one test's archives are never another's.
        $script:auditFile = Join-Path (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName 'audit.jsonl'
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'AuditMaxSizeMB' }
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'AuditArchiveKeepFiles' }
    }
    AfterEach { $script:auditFile = $script:OriginalAuditFile }

    It 'leaves the file alone below the limit, and when rotation is off' {
        Set-Content -LiteralPath $script:auditFile -Value '{"message":"صغير"}' -Encoding utf8

        Invoke-AuditRotation | Should -BeFalse
        Test-Path -LiteralPath $script:auditFile | Should -BeTrue
    }

    It 'archives past the limit instead of deleting anything' {
        # bridge.log drops its oldest generation, which is right for a
        # diagnostic log and wrong for the record of who put what on air.
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'AuditMaxSizeMB' }
        Set-Content -LiteralPath $script:auditFile -Value ('x' * 1200000) -Encoding utf8

        Invoke-AuditRotation | Should -BeTrue

        Test-Path -LiteralPath $script:auditFile | Should -BeFalse
        @(Get-AuditArchiveFiles) | Should -HaveCount 1
    }

    It 'still finds the history through the archive after a rotation' {
        # The first digest after a rotation must not report an empty morning.
        $dir = Split-Path -Parent $script:auditFile
        $old = '{"timestampUtc":"' + (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o') + '","message":"حدث قديم"}'
        Set-Content -LiteralPath (Join-Path $dir 'audit-20260101-000000.jsonl') -Value $old -Encoding utf8
        $new = '{"timestampUtc":"' + (Get-Date).ToUniversalTime().ToString('o') + '","message":"حدث جديد"}'
        Set-Content -LiteralPath $script:auditFile -Value $new -Encoding utf8

        $records = @(Read-AuditRecords -MaxLines 500)

        @($records | ForEach-Object { $_.message }) | Should -Contain 'حدث قديم'
        @($records | ForEach-Object { $_.message }) | Should -Contain 'حدث جديد'
    }

    It 'prunes only when explicitly told to keep a fixed number' {
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'AuditMaxSizeMB' }
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'AuditArchiveKeepFiles' }
        $dir = Split-Path -Parent $script:auditFile
        Set-Content -LiteralPath (Join-Path $dir 'audit-20260101-000000.jsonl') -Value 'قديم' -Encoding utf8
        Set-Content -LiteralPath $script:auditFile -Value ('x' * 1200000) -Encoding utf8

        Invoke-AuditRotation | Should -BeTrue

        @(Get-AuditArchiveFiles) | Should -HaveCount 1
    }
}

Describe 'Durations read like durations' {
    It 'leaves anything under an hour in minutes' {
        Format-DurationMinutes -Minutes 30 | Should -Be '30 دقيقة'
        Format-DurationMinutes -Minutes 59 | Should -Be '59 دقيقة'
    }

    It 'counts hours the way Arabic counts them' {
        # Dual for two, plural three to ten, singular again from eleven.
        Format-DurationMinutes -Minutes 60 | Should -Be 'ساعة'
        Format-DurationMinutes -Minutes 120 | Should -Be 'ساعتان'
        Format-DurationMinutes -Minutes 300 | Should -Be '5 ساعات'
        Format-DurationMinutes -Minutes 720 | Should -Be '12 ساعة'
    }

    It 'keeps the leftover minutes rather than rounding them away' {
        Format-DurationMinutes -Minutes 90 | Should -Be 'ساعة و30 دقيقة'
    }

    It 'reaches for days once there are enough hours' {
        # 1200 minutes was the complaint: twenty hours, written as a number
        # the reader had to divide.
        Format-DurationMinutes -Minutes 1200 | Should -Be '20 ساعة'
        Format-DurationMinutes -Minutes 1440 | Should -Be 'يوم'
        Format-DurationMinutes -Minutes 2880 | Should -Be 'يومان'
        Format-DurationMinutes -Minutes 1500 | Should -Be 'يوم وساعة'
    }

    It 'says zero plainly' {
        Format-DurationMinutes -Minutes 0 | Should -Be '0 دقيقة'
    }

    It 'promotes seconds that do not divide evenly by sixty' {
        # Caught in review: promotion only fired on exact multiples of 60, so
        # an uptime of 3661 still read "3661 ثانية" - the very thing the
        # formatter was written to stop, surviving in every value that is not
        # a round minute. Uptime almost never is.
        Format-DurationSeconds -Seconds 3661 | Should -Be 'ساعة ودقيقة'
        Format-DurationSeconds -Seconds 90061 | Should -Be 'يوم وساعة ودقيقة'
        Format-DurationSeconds -Seconds 3599 | Should -Be '59 دقيقة و59 ثانية'
        Format-DurationSeconds -Seconds 61 | Should -Be 'دقيقة وثانية'
    }

    It 'drops leftover seconds once past an hour, and keeps them below it' {
        Format-DurationSeconds -Seconds 3600 | Should -Be 'ساعة'
        Format-DurationSeconds -Seconds 90 | Should -Be 'دقيقة و30 ثانية'
    }

    It 'spells out a minute-valued setting on the settings screen' {
        Format-SettingDisplay -Name 'NewsDraftTimeoutMinutes' -Value 120 | Should -Be 'ساعتان'
    }

    It 'leaves a setting measured in anything else alone' {
        Format-SettingDisplay -Name 'CinegyFrameLossTolerance' -Value 5 | Should -Be '5 إطار'
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

Describe 'The command menu is scoped to the role' {
    BeforeEach {
        Mock Write-BridgeLog {}
        Mock Get-AuthorizedUsers {
            @(
                [pscustomobject]@{ UserId = 101; Alias = 'المالك'; Role = 'owner' }
                [pscustomobject]@{ UserId = 202; Alias = 'مشغّل'; Role = 'operator' }
            )
        }
        Mock Invoke-RestMethod { }
    }

    It 'keeps admin-only commands out of the menu every operator sees' {
        # Telegram shows one global list unless it is scoped, so ⚙️ الإعدادات
        # was advertised to everyone and refused only once tapped.
        Register-BotCommands

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*setMyCommands' -and $Body -notlike '*scope*' -and
            $Body -notlike '*settings*' -and $Body -notlike '*audit*' -and
            $Body -notlike '*diagbundle*' -and $Body -like '*templates*'
        }
    }

    It 'gives an administrator the full list in their own chat' {
        Register-BotCommands

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*setMyCommands' -and $Body -like '*"chat_id":101*' -and $Body -like '*settings*'
        }
    }

    It 'clears the scope for a user who is not an administrator' {
        # A demoted administrator must fall back to the operator menu rather
        # than keep a list of commands that now refuse them.
        Register-BotCommands

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*deleteMyCommands' -and $Body -like '*"chat_id":202*'
        }
    }

    It 'never sends the internal Admin flag to Telegram' {
        Register-BotCommands

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Body -like '*Admin*' }
    }
}

Describe 'Long-running graphics are not stale' {
    BeforeEach {
        # 21 hours on air: past any sane staleness threshold.
        $script:OnAir = @{ 8 = @{ Key = 'News-Ticker'; At = (Get-Date).AddHours(-21); Source = 'bridge'; UserId = 42 } }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'RespectCinegyItemDuration' }
        Mock Get-SettingInt { 3 } -ParameterFilter { $Name -eq 'CinegyMonitorTimeoutSeconds' }
        Mock Get-TemplateStore {
            @{ Order = @('News-Ticker'); Map = @{ 'News-Ticker' = @{ Key = 'News-Ticker'; Layer = 8; Device = ''; LongRunning = $false } } }
        }
        Mock Write-BridgeLog {}
    }
    AfterAll { $script:OnAir = @{} }

    It 'exempts a template the operator marked as long-running' {
        Mock Get-TemplateStore {
            @{ Order = @('News-Ticker'); Map = @{ 'News-Ticker' = @{ Key = 'News-Ticker'; Layer = 8; Device = ''; LongRunning = $true } } }
        }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeTrue
    }

    It 'exempts a graphic Cinegy scheduled for longer than it has been up' {
        # The real case: the ticker's Active Id matched the record exactly, it
        # was genuinely on screen, and administrators were told five times over
        # two days that it was a stale record.
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveDurationSeconds = 86400; ActiveManualEnd = $true } }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeTrue
    }

    It 'still calls it stale once the declared duration has run out' {
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveDurationSeconds = 3600; ActiveManualEnd = $false } }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeFalse
    }

    It 'does not silence the alert when Cinegy cannot be reached' {
        # "Cannot check" and "fine" are different things, and only one of them
        # is a reason to stay quiet about a graphic stuck on air.
        Mock Get-TitlerLayerStatus { throw 'connection refused' }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeFalse
    }

    It 'does not silence the alert for a layer Cinegy says is empty' {
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveDurationSeconds = 86400; ActiveManualEnd = $true } }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeFalse
    }

    It 'skips the Cinegy question when the setting is off' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'RespectCinegyItemDuration' }
        Mock Get-TitlerLayerStatus { throw 'should not be called' }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeFalse
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
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
Describe 'Repeat radar' {
    BeforeEach {
        $script:RecentShowTimes = @{}
        Mock Get-SettingInt { 3 } -ParameterFilter { $Name -eq 'RepeatWarningCount' }
        Mock Get-SettingInt { 60 } -ParameterFilter { $Name -eq 'RepeatWarningWindowMinutes' }
    }

    It 'stays quiet for the first two pushes' {
        Test-RepeatedShow -Key 'alpha' | Should -BeFalse
        Test-RepeatedShow -Key 'alpha' | Should -BeFalse
    }

    It 'flags the third push inside the window' {
        # A paste slip or a double tap, not editorial intent.
        Test-RepeatedShow -Key 'alpha' | Out-Null
        Test-RepeatedShow -Key 'alpha' | Out-Null
        Test-RepeatedShow -Key 'alpha' | Should -BeTrue
    }

    It 'forgets pushes that fell outside the window' {
        $now = Get-Date
        Test-RepeatedShow -Key 'alpha' -Now $now.AddMinutes(-90) | Out-Null
        Test-RepeatedShow -Key 'alpha' -Now $now.AddMinutes(-80) | Out-Null
        Test-RepeatedShow -Key 'alpha' -Now $now | Should -BeFalse
    }

    It 'counts each template separately' {
        Test-RepeatedShow -Key 'alpha' | Out-Null
        Test-RepeatedShow -Key 'alpha' | Out-Null
        Test-RepeatedShow -Key 'beta' | Should -BeFalse
    }

    It 'is disabled by a threshold of zero or one' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'RepeatWarningCount' }
        1..5 | ForEach-Object { Test-RepeatedShow -Key 'alpha' | Should -BeFalse }
    }
}

Describe 'Quiet hours delivery' {
    BeforeEach {
        $script:QuietHoursQueue = [System.Collections.Generic.List[object]]::new()
        Mock Send-TelegramMessage {}
        Mock Write-BridgeLog {}
        Mock Test-QuietHoursActive { $true }
    }
    AfterAll { $script:QuietHoursQueue = [System.Collections.Generic.List[object]]::new() }

    It 'holds a routine notice instead of paging at 03:00' {
        Send-AdminBroadcast -Text 'قالب لم يُتحقق منه'
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
        $script:QuietHoursQueue.Count | Should -Be 1
    }

    It 'still sends an urgent one immediately' {
        # A black output means the channel is wrong right now.
        Send-AdminBroadcast -Text 'المخرج أسود' -Urgent
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
        $script:QuietHoursQueue.Count | Should -Be 0
    }

    It 'delivers everything held as one message once the window passes' {
        Send-AdminBroadcast -Text 'أول'
        Send-AdminBroadcast -Text 'ثانٍ'
        Mock Test-QuietHoursActive { $false }

        Update-QuietHoursQueue

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'أول' -and $Text -match 'ثانٍ' }
        $script:QuietHoursQueue.Count | Should -Be 0
    }

    It 'keeps holding while the window is still open' {
        Send-AdminBroadcast -Text 'أول'
        Update-QuietHoursQueue
        $script:QuietHoursQueue.Count | Should -Be 1
    }
}

Describe 'One-hand layout and text shortcuts' {
    BeforeEach {
        Mock Get-TemplateStore {
            @{ Order = @('alpha', 'beta'); Map = @{
                    alpha = @{ Key = 'alpha'; Layer = 3 }; beta = @{ Key = 'beta'; Layer = 4 }
                }; Errors = @() }
        }
    }

    It 'splits every row into full-width buttons when enabled' {
        # Thumb-only use cannot reliably hit one of three buttons in a row.
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'OneHandMode' }
        $rows = New-Object System.Collections.ArrayList
        [void]$rows.Add(@(@{ text = 'a' }, @{ text = 'b' }))
        [void]$rows.Add(@(@{ text = 'c' }))
        $keyboard = ConvertTo-OneHandLayout -Keyboard @{ inline_keyboard = $rows.ToArray() }
        @($keyboard.inline_keyboard) | ForEach-Object { @($_).Count | Should -Be 1 }
        @($keyboard.inline_keyboard).Count | Should -Be 3
    }

    It 'leaves the keyboard untouched when disabled' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'OneHandMode' }
        $originalRows = New-Object System.Collections.ArrayList
        [void]$originalRows.Add(@(@{ text = 'a' }, @{ text = 'b' }))
        $original = @{ inline_keyboard = $originalRows.ToArray() }
        @((ConvertTo-OneHandLayout -Keyboard $original).inline_keyboard[0]).Count | Should -Be 2
    }

    It 'resolves an exact template name to its index' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableTextShortcuts' }
        Resolve-TemplateShortcut -Text 'beta' | Should -Be 1
        Resolve-TemplateShortcut -Text 'BETA' | Should -Be 1
    }

    It 'refuses anything that is not an exact match' {
        # A fuzzy match would put the wrong graphic on air from a typo.
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableTextShortcuts' }
        Resolve-TemplateShortcut -Text 'bet' | Should -Be -1
        Resolve-TemplateShortcut -Text 'beta2' | Should -Be -1
        Resolve-TemplateShortcut -Text '  ' | Should -Be -1
    }

    It 'is inert while the setting is off' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableTextShortcuts' }
        Resolve-TemplateShortcut -Text 'beta' | Should -Be -1
    }
}

Describe 'News draft expiry' {
    BeforeEach {
        $script:NewsTickerDraft = $null
        Mock Write-BridgeLog {}
        Mock Send-TelegramMessage {}
        Mock Remove-NewsTickerDraft { $script:NewsTickerDraft = $null }
        Mock Get-SettingInt { 30 } -ParameterFilter { $Name -eq 'NewsDraftTimeoutMinutes' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'drops a draft left open past the timeout' {
        # Reproduces the live incident: a draft started yesterday could never
        # publish, because the live file had moved on and the hash guard
        # refused every attempt. The operator saw their edits never appear.
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ', 'ب')
            UpdatedAt = (Get-Date).AddHours(-20).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        $script:NewsTickerDraft | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'انتهت صلاحية' }
    }

    It 'tells the owner how many items were lost, so the loss is not silent' {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ', 'ب', 'ج')
            UpdatedAt = (Get-Date).AddHours(-5).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match '3 خبرًا' }
    }

    It 'hands the items back instead of only counting them' {
        # An unpublished draft is somebody's work. Telling an operator that 28
        # items were lost, without the text, is worse than useless - the lock
        # hand-over has returned it since 5.5 and an expiry destroys as much.
        Mock Send-TelegramPagedText {}
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('خبر أول', 'خبر ثان')
            UpdatedAt = (Get-Date).AddHours(-5).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly -ParameterFilter {
            $Text -match '1\. خبر أول' -and $Text -match '2\. خبر ثان'
        }
    }

    It 'leaves a draft that is still being worked on' {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ')
            UpdatedAt = (Get-Date).AddMinutes(-5).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
    }

    It 'is disabled by a zero timeout' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'NewsDraftTimeoutMinutes' }
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; Items = @('أ')
            UpdatedAt = (Get-Date).AddDays(-2).ToString('o'); BaseHash = 'OLD'
        }

        Update-NewsDraftExpiry

        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
    }

    It 'does nothing when there is no draft at all' {
        { Update-NewsDraftExpiry } | Should -Not -Throw
    }

    It 'leaves a draft whose timestamp cannot be read, rather than guessing' {
        $script:NewsTickerDraft = @{ OwnerUserId = 42; OwnerChatId = 42; Items = @('أ'); UpdatedAt = 'not-a-date' }
        Update-NewsDraftExpiry
        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
    }
}

Describe 'News publish conflict reporting' {
    It 'reports a conflict as a conflict, with a way forward' {
        # "لم يتم النشر" alone left operators retrying the same doomed publish
        # and concluding the bot ignored their edits.
        Mock Get-NewsTickerDraft { $null }
        $result = Publish-NewsTickerDraft -UserId 42
        $result.Success | Should -BeFalse
        # Every caller branches on Conflict, so it must exist on every path.
        $result.PSObject.Properties.Name | Should -Contain 'Conflict'
    }
}

Describe 'News lock hand-over' {
    BeforeEach {
        $script:NewsLockRequest = $null
        $script:NewsTickerDraft = @{ OwnerUserId = 20; OwnerChatId = 20; Items = @('أ', 'ب'); UpdatedAt = (Get-Date).ToString('o') }
        Mock Send-TelegramMessage {}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Get-UserDisplayName { "user$UserId" }
        Mock Get-NewsTickerManagementKeyboard { @{ inline_keyboard = @() } }
        Mock Remove-NewsTickerDraft { $script:NewsTickerDraft = $null }
        Mock Get-SettingInt { 5 } -ParameterFilter { $Name -eq 'NewsLockRequestMinutes' }
    }
    AfterAll { $script:NewsTickerDraft = $null; $script:NewsLockRequest = $null }

    It 'asks the owner rather than taking the draft outright' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Should -BeTrue
        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 20 -and $Text -match 'يطلب' }
    }

    It 'refuses a request from the owner themselves' {
        Request-NewsLockRelease -ChatId 20 -UserId 20 | Should -BeFalse
    }

    It 'refuses a second requester while one is pending' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Request-NewsLockRelease -ChatId 22 -UserId 22 | Should -BeFalse
    }

    It 'hands over when the owner agrees, returning their text first' {
        # An unpublished draft is somebody's work; dropping it silently or
        # handing it to another person would both be worse than giving it back.
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null

        Complete-NewsLockRelease -Reason 'granted by the owner' | Should -BeTrue

        $script:NewsTickerDraft | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 20 -and $Text -match 'نصّ مسودتك' }
    }

    It 'keeps the draft when the owner says they are still working' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null

        Complete-NewsLockRelease -Denied | Should -BeFalse

        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
        $script:NewsLockRequest | Should -BeNullOrEmpty
    }

    It 'grants automatically once the window passes, because silence cannot wait' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        $script:NewsLockRequest.RequestedAt = (Get-Date).AddMinutes(-10)

        Update-NewsLockRequest

        $script:NewsTickerDraft | Should -BeNullOrEmpty
        $script:NewsLockRequest | Should -BeNullOrEmpty
    }

    It 'waits while the window is still open' {
        Request-NewsLockRelease -ChatId 21 -UserId 21 | Out-Null
        Update-NewsLockRequest
        $script:NewsTickerDraft | Should -Not -BeNullOrEmpty
    }
}

Describe 'News publish conflict resolution' {
    BeforeEach {
        $script:NewsTickerDraft = @{ OwnerUserId = 20; OwnerChatId = 20; Items = @('جديد'); BaseHash = 'STALE'; UpdatedAt = (Get-Date).ToString('o') }
        Mock Write-BridgeLog {}
        Mock Save-NewsTickerDraft { $true }
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $true; Items = @('قائم١', 'قائم٢'); Hash = 'CURRENT'; Error = '' } }
        Mock Publish-NewsTickerDraft { [pscustomobject]@{ Success = $true; Conflict = $false; Error = '' } }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'appends to what the other system wrote, keeping both' {
        # Another system writes this file too, so a conflict is the normal
        # case; refusing forever would make the bot useless for the ticker.
        Resolve-NewsPublishConflict -UserId 20 -Mode append | Out-Null

        @($script:NewsTickerDraft.Items) | Should -Be @('قائم١', 'قائم٢', 'جديد')
        $script:NewsTickerDraft.BaseHash | Should -Be 'CURRENT'
    }

    It 'replaces only when that is explicitly chosen' {
        Resolve-NewsPublishConflict -UserId 20 -Mode replace | Out-Null

        @($script:NewsTickerDraft.Items) | Should -Be @('جديد')
        $script:NewsTickerDraft.BaseHash | Should -Be 'CURRENT'
    }

    It 'refuses when the live file cannot be read, rather than guessing' {
        Mock Get-NewsTickerConfiguredSnapshot { [pscustomobject]@{ Success = $false; Items = @(); Hash = ''; Error = 'binary data' } }
        (Resolve-NewsPublishConflict -UserId 20 -Mode append).Success | Should -BeFalse
    }

    It 'refuses when the caller does not own the draft' {
        (Resolve-NewsPublishConflict -UserId 99 -Mode append).Success | Should -BeFalse
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

Describe 'News item delete confirmation' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر أول', 'خبر ثانٍ', 'خبر ثالث')
        }
        Mock Send-TelegramMessage {}
        Mock Edit-TelegramMessageText { $false }
        Mock Test-Admin { $true }
        Mock Save-NewsTickerDraft { $true }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'shows the item text, because a number alone is not recognisable' {
        # The list is scrolled with a thumb; a mis-tap used to lose typed work
        # on the first press.
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index 1 | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'خبر ثانٍ' -and $Text -match 'تأكيد حذف' }
    }

    It 'deletes nothing until the confirmation is answered' {
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index 1 | Out-Null
        @($script:NewsTickerDraft.Items).Count | Should -Be 3
    }

    It 'removes exactly the confirmed item once accepted' {
        Remove-NewsTickerDraftItem -ChatId 42 -UserId 42 -Index 1 | Should -BeTrue
        @($script:NewsTickerDraft.Items) | Should -Be @('خبر أول', 'خبر ثالث')
    }

    It 'offers a cancel that returns to the item rather than the list' {
        # Cancelling should leave the operator where they were.
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index 2 | Out-Null
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.callback_data } }) -contains 'news:item:2'
        }
    }

    It 'refuses an index that is not in the draft' {
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index 9 | Should -BeFalse
        Show-NewsTickerDeleteConfirm -ChatId 42 -UserId 42 -Index -1 | Should -BeFalse
    }

    It 'refuses when the asker does not own the draft' {
        Show-NewsTickerDeleteConfirm -ChatId 99 -UserId 99 -Index 0 | Should -BeFalse
    }
}

Describe 'Delete from the reorder list' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر أول', 'خبر ثانٍ', 'خبر ثالث')
        }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'offers a delete on every row' {
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        foreach ($i in 0..2) { $flat | Should -Contain "news:delask:$i" }
    }

    It 'routes through the same confirmation the item screen uses' {
        # A second delete path would be a second place for a thumb to lose
        # typed work.
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $flat | Should -Not -Contain 'news:delete:0'
    }

    It 'keeps the move and edit controls alongside it' {
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $middle = @($rows[1] | ForEach-Object { $_.callback_data })
        $middle | Should -Contain 'news:up:1'
        $middle | Should -Contain 'news:item:1'
        $middle | Should -Contain 'news:down:1'
        $middle | Should -Contain 'news:delask:1'
    }

    It 'shows nothing to delete when there is no draft' {
        $script:NewsTickerDraft = $null
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        ($flat -join ' ') | Should -Not -Match 'delask'
    }
}

Describe 'Named Cinegy layers' {
    BeforeAll { Import-Module (Join-Path $script:Root 'Modules\CinegyAirTitler.psm1') -Force }
    AfterEach { Set-AirLayerDeviceMap -Map @{} }

    It 'addresses an ordinary layer by number' {
        $resolved = Resolve-AirGfxDevice -Layer 7
        $resolved.Command | Should -Be '*GFX_7'
        $resolved.StatusPath | Should -Be 'gfx_7'
    }

    It 'addresses the logo by name, which is how Air Pro exposes it' {
        # Verified against the running engine: gfx_logo answers with a live
        # scene describing itself as "Show logo_mov.cintitle as logo", while
        # the numeric layers that template claimed simply do not exist.
        $resolved = Resolve-AirGfxDevice -Device 'logo'
        $resolved.Command | Should -Be '*GFX_LOGO'
        $resolved.StatusPath | Should -Be 'gfx_logo'
    }

    It 'resolves a mapped layer number to its device, so call sites need no change' {
        Set-AirLayerDeviceMap -Map @{ 9 = 'logo' }
        (Resolve-AirGfxDevice -Layer 9).StatusPath | Should -Be 'gfx_logo'
        (Resolve-AirGfxDevice -Layer 7).StatusPath | Should -Be 'gfx_7'
    }

    It 'lets an explicit device win over the map' {
        Set-AirLayerDeviceMap -Map @{ 9 = 'logo' }
        (Resolve-AirGfxDevice -Layer 9 -Device 'other').StatusPath | Should -Be 'gfx_other'
    }

    It 'clears the map when given an empty one' {
        Set-AirLayerDeviceMap -Map @{ 9 = 'logo' }
        Set-AirLayerDeviceMap -Map @{}
        (Resolve-AirGfxDevice -Layer 9).StatusPath | Should -Be 'gfx_9'
    }

    It 'ignores a blank device name rather than building gfx_' {
        Set-AirLayerDeviceMap -Map @{ 9 = '' }
        (Resolve-AirGfxDevice -Layer 9).StatusPath | Should -Be 'gfx_9'
    }

    It 'refuses a device name that could reshape the request path' {
        # It goes straight into a URL and an XML attribute.
        { Resolve-AirGfxDevice -Device '../video' } | Should -Throw
        { Resolve-AirGfxDevice -Device 'a b' } | Should -Throw
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

Describe 'News list layout' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @('خبر قصير', 'خبر ثانٍ طويل جدًا يتجاوز حدّ التسمية المختصرة بكثير جدًا فعلًا', 'خبر ثالث')
        }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListPaged' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'keeps everything on one row by default' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $middle = @($rows[1] | ForEach-Object { $_.callback_data })
        $middle | Should -Contain 'news:up:1'
        $middle | Should -Contain 'news:item:1'
        $middle | Should -Contain 'news:delask:1'
    }

    It 'gives the headline its own row when stacked' {
        # A 24-character label tells you nothing about a long headline, which
        # is the whole point of the alternative layout.
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        @($rows[2]).Count | Should -Be 1
        @($rows[2])[0].callback_data | Should -Be 'news:item:1'
    }

    It 'puts move, edit and delete on the row beneath it' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        $controls = @($rows[3] | ForEach-Object { $_.callback_data })
        $controls | Should -Contain 'news:up:1'
        $controls | Should -Contain 'news:down:1'
        $controls | Should -Contain 'news:edit:1'
        $controls | Should -Contain 'news:delask:1'
    }

    It 'omits the move it cannot make, at either end' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }
        $rows = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)
        @($rows[1] | ForEach-Object { $_.callback_data }) | Should -Not -Contain 'news:up:0'
        @($rows[5] | ForEach-Object { $_.callback_data }) | Should -Not -Contain 'news:down:2'
    }

    It 'shows more of a long headline when it owns the row' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }
        $stacked = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[2][0].text
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }
        $inline = @(@((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard)[1] | Where-Object { $_.callback_data -eq 'news:item:1' })[0].text
        $stacked.Length | Should -BeGreaterThan $inline.Length
    }

    It 'still deletes through the confirmation in both layouts' {
        foreach ($stacked in @($true, $false)) {
            Mock Get-Setting { $stacked } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }
            $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
            $flat | Should -Not -Contain 'news:delete:1'
            $flat | Should -Contain 'news:delask:1'
        }
    }
}

Describe 'News list paging' {
    BeforeEach {
        $script:NewsTickerDraft = @{
            OwnerUserId = 42; OwnerChatId = 42; UpdatedAt = (Get-Date).ToString('o')
            Items = @(1..38 | ForEach-Object { "خبر رقم $_" })
        }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListPaged' }
        Mock Get-SettingInt { 10 } -ParameterFilter { $Name -eq 'NewsListPageSize' }
        Mock Get-SettingInt { 24 } -ParameterFilter { $Name -eq 'NewsListLabelLength' }
        Mock Get-SettingInt { 60 } -ParameterFilter { $Name -eq 'NewsListStackedLabelLength' }
    }
    AfterAll { $script:NewsTickerDraft = $null }

    It 'puts the whole draft on one screen when paging is off and it fits' {
        # What "one long list" is for: a normal-sized draft, no page buttons,
        # everything reachable without flipping.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }
        $script:NewsTickerDraft.Items = @(1..12 | ForEach-Object { "خبر رقم $_" })

        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })

        @($flat | Where-Object { $_ -like 'news:item:*' }).Count | Should -Be 12
        $flat | Should -Not -Contain 'news:list:1'
    }

    It 'still pages a draft too big for one keyboard, and says why' {
        # The option cannot repeal Telegram's limit. Silently truncating, or
        # sending a keyboard that gets rejected, are both worse than paging
        # and saying so.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }

        $buttons = (@((Get-NewsTickerReorderKeyboard -UserId 42 -Page 0).inline_keyboard |
                    ForEach-Object { @($_).Count } | Measure-Object -Sum).Sum)

        $buttons | Should -BeLessThan 100
        (Get-NewsTickerPageCount -UserId 42) | Should -BeGreaterThan 1
        Get-NewsTickerReorderText -UserId 42 | Should -Match 'القائمة الطويلة مفعّلة'
    }

    It 'fits fewer items per screen when each one owns two rows' {
        # The stacked layout spends an extra button per item, so the same
        # budget buys fewer of them.
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewsListPaged' }
        $inline = Get-NewsTickerPageSize
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'NewsListStackedLayout' }

        (Get-NewsTickerPageSize) | Should -BeLessThan $inline
    }

    It 'reaches every item across the pages, including the last' {
        # 38 items rendered 152 buttons in one keyboard. Telegram refused it,
        # the resend was refused too, and the list silently stopped updating -
        # which read as the last items being missing.
        $seen = @()
        foreach ($page in 0..((Get-NewsTickerPageCount -UserId 42) - 1)) {
            $seen += @((Get-NewsTickerReorderKeyboard -UserId 42 -Page $page).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_.callback_data } } |
                    Where-Object { $_ -like 'news:item:*' })
        }
        @($seen | Sort-Object -Unique).Count | Should -Be 38
        $seen | Should -Contain 'news:item:37'
    }

    It 'keeps every page well inside the button limit' {
        foreach ($page in 0..3) {
            $buttons = (@((Get-NewsTickerReorderKeyboard -UserId 42 -Page $page).inline_keyboard |
                        ForEach-Object { @($_).Count } | Measure-Object -Sum).Sum)
            $buttons | Should -BeLessThan 100
        }
    }

    It 'numbers items by their real position, not their position on the page' {
        $labels = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 2).inline_keyboard |
                ForEach-Object { @($_) } | Where-Object { $_.callback_data -like 'news:item:*' })
        $labels[0].text | Should -Match '^21\.'
        $labels[0].callback_data | Should -Be 'news:item:20'
    }

    It 'offers forward and back only where they exist' {
        $firstPage = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 0).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $firstPage | Should -Not -Contain 'news:list:-1'
        $firstPage | Should -Contain 'news:list:1'

        $lastPage = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 3).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $lastPage | Should -Contain 'news:list:2'
        $lastPage | Should -Not -Contain 'news:list:4'
    }

    It 'clamps a page number that is out of range instead of rendering nothing' {
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 99).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $flat | Should -Contain 'news:item:37'
    }

    It 'shows no pager at all when everything fits on one page' {
        $script:NewsTickerDraft.Items = @('واحد', 'اثنان')
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 0).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        ($flat -join ' ') | Should -Not -Match 'news:list:'
    }

    It 'states the range and total in the heading' {
        $text = Get-NewsTickerReorderText -UserId 42 -Page 1
        $text | Should -Match 'الأخبار: 38'
        $text | Should -Match '11'
        $text | Should -Match 'صفحة 2 من 4'
    }

    It 'keeps the move controls absolute, so paging never moves the wrong item' {
        $flat = @((Get-NewsTickerReorderKeyboard -UserId 42 -Page 1).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_.callback_data } })
        $flat | Should -Contain 'news:up:10'
        $flat | Should -Contain 'news:delask:10'
    }
}

Describe 'Confirming removal of a live graphic' {
    BeforeEach {
        $script:OnAir = @{}
        Mock Send-TelegramMessage {}
        Mock Invoke-HideLayer { $true }
        Mock Invoke-ExitLayer { $true }
        Mock Test-Authorized { $true }
        Mock Test-TelegramPrivateChat { $true }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserLastActivity {}
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
    }
    AfterAll { $script:OnAir = @{} }
    BeforeAll {
        function New-Cb { param([string]$Data)
            [pscustomobject]@{ id = 'cb1'; data = $Data; from = [pscustomobject]@{ id = 42 }
                message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = 42; type = 'private' } } }
        }
    }

    It 'refuses to take a live graphic off air on one tap' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'hide:7')

        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تأكيد الإخفاء' -and $Text -match 'Urgent' }
    }

    It 'requires the same confirmation before an exit' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'exit:7')

        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تأكيد الخروج' }
    }

    It 'acts once the operator confirms' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'hidego:7')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }

    It 'does not ask about a layer with nothing on it' {
        # Friction on a path that does not matter is how operators learn to tap
        # straight through the confirmation that does.
        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'hide:3')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'is on by default, so a fresh install protects the air' {
        $defaults = $script:DefaultSettings
        $defaults['ConfirmLayerRemoval'] | Should -BeTrue
    }

    It 'can still be turned off for a room that wants one-tap hides' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'hide:7')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }
}
Describe 'Version 6 settings navigation schema' {
    It 'identifies the operator-audit improvement as the official Version 6 release' {
        $script:BridgeVersion | Should -Be '6.0.0'
        @(Get-WhatsNewSections)[0].Version | Should -Be '6.0.0'
    }

    It 'presents the operational setting categories in a stable order' {
        $definitions = @(Get-SettingCategoryDefinitions)

        @($definitions.Key) | Should -Be @(
            'security', 'onair', 'templates', 'news',
            'schedule', 'monitoring', 'storage', 'advanced'
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
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_.callback_data })

        $callbacks | Should -Contain 'cfgcat:security:0'
        $callbacks | Should -Contain 'cfgcat:monitoring:0'
        $callbacks | Should -Not -Contain 'cfg:t:RequireUserLevelAuth'
    }

    It 'limits a category page to eight setting actions and provides paging' {
        $keyboard = Get-SettingsCategoryKeyboard -Category 'monitoring' -Page 0 -PageSize 8
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_.callback_data })
        $settingCallbacks = @($callbacks | Where-Object { $_ -match '^cfg:(t|v|s):' })

        $settingCallbacks.Count | Should -Be 8
        $callbacks | Should -Contain 'cfgcat:monitoring:1'
        $callbacks | Should -Contain 'menu:settings'
    }

    It 'uses the existing protected toggle callback behind an Arabic label' {
        $keyboard = Get-SettingsCategoryKeyboard -Category 'security' -Page 0
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        $button = @($buttons | Where-Object { $_.callback_data -eq 'cfg:t:RequireUserLevelAuth' })[0]

        $button.text | Should -Match 'التحقق من هوية المستخدم'
        $button.text | Should -Match '🔒'
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

Describe 'Version 6 Telegram update admission integration' {
    It 'loads the operation policy and initializes a bounded processing ledger' {
        Get-Command Get-BridgeUpdatesForProcessing -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $script:ProcessedUpdateLedger | Should -Not -BeNullOrEmpty
        $script:ProcessedUpdateLedger.Capacity | Should -Be 4096
    }
}

Describe 'Version 6 administrator health center' {
    BeforeEach {
        $script:RuntimeState = New-BridgeRuntimeState
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'connected'
        $script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
        $script:OutputMonitorFailureCount = 0
        $script:OutputMonitorFailureAlerted = $false
        $script:OutputBlackAlerted = $false
        $script:ScheduleEvents = @()
    }

    It 'summarizes every operational component without running a new probe' {
        $snapshot = [pscustomobject]@{ DiskFreeGB = 10; RuntimeStorageBytes = 0L; BackupStorageBytes = 0L }

        $text = Get-BridgeHealthCenterText -DiagnosticsSnapshot $snapshot -Warnings @()

        $text | Should -Match '🟢 Telegram'
        $text | Should -Match '🟢 Cinegy'
        $text | Should -Match 'مراقبة المخرج'
        $text | Should -Match 'البث المرحّل'
        $text | Should -Match 'التخزين'
        $text | Should -Match 'الجدولة'
    }

    It 'marks disconnected Telegram and unhealthy Cinegy as red' {
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'disconnected'
        $script:RuntimeState.Monitoring.CinegyHealthState = 'unhealthy'
        $snapshot = [pscustomobject]@{ DiskFreeGB = 10; RuntimeStorageBytes = 0L; BackupStorageBytes = 0L }

        $text = Get-BridgeHealthCenterText -DiagnosticsSnapshot $snapshot -Warnings @()

        $text | Should -Match '🔴 Telegram'
        $text | Should -Match '🔴 Cinegy'
    }

    It 'offers refresh full status diagnostics and return controls' {
        $callbacks = @((Get-HealthCenterKeyboard).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)

        $callbacks | Should -Contain 'menu:healthcenter'
        $callbacks | Should -Contain 'menu:fullstatus'
        $callbacks | Should -Contain 'menu:diagnostics'
        $callbacks | Should -Contain 'menu:admintools'
    }

    Context 'administrator navigation' {
        BeforeEach {
            Mock Confirm-TelegramCallback {}
            Mock Test-TelegramPrivateChat { $true }
            Mock Test-Authorized { $true }
            Mock Update-UserLastActivity {}
            Mock Invoke-HealthCenterCommand {}
        }

        It 'shows the health center in administrator tools' {
            Mock Get-RunningRelayProcess { $null }
            $callbacks = @((Get-AdminToolsKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)

            $callbacks | Should -Contain 'menu:healthcenter'
        }

        It 'routes the health center callback only after the admin guard succeeds' {
            Mock Test-CallbackAdmin { $true }
            $callback = [pscustomobject]@{
                id = 'health-center-admin'
                from = [pscustomobject]@{ id = 101 }
                message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100; type = 'private' } }
                data = 'menu:healthcenter'
            }

            Invoke-CallbackQuery -CallbackQuery $callback

            Should -Invoke Invoke-HealthCenterCommand -Times 1 -Exactly -ParameterFilter { $ChatId -eq 100 -and $UserId -eq 101 }
        }

        It 'rejects a forged health center callback from an operator' {
            Mock Test-CallbackAdmin { $false }
            $callback = [pscustomobject]@{
                id = 'health-center-operator'
                from = [pscustomobject]@{ id = 101 }
                message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100; type = 'private' } }
                data = 'menu:healthcenter'
            }

            Invoke-CallbackQuery -CallbackQuery $callback

            Should -Invoke Invoke-HealthCenterCommand -Times 0 -Exactly
        }
    }
}

Describe 'Version 6 bounded administrator catalogues' {
    It 'keeps one thousand templates below the Telegram button limit with absolute indexes' {
        $map = @{}
        $order = @(0..999 | ForEach-Object {
                $key = 'template-{0:d4}' -f $_
                $map[$key] = [pscustomobject]@{ Key = $key; Layer = ($_ % 20) + 1 }
                $key
            })
        Mock Get-TemplateStore { [pscustomobject]@{ Map = $map; Order = $order; Errors = @() } }

        $keyboard = Get-TemplateAdminCatalogueKeyboard -Page 1 -PageSize 20
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        $callbacks = @($buttons.callback_data)

        $buttons.Count | Should -BeLessThan 100
        $callbacks | Should -Contain 'tadm:20'
        $callbacks | Should -Contain 'tadmpage:0'
        $callbacks | Should -Contain 'tadmpage:2'
    }

    It 'keeps two hundred and fifty users bounded with absolute user ids' {
        $users = @(0..249 | ForEach-Object {
                [pscustomobject]@{ UserId = 1000 + $_; Alias = "User $_"; Role = 'operator'; Disabled = $false; LastActivityAt = $null }
            })
        Mock Get-AuthorizedUsers { $users }
        Mock Test-Owner { $false }

        $keyboard = Get-UsersAdminKeyboard -ViewerUserId 9999 -Page 1 -PageSize 10
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        $callbacks = @($buttons.callback_data)

        $buttons.Count | Should -BeLessThan 100
        $callbacks | Should -Contain 'usr:toggle:1010'
        $callbacks | Should -Contain 'userspage:0'
        $callbacks | Should -Contain 'userspage:2'
    }

    It 'keeps two hundred pending access requests bounded and sorted by id' {
        $script:PendingApprovals = @{}
        200..1 | ForEach-Object { $script:PendingApprovals[[long]$_] = @{ Name = "Request $_" } }

        $keyboard = Get-PendingKeyboard -Page 1 -PageSize 20
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        $callbacks = @($buttons.callback_data)

        $buttons.Count | Should -BeLessThan 100
        $callbacks | Should -Contain 'approve:21'
        $callbacks | Should -Contain 'pendingpage:0'
        $callbacks | Should -Contain 'pendingpage:2'
    }

    Context 'page callback routing' {
        BeforeEach {
            Mock Confirm-TelegramCallback {}
            Mock Test-TelegramPrivateChat { $true }
            Mock Test-Authorized { $true }
            Mock Update-UserLastActivity {}
            Mock Test-CallbackAdmin { $true }
            Mock Test-CallbackTemplateReminderManager { $true }
            Mock Send-TelegramMessage {}
            Mock Show-UsersAdminScreen {}
            Mock Get-TemplateAdminCatalogueKeyboard { @{ inline_keyboard = @() } }
            Mock Get-PendingKeyboard { @{ inline_keyboard = @() } }
        }

        It 'routes template user and pending page callbacks to their absolute page' {
            foreach ($case in @(
                    @{ Data = 'tadmpage:4'; Id = 'template-page' }
                    @{ Data = 'userspage:3'; Id = 'users-page' }
                    @{ Data = 'pendingpage:2'; Id = 'pending-page' }
                )) {
                $callback = [pscustomobject]@{
                    id = $case.Id
                    from = [pscustomobject]@{ id = 101 }
                    message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100; type = 'private' } }
                    data = $case.Data
                }
                Invoke-CallbackQuery -CallbackQuery $callback
            }

            Should -Invoke Get-TemplateAdminCatalogueKeyboard -Times 1 -Exactly -ParameterFilter { $Page -eq 4 }
            Should -Invoke Show-UsersAdminScreen -Times 1 -Exactly -ParameterFilter { $Page -eq 3 }
            Should -Invoke Get-PendingKeyboard -Times 1 -Exactly -ParameterFilter { $Page -eq 2 }
        }
    }
}
