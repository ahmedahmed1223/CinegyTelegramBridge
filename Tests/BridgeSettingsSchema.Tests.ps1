#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeSettingsSchema.psm1') -Force
}

Describe 'Unified bridge setting schema' {
    BeforeAll {
        $script:Schema = @(New-BridgeSettingSchema `
                -Defaults ([ordered]@{
                    RequireUserLevelAuth = $true
                    AirVariableType = 'Text'
                    MaxFieldLength = 200
                    FutureSetting = 7
                }) `
                -DisplayMetadata @{
                    RequireUserLevelAuth = @{ Unit = ''; Description = 'التحقق من المستخدم' }
                    MaxFieldLength = @{ Unit = 'حرفًا'; Description = 'طول النص' }
                } `
                -CategoryByName @{ RequireUserLevelAuth = 'security'; AirVariableType = 'advanced'; MaxFieldLength = 'onair' } `
                -Labels @{ RequireUserLevelAuth = 'التحقق من هوية المستخدم' } `
                -ProtectedNames @('RequireUserLevelAuth') `
                -Choices @{ AirVariableType = @('Text', 'String') } `
                -Constraints @{ MaxFieldLength = @{ Minimum = 1; Maximum = 1000 } } `
                -AdvancedNames @('FutureSetting'))
    }

    It 'describes a protected boolean through one complete record' {
        $record = @($script:Schema | Where-Object Name -eq 'RequireUserLevelAuth')[0]

        $record.Default | Should -BeTrue
        $record.ValueType | Should -Be 'Boolean'
        $record.Category | Should -Be 'security'
        $record.Label | Should -Be 'التحقق من هوية المستخدم'
        $record.Protected | Should -BeTrue
    }

    It 'retains constrained choices and numeric display units' {
        @(@($script:Schema | Where-Object Name -eq 'AirVariableType')[0].Choices) | Should -Be @('Text', 'String')
        @($script:Schema | Where-Object Name -eq 'MaxFieldLength')[0].Unit | Should -Be 'حرفًا'
    }

    It 'keeps an unknown future setting reachable through Advanced' {
        $record = @($script:Schema | Where-Object Name -eq 'FutureSetting')[0]

        $record.Category | Should -Be 'advanced'
        $record.Label | Should -Be 'FutureSetting'
        $record.ValueType | Should -Be 'Int32'
    }

    It 'finds Arabic labels and returns only modified values' {
        (Find-BridgeSettings -Schema $script:Schema -Query 'هوية').Name | Should -Be 'RequireUserLevelAuth'
        (Get-ModifiedBridgeSettings -Schema $script:Schema -Values @{ MaxFieldLength = 250 }).Name | Should -Be 'MaxFieldLength'
    }

    It 'validates ranges, supports simple mode, and resets one value only' {
        (Test-BridgeSettingValue -Schema $script:Schema -Name 'MaxFieldLength' -Value 1001).Valid | Should -BeFalse
        @(Get-BridgeSettingsForMode -Schema $script:Schema -Advanced:$false).Name | Should -Not -Contain 'FutureSetting'
        $values = @{ MaxFieldLength = 250; FutureSetting = 9 }
        $updated = Reset-BridgeSettingToDefault -Schema $script:Schema -Values $values -Name 'MaxFieldLength'
        $updated.MaxFieldLength | Should -Be 200
        $updated.FutureSetting | Should -Be 9
    }
}
