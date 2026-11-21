#requires -Version 7

function Set-TemplateMaxAirPolicy {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][int]$Seconds, [long]$UserId = 0, [long]$Deadline = 0)
    if ($Seconds -lt 0 -or $Seconds -gt 3600) { return @{ ok = $false; error = 'template_air_limit_invalid' } }
    if (-not (Get-TemplateStore).Map.ContainsKey($Key)) { return @{ ok = $false; error = 'scene_not_found' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ ok = $false; error = 'bridge_busy' } }

    $setting = 'TemplateMaxAirSeconds'
    $settings = Get-JsonProp $config 'Settings'
    if ($null -eq $settings) { return @{ ok = $false; error = 'template_air_limit_save_failed' } }
    $map = Get-JsonProp $settings $setting
    $newMap = $null -eq $map
    $hadSetting = $false
    if ($newMap) {
        $hadSetting = if ($settings -is [System.Collections.IDictionary]) { $settings.Contains($setting) }
        else { $null -ne $settings.PSObject.Properties[$setting] }
        $map = [ordered]@{}
        Set-JsonProp $settings $setting $map
    }
    elseif ($map -isnot [System.Collections.IDictionary] -and $map -isnot [System.Management.Automation.PSCustomObject]) {
        return @{ ok = $false; error = 'template_air_limit_save_failed' }
    }

    # Only one live settings key changes. Roll it back on a failed durable
    # write so new shows cannot use a policy that was never committed.
    $hadLimit = if ($map -is [System.Collections.IDictionary]) { $map.Contains($Key) }
    else { $null -ne $map.PSObject.Properties[$Key] }
    $previous = Get-JsonProp $map $Key
    if ($Seconds -eq 0) { Remove-JsonProp $map $Key }
    else { Set-JsonProp $map $Key $Seconds }

    $script:LastConfigSaveFailed = $false
    try { Save-Config -Deadline $Deadline }
    catch { $script:LastConfigSaveFailed = $true }
    if ($script:LastConfigSaveFailed) {
        $currentSettings = Get-JsonProp $config 'Settings'
        if ($newMap) {
            if ($hadSetting) { Set-JsonProp $currentSettings $setting $null }
            else { Remove-JsonProp $currentSettings $setting }
        }
        else {
            if ($hadLimit) { Set-JsonProp $map $Key $previous }
            else { Remove-JsonProp $map $Key }
            Set-JsonProp $currentSettings $setting $map
        }
        return @{ ok = $false; error = 'template_air_limit_save_failed' }
    }

    Write-BridgeLog "Template maximum on-air policy updated by $UserId to $Seconds seconds."
    Add-AuditEntry (T 'kb.settingAudit' "$setting/$Key" $Seconds (Format-UserAuditActor -UserId $UserId)) | Out-Null
    return @{ ok = $true }
}
