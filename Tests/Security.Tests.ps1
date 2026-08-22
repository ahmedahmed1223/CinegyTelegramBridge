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

Describe 'Optional DPAPI secret storage' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    It 'keeps the feature disabled in the distributed default configuration' {
        $example = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Raw | ConvertFrom-Json
        $example.Settings.EnableDpapiSecrets | Should -BeFalse
    }

    It 'round-trips Arabic and symbol-rich secrets for the current Windows identity' {
        $plain = 'رمز-سري:AbC_123!@#'
        $cipher = ConvertTo-BridgeProtectedSecret -Value $plain
        $cipher | Should -Not -Be $plain
        ConvertFrom-BridgeProtectedSecret -CipherText $cipher | Should -Be $plain
    }

    It 'stores no plaintext and resolves references without persisting decrypted values' {
        $storePath = Join-Path $TestDrive 'secrets.dpapi.json'
        Write-BridgeSecretStore -Path $storePath -Secrets @{
            BotToken = '123456:TOP_SECRET_TOKEN'
            'LiveStream.RtmpDestination' = 'rtmp://example.invalid/live/SECRET_KEY'
        }
        $rawStore = Get-Content -LiteralPath $storePath -Raw
        $rawStore | Should -Not -Match 'TOP_SECRET_TOKEN|SECRET_KEY'

        $config = [pscustomobject]@{
            BotToken = 'dpapi:BotToken'
            LiveStream = [pscustomobject]@{ SourceUrl = ''; RtmpDestination = 'dpapi:LiveStream.RtmpDestination' }
        }
        $resolved = Resolve-BridgeConfigurationSecrets -Config $config -StorePath $storePath
        $resolved.Config.BotToken | Should -Be '123456:TOP_SECRET_TOKEN'
        $resolved.Config.LiveStream.RtmpDestination | Should -Match 'SECRET_KEY$'

        $persistable = ConvertTo-BridgePersistableConfig -Config $resolved.Config -References $resolved.References
        $persistable.BotToken | Should -Be 'dpapi:BotToken'
        $persistable.LiveStream.RtmpDestination | Should -Be 'dpapi:LiveStream.RtmpDestination'
        ($persistable | ConvertTo-Json -Depth 5) | Should -Not -Match 'TOP_SECRET_TOKEN|SECRET_KEY'
    }

    It 'migrates a copied config only when explicitly invoked' {
        $configPath = Join-Path $TestDrive 'config.json'
        $storePath = Join-Path $TestDrive 'custom-secrets.dpapi.json'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\config.example.json') -Destination $configPath

        & (Join-Path $PSScriptRoot '..\Protect-BridgeSecrets.ps1') -ConfigPath $configPath -SecretStorePath $storePath -Confirm:$false | Out-Null

        $migrated = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $migrated.Settings.EnableDpapiSecrets | Should -BeTrue
        $migrated.BotToken | Should -Be 'dpapi:BotToken'
        (Get-Content -LiteralPath $storePath -Raw) | Should -Not -Match 'REPLACE_WITH_TOKEN_FROM_BOTFATHER'
        Test-Path -LiteralPath "$configPath.pre-dpapi.bak" | Should -BeTrue
    }
}
