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

function Test-BridgeOwner {
    <#
        Owners are the only people who may appoint or remove an administrator.

        With OwnerUserIds unset the owner is whoever set the bridge up: the
        first id in AdminUserIds, falling back to the first AdminChatIds
        entry. That person configured the bot and its token, so they already
        hold every power the role grants - naming them costs nothing and
        keeps the bridge usable out of the box, where an empty owner list
        would take the promote button away from everyone until somebody
        hand-edited config.json.

        Deliberately the FIRST id and not every administrator: the whole
        point of the tier is that appointing administrators is narrower than
        being one.

        Matched on the user id alone, with no RequireUserLevelAuth switch to
        relax it. Administrator rights can be granted to a whole chat; owner
        rights are a person, and a group must never confer them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [object[]]$OwnerUserIds = @(),
        [object[]]$AdminUserIds = @(),
        [object[]]$AdminChatIds = @()
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($UserId -le 0) { return $false }
    $owners = @(Get-BridgeOwnerIds -OwnerUserIds $OwnerUserIds -AdminUserIds $AdminUserIds -AdminChatIds $AdminChatIds)
    return ($owners -contains $UserId)
}

function Get-BridgeOwnerIds {
    <# The effective owner list: what is configured, or the first
       administrator when nothing is. Shared so the check and the user screen
       cannot disagree about who the owner is. #>
    [CmdletBinding()]
    param(
        [object[]]$OwnerUserIds = @(),
        [object[]]$AdminUserIds = @(),
        [object[]]$AdminChatIds = @()
    )
    $clean = { param([object[]]$Ids)
        @($Ids | Where-Object { $null -ne $_ -and $_ -ne '' } | ForEach-Object { [long]$_ } | Where-Object { $_ -gt 0 }) }

    # @(...) around every call: a scriptblock returning an empty array unrolls
    # to nothing, and $null.Count throws under StrictMode.
    $owners = @(& $clean $OwnerUserIds)
    if ($owners.Count -gt 0) { return @($owners | Sort-Object -Unique) }

    $admins = @(& $clean $AdminUserIds)
    if ($admins.Count -eq 0) { $admins = @(& $clean $AdminChatIds) }
    if ($admins.Count -eq 0) { return @() }
    return @($admins[0])
}

function Test-BridgePrivateChat {
    [CmdletBinding()]
    param($Chat)
    if (-not $Chat) { return $false }
    $type=[string](Get-AuthorizationProperty -Object $Chat -Name type)
    if (-not [string]::IsNullOrWhiteSpace($type)) { return $type -eq 'private' }
    return [long](Get-AuthorizationProperty -Object $Chat -Name id) -gt 0
}

Export-ModuleMember -Function Test-BridgeAuthorized, Test-BridgeAdministrator, Test-BridgeOwner, Get-BridgeOwnerIds, Test-BridgePrivateChat
