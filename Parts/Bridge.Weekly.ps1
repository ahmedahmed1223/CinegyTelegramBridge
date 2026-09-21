#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    T-31: the weekly digest. A supervisor walking into Monday wants to know
    what the bridge noticed and nobody read during the week: a screen about
    to lose its table, templates nobody touched, failures that keep happening,
    settings that drifted, the ticker's pace, and the urgent board's activity.

    Each section reads through the same report machinery the other reports
    use - Get-ReportRecords against audit.jsonl - so the digest cannot drift
    from the records the daily reports already read. Everything is bounded
    on purpose: the bridge is one sequential loop, and a digest that runs
    long freezes it.
#>

function Get-WeeklyReportData {
    <#
        Every fact the digest shows, fetched once so the rich table, the
        text fallback and any future export agree about the numbers.

        A week is the span a newsroom reviews at handover - "did that banner
        run Tuesday" - so the window is the last seven days ending now.
    #>
    $now = Get-Date
    $window = Get-ReportPeriod -Period 'week'
    $label = 'آخر 7 أيام'

    # Screens approaching their payload cap. Get-RichPayloadPeak is the
    # runtime's own measurement: the biggest rich payload sent this run,
    # as a percentage of the limit. The limit is the same one
    # Register-RichPayloadMeasurement warns at 70% of, so that is the line
    # between "fine" and "will lose its table on a busier day".
    $peak = Get-RichPayloadPeak
    $nearLimit = ($peak -and [int]$peak.Percent -ge 70)
    $peakScreen = if ($nearLimit) { [string]$peak.Screen } else { '' }
    $peakPercent = if ($nearLimit) { [int]$peak.Percent } else { 0 }

    # Templates unused for thirty days (or never used at all).
    $idle = [System.Collections.Generic.List[string]]::new()
    try {
        $store = Get-TemplateStore
        $map = Get-JsonProp $store 'Map'
        if ($map) {
            $cutoff = $now.AddDays(-30)
            foreach ($key in @($map.Keys)) {
                $name = [string]$key
                if ($script:TemplateLastUsed.ContainsKey($name)) {
                    if ([datetime]$script:TemplateLastUsed[$name] -ge $cutoff) { continue }
                    $when = ([datetime]$script:TemplateLastUsed[$name]).ToLocalTime().ToString('MM-dd')
                }
                else { $when = 'أبدًا' }
                $idle.Add("$name — $when")
            }
        }
    }
    catch { Write-BridgeLog "Weekly report: idle-template signal failed: $($_.Exception.Message)" }

    # Repeated failure reasons - the five causes that fired most often.
    # AlertHistory is the bridge's own count of repeated failures, so a
    # cause that trips the same error three times in a week shows here.
    $repeats = @()
    try {
        $foundCauses = @()
        foreach ($cause in @($script:AlertHistory.Keys)) {
            $times = @(@($script:AlertHistory[$cause]) | Where-Object { $_ -is [datetime] })
            if ($times.Count -ge 2) {
                $foundCauses += [pscustomobject]@{ Cause = [string]$cause; Count = $times.Count }
            }
        }
        $repeats = @($foundCauses | Sort-Object Count -Descending | Select-Object -First 5)
    }
    catch { Write-BridgeLog "Weekly report: repeat-failure signal failed: $($_.Exception.Message)" }

    # Settings differing from their defaults. Names only: a setting's
    # value can be a secret, its name cannot - the same rule the weekly
    # notices already follow.
    $changed = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($prop in @($script:DefaultSettings.Keys)) {
            $name = [string]$prop
            $def = [string]$script:DefaultSettings[$name]
            $cur = ''
            try { $cur = [string](Get-JsonProp $config.Settings $name) } catch { continue }
            if ($cur -cne $def) { $changed.Add($name) }
        }
    }
    catch { Write-BridgeLog "Weekly report: changed-settings signal failed: $($_.Exception.Message)" }

    # Ticker publish summary: total publishes in the week and when the
    # strip was last touched. Reads through Get-ReportRecords like the
    # news report does, so the two can never disagree about the count.
    $tickerScan = Get-ReportRecords -From $window.From -To $window.To -EventName 'news_publish'
    $tickerRecords = @($tickerScan.Records)
    $tickerPublishes = $tickerRecords.Count
    $tickerLastAt = $null
    if ($tickerRecords.Count -gt 0) {
        $tickerLastAt = @($tickerRecords | Sort-Object { [datetime]$_.When } -Descending | Select-Object -First 1).When
    }

    # Urgent board activity: runs started (START) and stories played
    # (STOP) in the week. The board writes one audit line at start and
    # another at end, under the urgent_board_run event.
    $urgentScan = Get-ReportRecords -From $window.From -To $window.To -EventName 'urgent_board_run'
    $urgentRunsStarted = @($urgentScan.Records | Where-Object { [string]$_.Action -eq 'START' }).Count
    $urgentStoriesPlayed = @($urgentScan.Records | Where-Object { [string]$_.Action -eq 'STOP' }).Count

    return @{
        Label              = $label
        From               = $window.From
        To                 = $window.To
        PeakScreen         = $peakScreen
        PeakPercent        = [int]$peakPercent
        NearLimit          = [bool]$nearLimit
        IdleTemplates      = @($idle)
        Repeats            = $repeats
        ChangedSettings    = @($changed)
        TickerPublishes    = $tickerPublishes
        TickerLastAt       = $tickerLastAt
        UrgentRunsStarted  = $urgentRunsStarted
        UrgentStoriesPlayed = $urgentStoriesPlayed
        Truncated          = ($tickerScan.Truncated -or $urgentScan.Truncated)
    }
}

function Get-WeeklyReportBlocks {
    <# The digest as rich blocks: a heading, then one section per signal,
       each opening with its own glyph the way the other reports do. #>
    $data = Get-WeeklyReportData
    $blocks = @(@{ type = 'heading'; text = "📋 تقرير أسبوعي — $($data.Label)"; size = 3 })

    # Screens near their payload cap.
    if ($data.NearLimit) {
        $blocks += @{ type = 'paragraph'; text = "📐 شاشة قريبة من حدّ حجمها: <b>$(ConvertTo-HtmlText $data.PeakScreen)</b> — $($data.PeakPercent)% من الحدّ." }
    }
    else {
        $blocks += @{ type = 'paragraph'; text = '📐 لا شاشات قريبة من حدّ حجمها.' }
    }

    # Idle templates.
    $idle = @($data.IdleTemplates)
    if ($idle.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = '🕸 كل القوالب مستخدمة خلال آخر شهر.' }
    }
    else {
        $shown = @($idle | Select-Object -First 5)
        $extra = $idle.Count - 5
        $tail = if ($extra -gt 0) { " (+$extra أخرى)" } else { '' }
        $safe = @($shown | ForEach-Object { ConvertTo-HtmlText ([string]$_) })
        $blocks += @{ type = 'paragraph'; text = "🕸 قوالب بلا استعمال منذ شهر: $($safe -join ' · ')$tail" }
    }

    # Repeated failure reasons.
    $repeats = @($data.Repeats)
    if ($repeats.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = '🔁 لا فشل متكرر بنفس السبب هذا الأسبوع.' }
    }
    else {
        $parts = @($repeats | ForEach-Object {
                "$(ConvertTo-HtmlText $_.Cause) — $(Get-ArabicCountNoun -Count $_.Count -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' -EnglishOne 'time' -EnglishMany 'times')"
            })
        $blocks += @{ type = 'paragraph'; text = "🔁 فشل متكرر بنفس السبب: $($parts -join ' · ')" }
    }

    # Changed settings.
    $changed = @($data.ChangedSettings)
    if ($changed.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = '⚙️ لا إعدادات معدّلة عن الافتراضي.' }
    }
    else {
        $safe = @($changed | Select-Object -First 8 | ForEach-Object { "<code>$(ConvertTo-HtmlText ([string]$_))</code>" })
        $extra = $changed.Count - 8
        $tail = if ($extra -gt 0) { " (+$extra غيرها)" } else { '' }
        $blocks += @{ type = 'paragraph'; text = "⚙️ إعدادات معدّلة عن الافتراضي: $($safe -join ' ')$tail" }
    }

    # Ticker publish summary.
    if ($data.TickerPublishes -eq 0) {
        $blocks += @{ type = 'paragraph'; text = '📰 لم يُنشر شريط أخبار هذا الأسبوع.' }
    }
    else {
        $lastAt = if ($data.TickerLastAt) { ([datetime]$data.TickerLastAt).ToString('MM/dd HH:mm') } else { '—' }
        $blocks += @{ type = 'paragraph'; text = "📰 الأخبار: $(Get-ArabicCountNoun -Count $data.TickerPublishes -One 'تعديل' -Two 'تعديلان' -Few 'تعديلات' -Many 'تعديلًا' -EnglishOne 'edit' -EnglishMany 'edits') · آخر نشرة $lastAt" }
    }

    # Urgent board activity.
    $blocks += @{ type = 'paragraph'; text = "🚨 العواجل: $(Get-ArabicCountNoun -Count $data.UrgentRunsStarted -One 'تشغيل' -Two 'تشغيلان' -Few 'تشغيلات' -Many 'تشغيلًا' -EnglishOne 'run' -EnglishMany 'runs') · $(Get-ArabicCountNoun -Count $data.UrgentStoriesPlayed -One 'خبر' -Two 'خبران' -Few 'أخبار' -Many 'خبرًا' -EnglishOne 'headline' -EnglishMany 'headlines') بُثّت" }

    if ($data.Truncated) {
        $blocks += @{ type = 'paragraph'; text = "⚠️ بلغ السجل حدّ القراءة ($script:ReportMaxRecords سجلًّا)؛ قد تكون هناك عمليات أقدم داخل المدة." }
    }

    return $blocks
}

function Get-WeeklyReportText {
    <# The plain fallback, in the reports' shape: each section opens with
       its own glyph, every operator-typed value escaped. #>
    $data = Get-WeeklyReportData
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>📋 تقرير أسبوعي</b> — $(ConvertTo-HtmlText $data.Label)")

    if ($data.NearLimit) {
        $lines.Add("📐 شاشة قريبة من حدّها: <b>$(ConvertTo-HtmlText $data.PeakScreen)</b> — $($data.PeakPercent)%")
    }
    else { $lines.Add('📐 لا شاشات قريبة من حدّ حجمها.') }

    $idle = @($data.IdleTemplates)
    if ($idle.Count -eq 0) { $lines.Add('🕸 كل القوالب مستخدمة خلال آخر شهر.') }
    else {
        $shown = @($idle | Select-Object -First 5)
        $extra = $idle.Count - 5
        $tail = if ($extra -gt 0) { " (+$extra أخرى)" } else { '' }
        $safe = @($shown | ForEach-Object { ConvertTo-HtmlText ([string]$_) })
        $lines.Add("🕸 قوالب بلا استعمال منذ شهر: $($safe -join ' · ')$tail")
    }

    $repeats = @($data.Repeats)
    if ($repeats.Count -eq 0) { $lines.Add('🔁 لا فشل متكرر بنفس السبب.') }
    else {
        $parts = @($repeats | ForEach-Object { "$(ConvertTo-HtmlText $_.Cause) — $(Get-ArabicCountNoun -Count $_.Count -One 'مرة' -Two 'مرتين' -Few 'مرات' -Many 'مرة' -EnglishOne 'time' -EnglishMany 'times')" })
        $lines.Add("🔁 فشل متكرر: $($parts -join ' · ')")
    }

    $changed = @($data.ChangedSettings)
    if ($changed.Count -eq 0) { $lines.Add('⚙️ لا إعدادات معدّلة عن الافتراضي.') }
    else {
        $safe = @($changed | Select-Object -First 8 | ForEach-Object { "<code>$(ConvertTo-HtmlText ([string]$_))</code>" })
        $extra = $changed.Count - 8
        $tail = if ($extra -gt 0) { " (+$extra غيرها)" } else { '' }
        $lines.Add("⚙️ إعدادات معدّلة: $($safe -join ' ')$tail")
    }

    if ($data.TickerPublishes -eq 0) { $lines.Add('📰 لم يُنشر شريط أخبار هذا الأسبوع.') }
    else {
        $lastAt = if ($data.TickerLastAt) { ([datetime]$data.TickerLastAt).ToString('MM/dd HH:mm') } else { '—' }
        $lines.Add("📰 الأخبار: $(Get-ArabicCountNoun -Count $data.TickerPublishes -One 'تعديل' -Two 'تعديلان' -Few 'تعديلات' -Many 'تعديلًا' -EnglishOne 'edit' -EnglishMany 'edits') · آخر نشرة $lastAt")
    }

    $lines.Add("🚨 العواجل: $(Get-ArabicCountNoun -Count $data.UrgentRunsStarted -One 'تشغيل' -Two 'تشغيلان' -Few 'تشغيلات' -Many 'تشغيلًا' -EnglishOne 'run' -EnglishMany 'runs') · $(Get-ArabicCountNoun -Count $data.UrgentStoriesPlayed -One 'خبر' -Two 'خبران' -Few 'أخبار' -Many 'خبرًا' -EnglishOne 'headline' -EnglishMany 'headlines') بُثّت")

    if ($data.Truncated) { $lines.Add("<i>⚠️ بلغ السجل حدّ القراءة؛ قد تكون هناك عمليات أقدم داخل المدة.</i>") }
    return ($lines -join "`n")
}

function Get-WeeklyReportKeyboard {
    <# The digest has no period to switch - a week is the span - so the
       keyboard is just the way back to the reports menu and the main menu. #>
    return @{ inline_keyboard = @(
            , @((New-Button '📊 التقارير' 'menu:reports'))
            , @((New-Button '🏠 القائمة' 'menu:main'))
        )
    }
}

function Show-WeeklyReport {
    <# The entry point: rich blocks first, the plain text fallback the
       reports all fall through to when the API will not take the table. #>
    param([Parameter(Mandatory)][long]$ChatId)
    $keyboard = Get-WeeklyReportKeyboard
    $blocks = Get-WeeklyReportBlocks
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks $blocks -ReplyMarkup $keyboard) { return }
    Send-TelegramPagedText -ChatId $ChatId -Text (Get-WeeklyReportText) -ParseMode HTML -ReplyMarkup $keyboard
}
