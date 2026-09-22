Set-StrictMode -Version Latest

<#
    The feed's outage ledger: when it went, when it came back, and why.

    The bridge already knew both facts and kept neither. A consecutive counter
    answers "is it down right now" and is reset by the next success; a
    six-hour list of failure moments answers "is it dying" and is pruned. So
    after the fact nobody could say how long the feed had been gone, or how
    often, and the answer to "what happened last night" was a grep through
    bridge.log for lines that do not say when the trouble ended.

    Pure: no config, no clock of its own, no disk. The caller passes the
    moment, which is what lets the rules be tested without a bridge - and the
    rules are the part worth testing, because both of them are easy to get
    wrong in a way nobody notices until they are asked for a report.
#>

function New-BridgeOutageLedger {
    <# An empty ledger. A list, not an array: it is appended to and trimmed. #>
    return [pscustomobject]@{
        SchemaVersion = 1
        Outages = [System.Collections.Generic.List[object]]::new()
    }
}

function Get-BridgeOpenOutage {
    <#
        The outage of this kind that has not ended yet, or nothing.

        Kind, not just "the last one": the feed can be unreachable and black
        at once - a source that dies mid-fade - and closing one on the other's
        recovery would file a two-second black screen as a four-hour outage.
    #>
    param([Parameter(Mandatory)]$Ledger, [Parameter(Mandatory)][string]$Kind)
    foreach ($outage in @($Ledger.Outages)) {
        if ([string]$outage.Kind -ne $Kind) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$outage.EndedAt)) { return $outage }
    }
    return $null
}

function Open-BridgeOutage {
    <#
        Records that the feed went, unless this kind is already recorded as
        gone.

        Idempotent on purpose. The watchdog calls this from a path that runs
        once per failed capture, and a source that is down stays down: without
        the guard an hour of trouble would be filed as sixty outages, and the
        screen meant to show what happened would bury it.
    #>
    param(
        [Parameter(Mandatory)]$Ledger,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][datetime]$At,
        [AllowEmptyString()][string]$Cause = '',
        [AllowEmptyString()][string]$Source = ''
    )
    $open = Get-BridgeOpenOutage -Ledger $Ledger -Kind $Kind
    if ($open) {
        # A later cause is better than the first: "the server is not
        # answering" beats the timeout that preceded it.
        if (-not [string]::IsNullOrWhiteSpace($Cause)) { $open.Cause = $Cause }
        return $open
    }
    $outage = [pscustomobject]@{
        Kind = $Kind
        StartedAt = $At.ToString('o')
        EndedAt = ''
        Cause = [string]$Cause
        Source = [string]$Source
    }
    $Ledger.Outages.Insert(0, $outage)
    return $outage
}

function Close-BridgeOutage {
    <#
        Records that the feed came back. Returns the outage that ended, or
        nothing when none of this kind was open - a recovery with no outage
        behind it is the ordinary case on a healthy channel, not a fault.
    #>
    param(
        [Parameter(Mandatory)]$Ledger,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][datetime]$At
    )
    $open = Get-BridgeOpenOutage -Ledger $Ledger -Kind $Kind
    if (-not $open) { return $null }
    # Never before it began. A clock corrected backwards while the feed was
    # down would otherwise file a negative outage, and every reader of this
    # ledger would have to defend itself against it.
    $started = [datetime]::Parse([string]$open.StartedAt, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $ended = if ($At -lt $started) { $started } else { $At }
    $open.EndedAt = $ended.ToString('o')
    return $open
}

function Get-BridgeOutageDurationSeconds {
    <#
        How long one outage lasted, in seconds. An outage still open is
        measured to Now, because "gone for three hours so far" is the number
        somebody wants while it is still gone.
    #>
    param([Parameter(Mandatory)]$Outage, [datetime]$Now = (Get-Date))
    $started = [datetime]::Parse([string]$Outage.StartedAt, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $ended = if ([string]::IsNullOrWhiteSpace([string]$Outage.EndedAt)) { $Now }
    else { [datetime]::Parse([string]$Outage.EndedAt, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    return [int][math]::Max(0, ($ended - $started).TotalSeconds)
}

function Limit-BridgeOutageLedger {
    <#
        Keeps the newest few and drops anything older than the window.

        Both, not either. A count alone lets a quiet month of nothing keep an
        outage from July on the screen; a window alone lets a bad night write
        four hundred rows into a file the bridge reads at every start.

        An outage still open is never dropped, however old: the feed being
        gone since Tuesday is exactly the row an operator opens this screen
        for.
    #>
    param(
        [Parameter(Mandatory)]$Ledger,
        [int]$Keep = 40,
        [int]$WindowDays = 30,
        [datetime]$Now = (Get-Date)
    )
    $cutoff = $Now.AddDays(-[math]::Max(1, $WindowDays))
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($outage in @($Ledger.Outages)) {
        if ([string]::IsNullOrWhiteSpace([string]$outage.EndedAt)) { $kept.Add($outage); continue }
        if ($kept.Count -ge [math]::Max(1, $Keep)) { continue }
        $started = [datetime]::Parse([string]$outage.StartedAt, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($started -lt $cutoff) { continue }
        $kept.Add($outage)
    }
    $Ledger.Outages = $kept
    return $Ledger
}

function Get-BridgeOutageSummary {
    <#
        What the screen says above the list: how many outages in the window,
        how long they cost in total, and when the feed was last whole.

        LastGoodAt is the end of the newest closed outage, or nothing when the
        ledger is empty - which reads as "no outage has been recorded", not as
        "the feed has never worked".
    #>
    param(
        [Parameter(Mandatory)]$Ledger,
        [int]$WindowHours = 24,
        [datetime]$Now = (Get-Date)
    )
    $since = $Now.AddHours(-[math]::Max(1, $WindowHours))
    $count = 0
    $seconds = 0
    $open = 0
    $lastGood = $null
    foreach ($outage in @($Ledger.Outages)) {
        $started = [datetime]::Parse([string]$outage.StartedAt, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $isOpen = [string]::IsNullOrWhiteSpace([string]$outage.EndedAt)
        if ($isOpen) { $open++ }
        elseif (-not $lastGood) {
            $lastGood = [datetime]::Parse([string]$outage.EndedAt, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
        if ($started -lt $since) { continue }
        $count++
        $seconds += (Get-BridgeOutageDurationSeconds -Outage $outage -Now $Now)
    }
    return [pscustomobject]@{
        Count = $count
        TotalSeconds = $seconds
        OpenCount = $open
        LastGoodAt = $lastGood
        WindowHours = [math]::Max(1, $WindowHours)
    }
}

Export-ModuleMember -Function New-BridgeOutageLedger, Get-BridgeOpenOutage, Open-BridgeOutage,
Close-BridgeOutage, Get-BridgeOutageDurationSeconds, Limit-BridgeOutageLedger, Get-BridgeOutageSummary
