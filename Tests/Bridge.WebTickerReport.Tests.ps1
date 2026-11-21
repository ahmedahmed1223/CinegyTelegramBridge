. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

function global:New-TickerReportFixtureRecord {
    param([string]$Actor, [datetime]$When, [int]$Items)
    [pscustomobject]@{
        event = 'news_publish'; operationId = [guid]::NewGuid().ToString('N'); userId = $Actor
        timestampUtc = $When.ToUniversalTime().ToString('o'); action = 'PUBLISH'; count = $Items
        target = 'C:\private\ticker.txt'; values = 'Unpublished editorial fixture'
        message = 'http://internal.example/private.txt'
    }
}

Describe 'The Web ticker report' {
    BeforeEach {
        $script:TickerReportNow = [datetime]::new(2026, 3, 10, 9, 0, 0, [DateTimeKind]::Local)
        $script:TickerReportRecords = [System.Collections.Generic.List[object]]::new()
        Mock Get-Date { $script:TickerReportNow }
        Mock Read-AuditRecords { $script:TickerReportRecords }
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4322 }
        Mock Get-AuditOperatorName {
            if ($UserId -eq '4321') { return '<img data-label="Ticker desk">' }
            if ($UserId -eq '4322') { return 'C:\private\supervisor.txt' }
            return [string]$UserId
        }
        $script:TickerReportRecords.Add((New-TickerReportFixtureRecord -Actor 4321 -When $script:TickerReportNow.AddMinutes(-60) -Items 8))
        $script:TickerReportRecords.Add((New-TickerReportFixtureRecord -Actor 4321 -When $script:TickerReportNow.AddMinutes(-55) -Items 11))
        $script:TickerReportRecords.Add((New-TickerReportFixtureRecord -Actor 4322 -When $script:TickerReportNow.AddMinutes(-50) -Items 5))
        $script:TickerReportRecords.Add((New-TickerReportFixtureRecord -Actor 4433 -When $script:TickerReportNow.AddMinutes(-40) -Items 4))
        $script:TickerReportRecords.Add((New-TickerReportFixtureRecord -Actor 4322 -When $script:TickerReportNow.Date.AddMinutes(-5) -Items 3))
        $script:TickerReportRecords.Add((New-TickerReportFixtureRecord -Actor 4321 -When $script:TickerReportNow.AddDays(-32) -Items 99))
    }

    It 'uses the Bot reader, final item counts and same operator scope' {
        $own = Invoke-WebChannelOperation -Request @{ op = 'reports.ticker'; args = @{ actor = 4321; period = 'today' } }
        $own.ok | Should -BeTrue
        $own.data.scope | Should -Be 'mine'
        $own.data.publishes | Should -Be 2
        $own.data.items | Should -Be 11
        $own.data.days[0].edits | Should -Be '8 ← 11'
        $own.data.days[0].range | Should -Be '8–11'
        $all = Invoke-WebChannelOperation -Request @{ op = 'reports.ticker'; args = @{ actor = 4322; period = 'today' } }
        $bot = Get-NewsReportDays -Period today
        $all.data.scope | Should -Be 'all'
        $all.data.publishes | Should -Be $bot.Publishes
        $all.data.items | Should -Be 4
        $all.data.items | Should -Be $bot.Items
        $all.data.days[0].operators | Should -Be '<img data-label="Ticker desk"> 2'
        (Invoke-WebChannelOperation -Request @{ op = 'reports.ticker'; args = @{ actor = 4321; action = 'export'; scope = 'all' } }).error |
            Should -Be 'forbidden'
        (Invoke-WebChannelOperation -Request @{ op = 'reports.ticker'; args = @{ actor = 9999 } }).error | Should -Be 'forbidden'
        (Invoke-WebChannelOperation -Request @{ op = 'reports.ticker'; args = @{ actor = 4322; period = 'custom' } }).error | Should -Be 'report_invalid'
    }

    It 'fills silent station days and bounds both the daily edit trail and month export' {
        $yesterday = Invoke-WebChannelOperation -Request @{ op = 'reports.ticker'; args = @{ actor = 4321; period = 'yesterday' } }
        $yesterday.data.days[0].date | Should -Be '2026-03-09'
        $yesterday.data.days[0].publishes | Should -Be 0
        $yesterday.data.silentDays | Should -Be 1
        $yesterday.data.lastPublishedAt | Should -Be ''
        for ($index = 0; $index -lt 10; $index++) {
            $script:TickerReportRecords.Add((New-TickerReportFixtureRecord -Actor 4321 -When $script:TickerReportNow.AddMinutes(-10 + $index) -Items $index))
        }
        $month = Invoke-WebChannelOperation -Request @{ op = 'reports.ticker'; args = @{ actor = 4321; period = 'month' } }
        $month.data.days.Count | Should -Be 30
        $month.data.silentDays | Should -Be 29
        $month.data.items | Should -Be 9
        $month.data.publishes | Should -Be 12
        $month.data.days[-1].edits | Should -Be '… ← 4 ← 5 ← 6 ← 7 ← 8 ← 9'
        $export = Invoke-WebChannelOperation -Request @{ op = 'reports.ticker'; args = @{ actor = 4322; period = 'month'; action = 'export' } }
        $export.data.days | Should -Be 30
        $export.data.html | Should -Match '&lt;img data-label='
        $export.data.html | Should -Not -Match '<img|<script|https?://|C:\\private|Unpublished editorial|4321|4322|4433'
    }
}
