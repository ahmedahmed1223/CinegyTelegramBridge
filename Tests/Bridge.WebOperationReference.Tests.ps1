. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

function global:New-WebReferenceFixture {
    param([string]$OperationId, [string]$EventName = 'air_control', [int]$Minute = 0)
    return [pscustomobject]@{
        operationId = $OperationId; event = $EventName; timestampUtc = [datetime]::new(2026, 3, 10, 9, $Minute, 0, [DateTimeKind]::Utc).ToString('o')
        action = 'SHOW'; result = 'blocked'; layer = 7; durationMs = 12
        userId = 987654321; chatId = 123456789; userName = 'private-user'
        target = 'C:\private\title.cintitle'; message = 'Bearer sensitive-fixture-token'; values = 'private copy'
    }
}

Describe 'Exact Web operation reference lookup' {
    BeforeEach {
        $script:ReferenceFixtureId = 'air-5023333b032c476eb48204ca08032a98'
        $script:ReferenceFixtureRows = @(
            (New-WebReferenceFixture -OperationId $script:ReferenceFixtureId)
            (New-WebReferenceFixture -OperationId $script:ReferenceFixtureId -Minute 1)
            (New-WebReferenceFixture -OperationId 'air-5023333bcc2c476eb48204ca08032a98' -EventName 'activity')
        )
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-Admin { $UserId -eq 4322 }
        Mock Read-AuditRecords { $script:ReferenceFixtureRows }
        Mock Find-OperationByReference { throw 'The Web lookup must not read runtime log lines.' }
    }

    It 'checks role and format before any audit read' {
        (Get-WebOperationReferenceLookup -Arguments @{ actor = 4321; reference = '5023333b' }).error | Should -Be 'forbidden'
        (Get-WebOperationReferenceLookup -Arguments @{ actor = 4322; reference = '5023*' }).error | Should -Be 'operation_reference_invalid'
        Should -Invoke Read-AuditRecords -Times 0 -Exactly
    }

    It 'returns redacted typed results for one correlation and uses the Bot short reference in the history table' {
        $reply = Invoke-WebChannelOperation -Request @{ op = 'shift.operation-reference'; args = @{ actor = 4322; reference = ' 5023333B ' } }
        $reply.ok | Should -BeTrue
        $reply.data.status | Should -Be 'found'
        $reply.data.items.Count | Should -Be 2
        $reply.data.items[0].atMs | Should -BeGreaterThan $reply.data.items[1].atMs
        $reply.data.items[0].layer | Should -Be 7
        $reply.data.items[0].durationMs | Should -Be 12
        ($reply | ConvertTo-Json -Depth 6) | Should -Not -Match '5023333b032c|123456789|987654321|private|Bearer|token|cintitle'
        Should -Invoke Read-AuditRecords -Times 1 -Exactly -ParameterFilter { $MaxLines -eq 5000 }
        $history = ConvertTo-WebShiftHistoryItem -Record @{
            OperationId = $script:ReferenceFixtureId; Event = 'air_control'; When = [datetime]'2026-03-10T09:00:00'
            Action = 'SHOW'; Target = 'fixture'; Result = 'blocked'; UserId = ''; Layer = 7; DurationMs = 12L
        } -ShowOperator $false
        $history.reference | Should -BeExactly '5023333b'
    }

    It 'returns explicit missing and collision outcomes without leaking either match' {
        $missing = Get-WebOperationReferenceLookup -Arguments @{ actor = 4322; reference = 'f00dcafe' }
        $missing.data.status | Should -Be 'missing'
        $missing.data.items.Count | Should -Be 0
        $script:ReferenceFixtureRows += New-WebReferenceFixture -OperationId 'air-5023333bcc2c476eb48204ca08032a98'
        $collision = Get-WebOperationReferenceLookup -Arguments @{ actor = 4322; reference = '5023333b' }
        $collision.data.status | Should -Be 'collision'
        $collision.data.items.Count | Should -Be 0
    }

    It 'shows at most twenty recent records for a single distinct correlation' {
        $script:ReferenceFixtureRows = @(foreach ($minute in (0..21)) { New-WebReferenceFixture -OperationId $script:ReferenceFixtureId -Minute $minute })
        $reply = Get-WebOperationReferenceLookup -Arguments @{ actor = 4322; reference = '5023333b' }
        $reply.data.status | Should -Be 'found'
        $reply.data.items.Count | Should -Be 20
        $reply.data.truncated | Should -BeTrue
    }
}
