. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

function global:New-BulletinReportFixtureRecord {
    param([string]$Id, [string]$Actor, [datetime]$When, [string]$Action, [string]$Name, [int]$Rows, [string]$Kind)
    return [pscustomobject]@{
        event = 'mojaz_run'; operationId = $Id; userId = $Actor; timestampUtc = $When.ToUniversalTime().ToString('o')
        action = $Action; target = $Name; count = $Rows; values = $Kind; durationMs = 4200
        message = 'Editorial text fixture with an absolute path C:\private\script.txt'
    }
}

Describe 'The Web bulletin run report' {
    BeforeEach {
        $script:BulletinReportNow = [datetime]::new(2026, 3, 10, 9, 0, 0, [DateTimeKind]::Local)
        $script:BulletinReportRecords = [System.Collections.Generic.List[object]]::new()
        Mock Get-Date { $script:BulletinReportNow }
        Mock Read-AuditRecords { $script:BulletinReportRecords }
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4322 }
        Mock Get-AuditOperatorName {
            if ($UserId -eq '4321') { return '<img data-label="Operator">' }
            return 'C:\private\owner.txt'
        }
        Add-ReportFixture -At $script:BulletinReportNow.Date
    }

    It 'uses the same calendar window, operation pairing and actor rules as the Bot' {
        $mine = Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 4321; period = 'today' } }
        $mine.ok | Should -BeTrue
        $mine.data.scope | Should -Be 'mine'
        $mine.data.total | Should -Be 1
        $mine.data.rows | Should -Be 3
        $mine.data.scheduled | Should -Be 1
        $mine.data.items[0].name | Should -Be 'Morning'
        $mine.data.items[0].duration | Should -Not -BeNullOrEmpty
        $all = Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 4322; period = 'today' } }
        $shared = Get-MojazReportData -Period today
        $all.data.total | Should -Be $shared.Runs.Count
        $all.data.rows | Should -Be $shared.Rows
        $all.data.operators | Should -Be $shared.Operators
        $all.data.items[0].ended | Should -Be ''
        $all.data.items[0].name | Should -Be ''
        $all.data.items[0].operatorName | Should -Be ''
        $yesterday = Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 4322; period = 'yesterday' } }
        $yesterday.data.items[0].name | Should -Be 'Previous evening'
        $escalated = Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 4321; scope = 'all'; action = 'export' } }
        $escalated.error | Should -Be 'forbidden'
        (Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 'broken' } }).error | Should -Be 'forbidden'
        (Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 4322; period = 'custom' } }).error | Should -Be 'report_invalid'
    }

    It 'exports safe escaped HTML without audit message, raw paths, actor IDs or external elements' {
        $export = Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 4322; action = 'export' } }
        $export.ok | Should -BeTrue
        $export.data.count | Should -Be 2
        $export.data.html | Should -Match '&lt;img data-label='
        $export.data.html | Should -Not -Match '<img|<script|https?://|Editorial text|C:\\private|4321|4322'
        $export.data.html | Should -Match 'Morning'
    }

    It 'pages report runs independently of the export cap and reports both exact counts' {
        for ($index = 0; $index -lt 101; $index++) {
            $script:BulletinReportRecords.Add((New-BulletinReportFixtureRecord -Id "extra-$index" -Actor 4321 `
                    -When $script:BulletinReportNow.AddMinutes(-105 + $index) -Action START -Name "Run-$index" -Rows 1 -Kind manual))
        }
        $page = Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 4321; page = 5 } }
        $page.data.total | Should -Be 102
        $page.data.items.Count | Should -Be 2
        $page.data.pageCount | Should -Be 6
        $export = Invoke-WebChannelOperation -Request @{ op = 'reports.bulletins'; args = @{ actor = 4321; action = 'export' } }
        $export.data.count | Should -Be 100
        $export.data.total | Should -Be 102
        $export.data.truncated | Should -BeTrue
        $export.data.html | Should -Not -Match 'Run-0\b'
    }
}

function global:Add-ReportFixture {
    param([datetime]$At)
    $script:BulletinReportRecords.Add((New-BulletinReportFixtureRecord -Id 'yesterday' -Actor 4321 `
            -When $At.AddMinutes(-5) -Action START -Name 'Previous evening' -Rows 2 -Kind manual))
    $script:BulletinReportRecords.Add((New-BulletinReportFixtureRecord -Id 'own' -Actor 4321 `
            -When $At.AddHours(1) -Action START -Name 'Morning' -Rows 3 -Kind scheduled))
    $script:BulletinReportRecords.Add((New-BulletinReportFixtureRecord -Id 'own' -Actor 4321 `
            -When $At.AddHours(1).AddSeconds(4) -Action END -Name 'Morning' -Rows 3 -Kind scheduled))
    $script:BulletinReportRecords.Add((New-BulletinReportFixtureRecord -Id 'other' -Actor 4322 `
            -When $At.AddHours(2) -Action START -Name 'C:\private\title.png' -Rows 2 -Kind manual))
}
