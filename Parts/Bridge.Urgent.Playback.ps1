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
        SchemaVersion = 1
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
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ جدول العواجل غير مفعّل أو لا قالب له.'
        return $false
    }
    if ($script:UrgentBoardRun) {
        Send-TelegramMessage -ChatId $ChatId -Text 'جدول العواجل يعمل بالفعل.'
        return $false
    }
    $planResult = New-UrgentBoardPlan -ChatId $ChatId -SelectedOnly:$SelectedOnly
    if (-not $planResult.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لم يبدأ التشغيل: $([string]$planResult.Error)" -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
        return $false
    }
    $plan = $planResult.Value
    $steps = @($plan.Steps)
    $template = Get-UrgentTemplate

    # The board outranks the bulletin exactly as the single urgent does: the
    # scene is the same scene, and a bulletin left underneath it would keep
    # walking its own table behind a breaking line.
    if (-not $Force -and $script:MojazPlayback) {
        Send-TelegramMessage -ChatId $ChatId -Text '📑 الموجز على الهواء. ابدأ الجدول بعد إيقافه، أو أوقفه من شاشته.' `
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
        $reason = if ($result) { [string](Get-JsonProp $result 'Error') } else { 'تعذّر العرض' }
        Send-TelegramMessage -ChatId $ChatId -Text "❌ لم يبدأ جدول العواجل: $reason" -ReplyMarkup (Get-UrgentBoardKeyboard -ChatId $ChatId)
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
    Add-AuditEntry "🚨 تشغيل جدول العواجل ($($steps.Count) خطوة) - بواسطة $(Format-UserAuditActor -UserId $UserId)"
    Show-UrgentBoardScreen -ChatId $ChatId -UserId $UserId
    return $true
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
    $script:UrgentBoardRun = $null
    Clear-UrgentRunState
    if (-not $NoExit) {
        $template = Get-UrgentTemplate
        if ($template) {
            $chat = if ($ChatId -gt 0) { $ChatId } else { [long]$run.ChatId }
            $user = if ($UserId -gt 0) { $UserId } else { [long]$run.UserId }
            Invoke-ExitLayer -Layer ([int]$template.Layer) -ChatId $chat -UserId $user | Out-Null
        }
    }
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
        Send-TelegramMessage -ChatId $chat -Text '⏹ توقّف جدول العواجل: أُرسل عاجل مفرد على المشهد نفسه.'
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
        Write-BridgeLog "Urgent board run finished after $($steps.Count) step(s)."
        if (Get-Setting 'UrgentBoardNotifyOnFinish') {
            Send-TelegramMessage -ChatId ([long]$run.ChatId) -Text '⏹ انتهى جدول العواجل وخرج عن الهواء.'
        }
        Stop-UrgentBoardRun -Reason 'finished' -Quiet | Out-Null
        return
    }
    $index++
    $step = $steps[$index]
    $sent = Send-UrgentBoardStep -Step $step
    if (-not $sent.Success) {
        Write-BridgeLog "Urgent board step $($index + 1) failed: $([string]$sent.Error)" 'WARN'
        Send-TelegramMessage -ChatId ([long]$run.ChatId) -Text "❌ توقّف جدول العواجل عند الخطوة $($index + 1): $([string]$sent.Error)"
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
    param([Parameter(Mandatory)]$Step)
    $values = Get-UrgentItemVariables -Item $Step
    if ([string]$Step.Mode -ne 'exit') {
        $posted = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Values $values -TimeoutSec (Get-AirTimeout)
        if (Get-Setting 'LogAirXml') { Write-BridgeLog "Urgent board POSTBOX XML: $($posted.Xml)" }
        return $posted
    }
    $template = Get-UrgentTemplate
    if (-not $template) { return [pscustomobject]@{ Success = $false; Error = 'لا قالب للعاجل.' } }
    $layer = [int]$template.Layer
    $exit = Exit-TitlerScene -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $layer -TimeoutSec (Get-AirTimeout)
    if (-not $exit.Success) { return $exit }
    # The outro has to finish before the scene can be shown again, and the
    # scene itself says how long that is.
    $outro = 0.0
    $timing = Get-UrgentSceneTiming
    if ($timing) { $outro = [math]::Max(0.0, [double](Get-JsonProp $timing 'OutroSeconds')) }
    if ($outro -gt 0) { Start-Sleep -Milliseconds ([int]($outro * 1000)) }
    return (Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $layer -TemplatePath ([string]$template.Path) -Variables $values -TimeoutSec (Get-AirTimeout) `
            -Device ([string](Get-JsonProp $template 'Device')))
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
    if (-not $script:OnAir.ContainsKey($layer)) {
        Write-BridgeLog 'An urgent board run was interrupted; its layer is no longer on air, so the run was dropped.'
        return $false
    }
    $elapsed = ($Now - $startedAt).TotalSeconds
    $steps = @(Get-JsonProp $state 'Steps')
    $exitAt = [double](Get-JsonProp $state 'ExitAtSeconds')
    if ($steps.Count -lt 1) { return $false }
    if ($elapsed -ge $exitAt) {
        Write-BridgeLog 'An urgent board run outlived the restart; taking its scene off air.'
        Invoke-ExitLayer -Layer $layer -ChatId ([long](Get-JsonProp $state 'ChatId')) -UserId ([long](Get-JsonProp $state 'UserId')) | Out-Null
        return $false
    }
    # Which line the clock says should be up now.
    $step = 0
    for ($index = 0; $index -lt $steps.Count; $index++) {
        if ([double]$steps[$index].AtSeconds -le $elapsed) { $step = $index }
    }
    $script:UrgentBoardRun = @{
        Step = $step
        ChatId = [long](Get-JsonProp $state 'ChatId')
        UserId = [long](Get-JsonProp $state 'UserId')
        Clock = [System.Diagnostics.Stopwatch]::StartNew()
        # The stopwatch starts at zero now, so the elapsed time before the
        # restart is carried as an offset rather than pretended away.
        ClockOffset = [double]$elapsed
        Steps = $steps
        ExitAtSeconds = $exitAt
        BoardRevision = [int](Get-JsonProp $state 'BoardRevision')
        StartedAt = $startedAt.ToString('o')
        Summary = [string](Get-JsonProp $state 'Summary')
        OperationId = [string](Get-JsonProp $state 'OperationId')
    }
    Save-UrgentRunState | Out-Null
    Write-BridgeLog "An urgent board run resumed after a restart at step $($step + 1) of $($steps.Count)."
    Send-AdminBroadcast -Text "🚨 استأنف جدول العواجل بعد إعادة التشغيل عند الخطوة $($step + 1) من $($steps.Count)." | Out-Null
    return $true
}
