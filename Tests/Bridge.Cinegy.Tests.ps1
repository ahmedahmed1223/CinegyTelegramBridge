#requires -Version 7
<#
    Bridge.Cinegy.Tests.ps1 - Cinegy transport, telemetry, and watchdogs.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Air operation result logging' {
    BeforeEach {
        Mock Write-BridgeLog { }
        $script:auditFile = Join-Path $TestDrive 'audit.jsonl'
        Remove-Item -LiteralPath $script:auditFile -Force -ErrorAction SilentlyContinue
        $script:UserOperationHistory = @{}
        $script:LastShowAttempts = @{}
    }

    It 'writes a correlatable successful operation with duration and target' {
        Write-AirOperationResult -OperationId 'op-123' -Action SHOW -Result success -DurationMs 27 -UserId 20 -ChatId 10 -Layer 4 -Target urgent

        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
            $Message -match 'AIR_OP' -and $Message -match 'id=op-123' -and
                $Message -match 'action=SHOW' -and $Message -match 'result=success' -and
                $Message -match 'durationMs=27' -and $Message -match 'layer=4' -and
                $Message -match 'target="urgent"'
        }
    }

    It 'records the configured operator name alongside the immutable user id' {
        $previousAlias = if ($script:UserAliases.ContainsKey('20')) { [string]$script:UserAliases['20'] } else { $null }
        try {
            $script:UserAliases['20'] = 'محرر الأخبار'

            Write-AirOperationResult -OperationId 'op-user-name' -Action SHOW -Result success -DurationMs 27 -UserId 20 -ChatId 10 -Layer 4 -Target urgent

            Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
                $Message -match 'user=20' -and $Message -match 'userName="محرر الأخبار"'
            }
            $record = Get-Content -LiteralPath $script:auditFile | Select-Object -Last 1 | ConvertFrom-Json
            $record.userId | Should -Be 20
            $record.userName | Should -Be 'محرر الأخبار'
        }
        finally {
            if ($null -eq $previousAlias) { $script:UserAliases.Remove('20') | Out-Null }
            else { $script:UserAliases['20'] = $previousAlias }
        }
    }

    It 'writes failures at warning level without losing the error reason' {
        Write-AirOperationResult -OperationId 'op-456' -Action HIDE -Result blocked -DurationMs 3 -UserId 20 -ChatId 10 -Layer 4 -ErrorText 'cinegy timeout'

        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'id=op-456' -and
                $Message -match 'result=blocked' -and $Message -match 'cinegy timeout'
        }
    }

    It 'persists the same correlation id in the independent structured audit log' {
        Write-AirOperationResult -OperationId 'op-jsonl' -Action SHOW -Result success -DurationMs 31 -UserId 20 -ChatId 10 -Layer 4 -Target urgent

        $record = Get-Content -LiteralPath $script:auditFile | Select-Object -Last 1 | ConvertFrom-Json
        $record.operationId | Should -Be 'op-jsonl'
        $record.event | Should -Be 'air_control'
        $record.action | Should -Be 'SHOW'
        $record.result | Should -Be 'success'
        $record.userId | Should -Be 20
        $record.layer | Should -Be 4
    }

    It 'redacts secrets and keeps every audit entry on one JSONL line' {
        Write-AuditRecord -OperationId 'audit-secret' -EventName settings_change -Result success -UserId 20 -Message "token 123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345`nnext"

        $lines = @(Get-Content -LiteralPath $script:auditFile)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Not -Match '123456:ABC'
        ($lines[0] | ConvertFrom-Json).message | Should -Match '\*\*\*BOT_TOKEN\*\*\*'
    }
}

Describe 'Cinegy state freshness classification' {
    It 'classifies a recent successful comparison as connected' {
        $now = [datetime]'2026-08-22T12:00:00'
        (Get-CinegyStateFreshness -LastSuccessfulAt $now.AddSeconds(-10) -FailedCount 0 -Now $now -StaleAfterSeconds 45).State | Should -Be 'connected'
    }

    It 'classifies an old successful comparison as stale' {
        $now = [datetime]'2026-08-22T12:00:00'
        (Get-CinegyStateFreshness -LastSuccessfulAt $now.AddSeconds(-60) -FailedCount 0 -Now $now -StaleAfterSeconds 45).State | Should -Be 'stale'
    }

    It 'classifies a failed live comparison as unavailable' {
        $now = [datetime]'2026-08-22T12:00:00'
        (Get-CinegyStateFreshness -LastSuccessfulAt $now.AddSeconds(-10) -FailedCount 1 -Now $now -StaleAfterSeconds 45).State | Should -Be 'unavailable'
    }

    It 'classifies a never-successful comparison as unknown' {
        (Get-CinegyStateFreshness -LastSuccessfulAt $null -FailedCount 0 -Now ([datetime]'2026-08-22T12:00:00') -StaleAfterSeconds 45).State | Should -Be 'unknown'
    }
}

Describe 'CinegyAirTitler public commands' {
    It 'is not exported as a public module command' {
        Get-Command -Module CinegyAirTitler -Name ConvertTo-XmlSafeValue -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
}

InModuleScope CinegyAirTitler {
    Describe 'ConvertTo-XmlSafeValue' {
        It 'accepts an empty string' {
            # The ⏭ تخطي regression: a Mandatory [string] rejects ''.
            { ConvertTo-XmlSafeValue -Value '' } | Should -Not -Throw
            ConvertTo-XmlSafeValue -Value '' | Should -Be ''
        }

        It 'escapes XML metacharacters' {
            ConvertTo-XmlSafeValue -Value '<b>&"' | Should -Match '&lt;'
            ConvertTo-XmlSafeValue -Value '<b>&"' | Should -Not -Match '<b>'
        }

        It 'leaves Arabic text intact' {
            ConvertTo-XmlSafeValue -Value 'خبر عاجل' | Should -Be 'خبر عاجل'
        }
    }

    Describe 'Show-TitlerTemplate identity' {
        It 'assigns the SHOW event an id that the bridge can correlate with Cinegy status' {
            Mock Invoke-WebRequest {
                [pscustomobject]@{ StatusCode = 200; Content = '<Reply Success="y" Status="OK"/>' }
            }

            $result = Show-TitlerTemplate -AirServerAddress 'air-host' -AirChannelNumber 0 `
                -Layer 4 -TemplatePath 'D:\CG\urgent.cintitle'
            $eventIdProperty = $result.PSObject.Properties['EventId']

            $eventIdProperty | Should -Not -BeNullOrEmpty
            { [guid]::Parse(([string]$eventIdProperty.Value).Trim('{', '}')) } | Should -Not -Throw
            ([xml]$result.Xml).Request.Event.Id | Should -Be $eventIdProperty.Value
        }
    }
}

Describe 'Get-TitlerLayerStatus' {
    It 'extracts the external template filename from the Cinegy item description' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}" Name="Cinegy Type Layer 8 On" Description="Show ticker.cintitle on layer 8" IsEmpty="n"/>'
                }
            }
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"/><License State="Licensed"/><Output State="Normal"/><Client Connected="n" Identity=""/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 8

        $result.ActiveTemplateName | Should -Be 'ticker'
        $result.ActiveName | Should -Be 'Cinegy Type Layer 8 On'
    }

    It 'preserves Arabic and spaces when extracting a template from a full path' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}" Name="Cinegy Type Layer 8 On" Description="Show D:\Titles\حركة سلايد.cintitle on layer 8" IsEmpty="n"/>'
                }
            }
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}"/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 8

        $result.ActiveTemplateName | Should -Be 'حركة سلايد'
    }

    It 'returns operational metadata and the active Cinegy item name' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}" Name="External Lower Third" IsEmpty="n"/>'
                }
            }
            return [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}"/><License State="Licensed"/><Output State="Normal"/><Client Connected="y" Identity="Air Client 1"/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 4

        $result.ActiveName | Should -Be 'External Lower Third'
        $result.LicenseState | Should -Be 'Licensed'
        $result.OutputState | Should -Be 'Normal'
        $result.ClientConnected | Should -BeTrue
        $result.ClientIdentity | Should -Be 'Air Client 1'
    }

    It 'reports hidden when the active playlist item is Cinegy empty filler' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{86078791-9CB3-11F1-96C0-C85EA97266A8}" IsEmpty="y"/>'
                }
            }
            return [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{86078791-9CB3-11F1-96C0-C85EA97266A8}"/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 4

        $result.Success | Should -BeTrue
        $result.IsOnAir | Should -BeFalse
        Should -Invoke Invoke-WebRequest -ModuleName CinegyAirTitler -Times 1 -Exactly `
            -ParameterFilter { $Uri -eq 'http://air-host:5521/gfx_4/status/active' }
    }

    It 'reports a layer as on air when Cinegy returns a non-zero Active id' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/status/active') {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = '<Item Id="{D0B60C83-9CA7-11F1-96C0-C85EA97266A8}" IsEmpty="n"/>'
                }
            }
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Status><Active Id="{D0B60C83-9CA7-11F1-96C0-C85EA97266A8}"/></Status>'
            }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 2 -Layer 4

        $result.Success | Should -BeTrue
        $result.IsOnAir | Should -BeTrue
        $result.ActiveId | Should -Be '{D0B60C83-9CA7-11F1-96C0-C85EA97266A8}'
        Should -Invoke Invoke-WebRequest -ModuleName CinegyAirTitler -Times 1 -Exactly `
            -ParameterFilter { $Uri -eq 'http://air-host:5523/gfx_4/status' -and $Method -eq 'Get' }
        Should -Invoke Invoke-WebRequest -ModuleName CinegyAirTitler -Times 1 -Exactly `
            -ParameterFilter { $Uri -eq 'http://air-host:5523/gfx_4/status/active' -and $Method -eq 'Get' }
    }

    It 'reports a layer as hidden when Active is absent or has the zero id' -ForEach @(
        @{ Xml = '<Status></Status>' }
        @{ Xml = '<Status><Active Id="{00000000-0000-0000-0000-000000000000}"/></Status>' }
    ) {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{ StatusCode = 200; Content = $Xml }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 6

        $result.Success | Should -BeTrue
        $result.IsOnAir | Should -BeFalse
    }

    It 'returns an unknown result instead of claiming hidden when Cinegy is unreachable' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'connection refused' }

        $result = Get-TitlerLayerStatus -AirServerAddress 'offline-host' -AirChannelNumber 0 -Layer 4

        $result.Success | Should -BeFalse
        $result.IsOnAir | Should -BeNullOrEmpty
        $result.Error | Should -Match 'connection refused'
    }
}

Describe 'Get-AirTelemetryStatus' {
    It 'aggregates a healthy minute of Cinegy metrics' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics StartAt="2026-08-20T10:00:00Z"><At Time="2026-08-20T10:00:01Z" DroppedCount="0" OutputCount="25" NoInputSignal="0" AverageReadTime="1.0" ReadErrorRate="0" Heartbeat="650"/><At Time="2026-08-20T10:00:02Z" DroppedCount="0" OutputCount="25" NoInputSignal="0" AverageReadTime="3.0" ReadErrorRate="0" Heartbeat="700"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 2

        $result.Success | Should -BeTrue
        $result.Healthy | Should -BeTrue
        $result.SampleCount | Should -Be 2
        $result.OutputCount | Should -Be 50
        $result.DroppedCount | Should -Be 0
        $result.NoInputSignal | Should -Be 0
        $result.AverageReadTime | Should -Be 2.0
        $result.MaxReadErrorRate | Should -Be 0
        $result.MaxHeartbeat | Should -Be 700
        @($result.Issues).Count | Should -Be 0
        Should -Invoke Invoke-WebRequest -ModuleName CinegyAirTitler -Times 1 -Exactly `
            -ParameterFilter { $Uri -eq 'http://air-host:5523/metrics' -and $Method -eq 'Get' }
    }

    It 'marks dropped frames missing input and read errors as unhealthy' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="1" OutputCount="24" NoInputSignal="2" AverageReadTime="4.5" ReadErrorRate="5" Heartbeat="900"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0

        $result.Healthy | Should -BeFalse
        $result.DroppedCount | Should -Be 1
        $result.NoInputSignal | Should -Be 2
        $result.MaxReadErrorRate | Should -Be 5
        @($result.Issues).Count | Should -Be 3
    }

    It 'returns unknown health when the metrics endpoint is unreachable' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'metrics timeout' }

        $result = Get-AirTelemetryStatus -AirServerAddress 'offline-host' -AirChannelNumber 0

        $result.Success | Should -BeFalse
        $result.Healthy | Should -BeNullOrEmpty
        $result.Error | Should -Match 'metrics timeout'
    }

    It 'stays healthy for frame loss inside the tolerance' {
        # Zero tolerance is what produced 54 health transitions in one day: a
        # single dropped frame entered the sixty-sample window, the next check
        # the window had rolled past it, and the channel was never unwell.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="3" OutputCount="1500" NoInputSignal="0" AverageReadTime="4.5" ReadErrorRate="0.2" Heartbeat="900"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 `
            -FrameLossTolerance 5 -ReadErrorRateTolerance 0.5

        $result.Healthy | Should -BeTrue
        # Reported regardless: "within tolerance" is not "nothing happened".
        $result.DroppedCount | Should -Be 3
    }

    It 'still reports frame loss past the tolerance' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="60" OutputCount="1500" NoInputSignal="0" AverageReadTime="4.5" ReadErrorRate="0" Heartbeat="900"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -FrameLossTolerance 5 -FrameLossTolerancePercent 1

        $result.Healthy | Should -BeFalse
        $result.Issues | Should -Contain 'Dropped frames: 60 (4%)'
    }

    It 'stays quiet for a burst that is small against what actually went out' {
        # The alert the operator objected to: "الساقط 34، الخرج 1467" - which
        # sounds alarming and is 2.3%. A bare count cannot tell those apart,
        # and the sample window is not a fixed size.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="34" OutputCount="1467" NoInputSignal="0" AverageReadTime="2.31" ReadErrorRate="0" Heartbeat="924"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -FrameLossTolerance 5 -FrameLossTolerancePercent 5

        $result.Healthy | Should -BeTrue
        $result.DroppedPercent | Should -Be 2.32
    }

    It 'still speaks up when the share is genuinely bad' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="300" OutputCount="1500" NoInputSignal="0" AverageReadTime="2.31" ReadErrorRate="0" Heartbeat="924"/></Metrics>'
            }
        }

        $result = Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -FrameLossTolerance 5 -FrameLossTolerancePercent 5

        $result.Healthy | Should -BeFalse
        $result.Issues | Should -Contain 'Dropped frames: 300 (20%)'
    }

    It 'needs both thresholds crossed, not either' {
        # A handful of drops in a tiny window is a high percentage of nothing.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="3" OutputCount="10" NoInputSignal="0" AverageReadTime="2.31" ReadErrorRate="0" Heartbeat="924"/></Metrics>'
            }
        }

        (Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -FrameLossTolerance 5 -FrameLossTolerancePercent 5).Healthy | Should -BeTrue
    }

    It 'defaults to no tolerance, so an existing caller behaves as before' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{
                StatusCode = 200
                Content = '<Metrics><At DroppedCount="1" OutputCount="1500" NoInputSignal="0" AverageReadTime="4.5" ReadErrorRate="0" Heartbeat="900"/></Metrics>'
            }
        }

        (Get-AirTelemetryStatus -AirServerAddress 'air-host' -AirChannelNumber 0).Healthy | Should -BeFalse
    }

    It 'reads how long Cinegy means the active item to stay up' {
        # A ticker is scheduled as 24:00:00 with a manual end. That is the
        # engine saying "this is meant to be up", and it is what stops the
        # staleness alert from calling it forgotten.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            if ($Uri -like '*/active') {
                return [pscustomobject]@{ StatusCode = 200; Content = '<Item Id="{4}" Name="News-Ticker" Description="Show Ticker.cintitle" Duration="24:00:00.000" ManualEnd="y"/>' }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '<Status><Active Id="{4}"/><License State="Licensed"/><Output State="Normal"/><Client Connected="n" Identity=""/></Status>' }
        }

        $result = Get-TitlerLayerStatus -AirServerAddress 'air-host' -AirChannelNumber 0 -Layer 8

        $result.ActiveDurationSeconds | Should -Be 86400
        $result.ActiveManualEnd | Should -BeTrue
    }
}

Describe 'Cinegy telemetry text' {
    It 'formats healthy unhealthy and unreachable states without ambiguity' {
        $healthy = [pscustomobject]@{ Success = $true; Healthy = $true; SampleCount = 60; OutputCount = 1500; DroppedCount = 0; NoInputSignal = 0; AverageReadTime = 1.2; MaxReadErrorRate = 0; MaxHeartbeat = 700; Issues = @() }
        $unhealthy = [pscustomobject]@{ Success = $true; Healthy = $false; SampleCount = 60; OutputCount = 1490; DroppedCount = 2; NoInputSignal = 3; AverageReadTime = 2.2; MaxReadErrorRate = 4; MaxHeartbeat = 900; Issues = @('Dropped frames: 2') }
        $unknown = [pscustomobject]@{ Success = $false; Healthy = $null; Error = 'timeout' }

        Format-CinegyTelemetryStatus $healthy | Should -Match '^💚 صحة Cinegy: سليمة'
        Format-CinegyTelemetryStatus $unhealthy | Should -Match '^🔴 صحة Cinegy: تحذير'
        Format-CinegyTelemetryStatus $unknown | Should -Match '^⚠️ صحة Cinegy: غير معروفة'
    }
}

Describe 'Cinegy monitoring watchdogs' {
    BeforeEach {
        $script:RuntimeState.Monitoring.LastCinegyStateCheck = [datetime]::MinValue
        $script:RuntimeState.Monitoring.LastCinegyHealthCheck = [datetime]::MinValue
        $script:RuntimeState.Monitoring.CinegyHealthState = 'unknown'
        $script:HealthHistory.Cinegy.FailureCount = 0
        $script:HealthHistory.Cinegy.OutageStartedAt = $null
        $script:HealthHistory.Cinegy.AlertSent = $false
        Mock Get-SettingInt {
            if ($Name -eq 'CinegyStateCheckSeconds') { return 15 }
            if ($Name -eq 'CinegyHealthCheckSeconds') { return 60 }
            if ($Name -eq 'HealthFailureAlertThreshold') { return 2 }
            return 1
        }
        Mock Get-Setting { $true }
        Mock Send-AdminBroadcast { }
        Mock Write-BridgeLog { }
    }

    It 'alerts once when a tracked scene changes outside the bridge' {
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{
                Checked = @(4); Removed = @(4); Failed = @()
                Changes = @([pscustomobject]@{
                    Layer = 4; TemplateKey = 'lower-third'; ShowUserId = 10; ShownAt = Get-Date
                    ExpectedActiveId = '{OLD}'; ActualActiveId = '{NEW}'; ActualActiveName = 'External Item'
                    OutputState = 'Normal'; ClientConnected = $true; ClientIdentity = 'Air UI'
                })
            }
        }

        Update-CinegyStateWatchdog
        Update-CinegyStateWatchdog

        Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 1 }
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter {
            $Text -match 'تغيير خارجي' -and $Text -match 'lower-third' -and $Text -match 'External Item' -and $Text -match 'Air UI'
        }
    }

    It 'alerts only after the Cinegy failure threshold and sends one recovery notice' {
        $script:telemetryCall = 0
        Mock Get-AirTelemetryStatus {
            $script:telemetryCall++
            if ($script:telemetryCall -le 2) {
                return [pscustomobject]@{
                    Success = $true; Healthy = $false; SampleCount = 60
                    OutputCount = 1490; DroppedCount = 2; NoInputSignal = 0
                    AverageReadTime = 2; MaxReadErrorRate = 0; MaxHeartbeat = 800
                    Issues = @('Dropped frames: 2')
                }
            }
            return [pscustomobject]@{
                Success = $true; Healthy = $true; SampleCount = 60
                OutputCount = 1500; DroppedCount = 0; NoInputSignal = 0
                AverageReadTime = 1; MaxReadErrorRate = 0; MaxHeartbeat = 650
                Issues = @()
            }
        }

        Update-CinegyHealthWatchdog
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
        $script:RuntimeState.Monitoring.LastCinegyHealthCheck = [datetime]::MinValue
        Update-CinegyHealthWatchdog
        $script:RuntimeState.Monitoring.LastCinegyHealthCheck = [datetime]::MinValue
        Update-CinegyHealthWatchdog

        Should -Invoke Get-AirTelemetryStatus -Times 3 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'تحذير صحة Cinegy' }
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'تعافت صحة Cinegy' }
        $script:HealthHistory.Cinegy.FailureCount | Should -Be 0
        $script:HealthHistory.Cinegy.OutageStartedAt | Should -BeNullOrEmpty
    }

}

Describe 'Startup Cinegy reconciliation' {
    BeforeEach {
        Mock Get-CinegyLayerDashboard {
            @(
                [pscustomobject]@{ Layer = 4; Success = $true; IsOnAir = $false; ActiveId = ''; ActiveName = '' },
                [pscustomobject]@{ Layer = 7; Success = $true; IsOnAir = $true; ActiveId = '{EXTERNAL}'; ActiveName = 'Studio Lower Third' }
            )
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(4); Added = @(7); Removed = @(4); Failed = @(); Changes = @(); LastSuccessfulAt = Get-Date }
        }
        Mock Write-BridgeLog { }
    }

    It 'performs a full external-discovery comparison during startup' {
        { $script:result = Initialize-CinegyOnAirState } | Should -Not -Throw

        Should -Invoke Get-CinegyLayerDashboard -Times 1 -Exactly
        Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly -ParameterFilter {
            $Reason -eq 'startup' -and $DiscoverExternal -and @($LayerStatuses).Count -eq 2
        }
        $script:result.Added | Should -Be @(7)
    }

    It 'logs that uncertain startup layers were preserved rather than cleared' {
        Mock Get-CinegyLayerDashboard {
            @([pscustomobject]@{ Layer = 4; Success = $false; IsOnAir = $null; Error = 'timeout' })
        }
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(); Added = @(); Removed = @(); Failed = @(4); Changes = @(); LastSuccessfulAt = $null }
        }

        { Initialize-CinegyOnAirState | Out-Null } | Should -Not -Throw

        Should -Invoke Write-BridgeLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq 'WARN' -and $Message -match 'Startup.*preserved.*4'
        }
    }
}

Describe 'Cinegy state watchdog backoff wiring' {
    BeforeEach {
        $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds = 0
        $script:RuntimeState.Monitoring.LastCinegyStateCheck = [datetime]::MinValue
        Mock Write-BridgeLog {}
        Mock Send-AdminBroadcast {}
    }

    It 'widens the interval when a tracked layer cannot be verified' {
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(); Added = @(); Removed = @(); Failed = @(4); Changes = @() }
        }

        Update-CinegyStateWatchdog

        $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds | Should -BeGreaterThan 0
        Get-CinegyStateCheckInterval | Should -Be $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds
    }

    It 'skips the reconciliation entirely while the widened interval has not elapsed' {
        # This is the point of the whole change: an unreachable engine must not
        # be re-probed on the configured interval, because each probe blocks
        # the polling loop for its timeout.
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(); Added = @(); Removed = @(); Failed = @(4); Changes = @() }
        }

        Update-CinegyStateWatchdog
        Update-CinegyStateWatchdog

        Should -Invoke Update-OnAirStateFromCinegy -Times 1 -Exactly
    }

    It 'restores the configured interval after the engine answers again' {
        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(); Added = @(); Removed = @(); Failed = @(4); Changes = @() }
        }
        Update-CinegyStateWatchdog
        $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds | Should -BeGreaterThan 0

        Mock Update-OnAirStateFromCinegy {
            [pscustomobject]@{ Checked = @(4); Added = @(); Removed = @(); Failed = @(); Changes = @() }
        }
        $script:RuntimeState.Monitoring.LastCinegyStateCheck = [datetime]::MinValue
        Update-CinegyStateWatchdog

        $script:RuntimeState.Monitoring.CinegyStateBackoffSeconds | Should -Be 0
    }
}

Describe 'Live self-test' {
    BeforeEach {
        $script:OnAir = @{}
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Send-TelegramMessage {}
        Mock Get-AdminToolsKeyboard { @{ inline_keyboard = @() } }
        Mock Test-MaintenanceControl { $true }
        # Default first so unrelated settings still resolve, then the override.
        Mock Get-SettingInt { 3 }
        Mock Get-SettingInt { 15 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-TemplateStore { @{ Map = @{ 'lower-third' = @{ Key = 'lower-third'; Path = 'C:\t.cintitle'; Layer = 3; Fields = @('A'); FieldTypes = @{} } }; Order = @('lower-third'); Errors = @() } }
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $true; EventId = 'e1' } }
        Mock Exit-TitlerScene { [pscustomobject]@{ Success = $true } }
        Mock Hide-TitlerTemplate { [pscustomobject]@{ Success = $true } }
    }
    AfterAll { $script:OnAir = @{} }

    It 'runs the full path and reports success when the layer ends up empty' {
        $script:probe = 0
        Mock Get-TitlerLayerStatus {
            $script:probe++
            # empty, then live after SHOW, then empty again after cleanup
            [pscustomobject]@{ Success = $true; IsOnAir = ($script:probe -eq 2) }
        }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeTrue
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'نجح' }
    }

    It 'fails and says so when the layer is still occupied afterwards' {
        # The exact shape of today's incident: the scene never actually leaves.
        $script:probe = 0
        Mock Get-TitlerLayerStatus {
            $script:probe++
            [pscustomobject]@{ Success = $true; IsOnAir = ($script:probe -ne 1) }
        }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'فشل' }
    }

    It 'always attempts cleanup even when SHOW failed' {
        Mock Show-TitlerTemplate { [pscustomobject]@{ Success = $false; Error = 'engine refused' } }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false } }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Hide-TitlerTemplate -Times 1 -Exactly
    }

    It 'refuses to touch a layer that production templates use' {
        Mock Get-SettingInt { 3 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $false } }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }


    It 'sends nothing to air when no test layer is configured' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'TemplateTestLayer' }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
        Should -Invoke Hide-TitlerTemplate -Times 0 -Exactly
    }

    It 'refuses to start when the test layer is already busy' {
        Mock Get-TitlerLayerStatus { [pscustomobject]@{ Success = $true; IsOnAir = $true } }

        Invoke-BridgeSelfTest -ChatId 100 -UserId 100 | Should -BeFalse
        Should -Invoke Show-TitlerTemplate -Times 0 -Exactly
    }
}

Describe 'Black output watchdog' {
    BeforeEach {
        $script:OriginalLiveStreamForWatchdog = $config.LiveStream
        $config.LiveStream = [pscustomobject]@{
            SourceType = 'm3u8'; SourceUrl = 'https://primary.example/stream.m3u8'
            BackupSourceType = 'srt'; BackupSourceUrl = 'srt://127.0.0.1:5421'
            RtmpDestination = ''; VideoBitrateKbps = 2500; CopyCodec = $false
        }
        $script:LastOutputMonitorAt = [datetime]::MinValue
        $script:OutputBlackAlerted = $false
        $script:OutputMonitorFailureCount = 0
        $script:OutputMonitorFailureAlerted = $false
        $script:OutputMonitorFallbackActive = $false
        # The confirming look is booked across ticks now, so it has to be
        # cleared between cases or one test's booking answers the next one.
        $script:OutputMonitorConfirmAt = [datetime]::MinValue
        Mock Write-BridgeLog {}
        Mock Add-AuditEntry {}
        Mock Send-AdminBroadcast {}
        Mock Send-TelegramMessage {}
        Mock Start-Sleep {}
        Mock Get-MonitorFrame { 'frame.jpg' }
        Mock Remove-Item {}
        Mock Get-SettingInt { 60 } -ParameterFilter { $Name -eq 'OutputMonitorMinutes' }
        Mock Get-SettingInt { 6 } -ParameterFilter { $Name -eq 'OutputBlackLuminance' }
        Mock Get-SettingInt { 5 } -ParameterFilter { $Name -eq 'OutputBlackConfirmSeconds' }
        Mock Get-SettingInt { 8 } -ParameterFilter { $Name -eq 'SnapshotTimeoutSeconds' }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'OutputMonitorFailureAlertThreshold' }
        # The failure notice now names which link looks broken, and that check
        # reads a timeout of its own.
        Mock Get-SettingInt { 1 } -ParameterFilter { $Name -eq 'CinegyMonitorTimeoutSeconds' }
        Mock Get-AirVideoStatus { [pscustomobject]@{ Success = $true; ActiveId = ''; CuedId = ''; OutputState = 'Normal'; Error = '' } }
        Mock Get-Setting { $false } -ParameterFilter { $Name -eq 'NotifyOperatorsOnBlackOutput' }
    }

    AfterEach {
        $config.LiveStream = $script:OriginalLiveStreamForWatchdog
    }

    It 'alerts only after a second capture confirms the black' {
        Mock Get-BridgeFrameLuminance { 0.5 }

        # Two ticks, because the wait between the looks is no longer slept
        # through on the control loop - it is booked and honoured later.
        Update-OutputBlackWatchdog
        $script:OutputMonitorConfirmAt | Should -BeGreaterThan ([datetime]::MinValue)
        $script:OutputMonitorConfirmAt = (Get-Date).AddSeconds(-1)
        Update-OutputBlackWatchdog

        Should -Invoke Get-BridgeFrameLuminance -Times 2 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'أسود' }
    }

    It 'stays silent when the second capture is not black' {
        # A cut or a fade reads as black for one frame. Alerting on that would
        # train operators to ignore the alert.
        $script:probe = 0
        Mock Get-BridgeFrameLuminance { $script:probe++; if ($script:probe -eq 1) { 0.5 } else { 120 } }

        Update-OutputBlackWatchdog
        $script:OutputMonitorConfirmAt = (Get-Date).AddSeconds(-1)
        Update-OutputBlackWatchdog

        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'never takes a second capture when the first is bright' {
        Mock Get-BridgeFrameLuminance { 130 }

        Update-OutputBlackWatchdog

        Should -Invoke Get-BridgeFrameLuminance -Times 1 -Exactly
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
        # Nothing booked: a bright output is one reading, not a pair.
        $script:OutputMonitorConfirmAt | Should -Be ([datetime]::MinValue)
    }

    It 'books the confirming look instead of sleeping through it' {
        # The reason for the split. Start-Sleep here held the whole control
        # loop - auto-hide timers, the schedule, pending expiry and the
        # heartbeat all waited out a fade.
        Mock Get-BridgeFrameLuminance { 0.5 }
        Mock Start-Sleep { throw 'the control loop must not sleep for the confirming look' }

        { Update-OutputBlackWatchdog } | Should -Not -Throw

        $script:OutputMonitorConfirmAt | Should -BeGreaterThan (Get-Date)
        Should -Invoke Get-BridgeFrameLuminance -Times 1 -Exactly
    }

    It 'does not repeat the alert while the output stays black' {
        Mock Get-BridgeFrameLuminance { 0.5 }

        Update-OutputBlackWatchdog
        $script:OutputMonitorConfirmAt = (Get-Date).AddSeconds(-1)
        Update-OutputBlackWatchdog

        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog
        $script:OutputMonitorConfirmAt = (Get-Date).AddSeconds(-1)
        Update-OutputBlackWatchdog

        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
    }

    It 'reports recovery once the picture comes back' {
        Mock Get-BridgeFrameLuminance { 0.5 }
        Update-OutputBlackWatchdog
        $script:OutputMonitorConfirmAt = (Get-Date).AddSeconds(-1)
        Update-OutputBlackWatchdog

        Mock Get-BridgeFrameLuminance { 140 }
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'عاد المخرج' }
    }

    It 'does nothing at all when monitoring is disabled' {
        Mock Get-SettingInt { 0 } -ParameterFilter { $Name -eq 'OutputMonitorMinutes' }
        Mock Get-BridgeFrameLuminance { 0 }

        Update-OutputBlackWatchdog

        Should -Invoke Get-MonitorFrame -Times 0 -Exactly
    }

    It 'stays quiet when the capture itself failed, rather than assuming black' {
        # Without a configured backup there is no safe source to switch to;
        # a failed probe must remain quiet until the consecutive-failure alert.
        $config.LiveStream.BackupSourceUrl = ''
        Mock Get-MonitorFrame { $null }

        Update-OutputBlackWatchdog

        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'switches to the Cinegy backup after the first failed primary probe' {
        # A stopped primary must not leave operator snapshots pointed at the
        # dead M3U8 until the next hourly watchdog cycle.
        Mock Get-MonitorFrame { $null }

        Update-OutputBlackWatchdog

        $script:OutputMonitorFallbackActive | Should -BeTrue
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'الاحتياطي' }
    }

    It 'alerts administrators after the configured consecutive capture failures' {
        # Removing the failure counter or its threshold check must make this fail:
        # a stopped source must produce one actionable administrator alert.
        Mock Get-MonitorFrame { $null }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'OutputMonitorFailureAlertThreshold' }

        Update-OutputBlackWatchdog
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        $script:OutputMonitorFailureAlerted | Should -BeTrue
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'تعذّر' }
    }

    It 'reports availability recovery when no backup source is configured' {
        $config.LiveStream.BackupSourceUrl = ''
        Mock Get-MonitorFrame { $null }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'OutputMonitorFailureAlertThreshold' }

        Update-OutputBlackWatchdog
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        Mock Get-MonitorFrame { 'frame.jpg' }
        Mock Get-BridgeFrameLuminance { 140 }
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        $script:OutputMonitorFailureAlerted | Should -BeFalse
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'عاد الوصول' }
    }

    It 'uses the configured Cinegy source while fallback is active' {
        $script:OutputMonitorFallbackActive = $true

        $active = Get-ActiveLiveStreamConfig

        $active.SourceType | Should -Be 'srt'
        $active.SourceUrl | Should -Be 'srt://127.0.0.1:5421'
    }

    It 'switches once to the Cinegy backup after sustained primary failure' {
        # Removing the fallback switch leaves the relay and snapshots on a dead
        # primary source, so this must fail when that state transition is lost.
        Mock Get-MonitorFrame { $null }
        Mock Get-SettingInt { 2 } -ParameterFilter { $Name -eq 'OutputMonitorFailureAlertThreshold' }

        Update-OutputBlackWatchdog
        $script:LastOutputMonitorAt = [datetime]::MinValue
        Update-OutputBlackWatchdog

        $script:OutputMonitorFallbackActive | Should -BeTrue
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'الاحتياطي' }
    }

    It 'returns to the primary source when it can be captured again' {
        $script:OutputMonitorFallbackActive = $true
        $script:OutputMonitorFailureAlerted = $true
        $script:OutputMonitorFailureCount = 2
        Mock Get-MonitorFrame { 'frame.jpg' }
        Mock Get-BridgeFrameLuminance { 140 }

        Update-OutputBlackWatchdog

        $script:OutputMonitorFallbackActive | Should -BeFalse
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter { $Text -match 'الأساسي' }
    }
}

Describe 'Cinegy results keep one shape' {
    <#
        Four bugs this release came from the same thing: a field that exists
        only on the success path, read by a caller on the failure path, which
        throws under StrictMode exactly when the engine is already in trouble.
        These pin the shapes so the class cannot come back quietly.
    #>
    BeforeAll { Import-Module (Join-Path $script:Root 'Modules\CinegyAirTitler.psm1') -Force }

    It 'reports the same fields whether the command worked or failed' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { [pscustomobject]@{ StatusCode = 200; Content = '' } }
        $ok = Send-AirCommand -AirServerAddress 'air' -AirChannelNumber 0 -Device '*GFX_5' -Cmd 'Show'

        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'engine refused' }
        $bad = Send-AirCommand -AirServerAddress 'air' -AirChannelNumber 0 -Device '*GFX_5' -Cmd 'Show'

        $okFields = @($ok.PSObject.Properties.Name | Sort-Object)
        $badFields = @($bad.PSObject.Properties.Name | Sort-Object)
        $badFields | Should -Be $okFields
        $bad.StatusCode | Should -Be 0
        $ok.Error | Should -Be ''
    }

    It 'keeps one shape for a layer status too' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{ StatusCode = 200; Content = '<Status><Active Id="{00000000-0000-0000-0000-000000000000}"/><License State="Licensed"/><Output State="Normal"/><Client Connected="n" Identity=""/></Status>' }
        }
        $ok = Get-TitlerLayerStatus -AirServerAddress 'air' -AirChannelNumber 0 -Layer 5

        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'connection refused' }
        $bad = Get-TitlerLayerStatus -AirServerAddress 'air' -AirChannelNumber 0 -Layer 5

        @($bad.PSObject.Properties.Name | Sort-Object) | Should -Be @($ok.PSObject.Properties.Name | Sort-Object)
        # The field the staleness exemption reads, on the path where Cinegy
        # could not answer.
        $bad.ActiveDurationSeconds | Should -Be 0
    }

    It 'keeps one shape for telemetry, on all three of its exits' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{ StatusCode = 200; Content = '<Metrics><At DroppedCount="0" OutputCount="1500" NoInputSignal="0" AverageReadTime="4.5" ReadErrorRate="0" Heartbeat="900"/></Metrics>' }
        }
        $ok = Get-AirTelemetryStatus -AirServerAddress 'air' -AirChannelNumber 0

        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { [pscustomobject]@{ StatusCode = 200; Content = '<Metrics></Metrics>' } }
        $empty = Get-AirTelemetryStatus -AirServerAddress 'air' -AirChannelNumber 0

        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'metrics timeout' }
        $bad = Get-AirTelemetryStatus -AirServerAddress 'air' -AirChannelNumber 0

        $expected = @($ok.PSObject.Properties.Name | Sort-Object)
        @($empty.PSObject.Properties.Name | Sort-Object) | Should -Be $expected
        @($bad.PSObject.Properties.Name | Sort-Object) | Should -Be $expected
    }
}

Describe 'Capture failure logging' {
    It 'reads a dead stream host out of the ffmpeg reason line' {
        Test-MediaSourceUnreachable -Detail 'Error opening input file https://x/y.m3u8 | Server returned 5XX Server Error reply' |
            Should -BeTrue
    }

    It 'still calls anything else a bridge failure' {
        Test-MediaSourceUnreachable -Detail 'Output file #0 does not contain any stream' | Should -BeFalse
        Test-MediaSourceUnreachable -Detail '' | Should -BeFalse
    }

    It 'says the monitor source is down once, not once per attempt' {
        Mock Write-BridgeLog { }
        Mock Get-FfmpegPath { 'ffmpeg.exe' }
        Mock Start-BridgeMediaProcess { throw 'source unavailable' }
        $previousLiveStream = $config.LiveStream
        $config.LiveStream = [pscustomobject]@{ SourceType = 'm3u8'; SourceUrl = 'https://primary.example/stream.m3u8' }
        try {
            $script:OutputMonitorFailureCount = 0
            Get-MonitorFrame -TimeoutSeconds 1 | Should -BeNullOrEmpty
            $script:OutputMonitorFailureCount = 3
            Get-MonitorFrame -TimeoutSeconds 1 | Should -BeNullOrEmpty
        }
        finally {
            $config.LiveStream = $previousLiveStream
            $script:OutputMonitorFailureCount = 0
        }

        # The watchdog alerts at its threshold; repeating the line every hour
        # of a stream-host outage only buries other failures.
        Should -Invoke Write-BridgeLog -Times 1 -Exactly
    }
}


Describe 'The material on air and its schedule' {
    # The programme under the graphics. Read-only, and the bridge knew nothing
    # about it until now - an operator opened Cinegy to find out what was
    # playing before deciding whether the moment suited a strap.
    BeforeEach {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            $body = if ($Uri -match '/video/status') {
                '<?xml version="1.0"?><Status><Active Id="{AAA}"/><Cued Id="{BBB}"/><License State="Licensed"/><Output State="Normal"/></Status>'
            }
            elseif ($Uri -match '/video/list') {
                '<?xml version="1.0"?><List>' +
                '<Item Id="{BBB}" Name="الثانية" ScheduledAt="2026-09-09T19:00:00.000Z" Duration="01:00:00.000" ProxyProgress="100" LoopStart="n"/>' +
                '<Item Id="{AAA}" Name="الأولى" ScheduledAt="2026-09-09T18:00:00.000Z" Duration="01:00:00.000" ProxyProgress="0" LoopStart="y"/>' +
                '</List>'
            }
            else { '<?xml version="1.0"?><Status/>' }
            [pscustomobject]@{ Content = $body; StatusCode = 200 }
        }
    }

    It 'reads what is playing and what is cued as real ids' {
        $status = Get-AirVideoStatus -AirServerAddress '127.0.0.1' -AirChannelNumber 0
        $status.Success | Should -BeTrue
        $status.ActiveId | Should -Be 'AAA'
        $status.CuedId | Should -Be 'BBB'
        $status.OutputState | Should -Be 'Normal'
        $status.License | Should -Be 'Licensed'
    }

    It 'treats a null guid as nothing cued rather than as an item' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler {
            [pscustomobject]@{ Content = '<?xml version="1.0"?><Status><Active Id="{AAA}"/><Cued Id="{00000000-0000-0000-0000-000000000000}"/></Status>'; StatusCode = 200 }
        }
        (Get-AirVideoStatus -AirServerAddress '127.0.0.1' -AirChannelNumber 0).CuedId | Should -BeNullOrEmpty
    }

    It 'returns the schedule in time order whatever order it arrived in' {
        # The live channel does not promise an order, and a rundown out of
        # sequence is not a rundown.
        $schedule = Get-AirMaterialSchedule -AirServerAddress '127.0.0.1' -AirChannelNumber 0
        $schedule.Success | Should -BeTrue
        @($schedule.Items).Count | Should -Be 2
        @($schedule.Items)[0].Name | Should -Be 'الأولى'
        @($schedule.Items)[0].Duration | Should -Be ([timespan]'01:00:00')
        @($schedule.Items)[0].LoopStart | Should -BeTrue
        @($schedule.Items)[1].ProxyProgress | Should -Be 100
    }

    It 'reports a failure instead of guessing when the channel cannot be reached' {
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'no route to host' }
        $status = Get-AirVideoStatus -AirServerAddress '127.0.0.1' -AirChannelNumber 0
        $status.Success | Should -BeFalse
        $status.ActiveId | Should -BeNullOrEmpty
        (Get-AirMaterialSchedule -AirServerAddress '127.0.0.1' -AirChannelNumber 0).Items | Should -BeNullOrEmpty
    }

    It 'names the programme on air and the one after it' {
        $line = Get-AirMaterialNowNext -TimeoutSec 1
        $line | Should -Match 'الجاري'
        $line | Should -Match 'الأولى'
        $line | Should -Match 'التالي'
        $line | Should -Match 'الثانية'
    }

    It 'says nothing at all when the channel is unreachable' {
        # The status screen reports Cinegy health above this line; a second
        # failure notice in the same screen reads as two faults.
        Mock Invoke-WebRequest -ModuleName CinegyAirTitler { throw 'unreachable' }
        Get-AirMaterialNowNext -TimeoutSec 1 | Should -BeNullOrEmpty
    }
}


Describe 'A graphic that stayed on air' {
    # The failure the station actually reported when asked what had last gone
    # wrong: a graphic stayed up and was never taken down. The alert for it
    # existed and still allowed it, because it fired once to administrators
    # with no button - whoever missed that message missed it for good.
    BeforeEach {
        $script:StaleOnAirAlerted = @{}
        $script:OnAir.Clear()
        $script:OnAir[7] = @{ Key = 'Urgent'; At = (Get-Date).AddHours(-3); UserId = 705980352; ChatId = 705980352; ActiveId = '{X}' }
        $script:RuntimeState.Monitoring.LastStaleOnAirCheck = [datetime]::MinValue
        Mock Write-BridgeLog { }
        Mock Send-AdminBroadcast { }
        Mock Send-TelegramMessage { }
        Mock Test-LongRunningOnAir { $false }
        Mock Get-AdminNotifyIds { @(122238225) }
        # Set rather than mocked: a filtered mock on Get-SettingInt breaks
        # every other reader in the call, and New-Button is one of them.
        $script:OriginalStaleHours = Get-Setting 'StaleOnAirAlertHours'
        $config.Settings | Add-Member -NotePropertyName StaleOnAirAlertHours -NotePropertyValue 1 -Force
    }
    AfterEach {
        $script:OnAir.Clear(); $script:StaleOnAirAlerted = @{}
        $config.Settings | Add-Member -NotePropertyName StaleOnAirAlertHours -NotePropertyValue $script:OriginalStaleHours -Force
    }

    It 'carries the hide button on the notice itself' {
        Update-StaleOnAirWatchdog
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter {
            @($ReplyMarkup.inline_keyboard | ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) -contains 'hide:7'
        }
    }

    It 'tells the operator who put it there, not only the administrators' {
        Update-StaleOnAirWatchdog
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $ChatId -eq 705980352 }
    }

    It 'does not tell an administrator twice in two messages' {
        $script:OnAir[7].ChatId = 122238225
        Update-StaleOnAirWatchdog
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }

    It 'keeps saying so while the graphic is still up' {
        # One notice that goes unread used to be the end of it.
        Update-StaleOnAirWatchdog
        $script:StaleOnAirAlerted[7].Count | Should -Be 1

        # Too soon for the second notice.
        $script:RuntimeState.Monitoring.LastStaleOnAirCheck = [datetime]::MinValue
        Update-StaleOnAirWatchdog
        $script:StaleOnAirAlerted[7].Count | Should -Be 1

        # The first interval has passed.
        $script:StaleOnAirAlerted[7].LastAt = (Get-Date).AddMinutes(-20)
        $script:RuntimeState.Monitoring.LastStaleOnAirCheck = [datetime]::MinValue
        Update-StaleOnAirWatchdog
        $script:StaleOnAirAlerted[7].Count | Should -Be 2
        Should -Invoke Send-AdminBroadcast -Times 2 -Exactly
    }

    It 'starts from silence again for a layer shown afresh' {
        Update-StaleOnAirWatchdog
        $script:OnAir.Remove(7)
        $script:RuntimeState.Monitoring.LastStaleOnAirCheck = [datetime]::MinValue
        Update-StaleOnAirWatchdog
        $script:StaleOnAirAlerted.ContainsKey(7) | Should -BeFalse
    }
}

Describe 'Material due without a local copy' {
    BeforeEach {
        $script:MaterialProxyAlerted.Clear()
        $script:RuntimeState.Monitoring.LastMaterialProxyCheck = [datetime]::MinValue
        Mock Write-BridgeLog { }
        Mock Send-AdminBroadcast { }
        $script:soon = [datetimeoffset]::Now.AddMinutes(10)
        Mock Get-AirMaterialSchedule {
            [pscustomobject]@{ Success = $true; Error = ''; Items = @(
                    [pscustomobject]@{ Id = 'a'; Name = 'بلا نسخة'; ScheduledAt = $script:soon; Duration = [timespan]'01:00:00'; ProxyProgress = 0; LoopStart = $false }
                    [pscustomobject]@{ Id = 'b'; Name = 'ناقصة'; ScheduledAt = $script:soon; Duration = [timespan]'01:00:00'; ProxyProgress = 40; LoopStart = $false }
                    [pscustomobject]@{ Id = 'c'; Name = 'جاهزة'; ScheduledAt = $script:soon; Duration = [timespan]'01:00:00'; ProxyProgress = 100; LoopStart = $false }
                ) }
        }
    }
    AfterEach {
        $script:MaterialProxyAlerted.Clear()
        $config.Settings | Add-Member -NotePropertyName NotifyAdminsOnMissingProxy -NotePropertyValue $false -Force
    }

    It 'says nothing at all while the option is off' {
        # Twenty-two of twenty-four items on this station carry no local copy,
        # so an always-on alert would fire on nearly everything.
        $config.Settings | Add-Member -NotePropertyName NotifyAdminsOnMissingProxy -NotePropertyValue $false -Force
        Update-MaterialProxyWatchdog
        Should -Invoke Send-AdminBroadcast -Times 0 -Exactly
    }

    It 'names what is missing and what merely stopped part way' {
        $config.Settings | Add-Member -NotePropertyName NotifyAdminsOnMissingProxy -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName MaterialProxyLeadMinutes -NotePropertyValue 30 -Force
        Update-MaterialProxyWatchdog
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly -ParameterFilter {
            $Text -match 'بلا نسخة محلية' -and $Text -match 'متوقف عند 40' -and $Text -notmatch 'جاهزة'
        }
    }

    It 'reports an item once rather than on every tick' {
        $config.Settings | Add-Member -NotePropertyName NotifyAdminsOnMissingProxy -NotePropertyValue $true -Force
        $config.Settings | Add-Member -NotePropertyName MaterialProxyLeadMinutes -NotePropertyValue 30 -Force
        Update-MaterialProxyWatchdog
        $script:RuntimeState.Monitoring.LastMaterialProxyCheck = [datetime]::MinValue
        Update-MaterialProxyWatchdog
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
    }
}


Describe 'Advisory text checks before air' {
    # Advisory, never blocking. A breaking headline held back over a proper
    # noun no checker knows is worse than the typo it guarded against.
    It 'names the shapes a phone keyboard produces' {
        $warnings = @(Get-BridgeTextWarnings -Text 'الرئيييس  يفتتح,المعرض 2026')
        ($warnings -join ' ') | Should -Match 'حرف مكرّر'
        ($warnings -join ' ') | Should -Match 'مسافتان'
        ($warnings -join ' ') | Should -Match 'ترقيم'
        ($warnings -join ' ') | Should -Match 'أرقام لاتينية'
    }

    It 'says nothing about ordinary Arabic' {
        # The first build flagged الرئيس and اجتماع on a fresh install, which
        # is noise wearing the costume of a warning.
        Get-BridgeTextWarnings -Text 'الرئيس يفتتح المعرض اليوم' | Should -BeNullOrEmpty
    }

    It 'reads a word through what Arabic glues to it' {
        # A stem list cannot match والرئيس or بالوزير without this.
        foreach ($form in @('والرئيس', 'بالوزير', 'للحكومة')) {
            Test-BridgeWordKnown -Word $form -Lexicon ([System.Collections.Generic.HashSet[string]]::new()) | Should -BeTrue -Because "$form strips to a core word"
        }
    }

    It 'stays silent on unfamiliar words until the station has written enough' {
        # The core list suppresses; the station's own words qualify. Below the
        # threshold "you have never written this" carries no information, and
        # a test fixture has written nothing.
        @(Get-BridgeTextWarnings -Text 'زيارة الوفد الى مدينة فلانتينوس') |
            Where-Object { $_ -match 'لم تكتبها' } | Should -BeNullOrEmpty
    }
}

Describe 'Naming which link broke' {
    # "تعذّر الوصول إلى مخرج البث" names a symptom and leaves the reader to
    # work out where to start, at the moment they have least patience for it.
    BeforeEach { Mock Write-BridgeLog { } }

    It 'says the black was deliberate when the channel says so' {
        Mock Get-AirVideoStatus { [pscustomobject]@{ Success = $true; ActiveId = 'x'; CuedId = ''; OutputState = 'Black'; Error = '' } }
        (@(Get-OutputFailureDiagnosis) -join ' ') | Should -Match 'مقصود'
    }

    It 'starts at Cinegy when the channel does not answer at all' {
        Mock Get-AirVideoStatus { [pscustomobject]@{ Success = $false; ActiveId = ''; CuedId = ''; OutputState = ''; Error = 'down' } }
        (@(Get-OutputFailureDiagnosis) -join ' ') | Should -Match 'لا تُجيب'
    }

    It 'names the relay when one is meant to be running and is not' {
        Mock Get-AirVideoStatus { [pscustomobject]@{ Success = $true; ActiveId = 'x'; CuedId = ''; OutputState = 'Normal'; Error = '' } }
        Mock Get-RunningRelayProcess { $null }
        $original = $script:RelayState.ShouldRun
        try {
            $script:RelayState.ShouldRun = $true
            (@(Get-OutputFailureDiagnosis) -join ' ') | Should -Match 'الترحيل'
        }
        finally { $script:RelayState.ShouldRun = $original }
    }

    It 'names the streaming server when the last capture says it is down' {
        # The station asked for source AND server: the server link is read
        # from the last ffmpeg stderr, stored by Get-MonitorFrame.
        Mock Get-AirVideoStatus { [pscustomobject]@{ Success = $true; ActiveId = 'x'; CuedId = ''; OutputState = 'Normal'; Error = '' } }
        $original = $script:LastCaptureErrorDetail
        try {
            $script:LastCaptureErrorDetail = 'Connection refused by 10.0.0.5'
            $text = @(Get-OutputFailureDiagnosis) -join ' '
            $text | Should -Match 'سيرفر البث'
            $text | Should -Match 'الخطوة التالية'
        }
        finally { $script:LastCaptureErrorDetail = $original }
    }

    It 'still ends with a next step when nothing is broken' {
        Mock Get-AirVideoStatus { [pscustomobject]@{ Success = $true; ActiveId = 'x'; CuedId = ''; OutputState = 'Normal'; Error = '' } }
        $original = $script:LastCaptureErrorDetail
        try {
            $script:LastCaptureErrorDetail = ''
            (@(Get-OutputFailureDiagnosis) -join ' ') | Should -Match 'الخطوة التالية'
        }
        finally { $script:LastCaptureErrorDetail = $original }
    }
}
