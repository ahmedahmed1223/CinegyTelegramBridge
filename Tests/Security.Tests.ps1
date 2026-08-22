BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\BridgeSecurity.psm1') -Force
}

Describe 'Windows configuration ACL protection' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    It 'allows only the runtime identity, SYSTEM, and Administrators' {
        $configPath = Join-Path $TestDrive 'config.json'
        $backupDirectory = "$configPath.backups"
        New-Item -ItemType Directory -Path $backupDirectory | Out-Null
        Set-Content -LiteralPath $configPath -Value '{}'
        Set-Content -LiteralPath (Join-Path $backupDirectory 'config-1.json') -Value '{}'

        Protect-BridgeConfigurationAcl -ConfigPath $configPath

        foreach ($path in @($configPath, $backupDirectory, (Join-Path $backupDirectory 'config-1.json'))) {
            $acl = Get-Acl -LiteralPath $path
            $acl.AreAccessRulesProtected | Should -BeTrue
            $actual = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
            $expected = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544') | Sort-Object -Unique
            $actual | Should -Be $expected
            @($acl.Access | Where-Object AccessControlType -eq Deny).Count | Should -Be 0
        }
    }
}
