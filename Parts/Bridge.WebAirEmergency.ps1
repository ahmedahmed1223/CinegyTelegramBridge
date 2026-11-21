#requires -Version 7
$script:WebAirMaintenanceReviews = @{}
$script:WebEmergencyHideReviews = @{}

function Get-WebAirMaintenanceState {
    $manual = [bool](Get-Setting 'MaintenanceMode')
    $window = [bool](Test-MaintenanceWindowActive)
    $starts = [string](Get-Setting 'MaintenanceWindowStart')
    $ends = [string](Get-Setting 'MaintenanceWindowEnd')
    return @{
        manualEnabled = $manual; windowActive = $window; effectiveBlocked = $manual -or $window
        windowStart = if ($starts -match '^(?:[01]\d|2[0-3]):[0-5]\d$') { $starts }
        windowEnd = if ($ends -match '^(?:[01]\d|2[0-3]):[0-5]\d$') { $ends }
    }
}

function Invoke-WebAirMaintenance {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-Admin -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin 'inspect', 'preview', 'apply') { return @{ ok = $false; error = 'maintenance_invalid' } }
    $maintenance = Get-WebAirMaintenanceState
    if ($action -ceq 'inspect') { return @{ ok = $true; data = @{ maintenance = $maintenance } } }
    $desired = Get-JsonProp $Arguments 'enabled'
    if ($desired -isnot [bool]) { return @{ ok = $false; error = 'maintenance_invalid' } }

    $stale = @{ ok = $false; error = 'maintenance_stale' }
    $pending = if ($action -ceq 'apply') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAirMaintenanceReviews
    }
    if ($action -ceq 'apply' -and -not $pending) { return $stale }
    if ($desired -eq $maintenance.manualEnabled) { return $stale }
    $fingerprint = ConvertTo-Json -Compress -InputObject @($maintenance.manualEnabled, $maintenance.windowActive,
        $maintenance.windowStart, $maintenance.windowEnd, $desired)
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    if ($action -ceq 'preview') {
        $maintenance.requestedEnabled = $desired
        $maintenance.effectiveAfter = $desired -or $maintenance.windowActive
        $maintenance.review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebAirMaintenanceReviews
        return @{ ok = $true; data = @{ maintenance = $maintenance } }
    }
    if ($pending.Fingerprint -cne $fingerprint) { return $stale }

    # Use the same config transaction as reviewed settings import, so an
    # unsuccessful save restores the prior in-memory control state as well.
    if (-not (Set-ImportedSettings -Changes @(@{ Name = 'MaintenanceMode'; From = $maintenance.manualEnabled; To = $desired }) -Deadline $Deadline)) {
        if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
        return @{ ok = $false; error = 'maintenance_save_failed' }
    }
    Add-AuditEntry (T 'cmd.settingAudit' 'MaintenanceMode' $desired $(Format-UserAuditActor -UserId $actor))
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ maintenance = Get-WebAirMaintenanceState } }
}

function Get-WebEmergencyHidePlan {
    param([long]$Actor, [bool]$AdminOverride, [long]$Deadline)

    $targets = [System.Collections.Generic.List[hashtable]]::new()
    $blocked = [System.Collections.Generic.List[int]]::new()
    $observed = [System.Collections.Generic.List[hashtable]]::new()
    $devices = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $layers = @(Get-HideAllTargetLayers | Sort-Object -Unique)
    $knownLayers = @((Get-KnownLayers); $script:OnAir.Keys; $layers) | Where-Object { $_ -gt 0 } | Sort-Object -Unique
    foreach ($layer in $layers) {
        if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ error = 'bridge_busy' } }
        $device = (Resolve-AirGfxDevice -Layer $layer).StatusPath
        if (-not $devices.Add($device)) { return @{ error = 'emergency_ambiguous' } }
        if (-not $AdminOverride -and -not (Test-TemplateAccess -Layer $layer -ChatId $Actor -UserId $Actor).Allowed) {
            $blocked.Add($layer)
            continue
        }
        $status = Get-WebLayerStatus -Layer $layer
        $stamp = Get-CinegyLayerReviewStamp -Status $status
        if (-not $stamp) { return @{ error = 'emergency_unverified' } }
        if ($stamp -eq 'empty') {
            $observed.Add(@{ layer = $layer; device = $device; stamp = $stamp; startedAt = 0 })
            continue
        }
        $startTicks = Get-CinegyStatusStartTicks -Status $status
        if ($startTicks -le 0) { return @{ error = 'emergency_unverified' } }
        if (-not $AdminOverride) {
            $record = $script:OnAir[$layer]
            $key = [string](Get-JsonProp $record 'Key')
            $knownId = ([string](Get-JsonProp $record 'ActiveId')).Trim().Trim('{', '}').ToLowerInvariant()
            $aliases = @($knownLayers | Where-Object {
                    $_ -ne $layer -and (Resolve-AirGfxDevice -Layer ([int]$_)).StatusPath -eq $device
                })
            if (-not $key -or -not $knownId -or $stamp -cne "active:$knownId" -or $aliases.Count -gt 0 -or
                -not (Test-TemplateAccess -Key $key -Layer $layer -ChatId $Actor -UserId $Actor).Allowed) {
                $blocked.Add($layer)
                continue
            }
        }
        $observed.Add(@{ layer = $layer; device = $device; stamp = $stamp; startedAt = $startTicks })
        $targets.Add(@{ layer = $layer; device = $device; stamp = $stamp; startedAt = $startTicks
                name = Get-NewsScreenLine ([string](Get-JsonProp $status 'ActiveName')) 100 })
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ error = 'bridge_busy' } }
    $proof = @(foreach ($item in $observed) { @($item.layer, $item.device, $item.stamp, $item.startedAt) | ConvertTo-Json -Compress })
    return @{
        targets = $targets.ToArray(); blocked = $blocked.ToArray()
        fingerprint = ConvertTo-Json -Compress -Depth 6 -InputObject @($AdminOverride, $layers, $proof, $blocked.ToArray())
    }
}

function Invoke-WebEmergencyHide {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $admin = Test-Admin -ChatId $actor -UserId $actor
    if (-not (Get-Setting 'EnableHideAll') -or -not (Test-MaintenanceControl -ChatId $actor -UserId $actor -EmergencyOverride:$admin)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin 'preview', 'apply') { return @{ ok = $false; error = 'emergency_invalid' } }
    if ([string](Get-Setting 'SceneMode') -ne 'Single') { return @{ ok = $false; error = 'emergency_ambiguous' } }
    $stale = @{ ok = $false; error = 'emergency_stale' }
    $pending = if ($action -ceq 'apply') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebEmergencyHideReviews
    }
    if ($action -ceq 'apply' -and -not $pending) { return $stale }
    $prepared = Get-WebEmergencyHidePlan -Actor $actor -AdminOverride $admin -Deadline $Deadline
    $problem = [string](Get-JsonProp $prepared 'error')
    if ($problem) { return @{ ok = $false; error = $problem } }
    if ($action -ceq 'preview') {
        $targets = @(foreach ($entry in $prepared.targets) { @{ layer = $entry.layer; name = $entry.name } })
        if (-not $targets.Count) { return @{ ok = $false; error = 'emergency_none' } }
        $token = New-WebAirReview -Actor $actor -Fingerprint $prepared.fingerprint -Reviews $script:WebEmergencyHideReviews
        return @{ ok = $true; data = @{ preview = @{ review = $token; targets = $targets; blockedLayers = $prepared.blocked } } }
    }
    if ($pending.Fingerprint -cne $prepared.fingerprint) { return $stale }

    $results = @(foreach ($entry in $prepared.targets) {
            $outcome = if (($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) -or
                $entry.device -cne (Resolve-AirGfxDevice -Layer $entry.layer).StatusPath) { 'skipped' }
            elseif (Invoke-HideLayer -Layer $entry.layer -ChatId $actor -UserId $actor -Quiet -System:$admin `
                -MaintenanceOverride:$admin -ExpectedDevicePath $entry.device -ExpectedLayerStamp $entry.stamp -ExpectedLayerStartedAtTicks $entry.startedAt `
                -Deadline $Deadline) { 'sent' }
            else { 'failed' }
            @{ layer = $entry.layer; status = $outcome }
        })
    Add-AuditEntry (T 'flow.hideAllAudit' $(Format-UserAuditActor -UserId $actor))
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ results = $results } }
}
