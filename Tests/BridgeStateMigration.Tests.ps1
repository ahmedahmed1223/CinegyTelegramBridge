#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeStateMigration.psm1') -Force
}

Describe 'Versioned bridge state migration' {
    It 'treats an unwrapped legacy document as version zero' {
        $result = Invoke-BridgeStateMigration -Document ([pscustomobject]@{ Count = 4 }) -TargetVersion 0 -Migrations @{}

        $result.Success | Should -BeTrue
        $result.Version | Should -Be 0
        $result.Data.Count | Should -Be 4
    }

    It 'applies every migration step in order and returns a current envelope' {
        $migrations = @{
            0 = { param($data) [pscustomobject]@{ Count = $data.Count; Enabled = $true } }
            1 = { param($data) [pscustomobject]@{ Total = $data.Count; Enabled = $data.Enabled } }
        }

        $result = Invoke-BridgeStateMigration -Document ([pscustomobject]@{ Count = 4 }) -TargetVersion 2 -Migrations $migrations

        $result.Success | Should -BeTrue
        $result.Version | Should -Be 2
        $result.Data.Total | Should -Be 4
        $result.Data.Enabled | Should -BeTrue
    }

    It 'rejects a missing migration step without returning partial data as success' {
        $result = Invoke-BridgeStateMigration -Document ([pscustomobject]@{ Count = 4 }) -TargetVersion 2 -Migrations @{ 0 = { param($data) $data } }

        $result.Success | Should -BeFalse
        $result.Error | Should -Match '1'
    }

    It 'rejects a document newer than this bridge understands' {
        $document = ConvertTo-BridgeStateEnvelope -Data ([pscustomobject]@{ Count = 4 }) -Version 3

        $result = Invoke-BridgeStateMigration -Document $document -TargetVersion 2 -Migrations @{}

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'newer'
    }
}
