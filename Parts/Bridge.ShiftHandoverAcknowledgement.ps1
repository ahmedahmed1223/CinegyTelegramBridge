#requires -Version 7

$script:ShiftHandoverReferenceKey = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)

function Get-ShiftHandoverPeriod {
    param([long]$Minute, [int]$Hours)

    $through = [datetimeoffset]::FromUnixTimeSeconds($Minute * 60L)
    return @{
        from = $through.AddHours(-$Hours)
        through = $through
        key = "$Minute.$Hours"
    }
}

function Get-ShiftHandoverReferenceProof {
    param([long]$Actor, [string]$PeriodKey)

    $payload = [Text.Encoding]::UTF8.GetBytes("$Actor/${PeriodKey}")
    return [Convert]::ToHexString([Security.Cryptography.HMACSHA256]::HashData(
            $script:ShiftHandoverReferenceKey, $payload)).Substring(0, 24)
}

function Format-ShiftHandoverTimestamp {
    param([datetimeoffset]$At)

    return $At.ToLocalTime().ToString('yyyy-MM-dd HH:mm zzz', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-ShiftHandoverAuditEntries {
    param([long]$Actor, [object[]]$Records)

    foreach ($record in $Records) {
        if ((Get-AuditRecordField $record 'event') -cne 'handover_ack' -or (Get-AuditRecordField $record 'result') -cne 'success' -or
            (Get-AuditRecordField $record 'userId') -ne [string]$Actor) { continue }
        $stamp = Read-AuditRecordStamp -Record $record
        if ($null -eq $stamp) { continue }
        $target = [string](Get-AuditRecordField $record 'target')
        if ($target -cmatch '^([1-9][0-9]{6,8})\.([1-9][0-9]{0,2})$') {
            $period = Get-ShiftHandoverPeriod -Minute ([long]$Matches[1]) -Hours ([int]$Matches[2])
            @{
                key = $target
                from = Format-ShiftHandoverTimestamp -At $period.from
                through = Format-ShiftHandoverTimestamp -At $period.through
                recordedAt = Format-ShiftHandoverTimestamp -At ([datetimeoffset]$stamp)
            }
        }
    }
}

function Get-ShiftHandoverView {
    param([long]$Actor, [datetimeoffset]$Now = (Get-Date))

    $hours = Get-SettingInt 'MissedEventsHours' 1
    $minute = [long][math]::Floor($Now.ToUnixTimeSeconds() / 60.0)
    $period = Get-ShiftHandoverPeriod -Minute $minute -Hours $hours
    $recent = $null
    $reference = $null
    if (Get-Setting 'EnableShiftHandover') {
        $proof = Get-ShiftHandoverReferenceProof -Actor $Actor -PeriodKey $period.key
        $reference = "$($period.key).$proof"
        $recent = Get-ShiftHandoverAuditEntries -Actor $Actor -Records @(Read-AuditRecords -MaxLines 1500) | Select-Object -Last 1
    }
    return @{
        period = $period
        public = @{
            reference = $reference
            from = Format-ShiftHandoverTimestamp -At $period.from
            through = Format-ShiftHandoverTimestamp -At $period.through
            recent = $recent
        }
    }
}

function Add-ShiftHandoverAcknowledgement {
    param([long]$Actor, [long]$ChatId, [string]$Reference, [long]$Deadline = 0, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)

    if ($Actor -le 0 -or -not (Test-Authorized -ChatId $ChatId -UserId $Actor)) { return @{ error = 'forbidden' } }
    if (-not (Get-Setting 'EnableShiftHandover')) { return @{ error = 'handover_disabled' } }
    if ($Reference -cnotmatch '^([1-9][0-9]{6,8})\.([1-9][0-9]{0,2})\.([0-9A-F]{24})$') { return @{ error = 'handover_stale' } }
    $minute, $hours, $supplied = [long]$Matches[1], [int]$Matches[2], [string]$Matches[3]
    $end = $minute * 60L
    if ($end -gt $Now.ToUnixTimeSeconds() -or $end -le $Now.ToUnixTimeSeconds() - 600 -or
        $hours -ne (Get-SettingInt 'MissedEventsHours' 1)) { return @{ error = 'handover_stale' } }
    $period = Get-ShiftHandoverPeriod -Minute $minute -Hours $hours
    $expected = Get-ShiftHandoverReferenceProof -Actor $Actor -PeriodKey $period.key
    if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            [Text.Encoding]::ASCII.GetBytes($supplied), [Text.Encoding]::ASCII.GetBytes($expected))) {
        return @{ error = 'handover_stale' }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ error = 'bridge_busy' } }

    try { $raw = @(Read-AuditRecords -MaxLines 1500 -RequireCompleteRead) }
    catch { return @{ error = 'handover_unavailable' } }

    $prior = Get-ShiftHandoverAuditEntries -Actor $Actor -Records $raw | Where-Object key -ceq $period.key | Select-Object -Last 1
    if ($prior) { return @{ data = $prior } }
    # A capped tail may omit an earlier acknowledgement of this very period.
    # The first retained entry must reach the reference's earliest write time.
    if ($raw.Count -ge 1500) {
        $oldest = Read-AuditRecordStamp -Record $raw[0]
        if (-not $oldest -or $oldest.ToUniversalTime() -ge $period.through.UtcDateTime) {
            return @{ error = 'handover_unavailable' }
        }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) { return @{ error = 'bridge_busy' } }

    $message = T 'cb.handoverAudit' (Format-UserAuditActor -UserId $Actor)
    $operationId = "handover-$Actor-$($period.key)"
    $recordedAt = [datetimeoffset]::UtcNow
    if (-not (Write-AuditRecord -OperationId $operationId -EventName 'handover_ack' -Result success -UserId $Actor `
                -Target $period.key -Message $message -At $recordedAt -ReturnStatus)) {
        return @{ error = 'handover_unavailable' }
    }
    Add-AuditEntry -Message $message -InMemoryOnly
    return @{ data = @{
            key = $period.key
            from = Format-ShiftHandoverTimestamp -At $period.from
            through = Format-ShiftHandoverTimestamp -At $period.through
            recordedAt = Format-ShiftHandoverTimestamp -At $recordedAt
        } }
}

function Invoke-WebShiftHandoverAcknowledgement {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor)) {
        return @{ ok = $false; error = 'forbidden' }
    }
    $result = Add-ShiftHandoverAcknowledgement -Actor $actor -ChatId $actor -Reference ([string](Get-JsonProp $Arguments 'reference')) -Deadline $Deadline
    if ($result.ContainsKey('error')) { return @{ ok = $false; error = $result.error } }
    return @{ ok = $true; data = $result.data }
}
