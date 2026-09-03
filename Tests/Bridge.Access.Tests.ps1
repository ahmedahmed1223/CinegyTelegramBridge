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
        Should -Invoke Send-TelegramMessage -ParameterFilter {
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) -contains 'cfgpick:AdminOnlyTemplateKeys:0'
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
