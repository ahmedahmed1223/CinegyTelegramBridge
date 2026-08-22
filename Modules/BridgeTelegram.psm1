Set-StrictMode -Version Latest

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
            if ($RetryDelayMs -gt 0) { Start-Sleep -Milliseconds $RetryDelayMs }
        }
    }
}

Export-ModuleMember -Function Invoke-BridgeTelegramRequest
