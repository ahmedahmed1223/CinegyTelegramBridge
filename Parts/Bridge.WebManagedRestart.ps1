$script:ManagedRestartChannel = $null
$script:ManagedRestartOwnsMutex = $false
$script:ManagedRestartPending = $null
$script:ManagedRestartReviewExpiresAt = [datetimeoffset]::MinValue
$script:ManagedRestartExit = ''
$script:ManagedRestartReadySent = $false

function Initialize-ManagedRestartChannel {
    $pipeName = [Environment]::GetEnvironmentVariable('CGB_MANAGED_RESTART_PIPE')
    $pairing = [Environment]::GetEnvironmentVariable('CGB_MANAGED_RESTART_PAIRING')
    $requestId = [Environment]::GetEnvironmentVariable('CGB_MANAGED_RESTART_REQUEST')
    # External relay and capture programs must not inherit supervisor credentials.
    foreach ($name in 'CGB_MANAGED_RESTART_PIPE', 'CGB_MANAGED_RESTART_PAIRING', 'CGB_MANAGED_RESTART_REQUEST') {
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    if ($pipeName -cnotmatch '\ACinegyTelegramBridge\.ManagedRestart\.[a-f0-9]{32}\z' -or $pairing -notmatch '\A[a-f0-9]{64}\z') { return }
    $script:ManagedRestartChannel = @{
        PipeName = $pipeName; Pairing = $pairing
        Replacement = if ($requestId -cmatch '\A[a-f0-9]{32}\z') { $requestId } else { '' }
        ProofExpiresAt = [datetimeoffset]::UtcNow.AddMinutes(2)
    }
}

function Invoke-ManagedRestartSupervisor {
    param([string]$Action, [hashtable]$Arguments = @{})

    if (-not $script:ManagedRestartChannel -or -not $script:ManagedRestartOwnsMutex) {
        return @{ ok = $false; error = 'restart_unavailable' }
    }
    $pipe = $null
    $timeout = [Threading.CancellationTokenSource]::new([timespan]::FromMilliseconds(750))
    try {
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $script:ManagedRestartChannel.PipeName, 'InOut', 'Asynchronous')
        [void]$pipe.ConnectAsync($timeout.Token).GetAwaiter().GetResult()
        $encoding = [Text.UTF8Encoding]::new($false)
        $writer = [IO.StreamWriter]::new($pipe, $encoding, 4096, $true)
        $reader = [IO.StreamReader]::new($pipe, $encoding, $false, 4096, $true)
        $body = @{ action = $Action; pairing = $script:ManagedRestartChannel.Pairing } + $Arguments
        $json = ConvertTo-Json -InputObject $body -Compress -Depth 4
        [void]$writer.WriteLineAsync($json).WaitAsync($timeout.Token).GetAwaiter().GetResult()
        [void]$writer.FlushAsync($timeout.Token).GetAwaiter().GetResult()
        $line = $reader.ReadLineAsync($timeout.Token).AsTask().GetAwaiter().GetResult()
        if ($line -and $line.Length -lt 4096) { return ConvertFrom-Json -InputObject $line -AsHashtable }
    }
    catch { return @{ ok = $false; error = 'restart_unavailable' } }
    finally {
        if ($pipe) { $pipe.Dispose() }
        $timeout.Dispose()
    }
    return @{ ok = $false; error = 'restart_unavailable' }
}

function Get-ManagedRestartRevision {
    # The manager only needs an opaque revision. Keep scene identifiers on the
    # bridge and invalidate the review when the recorded on-air set changes.
    $scenes = @(foreach ($layer in @($script:OnAir.Keys | Sort-Object)) {
            $entry = $script:OnAir[$layer]
            [ordered]@{ layer = $layer; key = Get-JsonProp $entry 'Key'; at = Get-JsonProp $entry 'At'; id = Get-JsonProp $entry 'ActiveId' }
        })
    $revision = [ordered]@{
        startedAt = $script:BridgeStartedAt; scenes = $scenes; relayRequired = [bool]$script:RelayState.ShouldRun
        bulletinRunning = [bool]$script:MojazPlayback; urgentRunning = [bool]$script:UrgentBoardRun
        scheduledPaused = [bool](Get-Setting 'SchedulePaused'); maintenance = [bool](Get-Setting 'MaintenanceMode')
    }
    $state = ConvertTo-Json -InputObject $revision -Depth 5 -Compress
    return [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($script:ManagedRestartChannel.Pairing), [Text.Encoding]::UTF8.GetBytes($state)))
}

function Test-ManagedRestartActor {
    param([long]$Actor)
    return $Actor -gt 0 -and (Test-Authorized -ChatId $Actor -UserId $Actor) -and (Test-Admin -ChatId $Actor -UserId $Actor)
}

function Test-WebManagedRestartBusy {
    if ($script:ManagedRestartPending -or [datetimeoffset]::UtcNow -lt $script:ManagedRestartReviewExpiresAt) { return $true }
    if (-not $script:ManagedRestartChannel -or -not $script:ManagedRestartOwnsMutex) { return $false }
    $probe = Invoke-ManagedRestartSupervisor -Action probe
    return (Get-JsonProp $probe 'ok') -eq $true -and (Get-JsonProp $probe 'state') -in 'busy', 'stalled'
}

function Test-WebManagedRestartRelayActive {
    # The normal shutdown stops relay and a replacement does not resume it.
    if ($script:RelayState.ShouldRun) { return $true }
    try { return [bool](Get-RunningRelayProcess -ReadOnly) }
    catch { return $true }
}

function Invoke-WebManagedRestart {
    param([string]$Action, [System.Collections.IDictionary]$Arguments)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or
        -not (Test-ManagedRestartActor -Actor $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $session = [string](Get-JsonProp $Arguments 'session')
    if ($session -notmatch '\A[a-f0-9]{64}\z') { return @{ ok = $false; error = 'restart_invalid' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    if ($Action -ne 'reserve' -and $id -cnotmatch '\A[a-f0-9]{32}\z') { return @{ ok = $false; error = 'restart_invalid' } }
    if ($Action -in 'reserve', 'confirm', 'ack') {
        if (-not (Get-Setting 'AllowRemoteRestart') -or $script:RestartRequested) {
            return @{ ok = $false; error = 'restart_unavailable' }
        }
        if (Test-WebManagedRestartRelayActive) { return @{ ok = $false; error = 'restart_relay_active' } }
    }
    if (-not $script:ManagedRestartChannel -or -not $script:ManagedRestartOwnsMutex) {
        return @{ ok = $false; error = 'restart_unavailable' }
    }

    $wire = @{ actor = $actor; session = $session; id = $id; revision = Get-ManagedRestartRevision }
    if ($Action -eq 'ack') {
        $receipt = [string](Get-JsonProp $Arguments 'receipt')
        if ($receipt -cnotmatch '\A[a-f0-9]{32}\z') { return @{ ok = $false; error = 'restart_invalid' } }
        $wire.receipt = $receipt
    }
    $reply = Invoke-ManagedRestartSupervisor -Action $Action -Arguments $wire
    if ((Get-JsonProp $reply 'ok') -ne $true) { return @{ ok = $false; error = [string](Get-JsonProp $reply 'error') } }

    if ($Action -eq 'reserve') { $script:ManagedRestartReviewExpiresAt = [datetimeoffset]::UtcNow.AddSeconds(90) }
    elseif ($Action -eq 'cancel') { $script:ManagedRestartReviewExpiresAt = [datetimeoffset]::MinValue }
    if ($Action -eq 'ack') {
        # This is only recorded consent. Actual exit needs a distinct Manager
        # grant when the poll loop reaches its stable boundary.
        $script:ManagedRestartPending = @{
            Actor = $actor; Session = $session; Id = $id; Revision = $wire.revision; ExpiresAt = [datetimeoffset]::UtcNow.AddSeconds(90)
        }
    }

    return @{ ok = $true; data = @{
            id = [string](Get-JsonProp $reply 'id')
            state = [string](Get-JsonProp $reply 'state')
            receipt = [string](Get-JsonProp $reply 'receipt')
            activeScenes = $script:OnAir.Count
        } }
}

function Complete-ManagedRestartAtPollBoundary {
    $pending = $script:ManagedRestartPending
    if (-not $pending) { return }
    $cancel = if ($script:RestartRequested -or [datetimeoffset]::UtcNow -ge $pending.ExpiresAt -or
        -not (Get-Setting 'AllowRemoteRestart') -or -not (Test-ManagedRestartActor -Actor $pending.actor)) { 'cancel' }
    elseif (Test-WebManagedRestartRelayActive) { 'relay-active' }
    elseif ($pending.revision -cne (Get-ManagedRestartRevision)) { 'cancel' }
    if ($cancel) {
        $declined = Invoke-ManagedRestartSupervisor -Action $cancel -Arguments $pending
        if ((Get-JsonProp $declined 'error') -ceq 'restart_unavailable' -and [datetimeoffset]::UtcNow -lt $pending.ExpiresAt) { return }
        $script:ManagedRestartPending = $null
        $script:ManagedRestartReviewExpiresAt = [datetimeoffset]::MinValue
        return
    }
    $reply = Invoke-ManagedRestartSupervisor -Action grant -Arguments $pending
    if ((Get-JsonProp $reply 'error') -ceq 'restart_unavailable') { return }
    $script:ManagedRestartPending = $null
    if ((Get-JsonProp $reply 'ok') -ne $true -or (Get-JsonProp $reply 'state') -cne 'granted') { return }
    $script:ManagedRestartExit = $pending.id
    $script:RestartSelfRelaunch = $false
    $script:RestartRequested = $true
    Write-BridgeLog 'Managed Web restart granted. Leaving the polling loop.' 'WARN'
    Add-AuditEntry (T 'hlth.restartAudit' $(Format-UserAuditActor -UserId $pending.actor)) | Out-Null
}

function Send-ManagedRestartCleanup {
    if ($script:ManagedRestartExit) {
        Invoke-ManagedRestartSupervisor -Action cleanup -Arguments @{ id = $script:ManagedRestartExit } | Out-Null
    }
}

function Send-ManagedReplacementReady {
    if ($script:ManagedRestartReadySent -or -not $script:ManagedRestartChannel -or -not $script:ManagedRestartChannel.Replacement -or
        [datetimeoffset]::UtcNow -ge $script:ManagedRestartChannel.ProofExpiresAt) { return }
    $reply = Invoke-ManagedRestartSupervisor -Action ready -Arguments @{ id = $script:ManagedRestartChannel.Replacement }
    $script:ManagedRestartReadySent = (Get-JsonProp $reply 'ok') -eq $true -and (Get-JsonProp $reply 'state') -ceq 'running'
}
