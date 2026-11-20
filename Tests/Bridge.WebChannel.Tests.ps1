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

            { Get-TelegramUpdates -Offset 0 -TimeoutSeconds 1 } | Should -Throw

            $handle.IsCompleted | Should -BeTrue
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
        Mock Test-Authorized { $UserId -in @(4321, 4322) }
        Mock Test-Admin { $false }
        Mock Send-TelegramMessage {}
        Mock Save-NewsSheetItems { @{ Success = $false; Attempted = $false; Error = '' } }
        Mock Send-NewsPublishNotice {}
        Mock Write-NewsPublishRecord {}
        $previousDraft = $script:NewsTickerDraft
        $previousFile = $script:newsDraftFile
        $previousBackup = $script:newsBackupDirectory
        $requestTicker = {
            param($arguments)
            $line = @{ op = 'ticker.edit'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $script:NewsTickerDraft = $null
            $script:newsDraftFile = Join-Path $TestDrive 'web-edit-draft.json'
            $script:newsBackupDirectory = Join-Path $TestDrive 'web-edit-backups'

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

            $released = & $requestTicker @{ actor = 4321; action = 'handover'; revision = $moved.data.draft.revision }
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
