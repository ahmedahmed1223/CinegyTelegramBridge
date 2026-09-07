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

Describe 'Deferred Telegram transport stays off the air clock' {
    It 'returns control while the server is silent and collects the eventual response' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $worker = $null
        $client = $null
        try {
            $port = $listener.LocalEndpoint.Port
            $worker = Start-BridgeTelegramRequestWorker -Request @{
                Uri = "http://127.0.0.1:$port/"; Method = 'Post'; Body = @{ text = 'test' }; TimeoutSec = 5; MaxAttempts = 1
            }
            $accept = $listener.AcceptTcpClientAsync()
            $accept.Wait(4000) | Should -BeTrue
            $client = $accept.Result
            # The server deliberately has not answered. A synchronous send
            # cannot reach this assertion until its network timeout expires.
            Receive-BridgeTelegramRequestWorker -Worker $worker | Should -BeNullOrEmpty
            $reply = [Text.Encoding]::UTF8.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: 11`r`nConnection: close`r`n`r`n" + '{"ok":true}')
            $client.GetStream().Write($reply, 0, $reply.Length)
            $worker.Handle.AsyncWaitHandle.WaitOne(4000) | Should -BeTrue
            $result = Receive-BridgeTelegramRequestWorker -Worker $worker
            $result.Success | Should -BeTrue
            $result.Response.ok | Should -BeTrue
        }
        finally {
            if ($worker) { Stop-BridgeTelegramRequestWorker -Worker $worker }
            if ($client) { $client.Dispose() }
            $listener.Stop()
        }
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

    It 'returns a flood wait to the tick loop instead of sleeping inside the request' {
        $exception = [Exception]::new('Telegram returned 429')
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 429 })
        $errorRecord = [Management.Automation.ErrorRecord]::new($exception, 'RateLimited', 'InvalidOperation', $null)
        $errorRecord.ErrorDetails = [Management.Automation.ErrorDetails]::new('{"parameters":{"retry_after":7}}')
        Mock Invoke-RestMethod { throw $errorRecord } -ModuleName BridgeTelegram
        Mock Start-Sleep { } -ModuleName BridgeTelegram
        $result = Invoke-BridgeTelegramRequest -Uri 'https://example.invalid/sendMessage' -Method Post -Body @{} -TimeoutSec 3 -MaxAttempts 3
        $result.StatusCode | Should -Be 429
        $result.RetryAfterMs | Should -Be 7000
        Should -Invoke Start-Sleep -ModuleName BridgeTelegram -Times 0 -Exactly
    }
}

Describe 'A refused Telegram request says why' {
    It 'carries the description Telegram sent, not only the status line' {
        # The exception message is "Response status code does not indicate
        # success: 400 (Bad Request)" and nothing else - which is what the log
        # held when the reports screen broke, and why finding the cause took a
        # reproduction against the live audit trail instead of one line.
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Response status code does not indicate success: 400 (Bad Request).'),
            'x', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
            '{"ok":false,"error_code":400,"description":"Bad Request: can''t parse entities: Unclosed start tag at byte offset 91"}')

        $text = Get-BridgeTelegramErrorText -ErrorRecord $record
        $text | Should -Match '400'
        $text | Should -Match "can't parse entities"
        $text | Should -Match 'byte offset 91'
    }

    It 'falls back to the raw body when it is not the JSON we expect' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('boom'), 'x', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new('<html>gateway error</html>')
        Get-BridgeTelegramErrorText -ErrorRecord $record | Should -Match 'gateway error'
    }

    It 'is just the message when there is no body, and empty for nothing' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('timed out'), 'x', [System.Management.Automation.ErrorCategory]::OperationTimeout, $null)
        Get-BridgeTelegramErrorText -ErrorRecord $record | Should -Be 'timed out'
        Get-BridgeTelegramErrorText -ErrorRecord $null | Should -BeNullOrEmpty
    }
}
