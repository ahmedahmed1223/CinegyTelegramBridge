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
    if([string]::IsNullOrWhiteSpace($name)){$name="مشهد خارجي · طبقة $Layer"}
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
Export-ModuleMember -Function Resolve-BridgeCinegyLayerState, Get-BridgeCinegyStateBackoff
