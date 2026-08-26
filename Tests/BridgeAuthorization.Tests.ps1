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

Describe 'Test-BridgeOwner' {
    It 'makes the first administrator the owner when none is configured' {
        # "The owner is whoever set the bridge up" - the first id in
        # AdminUserIds, so the feature works before anyone edits config.json.
        Test-BridgeOwner -ChatId 100000001 -UserId 100000001 -AdminUserIds @(100000001, 100000002) | Should -BeTrue
    }

    It 'does not make every administrator an owner' {
        # The whole point of the tier: appointing administrators is narrower
        # than being one.
        Test-BridgeOwner -ChatId 100000002 -UserId 100000002 -AdminUserIds @(100000001, 100000002) | Should -BeFalse
    }

    It 'lets the configured owner list win over the first administrator' {
        Test-BridgeOwner -ChatId 100000002 -UserId 100000002 -OwnerUserIds @(100000002) -AdminUserIds @(100000001, 100000002) | Should -BeTrue
        Test-BridgeOwner -ChatId 100000001 -UserId 100000001 -OwnerUserIds @(100000002) -AdminUserIds @(100000001, 100000002) | Should -BeFalse
    }

    It 'refuses an operator, whatever the chat id says' {
        Test-BridgeOwner -ChatId 100000009 -UserId 100000009 -AdminUserIds @(100000001) | Should -BeFalse
    }

    It 'falls back to admin chat ids when no admin user ids exist' {
        Test-BridgeOwner -ChatId 100000003 -UserId 100000003 -AdminChatIds @(100000003, 100000004) | Should -BeTrue
        Test-BridgeOwner -ChatId 100000004 -UserId 100000004 -AdminChatIds @(100000003, 100000004) | Should -BeFalse
    }

    It 'has no owner at all when nothing is configured' {
        # Better than inventing one: an empty install grants nobody the power
        # to appoint administrators.
        Test-BridgeOwner -ChatId 100000001 -UserId 100000001 | Should -BeFalse
        @(Get-BridgeOwnerIds) | Should -HaveCount 0
    }

    It 'ignores blank and non-positive ids in the owner list' {
        @(Get-BridgeOwnerIds -OwnerUserIds @($null, '', 0, 100000005)) | Should -Be @(100000005)
    }
}
