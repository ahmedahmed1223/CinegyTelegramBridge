#requires -Version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeLanguage.psm1') -Force
}

Describe 'The catalogue itself' {
    It 'has both languages, filled, for every key it holds' {
        # The whole point of holding the two beside each other: a half-finished
        # entry is a fact this test can state, not a sentence somebody has to
        # happen to notice on a screen.
        $problems = @(Test-BridgeTextCatalogue)
        $summary = @($problems | ForEach-Object { "$($_.Key) [$($_.Language)] $($_.Problem)" }) -join '; '

        $problems | Should -BeNullOrEmpty -Because "every catalogue entry must carry both languages: $summary"
    }

    It 'names the faults it is meant to catch when they are actually present' {
        # A guard nobody has seen fail is a guard nobody knows works. The three
        # shapes are a missing language, an empty string, and a translation
        # that quietly drops the number the other language fills.
        $broken = [ordered]@{
            'a' = @{ ar = 'عربي' }
            'b' = @{ ar = 'عربي'; en = '   ' }
            'c' = @{ ar = 'الطبقة {0}'; en = 'the layer' }
            'd' = @{ ar = 'سليم'; en = 'fine' }
        }

        $problems = @(Test-BridgeTextCatalogue -Catalogue $broken)

        @($problems | Where-Object { $_.Key -eq 'a' -and $_.Problem -eq 'missing' }) | Should -Not -BeNullOrEmpty
        @($problems | Where-Object { $_.Key -eq 'b' -and $_.Problem -eq 'empty' }) | Should -Not -BeNullOrEmpty
        @($problems | Where-Object { $_.Key -eq 'c' -and $_.Problem -eq 'placeholders' }) | Should -Not -BeNullOrEmpty
        @($problems | Where-Object { $_.Key -eq 'd' }) | Should -BeNullOrEmpty
    }

    It 'accepts a translation that moves the placeholder, which the two languages need' {
        $moved = [ordered]@{ 'x' = @{ ar = 'الطبقة {0} من {1}'; en = '{1} layers, showing {0}' } }

        @(Test-BridgeTextCatalogue -Catalogue $moved) | Should -BeNullOrEmpty
    }
}

Describe 'Asking for a piece of text' {
    It 'answers in the language asked for' {
        Get-BridgeText -Key 'common.home' -Language 'ar' | Should -Be '🏠 القائمة'
        Get-BridgeText -Key 'common.home' -Language 'en' | Should -Be '🏠 Menu'
    }

    It 'fills the placeholders in each language' {
        Get-BridgeText -Key 'common.layer' -Language 'en' -Arguments @(9) | Should -Be 'Layer 9'
        Get-BridgeText -Key 'common.layer' -Language 'ar' -Arguments @(9) | Should -Be 'طبقة 9'
    }

    It 'falls back to Arabic for a language it does not have' {
        Get-BridgeText -Key 'common.home' -Language 'fr' | Should -Be '🏠 القائمة'
        Get-BridgeText -Key 'common.home' -Language '' | Should -Be '🏠 القائمة'
    }

    It 'returns the key itself for a key nobody wrote' {
        # Visible, greppable, and impossible to mistake for a sentence. A blank
        # here would be a screen with a hole in it that reads as deliberate.
        Get-BridgeText -Key 'no.such.key' -Language 'en' | Should -Be 'no.such.key'
    }

    It 'remembers what it was asked for and could not answer' {
        Clear-BridgeTextMisses
        Get-BridgeText -Key 'another.missing.key' -Language 'en' | Out-Null

        Get-BridgeTextMisses | Should -Contain 'another.missing.key'
    }

    It 'returns the template rather than throwing when the arguments do not fit' {
        # A screen that throws mid-edit takes the operator's typed work with
        # it; one that reads awkwardly does not.
        { Format-BridgeText -Template 'needs {0} and {1}' -Arguments @('one') } | Should -Not -Throw
        Format-BridgeText -Template 'needs {0} and {1}' -Arguments @('one') | Should -Be 'needs {0} and {1}'
    }

    It 'leaves a template with no arguments exactly as written' {
        Format-BridgeText -Template 'a { brace } that is not a placeholder' | Should -Be 'a { brace } that is not a placeholder'
    }
}

Describe 'Which languages exist' {
    It 'accepts the two it ships with and refuses an invented one' {
        Test-BridgeLanguage -Language 'ar' | Should -BeTrue
        Test-BridgeLanguage -Language 'EN' | Should -BeTrue
        Test-BridgeLanguage -Language 'de' | Should -BeFalse
        Test-BridgeLanguage -Language '' | Should -BeFalse
    }

    It 'defaults to Arabic, because that is what the station running this reads' {
        Get-BridgeDefaultLanguage | Should -Be 'ar'
        Get-BridgeLanguages | Should -Contain 'ar'
        Get-BridgeLanguages | Should -Contain 'en'
    }
}
