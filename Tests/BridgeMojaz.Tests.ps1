#requires -Version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\BridgeMojaz.psm1') -Force
}

Describe 'Mojaz bulletin library domain' {
    It 'creates named bulletins with stable ids and normalized unique names' {
        $library = New-MojazLibrary
        $first = Add-MojazBulletin -Library $library -Name '  الموجز   الصباحي  ' -Now ([datetimeoffset]'2026-09-02T08:00:00+03:00') -UserId 11
        $duplicate = Add-MojazBulletin -Library $first.Value -Name 'الموجز الصباحي' -Now ([datetimeoffset]'2026-09-02T08:01:00+03:00') -UserId 12

        $first.Success | Should -BeTrue
        $first.Value.Bulletins.Count | Should -Be 1
        $first.Value.Bulletins[0].Name | Should -Be 'الموجز الصباحي'
        $first.Value.Bulletins[0].Id | Should -Match '^b_[a-f0-9]{8}$'
        $duplicate.Success | Should -BeFalse
        $duplicate.ErrorCode | Should -Be 'duplicate_name'
    }

    It 'copies a bulletin without sharing its rows and starts a new revision' {
        $library = New-MojazLibrary
        $created = Add-MojazBulletin -Library $library -Name 'صباحي' -Now ([datetimeoffset]'2026-09-02T08:00:00+03:00') -UserId 11
        $source = $created.Value.Bulletins[0]
        $source.Rows = @(@{ Id = 'r_01'; ImageMode = 'inherit'; Image = ''; Title = 'أ'; Text = 'خبر' })
        $source.Revision = 3

        $copy = Copy-MojazBulletin -Library $created.Value -BulletinId $source.Id -Name 'مسائي' -Now ([datetimeoffset]'2026-09-02T09:00:00+03:00') -UserId 12
        $source.Rows[0].Title = 'تغيّر الأصل'

        $copy.Success | Should -BeTrue
        $copy.Value.Bulletins[1].Name | Should -Be 'مسائي'
        $copy.Value.Bulletins[1].Revision | Should -Be 1
        $copy.Value.Bulletins[1].Rows[0].Title | Should -Be 'أ'
        $copy.Value.Bulletins[1].Id | Should -Not -Be $source.Id
    }

    It 'renames a bulletin and increments only its saved revision' {
        $created = Add-MojazBulletin -Library (New-MojazLibrary) -Name 'قديم' -Now ([datetimeoffset]'2026-09-02T08:00:00+03:00') -UserId 11
        $id = $created.Value.Bulletins[0].Id

        $renamed = Rename-MojazBulletin -Library $created.Value -BulletinId $id -Name 'جديد' -Now ([datetimeoffset]'2026-09-02T10:00:00+03:00') -UserId 12

        $renamed.Success | Should -BeTrue
        $renamed.Value.Bulletins[0].Name | Should -Be 'جديد'
        $renamed.Value.Bulletins[0].Revision | Should -Be 2
        $renamed.Value.Bulletins[0].UpdatedBy | Should -Be 12
    }
}

Describe 'Mojaz immutable run snapshots' {
    It 'keeps copied rows after the editable bulletin changes' {
        $bulletin = [pscustomobject]@{
            Id = 'b_12345678'; Name = 'صباحي'; Revision = 7
            DelaySeconds = 8; IntroExtraSeconds = 0; LastRowSeconds = 0
            Rows = @(
                [pscustomobject]@{ Id='r_1'; ImageMode='new'; Image='.\Mojaz\bot\a.jpg'; Title='أ'; Text='الأول' }
                [pscustomobject]@{ Id='r_2'; ImageMode='inherit'; Image=''; Title='ب'; Text='الثاني' }
            )
        }
        $snapshot = New-MojazRunSnapshot -Bulletin $bulletin -SceneTiming ([pscustomobject]@{ IntroSeconds=1.2; OutroSeconds=6.72 }) -Now ([datetimeoffset]'2026-09-02T08:00:00+03:00')

        $bulletin.Rows[0].Title = 'معدّل'
        $bulletin.Rows = @()

        $snapshot.Success | Should -BeTrue
        $snapshot.Value.Rows.Count | Should -Be 2
        $snapshot.Value.Rows[0].Title | Should -Be 'أ'
        $snapshot.Value.BulletinRevision | Should -Be 7
    }

    It 'uses one plan for a single row including entrance dwell and exit hold' {
        $bulletin = [pscustomobject]@{
            Id='b_12345678'; Name='واحد'; Revision=1; DelaySeconds=8
            IntroExtraSeconds=0; LastRowSeconds=0
            Rows=@([pscustomobject]@{ Id='r_1'; ImageMode='inherit'; Image=''; Title='أ'; Text='خبر' })
        }

        $snapshot = New-MojazRunSnapshot -Bulletin $bulletin -SceneTiming ([pscustomobject]@{ IntroSeconds=1.2; OutroSeconds=6.72 })

        $snapshot.Value.Plan.Count | Should -Be 1
        # 8 + 1.2 + 6.72. The entrance and the exit are used as the scene cut
        # them; rounding each up to a whole second used to add 1.08 s of
        # nothing to a bulletin this short.
        $snapshot.Value.Plan[0].HoldSeconds | Should -Be 16
        $snapshot.Value.TotalSeconds | Should -Be 16
    }

    It 'plans multiple rows with intro on the first and outro hold on the last' {
        $bulletin = [pscustomobject]@{
            Id='b_12345678'; Name='متعدد'; Revision=1; DelaySeconds=8
            IntroExtraSeconds=0; LastRowSeconds=0
            Rows=@(
                [pscustomobject]@{ Id='r_1'; ImageMode='inherit'; Image=''; Title='أ'; Text='1' }
                [pscustomobject]@{ Id='r_2'; ImageMode='inherit'; Image=''; Title='ب'; Text='2' }
                [pscustomobject]@{ Id='r_3'; ImageMode='inherit'; Image=''; Title='ج'; Text='3' }
            )
        }

        $snapshot = New-MojazRunSnapshot -Bulletin $bulletin -SceneTiming ([pscustomobject]@{ IntroSeconds=1.2; OutroSeconds=6.72 })

        # 9.2, 8, 6.72 - shown rounded, but the clock runs on the fractions.
        @($snapshot.Value.Plan.HoldSeconds) | Should -Be @(9, 8, 7)
        @($snapshot.Value.Plan.AtSeconds) | Should -Be @(0, 9.2, 17.2)
        $snapshot.Value.TotalSeconds | Should -Be 24
    }
}

Describe 'Mojaz due schedule ordering' {
    It 'orders due work by scheduled time then creation time then id and excludes future work' {
        $schedules = @(
            [pscustomobject]@{ Id='c'; Status='scheduled'; ScheduledAt='2026-09-02T09:00:00+03:00'; CreatedAt='2026-09-01T08:00:00+03:00' }
            [pscustomobject]@{ Id='b'; Status='queued'; ScheduledAt='2026-09-02T08:00:00+03:00'; CreatedAt='2026-09-01T09:00:00+03:00' }
            [pscustomobject]@{ Id='a'; Status='scheduled'; ScheduledAt='2026-09-02T08:00:00+03:00'; CreatedAt='2026-09-01T09:00:00+03:00' }
            [pscustomobject]@{ Id='future'; Status='scheduled'; ScheduledAt='2026-09-02T12:00:00+03:00'; CreatedAt='2026-09-01T07:00:00+03:00' }
            [pscustomobject]@{ Id='done'; Status='completed'; ScheduledAt='2026-09-02T07:00:00+03:00'; CreatedAt='2026-09-01T07:00:00+03:00' }
        )

        $due = @(Get-MojazDueQueue -Schedules $schedules -Now ([datetimeoffset]'2026-09-02T10:00:00+03:00'))

        @($due.Id) | Should -Be @('a', 'b', 'c')
    }
}

Describe 'Mojaz bulletin row editing' {
    BeforeEach {
        $script:library = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'الصباحي').Value
        $script:id = [string]$script:library.Bulletins[0].Id
    }

    It 'adds rows with stable ids and bumps the revision once per change' {
        $first = Add-MojazBulletinRow -Library $script:library -BulletinId $script:id -Title 'أ' -Text 'خبر أ'
        $first.Success | Should -BeTrue
        $bulletin = $first.Value.Bulletins[0]
        @($bulletin.Rows).Count | Should -Be 1
        [string]$bulletin.Rows[0].Id | Should -Match '^r_[0-9a-f]{8}$'
        [int]$bulletin.Revision | Should -Be 2
        # The library handed in is never touched: only the returned copy moves.
        @($script:library.Bulletins[0].Rows).Count | Should -Be 0
    }

    It 'refuses a row with no title and no text' {
        $result = Add-MojazBulletinRow -Library $script:library -BulletinId $script:id -Title '  ' -Text ''
        $result.Success | Should -BeFalse
        $result.ErrorCode | Should -Be 'empty_row'
    }

    It 'removes one row by id and leaves an identical twin in place' {
        $library = (Add-MojazBulletinRow -Library $script:library -BulletinId $script:id -Title 'أ' -Text 'ن').Value
        $library = (Add-MojazBulletinRow -Library $library -BulletinId $script:id -Title 'أ' -Text 'ن').Value
        $target = [string]$library.Bulletins[0].Rows[0].Id
        $result = Remove-MojazBulletinRow -Library $library -BulletinId $script:id -RowId $target
        $result.Success | Should -BeTrue
        @($result.Value.Bulletins[0].Rows).Count | Should -Be 1
        [string]$result.Value.Bulletins[0].Rows[0].Id | Should -Not -Be $target
    }

    It 'moves a row up and refuses to move the first row further up' {
        $library = (Add-MojazBulletinRow -Library $script:library -BulletinId $script:id -Title 'أ' -Text 'ن').Value
        $library = (Add-MojazBulletinRow -Library $library -BulletinId $script:id -Title 'ب' -Text 'ن').Value
        $second = [string]$library.Bulletins[0].Rows[1].Id
        $moved = Move-MojazBulletinRow -Library $library -BulletinId $script:id -RowId $second -Direction up
        $moved.Success | Should -BeTrue
        [string]$moved.Value.Bulletins[0].Rows[0].Title | Should -Be 'ب'
        (Move-MojazBulletinRow -Library $moved.Value -BulletinId $script:id -RowId $second -Direction up).ErrorCode | Should -Be 'at_edge'
    }

    It 'keeps an inherited image empty and a new image as its path' {
        $library = (Add-MojazBulletinRow -Library $script:library -BulletinId $script:id -Title 'أ' -Text 'ن').Value
        [string]$library.Bulletins[0].Rows[0].ImageMode | Should -Be 'inherit'
        [string]$library.Bulletins[0].Rows[0].Image | Should -BeNullOrEmpty
        $withImage = (Add-MojazBulletinRow -Library $library -BulletinId $script:id -Title 'ب' -Text 'ن' -Image 'Mojaz\bot\a.jpg').Value
        [string]$withImage.Bulletins[0].Rows[1].ImageMode | Should -Be 'new'
    }

    It 'clears every row and validates timing bounds' {
        $library = (Add-MojazBulletinRow -Library $script:library -BulletinId $script:id -Title 'أ' -Text 'ن').Value
        @((Clear-MojazBulletinRows -Library $library -BulletinId $script:id).Value.Bulletins[0].Rows).Count | Should -Be 0
        (Set-MojazBulletinTiming -Library $library -BulletinId $script:id -DelayFrames 300).Value.Bulletins[0].DelayFrames | Should -Be 300
        (Set-MojazBulletinTiming -Library $library -BulletinId $script:id -DelayFrames 0).ErrorCode | Should -Be 'out_of_range'
        (Set-MojazBulletinTiming -Library $library -BulletinId $script:id -DelayFrames 15001).ErrorCode | Should -Be 'out_of_range'
    }

    It 'reports a missing bulletin instead of throwing' {
        (Add-MojazBulletinRow -Library $script:library -BulletinId 'b_nope' -Title 'أ' -Text 'ن').ErrorCode | Should -Be 'not_found'
        (Remove-MojazBulletin -Library $script:library -BulletinId 'b_nope').ErrorCode | Should -Be 'not_found'
    }

    It 'removes a whole bulletin and leaves the others alone' {
        $library = (Add-MojazBulletin -Library $script:library -Name 'المسائي').Value
        $result = Remove-MojazBulletin -Library $library -BulletinId $script:id
        $result.Success | Should -BeTrue
        @($result.Value.Bulletins).Count | Should -Be 1
        [string]$result.Value.Bulletins[0].Name | Should -Be 'المسائي'
    }
}

Describe 'Which picture each row actually shows' {
    BeforeEach {
        $script:library = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'الصباحي').Value
        $script:id = [string]$script:library.Bulletins[0].Id
    }

    It 'lets one picture stand for a run of rows that inherit it' {
        # The whole point of the inherit mode: set the picture once and the
        # rows after it keep showing it.
        $rows = @(
            [pscustomobject]@{ Id = 'r_1'; ImageMode = 'new'; Image = 'a.jpg'; Title = 'أ'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_2'; ImageMode = 'inherit'; Image = ''; Title = 'ب'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_3'; ImageMode = 'inherit'; Image = ''; Title = 'ج'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_4'; ImageMode = 'new'; Image = 'b.jpg'; Title = 'د'; Text = 'ن' }
        )

        $effective = @(Get-MojazEffectiveImages -Rows $rows -TemplateImage 'pic01.png')

        $effective | Should -Be @('a.jpg', 'a.jpg', 'a.jpg', 'b.jpg')
    }

    It 'starts from the template picture, and goes back to it on request' {
        $rows = @(
            [pscustomobject]@{ Id = 'r_1'; ImageMode = 'inherit'; Image = ''; Title = 'أ'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_2'; ImageMode = 'new'; Image = 'a.jpg'; Title = 'ب'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_3'; ImageMode = 'template'; Image = ''; Title = 'ج'; Text = 'ن' }
        )

        $effective = @(Get-MojazEffectiveImages -Rows $rows -TemplateImage 'pic01.png')

        # The first row inherits nothing, so it is the scene's own picture.
        $effective | Should -Be @('pic01.png', 'a.jpg', 'pic01.png')
    }

    It 'reads a row written before modes existed by whether it has a path' {
        $rows = @(
            [pscustomobject]@{ Id = 'r_1'; Image = 'a.jpg'; Title = 'أ'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_2'; Image = ''; Title = 'ب'; Text = 'ن' }
        )

        @(Get-MojazEffectiveImages -Rows $rows -TemplateImage 'pic01.png') | Should -Be @('a.jpg', 'a.jpg')
    }

    It 'stores the mode the caller asked for, path or not' {
        $result = Add-MojazBulletinRow -Library $script:library -BulletinId $script:id -Title 'أ' -Text 'ن' -ImageMode template
        [string]$result.Value.Bulletins[0].Rows[0].ImageMode | Should -Be 'template'
        [string]$result.Value.Bulletins[0].Rows[0].Image | Should -BeNullOrEmpty
    }

    It 'changes one row picture without touching its title or story' {
        $library = (Add-MojazBulletinRow -Library $script:library -BulletinId $script:id -Title 'عنوان' -Text 'خبر' -Image 'a.jpg').Value
        $rowId = [string]$library.Bulletins[0].Rows[0].Id

        $result = Set-MojazBulletinRow -Library $library -BulletinId $script:id -RowId $rowId -Image '' -ImageMode inherit

        $row = $result.Value.Bulletins[0].Rows[0]
        [string]$row.ImageMode | Should -Be 'inherit'
        [string]$row.Image | Should -BeNullOrEmpty
        [string]$row.Title | Should -Be 'عنوان'
        [string]$row.Text | Should -Be 'خبر'
    }

    It 'lists each distinct picture the bulletin already carries, once' {
        $rows = @(
            [pscustomobject]@{ Id = 'r_1'; ImageMode = 'new'; Image = 'a.jpg'; Title = 'أ'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_2'; ImageMode = 'inherit'; Image = ''; Title = 'ب'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_3'; ImageMode = 'new'; Image = 'a.jpg'; Title = 'ج'; Text = 'ن' }
            [pscustomobject]@{ Id = 'r_4'; ImageMode = 'new'; Image = 'b.jpg'; Title = 'د'; Text = 'ن' }
        )

        @(Get-MojazUsedImages -Rows $rows) | Should -Be @('a.jpg', 'b.jpg')
    }
}

Describe 'Timing a bulletin against the loop it plays in' {
    BeforeAll {
        # The scene as it ships: 25 fps, entrance 0-30, loop 30-1530.
        $script:sceneTiming = [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 60; OutroSeconds = 6.72 }
        # The same scene re-cut so one loop is one story: loop 30-230.
        $script:shortLoop = [pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 8; OutroSeconds = 6.72 }
    }

    It 'writes each row just after a loop wrap, where the fade hides it' {
        # The first wrap is LoopEnd/Fps after SHOW - the entrance plus one
        # loop - and every wrap after it is one loop apart.
        $plan = New-MojazLoopPlan -SceneTiming $script:shortLoop -RowCount 3 -OffsetSeconds 0.4

        @($plan.WriteOffsets) | Should -Be @(0, 9.6, 17.6)
        $plan.ExitOffset | Should -Be 25.2
    }

    It 'leaves the last row a full loop before the exit' {
        $plan = New-MojazLoopPlan -SceneTiming $script:shortLoop -RowCount 1 -OffsetSeconds 0.4

        @($plan.WriteOffsets) | Should -Be @(0)
        # One loop of screen time, then out - no write at all after SHOW.
        $plan.ExitOffset | Should -Be 9.2
    }

    It 'keeps every write inside the window the fade covers' {
        $plan = New-MojazLoopPlan -SceneTiming $script:shortLoop -RowCount 4 -OffsetSeconds 0.4
        $fade = $script:shortLoop.IntroSeconds

        foreach ($offset in @($plan.WriteOffsets)[1..3]) {
            $sinceWrap = ($offset - ($script:shortLoop.IntroSeconds + $script:shortLoop.LoopSeconds)) % $script:shortLoop.LoopSeconds
            $sinceWrap | Should -BeGreaterOrEqual 0
            $sinceWrap | Should -BeLessThan $fade
        }
    }

    It 'refuses to plan against a scene with no usable loop' {
        New-MojazLoopPlan -SceneTiming $null -RowCount 3 | Should -BeNullOrEmpty
        New-MojazLoopPlan -SceneTiming ([pscustomobject]@{ Fps = 25; IntroSeconds = 1.2; LoopSeconds = 0; OutroSeconds = 1 }) -RowCount 3 | Should -BeNullOrEmpty
    }

    It 'gives every row an absolute moment, so a late row does not push the rest' {
        # Without sync, the moments are the dwells added up - but they are
        # still absolute from the start, not measured from the previous send.
        $bulletin = [pscustomobject]@{
            Id = 'b_1'; Name = 'ن'; Revision = 1; DelaySeconds = 10; IntroExtraSeconds = 2; LastRowSeconds = 5
            Rows = @(
                [pscustomobject]@{ Id = 'r_1'; ImageMode = 'inherit'; Image = ''; Title = 'أ'; Text = 'ن' }
                [pscustomobject]@{ Id = 'r_2'; ImageMode = 'inherit'; Image = ''; Title = 'ب'; Text = 'ن' }
                [pscustomobject]@{ Id = 'r_3'; ImageMode = 'inherit'; Image = ''; Title = 'ج'; Text = 'ن' }
            )
        }

        $snapshot = (New-MojazRunSnapshot -Bulletin $bulletin).Value

        @($snapshot.Plan | ForEach-Object { $_.AtSeconds }) | Should -Be @(0, 12, 22)
        $snapshot.ExitAtSeconds | Should -Be 27
        $snapshot.SyncToLoop | Should -BeFalse
    }

    It 'takes its moments from the loop when the bulletin asks for sync' {
        $bulletin = [pscustomobject]@{
            Id = 'b_1'; Name = 'ن'; Revision = 1; DelaySeconds = 30; IntroExtraSeconds = 0; LastRowSeconds = 0
            SyncToLoop = $true
            Rows = @(
                [pscustomobject]@{ Id = 'r_1'; ImageMode = 'inherit'; Image = ''; Title = 'أ'; Text = 'ن' }
                [pscustomobject]@{ Id = 'r_2'; ImageMode = 'inherit'; Image = ''; Title = 'ب'; Text = 'ن' }
            )
        }

        $snapshot = (New-MojazRunSnapshot -Bulletin $bulletin -SceneTiming $script:shortLoop -OffsetSeconds 0.4).Value

        $snapshot.SyncToLoop | Should -BeTrue
        # The bulletin's own 30 second dwell is ignored: the loop is 8.
        @($snapshot.Plan | ForEach-Object { $_.AtSeconds }) | Should -Be @(0, 9.6)
        $snapshot.ExitAtSeconds | Should -Be 17.2
    }

    It 'falls back to the dwell when sync is asked for but the scene cannot give it' {
        $bulletin = [pscustomobject]@{
            Id = 'b_1'; Name = 'ن'; Revision = 1; DelaySeconds = 10; IntroExtraSeconds = 0; LastRowSeconds = 0
            SyncToLoop = $true
            Rows = @([pscustomobject]@{ Id = 'r_1'; ImageMode = 'inherit'; Image = ''; Title = 'أ'; Text = 'ن' })
        }

        $snapshot = (New-MojazRunSnapshot -Bulletin $bulletin -SceneTiming $null).Value

        $snapshot.SyncToLoop | Should -BeFalse
        $snapshot.ExitAtSeconds | Should -BeGreaterThan 0
    }
}

Describe 'Reading a design contract out of the scene' {
    BeforeAll {
        # Taken verbatim from mojaz.cintitle: the variable declares the name
        # and the type, and the element that consumes it declares the shape.
        $script:SceneXml = @'
<Scene Fps="25.000" Duration="1698" LoopStartFrame="30" LoopEndFrame="1530">
  <Var Name="mojaz_img" Type="File" UpdateType="Instant" Value=".\Mojaz\Pic01.png" />
  <Var Name="title.Text" Type="String" UpdateType="Instant" Value="قطاع غزة" />
  <Var Name="Subject.Text" Type="String" UpdateType="Instant" Value="نص الخبر" />
  <Plate Name="img 01" Start="30" Size="525.38;291.61" Source="File" File="${mojaz_img}" />
  <Text Name="title" Size="400.00;81.00" Text="${title.Text}" />
  <Text Name="subject" Size="479.00;385.00" Text="${Subject.Text}" />
</Scene>
'@
    }

    It 'names every field the design asks to be given' {
        @(Get-BridgeSceneFields -Xml $script:SceneXml).Name |
            Should -Be @('mojaz_img', 'title.Text', 'Subject.Text')
    }

    It 'tells media from text by the declared type' {
        $fields = @(Get-BridgeSceneFields -Xml $script:SceneXml)
        ($fields | Where-Object Name -eq 'mojaz_img').Kind | Should -Be 'media'
        ($fields | Where-Object Name -eq 'title.Text').Kind | Should -Be 'text'
    }

    It 'reads the size from the element that consumes the variable' {
        # This is the number a picture must be resized to, and it belongs to
        # this design - a second design with a wider box needs its own, which
        # is why a single global setting could never be right for both.
        $picture = @(Get-BridgeSceneFields -Xml $script:SceneXml) | Where-Object Name -eq 'mojaz_img'
        $picture.Width | Should -Be 525
        $picture.Height | Should -Be 292
        $picture.Element | Should -Be 'Plate'
    }

    It 'matches a variable whose name contains a dot to its own element' {
        # 'title.Text' and 'Subject.Text' both end in .Text; an unescaped dot
        # in the lookup would let one match the other's element and report the
        # wrong box size.
        $fields = @(Get-BridgeSceneFields -Xml $script:SceneXml)
        ($fields | Where-Object Name -eq 'title.Text').Height | Should -Be 81
        ($fields | Where-Object Name -eq 'Subject.Text').Height | Should -Be 385
    }

    It 'flags a variable no element consumes rather than hiding it' {
        # A field an operator would be asked to fill whose value then appears
        # nowhere on screen. Better said out loud at registration.
        $orphan = Get-BridgeSceneFields -Xml '<Scene><Var Name="unused" Type="String" /></Scene>'
        @($orphan).Count | Should -Be 1
        $orphan[0].Consumed | Should -BeFalse
        $orphan[0].Width | Should -Be 0
    }

    It 'discovers element types nobody enumerated in advance' {
        # ticker.cintitle feeds a Marquee. Reading the scene finds that;
        # a hand-written list of known element types would not have.
        $marquee = Get-BridgeSceneFields -Xml '<Scene><Var Name="New File" Type="File" /><Marquee Size="1699.00;75.00" File="${New File}" /></Scene>'
        $marquee[0].Element | Should -Be 'Marquee'
        $marquee[0].Width | Should -Be 1699
    }

    It 'returns nothing for a scene that declares nothing, without throwing' {
        @(Get-BridgeSceneFields -Xml '').Count | Should -Be 0
        @(Get-BridgeSceneFields -Xml '<Scene />').Count | Should -Be 0
    }
}

Describe 'A design that is not the news design' {
    BeforeAll {
        $script:NewsScene = '<Scene LoopStartFrame="30" LoopEndFrame="1530"><Var Name="mojaz_img" Type="File" /><Var Name="title.Text" Type="String" /><Plate Size="525.38;291.61" File="${mojaz_img}" /><Text Size="400;81" Text="${title.Text}" /></Scene>'
        # One video and nothing else. A perfectly good bulletin, and the rule
        # this replaced - picture AND title AND story - would have refused it.
        $script:VideoScene = '<Scene LoopStartFrame="30" LoopEndFrame="1530"><Var Name="clip" Type="File" /><Plate Size="1920.00;1080.00" Source="File" File="${clip}" /></Scene>'
    }

    It 'accepts a design that is a single video' {
        $verdict = Test-BridgeSceneUsable -Xml $script:VideoScene
        $verdict.Usable | Should -BeTrue
        @($verdict.Fields).Count | Should -Be 1
        $verdict.Fields[0].Kind | Should -Be 'media'
        $verdict.Fields[0].Width | Should -Be 1920
    }

    It 'refuses a scene with nothing to fill' {
        # A variable no element consumes is not a field.
        $verdict = Test-BridgeSceneUsable -Xml '<Scene LoopStartFrame="30" LoopEndFrame="1530"><Var Name="unused" Type="String" /></Scene>'
        $verdict.Usable | Should -BeFalse
        $verdict.Reason | Should -Match 'حقلًا واحدًا'
    }

    It 'reports a missing loop rather than refusing the design' {
        # A loop is what lets one scene hold while row after row is written
        # into it. Without one the design still works - it carries a single
        # story, which is what a video report is - so this says "no rows"
        # instead of "no".
        $verdict = Test-BridgeSceneUsable -Xml '<Scene><Var Name="clip" Type="File" /><Plate File="${clip}" /></Scene>'
        $verdict.Usable | Should -BeTrue
        $verdict.SupportsRows | Should -BeFalse
    }

    It 'accepts the built-in news design unchanged' {
        (Test-BridgeSceneUsable -Xml $script:NewsScene).Usable | Should -BeTrue
    }
}

Describe 'A row that carries a design its fields' {
    BeforeEach { $script:Library = New-MojazLibrary }

    It 'takes a row with no title and no story when the design has neither' {
        $script:Library = (Add-MojazBulletin -Library $script:Library -Name 'موجز فيديو' -TemplateKey 'Mojaz-Video').Value
        $bulletin = $script:Library.Bulletins[0]
        $result = Add-MojazBulletinRow -Library $script:Library -BulletinId $bulletin.Id -Fields @{ clip = 'D:\clips\a.mp4' }

        $result.Success | Should -BeTrue
        $row = @($result.Value.Bulletins[0].Rows)[0]
        $row.Fields.clip | Should -Be 'D:\clips\a.mp4'
    }

    It 'still refuses a row where nothing at all was filled' {
        $script:Library = (Add-MojazBulletin -Library $script:Library -Name 'موجز فيديو' -TemplateKey 'Mojaz-Video').Value
        $bulletin = $script:Library.Bulletins[0]
        $result = Add-MojazBulletinRow -Library $script:Library -BulletinId $bulletin.Id -Fields @{ clip = '   ' }

        $result.Success | Should -BeFalse
        $result.ErrorCode | Should -Be 'empty_row'
    }

    It 'leaves the built-in design exactly as it was' {
        # The option ships off, and with no field bag the old rule is the rule.
        $script:Library = (Add-MojazBulletin -Library $script:Library -Name 'موجز').Value
        $bulletin = $script:Library.Bulletins[0]
        $bulletin.TemplateKey | Should -Be ''
        (Add-MojazBulletinRow -Library $script:Library -BulletinId $bulletin.Id -Title '' -Text '').ErrorCode | Should -Be 'empty_row'

        $ok = Add-MojazBulletinRow -Library $script:Library -BulletinId $bulletin.Id -Title 'عنوان' -Text 'نص'
        $ok.Success | Should -BeTrue
        @($ok.Value.Bulletins[0].Rows)[0].PSObject.Properties.Name | Should -Not -Contain 'Fields'
    }

    It 'keeps a value the current design has no field for' {
        # Moving a bulletin between designs must not quietly destroy copy: the
        # editor stops asking for it, and moving back finds it still there.
        $script:Library = (Add-MojazBulletin -Library $script:Library -Name 'موجز' -TemplateKey 'A').Value
        $bulletin = $script:Library.Bulletins[0]
        $result = Add-MojazBulletinRow -Library $script:Library -BulletinId $bulletin.Id `
            -Fields @{ 'title.Text' = 'عنوان'; 'source.Text' = 'وكالة' }

        $row = @($result.Value.Bulletins[0].Rows)[0]
        $row.Fields.'source.Text' | Should -Be 'وكالة'
    }

    It 'counts only the fields somebody actually filled' {
        (Get-MojazFieldValues -Fields @{ a = 'x'; b = ''; c = '   ' }).Keys | Should -Be @('a')
        (Get-MojazFieldValues -Fields $null).Count | Should -Be 0
        # And reads a bag that has been through JSON, not only a hashtable.
        (Get-MojazFieldValues -Fields ([pscustomobject]@{ a = 'x'; b = '' })).Keys | Should -Be @('a')
    }
}

Describe 'A bulletin that carries one story' {
    BeforeAll {
        # A video report: one item, no loop to walk. Enter, play, leave.
        $script:VideoScene = '<Scene><Var Name="clip" Type="File" /><Plate Size="1920.00;1080.00" File="${clip}" /></Scene>'
        $script:LoopScene = '<Scene LoopStartFrame="30" LoopEndFrame="1530"><Var Name="clip" Type="File" /><Plate File="${clip}" /></Scene>'
    }

    It 'is a usable design even with no loop, and says it cannot walk rows' {
        # The rule this replaces refused it outright, which would have made a
        # video report impossible to put on air at all.
        $verdict = Test-BridgeSceneUsable -Xml $script:VideoScene
        $verdict.Usable | Should -BeTrue
        $verdict.SupportsRows | Should -BeFalse
        (Test-BridgeSceneUsable -Xml $script:LoopScene).SupportsRows | Should -BeTrue
    }

    It 'leaves when the operator said to, not when the row arithmetic says' {
        $bulletin = [pscustomobject]@{
            Id = 'b_1'; Name = 'تقرير'; Revision = 1; DelaySeconds = 8
            HoldSeconds = 40
            Rows = @([pscustomobject]@{ Id = 'r_1'; Title = 'خبر'; Text = 'نص'; ImageMode = 'inherit'; Image = '' })
        }
        $snapshot = (New-MojazRunSnapshot -Bulletin $bulletin).Value

        $snapshot.ExitAtSeconds | Should -Be 40
        $snapshot.HoldSeconds | Should -Be 40
        $snapshot.TotalSeconds | Should -Be 40
    }

    It 'never schedules a row past the moment it was told to leave' {
        # A write after EXIT writes into nothing.
        $bulletin = [pscustomobject]@{
            Id = 'b_2'; Name = 'تقرير'; Revision = 1; DelaySeconds = 30
            HoldSeconds = 20
            Rows = @(
                [pscustomobject]@{ Id = 'r_1'; Title = 'أ'; Text = 'ن'; ImageMode = 'inherit'; Image = '' }
                [pscustomobject]@{ Id = 'r_2'; Title = 'ب'; Text = 'ن'; ImageMode = 'inherit'; Image = '' }
            )
        }
        $snapshot = (New-MojazRunSnapshot -Bulletin $bulletin).Value

        $snapshot.ExitAtSeconds | Should -Be 20
        @($snapshot.Plan | Where-Object { [double]$_.AtSeconds -ge 20 }).Count | Should -Be 0
    }

    It 'leaves the row timing in charge when no hold was set' {
        $bulletin = [pscustomobject]@{
            Id = 'b_3'; Name = 'موجز'; Revision = 1; DelaySeconds = 8; HoldSeconds = 0
            Rows = @(
                [pscustomobject]@{ Id = 'r_1'; Title = 'أ'; Text = 'ن'; ImageMode = 'inherit'; Image = '' }
                [pscustomobject]@{ Id = 'r_2'; Title = 'ب'; Text = 'ن'; ImageMode = 'inherit'; Image = '' }
            )
        }
        $snapshot = (New-MojazRunSnapshot -Bulletin $bulletin).Value

        $snapshot.HoldSeconds | Should -Be 0
        $snapshot.ExitAtSeconds | Should -BeGreaterThan 0
        @($snapshot.Plan).Count | Should -Be 2
    }

    It 'bounds the hold like every other timing here' {
        $library = New-MojazLibrary
        $library = (Add-MojazBulletin -Library $library -Name 'تقرير').Value
        $id = $library.Bulletins[0].Id

        (Set-MojazBulletinTiming -Library $library -BulletinId $id -HoldFrames -1).ErrorCode | Should -Be 'out_of_range'
        (Set-MojazBulletinTiming -Library $library -BulletinId $id -HoldFrames 90001).ErrorCode | Should -Be 'out_of_range'
        $ok = Set-MojazBulletinTiming -Library $library -BulletinId $id -HoldFrames 1000
        $ok.Success | Should -BeTrue
        $ok.Value.Bulletins[0].HoldFrames | Should -Be 1000
    }
}

Describe 'How long a clip stays up' {
    function global:New-TestClipBulletin {
        param([double]$Hold = 0, [double]$MediaSeconds = 0, [double]$Delay = 8)
        [pscustomobject]@{
            Id = 'b_clip'; Name = 'تقرير'; Revision = 1; DelaySeconds = $Delay; HoldSeconds = $Hold
            Rows = @([pscustomobject]@{ Id = 'r_1'; Title = 'خبر'; Text = 'ن'; ImageMode = 'inherit'; Image = ''; MediaSeconds = $MediaSeconds })
        }
    }

    It 'follows the clip when the operator set nothing' {
        $snapshot = (New-MojazRunSnapshot -Bulletin (New-TestClipBulletin -MediaSeconds 42.5)).Value
        $snapshot.ExitAtSeconds | Should -Be 42.5
        $snapshot.HoldFromClip | Should -BeTrue
    }

    It 'never second-guesses a duration the operator typed' {
        # Even a clip twice as long: they said twenty, so twenty it is.
        $snapshot = (New-MojazRunSnapshot -Bulletin (New-TestClipBulletin -Hold 20 -MediaSeconds 42.5)).Value
        $snapshot.ExitAtSeconds | Should -Be 20
        $snapshot.HoldFromClip | Should -BeFalse
    }

    It 'takes the longest clip so a second one is not cut short' {
        $bulletin = New-TestClipBulletin -MediaSeconds 10
        $bulletin.Rows = @(
            [pscustomobject]@{ Id = 'r_1'; Title = 'أ'; Text = 'ن'; ImageMode = 'inherit'; Image = ''; MediaSeconds = 10 }
            [pscustomobject]@{ Id = 'r_2'; Title = 'ب'; Text = 'ن'; ImageMode = 'inherit'; Image = ''; MediaSeconds = 31 }
        )
        (New-MojazRunSnapshot -Bulletin $bulletin).Value.ExitAtSeconds | Should -Be 31
    }

    It 'falls back to the row timing when nothing knows a duration' {
        $snapshot = (New-MojazRunSnapshot -Bulletin (New-TestClipBulletin)).Value
        $snapshot.HoldSeconds | Should -Be 0
        $snapshot.HoldFromClip | Should -BeFalse
        $snapshot.ExitAtSeconds | Should -BeGreaterThan 0
    }
}
