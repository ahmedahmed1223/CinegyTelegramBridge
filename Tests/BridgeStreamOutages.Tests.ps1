BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules\BridgeStreamOutages.psm1') -Force
    Set-StrictMode -Version Latest
    $script:T0 = [datetime]'2026-09-22T10:00:00'
}

Describe 'Opening an outage' {
    It 'records when the feed went, and why' {
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0 -Cause 'the server is not answering' | Out-Null

        @($ledger.Outages).Count | Should -Be 1
        $ledger.Outages[0].Kind | Should -Be 'unreachable'
        $ledger.Outages[0].Cause | Should -Be 'the server is not answering'
        $ledger.Outages[0].EndedAt | Should -BeNullOrEmpty
    }

    It 'files one outage however many times the watchdog says it is down' {
        # The watchdog runs once per failed capture, and a source that is down
        # stays down. Without this an hour of trouble reads as sixty outages
        # and buries the screen it was meant to fill.
        $ledger = New-BridgeOutageLedger
        foreach ($minute in 0..20) {
            Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0.AddMinutes($minute) | Out-Null
        }
        @($ledger.Outages).Count | Should -Be 1
        $ledger.Outages[0].StartedAt | Should -Be $script:T0.ToString('o') -Because 'the outage began at the first failure, not the last'
    }

    It 'takes a later cause over the first one' {
        # "the server is not answering" is worth more than the timeout that
        # preceded it, and the diagnosis arrives after the first failure.
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0 -Cause 'a timeout' | Out-Null
        Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0.AddMinutes(2) -Cause 'the server is not answering' | Out-Null

        $ledger.Outages[0].Cause | Should -Be 'the server is not answering'
    }

    It 'keeps a black screen and an unreachable source apart' {
        # A source that dies mid-fade is both at once, and closing one on the
        # other's recovery would file a two-second fade as a four-hour outage.
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0 | Out-Null
        Open-BridgeOutage -Ledger $ledger -Kind 'black' -At $script:T0.AddMinutes(1) | Out-Null

        @($ledger.Outages).Count | Should -Be 2
        Close-BridgeOutage -Ledger $ledger -Kind 'black' -At $script:T0.AddMinutes(2) | Out-Null
        (Get-BridgeOpenOutage -Ledger $ledger -Kind 'unreachable') | Should -Not -BeNullOrEmpty
        (Get-BridgeOpenOutage -Ledger $ledger -Kind 'black') | Should -BeNullOrEmpty
    }
}

Describe 'Closing an outage' {
    It 'records when the feed came back' {
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0 | Out-Null
        $closed = Close-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0.AddMinutes(7)

        $closed.EndedAt | Should -Not -BeNullOrEmpty
        Get-BridgeOutageDurationSeconds -Outage $closed | Should -Be 420
    }

    It 'says nothing when a recovery follows no outage' {
        # The ordinary case on a healthy channel: every successful capture
        # passes through the recovery path.
        $ledger = New-BridgeOutageLedger
        Close-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0 | Should -BeNullOrEmpty
    }

    It 'never files an outage that ended before it began' {
        # A clock corrected backwards while the feed was down. Without this
        # every reader of the ledger would have to defend itself.
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0 | Out-Null
        $closed = Close-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0.AddMinutes(-5)

        Get-BridgeOutageDurationSeconds -Outage $closed | Should -Be 0
    }

    It 'measures an outage that is still running up to now' {
        $ledger = New-BridgeOutageLedger
        $outage = Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0
        Get-BridgeOutageDurationSeconds -Outage $outage -Now $script:T0.AddMinutes(3) | Should -Be 180
    }
}

Describe 'Trimming the ledger' {
    It 'keeps the newest few' {
        $ledger = New-BridgeOutageLedger
        foreach ($i in 1..60) {
            Open-BridgeOutage -Ledger $ledger -Kind "k$i" -At $script:T0.AddMinutes(-$i) | Out-Null
            Close-BridgeOutage -Ledger $ledger -Kind "k$i" -At $script:T0.AddMinutes(-$i).AddSeconds(30) | Out-Null
        }
        Limit-BridgeOutageLedger -Ledger $ledger -Keep 40 -WindowDays 30 -Now $script:T0 | Out-Null
        @($ledger.Outages).Count | Should -Be 40
    }

    It 'drops anything older than the window even when there are few of them' {
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'old' -At $script:T0.AddDays(-45) | Out-Null
        Close-BridgeOutage -Ledger $ledger -Kind 'old' -At $script:T0.AddDays(-45).AddMinutes(1) | Out-Null
        Open-BridgeOutage -Ledger $ledger -Kind 'recent' -At $script:T0.AddDays(-1) | Out-Null
        Close-BridgeOutage -Ledger $ledger -Kind 'recent' -At $script:T0.AddDays(-1).AddMinutes(1) | Out-Null

        Limit-BridgeOutageLedger -Ledger $ledger -Keep 40 -WindowDays 30 -Now $script:T0 | Out-Null
        @($ledger.Outages).Kind | Should -Be @('recent')
    }

    It 'never drops an outage that has not ended, however old' {
        # The feed gone since Tuesday is the row an operator opens this screen
        # for. A window that discards it answers the question with silence.
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0.AddDays(-90) | Out-Null
        Limit-BridgeOutageLedger -Ledger $ledger -Keep 1 -WindowDays 7 -Now $script:T0 | Out-Null

        @($ledger.Outages).Count | Should -Be 1
        $ledger.Outages[0].EndedAt | Should -BeNullOrEmpty
    }
}

Describe 'The summary above the list' {
    It 'counts only what falls inside the window' {
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'a' -At $script:T0.AddHours(-30) | Out-Null
        Close-BridgeOutage -Ledger $ledger -Kind 'a' -At $script:T0.AddHours(-30).AddMinutes(5) | Out-Null
        Open-BridgeOutage -Ledger $ledger -Kind 'b' -At $script:T0.AddHours(-2) | Out-Null
        Close-BridgeOutage -Ledger $ledger -Kind 'b' -At $script:T0.AddHours(-2).AddMinutes(3) | Out-Null

        $summary = Get-BridgeOutageSummary -Ledger $ledger -WindowHours 24 -Now $script:T0
        $summary.Count | Should -Be 1
        $summary.TotalSeconds | Should -Be 180
    }

    It 'says when the feed was last whole' {
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'a' -At $script:T0.AddHours(-2) | Out-Null
        Close-BridgeOutage -Ledger $ledger -Kind 'a' -At $script:T0.AddHours(-1)

        (Get-BridgeOutageSummary -Ledger $ledger -Now $script:T0).LastGoodAt | Should -Be $script:T0.AddHours(-1)
    }

    It 'reports nothing rather than a date when no outage was ever recorded' {
        # "No outage is recorded" and "the feed has never worked" are not the
        # same sentence, and a bridge that started an hour ago says the first.
        (Get-BridgeOutageSummary -Ledger (New-BridgeOutageLedger) -Now $script:T0).LastGoodAt | Should -BeNullOrEmpty
    }

    It 'counts an outage still running, and measures it to now' {
        $ledger = New-BridgeOutageLedger
        Open-BridgeOutage -Ledger $ledger -Kind 'unreachable' -At $script:T0.AddMinutes(-10) | Out-Null

        $summary = Get-BridgeOutageSummary -Ledger $ledger -WindowHours 24 -Now $script:T0
        $summary.OpenCount | Should -Be 1
        $summary.TotalSeconds | Should -Be 600
    }
}
