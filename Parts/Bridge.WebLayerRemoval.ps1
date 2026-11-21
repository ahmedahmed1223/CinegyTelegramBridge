#requires -Version 7

$script:WebLayerRemovalReviews = @{}

function Invoke-WebLayerRemoval {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    $operation = [string](Get-JsonProp $Arguments 'operation')
    $layer = 0
    if ($action -cnotin 'preview', 'apply' -or $operation -cnotin 'hide', 'exit' -or
        -not [int]::TryParse([string](Get-JsonProp $Arguments 'layer'), [ref]$layer) -or $layer -le 0) {
        return @{ ok = $false; error = 'layer_removal_invalid' }
    }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $stale = @{ ok = $false; error = 'layer_removal_stale' }
    $approval = if ($action -ceq 'apply') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebLayerRemovalReviews
    }
    if ($action -ceq 'apply' -and -not $approval) { return $stale }
    if ([string](Get-Setting 'SceneMode') -ne 'Single') { return @{ ok = $false; error = 'layer_removal_ambiguous' } }

    $record = $script:OnAir[$layer]
    $key = [string](Get-JsonProp $record 'Key')
    if (-not (Test-TemplateAccess -Key $key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $unverified = @{ ok = $false; error = 'layer_removal_unverified' }
    $tracked = Get-LayerRemovalFingerprint -Layer $layer
    $eventId = ([string](Get-JsonProp $record 'ActiveId')).Trim().Trim('{', '}').ToLowerInvariant()
    if (-not $tracked -or -not $key -or -not $eventId) { return $unverified }

    $physical = [string](Resolve-AirGfxDevice -Layer $layer).StatusPath
    if ($physical -cnotmatch '^gfx_([a-z0-9_]{1,32})$') { return $unverified }
    $device = $Matches[1]
    foreach ($other in @(Get-KnownLayers; $script:OnAir.Keys)) {
        if ($other -gt 0 -and $other -ne $layer -and (Resolve-AirGfxDevice -Layer ([int]$other)).StatusPath -ceq $physical) {
            return @{ ok = $false; error = 'layer_removal_ambiguous' }
        }
    }
    $live = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $layer `
        -Device $device -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    $stamp = Get-CinegyLayerReviewStamp -Status $live
    $started = Get-CinegyStatusStartTicks -Status $live
    if (-not $stamp -or $started -le 0) { return $unverified }
    if ($stamp -cne "active:$eventId" -or (Resolve-AirGfxDevice -Layer $layer).StatusPath -cne $physical) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $fingerprint = ConvertTo-Json -Compress -InputObject @($operation, $layer, $physical, $stamp, $started, $tracked,
        [string]$config.AirServerAddress, [int]$config.AirChannelNumber)
    if ($action -ceq 'preview') {
        $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebLayerRemovalReviews
        $review = $script:WebLayerRemovalReviews[$actor]
        $maximumExpiry = [datetimeoffset]::UtcNow.AddMinutes(2)
        if ($review.ExpiresAt -gt $maximumExpiry) { $review.ExpiresAt = $maximumExpiry }
        return @{ ok = $true; data = @{ preview = @{
            review = $token; layer = $layer; operation = $operation; templateKey = $key
            expiresAt = $review.ExpiresAt.ToUnixTimeMilliseconds()
        } } }
    }
    if ($approval.Fingerprint -cne $fingerprint) { return $stale }
    $remaining = ($approval.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
    if ($remaining -le 0) { return $stale }
    $dispatchDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
    if ($Deadline -gt 0) { $dispatchDeadline = [math]::Min($Deadline, $dispatchDeadline) }
    $reviewed = @{
        Layer = $layer; ChatId = $actor; UserId = $actor; Quiet = $true
        ExpectedLayerStamp = $stamp; ExpectedLayerStartedAtTicks = $started
        ExpectedDevicePath = $physical; Deadline = $dispatchDeadline
    }
    $sent = if ($operation -ceq 'hide') { Invoke-HideLayer @reviewed -CaptureRollback }
    else { Invoke-ExitLayer @reviewed }
    if (-not $sent) { return @{ ok = $false; error = 'layer_removal_refused' } }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ sent = $true } }
}
