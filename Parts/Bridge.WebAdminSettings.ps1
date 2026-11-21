#requires -Version 7

$script:WebAdminSettingReviews = @{}

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

function Get-WebAdminEditableSetting {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ error = 'forbidden' }
    }
    # These settings take effect through already established reads. Protected
    # controls and settings that need side effects stay in their existing screens.
    $id = [string](Get-JsonProp $Arguments 'id')
    if (($id -cnotin 'NotifyAdminsOnAccessRequest', 'AskRequesterName', 'MaxPendingApprovals', 'PendingStateTimeoutMinutes' -and
            -not (Get-WebAdminPresentationSettingSchema -Name $id)) -or $script:ProtectedSettings -contains $id) {
        return @{ error = 'setting_not_editable' }
    }
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
