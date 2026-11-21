function Get-WebOperationMetrics {
    param([System.Collections.IDictionary]$Arguments)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $metrics = Get-BridgeOperationMetrics
    $monitoring = $script:RuntimeState.Monitoring
    $telegram = [string]$monitoring.TelegramConnectionState
    $cinegy = [string]$monitoring.CinegyHealthState
    return @{ ok = $true; data = @{
            checkedAt = ([datetimeoffset]$metrics.Now).ToUnixTimeMilliseconds()
            startedAt = ([datetimeoffset]$metrics.StartedAt).ToUnixTimeMilliseconds()
            uptimeSeconds = [long][math]::Floor([math]::Max(0.0, $metrics.Uptime.TotalSeconds))
            state = $metrics.State
            airOperations = @{
                success = [int]$metrics.AirOperations.Success
                failed = [int]$metrics.AirOperations.Failed
                blocked = [int]$metrics.AirOperations.Blocked
            }
            telegramRateLimitHits = $metrics.TelegramRateLimitHits
            telegramOutboxDropped = $metrics.TelegramOutboxDropped
            telegramState = if ($telegram -cin @('connected', 'disconnected')) { $telegram } else { 'unknown' }
            cinegyState = if ($cinegy -cin @('healthy', 'unhealthy', 'unreachable')) { $cinegy } else { 'unknown' }
            lastHeartbeatDate = if ($metrics.LastHeartbeatDate -gt [datetime]::MinValue) {
                $metrics.LastHeartbeatDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            } else { $null }
            onAirCount = $metrics.OnAirCount
            # A rich-message heading can contain station or editorial text.
            richPayloadPeakPercent = if ($metrics.RichPayloadPeak.Length -gt 0) { [int]$metrics.RichPayloadPeak.Percent } else { $null }
        } }
}
