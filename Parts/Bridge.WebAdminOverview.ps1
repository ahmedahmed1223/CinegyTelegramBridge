#requires -Version 7

function Get-WebAdminSettingView {
    # Keep an explicit schema of safe scalars. Neither the full configuration
    # nor formatted diagnostic text is a suitable web response.
    $groups = [ordered]@{
        access = [ordered]@{
            EnableSelfServiceRequests = 'boolean'
            NotifyAdminsOnAccessRequest = 'boolean'
            AskRequesterName = 'boolean'
            BlockRejectedRequesters = 'boolean'
            MaxPendingApprovals = 'integer'
            PendingApprovalExpiryHours = 'integer'
        }
        air = [ordered]@{
            EnableTimedShow = 'boolean'
            ConfirmLayerRemoval = 'boolean'
            SchedulePaused = 'boolean'
            AutoHideDefaultSeconds = 'integer'
            PendingStateTimeoutMinutes = 'integer'
        }
        newsroom = [ordered]@{
            EnableUrgentBoard = 'boolean'
            MojazMultiDesign = 'boolean'
            EnableNewsTickerManagement = 'boolean'
            UrgentBoardMaxItems = 'integer'
            NewsMaxItems = 'integer'
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
                protected = $metadata.Protected
            }
        }
    }
    Get-WebAdminPresentationSettingView
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
