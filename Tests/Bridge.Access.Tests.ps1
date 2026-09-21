#requires -Version 7
<#
    Bridge.Access.Tests.ps1 - who may put a graphic on air, and take it off.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Per-template and per-layer permission' {
    BeforeEach {
        foreach ($name in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers')) {
            $config.Settings | Add-Member -NotePropertyName $name -NotePropertyValue '' -Force
        }
        Mock Test-Admin { $false }
        Mock Test-Owner { $false }
    }

    It 'lets everyone through when nothing is named' {
        (Test-TemplateAccess -Key 'Urgent' -Layer 7 -ChatId 100 -UserId 101).Allowed | Should -BeTrue
        Get-TemplateAccessLevel -Key 'Urgent' -Layer 7 | Should -Be 'all'
    }

    It 'keeps a named template to administrators' {
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyTemplateKeys' -NotePropertyValue 'Urgent, logo' -Force

        $refused = Test-TemplateAccess -Key 'Urgent' -Layer 7 -ChatId 100 -UserId 101
        $refused.Allowed | Should -BeFalse
        $refused.Reason | Should -Match 'للمشرفين'

        Mock Test-Admin { $true }
        (Test-TemplateAccess -Key 'Urgent' -Layer 7 -ChatId 100 -UserId 101).Allowed | Should -BeTrue
        # Another template in the same registry is untouched.
        (Test-TemplateAccess -Key 'Mojaz' -Layer 5 -ChatId 100 -UserId 101).Allowed | Should -BeTrue
    }

    It 'keeps a named template to the owner, and an administrator is not enough' {
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyTemplateKeys' -NotePropertyValue 'logo' -Force
        Mock Test-Admin { $true }

        $refused = Test-TemplateAccess -Key 'logo' -Layer 9 -ChatId 100 -UserId 101
        $refused.Allowed | Should -BeFalse
        $refused.Reason | Should -Match 'مالك الجسر'

        Mock Test-Owner { $true }
        (Test-TemplateAccess -Key 'logo' -Layer 9 -ChatId 100 -UserId 101).Allowed | Should -BeTrue
    }

    It 'protects a layer whatever template is on it' {
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyLayers' -NotePropertyValue '9' -Force

        (Test-TemplateAccess -Key 'anything' -Layer 9 -ChatId 100 -UserId 101).Allowed | Should -BeFalse
        (Test-TemplateAccess -Key 'anything' -Layer 8 -ChatId 100 -UserId 101).Allowed | Should -BeTrue
    }

    It 'takes the stricter of the two rules that apply' {
        # A permission that loosens when a second rule is added is not one.
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyTemplateKeys' -NotePropertyValue 'logo' -Force
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyLayers' -NotePropertyValue '9' -Force

        Get-TemplateAccessLevel -Key 'logo' -Layer 9 | Should -Be 'owner'
        Mock Test-Admin { $true }
        (Test-TemplateAccess -Key 'logo' -Layer 9 -ChatId 100 -UserId 101).Allowed | Should -BeFalse
    }

    It 'reads the lists the way every other list in the bridge is written' {
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyTemplateKeys' -NotePropertyValue "Urgent;  logo `n News-Ticker" -Force

        foreach ($key in @('Urgent', 'logo', 'News-Ticker')) {
            (Test-TemplateAccess -Key $key -Layer 0 -ChatId 100 -UserId 101).Allowed | Should -BeFalse
        }
        # Case is not the operator's problem.
        (Test-TemplateAccess -Key 'URGENT' -Layer 0 -ChatId 100 -UserId 101).Allowed | Should -BeFalse
        (Test-TemplateAccess -Key 'Mojaz' -Layer 0 -ChatId 100 -UserId 101).Allowed | Should -BeTrue
    }

    It 'refuses the show before anything reaches air' {
        Mock Send-TelegramMessage {}
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true } }
        Mock Write-AirOperationResult {}
        Mock Test-MaintenanceControl { $true }
        Mock Get-TemplateStore {
            @{ Map = @{ 'Urgent' = @{ Key = 'Urgent'; Path = 'D:\air\Urgent-Mov.cintitle'; Layer = 7; Fields = @() } }
                Order = @('Urgent') }
        }
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyTemplateKeys' -NotePropertyValue 'Urgent' -Force

        $result = Invoke-ShowTemplateResult -Key 'Urgent' -Variables @{} -ChatId 100 -UserId 101

        $result.Success | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -match 'مالك الجسر' }
    }
}

Describe 'Every setting the code reads is a setting the bridge declares' {
    It 'finds no name asked for that DefaultSettings has never heard of' {
        # The bug this exists for: four permission settings were read by the
        # show and hide paths but never added to DefaultSettings, so they had
        # no value, no label, and no place on the settings screen - and the
        # feature was silently inert while its own tests passed, because the
        # tests set the values directly.
        $root = Split-Path $PSScriptRoot -Parent
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'Parts') -Filter '*.ps1' -File) +
        @(Get-ChildItem -LiteralPath (Join-Path $root 'Modules') -Filter '*.psm1' -File) +
        @(Get-Item -LiteralPath (Join-Path $root 'TelegramBridge.ps1'))

        $asked = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($file in $sources) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($text, "Get-Setting(?:Int)?\s+'([A-Za-z][A-Za-z0-9_]*)'")) {
                $asked.Add($match.Groups[1].Value) | Out-Null
            }
        }

        $asked.Count | Should -BeGreaterThan 20 -Because 'the scan itself has to be finding names'
        $undeclared = @($asked | Where-Object { -not $script:DefaultSettings.Contains($_) } | Sort-Object)

        $undeclared | Should -BeNullOrEmpty -Because "these are read but never declared: $($undeclared -join ', ')"
    }
}

Describe 'Choosing the protected templates instead of typing them' {
    BeforeEach {
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Set-Setting {}
        Mock Get-TemplateStore {
            @{ Order = @('Urgent', 'logo', 'News-Ticker', 'Mojaz'); Map = @{} }
        }
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyTemplateKeys' -NotePropertyValue '' -Force
    }

    It 'opens the registry rather than a text prompt' {
        # The bug this prevents: a misspelled key reads as "not in the list",
        # so the permission silently protects nothing.
        Show-SettingChoices -Name 'AdminOnlyTemplateKeys' -ChatId 100 -UserId 101

        Get-PendingState -ChatId 100 | Should -BeNullOrEmpty
        # <setting>:<index>:<page> - the page rides along so a tick comes
        # back to the page it was on.
        Should -Invoke Send-TelegramMessage -ParameterFilter {
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) -contains 'cfgpick:AdminOnlyTemplateKeys:0:0'
        }
    }

    It 'ticks what is already protected and leaves the rest blank' {
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyTemplateKeys' -NotePropertyValue 'logo' -Force

        $labels = @((Get-SettingPickKeyboard -Name 'AdminOnlyTemplateKeys').inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['text'] })

        $labels | Should -Contain '✅ logo'
        $labels | Should -Contain '⬜ Urgent'
    }

    It 'adds a template on the first press and removes it on the second' {
        $script:written = @()
        Mock Set-Setting { $script:written += [string]$Value }

        Switch-SettingPick -Name 'AdminOnlyTemplateKeys' -Index 0 -ChatId 100 -UserId 101
        $script:written[-1] | Should -Be 'Urgent'

        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyTemplateKeys' -NotePropertyValue 'Urgent' -Force
        Switch-SettingPick -Name 'AdminOnlyTemplateKeys' -Index 0 -ChatId 100 -UserId 101
        $script:written[-1] | Should -Be ''
    }

    It 'ignores a position that is not in the registry' {
        Mock Set-Setting { throw 'must not write' }
        { Switch-SettingPick -Name 'AdminOnlyTemplateKeys' -Index 99 -ChatId 100 -UserId 101 } | Should -Not -Throw
    }

    It 'says plainly when nothing is protected' {
        Get-SettingPickText -Name 'AdminOnlyTemplateKeys' | Should -Match 'متاح للجميع'
    }
}

Describe 'Choosing the protected layers the same way' {
    BeforeEach {
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Set-Setting {}
        Mock Get-KnownLayers { @(5, 7, 8, 9) }
        Mock Get-LayerDisplayName { "طبقة $Layer" }
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyLayers' -NotePropertyValue '' -Force
    }

    It 'lists every layer the bridge knows, by name not by number alone' {
        # An administrator protects "the logo", not "9"; the number is what
        # gets stored, the name is what gets read.
        Mock Get-LayerDisplayName { if ($Layer -eq 9) { '9 · الشعار' } else { "طبقة $Layer" } }

        $labels = @((Get-SettingPickKeyboard -Name 'OwnerOnlyLayers').inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['text'] })

        $labels | Should -Contain '⬜ 9 · الشعار'
        @($labels | Where-Object { $_ -like '⬜*' }).Count | Should -Be 4
    }

    It 'stores the layer number, not the name it was shown under' {
        $script:written = @()
        Mock Set-Setting { $script:written += [string]$Value }

        # Index 3 is layer 9 in the sorted list.
        Switch-SettingPick -Name 'OwnerOnlyLayers' -Index 3 -ChatId 100 -UserId 101

        $script:written[-1] | Should -Be '9'
    }

    It 'protects that layer once it is picked' {
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyLayers' -NotePropertyValue '9' -Force
        foreach ($name in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers')) {
            $config.Settings | Add-Member -NotePropertyName $name -NotePropertyValue '' -Force
        }
        Mock Test-Admin { $true }
        Mock Test-Owner { $false }

        (Test-TemplateAccess -Key 'logo' -Layer 9 -ChatId 100 -UserId 101).Allowed | Should -BeFalse
        (Test-TemplateAccess -Key 'logo' -Layer 8 -ChatId 100 -UserId 101).Allowed | Should -BeTrue
    }
}

Describe 'Reading what is on air before taking it off' {
    BeforeEach {
        $config.Settings | Add-Member -NotePropertyName 'ShowOnAirTextOnRemoval' -NotePropertyValue $true -Force
        Mock Get-UserDisplayName { 'ابو حسام' }
        Mock Get-TemplateStore {
            @{ Order = @('Urgent'); Map = @{ 'Urgent' = @{ Key = 'Urgent'; Layer = 7; FieldSensitive = @('Ajel.secret') } } }
        }
        $script:OnAir = @{
            7 = @{ Key = 'Urgent'; At = (Get-Date).AddMinutes(-4); UserId = 101; ScreenCopy = 'Ajel.center: قصف على غزة' }
        }
    }
    AfterAll { $script:OnAir = @{} }

    It 'shows the strap on the confirmation, not only the layer number' {
        # A layer number cannot be checked against the screen under pressure;
        # the words on it can.
        $summary = Get-LayerRemovalSummary -Layer 7

        $summary | Should -Match 'قصف على غزة'
        $summary | Should -Match 'الطبقة 7'
    }

    It 'stays quiet about the text when the option is off' {
        $config.Settings | Add-Member -NotePropertyName 'ShowOnAirTextOnRemoval' -NotePropertyValue $false -Force

        Get-LayerRemovalSummary -Layer 7 | Should -Not -Match 'قصف على غزة'
    }

    It 'says the text is unrecorded rather than pretending the layer is empty' {
        $script:OnAir = @{ 7 = @{ Key = 'Urgent'; At = (Get-Date); UserId = 101 } }

        Get-LayerRemovalSummary -Layer 7 | Should -Match 'غير مسجّل'
    }

    It 'names a sensitive field without quoting it' {
        $copy = Format-OnAirScreenCopy -Key 'Urgent' -Variables @{
            'Ajel.center' = 'خبر عادي'
            'Ajel.secret' = 'رقم هاتف المصدر'
        }

        $copy | Should -Match 'خبر عادي'
        $copy | Should -Match 'Ajel.secret: •••'
        $copy | Should -Not -Match 'رقم هاتف المصدر'
    }

    It 'keeps the copy short enough for a confirmation screen' {
        $copy = Format-OnAirScreenCopy -Key 'Urgent' -Variables @{ 'Ajel.center' = ('ا' * 500) } -MaxChars 60

        $copy.Length | Should -BeLessOrEqual 62
        $copy | Should -Match '…$'
    }
}

Describe 'The template list shows only what the operator may use' {
    BeforeEach {
        foreach ($name in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers')) {
            $config.Settings | Add-Member -NotePropertyName $name -NotePropertyValue '' -Force
        }
        $config.Settings | Add-Member -NotePropertyName 'LayersScreenAccess' -NotePropertyValue 'all' -Force
        Mock Test-Admin { $false }
        Mock Test-Owner { $false }
        Mock Get-TemplateStore {
            @{
                Order = @('Urgent', 'logo', 'Mojaz')
                Map = @{
                    'Urgent' = @{ Key = 'Urgent'; Layer = 7; Description = ''; Category = ''; Presets = @(); Fields = @() }
                    'logo' = @{ Key = 'logo'; Layer = 9; Description = ''; Category = ''; Presets = @(); Fields = @() }
                    'Mojaz' = @{ Key = 'Mojaz'; Layer = 5; Description = ''; Category = ''; Presets = @(); Fields = @() }
                }
            }
        }
    }

    It 'leaves out a template the operator cannot put on air' {
        # Offered and then refused teaches people to press and see, which is
        # the opposite of a permission.
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyTemplateKeys' -NotePropertyValue 'logo' -Force

        $data = @((Get-TemplatesKeyboard -Prefix tpl -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { [string]$_['callback_data'] })

        @($data | Where-Object { $_ -like 'tpl:*' }).Count | Should -Be 2
    }

    It 'leaves out a template whose layer is protected' {
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyLayers' -NotePropertyValue '9' -Force

        $data = @((Get-TemplatesKeyboard -Prefix tpl -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { [string]$_['callback_data'] })

        @($data | Where-Object { $_ -like 'tpl:*' }).Count | Should -Be 2
    }

    It 'shows an administrator everything again' {
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyTemplateKeys' -NotePropertyValue 'logo' -Force
        Mock Test-Admin { $true }

        $data = @((Get-TemplatesKeyboard -Prefix tpl -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { [string]$_['callback_data'] })

        @($data | Where-Object { $_ -like 'tpl:*' }).Count | Should -Be 3
    }

    It 'filters nothing when asked without a user' {
        # The registry's own view of itself, for screens that are not a person
        # choosing what to put on air.
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyTemplateKeys' -NotePropertyValue 'logo' -Force

        $data = @((Get-TemplatesKeyboard -Prefix tpl).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { [string]$_['callback_data'] })

        @($data | Where-Object { $_ -like 'tpl:*' }).Count | Should -Be 3
    }
}

Describe 'Keeping the raw layer controls from ordinary operators' {
    BeforeEach {
        $config.Settings | Add-Member -NotePropertyName 'LayersScreenAccess' -NotePropertyValue 'all' -Force
        Mock Test-Admin { $false }
        Mock Test-Owner { $false }
    }

    It 'is open to everyone by default' {
        Test-LayersScreenAccess -ChatId 100 -UserId 101 | Should -BeTrue
    }

    It 'closes to an operator when set to administrators' {
        $config.Settings | Add-Member -NotePropertyName 'LayersScreenAccess' -NotePropertyValue 'admin' -Force
        Test-LayersScreenAccess -ChatId 100 -UserId 101 | Should -BeFalse

        Mock Test-Admin { $true }
        Test-LayersScreenAccess -ChatId 100 -UserId 101 | Should -BeTrue
    }

    It 'closes to an administrator when set to the owner' {
        $config.Settings | Add-Member -NotePropertyName 'LayersScreenAccess' -NotePropertyValue 'owner' -Force
        Mock Test-Admin { $true }
        Test-LayersScreenAccess -ChatId 100 -UserId 101 | Should -BeFalse

        Mock Test-Owner { $true }
        Test-LayersScreenAccess -ChatId 100 -UserId 101 | Should -BeTrue
    }

    It 'takes the button out of the menu when it is closed' {
        $config.Settings | Add-Member -NotePropertyName 'LayersScreenAccess' -NotePropertyValue 'admin' -Force

        $data = @((Get-MainMenuKeyboard -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { [string]$_['callback_data'] })

        $data | Should -Not -Contain 'menu:layers'
        # The templates button is not collateral damage.
        $data | Should -Contain 'menu:templates'
    }
}

Describe 'The requester names themselves' {
    BeforeEach {
        Mock Send-TelegramMessage {}
        Mock Send-AdminBroadcast {}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Save-UserAliases { $true }
        Mock Get-ApprovalKeyboard { @{ inline_keyboard = @() } }
        $config.Settings | Add-Member -NotePropertyName 'AskRequesterName' -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName 'EnableSelfServiceRequests' -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName 'MaxPendingApprovals' -NotePropertyValue 10 -Force
        $script:UserAliases.Clear()
        Clear-PendingState -ChatId 555
        # The queue is read back through the screen that shows it rather than
        # through the table itself: the bridge's own copy of that table is not
        # the one this file's scope holds, and asserting on the wrong one
        # passes or fails for reasons that have nothing to do with the code.
        Deny-UserAccess -TargetChatId 555 -RejectedBy 101 -RejecterUserId 101 -ErrorAction SilentlyContinue | Out-Null
        # And a rejection now blocks the chat, which is the point of it - so
        # the guard is wiped after the dequeue, never before.
        $script:AccessGuard = @{ Blocked = @{}; Attempts = @{} }
    }
    AfterAll { $script:UserAliases.Clear() }

    It 'asks for a name only after the request is already with the admins' {
        # A requester who never answers must still have a request waiting.
        Request-Approval -ChatId 555 -UserId 555 -From ([pscustomobject]@{ first_name = 'Ahmed'; username = 'ahmed' }) | Should -BeTrue

        Get-PendingApprovalsText | Should -Match '555'
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
        [string](Get-PendingState -ChatId 555).Mode | Should -Be 'access_request_name'
    }

    It 'replaces the Telegram handle with what the person sent' {
        Request-Approval -ChatId 555 -UserId 555 -From ([pscustomobject]@{ first_name = 'Ahmed'; username = 'ahmed' }) | Out-Null

        Complete-AccessRequestName -ChatId 555 -Value '  أحمد - قسم الأخبار  ' | Should -BeTrue

        Get-PendingApprovalsText | Should -Match 'أحمد - قسم الأخبار'
        Get-PendingState -ChatId 555 | Should -BeNullOrEmpty
    }

    It 'refuses to answer a chat that is not waiting in the queue' {
        # This is the one flow an unauthorized chat can reach, so it verifies
        # for itself rather than trusting the pending state alone.
        Set-PendingState -ChatId 556 -State @{ Mode = 'access_request_name'; UserId = 556 }

        Complete-AccessRequestName -ChatId 556 -Value 'أي اسم' | Should -BeFalse

        Get-PendingState -ChatId 556 | Should -BeNullOrEmpty
        $script:UserAliases.Count | Should -Be 0
    }

    It 'caps the name and flattens what would break a roster line' {
        Request-Approval -ChatId 555 -UserId 555 -From ([pscustomobject]@{ first_name = 'Ahmed' }) | Out-Null

        Complete-AccessRequestName -ChatId 555 -Value ("أ`nب`tج" + ('د' * 200)) | Out-Null

        $text = Get-PendingApprovalsText
        $text | Should -Match 'أ ب ج'
        # 200 identical letters would have run off the screen.
        $text | Should -Not -Match ('د' * 70)
    }

    It 'keeps the prompt open on an empty name' {
        Request-Approval -ChatId 555 -UserId 555 -From ([pscustomobject]@{ first_name = 'Ahmed' }) | Out-Null

        Complete-AccessRequestName -ChatId 555 -Value '   ' | Should -BeFalse

        [string](Get-PendingState -ChatId 555).Mode | Should -Be 'access_request_name'
    }

    It 'adopts that name as the alias when access is granted' {
        Mock Test-Authorized { $false }
        Mock Save-Config { $true }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
        Mock Get-ConfigSaveWarning { '' }
        Request-Approval -ChatId 555 -UserId 555 -From ([pscustomobject]@{ first_name = 'Ahmed' }) | Out-Null
        Complete-AccessRequestName -ChatId 555 -Value 'أحمد - قسم الأخبار' | Out-Null

        Grant-UserAccess -TargetChatId 555 -ApprovedBy 101 -ApproverUserId 101

        Get-UserDisplayName -UserId 555 | Should -Be 'أحمد - قسم الأخبار'
    }

    It 'leaves an alias somebody already chose alone' {
        Mock Test-Authorized { $false }
        Mock Save-Config { $true }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
        Mock Get-ConfigSaveWarning { '' }
        $script:UserAliases['555'] = 'اسم اختاره المشرف'
        Request-Approval -ChatId 555 -UserId 555 -From ([pscustomobject]@{ first_name = 'Ahmed' }) | Out-Null
        Complete-AccessRequestName -ChatId 555 -Value 'أحمد' | Out-Null

        Grant-UserAccess -TargetChatId 555 -ApprovedBy 101 -ApproverUserId 101

        Get-UserDisplayName -UserId 555 | Should -Be 'اسم اختاره المشرف'
    }

    It 'does not ask when the option is off' {
        $config.Settings | Add-Member -NotePropertyName 'AskRequesterName' -NotePropertyValue $false -Force

        Request-Approval -ChatId 555 -UserId 555 -From ([pscustomobject]@{ first_name = 'Ahmed' }) | Should -BeTrue

        Get-PendingState -ChatId 555 | Should -BeNullOrEmpty
        Get-PendingApprovalsText | Should -Match '555'
    }
}


Describe 'The access guard' {
    BeforeEach {
        # Through the functions, never by poking the table: that is the only
        # way a test proves what the running bridge would do.
        $script:AccessGuard = @{ Blocked = @{}; Attempts = @{} }
        foreach ($pair in @(@('BlockRejectedRequesters', $true), @('JoinSecret', ''), @('JoinSecretMaxAttempts', 3),
                @('MaxAccessRequestsPerDay', 3), @('DormantUserDays', 60), @('AutoDisableDormantUsers', $false),
                @('LeaveUnknownGroups', $true), @('EnableSelfServiceRequests', $true), @('MaxPendingApprovals', 20))) {
            $config.Settings | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
        Mock Send-TelegramMessage { $true }
        Mock Send-AdminBroadcast { $true }
        Mock Write-BridgeLog { }
    }

    It 'lets a chat ask up to the daily limit and no further' {
        1..3 | ForEach-Object { Test-AccessRequestAllowed -ChatId 500 | Should -BeTrue }
        Test-AccessRequestAllowed -ChatId 500 | Should -BeFalse
        # Another chat is unaffected: the limit is per chat, not global.
        Test-AccessRequestAllowed -ChatId 501 | Should -BeTrue
    }

    It 'restarts the window a day later rather than refusing for ever' {
        $start = Get-Date
        1..4 | ForEach-Object { Test-AccessRequestAllowed -ChatId 502 -Now $start | Out-Null }
        Test-AccessRequestAllowed -ChatId 502 -Now $start | Should -BeFalse
        Test-AccessRequestAllowed -ChatId 502 -Now $start.AddHours(25) | Should -BeTrue
    }

    It 'treats a zero limit as no limit' {
        $config.Settings | Add-Member -NotePropertyName 'MaxAccessRequestsPerDay' -NotePropertyValue 0 -Force
        1..10 | ForEach-Object { Test-AccessRequestAllowed -ChatId 503 | Should -BeTrue }
    }

    It 'refuses a blocked chat whatever the limit says' {
        Block-AccessChat -ChatId 504 -Reason 'rejected' -ByUserId 9 | Out-Null
        Test-ChatBlocked -ChatId 504 | Should -BeTrue
        Test-AccessRequestAllowed -ChatId 504 | Should -BeFalse
        Request-Approval -ChatId 504 -UserId 504 -From $null | Should -BeFalse
    }

    It 'unblocks and clears the day the chat had spent' {
        1..4 | ForEach-Object { Test-AccessRequestAllowed -ChatId 505 | Out-Null }
        Block-AccessChat -ChatId 505 -Reason 'rejected' | Out-Null

        Unblock-AccessChat -ChatId 505 -ByUserId 9 | Should -BeTrue
        Test-ChatBlocked -ChatId 505 | Should -BeFalse
        # The counter went with the block, so they can actually ask again.
        Test-AccessRequestAllowed -ChatId 505 | Should -BeTrue
        Unblock-AccessChat -ChatId 505 | Should -BeFalse
    }

    It 'survives a restart' {
        Block-AccessChat -ChatId 506 -Reason 'join_secret' -ByUserId 7 | Out-Null
        $script:AccessGuard = @{ Blocked = @{}; Attempts = @{} }
        Import-AccessGuard

        Test-ChatBlocked -ChatId 506 | Should -BeTrue
        $record = @(Get-BlockedAccessChats | Where-Object { $_.ChatId -eq 506 })
        $record.Count | Should -Be 1
        $record[0].Reason | Should -Be 'join_secret'
        $record[0].By | Should -Be 7
    }
}

Describe 'The join code' {
    BeforeEach {
        foreach ($pair in @(@('JoinSecret', 'cinegy-2026'), @('JoinSecretMaxAttempts', 3), @('MaxAccessRequestsPerDay', 3),
                @('EnableSelfServiceRequests', $true), @('MaxPendingApprovals', 20), @('AskRequesterName', $false),
                # Off here so the dequeue below only dequeues.
                @('BlockRejectedRequesters', $false))) {
            $config.Settings | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
        Mock Send-TelegramMessage { $true }
        Mock Send-AdminBroadcast { $true }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
        # Emptied through the bridge's own path: this file's scope does not
        # hold the same queue object the bridge functions write to, so
        # removing a key here would leave the real one untouched.
        Deny-UserAccess -TargetChatId 600 -RejectedBy 1 -RejecterUserId 1 -ErrorAction SilentlyContinue | Out-Null
        $script:AccessGuard = @{ Blocked = @{}; Attempts = @{} }
        Clear-PendingState -ChatId 600
    }

    AfterEach {
        $config.Settings | Add-Member -NotePropertyName 'JoinSecret' -NotePropertyValue '' -Force
        Clear-PendingState -ChatId 600
    }

    It 'matches nothing at all when no code is set' {
        $config.Settings | Add-Member -NotePropertyName 'JoinSecret' -NotePropertyValue '' -Force
        Test-JoinSecret -Provided '' | Should -BeFalse
        Test-JoinSecret -Provided 'anything' | Should -BeFalse
    }

    It 'asks for the code instead of queueing the request' {
        Request-Approval -ChatId 600 -UserId 600 -From $null | Should -BeFalse
        (Get-PendingState -ChatId 600).Mode | Should -Be 'join_secret'
        # Nothing about a pending request reached the administrators.
        Get-PendingApprovalsText | Should -Not -Match '600'
    }

    It 'says nothing more once the prompt has gone out' {
        Request-Approval -ChatId 600 -UserId 600 -From $null | Out-Null
        Get-UnauthorizedReplyText -ChatId 600 -Queued $false | Should -BeNullOrEmpty
        Get-UnauthorizedReplyText -ChatId 601 -Queued $false | Should -Match 'تواصل مع المشرف'
        Get-UnauthorizedReplyText -ChatId 601 -Queued $true | Should -Match 'فور الموافقة'
    }

    It 'queues the request when the code is right, and asks only once' {
        Request-Approval -ChatId 600 -UserId 600 -From $null | Out-Null
        Complete-JoinSecret -ChatId 600 -UserId 600 -Value ' cinegy-2026 ' -From $null | Should -BeTrue

        Get-PendingApprovalsText | Should -Match '600'
        Test-AccessSecretPassed -ChatId 600 | Should -BeTrue
        # Asked once: a second request does not send them back to the prompt.
        Deny-UserAccess -TargetChatId 600 -RejectedBy 1 -RejecterUserId 1
        Request-Approval -ChatId 600 -UserId 600 -From $null | Should -BeTrue
        Get-PendingState -ChatId 600 | Should -BeNullOrEmpty
    }

    It 'blocks the chat after enough wrong codes, and says nothing' {
        Request-Approval -ChatId 600 -UserId 600 -From $null | Out-Null
        1..2 | ForEach-Object { Complete-JoinSecret -ChatId 600 -UserId 600 -Value 'wrong' -From $null | Should -BeFalse }
        Test-ChatBlocked -ChatId 600 | Should -BeFalse

        Complete-JoinSecret -ChatId 600 -UserId 600 -Value 'wrong' -From $null | Should -BeFalse
        Test-ChatBlocked -ChatId 600 | Should -BeTrue
        Get-PendingState -ChatId 600 | Should -BeNullOrEmpty
        # The third refusal is silent - only the first two were answered.
        Should -Invoke Send-TelegramMessage -Times 2 -Exactly -ParameterFilter { $Text -like '*الرمز غير صحيح*' }
    }

    It 'does nothing when the chat is not at that prompt' {
        Complete-JoinSecret -ChatId 600 -UserId 600 -Value 'cinegy-2026' -From $null | Should -BeFalse
        Get-PendingApprovalsText | Should -Not -Match '600'
    }
}

Describe 'Rejecting a request' {
    BeforeEach {
        $script:AccessGuard = @{ Blocked = @{}; Attempts = @{} }
        foreach ($pair in @(@('BlockRejectedRequesters', $true), @('JoinSecret', ''), @('EnableSelfServiceRequests', $true),
                @('MaxPendingApprovals', 20), @('MaxAccessRequestsPerDay', 3), @('AskRequesterName', $false))) {
            $config.Settings | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force
        }
        Mock Send-TelegramMessage { $true }
        Mock Send-AdminBroadcast { $true }
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
    }

    It 'blocks the chat so it cannot simply ask again' {
        Request-Approval -ChatId 700 -UserId 700 -From $null | Out-Null
        Deny-UserAccess -TargetChatId 700 -RejectedBy 1 -RejecterUserId 1

        Test-ChatBlocked -ChatId 700 | Should -BeTrue
        Request-Approval -ChatId 700 -UserId 700 -From $null | Should -BeFalse
        Get-PendingApprovalsText | Should -Not -Match '700'
    }

    It 'leaves the chat free to ask again when the setting is off' {
        $config.Settings | Add-Member -NotePropertyName 'BlockRejectedRequesters' -NotePropertyValue $false -Force
        Request-Approval -ChatId 701 -UserId 701 -From $null | Out-Null
        Deny-UserAccess -TargetChatId 701 -RejectedBy 1 -RejecterUserId 1

        Test-ChatBlocked -ChatId 701 | Should -BeFalse
        Request-Approval -ChatId 701 -UserId 701 -From $null | Should -BeTrue
    }
}

Describe 'Dormant users' {
    BeforeEach {
        $config.Settings | Add-Member -NotePropertyName 'DormantUserDays' -NotePropertyValue 60 -Force
        $config.Settings | Add-Member -NotePropertyName 'AutoDisableDormantUsers' -NotePropertyValue $false -Force
        Mock Send-AdminBroadcast { $true }
        Mock Write-BridgeLog { }
    }

    It 'measures silence from the last interaction, then from the day access was granted' {
        $now = Get-Date
        $user = [pscustomobject]@{ LastActivityAt = $now.AddDays(-10).ToString('o'); AddedAt = $now.AddDays(-400).ToString('o') }
        Get-UserIdleDays -User $user -Now $now | Should -Be 10

        $never = [pscustomobject]@{ LastActivityAt = ''; AddedAt = $now.AddDays(-90).ToString('o') }
        Get-UserIdleDays -User $never -Now $now | Should -Be 90
    }

    It 'counts nobody when there is no date at all' {
        # No record is not evidence of absence.
        Get-UserIdleDays -User ([pscustomobject]@{ LastActivityAt = ''; AddedAt = '' }) | Should -Be -1
        Get-UserIdleDays -User ([pscustomobject]@{ LastActivityAt = 'not a date'; AddedAt = '' }) | Should -Be -1
    }

    It 'never lists the owner, the disabled, or the recently active' {
        $now = Get-Date
        $old = $now.AddDays(-200).ToString('o')
        Mock Get-AuthorizedUsers {
            @(
                [pscustomobject]@{ UserId = 1; Alias = 'owner'; Role = 'owner'; Disabled = $false; AddedAt = $old; LastActivityAt = $old }
                [pscustomobject]@{ UserId = 2; Alias = 'off'; Role = 'operator'; Disabled = $true; AddedAt = $old; LastActivityAt = $old }
                [pscustomobject]@{ UserId = 3; Alias = 'quiet'; Role = 'operator'; Disabled = $false; AddedAt = $old; LastActivityAt = $old }
                [pscustomobject]@{ UserId = 4; Alias = 'busy'; Role = 'operator'; Disabled = $false; AddedAt = $old; LastActivityAt = $now.ToString('o') }
            )
        }
        @(Get-DormantUsers -Now $now).UserId | Should -Be @(3)
    }

    It 'reports without disabling, and disables when told to' {
        $old = (Get-Date).AddDays(-200).ToString('o')
        Mock Get-AuthorizedUsers { @([pscustomobject]@{ UserId = 3; Alias = 'quiet'; Role = 'operator'; Disabled = $false; AddedAt = $old; LastActivityAt = $old }) }
        Mock Set-UserDisabled { $true }

        $script:LastDormantSweep = $null
        @(Update-DormantUsers).Count | Should -Be 1
        Should -Invoke Set-UserDisabled -Times 0 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly

        $config.Settings | Add-Member -NotePropertyName 'AutoDisableDormantUsers' -NotePropertyValue $true -Force
        $script:LastDormantSweep = $null
        Update-DormantUsers | Out-Null
        Should -Invoke Set-UserDisabled -Times 1 -Exactly -ParameterFilter { $TargetUserId -eq 3 -and $Disabled }
    }

    It 'sweeps once a day, not on every tick' {
        $old = (Get-Date).AddDays(-200).ToString('o')
        Mock Get-AuthorizedUsers { @([pscustomobject]@{ UserId = 3; Alias = 'quiet'; Role = 'operator'; Disabled = $false; AddedAt = $old; LastActivityAt = $old }) }

        $script:LastDormantSweep = $null
        Update-DormantUsers | Out-Null
        1..5 | ForEach-Object { Update-DormantUsers | Out-Null }
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
    }

    It 'does nothing at all when the setting is zero' {
        $config.Settings | Add-Member -NotePropertyName 'DormantUserDays' -NotePropertyValue 0 -Force
        $script:LastDormantSweep = $null
        @(Update-DormantUsers).Count | Should -Be 0
        @(Get-DormantUsers).Count | Should -Be 0
    }
}

Describe 'Unknown group chats' {
    BeforeEach {
        $config.Settings | Add-Member -NotePropertyName 'LeaveUnknownGroups' -NotePropertyValue $true -Force
        $script:LeftGroupChats = @{}
        Mock Invoke-BridgeTelegramRequest { [pscustomobject]@{ Success = $true; Response = $null; Error = ''; Attempts = 1 } }
        Mock Send-AdminBroadcast { $true }
        Mock Write-BridgeLog { }
    }

    It 'leaves a group once and tells the administrators' {
        $chat = [pscustomobject]@{ id = -1001; type = 'supergroup'; title = 'Random group' }
        Exit-UnknownGroupChat -Chat $chat | Should -BeTrue
        # A second message from the same group does not announce it again.
        Exit-UnknownGroupChat -Chat $chat | Should -BeFalse
        Should -Invoke Invoke-BridgeTelegramRequest -Times 1 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
    }

    It 'stays in a group somebody deliberately whitelisted' {
        $config | Add-Member -NotePropertyName 'AllowedChatIds' -NotePropertyValue @(-1002) -Force
        Exit-UnknownGroupChat -Chat ([pscustomobject]@{ id = -1002; type = 'group'; title = 'Newsroom' }) | Should -BeFalse
        Should -Invoke Invoke-BridgeTelegramRequest -Times 0 -Exactly
    }

    It 'never leaves a private chat, and does nothing when the setting is off' {
        Exit-UnknownGroupChat -Chat ([pscustomobject]@{ id = 12345; type = 'private'; title = '' }) | Should -BeFalse

        $config.Settings | Add-Member -NotePropertyName 'LeaveUnknownGroups' -NotePropertyValue $false -Force
        Exit-UnknownGroupChat -Chat ([pscustomobject]@{ id = -1003; type = 'supergroup'; title = 'Another' }) | Should -BeFalse
        Should -Invoke Invoke-BridgeTelegramRequest -Times 0 -Exactly
    }

    It 'stays put when Telegram refuses to let it out' {
        Mock Invoke-BridgeTelegramRequest { [pscustomobject]@{ Success = $false; Response = $null; Error = 'boom'; Attempts = 1 } }
        Exit-UnknownGroupChat -Chat ([pscustomobject]@{ id = -1004; type = 'group'; title = 'Broken' }) | Should -BeFalse
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }
}

Describe 'A permission list longer than one message' {
    BeforeEach {
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyTemplateKeys' -NotePropertyValue '' -Force
        Mock Send-TelegramMessage { $true }
        # A hundred templates drew a hundred rows into one message, which
        # Telegram will not send: the screen stopped opening on exactly the
        # installations big enough to need it.
        Mock Get-SettingPickItems { @(0..99 | ForEach-Object { @{ Value = "T$_"; Label = "T$_" } }) }
    }

    It 'pages instead of drawing every template at once' {
        $rows = @((Get-SettingPickKeyboard -Name 'AdminOnlyTemplateKeys').inline_keyboard)
        # Twenty items, two to a row, plus the pager and the done button.
        $rows.Count | Should -BeLessOrEqual 12
        @($rows | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) |
            Should -Contain 'cfgpickpage:AdminOnlyTemplateKeys:1'
    }

    It 'addresses items by their absolute position, not their position on the page' {
        $callbacks = @((Get-SettingPickKeyboard -Name 'AdminOnlyTemplateKeys' -Page 2).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })
        $callbacks | Should -Contain 'cfgpick:AdminOnlyTemplateKeys:40:2'
        $callbacks | Should -Not -Contain 'cfgpick:AdminOnlyTemplateKeys:0:2'
    }

    It 'says which page it is on' {
        Get-SettingPickText -Name 'AdminOnlyTemplateKeys' -Page 1 | Should -Match 'صفحة 2 من 5'
    }
}

Describe 'An administrator who can approve is an administrator who is told' {
    BeforeEach {
        # The shape this installation was actually in: three administrators
        # by authority, two by notification.
        $config | Add-Member -NotePropertyName 'AdminChatIds' -NotePropertyValue @(11, 22) -Force
        $config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @(11, 22, 33) -Force
    }

    It 'broadcasts to every administrator, not only those in the chat list' {
        # 33 could approve a stranger into the on-air controls and was never
        # told one had asked.
        $sent = [System.Collections.Generic.List[long]]::new()
        Mock Send-TelegramMessage { $sent.Add([long]$ChatId) }
        Mock Test-QuietHoursActive { $false }

        Send-AdminBroadcast -Text 'اختبار'

        @($sent) | Should -Contain 33
        @($sent).Count | Should -Be 3
    }

    It 'names the administrator who hears nothing, in both directions' {
        $mismatch = Get-AdminListMismatch
        @($mismatch.Unnotified) | Should -Be @(33)
        @($mismatch.Unauthorized) | Should -BeNullOrEmpty

        # And the health screen carries it, because nobody can notice a
        # message that never arrives.
        $warnings = @(Get-DiagnosticWarnings -Snapshot @{ DiskFreeGB = 40; RuntimeStorageBytes = 0; BackupStorageBytes = 0 })
        @($warnings | Where-Object { $_ -match '33' }) | Should -HaveCount 1
    }

    It 'stays silent when the two lists agree' {
        $config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @(11, 22) -Force
        $warnings = @(Get-DiagnosticWarnings -Snapshot @{ DiskFreeGB = 40; RuntimeStorageBytes = 0; BackupStorageBytes = 0 })
        @($warnings | Where-Object { $_ -match 'مشرفون بلا إشعارات' }) | Should -BeNullOrEmpty
    }
}

Describe 'A promotion puts an administrator in both lists' {
    BeforeEach {
        $config | Add-Member -NotePropertyName 'AdminChatIds' -NotePropertyValue @(11) -Force
        $config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @(11) -Force
        $config | Add-Member -NotePropertyName 'AllowedChatIds' -NotePropertyValue @(11, 44) -Force
        $config | Add-Member -NotePropertyName 'AllowedUserIds' -NotePropertyValue @(11, 44) -Force
        Mock Save-Config { }
    }

    It 'adds the promoted user to the notices as well as to the roster' {
        # The roster alone made an administrator who could approve a stranger
        # into the on-air controls and was never sent a single request.
        (Set-AdminRole -TargetUserId 44 -IsAdmin $true).Success | Should -BeTrue

        @($config.AdminUserIds) | Should -Contain 44
        @($config.AdminChatIds) | Should -Contain 44
    }

    It 'still refuses to make a group chat an audience' {
        # A group id is negative, and the original caution stands.
        $config | Add-Member -NotePropertyName 'AllowedUserIds' -NotePropertyValue @(11, -100123) -Force
        [void](Set-AdminRole -TargetUserId -100123 -IsAdmin $true)
        @($config.AdminChatIds) | Should -Not -Contain -100123
    }

    It 'takes a demoted administrator out of both' {
        [void](Set-AdminRole -TargetUserId 44 -IsAdmin $true)
        (Set-AdminRole -TargetUserId 44 -IsAdmin $false).Success | Should -BeTrue

        @($config.AdminUserIds) | Should -Not -Contain 44
        @($config.AdminChatIds) | Should -Not -Contain 44
    }

    It 'repairs an installation that was already promoted without notices' {
        # What this installation looked like: authority for three, notices for
        # two, and the third with no way to discover it.
        $config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @(11, 22, 33) -Force
        $config | Add-Member -NotePropertyName 'AdminChatIds' -NotePropertyValue @(11, 22) -Force

        $added = @(Repair-AdminChatIds)

        @($added) | Should -Be @(33)
        @($config.AdminChatIds) | Should -Contain 33
        # Idempotent: a second start changes nothing and says nothing.
        @(Repair-AdminChatIds) | Should -BeNullOrEmpty
    }
}

Describe 'Granting on-air control takes two taps' {
    It 'asks before it grants' {
        # A stray tap on a message sitting in a chat granted access with
        # nothing left behind to remind the administrator he had done it.
        $first = @(Get-ApprovalKeyboard -TargetChatId 4321).inline_keyboard | ForEach-Object { $_ } |
            Where-Object { [string]$_.text -match 'موافقة' }

        @($first)[0].callback_data | Should -Be 'approve:confirm:4321'
        # And the second button names the act rather than saying "yes".
        $second = @(Get-AccessGrantConfirmKeyboard -TargetChatId 4321).inline_keyboard | ForEach-Object { $_ }
        @($second)[0].callback_data | Should -Be 'approve:4321'
        @($second)[0].text | Should -Match 'امنح الوصول'
    }

    It 'routes the asking tap to a question, not to a grant' {
        Mock Test-CallbackAdmin { $true }
        # 11 is an administrator in this fixture but not in the example
        # config's allow list, and the router refuses before any branch runs.
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { $script:AskedText = $Text }
        Mock Grant-UserAccess { $script:Granted = $true }
        Mock Confirm-TelegramCallback { }
        $script:Granted = $false
        # [long], as Request-Approval stores it: a hashtable keyed by Int32
        # is not found by an Int64 lookup, so an int literal here would test
        # a shape production never has.
        $script:PendingApprovals[[long]4321] = @{ Name = 'معاذ - الأخبار'; ChatId = 4321; UserId = 4321; RequestedAt = (Get-Date) }

        Invoke-CallbackQuery -CallbackQuery ([pscustomobject]@{
                id = '1'; data = 'approve:confirm:4321'
                message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 11; type = 'private' } }
                from = [pscustomobject]@{ id = 11; first_name = 'x' }
            })

        $script:Granted | Should -BeFalse
        $script:AskedText | Should -Match 'منح الوصول'
        $script:AskedText | Should -Match 'معاذ'
        $script:PendingApprovals.Remove([long]4321)
    }
}

Describe 'A flow says it is about to end' {
    BeforeEach {
        $script:PendingState.Clear()
        # A default as well as the filtered one: a filtered mock alone makes
        # Pester throw on every other setting this path reads.
        Mock Get-SettingInt { 10 }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }
        Mock Update-DormantUsers { }
    }

    It 'warns a minute before, with a way to take more time' {
        # An editor writing a headline was cut off mid-sentence and told the
        # time had run out - the first he knew of any clock.
        $script:PendingState[555] = @{ Mode = 'news_add_text'; UserId = 555; StartedAt = (Get-Date).AddMinutes(-9.2) }
        $script:Warned = ''
        $script:WarnMarkup = $null
        Mock Send-TelegramMessage { $script:Warned = $Text; $script:WarnMarkup = $ReplyMarkup }

        Update-PendingExpiry

        $script:Warned | Should -Match 'ستُلغى العملية بعد دقيقة'
        @($script:WarnMarkup.inline_keyboard)[0][0].callback_data | Should -Be 'flow:extend'
        # Still there: warning is not expiring.
        $script:PendingState.ContainsKey(555) | Should -BeTrue
    }

    It 'warns once, not on every tick' {
        $script:PendingState[556] = @{ Mode = 'news_add_text'; UserId = 556; StartedAt = (Get-Date).AddMinutes(-9.2) }
        Mock Send-TelegramMessage { }

        Update-PendingExpiry
        Update-PendingExpiry

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
    }

    It 'still expires a flow that really was abandoned' {
        $script:PendingState[557] = @{ Mode = 'news_add_text'; UserId = 557; StartedAt = (Get-Date).AddMinutes(-30) }
        Mock Send-TelegramMessage { }
        Mock Write-BridgeLog { }

        Update-PendingExpiry

        $script:PendingState.ContainsKey(557) | Should -BeFalse
    }

    It 'restarts the clock when the extend button is pressed' {
        $script:PendingState[558] = @{ Mode = 'news_add_text'; UserId = 558; StartedAt = (Get-Date).AddMinutes(-9.5); WarnedAt = (Get-Date) }
        Mock Confirm-TelegramCallback { $script:Answer = $Text }
        Mock Test-Authorized { $true }

        Invoke-CallbackQuery -CallbackQuery ([pscustomobject]@{
                id = '2'; data = 'flow:extend'
                message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 558; type = 'private' } }
                from = [pscustomobject]@{ id = 558; first_name = 'x' }
            })

        ((Get-Date) - $script:PendingState[558].StartedAt).TotalMinutes | Should -BeLessThan 1
        $script:PendingState[558].ContainsKey('WarnedAt') | Should -BeFalse
        $script:Answer | Should -Match 'مُدِّدت'
    }
}

Describe 'The typed command passes the same door as the button' {
    <#
        The four button branches in Parts/Bridge.Callbacks.ps1 have always
        asked Test-TemplateAccess. Invoke-HideLayer and Invoke-ExitLayer never
        did - so `/اخفاء 9` typed by an operator whose BUTTON had just refused
        layer 9 reached Cinegy anyway, and the audit recorded that HIDE as a
        success rather than a refusal. SHOW had asked at its own door since it
        was written; hide and exit had the guard written four times downstream
        and zero times at the door they share.

        These drive the typed path, which is the shape that was broken. They
        assert on Hide-TitlerTemplate / Exit-TitlerScene - the real Cinegy
        boundary - because "was it refused politely" is not the question. The
        question is whether anything reached air.
    #>
    BeforeEach {
        foreach ($name in @('AdminOnlyTemplateKeys', 'OwnerOnlyTemplateKeys', 'AdminOnlyLayers', 'OwnerOnlyLayers')) {
            $config.Settings | Add-Member -NotePropertyName $name -NotePropertyValue '' -Force
        }
        Mock Test-Admin { $false }
        Mock Test-Owner { $false }
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false; ActiveId = ''; Error = '' } }
        Mock Sync-LayerAfterOperatorAction { }
        Mock Remove-OnAirRecord { }
        Mock Send-TemplateAirNotice { }
    }

    It 'sends no HIDE to Cinegy when a typed /اخفاء names an owner-only layer' {
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyLayers' -NotePropertyValue '9' -Force

        Invoke-HideCommand -ArgText '9' -ChatId 100 -UserId 101

        Should -Invoke Hide-TitlerTemplate -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'مالك الجسر' }
    }

    It 'sends no EXIT to Cinegy when a typed /خروج names an owner-only layer' {
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyLayers' -NotePropertyValue '9' -Force

        Invoke-ExitCommand -ArgText '9' -ChatId 100 -UserId 101 | Out-Null

        Should -Invoke Exit-TitlerScene -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'مالك الجسر' }
    }

    It 'refuses an admin-only layer to an operator and admits the administrator' {
        $config.Settings | Add-Member -NotePropertyName 'AdminOnlyLayers' -NotePropertyValue '9' -Force

        Invoke-HideCommand -ArgText '9' -ChatId 100 -UserId 101
        Should -Invoke Hide-TitlerTemplate -Times 0 -Exactly

        Mock Test-Admin { $true }
        Invoke-HideCommand -ArgText '9' -ChatId 100 -UserId 101
        Should -Invoke Hide-TitlerTemplate -Times 1 -Exactly
    }

    It 'leaves an unprotected layer alone, so the guard costs the ordinary hide nothing' {
        Invoke-HideCommand -ArgText '8' -ChatId 100 -UserId 101

        Should -Invoke Hide-TitlerTemplate -Times 1 -Exactly
    }

    It 'never refuses the auto-hide timer, which is not a person asking' {
        # -System. A timer armed by an operator who may not hide that layer by
        # hand must still fire, or the guard strands a graphic on air - a hide
        # that fails closed is worse than the hole it was written to close.
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyLayers' -NotePropertyValue '9' -Force

        Invoke-HideLayer -Layer 9 -ChatId 100 -UserId 101 -Quiet -System | Should -BeTrue

        Should -Invoke Hide-TitlerTemplate -Times 1 -Exactly
    }

    It 'never refuses engine teardown, which is not a person asking either' {
        $config.Settings | Add-Member -NotePropertyName 'OwnerOnlyLayers' -NotePropertyValue '9' -Force

        Invoke-ExitLayer -Layer 9 -ChatId 100 -UserId 101 -System | Should -BeTrue

        Should -Invoke Exit-TitlerScene -Times 1 -Exactly
    }
}
