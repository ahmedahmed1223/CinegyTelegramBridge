#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    The board on air: starting a run, walking it from the tick, the two ways a
    line can arrive, and the state that survives a restart mid-run.

    Split from Bridge.Urgent.ps1 before either was written. Bridge.Mojaz.ps1
    reached 2733 lines before it was cut into four, and the screens and the
    engine were the seam it was cut along.
#>

function Get-UrgentRunFile {
    return (Join-Path $logDir 'urgent-run.json')
}

function Get-UrgentManualFile {
    return (Join-Path $logDir 'urgent-manual.json')
}

function Get-UrgentElapsedSeconds {
    <# Monotonic, and anchored at the moment the scene actually went up.
       ClockOffset exists so a test can move time without a stopwatch. #>
    if (-not $script:UrgentBoardRun) { return 0.0 }
    return ([double]$script:UrgentBoardRun.Clock.Elapsed.TotalSeconds + [double]$script:UrgentBoardRun.ClockOffset)
}

function Save-UrgentRunState {
    <# Wall clock, not the stopwatch: after a restart the stopwatch is gone and
       this is the only thing that says how far in the run had got. #>
    if (-not $script:UrgentBoardRun) { return $false }
    $run = $script:UrgentBoardRun
    $state = [pscustomobject]@{
        SchemaVersion = 2
        SavedAt = (Get-Date).ToString('o')
        ElapsedSeconds = Get-UrgentElapsedSeconds
        Paused = [bool](Get-JsonProp $run 'Paused')
        StopFailed = [bool](Get-JsonProp $run 'StopFailed')
        StartedAt = [string]$run.StartedAt
        ChatId = [long]$run.ChatId
        UserId = [long]$run.UserId
        Step = [int]$run.Step
        Steps = @($run.Steps)
        ExitAtSeconds = [double]$run.ExitAtSeconds
        BoardRevision = [int]$run.BoardRevision
        OperationId = [string]$run.OperationId
        Summary = [string]$run.Summary
    }
    if (-not (Write-BridgeValidatedJson -Path (Get-UrgentRunFile) -Json ($state | ConvertTo-Json -Depth 12))) {
        Write-BridgeLog 'Could not write the urgent board run state.' 'WARN'
        return $false
    }
    return $true
}

function Clear-UrgentRunState {
    $path = Get-UrgentRunFile
    if (Test-Path -LiteralPath $path) {
        try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        catch { Write-BridgeLog "Could not remove urgent-run.json: $($_.Exception.Message)" 'WARN' }
    }
}

function Save-UrgentManualState {
    <# Persist the live manual show identity to disk so the hide button
       survives a restart. The operator was told a story is live and how
       to hide it; a restart must not take that promise off air with no
       way back.

       Also persists per-chat manual/auto mode and selections so table
       preferences survive a restart even when no manual show is active. #>
    $hasContent = ($script:UrgentManualLive -and $script:UrgentManualLive.Count -gt 0) -or
                  ($script:UrgentManualMode -and $script:UrgentManualMode.Count -gt 0) -or
                  ($script:UrgentSelections -and $script:UrgentSelections.Count -gt 0)

    if (-not $hasContent) {
        $path = Get-UrgentManualFile
        if (Test-Path -LiteralPath $path) {
            try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            catch { Write-BridgeLog "Could not remove urgent-manual.json: $($_.Exception.Message)" 'WARN' }
        }
        return $true
    }
    $payload = [pscustomobject]@{
        SchemaVersion = 2
        SavedAt = (Get-Date).ToString('o')
        States = @($script:UrgentManualLive.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ ChatId = [long]$_.Key; State = $_.Value }
        })
        ManualMode = @($script:UrgentManualMode.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ ChatId = [long]$_.Key; Mode = [bool]$_.Value }
        })
        Selections = @($script:UrgentSelections.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ ChatId = [string]$_.Key; Ids = @($_.Value) }
        })
    }
    if (-not (Write-BridgeValidatedJson -Path (Get-UrgentManualFile) -Json ($payload | ConvertTo-Json -Depth 8))) {
        Write-BridgeLog 'Could not write the urgent manual state.' 'WARN'
        return $false
    }
    return $true
}

function Import-UrgentManualState {
    <# Restore the manual show identity from disk at startup. Loads both
       $script:UrgentManualLive (hide button tokens) and
       $script:UrgentManualMode (per-chat manual/auto preference). #>
    $path = Get-UrgentManualFile
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $payload = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-BridgeLog "Could not read urgent-manual.json: $($_.Exception.Message)" 'WARN'
        return
    }
    if (-not $payload) { return }
    $states = Get-JsonProp $payload 'States'
    if ($states) {
        foreach ($entry in @($states)) {
            $cid = [long](Get-JsonProp $entry 'ChatId')
            if ($cid -gt 0) { $script:UrgentManualLive[$cid] = $entry.State }
        }
    }
    $modes = Get-JsonProp $payload 'ManualMode'
    if ($modes) {
        foreach ($entry in @($modes)) {
            $cid = [long](Get-JsonProp $entry 'ChatId')
            if ($cid -gt 0) { $script:UrgentManualMode[$cid] = [bool](Get-JsonProp $entry 'Mode') }
        }
    }
    $selections = Get-JsonProp $payload 'Selections'
    if ($selections) {
        foreach ($entry in @($selections)) {
            $cid = [string](Get-JsonProp $entry 'ChatId')
            if ($cid) { $script:UrgentSelections[$cid] = @(Get-JsonProp $entry 'Ids') }
        }
    }
}

function Write-UrgentRunEnd {
    <#
        Closes the run that Start-UrgentBoardRun opened.

        Without this the whole run appears in the reports as one air_control
        SHOW of the urgent scene - which says a graphic went up, and nothing
        about how many breaking lines it carried or why it ended.
    #>
    param($Run, [string]$Reason = 'finished', [long]$UserId = 0, [long]$ChatId = 0)
    if (-not $Run) { return }
    $template = Get-UrgentTemplate
    Write-AuditRecord -OperationId ([string]$Run.OperationId) -EventName urgent_board_run -Result $Reason `
        -UserId $(if ($UserId -gt 0) { $UserId } else { [long]$Run.UserId }) `
        -UserName (Get-UserDisplayName -UserId ([long]$Run.UserId)) `
        -ChatId $(if ($ChatId -gt 0) { $ChatId } else { [long]$Run.ChatId }) -Action STOP `
        -Layer $(if ($template) { [int]$template.Layer } else { 0 }) -Target 'urgent-board' `
        -Count (@($Run.Steps).Count) -Values ([string]$Run.Summary)
}

function Test-UrgentBoardOnAir {
    <# Is the board's scene occupied - by a run, or by a scene the bridge put
       there and has not taken down? #>
    $template = Get-UrgentTemplate
    if (-not $template) { return $false }
    if ($script:UrgentBoardRun) { return $true }
    return $script:OnAir.ContainsKey([int]$template.Layer)
}

function Start-UrgentBoardRun {
    <#
        Shows the first breaking line, then leaves the rest to the tick.

        The run works from a plan built here and never reads the board again,
        so editing the table mid-run changes what plays next time, not what is
        on air now.

        The first line goes up through Invoke-ShowTemplateResult like any other
        graphic: maintenance mode, the layer policy, the live Cinegy check and
        the audit trail are all on the path, and this screen does not get to
        skip them because it has an engine behind it.
    #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [switch]$SelectedOnly, [switch]$Force)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-UrgentBoardAvailable)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgp.boardOffOrNoTemplate')
        return $false
    }
    if ($script:UrgentBoardRun) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgp.alreadyRunning')
        return $false
    }
    $planResult = New-UrgentBoardPlan -ChatId $ChatId -SelectedOnly:$SelectedOnly
    if (-not $planResult.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgp.didNotStart' $([string]$planResult.Error)) -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $plan = $planResult.Value
    $steps = @($plan.Steps)
    $template = Get-UrgentTemplate

    # The board outranks the bulletin exactly as the single urgent does: the
    # scene is the same scene, and a bulletin left underneath it would keep
    # walking its own table behind a breaking line.
    if (-not $Force -and $script:MojazPlayback) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgp.bulletinOnAir') `
            -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }

    # Raised for exactly one call. The rule that a manual urgent stops a
    # running board reads the same key this SHOW carries, so without the flag
    # the board would be stopped by the very command that starts it - and
    # stopped AFTER reaching air, leaving a breaking line up with no engine
    # behind it and no screen saying so.
    $script:UrgentBoardStarting = $true
    try {
        $result = Invoke-ShowTemplateResult -Key $script:MojazUrgentKey `
            -Variables (Get-UrgentItemVariables -Item $steps[0]) -ChatId $ChatId -UserId $UserId
    }
    finally { $script:UrgentBoardStarting = $false }
    if (-not $result -or -not $result.Success) {
        $reason = if ($result) { [string](Get-JsonProp $result 'Error') } else { (T 'urgp.showFailed') }
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgp.boardDidNotStart' $reason) -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }

    $summary = Get-UrgentPlanSummary -Plan $plan
    $script:UrgentBoardRun = @{
        Step = 0
        ChatId = $ChatId
        UserId = $UserId
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
        ClockOffset = 0.0
        Steps = $steps
        ExitAtSeconds = [double]$plan.TotalSeconds
        BoardRevision = [int](Get-UrgentProperty $script:UrgentBoard 'Revision' 0)
        StartedAt = (Get-Date).ToString('o')
        Summary = $summary
        OperationId = "urgent-$([guid]::NewGuid().ToString('N'))"
    }
    Write-AuditRecord -OperationId ([string]$script:UrgentBoardRun.OperationId) -EventName urgent_board_run -Result started `
        -UserId $UserId -UserName (Get-UserDisplayName -UserId $UserId) -ChatId $ChatId -Action START `
        -Layer $(if ($template) { [int]$template.Layer } else { 0 }) -Target 'urgent-board' `
        -Count ($steps.Count) -Values $summary
    Save-UrgentRunState | Out-Null
    Write-BridgeLog "Urgent board run started by $UserId - $summary"
    foreach ($note in @(Get-UrgentProperty $plan 'Notes' @())) { Write-BridgeLog "Urgent board plan: $note" 'WARN' }
    Add-AuditEntry (T 'urgp.boardStarted' $($steps.Count) $(Format-UserAuditActor -UserId $UserId))
    Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId
    return $true
}

function Set-UrgentRunStopFailed {
    <#
        Freezes a run whose exit could not be confirmed and keeps it stoppable.

        A false answer, a thrown one, and a vanished template all land here:
        in each the scene's state is unknown, so the engine may not write
        again - but erasing the run would strand the breaking line on air with
        no engine and no retry. The flag is persisted, and the refusal it
        drives (Test-UrgentRunControl) survives a restart with it.
    #>
    param([Parameter(Mandatory)]$Run, [long]$ChatId = 0)
    $Run.Clock.Stop()
    $Run.Paused = $true
    $Run.StopFailed = $true
    $script:UrgentBoardRun = $Run
    Save-UrgentRunState | Out-Null
    if ($ChatId -gt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgp.exitUnconfirmed')
    }
    return $false
}

function Stop-UrgentBoardRun {
    <#
        Ends the run.

        -NoExit is for the callers that are already taking the layer off air
        themselves: a hide, an exit, a manual urgent replacing this one. Exiting
        again there would play an outro over whatever took its place.
    #>
    param([long]$ChatId = 0, [long]$UserId = 0, [string]$Reason = 'stopped', [switch]$Quiet, [switch]$NoExit)
    if (-not $script:UrgentBoardRun) { return $false }
    $run = $script:UrgentBoardRun
    # Detach only in memory to avoid Invoke-ExitLayer's recursive stop callback.
    # Keep the durable snapshot until exit has actually succeeded.
    $script:UrgentBoardRun = $null
    if (-not $NoExit) {
        $chat = if ($ChatId -gt 0) { $ChatId } else { [long]$run.ChatId }
        $user = if ($UserId -gt 0) { $UserId } else { [long]$run.UserId }
        $exited = $false
        try {
            $template = Get-UrgentTemplate
            if ($template) {
                # -System: board teardown, not an operator asking to leave.
                $exited = Invoke-ExitLayer -Layer ([int]$template.Layer) -ChatId $chat -UserId $user -System
            }
        }
        catch {
            # A missing template or a thrown exit cannot confirm removal.
            Write-BridgeLog "Urgent board exit attempt failed: $($_.Exception.Message)" 'WARN'
        }
        if (-not $exited) {
            # The engine must not continue writing to an uncertain scene,
            # but its stop button must survive a failed exit for retry.
            return (Set-UrgentRunStopFailed -Run $run -ChatId $chat)
        }
    }
    Clear-UrgentRunState
    Write-UrgentRunEnd -Run $run -Reason $Reason -UserId $UserId -ChatId $ChatId
    Write-BridgeLog "Urgent board run ended ($Reason) after $([int]$run.Step + 1) step(s)."
    if (-not $Quiet -and $ChatId -gt 0) { Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId }
    return $true
}

function Stop-UrgentBoardForLayer {
    <#
        The board's layer is being taken off air by something that is not this
        screen - the hide button, an exit, hide-all, a rollback.

        The run has to end with it, or it keeps writing lines into a scene
        nobody can see and then exits a layer that by then belongs to something
        else. The caller is already clearing the layer, so this does not exit
        again.
    #>
    param([Parameter(Mandatory)][int]$Layer)
    if (-not $script:UrgentBoardRun) { return $false }
    $template = Get-UrgentTemplate
    if (-not $template -or [int]$template.Layer -ne $Layer) { return $false }
    Write-BridgeLog "Urgent board run ended: layer $Layer was taken off air."
    return (Stop-UrgentBoardRun -Reason 'layer_cleared' -Quiet -NoExit)
}

function Stop-UrgentBoardForManualUrgent {
    <#
        A single urgent was pressed while the board was running.

        The older, simpler path wins: an operator reaching for the fixed button
        during a run is asking for that one line, now. The board stands down
        rather than fighting it for the same scene - and says so, because a
        table that stopped without a word reads as a table that finished.

        Skipped while the board's own opening SHOW is in flight: that SHOW
        carries this very key.
    #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if ($script:UrgentBoardStarting) { return $false }
    if (-not $script:UrgentBoardRun) { return $false }
    $chat = [long]$script:UrgentBoardRun.ChatId
    Stop-UrgentBoardRun -Reason 'manual_override' -Quiet -NoExit | Out-Null
    if ($chat -gt 0) {
        Send-TelegramMessage -ChatId $chat -Text (T 'urgp.stoppedBySingle')
    }
    Write-BridgeLog "Urgent board run stopped: a single urgent took the scene (user $UserId, chat $ChatId)."
    return $true
}

function Update-UrgentBoardRun {
    <#
        One step of the run, called from the tick.

        Each moment is absolute, measured from the start of the run, so a slow
        send delays its own line and none of the ones behind it. The tick is
        about a second apart - too coarse for a fade that lasts just over a
        second - so once a moment is close this waits out the remainder itself
        and sends on time. That blocks the bot for at most the pre-roll, once
        per line, which is the price of landing inside the window.

        The long poll is collapsed to one second while a run is live (see
        Get-EffectivePollTimeout); without that this would be called every
        thirty seconds and every window would be missed.
    #>
    if (-not $script:UrgentBoardRun) { return }
    $run = $script:UrgentBoardRun
    if ([bool](Get-JsonProp $run 'Paused')) { return }
    # A blank gap the station asked for, carried out here so the wait costs the
    # control loop nothing. Held before the step logic below, because during
    # the gap the next line's moment has usually already passed and the normal
    # path would step again over a layer that is deliberately empty.
    $pending = Get-JsonProp $run 'PendingShow'
    if ($pending) {
        if ((Get-UrgentElapsedSeconds) -lt [double]$pending.DueAt) { return }
        $run.PendingShow = $null
        $template = Get-UrgentTemplate
        if (-not $template) {
            Write-BridgeLog 'Urgent board: the scene vanished during the gap between lines.' 'WARN'
            Stop-UrgentBoardRun -Reason 'failed' -Quiet | Out-Null
            return
        }
        $shown = Show-UrgentBoardScene -Template $template -Values $pending.Values
        if (-not $shown.Success) {
            Write-BridgeLog "Urgent board could not return after the gap: $([string](Get-JsonProp $shown 'Error'))" 'WARN'
            Send-TelegramMessage -ChatId ([long]$run.ChatId) -Text (T 'urgp.stoppedNoReturn')
            Stop-UrgentBoardRun -Reason 'failed' -Quiet | Out-Null
            return
        }
        Save-UrgentRunState | Out-Null
        return
    }
    $steps = @($run.Steps)
    $index = [int]$run.Step
    $isLast = ($index -ge ($steps.Count - 1))
    $moment = if ($isLast) { [double]$run.ExitAtSeconds } else { [double]$steps[$index + 1].AtSeconds }
    # Sent early by the measured round trip, so it arrives on the moment rather
    # than after it.
    $target = $moment - ((Get-SettingInt 'UrgentSyncLeadMs' 120) / 1000.0)
    if ((Get-UrgentElapsedSeconds) -lt ($target - $script:UrgentPreRollSeconds)) { return }
    $remaining = $target - (Get-UrgentElapsedSeconds)
    if ($remaining -gt 0) {
        Start-Sleep -Milliseconds ([int][math]::Min(($script:UrgentPreRollSeconds * 1000), ($remaining * 1000)))
    }
    if ($isLast) {
        if (Stop-UrgentBoardRun -Reason 'finished' -Quiet) {
            Write-BridgeLog "Urgent board run finished after $($steps.Count) step(s)."
            if (Get-Setting 'UrgentBoardNotifyOnFinish') {
                Send-TelegramMessage -ChatId ([long]$run.ChatId) -Text (T 'urgp.ended')
            }
        }
        return
    }
    $index++
    $step = $steps[$index]
    $hidePrevious = [string]$steps[$index - 1].Mode -eq 'auto_hide'
    $sent = Send-UrgentBoardStep -Step $step -ForceExit:$hidePrevious
    if (-not $sent.Success) {
        Write-BridgeLog "Urgent board step $($index + 1) failed: $([string]$sent.Error)" 'WARN'
        Send-TelegramMessage -ChatId ([long]$run.ChatId) -Text (T 'urgp.stoppedAtStep' $($index + 1) $([string]$sent.Error))
        Stop-UrgentBoardRun -Reason 'failed' -Quiet | Out-Null
        return
    }
    $script:UrgentBoardRun.Step = $index
    Save-UrgentRunState | Out-Null
}

function Send-UrgentBoardStep {
    <#
        One breaking line onto the scene, in the mode that line asked for.

        text  - the values are written into the scene that is already up. The
                picture is never cut, and on a looping scene the change lands
                inside the fade where nobody sees it happen.
        exit  - the scene plays its outro and comes back with the new line. The
                separation is the point: this is a different story, not the next
                sentence of the same one.

        The exit path deliberately does not go through Invoke-ShowTemplateResult
        a second time. That would re-run the whole SHOW pipeline - the live
        layer check, a second audit record, another rollback candidate - once
        per line, on a clock measured in tenths of a second. The run was
        authorised once, at its start; this is the same authorised graphic
        continuing.
    #>
    param([Parameter(Mandatory)]$Step, [switch]$ForceExit)
    $values = Get-UrgentItemVariables -Item $Step
    if (-not $ForceExit -and [string]$Step.Mode -ne 'exit') {
        $posted = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Values $values -TimeoutSec (Get-AirTimeout)
        if (Get-Setting 'LogAirXml') { Write-BridgeLog "Urgent board POSTBOX XML: $($posted.Xml)" }
        return $posted
    }
    $template = Get-UrgentTemplate
    if (-not $template) { return [pscustomobject]@{ Success = $false; Error = (T 'urgp.noTemplate') } }
    $layer = [int]$template.Layer
    $exit = Exit-TitlerScene -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $layer -TimeoutSec (Get-AirTimeout)
    if (-not $exit.Success) { return $exit }
    # The outro has to finish before the scene can be shown again, and the
    # scene itself says how long that is.
    $outro = 0.0
    $timing = Get-UrgentSceneTiming
    if ($timing) { $outro = [math]::Max(0.0, [double](Get-JsonProp $timing 'OutroSeconds')) }
    # A deliberate blank gap between stories, when the station asked for one.
    # Waited by the tick rather than here: an operator may set this to a
    # minute, and Start-Sleep would hold the whole control loop for it - the
    # auto-hide timers, the schedule, the heartbeat and every button press.
    $gap = [double](Get-SettingInt 'UrgentExitGapSeconds' 0)
    if ($gap -gt 0 -and $script:UrgentBoardRun) {
        $script:UrgentBoardRun.PendingShow = @{
            DueAt = (Get-UrgentElapsedSeconds) + $outro + $gap
            Values = $values
        }
        return [pscustomobject]@{ Success = $true; Error = ''; Deferred = $true }
    }
    if ($outro -gt 0) { Start-Sleep -Milliseconds ([int]($outro * 1000)) }
    return (Show-UrgentBoardScene -Template $template -Values $values)
}

function Show-UrgentBoardScene {
    <#
        Puts the breaking scene back up with this line's values.

        The HIDE first is the whole point, and its absence was the bug: a scene
        already loaded on the layer keeps running with the values it was
        started with, so showing it again re-ran the entrance and left the
        PREVIOUS line's text on screen. Every story after the first was the
        first story again, with an exit animation between them - which is
        exactly what an operator reported.

        EXIT_SCENE_LOOP is not enough on its own: it tells the scene to leave
        its loop and play the outro, but the item stays loaded on the layer.
        Invoke-ShowTemplateResult has cleared the layer before a re-show since
        ReshowClearsLayer was written, and says why in its own comment; this
        path bypasses that funnel deliberately and so never inherited it.
    #>
    param([Parameter(Mandatory)]$Template, [Parameter(Mandatory)]$Values)
    $layer = [int]$Template.Layer
    $clear = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $layer -TimeoutSec (Get-AirTimeout)
    # Reported, not fatal: a failed clear is the exact condition under which
    # the show below puts the previous line back on air, so it has to be
    # findable in the log when somebody asks why a story repeated.
    if (-not $clear.Success) {
        Write-BridgeLog "Urgent board: could not clear layer $layer before the next line; the scene may keep its previous text: $([string]$clear.Error)" 'WARN'
    }
    return (Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $layer -TemplatePath ([string]$Template.Path) -Variables $Values -TimeoutSec (Get-AirTimeout) `
            -Device ([string](Get-JsonProp $Template 'Device')))
}

function Restore-UrgentBoardRun {
    <#
        A run that was on air when the bridge stopped is not on air now.

        Three endings, the same three the bulletin has. The layer is no longer
        the board's - somebody dealt with it already - so the file is dropped.
        The run is past its end - the scene is sitting there with nobody to
        take it off - so it is ended properly. Otherwise it rejoins its own
        schedule, which the absolute moments make possible: elapsed time alone
        says which line is due.
    #>
    param([datetime]$Now = (Get-Date))
    $path = Get-UrgentRunFile
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $state = $null
    try { $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-BridgeLog "Could not read urgent-run.json: $($_.Exception.Message)" 'WARN'
        Clear-UrgentRunState
        return $false
    }
    Clear-UrgentRunState
    $startedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string](Get-JsonProp $state 'StartedAt'), [ref]$startedAt)) { return $false }
    $template = Get-UrgentTemplate
    if (-not $template) { return $false }
    $layer = [int]$template.Layer
    if (-not $script:OnAir.ContainsKey($layer) -or
        [string](Get-JsonProp $script:OnAir[$layer] 'Key') -ne $script:MojazUrgentKey) {
        Write-BridgeLog 'An urgent board run was interrupted; its scene no longer owns the layer, so the run was dropped.'
        return $false
    }
    $paused = (Get-JsonProp $state 'Paused') -eq $true
    $elapsed = ($Now - $startedAt).TotalSeconds
    if ([int](Get-JsonProp $state 'SchemaVersion') -ge 2) {
        $savedAt = [datetime]::MinValue
        if (-not [datetime]::TryParse([string](Get-JsonProp $state 'SavedAt'), [ref]$savedAt)) { return $false }
        $elapsed = [double](Get-JsonProp $state 'ElapsedSeconds')
        if (-not $paused) { $elapsed += [math]::Max(0.0, ($Now - $savedAt).TotalSeconds) }
    }
    $steps = @(Get-JsonProp $state 'Steps')
    $exitAt = [double](Get-JsonProp $state 'ExitAtSeconds')
    if ($steps.Count -lt 1) { return $false }
    # V2 Step is the last successfully sent line. Downtime must not advance
    # it without a send; the next tick will deliver the first overdue line.
    $step = [int](Get-JsonProp $state 'Step')
    if ([int](Get-JsonProp $state 'SchemaVersion') -ge 2) {
        if ($step -lt 0 -or $step -ge $steps.Count) { return $false }
    }
    else {
        # Preserve the legacy wall-clock-only recovery contract.
        $step = 0
        for ($index = 0; $index -lt $steps.Count; $index++) {
            if ([double]$steps[$index].AtSeconds -le $elapsed) { $step = $index }
        }
    }
    $script:UrgentBoardRun = @{
        Step = $step
        ChatId = [long](Get-JsonProp $state 'ChatId')
        UserId = [long](Get-JsonProp $state 'UserId')
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
        # The stopwatch starts at zero now, so the elapsed time before the
        # restart is carried as an offset rather than pretended away.
        ClockOffset = [double]$elapsed
        Paused = $paused
        StopFailed = [bool](Get-JsonProp $state 'StopFailed')
        Steps = $steps
        ExitAtSeconds = $exitAt
        BoardRevision = [int](Get-JsonProp $state 'BoardRevision')
        StartedAt = $startedAt.ToString('o')
        Summary = [string](Get-JsonProp $state 'Summary')
        OperationId = [string](Get-JsonProp $state 'OperationId')
    }
    if ($paused) { $script:UrgentBoardRun.Clock.Reset() }
    Save-UrgentRunState | Out-Null
    if ($elapsed -ge $exitAt) {
        Write-BridgeLog 'An urgent board run outlived the restart; taking its scene off air.'
        Stop-UrgentBoardRun -Reason 'expired' -Quiet | Out-Null
        return $false
    }
    Write-BridgeLog "An urgent board run resumed after a restart at step $($step + 1) of $($steps.Count)."
    $restoreStatus = if ($paused) { (T 'urgp.stayedPaused') } else { (T 'urgp.resumed') }
    Send-AdminBroadcast -Text (T 'urgp.afterRestart' $restoreStatus $($step + 1) $($steps.Count)) | Out-Null
    return $true
}

function Test-UrgentRunControl {
    param([long]$ChatId, [long]$UserId)
    if (-not $script:UrgentBoardRun) { return $false }
    if ([bool](Get-JsonProp $script:UrgentBoardRun 'StopFailed')) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgp.exitUnsure')
        return $false
    }
    $template = Get-UrgentTemplate
    if (-not $template) { return $false }
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return $false }
    $access = Test-TemplateAccess -Key $script:MojazUrgentKey -Layer ([int]$template.Layer) -ChatId $ChatId -UserId $UserId
    if (-not $access.Allowed) {
        Send-TelegramMessage -ChatId $ChatId -Text $access.Reason
        return $false
    }
    return $true
}

function Suspend-UrgentBoardRun {
    param([long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-UrgentRunControl -ChatId $ChatId -UserId $UserId)) { return $false }
    $script:UrgentBoardRun.Clock.Stop()
    $script:UrgentBoardRun.Paused = $true
    Save-UrgentRunState | Out-Null
    return $true
}

function Resume-UrgentBoardRun {
    param([long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-UrgentRunControl -ChatId $ChatId -UserId $UserId)) { return $false }
    $script:UrgentBoardRun.Paused = $false
    $script:UrgentBoardRun.Clock.Start()
    Save-UrgentRunState | Out-Null
    return $true
}

function Move-UrgentBoardNext {
    # Step means successfully displayed, never merely selected. Force a full
    # transition even when the next line normally uses the postbox.
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-UrgentRunControl -ChatId $ChatId -UserId $UserId)) { return $false }
    $run = $script:UrgentBoardRun
    $next = [int]$run.Step + 1
    if ($next -ge @($run.Steps).Count) {
        return (Stop-UrgentBoardRun -Reason 'skip_last' -ChatId $ChatId -UserId $UserId -Quiet)
    }
    $step = $run.Steps[$next]
    $sent = Send-UrgentBoardStep -Step $step -ForceExit
    if (-not $sent.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'urgp.cannotAdvance')
        Stop-UrgentBoardRun -Reason 'skip_failed' -ChatId $ChatId -UserId $UserId -Quiet -NoExit | Out-Null
        return $false
    }
    $run.Step = $next
    $run.Clock.Restart()
    $run.ClockOffset = [double]$step.AtSeconds
    $run.Paused = $false
    Save-UrgentRunState | Out-Null
    Add-AuditEntry (T 'urgp.skipped' $(Format-UserAuditActor -UserId $UserId))
    return $true
}
