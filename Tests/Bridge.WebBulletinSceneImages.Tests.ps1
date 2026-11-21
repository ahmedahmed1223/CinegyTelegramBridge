. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')

Describe 'Picking an existing picture from a bulletin scene directory' {
    BeforeEach {
        $script:PreviousSceneImageLibrary = $script:MojazLibrary
        $script:SceneImageFixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $script:SceneImageFixtureRoot -ItemType Directory
        $script:SceneImageFixture = Join-Path $script:SceneImageFixtureRoot 'Selected.cintitle'
        [IO.File]::WriteAllText($script:SceneImageFixture, '<scene />')
        $script:SceneImagePng = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aQWQAAAAASUVORK5CYII=')
        $script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الاختبار' -UserId 4321).Value
        $bulletinId = $script:MojazLibrary.Bulletins[0].Id
        $script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $bulletinId -Title 'الصف' -UserId 4321).Value
        $script:SceneImageParameters = @{ actor = 4321; id = $bulletinId; rowId = $script:MojazLibrary.Bulletins[0].Rows[0].Id
            revision = $script:MojazLibrary.Bulletins[0].Revision }
        $script:SceneImageRequest = {
            param([hashtable]$Extras)
            Invoke-WebChannelOperation -Request @{ op = 'bulletin.scene-images'; args = $script:SceneImageParameters + $Extras }
        }
        Mock Test-Authorized { $UserId -in 4321, 4322 }
        Mock Test-MojazAvailable { $true }
        Mock Get-MojazPlaybackTemplate { @{ Path = $script:SceneImageFixture } }
        Mock Get-WebBulletinFields { @{ name = $script:MojazImageVariable; kind = 'media' } }
        Mock Get-MojazLibraryFile { Join-Path $script:SceneImageFixtureRoot 'library.json' }
        Mock Get-WebBulletinEditor {
            @{ id = $Bulletin.Id; revision = $Bulletin.Revision; imageMode = $Bulletin.Rows[0].ImageMode }
        }
        Mock Add-AuditEntry {}
        Mock Send-TelegramMessage { throw 'The scene picker must not dispatch Telegram.' }
        Mock Invoke-ShowTemplateResult { throw 'The scene picker must not command air.' }
    }

    AfterEach { $script:MojazLibrary = $script:PreviousSceneImageLibrary }

    It 'lists bounded raster names, excluding other files, nested pictures and images over the byte limit' {
        $nested = New-Item -Path (Join-Path $script:SceneImageFixtureRoot 'nested') -ItemType Directory
        [IO.File]::WriteAllBytes((Join-Path $nested.FullName 'nested.png'), $script:SceneImagePng)
        [IO.File]::WriteAllBytes((Join-Path $script:SceneImageFixtureRoot 'scene.svg'), $script:SceneImagePng)
        [IO.File]::WriteAllText((Join-Path $script:SceneImageFixtureRoot 'spoof.png'), 'a string, never an image')
        $large = [IO.File]::Create((Join-Path $script:SceneImageFixtureRoot 'large.png'))
        try { $large.Write($script:SceneImagePng); $large.SetLength(10MB + 1) }
        finally { $large.Dispose() }
        for ($i = 0; $i -lt 23; $i++) {
            [IO.File]::WriteAllBytes((Join-Path $script:SceneImageFixtureRoot ("picture-{0:d2}.png" -f $i)), $script:SceneImagePng)
        }
        $pageOne = & $script:SceneImageRequest @{ action = 'list'; page = 0 }
        $pageOne.ok | Should -BeTrue
        $pageOne.data.pageCount | Should -Be 2
        $pageOne.data.items.Count | Should -Be 20
        $pageOne.data.items[0].label | Should -Be 'picture-00.png'
        $pageTwo = & $script:SceneImageRequest @{ action = 'list'; page = 1 }
        $pageTwo.data.items.Count | Should -Be 3
        $pageTwo.data.items[-1].label | Should -Be 'picture-22.png'
        ($pageTwo | ConvertTo-Json -Depth 6) | Should -Not -Match ([regex]::Escape($script:SceneImageFixtureRoot))
    }

    It 'applies only a file from that actor and page via the shared relative-path writer' {
        [IO.File]::WriteAllBytes((Join-Path $script:SceneImageFixtureRoot 'new.png'), $script:SceneImagePng)
        $list = & $script:SceneImageRequest @{ action = 'list' }
        $request = @{ action = 'apply'; selection = $list.data.selection; slot = 0; path = '..\secret.png' }
        $script:SceneImageParameters.actor = 4322
        (& $script:SceneImageRequest $request).error | Should -Be 'bulletin_scene_image_stale'
        $script:SceneImageParameters.actor = 4321
        (& $script:SceneImageRequest $request).ok | Should -BeTrue
        $saved = Get-Content -LiteralPath (Join-Path $script:SceneImageFixtureRoot 'library.json') -Raw | ConvertFrom-Json
        $saved.Bulletins[0].Rows[0].Image | Should -Be '.\new.png'
        $saved.Bulletins[0].Rows[0].ImageMode | Should -Be 'new'
        (& $script:SceneImageRequest $request).error | Should -Be 'bulletin_stale'
    }

    It 'rejects a replaced candidate and a bulletin revision that changed since listing' {
        $file = Join-Path $script:SceneImageFixtureRoot 'new.png'
        [IO.File]::WriteAllBytes($file, $script:SceneImagePng)
        $list = & $script:SceneImageRequest @{ action = 'list' }
        [IO.File]::SetLastWriteTimeUtc($file, [datetime]::UtcNow.AddMinutes(-10))
        (& $script:SceneImageRequest @{ action = 'apply'; selection = $list.data.selection; slot = 0 }).error |
            Should -Be 'bulletin_scene_image_stale'
        $script:SceneImageParameters.revision--
        (& $script:SceneImageRequest @{ action = 'list' }).error | Should -Be 'bulletin_stale'
        Test-Path -LiteralPath (Join-Path $script:SceneImageFixtureRoot 'library.json') | Should -BeFalse
    }

    It 'never follows a scene-directory junction outside the configured physical directory' {
        $target = New-Item -Path (Join-Path $script:SceneImageFixtureRoot 'real') -ItemType Directory
        $alias = Join-Path $script:SceneImageFixtureRoot 'alias'
        try { New-Item -Path $alias -ItemType Junction -Target $target.FullName -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because 'This environment cannot create a test junction.'; return }
        [IO.File]::WriteAllText((Join-Path $target.FullName 'Selected.cintitle'), '<scene />')
        $script:SceneImageFixture = Join-Path $alias 'Selected.cintitle'
        (& $script:SceneImageRequest @{ action = 'list' }).error | Should -Be 'bulletin_scene_images_unavailable'
    }
}
