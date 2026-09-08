#requires -Version 7
<#
    Bridge.Admin.Tests.ps1 - Administrator tools, diagnostics, audit, and reports.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Per-user operation history and safe retry' {
    BeforeEach {
        $script:UserOperationHistory = @{}
        $script:LastShowAttempts = @{}
        $script:auditFile = Join-Path $TestDrive 'audit.jsonl'
        Mock Write-BridgeLog { }
        Mock Send-TelegramMessage { }
    }

    It 'keeps operation history isolated by Telegram user id without editorial values' {
        Write-AirOperationResult -OperationId one -Action SHOW -Result failed -DurationMs 10 -UserId 101 -ChatId 101 -Layer 4 -Target urgent -ErrorText timeout
        Write-AirOperationResult -OperationId two -Action HIDE -Result success -DurationMs 5 -UserId 202 -ChatId 202 -Layer 7 -Target ticker

        $first = @(Get-UserOperationHistory -UserId 101)
        $second = @(Get-UserOperationHistory -UserId 202)
        $first.Count | Should -Be 1
        $first[0].OperationId | Should -Be 'one'
        $first[0].Target | Should -Be 'urgent'
        $first[0].PSObject.Properties.Name | Should -Not -Contain 'Variables'
        $second.Count | Should -Be 1
        $second[0].OperationId | Should -Be 'two'
    }

    It 'reopens review for the same users last SHOW attempt instead of sending directly' {
        $script:LastShowAttempts['101'] = @{ Key = 'urgent'; Variables = @{ Headline = 'review me' }; AutoHideSeconds = 20 }
        Mock Get-TemplateIndex { 3 }
        Mock Start-ShowFlow { }
        Mock Show-TitlerTemplate { throw 'must not send during retry request' }

        Invoke-RetryLastShowAttempt -ChatId 101 -UserId 101

        Should -Invoke Start-ShowFlow -Times 1 -Exactly -ParameterFilter {
            $TemplateIndex -eq 3 -and $ChatId -eq 101 -and $UserId -eq 101 -and
                $InitialValues.Headline -eq 'review me' -and $ReviewImmediately
        }
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'shows only the requesting users recent operations with a retry button' {
        Add-UserOperationHistory -OperationId one -Action SHOW -Result failed -DurationMs 10 -UserId 101 -Layer 4 -Target urgent
        Add-UserOperationHistory -OperationId two -Action SHOW -Result success -DurationMs 10 -UserId 202 -Layer 7 -Target private
        $script:LastShowAttempts['101'] = @{ Key = 'urgent'; Variables = @{}; AutoHideSeconds = 0 }

        Invoke-MyOperationsCommand -ChatId 101 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'urgent' -and $Text -notmatch 'private' -and
                @($ReplyMarkup.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text }) -contains '🔁 إعادة محاولة آمنة'
        }
    }

    It 'speaks Arabic to the operator instead of leaking the wire verbs' {
        Add-UserOperationHistory -OperationId one -Action SHOW -Result success -DurationMs 120 -UserId 101 -Layer 4 -Target urgent
        Add-UserOperationHistory -OperationId two -Action HIDE -Result failed -DurationMs 90 -UserId 101 -Layer 7 -Target lower

        Invoke-MyOperationsCommand -ChatId 101 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            # Arabic wording, not SHOW/HIDE, and no millisecond counter.
            $Text -match 'عرض «urgent» على الطبقة 4' -and
                $Text -match 'فشل إخفاء «lower» على الطبقة 7' -and
                $Text -notmatch 'SHOW' -and $Text -notmatch 'HIDE' -and $Text -notmatch 'ms' -and
                $Text -match 'افحص الاتصال ثم أعد المحاولة'
        }
    }

    It 'shows the text that actually reached the screen' {
        # The template key alone does not tell an operator which of five
        # breaking-news straps they ran; the copy does.
        Add-UserOperationHistory -OperationId one -Action SHOW -Result success -DurationMs 10 `
            -UserId 101 -Layer 6 -Target 'breaking-news' -Values 'Headline.Text: انطلاق القمة'

        Invoke-MyOperationsCommand -ChatId 101 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'انطلاق القمة' -and $Text -match 'breaking-news'
        }
    }

    It 'stays quiet about copy it never recorded' {
        # Entries written before the values field existed must not render an empty
        # line that reads as "this banner was blank".
        Add-UserOperationHistory -OperationId two -Action HIDE -Result success -DurationMs 10 `
            -UserId 101 -Layer 6 -Target 'breaking-news'

        Invoke-MyOperationsCommand -ChatId 101 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -notmatch '📝' }
    }

    It 'no longer blames a restart for an empty operations screen' {
        Invoke-MyOperationsCommand -ChatId 303 -UserId 303

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -notmatch 'منذ آخر تشغيل' -and $Text -match 'لم تُسجَّل لك أي عملية بعد'
        }
    }
}

Describe 'Quiet runtime orchestration' {
    It 'does not leak periodic helper return values to the terminal' {
        foreach ($step in @('Update-PostShowQueue', 'Update-SnapshotJobs', 'Update-RelayWatchdog', 'Update-AutoHideQueue', 'Update-ScheduleQueue', 'Update-PendingExpiry', 'Update-SnapshotCleanup', 'Save-UsageCounts', 'Save-UserProfiles', 'Update-CinegyStateWatchdog', 'Update-CinegyHealthWatchdog', 'Update-Heartbeat')) {
            Mock $step { return $true }
        }

        @(Invoke-BridgeTick).Count | Should -Be 0
    }
}

Describe 'Maintenance mode control gate' {
    BeforeEach {
        $script:OriginalMaintenanceMode = Get-Setting 'MaintenanceMode'
        $config.Settings | Add-Member -NotePropertyName MaintenanceMode -NotePropertyValue $true -Force
        Mock Send-TelegramMessage { }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true; EventId = '{A}' } }
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true; Error = '' } }
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{ urgent = [pscustomobject]@{ Key='urgent'; Layer=4; Path='urgent.cintitle'; FieldTypes=@{} } }; Order=@('urgent'); Errors=@() }
        }
    }

    AfterEach { $config.Settings | Add-Member -NotePropertyName MaintenanceMode -NotePropertyValue $script:OriginalMaintenanceMode -Force }

    It 'blocks SHOW before any Cinegy command is sent' {
        $result = Invoke-ShowTemplateResult -Key urgent -ChatId 10 -UserId 10
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'الصيانة'
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }

    It 'blocks a normal HIDE before any Cinegy command is sent' {
        Invoke-HideLayer -Layer 4 -ChatId 10 -UserId 10 | Should -BeFalse
        Should -Invoke Hide-TitlerTemplate -Times 0 -Exactly
    }

    It 'blocks starting a new scheduled SHOW' {
        Mock Clear-PendingState { }
        Mock Get-TemplateByIndex { throw 'The schedule flow must stop before loading a template.' }
        Start-ScheduleShowFlow -TemplateIndex 0 -ChatId 10 -UserId 10
        Should -Invoke Get-TemplateByIndex -Times 0 -Exactly
    }

    It 'allows the administrator emergency hide-all override' {
        Mock Test-Admin { $true }
        Mock Get-HideAllTargetLayers { @(4) }
        Mock Invoke-HideLayer { $true }
        Mock Write-BridgeLog { }; Mock Add-AuditEntry { }
        Invoke-HideAllLayers -ChatId 1 -UserId 1
        Should -Invoke Invoke-HideLayer -Times 1 -Exactly -ParameterFilter { $Layer -eq 4 -and $MaintenanceOverride }
    }
}

Describe 'Help guidance' {
    It 'gives an actionable short path for common on-air operations' {
        $help = Get-HelpText

        $help | Should -Match '📋 القوالب ←'
        $help | Should -Match '📅 الجدولة'
        $help | Should -Match 'ظاهر.*خارجي.*مخفي.*غير معروف'
        $help | Should -Match '✏️ تحديث نص ←'
        $help | Should -Match '⏱ عرض مؤقّت'
    }

    It 'hides admin-only guidance from a regular user' {
        Mock Test-Admin { $false }

        $help = Get-HelpText

        $help | Should -Not -Match 'أدوات المشرف'
        $help | Should -Not -Match '🔄 تحديث حالة Cinegy'
    }

    It 'includes admin tools for an administrator' {
        Mock Test-Admin { $true }

        $help = Get-HelpText

        $help | Should -Match 'أدوات المشرف'
        $help | Should -Match '📊 الحالة الكاملة: للمشرف والمالك'
    }
}

Describe 'Simple and full status reports' {
    BeforeEach {
        $script:OnAir.Clear()
        foreach ($service in @('Telegram', 'Cinegy')) {
            $script:HealthHistory[$service].LastSuccess = $null
            $script:HealthHistory[$service].LastError = ''
            $script:HealthHistory[$service].LastErrorAt = $null
        }
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { }
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{ urgent = 1 }; Order = @('urgent'); Errors = @() }
        }
        Mock Get-CinegyLayerDashboard {
            @([pscustomobject]@{
                Layer = 4; Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = ''
                OutputState = 'Normal'; LicenseState = 'Licensed'; ClientConnected = $true; ClientIdentity = 'Client 1'
            })
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{
                Checked = @(4); Added = @(); Removed = @(); Failed = @()
                LastSuccessfulAt = [datetime]'2026-08-22T11:20:00'
            }
        }
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } }
        Mock Get-MonitorFrame { $null }
        Mock Get-FfmpegPath { 'ffmpeg.exe' }
        Mock Get-AirTelemetryStatus {
            [pscustomobject]@{
                Success = $true; Healthy = $true; SampleCount = 60
                OutputCount = 1500; DroppedCount = 0; NoInputSignal = 0
                MaxReadErrorRate = 0; AverageReadTime = 1.2; MaxHeartbeat = 700
            }
        }
        Mock Get-LiveRelayStatusText { 'متوقف' }
    }

    AfterEach { $script:OnAir.Clear() }

    It 'keeps the public status lightweight while showing the Air server address' {
        Mock Test-Admin { $false }

        Invoke-StatusCommand -ChatId 200 -UserId 200

        Should -Invoke Get-AirTelemetryStatus -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            # The screen goes out as HTML, so it is read the way the operator
            # sees it rather than through the markup.
            $rendered = ConvertFrom-TelegramHtmlText $Text
            $ChatId -eq 200 -and $ParseMode -eq 'HTML' -and
                $rendered -match 'القناة' -and $rendered -match [regex]::Escape([string]$config.AirServerAddress) -and
                # Relative first, because the question being asked is "is this
                # current?"; the clock time stays in brackets for log comparison.
                $rendered -match 'آخر فحص ناجح: (منذ .+|الآن) \(11:20:00\)' -and $rendered -notmatch 'صحة الخدمات'
        }
    }

    It 'keeps status and Cinegy reconciliation available during maintenance' {
        $original = Get-Setting 'MaintenanceMode'
        try {
            $config.Settings | Add-Member -NotePropertyName MaintenanceMode -NotePropertyValue $true -Force
            Mock Test-Admin { $false }

            Invoke-StatusCommand -ChatId 200 -UserId 200

            Should -Invoke Get-CinegyLayerDashboard -Times 1 -Exactly
            Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly
            Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'القناة' }
        }
        finally {
            $config.Settings | Add-Member -NotePropertyName MaintenanceMode -NotePropertyValue $original -Force
        }
    }

    It 'includes the operator identity in the on-air summary so multiple users are visible' {
        $script:UserAliases['777'] = 'مخرج الأخبار'
        $script:OnAir[4] = @{ Key = 'urgent'; At = (Get-Date).AddMinutes(-2); UserId = 777; ActiveId = '{A}'; Source = 'bridge' }
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date).AddMinutes(-5); UserId = 0; ActiveId = '{B}'; Source = 'cinegy'; CinegyEventName = 'Cinegy Type Layer 8 On' }

        $summary = Get-OnAirSummary

        $summary | Should -Match '🔵.*طبقة 4.*urgent'
        $summary | Should -Match 'Bot.*مخرج الأخبار'
        $summary | Should -Match '🟣.*طبقة 8.*ticker'
        $summary | Should -Match 'Cinegy Air.*Cinegy Type Layer 8 On'
    }

    It 'identifies each live template and layer in the main-menu hide buttons' {
        Mock Test-Admin { $false }
        $script:OnAir[4] = @{ Key = 'urgent'; At = Get-Date; UserId = 777; ActiveId = '{A}'; Source = 'bridge' }
        $script:OnAir[8] = @{ Key = 'ticker'; At = Get-Date; UserId = 0; ActiveId = '{B}'; Source = 'cinegy' }

        $keyboard = Get-MainMenuKeyboard -ChatId 200 -UserId 200
        $labels = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_.text })

        $labels | Should -Contain '🔴 إخفاء 4 · urgent'
        $labels | Should -Contain '🔴 إخفاء 8 · ticker'
    }

    It 'merges layer details and health timings into the administrator full status' {
        Mock Test-Admin { $true }
        $callback = [pscustomobject]@{
            id = 'full-status-1'
            from = [pscustomobject]@{ id = 100 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100 } }
            data = 'menu:fullstatus'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            # The six section headings are bold now, so the assertions read the
            # rendered screen; that the tags are there at all is pinned below.
            $rendered = ConvertFrom-TelegramHtmlText $Text
            $ChatId -eq 100 -and $ParseMode -eq 'HTML' -and
                $rendered -match 'الحالة الكاملة' -and $rendered -match 'Telegram.*ms' -and $rendered -match 'Cinegy.*ms' -and $rendered -match 'طبقة 4' -and
                $rendered -match '📺 المشاهد النشطة' -and $rendered -match '🎛 اتصال Cinegy' -and
                $rendered -match '🩺 صحة الخدمات' -and $rendered -match '⚙️ التشغيل والجدولة' -and $rendered -match '👥 الوصول' -and
                $rendered -match 'وضع المشاهد المختار: Single' -and
                $Text -match '<b>🎛 اتصال Cinegy</b>'
        }
    }

    It 'includes a manual source probe and monitoring-server state in full status' {
        Mock Test-Admin { $true }
        Mock Get-MonitorFrame { 'monitor-frame.jpg' }
        Mock Get-BridgeFrameLuminance { 120 }
        Mock Remove-Item { }

        Invoke-FullStatusCommand -ChatId 100 -UserId 100

        Should -Invoke Get-MonitorFrame -Times 1 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match '📡 مراقب المصدر' -and
                $Text -match 'سيرفر المتابعة' -and
                $Text -match 'المصدر الأساسي' -and
                $Text -match 'متاح'
        }
    }

    It 'rejects the legacy health command for a regular user' {
        Mock Test-Admin { $false }

        Invoke-BridgeCommand -Text '/health' -ChatId 200 -UserId 200

        Should -Invoke Get-AirTelemetryStatus -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
    }

    It 'keeps the legacy health command as an administrator alias for full status' {
        Mock Test-Admin { $true }

        Invoke-BridgeCommand -Text '/health' -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 100 -and $Text -match 'الحالة الكاملة' -and $Text -match 'صحة الخدمات'
        }
    }

    It 'keeps last success and error history inside full status' {
        Mock Test-Admin { $true }
        Invoke-HealthCommand -ChatId 100 -UserId 100

        Mock Invoke-RestMethod { throw 'telegram timeout' }
        Mock Get-AirTelemetryStatus { [pscustomobject]@{ Success = $false; Healthy = $null } }
        Invoke-HealthCommand -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $ChatId -eq 100 -and $Text -match 'آخر نجاح' -and $Text -match 'آخر خطأ: telegram timeout'
        }
    }
}

Describe 'Admin diagnostics command' {
    BeforeEach {
        $script:AirOperationCounters = @{ Success = 0; Failed = 0; Blocked = 0 }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $true }
        Mock Send-TelegramMessage { }
        Mock Get-TemplateStore {
            [pscustomobject]@{ Map = @{ a = 1; b = 2 }; Order = @('a', 'b'); Errors = @() }
        }
        Mock Get-AirTelemetryStatus {
            [pscustomobject]@{
                Success = $true; Healthy = $true; SampleCount = 60
                OutputCount = 1500; DroppedCount = 0; NoInputSignal = 0
                MaxReadErrorRate = 0; AverageReadTime = 1.2; MaxHeartbeat = 700
            }
        }
    }

    It 'reports operational state to an admin without exposing the bot token' {
        Invoke-BridgeCommand -Text '/diagnostics' -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تشخيص' -and $Text -match 'Bridge' -and $Text -match 'Cinegy' -and
                $Text -match 'الذاكرة' -and $Text -match 'مساحة القرص' -and $Text -match 'أحجام الملفات' -and
                $Text -match 'نجاح.*فشل.*محظور' -and $Text -notmatch [regex]::Escape([string]$config.BotToken)
        }
    }

    It 'counts successful failed and blocked air operations without reading log files' {
        Mock Write-BridgeLog { }
        Write-AirOperationResult -OperationId a -Action SHOW -Result success -DurationMs 1 -UserId 1 -ChatId 1
        Write-AirOperationResult -OperationId b -Action HIDE -Result failed -DurationMs 1 -UserId 1 -ChatId 1
        Write-AirOperationResult -OperationId c -Action EXIT -Result blocked -DurationMs 1 -UserId 1 -ChatId 1

        $snapshot = Get-BridgeDiagnosticsSnapshot
        $snapshot.AirOperations.Success | Should -Be 1
        $snapshot.AirOperations.Failed | Should -Be 1
        $snapshot.AirOperations.Blocked | Should -Be 1
    }

    It 'warns when free disk or retained runtime storage crosses configured limits' {
        $snapshot = [pscustomobject]@{
            DiskFreeGB = 0.5
            RuntimeStorageBytes = 120MB
            BackupStorageBytes = 80MB
        }

        $warnings = @(Get-DiagnosticWarnings -Snapshot $snapshot -DiskFreeWarningGB 2 -RuntimeStorageWarningMB 100 -BackupStorageWarningMB 50)
        $warnings.Count | Should -Be 3
        $warnings -join ' ' | Should -Match 'القرص'
        $warnings -join ' ' | Should -Match 'السجلات'
        $warnings -join ' ' | Should -Match 'النسخ'
    }

    It 'removes user and chat identifiers as well as secrets from diagnostic text' {
        $safe = Protect-DiagnosticText "AIR_OP user=123456 chat=987654 token=123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345 user 55555 from 44444"

        $safe | Should -Not -Match '123456|987654|55555|44444|ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $safe | Should -Match 'user=\*\*\*|chat=\*\*\*|user \*\*\*|from \*\*\*'
    }
}

Describe 'Administrator log cleanup' {
    BeforeEach {
        $script:PendingState.Clear()
        $script:auditFile = Join-Path $TestDrive 'audit.jsonl'
        $script:logPath = Join-Path $TestDrive 'bridge.log'
        $script:logDir = $TestDrive
        Set-Content -LiteralPath $script:auditFile -Value '{"old":"audit"}'
        Set-Content -LiteralPath $script:logPath -Value 'old runtime line'
        Set-Content -LiteralPath (Join-Path $TestDrive 'bridge.1.log') -Value 'old rotated line'
        Set-Content -LiteralPath (Join-Path $TestDrive 'relay-stderr.log') -Value 'old relay error'
        Set-Content -LiteralPath (Join-Path $TestDrive 'onair.json') -Value '{"live":true}'
        Mock Test-Admin { $true }
        Mock Test-CallbackAdmin { $true }
        Mock Confirm-TelegramCallback { }
        Mock Send-TelegramMessage { }
    }

    It 'requires a fresh per-admin confirmation before deleting a log' {
        Request-DiagnosticLogClear -Kind runtime -ChatId 100 -UserId 100

        (Get-Content -LiteralPath $script:logPath -Raw) | Should -Match 'old runtime'
        $state = Get-PendingState -ChatId 100
        $state.Mode | Should -Be 'diagnostic_log_clear'
        $state.Kind | Should -Be 'runtime'
        $state.UserId | Should -Be 100
    }

    It 'clears the current and rotated runtime logs but preserves the audit trail' {
        Clear-DiagnosticLog -Kind runtime -UserId 100 | Should -BeTrue

        (Get-Content -LiteralPath $script:logPath -Raw) | Should -Not -Match 'old runtime'
        Test-Path -LiteralPath (Join-Path $TestDrive 'bridge.1.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $TestDrive 'relay-stderr.log') | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $TestDrive 'onair.json') -Raw) | Should -Match 'live'
        (Get-Content -LiteralPath $script:auditFile -Raw) | Should -Match 'log_clear'
    }

    It 'clears old audit entries and creates a new record identifying the cleanup operation' {
        Clear-DiagnosticLog -Kind audit -UserId 100 | Should -BeTrue

        $content = Get-Content -LiteralPath $script:auditFile -Raw
        $content | Should -Not -Match 'old.*audit'
        $record = $content | ConvertFrom-Json
        $record.event | Should -Be 'log_clear'
        $record.target | Should -Be 'audit'
    }
}

Describe 'Redacted diagnostic bundle' {
    BeforeEach {
        $script:logDir = Join-Path $TestDrive 'bundle-runtime'
        New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null
        $script:logPath = Join-Path $script:logDir 'bridge.log'
        Set-Content -LiteralPath $script:logPath -Value @(
            '2026-08-22 [INFO] AIR_OP user=123456 chat=987654 target="ticker"'
            '2026-08-22 [ERROR] token 123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345 from 55555'
        )
    }

    It 'contains only a health summary and redacted recent runtime lines' {
        $bundle = New-DiagnosticBundle
        $extract = Join-Path $TestDrive 'bundle-extracted'
        [IO.Compression.ZipFile]::ExtractToDirectory($bundle, $extract)

        @(Get-ChildItem -LiteralPath $extract -File).Name | Sort-Object | Should -Be @('recent-runtime.log', 'summary.json')
        $allText = (Get-Content -LiteralPath (Join-Path $extract 'summary.json') -Raw) + "`n" +
            (Get-Content -LiteralPath (Join-Path $extract 'recent-runtime.log') -Raw)
        $allText | Should -Not -Match '123456|987654|55555|ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $allText | Should -Not -Match 'BotToken|AllowedUserIds|onair'
        $allText | Should -Match 'user=\*\*\*|chat=\*\*\*'
    }

    It 'is available only through the administrator command' {
        Mock Test-Admin { $true }
        Mock New-DiagnosticBundle { Join-Path $TestDrive 'diagnostics.zip' }
        Mock Send-TelegramDocument { $true }
        Mock Remove-Item { }

        Invoke-DiagnosticBundleCommand -ChatId 100 -UserId 100

        Should -Invoke Send-TelegramDocument -Times 1 -Exactly -ParameterFilter { $ChatId -eq 100 -and $FilePath -match 'diagnostics\.zip$' }
    }
}

Describe 'Operator log screens survive a restart' {
    BeforeEach {
        $script:OriginalAuditFileForRestoreTest = $script:auditFile
        $script:auditFile = Join-Path $TestDrive "audit-restore-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:AuditTrail = [System.Collections.Generic.List[string]]::new()
        $script:UserOperationHistory = @{}
        Mock Write-BridgeLog { }
        Mock Get-AuditArchiveFiles { @() }
    }

    AfterEach {
        $script:auditFile = $script:OriginalAuditFileForRestoreTest
        $script:AuditTrail = [System.Collections.Generic.List[string]]::new()
        $script:UserOperationHistory = @{}
    }

    It 'rebuilds the 📜 screen from the activity records on disk' {
        Add-Content -LiteralPath $script:auditFile -Encoding utf8 -Value @(
            (@{ timestampUtc = '2099-08-21T07:00:00.0000000Z'; event = 'activity'; message = 'عرض القالب urgent' } | ConvertTo-Json -Compress)
            (@{ timestampUtc = '2099-08-21T07:05:00.0000000Z'; event = 'air_control'; action = 'SHOW'; userId = 20; result = 'success' } | ConvertTo-Json -Compress)
            (@{ timestampUtc = '2099-08-21T07:10:00.0000000Z'; event = 'activity'; message = 'إخفاء الطبقة 4' } | ConvertTo-Json -Compress)
        )

        Import-AuditTrail

        $script:AuditTrail.Count | Should -Be 2
        $script:AuditTrail[0] | Should -Match 'عرض القالب urgent'
        $script:AuditTrail[1] | Should -Match 'إخفاء الطبقة 4'
        # air_control belongs to the 🧾 screen, not this one.
        ($script:AuditTrail -join "`n") | Should -Not -Match 'SHOW'
    }

    It 'rebuilds 🧾 عملياتي per user with the fields the screen prints' {
        Add-Content -LiteralPath $script:auditFile -Encoding utf8 -Value @(
            (@{ timestampUtc = '2099-08-21T07:00:00.0000000Z'; event = 'air_control'; operationId = 'air-1'; action = 'SHOW'; result = 'success'; userId = 101; layer = 4; target = 'urgent'; durationMs = 120 } | ConvertTo-Json -Compress)
            (@{ timestampUtc = '2099-08-21T07:01:00.0000000Z'; event = 'air_control'; operationId = 'air-2'; action = 'HIDE'; result = 'failed'; userId = 202; layer = 7; target = 'lower'; durationMs = 90 } | ConvertTo-Json -Compress)
            (@{ timestampUtc = '2099-08-21T07:02:00.0000000Z'; event = 'activity'; message = 'ليست عملية تحكم' } | ConvertTo-Json -Compress)
        )

        Import-UserOperationHistory

        $first = @(Get-UserOperationHistory -UserId 101)
        $first.Count | Should -Be 1
        $first[0].Action | Should -Be 'SHOW'
        $first[0].Target | Should -Be 'urgent'
        $first[0].Layer | Should -Be 4
        $first[0].DurationMs | Should -Be 120
        $first[0].Result | Should -Be 'success'

        @(Get-UserOperationHistory -UserId 202).Count | Should -Be 1
        @(Get-UserOperationHistory -UserId 999).Count | Should -Be 0
    }

    It 'keeps a UTC stamp from drifting when it is restored for display' {
        Add-Content -LiteralPath $script:auditFile -Encoding utf8 -Value (
            @{ timestampUtc = '2099-08-21T07:00:00.0000000Z'; event = 'air_control'; action = 'SHOW'; result = 'success'; userId = 101; layer = 4; target = 'urgent'; durationMs = 10 } | ConvertTo-Json -Compress)

        Import-UserOperationHistory

        $expected = ([datetime]'2099-08-21T07:00:00Z').ToLocalTime()
        (@(Get-UserOperationHistory -UserId 101)[0].At) | Should -Be $expected
    }

    It 'leaves both screens empty when no audit file exists yet' {
        Import-AuditTrail
        Import-UserOperationHistory

        $script:AuditTrail.Count | Should -Be 0
        $script:UserOperationHistory.Keys.Count | Should -Be 0
    }
}

Describe 'Bridge lifecycle notifications' {
    BeforeEach {
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'unknown'
        $script:HealthHistory.Telegram.FailureCount = 0
        $script:HealthHistory.Telegram.OutageStartedAt = $null
        $script:HealthHistory.Telegram.AlertSent = $false
        Mock Get-SettingInt { 2 }
        Mock Send-AdminBroadcast { }
        Mock Write-BridgeLog { }
    }

    It 'alerts only after the Telegram failure threshold and sends one recovery notification' {
        Set-TelegramConnectionState -Connected:$false -ErrorMessage 'timeout'
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
        Set-TelegramConnectionState -Connected:$false -ErrorMessage 'timeout again'
        Set-TelegramConnectionState -Connected:$false -ErrorMessage 'timeout third'
        Set-TelegramConnectionState -Connected:$true

        Should -Invoke Send-AdminBroadcast -Times 2 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'استعاد.*Telegram' }
        $script:HealthHistory.Telegram.FailureCount | Should -Be 0
        $script:HealthHistory.Telegram.OutageStartedAt | Should -BeNullOrEmpty
    }

    It 'notifies admins when the bridge starts' {
        Send-BridgeStartupNotification

        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'بدأ تشغيل' -and $Text -match $script:BridgeVersion }
    }
}

Describe 'Administrator tools grouping' {
    BeforeEach { $script:OnAir = @{} }

    It 'keeps settings and access requests one tap away for an administrator' {
        Mock Test-Admin { $true }
        $flat = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $flat | Should -Contain 'menu:settings'
        $flat | Should -Contain 'menu:pending'
        $flat | Should -Contain 'menu:admintools'
    }

    It 'moves the rarely used configuration off the main menu' {
        Mock Test-Admin { $true }
        $flat = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        foreach ($moved in @('menu:usersadmin', 'menu:presetsadmin', 'menu:templatesadmin', 'menu:audit', 'menu:diagnostics')) {
            $flat | Should -Not -Contain $moved
        }
    }

    It 'still reaches every moved entry from the tools screen, with a way back' {
        Mock Test-Admin { $true }
        $flat = @((Get-AdminToolsKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        foreach ($moved in @('menu:usersadmin', 'menu:presetsadmin', 'menu:templatesadmin', 'menu:audit', 'menu:diagnostics')) {
            $flat | Should -Contain $moved
        }
        $flat | Should -Contain 'menu'
    }

    It 'shows no administrator surface at all to an operator' {
        Mock Test-Admin { $false }
        $flat = @((Get-MainMenuKeyboard -ChatId 200 -UserId 200).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $flat | Should -Not -Contain 'menu:admintools'
        $flat | Should -Not -Contain 'menu:settings'
    }

    It 'shows access-request approval to administrators and the owner only' {
        $script:DefaultSettings['EnableSelfServiceRequests'] | Should -BeTrue
        $oldAdminUsers = @(Get-JsonProp $config 'AdminUserIds')
        $oldAdminChats = @(Get-JsonProp $config 'AdminChatIds')
        $oldOwners = @(Get-JsonProp $config 'OwnerUserIds')
        try {
            $config | Add-Member -NotePropertyName AdminUserIds -NotePropertyValue @(100) -Force
            $config | Add-Member -NotePropertyName AdminChatIds -NotePropertyValue @(100) -Force
            $config | Add-Member -NotePropertyName OwnerUserIds -NotePropertyValue @(101) -Force
            $script:PendingApprovals = @{ 555 = @{ UserId = 555 } }

            $adminFlat = @((Get-MainMenuKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
            $adminFlat | Should -Contain 'menu:pending'

            $ownerFlat = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
            $ownerFlat | Should -Contain 'menu:pending'

            $operatorFlat = @((Get-MainMenuKeyboard -ChatId 200 -UserId 200).inline_keyboard |
                    ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
            $operatorFlat | Should -Not -Contain 'menu:pending'
        }
        finally {
            $config | Add-Member -NotePropertyName AdminUserIds -NotePropertyValue $oldAdminUsers -Force
            $config | Add-Member -NotePropertyName AdminChatIds -NotePropertyValue $oldAdminChats -Force
            $config | Add-Member -NotePropertyName OwnerUserIds -NotePropertyValue $oldOwners -Force
            $script:PendingApprovals = @{}
        }
    }
}

Describe 'What is new and help content' {
    BeforeEach { $script:OnAir = @{} }

    It 'leads with the running version so an operator can tell which build they are on' {
        Get-WhatsNewText | Should -Match ([regex]::Escape($script:BridgeVersion))
    }

    It 'sends the release notes as HTML and keeps every tag inside one line' {
        Mock Send-TelegramMessage { $script:sentText = $Text }
        Mock Get-MainMenuKeyboard { @{ inline_keyboard = @() } }

        Send-TelegramPagedText -ChatId 100 -Parts @(Get-WhatsNewParts)[0] -ParseMode HTML

        $script:sentText | Should -Match '<b>'
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ParseMode -eq 'HTML' }
        # A line-boundary split cuts between lines, so a tag that opens on one
        # line and closes on another is the one thing that cannot survive it.
        foreach ($line in (Get-WhatsNewText -split "`n")) {
            (([regex]::Matches($line, '<[a-z]')).Count) | Should -Be (([regex]::Matches($line, '</[a-z]')).Count)
        }
    }

    It 'describes changes in operator terms, not function names' {
        $text = Get-WhatsNewText
        $text | Should -Match 'على الهواء'
        $text | Should -Not -Match 'Get-|Invoke-|\$script:'
    }

    It 'keeps the newest release first' {
        $text = Get-WhatsNewText
        # Anchored on the section marker: the header also carries the running version.
        $text.IndexOf('▪️ 5.1.0') | Should -BeLessThan $text.IndexOf('▪️ 5.0.0')
    }

    It 'is reachable from the menu and as a command' {
        $flat = @((Get-MainMenuKeyboard -ChatId 101 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $flat | Should -Contain 'menu:whatsnew'
        @($script:BotCommandList | ForEach-Object { $_.command }) | Should -Contain 'whatsnew'
    }

    It 'tells an operator about the freshness warning they will actually see' {
        Mock Test-Admin { $false }
        Get-HelpText -ChatId 200 -UserId 200 | Should -Match 'آخر مرة'
    }

    It 'shows administrators the tools screen and the self-test, and operators neither' {
        Mock Test-Admin { $true }
        $admin = Get-HelpText -ChatId 100 -UserId 100
        $admin | Should -Match 'أدوات الإدارة'
        $admin | Should -Match 'فحص المسار الحي'

        Mock Test-Admin { $false }
        $operator = Get-HelpText -ChatId 200 -UserId 200
        $operator | Should -Not -Match 'أدوات الإدارة'
        $operator | Should -Not -Match 'الأمر الخام'
    }

    It 'fits Telegram message limits without relying on chunking' {
        Mock Test-Admin { $true }
        # The full guide is every chapter end to end and outgrew one message,
        # so its button pages it; the screen an operator actually opens is a
        # chapter, and Bridge.Help.Tests keeps those inside the limit.
        # The release notes now lead with the newest versions and put the rest
        # behind 📄 المزيد, so it is the first screen that must fit, not the
        # whole history - which grows with every release and eventually would
        # not.
        @(Get-WhatsNewParts)[0].Length | Should -BeLessThan 4096
    }

    It 'leads with the newest three versions and holds the rest back' {
        $parts = @(Get-WhatsNewParts)

        $parts.Count | Should -Be 2
        $parts[0] | Should -Match ([regex]::Escape($script:BridgeVersion))
        # The oldest summary belongs to the part nobody has to read.
        $parts[0] | Should -Not -Match '4\.x'
        $parts[1] | Should -Match '4\.x'
    }

    It 'says nothing rather than throwing when there is nothing to say' {
        # Found in the pre-release audit: an empty body made Split-TelegramText
        # return no chunks, and indexing an empty array throws under
        # StrictMode before Telegram ever gets a chance to reject it.
        Mock Send-TelegramMessage { }

        { Send-TelegramPagedText -ChatId 100 -Text '' } | Should -Not -Throw
        { Send-TelegramPagedText -ChatId 100 -Parts @('', '') } | Should -Not -Throw
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'routes the promote and demote callbacks to the right user id' {
        Get-CallbackArg 'usr:promote:122238225' 'usr:promote:' | Should -Be '122238225'
        Get-CallbackArg 'usr:demote:7275359265' 'usr:demote:' | Should -Be '7275359265'
    }

    It 'sends everything in one message when it already fits' {
        Mock Send-TelegramMessage { }
        Send-TelegramPagedText -ChatId 100 -Text 'قصير'

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { -not $ReplyMarkup }
    }

    It 'offers المزيد for the rest, and the caller keyboard with the last part' {
        Mock Send-TelegramMessage { }
        Send-TelegramPagedText -ChatId 100 -Parts @('الجزء الأول', 'الجزء الثاني') -ReplyMarkup @{ inline_keyboard = @() }

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter {
            $Text -eq 'الجزء الأول' -and ($ReplyMarkup.inline_keyboard[0][0].callback_data -eq 'more:next')
        }

        Send-TelegramPagedChunk -ChatId 100 | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -eq 'الجزء الثاني' }
        # Exhausted: a second tap has nothing left to give.
        Send-TelegramPagedChunk -ChatId 100 | Should -BeFalse
    }
}

Describe 'Usage digest' {
    It 'ranks the busiest templates first' {
        $script:UsageCounts = @{ 'ticker' = 3; 'lower-third' = 11; 'bug' = 7 }
        $script:TemplateLastUsed = @{}
        $text = ConvertFrom-TelegramHtmlText (Get-UsageDigestText)
        $text.IndexOf('lower-third') | Should -BeLessThan $text.IndexOf('bug')
        $text.IndexOf('bug') | Should -BeLessThan $text.IndexOf('ticker')
    }

    It 'says plainly when nothing has been used yet' {
        $script:UsageCounts = @{}
        ConvertFrom-TelegramHtmlText (Get-UsageDigestText) | Should -Match 'لم تُستخدم'
    }

    It 'reports failures and refusals, and points at the audit log' {
        $script:UsageCounts = @{ 'ticker' = 1 }
        $script:AirOperationCounters = @{ Success = 10; Failed = 2; Blocked = 1 }
        $text = ConvertFrom-TelegramHtmlText (Get-UsageDigestText)
        # The outcome breakdown is one line per outcome now, quoted under
        # the two figures the screen is opened for.
        $text | Should -Match 'فاشلة — 2'
        $text | Should -Match 'مرفوضة — 1'
        $text | Should -Match 'السجل'
    }

    It 'stays quiet about the audit log when nothing went wrong' {
        $script:UsageCounts = @{ 'ticker' = 1 }
        $script:AirOperationCounters = @{ Success = 4; Failed = 0; Blocked = 0 }
        ConvertFrom-TelegramHtmlText (Get-UsageDigestText) | Should -Not -Match 'راجع 📜'
    }
}

Describe 'Administrator restart' {
    BeforeEach {
        $script:RestartRequested = $false
        $script:OnAir = @{}
        Mock Test-Admin { $true }
        Mock Send-TelegramMessage {}
        Mock Add-AuditEntry {}
        Mock Write-BridgeLog {}
        Mock Get-AdminToolsKeyboard { @{ inline_keyboard = @() } }
        Mock Get-Setting { $true } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }
        Mock Get-BridgeSupervisor { [pscustomobject]@{ Name = 'nssm.exe'; Supervised = $true } }
    }
    AfterAll { $script:RestartRequested = $false }

    It 'only identifies processes running this exact bridge script' {
        $scriptPath = [IO.Path]::GetFullPath($script:BridgeLaunch.ScriptPath)
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ ProcessId = 4101; CreationDate = 'now'; CommandLine = "pwsh -File `"$scriptPath`" -ConfigPath config.json" }
                [pscustomobject]@{ ProcessId = 4102; CreationDate = 'now'; CommandLine = 'pwsh -File C:\OtherStation\TelegramBridge.ps1 -ConfigPath config.json' }
            )
        }

        $processMatches = @(Get-OtherBridgeProcess)
        @($processMatches).Count | Should -Be 1
        $processMatches[0].ProcessId | Should -Be 4101
    }

    It 'refuses while the setting is off, whatever supervises the process' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }

        Request-BridgeRestart -ChatId 100 -UserId 100 | Should -BeFalse
        $script:RestartRequested | Should -BeFalse
    }

    It 'refuses when nothing would bring the bridge back' {
        # Exiting unsupervised with no way to relaunch is not a restart, it is
        # an outage with no way back in through the bot that just stopped.
        Mock Get-BridgeSupervisor { [pscustomobject]@{ Name = 'explorer.exe'; Supervised = $false } }
        Mock Get-BridgeRelaunchCommand { $null }

        Request-BridgeRestart -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'explorer.exe' }
    }

    It 'restarts itself when started from a terminal, rather than refusing' {
        # How this is actually run during a shift: by hand from the VS Code
        # console, where no service exists to bring it back. Refusing there
        # left the only restart route as walking over to the playout machine.
        Mock Get-BridgeSupervisor { [pscustomobject]@{ Name = 'pwsh.exe'; Supervised = $false } }
        Mock Get-BridgeRelaunchCommand { [pscustomobject]@{ FilePath = 'pwsh.exe'; Arguments = @(); WorkingDirectory = '.' } }

        Request-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'الجسر نفسه' }
    }

    It 'leaves the relaunch to the supervisor when there is one' {
        # Two bridges long-polling one bot token means button presses vanish
        # into whichever instance happened to receive them.
        Confirm-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue

        $script:RestartRequested | Should -BeTrue
        $script:RestartSelfRelaunch | Should -BeFalse
    }

    It 'takes the relaunch on itself when nothing else will' {
        Mock Get-BridgeSupervisor { [pscustomobject]@{ Name = 'pwsh.exe'; Supervised = $false } }

        Confirm-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue

        $script:RestartSelfRelaunch | Should -BeTrue
    }

    It 'quotes a launch path that contains a space' {
        # Start-Process -ArgumentList joins with spaces and quotes nothing, so
        # an unquoted "D:\cingy cg\..." reaches the replacement as
        # "-File D:\cingy" and the restart dies before it starts.
        $script:BridgeLaunch = @{
            ScriptPath             = $PSCommandPath
            ConfigPath             = 'D:\cingy cg\config.json'
            RuntimePath            = ''
            AllowMultipleInstances = $false
            RequireSingleInstance  = $true
            WorkingDirectory       = 'D:\cingy cg'
        }

        $command = Get-BridgeRelaunchCommand

        $command | Should -Not -BeNullOrEmpty
        $command.Arguments | Should -Contain '"D:\cingy cg\config.json"'
        $command.Arguments | Should -Contain '-RequireSingleInstance'
    }

    It 'asks before restarting rather than acting on the first tap' {
        Request-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue
        $script:RestartRequested | Should -BeFalse
    }

    It 'warns that scenes are on air when confirming' {
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date); UserId = 42; Source = 'bridge' }

        Request-BridgeRestart -ChatId 100 -UserId 100 | Out-Null

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'على الهواء' }
    }

    It 'signals the loop rather than killing the process from a callback' {
        # The finally block stops the relay, saves counters and releases the
        # single-instance mutex; exiting here would skip all of it and the
        # replacement would find the mutex still held.
        Confirm-BridgeRestart -ChatId 100 -UserId 100 | Should -BeTrue
        $script:RestartRequested | Should -BeTrue
    }

    It 'ignores a confirmation from a non-administrator' {
        Mock Test-Admin { $false }

        Confirm-BridgeRestart -ChatId 200 -UserId 200 | Should -BeFalse
        $script:RestartRequested | Should -BeFalse
    }

    It 'hides the button entirely while the setting is off' {
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'AllowRemoteRestart' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableLiveRelay' }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'EnableRawCommand' }

        $flat = @((Get-AdminToolsKeyboard -ChatId 100 -UserId 100).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $flat | Should -Not -Contain 'menu:restart'
    }
}

Describe 'Operational numbers and status sharing' {
    BeforeEach {
        $script:OnAir = @{}
        $script:BridgeStartedAt = (Get-Date).AddHours(-26)
        $script:TelegramRateLimitHits = 7
        $script:AirOperationCounters = @{ Success = 12; Failed = 1; Blocked = 2 }
    }
    AfterAll { $script:OnAir = @{} }

    It 'reports uptime, which is what tells an administrator it has been restarting' {
        $text = ConvertFrom-TelegramHtmlText (Get-BridgeStatsText)
        # Columns are aligned in a <pre> table now, so label and value are
        # separated by padding rather than a colon.
        $text | Should -Match 'مدة التشغيل — 1 ي'
        $text | Should -Match ([regex]::Escape($script:BridgeVersion))
    }

    It 'separates flood limits from ordinary failures' {
        ConvertFrom-TelegramHtmlText (Get-BridgeStatsText) | Should -Match '\(429\) — 7'
    }

    It 'counts every air operation outcome' {
        $text = ConvertFrom-TelegramHtmlText (Get-BridgeStatsText)
        $text | Should -Match 'عمليات الهواء — 15'
    }

    It 'shares a plain summary that survives being pasted elsewhere' {
        $script:OnAir[3] = @{ Key = 'lower-third'; At = (Get-Date).AddMinutes(-4); UserId = 42; Source = 'bridge' }
        $text = Get-OnAirShareText
        $text | Should -Match 'طبقة 3: lower-third'
        $text | Should -Match 'منذ'
        # No inline-keyboard chrome, no callback data - it is meant to be copied.
        $text | Should -Not -Match 'callback_data'
    }

    It 'says plainly when nothing is on air rather than sharing an empty list' {
        Get-OnAirShareText | Should -Match 'لا شيء على الهواء'
    }
}

Describe 'Cancel reasons' {
    BeforeEach {
        $script:CancelReasons = @{}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Save-CancelReasons { $true }
    }
    AfterAll { $script:CancelReasons = @{} }

    It 'counts each reason separately' {
        Add-CancelReason -Reason 'template' -UserId 42 -Key 'alpha'
        Add-CancelReason -Reason 'template' -UserId 42 -Key 'beta'
        Add-CancelReason -Reason 'timing' -UserId 42 -Key 'alpha'

        $script:CancelReasons['template'] | Should -Be 2
        $script:CancelReasons['timing'] | Should -Be 1
    }

    It 'stores counts only, never field text or user ids' {
        # It must not become a second audit log.
        Add-CancelReason -Reason 'director' -UserId 7275359265 -Key 'الانتخابات'
        ($script:CancelReasons.Values | ForEach-Object { $_ }) | ForEach-Object { $_ | Should -BeOfType [int] }
        ($script:CancelReasons.Keys -join ' ') | Should -Not -Match '7275359265'
    }

    It 'labels every reason in Arabic for the digest' {
        foreach ($code in @('template', 'timing', 'director', 'other')) {
            Get-CancelReasonLabel -Reason $code | Should -Not -Be $code
        }
    }

    It 'offers a skip, because an unexplained undo is still a valid undo' {
        $flat = @((Get-CancelReasonKeyboard).inline_keyboard | ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $flat | Should -Contain 'menu'
        $flat | Should -Contain 'cancelreason:template'
    }

    It 'reports the breakdown in the usage digest' {
        $script:UsageCounts = @{ 'alpha' = 1 }
        $script:AirOperationCounters = @{ Success = 1; Failed = 0; Blocked = 0 }
        $script:CancelReasons = @{ 'template' = 3 }

        ConvertFrom-TelegramHtmlText (Get-UsageDigestText) | Should -Match 'قالب خاطئ — 3'
    }
}

Describe 'Missed events and template history' {
    BeforeEach {
        $script:OnAir = @{}
        $script:auditFile = Join-Path $TestDrive "audit-$([guid]::NewGuid().ToString('N')).jsonl"
        $recent = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
        $old = (Get-Date).ToUniversalTime().AddDays(-3).ToString('o')
        Set-Content -LiteralPath $script:auditFile -Encoding utf8 -Value @(
            (@{ timestampUtc = $recent; action = 'SHOW'; result = 'success'; userId = 42; layer = 3; target = 'الانتخابات'; message = '' } | ConvertTo-Json -Compress)
            (@{ timestampUtc = $recent; action = 'HIDE'; result = 'success'; userId = 42; layer = 3; target = ''; message = '' } | ConvertTo-Json -Compress)
            (@{ timestampUtc = $recent; action = 'SHOW'; result = 'failed'; userId = 42; layer = 4; target = 'الطقس'; message = 'engine refused' } | ConvertTo-Json -Compress)
            (@{ timestampUtc = $old; action = 'SHOW'; result = 'success'; userId = 99; layer = 3; target = 'قديم-جدًا'; message = '' } | ConvertTo-Json -Compress)
        )
        Mock Get-UserDisplayName { 'أحمد' }
    }
    AfterAll { $script:OnAir = @{} }

    It 'summarises what happened while nobody was looking' {
        # The digest is HTML now; read it the way the operator sees it.
        $text = ConvertFrom-TelegramHtmlText (Get-MissedEventsText -Hours 12)
        # Grouped by graphic, not by verb: which template moved is the
        # question at a handover, and who moved it.
        $text | Should -Match 'الانتخابات'
        $text | Should -Match 'أحمد'
        $text | Should -Match 'إخفاء وخروج: 1'
    }

    It 'calls out failures, which is the part worth reading' {
        # The digest is HTML now; read it the way the operator sees it.
        $text = ConvertFrom-TelegramHtmlText (Get-MissedEventsText -Hours 12)
        $text | Should -Match 'فشل: 1'
        $text | Should -Match 'engine refused'
    }

    It 'ignores anything outside the window' {
        # The three-day-old entry names a template the recent ones do not.
        (ConvertFrom-TelegramHtmlText (Get-MissedEventsText -Hours 12)) | Should -Not -Match 'قديم-جدًا'
    }

    It 'splits a shared graphic between the operators who ran it' {
        # The question at a handover is not "20 times" but "by whom": one busy
        # operator and four colliding on the same layer read identically
        # without the breakdown.
        $recent = (Get-Date).ToUniversalTime().AddMinutes(-20).ToString('o')
        $rows = foreach ($n in 1..2) {
            @{ timestampUtc = $recent; action = 'SHOW'; result = 'success'; userId = 42; layer = 3; target = 'عاجل'; message = '' } | ConvertTo-Json -Compress
        }
        $rows += foreach ($n in 1..3) {
            @{ timestampUtc = $recent; action = 'SHOW'; result = 'success'; userId = 77; layer = 3; target = 'عاجل'; message = '' } | ConvertTo-Json -Compress
        }
        Add-Content -LiteralPath $script:auditFile -Encoding utf8 -Value $rows
        Mock Get-UserDisplayName { if ($UserId -eq 77) { 'محمد' } else { 'أحمد' } }

        # The digest is HTML now; read it the way the operator sees it.
        $text = ConvertFrom-TelegramHtmlText (Get-MissedEventsText -Hours 12)

        $text | Should -Match 'محمد 3'
        $text | Should -Match 'أحمد 2'
        $text | Should -Match 'مشغّلين'
    }

    It 'names one operator inline rather than tallying a single person' {
        # The digest is HTML now; read it the way the operator sees it.
        $text = ConvertFrom-TelegramHtmlText (Get-MissedEventsText -Hours 12)

        $text | Should -Match 'الانتخابات .* أحمد'
        $text | Should -Not -Match 'أحمد 1'
    }

    It 'reports the total number of shows, not just the top graphics' {
        (ConvertFrom-TelegramHtmlText (Get-MissedEventsText -Hours 12)) | Should -Match 'ما عُرض — 2 عرضًا'
    }

    It 'passes activity notes through verbatim rather than counting them' {
        # The old digest bucketed every message-only record as "other", which
        # was both the largest number on screen and the least informative.
        Add-Content -LiteralPath $script:auditFile -Encoding utf8 -Value (
            @{ timestampUtc = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
                event        = 'activity'; message = '📰 نشر شريط الأخبار بواسطة أحمد: 39 خبرًا'
            } | ConvertTo-Json -Compress)

        ConvertFrom-TelegramHtmlText (Get-MissedEventsText -Hours 12) | Should -Match '39 خبرًا'
    }
    It 'says so plainly when nothing happened' {
        Set-Content -LiteralPath $script:auditFile -Value '' -Encoding utf8
        ConvertFrom-TelegramHtmlText (Get-MissedEventsText -Hours 12) | Should -Match 'لا شيء مسجّل'
    }

    It 'escapes a template name and sends the digest as HTML' {
        # The digest carries template names, operator names and free-text audit
        # messages - a single '<' in any of them would cost the whole screen a
        # 400, which reads on the phone as the button doing nothing.
        Mock Get-MissedEventsRecords {
            @([pscustomobject]@{ Action = 'SHOW'; Target = '<b>عاجل'; UserId = 7; When = (Get-Date); Result = 'ok'; Message = '' })
        }

        $raw = Get-MissedEventsText -Hours 12
        $raw | Should -Match '&lt;b&gt;عاجل'
        $raw | Should -Match '<blockquote>'
        ConvertFrom-TelegramHtmlText $raw | Should -Match '<b>عاجل'
    }

    It 'answers who used a template, across the whole retained history' {
        $text = Get-TemplateHistoryText -Query 'الانتخابات'
        $text | Should -Match 'أحمد'
        $text | Should -Match 'SHOW'
    }

    It 'reports honestly when a template has no recorded use' {
        Get-TemplateHistoryText -Query 'لا-يوجد' | Should -Match 'لا يوجد سجل'
    }

    It 'asks for a name instead of dumping everything' {
        Get-TemplateHistoryText -Query '   ' | Should -Match 'اكتب اسم القالب'
    }
}

Describe 'The audit trail is archived, never dropped' {
    BeforeAll { $script:OriginalAuditFile = $script:auditFile }
    # Restored, because $script: here is the same scope the loaded bridge uses:
    # leaving it pointed at a TestDrive path silently broke every later suite
    # that reads the audit trail.
    AfterAll { $script:auditFile = $script:OriginalAuditFile }

    BeforeEach {
        Mock Write-BridgeLog {}
        # A directory per test, so one test's archives are never another's.
        $script:auditFile = Join-Path (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName 'audit.jsonl'
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'AuditMaxSizeMB' }
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'AuditArchiveKeepFiles' }
    }
    AfterEach { $script:auditFile = $script:OriginalAuditFile }

    It 'leaves the file alone below the limit, and when rotation is off' {
        Set-Content -LiteralPath $script:auditFile -Value '{"message":"صغير"}' -Encoding utf8

        Invoke-AuditRotation | Should -BeFalse
        Test-Path -LiteralPath $script:auditFile | Should -BeTrue
    }

    It 'archives past the limit instead of deleting anything' {
        # bridge.log drops its oldest generation, which is right for a
        # diagnostic log and wrong for the record of who put what on air.
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'AuditMaxSizeMB' }
        Set-Content -LiteralPath $script:auditFile -Value ('x' * 1200000) -Encoding utf8

        Invoke-AuditRotation | Should -BeTrue

        Test-Path -LiteralPath $script:auditFile | Should -BeFalse
        @(Get-AuditArchiveFiles) | Should -HaveCount 1
    }

    It 'still finds the history through the archive after a rotation' {
        # The first digest after a rotation must not report an empty morning.
        $dir = Split-Path -Parent $script:auditFile
        $old = '{"timestampUtc":"' + (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o') + '","message":"حدث قديم"}'
        Set-Content -LiteralPath (Join-Path $dir 'audit-20260101-000000.jsonl') -Value $old -Encoding utf8
        $new = '{"timestampUtc":"' + (Get-Date).ToUniversalTime().ToString('o') + '","message":"حدث جديد"}'
        Set-Content -LiteralPath $script:auditFile -Value $new -Encoding utf8

        $records = @(Read-AuditRecords -MaxLines 500)

        @($records | ForEach-Object { $_.message }) | Should -Contain 'حدث قديم'
        @($records | ForEach-Object { $_.message }) | Should -Contain 'حدث جديد'
    }

    It 'prunes only when explicitly told to keep a fixed number' {
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'AuditMaxSizeMB' }
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'AuditArchiveKeepFiles' }
        $dir = Split-Path -Parent $script:auditFile
        Set-Content -LiteralPath (Join-Path $dir 'audit-20260101-000000.jsonl') -Value 'قديم' -Encoding utf8
        Set-Content -LiteralPath $script:auditFile -Value ('x' * 1200000) -Encoding utf8

        Invoke-AuditRotation | Should -BeTrue

        @(Get-AuditArchiveFiles) | Should -HaveCount 1
    }
}

Describe 'Version 6 administrator health center' {
    BeforeEach {
        $script:RuntimeState = New-BridgeRuntimeState
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'connected'
        $script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
        $script:OutputMonitorFailureCount = 0
        $script:OutputMonitorFailureAlerted = $false
        $script:OutputBlackAlerted = $false
        $script:ScheduleEvents = @()
    }

    It 'summarizes every operational component without running a new probe' {
        $snapshot = [pscustomobject]@{ DiskFreeGB = 10; RuntimeStorageBytes = 0L; BackupStorageBytes = 0L }

        # The health centre is HTML now; read it as the operator sees it.
        $text = ConvertFrom-TelegramHtmlText (Get-BridgeHealthCenterText -DiagnosticsSnapshot $snapshot -Warnings @())

        # Each row now carries an identity glyph beside its state colour: a
        # column of seven 🟢 says nothing about which row is which.
        # A three-column table row: state, identity, name.
        $text | Should -Match '🟢\s+📡\s+Telegram'
        $text | Should -Match '🟢\s+🎛\s+Cinegy'
        $text | Should -Match 'مراقبة المخرج'
        $text | Should -Match 'البث المرحّل'
        $text | Should -Match 'التخزين'
        $text | Should -Match 'الجدولة'
    }

    It 'marks disconnected Telegram and unhealthy Cinegy as red' {
        $script:RuntimeState.Monitoring.TelegramConnectionState = 'disconnected'
        $script:RuntimeState.Monitoring.CinegyHealthState = 'unhealthy'
        $snapshot = [pscustomobject]@{ DiskFreeGB = 10; RuntimeStorageBytes = 0L; BackupStorageBytes = 0L }

        # The health centre is HTML now; read it as the operator sees it.
        $text = ConvertFrom-TelegramHtmlText (Get-BridgeHealthCenterText -DiagnosticsSnapshot $snapshot -Warnings @())

        $text | Should -Match '🔴\s+📡\s+Telegram'
        $text | Should -Match '🔴\s+🎛\s+Cinegy'
    }

    It 'offers refresh full status diagnostics and return controls' {
        $callbacks = @((Get-HealthCenterKeyboard).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)

        $callbacks | Should -Contain 'menu:healthcenter'
        $callbacks | Should -Contain 'menu:fullstatus'
        $callbacks | Should -Contain 'menu:diagnostics'
        $callbacks | Should -Contain 'menu:admintools'
    }

    Context 'administrator navigation' {
        BeforeEach {
            Mock Confirm-TelegramCallback {}
            Mock Test-TelegramPrivateChat { $true }
            Mock Test-Authorized { $true }
            Mock Update-UserLastActivity {}
            Mock Invoke-HealthCenterCommand {}
        }

        It 'shows the health center in administrator tools' {
            Mock Get-RunningRelayProcess { $null }
            $callbacks = @((Get-AdminToolsKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)

            $callbacks | Should -Contain 'menu:healthcenter'
        }

        It 'routes the health center callback only after the admin guard succeeds' {
            Mock Test-CallbackAdmin { $true }
            $callback = [pscustomobject]@{
                id = 'health-center-admin'
                from = [pscustomobject]@{ id = 101 }
                message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100; type = 'private' } }
                data = 'menu:healthcenter'
            }

            Invoke-CallbackQuery -CallbackQuery $callback

            Should -Invoke Invoke-HealthCenterCommand -Times 1 -Exactly -ParameterFilter { $ChatId -eq 100 -and $UserId -eq 101 }
        }

        It 'rejects a forged health center callback from an operator' {
            Mock Test-CallbackAdmin { $false }
            $callback = [pscustomobject]@{
                id = 'health-center-operator'
                from = [pscustomobject]@{ id = 101 }
                message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100; type = 'private' } }
                data = 'menu:healthcenter'
            }

            Invoke-CallbackQuery -CallbackQuery $callback

            Should -Invoke Invoke-HealthCenterCommand -Times 0 -Exactly
        }
    }
}

Describe 'Version 6 bounded administrator catalogues' {
    It 'keeps one thousand templates below the Telegram button limit with absolute indexes' {
        $map = @{}
        $order = @(0..999 | ForEach-Object {
                $key = 'template-{0:d4}' -f $_
                $map[$key] = [pscustomobject]@{ Key = $key; Layer = ($_ % 20) + 1 }
                $key
            })
        Mock Get-TemplateStore { [pscustomobject]@{ Map = $map; Order = $order; Errors = @() } }

        $keyboard = Get-TemplateAdminCatalogueKeyboard -Page 1 -PageSize 20
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        $callbacks = @($buttons.callback_data)

        $buttons.Count | Should -BeLessThan 100
        $callbacks | Should -Contain 'tadm:20'
        $callbacks | Should -Contain 'tadmpage:0'
        $callbacks | Should -Contain 'tadmpage:2'
    }

    It 'keeps two hundred and fifty users bounded with absolute user ids' {
        $users = @(0..249 | ForEach-Object {
                [pscustomobject]@{ UserId = 1000 + $_; Alias = "User $_"; Role = 'operator'; Disabled = $false; LastActivityAt = $null }
            })
        Mock Get-AuthorizedUsers { $users }
        Mock Test-Owner { $false }

        $keyboard = Get-UsersAdminKeyboard -ViewerUserId 9999 -Page 1 -PageSize 10
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        $callbacks = @($buttons.callback_data)

        # One row per person now, so ten people are ten rows and not fifty:
        # ten names, three pager buttons and the way back.
        $buttons.Count | Should -BeLessOrEqual 14
        $callbacks | Should -Contain 'usr:card:1010:1'
        $callbacks | Should -Contain 'userspage:0'
        $callbacks | Should -Contain 'userspage:2'
        # And the actions live on that person's card, where a press cannot
        # land on somebody else.
        @((Get-UserCardKeyboard -TargetUserId 1010 -ViewerUserId 9999 -Page 1).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) |
            Should -Contain 'usr:toggle:1010'
    }

    It 'keeps two hundred pending access requests bounded and sorted by id' {
        $script:PendingApprovals = @{}
        200..1 | ForEach-Object { $script:PendingApprovals[[long]$_] = @{ Name = "Request $_" } }

        $keyboard = Get-PendingKeyboard -Page 1 -PageSize 20
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { @($_) })
        $callbacks = @($buttons.callback_data)

        $buttons.Count | Should -BeLessThan 100
        $callbacks | Should -Contain 'approve:21'
        $callbacks | Should -Contain 'pendingpage:0'
        $callbacks | Should -Contain 'pendingpage:2'
    }

    Context 'page callback routing' {
        BeforeEach {
            Mock Confirm-TelegramCallback {}
            Mock Test-TelegramPrivateChat { $true }
            Mock Test-Authorized { $true }
            Mock Update-UserLastActivity {}
            Mock Test-CallbackAdmin { $true }
            Mock Test-CallbackTemplateReminderManager { $true }
            Mock Send-TelegramMessage {}
            Mock Show-UsersAdminScreen {}
            Mock Get-TemplateAdminCatalogueKeyboard { @{ inline_keyboard = @() } }
            Mock Get-PendingKeyboard { @{ inline_keyboard = @() } }
        }

        It 'routes template user and pending page callbacks to their absolute page' {
            foreach ($case in @(
                    @{ Data = 'tadmpage:4'; Id = 'template-page' }
                    @{ Data = 'userspage:3'; Id = 'users-page' }
                    @{ Data = 'pendingpage:2'; Id = 'pending-page' }
                )) {
                $callback = [pscustomobject]@{
                    id = $case.Id
                    from = [pscustomobject]@{ id = 101 }
                    message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 100; type = 'private' } }
                    data = $case.Data
                }
                Invoke-CallbackQuery -CallbackQuery $callback
            }

            Should -Invoke Get-TemplateAdminCatalogueKeyboard -Times 1 -Exactly -ParameterFilter { $Page -eq 4 }
            Should -Invoke Show-UsersAdminScreen -Times 1 -Exactly -ParameterFilter { $Page -eq 3 }
            Should -Invoke Get-PendingKeyboard -Times 1 -Exactly -ParameterFilter { $Page -eq 2 }
        }
    }
}

Describe 'Operation reference lookup' {
    BeforeAll {
        $script:RefLog = Join-Path $TestDrive 'ref-bridge.log'
        @(
            '2026-08-31 21:40:01 [WARN] AIR_OP id=air-5023333b032c476eb48204ca08032a98 action=SHOW result=blocked user=10 layer=7'
            '2026-08-31 21:40:02 [INFO] Some unrelated line mentioning 5023333b in passing'
            '2026-08-31 21:41:00 [INFO] AIR_OP id=air-8a07c90f7f7145fc9222a681f8c58699 action=HIDE result=ok user=10 layer=4'
        ) | Set-Content -LiteralPath $script:RefLog -Encoding utf8
    }

    It 'returns the operation record for a reference' {
        $lines = Find-OperationByReference -Reference '5023333b' -Path $script:RefLog

        @($lines).Count | Should -Be 1
        @($lines)[0] | Should -Match 'result=blocked'
    }

    It 'ignores a line that merely mentions the reference' {
        # This is a lookup, not a log search: only structured AIR_OP records
        # come back, or the screen becomes a way to read the least redacted
        # file the bridge writes, a keyword at a time.
        $lines = Find-OperationByReference -Reference '5023333b' -Path $script:RefLog

        @($lines | Where-Object { $_ -match 'unrelated' }).Count | Should -Be 0
    }

    It 'refuses anything that is not eight hex characters' {
        foreach ($bad in 'AIR_OP', 'result=ok', '502333', '5023333bb', 'zzzzzzzz', '') {
            Find-OperationByReference -Reference $bad -Path $script:RefLog | Should -BeNullOrEmpty
        }
    }

    It 'accepts the reference in either case, as it is pasted' {
        @(Find-OperationByReference -Reference '5023333B' -Path $script:RefLog).Count | Should -Be 1
    }

    It 'returns nothing rather than throwing when the log has rotated away' {
        @(Find-OperationByReference -Reference '5023333b' -Path (Join-Path $TestDrive 'gone.log')).Count | Should -Be 0
    }

    It 'offers the lookup from the diagnostics screen' {
        $callbacks = @((Get-DiagnosticsKeyboard).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] })

        $callbacks | Should -Contain 'diag:findref'
    }

    It 'refuses a non-administrator who reaches the prompt anyway' {
        Mock Test-Admin { $false }
        Mock Send-TelegramMessage { }
        Set-PendingState -ChatId 555 -State @{ Mode = 'operation_reference'; UserId = 555 }

        Complete-OperationReferenceLookup -ChatId 555 -UserId 555 -Value '5023333b'

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'للمشرف وحده' }
    }
}

Describe 'Reference lookup with exactly one hit' {
    BeforeEach {
        Mock Test-Admin { $true }
        Mock Send-TelegramPagedText { }
        Mock Send-TelegramMessage { }
    }

    It 'reports a single match instead of throwing on it' {
        # PowerShell unwraps a one-item array on return, so a lookup that hit
        # exactly one AIR_OP line came back as a [string] - and .Count on a
        # string throws under StrictMode. It reached production as
        # "Unhandled error processing message ... property 'Count' cannot be
        # found", which is the one shape a lookup is most likely to have.
        Mock Find-OperationByReference { 'AIR_OP id=air-5023333b032c476eb48204ca08032a98 action=SHOW result=blocked' }
        Set-PendingState -ChatId 777 -State @{ Mode = 'operation_reference'; UserId = 777 }

        { Complete-OperationReferenceLookup -ChatId 777 -UserId 777 -Value '5023333b' } | Should -Not -Throw

        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly -ParameterFilter { $Text -match '1 سطرًا' -and $Text -match 'result=blocked' }
    }

    It 'says the log has nothing rather than counting an empty result wrong' {
        Mock Find-OperationByReference { @() }
        Set-PendingState -ChatId 777 -State @{ Mode = 'operation_reference'; UserId = 777 }

        Complete-OperationReferenceLookup -ChatId 777 -UserId 777 -Value '5023333b'

        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly -ParameterFilter { $Text -match 'لا سجل' }
    }

    It 'tells a bad reference apart from a log that simply has no such line' {
        # One function could not report both: an empty array comes back from
        # PowerShell as $null, exactly as an absent value does, so a rotated
        # log read as a malformed reference. The shape check is its own now.
        Set-PendingState -ChatId 777 -State @{ Mode = 'operation_reference'; UserId = 777 }

        Complete-OperationReferenceLookup -ChatId 777 -UserId 777 -Value 'AIR_OP'

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'ليس مرجعًا' }
    }

    It 'accepts the shape without touching the log' {
        Test-OperationReference -Reference '5023333B' | Should -BeTrue
        Test-OperationReference -Reference 'AIR_OP' | Should -BeFalse
        Test-OperationReference -Reference '' | Should -BeFalse
    }
}

Describe 'The health screen can be read down its state column' {
    BeforeEach {
        Mock Get-BridgeUsageMetrics { @{ OperationsToday = 3; ActiveOperators = 1; OnAirCount = 0 } }
        Mock Get-UpcomingScheduleEvents { @() }
        Mock Get-BridgeDiagnosticsSnapshot { @{ DiskFreeGB = 40 } }
    }

    It 'gives every subsystem a row, with the glyph in a column of its own' {
        # Seven sentences each starting with a coloured circle is parsed one
        # line at a time; a column of them is scanned in one movement, which
        # is the whole job of this screen.
        $table = @(@(Get-BridgeHealthCenterBlocks -Warnings @()) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[0]).Count | Should -Be 3
        @($table.cells).Count | Should -Be 8
        foreach ($row in @($table.cells | Select-Object -Skip 1)) {
            @($row)[1].text | Should -BeIn @('🟢', '🟠', '🔴')
        }
    }

    It 'puts a fault above the healthy rows, not in row six' {
        $script:RuntimeState.Monitoring.CinegyHealthState = 'unhealthy'
        try {
            $table = @(@(Get-BridgeHealthCenterBlocks -Warnings @()) | Where-Object { $_.type -eq 'table' })[0]
            $first = @($table.cells)[1]

            @($first)[0].text | Should -Be 'Cinegy'
            @($first)[1].text | Should -Be '🔴'
        }
        finally { $script:RuntimeState.Monitoring.CinegyHealthState = 'unknown' }
    }

    It 'builds the lines from the same rows, so the two screens cannot disagree' {
        $rows = @(Get-BridgeHealthRows -DiagnosticsSnapshot @{ DiskFreeGB = 40 } -Warnings @())
        # The health centre is HTML now; read it as the operator sees it.
        $text = ConvertFrom-TelegramHtmlText (Get-BridgeHealthCenterText -DiagnosticsSnapshot @{ DiskFreeGB = 40 } -Warnings @())

        foreach ($row in $rows) {
            # Icon, identity glyph, name, detail - the shape the screen renders
            # every row in, so the two still cannot drift apart.
            # The exact shape the screen renders every row in, so the two
            # still cannot drift apart: state, identity, name — detail.
            $text | Should -Match ([regex]::Escape("$($row.Icon) $($row.Glyph) $($row.Name) — $($row.Detail)"))
        }
    }
}

Describe 'The status screens lead with the verdict and table what is on air' {
    BeforeEach {
        Mock Get-AuditOperatorName { 'سامي' }
        $script:OnAir.Clear()
    }
    AfterEach { $script:OnAir.Clear() }

    It 'says the screen is empty rather than drawing a table of nothing' {
        $blocks = @(Get-OnAirTableBlocks)

        @($blocks | Where-Object { $_.type -eq 'table' }).Count | Should -Be 0
        $blocks[0].text | Should -Match 'لا شيء على الهواء'
    }

    It 'gives each live layer a row, four columns wide like every other table' {
        $script:OnAir[7] = @{ Key = 'urgent'; At = (Get-Date).AddMinutes(-5); UserId = 10 }
        $script:OnAir[8] = @{ Key = 'ticker'; At = (Get-Date).AddSeconds(-2); UserId = 10 }

        $table = @(@(Get-OnAirTableBlocks) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells).Count | Should -Be 3
        @($table.cells[0]).Count | Should -Be 4
        @($table.cells[1])[1].text | Should -Be 'urgent'
        # A layer that went up two seconds ago reads better than "منذ 0 ثانية".
        @($table.cells[2])[2].text | Should -Be 'الآن'
    }

    It 'puts the verdict above everything and folds the machine detail' {
        $blocks = @(Get-StatusRichBlocks -Title 'ℹ️ الحالة' -Overall '🟠 طبقات على الهواء' `
                -DetailLines @('🌐 127.0.0.1', '', '📶 حالة بيانات Cinegy: حديثة'))

        $blocks[0].type | Should -Be 'heading'
        $blocks[1].text | Should -Be '🟠 طبقات على الهواء'
        $folded = @($blocks | Where-Object { $_.type -eq 'details' })[0]
        # A blank separator is a text-screen device; as a block it renders as
        # a gap that looks like something failed to load.
        @($folded.blocks).Count | Should -Be 2
    }

    It 'folds nothing when there is no detail to fold' {
        $blocks = @(Get-StatusRichBlocks -Title 'ℹ️ الحالة' -Overall '🟢 كل شيء سليم' -DetailLines @())

        @($blocks | Where-Object { $_.type -eq 'details' }).Count | Should -Be 0
    }

    It 'shows the identity above the fold, not inside the collapsed detail' {
        # The id is what an operator is asked for when requesting access or
        # reporting a fault; behind a disclosure triangle it gets screenshotted
        # wrongly or not at all.
        $identity = '👤 معرّفك: 8201739556'
        $blocks = @(Get-StatusRichBlocks -Title 'ℹ️ الحالة' -Overall '🟢 كل شيء سليم' `
                -Identity $identity -DetailLines @('🌐 127.0.0.1'))

        $blocks[2].text | Should -Be $identity
        $folded = @($blocks | Where-Object { $_.type -eq 'details' })[0]
        @($folded.blocks | Where-Object { $_.text -eq $identity }).Count | Should -Be 0
    }

    It 'omits the identity paragraph entirely when none is supplied' {
        $blocks = @(Get-StatusRichBlocks -Title 'ℹ️ الحالة' -Overall '🟢 كل شيء سليم' -DetailLines @())

        $blocks[2].type | Should -Be 'divider'
    }
}

Describe 'A log line is shown in the font it was written for' {
    BeforeEach {
        Mock Test-Admin { $true }
        Mock Send-TelegramPagedText { }
        Mock Send-TelegramMessage { }
    }

    It 'sends the matching lines as preformatted, so the columns stay columns' {
        # id=, action= and result= are held in place by spaces; a proportional
        # font stops them lining up between rows and the eye loses the column.
        Mock Find-OperationByReference { @('AIR_OP id=air-5023333b action=SHOW result=ok', 'AIR_OP id=air-5023333b action=HIDE result=ok') }
        Mock Send-TelegramRichMessage { $true }
        Set-PendingState -ChatId 777 -State @{ Mode = 'operation_reference'; UserId = 777 }

        Complete-OperationReferenceLookup -ChatId 777 -UserId 777 -Value '5023333b'

        Should -Invoke Send-TelegramRichMessage -Times 1 -Exactly -ParameterFilter {
            @($Blocks | Where-Object { $_.type -eq 'pre' }).Count -eq 1
        }
        Should -Invoke Send-TelegramPagedText -Times 0 -Exactly
    }

    It 'falls back to the text version when rich sending is refused' {
        Mock Find-OperationByReference { @('AIR_OP id=air-5023333b action=SHOW result=ok') }
        Mock Send-TelegramRichMessage { $false }
        Set-PendingState -ChatId 777 -State @{ Mode = 'operation_reference'; UserId = 777 }

        Complete-OperationReferenceLookup -ChatId 777 -UserId 777 -Value '5023333b'

        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly
    }

    It 'does not draw an empty code block when the log has no such line' {
        Mock Find-OperationByReference { @() }
        Mock Send-TelegramRichMessage { $true }
        Set-PendingState -ChatId 777 -State @{ Mode = 'operation_reference'; UserId = 777 }

        Complete-OperationReferenceLookup -ChatId 777 -UserId 777 -Value '5023333b'

        Should -Invoke Send-TelegramRichMessage -Times 0 -Exactly
        Should -Invoke Send-TelegramPagedText -Times 1 -Exactly
    }
}

Describe 'The pending access requests screen' {
    BeforeEach { $script:PendingApprovals.Clear() }
    AfterAll { $script:PendingApprovals.Clear() }

    It 'shows who is asking, from which id, and since when' {
        $script:PendingApprovals[555001] = @{ Name = 'مشغّل جديد'; ChatId = 555001; UserId = 999777; RequestedAt = (Get-Date).AddMinutes(-30) }

        $text = Get-PendingApprovalsText

        $text | Should -Match 'مشغّل جديد'
        # The id is what the administrator is actually granting control to.
        $text | Should -Match '999777'
        $text | Should -Match 'منذ'
    }

    It 'escapes a name its requester chose' {
        # The only text on this screen written by a stranger.
        $script:PendingApprovals[555002] = @{ Name = '<b>مدير</b>'; ChatId = 555002; UserId = 555002; RequestedAt = (Get-Date) }

        $text = Get-PendingApprovalsText

        $text | Should -Match '&lt;b&gt;'
        $text | Should -Not -Match '<b>مدير'
    }

    It 'says there are none rather than showing an empty screen' {
        Get-PendingApprovalsText | Should -Match 'لا طلبات'
    }

    It 'colours approval and leaves the refusal plain' {
        $script:PendingApprovals[555003] = @{ Name = 'س'; ChatId = 555003; UserId = 555003; RequestedAt = (Get-Date) }
        $buttons = @((Get-PendingKeyboard).inline_keyboard | ForEach-Object { @($_) })
        $yes = @($buttons | Where-Object { [string]$_['callback_data'] -eq 'approve:555003' })[0]
        $no = @($buttons | Where-Object { [string]$_['callback_data'] -eq 'reject:555003' })[0]

        $yes['style'] | Should -Be 'success'
        $no.ContainsKey('style') | Should -BeFalse
    }
}

Describe 'The authorized users roster' {
    It 'shows the id, the role and the state for each person' {
        $text = Get-AuthorizedUsersText

        # The id is what ties a person to the log, to an operation reference
        # and to the access request that was approved.
        $text | Should -Match '<code>111111111</code>'
        $text | Should -Match 'مالك'
        $text | Should -Match 'مستخدمًا'
    }

    It 'says who has no operational name rather than printing their id twice' {
        Get-AuthorizedUsersText | Should -Match 'بلا اسم تشغيلي'
    }

    It 'escapes an alias an administrator typed' {
        Mock Get-AuthorizedUsers {
            @([pscustomobject]@{ UserId = 4242; Alias = '<b>مشرف</b>'; Role = 'operator'; Disabled = $false; AddedAt = ''; AddedByUserId = 0; LastActivityAt = '' })
        }

        $text = Get-AuthorizedUsersText

        $text | Should -Match '&lt;b&gt;'
        $text | Should -Not -Match '<b>مشرف'
    }

    It 'numbers the rows the same way the buttons are numbered' {
        Mock Get-AuthorizedUsers {
            @(
                [pscustomobject]@{ UserId = 11; Alias = 'أول'; Role = 'operator'; Disabled = $false; AddedAt = ''; AddedByUserId = 0; LastActivityAt = '' }
                [pscustomobject]@{ UserId = 22; Alias = 'ثانٍ'; Role = 'operator'; Disabled = $false; AddedAt = ''; AddedByUserId = 0; LastActivityAt = '' }
            )
        }

        Get-AuthorizedUsersText | Should -Match '2\. <b>ثانٍ</b>'
        $buttons = @((Get-UsersAdminKeyboard).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { [string]$_['text'] })
        @($buttons | Where-Object { $_ -like '2.*ثانٍ*' }).Count | Should -Be 1
    }
}

Describe 'The operations log reaches past the last ten' {
    BeforeEach {
        # Three days of a busy station: one operation every twenty minutes,
        # from two operators, with a failure every seventeenth.
        Mock Get-ReportRecords {
            $now = Get-Date
            $records = @(0..215 | ForEach-Object {
                    [pscustomobject]@{
                        When   = $now.AddMinutes(-20 * $_)
                        Action = 'SHOW'
                        Result = $(if ($_ % 17 -eq 0) { 'failed' } else { 'success' })
                        Target = "قالب رقم $_"
                        UserId = $(if ($_ % 2 -eq 0) { '101' } else { '202' })
                        Values = 'نص الخبر كما ظهر على الشاشة'
                        Count  = 0
                        Layer  = 4
                        OperationId = "air-$('{0:x32}' -f $_)"
                        DurationMs  = 120
                    }
                })
            # The caller's window is what decides which of these count.
            @{ Records = @($records | Where-Object { $_.When -ge $From -and $_.When -le $To }); Truncated = $false }
        }
        Mock Get-AuditOperatorName { if ($UserId -eq '101') { 'مشغّل الأخبار' } else { 'مخرج النشرة' } }
        Mock Test-Admin { $true }
        Mock Get-OperationSentence { "عرض «$Target»" }
    }

    It 'answers "what went out in the last 48 hours", which memory could not' {
        # The screen this extends holds twenty entries a person and forgets
        # them at a restart. This one reads audit.jsonl, so the window is the
        # only limit.
        $data = Get-OperationLogData -Hours 48
        $wider = Get-OperationLogData -Hours 72

        # 48 hours at one operation every twenty minutes is 144 of them.
        @($data.Records).Count | Should -BeGreaterThan 100
        @($wider.Records).Count | Should -BeGreaterThan @($data.Records).Count
        $data.Label | Should -Be 'آخر 48 ساعة'
        # Newest first: the screen is opened to ask what just happened.
        @($data.Records)[0].When | Should -BeGreaterThan @($data.Records)[-1].When
    }

    It 'shows one operator only their own operations' {
        $mine = Get-OperationLogData -Hours 72 -OnlyUserId 101
        @($mine.Records | Where-Object { $_.UserId -ne '101' }) | Should -BeNullOrEmpty
        $mine.Scope | Should -Be 'mine'
    }

    It 'leads with the verdict and stays inside what the bridge will send' {
        $blocks = @(Get-OperationLogBlocks -Hours 72)
        $json = (@{ blocks = $blocks; is_rtl = $true } | ConvertTo-Json -Depth 12 -Compress)

        $blocks[0].type | Should -Be 'heading'
        $blocks[1].text | Should -Match 'عملية'
        Test-RichPayloadSize -Length $json.Length | Should -BeTrue
        # Capped like every other table, and it says what it left out.
        @($blocks | Where-Object { $_.type -eq 'table' })[0].cells.Count | Should -Be 41
        $json | Should -Match 'صفًّا أقدم غير معروضة'
    }

    It 'names the operator only where the answer differs by row' {
        $everyone = @(Get-OperationLogBlocks -Hours 24)
        $mine = @(Get-OperationLogBlocks -Hours 24 -OnlyUserId 101)

        @($everyone | Where-Object { $_.type -eq 'table' })[0].cells[0].Count | Should -Be 5
        @($mine | Where-Object { $_.type -eq 'table' })[0].cells[0].Count | Should -Be 4
    }

    It 'says so plainly when the window is empty' {
        Mock Get-ReportRecords { @{ Records = @(); Truncated = $false } }
        $blocks = @(Get-OperationLogBlocks -Hours 24)
        @($blocks | Where-Object { $_.type -eq 'table' }) | Should -BeNullOrEmpty
        $blocks[1].text | Should -Match 'لم تُسجَّل أي عملية'
    }

    It 'marks the window being read and offers the other two' {
        $keyboard = Get-OperationLogKeyboard -Hours 48 -OnlyUserId 101 -ChatId 1 -UserId 1
        $labels = @(@($keyboard.inline_keyboard)[0] | ForEach-Object { $_.text })

        $labels | Should -Contain '• 48 ساعة'
        $labels | Should -Contain '24 ساعة'
        $labels | Should -Contain '72 ساعة'
        # Every row is a row, which is what one bare button once cost.
        foreach ($row in @($keyboard.inline_keyboard)) { , $row | Should -BeOfType ([System.Array]) }
    }

    It 'offers everyone-s operations to an administrator and not to an operator' {
        @(@(Get-OperationLogKeyboard -Hours 24 -OnlyUserId 5 -ChatId 5 -UserId 5).inline_keyboard |
            ForEach-Object { $_ } | Where-Object { $_.callback_data -eq 'oplog:all:24' }) | Should -HaveCount 1

        Mock Test-Admin { $false }
        @(@(Get-OperationLogKeyboard -Hours 24 -OnlyUserId 5 -ChatId 5 -UserId 5).inline_keyboard |
            ForEach-Object { $_ } | Where-Object { $_.callback_data -eq 'oplog:all:24' }) | Should -BeNullOrEmpty
    }

    It 'gives an operator their own rows even when the callback asks for everyone' {
        # The guard is in the command, not only on the button: a callback can
        # arrive without one being pressed.
        Mock Test-Admin { $false }
        Mock Send-TelegramRichMessage { $script:LoggedBlocks = $Blocks; $true }

        Invoke-OperationLogCommand -ChatId 202 -UserId 202 -Hours 24 -AllUsers

        @($script:LoggedBlocks)[0].text | Should -Match 'عملياتي'
        @($script:LoggedBlocks)[0].text | Should -Not -Match 'كل المشغّلين'
    }

    It 'falls back to the text version, totals first' {
        Mock Send-TelegramRichMessage { $false }
        Mock Send-TelegramPagedText { $script:LoggedText = $Text }

        Invoke-OperationLogCommand -ChatId 101 -UserId 101 -Hours 48

        $script:LoggedText | Should -Match '<b>الإجمالي</b>'
    }
}
