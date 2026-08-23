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
            return [pscustomobject]@{ Success=$true; Response=$response; Error=''; Attempts=$attempt }
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                return [pscustomobject]@{ Success=$false; Response=$null; Error=$_.Exception.Message; Attempts=$attempt }
            }
            $delay = Get-BridgeTelegramRetryDelayMs -ErrorRecord $_ -DefaultDelayMs $RetryDelayMs
            if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
    }
}

Export-ModuleMember -Function Invoke-BridgeTelegramRequest, Get-BridgeTelegramRetryDelayMs
