function Format-WebShiftHistoryField {
    param([AllowEmptyString()][string]$Text, [int]$MaximumLength = 100)

    $safe = Protect-SensitiveText $Text
    if (-not $safe) { return '' }
    $safe = [regex]::Replace($safe, '(?i)https?://[^\s"''<>]+', '[link]')
    $safe = [regex]::Replace($safe,
        '(?i)\b(token|secret|password|passphrase|api[-_]?key|access[-_]?key)(\s*[=:]\s*)(?:"[^"]*"|''[^'']*''|[^\s&;,]+)', '$1$2***')
    $safe = ([regex]::Replace($safe, '[\p{Cc}\p{Cf}]', ' ')).Trim()
    if ($safe.Length -gt $MaximumLength) {
        $safe = $safe.Substring(0, (Get-SafeTextPrefixLength -Text $safe -MaximumCodeUnits $MaximumLength))
    }
    return $safe
}

function Get-WebShiftHistoryRequest {
    param([System.Collections.IDictionary]$Arguments)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }

    $action = [string](Get-JsonProp $Arguments 'action')
    $view = [string](Get-JsonProp $Arguments 'view')
    $scope = [string](Get-JsonProp $Arguments 'scope')
    if (-not $action) { $action = 'list' }
    if (-not $view) { $view = 'operations' }
    if (-not $scope) {
        if ($view -eq 'audit') { $scope = 'all' } else { $scope = 'mine' }
    }
    $invalid = @{ ok = $false; error = 'history_invalid' }
    if ($action -cnotin @('list', 'export') -or $view -cnotin @('operations', 'audit') -or
        $scope -cnotin @('mine', 'all')) { return $invalid }
    $admin = Test-Admin -ChatId $actor -UserId $actor
    if (($scope -eq 'all' -or $view -eq 'audit' -or $action -eq 'export') -and -not $admin) {
        return @{ ok = $false; error = 'forbidden' }
    }

    $operatorId = [string](Get-JsonProp $Arguments 'operatorId')
    if ($operatorId -and $scope -ne 'all') { return @{ ok = $false; error = 'forbidden' } }
    if ($operatorId) {
        $parsedId = 0L
        if (-not [long]::TryParse($operatorId, [ref]$parsedId) -or $parsedId -le 0) { return $invalid }
        $operatorId = $parsedId.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $hours = 48
    $rawHours = Get-JsonProp $Arguments 'hours'
    if ($null -ne $rawHours -and (-not [int]::TryParse([string]$rawHours, [ref]$hours) -or
            $hours -notin 24, 48, 72, 168)) { return $invalid }
    $page = 0
    $rawPage = Get-JsonProp $Arguments 'page'
    if ($null -ne $rawPage -and -not [int]::TryParse([string]$rawPage, [ref]$page)) { return $invalid }
    $day = [string](Get-JsonProp $Arguments 'day')
    $date = [datetime]::MinValue
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($day -and (-not [datetime]::TryParseExact($day, 'yyyy-MM-dd', $culture, [Globalization.DateTimeStyles]::None, [ref]$date) -or
            $date.Date -eq [datetime]::MaxValue.Date)) { return $invalid }

    $target = [string](Get-JsonProp $Arguments 'target')
    $kind = [string](Get-JsonProp $Arguments 'kind')
    $result = [string](Get-JsonProp $Arguments 'result')
    if ($target.Length -gt 100 -or ($kind -and ($view -ne 'audit' -or $kind -cnotmatch '^[a-z][a-z0-9_]{0,39}$')) -or
        ($result -and $result -cnotin @('success', 'failed', 'blocked', 'problems'))) { return $invalid }

    $now = Get-Date
    $from = if ($day) { $date.Date } else { $now.AddHours(-$hours) }
    $to = if ($day) { $date.Date.AddDays(1).AddTicks(-1) } else { $now }
    return @{ ok = $true; actor = $actor; action = $action; view = $view; scope = $scope; operatorId = $operatorId
        page = $page; from = $from; to = $to; target = $target; kind = $kind; result = $result }
}

function ConvertTo-WebShiftHistoryItem {
    param($Record, [bool]$ShowOperator)

    $reference = [string]$Record.OperationId
    if ($reference -cnotmatch '^[A-Za-z0-9_-]{1,80}$') { $reference = '' }
    $at = [datetimeoffset]([datetime]$Record.When)
    $operatorId = if ($ShowOperator -and [string]$Record.UserId -match '^[1-9][0-9]{0,18}$') { [string]$Record.UserId } else { '' }
    return [ordered]@{
        reference = $reference
        event = [string]$Record.Event
        atMs = $at.ToUnixTimeMilliseconds()
        stationTime = $at.ToString('yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture)
        action = Format-WebShiftHistoryField -Text ([string]$Record.Action) -MaximumLength 40
        target = Format-WebShiftHistoryField -Text ([string]$Record.Target)
        result = Format-WebShiftHistoryField -Text ([string]$Record.Result) -MaximumLength 40
        layer = [int]$Record.Layer
        durationMs = [long]$Record.DurationMs
        operatorId = $operatorId
        operatorName = if ($operatorId) { Format-WebShiftHistoryField -Text (Get-AuditOperatorName -UserId $operatorId) -MaximumLength 80 } else { '' }
    }
}

function Get-WebShiftHistoryOption {
    param([object[]]$Records, [string]$Property, [int]$Limit = 12)

    $labels = @(foreach ($record in $Records) {
            $value = [string](Get-JsonProp $record $Property)
            if ($Property -eq 'Target') { $value = Format-WebShiftHistoryField -Text $value }
            if ($value) { $value }
        })
    $groups = @($labels | Group-Object | Sort-Object -Property Count, Name -Descending)
    return @{
        items = @($groups | Select-Object -First $Limit | ForEach-Object {
                $label = if ($Property -eq 'UserId') {
                    Format-WebShiftHistoryField -Text (Get-AuditOperatorName -UserId $_.Name) -MaximumLength 80
                }
                else { Format-WebShiftHistoryField -Text $_.Name }
                $value = if ($Property -eq 'UserId') { $_.Name } else { $label }
                if ($value) { @{ value = [string]$value; label = [string]$label; count = [int]$_.Count } }
            })
        hidden = [math]::Max(0, $groups.Count - $Limit)
    }
}

function Protect-WebShiftCsvCell {
    param([AllowEmptyString()][string]$Text)

    # Quoting with ConvertTo-Csv handles commas and quotes. Spreadsheet apps
    # still evaluate formula-like content inside those quoted cells.
    if ($Text -match '^\s*[=+@-]') { return "'$Text" }
    return $Text
}

function Get-WebShiftHistoryExport {
    param([object[]]$Records, [bool]$Truncated, [bool]$ShowOperator)

    $limit = 250
    $rows = @(foreach ($record in @($Records | Select-Object -First $limit)) {
            $item = ConvertTo-WebShiftHistoryItem -Record $record -ShowOperator $ShowOperator
            [pscustomobject][ordered]@{
                (T 'rep.col.time')       = $item.stationTime
                (T 'rep.col.operation')  = Protect-WebShiftCsvCell $item.action
                (T 'rep.col.template')   = Protect-WebShiftCsvCell $item.target
                (T 'rep.col.layer')      = $item.layer
                (T 'rep.col.result')     = Protect-WebShiftCsvCell $item.result
                (T 'rep.col.operator')   = Protect-WebShiftCsvCell $item.operatorName
                (T 'rep.col.operatorId') = $item.operatorId
                'Event'                 = $item.event
                'Reference'             = Protect-WebShiftCsvCell $item.reference
            }
        })
    $csv = ''
    if ($rows.Count -gt 0) { $csv = ($rows | ConvertTo-Csv -NoTypeInformation -UseCulture) -join "`r`n" }
    return @{ csv = $csv; count = $rows.Count; truncated = ($Truncated -or $Records.Count -gt $limit) }
}

function Invoke-WebShiftHistory {
    param([System.Collections.IDictionary]$Arguments)

    $request = Get-WebShiftHistoryRequest -Arguments $Arguments
    if (-not $request.ok) { return $request }
    $eventName = if ($request.view -eq 'operations') { 'air_control' } else { '' }
    $window = Get-ReportRecords -From $request.from -To $request.to -EventName $eventName
    $showOperator = $request.scope -eq 'all'
    $scoped = @($window.Records | Where-Object {
            ($showOperator -or [string]$_.UserId -eq [string]$request.actor) -and
            [string]$_.Event -cmatch '^[a-z][a-z0-9_]{0,39}$'
        })
    $ordered = @($scoped | Where-Object {
            (-not $request.operatorId -or [string]$_.UserId -eq $request.operatorId) -and
            (-not $request.target -or (Format-WebShiftHistoryField -Text ([string]$_.Target)) -ieq $request.target) -and
            (-not $request.kind -or [string]$_.Event -eq $request.kind) -and
            (-not $request.result -or [string]$_.Result -eq $request.result -or
                ($request.result -eq 'problems' -and [string]$_.Result -in 'failed', 'blocked'))
        } | Sort-Object -Property When, OperationId -Descending)
    if ($request.action -eq 'export') {
        return @{ ok = $true; data = Get-WebShiftHistoryExport -Records $ordered -Truncated $window.Truncated -ShowOperator $showOperator }
    }

    $page = Get-BridgePageWindow -ItemCount $ordered.Count -Page $request.page -PageSize 20
    $items = @(for ($index = $page.StartIndex; $index -le $page.EndIndex; $index++) {
            ConvertTo-WebShiftHistoryItem -Record $ordered[$index] -ShowOperator $showOperator
        })
    $targets = Get-WebShiftHistoryOption -Records $scoped -Property Target
    $operators = if ($showOperator) {
        Get-WebShiftHistoryOption -Records @($scoped | Where-Object { [string]$_.UserId -match '^[1-9][0-9]{0,18}$' }) -Property UserId
    }
    else { @{ items = @(); hidden = 0 } }
    $kinds = if ($request.view -eq 'audit') { Get-WebShiftHistoryOption -Records $scoped -Property Event } else { @{ items = @() } }
    return @{ ok = $true; data = @{
            items = $items
            page = $page.Page
            pageCount = $page.PageCount
            total = $ordered.Count
            truncated = [bool]$window.Truncated
            stationTimeZone = [TimeZoneInfo]::Local.Id
            targets = $targets.items
            operators = $operators.items
            kinds = $kinds.items
            hiddenTargets = $targets.hidden
            hiddenOperators = $operators.hidden
        } }
}
