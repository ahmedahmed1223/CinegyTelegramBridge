function Invoke-WebRelayDestination {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline, [switch]$ApplyReview)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_timeout' }
    }

    $raw = Get-JsonProp $Arguments 'destination'
    if ($raw -isnot [string] -or -not (Test-RelayDestinationUrl -Value $raw)) {
        return @{ ok = $false; error = 'relay_invalid' }
    }
    $destination = $raw.Trim()
    $revision = [string](Get-JsonProp $Arguments 'revision')

    $status = (Get-WebRelayControlState).Data
    if ($revision -cne $status.revision) { return @{ ok = $false; error = 'relay_stale' } }
    if (-not $status.canEditDestination) { return @{ ok = $false; error = 'relay_unavailable' } }

    # The pending review stores only a keyed fingerprint of the new credential.
    $reviewed = ConvertTo-Json -Compress -InputObject @($revision, $destination)
    $fingerprint = [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData(
            $script:WebRelayReviewKey, [Text.Encoding]::UTF8.GetBytes($reviewed)))
    if (-not $ApplyReview) {
        $token = New-WebAirReview -Actor $actor -Fingerprint $fingerprint -Reviews $script:WebRelayDestinationReviews
        return @{ ok = $true; data = @{ review = $token } }
    }
    $token = [string](Get-JsonProp $Arguments 'review')
    if ($token -cnotmatch '\A[a-f0-9]{32}\z') { return @{ ok = $false; error = 'relay_invalid' } }
    $pending = Use-WebAirReview -Actor $actor -Token $token -Reviews $script:WebRelayDestinationReviews
    if (-not $pending -or $pending.Fingerprint -cne $fingerprint) { return @{ ok = $false; error = 'relay_stale' } }

    $stream = Get-LiveStreamConfig
    $previous = [string](Get-JsonProp $stream 'RtmpDestination')
    Save-Config -Path $script:ConfigPath -ReviewedRelay @{ Expected = $previous; Destination = $destination } -Deadline $Deadline
    if ($script:LastConfigSaveConflict) { return @{ ok = $false; error = 'relay_stale' } }
    if ($script:LastConfigSaveFailed) { return @{ ok = $false; error = 'relay_config_failed' } }
    Set-JsonProp $stream 'RtmpDestination' $destination
    Write-BridgeLog "User $actor updated LiveStream.RtmpDestination"
    $updated = (Get-WebRelayControlState).Data
    $updated.outcome = 'destination-saved'
    return @{ ok = $true; data = $updated }
}

function Get-ReviewedRelayConfigPlan {
    param([System.Text.Json.Nodes.JsonObject]$Document, [System.Collections.IDictionary]$Change,
        [System.Text.Json.Nodes.JsonNodeOptions]$NodeOptions)

    if ($Change.Destination -isnot [string] -or -not (Test-RelayDestinationUrl -Value $Change.Destination)) {
        return @{ Code = 'failed' }
    }
    if (-not $Document.ContainsKey('LiveStream')) { $Document['LiveStream'] = [System.Text.Json.Nodes.JsonObject]::new($NodeOptions) }
    $stream = $Document['LiveStream']
    if ($stream -isnot [System.Text.Json.Nodes.JsonObject]) { return @{ Code = 'failed' } }
    $diskValue = if ($stream['RtmpDestination']) { ConvertFrom-Json -InputObject $stream['RtmpDestination'].ToJsonString() -NoEnumerate -ErrorAction Stop }
    if ($null -eq $diskValue) { $diskValue = '' }
    if ($diskValue -isnot [string]) { return @{ Code = 'stale' } }

    $references = $script:SecretReferences
    $memoryReference = [string]$references['LiveStream.RtmpDestination']
    $diskReference = ''
    if ($diskValue -match '\Adpapi:[A-Za-z][A-Za-z0-9_.-]{0,63}\z') { $diskReference = $diskValue }
    if ($diskReference -cne $memoryReference -or (-not $diskReference -and $diskValue -cne $Change.Expected)) {
        return @{ Code = 'stale' }
    }
    $settings = $Document['Settings']
    $dpapi = $settings -is [System.Text.Json.Nodes.JsonObject] -and $settings['EnableDpapiSecrets'] -and
        $settings['EnableDpapiSecrets'].GetValueKind() -eq [System.Text.Json.JsonValueKind]::True
    if (-not $diskReference -and -not $dpapi) {
        $stream['RtmpDestination'] = [System.Text.Json.Nodes.JsonValue]::Create([string]$Change.Destination)
        return @{ Code = 'ready'; SecretOnly = $false; Secrets = $null; Reference = '' }
    }

    $secretFile = Get-Item -LiteralPath $script:SecretStorePath -Force -ErrorAction SilentlyContinue
    if ($secretFile -and ($secretFile -isnot [IO.FileInfo] -or $secretFile.Length -gt 16MB -or
            ($secretFile.Attributes -band [IO.FileAttributes]::ReparsePoint))) { return @{ Code = 'failed' } }
    if (-not $secretFile -and $references.Count) { return @{ Code = 'stale' } }
    $secrets = if ($secretFile) { Read-BridgeSecretStore -Path $script:SecretStorePath } else { @{} }

    $slot = if ($diskReference) { $diskReference.Substring(6) } else { 'LiveStream.ReviewedRtmpDestination' }
    $reference = "dpapi:$slot"
    # A shared slot must not overwrite the bot's token or ingest URL.
    foreach ($other in @($Document['BotToken'], $stream['SourceUrl'])) {
        if ($other -and $other.GetValueKind() -eq [System.Text.Json.JsonValueKind]::String -and
            (ConvertFrom-Json -InputObject $other.ToJsonString() -NoEnumerate) -ieq $reference) { return @{ Code = 'stale' } }
    }
    if ($diskReference -and (-not $secrets.ContainsKey($slot) -or $secrets[$slot] -cne $Change.Expected)) {
        return @{ Code = 'stale' }
    }
    $secrets[$slot] = $Change.Destination
    if (-not $diskReference) { $stream['RtmpDestination'] = [System.Text.Json.Nodes.JsonValue]::Create([string]$reference) }
    return @{ Code = 'ready'; SecretOnly = [bool]$diskReference; Secrets = $secrets; Reference = $reference }
}
