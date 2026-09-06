#requires -Version 7
BeforeAll {
    # The bridge runs under StrictMode, and without it here these tests pass
    # on code that throws in production: reading .Sum off an empty
    # Measure-Object result is silently $null under the default mode.
    Set-StrictMode -Version Latest

    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'Parts\Bridge.Reports.ps1')

    # The report functions read through Read-AuditRecords and the two audit
    # field helpers; defining those here keeps this file independent of the
    # whole bridge while still exercising the real grouping and pairing logic.
    # Replaced by a Mock in every Describe that needs records; the real
    # signature is kept so the Mock's ParameterFilter would still bind.
    function Read-AuditRecords {
        param([int]$MaxLines = 0)
        Write-Verbose "stub asked for $MaxLines records"
        @()
    }
    function Get-AuditRecordField {
        param($Record, [string]$Name)
        if ($Record -and $Record.PSObject.Properties[$Name]) { return [string]$Record.PSObject.Properties[$Name].Value }
        return ''
    }
    function Read-AuditRecordStamp {
        param($Record)
        $at = [datetime]::MinValue
        if ([datetime]::TryParse((Get-AuditRecordField $Record 'timestampUtc'), $null,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)) { return $at.ToLocalTime() }
        return $null
    }
    function Get-AuditOperatorName {
        param([string]$UserId)
        if ($UserId -eq '77') { return 'محمد' }
        if ($UserId) { return 'أحمد' }
        return ''
    }
    function Get-OperatorTally {
        param([object[]]$Records)
        $byUser = @(@($Records) | Group-Object -Property UserId | Sort-Object Count -Descending)
        if ($byUser.Count -le 1) { return @{ Single = (Get-AuditOperatorName -UserId ([string]$byUser[0].Name)); Breakdown = '' } }
        $parts = foreach ($e in $byUser) { "$(Get-AuditOperatorName -UserId ([string]$e.Name)) $($e.Count)" }
        return @{ Single = ''; Breakdown = ($parts -join ' · ') }
    }

    function New-Rec {
        param([string]$Action, [int]$Layer, [string]$Target, [int]$MinutesAgo, [string]$UserId = '42', [string]$Values = '')
        [pscustomobject]@{
            When = (Get-Date).AddMinutes(-$MinutesAgo); Action = $Action; Result = 'success'
            Target = $Target; UserId = $UserId; Values = $Values; Count = 0; Layer = $Layer
        }
    }
}

Describe 'Banner session pairing' {
    It 'closes a session at the hide that took it off air' {
        $sessions = @(Get-BannerSessions -Records @(
                (New-Rec -Action SHOW -Layer 4 -Target 'عاجل' -MinutesAgo 30 -Values 'نص')
                (New-Rec -Action HIDE -Layer 4 -Target '' -MinutesAgo 10)
            ))

        $sessions.Count | Should -Be 1
        $sessions[0].Target | Should -Be 'عاجل'
        $sessions[0].EndedBy | Should -Be 'إخفاء'
        [int][math]::Round(($sessions[0].EndedAt - $sessions[0].StartedAt).TotalMinutes) | Should -Be 20
    }

    It 'treats a second show on the same layer as a replacement, not a second live banner' {
        $sessions = @(Get-BannerSessions -Records @(
                (New-Rec -Action SHOW -Layer 4 -Target 'أول' -MinutesAgo 30)
                (New-Rec -Action SHOW -Layer 4 -Target 'ثانٍ' -MinutesAgo 20)
            ))

        $sessions.Count | Should -Be 2
        (@($sessions | Where-Object { $_.Target -eq 'أول' })[0]).EndedBy | Should -Be 'استبدال'
        # The replacement is still live: it has no end, and must not be given one.
        (@($sessions | Where-Object { $_.Target -eq 'ثانٍ' })[0]).EndedAt | Should -BeNullOrEmpty
    }

    It 'keeps layers independent' {
        $sessions = @(Get-BannerSessions -Records @(
                (New-Rec -Action SHOW -Layer 4 -Target 'عاجل' -MinutesAgo 30)
                (New-Rec -Action SHOW -Layer 7 -Target 'شعار' -MinutesAgo 25)
                (New-Rec -Action HIDE -Layer 4 -Target '' -MinutesAgo 10)
            ))

        (@($sessions | Where-Object { $_.Target -eq 'عاجل' })[0]).EndedAt | Should -Not -BeNullOrEmpty
        (@($sessions | Where-Object { $_.Target -eq 'شعار' })[0]).EndedAt | Should -BeNullOrEmpty
    }

    It 'ignores failed operations, which never reached the screen' {
        $failed = New-Rec -Action SHOW -Layer 4 -Target 'فاشل' -MinutesAgo 30
        $failed.Result = 'failed'

        @(Get-BannerSessions -Records @($failed)).Count | Should -Be 0
    }

    It 'survives an unmatched hide with no show before it' {
        # A restart, or a hide of something shown before the window opened.
        $orphan = @((New-Rec -Action HIDE -Layer 4 -Target '' -MinutesAgo 5))
        { Get-BannerSessions -Records $orphan } | Should -Not -Throw
        @(Get-BannerSessions -Records $orphan).Count | Should -Be 0
    }
}

Describe 'Report windows' {
    It 'labels each period in Arabic and starts it where it should' {
        (Get-ReportPeriod -Period today).Label | Should -Be 'اليوم'
        (Get-ReportPeriod -Period today).From | Should -Be (Get-Date).Date
        (Get-ReportPeriod -Period week).From | Should -Be (Get-Date).Date.AddDays(-6)
        (Get-ReportPeriod -Period month).Label | Should -Be 'آخر 30 يومًا'
    }
}

Describe 'News report' {
    BeforeEach {
        # Two hours ago, but never before today began: the record has to fall
        # inside the "today" period even when the suite runs just after
        # midnight, which is where this used to fail once a night.
        $moment = [datetime]::Now.AddHours(-2)
        if ($moment -lt [datetime]::Now.Date) { $moment = [datetime]::Now.Date.AddMinutes(1) }
        $stamp = $moment.ToUniversalTime().ToString('o')
        Mock Read-AuditRecords {
            @(
                [pscustomobject]@{ timestampUtc = $stamp; event = 'news_publish'; action = 'PUBLISH'; result = 'success'; userId = '42'; count = '10' }
                [pscustomobject]@{ timestampUtc = $stamp; event = 'news_publish'; action = 'PUBLISH'; result = 'success'; userId = '77'; count = '10' }
                [pscustomobject]@{ timestampUtc = $stamp; event = 'air_control'; action = 'SHOW'; result = 'success'; userId = '42'; target = 'عاجل'; layer = '4' }
            )
        }
    }

    It 'reports what is on air and splits the day between its publishers' {
        # Not a total any more: the strip is one running thing, so adding its
        # readings up counted the same headlines once per edit.
        $text = Get-NewsReportText -Period today

        $text | Should -Match 'على الهواء'
        $text | Should -Match '2 تعديلًا'
        $text | Should -Match 'أحمد 1'
        $text | Should -Match 'محمد 1'
        # An air_control record is not a news publish.
        $text | Should -Not -Match 'عاجل'
    }

    It 'says plainly when nothing was published' {
        Mock Read-AuditRecords { @() }
        Get-NewsReportText -Period today | Should -Match 'لم يُنشر'
    }
}

Describe 'HTML export' {
    BeforeEach {
        $script:BridgeVersion = '6.1.0'
        $stamp = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
        Mock Read-AuditRecords {
            @(
                [pscustomobject]@{ timestampUtc = $stamp; event = 'air_control'; action = 'SHOW'; result = 'success'
                    userId = '42'; target = 'breaking-news'; layer = '4'; values = 'Headline: <b>عاجل</b> & "اقتباس"' }
            )
        }
    }

    It 'escapes operator copy instead of letting it become markup' {
        $html = Get-BannerReportHtml -Period today

        # The copy is operator input: it must never reach the document as tags.
        $html | Should -Match '&lt;b&gt;'
        $html | Should -Match '&amp;'
        $html | Should -Not -Match '<b>عاجل</b>'
    }

    It 'builds a self-contained right-to-left page' {
        $html = Get-BannerReportHtml -Period today

        $html | Should -Match 'dir="rtl"'
        $html | Should -Match 'lang="ar"'
        $html | Should -Match '@media print'
        # No internet on a playout machine: nothing may be fetched.
        $html | Should -Not -Match '<script'
        $html | Should -Not -Match 'https?://'
    }

    It 'carries the truncation warning into the file too' {
        $stamp = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
        Mock Read-AuditRecords {
            @(1..$script:ReportMaxRecords | ForEach-Object {
                    [pscustomobject]@{ timestampUtc = $stamp; event = 'news_publish'; action = 'PUBLISH'
                        result = 'success'; userId = '42'; count = '1' }
                })
        }

        Get-NewsReportHtml -Period today | Should -Match 'عُرض أحدث'
    }
}

Describe 'Report truncation honesty' {
    It 'announces that it showed only the newest records' {
        $stamp = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
        Mock Read-AuditRecords {
            @(1..$script:ReportMaxRecords | ForEach-Object {
                    [pscustomobject]@{ timestampUtc = $stamp; event = 'news_publish'; action = 'PUBLISH'; result = 'success'; userId = '42'; count = '1' }
                })
        }

        # A report that silently drops records reads as a complete one.
        Get-NewsReportText -Period today | Should -Match 'عُرض أحدث'
    }
}

Describe 'Banner report as rich blocks' {
    BeforeEach {
        Mock Get-AuditOperatorName { 'مخرج الأخبار' }
        $script:RichMessagesUnavailable = $false
    }

    It 'leads with a heading and lays the sessions out as a table' {
        Mock Get-BannerReportData {
            @{ Label = 'اليوم'; Operators = 2; Truncated = $false; Sessions = @(
                    @{ UserId = 10; Layer = 7; Target = 'urgent'; Values = 'نص'
                        StartedAt = '2026-08-31T21:00:00'; EndedAt = '2026-08-31T21:05:00' }
                ) }
        }

        $blocks = @(Get-BannerReportBlocks -Period today)
        $table = @($blocks | Where-Object { $_.type -eq 'table' })[0]

        $blocks[0].type | Should -Be 'heading'
        $table | Should -Not -BeNullOrEmpty
        @($table.cells).Count | Should -Be 2
        @($table.cells[0] | Where-Object { $_.is_header }).Count | Should -Be 4
        @($table.cells[1])[0].text | Should -Be 'urgent · ط7'
        @($table.cells[1])[3].text | Should -Be '5 د'
    }

    It 'says a banner is still up rather than reporting a duration it does not have' {
        Mock Get-BannerReportData {
            @{ Label = 'اليوم'; Operators = 1; Truncated = $false; Sessions = @(
                    @{ UserId = 10; Layer = 7; Target = 'urgent'; Values = ''
                        StartedAt = '2026-08-31T21:00:00'; EndedAt = $null }
                ) }
        }

        $table = @(@(Get-BannerReportBlocks -Period today) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[1])[3].text | Should -Match 'على الهواء'
    }

    It 'draws no empty table for a period with nothing in it' {
        Mock Get-BannerReportData { @{ Label = 'أمس'; Operators = 0; Truncated = $false; Sessions = @() } }

        $blocks = @(Get-BannerReportBlocks -Period yesterday)

        @($blocks | Where-Object { $_.type -eq 'table' }).Count | Should -Be 0
        @($blocks | Where-Object { $_.type -eq 'paragraph' })[0].text | Should -Match 'لم يُعرض'
    }
}

Describe 'News report as rich blocks' {
    It 'puts the day, its counts and its operators on one row' {
        # The text version spends a second indented line on the tally because
        # it has nowhere else to put it; here it is the fourth column.
        Mock Get-NewsReportDays {
            @{ Label = 'الأسبوع'; Publishes = 3; Items = 14; Truncated = $false; SilentDays = 0
                LastPublishedAt = [datetime]'2026-08-31T21:40'; Days = @(
                    @{ Date = [datetime]'2026-08-30'; Publishes = 1; Items = 12; Counts = @(12)
                        First = [datetime]'2026-08-30T20:00'; Last = [datetime]'2026-08-30T20:00'
                        Tally = @{ Breakdown = 'سامي 1'; Single = '' } }
                    @{ Date = [datetime]'2026-08-31'; Publishes = 2; Items = 14; Counts = @(15, 14)
                        First = [datetime]'2026-08-31T07:10'; Last = [datetime]'2026-08-31T21:40'
                        Tally = @{ Breakdown = ''; Single = 'ليلى' } }
                ) }
        }

        $blocks = @(Get-NewsReportBlocks -Period week)
        $table = @($blocks | Where-Object { $_.type -eq 'table' })[0]

        $blocks[0].type | Should -Be 'heading'
        @($table.cells).Count | Should -Be 3
        @($table.cells[0] | Where-Object { $_.is_header }).Count | Should -Be 4
        @($table.cells[1])[2].text | Should -Be '12'
        @($table.cells[2])[2].text | Should -Be '14'
        # The range replaces the trail in the table; the trail itself, the
        # span and the operators moved to the details block below it.
        @($table.cells[2])[3].text | Should -Be '14–15'
        $detail = @($blocks | Where-Object { $_.type -eq 'details' })[0]
        $texts = @($detail.blocks | ForEach-Object { $_.text })
        @($texts | Where-Object { $_ -match '07:10 ← 21:40' }).Count | Should -Be 1
        @($texts | Where-Object { $_ -match 'ليلى' }).Count | Should -Be 1
    }

    It 'draws no table for a period nothing was published in' {
        Mock Get-NewsReportDays { @{ Label = 'أمس'; Publishes = 0; Items = 0; Truncated = $false; SilentDays = 1; LastPublishedAt = $null; Days = @() } }

        $blocks = @(Get-NewsReportBlocks -Period yesterday)

        @($blocks | Where-Object { $_.type -eq 'table' }).Count | Should -Be 0
        @($blocks | Where-Object { $_.type -eq 'paragraph' })[0].text | Should -Match 'لم يُنشر'
    }

    It 'says so rather than leaving the operator column blank' {
        Mock Get-NewsReportDays {
            @{ Label = 'اليوم'; Publishes = 1; Items = 5; Truncated = $false; SilentDays = 0
                LastPublishedAt = [datetime]'2026-08-31T20:00'; Days = @(
                    @{ Date = [datetime]'2026-08-31'; Publishes = 1; Items = 5; Counts = @(5)
                        First = [datetime]'2026-08-31T20:00'; Last = [datetime]'2026-08-31T20:00'
                        Tally = @{ Breakdown = ''; Single = '' } }
                ) }
        }

        $table = @(@(Get-NewsReportBlocks -Period today) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[1])[3].text | Should -Be '5'
    }
}

Describe 'The ticker is one running strip, not a series of bulletins' {
    It 'reports what the day ended with instead of adding every reading up' {
        # A strip of 14 edited three times was being reported as 40 items:
        # each publish records how many the strip held at that moment, so the
        # sum counted the same headlines once per edit.
        Mock Get-ReportPeriod { @{ From = [datetime]'2026-08-31'; To = [datetime]'2026-08-31T23:59'; Label = 'اليوم' } }
        Mock Get-ReportRecords {
            @{ Truncated = $false; Records = @(
                    [pscustomobject]@{ When = [datetime]'2026-08-31T07:10'; Count = 12; UserId = '10' }
                    [pscustomobject]@{ When = [datetime]'2026-08-31T13:00'; Count = 15; UserId = '10' }
                    [pscustomobject]@{ When = [datetime]'2026-08-31T21:40'; Count = 14; UserId = '10' }
                ) }
        }
        Mock Get-OperatorTally { @{ Breakdown = ''; Single = 'سامي' } }

        $data = Get-NewsReportDays -Period today

        $data.Publishes | Should -Be 3
        $data.Items | Should -Be 14
        @($data.Days)[0].Counts | Should -Be @(12, 15, 14)
    }

    It 'shows the size of every edit rather than only how many there were' {
        Get-NewsEditTrail -Counts @(12, 15, 14) | Should -Be '12 ← 15 ← 14'
        Get-NewsEditTrail -Counts @(9) | Should -Be '9'
        Get-NewsEditTrail -Counts @() | Should -Be '—'
    }

    It 'trims a long day to its most recent edits, and says it trimmed' {
        Get-NewsEditTrail -Counts @(1, 2, 3, 4, 5, 6, 7, 8) -Max 3 | Should -Be '… ← 6 ← 7 ← 8'
    }
}

Describe 'A day with no edit is a row, not an absence' {
    It 'fills the silent days so the gap is visible' {
        # Group-Object only produces days that have records, so a week in
        # which Wednesday carried nothing simply had no Wednesday row - and
        # that gap is what a supervisor opens the report to find.
        Mock Get-ReportPeriod { @{ From = [datetime]'2026-08-29'; To = [datetime]'2026-08-31T23:59'; Label = 'آخر 3 أيام' } }
        Mock Get-ReportRecords {
            @{ Truncated = $false; Records = @(
                    [pscustomobject]@{ When = [datetime]'2026-08-29T20:00'; Count = 10; UserId = '10' }
                    [pscustomobject]@{ When = [datetime]'2026-08-31T20:00'; Count = 11; UserId = '10' }
                ) }
        }
        Mock Get-OperatorTally { @{ Breakdown = ''; Single = 'سامي' } }

        $data = Get-NewsReportDays -Period week

        @($data.Days).Count | Should -Be 3
        @($data.Days)[1].Publishes | Should -Be 0
        $data.SilentDays | Should -Be 1
    }

    It 'says how long the strip has been sitting untouched' {
        $lines = @(Get-NewsReportHighlights -Data @{
                LastPublishedAt = [datetime]'2026-08-31T18:00'; SilentDays = 2
            } -Now ([datetime]'2026-08-31T21:00'))

        @($lines | Where-Object { $_ -match 'منذ 3 ساعة' }).Count | Should -Be 1
        @($lines | Where-Object { $_ -match 'أيام بلا نشرة: 2' }).Count | Should -Be 1
    }

    It 'says nothing was published rather than pretending to a last time' {
        @(Get-NewsReportHighlights -Data @{ LastPublishedAt = $null; SilentDays = 7 })[0] |
            Should -Match 'لم تُنشر'
    }
}

Describe 'A ten-edit day has to stay readable' {
    BeforeAll {
        $script:BusyDay = @{
            Label = 'اليوم'; Publishes = 10; Items = 16; Truncated = $false; SilentDays = 0
            LastPublishedAt = [datetime]'2026-08-31T22:10'
            Days = @(@{
                    Date = [datetime]'2026-08-31'; Publishes = 10; Items = 16
                    Counts = @(12, 13, 15, 14, 16, 15, 17, 18, 17, 16)
                    First = [datetime]'2026-08-31T06:00'; Last = [datetime]'2026-08-31T22:10'
                    Tally = @{ Breakdown = 'سامي 6 · ليلى 4'; Single = '' }
                })
        }
    }

    It 'keeps the table to four short columns whatever the day did' {
        # Telegram divides a table's width evenly, so a sixth column gets a
        # sixth of a phone screen - the same mistake as a row of six buttons.
        Mock Get-NewsReportDays { $script:BusyDay }

        $table = @(@(Get-NewsReportBlocks -Period today) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[0]).Count | Should -Be 4
        foreach ($row in @($table.cells)) { @($row).Count | Should -Be 4 }
        foreach ($cell in @($table.cells[1])) { $cell.text.Length | Should -BeLessOrEqual 12 }
    }

    It 'holds ten readings in a range rather than a column of numbers' {
        Get-NewsCountRange -Counts @(12, 13, 15, 14, 16, 15, 17, 18, 17, 16) | Should -Be '12–18'
        Get-NewsCountRange -Counts @(9, 9, 9) | Should -Be '9'
        Get-NewsCountRange -Counts @() | Should -Be '—'
    }

    It 'puts the readings, the span and the operators where the width is' {
        Mock Get-NewsReportDays { $script:BusyDay }

        $blocks = @(Get-NewsReportBlocks -Period today)
        $details = @($blocks | Where-Object { $_.type -eq 'details' })[0]
        $texts = @($details.blocks | ForEach-Object { $_.text })

        $details.summary | Should -Match 'تفاصيل'
        @($texts | Where-Object { $_ -match '06:00 ← 22:10' }).Count | Should -Be 1
        @($texts | Where-Object { $_ -match 'سامي 6' }).Count | Should -Be 1
        @($texts | Where-Object { $_ -match '12 ← 13 ← 15' }).Count | Should -Be 1
    }

    It 'shows every one of the ten readings, not the first six' {
        # The trail is capped for the table's sake, not the detail's.
        Get-NewsEditTrail -Counts @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) -Max 24 |
            Should -Be '1 ← 2 ← 3 ← 4 ← 5 ← 6 ← 7 ← 8 ← 9 ← 10'
    }

    It 'folds nothing away for a period with no edits at all' {
        Mock Get-NewsReportDays { @{ Label = 'أمس'; Publishes = 0; Items = 0; Truncated = $false; SilentDays = 1; LastPublishedAt = $null; Days = @() } }

        @(@(Get-NewsReportBlocks -Period yesterday) | Where-Object { $_.type -eq 'details' }).Count | Should -Be 0
    }
}

Describe 'The banner table gives its width to the name' {
    It 'carries the layer on the banner cell instead of spending a column on one digit' {
        Mock Get-BannerReportData {
            @{ Label = 'اليوم'; Operators = 1; Truncated = $false; Sessions = @(
                    @{ UserId = 10; Layer = 7; Target = 'urgent'; Values = 'نص'
                        StartedAt = '2026-08-31T21:00:00'; EndedAt = '2026-08-31T21:05:00' }
                ) }
        }
        Mock Get-AuditOperatorName { 'سامي' }

        $table = @(@(Get-BannerReportBlocks -Period today) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[0]).Count | Should -Be 4
        @($table.cells[1])[0].text | Should -Be 'urgent · ط7'
    }
}

Describe 'The banner copy is kept, below the table' {
    It 'folds the on-air text under the report instead of dropping it' {
        # No column in a four-column table is wide enough for a sentence, but
        # the copy is what an operator recognises a banner by.
        Mock Get-BannerReportData {
            @{ Label = 'اليوم'; Operators = 1; Truncated = $false; Sessions = @(
                    @{ UserId = 10; Layer = 7; Target = 'urgent'; Values = 'عاجل: بيان الوزارة'
                        StartedAt = '2026-08-31T21:00:00'; EndedAt = '2026-08-31T21:05:00' }
                    @{ UserId = 10; Layer = 8; Target = 'ticker'; Values = ''
                        StartedAt = '2026-08-31T22:00:00'; EndedAt = $null }
                ) }
        }
        Mock Get-AuditOperatorName { 'سامي' }

        $details = @(@(Get-BannerReportBlocks -Period today) | Where-Object { $_.type -eq 'details' })[0]

        $details.summary | Should -Match 'نصوص البنرات \(1\)'
        @($details.blocks)[0].text | Should -Match 'عاجل: بيان الوزارة'
    }
}

Describe 'The bulletin report' {
    BeforeAll {
        # Anchored to now, never to a fixed hour of the day. Placing a
        # record at "today at 10:00" puts it in the FUTURE when the suite runs
        # in the morning, and the report window ends at now - so the record
        # vanished and these tests passed at night and failed at 09:47.
        function global:Get-TestReportAnchor {
            param([int]$MinutesAgo = 180)
            $at = (Get-Date).AddMinutes(-1 * $MinutesAgo)
            $startOfDay = (Get-Date).Date.AddMinutes(1)
            if ($at -lt $startOfDay) { return $startOfDay }
            return $at
        }

        function global:New-TestMojazAudit {
            param([string]$Operation, [string]$Action, [datetime]$At, [string]$Name = 'موجز المساء',
                [int]$Count = 3, [long]$DurationMs = 0, [string]$Values = 'manual', [string]$UserId = '42')
            [pscustomobject]@{
                timestampUtc = $At.ToUniversalTime().ToString('o'); operationId = $Operation
                event = 'mojaz_run'; action = $Action; result = $(if ($Action -eq 'START') { 'started' } else { 'completed' })
                userId = $UserId; target = $Name; count = $Count; durationMs = $DurationMs; values = $Values
            }
        }
    }

    It 'says so quietly when nothing ran, instead of throwing' {
        # The bug: Measure-Object over an empty collection returns an object
        # with no Sum, and StrictMode throws on reading it - so the report
        # failed to open on every period with no bulletin in it, which is
        # every quiet day. This file's own header warns about that trap.
        Mock Read-AuditRecords { @() }

        $blocks = @(Get-MojazReportBlocks -Period today)
        $blocks[0].text | Should -Match 'تقرير الموجزات'
        $blocks[1].text | Should -Match 'لم يُشغَّل أي موجز'
        Get-MojazReportText -Period today | Should -Match 'لم يُشغَّل أي موجز'
    }

    It 'pairs a run start with its end by operation id' {
        $start = Get-TestReportAnchor -MinutesAgo 90
        Mock Read-AuditRecords {
            @(
                (New-TestMojazAudit -Operation 'mojaz-a' -Action START -At $start -Count 4)
                (New-TestMojazAudit -Operation 'mojaz-a' -Action END -At $start.AddMinutes(6) -Count 4 -DurationMs 360000)
            )
        }

        $data = Get-MojazReportData -Period today
        @($data.Runs).Count | Should -Be 1
        $data.Runs[0].Rows | Should -Be 4
        $data.Rows | Should -Be 4
        $data.Runs[0].EndedAt | Should -Not -BeNullOrEmpty
    }

    It 'says a run with no end is still on air rather than dropping it' {
        Mock Read-AuditRecords { @((New-TestMojazAudit -Operation 'mojaz-b' -Action START -At (Get-TestReportAnchor -MinutesAgo 60))) }

        $data = Get-MojazReportData -Period today
        @($data.Runs).Count | Should -Be 1
        Get-MojazRunDuration -Run $data.Runs[0] | Should -Match 'على الهواء'
    }

    It 'keeps two runs of the same bulletin apart' {
        # Without the operation id they collapsed into one row, because the
        # bulletin name and the row count are identical in both.
        $start = Get-TestReportAnchor -MinutesAgo 120
        Mock Read-AuditRecords {
            @(
                (New-TestMojazAudit -Operation 'mojaz-a' -Action START -At $start)
                (New-TestMojazAudit -Operation 'mojaz-a' -Action END -At $start.AddMinutes(5) -DurationMs 300000)
                (New-TestMojazAudit -Operation 'mojaz-b' -Action START -At $start.AddMinutes(40) -Values 'scheduled')
                (New-TestMojazAudit -Operation 'mojaz-b' -Action END -At $start.AddMinutes(44) -DurationMs 240000 -Values 'scheduled')
            )
        }

        $data = Get-MojazReportData -Period today
        @($data.Runs).Count | Should -Be 2
        $data.Scheduled | Should -Be 1
        # Ordered by when they started, not by the order the log holds them.
        $data.Runs[0].StartedAt | Should -BeLessThan $data.Runs[1].StartedAt
    }
}

Describe 'Work report' {
    BeforeEach {
        # One refused operator, one operator the engine failed, so the two can
        # be told apart - which is the whole point of counting them separately.
        $stamp = { param($MinutesAgo) (Get-Date).ToUniversalTime().AddMinutes(-$MinutesAgo).ToString('o') }
        Mock Read-AuditRecords {
            @(
                [pscustomobject]@{ timestampUtc = (& $stamp 50); event = 'air_control'; action = 'SHOW'; result = 'success'; userId = '42'; target = 'عاجل'; layer = '4' }
                [pscustomobject]@{ timestampUtc = (& $stamp 40); event = 'air_control'; action = 'SHOW'; result = 'success'; userId = '42'; target = 'عاجل'; layer = '4' }
                [pscustomobject]@{ timestampUtc = (& $stamp 30); event = 'air_control'; action = 'HIDE'; result = 'success'; userId = '42'; target = 'عاجل'; layer = '4' }
                [pscustomobject]@{ timestampUtc = (& $stamp 20); event = 'air_control'; action = 'SHOW'; result = 'blocked'; userId = '42'; target = 'News-Ticker'; layer = '8' }
                [pscustomobject]@{ timestampUtc = (& $stamp 10); event = 'air_control'; action = 'SHOW'; result = 'failed'; userId = '77'; target = 'شعار'; layer = '2' }
            )
        }
    }

    It 'counts a refusal apart from an engine failure' {
        # Merged, a shift of permission refusals read exactly like a shift of
        # Cinegy errors, and the two need opposite responses.
        $data = Get-WorkReportData -Period today
        $ahmed = @($data.People | Where-Object { $_.UserId -eq '42' })[0]
        $ahmed.Blocked | Should -Be 1
        $ahmed.Failed | Should -Be 0

        $mohammed = @($data.People | Where-Object { $_.UserId -eq '77' })[0]
        $mohammed.Blocked | Should -Be 0
        $mohammed.Failed | Should -Be 1
    }

    It 'counts only the shows that actually reached air' {
        $ahmed = @((Get-WorkReportData -Period today).People | Where-Object { $_.UserId -eq '42' })[0]
        # Four operations, three of them successful, but a hide is not air time
        # and the blocked show never left the building.
        $ahmed.Total | Should -Be 4
        $ahmed.OnAir | Should -Be 2
    }

    It 'names the template the operator spent the shift on' {
        $ahmed = @((Get-WorkReportData -Period today).People | Where-Object { $_.UserId -eq '42' })[0]
        $ahmed.TopTarget | Should -Be 'عاجل'
    }

    It 'adds every operator up so the shift has one number' {
        $totals = (Get-WorkReportData -Period today).Totals
        $totals.Operators | Should -Be 2
        $totals.Total | Should -Be 5
        $totals.OnAir | Should -Be 2
        $totals.Blocked | Should -Be 1
        $totals.Failed | Should -Be 1
    }

    It 'stays silent about problems that did not happen' {
        # A "0 blocked, 0 failed" on every clean line teaches the reader to
        # skip the symbols that matter on the line that is not clean.
        Get-WorkReportProblemSuffix -Blocked 0 -Failed 0 | Should -BeExactly ''
        Get-WorkReportProblemSuffix -Blocked 2 -Failed 0 | Should -Match 'مرفوضة'
        Get-WorkReportProblemSuffix -Blocked 2 -Failed 0 | Should -Not -Match 'فاشلة'
        Get-WorkReportProblemSuffix -Blocked 0 -Failed 3 | Should -Match 'فاشلة'
    }

    It 'shows the operator what they did, not just how much' {
        $text = Get-WorkReportText -Period today
        $text | Should -Match 'على الهواء'
        $text | Should -Match 'الأكثر: عاجل'
        $text | Should -Match 'الإجمالي:'
        $text | Should -Match 'مرفوضة'
    }

    It 'says so plainly when nobody touched the air' {
        Mock Read-AuditRecords { @() }
        Get-WorkReportText -Period today | Should -Match 'لا توجد عمليات'
    }

    It 'gives the table the same numbers as the text' {
        $blocks = @(Get-WorkReportBlocks -Period today)
        $table = @($blocks | Where-Object { $_.type -eq 'table' })[0]
        $table | Should -Not -BeNullOrEmpty
        # Header, two operators, and a totals row.
        @($table.cells).Count | Should -Be 4
        @($table.cells)[0].Count | Should -Be 7
    }
}
