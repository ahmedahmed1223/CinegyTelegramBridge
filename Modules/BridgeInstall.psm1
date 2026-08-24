Set-StrictMode -Version Latest

function Get-BridgeInstallProperty {
    <# Reads a possibly-absent property without tripping StrictMode, for both
       hashtables and ConvertFrom-Json objects. #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $null
}

function Get-BridgeReadinessReport {
    <#
        Decides whether a bridge installation will actually run, from facts the
        caller has already gathered. Pure: no disk, no registry, no network, so
        every branch below is testable.

        The check that matters most is the DPAPI one. Secrets are protected
        with DataProtectionScope::CurrentUser, and both installers run the
        bridge as SYSTEM. Protect the token as yourself, install the service,
        and it starts, fails to decrypt, and dies - repeatedly, because the
        supervisor restarts it. Nothing in the old flow said a word about it.

        Errors block the install. Warnings do not: a missing ffmpeg only costs
        snapshots, and refusing to install over that would be worse than
        saying so.
    #>
    [CmdletBinding()]
    param(
        [object]$Config,
        [string]$RunAsAccount = 'SYSTEM',
        [string]$ProtectedBy = '',
        [switch]$HasPowerShell7,
        [switch]$HasFfmpeg,
        [switch]$TemplatesReadable,
        [string]$TemplatesError = ''
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not $HasPowerShell7) {
        $errors.Add('PowerShell 7 (pwsh.exe) was not found. Install it from https://aka.ms/powershell-release.')
    }
    if ($null -eq $Config) {
        $errors.Add('config.json is missing or is not valid JSON. Copy config.example.json to config.json and edit it.')
        return [pscustomobject]@{ Ok = $false; Errors = @($errors); Warnings = @($warnings) }
    }

    $token = [string](Get-BridgeInstallProperty -Object $Config -Name 'BotToken')
    if ([string]::IsNullOrWhiteSpace($token)) {
        $errors.Add('config.json has no BotToken. Get one from @BotFather and put it in config.json.')
    }
    elseif ($token -match '^(?i)(REPLACE|YOUR|TOKEN|CHANGE)') {
        $errors.Add('config.json still carries the placeholder BotToken from config.example.json.')
    }

    $adminIds = @(Get-BridgeInstallProperty -Object $Config -Name 'AdminChatIds')
    if ($adminIds.Count -eq 0) {
        $errors.Add('config.json lists no AdminChatIds. Without one, nobody can administer the bot or receive its alerts.')
    }
    $allowedIds = @(Get-BridgeInstallProperty -Object $Config -Name 'AllowedChatIds')
    if ($allowedIds.Count -eq 0) {
        $warnings.Add('No AllowedChatIds yet. Operators will have to request access and be approved from chat.')
    }

    $settings = Get-BridgeInstallProperty -Object $Config -Name 'Settings'
    if ([bool](Get-BridgeInstallProperty -Object $settings -Name 'EnableDpapiSecrets')) {
        $serviceAccount = if ([string]::IsNullOrWhiteSpace($RunAsAccount)) { 'SYSTEM' } else { $RunAsAccount }
        $sameAccount = -not [string]::IsNullOrWhiteSpace($ProtectedBy) -and
            $ProtectedBy.Trim().EndsWith($serviceAccount.Trim(), [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $sameAccount) {
            $errors.Add("DPAPI secrets are protected for '$ProtectedBy' but the service will run as '$serviceAccount'. " +
                'A CurrentUser DPAPI secret cannot be read by another account, so the bridge would start, fail to decrypt its token, and be restarted for ever. ' +
                "Either run Protect-BridgeSecrets.ps1 as '$serviceAccount', or install the service under the account that protected them.")
        }
    }

    if (-not $TemplatesReadable) {
        $detail = if ($TemplatesError) { " ($TemplatesError)" } else { '' }
        $errors.Add("The template registry could not be read$detail. The bridge would start with nothing to push.")
    }

    $needsFfmpeg = [bool](Get-BridgeInstallProperty -Object $settings -Name 'EnableSnapshot') -or
        [bool](Get-BridgeInstallProperty -Object $settings -Name 'EnableLiveRelay')
    if ($needsFfmpeg -and -not $HasFfmpeg) {
        $warnings.Add('ffmpeg.exe was not found, so snapshots, the live relay and the black-output monitor will not work. Everything else will.')
    }

    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = @($errors); Warnings = @($warnings) }
}

function Get-BridgeStartVerdict {
    <#
        Decides whether a service that was just started is actually up.

        "Running" on its own proves nothing: a bridge that dies on a bad token
        is restarted by NSSM or Task Scheduler every few seconds, and is
        therefore Running most times you look. What separates the two is the
        log - a healthy start writes its version line once and then stops
        restarting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$State,
        [int]$StartupLinesSinceLaunch = 0,
        [switch]$SawTelegramConnection
    )
    if ($State -ne 'Running') {
        return [pscustomobject]@{ Healthy = $false; Reason = "The service is not running (state: $State). Check logs\service-stderr.log." }
    }
    if ($StartupLinesSinceLaunch -gt 1) {
        return [pscustomobject]@{ Healthy = $false; Reason = "The bridge started $StartupLinesSinceLaunch times in a few seconds, so it is crashing and being restarted. Check logs\bridge.log." }
    }
    if ($StartupLinesSinceLaunch -eq 0) {
        return [pscustomobject]@{ Healthy = $false; Reason = 'No startup line reached logs\bridge.log. The service is up but the bridge did not start.' }
    }
    if (-not $SawTelegramConnection) {
        return [pscustomobject]@{ Healthy = $true; Reason = 'The bridge started, but no Telegram connection is logged yet. Watch the log for a moment.' }
    }
    return [pscustomobject]@{ Healthy = $true; Reason = 'The bridge is running and connected to Telegram.' }
}

Export-ModuleMember -Function Get-BridgeReadinessReport, Get-BridgeStartVerdict, Get-BridgeInstallProperty
