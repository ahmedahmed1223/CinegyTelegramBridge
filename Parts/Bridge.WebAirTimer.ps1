#requires -Version 7
$script:WebAirTimerReviews = @{}

function Test-WebAirTimerTarget {
    param([hashtable]$Timer, [AllowNull()]$LiveStatus = $null)

    $device = [string](Get-JsonProp $Timer 'ExpectedDevicePath')
    $startTicks = [long](Get-JsonProp $Timer 'ExpectedLayerStartedAtTicks')
    if (-not $device -and $startTicks -eq 0) { return $true }
    if (-not $device -or $startTicks -le 0 -or
        (Resolve-AirGfxDevice -Layer ([int](Get-JsonProp $Timer 'Layer'))).StatusPath -cne $device) { return $false }
    return ($null -eq $LiveStatus -or (Get-CinegyStatusStartTicks -Status $LiveStatus) -eq $startTicks)
}

function Invoke-WebAirTimer {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Get-Setting 'EnableTimedShow') -or -not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $layer = 0
    $invalid = @{ ok = $false; error = 'live_timer_invalid' }
    $stale = @{ ok = $false; error = 'live_timer_stale' }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    if ($action -cnotin 'inspect', 'preview', 'apply' -or
        -not [int]::TryParse([string](Get-JsonProp $Arguments 'layer'), [ref]$layer) -or $layer -le 0) { return $invalid }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $approved = if ($action -ceq 'apply') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAirTimerReviews
    }
    if ($action -ceq 'apply' -and -not $approved) { return $stale }

    $current = $script:OnAir[$layer]
    $snapshot = $script:LastSuccessfulLayerShows[$layer]
    $key = [string](Get-JsonProp $current 'Key')
    $template = if ($key) { (Get-TemplateStore).Map[$key] }
    if (-not $template -or [int]$template.Layer -ne $layer -or $key -cne [string](Get-JsonProp $snapshot 'Key')) { return $stale }
    if (-not (Test-TemplateAccess -Key $key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $device = (Resolve-AirGfxDevice -Layer $layer).StatusPath
    $managedLayers = @($script:BoardsLive.Keys; $(if ($script:MojazPlayback) { Get-MojazRunLayer -Playback $script:MojazPlayback });
        [int](Get-JsonProp $script:UrgentBoardRun 'Layer'); (Get-SettingInt 'TemplateTestLayer' 0))
    $managed = @($managedLayers | Where-Object {
            $_ -gt 0 -and (Resolve-AirGfxDevice -Layer ([int]$_)).StatusPath -eq $device
        }).Count -gt 0
    if ([string](Get-Setting 'SceneMode') -ne 'Single' -or $managed -or $key -in $script:MojazTemplateKey, $script:MojazUrgentKey -or
        (Get-JsonProp $template 'Bulletin') -or (Test-PermanentGraphicAutoHideProtected -Key $key -Layer $layer) -or
        (Test-PermanentGraphicAutoHideProtected -Layer $layer)) { return @{ ok = $false; error = 'live_timer_managed' } }

    $snapshotId = ([string](Get-JsonProp $snapshot 'ActiveId')).Trim().Trim('{', '}').ToLowerInvariant()
    $currentId = ([string](Get-JsonProp $current 'ActiveId')).Trim().Trim('{', '}').ToLowerInvariant()
    $snapshotStart = [long](Get-JsonProp $snapshot 'EngineStartedAtTicks')
    if (-not (Get-JsonProp $snapshot 'EventIdentityConfirmed') -or -not $snapshotId -or $snapshotId -cne $currentId -or
        $snapshotStart -le 0 -or $device -cne [string](Get-JsonProp $snapshot 'DevicePath')) {
        return @{ ok = $false; error = 'live_timer_unverified' }
    }
    $status = Get-WebLayerStatus -Layer $layer
    $stamp = Get-CinegyLayerReviewStamp -Status $status
    if (-not $stamp) { return @{ ok = $false; error = 'live_timer_unverified' } }
    if ($stamp -cne "active:$snapshotId" -or (Get-CinegyStatusStartTicks -Status $status) -ne $snapshotStart) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }

    $timers = @($script:AutoHideQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq $layer })
    if ($timers.Count -gt 1) { return @{ ok = $false; error = 'live_timer_unverified' } }
    $timer = $timers | Select-Object -First 1
    $timerDeadline = if ($timer) { [datetimeoffset](Get-JsonProp $timer 'At') }
    $timerId = if ($timer) { ([string]((Get-JsonProp $timer 'ActiveId') ?? '')).Trim().Trim('{', '}').ToLowerInvariant() } else { '' }
    $currentDeadline = if ($timerId -ceq $snapshotId) { $timerDeadline }
    $maxSeconds = Get-EffectiveAutoHideSeconds -Key $key
    $capAt = $null
    if ($maxSeconds -gt 0) {
        $shownAt = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string](Get-JsonProp $current 'At'), [ref]$shownAt)) {
            return @{ ok = $false; error = 'live_timer_unverified' }
        }
        $capAt = $shownAt.AddSeconds($maxSeconds)
    }
    $plan = @{
        layer = $layer; templateKey = $key; choices = @(Get-AutoHideChoices | Where-Object { $_ -gt 0 -and $_ -le 86400 })
        currentHideAt = if ($currentDeadline) { $currentDeadline.ToUnixTimeMilliseconds() }
        maximumHideAt = if ($capAt) { $capAt.ToUnixTimeMilliseconds() }
    }
    if ($action -ceq 'inspect') { return @{ ok = $true; data = @{ plan = $plan } } }

    $seconds = Get-JsonProp $Arguments 'seconds'
    $adjustment = Get-JsonProp $Arguments 'adjustSeconds'
    $now = [datetimeoffset]::Now
    $proposed = $null
    if ($null -ne $seconds -and $null -eq $adjustment) {
        if (($seconds -isnot [int] -and $seconds -isnot [long]) -or $seconds -lt 1 -or $seconds -gt 86400) { return $invalid }
        $proposed = $now.AddSeconds($seconds)
    }
    elseif ($null -ne $adjustment -and $null -eq $seconds) {
        if (($adjustment -isnot [int] -and $adjustment -isnot [long]) -or $adjustment -eq 0 -or
            $adjustment -lt -86400 -or $adjustment -gt 86400) { return $invalid }
        if (-not $currentDeadline -or $currentDeadline -le $now -or (Get-JsonProp $timer 'Stage') -eq 'offer') { return $stale }
        $proposed = $currentDeadline.AddSeconds($adjustment)
        if ($proposed -lt $now.AddSeconds(5)) { $proposed = $now.AddSeconds(5) }
        if ($proposed -gt $now.AddDays(1)) { return $invalid }
    }
    else { return $invalid }
    if ($capAt -and $proposed -gt $capAt) { $proposed = $capAt }
    if ($proposed -le $now) { return $stale }
    $timerSignature = if ($timer) {
        @($timerDeadline.ToString('o'), $timerId, (Get-JsonProp $timer 'TemplateKey'), (Get-JsonProp $timer 'UserId'),
            (Get-JsonProp $timer 'Stage'), (Get-JsonProp $timer 'Token'), (Get-JsonProp $timer 'RetryAt'),
            (Get-JsonProp $timer 'ExpectedDevicePath'), (Get-JsonProp $timer 'ExpectedLayerStartedAtTicks'))
    }
    $fingerprint = ConvertTo-Json -Compress -Depth 8 -InputObject @($key, $layer, $device, $stamp, $snapshotStart,
        $seconds, $adjustment, $plan.maximumHideAt, $timerSignature)
    if ($action -ceq 'preview') {
        $plan.review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebAirTimerReviews
        $script:WebAirTimerReviews[$actor].DeadlineAt = $proposed
        $plan.proposedHideAt = $proposed.ToUnixTimeMilliseconds()
        return @{ ok = $true; data = @{ plan = $plan } }
    }
    if ($approved.Fingerprint -cne $fingerprint -or $approved.DeadlineAt -le $now) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $remaining = [int][math]::Ceiling(($approved.DeadlineAt - $now).TotalSeconds)
    if (-not (Set-AutoHideTimer -Layer $layer -Seconds $remaining -ChatId $actor -UserId $actor -TemplateKey $key `
                -ActiveId ([string](Get-JsonProp $status 'ActiveId')) -ActiveIdConfirmed $true -Deadline $approved.DeadlineAt `
                -SingleSceneOnly -ExpectedDevicePath $device -ExpectedLayerStartedAtTicks $snapshotStart)) {
        return @{ ok = $false; error = 'live_timer_save_failed' }
    }
    Add-AuditEntry (T 'flow.timerAudit' $remaining $layer $(Format-UserAuditActor -UserId $actor))
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ hideAt = $approved.DeadlineAt.ToUnixTimeMilliseconds() } }
}
