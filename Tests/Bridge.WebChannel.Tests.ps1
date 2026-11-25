#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Browser air events' {
    It 'shares only registered non-sensitive text from the same template and layer' {
        $template = @{ Key='text-sync'; Path='test.scene'; Layer=5; FieldTypes=@{ title='Text'; photo='Image'; hidden='String' } }
        $script:LastWebTemplateText['text-sync'] = @{ Path='test.scene'; Layer=5; Values=@{ title='نص من البوت'; hidden='private'; photo='local'; other='unregistered' } }
        $fields = @(@{ name='title'; sensitive=$false }, @{ name='photo'; sensitive=$false }, @{ name='hidden'; sensitive=$true })
        try {
            $values = Get-WebLastTemplateText -Template $template -Fields $fields
            $values.Count | Should -Be 1
            $values.title | Should -Be 'نص من البوت'
            $template.Layer = 6
            (Get-WebLastTemplateText -Template $template -Fields $fields).Count | Should -Be 0
        } finally { $script:LastWebTemplateText.Remove('text-sync') }
    }
    It 'retains successive operations and filters by current audience, mute and access' {
        $previousChannel = $script:WebChannel
        $script:WebChannel = @{}
        try {
            Mock Get-TemplateNotifyScope { 'all' }
            Mock Test-AirNoticeMuted { $UserId -eq 32 }
            Mock Test-Admin { $false }
            Mock Test-TemplateAccess { @{ Allowed = ($UserId -ne 33) } }
            Add-WebAirEvent -Id 'from-web' -Action SHOW -Key Urgent -Layer 7
            Add-WebAirEvent -Id 'from-bot' -Action HIDE -Key Urgent -Layer 7
            (Get-WebPersonalAirNotice -Actor 31).events.id | Should -Be @('from-web','from-bot')
            (Get-WebPersonalAirNotice -Actor 32).events.Count | Should -Be 0
            (Get-WebPersonalAirNotice -Actor 33).events.Count | Should -Be 0
            Mock Get-TemplateNotifyScope { 'admins' }
            (Get-WebPersonalAirNotice -Actor 31).events.Count | Should -Be 0
        } finally { $script:WebAirEvents.Clear(); $script:WebChannel = $previousChannel }
    }
}

Describe 'Web layer removal compatibility' {
    It 'requires a reviewed request on the legacy HIDE and EXIT operations when the station enables confirmation' {
        Mock Test-Authorized { $true }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        Mock Invoke-HideLayer { $true }
        Mock Invoke-ExitLayer { $true }
        Mock Publish-WebChannelState {}

        (Invoke-WebAirHide @{ actor = 4321; layer = 9 }).error | Should -Be 'layer_review_required'
        (Invoke-WebAirExit @{ actor = 4321; layer = 9 }).error | Should -Be 'layer_review_required'
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
    }

    It 'keeps legacy HIDE and EXIT available when station confirmation is disabled' {
        Mock Test-Authorized { $true }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        Mock Invoke-HideLayer { $true }
        Mock Invoke-ExitLayer { $true }
        Mock Publish-WebChannelState {}

        (Invoke-WebAirHide @{ actor = 4321; layer = 9 }).ok | Should -BeTrue
        (Invoke-WebAirExit @{ actor = 4321; layer = 9 }).ok | Should -BeTrue
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Quiet -and $CaptureRollback -and $Layer -eq 9 }
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 9 }
    }
}

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

    It 'publishes help for the current actor without passing through Bot source text' {
        Mock Test-Authorized { $UserId -in 7110, 7111, 7112 }
        Mock Test-Admin { $UserId -in 7111, 7112 }
        Mock Test-Owner { $UserId -eq 7112 }
        Mock Get-HelpChapters {
            @{ Key = 'show'; AdminOnly = $false; Body = @('<script>private-bot-body</script>') }
            @{ Key = 'settings'; AdminOnly = $true; Body = @('config.json') }
            @{ Key = 'access'; AdminOnly = $true }
        }
        Mock Get-WhatsNewSections {
            foreach ($version in '9.1.11', '9.1.4', '9.1.3', '9.1.1', '9.1.0', '9.0.0', '8.129.0') {
                @{ Version = $version; Items = @('private-bot-release') }
            }
        }
        $operator = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"help.operator","args":{"actor":7110,"role":"owner"}}' | ConvertFrom-Json
        $operator.ok | Should -BeTrue
        $operator.data.chapters.id | Should -Be @('templates')
        $operator.data.releases.version | Should -Be @('9.1.11', '9.1.4', '9.1.3', '9.1.1', '9.1.0')
        $operator.data.releases[0].Items | Should -HaveCount 2
        $operator.data.releases[0].Items[0] | Should -Match 'تشغيل المحدد'
        $operator.data.releases[0].Items[1] | Should -Match 'أعلى إدارة العواجل'

        Mock Get-WhatsNewSections {
            @{ Version = '9.1.4'; Items = @('private-bot-release') }
            @{ Version = '8.129.0'; Items = @('private-bot-release') }
        }

        $admin = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"help.operator","args":{"actor":7111}}' | ConvertFrom-Json
        $admin.data.chapters.id | Should -Be @('templates', 'system', 'access')
        $admin.data.releases[-1].Items.Count | Should -Be 2

        $raw = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"help.operator","args":{"actor":7112}}'
        ($raw | ConvertFrom-Json).data.chapters.id | Should -Be @('templates', 'system', 'access', 'roles')
        $raw | Should -Not -Match 'private-bot-body|private-bot-release|config\.json'
        $denied = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"help.operator","args":{"actor":7113}}' | ConvertFrom-Json
        $denied.error | Should -Be 'forbidden'
    }

    It 'publishes only current administrators a typed in-memory operating snapshot' {
        Mock Test-Authorized { $UserId -in 7130, 7131 }
        Mock Test-Admin { $UserId -eq 7131 }
        Mock Get-BridgeOperationMetrics {
            @{
                Now = [datetime]'2024-08-10T10:00:00'; StartedAt = [datetime]'2024-08-10T09:30:00'
                Uptime = [timespan]::FromMinutes(30); State = 'telegram-limiting'
                AirOperations = @{ Success = 12; Failed = 2; Blocked = 1; Name = 'editorial-private' }
                TelegramRateLimitHits = 2; TelegramOutboxDropped = 3
                LastHeartbeatDate = [datetime]'2024-08-09'; OnAirCount = 2
                RichPayloadPeak = @{ Length = 9000; Percent = 75; Screen = 'private-screen-title' }
            }
        }
        $operator = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.operation-metrics","args":{"actor":7130,"role":"admin"}}' | ConvertFrom-Json
        $operator.error | Should -Be 'forbidden'
        $monitoring = $script:RuntimeState.Monitoring
        $healthBefore = $monitoring.CinegyHealthState
        try {
            $monitoring.CinegyHealthState = 'unreachable'
            $raw = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.operation-metrics","args":{"actor":7131}}'
        } finally {
            $monitoring.CinegyHealthState = $healthBefore
        }
        $response = $raw | ConvertFrom-Json
        $response.ok | Should -BeTrue
        $response.data.uptimeSeconds | Should -Be 1800
        $response.data.airOperations.success | Should -Be 12
        $response.data.telegramRateLimitHits | Should -Be 2
        $response.data.telegramOutboxDropped | Should -Be 3
        $response.data.cinegyState | Should -Be 'unreachable'
        $response.data.richPayloadPeakPercent | Should -Be 75
        $response.data.lastHeartbeatDate | Should -Be '2024-08-09'
        $raw | Should -Not -Match 'private-screen-title|editorial-private'
    }

    It 'records a report-bound handover once across the real Web pipe and native Telegram callback' {
        $priorFile = $script:auditFile
        $priorTrail = $script:AuditTrail
        $script:auditFile = Join-Path $TestDrive 'handover-ack-fixture.jsonl'
        $script:AuditTrail = [System.Collections.Generic.List[string]]::new()
        $script:handoverFixtureKeyboard = $null
        $script:handoverFixtureText = ''
        Mock Test-Authorized { $UserId -in 7031, 7032 }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserNameFromTelegram {}
        Mock Send-TelegramMessage {}
        Mock Get-AirMaterialNowNext { '' }
        Mock Get-UpcomingScheduleEvents { @() }
        Mock Send-TelegramPagedText {
            $script:handoverFixtureKeyboard = $ReplyMarkup
            $script:handoverFixtureText = $Text
        }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 6 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        $press = {
            param([long]$Actor, [string]$Data)
            Invoke-CallbackQuery -CallbackQuery ([pscustomobject]@{
                    id = "fixture-$Actor"
                    data = $Data
                    from = [pscustomobject]@{ id = $Actor; first_name = 'Private fixture name' }
                    message = [pscustomobject]@{ message_id = 5; chat = [pscustomobject]@{ id = $Actor; type = 'private' } }
                })
        }
        $ack = 'reports.handover.acknowledge'
        try {
            Show-ShiftHandoverScreen -ChatId 7031 -UserId 7031
            $button = $script:handoverFixtureKeyboard.inline_keyboard[0][0].callback_data
            $button | Should -Match '^handover:done:'
            [Text.Encoding]::UTF8.GetByteCount($button) | Should -BeLessOrEqual 64
            $nativeReference = $button.Substring('handover:done:'.Length)
            (& $call $ack @{ actor = 7032; reference = $nativeReference }).error | Should -Be 'handover_stale'
            (& $call $ack @{ actor = 7999; reference = $nativeReference }).error | Should -Be 'forbidden'
            $received = & $call $ack @{ actor = 7031; reference = $nativeReference; userId = 7032 }
            $received.ok | Should -BeTrue
            $received.data.recordedAt | Should -Not -BeNullOrEmpty
            (& $call $ack @{ actor = 7031; reference = $nativeReference }).data.recordedAt | Should -BeExactly $received.data.recordedAt
            Show-ShiftHandoverScreen -ChatId 7031 -UserId 7031
            $script:handoverFixtureText | Should -Match ([regex]::Escape($received.data.recordedAt))
            & $press 7031 $button
            & $press 7031 'handover:done'
            $stored = @(Read-AuditRecords -RequireCompleteRead)
            $stored.Count | Should -Be 1
            $stored[0].event | Should -BeExactly 'handover_ack'
            $stored[0].userId | Should -Be 7031

            $web = & $call 'reports.handover' @{ actor = 7032 }
            $web.data.acknowledgement.reference | Should -Not -BeNullOrEmpty
            & $press 7032 "handover:done:$($web.data.acknowledgement.reference)"
            $same = & $call $ack @{ actor = 7032; reference = $web.data.acknowledgement.reference }
            $same.ok | Should -BeTrue
            $readBack = & $call 'reports.handover' @{ actor = 7032 }
            $readBack.data.acknowledgement.recent.key | Should -BeExactly $same.data.key
            ($readBack.data.acknowledgement | ConvertTo-Json -Depth 6) | Should -Not -Match 'Private fixture name|userId|chatId'
            @(Read-AuditRecords -RequireCompleteRead).Count | Should -Be 2

            $stale = (Get-ShiftHandoverView -Actor 7031 -Now ([datetimeoffset]::UtcNow.AddMinutes(-11))).public.reference
            (& $call $ack @{ actor = 7031; reference = $stale }).error | Should -Be 'handover_stale'
            Add-Content -LiteralPath $script:auditFile -Value 'null' -Encoding utf8
            (& $call $ack @{ actor = 7031; reference = $nativeReference }).error | Should -Be 'handover_unavailable'
            Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableShiftHandover' }
            (& $call $ack @{ actor = 7031; reference = $nativeReference }).error | Should -Be 'handover_disabled'
            @(Read-AuditRecords | Where-Object { $_ }).Count | Should -Be 2
        }
        finally {
            $script:auditFile = $priorFile
            $script:AuditTrail = $priorTrail
        }
    }

    It 'reviews backup restore and default reset over the private pipe without exposing or replacing the rest of config' {
        Mock Test-Authorized { $UserId -in 7710, 7711, 7712 }
        Mock Test-Admin { $UserId -in 7711, 7712 }
        Mock Test-UrgentBoardTimingBusy { $script:webRecoveryTimingBusy }
        Mock Add-AuditEntry {}
        Mock Protect-BridgePathAcl {}
        Mock Protect-BridgeConfigurationAcl {}
        Mock Restore-ConfigBackup { throw 'The Web path must not invoke full restore.' }
        Mock Reset-SettingsToDefault { throw 'The Web path must not clear all settings.' }

        $previousPath = $script:ConfigPath
        $previousSettings = Get-JsonProp $config 'Settings'
        $previousSaveFailed = $script:LastConfigSaveFailed
        $previousConflict = Get-Variable LastConfigSaveConflict -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $script:ConfigPath = Join-Path $TestDrive 'web-recovery.config.fixture.json'
        $script:webRecoveryTimingBusy = $false
        $roomDefault = [bool]$script:DefaultSettings['OneHandMode']
        $oldRoom = -not $roomDefault
        $defaultInterval = [int]$script:DefaultSettings['UrgentBoardIntervalSeconds']
        $oldInterval = $defaultInterval + 1
        $active = @{
            BotToken = 'CURRENT_SECRET_01'; AirServerAddress = 'station-current.invalid'; AllowedUserIds = @(7711, 7712)
            Settings = @{ OneHandMode = $oldRoom; UrgentBoardIntervalSeconds = $defaultInterval; JoinSecret = 'CURRENT_JOIN_SECRET' }
        }
        Set-JsonProp -Object $config -Name 'Settings' -Value ([pscustomobject]$active.Settings)
        $activeText = ConvertTo-Json -InputObject $active -Depth 8 -Compress
        [IO.File]::WriteAllText($script:ConfigPath, $activeText)
        $backupRoot = New-Item -ItemType Directory -Path "$script:ConfigPath.backups"
        $backupName = 'config-20261121-123456-000-a1234567.json'
        $backupPath = Join-Path $backupRoot.FullName $backupName
        $archive = @{
            BotToken = 'BACKUP_SECRET_01'; AirServerAddress = 'station-archive.invalid'; AllowedUserIds = @(99)
            Settings = @{ OneHandMode = $roomDefault; UrgentBoardIntervalSeconds = $oldInterval; JoinSecret = 'BACKUP_JOIN_SECRET' }
        }
        $archiveText = ConvertTo-Json -InputObject $archive -Depth 8 -Compress
        [IO.File]::WriteAllText($backupPath, $archiveText)
        [IO.File]::WriteAllText((Join-Path $backupRoot.FullName 'not-bridge-owned.json'), $archiveText)

        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 6 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        $listOp = 'admin.settings.recovery.backups'
        $reviewOp = 'admin.settings.recovery.review'
        $confirmOp = 'admin.settings.recovery.confirm'
        $reviewRequest = @{ actor = 7711; source = 'backup'; backup = '' }
        $confirmRequest = @{ actor = 7711; review = '' }
        try {
            (& $call $listOp @{ actor = 7710 }).error | Should -Be 'forbidden'
            (& $call $reviewOp @{ actor = 7710; source = 'defaults' }).error | Should -Be 'forbidden'
            $list = & $call $listOp @{ actor = 7711 }
            $list.ok | Should -BeTrue
            @($list.data.items).Count | Should -Be 1
            $list.data.items[0].kind | Should -Be 'automatic'
            $reviewRequest.backup = $list.data.items[0].id
            $reviewRequest.backup | Should -Match '^[0-9a-f]{64}$'
            ($list | ConvertTo-Json -Depth 6) | Should -Not -Match 'SECRET|station-|\.json|config-20261121'
            (& $call $reviewOp @{ actor = 7711; source = 'backup'; backup = $backupPath }).error | Should -Be 'setting_invalid'
            (& $call $reviewOp @{ actor = 7712; source = 'backup'; backup = $reviewRequest.backup }).error | Should -Be 'setting_stale'

            $draft = & $call $reviewOp $reviewRequest
            $draft.ok | Should -BeTrue
            @($draft.data.changes).Count | Should -Be 2
            ($draft | ConvertTo-Json -Depth 7) | Should -Not -Match 'SECRET|station-|\.json|AllowedUserIds'
            $confirmRequest.review = $draft.data.review
            (& $call $confirmOp @{ actor = 7712; review = $confirmRequest.review }).error | Should -Be 'setting_stale'
            $fileTime = [IO.File]::GetLastWriteTimeUtc($backupPath)
            [IO.File]::WriteAllText($backupPath, $archiveText.Replace('BACKUP_SECRET_01', 'BACKUP_SECRET_02'))
            [IO.File]::SetLastWriteTimeUtc($backupPath, $fileTime)
            (& $call $confirmOp $confirmRequest).error | Should -Be 'setting_stale'
            [IO.File]::ReadAllText($script:ConfigPath) | Should -BeExactly $activeText
            (Get-Setting 'OneHandMode') | Should -Be $oldRoom

            $draft = & $call $reviewOp $reviewRequest
            $draft.ok | Should -BeTrue
            $confirmRequest.review = $draft.data.review
            [IO.File]::WriteAllText($script:ConfigPath, $activeText.Replace('CURRENT_SECRET_01', 'CURRENT_SECRET_02'))
            (& $call $confirmOp $confirmRequest).error | Should -Be 'setting_stale'
            (Get-Setting 'OneHandMode') | Should -Be $oldRoom
            ([IO.File]::ReadAllText($script:ConfigPath) | ConvertFrom-Json).BotToken | Should -BeExactly 'CURRENT_SECRET_02'

            $draft = & $call $reviewOp $reviewRequest
            $confirmRequest.review = $draft.data.review
            $script:webRecoveryTimingBusy = $true
            (& $call $confirmOp $confirmRequest).error | Should -Be 'urgent_timing_active'
            (& $call $reviewOp $reviewRequest).error | Should -Be 'urgent_timing_active'
            (Get-Setting 'UrgentBoardIntervalSeconds') | Should -Be $defaultInterval
            $script:webRecoveryTimingBusy = $false
            $draft = & $call $reviewOp $reviewRequest
            $confirmRequest.review = $draft.data.review
            (& $call $confirmOp $confirmRequest).data.applied | Should -Be 2
            (& $call $confirmOp $confirmRequest).error | Should -Be 'setting_stale'
            (Get-Setting 'OneHandMode') | Should -Be $roomDefault
            (Get-Setting 'UrgentBoardIntervalSeconds') | Should -Be $oldInterval
            $afterRestore = [IO.File]::ReadAllText($script:ConfigPath) | ConvertFrom-Json
            $afterRestore.BotToken | Should -BeExactly 'CURRENT_SECRET_02'
            $afterRestore.AirServerAddress | Should -BeExactly 'station-current.invalid'
            $afterRestore.Settings.JoinSecret | Should -BeExactly 'CURRENT_JOIN_SECRET'
            $afterRestore.AllowedUserIds | Should -Be @(7711, 7712)

            $previous = (& $call $listOp @{ actor = 7711 }).data.items | Where-Object kind -eq 'previous'
            $previous.id | Should -Not -BeNullOrEmpty
            $previousReview = & $call $reviewOp @{ actor = 7711; source = 'backup'; backup = $previous.id }
            @($previousReview.data.changes).Count | Should -Be 2
            $reset = & $call $reviewOp @{ actor = 7711; source = 'defaults' }
            $reset.data.changes.id | Should -Be @('UrgentBoardIntervalSeconds')
            $confirmRequest.review = $reset.data.review
            (& $call $confirmOp $confirmRequest).data.applied | Should -Be 1
            (Get-Setting 'UrgentBoardIntervalSeconds') | Should -Be $defaultInterval
            ([IO.File]::ReadAllText($script:ConfigPath) | ConvertFrom-Json).Settings.JoinSecret | Should -BeExactly 'CURRENT_JOIN_SECRET'

            for ($copy = 1; $copy -le 21; $copy++) {
                $historicalName = ('config-20261120-123456-{0:000}-a1234567.json' -f $copy)
                [IO.File]::WriteAllText((Join-Path $backupRoot.FullName $historicalName), $archiveText)
            }
            $bounded = & $call $listOp @{ actor = 7711 }
            @($bounded.data.items).Count | Should -Be 20
            $bounded.data.truncated | Should -BeTrue
            Should -Invoke Restore-ConfigBackup -Times 0 -Exactly
            Should -Invoke Reset-SettingsToDefault -Times 0 -Exactly
        }
        finally {
            $script:ConfigPath = $previousPath
            Set-JsonProp -Object $config -Name 'Settings' -Value $previousSettings
            $script:LastConfigSaveFailed = $previousSaveFailed
            $script:LastConfigSaveConflict = $previousConflict
            $script:webRecoveryTimingBusy = $false
        }
    }

    It 'delivers a bounded diagnostic bundle over the private pipe to current administrators only' {
        $beforeLog = $script:logPath
        $script:logPath = Join-Path $TestDrive 'bundle-runtime.log'
        '2026-11-21 14:00:00 [WARN] Live relay failed at rtmps://username:secret@example.invalid/ingest?query=private' |
            Set-Content -LiteralPath $script:logPath
        Mock Test-Authorized { $UserId -in 7070, 7071 }
        Mock Test-Admin { $UserId -eq 7071 }
        Mock Get-BridgeDiagnosticResources {
            @{
                Uptime = [timespan]::FromHours(1)
                WorkingSetMB = 200.0; PrivateMemoryMB = 150.0; DiskFreeGB = 1.0
                AirOperations = @{ Success = 12; Failed = 1; Blocked = 2 }
            }
        }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'DiskFreeWarningGB' }
        Mock Get-WebRuntimeFileDiagnostics { @{ ok = $true; data = @{ checkedAt = 1000; parseLimitBytes = 1MB; items = @() } } }
        try {
            $denial = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.diagnostics.bundle","args":{"actor":7070}}'
            ($denial | ConvertFrom-Json).error | Should -Be 'forbidden'
            $raw = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.diagnostics.bundle","args":{"actor":7071,"path":"C:/untrusted.json"}}'
            $response = $raw | ConvertFrom-Json
            $response.ok | Should -BeTrue
            $response.data.lowDisk | Should -BeTrue
            $response.data.airOperations.success | Should -Be 12
            $response.data.timeline.items[0].category | Should -Be 'relay'
            $raw | Should -Not -Match 'username|secret|query=private|example\.invalid|untrusted|"actor":'
            Should -Invoke Get-BridgeDiagnosticResources -Times 1 -Exactly
        }
        finally { $script:logPath = $beforeLog }
    }

    It 'exchanges restart wire data with a synthetic supervisor on a private pipe' {
        $savedChannel = $script:ManagedRestartChannel
        $savedOwnsMutex = $script:ManagedRestartOwnsMutex
        $fixtureName = "CinegyTelegramBridge.ManagedRestart.$([guid]::NewGuid().ToString('N'))"
        $fixtureServer = [IO.Pipes.NamedPipeServerStream]::new($fixtureName, 'InOut', 1, 'Byte', 'Asynchronous')
        $fixtureThread = [powershell]::Create()
        $fixtureReady = [Threading.ManualResetEventSlim]::new($false)
        $script:ManagedRestartChannel = @{ PipeName = $fixtureName; Pairing = 'A' * 64; Replacement = '' }
        $script:ManagedRestartOwnsMutex = $true
        try {
            [void]$fixtureThread.AddScript({
                    param($server, $ready)
                    $ready.Set()
                    $server.WaitForConnection()
                    $encoding = [Text.UTF8Encoding]::new($false)
                    $reader = [IO.StreamReader]::new($server, $encoding, $false, 4096, $true)
                    $writer = [IO.StreamWriter]::new($server, $encoding, 4096, $true)
                    $request = $reader.ReadLine()
                    $writer.WriteLine('{"ok":true,"state":"available"}')
                    $writer.Flush()
                    $request
                }).AddArgument($fixtureServer).AddArgument($fixtureReady)
            $handle = $fixtureThread.BeginInvoke()
            $fixtureReady.Wait([timespan]::FromSeconds(10)) | Should -BeTrue
            $response = Invoke-ManagedRestartSupervisor -Action probe
            $response.ok | Should -BeTrue
            $response.state | Should -Be 'available'
            $request = @($fixtureThread.EndInvoke($handle))[0] | ConvertFrom-Json
            $request.action | Should -Be 'probe'
            $request.pairing | Should -Be ('A' * 64)
        }
        finally {
            $fixtureServer.Dispose()
            $fixtureThread.Dispose()
            $fixtureReady.Dispose()
            $script:ManagedRestartChannel = $savedChannel
            $script:ManagedRestartOwnsMutex = $savedOwnsMutex
        }
    }

    It 'keeps reviewed Web restart inert until receipt and the stable bridge boundary' {
        $savedChannel = $script:ManagedRestartChannel
        $savedOwnsMutex = $script:ManagedRestartOwnsMutex
        $savedPending = $script:ManagedRestartPending
        $savedExpiry = $script:ManagedRestartReviewExpiresAt
        $savedExit = $script:ManagedRestartExit
        $savedRequested = $script:RestartRequested
        $savedRelaunch = $script:RestartSelfRelaunch
        $script:ManagedRestartChannel = @{ Pairing = 'A' * 64; PipeName = 'synthetic'; Replacement = '' }
        $script:ManagedRestartOwnsMutex = $true
        $script:RestartRequested = $false
        $script:ManagedRestartPending = $null
        Mock Test-Authorized { $UserId -in 6401, 6402 }
        Mock Test-Admin { $UserId -eq 6402 }
        Mock Get-Setting { $false } -ParameterFilter { $Name -in 'SchedulePaused', 'MaintenanceMode' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }
        Mock Get-RunningRelayProcess { $null }
        Mock Add-AuditEntry {}
        Mock Invoke-ManagedRestartSupervisor {
            $stateForAction = switch ($Action) { reserve { 'reserved' }; confirm { 'reviewed' }; ack { 'received' }; grant { 'granted' } }
            @{ ok = $true; id = 'a' * 32; state = $stateForAction; receipt = 'b' * 32 }
        }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $call 'admin.restart.review' @{ actor = 6401; session = 'C' * 64 }).error | Should -Be 'forbidden'
            $review = & $call 'admin.restart.review' @{ actor = 6402; session = 'C' * 64 }
            $review.data.state | Should -Be 'reserved'
            Mock Send-TelegramMessage {}
            Confirm-BridgeRestart -ChatId 6402 -UserId 6402 | Should -BeFalse
            $script:RestartRequested | Should -BeFalse
            $confirm = & $call 'admin.restart.confirm' @{ actor = 6402; session = 'C' * 64; id = $review.data.id }
            $confirm.data.receipt | Should -Be ('b' * 32)
            Complete-ManagedRestartAtPollBoundary
            $script:RestartRequested | Should -BeFalse
            (& $call 'admin.restart.accept' @{ actor = 6402; session = 'C' * 64; id = $review.data.id; receipt = $confirm.data.receipt }).data.state | Should -Be 'received'
            $script:RestartRequested | Should -BeFalse
            Should -Invoke Invoke-ManagedRestartSupervisor -Times 0 -Exactly -ParameterFilter { $Action -eq 'grant' }
            Complete-ManagedRestartAtPollBoundary
            $script:RestartRequested | Should -BeTrue
            $script:RestartSelfRelaunch | Should -BeFalse
            Should -Invoke Invoke-ManagedRestartSupervisor -Times 1 -Exactly -ParameterFilter { $Action -eq 'grant' }
        }
        finally {
            $script:ManagedRestartChannel = $savedChannel
            $script:ManagedRestartOwnsMutex = $savedOwnsMutex
            $script:ManagedRestartPending = $savedPending
            $script:ManagedRestartReviewExpiresAt = $savedExpiry
            $script:ManagedRestartExit = $savedExit
            $script:RestartRequested = $savedRequested
            $script:RestartSelfRelaunch = $savedRelaunch
        }
    }

    It 'blocks every reviewed Web restart mutation while relay is running or intended to run' {
        $savedChannel = $script:ManagedRestartChannel
        $savedOwnsMutex = $script:ManagedRestartOwnsMutex
        $savedPending = $script:ManagedRestartPending
        $savedExpiry = $script:ManagedRestartReviewExpiresAt
        $savedRequested = $script:RestartRequested
        $savedRelay = $script:RelayState
        $script:ManagedRestartChannel = @{ Pairing = 'A' * 64; PipeName = 'synthetic'; Replacement = '' }
        $script:ManagedRestartOwnsMutex = $true
        $script:RestartRequested = $false
        $script:ManagedRestartPending = $null
        $script:RelayState = @{ ShouldRun = $true; Process = $null }

        Mock Test-Authorized { $true }
        Mock Test-Admin { $true }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -in 'SchedulePaused', 'MaintenanceMode' }
        Mock Get-BridgeRestartPath { @{ Kind = 'supervisor-reported' } }
        Mock Get-RunningRelayProcess { $null }
        Mock Invoke-ManagedRestartSupervisor {
            $state = switch ($Action) { ack { 'received' }; 'relay-active' { 'relay-active' }; cancel { 'failed' }; default { 'reserved' } }
            @{ ok = $true; id = 'a' * 32; state = $state; receipt = '' }
        }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $argsForRestart = @{ actor = 6402; session = 'C' * 64; id = 'a' * 32; receipt = 'b' * 32 }
            (& $call 'admin.restart.review' $argsForRestart).error | Should -Be 'restart_relay_active'
            $readiness = (& $call 'admin.restart.readiness' @{ actor = 6402 }).data
            $readiness.relayBlocksRestart | Should -BeTrue
            $readiness.managedRestartAvailable | Should -BeFalse
            $script:RelayState.ShouldRun = $false
            Mock Get-RunningRelayProcess { [pscustomobject]@{ HasExited = $false } } -ParameterFilter { $ReadOnly }
            (& $call 'admin.restart.confirm' $argsForRestart).error | Should -Be 'restart_relay_active'
            (& $call 'admin.restart.accept' $argsForRestart).error | Should -Be 'restart_relay_active'
            Should -Invoke Invoke-ManagedRestartSupervisor -Times 0 -Exactly
            Mock Get-RunningRelayProcess { $null } -ParameterFilter { $ReadOnly }
            (& $call 'admin.restart.accept' $argsForRestart).data.state | Should -Be 'received'
            $script:RelayState.ShouldRun = $true
            Complete-ManagedRestartAtPollBoundary
            $script:RestartRequested | Should -BeFalse
            Should -Invoke Invoke-ManagedRestartSupervisor -Times 0 -Exactly -ParameterFilter { $Action -eq 'grant' }
            Should -Invoke Invoke-ManagedRestartSupervisor -Times 1 -Exactly -ParameterFilter { $Action -eq 'relay-active' }
            (& $call 'admin.restart.status' $argsForRestart).ok | Should -BeTrue
            (& $call 'admin.restart.cancel' $argsForRestart).ok | Should -BeTrue

            Mock Send-TelegramMessage {}
            Mock Invoke-ManagedRestartSupervisor { @{ ok = $true; state = 'stalled' } } -ParameterFilter { $Action -eq 'probe' }
            $script:RelayState.ShouldRun = $false
            Confirm-BridgeRestart -ChatId 6402 -UserId 6402 | Should -BeFalse
            $script:RestartRequested | Should -BeFalse
            (& $call 'admin.restart.readiness' @{ actor = 6402 }).data.state | Should -Be 'stalled'
        }
        finally {
            $script:ManagedRestartChannel = $savedChannel
            $script:ManagedRestartOwnsMutex = $savedOwnsMutex
            $script:ManagedRestartPending = $savedPending
            $script:ManagedRestartReviewExpiresAt = $savedExpiry
            $script:RestartRequested = $savedRequested
            $script:RelayState = $savedRelay
        }
    }

    It 'reads restart readiness through the private pipe without arming shutdown' {
        $previousRestart = $script:RestartRequested
        $previousRelaunch = $script:RestartSelfRelaunch
        $script:RestartRequested = $false
        $script:RestartSelfRelaunch = $false
        Mock Test-Authorized { $UserId -in 6101, 6102 }
        Mock Test-Admin { $UserId -eq 6102 }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }
        Mock Get-BridgeSupervisor { @{ Name = 'synthetic-supervisor.exe'; Supervised = $true } }
        Mock Start-Process { throw 'The fixture must never start a process' }
        Mock Stop-Process { throw 'The fixture must never stop a process' }
        try {
            $denied = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.restart.readiness","args":{"actor":6101}}'
            ($denied | ConvertFrom-Json).error | Should -Be 'forbidden'
            Should -Invoke Get-BridgeSupervisor -Times 0 -Exactly
            $raw = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.restart.readiness","args":{"actor":6102,"path":"C:/untrusted.json"}}'
            ($raw | ConvertFrom-Json).data.state | Should -Be 'supervisor-reported'
            $raw | Should -Not -Match 'synthetic-supervisor|untrusted|"actor":'
            $script:RestartRequested | Should -BeFalse
            $script:RestartSelfRelaunch | Should -BeFalse
            Should -Invoke Start-Process -Times 0 -Exactly
            Should -Invoke Stop-Process -Times 0 -Exactly
        }
        finally {
            $script:RestartRequested = $previousRestart
            $script:RestartSelfRelaunch = $previousRelaunch
        }
    }

    It 'shares saved template favorites with the Bot through the named pipe and isolates operators' {
        $previousFavorites = $script:UserFavorites
        $script:UserFavorites = @{ '4321' = @('Caption') }
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Get-TemplateStore {
            @{
                Order = @('Caption', 'Headline')
                Map = @{ Caption = @{ Key = 'Caption'; Layer = 5 }; Headline = @{ Key = 'Headline'; Layer = 6 } }
            }
        }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableFavorites' }
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'FavoritesCount' }
        Mock Save-UserFavorites { $true }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $call 'air.templateFavorites' @{ actor = 4321 }).data.selectedKeys | Should -Be @('Caption')
            $edit = @{ actor = 4321; key = 'Headline'; selected = $true }
            $updated = & $call 'air.templateFavorite.set' $edit
            $updated.ok | Should -BeTrue
            $updated.data.selectedKeys | Should -Be @('Caption', 'Headline')
            $updated.data.promotedKeys | Should -Be @('Caption')
            @(Get-UserFavoriteSelection -UserId 4321) | Should -Be @('Caption', 'Headline')
            (& $call 'air.templateFavorite.set' $edit).ok | Should -BeTrue
            @((& $call 'air.templateFavorites' @{ actor = 4322 }).data.selectedKeys).Count | Should -Be 0
            Should -Invoke Save-UserFavorites -Times 1 -Exactly
        }
        finally { $script:UserFavorites = $previousFavorites }
    }

    It 'sets a reviewed template maximum through the named pipe without sending any air command' {
        $previousReviews = $script:WebTemplateMaxAirReviews
        $script:WebTemplateMaxAirReviews = @{}
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Get-TemplateStore { @{ Map = @{ Caption = @{ Key = 'Caption'; Layer = 5 } } } }
        Mock Get-TemplatePresetRegistryRevision { 'registry-revision' }
        Mock Get-Setting { @{ Caption = 120 } } -ParameterFilter { $Name -eq 'TemplateMaxAirSeconds' }
        Mock Set-TemplateMaxAirPolicy { @{ ok = $true } }
        Mock Invoke-ShowTemplateResult { throw 'A configuration review cannot show a template.' }
        Mock Invoke-HideLayer { throw 'A configuration review cannot hide a template.' }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $call 'air.templateMaxAir' @{ actor = 4322; key = 'Caption' }).error | Should -Be 'forbidden'
            $current = & $call 'air.templateMaxAir' @{ actor = 4321; key = 'Caption' }
            $current.data.seconds | Should -Be 120
            $edit = @{ actor = 4321; key = 'Caption'; revision = $current.data.revision; mode = 'set'; seconds = 90 }
            $review = & $call 'air.templateMaxAir.review' $edit
            $review.data.seconds | Should -Be 90
            Should -Invoke Set-TemplateMaxAirPolicy -Times 0 -Exactly
            $confirm = @{ actor = 4321; key = 'Caption'; review = $review.data.review }
            (& $call 'air.templateMaxAir.confirm' $confirm).data.seconds | Should -Be 90
            (& $call 'air.templateMaxAir.confirm' $confirm).error | Should -Be 'template_air_limit_stale'
            Should -Invoke Set-TemplateMaxAirPolicy -Times 1 -Exactly -ParameterFilter { $Key -ceq 'Caption' -and $Seconds -eq 90 -and $UserId -eq 4321 }
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        }
        finally { $script:WebTemplateMaxAirReviews = $previousReviews }
    }

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

    It 'reviews a relay destination on the private pipe without touching the source or running relay' {
        $relayBefore = $script:RelayState
        $pidFileBefore = $script:relayPidFile
        $configPathBefore = $script:ConfigPath
        $streamBefore = $config.LiveStream
        $script:RelayState = @{ Process = $null; ShouldRun = $false; VerifyAt = $null; Revision = 0 }
        $script:relayPidFile = Join-Path $TestDrive 'review-destination.pid'
        $script:ConfigPath = Join-Path $TestDrive 'review-destination.json'
        $config.LiveStream = [pscustomobject]@{
            SourceUrl = 'https://input.example.invalid/live.m3u8'
            RtmpDestination = 'rtmp://old.example.invalid/live/old-key'
        }
        @{ LiveStream = $config.LiveStream; Settings = @{ EnableDpapiSecrets = $false } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigPath
        Mock Test-Authorized { $UserId -in 7321, 7322, 7323 }
        Mock Test-Admin { $UserId -in 7321, 7323 }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableLiveRelay' }
        Mock Protect-BridgePathAcl {}
        Mock Protect-BridgeConfigurationAcl {}
        Mock Get-RunningRelayProcess { $null }
        Mock Start-RelayProcess { throw 'The fixture must never launch relay' }
        Mock Stop-RelayProcess { throw 'The fixture must never stop relay' }

        $request = {
            param($route, $arguments)
            $line = @{ op = $route; args = $arguments } | ConvertTo-Json -Compress
            return (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json)
        }
        try {
            $status = (& $request 'relay.control' @{ actor = 7321; action = 'status' }).data
            $status.canEditDestination | Should -BeTrue
            $destination = 'rtmps://user:private-password@new.example.invalid:443/live/new-key?secret=private-query'
            $proposal = @{ actor = 7322; revision = $status.revision; destination = $destination }
            (& $request 'relay.destination.review' $proposal).error | Should -Be 'forbidden'
            $proposal.actor = 7321
            $review = & $request 'relay.destination.review' $proposal
            $review.ok | Should -BeTrue
            $review | ConvertTo-Json -Depth 6 | Should -Not -Match 'new-key|old-key|private-password|private-query|example\.invalid'
            $proposal.review = $review.data.review
            $proposal.actor = 7323
            (& $request 'relay.destination.confirm' $proposal).error | Should -Be 'relay_stale'
            $proposal.actor = 7321
            $proposal.destination = 'rtmp://bad.example.invalid/changed'
            (& $request 'relay.destination.confirm' $proposal).error | Should -Be 'relay_stale'
            $proposal.destination = $destination
            $proposal.review = (& $request 'relay.destination.review' $proposal).data.review
            $script:RelayState.ShouldRun = $true
            (& $request 'relay.destination.confirm' $proposal).error | Should -Be 'relay_stale'
            $script:RelayState.ShouldRun = $false
            $script:RelayState.Revision++
            $proposal.revision = (& $request 'relay.control' @{ actor = 7321; action = 'status' }).data.revision
            $proposal.review = (& $request 'relay.destination.review' $proposal).data.review
            $result = & $request 'relay.destination.confirm' $proposal
            $result.data.outcome | Should -Be 'destination-saved'
            $result | ConvertTo-Json -Depth 6 | Should -Not -Match 'new-key|old-key|private-password|private-query|example\.invalid'
            $persisted = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
            $persisted.LiveStream.RtmpDestination | Should -Be $destination
            $persisted.LiveStream.SourceUrl | Should -Be 'https://input.example.invalid/live.m3u8'
            $config.LiveStream.RtmpDestination | Should -Be $destination
            (& $request 'relay.destination.confirm' $proposal).error | Should -Be 'relay_stale'
            Should -Invoke Start-RelayProcess -Times 0 -Exactly
            Should -Invoke Stop-RelayProcess -Times 0 -Exactly
        }
        finally {
            $config.LiveStream = $streamBefore
            $script:RelayState = $relayBefore
            $script:relayPidFile = $pidFileBefore
            $script:ConfigPath = $configPathBefore
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

    It 'returns a scoped ticker aggregate and HTML through the real pipe' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-Admin { $false }
        Mock Get-NewsReportDays {
            @{ Label = 'Today'; Publishes = 2; Items = 11; SilentDays = 0; Truncated = $false; LastPublishedAt = $null
                Days = @([pscustomobject]@{ Date = [datetime]'2026-03-10'; Publishes = 2; Items = 11
                        Counts = @(8, 11); First = $null; Last = $null; Tally = @{ Single = 'Ticker desk'; Breakdown = '' }
                    }) }
        }
        $list = @{ op = 'reports.ticker'; args = @{ actor = 4321; action = 'list'; period = 'today' } } | ConvertTo-Json -Compress
        $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $list | ConvertFrom-Json
        $reply.ok | Should -BeTrue
        $reply.data.scope | Should -Be 'mine'
        $reply.data.days[0].items | Should -Be 11
        $save = @{ op = 'reports.ticker'; args = @{ actor = 4321; action = 'export'; period = 'today' } } | ConvertTo-Json -Compress
        $export = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $save | ConvertFrom-Json
        $export.data.days | Should -Be 1
        $export.data.html | Should -Match 'Ticker desk'
        Should -Invoke Get-NewsReportDays -Times 2 -Exactly -ParameterFilter { $OnlyUserId -eq 4321 }
    }

    It 'returns both station reports for an authorized operator through the real pipe' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Get-MissedEventsWindow { @{ Records = @(); Truncated = $false } }
        Mock Get-WeeklyReportData {
            @{ From = [datetime]'2026-03-04'; To = [datetime]'2026-03-10'; TickerPublishes = 5; TickerLastAt = $null
                UrgentRunsStarted = 0; UrgentStoriesPlayed = 0; NearLimit = $false; PeakScreen = ''; PeakPercent = 0
                IdleTemplates = @(); Repeats = @(); ChangedSettings = @(); Truncated = $false }
        }
        $weekly = @{ op = 'reports.weekly'; args = @{ actor = 4321 } } | ConvertTo-Json -Compress
        $week = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $weekly | ConvertFrom-Json
        $week.ok | Should -BeTrue
        $week.data.tickerPublishes | Should -Be 5
        $handover = @{ op = 'reports.handover'; args = @{ actor = 4321 } } | ConvertTo-Json -Compress
        $shift = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $handover | ConvertFrom-Json
        $shift.ok | Should -BeTrue
        $shift.data.showCount | Should -Be 0
    }

    It 'round-trips an over-frame registry through the real private pipe with bounded file references' {
        $oldLog = $script:logDir
        $oldOnAir = $script:OnAir
        $script:OnAir = @{}
        $script:logDir = $TestDrive
        $script:PipeRegistryExportFixture = Join-Path $TestDrive 'registry-transfer.json'
        $catalogue = New-Item -Path (Join-Path $TestDrive 'registry-catalogue') -ItemType Directory
        $scene = Join-Path $catalogue.FullName 'fixture.cintitle'
        [IO.File]::WriteAllText($scene, '<synthetic />')
        $before = @{ Fixture = @{ path = $scene; layer = 12 } }
        [IO.File]::WriteAllText($script:PipeRegistryExportFixture, (ConvertTo-Json -InputObject $before))
        $candidate = @{ Fixture = @{ path = $scene; layer = 12; fields = @('TITLE')
                presets = @(@{ name = 'Large fixture'; values = @(('a' * 100000)) })
            } }
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $candidate -Depth 8))
        $bytes.Length | Should -BeGreaterThan 65536
        Mock Get-TemplateRegistryFilePath { $script:PipeRegistryExportFixture }
        Mock Test-WebSceneCatalogueAccess { $Actor -eq 4321 }
        Mock Add-AuditEntry {}
        $request = {
            param([string]$Operation, [hashtable]$ArgsForWire)
            $line = @{ op = $Operation; args = (@{ actor = 4321 } + $ArgsForWire) } | ConvertTo-Json -Compress
            $line.Length | Should -BeLessThan 1024
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        $import = 'air.template-registry-import'
        $export = 'air.template-registry-export'
        try {
            $policy = & $request $import @{ action = 'prepare' }
            $policy.ok | Should -BeTrue
            $policy.data.maximumBytes | Should -Be 10MB
            $uploadId = [guid]::NewGuid().ToString('N')
            $path = Join-Path $policy.data.directory "upload-$uploadId.json"
            $share = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
            $upload = [IO.FileStream]::new($path, 'CreateNew', 'Write', $share, 4096, [IO.FileOptions]::DeleteOnClose)
            try {
                $upload.Write($bytes)
                $upload.Flush()
                $review = & $request $import @{ action = 'review'; transferId = $uploadId }
                $review.ok | Should -BeTrue
                $review.data.changed | Should -Be 1
                (& $request $import @{ action = 'confirm'; transferId = $uploadId; review = $review.data.review }).ok | Should -BeTrue
            }
            finally { $upload.Dispose() }
            Test-Path -LiteralPath $path | Should -BeFalse

            $receipt = & $request $export @{ action = 'review' }
            $receipt.data.bytes | Should -Be $bytes.Length
            $downloadId = [guid]::NewGuid().ToString('N')
            $downloadPath = Join-Path $policy.data.directory "download-$downloadId.json"
            $downloadShare = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $download = [IO.FileStream]::new($downloadPath, 'CreateNew', 'ReadWrite', $downloadShare, 4096, [IO.FileOptions]::DeleteOnClose)
            try {
                $result = & $request $export @{ action = 'download'; transferId = $downloadId; review = $receipt.data.review }
                $result.data.bytes | Should -Be $bytes.Length
                $result.data.PSObject.Properties.Name | Should -Not -Contain 'base64'
                $roundtrip = [byte[]]::new($result.data.bytes)
                $download.ReadExactly($roundtrip)
                [Convert]::ToBase64String($roundtrip) | Should -BeExactly ([Convert]::ToBase64String($bytes))
            }
            finally { $download.Dispose() }
            Test-Path -LiteralPath $downloadPath | Should -BeFalse

            $oversizedId = [guid]::NewGuid().ToString('N')
            $oversizedPath = Join-Path $policy.data.directory "upload-$oversizedId.json"
            $oversized = [IO.FileStream]::new($oversizedPath, 'CreateNew', 'Write', $share, 4096, [IO.FileOptions]::DeleteOnClose)
            try {
                $oversized.SetLength(10MB + 1)
                $oversized.Flush()
                (& $request $import @{ action = 'review'; transferId = $oversizedId }).error | Should -Be 'template_registry_import_size'
            }
            finally { $oversized.Dispose() }
            Test-Path -LiteralPath $oversizedPath | Should -BeFalse
        }
        finally {
            $script:logDir = $oldLog
            $script:OnAir = $oldOnAir
        }
    }


    It 'looks up a redacted exact incident reference over the private named pipe' {
        $before = $script:auditFile
        $script:auditFile = Join-Path $TestDrive 'incident-audit.jsonl'
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4322 }
        $id = 'air-5023333b032c476eb48204ca08032a98'
        $record = @{
            operationId = $id; event = 'air_control'; timestampUtc = '2026-03-10T09:00:00.0000000Z'
            action = 'SHOW'; result = 'failed'; layer = 7; durationMs = 56
            target = 'C:\private\path.cintitle'; message = 'operator secret fixture'
        }
        try {
            [IO.File]::WriteAllText($script:auditFile, ($record | ConvertTo-Json -Compress))
            $request = @{ op = 'shift.operation-reference'; args = @{ actor = 4322; reference = '5023333B' } }
            $line = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($request | ConvertTo-Json -Compress)
            $result = $line | ConvertFrom-Json
            $result.data.status | Should -Be 'found'
            $result.data.items[0].durationMs | Should -Be 56
            $line | Should -Not -Match 'private|secret|cintitle|5023333b032c'
            $request.args.actor = 4321
            (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($request | ConvertTo-Json -Compress) | ConvertFrom-Json).error |
                Should -Be 'forbidden'
        }
        finally { $script:auditFile = $before }
    }

    It 'carries a queued request to the bridge thread and its answer back' {
        $parsed = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"ping"}') | ConvertFrom-Json
        $parsed.ok | Should -BeTrue
        $parsed.data.version | Should -Be $script:BridgeVersion
    }

    It 'serves only the dedicated normalized playback source from the private pipe without a pump' {
        $settings = Get-JsonProp $config 'Settings'
        $previous = Get-JsonProp $settings 'WebLivePlaybackUrl'
        $previousPage = Get-JsonProp $settings 'LiveWatchUrl'
        $request = '{"op":"live.playback","args":{"actor":9999,"url":"https://untrusted.example/override"}}'
        Mock Invoke-WebChannelOperation { throw 'Playback is a read-only listener operation.' }
        Mock Save-Config {}
        Mock Get-ActiveLiveStreamConfig {
            [pscustomobject]@{ SourceUrl = 'https://relay.example/hls?private=fixture'; RtmpDestination = 'rtmp://private.example/key' }
        }
        try {
            Set-JsonProp $settings 'LiveWatchUrl' 'https://watch.example/index.html?theme=dark&src=stale#player'
            foreach ($invalid in @('', 'https://film.example/hls?secret=fixture', 'https://fixture:private@film.example/hls')) {
                Set-JsonProp $settings 'WebLivePlaybackUrl' $invalid
                Publish-WebChannelState -Force
                $reply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $request -PumpSeconds 0) | ConvertFrom-Json
                $reply.ok | Should -BeTrue
                $reply.data.url | Should -BeNullOrEmpty
            }
            Set-JsonProp $settings 'WebLivePlaybackUrl' 'HTTPS://FILM.EXAMPLE:443/hls/index.m3u8'
            Publish-WebChannelState -Force
            $reply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $request -PumpSeconds 0) | ConvertFrom-Json
            $reply.data.url | Should -BeExactly 'https://film.example/hls/index.m3u8'
            @($reply.data.PSObject.Properties.Name) | Should -Be @('url')
            $watch = [uri](Get-LiveWatchUrl)
            @($watch.Query.TrimStart('?').Split('&') | Where-Object { $_ -like 'src=*' }) |
                Should -Be @('src=' + [uri]::EscapeDataString($reply.data.url))
            $watch.Query | Should -Match 'theme=dark'
            $watch.Fragment | Should -Be '#player'

            Set-Setting -Name 'WebLivePlaybackUrl' -Value 'https://film.example/live/replacement.m3u8'
            $updated = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $request -PumpSeconds 0) | ConvertFrom-Json
            $updated.data.url | Should -BeExactly 'https://film.example/live/replacement.m3u8'
            (Get-LiveWatchUrl) | Should -Match ([regex]::Escape([uri]::EscapeDataString($updated.data.url)))
            Should -Invoke Get-ActiveLiveStreamConfig -Times 0 -Exactly
            Should -Invoke Invoke-WebChannelOperation -Times 0 -Exactly
        }
        finally {
            Set-JsonProp $settings 'WebLivePlaybackUrl' $previous
            Set-JsonProp $settings 'LiveWatchUrl' $previousPage
            Publish-WebChannelState -Force
        }
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

        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }

        # 3. air.hide
        $hideReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.hide","args":{"actor":4321,"layer":5}}') | ConvertFrom-Json
        $hideReply.ok | Should -BeTrue
        Should -Invoke Invoke-HideLayer -Times 1

        # 4. air.exit
        $exitReply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"air.exit","args":{"actor":4321,"layer":5}}') | ConvertFrom-Json
        $exitReply.ok | Should -BeTrue
        Should -Invoke Invoke-ExitLayer -Times 1
    }

    It 'lists and registers selected scenes through the shared catalogue without escaping the configured folder' {
        $script:WebSceneTestRoot = Join-Path $TestDrive 'scenes'
        $studio = Join-Path $script:WebSceneTestRoot 'studio'
        New-Item -ItemType Directory -Path $studio -Force | Out-Null
        $sceneFile = Join-Path $studio 'evening.cintitle'
        Set-Content -LiteralPath $sceneFile -Value '<Scene />'
        Set-Content -LiteralPath (Join-Path $studio '%SystemRoot%-report.cintitle') -Value '<Scene />'
        Set-Content -LiteralPath (Join-Path $studio 'notes.txt') -Value 'station notes'
        Set-Content -LiteralPath (Join-Path $TestDrive 'outside.cintitle') -Value '<Scene />'
        $script:WebSceneTestRegistry = Join-Path $TestDrive 'scene-registry.json'
        Set-Content -LiteralPath $script:WebSceneTestRegistry -Value '{}'
        Mock Get-TemplateRegistryFilePath { $script:WebSceneTestRegistry }
        Mock Get-Setting { $script:WebSceneTestRoot } -ParameterFilter { $Name -eq 'TemplateBasePath' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableFullTemplateManagement' }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Add-AuditEntry {}
        $catalogueCall = {
            param($payload)
            $line = @{ op = 'air.templateCatalogue'; args = $payload } | ConvertTo-Json -Depth 6 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        $request = @{ actor = 4322; action = 'browse'; folder = '' }
        (& $catalogueCall $request).error | Should -Be 'forbidden'
        $request.actor = 4321
        (& $catalogueCall $request).data.entries.name | Should -Be @('studio')
        $work = @{
            Request = @{ op = 'air.templateCatalogue'; args = $request.Clone() }
            Deadline = [Diagnostics.Stopwatch]::GetTimestamp() + 12 * [Diagnostics.Stopwatch]::Frequency
            Claim = [Threading.Tasks.TaskCompletionSource[bool]]::new()
            Reply = [Threading.Tasks.TaskCompletionSource[string]]::new()
        }
        $script:WebChannel.Shared.Queue.Enqueue($work)
        Invoke-WebChannelRequests
        $work.Claim.Task.Result | Should -BeTrue
        $work.Reply.Task.IsCompleted | Should -BeFalse
        (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"ping"}' | ConvertFrom-Json).ok | Should -BeTrue
        while (-not $work.Reply.Task.IsCompleted -and [Diagnostics.Stopwatch]::GetTimestamp() -lt $work.Deadline) {
            Invoke-WebChannelRequests
            Start-Sleep -Milliseconds 25
        }
        $work.Reply.Task.IsCompleted | Should -BeTrue
        $request.folder = '..'
        (& $catalogueCall $request).error | Should -Be 'scene_not_found'
        $request.folder = 'studio'
        $files = (& $catalogueCall $request).data.entries
        $files.name | Should -Be @('evening.cintitle')
        $files.folder | Should -BeFalse
        $request.action = 'review'
        $request.definition = @{ key = 'evening'; file = $files.path; layer = 8; description = 'بطاقة المساء'; fields = @('Title', 'Guest') }
        $plan = (& $catalogueCall $request).data.preview
        $plan.fields | Should -Be @('Title', 'Guest')
        (Get-TemplateStore).Map.ContainsKey('evening') | Should -BeFalse
        $request.action = 'register'
        $request.review = $plan.review
        Add-Content -LiteralPath $sceneFile -Value '<!-- scene changed after review -->'
        (& $catalogueCall $request).error | Should -Be 'scene_registry_stale'
        $request.action = 'review'
        $request.review = (& $catalogueCall $request).data.preview.review
        $request.action = 'register'
        (& $catalogueCall $request).ok | Should -BeTrue
        $saved = (Get-TemplateStore).Map['evening']
        $saved.Path | Should -Be $sceneFile
        $saved.Fields | Should -Be @('Title', 'Guest')
        $saved.Layer | Should -Be 8
        (& $catalogueCall $request).error | Should -Be 'scene_registry_stale'
        @(Get-TemplateBackupFiles -Path $script:WebSceneTestRegistry).Count | Should -Be 1
    }

    It 'reviews catalogue edits and deletion against the same definition and active schedule used by Telegram' {
        $script:WebDefinitionTestRegistry = Join-Path $TestDrive 'definition-catalogue.json'
        Set-Content -LiteralPath $script:WebDefinitionTestRegistry -Value @'
{"Evening":{"path":"C:/station/old.cintitle","layer":8,"description":"Before","category":"News","fields":[{"name":"Title","label":"Title","type":"Text","maxLength":90},"Guest"],"presets":[{"name":"Standard","values":["fixture sensitive value","Host"]}]}}
'@
        $script:WebDefinitionTestLive = $false
        $script:WebDefinitionTestScheduled = $false
        $script:WebDefinitionTestLinked = $false
        Mock Get-TemplateRegistryFilePath { $script:WebDefinitionTestRegistry }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableFullTemplateManagement' }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Get-UpcomingScheduleEvents {
            if ($script:WebDefinitionTestScheduled) { @{ TemplateKey = 'Evening' } }
        }
        Mock Get-ContentBoards {
            if ($script:WebDefinitionTestLinked) { @{ TemplateKey = 'Evening' } }
        }
        Mock Add-AuditEntry {}
        Mock Send-TelegramMessage {}
        $definitionCall = {
            param($payload)
            $line = @{ op = 'air.templateDefinition'; args = $payload } | ConvertTo-Json -Depth 8 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
        }
        $request = @{ actor = 4322; action = 'inspect'; key = 'Evening' }
        ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'forbidden'
        $request.actor = 4321
        $loaded = & $definitionCall $request
        $loaded | Should -Not -Match 'fixture sensitive value|C:/station/'
        $original = ($loaded | ConvertFrom-Json).data.definition
        $original.fields.name | Should -Be @('Title', 'Guest')
        $request.revision = $original.revision
        $request.action = 'review-edit'
        $request.changes = @{ description = 'Evening news'; category = 'Programmes'; layer = 8
            fields = @(@{ name = 'Title'; label = 'Headline'; required = $true; maxLength = 70 }, @{ name = 'Guest'; label = 'Guest' }) }
        $request.changes.fields[1].name = 'Presenter'
        ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'scene_definition_preset_fields'
        $request.changes.fields[1].name = 'Guest'
        $script:WebDefinitionTestScheduled = $true
        $request.changes.layer = 11
        ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'scene_definition_scheduled'
        $request.changes.layer = 8
        $preview = ((& $definitionCall $request) | ConvertFrom-Json).data.preview
        $script:WebDefinitionTestScheduled = $false
        $preview.after.description | Should -Be 'Evening news'
        (Get-TemplateStore).Map['Evening'].Description | Should -Be 'Before'
        $request.review = $preview.review
        $request.action = 'edit'
        # An edit made in the bot uses the same registry writer.
        (Save-TemplateDefinitionChange -TemplateKey Evening -Action edit -Definition @{ path = 'C:/station/old.cintitle'; layer = 8; description = 'Bot edit'; fields = @(@{ name = 'Title'; type = 'Text'; maxLength = 90 }, 'Guest') }).Success | Should -BeTrue
        ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'scene_registry_stale'
        $request.action = 'inspect'
        $request.revision = ((& $definitionCall $request) | ConvertFrom-Json).data.definition.revision
        Start-TemplateDefinitionPrompt -Action delete -TemplateIndex 0 -ChatId 4321 -UserId 4321
        $olderReview = [string](Get-JsonProp (Get-PendingState -ChatId 4321) 'DefinitionNonce')
        Start-TemplateDefinitionPrompt -Action delete -TemplateIndex 0 -ChatId 4321 -UserId 4321
        $latestReview = [string](Get-JsonProp (Get-PendingState -ChatId 4321) 'DefinitionNonce')
        $olderReview | Should -Not -BeNullOrEmpty
        $latestReview | Should -Not -Be $olderReview
        Confirm-TemplateDefinitionChange -ChatId 4321 -UserId 4321 -Nonce $olderReview
        (Get-TemplateStore).Map.ContainsKey('Evening') | Should -BeTrue
        (Get-JsonProp (Get-PendingState -ChatId 4321) 'DefinitionNonce') | Should -Be $latestReview
        $request.action = 'review-edit'
        $request.review = ((& $definitionCall $request) | ConvertFrom-Json).data.preview.review
        $request.action = 'edit'
        ((& $definitionCall $request) | ConvertFrom-Json).ok | Should -BeTrue
        Confirm-TemplateDefinitionChange -ChatId 4321 -UserId 4321 -Nonce $latestReview
        $shared = (Get-Content -LiteralPath $script:WebDefinitionTestRegistry -Raw | ConvertFrom-Json).Evening
        $shared.description | Should -Be 'Evening news'
        $shared.fields[0].type | Should -Be 'Text'
        $shared.fields[0].required | Should -BeTrue
        $shared.presets[0].values | Should -Be @('fixture sensitive value', 'Host')
        $request.action = 'inspect'
        $request.revision = ((& $definitionCall $request) | ConvertFrom-Json).data.definition.revision
        $request.action = 'review-delete'
        $request.review = ((& $definitionCall $request) | ConvertFrom-Json).data.preview.review
        $request.action = 'delete'
        $oldOnAir = $script:OnAir
        $oldLibrary = $script:MojazLibrary
        $oldSchedules = $script:MojazSchedules
        try {
            $script:OnAir = @{ 8 = @{ Key = 'Evening' } }
            ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'scene_definition_live'
            $script:OnAir.Clear()
            $script:WebDefinitionTestScheduled = $true
            ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'scene_definition_scheduled'
            $script:WebDefinitionTestScheduled = $false
            $script:WebDefinitionTestLinked = $true
            ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'scene_definition_linked'
            $script:WebDefinitionTestLinked = $false
            $script:MojazSchedules = @(@{ Status = 'queued'; DesignKey = 'Evening' })
            ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'scene_definition_scheduled'
            $script:MojazSchedules = @()
            $script:MojazLibrary = @{ Bulletins = @(@{ TemplateKey = 'Evening' }) }
            ((& $definitionCall $request) | ConvertFrom-Json).error | Should -Be 'scene_definition_linked'
            $script:MojazLibrary = $oldLibrary
            $request.action = 'review-delete'
            $request.review = ((& $definitionCall $request) | ConvertFrom-Json).data.preview.review
            $request.action = 'delete'
            ((& $definitionCall $request) | ConvertFrom-Json).ok | Should -BeTrue
            (Get-TemplateStore).Map.ContainsKey('Evening') | Should -BeFalse
        }
        finally {
            $script:OnAir = $oldOnAir
            $script:MojazLibrary = $oldLibrary
            $script:MojazSchedules = $oldSchedules
        }
    }

    It 'routes the newsroom workflow requests with their own authorization and reports an empty operator history' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-Admin { $false }
        $savedHistory = $script:LastShow
        $script:LastShow = @{}
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $call 'telegram.access.requests' @{ actor = 4321; page = 0 }).error | Should -Be 'forbidden'
            (& $call 'schedule.templates' @{ actor = 9876; action = 'list' }).error | Should -Be 'forbidden'
            (& $call 'schedule.templates' @{ actor = 4321; action = 'list'; page = 0 }).ok | Should -BeTrue
            (& $call 'air.rerun' @{ actor = 4321; kind = 'repeat'; action = 'inspect' }).error | Should -Be 'rerun_missing'
        }
        finally { $script:LastShow = $savedHistory }
    }

    It 'rechecks the current administrator and applies a single reviewed setting change across the named pipe' {
        Mock Test-Authorized { $UserId -in 4321, 9876 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-StatusViewer { $UserId -eq 4321 }
        Mock Save-Config { $script:LastConfigSaveFailed = $false }
        $previousSettings = Get-JsonProp $config 'Settings'
        $previousSaveStatus = $script:LastConfigSaveFailed
        Set-JsonProp $config 'Settings' @{ AskRequesterName = $false }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $call 'admin.overview' @{ actor = 9876 }).error | Should -Be 'forbidden'
            $overview = & $call 'admin.overview' @{ actor = 4321 }
            $overview.ok | Should -BeTrue
            @($overview.data.settings.id) | Should -Contain 'AskRequesterName'
            @($overview.data.settings.id) | Should -Not -Contain 'BotToken'
            (& $call 'shift.history' @{ actor = 9876; scope = 'all' }).error | Should -Be 'forbidden'
            (& $call 'shift.history' @{ actor = 9876; scope = 'mine' }).ok | Should -BeTrue
            $draft = & $call 'admin.settings.review' @{ actor = 4321; id = 'AskRequesterName'; enabled = $true }
            $draft.ok | Should -BeTrue
            $confirm = @{ actor = 9876; id = 'AskRequesterName'; review = $draft.data.review }
            (& $call 'admin.settings.confirm' $confirm).error | Should -Be 'forbidden'
            $confirm.actor = 4321
            (& $call 'admin.settings.confirm' $confirm).data.setting.enabled | Should -BeTrue
            (& $call 'admin.settings.confirm' $confirm).error | Should -Be 'setting_stale'
            Should -Invoke Save-Config -Times 1 -Exactly
        }
        finally {
            Set-JsonProp $config 'Settings' $previousSettings
            $script:LastConfigSaveFailed = $previousSaveStatus
        }
    }

    It 'reviews native editorial timing and imports partial snapshots through the private pipe' {
        Mock Test-Authorized { $UserId -in 6301, 6302 }
        Mock Test-Admin { $UserId -eq 6302 }
        Mock Test-StatusViewer { $UserId -eq 6302 }
        Mock Save-Config { $script:LastConfigSaveFailed = $false; $script:LastConfigSaveConflict = $false }
        Mock Add-AuditEntry {}
        $previousSettings = Get-JsonProp $config 'Settings'
        $previousSaveFailed = $script:LastConfigSaveFailed
        $previousConflict = Get-Variable LastConfigSaveConflict -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        Set-JsonProp $config 'Settings' @{ UrgentBoardIntervalSeconds = 8; TemplateReminderFollowUpMinutes = 5; NewsDraftTimeoutMinutes = 120 }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $overview = & $call 'admin.overview' @{ actor = 6302 }
            ($overview.data.settings | Where-Object id -eq 'TemplateReminderFollowUpMinutes').editable | Should -BeTrue
            ($overview.data.settings | Where-Object id -eq 'EnableUrgentBoard').editable | Should -BeFalse
            $review = & $call 'admin.settings.review' @{ actor = 6302; id = 'UrgentBoardIntervalSeconds'; value = 12 }
            $review.data.setting.unit | Should -BeExactly 'ثانية'
            (& $call 'admin.settings.confirm' @{ actor = 6301; id = 'UrgentBoardIntervalSeconds'; review = $review.data.review }).error | Should -Be 'forbidden'
            (& $call 'admin.settings.confirm' @{ actor = 6302; id = 'UrgentBoardIntervalSeconds'; review = $review.data.review }).data.setting.value | Should -Be 12
            (Get-Setting 'UrgentBoardIntervalSeconds') | Should -Be 12
            Should -Invoke Save-Config -Times 1 -Exactly -ParameterFilter {
                $ReviewedExpected.Count -eq 1 -and $ReviewedExpected.UrgentBoardIntervalSeconds -eq 8 -and
                $ReviewedPatch.Count -eq 1 -and $ReviewedPatch.UrgentBoardIntervalSeconds -eq 12
            }
            $partial = & $call 'admin.settings.import.review' @{ actor = 6302; settings = @{ TemplateReminderFollowUpMinutes = 0 } }
            @($partial.data.changes).Count | Should -Be 1
            (& $call 'admin.settings.import.confirm' @{ actor = 6302; review = $partial.data.review }).data.applied | Should -Be 1
            (Get-Setting 'TemplateReminderFollowUpMinutes') | Should -Be 0
            (Get-Setting 'NewsDraftTimeoutMinutes') | Should -Be 120
            $export = & $call 'admin.settings.export' @{ actor = 6302 }
            $export.data.Settings.UrgentBoardIntervalSeconds | Should -Be 12
            $export.data.Settings.TemplateReminderFollowUpMinutes | Should -Be 0
            ($export.data.Settings.PSObject.Properties.Name) | Should -Not -Contain 'BotToken'
        }
        finally {
            Set-JsonProp $config 'Settings' $previousSettings
            $script:LastConfigSaveFailed = $previousSaveFailed
            $script:LastConfigSaveConflict = $previousConflict
        }
    }

    It 'protects registry diagnostics and lists opaque backup choices through the named pipe' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        $oldRegistry = $config.TemplateRegistryPath
        $oldManagement = Get-Setting 'EnableFullTemplateManagement'
        $registry = New-TempTemplateFile -Json '{}'
        $backupDirectory = New-Item -ItemType Directory -Path "$registry.backups"
        $backupName = 'templates-20261121-123456-000-a1234567.json'
        Copy-Item -LiteralPath $registry -Destination (Join-Path $backupDirectory.FullName $backupName)
        Set-JsonProp $config.Settings 'EnableFullTemplateManagement' $true
        $call = {
            param([string]$Operation, [long]$Actor)
            $line = @{ op = $Operation; args = @{ actor = $Actor; action = 'list' } } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $call 'air.template-backups' 4322).error | Should -Be 'forbidden'
            (& $call 'air.template-issues' 4322).error | Should -Be 'forbidden'
            $result = & $call 'air.template-backups' 4321
            $result.ok | Should -BeTrue
            @($result.data.backups).Count | Should -Be 1
            $result.data.backups[0].id | Should -Match '^[A-F0-9]{64}$'
            ($result | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($backupDirectory.FullName))
            ($result | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($backupName))
            (& $call 'air.template-issues' 4321).ok | Should -BeTrue
        }
        finally {
            $config.TemplateRegistryPath = $oldRegistry
            Set-JsonProp $config.Settings 'EnableFullTemplateManagement' $oldManagement
        }
    }

    It 'validates a replacement file in the catalogue worker and changes only the reviewed registry path' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Get-WebLayerStatus { @{ Success = $true; IsOnAir = $false } }
        $oldRegistry = $config.TemplateRegistryPath
        $oldRoot = Get-Setting 'TemplateBasePath'
        $oldManagement = Get-Setting 'EnableFullTemplateManagement'
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'replacement-catalogue')).FullName
        $previous = Join-Path $folder 'existing.cintitle'
        $replacement = Join-Path $folder 'replacement.cintitle'
        $markup = '<Scene><Var Name="Title" Type="String" /><Title Text="${Title}" /></Scene>'
        Set-Content -LiteralPath $previous -Value $markup
        Set-Content -LiteralPath $replacement -Value $markup
        $definition = @{ Caption = @{ path = $previous; layer = 7; description = 'Fixture caption'; fields = @('Title') } }
        $registry = New-TempTemplateFile -Json ($definition | ConvertTo-Json -Depth 6)
        Set-JsonProp $config.Settings 'TemplateBasePath' $folder
        Set-JsonProp $config.Settings 'EnableFullTemplateManagement' $true
        $call = {
            param([hashtable]$Arguments)
            $line = @{ op = 'air.templateScene'; args = $Arguments } | ConvertTo-Json -Depth 4 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $request = @{ actor = 4321; key = 'Caption'; action = 'inspect' }
            $request.revision = (& $call $request).data.current.revision
            $request.action = 'select'
            $request.file = 'replacement.cintitle'
            $selection = & $call $request
            $selection.ok | Should -BeTrue
            $selection.data.selection.handle | Should -Not -BeNullOrEmpty
            ($selection | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($folder))
            $request.action = 'preview'
            $request.Remove('file')
            $request.selection = $selection.data.selection.handle
            $review = & $call $request
            $review.ok | Should -BeTrue
            (Get-TemplateStore).Map['Caption'].Path | Should -Be $previous
            $request.action = 'apply'
            $request.review = $review.data.preview.review
            (& $call $request).ok | Should -BeTrue
            $saved = Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json
            $saved.Caption.path | Should -Be $replacement
            $saved.Caption.description | Should -Be 'Fixture caption'
            @($saved.Caption.fields) | Should -Be @('Title')
        }
        finally {
            $config.TemplateRegistryPath = $oldRegistry
            Set-JsonProp $config.Settings 'TemplateBasePath' $oldRoot
            Set-JsonProp $config.Settings 'EnableFullTemplateManagement' $oldManagement
        }
    }

    It 'only clears the reviewed Telegram quarantine after saving through the named pipe' {
        $previousChats = $script:DeadChats
        $previousStrikes = $script:DeadChatStrikes
        $previousReviews = $script:WebTelegramQuarantineReviews
        $script:DeadChats = @{
            '444' = @{ Since = '2026-11-21T08:00:00Z'; Strikes = 3; LastError = 'private Telegram response' }
            '-555' = @{ Since = '2026-11-21T09:00:00Z'; Strikes = 4; LastError = 'private group response' }
        }
        $script:DeadChatStrikes = @{ '444' = 3 }
        $script:WebTelegramQuarantineReviews = @{}
        $script:QuarantineSaveSucceeds = $false
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Save-DeadChats { $script:QuarantineSaveSucceeds }
        Mock Invoke-BridgeTelegramRequest { throw 'A quarantine reset cannot send a Telegram message.' }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $call 'telegram.delivery.quarantine' @{ actor = 4322 }).error | Should -Be 'forbidden'
            $list = & $call 'telegram.delivery.quarantine' @{ actor = 4321 }
            $list.ok | Should -BeTrue
            $list.data.total | Should -Be 2
            $list.data.items[0].canReset | Should -BeFalse
            $list.data.items[1].canReset | Should -BeTrue
            ($list | ConvertTo-Json -Depth 7) | Should -Not -Match 'LastError|private Telegram response|private group response'

            $review = & $call 'telegram.delivery.quarantine.reset.review' @{ actor = 4321; chatId = 444 }
            $review.ok | Should -BeTrue
            $confirm = @{ actor = 4321; chatId = 444; review = $review.data.review }
            (& $call 'telegram.delivery.quarantine.reset.confirm' $confirm).error | Should -Be 'telegram_quarantine_save_failed'
            (Test-DeadChat -ChatId 444) | Should -BeTrue
            $script:DeadChatStrikes['444'] | Should -Be 3

            $script:QuarantineSaveSucceeds = $true
            (& $call 'telegram.delivery.quarantine.reset.confirm' $confirm).error | Should -Be 'telegram_quarantine_stale'
            $review = & $call 'telegram.delivery.quarantine.reset.review' @{ actor = 4321; chatId = 444 }
            $confirm.review = $review.data.review
            (& $call 'telegram.delivery.quarantine.reset.confirm' $confirm).data.chatId | Should -Be 444
            (Test-DeadChat -ChatId 444) | Should -BeFalse
            (Test-DeadChat -ChatId -555) | Should -BeTrue
            $script:DeadChatStrikes.ContainsKey('444') | Should -BeFalse
            Should -Invoke Invoke-BridgeTelegramRequest -Times 0 -Exactly
        }
        finally {
            $script:DeadChats = $previousChats
            $script:DeadChatStrikes = $previousStrikes
            $script:WebTelegramQuarantineReviews = $previousReviews
        }
    }

    It 'keeps administrative disclosure behind current Telegram access and exposes personal notice settings' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-Admin { $false }
        $call = {
            param([string]$Operation, [hashtable]$Arguments)
            $line = @{ op = $Operation; args = $Arguments } | ConvertTo-Json -Depth 5 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        foreach ($operation in @('admin.announcements.list', 'admin.diagnostics.runtime-files', 'admin.readiness', 'admin.settings.export', 'admin.notifications.coverage', 'telegram.access.blocked', 'telegram.access.history', 'telegram.access.suspended-operators')) {
            (& $call $operation @{ actor = 4321 }).error | Should -Be 'forbidden'
        }
        (& $call 'shift.notices' @{ actor = 4321; area = 'personal'; action = 'read' }).ok | Should -BeTrue
        (& $call 'schedule.executions' @{ actor = 9876 }).error | Should -Be 'forbidden'
        (& $call 'schedule.executions' @{ actor = 4321; kind = 'all'; result = 'all' }).ok | Should -BeTrue
    }

    It 'holds and resumes the shared template queue through the named pipe after a current administrator review' {
        Mock Test-Authorized { $UserId -in 4321, 4876, 9876 }
        Mock Test-Admin { $UserId -eq 4876 -or ($UserId -eq 4321 -and $script:ScheduleHoldActorIsAdmin) }
        Mock Add-AuditEntry {}
        Mock Invoke-ShowTemplateResult { throw 'The hold control must not execute a show.' }
        Mock Update-ScheduleQueue { throw 'The hold control must not run a scheduler tick.' }
        Mock Save-Config {
            $script:LastConfigSaveConflict = $false
            $script:LastConfigSaveFailed = $script:ScheduleHoldSimulatedSaveFailure
        }

        $previousSettings = Get-JsonProp $config 'Settings'
        $previousEvents = $script:ScheduleEvents
        $previousSave = $script:LastConfigSaveFailed
        $previousConflict = Get-Variable LastConfigSaveConflict -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $script:ScheduleHoldActorIsAdmin = $true
        $script:ScheduleHoldSimulatedSaveFailure = $false
        $script:WebScheduleHoldReviews.Clear()
        Set-JsonProp $config 'Settings' @{ SchedulePaused = $false; MaintenanceMode = $false }
        $appointment = @{
            Id = 'fixture-schedule-hold'; Status = 'pending'; TemplateKey = 'Evening'
            ScheduledAt = '2031-02-24T12:45:00.0000000+00:00'; MutationId = 'fixture-first'
        }
        $script:ScheduleEvents = @($appointment)
        $call = {
            param([string]$Operation, [long]$Actor = 4321, [hashtable]$Values = @{})
            $line = @{ op = "schedule.hold.$Operation"; args = @{ actor = $Actor } + $Values } | ConvertTo-Json -Compress -Depth 5
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }

        try {
            (& $call 'review' 9876 @{ paused = $true }).error | Should -Be 'forbidden'
            (& $call 'review' 4321 @{ paused = 'true' }).error | Should -Be 'schedule_hold_invalid'
            $review = & $call 'review' 4321 @{ paused = $true }
            $review.ok | Should -BeTrue
            $review.data.currentlyPaused | Should -BeFalse
            $review.data.pendingAppointments | Should -Be 1
            $confirm = @{ review = $review.data.review }
            (Get-Setting 'SchedulePaused') | Should -BeFalse
            (& $call 'confirm' 4876 $confirm).error | Should -Be 'schedule_hold_stale'
            $script:ScheduleHoldActorIsAdmin = $false
            (& $call 'confirm' 4321 $confirm).error | Should -Be 'forbidden'
            $script:ScheduleHoldActorIsAdmin = $true
            $appointment.MutationId = 'fixture-second'
            (& $call 'confirm' 4321 $confirm).error | Should -Be 'schedule_hold_stale'
            Should -Invoke Save-Config -Exactly -Times 0

            $review = & $call 'review' 4321 @{ paused = $true }
            $confirm.review = $review.data.review
            $script:ScheduleHoldSimulatedSaveFailure = $true
            (& $call 'confirm' 4321 $confirm).error | Should -Be 'schedule_hold_save_failed'
            (Get-Setting 'SchedulePaused') | Should -BeFalse
            (& $call 'confirm' 4321 $confirm).error | Should -Be 'schedule_hold_stale'
            $script:ScheduleHoldSimulatedSaveFailure = $false

            $review = & $call 'review' 4321 @{ paused = $true }
            $confirm.review = $review.data.review
            (& $call 'confirm' 4321 $confirm).data.paused | Should -BeTrue
            (Get-Setting 'SchedulePaused') | Should -BeTrue
            (& $call 'confirm' 4321 $confirm).error | Should -Be 'schedule_hold_stale'

            $review = & $call 'review' 4321 @{ paused = $false }
            $confirm.review = $review.data.review
            Set-JsonProp (Get-JsonProp $config 'Settings') 'MaintenanceMode' $true
            (& $call 'confirm' 4321 $confirm).error | Should -Be 'schedule_hold_stale'
            $review = & $call 'review' 4321 @{ paused = $false }
            $review.data.maintenance | Should -BeTrue
            $confirm.review = $review.data.review
            (& $call 'confirm' 4321 $confirm).data.paused | Should -BeFalse
            (Get-Setting 'SchedulePaused') | Should -BeFalse
            (Get-Setting 'MaintenanceMode') | Should -BeTrue
            $appointment.Status | Should -Be 'pending'
            $appointment.MutationId | Should -Be 'fixture-second'
            Should -Invoke Save-Config -Exactly -Times 3
            Should -Invoke Invoke-ShowTemplateResult -Exactly -Times 0
            Should -Invoke Update-ScheduleQueue -Exactly -Times 0
        }
        finally {
            Set-JsonProp $config 'Settings' $previousSettings
            $script:ScheduleEvents = $previousEvents
            $script:LastConfigSaveFailed = $previousSave
            $script:LastConfigSaveConflict = $previousConflict
            $script:WebScheduleHoldReviews.Clear()
        }
    }

    It 'enforces current admin access and the opt-in before reading detailed engine health through the named pipe' {
        Mock Test-Authorized { $UserId -in 4321, 9876 }
        Mock Test-Admin { $UserId -ne 9876 }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableEngineHealth' }
        Mock Get-AirTelemetryStatus { throw 'Feature gate must run before the engine probe.' }
        Mock Get-AirVideoStatus { throw 'Feature gate must run before the video probe.' }
        $line = '{"op":"admin.engine-health","args":{"actor":VAR}}'
        $denied = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($line.Replace('VAR', '9876'))
        ($denied | ConvertFrom-Json).error | Should -Be 'forbidden'
        $revoked = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($line.Replace('VAR', '1234'))
        ($revoked | ConvertFrom-Json).error | Should -Be 'forbidden'
        $disabled = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($line.Replace('VAR', '4321'))
        $disabledSnapshot = $disabled | ConvertFrom-Json
        $disabledSnapshot.ok | Should -BeTrue
        $disabledSnapshot.data.enabled | Should -BeFalse
        Should -Invoke Get-AirTelemetryStatus -Exactly -Times 0
        Should -Invoke Get-AirVideoStatus -Exactly -Times 0
    }

    It 'publishes only safe detailed engine readings through the named pipe' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableEngineHealth' }
        Mock Get-AirTelemetryStatus {
            @{
                Success = $true; Healthy = $true; SampleCount = $script:HealthFixtureSamples
                OutputCount = 1500; DroppedCount = $script:HealthFixtureDropped; NoInputSignal = 2
                AverageReadTime = 13.25; MaxReadErrorRate = [double]::NaN
                Xml = '<raw-private-engine-xml>'; Uri = 'http://fixture-engine-host'; Issues = @('fixture-private-issue')
            }
        }
        Mock Get-AirVideoStatus { @{ Success = $true; License = $script:HealthFixtureLicense; Error = 'fixture-private-video-error' } }
        Mock Send-AirCommand { throw 'Reading engine health must not issue air commands.' }
        Mock Get-AirMaterialSchedule { throw 'Programme schedule is a separate status screen.' }
        $oldProbe = $script:WebLayerComparisonNextProbe
        $oldBaseline = $script:WebEngineHealthBaseline
        $oldBotCount = $script:LastEngineDropped
        $script:WebLayerComparisonNextProbe = 0L
        $script:WebEngineHealthBaseline = $null
        $script:LastEngineDropped = 70
        $script:HealthFixtureDropped = 4
        $script:HealthFixtureSamples = 60
        $script:HealthFixtureLicense = 'fixture-private-license-id'
        $line = '{"op":"admin.engine-health","args":{"actor":4321}}'
        try {
            $raw = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
            $reply = $raw | ConvertFrom-Json
            $reply.ok | Should -BeTrue
            $reply.data.enabled | Should -BeTrue
            $reply.data.health | Should -Be 'no_input'
            $reply.data.license | Should -Be 'warning'
            $reply.data.checkedAtMs | Should -BeGreaterThan 0
            $reply.data.elapsedMs | Should -BeGreaterOrEqual 0
            $reply.data.outputFrames | Should -Be 1500
            $reply.data.droppedFrames | Should -Be 4
            $reply.data.droppedSampleIncrease | Should -BeNullOrEmpty
            $reply.data.meanReadMs | Should -Be 13.25
            $reply.data.maxReadErrorPercent | Should -BeNullOrEmpty
            $raw | Should -Not -Match 'fixture-private|fixture-engine-host|raw-private-engine-xml'

            $script:WebLayerComparisonNextProbe | Should -BeGreaterThan 0
            # Ensure the guard is still closed when a slow test host opens a new pipe.
            $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + (60L * [Diagnostics.Stopwatch]::Frequency)
            $busy = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
            ($busy | ConvertFrom-Json).error | Should -Be 'layer_comparison_busy'
            $script:WebLayerComparisonNextProbe = 0L
            $script:HealthFixtureDropped = 7
            $script:HealthFixtureLicense = 'Licensed'
            $raw = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
            $reply = $raw | ConvertFrom-Json
            $reply.data.license | Should -Be 'licensed'
            $reply.data.droppedSampleIncrease | Should -Be 3

            $script:WebLayerComparisonNextProbe = 0L
            $script:HealthFixtureDropped = 1
            $reply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line) | ConvertFrom-Json
            $reply.data.droppedSampleIncrease | Should -BeNullOrEmpty

            $script:WebLayerComparisonNextProbe = 0L
            $script:HealthFixtureSamples = 0
            $reply = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line) | ConvertFrom-Json
            $reply.data.health | Should -Be 'no_samples'
            $reply.data.outputFrames | Should -BeNullOrEmpty
            $script:LastEngineDropped | Should -Be 70
            Should -Invoke Get-AirTelemetryStatus -Exactly -Times 4 -ParameterFilter { $TimeoutSec -eq 1 }
            Should -Invoke Get-AirVideoStatus -Exactly -Times 4 -ParameterFilter { $TimeoutSec -eq 1 }
            Should -Invoke Get-AirMaterialSchedule -Exactly -Times 0
            Should -Invoke Send-AirCommand -Exactly -Times 0
        }
        finally {
            $script:WebLayerComparisonNextProbe = $oldProbe
            $script:WebEngineHealthBaseline = $oldBaseline
            $script:LastEngineDropped = $oldBotCount
            Remove-Variable -Name HealthFixtureSamples, HealthFixtureLicense, HealthFixtureDropped -Scope Script
        }
    }

    It 'reads the exact current and cued programme on demand through the named pipe' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Get-AirVideoStatus {
            @{ Success = $true; ActiveId = 'private-live-id'; CuedId = 'private-cued-id' }
        }
        Mock Get-AirMaterialSchedule { throw 'A fresh cache already contains both exact programme identities.' }
        Mock Send-AirCommand { throw 'Reading programmes must not issue an air command.' }
        $previousProbe = $script:WebLayerComparisonNextProbe
        $previousCache = $script:MaterialScheduleCache
        $previousCacheAt = $script:MaterialScheduleCacheAt
        $programmeFixtureTime = [datetimeoffset]::Now
        $script:WebLayerComparisonNextProbe = 0L
        $script:MaterialScheduleCacheAt = $programmeFixtureTime
        $script:MaterialScheduleCache = @(
            @{ Id = '{private-cued-id}'; Name = 'Cued fixture'; ScheduledAt = $programmeFixtureTime.AddMinutes(5); Duration = [timespan]::FromMinutes(15) }
            @{ Id = 'unrelated'; Name = 'Unrelated later programme'; ScheduledAt = $programmeFixtureTime.AddMinutes(1); Duration = [timespan]::FromMinutes(5) }
            @{ Id = '{private-live-id}'; Name = 'Live fixture'; ScheduledAt = $programmeFixtureTime.AddMinutes(-2); Duration = [timespan]::FromMinutes(10) }
        )
        $call = {
            param([long]$ProgrammeActor)
            $line = @{ op = 'air.programme'; args = @{ actor = $ProgrammeActor } } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
        }
        try {
            ((& $call 9876) | ConvertFrom-Json).error | Should -Be 'forbidden'
            Should -Invoke Get-AirVideoStatus -Times 0 -Exactly
            $wire = & $call 4321
            $snapshot = $wire | ConvertFrom-Json
            $snapshot.ok | Should -BeTrue
            $snapshot.data.statusAvailable | Should -BeTrue
            $snapshot.data.scheduleAvailable | Should -BeTrue
            $snapshot.data.current.label | Should -Be 'Live fixture'
            $snapshot.data.current.remainingSeconds | Should -BeGreaterThan 400
            $snapshot.data.cued.label | Should -Be 'Cued fixture'
            $snapshot.data.cued.remainingSeconds | Should -BeNullOrEmpty
            $wire | Should -Not -Match 'private-live-id|private-cued-id|Unrelated later programme'
            $script:WebLayerComparisonNextProbe | Should -BeGreaterThan 0
            $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + 15 * [Diagnostics.Stopwatch]::Frequency
            ((& $call 4321) | ConvertFrom-Json).error | Should -Be 'layer_comparison_busy'
            Should -Invoke Get-AirVideoStatus -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 1 }
            Should -Invoke Get-AirMaterialSchedule -Times 0 -Exactly
            Should -Invoke Send-AirCommand -Times 0 -Exactly
        }
        finally {
            $script:WebLayerComparisonNextProbe = $previousProbe
            $script:MaterialScheduleCache = $previousCache
            $script:MaterialScheduleCacheAt = $previousCacheAt
        }
    }

    It 'distinguishes missing cued programme data through the named pipe' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Get-AirVideoStatus {
            if ($script:FixtureProgrammeOffline) { return @{ Success = $false; Error = 'fixture-engine-address' } }
            return @{ Success = $true; ActiveId = 'private-live-id'; CuedId = 'private-cued-id' }
        }
        Mock Get-AirMaterialSchedule {
            @{ Success = $true; Items = @(
                @{ Id = 'private-live-id'; Name = 'X:\fixture-private\programme.mp4'; ScheduledAt = [datetimeoffset]::MinValue; Duration = [timespan]::Zero }
                @{ Id = 'some-other-item'; Name = 'Unrelated programme'; ScheduledAt = [datetimeoffset]::Now.AddMinutes(2); Duration = [timespan]::FromMinutes(10) }
            ) }
        }
        $previousProbe = $script:WebLayerComparisonNextProbe
        $previousCacheAt = $script:MaterialScheduleCacheAt
        $script:MaterialScheduleCacheAt = [datetime]::MinValue
        $script:WebLayerComparisonNextProbe = 0L
        $script:FixtureProgrammeOffline = $false
        $line = '{"op":"air.programme","args":{"actor":4321}}'
        try {
            $wire = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
            $snapshot = $wire | ConvertFrom-Json
            $snapshot.ok | Should -BeTrue
            $snapshot.data.current.listed | Should -BeTrue
            $snapshot.data.current.label | Should -BeNullOrEmpty
            $snapshot.data.current.startsAtMs | Should -BeNullOrEmpty
            $snapshot.data.cued.listed | Should -BeFalse
            $snapshot.data.scheduleAvailable | Should -BeTrue
            $wire | Should -Not -Match 'fixture-private|Unrelated programme'
            $script:WebLayerComparisonNextProbe = 0L
            $script:FixtureProgrammeOffline = $true
            $wire = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
            $outage = $wire | ConvertFrom-Json
            $outage.ok | Should -BeTrue
            $outage.data.statusAvailable | Should -BeFalse
            $outage.data.current | Should -BeNullOrEmpty
            $outage.data.cued | Should -BeNullOrEmpty
            $wire | Should -Not -Match 'fixture-engine-address'
            Should -Invoke Get-AirMaterialSchedule -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 1 }
        }
        finally {
            $script:WebLayerComparisonNextProbe = $previousProbe
            $script:MaterialScheduleCacheAt = $previousCacheAt
            Remove-Variable -Name FixtureProgrammeOffline -Scope Script
        }
    }

    It 'compares an authorized layer through the named pipe without reconciling or exposing raw Cinegy data' {
        Mock Test-Authorized { $UserId -in 4321, 9876 }
        Mock Test-LayersScreenAccess { $UserId -eq 4321 }
        Mock Get-KnownLayers { @(4, 5) }
        Mock Get-WebLayerNameSafe { "Fixture layer $Layer" }
        Mock Get-WebLayerStatus {
            @{
                Success = $true; IsOnAir = $false; ActiveId = 'fixture-private-active'
                ActiveXml = '<RawFixture />'; ClientIdentity = 'fixture-private-station'
            }
        }
        Mock Update-OnAirStateFromCinegy { throw 'Comparison must not invoke reconciliation.' }
        Mock Restore-UrgentBoardLine { throw 'Comparison must not attempt to restore graphics.' }
        Mock Save-OnAirState { throw 'Comparison must not save on-air state.' }
        $oldOnAir = $script:OnAir
        $oldProbe = $script:WebLayerComparisonNextProbe
        $script:OnAir = @{ 5 = [pscustomobject]@{ Key = 'fixture-record'; ActiveId = 'fixture-private-prior' } }
        $script:WebLayerComparisonNextProbe = 0L
        $call = {
            param([hashtable]$Values)
            $line = @{ op = 'air.layer-comparison'; args = $Values } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
        }
        try {
            ((& $call @{ actor = 9876; layer = 5 }) | ConvertFrom-Json).error | Should -Be 'forbidden'
            $targets = (& $call @{ actor = 4321 }) | ConvertFrom-Json
            $targets.ok | Should -BeTrue
            @($targets.data.layers).Count | Should -Be 2
            $targets.data.layers.layer | Should -Contain 4
            $targets.data.layers.layer | Should -Contain 5
            ((& $call @{ actor = 4321; layer = 82 }) | ConvertFrom-Json).error | Should -Be 'layer_comparison_missing'
            Should -Invoke Get-WebLayerStatus -Exactly -Times 0
            $wire = & $call @{ actor = 4321; layer = 5 }
            $result = $wire | ConvertFrom-Json
            $result.ok | Should -BeTrue
            $result.data.disposition | Should -Be 'remove'
            $result.data.tracked | Should -BeTrue
            $result.data.engineActive | Should -BeFalse
            $wire | Should -Not -Match 'fixture-private-|RawFixture'
            $script:OnAir[5].ActiveId | Should -Be 'fixture-private-prior'
            Should -Invoke Get-WebLayerStatus -Exactly -Times 1 -ParameterFilter { $Layer -eq 5 -and $TimeoutSec -eq 2 }
            Should -Invoke Update-OnAirStateFromCinegy -Exactly -Times 0
            Should -Invoke Restore-UrgentBoardLine -Exactly -Times 0
            Should -Invoke Save-OnAirState -Exactly -Times 0
        }
        finally {
            $script:OnAir = $oldOnAir
            $script:WebLayerComparisonNextProbe = $oldProbe
        }
    }

    It 'keeps emergency scope review separate from air commands through the named pipe' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Get-KnownLayers { @(4, 5) }
        Mock Get-LayerName { "Fixture layer $Layer" }
        Mock Get-Setting { 'all' } -ParameterFilter { $Name -eq 'HideAllLayers' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableHideAll' }
        Mock Save-HideAllLayerScope { @{ ok = $true } }
        Mock Invoke-HideLayer { throw 'Scope editing must not issue HIDE.' }
        $oldReviews = $script:WebHideAllLayerScopeReviews
        $script:WebHideAllLayerScopeReviews = @{}
        $call = {
            param([string]$Operation, [hashtable]$Values)
            $line = @{ op = $Operation; args = $Values } | ConvertTo-Json -Depth 4 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $scope = & $call 'air.hideAllScope' @{ actor = 4322 }
            $scope.data.mode | Should -Be 'all'
            $scope.data.canManage | Should -BeFalse
            (& $call 'air.hideAllScope.review' @{ actor = 4322; revision = $scope.data.revision; mode = 'none' }).error | Should -Be 'forbidden'
            $review = & $call 'air.hideAllScope.review' @{ actor = 4321; revision = $scope.data.revision; mode = 'none' }
            $review.ok | Should -BeTrue
            Should -Invoke Save-HideAllLayerScope -Exactly -Times 0
            $confirm = @{ actor = 4321; review = $review.data.review }
            (& $call 'air.hideAllScope.confirm' $confirm).ok | Should -BeTrue
            (& $call 'air.hideAllScope.confirm' $confirm).error | Should -Be 'hide_all_scope_stale'
            Should -Invoke Save-HideAllLayerScope -Exactly -Times 1 -ParameterFilter { $Mode -eq 'none' -and $UserId -eq 4321 }
            Should -Invoke Invoke-HideLayer -Exactly -Times 0
        }
        finally { $script:WebHideAllLayerScopeReviews = $oldReviews }
    }

    It 'shows and acknowledges only the actors current follow-up reminders through the named pipe' {
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Get-TemplateReminderTargetDecision { @{ ShouldNotify = $true } }
        Mock Save-TemplateReminderQueue { $true }
        $oldQueue = $script:TemplateReminderQueue
        $oldSeed = [datetimeoffset]::Now.AddMinutes(15)
        $script:TemplateReminderQueue = [System.Collections.Generic.List[hashtable]]::new([hashtable[]]@(
            @{ ReminderId = 'fixture-own'; UserId = 4321; TemplateKey = 'own-fixture'; Stage = 'followup'; Layer = 4; At = $oldSeed; Minutes = 15 }
            @{ ReminderId = 'fixture-other'; UserId = 4322; TemplateKey = 'other-fixture'; Stage = 'followup'; Layer = 5; At = $oldSeed; Minutes = 15 }
            @{ ReminderId = 'fixture-initial'; UserId = 4321; TemplateKey = 'initial-fixture'; Stage = 'initial'; Layer = 4; At = $oldSeed; Minutes = 15 }
        ))
        $call = {
            param([string]$Operation, [hashtable]$Values)
            $line = @{ op = $Operation; args = $Values } | ConvertTo-Json -Depth 4 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $list = & $call 'air.personalReminders' @{ actor = 4321 }
            $list.data.items.id | Should -Be 'fixture-own'
            $list.data.snoozeMinutes | Should -Be 5
            $command = @{ actor = 4321; id = 'fixture-other'; action = 'acknowledge' }
            (& $call 'air.personalReminder.act' $command).error | Should -Be 'reminder_stale'
            $command.id = 'fixture-own'
            $ack = & $call 'air.personalReminder.act' $command
            $ack.ok | Should -BeTrue
            @($ack.data.items).Count | Should -Be 0
            (& $call 'air.personalReminder.act' $command).error | Should -Be 'reminder_stale'
            $script:TemplateReminderQueue.ReminderId | Should -Contain 'fixture-other'
            $script:TemplateReminderQueue.ReminderId | Should -Contain 'fixture-initial'
            Should -Invoke Save-TemplateReminderQueue -Exactly -Times 1
        }
        finally { $script:TemplateReminderQueue = $oldQueue }
    }

    It 'requires an actor-owned review for local external layer adoption through the named pipe' {
        Mock Test-Authorized { $UserId -in 4321, 4876 }
        Mock Test-LayersScreenAccess { $true }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-AirRunActive { $false }
        Mock Test-PermanentGraphicAutoHideProtected { $false }
        Mock Get-KnownLayers { @(4) }
        Mock Get-Setting { 'Single' } -ParameterFilter { $Name -eq 'SceneMode' }
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'PendingStateTimeoutMinutes' }
        Mock Get-TemplateStore { @{ Map = @{ ExternalFixture = @{ Layer = 4; Key = 'ExternalFixture' } } } }
        Mock Resolve-AirGfxDevice { @{ StatusPath = "gfx_$Layer" } }
        Mock Get-OnAirDiscoveryDiskRevision { 'fixture-state-version' }
        Mock Get-WebLayerStatus {
            @{ Success = $true; IsOnAir = $true; ActiveName = 'redacted-fixture'; ActiveTemplateName = 'ExternalFixture'
                ActiveId = '{4bc680c0-044d-42a3-b6e7-201a81df24c2}' }
        }
        Mock Get-CinegyStatusStartTicks { 3001L }
        Mock Save-ReviewedOnAirDiscovery { 'saved' }
        Mock Update-OnAirStateFromCinegy { throw 'Adoption must not invoke unrestricted reconciliation.' }
        Mock Publish-WebChannelState {}
        $old = @{
            OnAir = $script:OnAir; Scenes = $script:OnAirScenes; Boards = $script:BoardsLive
            Urgent = $script:UrgentManualLive; Hides = $script:AutoHideQueue; Reminders = $script:TemplateReminderQueue
            Probe = $script:WebLayerComparisonNextProbe
        }
        $script:OnAir = @{}
        $script:OnAirScenes = [Collections.Generic.List[object]]::new()
        $script:BoardsLive = @{}
        $script:UrgentManualLive = @{}
        $script:AutoHideQueue = @()
        $script:TemplateReminderQueue = @()
        $script:WebLayerAdoptionReviews.Clear()
        $call = {
            param([string]$Action, [long]$Actor, [string]$Review = '')
            $script:WebLayerComparisonNextProbe = 0L
            $line = @{ op = "air.layer-adoption.$Action"; args = @{ actor = $Actor; layer = 4; review = $Review } } |
                ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $review = & $call review 4321
            $review.ok | Should -BeTrue
            $review.data.templateKey | Should -Be 'ExternalFixture'
            Should -Invoke Save-ReviewedOnAirDiscovery -Exactly -Times 0
            (& $call confirm 4876 $review.data.review).error | Should -Be 'layer_adoption_stale'
            (& $call confirm 4321 $review.data.review).data.adopted | Should -BeTrue
            (& $call confirm 4321 $review.data.review).error | Should -Be 'layer_adoption_stale'
            Should -Invoke Save-ReviewedOnAirDiscovery -Exactly -Times 1
            Should -Invoke Update-OnAirStateFromCinegy -Exactly -Times 0
        }
        finally {
            $script:OnAir = $old.OnAir
            $script:OnAirScenes = $old.Scenes
            $script:BoardsLive = $old.Boards
            $script:UrgentManualLive = $old.Urgent
            $script:AutoHideQueue = $old.Hides
            $script:TemplateReminderQueue = $old.Reminders
            $script:WebLayerComparisonNextProbe = $old.Probe
            $script:WebLayerAdoptionReviews.Clear()
        }
    }

    It 'reports test-layer readiness through the named pipe without invoking a self-test or sending commands' {
        Mock Test-Authorized { $UserId -in 4321, 9876 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-MaintenanceControl { $true } -ParameterFilter { $Quiet }
        Mock Get-Setting { 'Single' } -ParameterFilter { $Name -eq 'SceneMode' }
        Mock Get-SettingInt { 87 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-TemplateStore {
            @{ Map = @{ PrivateScene = @{ Layer = 4; Path = 'C:\private-scene.cintitle' } }; Order = @('PrivateScene') }
        }
        Mock Get-TemplateTestLayerConflict { @() }
        Mock Test-PermanentGraphicAutoHideProtected { $false }
        Mock Resolve-AirGfxDevice { @{ StatusPath = "gfx_$Layer" } }
        Mock Get-WebLayerStatus {
            @{ Success = $true; IsOnAir = $false; ActiveId = 'PrivateEventId'; ActiveXml = '<PrivateFixture />' }
        }
        Mock Invoke-BridgeSelfTest { throw 'Readiness must not invoke the runner.' }
        Mock Show-TitlerTemplate { throw 'Readiness must not send SHOW.' }
        Mock Exit-TitlerScene { throw 'Readiness must not send EXIT.' }
        Mock Hide-TitlerTemplate { throw 'Readiness must not send HIDE.' }
        $oldOnAir = $script:OnAir
        $oldProbe = $script:WebLayerComparisonNextProbe
        $script:OnAir = @{}
        $script:WebLayerComparisonNextProbe = 0L
        try {
            $denied = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.self-test.readiness","args":{"actor":9876}}' |
                ConvertFrom-Json
            $denied.error | Should -Be 'forbidden'
            Should -Invoke Get-WebLayerStatus -Exactly -Times 0
            $response = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.self-test.readiness","args":{"actor":4321}}'
            $result = $response | ConvertFrom-Json
            $result.ok | Should -BeTrue
            $result.data.layer | Should -Be 87
            $result.data.engine | Should -Be 'idle'
            $result.data.findings | Should -Contain 'dedicated_scene_unavailable'
            $result.data.findings | Should -Contain 'identity_cleanup_unavailable'
            $response | Should -Not -Match 'PrivateScene|private-scene|PrivateEventId|PrivateFixture'
            Should -Invoke Get-WebLayerStatus -Exactly -Times 1 -ParameterFilter { $Layer -eq 87 -and $TimeoutSec -eq 1 -and $RequireConsistentIdentity }
            Should -Invoke Test-MaintenanceControl -Exactly -Times 1 -ParameterFilter { $Quiet }
            Should -Invoke Invoke-BridgeSelfTest -Exactly -Times 0
            Should -Invoke Show-TitlerTemplate -Exactly -Times 0
            Should -Invoke Exit-TitlerScene -Exactly -Times 0
            Should -Invoke Hide-TitlerTemplate -Exactly -Times 0
        }
        finally {
            $script:OnAir = $oldOnAir
            $script:WebLayerComparisonNextProbe = $oldProbe
        }
    }

    It 'delivers the administrator usage summary through the named pipe without returning audit values' {
        Mock Test-Authorized { $UserId -in 4321, 9876 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Get-ReportRecords {
            @{ Records = @(@{ UserId = 'private-audit-user'; Values = 'private-audit-values' }); Truncated = $true }
        }
        Mock Invoke-ShowTemplateResult { throw 'Usage summary must not execute an air command.' }
        $oldCounts = $script:UsageCounts
        $oldLastUse = $script:TemplateLastUsed
        $oldOutcomes = $script:AirOperationCounters
        $script:UsageCounts = @{ 'C:\private-fixture-template.cintitle' = 18; Accessible = 12 }
        $script:TemplateLastUsed = @{ Accessible = [datetime]'2026-01-13T09:00:00Z' }
        $script:AirOperationCounters = @{ Success = 3; Failed = 2; Blocked = 1 }
        try {
            $denied = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.usage-summary","args":{"actor":9876}}' |
                ConvertFrom-Json
            $denied.error | Should -Be 'forbidden'
            Should -Invoke Get-ReportRecords -Exactly -Times 0
            $response = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"admin.usage-summary","args":{"actor":4321}}'
            $result = $response | ConvertFrom-Json
            $result.ok | Should -BeTrue
            $result.data.successful | Should -Be 3
            $result.data.failed | Should -Be 2
            $result.data.blocked | Should -Be 1
            $result.data.sevenDayOperations | Should -Be 1
            $result.data.sevenDayTruncated | Should -BeTrue
            $result.data.templates[0].name | Should -BeNullOrEmpty
            $result.data.templates[1].name | Should -Be 'Accessible'
            $result.data.templates[1].lastUsedAt | Should -BeGreaterThan 0
            $response | Should -Not -Match 'private-audit-|private-fixture-template'
            Should -Invoke Get-ReportRecords -Exactly -Times 1 -ParameterFilter { $EventName -ceq 'air_control' }
            Should -Invoke Invoke-ShowTemplateResult -Exactly -Times 0
        }
        finally {
            $script:UsageCounts = $oldCounts
            $script:TemplateLastUsed = $oldLastUse
            $script:AirOperationCounters = $oldOutcomes
        }
    }

    It 'replaces a stale external layer with a fresh unowned scene through the named pipe and atomic ledger' {
        Mock Test-Authorized { $UserId -in 4321, 4876 }
        Mock Test-LayersScreenAccess { $true }
        Mock Test-TemplateAccess { @{ Allowed = ($Key -ne $script:FixtureReplacementDeniedKey) } }
        Mock Test-AirRunActive { $false }
        Mock Test-PermanentGraphicAutoHideProtected { $false }
        Mock Get-KnownLayers { @(4, 5) }
        Mock Get-Setting { 'Single' } -ParameterFilter { $Name -eq 'SceneMode' }
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'PendingStateTimeoutMinutes' }
        Mock Get-TemplateStore {
            @{ Map = @{
                OldFixture = @{ Layer = 4; Key = 'OldFixture'; Path = 'old-fixture.cintitle'; PresetRevision = 'old-v1' }
                NewFixture = @{ Layer = 4; Key = 'NewFixture'; Path = 'new-fixture.cintitle'; PresetRevision = 'new-v1' }
            } }
        }
        Mock Resolve-AirGfxDevice { @{ StatusPath = "gfx_$Layer" } }
        Mock Get-UpcomingScheduleEvents { $script:FixtureReplacementSchedule }
        Mock Get-WebLayerStatus {
            if (-not $RequireConsistentIdentity) { throw 'Replacement requires a consistent identity read.' }
            $reportedEvent = '4bc680c0-044d-42a3-b6e7-201a81df24c2'
            $detailEvent = $script:FixtureReplacementDetail
            $detailStart = $script:FixtureReplacementStart
            @{
                Success = $true; IsOnAir = $true; ActiveId = $reportedEvent
                ActiveTemplateName = 'NewFixture'; ActiveName = 'private fixture event text'
                ActiveXml = "<Item Id=`"$detailEvent`" IsEmpty=`"n`" ScheduledAt=`"$detailStart`" Name=`"private fixture event text`" />"
            }
        }
        Mock Update-OnAirStateFromCinegy { throw 'The reviewed writer must not reconcile or restore air.' }
        Mock Invoke-HideLayer { throw 'Reconciliation must not issue an air command.' }
        Mock Send-AirCommand { throw 'Reconciliation must not issue an air command.' }
        Mock Publish-WebChannelState {}
        $original = @{
            onAirFile = $script:onAirFile; OnAir = $script:OnAir; Scenes = $script:OnAirScenes; Boards = $script:BoardsLive
            Urgent = $script:UrgentManualLive; Hides = $script:AutoHideQueue; Reminders = $script:TemplateReminderQueue
            Shows = $script:LastSuccessfulLayerShows; Rollback = $script:RollbackCandidates; Probe = $script:WebLayerComparisonNextProbe
            MojazSchedules = $script:MojazSchedules
        }
        $script:onAirFile = Join-Path $TestDrive 'external-layer-replacement.json'
        $script:OnAir = @{}
        $script:OnAirScenes = [Collections.Generic.List[object]]::new()
        $script:BoardsLive = @{}
        $script:UrgentManualLive = @{}
        $script:AutoHideQueue = @()
        $script:TemplateReminderQueue = @()
        $script:LastSuccessfulLayerShows = @{}
        $script:RollbackCandidates = @{}
        $script:MojazSchedules = @()
        $script:FixtureReplacementSchedule = @()
        $script:FixtureReplacementDeniedKey = ''
        $script:FixtureReplacementDetail = '4bc680c0-044d-42a3-b6e7-201a81df24c2'
        $script:FixtureReplacementStart = '2026-11-21T12:00:00Z'
        $script:WebLayerReplacementReviews.Clear()
        Set-OnAirLayerRecord -Layer 4 -Record @{
            Key = 'OldFixture'; Source = 'cinegy'; UserId = 0L; ChatId = 0L
            ActiveId = 'f691112c-e6a9-4397-9d00-703c977022f3'; At = [datetime]'2026-11-21T11:00:00Z'
        }
        Set-OnAirLayerRecord -Layer 5 -Record @{
            Key = 'PeerFixture'; Source = 'bridge'; UserId = 99L; ChatId = 99L; ActiveIdConfirmed = $true
            ActiveId = '1b28dae7-6e04-43ba-9531-29e8311398e4'; At = [datetime]'2026-11-21T11:00:00Z'
        }
        $script:OnAirScenes[1] | Add-Member -NotePropertyName Extension -NotePropertyValue 'keep-peer-extension'
        $localId = $script:OnAirScenes[0].SceneId
        $peer = $script:OnAirScenes[1]
        $before = ConvertTo-Json -InputObject @{ SchemaVersion = 1; Scenes = @($script:OnAirScenes) } -Depth 6
        [IO.File]::WriteAllText($script:onAirFile, $before)
        $call = {
            param([string]$Action, [long]$Actor = 4321, [string]$Review = '')
            $script:WebLayerComparisonNextProbe = 0L
            $line = @{ op = "air.layer-replacement.$Action"; args = @{ actor = $Actor; layer = 4; review = $Review } } |
                ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $call review 9999).error | Should -Be 'forbidden'
            $script:FixtureReplacementSchedule = @(@{ TemplateKey = 'NewFixture' })
            (& $call review).error | Should -Be 'layer_replacement_unavailable'
            $script:FixtureReplacementSchedule = @()
            $script:FixtureReplacementDeniedKey = 'NewFixture'
            (& $call review).error | Should -Be 'forbidden'
            $script:FixtureReplacementDeniedKey = ''
            $script:FixtureReplacementDetail = 'f691112c-e6a9-4397-9d00-703c977022f3'
            (& $call review).error | Should -Be 'layer_replacement_unavailable'
            $script:FixtureReplacementDetail = '4bc680c0-044d-42a3-b6e7-201a81df24c2'

            $review = & $call review
            $review.ok | Should -BeTrue
            $review.data.oldTemplateKey | Should -Be 'OldFixture'
            $review.data.templateKey | Should -Be 'NewFixture'
            ($review | ConvertTo-Json -Depth 5) | Should -Not -Match 'private fixture|f691112c|4bc680c0'
            (& $call confirm 4876 $review.data.review).error | Should -Be 'layer_replacement_stale'
            $script:FixtureReplacementStart = '2026-11-21T12:00:30Z'
            (& $call confirm 4321 $review.data.review).error | Should -Be 'layer_replacement_stale'
            [IO.File]::ReadAllText($script:onAirFile) | Should -BeExactly $before

            $review = & $call review
            [IO.File]::AppendAllText($script:onAirFile, [Environment]::NewLine)
            (& $call confirm 4321 $review.data.review).error | Should -Be 'layer_replacement_stale'
            $review = & $call review
            New-Item -Path "$script:onAirFile.bak" -ItemType Directory | Out-Null
            (& $call confirm 4321 $review.data.review).error | Should -Be 'layer_replacement_save_failed'
            [IO.File]::ReadAllText($script:onAirFile) | Should -BeExactly ($before + [Environment]::NewLine)
            $script:OnAirScenes[0].SceneId | Should -Be $localId
            Remove-Item -LiteralPath "$script:onAirFile.bak"

            $review = & $call review
            (& $call confirm 4321 $review.data.review).data.replaced | Should -BeTrue
            (& $call confirm 4321 $review.data.review).error | Should -Be 'layer_replacement_stale'
            $newScene = $script:OnAirScenes[0]
            $newScene.SceneId | Should -Not -Be $localId
            $newScene.ActiveIdConfirmed | Should -BeFalse
            $newScene.Source | Should -BeExactly 'cinegy'
            $newScene.UserId | Should -Be 0
            $newScene.ChatId | Should -Be 0
            $script:OnAir[4].Key | Should -BeExactly 'NewFixture'
            [object]::ReferenceEquals($peer, $script:OnAirScenes[1]) | Should -BeTrue
            $disk = Get-Content -LiteralPath $script:onAirFile -Raw | ConvertFrom-Json
            $disk.Scenes[0].SceneId | Should -Be $newScene.SceneId
            $disk.Scenes[1].Extension | Should -Be 'keep-peer-extension'
            $disk.Scenes[1].ActiveIdConfirmed | Should -BeTrue
            Should -Invoke Publish-WebChannelState -Exactly -Times 1
            Should -Invoke Invoke-HideLayer -Exactly -Times 0
            Should -Invoke Send-AirCommand -Exactly -Times 0
        }
        finally {
            foreach ($entry in $original.GetEnumerator()) { Set-Variable -Scope Script -Name $entry.Key -Value $entry.Value }
            Remove-Variable -Scope Script -Name FixtureReplacementSchedule, FixtureReplacementDeniedKey, FixtureReplacementDetail, FixtureReplacementStart
            $script:WebLayerReplacementReviews.Clear()
        }
    }

    It 'reviews forgetting exactly one stale external record through the named pipe without touching air' {
        Mock Test-Authorized { $UserId -in 4321, 4876 }
        Mock Test-LayersScreenAccess { $true }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-AirRunActive { $false }
        Mock Test-PermanentGraphicAutoHideProtected { $false }
        Mock Get-KnownLayers { @(4) }
        Mock Get-Setting { 'Single' } -ParameterFilter { $Name -eq 'SceneMode' }
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'PendingStateTimeoutMinutes' }
        Mock Get-TemplateStore { @{ Map = @{ ExternalFixture = @{ Layer = 4; Key = 'ExternalFixture' } } } }
        Mock Resolve-AirGfxDevice { @{ StatusPath = "gfx_$Layer" } }
        Mock Read-ReviewedOnAirDocument { @{ Revision = 'fixture-state-version'; Scenes = @($script:OnAirScenes) } }
        Mock Get-WebLayerStatus {
            @{
                Success = $true; IsOnAir = $false; OffAirReason = 'empty-item'; ActiveId = '{4bc680c0-044d-42a3-b6e7-201a81df24c2}'
                ActiveXml = '<Item Id="{4bc680c0-044d-42a3-b6e7-201a81df24c2}" IsEmpty="y" ScheduledAt="2026-11-21T12:00:00Z" />'
            }
        }
        Mock Save-ReviewedOnAirForget { 'saved' }
        Mock Update-OnAirStateFromCinegy { throw 'Local cleanup must not invoke unrestricted reconciliation.' }
        Mock Restore-UrgentBoardLine { throw 'Local cleanup must not attempt to restore graphics.' }
        Mock Invoke-HideLayer { throw 'Local cleanup must not send HIDE.' }
        Mock Publish-WebChannelState {}
        $old = @{
            OnAir = $script:OnAir; Scenes = $script:OnAirScenes; Boards = $script:BoardsLive
            Urgent = $script:UrgentManualLive; Hides = $script:AutoHideQueue; Reminders = $script:TemplateReminderQueue
            Shows = $script:LastSuccessfulLayerShows; Rollback = $script:RollbackCandidates; Probe = $script:WebLayerComparisonNextProbe
        }
        $script:OnAir = @{}
        $script:OnAirScenes = [Collections.Generic.List[object]]::new()
        $script:BoardsLive = @{}
        $script:UrgentManualLive = @{}
        $script:AutoHideQueue = @()
        $script:TemplateReminderQueue = @()
        $script:LastSuccessfulLayerShows = @{}
        $script:RollbackCandidates = @{}
        $script:WebLayerForgetReviews.Clear()
        Set-OnAirLayerRecord -Layer 4 -Record @{
            Key = 'ExternalFixture'; Source = 'cinegy'; ActiveId = '{f691112c-e6a9-4397-9d00-703c977022f3}'; At = [datetime]'2026-11-21T11:00:00Z'
        }
        $call = {
            param([string]$Action, [long]$Actor, [string]$Review = '')
            $script:WebLayerComparisonNextProbe = 0L
            $line = @{ op = "air.layer-forget.$Action"; args = @{ actor = $Actor; layer = 4; review = $Review } } |
                ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $review = & $call review 4321
            $review.ok | Should -BeTrue
            $review.data.templateKey | Should -Be 'ExternalFixture'
            Should -Invoke Save-ReviewedOnAirForget -Exactly -Times 0
            (& $call confirm 4876 $review.data.review).error | Should -Be 'layer_forget_stale'
            (& $call confirm 4321 $review.data.review).data.forgotten | Should -BeTrue
            (& $call confirm 4321 $review.data.review).error | Should -Be 'layer_forget_stale'
            Should -Invoke Save-ReviewedOnAirForget -Exactly -Times 1
            Should -Invoke Update-OnAirStateFromCinegy -Exactly -Times 0
            Should -Invoke Restore-UrgentBoardLine -Exactly -Times 0
            Should -Invoke Invoke-HideLayer -Exactly -Times 0
        }
        finally {
            $script:OnAir = $old.OnAir
            $script:OnAirScenes = $old.Scenes
            $script:BoardsLive = $old.Boards
            $script:UrgentManualLive = $old.Urgent
            $script:AutoHideQueue = $old.Hides
            $script:TemplateReminderQueue = $old.Reminders
            $script:LastSuccessfulLayerShows = $old.Shows
            $script:RollbackCandidates = $old.Rollback
            $script:WebLayerComparisonNextProbe = $old.Probe
            $script:WebLayerForgetReviews.Clear()
        }
    }

    It 'lists searchable Telegram presence for administrators through the private named pipe' {
        Mock Test-Authorized { $UserId -in 4321, 4876, 9876 }
        Mock Test-Admin { $UserId -in 4321, 4876 }
        Mock Get-AuthorizedUsers {
            @(
                @{ UserId = 4876L; Alias = 'Fixture Owner'; Role = 'owner'; Disabled = $false; LastActivityAt = '2026-11-21T12:00:01Z' }
                @{ UserId = 4321L; Alias = 'Fixture Admin'; Role = 'admin'; Disabled = $false; LastActivityAt = '' }
                @{
                    UserId = 9876L; Alias = 'Fixture Operator'; Role = 'operator'; Disabled = $true; LastActivityAt = '2026-11-21T11:00:01Z'
                    RawMessage = 'private-fixture-payload'; IP = '192.0.2.23'
                }
                @{ UserId = 9000000000000011L; Alias = 'Browser-only'; Role = 'operator'; Disabled = $false; LastActivityAt = '2026-11-21T13:00:01Z' }
            )
        }
        Mock Get-WorkReportData { throw 'Presence must not read detailed audit records.' }
        $call = {
            param([long]$Actor, [string]$Query = '', [int]$Page = 0)
            $line = @{ op = 'telegram.access.presence'; args = @{ actor = $Actor; q = $Query; page = $Page } } |
                ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line
        }
        ((& $call 9876) | ConvertFrom-Json).error | Should -Be 'forbidden'
        Should -Invoke Get-AuthorizedUsers -Exactly -Times 0
        $wire = & $call 4321
        $result = $wire | ConvertFrom-Json
        $result.ok | Should -BeTrue
        $result.data.total | Should -Be 3
        @($result.data.items).Count | Should -Be 3
        $result.data.items[0].role | Should -Be 'owner'
        $result.data.items[1].disabled | Should -BeTrue
        $result.data.items[2].lastSeenAt | Should -BeNullOrEmpty
        $wire | Should -Not -Match 'private-fixture-payload|192\.0\.2\.23|Browser-only|UserId'
        $found = (& $call 4876 'fIxTuRe AdMiN' 99) | ConvertFrom-Json
        $found.ok | Should -BeTrue
        $found.data.total | Should -Be 1
        $found.data.page | Should -Be 0
        $found.data.items[0].role | Should -Be 'admin'
        Should -Invoke Get-WorkReportData -Exactly -Times 0
    }

    It 'rechecks air permissions before loading sensitive scene data through the named pipe' {
        Mock Test-Authorized { $false }
        Mock Get-TitlerLayerStatus { throw 'A denied request must not probe a layer.' }
        foreach ($operation in @('air.rollback', 'air.text', 'air.timer', 'air.maintenance', 'air.emergency-hide', 'air.layer-removal', 'air.template-backups')) {
            $line = @{ op = $operation; args = @{ actor = 4321; layer = 9; action = 'preview' } } | ConvertTo-Json -Depth 5 -Compress
            $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $reply.error | Should -Be 'forbidden'
        }
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
    }

    It 'refuses to review an occupied layer when Cinegy has no verifiable start for the repeat' {
        Mock Test-Authorized { $true }
        Mock Test-MaintenanceControl { $true }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-TemplateShowPolicy { @{ Allowed = $true } }
        Mock Get-TemplatePresetRegistryRevision { 'fixture-revision' }
        Mock Resolve-AirGfxDevice { @{ StatusPath = 'gfx_7' } }
        Mock Get-TemplateStore { @{ Map = @{ Guest = @{ Key = 'Guest'; Layer = 7; Path = 'guest.cintitle'; PresetRevision = 'fixture-revision'; Fields = @() } } } }
        Mock Get-WebLayerStatus { @{ Success = $true; IsOnAir = $true; ActiveId = 'known-id'; ActiveXml = '' } }
        Mock Invoke-ShowTemplateResult {}
        $savedHistory = $script:LastShow
        $script:LastShow = @{ ([long]4321) = @{ Key = 'Guest'; Variables = @{} } }
        try {
            $line = @{ op = 'air.rerun'; args = @{ actor = 4321; kind = 'repeat'; action = 'preview' } } | ConvertTo-Json -Depth 5 -Compress
            $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            $reply.error | Should -Be 'rerun_unverified'
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        }
        finally { $script:LastShow = $savedHistory }
    }

    It 'rehearses a selected template with sample values only on the reviewed isolated device' {
        $templateFile = Join-Path $TestDrive 'web-rehearsal.cintitle'
        Set-Content -LiteralPath $templateFile -Value '<Scene />'
        $script:WebTemplateTrialPath = $templateFile
        $script:WebTemplateTrialOccupied = $false
        $script:WebTemplateTrialMaintenance = $true
        $script:WebTemplateTrialAlias = $false
        $script:WebTemplateTrialMode = 'Single'
        $script:WebTemplateRehearsalReviews = @{}
        Mock Test-Authorized { $true }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-MaintenanceControl { $script:WebTemplateTrialMaintenance }
        Mock Test-TemplateAccess { @{ Allowed = $true } }
        Mock Test-PermanentGraphicAutoHideProtected { $false }
        Mock Get-TemplateStore {
            @{ Map = @{ Programme = @{
                        Key = 'Programme'; Layer = 5; Path = $script:WebTemplateTrialPath; Description = 'بطاقة البرنامج'
                        Fields = @('title', 'enabled', 'picture'); FieldLabels = @('العنوان', 'التفعيل', 'الصورة')
                        FieldLimits = @(2, 0, 0); FieldRequired = @($true, $false, $false)
                        FieldTypes = @{ enabled = 'Bool' }
                    } } }
        }
        Mock Get-MojazDesignFields { @{ Name = 'picture'; Kind = 'media' } }
        Mock Resolve-AirGfxDevice {
            $actualLayer = if ($Layer -eq 5 -and $script:WebTemplateTrialAlias) { 9 } else { $Layer }
            @{ StatusPath = "gfx_$actualLayer" }
        }
        Mock Get-Setting { Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableFullTemplateManagement' }
        Mock Get-Setting { $script:WebTemplateTrialMode } -ParameterFilter { $Name -eq 'SceneMode' }
        Mock Get-SettingInt { Get-BridgeSettingInt -Config $config -Defaults $script:DefaultSettings -Name $Name -Minimum $Minimum }
        Mock Get-SettingInt { 9 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-SettingInt { 10 } -ParameterFilter { $Name -eq 'TemplateTestAutoHideSeconds' }
        Mock Get-WebLayerStatus {
            @{ Success = $true; IsOnAir = $script:WebTemplateTrialOccupied; ActiveId = '{foreign}' }
        }
        Mock Show-TitlerTemplate {
            $script:WebTemplateTrialLatestDeadline = [datetimeoffset]::Now.AddSeconds(10)
            @{ Success = $true; EventId = '{our-rehearsal}' }
        }
        Mock Get-VerifiedCinegyShowIdentity { @{ Success = $true; ActiveId = '{our-rehearsal}' } }
        Mock Save-OnAirState {}
        Mock Set-AutoHideTimer { $true }
        Mock Invoke-ShowTemplateResult {}
        Mock Send-PostboxValues {}
        Mock Publish-WebChannelState {}
        $sendRehearsal = {
            param($payload)
            $line = @{ op = 'air.rehearsal'; args = $payload } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            $request = @{ actor = 4322; action = 'preview'; key = 'Programme' }
            (& $sendRehearsal $request).error | Should -Be 'forbidden'
            $request.actor = 4321
            $script:WebTemplateTrialMode = 'Multi'
            (& $sendRehearsal $request).error | Should -Be 'rehearsal_multi'
            $script:WebTemplateTrialMode = 'Single'
            $script:WebTemplateTrialAlias = $true
            (& $sendRehearsal $request).error | Should -Be 'rehearsal_unavailable'
            $script:WebTemplateTrialAlias = $false
            $first = (& $sendRehearsal $request).data.preview
            $first.layer | Should -Be 9
            $first.fields.value | Should -Be @('TE', 'false')
            $request.action = 'start'
            $request.review = $first.review
            $script:WebTemplateTrialOccupied = $true
            (& $sendRehearsal $request).error | Should -Be 'rehearsal_busy'
            $script:WebTemplateTrialOccupied = $false
            Should -Invoke Show-TitlerTemplate -Times 0 -Exactly

            $request.action = 'preview'
            $second = (& $sendRehearsal $request).data.preview
            Add-Content -LiteralPath $templateFile -Value '<!-- edited after review -->'
            $request.action = 'start'
            $request.review = $second.review
            (& $sendRehearsal $request).error | Should -Be 'rehearsal_stale'
            Should -Invoke Show-TitlerTemplate -Times 0 -Exactly

            $request.action = 'preview'
            $confirmed = (& $sendRehearsal $request).data.preview
            $request.action = 'start'
            $request.review = $confirmed.review
            (& $sendRehearsal $request).data.autoHideFailed | Should -BeFalse
            (& $sendRehearsal $request).error | Should -Be 'rehearsal_stale'
            Should -Invoke Show-TitlerTemplate -Times 1 -Exactly -ParameterFilter {
                $Layer -eq 9 -and $Variables.title -eq 'TE' -and $Variables.enabled -eq 'false' -and -not $Variables.ContainsKey('picture')
            }
            Should -Invoke Set-AutoHideTimer -Times 1 -Exactly -ParameterFilter {
                $Layer -eq 9 -and $ActiveId -eq '{our-rehearsal}' -and $ActiveIdConfirmed -and
                    $SingleSceneOnly -and $null -ne $Deadline -and $Deadline -le $script:WebTemplateTrialLatestDeadline
            }
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            Should -Invoke Send-PostboxValues -Times 0 -Exactly
        }
        finally {
            $script:OnAir.Remove(9)
            $script:WebTemplateRehearsalReviews.Clear()
        }
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

    It 'reviews a single urgent and gives authorized operators distinct controls for the confirmed scene' {
        $oldBoard = $script:UrgentBoard
        $oldManual = $script:UrgentManualLive
        $oldNotice = $script:UrgentWebNotice
        $oldReviews = $script:WebUrgentManualReviews
        $oldRun = $script:UrgentBoardRun
        $oldBulletin = $script:MojazPlayback
        $oldLayer = $script:OnAir[5]
        $script:UrgentBoard = (Add-UrgentItem -Board (New-UrgentBoard) -Text 'خبر فردي').Value
        $script:UrgentBoardRun = $null
        $script:MojazPlayback = $null
        $script:UrgentManualLive = @{}
        $script:UrgentWebNotice = $null
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
        Mock Send-TemplateAirNotice { 0 }
        Mock Get-TemplateNotifyScope { 'all' }
        Mock Test-AirNoticeMuted { $false }
        Mock Invoke-ShowTemplateResult {
            $fixtureEvent = 'f691112c-e6a9-4397-9d00-703c977022f3'
            $script:OnAir[5] = @{ Key = 'Urgent'; ActiveId = $fixtureEvent; At = (Get-Date) }
            $script:webSingleScene = @{ Success = $true; IsOnAir = $true; ActiveId = $fixtureEvent }
            @{ Success = $true; EventIdentityConfirmed = $true; UrgentEventReadConfirmed = $true; EventId = $fixtureEvent }
        }
        Mock Invoke-HideLayer {
            if ($script:webSingleHideClears) {
                $script:webSingleScene = @{ Success = $true; IsOnAir = $false }
                $script:OnAir.Remove(5)
            }
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
            $result.sceneConfirmed | Should -BeTrue
            $live = $result.live
            $live.itemId | Should -Be $command.itemId
            Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
                $RequireEventIdentity -and $ManualUrgent -and $AutoHideSeconds -eq 30 -and
                    $ExpectedLayerStamp -eq 'empty' -and $Variables['headline'] -eq 'خبر فردي'
            }
            Should -Invoke Send-TemplateAirNotice -Times 1 -Exactly -ParameterFilter { $ConfirmedManualUrgent -and $IncludeActor -and $AutoHideSeconds -eq 0 }
            (& $call @{ actor = 4322; action = 'hide'; review = $live.review }).error | Should -Be 'urgent_stale'
            $peerStatus = (& $call @{ actor = 4322; action = 'status' }).data
            $peerStatus.noticeId | Should -BeExactly (Get-UrgentWebNoticeId)
            $peerStatus.live.review | Should -Not -Be $live.review
            $hide = @{ actor = 4322; action = 'hide'; review = $peerStatus.live.review }
            $script:webSingleScene.ActiveId = 'replacement'
            (& $call $hide).error | Should -Be 'urgent_stale'
            Should -Invoke Invoke-HideLayer -Times 0 -Exactly
            $script:webSingleScene.ActiveId = 'f691112c-e6a9-4397-9d00-703c977022f3'
            (& $call $hide).error | Should -Be 'urgent_manual_hide_unconfirmed'
            $script:UrgentManualLive.Count | Should -Be 1
            $script:webSingleHideClears = $true
            (& $call $hide).ok | Should -BeTrue
            Should -Invoke Invoke-HideLayer -Times 2 -Exactly -ParameterFilter {
                $RequireConsistentIdentity -and $ExpectedLayerStamp -eq 'active:f691112c-e6a9-4397-9d00-703c977022f3' -and $UserId -eq 4322
            }
            $script:UrgentManualLive.Count | Should -Be 0
            (& $call $command).error | Should -Be 'urgent_stale'
        }
        finally {
            $script:UrgentBoard = $oldBoard
            $script:UrgentManualLive = $oldManual
            $script:UrgentWebNotice = $oldNotice
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
            $invalidModeLine = '{"op":"urgent.playback","args":{"actor":4321,"action":"preview","mode":"unknown"}}'
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $invalidModeLine) | ConvertFrom-Json).error | Should -Be 'urgent_invalid'

            $start = @{ op = 'urgent.playback'; args = @{ actor = 4321; action = 'start'; review = $preview.data.preview.review } }
            $script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text 'خبر آخر').Value
            $selected = @{ op = 'urgent.playback'; args = @{ actor = 4321; action = 'preview-selected'; selectedIds = @() } }
            $missing = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($selected | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $missing.error | Should -Be 'urgent_stale'
            $secondId = $script:UrgentBoard.Items[1].Id
            $selected.args.selectedIds = @($secondId)
            $subset = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($selected | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $subset.ok | Should -BeTrue
            $subset.data.preview.itemCount | Should -Be 1
            @($subset.data.preview.headlines) | Should -Be @('خبر آخر')
            @($subset.data.preview.steps.text | Sort-Object -Unique) | Should -Be @('خبر آخر')
            $selected.args.action = 'start-selected'
            $selected.args.review = $subset.data.preview.review
            $selected.args.selectedIds = @()
            $missing = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($selected | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $missing.error | Should -Be 'urgent_stale'
            $stale = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $stale.error | Should -Be 'urgent_stale'

            $overrideItem = $script:UrgentBoard.Items[1]
            $overrideItem.Mode = 'exit'
            $sessionModeLine = '{"op":"urgent.playback","args":{"actor":4321,"action":"preview","mode":"auto_hide"}}'
            $preview = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $sessionModeLine) | ConvertFrom-Json
            $start.args.review = $preview.data.preview.review
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'urgent_stale'
            $start.args.mode = 'auto_hide'
            $playbackScene.ActiveId = 'external-replacement'
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'urgent_stale'
            $playbackScene.ActiveId = 'old-graphic'
            $start.args.actor = 999
            ((Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json).error | Should -Be 'forbidden'
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            $start.args.actor = 4321
            $started = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($start | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $started.data.run.state | Should -Be 'playing'
            $script:UrgentBoardRun.Steps[0].Mode | Should -Be 'auto_hide'
            $script:UrgentBoardRun.Steps[1].Mode | Should -Be 'exit'
            $newRow = (Add-UrgentItem -Board (New-UrgentBoard) -Text 'خبر جديد أثناء الدورة').Value.Items[0]
            (Add-UrgentRunStep -Item $newRow) | Should -BeGreaterThan 0
            $script:UrgentBoardRun.Steps[-1].Mode | Should -Be 'auto_hide'
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
            $script:UrgentBoardRun = $null
            $playbackScene.ActiveId = 'old-graphic'
            $selected.args.selectedIds = @($secondId)
            $selected.args.action = 'preview-selected'
            $subset = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($selected | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $subset.ok | Should -BeTrue
            $selected.args.action = 'start-selected'
            $selected.args.review = $subset.data.preview.review
            $subsetStarted = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($selected | ConvertTo-Json -Compress)) | ConvertFrom-Json
            $subsetStarted.ok | Should -BeTrue
            $script:UrgentBoardRun.Scope | Should -Be 'selected'
            @($script:UrgentBoardRun.Steps.ItemId | Sort-Object -Unique) | Should -Be @($secondId)
            (Add-UrgentRunStep -Item $newRow) | Should -Be 0
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

        $query = @{ op = 'content.list'; args = @{ actor = 4321; view = 'ticker'; page = 0; search = 'خَبَر 3'; order = 'title-desc' } } | ConvertTo-Json -Compress
        $filtered = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $query | ConvertFrom-Json
        $filtered.data.total | Should -Be 6
        $filtered.data.collectionTotal | Should -Be 34
        $filtered.data.items.position | Should -Be @(34, 33, 32, 31, 30, 3)
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

            $third = & $requestTicker @{ actor = 4321; action = 'add'; revision = $moved.data.draft.revision; text = 'خبر ثالث' }
            $newOrder = @{ actor = 4321; action = 'move'; revision = $third.data.draft.revision; index = 2; destination = 0 }
            (& $requestTicker $newOrder).data.draft.items | Should -Be @('خبر ثالث', 'حرره البوت', 'أول')
            (& $requestTicker $newOrder).error | Should -Be 'ticker_stale'
            $latestDraft = Get-NewsTickerDraft -UserId 4321
            Set-NewsTickerDraftItems -Draft $latestDraft -Items @('حرره البوت', 'أول') | Should -BeTrue
            $moved = & $requestTicker @{ actor = 4321; action = 'status' }

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

    It 'merges different headline edits and rejects stale, unauthorized, or post-handover shared edits' {
        $oldDraft = $script:NewsTickerDraft
        $oldPath = $script:newsDraftFile
        $oldGrant = $script:NewsLockGrant
        $oldRequest = $script:NewsLockRequest
        $script:newsDraftFile = Join-Path $TestDrive 'collaborative-ticker.json'
        $script:NewsLockGrant = $null
        $script:NewsLockRequest = $null
        $script:NewsTickerDraft = @{ Id = 'collaborative'; OwnerUserId = 4321; OwnerChatId = 4321; Items = @('الخبر الأول', 'الخبر الثاني') }
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $false }
        Mock Get-Setting { Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name }
        Mock Get-Setting { $true } -ParameterFilter { $Name -in 'EnableNewsTickerManagement', 'NewNewsItemAtTop' }
        Mock Get-Setting { '|' } -ParameterFilter { $Name -eq 'NewsItemSeparator' }
        Mock Get-SettingInt { Get-BridgeSettingInt -Config $config -Defaults $script:DefaultSettings -Name $Name -Minimum $Minimum }
        $tickerCall = {
            param($arguments)
            $line = @{ op = 'ticker.edit'; args = $arguments } | ConvertTo-Json -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        try {
            (& $tickerCall @{ actor = 4322; action = 'status' }).data.state | Should -Be 'locked'
            $shared = & $tickerCall @{ actor = 4321; action = 'share'; revision = Get-NewsTickerDraftRevision -Draft $script:NewsTickerDraft }
            $shared.ok | Should -BeTrue -Because ($shared | ConvertTo-Json -Compress -Depth 6)
            $fromOwner = $shared.data.draft
            $fromPeer = (& $tickerCall @{ actor = 4322; action = 'status' }).data.draft
            $fromOwner.canManage | Should -BeTrue
            $fromPeer.canManage | Should -BeFalse
            $fromPeer.items | Should -Be @('الخبر الأول', 'الخبر الثاني')
            (& $tickerCall @{ actor = 4400; action = 'status' }).error | Should -Be 'forbidden'
            $peerEdit = @{ actor = 4322; action = 'update'; review = $fromPeer.rowKeys[1]; revision = $fromPeer.revision; index = 1; text = 'تعديل المحرر الثاني' }
            (& $tickerCall @{ actor = 4321; action = 'add'; review = $fromOwner.sharedDraftKey; revision = $fromOwner.revision; text = 'خبر مضاف' }).ok | Should -BeTrue
            (Update-NewsTickerDraftItem -UserId 4321 -Index 1 -Text 'تعديل من البوت') | Should -BeTrue
            $updated = & $tickerCall $peerEdit
            $updated.ok | Should -BeTrue -Because ($updated | ConvertTo-Json -Compress -Depth 6)
            $updated.data.draft.items | Should -Be @('خبر مضاف', 'تعديل من البوت', 'تعديل المحرر الثاني')
            (& $tickerCall $peerEdit).error | Should -Be 'ticker_stale'
            (& $tickerCall @{ actor = 4322; action = 'discard'; revision = $updated.data.draft.revision }).error | Should -Be 'ticker_locked'
            $script:NewsTickerDraft = $null
            Import-NewsTickerDraft
            $restored = (& $tickerCall @{ actor = 4322; action = 'status' }).data.draft
            $restored.rowKeys | Should -Be $updated.data.draft.rowKeys
            $scheduled = & $tickerCall @{
                actor = 4321; action = 'schedule'; revision = $restored.revision
                publishAtMs = [datetimeoffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds()
            }
            $scheduled.ok | Should -BeTrue -Because ($scheduled | ConvertTo-Json -Compress -Depth 6)
            (& $tickerCall @{ actor = 4322; action = 'add'; review = $fromPeer.sharedDraftKey; text = 'خبر بعد الجدولة' }).error | Should -Be 'ticker_scheduled_readonly'
            (& $tickerCall @{ actor = 4321; action = 'handover'; revision = $scheduled.data.draft.revision }).ok | Should -BeTrue
            (& $tickerCall @{ actor = 4321; action = 'start_shared' }).ok | Should -BeTrue
            (& $tickerCall @{ actor = 4322; action = 'add'; review = $fromPeer.sharedDraftKey; text = 'إضافة متأخرة' }).error | Should -Be 'ticker_stale'
            (Get-NewsTickerDraft).Items | Should -Be @('خبر مضاف', 'تعديل من البوت', 'تعديل المحرر الثاني')
        }
        finally {
            $script:NewsTickerDraft = $oldDraft
            $script:newsDraftFile = $oldPath
            $script:NewsLockGrant = $oldGrant
            $script:NewsLockRequest = $oldRequest
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

    It 'reads the built-in bulletin text that the bot plays even without scene field discovery' {
        Mock Get-MojazRowFieldPrompts { @() }
        Mock Get-WebBulletinPhotoDestination { $null }
        Mock Test-MojazBulletinPlaybackDesign { $false }
        Mock Get-MojazBulletinSceneTiming { $null }
        $bulletin = @{
            Id = 'b_built_in'; Name = 'موجز'; Revision = 2
            Rows = @(@{
                    Id = 'r_built_in'; Title = 'العنوان الحالي'; Text = "سطر أول`nسطر ثانٍ"; ImageMode = 'inherit'
                    Fields = @{ 'title.Text' = 'عنوان قديم'; 'Subject.Text' = 'نص قديم'; 'mojaz_img' = 'pic.png' }
                })
        }
        $editor = Get-WebBulletinEditor -Bulletin $bulletin
        @($editor.fields).name | Should -Be @('title.Text', 'Subject.Text', 'mojaz_img')
        $editor.rows[0].values['title.Text'] | Should -Be $bulletin.Rows[0].Title
        $editor.rows[0].values['Subject.Text'] | Should -Be $bulletin.Rows[0].Text
        $editor.rows[0].media | Should -BeNullOrEmpty
        $editor.rows[0].imageMode | Should -Be 'inherit'
    }

    It 'saves the title, story and processed photo together for a new bulletin row' {
        Add-Type -AssemblyName System.Drawing
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-MojazAvailable { $true }
        Mock Get-MojazUploadDirectory { Join-Path $TestDrive 'story-row-pictures' }
        Mock Get-MojazImageSize { @{ Width = 32; Height = 18 } }
        Mock Get-WebBulletinFields {
            @{ name = 'title.Text'; label = 'العنوان'; kind = 'text' }
            @{ name = 'Subject.Text'; label = 'النص'; kind = 'text' }
            @{ name = 'mojaz_img'; label = 'الصورة'; kind = 'media' }
        }
        $oldLibrary = $script:MojazLibrary
        $oldUploadDirectory = $script:mojazWebUploadDirectory
        $script:mojazWebUploadDirectory = Join-Path $TestDrive 'story-row-staging'
        New-Item -ItemType Directory -Path $script:mojazWebUploadDirectory | Out-Null
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز كامل').Value
            $bulletin = $script:MojazLibrary.Bulletins[0]
            $request = @{ op = 'bulletin.photo'; args = @{
                    actor = 4321; action = 'apply'; id = $bulletin.Id; revision = $bulletin.Revision
                    createRow = $true; field = 'mojaz_img'; upload = [guid]::NewGuid().ToString('N')
                    values = @{ 'title.Text' = 'خبر'; 'Subject.Text' = " `u{200B} " }
                } }
            $path = Join-Path $script:mojazWebUploadDirectory "web-$($request.args.upload).image"
            $bitmap = [System.Drawing.Bitmap]::new(3, 4)
            try { $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }
            finally { $bitmap.Dispose() }
            $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($request | ConvertTo-Json -Depth 6 -Compress) | ConvertFrom-Json
            $reply.error | Should -Be 'bulletin_invalid'
            $script:MojazLibrary.Bulletins[0].Rows.Count | Should -Be 0
            Test-Path -LiteralPath (Get-MojazUploadDirectory) | Should -BeFalse

            $request.args.values['Subject.Text'] = "  سطر أول`nسطر ثانٍ  "
            $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line ($request | ConvertTo-Json -Depth 6 -Compress) | ConvertFrom-Json
            $reply.ok | Should -BeTrue
            $reply.data.rows[0].values.'title.Text' | Should -Be 'خبر'
            $reply.data.rows[0].values.'Subject.Text' | Should -Be "سطر أول`nسطر ثانٍ"
            $reply.data.rows[0].media | Should -Contain 'mojaz_img'
            $script:MojazLibrary.Bulletins[0].Revision | Should -Be ($bulletin.Revision + 1)
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
        for ($number = 2; $number -le 21; $number++) {
            $board = (Add-BoardItem -Board $board -TextFields @('programme.title', 'programme.guest') -Values @{
                    'programme.title' = "الفقرة $number" } -MaxFieldLength 100).Value
        }
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
            $editorRequest = @{ op = 'board.edit'; args = @{ actor = 4321; action = 'read'; id = $boardId; page = 1 } } | ConvertTo-Json -Compress
            $offPage = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $editorRequest | ConvertFrom-Json
            $offPage.ok | Should -BeTrue
            $offPage.data.page | Should -Be 1
            $offPage.data.rows.id | Should -Not -Contain $request.rowId
            $liveRow = Get-JsonProp $offPage.data 'liveRow'
            $liveRow | Should -Not -BeNullOrEmpty
            $liveRow.id | Should -Be $request.rowId
            $liveRow.number | Should -Be 1
            $liveRow.values.'programme.guest' | Should -Be 'الضيف الأول'
            $filteredRequest = @{ op = 'board.edit'; args = @{ actor = 4321; action = 'read'; id = $boardId; search = 'الفقرة 21'; order = 'title-desc' } } | ConvertTo-Json -Compress
            $filteredBoard = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $filteredRequest | ConvertFrom-Json
            $filteredBoard.ok | Should -BeTrue
            $filteredBoard.data.rows.number | Should -Be @(21)
            $filteredBoard.data.total | Should -Be 1
            $filteredBoard.data.collectionTotal | Should -Be 21
            $filteredBoard.data.liveRow.id | Should -Be $request.rowId
            $guestRequest = @{ op = 'board.edit'; args = @{ actor = 4321; action = 'read'; id = $boardId; search = 'الضَّيف الأول' } } | ConvertTo-Json -Compress
            $byGuest = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $guestRequest | ConvertFrom-Json
            $byGuest.data.rows.id | Should -Be @($request.rowId)
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
            $afterHide = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $editorRequest | ConvertFrom-Json
            (Get-JsonProp $afterHide.data 'liveRow') | Should -BeNullOrEmpty
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

    It 'shares template presets without exposing sensitive fields and rejects stale changes or playout' {
        Mock Test-Authorized { $UserId -in 4321, 4322, 4323 }
        Mock Test-Admin { $UserId -eq 4321 }
        Mock Test-TemplateAccess { @{ Allowed = ($UserId -ne 4323) } }
        Mock Invoke-ShowTemplateResult { @{ Success = $true } }
        Mock Publish-WebChannelState {}
        $script:PresetFixtureRegistry = Join-Path $TestDrive 'web-presets.json'
        Mock Get-TemplateRegistryFilePath { $script:PresetFixtureRegistry }
        $scene = Join-Path $TestDrive 'preset-scene.cintitle'
        Set-Content -LiteralPath $scene -Value '<Scene />'
        @{
            Programme = @{
                layer = 7; path = $scene
                fields = @(@{ name = 'title'; label = 'العنوان'; required = $true },
                    @{ name = 'studioCode'; sensitive = $true; required = $true }, 'streamKey')
                presets = @(@{ name = 'الافتتاح'; values = @($null, 'private-fixture-code', 'private-fixture-stream') })
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:PresetFixtureRegistry
        $sendPreset = {
            param($operation, $payload)
            $line = @{ op = $operation; args = $payload } | ConvertTo-Json -Depth 8 -Compress
            Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
        }
        (& $sendPreset 'air.presets' @{ actor = 4323; key = 'Programme' }).error | Should -Be 'forbidden'
        $previousText = $script:LastWebTemplateText['Programme']
        try {
            $script:LastWebTemplateText['Programme'] = @{ Path = $scene; Layer = 7; Values = @{ title = 'مشترك'; studioCode = 'private-fixture-code' } }
            foreach ($readerId in 4321, 4322) {
                $shared = & $sendPreset 'air.presets' @{ actor = $readerId; key = 'Programme' }
                $shared.data.lastValues.title | Should -Be 'مشترك'
                ($shared | ConvertTo-Json -Depth 8) | Should -Not -Match 'private-fixture'
            }
        } finally {
            if ($null -ne $previousText) { $script:LastWebTemplateText['Programme'] = $previousText }
            else { $script:LastWebTemplateText.Remove('Programme') }
        }
        $list = & $sendPreset 'air.presets' @{ actor = 4322; key = 'Programme' }
        $list.ok | Should -BeTrue
        $list.data.canManage | Should -BeFalse
        (Get-JsonProp $list.data.items[0].values 'title') | Should -BeNullOrEmpty
        $list.data.items[0].hiddenFields | Should -Be @('studioCode', 'streamKey')
        ($list | ConvertTo-Json -Depth 8) | Should -Not -Match 'private-fixture'
        $oldButton = 'pad:0:0:{0}' -f $list.data.revision.Substring(0, 16)
        (Read-TemplatePresetButton -Data $oldButton).Preset.Name | Should -Be 'الافتتاح'
        $request = @{ actor = 4322; key = 'Programme'; action = 'edit'; index = 0; revision = $list.data.revision
            values = @{ title = 'خبر جديد' } }
        (& $sendPreset 'air.preset-change' $request).error | Should -Be 'forbidden'
        $request.actor = 4321
        $changed = & $sendPreset 'air.preset-change' $request
        $changed.ok | Should -BeTrue
        $changed.data.items[0].values.title | Should -Be 'خبر جديد'
        Read-TemplatePresetButton -Data $oldButton | Should -BeNullOrEmpty
        (& $sendPreset 'air.preset-change' $request).error | Should -Be 'preset_stale'
        $show = @{ actor = 4322; key = 'Programme'; presetIndex = 0; presetRevision = $list.data.revision
            variables = @{ title = 'العنوان المباشر' }; autoHideSeconds = 0 }
        (& $sendPreset 'air.show' $show).error | Should -Be 'preset_stale'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        $show.presetRevision = $changed.data.revision
        (& $sendPreset 'air.show' $show).ok | Should -BeTrue
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
            $Variables['title'] -ceq 'العنوان المباشر' -and $Variables['studioCode'] -ceq 'private-fixture-code'
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
            $none = & $sendBoard 'board.list' @{ actor = 4322; search = 'عنوان غائب من جميع اللوحات 5423' }
            $none.data.total | Should -Be 0
            $matchByName = & $sendBoard 'board.list' @{ actor = 4322; search = 'المَساء'; order = 'title-desc' }
            $matchByName.data.items.Id | Should -Contain $boardId
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
            try { $bitmap.Save($inputFile, [System.Drawing.Imaging.ImageFormat]::Tiff) }
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
            try {
                $asset.Width | Should -Be 40
                $asset.Height | Should -Be 20
                $asset.RawFormat.Guid | Should -Be ([System.Drawing.Imaging.ImageFormat]::Png.Guid)
            }
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

    It 'lists and saves an unreferenced scene picture through the real pipe without disclosing its path' {
        $oldLibrary = $script:MojazLibrary
        $fixture = New-Item -Path (Join-Path $TestDrive 'scene-image-pipe') -ItemType Directory
        $script:PipeSceneImageScene = Join-Path $fixture.FullName 'Example.cintitle'
        $script:PipeSceneImageLibrary = Join-Path $fixture.FullName 'library.json'
        [IO.File]::WriteAllText($script:PipeSceneImageScene, '<scene />')
        $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aQWQAAAAASUVORK5CYII=')
        [IO.File]::WriteAllBytes((Join-Path $fixture.FullName 'logo.png'), $png)
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-MojazAvailable { $true }
        Mock Get-MojazPlaybackTemplate { @{ Path = $script:PipeSceneImageScene } }
        Mock Get-WebBulletinFields { @{ name = $script:MojazImageVariable; kind = 'media' } }
        Mock Get-MojazLibraryFile { $script:PipeSceneImageLibrary }
        Mock Add-AuditEntry {}
        Mock Get-WebBulletinEditor { @{ id = $Bulletin.Id; revision = $Bulletin.Revision } }
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الاتصال').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -Title 'صف الاتصال').Value
            $bulletin = $script:MojazLibrary.Bulletins[0]
            $request = @{ actor = 4321; id = $id; rowId = $bulletin.Rows[0].Id; revision = $bulletin.Revision }
            $list = @{ op = 'bulletin.scene-images'; args = $request + @{ action = 'list' } } | ConvertTo-Json -Compress
            $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $list
            $reply | Should -Not -Match 'cintitle|scene-image-pipe'
            $choices = $reply | ConvertFrom-Json
            $choices.data.items[0].label | Should -Be 'logo.png'
            $apply = @{ op = 'bulletin.scene-images'; args = $request + @{
                    action = 'apply'; selection = $choices.data.selection; slot = 0
                } } | ConvertTo-Json -Compress
            (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $apply | ConvertFrom-Json).ok | Should -BeTrue
            $script:MojazLibrary.Bulletins[0].Rows[0].Image | Should -Be '.\logo.png'
        }
        finally { $script:MojazLibrary = $oldLibrary }
    }

    It 'returns a scoped bulletin report and its bounded HTML through the real pipe' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-Admin { $false }
        Mock Get-MojazReportData {
            @{ Label = 'Today'; Rows = 2; Operators = 1; Scheduled = 1; Truncated = $false
                Runs = @([pscustomobject]@{ Name = 'Fixture bulletin'; UserId = '4321'; Rows = 2
                        StartedAt = [datetime]::new(2026, 3, 10, 8, 0, 0, [DateTimeKind]::Local)
                        EndedAt = $null; Kind = 'scheduled'; DurationMs = 0L
                    }) }
        }
        $list = @{ op = 'reports.bulletins'; args = @{ actor = 4321; action = 'list'; period = 'today' } } | ConvertTo-Json -Compress
        $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $list | ConvertFrom-Json
        $reply.ok | Should -BeTrue
        $reply.data.scope | Should -Be 'mine'
        $reply.data.items[0].name | Should -Be 'Fixture bulletin'
        $save = @{ op = 'reports.bulletins'; args = @{ actor = 4321; action = 'export'; period = 'today' } } | ConvertTo-Json -Compress
        $export = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $save | ConvertFrom-Json
        $export.data.count | Should -Be 1
        $export.data.html | Should -Match 'Fixture bulletin'
        Should -Invoke Get-MojazReportData -Times 2 -Exactly -ParameterFilter { $OnlyUserId -eq 4321 }
    }

    It 'returns a scoped template aggregate and HTML through the real pipe' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-Admin { $false }
        Mock Get-BannerReportData {
            @{ Label = 'Today'; Operators = 1; Truncated = $false
                Sessions = @([pscustomobject]@{ Target = 'Fixture banner'; UserId = '4321'; Layer = 4
                        StartedAt = [datetime]'2026-03-10T08:00:00'; EndedAt = $null; EndedBy = ''; Values = 'Editorial fixture'
                    }) }
        }
        $list = @{ op = 'reports.templates'; args = @{ actor = 4321; action = 'list'; period = 'today' } } | ConvertTo-Json -Compress
        $reply = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $list | ConvertFrom-Json
        $reply.ok | Should -BeTrue
        $reply.data.scope | Should -Be 'mine'
        $reply.data.items[0].layer | Should -Be 4
        $save = @{ op = 'reports.templates'; args = @{ actor = 4321; action = 'export'; period = 'today' } } | ConvertTo-Json -Compress
        $export = Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $save | ConvertFrom-Json
        $export.data.html | Should -Match 'Fixture banner'
        $export.data.html | Should -Not -Match 'Editorial fixture'
        Should -Invoke Get-BannerReportData -Times 2 -Exactly -ParameterFilter { $OnlyUserId -eq 4321 }
    }

    It 'routes reviewed after-urgent bookings and whole-bulletin deletion over the pipe without calling air' {
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-MojazAvailable { $true }
        Mock Test-WebBulletinPlayoutAccess { $true }
        Mock Test-MaintenanceWindowActive { $false }
        Mock Get-MojazUrgentTemplate { @{ Key = 'Urgent'; Layer = 7 } }
        Mock Get-MojazPlaybackTemplate { @{ Key = 'Mojaz'; Layer = 4; Path = 'fixture.cintitle' } }
        Mock Get-MojazResolvedRunSnapshot { @{ Success = $true; Value = @{ Rows = $Bulletin.Rows } } }
        Mock Read-MojazLayerStamp { 'active:bulletin-urgent-test' }
        Mock Add-AuditEntry {}
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'pipe-bulletin-management.json' }
        Mock Get-MojazSchedulesFile { Join-Path $TestDrive 'pipe-bulletin-management-schedules.json' }
        Mock Invoke-ShowTemplateResult { throw 'The real pipe fixture must not call air.' }
        $oldBulletinLibrary = $script:MojazLibrary
        $oldBulletinSchedules = $script:MojazSchedules
        $oldBulletinPlayback = $script:MojazPlayback
        $oldBulletinOnAir = $script:OnAir
        try {
            $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الاتصال').Value
            $id = $script:MojazLibrary.Bulletins[0].Id
            $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $id -Title 'صف الاتصال').Value
            $revision = $script:MojazLibrary.Bulletins[0].Revision
            $script:MojazSchedules = @()
            $script:MojazPlayback = $null
            $script:OnAir = @{ 7 = @{ Key = 'Urgent'; ActiveId = 'bulletin-urgent-test'; ActiveIdConfirmed = $true; At = [datetime]::Now } }
            $sendBulletin = {
                param($op, $body)
                $line = @{ op = $op; args = $body } | ConvertTo-Json -Compress
                Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line $line | ConvertFrom-Json
            }
            $queueReview = & $sendBulletin 'bulletin.afterUrgent' @{ actor = 4321; action = 'review'; id = $id; revision = $revision }
            $queueReview.ok | Should -BeTrue
            $queue = & $sendBulletin 'bulletin.afterUrgent' @{ actor = 4321; action = 'confirm'; review = $queueReview.data.review }
            $queue.ok | Should -BeTrue
            $script:MojazSchedules[0].Source | Should -Be 'web'
            $deleteReview = & $sendBulletin 'bulletin.management' @{
                actor = 4321; action = 'review'; id = $id; revision = $revision; operation = 'delete'
            }
            $deleteReview.data.pendingCount | Should -Be 1
            $removed = & $sendBulletin 'bulletin.management' @{ actor = 4321; action = 'confirm'; review = $deleteReview.data.review }
            $removed.ok | Should -BeTrue
            $script:MojazSchedules.Count | Should -Be 0
            $script:MojazLibrary.Bulletins.Count | Should -Be 0
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        }
        finally {
            $script:MojazLibrary = $oldBulletinLibrary
            $script:MojazSchedules = $oldBulletinSchedules
            $script:MojazPlayback = $oldBulletinPlayback
            $script:OnAir = $oldBulletinOnAir
        }
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
        Mock Test-Authorized { $UserId -in 4321,4322 }
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
            $second = (Invoke-WebPipeRequest -PipeName $script:WebChannelPipeName -Line '{"op":"content.list","args":{"actor":4322,"view":"urgent"}}') | ConvertFrom-Json
            $second.ok | Should -BeTrue
            $second.data.items[0].id | Should -Be $row.Id
            $second.data.items[0].values.strap | Should -Be 'خبر جديد'

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
