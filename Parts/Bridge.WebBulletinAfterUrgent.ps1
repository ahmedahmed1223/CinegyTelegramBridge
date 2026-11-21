$script:WebBulletinAfterUrgentReviews = @{}

function Get-WebBulletinAfterUrgentPlan {
    param([long]$Actor, [string]$Id, [int]$Revision)

    $bulletin = Get-MojazBulletin -Library $script:MojazLibrary -BulletinId $Id
    if (-not $bulletin) { return @{ ok = $false; error = 'not_found' } }
    if ([int](Get-JsonProp $bulletin 'Revision') -ne $Revision) { return @{ ok = $false; error = 'bulletin_stale' } }
    if ((Get-Setting 'MaintenanceMode') -or (Test-MaintenanceWindowActive) -or
        -not (Test-WebBulletinPlayoutAccess -Bulletin $bulletin -Actor $Actor)) {
        return @{ ok = $false; error = 'bulletin_playback_unavailable' }
    }
    if (Test-MojazOnAir -Bulletin $bulletin) { return @{ ok = $false; error = 'bulletin_on_air' } }
    $clock = Get-SystemClockStatus
    if (-not $clock.Success) { return @{ ok = $false; error = 'bulletin_schedule_clock' } }

    $urgent = Get-MojazUrgentTemplate
    $urgentLayer = [int](Get-JsonProp $urgent 'Layer')
    $urgentKey = [string](Get-JsonProp $urgent 'Key')
    $record = $script:OnAir[$urgentLayer]
    if ($urgentLayer -le 0 -or [string](Get-JsonProp $record 'Key') -ne $urgentKey -or -not $urgentKey) {
        return @{ ok = $false; error = 'bulletin_urgent_gone' }
    }
    $activeId = ([string](Get-JsonProp $record 'ActiveId')).Trim().Trim('{', '}').ToLowerInvariant()
    $observed = Read-MojazLayerStamp -Layer $urgentLayer
    if ($observed -eq 'empty') { return @{ ok = $false; error = 'bulletin_urgent_gone' } }
    if (-not $activeId -or -not (Get-JsonProp $record 'ActiveIdConfirmed') -or $observed -cne "active:$activeId") {
        return @{ ok = $false; error = 'bulletin_urgent_unconfirmed' }
    }

    $target = Get-MojazPlaybackTemplate -Bulletin $bulletin
    $resolved = Get-MojazResolvedRunSnapshot -Bulletin $bulletin
    if (-not $resolved.Success -or -not $resolved.Value) { return @{ ok = $false; error = 'bulletin_playback_empty' } }
    $rowCount = @(Get-JsonProp $resolved.Value 'Rows' | Where-Object { $null -ne $_ }).Count
    if ($rowCount -eq 0) { return @{ ok = $false; error = 'bulletin_playback_empty' } }
    $id = [string](Get-JsonProp $bulletin 'Id')
    $summary = @{
        id = $id; revision = $Revision; name = [string](Get-JsonProp $bulletin 'Name'); rowCount = $rowCount; urgentLayer = $urgentLayer
    }
    $fingerprint = ConvertTo-Json -Compress -InputObject ([ordered]@{
            id = $id; revision = $Revision; rowCount = $rowCount
            design = [string](Get-MojazBulletinDesignKey -Bulletin $bulletin)
            designLayer = [int](Get-JsonProp $target 'Layer'); designPath = [string](Get-JsonProp $target 'Path')
            urgentLayer = $urgentLayer; urgent = $observed; urgentAt = [string](Get-JsonProp $record 'At')
        })
    return @{ ok = $true; data = $summary; fingerprint = $fingerprint }
}

function Invoke-WebBulletinAfterUrgent {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'review') {
        $id = [string](Get-JsonProp $Arguments 'id')
        $revision = 0
        if (-not $id -or -not [int]::TryParse([string](Get-JsonProp $Arguments 'revision'), [ref]$revision)) {
            return @{ ok = $false; error = 'bulletin_invalid' }
        }
        $plan = Get-WebBulletinAfterUrgentPlan -Actor $actor -Id $id -Revision $revision
        if (-not $plan.ok) { return $plan }
        $review = New-WebAirReview -Actor $actor -Fingerprint $plan.fingerprint -Reviews $script:WebBulletinAfterUrgentReviews
        $script:WebBulletinAfterUrgentReviews[$actor].Id = $plan.data.id
        $script:WebBulletinAfterUrgentReviews[$actor].Revision = $revision
        $plan.data.review = $review
        return @{ ok = $true; data = $plan.data }
    }
    if ($action -ne 'confirm') { return @{ ok = $false; error = 'bulletin_invalid' } }
    $stale = @{ ok = $false; error = 'bulletin_stale' }
    $review = [string](Get-JsonProp $Arguments 'review')
    if (-not $review) { return $stale }
    $pending = Use-WebAirReview -Actor $actor -Token $review -Reviews $script:WebBulletinAfterUrgentReviews
    if (-not $pending) { return $stale }
    $plan = Get-WebBulletinAfterUrgentPlan -Actor $actor -Id $pending.Id -Revision $pending.Revision
    if (-not $plan.ok) { return $plan }
    if ($plan.fingerprint -cne $pending.Fingerprint) { return $stale }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }

    $now = [datetimeoffset]::Now
    $alreadyQueued = @(Get-MojazBulletinSchedules -BulletinId $pending.Id | Where-Object {
            $slot = [datetimeoffset]::MinValue
            [datetimeoffset]::TryParse([string](Get-JsonProp $_ 'ScheduledAt'), [ref]$slot) -and $slot -le $now -and
            (Test-MojazScheduleAccess -Entry $_)
        }).Count -gt 0
    if (-not $alreadyQueued) {
        # The common queue holds this due appointment while the urgent or
        # another bulletin is on air, and rechecks the Web actor at runtime.
        if (-not (Add-MojazSchedule -BulletinId $pending.Id -ScheduledAt $now -ChatId $actor -UserId $actor -FromWeb)) {
            return @{ ok = $false; error = 'bulletin_schedule_save_failed' }
        }
        Add-AuditEntry (T 'mjp.heldUntilAfterUrgent' $plan.data.name (Format-UserAuditActor -UserId $actor))
    }
    return @{ ok = $true; data = @{ id = $pending.Id; alreadyQueued = $alreadyQueued } }
}
