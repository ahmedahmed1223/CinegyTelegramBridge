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
            , @((New-Button '🏠 القائمة' 'menu:main'))
        )
    }
}

function Get-ReportPeriodKeyboard {
    <# The period row doubles as the refresh control: tapping the current
       period re-runs it. #>
    param([Parameter(Mandatory)][ValidateSet('banners', 'news')][string]$Kind)
    return @{ inline_keyboard = @(
            , @((New-Button 'اليوم' "rep:${Kind}:today"), (New-Button 'أمس' "rep:${Kind}:yesterday"))
            , @((New-Button '7 أيام' "rep:${Kind}:week"), (New-Button '30 يومًا' "rep:${Kind}:month"))
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
📰 الأخبار — النشر اليومي وعدد الأخبار
"@
}

function Show-Report {
    <# One entry point for both sections. Operators see their own work;
       administrators and the owner see everyone's, because the banner report
       names who did what. #>
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [Parameter(Mandatory)][ValidateSet('banners', 'news')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $onlyUser = if (Test-Admin -ChatId $ChatId -UserId $UserId) { 0 } else { $UserId }
    $text = if ($Kind -eq 'news') {
        Get-NewsReportText -Period $Period -OnlyUserId $onlyUser
    }
    else {
        Get-BannerReportText -Period $Period -OnlyUserId $onlyUser
    }
    Send-TelegramPagedText -ChatId $ChatId -Text $text -ReplyMarkup (Get-ReportPeriodKeyboard -Kind $Kind)
}

function Get-ReportPeriod {
    <# Named windows an operator actually asks for at a handover, resolved to
       a start time and an Arabic label. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period)
    $now = Get-Date
    switch ($Period) {
        'today' { return @{ From = $now.Date; To = $now; Label = 'اليوم' } }
        'yesterday' { return @{ From = $now.Date.AddDays(-1); To = $now.Date; Label = 'أمس' } }
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
        [pscustomobject]@{
            When   = $at
            Action = (Get-AuditRecordField $record 'action')
            Result = (Get-AuditRecordField $record 'result')
            Target = (Get-AuditRecordField $record 'target')
            UserId = (Get-AuditRecordField $record 'userId')
            Values = (Get-AuditRecordField $record 'values')
            Count  = $count
            Layer  = $layer
        }
    }
    return @{
        Records   = @($records)
        Truncated = ($raw.Count -ge $script:ReportMaxRecords)
    }
}

function Get-NewsReportText {
    <# What the ticker did: how many publishes, how many items, and by whom -
       per day, because "94 items this week" hides that one person carried
       six of the seven days. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $window = Get-ReportPeriod -Period $Period
    $scan = Get-ReportRecords -From $window.From -To $window.To -EventName 'news_publish'
    $records = @($scan.Records)
    if ($OnlyUserId -gt 0) { $records = @($records | Where-Object { $_.UserId -eq [string]$OnlyUserId }) }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("📰 تقرير الأخبار — $($window.Label)")
    $lines.Add('━━━━━━━━━━━━━━')
    if ($records.Count -eq 0) {
        $lines.Add('لم يُنشر شريط أخبار في هذه الفترة.')
        return ($lines -join "`n")
    }

    $totalItems = 0
    foreach ($day in @($records | Group-Object -Property { $_.When.Date } | Sort-Object Name)) {
        $dayRecords = @($day.Group)
        $items = [int](@($dayRecords | Measure-Object -Property Count -Sum).Sum)
        $totalItems += $items
        $stamp = ([datetime]$dayRecords[0].When).ToString('yyyy/MM/dd')
        $lines.Add("• $stamp — $($dayRecords.Count) نشرة · $items خبرًا")
        $tally = Get-OperatorTally -Records $dayRecords
        if ($tally.Breakdown) { $lines.Add("   ↳ $($tally.Breakdown)") }
        elseif ($tally.Single) { $lines.Add("   ↳ $($tally.Single)") }
    }

    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("الإجمالي: $($records.Count) نشرة · $totalItems خبرًا")
    if ($scan.Truncated) { $lines.Add("⚠️ عُرض أحدث $script:ReportMaxRecords سجل فقط؛ اختر مدة أقصر لتقرير كامل.") }
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

function Get-BannerReportText {
    <# Every banner that went up in the window: its copy, who ran it, and how
       long it stayed. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $window = Get-ReportPeriod -Period $Period
    $scan = Get-ReportRecords -From $window.From -To $window.To -EventName 'air_control'
    $sessions = @(Get-BannerSessions -Records @($scan.Records))
    if ($OnlyUserId -gt 0) { $sessions = @($sessions | Where-Object { $_.UserId -eq [string]$OnlyUserId }) }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("🖼 تقرير البنرات — $($window.Label)")
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

    $operatorCount = @($sessions | Group-Object -Property UserId).Count
    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("الإجمالي: $($sessions.Count) بنرًا · $operatorCount مشغّلين")
    if ($scan.Truncated) { $lines.Add("⚠️ عُرض أحدث $script:ReportMaxRecords سجل فقط؛ اختر مدة أقصر لتقرير كامل.") }
    return ($lines -join "`n")
}
