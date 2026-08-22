#requires -Version 7

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
        $names | Should -Contain 'release-manifest.json'
        foreach ($forbidden in @('config.json', 'secrets.dpapi.json', 'templates.json', 'onair.json', 'audit.jsonl', 'bridge.log', 'schedule.json')) {
            $names | Should -Not -Contain $forbidden
        }
        @($names | Where-Object { $_ -match '(^|/)(logs|artifacts|backups?)(/|$)|\.(bak|tmp|log|jsonl)$' }).Count | Should -Be 0
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
        $manifest.Version | Should -Match '^\d+\.\d+\.\d+$'
    }
}
