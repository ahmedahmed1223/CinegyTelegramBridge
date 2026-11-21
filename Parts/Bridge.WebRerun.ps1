#requires -Version 7
# Dot-source in the bridge scope so the Bot and Web share the same histories.
$script:WebAirRerunReviews = @{}

function Invoke-WebAirRerun {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $kind = [string](Get-JsonProp $Arguments 'kind')
    $action = [string](Get-JsonProp $Arguments 'action')
    $invalid = @{ ok = $false; error = 'rerun_invalid' }
    $stale = @{ ok = $false; error = 'rerun_stale' }
    if ($kind -cnotin 'repeat', 'retry' -or $action -cnotin 'inspect', 'preview', 'start') { return $invalid }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }

    $pending = if ($action -ceq 'start') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAirRerunReviews
    }
    $source = if ($kind -ceq 'repeat') { $script:LastShow[$actor] } else { $script:LastShowAttempts[[string]$actor] }
    if ($action -ceq 'start' -and (-not $pending -or -not [object]::ReferenceEquals($pending.Source, $source))) { return $stale }
    if (-not $source) { return @{ ok = $false; error = 'rerun_missing' } }
    $key = [string](Get-JsonProp $source 'Key')
    if (-not $key) { return $stale }
    $template = (Get-TemplateStore).Map[$key]
    if (-not $template) { return $stale }
    $key = [string]$template.Key
    $layer = [int]$template.Layer
    $path = [string]$template.Path
    $revision = [string](Get-JsonProp $template 'PresetRevision')
    if ($layer -le 0 -or -not $path -or -not $revision -or
        $revision -cne (Get-TemplatePresetRegistryRevision -TemplateKey $key)) { return $stale }

    if (-not (Test-TemplateAccess -Key $key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $policy = Test-TemplateShowPolicy -Key $key -Layer $layer -IsAdmin:(Test-Admin -ChatId $actor -UserId $actor)
    if (-not $policy.Allowed) { return @{ ok = $false; error = 'rerun_refused' } }

    $fields = @(Get-WebTemplateFields -Template $template)
    $storedValues = Get-JsonProp $source 'Variables'
    $submitted = if ($action -cne 'inspect') { Get-JsonProp $Arguments 'variables' }
    if ($null -ne $submitted) {
        if ($submitted -isnot [System.Collections.IDictionary]) { return $invalid }
        $allowedNames = @($fields | ForEach-Object { $_.name })
        foreach ($name in $submitted.Keys) {
            if ($name -cnotin $allowedNames -or $submitted[$name] -isnot [string]) { return $invalid }
        }
    }
    $variables = @{}
    $view = @(foreach ($field in $fields) {
            $name = [string]$field.name
            if ($submitted -and $submitted.Contains($name)) { $variables[$name] = $submitted[$name] }
            elseif (-not $field.sensitive -and $storedValues -and $storedValues.Contains($name)) {
                $variables[$name] = [string]$storedValues[$name]
            }
            @{
                name = $name; label = $field.label; required = $field.required; sensitive = $field.sensitive
                maxLength = $field.maxLength
                value = if (-not $field.sensitive -and $variables.ContainsKey($name)) { $variables[$name] }
                hasValue = $variables.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$variables[$name])
            }
        })
    $requestedSeconds = if ($kind -ceq 'retry') { [int](Get-JsonProp $source 'AutoHideSeconds') } else { 0 }
    $plan = @{
        key = $key; layer = $layer; autoHideSeconds = Get-EffectiveAutoHideSeconds -Key $key -RequestedSeconds $requestedSeconds
        fields = $view
    }
    if ($action -ceq 'inspect') { return @{ ok = $true; data = @{ rerun = $plan } } }
    if ([string](Get-Setting 'SceneMode') -eq 'Multi') { return @{ ok = $false; error = 'rerun_ambiguous' } }
    if ($script:LayerLocks.ContainsKey($layer)) { return @{ ok = $false; error = 'rerun_busy' } }
    foreach ($field in $view) {
        if ($field.required -and -not $field.hasValue) { return @{ ok = $false; error = 'rerun_required' } }
        if (-not $variables.ContainsKey($field.name)) { continue }
        $value = $variables[$field.name]
        try { [void][Xml.XmlConvert]::VerifyXmlChars($value) } catch { return $invalid }
        if ($field.maxLength -and (Get-TextElementCount -Text $value) -gt $field.maxLength) {
            return @{ ok = $false; error = 'rerun_too_long' }
        }
    }

    $device = (Resolve-AirGfxDevice -Layer $layer).StatusPath
    $status = Get-WebLayerStatus -Layer $layer
    $stamp = Get-CinegyLayerReviewStamp -Status $status
    if (-not $stamp) { return @{ ok = $false; error = 'rerun_unverified' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $startedAt = Get-CinegyStatusStartTicks -Status $status
    if ($stamp -cne 'empty' -and $startedAt -le 0) { return @{ ok = $false; error = 'rerun_unverified' } }
    $plan.replacesGraphic = $stamp -ne 'empty'
    $plan.graphicName = Get-NewsScreenLine ([string](Get-JsonProp $status 'ActiveName')) 100
    # Keep submitted secrets only in the request. Variable order follows the
    # registry, so equivalent JSON property ordering cannot change the review.
    $reviewedVariables = [ordered]@{}
    foreach ($field in $fields) {
        if ($variables.ContainsKey($field.name)) { $reviewedVariables[$field.name] = $variables[$field.name] }
    }
    $body = ConvertTo-Json -Compress -Depth 8 -InputObject @($kind, $key, $revision, $layer, $device, $path,
        $plan.autoHideSeconds, $stamp, $startedAt, $reviewedVariables)
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData($script:TemplatePresetRevisionKey, $bytes))
    if ($action -ceq 'preview') {
        $plan.review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebAirRerunReviews
        $script:WebAirRerunReviews[$actor].Source = $source
        return @{ ok = $true; data = @{ rerun = $plan } }
    }
    if ($pending.Fingerprint -cne $fingerprint) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }

    $show = @{
        Key = $key; Variables = $variables; ChatId = $actor; UserId = $actor; AutoHideSeconds = $requestedSeconds
        ExpectedLayer = $layer; ExpectedTemplatePath = $path; ExpectedLayerStamp = $stamp; ExpectedLayerStartedAtTicks = $startedAt
    }
    $show.Deadline = $Deadline
    $result = Invoke-ShowTemplateResult @show
    if (-not (Get-JsonProp $result 'Success')) {
        return @{ ok = $false; error = 'rerun_refused' }
    }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ sceneConfirmed = [bool](Get-JsonProp $result 'ActiveIdConfirmed') } }
}
