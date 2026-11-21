function Get-MojazManagementPlan {
    param([string]$BulletinId, [ValidateSet('clear', 'delete')][string]$Operation)

    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $BulletinId
    if (-not $bulletin) { return @{ ok = $false; error = 'not_found' } }
    $id = [string](Get-JsonProp $bulletin 'Id')
    $references = @($script:MojazSchedules | Where-Object { [string](Get-JsonProp $_ 'BulletinId') -eq $id })
    if ((Test-MojazOnAir -Bulletin $bulletin) -or ($references | Where-Object {
                [string](Get-JsonProp $_ 'Status') -eq 'running'
            } | Select-Object -First 1)) {
        return @{ ok = $false; error = 'bulletin_on_air' }
    }

    $rows = @(Get-JsonProp $bulletin 'Rows' | Where-Object { $null -ne $_ })
    if ($Operation -eq 'clear' -and $rows.Count -eq 0) {
        return @{ ok = $false; error = 'bulletin_empty' }
    }
    $summary = [ordered]@{
        id = $id
        operation = $Operation
        revision = [int](Get-JsonProp $bulletin 'Revision')
        name = [string](Get-JsonProp $bulletin 'Name')
        rowCount = $rows.Count
        pendingCount = @($references | Where-Object { [string](Get-JsonProp $_ 'Status') -in 'scheduled', 'queued' }).Count
        referenceCount = $references.Count
    }
    # Appointment changes are independent of the bulletin revision. Bind
    # their identities, slots and states so equal counts cannot hide swaps.
    $scheduleSnapshot = @(foreach ($entry in @($references | Sort-Object -Property Id)) {
            [ordered]@{
                id = [string](Get-JsonProp $entry 'Id')
                scheduledAt = [string](Get-JsonProp $entry 'ScheduledAt')
                status = [string](Get-JsonProp $entry 'Status')
                design = [string](Get-JsonProp $entry 'DesignKey')
                createdBy = [long](Get-JsonProp $entry 'CreatedBy')
            }
        })
    $fingerprint = ConvertTo-Json -Compress -Depth 6 -InputObject ([ordered]@{ summary = $summary; onAir = $false; references = $scheduleSnapshot })
    return @{ ok = $true; summary = $summary; fingerprint = $fingerprint }
}

function Invoke-MojazManagementCommit {
    param([string]$BulletinId, [ValidateSet('clear', 'delete')][string]$Operation, [string]$Fingerprint,
        [long]$UserId, [long]$Deadline = 0)

    $plan = Get-MojazManagementPlan -BulletinId $BulletinId -Operation $Operation
    if (-not $plan.ok -and $plan.error -eq 'bulletin_on_air') { return $plan }
    if (-not $plan.ok -or -not $Fingerprint -or $plan.fingerprint -cne $Fingerprint) {
        return @{ ok = $false; error = 'bulletin_stale' }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }

    $summary = $plan.summary
    if ($Operation -eq 'clear') {
        $candidate = Clear-MojazBulletinRows -Library $script:MojazLibrary -BulletinId $summary.id -UserId $UserId
        if (-not (Invoke-MojazEdit -Result $candidate -ChatId $UserId -Quiet)) {
            return @{ ok = $false; error = 'bulletin_save_failed' }
        }
        Add-AuditEntry (T 'mjz.clearedAudit' (Format-UserAuditActor -UserId $UserId))
        $cleared = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $summary.id
        return @{ ok = $true; data = @{ id = $summary.id; operation = $Operation; revision = [int]$cleared.Revision } }
    }

    $removal = Remove-MojazBulletin -Library $script:MojazLibrary -BulletinId $summary.id
    if (-not $removal.Success) { return @{ ok = $false; error = 'bulletin_stale' } }
    $before = @($script:MojazSchedules)
    $kept = @($before | Where-Object { [string](Get-JsonProp $_ 'BulletinId') -ne $summary.id })
    $hasReferences = $before.Count -ne $kept.Count
    # Schedules go first. A failed library save leaves the bulletin live in
    # storage and lets the same validated schedule writer restore its slots.
    if ($hasReferences -and -not (Save-MojazSchedules -Schedules $kept)) {
        return @{ ok = $false; error = 'bulletin_schedule_save_failed' }
    }
    if (-not (Save-MojazLibrary -Library $removal.Value)) {
        if ($hasReferences -and -not (Save-MojazSchedules -Schedules $before)) {
            $script:MojazSchedules = $before
            Write-BridgeLog "Could not restore the persisted appointments for bulletin '$($summary.id)' after its deletion failed." 'ERROR'
            return @{ ok = $false; error = 'bulletin_schedule_rollback_failed' }
        }
        return @{ ok = $false; error = 'bulletin_save_failed' }
    }
    $note = if ($summary.pendingCount -gt 0) { T 'mjz.withSlots' $summary.pendingCount } else { '' }
    Add-AuditEntry (T 'mjz.deletedAudit' $summary.name $note (Format-UserAuditActor -UserId $UserId))
    return @{ ok = $true; data = @{ id = $summary.id; operation = $Operation; revision = $null } }
}

function Request-MojazManagementReview {
    param([long]$ChatId, [long]$UserId, [ValidateSet('clear', 'delete')][string]$Operation)

    $id = Get-MojazSelectedId -ChatId $ChatId
    $plan = Get-MojazManagementPlan -BulletinId $id -Operation $Operation
    if (-not $plan.ok) {
        $text = if ($plan.error -eq 'bulletin_on_air') { T 'mojaz.onAirStopFirst' }
        elseif ($plan.error -eq 'bulletin_empty') { T 'reply.bulletinRowsAlreadyEmpty' }
        else { T 'reply.reviewExpired' }
        Send-TelegramMessage -ChatId $ChatId -Text $text
        return
    }
    $summary = $plan.summary
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'mojaz_management_review'; UserId = $UserId; Operation = $Operation
        BulletinId = $summary.id; Fingerprint = $plan.fingerprint
        BulletinName = $summary.name; PendingCount = $summary.pendingCount
    }
    if ($Operation -eq 'delete') {
        $warning = T 'cb.confirmBoardDelete' $summary.name $summary.rowCount
        if ($summary.pendingCount -gt 0) { $warning += (T 'cb.andCancelSlots' $summary.pendingCount) }
        $question = T 'reply.yesDeleteBulletin'
        $callback = 'mojaz:dropconfirm'
    }
    else {
        $warning = T 'reply.confirmClearRows'
        if ($summary.pendingCount -gt 0) { $warning += (T 'reply.clearKeepsBulletinSlots' $summary.pendingCount) }
        $question = T 'reply.yesClearRows'
        $callback = 'mojaz:clearconfirm'
    }
    Send-TelegramMessage -ChatId $ChatId -Text $warning -ReplyMarkup (Get-MojazConfirmKeyboard -Question $question -ConfirmData $callback)
}

function Confirm-MojazManagementReview {
    param([long]$ChatId, [long]$UserId, [ValidateSet('clear', 'delete')][string]$Operation)

    $pending = Get-PendingState -ChatId $ChatId
    if (-not $pending -or $pending.Mode -ne 'mojaz_management_review' -or [long]$pending.UserId -ne $UserId -or
        [string]$pending.Operation -cne $Operation -or [string]$pending.BulletinId -cne (Get-MojazSelectedId -ChatId $ChatId)) {
        Send-TelegramMessage -ChatId $ChatId -Text (T 'reply.reviewExpired')
        return
    }
    Clear-PendingState -ChatId $ChatId
    $result = Invoke-MojazManagementCommit -BulletinId $pending.BulletinId -Operation $Operation -Fingerprint $pending.Fingerprint -UserId $UserId
    if (-not $result.ok) {
        $text = switch ($result.error) {
            'bulletin_on_air' { T 'mojaz.onAirStopFirst' }
            'bulletin_stale' { T 'reply.reviewExpired' }
            'bulletin_schedule_save_failed' { T 'mojaz.cancelSchedulesFailed' }
            'bulletin_schedule_rollback_failed' { T 'reply.bulletinRollbackFailed' }
            default { T 'mjz.saveFailed' }
        }
        Send-TelegramMessage -ChatId $ChatId -Text $text
        return
    }
    if ($Operation -eq 'delete') {
        $note = if ([int]$pending.PendingCount -gt 0) { T 'mjz.withSlots' $pending.PendingCount } else { '' }
        Send-TelegramMessage -ChatId $ChatId -Text (T 'mjz.deleted' $pending.BulletinName $note)
        Show-MojazLibraryScreen -ChatId $ChatId -UserId $UserId
    }
    else { Show-MojazScreen -ChatId $ChatId -UserId $UserId }
}
