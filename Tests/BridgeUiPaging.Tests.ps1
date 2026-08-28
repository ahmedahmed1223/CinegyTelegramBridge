#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeUiPaging.psm1') -Force
}

Describe 'Bounded Telegram page windows' {
    It 'represents an empty collection as one empty page' {
        $window = Get-BridgePageWindow -ItemCount 0 -Page 5 -PageSize 20

        $window.Page | Should -Be 0
        $window.PageCount | Should -Be 1
        $window.StartIndex | Should -Be 0
        $window.EndIndex | Should -Be -1
        $window.HasPrevious | Should -BeFalse
        $window.HasNext | Should -BeFalse
    }

    It 'calculates a middle page using absolute indexes' {
        $window = Get-BridgePageWindow -ItemCount 45 -Page 1 -PageSize 20

        $window.Page | Should -Be 1
        $window.PageCount | Should -Be 3
        $window.StartIndex | Should -Be 20
        $window.EndIndex | Should -Be 39
        $window.HasPrevious | Should -BeTrue
        $window.HasNext | Should -BeTrue
    }

    It 'clamps negative and excessive page requests' {
        (Get-BridgePageWindow -ItemCount 45 -Page -9 -PageSize 20).Page | Should -Be 0
        $last = Get-BridgePageWindow -ItemCount 45 -Page 99 -PageSize 20
        $last.Page | Should -Be 2
        $last.StartIndex | Should -Be 40
        $last.EndIndex | Should -Be 44
    }
}
