. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Reviewed bulletin management and queue recording' {
    BeforeEach {
        $script:PreviousBulletinLibrary = $script:MojazLibrary
        $script:PreviousBulletinSchedules = $script:MojazSchedules
        $script:PreviousBulletinPlayback = $script:MojazPlayback
        $script:PreviousBulletinOnAir = $script:OnAir
        $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الاختبار' -UserId 4321).Value
        $script:ManagementBulletinId = $script:MojazLibrary.Bulletins[0].Id
        $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $script:ManagementBulletinId -Title 'عنوان' -Text 'نص' -UserId 4321).Value
        $script:MojazSchedules = @([pscustomobject]@{
                Id = 'management-slot'; BulletinId = $script:ManagementBulletinId; Status = 'scheduled'
                ScheduledAt = [datetimeoffset]::Now.AddHours(2).ToString('o')
            })
        $script:MojazPlayback = $null
        $script:OnAir = @{}
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-MojazAvailable { $true }
        Mock Get-MojazLibraryFile { Join-Path $TestDrive 'bulletins-management-test.json' }
        Mock Get-MojazSchedulesFile { Join-Path $TestDrive 'schedules-management-test.json' }
        Mock Add-AuditEntry {}
        Mock Invoke-ShowTemplateResult { throw 'A management operation must not put anything on air.' }
        Mock Send-TelegramMessage { throw 'The Web operation must not dispatch Telegram.' }
        $script:ReviewManagementBulletin = {
            param([string]$Action)
            Invoke-WebChannelOperation -Request @{
                op = 'bulletin.management'
                args = @{
                    actor = 4321; action = 'review'; operation = $Action; id = $script:ManagementBulletinId
                    revision = $script:MojazLibrary.Bulletins[0].Revision
                }
            }
        }
    }

    AfterEach {
        $script:MojazLibrary = $script:PreviousBulletinLibrary
        $script:MojazSchedules = $script:PreviousBulletinSchedules
        $script:MojazPlayback = $script:PreviousBulletinPlayback
        $script:OnAir = $script:PreviousBulletinOnAir
    }

    It 'refuses an appointment substitution with the same count and another actor redeeming the review' {
        $review = & $script:ReviewManagementBulletin delete
        $review.ok | Should -BeTrue
        $review.data.pendingCount | Should -Be 1
        (Invoke-WebBulletinManagement -Arguments @{
                actor = 4322; action = 'confirm'; review = $review.data.review
            }).error | Should -Be 'bulletin_stale'
        $script:MojazSchedules[0].Id = 'replaced-slot'
        (Invoke-WebBulletinManagement -Arguments @{
                actor = 4321; action = 'confirm'; review = $review.data.review
            }).error | Should -Be 'bulletin_stale'
        $script:MojazLibrary.Bulletins.Count | Should -Be 1
        $script:MojazSchedules[0].Id | Should -Be 'replaced-slot'
    }

    It 'rechecks that the target remains off air, then clears rows without cancelling its slot' {
        $review = & $script:ReviewManagementBulletin clear
        $script:MojazPlayback = @{ BulletinId = $script:ManagementBulletinId }
        (Invoke-WebBulletinManagement -Arguments @{
                actor = 4321; action = 'confirm'; review = $review.data.review
            }).error | Should -Be 'bulletin_on_air'
        $script:MojazLibrary.Bulletins[0].Rows.Count | Should -Be 1
        $script:MojazPlayback = $null
        $review = & $script:ReviewManagementBulletin clear
        (Invoke-WebBulletinManagement -Arguments @{
                actor = 4321; action = 'confirm'; review = $review.data.review
            }).ok | Should -BeTrue
        $script:MojazLibrary.Bulletins[0].Rows.Count | Should -Be 0
        $script:MojazSchedules[0].Id | Should -Be 'management-slot'
        Test-Path -LiteralPath (Join-Path $TestDrive 'schedules-management-test.json') | Should -BeFalse
    }

    It 'puts the exact appointments back on disk when the reviewed library removal fails' {
        Mock Save-MojazLibrary { $false }
        $review = & $script:ReviewManagementBulletin delete
        (Invoke-WebBulletinManagement -Arguments @{
                actor = 4321; action = 'confirm'; review = $review.data.review
            }).error | Should -Be 'bulletin_save_failed'
        $script:MojazLibrary.Bulletins.Count | Should -Be 1
        $script:MojazSchedules[0].Id | Should -Be 'management-slot'
        $disk = Get-Content -LiteralPath (Join-Path $TestDrive 'schedules-management-test.json') -Raw | ConvertFrom-Json
        $disk.Schedules[0].Id | Should -Be 'management-slot'
    }

    It 'checks the reviewed urgent identity again before recording one Web-origin appointment' {
        Mock Test-WebBulletinPlayoutAccess { $true }
        Mock Get-MojazUrgentTemplate { @{ Key = 'Urgent'; Layer = 7 } }
        Mock Get-MojazPlaybackTemplate { @{ Key = 'Mojaz'; Layer = 4; Path = 'fixture.cintitle' } }
        Mock Test-MaintenanceWindowActive { $false }
        Mock Get-MojazResolvedRunSnapshot { @{ Success = $true; Value = @{ Rows = $Bulletin.Rows } } }
        Mock Read-MojazLayerStamp { $script:ManagementUrgentStamp }
        $script:ManagementUrgentStamp = 'active:urgent-a'
        $script:OnAir[7] = @{ Key = 'Urgent'; ActiveId = 'urgent-a'; ActiveIdConfirmed = $true; At = [datetime]::Now }
        $argsForReview = @{
            actor = 4321; action = 'review'; id = $script:ManagementBulletinId
            revision = $script:MojazLibrary.Bulletins[0].Revision
        }
        $review = Invoke-WebChannelOperation -Request @{ op = 'bulletin.afterUrgent'; args = $argsForReview }
        $review.ok | Should -BeTrue
        $script:ManagementUrgentStamp = 'empty'
        (Invoke-WebBulletinAfterUrgent -Arguments @{
                actor = 4321; action = 'confirm'; review = $review.data.review
            }).error | Should -Be 'bulletin_urgent_gone'
        $script:MojazSchedules.Count | Should -Be 1
        $script:ManagementUrgentStamp = 'active:urgent-a'
        $review = Invoke-WebBulletinAfterUrgent -Arguments $argsForReview
        (Invoke-WebBulletinAfterUrgent -Arguments @{
                actor = 4321; action = 'confirm'; review = $review.data.review
            }).ok | Should -BeTrue
        $script:MojazSchedules[-1].Source | Should -Be 'web'
        $script:MojazSchedules[-1].CreatedBy | Should -Be 4321
        $review = Invoke-WebBulletinAfterUrgent -Arguments $argsForReview
        (Invoke-WebBulletinAfterUrgent -Arguments @{
                actor = 4321; action = 'confirm'; review = $review.data.review
            }).data.alreadyQueued | Should -BeTrue
        $script:MojazSchedules.Count | Should -Be 2
        Should -Invoke Invoke-ShowTemplateResult -Times 0 -Exactly
    }
}
