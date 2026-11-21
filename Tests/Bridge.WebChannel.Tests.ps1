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

    It 'uses shared urgent timing rules and refuses stale changes without calling air' {
        $oldSettings = Get-JsonProp $config 'Settings'
        $oldRun = $script:UrgentBoardRun
        $script:UrgentBoardRun = $null
        $fixtureSettings = [pscustomobject]@{ UrgentBoardIntervalSeconds = 8; UrgentBoardMode = 'text' }
        Set-JsonProp $config 'Settings' $fixtureSettings
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-UrgentBoardAvailable { $true }
        Mock Get-UrgentFloorSeconds { 4.5 }
        Mock Save-Config {}
        Mock Invoke-ShowTemplateResult {}
        $command = {
            param($arguments)
            $line = @{ op = 'urgent.timing'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $command @{ actor = 4322; action = 'status' }).error | Should -Be 'forbidden'
            $status = (& $command @{ actor = 4321; action = 'status' }).data
            $status.floorSeconds | Should -Be 4.5
            $change = @{ actor = 4321; action = 'save'; revision = $status.revision; field = 'interval'; number = 0 }
            (& $command $change).error | Should -Be 'urgent_timing_invalid'
            $change.number = 3
            $saved = (& $command $change).data
            $saved.intervalSeconds | Should -Be 3
            (Get-UrgentBoardDefaults).IntervalSeconds | Should -Be 3
            (& $command $change).error | Should -Be 'urgent_stale'
            Set-UrgentBoardSetting -ChatId 4321 -Name UrgentBoardMode -Value 'exit' | Should -BeTrue
            $change.revision = $saved.revision
            (& $command $change).error | Should -Be 'urgent_stale'
            $fresh = (& $command @{ actor = 4321; action = 'status' }).data
            $change.revision = $fresh.revision
            $change.number = 12
            $script:UrgentBoardRun = @{ Id = 'fixture-active' }
            (& $command $change).error | Should -Be 'urgent_timing_active'
            Set-UrgentBoardSetting -ChatId 4321 -Name UrgentExitGapSeconds -Value 20 -Quiet | Should -BeFalse
            $script:UrgentBoardRun = $null
            Mock Save-Config { $script:LastConfigSaveFailed = $true }
            (& $command $change).error | Should -Be 'urgent_timing_save_failed'
            (Get-UrgentBoardDefaults).IntervalSeconds | Should -Be 3
            Set-JsonProp (Get-JsonProp $config 'Settings') 'UrgentBoardIntervalSeconds' 'invalid'
            (Get-UrgentBoardDefaults).IntervalSeconds | Should -Be 8
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        }
        finally {
            $script:UrgentBoardRun = $oldRun
            $script:LastConfigSaveFailed = $false
            Set-JsonProp $config 'Settings' $oldSettings
        }
    }

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

    It 'runs a reviewed urgent rehearsal only on an isolated empty test layer' {
        $oldBoard = $script:UrgentBoard
        $oldReviews = $script:WebUrgentManualReviews
        $oldLayer = $script:OnAir[9]
        $script:UrgentBoard = (Add-UrgentItem -Board (New-UrgentBoard) -Text 'خبر للبروفة').Value
        $script:WebUrgentManualReviews = @{}
        $script:webTrialLayer = 9
        $script:webTrialLayerAllowed = $true
        $script:webTrialStatus = @{ Success = $true; IsOnAir = $false }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-MaintenanceControl { $true }
        Mock Test-UrgentBoardAvailable { $true }
        Mock Test-TemplateAccess { @{ Allowed = ($Layer -ne 9 -or $script:webTrialLayerAllowed) } }
        Mock Get-UrgentTemplate { @{ Key = 'Urgent'; Layer = 5; Path = 'fixture.cintitle'; Fields = @('headline') } }
        Mock Get-KnownLayers { 5 }
        Mock Get-Setting { Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableFullTemplateManagement' }
        Mock Get-SettingInt { Get-BridgeSettingInt -Config $config -Defaults $script:DefaultSettings -Name $Name -Minimum $Minimum }
        Mock Get-SettingInt { $script:webTrialLayer } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-SettingInt { 10 } -ParameterFilter { $Name -eq 'TemplateTestAutoHideSeconds' }
        Mock Get-WebUrgentLayerStatus { $script:webTrialStatus }
        $script:webTrialActualId = 'trial-item'
        Mock Show-TitlerTemplate {
            $script:webTrialStatus = @{ Success = $true; IsOnAir = $true; ActiveName = 'Urgent'; ActiveId = $script:webTrialActualId }
            @{ Success = $true; EventId = 'trial-item' }
        }
        Mock Get-TitlerLayerStatus { $script:webTrialStatus }
        Mock Set-OnAirShownRecord { $script:OnAir[$Layer] = $Record }
        Mock Save-OnAirState {}
        Mock Set-AutoHideTimer { $true }
        Mock Invoke-ShowTemplateResult {}
        $call = {
            param($arguments)
            $line = @{ op = 'urgent.manual'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $request = @{ actor = 4321; action = 'rehearse-preview'; itemId = $script:UrgentBoard.Items[0].Id }
            $request.actor = 4322
            (& $call $request).error | Should -Be 'forbidden'
            $request.actor = 4321
            $script:webTrialLayer = 5
            (& $call $request).error | Should -Be 'urgent_rehearsal_unavailable'
            $script:webTrialLayer = 9
            $script:webTrialLayerAllowed = $false
            (& $call $request).error | Should -Be 'urgent_rehearsal_unavailable'
            $script:webTrialLayerAllowed = $true
            $review = (& $call $request).data.preview
            $review.layer | Should -Be 9
            $review.autoHideSeconds | Should -Be 10
            $request.action = 'rehearse'
            $request.review = $review.review
            $script:webTrialStatus = @{ Success = $true; IsOnAir = $true; ActiveId = 'foreign' }
            (& $call $request).error | Should -Be 'urgent_rehearsal_busy'
            Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
            $script:webTrialStatus = @{ Success = $true; IsOnAir = $false }
            (& $call $request).error | Should -Be 'urgent_stale'
            $request.action = 'rehearse-preview'
            $request.review = (& $call $request).data.preview.review
            $request.action = 'rehearse'
            (& $call $request).ok | Should -BeTrue
            Should -Invoke Show-TitlerTemplate -Times 1 -Exactly -ParameterFilter { $Layer -eq 9 -and $Variables['headline'] -eq 'خبر للبروفة' }
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            Should -Invoke Set-AutoHideTimer -Times 1 -Exactly -ParameterFilter {
                $Layer -eq 9 -and $ActiveId -eq 'trial-item' -and $ActiveIdConfirmed
            }
            $script:webTrialStatus = @{ Success = $true; IsOnAir = $false }
            $script:webTrialActualId = 'different-item-with-same-template'
            $request.action = 'rehearse-preview'
            $request.review = (& $call $request).data.preview.review
            $request.action = 'rehearse'
            $unconfirmed = & $call $request
            $unconfirmed.ok | Should -BeTrue
            $unconfirmed.data.autoHideFailed | Should -BeTrue
            Should -Invoke Set-AutoHideTimer -Times 1 -Exactly
        }
        finally {
            $script:UrgentBoard = $oldBoard
            $script:WebUrgentManualReviews = $oldReviews
            if ($oldLayer) { $script:OnAir[9] = $oldLayer } else { $script:OnAir.Remove(9) | Out-Null }
        }
    }

    It 'reviews a single urgent before showing it and hides only the same scene for its owner' {
        $oldBoard = $script:UrgentBoard
        $oldManual = $script:UrgentManualLive
        $oldReviews = $script:WebUrgentManualReviews
        $oldRun = $script:UrgentBoardRun
        $oldBulletin = $script:MojazPlayback
        $oldLayer = $script:OnAir[5]
        $script:UrgentBoard = (Add-UrgentItem -Board (New-UrgentBoard) -Text 'خبر فردي').Value
        $script:UrgentBoardRun = $null
        $script:MojazPlayback = $null
        $script:UrgentManualLive = @{}
        $script:WebUrgentManualReviews = @{}
        $script:webSingleScene = @{ Success = $true; IsOnAir = $false }
        $script:webSingleHideClears = $false
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-UrgentBoardAvailable { $true }
        Mock Test-MaintenanceControl { $true }
        Mock Get-UrgentTemplate { @{ Key = 'Urgent'; Layer = 5; Fields = @('headline') } }
        Mock Get-WebUrgentLayerStatus { $script:webSingleScene }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-TemplateShowPolicy { @{ Allowed = $true } }
        Mock Get-EffectiveAutoHideSeconds { [math]::Min(20, $RequestedSeconds) }
        Mock Save-UrgentManualState { $true }
        Mock Invoke-ShowTemplateResult {
            $script:OnAir[5] = @{ Key = 'Urgent'; ActiveId = 'single-scene'; At = (Get-Date) }
            $script:webSingleScene = @{ Success = $true; IsOnAir = $true; ActiveId = 'single-scene' }
            @{ Success = $true }
        }
        Mock Invoke-HideLayer {
            if ($script:webSingleHideClears) { $script:webSingleScene = @{ Success = $true; IsOnAir = $false } }
            $true
        }
        $call = {
            param($arguments)
            $line = @{ op = 'urgent.manual'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $command = @{ actor = 4321; action = 'preview'; itemId = $script:UrgentBoard.Items[0].Id; autoHideSeconds = 30 }
            $review = (& $call $command).data.preview
            $review.autoHideSeconds | Should -Be 20
            $script:WebUrgentManualReviews[[long]4321].ExpiresAt = [datetimeoffset]::UtcNow.AddMinutes(-1)
            $command.action = 'show'
            $command.review = $review.review
            (& $call $command).error | Should -Be 'urgent_stale'
            $command.action = 'preview'
            $command.review = (& $call $command).data.preview.review
            $command.action = 'show'
            $script:webSingleScene = @{ Success = $true; IsOnAir = $true; ActiveId = 'other-scene' }
            (& $call $command).error | Should -Be 'urgent_stale'
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            $script:webSingleScene = @{ Success = $true; IsOnAir = $false }
            (& $call $command).error | Should -Be 'urgent_stale'
            $command.action = 'preview'
            $command.review = (& $call $command).data.preview.review
            $command.action = 'show'
            $script:MojazPlayback = @{ OperationId = 'new-bulletin' }
            (& $call $command).error | Should -Be 'urgent_stale'
            $command.action = 'preview'
            $newReview = (& $call $command).data.preview
            $newReview.stopsBulletin | Should -BeTrue
            $command.review = $newReview.review
            $command.action = 'show'
            $result = (& $call $command).data
            $result.autoHideFailed | Should -BeTrue
            $live = $result.live
            $live.itemId | Should -Be $command.itemId
            Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
                $AutoHideSeconds -eq 30 -and $ExpectedLayerStamp -eq 'empty' -and $Variables['headline'] -eq 'خبر فردي'
            }
            (& $call @{ actor = 4322; action = 'hide'; review = $live.review }).error | Should -Be 'urgent_stale'
            $hide = @{ actor = 4321; action = 'hide'; review = $live.review }
            $script:webSingleScene.ActiveId = 'replacement'
            (& $call $hide).error | Should -Be 'urgent_stale'
            Should -Invoke Invoke-HideLayer -Times 0 -Exactly
            $script:webSingleScene.ActiveId = 'single-scene'
            (& $call $hide).error | Should -Be 'urgent_manual_hide_unconfirmed'
            $script:UrgentManualLive.Count | Should -Be 1
            $script:webSingleHideClears = $true
            (& $call $hide).ok | Should -BeTrue
            Should -Invoke Invoke-HideLayer -Times 2 -Exactly -ParameterFilter { $ExpectedLayerStamp -eq 'active:single-scene' }
            $script:UrgentManualLive.Count | Should -Be 0
            (& $call $command).error | Should -Be 'urgent_stale'
        }
        finally {
            $script:UrgentBoard = $oldBoard
            $script:UrgentManualLive = $oldManual
            $script:WebUrgentManualReviews = $oldReviews
            $script:UrgentBoardRun = $oldRun
            $script:MojazPlayback = $oldBulletin
            if ($oldLayer) { $script:OnAir[5] = $oldLayer } else { $script:OnAir.Remove(5) | Out-Null }
        }
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
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowOperatorsClearAllNews' }
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

    It 'reviews a pasted ticker block and applies only the reviewed order and permitted clear' {
        $oldDraft = $script:NewsTickerDraft
        $oldPath = $script:newsDraftFile
        $oldRequest = $script:NewsLockRequest
        $oldRequestPath = $script:newsLockRequestFile
        $oldGrant = $script:NewsLockGrant
        $script:NewsLockRequest = $null
        $script:NewsLockGrant = $null
        $script:newsLockRequestFile = Join-Path $TestDrive 'web-paste-lock-request.json'
        $script:newsDraftFile = Join-Path $TestDrive 'web-paste-draft.json'
        $script:NewsTickerDraft = @{ Id = 'web-paste'; OwnerUserId = 4321; Items = @('قديم') }
        $script:webPasteAtTop = $true
        $script:webPasteCanClear = $false
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $false }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableNewsTickerManagement' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -in 'AllowOperatorsDeleteNews', 'AllowOperatorsRestoreNews' }
        Mock Get-Setting { '' } -ParameterFilter { $Name -eq 'NewsSheetCsvUrl' }
        Mock Get-Setting { $script:webPasteCanClear } -ParameterFilter { $Name -eq 'AllowOperatorsClearAllNews' }
        Mock Get-Setting { $script:webPasteAtTop } -ParameterFilter { $Name -eq 'NewNewsItemAtTop' }
        Mock Get-Setting { '|' } -ParameterFilter { $Name -eq 'NewsItemSeparator' }
        Mock Get-SettingInt { Get-BridgeSettingInt -Config $config -Defaults $script:DefaultSettings -Name $Name -Minimum $Minimum }
        Mock Get-SettingInt { 120 } -ParameterFilter { $Name -eq 'NewsLockGrantHoldSeconds' }
        $requestPaste = {
            param($arguments)
            $line = @{ op = 'ticker.edit'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $revision = Get-NewsTickerDraftRevision -Draft $script:NewsTickerDraft
            $inputText = "1. أول`n2. ثان`nقديم`nأول"
            $request = @{ actor = 4321; action = 'preview_paste'; text = $inputText; revision = $revision }
            $request.text = "أول | جزء`nثان"
            (& $requestPaste $request).error | Should -Be 'ticker_paste_separator'
            $request.text = $inputText
            $review = (& $requestPaste $request).data.paste
            $review.items | Should -Be @('أول', 'ثان')
            $review.duplicates | Should -Be 2
            $review.atTop | Should -BeTrue
            $script:NewsTickerDraft.Items | Should -Be @('قديم')
            $request.action = 'apply_paste'
            $request.review = $review.review
            $script:webPasteAtTop = $false
            (& $requestPaste $request).error | Should -Be 'ticker_stale'
            $script:webPasteAtTop = $true
            $applied = & $requestPaste $request
            $applied.data.draft.items | Should -Be @('أول', 'ثان', 'قديم')
            $clear = @{ actor = 4321; action = 'clear'; revision = $applied.data.draft.revision }
            (& $requestPaste $clear).error | Should -Be 'forbidden'
            $script:webPasteCanClear = $true
            $script:NewsTickerDraft.PublishAt = [datetimeoffset]::UtcNow.AddHours(1).ToString('o')
            (& $requestPaste $clear).error | Should -Be 'ticker_stale'
            $clear.revision = Get-NewsTickerDraftRevision -Draft $script:NewsTickerDraft
            $cleared = & $requestPaste $clear
            $cleared.data.draft.items | Should -BeNullOrEmpty
            $cleared.data.draft.scheduledAt | Should -BeNullOrEmpty
            $script:NewsLockRequest = @{ DraftId = 'web-paste'; OwnerUserId = 4321; RequesterUserId = 4322; RequesterChatId = 0 }
            Save-NewsLockRequest | Should -BeTrue
            $discarded = & $requestPaste @{ actor = 4321; action = 'discard'; revision = $cleared.data.draft.revision }
            $discarded.data.state | Should -Be 'locked'
            Test-Path -LiteralPath $script:newsDraftFile | Should -BeFalse
            Test-Path -LiteralPath $script:newsLockRequestFile | Should -BeFalse
            (Get-NewsLockReservation).UserId | Should -Be 4322
        }
        finally {
            $script:NewsTickerDraft = $oldDraft
            $script:newsDraftFile = $oldPath
            $script:NewsLockRequest = $oldRequest
            $script:newsLockRequestFile = $oldRequestPath
            $script:NewsLockGrant = $oldGrant
        }
    }

    It 'shares web lock requests and preserves drafts through approval and administrative release' {
        $owner = $script:WebOnlyUserIdBase + 1
        $oldDraft = $script:NewsTickerDraft
        $oldPath = $script:newsDraftFile
        $oldRequest = $script:NewsLockRequest
        $oldRequestPath = $script:newsLockRequestFile
        $oldGrant = $script:NewsLockGrant
        $script:newsDraftFile = Join-Path $TestDrive 'web-lock-draft.json'
        $script:newsLockRequestFile = Join-Path $TestDrive 'web-lock-request.json'
        $script:NewsLockRequest = $null
        $script:NewsLockGrant = $null
        $draft = @{ Id = 'web-lock'; OwnerUserId = $owner; OwnerChatId = $owner; Items = @('مسودة مشتركة'); PublishAt = [datetimeoffset]::UtcNow.AddHours(1).ToString('o') }
        $script:NewsTickerDraft = $draft
        Mock Test-Authorized { $UserId -in 4321, 4322, 9000000000000001 }
        Mock Test-Admin { $UserId -eq 4322 }
        Mock Get-Setting { Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableNewsTickerManagement' }
        Mock Send-TelegramMessage {}
        $command = {
            param($arguments)
            $payload = @{ op = 'ticker.edit'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $payload | ConvertFrom-Json
        }
        try {
            $initial = (& $command @{ actor = 4321; action = 'status' }).data.lock
            $initial.canRequest | Should -BeTrue
            (& $command @{ actor = 4321; action = 'force_release'; revision = $initial.revision }).error | Should -Be 'forbidden'
            $ask = @{ actor = 4321; action = 'request_lock'; revision = $initial.revision }
            (& $command $ask).data.lock.waiting | Should -BeTrue
            (& $command @{ actor = 4322; action = 'request_lock'; revision = $initial.revision }).error | Should -Be 'ticker_lock_pending'
            $approval = (& $command @{ actor = $owner; action = 'status' }).data.lock.response
            $approval | Should -Not -BeNullOrEmpty
            (& $command @{ actor = 4322; action = 'approve_lock'; review = $approval }).error | Should -Be 'forbidden'
            (& $command @{ actor = $owner; action = 'deny_lock'; review = $approval }).ok | Should -BeTrue
            (& $command $ask).ok | Should -BeTrue
            (& $command @{ actor = $owner; action = 'approve_lock'; review = $approval }).error | Should -Be 'ticker_stale'
            $approval = (& $command @{ actor = $owner; action = 'status' }).data.lock.response
            $released = & $command @{ actor = $owner; action = 'approve_lock'; review = $approval }
            $released.ok | Should -BeTrue
            $script:NewsTickerDraft.Items | Should -Be @('مسودة مشتركة')
            (Get-JsonProp $script:NewsTickerDraft 'PublishAt') | Should -BeNullOrEmpty
            (& $command @{ actor = 4321; action = 'status' }).data.state | Should -Be 'open'
            $claimed = & $command @{ actor = 4321; action = 'start' }
            $claimed.data.draft.items | Should -Be @('مسودة مشتركة')
            $administrative = (& $command @{ actor = 4322; action = 'status' }).data.lock
            $administrative.canForce | Should -BeTrue
            (& $command @{ actor = 4322; action = 'force_release'; revision = $administrative.revision }).data.state | Should -Be 'open'
            $script:NewsTickerDraft.Items | Should -Be @('مسودة مشتركة')

            (& $command @{ actor = 4321; action = 'start' }).ok | Should -BeTrue
            $newLock = (& $command @{ actor = $owner; action = 'status' }).data.lock
            (& $command @{ actor = $owner; action = 'request_lock'; revision = $newLock.revision }).ok | Should -BeTrue
            $originalId = $script:NewsLockRequest.Id
            $script:NewsLockRequest = $null
            Import-NewsLockRequest
            $script:NewsLockRequest.Id | Should -Be $originalId
            $script:NewsLockRequest.RequestedAt = (Get-Date).AddMinutes(-60)
            Update-NewsLockRequest
            $script:NewsTickerDraft = $null
            $script:NewsLockGrant = $null
            Import-NewsTickerDraft
            (& $command @{ actor = $owner; action = 'status' }).data.state | Should -Be 'open'
            (& $command @{ actor = 4322; action = 'status' }).data.state | Should -Be 'locked'
            (& $command @{ actor = $owner; action = 'start' }).data.draft.items | Should -Be @('مسودة مشتركة')

            Open-NewsTickerDraftToAll -ChatId $owner -UserId $owner | Should -BeTrue
            (& $command @{ actor = 4321; action = 'start' }).ok | Should -BeTrue
            Request-NewsLockRelease -ChatId 4322 -UserId 4322 | Should -BeTrue
            $telegramRequest = (& $command @{ actor = 4321; action = 'status' }).data.lock
            $telegramRequest.preservesAtDeadline | Should -BeFalse
            (& $command @{ actor = 4321; action = 'approve_lock'; review = $telegramRequest.response }).ok | Should -BeTrue
            $script:NewsTickerDraft = $null
            $script:NewsLockGrant = $null
            Import-NewsTickerDraft
            (& $command @{ actor = 4321; action = 'status' }).data.state | Should -Be 'locked'
            (& $command @{ actor = 4322; action = 'start' }).data.draft.items | Should -Be @('مسودة مشتركة')
        }
        finally {
            $script:NewsTickerDraft = $oldDraft
            $script:newsDraftFile = $oldPath
            $script:NewsLockRequest = $oldRequest
            $script:newsLockRequestFile = $oldRequestPath
            $script:NewsLockGrant = $oldGrant
        }
    }

    It 'imports reviewed UTF-8 bytes and replaces only the current ticker draft' {
        $oldDraft = $script:NewsTickerDraft
        $oldDraftPath = $script:newsDraftFile
        $oldImportPath = $script:newsImportDirectory
        $script:newsDraftFile = Join-Path $TestDrive 'web-txt-draft.json'
        $script:newsImportDirectory = Join-Path $TestDrive 'web-txt-uploads'
        New-Item -ItemType Directory -Path $script:newsImportDirectory | Out-Null
        $script:NewsTickerDraft = @{ Id = 'web-txt'; OwnerUserId = 4321; Items = @('المسودة الحالية'); PublishAt = [datetimeoffset]::UtcNow.AddHours(1).ToString('o') }
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Get-Setting { Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableNewsTickerManagement' }
        Mock Get-Setting { '|' } -ParameterFilter { $Name -eq 'NewsItemSeparator' }
        $command = {
            param($arguments)
            $line = @{ op = 'ticker.txt'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $revision = Get-NewsTickerDraftRevision -Draft $script:NewsTickerDraft
            $upload = [guid]::NewGuid().ToString('N')
            $candidate = Join-Path $script:newsImportDirectory "web-$upload.txt"
            (& $command @{ actor = 4322; action = 'prepare'; revision = $revision }).error | Should -Be 'ticker_locked'
            (& $command @{ actor = 4321; action = 'prepare'; revision = $revision }).data.maximumBytes | Should -BeGreaterThan 65536
            $preview = @{ actor = 4321; action = 'preview'; revision = $revision; upload = $upload }
            (& $command ($preview + @{ review = 'unused' })).error | Should -Be 'ticker_txt_invalid'
            [IO.File]::WriteAllBytes($candidate, [byte[]]@(0xff, 0xfe, 0))
            (& $command $preview).error | Should -Be 'ticker_txt_invalid'
            $news = 'أول خبر|ثاني خبر|أول خبر'
            [IO.File]::WriteAllText($candidate, $news, [Text.UTF8Encoding]::new($true))
            $entry = @{
                Request = @{ args = $preview }
                Deadline = [Diagnostics.Stopwatch]::GetTimestamp() + 10 * [Diagnostics.Stopwatch]::Frequency
                Reply = [System.Threading.Tasks.TaskCompletionSource[string]]::new()
            }
            Start-WebTickerTxtRequest -Entry $entry | Should -BeNullOrEmpty
            $entry.Reply.Task.IsCompleted | Should -BeFalse
            $script:NewsTickerDraft.Items = @('تحرير جديد')
            while (-not $entry.Reply.Task.IsCompleted -and [Diagnostics.Stopwatch]::GetTimestamp() -lt $entry.Deadline) {
                Update-WebTickerTxtRequest
                Wait-WebChannelSignal -Milliseconds 20
            }
            $entry.Reply.Task.IsCompleted | Should -BeTrue
            ($entry.Reply.Task.Result | ConvertFrom-Json).error | Should -Be 'ticker_stale'
            $script:NewsTickerDraft.Items = @('المسودة الحالية')
            $review = (& $command $preview).data
            $review.items | Should -Be @('أول خبر', 'ثاني خبر')
            $review.currentItems | Should -Be @('المسودة الحالية')
            $review.duplicates | Should -Be 1
            $review.cancelsSchedule | Should -BeTrue
            $script:NewsTickerDraft.Items | Should -Be @('المسودة الحالية')
            $apply = @{ actor = 4321; action = 'apply'; revision = $revision; upload = $upload; review = $review.review }
            [IO.File]::WriteAllText($candidate, 'محتوى غير مراجع')
            (& $command $apply).error | Should -Be 'ticker_stale'
            [IO.File]::WriteAllText($candidate, $news, [Text.UTF8Encoding]::new($true))
            (& $command $apply).ok | Should -BeTrue
            $script:NewsTickerDraft.Items | Should -Be @('أول خبر', 'ثاني خبر')
            (Get-JsonProp $script:NewsTickerDraft 'PublishAt') | Should -BeNullOrEmpty
            (& $command $apply).error | Should -Be 'ticker_stale'
        }
        finally {
            $script:NewsTickerDraft = $oldDraft
            $script:newsDraftFile = $oldDraftPath
            $script:newsImportDirectory = $oldImportPath
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
        $alternate = Join-Path $TestDrive 'alternate.cintitle'
        '<Scene><Var Name="title.Text" Type="String" /><Title Text="${title.Text}" /></Scene>' | Set-Content -LiteralPath $alternate
        $collision = Join-Path $TestDrive 'collision.cintitle'
        '<Scene><Var Name="mojaz_img" Type="String" /><Title Text="${mojaz_img}" /></Scene>' | Set-Content -LiteralPath $collision
        $mediaCollision = Join-Path $TestDrive 'media-collision.cintitle'
        '<Scene><Var Name="location.Text" Type="String" /><Plate File="${location.Text}" /></Scene>' | Set-Content -LiteralPath $mediaCollision
        $imageOnly = Join-Path $TestDrive 'image-only.cintitle'
        '<Scene><Var Name="mojaz_img" Type="File" /><Plate File="${mojaz_img}" /></Scene>' | Set-Content -LiteralPath $imageOnly
        @{
            Mojaz = @{ path = $scene; layer = 4 }
            HeadlineBulletin = @{ path = $alternate; layer = 6; bulletin = $true }
            ConflictingBulletin = @{ path = $collision; layer = 6; bulletin = $true }
            ConflictingMedia = @{ path = $mediaCollision; layer = 6; bulletin = $true }
            PhotoBulletin = @{ path = $imageOnly; layer = 6; bulletin = $true }
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
            $edit.revision = $again.data.revision
            $edit.values['title.Text'] = 'عنوان من البوت'
            $edit.values['location.Text'] = 'الميدان'
            $again = & $requestBulletin $edit

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

            $change = @{ actor = 4321; action = 'design'; id = $id; revision = $skipped.data.revision; design = 'HeadlineBulletin' }
            $oldPlayback = $script:MojazPlayback
            try {
                $script:MojazPlayback = @{ BulletinId = $id }
                (& $requestBulletin $change).error | Should -Be 'bulletin_on_air'
            }
            finally { $script:MojazPlayback = $oldPlayback }
            $changed = & $requestBulletin $change
            $changed.ok | Should -BeTrue
            $changed.data.design | Should -Be 'HeadlineBulletin'
            @($changed.data.fields).Name | Should -Be @('title.Text')
            $changed.data.rows[1].id | Should -Be $rowId
            (& $requestBulletin $change).error | Should -Be 'bulletin_stale'
            Import-MojazLibrary
            $change.revision = $changed.data.revision
            $change.design = 'ConflictingBulletin'
            (& $requestBulletin $change).error | Should -Be 'bulletin_design_collision'
            $change.design = 'ConflictingMedia'
            (& $requestBulletin $change).error | Should -Be 'bulletin_design_collision'
            $change.design = 'StudioBulletin'
            $restoredDesign = & $requestBulletin $change
            $restoredDesign.data.rows[1].media | Should -Contain 'mojaz_img'
            $restoredDesign.data.rows[1].values.'title.Text' | Should -Be 'عنوان من البوت'
            $restoredDesign.data.rows[1].values.'location.Text' | Should -Be 'الميدان'

            $restoredDesign.data.rows[1].imageMode | Should -Be 'new'
            @($restoredDesign.data.imageChoices).rowId | Should -Contain $rowId
            ($restoredDesign | ConvertTo-Json -Depth 9) | Should -Not -Match 'attached\.png'
            $imageEdit = @{
                actor = 4321; action = 'update'; id = $id; rowId = $restoredDesign.data.rows[0].id
                revision = $restoredDesign.data.revision; values = @{ 'title.Text' = 'خبر ثانٍ'; 'location.Text' = '' }
                imageMode = 'reuse'; imageSourceRowId = 'D:/unauthorized.png'
            }
            (& $requestBulletin $imageEdit).error | Should -Be 'bulletin_image_invalid'
            $imageEdit.imageSourceRowId = $rowId
            (Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id).Rows[0].PSObject.Properties.Remove('ImageMode')
            $reused = & $requestBulletin $imageEdit
            $reused.data.rows[0].imageMode | Should -Be 'new'
            (Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id).Rows[0].Image | Should -Be 'D:/station/attached.png'
            (& $requestBulletin $imageEdit).error | Should -Be 'bulletin_stale'
            $imageEdit.revision = $reused.data.revision
            $imageEdit.imageMode = 'template'
            $imageEdit.Remove('imageSourceRowId')
            $templateImage = & $requestBulletin $imageEdit
            $templateImage.data.rows[0].imageMode | Should -Be 'template'
            $imageEdit.revision = $templateImage.data.revision
            $imageEdit.imageMode = 'inherit'
            $inherited = & $requestBulletin $imageEdit
            $inherited.data.rows[0].imageMode | Should -Be 'inherit'

            $album = & $requestBulletin @{ actor = 4321; action = 'create'; name = 'موجز الصور'; design = 'PhotoBulletin' }
            $album.ok | Should -BeTrue
            $photo = & $requestBulletin @{ actor = 4321; action = 'add'; id = $album.data.id; revision = $album.data.revision; imageMode = 'template'; values = @{} }
            $photo.data.rows[0].imageMode | Should -Be 'template'
            $photo = & $requestBulletin @{ actor = 4321; action = 'update'; id = $album.data.id; revision = $photo.data.revision; rowId = $photo.data.rows[0].id; imageMode = 'inherit'; values = @{} }
            $photo.data.rows[0].imageMode | Should -Be 'inherit'

            Mock Write-BridgeValidatedJson { $false }
            $move.action = 'remove'
            $move.revision = $inherited.data.revision
            (& $requestBulletin $move).error | Should -Be 'bulletin_save_failed'
            $stillSaved = & $requestBulletin @{ actor = 4321; action = 'read'; id = $id }
            $stillSaved.data.revision | Should -Be $inherited.data.revision
            $stillSaved.data.rows[1].id | Should -Be $rowId

            Move-Item -LiteralPath $scene -Destination (Join-Path $TestDrive 'retired-bulletin.cintitle')
            $unreadable = & $requestBulletin @{ actor = 4321; action = 'read'; id = $id }
            $unreadable.data.fields | Should -BeNullOrEmpty
            $edit.revision = $unreadable.data.revision
            (& $requestBulletin $edit).error | Should -Be 'bulletin_invalid'
        }
        finally { $script:MojazLibrary = $previousLibrary }
    }

    It 'validates and saves a staged bulletin photo only for the current row revision' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'photo-library.json' }
        Mock Get-MojazUploadDirectory { Join-Path $TestDrive 'scene-pictures' }
        Mock Get-MojazImageSize { @{ Width = 32; Height = 18 } }
        Mock Test-MojazAvailable { $true }
        Mock Get-WebBulletinFields { @{ name = $script:MojazImageVariable; label = 'الصورة'; kind = 'media' } }
        $oldLibrary = $script:MojazLibrary
        $oldUploadDirectory = Get-Variable mojazWebUploadDirectory -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $script:mojazWebUploadDirectory = Join-Path $TestDrive 'web-photo-uploads'
        New-Item -ItemType Directory -Path $script:mojazWebUploadDirectory | Out-Null
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الصور').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -Title 'عنوان محفوظ').Value
            $bulletin = $script:MojazLibrary.Bulletins[0]
            $sendPhoto = {
                param($photoArgs)
                $line = @{ op = 'bulletin.photo'; args = $photoArgs } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $photo = @{ actor = 999; action = 'prepare'; id = $id; rowId = $bulletin.Rows[0].Id; revision = $bulletin.Revision }
            (& $sendPhoto $photo).error | Should -Be 'forbidden'
            $photo.actor = 4321
            (& $sendPhoto $photo).data.maximumBytes | Should -Be 10MB
            $photo.action = 'apply'
            $photo.upload = [guid]::NewGuid().ToString('N')
            $inputFile = Join-Path $script:mojazWebUploadDirectory "web-$($photo.upload).image"
            Set-Content -LiteralPath $inputFile -Value 'هذا ليس صورة'
            (& $sendPhoto $photo).error | Should -Be 'bulletin_photo_invalid'
            $large = [IO.File]::OpenWrite($inputFile)
            try { $large.SetLength(10MB + 1) }
            finally { $large.Dispose() }
            (& $sendPhoto $photo).error | Should -Be 'bulletin_photo_size'
            $bitmap = [System.Drawing.Bitmap]::new(2, 2)
            try { $bitmap.Save($inputFile, [System.Drawing.Imaging.ImageFormat]::Png) }
            finally { $bitmap.Dispose() }
            $validRevision = $photo.revision
            $photo.revision--
            (& $sendPhoto $photo).error | Should -Be 'bulletin_stale'
            $photo.revision = $validRevision
            Mock Get-MojazImageSize { @{ Width = 40; Height = 18 } } -ParameterFilter { $script:webPhotoTargetChanged }
            $script:webPhotoTargetChanged = $false
            Mock Test-Authorized {
                $script:webPhotoAuthChecks++
                if ($script:webPhotoAuthChecks -eq 2) { $script:webPhotoTargetChanged = $true }
                $UserId -eq 4321
            }
            $script:webPhotoAuthChecks = 0
            (& $sendPhoto $photo).error | Should -Be 'bulletin_stale'
            @(Get-ChildItem -LiteralPath (Get-MojazUploadDirectory) -Filter '*.png').Count | Should -Be 0
            $script:webPhotoTargetChanged = $false
            $edited = & $sendPhoto $photo
            $edited.ok | Should -BeTrue
            $edited.data.rows[0].imageMode | Should -Be 'new'
            ($edited | ConvertTo-Json -Depth 8) | Should -Not -Match '\.png'
            Import-MojazLibrary
            $saved = $script:MojazLibrary.Bulletins[0].Rows[0]
            $saved.Title | Should -Be 'عنوان محفوظ'
            $saved.Image | Should -Match '^\.\\Mojaz\\bot\\mojaz-.*\.png$'
            $file = Join-Path (Get-MojazUploadDirectory) (Split-Path -Leaf $saved.Image)
            $decoded = [System.Drawing.Image]::FromFile($file)
            try { $decoded.Width | Should -Be 32; $decoded.Height | Should -Be 18 }
            finally { $decoded.Dispose() }
            (& $sendPhoto $photo).error | Should -Be 'bulletin_stale'
            $photo.revision = $script:MojazLibrary.Bulletins[0].Revision
            Mock Get-WebBulletinEditor { throw 'simulated editor projection failure' }
            (& $sendPhoto $photo).error | Should -Be 'bridge_outcome_unknown'
            $newImage = $script:MojazLibrary.Bulletins[0].Rows[0].Image
            Test-Path -LiteralPath (Join-Path (Get-MojazUploadDirectory) (Split-Path -Leaf $newImage)) | Should -BeTrue
        }
        finally {
            $script:MojazLibrary = $oldLibrary
            $script:mojazWebUploadDirectory = $oldUploadDirectory
        }
    }

    It 'deletes only the programme board revision reviewed by an administrator' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-BoardsAvailable { $true }
        Mock Get-BoardsDirectory { Join-Path $TestDrive 'programme-board-delete' }
        $board = (New-ContentBoard -Name 'لوحة للحذف التجريبي' -TemplateKey 'Programme').Value
        $id = $board.Id
        try {
            Save-ContentBoard -Board $board | Should -BeTrue
            $path = Join-Path (Get-BoardsDirectory) 'imported-programme.json'
            Move-Item -LiteralPath (Get-BoardFilePath -BoardId $id) -Destination $path
            Copy-Item -LiteralPath $path -Destination "$path.bak"
            Import-ContentBoards
            $request = @{ actor = 4322; id = $id; revision = $board.Revision }
            $send = {
                $line = @{ op = 'board.delete'; args = $request } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            (& $send).error | Should -Be 'forbidden'
            $request.actor = 4321
            $request.revision++
            (& $send).error | Should -Be 'board_stale'
            Test-Path -LiteralPath $path | Should -BeTrue
            $request.revision = $board.Revision
            $duplicate = Join-Path (Get-BoardsDirectory) 'another-import.json'
            Copy-Item -LiteralPath $path -Destination $duplicate
            Import-ContentBoards
            (& $send).error | Should -Be 'board_delete_failed'
            Test-Path -LiteralPath $path | Should -BeTrue
            Test-Path -LiteralPath $duplicate | Should -BeTrue
            Remove-Item -LiteralPath $duplicate
            Import-ContentBoards
            $handle = [IO.File]::Open($path, 'Open', 'Read', 'Read')
            try { (& $send).error | Should -Be 'board_delete_failed' }
            finally { $handle.Dispose() }
            (Get-ContentBoard -BoardId $id).Revision | Should -Be $board.Revision
            Test-Path -LiteralPath "$path.bak" | Should -BeTrue
            (& $send).ok | Should -BeTrue
            Test-Path -LiteralPath $path | Should -BeFalse
            Test-Path -LiteralPath "$path.bak" | Should -BeFalse
            Import-ContentBoards
            Get-ContentBoard -BoardId $id | Should -BeNullOrEmpty
        }
        finally { Remove-ContentBoardFile -BoardId $id | Out-Null }
    }

    It 'reviews a programme board paste and commits the same rows once' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-BoardsAvailable { $true }
        Mock Get-BoardTextFields { 'programme.title'; 'programme.guest' }
        Mock Get-MojazFieldLabel { $FieldName }
        Mock Write-BridgeValidatedJson { $true }
        $board = (New-ContentBoard -Name 'برنامج الاختبار' -TemplateKey 'Programme' -EditRole 'admin').Value
        try {
            Save-ContentBoard -Board $board | Should -BeTrue
            $request = @{ actor = 4321; action = 'preview'; id = $board.Id; revision = $board.Revision; format = 'table'
                text = "`tضيف أول`nفقرة ثانية`tضيف ثانٍ`nأ`tب`tج" }
            $send = {
                $line = @{ op = 'board.paste'; args = $request } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $preview = & $send
            $preview.ok | Should -BeTrue
            $preview.data.preview.rows.Count | Should -Be 2
            $preview.data.preview.rows[0].'programme.title' | Should -BeNullOrEmpty
            $preview.data.preview.rows[0].'programme.guest' | Should -Be 'ضيف أول'
            $preview.data.preview.skippedLines | Should -Be @(3)
            (Get-ContentBoard -BoardId $board.Id).Items.Count | Should -Be 0
            $request.action = 'commit'
            $request.review = $preview.data.preview.review
            $request.actor = 4322
            (& $send).error | Should -Be 'forbidden'
            $request.actor = 4321
            $originalText = $request.text
            $request.text += "`nفقرة مختلفة`tضيف مختلف"
            (& $send).error | Should -Be 'board_stale'
            $request.text = $originalText
            $saved = & $send
            $saved.ok | Should -BeTrue
            $saved.data.savedPage | Should -Be 0
            $savedBoard = Get-ContentBoard -BoardId $board.Id
            $savedBoard.Revision | Should -Be ($board.Revision + 1)
            $savedBoard.Items.Count | Should -Be 2
            (& $send).error | Should -Be 'board_stale'
            $request.action = 'preview'
            $request.revision = $savedBoard.Revision
            $request.format = 'pipe'
            $request.text = 'افتتاح | ضيف الافتتاح'
            $pipePreview = & $send
            $pipePreview.data.preview.rows[0].'programme.guest' | Should -Be 'ضيف الافتتاح'

            $legacyTitle = 'أ' * 500
            $legacy = Add-BoardItem -Board (Get-ContentBoard -BoardId $board.Id) -TextFields @('programme.title', 'programme.guest') `
                -Values @{ 'programme.title' = $legacyTitle; 'programme.guest' = 'ضيف سابق' } -MaxFieldLength 500
            Save-ContentBoard -Board $legacy.Value | Should -BeTrue
            $legacyRow = $legacy.Value.Items[-1]
            $line = @{ op = 'board.edit'; args = @{ actor = 4321; action = 'update'; id = $board.Id
                    revision = $legacy.Value.Revision; rowId = $legacyRow.Id
                    values = @{ 'programme.title' = $legacyTitle; 'programme.guest' = 'ضيف جديد' } } } | ConvertTo-Json -Compress -Depth 5
            $edited = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $edited.ok | Should -BeTrue
            $edited.data.rows[-1].values.'programme.title' | Should -Be $legacyTitle
            $edited.data.rows[-1].values.'programme.guest' | Should -Be 'ضيف جديد'
        }
        finally { Remove-ContentBoardFile -BoardId $board.Id }
    }

    It 'plays a reviewed programme row and only hides the exact scene reviewed by the operator' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-BoardsAvailable { $true }
        Mock Test-MaintenanceControl { $true }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-TemplateShowPolicy { @{ Allowed = $true } }
        Mock Get-BoardTextFields { 'programme.title'; 'programme.guest' }
        Mock Get-MojazFieldLabel { $FieldName }
        Mock Get-EffectiveAutoHideSeconds { 0 }
        Mock Write-BridgeValidatedJson { $true }
        $script:BoardAirPath = Join-Path $TestDrive 'programme.cintitle'
        Set-Content -LiteralPath $script:BoardAirPath -Value '<Scene />'
        Mock Get-TemplateStore { @{ Map = @{ Programme = @{ Key = 'Programme'; Layer = 7; Path = $script:BoardAirPath } } } }
        $script:BoardAirEngine = @{ Success = $true; IsOnAir = $false }
        $script:BoardAirSceneMode = 'Single'
        $script:BoardAirHasIdentity = $true
        Mock Get-Setting { $script:BoardAirSceneMode } -ParameterFilter { $Name -eq 'SceneMode' }
        Mock Get-TitlerLayerStatus { $script:BoardAirEngine }
        Mock Invoke-ShowTemplateResult {
            $engineStarted = ([datetimeoffset]'2025-01-01T15:00:00Z').UtcDateTime
            $script:OnAir[7] = @{ Key = 'Programme'; ActiveId = '{show-1}'; ActiveIdConfirmed = $true; At = Get-Date }
            $script:BoardAirEngine = @{
                Success = $true; IsOnAir = $true; ActiveId = '{show-1}'; ActiveXml = '<Item ScheduledAt="2025-01-01T15:00:00Z" />'
            }
            @{ Success = $true; EngineStartedAtUtc = $engineStarted; EventIdentityConfirmed = $script:BoardAirHasIdentity }
        }
        Mock Invoke-HideLayer {
            $script:OnAir.Remove(7)
            $script:BoardAirEngine = @{ Success = $true; IsOnAir = $false }
            $true
        }
        $board = (New-ContentBoard -Name 'برنامج العرض' -TemplateKey 'Programme' -EditRole 'admin').Value
        $board = (Add-BoardItem -Board $board -TextFields @('programme.title', 'programme.guest') -Values @{
                'programme.title' = 'الفقرة الأولى'; 'programme.guest' = 'الضيف الأول' } -MaxFieldLength 100).Value
        $boardId = $board.Id
        try {
            Save-ContentBoard -Board $board | Should -BeTrue
            $request = @{ actor = 4322; action = 'show-preview'; id = $boardId; revision = $board.Revision; rowId = $board.Items[0].Id }
            $sendBoardAir = {
                $line = @{ op = 'board.air'; args = $request } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $preview = & $sendBoardAir
            $preview.ok | Should -BeTrue
            $preview.data.preview.layer | Should -Be 7
            $preview.data.preview.fields.value | Should -Be @('الفقرة الأولى', 'الضيف الأول')
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly

            $request.action = 'show'
            $request.review = $preview.data.preview.review
            $request.actor = 4321
            (& $sendBoardAir).error | Should -Be 'board_stale'
            $request.actor = 4322
            $script:BoardAirEngine = @{ Success = $true; IsOnAir = $true; ActiveId = '{incoming}' }
            (& $sendBoardAir).error | Should -Be 'board_stale'
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly

            $request.action = 'show-preview'
            $preview = & $sendBoardAir
            $preview.data.preview.replacesGraphic | Should -BeTrue
            $request.action = 'show'
            $request.review = $preview.data.preview.review
            $shown = & $sendBoardAir
            $shown.ok | Should -BeTrue
            $shown.data.liveRowId | Should -Be $request.rowId
            (& $sendBoardAir).error | Should -Be 'board_stale'
            Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
                $Key -eq 'Programme' -and $ExpectedLayer -eq 7 -and $ExpectedLayerStamp -eq 'active:incoming' -and -not $RequireEventIdentity -and
                $Variables['programme.guest'] -eq 'الضيف الأول'
            }

            $request.action = 'hide-preview'
            $script:BoardAirSceneMode = 'Multi'
            (& $sendBoardAir).error | Should -Be 'board_air_multiple'
            $script:BoardAirSceneMode = 'Single'
            $hidePreview = & $sendBoardAir
            $hidePreview.ok | Should -BeTrue
            $request.action = 'hide'
            $request.review = $hidePreview.data.preview.review
            $script:BoardAirEngine.ActiveId = '{different}'
            (& $sendBoardAir).error | Should -Be 'board_stale'
            Should -Invoke Invoke-HideLayer -Times 0 -Exactly

            $script:BoardAirEngine.ActiveId = '{show-1}'
            $request.action = 'hide-preview'
            $script:BoardAirEngine.ActiveXml = '<Item ScheduledAt="2025-01-01T15:00:00.333Z" />'
            (& $sendBoardAir).error | Should -Be 'board_stale'
            $script:BoardAirEngine.ActiveXml = '<Item ScheduledAt="2025-01-01T15:00:00Z" />'
            $hidePreview = & $sendBoardAir
            $request.action = 'hide'
            $request.review = $hidePreview.data.preview.review
            $hidden = & $sendBoardAir
            $hidden.ok | Should -BeTrue
            $hidden.data.liveRowId | Should -BeNullOrEmpty
            Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 7 -and $ExpectedLayerStamp -eq 'active:show-1' }

            $script:BoardAirHasIdentity = $false
            $request.action = 'show-preview'
            $preview = & $sendBoardAir
            $request.action = 'show'
            $request.review = $preview.data.preview.review
            $uncertain = & $sendBoardAir
            $uncertain.ok | Should -BeTrue
            $uncertain.data.liveRowId | Should -BeNullOrEmpty
            $request.action = 'hide-preview'
            (& $sendBoardAir).error | Should -Be 'board_stale'
        }
        finally {
            Clear-BoardItemLive -Layer 7
            $script:OnAir.Remove(7)
            Remove-ContentBoardFile -BoardId $boardId
        }
    }

    It 'reviews a live programme correction and writes only selected fields to the confirmed scene' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-BoardsAvailable { $true }
        Mock Test-MaintenanceControl { $true }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Get-BoardTextFields { 'programme.title'; 'programme.guest' }
        Mock Get-MojazFieldLabel { $FieldName }
        Mock Write-BridgeValidatedJson { $true }
        $script:BoardCorrectionProgrammePath = Join-Path $TestDrive 'correction-programme.cintitle'
        $script:BoardCorrectionLogoPath = Join-Path $TestDrive 'correction-logo.cintitle'
        Set-Content -LiteralPath $script:BoardCorrectionProgrammePath -Value '<Scene />'
        Set-Content -LiteralPath $script:BoardCorrectionLogoPath -Value '<Scene />'
        Mock Get-TemplateStore {
            @{ Map = @{ Programme = @{ Layer = 7; Path = $script:BoardCorrectionProgrammePath }
                    Logo = @{ Layer = 2; Path = $script:BoardCorrectionLogoPath } } }
        }
        Mock Get-MojazDesignFields {
            @{ Name = $script:BoardCorrectionOtherField; Kind = 'text' }
        } -ParameterFilter { $TemplateKey -eq 'Logo' }
        $script:BoardCorrectionOtherField = 'logo.channel'
        $script:BoardCorrectionEvent = '{programme-event}'
        $script:BoardCorrectionExternal = $false
        Mock Get-TitlerLayerStatus {
            if ($Device -eq '4' -and $script:BoardCorrectionExternal) {
                return @{ Success = $true; IsOnAir = $true; ActiveId = '{external-event}' }
            }
            if ($Layer -notin 2, 7) { return @{ Success = $true; IsOnAir = $false } }
            $id = if ($Layer -eq 7) { $script:BoardCorrectionEvent } else { '{logo-event}' }
            @{ Success = $true; IsOnAir = $true; ActiveId = $id }
        }
        Mock Invoke-SetValues { $true }
        $board = (New-ContentBoard -Name 'برنامج التصحيح' -TemplateKey 'Programme' -EditRole 'admin').Value
        $board = (Add-BoardItem -Board $board -TextFields @('programme.title', 'programme.guest') -Values @{
                'programme.title' = 'الافتتاح'; 'programme.guest' = 'الاسم المحفوظ' } -MaxFieldLength 100).Value
        $boardId = $board.Id
        try {
            Save-ContentBoard -Board $board | Should -BeTrue
            $script:OnAir[7] = @{ Key = 'Programme'; ActiveId = '{programme-event}'; ActiveIdConfirmed = $true; At = Get-Date }
            $script:OnAir[2] = @{ Key = 'Logo'; ActiveId = '{logo-event}'; ActiveIdConfirmed = $true; At = Get-Date }
            $script:LastSuccessfulLayerShows[7] = @{ Key = 'Programme'; ActiveId = '{programme-event}'; ActiveIdConfirmed = $true
                TemplatePath = $script:BoardCorrectionProgrammePath; SceneWriteTicks = (Get-Item $script:BoardCorrectionProgrammePath).LastWriteTimeUtc.Ticks }
            $script:LastSuccessfulLayerShows[2] = @{ Key = 'Logo'; ActiveId = '{logo-event}'; ActiveIdConfirmed = $true
                TemplatePath = $script:BoardCorrectionLogoPath; SceneWriteTicks = (Get-Item $script:BoardCorrectionLogoPath).LastWriteTimeUtc.Ticks }
            Set-BoardItemLive -Layer 7 -BoardId $boardId -ItemId $board.Items[0].Id -AirIdentity (Get-BoardAirIdentity -Layer 7 -Key 'Programme')
            $request = @{ actor = 4322; action = 'update-preview'; id = $boardId; revision = $board.Revision; rowId = $board.Items[0].Id
                values = @{ 'programme.guest' = 'الاسم المصحّح' } }
            $sendCorrection = {
                $line = @{ op = 'board.air'; args = $request } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            (& $sendCorrection).error | Should -Be 'forbidden'
            $request.actor = 4321
            $first = & $sendCorrection
            $first.ok | Should -BeTrue
            $first.data.preview.fields.value | Should -Be 'الاسم المصحّح'
            Should -Invoke Invoke-SetValues -Times 0 -Exactly

            $request.action = 'update'
            $request.review = $first.data.preview.review
            $script:BoardCorrectionEvent = '{different}'
            (& $sendCorrection).error | Should -Be 'board_stale'
            $script:BoardCorrectionEvent = '{programme-event}'
            $request.action = 'update-preview'
            $second = & $sendCorrection
            $request.action = 'update'
            $request.review = $second.data.preview.review
            $script:BoardCorrectionOtherField = 'programme.guest'
            (& $sendCorrection).error | Should -Be 'board_air_conflict'
            Should -Invoke Invoke-SetValues -Times 0 -Exactly

            $script:BoardCorrectionOtherField = 'logo.channel'
            $request.action = 'update-preview'
            $script:BoardCorrectionExternal = $true
            (& $sendCorrection).error | Should -Be 'board_air_conflict'
            $script:BoardCorrectionExternal = $false
            $oldTicks = $script:LastSuccessfulLayerShows[7].SceneWriteTicks
            $script:LastSuccessfulLayerShows[7].SceneWriteTicks = $oldTicks - 1
            (& $sendCorrection).error | Should -Be 'board_air_conflict'
            $script:LastSuccessfulLayerShows[7].SceneWriteTicks = $oldTicks
            $latest = & $sendCorrection
            $request.action = 'update'
            $request.review = $latest.data.preview.review
            (& $sendCorrection).ok | Should -BeTrue
            (& $sendCorrection).error | Should -Be 'board_stale'
            Should -Invoke Invoke-SetValues -Times 1 -Exactly -ParameterFilter {
                $Quiet -and $Values.Count -eq 1 -and $Values['programme.guest'] -ceq 'الاسم المصحّح'
            }
            $saved = Get-ContentBoard -BoardId $boardId
            $saved.Revision | Should -Be $board.Revision
            $saved.Items[0].Values.'programme.guest' | Should -Be 'الاسم المحفوظ'

            $request.action = 'update-preview'
            $after = & $sendCorrection
            $request.action = 'update'
            $request.review = $after.data.preview.review
            $expired = Invoke-WebChannelOperation -Request @{ op = 'board.air'; args = $request } -Entry @{ Deadline = [long]1 }
            $expired.error | Should -Be 'bridge_busy'
            Should -Invoke Invoke-SetValues -Times 1 -Exactly
        }
        finally {
            Clear-BoardItemLive -Layer 7
            $script:OnAir.Remove(7)
            $script:OnAir.Remove(2)
            $script:LastSuccessfulLayerShows.Remove(7)
            $script:LastSuccessfulLayerShows.Remove(2)
            Remove-ContentBoardFile -BoardId $boardId
        }
    }

    It 'shares programme boards with the bot and applies its row permissions and revision checks' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-BoardsAvailable { $true }
        Mock Get-BoardsDirectory { Join-Path $TestDrive 'programme-boards' }
        Mock Get-BoardTextFields { 'programme.title'; 'programme.guest[1]' }
        Mock Get-BoardMediaFields { 'programme.logo' }
        Mock Get-MojazFieldLabel { $FieldName }
        Mock Write-BridgeValidatedJson { $true }
        $board = (New-ContentBoard -Name 'لقاء المساء' -TemplateKey 'Programme' -EditRole 'admin').Value
        $boardId = $board.Id
        try {
            Save-ContentBoard -Board $board | Should -BeTrue
            $sendBoard = {
                param($operation, $payload)
                $line = @{ op = $operation; args = $payload } | ConvertTo-Json -Compress -Depth 5
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $list = & $sendBoard 'board.list' @{ actor = 4322 }
            $list.ok | Should -BeTrue
            $list.data.items.Id | Should -Contain $boardId
            $read = & $sendBoard 'board.edit' @{ actor = 4322; action = 'read'; id = $boardId }
            $read.data.canEdit | Should -BeFalse
            $read.data.fields.name | Should -Be @('programme.title', 'programme.guest[1]')
            $read.data.sceneMedia | Should -Be @('programme.logo')
            $inputRow = @{ actor = 4322; action = 'add'; id = $boardId; revision = $board.Revision
                values = @{ 'programme.title' = 'لقاء المساء'; 'programme.guest[1]' = 'الضيف الأول' } }
            (& $sendBoard 'board.edit' $inputRow).error | Should -Be 'forbidden'
            $inputRow.actor = 4321
            $added = & $sendBoard 'board.edit' $inputRow
            $added.ok | Should -BeTrue
            $rowId = $added.data.rows[0].id
            $added.data.rows[0].values.'programme.guest[1]' | Should -Be 'الضيف الأول'
            (& $sendBoard 'board.edit' $inputRow).error | Should -Be 'board_stale'
            $inputRow.action = 'update'
            $inputRow.revision = $added.data.revision
            $inputRow.rowId = $rowId
            $inputRow.values['programme.title'] = 'اللقاء المباشر'
            $inputRow.values['programme.guest[1]'] = 'الضيف الثاني'
            $inputRow.values['programme.logo'] = 'untrusted.png'
            (& $sendBoard 'board.edit' $inputRow).error | Should -Be 'board_unknown_field'
            (Get-BoardItem -Board (Get-ContentBoard -BoardId $boardId) -ItemId $rowId).Values.'programme.title' | Should -Be 'لقاء المساء'
            $inputRow.values.Remove('programme.logo')
            $inputRow.values['programme.title'] = "نص معطوب`0"
            (& $sendBoard 'board.edit' $inputRow).error | Should -Be 'board_invalid_text'
            $inputRow.values['programme.title'] = 'اللقاء المباشر'
            $edited = & $sendBoard 'board.edit' $inputRow
            $edited.data.revision | Should -Be ($added.data.revision + 1)
            $edited.data.rows[0].values.'programme.title' | Should -Be 'اللقاء المباشر'
            $edited.data.rows[0].values.'programme.guest[1]' | Should -Be 'الضيف الثاني'
            $disabled = & $sendBoard 'board.edit' @{ actor = 4322; action = 'disable'; id = $boardId
                revision = $edited.data.revision; rowId = $rowId }
            $disabled.ok | Should -BeTrue
            $disabled.data.rows[0].enabled | Should -BeFalse
        }
        finally { Remove-ContentBoardFile -BoardId $boardId }
    }

    It 'creates a programme board only for an administrator using an eligible template' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-BoardsAvailable { $true }
        Mock Get-BoardsDirectory { Join-Path $TestDrive 'programme-boards' }
        Mock Get-BoardEligibleTemplates {
            [pscustomobject]@{ Key = 'Programme'; Layer = 7; Usable = $true; Reason = '' }
            [pscustomobject]@{ Key = 'NoText'; Layer = 8; Usable = $false; Reason = 'لا حقول نصية' }
        }
        Mock Get-BoardTextFields { 'programme.host' }
        Mock Get-MojazFieldLabel { 'المقدّم' }
        Mock Write-BridgeValidatedJson { $true }
        $request = @{ actor = 4322; action = 'create'; template = 'Programme'; name = 'موعد مع الثقافة' }
        $sendBoard = {
            $line = @{ op = 'board.edit'; args = $request } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        $initial = @(Get-ContentBoards).Count
        $createdId = ''
        try {
            (& $sendBoard).error | Should -Be 'forbidden'
            $request.actor = 4321
            $request.template = 'NoText'
            (& $sendBoard).error | Should -Be 'board_invalid_template'
            @(Get-ContentBoards).Count | Should -Be $initial
            $request.template = 'Programme'
            $created = & $sendBoard
            $createdId = $created.data.id
            $created.ok | Should -BeTrue
            (Get-ContentBoard -BoardId $createdId).Name | Should -Be 'موعد مع الثقافة'
            $request = @{ actor = 4322; action = 'role'; id = $createdId; revision = $created.data.revision; role = 'owner' }
            (& $sendBoard).error | Should -Be 'forbidden'
            $request.actor = 4321
            $locked = & $sendBoard
            $locked.ok | Should -BeTrue
            $locked.data.editRole | Should -Be 'owner'
            $locked.data.canEdit | Should -BeFalse
        }
        finally { if ($createdId) { Remove-ContentBoardFile -BoardId $createdId } }
    }

    It 'uploads a photo only to the selected custom bulletin media field' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-MojazAvailable { $true }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'custom-photo-library.json' }
        Mock Get-TemplateRegistryFilePath { Join-Path $TestDrive 'custom-photo-templates.json' }
        $sceneFolder = Join-Path $TestDrive "studio`u{A0}archive"
        New-Item -ItemType Directory -Path $sceneFolder | Out-Null
        $path = Join-Path $sceneFolder 'custom-photo.cintitle'
        '<Scene Fps="25" Duration="125"><Var Name="studio.main" Type="File" /><Plate File="${studio.main}" Size="40;20" /><Var Name="studio.side" Type="File" /><Plate File="${studio.side}" /><Var Name="studio.title" Type="String" /><Title Text="${studio.title}" /></Scene>' |
            Set-Content -LiteralPath $path
        @{ StudioPhoto = @{ path = $path; layer = 6; bulletin = $true } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-TemplateRegistryFilePath)
        $oldLibrary = $script:MojazLibrary
        $oldUploadDirectory = Get-Variable mojazWebUploadDirectory -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $script:mojazWebUploadDirectory = Join-Path $TestDrive 'web-custom-photo-uploads'
        New-Item -ItemType Directory -Path $script:mojazWebUploadDirectory | Out-Null
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'صور الاستوديو' -TemplateKey 'StudioPhoto').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -Fields @{
                    'studio.title' = 'عنوان ثابت'; 'studio.side' = 'other.png'
                }).Value
            $bulletin = $script:MojazLibrary.Bulletins[0]
            $photo = @{ actor = 4321; action = 'prepare'; id = $id; rowId = $bulletin.Rows[0].Id; revision = $bulletin.Revision; field = 'studio.title' }
            $send = {
                $line = @{ op = 'bulletin.photo'; args = $photo } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            (& $send).error | Should -Be 'bulletin_photo_unavailable'
            $photo.field = 'studio.main'
            (& $send).ok | Should -BeTrue
            $photo.action = 'apply'
            $photo.upload = [guid]::NewGuid().ToString('N')
            $inputFile = Join-Path $script:mojazWebUploadDirectory "web-$($photo.upload).image"
            $bitmap = [System.Drawing.Bitmap]::new(3, 3)
            try { $bitmap.Save($inputFile, [System.Drawing.Imaging.ImageFormat]::Png) }
            finally { $bitmap.Dispose() }
            $edited = & $send
            $edited.ok | Should -BeTrue
            $edited.data.photoFields | Should -Contain 'studio.main'
            $edited.data.rows[0].media | Should -Contain 'studio.main'
            ($edited | ConvertTo-Json -Depth 8) | Should -Not -Match '\.png'
            Import-MojazLibrary
            $row = $script:MojazLibrary.Bulletins[0].Rows[0]
            $row.Fields.'studio.side' | Should -Be 'other.png'
            $row.Fields.'studio.title' | Should -Be 'عنوان ثابت'
            $row.Image | Should -BeNullOrEmpty
            $asset = [System.Drawing.Image]::FromFile($row.MediaFields.'studio.main')
            try { $asset.Width | Should -Be 40; $asset.Height | Should -Be 20 }
            finally { $asset.Dispose() }
            $previewArgs = @{ actor = 4321; id = $id; rowId = $row.Id; revision = $edited.data.revision; field = 'studio.main' }
            $line = @{ op = 'bulletin.preview'; args = $previewArgs } | ConvertTo-Json -Compress
            $preview = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $preview.ok | Should -BeTrue
            $preview.data.rows[0].imageFields | Should -Contain 'studio.main'
            ($preview | ConvertTo-Json -Depth 8) | Should -Not -Match '\.png'

            $photo.revision = $edited.data.revision
            $photo.Remove('rowId')
            (& $send).error | Should -Be 'not_found'
            $photo.createRow = $true
            $photo.field = 'studio.side'
            $photo.upload = [guid]::NewGuid().ToString('N')
            $newUpload = Join-Path $script:mojazWebUploadDirectory "web-$($photo.upload).image"
            Set-Content -LiteralPath $newUpload 'not an image'
            (& $send).error | Should -Be 'bulletin_photo_invalid'
            (Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id).Rows.Count | Should -Be 1
            (Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id).Revision | Should -Be $photo.revision
            Copy-Item -LiteralPath $inputFile -Destination $newUpload -Force
            $added = & $send
            $added.ok | Should -BeTrue
            $added.data.total | Should -Be 2
            $added.data.rows[1].media | Should -Be @('studio.side')
            $added.data.rows[1].values.'studio.title' | Should -BeNullOrEmpty
            (& $send).error | Should -Be 'bulletin_stale'
            Import-MojazLibrary
            $saved = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $id
            $saved.Rows[0].Id | Should -Be $row.Id
            Test-Path -LiteralPath $saved.Rows[1].MediaFields.'studio.side' | Should -BeTrue
        }
        finally {
            $script:MojazLibrary = $oldLibrary
            $script:mojazWebUploadDirectory = $oldUploadDirectory
        }
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

    It 'edits and previews timing against the selected bulletin design through the pipe' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Get-Setting { Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'MojazMultiDesign' }
        Mock Test-MojazAvailable { $true }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'web-studio-timing.json' }
        Mock Get-TemplateRegistryFilePath { Join-Path $TestDrive 'studio-timing-templates.json' }
        Mock Invoke-ShowTemplateResult { throw 'A preview must never send an air command' }
        $scene = Join-Path $TestDrive 'studio-clock.cintitle'
        '<Scene Fps="50" LoopStartFrame="50" LoopEndFrame="200" Duration="300"><Var Name="title.Text" Type="String" /><Title Text="${title.Text}" /></Scene>' |
            Set-Content -LiteralPath $scene
        @{ StudioClock = @{ path = $scene; layer = 6; bulletin = $true } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-TemplateRegistryFilePath)
        $previousLibrary = $script:MojazLibrary
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'توقيت الاستوديو' -TemplateKey 'StudioClock').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            foreach ($title in 'الأول', 'الثاني') {
                $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -Title $title).Value
            }
            $revision = $script:MojazLibrary.Bulletins[0].Revision
            $request = @{ actor = 4321; id = $id; revision = $revision; action = 'timing'; timing = @{ delayFrames = 125 } }
            $line = @{ op = 'bulletin.edit'; args = $request } | ConvertTo-Json -Compress
            $edited = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $edited.ok | Should -BeTrue
            $edited.data.timing.fps | Should -Be 50
            $edited.data.timing.delayFrames | Should -Be 125
            $edited.data.playbackSupported | Should -BeTrue
            $previewArgs = @{ actor = 4321; id = $id; revision = $edited.data.revision }
            $line = @{ op = 'bulletin.preview'; args = $previewArgs } | ConvertTo-Json -Compress
            $preview = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $preview.ok | Should -BeTrue
            $preview.data.plannedCount | Should -Be 2
            $preview.data.rows[1].startSeconds | Should -Be 3.5
            $preview.data.exitSeconds | Should -Be 5.5
            $request.revision = $edited.data.revision
            $request.timing.delayFrames = 25
            $line = @{ op = 'bulletin.edit'; args = $request } | ConvertTo-Json -Compress
            $shorter = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $shorter.ok | Should -BeTrue
            $previewArgs.revision = $shorter.data.revision
            $line = @{ op = 'bulletin.preview'; args = $previewArgs } | ConvertTo-Json -Compress
            $preview = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $preview.data.rows[1].startSeconds | Should -Be 1.5
            $preview.data.exitSeconds | Should -Be 3.5
            $previewArgs.stamp = $preview.data.stamp
            $previousWrite = [IO.File]::GetLastWriteTimeUtc($scene)
            $original = Get-Content -LiteralPath $scene -Raw
            $original.Replace('Fps="50"', 'Fps="25"') | Set-Content -LiteralPath $scene
            [IO.File]::SetLastWriteTimeUtc($scene, $previousWrite.AddSeconds(2))
            $line = @{ op = 'bulletin.preview'; args = $previewArgs } | ConvertTo-Json -Compress
            (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json).error | Should -Be 'bulletin_stale'
            $original.Replace(' LoopStartFrame="50"', '') | Set-Content -LiteralPath $scene
            [IO.File]::SetLastWriteTimeUtc($scene, $previousWrite.AddSeconds(4))
            $line = @{ op = 'bulletin.edit'; args = @{ actor = 4321; id = $id; action = 'read' } } | ConvertTo-Json -Compress
            $oneShot = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $oneShot.data.timing.fps | Should -Be 50
            $oneShot.data.timing.loopFrames | Should -Be 0
            '<CinegyTitler><Scene><Fps>50</Fps><LoopStartFrame>0</LoopStartFrame><LoopEndFrame>200</LoopEndFrame><Duration>300</Duration></Scene></CinegyTitler>' |
                Set-Content -LiteralPath $scene
            [IO.File]::SetLastWriteTimeUtc($scene, $previousWrite.AddSeconds(6))
            (Get-MojazSceneTiming -Path $scene).LoopFrames | Should -Be 200
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        }
        finally { $script:MojazLibrary = $previousLibrary }
    }

    It 'previews saved bulletin fields without writing to air and uses the shared playback plan' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-MojazAvailable { $true }
        Mock Test-MojazBulletinPlaybackDesign { (Get-MojazBulletinDesignKey -Bulletin $Bulletin) -eq $script:MojazTemplateKey }
        Mock Get-WebBulletinFields {
            @{ name = 'title.Text'; label = 'العنوان'; kind = 'text' }
            @{ name = 'desk'; label = 'المكتب'; kind = 'text' }
            @{ name = $script:MojazImageVariable; label = 'الصورة'; kind = 'media' }
        }
        Mock Get-MojazSceneTiming { $null }
        Mock Invoke-ShowTemplateResult { throw 'A preview must not call air' }
        Mock Save-MojazLibrary { throw 'A preview must not write' }
        $oldLibrary = $script:MojazLibrary
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز المراجعة').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRows -Library $script:MojazLibrary -BulletinId $id -Rows @(
                    @{ Title = 'خبر أول'; Image = 'D:\fixture\photo.png'; Fields = @{ desk = 'المكتب الأول' } },
                    @{ Title = 'خبر مستبعد'; ImageMode = 'template' },
                    @{ Title = 'متن كامل للمراجعة' }
                )).Value
            $bulletin = $script:MojazLibrary.Bulletins[0]
            $script:MojazLibrary = (Switch-MojazBulletinRowSkip -Library $script:MojazLibrary -BulletinId $id -RowId $bulletin.Rows[1].Id).Value
            $bulletin = $script:MojazLibrary.Bulletins[0]
            $request = @{ op = 'bulletin.preview'; args = @{ actor = 4321; id = $id; revision = $bulletin.Revision } }
            $preview = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($request | ConvertTo-Json -Compress) | ConvertFrom-Json
            $preview.ok | Should -BeTrue
            $preview.data.rows[0].values.desk | Should -Be 'المكتب الأول'
            $preview.data.rows[1].skipped | Should -BeTrue
            $preview.data.rows[1].startSeconds | Should -BeNullOrEmpty
            $preview.data.rows[2].startSeconds | Should -BeGreaterThan 0
            $preview.data.rows[2].imageMode | Should -Be 'template'
            $preview.data.plannedCount | Should -Be 2
            ($preview | ConvertTo-Json -Depth 9) | Should -Not -Match 'photo\.png'
            $request.args.stamp = $preview.data.stamp
            (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($request | ConvertTo-Json -Compress) | ConvertFrom-Json).ok | Should -BeTrue
            Mock Get-MojazDelaySeconds { 113 }
            (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($request | ConvertTo-Json -Compress) | ConvertFrom-Json).error | Should -Be 'bulletin_stale'
            $request.args.revision--
            (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($request | ConvertTo-Json -Compress) | ConvertFrom-Json).error | Should -Be 'bulletin_stale'
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            Should -Invoke Save-MojazLibrary -Times 0 -Exactly
        }
        finally { $script:MojazLibrary = $oldLibrary }
    }

    It 'resolves preview pictures through the saved rows and refuses paths outside the selected scene' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-MojazAvailable { $true }
        Mock Test-MojazBulletinPlaybackDesign { $true }
        Mock Get-MojazSceneTiming { $null }
        Mock Get-WebBulletinFields { @{ name = $script:MojazImageVariable; label = 'الصورة'; kind = 'media' } }
        $sceneRoot = Join-Path $TestDrive 'preview-scene'
        New-Item -ItemType Directory -Path $sceneRoot -Force | Out-Null
        Mock Get-TemplateStore { @{ Map = @{ Mojaz = @{ Path = Join-Path $sceneRoot 'test.cintitle' } } } }
        Mock Get-MojazTemplateImage { 'scene.png' }
        $oldLibrary = $script:MojazLibrary
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الصور').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRows -Library $script:MojazLibrary -BulletinId $id -Rows @(
                    @{ Title = 'صورة من الصف'; Image = 'photo.png' },
                    @{ Title = 'صورة موروثة' },
                    @{ Title = 'صورة القالب'; ImageMode = 'template' },
                    @{ Title = 'ملف خارج القالب'; Image = '../private.png' }
                )).Value
            $bulletin = $script:MojazLibrary.Bulletins[0]
            $sendImage = {
                param($imageArgs)
                $line = @{ op = 'bulletin.preview-image'; args = $imageArgs } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $request = @{ actor = 4321; id = $id; revision = $bulletin.Revision; field = $script:MojazImageVariable; rowId = $bulletin.Rows[1].Id }
            $previewLine = @{ op = 'bulletin.preview'; args = $request } | ConvertTo-Json -Compress
            $preview = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $previewLine | ConvertFrom-Json
            $preview.data.rows[1].imageFields | Should -Contain $script:MojazImageVariable
            ($preview | ConvertTo-Json -Depth 8) | Should -Not -Match 'photo\.png|scene\.png|private\.png'
            $request.stamp = $preview.data.stamp
            (& $sendImage $request).data.path | Should -Be (Join-Path $sceneRoot 'photo.png')
            $request.rowId = $bulletin.Rows[2].Id
            (& $sendImage $request).data.path | Should -Be (Join-Path $sceneRoot 'scene.png')
            Mock Get-MojazTemplateImage { '' }
            (& $sendImage $request).error | Should -Be 'bulletin_stale'
            $emptyTemplate = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $previewLine | ConvertFrom-Json
            $request.stamp = $emptyTemplate.data.stamp
            (& $sendImage $request).data.path | Should -Be (Join-Path $sceneRoot 'photo.png')
            $request.rowId = $bulletin.Rows[3].Id
            (& $sendImage $request).error | Should -Be 'not_found'
            $request.actor = 999
            (& $sendImage $request).error | Should -Be 'forbidden'
            $request.actor = 4321
            $request.revision--
            (& $sendImage $request).error | Should -Be 'bulletin_stale'
        }
        finally { $script:MojazLibrary = $oldLibrary }
    }

    It 'shares bulletin appointments with Telegram and refuses revoked scheduled web operators' {
        Mock Test-MojazAvailable { $true }
        Mock Test-MojazBulletinPlaybackDesign { $true }
        Mock Get-MojazTemplate { @{ Layer = 4 } }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-TemplateShowPolicy { @{ Allowed = $true } }
        Mock Test-MojazUrgentOnAir { $false }
        Mock Get-SettingInt { Get-BridgeSettingInt -Config $config -Defaults $script:DefaultSettings -Name $Name -Minimum $Minimum }
        Mock Get-SettingInt { 180 } -ParameterFilter { $Name -eq 'MojazScheduleNoticeSeconds' }
        Mock Send-TelegramMessage {}
        Mock Write-BridgeExecutionRecord {}
        Mock Get-MojazSchedulesFile { Join-Path $TestDrive 'shared-web-bulletin-schedule.json' }
        Mock Invoke-ShowTemplateResult { throw 'The test never calls air' }
        $script:webScheduleAllowed = $true
        Mock Test-Authorized { $UserId -eq 4321 -and $script:webScheduleAllowed }
        $oldLibrary = $script:MojazLibrary
        $oldSchedule = $script:MojazSchedules
        $oldPlayback = $script:MojazPlayback
        $oldSelections = $script:MojazSelections
        try {
            $script:MojazPlayback = $null
            $script:MojazSchedules = @()
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الموعد').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -Title 'الخبر المحفوظ').Value
            $sendSchedule = {
                param($scheduleArgs)
                $line = @{ op = 'bulletin.schedule'; args = $scheduleArgs } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $future = [datetimeoffset]::Now.AddHours(3)
            Add-MojazSchedule -BulletinId $id -ScheduledAt $future.AddMinutes(5) -ChatId 100 -UserId 101 | Should -BeTrue
            $schedule = @{ actor = 4321; id = $id; revision = $script:MojazLibrary.Bulletins[0].Revision; action = 'list' }
            (& $sendSchedule $schedule).data.items.Count | Should -Be 1
            $schedule.action = 'add'
            $schedule.scheduledAtMs = $future.ToUnixTimeMilliseconds()
            $schedule.revision--
            (& $sendSchedule $schedule).error | Should -Be 'bulletin_stale'
            $schedule.revision++
            $schedule.scheduledAtMs = [datetimeoffset]::Now.AddMinutes(-1).ToUnixTimeMilliseconds()
            (& $sendSchedule $schedule).error | Should -Be 'bulletin_schedule_invalid'
            $schedule.scheduledAtMs = $future.ToUnixTimeMilliseconds()
            $created = & $sendSchedule $schedule
            $created.ok | Should -BeTrue
            (& $sendSchedule $schedule).data.items.Count | Should -Be 2
            Import-MojazSchedules
            @(Get-MojazBulletinSchedules -BulletinId $id).Count | Should -Be 2
            $webId = $created.data.items[0].id
            ([datetimeoffset]$script:MojazSchedules[1].ScheduledAt).Offset | Should -Be $future.ToLocalTime().Offset
            $schedule.action = 'cancel'
            $schedule.scheduleId = $created.data.items[1].id
            (& $sendSchedule $schedule).ok | Should -BeTrue
            @(Get-MojazBulletinSchedules -BulletinId $id).Count | Should -Be 1
            $script:webScheduleAllowed = $false
            Update-MojazScheduleQueue -Now $future.AddSeconds(-1)
            $script:MojazPlayback = @{ BulletinId = 'busy'; BulletinName = 'موجز على الهواء' }
            Update-MojazScheduleQueue -Now $future.AddSeconds(1)
            $script:MojazSchedules[0].Id | Should -Be $webId
            $script:MojazSchedules[0].Status | Should -Be 'failed'
            $script:MojazSchedules[0].LastError | Should -Be 'not_authorized'
            Should -Invoke Send-TelegramMessage -Times 0 -Exactly
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly

            $script:MojazPlayback = $null
            $script:webScheduleAllowed = $true
            $script:MojazSelections = @{ '4321' = 'different-bulletin' }
            $schedule.action = 'add'
            $schedule.scheduledAtMs = $future.AddMinutes(10).ToUnixTimeMilliseconds()
            (& $sendSchedule $schedule).ok | Should -BeTrue
            Mock Start-MojazPlayback { $true }
            Update-MojazScheduleQueue -Now $future.AddMinutes(11)
            Should -Invoke Start-MojazPlayback -Times 1 -Exactly -ParameterFilter { $Bulletin.Id -eq $id -and $Force }
            $script:MojazSelections['4321'] | Should -Be 'different-bulletin'
            $running = $script:MojazSchedules | Where-Object Status -EQ 'running'
            $schedule.action = 'cancel'
            $schedule.scheduleId = $running.Id
            (& $sendSchedule $schedule).error | Should -Be 'bulletin_schedule_stale'
        }
        finally {
            $script:MojazLibrary = $oldLibrary
            $script:MojazSchedules = $oldSchedule
            $script:MojazPlayback = $oldPlayback
            $script:MojazSelections = $oldSelections
        }
    }

    It 'reviews manual bulletin playback and stops only the confirmed live run through the pipe' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-MojazAvailable { $true }
        Mock Get-MojazTemplate { @{ Layer = 4 } }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-TemplateShowPolicy { @{ Allowed = $true } }
        Mock Test-MaintenanceControl { $true }
        Mock Send-TelegramMessage {}
        Mock Test-MojazUrgentOnAir { $script:webBulletinUrgent }
        Mock Get-WebBulletinFields { @{ name = 'title.Text'; label = 'العنوان'; kind = 'text' } }
        Mock Get-MojazSceneTiming { $null }
        Mock Get-MojazTemplateImage { '' }
        Mock Get-MojazTickerReview {}
        Mock Get-CinegyLayerStartedAtUtc {}
        Mock Hide-MojazTicker {}
        Mock Request-MojazTickerReturn {}
        Mock Update-MojazPendingUrgent {}
        Mock Save-MojazPlaybackState { $true }
        Mock Clear-MojazPlaybackState {}
        Mock Send-PostboxValues { throw 'The replacement must never receive our bulletin values.' }
        Mock Invoke-ShowTemplateResult {
            $script:webBulletinScene = 'run-item'
            @{ Success = $true; ActiveId = '{run-item}'; ActiveIdConfirmed = $true }
        }
        Mock Get-TitlerLayerStatus {
            @{ Success = $true; IsOnAir = [bool]$script:webBulletinScene; ActiveId = $script:webBulletinScene }
        }
        Mock Exit-TitlerScene { @{ Success = $script:webBulletinExit; Error = 'simulated failure' } }
        $oldLibrary = $script:MojazLibrary
        $oldPlayback = $script:MojazPlayback
        try {
            $script:MojazPlayback = $null
            $script:webBulletinScene = ''
            $script:webBulletinUrgent = $false
            $script:webBulletinExit = $false
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز التشغيل').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -Title 'الخبر المراجع').Value
            $request = @{ actor = 4321; id = $id; revision = $script:MojazLibrary.Bulletins[0].Revision }
            Mock Get-TitlerLayerStatus { @{ Success = $true; IsOnAir = $true; ActiveId = 'another-id'; ActiveName = 'Mojaz' } } -ParameterFilter { $Layer -eq 9 }
            (Get-VerifiedCinegyShowIdentity -Key 'Mojaz' -Layer 9 -ExpectedActiveId 'our-id' -RequireEventIdentity).Success | Should -BeFalse
            (Get-VerifiedCinegyShowIdentity -Key 'Mojaz' -Layer 9 -ExpectedActiveId '{Another-ID}' -RequireEventIdentity).Success | Should -BeTrue
            $callBulletin = {
                param([string]$bulletinAction, [string]$op = 'bulletin.playback')
                $request.action = $bulletinAction
                $line = @{ op = $op; args = $request } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $request.stamp = (& $callBulletin '' 'bulletin.preview').data.stamp
            (& $callBulletin 'status').data.canStart | Should -BeTrue
            (& $callBulletin 'start').error | Should -Be 'bulletin_playback_stale'
            $review = & $callBulletin 'review'
            $review.ok | Should -BeTrue
            $review.data.layer | Should -Be 4
            $review.data.replacing | Should -BeFalse
            $request.review = $review.data.review
            $request.actor = 4322
            (& $callBulletin 'start').error | Should -Be 'bulletin_playback_stale'
            $request.actor = 4323
            (& $callBulletin 'start').error | Should -Be 'forbidden'
            $request.actor = 4321
            $script:webBulletinScene = 'different-item'
            (& $callBulletin 'start').error | Should -Be 'bulletin_playback_stale'
            (& $callBulletin 'start').error | Should -Be 'bulletin_playback_stale'
            $review = & $callBulletin 'review'
            $review.data.replacing | Should -BeTrue
            $request.review = $review.data.review
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -Title 'تعديل بعد المراجعة').Value
            (& $callBulletin 'start').error | Should -Be 'bulletin_stale'
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            $request.revision++
            $request.Remove('stamp')
            $request.stamp = (& $callBulletin '' 'bulletin.preview').data.stamp
            $script:webBulletinUrgent = $true
            (& $callBulletin 'review').error | Should -Be 'bulletin_urgent_active'
            $script:webBulletinUrgent = $false
            $request.review = (& $callBulletin 'review').data.review
            $running = (& $callBulletin 'start').data.run
            $running.id | Should -Match '^mojaz-'
            $running.rowCount | Should -Be 2
            Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
                $ExpectedLayerStamp -eq 'active:different-item' -and $ExpectedLayer -eq 4 -and $RequireEventIdentity
            }
            $request.runId = 'older-run'
            (& $callBulletin 'stop').error | Should -Be 'bulletin_playback_stale'
            $request.runId = $running.id
            $script:webBulletinScene = 'replacement'
            (& $callBulletin 'stop').error | Should -Be 'bulletin_playback_stale'
            Should -Invoke Exit-TitlerScene -Times 0 -Exactly
            # The preflight is not the write guard. Cinegy can change even
            # after the preflight, before Invoke-ExitLayer reads it again.
            $script:webBulletinScene = 'replacement'
            $script:webBulletinStatusReads = 0
            Mock Get-TitlerLayerStatus {
                $script:webBulletinStatusReads++
                $scene = if ($script:webBulletinStatusReads -eq 1) { 'run-item' } else { $script:webBulletinScene }
                @{ Success = $true; IsOnAir = $true; ActiveId = $scene }
            }
            (& $callBulletin 'stop').error | Should -Be 'bulletin_stop_unconfirmed'
            Should -Invoke Exit-TitlerScene -Times 0 -Exactly
            $script:webBulletinScene = 'run-item'
            (& $callBulletin 'stop').error | Should -Be 'bulletin_stop_unconfirmed'
            (& $callBulletin 'status').data.run.state | Should -Be 'stop_unconfirmed'
            $script:webBulletinExit = $true
            $stopped = & $callBulletin 'stop'
            $stopped.ok | Should -BeTrue
            $stopped.data.run | Should -BeNullOrEmpty
            Should -Invoke Exit-TitlerScene -Times 2 -Exactly

            $request.review = (& $callBulletin 'review').data.review
            (& $callBulletin 'start').data.run.state | Should -Be 'playing'
            $script:webBulletinScene = 'new-template-instance'
            $script:MojazPlayback.ClockOffset = 1000
            Update-MojazPlayback
            $script:MojazPlayback | Should -BeNullOrEmpty
            Should -Invoke Send-PostboxValues -Times 0 -Exactly
            Should -Invoke Exit-TitlerScene -Times 2 -Exactly

            $request.review = (& $callBulletin 'review').data.review
            (& $callBulletin 'start').data.run.state | Should -Be 'playing'
            $script:webBulletinScene = 'replacement-onto-outro'
            $script:MojazPlayback.Index = 1
            $script:MojazPlayback.ClockOffset = 1000
            Update-MojazPlayback
            $script:MojazPlayback | Should -BeNullOrEmpty
            Should -Invoke Exit-TitlerScene -Times 2 -Exactly
        }
        finally {
            $script:MojazLibrary = $oldLibrary
            $script:MojazPlayback = $oldPlayback
        }
    }

    It 'plays and schedules the actual alternate bulletin design and restores its frozen fields' {
        Mock Test-Authorized { $UserId -eq 4321 -and $script:alternateWebAuthorized }
        Mock Get-Setting { Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name }
        Mock Get-Setting { $script:alternateWebEnabled } -ParameterFilter { $Name -eq 'MojazMultiDesign' }
        Mock Test-MojazAvailable { $true }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-TemplateShowPolicy { @{ Allowed = $true } }
        Mock Test-MaintenanceControl { $true }
        Mock Get-MojazTickerReview {}
        Mock Get-CinegyLayerStartedAtUtc {}
        Mock Get-MojazPlaybackFile { Join-Path $TestDrive 'alternate-web-run.json' }
        Mock Get-MojazSchedulesFile { Join-Path $TestDrive 'alternate-web-schedules.json' }
        Mock Get-TemplateRegistryFilePath { Join-Path $TestDrive 'alternate-web-templates.json' }
        Mock Send-TelegramMessage {}
        Mock Send-AdminBroadcast {}
        Mock Write-BridgeExecutionRecord {}
        Mock Test-MojazUrgentOnAir { $script:alternateWebUrgent }
        Mock Get-TitlerLayerStatus {
            @{ Success = $true; IsOnAir = [bool]$script:alternateWebScene; ActiveId = $script:alternateWebScene }
        }
        Mock Get-TitlerLayerStatus {
            @{ Success = $true; IsOnAir = $script:alternateWebOverlap; ActiveId = 'another-graphic' }
        } -ParameterFilter { $Layer -eq 7 }
        Mock Get-TitlerLayerStatus {
            @{ Success = $true; IsOnAir = $true; ActiveId = $script:alternateWebIndependent }
        } -ParameterFilter { $Layer -eq 8 }
        Mock Invoke-ShowTemplateResult {
            $script:alternateWebScene = 'studio-web-item'
            @{ Success = $true; ActiveId = $script:alternateWebScene; ActiveIdConfirmed = $true }
        }
        Mock Send-PostboxValues { @{ Success = $true; Xml = '' } }
        Mock Invoke-ExitLayer { $script:alternateWebScene = ''; $true }
        $path = Join-Path $TestDrive 'alternate-web-scene.cintitle'
        $picture = Join-Path $TestDrive 'studio.jpg'
        $independentPath = Join-Path $TestDrive 'station-label.cintitle'
        '<Scene><Var Name="station.label" Type="String" /><Title Text="${station.label}" /></Scene>' | Set-Content -LiteralPath $independentPath
        '<Scene Fps="50" Duration="300" LoopStartFrame="50" LoopEndFrame="200"><Var Name="studio.place" Type="String" /><Title Text="${studio.place}" /><Var Name="studio.picture" Type="File" /><Plate File="${studio.picture}" /></Scene>' |
            Set-Content -LiteralPath $path
        @{
            StudioBulletin = @{ path = $path; layer = 6; bulletin = $true }
            Other = @{ path = $path; layer = 7 }
            StationLabel = @{ path = $independentPath; layer = 8 }
        } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-TemplateRegistryFilePath)
        $oldLibrary = $script:MojazLibrary
        $oldPlayback = $script:MojazPlayback
        $oldSchedules = $script:MojazSchedules
        $oldOnAir = $script:OnAir
        $oldShows = $script:LastSuccessfulLayerShows
        try {
            $script:MojazPlayback = $null
            $script:MojazSchedules = @()
            $script:alternateWebScene = ''
            $script:alternateWebUrgent = $false
            $script:alternateWebOverlap = $true
            $script:alternateWebEnabled = $true
            $script:alternateWebAuthorized = $true
            $script:OnAir = @{}
            $script:alternateWebIndependent = 'station-label'
            $script:LastSuccessfulLayerShows = @{
                8 = @{ Key = 'StationLabel'; ActiveId = 'station-label'; ActiveIdConfirmed = $true; TemplatePath = $independentPath
                    SceneWriteTicks = [IO.File]::GetLastWriteTimeUtc($independentPath).Ticks }
            }
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الاستوديو' -TemplateKey 'StudioBulletin').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id `
                    -Fields @{ 'studio.place' = 'غزة'; 'studio.picture' = $picture }).Value
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id `
                    -Fields @{ 'studio.place' = 'القدس' }).Value
            $request = @{ actor = 4321; id = $id; revision = $script:MojazLibrary.Bulletins[0].Revision }
            $call = {
                param([string]$op, [string]$action)
                $request.action = $action
                $line = @{ op = "bulletin.$op"; args = $request } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $request.stamp = (& $call 'preview' '').data.stamp
            (& $call 'playback' 'review').error | Should -Be 'bulletin_fields_busy'
            $script:alternateWebOverlap = $false
            $script:alternateWebIndependent = 'unknown-replacement'
            (& $call 'playback' 'review').error | Should -Be 'bulletin_fields_busy'
            $script:alternateWebIndependent = 'station-label'
            $newWrite = [IO.File]::GetLastWriteTimeUtc($independentPath).AddSeconds(2)
            [IO.File]::SetLastWriteTimeUtc($independentPath, $newWrite)
            (& $call 'playback' 'review').error | Should -Be 'bulletin_fields_busy'
            $script:LastSuccessfulLayerShows[8].SceneWriteTicks = $newWrite.Ticks
            $script:alternateWebEnabled = $false
            (& $call 'playback' 'review').error | Should -Be 'bulletin_playback_unavailable'
            $script:alternateWebEnabled = $true
            $review = & $call 'playback' 'review'
            $review.ok | Should -BeTrue
            $review.data.layer | Should -Be 6
            $request.review = $review.data.review
            $started = & $call 'playback' 'start'
            $started.ok | Should -BeTrue
            Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
                $Key -eq 'StudioBulletin' -and $ExpectedLayer -eq 6 -and $RequireEventIdentity -and $SkipPostboxWrites -and
                $Variables.Count -eq 2 -and $Variables['studio.place'] -eq 'غزة' -and
                $VariableTypes['studio.picture'] -eq 'File' -and $Variables['studio.picture'] -eq $picture
            }
            $secondId = $script:MojazLibrary.Bulletins[0].Rows[1].Id
            $script:MojazLibrary = (Set-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -RowId $secondId `
                    -DesignFields @{ 'studio.place' = 'رام الله' }).Value
            $restartTime = [datetime]$script:MojazPlayback.StartedAt
            $script:MojazPlayback = $null
            Restore-MojazPlayback -Now $restartTime | Should -BeTrue
            Should -Invoke Send-PostboxValues -Times 1 -Exactly -ParameterFilter {
                $Values['studio.place'] -eq 'غزة' -and $Types['studio.picture'] -eq 'File'
            }
            $script:MojazPlayback.ClockOffset = 1000
            Update-MojazPlayback
            Should -Invoke Send-PostboxValues -Times 1 -Exactly -ParameterFilter { $Values['studio.place'] -eq 'القدس' }
            $request.runId = $started.data.run.id
            (& $call 'playback' 'stop').ok | Should -BeTrue
            Should -Invoke Invoke-ExitLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 6 -and $ExpectedLayerStamp -eq 'active:studio-web-item' }
            $when = [datetimeoffset]::Now.AddHours(1)
            $request.revision = $script:MojazLibrary.Bulletins[0].Revision
            $request.scheduledAtMs = $when.ToUnixTimeMilliseconds()
            (& $call 'schedule' 'add').ok | Should -BeTrue
            $request.scheduledAtMs = $when.AddMinutes(1).ToUnixTimeMilliseconds()
            (& $call 'schedule' 'add').ok | Should -BeTrue
            Add-MojazSchedule -BulletinId $id -ScheduledAt $when.AddMinutes(3) -ChatId 4321 -UserId 4321 | Should -BeTrue
            $script:alternateWebUrgent = $true
            Update-MojazScheduleQueue -Now $when.AddSeconds(1)
            $script:MojazSchedules[0].Status | Should -Be 'queued'
            $script:alternateWebUrgent = $false
            Update-MojazScheduleQueue -Now $when.AddSeconds(2)
            $script:MojazSchedules[0].Status | Should -Be 'running'
            Should -Invoke Invoke-ShowTemplateResult -Times 2 -Exactly -ParameterFilter {
                $Key -eq 'StudioBulletin' -and $ExpectedLayer -eq 6 -and $ExpectedLayerStamp -eq 'empty'
            }
            $script:alternateWebOverlap = $true
            $script:MojazPlayback.ClockOffset = 1000
            Update-MojazPlayback
            (& $call 'playback' 'status').data.run.state | Should -Be 'fields_blocked'
            Should -Invoke Send-PostboxValues -Times 2 -Exactly
            $script:alternateWebOverlap = $false
            Stop-MojazPlayback -Quiet | Should -BeTrue
            $registry = Get-TemplateRegistryFilePath
            $timestamp = [IO.File]::GetLastWriteTimeUtc($registry)
            @{ StudioBulletin = @{ path = $path; layer = 9; bulletin = $true } } |
                ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $registry
            [IO.File]::SetLastWriteTimeUtc($registry, $timestamp.AddSeconds(2))
            Update-MojazScheduleQueue -Now $when.AddMinutes(2)
            $script:MojazSchedules[1].Status | Should -Be 'failed'
            $script:MojazSchedules[1].LastError | Should -Be 'playback_target_changed'
            $script:alternateWebAuthorized = $false
            Update-MojazScheduleQueue -Now $when.AddMinutes(4)
            $script:MojazSchedules[2].Status | Should -Be 'failed'
            $script:MojazSchedules[2].LastError | Should -Be 'not_authorized'
            Should -Invoke Invoke-ShowTemplateResult -Times 2 -Exactly
        }
        finally {
            $script:MojazLibrary = $oldLibrary
            $script:MojazPlayback = $oldPlayback
            $script:MojazSchedules = $oldSchedules
            $script:OnAir = $oldOnAir
            $script:LastSuccessfulLayerShows = $oldShows
        }
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

            $timing = @{
                op = 'urgent.write'
                args = @{ actor = 4321; action = 'timing'; revision = $script:UrgentBoard.Revision; id = $row.Id
                    timing = @{ intervalSeconds = 17; repeats = 2; mode = 'exit' } }
            }
            $wire = $timing | ConvertTo-Json -Depth 6 -Compress
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $wire) | ConvertFrom-Json).ok | Should -BeTrue
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $wire) | ConvertFrom-Json).error | Should -Be 'urgent_stale'
            $custom = $script:UrgentBoard.Items[0]
            $custom.IntervalSeconds | Should -Be 17
            $custom.Repeats | Should -Be 2
            $custom.Mode | Should -Be 'exit'
            (Get-UrgentItemVariables -Item $custom)['location[1]'] | Should -Be 'الاستوديو'
            $customPlan = New-UrgentRunPlan -Items @($custom) -Defaults (New-UrgentDefaults)
            $customPlan.Value.Steps[0].HoldSeconds | Should -Be 17
            $customPlan.Value.StepCount | Should -Be 2
            $timing.args.revision = $script:UrgentBoard.Revision
            $timing.args.timing.intervalSeconds = 18
            $timing.args.timing.repeats = 100
            $wire = $timing | ConvertTo-Json -Depth 6 -Compress
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $wire) | ConvertFrom-Json).error | Should -Be 'refused'
            $script:UrgentBoard.Revision | Should -Be $timing.args.revision
            $script:UrgentBoard.Items[0].IntervalSeconds | Should -Be 17

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
            $list.data.items[0].timing.intervalSeconds | Should -Be 17
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
            $timing.args.revision = $script:UrgentBoard.Revision
            $timing.args.timing = @{ intervalSeconds = 0; repeats = 0; mode = '' }
            $wire = $timing | ConvertTo-Json -Depth 6 -Compress
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $wire) | ConvertFrom-Json).ok | Should -BeTrue
            $script:UrgentBoard.Items[0].IntervalSeconds | Should -Be 0
            $script:UrgentBoard.Items[0].Repeats | Should -Be 0
            $script:UrgentBoard.Items[0].Mode | Should -Be ''

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
