. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

function global:New-TemplateReportFixtureRecord {
    param([string]$Actor, [datetime]$When, [string]$Action, [int]$Layer, [string]$Target, [string]$Result = 'success')
    [pscustomobject]@{
        event = 'air_control'; userId = $Actor; timestampUtc = $When.ToUniversalTime().ToString('o')
        action = $Action; target = $Target; layer = $Layer; result = $Result
        values = 'Broadcast editorial fixture C:\private\copy.txt'
        message = 'http://internal.example/fixture'
    }
}

Describe 'The Web template display report' {
    BeforeEach {
        $script:TemplateReportNow = [datetime]::new(2026, 3, 10, 9, 0, 0, [DateTimeKind]::Local)
        $script:TemplateReportRecords = [System.Collections.Generic.List[object]]::new()
        Mock Get-Date { $script:TemplateReportNow }
        Mock Read-AuditRecords { $script:TemplateReportRecords }
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4322 }
        Mock Get-AuditOperatorName {
            if ($UserId -eq '4321') { return '<img data-label="Graphics desk">' }
            if ($UserId -eq '4322') { return 'C:\private\supervisor.txt' }
            return [string]$UserId
        }
        $at = $script:TemplateReportNow.Date.AddHours(7)
        $script:TemplateReportRecords.Add((New-TemplateReportFixtureRecord -Actor 4321 -When $at -Action SHOW -Layer 4 -Target 'Lower third'))
        $script:TemplateReportRecords.Add((New-TemplateReportFixtureRecord -Actor 4322 -When $at.AddMinutes(2) -Action SHOW -Layer 4 -Target 'C:\scenes\replacement.cintitle'))
        $script:TemplateReportRecords.Add((New-TemplateReportFixtureRecord -Actor 4321 -When $at.AddMinutes(5) -Action EXIT -Layer 4 -Target 'exit'))
        $script:TemplateReportRecords.Add((New-TemplateReportFixtureRecord -Actor 4322 -When $at.AddMinutes(7) -Action SHOW -Layer 5 -Target 'Graphics board'))
        $script:TemplateReportRecords.Add((New-TemplateReportFixtureRecord -Actor 4321 -When $at.AddMinutes(7) -Action SHOW -Layer 6 -Target 'Failed show' -Result failed))
        $script:TemplateReportRecords.Add((New-TemplateReportFixtureRecord -Actor 4321 -When $at.Date.AddMinutes(-5) -Action SHOW -Layer 1 -Target 'Yesterday'))
    }

    It 'pairs layer events before filtering by operator and keeps the Bot calendar periods' {
        $own = Invoke-WebChannelOperation -Request @{ op = 'reports.templates'; args = @{ actor = 4321; period = 'today' } }
        $own.ok | Should -BeTrue
        $own.data.scope | Should -Be 'mine'
        $own.data.total | Should -Be 1
        $own.data.withoutEnd | Should -Be 0
        $own.data.items[0].name | Should -Be 'Lower third'
        $own.data.items[0].layer | Should -Be 4
        $own.data.items[0].endedBy | Should -Be (T 'rep.replacement')
        $own.data.items[0].ended | Should -Match '07:02:00'
        $all = Invoke-WebChannelOperation -Request @{ op = 'reports.templates'; args = @{ actor = 4322; period = 'today' } }
        $bot = Get-BannerReportData -Period today
        $all.data.total | Should -Be $bot.Sessions.Count
        $all.data.operators | Should -Be $bot.Operators
        $all.data.withoutEnd | Should -Be 1
        $all.data.items[1].endedBy | Should -Be (T 'rep.op.exit')
        $all.data.items[1].name | Should -Be ''
        $all.data.items[1].operatorName | Should -Be ''
        (Invoke-WebChannelOperation -Request @{ op = 'reports.templates'; args = @{ actor = 4321; period = 'yesterday' } }).data.items[0].name |
            Should -Be 'Yesterday'
        (Invoke-WebChannelOperation -Request @{ op = 'reports.templates'; args = @{ actor = 4321; scope = 'all'; action = 'export' } }).error |
            Should -Be 'forbidden'
        (Invoke-WebChannelOperation -Request @{ op = 'reports.templates'; args = @{ actor = 4322; period = 'invalid' } }).error |
            Should -Be 'report_invalid'
    }

    It 'bounds the export and excludes banner copy, paths and raw operator IDs' {
        for ($index = 0; $index -lt 101; $index++) {
            $script:TemplateReportRecords.Add((New-TemplateReportFixtureRecord -Actor 4321 -When $script:TemplateReportNow.AddMinutes(-110 + $index) `
                    -Action SHOW -Layer 7 -Target "Extra-$index"))
        }
        $own = Invoke-WebChannelOperation -Request @{ op = 'reports.templates'; args = @{ actor = 4321; page = 5 } }
        $own.data.total | Should -Be 102
        $own.data.items.Count | Should -Be 2
        $export = Invoke-WebChannelOperation -Request @{ op = 'reports.templates'; args = @{ actor = 4322; action = 'export' } }
        $export.ok | Should -BeTrue
        $export.data.total | Should -Be 104
        $export.data.count | Should -Be 100
        $export.data.truncated | Should -BeTrue
        $export.data.html | Should -Match '&lt;img data-label='
        $export.data.html | Should -Not -Match '<img|<script|Broadcast editorial|C:\\private|cintitle|http://|4321|4322|Extra-0\b'
        (Get-BannerReportHtml -Period today) | Should -Match 'Broadcast editorial fixture'
    }
}
