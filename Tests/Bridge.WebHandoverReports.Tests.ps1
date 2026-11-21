. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

function global:New-HandoverFixtureRecord {
    param([string]$EventName, [string]$Action, [string]$Result, [datetime]$When, [string]$Target, [string]$Message)
    [pscustomobject]@{
        event = $EventName; userId = '54321'; timestampUtc = $When.ToUniversalTime().ToString('o')
        action = $Action; target = $Target; layer = 4; result = $Result
        values = 'unpublished editorial fixture'; message = $Message
    }
}

Describe 'Web weekly and shift handover reporting' {
    BeforeEach {
        $script:HandoverFixtureNow = [datetime]::new(2026, 3, 10, 9, 0, 0, [DateTimeKind]::Local)
        $script:HandoverOriginalAir = $script:OnAir
        $script:HandoverOriginalAlerts = $script:AlertHistory
        $script:OnAir = @{ 4 = @{ Key = 'Lower third' }; 9 = @{ Key = 'C:\private\layer.cintitle' } }
        $script:AlertHistory = @{ 'private-alert-note' = @($script:HandoverFixtureNow.AddHours(-1), $script:HandoverFixtureNow.AddMinutes(-5)) }
        $script:HandoverFixtureRecords = [System.Collections.Generic.List[object]]::new()
        Mock Get-Date { $script:HandoverFixtureNow }
        Mock Read-AuditRecords { $script:HandoverFixtureRecords }
        Mock Test-Authorized { $UserId -eq 4321 }
        Mock Test-Admin { throw 'The two Bot reports are available to ordinary operators.' }
        Mock Get-SettingInt -ParameterFilter { $Name -eq 'MissedEventsHours' } { 4 }
        Mock Get-OperatorConnectionSummary { 'Cinegy: healthy · Telegram: connected' }
        Mock Get-AuditOperatorName { 'Graphics desk' }
        Mock Get-RichPayloadPeak { @{ Screen = 'Get-WeeklyReportBlocks'; Percent = 80 } }
        Mock Get-TemplateStore { @{ Map = @{ Unused = @{} } } }
    }

    AfterEach {
        $script:OnAir = $script:HandoverOriginalAir
        $script:AlertHistory = $script:HandoverOriginalAlerts
    }

    It 'rejects unauthorized actors before reading either report' {
        (Invoke-WebChannelOperation -Request @{ op = 'reports.weekly'; args = @{ actor = 9999 } }).error | Should -Be 'forbidden'
        (Invoke-WebChannelOperation -Request @{ op = 'reports.handover'; args = @{ actor = 'x' } }).error | Should -Be 'forbidden'
        Should -Invoke Read-AuditRecords -Times 0 -Exactly
    }

    It 'projects Bot weekly metrics for operators without sending raw alert causes or editorial data' {
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord news_publish PUBLISH success $script:HandoverFixtureNow.AddDays(-1)))
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord urgent_board_run START success $script:HandoverFixtureNow.AddDays(-1)))
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord urgent_board_run STOP success $script:HandoverFixtureNow.AddHours(-1)))
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord news_publish PUBLISH success $script:HandoverFixtureNow.AddDays(-9)))
        $result = Invoke-WebChannelOperation -Request @{ op = 'reports.weekly'; args = @{ actor = 4321 } }
        $result.ok | Should -BeTrue
        $shared = Get-WeeklyReportData
        $result.data.tickerPublishes | Should -Be $shared.TickerPublishes
        $result.data.tickerPublishes | Should -Be 1
        $result.data.urgentRuns | Should -Be 1
        $result.data.urgentStories | Should -Be 1
        $result.data.idle[0] | Should -Match 'Unused'
        $result.data.peakPercent | Should -Be 80
        $result.data.repeatCounts[0] | Should -Be 2
        ($result | ConvertTo-Json -Depth 6) | Should -Not -Match 'private-alert-note|editorial fixture|54321'
    }

    It 'uses the configured Bot handover window and bounded source with safe summaries' {
        $old = New-HandoverFixtureRecord air_control SHOW success $script:HandoverFixtureNow.AddHours(-5) 'Outside window'
        for ($index = 0; $index -lt 1494; $index++) { $script:HandoverFixtureRecords.Add($old) }
        $start = $script:HandoverFixtureNow.AddHours(-2)
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord air_control SHOW success $start 'Lower third'))
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord air_control SHOW success $start.AddMinutes(5) 'Lower third'))
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord air_control HIDE success $start.AddMinutes(6)))
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord air_control EXIT failed $start.AddMinutes(7) 'C:\private\fail.cintitle' 'Private failure on http://internal'))
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord air_control SHOW blocked $start.AddMinutes(8)))
        $script:HandoverFixtureRecords.Add((New-HandoverFixtureRecord -EventName activity -Result success -When $start.AddMinutes(9) -Message '📰 private headline'))
        $result = Invoke-WebChannelOperation -Request @{ op = 'reports.handover'; args = @{ actor = 4321 } }
        $result.ok | Should -BeTrue
        $result.data.hours | Should -Be 4
        $result.data.truncated | Should -BeTrue
        $result.data.activeCount | Should -Be 2
        $result.data.active[0].name | Should -Be 'Lower third'
        $result.data.showCount | Should -Be 2
        $result.data.shows[0].operators | Should -Be 'Graphics desk'
        $result.data.removalCount | Should -Be 2
        $result.data.failureCount | Should -Be 1
        $result.data.blockedCount | Should -Be 1
        $result.data.notableCount | Should -Be 1
        $result.data.recentFailures[0].action | Should -Be 'EXIT'
        ($result | ConvertTo-Json -Depth 6) | Should -Not -Match 'Outside window|private|http://|54321|editorial'
        @(Get-MissedEventsRecords -Hours 4).Count | Should -Be 6
    }
}
