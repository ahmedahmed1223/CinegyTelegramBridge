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
        $stamp = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
        Mock Read-AuditRecords {
            @(
                [pscustomobject]@{ timestampUtc = $stamp; event = 'news_publish'; action = 'PUBLISH'; result = 'success'; userId = '42'; count = '10' }
                [pscustomobject]@{ timestampUtc = $stamp; event = 'news_publish'; action = 'PUBLISH'; result = 'success'; userId = '77'; count = '10' }
                [pscustomobject]@{ timestampUtc = $stamp; event = 'air_control'; action = 'SHOW'; result = 'success'; userId = '42'; target = 'عاجل'; layer = '4' }
            )
        }
    }

    It 'totals the items and splits the day between its publishers' {
        $text = Get-NewsReportText -Period today

        $text | Should -Match '20 خبرًا'
        $text | Should -Match '2 نشرة'
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
        @($table.cells[0] | Where-Object { $_.is_header }).Count | Should -Be 5
        @($table.cells[1])[0].text | Should -Be 'urgent'
        @($table.cells[1])[4].text | Should -Be '5 د'
    }

    It 'says a banner is still up rather than reporting a duration it does not have' {
        Mock Get-BannerReportData {
            @{ Label = 'اليوم'; Operators = 1; Truncated = $false; Sessions = @(
                    @{ UserId = 10; Layer = 7; Target = 'urgent'; Values = ''
                        StartedAt = '2026-08-31T21:00:00'; EndedAt = $null }
                ) }
        }

        $table = @(@(Get-BannerReportBlocks -Period today) | Where-Object { $_.type -eq 'table' })[0]

        @($table.cells[1])[4].text | Should -Match 'على الهواء'
    }

    It 'draws no empty table for a period with nothing in it' {
        Mock Get-BannerReportData { @{ Label = 'أمس'; Operators = 0; Truncated = $false; Sessions = @() } }

        $blocks = @(Get-BannerReportBlocks -Period yesterday)

        @($blocks | Where-Object { $_.type -eq 'table' }).Count | Should -Be 0
        @($blocks | Where-Object { $_.type -eq 'paragraph' })[0].text | Should -Match 'لم يُعرض'
    }
}
