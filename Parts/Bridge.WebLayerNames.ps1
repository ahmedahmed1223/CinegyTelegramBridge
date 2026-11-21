#requires -Version 7

$script:WebLayerNameReviews = @{}

function Get-WebLayerNameRow {
    param([int]$Layer)
    $current = Get-LayerName -Layer $Layer
    $label = ConvertTo-LayerNameEdit -Name $current
    $name = if ($label.ok) { Protect-SensitiveText $label.name } else { '' }
    return @{ layer = $Layer; name = [string]$name; hasCustomName = [bool]$current }
}

function Get-WebLayerNames {
    param([System.Collections.IDictionary]$Arguments)
    if (-not (Get-WebTelegramAccessAdministrator -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }
    $page = 0
    $pageSize = 20
    $requestedPage = Get-JsonProp $Arguments 'page'
    $requestedSize = Get-JsonProp $Arguments 'pageSize'
    if (($null -ne $requestedPage -and -not [int]::TryParse([string]$requestedPage, [ref]$page)) -or $page -lt 0 -or
        ($null -ne $requestedSize -and -not [int]::TryParse([string]$requestedSize, [ref]$pageSize)) -or $pageSize -lt 1 -or $pageSize -gt 40) {
        return @{ ok = $false; error = 'bad_request' }
    }
    $layers = @(Get-KnownLayers | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    $window = Get-BridgePageWindow -ItemCount $layers.Count -Page $page -PageSize $pageSize
    $items = @(if ($layers.Count -gt 0) {
            foreach ($index in $window.StartIndex..$window.EndIndex) {
                Get-WebLayerNameRow -Layer $layers[$index]
            }
        })
    return @{ ok = $true; data = @{ items = $items; page = $window.Page; pageSize = $pageSize; total = $layers.Count } }
}

function Get-WebLayerNameCandidate {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebTelegramAccessAdministrator -Arguments $Arguments
    if (-not $actor) { return @{ error = 'forbidden' } }
    $layer = 0
    if (-not [int]::TryParse([string](Get-JsonProp $Arguments 'layer'), [ref]$layer) -or $layer -le 0) {
        return @{ error = 'bad_request' }
    }
    if ($layer -notin @(Get-KnownLayers)) { return @{ error = 'layer_name_not_found' } }
    return @{
        actor = $actor; current = Get-WebLayerNameRow -Layer $layer
        fingerprint = ConvertTo-Json -InputObject @($layer, @(Get-LayerNameSettingPairs -Layer $layer)) -Compress
    }
}

function New-WebLayerNameReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebLayerNameCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $requested = Get-JsonProp $Arguments 'name'
    if ($requested -isnot [string]) { return @{ ok = $false; error = 'bad_request' } }
    $edit = ConvertTo-LayerNameEdit -Name $requested
    if (-not $edit.ok) { return $edit }
    $name = Protect-SensitiveText $edit.name
    if (-not [string]::Equals($name, $edit.name, [StringComparison]::Ordinal)) {
        return @{ ok = $false; error = 'layer_name_invalid' }
    }
    if ([string]::Equals((Get-LayerName -Layer $candidate.current.layer), $edit.name, [StringComparison]::Ordinal) -and
        @(Get-LayerNameSettingPairs -Layer $candidate.current.layer).Count -le 1) {
        return @{ ok = $false; error = 'layer_name_unchanged' }
    }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebLayerNameReviews
    $review = $script:WebLayerNameReviews[$candidate.actor]
    $review.Name = $edit.name
    return @{ ok = $true; data = @{
        current = $candidate.current; name = $edit.name; review = $token; expiresAt = $review.ExpiresAt.ToString('o')
    } }
}

function Complete-WebLayerNameReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebLayerNameCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebLayerNameReviews
    if (-not $review -or -not [string]::Equals($review.Fingerprint, $candidate.fingerprint, [StringComparison]::Ordinal)) {
        return @{ ok = $false; error = 'layer_name_stale' }
    }
    $layer = $candidate.current.layer
    $saved = Save-LayerName -Layer $layer -Name $review.Name -UserId $candidate.actor -Deadline $Deadline
    if (-not $saved.ok) { return $saved }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = Get-WebLayerNameRow -Layer $layer }
}
