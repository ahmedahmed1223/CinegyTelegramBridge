#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Web channel: sign-in through Telegram' {
    BeforeEach {
        $script:WebLoginRequests = @{}
        $script:WebChannel = @{ Shared = @{} }   # "open" for the checks that ask
        Mock Send-TelegramMessage { }
        Mock Edit-TelegramMessageText { $true }
    }
    AfterEach { $script:WebChannel = $null }

    It 'reads the code from /web and from the sign-in page link' {
        Get-WebLoginCodeFromCommand -Command 'web' -ArgText ' 123456 ' | Should -Be '123456'
        Get-WebLoginCodeFromCommand -Command 'start' -ArgText 'web-654321' | Should -Be '654321'
        Get-WebLoginCodeFromCommand -Command 'start' -ArgText '' | Should -Be ''
        Get-WebLoginCodeFromCommand -Command 'web' -ArgText '12345' | Should -Be ''
        Get-WebLoginCodeFromCommand -Command 'show' -ArgText '123456' | Should -Be ''
    }

    It 'approves only for the person who typed the code, and hands the approval out once' {
        (Register-WebLoginRequest -Arguments @{ code = '111222'; address = '203.0.113.9'; agent = 'Edge' }).ok | Should -BeTrue
        (Get-WebLoginRequestState -Code '111222').data.state | Should -Be 'pending'

        Request-WebLoginApproval -Code '111222' -ChatId 501 -UserId 501
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $ChatId -eq 501 -and $Text -match '111222' -and $Text -match '203\.0\.113\.9' }

        # Someone else pressing the button in a forwarded copy does nothing.
        Complete-WebLoginApproval -Code '111222' -Approve $true -ChatId 777 -UserId 777 -MessageId 9
        (Get-WebLoginRequestState -Code '111222').data.state | Should -Be 'pending'

        Complete-WebLoginApproval -Code '111222' -Approve $true -ChatId 501 -UserId 501 -MessageId 9
        $approved = Get-WebLoginRequestState -Code '111222'
        $approved.data.state | Should -Be 'approved'
        $approved.data.userId | Should -Be 501
        (Get-WebLoginRequestState -Code '111222').data.state | Should -Be 'expired'
    }

    It 'refuses a second person who types a code someone else already claimed' {
        Register-WebLoginRequest -Arguments @{ code = '333444' } | Out-Null
        Request-WebLoginApproval -Code '333444' -ChatId 501 -UserId 501
        Request-WebLoginApproval -Code '333444' -ChatId 777 -UserId 777
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $ChatId -eq 777 -and $Text -eq (T 'web.login.unknown') }
    }

    It 'treats an expired request as gone' {
        Register-WebLoginRequest -Arguments @{ code = '555666' } | Out-Null
        $script:WebLoginRequests['555666'].ExpiresAt = (Get-Date).AddSeconds(-1)
        Request-WebLoginApproval -Code '555666' -ChatId 501 -UserId 501
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $Text -eq (T 'web.login.unknown') }
        (Get-WebLoginRequestState -Code '555666').data.state | Should -Be 'expired'
    }

    It 'rejects a malformed or reused code' {
        (Register-WebLoginRequest -Arguments @{ code = '12ab56' }).error | Should -Be 'bad_code'
        Register-WebLoginRequest -Arguments @{ code = '777888' } | Out-Null
        (Register-WebLoginRequest -Arguments @{ code = '777888' }).error | Should -Be 'code_in_use'
    }

    It 'answers /web from the bot command path instead of the main menu' {
        Mock Test-Authorized { $true }
        Mock Show-MainMenu { }
        Register-WebLoginRequest -Arguments @{ code = '246810' } | Out-Null
        Invoke-BridgeCommand -Text '/start web-246810' -ChatId 501 -UserId 501
        Should -Invoke Show-MainMenu -Times 0
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $Text -match '246810' }
    }
}

Describe 'Web channel: browser-only accounts' {
    BeforeEach {
        $script:WebChannel = $null
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(11) -Force
        $config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @(11, 22) -Force
        $config | Add-Member -NotePropertyName 'AllowedUserIds' -NotePropertyValue @(11, 22, 33) -Force
        Mock Save-Config { }
        Mock Save-UserAliases { $true }
    }

    It 'lets an administrator add an operator, who then passes the same checks the bot makes' {
        $webUser = $script:WebOnlyUserIdBase + 1
        (Grant-WebOnlyAccount -Arguments @{ actor = 22; userId = $webUser; role = 'operator'; name = 'Night desk' }).ok | Should -BeTrue
        Test-Authorized -ChatId $webUser -UserId $webUser | Should -BeTrue
        Test-Admin -ChatId $webUser -UserId $webUser | Should -BeFalse
        Get-UserDisplayName -UserId $webUser | Should -Be 'Night desk'
    }

    It 'keeps appointing an administrator to the owner' {
        $webUser = $script:WebOnlyUserIdBase + 2
        (Grant-WebOnlyAccount -Arguments @{ actor = 22; userId = $webUser; role = 'admin'; name = 'x' }).error | Should -Be 'owner_only'
        (Grant-WebOnlyAccount -Arguments @{ actor = 33; userId = $webUser; role = 'operator'; name = 'x' }).error | Should -Be 'forbidden'
        (Grant-WebOnlyAccount -Arguments @{ actor = 11; userId = $webUser; role = 'admin'; name = 'x' }).ok | Should -BeTrue
        Test-Admin -ChatId $webUser -UserId $webUser | Should -BeTrue
    }

    It 'never grants or revokes a Telegram account through this door' {
        (Grant-WebOnlyAccount -Arguments @{ actor = 11; userId = 4242; role = 'operator'; name = 'x' }).error | Should -Be 'not_web_only'
        (Revoke-WebOnlyAccount -Arguments @{ actor = 11; userId = 33 }).error | Should -Be 'not_web_only'
        Test-Authorized -ChatId 33 -UserId 33 | Should -BeTrue
    }

    It 'sends nothing to a browser-only account' {
        Mock Invoke-BridgeTelegramRequest { [pscustomobject]@{ Success = $true; Response = @{ result = @{ message_id = 1 } }; StatusCode = 200 } }
        Send-TelegramMessage -ChatId ($script:WebOnlyUserIdBase + 3) -Text 'notice'
        Should -Invoke Invoke-BridgeTelegramRequest -Times 0
    }
}

Describe 'Web channel: the pipe' {
    BeforeAll {
        function global:Invoke-WebPipeRequest {
            <# A real client on the real pipe, run on its own runspace while this
               thread plays the bridge: that is the only way to prove a queued
               request reaches the bridge thread and its answer comes back. #>
            param([Parameter(Mandatory)][string]$PipeName, [Parameter(Mandatory)][string]$Line, [int]$PumpSeconds = 10)
            $client = [powershell]::Create()
            $client.AddScript({
                    param($name, $text)
                    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $name, 'InOut')
                    try {
                        $pipe.Connect(5000)
                        $writer = [System.IO.StreamWriter]::new($pipe, [System.Text.UTF8Encoding]::new($false), 4096, $true)
                        $reader = [System.IO.StreamReader]::new($pipe, [System.Text.UTF8Encoding]::new($false), $false, 4096, $true)
                        $writer.WriteLine($text); $writer.Flush()
                        $reader.ReadLine()
                    }
                    finally { $pipe.Dispose() }
                }).AddArgument($PipeName).AddArgument($Line) | Out-Null
            $handle = $client.BeginInvoke()
            $until = (Get-Date).AddSeconds($PumpSeconds)
            while (-not $handle.IsCompleted -and (Get-Date) -lt $until) {
                Wait-WebChannelSignal -Milliseconds 50
                Invoke-WebChannelRequests
            }
            try { return [string](@($client.EndInvoke($handle))[-1]) }
            finally { $client.Dispose() }
        }
        $script:WebChannelPipeName = "CinegyTelegramBridge.Web.Test.$PID.$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        Mock Update-WebBotUsername { }
        Start-WebChannel
    }
    AfterAll { Stop-WebChannel }

    It 'answers status from the published snapshot without the bridge thread' {
        $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"status"}' -PumpSeconds 0
        $parsed = $reply | ConvertFrom-Json
        $parsed.ok | Should -BeTrue
        $parsed.data.version | Should -Be $script:BridgeVersion
    }

    It 'publishes feed health and recent outages without exposing their source or cause' {
        $previousOutages = $script:StreamOutages
        try {
            $script:StreamOutages = New-BridgeOutageLedger
            $now = [datetime]::Now
            Open-BridgeOutage -Ledger $script:StreamOutages -Kind black -At $now.AddMinutes(-5) -Cause 'private-diagnostics' | Out-Null
            Close-BridgeOutage -Ledger $script:StreamOutages -Kind black -At $now.AddMinutes(-4) | Out-Null
            Open-BridgeOutage -Ledger $script:StreamOutages -Kind unreachable -At $now.AddMinutes(-1) -Source 'srt://internal.example/ingest-key' | Out-Null
            Publish-WebChannelState -Force

            $raw = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"status"}' -PumpSeconds 0
            $feed = ($raw | ConvertFrom-Json).data.feed
            $feed.state | Should -Be 'unreachable'
            $feed.outageCount | Should -Be 2
            $feed.recent[0].endedAt | Should -Be 0
            $feed.recent[1].endedAt | Should -BeGreaterThan $feed.recent[1].startedAt
            $raw | Should -Not -Match 'ingest-key|private-diagnostics|internal\.example'
        }
        finally {
            $script:StreamOutages = $previousOutages
            Publish-WebChannelState -Force
        }
    }

    It 'controls the same relay as Telegram and refuses expired reviews and unauthorized operators' {
        $previousRelay = $script:RelayState
        $previousPidFile = $script:relayPidFile
        $script:RelayState = @{ Process = $null; ShouldRun = $false; Restarts = 0; NotifyChatId = 0; VerifyAt = $null }
        $script:relayPidFile = Join-Path $TestDrive 'web-relay.pid'
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableLiveRelay' }
        Mock Get-ActiveLiveStreamConfig { @{ SourceUrl = 'https://example.invalid/ingest?secret=station'; RtmpDestination = 'rtmp://example.invalid/private-stream-key' } }
        Mock Start-RelayProcess {
            $script:RelayState.Process = [pscustomobject]@{ Id = 5777; StartTime = [datetime]'2026-11-20T13:00:00'; HasExited = $false }
            return $true
        }
        Mock Stop-RelayProcess { throw 'Simulated access denied' }
        Mock Send-TelegramMessage { }
        try {
            $relayRequest = {
                param($arguments)
                $line = @{ op = 'relay.control'; args = $arguments } | ConvertTo-Json -Compress
                return (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json)
            }
            (& $relayRequest @{ actor = 4322; action = 'status' }).error | Should -Be 'forbidden'
            (& $relayRequest @{ actor = 4322; action = 'start'; revision = 'anything' }).error | Should -Be 'forbidden'
            $initial = & $relayRequest @{ actor = 4321; action = 'status' }
            $initial.data.state | Should -Be 'stopped'
            $initial.data.canStart | Should -BeTrue
            $initial | ConvertTo-Json -Depth 6 | Should -Not -Match 'station|private-stream-key|example\.invalid'

            $launch = @{ actor = 4321; action = 'start'; revision = $initial.data.revision }
            $started = & $relayRequest $launch
            $started.data.state | Should -Be 'starting'
            $script:RelayState.NotifyChatId | Should -Be 0
            (& $relayRequest $launch).error | Should -Be 'relay_stale'
            Should -Invoke Start-RelayProcess -Times 1 -Exactly
            Should -Invoke Send-TelegramMessage -Times 0 -Exactly

            $stop = @{ actor = 4321; action = 'stop'; revision = $started.data.revision }
            $script:RelayState.Process.StartTime = $script:RelayState.Process.StartTime.AddSeconds(10)
            (& $relayRequest $stop).error | Should -Be 'relay_stale'
            Should -Invoke Stop-RelayProcess -Times 0 -Exactly
            $current = & $relayRequest @{ actor = 4321; action = 'status' }
            $stop.revision = $current.data.revision
            (& $relayRequest $stop).error | Should -Be 'relay_stop_failed'
            $script:RelayState.Process.HasExited | Should -BeFalse
            $script:RelayState.ShouldRun | Should -BeFalse

            Mock Stop-RelayProcess { $script:RelayState.Process.HasExited = $true }
            $current = & $relayRequest @{ actor = 4321; action = 'status' }
            $stop.revision = $current.data.revision
            (& $relayRequest $stop).data.state | Should -Be 'stopped'
            $script:RelayState.Process | Should -BeNullOrEmpty
            (& $relayRequest $launch).error | Should -Be 'relay_stale'

            '5777' | Set-Content -LiteralPath $script:relayPidFile
            Mock Get-Process { [pscustomobject]@{ Id = 5777; HasExited = $false; ProcessName = 'ffmpeg' } } -ParameterFilter { $Id -eq 5777 }
            $unverified = & $relayRequest @{ actor = 4321; action = 'status' }
            $unverified.data.state | Should -Be 'unverified'
            $unverified.data.canStart | Should -BeFalse
            $stop.revision = $unverified.data.revision
            (& $relayRequest $stop).error | Should -Be 'relay_unavailable'
            Test-Path -LiteralPath $script:relayPidFile | Should -BeTrue
        }
        finally { $script:RelayState = $previousRelay; $script:relayPidFile = $previousPidFile }
    }

    It 'waits for the original relay to exit before changing source and reports an early exit to the web' {
        $previousRelay = $script:RelayState
        $previousPidFile = $script:relayPidFile
        $previousFallback = $script:OutputMonitorFallbackActive
        $script:relayPidFile = Join-Path $TestDrive 'relay-source-change.pid'
        $script:OutputMonitorFallbackActive = $false
        $original = [pscustomobject]@{ Id = 1; StartTime = (Get-Date); HasExited = $false }
        $script:RelayState = @{ Process = $original; ShouldRun = $true; Restarts = 0; NotifyChatId = 0; VerifyAt = $null }
        Mock Get-BackupLiveStreamConfig { @{ SourceUrl = 'https://example.invalid/backup' } }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableLiveRelay' }
        Mock Get-ActiveLiveStreamConfig { @{ SourceUrl = 'https://example.invalid/output'; RtmpDestination = 'rtmp://example.invalid/test' } }
        Mock Stop-RelayProcess { }
        Mock Start-RelayProcess {
            $script:RelayState.Process = [pscustomobject]@{ Id = 2; HasExited = $false; ExitCode = 1; StartTime = (Get-Date) }
            return $true
        }
        Mock Get-LastErrorLine { 'simulated encoder error' }
        try {
            Set-OutputMonitorFallbackActive -Active $true | Should -BeTrue
            (Get-WebRelayControlState).Data.state | Should -Be 'switching'
            Update-RelayWatchdog
            Should -Invoke Start-RelayProcess -Times 0 -Exactly
            $script:RelayState.Process.Id | Should -Be $original.Id

            $original.HasExited = $true
            Update-RelayWatchdog
            Should -Invoke Start-RelayProcess -Times 1 -Exactly
            $script:RelayState.Process.Id | Should -Be 2
            $script:RelayState.Process.HasExited = $true
            (Get-WebRelayControlState).Data.state | Should -Be 'starting'
            $script:RelayState.VerifyAt = (Get-Date).AddSeconds(-1)
            Update-RelayWatchdog
            $failed = (Get-WebRelayControlState).Data
            $failed.state | Should -Be 'failed'
            $failed.canStart | Should -BeTrue
            ($failed | ConvertTo-Json -Compress) | Should -Not -Match 'simulated encoder error'
        }
        finally {
            $script:RelayState = $previousRelay
            $script:relayPidFile = $previousPidFile
            $script:OutputMonitorFallbackActive = $previousFallback
        }
    }

    It 'captures and downloads only the requesting operators media through the shared job queue' {
        $previousCaptureLog = $script:logDir
        $previousCaptureJobs = $script:SnapshotJobs
        $previousCaptureFallback = $script:OutputMonitorFallbackActive
        $script:OutputMonitorFallbackActive = $false
        $script:logDir = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'web-captures')).FullName
        $script:SnapshotJobs = [System.Collections.Generic.List[hashtable]]::new()
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableSnapshot' }
        Mock Get-ActiveLiveStreamConfig { @{ SourceType = 'hls'; SourceUrl = 'https://example.invalid/private-input' } }
        Mock Get-BackupLiveStreamConfig { @{ SourceType = 'hls'; SourceUrl = 'https://example.invalid/backup-input' } }
        Mock Set-OutputMonitorFallbackActive { throw 'A browser capture cannot change the station output source' }
        Mock Get-FfmpegPath { 'ffmpeg' }
        Mock Start-BridgeMediaProcess {
            Set-Content -LiteralPath $Arguments[-1] -Value 'sample output'
            $exitCode = if ($Arguments -contains 'https://example.invalid/backup-input') { 0 } else { 1 }
            [pscustomobject]@{ HasExited = $true; ExitCode = $exitCode }
        }
        Mock Send-TelegramVideo { }
        Mock Send-TelegramMessage { }
        try {
            $captureRequest = {
                param($arguments)
                $line = @{ op = 'media.capture'; args = $arguments } | ConvertTo-Json -Compress
                return (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json)
            }
            (& $captureRequest @{ actor = 99; action = 'start'; kind = 'clip' }).error | Should -Be 'forbidden'
            $job = & $captureRequest @{ actor = 4321; action = 'start'; kind = 'clip' }
            $job.data.state | Should -Be 'pending'
            $job.data.id | Should -Match '^[a-f0-9]{32}$'
            (& $captureRequest @{ actor = 4322; action = 'start'; kind = 'clip' }).error | Should -Be 'capture_busy'
            (& $captureRequest @{ actor = 4322; action = 'status'; id = $job.data.id }).error | Should -Be 'not_found'
            $script:SnapshotJobs.Count | Should -Be 1
            Update-SnapshotJobs
            $script:SnapshotJobs.Count | Should -Be 1
            $script:SnapshotJobs[0].SourceIsPrimary | Should -BeFalse
            $script:OutputMonitorFallbackActive | Should -BeFalse
            Update-SnapshotJobs
            $ready = & $captureRequest @{ actor = 4321; action = 'status'; id = $job.data.id }
            $ready.data.state | Should -Be 'ready'
            $ready.data.kind | Should -Be 'clip'
            $ready.data.source | Should -Be 'backup'
            $ready | ConvertTo-Json -Depth 5 | Should -Not -Match 'private-input|web-captures'
            $file = & $captureRequest @{ actor = 4321; action = 'file'; id = $job.data.id }
            $file.data.path | Should -Be (Join-Path $script:logDir "snapshot-web-$($job.data.id).mp4")
            Test-Path -LiteralPath $file.data.path | Should -BeTrue
            (& $captureRequest @{ actor = 4322; action = 'file'; id = $job.data.id }).error | Should -Be 'not_found'
            $script:WebCaptureRecords[$job.data.id].ExpiresAt = (Get-Date).AddSeconds(-1)
            (& $captureRequest @{ actor = 4321; action = 'status'; id = $job.data.id }).error | Should -Be 'not_found'
            Test-Path -LiteralPath $file.data.path | Should -BeFalse
            Should -Invoke Set-OutputMonitorFallbackActive -Times 0 -Exactly
            Should -Invoke Send-TelegramMessage -Times 0 -Exactly
            Should -Invoke Send-TelegramVideo -Times 0 -Exactly
        }
        finally {
            $script:OutputMonitorFallbackActive = $previousCaptureFallback
            $script:SnapshotJobs = $previousCaptureJobs
            $script:logDir = $previousCaptureLog
        }
    }

    It 'carries a queued request to the bridge thread and its answer back' {
        $parsed = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"ping"}') | ConvertFrom-Json
        $parsed.ok | Should -BeTrue
        $parsed.data.version | Should -Be $script:BridgeVersion
    }

    It 'drops an expired on-air request before entering the bridge operation' {
        Mock Invoke-WebChannelOperation { throw 'an expired command reached the air-control thread' }
        $expired = @{
            Request = @{ op = 'urgent.playback'; args = @{ action = 'start' } }
            Deadline = [Diagnostics.Stopwatch]::GetTimestamp() - 1
            Claim = [System.Threading.Tasks.TaskCompletionSource[bool]]::new()
            Reply = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
        }
        $script:WebChannel.Shared.Queue.Enqueue($expired)
        Invoke-WebChannelRequests
        $expired.Claim.Task.Result | Should -BeFalse
        ($expired.Reply.Task.Result | ConvertFrom-Json).error | Should -Be 'bridge_busy'
        Should -Invoke Invoke-WebChannelOperation -Times 0 -Exactly
    }

    It 'answers garbage with an error instead of hanging' {
        ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line 'not json' -PumpSeconds 0) | ConvertFrom-Json).error | Should -Be 'bad_request'
        ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"drop.tables"}') | ConvertFrom-Json).error | Should -Be 'unknown_op'
    }

    It 'knows an authorized user by id and nobody else' {
        $config | Add-Member -NotePropertyName 'AllowedUserIds' -NotePropertyValue @(4321) -Force
        Publish-WebChannelState -Force
        $known = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"identity","args":{"userId":4321}}' -PumpSeconds 0) | ConvertFrom-Json
        $known.data.id | Should -Be 4321
        $known.data.role | Should -Be 'operator'
        $stranger = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"identity","args":{"userId":999}}' -PumpSeconds 0) | ConvertFrom-Json
        $stranger.data | Should -BeNullOrEmpty
        $roster = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"roster"}' -PumpSeconds 0) | ConvertFrom-Json
        @($roster.data.id) | Should -Contain 4321
    }

    It 'serves the browser while a Telegram poll hangs, then throws the poll error as before' {
        # A loopback socket that accepts and never answers: the poll hangs the
        # way it does on the station's slow link, until its own deadline.
        Mock Invoke-BridgeTick { }
        Mock Write-BridgeLivenessStamp { }
        Mock Get-SettingInt { Get-BridgeSettingInt -Config $config -Defaults $script:DefaultSettings -Name $Name -Minimum $Minimum }
        # The shortest margin the setting allows, so the hang costs seconds.
        Mock Get-SettingInt { 5 } -ParameterFilter { $Name -eq 'TelegramPollMarginSeconds' }
        $silent = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $silent.Start()
        $client = [powershell]::Create()
        try {
            # Dynamic scope: Get-TelegramUpdates reads $apiBase from its caller.
            Set-Variable -Name apiBase -Value "http://127.0.0.1:$($silent.LocalEndpoint.Port)/botTEST"
            $client.AddScript({
                    param($name)
                    Start-Sleep -Milliseconds 700
                    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $name, 'InOut')
                    try {
                        $pipe.Connect(5000)
                        $writer = [System.IO.StreamWriter]::new($pipe); $writer.WriteLine('{"op":"ping"}'); $writer.Flush()
                        [System.IO.StreamReader]::new($pipe).ReadLine()
                    }
                    finally { $pipe.Dispose() }
                }).AddArgument($script:WebChannelPipeName) | Out-Null
            $handle = $client.BeginInvoke()

            $pollError = $null
            try { Get-TelegramUpdates -Offset 0 -TimeoutSeconds 1 | Out-Null }
            catch { $pollError = $_ }
            $pollError | Should -Not -BeNullOrEmpty

            $handle.IsCompleted | Should -BeTrue -Because "the poll ended with '$($pollError.Exception.Message)'"
            ((@($client.EndInvoke($handle))[-1]) | ConvertFrom-Json).ok | Should -BeTrue
            Should -Invoke Invoke-BridgeTick -Times 1 -Because 'the poll ran past its own timeout, and the engines on air must not wait for it'
        }
        finally { $client.Dispose(); $silent.Stop() }
    }

    It 'handles air operations via pipe' {
        $registry = Join-Path $TestDrive 'web-templates.json'
        @{
            test_lower = @{
                path = Join-Path $TestDrive 'test_lower.cintitle'
                description = 'Lower Third Template'
                layer = 5
                category = 'news'
                maxLength = 20
                fields = @(
                    @{ name = 'f1'; label = 'Headline'; required = $true; maxLength = 10 }
                    @{ name = 'f2'; label = 'Subtitle' }
                    'f3'
                )
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $registry
        Mock Get-TemplateRegistryFilePath { $registry }
        Mock Test-Authorized { $true }
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Invoke-HideLayer { $true }
        Mock Invoke-ExitLayer { $true }

        # 1. air.templates
        $tplReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.templates"}') | ConvertFrom-Json
        $tplReply.ok | Should -BeTrue
        $tplReply.data.Count | Should -Be 1
        $tplReply.data[0].key | Should -Be 'test_lower'
        $tplReply.data[0].name | Should -Be 'Lower Third Template'
        $tplReply.data[0].layer | Should -Be 5
        $tplReply.data[0].fields[0].name | Should -Be 'f1'
        $tplReply.data[0].fields[0].label | Should -Be 'Headline'
        $tplReply.data[0].fields[0].required | Should -BeTrue
        $tplReply.data[0].fields[0].maxLength | Should -Be 10
        $tplReply.data[0].fields[1].maxLength | Should -Be 20
        $tplReply.data[0].fields[2].label | Should -Be 'f3'

        # 2. air.show
        $showReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.show","args":{"actor":4321,"key":"test_lower","variables":{"f1":"Breaking"}}}') | ConvertFrom-Json
        $showReply.ok | Should -BeTrue
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
            $Variables['f1'] -eq 'Breaking' -and $Variables.Count -eq 1
        }

        foreach ($request in @(
                '{"op":"air.show","args":{"actor":4321,"key":"missing"}}'
                '{"op":"air.show","args":{"actor":4321,"key":"test_lower","variables":{}}}'
                '{"op":"air.show","args":{"actor":4321,"key":"test_lower","variables":{"f1":"01234567890"}}}'
                '{"op":"air.show","args":{"actor":4321,"key":"test_lower","variables":{"f1":"Breaking","other":"value"}}}'
            )) {
            $refused = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $request) | ConvertFrom-Json
            $refused.ok | Should -BeFalse
            $refused.error | Should -Be 'refused'
        }
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly

        # 3. air.hide
        $hideReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.hide","args":{"actor":4321,"layer":5}}') | ConvertFrom-Json
        $hideReply.ok | Should -BeTrue
        Should -Invoke Invoke-HideLayer -Times 1

        # 4. air.exit
        $exitReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.exit","args":{"actor":4321,"layer":5}}') | ConvertFrom-Json
        $exitReply.ok | Should -BeTrue
        Should -Invoke Invoke-ExitLayer -Times 1
    }

    It 'starts only a reviewed urgent plan and refuses revoked actors or commands for a different run' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-UrgentBoardAvailable { $true }
        Mock Get-UrgentTemplate { @{ Key = 'Urgent'; Layer = 5 } }
        Mock Get-UrgentSceneTiming { $null }
        Mock Get-WebUrgentLayerStatus { $playbackScene }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-TemplateShowPolicy { @{ Allowed = $true } }
        Mock Test-MaintenanceControl { $true }
        Mock Invoke-ShowTemplateResult { @{ Success = $true } }
        Mock Get-UrgentItemVariables { @{} }
        Mock Save-UrgentRunState { $true }
        Mock Clear-UrgentRunState {}
        Mock Invoke-ExitLayer { $false }
        Mock Send-TelegramMessage {}
        Mock Send-UrgentBoardStep { @{ Success = $true } }
        Mock Show-UrgentBoardScreen {}
        $previousBoard = $script:UrgentBoard
        $previousRun = $script:UrgentBoardRun
        $previousLayer = $script:OnAir[5]
        $playbackScene = @{ Success = $true; IsOnAir = $true; ActiveId = 'old-graphic'; ActiveName = 'النشرة' }
        try {
            $script:UrgentBoardRun = $null
            $script:UrgentBoard = (Add-UrgentItem -Board (New-UrgentBoard) -Text 'خبر للمراجعة').Value
            $previewLine = '{"op":"urgent.playback","args":{"actor":4321,"action":"preview"}}'
            $preview = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $previewLine) | ConvertFrom-Json
            $preview.ok | Should -BeTrue
            $preview.data.preview.itemCount | Should -Be 1
            $preview.data.preview.replacesGraphic | Should -BeTrue
            $preview.data.preview.graphicName | Should -Be 'النشرة'
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly

            $start = @{ op = 'urgent.playback'; args = @{ actor = 4321; action = 'start'; review = $preview.data.preview.review } }
            $script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text 'خبر آخر').Value
            $stale = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $stale.error | Should -Be 'urgent_stale'

            $preview = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $previewLine) | ConvertFrom-Json
            $start.args.review = $preview.data.preview.review
            $playbackScene.ActiveId = 'external-replacement'
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'urgent_stale'
            $playbackScene.ActiveId = 'old-graphic'
            $start.args.actor = 999
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'forbidden'
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            $start.args.actor = 4321
            $started = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $started.data.run.state | Should -Be 'playing'
            Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $ExpectedLayerStamp -eq 'active:old-graphic' }
            $script:OnAir[5] = @{ Key = $script:MojazUrgentKey; ActiveId = 'started-urgent' }
            $playbackScene.ActiveId = 'started-urgent'

            $control = @{ op = 'urgent.playback'; args = @{ actor = 4321; action = 'pause'; runId = $started.data.run.id } }
            $paused = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($control | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $paused.data.run.state | Should -Be 'paused'
            $control.args.action = 'resume'
            $resumed = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($control | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $resumed.data.run.state | Should -Be 'playing'
            $control.args.action = 'skip'
            $control.args.step = 0
            $skipped = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($control | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $skipped.data.run.step | Should -Be 1
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($control | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'urgent_stale'
            Should -Invoke Send-UrgentBoardStep -Times 1 -Exactly

            $stop = @{ op = 'urgent.playback'; args = @{ actor = 4321; action = 'stop'; runId = 'old-run' } }
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($stop | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'urgent_stale'
            Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
            $stop.args.runId = $started.data.run.id
            $playbackScene.ActiveId = 'external-replacement'
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($stop | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'urgent_stale'
            Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
            $playbackScene.ActiveId = 'started-urgent'
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($stop | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'urgent_stop_unconfirmed'
            $status = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"urgent.playback","args":{"actor":4321,"action":"status"}}') | ConvertFrom-Json
            $status.data.run.state | Should -Be 'stop_unconfirmed'
            $status.data.run.id | Should -Be $started.data.run.id
        }
        finally {
            $script:UrgentBoard = $previousBoard
            $script:UrgentBoardRun = $previousRun
            if ($null -eq $previousLayer) { $script:OnAir.Remove(5) } else { $script:OnAir[5] = $previousLayer }
        }
    }

    It 'serves the published ticker in bounded pages only to authorized operators' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableNewsTickerManagement' }
        Mock Get-NewsTickerConfiguredSnapshot {
            [pscustomobject]@{ Success = $true; Items = @(1..34 | ForEach-Object { "خبر $_" }) }
        }
        $denied = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"content.list","args":{"actor":999,"view":"ticker"}}') | ConvertFrom-Json
        $denied.error | Should -Be 'forbidden'
        Should -Invoke Get-NewsTickerConfiguredSnapshot -Times 0 -Exactly
        $reply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"content.list","args":{"actor":4321,"view":"ticker","page":1}}') | ConvertFrom-Json
        $reply.ok | Should -BeTrue
        $reply.data.total | Should -Be 34
        $reply.data.page | Should -Be 1
        $reply.data.pageCount | Should -Be 2
        $reply.data.items.Count | Should -Be 14
        $reply.data.items[0].title | Should -Be 'خبر 21'
    }

    It 'shares the ticker draft with the bot and protects its ownership, revision, and publication' {
        $webTickerFile = Join-Path $TestDrive 'web-edit-news.txt'
        Set-Content -LiteralPath $webTickerFile -Value 'أول | ثاني'
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableNewsTickerManagement' }
        Mock Get-Setting { $webTickerFile } -ParameterFilter { $Name -eq 'NewsFilePath' }
        Mock Get-Setting { '|' } -ParameterFilter { $Name -eq 'NewsItemSeparator' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowOperatorsDeleteNews' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowOperatorsRestoreNews' }
        Mock Get-Setting { '' } -ParameterFilter { $Name -eq 'NewsSheetCsvUrl' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NewNewsItemAtTop' }
        Mock Test-Authorized { $UserId -in @(4321, 4322) }
        Mock Test-Admin { $false }
        Mock Send-TelegramMessage {}
        Mock Save-NewsSheetItems { @{ Success = $false; Attempted = $false; Error = '' } }
        Mock Send-NewsPublishNotice {}
        Mock Write-NewsPublishRecord {}
        $previousDraft = $script:NewsTickerDraft
        $previousFile = $script:newsDraftFile
        $previousBackup = $script:newsBackupDirectory
        $previousShelf = $script:NewsPaused
        $previousShelfFile = $script:newsPausedFile
        $requestTicker = {
            param($arguments)
            $line = @{ op = 'ticker.edit'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $script:NewsTickerDraft = $null
            $script:newsDraftFile = Join-Path $TestDrive 'web-edit-draft.json'
            $script:newsBackupDirectory = Join-Path $TestDrive 'web-edit-backups'
            $script:newsPausedFile = Join-Path $TestDrive 'web-paused.json'
            $script:NewsPaused = [System.Collections.Generic.List[string]]::new()

            $started = & $requestTicker @{ actor = 4321; action = 'start' }
            $started.ok | Should -BeTrue
            $started.data.draft.items | Should -Be @('أول', 'ثاني')
            (& $requestTicker @{ actor = 4322; action = 'start' }).error | Should -Be 'ticker_locked'
            $other = & $requestTicker @{ actor = 4322; action = 'status' }
            $other.data.state | Should -Be 'locked'
            $other.data.draft | Should -BeNullOrEmpty
            (& $requestTicker @{ actor = 999; action = 'status' }).error | Should -Be 'forbidden'

            $revision = $started.data.draft.revision
            Update-NewsTickerDraftItem -UserId 4321 -Index 1 -Text 'حرره البوت' | Should -BeTrue
            (& $requestTicker @{ actor = 4321; action = 'remove'; revision = $revision; index = 0 }).error | Should -Be 'ticker_stale'
            $mine = (& $requestTicker @{ actor = 4321; action = 'status' }).data.draft
            (& $requestTicker @{ actor = 4321; action = 'remove'; revision = $mine.revision; index = 0 }).error | Should -Be 'forbidden'
            $moved = & $requestTicker @{ actor = 4321; action = 'up'; revision = $mine.revision; index = 1 }
            $moved.data.draft.items | Should -Be @('حرره البوت', 'أول')

            $paused = & $requestTicker @{ actor = 4321; action = 'pause'; revision = $moved.data.draft.revision; index = 1 }
            $paused.data.draft.items | Should -Be @('حرره البوت')
            $paused.data.draft.paused.items | Should -Be @('أول')
            (Get-Content -LiteralPath $script:newsPausedFile -Raw | ConvertFrom-Json).Items | Should -Be @('أول')
            $resume = @{ actor = 4321; action = 'resume'; revision = $paused.data.draft.revision; index = 0; text = 'خبر مختلف' }
            (& $requestTicker $resume).error | Should -Be 'ticker_stale'
            $resume.text = 'أول'
            $restored = & $requestTicker $resume
            $restored.data.draft.items | Should -Contain 'أول'
            $restored.data.draft.paused.total | Should -Be 0
            $reordered = $restored.data.draft
            $schedule = @{ actor = 4321; action = 'schedule'; revision = $reordered.revision; publishAtMs = '2035-05-01T17:00:00' }
            (& $requestTicker $schedule).error | Should -Be 'ticker_schedule_invalid'
            $schedule.publishAtMs = [datetimeoffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds()
            $scheduledFor = [datetimeoffset]::FromUnixTimeMilliseconds($schedule.publishAtMs)
            $scheduled = & $requestTicker $schedule
            $scheduled.ok | Should -BeTrue
            (Get-NewsPublishAt -Draft (Get-NewsTickerDraft -UserId 4321)) | Should -Be $scheduledFor
            (& $requestTicker @{ actor = 4322; action = 'unschedule'; revision = $scheduled.data.draft.revision }).error | Should -Be 'ticker_locked'
            (& $requestTicker @{ actor = 4321; action = 'unschedule'; revision = $reordered.revision }).error | Should -Be 'ticker_stale'
            $cancelled = & $requestTicker @{ actor = 4321; action = 'unschedule'; revision = $scheduled.data.draft.revision }
            $cancelled.ok | Should -BeTrue
            $cancelled.data.draft.scheduledAt | Should -BeNullOrEmpty
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('أول', 'ثاني')

            $released = & $requestTicker @{ actor = 4321; action = 'handover'; revision = $cancelled.data.draft.revision }
            $released.data.state | Should -Be 'open'
            $taken = & $requestTicker @{ actor = 4322; action = 'start' }
            $taken.data.draft.items | Should -Be @('حرره البوت', 'أول')
            $publish = @{ actor = 4322; action = 'publish'; revision = $taken.data.draft.revision }

            Set-Content -LiteralPath $webTickerFile -Value 'تغيير خارجي'
            (& $requestTicker $publish).error | Should -Be 'ticker_conflict'
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('تغيير خارجي')
            $review = & $requestTicker @{ actor = 4322; action = 'review_conflict'; revision = $taken.data.draft.revision }
            $review.data.conflict.items | Should -Be @('تغيير خارجي')
            $publish.action = 'append'
            $publish.review = $review.data.conflict.review
            Set-Content -LiteralPath $webTickerFile -Value 'تغيير أحدث'
            (& $requestTicker $publish).error | Should -Be 'ticker_conflict'
            $review = & $requestTicker @{ actor = 4322; action = 'review_conflict'; revision = $taken.data.draft.revision }
            $publish.review = $review.data.conflict.review
            $published = & $requestTicker $publish
            $published.ok | Should -BeTrue
            $published.data.state | Should -Be 'available'
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('تغيير أحدث', 'حرره البوت', 'أول')
            Test-Path -LiteralPath $script:newsDraftFile | Should -BeFalse
        }
        finally {
            $script:NewsTickerDraft = $previousDraft
            $script:newsDraftFile = $previousFile
            $script:newsBackupDirectory = $previousBackup
            $script:NewsPaused = $previousShelf
            $script:newsPausedFile = $previousShelfFile
        }
    }

    It 'imports only reviewed sheet headlines while the operator owns the ticker draft' {
        $tickerPath = Join-Path $TestDrive 'sheet-import-ticker.txt'
        Set-Content -LiteralPath $tickerPath -Value 'الشريط المنشور'
        $previousSheetDraft = $script:NewsTickerDraft
        $previousSheetDraftPath = $script:newsDraftFile
        $previousSheetBackupPath = $script:newsBackupDirectory
        $script:newsDraftFile = Join-Path $TestDrive 'sheet-import-draft.json'
        $script:newsBackupDirectory = Join-Path $TestDrive 'sheet-import-backups'
        $script:NewsTickerDraft = @{ Id = 'mock'; OwnerUserId = 4321; OwnerChatId = 4321; Items = @('مسودة حالية') }
        $script:webSheetCsv = "خبر من الجدول,ملاحظات"
        $script:webSheetPullAllowed = $true
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $false }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableNewsTickerManagement' }
        Mock Get-Setting { $script:webSheetPullAllowed } -ParameterFilter { $Name -eq 'AllowOperatorsSheetPull' }
        Mock Get-Setting { 'https://example.invalid/private-csv?secret=fixture' } -ParameterFilter { $Name -eq 'NewsSheetCsvUrl' }
        Mock Get-Setting { $tickerPath } -ParameterFilter { $Name -eq 'NewsFilePath' }
        Mock Get-Setting { '|' } -ParameterFilter { $Name -eq 'NewsItemSeparator' }
        $script:webSheetTransfer = [System.Threading.Tasks.TaskCompletionSource[bool]]::new()
        Mock Start-NewsSheetCsvDownload { @{ Task = $script:webSheetTransfer.Task; FixtureCsv = $script:webSheetCsv; Error = '' } }
        Mock Receive-NewsSheetCsvDownload { @{ Success = $true; Csv = $Transfer.FixtureCsv; Error = '' } }
        Mock Send-NewsSheetNotice {}
        Mock Write-NewsPublishRecord {}
        $requestSheet = {
            param($arguments)
            $line = @{ op = 'ticker.sheet'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $requestSheet @{ actor = 4322; action = 'preview'; target = 'air' }).error | Should -Be 'ticker_locked'
            Should -Invoke Start-NewsSheetCsvDownload -Times 0
            $pendingPreview = @{
                Request = @{ args = @{ actor = 4321; action = 'preview'; target = 'draft' } }
                Deadline = [Diagnostics.Stopwatch]::GetTimestamp() + 15 * [Diagnostics.Stopwatch]::Frequency
                Reply = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
            }
            Start-WebTickerSheetRequest -Entry $pendingPreview | Should -BeNullOrEmpty
            (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"ping"}' | ConvertFrom-Json).ok | Should -BeTrue
            $pendingPreview.Reply.Task.IsCompleted | Should -BeFalse
            $script:webSheetPullAllowed = $false
            $script:webSheetTransfer.SetResult($true)
            Update-WebTickerSheetRequest
            ($pendingPreview.Reply.Task.Result | ConvertFrom-Json).error | Should -Be 'forbidden'
            $script:webSheetPullAllowed = $true
            $preview = (& $requestSheet @{ actor = 4321; action = 'preview'; target = 'draft' }).data
            $preview.items | Should -Be @('خبر من الجدول')
            $preview | ConvertTo-Json -Depth 4 | Should -Not -Match 'private-csv|fixture'
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('الشريط المنشور')
            $script:webSheetCsv = "خبر تغيّر,ملاحظات"
            $confirm = @{ actor = 4321; action = 'apply'; target = 'draft'; review = $preview.review }
            (& $requestSheet $confirm).error | Should -Be 'ticker_sheet_stale'
            $confirm.review = (& $requestSheet @{ actor = 4321; action = 'preview'; target = 'draft' }).data.review
            (& $requestSheet $confirm).ok | Should -BeTrue
            $script:NewsTickerDraft.Items | Should -Be @('خبر تغيّر')
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('الشريط المنشور')
            $air = (& $requestSheet @{ actor = 4321; action = 'preview'; target = 'air' }).data
            $confirm.target = 'air'; $confirm.review = $air.review
            (& $requestSheet $confirm).ok | Should -BeTrue
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('خبر تغيّر')
            $script:NewsTickerDraft.Items | Should -Be @('خبر تغيّر')
            Should -Invoke Send-NewsSheetNotice -Times 1 -Exactly
        }
        finally {
            Stop-WebTickerSheetRequest -ErrorCode 'channel_closed'
            $script:NewsTickerDraft = $previousSheetDraft
            $script:newsDraftFile = $previousSheetDraftPath
            $script:newsBackupDirectory = $previousSheetBackupPath
        }
    }

    It 'restores only the reviewed ticker backup and preserves the editors draft' {
        $tickerPath = Join-Path $TestDrive 'restore-ticker.txt'
        $oldBackupDirectory = $script:newsBackupDirectory
        $oldDraft = $script:NewsTickerDraft
        $oldDraftPath = $script:newsDraftFile
        $script:newsBackupDirectory = (New-Item -Path (Join-Path $TestDrive 'private-ticker-backups') -ItemType Directory).FullName
        $backupPath = Join-Path $script:newsBackupDirectory 'backup-original.txt'
        $script:newsDraftFile = Join-Path $TestDrive 'restore-draft.json'
        $script:NewsTickerDraft = @{ OwnerUserId = 4322; Items = @('مسودة محرر آخر'); PublishAt = [datetimeoffset]::UtcNow.AddHours(1).ToString('o') }
        Set-Content -LiteralPath $tickerPath -Value 'المنشور الآن'
        Set-Content -LiteralPath $backupPath -Value 'النسخة المحفوظة'
        Mock Test-Authorized { $UserId -in 4321, 4322, 4323 }
        Mock Test-Admin { $UserId -in 4321, 4323 }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableNewsTickerManagement' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowOperatorsRestoreNews' }
        Mock Get-Setting { $tickerPath } -ParameterFilter { $Name -eq 'NewsFilePath' }
        Mock Get-Setting { '|' } -ParameterFilter { $Name -eq 'NewsItemSeparator' }
        $requestBackup = {
            param($arguments)
            $line = @{ op = 'ticker.backups'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $requestBackup @{ actor = 4322; action = 'list' }).error | Should -Be 'forbidden'
            $listed = & $requestBackup @{ actor = 4321; action = 'list' }
            $listed.ok | Should -BeTrue
            $listed.data.list.total | Should -Be 1
            $listed | ConvertTo-Json -Depth 5 | Should -Not -Match 'private-ticker-backups|backup-original'
            $id = $listed.data.list.items[0].id
            $preview = (& $requestBackup @{ actor = 4321; action = 'preview'; id = $id }).data.preview
            $preview.currentItems | Should -Be @('المنشور الآن')
            $preview.items | Should -Be @('النسخة المحفوظة')
            $preview.cancelsSchedule | Should -BeTrue
            $restore = @{ actor = 4321; action = 'restore'; id = $id; review = $preview.review }
            $restore.actor = 4323
            (& $requestBackup $restore).error | Should -Be 'ticker_backup_stale'
            $restore.actor = 4321
            Set-Content -LiteralPath $tickerPath -Value 'تغيّر المنشور'
            (& $requestBackup $restore).error | Should -Be 'ticker_backup_stale'
            $restore.review = (& $requestBackup @{ actor = 4321; action = 'preview'; id = $id }).data.preview.review
            Set-Content -LiteralPath $backupPath -Value 'تغيّرت النسخة'
            (& $requestBackup $restore).error | Should -Be 'ticker_backup_stale'
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('تغيّر المنشور')
            $restore.review = (& $requestBackup @{ actor = 4321; action = 'preview'; id = $id }).data.preview.review
            (& $requestBackup $restore).ok | Should -BeTrue
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('تغيّرت النسخة')
            @(Get-NewsTickerBackupFiles).Count | Should -Be 2
            $script:NewsTickerDraft.Items | Should -Be @('مسودة محرر آخر')
            Get-NewsPublishAt -Draft $script:NewsTickerDraft | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $script:newsDraftFile -Raw | ConvertFrom-Json -AsHashtable).Contains('PublishAt') | Should -BeFalse
            (& $requestBackup $restore).error | Should -Be 'ticker_backup_stale'
            [IO.File]::WriteAllBytes($tickerPath, [byte[]]@(0, 1, 2))
            $recovery = (& $requestBackup @{ actor = 4321; action = 'preview'; id = $id }).data.preview
            $recovery.currentReadable | Should -BeFalse
            $restore.review = $recovery.review
            (& $requestBackup $restore).ok | Should -BeTrue
            (Get-NewsTickerConfiguredSnapshot).Items | Should -Be @('تغيّرت النسخة')
            $stream = [IO.File]::OpenWrite($tickerPath)
            try { $stream.SetLength(9MB) }
            finally { $stream.Dispose() }
            (& $requestBackup @{ actor = 4321; action = 'preview'; id = $id }).error | Should -Be 'ticker_backup_unreadable'
        }
        finally {
            $script:newsBackupDirectory = $oldBackupDirectory
            $script:NewsTickerDraft = $oldDraft
            $script:newsDraftFile = $oldDraftPath
        }
    }

    It 'shares saved ticker sets across channels and checks both reviewed revisions' {
        $oldSets = $script:NewsSets
        $oldSetsPath = $script:newsSetsFile
        $oldDraft = $script:NewsTickerDraft
        $oldDraftPath = $script:newsDraftFile
        $script:NewsSets = [System.Collections.Generic.List[object]]::new()
        $script:newsSetsFile = Join-Path $TestDrive 'web-sets.json'
        $script:newsDraftFile = Join-Path $TestDrive 'web-set-draft.json'
        $script:NewsTickerDraft = @{ OwnerUserId = 4321; OwnerChatId = 4321; Items = @('خبر المساء') }
        Mock Test-Authorized { $UserId -in 4321, 4322, 4323 }
        Mock Test-Admin { $UserId -eq 4323 }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableNewsTickerManagement' }
        Mock Get-Setting { '|' } -ParameterFilter { $Name -eq 'NewsItemSeparator' }
        $requestSet = {
            param($arguments)
            $line = @{ op = 'ticker.sets'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $requestSet @{ actor = 999; action = 'status' }).error | Should -Be 'forbidden'
            $current = & $requestSet @{ actor = 4321; action = 'status' }
            $current.ok | Should -BeTrue
            $draftRevision = $current.data.draftRevision
            $saved = & $requestSet @{ actor = 4321; action = 'save'; name = 'المساء'; draftRevision = $draftRevision }
            $saved.data.items[0].name | Should -Be 'المساء'
            $setRevision = $saved.data.items[0].revision
            (& $requestSet @{ actor = 4322; action = 'status' }).data.items[0].canManage | Should -BeFalse
            (& $requestSet @{ actor = 4321; action = 'save'; name = ' المساء '; draftRevision = $draftRevision }).error | Should -Be 'ticker_set_exists'
            (& $requestSet @{ actor = 4322; action = 'delete'; index = 0; revision = $setRevision }).error | Should -Be 'forbidden'
            $script:NewsTickerDraft.OwnerUserId = 4322
            $otherRevision = Get-NewsTickerDraftRevision -Draft $script:NewsTickerDraft
            (& $requestSet @{ actor = 4322; action = 'replace'; index = 0; revision = $setRevision; draftRevision = $otherRevision }).error | Should -Be 'forbidden'
            $script:NewsTickerDraft.OwnerUserId = 4321
            $script:NewsTickerDraft.Items = @('تغيير من البوت')
            (& $requestSet @{ actor = 4321; action = 'load'; index = 0; revision = $setRevision; draftRevision = $draftRevision }).error | Should -Be 'ticker_stale'
            $draftRevision = Get-NewsTickerDraftRevision -Draft $script:NewsTickerDraft
            (& $requestSet @{ actor = 4321; action = 'load'; index = 0; revision = $setRevision; draftRevision = $draftRevision }).ok | Should -BeTrue
            (Get-NewsTickerDraft -UserId 4321).Items | Should -Be @('خبر المساء')
            $script:NewsTickerDraft.Items = @('نسخة أحدث')
            Save-NewsSetFromDraft -UserId 4321 -Name 'المساء' | Should -BeTrue
            (& $requestSet @{ actor = 4323; action = 'delete'; index = 0; revision = $setRevision }).error | Should -Be 'ticker_set_stale'
            $reviewed = & $requestSet @{ actor = 4323; action = 'status' }
            $reviewed.data.items[0].canManage | Should -BeTrue
            (& $requestSet @{ actor = 4323; action = 'delete'; index = 0; revision = $reviewed.data.items[0].revision }).ok | Should -BeTrue
            $script:NewsSets.Count | Should -Be 0
        }
        finally {
            $script:NewsSets = $oldSets
            $script:newsSetsFile = $oldSetsPath
            $script:NewsTickerDraft = $oldDraft
            $script:newsDraftFile = $oldDraftPath
        }
    }

    It 'edits the same bulletin as Telegram, rejects older revisions and preserves media paths on the bridge' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'web-bulletins.json' }
        Mock Get-TemplateRegistryFilePath { Join-Path $TestDrive 'web-bulletin-templates.json' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'MojazMultiDesign' }
        $scene = Join-Path $TestDrive 'bulletin.cintitle'
        '<Scene><Var Name="location.Text" Type="String" /><Var Name="title.Text" Type="String" /><Var Name="mojaz_img" Type="String" /><Plate File="${mojaz_img}" /><Title Text="${location.Text}" /><Title Text="${title.Text}" /></Scene>' |
            Set-Content -LiteralPath $scene
        @{
            Mojaz = @{ path = $scene; layer = 4 }
            StudioBulletin = @{
                path = $scene; layer = 5; description = 'موجز الاستوديو'; bulletin = $true
                fields = @(@{ name = 'title.Text'; label = 'العنوان' }, @{ name = 'location.Text'; label = 'الموقع' })
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-TemplateRegistryFilePath)
        $previousLibrary = $script:MojazLibrary
        try {
            $script:MojazLibrary = New-MojazLibrary
            $requestBulletin = {
                param($arguments)
                $line = @{ op = 'bulletin.edit'; args = $arguments } | ConvertTo-Json -Depth 8 -Compress
                return (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json)
            }
            (& $requestBulletin @{ actor = 999; action = 'create'; name = 'موجز' }).error | Should -Be 'forbidden'
            $designs = & $requestBulletin @{ actor = 4321; action = 'designs' }
            @($designs.data.designs).key | Should -Contain 'StudioBulletin'
            (& $requestBulletin @{ actor = 4321; action = 'create'; name = 'موجز'; design = 'Missing' }).error | Should -Be 'bulletin_invalid'
            $created = & $requestBulletin @{ actor = 4321; action = 'create'; name = 'موجز اليوم'; design = 'StudioBulletin' }
            $created.ok | Should -BeTrue
            $id = $created.data.id
            $created.data.design | Should -Be 'StudioBulletin'
            $created.data.playbackSupported | Should -BeFalse
            $created.data.fields[1].name | Should -Be 'location.Text'
            $created.data.fields[1].label | Should -Be 'الموقع'
            $list = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"content.list","args":{"actor":4321,"view":"bulletins"}}' | ConvertFrom-Json
            $list.data.items[0].id | Should -Be $id

            $add = @{ actor = 4321; action = 'add'; id = $id; revision = 1; values = @{ 'title.Text' = 'العنوان'; 'location.Text' = 'الاستوديو' } }
            $added = & $requestBulletin $add
            $added.ok | Should -BeTrue
            $rowId = $added.data.rows[0].id
            $saved = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
            $saved.Rows[0].Title | Should -Be 'العنوان'
            $saved.Rows[0].Fields.'location.Text' | Should -Be 'الاستوديو'

            $botImage = Set-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -RowId $rowId -Image 'D:/station/attached.png' -UserId 4321
            (Invoke-MojazEdit -Result $botImage -ChatId 4321 -Quiet) | Should -BeTrue
            (& $requestBulletin $add).error | Should -Be 'bulletin_stale'
            $latest = & $requestBulletin @{ actor = 4321; action = 'read'; id = $id }
            (Get-JsonProp $latest.data.rows[0].values 'mojaz_img') | Should -BeNullOrEmpty
            $latest.data.rows[0].media[0] | Should -Be 'mojaz_img'
            $edit = @{ actor = 4321; action = 'update'; id = $id; rowId = $rowId; revision = $latest.data.revision; values = @{
                    'title.Text' = 'عنوان جديد'; 'location.Text' = ''
                } }
            $edit.values['mojaz_img'] = 'D:/unauthorized.png'
            (& $requestBulletin $edit).error | Should -Be 'bulletin_invalid'
            $edit.values.Remove('mojaz_img')
            $updated = & $requestBulletin $edit
            $updated.ok | Should -BeTrue
            $updated.data.rows[0].values.'location.Text' | Should -BeNullOrEmpty
            Import-MojazLibrary
            $persisted = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
            $persisted.Rows[0].Image | Should -Be 'D:/station/attached.png'
            $persisted.Rows[0].Title | Should -Be 'عنوان جديد'
            $botTitle = Set-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -RowId $rowId -Title 'عنوان من البوت' -UserId 4321
            (Invoke-MojazEdit -Result $botTitle -ChatId 4321 -Quiet) | Should -BeTrue
            $again = & $requestBulletin @{ actor = 4321; action = 'read'; id = $id }
            $again.data.rows[0].values.'title.Text' | Should -Be 'عنوان من البوت'

            $add.revision = $again.data.revision
            $add.values['title.Text'] = 'خبر ثانٍ'
            $second = & $requestBulletin $add
            $second.ok | Should -BeTrue
            $move = @{ actor = 4321; action = 'down'; id = $id; revision = $second.data.revision; rowId = $rowId }
            $moved = & $requestBulletin $move
            $moved.data.rows[1].id | Should -Be $rowId
            $move.action = 'skip'
            $move.revision = $moved.data.revision
            $skipped = & $requestBulletin $move
            $skipped.data.rows[1].skipped | Should -BeTrue
            $copy = & $requestBulletin @{ actor = 4321; action = 'copy'; id = $id; revision = $skipped.data.revision; name = 'نسخة اليوم' }
            $copy.data.id | Should -Not -Be $id
            $copy.data.rows[1].skipped | Should -BeTrue

            Mock Write-BridgeValidatedJson { $false }
            $move.action = 'remove'
            $move.revision = $skipped.data.revision
            (& $requestBulletin $move).error | Should -Be 'bulletin_save_failed'
            $stillSaved = & $requestBulletin @{ actor = 4321; action = 'read'; id = $id }
            $stillSaved.data.revision | Should -Be $skipped.data.revision
            $stillSaved.data.rows[1].id | Should -Be $rowId

            Move-Item -LiteralPath $scene -Destination (Join-Path $TestDrive 'retired-bulletin.cintitle')
            $unreadable = & $requestBulletin @{ actor = 4321; action = 'read'; id = $id }
            $unreadable.data.fields | Should -BeNullOrEmpty
            $edit.revision = $unreadable.data.revision
            (& $requestBulletin $edit).error | Should -Be 'bulletin_invalid'
        }
        finally { $script:MojazLibrary = $previousLibrary }
    }

    It 'reviews a batch against its mapped bulletin columns and appends it only once after confirmation' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-MojazAvailable { $true }
        $script:WebPasteReviewLocationLabel = 'الموقع'
        Mock Get-MojazRowFieldPrompts {
            @(
                @{ Name = 'title.Text'; Label = 'العنوان'; Kind = 'text' }
                @{ Name = 'Subject.Text'; Label = 'التفاصيل'; Kind = 'text' }
                @{ Name = 'location[1]'; Label = $script:WebPasteReviewLocationLabel; Kind = 'text' }
                @{ Name = 'mojaz_img'; Label = 'الصورة'; Kind = 'media' }
            )
        }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'paste-bulletins.json' }
        $previousLibrary = $script:MojazLibrary
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز المحطة').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $pasteRequest = {
                param($arguments)
                $line = @{ op = 'bulletin.paste'; args = $arguments } | ConvertTo-Json -Compress
                return (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json -AsHashtable)
            }
            $request = @{ actor = 4321; action = 'preview'; id = $id; revision = 1; format = 'table'; text = "أول`t`"خبر أول`nسطر تابع`"`tالاستوديو`nغير مطابق`tناقص`n`tخبر ثانٍ`tالميدان" }
            $preview = & $pasteRequest $request
            $preview.ok | Should -BeTrue
            $preview.data.preview.rows.Count | Should -Be 2
            $preview.data.preview.rows[1]['location[1]'] | Should -Be 'الميدان'
            $preview.data.preview.skippedLines | Should -Be @(2)
            @($script:MojazLibrary.Bulletins[0].Rows).Count | Should -Be 0
            Test-Path -LiteralPath (Get-MojazLibraryFile) | Should -BeFalse

            $request.action = 'commit'
            $request.review = $preview.data.preview.review
            $paste = $request.text
            $request.text = $paste.Replace('الميدان', 'موقع جديد')
            (& $pasteRequest $request).error | Should -Be 'bulletin_stale'
            $request.text = $paste
            $script:WebPasteReviewLocationLabel = 'المصدر'
            (& $pasteRequest $request).error | Should -Be 'bulletin_stale'
            $script:WebPasteReviewLocationLabel = 'الموقع'

            Mock Write-BridgeValidatedJson { $false }
            (& $pasteRequest $request).error | Should -Be 'bulletin_save_failed'
            @($script:MojazLibrary.Bulletins[0].Rows).Count | Should -Be 0
            Mock Write-BridgeValidatedJson { $true }
            $saved = & $pasteRequest $request
            $saved.ok | Should -BeTrue
            $saved.data.savedPage | Should -Be 0
            $read = @{ op = 'bulletin.edit'; args = @{ actor = 4321; action = 'read'; id = $id; page = 0 } } | ConvertTo-Json -Compress
            $board = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $read | ConvertFrom-Json -AsHashtable).data
            $board.rows[0].values['title.Text'] | Should -Be 'أول'
            $board.rows[1].values['location[1]'] | Should -Be 'الميدان'
            $board.revision | Should -Be 2
            $script:MojazLibrary.Bulletins[0].Rows[0].Text | Should -Be "خبر أول`nسطر تابع"
            $script:MojazLibrary.Bulletins[0].Rows[0].ImageMode | Should -Be 'inherit'
            (& $pasteRequest $request).error | Should -Be 'bulletin_stale'
            @($script:MojazLibrary.Bulletins[0].Rows).Count | Should -Be 2
        }
        finally { $script:MojazLibrary = $previousLibrary }
    }

    It 'uses the bot timing rules and updates only the selected bulletin without an air operation' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-MojazAvailable { $true }
        Mock Get-MojazRowFieldPrompts { @() }
        Mock Get-MojazSceneTiming { $null }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'timed-bulletins.json' }
        Mock Invoke-ShowTemplateResult { throw 'Editing timings must never air the bulletin' }
        $previousLibrary = $script:MojazLibrary
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز التوقيت' -DelayFrames 200).Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            Set-JsonProp $script:MojazLibrary.Bulletins[0] 'IntroExtraSeconds' 6
            $timingRequest = {
                param($arguments)
                $line = @{ op = 'bulletin.edit'; args = $arguments } | ConvertTo-Json -Depth 6 -Compress
                return (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json)
            }
            $read = & $timingRequest @{ actor = 4321; action = 'read'; id = $id }
            $read.data.timing.delayFrames | Should -Be 200
            $read.data.timing.introExtraFrames | Should -BeGreaterThan 0
            $payload = @{ actor = 4321; action = 'timing'; id = $id; revision = 1; timing = @{
                    delayFrames = 0; introExtraFrames = 0; lastRowFrames = 45; syncToLoop = $true
                } }
            (& $timingRequest $payload).error | Should -Be 'bulletin_refused'
            $payload.timing.delayFrames = 225
            $saved = & $timingRequest $payload
            $saved.ok | Should -BeTrue
            $saved.data.timing.delayFrames | Should -Be 225
            $saved.data.timing.introExtraFrames | Should -Be 0
            $saved.data.timing.lastRowFrames | Should -Be 45
            $saved.data.timing.syncToLoop | Should -BeTrue
            $stored = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
            (Get-JsonProp $stored 'IntroExtraSeconds') | Should -BeNullOrEmpty
            Get-MojazDelayFrames -Bulletin $stored | Should -Be 225
            Get-MojazLastRowFrames -Bulletin $stored | Should -Be 45
            Test-MojazSyncToLoop -Bulletin $stored | Should -BeTrue
            (& $timingRequest $payload).error | Should -Be 'bulletin_stale'

            Remove-JsonProp $stored 'DelayFrames'
            $syncOnly = & $timingRequest @{ actor = 4321; action = 'timing'; id = $id; revision = $stored.Revision; timing = @{ syncToLoop = $false } }
            $syncOnly.ok | Should -BeTrue
            $inherited = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
            (Get-JsonProp $inherited 'DelayFrames') | Should -BeNullOrEmpty
            (Get-MojazDelayFrames -Bulletin $inherited) | Should -Be (Get-MojazDelayFrames)
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        }
        finally { $script:MojazLibrary = $previousLibrary }
    }

    It 'ignores a stale manual urgent display without rewriting its state when reading the board' {
        Mock Test-Authorized { $true }
        Mock Test-UrgentBoardAvailable { $true }
        Mock Get-UrgentTemplate {
            @{ Layer = 5; Fields = @('strap'); FieldLabels = @(''); FieldLimits = @(0); FieldRequired = @($true) }
        }
        Mock Get-UrgentLiveStamp { 'current scene' }
        Mock Save-UrgentManualState { $true }
        $previousBoard = $script:UrgentBoard
        $previousLive = $script:UrgentManualLive
        try {
            $script:UrgentBoard = @{ Items = @(@{ Id = 'story'; Text = 'خبر عاجل'; Enabled = $true }) }
            $script:UrgentManualLive = @{ '4321' = @{ ItemId = 'story'; Layer = 5; LiveStamp = 'previous scene' } }
            $reply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"content.list","args":{"actor":4321,"view":"urgent"}}') | ConvertFrom-Json
            $reply.ok | Should -BeTrue
            $reply.data.items[0].state | Should -Be 'ready'
            $reply.data.fields.Count | Should -Be 1
            $reply.data.items[0].values.strap | Should -Be 'خبر عاجل'
            $script:UrgentManualLive.ContainsKey('4321') | Should -BeTrue
            Should -Invoke Save-UrgentManualState -Times 0 -Exactly
        }
        finally {
            $script:UrgentBoard = $previousBoard
            $script:UrgentManualLive = $previousLive
        }
    }

    It 'saves template fields as columns and rejects stale edits made after the board changed' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-UrgentBoardAvailable { $true }
        Mock Get-UrgentBoardFile { Join-Path $TestDrive 'web-urgent.json' }
        Mock Get-UrgentTemplate {
            @{
                Layer = 5
                Fields = @('strap', 'kicker', 'location[1]')
                FieldLabels = @('النص', 'العنوان', 'الموقع')
                FieldLimits = @(100, 50, 16)
                FieldRequired = @($true, $false, $true)
                FieldTypes = @{ 'location[1]' = 'String' }
            }
        }
        $previousBoard = $script:UrgentBoard
        try {
            $script:UrgentBoard = New-UrgentBoard
            $initial = [int]$script:UrgentBoard.Revision
            $add = '{"op":"urgent.write","args":{"actor":4321,"action":"add","revision":' + $initial + ',"row":{"values":{"kicker":"تنبيه","strap":"خبر جديد","location[1]":"الاستوديو"},"enabled":true}}}'
            $created = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $add) | ConvertFrom-Json
            $created.ok | Should -BeTrue
            $row = $script:UrgentBoard.Items[0]
            $row.Title | Should -Be 'تنبيه'
            $row.Text | Should -Be 'خبر جديد'
            $row.UpdatedBy | Should -Be 4321

            $stale = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $add) | ConvertFrom-Json
            $stale.error | Should -Be 'urgent_stale'
            $script:UrgentBoard.Items.Count | Should -Be 1

            $edit = '{"op":"urgent.write","args":{"actor":4321,"action":"update","revision":' + $script:UrgentBoard.Revision + ',"id":"' + $row.Id + '","row":{"values":{"kicker":"عنوان معدّل","strap":"خبر معدّل","location[1]":"الميدان"},"enabled":false}}}'
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $edit) | ConvertFrom-Json).ok | Should -BeTrue
            $script:UrgentBoard.Items[0].Enabled | Should -BeFalse
            $script:UrgentBoard.Items[0].Text | Should -Be 'خبر معدّل'
            $list = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"content.list","args":{"actor":4321,"view":"urgent"}}') | ConvertFrom-Json
            $list.data.items[0].id | Should -Be $row.Id
            $list.data.fields[2].label | Should -Be 'الموقع'
            $list.data.items[0].values.kicker | Should -Be 'عنوان معدّل'
            $list.data.items[0].values.'location[1]' | Should -Be 'الميدان'
            $list.data.revision | Should -Be $script:UrgentBoard.Revision

            $invalid = $edit | ConvertFrom-Json -AsHashtable
            $invalid.args.revision = $list.data.revision
            $invalid.args.row.values['location[1]'] = ''
            $emptyLocation = $invalid | ConvertTo-Json -Depth 6 -Compress
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $emptyLocation) | ConvertFrom-Json).error | Should -Be 'urgent_invalid'
            $invalid.args.row.values['location[1]'] = "الميدان$([char]0)"
            $invalidXml = $invalid | ConvertTo-Json -Depth 6 -Compress
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $invalidXml) | ConvertFrom-Json).error | Should -Be 'urgent_invalid'

            Import-UrgentBoard
            (Get-UrgentItemVariables -Item $script:UrgentBoard.Items[0])['location[1]'] | Should -Be 'الميدان'

            $plan = New-UrgentRunPlan -Items @($row) -Defaults (New-UrgentDefaults)
            $plan.Success | Should -BeTrue
            (Get-UrgentItemVariables -Item $plan.Value.Steps[0])['location[1]'] | Should -Be 'الاستوديو'
            Mock Send-PostboxValues { @{ Success = $true } }
            (Send-UrgentBoardStep -Step $plan.Value.Steps[0]).Success | Should -BeTrue
            Should -Invoke Send-PostboxValues -Times 1 -Exactly -ParameterFilter {
                $Types['location[1]'] -eq 'String' -and $Values['location[1]'] -eq 'الاستوديو'
            }
        }
        finally { $script:UrgentBoard = $previousBoard }
    }
}
