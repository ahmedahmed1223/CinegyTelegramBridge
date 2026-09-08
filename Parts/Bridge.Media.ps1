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
    if ($SourceIsPrimary) { return 'البث الأساسي' }
    return 'بث Cinegy الاحتياطي'
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
            Send-AdminBroadcast -Text '❌ تعذرت إعادة تشغيل البث بعد تبديل المصدر.' -Urgent
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

function Get-FfprobePath {
    <# ffprobe ships beside ffmpeg in every distribution of it, so the one
       already resolved for the output monitor finds this one too. #>
    $cmd = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $ffmpeg = Get-FfmpegPath
    if ($ffmpeg) {
        $beside = Join-Path (Split-Path -Parent $ffmpeg) 'ffprobe.exe'
        if (Test-Path -LiteralPath $beside) { return $beside }
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
       the previous frame is re-sent instead of spawning ffmpeg again, which
       keeps repeated taps from loading the playout machine's CPU. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }

    if (-not (Get-Setting 'EnableSnapshot')) {
        Send-TelegramMessage -ChatId $ChatId -Text "خاصية الصور معطّلة من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $cooldown = Get-SettingInt 'SnapshotCooldownSeconds' 0
    if ($cooldown -gt 0 -and $script:LastSnapshotFile -and (Test-Path $script:LastSnapshotFile) -and
        ((Get-Date) - $script:LastSnapshotAt).TotalSeconds -lt $cooldown) {
        Send-TelegramPhoto -ChatId $ChatId -FilePath $script:LastSnapshotFile `
            -Caption "📸 آخر لقطة ($([int]((Get-Date) - $script:LastSnapshotAt).TotalSeconds) ثانية مضت)`n📡 المصدر: $(Get-SnapshotSourceLabel -SourceIsPrimary $script:LastSnapshotSourceIsPrimary)" `
            -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $ls = Get-ActiveLiveStreamConfig
    $sourceUrl = [string]$ls.SourceUrl
    if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ LiveStream.SourceUrl غير مضبوط في config.json." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $ffmpeg = Get-FfmpegPath
    if (-not $ffmpeg) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ لم يتم العثور على ffmpeg.exe. ثبّته أولًا (winget install ffmpeg)." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
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
    $outPath = Join-Path $logDir "snapshot-$stamp.jpg"
    # Per-job stderr file: a shared one would race between concurrent captures
    # and report the wrong error back to the wrong operator.
    $errLog = Join-Path $logDir "snapshot-$stamp.err"
    $timeout = Get-SettingInt 'SnapshotTimeoutSeconds' 3

    $processArguments = @('-y', '-loglevel', 'error') + $inputArgs + @('-frames:v', '1', '-q:v', '2', $outPath)
    try {
        $proc = Start-BridgeMediaProcess -FilePath $ffmpeg -Arguments $processArguments `
            -WorkingDirectory $scriptRoot -StandardErrorPath $errLog
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل تشغيل ffmpeg: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $script:SnapshotJobs.Add(@{
            Proc = $proc; ChatId = $ChatId; UserId = $UserId; OutPath = $outPath; ErrLog = $errLog
            SourceIsPrimary = (-not $script:OutputMonitorFallbackActive)
            Deadline = (Get-Date).AddSeconds($timeout)
        })
    Send-TelegramMessage -ChatId $ChatId -Text "⏳ جاري التقاط صورة من البث..."
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
            $msg = "❌ انتهت مهلة التقاط الصورة - تأكد أن المصدر قابل للوصول."
        }
        elseif ($job.Proc.ExitCode -ne 0 -or -not (Test-Path $job.OutPath)) {
            $detail = Get-LastErrorLine -Path $job.ErrLog
            $level = if (Test-MediaSourceUnreachable -Detail $detail) { 'WARN' } else { 'ERROR' }
            Write-BridgeLog "Snapshot ffmpeg failed (exit $($job.Proc.ExitCode)): $detail" $level
            $msg = "❌ فشل التقاط الصورة (كود $($job.Proc.ExitCode))."
            if ($detail) { $msg += "`nسبب ffmpeg: $detail" }
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
                $retryRequests += ,@{ ChatId = $job.ChatId; UserId = $job.UserId }
                Send-TelegramMessage -ChatId $job.ChatId -Text '⚠️ تعذّر التقاط الأساسي؛ أجرب الآن مصدر Cinegy الاحتياطي.'
            }
            else {
                Send-TelegramMessage -ChatId $job.ChatId -Text $msg -ReplyMarkup (Get-MainMenuKeyboard -ChatId $job.ChatId -UserId $job.UserId)
            }
        }
        else {
            # Retain only the newest frame for the cooldown cache.
            if ($script:LastSnapshotFile -and $script:LastSnapshotFile -ne $job.OutPath) {
                Remove-Item $script:LastSnapshotFile -Force -ErrorAction SilentlyContinue
            }
            $script:LastSnapshotFile = $job.OutPath
            $script:LastSnapshotAt = Get-Date
            $script:LastSnapshotSourceIsPrimary = [bool]$job.SourceIsPrimary
            $sourceLabel = Get-SnapshotSourceLabel -SourceIsPrimary ([bool]$job.SourceIsPrimary)
            Write-BridgeLog "User $($job.UserId) captured a stream snapshot from $sourceLabel"
            Add-AuditEntry "📸 لقطة - بواسطة $(Format-UserAuditActor -UserId ([long]$job.UserId))"
            Send-TelegramPhoto -ChatId $job.ChatId -FilePath $job.OutPath `
                -Caption "📸 لقطة من الهواء - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n📡 المصدر: $sourceLabel" `
                -ReplyMarkup (Get-MainMenuKeyboard -ChatId $job.ChatId -UserId $job.UserId)
        }
        Remove-Item $job.ErrLog -Force -ErrorAction SilentlyContinue
        $done += $job
    }
    foreach ($job in $done) { $script:SnapshotJobs.Remove($job) | Out-Null }
    foreach ($request in $retryRequests) { Start-SnapshotJob -ChatId $request.ChatId -UserId $request.UserId }
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
            & $note "Output monitor capture timed out after ${TimeoutSeconds}s"
            return $null
        }
        if ($proc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outPath)) {
            & $note "Output monitor capture failed (exit $($proc.ExitCode)): $(Get-LastErrorLine -Path $errLog)"
            return $null
        }
        return $outPath
    }
    catch {
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
        'متوقف — ffmpeg غير موجود'
    }
    elseif ($intervalMinutes -le 0) {
        'يعمل، والمراقبة الدورية معطلة'
    }
    else {
        'يعمل'
    }

    $probeState = 'لم يُنفّذ'
    $luminance = $null
    if ($Probe) {
        if (-not $ffmpeg) {
            $probeState = 'تعذّر — ffmpeg غير موجود'
        }
        elseif ([string]::IsNullOrWhiteSpace([string](Get-JsonProp $primary 'SourceUrl'))) {
            $probeState = 'تعذّر — رابط المصدر الأساسي غير مضبوط'
        }
        else {
            $probePath = Get-MonitorFrame -TimeoutSeconds $timeout
            if (-not $probePath) {
                $probeState = 'غير متاح'
            }
            else {
                try { $luminance = Get-BridgeFrameLuminance -Path $probePath }
                catch { $luminance = $null }
                finally { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
                if ($null -eq $luminance) {
                    $probeState = 'تم التقاط الصورة (تعذّر قياس السطوع)'
                }
                elseif ($luminance -le (Get-SettingInt 'OutputBlackLuminance' 6)) {
                    $probeState = "متاح لكن أسود (سطوع $luminance)"
                }
                else {
                    $probeState = "متاح (سطوع $luminance)"
                }
            }
        }
    }

    $activeSource = if ($script:OutputMonitorFallbackActive -and $backup) { 'Cinegy الاحتياطي' } else { 'المصدر الأساسي' }
    $primaryType = if ([string]::IsNullOrWhiteSpace([string](Get-JsonProp $primary 'SourceType'))) { 'غير مضبوط' } else { [string](Get-JsonProp $primary 'SourceType') }
    $backupText = if ($backup) { "مضبوط ($([string]$backup.SourceType))" } else { 'غير مضبوط' }
    $lastCheck = if ($script:LastOutputMonitorAt -gt [datetime]::MinValue) {
        ([datetime]$script:LastOutputMonitorAt).ToString('yyyy-MM-dd HH:mm:ss')
    }
    else { 'لم يبدأ بعد' }
    $periodic = if ($intervalMinutes -gt 0) { "كل $intervalMinutes دقيقة" } else { 'معطلة' }
    $text = @(
        '📡 مراقب المصدر',
        "🖥️ سيرفر المتابعة: $serverState · $serverName",
        "🔎 الفحص اليدوي للمصدر الأساسي: $probeState",
        "🎚 المصدر المستخدم حالياً: $activeSource",
        "🔗 نوع المصدر الأساسي: $primaryType",
        "🛟 المصدر الاحتياطي: $backupText",
        "⏱ المراقبة الدورية: $periodic · آخر دورة: $lastCheck",
        "⚠️ فشل التقاط متتالٍ: $([int]$script:OutputMonitorFailureCount)"
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
    $intervalMinutes = Get-SettingInt 'OutputMonitorMinutes' 0
    if ($intervalMinutes -le 0) { return }
    $now = Get-Date
    if (($now - $script:LastOutputMonitorAt).TotalMinutes -lt $intervalMinutes) { return }
    $script:LastOutputMonitorAt = $now

    $threshold = Get-SettingInt 'OutputBlackLuminance' 1
    $timeout = Get-SettingInt 'SnapshotTimeoutSeconds' 3

    $firstPath = Get-MonitorFrame -TimeoutSeconds $timeout
    if (-not $firstPath) {
        $script:OutputMonitorFailureCount++
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
            Add-AuditEntry "⚠️ تعذّر الوصول إلى مخرج البث $($script:OutputMonitorFailureCount) مرات متتالية"
            if ($shouldSwitch -and (Set-OutputMonitorFallbackActive -Active $true)) {
                Send-AdminBroadcast -Text "⚠️ تعذّر الوصول إلى المصدر الأساسي بعد $($script:OutputMonitorFailureCount) محاولات متتالية.`nتم التحويل إلى مصدر Cinegy الاحتياطي." -Urgent
            }
            else {
                Send-OutputMonitorFailureNotification -FailureCount $script:OutputMonitorFailureCount
            }
        }
        return
    }
    if ($script:OutputMonitorFailureCount -gt 0) {
        if ($script:OutputMonitorFallbackActive) {
            if (Set-OutputMonitorFallbackActive -Active $false) {
                Send-AdminBroadcast -Text '💡 عاد المصدر الأساسي؛ تمت العودة إليه من مصدر Cinegy الاحتياطي.' -Urgent
            }
        }
        elseif ($script:OutputMonitorFailureAlerted) {
            Send-OutputMonitorFailureNotification -Recovered
        }
        $script:OutputMonitorFailureCount = 0
        $script:OutputMonitorFailureAlerted = $false
    }
    $first = Get-BridgeFrameLuminance -Path $firstPath
    Remove-Item -LiteralPath $firstPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $first) { return }

    if ($first -gt $threshold) {
        if ($script:OutputBlackAlerted) {
            $script:OutputBlackAlerted = $false
            Write-BridgeLog "Output brightness recovered (luma $first)"
            Send-OutputBlackNotification -Recovered -Luminance $first
        }
        return
    }

    # Confirm before crying wolf: cuts and fades are legitimately black.
    Start-Sleep -Seconds ([math]::Max(1, (Get-SettingInt 'OutputBlackConfirmSeconds' 1)))
    $secondPath = Get-MonitorFrame -TimeoutSeconds $timeout
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
    Add-AuditEntry "🖤 تأكيد شاشة سوداء على المخرج (سطوع $second)"
    Send-OutputBlackNotification -Luminance $second
}

function Send-OutputMonitorFailureNotification {
    <# Reports a sustained inability to capture the configured output source,
       separately from the confirmed-black picture alarm. #>
    param([int]$FailureCount = 0, [switch]$Recovered)
    $text = if ($Recovered) {
        '💡 عاد الوصول إلى مخرج البث بعد تعذّر التقاطه.'
    }
    else {
        "⚠️ تعذّر الوصول إلى مخرج البث بعد $FailureCount محاولات متتالية.`nتحقّق من رابط المصدر وخادم البث."
    }
    Send-AdminBroadcast -Text $text -Urgent
}

function Send-OutputBlackNotification {
    <# Administrators always hear about a black output. Operators hear about it
       only if NotifyOperatorsOnBlackOutput is on, because during a planned
       break a broadcast to everyone is noise, not information. #>
    param([double]$Luminance = 0, [switch]$Recovered)
    $text = if ($Recovered) { "💡 عاد المخرج إلى الإضاءة الطبيعية (سطوع $Luminance)." }
    else { "🖤 المخرج أسود — تأكّد عبر لقطتين متتاليتين (سطوع $Luminance).`nتحقّق من المصدر وسلسلة البث." }
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
    if ($proc) { return "🟢 يعمل (PID $($proc.Id))" }
    if ($script:RelayState.ShouldRun) { return "🟠 متوقف - محاولة إعادة التشغيل" }
    return "⚪ متوقف"
}

function Build-RelayArguments {
    $ls = Get-ActiveLiveStreamConfig
    $rtmp = [string]$ls.RtmpDestination
    if ([string]::IsNullOrWhiteSpace($rtmp)) { throw "لم يتم ضبط رابط RTMP بعد - استخدم زر 🔗 رابط البث أولًا." }
    $sourceUrl = [string]$ls.SourceUrl
    if ([string]::IsNullOrWhiteSpace($sourceUrl)) { throw "LiveStream.SourceUrl غير مضبوط في config.json." }

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
    if (-not $ffmpeg) { throw "لم يتم العثور على ffmpeg.exe. ثبّته أولًا (winget install ffmpeg)." }
    $relayArgs = @(Build-RelayArguments)
    $stdoutLog = Join-Path $logDir "relay-stdout.log"
    $stderrLog = Join-Path $logDir "relay-stderr.log"

    # Quoted for the same reason as the snapshot: source URLs, RTMP keys and
    # paths can all contain spaces.
    $script:RelayState.Process = Start-BridgeMediaProcess -FilePath $ffmpeg -Arguments $relayArgs `
        -WorkingDirectory $scriptRoot -StandardOutputPath $stdoutLog -StandardErrorPath $stderrLog
    # pid + process start time, so a recycled PID cannot be mistaken for ours.
    $stamp = "$($script:RelayState.Process.Id)|$($script:RelayState.Process.StartTime.Ticks)"
    Set-Content -Path $relayPidFile -Value $stamp -Encoding ascii
    return $true
}

function Start-LiveRelay {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableLiveRelay')) {
        Send-TelegramMessage -ChatId $ChatId -Text "البث المباشر معطّل من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if (Get-RunningRelayProcess) {
        Send-TelegramMessage -ChatId $ChatId -Text "البث يعمل بالفعل." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
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
    Add-AuditEntry "▶️ بدء البث - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "⏳ جاري بدء البث..." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Stop-LiveRelay {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $script:RelayState.ShouldRun = $false
    $script:RelayState.VerifyAt = $null
    $proc = Get-RunningRelayProcess
    if (-not $proc) {
        Send-TelegramMessage -ChatId $ChatId -Text "لا يوجد بث يعمل حاليًا." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        Write-BridgeLog "User $UserId stopped live relay (PID $($proc.Id))"
        Add-AuditEntry "⏹ إيقاف البث - بواسطة $(Format-UserAuditActor -UserId $UserId)"
        Send-TelegramMessage -ChatId $ChatId -Text "⏹ تم إيقاف البث." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "فشل إيقاف البث: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
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
                $msg = "❌ توقف البث فورًا بعد التشغيل (كود $exitCode)."
                if ($detail) { $msg += "`nسبب ffmpeg: $detail" }
                Send-TelegramMessage -ChatId $notify -Text $msg -ReplyMarkup (Get-MainMenuKeyboard -ChatId $notify)
            }
        }
        elseif ($notify) {
            Send-TelegramMessage -ChatId $notify -Text "▶️ البث يعمل الآن." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $notify)
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
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text "⚠️ توقف البث المباشر (إعادة التشغيل التلقائي معطّلة)." }
        return
    }

    if ($decision.Action -eq 'give_up') {
        $script:RelayState.ShouldRun = $false
        Write-BridgeLog "Live relay exceeded RelayMaxRestarts ($maxRestarts) - giving up" "ERROR"
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text "⚠️ توقف البث نهائيًا بعد $maxRestarts محاولة إعادة تشغيل. راجع logs\relay-stderr.log." }
        return
    }

    $script:RelayState.Restarts=$decision.Restarts
    Write-BridgeLog "Live relay died - auto-restart attempt $($script:RelayState.Restarts)/$maxRestarts" "WARN"
    try {
        Start-RelayProcess | Out-Null
        $script:RelayState.VerifyAt = (Get-Date).AddSeconds(3)
        $script:RelayState.NotifyChatId = 0
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text "🔄 انقطع البث وتمت إعادة تشغيله تلقائيًا (محاولة $($script:RelayState.Restarts))." }
    }
    catch {
        Write-BridgeLog "Live relay auto-restart failed: $(Protect-SensitiveText $_.Exception.Message)" "ERROR"
    }
}

function Start-StreamUrlPrompt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'stream_url'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل رابط RTMP الكامل (الخادم + المفتاح معًا) من إعدادات بث فيديو تشات تليجرام:" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-StreamUrl {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    Clear-PendingState -ChatId $ChatId
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text "لم يتم إدخال رابط، لم يتغيّر شيء." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $state.UserId)
        return
    }
    $ls = Get-LiveStreamConfig
    $ls | Add-Member -NotePropertyName 'RtmpDestination' -NotePropertyValue $trimmed -Force
    Save-Config
    Write-BridgeLog "User $($state.UserId) updated LiveStream.RtmpDestination"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ تم حفظ رابط البث.$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $state.UserId)
}
