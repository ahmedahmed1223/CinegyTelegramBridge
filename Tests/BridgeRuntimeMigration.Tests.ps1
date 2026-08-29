#requires -Version 7
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeStateMigration.psm1') -Force }
Describe 'Runtime state migration' {
    It 'migrates a legacy JSON file without replacing it when migration fails' {
        $path = Join-Path $TestDrive 'onair.json'
        Set-Content -LiteralPath $path -Value '{"7":{"Key":"lower-third"}}'
        $result = Invoke-BridgeStateFileMigration -Path $path -TargetVersion 1 -Migrations @{ 0 = { param($data) $data } }
        $result.Success | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).SchemaVersion | Should -Be 1
        $result.BackupPath | Should -Exist
        (Get-Content -LiteralPath $result.BackupPath -Raw | ConvertFrom-Json).'7'.Key | Should -Be 'lower-third'
    }

    It 'leaves the primary byte-for-byte unchanged when a migration step fails' {
        $path = Join-Path $TestDrive 'schedule.json'
        $original = '{"items":[1]}'
        Set-Content -LiteralPath $path -Value $original -NoNewline
        $result = Invoke-BridgeStateFileMigration -Path $path -TargetVersion 1 -Migrations @{ 0 = { throw 'bad step' } }
        $result.Success | Should -BeFalse
        (Get-Content -LiteralPath $path -Raw) | Should -BeExactly $original
    }

    It 'reports schema, size, and validated backup health' {
        $path = Join-Path $TestDrive 'autohide.json'
        Set-Content -LiteralPath $path -Value '{"SchemaVersion":1,"Data":[]}'
        $backup = "$path.20260829T120000000Z.bak"
        Set-Content -LiteralPath $backup -Value '{"SchemaVersion":1,"Data":[]}'
        $health = Get-BridgeRuntimeFileHealth -Path $path
        $health.Healthy | Should -BeTrue
        $health.SchemaVersion | Should -Be 1
        $health.SizeBytes | Should -BeGreaterThan 0
        $health.BackupHealthy | Should -BeTrue
    }
}
