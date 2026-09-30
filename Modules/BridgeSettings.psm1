Set-StrictMode -Version Latest

function Get-BridgeObjectProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $null
}

function Test-BridgeObjectProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $Object.PSObject.Properties.Match($Name).Count -gt 0
}

function Set-BridgeObjectProperty {
    # Add-Member on a dictionary creates a note property that JSON discards.
    # Defaults and identity arrays must survive the next settings save.
    param($Object, [Parameter(Mandatory)][string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value; return }
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
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
    if ($null -eq $settings) {
        $settings = [pscustomobject]@{}
        Set-BridgeObjectProperty -Object $Config -Name Settings -Value $settings
        $changed = $true
    }
    foreach ($name in $Defaults.Keys) {
        if (-not (Test-BridgeObjectProperty -Object $settings -Name ([string]$name))) {
            Set-BridgeObjectProperty -Object $settings -Name ([string]$name) -Value $Defaults[$name]
            $changed = $true
        }
    }
    foreach ($name in @('AllowedUserIds', 'AdminUserIds')) {
        if (-not (Test-BridgeObjectProperty -Object $Config -Name $name)) {
            Set-BridgeObjectProperty -Object $Config -Name $name -Value @()
            $changed = $true
        }
    }
    return $changed
}

Export-ModuleMember -Function Get-BridgeSetting, Get-BridgeSettingInt, Initialize-BridgeSettings
