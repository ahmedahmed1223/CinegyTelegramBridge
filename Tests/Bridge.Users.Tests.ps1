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

Describe 'A name learned from the update itself' {
    BeforeEach {
        $script:UserAliases = @{}
        $script:userAliasesFile = Join-Path $TestDrive 'user-aliases.json'
    }

    It 'names an operator the audit log would otherwise record as a number' {
        # Measured on this station: 7 of 8 users had no name and 366 audit
        # records named a raw id, because only an access request ever captured
        # one - and most operators were added directly by an administrator.
        Update-UserNameFromTelegram -UserId 101 -From ([pscustomobject]@{ first_name = 'أحمد'; last_name = 'علي' }) | Should -BeTrue
        Get-UserDisplayName -UserId 101 | Should -Be 'أحمد علي'
        Format-UserAuditActor -UserId 101 | Should -Match 'أحمد علي'
        Format-UserAuditActor -UserId 101 | Should -Match '101'
    }

    It 'keeps the handle when Telegram carries no first name' {
        Update-UserNameFromTelegram -UserId 102 -From ([pscustomobject]@{ username = 'news_desk' }) | Should -BeTrue
        Get-UserDisplayName -UserId 102 | Should -Be '@news_desk'
    }

    It 'never overwrites a name an administrator chose' {
        Set-UserAlias -TargetUserId 103 -Alias 'مخرج النشرة' | Out-Null
        Update-UserNameFromTelegram -UserId 103 -From ([pscustomobject]@{ first_name = 'Ahmad' }) | Should -BeFalse
        Get-UserDisplayName -UserId 103 | Should -Be 'مخرج النشرة'
    }

    It 'writes once, not on every message' {
        $from = [pscustomobject]@{ first_name = 'أحمد' }
        Update-UserNameFromTelegram -UserId 104 -From $from | Should -BeTrue
        Update-UserNameFromTelegram -UserId 104 -From $from | Should -BeFalse
    }

    It 'ignores an update with no sender rather than storing a blank' {
        Update-UserNameFromTelegram -UserId 105 -From $null | Should -BeFalse
        Get-UserDisplayName -UserId 105 | Should -Be '105'
    }

    It 'caps a pasted paragraph so one name cannot stretch every audit line' {
        Update-UserNameFromTelegram -UserId 106 -From ([pscustomobject]@{ first_name = ('ا' * 200) }) | Out-Null
        (Get-UserDisplayName -UserId 106).Length | Should -BeLessOrEqual 80
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

        $ownerView = @((Get-UserCardKeyboard -TargetUserId 202 -ViewerUserId 101).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })
        $adminView = @((Get-UserCardKeyboard -TargetUserId 202 -ViewerUserId 202).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } })

        $ownerView | Should -Contain 'usr:demote:202'
        $adminView | Should -Not -Contain 'usr:demote:202'
        # Nothing to promote the owner to, and demoting them is refused.
        @((Get-UserCardKeyboard -TargetUserId 101 -ViewerUserId 101).inline_keyboard |
                ForEach-Object { @($_) | ForEach-Object { $_['callback_data'] } }) |
            Should -Not -Contain 'usr:demote:101'
        $config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @() -Force
    }

    It 'refuses to revoke the final administrator' {
        $result = Revoke-AuthorizedUser -TargetUserId 101
        $result.Success | Should -BeFalse
        $result.Error | Should -Match 'آخر مشرف|المالك'
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

    It 'refuses to revoke an explicitly configured owner' {
        $originalOwners = @(Get-JsonProp $config 'OwnerUserIds')
        try {
            $config | Add-Member -NotePropertyName OwnerUserIds -NotePropertyValue @(202) -Force
            $result = Revoke-AuthorizedUser -TargetUserId 202
            $result.Success | Should -BeFalse
            $result.Error | Should -Match 'المالك'
            $config.AllowedUserIds | Should -Contain 202
        }
        finally { $config | Add-Member -NotePropertyName OwnerUserIds -NotePropertyValue $originalOwners -Force }
    }

    It 'clears every pending flow owned by a revoked user' {
        Set-PendingState -ChatId 202 -State @{ Mode = 'update_field'; UserId = 202; Field = 'headline' }
        Revoke-AuthorizedUser -TargetUserId 202 | Out-Null
        Get-PendingState -ChatId 202 | Should -BeNullOrEmpty
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

    It 'names every user in the roster and puts their actions on their card' {
        $roster = @((Get-UsersAdminKeyboard).inline_keyboard | ForEach-Object { @($_) })
        @($roster.callback_data) | Should -Contain 'usr:card:202:0'
        # One row each: the roster no longer carries five buttons per person.
        @($roster.callback_data) | Should -Not -Contain 'usr:alias:202'

        $card = @((Get-UserCardKeyboard -TargetUserId 202 -ViewerUserId 101).inline_keyboard | ForEach-Object { @($_) })
        @($card.callback_data) | Should -Contain 'usr:alias:202'
        @($card.callback_data) | Should -Contain 'usr:revoke:202'
        # And a way back to the page the roster was on.
        @($card.callback_data) | Should -Contain 'userspage:0'
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

    It 'shows the approximate activity state on the user card' {
        Mock Get-AuthorizedUsers { @([pscustomobject]@{ UserId=202L; Alias='مخرج'; Role='operator'; Disabled=$false; AddedAt=''; AddedByUserId=0L; LastActivityAt=(Get-Date).AddMinutes(-1).ToString('o') }) }
        Mock Test-Owner { $false }
        Get-UserCardText -TargetUserId 202 | Should -Match 'نشط حديثًا'
        @((Get-UserCardKeyboard -TargetUserId 202 -ViewerUserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) |
            Should -Contain 'usr:activity:202'
    }

    It 'says on the card what the roster has no room for' {
        $added = (Get-Date).AddDays(-30)
        Mock Get-AuthorizedUsers { @([pscustomobject]@{ UserId=202L; Alias='مخرج'; Role='admin'; Disabled=$true; AddedAt=$added.ToString('o'); AddedByUserId=0L; LastActivityAt=(Get-Date).AddDays(-9).ToString('o') }) }
        $text = Get-UserCardText -TargetUserId 202
        $text | Should -Match '202'
        $text | Should -Match 'معطّل'
        $text | Should -Match 'مشرف'
        $text | Should -Match 'منذ 9 يومًا'
        $text | Should -Match $added.ToString('yyyy-MM-dd')
    }

    It 'says plainly when the person is gone rather than drawing their buttons' {
        Mock Get-AuthorizedUsers { @() }
        Get-UserCardText -TargetUserId 202 | Should -Match 'لم يعد ضمن'
        @((Get-UserCardKeyboard -TargetUserId 202 -ViewerUserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { $_['callback_data'] }) |
            Should -Not -Contain 'usr:revoke:202'
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
        $text = ConvertFrom-TelegramHtmlText (Get-UserActivitySummaryText -Now $now)
        $text | Should -Match 'أحمد.*نشط حديثًا'
        $text | Should -Match 'سارة.*خامل'
        $text | Should -Match 'جديد.*غير معروف'
    }

    It 'escapes an alias and keeps the caveat apart from the list' {
        # Aliases are typed by an administrator, so a '<' in one would cost the
        # whole screen a 400 from Telegram - which reads on the phone as the
        # button doing nothing. And the caveat matters here more than on most
        # screens: "نشط" means "spoke to the bot recently", not "online".
        Mock Get-AuthorizedUsers {
            @([pscustomobject]@{ UserId = 1L; Alias = '<b>مخرج'; LastActivityAt = (Get-Date).ToString('o') })
        }

        $raw = Get-UserActivitySummaryText
        $raw | Should -Match '&lt;b&gt;مخرج'
        $raw | Should -Match '<i>Telegram لا يوفّر'
        # Not quoted: this list is the whole screen, not evidence under a
        # verdict, and the bar is kept for detail an operator may skip.
        $raw | Should -Not -Match 'blockquote'
        ConvertFrom-TelegramHtmlText $raw | Should -Match '<b>مخرج'
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

Describe 'Dead chats quarantine (D1)' {
    BeforeEach {
        Mock Write-BridgeLog { }
        Mock Add-AuditEntry { }
        Mock Send-AdminBroadcast { }
        $script:DeadChats = @{}
        $script:DeadChatStrikes = @{}
        $script:deadChatsFile = Join-Path $TestDrive 'dead-chats.json'
    }

    AfterEach {
        $script:DeadChats = @{}
        $script:DeadChatStrikes = @{}
    }

    It 'ignores content failures and counts only undeliverable chats' {
        # A 400 is the bridge's own malformed message: quarantining on it
        # would hide our bugs behind a roster.
        Register-TelegramSendFailure -ChatId 111 -StatusCode 400 -ErrorText 'Bad Request'
        Register-TelegramSendFailure -ChatId 111 -StatusCode 400 -ErrorText 'Bad Request'
        Register-TelegramSendFailure -ChatId 111 -StatusCode 400 -ErrorText 'Bad Request'
        Test-DeadChat -ChatId 111 | Should -BeFalse
        Register-TelegramSendFailure -ChatId 222 -StatusCode 403 -ErrorText 'Forbidden: bot was blocked'
        Register-TelegramSendFailure -ChatId 222 -StatusCode 403 -ErrorText 'Forbidden: bot was blocked'
        Test-DeadChat -ChatId 222 | Should -BeFalse
        Register-TelegramSendFailure -ChatId 222 -StatusCode 403 -ErrorText 'Forbidden: bot was blocked'
        Test-DeadChat -ChatId 222 | Should -BeTrue
        Should -Invoke Send-AdminBroadcast -Times 1 -Exactly
    }

    It 'skips quarantined chats instead of failing again' {
        $script:DeadChats['333'] = @{ Since = (Get-Date).ToString('o'); LastError = 'blocked'; Strikes = 3 }
        Mock Invoke-BridgeTelegramRequest { throw 'must not attempt a quarantined chat' }
        Send-TelegramMessage -ChatId 333 -Text 'hello'
        Should -Invoke Invoke-BridgeTelegramRequest -Times 0 -Exactly
    }

    It 'releases back to zero strikes rather than trusting the button' {
        $script:DeadChats['444'] = @{ Since = (Get-Date).ToString('o'); LastError = 'blocked'; Strikes = 3 }
        Restore-DeadChat -ChatId 444
        Test-DeadChat -ChatId 444 | Should -BeFalse
        Register-TelegramSendFailure -ChatId 444 -StatusCode 403 -ErrorText 'still blocked'
        Test-DeadChat -ChatId 444 | Should -BeFalse
    }

    It 'persists the quarantine across restarts' {
        $script:DeadChats['555'] = @{ Since = (Get-Date).ToString('o'); LastError = 'Unauthorized'; Strikes = 3 }
        Save-DeadChats | Should -BeTrue
        $script:DeadChats = @{}
        Import-DeadChats
        Test-DeadChat -ChatId 555 | Should -BeTrue
    }
}
