#requires -Version 7
# Dot-sourced into the bridge scope alongside the existing board postbox guard.
$script:WebAirTextReviews = @{}

function Get-WebAirTextField {
    param([hashtable]$Template, [hashtable]$Snapshot)

    $consumers = @(Get-MojazDesignFields -TemplateKey $Template.Key | Where-Object {
            $_.Kind -eq 'text' -and $_.Consumed
        } | ForEach-Object { [string]$_.Name })
    $overrides = Get-TemplateFieldTypeOverrides -Template $Template
    $defaultType = [string](Get-Setting 'AirVariableType')
    $previous = Get-JsonProp $Snapshot 'Variables'
    $fields = @(Get-WebTemplateFields -Template $Template)
    foreach ($field in $fields) {
        $name = [string]$field.name
        $type = $overrides[$name] ?? $defaultType
        if ($field.sensitive -or $name -cnotin $consumers -or $type -notin 'Text', 'String') { continue }
        # Duplicate names cannot be addressed independently by the postbox.
        if (@($fields | Where-Object { $_.name -eq $name }).Count -ne 1) { continue }
        $stored = [string](Get-JsonProp $previous $name)
        @{
            name = $name; label = $field.label; required = $field.required; maxLength = $field.maxLength
            lastKnownValue = if ($stored.Length -le 160) { $stored } else { $stored.Substring(0, 160) + '...' }
            type = if ($type -eq 'String') { 'String' } else { 'Text' }
        }
    }
}

function Invoke-WebAirText {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = [long](Get-JsonProp $Arguments 'actor')
    if ($actor -le 0 -or -not (Test-Authorized -ChatId $actor -UserId $actor) -or
        -not (Test-MaintenanceControl -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    $invalid = @{ ok = $false; error = 'live_text_invalid' }
    $stale = @{ ok = $false; error = 'live_text_stale' }
    $busy = @{ ok = $false; error = 'bridge_busy' }
    $layer = 0
    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -cnotin 'inspect', 'preview', 'apply' -or
        -not [int]::TryParse([string](Get-JsonProp $Arguments 'layer'), [ref]$layer) -or $layer -le 0) { return $invalid }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }

    $pending = if ($action -ceq 'apply') {
        Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAirTextReviews
    }
    if ($action -ceq 'apply' -and -not $pending) { return $stale }
    $snapshot = $script:LastSuccessfulLayerShows[$layer]
    $key = [string](Get-JsonProp $snapshot 'Key')
    $current = $script:OnAir[$layer]
    $template = if ($key) { (Get-TemplateStore).Map[$key] }
    if (-not $template -or [int]$template.Layer -ne $layer -or $key -cne [string](Get-JsonProp $current 'Key')) { return $stale }
    if (-not (Test-TemplateAccess -Key $key -Layer $layer -ChatId $actor -UserId $actor).Allowed) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $device = (Resolve-AirGfxDevice -Layer $layer).StatusPath
    $managedLayers = @($script:BoardsLive.Keys; [int]$(if ($script:MojazPlayback) { Get-MojazRunLayer -Playback $script:MojazPlayback } else { 0 });
        [int](Get-JsonProp $script:UrgentBoardRun 'Layer'); (Get-SettingInt 'TemplateTestLayer' 0))
    $usesManagedDevice = @($managedLayers | Where-Object {
            $_ -gt 0 -and (Resolve-AirGfxDevice -Layer ([int]$_)).StatusPath -eq $device
        }).Count -gt 0
    if ([string](Get-Setting 'SceneMode') -eq 'Multi' -or $usesManagedDevice -or
        (Get-JsonProp $current 'Source') -in 'cinegy', 'BotTest' -or $key -eq $script:MojazTemplateKey -or
        (Get-JsonProp $template 'Bulletin') -or (Test-PermanentGraphicAutoHideProtected -Key $key -Layer $layer) -or
        (Test-PermanentGraphicAutoHideProtected -Layer $layer)) { return @{ ok = $false; error = 'live_text_managed' } }
    if ($script:LayerLocks.ContainsKey($layer)) { return @{ ok = $false; error = 'live_text_busy' } }

    $eventId = ([string](Get-JsonProp $snapshot 'ActiveId')).Trim().Trim('{', '}').ToLowerInvariant()
    $shownAt = [long](Get-JsonProp $snapshot 'EngineStartedAtTicks')
    $revision = [string](Get-JsonProp $snapshot 'TemplateRevision')
    if (-not (Get-JsonProp $snapshot 'EventIdentityConfirmed') -or -not $eventId -or $shownAt -le 0 -or
        $device -cne [string](Get-JsonProp $snapshot 'DevicePath') -or -not $revision -or
        $revision -cne [string](Get-JsonProp $template 'PresetRevision') -or
        $revision -cne (Get-TemplatePresetRegistryRevision -TemplateKey $key) -or
        -not (Test-WebRollbackLocalScene -Template $template -Restore $snapshot)) { return @{ ok = $false; error = 'live_text_unverified' } }

    $fields = @(Get-WebAirTextField -Template $template -Snapshot $snapshot)
    if (-not $fields.Count -or $fields.Count -gt 40) { return @{ ok = $false; error = 'live_text_no_fields' } }
    $names = @($fields | ForEach-Object { $_.name })
    $patch = @{}
    $types = @{}
    if ($action -cne 'inspect') {
        $values = Get-JsonProp $Arguments 'values'
        if ($values -isnot [System.Collections.IDictionary] -or -not $values.Count) { return $invalid }
        foreach ($name in $values.Keys) {
            if ($name -cnotin $names -or $values[$name] -isnot [string]) { return $invalid }
        }
        foreach ($field in $fields) {
            $name = $field.name
            if (-not $values.Contains($name)) { continue }
            $value = $values[$name]
            if ($field.required -and [string]::IsNullOrWhiteSpace($value)) { return @{ ok = $false; error = 'live_text_required' } }
            if ($field.maxLength -and (Get-TextElementCount -Text $value) -gt $field.maxLength) { return @{ ok = $false; error = 'live_text_too_long' } }
            try { [void][Xml.XmlConvert]::VerifyXmlChars($value) } catch { return $invalid }
            $patch[$name] = $value
            $types[$name] = $field.type
        }

        $isolated = Test-ProgrammeBoardPostboxScope -Layer $layer -Names @($patch.Keys) -Deadline $Deadline -LocalScenesOnly
        if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
        if (-not $isolated) { return @{ ok = $false; error = 'live_text_conflict' } }
        if ($device -cne (Resolve-AirGfxDevice -Layer $layer).StatusPath -or
            $revision -cne (Get-TemplatePresetRegistryRevision -TemplateKey $key) -or
            -not (Test-WebRollbackLocalScene -Template $template -Restore $snapshot)) { return $stale }
    }

    # Read the target after the peer sweep so a replacement during those checks
    # is never mistaken for the scene from the beginning of the review.
    $status = Get-WebLayerStatus -Layer $layer
    $stamp = Get-CinegyLayerReviewStamp -Status $status
    if (-not $stamp) { return @{ ok = $false; error = 'live_text_unverified' } }
    if ($stamp -cne "active:$eventId" -or (Get-CinegyStatusStartTicks -Status $status) -ne $shownAt) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }

    $plan = @{ layer = $layer; templateKey = $key; fields = $fields }
    if ($action -ceq 'inspect') { return @{ ok = $true; data = @{ plan = $plan } } }
    $changes = @(foreach ($field in $fields) {
            if ($patch.ContainsKey($field.name)) { @{ name = $field.name; label = $field.label; value = $patch[$field.name]; type = $types[$field.name] } }
        })
    $generation = [long](Get-JsonProp $snapshot 'TextRevision')
    $fingerprint = ConvertTo-Json -InputObject @($layer, $device, $key, $revision, $eventId, $shownAt, $generation, $changes) -Compress -Depth 6
    if ($action -ceq 'preview') {
        $plan.changes = $changes
        $plan.review = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebAirTextReviews
        return @{ ok = $true; data = @{ plan = $plan } }
    }
    if ($pending.Fingerprint -cne $fingerprint) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return $busy }
    if (-not (Invoke-SetValues -Values $patch -Types $types -ChatId $actor -UserId $actor -Quiet)) {
        return @{ ok = $false; error = 'live_text_refused' }
    }

    # Preserve the effective scene for subsequent corrections. Copy before
    # updating because a rollback candidate may hold a reference to its snapshot.
    $newSnapshot = $snapshot.Clone()
    $newSnapshot.Variables = Copy-ShowVariables -Variables (Get-JsonProp $snapshot 'Variables')
    foreach ($name in $patch.Keys) { $newSnapshot.Variables[$name] = $patch[$name] }
    $newSnapshot.TextRevision = $generation + 1
    $script:LastSuccessfulLayerShows[$layer] = $newSnapshot
    $shared = $script:LastWebTemplateText[$key]
    if ($shared -and (Get-JsonProp $shared 'Path') -ceq $template.Path -and (Get-JsonProp $shared 'Layer') -eq $layer) {
        $sharedValues = Copy-ShowVariables -Variables (Get-JsonProp $shared 'Values')
        foreach ($name in $patch.Keys) { $sharedValues[$name] = $patch[$name] }
        Set-JsonProp $shared 'Values' $sharedValues
        Set-JsonProp $current 'ScreenCopy' (Format-OnAirScreenCopy -Key $key -Variables $sharedValues)
    }
    Publish-WebChannelState -Force
    return @{ ok = $true; data = @{ accepted = $true } }
}
