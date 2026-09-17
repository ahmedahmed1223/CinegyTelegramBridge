#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Template air policy settings and explanations' {
    It 'explains the source of a shortened show duration without calling air' {
        Mock Get-Setting {
            param($Name)
            switch ($Name) {
                TemplateMaxAirSeconds { return @{ urgent = 120 } }
                SensitiveTemplateKeys { return '' }
                default { return $null }
            }
        }
        Get-TemplateAirLimitExplanation -Key urgent -RequestedSeconds 600 | Should -Match '600.*120.*حد القالب'
        Get-TemplateAirLimitExplanation -Key urgent -RequestedSeconds 60 | Should -Be ''
    }
    It 'registers bounded extension controls in the template settings category' {
        @($script:DefaultSettings.Keys) | Should -Contain 'TemplateAirExtensionEnabled'
        $script:DefaultSettings.TemplateAirExtensionResponseSeconds | Should -Be 30
        $script:DefaultSettings.TemplateAirExtensionMaxSeconds | Should -Be 900
        foreach ($name in @('TemplateAirExtensionEnabled','TemplateAirExtensionResponseSeconds','TemplateAirExtensionMaxSeconds')) {
            $script:SettingDisplayMetadata.ContainsKey($name) | Should -BeTrue
            $script:SettingNavigationLabels.ContainsKey($name) | Should -BeTrue
            $buttons = @()
            for ($page=0; $page -lt 20; $page++) {
                $keyboard = Get-SettingsCategoryKeyboard -Category templates -Page $page
                $buttons += @($keyboard.inline_keyboard | ForEach-Object { $_ })
            }
            @($buttons | Where-Object { $_.callback_data -like "*:$name" }).Count | Should -BeGreaterThan 0
        }
        (Get-SettingBounds TemplateAirExtensionResponseSeconds).Maximum | Should -Be 120
        (Get-SettingBounds TemplateAirExtensionMaxSeconds).Maximum | Should -Be 3600
        $script:ProtectedSettings | Should -Contain 'TemplateAirExtensionEnabled'
    }
}
