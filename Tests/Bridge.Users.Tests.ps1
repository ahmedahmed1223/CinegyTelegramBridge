#requires -Version 7
<#
    Bridge.Users.Tests.ps1 - Authorization, roles, aliases, and per-role menus.

    Split out of Bridge.Tests.ps1; the shared setup lives in
    Bridge.TestContext.ps1.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'User aliases' {
    BeforeEach {
        $script:UserAliases = @{}
        $script:userAliasesFile = Join-Path $TestDrive 'user-aliases.json'
    }

    It 'stores a trimmed alias and resolves it instead of the numeric id' {
        Set-UserAlias -TargetUserId 101 -Alias '  مخرج الأخبار  ' | Should -BeTrue
        Get-UserDisplayName -UserId 101 | Should -Be 'مخرج الأخبار'
    }

    It 'removes an alias when an empty value is saved' {
        Set-UserAlias -TargetUserId 101 -Alias 'مخرج الأخبار' | Out-Null
        Set-UserAlias -TargetUserId 101 -Alias '' | Should -BeTrue
        Get-UserDisplayName -UserId 101 | Should -Be '101'
    }
}

Describe 'Authorized user administration' {
    BeforeEach {
        $script:OriginalAllowedChatIds = @(Get-JsonProp $config 'AllowedChatIds')
        $script:OriginalAllowedUserIds = @(Get-JsonProp $config 'AllowedUserIds')
        $script:OriginalAdminChatIds = @(Get-JsonProp $config 'AdminChatIds')
        $script:OriginalAdminUserIds = @(Get-JsonProp $config 'AdminUserIds')
        $config.AllowedChatIds = @(101, 202); $config.AllowedUserIds = @(101, 202)
        $config.AdminChatIds = @(101); $config.AdminUserIds = @(101)
        $script:DisabledUserIds = @{}
        $script:disabledUsersFile = Join-Path $TestDrive 'disabled-users.json'
        $script:UserProfiles = @{}
        $script:userProfilesFile = Join-Path $TestDrive 'user-profiles.json'
        Mock Save-Config { }
    }

    AfterEach {
        $config.AllowedChatIds = $script:OriginalAllowedChatIds
        $config.AllowedUserIds = $script:OriginalAllowedUserIds
        $config.AdminChatIds = $script:OriginalAdminChatIds
        $config.AdminUserIds = $script:OriginalAdminUserIds
    }

    It 'rejects a disabled user while preserving the whitelist entry' {
        Set-UserDisabled -TargetUserId 202 -Disabled $true | Should -BeTrue
        Test-Authorized -ChatId 202 -UserId 202 | Should -BeFalse
        $config.AllowedUserIds | Should -Contain 202
    }

    It 'promotes an authorized operator to administrator' {
        $result = Set-AdminRole -TargetUserId 202 -IsAdmin $true

        $result.Success | Should -BeTrue -Because $result.Error
        $config.AdminUserIds | Should -Contain 202
        Should -Invoke Save-Config -Times 1 -Exactly
    }

    It 'refuses to promote someone who is not authorized at all' {
        # Promotion must not double as a way in.
        $result = Set-AdminRole -TargetUserId 909 -IsAdmin $true

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'غير مصرّح'
        $config.AdminUserIds | Should -Not -Contain 909
    }

    It 'refuses to demote the owner' {
        # Otherwise two owners could strip each other and nobody would be left
        # able to appoint anyone.
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(202) -Force
        $config.AdminUserIds = @(101, 202)

        $result = Set-AdminRole -TargetUserId 202 -IsAdmin $false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'المالك'
        $config.AdminUserIds | Should -Contain 202
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'refuses to demote the last administrator' {
        # Reachable only when the owner is somebody other than that last
        # administrator - an owner who appoints but does not operate. When the
        # owner IS the last administrator the owner guard answers first, which
        # is the same refusal by a better name.
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(202) -Force

        $result = Set-AdminRole -TargetUserId 101 -IsAdmin $false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'آخر مشرف'
        $config.AdminUserIds | Should -Contain 101
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'refuses to demote the sole administrator who is also the owner' {
        $result = Set-AdminRole -TargetUserId 101 -IsAdmin $false

        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'المالك'
        $config.AdminUserIds | Should -Contain 101
    }

    It 'demotes an administrator who is neither the owner nor the last one' {
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(101) -Force
        $config.AdminUserIds = @(101, 202)

        $result = Set-AdminRole -TargetUserId 202 -IsAdmin $false

        $result.Success | Should -BeTrue -Because $result.Error
        $config.AdminUserIds | Should -Not -Contain 202
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'warns when the configured owner cannot use the bot at all' {
        # Found in the pre-release audit. Naming an unauthorized owner locks
        # the station out of the role in both directions at once: the named
        # owner is refused at every screen, and the administrator who held it
        # by default no longer does. Nobody can appoint anyone, silently.
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(777) -Force
        try {
            Test-Owner -ChatId 777 -UserId 777 | Should -BeTrue
            Test-Authorized -ChatId 777 -UserId 777 | Should -BeFalse
            Test-Owner -ChatId 101 -UserId 101 | Should -BeFalse

            @(Test-OwnerConfiguration) | Should -Not -BeNullOrEmpty
            @(Test-OwnerConfiguration)[0] | Should -Match '777'
        }
        finally { $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force }
    }

    It 'stays quiet when the owner is a real authorized user' {
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(101) -Force
        try { @(Test-OwnerConfiguration) | Should -HaveCount 0 }
        finally { $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force }
    }

    It 'shows role buttons to the owner and to nobody else' {
        # A button that always answers "not allowed" is worse than no button.
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @(101) -Force
        $config.AdminUserIds = @(101, 202)

        $ownerView = @((Get-UsersAdminKeyboard -ViewerUserId 101).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $adminView = @((Get-UsersAdminKeyboard -ViewerUserId 202).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $ownerView | Should -Contain 'usr:demote:202'
        $adminView | Should -Not -Contain 'usr:demote:202'
        # Nothing to promote the owner to, and demoting them is refused.
        $ownerView | Should -Not -Contain 'usr:demote:101'
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'refuses to revoke the final administrator' {
        $result = Revoke-AuthorizedUser -TargetUserId 101
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'آخر مشرف'
        $config.AdminUserIds | Should -Contain 101
    }

    It 'refuses to disable the final administrator' {
        Set-UserDisabled -TargetUserId 101 -Disabled $true | Should -BeFalse
        Test-UserDisabled -UserId 101 | Should -BeFalse
    }

    It 'removes a regular user from both chat and user authorization lists' {
        $result = Revoke-AuthorizedUser -TargetUserId 202
        $result.Success | Should -BeTrue -Because $result.Error
        $config.AllowedChatIds | Should -Not -Contain 202
        $config.AllowedUserIds | Should -Not -Contain 202
        Should -Invoke Save-Config -Times 1 -Exactly
    }

    It 'lists unique users with alias role and disabled state' {
        $script:UserAliases['202'] = 'مخرج الأخبار'; $script:DisabledUserIds['202'] = $true
        $users = @(Get-AuthorizedUsers)
        $users.Count | Should -Be 2
        # 101 is the only administrator, so it is also the owner: with no
        # OwnerUserIds configured the first administrator holds the role.
        ($users | Where-Object UserId -eq 101).Role | Should -Be 'owner'
        ($users | Where-Object UserId -eq 202).Alias | Should -Be 'مخرج الأخبار'
        ($users | Where-Object UserId -eq 202).Disabled | Should -BeTrue
    }

    It 'requires confirmation before revoking a user' {
        Mock Send-TelegramMessage { }
        Request-UserRevocation -TargetUserId 202 -ChatId 101 -AdminUserId 101
        $config.AllowedUserIds | Should -Contain 202
        (Get-PendingState -ChatId 101).Mode | Should -Be 'user_revoke'
        Should -Invoke Save-Config -Times 0 -Exactly
    }

    It 'records who approved a user and when they were added' {
        Write-UserApprovalMetadata -TargetUserId 202 -ApprovedByUserId 101 | Should -BeTrue
        $script:UserProfiles['202'].AddedByUserId | Should -Be 101
        $script:UserProfiles['202'].AddedAt | Should -Not -BeNullOrEmpty
    }

    It 'updates last activity only for an authorized user' {
        Update-UserLastActivity -UserId 202 | Should -BeTrue
        $script:UserProfiles['202'].LastActivityAt | Should -Not -BeNullOrEmpty
        Update-UserLastActivity -UserId 303 | Should -BeFalse
        $script:UserProfiles.ContainsKey('303') | Should -BeFalse
    }

    It 'removes the runtime profile when access is revoked' {
        $script:UserProfiles['202'] = @{ AddedAt = (Get-Date).ToString('o'); AddedByUserId = 101; LastActivityAt = $null }
        Revoke-AuthorizedUser -TargetUserId 202 | Out-Null
        $script:UserProfiles.ContainsKey('202') | Should -BeFalse
    }

    It 'offers an alias action for every user in the management keyboard' {
        $keyboard = Get-UsersAdminKeyboard
        $buttons = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_ })

        @($buttons.callback_data) | Should -Contain 'usr:alias:202'
        @($buttons.text) -join ' ' | Should -Match 'Alias'
    }

    It 'edits and removes a user alias through the interactive admin flow' {
        $script:UserAliases = @{}
        $script:userAliasesFile = Join-Path $TestDrive 'user-aliases-admin.json'
        Mock Send-TelegramMessage { }

        Start-UserAliasEdit -TargetUserId 202 -ChatId 101 -AdminUserId 101
        (Get-PendingState -ChatId 101).Mode | Should -Be 'user_alias_edit'
        Complete-UserAliasEdit -ChatId 101 -AdminUserId 101 -Value 'مخرج الأخبار'
        Get-UserDisplayName -UserId 202 | Should -Be 'مخرج الأخبار'

        Start-UserAliasEdit -TargetUserId 202 -ChatId 101 -AdminUserId 101
        Complete-UserAliasEdit -ChatId 101 -AdminUserId 101 -Value '-'
        Get-UserDisplayName -UserId 202 | Should -Be '202'
    }
}

Describe 'Role-aware status menus' {
    It 'shows only the simple status button to a regular authorized user' {
        Mock Test-Admin { $false }

        $keyboard = Get-MainMenuKeyboard -ChatId 200 -UserId 200
        $callbackData = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_['callback_data'] })

        $callbackData | Should -Contain 'menu:status'
        $callbackData | Should -Not -Contain 'menu:fullstatus'
        $callbackData | Should -Not -Contain 'menu:health'
        $callbackData | Should -Not -Contain 'menu:refreshstatus'
    }

    It 'adds the full status button for an administrator without separate health or refresh buttons' {
        Mock Test-Admin { $true }

        $keyboard = Get-MainMenuKeyboard -ChatId 100 -UserId 100
        $callbackData = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_['callback_data'] })

        $callbackData | Should -Contain 'menu:status'
        $callbackData | Should -Contain 'menu:fullstatus'
        $callbackData | Should -Not -Contain 'menu:health'
        $callbackData | Should -Not -Contain 'menu:refreshstatus'
    }

    It 'adds the full status button for the owner even when they are not an administrator' {
        Mock Test-Admin { $false }
        Mock Test-Owner { $true }

        $keyboard = Get-MainMenuKeyboard -ChatId 101 -UserId 101
        $callbackData = @($keyboard.inline_keyboard | ForEach-Object { $_ } | ForEach-Object { $_['callback_data'] })

        $callbackData | Should -Contain 'menu:fullstatus'
    }

    It 'rejects a forged full-status callback from a non-admin' {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $false }
        Mock Test-Owner { $false }
        Mock Send-TelegramMessage { }
        Mock Invoke-FullStatusCommand { }
        $callback = [pscustomobject]@{
            id      = 'callback-1'
            from    = [pscustomobject]@{ id = 200 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 200 } }
            data    = 'menu:fullstatus'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Invoke-FullStatusCommand -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 1 -Exactly
    }

    It 'allows the owner to invoke the full status callback' {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Test-Admin { $false }
        Mock Test-Owner { $true }
        Mock Send-TelegramMessage { }
        Mock Invoke-FullStatusCommand { }
        $callback = [pscustomobject]@{
            id      = 'owner-full-status-1'
            from    = [pscustomobject]@{ id = 101 }
            message = [pscustomobject]@{ chat = [pscustomobject]@{ id = 101 } }
            data    = 'menu:fullstatus'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Invoke-FullStatusCommand -Times 1 -Exactly -ParameterFilter { $ChatId -eq 101 -and $UserId -eq 101 }
    }

}

Describe 'Private-chat-only policy' {
    BeforeEach {
        Mock Confirm-TelegramCallback { }
        Mock Test-Authorized { $true }
        Mock Send-TelegramMessage { }
    }

    It 'ignores callbacks originating from a Telegram group' {
        $callback = [pscustomobject]@{
            id = 'group-menu-1'
            from = [pscustomobject]@{ id = 200 }
            message = [pscustomobject]@{
                chat = [pscustomobject]@{ id = -100123; type = 'supergroup' }
            }
            data = 'menu'
        }

        Invoke-CallbackQuery -CallbackQuery $callback

        Should -Invoke Test-Authorized -Times 0 -Exactly
        Should -Invoke Send-TelegramMessage -Times 0 -Exactly
    }
}

Describe 'Administrative user activity status' {
    It 'labels recent stale and unknown activity without claiming Telegram presence' {
        $now = [datetime]'2099-08-21T10:00:00Z'
        (Get-UserActivityStatus -LastActivityAt $now.AddMinutes(-4).ToString('o') -Now $now -ActiveWithinMinutes 5).State | Should -Be 'recent'
        (Get-UserActivityStatus -LastActivityAt $now.AddMinutes(-6).ToString('o') -Now $now -ActiveWithinMinutes 5).State | Should -Be 'idle'
        (Get-UserActivityStatus -LastActivityAt '' -Now $now -ActiveWithinMinutes 5).State | Should -Be 'unknown'
    }

    It 'shows the approximate activity state in administrator user rows' {
        Mock Get-AuthorizedUsers { @([pscustomobject]@{ UserId=202L; Alias='مخرج'; Role='operator'; Disabled=$false; LastActivityAt=(Get-Date).AddMinutes(-1).ToString('o') }) }
        Mock Test-Owner { $false }
        $buttons = @((Get-UsersAdminKeyboard -ViewerUserId 101).inline_keyboard | ForEach-Object { @($_) })
        @($buttons.text) -join ' ' | Should -Match 'نشط حديثًا'
        @($buttons | Where-Object text -Match 'نشط حديثًا').callback_data | Should -Be 'usr:activity:202'
    }

    It 'discloses that the user-management activity labels are approximate' {
        Mock Send-TelegramMessage { }
        Mock Get-AuthorizedUsers { @() }
        Mock Test-Owner { $false }

        Show-UsersAdminScreen -ChatId 101 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'تقريبي|لحظية' }
    }

    It 'adds a user activity summary to administrator tools' {
        Mock Get-RunningRelayProcess { $null }
        $callbacks = @((Get-AdminToolsKeyboard -ChatId 101 -UserId 101).inline_keyboard | ForEach-Object { @($_) } | ForEach-Object callback_data)
        $callbacks | Should -Contain 'menu:userpresence'
    }

    It 'summarizes recent idle and unknown users from cached activity only' {
        $now = Get-Date
        Mock Get-AuthorizedUsers {
            @(
                [pscustomobject]@{ UserId=1L; Alias='أحمد'; LastActivityAt=$now.AddMinutes(-1).ToString('o') },
                [pscustomobject]@{ UserId=2L; Alias='سارة'; LastActivityAt=$now.AddMinutes(-9).ToString('o') },
                [pscustomobject]@{ UserId=3L; Alias='جديد'; LastActivityAt='' }
            )
        }
        $text = Get-UserActivitySummaryText -Now $now
        $text | Should -Match 'أحمد.*نشط حديثًا'
        $text | Should -Match 'سارة.*خامل'
        $text | Should -Match 'جديد.*غير معروف'
    }
}

Describe 'Reserved layers admit administrators only' {
    BeforeEach {
        # Default first so unrelated settings still resolve, then the override.
        Mock Get-Setting { '' }
        Mock Get-Setting { '9' } -ParameterFilter { $Name -eq 'ReservedLayers' }
    }

    It 'refuses an operator' {
        $policy = Test-TemplateShowPolicy -Key 'lower-third' -Layer 9
        $policy.Allowed | Should -BeFalse
        $policy.Reason | Should -Match 'محجوزة'
    }

    It 'admits an administrator but says the layer is reserved' {
        # They are who reserved it; refusing them means editing config to
        # touch their own protected layer.
        $policy = Test-TemplateShowPolicy -Key 'lower-third' -Layer 9 -IsAdmin
        $policy.Allowed | Should -BeTrue
        $policy.Warning | Should -Match 'محجوزة'
    }

    It 'leaves an unreserved layer alone for both roles' {
        (Test-TemplateShowPolicy -Key 'lower-third' -Layer 3).Allowed | Should -BeTrue
        (Test-TemplateShowPolicy -Key 'lower-third' -Layer 3).Warning | Should -BeNullOrEmpty
    }

    It 'still blocks a disabled template for an administrator' {
        # Reserving a layer is about the layer; disabling a template is about
        # the template, and admin rights do not override that.
        Mock Get-Setting { 'broken-tpl' } -ParameterFilter { $Name -eq 'DisabledTemplateKeys' }
        (Test-TemplateShowPolicy -Key 'broken-tpl' -Layer 3 -IsAdmin).Allowed | Should -BeFalse
    }
}

Describe 'The command menu is scoped to the role' {
    BeforeEach {
        Mock Write-BridgeLog {}
        Mock Get-AuthorizedUsers {
            @(
                [pscustomobject]@{ UserId = 101; Alias = 'المالك'; Role = 'owner' }
                [pscustomobject]@{ UserId = 202; Alias = 'مشغّل'; Role = 'operator' }
            )
        }
        Mock Invoke-RestMethod { }
    }

    It 'keeps admin-only commands out of the menu every operator sees' {
        # Telegram shows one global list unless it is scoped, so ⚙️ الإعدادات
        # was advertised to everyone and refused only once tapped.
        Register-BotCommands

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*setMyCommands' -and $Body -notlike '*scope*' -and
            $Body -notlike '*settings*' -and $Body -notlike '*audit*' -and
            $Body -notlike '*diagbundle*' -and $Body -like '*templates*'
        }
    }

    It 'gives an administrator the full list in their own chat' {
        Register-BotCommands

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*setMyCommands' -and $Body -like '*"chat_id":101*' -and $Body -like '*settings*'
        }
    }

    It 'clears the scope for a user who is not an administrator' {
        # A demoted administrator must fall back to the operator menu rather
        # than keep a list of commands that now refuse them.
        Register-BotCommands

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*deleteMyCommands' -and $Body -like '*"chat_id":202*'
        }
    }

    It 'never sends the internal Admin flag to Telegram' {
        Register-BotCommands

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Body -like '*Admin*' }
    }
}
