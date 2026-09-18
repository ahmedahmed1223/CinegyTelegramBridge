#requires -Version 7
. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Weekly digest report' {
    BeforeEach {
        $script:TemplateLastUsed = @{}
        $script:AlertHistory = @{}
        $script:RichPeakPayload = $null
        $script:DefaultSettings = @{ TestSetting1 = 'default1'; TestSetting2 = 'default2' }
    }

    It 'returns weekly report data with all sections' {
        $data = Get-WeeklyReportData
        $data | Should -Not -BeNullOrEmpty
        $data.TickerPublishes | Should -Not -BeNullOrEmpty
        $data.UrgentRunsStarted | Should -Not -BeNullOrEmpty
    }

    It 'builds weekly report blocks with heading' {
        Mock Send-TelegramRichMessage { $true }
        Mock Send-TelegramPagedText { $true }
        Show-WeeklyReport -ChatId 100
        Should -Invoke Send-TelegramRichMessage -Times 1 -Exactly
    }

    It 'includes idle templates in the weekly report' {
        $script:TemplateLastUsed = @{ 'OldTemplate' = (Get-Date).AddDays(-60) }
        Mock Get-TemplateStore { @{ Map = @{ 'OldTemplate' = @{} } } }
        Mock Send-TelegramRichMessage { $true }
        Show-WeeklyReport -ChatId 100
        Should -Invoke Send-TelegramRichMessage -Times 1 -Exactly
    }
}
