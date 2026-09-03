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
