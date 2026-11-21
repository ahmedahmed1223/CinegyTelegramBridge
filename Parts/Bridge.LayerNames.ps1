#requires -Version 7

function ConvertTo-LayerNameEdit {
    param([AllowEmptyString()][string]$Name)
    if ($Name -match '[;=]') { return @{ ok = $false; error = 'layer_name_invalid' } }
    if ($Name -match '[\p{Cc}\p{Zl}\p{Zp}\u202A-\u202E\u2066-\u2069]') {
        return @{ ok = $false; error = 'layer_name_single_line' }
    }
    $label = $Name.Trim()
    if ($label -match '^(?:[a-z]:[\\/]|\\\\|(?:file|https?|rtmps?|srt)://)') {
        return @{ ok = $false; error = 'layer_name_invalid' }
    }
    if ($label.Length -gt 240 -or [Globalization.StringInfo]::new($label).LengthInTextElements -gt 60) {
        return @{ ok = $false; error = 'layer_name_invalid' }
    }
    return @{ ok = $true; name = $label }
}

function Save-LayerName {
    param([int]$Layer, [AllowEmptyString()][string]$Name, [long]$UserId, [long]$Deadline = 0, [switch]$NormalizeOtherPairs)
    if ($Layer -le 0 -or (-not $NormalizeOtherPairs -and $Layer -notin @(Get-KnownLayers))) {
        return @{ ok = $false; error = 'layer_name_not_found' }
    }
    $edit = ConvertTo-LayerNameEdit -Name $Name
    if (-not $edit.ok) { return $edit }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }

    $setting = 'LayerNames'
    $stored = [string](Get-Setting $setting)
    $pairs = [System.Collections.Generic.List[string]]::new()
    $normalized = @{}
    $replaced = $false
    foreach ($pair in ($stored -split ';')) {
        $entry = ConvertFrom-LayerNamePair -Pair $pair
        if ($NormalizeOtherPairs) {
            if ($entry -and $entry.name -and $entry.layer -ne $Layer) { $normalized[[int]$entry.layer] = $entry.name }
            continue
        }
        if ($entry -and $entry.layer -eq $Layer) {
            # Put the replacement where the effective name was read, and
            # remove duplicate entries only for this layer.
            if (-not $replaced -and $edit.name) { $pairs.Add("$Layer=$($edit.name)") }
            $replaced = $true
            continue
        }
        if ($stored) { $pairs.Add($pair) }
    }
    if ($NormalizeOtherPairs) {
        # The Bot has always cleaned and sorted the compound setting.
        if ($edit.name) { $normalized[$Layer] = $edit.name }
        foreach ($number in @($normalized.Keys | Sort-Object)) { $pairs.Add("$number=$($normalized[$number])") }
    }
    elseif (-not $replaced -and $edit.name) { $pairs.Add("$Layer=$($edit.name)") }
    $replacement = $pairs -join ';'
    if ([string]::Equals($stored, $replacement, [StringComparison]::Ordinal)) { return $edit }

    $settings = Get-JsonProp $config 'Settings'
    if ($null -eq $settings) { return @{ ok = $false; error = 'layer_name_save_failed' } }
    $script:LastConfigSaveFailed = $false
    $script:LastConfigSaveConflict = $false
    try { Save-Config -Deadline $Deadline -ReviewedPatch @{ LayerNames = $replacement } -ReviewedExpected @{ LayerNames = $stored } }
    catch { $script:LastConfigSaveFailed = $true }
    if ($script:LastConfigSaveFailed) {
        if ($script:LastConfigSaveConflict) { return @{ ok = $false; error = 'layer_name_stale' } }
        return @{ ok = $false; error = 'layer_name_save_failed' }
    }
    Set-JsonProp $settings $setting $replacement

    $action = if ($edit.name) { "set to '$(Protect-SensitiveText $edit.name)'" } else { 'cleared' }
    Write-BridgeLog "User $UserId $action layer $Layer name"
    Add-AuditEntry (T 'cmd.layerNameAudit' $Layer $action (Format-UserAuditActor -UserId $UserId)) | Out-Null
    return $edit
}
