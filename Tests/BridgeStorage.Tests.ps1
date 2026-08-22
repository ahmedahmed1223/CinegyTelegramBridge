#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeStorage.psm1') -Force
}

Describe 'Validated JSON storage module' {
    It 'writes a validated primary and matching backup atomically' {
        $path = Join-Path $TestDrive 'state\sample.json'

        Write-BridgeValidatedJson -Path $path -Json '{"layer":7}' | Should -BeTrue

        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).layer | Should -Be 7
        (Get-Content -LiteralPath "$path.bak" -Raw | ConvertFrom-Json).layer | Should -Be 7
        Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
        Test-Path -LiteralPath "$path.bak.tmp" | Should -BeFalse
    }

    It 'rejects invalid JSON without replacing an existing valid primary' {
        $path = Join-Path $TestDrive 'protected.json'
        Set-Content -LiteralPath $path -Value '{"safe":true}' -Encoding utf8

        Write-BridgeValidatedJson -Path $path -Json '{broken' | Should -BeFalse

        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).safe | Should -BeTrue
    }

    It 'restores an invalid primary from the last valid backup and reports recovery' {
        $path = Join-Path $TestDrive 'recover.json'
        Set-Content -LiteralPath $path -Value '{broken' -Encoding utf8
        Set-Content -LiteralPath "$path.bak" -Value '{"active":true}' -Encoding utf8

        $result = Read-BridgeValidatedJson -Path $path -AsHashtable

        $result.Recovered | Should -BeTrue
        $result.Data.active | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).active | Should -BeTrue
    }

    It 'returns null when neither primary nor backup exists' {
        Read-BridgeValidatedJson -Path (Join-Path $TestDrive 'missing.json') | Should -BeNullOrEmpty
    }
}
