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
        if($hasId -and $actualId -ne [string](Get-CinegyStateProperty $TrackedRecord ActiveId)){
            $updated=Copy-CinegyTrackedRecord $TrackedRecord
            $updated.ActiveId=$actualId
            return [pscustomobject]@{Action='update';Record=$updated;Change=$null}
        }
        return [pscustomobject]@{Action='keep';Record=$TrackedRecord;Change=$null}
    }
    if(-not $DiscoverExternal -or -not $isOnAir){return [pscustomobject]@{Action='ignore';Record=$null;Change=$null}}
    $name=[string](Get-CinegyStateProperty $Status ActiveName)
    if([string]::IsNullOrWhiteSpace($name)){$name="مشهد خارجي · طبقة $Layer"}
    $record=@{Key=$name;At=$Now;UserId=0L;ActiveId=[string](Get-CinegyStateProperty $Status ActiveId);Source='cinegy'}
    return [pscustomobject]@{Action='add';Record=$record;Change=$null}
}

Export-ModuleMember -Function Resolve-BridgeCinegyLayerState
