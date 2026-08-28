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

function Escape-XmlValue {
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
        $safeName = Escape-XmlValue -Value $key
        $safeValue = Escape-XmlValue -Value ([string]$Variables[$key])
        $type = if ($Types.ContainsKey($key)) { [string]$Types[$key] } else { $DefaultType }
        $safeType = Escape-XmlValue -Value $type
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
        Determines whether a Cinegy response is sufficient for safely enabling
        independent scene actions. The currently documented status endpoint
        exposes one layer-level Active item only, so callers without an
        explicit multi-item probe receive a fail-closed result.
    #>
    param(
        [object[]]$SceneItems = @(),
        [bool]$DirectTargetSupported = $false
    )
    $items = @($SceneItems)
    $identities = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $stable = $items.Count -ge 2
    foreach ($item in $items) {
        $property = $item.PSObject.Properties['SceneId']
        $id = if ($null -eq $property) { '' } else { [string]$property.Value }
        if ([string]::IsNullOrWhiteSpace($id) -or -not $identities.Add($id.Trim())) {
            $stable = $false
            break
        }
    }
    $verified = $stable -and $DirectTargetSupported
    $error = if ($verified) { '' }
    elseif (-not $stable) { 'Cinegy لم يثبت قائمة مشاهد مستقلة بهويات ثابتة.' }
    else { 'Cinegy لم يثبت إمكانية استهداف مشهد محدد مباشرة.' }
    return [pscustomobject]@{
        CanListScenes = $stable
        CanTargetScene = $DirectTargetSupported
        Verified = $verified
        Error = $error
    }
}

# Escape-XmlValue is an implementation detail. Tests exercise it inside the
# module scope so importing the module exposes only its supported commands.
Export-ModuleMember -Function Set-AirLayerDeviceMap, Resolve-AirGfxDevice, Send-AirCommand, Show-TitlerTemplate, Hide-TitlerTemplate, Exit-TitlerScene, Send-PostboxValues, Get-TitlerLayerStatus, Get-AirTelemetryStatus, Get-CinegySceneCapabilities
