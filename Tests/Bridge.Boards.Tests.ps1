#requires -Version 7
<#
    Bridge.Boards.Tests.ps1 - programme content boards where they meet the
    bridge: the screens, the permissions, the storage and the one tap that
    reaches air.

    The domain itself is covered by BridgeContentBoards.Tests.ps1; nothing here
    re-tests arithmetic that file already pins.
#>

. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Which templates a programme board may be bound to' {
    BeforeEach {
        # Two text fields and one picture, which is the shape a programme banner
        # usually has; and a second template that declares nothing at all.
        Mock Get-MojazDesignFields {
            if ($TemplateKey -eq 'Econ') {
                @(
                    [pscustomobject]@{ Name = 'title.Text'; Kind = 'text'; Consumed = $true }
                    [pscustomobject]@{ Name = 'Subject.Text'; Kind = 'text'; Consumed = $true }
                    [pscustomobject]@{ Name = 'econ_img'; Kind = 'media'; Consumed = $true }
                )
            }
            else { @() }
        }
        Mock Get-TemplateStore {
            @{
                Order = @('Econ', 'logo')
                Map = @{
                    'Econ' = @{ Key = 'Econ'; Path = 'C:\econ.cintitle'; Layer = 6 }
                    'logo' = @{ Key = 'logo'; Path = 'C:\logo.cintitle'; Layer = 9 }
                }
            }
        }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*.cintitle' }
    }

    It 'offers a scene that declares text, and refuses one that declares none' {
        # Two of this station's four templates declare no fields whatever, so a
        # picker that offered every template would offer rows nothing can fill.
        $candidates = @(Get-BoardEligibleTemplates)

        @($candidates | Where-Object { $_.Key -eq 'Econ' })[0].Usable | Should -BeTrue
        @($candidates | Where-Object { $_.Key -eq 'logo' })[0].Usable | Should -BeFalse
    }

    It 'says why the refused one was refused instead of dropping it silently' {
        # An administrator who cannot find the template they meant deserves to
        # be told why, not left to guess at an absence.
        @(Get-BoardEligibleTemplates | Where-Object { $_.Key -eq 'logo' })[0].Reason | Should -Match 'حقلًا نصّيًا'
    }

    It 'gives the board only the text fields, never the picture' {
        # A variable the bridge never sends is left exactly as the designer
        # built it - the banner keeps its own background and changes its words.
        Get-BoardTextFields -TemplateKey 'Econ' | Should -Be @('title.Text', 'Subject.Text')
        Get-BoardMediaFields -TemplateKey 'Econ' | Should -Be @('econ_img')
    }
}

Describe 'Every board button fits in a Telegram callback' {
    <#
        callback_data is capped at 64 BYTES and an over-long one has Telegram
        refuse the WHOLE message - which is how the mojazdesign: buttons came to
        make a screen simply not appear. Arabic is two bytes a character, so a
        board named in Arabic is the case that matters.
    #>
    BeforeEach {
        Mock Get-MojazDesignFields {
            @(
                [pscustomobject]@{ Name = 'title.Text'; Kind = 'text'; Consumed = $true }
                [pscustomobject]@{ Name = 'Subject.Text'; Kind = 'text'; Consumed = $true }
            )
        }
        Mock Get-TemplateStore { @{ Order = @('Econ'); Map = @{ 'Econ' = @{ Key = 'Econ'; Path = 'C:\econ.cintitle'; Layer = 6 } } } }
        Mock Test-Admin { $true }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*.cintitle' }

        $longArabicName = 'بنر برنامج الاقتصاد المسائي اليومي'
        $board = (New-ContentBoard -Name $longArabicName -TemplateKey 'Econ' -UserId 7).Value
        $board = (Add-BoardItem -Board $board -TextFields @('title.Text', 'Subject.Text') `
                -Values @{ 'title.Text' = 'ضيف الحلقة'; 'Subject.Text' = 'أحمد' } -UserId 7).Value
        $script:ContentBoards = [ordered]@{ "$($board.Id)" = $board }
        $script:TestBoard = $board
    }
    AfterEach { $script:ContentBoards = [ordered]@{} }

    It 'keeps every callback on the boards list under the cap' {
        foreach ($button in @((Get-BoardsKeyboard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) })) {
            [System.Text.Encoding]::UTF8.GetByteCount([string]$button.callback_data) | Should -BeLessOrEqual 64
        }
    }

    It 'keeps every callback on the board screen under the cap' {
        foreach ($button in @((Get-BoardScreenKeyboard -Board $script:TestBoard -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) })) {
            [System.Text.Encoding]::UTF8.GetByteCount([string]$button.callback_data) | Should -BeLessOrEqual 64
        }
    }

    It 'offers the edit-role button the manual promises, showing the role it is on' {
        # The role existed in the domain and was honoured by
        # Test-BoardEditAllowed, but no screen could set it - so the manual
        # described a control that was not there. A documented button that does
        # not exist is worse than an undocumented one.
        $labels = @((Get-BoardScreenKeyboard -Board $script:TestBoard -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object { [string]$_.text })

        @($labels | Where-Object { $_ -like '*من يملأ الجدول*' }) | Should -Not -BeNullOrEmpty
        @($labels | Where-Object { $_ -like '*الجميع*' }) | Should -Not -BeNullOrEmpty
    }

    It 'names the template, its layer and its fields on the board screen' {
        # "الحقول: 2" tells a producer how many boxes to expect, not what they
        # are. The board IS its template - it decides the fields and the layer -
        # so the screen that opens the board says which template it is bound to.
        $script:BoardScreenTextForTest = ''
        Mock Send-TelegramMessage { $script:BoardScreenTextForTest = $Text }
        Mock Edit-TelegramMessageText { $false }

        Show-BoardScreen -BoardId $script:TestBoard.Id -ChatId 100 -UserId 101

        $script:BoardScreenTextForTest | Should -Match 'Econ'
        $script:BoardScreenTextForTest | Should -Match 'طبقة 6'
        $script:BoardScreenTextForTest | Should -Match 'title\.Text'
        $script:BoardScreenTextForTest | Should -Match 'لا يتغيّر'
    }

    It 'keeps every callback on the row card under the cap, fields included' {
        $item = $script:TestBoard.Items[0]
        foreach ($button in @((Get-BoardItemKeyboard -Board $script:TestBoard -Item $item -ChatId 100 -UserId 101).inline_keyboard | ForEach-Object { @($_) })) {
            [System.Text.Encoding]::UTF8.GetByteCount([string]$button.callback_data) | Should -BeLessOrEqual 64
        }
    }

    It 'addresses a field by position, so an Arabic variable name cannot burst the budget' {
        $item = $script:TestBoard.Items[0]
        $data = @((Get-BoardItemKeyboard -Board $script:TestBoard -Item $item -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object callback_data | Where-Object { $_ -like 'boards:f:*' })

        @($data).Count | Should -Be 2
        $data[0] | Should -Match 'boards:f:b_[a-f0-9]{8}:i_[a-f0-9]{8}:0$'
    }
}

Describe 'A row on the card' {
    BeforeEach {
        Mock Get-MojazDesignFields {
            @(
                [pscustomobject]@{ Name = 'title.Text'; Kind = 'text'; Consumed = $true }
                [pscustomobject]@{ Name = 'econ_img'; Kind = 'media'; Consumed = $true }
            )
        }
        Mock Get-TemplateStore { @{ Order = @('Econ'); Map = @{ 'Econ' = @{ Key = 'Econ'; Path = 'C:\econ.cintitle'; Layer = 6 } } } }
        Mock Get-EffectiveAutoHideSeconds { 0 }
        Mock Send-TelegramMessage {}
        Mock Test-Admin { $true }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*.cintitle' }
        $board = (New-ContentBoard -Name 'بنر الاقتصاد' -TemplateKey 'Econ' -UserId 7).Value
        $board = (Add-BoardItem -Board $board -TextFields @('title.Text') -Values @{ 'title.Text' = 'ضيف الحلقة' } -UserId 7).Value
        $script:ContentBoards = [ordered]@{ "$($board.Id)" = $board }
        $script:TestBoard = $board
        $script:BoardsLive = @{}
    }
    AfterEach { $script:ContentBoards = [ordered]@{}; $script:BoardsLive = @{} }

    It 'names the picture field as the scene s own instead of saying nothing about it' {
        # Silence would read as "the developer forgot the picture"; the scene
        # keeps its own on purpose, and the card has to say so.
        Show-BoardItemScreen -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id -ChatId 100 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'econ_img' -and $Text -match 'من المشهد' }
    }

    It 'offers no edit button for the picture field' {
        $data = @((Get-BoardItemKeyboard -Board $script:TestBoard -Item $script:TestBoard.Items[0] -ChatId 100 -UserId 101).inline_keyboard |
                ForEach-Object { @($_) } | ForEach-Object callback_data | Where-Object { $_ -like 'boards:f:*' })

        @($data).Count | Should -Be 1
    }

    It 'warns about a value whose variable has left the scene, and keeps it' {
        # Re-cutting a scene must not destroy a producer's text. The value stays
        # and is simply not sent; punishing the producer for a designer's edit
        # is the wrong answer to the wrong person.
        Mock Get-MojazDesignFields { @([pscustomobject]@{ Name = 'other.Text'; Kind = 'text'; Consumed = $true }) }

        Show-BoardItemScreen -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id -ChatId 100 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'title.Text' -and $Text -match 'لم تعد في المشهد' }
    }

    It 'says the forced hide before the press, not after it' {
        # A sensitive template has a hard auto-hide ceiling. Discovering it after
        # the graphic vanishes is the gap this bridge already paid for once.
        Mock Get-EffectiveAutoHideSeconds { 30 }

        Show-BoardItemScreen -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id -ChatId 100 -UserId 101

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'يُخفى تلقائيًا بعد 30' }
    }
}

Describe 'A prepared row reaching air' {
    BeforeEach {
        Mock Get-MojazDesignFields { @([pscustomobject]@{ Name = 'title.Text'; Kind = 'text'; Consumed = $true }) }
        Mock Get-TemplateStore { @{ Order = @('Econ'); Map = @{ 'Econ' = @{ Key = 'Econ'; Path = 'C:\econ.cintitle'; Layer = 6 } } } }
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $true } }
        Mock Send-TelegramMessage {}
        Mock Write-BridgeValidatedJson { $true }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*.cintitle' }
        $board = (New-ContentBoard -Name 'بنر الاقتصاد' -TemplateKey 'Econ' -UserId 7).Value
        $board = (Add-BoardItem -Board $board -TextFields @('title.Text') -Values @{ 'title.Text' = 'ضيف الحلقة' } -UserId 7).Value
        $script:ContentBoards = [ordered]@{ "$($board.Id)" = $board }
        $script:TestBoard = $board
        $script:BoardsLive = @{}
        $script:OnAir = @{}
    }
    AfterEach { $script:ContentBoards = [ordered]@{}; $script:BoardsLive = @{}; $script:OnAir = @{} }

    It 'goes through the show funnel rather than around it' {
        # Everything that makes a SHOW safe on this bridge - maintenance mode,
        # the per-layer permission, the reserved layer policy, the live Cinegy
        # check, the audit record, stopping a bulletin that owns the layer -
        # lives in that funnel. A second door is a second place to forget it.
        Show-BoardItemOnAir -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id -ChatId 100 -UserId 101 | Should -BeTrue

        Should -Invoke Invoke-ShowTemplateResult -Times 1 -Exactly -ParameterFilter {
            $Key -eq 'Econ' -and $Variables['title.Text'] -eq 'ضيف الحلقة'
        }
    }

    It 'is refused when the funnel refuses it, and marks nothing live' {
        # The broken shape: a protected layer. The refusal comes from the funnel
        # and this feature must not record an air state the funnel never granted.
        Mock Invoke-ShowTemplateResult { [pscustomobject]@{ Success = $false; Error = 'الطبقة 6 للمشرفين وحدهم.' } }

        Show-BoardItemOnAir -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id -ChatId 100 -UserId 101 | Should -BeFalse

        $script:BoardsLive.Count | Should -Be 0
    }

    It 'refuses a disabled row instead of putting it on air' {
        $disabled = (Set-BoardItemEnabled -Board $script:TestBoard -ItemId $script:TestBoard.Items[0].Id -Enabled $false).Value
        $script:ContentBoards["$($disabled.Id)"] = $disabled

        Show-BoardItemOnAir -BoardId $disabled.Id -ItemId $disabled.Items[0].Id -ChatId 100 -UserId 101 | Should -BeFalse

        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }

    It 'says so rather than throwing when the bound template has left the registry' {
        Mock Get-TemplateStore { @{ Order = @(); Map = @{} } }

        Show-BoardItemOnAir -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id -ChatId 100 -UserId 101 | Should -BeFalse

        Should -Invoke Send-TelegramMessage -Times 1 -Exactly -ParameterFilter { $Text -match 'لم يعد في السجلّ' }
    }

    It 'records the live row against the LAYER, so a second board replaces the first' {
        # Two boards may be bound to templates sharing one layer. Keyed by board,
        # both cards would go on claiming to be on air - and a card that lies
        # about the air is worse than one that says nothing.
        $script:OnAir[6] = @{ Key = 'Econ' }
        Show-BoardItemOnAir -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id -ChatId 100 -UserId 101 | Out-Null
        Test-BoardItemLive -Layer 6 -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id | Should -BeTrue

        Set-BoardItemLive -Layer 6 -BoardId 'b_other' -ItemId 'i_other'

        Test-BoardItemLive -Layer 6 -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id | Should -BeFalse
        $script:BoardsLive.Count | Should -Be 1
    }

    It 'stops claiming a row is live once the layer is no longer on air' {
        Show-BoardItemOnAir -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id -ChatId 100 -UserId 101 | Out-Null
        $script:OnAir.Remove(6)

        Test-BoardItemLive -Layer 6 -BoardId $script:TestBoard.Id -ItemId $script:TestBoard.Items[0].Id | Should -BeFalse
    }
}

Describe 'Who may change a board' {
    BeforeEach {
        Mock Test-Admin { $false }
        Mock Test-Owner { $false }
    }

    It 'lets anyone authorized edit by default, because a table nobody may fill is dead' {
        Test-BoardEditAllowed -Board (New-ContentBoard -Name 'بنر' -TemplateKey 'Econ').Value -ChatId 100 -UserId 101 | Should -BeTrue
    }

    It 'holds editing to administrators when the station asked for the split' {
        $board = (New-ContentBoard -Name 'بنر' -TemplateKey 'Econ' -EditRole 'admin').Value

        Test-BoardEditAllowed -Board $board -ChatId 100 -UserId 101 | Should -BeFalse
        Mock Test-Admin { $true }
        Test-BoardEditAllowed -Board $board -ChatId 100 -UserId 101 | Should -BeTrue
    }
}

Describe 'Boards on disk' {
    BeforeEach {
        $script:OriginalLogDir = $script:logDir
        # A fresh folder per test: TestDrive is shared across the Its in one
        # Describe, so a shared name would let each test read the boards the
        # previous one wrote and count them as its own.
        $script:logDir = Join-Path $TestDrive "runtime-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null
        $script:ContentBoards = [ordered]@{}
    }
    AfterEach { $script:logDir = $script:OriginalLogDir; $script:ContentBoards = [ordered]@{} }

    It 'writes one file per board, so editing one does not rewrite the others' {
        # A single shared file means every row edit rewrites every board - the
        # O(n) pattern that had to be taken out of the alias map in 8.53.0.
        $first = (New-ContentBoard -Name 'الاقتصاد' -TemplateKey 'Econ').Value
        $second = (New-ContentBoard -Name 'الرياضة' -TemplateKey 'Sport').Value

        Save-ContentBoard -Board $first | Should -BeTrue
        Save-ContentBoard -Board $second | Should -BeTrue

        @(Get-ChildItem -LiteralPath (Get-BoardsDirectory) -Filter '*.json' -File | Where-Object { $_.Name -notlike '*.bak*' }).Count | Should -Be 2
    }

    It 'reads them back from the directory, which is the index' {
        # No index file: one kept beside the boards is a second source of truth
        # that drifts from the first the moment one write lands and the other
        # does not.
        Save-ContentBoard -Board (New-ContentBoard -Name 'الاقتصاد' -TemplateKey 'Econ').Value | Out-Null
        Save-ContentBoard -Board (New-ContentBoard -Name 'الرياضة' -TemplateKey 'Sport').Value | Out-Null
        $script:ContentBoards = [ordered]@{}

        Import-ContentBoards

        @(Get-ContentBoards).Count | Should -Be 2
        @(Get-ContentBoards | ForEach-Object { $_.Name }) | Should -Contain 'الرياضة'
    }

    It 'takes the file with the board when it is deleted' {
        # Leaving it behind would have the directory - which IS the index - go
        # on listing a board nobody can reach.
        $board = (New-ContentBoard -Name 'الاقتصاد' -TemplateKey 'Econ').Value
        Save-ContentBoard -Board $board | Out-Null

        Remove-ContentBoardFile -BoardId $board.Id

        Test-Path -LiteralPath (Get-BoardFilePath -BoardId $board.Id) | Should -BeFalse
        @(Get-ContentBoards).Count | Should -Be 0
    }

    It 'skips a board whose file is unreadable instead of refusing to start' {
        Save-ContentBoard -Board (New-ContentBoard -Name 'سليم' -TemplateKey 'Econ').Value | Out-Null
        Set-Content -LiteralPath (Join-Path (Get-BoardsDirectory) 'b_broken.json') -Value '{ not json' -Encoding utf8
        $script:ContentBoards = [ordered]@{}

        { Import-ContentBoards } | Should -Not -Throw
        @(Get-ContentBoards).Count | Should -Be 1
    }
}

Describe 'Adding several rows through the add button' {
    <#
        ➕ add already split a paste into rows - and kept the first, dropping
        the rest without a word. The paste button did it right; add now hands
        anything of more than one row to the same path.
    #>
    BeforeEach {
        Mock Get-MojazDesignFields { @([pscustomobject]@{ Name = 'title.Text'; Kind = 'text'; Consumed = $true }) }
        Mock Get-TemplateStore { @{ Order = @('Econ'); Map = @{ 'Econ' = @{ Key = 'Econ'; Path = 'C:\econ.cintitle'; Layer = 6 } } } }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*.cintitle' }
        Mock Send-TelegramMessage {}
        Mock Show-BoardScreen {}
        Mock Test-Admin { $true }
        Mock Save-ContentBoard { $script:ContentBoards["$($Board.Id)"] = $Board; $true }
        $board = (New-ContentBoard -Name 'بنر' -TemplateKey 'Econ' -UserId 7).Value
        $script:ContentBoards = [ordered]@{ "$($board.Id)" = $board }
        $script:BoardAddId = [string]$board.Id
    }
    AfterEach { $script:ContentBoards = [ordered]@{}; Clear-PendingState -ChatId 100 }

    It 'adds every pasted row, not only the first' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'board_add'; UserId = 101; BoardId = $script:BoardAddId; StartedAt = (Get-Date) }
        Complete-BoardText -ChatId 100 -UserId 101 -Value "الأول`nالثاني`nالثالث" | Out-Null
        @($script:ContentBoards[$script:BoardAddId].Items).Count | Should -Be 3
        Should -Invoke Send-TelegramMessage -ParameterFilter { $Text -like "*$(T 'board.rowsAdded' 3)*" }
    }

    It 'still adds one row straight away' {
        Set-PendingState -ChatId 100 -State @{ Mode = 'board_add'; UserId = 101; BoardId = $script:BoardAddId; StartedAt = (Get-Date) }
        Complete-BoardText -ChatId 100 -UserId 101 -Value 'وحده' | Out-Null
        @($script:ContentBoards[$script:BoardAddId].Items).Count | Should -Be 1
    }
}
