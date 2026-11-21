#requires -Version 7

$script:WebAdminSettingReviews = @{}
$script:WebAdminSettingsImportReviews = @{}

function Get-WebAdminEditableSettingSchema {
    param([AllowEmptyString()][string]$Name)

    # This allowlist controls the editor and the portable partial snapshot.
    # Numeric and Boolean type alone is insufficient for an editorial setting.
    $categories = [ordered]@{
        NotifyAdminsOnAccessRequest = 'access'
        AskRequesterName = 'access'
        MaxPendingApprovals = 'access'
        PendingStateTimeoutMinutes = 'air'
        OneHandMode = 'presentation'
        EnablePersistentMenuButton = 'presentation'
        NewsMaxItems = 'newsroom'
        NewsDraftTimeoutMinutes = 'newsroom'
        UrgentBoardIntervalSeconds = 'urgent'
        UrgentBoardRepeats = 'urgent'
        UrgentBoardTotalSeconds = 'urgent'
        UrgentBoardMaxItems = 'urgent'
        UrgentBoardMaxTextLength = 'urgent'
        UrgentBoardNotifyOnFinish = 'urgent'
        MojazRowFrames = 'bulletin'
        MojazIntroExtraFrames = 'bulletin'
        MojazLastRowFrames = 'bulletin'
        MojazNotifyOnFinish = 'bulletin'
        TemplateReminderFollowUpMinutes = 'reminders'
        SchedulePreNotifyMinutes = 'reminders'
        MojazScheduleNoticeSeconds = 'reminders'
    }
    $ids = $categories.Keys
    if ($PSBoundParameters.ContainsKey('Name')) {
        if ($Name -cnotin $ids) { return }
        $ids = @($Name)
    }
    $nativeSettings = @{}
    foreach ($metadata in $script:SettingSchema) { $nativeSettings[$metadata.Name] = $metadata }
    foreach ($id in $ids) {
        $metadata = $nativeSettings[$id]
        if (-not $metadata -or $metadata.Name -cne $id -or $script:ProtectedSettings -contains $id -or
            ($metadata.Default -isnot [bool] -and $metadata.Default -isnot [int]) -or
            ($metadata.Protected -or $metadata.Sensitive -or $metadata.RequiresConfirmation -or $metadata.RequiresRestart)) { continue }
        @{ Metadata = $metadata; Category = $categories[$id] }
    }
}

function Get-WebAdminEditableSettingView {
    param([AllowEmptyString()][string]$Name)
    foreach ($entry in @(Get-WebAdminEditableSettingSchema @PSBoundParameters)) {
        $metadata = $entry.Metadata
        $current = $null
        try { $current = ConvertTo-ImportedSettingValue -Name $metadata.Name -Value (Get-Setting -Name $metadata.Name) }
        catch { $current = $null }
        $isBoolean = $metadata.Default -is [bool]
        $bounds = if (-not $isBoolean) { Get-SettingBounds -Name $metadata.Name }
        [ordered]@{
            id = $metadata.Name; category = $entry.Category
            kind = if ($isBoolean) { 'boolean' } else { 'integer' }
            label = $metadata.Label; description = $metadata.Description; unit = $metadata.Unit
            enabled = if ($current -is [bool]) { $current }
            value = if ($current -is [int]) { $current }
            minimum = if ($bounds) { $bounds.Minimum }
            maximum = if ($bounds) { $bounds.Maximum }
            protected = $false; editable = $null -ne $current
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
    Get-WebAdminEditableSettingSchema | ForEach-Object { $_.Metadata.Name }
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
    $setting = Get-WebAdminEditableSettingView -Name $id
    if (-not $setting -or -not $setting.editable) { return @{ error = 'setting_not_editable' } }
    return @{
        actor = $actor; setting = $setting
        fingerprint = ConvertTo-Json -InputObject @($id, $setting.kind, $setting.enabled, $setting.value, $setting.minimum, $setting.maximum) -Compress
    }
}

function Test-WebAdminSettingTimingBusy {
    param([string]$Name)
    return $Name -cin @('UrgentBoardIntervalSeconds', 'UrgentBoardRepeats', 'UrgentBoardTotalSeconds') -and (Test-UrgentBoardTimingBusy)
}

function New-WebAdminSettingReview {
    param([System.Collections.IDictionary]$Arguments)
    $candidate = Get-WebAdminEditableSetting -Arguments $Arguments
    if ($candidate.ContainsKey('error')) { return @{ ok = $false; error = $candidate.error } }
    $setting = $candidate.setting
    if (Test-WebAdminSettingTimingBusy -Name $setting.id) { return @{ ok = $false; error = 'urgent_timing_active' } }
    $enabled = Get-JsonProp $Arguments 'enabled'
    $number = Get-JsonProp $Arguments 'value'
    if ($setting.kind -ceq 'boolean') {
        if ($null -ne $number -or $enabled -isnot [bool]) { return @{ ok = $false; error = 'setting_invalid' } }
        $current = $setting.enabled
        $requested = $enabled
    }
    else {
        if ($null -ne $enabled -or ($number -isnot [int] -and $number -isnot [long])) { return @{ ok = $false; error = 'setting_invalid' } }
        $current = $setting.value
        $requested = $number
    }
    try { $desired = ConvertTo-ImportedSettingValue -Name $setting.id -Value $requested }
    catch { return @{ ok = $false; error = 'setting_invalid' } }
    if ([object]::Equals($current, $desired)) { return @{ ok = $false; error = 'setting_invalid' } }

    $token = New-WebAirReview -Actor $candidate.actor -Fingerprint $candidate.fingerprint -Reviews $script:WebAdminSettingReviews
    $script:WebAdminSettingReviews[$candidate.actor].Desired = $desired
    return @{ ok = $true; data = @{
            setting = $setting; enabled = if ($desired -is [bool]) { $desired }
            value = if ($desired -is [int]) { $desired }
            review = $token
        } }
}

function Get-WebAdminSettingWriteDeadline {
    param([System.Collections.IDictionary]$Review, [long]$Deadline)

    $remaining = ($Review.ExpiresAt - [datetimeoffset]::UtcNow).TotalSeconds
    if ($remaining -le 0) { return 0L }
    $reviewDeadline = [Diagnostics.Stopwatch]::GetTimestamp() + [long]($remaining * [Diagnostics.Stopwatch]::Frequency)
    if ($Deadline -gt 0) { return [math]::Min($Deadline, $reviewDeadline) }
    return $reviewDeadline
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
    if (Test-WebAdminSettingTimingBusy -Name $id) { return @{ ok = $false; error = 'urgent_timing_active' } }
    $before = if ($candidate.setting.kind -ceq 'boolean') { $candidate.setting.enabled } else { $candidate.setting.value }
    $writeDeadline = Get-WebAdminSettingWriteDeadline -Review $review -Deadline $Deadline
    if ($writeDeadline -le 0) { return @{ ok = $false; error = 'setting_stale' } }
    $change = @{ Name = $id; From = $before; To = $review.Desired }
    $expected = @{}
    $expected[$id] = $before
    if (-not (Set-ImportedSettings -Changes @($change) -Deadline $writeDeadline -ReviewedExpected $expected)) {
        if ($script:LastConfigSaveConflict) { return @{ ok = $false; error = 'setting_stale' } }
        return @{ ok = $false; error = 'setting_save_failed' }
    }

    $actor = $candidate.actor
    Write-BridgeLog "User $actor set $id from the web"
    Add-AuditEntry (T 'kb.settingAudit' $id $review.Desired (Format-UserAuditActor -UserId $actor)) | Out-Null
    $saved = Get-WebAdminEditableSettingView -Name $id
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
            if (Test-WebAdminSettingTimingBusy -Name $id) { return @{ error = 'urgent_timing_active' } }
            $changes.Add(@{ Name = $id; From = $current; To = $target })
        }
    }
    return @{
        before = $before; after = $after; changes = $changes.ToArray()
        fingerprint = ConvertTo-Json -InputObject @($before, $after) -Compress
    }
}

function Get-WebAdminSettingsImportChanges {
    param([System.Collections.IDictionary]$Plan)

    foreach ($change in $Plan.changes) {
        @{
            id = $change.Name; kind = if ($change.To -is [bool]) { 'boolean' } else { 'integer' }
            beforeEnabled = if ($change.From -is [bool]) { $change.From }
            afterEnabled = if ($change.To -is [bool]) { $change.To }
            beforeValue = if ($change.From -is [int]) { $change.From }
            afterValue = if ($change.To -is [int]) { $change.To }
        }
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
    $changes = @(Get-WebAdminSettingsImportChanges -Plan $plan)
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
    return Save-WebAdminSettingsImportPlan -Actor $actor -Approved $approved -Deadline $Deadline
}

function Save-WebAdminSettingsImportPlan {
    param([long]$Actor, [System.Collections.IDictionary]$Approved, [long]$Deadline, [System.Collections.IDictionary]$Version)

    $stale = @{ ok = $false; error = 'setting_stale' }
    if (-not $Approved) { return $stale }
    $plan = Get-WebAdminSettingsImportPlan -Requested $approved.Desired
    if ($plan.ContainsKey('error') -and $plan.error -ceq 'urgent_timing_active') { return @{ ok = $false; error = $plan.error } }
    if ($plan.ContainsKey('error') -or $approved.Fingerprint -cne $plan.fingerprint -or -not $plan.changes.Count) { return $stale }
    $writeDeadline = Get-WebAdminSettingWriteDeadline -Review $approved -Deadline $Deadline
    if ($writeDeadline -le 0) { return $stale }
    if (-not (Set-ImportedSettings -Changes $plan.changes -Deadline $writeDeadline -ReviewedExpected $plan.before -ReviewedVersion $Version)) {
        if ($script:LastConfigSaveConflict) { return $stale }
        return @{ ok = $false; error = 'setting_save_failed' }
    }
    Add-AuditEntry (T 'cfg.importAudit' $plan.changes.Count $(Format-UserAuditActor -UserId $actor)) | Out-Null
    return @{ ok = $true; data = @{ applied = $plan.changes.Count } }
}
