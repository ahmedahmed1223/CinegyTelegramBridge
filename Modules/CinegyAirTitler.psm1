#requires -Version 7
<#
    CinegyAirTitler.psm1

    Reusable functions for talking to Cinegy Air Pro's built-in HTTP control
    surfaces. Refactored out of the example scripts in
    https://github.com/Cinegy/Cinegy.Powershell (Titler/*.ps1) so they can be
    called programmatically instead of being edited-and-run by hand.

    Two HTTP endpoints are used, both served directly by the Air Pro engine
    instance (port = 5521 + channel/instance number):

      POST http://<host>:<port>/video/command
        Generic "Event" command channel. Used here to SHOW / HIDE / EXIT a
        Titler (graphics) layer. XML shape:
          <Request>
            <Event Device="*GFX_<layer>" Cmd="SHOW|HIDE|EXIT_SCENE_LOOP">
              <Op1>path to .cintitle scene (SHOW only)</Op1>
              <Op2>&lt;Variables&gt;&lt;Var Name="Field.Text" Type="String" Value="..."/&gt;&lt;/Variables&gt;</Op2>
              <Op3></Op3>
            </Event>
          </Request>

      POST http://<host>:<port>/postbox
        Live-variable update channel. Used to push new values into a scene
        that is already on air, without re-triggering SHOW. XML shape:
          <PostRequest>
            <SetValue Name="Field.Text" Type="Text|String|Bool|Float" Value="..." />
          </PostRequest>

    Both endpoints are documented only by example in the Cinegy repo above.
    Playlist transport commands (PLAY/PAUSE/CUE/SKIP) are NOT demonstrated
    anywhere in that repo, so this module does not claim specific Device/Cmd
    values for them - see Send-AirCommand for a generic escape hatch and
    confirm exact values with Cinegy support/documentation before using it
    for transport control.
#>

Set-StrictMode -Version Latest

function ConvertTo-XmlSafeValue {
    <#
        Minimal XML-attribute/text escaping for values coming from chat input.

        AllowEmptyString is required, not cosmetic: a Mandatory [string]
        parameter REJECTS '' with "Cannot bind argument to parameter 'Value'
        because it is an empty string", which used to crash any push that
        carried a blank field value.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [System.Security.SecurityElement]::Escape($Value)
}

function Send-AirCommand {
    <#
        .SYNOPSIS
        Generic low-level POST to the Air Pro /video/command endpoint.

        .DESCRIPTION
        Exposed as an escape hatch for Device/Cmd combinations not wrapped by
        a dedicated function below. Confirm exact values against Cinegy's
        Air Remote Control documentation - do not guess in production.
    #>
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [Parameter(Mandatory)][string]$Device,
        [Parameter(Mandatory)][string]$Cmd,
        [string]$EventId = "",
        [string]$Op1 = "",
        [string]$Op2 = "",
        [string]$Op3 = "",
        [int]$TimeoutSec = 10
    )

    $xmlDoc = New-Object System.Xml.XmlDocument
    $decl = $xmlDoc.CreateXmlDeclaration("1.0", "UTF-8", $null)
    $xmlRootElem = $xmlDoc.AppendChild($xmlDoc.CreateElement('Request'))
    $xmlDoc.InsertBefore($decl, $xmlDoc.DocumentElement) | Out-Null

    $xmlEventElem = $xmlRootElem.AppendChild($xmlDoc.CreateElement('Event'))

    $devAttr = $xmlDoc.CreateAttribute('Device'); $devAttr.Value = $Device
    $xmlEventElem.Attributes.Append($devAttr) | Out-Null

    $cmdAttr = $xmlDoc.CreateAttribute('Cmd'); $cmdAttr.Value = $Cmd
    $xmlEventElem.Attributes.Append($cmdAttr) | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($EventId)) {
        $idAttr = $xmlDoc.CreateAttribute('Id'); $idAttr.Value = $EventId
        $xmlEventElem.Attributes.Append($idAttr) | Out-Null
    }

    foreach ($pair in @(@('Op1', $Op1), @('Op2', $Op2), @('Op3', $Op3))) {
        $opElem = $xmlDoc.CreateElement($pair[0])
        $opElem.InnerText = $pair[1]
        $xmlEventElem.AppendChild($opElem) | Out-Null
    }

    $uri = "http://$($AirServerAddress):$(5521 + $AirChannelNumber)/video/command"

    try {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Body $xmlDoc.OuterXml `
            -ContentType "text/xml; charset=utf-8" -TimeoutSec $TimeoutSec -UseBasicParsing
        # Both paths carry every field. A caller that reads .Error to log what
        # went wrong, or .StatusCode to log what went right, must not crash
        # under StrictMode for asking on the wrong branch.
        return [pscustomobject]@{ Success = $true; StatusCode = $response.StatusCode; Error = ''; Uri = $uri; Xml = $xmlDoc.OuterXml }
    }
    catch {
        return [pscustomobject]@{ Success = $false; StatusCode = 0; Error = $_.Exception.Message; Uri = $uri; Xml = $xmlDoc.OuterXml }
    }
}

$script:AirLayerDevices = @{}

function Set-AirLayerDeviceMap {
    <# Registers which layer numbers are addressed by a device name instead of
       gfx_<n>. Called by the bridge whenever templates.json is parsed. #>
    [CmdletBinding()]
    param([hashtable]$Map = @{})
    $script:AirLayerDevices = @{}
    foreach ($layer in $Map.Keys) {
        $name = [string]$Map[$layer]
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $script:AirLayerDevices[[int]$layer] = $name
    }
}

function Resolve-AirGfxDevice {
    <#
        Maps a template's layer to the Cinegy device that carries it.

        Almost every graphics layer is numeric: device *GFX_7, status path
        gfx_7. The logo is not - Air Pro exposes it as a named device, and its
        own active item describes itself as "Show logo_mov.cintitle as logo"
        rather than "on layer N". Verified against the running engine:
        gfx_logo answers with a live scene while gfx_9 and friends do not
        exist at all.

        A template therefore may declare `device` to name that layer instead
        of relying on its number. The number is still what the bridge keys its
        own bookkeeping on, so it must stay unique across templates.
    #>
    param([string]$Device = '', [int]$Layer = 0)
    # Falls back to the map the bridge registers from templates.json, so the
    # twenty existing call sites keep passing a plain layer number and only
    # this one place knows that some layers are named.
    if ([string]::IsNullOrWhiteSpace($Device) -and $script:AirLayerDevices.ContainsKey($Layer)) {
        $Device = [string]$script:AirLayerDevices[$Layer]
    }
    if (-not [string]::IsNullOrWhiteSpace($Device)) {
        $clean = $Device.Trim()
        if ($clean -notmatch '^[A-Za-z0-9_]{1,32}$') { throw "Invalid Cinegy device name '$Device'." }
        return [pscustomobject]@{ Command = "*GFX_$($clean.ToUpperInvariant())"; StatusPath = "gfx_$($clean.ToLowerInvariant())" }
    }
    return [pscustomobject]@{ Command = "*GFX_$Layer"; StatusPath = "gfx_$Layer" }
}

function Show-TitlerTemplate {
    <#
        .SYNOPSIS
        Pushes a Titler (.cintitle) scene on-air on a given GFX layer, with
        an optional set of field values.

        .PARAMETER Variables
        Hashtable of Field Name -> Value, e.g. @{ 'TopText.Text' = 'Breaking News'; 'BottomText.Text' = '...' }
    #>
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [Parameter(Mandatory)][int]$Layer,
        [string]$Device = '',
        [Parameter(Mandatory)][string]$TemplatePath,
        [hashtable]$Variables = @{},
        # Per-variable type overrides, e.g. @{ 'Score.Value' = 'Float' }.
        [hashtable]$Types = @{},
        # Type used when a variable has no explicit override.
        #
        # Cinegy's published sample uses Type="String" here, but a scene that
        # accepts Type="Text" on the /postbox endpoint can silently IGNORE the
        # same variable sent as "String" on SHOW - Air still answers 200 OK, so
        # the graphic simply keeps its previous text with no error anywhere.
        # "Text" matches what the postbox channel proved to accept.
        [string]$DefaultType = 'Text',
        [int]$TimeoutSec = 10
    )

    $variableXml = "<Variables>"
    foreach ($key in $Variables.Keys) {
        $safeName = ConvertTo-XmlSafeValue -Value $key
        $safeValue = ConvertTo-XmlSafeValue -Value ([string]$Variables[$key])
        $type = if ($Types.ContainsKey($key)) { [string]$Types[$key] } else { $DefaultType }
        $safeType = ConvertTo-XmlSafeValue -Value $type
        $variableXml += "<Var Name=""$safeName"" Type=""$safeType"" Value=""$safeValue"" />"
    }
    $variableXml += "</Variables>"

    $eventId = "{$([guid]::NewGuid().ToString().ToUpperInvariant())}"
    $result = Send-AirCommand -AirServerAddress $AirServerAddress -AirChannelNumber $AirChannelNumber `
        -Device (Resolve-AirGfxDevice -Device $Device -Layer $Layer).Command -Cmd "SHOW" -EventId $eventId -Op1 $TemplatePath `
        -Op2 $variableXml -TimeoutSec $TimeoutSec
    $result | Add-Member -NotePropertyName EventId -NotePropertyValue $eventId -Force
    return $result
}

function Hide-TitlerTemplate {
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [Parameter(Mandatory)][int]$Layer,
        [string]$Device = '',
        [int]$TimeoutSec = 10
    )
    Send-AirCommand -AirServerAddress $AirServerAddress -AirChannelNumber $AirChannelNumber `
        -Device (Resolve-AirGfxDevice -Device $Device -Layer $Layer).Command -Cmd "HIDE" -TimeoutSec $TimeoutSec
}

function Exit-TitlerScene {
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [Parameter(Mandatory)][int]$Layer,
        [string]$Device = '',
        [int]$TimeoutSec = 10
    )
    Send-AirCommand -AirServerAddress $AirServerAddress -AirChannelNumber $AirChannelNumber `
        -Device (Resolve-AirGfxDevice -Device $Device -Layer $Layer).Command -Cmd "EXIT_SCENE_LOOP" -TimeoutSec $TimeoutSec
}

function Send-PostboxValues {
    <#
        .SYNOPSIS
        Pushes one or more live variable updates into whatever Titler scene
        is currently on air, via the /postbox endpoint (no re-trigger of SHOW).

        .PARAMETER Values
        Hashtable of Name -> Value. Type is inferred as Bool/Float/String
        unless overridden per-key via -Types.
    #>
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [Parameter(Mandatory)][hashtable]$Values,
        [hashtable]$Types = @{},
        [int]$TimeoutSec = 10
    )

    $xmlDoc = New-Object System.Xml.XmlDocument
    $rootElem = $xmlDoc.AppendChild($xmlDoc.CreateElement('PostRequest'))

    foreach ($name in $Values.Keys) {
        $type = if ($Types.ContainsKey($name)) { $Types[$name] } else { 'Text' }
        $setValueElem = $rootElem.AppendChild($xmlDoc.CreateElement('SetValue'))
        $setValueElem.SetAttribute("Name", $name)
        $setValueElem.SetAttribute("Type", $type)
        $setValueElem.SetAttribute("Value", [string]$Values[$name])
    }

    $uri = "http://$($AirServerAddress):$(5521 + $AirChannelNumber)/postbox"

    try {
        $response = Invoke-WebRequest -Uri $uri -Method Post -Body $xmlDoc.OuterXml `
            -ContentType "text/xml; charset=utf-8" -TimeoutSec $TimeoutSec -UseBasicParsing
        # Both paths carry every field. A caller that reads .Error to log what
        # went wrong, or .StatusCode to log what went right, must not crash
        # under StrictMode for asking on the wrong branch.
        return [pscustomobject]@{ Success = $true; StatusCode = $response.StatusCode; Error = ''; Uri = $uri; Xml = $xmlDoc.OuterXml }
    }
    catch {
        return [pscustomobject]@{ Success = $false; StatusCode = 0; Error = $_.Exception.Message; Uri = $uri; Xml = $xmlDoc.OuterXml }
    }
}

function Get-TitlerLayerStatus {
    <#
        .SYNOPSIS
        Reads the actual active state of one Cinegy Title/GFX layer.

        .DESCRIPTION
        Cinegy exposes each graphics layer as gfx_<n>. GET /status identifies
        the active playlist item, but that item remains present after HIDE or
        EXIT. GET /status/active distinguishes the blank filler by returning
        IsEmpty="y". A failed request deliberately returns IsOnAir = $null:
        callers must preserve their last-known state rather than mistake a
        network failure for a hidden graphic.
    #>
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [Parameter(Mandatory)][int]$Layer,
        [string]$Device = '',
        [int]$TimeoutSec = 10
    )

    $uri = "http://$($AirServerAddress):$(5521 + $AirChannelNumber)/$((Resolve-AirGfxDevice -Device $Device -Layer $Layer).StatusPath)/status"
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing
        $xml = [xml]$response.Content
        $activeNode = $xml.SelectSingleNode('/Status/Active')
        $licenseNode = $xml.SelectSingleNode('/Status/License')
        $outputNode = $xml.SelectSingleNode('/Status/Output')
        $clientNode = $xml.SelectSingleNode('/Status/Client')
        $activeId = if ($activeNode) { [string]$activeNode.GetAttribute('Id') } else { '' }
        $licenseState = if ($licenseNode) { [string]$licenseNode.GetAttribute('State') } else { '' }
        $outputState = if ($outputNode) { [string]$outputNode.GetAttribute('State') } else { '' }
        $clientConnected = $false
        $clientIdentity = ''
        if ($clientNode) {
            $clientConnected = ([string]$clientNode.GetAttribute('Connected')) -match '^(?i:y|yes|true|1)$'
            $clientIdentity = [string]$clientNode.GetAttribute('Identity')
        }
        $normalizedId = $activeId.Trim().Trim('{', '}')
        $hasActiveItem = -not [string]::IsNullOrWhiteSpace($normalizedId) -and
            $normalizedId -ne '00000000-0000-0000-0000-000000000000'
        $isOnAir = $false
        # Why the layer is off air, kept because the log could not say.
        # 'no-active-item' never reaches /status/active at all, and
        # 'empty-item' is the engine's own IsEmpty="y" filler; both used
        # to be written as "Cinegy confirmed hidden", which is the one
        # question the log is asked when a graphic leaves by itself.
        $offAirReason = 'no-active-item'
        $activeItemXml = ''
        $activeName = ''
        $activeDescription = ''
        $activeTemplateName = ''
        $activeDurationSeconds = 0
        $activeManualEnd = $false

        if ($hasActiveItem) {
            $activeUri = "$uri/active"
            $activeResponse = Invoke-WebRequest -Uri $activeUri -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing
            $activeItemXml = [string]$activeResponse.Content
            $activeXml = [xml]$activeItemXml
            $itemNode = $activeXml.SelectSingleNode('/Item')
            if (-not $itemNode) { throw "Cinegy active status did not contain an Item element." }
            $isEmpty = [string]$itemNode.GetAttribute('IsEmpty')
            $isOnAir = $isEmpty -notmatch '^(?i:y|yes|true|1)$'
            $offAirReason = if ($isOnAir) { '' } else { 'empty-item' }
            $activeName = [string]$itemNode.GetAttribute('Name')
            $activeDescription = [string]$itemNode.GetAttribute('Description')
            if ($activeDescription -match '(?i)^\s*(?:Show|Play|Take)\s+(?:.*[\\/])?(?<Template>.+?)\.cintitle(?:\s+on\s+layer\s+\d+)?\s*$') {
                $activeTemplateName = [string]$Matches.Template
            }
            # How long Cinegy intends this item to stay up. A ticker carries
            # Duration="24:00:00.000" ManualEnd="y" - it is not a graphic
            # somebody forgot to take down, and the staleness alert has no
            # business calling it one.
            # Parsed by hand rather than with TimeSpan.TryParse, which rejects
            # the very value this exists for: a ticker reads "24:00:00.000",
            # and TryParse requires the hour field to be 0-23, so it returned
            # false and the duration silently read as zero.
            if ([string]$itemNode.GetAttribute('Duration') -match
                '^\s*(?:(?<d>\d+)\.)?(?<h>\d+):(?<m>\d{1,2}):(?<s>\d{1,2}(?:\.\d+)?)\s*$') {
                $seconds = ([double]$Matches.h) * 3600 + ([double]$Matches.m) * 60 +
                    [double]::Parse($Matches.s, [Globalization.CultureInfo]::InvariantCulture)
                # ContainsKey, not $Matches.d: an optional group that did not
                # participate is absent from the hashtable, and reading it
                # under StrictMode throws rather than returning empty.
                if ($Matches.ContainsKey('d')) { $seconds += ([double]$Matches.d) * 86400 }
                $activeDurationSeconds = [int][math]::Min([int]::MaxValue, $seconds)
            }
            $activeManualEnd = ([string]$itemNode.GetAttribute('ManualEnd')) -match '^(?i:y|yes|true|1)$'
        }

        return [pscustomobject]@{
            Success    = $true
            IsOnAir    = $isOnAir
            OffAirReason = $offAirReason
            ActiveId   = $activeId
            ActiveName = $activeName
            ActiveTemplateName = $activeTemplateName
            ActiveDescription = $activeDescription
            ActiveDurationSeconds = $activeDurationSeconds
            ActiveManualEnd = $activeManualEnd
            LicenseState = $licenseState
            OutputState = $outputState
            ClientConnected = $clientConnected
            ClientIdentity = $clientIdentity
            StatusCode = $response.StatusCode
            Error       = ''
            Uri         = $uri
            Xml         = $response.Content
            ActiveXml   = $activeItemXml
        }
    }
    catch {
        # Same field set as the success path. A caller reading a field that
        # exists only when the call worked crashes under StrictMode exactly
        # when the engine is already in trouble - the worst possible moment.
        return [pscustomobject]@{
            Success  = $false
            IsOnAir  = $null
            OffAirReason = 'unreadable'
            ActiveId = ''
            ActiveName = ''
            ActiveTemplateName = ''
            ActiveDescription = ''
            ActiveDurationSeconds = 0
            ActiveManualEnd = $false
            LicenseState = ''
            OutputState = ''
            ClientConnected = $false
            ClientIdentity = ''
            StatusCode = 0
            Error    = $_.Exception.Message
            Uri      = $uri
            Xml      = ''
            ActiveXml = ''
        }
    }
}

function Get-AirTelemetryStatus {
    <# Reads Cinegy Air's one-minute, one-second-interval telemetry history.
       Counters are aggregated for an operator-friendly summary. A failed or
       empty response returns Healthy = $null so callers never report an
       unavailable engine as healthy.

       The tolerances exist because the counters had none. One dropped frame
       inside the sixty-sample window turned the whole channel unhealthy, and
       the next check - the window having rolled past it - turned it healthy
       again: 54 health transitions in a day on a channel that was fine.
       Playout drops the occasional frame. A threshold is what separates a
       drop worth waking someone for from one that is just television. #>
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [int]$TimeoutSec = 10,
        [ValidateRange(0, 100000)][int]$FrameLossTolerance = 0,
        [ValidateRange(0, 100)][double]$FrameLossTolerancePercent = 0,
        [ValidateRange(0, 100)][double]$ReadErrorRateTolerance = 0
    )

    $uri = "http://$($AirServerAddress):$(5521 + $AirChannelNumber)/metrics"
    try {
        $response = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing
        $xml = [xml]$response.Content
        $nodes = @($xml.SelectNodes('/Metrics/At'))
        if ($nodes.Count -eq 0) {
            return [pscustomobject]@{
                Success = $true; Healthy = $null; SampleCount = 0
                OutputCount = 0L; DroppedCount = 0L; NoInputSignal = 0L
                AverageReadTime = 0.0; MaxReadErrorRate = 0.0; MaxHeartbeat = 0L; DroppedPercent = 0.0
                Issues = @('No telemetry samples'); StatusCode = $response.StatusCode
                Error = ''; Uri = $uri; Xml = $response.Content
            }
        }

        [long]$outputCount = 0
        [long]$droppedCount = 0
        [long]$noInputSignal = 0
        [double]$readTimeTotal = 0
        [double]$maxReadErrorRate = 0
        [long]$maxHeartbeat = 0
        foreach ($node in $nodes) {
            $outputCount += [long]$node.GetAttribute('OutputCount')
            $droppedCount += [long]$node.GetAttribute('DroppedCount')
            $noInputSignal += [long]$node.GetAttribute('NoInputSignal')
            $readTime = [double]::Parse([string]$node.GetAttribute('AverageReadTime'), [Globalization.CultureInfo]::InvariantCulture)
            $readErrorRate = [double]::Parse([string]$node.GetAttribute('ReadErrorRate'), [Globalization.CultureInfo]::InvariantCulture)
            $heartbeat = [long]$node.GetAttribute('Heartbeat')
            $readTimeTotal += $readTime
            if ($readErrorRate -gt $maxReadErrorRate) { $maxReadErrorRate = $readErrorRate }
            if ($heartbeat -gt $maxHeartbeat) { $maxHeartbeat = $heartbeat }
        }

        # Counted against a tolerance, but always reported with the raw number:
        # "within tolerance" must never read as "nothing happened".
        # A share of what actually went out, not a bare count. Thirty-four
        # dropped frames sounds alarming and is 2.3% of 1467 - a count alone
        # cannot tell those apart, and the window is not a fixed size. Both
        # thresholds must be crossed: the count keeps a tiny sample from
        # raising an alarm on percentages, the percentage keeps a busy minute
        # from raising one on counts.
        $droppedPercent = if ($outputCount -gt 0) { [Math]::Round((100 * $droppedCount / $outputCount), 2) } else { 0 }
        $noInputPercent = if ($outputCount -gt 0) { [Math]::Round((100 * $noInputSignal / $outputCount), 2) } else { 0 }

        $issues = [System.Collections.Generic.List[string]]::new()
        if ($droppedCount -gt $FrameLossTolerance -and $droppedPercent -gt $FrameLossTolerancePercent) {
            $issues.Add("Dropped frames: $droppedCount ($droppedPercent%)")
        }
        if ($noInputSignal -gt $FrameLossTolerance -and $noInputPercent -gt $FrameLossTolerancePercent) {
            $issues.Add("Missing input frames: $noInputSignal ($noInputPercent%)")
        }
        if ($maxReadErrorRate -gt $ReadErrorRateTolerance) { $issues.Add("Read error rate: $maxReadErrorRate%") }

        return [pscustomobject]@{
            Success = $true
            Healthy = ($issues.Count -eq 0)
            SampleCount = $nodes.Count
            OutputCount = $outputCount
            DroppedCount = $droppedCount
            NoInputSignal = $noInputSignal
            AverageReadTime = [Math]::Round(($readTimeTotal / $nodes.Count), 2)
            MaxReadErrorRate = $maxReadErrorRate
            MaxHeartbeat = $maxHeartbeat
            DroppedPercent = $droppedPercent
            Issues = $issues.ToArray()
            StatusCode = $response.StatusCode
            Error = ''
            Uri = $uri
            Xml = $response.Content
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false; Healthy = $null; SampleCount = 0
            OutputCount = 0L; DroppedCount = 0L; NoInputSignal = 0L
            AverageReadTime = 0.0; MaxReadErrorRate = 0.0; MaxHeartbeat = 0L; DroppedPercent = 0.0
            Issues = @(); StatusCode = 0; Error = $_.Exception.Message; Uri = $uri; Xml = ''
        }
    }
}

function Get-CinegySceneCapabilities {
    <#
        Verifies the documented Cinegy layer-catalog model: many named
        templates/items may target one layer, while control and status remain
        layer-scoped and expose one active item identity at a time.
    #>
    param(
        [object[]]$SceneItems = @(),
        [bool]$LayerTargetSupported = $false,
        [bool]$DirectTargetSupported = $false
    )
    $items = @($SceneItems)
    $identifiedActiveItems = 0
    $canIdentifyActiveItem = $items.Count -gt 0
    foreach ($item in $items) {
        $isOnAirProperty = $item.PSObject.Properties['IsOnAir']
        if ($null -ne $isOnAirProperty -and -not [bool]$isOnAirProperty.Value) { continue }
        $activeIdProperty = $item.PSObject.Properties['ActiveId']
        $sceneIdProperty = $item.PSObject.Properties['SceneId']
        $identity = if ($null -ne $activeIdProperty) { [string]$activeIdProperty.Value } elseif ($null -ne $sceneIdProperty) { [string]$sceneIdProperty.Value } else { '' }
        $normalizedIdentity = $identity.Trim().Trim('{', '}')
        if ([string]::IsNullOrWhiteSpace($normalizedIdentity) -or
            $normalizedIdentity -eq '00000000-0000-0000-0000-000000000000') {
            $canIdentifyActiveItem = $false
            break
        }
        $identifiedActiveItems++
    }
    if ($identifiedActiveItems -eq 0) { $canIdentifyActiveItem = $false }
    $verified = $canIdentifyActiveItem -and $LayerTargetSupported
    $capabilityError = if ($verified) { '' }
    elseif (-not $canIdentifyActiveItem) { 'Cinegy لم يثبت هوية العنصر النشط على الطبقة.' }
    else { 'Cinegy لم يثبت أوامر التحكم المباشر بالطبقة.' }
    return [pscustomobject]@{
        Semantics = 'LayerCatalog'
        CanListScenes = $canIdentifyActiveItem
        CanIdentifyActiveItem = $canIdentifyActiveItem
        CanTargetLayer = $LayerTargetSupported
        CanTargetScene = $DirectTargetSupported
        Verified = $verified
        Error = $capabilityError
    }
}

# ConvertTo-XmlSafeValue is an implementation detail. Tests exercise it inside the
# module scope so importing the module exposes only its supported commands.
function ConvertFrom-AirItemNode {
    <# One <Item/> from a video list, as something the screens can use.

       Durations arrive as "01:00:00.040" and moments as UTC with a Z; both are
       parsed here rather than in every caller, and an unparsable one yields a
       zero rather than throwing - a schedule with one malformed row is still
       worth showing. #>
    param([Parameter(Mandatory)]$Node)
    $scheduled = [datetimeoffset]::MinValue
    [void][datetimeoffset]::TryParse([string]$Node.GetAttribute('ScheduledAt'), [ref]$scheduled)
    $duration = [timespan]::Zero
    [void][timespan]::TryParse([string]$Node.GetAttribute('Duration'), [ref]$duration)
    $progress = 0
    [void][int]::TryParse([string]$Node.GetAttribute('ProxyProgress'), [ref]$progress)
    return [pscustomobject]@{
        Id = [string]$Node.GetAttribute('Id')
        Name = [string]$Node.GetAttribute('Name')
        ScheduledAt = $scheduled
        Duration = $duration
        LoopStart = ([string]$Node.GetAttribute('LoopStart')) -match '^(?i:y|yes|true|1)$'
        ProxyProgress = $progress
    }
}

function Get-AirVideoStatus {
    <#
        .SYNOPSIS
        What the channel is playing now, and what it has cued next.

        .DESCRIPTION
        The bridge has always known what IT put on air and nothing about the
        programme running underneath, so an operator opened Cinegy to find out
        which item was playing. The video device answers both in one read.

        Unlike the graphics layers, whose Cued id is a null guid in this
        workflow, /video/status carries real ids for both - so "on now" and
        "next up" are answerable. Ids are returned bare; matching them to names
        is the caller's job via Get-AirMaterialSchedule.

        A failed request returns Success = $false with everything else empty,
        never a guess.
    #>
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [int]$TimeoutSec = 10
    )
    $uri = "http://$($AirServerAddress):$(5521 + $AirChannelNumber)/video/status"
    try {
        $xml = [xml](Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing).Content
        $empty = '00000000-0000-0000-0000-000000000000'
        $read = {
            param($Path)
            $node = $xml.SelectSingleNode($Path)
            if (-not $node) { return '' }
            $id = ([string]$node.GetAttribute('Id')).Trim().Trim('{', '}')
            if ($id -eq $empty) { return '' }
            return $id
        }
        $outputNode = $xml.SelectSingleNode('/Status/Output')
        $licenseNode = $xml.SelectSingleNode('/Status/License')
        return [pscustomobject]@{
            Success = $true
            ActiveId = [string](& $read '/Status/Active')
            CuedId = [string](& $read '/Status/Cued')
            OutputState = if ($outputNode) { [string]$outputNode.GetAttribute('State') } else { '' }
            License = if ($licenseNode) { [string]$licenseNode.GetAttribute('State') } else { '' }
            Error = ''
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; ActiveId = ''; CuedId = ''; OutputState = ''; License = ''; Error = [string]$_.Exception.Message }
    }
}

function Get-AirMaterialSchedule {
    <#
        .SYNOPSIS
        The channel playout schedule - the programmes, not the graphics.

        .DESCRIPTION
        GET /video/list returns the material Cinegy holds for the channel with
        the time each is due, its duration, and how far its proxy has been
        built. Measured on a live channel at twenty-four items in about four
        and a half kilobytes for a full day, which is small - but a holiday
        schedule is not this one, so callers still page or trim before putting
        it on a screen.

        Ids match those in Get-AirVideoStatus, which is how "on now" gets a
        name instead of a guid.
    #>
    param(
        [Parameter(Mandatory)][string]$AirServerAddress,
        [Parameter(Mandatory)][int]$AirChannelNumber,
        [int]$TimeoutSec = 10
    )
    $uri = "http://$($AirServerAddress):$(5521 + $AirChannelNumber)/video/list"
    try {
        $xml = [xml](Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing).Content
        $items = @(foreach ($node in @($xml.SelectNodes('/List/Item'))) { ConvertFrom-AirItemNode -Node $node })
        return [pscustomobject]@{ Success = $true; Items = @($items | Sort-Object ScheduledAt); Error = '' }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Items = @(); Error = [string]$_.Exception.Message }
    }
}

Export-ModuleMember -Function Set-AirLayerDeviceMap, Resolve-AirGfxDevice, Send-AirCommand, Show-TitlerTemplate, Hide-TitlerTemplate, Exit-TitlerScene, Send-PostboxValues, Get-TitlerLayerStatus, Get-AirTelemetryStatus, Get-CinegySceneCapabilities, Get-AirVideoStatus, Get-AirMaterialSchedule
