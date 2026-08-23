#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Send-TelegramDocument {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Caption = ''
    )
    try { $form = @{ chat_id = "$ChatId"; document = Get-Item -LiteralPath $FilePath -ErrorAction Stop } }
    catch { Write-BridgeLog "Failed to send Telegram document to $ChatId : $($_.Exception.Message)" 'ERROR'; return $false }
    if ($Caption) { $form.caption = $Caption }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendDocument" -Method Post -Form $form `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 3
    if (-not $request.Success) {
        Write-BridgeLog "Failed to send Telegram document to $ChatId : $($request.Error)" 'ERROR'
        return $false
    }
    return $true
}

function Receive-TelegramDocument {
    param(
        [Parameter(Mandatory)][string]$FileId,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaximumBytes = 1048576
    )
    $metadata = Invoke-RestMethod -Uri "$apiBase/getFile?file_id=$([uri]::EscapeDataString($FileId))" -Method Get `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1)
    if (-not (Get-JsonProp $metadata 'ok')) { throw 'Telegram رفض طلب معلومات الملف.' }
    $result = Get-JsonProp $metadata 'result'
    $remotePath = [string](Get-JsonProp $result 'file_path')
    if ([string]::IsNullOrWhiteSpace($remotePath) -or $remotePath.Contains('..') -or $remotePath -notmatch '^[A-Za-z0-9_./-]+$') {
        throw 'Telegram أعاد مسار ملف غير صالح.'
    }
    $directory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Invoke-WebRequest -Uri "https://api.telegram.org/file/bot$($config.BotToken)/$remotePath" -OutFile $DestinationPath `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) | Out-Null
    $length = (Get-Item -LiteralPath $DestinationPath -ErrorAction Stop).Length
    if ($length -le 0 -or $length -gt $MaximumBytes) {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        throw "حجم ملف الاستيراد غير صالح ($length بايت)."
    }
    return $DestinationPath
}

function Save-UserProfiles {
    param([switch]$Force)
    if (-not $script:UserProfilesDirty) { return $true }
    if (-not $Force -and ((Get-Date) - $script:LastUserProfilesFlush).TotalSeconds -lt 60) { return $true }
    try {
        $temporary = "$($script:userProfilesFile).tmp"
        $script:UserProfiles | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:userProfilesFile -Force -ErrorAction Stop
        $script:UserProfilesDirty = $false; $script:LastUserProfilesFlush = Get-Date
        return $true
    }
    catch { Write-BridgeLog "Could not write user-profiles.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Record-UserApprovalMetadata {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ApprovedByUserId)
    $script:UserProfiles[[string]$TargetUserId] = @{ AddedAt = (Get-Date).ToString('o'); AddedByUserId = $ApprovedByUserId; LastActivityAt = $null }
    $script:UserProfilesDirty = $true
    return Save-UserProfiles -Force
}

function Update-UserLastActivity {
    param([Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Authorized -ChatId $UserId -UserId $UserId)) { return $false }
    $id = [string]$UserId
    if (-not $script:UserProfiles.ContainsKey($id)) { $script:UserProfiles[$id] = @{ AddedAt = ''; AddedByUserId = 0L; LastActivityAt = '' } }
    $script:UserProfiles[$id].LastActivityAt = (Get-Date).ToString('o'); $script:UserProfilesDirty = $true
    Save-UserProfiles | Out-Null
    return $true
}

function Import-DisabledUsers {
    if (-not (Test-Path -LiteralPath $script:disabledUsersFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:disabledUsersFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { if ([bool]$prop.Value) { $script:DisabledUserIds[$prop.Name] = $true } }
    }
    catch { Write-BridgeLog "Could not read disabled-users.json: $($_.Exception.Message)" 'WARN' }
}

function Save-DisabledUsers {
    try {
        $temporary = "$($script:disabledUsersFile).tmp"
        $script:DisabledUserIds | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:disabledUsersFile -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write disabled-users.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Set-UserDisabled {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][bool]$Disabled)
    if ($TargetUserId -le 0) { return $false }
    if ($Disabled) {
        $adminIds = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
        $activeAdmins = @($adminIds | Where-Object { -not (Test-UserDisabled -UserId ([long]$_)) })
        if ($adminIds -contains $TargetUserId -and $activeAdmins.Count -le 1) { return $false }
    }
    if ($Disabled) { $script:DisabledUserIds[[string]$TargetUserId] = $true }
    else { $script:DisabledUserIds.Remove([string]$TargetUserId) }
    return Save-DisabledUsers
}

function Test-UserDisabled {
    param([Parameter(Mandatory)][long]$UserId)
    return $script:DisabledUserIds.ContainsKey([string]$UserId)
}

function Revoke-AuthorizedUser {
    param([Parameter(Mandatory)][long]$TargetUserId)
    $admins = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
    if ($admins -contains $TargetUserId -and $admins.Count -le 1) { return [pscustomobject]@{ Success = $false; Error = 'لا يمكن سحب صلاحية آخر مشرف.' } }
    foreach ($name in @('AllowedChatIds', 'AllowedUserIds', 'AdminChatIds', 'AdminUserIds')) {
        $remaining = @(@(Get-JsonProp $config $name) | Where-Object { [long]$_ -ne $TargetUserId })
        $config | Add-Member -NotePropertyName $name -NotePropertyValue $remaining -Force
    }
    $script:DisabledUserIds.Remove([string]$TargetUserId)
    $script:UserProfiles.Remove([string]$TargetUserId); $script:UserProfilesDirty = $true
    Save-DisabledUsers | Out-Null; Save-UserProfiles -Force | Out-Null; Save-Config
    return [pscustomobject]@{ Success = $true; Error = '' }
}

function Get-AuthorizedUsers {
    $ids = @(@(Get-JsonProp $config 'AllowedUserIds') + @(Get-JsonProp $config 'AllowedChatIds') + @(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') |
            Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
    $adminIds = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Sort-Object -Unique)
    return @($ids | ForEach-Object {
            $id = [long]$_
            [pscustomobject]@{
                UserId = $id; Alias = Get-UserDisplayName -UserId $id
                Role = if ($adminIds -contains $id) { 'admin' } else { 'operator' }
                Disabled = Test-UserDisabled -UserId $id
                AddedAt = if ($script:UserProfiles.ContainsKey([string]$id)) { [string]$script:UserProfiles[[string]$id].AddedAt } else { '' }
                AddedByUserId = if ($script:UserProfiles.ContainsKey([string]$id)) { [long]$script:UserProfiles[[string]$id].AddedByUserId } else { 0L }
                LastActivityAt = if ($script:UserProfiles.ContainsKey([string]$id)) { [string]$script:UserProfiles[[string]$id].LastActivityAt } else { '' }
            }
        })
}

function Request-UserRevocation {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$AdminUserId)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'user_revoke'; TargetUserId = $TargetUserId; UserId = $AdminUserId }
    Send-TelegramMessage -ChatId $ChatId -Text "⚠️ تأكيد سحب صلاحية $(Get-UserDisplayName -UserId $TargetUserId) ($TargetUserId)؟" `
        -ReplyMarkup @{ inline_keyboard = @(, @((New-Button '✅ نعم، اسحب الصلاحية' 'usr:revokeconfirm'), (New-Button '❌ إلغاء' 'menu:usersadmin'))) }
}

function Test-Authorized {
    <# In a private chat chat.id == user.id, so the historical AllowedChatIds
       list keeps working untouched. In a group they differ, and with
       RequireUserLevelAuth on (the default) the sender must be listed in
       AllowedUserIds explicitly - whitelisting a group no longer implicitly
       authorizes every member of it. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return Test-BridgeAuthorized -ChatId $ChatId -UserId $UserId `
        -AllowedUserIds @(Get-JsonProp $config 'AllowedUserIds') -AllowedChatIds @(Get-JsonProp $config 'AllowedChatIds') `
        -DisabledUserIds @($script:DisabledUserIds.Keys) -RequireUserLevelAuth:([bool](Get-Setting 'RequireUserLevelAuth'))
}

function Test-Admin {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return Test-BridgeAdministrator -ChatId $ChatId -UserId $UserId `
        -AdminUserIds @(Get-JsonProp $config 'AdminUserIds') -AdminChatIds @(Get-JsonProp $config 'AdminChatIds') `
        -RequireUserLevelAuth:([bool](Get-Setting 'RequireUserLevelAuth'))
}

function Test-TelegramPrivateChat {
    <# This bridge is intentionally operated through one-to-one chats only.
       Telegram always supplies chat.type; the positive-id fallback keeps old
       saved/test callback payloads compatible without authorizing groups. #>
    param($Chat)
    return Test-BridgePrivateChat -Chat $Chat
}

