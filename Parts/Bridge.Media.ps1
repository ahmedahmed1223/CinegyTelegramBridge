#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-LiveStreamConfig {
    <# Ensures $config.LiveStream exists and returns it. Fields: SourceType
       (m3u8|hls|srt|ndi), SourceUrl, RtmpDestination (Telegram's
       rtmp://.../key, set from chat), VideoBitrateKbps, CopyCodec ($true to
       pass through with -c copy instead of re-encoding - far lighter on the
       playout box's CPU when the source is already H.264/AAC). #>
    $ls = Get-JsonProp $config 'LiveStream'
    if (-not $ls) {
        $ls = [pscustomobject]@{ SourceType = 'm3u8'; SourceUrl = ''; RtmpDestination = ''; VideoBitrateKbps = 2500; CopyCodec = $false }
        $config | Add-Member -NotePropertyName LiveStream -NotePropertyValue $ls -Force
    }
    return $ls
}

function Get-BackupLiveStreamConfig {
    <# Returns the optional standby input without changing the configured
       primary source. An empty BackupSourceUrl explicitly disables failover. #>
    $primary = Get-LiveStreamConfig
    $backupUrl = [string](Get-JsonProp $primary 'BackupSourceUrl')
    if ([string]::IsNullOrWhiteSpace($backupUrl)) { return $null }
    $backupType = [string](Get-JsonProp $primary 'BackupSourceType')
    if ([string]::IsNullOrWhiteSpace($backupType)) { $backupType = 'srt' }
    return [pscustomobject]@{
        SourceType = $backupType
        SourceUrl = $backupUrl
        RtmpDestination = [string](Get-JsonProp $primary 'RtmpDestination')
        VideoBitrateKbps = Get-JsonProp $primary 'VideoBitrateKbps'
        CopyCodec = Get-JsonProp $primary 'CopyCodec'
    }
}

function Get-ActiveLiveStreamConfig {
    $primary = Get-LiveStreamConfig
    if (-not $script:OutputMonitorFallbackActive) { return $primary }
    $backup = Get-BackupLiveStreamConfig
    if ($backup) { return $backup }
    return $primary
}

function Get-SnapshotSourceLabel {
    param([Parameter(Mandatory)][bool]$SourceIsPrimary)
    if ($SourceIsPrimary) { return (T 'media.primary') }
    return (T 'media.backup')
}

function Set-OutputMonitorFallbackActive {
    param([Parameter(Mandatory)][bool]$Active)
    if ($script:OutputMonitorFallbackActive -eq $Active) { return $false }
    if ($Active -and -not (Get-BackupLiveStreamConfig)) { return $false }
    $script:OutputMonitorFallbackActive = $Active

    # A relay process receives its input only when it starts, so an active
    # relay must be relaunched for the source selection to take effect.
    if ($script:RelayState.ShouldRun) {
        $running = Get-RunningRelayProcess
        if ($running) { Stop-Process -Id $running.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $relayPidFile -Force -ErrorAction SilentlyContinue
        $script:RelayState.Process = $null
        try {
            Start-RelayProcess | Out-Null
            $script:RelayState.Restarts = 0
            $script:RelayState.VerifyAt = (Get-Date).AddSeconds(3)
            $script:RelayState.NotifyChatId = 0
        }
        catch {
            # A manual start failure is final. A failed automatic attempt keeps
            # ShouldRun set so the watchdog can spend the remaining retry budget.
            if ($notify) { $script:RelayState.ShouldRun = $false }
            Write-BridgeLog "Live relay source switch failed: $(Protect-SensitiveText $_.Exception.Message)" 'ERROR'
            Send-AdminBroadcast -Text (T 'media.restartFailed') -Urgent
        }
    }
    return $true
}

function Get-FfmpegPath {
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe",
            "$env:ProgramData\chocolatey\bin\ffmpeg.exe",
            (Join-Path $scriptRoot "ffmpeg.exe")
        )) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function ConvertTo-ProcessArgumentLine {
    <# Start-Process -ArgumentList joins an array with spaces and does NOT quote
       elements that contain spaces. With a script path like
       "D:\cingy cg\...\snapshot.jpg" ffmpeg then receives "D:\cingy" as the
       output filename and dies with "Invalid argument" (exit -22). Every
       external process launch therefore goes through this, which applies the
       standard Windows argv quoting rules. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    return ConvertTo-BridgeProcessArgumentLine -Arguments $Arguments
}

function Test-MediaSourceUnreachable {
    <# ffmpeg failing because the stream host is down is not the bridge
       failing, and logging it as an error buries the failures that are. The
       reason line ffmpeg prints is the only thing that tells them apart. #>
    param([string]$Detail)
    if ([string]::IsNullOrWhiteSpace($Detail)) { return $false }
    return [bool]($Detail -match 'Error opening input|Server returned|Connection refused|Connection timed out|No route to host|not known|Invalid data found|HTTP error')
}

function Get-LastErrorLine {
    <# Surfaces the tail of an ffmpeg stderr file so the operator sees the real
       reason in Telegram instead of a bare exit code. #>
    param([Parameter(Mandatory)][string]$Path, [int]$MaxLength = 250)
    if (-not (Test-Path $Path)) { return '' }
    try {
        $lines = @(Get-Content -Path $Path -ErrorAction Stop | Where-Object { $_ -and $_.Trim() })
        if ($lines.Count -eq 0) { return '' }
        $text = Protect-SensitiveText ((@($lines | Select-Object -Last 2) -join ' | ').Trim())
        if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + '…' }
        return $text
    }
    catch { return '' }
}

function Get-FfmpegInputArguments {
    param([Parameter(Mandatory)][string]$SourceType, [Parameter(Mandatory)][string]$SourceUrl, [switch]$Realtime)
    return Get-BridgeFfmpegInputArguments -SourceType $SourceType -SourceUrl $SourceUrl -Realtime:$Realtime
}

function Start-SnapshotJob {
    <# Kicks off a one-frame ffmpeg grab and returns immediately. The result is
       delivered later by Update-SnapshotJobs. Within SnapshotCooldownSeconds
       the previous frame is re-sent instead of spawning ffmpeg again - but
       that check is keyed off LastSnapshotAt, which Update-SnapshotJobs only
       sets once a job *finishes*. A burst of taps inside the capture window
       (SnapshotTimeoutSeconds, a few seconds) would all pass the cooldown
       check and each spawn their own ffmpeg against the live source, from
       any allowlisted account - not just an admin. The in-flight guard below
       catches exactly that gap: at most one capture runs at a time. #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        # 'clip' asks ffmpeg for seconds instead of one frame and sends the
        # result as video. Everything else about the job is the same, which
        # is why it is a parameter rather than a second function.
        [ValidateSet('photo', 'clip')][string]$Kind = 'photo'
    )
    if ($UserId -eq 0) { $UserId = $ChatId }

    if (-not (Get-Setting 'EnableSnapshot')) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.snapshotsDisabled') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    # A clip is never re-sent from the cache. A still from ten seconds ago
    # still answers "what is on screen"; a clip from ten seconds ago
    # answers a question about a moment that has passed.
    $cooldown = if ($Kind -eq 'clip') { 0 } else { Get-SettingInt 'SnapshotCooldownSeconds' 0 }
    if ($cooldown -gt 0 -and $script:LastSnapshotFile -and (Test-Path $script:LastSnapshotFile) -and
        ((Get-Date) - $script:LastSnapshotAt).TotalSeconds -lt $cooldown) {
        Send-TelegramPhoto -ChatId $ChatId -FilePath $script:LastSnapshotFile `
            -Caption (T 'media.lastSnapshot' $([int]((Get-Date) - $script:LastSnapshotAt).TotalSeconds) $(Get-SnapshotSourceLabel -SourceIsPrimary $script:LastSnapshotSourceIsPrimary)) `
            -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    if ($script:SnapshotJobs.Count -gt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.snapshotBusy') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $ls = Get-ActiveLiveStreamConfig
    $sourceUrl = [string]$ls.SourceUrl
    if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.sourceUrlUnset') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $ffmpeg = Get-FfmpegPath
    if (-not $ffmpeg) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.ffmpegMissing') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try {
        $inputArgs = @(Get-FfmpegInputArguments -SourceType ([string]$ls.SourceType) -SourceUrl $sourceUrl)
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $extension = if ($Kind -eq 'clip') { 'mp4' } else { 'jpg' }
    $outPath = Join-Path $logDir "snapshot-$stamp.$extension"
    # Per-job stderr file: a shared one would race between concurrent captures
    # and report the wrong error back to the wrong operator.
    $errLog = Join-Path $logDir "snapshot-$stamp.err"
    $timeout = Get-SettingInt 'SnapshotTimeoutSeconds' 3
    $clipSeconds = [math]::Max(1, (Get-SettingInt 'ClipSeconds' 1))

    $processArguments = if ($Kind -eq 'clip') {
        # Copied, not re-encoded: the gallery machine is running playout
        # and has no cycles to spare for an x264 pass nobody asked for.
        # faststart moves the index to the front so Telegram can begin
        # playing before the whole file has arrived.
        @('-y', '-loglevel', 'error') + $inputArgs +
        @('-t', "$clipSeconds", '-c', 'copy', '-movflags', '+faststart', $outPath)
    }
    else { @('-y', '-loglevel', 'error') + $inputArgs + @('-frames:v', '1', '-q:v', '2', $outPath) }
    # A clip cannot finish before its own length, so the deadline is that
    # plus the time the source takes to open - which on an HLS feed here
    # was measured at five to ten seconds.
    if ($Kind -eq 'clip') { $timeout = $clipSeconds + ($timeout * 3) }
    try {
        $proc = Start-BridgeMediaProcess -FilePath $ffmpeg -Arguments $processArguments `
            -WorkingDirectory $scriptRoot -StandardErrorPath $errLog
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.ffmpegFailed' $(Protect-SensitiveText $_.Exception.Message)) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $script:SnapshotJobs.Add(@{
            Proc = $proc; ChatId = $ChatId; UserId = $UserId; OutPath = $outPath; ErrLog = $errLog
            Kind = $Kind
            SourceIsPrimary = (-not $script:OutputMonitorFallbackActive)
            Deadline = (Get-Date).AddSeconds($timeout)
        })
    Send-TelegramMessage -ChatId $ChatId -Text $(if ($Kind -eq 'clip') { (T 'media.recording' $clipSeconds) } else { (T 'media.grabbing') })
}

function Update-SnapshotJobs {
    <# Polled from Invoke-BridgeTick. Delivers finished snapshots and kills
       ones that overran their deadline. #>
    if ($script:SnapshotJobs.Count -eq 0) { return }
    $done = @()
    $retryRequests = @()
    foreach ($job in $script:SnapshotJobs) {
        $expired = (Get-Date) -gt $job.Deadline
        if (-not $job.Proc.HasExited -and -not $expired) { continue }

        $failed = $false
        if (-not $job.Proc.HasExited) {
            Stop-Process -Id $job.Proc.Id -Force -ErrorAction SilentlyContinue
            Remove-Item $job.OutPath -Force -ErrorAction SilentlyContinue
            $failed = $true
            $script:LastCaptureErrorDetail = (T 'media.grabTimedOut')
            $msg = (T 'media.grabTimedOutMsg')
        }
        elseif ($job.Proc.ExitCode -ne 0 -or -not (Test-Path $job.OutPath)) {
            $detail = Get-LastErrorLine -Path $job.ErrLog
            $script:LastCaptureErrorDetail = $detail
            $level = if (Test-MediaSourceUnreachable -Detail $detail) { 'WARN' } else { 'ERROR' }
            Write-BridgeLog "Snapshot ffmpeg failed (exit $($job.Proc.ExitCode)): $detail" $level
            $msg = (T 'media.captureFailed' $($job.Proc.ExitCode))
            if ($detail) { $msg += (T 'media.ffmpegReason' $detail) }
            # Clean up the partial/zero-byte output ffmpeg may have left behind.
            Remove-Item $job.OutPath -Force -ErrorAction SilentlyContinue
            $failed = $true
        }

        if ($failed) {
            $backup = Get-BackupLiveStreamConfig
            if ($job.SourceIsPrimary -and $backup -and (Set-OutputMonitorFallbackActive -Active $true)) {
                # The operator asked for a picture, so do not make them wait for
                # the hourly watchdog. Retry this same request from Cinegy's
                # standby input after switching the active source.
                $retryRequests += ,@{ ChatId = $job.ChatId; UserId = $job.UserId; Kind = [string]$job.Kind }
                Send-TelegramMessage -ChatId $job.ChatId -Text (T 'media.tryingBackup')
            }
            else {
                Send-TelegramMessage -ChatId $job.ChatId -Text $msg -ReplyMarkup (Get-MainMenuKeyboard -ChatId $job.ChatId -UserId $job.UserId)
            }
        }
        elseif ([string]$job.Kind -eq 'clip') {
            $sourceLabel = Get-SnapshotSourceLabel -SourceIsPrimary ([bool]$job.SourceIsPrimary)
            Write-BridgeLog "User $($job.UserId) recorded a clip from $sourceLabel"
            Add-AuditEntry (T 'media.clipAudit' $(Format-UserAuditActor -UserId ([long]$job.UserId)))
            Send-TelegramVideo -ChatId $job.ChatId -FilePath $job.OutPath `
                -Caption (T 'media.clipOfAir' $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $sourceLabel) `
                -ReplyMarkup (Get-MainMenuKeyboard -ChatId $job.ChatId -UserId $job.UserId)
            # Not kept: the cooldown cache is for stills, and a clip is
            # megabytes that answer a question already answered.
            Remove-Item $job.OutPath -Force -ErrorAction SilentlyContinue
        }
        else {
            # Retain only the newest frame for the cooldown cache.
            if ($script:LastSnapshotFile -and $script:LastSnapshotFile -ne $job.OutPath) {
                Remove-Item $script:LastSnapshotFile -Force -ErrorAction SilentlyContinue
            }
            $script:LastSnapshotFile = $job.OutPath
            $script:LastSnapshotAt = Get-Date
            $script:LastCaptureErrorDetail = ''
            $script:LastSnapshotSourceIsPrimary = [bool]$job.SourceIsPrimary
            $sourceLabel = Get-SnapshotSourceLabel -SourceIsPrimary ([bool]$job.SourceIsPrimary)
            Write-BridgeLog "User $($job.UserId) captured a stream snapshot from $sourceLabel"
            Add-AuditEntry (T 'media.snapshotAudit' $(Format-UserAuditActor -UserId ([long]$job.UserId)))
            Send-TelegramPhoto -ChatId $job.ChatId -FilePath $job.OutPath `
                -Caption (T 'media.snapshotOfAir' $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $sourceLabel) `
                -ReplyMarkup (Get-MainMenuKeyboard -ChatId $job.ChatId -UserId $job.UserId)
        }
        Remove-Item $job.ErrLog -Force -ErrorAction SilentlyContinue
        $done += $job
    }
    foreach ($job in $done) { $script:SnapshotJobs.Remove($job) | Out-Null }
    foreach ($request in $retryRequests) {
        $kind = if ($request.Kind) { [string]$request.Kind } else { 'photo' }
        Start-SnapshotJob -ChatId $request.ChatId -UserId $request.UserId -Kind $kind
    }
}

function Test-PrimaryMonitorSourceBack {
    <#
        Asks the primary source directly, while the standby is the one in use.

        Without this the monitor read a successful grab from the standby as
        proof that the primary had recovered, and announced a return that
        nobody had tested - the two sources are different addresses and only
        one of them was ever asked.
    #>
    param([int]$TimeoutSeconds = 8)
    $wasFallback = $script:OutputMonitorFallbackActive
    try {
        # Asked as the primary for the length of one grab, then put back
        # exactly as it was whatever the answer is.
        $script:OutputMonitorFallbackActive = $false
        $path = Get-MonitorFrame -TimeoutSeconds $TimeoutSeconds
        if ($path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; return $true }
        return $false
    }
    finally { $script:OutputMonitorFallbackActive = $wasFallback }
}

function Get-MonitorFrame {
    <# Grabs one frame synchronously for the black-output monitor.

       Deliberately synchronous, unlike the operator snapshot: this runs on a
       timer nobody is waiting on, once an hour, and bounding it with a short
       timeout is simpler than threading another async job through the tick.
       Returns the file path, or $null with the reason logged. #>
    param([int]$TimeoutSeconds = 8)
    $ls = Get-LiveStreamConfig
    $sourceUrl = [string]$ls.SourceUrl
    if ([string]::IsNullOrWhiteSpace($sourceUrl)) { return $null }
    $ffmpeg = Get-FfmpegPath
    if (-not $ffmpeg) { return $null }

    # The watchdog counts consecutive failures and alerts at its threshold, so
    # once the source is known down a line per attempt adds nothing: an hour of
    # 5XX from the stream host filled the log with twenty identical warnings.
    $note = { param([string]$Text) if ($script:OutputMonitorFailureCount -le 0) { Write-BridgeLog $Text 'WARN' } }

    $stamp = "monitor-$([guid]::NewGuid().ToString('N'))"
    $outPath = Join-Path $script:logDir "$stamp.jpg"
    $errLog = Join-Path $script:logDir "$stamp.err"
    try {
        $inputArgs = @(Get-FfmpegInputArguments -SourceType ([string]$ls.SourceType) -SourceUrl $sourceUrl)
        $proc = Start-BridgeMediaProcess -FilePath $ffmpeg `
            -Arguments (@('-y', '-loglevel', 'error') + $inputArgs + @('-frames:v', '1', '-q:v', '5', $outPath)) `
            -WorkingDirectory $scriptRoot -StandardErrorPath $errLog
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $script:LastCaptureErrorDetail = (T 'media.captureTimedOut' $(Get-ArabicCountNoun -Count $TimeoutSeconds -One 'ثانية' -Two 'ثانيتان' -Few 'ثوانٍ' -Many 'ثانية' -EnglishOne 'second' -EnglishMany 'seconds'))
            & $note "Output monitor capture timed out after ${TimeoutSeconds}s"
            return $null
        }
        if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
            $script:LastCaptureErrorDetail = Get-LastErrorLine -Path $errLog
            & $note "Output monitor capture failed (exit $($proc.ExitCode)): $script:LastCaptureErrorDetail"
            return $null
        }
        return $outPath
    }
    catch {
        $script:LastCaptureErrorDetail = $_.Exception.Message
        & $note "Output monitor capture could not start: $($_.Exception.Message)"
        return $null
    }
    finally { Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue }
}

function Get-OutputMonitorStatus {
    <# Produces the read-only source/monitor section used by full status. A
       manual probe always checks the configured primary source; the active
       source line still makes it clear when snapshots/relay are on Cinegy's
       standby input. #>
    [CmdletBinding()]
    param([switch]$Probe)

    $intervalMinutes = [math]::Max(0, (Get-SettingInt 'OutputMonitorMinutes' 0))
    $timeout = [math]::Max(1, (Get-SettingInt 'SnapshotTimeoutSeconds' 3))
    $primary = Get-LiveStreamConfig
    $backup = Get-BackupLiveStreamConfig
    $ffmpeg = Get-FfmpegPath
    $serverName = [Environment]::MachineName
    $serverState = if (-not $ffmpeg) {
        (T 'media.stoppedNoFfmpeg')
    }
    elseif ($intervalMinutes -le 0) {
        (T 'media.runningMonitorOff')
    }
    else {
        (T 'media.running')
    }

    $probeState = (T 'media.notRun')
    $luminance = $null
    if ($Probe) {
        if (-not $ffmpeg) {
            $probeState = (T 'media.failedNoFfmpeg')
        }
        elseif ([string]::IsNullOrWhiteSpace([string](Get-JsonProp $primary 'SourceUrl'))) {
            $probeState = (T 'media.failedNoUrl')
        }
        else {
            # Someone pressed a button and is waiting for an answer, so a
            # wrong answer costs more than a slow one.
            $probePath = Get-MonitorFrame -TimeoutSeconds ($timeout * 3)
            if (-not $probePath) {
                $probeState = (T 'media.unavailable')
            }
            else {
                try { $luminance = Get-BridgeFrameLuminance -Path $probePath }
                catch { $luminance = $null }
                finally { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
                if ($null -eq $luminance) {
                    $probeState = (T 'media.grabbedNoLuma')
                }
                elseif ($luminance -le (Get-SettingInt 'OutputBlackLuminance' 6)) {
                    $probeState = (T 'media.blackButThere' $luminance)
                }
                else {
                    $probeState = (T 'media.there' $luminance)
                }
            }
        }
    }

    $activeSource = if ($script:OutputMonitorFallbackActive -and $backup) { (T 'media.cinegyBackup') } else { (T 'media.primarySource') }
    $primaryType = if ([string]::IsNullOrWhiteSpace([string](Get-JsonProp $primary 'SourceType'))) { (T 'media.notSet') } else { [string](Get-JsonProp $primary 'SourceType') }
    $backupText = if ($backup) { (T 'media.set' $([string]$backup.SourceType)) } else { (T 'media.notSet') }
    $lastCheck = if ($script:LastOutputMonitorAt -gt [datetime]::MinValue) {
        ([datetime]$script:LastOutputMonitorAt).ToString('yyyy-MM-dd HH:mm:ss')
    }
    else { (T 'media.notStarted') }
    $periodic = if ($intervalMinutes -gt 0) { (T 'media.every' $(Get-ArabicCountNoun -Count $intervalMinutes -One 'دقيقة' -Two 'دقيقتان' -Few 'دقائق' -Many 'دقيقة' -EnglishOne 'minute' -EnglishMany 'minutes')) } else { (T 'media.monitorDisabled') }
    $text = @(
        (T 'media.sourceMonitor'),
        (T 'media.watchServer' $serverState $serverName),
        (T 'media.manualCheck' $probeState),
        (T 'media.sourceInUse' $activeSource),
        (T 'media.mainSourceKind' $primaryType),
        (T 'media.fallbackSource' $backupText),
        (T 'media.watchCycle' $periodic $lastCheck),
        (T 'media.capturesInARow' $([int]$script:OutputMonitorFailureCount))
    ) -join "`n"
    return [pscustomobject]@{
        Text = $text
        ServerState = $serverState
        PrimaryState = $probeState
        ActiveSource = $activeSource
        BackupConfigured = [bool]$backup
        Probed = [bool]$Probe
        Luminance = $luminance
    }
}

function Test-OutputMonitorFlapping {
    <#
        Reports a source that keeps failing and recovering.

        The consecutive counter beside this one answers "is the source down
        right now". It cannot answer "is the source dying", because every
        success resets it - so a stream that fails one capture in two is fifty
        percent blind and never alerts. That is not hypothetical: the station's
        stream failed on isolated days through September, each failure followed
        by a success, and the first warning anybody could have acted on would
        have been the day it started failing hourly.

        Six hours, fixed: long enough that two unlucky grabs do not raise it,
        short enough that a degrading evening is reported the same evening.
        Reported once per window, because a repeated warning about a source
        that is still half working is how a channel learns to ignore warnings.
    #>
    param([datetime]$Now = (Get-Date))
    $threshold = Get-SettingInt 'OutputMonitorFlapAlertCount' 0
    if ($threshold -le 0) { return $false }
    $windowStart = $Now.AddHours(-6)
    # Pruned here rather than on a timer: this is the only reader, so the list
    # cannot grow unbounded between calls that care about its size.
    while ($script:OutputMonitorFailureMoments.Count -gt 0 -and $script:OutputMonitorFailureMoments[0] -lt $windowStart) {
        $script:OutputMonitorFailureMoments.RemoveAt(0)
    }
    $recent = $script:OutputMonitorFailureMoments.Count
    if ($recent -lt $threshold) { return $false }
    if ($script:OutputMonitorFlapAlertedAt -gt $windowStart) { return $false }
    $script:OutputMonitorFlapAlertedAt = $Now
    Write-BridgeLog "Output monitor source is flapping: $recent failed capture(s) in the last six hours, each followed by a success." 'WARN'
    Add-AuditEntry (T 'media.sourceFlappingShort' $(Get-ArabicCountNoun -Count $recent -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' -EnglishOne 'time' -EnglishMany 'times'))
    Send-AdminBroadcast -Text (T 'media.sourceFlapping' $(Get-ArabicCountNoun -Count $recent -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' -EnglishOne 'time' -EnglishMany 'times')) | Out-Null
    return $true
}

function Update-OutputBlackWatchdog {
    <#
        Looks at the actual picture on a timer and reports a black output.

        Every other health check in the bridge asks a component whether it is
        happy. Cinegy can answer healthy, the relay process can be alive, the
        graphics layers can all be correct, and the transmission can still be
        a black rectangle. This is the only check that looks at the output.

        A single black frame is not evidence: a cut, a fade, a momentary
        source glitch all read as black. It therefore confirms with a second
        capture a few seconds later and alerts only if both are black.
    #>
    # A booked second look comes first, and is not subject to the interval:
    # the pair belongs to one reading.
    if ($script:OutputMonitorConfirmAt -gt [datetime]::MinValue) {
        if ((Get-Date) -lt $script:OutputMonitorConfirmAt) { return }
        Complete-OutputBlackConfirmation
        return
    }
    $intervalMinutes = Get-SettingInt 'OutputMonitorMinutes' 0
    if ($intervalMinutes -le 0) { return }
    $now = Get-Date
    if (($now - $script:LastOutputMonitorAt).TotalMinutes -lt $intervalMinutes) { return }
    $script:LastOutputMonitorAt = $now

    $threshold = Get-SettingInt 'OutputBlackLuminance' 1
    $timeout = Get-SettingInt 'SnapshotTimeoutSeconds' 3

    $firstPath = Get-MonitorFrame -TimeoutSeconds $timeout
    if (-not $firstPath) {
        # One more try before believing it. This ran once an hour and a single
        # eight-second timeout switched a working channel to its standby: the
        # grab that failed on 8 September timed out while the machine was busy
        # building something else, and the source was fine the whole time.
        # A second attempt costs eight seconds against an hour of being on the
        # wrong source.
        # And the retry waits properly rather than repeating the same
        # impatience. Measured against the station's own HLS source with its
        # eight-second ceiling: 5.2s, 4.7s, 10.3s - every grab succeeded and a
        # third took longer than the ceiling allowed. An HLS source fetches a
        # playlist and a segment before it can decode anything, so a timeout
        # here says "slow", not "down" - and two unlucky grabs in a row were
        # raising the flapping alarm on a source that was working throughout.
        Start-Sleep -Milliseconds 1500
        $firstPath = Get-MonitorFrame -TimeoutSeconds ($timeout * 3)
        if ($firstPath) { Write-BridgeLog 'Output monitor: the first grab failed and the patient retry succeeded; the source is up but slow to open.' 'INFO' }
    }
    if (-not $firstPath) {
        $script:OutputMonitorFailureCount++
        # Recorded on its own clock, because the consecutive counter below is
        # reset by the very next success and cannot describe a source that
        # alternates. Thirty-six captures failed over one month here and the
        # consecutive alert fired only for the one burst that happened to land
        # back to back; the twelve days of isolated failures that preceded the
        # source's collapse produced no warning at all, because each one was
        # followed by a success that zeroed the count.
        $script:OutputMonitorFailureMoments.Add($now)
        Test-OutputMonitorFlapping -Now $now | Out-Null
        # The ledger, which is the only thing here that survives a restart
        # and the only thing that can say how long the feed was gone.
        Start-StreamOutage -Kind 'unreachable' -Cause ([string]$script:LastCaptureErrorDetail) -At $now
        $failureThreshold = [math]::Max(1, (Get-SettingInt 'OutputMonitorFailureAlertThreshold' 2))
        $backup = Get-BackupLiveStreamConfig
        # A configured standby is actionable immediately. Waiting for the
        # generic alert threshold would leave snapshots and an already-running
        # relay on a dead primary for another watchdog interval.
        $shouldSwitch = $backup -and -not $script:OutputMonitorFallbackActive -and -not $script:OutputMonitorFailureAlerted
        $shouldAlert = -not $script:OutputMonitorFailureAlerted -and $script:OutputMonitorFailureCount -ge $failureThreshold
        if ($shouldSwitch -or $shouldAlert) {
            $script:OutputMonitorFailureAlerted = $true
            Write-BridgeLog "Output monitor source unavailable for $($script:OutputMonitorFailureCount) consecutive capture(s)" 'WARN'
            Add-AuditEntry (T 'media.outputUnreachableShort' $(Get-ArabicCountNoun -Count $script:OutputMonitorFailureCount -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' -EnglishOne 'time' -EnglishMany 'times'))
            if ($shouldSwitch -and (Set-OutputMonitorFallbackActive -Active $true)) {
                # Checked again in minutes, not at the next hourly turn. The
                # switch is the moment the primary matters most, and leaving
                # the answer an hour away is why nobody heard that it had come
                # back - the check simply had not run yet.
                $script:LastOutputMonitorAt = $now.AddMinutes(-([math]::Max(0, (Get-SettingInt 'OutputMonitorMinutes' 1) - 3)))
                Send-AdminBroadcast -Text (T 'media.switchedToFallback' $($script:OutputMonitorFailureCount)) -Urgent
            }
            else {
                Send-OutputMonitorFailureNotification -FailureCount $script:OutputMonitorFailureCount
            }
        }
        return
    }
    if ($script:OutputMonitorFailureCount -gt 0) {
        if ($script:OutputMonitorFallbackActive) {
            # The grab that just succeeded came from whichever source is
            # active - and while the fallback is active, that is the standby.
            # Reading it as "the primary is back" announced a recovery nobody
            # had tested. The primary is asked directly.
            if (Test-PrimaryMonitorSourceBack -TimeoutSeconds $timeout) {
                if (Set-OutputMonitorFallbackActive -Active $false) {
                    Send-AdminBroadcast -Text (T 'media.primaryReturned') -Urgent
                }
            }
            else {
                # Still on the standby, and still working: no news, and the
                # counter stays up so the next success asks again.
                return
            }
        }
        elseif ($script:OutputMonitorFailureAlerted) {
            Send-OutputMonitorFailureNotification -Recovered
        }
        Stop-StreamOutage -Kind 'unreachable' -At $now
        $script:OutputMonitorFailureCount = 0
        $script:OutputMonitorFailureAlerted = $false
        $script:LastCaptureErrorDetail = ''
    }
    $first = Get-BridgeFrameLuminance -Path $firstPath
    Remove-Item -LiteralPath $firstPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $first) { return }

    if ($first -gt $threshold) {
        if ($script:OutputBlackAlerted) {
            $script:OutputBlackAlerted = $false
            Write-BridgeLog "Output brightness recovered (luma $first)"
            Stop-StreamOutage -Kind 'black'
            Send-OutputBlackNotification -Recovered -Luminance $first
        }
        return
    }

    # Confirm before crying wolf: cuts and fades are legitimately black - but
    # the waiting is owed to a clock, not to this thread. Start-Sleep here held
    # the whole control loop: auto-hide timers, the schedule, pending expiry
    # and the heartbeat all waited out a fade. The second look is booked for a
    # moment and taken by whichever tick arrives after it.
    $script:OutputMonitorFirstLuma = $first
    $script:OutputMonitorConfirmAt = (Get-Date).AddSeconds([math]::Max(1, (Get-SettingInt 'OutputBlackConfirmSeconds' 1)))
    return
}

function Complete-OutputBlackConfirmation {
    <# The second half of Update-OutputBlackWatchdog, on a later tick. #>
    $timeout = Get-SettingInt 'SnapshotTimeoutSeconds' 3
    $threshold = Get-SettingInt 'OutputBlackLuminance' 1
    $first = [double]$script:OutputMonitorFirstLuma
    $script:OutputMonitorConfirmAt = [datetime]::MinValue

    # Patient, like the first look. A timeout here returns silently, so an
    # impatient ceiling does not raise a false alarm - it loses a true one,
    # which on a source that needs ten seconds to open is worse.
    $secondPath = Get-MonitorFrame -TimeoutSeconds ($timeout * 3)
    if (-not $secondPath) { return }
    $second = Get-BridgeFrameLuminance -Path $secondPath
    Remove-Item -LiteralPath $secondPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $second -or $second -gt $threshold) {
        Write-BridgeLog "Output monitor: first frame dark (luma $first) but second was not (luma $second) - treated as a transition"
        return
    }

    if ($script:OutputBlackAlerted) { return }
    $script:OutputBlackAlerted = $true
    Write-BridgeLog "Output confirmed black across two captures (luma $first then $second)" 'WARN'
    Add-AuditEntry (T 'media.blackConfirmed' $second)
    # Opened on the confirmation, never on the first dark frame: a cut or a
    # fade is legitimately black, and filing each one as an outage would
    # make the screen a list of transitions.
    # The cause is stored, so it is frozen in whatever language the bridge
    # was set to when it happened - a record written in Arabic would read
    # Arabic on an English screen for ever. The row already says "black";
    # what it wants beside that is the measurement, which needs no language.
    Start-StreamOutage -Kind 'black' -Cause "luma $second"
    Send-OutputBlackNotification -Luminance $second
}

function Get-OutputFailureDiagnosis {
    <#
        Which link in the chain looks broken, not merely that something is.

        (T 'media.outputUnreachable') names a symptom and leaves the reader to
        work out where to start, at the moment they have least patience for
        it. There are three candidates and the bridge can already see all
        three: the channel itself, the relay process that republishes it, and
        the source it is reading.

        Every check here is read-only. SetOutput would change what goes to
        air and is never sent from the bridge.

        Returns the lines to append, in the order a person would check them.
    #>
    $lines = @()
    $nextStep = ''

    # The channel first. A deliberate Black or Bypass is a working channel
    # with nothing to show, which reads identically to a dead one on a
    # captured frame - and is the single most common false alarm here.
    $status = Get-AirVideoStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not $status.Success) {
        $lines += (T 'media.channelSilent')
        $nextStep = (T 'media.nextOpenAir')
    }
    elseif ($status.OutputState -and $status.OutputState -ne 'Normal') {
        $lines += (T 'media.channelAnswers' $(ConvertTo-TelegramHtmlText $status.OutputState))
    }
    else {
        $lines += (T 'media.channelNormal')
    }

    # Then the relay, when one is meant to be running: an ffmpeg that died is
    # a break the operator can fix without touching playout.
    if ($script:RelayState.ShouldRun) {
        $running = Get-RunningRelayProcess
        if ($running) { $lines += (T 'media.relayRunning') }
        else {
            $lines += (T 'media.relayShouldRun')
            if (-not $nextStep) { $nextStep = (T 'media.nextRestartRelay') }
        }
    }

    # Then the streaming server, read from the last capture's own stderr:
    # a refused connection names the server, a local failure does not.
    $serverDetail = [string]$script:LastCaptureErrorDetail
    if (-not [string]::IsNullOrWhiteSpace($serverDetail)) {
        $short = $serverDetail.Trim()
        if ($short.Length -gt 180) { $short = $short.Substring(0, 180) + '…' }
        $safe = ConvertTo-TelegramHtmlText $short
        if (Test-MediaSourceUnreachable -Detail $serverDetail) {
            $lines += (T 'media.serverNotAnswering' $safe)
            if (-not $nextStep) { $nextStep = (T 'media.nextCheckServer') }
        }
        else {
            $lines += (T 'media.lastRecordedError' $safe)
        }
    }

    # And the source last, because it is the one the bridge cannot test
    # without another capture - but it can say which source it was using,
    # which is the question that follows.
    $active = Get-ActiveLiveStreamConfig
    $label = Get-SnapshotSourceLabel -SourceIsPrimary (-not $script:OutputMonitorFallbackActive)
    if ([string]::IsNullOrWhiteSpace([string]$active.SourceUrl)) {
        $lines += (T 'media.sourceUnset')
    }
    else {
        $lines += (T 'media.checkSource' $label)
    }
    if (-not $nextStep) { $nextStep = (T 'media.nextAskSnapshot') }
    $lines += $nextStep
    return $lines
}

function Send-OutputMonitorFailureNotification {
    <# Reports a sustained inability to capture the configured output source,
       separately from the confirmed-black picture alarm. Names the suspect
       link rather than the symptom: see Get-OutputFailureDiagnosis. #>
    param([int]$FailureCount = 0, [switch]$Recovered)
    if ($Recovered) {
        Send-AdminBroadcast -Text (T 'media.outputBack') -Urgent
        return
    }
    $diagnosis = @(Get-OutputFailureDiagnosis)
    $text = (T 'media.outputUnreachable' $FailureCount) +
        ($diagnosis -join "`n")
    # P1: the diagnosis names the server and the next step, and the operator
    # retypes it for the maintenance group. The copy keeps a plain-text
    # twin: Telegram gives bots no clipboard, but a plain message
    # long-press-copies whole, while the HTML original does not.
    $script:LastFailureDiagnosisPlain = @{
        Text = ($text -replace '<[^>]+>', ''); At = (Get-Date); Failures = $FailureCount
    }
    $copyRow = @{ inline_keyboard = @(, @(@{ text = (T 'media.copyReady'); callback_data = 'diag:copy' })) }
    Send-AdminBroadcast -Text $text -ReplyMarkup $copyRow -Urgent
}

function Send-OutputBlackNotification {
    <# Administrators always hear about a black output. Operators hear about it
       only if NotifyOperatorsOnBlackOutput is on, because during a planned
       break a broadcast to everyone is noise, not information. #>
    param([double]$Luminance = 0, [switch]$Recovered)
    $text = if ($Recovered) { (T 'media.backToLight' $Luminance) }
    else { (T 'media.outputBlack' $Luminance) }
    Send-AdminBroadcast -Text $text -Urgent
    if (-not (Get-Setting 'NotifyOperatorsOnBlackOutput')) { return }
    # The same audience Send-AdminBroadcast just used, or an administrator
    # it reached would be told twice.
    $adminIds = @(Get-AdminNotifyIds)
    foreach ($chatId in @(@(Get-JsonProp $config 'AllowedChatIds') | ForEach-Object { [long]$_ })) {
        if ($adminIds -contains $chatId) { continue }   # already told above
        Send-TelegramMessage -ChatId $chatId -Text $text
    }
}

function Update-UploadCleanup {
    <#
        Sweeps documents operators uploaded to the bot.

        A news import or a template registry file is staged to disk, parsed,
        and then simply left there. Every upload accumulated for ever, on the
        playout machine, holding whatever editorial text the operator sent -
        content nobody intended the bridge to retain.

        Staged uploads are consumed within seconds of arriving, so anything
        older than the retention window is finished with by definition.
    #>
    param([switch]$Force)
    $retention = Get-SettingInt 'UploadRetentionMinutes' 0
    if ($retention -le 0) { return }
    if (-not $Force -and ((Get-Date) - $script:LastUploadSweep).TotalSeconds -lt 300) { return }
    $script:LastUploadSweep = Get-Date

    $cutoff = (Get-Date).AddMinutes(-$retention)
    $removed = 0
    foreach ($directory in @($script:newsImportDirectory, (Join-Path $script:logDir 'template-imports'))) {
        if (-not (Test-Path -LiteralPath $directory)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -ge $cutoff) { continue }
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    if ($removed -gt 0) { Write-BridgeLog "Upload cleanup removed $removed staged upload(s) older than $retention minute(s)" }
}

function Update-SnapshotCleanup {
    <# Snapshots are throwaway files. The success path already deletes the
       previously cached frame and the failure paths delete their own output,
       but a hard kill of the bridge mid-capture can still orphan files - so
       sweep the folder periodically and once at startup. Runs at most every
       few minutes; it is only a few Get-ChildItem calls. #>
    param([switch]$Force)
    if (-not $Force -and ((Get-Date) - $script:LastSnapshotSweep).TotalSeconds -lt 300) { return }
    $script:LastSnapshotSweep = Get-Date

    $retention = Get-SettingInt 'SnapshotRetentionMinutes' 1
    $cutoff = (Get-Date).AddMinutes(-$retention)
    $active = @($script:SnapshotJobs | ForEach-Object { $_.OutPath })
    $removed = 0
    foreach ($pattern in @('snapshot-*.jpg', 'snapshot-*.err')) {
        foreach ($file in @(Get-ChildItem -Path $logDir -Filter $pattern -File -ErrorAction SilentlyContinue)) {
            if ($active -contains $file.FullName) { continue }          # capture in flight
            if ($file.LastWriteTime -ge $cutoff) { continue }           # still fresh / cached
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    # Drop the stale legacy shared error log from earlier versions.
    $legacy = Join-Path $logDir 'snapshot-stderr.log'
    if (Test-Path $legacy) { Remove-Item $legacy -Force -ErrorAction SilentlyContinue }

    if ($removed -gt 0) { Write-BridgeLog "Snapshot cleanup removed $removed stale file(s)" }
}

function Get-RunningRelayProcess {
    <# The pid file stores "<pid>|<start ticks>". Matching the start time too
       matters because Windows recycles PIDs: a stale relay.pid could otherwise
       resolve to an unrelated ffmpeg - very plausibly one of this bridge's own
       short-lived snapshot captures - and the menu would claim the relay is
       live while offering to kill the wrong process. #>
    if ($script:RelayState.Process -and -not $script:RelayState.Process.HasExited) { return $script:RelayState.Process }
    if (Test-Path $relayPidFile) {
        $raw = ''
        try { $raw = (Get-Content $relayPidFile -Raw -ErrorAction Stop).Trim() } catch { $raw = '' }
        $parts = @($raw -split '\|')
        $parsedPid = 0
        if ($parts.Count -ge 1 -and [int]::TryParse($parts[0], [ref]$parsedPid)) {
            $proc = Get-Process -Id $parsedPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like 'ffmpeg*') {
                $ticks = 0L
                if ($parts.Count -lt 2 -or -not [long]::TryParse($parts[1], [ref]$ticks)) {
                    return $proc          # legacy pid file without a timestamp
                }
                if ([Math]::Abs($proc.StartTime.Ticks - $ticks) -lt [TimeSpan]::TicksPerSecond) {
                    return $proc
                }
            }
        }
        Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
    }
    return $null
}

function Get-LiveRelayStatusText {
    $proc = Get-RunningRelayProcess
    if ($proc) { return (T 'media.running' $($proc.Id)) }
    if ($script:RelayState.ShouldRun) { return (T 'media.stoppedRetrying') }
    return (T 'media.stopped')
}

function Build-RelayArguments {
    $ls = Get-ActiveLiveStreamConfig
    $rtmp = [string]$ls.RtmpDestination
    if ([string]::IsNullOrWhiteSpace($rtmp)) { throw (T 'media.rtmpUnset') }
    $sourceUrl = [string]$ls.SourceUrl
    if ([string]::IsNullOrWhiteSpace($sourceUrl)) { throw (T 'media.sourceUrlUnsetPlain') }

    $inputArgs = @(Get-FfmpegInputArguments -SourceType ([string]$ls.SourceType) -SourceUrl $sourceUrl -Realtime)

    if (Get-JsonProp $ls 'CopyCodec') {
        $outputArgs = @('-c', 'copy', '-f', 'flv', $rtmp)
    }
    else {
        $vBitrate = 0
        if (-not [int]::TryParse([string](Get-JsonProp $ls 'VideoBitrateKbps'), [ref]$vBitrate) -or $vBitrate -le 0) { $vBitrate = 2500 }
        $outputArgs = @(
            '-c:v', 'libx264', '-preset', 'veryfast', '-b:v', "${vBitrate}k", '-maxrate', "${vBitrate}k", '-bufsize', "$($vBitrate * 2)k",
            '-pix_fmt', 'yuv420p', '-g', '60',
            '-c:a', 'aac', '-b:a', '128k', '-ar', '44100',
            '-f', 'flv', $rtmp
        )
    }
    return $inputArgs + $outputArgs
}

function Start-RelayProcess {
    <# Low-level launch shared by the button and the watchdog's auto-restart.
       Returns $true if the process started (startup success is verified later,
       asynchronously, so the caller never blocks). #>
    $ffmpeg = Get-FfmpegPath
    if (-not $ffmpeg) { throw (T 'media.ffmpegMissingPlain') }
    $relayArgs = @(Build-RelayArguments)
    $stdoutLog = Join-Path $logDir "relay-stdout.log"
    $stderrLog = Join-Path $logDir "relay-stderr.log"

    # Quoted for the same reason as the snapshot: source URLs, RTMP keys and
    # paths can all contain spaces.
    $script:RelayState.Process = Start-BridgeMediaProcess -FilePath $ffmpeg -Arguments $relayArgs `
        -WorkingDirectory $scriptRoot -StandardOutputPath $stdoutLog -StandardErrorPath $stderrLog
    # pid + process start time, so a recycled PID cannot be mistaken for ours.
    $stamp = "$($script:RelayState.Process.Id)|$($script:RelayState.Process.StartTime.Ticks)"
    # ffmpeg is already running by this line, so a failure to write the stamp
    # is not a failure to start the relay. Reported as started either way: an
    # unwritable pid file used to be read as "the relay did not start" while
    # the stream was live and now untracked - nothing in the interface could
    # stop it, because nothing knew it was there.
    try { Set-Content -Path $relayPidFile -Value $stamp -Encoding ascii -ErrorAction Stop }
    catch { Write-BridgeLog "Relay is running (pid $($script:RelayState.Process.Id)) but its pid file could not be written: $(Protect-SensitiveText $_.Exception.Message). Stop it from the manager or by pid." 'ERROR' }
    return $true
}

function Start-LiveRelay {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableLiveRelay')) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.relayDisabled') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if (Get-RunningRelayProcess) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.alreadyRunning') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try { Start-RelayProcess | Out-Null }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $script:RelayState.ShouldRun = $true
    $script:RelayState.Restarts = 0
    $script:RelayState.NotifyChatId = $ChatId
    $script:RelayState.VerifyAt = (Get-Date).AddSeconds(3)
    Write-BridgeLog "User $UserId started live relay (PID $($script:RelayState.Process.Id))"
    Add-AuditEntry (T 'media.feedStartedAudit' $(Format-UserAuditActor -UserId $UserId))
    Send-TelegramMessage -ChatId $ChatId -Text (T 'media.starting') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Stop-LiveRelay {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $script:RelayState.ShouldRun = $false
    $script:RelayState.VerifyAt = $null
    $proc = Get-RunningRelayProcess
    if (-not $proc) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.noneRunning') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        Write-BridgeLog "User $UserId stopped live relay (PID $($proc.Id))"
        Add-AuditEntry (T 'media.feedStoppedAudit' $(Format-UserAuditActor -UserId $UserId))
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.stoppedOk') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.stopFailed' $(Protect-SensitiveText $_.Exception.Message)) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    $script:RelayState.Process = $null
    Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
}

function Update-RelayWatchdog {
    <# Two jobs: confirm a just-started relay actually stayed up (deferred so
       Start-LiveRelay does not sleep), and restart a relay that died on its
       own - a dropped source used to silently kill the stream with nobody
       noticing until someone checked. #>
    if ($script:RelayState.VerifyAt) {
        if ((Get-Date) -lt $script:RelayState.VerifyAt) { return }
        $script:RelayState.VerifyAt = $null
        $notify = [long]$script:RelayState.NotifyChatId
        if ($script:RelayState.Process -and $script:RelayState.Process.HasExited) {
            # Capture the exit code before clearing the reference.
            $exitCode = $script:RelayState.Process.ExitCode
            $detail = Get-LastErrorLine -Path (Join-Path $logDir "relay-stderr.log")
            Write-BridgeLog "Live relay exited immediately (code $exitCode): $detail" "ERROR"
            $script:RelayState.ShouldRun = $false
            $script:RelayState.Process = $null
            Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
            if ($notify) {
                $msg = (T 'media.stoppedAtOnce' $exitCode)
                if ($detail) { $msg += (T 'media.ffmpegReason' $detail) }
                Send-TelegramMessage -ChatId $notify -Text $msg -ReplyMarkup (Get-MainMenuKeyboard -ChatId $notify)
            }
        }
        elseif ($notify) {
            Send-TelegramMessage -ChatId $notify -Text (T 'media.runningNow') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $notify)
        }
        return
    }

    $interval = Get-SettingInt 'RelayWatchdogSeconds' 5
    $now=Get-Date
    $running=$null
    if($script:RelayState.ShouldRun -and ($now-$script:RelayState.LastCheck).TotalSeconds -ge $interval){$running=Get-RunningRelayProcess}
    $maxRestarts = Get-SettingInt 'RelayMaxRestarts' 0
    $decision=Get-BridgeRelayWatchdogDecision -ShouldRun:([bool]$script:RelayState.ShouldRun) `
        -HasRunningProcess:([bool]$running) -AutoRestart:([bool](Get-Setting 'RelayAutoRestart')) `
        -Restarts ([int]$script:RelayState.Restarts) -MaxRestarts $maxRestarts `
        -LastCheck ([datetime]$script:RelayState.LastCheck) -IntervalSeconds $interval -Now $now
    if($decision.Action -in @('idle','wait')){return}
    $script:RelayState.LastCheck=$decision.CheckedAt
    if($decision.Action -eq 'running'){return}

    Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
    $script:RelayState.Process = $null

    if ($decision.Action -eq 'stay_down') {
        $script:RelayState.ShouldRun = $false
        Write-BridgeLog "Live relay died and RelayAutoRestart is off - staying down" "WARN"
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text (T 'media.relayStopped') }
        return
    }

    if ($decision.Action -eq 'give_up') {
        $script:RelayState.ShouldRun = $false
        Write-BridgeLog "Live relay exceeded RelayMaxRestarts ($maxRestarts) - giving up" "ERROR"
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text (T 'media.gaveUp' $maxRestarts) }
        return
    }

    $script:RelayState.Restarts=$decision.Restarts
    Write-BridgeLog "Live relay died - auto-restart attempt $($script:RelayState.Restarts)/$maxRestarts" "WARN"
    try {
        Start-RelayProcess | Out-Null
        $script:RelayState.VerifyAt = (Get-Date).AddSeconds(3)
        $script:RelayState.NotifyChatId = 0
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text (T 'media.restarted' $($script:RelayState.Restarts)) }
    }
    catch {
        Write-BridgeLog "Live relay auto-restart failed: $(Protect-SensitiveText $_.Exception.Message)" "ERROR"
    }
}

function Start-StreamUrlPrompt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'stream_url'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text (T 'media.sendRtmp') -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-StreamUrl {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    Clear-PendingState -ChatId $ChatId
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.noUrlGiven') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $state.UserId)
        return
    }
    # ffmpeg resolves the output protocol from the URL scheme itself, so a
    # non-rtmp value (file://, concat:, a pipe) would redirect the relay's
    # output away from the network. Admin-only already, but the allowlist
    # costs nothing and closes it outright rather than trusting intent.
    if ($trimmed -notmatch '^rtmps?://') {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'media.rtmpPrefix') -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $state.UserId)
        return
    }
    $ls = Get-LiveStreamConfig
    $ls | Add-Member -NotePropertyName 'RtmpDestination' -NotePropertyValue $trimmed -Force
    Save-Config
    Write-BridgeLog "User $($state.UserId) updated LiveStream.RtmpDestination"
    Send-TelegramMessage -ChatId $ChatId -Text (T 'media.linkSaved' $(Get-ConfigSaveWarning)) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $state.UserId)
}

function Import-StreamOutages {
    <#
        Reads the outage ledger from disk at start.

        An unreadable file is not an empty ledger and is not a reason to
        refuse to start: the bridge keeps going with what it can read, and
        says so once. The worst this costs is a forgotten outage; refusing to
        start costs the channel its graphics.
    #>
    if (-not (Test-Path -LiteralPath $script:streamOutageFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:streamOutageFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $ledger = New-BridgeOutageLedger
        foreach ($outage in @(Get-JsonProp $raw 'Outages')) {
            if ([string]::IsNullOrWhiteSpace([string](Get-JsonProp $outage 'StartedAt'))) { continue }
            $ledger.Outages.Add([pscustomobject]@{
                    Kind = [string](Get-JsonProp $outage 'Kind')
                    StartedAt = [string](Get-JsonProp $outage 'StartedAt')
                    EndedAt = [string](Get-JsonProp $outage 'EndedAt')
                    Cause = [string](Get-JsonProp $outage 'Cause')
                    Source = [string](Get-JsonProp $outage 'Source')
                })
        }
        $script:StreamOutages = $ledger
        Write-BridgeLog "Read $(@($ledger.Outages).Count) recorded feed outage(s) from stream-outages.json"
    }
    catch {
        Write-BridgeLog "Could not read stream-outages.json: $(Protect-SensitiveText -Text $_.Exception.Message)" 'WARN'
    }
}

function Save-StreamOutages {
    <# Written only when something changed, and trimmed on the way out so the
       file cannot grow past what the screen will ever show. #>
    if (-not $script:StreamOutagesDirty) { return }
    $script:StreamOutagesDirty = $false
    try {
        Limit-BridgeOutageLedger -Ledger $script:StreamOutages -Keep 40 -WindowDays 30 | Out-Null
        $payload = [pscustomobject]@{
            SchemaVersion = 1
            Outages = @($script:StreamOutages.Outages)
        }
        Write-BridgeValidatedJson -Path $script:streamOutageFile -Json ($payload | ConvertTo-Json -Depth 5) | Out-Null
    }
    catch {
        Write-BridgeLog "Could not write stream-outages.json: $(Protect-SensitiveText -Text $_.Exception.Message)" 'WARN'
    }
}

function Start-StreamOutage {
    <# The feed went. Idempotent: the watchdog calls this once per failed
       capture and a source that is down stays down. #>
    param(
        [Parameter(Mandatory)][string]$Kind,
        [AllowEmptyString()][string]$Cause = '',
        [datetime]$At = (Get-Date)
    )
    $before = @($script:StreamOutages.Outages).Count
    $open = Get-BridgeOpenOutage -Ledger $script:StreamOutages -Kind $Kind
    $source = if ($script:OutputMonitorFallbackActive) { (T 'media.cinegyBackup') } else { (T 'media.primarySource') }
    Open-BridgeOutage -Ledger $script:StreamOutages -Kind $Kind -At $At -Cause $Cause -Source $source | Out-Null
    $script:StreamOutagesDirty = $true
    if (-not $open -and @($script:StreamOutages.Outages).Count -gt $before) {
        Write-BridgeLog "Feed outage opened ($Kind)$(if ($Cause) { ": $Cause" })"
    }
    Save-StreamOutages
}

function Stop-StreamOutage {
    <# The feed came back. Silent when no outage of this kind was open, which
       is every successful capture on a healthy channel. #>
    param([Parameter(Mandatory)][string]$Kind, [datetime]$At = (Get-Date))
    $closed = Close-BridgeOutage -Ledger $script:StreamOutages -Kind $Kind -At $At
    if (-not $closed) { return }
    $script:StreamOutagesDirty = $true
    Write-BridgeLog "Feed outage closed ($Kind) after $(Format-DurationSeconds -Seconds (Get-BridgeOutageDurationSeconds -Outage $closed))"
    Save-StreamOutages
}

function Get-FeedWatchText {
    <#
        One screen for the question the station actually asks: is the feed
        arriving, since when, and what has it done lately.

        The pieces already existed and none of them were together. The state
        lived in a counter, the source in the status block, and the history
        nowhere at all - the six-hour list of failure moments is pruned and
        in memory, so "what happened last night" had no answer but a grep
        through bridge.log for lines that never say when the trouble ended.

        -Probe grabs one frame to measure. Read-only: nothing is sent to
        Cinegy and nothing on air is touched.
    #>
    [CmdletBinding()]
    param([switch]$Probe)

    $now = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((T 'feed.title'))
    $lines.Add('')

    $openUnreachable = Get-BridgeOpenOutage -Ledger $script:StreamOutages -Kind 'unreachable'
    $openBlack = Get-BridgeOpenOutage -Ledger $script:StreamOutages -Kind 'black'
    $status = Get-OutputMonitorStatus -Probe:$Probe

    # The open outage outranks the probe: a single lucky frame does not mean a
    # source that has failed every capture for an hour is back, and the
    # watchdog is what decides that, on its own clock.
    $state = if ($openUnreachable) { (T 'feed.stateDown') }
    elseif ($openBlack) { (T 'feed.stateBlack') }
    elseif ($script:LastOutputMonitorAt -le [datetime]::MinValue) { (T 'feed.stateUnknown') }
    else { (T 'feed.stateGood') }
    $openOutage = if ($openUnreachable) { $openUnreachable } else { $openBlack }
    $summary = Get-BridgeOutageSummary -Ledger $script:StreamOutages -WindowHours 24 -Now $now
    if ($openOutage) {
        $state += ' · ' + (T 'feed.since' (Format-DurationSeconds -Seconds (Get-BridgeOutageDurationSeconds -Outage $openOutage -Now $now)))
    }
    elseif ($summary.LastGoodAt) {
        # "Arriving" on its own does not answer what the screen was asked.
        # How long it has been arriving is the half that says whether the
        # feed settled an hour ago or has been steady since Tuesday.
        $state += ' · ' + (T 'feed.since' (Format-DurationSeconds -Seconds ([int]($now - $summary.LastGoodAt).TotalSeconds)))
    }
    $lines.Add($state)

    if (-not (Get-FfmpegPath)) { $lines.Add((T 'feed.noFfmpeg')) }
    elseif ((Get-SettingInt 'OutputMonitorMinutes' 0) -le 0) { $lines.Add((T 'feed.watchOff')) }

    $lastCheck = if ($script:LastOutputMonitorAt -gt [datetime]::MinValue) {
        ([datetime]$script:LastOutputMonitorAt).ToString('yyyy-MM-dd HH:mm:ss')
    }
    else { (T 'feed.neverChecked') }
    $lines.Add((T 'feed.lastCheck' $lastCheck))
    $lines.Add((T 'feed.source' $($status.ActiveSource) $($status.PrimaryState)))

    $intervalMinutes = [math]::Max(0, (Get-SettingInt 'OutputMonitorMinutes' 0))
    if ($intervalMinutes -gt 0) { $lines.Add((T 'feed.cycle' (Format-DurationMinutes -Minutes $intervalMinutes))) }

    $lines.Add('')
    if ($summary.Count -le 0) {
        $lines.Add((T 'feed.windowClean' (Format-DurationMinutes -Minutes ($summary.WindowHours * 60))))
    }
    else {
        $window = Format-DurationMinutes -Minutes ($summary.WindowHours * 60)
        $counted = Get-ArabicCountNoun -Count $summary.Count -One 'انقطاع' -Two 'انقطاعان' -Few 'انقطاعات' -Many 'انقطاعًا' -EnglishOne 'outage' -EnglishMany 'outages'
        $total = Format-DurationSeconds -Seconds $summary.TotalSeconds
        $lines.Add((T 'feed.windowSummary' $window $counted $total))
    }
    if ($summary.LastGoodAt) {
        $lines.Add((T 'feed.lastGood' $($summary.LastGoodAt.ToString('yyyy-MM-dd HH:mm'))))
    }

    $lines.Add('')
    $outages = @($script:StreamOutages.Outages)
    if ($outages.Count -eq 0) { $lines.Add((T 'feed.noOutages')) }
    else {
        $lines.Add((T 'feed.outagesTitle'))
        # Eight, not the whole ledger: this screen is one Telegram message and
        # the list is the part that grows.
        foreach ($outage in @($outages | Select-Object -First 8)) {
            $started = [datetime]::Parse([string]$outage.StartedAt, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $glyph = if ([string]$outage.Kind -eq 'black') { '🖤' } else { '🔴' }
            $kind = if ([string]$outage.Kind -eq 'black') { (T 'feed.kind.black') } else { (T 'feed.kind.unreachable') }
            $length = if ([string]::IsNullOrWhiteSpace([string]$outage.EndedAt)) { (T 'feed.stillDown') }
            else { Format-DurationSeconds -Seconds (Get-BridgeOutageDurationSeconds -Outage $outage -Now $now) }
            $detail = if ([string]::IsNullOrWhiteSpace([string]$outage.Cause)) { [string]$outage.Source }
            else { [string]$outage.Cause }
            $tail = ConvertTo-TelegramHtmlText -Text "$length$(if ($detail) { " · $detail" })"
            $lines.Add((T 'feed.outageRow' $glyph $($started.ToString('MM-dd HH:mm')) $kind $tail))
        }
    }

    $lines.Add('')
    $lines.Add((T 'feed.probeNote'))
    return ($lines -join "`n")
}

function Get-LiveWatchUrl {
    <#
        The Mini App page's address with this channel's stream on it, or
        nothing.

        Nothing when the setting is empty, when it is not https - Telegram
        refuses any other scheme for a Mini App, so the button would simply
        fail to open - or when no stream is configured, because a player
        with nothing to play is a black rectangle with a back button.

        The stream travels as a query parameter rather than being written
        into the page, so one static file serves every station.
    #>
    $page = [string](Get-Setting 'LiveWatchUrl')
    if ([string]::IsNullOrWhiteSpace($page) -or $page -notmatch '^(?i:https://)') { return '' }
    $source = [string](Get-ActiveLiveStreamConfig).SourceUrl
    if ([string]::IsNullOrWhiteSpace($source)) { return '' }
    $separator = if ($page.Contains('?')) { '&' } else { '?' }
    return "$page$separator" + "src=$([uri]::EscapeDataString($source))&lang=$(Get-BridgeLanguage)"
}

function Get-FeedWatchKeyboard {
    <# A snapshot and a refresh, then back where the operator came from.
       The rows are the same for everyone who can reach this screen, so it
       takes no chat and no user: the door is what decides who gets in. #>
    $rows = @()
    # 📺 opens the channel's own output inside Telegram, above the stills: a
    # snapshot answers "what is on screen" and this answers "what is it
    # doing". Only where a page has been hosted - the bridge serves no HTTP,
    # so the address is a station's own and empty means no button.
    $watch = Get-LiveWatchUrl
    if ($watch) { $rows += , @( (New-Button (T 'feed.watchLive') '' -WebAppUrl $watch) ) }
    if (Get-Setting 'EnableSnapshot') {
        # A still and a clip on one row: the same question asked of one
        # frame and of a few seconds.
        $rows += , @( (New-Button (T 'feed.snapshotNow') 'menu:snapshot'), (New-Button (T 'feed.clipNow') 'menu:clip') )
        $rows += , @( (New-Button (T 'feed.refresh') 'menu:feedwatch:probe') )
    }
    else { $rows += , @( (New-Button (T 'feed.refresh') 'menu:feedwatch:probe') ) }
    # Home, not the administration tools: the screen is opened from the main
    # menu now, and a back button that lands somewhere the operator never
    # was is worse than none.
    $rows += , @( (New-Button (T 'common.home') 'menu:main') )
    return @{ inline_keyboard = $rows }
}

function Show-FeedWatchScreen {
    <# The screen, drawn from the ledger and the monitor. -Probe costs one
       frame grab; the plain open costs nothing. #>
    param([Parameter(Mandatory)][long]$ChatId, [switch]$Probe)
    Send-TelegramMessage -ChatId $ChatId -ParseMode HTML `
        -Text (Get-FeedWatchText -Probe:$Probe) `
        -ReplyMarkup (Get-FeedWatchKeyboard) | Out-Null
}
