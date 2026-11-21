function Get-WebAirOperationReference {
    param([string]$EventName, [string]$OperationId)
    if ($EventName -cne 'air_control' -or $OperationId -notmatch '\Aair-[0-9a-f]{32}\z') { return '' }
    return (Get-OperationReference -OperationId $OperationId).ToLowerInvariant()
}

function Get-WebOperationReferenceLookup {
    param([System.Collections.IDictionary]$Arguments)
    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor) -or -not (Test-Admin -ChatId $actor -UserId $actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $supplied = [string](Get-JsonProp $Arguments 'reference')
    if (-not (Test-OperationReference -Reference $supplied)) { return @{ ok = $false; error = 'operation_reference_invalid' } }
    $wanted = $supplied.Trim().ToLowerInvariant()

    # The writer logs both a diagnostic line and an air_control audit event.
    # Search bounded structured events so no free-form log text reaches Web.
    $limit = $script:ReportMaxRecords
    $records = @(Read-AuditRecords -MaxLines $limit)
    $matching = [Collections.Generic.List[object]]::new()
    $operationId = ''
    foreach ($record in $records) {
        $id = [string](Get-AuditRecordField -Record $record -Name 'operationId')
        $eventName = [string](Get-AuditRecordField -Record $record -Name 'event')
        if ((Get-WebAirOperationReference -EventName $eventName -OperationId $id) -cne $wanted) { continue }
        if ($operationId -and $operationId -ine $id) {
            return @{ ok = $true; data = @{ status = 'collision'; readLimit = $limit; truncated = ($records.Count -ge $limit); items = @() } }
        }
        $operationId = $id
        $when = Read-AuditRecordStamp -Record $record
        $action = [string](Get-AuditRecordField -Record $record -Name 'action')
        $result = [string](Get-AuditRecordField -Record $record -Name 'result')
        if (-not $when -or $action -cnotin 'SHOW', 'HIDE', 'EXIT', 'UPDATE' -or $result -cnotin 'success', 'failed', 'blocked') { continue }
        $layer = 0
        $duration = 0L
        [void][int]::TryParse([string](Get-AuditRecordField -Record $record -Name 'layer'), [ref]$layer)
        [void][long]::TryParse([string](Get-AuditRecordField -Record $record -Name 'durationMs'), [ref]$duration)
        $matching.Add(@{
                atMs = ([datetimeoffset]$when).ToUnixTimeMilliseconds()
                stationTime = ([datetimeoffset]$when).ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
                action = $action; result = $result; layer = [math]::Max(0, $layer); durationMs = [math]::Max(0L, $duration)
            })
    }
    return @{ ok = $true; data = @{
            status = $(if ($matching.Count) { 'found' } else { 'missing' })
            readLimit = $limit; truncated = ($records.Count -ge $limit -or $matching.Count -gt 20)
            items = @($matching | Sort-Object { $_.atMs } -Descending | Select-Object -First 20)
        } }
}
