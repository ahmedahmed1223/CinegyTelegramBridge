#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeTelegram.psm1') -Force
}

Describe 'Telegram HTTP transport module' {
    BeforeEach {
        Mock Start-Sleep { } -ModuleName BridgeTelegram
    }

    It 'retries one transient failure and returns the successful response' {
        $script:transportAttempts = 0
        Mock Invoke-RestMethod {
            $script:transportAttempts++
            if ($script:transportAttempts -eq 1) { throw 'temporary failure' }
            [pscustomobject]@{ ok=$true; result='sent' }
        } -ModuleName BridgeTelegram

        $result = Invoke-BridgeTelegramRequest -Uri 'https://example.invalid/sendMessage' -Method Post `
            -Body @{chat_id=1;text='مرحبا'} -TimeoutSec 7 -MaxAttempts 2

        $result.Success | Should -BeTrue
        $result.Response.result | Should -Be 'sent'
        Should -Invoke Invoke-RestMethod -ModuleName BridgeTelegram -Times 2 -Exactly -ParameterFilter { $TimeoutSec -eq 7 }
        Should -Invoke Start-Sleep -ModuleName BridgeTelegram -Times 1 -Exactly
    }

    It 'returns a structured failure result after the configured attempts' {
        Mock Invoke-RestMethod { throw 'HTTP rejected token value' } -ModuleName BridgeTelegram

        $result = Invoke-BridgeTelegramRequest -Uri 'https://example.invalid/sendPhoto' -Method Post `
            -Form @{chat_id='1'} -TimeoutSec 4 -MaxAttempts 2

        $result.Success | Should -BeFalse
        $result.Error | Should -Be 'HTTP rejected token value'
        $result.Attempts | Should -Be 2
    }

    It 'accepts a single-attempt request without sleeping after failure' {
        Mock Invoke-RestMethod { throw 'no connection' } -ModuleName BridgeTelegram

        $result = Invoke-BridgeTelegramRequest -Uri 'https://example.invalid/getUpdates' -Method Get `
            -TimeoutSec 3 -MaxAttempts 1

        $result.Success | Should -BeFalse
        $result.Attempts | Should -Be 1
        Should -Invoke Start-Sleep -ModuleName BridgeTelegram -Times 0 -Exactly
    }
}

Describe 'Telegram 429 retry delay' {
    BeforeAll {
        function New-FakeTelegramError {
            param([int]$StatusCode, [string]$Body)
            $record = [pscustomobject]@{
                Exception     = [pscustomobject]@{ Response = [pscustomobject]@{ StatusCode = $StatusCode } }
                ErrorDetails  = [pscustomobject]@{ Message = $Body }
            }
            return $record
        }
    }

    It 'waits the retry_after Telegram asked for, converted to milliseconds' {
        $err = New-FakeTelegramError -StatusCode 429 -Body '{"ok":false,"error_code":429,"parameters":{"retry_after":7}}'
        Get-BridgeTelegramRetryDelayMs -ErrorRecord $err -DefaultDelayMs 400 | Should -Be 7000
    }

    It 'keeps the fixed delay for a non-429 failure' {
        $err = New-FakeTelegramError -StatusCode 500 -Body '{"ok":false,"error_code":500}'
        Get-BridgeTelegramRetryDelayMs -ErrorRecord $err -DefaultDelayMs 400 | Should -Be 400
    }

    It 'keeps the fixed delay when a 429 carries no retry_after' {
        $err = New-FakeTelegramError -StatusCode 429 -Body '{"ok":false,"error_code":429}'
        Get-BridgeTelegramRetryDelayMs -ErrorRecord $err -DefaultDelayMs 400 | Should -Be 400
    }

    It 'caps an implausibly long retry_after so the bridge cannot be parked for hours' {
        $err = New-FakeTelegramError -StatusCode 429 -Body '{"parameters":{"retry_after":99999}}'
        Get-BridgeTelegramRetryDelayMs -ErrorRecord $err -DefaultDelayMs 400 -MaximumDelayMs 60000 | Should -Be 60000
    }

    It 'falls back to the fixed delay for a transport error with no response at all' {
        $err = [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'connection refused' } }
        Get-BridgeTelegramRetryDelayMs -ErrorRecord $err -DefaultDelayMs 400 | Should -Be 400
    }
}
