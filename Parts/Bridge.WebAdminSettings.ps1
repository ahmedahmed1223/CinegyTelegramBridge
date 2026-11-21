#requires -Version 7

$script:WebAdminSettingReviews = @{}
$script:WebAdminSettingsImportReviews = @{}

function Get-WebAdminPresentationSettingSchema {
    param([AllowEmptyString()][string]$Name)
    # Stage only presentation controls. A typed Boolean by itself does not
    # make a setting safe to expose: some Booleans grant air or admin powers.
    $allowed = @('OneHandMode', 'EnablePersistentMenuButton')
    if ($PSBoundParameters.ContainsKey('Name')) {
        if ($Name -cnotin $allowed) { return }
        $allowed = @($Name)
    }

    foreach ($id in $allowed) {
        if ($script:ProtectedSettings -contains $id) { continue }
        $matchesForId = @($script:SettingSchema | Where-Object Name -ceq $id)
        if ($matchesForId.Count -ne 1) { continue }
        $setting = $matchesForId[0]
        if ($setting.ValueType -ceq 'Boolean' -and $setting.Default -is [bool] -and
            -not ($setting.Protected -or $setting.Sensitive -or $setting.RequiresConfirmation -or $setting.RequiresRestart)) {
            $setting
        }
    }
}

function Get-WebAdminPresentationSettingView {
    foreach ($setting in @(Get-WebAdminPresentationSettingSchema)) {
        $current = Get-Setting -Name $setting.Name
        [ordered]@{
            id = [string]$setting.Name; category = 'presentation'; kind = 'boolean'
            label = [string]$setting.Label; description = [string]$setting.Description; unit = [string]$setting.Unit
            enabled = if ($current -is [bool]) { $current }
            value = $null; minimum = $null; maximum = $null; protected = $false
        }
    }
}

function Get-WebAdminSettingActor {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return 0L
    }
    return $actor
}

function Get-WebAdminEditableSettingId {
    # Protected controls and changes with side effects stay in their existing
    # screens. This list governs both editing and the portable Web snapshot.
    $ids = @('NotifyAdminsOnAccessRequest', 'AskRequesterName', 'MaxPendingApprovals', 'PendingStateTimeoutMinutes')
    $ids += @(Get-WebAdminPresentationSettingSchema | ForEach-Object { $_.Name })
    foreach ($id in $ids) {
        if ($script:ProtectedSettings -notcontains $id) { $id }
    }
}

function Get-WebAdminSettingsExport {
    param([System.Collections.IDictionary]$Arguments, [datetimeoffset]$Now = [datetimeoffset]::Now)
    if (-not (Get-WebAdminSettingActor -Arguments $Arguments)) { return @{ ok = $false; error = 'forbidden' } }

    $settings = [ordered]@{}
    foreach ($id in Get-WebAdminEditableSettingId) {
        $current = Get-Setting -Name $id
        # Never serialize an unsupported type, even if a station file
        # contains a hand-edited value of the wrong shape.
        if ($current -isnot [bool] -and $current -isnot [int] -and $current -isnot [long]) { continue }
        try { $normalized = ConvertTo-ImportedSettingValue -Name $id -Value $current }
        catch { continue }
        if ($normalized -is [bool] -or $normalized -is [int]) { $settings[$id] = $normalized }
    }
    if (-not $settings.Count) { return @{ ok = $false; error = 'setting_export_unavailable' } }
    return @{ ok = $true; data = (New-BridgeSettingsExportDocument -Settings $settings -Now $Now) }
}

function Get-WebAdminEditableSetting {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebAdminSettingActor -Arguments $Arguments
    if (-not $actor) { return @{ error = 'forbidden' } }
    $id = [string](Get-JsonProp $Arguments 'id')
    if ($id -cnotin @(Get-WebAdminEditableSettingId)) { return @{ error = 'setting_not_editable' } }
    $setting = Get-WebAdminSettingView | Where-Object { $_.id -ceq $id } | Select-Object -First 1
    if (-not $setting) { return @{ error = 'setting_not_editable' } }
    return @{
        actor = $actor; setting = $setting
        fingerprint = ConvertTo-Json -InputObject @($id, $setting.kind, $setting.enabled, $setting.value, $setting.minimum, $setting.maximum) -Compress
    }
}

function New-WebAdminSettingReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebAdminEditableSetting -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $setting = $candidate.setting
    $enabled = Get-JsonProp $Arguments 'enabled'
    $number = Get-JsonProp $Arguments 'value'
    $desired = $null
    if ($setting.kind -ceq 'boolean' -and $enabled -is [bool] -and $null -eq $number -and
        -not [object]::Equals($enabled, $setting.enabled)) {
        $desired = $enabled
    }
    elseif ($setting.kind -ceq 'integer' -and $null -eq $enabled -and ($number -is [int] -or $number -is [long]) -and
        $null -ne $setting.minimum -and $null -ne $setting.maximum -and
        $number -ge $setting.minimum -and $number -le $setting.maximum -and $number -ne $setting.value) {
        $desired = [int]$number
    }
    if ($null -eq $desired) { return @{ ok = $false; error = 'setting_invalid' } }

    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebAdminSettingReviews
    $script:WebAdminSettingReviews[$candidate.actor].Desired = $desired
    return @{ ok = $true; data = @{
            setting = $setting; enabled = if ($desired -is [bool]) { $desired }
            value = if ($desired -is [int]) { $desired }
            review = $token
        } }
}

function Complete-WebAdminSettingReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $candidate = Get-WebAdminEditableSetting -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $review = Use-WebAirReview -Actor $candidate.actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAdminSettingReviews
    if (-not $review -or $review.Fingerprint -cne $candidate.fingerprint) { return @{ ok = $false; error = 'setting_stale' } }

    $id = $candidate.setting.id
    $settings = Get-JsonProp $config 'Settings'
    # Initialization supplies the settings object. Preserve the exact stored
    # value (or absence) if the shared writer cannot persist this change.
    if ($null -eq $settings) { return @{ ok = $false; error = 'setting_save_failed' } }
    $hadValue = if ($settings -is [System.Collections.IDictionary]) { $settings.Contains($id) }
    else { $settings.PSObject.Properties.Match($id).Count -gt 0 }
    $previous = Get-JsonProp $settings $id
    Set-Setting -Name $id -Value $review.Desired
    if ($script:LastConfigSaveFailed) {
        if ($hadValue) { Set-JsonProp -Object $settings -Name $id -Value $previous }
        else { Remove-JsonProp -Object $settings -Name $id }
        return @{ ok = $false; error = 'setting_save_failed' }
    }

    $actor = $candidate.actor
    Write-BridgeLog "User $actor set $id from the web"
    Add-AuditEntry (T 'kb.settingAudit' $id $review.Desired (Format-UserAuditActor -UserId $actor)) | Out-Null
    $saved = Get-WebAdminSettingView | Where-Object { $_.id -ceq $id } | Select-Object -First 1
    return @{ ok = $true; data = @{ setting = $saved } }
}


function Get-WebAdminSettingsImportPlan {
    param([System.Collections.IDictionary]$Requested)

    if ($null -eq $Requested -or -not $Requested.Count) { return @{ error = 'settings_import_invalid' } }
    $before = [ordered]@{}
    $after = [ordered]@{}
    $changes = [System.Collections.Generic.List[object]]::new()
    $allowed = @(Get-WebAdminEditableSettingId)
    foreach ($id in @($Requested.Keys | Sort-Object -CaseSensitive)) {
        $desired = $Requested[$id]
        if ($id -cnotin $allowed -or ($desired -isnot [bool] -and $desired -isnot [int] -and $desired -isnot [long])) {
            return @{ error = 'settings_import_invalid' }
        }
        try {
            $current = ConvertTo-ImportedSettingValue -Name $id -Value (Get-Setting -Name $id)
            $target = ConvertTo-ImportedSettingValue -Name $id -Value $desired
        }
        catch { return @{ error = 'settings_import_invalid' } }
        if ($target -isnot [bool] -and $target -isnot [int]) { return @{ error = 'settings_import_invalid' } }
        $before[$id] = $current
        $after[$id] = $target
        if (-not [object]::Equals($current, $target)) {
            $changes.Add(@{ Name = $id; From = $current; To = $target })
        }
    }
    return @{
        before = $before; after = $after; changes = $changes.ToArray()
        fingerprint = ConvertTo-Json -InputObject @($before, $after) -Compress
    }
}

function New-WebAdminSettingsImportReview {
    param([System.Collections.IDictionary]$Arguments)
    $actor = Get-WebAdminSettingActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    $requested = Get-JsonProp $Arguments 'settings'
    if ($requested -isnot [System.Collections.IDictionary]) { return @{ ok = $false; error = 'settings_import_invalid' } }
    $plan = Get-WebAdminSettingsImportPlan -Requested $requested
    if ($plan.ContainsKey('error')) { return @{ ok = $false; error = $plan.error } }
    $changes = @(foreach ($change in $plan.changes) {
        @{
            id = $change.Name; kind = if ($change.To -is [bool]) { 'boolean' } else { 'integer' }
            beforeEnabled = if ($change.From -is [bool]) { $change.From }
            afterEnabled = if ($change.To -is [bool]) { $change.To }
            beforeValue = if ($change.From -is [int]) { $change.From }
            afterValue = if ($change.To -is [int]) { $change.To }
        }
    })
    $token = $null
    # An unchanged file also invalidates an older review in this browser actor slot.
    $script:WebAdminSettingsImportReviews.Remove($actor)
    if ($changes.Count) {
        $token = New-WebAirReview -Actor $actor -Fingerprint $plan.fingerprint -Reviews $script:WebAdminSettingsImportReviews
        $script:WebAdminSettingsImportReviews[$actor].Desired = $plan.after
    }
    return @{ ok = $true; data = @{ changes = $changes; review = $token } }
}

function Complete-WebAdminSettingsImportReview {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)
    $actor = Get-WebAdminSettingActor -Arguments $Arguments
    if (-not $actor) { return @{ ok = $false; error = 'forbidden' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $approved = Use-WebAirReview -Actor $actor -Token ([string](Get-JsonProp $Arguments 'review')) -Reviews $script:WebAdminSettingsImportReviews
    $stale = @{ ok = $false; error = 'setting_stale' }
    if (-not $approved) { return $stale }
    $plan = Get-WebAdminSettingsImportPlan -Requested $approved.Desired
    if ($plan.ContainsKey('error') -or $approved.Fingerprint -cne $plan.fingerprint -or -not $plan.changes.Count) { return $stale }
    $remaining = ($approved.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
    if ($remaining -le 0) { return $stale }
    $writeDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
    if ($Deadline -gt 0) { $writeDeadline = [math]::Min($Deadline, $writeDeadline) }
    if (-not (Set-ImportedSettings -Changes $plan.changes -Deadline $writeDeadline -ReviewedExpected $plan.before)) {
        if ($script:LastConfigSaveConflict) { return $stale }
        return @{ ok = $false; error = 'setting_save_failed' }
    }
    Add-AuditEntry (T 'cfg.importAudit' $plan.changes.Count $(Format-UserAuditActor -UserId $actor)) | Out-Null
    return @{ ok = $true; data = @{ applied = $plan.changes.Count } }
}
