#requires -Version 7

$script:WebTemplateMaxAirReviews = @{}

function Get-WebTemplateMaxAirCandidate {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ error = 'forbidden' }
    }
    $key = [string](Get-JsonProp $Arguments 'key')
    if ([string]::IsNullOrWhiteSpace($key)) { return @{ error = 'template_air_limit_invalid' } }
    $template = Get-JsonProp (Get-TemplateStore).Map $key
    if (-not $template -or -not [string]::Equals([string](Get-JsonProp $template 'Key'), $key, [StringComparison]::Ordinal)) {
        return @{ error = 'scene_not_found' }
    }
    $registryRevision = Get-TemplatePresetRegistryRevision -TemplateKey $key
    if (-not $registryRevision) { return @{ error = 'scene_not_found' } }
    $raw = Get-JsonProp (Get-Setting 'TemplateMaxAirSeconds') $key
    $configured = 0
    [void][int]::TryParse([string]$raw, [ref]$configured)
    $revision = Get-TemplatePresetRevision -TemplateKey $key -Entry @($registryRevision, $raw)
    return @{ actor = $actor; current = @{ key = $key; seconds = [math]::Max(0, $configured); revision = $revision } }
}

function Get-WebTemplateMaxAir {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebTemplateMaxAirCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    return @{ ok = $true; data = $candidate.current }
}

function New-WebTemplateMaxAirReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebTemplateMaxAirCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ([string](Get-JsonProp $Arguments 'revision') -cne $candidate.current.revision) {
        return @{ ok = $false; error = 'template_air_limit_stale' }
    }
    $action = [string](Get-JsonProp $Arguments 'mode')
    $seconds = Get-JsonProp $Arguments 'seconds'
    if ($action -ceq 'remove' -and $null -eq $seconds) { $seconds = 0 }
    elseif ($action -cne 'set' -or ($seconds -isnot [int] -and $seconds -isnot [long]) -or $seconds -lt 1 -or $seconds -gt 3600) {
        return @{ ok = $false; error = 'template_air_limit_invalid' }
    }
    if ($seconds -eq $candidate.current.seconds) { return @{ ok = $false; error = 'template_air_limit_unchanged' } }
    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.current.revision -Reviews $script:WebTemplateMaxAirReviews
    $review = $script:WebTemplateMaxAirReviews[$candidate.actor]
    $review.Seconds = [int]$seconds
    return @{ ok = $true; data = @{
        current = $candidate.current; seconds = [int]$seconds; review = $token; expiresAt = $review.ExpiresAt.ToString('o')
    } }
}

function Complete-WebTemplateMaxAirReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebTemplateMaxAirCandidate -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebTemplateMaxAirReviews
    if (-not $review -or $review.Fingerprint -cne $candidate.current.revision) {
        return @{ ok = $false; error = 'template_air_limit_stale' }
    }
    $key = $candidate.current.key
    $result = Set-TemplateMaxAirPolicy -Key $key -Seconds $review.Seconds -UserId $candidate.actor -Deadline $Deadline
    if (-not $result.ok) { return $result }
    return @{ ok = $true; data = @{ key = $key; seconds = [int]$review.Seconds } }
}
