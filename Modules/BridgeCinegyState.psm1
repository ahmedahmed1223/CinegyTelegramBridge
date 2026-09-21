Set-StrictMode -Version Latest

function Get-CinegyStateProperty {
    param($Object,[Parameter(Mandatory)][string]$Name)
    if($null -eq $Object){return $null}
    if($Object -is [hashtable]){if($Object.ContainsKey($Name)){return $Object[$Name]};return $null}
    if($Object.PSObject.Properties.Match($Name).Count -gt 0){return $Object.$Name}
    return $null
}

function Copy-CinegyTrackedRecord {
    param([hashtable]$Record)
    if(-not $Record){return $null}
    $copy=@{}
    foreach($key in $Record.Keys){$copy[$key]=$Record[$key]}
    return $copy
}

function Test-BridgeCinegyNamedScene {
    <#
        Does this status NAME a scene, or is it merely an item id?

        A spent or just-ended item stays Active on its layer with its Id
        intact and reports either no name at all or the placeholder "Item" -
        which is exactly what a genuinely empty layer reports. An Id on its
        own is therefore not evidence that anything is showing.

        Discovery has always known this (see the long note below it, and the
        phantom scene it was written for). The removal path did not: it called
        any non-empty ActiveId "externally replaced", so an operator whose own
        graphic had simply ended was told an unnamed stranger had taken the
        layer - while the log line for the very same decision said "Cinegy
        confirmed hidden". Two stories from one decision, and the alarming one
        was the wrong one.

        One rule, asked in both places.
    #>
    param([Parameter(Mandatory)]$Status)
    $name = [string](Get-CinegyStateProperty $Status ActiveTemplateName)
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-CinegyStateProperty $Status ActiveName) }
    return (-not [string]::IsNullOrWhiteSpace($name) -and $name -ne 'Item')
}

function Resolve-BridgeCinegyLayerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Layer,
        [hashtable]$TrackedRecord,
        [Parameter(Mandatory)]$Status,
        [switch]$DiscoverExternal,
        [datetime]$Now=(Get-Date)
    )
    if(-not [bool](Get-CinegyStateProperty $Status Success)){
        return [pscustomobject]@{Action='failed';Record=$TrackedRecord;Change=$null}
    }
    $isOnAir=[bool](Get-CinegyStateProperty $Status IsOnAir)
    if($TrackedRecord){
        if(-not $isOnAir){
            $change=[pscustomobject]@{
                Layer=$Layer;TemplateKey=[string](Get-CinegyStateProperty $TrackedRecord Key)
                ShowUserId=[long](Get-CinegyStateProperty $TrackedRecord UserId);ShownAt=(Get-CinegyStateProperty $TrackedRecord At)
                ExpectedActiveId=[string](Get-CinegyStateProperty $TrackedRecord ActiveId)
                ActualActiveId=[string](Get-CinegyStateProperty $Status ActiveId)
                ActualActiveName=[string](Get-CinegyStateProperty $Status ActiveName)
                OutputState=[string](Get-CinegyStateProperty $Status OutputState)
                ClientConnected=[bool](Get-CinegyStateProperty $Status ClientConnected)
                ClientIdentity=[string](Get-CinegyStateProperty $Status ClientIdentity)
                # Decided here, where the status is, rather than re-derived
                # from ActualActiveId by whoever writes the notice.
                Replaced=(Test-BridgeCinegyNamedScene -Status $Status)
            }
            return [pscustomobject]@{Action='remove';Record=$null;Change=$change}
        }
        $actualId=[string](Get-CinegyStateProperty $Status ActiveId)
        $normalized=$actualId.Trim().Trim('{','}')
        $hasId=-not [string]::IsNullOrWhiteSpace($normalized) -and $normalized -ne '00000000-0000-0000-0000-000000000000'
        $updated=$null
        if($hasId -and $actualId -ne [string](Get-CinegyStateProperty $TrackedRecord ActiveId)){
            $updated=Copy-CinegyTrackedRecord $TrackedRecord
            $updated.ActiveId=$actualId
        }
        $source=[string](Get-CinegyStateProperty $TrackedRecord Source)
        $templateName=[string](Get-CinegyStateProperty $Status ActiveTemplateName)
        # A discovered record survives a restart in onair.json, so one adopted
        # under the withdrawn rule would go on claiming air for ever - which is
        # exactly what happened to a bulletin that had already left the screen.
        # If the engine will not name what is on this layer, the bridge has no
        # ground to say a scene is showing there, and never had.
        #
        # Only DISCOVERED records are dropped this way. A bridge-pushed record
        # is the bridge's own knowledge of what it did, and is never
        # second-guessed by a read that cannot represent an exit.
        if($source -like 'cinegy*' -and [string]::IsNullOrWhiteSpace($templateName) -and
            [string]::IsNullOrWhiteSpace([string](Get-CinegyStateProperty $Status ActiveName))){
            return [pscustomobject]@{Action='remove';Record=$null;Change=$null}
        }
        if($source -eq 'cinegy' -and -not [string]::IsNullOrWhiteSpace($templateName) -and
            $templateName -ne [string](Get-CinegyStateProperty $TrackedRecord Key)){
            if(-not $updated){$updated=Copy-CinegyTrackedRecord $TrackedRecord}
            $updated.Key=$templateName
            $eventName=[string](Get-CinegyStateProperty $Status ActiveName)
            if(-not [string]::IsNullOrWhiteSpace($eventName)){$updated.CinegyEventName=$eventName}
        }
        if($updated){return [pscustomobject]@{Action='update';Record=$updated;Change=$null}}
        return [pscustomobject]@{Action='keep';Record=$TrackedRecord;Change=$null}
    }
    if(-not $DiscoverExternal -or -not $isOnAir){return [pscustomobject]@{Action='ignore';Record=$null;Change=$null}}
    $name=[string](Get-CinegyStateProperty $Status ActiveTemplateName)
    $cinegyEventName=[string](Get-CinegyStateProperty $Status ActiveName)
    if([string]::IsNullOrWhiteSpace($name)){$name=$cinegyEventName}
    # Discovery needs positive evidence, not merely "not marked empty".
    #
    # A spent or just-ended item stays Active on its layer, briefly with no
    # IsEmpty attribute at all, and reports the placeholder Name "Item" with
    # no Description - which is exactly what every genuinely empty layer
    # reports too. A real scene always carries a describing name, e.g.
    # "Show L band - New.CinTitle on Layer 4".
    #
    # Inventing "مشهد خارجي · طبقة N" for an anonymous item is what put a
    # phantom scene into onair.json at startup: the bot claimed layer 7 was
    # live when the screen was blank. Ambiguity must never ADD a record. It
    # still never removes one either - that asymmetry is deliberate.
    #
    # Naming an unnamed item from the template registry was tried here and
    # withdrawn. EXIT_SCENE_LOOP ends the animation but leaves the playlist
    # item Active under the same Id with no marker, so a bulletin that had
    # played its way off the screen got adopted as live and the bot announced
    # it for hours. Nothing the engine exposes separates the two cases:
    # IsOnAir, ActiveId, LogId, ScheduledAt, Duration, ManualEnd and
    # OutputState were identical on an exited layer and a visible one.
    #
    # An unnamed active item is not a claim this function is entitled to make.
    # The layers screen reads Cinegy live and already offers the hide button
    # for any layer the engine reports on air, so an operator loses no control
    # by this silence - only a claim that was not true.
    if(-not (Test-BridgeCinegyNamedScene -Status $Status)){
        return [pscustomobject]@{Action='ignore';Record=$null;Change=$null}
    }
    $record=@{Key=$name;At=$Now;UserId=0L;ActiveId=[string](Get-CinegyStateProperty $Status ActiveId);Source='cinegy'}
    if(-not [string]::IsNullOrWhiteSpace($cinegyEventName)){$record.CinegyEventName=$cinegyEventName}
    return [pscustomobject]@{Action='add';Record=$record;Change=$null}
}

function Get-BridgeCinegyStateBackoff {
    <#
        Decides how long to wait before the next tracked-layer reconciliation.

        Every reconciliation issues one synchronous HTTP status read per
        tracked GFX layer, on the single polling thread. With Air unreachable
        that costs layers x timeout of dead air on the bot for every tick, on
        the interval, indefinitely - and the operator finds a frozen bot at
        exactly the moment the playout machine is already in trouble.

        So an unreachable engine doubles the wait each time up to a ceiling,
        and the first successful reconciliation clears it. Returns 0 when
        healthy, meaning "use the configured interval, no extra wait".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$BaseIntervalSeconds,
        [ValidateRange(0, 3600)][int]$CurrentBackoffSeconds = 0,
        [switch]$Reachable,
        [ValidateRange(1, 3600)][int]$MaximumSeconds = 60
    )
    if ($Reachable) { return 0 }
    $next = if ($CurrentBackoffSeconds -lt $BaseIntervalSeconds) { $BaseIntervalSeconds * 2 }
    else { $CurrentBackoffSeconds * 2 }
    return [Math]::Min($next, $MaximumSeconds)
}
function Get-BridgeStaleOnAirLayers {
    <#
        Names bridge-pushed layers that have been on air implausibly long.

        A record can outlive the graphic it describes: the bridge can die
        between SHOW and EXIT, or a scene can be taken down inside Cinegy in a
        way the status endpoint cannot express. The bridge then reports a
        graphic that left the screen hours ago, and offers a hide button for
        nothing - which is exactly how a stale 'Urgent' record survived an
        EXIT and went unnoticed for an hour and a half.

        Only bridge-pushed records are considered: a Cinegy-owned scene such as
        a permanent ticker is legitimately up for days.

        This reports; it never removes. Deleting a record the operator can
        still see on screen would be worse than the stale one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$OnAir,
        [Parameter(Mandatory)][datetime]$Now,
        [ValidateRange(0, 168)][int]$ThresholdHours = 6,
        [object[]]$AlreadyAlerted = @()
    )
    if ($ThresholdHours -le 0) { return @() }
    $alerted = @($AlreadyAlerted | ForEach-Object { [int]$_ })
    $stale = foreach ($layer in ($OnAir.Keys | Sort-Object)) {
        $record = $OnAir[$layer]
        $source = if ($record.ContainsKey('Source')) { [string]$record.Source } else { 'bridge' }
        if ($source -ne 'bridge') { continue }
        if ($alerted -contains [int]$layer) { continue }
        $at = $record.At
        if ($at -isnot [datetime]) { continue }
        if (($Now - $at).TotalHours -lt $ThresholdHours) { continue }
        [pscustomobject]@{
            Layer = [int]$layer
            Key   = [string]$record.Key
            Hours = [math]::Floor(($Now - $at).TotalHours)
        }
    }
    return @($stale)
}
Export-ModuleMember -Function Test-BridgeCinegyNamedScene, Resolve-BridgeCinegyLayerState, Get-BridgeStaleOnAirLayers, Get-BridgeCinegyStateBackoff
