#requires -Version 7

$script:UserWorkingNameLimit = 80

function Get-UserWorkingNameEdit {
    param([AllowEmptyString()][string]$Value)
    $alias = $Value.Trim()
    if ($alias -ceq '-') { $alias = '' }
    if ([Globalization.StringInfo]::new($alias).LengthInTextElements -gt $script:UserWorkingNameLimit) {
        return @{ ok = $false; error = 'telegram_alias_too_long' }
    }
    if ($alias -match '[\x00-\x1F\x7F-\x9F\u2028\u2029]') {
        return @{ ok = $false; error = 'telegram_alias_multiline' }
    }
    return @{ ok = $true; alias = $alias }
}

function Set-UserWorkingName {
    param([long]$TargetUserId, [AllowEmptyString()][string]$Value)
    if ($TargetUserId -le 0) { return @{ ok = $false; error = 'bad_request' } }
    $edit = Get-UserWorkingNameEdit -Value $Value
    if (-not $edit.ok) { return $edit }
    $key = [string]$TargetUserId
    $hadAlias = $script:UserAliases.ContainsKey($key)
    $previous = $script:UserAliases[$key]
    if (-not (Set-UserAlias -TargetUserId $TargetUserId -Alias $edit.alias)) {
        # Persisted display names also feed authentication claims. A failed
        # write must leave readers on the previous committed name.
        if ($hadAlias) { $script:UserAliases[$key] = $previous }
        else { $script:UserAliases.Remove($key) }
        return @{ ok = $false; error = 'telegram_alias_save_failed' }
    }
    return $edit
}

function Write-UserWorkingNameAudit {
    param([long]$TargetUserId, [long]$AdminUserId, [AllowEmptyString()][string]$Alias)
    $action = if ($Alias) { (T 'kb.aliasSet' (Protect-SensitiveText $Alias)) } else { (T 'kb.clearAlias') }
    Write-BridgeLog "Admin $AdminUserId updated alias for user ${TargetUserId}: $action"
    Add-AuditEntry (T 'kb.userAudit' $action (Format-UserAuditActor -UserId $TargetUserId) (Format-UserAuditActor -UserId $AdminUserId)) | Out-Null
}
