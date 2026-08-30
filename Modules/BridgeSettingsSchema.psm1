Set-StrictMode -Version Latest

function Get-BridgeMapValue {
    param($Map, [string]$Name, $Fallback = $null)
    if ($null -eq $Map) { return $Fallback }
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Name)) { return $Map[$Name] }
    $property = $Map.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Fallback
}

function New-BridgeSettingSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defaults,
        [System.Collections.IDictionary]$DisplayMetadata = @{},
        [System.Collections.IDictionary]$CategoryByName = @{},
        [System.Collections.IDictionary]$Labels = @{},
        [string[]]$ProtectedNames = @(),
        [System.Collections.IDictionary]$Choices = @{},
        [System.Collections.IDictionary]$Constraints = @{},
        [string[]]$AdvancedNames = @(),
        [string[]]$SensitiveNames = @(),
        [string[]]$ConfirmationNames = @(),
        [string[]]$RestartNames = @()
    )

    foreach ($name in $Defaults.Keys) {
        $default = $Defaults[$name]
        $display = Get-BridgeMapValue -Map $DisplayMetadata -Name $name -Fallback @{}
        $category = [string](Get-BridgeMapValue -Map $CategoryByName -Name $name -Fallback 'advanced')
        $description = [string](Get-BridgeMapValue -Map $display -Name 'Description' -Fallback '')
        $label = [string](Get-BridgeMapValue -Map $Labels -Name $name -Fallback $(if ($description) { $description } else { $name }))
        $unit = [string](Get-BridgeMapValue -Map $display -Name 'Unit' -Fallback '')
        $settingChoices = @(Get-BridgeMapValue -Map $Choices -Name $name -Fallback @())
        $constraint = Get-BridgeMapValue -Map $Constraints -Name $name -Fallback @{}
        [pscustomobject]@{
            Name = [string]$name
            Default = $default
            ValueType = if ($null -eq $default) { 'Object' } else { $default.GetType().Name }
            Category = if ($category) { $category } else { 'advanced' }
            Label = if ($label) { $label } else { [string]$name }
            Unit = $unit
            Description = $description
            Protected = $ProtectedNames -contains [string]$name
            Choices = $settingChoices
            Minimum = Get-BridgeMapValue -Map $constraint -Name 'Minimum'
            Maximum = Get-BridgeMapValue -Map $constraint -Name 'Maximum'
            Advanced = ($AdvancedNames -contains [string]$name) -or $category -eq 'advanced'
            Sensitive = $SensitiveNames -contains [string]$name
            RequiresConfirmation = $ConfirmationNames -contains [string]$name
            RequiresRestart = $RestartNames -contains [string]$name
        }
    }
}

function Find-BridgeSettings {
    param([Parameter(Mandatory)][object[]]$Schema, [Parameter(Mandatory)][string]$Query)
    $needle = $Query.Trim()
    return @($Schema | Where-Object { $_.Name -like "*$needle*" -or $_.Label -like "*$needle*" -or $_.Description -like "*$needle*" })
}

function Get-ModifiedBridgeSettings {
    param([Parameter(Mandatory)][object[]]$Schema, [Parameter(Mandatory)][hashtable]$Values)
    return @($Schema | Where-Object { $Values.ContainsKey($_.Name) -and $Values[$_.Name] -ne $_.Default })
}

function Get-BridgeSettingsForMode {
    param([Parameter(Mandatory)][object[]]$Schema, [switch]$Advanced)
    if ($Advanced) { return @($Schema) }
    return @($Schema | Where-Object { -not $_.Advanced })
}

Export-ModuleMember -Function New-BridgeSettingSchema, Find-BridgeSettings, Get-ModifiedBridgeSettings, Get-BridgeSettingsForMode
