Set-StrictMode -Version Latest

function Get-AuthorizationProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $null
}

function Test-BridgeAuthorized {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [object[]]$AllowedUserIds = @(),
        [object[]]$AllowedChatIds = @(),
        [object[]]$DisabledUserIds = @(),
        [switch]$RequireUserLevelAuth
    )
    if ($UserId -eq 0) { $UserId=$ChatId }
    if (@($DisabledUserIds | ForEach-Object {[long]$_}) -contains $UserId) { return $false }
    if ($UserId -ne 0 -and @($AllowedUserIds | ForEach-Object {[long]$_}) -contains $UserId) { return $true }
    if ($RequireUserLevelAuth -and $ChatId -ne $UserId) { return $false }
    return @($AllowedChatIds | ForEach-Object {[long]$_}) -contains $ChatId
}

function Test-BridgeAdministrator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [object[]]$AdminUserIds = @(),
        [object[]]$AdminChatIds = @(),
        [switch]$RequireUserLevelAuth
    )
    if ($UserId -eq 0) { $UserId=$ChatId }
    if ($UserId -ne 0 -and @($AdminUserIds | ForEach-Object {[long]$_}) -contains $UserId) { return $true }
    if ($RequireUserLevelAuth -and $ChatId -ne $UserId) { return $false }
    return @($AdminChatIds | ForEach-Object {[long]$_}) -contains $ChatId
}

function Test-BridgePrivateChat {
    [CmdletBinding()]
    param($Chat)
    if (-not $Chat) { return $false }
    $type=[string](Get-AuthorizationProperty -Object $Chat -Name type)
    if (-not [string]::IsNullOrWhiteSpace($type)) { return $type -eq 'private' }
    return [long](Get-AuthorizationProperty -Object $Chat -Name id) -gt 0
}

Export-ModuleMember -Function Test-BridgeAuthorized, Test-BridgeAdministrator, Test-BridgePrivateChat
