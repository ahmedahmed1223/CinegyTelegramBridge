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
    param([Parameter(Mandatory)][ValidateSet('banners', 'news')][string]$Kind, [string]$Period = 'today')
    return @{ inline_keyboard = @(
            , @((New-Button 'اليوم' "rep:${Kind}:today"), (New-Button 'أمس' "rep:${Kind}:yesterday"))
            , @((New-Button '7 أيام' "rep:${Kind}:week"), (New-Button '30 يومًا' "rep:${Kind}:month"))
            , @((New-Button '⬇️ تحميل الملف' "repdl:${Kind}:${Period}"))
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
    $markup = Get-ReportPeriodKeyboard -Kind $Kind -Period $Period
    # The banner report is the one with columns, so it is the one that gains
    # from a real table. Tried first and never depended on: an API without
    # sendRichMessage, or a shape it will not take, falls through to exactly
    # the text this screen has always sent.
    if ($Kind -eq 'banners') {
        $blocks = Get-BannerReportBlocks -Period $Period -OnlyUserId $onlyUser
        if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $blocks -ReplyMarkup $markup) { return }
    }
    $text = if ($Kind -eq 'news') {
        Get-NewsReportText -Period $Period -OnlyUserId $onlyUser
    }
    else {
        Get-BannerReportText -Period $Period -OnlyUserId $onlyUser
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
        $dayItems = 0
        foreach ($record in $dayRecords) { $dayItems += [int]$record.Count }
        [pscustomobject]@{
            Date      = ([datetime]$dayRecords[0].When).Date
            Publishes = $dayRecords.Count
            Items     = $dayItems
            Tally     = (Get-OperatorTally -Records $dayRecords)
        }
    }
    $days = @($days)
    $totalItems = 0
    foreach ($day in $days) { $totalItems += [int]$day.Items }
    return @{
        Label      = $window.Label
        Days       = $days
        Publishes  = $records.Count
        Items      = $totalItems
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

function Get-NewsReportText {
    <# What the ticker did: how many publishes, how many items, and by whom -
       per day, because "94 items this week" hides that one person carried
       six of the seven days. #>
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-NewsReportDays -Period $Period -OnlyUserId $OnlyUserId

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("📰 تقرير الأخبار — $($data.Label)")
    $lines.Add('━━━━━━━━━━━━━━')
    if (@($data.Days).Count -eq 0) {
        $lines.Add('لم يُنشر شريط أخبار في هذه الفترة.')
        return ($lines -join "`n")
    }

    foreach ($day in @($data.Days)) {
        $lines.Add("• $($day.Date.ToString('yyyy/MM/dd')) — $($day.Publishes) نشرة · $($day.Items) خبرًا")
        if ($day.Tally.Breakdown) { $lines.Add("   ↳ $($day.Tally.Breakdown)") }
        elseif ($day.Tally.Single) { $lines.Add("   ↳ $($day.Tally.Single)") }
    }

    $lines.Add('━━━━━━━━━━━━━━')
    $lines.Add("الإجمالي: $($data.Publishes) نشرة · $($data.Items) خبرًا")
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

    $cells = @(, @(
            @{ text = 'البنر'; is_header = $true }
            @{ text = 'الطبقة'; is_header = $true }
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
            @{ text = [string]$session.Target }
            @{ text = [string]$session.Layer }
            @{ text = $(if ($who) { $who } else { '—' }) }
            @{ text = $start }
            @{ text = $span }
        )
    }

    $blocks += @{ type = 'table'; cells = $cells; is_striped = $true; is_compact = $true; is_bordered = $true }
    $blocks += @{ type = 'paragraph'; text = "الإجمالي: $($sessions.Count) بنرًا · $($data.Operators) مشغّلين" }
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

function Get-NewsReportHtml {
    param([Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period, [long]$OnlyUserId = 0)
    $data = Get-NewsReportDays -Period $Period -OnlyUserId $OnlyUserId
    $days = @($data.Days)
    $body = [System.Collections.Generic.List[string]]::new()
    if ($days.Count -eq 0) { $body.Add('<p>لم يُنشر شريط أخبار في هذه الفترة.</p>') }
    foreach ($day in $days) {
        $who = if ($day.Tally.Breakdown) { $day.Tally.Breakdown } else { $day.Tally.Single }
        $sub = if ($who) { ConvertTo-HtmlText $who } else { '&mdash;' }
        $head = "$($day.Date.ToString('yyyy/MM/dd')) — $($day.Publishes) نشرة &middot; $($day.Items) خبرًا"
        $body.Add('<div class="row"><div class="head">' + $head + '</div><div class="sub">' + $sub + '</div></div>')
    }
    $body.Add('<p class="totals">' + "الإجمالي: $($data.Publishes) نشرة &middot; $($data.Items) خبرًا" + '</p>')
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
        [Parameter(Mandatory)][ValidateSet('banners', 'news')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('today', 'yesterday', 'week', 'month')][string]$Period
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $onlyUser = if (Test-Admin -ChatId $ChatId -UserId $UserId) { 0 } else { $UserId }
    $path = Join-Path $script:logDir "report-$Kind-$Period-$((Get-Date).ToString('yyyyMMdd-HHmmss')).html"
    try {
        $html = if ($Kind -eq 'news') {
            Get-NewsReportHtml -Period $Period -OnlyUserId $onlyUser
        }
        else {
            Get-BannerReportHtml -Period $Period -OnlyUserId $onlyUser
        }
        [IO.File]::WriteAllText($path, $html, [Text.UTF8Encoding]::new($false))
        $caption = if ($Kind -eq 'news') { '📰 تقرير الأخبار' } else { '🖼 تقرير البنرات' }
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
