#requires -Version 7

function Get-WebAdminSettingView {
    # Keep an explicit schema of safe scalars. Neither the full configuration
    # nor formatted diagnostic text is a suitable web response.
    $groups = [ordered]@{
        access = [ordered]@{
            EnableSelfServiceRequests = 'boolean'
            BlockRejectedRequesters = 'boolean'
            PendingApprovalExpiryHours = 'integer'
        }
        air = [ordered]@{
            EnableTimedShow = 'boolean'
            ConfirmLayerRemoval = 'boolean'
            SchedulePaused = 'boolean'
            AutoHideDefaultSeconds = 'integer'
        }
        newsroom = [ordered]@{
            EnableUrgentBoard = 'boolean'
            MojazMultiDesign = 'boolean'
            EnableNewsTickerManagement = 'boolean'
        }
        monitoring = [ordered]@{
            NotifyAdminsOnCinegyHealth = 'boolean'
            OutputMonitorMinutes = 'integer'
            CinegyStateStaleSeconds = 'integer'
            HealthFailureAlertThreshold = 'integer'
        }
    }
    foreach ($group in $groups.GetEnumerator()) {
        foreach ($setting in $group.Value.GetEnumerator()) {
            $name = [string]$setting.Key
            $kind = [string]$setting.Value
            $metadata = $script:SettingSchema | Where-Object Name -CEQ $name | Select-Object -First 1
            if (-not $metadata -or $metadata.Sensitive) { continue }
            $current = Get-Setting $name
            $enabled = $null
            $value = $null
            $number = 0
            if ($kind -eq 'boolean') {
                if ($current -is [bool]) { $enabled = $current }
            }
            elseif ($null -ne $current -and [int]::TryParse([string]$current, [ref]$number)) {
                $value = $number
            }
            [ordered]@{
                id = $name; category = [string]$group.Key; kind = $kind
                label = $metadata.Label; description = $metadata.Description
                unit = $metadata.Unit
                enabled = $enabled; value = $value
                minimum = $metadata.Minimum; maximum = $metadata.Maximum
                protected = $metadata.Protected; editable = $false
            }
        }
    }
    Get-WebAdminEditableSettingView
}

function Get-WebAdminNotificationCoverage {
    param([System.Collections.IDictionary]$Arguments, [datetimeoffset]$Now = [datetimeoffset]::Now)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    # The Bot can render private IDs to a station administrator. Only counts
    # cross the web boundary, so this report also works for shared screens.
    $mismatch = Get-AdminListMismatch
    return @{ ok = $true; data = @{
        checkedAt = $Now.ToUnixTimeMilliseconds()
        matched = $mismatch.MatchedCount
        withoutPersonalChat = $mismatch.Unnotified.Count
        withoutAdminRights = $mismatch.Unauthorized.Count
    } }
}

function Get-WebUsageSummary {
    param([System.Collections.IDictionary]$Arguments)

    if (-not (Get-WebAdminSettingActor -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $digest = Get-BridgeUsageDigestSnapshot
    return @{ ok = $true; data = @{
        capturedAt = ConvertTo-AirStatusWidgetEpoch $digest.CapturedAt
        startedAt = ConvertTo-AirStatusWidgetEpoch $script:BridgeStartedAt
        successful = $digest.Outcomes.Success
        failed = $digest.Outcomes.Failed
        blocked = $digest.Outcomes.Blocked
        sevenDayOperations = $digest.WeeklyOperations
        dailyAverage = $digest.DailyAverage
        sevenDayTruncated = $digest.WeeklyTruncated
        templates = @(foreach ($item in $digest.Ranked) {
            $lastUsed = ConvertTo-AirStatusWidgetEpoch $item.LastUsed
            @{
                name = Format-WebTemplateReportLabel -Text $item.Key
                uses = $item.Value
                lastUsedAt = if ($lastUsed -gt 0) { $lastUsed } else { $null }
            }
        })
    } }
}

function Get-WebShiftReadiness {
    param([System.Collections.IDictionary]$Arguments, [datetimeoffset]$Now = [datetimeoffset]::Now)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $snapshot = Get-ShiftReadinessSnapshot
    return @{ ok = $true; data = @{
        checkedAt = $Now.ToUnixTimeMilliseconds()
        ready = $snapshot.Ready
        onAirLayers = $snapshot.OnAirLayers
        pendingOperations = $snapshot.PendingOperations
        tickerDraft = $snapshot.TickerDraft
        quarantinedChats = $snapshot.QuarantinedChats
        pinnedFaults = $snapshot.PinnedFaults
        quietHours = $snapshot.QuietHours
        protectionFindings = @(Get-ShiftReadinessProtectionFinding | ForEach-Object { $_.Name })
    } }
}

function Get-WebSelfTestReadiness {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }

    $findings = [Collections.Generic.List[string]]::new()
    if (-not (Test-MaintenanceControl -ChatId $actor -UserId $actor -Quiet)) { $findings.Add('maintenance_active') }
    $layer = Get-SettingInt 'TemplateTestLayer' 0
    if ($layer -le 0) { $findings.Add('test_layer_missing') }
    if ((Get-Setting 'SceneMode') -ne 'Single') { $findings.Add('multi_scene_state') }

    $store = Get-TemplateStore
    $first = if ($store.Order.Count -gt 0) { $store.Map[$store.Order[0]] }
    $hasTemplate = -not [string]::IsNullOrWhiteSpace([string](Get-JsonProp $first 'Path'))
    if (-not $hasTemplate) { $findings.Add('registered_scene_missing') }
    if ($layer -gt 0) {
        if (@(Get-TemplateTestLayerConflict -Layer $layer).Count -gt 0) { $findings.Add('layer_configured_for_templates') }
        if (Test-PermanentGraphicAutoHideProtected -Layer $layer) { $findings.Add('permanent_layer') }
        $physical = (Resolve-AirGfxDevice -Layer $layer).StatusPath
        # The native conflict checker is logical. A named registry device on a
        # different layer can still address the configured test device.
        $aliases = @(foreach ($template in $store.Map.Values) {
            $otherLayer = [int](Get-JsonProp $template 'Layer')
            if ($otherLayer -gt 0 -and $otherLayer -ne $layer) {
                $otherDevice = [string](Get-JsonProp $template 'Device')
                if ((Resolve-AirGfxDevice -Layer $otherLayer -Device $otherDevice).StatusPath -ceq $physical) { $otherLayer }
            }
        })
        if ($aliases.Count -gt 0) { $findings.Add('physical_layer_conflict') }
        if (@($script:OnAir.Keys | Where-Object {
                [int]$_ -eq $layer -or (Resolve-AirGfxDevice -Layer ([int]$_)).StatusPath -ceq $physical
            }).Count -gt 0) { $findings.Add('layer_tracked') }
    }

    $engine = 'not_checked'
    $observedAt = $null
    if ($findings.Count -eq 0) {
        $now = [Diagnostics.Stopwatch]::GetTimestamp()
        if ($Deadline -gt 0 -and $now -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
        if ($now -lt $script:WebLayerComparisonNextProbe) { return @{ ok = $false; error = 'layer_comparison_busy' } }
        try { $status = Get-WebLayerStatus -Layer $layer -TimeoutSec 1 -RequireConsistentIdentity }
        catch { $status = $null }
        finally {
            $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency
        }
        $observedAt = [datetimeoffset]::UtcNow.ToUnixTimeMilliseconds()
        $active = Get-JsonProp $status 'IsOnAir'
        $engine = 'unknown'
        if ((Get-JsonProp $status 'Success') -eq $true -and $active -is [bool]) {
            $engine = if ($active) { 'occupied' } else { 'idle' }
        }
    }

    # Native self-test chooses the first template and uses layer-wide EXIT
    # and HIDE. These are outstanding requirements for a test that can
    # prove both scene identity and cleanup, independent of an idle sample.
    $findings.Add('dedicated_scene_unavailable')
    $findings.Add('identity_cleanup_unavailable')
    return @{ ok = $true; data = @{
        layer = if ($layer -gt 0) { $layer } else { $null }
        hasRegisteredTemplate = $hasTemplate
        engine = $engine; observedAt = $observedAt; findings = $findings.ToArray()
    } }
}

function Get-WebRestartReadiness {
    param([System.Collections.IDictionary]$Arguments, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $state = if ($script:RestartRequested) { 'already-requested' }
    elseif (-not (Get-Setting 'AllowRemoteRestart')) { 'disabled' }
    else {
        try { (Get-BridgeRestartPath).Kind }
        catch { 'unavailable' }
    }
    $managed = $false
    $relayActive = $false
    if ($state -notin 'disabled', 'already-requested' -and $script:ManagedRestartChannel -and $script:ManagedRestartOwnsMutex) {
        $relayActive = Test-WebManagedRestartRelayActive
        if (-not $relayActive) {
            $probe = Invoke-ManagedRestartSupervisor -Action probe
            $managed = (Get-JsonProp $probe 'ok') -eq $true -and (Get-JsonProp $probe 'state') -ceq 'available'
            if ((Get-JsonProp $probe 'ok') -eq $true -and (Get-JsonProp $probe 'state') -ceq 'stalled') { $state = 'stalled' }
        }
    }
    return @{ ok = $true; data = @{
            checkedAt = $Now.ToUnixTimeMilliseconds()
            state = $state
            activeScenes = $script:OnAir.Count
            managedRestartAvailable = $managed
            relayBlocksRestart = $relayActive
        } }
}

function Get-WebAdminOverview {
    param([System.Collections.IDictionary]$Arguments, [datetime]$Now = (Get-Date))
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-StatusViewer -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $monitoring = $script:RuntimeState.Monitoring
    $telegramState = [string]$monitoring.TelegramConnectionState
    if ($telegramState -cnotin 'connected', 'disconnected') { $telegramState = 'unknown' }
    $cinegyState = [string]$monitoring.CinegyHealthState
    if ($cinegyState -cnotin 'healthy', 'unhealthy', 'unreachable') { $cinegyState = 'unknown' }
    $lastRead = $monitoring.LastCinegyStateSuccess
    $lastReadAt = if ($lastRead -gt [datetime]::MinValue) { ([datetimeoffset]$lastRead).ToUnixTimeMilliseconds() } else { 0L }
    $freshnessInputs = @{
        LastSuccessfulAt = if ($lastReadAt) { $lastRead }
        FailedCount = $monitoring.LastCinegyStateFailedCount
        Now = $Now
        StaleAfterSeconds = Get-SettingInt 'CinegyStateStaleSeconds' 45
    }
    $freshness = Get-CinegyStateFreshness @freshnessInputs

    # Reuse the dashboard's cached feed and read-only relay projections.
    # Report their state codes only, excluding sources, revisions and process details.
    $outputState = [string](Get-WebFeedStatus -Now $Now).state
    if ($outputState -cnotin 'unreachable', 'black', 'unconfigured', 'off', 'pending', 'degraded', 'receiving') { $outputState = 'unknown' }
    $relayState = [string](Get-WebRelayControlState).Data.state
    if ($relayState -cnotin 'unverified', 'switching', 'starting', 'running', 'retrying', 'disabled', 'failed', 'stopped') { $relayState = 'unknown' }
    $usage = Get-BridgeUsageMetrics

    return @{ ok = $true; data = [ordered]@{
            version = $script:BridgeVersion
            startedAt = ([datetimeoffset]$script:BridgeStartedAt).ToUnixTimeMilliseconds()
            publishedAt = ([datetimeoffset]$Now).ToUnixTimeMilliseconds()
            services = [ordered]@{
                telegramState = $telegramState
                telegramFailures = [int]$script:HealthHistory.Telegram.FailureCount
                cinegyState = $cinegyState; cinegyLastReadAt = $lastReadAt; cinegyFresh = $freshness.State -eq 'connected'
                outputMonitorState = $outputState; relayState = $relayState
                schedulePaused = (Get-Setting 'SchedulePaused') -eq $true
                quarantinedChats = [int]$script:DeadChats.Count
            }
            activity = [ordered]@{
                recentOperationsToday = [int]$usage.OperationsToday
                activeOperatorsToday = [int]$usage.ActiveOperators
                onAirLayers = [int]$usage.OnAirCount
                pendingRequests = [int]$script:PendingApprovals.Count
                scheduledEvents = @(Get-UpcomingScheduleEvents).Count
            }
            settings = @(Get-WebAdminSettingView)
        } }
}

$script:WebEngineHealthBaseline = $null

function Get-WebEngineHealth {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    if (-not (Get-Setting 'EnableEngineHealth')) {
        $script:WebEngineHealthBaseline = $null
        return @{ ok = $true; data = @{ enabled = $false } }
    }
    $tick = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($Deadline -gt 0 -and $tick -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    if ($tick -lt $script:WebLayerComparisonNextProbe) { return @{ ok = $false; error = 'layer_comparison_busy' } }
    try {
        $probe = Get-EngineHealthProbe -TimeoutSec 1 -Deadline $Deadline
    }
    finally {
        $script:WebLayerComparisonNextProbe = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }

    $telemetry = $probe.Telemetry
    $sampleCount = [int]$telemetry.SampleCount
    $hasSamples = $telemetry.Success -and $sampleCount -gt 0
    $health = if (-not $telemetry.Success) { 'unavailable' }
    elseif (-not $hasSamples) { 'no_samples' }
    elseif ($telemetry.Healthy -eq $false) { 'warning' }
    elseif ([long]$telemetry.NoInputSignal -gt 0) { 'no_input' }
    elseif ($telemetry.Healthy -eq $true) { 'healthy' }
    else { 'unavailable' }

    $license = 'unavailable'
    if ((Get-JsonProp $probe.Video 'Success') -and (Get-JsonProp $probe.Video 'License')) {
        $license = if ((Get-JsonProp $probe.Video 'License') -eq 'Licensed') { 'licensed' } else { 'warning' }
    }

    $dropped = [long]$telemetry.DroppedCount
    $increase = $null
    if ($hasSamples) {
        # Metrics is a rolling sample; its increase is only a comparison with the
        # previous Web sample. Keep it independent of the Bot's display baseline.
        $previous = $script:WebEngineHealthBaseline
        if ($previous -and $previous.Address -eq $config.AirServerAddress -and $previous.Channel -eq $config.AirChannelNumber -and
            $dropped -gt $previous.Dropped) {
            $increase = $dropped - $previous.Dropped
        }
        $script:WebEngineHealthBaseline = @{ Address = $config.AirServerAddress; Channel = $config.AirChannelNumber; Dropped = $dropped }
    }
    else { $script:WebEngineHealthBaseline = $null }

    $readTime = [double]$telemetry.AverageReadTime
    $readErrorRate = [double]$telemetry.MaxReadErrorRate
    return @{ ok = $true; data = @{
            enabled = $true
            checkedAtMs = [datetimeoffset]::Now.ToUnixTimeMilliseconds()
            elapsedMs = $probe.ElapsedMs
            health = $health
            license = $license
            sampleCount = if ($hasSamples) { $sampleCount } else { $null }
            outputFrames = if ($hasSamples) { [long]$telemetry.OutputCount } else { $null }
            droppedFrames = if ($hasSamples) { $dropped } else { $null }
            droppedSampleIncrease = $increase
            inputLossFrames = if ($hasSamples) { [long]$telemetry.NoInputSignal } else { $null }
            meanReadMs = if ($hasSamples -and [double]::IsFinite($readTime) -and $readTime -ge 0) { $readTime } else { $null }
            maxReadErrorPercent = if ($hasSamples -and [double]::IsFinite($readErrorRate) -and $readErrorRate -ge 0 -and $readErrorRate -le 100) { $readErrorRate } else { $null }
        } }
}
