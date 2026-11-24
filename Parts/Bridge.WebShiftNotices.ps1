$script:WebAirEvents = [Collections.Generic.Queue[object]]::new()

function Add-WebAirEvent {
    param([string]$Id, [string]$Action, [string]$Key, [int]$Layer)
    if (-not $script:WebChannel -or -not $Key -or $Layer -le 0) { return }
    $scope = Get-TemplateNotifyScope -Key $Key
    if ($scope -notin 'all','admins') { return }
    while ($script:WebAirEvents.Count -ge 64) { $script:WebAirEvents.Dequeue() | Out-Null }
    $script:WebAirEvents.Enqueue(@{ id=$Id; action=$Action; key=$Key; layer=$Layer; at=[datetimeoffset]::UtcNow.ToUnixTimeMilliseconds(); scope=$scope })
}

function Get-WebPersonalAirNotice {
    param([long]$Actor)

    $supported = -not (Test-WebOnlyUserId -UserId $Actor)
    $muted = Test-AirNoticeMuted -UserId $Actor
    $cutoff = [datetimeoffset]::UtcNow.AddMinutes(-2).ToUnixTimeMilliseconds()
    $events = @(if (-not $muted -and $script:WebAirEvents.Count) {
        $admin = Test-Admin -ChatId $Actor -UserId $Actor
        foreach ($entry in $script:WebAirEvents) {
            if ($entry.at -lt $cutoff) { continue }
            $scope = Get-TemplateNotifyScope -Key $entry.key
            if ($scope -notin 'all','admins' -or (-not $admin -and 'admins' -in $entry.scope,$scope)) { continue }
            if ((Test-TemplateAccess -Key $entry.key -Layer $entry.layer -ChatId $Actor -UserId $Actor).Allowed) {
                @{ id=$entry.id; action=$entry.action; key=$entry.key; layer=$entry.layer; at=$entry.at }
            }
        }
    })
    return @{
        events = $events
        telegramAvailable = $supported
        muted = if ($supported) { $muted } else { $null }
    }
}

function Get-WebTemplateNoticePage {
    param([int]$Page)

    $store = Get-TemplateStore
    $keys = @((Get-JsonProp $store 'Order') | Where-Object { $_ })
    $window = Get-BridgePageWindow -ItemCount $keys.Count -Page $Page -PageSize 12
    $rules = Get-TemplateNotifyMap
    $items = @(for ($index = $window.StartIndex; $index -le $window.EndIndex; $index++) {
            $key = [string]$keys[$index]
            @{
                key = $key
                scope = if ($rules.Contains($key)) { [string]$rules[$key] } else { 'none' }
                canChange = Test-TemplateNotifyRuleKey -Key $key
            }
        })
    return @{ items = $items; page = $window.Page; pageCount = $window.PageCount; total = $keys.Count }
}

function Invoke-WebPersonalAirNotice {
    param([long]$Actor, [System.Collections.IDictionary]$Arguments, [long]$Deadline)

    $action = [string](Get-JsonProp $Arguments 'action')
    $current = Get-WebPersonalAirNotice -Actor $Actor
    if ($action -eq 'read') { return @{ ok = $true; data = $current } }
    if ($action -ne 'update') { return @{ ok = $false; error = 'notices_invalid' } }
    if (-not $current.telegramAvailable) { return @{ ok = $false; error = 'notices_no_telegram' } }

    $muted = Get-JsonProp $Arguments 'muted'
    $expected = Get-JsonProp $Arguments 'expectedMuted'
    if ($muted -isnot [bool] -or $expected -isnot [bool]) { return @{ ok = $false; error = 'notices_invalid' } }
    if ($current.muted -ne $expected) { return @{ ok = $false; error = 'notices_stale' } }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $result = Set-AirNoticeMuted -UserId $Actor -Muted $muted -IncludeSaveStatus
    if (-not $result.Saved) { return @{ ok = $false; error = 'notices_save_failed' } }
    return @{ ok = $true; data = Get-WebPersonalAirNotice -Actor $Actor }
}

function Invoke-WebTemplateNoticeRule {
    param([long]$Actor, [System.Collections.IDictionary]$Arguments, [long]$Deadline)

    if (-not (Test-Admin -ChatId $Actor -UserId $Actor)) { return @{ ok = $false; error = 'forbidden' } }
    $action = [string](Get-JsonProp $Arguments 'action')
    $page = 0
    $rawPage = Get-JsonProp $Arguments 'page'
    $invalid = @{ ok = $false; error = 'notices_invalid' }
    if ($null -ne $rawPage -and -not [int]::TryParse([string]$rawPage, [ref]$page)) { return $invalid }
    if ($action -eq 'list') { return @{ ok = $true; data = Get-WebTemplateNoticePage -Page $page } }
    if ($action -ne 'update') { return $invalid }

    $key = [string](Get-JsonProp $Arguments 'key')
    $scope = [string](Get-JsonProp $Arguments 'scope')
    $expected = [string](Get-JsonProp $Arguments 'expectedScope')
    if (-not (Test-TemplateNotifyRuleKey -Key $key) -or $scope -cnotin @('none', 'admins', 'all') -or
        $expected -cnotin @('none', 'admins', 'all')) { return $invalid }

    $store = Get-TemplateStore
    $template = Get-JsonProp (Get-JsonProp $store 'Map') $key
    if (-not $template) { return @{ ok = $false; error = 'notices_template_gone' } }
    $key = [string]$template.Key
    if ((Get-TemplateNotifyScope -Key $key) -cne $expected) {
        return @{ ok = $false; error = 'notices_stale' }
    }
    if ($Deadline -gt 0 -and [Diagnostics.Stopwatch]::GetTimestamp() -ge $Deadline) {
        return @{ ok = $false; error = 'bridge_busy' }
    }
    $result = Set-TemplateNotifyRule -Key $key -Scope $scope -IncludeSaveStatus
    if (-not $result.Saved) { return @{ ok = $false; error = 'notices_save_failed' } }
    if ($scope -cne $expected) { Write-BridgeLog "User $Actor set the on-air notice for '$key' to $scope" }
    return @{ ok = $true; data = Get-WebTemplateNoticePage -Page $page }
}

function Invoke-WebShiftNotice {
    param([System.Collections.IDictionary]$Arguments, [long]$Deadline = 0)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }

    switch ([string](Get-JsonProp $Arguments 'area')) {
        'personal' { return Invoke-WebPersonalAirNotice -Actor $actor -Arguments $Arguments -Deadline $Deadline }
        'rules' { return Invoke-WebTemplateNoticeRule -Actor $actor -Arguments $Arguments -Deadline $Deadline }
        default { return @{ ok = $false; error = 'notices_invalid' } }
    }
}
