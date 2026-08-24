Set-StrictMode -Version Latest

function Protect-BridgePathAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $allowedSids = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    ) | Select-Object -Unique

    foreach ($candidate in $Path) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        $currentAcl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        $currentSids = @($currentAcl.Access | ForEach-Object {
                $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
            } | Sort-Object -Unique)
        $expectedSids = @($allowedSids | ForEach-Object Value | Sort-Object -Unique)
        $hasOnlyFullControl = @($currentAcl.Access | Where-Object {
                $_.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
                ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl
            }).Count -eq 0
        if ($currentAcl.AreAccessRulesProtected -and $hasOnlyFullControl -and
            @(Compare-Object $currentSids $expectedSids).Count -eq 0) { continue }

        $acl = if ($item.PSIsContainer) {
            [Security.AccessControl.DirectorySecurity]::new()
        }
        else { [Security.AccessControl.FileSecurity]::new() }
        $acl.SetAccessRuleProtection($true, $false)
        $inheritance = if ($item.PSIsContainer) {
            [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        }
        else { [Security.AccessControl.InheritanceFlags]::None }
        foreach ($sid in $allowedSids) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                $sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule) | Out-Null
        }
        try { Set-Acl -LiteralPath $item.FullName -AclObject $acl -ErrorAction Stop }
        catch { throw "Could not secure '$($item.FullName)': $($_.Exception.Message)" }
    }
}

function Protect-BridgeConfigurationAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    $backupDirectory = "$ConfigPath.backups"
    $targets = @($ConfigPath, "$ConfigPath.bak", $backupDirectory)
    if (Test-Path -LiteralPath $backupDirectory) {
        $targets += @(Get-ChildItem -LiteralPath $backupDirectory -File -Force -ErrorAction Stop | ForEach-Object FullName)
    }
    Protect-BridgePathAcl -Path $targets
}

function ConvertTo-BridgeProtectedSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'DPAPI secret protection is available only on Windows.' }
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($Value)
    try {
        $cipherBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { return [Convert]::ToBase64String($cipherBytes) }
        finally { [Array]::Clear($cipherBytes, 0, $cipherBytes.Length) }
    }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}

function ConvertFrom-BridgeProtectedSecret {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CipherText)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'DPAPI secret protection is available only on Windows.' }
    $cipherBytes = [Convert]::FromBase64String($CipherText)
    try {
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $cipherBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { return [Text.Encoding]::UTF8.GetString($plainBytes) }
        finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
    }
    finally { [Array]::Clear($cipherBytes, 0, $cipherBytes.Length) }
}

function Read-BridgeSecretStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "DPAPI secret store not found: $Path" }
    $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([int]$document.Version -ne 1 -or [string]$document.Scope -ne 'CurrentUser') { throw 'Unsupported DPAPI secret-store format.' }
    $result = @{}
    foreach ($property in $document.Secrets.PSObject.Properties) {
        $result[$property.Name] = ConvertFrom-BridgeProtectedSecret -CipherText ([string]$property.Value)
    }
    return $result
}

function Write-BridgeSecretStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Secrets)
    $encrypted = [ordered]@{}
    foreach ($name in @($Secrets.Keys | Sort-Object)) {
        if ($name -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') { throw "Invalid secret name '$name'." }
        $encrypted[$name] = ConvertTo-BridgeProtectedSecret -Value ([string]$Secrets[$name])
    }
    # ProtectedBy records which identity can actually open this store. DPAPI
    # CurrentUser secrets are unreadable by any other account, and both
    # installers run the bridge as SYSTEM - so without this the readiness
    # check cannot warn, and the mismatch only shows up as a service that
    # restarts for ever. Purely informational: nothing is derived from it.
    $document = [ordered]@{
        Version     = 1
        Scope       = 'CurrentUser'
        ProtectedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Secrets     = $encrypted
    }
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = "$Path.tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($document | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
        Protect-BridgePathAcl -Path $Path
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Resolve-BridgeConfigurationSecrets {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$StorePath)
    $references = @{}
    $store = $null
    $fields = @(
        @{ Path = 'BotToken'; Object = $Config; Name = 'BotToken' }
        @{ Path = 'LiveStream.SourceUrl'; Object = $Config.LiveStream; Name = 'SourceUrl' }
        @{ Path = 'LiveStream.RtmpDestination'; Object = $Config.LiveStream; Name = 'RtmpDestination' }
    )
    foreach ($field in $fields) {
        if ($null -eq $field.Object -or $field.Object.PSObject.Properties.Match($field.Name).Count -eq 0) { continue }
        $value = [string]$field.Object.($field.Name)
        if ($value -notmatch '^dpapi:([A-Za-z][A-Za-z0-9_.-]{0,63})$') { continue }
        if ($null -eq $store) { $store = Read-BridgeSecretStore -Path $StorePath }
        $secretName = $Matches[1]
        if (-not $store.ContainsKey($secretName)) { throw "DPAPI secret '$secretName' is missing from the store." }
        $references[$field.Path] = "dpapi:$secretName"
        $field.Object.($field.Name) = [string]$store[$secretName]
    }
    return [pscustomobject]@{ Config = $Config; References = $references; StorePath = $StorePath }
}

function ConvertTo-BridgePersistableConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [hashtable]$References = @{})
    $copy = $Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    foreach ($path in $References.Keys) {
        switch ($path) {
            'BotToken' { $copy.BotToken = [string]$References[$path] }
            'LiveStream.SourceUrl' { $copy.LiveStream.SourceUrl = [string]$References[$path] }
            'LiveStream.RtmpDestination' { $copy.LiveStream.RtmpDestination = [string]$References[$path] }
        }
    }
    return $copy
}

function Update-BridgeReferencedSecrets {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [hashtable]$References = @{}, [Parameter(Mandatory)][string]$StorePath)
    if ($References.Count -eq 0) { return }
    $secrets = Read-BridgeSecretStore -Path $StorePath
    foreach ($path in $References.Keys) {
        $name = ([string]$References[$path]).Substring(6)
        switch ($path) {
            'BotToken' { $secrets[$name] = [string]$Config.BotToken }
            'LiveStream.SourceUrl' { $secrets[$name] = [string]$Config.LiveStream.SourceUrl }
            'LiveStream.RtmpDestination' { $secrets[$name] = [string]$Config.LiveStream.RtmpDestination }
        }
    }
    Write-BridgeSecretStore -Path $StorePath -Secrets $secrets
}

Export-ModuleMember -Function Protect-BridgePathAcl, Protect-BridgeConfigurationAcl, ConvertTo-BridgeProtectedSecret, `
    ConvertFrom-BridgeProtectedSecret, Read-BridgeSecretStore, Write-BridgeSecretStore, `
    Resolve-BridgeConfigurationSecrets, ConvertTo-BridgePersistableConfig, Update-BridgeReferencedSecrets
