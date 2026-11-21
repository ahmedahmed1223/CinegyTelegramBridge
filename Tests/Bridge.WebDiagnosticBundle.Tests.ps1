. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Bounded Web diagnostics bundle' {
    It 'denies anyone outside the currently authorized administrators before reading local data' {
        Mock Test-Authorized { $UserId -in 3001, 3002 }
        Mock Test-Admin { $UserId -in 3002, 3003 }
        Mock Get-BridgeDiagnosticResources { throw 'Must check actor before reading resources' }
        Mock Read-WebDiagnosticTimeline { throw 'Must check actor before reading timeline' }
        foreach ($actor in 0, 3001, 3003, 'untrusted') {
            (Get-WebDiagnosticBundle -Arguments @{ actor = $actor }).error | Should -Be 'forbidden'
        }
        Should -Invoke Get-BridgeDiagnosticResources -Times 0 -Exactly
        Should -Invoke Read-WebDiagnosticTimeline -Times 0 -Exactly
    }

    It 'reconstructs typed timeline categories without copying log text or identifiers' {
        $logFile = Join-Path $TestDrive 'safe-timeline.log'
        @(
            '2026-11-21 14:00:00 [INFO] AIR_OP id=air-1234567890abcdef1234567890abcdef action=SHOW result=blocked user=987654321 chat=987654321 target=C:\private\edits'
            '2026-11-21 14:01:00 [ERROR] Telegram unreachable https://user:password@example.invalid?token=private-query'
            '2026-11-21 14:02:00 [WARN] An unexpected warning by actor 987654321 at C:\private\something'
            '2026-11-21 14:03:00 [INFO] Unclassified editorial header private-title'
            '2026-02-29 14:00:00 [WARN] Non-existent date'
        ) | Set-Content -LiteralPath $logFile -Encoding utf8
        $timeline = Read-WebDiagnosticTimeline -Path $logFile
        $timeline.state | Should -Be 'available'
        $timeline.items.Count | Should -Be 3
        $timeline.items.category | Should -Be @('air','telegram','other')
        $timeline.items[0].action | Should -Be 'SHOW'
        $timeline.items[0].outcome | Should -Be 'blocked'
        $timeline.items[1].severity | Should -Be 'error'
        $timeline.items[2].atMs | Should -BeGreaterThan $timeline.items[1].atMs
        $timeline | ConvertTo-Json -Depth 5 | Should -Not -Match '1234567890abcdef|987654321|private|password|example\.invalid'
    }

    It 'limits both input bytes and returned events and marks unavailable logs' {
        $logFile = Join-Path $TestDrive 'oversized.log'
        $first = '2026-11-21 14:00:00 [ERROR] ' + ('x' * 150KB) + [Environment]::NewLine
        $next = ('2026-11-21 14:01:00 [WARN] Output monitor warning' + [Environment]::NewLine) * 205
        [IO.File]::WriteAllText($logFile, $first + $next)
        $timeline = Read-WebDiagnosticTimeline -Path $logFile
        $timeline.state | Should -Be 'available'
        $timeline.byteLimit | Should -Be 128KB
        $timeline.lineLimit | Should -Be 200
        $timeline.truncated | Should -BeTrue
        $timeline.items.Count | Should -Be 200
        $timeline.items[0].category | Should -Be 'feed'
        (Read-WebDiagnosticTimeline -Path (Join-Path $TestDrive 'missing.log')).state | Should -Be 'missing'
        (Read-WebDiagnosticTimeline -Path $TestDrive).state | Should -Be 'unavailable'
    }
}
