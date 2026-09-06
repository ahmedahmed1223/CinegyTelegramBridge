Set-StrictMode -Version Latest

function Get-BridgeTelegramRetryDelayMs {
    <#
        How long to wait before retrying a failed Telegram call.

        Telegram answers a flood-limited call with HTTP 429 and a
        parameters.retry_after in *seconds*, and it means it: retrying sooner
        is refused again and deepens the limit. Broadcasting to every
        administrator, or a long status split into several messages, is
        exactly the shape that trips it - and a dropped admin alert is the one
        message that most needed to arrive.

        Anything else keeps the caller's fixed delay.
    #>
    [CmdletBinding()]
    param(
        [object]$ErrorRecord,
        [ValidateRange(0, 5000)][int]$DefaultDelayMs = 400,
        [ValidateRange(1000, 300000)][int]$MaximumDelayMs = 60000
    )
    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { $status = 0 }
    if ($status -ne 429) { return $DefaultDelayMs }

    # PowerShell 7 exposes the response body on the record's ErrorDetails.
    $body = ''
    try { $body = [string]$ErrorRecord.ErrorDetails.Message } catch { $body = '' }
    $seconds = 0
    if ($body) {
        $match = [regex]::Match($body, '"retry_after"\s*:\s*(?<s>\d+)')
        if ($match.Success) { $seconds = [int]$match.Groups['s'].Value }
    }
    if ($seconds -le 0) { return $DefaultDelayMs }
    return [Math]::Min($seconds * 1000, $MaximumDelayMs)
}

function Invoke-BridgeTelegramRequest {
    [CmdletBinding(DefaultParameterSetName='Body')]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][ValidateSet('Get','Post')][string]$Method,
        [Parameter(ParameterSetName='Body')]$Body,
        [Parameter(ParameterSetName='Form')]$Form,
        [string]$ContentType = '',
        [Parameter(Mandatory)][ValidateRange(1,300)][int]$TimeoutSec,
        [ValidateRange(1,5)][int]$MaxAttempts = 1,
        [ValidateRange(0,5000)][int]$RetryDelayMs = 400
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $request = @{ Uri=$Uri; Method=$Method; TimeoutSec=$TimeoutSec }
            if ($PSCmdlet.ParameterSetName -eq 'Form' -and $null -ne $Form) { $request.Form=$Form }
            elseif ($null -ne $Body) { $request.Body=$Body }
            if (-not [string]::IsNullOrWhiteSpace($ContentType)) { $request.ContentType=$ContentType }
            $response = Invoke-RestMethod @request
            return [pscustomobject]@{ Success=$true; Response=$response; Error=''; Attempts=$attempt; StatusCode=200; RetryAfterMs=0 }
        }
        catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
            if ($status -eq 429) {
                $delay = Get-BridgeTelegramRetryDelayMs -ErrorRecord $_ -DefaultDelayMs $RetryDelayMs -MaximumDelayMs 300000
                return [pscustomobject]@{ Success=$false; Response=$null; Error=$_.Exception.Message; Attempts=$attempt; StatusCode=429; RetryAfterMs=$delay }
            }
            if ($attempt -ge $MaxAttempts) {
                return [pscustomobject]@{ Success=$false; Response=$null; Error=$_.Exception.Message; Attempts=$attempt; StatusCode=$status; RetryAfterMs=0 }
            }
            $delay = Get-BridgeTelegramRetryDelayMs -ErrorRecord $_ -DefaultDelayMs $RetryDelayMs
            if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
    }
}

function Start-BridgeTelegramRequestWorker {
    <# A private runspace owns only one HTTP request. It never receives bridge
       state or Cinegy functions, so a stalled upload cannot hold the air clock. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Request)
    $pipeline = [powershell]::Create()
    try {
        $pipeline.AddScript({
            param($transportModule, $requestArguments)
            Import-Module $transportModule -ErrorAction Stop
            Invoke-BridgeTelegramRequest @requestArguments
        }).AddArgument((Join-Path $PSScriptRoot 'BridgeTelegram.psm1')).AddArgument($Request) | Out-Null
        return @{ Pipeline = $pipeline; Handle = $pipeline.BeginInvoke(); Disposed = $false }
    }
    catch { $pipeline.Dispose(); throw }
}

function Receive-BridgeTelegramRequestWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Worker)
    if ($Worker.Disposed -or -not $Worker.Handle.IsCompleted) { return $null }
    try {
        $results = @($Worker.Pipeline.EndInvoke($Worker.Handle))
        if ($results.Count -eq 0) { throw 'Deferred Telegram transport returned no result.' }
        return $results[-1]
    }
    catch {
        return [pscustomobject]@{ Success = $false; Response = $null; Error = 'Deferred Telegram transport failed.'; StatusCode = 0; RetryAfterMs = 0 }
    }
    finally { $Worker.Pipeline.Dispose(); $Worker.Disposed = $true }
}

function Stop-BridgeTelegramRequestWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Worker)
    if ($Worker.Disposed) { return }
    try { $Worker.Pipeline.Stop() }
    finally { $Worker.Pipeline.Dispose(); $Worker.Disposed = $true }
}

Export-ModuleMember -Function Invoke-BridgeTelegramRequest, Get-BridgeTelegramRetryDelayMs, Start-BridgeTelegramRequestWorker, Receive-BridgeTelegramRequestWorker, Stop-BridgeTelegramRequestWorker
