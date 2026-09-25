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

Describe 'Every screen built from a growing list is paged' {
    <#
        The same bug has been fixed in four screens now: a keyboard drawing one
        row per item works until somebody has enough items, then Telegram
        refuses the message and the screen stops opening - for exactly the
        people using that feature most. Fixing it a fifth time by hand is not a
        plan, so the rule is enforced here instead.

        A keyboard that loops over a collection must page it. A screen whose
        collection cannot grow is listed below WITH THE REASON it cannot; if
        you add one, write the reason rather than silencing the test.
    #>
    BeforeAll {
        $script:BoundedScreens = @{
            'Get-MainMenuKeyboard'              = 'one row per on-air layer, and layers come from the registry'
            'Get-LayersKeyboard'                = 'one button per known layer'
            'Get-LayerDashboardKeyboard'        = 'one button per known layer, two to a row'
            'Get-LayerNamesKeyboard'            = 'one button per known layer'
            'Get-HideAllLayerSettingsKeyboard'  = 'one button per known layer'
            'Get-SettingsKeyboard'              = 'one button per settings category, a fixed list'
            'Get-AdminToolsKeyboard'            = 'one button per admin-tools category, a fixed list of four'
            'Get-SettingsCategoryKeyboard'      = 'the settings in one category, a fixed list in the source'
            'Get-DurationKeyboard'              = 'a fixed set of durations'
            'Get-SettingSmallRangeKeyboard'     = 'one button per value in a declared range of at most 24'
            'Show-SettingTimePicker'            = 'twenty-four hours and four quarters, both fixed'
            'Get-OperationLogKeyboard'          = 'one button per window in $script:OperationLogWindows, a fixed list of three'
            'Get-SettingsGroupPickerKeyboard'   = 'one button per group of one category, a fixed list in the source of at most five'
            'Show-NewsPasteReview'              = 'two fixed buttons, add and cancel; the pasted items are text lines, cut at five and three'
            'Get-OperationLogFilterKeyboard'    = 'one button per choice from Get-OperationLogFilterOptions, which caps both lists at its Limit and reports what it left out'
            'Get-ScheduleCalendarKeyboard'      = 'one month of days'
            'Get-BoardItemKeyboard'             = 'one row per text field the bound scene declares - a .cintitle contract, not a collection that grows with the station''s data'
            'ConvertTo-OneHandLayout'           = 'rearranges rows it is given; it builds none'
            'Invoke-ShowTemplateResult'         = 'builds no keyboard; it prepends one fixed row to the main menu on the failure message'
            # Reached by widening the guard to see classic index loops. Each
            # reason is the bound itself, not a promise that it is small.
            'Get-ConfigBackupsKeyboard'         = 'one row per saved configuration, and ConfigBackupKeepFiles declares its range'
            'Get-TemplateBackupsKeyboard'       = 'one row per saved template registry, capped by the same ConfigBackupKeepFiles'
            'Get-NewsTickerBackupsKeyboard'     = 'one row per saved ticker copy, and NewsBackupKeepFiles declares its range'
            'Get-NewsTickerReorderKeyboard'     = 'paged by hand with Get-NewsTickerPageSize, and the item count is capped by NewsMaxItems'
            'Get-FieldsKeyboard'                = 'one button per field of a single template, which the Cinegy scene defines - nobody adds fields at runtime'
            'Get-FieldPromptKeyboard'           = 'the recent values of one field, capped by RecentValuesPerField'
            'Get-MojazImageKeyboard'            = 'the loop stops at eight in its own condition'
            'Get-HelpHomeKeyboard'              = 'one button per help chapter, a fixed list in the source'
            'Get-ScheduleAnchorPickerKeyboard'  = 'one button per choice its caller passes in'
            'Get-ScheduleHourKeyboard'          = 'twenty-four hours'
            'Get-ScheduleMinuteKeyboard'        = 'four quarters of an hour'
            'Get-SettingChoiceKeyboard'         = 'the declared values of one setting in $script:SettingChoices'
            'Get-SettingStepperKeyboard'        = 'a fixed set of step presets'
            'Update-NewsDraftExpiry'            = 'not a keyboard builder; the loop numbers the draft lines inside a warning'
            'ConvertTo-TelegramReplyMarkupJson' = 'serialises a keyboard, it does not build one'
            'Receive-SettingsImport'            = 'not a keyboard builder; it reports on an imported file'
            'Update-TemplateReminderQueue'      = 'not a keyboard builder; it sends one reminder per due item'
            'Update-PendingExpiry'              = 'not a keyboard builder; its one row is the extend button on the expiry warning'
            'Invoke-CallbackQuery'              = 'the callback switch, which delegates to the builders above'
            'Update-StaleOnAirWatchdog'         = 'one hide button per stale layer, and a channel has nine graphics layers'
            'Show-ShiftReadinessScreen'         = 'its keyboard is two fixed rows; the loop it holds walks Get-DisabledGuardLines, a fixed table of guards in the source'
            'Show-MaterialScheduleScreen'       = 'a fixed refresh-and-back keyboard; the loop builds text, trimmed by Select-RichTableRows and paged by Send-TelegramPagedText'
            'Show-ShiftHandoverScreen'          = 'a fixed keyboard of three buttons; the loops build text, paged by Send-TelegramPagedText'
            'Show-UrgentReviewScreen'           = 'its keyboard is two fixed rows - start and back; the loop it holds walks the plan notes, of which New-UrgentRunPlan emits at most three'
        }

        # Rich-table screens whose rows are a fixed list rather than the
        # station's data. Counted once, in 8.17, against every Get-*Blocks in
        # Parts: twenty-five of them, and exactly one was growing unbounded.
        $script:FixedRowScreens = @{
            'Get-BridgeHealthCenterBlocks' = 'one row per health check, and the checks are a fixed list'
            'Get-BridgeStatsBlocks'        = 'one row per counter on the operating-numbers screen'
            'Get-RuntimeFileHealthBlocks'  = 'one row per runtime file, named in the source'
            'Get-OnAirTableBlocks'         = 'one row per layer on air; a channel has a handful'
            'Get-StatusRichBlocks'         = 'the same layers, in the status summary'
            'Get-MainMenuIntroBlocks'      = 'the live layers and a fixed intro'
            'Get-MojazBlocks'              = 'the selected bulletin, which has no loop over a collection'
            'Get-ConfigRestoreBlocks'      = 'bounded by ConfigBackupKeepFiles, which is a capped setting'
            'Get-HelpRichBlocks'           = 'the manual chapters, capped against the payload limit since 8.16'
            'Get-MyOperationsBlocks'       = 'the newest few operations then a folded remainder, by construction'
            'Get-MissedEventsBlocks'       = 'fixed sections, each already limited by its own reader'
            'Get-NewsDayDetailBlocks'      = 'one row per day of the report window'
            'Get-NewsReportBlocks'         = 'one row per day of the report window'
            'Get-WorkReportBlocks'         = 'one row per operator, and the roster is the whitelist'
        }

        function global:Get-BridgeKeyboardBuilders {
            param([Parameter(Mandatory)][string]$PartsPath)
            $found = @{}
            foreach ($file in @(Get-ChildItem -LiteralPath $PartsPath -Filter '*.ps1' -File)) {
                $errors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
                foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                    $found[$fn.Name] = [pscustomobject]@{ File = $file.Name; Body = $fn.Extent.Text }
                }
            }
            return $found
        }
    }

    It 'pages every keyboard whose collection can grow' {
        $builders = Get-BridgeKeyboardBuilders -PartsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Parts')
        $offenders = @(
            foreach ($name in @($builders.Keys | Sort-Object)) {
                $body = $builders[$name].Body
                if ($body -notmatch 'inline_keyboard') { continue }
                # 'for (' as well as foreach: the guard looked only for the
                # two foreach forms, and nineteen builders were written with a
                # classic index loop - so the most-used screen in the bot, the
                # template list, grew one row per template with nothing
                # watching. Measured at 300 templates: 301 rows, 29 KB of
                # reply_markup, which Telegram will not send.
                if ($body -notmatch 'foreach\s*\(' -and $body -notmatch 'ForEach-Object' -and $body -notmatch 'for\s*\(') { continue }
                if ($body -match 'Get-BridgePageWindow') { continue }
                if ($script:BoundedScreens.ContainsKey($name)) { continue }
                "$name ($($builders[$name].File))"
            }
        )

        $offenders | Should -BeNullOrEmpty -Because "these build a keyboard from a collection without paging it - page it with Get-BridgePageWindow, or add it to BoundedScreens with the reason its collection cannot grow: $($offenders -join ', ')"
    }

    It 'bounds every rich table whose rows come from a growing collection' {
        # The sibling of the paging rule above, for the message body rather
        # than the keyboard. A table that grows with the station's data crosses
        # the payload limit gradually, and the first to notice is the operator
        # whose table vanished into a text fallback.
        #
        # Bounded means any of: Select-RichTableRows, Get-BridgePageWindow, a
        # page window of its own, or Select-Object -First. Screens whose rows
        # are a fixed list - the health checks, the runtime files, the layers
        # on air - are named below with the reason, because a rule that cannot
        # be satisfied is a rule that gets deleted.
        $builders = Get-BridgeKeyboardBuilders -PartsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Parts')
        $offenders = @(
            foreach ($name in @($builders.Keys | Sort-Object)) {
                if ($name -notlike 'Get-*Blocks') { continue }
                $body = $builders[$name].Body
                # 'for (' as well as foreach: the guard looked only for the
                # two foreach forms, and nineteen builders were written with a
                # classic index loop - so the most-used screen in the bot, the
                # template list, grew one row per template with nothing
                # watching. Measured at 300 templates: 301 rows, 29 KB of
                # reply_markup, which Telegram will not send.
                if ($body -notmatch 'foreach\s*\(' -and $body -notmatch 'ForEach-Object' -and $body -notmatch 'for\s*\(') { continue }
                # Every named way a builder can be bounded. Get-NewsTickerPageSize is
                # the ticker's own page size, applied by hand in two places -
                # bounded, but not through the shared helper, which is worth
                # knowing and is why it is listed rather than pattern-matched.
                if ($body -match 'Select-RichTableRows|Get-BridgePageWindow|Get-NewsTickerPageSize|Select-Object\s+-First|\$PageSize') { continue }
                if ($script:FixedRowScreens.ContainsKey($name)) { continue }
                "$name ($($builders[$name].File))"
            }
        )

        $offenders | Should -BeNullOrEmpty -Because "these build a rich table from a collection without bounding it - trim it with Select-RichTableRows, or add it to FixedRowScreens with the reason its rows cannot grow: $($offenders -join ', ')"
    }

    It 'names a real function in every fixed-rows exemption' {
        $builders = Get-BridgeKeyboardBuilders -PartsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Parts')
        $stale = @($script:FixedRowScreens.Keys | Where-Object { -not $builders.ContainsKey($_) } | Sort-Object)
        $stale | Should -BeNullOrEmpty -Because "these exemptions name functions that no longer exist: $($stale -join ', ')"
    }

    It 'names a real function in every exemption' {
        # An exemption for a function since renamed or deleted stops exempting
        # anything and starts hiding whatever offender takes its place.
        $builders = Get-BridgeKeyboardBuilders -PartsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Parts')
        $stale = @($script:BoundedScreens.Keys | Where-Object { -not $builders.ContainsKey($_) } | Sort-Object)
        $stale | Should -BeNullOrEmpty -Because "these exemptions name functions that no longer exist: $($stale -join ', ')"
    }
}
