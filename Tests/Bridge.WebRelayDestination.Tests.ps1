. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Reviewed Web relay destination persistence' {
    BeforeEach {
        $script:oldRelayStore = $script:SecretStorePath
        $script:oldRelayReferences = $script:SecretReferences
        $script:SecretStorePath = Join-Path $TestDrive 'relay-fixture-secrets.json'
        $script:SecretReferences = @{}
        $script:relayConfig = Join-Path $TestDrive ("relay-$([guid]::NewGuid().ToString('N')).json")
        $script:previousDestination = 'rtmp://old.example.invalid/live/old-key'
        $script:replacement = 'rtmps://name:password@new.example.invalid:443/live/new-key?secret=value'
        $script:configDocument = @{
            BotToken = 'fixture'
            CustomData = @{ Keep = 'original' }
            Settings = @{ EnableDpapiSecrets = $false }
            LiveStream = @{
                SourceUrl = 'https://input.example.invalid/live.m3u8'
                RtmpDestination = $script:previousDestination
            }
        }
        Mock Protect-BridgePathAcl {}
        Mock Protect-BridgeConfigurationAcl {}
    }
    AfterEach {
        $script:SecretStorePath = $script:oldRelayStore
        $script:SecretReferences = $script:oldRelayReferences
    }
    It 'shares URL validation with the Bot and rejects non-network, missing-host and injected argument values' {
        Test-RelayDestinationUrl " $script:replacement " | Should -BeTrue
        Test-RelayDestinationUrl 'file:///fixture' | Should -BeFalse
        Test-RelayDestinationUrl 'rtmps:///missing-host' | Should -BeFalse
        Test-RelayDestinationUrl "rtmp://new.example.invalid/live`n-y" | Should -BeFalse
        Test-RelayDestinationUrl ('rtmp://new.example.invalid/' + ('x' * 4096)) | Should -BeFalse
    }
    It 'atomically updates just the destination and keeps the previous file as backup' {
        $original = $script:configDocument | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $script:relayConfig -Value $original -NoNewline
        Save-Config -Path $script:relayConfig -ReviewedRelay @{ Expected = $script:previousDestination; Destination = $script:replacement }
        $script:LastConfigSaveFailed | Should -BeFalse
        $configAfter = Get-Content -LiteralPath $script:relayConfig -Raw | ConvertFrom-Json
        $configAfter.LiveStream.RtmpDestination | Should -Be $script:replacement
        $configAfter.LiveStream.SourceUrl | Should -Be 'https://input.example.invalid/live.m3u8'
        $configAfter.CustomData.Keep | Should -Be 'original'
        Get-Content -LiteralPath "$script:relayConfig.bak" -Raw | Should -BeExactly $original
    }
    It 'refuses stale disk values and expired writes without touching the configuration' {
        $original = $script:configDocument | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $script:relayConfig -Value $original -NoNewline
        Save-Config -Path $script:relayConfig -ReviewedRelay @{ Expected = ''; Destination = $script:replacement }
        $script:LastConfigSaveConflict | Should -BeTrue
        Save-Config -Path $script:relayConfig -ReviewedRelay @{ Expected = $script:previousDestination; Destination = $script:replacement } -Deadline 1
        $script:LastConfigSaveFailed | Should -BeTrue
        Get-Content -LiteralPath $script:relayConfig -Raw | Should -BeExactly $original
    }
    It 'introduces an encrypted reference and replaces an existing protected value without publishing plaintext' -Skip:(-not $IsWindows) {
        $script:configDocument.Settings.EnableDpapiSecrets = $true
        $script:configDocument | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:relayConfig
        Save-Config -Path $script:relayConfig -ReviewedRelay @{ Expected = $script:previousDestination; Destination = $script:replacement }
        $script:LastConfigSaveFailed | Should -BeFalse
        $published = Get-Content -LiteralPath $script:relayConfig -Raw
        $published | Should -Not -Match 'new-key|password|secret=value'
        $parsed = $published | ConvertFrom-Json
        $parsed.LiveStream.RtmpDestination | Should -Be 'dpapi:LiveStream.ReviewedRtmpDestination'
        (Read-BridgeSecretStore -Path $script:SecretStorePath)['LiveStream.ReviewedRtmpDestination'] | Should -Be $script:replacement

        Save-Config -Path $script:relayConfig -ReviewedRelay @{ Expected = $script:replacement; Destination = $script:previousDestination }
        $script:LastConfigSaveFailed | Should -BeFalse
        Get-Content -LiteralPath $script:relayConfig -Raw | Should -BeExactly $published
        (Read-BridgeSecretStore -Path $script:SecretStorePath)['LiveStream.ReviewedRtmpDestination'] | Should -Be $script:previousDestination
    }
}
