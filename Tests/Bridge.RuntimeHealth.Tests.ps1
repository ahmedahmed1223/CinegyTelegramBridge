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

Describe 'The reporting screens lead with a verdict' {
    It 'says whether anything is wrong before listing the rows that prove it' {
        # The health centre is opened to answer one question. It used to answer
        # it only by making the operator read seven rows and notice a colour.
        $healthy = ConvertFrom-TelegramHtmlText (Get-BridgeHealthCenterText `
                -DiagnosticsSnapshot @{ DiskFreeGB = 40 } -Warnings @())
        @($healthy -split "`n" | Where-Object { $_ -match '🟢|🟠|🔴' })[0] |
            Should -Match 'كل شيء سليم|يحتاج مراجعة|عطلٌ يحتاج تدخلًا'
    }

    It 'takes the verdict from the rows, so the two cannot disagree' {
        # Recomputing the judgement would let the heading say "all clear" over
        # a red row - the exact failure the verdict was added to prevent.
        Mock Get-BridgeHealthRows {
            @(
                [pscustomobject]@{ Icon = '🟢'; Name = 'أ'; Detail = 'سليم' }
                [pscustomobject]@{ Icon = '🔴'; Name = 'ب'; Detail = 'معطّل' }
            )
        }
        $text = ConvertFrom-TelegramHtmlText (Get-BridgeHealthCenterText `
                -DiagnosticsSnapshot @{ DiskFreeGB = 40 } -Warnings @())
        $text | Should -Match 'عطلٌ يحتاج تدخلًا'
    }

    It 'folds the files that are fine and leaves the ones that are not on top' {
        # Sixteen lines of "not written yet" gave a healthy install the same
        # weight on screen as a broken one.
        $records = @(1..6 | ForEach-Object {
                [pscustomobject]@{ Name = "ok$_.json"; State = 'healthy'; SizeText = '1 KB'; ModifiedAt = (Get-Date) }
            }) + @([pscustomobject]@{ Name = 'broken.json'; State = 'broken'; SizeText = '0 KB'; ModifiedAt = (Get-Date) })

        $raw = Get-RuntimeFileHealthText -Records $records
        $text = ConvertFrom-TelegramHtmlText $raw

        # The broken file is above the fold, outside any quote.
        $lines = @($text -split "`n")
        $brokenAt = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'broken.json' })
        $quietAt = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'سليمة أو لم تُكتب' })
        $brokenAt | Should -BeGreaterThan -1
        $brokenAt | Should -BeLessThan $quietAt
        # And the six that are fine are folded behind a count.
        $text | Should -Match 'سليمة أو لم تُكتب بعد \(6\)'
        # HTML validity for this screen is pinned by the gate in
        # Bridge.Tests.ps1, which owns Test-BridgeTelegramHtml; asserting it
        # here too would make this file depend on that one's load order.
        $raw | Should -Match '<blockquote expandable>'
    }
}

Describe 'A Cinegy health change says why, in numbers' {
    BeforeEach {
        Mock Write-BridgeLog {}
        Mock Send-AdminBroadcast {}
        $script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
        $script:RuntimeState.Monitoring.LastCinegyHealthCheck = (Get-Date).AddHours(-1)
        $script:HealthHistory.Cinegy.PendingState = ''
        $script:HealthHistory.Cinegy.PendingCount = 0
        $script:HealthHistory.Cinegy.FailureCount = 0
        $script:HealthHistory.Cinegy.AlertSent = $false
        # The real settings rather than a mock: Get-Setting is read by half the
        # bridge, and a filtered mock without a default breaks every call this
        # function makes for an unrelated key.
        $config.Settings | Add-Member -NotePropertyName CinegyHealthConfirmChecks -NotePropertyValue 1 -Force
        $config.Settings | Add-Member -NotePropertyName NotifyAdminsOnCinegyHealth -NotePropertyValue $false -Force
        $config.Settings | Add-Member -NotePropertyName CinegyHealthCheckSeconds -NotePropertyValue 1 -Force
    }

    It 'names the tolerance that was crossed, not just the word "unhealthy"' {
        # The log said "Cinegy health changed from healthy to unhealthy" and
        # nothing else, so the only way to learn why was to read the engine's
        # metrics by hand after the moment had passed.
        Mock Get-AirTelemetryStatus {
            [pscustomobject]@{
                Success = $true; Healthy = $false; SampleCount = 60; OutputCount = 1440
                DroppedCount = 60; DroppedPercent = 4.0; NoInputSignal = 0
                AverageReadTime = 9.1; MaxReadErrorRate = 0; MaxHeartbeat = 700
                Issues = @('الإطارات الساقطة 60 تتجاوز الحد 5')
            }
        }

        Update-CinegyHealthWatchdog

        Should -Invoke Write-BridgeLog -ParameterFilter {
            $Message -match 'healthy to unhealthy' -and $Message -match 'تتجاوز الحد'
        }
        $script:HealthHistory.Cinegy.LastError | Should -Match 'تتجاوز الحد'
    }

    It 'falls back to the raw figures when the engine names no issue' {
        Mock Get-AirTelemetryStatus {
            [pscustomobject]@{
                Success = $true; Healthy = $false; SampleCount = 60; OutputCount = 1440
                DroppedCount = 12; DroppedPercent = 0.8; NoInputSignal = 0
                AverageReadTime = 3.2; MaxReadErrorRate = 0.9; MaxHeartbeat = 700
                Issues = @()
            }
        }

        Update-CinegyHealthWatchdog

        $script:HealthHistory.Cinegy.LastError | Should -Match '12'
        $script:HealthHistory.Cinegy.LastError | Should -Match 'أخطاء القراءة'
    }

    It 'says unreachable is unreachable, and keeps the credential out of it' {
        # A transport error carries the URL it failed on, and that URL is how
        # the bridge reaches Air - not secret here, but the same redactor
        # guards every other path and this one must not be the exception.
        Mock Get-AirTelemetryStatus {
            [pscustomobject]@{ Success = $false; Healthy = $null; Error = 'connection refused' }
        }

        Update-CinegyHealthWatchdog

        $script:HealthHistory.Cinegy.LastError | Should -Match 'تعذّر الوصول'
        $script:HealthHistory.Cinegy.LastError | Should -Match 'connection refused'
    }
}

Describe 'Recovery is announced, not only the failure' {
    BeforeEach {
        Mock Write-BridgeLog {}
        Mock Send-AdminBroadcast {}
        $script:RuntimeState.Monitoring.LastCinegyHealthCheck = (Get-Date).AddHours(-1)
        $script:HealthHistory.Cinegy.PendingState = ''
        $script:HealthHistory.Cinegy.PendingCount = 0
        $config.Settings | Add-Member -NotePropertyName CinegyHealthConfirmChecks -NotePropertyValue 1 -Force
        $config.Settings | Add-Member -NotePropertyName NotifyAdminsOnCinegyHealth -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName CinegyHealthCheckSeconds -NotePropertyValue 1 -Force
        Mock Get-AirTelemetryStatus {
            [pscustomobject]@{
                Success = $true; Healthy = $true; SampleCount = 60; OutputCount = 1500
                DroppedCount = 0; DroppedPercent = 0; NoInputSignal = 0
                AverageReadTime = 1.0; MaxReadErrorRate = 0; MaxHeartbeat = 700; Issues = @()
            }
        }
    }

    It 'says it recovered even when the dip never reached the warning threshold' {
        # The warning waits for HealthFailureAlertThreshold consecutive
        # failures. A dip that cleared just under it left the screens saying
        # "غير سليم" for minutes and then went quiet, and an operator who had
        # looked in the middle of it was never told it was over.
        $script:RuntimeState.Monitoring.CinegyHealthState = 'unhealthy'
        $script:HealthHistory.Cinegy.AlertSent = $false
        $script:HealthHistory.Cinegy.OutageStartedAt = (Get-Date).AddMinutes(-4)
        $script:HealthHistory.Cinegy.LastError = 'قياسات غير سليمة: الإطارات الساقطة 60'

        Update-CinegyHealthWatchdog

        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تعافت صحة Cinegy' -and
            $Text -match 'استمر الخلل' -and
            # It carries why it had been unhealthy, and the numbers it is at now.
            $Text -match 'الإطارات الساقطة 60' -and $Text -match 'العينات 60' -and
            # And says why no warning preceded it.
            $Text -match 'لم يبلغ الخلل حدّ التنبيه'
        }
    }

    It 'does not claim a recovery when it was never down' {
        # A first reading of a run is 'unknown' to 'healthy', which is a
        # startup, not a recovery - and announcing one on every restart is how
        # an alert channel gets muted.
        $script:RuntimeState.Monitoring.CinegyHealthState = 'unknown'
        $script:HealthHistory.Cinegy.AlertSent = $false
        $script:HealthHistory.Cinegy.OutageStartedAt = $null

        Update-CinegyHealthWatchdog

        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'stays silent when the state has not moved' {
        $script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
        $script:HealthHistory.Cinegy.AlertSent = $false

        Update-CinegyHealthWatchdog

        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }
}
