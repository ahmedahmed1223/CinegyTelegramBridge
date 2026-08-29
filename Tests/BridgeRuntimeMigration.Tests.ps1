#requires -Version 7
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeStateMigration.psm1') -Force }
Describe 'Runtime state migration' {
    It 'migrates a legacy JSON file without replacing it when migration fails' {
        $path = Join-Path $TestDrive 'onair.json'
        Set-Content -LiteralPath $path -Value '{"7":{"Key":"lower-third"}}'
        $result = Invoke-BridgeStateFileMigration -Path $path -TargetVersion 1 -Migrations @{ 0 = { param($data) $data } }
        $result.Success | Should -BeTrue
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).SchemaVersion | Should -Be 1
    }
}
