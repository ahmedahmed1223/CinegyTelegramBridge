#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')
Describe 'Full urgent reader and manual single story' {
    BeforeEach {
        $script:UrgentBoard = New-UrgentBoard
        $script:UrgentBoardRun = $null
        $script:PendingState.Clear()
        $script:OnAir = @{}
        $script:UrgentManualLive = @{}
        $script:UrgentManualMode = @{}
        $script:ManualPayload = $null
        $script:ManualText = ('تفاصيل الخبر الطويل <نص> & ' * 8) + 'نهاية الخبر'
        $script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text $script:ManualText -UserId 101).Value
        # Clean up any leftover manual state file from previous tests
        $leftover = Join-Path $TestDrive 'urgent-manual.json'
        if (Test-Path $leftover) { Remove-Item $leftover -Force -ErrorAction SilentlyContinue }
        Mock Get-UrgentTemplate { @{ Key='urgent'; Layer=7; Fields=@('Text','Kicker') } }
        Mock Get-UrgentSceneTiming { @{ LoopSeconds=8; IntroSeconds=2; OutroSeconds=2 } }
        Mock Send-TelegramMessage { $script:ManualPayload = @{Text=$Text; Markup=$ReplyMarkup} }
        Mock Edit-TelegramMessageText { $script:ManualPayload = @{Text=$Text; Markup=$ReplyMarkup}; $true }
        Mock Invoke-ShowTemplateResult { throw 'No air allowed in reader' }
        Mock Invoke-HideLayer { throw 'No air allowed in reader' }
    }
    It 'opens a paged full reader with navigation and no air commands' {
        $item = $script:UrgentBoard.Items[0]
        $item.Text = ('< & تفاصيل ' * 600)
        Show-UrgentReader -ChatId 100 -UserId 101 -ItemId $item.Id -MessageId 9
        $script:ManualPayload.Text.Length | Should -BeLessOrEqual 4096
        $script:ManualPayload.Text | Should -Match 'الخبر 1 من 1'
        $buttons = @($script:ManualPayload.Markup.inline_keyboard | ForEach-Object { $_ })
        @($buttons | Where-Object callback_data -like 'urgread:*').Count | Should -BeGreaterThan 0
        $chunks = @(Split-UrgentReaderText -Text $item.Text)
        ($chunks -join '') | Should -Be $item.Text
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
    }
    It 'shows only the chosen story after confirmation without starting a sequence' {
        Mock Test-Authorized { $true }
        Mock Test-MaintenanceControl { $true }
        Mock Invoke-ShowTemplateResult {
            $script:OnAir[7] = @{ Key='urgent'; At=[datetimeoffset]::Now; ActiveId='same-template' }
            @{ Success=$true }
        }
        $id = $script:UrgentBoard.Items[0].Id
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id -MessageId 9
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        $state = Get-PendingState -ChatId 100
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$($state.Token)" | Should -BeTrue
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $Variables.Text -eq $script:ManualText -and $AutoHideSeconds -eq 0 }
        $script:UrgentBoardRun | Should -BeNullOrEmpty
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$($state.Token)" | Should -BeFalse
    }
    It 'offers a timed button beside run-on-air, and only the timed one carries the hide time' {
        Mock Test-Authorized { $true }
        Mock Test-MaintenanceControl { $true }
        Mock Invoke-ShowTemplateResult {
            $script:OnAir[7] = @{ Key='urgent'; At=[datetimeoffset]::Now; ActiveId='same-template' }
            @{ Success=$true }
        }
        # The story holds the screen 90 s in a sequence, so the picker stars 90.
        $script:UrgentBoard.Items[0].IntervalSeconds = 90
        try {
            $id = $script:UrgentBoard.Items[0].Id
            $row = @((Get-UrgentItemKeyboard -Position 0).inline_keyboard[0])
            @($row | ForEach-Object { $_['callback_data'] }) | Should -Be @("urgsingle:$id", "urgsingle:${id}:t")

            # The timed button opens the template presets, starring the story's own gap.
            Show-UrgentTimedPicker -ChatId 100 -UserId 101 -ItemId $id -MessageId 9
            $picks = @($script:ManualPayload.Markup.inline_keyboard | ForEach-Object { $_ })
            @($picks | Where-Object { $_['callback_data'] -eq "urgt:${id}:90" -and $_['text'] -like '*⭐*' }).Count | Should -Be 1
            @($picks | Where-Object { $_['callback_data'] -eq "urgt:${id}:c" }).Count | Should -Be 1
            @($picks | Where-Object { $_['callback_data'] -eq "urgentb:item:$id" }).Count | Should -Be 1 -Because 'back returns to the story'

            # The plain button: no timer, as before.
            Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id -MessageId 9
            $script:ManualPayload.Text | Should -Not -Match ([regex]::Escape((Format-DurationSeconds -Seconds 90)))
            $state = Get-PendingState -ChatId 100
            Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$($state.Token)" | Should -BeTrue
            Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $AutoHideSeconds -eq 0 }

            # The timed button: the board's duration, said on the review and on the live message.
            $script:OnAir = @{}; $script:UrgentManualLive = @{}
            Invoke-UrgentTimedPick -ChatId 100 -UserId 101 -Argument "${id}:90" -MessageId 9 | Should -BeTrue
            $script:ManualPayload.Text | Should -Match ([regex]::Escape((Format-DurationSeconds -Seconds 90)))
            $state = Get-PendingState -ChatId 100
            Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$($state.Token)" | Should -BeTrue
            Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $AutoHideSeconds -eq 90 }
            $script:ManualPayload.Text | Should -Match ([regex]::Escape((Format-DurationSeconds -Seconds 90)))
        }
        finally { $script:UrgentBoard.Items[0].IntervalSeconds = 0 }
    }
    It 'takes a typed duration for the timed show, and asks again for a bad one' {
        Mock Test-Authorized { $true }
        $id = $script:UrgentBoard.Items[0].Id
        Invoke-UrgentTimedPick -ChatId 100 -UserId 101 -Argument "${id}:c" | Should -BeTrue
        (Get-PendingState -ChatId 100).Mode | Should -Be 'urgent_timed_custom'
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value 'abc' | Should -BeFalse
        (Get-PendingState -ChatId 100).Mode | Should -Be 'urgent_timed_custom' -Because 'a wrong number keeps the flow open'
        Complete-UrgentBoardText -ChatId 100 -UserId 101 -Value '45' | Should -BeTrue
        (Get-PendingState -ChatId 100).Mode | Should -Be 'urgent_manual_confirm'
        (Get-PendingState -ChatId 100).AutoHideSeconds | Should -Be 45
        $script:ManualPayload.Text | Should -Match ([regex]::Escape((Format-DurationSeconds -Seconds 45)))
    }
    It 'keeps each user their own manual or sequence choice, across a restart' {
        Mock Test-Authorized { $true }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserNameFromTelegram {}
        Mock Update-UserLastActivity {}
        Mock Show-UrgentBoardScreen {}
        Mock Write-BridgeLog {}
        $q = @{ id='m'; from=@{ id=101 }; message=@{ message_id=9; chat=@{ id=101; type='private' } }; data='urgmode:manual' }
        Invoke-CallbackQuery $q
        $buttons = @((Get-UrgentBoardKeyboard -ChatId 101 -UserId 101).inline_keyboard | ForEach-Object { $_ })
        @($buttons | Where-Object { $_['callback_data'] -eq 'urgmode:manual' -and $_['text'] -like '*✅*' }).Count | Should -Be 1 -Because 'user 101 chose manual'
        $other = @((Get-UrgentBoardKeyboard -ChatId 102 -UserId 102).inline_keyboard | ForEach-Object { $_ })
        @($other | Where-Object { $_['callback_data'] -eq 'urgmode:auto' -and $_['text'] -like '*✅*' }).Count | Should -Be 1 -Because 'user 102 still runs the sequence'
        Should -Invoke Write-BridgeLog -Times 1 -ParameterFilter { $Message -like 'User 101 set the urgent board to manual mode*saved: True*' }

        $script:UrgentManualMode = @{}
        Import-UrgentManualState
        $script:UrgentManualMode[[long]101] | Should -BeTrue -Because 'the choice survives a restart'
    }
    It 'reads a manual-mode file written before 8.71.3, keyed by private chat' {
        $legacy = '{"SchemaVersion":2,"SavedAt":"2026-09-21T10:31:39+03:00","States":[],"ManualMode":[{"ChatId":122238225,"Mode":true}],"Selections":[]}'
        Set-Content -LiteralPath (Get-UrgentManualFile) -Value $legacy -Encoding utf8
        Import-UrgentManualState
        $script:UrgentManualMode[[long]122238225] | Should -BeTrue
    }
    It 'offers manual mode and reaches full reading through actual callbacks' {
        Mock Test-Authorized { $true }
        Mock Confirm-TelegramCallback {}
        Mock Update-UserNameFromTelegram {}
        Mock Update-UserLastActivity {}
        Mock Show-UrgentBoardScreen {}
        $id=$script:UrgentBoard.Items[0].Id
        $q=@{id='manual';from=@{id=101};message=@{message_id=9;chat=@{id=100;type='private'}};data='urgmode:manual'}
        Invoke-CallbackQuery $q
        $buttons=@((Get-UrgentBoardKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { $_ })
        $buttons.callback_data | Should -Not -Contain 'urgentb:review:all'
        $buttons.callback_data | Should -Contain "urgread:${id}:0"
        $q.data="urgread:${id}:0"
        Invoke-CallbackQuery $q
        $script:ManualPayload.Text | Should -Match 'نهاية الخبر'
        $q.data="urgsingle:$id"
        Invoke-CallbackQuery $q
        (Get-PendingState -ChatId 100).Mode | Should -Be 'urgent_manual_confirm'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
    It 'does not hide a newer show even when template and ActiveId are reused' {
        Mock Test-Authorized { $true }
        Mock Test-MaintenanceControl { $true }
        Mock Invoke-ShowTemplateResult { $script:OnAir[7]=@{Key='urgent';ActiveId='same';At=[datetimeoffset]::Now}; @{Success=$true} }
        Mock Invoke-HideLayer { $true }
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $script:UrgentBoard.Items[0].Id
        $token=(Get-PendingState -ChatId 100).Token
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$token" | Should -BeTrue
        $hide=$script:UrgentManualLive[100L].Token
        $script:OnAir[7].At=$script:OnAir[7].At.AddSeconds(1)
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "hide:$hide" | Should -BeFalse
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
    }
    It 'refuses changed editorial text and failed automatic-run stop before showing' {
        Mock Test-Authorized { $true }
        Mock Test-MaintenanceControl { $true }
        Mock Stop-UrgentBoardRun { $false }
        $id=$script:UrgentBoard.Items[0].Id
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id
        $token=(Get-PendingState -ChatId 100).Token
        $script:UrgentBoard.Items[0].Text='تعديل لاحق'
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$token" | Should -BeFalse
        $script:UrgentBoardRun=@{Step=0}
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id
        $token=(Get-PendingState -ChatId 100).Token
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$token" | Should -BeFalse
        Should -Invoke Stop-UrgentBoardRun -Times 1 -Exactly
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
    It 'returns to reading on cancel and makes the old show confirmation unusable' {
        Mock Test-Authorized { $true }
        Mock Test-MaintenanceControl { $true }
        $id=$script:UrgentBoard.Items[0].Id
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id
        $token=(Get-PendingState -ChatId 100).Token
        Show-UrgentReader -ChatId 100 -UserId 101 -ItemId $id
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$token" | Should -BeFalse
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
    It 'shows story one hides it and then shows story four through real callbacks' {
        Mock Test-Authorized { $true }; Mock Test-MaintenanceControl { $true }
        Mock Confirm-TelegramCallback {}; Mock Update-UserNameFromTelegram {}; Mock Update-UserLastActivity {}
        Mock Invoke-HideLayer { $script:OnAir.Remove(7); $true }
        Mock Invoke-ShowTemplateResult { $script:OnAir[7]=@{Key='urgent';ActiveId='reused';At=[datetimeoffset]::Now}; @{Success=$true} }
        for($n=2;$n -le 4;$n++) { $script:UrgentBoard=(Add-UrgentItem -Board $script:UrgentBoard -Text "خبر $n" -UserId 101).Value }
        $q=@{id='manual-chain';from=@{id=101};message=@{message_id=9;chat=@{id=100;type='private'}};data="urgsingle:$($script:UrgentBoard.Items[0].Id)"}
        Invoke-CallbackQuery $q
        $q.data="urgmanual:show:$((Get-PendingState -ChatId 100).Token)"; Invoke-CallbackQuery $q
        $oldHide="urgmanual:hide:$($script:UrgentManualLive[100L].Token)"
        $q.data=$oldHide; Invoke-CallbackQuery $q
        $script:OnAir.ContainsKey(7) | Should -BeFalse
        $q.data="urgsingle:$($script:UrgentBoard.Items[3].Id)"; Invoke-CallbackQuery $q
        $q.data="urgmanual:show:$((Get-PendingState -ChatId 100).Token)"; Invoke-CallbackQuery $q
        $q.data=$oldHide; Invoke-CallbackQuery $q
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        Should -Invoke Invoke-ShowTemplateResult -Times 2 -Exactly
        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter { $Variables.Text -eq 'خبر 4' }
        $script:UrgentBoardRun | Should -BeNullOrEmpty
    }
    It 'does not stop playback when manual show access or policy is denied' {
        Mock Test-Authorized { $true }; Mock Test-MaintenanceControl { $true }
        Mock Stop-UrgentBoardRun { $true }
        Mock Invoke-ShowTemplateResult { @{Success=$false} }
        $script:UrgentBoardRun=@{Step=0}
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $script:UrgentBoard.Items[0].Id
        $token=(Get-PendingState -ChatId 100).Token
        Mock Test-TemplateAccess { @{Allowed=$false} }
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$token" | Should -BeFalse
        Should -Invoke Stop-UrgentBoardRun -Times 0 -Exactly
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
        Mock Test-TemplateAccess { @{Allowed=$true} }
        Mock Test-TemplateShowPolicy { @{Allowed=$false} }
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$token" | Should -BeFalse
        Should -Invoke Stop-UrgentBoardRun -Times 0 -Exactly
    }
    It 'rechecks revoked access before hiding a manually displayed story' {
        Mock Test-Authorized { $true }; Mock Test-MaintenanceControl { $true }
        Mock Invoke-ShowTemplateResult { $script:OnAir[7]=@{Key='urgent';ActiveId='same';At=[datetimeoffset]::Now}; @{Success=$true} }
        Mock Invoke-HideLayer { $true }
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $script:UrgentBoard.Items[0].Id
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$((Get-PendingState -ChatId 100).Token)" | Should -BeTrue
        $button=@($script:ManualPayload.Markup.inline_keyboard | ForEach-Object { $_ } | Where-Object callback_data -like 'urgmanual:hide:*')[0].callback_data
        Mock Test-TemplateAccess { @{Allowed=$false} }
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument (Get-CallbackArg $button 'urgmanual:') | Should -BeFalse
        Should -Invoke Invoke-HideLayer -Times 0 -Exactly
    }
    It 'stops a manually displayed story from the urgent board control' {
        Mock Test-Authorized { $true }; Mock Test-MaintenanceControl { $true }
        Mock Invoke-ShowTemplateResult { $script:OnAir[7]=@{Key='urgent';ActiveId='same';At=[datetimeoffset]::Now}; @{Success=$true} }
        Mock Invoke-HideLayer { $script:OnAir.Remove(7); $true }
        $id = $script:UrgentBoard.Items[0].Id
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$((Get-PendingState -ChatId 100).Token)" | Should -BeTrue

        Stop-UrgentCurrentAir -ChatId 100 -UserId 101 | Should -BeTrue
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
        $script:UrgentManualLive.Count | Should -Be 0
    }
    It 'keeps the live hide button after canceled replacement and expired unrelated editing' {
        Mock Test-Authorized { $true }; Mock Test-MaintenanceControl { $true }
        Mock Invoke-ShowTemplateResult { $script:OnAir[7]=@{Key='urgent';ActiveId='same';At=[datetimeoffset]::Now}; @{Success=$true} }
        Mock Invoke-HideLayer { $true }
        $id=$script:UrgentBoard.Items[0].Id
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$((Get-PendingState -ChatId 100).Token)" | Should -BeTrue
        $button=@($script:ManualPayload.Markup.inline_keyboard | ForEach-Object { $_ } | Where-Object callback_data -like 'urgmanual:hide:*')[0].callback_data
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id
        Show-UrgentReader -ChatId 100 -UserId 101 -ItemId $id
        Set-PendingState -ChatId 100 -State @{Mode='urgent_item_text';UserId=101;StartedAt=(Get-Date).AddDays(-1)}
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument (Get-CallbackArg $button 'urgmanual:') | Should -BeTrue
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly
    }
    It 'selections are saved to disk when Save-UrgentManualState runs' {
        $testFile = Join-Path $env:TEMP "urgent-manual-save-$(New-Guid).json"
        Mock Get-UrgentManualFile { $testFile }
        Set-UrgentSelectedIds -ChatId 100 -Ids @('u_sel0001', 'u_sel0002')
        Save-UrgentManualState | Out-Null
        (Get-Content $testFile -Raw | ConvertFrom-Json).Selections.Count | Should -Be 1
        if (Test-Path $testFile) { Remove-Item $testFile -Force -ErrorAction SilentlyContinue }
    }
    It 'persists manual show identity and mode across a restart' {
        $script:TestManualFile = Join-Path $env:TEMP "urgent-manual-persist-$(New-Guid).json"
        Mock Get-UrgentManualFile { $script:TestManualFile }
        Mock Test-Authorized { $true }; Mock Test-MaintenanceControl { $true }
        Mock Invoke-ShowTemplateResult { $script:OnAir[7]=@{Key='urgent';ActiveId='same';At=[datetimeoffset]::Now}; @{Success=$true} }
        Mock Invoke-HideLayer { $true }
        $id=$script:UrgentBoard.Items[0].Id
        Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id
        Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$((Get-PendingState -ChatId 100).Token)" | Should -BeTrue
        $savedLive = $script:UrgentManualLive[100L]
        $savedLive | Should -Not -BeNullOrEmpty
        $script:UrgentManualLive = @{}; $script:UrgentManualMode = @{}
        Import-UrgentManualState
        $script:UrgentManualLive[100L].Token | Should -Be $savedLive.Token
        if (Test-Path $script:TestManualFile) { Remove-Item $script:TestManualFile -Force -ErrorAction SilentlyContinue }
    }
    It 'clears the manual state file when all live shows end' {
        $testFile = Join-Path $env:TEMP "urgent-manual-clear-$(New-Guid).json"
        Mock Get-UrgentManualFile { $testFile }
        try {
            Mock Test-Authorized { $true }; Mock Test-MaintenanceControl { $true }
            Mock Invoke-ShowTemplateResult { $script:OnAir[7]=@{Key='urgent';ActiveId='same';At=[datetimeoffset]::Now}; @{Success=$true} }
            Mock Invoke-HideLayer { $script:OnAir.Remove(7); $true }
            $id=$script:UrgentBoard.Items[0].Id
            Show-UrgentManualConfirm -ChatId 100 -UserId 101 -ItemId $id
            Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument "show:$((Get-PendingState -ChatId 100).Token)" | Should -BeTrue
            $script:UrgentManualLive.Count | Should -BeGreaterThan 0
            $button=@($script:ManualPayload.Markup.inline_keyboard | ForEach-Object { $_ } | Where-Object callback_data -like 'urgmanual:hide:*')[0].callback_data
            Invoke-UrgentManualAction -ChatId 100 -UserId 101 -Argument (Get-CallbackArg $button 'urgmanual:') | Should -BeTrue
            $script:UrgentManualLive.Count | Should -Be 0
        } finally {
            if (Test-Path $testFile) { Remove-Item $testFile -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'recovers safely from a corrupt manual state file' {
        $testFile = Join-Path $env:TEMP "urgent-manual-corrupt-$(New-Guid).json"
        Mock Get-UrgentManualFile { $testFile }
        Set-Content -Path $testFile -Value '{ invalid json [[}' -Encoding utf8
        { Import-UrgentManualState } | Should -Not -Throw
        $script:UrgentManualLive.Count | Should -Be 0
        $script:UrgentManualMode.Count | Should -Be 0
        if (Test-Path $testFile) { Remove-Item $testFile -Force -ErrorAction SilentlyContinue }
    }
    It 'shows T-12 fix buttons in the board keyboard when warnings apply' {
        Mock Test-Authorized { $true }
        Mock Test-UrgentSceneLoop { $false }
        Mock Get-UrgentRunCeiling { @{Seconds=30;AutoHideSeconds=30;Reason='autohide'} }
        $kb = Get-UrgentBoardKeyboard -ChatId 100
        $all = @($kb.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.callback_data })
        $all | Should -Contain 'urgentb:timing'
    }
    It 'keeps the complete long story in field mapping and the bot detail screen' {
        $item = @($script:UrgentBoard.Items)[0]
        (Get-UrgentItemVariables -Item $item).Text | Should -Be $script:ManualText
        Show-UrgentItemScreen -ChatId 100 -Position 0 -MessageId 9
        $script:ManualPayload.Text | Should -Match ([regex]::Escape((ConvertTo-TelegramHtmlText $script:ManualText)))
        $script:ManualPayload.Text | Should -Match 'نهاية الخبر'
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
}
