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
            'Get-SettingsCategoryKeyboard'      = 'the settings in one category, a fixed list in the source'
            'Get-DurationKeyboard'              = 'a fixed set of durations'
            'Get-SettingSmallRangeKeyboard'     = 'one button per value in a declared range of at most 24'
            'Show-SettingTimePicker'            = 'twenty-four hours and four quarters, both fixed'
            'Get-OperationLogKeyboard'          = 'one button per window in $script:OperationLogWindows, a fixed list of three'
            'Get-ScheduleCalendarKeyboard'      = 'one month of days'
            'ConvertTo-OneHandLayout'           = 'rearranges rows it is given; it builds none'
            'ConvertTo-TelegramReplyMarkupJson' = 'serialises a keyboard, it does not build one'
            'Receive-SettingsImport'            = 'not a keyboard builder; it reports on an imported file'
            'Update-TemplateReminderQueue'      = 'not a keyboard builder; it sends one reminder per due item'
            'Update-PendingExpiry'              = 'not a keyboard builder; its one row is the extend button on the expiry warning'
            'Invoke-CallbackQuery'              = 'the callback switch, which delegates to the builders above'
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
                if ($body -notmatch 'foreach\s*\(' -and $body -notmatch 'ForEach-Object') { continue }
                if ($body -match 'Get-BridgePageWindow') { continue }
                if ($script:BoundedScreens.ContainsKey($name)) { continue }
                "$name ($($builders[$name].File))"
            }
        )

        $offenders | Should -BeNullOrEmpty -Because "these build a keyboard from a collection without paging it - page it with Get-BridgePageWindow, or add it to BoundedScreens with the reason its collection cannot grow: $($offenders -join ', ')"
    }

    It 'names a real function in every exemption' {
        # An exemption for a function since renamed or deleted stops exempting
        # anything and starts hiding whatever offender takes its place.
        $builders = Get-BridgeKeyboardBuilders -PartsPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Parts')
        $stale = @($script:BoundedScreens.Keys | Where-Object { -not $builders.ContainsKey($_) } | Sort-Object)
        $stale | Should -BeNullOrEmpty -Because "these exemptions name functions that no longer exist: $($stale -join ', ')"
    }
}
