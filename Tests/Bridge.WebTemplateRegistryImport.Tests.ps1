. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

function global:ConvertTo-RegistryImportFixture {
    param($Document)
    $text = ConvertTo-Json -InputObject $Document -Depth 16
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
}

Describe 'Reviewed Web template registry import' {
    BeforeEach {
        $script:ImportFixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:ImportFixtureCatalogue = Join-Path $script:ImportFixtureRoot 'approved'
        $null = New-Item -Path $script:ImportFixtureCatalogue -ItemType Directory -Force
        $script:ImportFixtureRegistry = Join-Path $script:ImportFixtureRoot 'registry.json'
        $script:ImportFixtureScene = Join-Path $script:ImportFixtureCatalogue 'new.cintitle'
        [IO.File]::WriteAllText($script:ImportFixtureScene, '<synthetic />')
        $script:ImportFixtureDocument = [ordered]@{ Legacy = @{ path = '\\never-visit.invalid\graphics\legacy.cintitle'; layer = 21 } }
        [IO.File]::WriteAllText($script:ImportFixtureRegistry, (ConvertTo-Json $script:ImportFixtureDocument))
        $script:ImportFixtureBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ImportFixtureRegistry))
        $script:ImportFixtureDocument.New = @{ path = $script:ImportFixtureScene; layer = 31 }
        $script:ImportFixtureOriginalLog = $script:logDir
        $script:logDir = $script:ImportFixtureRoot
        $script:ImportFixtureRequest = {
            param([string]$Action, [string]$ReviewToken = '')
            $policy = Get-WebTemplateRegistryTransferPolicy
            $transferId = [guid]::NewGuid().ToString('N')
            $path = Join-Path $policy.data.directory "upload-$transferId.json"
            $bytes = [Convert]::FromBase64String((ConvertTo-RegistryImportFixture -Document $script:ImportFixtureDocument))
            [IO.File]::WriteAllBytes($path, $bytes)
            try {
                Invoke-WebChannelOperation -Request @{ op = 'air.template-registry-import'; args = @{
                        actor = 4321; action = $Action; review = $ReviewToken; transferId = $transferId
                    } }
            }
            finally { Remove-Item -LiteralPath $path -Force }
        }
        $script:ImportFixturePriorOnAir = $script:OnAir
        $script:OnAir = @{}
        Mock Get-TemplateRegistryFilePath { $script:ImportFixtureRegistry }
        Mock Get-WebSceneCatalogueRoot { $script:ImportFixtureCatalogue }
        Mock Test-WebSceneCatalogueAccess { $Actor -eq 4321 }
        Mock Add-AuditEntry {}
    }

    AfterEach {
        $script:OnAir = $script:ImportFixturePriorOnAir
        $script:logDir = $script:ImportFixtureOriginalLog
    }

    It 'reviews the changes, preserves an unprobed legacy path, backs up the prior bytes and imports the reviewed file' {
        $review = & $script:ImportFixtureRequest review
        $review.ok | Should -BeTrue -Because ([string](Get-JsonProp $review 'error'))
        $review.data.added | Should -Be 1
        $review.data.unchanged | Should -Be 1
        ($review | ConvertTo-Json -Depth 5) | Should -Not -Match 'cintitle|never-visit|approved'
        ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ImportFixtureRegistry))) | Should -BeExactly $script:ImportFixtureBytes
        $commit = & $script:ImportFixtureRequest confirm $review.data.review
        $commit.ok | Should -BeTrue -Because ([string](Get-JsonProp $commit 'error'))
        ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ImportFixtureRegistry))) |
            Should -BeExactly (ConvertTo-RegistryImportFixture -Document $script:ImportFixtureDocument)
        $backup = Get-ChildItem -LiteralPath "$script:ImportFixtureRegistry.backups" -File
        ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup.FullName))) | Should -BeExactly $script:ImportFixtureBytes
        Should -Invoke Add-AuditEntry -Times 1 -Exactly
        (& $script:ImportFixtureRequest confirm $review.data.review).error | Should -Be 'template_registry_import_stale'
    }

    It 'refuses remote, outside or stream paths before touching any supplied path' {
        $null = Get-WebTemplateRegistryTransferPolicy
        Mock Get-WebTemplateRegistryTransferDirectory { Get-Item -LiteralPath (Join-Path $script:ImportFixtureRoot 'web-registry-transfer') }
        Mock Get-WebTemplateRegistryExportFile { Get-Item -LiteralPath $script:ImportFixtureRegistry }
        Mock Get-WebSceneItem { throw 'No submitted path can be touched for this rejected document.' }
        foreach ($submitted in @(
                '\\never-visit.invalid\graphics\new.cintitle',
                (Join-Path $script:ImportFixtureRoot 'outside.cintitle'),
                "$($script:ImportFixtureScene):unsafe.cintitle",
                (Join-Path $script:ImportFixtureCatalogue 'sub\..\new.cintitle')
            )) {
            $script:ImportFixtureDocument.New.path = $submitted
            (& $script:ImportFixtureRequest review).error | Should -Be 'template_registry_import_path'
        }
        Should -Invoke Get-WebSceneItem -Times 0 -Exactly
        Should -Invoke Add-AuditEntry -Times 0 -Exactly
    }

    It 'rechecks schedules and identifies substituted uploads and replaced scenes before saving' {
        $review = & $script:ImportFixtureRequest review
        $review.ok | Should -BeTrue -Because ([string](Get-JsonProp $review 'error'))
        $script:ImportFixtureDocument.New.layer = 32
        (& $script:ImportFixtureRequest confirm $review.data.review).error | Should -Be 'template_registry_import_stale'
        $script:ImportFixtureDocument.New.layer = 31
        $review = & $script:ImportFixtureRequest review
        [IO.File]::AppendAllText($script:ImportFixtureScene, '<changed />')
        (& $script:ImportFixtureRequest confirm $review.data.review).error | Should -Be 'template_registry_import_stale'
        $review = & $script:ImportFixtureRequest review
        Mock Get-UpcomingScheduleEvents { @{ TemplateKey = 'New' } }
        (& $script:ImportFixtureRequest confirm $review.data.review).error | Should -Be 'scene_definition_scheduled'
        ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ImportFixtureRegistry))) | Should -BeExactly $script:ImportFixtureBytes
        Should -Invoke Add-AuditEntry -Times 0 -Exactly
    }
}
