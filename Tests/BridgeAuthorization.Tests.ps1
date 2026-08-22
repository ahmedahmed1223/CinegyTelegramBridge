#requires -Version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules\BridgeAuthorization.psm1') -Force
}

Describe 'Private user authorization policy' {
    It 'authorizes an explicitly allowed user and denies a disabled user' {
        Test-BridgeAuthorized -ChatId 101 -UserId 101 -AllowedUserIds @(101) -AllowedChatIds @() `
            -DisabledUserIds @() -RequireUserLevelAuth | Should -BeTrue
        Test-BridgeAuthorized -ChatId 101 -UserId 101 -AllowedUserIds @(101) -AllowedChatIds @() `
            -DisabledUserIds @(101) -RequireUserLevelAuth | Should -BeFalse
    }

    It 'does not let an allowed chat authorize a different sender when user-level authorization is required' {
        Test-BridgeAuthorized -ChatId 500 -UserId 101 -AllowedUserIds @() -AllowedChatIds @(500) `
            -DisabledUserIds @() -RequireUserLevelAuth | Should -BeFalse
    }

    It 'recognizes administrators by user id and preserves the private-chat legacy fallback' {
        Test-BridgeAdministrator -ChatId 101 -UserId 101 -AdminUserIds @(101) -AdminChatIds @() `
            -RequireUserLevelAuth | Should -BeTrue
        Test-BridgeAdministrator -ChatId 202 -UserId 202 -AdminUserIds @() -AdminChatIds @(202) `
            -RequireUserLevelAuth | Should -BeTrue
    }

    It 'accepts only explicit private chats and positive legacy private ids' {
        Test-BridgePrivateChat -Chat ([pscustomobject]@{id=10;type='private'}) | Should -BeTrue
        Test-BridgePrivateChat -Chat ([pscustomobject]@{id=-10;type='group'}) | Should -BeFalse
        Test-BridgePrivateChat -Chat ([pscustomobject]@{id=10}) | Should -BeTrue
        Test-BridgePrivateChat -Chat ([pscustomobject]@{id=-10}) | Should -BeFalse
    }
}
