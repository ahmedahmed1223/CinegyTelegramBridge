#requires -Version 7
# Dot-sourced into the bridge scope. Web uses the same candidate and expiry as Telegram.
$script:WebAirRollbackReviews = @{}

function Initialize-WebRollbackProof {
    param([int]$Layer, [string]$CurrentKey, [long]$StartTicks, [switch]$ExactEvent, [switch]$RestoreUntimed)

    if (-not (Get-Setting 'EnableSafeRollback')) { return }
    $candidate = $script:RollbackCandidates[$Layer]
    if ($candidate) {
        $candidate.Web = @{
            Device = (Resolve-AirGfxDevice -Layer $Layer).StatusPath
            CurrentKey = $CurrentKey; StartTicks = $StartTicks
            ExactEvent = [bool]$ExactEvent; RestoreUntimed = [bool]$RestoreUntimed
        }
    }
}

function Test-WebRollbackUntimedSnapshot {
    param([int]$Layer, $Snapshot, $Status)
    $startedAt = Get-CinegyStatusStartTicks -Status $Status
    return ($null -ne $Snapshot -and (Get-JsonProp $Snapshot 'EventIdentityConfirmed') -eq $true -and
        $startedAt -gt 0 -and (Get-JsonProp $Snapshot 'EngineStartedAtTicks') -eq $startedAt -and
        (Get-JsonProp $Snapshot 'DevicePath') -ceq (Resolve-AirGfxDevice -Layer $Layer).StatusPath -and
        (Get-JsonProp $Snapshot 'AutoHideSeconds') -eq 0 -and
        -not @($script:AutoHideQueue | Where-Object { [int](Get-JsonProp $_ 'Layer') -eq $Layer }).Count)
}

function Get-WebPlainLocalFile {
    param([string]$Path)
    if (-not $Path -or -not [IO.Path]::IsPathFullyQualified($Path)) { return }
    try {
        # The bridge thread cannot wait for an offline network share to prove
        # that a previous file still has the reviewed contents.
        $root = [IO.Path]::GetPathRoot($path)
        if ($root -notmatch '^[A-Za-z]:[\\/]$' -or [IO.DriveInfo]::new($root).DriveType -ne [IO.DriveType]::Fixed) { return }
        $cursor = $root
        $file = $null
        foreach ($part in $path.Substring($root.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
            if ($part -in '.', '..') { return }
            $file = Get-Item -LiteralPath (Join-Path $cursor $part) -ErrorAction Stop
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
            $cursor = $file.FullName
        }
        if ($file -is [IO.FileInfo]) { return $file }
    }
    catch { return }
}

function Test-WebRollbackLocalScene {
    param($Template, $Restore)
    $path = [string](Get-JsonProp $Template 'Path')
    $ticks = [long](Get-JsonProp $Restore 'SceneWriteTicks')
    if (-not $ticks -or $path -cne [string](Get-JsonProp $Restore 'TemplatePath')) { return $false }
    $file = Get-WebPlainLocalFile -Path $path
    return ($null -ne $file -and $file.LastWriteTimeUtc.Ticks -eq $ticks)
}

function Get-WebRollbackDirectDevice {
    param([int]$Layer, [string]$ExpectedDevicePath)

    if ($Layer -le 0 -or $ExpectedDevicePath -cnotmatch '^gfx_([a-z0-9_]{1,32})$' -or
        [string](Get-Setting 'SceneMode') -ne 'Single') { return '' }
    $device = $Matches[1]
    if ((Resolve-AirGfxDevice -Layer $Layer).StatusPath -cne $ExpectedDevicePath) { return '' }

    $managedLayers = @($script:BoardsLive.Keys;
        $(if ($script:MojazPlayback) { Get-MojazRunLayer -Playback $script:MojazPlayback });
        [int](Get-JsonProp $script:UrgentBoardRun 'Layer'); (Get-SettingInt 'TemplateTestLayer' 0))
    foreach ($managedLayer in $managedLayers) {
        if ($managedLayer -gt 0 -and (Resolve-AirGfxDevice -Layer ([int]$managedLayer)).StatusPath -eq $ExpectedDevicePath) {
            return ''
        }
    }
    if (Test-PermanentGraphicAutoHideProtected -Layer $Layer) { return '' }
    return $device
}

function Get-WebRollbackContext {
    param([int]$Layer, [long]$Actor, [hashtable]$Templates)

    $candidate = Get-RollbackCandidate -Layer $Layer -UserId $Actor
    if (-not $candidate) { return @{ error = 'rollback_missing' } }
    $proof = Get-JsonProp $candidate 'Web'
    $restore = Get-JsonProp $candidate 'Restore'
    $currentKey = [string](Get-JsonProp $proof 'CurrentKey')
    $restoreKey = [string](Get-JsonProp $restore 'Key')
    $expected = [string](Get-JsonProp $candidate 'ExpectedState')
    $device = [string](Get-JsonProp $proof 'Device')
    $current = $Templates[$currentKey]
    $target = $Templates[$restoreKey]
    $clearing = (Get-JsonProp $restore 'Action') -eq 'hide'
    if (-not $device -or $device -cne (Resolve-AirGfxDevice -Layer $Layer).StatusPath -or
        -not $current -or -not $target -or [int]$current.Layer -ne $Layer -or [int]$target.Layer -ne $Layer -or
        $expected -cnotin 'hidden', 'replace' -or ($clearing -and $expected -ne 'replace')) {
        return @{ error = 'rollback_stale' }
    }
    if (-not (Test-TemplateAccess -Key $currentKey -Layer $Layer -ChatId $Actor -UserId $Actor).Allowed -or
        -not (Test-TemplateAccess -Key $restoreKey -Layer $Layer -ChatId $Actor -UserId $Actor).Allowed) {
        return @{ error = 'forbidden' }
    }

    if (-not (Get-WebRollbackDirectDevice -Layer $Layer -ExpectedDevicePath $device) -or
        $script:MojazTemplateKey -in $currentKey, $restoreKey -or $script:MojazUrgentKey -in $currentKey, $restoreKey -or
        (Get-JsonProp $current 'Bulletin') -or (Get-JsonProp $target 'Bulletin') -or
        (Test-PermanentGraphicAutoHideProtected -Layer $Layer) -or
        (Test-PermanentGraphicAutoHideProtected -Key $currentKey) -or (Test-PermanentGraphicAutoHideProtected -Key $restoreKey)) {
        return @{ error = 'rollback_managed' }
    }
    if ($expected -eq 'replace' -and (-not (Get-JsonProp $proof 'ExactEvent') -or
            [long](Get-JsonProp $proof 'StartTicks') -le 0 -or
            -not (Get-JsonProp $candidate 'ExpectedActiveId') -or
            [string](Get-JsonProp $script:OnAir[$Layer] 'Key') -cne $currentKey)) { return @{ error = 'rollback_unverified' } }

    if (-not $clearing) {
        $policy = Test-TemplateShowPolicy -Key $restoreKey -Layer $Layer -IsAdmin:(Test-Admin -ChatId $Actor -UserId $Actor)
        $savedRevision = [string](Get-JsonProp $restore 'TemplateRevision')
        if (($expected -eq 'replace' -and (Get-Setting 'ReshowClearsLayer')) -or
            (Get-EffectiveAutoHideSeconds -Key $restoreKey) -gt 0 -or
            -not $policy.Allowed -or -not (Get-JsonProp $proof 'RestoreUntimed') -or -not (Get-JsonProp $restore 'ActiveIdConfirmed') -or
            -not $savedRevision -or $savedRevision -cne [string](Get-JsonProp $target 'PresetRevision') -or
            [string](Get-JsonProp $restore 'TemplatePath') -cne [string]$target.Path) { return @{ error = 'rollback_unavailable' } }
    }
    $plan = @{
        layer = $Layer; action = if ($clearing) { 'clear' } else { 'restore' }
        templateKey = $restoreKey; expiresAt = ([datetimeoffset]$candidate.ExpiresAt).ToUnixTimeMilliseconds()
    }
    return @{ candidate = $candidate; plan = $plan; target = $target; proof = $proof }
}

function Invoke-WebAirRollback {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin 'list', 'preview', 'apply') { return @{ ok = $false; error = 'rollback_invalid' } }
    $stale = @{ ok = $false; error = 'rollback_stale' }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $templates = (Get-TemplateStore).Map
    if ($action -ceq 'list') {
        $candidates = @(foreach ($availableLayer in @($script:RollbackCandidates.Keys | Sort-Object)) {
                $context = Get-WebRollbackContext -Layer $availableLayer -Actor $actor -Templates $templates
                $listedPlan = Get-JsonProp $context 'plan'
                if ($listedPlan) { $listedPlan }
            })
        return @{ ok = $true; data = @{ candidates = $candidates } }
    }
    $layer = 0
    if (-not [int]::TryParse([string](Get-JsonProp $Arguments 'layer'), [ref]$layer) -or $layer -le 0) {
        return @{ ok = $false; error = 'rollback_invalid' }
    }
    $pending = if ($action -ceq 'apply') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAirRollbackReviews
    }
    if ($action -ceq 'apply' -and -not $pending) { return $stale }
    $context = Get-WebRollbackContext -Layer $layer -Actor $actor -Templates $templates
    $blocked = [string](Get-JsonProp $context 'error')
    if ($blocked) { return @{ ok = $false; error = $blocked } }
    if ($script:LayerLocks.ContainsKey($layer)) { return @{ ok = $false; error = 'rollback_busy' } }

    $candidate = $context.candidate
    $plan = $context.plan
    $clearing = $plan.action -eq 'clear'
    $scheduledKeys = @(Get-UpcomingScheduleEvents | ForEach-Object { [string](Get-JsonProp $_ 'TemplateKey') })
    $scheduledKeys += @($script:MojazSchedules | Where-Object { (Get-JsonProp $_ 'Status') -in 'scheduled', 'queued', 'running' } |
        ForEach-Object { Get-MojazRunDesignKey -Playback $_ })
    foreach ($scheduledKey in $scheduledKeys) {
        if (-not $scheduledKey -or -not $templates.ContainsKey($scheduledKey)) { continue }
        if ((Resolve-AirGfxDevice -Layer ([int]$templates[$scheduledKey].Layer)).StatusPath -eq $context.proof.Device) {
            return @{ ok = $false; error = 'rollback_scheduled' }
        }
    }
    if (-not $clearing -and -not (Test-WebRollbackLocalScene -Template $context.target -Restore $candidate.Restore)) {
        return @{ ok = $false; error = 'rollback_unverified' }
    }

    $status = Get-WebLayerStatus -Layer $layer
    $stamp = Get-CinegyLayerReviewStamp -Status $status
    if (-not $stamp) { return @{ ok = $false; error = 'rollback_unverified' } }
    $startedAt = if ($stamp -eq 'empty') { 0L } else { Get-CinegyStatusStartTicks -Status $status }
    $expectedStamp = if ($candidate.ExpectedState -eq 'hidden') { 'empty' }
    else { "active:$(([string]$candidate.ExpectedActiveId).Trim().Trim('{', '}').ToLowerInvariant())" }
    if ($stamp -cne $expectedStamp -or ($expectedStamp -ne 'empty' -and $startedAt -ne $context.proof.StartTicks)) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    $remaining = ([datetimeoffset]$candidate.ExpiresAt - [datetimeoffset]::Now).TotalSeconds
    if ($remaining -le 0) { return $stale }
    $executionDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
    if ($Deadline -gt 0) { $executionDeadline = [math]::Min($Deadline, $executionDeadline) }
    $fingerprint = ConvertTo-Json -Compress -InputObject @($candidate.Id, $layer, $plan.action, $context.proof.Device, $stamp, $startedAt)
    if ($action -ceq 'preview') {
        $plan.currentName = Get-NewsScreenLine ([string](Get-JsonProp $status 'ActiveName')) 100
        $plan.review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebAirRollbackReviews
        return @{ ok = $true; data = @{ preview = $plan } }
    }
    if ($pending.Fingerprint -cne $fingerprint) { return $stale }

    # Consume before dispatch. A timeout can mean Cinegy accepted the command
    # but the reply was lost, so the same candidate must never be sent twice.
    $script:RollbackCandidates.Remove($layer) | Out-Null
    $guard = @{
        ChatId = $actor; UserId = $actor; ExpectedLayerStamp = $stamp
        ExpectedLayerStartedAtTicks = $startedAt; Deadline = $executionDeadline
        ReviewedRollback = $true; ExpectedDevicePath = [string](Get-JsonProp (Get-JsonProp $candidate 'Web') 'Device')
    }
    if ($clearing) {
        if (-not (Invoke-HideLayer @guard -Layer $layer -Quiet)) { return @{ ok = $false; error = 'rollback_refused' } }
        $device = Get-WebRollbackDirectDevice -Layer $layer -ExpectedDevicePath $guard.ExpectedDevicePath
        $confirmed = $false
        if ($device) {
            $afterHide = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
                -Layer $layer -Device $device -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
            $confirmed = (Get-CinegyLayerReviewStamp -Status $afterHide) -ceq 'empty'
        }
    }
    else {
        $shown = Invoke-ShowTemplateResult @guard -Key $plan.templateKey -Variables ([hashtable]$candidate.Restore.Variables) `
            -ExpectedLayer $layer -ExpectedTemplatePath ([string]$context.target.Path) -RequireEventIdentity
        if (-not (Get-JsonProp $shown 'Success')) { return @{ ok = $false; error = 'rollback_refused' } }
        $confirmed = [bool](Get-JsonProp $shown 'EventIdentityConfirmed')
    }
    Add-AuditEntry (T 'flow.safeUndoAudit' $plan.templateKey $layer $(Format-UserAuditActor -UserId $actor))
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ sceneConfirmed = $confirmed } }
}
