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
        [System.Collections.IDictionary]$Choices = @{}
    )

    foreach ($name in $Defaults.Keys) {
        $default = $Defaults[$name]
        $display = Get-BridgeMapValue -Map $DisplayMetadata -Name $name -Fallback @{}
        $category = [string](Get-BridgeMapValue -Map $CategoryByName -Name $name -Fallback 'advanced')
        $description = [string](Get-BridgeMapValue -Map $display -Name 'Description' -Fallback '')
        $label = [string](Get-BridgeMapValue -Map $Labels -Name $name -Fallback $(if ($description) { $description } else { $name }))
        $unit = [string](Get-BridgeMapValue -Map $display -Name 'Unit' -Fallback '')
        $settingChoices = @(Get-BridgeMapValue -Map $Choices -Name $name -Fallback @())
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
        }
    }
}

Export-ModuleMember -Function New-BridgeSettingSchema
