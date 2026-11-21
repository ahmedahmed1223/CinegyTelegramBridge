. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Reviewed Web template registry export' {
    BeforeEach {
        $script:RegistryExportFixture = Join-Path $TestDrive "registry-export-$([guid]::NewGuid().ToString('N')).json"
        $fixture = @{ Teaser = @{ path = 'C:\catalogue\teaser.cintitle'; layer = 7; fields = @('TITLE')
                presets = @(@{ name = 'Stored fixture'; values = @('Exact Ärabic عربي') })
            } }
        [IO.File]::WriteAllText($script:RegistryExportFixture, ($fixture | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($true))
        $script:RegistryExportExpectedBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:RegistryExportFixture))
        $script:RegistryExportPriorLog = $script:logDir
        $script:logDir = $TestDrive
        Mock Get-TemplateRegistryFilePath { $script:RegistryExportFixture }
        Mock Test-WebSceneCatalogueAccess { $Actor -in 4321, 4322 }
        Mock Add-AuditEntry {}
    }
    AfterEach { $script:logDir = $script:RegistryExportPriorLog }

    It 'returns no content at review and delivers the exact bytes only to the same actor once' {
        $review = Invoke-WebChannelOperation -Request @{ op = 'air.template-registry-export'; args = @{ actor = 4321; action = 'review'; path = '\\untrusted\registry.json' } }
        $review.ok | Should -BeTrue -Because ([string](Get-JsonProp $review 'error'))
        $review.data.templates | Should -Be 1
        $review.data.bytes | Should -BeGreaterThan 0
        ($review | ConvertTo-Json -Depth 5) | Should -Not -Match 'base64|catalogue|Stored fixture|Exact'
        $policy = Invoke-WebTemplateRegistryExport -Arguments @{ actor = 4321; action = 'prepare' }
        $transferId = [guid]::NewGuid().ToString('N')
        $downloadPath = Join-Path $policy.data.directory "download-$transferId.json"
        [IO.File]::WriteAllBytes($downloadPath, [byte[]]@())
        $command = @{ actor = 4322; action = 'download'; review = $review.data.review; transferId = $transferId; path = '\\untrusted\another.json' }
        (Invoke-WebChannelOperation -Request @{ op = 'air.template-registry-export'; args = $command }).error |
            Should -Be 'template_registry_export_stale'
        $command.actor = 4321
        $download = Invoke-WebChannelOperation -Request @{ op = 'air.template-registry-export'; args = $command }
        $download.ok | Should -BeTrue
        ([Convert]::ToBase64String([IO.File]::ReadAllBytes($downloadPath))) | Should -BeExactly $script:RegistryExportExpectedBytes
        (Invoke-WebChannelOperation -Request @{ op = 'air.template-registry-export'; args = $command }).error |
            Should -Be 'template_registry_export_stale'
        (Test-TemplateRegistryImport -Path $script:RegistryExportFixture).Success | Should -BeTrue
        Should -Invoke Add-AuditEntry -Times 1 -Exactly
    }

    It 'rejects changed bytes after review and never sends a partial export over the size limit' {
        $review = Invoke-WebTemplateRegistryExport -Arguments @{ actor = 4321; action = 'review' }
        $review.ok | Should -BeTrue -Because ([string](Get-JsonProp $review 'error'))
        [IO.File]::AppendAllText($script:RegistryExportFixture, ' ')
        (Invoke-WebTemplateRegistryExport -Arguments @{ actor = 4321; action = 'download'; review = $review.data.review }).error |
            Should -Be 'template_registry_export_stale'
        $stream = [IO.File]::OpenWrite($script:RegistryExportFixture)
        try { $stream.SetLength(10MB + 1) }
        finally { $stream.Dispose() }
        (Invoke-WebTemplateRegistryExport -Arguments @{ actor = 4321; action = 'review' }).error |
            Should -Be 'template_registry_export_size'
        Should -Invoke Add-AuditEntry -Times 0 -Exactly
    }

    It 'checks authorization and rejects UNC registry policy before probing the filesystem' {
        Mock Get-TemplateRegistryFilePath { '\\untrusted\never-visited\registry.json' }
        Mock Get-WebSceneItem { throw 'The UNC registry must never be probed.' }
        (Invoke-WebTemplateRegistryExport -Arguments @{ actor = 7777; action = 'review' }).error | Should -Be 'forbidden'
        Should -Invoke Get-TemplateRegistryFilePath -Times 0 -Exactly
        (Invoke-WebTemplateRegistryExport -Arguments @{ actor = 4321; action = 'review' }).error |
            Should -Be 'template_registry_export_unavailable'
        Should -Invoke Get-WebSceneItem -Times 0 -Exactly
    }
}
