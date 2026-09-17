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
