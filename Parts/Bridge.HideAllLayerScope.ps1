#requires -Version 7

function ConvertTo-HideAllLayerScopeEdit {
    param([string]$Mode, [object[]]$Layers = @())
    if ($Mode -ceq 'all' -and $Layers.Count -eq 0) { return @{ ok = $true; value = 'all'; layers = @() } }
    if ($Mode -ceq 'none' -and $Layers.Count -eq 0) { return @{ ok = $true; value = ''; layers = @() } }
    if ($Mode -cne 'selected' -or $Layers.Count -eq 0) { return @{ ok = $false; error = 'hide_all_scope_invalid' } }
    $known = @(Get-KnownLayers | Where-Object { $_ -gt 0 })
    if ($Layers.Count -gt $known.Count) { return @{ ok = $false; error = 'hide_all_scope_invalid' } }
    $selected = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($layer in $Layers) {
        if (($layer -isnot [int] -and $layer -isnot [long]) -or $layer -notin $known -or -not $selected.Add([int]$layer)) {
            return @{ ok = $false; error = 'hide_all_scope_invalid' }
        }
    }
    $ordered = @($selected | Sort-Object)
    return @{ ok = $true; value = ($ordered -join ','); layers = $ordered }
}

function Save-HideAllLayerScope {
    param([string]$Mode, [object[]]$Layers = @(), [long]$UserId, [long]$Deadline = 0)
    $edit = ConvertTo-HideAllLayerScopeEdit -Mode $Mode -Layers $Layers
    if (-not $edit.ok) { return $edit }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }
    $previous = [string](Get-Setting 'HideAllLayers')
    if ([string]::Equals($previous, $edit.value, [StringComparison]::Ordinal)) { return @{ ok = $true } }

    $settings = Get-JsonProp $config 'Settings'
    if ($null -eq $settings) { return @{ ok = $false; error = 'hide_all_scope_save_failed' } }
    $script:LastConfigSaveFailed = $false
    $script:LastConfigSaveConflict = $false
    try {
        Save-Config -Deadline $Deadline -ReviewedPatch @{ HideAllLayers = $edit.value } -ReviewedExpected @{ HideAllLayers = $previous }
    }
    catch { $script:LastConfigSaveFailed = $true }
    if ($script:LastConfigSaveFailed) {
        $code = if ($script:LastConfigSaveConflict) { 'hide_all_scope_stale' } else { 'hide_all_scope_save_failed' }
        return @{ ok = $false; error = $code }
    }
    Set-JsonProp $settings 'HideAllLayers' $edit.value
    Write-BridgeLog "User $UserId changed HideAllLayers to '$($edit.value)'" 'WARN'
    Add-AuditEntry (T 'cmd.hideAllAudit' $edit.value (Format-UserAuditActor -UserId $UserId)) | Out-Null
    return @{ ok = $true }
}
