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

function Resolve-BridgeCinegyLayerState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Layer,
        [hashtable]$TrackedRecord,
        [Parameter(Mandatory)]$Status,
        [switch]$DiscoverExternal,
        [string]$RegisteredTemplateName='',
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
    # Not every engine names what it plays, though, and this one names none of
    # it: every Active element it returns is <Item Id=.. LogId=.. ScheduledAt=..
    # Duration=.. ManualEnd=..> with no Name and no Description at all. So the
    # rule above refused every layer and external discovery never once fired
    # here - the news strip was on air, the engine said so, and the bot's menu
    # did not list it, so nobody could hide it from the bot.
    #
    # Hence a second route, which invents nothing either: hard evidence that a
    # real item is playing rather than the husk of a spent one, plus a name the
    # caller already knew - the template registered for that layer. Missing
    # either, this still ignores the layer. Ambiguity must never ADD a record.
    $inferred=$false
    if([string]::IsNullOrWhiteSpace($name) -or $name -eq 'Item'){
        if([string]::IsNullOrWhiteSpace($RegisteredTemplateName) -or
            -not (Test-BridgeCinegyActiveItem -Status $Status)){
            return [pscustomobject]@{Action='ignore';Record=$null;Change=$null}
        }
        $name=$RegisteredTemplateName
        $inferred=$true
    }
    # An unnamed item proves a scene is LOADED on the layer. It does not prove
    # anything is rendering, and on this engine it cannot: EXIT_SCENE_LOOP ends
    # the animation but leaves the playlist item Active under the same Id with
    # no IsEmpty marker, so a layer that has played its way off the screen
    # reads exactly like one still playing. Remove-OnAirRecord says the same
    # thing from the other side - it is why the bridge drops its own record
    # after an EXIT rather than trusting a later read.
    #
    # So it is adopted, because the operator still needs the button that
    # releases the layer - but under a source that says the claim is
    # unverified, and every screen showing it says so instead of calling it
    # live.
    $source=if($inferred){'cinegy-unconfirmed'}else{'cinegy'}
    $record=@{Key=$name;At=$Now;UserId=0L;ActiveId=[string](Get-CinegyStateProperty $Status ActiveId);Source=$source}
    if(-not [string]::IsNullOrWhiteSpace($cinegyEventName)){$record.CinegyEventName=$cinegyEventName}
    return [pscustomobject]@{Action='add';Record=$record;Change=$null}
}

function Test-BridgeCinegyActiveItem {
    <#
        Is a real item playing on this layer, or is this the anonymous husk a
        spent one leaves behind?

        That husk is why the naming rule refused anything unnamed: it stays
        Active for a moment after its item ends and reads like a live one. But
        the two are not actually alike. A real item carries the engine's own
        log identity and the moment it was scheduled; a placeholder carries
        neither, and a genuinely empty layer reports the zero GUID.

        All three must hold. Any one of them alone is how a phantom scene got
        into onair.json and the bot claimed a blank layer was live.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Status)
    $activeId=([string](Get-CinegyStateProperty $Status ActiveId)).Trim().Trim('{','}')
    if([string]::IsNullOrWhiteSpace($activeId) -or $activeId -eq '00000000-0000-0000-0000-000000000000'){return $false}
    $xml=[string](Get-CinegyStateProperty $Status ActiveXml)
    if([string]::IsNullOrWhiteSpace($xml)){return $false}
    # When the engine says so outright, believe it and stop.
    if([regex]::IsMatch($xml,'IsEmpty\s*=\s*"y"','IgnoreCase')){return $false}
    $logId=[regex]::Match($xml,'LogId\s*=\s*"([^"]*)"')
    if(-not $logId.Success){return $false}
    $normalizedLogId=$logId.Groups[1].Value.Trim().Trim('{','}')
    if([string]::IsNullOrWhiteSpace($normalizedLogId) -or $normalizedLogId -eq '00000000-0000-0000-0000-000000000000'){return $false}
    $scheduled=[regex]::Match($xml,'ScheduledAt\s*=\s*"([^"]*)"')
    if(-not $scheduled.Success){return $false}
    $parsed=[datetime]::MinValue
    return [datetime]::TryParse($scheduled.Groups[1].Value,[ref]$parsed)
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
Export-ModuleMember -Function Resolve-BridgeCinegyLayerState, Test-BridgeCinegyActiveItem, Get-BridgeStaleOnAirLayers, Get-BridgeCinegyStateBackoff
