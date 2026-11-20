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
        $storeMock = @{
            Map = @{
                'test_lower' = [ordered]@{
                    description = 'Lower Third Template'
                    layer = 5
                    category = 'news'
                    fields = @(
                        [ordered]@{ name = 'f1'; label = 'Headline'; required = $true }
                    )
                }
            }
        }
        Mock Get-TemplateStore { $storeMock }
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

        # 2. air.show
        $showReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.show","args":{"actor":4321,"key":"test_lower","variables":{"f1":"Breaking"}}}') | ConvertFrom-Json
        $showReply.ok | Should -BeTrue
        Should -Invoke Invoke-ShowTemplateResult -Times 1

        # 3. air.hide
        $hideReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.hide","args":{"actor":4321,"layer":5}}') | ConvertFrom-Json
        $hideReply.ok | Should -BeTrue
        Should -Invoke Invoke-HideLayer -Times 1

        # 4. air.exit
        $exitReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.exit","args":{"actor":4321,"layer":5}}') | ConvertFrom-Json
        $exitReply.ok | Should -BeTrue
        Should -Invoke Invoke-ExitLayer -Times 1
    }
}
