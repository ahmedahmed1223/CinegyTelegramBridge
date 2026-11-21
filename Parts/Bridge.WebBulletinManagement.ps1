$script:WebBulletinManagementReviews = @{}

function Invoke-WebBulletinManagement {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }
    if (-not (Test-MojazAvailable)) { return @{ ok = $false; error = 'content_disabled' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    if ($action -eq 'review') {
        $operation = [string](Get-JsonProp $Arguments 'operation')
        $id = [string](Get-JsonProp $Arguments 'id')
        $revision = 0
        if ($operation -cnotin @('clear', 'delete') -or -not $id -or
            -not [int]::TryParse([string](Get-JsonProp $Arguments 'revision'), [ref]$revision)) {
            return @{ ok = $false; error = 'bulletin_invalid' }
        }
        $plan = Get-MojazManagementPlan -BulletinId $id -Operation $operation
        if (-not $plan.ok) { return $plan }
        if ($plan.summary.revision -ne $revision) { return @{ ok = $false; error = 'bulletin_stale' } }

        $token = New-WebAirReview -Actor $actor -Fingerprint $plan.fingerprint -Reviews $script:WebBulletinManagementReviews
        $script:WebBulletinManagementReviews[$actor].BulletinId = $plan.summary.id
        $script:WebBulletinManagementReviews[$actor].Operation = $operation
        $plan.summary.review = $token
        return @{ ok = $true; data = $plan.summary }
    }
    if ($action -ne 'confirm') { return @{ ok = $false; error = 'bulletin_invalid' } }
    $review = [string](Get-JsonProp $Arguments 'review')
    if (-not $review) { return @{ ok = $false; error = 'bulletin_stale' } }
    $pending = Use-WebAirReview -Actor $actor -Token $review -Reviews $script:WebBulletinManagementReviews
    if (-not $pending) { return @{ ok = $false; error = 'bulletin_stale' } }
    return Invoke-MojazManagementCommit -BulletinId $pending.BulletinId -Operation $pending.Operation `
        -Fingerprint $pending.Fingerprint -UserId $actor -Deadline $Deadline
}
