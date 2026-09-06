#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Reports read audit.jsonl - the same permanent record /digest and /who
    already read - rather than keeping a second log to drift out of sync
    with it.

    Everything here is bounded on purpose. The bridge is one sequential
    loop, so a scan that runs long is a freeze of the whole bridge,
    emergency hide included.
#>

# The report scan ceiling. Announced in the report when reached, because a
# truncated report that does not say so reads as a complete one.
$script:ReportMaxRecords = 5000

function Get-ReportsMenuKeyboard {
    return @{ inline_keyboard = @(
            , @((New-Button '🖼 البنرات' 'rep:banners:today'), (New-Button '📰 الأخبار' 'rep:news:today'))
            , @((New-Button '📑 الموجزات' 'rep:mojaz:today'))
            , @((New-Button '👥 تقرير العمل' 'rep:work:today'))
            , @((New-Button '🏠 القائمة' 'menu:main'))
        )
    }
}

function Get-ReportPeriodKeyboard {
    <# The period row doubles as the refresh control: tapping the current
       period re-runs it. #>
    param([Parameter(Mandatory)][ValidateSet('banners', 'news', 'mojaz', 'work')][string]$Kind, [string]$Period = 'today')
    # The period being read is marked. Four identical buttons over a report
    # that does not repeat its own window left the operator guessing which one
    # they had pressed.
    $mark = { param($Value, $Label) if ($Value -eq $Period) { "• $Label" } else { $Label } }
    return @{ inline_keyboard = @(
            , @((New-Button (& $mark 'today' 'اليوم') "rep:${Kind}:today"), (New-Button (& $mark 'yesterday' 'أمس') "rep:${Kind}:yesterday"))
            , @((New-Button (& $mark 'week' '7 أيام') "rep:${Kind}:week"), (New-Button (& $mark 'month' '30 يومًا') "rep:${Kind}:month"))
            $(if ($Kind -ne 'work') { , @((New-Button '⬇️ تحميل الملف' "repdl:${Kind}:${Period}")) })
            , @((New-Button '📊 التقارير' 'menu:reports'), (New-Button '🏠 القائمة' 'menu:main'))
        )
    }
}

function Show-ReportsMenu {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $scope = if (Test-Admin -ChatId $ChatId -UserId $UserId) { 'كل المشغّلين' } else { 'عملياتك أنت' }
    Send-TelegramMessage -ChatId $ChatId -ReplyMarkup (Get-ReportsMenuKeyboard) -Text @"
📊 التقارير
━━━━━━━━━━━━━━
النطاق: $scope

🖼 البنرات — ماذا ظهر، بأي نص، ومتى اختفى
📰 الأخبار — تعديلات الشريط اليومي وحجم كل تعديل
📑 الموجزات — أي نشرة شُغّلت، بكم صفًّا، ومن شغّلها
👥 تقرير العمل — حصيلة كل مشغّل من عمليات الهواء
"@
}

function Show-Report {
    <# One entry point for both sections. Operators see their own work;
       administrators and the owner see everyone's, because the banner report
       names who did what. #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [Parameter(Mandatory)][ValidateSet('banners', 'news', 'mojaz', 'work')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $onlyUser = if (Test-Admin -ChatId $ChatId -UserId $UserId) { 0 } else { $UserId }
    $markup = Get-ReportPeriodKeyboard -Kind $Kind -Period $Period
    # Both reports are rows of columns, so both gain from a real table.
    # Tried first and never depended on: an API without sendRichMessage, or a
    # shape it will not take, falls through to exactly the text this screen
    # has always sent.
    $blocks = switch ($Kind) {
        'news' { Get-NewsReportBlocks -Period $Period -OnlyUserId $onlyUser }
        'mojaz' { Get-MojazReportBlocks -Period $Period -OnlyUserId $onlyUser }
        'work' { Get-WorkReportBlocks -Period $Period -OnlyUserId $onlyUser }
        default { Get-BannerReportBlocks -Period $Period -OnlyUserId $onlyUser }
    }
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $blocks -ReplyMarkup $markup) { return }
    $text = switch ($Kind) {
        'news' { Get-NewsReportText -Period $Period -OnlyUserId $onlyUser }
        'mojaz' { Get-MojazReportText -Period $Period -OnlyUserId $onlyUser }
        'work' { Get-WorkReportText -Period $Period -OnlyUserId $onlyUser }
        default { Get-BannerReportText -Period $Period -OnlyUserId $onlyUser }
    }
    Send-TelegramPagedText -ChatId $ChatId -Text $text -ReplyMarkup $markup
}

function Get-ReportPeriod {
    <# Named windows an operator actually asks for at a handover, resolved to
       a start time and an Arabic label. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period)
    $now = Get-Date
    switch ($Period) {
        'today' { return @{ From = $now.Date; To = $now; Label = 'اليوم' } }
        'yesterday' { return @{ From = $now.Date.AddDays(-1); To = $now.Date.AddTicks(-1); Label = 'أمس' } }
        'week' { return @{ From = $now.Date.AddDays(-6); To = $now; Label = 'آخر 7 أيام' } }
        default { return @{ From = $now.Date.AddDays(-29); To = $now; Label = 'آخر 30 يومًا' } }
    }
}

function Get-ReportRecords {
    <# Audit records inside a window, normalised and bounded.

       Returns the records plus a Truncated flag, so every caller can say so
       out loud instead of quietly presenting a partial answer. #>
    param([Parameter(Mandatory)][datetime]$From, [datetime]$To = (Get-Date), [string]$EventName = '')
    $raw = @(Read-AuditRecords -MaxLines $script:ReportMaxRecords)
    $records = foreach ($record in $raw) {
        if ($EventName -and (Get-AuditRecordField $record 'event') -ne $EventName) { continue }
        $at = Read-AuditRecordStamp -Record $record
        if (-not $at -or $at -lt $From -or $at -gt $To) { continue }
        $count = 0
        [void][int]::TryParse((Get-AuditRecordField $record 'count'), [ref]$count)
        $layer = 0
        [void][int]::TryParse((Get-AuditRecordField $record 'layer'), [ref]$layer)
        $duration = 0L
        [void][long]::TryParse((Get-AuditRecordField $record 'durationMs'), [ref]$duration)
        [pscustomobject]@{
            When   = $at
            Action = (Get-AuditRecordField $record 'action')
            Result = (Get-AuditRecordField $record 'result')
            Target = (Get-AuditRecordField $record 'target')
            UserId = (Get-AuditRecordField $record 'userId')
            Values = (Get-AuditRecordField $record 'values')
            Count  = $count
            Layer  = $layer
            # Both are written by Write-AuditRecord and were dropped here, so a
            # report that pairs a start with its end - the bulletin one - had
            # nothing to pair on and matched nothing.
            OperationId = (Get-AuditRecordField $record 'operationId')
            DurationMs  = $duration
        }
    }
    return @{
        Records   = @($records)
        Truncated = ($raw.Count -ge $script:ReportMaxRecords)
    }
}

function Get-WorkReportData {
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $window = Get-ReportPeriod -Period $Period
    $scan = Get-ReportRecords -From $window.From -To $window.To -EventName 'air_control'
    $records = @($scan.Records | Where-Object { $_.UserId })
    if ($OnlyUserId -gt 0) { $records = @($records | Where-Object { $_.UserId -eq [string]$OnlyUserId }) }
    $people = foreach ($group in @($records | Group-Object -Property UserId | Sort-Object Count -Descending)) {
        $items = @($group.Group)
        # Blocked is counted apart from failed on purpose. They were one number
        # and they are two different conversations: blocked is a person being
        # refused (wrong permission, maintenance window), failed is the engine
        # not doing what it was told. Merged, a shift full of refusals looked
        # exactly like a shift full of Cinegy errors.
        $shows = @($items | Where-Object { $_.Action -eq 'SHOW' -and $_.Result -eq 'success' }).Count
        $lastAt = @($items | Sort-Object When -Descending | Select-Object -First 1).When
        $topTarget = ''
        $named = @($items | Where-Object { $_.Target })
        if ($named.Count -gt 0) {
            $topTarget = [string](@($named | Group-Object -Property Target | Sort-Object Count -Descending)[0].Name)
        }
        [pscustomobject]@{
            UserId    = [string]$group.Name
            Total     = $items.Count
            Success   = @($items | Where-Object { $_.Result -eq 'success' }).Count
            Blocked   = @($items | Where-Object { $_.Result -eq 'blocked' }).Count
            Failed    = @($items | Where-Object { $_.Result -eq 'failed' }).Count
            OnAir     = $shows
            LastAt    = $lastAt
            TopTarget = $topTarget
        }
    }
    $people = @($people)
    # Measure-Object over an empty set returns no object at all, and reading
    # .Sum off that throws under Set-StrictMode -Version Latest. It took the
    # bulletin report down on a quiet day once already (see the same guard
    # below); a quiet day is exactly when a report is opened to check.
    $totals = if ($people.Count -eq 0) {
        [pscustomobject]@{ Operators = 0; Total = 0; Success = 0; Blocked = 0; Failed = 0; OnAir = 0 }
    }
    else {
        [pscustomobject]@{
            Operators = $people.Count
            Total     = [int](@($people | Measure-Object -Property Total -Sum).Sum)
            Success   = [int](@($people | Measure-Object -Property Success -Sum).Sum)
            Blocked   = [int](@($people | Measure-Object -Property Blocked -Sum).Sum)
            Failed    = [int](@($people | Measure-Object -Property Failed -Sum).Sum)
            OnAir     = [int](@($people | Measure-Object -Property OnAir -Sum).Sum)
        }
    }
    return @{ Label = $window.Label; People = $people; Totals = $totals; Truncated = $scan.Truncated }
}

function Get-WorkReportProblemSuffix {
    <# Names only the problems that actually happened. A line reading
       "🚫 0 · ⚠️ 0" on every clean shift trains the reader to skip the very
       symbols that matter on the shift that is not clean. #>
    param([int]$Blocked = 0, [int]$Failed = 0)
    $parts = @()
    if ($Blocked -gt 0) { $parts += "🚫 $Blocked مرفوضة" }
    if ($Failed -gt 0) { $parts += "⚠️ $Failed فاشلة" }
    if ($parts.Count -eq 0) { return '' }
    return ' · ' + ($parts -join ' · ')
}

function Get-WorkReportDetailLine {
    <# The second line under an operator: what actually reached the screen,
       what they worked on most, and when they were last active - the three
       questions a supervisor asks after "how many". #>
    param([int]$OnAir = 0, [string]$TopTarget = '', $LastAt = $null)
    $parts = @("🔴 $OnAir على الهواء")
    if ($TopTarget) { $parts += "الأكثر: $TopTarget" }
    if ($LastAt -is [datetime]) { $parts += "آخر نشاط $($LastAt.ToString('HH:mm'))" }
    return ($parts -join ' · ')
}

function Get-WorkReportText {
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-WorkReportData -Period $Period -OnlyUserId $OnlyUserId
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("👥 تقرير العمل — $($data.Label)")
    if ($data.People.Count -eq 0) { $lines.Add('لا توجد عمليات هواء مسجلة في هذه الفترة.'); return ($lines -join "`n") }
    foreach ($person in $data.People) {
        $name = Get-AuditOperatorName -UserId $person.UserId
        $lines.Add("• ${name}: $($person.Total) عملية · ✅ $($person.Success)$(Get-WorkReportProblemSuffix -Blocked $person.Blocked -Failed $person.Failed)")
        $lines.Add("   $(Get-WorkReportDetailLine -OnAir $person.OnAir -TopTarget $person.TopTarget -LastAt $person.LastAt)")
    }
    if ($data.People.Count -gt 1) {
        $t = $data.Totals
        $lines.Add('')
        $lines.Add("الإجمالي: $($t.Total) عملية · 🔴 $($t.OnAir) على الهواء · ✅ $($t.Success)$(Get-WorkReportProblemSuffix -Blocked $t.Blocked -Failed $t.Failed) · $($t.Operators) مشغّلين")
    }
    $note = Get-ReportTruncationNote -Truncated ([bool]$data.Truncated)
    if ($note) { $lines.Add(''); $lines.Add("⚠️ $note") }
    return ($lines -join "`n")
}

function Get-WorkReportBlocks {
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-WorkReportData -Period $Period -OnlyUserId $OnlyUserId
    $blocks = @(@{ type = 'heading'; text = "👥 تقرير العمل — $($data.Label)"; size = 3 })
    if ($data.People.Count -eq 0) { return $blocks + @(@{ type = 'paragraph'; text = 'لا توجد عمليات هواء مسجلة في هذه الفترة.' }) }
    $cells = @(, @(
            @{ text = 'المشغّل'; is_header = $true }
            @{ text = 'العمليات'; is_header = $true }
            @{ text = 'على الهواء'; is_header = $true }
            @{ text = 'مرفوضة'; is_header = $true }
            @{ text = 'فاشلة'; is_header = $true }
            @{ text = 'الأكثر'; is_header = $true }
            @{ text = 'آخر نشاط'; is_header = $true }
        ))
    foreach ($person in $data.People) {
        $last = if ($person.LastAt -is [datetime]) { $person.LastAt.ToString('MM-dd HH:mm') } else { '—' }
        $cells += , @(
            @{ text = (Get-AuditOperatorName -UserId $person.UserId) }
            @{ text = [string]$person.Total }
            @{ text = [string]$person.OnAir }
            @{ text = [string]$person.Blocked }
            @{ text = [string]$person.Failed }
            @{ text = $(if ($person.TopTarget) { [string]$person.TopTarget } else { '—' }) }
            @{ text = $last }
        )
    }
    if ($data.People.Count -gt 1) {
        $t = $data.Totals
        $cells += , @(
            @{ text = 'الإجمالي'; is_header = $true }
            @{ text = [string]$t.Total; is_header = $true }
            @{ text = [string]$t.OnAir; is_header = $true }
            @{ text = [string]$t.Blocked; is_header = $true }
            @{ text = [string]$t.Failed; is_header = $true }
            @{ text = '—'; is_header = $true }
            @{ text = '—'; is_header = $true }
        )
    }
    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    return $blocks
}

function Get-NewsReportDays {
    <# The aggregation both renderers share, so the text screen and the
       downloadable file can never disagree about the numbers. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $window = Get-ReportPeriod -Period $Period
    $scan = Get-ReportRecords -From $window.From -To $window.To -EventName 'news_publish'
    $records = @($scan.Records)
    if ($OnlyUserId -gt 0) { $records = @($records | Where-Object { $_.UserId -eq [string]$OnlyUserId }) }

    # Summed by hand rather than with Measure-Object: on an empty set it
    # returns no object at all, and reading .Sum off that throws under
    # StrictMode - which is exactly the "nothing published today" case.
    $days = foreach ($day in @($records | Group-Object -Property { $_.When.Date } | Sort-Object Name)) {
        $dayRecords = @($day.Group)
        $ordered = @($dayRecords | Sort-Object { [datetime]$_.When })
        $stamps = @($ordered | ForEach-Object { [datetime]$_.When })
        $counts = @($ordered | ForEach-Object { [int]$_.Count })
        [pscustomobject]@{
            Date      = ([datetime]$dayRecords[0].When).Date
            Publishes = $dayRecords.Count
            # The ticker is one running strip that gets edited, not a series
            # of separate bulletins, so every publish records how many items
            # the strip held at that moment. Adding those up counted the same
            # headlines once per edit: a strip of 14 edited three times was
            # reported as 40 items. What the day actually ended with is the
            # last reading.
            Items     = $(if ($counts.Count -gt 0) { $counts[-1] } else { 0 })
            Counts    = $counts
            # When the ticker was first and last touched that day. "3
            # publishes" does not say whether they were spread across the
            # bulletin or all fired in one minute at handover.
            First     = $stamps[0]
            Last      = $stamps[-1]
            Tally     = (Get-OperatorTally -Records $dayRecords)
        }
    }
    $days = @($days)

    # Days with nothing published are filled in rather than left out.
    # Group-Object only produces days that have records, so a week in which
    # Wednesday carried no bulletin at all simply had no Wednesday row - and
    # the gap is the single thing a supervisor opens this report to find.
    $byDate = @{}
    foreach ($day in $days) { $byDate[$day.Date.ToString('yyyy-MM-dd')] = $day }
    $filled = [System.Collections.Generic.List[object]]::new()
    $cursor = ([datetime]$window.From).Date
    $lastDay = ([datetime]$window.To).Date
    while ($cursor -le $lastDay) {
        $key = $cursor.ToString('yyyy-MM-dd')
        if ($byDate.ContainsKey($key)) { $filled.Add($byDate[$key]) }
        else {
            $filled.Add([pscustomobject]@{
                    Date = $cursor; Publishes = 0; Items = 0; Counts = @()
                    First = $null; Last = $null
                    Tally = @{ Breakdown = ''; Single = '' }
                })
        }
        $cursor = $cursor.AddDays(1)
    }
    $days = @($filled)

    $published = @($days | Where-Object { $_.Publishes -gt 0 })
    # On air at the end of the window, for the same reason: summing a running
    # strip's readings is not a total of anything.
    $totalItems = $(if ($published.Count -gt 0) { [int]$published[-1].Items } else { 0 })
    return @{
        Label      = $window.Label
        Days       = $days
        Publishes  = $records.Count
        Items      = $totalItems
        # The two facts a ticker report exists to answer, and neither was
        # here: when it was last touched, and how many days went by untouched.
        LastPublishedAt = $(if ($published.Count -gt 0) { $published[-1].Last } else { $null })
        SilentDays = @($days | Where-Object { $_.Publishes -eq 0 }).Count
        Truncated  = $scan.Truncated
    }
}

function Get-BannerReportData {
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $window = Get-ReportPeriod -Period $Period
    $scan = Get-ReportRecords -From $window.From -To $window.To -EventName 'air_control'
    $sessions = @(Get-BannerSessions -Records @($scan.Records))
    if ($OnlyUserId -gt 0) { $sessions = @($sessions | Where-Object { $_.UserId -eq [string]$OnlyUserId }) }
    return @{
        Label     = $window.Label
        Sessions  = $sessions
        Operators = @($sessions | Group-Object -Property UserId).Count
        Truncated = $scan.Truncated
    }
}

function Get-MojazReportData {
    <#
        Every bulletin run in the window, paired from its own audit trail.

        A run writes START when the scene is up and END when it leaves, under
        one operation id - so a run still on air has a start and no end, and
        says so rather than being dropped or counted as finished.
    #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $window = Get-ReportPeriod -Period $Period
    $scan = Get-ReportRecords -From $window.From -To $window.To -EventName 'mojaz_run'
    $byOperation = [ordered]@{}
    foreach ($record in @($scan.Records)) {
        $id = [string]$record.OperationId
        if ([string]::IsNullOrWhiteSpace($id)) { $id = "$([string]$record.Target)|$(([datetime]$record.When).ToString('o'))" }
        if (-not $byOperation.Contains($id)) {
            $byOperation[$id] = [pscustomobject]@{
                Name = [string]$record.Target; UserId = [string]$record.UserId; Rows = [int]$record.Count
                StartedAt = $null; EndedAt = $null; Kind = [string]$record.Values; DurationMs = 0L
            }
        }
        $run = $byOperation[$id]
        if ([string]$record.Action -eq 'START') {
            $run.StartedAt = $record.When
            $run.Rows = [int]$record.Count
            $run.UserId = [string]$record.UserId
            $run.Kind = [string]$record.Values
        }
        else {
            $run.EndedAt = $record.When
            $run.DurationMs = [long]$record.DurationMs
            if (-not $run.Name) { $run.Name = [string]$record.Target }
        }
    }
    $runs = @(@($byOperation.Values) | Where-Object { $_.StartedAt -or $_.EndedAt } |
            Sort-Object { if ($_.StartedAt) { $_.StartedAt } else { $_.EndedAt } })
    if ($OnlyUserId -gt 0) { $runs = @($runs | Where-Object { $_.UserId -eq [string]$OnlyUserId }) }
    return @{
        Label     = $window.Label
        Runs      = $runs
        # Measure-Object over an empty collection returns an object with no
        # Sum at all, and StrictMode throws on reading it - which is what the
        # report did on any period with no bulletin in it, meaning every
        # quiet day.
        Rows      = [int]$(if ($runs.Count -gt 0) { (@($runs) | Measure-Object -Property Rows -Sum).Sum } else { 0 })
        Operators = @($runs | Group-Object -Property UserId).Count
        Scheduled = @($runs | Where-Object { $_.Kind -eq 'scheduled' }).Count
        Truncated = $scan.Truncated
    }
}

function Get-MojazRunDuration {
    <# How long the bulletin held the screen. The recorded elapsed time is
       preferred over the gap between the two stamps: it is the playback's own
       monotonic clock, and it is the number the newsroom asks about. #>
    param([Parameter(Mandatory)]$Run)
    if (-not $Run.EndedAt) { return '🔴 على الهواء' }
    $seconds = if ([long]$Run.DurationMs -gt 0) { [int][math]::Round([long]$Run.DurationMs / 1000) }
    elseif ($Run.StartedAt) { [int][math]::Round((([datetime]$Run.EndedAt) - ([datetime]$Run.StartedAt)).TotalSeconds) }
    else { 0 }
    return (Format-DurationSeconds -Seconds ([math]::Max(0, $seconds)))
}

function Get-MojazReportBlocks {
    <# Four columns, like the banner report and for the same reason: Telegram
       splits a table's width evenly, so a fifth column costs the bulletin name
       the room it needs to be recognised. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-MojazReportData -Period $Period -OnlyUserId $OnlyUserId
    $runs = @($data.Runs)

    $blocks = @(@{ type = 'heading'; text = "📑 تقرير الموجزات — $($data.Label)"; size = 3 })
    if ($runs.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لم يُشغَّل أي موجز في هذه الفترة.' }
        return $blocks
    }

    $cells = @(, @(
            @{ text = 'الموجز'; is_header = $true }
            @{ text = 'المشغّل'; is_header = $true }
            @{ text = 'البداية'; is_header = $true }
            @{ text = 'المدة'; is_header = $true }
        ))
    foreach ($run in $runs) {
        $started = if ($run.StartedAt) { ([datetime]$run.StartedAt).ToString('HH:mm') } else { '—' }
        $who = Get-AuditOperatorName -UserId ([string]$run.UserId)
        # The row count rides on the name: it is what tells two runs of the
        # same bulletin apart, and it does not deserve a column of its own.
        $mark = if ($run.Kind -eq 'scheduled') { '🕒 ' } else { '' }
        $cells += , @(
            @{ text = "$mark$([string]$run.Name) · $([int]$run.Rows) صف" }
            @{ text = $(if ($who) { $who } else { '—' }) }
            @{ text = $started }
            @{ text = (Get-MojazRunDuration -Run $run) }
        )
    }

    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $summary = "الإجمالي: $($runs.Count) تشغيلًا · $([int]$data.Rows) صفًّا · $($data.Operators) مشغّلين"
    if ([int]$data.Scheduled -gt 0) { $summary += " · $([int]$data.Scheduled) بالجدولة 🕒" }
    $blocks += @{ type = 'paragraph'; text = $summary }
    if ($data.Truncated) {
        $blocks += @{ type = 'paragraph'; text = "⚠️ عُرض أحدث $script:ReportMaxRecords سجل فقط؛ اختر مدة أقصر لتقرير كامل." }
    }
    return $blocks
}

function Get-MojazReportText {
    <# The plain fallback, for an API that will not take the rich blocks. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-MojazReportData -Period $Period -OnlyUserId $OnlyUserId
    $runs = @($data.Runs)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("📑 تقرير الموجزات — $($data.Label)")
    $lines.Add('━━━━━━━━━━━━━━')
    if ($runs.Count -eq 0) {
        $lines.Add('لم يُشغَّل أي موجز في هذه الفترة.')
        return ($lines -join "`n")
    }
    foreach ($run in $runs) {
        $started = if ($run.StartedAt) { ([datetime]$run.StartedAt).ToString('HH:mm') } else { '—' }
        $who = Get-AuditOperatorName -UserId ([string]$run.UserId)
        $mark = if ($run.Kind -eq 'scheduled') { '🕒 ' } else { '▶️ ' }
        $lines.Add("$mark$started · $([string]$run.Name) · $([int]$run.Rows) صف · $(Get-MojazRunDuration -Run $run)")
        if ($who) { $lines.Add("   المشغّل: $who") }
    }
    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("الإجمالي: $($runs.Count) تشغيلًا · $([int]$data.Rows) صفًّا")
    if ($data.Truncated) { $lines.Add("⚠️ عُرض أحدث $script:ReportMaxRecords سجل فقط.") }
    return ($lines -join "`n")
}

function Get-NewsCountRange {
    <# Where the strip sat across the day: '12–18', or a single number when
       it never moved. Two numbers and a dash hold what a ten-step trail was
       spending a whole column to say. #>
    param([AllowNull()][object[]]$Counts)
    $list = @($Counts | ForEach-Object { [int]$_ })
    if ($list.Count -eq 0) { return '—' }
    $low = ($list | Measure-Object -Minimum).Minimum
    $high = ($list | Measure-Object -Maximum).Maximum
    if ($low -eq $high) { return [string]$low }
    return "$low–$high"
}

function Get-NewsDayDetailBlocks {
    <#
        The per-day detail, for the collapsible block under the table.

        This is where the ten-edit day goes. A column cannot hold ten
        readings on a phone - Telegram divides a table's width evenly, so a
        sixth column gets a sixth of the screen, which is the same mistake as
        a row of six buttons - but a block under it has the whole width and
        can spend a line per day.
    #>
    param([Parameter(Mandatory)][object[]]$Days)
    $blocks = @()
    foreach ($day in @($Days)) {
        if ([int]$day.Publishes -eq 0) { continue }
        $who = if ($day.Tally.Breakdown) { [string]$day.Tally.Breakdown }
        elseif ($day.Tally.Single) { [string]$day.Tally.Single }
        else { '' }
        $span = if ($day.First -and $day.Last -and $day.First -ne $day.Last) {
            "$(([datetime]$day.First).ToString('HH:mm')) ← $(([datetime]$day.Last).ToString('HH:mm'))"
        }
        elseif ($day.Last) { ([datetime]$day.Last).ToString('HH:mm') }
        else { '' }
        $head = "$($day.Date.ToString('MM/dd')) $(Get-ArabicWeekdayShort -Date $day.Date)"
        $parts = @("🕒 $span")
        if ($who) { $parts += "👤 $who" }
        $blocks += @{ type = 'paragraph'; text = "$head — $($parts -join ' · ')" }
        $blocks += @{ type = 'paragraph'; text = (Get-NewsEditTrail -Counts $day.Counts -Max 24) }
    }
    return $blocks
}

function Get-NewsReportBlocks {
    <#
        The news report: a narrow table anyone can scan, and the detail
        folded underneath it.

        Telegram divides a table's width evenly between its columns, so the
        six-column version gave each of them a sixth of a phone screen - the
        same mistake as a row of six buttons, and the reason the news list
        moved its headline out of the buttons in 6.9.3. An editor who touches
        the strip ten times a day made that unreadable rather than merely
        tight.

        Four columns, therefore, all of them short and of predictable width:
        the day, how many edits, what stayed on air, and the range the strip
        moved through. The readings themselves, the working span and the
        operators go into a details block, where the width is the whole
        message.
    #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-NewsReportDays -Period $Period -OnlyUserId $OnlyUserId
    $days = @($data.Days)

    $blocks = @(@{ type = 'heading'; text = "📰 تقرير الأخبار — $($data.Label)"; size = 3 })
    # Days are filled in for silent ones now, so the window always has rows;
    # what makes it empty is that none of them carried an edit.
    if ([int]$data.Publishes -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لم يُنشر شريط أخبار في هذه الفترة.' }
        return $blocks
    }

    $cells = @(, @(
            @{ text = 'اليوم'; is_header = $true }
            @{ text = 'تعديلات'; is_header = $true }
            @{ text = 'على الهواء'; is_header = $true }
            @{ text = 'المدى'; is_header = $true }
        ))
    foreach ($day in $days) {
        $label = "$($day.Date.ToString('MM/dd')) $(Get-ArabicWeekdayShort -Date $day.Date)"
        # A silent day says so across the row rather than showing zeros that
        # read like a rendering fault.
        if ([int]$day.Publishes -eq 0) {
            $cells += , @(@{ text = $label }, @{ text = '—' }, @{ text = '—' }, @{ text = 'بلا تعديل' })
            continue
        }
        $cells += , @(
            @{ text = $label }
            @{ text = [string]$day.Publishes }
            @{ text = [string]$day.Items }
            @{ text = (Get-NewsCountRange -Counts $day.Counts) }
        )
    }

    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $blocks += @{ type = 'paragraph'; text = "الإجمالي: $($data.Publishes) تعديلًا · على الهواء $($data.Items) خبرًا" }
    foreach ($line in @(Get-NewsReportHighlights -Data $data)) {
        $blocks += @{ type = 'paragraph'; text = $line }
    }
    $detail = @(Get-NewsDayDetailBlocks -Days $days)
    if ($detail.Count -gt 0) {
        $blocks += @{ type = 'details'; summary = '🔍 تفاصيل كل يوم'; blocks = $detail }
    }
    if ($data.Truncated) {
        $blocks += @{ type = 'paragraph'; text = "⚠️ عُرض أحدث $script:ReportMaxRecords سجل فقط؛ اختر مدة أقصر لتقرير كامل." }
    }
    return $blocks
}

function Get-NewsEditTrail {
    <#
        How big each edit was, as the strip's item count after every one of
        them: '12 ← 15 ← 14'.

        A count of edits does not say whether the day was one strip written
        once and nudged twice, or a strip rebuilt from nothing three times.
        The numbers themselves show both the direction and the size, and the
        last of them is what stayed on air.

        Read right to left with the rest of the screen, so the arrow points
        the way the eye travels and the newest reading sits at the end.
    #>
    param([AllowNull()][object[]]$Counts, [int]$Max = 6)
    $list = @($Counts)
    if ($list.Count -eq 0) { return '—' }
    if ($list.Count -eq 1) { return [string]$list[0] }
    $shown = $list
    $prefix = ''
    if ($list.Count -gt $Max) { $shown = $list[($list.Count - $Max)..($list.Count - 1)]; $prefix = '… ← ' }
    return $prefix + (($shown | ForEach-Object { [string]$_ }) -join ' ← ')
}

function Get-ArabicWeekdayShort {
    <# The day name, because '08/27' does not tell a supervisor whether the
       silent day was a Friday. #>
    param([Parameter(Mandatory)][datetime]$Date)
    return @('أحد', 'إثنين', 'ثلاثاء', 'أربعاء', 'خميس', 'جمعة', 'سبت')[[int]$Date.DayOfWeek]
}

function Get-NewsReportHighlights {
    <#
        The two sentences this report exists to produce and never did: how
        long the ticker has been sitting untouched, and how many days in the
        window carried no bulletin at all.

        A count of publishes answers neither. A ticker last written six hours
        ago is stale copy on air right now, and that is not visible anywhere
        in a table of totals.
    #>
    param([Parameter(Mandatory)][hashtable]$Data, [datetime]$Now = (Get-Date))
    $lines = @()
    if ($Data.LastPublishedAt) {
        $ago = $Now - ([datetime]$Data.LastPublishedAt)
        $since = if ($ago.TotalMinutes -lt 60) { "$([int]$ago.TotalMinutes) دقيقة" }
        elseif ($ago.TotalHours -lt 24) { "$([int]$ago.TotalHours) ساعة" }
        else { "$([int]$ago.TotalDays) يومًا" }
        $lines += "🕒 آخر نشرة: $(([datetime]$Data.LastPublishedAt).ToString('MM/dd HH:mm')) — منذ $since"
    }
    else { $lines += '🕒 لم تُنشر أي نشرة في هذه الفترة.' }
    if ([int]$Data.SilentDays -gt 0) {
        $lines += "🔇 أيام بلا نشرة: $($Data.SilentDays)"
    }
    return $lines
}

function Get-NewsReportText {
    <# What the ticker did: how many publishes, how many items, and by whom -
       per day, because "94 items this week" hides that one person carried
       six of the seven days. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-NewsReportDays -Period $Period -OnlyUserId $OnlyUserId

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("📰 تقرير الأخبار — $($data.Label)")
    $lines.Add('━━━━━━━━━━━━━━')
    if ([int]$data.Publishes -eq 0) {
        $lines.Add('لم يُنشر شريط أخبار في هذه الفترة.')
        return ($lines -join "`n")
    }

    foreach ($day in @($data.Days)) {
        $lines.Add("• $($day.Date.ToString('yyyy/MM/dd')) — $($day.Publishes) تعديلًا · على الهواء $($day.Items) · $(Get-NewsEditTrail -Counts $day.Counts)")
        if ($day.Tally.Breakdown) { $lines.Add("   ↳ $($day.Tally.Breakdown)") }
        elseif ($day.Tally.Single) { $lines.Add("   ↳ $($day.Tally.Single)") }
    }

    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("الإجمالي: $($data.Publishes) تعديلًا · على الهواء $($data.Items) خبرًا")
    if ($data.Truncated) { $lines.Add("⚠️ عُرض أحدث $script:ReportMaxRecords سجل فقط؛ اختر مدة أقصر لتقرير كامل.") }
    return ($lines -join "`n")
}

function Get-BannerSessions {
    <# Pairs each SHOW with whatever took it off air.

       There is no "banner session" in the audit; it is derived. A session ends
       at the first HIDE, EXIT, or replacing SHOW on the same layer. One that
       never ends is reported as still on air rather than given a guessed
       duration. #>
    param([object[]]$Records = @())
    $ordered = @(@($Records) | Where-Object { $_.Action -in @('SHOW', 'HIDE', 'EXIT') -and $_.Result -eq 'success' } |
            Sort-Object When)
    $open = @{}
    $sessions = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $ordered) {
        $layer = [int]$record.Layer
        if ($record.Action -eq 'SHOW') {
            # A replacing SHOW closes whatever this layer was already showing.
            if ($open.ContainsKey($layer)) {
                $previous = $open[$layer]
                $previous.EndedAt = $record.When
                $previous.EndedBy = 'استبدال'
                $sessions.Add($previous)
            }
            $open[$layer] = [pscustomobject]@{
                Target = $record.Target; Layer = $layer; UserId = $record.UserId
                Values = $record.Values; StartedAt = $record.When; EndedAt = $null; EndedBy = ''
            }
            continue
        }
        if ($open.ContainsKey($layer)) {
            $session = $open[$layer]
            $session.EndedAt = $record.When
            $session.EndedBy = if ($record.Action -eq 'EXIT') { 'خروج' } else { 'إخفاء' }
            $sessions.Add($session)
            [void]$open.Remove($layer)
        }
    }
    foreach ($layer in @($open.Keys)) { $sessions.Add($open[$layer]) }
    return @($sessions | Sort-Object StartedAt)
}

function Get-BannerReportBlocks {
    <#
        The banner report as rich blocks: a heading, a real table, a total.

        The text version below lines its columns up with spaces and leading
        emoji, which a proportional font on a phone does not line up at all -
        every row wraps differently and the report reads as a list rather than
        a table. Telegram lays this one out itself.

        The banner copy stays out of the table on purpose. It is a whole
        sentence of on-air text, and a column wide enough for it squeezes the
        other four into nothing; it goes underneath its own row instead, the
        way the text version already shows it.
    #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-BannerReportData -Period $Period -OnlyUserId $OnlyUserId
    $sessions = @($data.Sessions)

    $blocks = @(@{ type = 'heading'; text = "🖼 تقرير البنرات — $($data.Label)"; size = 3 })
    if ($sessions.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لم يُعرض أي بنر في هذه الفترة.' }
        return $blocks
    }

    # Four columns, not five. Telegram splits a table's width evenly, so the
    # layer - a single digit - was taking as much of a phone screen as the
    # banner name. It rides on the name instead.
    $cells = @(, @(
            @{ text = 'البنر'; is_header = $true }
            @{ text = 'المشغّل'; is_header = $true }
            @{ text = 'الوقت'; is_header = $true }
            @{ text = 'المدة'; is_header = $true }
        ))
    foreach ($session in $sessions) {
        $start = ([datetime]$session.StartedAt).ToString('HH:mm')
        if ($session.EndedAt) {
            $minutes = [int][math]::Round((([datetime]$session.EndedAt) - ([datetime]$session.StartedAt)).TotalMinutes)
            $span = "$minutes د"
        }
        else { $span = '🔴 على الهواء' }
        $who = Get-AuditOperatorName -UserId ([string]$session.UserId)
        $cells += , @(
            @{ text = "$([string]$session.Target) · ط$([string]$session.Layer)" }
            @{ text = $(if ($who) { $who } else { '—' }) }
            @{ text = $start }
            @{ text = $span }
        )
    }

    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $blocks += @{ type = 'paragraph'; text = "الإجمالي: $($sessions.Count) بنرًا · $($data.Operators) مشغّلين" }
    # The copy that actually reached the screen is what an operator
    # recognises a banner by, and no column in a four-column table is wide
    # enough for a sentence. It goes underneath, where the width is the
    # whole message.
    $copy = @(foreach ($session in $sessions) {
            if (-not $session.Values) { continue }
            @{ type = 'paragraph'; text = "$(([datetime]$session.StartedAt).ToString('HH:mm')) · $([string]$session.Target) — $([string]$session.Values)" }
        })
    if ($copy.Count -gt 0) {
        $blocks += @{ type = 'details'; summary = "📝 نصوص البنرات ($($copy.Count))"; blocks = $copy }
    }
    if ($data.Truncated) {
        $blocks += @{ type = 'paragraph'; text = "⚠️ عُرض أحدث $script:ReportMaxRecords سجل فقط؛ اختر مدة أقصر لتقرير كامل." }
    }
    return $blocks
}

function Get-BannerReportText {
    <# Every banner that went up in the window: its copy, who ran it, and how
       long it stayed. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-BannerReportData -Period $Period -OnlyUserId $OnlyUserId
    $sessions = @($data.Sessions)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("🖼 تقرير البنرات — $($data.Label)")
    $lines.Add('━━━━━━━━━━━━━━')
    if ($sessions.Count -eq 0) {
        $lines.Add('لم يُعرض أي بنر في هذه الفترة.')
        return ($lines -join "`n")
    }

    foreach ($session in $sessions) {
        $who = Get-AuditOperatorName -UserId ([string]$session.UserId)
        $start = ([datetime]$session.StartedAt).ToString('HH:mm')
        if ($session.EndedAt) {
            $minutes = [int][math]::Round((([datetime]$session.EndedAt) - ([datetime]$session.StartedAt)).TotalMinutes)
            $span = "$start ← $(([datetime]$session.EndedAt).ToString('HH:mm')) · $minutes دقيقة"
            $icon = '✅'
        }
        else {
            $span = "$start ← ما زال على الهواء"
            $icon = '🔴'
        }
        $lines.Add("$icon $span")
        $detail = "   «$($session.Target)» على الطبقة $($session.Layer)"
        if ($who) { $detail += " — $who" }
        $lines.Add($detail)
        if ($session.Values) { $lines.Add("   📝 $($session.Values)") }
        else { $lines.Add('   📝 النص غير مسجَّل لهذه العملية') }
    }

    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("الإجمالي: $($sessions.Count) بنرًا · $($data.Operators) مشغّلين")
    if ($data.Truncated) { $lines.Add("⚠️ عُرض أحدث $script:ReportMaxRecords سجل فقط؛ اختر مدة أقصر لتقرير كامل.") }
    return ($lines -join "`n")
}

function ConvertTo-HtmlText {
    <# Banner copy and template keys are operator input and go straight into
       the document, so they are escaped before anything else touches them. #>
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-ReportTruncationNote {
    param([bool]$Truncated)
    if (-not $Truncated) { return '' }
    return "عُرض أحدث $script:ReportMaxRecords سجل فقط؛ اختر مدة أقصر للحصول على تقرير كامل."
}

function Get-ReportHtmlDocument {
    <# A self-contained RTL page: inline CSS, nothing fetched from anywhere.
       The playout machine may have no internet, and a report that renders as
       a broken page is worse than no report.

       @media print is the whole PDF story: the viewer prints the page from
       their own browser - correctly shaped Arabic included - instead of the
       bridge depending on a PDF library that cannot lay Arabic out. #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$Note = '')
    $generated = (Get-Date).ToString('yyyy/MM/dd HH:mm')
    $noteHtml = if ($Note) { '<p class="note">' + (ConvertTo-HtmlText $Note) + '</p>' } else { '' }
    $head = @'
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: light; }
  body { margin: 0; padding: 24px; background: #f6f7f9; color: #16191d;
         font-family: "Segoe UI", Tahoma, "Noto Naskh Arabic", "Traditional Arabic", sans-serif;
         font-size: 16px; line-height: 1.7; }
  .sheet { max-width: 840px; margin: 0 auto; background: #fff; border-radius: 10px;
           padding: 28px 32px; box-shadow: 0 1px 3px rgba(0,0,0,.12); }
  h1 { font-size: 22px; margin: 0 0 4px; }
  .meta { color: #5d646d; font-size: 13px; margin: 0 0 20px; }
  .note { background: #fff6e5; border-inline-start: 4px solid #e0a03a; padding: 10px 14px;
          border-radius: 6px; font-size: 14px; }
  .row { border-block-end: 1px solid #eceef1; padding: 12px 0; break-inside: avoid; }
  .row:last-child { border-block-end: 0; }
  .head { font-weight: 600; }
  .sub { color: #5d646d; font-size: 14px; }
  .copy { background: #f3f5f7; border-radius: 6px; padding: 8px 12px; margin-top: 6px;
          font-size: 14px; white-space: pre-wrap; word-break: break-word; }
  .live { color: #c0392b; font-weight: 600; }
  .totals { margin-top: 22px; padding-top: 14px; border-top: 2px solid #16191d; font-weight: 600; }
  @media print {
    body { background: #fff; padding: 0; font-size: 12pt; }
    .sheet { box-shadow: none; max-width: none; padding: 0; }
  }
</style>
'@
    $safeTitle = ConvertTo-HtmlText $Title
    return @"
$head<title>$safeTitle</title>
</head>
<body>
<div class="sheet">
<h1>$safeTitle</h1>
<p class="meta">أُنشئ في $generated · جسر Cinegy Telegram $($script:BridgeVersion)</p>
$noteHtml
$Body
</div>
</body>
</html>
"@
}

function Get-BannerReportHtml {
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-BannerReportData -Period $Period -OnlyUserId $OnlyUserId
    $sessions = @($data.Sessions)
    $body = [System.Collections.Generic.List[string]]::new()
    if ($sessions.Count -eq 0) { $body.Add('<p>لم يُعرض أي بنر في هذه الفترة.</p>') }
    foreach ($session in $sessions) {
        $who = Get-AuditOperatorName -UserId ([string]$session.UserId)
        $start = ([datetime]$session.StartedAt).ToString('yyyy/MM/dd HH:mm')
        if ($session.EndedAt) {
            $minutes = [int][math]::Round((([datetime]$session.EndedAt) - ([datetime]$session.StartedAt)).TotalMinutes)
            $span = "$start &#8592; $(([datetime]$session.EndedAt).ToString('HH:mm')) &middot; $minutes دقيقة"
        }
        else { $span = '<span class="live">' + $start + ' &#8592; ما زال على الهواء</span>' }
        $sub = '&laquo;' + (ConvertTo-HtmlText ([string]$session.Target)) + "&raquo; &middot; الطبقة $($session.Layer)"
        if ($who) { $sub += ' &middot; ' + (ConvertTo-HtmlText $who) }
        $copy = if ($session.Values) { ConvertTo-HtmlText ([string]$session.Values) } else { 'النص غير مسجَّل لهذه العملية' }
        $body.Add('<div class="row"><div class="head">' + $span + '</div><div class="sub">' + $sub + '</div><div class="copy">' + $copy + '</div></div>')
    }
    $body.Add('<p class="totals">' + "الإجمالي: $($sessions.Count) بنرًا &middot; $($data.Operators) مشغّلين" + '</p>')
    return Get-ReportHtmlDocument -Title "تقرير البنرات — $($data.Label)" -Body ($body -join "`n") `
        -Note (Get-ReportTruncationNote -Truncated ([bool]$data.Truncated))
}

function Get-MojazReportHtml {
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-MojazReportData -Period $Period -OnlyUserId $OnlyUserId
    $runs = @($data.Runs)
    $body = [System.Collections.Generic.List[string]]::new()
    if ($runs.Count -eq 0) { $body.Add('<p>لم يُشغَّل أي موجز في هذه الفترة.</p>') }
    foreach ($run in $runs) {
        $who = Get-AuditOperatorName -UserId ([string]$run.UserId)
        $started = if ($run.StartedAt) { ([datetime]$run.StartedAt).ToString('yyyy/MM/dd HH:mm') } else { '&mdash;' }
        $head = if ($run.EndedAt) { "$started &#8592; $(([datetime]$run.EndedAt).ToString('HH:mm')) &middot; $(Get-MojazRunDuration -Run $run)" }
        else { '<span class="live">' + $started + ' &#8592; ما زال على الهواء</span>' }
        $sub = '&laquo;' + (ConvertTo-HtmlText ([string]$run.Name)) + "&raquo; &middot; $([int]$run.Rows) صفًّا"
        if ($run.Kind -eq 'scheduled') { $sub += ' &middot; بالجدولة' }
        if ($who) { $sub += ' &middot; ' + (ConvertTo-HtmlText $who) }
        $body.Add('<div class="row"><div class="head">' + $head + '</div><div class="sub">' + $sub + '</div></div>')
    }
    $body.Add('<p class="totals">' + "الإجمالي: $($runs.Count) تشغيلًا &middot; $([int]$data.Rows) صفًّا &middot; $($data.Operators) مشغّلين" + '</p>')
    return Get-ReportHtmlDocument -Title "تقرير الموجزات — $($data.Label)" -Body ($body -join "`n") `
        -Note (Get-ReportTruncationNote -Truncated ([bool]$data.Truncated))
}

function Get-NewsReportHtml {
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-NewsReportDays -Period $Period -OnlyUserId $OnlyUserId
    $days = @($data.Days)
    $body = [System.Collections.Generic.List[string]]::new()
    if ($days.Count -eq 0) { $body.Add('<p>لم يُنشر شريط أخبار في هذه الفترة.</p>') }
    foreach ($day in $days) {
        $who = if ($day.Tally.Breakdown) { $day.Tally.Breakdown } else { $day.Tally.Single }
        $sub = if ($who) { ConvertTo-HtmlText $who } else { '&mdash;' }
        $head = "$($day.Date.ToString('yyyy/MM/dd')) — $($day.Publishes) تعديلًا &middot; على الهواء $($day.Items) &middot; $(Get-NewsEditTrail -Counts $day.Counts)"
        $body.Add('<div class="row"><div class="head">' + $head + '</div><div class="sub">' + $sub + '</div></div>')
    }
    $body.Add('<p class="totals">' + "الإجمالي: $($data.Publishes) تعديلًا &middot; على الهواء $($data.Items) خبرًا" + '</p>')
    return Get-ReportHtmlDocument -Title "تقرير الأخبار — $($data.Label)" -Body ($body -join "`n") `
        -Note (Get-ReportTruncationNote -Truncated ([bool]$data.Truncated))
}

function Export-BridgeReport {
    <# Writes the report beside the other runtime files, sends it, then removes
       it - the same shape the settings and diagnostics exports already use.
       The file is disposable; audit.jsonl stays the record. #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [Parameter(Mandatory)][ValidateSet('banners', 'news', 'mojaz')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $onlyUser = if (Test-Admin -ChatId $ChatId -UserId $UserId) { 0 } else { $UserId }
    $path = Join-Path $script:logDir "report-$Kind-$Period-$((Get-Date).ToString('yyyyMMdd-HHmmss')).html"
    try {
        $html = switch ($Kind) {
            'news' { Get-NewsReportHtml -Period $Period -OnlyUserId $onlyUser }
            'mojaz' { Get-MojazReportHtml -Period $Period -OnlyUserId $onlyUser }
            default { Get-BannerReportHtml -Period $Period -OnlyUserId $onlyUser }
        }
        [IO.File]::WriteAllText($path, $html, [Text.UTF8Encoding]::new($false))
        $caption = switch ($Kind) {
            'news' { '📰 تقرير الأخبار' }
            'mojaz' { '📑 تقرير الموجزات' }
            default { '🖼 تقرير البنرات' }
        }
        if (-not (Send-TelegramDocument -ChatId $ChatId -FilePath $path -Caption "$caption — افتحه في المتصفح، ويمكنك طباعته PDF من هناك.")) {
            Send-TelegramMessage -ChatId $ChatId -Text '⚠️ تعذّر إرسال ملف التقرير.' -ReplyMarkup (Get-ReportPeriodKeyboard -Kind $Kind)
        }
    }
    catch {
        Write-BridgeLog "Report export failed ($Kind/$Period): $($_.Exception.Message)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text '⚠️ تعذّر إنشاء ملف التقرير.' -ReplyMarkup (Get-ReportPeriodKeyboard -Kind $Kind)
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}
