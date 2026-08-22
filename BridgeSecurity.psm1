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

Export-ModuleMember -Function Protect-BridgePathAcl, Protect-BridgeConfigurationAcl
