#requires -Version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeContentBoards.psm1') -Force

    # Two text fields, which is the shape a programme banner usually has: a
    # title line and a subject line. The scene declares them; nothing here
    # invents field names.
    $script:TestFields = @('title.Text', 'Subject.Text')

    function New-TestContentBoard {
        param([string[]]$Fields = $script:TestFields)
        $board = (New-ContentBoard -Name 'بنر برنامج الاقتصاد' -TemplateKey 'Econ' -UserId 7).Value
        foreach ($pair in @(@('ضيف الحلقة', 'أحمد'), @('الأسعار اليوم', 'ارتفاع'), @('الختام', 'شكرًا'))) {
            $board = (Add-BoardItem -Board $board -TextFields $Fields -UserId 7 `
                    -Values @{ 'title.Text' = $pair[0]; 'Subject.Text' = $pair[1] }).Value
        }
        return $board
    }
}

Describe 'Creating a programme board' {
    It 'trims the name the producer typed rather than storing their spacing' {
        (New-ContentBoard -Name '  بنر   الاقتصاد  ' -TemplateKey 'Econ').Value.Name | Should -Be 'بنر الاقتصاد'
    }

    It 'refuses a board with no name and one with no template' {
        (New-ContentBoard -Name '   ' -TemplateKey 'Econ').ErrorCode | Should -Be 'invalid_name'
        (New-ContentBoard -Name 'بنر' -TemplateKey '').ErrorCode | Should -Be 'invalid_template'
    }

    It 'keeps the id short enough that two of them fit in a callback' {
        # callback_data is capped at 64 BYTES. A row button carries the board id
        # AND the item id; two full GUIDs would be 78 before the prefix, which is
        # how the mojazdesign: buttons came to exceed the cap and have Telegram
        # refuse the whole message.
        $board = (New-ContentBoard -Name 'بنر' -TemplateKey 'Econ').Value
        $item = (Add-BoardItem -Board $board -TextFields $script:TestFields -Values @{ 'title.Text' = 'س' }).Value.Items[0]

        $data = "boards:i:$($board.Id):$($item.Id):text"
        [System.Text.Encoding]::UTF8.GetByteCount($data) | Should -BeLessOrEqual 64
    }

    It 'opens to everyone by default, because a table nobody may fill is dead on delivery' {
        (New-ContentBoard -Name 'بنر' -TemplateKey 'Econ').Value.EditRole | Should -Be 'all'
    }

    It 'takes the roles the bridge already has, and refuses an invented one' {
        foreach ($role in @('all', 'admin', 'owner')) {
            (New-ContentBoard -Name 'بنر' -TemplateKey 'Econ' -EditRole $role).Success | Should -BeTrue
        }
        (New-ContentBoard -Name 'بنر' -TemplateKey 'Econ' -EditRole 'producer').ErrorCode | Should -Be 'invalid_role'
    }
}

Describe 'Rows a producer prepares' {
    It 'never mutates the board it was handed' {
        # A caller that changed the live board would leave a half-applied table
        # on screen the moment a later line refused the change.
        $board = New-TestContentBoard
        $before = @($board.Items).Count

        Add-BoardItem -Board $board -TextFields $script:TestFields -Values @{ 'title.Text' = 'جديد' } | Out-Null

        @($board.Items).Count | Should -Be $before
    }

    It 'refuses a row where nothing at all was filled' {
        # An empty row reaches air as a blank graphic, which the gallery reads
        # as a fault rather than as a choice.
        $board = New-TestContentBoard

        (Add-BoardItem -Board $board -TextFields $script:TestFields -Values @{ 'title.Text' = ''; 'Subject.Text' = '  ' }).ErrorCode |
            Should -Be 'empty'
    }

    It 'accepts a row that fills only some of the fields' {
        $board = New-TestContentBoard
        $result = Add-BoardItem -Board $board -TextFields $script:TestFields -Values @{ 'title.Text' = 'وحده' }

        $result.Success | Should -BeTrue
        $result.Value.Items[-1].Values.'Subject.Text' | Should -Be ''
    }

    It 'stops at the ceiling instead of growing without one' {
        $board = New-TestContentBoard

        (Add-BoardItem -Board $board -TextFields $script:TestFields -MaxItems 3 -Values @{ 'title.Text' = 'رابع' }).ErrorCode |
            Should -Be 'full'
    }

    It 'refuses a value past the field length rather than truncating a producer silently' {
        $board = New-TestContentBoard

        (Add-BoardItem -Board $board -TextFields $script:TestFields -MaxFieldLength 10 -Values @{ 'title.Text' = ('ن' * 11) }).ErrorCode |
            Should -Be 'too_long'
    }

    It 'says so when the scene declares no text field at all' {
        # Two of this station's four templates declare no fields whatever, so a
        # picker that offered every template would offer these.
        (Add-BoardItem -Board (New-TestContentBoard) -TextFields @() -Values @{ 'x' = 'y' }).ErrorCode |
            Should -Be 'no_fields'
    }
}

Describe 'Editing and ordering' {
    It 'changes one field and leaves its neighbour alone' {
        $board = New-TestContentBoard
        $id = $board.Items[0].Id

        $result = Set-BoardItemField -Board $board -ItemId $id -Field 'title.Text' -Value 'معدّل' -TextFields $script:TestFields

        $result.Value.Items[0].Values.'title.Text' | Should -Be 'معدّل'
        $result.Value.Items[0].Values.'Subject.Text' | Should -Be 'أحمد'
    }

    It 'refuses a field the scene no longer declares' {
        $board = New-TestContentBoard

        (Set-BoardItemField -Board $board -ItemId $board.Items[0].Id -Field 'Subject.Text' -Value 'س' -TextFields @('title.Text')).ErrorCode |
            Should -Be 'unknown_field'
    }

    It 'moves a row without losing the others, and refuses to move past the ends' {
        $board = New-TestContentBoard
        $second = $board.Items[1].Id

        $moved = (Move-BoardItem -Board $board -ItemId $second -Delta -1).Value
        @($moved.Items).Count | Should -Be 3
        $moved.Items[0].Id | Should -Be $second

        (Move-BoardItem -Board $moved -ItemId $second -Delta -1).ErrorCode | Should -Be 'at_edge'
    }

    It 'disables a row without deleting the work behind it' {
        # The producer prepared ten and today the show needs six.
        $board = New-TestContentBoard
        $result = Set-BoardItemEnabled -Board $board -ItemId $board.Items[0].Id -Enabled $false

        $result.Value.Items[0].Enabled | Should -BeFalse
        $result.Value.Items[0].Values.'title.Text' | Should -Be 'ضيف الحلقة'
    }

    It 'removes one row and leaves an identical twin in place' {
        $board = New-TestContentBoard
        $board = (Add-BoardItem -Board $board -TextFields $script:TestFields -Values @{ 'title.Text' = 'ضيف الحلقة'; 'Subject.Text' = 'أحمد' }).Value

        $result = Remove-BoardItem -Board $board -ItemId $board.Items[0].Id

        @($result.Value.Items).Count | Should -Be 3
        @($result.Value.Items | Where-Object { $_.Values.'title.Text' -eq 'ضيف الحلقة' }).Count | Should -Be 1
    }

    It 'changes who may fill the board, and refuses a role that is not one of the three' {
        # New-ContentBoard took the role at birth and nothing could change it
        # afterwards: a board created open stayed open forever, and no screen
        # could say otherwise. A role you can set once and never correct is a
        # role nobody dares set in the first place.
        $board = New-TestContentBoard

        $result = Set-BoardEditRole -Board $board -Role 'admin'

        $result.Value.EditRole | Should -Be 'admin'
        $board.EditRole | Should -Be 'all'
        (Set-BoardEditRole -Board $board -Role 'producer').ErrorCode | Should -Be 'invalid_role'
    }

    It 'bumps the revision once per accepted change and not at all for a refused one' {
        $board = New-TestContentBoard
        $before = [int]$board.Revision

        (Set-BoardItemEnabled -Board $board -ItemId $board.Items[0].Id -Enabled $false).Value.Revision | Should -Be ($before + 1)
        (Set-BoardItemEnabled -Board $board -ItemId 'i_nosuch' -Enabled $false).Success | Should -BeFalse
    }
}

Describe 'A field the scene no longer declares' {
    <#
        Re-cutting a scene in Titler must not destroy a producer's text. The
        value stays on disk and is simply not sent, and the screen says the
        field is gone - punishing the producer for a designer's edit is the
        wrong answer to the wrong person.
    #>
    It 'is not sent on air' {
        $board = New-TestContentBoard

        $values = Get-BoardItemValues -Item $board.Items[0] -TextFields @('title.Text')

        @($values.Keys) | Should -Be @('title.Text')
    }

    It 'is still in the file, and is named so a screen can say so' {
        $board = New-TestContentBoard

        Get-BoardOrphanFields -Item $board.Items[0] -TextFields @('title.Text') | Should -Be @('Subject.Text')
        $board.Items[0].Values.'Subject.Text' | Should -Be 'أحمد'
    }

    It 'reports nothing when every stored field is still declared' {
        Get-BoardOrphanFields -Item (New-TestContentBoard).Items[0] -TextFields $script:TestFields | Should -BeNullOrEmpty
    }
}

Describe 'A producer pasting a prepared block' {
    It 'reads one line per row with the fields in the scene order' {
        $parsed = ConvertFrom-BoardPasteText -Text "ضيف|أحمد`nسعر|ارتفاع" -TextFields $script:TestFields

        @($parsed.Rows).Count | Should -Be 2
        $parsed.Rows[1]['Subject.Text'] | Should -Be 'ارتفاع'
    }

    It 'needs no separator at all when the scene declares one field' {
        $parsed = ConvertFrom-BoardPasteText -Text "خبر أول`nخبر ثانٍ" -TextFields @('Ajel.center')

        @($parsed.Rows).Count | Should -Be 2
        $parsed.Rows[0]['Ajel.center'] | Should -Be 'خبر أول'
    }

    It 'drops blank lines without counting them as anything' {
        (ConvertFrom-BoardPasteText -Text "أول|1`n`n   `nثانٍ|2" -TextFields $script:TestFields).Rows.Count | Should -Be 2
    }

    It 'names what it refused rather than reporting only what it took' {
        # "23 rows added" with no mention of the seven that were not is the
        # shape of a screen an operator stops believing.
        $parsed = ConvertFrom-BoardPasteText -Text "سليم|نعم`nزائد|أ|ب" -TextFields $script:TestFields

        @($parsed.Rows).Count | Should -Be 1
        @($parsed.Skipped).Count | Should -Be 1
        $parsed.Skipped[0] | Should -Match '3'
    }

    It 'fills the missing tail fields rather than refusing a short line' {
        $parsed = ConvertFrom-BoardPasteText -Text 'العنوان وحده' -TextFields $script:TestFields

        $parsed.Rows[0]['title.Text'] | Should -Be 'العنوان وحده'
        $parsed.Rows[0]['Subject.Text'] | Should -Be ''
    }
}

Describe 'Either shape a board can arrive in' {
    It 'reads a hashtable, an ordered dictionary and an object alike' {
        # [ordered]@{} is an OrderedDictionary, which is NOT a Hashtable and
        # exposes none of its keys as PSObject properties - read as a plain
        # object it answers $null for every one of them.
        $plain = @{ Name = 'بنر' }
        $ordered = [ordered]@{ Name = 'بنر' }
        $object = [pscustomobject]@{ Name = 'بنر' }

        foreach ($shape in @($plain, $ordered, $object)) {
            Get-BoardProperty $shape 'Name' | Should -Be 'بنر'
            Get-BoardProperty $shape 'Missing' 'fallback' | Should -Be 'fallback'
        }
    }
}
