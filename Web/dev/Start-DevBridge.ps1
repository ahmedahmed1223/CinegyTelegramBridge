#requires -Version 7
<#
    Start-DevBridge.ps1 - the bridge's web channel, for developing the web
    interface without a live station.

    Loads TelegramBridge.ps1 with -LoadOnly and config.example.json (the same
    way the tests do), opens the real web channel on a development pipe, and
    publishes a made-up air state that moves. Nothing here talks to Cinegy,
    and the placeholder token means nothing reaches Telegram either.

    A Telegram sign-in is approved automatically as the owner after a few
    seconds - there is no bot to approve it in. That shortcut exists only in
    this script.

        pwsh -File Web/dev/Start-DevBridge.ps1
        # Supply -CaptureFixtureDirectory with output.jpg and output.mp4 to exercise capture.
        dotnet run --project Web/Server -- --PipeName CinegyTelegramBridge.Web.Dev --BridgeRoot (Join-Path ([IO.Path]::GetTempPath()) 'cgb-dev-bridge')
        pnpm --dir Web/Client dev
#>
param(
    [string]$PipeName = 'CinegyTelegramBridge.Web.Dev',
    [long]$OwnerId = 1001,
    [string]$CaptureFixtureDirectory,
    [string]$SheetFixturePath,
    [string]$FixtureRuntimeDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'cgb-dev-bridge')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runtime = [IO.Path]::GetFullPath($FixtureRuntimeDirectory)
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
. (Join-Path $root 'TelegramBridge.ps1') -LoadOnly -ConfigPath 'config.example.json' -RuntimePath $runtime
Copy-Item -LiteralPath (Join-Path $root 'TelegramBridge.ps1') -Destination $runtime

$fixtureRegistry = Join-Path $runtime 'templates.json'
$fixtureTicker = Join-Path $runtime 'ticker.txt'
Set-JsonProp $config 'TemplateRegistryPath' $fixtureRegistry
Set-JsonProp $config.Settings 'NewsFilePath' $fixtureTicker
Set-JsonProp $config.Settings 'EnableUrgentBoard' $true
Set-JsonProp $config.Settings 'EnableFullTemplateManagement' $true
Set-JsonProp $config.Settings 'TemplateTestLayer' 9
Set-JsonProp $config.Settings 'UrgentBoardIntervalSeconds' 30
Set-JsonProp $config.Settings 'EnableNewsTickerManagement' $true
if ($SheetFixturePath) {
    Set-JsonProp $config.Settings 'NewsSheetCsvUrl' 'https://example.invalid/fixture.csv'
    function Start-NewsSheetCsvDownload {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The fixture accepts the download signature but never uses the network.')]
        param([string]$Url, [int]$TimeoutSeconds, [int]$MaxBytes)
        $file = Get-Item -LiteralPath $SheetFixturePath
        if ($file.Length -gt $MaxBytes) { return @{ Error = 'Fixture too large' } }
        return @{ Task = [System.Threading.Tasks.Task]::CompletedTask; FixtureCsv = [IO.File]::ReadAllText($file.FullName); Error = '' }
    }
    function Receive-NewsSheetCsvDownload {
        param([hashtable]$Transfer)
        return @{ Success = $true; Csv = $Transfer.FixtureCsv; Error = '' }
    }
}
Set-JsonProp $config.Settings 'EnableLiveRelay' $true
Set-JsonProp $config.Settings 'EnableSnapshot' ([bool]$CaptureFixtureDirectory)
Set-JsonProp $config.Settings 'NewsItemSeparator' '|'
Set-JsonProp $config.Settings 'MojazMultiDesign' $true
@{
    Urgent = @{
        path = Join-Path $runtime 'urgent.cintitle'; layer = 3; description = 'شريط الأخبار العاجلة'; category = 'الأخبار'
        fields = @(
            @{ name = 'Ajel.center'; label = 'نص العاجل'; required = $true; maxLength = 120 }
            @{ name = 'Ajel.title'; label = 'العنوان'; maxLength = 45 }
            @{ name = 'Ajel.location'; label = 'الموقع'; maxLength = 30 }
        )
    }
    Mojaz = @{
        path = Join-Path $runtime 'mojaz.cintitle'; layer = 4; description = 'الموجز الإخباري'; category = 'الأخبار'
        fields = @(@{ name = 'title.Text'; label = 'العنوان'; required = $true }, @{ name = 'Subject.Text'; label = 'التفاصيل' })
    }
    StudioBulletin = @{
        path = Join-Path $runtime 'studio-bulletin.cintitle'; layer = 6; description = 'موجز الاستوديو'; category = 'الأخبار'; bulletin = $true
        fields = @(
            @{ name = 'title.Text'; label = 'العنوان' }
            @{ name = 'Subject.Text'; label = 'التفاصيل' }
            @{ name = 'studio.location'; label = 'الموقع' }
            @{ name = 'studio.picture'; label = 'صورة الاستوديو' }
            @{ name = 'studio.thumbnail'; label = 'الصورة المصغّرة' }
        )
    }
    PhotoBulletin = @{
        path = Join-Path $runtime 'photo-bulletin.cintitle'; layer = 6; description = 'موجز الصور'; category = 'الأخبار'; bulletin = $true
        fields = @(@{ name = 'photo.main'; label = 'الصورة الرئيسية' }, @{ name = 'photo.detail'; label = 'صورة التفاصيل' })
    }
    Guest = @{
        path = Join-Path $runtime 'guest.cintitle'; layer = 5; description = 'اسم الضيف'; category = 'الأسماء'
        fields = @(@{ name = 'name'; label = 'اسم الضيف'; required = $true; maxLength = 40 }, @{ name = 'role'; label = 'الصفة' })
    }
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fixtureRegistry
@'
<CinegyTitler><Scene Fps="25" Duration="125" LoopStartFrame="25" LoopEndFrame="100">
  <Var Name="title.Text" Type="String" /><Title Text="${title.Text}" />
  <Var Name="Subject.Text" Type="String" /><Title Text="${Subject.Text}" />
  <Var Name="mojaz_img" Type="File" /><Plate File="${mojaz_img}" />
</Scene></CinegyTitler>
'@ | Set-Content -LiteralPath (Join-Path $runtime 'mojaz.cintitle')
@'
<Scene Fps="50" Duration="300" LoopStartFrame="50" LoopEndFrame="200">
  <Var Name="title.Text" Type="String" /><Title Text="${title.Text}" />
  <Var Name="Subject.Text" Type="String" /><Title Text="${Subject.Text}" />
  <Var Name="studio.location" Type="String" /><Title Text="${studio.location}" />
  <Var Name="studio.picture" Type="File" /><Plate File="${studio.picture}" Size="320;180" />
  <Var Name="studio.thumbnail" Type="File" /><Plate File="${studio.thumbnail}" Size="160;90" />
</Scene>
'@ | Set-Content -LiteralPath (Join-Path $runtime 'studio-bulletin.cintitle')
@'
<Scene Fps="50" Duration="300" LoopStartFrame="50" LoopEndFrame="200">
  <Var Name="photo.main" Type="File" /><Plate File="${photo.main}" Size="320;180" />
  <Var Name="photo.detail" Type="File" /><Plate File="${photo.detail}" Size="160;90" />
</Scene>
'@ | Set-Content -LiteralPath (Join-Path $runtime 'photo-bulletin.cintitle')
'نافذة على أبرز الأخبار اليوم|متابعة مباشرة في النشرة المسائية|برنامج خاص مساء الخميس' |
    Set-Content -LiteralPath $fixtureTicker
$script:UrgentBoard = New-UrgentBoard
$script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text 'متابعة مباشرة من غرفة الأخبار' -Title 'متابعة مباشرة').Value
$script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text 'خدمة إخبارية خاصة عند التاسعة').Value
$script:UrgentBoard = (Add-UrgentItem -Board $script:UrgentBoard -Text 'تحديث جديد من الميدان').Value
Set-JsonProp $script:UrgentBoard.Items[0] 'ExtraFields' @{ 'Ajel.location' = 'الاستوديو' }
$script:UrgentBoard.Items[1].Enabled = $false
$script:MojazLibrary = (Add-MojazBulletin -Library (New-MojazLibrary) -Name 'موجز الفترة المسائية').Value
$demoBulletinId = $script:MojazLibrary.Bulletins[0].Id
$demoPicture = ''
if ($CaptureFixtureDirectory) {
    $fixturePicture = Join-Path $CaptureFixtureDirectory 'output.jpg'
    if (Test-Path -LiteralPath $fixturePicture -PathType Leaf) {
        Copy-Item -LiteralPath $fixturePicture -Destination (Join-Path $runtime 'demo-picture.jpg') -Force
        $demoPicture = '.\demo-picture.jpg'
    }
}
$script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $demoBulletinId -Title 'أبرز العناوين' -Text 'العناوين الرئيسية في النشرة المسائية.' -Image $demoPicture).Value
$script:MojazLibrary = (Add-MojazBulletinRow -Library $script:MojazLibrary -BulletinId $demoBulletinId -Title 'تقرير اليوم' -Text 'متابعة من غرفة الأخبار.').Value
$script:MojazLibrary = (Add-MojazBulletin -Library $script:MojazLibrary -Name 'موجز الصور' -TemplateKey 'PhotoBulletin').Value

$config | Add-Member -NotePropertyName 'OwnerUserIds' -NotePropertyValue @($OwnerId) -Force
$config | Add-Member -NotePropertyName 'AdminUserIds' -NotePropertyValue @($OwnerId, 1002) -Force
$config | Add-Member -NotePropertyName 'AllowedUserIds' -NotePropertyValue @($OwnerId, 1002, 1003) -Force
$script:UserAliases[[string]$OwnerId] = 'مدير المحطة'
$script:UserAliases['1002'] = 'رئيس التحرير'
$script:UserAliases['1003'] = 'مشغّل الفترة المسائية'
# Saving is the bridge's business on a station; here it would rewrite the
# example config in the repository.
function Save-Config { }
function Save-UserAliases { $true }
function Update-WebBotUsername { $script:WebBotUsername = 'cinegy_dev_bot' }
function Send-TelegramMessage { }
function Get-FfmpegPath { return 'fixture' }
function Start-BridgeMediaProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The fixture accepts the production signature without starting an external process.')]
    param($FilePath, $Arguments, $WorkingDirectory, $StandardErrorPath)
    $destination = $Arguments[-1]
    $fixture = Join-Path $CaptureFixtureDirectory ('output' + [IO.Path]::GetExtension($destination))
    Copy-Item -LiteralPath $fixture -Destination $destination -ErrorAction Stop
    return @{ HasExited = $true; ExitCode = 0 }
}
function Save-NewsSheetItems { @{ Success = $false; Attempted = $false; Error = '' } }
function Start-RelayProcess {
    $script:RelayState.Process = @{ Id = 1; StartTime = (Get-Date); HasExited = $false }
    return $true
}
function Stop-RelayProcess {
    param($Process)
    $Process.HasExited = $true
}

# The dev pipe uses real web dispatch and validation. Replacing the three
# commands here confines their effects to the simulated on-air state.
function Invoke-ShowTemplateResult {
    param([string]$Key, [hashtable]$Variables, [long]$UserId, [int]$AutoHideSeconds, [string]$ExpectedLayerStamp,
        [int]$ExpectedLayer, [string]$ExpectedTemplatePath)
    $template = (Get-TemplateStore).Map[$Key]
    $layer = [int]$template.Layer
    if (($ExpectedLayer -gt 0 -and $layer -ne $ExpectedLayer) -or
        ($ExpectedTemplatePath -and [string]$template.Path -cne $ExpectedTemplatePath) -or
        ($ExpectedLayerStamp -and (Get-CinegyLayerReviewStamp -Status (Get-TitlerLayerStatus -Layer $layer)) -cne $ExpectedLayerStamp)) {
        return @{ Success = $false }
    }
    $shownAt = Get-Date
    $activeId = [guid]::NewGuid().ToString()
    $script:OnAir[$layer] = @{ Key = $Key; At = $shownAt; ActiveId = $activeId; UserId = $UserId; Source = 'bridge'; Variables = $Variables }
    $script:AutoHideQueue = @($script:AutoHideQueue | Where-Object { $_.Layer -ne $layer })
    if ($AutoHideSeconds -gt 0) {
        $script:AutoHideQueue += @{ Layer = $layer; At = $shownAt.AddSeconds($AutoHideSeconds) }
    }
    return @{ Success = $true; AutoHideArmed = $AutoHideSeconds -gt 0; ActiveId = $activeId; ActiveIdConfirmed = $true }
}

function Show-TitlerTemplate {
    param([int]$Layer, [string]$TemplatePath, [hashtable]$Variables)
    if ($Layer -ne 9) { throw 'The development rehearsal accepts only the fixture layer.' }
    $eventId = [guid]::NewGuid().ToString()
    $script:OnAir[$Layer] = @{
        Key = [IO.Path]::GetFileNameWithoutExtension($TemplatePath); At = Get-Date
        ActiveId = $eventId; Variables = $Variables
    }
    return @{ Success = $true; EventId = $eventId }
}

function Set-AutoHideTimer {
    param([int]$Layer, [int]$Seconds)
    $script:AutoHideQueue = @($script:AutoHideQueue | Where-Object { $_.Layer -ne $Layer })
    $script:AutoHideQueue += @{ Layer = $Layer; At = (Get-Date).AddSeconds($Seconds) }
    return $true
}

function Invoke-HideLayer {
    param([int]$Layer)
    $script:AutoHideQueue = @($script:AutoHideQueue | Where-Object { $_.Layer -ne $Layer })
    if (-not $script:OnAir.ContainsKey($Layer)) { return $false }
    $script:OnAir.Remove($Layer)
    return $true
}

function Invoke-ExitLayer {
    param([int]$Layer, [string]$ExpectedLayerStamp)
    if ($ExpectedLayerStamp -and (Get-CinegyLayerReviewStamp -Status (Get-TitlerLayerStatus -Layer $Layer)) -cne $ExpectedLayerStamp) {
        return $false
    }
    return Invoke-HideLayer -Layer $Layer
}

function Send-PostboxValues {
    param([hashtable]$Values)
    $live = $script:OnAir[(Get-MojazRunLayer -Playback $script:MojazPlayback)]
    if (-not $live) { return @{ Success = $false; Error = 'No running fixture scene.' } }
    $live.Variables = $Values
    return @{ Success = $true; Xml = '' }
}

function Get-TitlerLayerStatus {
    param([int]$Layer)
    $live = $script:OnAir[$Layer]
    return @{
        Success = $true; IsOnAir = $null -ne $live
        ActiveId = Get-JsonProp $live 'ActiveId'; ActiveName = Get-JsonProp $live 'Key'
    }
}

function Send-UrgentBoardStep {
    param($Step)
    return Invoke-ShowTemplateResult -Key $script:MojazUrgentKey -Variables (Get-UrgentItemVariables -Item $Step) -UserId $OwnerId
}

$script:WebChannelPipeName = $PipeName
Start-WebChannel

$started = Get-Date
Set-JsonProp (Get-LiveStreamConfig) 'SourceUrl' 'https://example.invalid/simulated-output.m3u8'
Set-JsonProp (Get-LiveStreamConfig) 'RtmpDestination' 'rtmp://example.invalid/simulated-relay'
$script:LastOutputMonitorAt = $started.AddMinutes(-2)
$script:StreamOutages = New-BridgeOutageLedger
Open-BridgeOutage -Ledger $script:StreamOutages -Kind black -At $started.AddMinutes(-47) | Out-Null
Close-BridgeOutage -Ledger $script:StreamOutages -Kind black -At $started.AddMinutes(-46) | Out-Null
$script:RuntimeState.Monitoring.TelegramConnectionState = 'connected'
$script:RuntimeState.Monitoring.CinegyHealthState = 'healthy'
$script:OnAir[1] = [pscustomobject]@{ Key = 'شعار القناة'; At = $started.AddMinutes(-47); UserId = $OwnerId; Source = 'bridge' }
$script:OnAir[3] = [pscustomobject]@{ Key = 'شريط الأخبار العاجلة'; At = $started.AddSeconds(-95); ActiveId = 'dev-graphics-3'; UserId = 1003; Source = 'bridge' }
$script:OnAir[5] = [pscustomobject]@{ Key = 'اسم الضيف — د. سامر الخطيب'; At = $started.AddSeconds(-20); UserId = 0; Source = 'cinegy' }
$script:AutoHideQueue = @([pscustomobject]@{ Layer = 5; At = $started.AddSeconds(40) })

Write-Host "Dev bridge on pipe $PipeName. Ctrl+C to stop." -ForegroundColor Cyan
try {
    while ($true) {
        foreach ($timer in @($script:AutoHideQueue)) {
            if ($timer.At -le (Get-Date)) { Invoke-HideLayer -Layer $timer.Layer | Out-Null }
        }
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = Get-Date
        $script:RuntimeState.Monitoring.LastCinegyStateFailedCount = 0
        foreach ($code in @($script:WebLoginRequests.Keys)) {
            $request = $script:WebLoginRequests[$code]
            if ($request.State -eq 'pending' -and ((Get-Date) - $request.ExpiresAt.AddMinutes(-$script:WebLoginLifetimeMinutes)).TotalSeconds -gt 4) {
                $request.State = 'approved'; $request.UserId = $OwnerId; $request.RequestedBy = $OwnerId
                Write-Host "DEV: approved sign-in $code as the owner" -ForegroundColor Yellow
            }
        }
        Publish-WebChannelState
        Invoke-WebChannelRequests
        Update-SnapshotJobs
        if ($script:RelayState.ShouldRun) { Update-RelayWatchdog }
        Update-UrgentBoardRun
        Update-MojazPlayback
        Wait-WebChannelSignal -Milliseconds 250
    }
}
finally { Stop-WebChannel }
