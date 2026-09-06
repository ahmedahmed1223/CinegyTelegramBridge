#requires -Version 7
<#
    Bridge.OnAir.Tests.ps1 - On-air records, layers, hide/exit, and timers.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Safe in-memory layer rollback' {
    BeforeEach {
        $config.Settings.EnableSafeRollback=$true
        $script:RollbackCandidates=@{}; $script:LastSuccessfulLayerShows=@{}; $script:OnAir=@{}
        $script:PendingState.Clear(); $script:LayerLocks=@{}; $script:AutoHideQueue=[Collections.Generic.List[object]]::new()
        Mock Get-TemplateStore {
            @{ Order=@('alpha','beta'); Map=@{
                alpha=@{ Key='alpha'; Layer=5; Path='C:\Scenes\Alpha.cintitle'; Fields=@('Title'); FieldTypes=@{}; Presets=@() }
                beta=@{ Key='beta'; Layer=5; Path='C:\Scenes\Beta.cintitle'; Fields=@('Title'); FieldTypes=@{}; Presets=@() }
            }; Errors=@() }
        }
        Mock Test-Admin { $false }
        Mock Send-TelegramMessage { }
        Mock Save-OnAirState { }
        Mock Add-UsageCount { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Write-AirOperationResult { }
        Mock Update-OnAirStateFromCinegy { [pscustomobject]@{ Added=@(); Removed=@(); Failed=@() } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success=$true; EventId='event-new'; Error=''; Xml='' } }
    }

    AfterEach {
        $config.Settings.EnableSafeRollback=$false
    }

    It 'keeps rollback disabled by default until the administrator enables it' {
        $config.Settings.EnableSafeRollback=$false
        Set-RollbackCandidate -Layer 5 -RestoreSnapshot @{ Key='alpha'; Variables=@{Title='old'} } `
            -ExpectedState hidden -ActorUserId 10
        Get-RollbackCandidate -Layer 5 -UserId 10 | Should -BeNullOrEmpty
        $script:RollbackCandidates.ContainsKey(5) | Should -BeFalse
    }

    It 'creates a rollback candidate only when the previous bot scene correlates with live ActiveId' {
        $script:LastSuccessfulLayerShows[5]=@{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old'; UserId=10; ChatId=10; At=(Get-Date) }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='event-old'; Error='' } }
        Invoke-ShowTemplateResult -Key beta -Variables @{Title='new'} -ChatId 10 -UserId 10 | Out-Null

        $candidate = Get-RollbackCandidate -Layer 5 -UserId 10
        $candidate.Restore.Key | Should -Be 'alpha'
        $candidate.Restore.Variables.Title | Should -Be 'old'
        $candidate.ExpectedActiveId | Should -Be 'event-new'
        $script:LastSuccessfulLayerShows[5].Key | Should -Be 'beta'
    }

    It 'offers an undo that clears a layer that was empty before the push' {
        # The commonest daily error: the wrong template, onto a layer that
        # had nothing on it. Before this there was nothing to press.
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$false; ActiveId=''; Error='' } }

        Invoke-ShowTemplateResult -Key beta -Variables @{Title='new'} -ChatId 10 -UserId 10 | Out-Null

        $candidate = Get-RollbackCandidate -Layer 5 -UserId 10
        $candidate | Should -Not -BeNullOrEmpty
        $candidate.Restore.Action | Should -Be 'hide'
    }

    It 'does not offer rollback when the previous snapshot does not match Cinegy' {
        $script:LastSuccessfulLayerShows[5]=@{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old'; UserId=10; ChatId=10 }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='external-event'; Error='' } }
        Invoke-ShowTemplateResult -Key beta -Variables @{Title='new'} -ChatId 10 -UserId 10 | Out-Null
        Get-RollbackCandidate -Layer 5 -UserId 10 | Should -BeNullOrEmpty
    }

    It 'captures a correlated manual hide as a restore-to-empty-state candidate' {
        $script:LastSuccessfulLayerShows[5]=@{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old'; UserId=10; ChatId=10 }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='event-old'; Error='' } }
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success=$true; Error='' } }
        Mock Sync-LayerAfterOperatorAction { }
        Invoke-HideLayer -Layer 5 -ChatId 10 -UserId 10 | Should -BeTrue
        (Get-RollbackCandidate -Layer 5 -UserId 10).ExpectedState | Should -Be 'hidden'
    }

    It 'records the configured operator name with its ID in the visible template-operation audit' {
        $previousAlias = if ($script:UserAliases.ContainsKey('10')) { [string]$script:UserAliases['10'] } else { $null }
        try {
            $script:UserAliases['10'] = 'محرر الأخبار'
            $script:LastSuccessfulLayerShows[5]=@{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old'; UserId=10; ChatId=10 }
            Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='event-old'; Error='' } }
            Mock Hide-TitlerTemplate { [pscustomobject]@{ Success=$true; Error='' } }
            Mock Sync-LayerAfterOperatorAction { }

            Invoke-HideLayer -Layer 5 -ChatId 10 -UserId 10 | Should -BeTrue

            Should -Invoke Add-AuditEntry -Times 1 -Exactly -ParameterFilter { $Message -match "محرر الأخبار $([char]0x200E)\(10\)" }
        }
        finally {
            if ($null -eq $previousAlias) { $script:UserAliases.Remove('10') | Out-Null }
            else { $script:UserAliases['10'] = $previousAlias }
        }
    }

    It 'restores only after review when the expected current scene still matches' {
        Set-RollbackCandidate -Layer 5 -RestoreSnapshot @{ Key='alpha'; Variables=@{Title='old'}; ActiveId='event-old' } `
            -ExpectedState replace -ExpectedActiveId 'event-current' -ActorUserId 10
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='event-current'; Error='' } }
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success=$true } }

        Start-SafeRollbackReview -Layer 5 -ChatId 10 -UserId 10
        (Get-PendingState -ChatId 10).Mode | Should -Be 'safe_rollback_review'
        Confirm-SafeRollback -Layer 5 -ChatId 10 -UserId 10
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $Key -eq 'alpha' -and $Variables.Title -eq 'old' }
    }

    It 'cancels and invalidates rollback on external change or uncertain Cinegy state' {
        foreach ($status in @(
            [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='different'; Error='' },
            [pscustomobject]@{ Success=$false; IsOnAir=$null; ActiveId=''; Error='timeout' }
        )) {
            $script:PendingState.Clear(); $script:RollbackCandidates=@{}
            Set-RollbackCandidate -Layer 5 -RestoreSnapshot @{ Key='alpha'; Variables=@{Title='old'} } `
                -ExpectedState replace -ExpectedActiveId 'event-current' -ActorUserId 10
            Mock Get-TitlerLayerStatus { return $status }
            Mock Invoke-ShowTemplateResult { throw 'must not execute' }
            Start-SafeRollbackReview -Layer 5 -ChatId 10 -UserId 10
            Confirm-SafeRollback -Layer 5 -ChatId 10 -UserId 10
            Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
            $script:RollbackCandidates.ContainsKey(5) | Should -BeFalse
        }
    }

    It 'expires candidates and never writes their editorial values to disk' {
        Set-RollbackCandidate -Layer 5 -RestoreSnapshot @{ Key='alpha'; Variables=@{Title='secret editorial value'} } `
            -ExpectedState hidden -ActorUserId 10
        $script:RollbackCandidates[5].ExpiresAt=(Get-Date).AddSeconds(-1)
        Get-RollbackCandidate -Layer 5 -UserId 10 | Should -BeNullOrEmpty
        $script:RollbackCandidates.ContainsKey(5) | Should -BeFalse
    }
}

Describe 'Layer naming' {
    It 'ignores malformed layer-name entries instead of crashing on indexes' {
        $original = Get-Setting 'LayerNames'
        try {
            $config.Settings | Add-Member -NotePropertyName 'LayerNames' -NotePropertyValue 'bad;7=عاجل;9=شريط الأخبار;=oops;10=' -Force
            Get-LayerName -Layer 7 | Should -Be 'عاجل'
            Set-LayerName -Layer 8 -Name 'أخبار' -ChatId 42 -UserId 42 | Should -BeTrue
            Get-Setting 'LayerNames' | Should -Be '7=عاجل;8=أخبار;9=شريط الأخبار'
            Get-LayerDisplayName -Layer 8 | Should -Be 'أخبار · طبقة 8'
        }
        finally {
            $config.Settings | Add-Member -NotePropertyName 'LayerNames' -NotePropertyValue $original -Force
        }
    }
}

Describe 'SHOW identity tracking' {
    BeforeEach {
        $script:OriginalReservedLayers = Get-Setting 'ReservedLayers'
        $script:OriginalDisabledTemplateKeys = Get-Setting 'DisabledTemplateKeys'
        $script:OriginalSensitiveTemplateKeys = Get-Setting 'SensitiveTemplateKeys'
        $script:OriginalSensitiveTemplateAutoHideSeconds = Get-Setting 'SensitiveTemplateAutoHideSeconds'
        $config.Settings | Add-Member -NotePropertyName ReservedLayers -NotePropertyValue '' -Force
        $config.Settings | Add-Member -NotePropertyName DisabledTemplateKeys -NotePropertyValue '' -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue '' -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateAutoHideSeconds -NotePropertyValue 30 -Force
        $OnAir.Clear()
        $LastShow.Clear()
        $LastSuccessfulLayerShows.Clear()
        $script:AutoHideQueue.Clear()
        Mock Get-TemplateStore {
            [pscustomobject]@{
                Map = @{
                    urgent = [pscustomobject]@{
                        Layer = 4
                        Path = 'D:\CG\urgent.cintitle'
                        FieldTypes = @{}
                    }
                }
            }
        }
        Mock Show-TitlerTemplate {
            [pscustomobject]@{
                Success = $true
                EventId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
                Xml = '<Request/>'
            }
        }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = ''; Error = '' }
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(4); Added = @(); Removed = @(); Failed = @(); LastSuccessfulAt = Get-Date }
        }
        Mock Save-OnAirState { }
        Mock Add-UsageCount { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Get-AfterShowKeyboard { @{ inline_keyboard = @() } }
        Mock Send-TelegramMessage { }
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName ReservedLayers -NotePropertyValue $script:OriginalReservedLayers -Force
        $config.Settings | Add-Member -NotePropertyName DisabledTemplateKeys -NotePropertyValue $script:OriginalDisabledTemplateKeys -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue $script:OriginalSensitiveTemplateKeys -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateAutoHideSeconds -NotePropertyValue $script:OriginalSensitiveTemplateAutoHideSeconds -Force
        $OnAir.Clear()
        $LastShow.Clear()
        $LastSuccessfulLayerShows.Clear()
        $script:AutoHideQueue.Clear()
    }

    It 'stores the SHOW event id with the local on-air record' {
        Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        Get-JsonProp $OnAir[4] 'ActiveId' | Should -Be '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
    }

    It 'does not record an on-air scene when Cinegy disconnects during SHOW' {
        Mock Show-TitlerTemplate {
            [pscustomobject]@{ Success = $false; EventId = ''; Xml = ''; Error = 'connection refused' }
        }

        Invoke-ShowTemplateResult -Key 'urgent' -Variables @{ 'Title.Text' = 'test' } -ChatId 10 -UserId 20

        $OnAir.ContainsKey(4) | Should -BeFalse
        $LastShow.ContainsKey(10) | Should -BeFalse
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

    It 'blocks SHOW when the target Cinegy layer cannot be verified' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $false; IsOnAir = $false; ActiveId = ''; ActiveName = ''; Error = 'timeout' }
        }

        $result = Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'التحقق'
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
        Should -Invoke Update-OnAirStateFromCinegy -Times 0 -Exactly
    }

    It 'blocks SHOW on an administrator-reserved layer before Cinegy is queried' {
        $config.Settings | Add-Member -NotePropertyName ReservedLayers -NotePropertyValue '4, 9' -Force

        $result = Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'محجوزة'
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'blocks a temporarily disabled template before Cinegy is queried' {
        $config.Settings | Add-Member -NotePropertyName DisabledTemplateKeys -NotePropertyValue 'urgent;logo' -Force

        $result = Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'معطّل'
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'schedules automatic hide against the exact Cinegy engine identity' {
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue 'urgent, breaking' -Force
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateAutoHideSeconds -NotePropertyValue 30 -Force
        $script:IdentityStatusCall = 0
        Mock Get-TitlerLayerStatus {
            $script:IdentityStatusCall++
            if ($script:IdentityStatusCall -eq 1) {
                return [pscustomobject]@{ Success=$true; IsOnAir=$false; ActiveId=''; ActiveName=''; ActiveTemplateName=''; Error='' }
            }
            return [pscustomobject]@{
                Success=$true; IsOnAir=$true; ActiveId='{ENGINE-GUID}'
                ActiveName='Show urgent.cintitle on layer 4'; ActiveTemplateName='urgent'; Error=''
            }
        }

        Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $script:AutoHideQueue.Count | Should -Be 1
        $script:AutoHideQueue[0].Layer | Should -Be 4
        $script:AutoHideQueue[0].ActiveId | Should -Be '{ENGINE-GUID}'
        $script:AutoHideQueue[0].ActiveIdConfirmed | Should -BeTrue
        [math]::Round(($script:AutoHideQueue[0].At - (Get-Date)).TotalSeconds) | Should -BeIn @(29, 30)
    }

    It 'does not arm a destructive timer without positive exact post-show identity' {
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue 'urgent' -Force
        $script:IdentityStatusCall = 0
        Mock Get-TitlerLayerStatus {
            $script:IdentityStatusCall++
            if ($script:IdentityStatusCall -eq 1) {
                return [pscustomobject]@{ Success=$true; IsOnAir=$false; ActiveId=''; ActiveName=''; ActiveTemplateName=''; Error='' }
            }
            return [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='{OTHER}'; ActiveName=''; ActiveTemplateName=''; Error='' }
        }

        Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20

        $script:AutoHideQueue.Count | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 1 -ParameterFilter { $Text -match 'ربط|يدوي' }
    }

    It 'arms a timer for an anonymous Cinegy item when its ActiveId changed after SHOW' {
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue 'urgent' -Force
        $script:IdentityStatusCall = 0
        Mock Get-TitlerLayerStatus {
            $script:IdentityStatusCall++
            if ($script:IdentityStatusCall -eq 1) {
                return [pscustomobject]@{ Success=$true; IsOnAir=$false; ActiveId='{OLD-ITEM}'; ActiveName=''; ActiveTemplateName=''; Error='' }
            }
            return [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='{ENGINE-ITEM}'; ActiveName=''; ActiveTemplateName=''; Error='' }
        }

        Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20 -AutoHideSeconds 30

        $script:AutoHideQueue.Count | Should -Be 1
        $OnAir[4].ActiveId | Should -Be '{ENGINE-ITEM}'
        $script:AutoHideQueue[0].ActiveId | Should -Be '{ENGINE-ITEM}'
        $script:AutoHideQueue[0].ActiveIdConfirmed | Should -BeTrue
    }

    It 'allows a later manual timer for the anonymous item captured by SHOW' {
        $script:IdentityStatusCall = 0
        Mock Get-TitlerLayerStatus {
            $script:IdentityStatusCall++
            if ($script:IdentityStatusCall -eq 1) {
                return [pscustomobject]@{ Success=$true; IsOnAir=$false; ActiveId='{OLD-ITEM}'; ActiveName=''; ActiveTemplateName=''; Error='' }
            }
            return [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='{ENGINE-ITEM}'; ActiveName=''; ActiveTemplateName=''; Error='' }
        }
        Mock Save-AutoHideQueue { $true }

        Invoke-ShowTemplateResult -Key 'urgent' -ChatId 10 -UserId 20
        Set-LayerAutoHide -Layer 4 -Seconds 30 -ChatId 10 -UserId 20

        $script:AutoHideQueue.Count | Should -Be 1
        $script:AutoHideQueue[0].ActiveId | Should -Be '{ENGINE-ITEM}'
        $script:AutoHideQueue[0].ActiveIdConfirmed | Should -BeTrue
    }

    It 'keeps a shorter operator timer for a sensitive template' {
        $config.Settings | Add-Member -NotePropertyName SensitiveTemplateKeys -NotePropertyValue 'urgent' -Force

        Get-EffectiveAutoHideSeconds -Key urgent -RequestedSeconds 10 | Should -Be 10
        Get-EffectiveAutoHideSeconds -Key urgent -RequestedSeconds 60 | Should -Be 30
        Get-EffectiveAutoHideSeconds -Key other -RequestedSeconds 60 | Should -Be 60
    }
}

Describe 'Persistent timed-show auto-hide timers' {
    BeforeEach {
        $script:OriginalAutoHideFileForTest = $script:autoHideFile
        $script:autoHideFile = Join-Path $TestDrive 'autohide.json'
        $script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()
        $script:OnAir = @{}
        Mock Write-BridgeLog { }
        Mock Send-TelegramMessage { }
        Mock Invoke-HideLayer { $true }
    }

    AfterEach {
        $script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()
        $script:OnAir = @{}
        $script:autoHideFile = $script:OriginalAutoHideFileForTest
    }

    It 'restores a timer after restart and hides the same scene after the remaining duration' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $timer = @{
            Layer = 7; At = $now.AddSeconds(30).ToString('o'); ChatId = 1L; UserId = 2L
            TemplateKey = 'Urgent'; ActiveId = 'show-1'
        }
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-1'; At = $now.DateTime; UserId = 2L }
        $script:AutoHideQueue.Add($timer)
        Save-AutoHideQueue | Should -BeTrue
        $script:AutoHideQueue.Clear()

        Import-AutoHideQueue
        Update-AutoHideQueue -Now $now.AddSeconds(29)

        $script:AutoHideQueue.Count | Should -Be 1
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly

        Update-AutoHideQueue -Now $now.AddSeconds(30)

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 7 -and $Quiet }
        $script:AutoHideQueue.Count | Should -Be 0
    }

    It 'does not hide a replacement scene when the persisted timer belongs to an older show' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $timer = @{
            Layer = 7; At = $now.AddSeconds(-1).ToString('o'); ChatId = 1L; UserId = 2L
            TemplateKey = 'Urgent'; ActiveId = 'show-old'
        }
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'show-new'; At = $now.DateTime; UserId = 2L }
        $script:AutoHideQueue.Add($timer)
        Save-AutoHideQueue | Should -BeTrue
        $script:AutoHideQueue.Clear()

        Import-AutoHideQueue
        Update-AutoHideQueue -Now $now

        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        $script:AutoHideQueue.Count | Should -Be 0
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'لم يُنفَّذ|تغيّرت' }
    }

    It 'verifies and stores the engine identity when attaching a timer to an existing scene' {
        $script:OnAir[7] = @{ Key='Urgent'; ActiveId='{COMMAND-GUID}'; At=Get-Date; UserId=2L; Source='bridge' }
        Mock Get-TemplateStore { [pscustomobject]@{ Map=@{ Urgent=@{ Key='Urgent'; Path='D:\CG\Urgent.cintitle' } }; Order=@('Urgent') } }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='{ENGINE-GUID}'; ActiveTemplateName='Urgent'; ActiveName='Urgent'; Error='' }
        }
        Mock Save-OnAirState { }
        Mock Add-AuditEntry { }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard=@() } }

        Set-LayerAutoHide -Layer 7 -Seconds 30 -ChatId 2 -UserId 2

        $script:AutoHideQueue.Count | Should -Be 1
        $script:AutoHideQueue[0].ActiveId | Should -Be '{ENGINE-GUID}'
        $script:AutoHideQueue[0].ActiveIdConfirmed | Should -BeTrue
        $script:OnAir[7].ActiveId | Should -Be '{ENGINE-GUID}'
    }

    It 'does not hide or lose a due timer when consuming it cannot be persisted' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key='Urgent'; ActiveId='engine-1'; At=$now.DateTime; UserId=2L }
        $script:AutoHideQueue.Add(@{ Layer=7; At=$now; ChatId=2L; UserId=2L; TemplateKey='Urgent'; ActiveId='engine-1'; ActiveIdConfirmed=$true })
        Mock Save-AutoHideQueue { $false }

        Update-AutoHideQueue -Now $now

        $script:AutoHideQueue.Count | Should -Be 1
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
    }

    It 'rechecks the live Cinegy ActiveId before hiding a confirmed timer' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $script:OnAir[7] = @{ Key='Urgent'; ActiveId='{ENGINE-1}'; At=$now.DateTime; UserId=2L }
        $script:AutoHideQueue.Add(@{
                Layer=7; At=$now; ChatId=2L; UserId=2L; TemplateKey='Urgent'
                ActiveId='{ENGINE-1}'; ActiveIdConfirmed=$true
            })
        Mock Save-AutoHideQueue { $true }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success=$true; IsOnAir=$true; ActiveId='{REPLACEMENT}'; ActiveName=''; ActiveTemplateName='' }
        }

        Update-AutoHideQueue -Now $now

        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تغيّرت|تغيّر|لم يُنفَّذ' }
    }
}

Describe 'Snapshot source labels' {
    It 'labels a snapshot captured from the primary broadcast source' {
        Get-SnapshotSourceLabel -SourceIsPrimary $true | Should -Be 'البث الأساسي'
    }

    It 'labels a snapshot captured from Cinegy backup source' {
        Get-SnapshotSourceLabel -SourceIsPrimary $false | Should -Be 'بث Cinegy الاحتياطي'
    }
}

Describe 'Layer preparation locks' {
    BeforeEach {
        $script:LayerLocks.Clear()
        Clear-PendingState -ChatId 10
        Clear-PendingState -ChatId 11
        Mock Get-TemplateByIndex {
            [pscustomobject]@{
                Key = 'urgent'
                Layer = 4
                Fields = @('Title.Text')
                FieldLabels = @('العنوان')
                FieldLimits = @(80)
            }
        }
        Mock Send-TelegramMessage { }
    }

    AfterEach {
        Clear-PendingState -ChatId 10
        Clear-PendingState -ChatId 11
        $script:LayerLocks.Clear()
    }

    It 'prevents a second operator from preparing the same layer' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 10 -UserId 20
        Start-ShowFlow -TemplateIndex 0 -ChatId 11 -UserId 21

        Get-PendingState -ChatId 10 | Should -Not -BeNullOrEmpty
        Get-PendingState -ChatId 11 | Should -BeNullOrEmpty
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            # Asserts the notice names who holds the layer and for how long -
            # a bare owner id told the second operator nothing they could act on.
            $ChatId -eq 11 -and $Text -match 'يجهّز' -and $Text -match 'منذ'
        }
    }

    It 'releases the layer when the first operator cancels the draft' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 10 -UserId 20
        Clear-PendingState -ChatId 10

        Start-ShowFlow -TemplateIndex 0 -ChatId 11 -UserId 21

        Get-PendingState -ChatId 11 | Should -Not -BeNullOrEmpty
    }

    It 'releases the layer when the draft expires' {
        Start-ShowFlow -TemplateIndex 0 -ChatId 10 -UserId 20
        $state = Get-PendingState -ChatId 10
        $state.StartedAt = (Get-Date).AddMinutes(-10)

        Get-PendingState -ChatId 10 | Should -BeNullOrEmpty
        Start-ShowFlow -TemplateIndex 0 -ChatId 11 -UserId 21

        Get-PendingState -ChatId 11 | Should -Not -BeNullOrEmpty
    }

    It 'releases the layer when the periodic expiry sweep removes the draft' {
        Mock Write-BridgeLog { }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
        Start-ShowFlow -TemplateIndex 0 -ChatId 10 -UserId 20
        $state = Get-PendingState -ChatId 10
        $state.StartedAt = (Get-Date).AddMinutes(-10)

        Update-PendingExpiry
        Start-ShowFlow -TemplateIndex 0 -ChatId 11 -UserId 21

        Get-PendingState -ChatId 11 | Should -Not -BeNullOrEmpty
    }
}

Describe 'Hide-all confirmation gate' {
    BeforeEach {
        Clear-PendingState -ChatId 70
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { }
        Mock Invoke-HideAllLayers { }
        Mock Get-KnownLayers { @(2, 4) }
    }

    AfterEach { Clear-PendingState -ChatId 70 }

    It 'does not hide layers when the emergency button is first pressed' {
        $callback = [pscustomobject]@{
            id = 'hide-all-review-1'
            from = [pscustomobject]@{ id = 80 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 70 } }
            data = 'menu:hideall'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Invoke-HideAllLayers -Times 0 -Exactly
        $state = Get-PendingState -ChatId 70
        $state | Should -Not -BeNullOrEmpty
        $state.Mode | Should -Be 'hide_all_review'
    }

    It 'hides all layers only after the operator confirms' {
        $review = [pscustomobject]@{
            id = 'hide-all-review-2'
            from = [pscustomobject]@{ id = 80 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 70 } }
            data = 'menu:hideall'
        }
        Invoke-CallbackQuery -CallbackQuery $review
        $confirm = [pscustomobject]@{
            id = 'hide-all-confirm-2'
            from = [pscustomobject]@{ id = 80 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 70 } }
            data = 'hideall:confirm'
        }

        Invoke-CallbackQuery -CallbackQuery $confirm

        Should -Invoke Invoke-HideAllLayers -Times 1 -Exactly -ParameterFilter { $ChatId -eq 70 -and $UserId -eq 80 }
        Get-PendingState -ChatId 70 | Should -BeNullOrEmpty
    }

    It 'requires the same confirmation for the slash hideall command' {
        Invoke-BridgeCommand -Text '/hideall' -ChatId 70 -UserId 80

        Should -Invoke Invoke-HideAllLayers -Times 0 -Exactly
        (Get-PendingState -ChatId 70).Mode | Should -Be 'hide_all_review'
    }
}

Describe 'Configurable hide-all layers' {
    BeforeEach {
        $script:OriginalHideAllLayersForTest = Get-Setting 'HideAllLayers'
        $config.Settings | Add-Member -NotePropertyName 'HideAllLayers' -NotePropertyValue '2,4' -Force
        $script:OnAir.Clear()
        Mock Get-KnownLayers { @(2, 4, 6) }
        Mock Invoke-HideLayer { $true }
        Mock Send-TelegramMessage { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Save-Config { }
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $true }
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName 'HideAllLayers' -NotePropertyValue $script:OriginalHideAllLayersForTest -Force
        $script:OnAir.Clear()
    }

    It 'uses only the layers selected by the administrator for hide-all' {
        $script:OnAir[8] = @{ Key = 'outside-scope'; At = Get-Date; UserId = 10 }

        Invoke-HideAllLayers -ChatId 70 -UserId 80

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 2 }
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 4 }
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly -ParameterFilter { $Layer -in @(6, 8) }
    }

    It 'uses every known layer when the setting is all' {
        $config.Settings | Add-Member -NotePropertyName 'HideAllLayers' -NotePropertyValue 'all' -Force

        $targets = @(Get-HideAllTargetLayers)

        $targets | Should -Be @(2, 4, 6)
    }

    It 'shows the selected layers as toggles in the administrator settings panel' {
        $keyboard = Get-HideAllLayerSettingsKeyboard
        $labels = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text })
        $callbacks = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_['callback_data'] })

        $labels | Should -Contain '✅ طبقة 2'
        $labels | Should -Contain '✅ طبقة 4'
        $labels | Should -Contain '⬜ طبقة 6'
        $callbacks | Should -Contain 'hideallcfg:toggle:6'
    }

    It 'adds a layer selected from the settings panel to the emergency scope' {
        $callback = [pscustomobject]@{
            id = 'hide-all-scope-1'
            from = [pscustomobject]@{ id = 80 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 70 } }
            data = 'hideallcfg:toggle:6'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        (Get-Setting 'HideAllLayers') | Should -Be '2,4,6'
    }
}

Describe 'On-air identity persistence' {
    BeforeEach {
        $script:OriginalOnAirFileForTest = $script:onAirFile
        $script:onAirFile = Join-Path $TestDrive 'onair.json'
        $OnAir.Clear()
        $script:OnAirScenes = [System.Collections.Generic.List[object]]::new()
        Mock Write-BridgeLog { }
    }

    AfterEach {
        $OnAir.Clear()
        $script:onAirFile = $script:OriginalOnAirFileForTest
    }

    It 'restores the SHOW event id after a bridge restart' {
        $OnAir[4] = @{
            Key = 'urgent'
            At = Get-Date
            UserId = 20
            ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
            ActiveIdConfirmed = $true
        }
        Save-OnAirState
        $OnAir.Clear()

        Import-OnAirState

        Get-JsonProp $OnAir[4] 'ActiveId' | Should -Be '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        Get-JsonProp $OnAir[4] 'ActiveIdConfirmed' | Should -BeTrue
    }

    It 'reads the canonical scene envelope through the legacy one-record layer view' {
        @{ SchemaVersion = 1; Scenes = @(
            @{ SceneId = 'legacy-4'; Layer = 4; Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{CANONICAL}'; Source = 'bridge' }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:onAirFile -Encoding utf8

        Import-OnAirState

        $OnAir.ContainsKey(4) | Should -BeTrue
        $OnAir[4].Key | Should -Be 'urgent'
        $OnAir[4].ActiveId | Should -Be '{CANONICAL}'
    }

    It 'rejects Multi mode when Cinegy has not proved a non-empty active identity' {
        $original = Get-Setting 'SceneMode'
        Mock Save-Config { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-TelegramMessage { }
        Mock Get-CinegyLayerDashboard { @([pscustomobject]@{ Success = $true; ActiveId = '' }) }

        try {
            Set-SettingChoice -Name 'SceneMode' -Index 1 -ChatId 100 -UserId 100

            Get-Setting 'SceneMode' | Should -Be $original
            Should -Invoke Save-Config -Times 0 -Exactly
            Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'غير متاح' }
        }
        finally { $config.Settings | Add-Member -NotePropertyName 'SceneMode' -NotePropertyValue $original -Force }
    }

    It 'preserves every canonical same-layer scene when the state is re-saved' {
        @{ SchemaVersion = 1; Scenes = @(
            @{ SceneId = 'scene-a'; Layer = 4; Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{A}'; Source = 'bridge' }
            @{ SceneId = 'scene-b'; Layer = 4; Key = 'ticker'; At = '2026-08-28T12:01:00Z'; UserId = 21; ActiveId = '{B}'; Source = 'bridge' }
        ) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:onAirFile -Encoding utf8

        Import-OnAirState
        Save-OnAirState
        $saved = Get-Content -LiteralPath $script:onAirFile -Raw | ConvertFrom-Json

        @($saved.Scenes | Where-Object { $_.Layer -eq 4 }).Count | Should -Be 2
        @($saved.Scenes.SceneId) | Should -Contain 'scene-a'
        @($saved.Scenes.SceneId) | Should -Contain 'scene-b'
    }

    It 'updates only the projected canonical scene when Cinegy changes its identity' {
        Set-OnAirCanonicalScenes -Scenes @(
            [pscustomobject]@{ SceneId = 'scene-a'; Layer = 4; Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{A}'; Source = 'bridge' }
            [pscustomobject]@{ SceneId = 'scene-b'; Layer = 4; Key = 'ticker'; At = '2026-08-28T12:01:00Z'; UserId = 21; ActiveId = '{B}'; Source = 'bridge' }
        )

        Update-OnAirLayerRecord -Layer 4 -Record @{ Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{A2}'; Source = 'bridge' }

        @($script:OnAirScenes | Where-Object { $_.Layer -eq 4 }).Count | Should -Be 2
        ($script:OnAirScenes | Where-Object { $_.SceneId -eq 'scene-a' }).ActiveId | Should -Be '{A2}'
        ($script:OnAirScenes | Where-Object { $_.SceneId -eq 'scene-b' }).ActiveId | Should -BeNullOrEmpty
    }

    It 'preserves the same-layer catalogue on Multi SHOW and collapses it on Single SHOW' {
        $originalMode = Get-Setting 'SceneMode'
        try {
            Set-OnAirCanonicalScenes -Scenes @(
                [pscustomobject]@{ SceneId = 'scene-a'; Layer = 4; Key = 'urgent'; At = '2026-08-28T12:00:00Z'; UserId = 20; ActiveId = '{A}'; Source = 'bridge' }
                [pscustomobject]@{ SceneId = 'scene-b'; Layer = 4; Key = 'ticker'; At = '2026-08-28T12:01:00Z'; UserId = 21; ActiveId = '{B}'; Source = 'bridge' }
            )
            $config.Settings | Add-Member -NotePropertyName SceneMode -NotePropertyValue 'Multi' -Force
            Set-OnAirShownRecord -Layer 4 -Record @{ Key = 'breaking'; At = Get-Date; UserId = 22; ActiveId = '{NEW}' }
            @($script:OnAirScenes | Where-Object Layer -eq 4).Count | Should -Be 2
            $script:OnAirScenes[0].Key | Should -Be 'breaking'
            $script:OnAirScenes[1].ActiveId | Should -BeNullOrEmpty

            $config.Settings | Add-Member -NotePropertyName SceneMode -NotePropertyValue 'Single' -Force
            Set-OnAirShownRecord -Layer 4 -Record @{ Key = 'single'; At = Get-Date; UserId = 23; ActiveId = '{SINGLE}' }
            @($script:OnAirScenes | Where-Object Layer -eq 4).Count | Should -Be 1
            $script:OnAirScenes[0].Key | Should -Be 'single'
        }
        finally { $config.Settings | Add-Member -NotePropertyName SceneMode -NotePropertyValue $originalMode -Force }
    }

    It 'restores on-air state from the last validated backup when the primary JSON is corrupt' {
        $OnAir[4] = @{ Key = 'urgent'; At = Get-Date; UserId = 20; ActiveId = '{SAFE}' }
        Save-OnAirState
        Test-Path -LiteralPath "$($script:onAirFile).bak" | Should -BeTrue
        Set-Content -LiteralPath $script:onAirFile -Value '{broken-json'
        $OnAir.Clear()

        Import-OnAirState

        $OnAir[4].ActiveId | Should -Be '{SAFE}'
        { Get-Content -LiteralPath $script:onAirFile -Raw | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe 'Exit scene on-air record cleanup' {
    BeforeEach {
        $OnAir.Clear()
        $OnAir[7] = @{
            Key = 'urgent'; At = Get-Date; UserId = 10
            ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        }
        Mock Save-OnAirState { }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-TelegramMessage { }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Layer = 7; Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = '' } }
    }

    AfterEach { $OnAir.Clear() }

    It 'removes and persists the template record after a successful exit button action' {
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $true; Error = '' } }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42

        $OnAir.ContainsKey(7) | Should -BeFalse
        # Deliberately no longer reconciles against a status read: Cinegy keeps
        # the item Active after EXIT_SCENE_LOOP, so that read cannot tell an
        # exited scene from a live one and used to preserve the record.
        Should -Invoke Save-OnAirState -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تم الخروج من المشهد'
        }
    }

    It 'keeps the template record when Cinegy rejects the exit action' {
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $false; Error = 'timeout' } }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42

        $OnAir.ContainsKey(7) | Should -BeTrue
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

}

Describe 'Update-OnAirStateFromCinegy' {
    BeforeEach {
        $OnAir.Clear()
        $OnAir[4] = @{ Key = 'lower-third'; At = Get-Date; UserId = 10 }
        Mock Save-OnAirState { }
        Mock Write-BridgeLog { }
    }

    AfterEach { $OnAir.Clear() }

    It 'removes a stale local layer when Cinegy says it is hidden' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = '' }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeFalse
        $result.Removed | Should -Be @(4)
        Should -Invoke Save-OnAirState -Times 1 -Exactly
        Should -Invoke Write-BridgeLog -Times 1 -ParameterFilter {
            $Message -match 'removed on-air record.*layer 4.*confirmed hidden'
        }
    }

    It 'keeps the tracked template when Cinegy reports a different active id but is still on air' {
        $OnAir[4].ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success  = $true
                IsOnAir  = $true
                ActiveId = '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'
                ActiveName = 'External Item'
                OutputState = 'Normal'
                ClientConnected = $true
                ClientIdentity = 'Air UI'
            }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $OnAir[4].ActiveId | Should -Be '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'
        $result.Removed | Should -Be @()
        Should -Invoke Save-OnAirState -Times 1 -Exactly
    }

    It 'does not rewrite onair state when Cinegy reports the already tracked active id' {
        $OnAir[4].ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success    = $true
                IsOnAir    = $true
                ActiveId   = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
                ActiveName = 'lower-third.cintitle'
            }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $OnAir[4].ActiveId | Should -Be '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        @($result.Removed).Count | Should -Be 0
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

    It 'formats an actionable external change alert without inventing a source IP' {
        $change = [pscustomobject]@{
            Layer = 4; TemplateKey = 'lower-third'; ShowUserId = 10; ShownAt = [datetime]'2026-08-21T10:00:00'
            ExpectedActiveId = '{OLD}'; ActualActiveId = '{NEW}'; ActualActiveName = 'External Item'
            OutputState = 'Normal'; ClientConnected = $true; ClientIdentity = 'Air UI'
        }

        $text = Format-ExternalCinegyChangeAlert -Changes @($change)

        $text | Should -Match 'lower-third'
        $text | Should -Match 'External Item'
        $text | Should -Match 'Air UI'
        $text | Should -Not -Match 'عنوان IP'
    }

    It 'keeps a tracked layer that has no correlatable event id but is on air' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success  = $true
                IsOnAir  = $true
                ActiveId = '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'
            }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $result.Removed | Should -Be @()
        Should -Invoke Save-OnAirState -Times 1 -Exactly
    }

    It 'preserves the local layer when the status request fails' {
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $false; IsOnAir = $null; Error = 'timeout' }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $result.Failed | Should -Be @(4)
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

    It 'preserves the local layer when Cinegy says it is on air but returns an empty active id' {
        $OnAir[4].ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '' }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        @($result.Removed).Count | Should -Be 0
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }

    It 'adopts Cinegy active id and preserves layer when template name matches' {
        $OnAir[4] = @{ Key = 'lower-third'; At = Get-Date; UserId = 10; ActiveId = '{COMMAND-GUID}' }
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success    = $true
                IsOnAir    = $true
                ActiveId   = '{CINEGY-ENGINE-GUID}'
                ActiveName = 'lower-third.cintitle'
            }
        }

        $result = Update-OnAirStateFromCinegy

        $OnAir.ContainsKey(4) | Should -BeTrue
        $OnAir[4].ActiveId | Should -Be '{CINEGY-ENGINE-GUID}'
        @($result.Removed).Count | Should -Be 0
    }

    It 'does not let a later watchdog observation adopt a replacement for pending auto-hide' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $originalQueue = $script:AutoHideQueue
        try {
            $script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()
            $script:AutoHideQueue.Add(@{
                    Layer = 4; At = $now.AddSeconds(30); ChatId = 1L; UserId = 10L
                    TemplateKey = 'lower-third'; ActiveId = '{COMMAND-GUID}'
                })
            $OnAir[4] = @{ Key = 'lower-third'; At = $now.DateTime; UserId = 10; ActiveId = '{COMMAND-GUID}'; Source = 'bridge' }
            Mock Save-AutoHideQueue { $true }
            Mock Send-TelegramMessage { }
            Mock Invoke-HideLayer { $true }
            Mock Get-TitlerLayerStatus {
                [pscustomobject]@{
                    Success = $true; IsOnAir = $true; ActiveId = '{CINEGY-ENGINE-GUID}'
                    ActiveName = 'Show lower-third.cintitle on layer 4'; ActiveTemplateName = 'lower-third'
                }
            }

            Update-OnAirStateFromCinegy | Out-Null
            $script:AutoHideQueue[0].ActiveId | Should -Be '{COMMAND-GUID}'

            Update-AutoHideQueue -Now $now.AddSeconds(30)
            Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        }
        finally { $script:AutoHideQueue = $originalQueue }
    }

    It 'does not rebind a confirmed auto-hide to a later replacement even when the template name matches' {
        $now = [datetimeoffset]'2099-08-21T10:00:00+03:00'
        $originalQueue = $script:AutoHideQueue
        try {
            $script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()
            $script:AutoHideQueue.Add(@{
                    Layer = 4; At = $now.AddSeconds(30); ChatId = 1L; UserId = 10L
                    TemplateKey = 'lower-third'; ActiveId = '{CINEGY-ENGINE-GUID}'; ActiveIdConfirmed = $true
                })
            $OnAir[4] = @{ Key = 'lower-third'; At = $now.DateTime; UserId = 10; ActiveId = '{CINEGY-ENGINE-GUID}'; Source = 'bridge' }
            Mock Save-AutoHideQueue { $true }
            Mock Send-TelegramMessage { }
            Mock Invoke-HideLayer { $true }
            Mock Get-TitlerLayerStatus {
                [pscustomobject]@{
                    Success = $true; IsOnAir = $true; ActiveId = '{LATER-REPLACEMENT-GUID}'
                    ActiveName = 'Show lower-third.cintitle on layer 4'; ActiveTemplateName = 'lower-third'
                }
            }

            Update-OnAirStateFromCinegy | Out-Null

            $script:AutoHideQueue[0].ActiveId | Should -Be '{CINEGY-ENGINE-GUID}'
            Update-AutoHideQueue -Now $now.AddSeconds(30)
            Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        }
        finally { $script:AutoHideQueue = $originalQueue }
    }

    It 'reuses a supplied dashboard sample instead of querying the layer again' {
        Mock Get-TitlerLayerStatus { throw 'must not be called' }
        $sample = [pscustomobject]@{
            Layer = 4; Success = $true; IsOnAir = $false; ActiveId = ''
        }

        $result = Update-OnAirStateFromCinegy -LayerStatuses @($sample)

        $result.Removed | Should -Be @(4)
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
    }

    It 'adds an externally started Cinegy scene during a full layer comparison' {
        $OnAir.Clear()
        $sample = [pscustomobject]@{
            Layer = 7; Success = $true; IsOnAir = $true
            ActiveId = '{CINEGY-EXTERNAL-GUID}'; ActiveName = 'Breaking News On'
        }

        $result = Update-OnAirStateFromCinegy -Reason 'operator-check' -LayerStatuses @($sample) -DiscoverExternal

        $result.Added | Should -Be @(7)
        $OnAir.ContainsKey(7) | Should -BeTrue
        $OnAir[7].Key | Should -Be 'Breaking News On'
        $OnAir[7].Source | Should -Be 'cinegy'
        $OnAir[7].UserId | Should -Be 0
        Should -Invoke Save-OnAirState -Times 1 -Exactly
    }

    It 'does not invent an external record when the Cinegy layer query is uncertain' {
        $OnAir.Clear()
        $sample = [pscustomobject]@{
            Layer = 7; Success = $false; IsOnAir = $null; Error = 'timeout'
        }

        $result = Update-OnAirStateFromCinegy -Reason 'operator-check' -LayerStatuses @($sample) -DiscoverExternal

        @($result.Added).Count | Should -Be 0
        $OnAir.ContainsKey(7) | Should -BeFalse
        Should -Invoke Save-OnAirState -Times 0 -Exactly
    }
}

Describe 'Cinegy layer dashboard' {
    BeforeEach {
        $OnAir.Clear()
        $OnAir[4] = @{
            Key = 'lower-third'; At = Get-Date; UserId = 10
            ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'
        }
        Mock Get-KnownLayers { @(4, 5, 6, 7) }
        Mock Get-TitlerLayerStatus {
            switch ($Layer) {
                4 { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}'; ActiveName = 'Bot Item'; OutputState = 'Normal'; LicenseState = 'Licensed'; ClientConnected = $true; ClientIdentity = 'Client 1' } }
                5 { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveId = '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}'; ActiveName = 'External Item'; OutputState = 'Normal'; LicenseState = 'Licensed'; ClientConnected = $true; ClientIdentity = 'Client 1' } }
                6 { [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = ''; OutputState = 'Normal'; LicenseState = 'Licensed'; ClientConnected = $true; ClientIdentity = 'Client 1' } }
                7 { [pscustomobject]@{ Success = $false; IsOnAir = $null; ActiveId = ''; Error = 'timeout' } }
            }
        }
    }

    AfterEach { $OnAir.Clear() }

    It 'collects every configured layer exactly once' {
        $dashboard = @(Get-CinegyLayerDashboard)

        @($dashboard.Layer) | Should -Be @(4, 5, 6, 7)
        Should -Invoke Get-TitlerLayerStatus -Times 4 -Exactly -ParameterFilter { $TimeoutSec -eq 1 }
    }

    It 'distinguishes bridge external hidden and unknown layers' {
        $text = Format-CinegyLayerDashboard -LayerStatuses @(Get-CinegyLayerDashboard)

        $text | Should -Match '🔴 طبقة 4: lower-third'
        $text | Should -Match '🟠 طبقة 5: External Item \(خارجي\)'
        $text | Should -Match '⚪ طبقة 6: مخفية'
        $text | Should -Match '⚠️.*طبقة 7: غير معروف'
        $text | Should -Match '🙈 إخفاء.*فورًا'
        $text | Should -Match '🔄 تحديث.*فحص كل الطبقات'
        $text | Should -Match 'الخرج Normal'
        $text | Should -Match 'الترخيص Licensed'
        $text | Should -Match 'العميل Client 1'
    }
}

Describe 'Layer quick panel' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { }
        Mock Get-CinegyLayerDashboard {
            @(
                [pscustomobject]@{ Layer = 2; Success = $true; IsOnAir = $true; ActiveId = '{A}'; ActiveName = 'External' },
                [pscustomobject]@{ Layer = 4; Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = '' }
            )
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(2, 4); Added = @(2); Removed = @(); Failed = @(); Changes = @() }
        }
    }

    It 'shows actual layer states as quick action buttons' {
        $callback = [pscustomobject]@{
            id = 'layers-panel-1'
            from = [pscustomobject]@{ id = 200 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 200 } }
            data = 'menu:layers'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Get-CinegyLayerDashboard -Times 1 -Exactly
        Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly -ParameterFilter {
            $Reason -eq 'operator-check' -and $DiscoverExternal
        }
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $labels = @($ReplyMarkup.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text })
            $labels -contains '🙈 إخفاء طبقة 2' -and
                $labels -contains '🔄 تحديث · طبقة 4 مخفية'
        }
    }
}

Describe 'Main menu on-air priority' {
    BeforeEach {
        $script:OnAir = @{}
        $script:AutoHideQueue = @()
        Mock Test-Admin { $false }
    }
    AfterAll { $script:OnAir = @{} }

    It 'puts every live layer above anything that can put more on air' {
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date); UserId = 1; Source = 'bot' }

        $rows = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard)
        $firstRowData = @($rows[0] | ForEach-Object { $_['callback_data'] })

        # The operator opens this menu when the wrong graphic is live; the fix
        # must not sit below the buttons that caused it.
        $firstRowData | Should -Contain 'hide:3'
    }

    It 'places the emergency hide-all directly under the live layers' {
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date); UserId = 1; Source = 'bot' }
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date); UserId = 1; Source = 'cinegy' }

        $rows = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard)
        $flat = @($rows | ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $hideAllIndex = [array]::IndexOf($flat, 'menu:hideall')
        $templatesIndex = [array]::IndexOf($flat, 'menu:templates')

        $hideAllIndex | Should -BeGreaterThan -1
        $hideAllIndex | Should -BeLessThan $templatesIndex
    }

    It 'still offers hide-all when nothing is tracked as live' {
        $flat = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $flat | Should -Contain 'menu:hideall'
    }

    It 'reports what is on air instead of a static prompt' {
        # Read as the operator sees it: the screen is HTML now, so the
        # assertions go against the rendered text rather than the markup.
        ConvertFrom-TelegramHtmlText (Get-MainMenuIntro) | Should -Match 'لا شيء على الهواء'
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date); UserId = 1; Source = 'cinegy' }
        ConvertFrom-TelegramHtmlText (Get-MainMenuIntro) | Should -Match '8 · ticker'
    }

    It 'sends the menu screen as HTML, with the verdict carrying the weight' {
        # The verdict is the one line that has to land in a glance; the
        # engine address and the channel are <code> so they stay LTR and
        # tap-to-copy for an operator quoting them in a fault report.
        $script:OnAir.Clear()
        $text = Get-MainMenuIntro
        @($text -split "`n")[0] | Should -Match '^<b>.+</b>$'
        $text | Should -Match ('<code>' + [regex]::Escape($config.AirServerAddress) + '</code>')

        Mock Send-TelegramMessage { }
        Mock Clear-PendingState { }
        Show-MainMenu -ChatId 909 -UserId 909
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ParseMode -eq 'HTML'
        }
    }

    It 'escapes a template name that would otherwise be read as a tag' {
        # An unescaped '<' makes Telegram refuse the whole message with a
        # 400, which on the phone reads as the menu button doing nothing.
        $script:OnAir.Clear()
        $script:OnAir[3] = @{ Key = '<b>Urgent'; At = (Get-Date); UserId = 1; Source = 'bridge' }
        $text = Get-MainMenuIntro
        $text | Should -Match '&lt;b&gt;Urgent'
        ConvertFrom-TelegramHtmlText $text | Should -Match '<b>Urgent'
    }

    It 'separates the verdict, the air and the machine' {
        # Run together the three read as one paragraph an operator has to
        # parse under pressure; the verdict is what matters at a glance.
        $script:OnAir.Clear()
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = (Get-Date)
        $text = Get-MainMenuIntro
        @($text -split "`n")[0] | Should -Match 'كل شيء سليم'
        $text | Should -Match '━━━'

        $script:OnAir[4] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 1; Source = 'bridge' }
        @((Get-MainMenuIntro) -split "`n")[0] | Should -Match 'طبقات على الهواء'
        # Still three blocks after the HTML rebuild, not three tag soups.
    }

    It 'gives each on-air layer its own line' {
        $script:OnAir.Clear()
        $script:OnAir[4] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 1; Source = 'bridge' }
        $script:OnAir[7] = @{ Key = 'Logo'; At = (Get-Date); UserId = 1; Source = 'bridge' }
        $onAirLines = @((ConvertFrom-TelegramHtmlText (Get-MainMenuIntro)) -split "`n" |
                Where-Object { $_ -match '^ • طبقة' })
        $onAirLines.Count | Should -Be 2
        $onAirLines[0] | Should -Match '4 · Urgent'
        $onAirLines[1] | Should -Match '7 · Logo'
    }

    It 'says the verdict is unconfirmed when the Cinegy reading is stale' {
        $script:OnAir.Clear()
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = [datetime]::MinValue
        Get-MainMenuIntro | Should -Match 'تعذّر تأكيد الحالة'
    }

    It 'names the operator the screen was built for' {
        # The same helper ℹ️ الحالة uses, so one person is written one way on
        # both screens, with the bracketed id pinned LTR after an Arabic name.
        $withUser = Get-MainMenuIntro -UserId 122238225
        $withUser | Should -Match '👤'
        $withUser | Should -Match '122238225'
        # Asked for without an operator - as the tests above do - it stays out
        # rather than printing a bare zero.
        Get-MainMenuIntro | Should -Not -Match '👤'
    }

    It 'names the engine and channel the claim is about' {
        # The menu is where an operator lands, so it answers rather than
        # pointing: which Air engine and channel these layers belong to.
        ConvertFrom-TelegramHtmlText (Get-MainMenuIntro) | Should -Match ([regex]::Escape($config.AirServerAddress))
        Get-MainMenuIntro | Should -Match 'القناة'
    }

    It 'pins the persistent keyboard once per chat, not once per menu press' {
        # Telegram keeps a reply keyboard until it is replaced, so re-sending
        # it put a message saying only "the menu exists" above every single
        # menu the operator opened.
        $script:PersistentKeyboardPinned = @{}
        Mock Send-TelegramMessage { }
        Mock Clear-PendingState { }

        Show-MainMenu -ChatId 909 -UserId 909
        Show-MainMenu -ChatId 909 -UserId 909
        Show-MainMenu -ChatId 909 -UserId 909

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'أسفل الشاشة'
        }
        # The menu itself still arrives every time it is asked for.
        Should -Invoke Send-TelegramMessage -Times 3 -Exactly -ParameterFilter {
            $Text -notmatch 'أسفل الشاشة'
        }
    }

    It 'leads with a greeting but still shows the status under it' {
        # /بدء and /إلغاء passed an -Intro that replaced the screen, so the
        # two most-used doors into the bridge still ended at "اختر من
        # القائمة:" - the data-free line this screen was rebuilt to stop
        # showing.
        $script:PersistentKeyboardPinned = @{ 909 = $true }
        Mock Send-TelegramMessage { }
        Mock Clear-PendingState { }
        Show-MainMenu -ChatId 909 -UserId 909 -Intro 'أهلاً!'
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'أهلاً!' -and $Text -match 'الهواء'
        }
    }

    It 'states how old the on-air claim is, not just what it claims' {
        # A stale "on air" that reads identically to a fresh one is what let an
        # exited scene sit unnoticed for an hour and a half.
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = [datetime]::MinValue
        Get-MainMenuIntro | Should -Match 'لم يتم التحقّق بعد'

        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = (Get-Date)
        Get-MainMenuIntro | Should -Match 'تحقّق قبل'
    }
}

Describe 'Exit clears the on-air record Cinegy cannot report' {
    BeforeEach {
        $script:OnAir = @{}
        $script:onAirFile = Join-Path $TestDrive "onair-exit-$([guid]::NewGuid().ToString('N')).json"
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Send-TelegramMessage {}
        Mock Get-AfterLayerRemovalKeyboard { @{ inline_keyboard = @() } }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
        Mock Write-AirOperationResult {}
        Mock Test-MaintenanceControl { $true }
        Mock Set-RollbackCandidate {}
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $true } }
        # Reproduces the live failure: after EXIT_SCENE_LOOP the item is still
        # Active under the same Id, with no IsEmpty marker to read.
        Mock Get-TitlerLayerStatus {
            [pscustomobject]@{
                Success = $true; IsOnAir = $true; ActiveId = '{0A1072EA-9EFF-11F1-96C0-C85EA97266A8}'
                ActiveName = ''; ActiveTemplateName = ''; ActiveDescription = ''
            }
        }
    }
    AfterAll { $script:OnAir = @{} }

    It 'drops the record even though Cinegy still reports the layer active' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; ActiveId = '{0A1072EA-9EFF-11F1-96C0-C85EA97266A8}'; Source = 'bridge' }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42 | Should -BeTrue

        $script:OnAir.ContainsKey(7) | Should -BeFalse
    }

    It 'leaves other layers alone' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date); UserId = 0; Source = 'cinegy' }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42 | Out-Null

        $script:OnAir.ContainsKey(8) | Should -BeTrue
    }

    It 'keeps the record when the exit command itself failed' {
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $false; Error = 'engine unreachable' } }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-ExitLayer -Layer 7 -ChatId 42 -UserId 42 | Should -BeFalse

        $script:OnAir.ContainsKey(7) | Should -BeTrue
    }

    It 'is a no-op for a layer that was not tracked' {
        Remove-OnAirRecord -Layer 3 -Reason 'test' | Should -BeFalse
    }
}

Describe 'Layer removal confirmation' {
    BeforeEach {
        $script:OnAir = @{}
        Mock Send-TelegramMessage {}
        Mock Invoke-HideLayer { $true }
        Mock Invoke-ExitLayer { $true }
        Mock Test-Authorized { $true }
        Mock Test-TelegramPrivateChat { $true }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserLastActivity {}
    }
    AfterAll { $script:OnAir = @{} }
    BeforeAll {
        function New-HideCallback { param([string]$Data)
            [pscustomobject]@{ id = 'cb1'; data = $Data; from = [pscustomobject]@{ id = 42 }
                message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = 42; type = 'private' } } }
        }
    }

    It 'names the template, its age and who pushed it' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date).AddMinutes(-4); UserId = 42; Source = 'bridge' }
        $summary = Get-LayerRemovalSummary -Layer 7
        $summary | Should -Match 'Urgent'
        $summary | Should -Match 'الطبقة 7'
        $summary | Should -Match 'على الهواء منذ'
    }

    It 'says plainly when the bridge has no record for the layer' {
        Get-LayerRemovalSummary -Layer 3 | Should -Match 'لا يوجد سجل'
    }

    It 'marks a Cinegy-owned scene as started outside the bridge' {
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date); UserId = 0; Source = 'cinegy' }
        Get-LayerRemovalSummary -Layer 8 | Should -Match 'خارج الجسر'
    }

    It 'keeps the emergency path at one tap while confirmation is off' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        Mock Get-Setting { '' } -ParameterFilter { $Name -in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers') }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ShowOnAirTextOnRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'hide:7')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }

    It 'asks first when confirmation is on, and does not touch air yet' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        Mock Get-Setting { '' } -ParameterFilter { $Name -in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers') }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ShowOnAirTextOnRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'hide:7')

        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'Urgent' }
    }

    It 'executes once the operator confirms' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        Mock Get-Setting { '' } -ParameterFilter { $Name -in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers') }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ShowOnAirTextOnRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'hidego:7')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }

    It 'confirms an exit the same way' {
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        Mock Get-Setting { '' } -ParameterFilter { $Name -in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers') }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ShowOnAirTextOnRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'exit:7')
        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly

        Invoke-CallbackQuery -CallbackQuery (New-HideCallback -Data 'exitgo:7')
        Should -Invoke Invoke-ExitLayer -Times 1 -Exactly
    }
}

Describe 'Undo survives navigating away' {
    BeforeEach {
        $script:OnAir = @{}
        $script:RollbackCandidates = @{}
        Mock Test-Admin { $false }
        Mock Get-Setting { $false }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'EnableSafeRollback' }
    }
    AfterAll { $script:RollbackCandidates = @{} }

    It 'offers the rollback from the main menu, not only from the original message' {
        $script:RollbackCandidates[3] = @{ Id = 'r1'; Layer = 3; ActorUserId = 42
            ExpiresAt = (Get-Date).AddSeconds(45); CreatedAt = (Get-Date) }

        $flat = @((Get-MainMenuKeyboard -ChatId 42 -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $flat | Should -Contain 'rollback:3'
    }

    It 'does not offer another operator someone else undo' {
        $script:RollbackCandidates[3] = @{ Id = 'r1'; Layer = 3; ActorUserId = 42
            ExpiresAt = (Get-Date).AddSeconds(45); CreatedAt = (Get-Date) }

        $flat = @((Get-MainMenuKeyboard -ChatId 99 -UserId 99).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $flat | Should -Not -Contain 'rollback:3'
    }

    It 'drops the button once the window has passed' {
        $script:RollbackCandidates[3] = @{ Id = 'r1'; Layer = 3; ActorUserId = 42
            ExpiresAt = (Get-Date).AddSeconds(-1); CreatedAt = (Get-Date).AddMinutes(-5) }

        $flat = @((Get-MainMenuKeyboard -ChatId 42 -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $flat | Should -Not -Contain 'rollback:3'
    }
}

Describe 'On-air row tools' {
    BeforeEach {
        $script:OnAir = @{}
        $script:RollbackCandidates = @{}
        Mock Test-Admin { $false }
    }
    AfterAll { $script:OnAir = @{} }

    It 'offers an instant frame and a copyable status beside the live layers' {
        # The operator can check the bridge's claim against the real output
        # without leaving the chat.
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        $flat = @((Get-MainMenuKeyboard -ChatId 42 -UserId 42).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $flat | Should -Contain 'menu:snapshot'
        $flat | Should -Contain 'menu:sharestatus'
    }

    It 'keeps the emergency hide on that same row' {
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date); UserId = 42; Source = 'bridge' }
        $rows = @((Get-MainMenuKeyboard -ChatId 42 -UserId 42).inline_keyboard)
        $toolRow = @($rows | Where-Object { @($_ | ForEach-Object { $_['callback_data'] }) -contains 'menu:hideall' })
        @($toolRow[0] | ForEach-Object { $_['callback_data'] }) | Should -Contain 'menu:sharestatus'
    }
}

Describe 'Layer lock visibility' {
    BeforeEach {
        $script:LayerLocks = @{}
        Mock Get-UserDisplayName { 'أحمد' }
    }
    AfterAll { $script:LayerLocks = @{} }

    It 'names the holder and how long they have held it' {
        # "المستخدم 7275359265" does not tell the second operator whether to
        # wait or to call across the room.
        $script:LayerLocks[5] = @{ ChatId = 10; UserId = 20; Key = 'lower-third'; StartedAt = (Get-Date).AddMinutes(-2) }

        $notice = Get-LayerLockNotice -Layer 5 -UserId 21
        $notice | Should -Match 'أحمد'
        $notice | Should -Match 'lower-third'
        $notice | Should -Match 'منذ'
    }

    It 'says nothing to the operator who holds the lock themselves' {
        $script:LayerLocks[5] = @{ ChatId = 10; UserId = 20; Key = 'lower-third'; StartedAt = (Get-Date) }
        Get-LayerLockNotice -Layer 5 -UserId 20 | Should -BeNullOrEmpty
    }

    It 'says nothing about a free layer' {
        Get-LayerLockNotice -Layer 5 -UserId 20 | Should -BeNullOrEmpty
    }

    It 'badges a locked layer in the template list, before any field is typed' {
        $script:LayerLocks[5] = @{ ChatId = 10; UserId = 20; Key = 'lower-third'; StartedAt = (Get-Date) }
        Mock Get-TemplateStore {
            @{ Order = @('alpha'); Map = @{ alpha = @{ Key = 'alpha'; Layer = 5; Category = ''; Presets = @() } }; Errors = @() }
        }
        Mock Get-TemplateLastUsedLabel { '' }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ShowLayerLockBadge' }

        $labels = @((Get-TemplatesKeyboard -Prefix tpl).inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_.text } })
        ($labels -join ' ') | Should -Match '🔒'
    }
}

Describe 'Long-running graphics are not stale' {
    BeforeEach {
        # 21 hours on air: past any sane staleness threshold.
        $script:OnAir = @{ 8 = @{ Key = 'News-Ticker'; At = (Get-Date).AddHours(-21); Source = 'bridge'; UserId = 42 } }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'RespectCinegyItemDuration' }
        Mock Get-SettingInt { 3 } -ParameterFilter { $Name -eq 'CinegyMonitorTimeoutSeconds' }
        Mock Get-TemplateStore {
            @{ Order = @('News-Ticker'); Map = @{ 'News-Ticker' = @{ Key = 'News-Ticker'; Layer = 8; Device = ''; LongRunning = $false } } }
        }
        Mock Write-BridgeLog {}
    }
    AfterAll { $script:OnAir = @{} }

    It 'exempts a template the operator marked as long-running' {
        Mock Get-TemplateStore {
            @{ Order = @('News-Ticker'); Map = @{ 'News-Ticker' = @{ Key = 'News-Ticker'; Layer = 8; Device = ''; LongRunning = $true } } }
        }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeTrue
    }

    It 'exempts a graphic Cinegy scheduled for longer than it has been up' {
        # The real case: the ticker's Active Id matched the record exactly, it
        # was genuinely on screen, and administrators were told five times over
        # two days that it was a stale record.
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveDurationSeconds = 86400; ActiveManualEnd = $true } }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeTrue
    }

    It 'still calls it stale once the declared duration has run out' {
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true; ActiveDurationSeconds = 3600; ActiveManualEnd = $false } }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeFalse
    }

    It 'does not silence the alert when Cinegy cannot be reached' {
        # "Cannot check" and "fine" are different things, and only one of them
        # is a reason to stay quiet about a graphic stuck on air.
        Mock Get-TitlerLayerStatus { throw 'connection refused' }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeFalse
    }

    It 'does not silence the alert for a layer Cinegy says is empty' {
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveDurationSeconds = 86400; ActiveManualEnd = $true } }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeFalse
    }

    It 'skips the Cinegy question when the setting is off' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'RespectCinegyItemDuration' }
        Mock Get-TitlerLayerStatus { throw 'should not be called' }

        Test-LongRunningOnAir -Layer 8 -Key 'News-Ticker' | Should -BeFalse
        Should -Invoke Get-TitlerLayerStatus -Times 0 -Exactly
    }
}

Describe 'Named Cinegy layers' {
    BeforeAll { Import-Module (Join-Path $script:Root 'Modules\CinegyAirTitler.psm1') -Force }
    AfterEach { Set-AirLayerDeviceMap -Map @{} }

    It 'addresses an ordinary layer by number' {
        $resolved = Resolve-AirGfxDevice -Layer 7
        $resolved.Command | Should -Be '*GFX_7'
        $resolved.StatusPath | Should -Be 'gfx_7'
    }

    It 'addresses the logo by name, which is how Air Pro exposes it' {
        # Verified against the running engine: gfx_logo answers with a live
        # scene describing itself as "Show logo_mov.cintitle as logo", while
        # the numeric layers that template claimed simply do not exist.
        $resolved = Resolve-AirGfxDevice -Device 'logo'
        $resolved.Command | Should -Be '*GFX_LOGO'
        $resolved.StatusPath | Should -Be 'gfx_logo'
    }

    It 'resolves a mapped layer number to its device, so call sites need no change' {
        Set-AirLayerDeviceMap -Map @{ 9 = 'logo' }
        (Resolve-AirGfxDevice -Layer 9).StatusPath | Should -Be 'gfx_logo'
        (Resolve-AirGfxDevice -Layer 7).StatusPath | Should -Be 'gfx_7'
    }

    It 'lets an explicit device win over the map' {
        Set-AirLayerDeviceMap -Map @{ 9 = 'logo' }
        (Resolve-AirGfxDevice -Layer 9 -Device 'other').StatusPath | Should -Be 'gfx_other'
    }

    It 'clears the map when given an empty one' {
        Set-AirLayerDeviceMap -Map @{ 9 = 'logo' }
        Set-AirLayerDeviceMap -Map @{}
        (Resolve-AirGfxDevice -Layer 9).StatusPath | Should -Be 'gfx_9'
    }

    It 'ignores a blank device name rather than building gfx_' {
        Set-AirLayerDeviceMap -Map @{ 9 = '' }
        (Resolve-AirGfxDevice -Layer 9).StatusPath | Should -Be 'gfx_9'
    }

    It 'refuses a device name that could reshape the request path' {
        # It goes straight into a URL and an XML attribute.
        { Resolve-AirGfxDevice -Device '../video' } | Should -Throw
        { Resolve-AirGfxDevice -Device 'a b' } | Should -Throw
    }
}

Describe 'Confirming removal of a live graphic' {
    BeforeEach {
        $script:OnAir = @{}
        Mock Send-TelegramMessage {}
        Mock Invoke-HideLayer { $true }
        Mock Invoke-ExitLayer { $true }
        Mock Test-Authorized { $true }
        Mock Test-TelegramPrivateChat { $true }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserLastActivity {}
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        Mock Get-Setting { '' } -ParameterFilter { $Name -in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers') }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ShowOnAirTextOnRemoval' }
    }
    AfterAll { $script:OnAir = @{} }
    BeforeAll {
        function New-Cb { param([string]$Data)
            [pscustomobject]@{ id = 'cb1'; data = $Data; from = [pscustomobject]@{ id = 42 }
                message = [pscustomobject]@{ message_id = 1; chat = [pscustomobject]@{ id = 42; type = 'private' } } }
        }
    }

    It 'refuses to take a live graphic off air on one tap' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'hide:7')

        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تأكيد الإخفاء' -and $Text -match 'Urgent' }
    }

    It 'requires the same confirmation before an exit' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'exit:7')

        Should -Invoke Invoke-ExitLayer -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تأكيد الخروج' }
    }

    It 'acts once the operator confirms' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'hidego:7')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }

    It 'does not ask about a layer with nothing on it' {
        # Friction on a path that does not matter is how operators learn to tap
        # straight through the confirmation that does.
        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'hide:3')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'is on by default, so a fresh install protects the air' {
        $defaults = $script:DefaultSettings
        $defaults['ConfirmLayerRemoval'] | Should -BeTrue
    }

    It 'can still be turned off for a room that wants one-tap hides' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'ConfirmLayerRemoval' }
        Mock Get-Setting { '' } -ParameterFilter { $Name -in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers') }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'ShowOnAirTextOnRemoval' }
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Invoke-CallbackQuery -CallbackQuery (New-Cb -Data 'hide:7')

        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }
}

Describe 'Audit actor label' {
    It 'keeps the bracketed id left-to-right beside an Arabic name' {
        Mock Get-UserDisplayName { 'الغازي' }

        $label = Format-UserAuditActor -UserId 8201739556

        # Without the marks the brackets render mirrored on the 📜 screen,
        # because the line around them reads right-to-left.
        $label | Should -Be "الغازي $([char]0x200E)(8201739556)$([char]0x200E)"
    }

    It 'falls back to the bare id when there is no name to show' {
        Mock Get-UserDisplayName { '' }

        Format-UserAuditActor -UserId 8201739556 | Should -Be '8201739556'
    }
}

Describe 'What came off air is named and quoted' {
    BeforeEach {
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-TelegramMessage { }
        Mock Write-AuditRecord { }
        Mock Add-UserOperationHistory { }
        Mock Sync-LayerAfterOperatorAction { }
        Mock Save-OnAirState { }
        Mock Test-MaintenanceControl { $true }
        # Through the config, not a filtered mock of Get-Setting: that would
        # need a default mock for every other setting this flow reads.
        $script:RollbackWas = Get-Setting 'EnableSafeRollback'
        $config.Settings | Add-Member -NotePropertyName EnableSafeRollback -NotePropertyValue $false -Force
        $script:OnAir.Clear()
    }
    AfterEach {
        $config.Settings | Add-Member -NotePropertyName EnableSafeRollback -NotePropertyValue $script:RollbackWas -Force
        $script:OnAir.Clear()
    }

    It 'carries the on-air copy on the layer record, so a hide can quote it' {
        # The record held the key and the time only, so hiding recorded a
        # layer number and nothing else - the history could say something was
        # hidden but never which strap.
        Set-OnAirShownRecord -Layer 7 -Record @{
            Key = 'urgent'; At = (Get-Date); UserId = 10; ActiveId = ''
            ActiveIdConfirmed = $false; AirCopy = 'text: عاجل'
        }

        Get-JsonProp $script:OnAir[7] 'AirCopy' | Should -Be 'text: عاجل'
    }

    It 'names and quotes the outgoing banner when a layer is hidden' {
        Mock Hide-TitlerTemplate { @{ Success = $true; Error = '' } }
        Set-OnAirShownRecord -Layer 7 -Record @{
            Key = 'urgent'; At = (Get-Date); UserId = 10; ActiveId = ''
            ActiveIdConfirmed = $false; AirCopy = 'text: عاجل'
        }

        Invoke-HideLayer -Layer 7 -ChatId 10 -UserId 10 -Quiet | Out-Null

        Should -Invoke Add-UserOperationHistory -Times 1 -Exactly -ParameterFilter {
            $Action -eq 'HIDE' -and $Target -eq 'urgent' -and $Values -eq 'text: عاجل'
        }
    }

    It 'records nothing rather than guessing when the layer was already empty' {
        Mock Hide-TitlerTemplate { @{ Success = $true; Error = '' } }

        Invoke-HideLayer -Layer 4 -ChatId 10 -UserId 10 -Quiet | Out-Null

        Should -Invoke Add-UserOperationHistory -Times 1 -Exactly -ParameterFilter {
            $Action -eq 'HIDE' -and $Target -eq '' -and $Values -eq ''
        }
    }
}

Describe 'Noticing that the logo or the strip is gone' {
    BeforeEach {
        Mock Write-BridgeLog { }
        Mock Send-AdminBroadcast { $true }
        Mock Get-LayerDisplayName { "طبقة $Layer" }
        $script:MissingGraphicState = @{}
        $config.Settings | Add-Member -NotePropertyName 'NotifyAdminsOnMissingGraphic' -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName 'MissingGraphicConfirmChecks' -NotePropertyValue 2 -Force
        Mock Get-TemplateStore {
            @{
                Order = @('logo', 'News-Ticker', 'Urgent')
                Map = @{
                    'logo' = @{ Key = 'logo'; Layer = 9; LongRunning = $true }
                    'News-Ticker' = @{ Key = 'News-Ticker'; Layer = 8; LongRunning = $true }
                    # Not permanent: nobody expects it to sit there.
                    'Urgent' = @{ Key = 'Urgent'; Layer = 7; LongRunning = $false }
                }
            }
        }
    }

    function global:New-TestLayerState {
        param([int]$Layer, [bool]$OnAir = $true, [bool]$Success = $true)
        [pscustomobject]@{ Layer = $Layer; Success = $Success; IsOnAir = $OnAir }
    }

    It 'counts only the templates declared permanent' {
        @(Get-BridgePermanentGraphics).Key | Should -Be @('logo', 'News-Ticker')
    }

    It 'stays quiet while both are up' {
        Update-MissingGraphicWatchdog -LayerStatuses @((New-TestLayerState -Layer 9), (New-TestLayerState -Layer 8))
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'waits for the miss to be confirmed before saying anything' {
        # A permanent graphic is legitimately down for the seconds a swap
        # takes, and an alert on every such moment is one nobody reads.
        $gone = @((New-TestLayerState -Layer 9 -OnAir $false), (New-TestLayerState -Layer 8))

        Update-MissingGraphicWatchdog -LayerStatuses $gone
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly

        Update-MissingGraphicWatchdog -LayerStatuses $gone
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'logo' -and $Text -match 'ليس على الهواء' }
    }

    It 'says it once, not on every check afterwards' {
        $gone = @((New-TestLayerState -Layer 9 -OnAir $false), (New-TestLayerState -Layer 8))
        1..6 | ForEach-Object { Update-MissingGraphicWatchdog -LayerStatuses $gone }
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
    }

    It 'says so again when it comes back' {
        $gone = @((New-TestLayerState -Layer 9 -OnAir $false), (New-TestLayerState -Layer 8))
        1..2 | ForEach-Object { Update-MissingGraphicWatchdog -LayerStatuses $gone }

        Update-MissingGraphicWatchdog -LayerStatuses @((New-TestLayerState -Layer 9), (New-TestLayerState -Layer 8))
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'عاد' }
    }

    It 'treats an engine that did not answer as no news, not as missing' {
        # The layer read failed; that says nothing about what is on it.
        $unknown = @((New-TestLayerState -Layer 9 -OnAir $false -Success $false), (New-TestLayerState -Layer 8))
        1..5 | ForEach-Object { Update-MissingGraphicWatchdog -LayerStatuses $unknown }
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'ignores a template nobody said was permanent' {
        $gone = @((New-TestLayerState -Layer 9), (New-TestLayerState -Layer 8), (New-TestLayerState -Layer 7 -OnAir $false))
        1..4 | ForEach-Object { Update-MissingGraphicWatchdog -LayerStatuses $gone }
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'says nothing at all when the option is off' {
        $config.Settings | Add-Member -NotePropertyName 'NotifyAdminsOnMissingGraphic' -NotePropertyValue $false -Force
        $gone = @((New-TestLayerState -Layer 9 -OnAir $false), (New-TestLayerState -Layer 8 -OnAir $false))
        1..4 | ForEach-Object { Update-MissingGraphicWatchdog -LayerStatuses $gone }
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }
}
