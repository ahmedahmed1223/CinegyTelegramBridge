#requires -Version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeUrgent.psm1') -Force

    function New-TestBoard {
        <#
            Three lines, nothing overridden - the shape almost every test below
            starts from.

            Defaults ride along as a property the tests set and pass back into
            the planner. They are not part of the saved board: the live ones are
            settings, and Get-UrgentBoardDefaults builds this same shape out of
            them.
        #>
        param([int]$Count = 3)
        $board = New-UrgentBoard
        for ($index = 1; $index -le $Count; $index++) {
            $board = (Add-UrgentItem -Board $board -Text "عاجل $index" -UserId 7).Value
        }
        $board | Add-Member -NotePropertyName Defaults -NotePropertyValue (New-UrgentDefaults) -Force
        return $board
    }
}

Describe 'Urgent board domain' {
    It 'budgets the exit of an auto-hide line before the following text line' {
        $board = New-TestBoard -Count 2
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[0].Id -Field Mode -Value 'auto_hide').Value
        $plan = (New-UrgentRunPlan -Items $board.Items -Defaults (New-UrgentDefaults) -TransitionSeconds 3).Value
        $plan.Steps[1].TransitionSeconds | Should -Be 3
        $plan.TotalSeconds | Should -Be 19
    }

    It 'does not let per-item repeats exceed a hard ceiling after auto-hide transitions' {
        $board = New-TestBoard -Count 2
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[0].Id -Field Mode -Value 'auto_hide').Value
        $defaults = New-UrgentDefaults
        $defaults.RepeatMode = 'item'
        $defaults.Repeats = 2
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[1].Id -Field Mode -Value 'exit').Value
        $plan = (New-UrgentRunPlan -Items $board.Items -Defaults $defaults -TransitionSeconds 3 -MaxSeconds 38).Value
        $plan.TotalSeconds | Should -BeLessOrEqual 38
    }

    It 'adds normalized items with stable ids and refuses empty or oversized text' {
        $board = New-UrgentBoard
        $added = Add-UrgentItem -Board $board -Text "  خبر    عاجل  " -UserId 11
        $empty = Add-UrgentItem -Board $added.Value -Text '   ' -UserId 11
        $long = Add-UrgentItem -Board $added.Value -Text ('ط' * 301) -UserId 11

        $added.Success | Should -BeTrue
        $added.Value.Items.Count | Should -Be 1
        $added.Value.Items[0].Text | Should -Be 'خبر عاجل'
        $added.Value.Items[0].Id | Should -Match '^u_[a-f0-9]{8}$'
        $added.Value.Revision | Should -Be 2
        $empty.Success | Should -BeFalse
        $empty.ErrorCode | Should -Be 'invalid_text'
        $long.ErrorCode | Should -Be 'too_long'
    }

    It 'never mutates the board it was given' {
        $board = New-TestBoard -Count 2
        $originalFirst = $board.Items[0].Text
        $edited = Set-UrgentItem -Board $board -ItemId $board.Items[0].Id -Field Text -Value 'تغيّر' -UserId 3

        $edited.Success | Should -BeTrue
        $edited.Value.Items[0].Text | Should -Be 'تغيّر'
        $board.Items[0].Text | Should -Be $originalFirst
    }

    It 'refuses the item edits that would put nonsense on air' {
        $board = New-TestBoard -Count 1
        $id = $board.Items[0].Id

        (Set-UrgentItem -Board $board -ItemId $id -Field Mode -Value 'fade').ErrorCode | Should -Be 'invalid_mode'
        (Set-UrgentItem -Board $board -ItemId $id -Field RepeatMode -Value 'random').ErrorCode | Should -Be 'invalid_repeat_mode'
        (Set-UrgentItem -Board $board -ItemId $id -Field IntervalSeconds -Value 'ثمانية').ErrorCode | Should -Be 'invalid_number'
        (Set-UrgentItem -Board $board -ItemId $id -Field IntervalSeconds -Value -1).ErrorCode | Should -Be 'invalid_number'
        (Set-UrgentItem -Board $board -ItemId $id -Field Repeats -Value 100).ErrorCode | Should -Be 'invalid_number'
        (Set-UrgentItem -Board $board -ItemId 'u_nope' -Field Text -Value 'x').ErrorCode | Should -Be 'not_found'
    }

    It 'moves an item without losing the others, and refuses to move past the ends' {
        $board = New-TestBoard -Count 3
        $second = $board.Items[1].Id
        $moved = Move-UrgentItem -Board $board -ItemId $second -Delta -1

        $moved.Success | Should -BeTrue
        @($moved.Value.Items).Count | Should -Be 3
        $moved.Value.Items[0].Id | Should -Be $second
        $moved.Value.Items[1].Text | Should -Be 'عاجل 1'
        (Move-UrgentItem -Board $board -ItemId $board.Items[0].Id -Delta -1).ErrorCode | Should -Be 'out_of_range'
        (Move-UrgentItem -Board $board -ItemId $board.Items[2].Id -Delta 1).ErrorCode | Should -Be 'out_of_range'
    }

    It 'stops adding at the table limit' {
        $board = New-UrgentBoard
        for ($index = 0; $index -lt 3; $index++) {
            $board = (Add-UrgentItem -Board $board -Text "عاجل $index" -MaxItems 3).Value
        }
        $overflow = Add-UrgentItem -Board $board -Text 'واحد زائد' -MaxItems 3

        $overflow.Success | Should -BeFalse
        $overflow.ErrorCode | Should -Be 'full'
    }

    It 'reads its fields off a hashtable, an ordered dictionary and an object alike' {
        # [ordered]@{} is an OrderedDictionary: not a [hashtable], and its keys
        # are not PSObject properties either - so a reader that tests only for
        # [hashtable] answers $null to every key on it.
        $plain = @{ IntervalSeconds = 5 }
        $ordered = [ordered]@{ IntervalSeconds = 6 }
        $object = [pscustomobject]@{ IntervalSeconds = 7 }

        (Get-UrgentProperty $plain 'IntervalSeconds' 0) | Should -Be 5
        (Get-UrgentProperty $ordered 'IntervalSeconds' 0) | Should -Be 6
        (Get-UrgentProperty $object 'IntervalSeconds' 0) | Should -Be 7
        (Get-UrgentProperty $ordered 'Missing' 'fallback') | Should -Be 'fallback'
        (Get-UrgentProperty $null 'IntervalSeconds' 99) | Should -Be 99
    }
}

Describe 'Urgent effective timing' {
    It 'treats zero as inherit and says which numbers were inherited' {
        $defaults = New-UrgentDefaults
        $defaults.IntervalSeconds = 9
        $defaults.Repeats = 2
        $item = @{ Mode = ''; IntervalSeconds = 0; TotalSeconds = 0; Repeats = 0; RepeatMode = '' }

        $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults

        $timing.IntervalSeconds | Should -Be 9
        $timing.Repeats | Should -Be 2
        $timing.Mode | Should -Be 'text'
        $timing.RepeatMode | Should -Be 'cycle'
        $timing.IntervalInherited | Should -BeTrue
        $timing.RepeatsInherited | Should -BeTrue
    }

    It 'lets an item override every inherited number' {
        $defaults = New-UrgentDefaults
        $item = @{ Mode = 'exit'; IntervalSeconds = 15; TotalSeconds = 120; Repeats = 4; RepeatMode = 'item' }

        $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults

        $timing.Mode | Should -Be 'exit'
        $timing.IntervalSeconds | Should -Be 15
        $timing.TotalSeconds | Should -Be 120
        $timing.Repeats | Should -Be 4
        $timing.RepeatMode | Should -Be 'item'
        $timing.IntervalInherited | Should -BeFalse
        $timing.ModeInherited | Should -BeFalse
    }

    It 'raises a too-short interval to the floor the scene sets, and flags it' {
        $defaults = New-UrgentDefaults
        $item = @{ IntervalSeconds = 2 }

        $timing = Get-UrgentEffectiveTiming -Item $item -Defaults $defaults -FloorSeconds 4.5

        $timing.IntervalSeconds | Should -Be 2
        $timing.HoldSeconds | Should -Be 4.5
        $timing.IntervalRaisedToFloor | Should -BeTrue
    }

    It 'keeps the floor a double rather than truncating it to a whole second' {
        # [math]::Max(0, $double) picks the int overload and drops the fraction
        # in silence; the literals in the resolver are 0.0 for exactly this.
        $timing = Get-UrgentEffectiveTiming -Item @{ IntervalSeconds = 3 } -Defaults (New-UrgentDefaults) -FloorSeconds 3.75

        $timing.HoldSeconds | Should -Be 3.75
    }
}

Describe 'Urgent run plan' {
    It 'orders a cycle run 1 2 3 · 1 2 3' {
        $board = New-TestBoard -Count 3
        $board.Defaults.Repeats = 2
        $board.Defaults.RepeatMode = 'cycle'

        $plan = New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults

        $plan.Success | Should -BeTrue
        $plan.Value.StepCount | Should -Be 6
        @($plan.Value.Steps | ForEach-Object { $_.Text }) -join ',' |
            Should -Be 'عاجل 1,عاجل 2,عاجل 3,عاجل 1,عاجل 2,عاجل 3'
        $plan.Value.RepeatMode | Should -Be 'cycle'
    }

    It 'orders an item run 1 1 · 2 2 · 3 3' {
        $board = New-TestBoard -Count 3
        $board.Defaults.Repeats = 2
        $board.Defaults.RepeatMode = 'item'

        $plan = New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults

        @($plan.Value.Steps | ForEach-Object { $_.Text }) -join ',' |
            Should -Be 'عاجل 1,عاجل 1,عاجل 2,عاجل 2,عاجل 3,عاجل 3'
    }

    It 'defaults to the whole-table order' {
        $board = New-TestBoard -Count 2
        $board.Defaults.Repeats = 2

        (New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults).Value.RepeatMode | Should -Be 'cycle'
    }

    It 'places every moment absolutely, not as a running sum of drift' {
        $board = New-TestBoard -Count 3
        $board.Defaults.IntervalSeconds = 10

        $steps = @((New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults).Value.Steps)

        @($steps | ForEach-Object { $_.AtSeconds }) | Should -Be @(0, 10, 20)
    }

    It 'charges an exit-mode line its transition, and never charges the first line twice' {
        $board = New-TestBoard -Count 3
        $board.Defaults.IntervalSeconds = 10
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[0].Id -Field Mode -Value 'exit').Value
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[2].Id -Field Mode -Value 'exit').Value

        $plan = New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults -TransitionSeconds 2

        $steps = @($plan.Value.Steps)
        # The first line rides the SHOW: it acts at 0 and is visible at 0.
        $steps[0].TransitionSeconds | Should -Be 0
        $steps[0].VisibleAtSeconds | Should -Be 0
        # Text line: written into the scene already up, so nothing to wait for.
        $steps[1].AtSeconds | Should -Be 10
        $steps[1].TransitionSeconds | Should -Be 0
        # Exit line: acts at 20, visible two seconds later once the outro and
        # the entrance have played.
        $steps[2].AtSeconds | Should -Be 20
        $steps[2].TransitionSeconds | Should -Be 2
        $steps[2].VisibleAtSeconds | Should -Be 22
        $plan.Value.TotalSeconds | Should -Be 32
    }

    It 'trims the cycles to the ceiling instead of overrunning it, and says so' {
        $board = New-TestBoard -Count 2
        $board.Defaults.IntervalSeconds = 10
        $board.Defaults.Repeats = 5

        $plan = New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults -MaxSeconds 45

        $plan.Success | Should -BeTrue
        $plan.Value.Cycles | Should -Be 2
        $plan.Value.RequestedCycles | Should -Be 5
        $plan.Value.TrimmedBy | Should -Be 'total'
        $plan.Value.TotalSeconds | Should -BeLessOrEqual 45
        @($plan.Value.Notes) -join ' ' | Should -Match 'قصّ التكرار من 5 إلى 2'
    }

    It 'names the forced hide when that is what cut the run short' {
        $board = New-TestBoard -Count 2
        $board.Defaults.IntervalSeconds = 10
        $board.Defaults.Repeats = 4

        $plan = New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults -MaxSeconds 30 -MaxReason 'autohide'

        $plan.Value.TrimmedBy | Should -Be 'autohide'
        @($plan.Value.Notes) -join ' ' | Should -Match 'الإخفاء التلقائي'
    }

    It 'refuses a run when even one cycle does not fit under the ceiling' {
        $board = New-TestBoard -Count 4
        $board.Defaults.IntervalSeconds = 10

        $plan = New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults -MaxSeconds 25 -MaxReason 'autohide'

        $plan.Success | Should -BeFalse
        $plan.ErrorCode | Should -Be 'no_fit'
        $plan.Error | Should -Match '40 ث'
    }

    It 'refuses an empty selection rather than showing nothing on air' {
        (New-UrgentRunPlan -Items @() -Defaults (New-UrgentDefaults)).ErrorCode | Should -Be 'empty'
    }

    It 'warns when an item-order run would exit and return with the same words' {
        $board = New-TestBoard -Count 2
        $board.Defaults.Repeats = 2
        $board.Defaults.RepeatMode = 'item'
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[0].Id -Field Mode -Value 'exit').Value

        $plan = New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults -TransitionSeconds 2

        @($plan.Value.Notes) -join ' ' | Should -Match 'يخرج ويعود بالنصّ نفسه'
    }

    It 'lets the first item that states an order or a repeat count carry the run' {
        $board = New-TestBoard -Count 2
        $board.Defaults.Repeats = 1
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[1].Id -Field RepeatMode -Value 'item').Value
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[1].Id -Field Repeats -Value 3).Value

        $plan = New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults

        $plan.Value.RepeatMode | Should -Be 'item'
        $plan.Value.Cycles | Should -Be 3
        $plan.Value.StepCount | Should -Be 6
    }

    It 'summarises the run in the line the operator reads before it starts' {
        $board = New-TestBoard -Count 3
        $board.Defaults.IntervalSeconds = 8
        $board.Defaults.Repeats = 2
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[0].Id -Field Mode -Value 'exit').Value

        $summary = Get-UrgentPlanSummary -Plan (New-UrgentRunPlan -Items @($board.Items) -Defaults $board.Defaults -TransitionSeconds 2).Value

        $summary | Should -Match '3 عاجلًا'
        $summary | Should -Match '2 دورة'
        $summary | Should -Match 'الجدول كاملًا ثم يعيد'
        $summary | Should -Match 'الزمن المتوقّع 0:50'
        $summary | Should -Match 'بحركة خروج'
    }
}

Describe 'Urgent selection' {
    It 'plays the whole table, or only what this chat selected' {
        $board = New-TestBoard -Count 3
        $selected = @($board.Items[0].Id, $board.Items[2].Id)

        $all = @(Get-UrgentPlayableItems -Board $board)
        $some = @(Get-UrgentPlayableItems -Board $board -SelectedIds $selected -SelectedOnly)

        $all.Count | Should -Be 3
        $some.Count | Should -Be 2
        @($some | ForEach-Object { $_.Text }) -join ',' | Should -Be 'عاجل 1,عاجل 3'
    }

    It 'leaves a disabled item out of both' {
        $board = New-TestBoard -Count 3
        $board = (Set-UrgentItem -Board $board -ItemId $board.Items[1].Id -Field Enabled -Value $false).Value

        @(Get-UrgentPlayableItems -Board $board).Count | Should -Be 2
        @(Get-UrgentPlayableItems -Board $board -SelectedIds @($board.Items[1].Id) -SelectedOnly).Count | Should -Be 0
    }
}
