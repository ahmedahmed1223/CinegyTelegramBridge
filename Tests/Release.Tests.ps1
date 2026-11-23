#requires -Version 7

Describe 'Release version format' {
    It 'packages a safe semantic-version prerelease identifier' {
        $root = Split-Path -Parent $PSScriptRoot
        $build = & (Join-Path $root 'Build-Release.ps1') -Version '6.0.0-preview.1' -SkipChecks -OutputDirectory $TestDrive

        $build.Version | Should -Be '6.0.0-preview.1'
        [IO.Path]::GetFileName($build.ZipPath) | Should -Be 'CinegyTelegramBridge-6.0.0-preview.1.zip'
    }
}

Describe 'Release package safety' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $build = & (Join-Path $root 'Build-Release.ps1') -SkipChecks -OutputDirectory $TestDrive
        $script:ReleaseZip = [string]$build.ZipPath
        $script:ReleaseChecksum = [string]$build.ChecksumPath
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }

    It 'contains only distributable files and no runtime state or secrets files' {
        $archive = [IO.Compression.ZipFile]::OpenRead($script:ReleaseZip)
        try { $names = @($archive.Entries | ForEach-Object FullName) }
        finally { $archive.Dispose() }

        $names | Should -Contain 'config.example.json'
        $names | Should -Contain 'templates.example.json'
        $names | Should -Contain 'docs/VERSION-6.md'
        $names | Should -Contain 'release-manifest.json'
        $names | Should -Contain 'scripts/Test-ServiceLifecycle.ps1'
        $names | Should -Contain 'scripts/Update-BridgeWeb.ps1'
        foreach ($forbidden in @('config.json', 'secrets.dpapi.json', 'templates.json', 'onair.json', 'audit.jsonl', 'bridge.log', 'schedule.json', 'autohide.json', 'template-reminders.json')) {
            $names | Should -Not -Contain $forbidden
        }
        @($names | Where-Object { $_ -match '(^|/)(logs|artifacts|backups?)(/|$)|\.(bak|tmp|log|jsonl)$' }).Count | Should -Be 0
    }

    It 'packages every file the bridge loads at startup' {
        # The safety test above asks what must NOT be in the package. Nothing
        # asked the other question, and the answer had quietly become "thirteen
        # of them are missing": TelegramBridge.ps1 dot-sources each part by
        # name, so an extracted release without one throws on the first load and
        # never reaches a screen. Read off the loader itself rather than a
        # second hand-kept list, because a hand-kept list is what drifted.
        $bridge = Get-Content -LiteralPath (Join-Path $root 'TelegramBridge.ps1') -Raw
        $required = @(
            [regex]::Matches($bridge, "(?m)^\s+'(Bridge\.[A-Za-z.]+)'\s*$") | ForEach-Object { 'Parts/' + $_.Groups[1].Value + '.ps1' }
            [regex]::Matches($bridge, 'Join-Path \$moduleRoot "([A-Za-z]+\.psm1)"') | ForEach-Object { 'Modules/' + $_.Groups[1].Value }
        )
        $required.Count | Should -BeGreaterThan 40 -Because 'the loader should have been read; a regex that matches nothing would pass this test vacuously'

        $archive = [IO.Compression.ZipFile]::OpenRead($script:ReleaseZip)
        try { $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }) }
        finally { $archive.Dispose() }

        $missing = @($required | Where-Object { $names -notcontains $_ } | Sort-Object)
        $missing | Should -BeNullOrEmpty -Because "the bridge loads these by name and the package does not carry them, so the extracted release cannot start: $($missing -join ', ')"
    }

    It 'runs the managed-service lifecycle check in Windows CI' {
        $workflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\windows-ci.yml') -Raw

        $workflow | Should -Match 'Test-ServiceLifecycle\.ps1'
    }

    It 'does not require destructive smoke commands in a live working environment' {
        $gate = Get-Content -LiteralPath (Join-Path $root 'Run-Checks.ps1') -Raw
        $readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw

        $gate | Should -Match 'dedicated non-production layer'
        $gate | Should -Match 'Do not send test SHOW/HIDE/EXIT commands in a working environment'
        $readme | Should -Match 'do \*\*not\*\* send test SHOW/HIDE/EXIT'
    }

    It 'publishes a matching SHA-256 checksum and unsigned manifest when no certificate is requested' {
        $expected = ((Get-Content -LiteralPath $script:ReleaseChecksum -Raw).Trim() -split '\s+')[0]
        (Get-FileHash -LiteralPath $script:ReleaseZip -Algorithm SHA256).Hash | Should -Be $expected

        $archive = [IO.Compression.ZipFile]::OpenRead($script:ReleaseZip)
        try {
            $entry = $archive.GetEntry('release-manifest.json')
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json }
            finally { $reader.Dispose() }
        }
        finally { $archive.Dispose() }
        $manifest.AuthenticodeSigned | Should -BeFalse
        $manifest.Version | Should -Match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
    }

    It 'identifies the packaged README with the same version as the manifest' {
        $archive = [IO.Compression.ZipFile]::OpenRead($script:ReleaseZip)
        try {
            $manifestReader = [IO.StreamReader]::new($archive.GetEntry('release-manifest.json').Open())
            $readmeReader = [IO.StreamReader]::new($archive.GetEntry('README.md').Open())
            try {
                $manifest = $manifestReader.ReadToEnd() | ConvertFrom-Json
                $readme = $readmeReader.ReadToEnd()
            }
            finally { $manifestReader.Dispose(); $readmeReader.Dispose() }
        }
        finally { $archive.Dispose() }

        $readme | Should -Match ([regex]::Escape("## Version $($manifest.Version)"))
    }
}

Describe 'Web-only update' {
    BeforeAll {
        $script:WebUpdater = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Update-BridgeWeb.ps1'
    }

    BeforeEach {
        $sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $station = Join-Path $sandbox 'station'
        $web = Join-Path $station 'dist/web'
        $bundle = Join-Path $sandbox 'bundle'
        $newWeb = Join-Path $bundle 'dist/web'
        foreach ($folder in @("$web/wwwroot/assets", "$newWeb/wwwroot/assets", "$station/dist/BridgeManager", "$station/logs/web")) {
            [IO.Directory]::CreateDirectory($folder) | Out-Null
        }
        Set-Content -LiteralPath "$station/TelegramBridge.ps1" -Value "`$script:BridgeVersion = '9.1.0'"
        Set-Content -LiteralPath "$web/CinegyBridge.Web.exe" -Value 'old executable'
        Set-Content -LiteralPath "$web/wwwroot/index.html" -Value 'old page'
        Set-Content -LiteralPath "$web/wwwroot/assets/old.js" -Value 'old javascript'
        Set-Content -LiteralPath "$web/wwwroot/index.html.br" -Value 'old compressed page'
        Set-Content -LiteralPath "$web/appsettings.json" -Value 'local web settings'
        Set-Content -LiteralPath "$station/dist/BridgeManager/BridgeManager.exe" -Value 'original manager'
        Set-Content -LiteralPath "$station/logs/web/session.json" -Value 'original sessions'
        Set-Content -LiteralPath "$station/config.json" -Value 'original station settings'

        Set-Content -LiteralPath "$newWeb/CinegyBridge.Web.exe" -Value 'new executable'
        Set-Content -LiteralPath "$newWeb/wwwroot/index.html" -Value 'new page'
        Set-Content -LiteralPath "$newWeb/wwwroot/assets/new.js" -Value 'new javascript'
        Set-Content -LiteralPath "$newWeb/wwwroot/assets/new.js.gz" -Value 'new compressed javascript'
        Set-Content -LiteralPath "$bundle/config.json" -Value 'archive settings must be ignored'
        $script:WebUpdateManifest = @{
            Product = 'CinegyTelegramBridge'; Version = '9.2.0'; MinimumWebBridgeVersion = '9.1.0'
            Files = @(Get-ChildItem -LiteralPath $newWeb -File -Recurse | ForEach-Object {
                    @{
                        Name = [IO.Path]::GetRelativePath($bundle, $_.FullName).Replace('\', '/')
                        Length = $_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName).Hash
                    }
                })
        }
        $script:WebUpdateZip = Join-Path $sandbox 'release.zip'
    }

    It 'updates only the web payload and restores it from the retained backup' {
        $script:WebUpdateManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$bundle/release-manifest.json"
        Compress-Archive -Path "$bundle/*" -DestinationPath $script:WebUpdateZip
        $update = & $script:WebUpdater -BridgeRoot $station -ReleaseZip $script:WebUpdateZip -ExpectedSha256 (Get-FileHash -LiteralPath $script:WebUpdateZip).Hash -RunningBridgeVersion 9.1.0

        $update.Version | Should -Be '9.2.0'
        Get-Content -LiteralPath "$web/CinegyBridge.Web.exe" | Should -Be 'new executable'
        Get-Content -LiteralPath "$web/wwwroot/assets/new.js" | Should -Be 'new javascript'
        Get-Content -LiteralPath "$web/wwwroot/assets/new.js.gz" | Should -Be 'new compressed javascript'
        Test-Path -LiteralPath "$web/wwwroot/assets/old.js" | Should -BeFalse
        Test-Path -LiteralPath "$web/wwwroot/index.html.br" | Should -BeFalse
        Get-Content -LiteralPath "$web/appsettings.json" | Should -Be 'local web settings'
        Get-Content -LiteralPath "$station/dist/BridgeManager/BridgeManager.exe" | Should -Be 'original manager'
        Get-Content -LiteralPath "$station/logs/web/session.json" | Should -Be 'original sessions'
        Get-Content -LiteralPath "$station/config.json" | Should -Be 'original station settings'

        # Recover even if execution was interrupted with the executable between versions.
        Remove-Item -LiteralPath "$web/CinegyBridge.Web.exe"
        & $script:WebUpdater -BridgeRoot $station -RollbackDirectory $update.BackupDirectory | Out-Null
        Get-Content -LiteralPath "$web/CinegyBridge.Web.exe" | Should -Be 'old executable'
        Get-Content -LiteralPath "$web/wwwroot/assets/old.js" | Should -Be 'old javascript'
        Get-Content -LiteralPath "$web/wwwroot/index.html.br" | Should -Be 'old compressed page'
        Test-Path -LiteralPath "$web/wwwroot/assets/new.js" | Should -BeFalse
    }

    It 'rejects a different ZIP checksum and an incompatible running bridge before switching files' {
        $script:WebUpdateManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$bundle/release-manifest.json"
        Compress-Archive -Path "$bundle/*" -DestinationPath $script:WebUpdateZip
        { & $script:WebUpdater -BridgeRoot $station -ReleaseZip $script:WebUpdateZip -ExpectedSha256 ('0' * 64) -RunningBridgeVersion 9.1.0 } |
            Should -Throw '*ZIP SHA-256 does not match*'
        { & $script:WebUpdater -BridgeRoot $station -ReleaseZip $script:WebUpdateZip -ExpectedSha256 (Get-FileHash -LiteralPath $script:WebUpdateZip).Hash -RunningBridgeVersion 9.0.0 } |
            Should -Throw '*requires bridge 9.1.0*'
        Get-Content -LiteralPath "$web/CinegyBridge.Web.exe" | Should -Be 'old executable'
    }

    It 'rejects a changed asset after checking the ZIP checksum' {
        $script:WebUpdateManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$bundle/release-manifest.json"
        Set-Content -LiteralPath "$newWeb/wwwroot/assets/new.js" -Value 'bad javascript'
        Compress-Archive -Path "$bundle/*" -DestinationPath $script:WebUpdateZip
        { & $script:WebUpdater -BridgeRoot $station -ReleaseZip $script:WebUpdateZip -ExpectedSha256 (Get-FileHash -LiteralPath $script:WebUpdateZip).Hash -RunningBridgeVersion 9.1.0 } |
            Should -Throw '*payload hash or size mismatch*'
        Get-Content -LiteralPath "$web/wwwroot/assets/old.js" | Should -Be 'old javascript'
    }

    It 'never stages a manifest path that escapes the web payload' {
        $script:WebUpdateManifest.Files += @{
            Name = 'dist/web/wwwroot/assets/../../../config.json'; Length = 32; SHA256 = '0' * 64
        }
        $script:WebUpdateManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$bundle/release-manifest.json"
        Compress-Archive -Path "$bundle/*" -DestinationPath $script:WebUpdateZip
        { & $script:WebUpdater -BridgeRoot $station -ReleaseZip $script:WebUpdateZip -ExpectedSha256 (Get-FileHash -LiteralPath $script:WebUpdateZip).Hash -RunningBridgeVersion 9.1.0 } |
            Should -Throw '*Invalid or duplicate web payload entry*'
        Get-Content -LiteralPath "$station/config.json" | Should -Be 'original station settings'
    }
}

Describe 'Packaged web and manager' {
    It 'puts the verified web and manager builds where the manager can find them without copying runtime data' {
        $root = Split-Path -Parent $PSScriptRoot
        $web = Join-Path $TestDrive 'fixture-web'
        $manager = Join-Path $TestDrive 'fixture-manager'
        New-Item -ItemType Directory -Path (Join-Path $web 'wwwroot/assets'), $manager | Out-Null
        foreach ($fixtureFile in @('CinegyBridge.Web.exe', 'wwwroot/index.html', 'wwwroot/index.html.br',
                'wwwroot/assets/index.js', 'wwwroot/assets/index.js.gz', 'config.json', 'wwwroot/assets/session.json', 'wwwroot/assets/session.json.gz')) {
            Set-Content -LiteralPath (Join-Path $web $fixtureFile) -Value 'test fixture'
        }
        Set-Content -LiteralPath (Join-Path $manager 'BridgeManager.exe') -Value 'test fixture'
        Set-Content -LiteralPath (Join-Path $manager 'BridgeManager-selftest.log') -Value 'test fixture'
        $build = & (Join-Path $root 'Build-Release.ps1') -SkipChecks -OutputDirectory (Join-Path $TestDrive 'bundle') `
            -WebBundleDirectory $web -ManagerBundleDirectory $manager
        $archive = [IO.Compression.ZipFile]::OpenRead($build.ZipPath)
        try {
            $names = @($archive.Entries.FullName)
            $reader = [IO.StreamReader]::new($archive.GetEntry('release-manifest.json').Open())
            try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json }
            finally { $reader.Dispose() }
        }
        finally { $archive.Dispose() }
        foreach ($requiredPath in @('dist/web/CinegyBridge.Web.exe', 'dist/web/wwwroot/index.html', 'dist/web/wwwroot/assets/index.js',
                'dist/web/wwwroot/index.html.br', 'dist/web/wwwroot/assets/index.js.gz', 'dist/BridgeManager/BridgeManager.exe')) { $names | Should -Contain $requiredPath }
        ($names -join "`n") | Should -Not -Match '(?m)(^|/)(config\.json|session\.json(?:\.gz)?|BridgeManager-selftest\.log)$'
        $manifest.MinimumWebBridgeVersion | Should -Be $build.Version
    }
}
