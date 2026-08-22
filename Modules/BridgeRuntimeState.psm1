Set-StrictMode -Version Latest

function New-BridgeRuntimeState {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        Relay=[pscustomobject]@{
            Process=$null;ShouldRun=$false;Restarts=0;LastCheck=[datetime]::MinValue
            NotifyChatId=0L;VerifyAt=$null
        }
        Monitoring=[pscustomobject]@{
            CinegyHealthState='unknown';TelegramConnectionState='unknown'
            LastCinegyStateCheck=[datetime]::MinValue;LastCinegyStateSuccess=[datetime]::MinValue
            LastCinegyHealthCheck=[datetime]::MinValue
        }
    }
}

Export-ModuleMember -Function New-BridgeRuntimeState
