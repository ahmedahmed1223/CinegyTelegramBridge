#requires -Version 7

$script:WebHideAllLayerScopeReviews = @{}

function Get-WebHideAllLayerScopeActor {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if ([long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -and $actor -gt 0 -and
        (Test-Authorized -ChatId $actor -UserId $actor)) { return $actor }
}

function Get-WebHideAllLayerScopeView {
    param([long]$Actor)
    $raw = [string](Get-Setting 'HideAllLayers')
    $enabled = [bool](Get-Setting 'EnableHideAll')
    $known = @(Get-KnownLayers | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    $selected = @(Get-HideAllTargetLayers | Where-Object { $_ -gt 0 })
    $mode = if ($raw.Trim().Equals('all', [StringComparison]::OrdinalIgnoreCase)) { 'all' }
    elseif ($selected.Count) { 'selected' }
    else { 'none' }
    $layers = @(foreach ($layer in $known) {
            $name = ConvertTo-LayerNameEdit -Name (Get-LayerName -Layer $layer)
            [ordered]@{ id = [int]$layer; name = if ($name.ok) { [string](Protect-SensitiveText $name.name) } else { '' } }
        })
    $revision = Get-TemplatePresetRevision -TemplateKey 'hide-all-layer-scope' -Entry @($raw, $enabled, $layers)
    return @{
        raw = $raw
        data = @{
            mode = $mode; selectedLayers = $selected; knownLayers = $layers; revision = $revision
            enabled = $enabled; canManage = [bool](Test-Admin -ChatId $Actor -UserId $Actor)
        }
    }
}

function Get-WebHideAllLayerScope {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebHideAllLayerScopeActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    return @{ ok = $true; data = (Get-WebHideAllLayerScopeView -Actor $actor).data }
}

function New-WebHideAllLayerScopeReview {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebHideAllLayerScopeActor -Arguments $Arguments
    if (-not $actor -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $view = Get-WebHideAllLayerScopeView -Actor $actor
    if ([string](Get-JsonProp $Arguments 'revision') -cne $view.data.revision) {
        return @{ ok = $false; error = 'hide_all_scope_stale' }
    }
    $mode = [string](Get-JsonProp $Arguments 'mode')
    $layers = @()
    if ($Arguments.Contains('layers') -and $null -ne $Arguments['layers']) {
        if ($Arguments['layers'] -isnot [System.Collections.IList]) { return @{ ok = $false; error = 'hide_all_scope_invalid' } }
        $layers = $Arguments['layers']
    }
    $edit = ConvertTo-HideAllLayerScopeEdit -Mode $mode -Layers $layers
    if (-not $edit.ok) { return $edit }
    if ([string]::Equals($view.raw, $edit.value, [StringComparison]::Ordinal)) {
        return @{ ok = $false; error = 'hide_all_scope_unchanged' }
    }
    $token = New-WebAirReview -Actor $actor -Fingerprint $view.data.revision -Reviews $script:WebHideAllLayerScopeReviews
    $pending = $script:WebHideAllLayerScopeReviews[$actor]
    $pending.Mode = $mode
    $pending.Layers = $edit.layers
    $selected = if ($mode -ceq 'all') { $view.data.knownLayers | ForEach-Object { $_.id } }
    else { $edit.layers }
    return @{ ok = $true; data = @{
        current = $view.data; mode = $mode; selectedLayers = @($selected); review = $token
        expiresAt = $pending.ExpiresAt.ToString('o')
    } }
}

function Complete-WebHideAllLayerScopeReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $actor = Get-WebHideAllLayerScopeActor -Arguments $Arguments
    if (-not $actor -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $view = Get-WebHideAllLayerScopeView -Actor $actor
    $pending = Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebHideAllLayerScopeReviews
    if (-not $pending -or $pending.Fingerprint -cne $view.data.revision) {
        return @{ ok = $false; error = 'hide_all_scope_stale' }
    }
    $saved = Save-HideAllLayerScope -Mode $pending.Mode -Layers $pending.Layers -UserId $actor -Deadline $Deadline
    if (-not $saved.ok) { return $saved }
    return @{ ok = $true; data = (Get-WebHideAllLayerScopeView -Actor $actor).data }
}
