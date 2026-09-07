#requires -Version 7
<#
    Bridge.RuntimeHealth.Tests.ps1 - the runtime-file health screen, the health
    centre's usage line, and the operator-visible operation reference.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Runtime file health' {
    BeforeEach {
        $script:HealthDir = Join-Path $TestDrive "rt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:HealthDir -Force | Out-Null
    }

    It 'reports a valid file as healthy and carries its stamp' {
        $path = Join-Path $script:HealthDir 'onair.json'
        '{"Scenes":[]}' | Set-Content -LiteralPath $path -Encoding utf8
        $record = @(Get-RuntimeFileHealth -Files @(@{ Name = 'onair.json'; Path = $path }))[0]
        $record.Exists | Should -BeTrue
        $record.Valid | Should -BeTrue
        $record.State | Should -Be 'healthy'
        $record.ModifiedAt | Should -Not -BeNullOrEmpty
    }

    It 'reports a corrupt file as broken rather than throwing' {
        $path = Join-Path $script:HealthDir 'drafts.json'
        'this is not json {{{' | Set-Content -LiteralPath $path -Encoding utf8
        $record = @(Get-RuntimeFileHealth -Files @(@{ Name = 'drafts.json'; Path = $path }))[0]
        $record.Exists | Should -BeTrue
        $record.Valid | Should -BeFalse
        $record.State | Should -Be 'broken'
    }

    It 'calls a corrupt file recoverable when a backup sits beside it' {
        $path = Join-Path $script:HealthDir 'schedule.json'
        'broken{' | Set-Content -LiteralPath $path -Encoding utf8
        '{"ok":true}' | Set-Content -LiteralPath "$path.bak" -Encoding utf8
        $record = @(Get-RuntimeFileHealth -Files @(@{ Name = 'schedule.json'; Path = $path }))[0]
        $record.State | Should -Be 'recoverable'
        $record.HasBackup | Should -BeTrue
    }

    It 'treats a file that was never written as absent, not as a fault' {
        $record = @(Get-RuntimeFileHealth -Files @(@{ Name = 'news-draft.json'; Path = (Join-Path $script:HealthDir 'news-draft.json') }))[0]
        $record.Exists | Should -BeFalse
        $record.State | Should -Be 'absent'
    }

    It 'renders one Arabic row per file and marks the broken one' {
        $good = Join-Path $script:HealthDir 'a.json'; '{}' | Set-Content -LiteralPath $good -Encoding utf8
        $bad = Join-Path $script:HealthDir 'b.json'; 'nope{' | Set-Content -LiteralPath $bad -Encoding utf8
        $text = Get-RuntimeFileHealthText -Records @(Get-RuntimeFileHealth -Files @(
                @{ Name = 'a.json'; Path = $good }, @{ Name = 'b.json'; Path = $bad }))
        $text | Should -Match 'صحة ملفات التشغيل'
        $text | Should -Match 'a\.json'
        $text | Should -Match 'b\.json'
        $text | Should -Match '🔴'
    }

    It 'says so plainly when every file is healthy' {
        $good = Join-Path $script:HealthDir 'a.json'; '{}' | Set-Content -LiteralPath $good -Encoding utf8
        $text = Get-RuntimeFileHealthText -Records @(Get-RuntimeFileHealth -Files @(@{ Name = 'a.json'; Path = $good }))
        $text | Should -Match 'كل ملفات التشغيل سليمة'
    }

    It 'reaches the screen from the health centre keyboard' {
        @((Get-HealthCenterKeyboard).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data) |
            Should -Contain 'health:files'
    }
}

Describe 'Health centre usage line' {
    BeforeEach {
        $script:RuntimeState = New-BridgeRuntimeState
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'connected'
        $script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
        $script:OutputMonitorFailureCount = 0
        $script:OutputMonitorFailureAlerted = $false
        $script:OutputBlackAlerted = $false
        $script:ScheduleEvents = @()
        $script:UserOperationHistory = @{}
        $script:OnAir = @{}
    }

    It 'counts today operations and the operators behind them' {
        Add-UserOperationHistory -OperationId 'air-1' -Action SHOW -Result success -DurationMs 10 -UserId 101 -Layer 4 -Target 'urgent'
        Add-UserOperationHistory -OperationId 'air-2' -Action HIDE -Result success -DurationMs 10 -UserId 101 -Layer 4
        Add-UserOperationHistory -OperationId 'air-3' -Action SHOW -Result success -DurationMs 10 -UserId 202 -Layer 6 -Target 'lower'
        $usage = Get-BridgeUsageMetrics
        $usage.OperationsToday | Should -Be 3
        $usage.ActiveOperators | Should -Be 2
    }

    It 'counts what is on air now and reports uptime' {
        $script:OnAir = @{ '4' = @{ Key = 'urgent' } }
        $usage = Get-BridgeUsageMetrics
        $usage.OnAirCount | Should -Be 1
        $usage.UptimeText | Should -Not -BeNullOrEmpty
    }

    It 'reports zero without inventing activity on a quiet bridge' {
        $usage = Get-BridgeUsageMetrics
        $usage.OperationsToday | Should -Be 0
        $usage.ActiveOperators | Should -Be 0
        $usage.OnAirCount | Should -Be 0
    }

    It 'shows the usage line on the health centre screen' {
        Add-UserOperationHistory -OperationId 'air-1' -Action SHOW -Result success -DurationMs 10 -UserId 101 -Layer 4 -Target 'urgent'
        $snapshot = [pscustomobject]@{ DiskFreeGB = 10; RuntimeStorageBytes = 0L; BackupStorageBytes = 0L }
        # The health centre is HTML now; read it as the operator sees it.
        $text = ConvertFrom-TelegramHtmlText (Get-BridgeHealthCenterText -DiagnosticsSnapshot $snapshot -Warnings @())
        $text | Should -Match '📈 الاستخدام'
    }
}

Describe 'Operator-visible operation reference' {
    BeforeEach { $script:UserOperationHistory = @{} }

    It 'shortens the correlation id to a quotable reference' {
        Get-OperationReference -OperationId 'air-1fbf8e20975640f38a0d7e0b078e0359' | Should -Be '1fbf8e20'
    }

    It 'returns nothing for a missing or malformed id rather than a stray hash' {
        Get-OperationReference -OperationId '' | Should -BeNullOrEmpty
        Get-OperationReference -OperationId 'air-' | Should -BeNullOrEmpty
    }

    It 'prints the reference beside the operation on the operator screen' {
        Mock Send-TelegramMessage {}
        Add-UserOperationHistory -OperationId 'air-1fbf8e20975640f38a0d7e0b078e0359' -Action SHOW -Result success -DurationMs 10 -UserId 101 -Layer 4 -Target 'urgent'
        Invoke-MyOperationsCommand -ChatId 101 -UserId 101
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match '1fbf8e20' }
    }
}
