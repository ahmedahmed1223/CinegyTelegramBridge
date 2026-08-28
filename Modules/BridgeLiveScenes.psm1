#requires -Version 7
Set-StrictMode -Version Latest

function Get-BridgeLiveSceneValue {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-BridgeLegacySceneId {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)]$Record
    )
    $material = @(
        $Layer
        [string](Get-BridgeLiveSceneValue -Object $Record -Name 'Key')
        [string](Get-BridgeLiveSceneValue -Object $Record -Name 'ActiveId')
        [string](Get-BridgeLiveSceneValue -Object $Record -Name 'At')
    ) -join '|'
    $bytes = [Text.Encoding]::UTF8.GetBytes($material)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return "legacy-$(([Convert]::ToHexString($hash)).Substring(0, 16).ToLowerInvariant())"
}

function New-BridgeLiveSceneRecord {
    param(
        [Parameter(Mandatory)]$Record,
        [AllowNull()][int]$LegacyLayer,
        [switch]$Legacy
    )
    $layerValue = if ($Legacy) { $LegacyLayer } else { Get-BridgeLiveSceneValue -Object $Record -Name 'Layer' }
    $layer = 0
    if (-not [int]::TryParse([string]$layerValue, [ref]$layer) -or $layer -lt 0) {
        throw 'scene layer must be a non-negative integer'
    }
    $sceneId = [string](Get-BridgeLiveSceneValue -Object $Record -Name 'SceneId')
    if ($Legacy) { $sceneId = Get-BridgeLegacySceneId -Layer $layer -Record $Record }
    if ([string]::IsNullOrWhiteSpace($sceneId)) { throw 'scene identity is required' }

    $at = Get-BridgeLiveSceneValue -Object $Record -Name 'At'
    return [pscustomobject]@{
        SceneId  = $sceneId.Trim()
        Layer    = $layer
        Key      = [string](Get-BridgeLiveSceneValue -Object $Record -Name 'Key')
        At       = if ($null -eq $at) { '' } else { [string]$at }
        UserId   = [long](Get-BridgeLiveSceneValue -Object $Record -Name 'UserId')
        ChatId   = [long](Get-BridgeLiveSceneValue -Object $Record -Name 'ChatId')
        ActiveId = [string](Get-BridgeLiveSceneValue -Object $Record -Name 'ActiveId')
        Source   = if ([string]::IsNullOrWhiteSpace([string](Get-BridgeLiveSceneValue -Object $Record -Name 'Source'))) { 'bridge' } else { [string](Get-BridgeLiveSceneValue -Object $Record -Name 'Source') }
        TemplatePath = [string](Get-BridgeLiveSceneValue -Object $Record -Name 'TemplatePath')
        LastVerifiedAtUtc = [string](Get-BridgeLiveSceneValue -Object $Record -Name 'LastVerifiedAtUtc')
    }
}

function ConvertTo-BridgeLiveSceneState {
    [OutputType([pscustomobject])]
    param([AllowNull()]$Document)

    try {
        $payload = Get-BridgeLiveSceneValue -Object $Document -Name 'Data'
        if ($null -eq $payload) { $payload = $Document }
        $canonicalScenes = Get-BridgeLiveSceneValue -Object $payload -Name 'Scenes'
        $scenes = [System.Collections.Generic.List[object]]::new()
        $identities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        if ($null -ne $canonicalScenes) {
            foreach ($record in @($canonicalScenes)) {
                $scene = New-BridgeLiveSceneRecord -Record $record
                if (-not $identities.Add($scene.SceneId)) { throw "duplicate scene identity '$($scene.SceneId)'" }
                $scenes.Add($scene)
            }
        }
        elseif ($null -ne $payload) {
            if ($payload -is [System.Collections.IDictionary]) {
                $entries = @($payload.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
            }
            else {
                $entries = @($payload.PSObject.Properties)
            }
            foreach ($entry in $entries) {
                $layer = 0
                if (-not [int]::TryParse([string]$entry.Name, [ref]$layer)) { continue }
                $scene = New-BridgeLiveSceneRecord -Record $entry.Value -LegacyLayer $layer -Legacy
                if (-not $identities.Add($scene.SceneId)) { throw "duplicate scene identity '$($scene.SceneId)'" }
                $scenes.Add($scene)
            }
        }

        return [pscustomobject]@{
            Success = $true
            SchemaVersion = 1
            Scenes = @($scenes)
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            SchemaVersion = 1
            Scenes = @()
            Error = $_.Exception.Message
        }
    }
}

function Get-BridgeLiveScenesForLayer {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$Layer
    )
    return @((Get-BridgeLiveSceneValue -Object $State -Name 'Scenes') | Where-Object { [int]$_.Layer -eq $Layer })
}

function Get-BridgeLiveScenes {
    param([Parameter(Mandatory)]$State)
    return @(Get-BridgeLiveSceneValue -Object $State -Name 'Scenes')
}

function Get-BridgeLiveScene {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$SceneId
    )
    return @(Get-BridgeLiveScenes -State $State | Where-Object { $_.SceneId -ieq $SceneId } | Select-Object -First 1)[0]
}

function Get-BridgePrimarySceneForLayer {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][int]$Layer
    )
    return @(Get-BridgeLiveScenesForLayer -State $State -Layer $Layer | Select-Object -First 1)[0]
}

function Test-BridgeSceneMode {
    param(
        [ValidateSet('Single', 'Multi')][string]$RequestedMode = 'Single',
        [Parameter(Mandatory)]$Capabilities
    )
    $verified = [bool](Get-BridgeLiveSceneValue -Object $Capabilities -Name 'Verified')
    if ($RequestedMode -eq 'Multi' -and $verified) {
        return [pscustomobject]@{ Mode = 'Multi'; Verified = $true; Error = '' }
    }
    $error = if ($RequestedMode -eq 'Multi') {
        $detail = [string](Get-BridgeLiveSceneValue -Object $Capabilities -Name 'Error')
        if ([string]::IsNullOrWhiteSpace($detail)) { 'وضع المشاهد المتعددة غير متاح حتى يثبت Cinegy الهوية والاستهداف المباشر.' } else { "وضع المشاهد المتعددة غير متاح: $detail" }
    }
    else { '' }
    return [pscustomobject]@{ Mode = 'Single'; Verified = $verified; Error = $error }
}

Export-ModuleMember -Function ConvertTo-BridgeLiveSceneState, Get-BridgeLiveScenes, Get-BridgeLiveScenesForLayer, Get-BridgeLiveScene, Get-BridgePrimarySceneForLayer, Test-BridgeSceneMode
