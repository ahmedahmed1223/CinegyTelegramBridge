Set-StrictMode -Version Latest

function Get-BridgeObjectProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $null
}

function Get-BridgeSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defaults,
        [Parameter(Mandatory)][string]$Name
    )
    $settings = Get-BridgeObjectProperty -Object $Config -Name Settings
    if ($settings) {
        $value = Get-BridgeObjectProperty -Object $settings -Name $Name
        if ($null -ne $value) { return $value }
    }
    if ($Defaults.Contains($Name)) { return $Defaults[$Name] }
    return $null
}

function Get-BridgeSettingInt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defaults,
        [Parameter(Mandatory)][string]$Name,
        [int]$Minimum = 0
    )
    $value = 0
    $raw = Get-BridgeSetting -Config $Config -Defaults $Defaults -Name $Name
    if (-not [int]::TryParse([string]$raw, [ref]$value)) { $value = 0 }
    if ($value -lt $Minimum) { $value = $Minimum }
    return $value
}

function Initialize-BridgeSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defaults
    )
    $settings = Get-BridgeObjectProperty -Object $Config -Name Settings
    $changed = $false
    if (-not $settings) {
        $settings = [pscustomobject]@{}
        $Config | Add-Member -NotePropertyName Settings -NotePropertyValue $settings -Force
        $changed = $true
    }
    foreach ($name in $Defaults.Keys) {
        if ($settings.PSObject.Properties.Match([string]$name).Count -eq 0) {
            $settings | Add-Member -NotePropertyName ([string]$name) -NotePropertyValue $Defaults[$name] -Force
            $changed = $true
        }
    }
    foreach ($name in @('AllowedUserIds', 'AdminUserIds')) {
        if ($Config.PSObject.Properties.Match($name).Count -eq 0) {
            $Config | Add-Member -NotePropertyName $name -NotePropertyValue @() -Force
            $changed = $true
        }
    }
    return $changed
}

Export-ModuleMember -Function Get-BridgeSetting, Get-BridgeSettingInt, Initialize-BridgeSettings
