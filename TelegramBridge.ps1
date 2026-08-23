#requires -Version 7
<#
    TelegramBridge.ps1

    Long-polling Telegram bot that lets whitelisted operators drive a
    Cinegy Air Pro channel's Titler graphics from chat, using inline
    keyboard buttons: push a named template on air with text fields,
    hide/exit it, push a live variable update, grab an on-air snapshot,
    and relay the live air output into a Telegram Video Chat.

Built on top of Modules/CinegyAirTitler.psm1, which wraps the HTTP control
    surfaces demonstrated in https://github.com/Cinegy/Cinegy.Powershell
    (Titler/PushTitlerTemplateOnAir.ps1, HideTitlerTemplateOnAir.ps1,
    ExitSceneTitlerTemplateOnAir.ps1, PushTitlerVariableToPostbox.ps1).

Design notes (see docs/archive/REVIEW.md and docs/archive/TASKS.md for the historical rationale):

      * The polling loop must never block. Anything slow (ffmpeg snapshot,
        relay startup verification) is started asynchronously and polled
        from Invoke-BridgeTick, and the long-poll timeout collapses to
        1 second while async work is outstanding. An urgent "hide" is
        therefore never queued behind a snapshot.
      * Authorization is evaluated against the *user* id, not just the
        chat id, so adding a group to the whitelist does not silently
        authorize every current and future member.
      * Almost every behaviour is configurable at runtime from the
        in-chat admin Settings screen; see $script:DefaultSettings.

    Run this on a machine with network access to the Air Pro engine
    (commonly the playout box itself). See README.md for setup as a
    Scheduled Task / service, and for how to get a bot token and chat ID.

    Usage:
        pwsh -File .\TelegramBridge.ps1 -ConfigPath .\config.json
#>

param(
    [string]$ConfigPath = ".\config.json",
    [string]$RuntimePath = '',
    [switch]$AllowMultipleInstances,
    # Dot-source the script with -LoadOnly to get every function defined
    # without contacting Telegram, taking the single-instance mutex, or
    # entering the polling loop. Used by Tests\Bridge.Tests.ps1.
    [switch]$LoadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Bump on every functional change. Shown in ℹ️ الحالة and logged at startup so
# "which build is actually running?" is answerable without diffing files.
$script:BridgeVersion = '4.3.1'

$scriptRoot = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$moduleRoot = Join-Path $scriptRoot 'Modules'
Import-Module (Join-Path $moduleRoot "CinegyAirTitler.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeSecurity.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeSettings.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeStorage.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeTelegram.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeAuthorization.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeFlowState.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeCinegyState.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeSchedulePolicy.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeMedia.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeRelayPolicy.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeRuntimeState.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeNewsTicker.psm1") -Force

# Resolve the config path relative to the script, not the caller's cwd, so a
# Scheduled Task / service with a different working directory still works.
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot ($ConfigPath -replace '^\.[\\/]+', '')
}

# ============================================================================
#  Settings schema and defaults
# ============================================================================
# Every key here is exposed in the in-chat admin Settings screen. The .NET
# type of the default determines the editor used (bool -> toggle button,
# int -> "send me a number" prompt).

$script:DefaultSettings = [ordered]@{
    # --- security ---
    RequireUserLevelAuth       = $true   # authorize the user id, not just the chat id
    EnableSelfServiceRequests  = $true   # strangers may request access via the bot
    EnableRawCommand           = $true   # allow the admin /أمر Device Cmd escape hatch
    EnableFullTemplateManagement = $false # permits structural template edits from Telegram
    EnableDpapiSecrets        = $false  # opt-in; current plaintext config behavior remains the default
    # --- features ---
    EnableSnapshot             = $true
    EnableLiveRelay            = $true
    EnableTimedShow            = $true
    EnableHideAll              = $true
    HideAllLayers              = 'all'  # all, or a comma-separated administrator-selected layer list
    ReservedLayers             = ''     # layers where SHOW is blocked; HIDE/EXIT remain available
    DisabledTemplateKeys       = ''     # comma/semicolon-separated template keys blocked from SHOW
    SensitiveTemplateKeys      = ''     # templates that must always receive an automatic hide timer
    SensitiveTemplateAutoHideSeconds = 30 # maximum on-air lifetime for a sensitive template
    TemplateTestLayer         = 0       # dedicated non-program test layer; 0 disables template testing
    TemplateTestAutoHideSeconds = 10    # short safety timeout for the dedicated test layer
    EnableSafeRollback         = $false # opt-in; preserves the current workflow by default
    RollbackWindowSeconds       = 120   # in-memory safe rollback lifetime; editorial values are never persisted
    LayerNames                 = ''     # e.g. 7=عاجل;8=شريط الأخبار
    EnableFavorites            = $true
    SharedFavoritesEnabled     = $false  # reserved; per-user favourites remain the active mode
    MaintenanceMode           = $false  # blocks playout mutations while monitoring remains available
    EnablePersistentMenuButton = $true   # always-visible 🏠 القائمة / 🆘 مساعدة bar
    ButtonTextMaxLength        = 32      # visual text elements; 0 disables shortening
    EnableNewsTickerManagement = $true
    NewsFilePath               = 'D:\cingy cg\ticker msg\news.txt'
    NewsItemSeparator          = '|'
    NewsMaxItemLength          = 1000
    NewsMaxItems               = 200
    NewsImportMaxBytes         = 1048576
    NewsBackupKeepFiles        = 20
    NewsDraftTimeoutMinutes    = 30
    AllowOperatorsDeleteNews   = $false
    AllowOperatorsRestoreNews  = $false
    AllowOperatorsClearAllNews = $false
    # --- safety ---
    DropPendingUpdatesOnStart  = $true   # never replay a pre-restart button press on air
    AirCommandTimeoutSeconds   = 3       # Air Pro is normally on localhost/LAN
    TelegramRequestTimeoutSeconds = 15   # bounded timeout for sendMessage/photo/document
    MaxFieldLength             = 200     # reject text too long for a graphic
    LogAirXml                  = $false  # log the exact XML sent to Air Pro (diagnostics)
    ReshowClearsLayer          = $true   # hide a live layer before re-showing so new text is applied
    AirVariableType            = 'Text'  # Type= sent with SHOW variables: Text | String | Bool | Float
    SetValuesAfterShow         = $true   # re-send field values via postbox just after SHOW
    PostShowDelayMs            = 400     # wait this long after SHOW before the postbox write
    # --- timing / limits ---
    PendingStateTimeoutMinutes = 5       # abandoned "type the field text" flows expire
    SnapshotCooldownSeconds    = 10      # reuse the last frame instead of re-running ffmpeg
    SnapshotTimeoutSeconds     = 8       # hard kill ffmpeg after this
    SnapshotRetentionMinutes   = 30      # sweep orphaned snapshot files older than this
    AutoHideDefaultSeconds     = 10      # pre-selected duration for the timed-show button
    AutoHidePresetSeconds      = '5,10,15,30,60,120'  # quick-pick durations offered on screen
    RelayAutoRestart           = $true
    RelayMaxRestarts           = 20
    RelayWatchdogSeconds       = 20
    CinegyStateCheckSeconds    = 15      # reconcile tracked GFX layers for external changes
    CinegyStateStaleSeconds    = 45      # age after which the last successful state sample is stale
    CinegyHealthCheckSeconds   = 60      # sample /metrics and alert only on transitions
    CinegyMonitorTimeoutSeconds = 3      # bounded, but enough for Air Pro to answer a status read
    ScheduleConflictWindowMinutes = 2    # warn when pending events target one layer this close together
    SchedulePaused              = $false # keep events pending without executing them
    SchedulePreNotifyMinutes    = 0      # disabled by default; notify shortly before an occurrence
    ScheduleMaxRetries          = 0       # safe default: do not replay a failed SHOW unless admin opts in
    ScheduleRetryDelaySeconds   = 30      # wait before an opted-in scheduled SHOW retry
    ScheduleRetryBackoffFactor  = 2       # exponential multiplier per failed attempt
    ScheduleRetryMaxDelaySeconds = 300    # cap retry delay even with many attempts
    HealthFailureAlertThreshold = 3      # consecutive failures before one outage alert
    MaxPendingApprovals        = 20
    PendingApprovalExpiryHours = 24
    FavoritesCount             = 3
    RecentValuesPerField       = 5       # quick choices remembered per operator and field
    # --- housekeeping ---
    LogMaxSizeMB               = 10
    LogKeepFiles               = 5
    AuditTrailSize             = 50
    ConfigBackupKeepFiles      = 10
    DiskFreeWarningGB          = 2
    RuntimeStorageWarningMB    = 100
    BackupStorageWarningMB     = 50
    # --- notifications ---
    HeartbeatEnabled           = $false
    HeartbeatHour              = 9       # 0-23, local time
    NotifyAdminsOnRelayFailure = $true
    NotifyAdminsOnExternalChange = $true
    NotifyAdminsOnCinegyHealth = $true
}

$script:SettingDisplayMetadata = @{
    AirCommandTimeoutSeconds = @{ Unit = 'ثانية'; Description = 'مهلة انتظار أمر Cinegy' }
    TelegramRequestTimeoutSeconds = @{ Unit = 'ثانية'; Description = 'مهلة إرسال رسائل وملفات Telegram' }
    MaxFieldLength = @{ Unit = 'حرفًا'; Description = 'الحد الأقصى لطول نص الحقل' }
    ButtonTextMaxLength = @{ Unit = 'حرفًا'; Description = 'الحد البصري لنص أزرار Telegram (0 للتعطيل)' }
    PostShowDelayMs = @{ Unit = 'مللي ثانية'; Description = 'تأخير إعادة إرسال النص بعد العرض' }
    PendingStateTimeoutMinutes = @{ Unit = 'دقيقة'; Description = 'مدة صلاحية عملية الإدخال غير المكتملة' }
    SnapshotCooldownSeconds = @{ Unit = 'ثانية'; Description = 'الفاصل قبل التقاط صورة بث جديدة' }
    SnapshotTimeoutSeconds = @{ Unit = 'ثانية'; Description = 'مهلة التقاط صورة البث' }
    SnapshotRetentionMinutes = @{ Unit = 'دقيقة'; Description = 'مدة الاحتفاظ بصور البث المؤقتة' }
    AutoHideDefaultSeconds = @{ Unit = 'ثانية'; Description = 'مدة الإخفاء التلقائي الافتراضية' }
    RelayMaxRestarts = @{ Unit = 'محاولة'; Description = 'الحد الأقصى لمحاولات إعادة تشغيل البث' }
    RelayWatchdogSeconds = @{ Unit = 'ثانية'; Description = 'الفاصل بين فحوص البث المباشر' }
    CinegyStateCheckSeconds = @{ Unit = 'ثانية'; Description = 'الفاصل بين فحوص تغير طبقات Cinegy' }
    CinegyHealthCheckSeconds = @{ Unit = 'ثانية'; Description = 'الفاصل بين فحوص صحة Cinegy' }
    CinegyMonitorTimeoutSeconds = @{ Unit = 'ثانية'; Description = 'مهلة فحص حالة Cinegy' }
    SensitiveTemplateAutoHideSeconds = @{ Unit = 'ثانية'; Description = 'الحد الأقصى لبقاء القالب الحساس على الهواء' }
    TemplateTestLayer = @{ Unit = 'طبقة'; Description = 'طبقة تجربة القوالب المستقلة (0 للتعطيل)' }
    TemplateTestAutoHideSeconds = @{ Unit = 'ثانية'; Description = 'مدة إخفاء اختبار القالب تلقائيًا' }
    EnableSafeRollback = @{ Unit = ''; Description = 'تفعيل التراجع الآمن قصير العمر (معطل افتراضيًا)' }
    RollbackWindowSeconds = @{ Unit = 'ثانية'; Description = 'مدة صلاحية التراجع الآمن داخل الذاكرة' }
    HealthFailureAlertThreshold = @{ Unit = 'محاولة'; Description = 'عدد حالات الفشل المتتالية قبل تنبيه المشرف' }
    SchedulePreNotifyMinutes = @{ Unit = 'دقيقة'; Description = 'مدة الإشعار المسبق للحدث المجدول (0 للتعطيل)' }
    MaxPendingApprovals = @{ Unit = 'طلب'; Description = 'الحد الأقصى لطلبات الوصول المعلّقة' }
    PendingApprovalExpiryHours = @{ Unit = 'ساعة'; Description = 'مدة صلاحية طلب الوصول' }
    FavoritesCount = @{ Unit = 'قوالب'; Description = 'عدد القوالب المفضلة المعروضة' }
    RecentValuesPerField = @{ Unit = 'قيم'; Description = 'عدد القيم الحديثة لكل حقل' }
    LogMaxSizeMB = @{ Unit = 'ميغابايت'; Description = 'الحجم الأقصى لملف السجل' }
    LogKeepFiles = @{ Unit = 'ملفات'; Description = 'عدد ملفات السجل المحتفَظ بها' }
    AuditTrailSize = @{ Unit = 'سجل'; Description = 'عدد عناصر سجل العمليات المحتفَظ بها' }
    ConfigBackupKeepFiles = @{ Unit = 'ملفات'; Description = 'عدد نسخ الإعدادات المحتفَظ بها' }
    DiskFreeWarningGB = @{ Unit = 'غيغابايت'; Description = 'حد تنبيه انخفاض مساحة القرص' }
    RuntimeStorageWarningMB = @{ Unit = 'ميغابايت'; Description = 'حد تنبيه حجم ملفات التشغيل والسجلات' }
    BackupStorageWarningMB = @{ Unit = 'ميغابايت'; Description = 'حد تنبيه حجم النسخ الاحتياطية' }
    HeartbeatHour = @{ Unit = 'ساعة (0-23)'; Description = 'ساعة إرسال نبض التشغيل اليومي' }
}

# ============================================================================
#  Config load / save
# ============================================================================

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found at '$ConfigPath'. Copy config.example.json to config.json and edit it first."
}
if (-not $LoadOnly) { Protect-BridgeConfigurationAcl -ConfigPath $ConfigPath }
try {
    $config = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    # A truncated config.json (interrupted write, disk full) would otherwise
    # stop the bridge dead. Save-Config keeps a .bak of the last good copy.
    $backupPath = "$ConfigPath.bak"
    if (-not (Test-Path $backupPath)) { throw "Config file '$ConfigPath' is unreadable and no .bak exists: $($_.Exception.Message)" }
    Write-Host "config.json is unreadable ($($_.Exception.Message)); falling back to $backupPath"
    $config = Get-Content -Path $backupPath -Raw | ConvertFrom-Json
    Copy-Item -Path $backupPath -Destination $ConfigPath -Force -ErrorAction SilentlyContinue
}
$configDirectory = Split-Path -Parent $ConfigPath
$configuredSecretStore = if ($config.PSObject.Properties.Match('SecretStorePath').Count -gt 0) { [string]$config.SecretStorePath } else { 'secrets.dpapi.json' }
$script:SecretStorePath = if ([IO.Path]::IsPathRooted($configuredSecretStore)) { $configuredSecretStore } else { Join-Path $configDirectory $configuredSecretStore }
$resolvedSecrets = Resolve-BridgeConfigurationSecrets -Config $config -StorePath $script:SecretStorePath
$config = $resolvedSecrets.Config
$script:SecretReferences = $resolvedSecrets.References

function Get-JsonProp {
    <# Safely reads a possibly-absent property from a ConvertFrom-Json object
       without tripping Set-StrictMode's property-not-found error. Telegram and
       hand-edited JSON both omit optional fields entirely rather than sending
       them as null, so every read of external JSON goes through here. #>
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Match($Name).Count -gt 0) { return $Object.$Name }
    return $null
}

function Save-Config {
    <# Persists config changes (approved users, settings, stream URL) back to
       disk. Re-reads the file first and only overwrites the blocks this bot
       manages, so a manual edit made while the bridge is running is not
       clobbered by the next approval - and the in-memory copy picks that
       manual edit up at the same time. #>
    param([string]$Path = $ConfigPath)
    if ($LoadOnly -and [IO.Path]::GetFullPath($Path) -eq [IO.Path]::GetFullPath($ConfigPath) -and
        [IO.Path]::GetFileName($Path) -eq 'config.example.json') {
        $script:LastConfigSaveFailed = $false
        return
    }
    $managed = @('AllowedChatIds', 'AdminChatIds', 'AllowedUserIds', 'AdminUserIds', 'Settings', 'LiveStream')
    $target = $null
    try { $target = Get-Content -Path $Path -Raw | ConvertFrom-Json }
    catch { Write-Host "Save-Config: could not re-read $Path, writing in-memory copy." }

    if ($target) {
        foreach ($name in $managed) {
            if ($config.PSObject.Properties.Match($name).Count -gt 0) {
                $target | Add-Member -NotePropertyName $name -NotePropertyValue $config.$name -Force
            }
        }
        # Adopt any unmanaged keys the operator edited on disk into memory.
        foreach ($prop in $target.PSObject.Properties) {
            if ($managed -notcontains $prop.Name) {
                $config | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
            }
        }
    }
    else {
        $target = $config
    }
    # A locked config.json (open in an editor, AV scan, roaming profile) must
    # not take down whatever action triggered the save - the in-memory change
    # still applies for this run, so report and continue. The outcome is
    # recorded in a flag rather than returned, because a return value here
    # would leak a stray boolean into the output of every caller.
    # Written atomically via a temp file + Move-Item. A direct Set-Content that
    # is interrupted (power loss, crash) leaves a truncated config.json, and
    # since it holds the bot token and the operator whitelist the bridge would
    # then refuse to start at all. A .bak copy is kept as a second net.
    $tempPath = "$Path.tmp"
    $backupPath = "$Path.bak"
    try {
        if (Test-Path -LiteralPath $Path) {
            $versionedBackupDirectory = "$Path.backups"
            New-Item -ItemType Directory -Path $versionedBackupDirectory -Force -ErrorAction Stop | Out-Null
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
            $versionedBackup = Join-Path $versionedBackupDirectory "config-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
            Copy-Item -LiteralPath $Path -Destination $versionedBackup -ErrorAction Stop
            $keep = Get-SettingInt 'ConfigBackupKeepFiles' 1
            $oldBackups = @(Get-ChildItem -LiteralPath $versionedBackupDirectory -Filter '*.json' |
                    Sort-Object LastWriteTimeUtc, Name -Descending | Select-Object -Skip $keep)
            foreach ($oldBackup in $oldBackups) { Remove-Item -LiteralPath $oldBackup.FullName -Force -ErrorAction SilentlyContinue }
        }
        $targetSettings = Get-JsonProp $target 'Settings'
        $dpapiEnabled = $targetSettings -and $targetSettings.PSObject.Properties.Match('EnableDpapiSecrets').Count -gt 0 -and [bool]$targetSettings.EnableDpapiSecrets
        if ($dpapiEnabled) {
            if ($script:SecretReferences.Count -eq 0) {
                $secrets = @{}
                foreach ($entry in @(
                        @{ Path = 'BotToken'; Name = 'BotToken'; Value = [string]$config.BotToken }
                        @{ Path = 'LiveStream.SourceUrl'; Name = 'LiveStream.SourceUrl'; Value = [string]$config.LiveStream.SourceUrl }
                        @{ Path = 'LiveStream.RtmpDestination'; Name = 'LiveStream.RtmpDestination'; Value = [string]$config.LiveStream.RtmpDestination }
                    )) {
                    if ([string]::IsNullOrWhiteSpace($entry.Value)) { continue }
                    $secrets[$entry.Name] = $entry.Value
                    $script:SecretReferences[$entry.Path] = "dpapi:$($entry.Name)"
                }
                Write-BridgeSecretStore -Path $script:SecretStorePath -Secrets $secrets
            }
            else { Update-BridgeReferencedSecrets -Config $config -References $script:SecretReferences -StorePath $script:SecretStorePath }
            $target = ConvertTo-BridgePersistableConfig -Config $target -References $script:SecretReferences
        }
        elseif ($script:SecretReferences.ContainsKey('BotToken')) {
            $target.BotToken = [string]$config.BotToken
        }
        $target | ConvertTo-Json -Depth 20 | Set-Content -Path $tempPath -Encoding utf8 -ErrorAction Stop
        if (Test-Path $Path) { Copy-Item -Path $Path -Destination $backupPath -Force -ErrorAction SilentlyContinue }
        Move-Item -Path $tempPath -Destination $Path -Force -ErrorAction Stop
        Protect-BridgeConfigurationAcl -ConfigPath $Path
        $script:LastConfigSaveFailed = $false
    }
    catch {
        $script:LastConfigSaveFailed = $true
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        Write-BridgeLog "Could not write $Path : $($_.Exception.Message). Change applies to this session only." "ERROR"
    }
}

function Restore-ConfigBackup {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [string]$Path = $ConfigPath
    )
    $restoreTempPath = "$Path.restore.tmp"
    try {
        if (-not (Test-Path -LiteralPath $BackupPath)) { throw "ملف النسخة غير موجود." }
        $candidate = Get-Content -LiteralPath $BackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string](Get-JsonProp $candidate 'BotToken'))) {
            throw "النسخة لا تحتوي BotToken صالحًا."
        }
        $backupDirectory = "$Path.backups"
        New-Item -ItemType Directory -Path $backupDirectory -Force -ErrorAction Stop | Out-Null
        if (Test-Path -LiteralPath $Path) {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
            $beforeRestore = Join-Path $backupDirectory "pre-restore-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
            Copy-Item -LiteralPath $Path -Destination $beforeRestore -ErrorAction Stop
        }
        Copy-Item -LiteralPath $BackupPath -Destination $restoreTempPath -Force -ErrorAction Stop
        Move-Item -LiteralPath $restoreTempPath -Destination $Path -Force -ErrorAction Stop
        Protect-BridgeConfigurationAcl -ConfigPath $Path
        return [pscustomobject]@{ Success = $true; Error = '' }
    }
    catch {
        Remove-Item -LiteralPath $restoreTempPath -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Success = $false; Error = Protect-SensitiveText $_.Exception.Message }
    }
}

function Get-ConfigDifferenceSummary {
    param(
        [Parameter(Mandatory)][string]$CurrentPath,
        [Parameter(Mandatory)][string]$BackupPath
    )
    try {
        $current = Get-Content -LiteralPath $CurrentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $backup = Get-Content -LiteralPath $BackupPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $names = @(@($current.PSObject.Properties.Name) + @($backup.PSObject.Properties.Name) | Sort-Object -Unique)
        $changed = foreach ($name in $names) {
            $currentValue = Get-JsonProp $current $name
            $backupValue = Get-JsonProp $backup $name
            $currentJson = $currentValue | ConvertTo-Json -Depth 20 -Compress
            $backupJson = $backupValue | ConvertTo-Json -Depth 20 -Compress
            if ($currentJson -ne $backupJson) { $name }
        }
        if (@($changed).Count -eq 0) { return 'الاختلافات: لا توجد اختلافات ظاهرة.' }
        return "الاختلافات: $(@($changed) -join '، ')"
    }
    catch { return "الاختلافات: تعذّر حسابها ($($_.Exception.Message))." }
}

function Get-ConfigSaveWarning {
    <# Appended to any confirmation whose change could not be persisted, so an
       operator is never told something was saved when it was not. #>
    if ($script:LastConfigSaveFailed) { return "`n⚠️ تعذّر حفظ config.json - التغيير مؤقّت حتى إعادة التشغيل." }
    return ''
}

function Get-Setting {
    param([Parameter(Mandatory)][string]$Name)
    return Get-BridgeSetting -Config $config -Defaults $script:DefaultSettings -Name $Name
}

function Get-SettingInt {
    param([Parameter(Mandatory)][string]$Name, [int]$Minimum = 0)
    return Get-BridgeSettingInt -Config $config -Defaults $script:DefaultSettings -Name $Name -Minimum $Minimum
}

function Get-LayerName {
    param([Parameter(Mandatory)][int]$Layer)
    foreach ($pair in @([string](Get-Setting 'LayerNames') -split ';')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        if ($parts.Count -lt 2) { continue }
        $number = 0
        if ([int]::TryParse($parts[0].Trim(), [ref]$number) -and $number -eq $Layer) {
            $name = $parts[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }
            return ''
        }
    }
    return ''
}

function Get-LayerDisplayName {
    param([Parameter(Mandatory)][int]$Layer)
    $name = Get-LayerName -Layer $Layer
    if ([string]::IsNullOrWhiteSpace($name)) { return "طبقة $Layer" }
    return "$name · طبقة $Layer"
}

function Format-SettingDisplay {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $metadata = Get-JsonProp $script:SettingDisplayMetadata $Name
    if ($metadata -and (Get-JsonProp $metadata 'Unit')) { return "$Value $((Get-JsonProp $metadata 'Unit'))" }
    return [string]$Value
}

function Get-SettingPromptText {
    param([Parameter(Mandatory)][string]$Name)
    $metadata = Get-JsonProp $script:SettingDisplayMetadata $Name
    $description = if ($metadata) { [string](Get-JsonProp $metadata 'Description') } else { 'قيمة الإعداد' }
    $current = Format-SettingDisplay -Name $Name -Value (Get-Setting $Name)
    $default = Format-SettingDisplay -Name $Name -Value $script:DefaultSettings[$Name]
    return "$description.`nالقيمة الحالية: $current`nالقيمة الافتراضية: $default`nأرسل رقمًا صحيحًا غير سالب:"
}

function Set-Setting {
    param([Parameter(Mandatory)][string]$Name, $Value)
    $settings = Get-JsonProp $config 'Settings'
    if (-not $settings) {
        $settings = [pscustomobject]@{}
        $config | Add-Member -NotePropertyName 'Settings' -NotePropertyValue $settings -Force
    }
    $settings | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    Save-Config
}

function Initialize-Settings {
    <# Fills in any setting missing from config.json with its default, so the
       file is self-documenting after first run and older configs upgrade
       cleanly. #>
    $added = Initialize-BridgeSettings -Config $config -Defaults $script:DefaultSettings
    if ($added) { Save-Config }
}

# ============================================================================
#  Logging (with rotation) and audit trail
# ============================================================================

if ([string]::IsNullOrWhiteSpace($RuntimePath)) {
    $logPath = Join-Path $scriptRoot $config.LogPath
    $logDir = Split-Path $logPath -Parent
}
else {
    $logDir = if ([IO.Path]::IsPathRooted($RuntimePath)) { $RuntimePath } else { Join-Path $scriptRoot $RuntimePath }
    $logPath = Join-Path $logDir 'bridge.log'
}
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
$script:logDir = $logDir
$script:logPath = $logPath

$relayPidFile = Join-Path $logDir "relay.pid"
$usageFile = Join-Path $logDir "usage.json"
$script:userFavoritesFile = Join-Path $logDir "favorites.json"
$script:userAliasesFile = Join-Path $logDir "user-aliases.json"
$script:disabledUsersFile = Join-Path $logDir "disabled-users.json"
$script:userProfilesFile = Join-Path $logDir "user-profiles.json"
$onAirFile = Join-Path $logDir "onair.json"
$script:draftsFile = Join-Path $logDir "drafts.json"
$script:recentValuesFile = Join-Path $logDir "recent-values.json"
$script:scheduleFile = Join-Path $logDir "schedule.json"
$script:scheduleExecutionFile = Join-Path $logDir "schedule-execution.jsonl"
$script:auditFile = Join-Path $logDir "audit.jsonl"
$script:newsDraftFile = Join-Path $logDir 'news-draft.json'
$script:newsBackupDirectory = Join-Path $logDir 'news-backups'
$script:newsImportDirectory = Join-Path $logDir 'news-imports'
$script:NewsTickerDraft = $null

function Invoke-LogRotation {
    <# Renames bridge.log -> bridge.1.log -> bridge.2.log ... keeping
       LogKeepFiles generations, so an always-on playout box does not grow an
       unbounded log file. #>
    $keep = Get-SettingInt 'LogKeepFiles' 1
    $base = [System.IO.Path]::GetFileNameWithoutExtension($logPath)
    $ext = [System.IO.Path]::GetExtension($logPath)
    $oldest = Join-Path $logDir "$base.$keep$ext"
    if (Test-Path $oldest) { Remove-Item $oldest -Force -ErrorAction SilentlyContinue }
    for ($i = $keep - 1; $i -ge 1; $i--) {
        $from = Join-Path $logDir "$base.$i$ext"
        $to = Join-Path $logDir "$base.$($i + 1)$ext"
        if (Test-Path $from) { Move-Item $from $to -Force -ErrorAction SilentlyContinue }
    }
    Move-Item $logPath (Join-Path $logDir "$base.1$ext") -Force -ErrorAction SilentlyContinue
}

function Protect-SensitiveText {
    <# Strips credentials out of anything headed for the log or for chat.

       ffmpeg echoes its output URL in most error messages, and that URL is
       rtmp://<host>/s/<Telegram stream key> - so surfacing raw ffmpeg stderr
       would publish the stream key into the operators' chat and into
       bridge.log. Bot tokens and SRT passphrases get the same treatment. #>
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $safe = $Text
    $safe = [regex]::Replace($safe, '(?i)(rtmps?://)[^\s"''<>]+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)(srt://)[^\s"''<>]+', '$1***')
    $safe = [regex]::Replace($safe, '(?i)(passphrase=)[^\s&"'']+', '$1***')
    $safe = [regex]::Replace($safe, '\d{6,}:[A-Za-z0-9_\-]{25,}', '***BOT_TOKEN***')
    return $safe
}

function Protect-DiagnosticText {
    <# Diagnostic exports are more restrictive than the private runtime log:
       redact stable actor identifiers as well as credentials. #>
    param([AllowEmptyString()][string]$Text)
    $safe = Protect-SensitiveText $Text
    if ([string]::IsNullOrEmpty($safe)) { return $safe }
    return [regex]::Replace($safe, '(?i)\b(user|chat|from|admin|actor)(?:Id)?(=|\s+)\d+\b', '$1$2***')
}

function Write-BridgeLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $(Protect-SensitiveText $Message)"
    Write-Host $line
    try {
        $maxMB = Get-SettingInt 'LogMaxSizeMB' 0
        if ($maxMB -gt 0 -and (Test-Path $logPath) -and (Get-Item $logPath).Length -gt ($maxMB * 1MB)) {
            Invoke-LogRotation
        }
        Add-Content -Path $logPath -Value $line
    }
    catch {
        Write-Host "(logging failed: $($_.Exception.Message))"
    }
}

function Write-ValidatedJsonState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )
    $success = Write-BridgeValidatedJson -Path $Path -Json $Json
    if (-not $success) { Write-BridgeLog "Validated JSON state write failed for '$([IO.Path]::GetFileName($Path))'" 'ERROR' }
    return $success
}

function Read-ValidatedJsonState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AsHashtable
    )
    $result = Read-BridgeValidatedJson -Path $Path -AsHashtable:$AsHashtable
    if ($result -and $result.Recovered) {
        Write-BridgeLog "Recovered '$([IO.Path]::GetFileName($Path))' from its last validated backup" 'WARN'
    }
    return $result
}

$script:AuditTrail = [System.Collections.Generic.List[string]]::new()
$script:AirOperationCounters = @{ Success = 0; Failed = 0; Blocked = 0 }
$script:UserOperationHistory = @{}
$script:LastShowAttempts = @{}

function Add-UserOperationHistory {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Result,
        [Parameter(Mandatory)][long]$DurationMs,
        [Parameter(Mandatory)][long]$UserId,
        [int]$Layer = 0,
        [string]$Target = ''
    )
    $key = [string]$UserId
    $history = [System.Collections.Generic.List[object]]::new()
    if ($script:UserOperationHistory.ContainsKey($key)) {
        foreach ($existing in @($script:UserOperationHistory[$key])) { $history.Add($existing) }
    }
    $history.Add([pscustomobject]@{
        At = Get-Date; OperationId = $OperationId; Action = $Action; Result = $Result
        DurationMs = $DurationMs; Layer = $Layer; Target = $Target
    })
    while ($history.Count -gt 20) { $history.RemoveAt(0) }
    $script:UserOperationHistory[$key] = $history.ToArray()
}

function Get-UserOperationHistory {
    param([Parameter(Mandatory)][long]$UserId)
    $key = [string]$UserId
    if (-not $script:UserOperationHistory.ContainsKey($key)) { return @() }
    return @($script:UserOperationHistory[$key])
}

function Write-AuditRecord {
    <# Permanent machine-readable security and control audit trail. This is
       intentionally separate from bridge.log (runtime diagnostics) and from
       the short in-memory list displayed in Telegram. #>
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][string]$Result,
        [long]$UserId = 0,
        [long]$ChatId = 0,
        [string]$Action = '',
        [int]$Layer = 0,
        [string]$Target = '',
        [long]$DurationMs = 0,
        [string]$Message = ''
    )
    $record = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        operationId  = Protect-SensitiveText (($OperationId -replace '[\r\n]+', ' ').Trim())
        event        = Protect-SensitiveText (($Event -replace '[\r\n]+', ' ').Trim())
        result       = Protect-SensitiveText (($Result -replace '[\r\n]+', ' ').Trim())
        userId       = $UserId
        chatId       = $ChatId
        action       = Protect-SensitiveText (($Action -replace '[\r\n]+', ' ').Trim())
        layer        = $Layer
        target       = Protect-SensitiveText (($Target -replace '[\r\n]+', ' ').Trim())
        durationMs   = $DurationMs
        message      = Protect-SensitiveText (($Message -replace '[\r\n]+', ' ').Trim())
    }
    try {
        Add-Content -LiteralPath $script:auditFile -Value ($record | ConvertTo-Json -Compress -Depth 4) -Encoding utf8
    }
    catch {
        Write-BridgeLog "AUDIT_WRITE_FAILED id=$OperationId event=$Event error=$($_.Exception.Message)" 'ERROR'
    }
}

function Add-AuditEntry {
    <# Short in-memory history surfaced by the admin's 📜 button, so "who put
       that on air?" can be answered from Telegram without opening the log. #>
    param([Parameter(Mandatory)][string]$Message)
    $script:AuditTrail.Add("$(Get-Date -Format 'HH:mm:ss') $Message")
    $max = Get-SettingInt 'AuditTrailSize' 1
    while ($script:AuditTrail.Count -gt $max) { $script:AuditTrail.RemoveAt(0) }
    Write-AuditRecord -OperationId "audit-$([guid]::NewGuid().ToString('N'))" -Event activity -Result success -Message $Message
}

# ============================================================================
#  Telegram API helpers
# ============================================================================

$apiBase = "https://api.telegram.org/bot$($config.BotToken)"
$script:TelegramTextLimit = 3500   # below the hard 4096 so captions/markup fit

function Get-TextElementCount {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return [Globalization.StringInfo]::ParseCombiningCharacters($Text).Count
}

function Get-SafeTextPrefixLength {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][int]$MaximumCodeUnits)
    if ($Text.Length -le $MaximumCodeUnits) { return $Text.Length }
    $boundaries = [Globalization.StringInfo]::ParseCombiningCharacters($Text)
    $prefixLength = 0
    foreach ($boundary in $boundaries) {
        if ($boundary -gt $MaximumCodeUnits) { break }
        $prefixLength = $boundary
    }
    if ($prefixLength -gt 0) { return $prefixLength }
    # An exceptionally large combining sequence can exceed the whole Telegram
    # chunk. Fall back to a code-point-safe cut so progress is still made.
    $prefixLength = [math]::Min($MaximumCodeUnits, $Text.Length)
    if ($prefixLength -gt 0 -and [char]::IsHighSurrogate($Text[$prefixLength - 1])) { $prefixLength-- }
    return [math]::Max(1, $prefixLength)
}

function Split-TelegramText {
    <# Telegram rejects messages over 4096 characters outright. Long template
       listings and audit dumps are chunked on line boundaries.

       Always returns a flat [string[]]. Do NOT "optimise" the short-message
       path to `return , @($Text)`: the unary comma wraps the array, the
       function then emits a single *array* object, and the caller ends up
       putting an array into the message body - which Telegram receives as the
       literal text "System.Object[]". #>
    param([Parameter(Mandatory)][string]$Text)
    $limit = $script:TelegramTextLimit
    $chunks = [System.Collections.Generic.List[string]]::new()

    if ($Text.Length -le $limit) {
        $chunks.Add($Text)
        return $chunks.ToArray()
    }

    $current = [System.Text.StringBuilder]::new()
    foreach ($rawLine in ($Text -split "`n")) {
        $line = [string]$rawLine
        # A single line longer than the whole limit has to be hard-split.
        while ($line.Length -gt $limit) {
            if ($current.Length -gt 0) {
                $chunks.Add($current.ToString())
                $current.Clear() | Out-Null
            }
            $prefixLength = Get-SafeTextPrefixLength -Text $line -MaximumCodeUnits $limit
            $chunks.Add($line.Substring(0, $prefixLength))
            $line = $line.Substring($prefixLength)
        }
        $separator = if ($current.Length -gt 0) { 1 } else { 0 }
        if (($current.Length + $separator + $line.Length) -gt $limit) {
            $chunks.Add($current.ToString())
            $current.Clear() | Out-Null
            $separator = 0
        }
        if ($separator -eq 1) { $current.Append("`n") | Out-Null }
        $current.Append($line) | Out-Null
    }
    if ($current.Length -gt 0) { $chunks.Add($current.ToString()) }
    return $chunks.ToArray()
}

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$Text,
        [hashtable]$ReplyMarkup
    )
    [string[]]$chunks = @(Split-TelegramText -Text $Text)
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        # [string] cast is deliberate belt-and-braces against anything
        # array-shaped ever reaching the body again.
        $body = @{ chat_id = $ChatId; text = [string]$chunks[$i] }
        # Only the final chunk carries the keyboard.
        if ($ReplyMarkup -and $i -eq ($chunks.Count - 1)) {
            $body.reply_markup = ($ReplyMarkup | ConvertTo-Json -Depth 10 -Compress)
        }
        $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendMessage" -Method Post -Body $body `
            -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
        if (-not $request.Success) {
            Write-BridgeLog "Failed to send Telegram message to $ChatId : $($request.Error)" "ERROR"
        }
    }
}

function Send-TelegramPhoto {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Caption,
        [hashtable]$ReplyMarkup
    )
    $form = @{ chat_id = "$ChatId"; photo = Get-Item -Path $FilePath }
    if ($Caption) { $form.caption = $Caption }
    if ($ReplyMarkup) { $form.reply_markup = ($ReplyMarkup | ConvertTo-Json -Depth 10 -Compress) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendPhoto" -Method Post -Form $form `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if (-not $request.Success) {
        Write-BridgeLog "Failed to send Telegram photo to $ChatId : $($request.Error)" "ERROR"
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل إرسال الصورة: $($request.Error)"
    }
}

function Confirm-TelegramCallback {
    <# Acknowledges a button press so Telegram stops showing the loading
       spinner on the client. Optional Text shows a small toast. #>
    param([Parameter(Mandatory)][string]$CallbackQueryId, [string]$Text)
    try {
        $body = @{ callback_query_id = $CallbackQueryId }
        if ($Text) { $body.text = $Text }
        Invoke-RestMethod -Uri "$apiBase/answerCallbackQuery" -Method Post -Body $body | Out-Null
    }
    catch {
        Write-BridgeLog "Failed to answer callback query $CallbackQueryId : $($_.Exception.Message)" "ERROR"
    }
}

function Get-TelegramUpdates {
    <# Returns the update array, never $null. Telegram can reply with
       ok:false (409 Conflict when a second poller exists, or after a token
       revoke) and StrictMode would otherwise throw on the missing 'result'
       property, turning a clear condition into a confusing crash loop. #>
    param([long]$Offset, [int]$TimeoutSeconds)
    $uri = "$apiBase/getUpdates?timeout=$TimeoutSeconds&offset=$Offset"
    $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec ($TimeoutSeconds + 10)
    if (-not (Get-JsonProp $response 'ok')) {
        $desc = [string](Get-JsonProp $response 'description')
        throw "Telegram getUpdates rejected the request: $desc"
    }
    return @(Get-JsonProp $response 'result')
}

function Clear-PendingTelegramUpdates {
    <# Telegram holds undelivered updates for up to 24 hours. Without this, a
       button press that arrived while the bridge was down is delivered - and
       executed - the moment it restarts. On a playout system that means a
       graphic going on air by itself, possibly during a completely different
       programme. Confirming everything queued at startup is the safe default;
       an operator who still wants the action simply presses again.

       Returns the offset to start polling from. #>
    try {
        $probe = Invoke-RestMethod -Uri "$apiBase/getUpdates?offset=-1&timeout=0" -Method Get -TimeoutSec 20
        $pending = @(Get-JsonProp $probe 'result')
        if ($pending.Count -eq 0) { return 0 }
        $nextOffset = [long]$pending[-1].update_id + 1
        # Re-requesting with the advanced offset is what actually acknowledges
        # the backlog to Telegram.
        Invoke-RestMethod -Uri "$apiBase/getUpdates?offset=$nextOffset&timeout=0" -Method Get -TimeoutSec 20 | Out-Null
        Write-BridgeLog "Discarded queued Telegram updates from before startup (offset now $nextOffset)" "WARN"
        return $nextOffset
    }
    catch {
        Write-BridgeLog "Could not drain pending updates: $($_.Exception.Message)" "WARN"
        return 0
    }
}

function Send-AdminBroadcast {
    param([Parameter(Mandatory)][string]$Text, [hashtable]$ReplyMarkup)
    foreach ($adminId in @(Get-JsonProp $config 'AdminChatIds')) {
        if ($adminId) { Send-TelegramMessage -ChatId ([long]$adminId) -Text $Text -ReplyMarkup $ReplyMarkup }
    }
}

# ---- native command menu + persistent keyboard ------------------------------
# Two independent escape hatches for "I opened a new chat" or "I'm stuck":
#   1. Telegram's built-in ☰ Menu button next to the input box, populated by
#      setMyCommands. NOTE: Telegram only accepts [a-z0-9_] command names, so
#      the English aliases are what gets registered - the Arabic descriptions
#      are what the operator actually reads in the list.
#   2. A persistent reply keyboard pinned above the input box with
#      🏠 القائمة / 🆘 مساعدة, which works even mid-flow.

$script:BotCommandList = @(
    @{ command = 'start'; description = '🏠 فتح القائمة الرئيسية' }
    @{ command = 'menu'; description = '🏠 عرض القائمة الرئيسية من جديد' }
    @{ command = 'cancel'; description = '❌ إلغاء أي عملية معلّقة والبدء من جديد' }
    @{ command = 'help'; description = '❓ شرح الأزرار والأوامر' }
    @{ command = 'templates'; description = '📋 عرض القوالب المتاحة' }
    @{ command = 'status'; description = 'ℹ️ حالة النظام والبث والقوالب' }
    @{ command = 'myoperations'; description = '🧾 آخر عملياتي وإعادة المحاولة' }
    @{ command = 'snapshot'; description = '📸 التقاط صورة من البث' }
    @{ command = 'schedule'; description = '📅 جدولة عرض ومراجعة الأحداث القادمة' }
    @{ command = 'hideall'; description = '🚨 إخفاء كل الطبقات (طوارئ)' }
    @{ command = 'settings'; description = '⚙️ الإعدادات (للمشرفين)' }
    @{ command = 'audit'; description = '📜 سجل آخر العمليات (للمشرفين)' }
    @{ command = 'diagnostics'; description = '🧪 تقرير التشخيص (للمشرفين)' }
    @{ command = 'diagbundle'; description = '📦 حزمة تشخيص منقحة (للمشرفين)' }
)

function Register-BotCommands {
    <# Populates Telegram's ☰ Menu button so a brand-new chat, or a user who
       lost the inline keyboard, always has a visible way in. Failures here are
       never fatal - the bot works fine without the menu. #>
    try {
        $body = @{ commands = $script:BotCommandList } | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod -Uri "$apiBase/setMyCommands" -Method Post -Body $body -ContentType 'application/json; charset=utf-8' | Out-Null

        $menuBody = @{ menu_button = @{ type = 'commands' } } | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod -Uri "$apiBase/setChatMenuButton" -Method Post -Body $menuBody -ContentType 'application/json; charset=utf-8' | Out-Null

        Write-BridgeLog "Registered $($script:BotCommandList.Count) bot commands with Telegram's menu button"
    }
    catch {
        Write-BridgeLog "Could not register bot commands: $($_.Exception.Message)" "WARN"
    }
}

# Exact labels of the persistent keyboard buttons. Telegram delivers a tap on
# these as an ordinary text message, so they are matched verbatim (emoji
# included) to avoid ever swallowing legitimate on-air text.
$script:MenuHotword = '🏠 القائمة'
$script:HelpHotword = '🆘 مساعدة'
$script:NewsHotword = '📰 إدارة شريط الأخبار'

function Get-PersistentReplyKeyboard {
    $buttons = @(@{ text = $script:MenuHotword }, @{ text = $script:HelpHotword })
    if (Get-Setting 'EnableNewsTickerManagement') { $buttons += @{ text = $script:NewsHotword } }
    return @{
        keyboard        = @( , $buttons )
        resize_keyboard = $true
        is_persistent   = $true
    }
}

function Show-MainMenu {
    <# The canonical "get me back to a known state" response: clears any
       half-finished flow, re-pins the persistent keyboard, then shows the
       inline menu. A message can only carry one reply_markup, hence two
       sends. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [string]$Intro = "اختر من القائمة:")
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    if (Get-Setting 'EnablePersistentMenuButton') {
        Send-TelegramMessage -ChatId $ChatId -Text "استخدم زر 🏠 القائمة أسفل الشاشة في أي وقت للرجوع إلى هنا." -ReplyMarkup (Get-PersistentReplyKeyboard)
    }
    Send-TelegramMessage -ChatId $ChatId -Text $Intro -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

# ============================================================================
#  Authorization (user-level, not just chat-level)
# ============================================================================

$script:DisabledUserIds = @{}
$script:UserProfiles = @{}
$script:UserProfilesDirty = $false
$script:LastUserProfilesFlush = [datetime]::MinValue

function Import-UserProfiles {
    if (-not (Test-Path -LiteralPath $script:userProfilesFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:userProfilesFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            $script:UserProfiles[$prop.Name] = @{
                AddedAt = [string](Get-JsonProp $prop.Value 'AddedAt'); AddedByUserId = [long](Get-JsonProp $prop.Value 'AddedByUserId')
                LastActivityAt = [string](Get-JsonProp $prop.Value 'LastActivityAt')
            }
        }
    }
    catch { Write-BridgeLog "Could not read user-profiles.json: $($_.Exception.Message)" 'WARN' }
}

# ============================================================================
#  News ticker editor (single durable draft; the live file changes on publish)
# ============================================================================
function Get-NewsTickerConfiguredSnapshot {
    Get-NewsTickerSnapshot -Path ([string](Get-Setting 'NewsFilePath')) -Separator ([string](Get-Setting 'NewsItemSeparator')) `
        -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
}

function Save-NewsTickerDraft {
    if (-not $script:NewsTickerDraft) { return $false }
    try {
        $json = $script:NewsTickerDraft | ConvertTo-Json -Depth 8
        $parent=Split-Path -Parent $script:newsDraftFile;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null}
        $temp="$script:newsDraftFile.$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($true));[IO.File]::Move($temp,$script:newsDraftFile,$true)
        return $true
    } catch { Write-BridgeLog "Could not save news draft: $($_.Exception.Message)" 'ERROR'; return $false }
}

function Import-NewsTickerDraft {
    if (-not (Test-Path -LiteralPath $script:newsDraftFile)) { return }
    try { $script:NewsTickerDraft = Get-Content -LiteralPath $script:newsDraftFile -Raw | ConvertFrom-Json -AsHashtable }
    catch { Write-BridgeLog "Could not load news draft: $($_.Exception.Message)" 'WARN'; $script:NewsTickerDraft = $null }
}

function Get-NewsTickerDraft { param([long]$UserId = 0)
    if (-not $script:NewsTickerDraft) { return $null }
    if ($UserId -and [long]$script:NewsTickerDraft.OwnerUserId -ne $UserId) { return $null }
    return $script:NewsTickerDraft
}

function Remove-NewsTickerDraft {
    $script:NewsTickerDraft = $null
    Remove-Item -LiteralPath $script:newsDraftFile -Force -ErrorAction SilentlyContinue
}

function Start-NewsTickerDraft {
    param([long]$ChatId,[long]$UserId)
    if ($script:NewsTickerDraft) {
        if ([long]$script:NewsTickerDraft.OwnerUserId -eq $UserId) { return [pscustomobject]@{Success=$true;Draft=$script:NewsTickerDraft;Error=''} }
        return [pscustomobject]@{Success=$false;Draft=$null;Error="المسودة مقفلة حاليًا للمستخدم $($script:NewsTickerDraft.OwnerUserId)."}
    }
    $snapshot = Get-NewsTickerConfiguredSnapshot
    if (-not $snapshot.Success) { return [pscustomobject]@{Success=$false;Draft=$null;Error=$snapshot.Error} }
    $script:NewsTickerDraft = [ordered]@{ Id=[guid]::NewGuid().ToString('N');OwnerUserId=$UserId;OwnerChatId=$ChatId;CreatedAt=(Get-Date).ToString('o');UpdatedAt=(Get-Date).ToString('o');BaseHash=$snapshot.Hash;Items=@($snapshot.Items) }
    Save-NewsTickerDraft | Out-Null
    return [pscustomobject]@{Success=$true;Draft=$script:NewsTickerDraft;Error=''}
}

function Add-NewsTickerDraftItem { param([long]$UserId,[string]$Text)
    $draft = Get-NewsTickerDraft -UserId $UserId; if (-not $draft) { return $false }
    $parsed = ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems 1
    if (-not $parsed.Success -or @($parsed.Items).Count -ne 1) { return $false }
    $draft.Items = @($draft.Items) + @($parsed.Items); $draft.UpdatedAt=(Get-Date).ToString('o'); return (Save-NewsTickerDraft)
}
function Update-NewsTickerDraftItem { param([long]$UserId,[int]$Index,[string]$Text)
    $draft=Get-NewsTickerDraft -UserId $UserId;if(-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count){return $false}
    $parsed=ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems 1
    if(-not $parsed.Success -or @($parsed.Items).Count -ne 1){return $false};$items=@($draft.Items);$items[$Index]=$parsed.Items[0];$draft.Items=$items;$draft.UpdatedAt=(Get-Date).ToString('o');return(Save-NewsTickerDraft)
}
function Remove-NewsTickerDraftItem { param([long]$ChatId,[long]$UserId,[int]$Index)
    $draft=Get-NewsTickerDraft -UserId $UserId;if(-not $draft -or $Index -lt 0 -or $Index -ge @($draft.Items).Count){return $false}
    if(-not(Test-Admin -ChatId $ChatId -UserId $UserId)-and -not(Get-Setting 'AllowOperatorsDeleteNews')){return $false}
    $items=[Collections.Generic.List[string]]::new();@($draft.Items)|ForEach-Object{$items.Add([string]$_)};$items.RemoveAt($Index);$draft.Items=@($items);return(Save-NewsTickerDraft)
}
function Move-NewsTickerDraftItem { param([long]$UserId,[int]$Index,[int]$Delta)
    $draft=Get-NewsTickerDraft -UserId $UserId;$target=$Index+$Delta;if(-not $draft -or $Index -lt 0 -or $target -lt 0 -or $Index -ge @($draft.Items).Count -or $target -ge @($draft.Items).Count){return $false}
    $items=@($draft.Items);$swap=$items[$target];$items[$target]=$items[$Index];$items[$Index]=$swap;$draft.Items=$items;$draft.UpdatedAt=(Get-Date).ToString('o');return(Save-NewsTickerDraft)
}

function Import-NewsTickerTextToDraft { param([long]$UserId,[string]$Text,[ValidateSet('replace','append')][string]$Mode='replace')
    $draft=Get-NewsTickerDraft -UserId $UserId; if (-not $draft) { return [pscustomobject]@{Success=$false;Error='لا توجد مسودة مملوكة لك.'} }
    $parsed=ConvertFrom-NewsTickerText -Text $Text -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if (-not $parsed.Success) { return [pscustomobject]@{Success=$false;Error=($parsed.Errors -join ' ')} }
    $items = if ($Mode -eq 'append') { @($draft.Items)+@($parsed.Items) } else { @($parsed.Items) }
    $validated=ConvertFrom-NewsTickerText -Text (ConvertTo-NewsTickerText -Items $items -Separator ([string](Get-Setting 'NewsItemSeparator'))) -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if (-not $validated.Success) { return [pscustomobject]@{Success=$false;Error=($validated.Errors -join ' ')} }
    $draft.Items=@($validated.Items);$draft.UpdatedAt=(Get-Date).ToString('o'); Save-NewsTickerDraft | Out-Null
    return [pscustomobject]@{Success=$true;Count=$draft.Items.Count;Error=''}
}

function Clear-NewsTickerDraftItems { param([long]$ChatId,[long]$UserId)
    if (-not (Get-NewsTickerDraft -UserId $UserId)) { return $false }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId) -and -not (Get-Setting 'AllowOperatorsClearAllNews')) { return $false }
    $script:NewsTickerDraft.Items=@();$script:NewsTickerDraft.UpdatedAt=(Get-Date).ToString('o');return (Save-NewsTickerDraft)
}

function Publish-NewsTickerDraft { param([long]$ChatId,[long]$UserId)
    $draft=Get-NewsTickerDraft -UserId $UserId;if(-not $draft){return [pscustomobject]@{Success=$false;Error='لا توجد مسودة مملوكة لك.'}}
    $result=Publish-NewsTickerFile -Path ([string](Get-Setting 'NewsFilePath')) -Items @($draft.Items) -ExpectedHash ([string]$draft.BaseHash) -Separator ([string](Get-Setting 'NewsItemSeparator')) -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
    if($result.Success){ Add-AuditEntry "📰 نشر شريط الأخبار بواسطة $(Get-UserDisplayName -UserId $UserId): $(@($draft.Items).Count) خبرًا";Remove-NewsTickerDraft }
    return $result
}

function Get-NewsTickerManagementKeyboard { param([long]$ChatId,[long]$UserId)
    $rows=@();$draft=Get-NewsTickerDraft
    if(-not $draft){$rows+=,@(@{text='✏️ بدء التحرير';callback_data='news:start'},@{text='📥 استيراد TXT';callback_data='news:import'})}
    elseif([long]$draft.OwnerUserId -eq $UserId){$rows+=,@(@{text='➕ إضافة خبر';callback_data='news:add'},@{text='📝 تعديل وترتيب';callback_data='news:list'});$rows+=,@(@{text='📥 استيراد TXT';callback_data='news:import'},@{text='👁 معاينة';callback_data='news:preview'});if((Test-Admin -ChatId $ChatId -UserId $UserId)-or(Get-Setting 'AllowOperatorsClearAllNews')){$rows+=,@(@{text='🧹 مسح الكل';callback_data='news:clear'})};$rows+=,@(@{text='✅ مراجعة ونشر';callback_data='news:publish'},@{text='🗑 إلغاء المسودة';callback_data='news:cancel'})}
    else{$rows+=,@(@{text="🔒 لدى $($draft.OwnerUserId)";callback_data='news:refresh'});if(Test-Admin -ChatId $ChatId -UserId $UserId){$rows+=,@(@{text='🔓 إلغاء القفل (مشرف)';callback_data='news:unlock'})}}
    if((Test-Admin -ChatId $ChatId -UserId $UserId)-or(Get-Setting 'AllowOperatorsRestoreNews')){$rows+=,@(@{text='🕘 النسخ والاستعادة';callback_data='news:backups'})}
    $rows+=,@(@{text='🔄 تحديث';callback_data='news:refresh'},@{text='⬅️ الرئيسية';callback_data='menu'});return @{inline_keyboard=$rows}
}

function Edit-TelegramMessageText {
    <# Edits an existing message in place so interactive screens (e.g. the
       news reorder list) never pile up duplicate messages with stale
       buttons. Falls back to returning $false so callers can resend. #>
    param([Parameter(Mandatory)][long]$ChatId,[Parameter(Mandatory)][int]$MessageId,
        [Parameter(Mandatory)][string]$Text,[hashtable]$ReplyMarkup)
    $body = @{ chat_id = $ChatId; message_id = $MessageId; text = $Text }
    if ($ReplyMarkup) { $body.reply_markup = ($ReplyMarkup | ConvertTo-Json -Depth 10 -Compress) }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/editMessageText" -Method Post -Body $body `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if (-not $request.Success) { Write-BridgeLog "Failed to edit Telegram message ${MessageId}: $($request.Error)" "WARN"; return $false }
    return $true
}

function Get-NewsTickerReorderKeyboard { param([long]$UserId)
    <# One row per draft item: ⬆️ moves it up, the numbered label opens the
       per-item editor, ⬇️ moves it down. The whole list lives in ONE message
       that is edited in place, so indexes can never go stale. #>
    $draft=Get-NewsTickerDraft -UserId $UserId;$rows=@()
    if($draft){$count=@($draft.Items).Count
        for($i=0;$i-lt $count;$i++){$label="$(($i+1)). $($draft.Items[$i])";if($label.Length-gt 30){$label=$label.Substring(0,29)+'…'}
            $row=@();if($i-gt 0){$row+=,@{text='⬆️';callback_data="news:up:$i"}};$row+=,@{text=$label;callback_data="news:item:$i"};if($i-lt ($count-1)){$row+=,@{text='⬇️';callback_data="news:down:$i"}}
            $rows+=,@($row)}}
    else{$rows+=,@(@{text='لا توجد مسودة مملوكة لك';callback_data='news:refresh'})}
    $rows+=,@(@{text='➕ إضافة خبر';callback_data='news:add'},@{text='⬅️ إدارة الأخبار';callback_data='news:refresh'});return @{inline_keyboard=$rows}
}

function Get-NewsTickerReorderText { param([long]$UserId)
    $draft=Get-NewsTickerDraft -UserId $UserId
    if(-not $draft){return '📝 الترتيب والتعديل'+"`n"+'⚠️ لا توجد مسودة مملوكة لك.'}
    return "📝 ترتيب المسودة ($(@($draft.Items).Count) خبرًا):`nاضغط ⬆️ أو ⬇️ بجانب الخبر لتحريكه، واضغط نص الخبر لتعديله أو حذفه."
}

function Show-NewsTickerReorderScreen { param([long]$ChatId,[long]$UserId,[int]$MessageId=0)
    <# Edits the originating message when possible so repeated ⬆️/⬇️ presses
       reuse a single message instead of flooding the chat with stale lists. #>
    $text=Get-NewsTickerReorderText -UserId $UserId;$kb=Get-NewsTickerReorderKeyboard -UserId $UserId
    if($MessageId-gt 0 -and (Edit-TelegramMessageText -ChatId $ChatId -MessageId $MessageId -Text $text -ReplyMarkup $kb)){return}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup $kb
}

function Get-NewsTickerBackupsKeyboard {
    $rows=@();$files=@(Get-ChildItem -LiteralPath $script:newsBackupDirectory -File -Filter '*.txt' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 10)
    for($i=0;$i-lt $files.Count;$i++){$rows+=,@(@{text=$files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss');callback_data="news:restore:$i"})};$rows+=,@(@{text='⬅️ إدارة الأخبار';callback_data='news:refresh'});return @{inline_keyboard=$rows}
}

function Get-NewsTickerItemsKeyboard { param([long]$UserId)
    $draft=Get-NewsTickerDraft -UserId $UserId;$rows=@();if($draft){for($i=0;$i-lt @($draft.Items).Count;$i++){$label="$(($i+1)). $($draft.Items[$i])";if($label.Length-gt 35){$label=$label.Substring(0,34)+'…'};$rows+=,@(@{text=$label;callback_data="news:item:$i"})}}
    $rows+=,@(@{text='⬅️ إدارة الأخبار';callback_data='news:refresh'});return @{inline_keyboard=$rows}
}

function Show-NewsTickerManagementScreen { param([long]$ChatId,[long]$UserId)
    $snapshot=Get-NewsTickerConfiguredSnapshot
    $text=if($snapshot.Success){"📰 إدارة شريط الأخبار`nالحالي: $(@($snapshot.Items).Count) خبرًا."}else{"⚠️ تعذر قراءة ملف الأخبار: $($snapshot.Error)"}
    if($script:NewsTickerDraft){$text+="`nالمسودة مقفلة للمستخدم $($script:NewsTickerDraft.OwnerUserId) وتحتوي $(@($script:NewsTickerDraft.Items).Count) خبرًا."}
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
}

function Complete-NewsTickerAddText { param([long]$ChatId,[long]$UserId,[string]$Value)
    Clear-PendingState -ChatId $ChatId
    $ok=Add-NewsTickerDraftItem -UserId $UserId -Text $Value
    Send-TelegramMessage -ChatId $ChatId -Text $(if($ok){'✅ أضيف الخبر إلى المسودة فقط.'}else{'❌ لم تتم الإضافة؛ تحقق من النص والحدود.'}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
}
function Complete-NewsTickerEditText { param([long]$ChatId,[long]$UserId,[string]$Value)
    $state=Get-PendingState -ChatId $ChatId;if(-not $state -or $state.Mode-ne'news_edit_text'){return};$index=[int]$state.Index;Clear-PendingState -ChatId $ChatId
    $ok=Update-NewsTickerDraftItem -UserId $UserId -Index $index -Text $Value
    Send-TelegramMessage -ChatId $chatId -Text $(if($ok){'✅ حُدّث الخبر في المسودة.'}else{'❌ تعذر تعديل الخبر.'});Show-NewsTickerReorderScreen -ChatId $chatId -UserId $UserId
}

function Receive-NewsTickerImport { param($Document,[long]$ChatId,[long]$UserId)
    $state=Get-PendingState -ChatId $ChatId
    if(-not $state -or $state.Mode -ne 'news_import_upload' -or [long]$state.UserId -ne $UserId){Send-TelegramMessage -ChatId $ChatId -Text 'ابدأ الاستيراد من إدارة شريط الأخبار أولًا.';return}
    $name=[string](Get-JsonProp $Document 'file_name');if([IO.Path]::GetExtension($name) -ine '.txt'){Send-TelegramMessage -ChatId $ChatId -Text 'يُقبل ملف TXT فقط.';return}
    $staged=Join-Path $script:newsImportDirectory ("news-$([guid]::NewGuid().ToString('N')).txt")
    try {
        Receive-TelegramDocument -FileId ([string](Get-JsonProp $Document 'file_id')) -DestinationPath $staged -MaximumBytes (Get-SettingInt 'NewsImportMaxBytes' 1)|Out-Null
        $snapshot=Get-NewsTickerSnapshot -Path $staged -Separator ([string](Get-Setting 'NewsItemSeparator')) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
        if(-not $snapshot.Success){throw $snapshot.Error}
        $text=ConvertTo-NewsTickerText -Items @($snapshot.Items) -Separator ([string](Get-Setting 'NewsItemSeparator'))
        $result=Import-NewsTickerTextToDraft -UserId $UserId -Text $text -Mode replace
        if(-not $result.Success){throw $result.Error}
        Clear-PendingState -ChatId $ChatId
        Send-TelegramMessage -ChatId $ChatId -Text "✅ استورد $($result.Count) خبرًا إلى المسودة فقط. راجعها قبل النشر." -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $ChatId -UserId $UserId)
    } catch { Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل الاستيراد: $($_.Exception.Message)" }
    finally {Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue}
}

function Send-TelegramDocument {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Caption = ''
    )
    try { $form = @{ chat_id = "$ChatId"; document = Get-Item -LiteralPath $FilePath -ErrorAction Stop } }
    catch { Write-BridgeLog "Failed to send Telegram document to $ChatId : $($_.Exception.Message)" 'ERROR'; return $false }
    if ($Caption) { $form.caption = $Caption }
    $request = Invoke-BridgeTelegramRequest -Uri "$apiBase/sendDocument" -Method Post -Form $form `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) -MaxAttempts 2
    if (-not $request.Success) {
        Write-BridgeLog "Failed to send Telegram document to $ChatId : $($request.Error)" 'ERROR'
        return $false
    }
    return $true
}

function Receive-TelegramDocument {
    param(
        [Parameter(Mandatory)][string]$FileId,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaximumBytes = 1048576
    )
    $metadata = Invoke-RestMethod -Uri "$apiBase/getFile?file_id=$([uri]::EscapeDataString($FileId))" -Method Get `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1)
    if (-not (Get-JsonProp $metadata 'ok')) { throw 'Telegram رفض طلب معلومات الملف.' }
    $result = Get-JsonProp $metadata 'result'
    $remotePath = [string](Get-JsonProp $result 'file_path')
    if ([string]::IsNullOrWhiteSpace($remotePath) -or $remotePath.Contains('..') -or $remotePath -notmatch '^[A-Za-z0-9_./-]+$') {
        throw 'Telegram أعاد مسار ملف غير صالح.'
    }
    $directory = Split-Path -Parent $DestinationPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Invoke-WebRequest -Uri "https://api.telegram.org/file/bot$($config.BotToken)/$remotePath" -OutFile $DestinationPath `
        -TimeoutSec (Get-SettingInt 'TelegramRequestTimeoutSeconds' 1) | Out-Null
    $length = (Get-Item -LiteralPath $DestinationPath -ErrorAction Stop).Length
    if ($length -le 0 -or $length -gt $MaximumBytes) {
        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        throw "حجم ملف الاستيراد غير صالح ($length بايت)."
    }
    return $DestinationPath
}

function Save-UserProfiles {
    param([switch]$Force)
    if (-not $script:UserProfilesDirty) { return $true }
    if (-not $Force -and ((Get-Date) - $script:LastUserProfilesFlush).TotalSeconds -lt 60) { return $true }
    try {
        $temporary = "$($script:userProfilesFile).tmp"
        $script:UserProfiles | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:userProfilesFile -Force -ErrorAction Stop
        $script:UserProfilesDirty = $false; $script:LastUserProfilesFlush = Get-Date
        return $true
    }
    catch { Write-BridgeLog "Could not write user-profiles.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Record-UserApprovalMetadata {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ApprovedByUserId)
    $script:UserProfiles[[string]$TargetUserId] = @{ AddedAt = (Get-Date).ToString('o'); AddedByUserId = $ApprovedByUserId; LastActivityAt = $null }
    $script:UserProfilesDirty = $true
    return Save-UserProfiles -Force
}

function Update-UserLastActivity {
    param([Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Authorized -ChatId $UserId -UserId $UserId)) { return $false }
    $id = [string]$UserId
    if (-not $script:UserProfiles.ContainsKey($id)) { $script:UserProfiles[$id] = @{ AddedAt = ''; AddedByUserId = 0L; LastActivityAt = '' } }
    $script:UserProfiles[$id].LastActivityAt = (Get-Date).ToString('o'); $script:UserProfilesDirty = $true
    Save-UserProfiles | Out-Null
    return $true
}

function Import-DisabledUsers {
    if (-not (Test-Path -LiteralPath $script:disabledUsersFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:disabledUsersFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { if ([bool]$prop.Value) { $script:DisabledUserIds[$prop.Name] = $true } }
    }
    catch { Write-BridgeLog "Could not read disabled-users.json: $($_.Exception.Message)" 'WARN' }
}

function Save-DisabledUsers {
    try {
        $temporary = "$($script:disabledUsersFile).tmp"
        $script:DisabledUserIds | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:disabledUsersFile -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write disabled-users.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Set-UserDisabled {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][bool]$Disabled)
    if ($TargetUserId -le 0) { return $false }
    if ($Disabled) {
        $adminIds = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
        $activeAdmins = @($adminIds | Where-Object { -not (Test-UserDisabled -UserId ([long]$_)) })
        if ($adminIds -contains $TargetUserId -and $activeAdmins.Count -le 1) { return $false }
    }
    if ($Disabled) { $script:DisabledUserIds[[string]$TargetUserId] = $true }
    else { $script:DisabledUserIds.Remove([string]$TargetUserId) }
    return Save-DisabledUsers
}

function Test-UserDisabled {
    param([Parameter(Mandatory)][long]$UserId)
    return $script:DisabledUserIds.ContainsKey([string]$UserId)
}

function Revoke-AuthorizedUser {
    param([Parameter(Mandatory)][long]$TargetUserId)
    $admins = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
    if ($admins -contains $TargetUserId -and $admins.Count -le 1) { return [pscustomobject]@{ Success = $false; Error = 'لا يمكن سحب صلاحية آخر مشرف.' } }
    foreach ($name in @('AllowedChatIds', 'AllowedUserIds', 'AdminChatIds', 'AdminUserIds')) {
        $remaining = @(@(Get-JsonProp $config $name) | Where-Object { [long]$_ -ne $TargetUserId })
        $config | Add-Member -NotePropertyName $name -NotePropertyValue $remaining -Force
    }
    $script:DisabledUserIds.Remove([string]$TargetUserId)
    $script:UserProfiles.Remove([string]$TargetUserId); $script:UserProfilesDirty = $true
    Save-DisabledUsers | Out-Null; Save-UserProfiles -Force | Out-Null; Save-Config
    return [pscustomobject]@{ Success = $true; Error = '' }
}

function Get-AuthorizedUsers {
    $ids = @(@(Get-JsonProp $config 'AllowedUserIds') + @(Get-JsonProp $config 'AllowedChatIds') + @(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') |
            Where-Object { [long]$_ -gt 0 } | Sort-Object -Unique)
    $adminIds = @(@(Get-JsonProp $config 'AdminUserIds') + @(Get-JsonProp $config 'AdminChatIds') | Sort-Object -Unique)
    return @($ids | ForEach-Object {
            $id = [long]$_
            [pscustomobject]@{
                UserId = $id; Alias = Get-UserDisplayName -UserId $id
                Role = if ($adminIds -contains $id) { 'admin' } else { 'operator' }
                Disabled = Test-UserDisabled -UserId $id
                AddedAt = if ($script:UserProfiles.ContainsKey([string]$id)) { [string]$script:UserProfiles[[string]$id].AddedAt } else { '' }
                AddedByUserId = if ($script:UserProfiles.ContainsKey([string]$id)) { [long]$script:UserProfiles[[string]$id].AddedByUserId } else { 0L }
                LastActivityAt = if ($script:UserProfiles.ContainsKey([string]$id)) { [string]$script:UserProfiles[[string]$id].LastActivityAt } else { '' }
            }
        })
}

function Request-UserRevocation {
    param([Parameter(Mandatory)][long]$TargetUserId, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$AdminUserId)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'user_revoke'; TargetUserId = $TargetUserId; UserId = $AdminUserId }
    Send-TelegramMessage -ChatId $ChatId -Text "⚠️ تأكيد سحب صلاحية $(Get-UserDisplayName -UserId $TargetUserId) ($TargetUserId)؟" `
        -ReplyMarkup @{ inline_keyboard = @(, @((New-Button '✅ نعم، اسحب الصلاحية' 'usr:revokeconfirm'), (New-Button '❌ إلغاء' 'menu:usersadmin'))) }
}

function Test-Authorized {
    <# In a private chat chat.id == user.id, so the historical AllowedChatIds
       list keeps working untouched. In a group they differ, and with
       RequireUserLevelAuth on (the default) the sender must be listed in
       AllowedUserIds explicitly - whitelisting a group no longer implicitly
       authorizes every member of it. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return Test-BridgeAuthorized -ChatId $ChatId -UserId $UserId `
        -AllowedUserIds @(Get-JsonProp $config 'AllowedUserIds') -AllowedChatIds @(Get-JsonProp $config 'AllowedChatIds') `
        -DisabledUserIds @($script:DisabledUserIds.Keys) -RequireUserLevelAuth:([bool](Get-Setting 'RequireUserLevelAuth'))
}

function Test-Admin {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    return Test-BridgeAdministrator -ChatId $ChatId -UserId $UserId `
        -AdminUserIds @(Get-JsonProp $config 'AdminUserIds') -AdminChatIds @(Get-JsonProp $config 'AdminChatIds') `
        -RequireUserLevelAuth:([bool](Get-Setting 'RequireUserLevelAuth'))
}

function Test-TelegramPrivateChat {
    <# This bridge is intentionally operated through one-to-one chats only.
       Telegram always supplies chat.type; the positive-id fallback keeps old
       saved/test callback payloads compatible without authorizing groups. #>
    param($Chat)
    return Test-BridgePrivateChat -Chat $Chat
}

# ============================================================================
#  Template registry (cached, validated, deterministically ordered)
# ============================================================================

$script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }

function Get-TemplateRegistryFilePath {
    $configured = [string]$config.TemplateRegistryPath
    if ([System.IO.Path]::IsPathRooted($configured)) { return $configured }
    return (Join-Path $scriptRoot $configured)
}

function Save-TemplatePresetChange {
    <# Mutates only the presets array of one template. A timestamped backup is
       taken first and the final JSON replaces the original atomically. #>
    param(
        [Parameter(Mandatory)][string]$TemplateKey,
        [Parameter(Mandatory)][ValidateSet('create', 'rename', 'edit', 'delete')][string]$Action,
        [int]$PresetIndex = -1,
        [string]$Name = '',
        [object[]]$Values = @()
    )
    $path = Get-TemplateRegistryFilePath
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $template = Get-JsonProp $raw $TemplateKey
        if (-not $template) { throw "Template '$TemplateKey' was not found." }
        $presets = @(Get-JsonProp $template 'presets' | Where-Object { $null -ne $_ })

        if ($Action -eq 'create') {
            if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Preset name is empty.' }
            if (@($presets | Where-Object { [string](Get-JsonProp $_ 'name') -eq $Name }).Count -gt 0) {
                throw "Preset '$Name' already exists."
            }
            $presets += [pscustomobject]@{ name = $Name.Trim(); values = @($Values | ForEach-Object { [string]$_ }) }
        }
        else {
            if ($PresetIndex -lt 0 -or $PresetIndex -ge $presets.Count) { throw 'Preset index is no longer valid.' }
            switch ($Action) {
                'rename' {
                    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Preset name is empty.' }
                    $presets[$PresetIndex] | Add-Member -NotePropertyName name -NotePropertyValue $Name.Trim() -Force
                }
                'edit' {
                    $presets[$PresetIndex] | Add-Member -NotePropertyName values -NotePropertyValue @($Values | ForEach-Object { [string]$_ }) -Force
                }
                'delete' {
                    $presets = @($presets | Where-Object { $_ -ne $presets[$PresetIndex] })
                }
            }
        }
        $template | Add-Member -NotePropertyName presets -NotePropertyValue @($presets) -Force

        $backupDir = "$path.backups"
        New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $backupPath = Join-Path $backupDir "templates-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
        $keep = Get-SettingInt 'ConfigBackupKeepFiles' 1
        if ($keep -gt 0) {
            @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip $keep) |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }

        $temporary = "$path.tmp"
        $raw | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        $script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }
        return [pscustomobject]@{ Success = $true; Error = ''; BackupPath = $backupPath }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; BackupPath = '' }
    }
}

function Get-TemplateStore {
    <# Returns @{ Map; Order; Errors }. Cached on the file's LastWriteTimeUtc,
       so editing templates.json takes effect immediately without a restart,
       but a single button press no longer re-parses the file a dozen times.
       Order is sorted by the optional "order" field then by key, so button
       positions stay stable between renders (hashtable order is not). #>
    $path = Get-TemplateRegistryFilePath
    if (-not (Test-Path $path)) {
        return @{ Map = @{}; Order = @(); Errors = @("ملف القوالب غير موجود: $path"); InvalidKeys = @(); SharedLayers = @{} }
    }
    $writeTime = (Get-Item $path).LastWriteTimeUtc
    if ($script:TemplateCache.Path -eq $path -and $script:TemplateCache.WriteTime -eq $writeTime) {
        return $script:TemplateCache
    }

    $map = @{}
    $errors = [System.Collections.Generic.List[string]]::new()
    $invalidKeys = [System.Collections.Generic.List[string]]::new()
    $layerTemplates = @{}
    try {
        $raw = Get-Content -Path $path -Raw | ConvertFrom-Json
    }
    catch {
        # Cache the failure too, keyed on the same write time: otherwise a
        # malformed templates.json is re-parsed and re-logged on every single
        # call - dozens of times per button press.
        $script:TemplateCache = @{
            WriteTime = $writeTime; Path = $path; Map = @{}; Order = @()
            Errors    = @("تعذّر قراءة templates.json: $($_.Exception.Message)")
            InvalidKeys = @(); SharedLayers = @{}
        }
        Write-BridgeLog "Template registry unreadable: $($_.Exception.Message)" "ERROR"
        return $script:TemplateCache
    }

    foreach ($prop in $raw.PSObject.Properties) {
        $key = $prop.Name
        $entry = $prop.Value
        $tplPath = Get-JsonProp $entry 'path'
        $layerRaw = Get-JsonProp $entry 'layer'
        $layer = 0
        if ([string]::IsNullOrWhiteSpace([string]$tplPath)) {
            $errors.Add("القالب '$key' بلا حقل path - تم تخطيه.")
            $invalidKeys.Add($key)
            continue
        }
        if (-not [IO.Path]::IsPathRooted([string]$tplPath)) {
            $errors.Add("القالب '$key' له مسار غير مطلق '$tplPath' - تم تخطيه.")
            $invalidKeys.Add($key)
            continue
        }
        if (-not [IO.Path]::GetExtension([string]$tplPath).Equals('.cintitle', [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("القالب '$key' يجب أن يشير إلى ملف .cintitle - تم تخطيه.")
            $invalidKeys.Add($key)
            continue
        }
        if (-not [int]::TryParse([string]$layerRaw, [ref]$layer)) {
            $errors.Add("القالب '$key' بلا حقل layer صالح - تم تخطيه.")
            $invalidKeys.Add($key)
            continue
        }
        $order = 1000
        $parsedOrder = 0
        if ([int]::TryParse([string](Get-JsonProp $entry 'order'), [ref]$parsedOrder)) { $order = $parsedOrder }

        $presets = @()
        foreach ($p in @(Get-JsonProp $entry 'presets')) {
            if (-not $p) { continue }
            $presets += , @{
                Name   = [string](Get-JsonProp $p 'name')
                Values = @(Get-JsonProp $p 'values' | Where-Object { $null -ne $_ })
            }
        }

        # A "fields" entry may be either a plain variable name, or an object
        # { "name": "Ajel.center", "label": "نص العاجل" } so operators are
        # prompted with something human instead of a scene variable name.
        # The Where-Object is load-bearing: an absent "fields" key makes
        # Get-JsonProp emit a single $null, and a bare @() around that yields a
        # one-element array holding $null - i.e. a phantom field the operator
        # would be prompted to fill in.
        # Optional per-template default, e.g. a ticker that tolerates more text
        # than a lower-third. 0 means "use the global MaxFieldLength setting".
        $templateLimit = 0
        $parsedLimit = 0
        if ([int]::TryParse([string](Get-JsonProp $entry 'maxLength'), [ref]$parsedLimit) -and $parsedLimit -gt 0) {
            $templateLimit = $parsedLimit
        }

        $fieldNames = @()
        $fieldLabels = @()
        $fieldLimits = @()
        $fieldRequired = @()
        $fieldSensitive = @()
        # Name -> Cinegy variable type override (Text|String|Bool|Float).
        # Empty means "use the AirVariableType setting".
        $fieldTypes = @{}
        foreach ($f in @(Get-JsonProp $entry 'fields' | Where-Object { $null -ne $_ })) {
            if ($f -is [string]) {
                $fieldNames += $f
                $fieldLabels += ''
                $fieldLimits += $templateLimit
                $fieldRequired += $false
                $fieldSensitive += $false
            }
            else {
                $fname = [string](Get-JsonProp $f 'name')
                if ([string]::IsNullOrWhiteSpace($fname)) {
                    $errors.Add("القالب '$key' فيه حقل بلا اسم - تم تخطيه.")
                    continue
                }
                $fieldNames += $fname
                $fieldLabels += [string](Get-JsonProp $f 'label')
                $fieldRequired += ((Get-JsonProp $f 'required') -eq $true)
                $fieldSensitive += ((Get-JsonProp $f 'sensitive') -eq $true)
                $fieldTypes[$fname] = [string](Get-JsonProp $f 'type')
                # Per-field limit wins over the template default, which wins
                # over the global setting.
                $fieldLimit = $templateLimit
                $parsedField = 0
                if ([int]::TryParse([string](Get-JsonProp $f 'maxLength'), [ref]$parsedField) -and $parsedField -gt 0) {
                    $fieldLimit = $parsedField
                }
                $fieldLimits += $fieldLimit
            }
        }

        $map[$key] = @{
            Key         = $key
            Path        = [string]$tplPath
            Layer       = $layer
            Fields      = $fieldNames
            FieldLabels = $fieldLabels
            FieldLimits = $fieldLimits
            FieldRequired = $fieldRequired
            FieldSensitive = $fieldSensitive
            FieldTypes  = $fieldTypes
            MaxLength   = $templateLimit
            Description = [string](Get-JsonProp $entry 'description')
            Category    = [string](Get-JsonProp $entry 'category')
            Order       = $order
            Presets     = $presets
        }
        $layerKey = [string]$layer
        if (-not $layerTemplates.ContainsKey($layerKey)) { $layerTemplates[$layerKey] = @() }
        $layerTemplates[$layerKey] = @($layerTemplates[$layerKey]) + $key
    }

    # Script-block sort expressions: -Property 'Name' resolves ambiguously
    # against a [hashtable]'s own members, so address the entries explicitly.
    $ordered = @($map.Values | Sort-Object -Property @{ Expression = { $_.Order } }, @{ Expression = { $_.Key } } | ForEach-Object { $_.Key })
    $sharedLayers = @{}
    foreach ($layerKey in $layerTemplates.Keys) {
        if (@($layerTemplates[$layerKey]).Count -gt 1) { $sharedLayers[$layerKey] = @($layerTemplates[$layerKey] | Sort-Object) }
    }

    $script:TemplateCache = @{
        WriteTime = $writeTime
        Path      = $path
        Map       = $map
        Order     = $ordered
        Errors    = @($errors)
        InvalidKeys = $invalidKeys.ToArray()
        SharedLayers = $sharedLayers
    }
    foreach ($e in $errors) { Write-BridgeLog "Template registry: $e" "WARN" }
    return $script:TemplateCache
}

function Get-TemplateByIndex {
    param([Parameter(Mandatory)][int]$Index)
    $store = Get-TemplateStore
    if ($Index -lt 0 -or $Index -ge $store.Order.Count) { return $null }
    return $store.Map[$store.Order[$Index]]
}

function Get-TemplateIndex {
    param([Parameter(Mandatory)][string]$Key)
    $store = Get-TemplateStore
    return [array]::IndexOf($store.Order, $Key)
}

function Get-KnownLayers {
    $store = Get-TemplateStore
    $layers = @($store.Map.Values | ForEach-Object { $_.Layer } | Sort-Object -Unique)
    if ($layers.Count -eq 0) { $layers = 1..8 }
    return $layers
}

function Save-TemplateDefinitionChange {
    param(
        [Parameter(Mandatory)][string]$TemplateKey,
        [Parameter(Mandatory)][ValidateSet('edit', 'create', 'delete')][string]$Action,
        [hashtable]$Definition = @{}
    )
    $path = Get-TemplateRegistryFilePath
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $existing = Get-JsonProp $raw $TemplateKey
        if ($Action -eq 'create' -and $existing) { throw "يوجد قالب بالمفتاح '$TemplateKey' بالفعل." }
        if ($Action -ne 'create' -and -not $existing) { throw "القالب '$TemplateKey' غير موجود." }
        if ($Action -eq 'delete') {
            if (@($script:OnAir.Values | Where-Object { [string](Get-JsonProp $_ 'Key') -eq $TemplateKey }).Count -gt 0) { throw 'لا يمكن حذف قالب على الهواء.' }
            if (@(Get-UpcomingScheduleEvents | Where-Object { [string](Get-JsonProp $_ 'TemplateKey') -eq $TemplateKey }).Count -gt 0) { throw 'لا يمكن حذف قالب مرتبط بجدولة قادمة.' }
            $raw.PSObject.Properties.Remove($TemplateKey)
        }
        else {
            $templatePath = [string](Get-JsonProp $Definition 'path')
            $layer = 0
            if ([string]::IsNullOrWhiteSpace($templatePath)) { throw 'مسار القالب فارغ.' }
            if (-not [int]::TryParse([string](Get-JsonProp $Definition 'layer'), [ref]$layer) -or $layer -le 0) { throw 'رقم الطبقة يجب أن يكون موجبًا.' }
            $root = [IO.Path]::GetFullPath($scriptRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $resolved = [IO.Path]::GetFullPath((Join-Path $scriptRoot $templatePath))
            if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'مسار القالب يجب أن يكون داخل مجلد المشروع.' }
            $fields = @(Get-JsonProp $Definition 'fields')
            foreach ($field in $fields) {
                $fieldName = if ($field -is [string]) { $field } else { [string](Get-JsonProp $field 'name') }
                if ([string]::IsNullOrWhiteSpace([string]$fieldName)) { throw 'يوجد حقل بلا اسم صالح.' }
            }
            if ($Action -eq 'create') { $target = [pscustomobject]@{}; $raw | Add-Member -NotePropertyName $TemplateKey -NotePropertyValue $target }
            else { $target = $existing }
            foreach ($name in @('path', 'layer', 'order', 'description', 'category', 'fields')) {
                if ($Definition.ContainsKey($name)) { $target | Add-Member -NotePropertyName $name -NotePropertyValue $Definition[$name] -Force }
            }
        }
        $backupDir = "$path.backups"
        New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
        $backupPath = Join-Path $backupDir "templates-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
        $temporary = "$path.tmp"
        $raw | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        $script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }
        return [pscustomobject]@{ Success = $true; Error = ''; BackupPath = $backupPath }
    }
    catch { return [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; BackupPath = '' } }
}

function Get-HideAllTargetLayers {
    <# "all" preserves the established default. An empty or invalid selection
       deliberately hides nothing, so a bad configuration cannot widen scope. #>
    $known = @((Get-KnownLayers | ForEach-Object { [int]$_ }) | Sort-Object -Unique)
    $raw = [string](Get-Setting 'HideAllLayers')
    if ($raw.Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) { return $known }

    $selected = @()
    foreach ($part in ($raw -split '[,;\s]+')) {
        $layer = 0
        if ([int]::TryParse($part.Trim(), [ref]$layer) -and $known -contains $layer) { $selected += $layer }
    }
    return @($selected | Sort-Object -Unique)
}

function Get-CinegyLayerDashboard {
    <# Takes one read-only snapshot of every GFX layer referenced by the
       configured templates. Each returned status carries its Layer number so
       the same sample can be formatted and reused for reconciliation. #>
    foreach ($layer in (Get-KnownLayers)) {
        $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
            -AirChannelNumber $config.AirChannelNumber -Layer ([int]$layer) `
            -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $status | Add-Member -NotePropertyName Layer -NotePropertyValue ([int]$layer) -Force
        Write-Output $status
    }
}

function Format-CinegyLayerDashboard {
    param([Parameter(Mandatory)][object[]]$LayerStatuses)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('🎚 حالة طبقات Cinegy:')
    $lines.Add('الإجراءات: 🙈 إخفاء = يخفي الطبقة فورًا | 🔄 تحديث = يعيد فحص كل الطبقات')
    $lines.Add('')

    foreach ($status in @($LayerStatuses | Sort-Object Layer)) {
        $layer = [int]$status.Layer
        if (-not $status.Success) {
            $lines.Add("⚠️ $(Get-LayerDisplayName -Layer $layer): غير معروف")
            continue
        }
        if (-not $status.IsOnAir) {
            $lines.Add("⚪ $(Get-LayerDisplayName -Layer $layer): مخفية")
            continue
        }

        $trackedKey = ''
        if ($script:OnAir.ContainsKey($layer)) {
            $trackedId = [string](Get-JsonProp $script:OnAir[$layer] 'ActiveId')
            $actualId = [string](Get-JsonProp $status 'ActiveId')
            if (-not [string]::IsNullOrWhiteSpace($trackedId) -and
                $trackedId.Trim().Trim('{', '}').Equals($actualId.Trim().Trim('{', '}'), [System.StringComparison]::OrdinalIgnoreCase)) {
                $trackedKey = [string](Get-JsonProp $script:OnAir[$layer] 'Key')
            }
        }

        $trackedSource = if ($script:OnAir.ContainsKey($layer)) { [string](Get-JsonProp $script:OnAir[$layer] 'Source') } else { '' }
        if ($trackedKey -and $trackedSource -ne 'cinegy') {
            $lines.Add("🔴 $(Get-LayerDisplayName -Layer $layer): $trackedKey")
        }
        else {
            $activeName = [string](Get-JsonProp $status 'ActiveTemplateName')
            if ([string]::IsNullOrWhiteSpace($activeName)) { $activeName = [string](Get-JsonProp $status 'ActiveName') }
            if ([string]::IsNullOrWhiteSpace($activeName)) { $activeName = 'مشهد غير مسمّى' }
            $lines.Add("🟠 $(Get-LayerDisplayName -Layer $layer): $activeName (خارجي)")
        }
    }

    $metadata = @($LayerStatuses | Where-Object { $_.Success } | Select-Object -First 1)
    if ($metadata.Count -gt 0) {
        $meta = $metadata[0]
        $parts = [System.Collections.Generic.List[string]]::new()
        $outputState = [string](Get-JsonProp $meta 'OutputState')
        $licenseState = [string](Get-JsonProp $meta 'LicenseState')
        $clientIdentity = [string](Get-JsonProp $meta 'ClientIdentity')
        $clientConnected = [bool](Get-JsonProp $meta 'ClientConnected')
        if ($outputState) { $parts.Add("الخرج $outputState") }
        if ($licenseState) { $parts.Add("الترخيص $licenseState") }
        if ($clientConnected) {
            if (-not $clientIdentity) { $clientIdentity = 'متصل' }
            $parts.Add("العميل $clientIdentity")
        }
        else { $parts.Add('العميل غير متصل') }
        if ($parts.Count -gt 0) { $lines.Add('• ' + ($parts -join ' | ')) }
    }
    return ($lines -join "`n")
}

function Format-CinegyTelemetryStatus {
    param([Parameter(Mandatory)]$Telemetry)
    if (-not $Telemetry.Success) {
        return "⚠️ صحة Cinegy: غير معروفة (تعذّر قراءة metrics)"
    }
    if ($null -eq $Telemetry.Healthy) {
        return "⚠️ صحة Cinegy: غير معروفة (لا توجد عينات)"
    }
    $summary = "العينات $($Telemetry.SampleCount)، الخرج $($Telemetry.OutputCount)، الساقط $($Telemetry.DroppedCount)، فقد الإدخال $($Telemetry.NoInputSignal)، أخطاء القراءة $($Telemetry.MaxReadErrorRate)%، متوسط القراءة $($Telemetry.AverageReadTime)ms، Heartbeat $($Telemetry.MaxHeartbeat)ms"
    if ($Telemetry.Healthy) { return "💚 صحة Cinegy: سليمة — $summary" }
    return "🔴 صحة Cinegy: تحذير — $summary"
}

# ---- usage counters (drive the ⭐ favourites row) ----

$script:UsageCounts = @{}
$script:TemplateLastUsed = @{}
$script:UserFavorites = @{}
$script:UserAliases = @{}
$script:UsageDirty = $false
$script:LastUsageFlush = [datetime]::MinValue

function Import-UsageCounts {
    if (-not (Test-Path $usageFile)) { return }
    try {
        $raw = Get-Content -Path $usageFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) {
            if ($prop.Value -is [ValueType]) { $script:UsageCounts[$prop.Name] = [int]$prop.Value; continue }
            $script:UsageCounts[$prop.Name] = [int](Get-JsonProp $prop.Value 'Count')
            $lastUsed = [string](Get-JsonProp $prop.Value 'LastUsedUtc')
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($lastUsed, [ref]$parsed)) { $script:TemplateLastUsed[$prop.Name] = $parsed.ToUniversalTime() }
        }
    }
    catch { Write-BridgeLog "Could not read usage.json: $($_.Exception.Message)" "WARN" }
}

function Add-UsageCount {
    <# Counts in memory and marks the file dirty; the actual write is deferred
       to the tick. Writing on every push put synchronous disk I/O directly on
       the on-air path for what is only a button-ordering statistic. #>
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:UsageCounts.ContainsKey($Key)) { $script:UsageCounts[$Key] = 0 }
    $script:UsageCounts[$Key]++
    $script:TemplateLastUsed[$Key] = [datetime]::UtcNow
    $script:UsageDirty = $true
}

function Save-UsageCounts {
    param([switch]$Force)
    if (-not $script:UsageDirty) { return }
    if (-not $Force -and ((Get-Date) - $script:LastUsageFlush).TotalSeconds -lt 60) { return }
    $script:LastUsageFlush = Get-Date
    try {
        $persisted = [ordered]@{}
        foreach ($key in @($script:UsageCounts.Keys | Sort-Object)) {
            $persisted[$key] = [ordered]@{
                Count = [int]$script:UsageCounts[$key]
                LastUsedUtc = if ($script:TemplateLastUsed.ContainsKey($key)) { ([datetime]$script:TemplateLastUsed[$key]).ToUniversalTime().ToString('o') } else { '' }
            }
        }
        $persisted | ConvertTo-Json -Depth 4 | Set-Content -Path $usageFile -Encoding utf8 -ErrorAction Stop
        $script:UsageDirty = $false
    }
    catch { Write-BridgeLog "Could not write usage.json: $($_.Exception.Message)" "WARN" }
}

function Import-OnAirState {
    <# Restores what the bridge believed was live before a restart, so the
       🔴 row and one-tap hide survive a service bounce. Treated as advisory:
       it is the bot's own record, not a query of Air Pro. #>
    try {
        $read = Read-ValidatedJsonState -Path $onAirFile
        if (-not $read) { return }
        $raw = $read.Data
        foreach ($prop in $raw.PSObject.Properties) {
            $layer = 0
            if (-not [int]::TryParse($prop.Name, [ref]$layer)) { continue }
            $at = Get-Date
            $parsedAt = [datetime]::MinValue
            if ([datetime]::TryParse([string](Get-JsonProp $prop.Value 'At'), [ref]$parsedAt)) { $at = $parsedAt }
            $script:OnAir[$layer] = @{
                Key    = [string](Get-JsonProp $prop.Value 'Key')
                At     = $at
                UserId = [long](Get-JsonProp $prop.Value 'UserId')
                ActiveId = [string](Get-JsonProp $prop.Value 'ActiveId')
                Source = if (Get-JsonProp $prop.Value 'Source') { [string](Get-JsonProp $prop.Value 'Source') } else { 'bridge' }
            }
        }
        if ($script:OnAir.Count -gt 0) { Write-BridgeLog "Restored on-air record for $($script:OnAir.Count) layer(s) from the previous run" }
    }
    catch { Write-BridgeLog "Could not read onair.json: $($_.Exception.Message)" "WARN" }
}

function Save-OnAirState {
    try {
        Write-BridgeLog "Save-OnAirState invoked (in-memory layers: $($script:OnAir.Keys.Count))" "DEBUG"
        $parentDir = Split-Path $onAirFile -Parent
        if (-not (Test-Path -LiteralPath $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        $out = @{}
        foreach ($layer in $script:OnAir.Keys) {
            $info = $script:OnAir[$layer]
            $atVal = Get-JsonProp $info 'At'
            $atStr = if ($atVal -is [datetime]) { $atVal.ToString('o') } elseif ($atVal) { [string]$atVal } else { (Get-Date).ToString('o') }
            $out["$layer"] = @{
                Key = [string](Get-JsonProp $info 'Key')
                At = $atStr
                UserId = [long](Get-JsonProp $info 'UserId')
                ActiveId = [string](Get-JsonProp $info 'ActiveId')
                Source = if (Get-JsonProp $info 'Source') { [string](Get-JsonProp $info 'Source') } else { 'bridge' }
            }
        }
        $json = $out | ConvertTo-Json -Depth 4
        Write-BridgeLog "Writing validated onair payload (size: $($json.Length) chars)" "DEBUG"
        if (-not (Write-ValidatedJsonState -Path $onAirFile -Json $json)) { throw 'validated state write failed' }
        # Log a successful write so operators can see when the onair.json was updated.
        Write-BridgeLog "Wrote onair.json ($($out.Keys.Count) layer(s)) to $onAirFile" "INFO"
    }
    catch { Write-BridgeLog "Could not write onair.json: $($_.Exception.Message)" "WARN" }
}

function Test-OnAirTemplateMatch {
    param(
        [string]$TemplateKey,
        [string]$ActiveName,
        [bool]$HasTrackedId = $false
    )
    if ([string]::IsNullOrWhiteSpace($ActiveName)) {
        return $HasTrackedId
    }
    if ([string]::IsNullOrWhiteSpace($TemplateKey)) { return $false }

    $cleanActive = $ActiveName.Trim()
    $cleanKey = $TemplateKey.Trim()

    if ($cleanActive -ieq $cleanKey -or
        $cleanActive -like "*$cleanKey*" -or
        $cleanKey -like "*$cleanActive*") {
        return $true
    }

    $store = Get-TemplateStore
    $tpl = Get-JsonProp $store.Map $TemplateKey

    if ($tpl) {
        $tplPath = [string](Get-JsonProp $tpl 'path')
        if (-not [string]::IsNullOrWhiteSpace($tplPath)) {
            $fileName = [System.IO.Path]::GetFileName($tplPath)
            $fileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($tplPath)
            if ($cleanActive -ieq $fileName -or
                $cleanActive -ieq $fileNameNoExt -or
                $cleanActive -like "*$fileNameNoExt*" -or
                $fileNameNoExt -like "*$cleanActive*") {
                return $true
            }
        }
    }
    return $false
}

function Update-OnAirStateFromCinegy {
    <# Reconciles onair.json with Cinegy's current GFX-layer state. Regular
       watchdog calls verify bridge-tracked layers only. Operator checks pass a
       full dashboard sample with -DiscoverExternal, allowing scenes started
       directly in Cinegy to become hideable without turning onair.json into a
       historical log. Failed queries never add or remove state. #>
    param(
        [string]$Reason = 'manual',
        [object[]]$LayerStatuses = @(),
        [int]$TimeoutSec = 0,
        [switch]$DiscoverExternal
    )
    if ($TimeoutSec -le 0) { $TimeoutSec = Get-AirTimeout }

    $checked = [System.Collections.Generic.List[int]]::new()
    $added = [System.Collections.Generic.List[int]]::new()
    $removed = [System.Collections.Generic.List[int]]::new()
    $failed = [System.Collections.Generic.List[int]]::new()
    $changes = [System.Collections.Generic.List[object]]::new()
    $statusByLayer = @{}
    foreach ($item in @($LayerStatuses)) {
        $itemLayer = 0
        if ([int]::TryParse([string](Get-JsonProp $item 'Layer'), [ref]$itemLayer)) {
            $statusByLayer[$itemLayer] = $item
        }
    }

    foreach ($layer in @($script:OnAir.Keys)) {
        $status = if ($statusByLayer.ContainsKey([int]$layer)) { $statusByLayer[[int]$layer] }
        else {
            Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
                -AirChannelNumber $config.AirChannelNumber -Layer ([int]$layer) -TimeoutSec $TimeoutSec
        }
        $record = $script:OnAir[$layer]
        $decision = Resolve-BridgeCinegyLayerState -Layer ([int]$layer) -TrackedRecord $record -Status $status
        if ($decision.Action -eq 'failed') {
            $failed.Add([int]$layer)
            Write-BridgeLog "Could not verify GFX layer $layer during $Reason sync: $($status.Error)" "WARN"
            # Keep the record: an unavailable engine is not the same as a hidden graphic.
            continue
        }

        $checked.Add([int]$layer)
        if ($decision.Action -eq 'update') {
            $script:OnAir[$layer] = $decision.Record
            $script:OnAirDirty = $true
        }
        elseif ($decision.Action -eq 'remove') {
            # Genuinely hidden (IsEmpty) or replaced off air: drop from the
            # on-air record so onair.json reflects what is live now.
            $changes.Add($decision.Change)
            $script:OnAir.Remove([int]$layer)
            $recordSource = [string](Get-JsonProp $record 'Source')
            if ([string]::IsNullOrWhiteSpace($recordSource)) { $recordSource = 'bridge' }
            Write-BridgeLog "Cinegy state sync ($Reason) removed on-air record for layer $layer after Cinegy confirmed hidden; template '$([string](Get-JsonProp $record 'Key'))', source $recordSource, user $([long](Get-JsonProp $record 'UserId'))" "INFO"
            # A stale timer must not hide a different scene that an external
            # controller may put on the same layer later.
            for ($i = $script:AutoHideQueue.Count - 1; $i -ge 0; $i--) {
                if ([int]$script:AutoHideQueue[$i].Layer -eq [int]$layer) {
                    $script:AutoHideQueue.RemoveAt($i)
                }
            }
            $removed.Add([int]$layer)
        }
    }

    if ($DiscoverExternal) {
        foreach ($item in @($LayerStatuses)) {
            $layer = 0
            if (-not [int]::TryParse([string](Get-JsonProp $item 'Layer'), [ref]$layer)) { continue }
            if ($script:OnAir.ContainsKey($layer)) { continue }
            $decision = Resolve-BridgeCinegyLayerState -Layer $layer -Status $item -DiscoverExternal
            if ($decision.Action -eq 'failed') {
                if (-not $failed.Contains($layer)) { $failed.Add($layer) }
                Write-BridgeLog "Could not discover GFX layer $layer during $Reason comparison: $([string](Get-JsonProp $item 'Error'))" "WARN"
                continue
            }
            if ($decision.Action -ne 'add') { continue }
            $script:OnAir[$layer] = $decision.Record
            $added.Add($layer)
            $script:OnAirDirty = $true
            Write-BridgeLog "Cinegy state comparison ($Reason) discovered external on-air scene '$([string]$decision.Record.Key)' on layer $layer; added to onair.json for operator hide/exit" "INFO"
        }
    }

    if ($added.Count -gt 0 -or $removed.Count -gt 0 -or $script:OnAirDirty) {
        Save-OnAirState
        $script:OnAirDirty = $false
        if ($removed.Count -gt 0) {
            Write-BridgeLog "Cinegy state sync ($Reason) removed stale layer record(s): $($removed -join ', ')"
        }
    }

    $suppliedCount = @($LayerStatuses).Count
    if ($failed.Count -eq 0 -and ($checked.Count -gt 0 -or $suppliedCount -gt 0)) {
        $script:RuntimeState.Monitoring.LastCinegyStateSuccess = Get-Date
    }

    return [pscustomobject]@{
        Checked = $checked.ToArray()
        Added   = $added.ToArray()
        Removed = $removed.ToArray()
        Failed  = $failed.ToArray()
        Changes = $changes.ToArray()
        LastSuccessfulAt = if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }
    }
}

function Initialize-CinegyOnAirState {
    <# Startup is the highest-risk moment for stale state: read every configured
       GFX layer before accepting operator commands, discover scenes started in
       Cinegy, and preserve any local record whose layer cannot be verified. #>
    $layerStatuses = @(Get-CinegyLayerDashboard)
    $sync = Update-OnAirStateFromCinegy -Reason 'startup' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal
    if ($sync.Failed.Count -gt 0) {
        Write-BridgeLog "Startup Cinegy comparison uncertain; preserved on-air record(s) for unverified layer(s): $($sync.Failed -join ', ')" "WARN"
    }
    else {
        Write-BridgeLog "Startup Cinegy comparison complete (added: $(@($sync.Added).Count); removed: $(@($sync.Removed).Count); checked: $(@($layerStatuses).Count))" "INFO"
    }
    return $sync
}

function Get-CinegyStateFreshness {
    param(
        [AllowNull()][object]$LastSuccessfulAt,
        [int]$FailedCount = 0,
        [datetime]$Now = (Get-Date),
        [int]$StaleAfterSeconds = 45
    )
    if ($FailedCount -gt 0) {
        return [pscustomobject]@{ State = 'unavailable'; Label = '🔴 غير متاح'; AgeSeconds = $null }
    }
    if ($null -eq $LastSuccessfulAt -or [string]::IsNullOrWhiteSpace([string]$LastSuccessfulAt)) {
        return [pscustomobject]@{ State = 'unknown'; Label = '⚪ غير معروف'; AgeSeconds = $null }
    }
    $ageSeconds = [math]::Max(0, [math]::Floor(($Now - ([datetime]$LastSuccessfulAt)).TotalSeconds))
    if ($ageSeconds -gt [math]::Max(1, $StaleAfterSeconds)) {
        return [pscustomobject]@{ State = 'stale'; Label = "🟠 متأخر منذ $ageSeconds ثانية"; AgeSeconds = $ageSeconds }
    }
    return [pscustomobject]@{ State = 'connected'; Label = '🟢 متصل'; AgeSeconds = $ageSeconds }
}

function Format-ExternalCinegyChangeAlert {
    param([Parameter(Mandatory)][object[]]$Changes)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('⚠️ تغيير خارجي في Cinegy')
    $lines.Add("خادم Air: $($config.AirServerAddress) | القناة: $($config.AirChannelNumber)")
    foreach ($change in @($Changes)) {
        $replaced = -not [string]::IsNullOrWhiteSpace([string]$change.ActualActiveId)
        $state = if ($replaced) { 'استُبدل خارجيًا' } else { 'أُخفي' }
        $lines.Add('')
        $lines.Add("$(Get-LayerDisplayName -Layer ([int]$change.Layer)): $state")
        $lines.Add("القالب الذي كان يعرضه البوت: $($change.TemplateKey)")
        $lines.Add("المشغّل: $($change.ShowUserId) | بدأ: $($change.ShownAt)")
        $lines.Add("المعرّف السابق: $($change.ExpectedActiveId)")
        if ($replaced) {
            $name = if ([string]::IsNullOrWhiteSpace([string]$change.ActualActiveName)) { 'عنصر غير مسمّى' } else { $change.ActualActiveName }
            $lines.Add("العنصر الحالي: $name | المعرّف: $($change.ActualActiveId)")
        }
        if ($change.OutputState) { $lines.Add("حالة الخرج: $($change.OutputState)") }
        $source = if ($change.ClientConnected -and -not [string]::IsNullOrWhiteSpace([string]$change.ClientIdentity)) { "عميل Cinegy: $($change.ClientIdentity)" } else { 'مصدر خارجي غير معرّف' }
        $lines.Add("المصدر: $source")
    }
    $lines.Add('تم تحديث حالة البوت وإلغاء أي مؤقت مرتبط.')
    return ($lines -join "`n")
}

function Import-UserFavorites {
    if (-not (Test-Path -LiteralPath $script:userFavoritesFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:userFavoritesFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { $script:UserFavorites[$prop.Name] = @($prop.Value | ForEach-Object { [string]$_ }) }
    }
    catch { Write-BridgeLog "Could not read favorites.json: $($_.Exception.Message)" 'WARN' }
}

function Save-UserFavorites {
    try {
        $temporary = "$($script:userFavoritesFile).tmp"
        $script:UserFavorites | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:userFavoritesFile -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write favorites.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Set-UserFavorite {
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$TemplateKey, [Parameter(Mandatory)][bool]$Enabled)
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($TemplateKey)) { return $false }
    $id = [string]$UserId
    $current = if ($script:UserFavorites.ContainsKey($id)) { @($script:UserFavorites[$id]) } else { @() }
    if ($Enabled) { if ($current -notcontains $TemplateKey) { $current += $TemplateKey } }
    else { $current = @($current | Where-Object { $_ -ne $TemplateKey }) }
    $script:UserFavorites[$id] = $current
    return Save-UserFavorites
}

function Import-UserAliases {
    if (-not (Test-Path -LiteralPath $script:userAliasesFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:userAliasesFile -Raw | ConvertFrom-Json
        foreach ($prop in $raw.PSObject.Properties) { $script:UserAliases[$prop.Name] = [string]$prop.Value }
    }
    catch { Write-BridgeLog "Could not read user-aliases.json: $($_.Exception.Message)" 'WARN' }
}

function Save-UserAliases {
    try {
        $temporary = "$($script:userAliasesFile).tmp"
        $script:UserAliases | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:userAliasesFile -Force -ErrorAction Stop
        return $true
    }
    catch { Write-BridgeLog "Could not write user-aliases.json: $($_.Exception.Message)" 'WARN'; return $false }
}

function Set-UserAlias {
    param([Parameter(Mandatory)][long]$TargetUserId, [AllowEmptyString()][string]$Alias = '')
    if ($TargetUserId -le 0) { return $false }
    $id = [string]$TargetUserId; $clean = $Alias.Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { $script:UserAliases.Remove($id) }
    else { $script:UserAliases[$id] = $clean }
    return Save-UserAliases
}

function Get-UserDisplayName {
    param([Parameter(Mandatory)][long]$UserId)
    $id = [string]$UserId
    if ($script:UserAliases.ContainsKey($id) -and -not [string]::IsNullOrWhiteSpace([string]$script:UserAliases[$id])) { return [string]$script:UserAliases[$id] }
    return $id
}

function Get-FavoriteTemplateKeys {
    param([long]$UserId = 0)
    $count = Get-SettingInt 'FavoritesCount' 0
    if ($count -le 0) { return @() }
    $store = Get-TemplateStore
    $id = [string]$UserId
    if ($UserId -gt 0 -and $script:UserFavorites.ContainsKey($id)) {
        return @($script:UserFavorites[$id] | Where-Object { $store.Map.ContainsKey($_) } | Select-Object -First $count)
    }
    return @(
        $script:UsageCounts.GetEnumerator() |
        Where-Object { $store.Map.ContainsKey($_.Key) } |
        Sort-Object -Property Value -Descending |
        Select-Object -First $count |
        ForEach-Object { $_.Key }
    )
}

# ============================================================================
#  Runtime state
# ============================================================================

# ChatId -> @{ Mode; StartedAt; ... }. Modes: show_fields, update_field,
# stream_url, setting_value. Entries expire (PendingStateTimeoutMinutes) so an
# abandoned flow can never swallow an unrelated message days later and put it
# on air.
$script:PendingState = @{}

# Layer -> @{ ChatId; UserId; Key; StartedAt }. A lock exists only while an
# operator is preparing a SHOW flow; it prevents two drafts racing toward the
# same GFX layer.
$script:LayerLocks = @{}

# UserId|field-name -> newest-first string array. Scoping history by user keeps
# one operator's editorial text out of another operator's quick choices.
$script:RecentFieldValues = @{}

$script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()

function Get-SystemClockStatus {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    $zone = [System.TimeZoneInfo]::Local
    $reasonable = $Now.Year -ge 2024 -and $Now.Year -le 2100 -and -not [string]::IsNullOrWhiteSpace($zone.Id)
    return [pscustomobject]@{
        Success = $reasonable; Now = $Now; TimeZoneId = $zone.Id
        Offset = $Now.Offset; Error = if ($reasonable) { '' } else { 'System clock or timezone is not reasonable.' }
    }
}

function ConvertFrom-OperatorScheduleTime {
    param([Parameter(Mandatory)][string]$Text, [datetimeoffset]$Now = [datetimeoffset]::Now)
    $clock = Get-SystemClockStatus -Now $Now
    if (-not $clock.Success) { return $clock }
    $localTime = [datetime]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [datetime]::TryParseExact($Text.Trim(), 'yyyy-MM-dd HH:mm', $culture, [System.Globalization.DateTimeStyles]::None, [ref]$localTime)) {
        return [pscustomobject]@{ Success = $false; Error = 'استخدم الصيغة YYYY-MM-DD HH:mm'; TimeZoneId = $clock.TimeZoneId }
    }
    $localTime = [datetime]::SpecifyKind($localTime, [System.DateTimeKind]::Unspecified)
    $zone = [System.TimeZoneInfo]::Local
    if ($zone.IsInvalidTime($localTime) -or $zone.IsAmbiguousTime($localTime)) {
        return [pscustomobject]@{ Success = $false; Error = 'الوقت غير واضح بسبب تغيير التوقيت المحلي؛ اختر وقتًا آخر.'; TimeZoneId = $zone.Id }
    }
    $scheduledAt = [datetimeoffset]::new($localTime, $zone.GetUtcOffset($localTime))
    if ($scheduledAt -le $Now) {
        return [pscustomobject]@{ Success = $false; Error = 'يجب أن يكون الموعد في المستقبل.'; TimeZoneId = $zone.Id }
    }
    return [pscustomobject]@{ Success = $true; ScheduledAt = $scheduledAt; TimeZoneId = $zone.Id; Error = '' }
}

function New-ScheduledShowEvent {
    param(
        [Parameter(Mandatory)][string]$TemplateKey,
        [int]$Layer = 0,
        [hashtable]$Values = @{},
        [Parameter(Mandatory)][datetimeoffset]$ScheduledAt,
        [Parameter(Mandatory)][ValidateSet('once', 'daily', 'weekly')][string]$Recurrence,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId,
        [string]$RecurrenceUntil = ''
    )
    return @{
        Id = [guid]::NewGuid().ToString(); TemplateKey = $TemplateKey; Layer = $Layer; Values = $Values
        ScheduledAt = $ScheduledAt.ToString('o'); TimeZoneId = [System.TimeZoneInfo]::Local.Id
        Recurrence = $Recurrence; Status = 'pending'; ChatId = $ChatId; UserId = $UserId
        CreatedAt = [datetimeoffset]::Now.ToString('o'); ExecutionKey = ''
        CompletedExecutionKey = ''; StartedAt = ''; CompletedAt = ''; LastResult = ''
        AttemptCount = 0; NextAttemptAt = ''; RecurrenceUntil = $RecurrenceUntil
        NotificationExecutionKey = ''
    }
}

function Save-ScheduleEvents {
    try {
        $json = ConvertTo-Json -InputObject @($script:ScheduleEvents.ToArray()) -Depth 8
        if (-not (Write-ValidatedJsonState -Path $script:scheduleFile -Json $json)) { throw 'validated state write failed' }
        return $true
    }
    catch {
        Write-BridgeLog "Could not write schedule.json: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Write-ScheduleExecutionEntry {
    param(
        [Parameter(Mandatory)][hashtable]$ScheduleEntry,
        [Parameter(Mandatory)][ValidateSet('success', 'failed')][string]$Result,
        [Parameter(Mandatory)][long]$DurationMs,
        [int]$Attempt = 1,
        [string]$ErrorText = ''
    )
    try {
        $record = [ordered]@{
            Timestamp    = [datetimeoffset]::Now.ToString('o')
            EventId      = [string]$ScheduleEntry.Id
            ExecutionKey = [string]$ScheduleEntry.ExecutionKey
            TemplateKey  = [string]$ScheduleEntry.TemplateKey
            Layer        = [int](Get-JsonProp $ScheduleEntry 'Layer')
            ScheduledAt  = [string]$ScheduleEntry.ScheduledAt
            Attempt      = $Attempt
            Result       = $Result
            DurationMs   = $DurationMs
            Error        = if ($ErrorText) { Protect-SensitiveText $ErrorText } else { '' }
        }
        Add-Content -LiteralPath $script:scheduleExecutionFile -Value ($record | ConvertTo-Json -Compress -Depth 4) -Encoding utf8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-BridgeLog "Could not append schedule execution log: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Import-ScheduleEvents {
    try {
        $read = Read-ValidatedJsonState -Path $script:scheduleFile -AsHashtable
        if (-not $read) { return }
        $raw = $read.Data
        $script:ScheduleEvents = [System.Collections.Generic.List[hashtable]]::new()
        $recovered = $false
        foreach ($scheduleEntry in @($raw)) {
            if (-not $scheduleEntry -or -not $scheduleEntry.ContainsKey('Id')) { continue }
            if ([string]$scheduleEntry.Status -eq 'running') {
                # The command may already have reached Cinegy before the crash.
                # Never replay that occurrence automatically.
                $scheduleEntry.Status = 'interrupted'
                $scheduleEntry.LastResult = 'Bridge restarted while occurrence was running; not replayed.'
                $recovered = $true
            }
            $script:ScheduleEvents.Add($scheduleEntry)
        }
        if ($recovered) { Save-ScheduleEvents | Out-Null }
    }
    catch { Write-BridgeLog "Could not read schedule.json: $($_.Exception.Message)" "ERROR" }
}

function Add-ScheduledShowEvent {
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)
    $script:ScheduleEvents.Add($ScheduleEntry)
    if (Save-ScheduleEvents) { return $true }
    $script:ScheduleEvents.Remove($ScheduleEntry) | Out-Null
    return $false
}

function Update-ScheduleQueue {
    param([datetimeoffset]$Now = [datetimeoffset]::Now)
    if (Get-Setting 'MaintenanceMode') { return }
    if (Get-Setting 'SchedulePaused') { return }
    foreach ($scheduleEntry in @($script:ScheduleEvents)) {
        if ([string]$scheduleEntry.Status -ne 'pending') { continue }
        $scheduledAt = [datetimeoffset]$scheduleEntry.ScheduledAt
        $occurrenceKey = "$($scheduleEntry.Id)|$($scheduledAt.ToString('o'))"
        $notifyMinutes = Get-SettingInt 'SchedulePreNotifyMinutes' 0
        $minutesUntil = ($scheduledAt - $Now).TotalMinutes
        if ($notifyMinutes -gt 0 -and $minutesUntil -gt 0 -and $minutesUntil -le $notifyMinutes -and
            [string](Get-JsonProp $scheduleEntry 'NotificationExecutionKey') -ne $occurrenceKey) {
            $roundedMinutes = [math]::Max(1, [math]::Ceiling($minutesUntil))
            Send-TelegramMessage -ChatId ([long]$scheduleEntry.ChatId) -Text "⏰ الحدث المجدول '$($scheduleEntry.TemplateKey)' سيُعرض بعد نحو $roundedMinutes دقائق.`n$(Format-ScheduleEvent -ScheduleEntry $scheduleEntry)"
            $scheduleEntry.NotificationExecutionKey = $occurrenceKey
            Save-ScheduleEvents | Out-Null
        }
        $dueState=Get-BridgeScheduleDueState -ScheduleEntry $scheduleEntry -Now $Now
        if(-not $dueState.IsDue){continue}
        $executionKey=$dueState.ExecutionKey

        $scheduleEntry.Status = 'running'; $scheduleEntry.ExecutionKey = $executionKey
        $scheduleEntry.StartedAt = $Now.ToString('o')
        if (-not (Save-ScheduleEvents)) { $scheduleEntry.Status = 'pending'; continue }

        $priorAttempts = 0
        [int]::TryParse([string](Get-JsonProp $scheduleEntry 'AttemptCount'), [ref]$priorAttempts) | Out-Null
        $executionTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ShowTemplateResult -Key ([string]$scheduleEntry.TemplateKey) -Variables $scheduleEntry.Values -ChatId ([long]$scheduleEntry.ChatId) -UserId ([long]$scheduleEntry.UserId)
        $executionTimer.Stop()
        $executionResult = if ($result -and $result.Success) { 'success' } else { 'failed' }
        $executionError = if ($executionResult -eq 'failed') { if ($result) { [string]$result.Error } else { 'SHOW returned no result.' } } else { '' }
        Write-ScheduleExecutionEntry -ScheduleEntry $scheduleEntry -Result $executionResult -DurationMs $executionTimer.ElapsedMilliseconds -Attempt ($priorAttempts + 1) -ErrorText $executionError | Out-Null
        if ($result -and $result.Success) {
            $scheduleEntry.CompletedExecutionKey = $executionKey
            $scheduleEntry.CompletedAt = [datetimeoffset]::Now.ToString('o')
            $scheduleEntry.LastResult = 'success'
            $scheduleEntry.NextAttemptAt = ''
            if ([string]$scheduleEntry.Recurrence -eq 'once') {
                $scheduleEntry.Status = 'completed'
            }
            else {
                $days = if ([string]$scheduleEntry.Recurrence -eq 'daily') { 1 } else { 7 }
                do { $scheduledAt = Get-NextLocalOccurrence -Occurrence $scheduledAt -Days $days -TimeZoneId ([string]$scheduleEntry.TimeZoneId) } while ($scheduledAt -le $Now)
                $scheduleEntry.ScheduledAt = $scheduledAt.ToString('o')
                $untilText = [string](Get-JsonProp $scheduleEntry 'RecurrenceUntil')
                $pastEnd = $false
                if (-not [string]::IsNullOrWhiteSpace($untilText)) {
                    $untilDate = [datetime]::MinValue
                    if ([datetime]::TryParse($untilText, [ref]$untilDate)) { $pastEnd = $scheduledAt.Date -gt $untilDate.Date }
                }
                $scheduleEntry.Status = if ($pastEnd) { 'completed' } else { 'pending' }
                $scheduleEntry.ExecutionKey = ''; $scheduleEntry.AttemptCount = 0; $scheduleEntry.NotificationExecutionKey = ''
            }
        }
        else {
            $scheduleEntry.LastResult = if ($result) { [string]$result.Error } else { 'SHOW returned no result.' }
            $maxRetries = Get-SettingInt 'ScheduleMaxRetries' 0
            $priorAttemptCount=0
            [int]::TryParse([string](Get-JsonProp $scheduleEntry 'AttemptCount'),[ref]$priorAttemptCount)|Out-Null
            $retry=Get-BridgeScheduleRetryDecision -PriorAttemptCount $priorAttemptCount -MaxRetries $maxRetries `
                -BaseSeconds (Get-SettingInt 'ScheduleRetryDelaySeconds' 30) -Factor (Get-SettingInt 'ScheduleRetryBackoffFactor' 2) `
                -MaxDelaySeconds (Get-SettingInt 'ScheduleRetryMaxDelaySeconds' 300) -Now $Now
            $scheduleEntry.AttemptCount=$retry.AttemptCount
            if ($retry.ShouldRetry) {
                $scheduleEntry.Status = 'pending'; $scheduleEntry.ExecutionKey = ''
                $scheduleEntry.NextAttemptAt = $retry.NextAttemptAt.ToString('o')
                Write-BridgeLog "Scheduled event $($scheduleEntry.Id) SHOW failed; retry $($retry.AttemptCount)/$maxRetries at $($scheduleEntry.NextAttemptAt): $($scheduleEntry.LastResult)" 'WARN'
            }
            else {
                $scheduleEntry.Status = 'failed'; $scheduleEntry.NextAttemptAt = ''
            }
        }
        Save-ScheduleEvents | Out-Null
    }
}

function Get-NextLocalOccurrence {
    param([Parameter(Mandatory)][datetimeoffset]$Occurrence, [Parameter(Mandatory)][int]$Days, [Parameter(Mandatory)][string]$TimeZoneId)
    try { $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId) }
    catch { $zone = [System.TimeZoneInfo]::Local }
    $local = [System.TimeZoneInfo]::ConvertTime($Occurrence, $zone).DateTime.AddDays($Days)
    $local = [datetime]::SpecifyKind($local, [System.DateTimeKind]::Unspecified)
    # A recurring wall-clock time inside a spring-forward gap is moved to the
    # first valid minute. For a repeated autumn hour choose the standard-time
    # offset so the occurrence is deterministic and never fires twice.
    while ($zone.IsInvalidTime($local)) { $local = $local.AddMinutes(1) }
    $offset = if ($zone.IsAmbiguousTime($local)) {
        @($zone.GetAmbiguousTimeOffsets($local) | Sort-Object TotalMinutes | Select-Object -First 1)[0]
    }
    else { $zone.GetUtcOffset($local) }
    return [datetimeoffset]::new($local, $offset)
}

function Get-UpcomingScheduleEvents {
    return @($script:ScheduleEvents | Where-Object { [string]$_.Status -eq 'pending' } | Sort-Object { [datetimeoffset]$_.ScheduledAt })
}

function Stop-ScheduledShowEvent {
    param([Parameter(Mandatory)][string]$Id)
    $scheduleEntry = @($script:ScheduleEvents | Where-Object { [string]$_.Id -eq $Id }) | Select-Object -First 1
    if (-not $scheduleEntry -or [string]$scheduleEntry.Status -ne 'pending') { return $false }
    $scheduleEntry.Status = 'cancelled'; $scheduleEntry.LastResult = 'cancelled by operator'
    return (Save-ScheduleEvents)
}

function Format-ScheduleEvent {
    param([Parameter(Mandatory)][hashtable]$ScheduleEntry)
    $recurrence = switch ([string]$ScheduleEntry.Recurrence) { 'daily' { 'يومي' }; 'weekly' { 'أسبوعي' }; default { 'مرة واحدة' } }
    $at = [datetimeoffset]$ScheduleEntry.ScheduledAt
    $zone = [string](Get-JsonProp $ScheduleEntry 'TimeZoneId')
    if ([string]::IsNullOrWhiteSpace($zone)) { $zone = [System.TimeZoneInfo]::Local.Id }
    return "$($ScheduleEntry.TemplateKey) — $($at.ToString('yyyy-MM-dd HH:mm zzz')) — $zone — $recurrence"
}

function Start-ScheduleMutationFlow {
    param(
        [Parameter(Mandatory)][ValidateSet('copy', 'edit')][string]$Action,
        [Parameter(Mandatory)][string]$EventId,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId
    )
    $entry = @($script:ScheduleEvents | Where-Object { [string]$_.Id -eq $EventId -and [string]$_.Status -eq 'pending' }) | Select-Object -First 1
    if (-not $entry) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الحدث لم يعد متاحًا للنسخ أو التعديل.' -ReplyMarkup (Get-ScheduleMenuKeyboard)
        return
    }
    if ([long]$entry.UserId -ne $UserId -and -not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'يمكنك تعديل أحداثك فقط.' -ReplyMarkup (Get-ScheduleMenuKeyboard)
        return
    }
    $values = @{}
    foreach ($name in $entry.Values.Keys) { $values[[string]$name] = [string]$entry.Values[$name] }
    $state = @{
        Mode = 'schedule_time'; MutationAction = $Action; OriginalEventId = $EventId
        TemplateKey = [string]$entry.TemplateKey; Layer = [int](Get-JsonProp $entry 'Layer')
        Fields = @($values.Keys); Values = $values; Recurrence = [string]$entry.Recurrence
        TimeZoneId = [string]$entry.TimeZoneId; RecurrenceUntil = [string](Get-JsonProp $entry 'RecurrenceUntil'); UserId = $UserId
    }
    Set-PendingState -ChatId $ChatId -State $state
    $verb = if ($Action -eq 'copy') { 'نسخ الحدث إلى موعد جديد' } else { 'تعديل موعد الحدث' }
    Send-TelegramMessage -ChatId $ChatId -Text "📅 $verb`nالموعد الحالي: $(([datetimeoffset]$entry.ScheduledAt).ToString('yyyy-MM-dd HH:mm zzz'))`nالمنطقة: $($entry.TimeZoneId)`nأرسل الموعد الجديد بصيغة YYYY-MM-DD HH:mm" -ReplyMarkup (Get-CancelKeyboard)
}

function Start-ScheduleShowFlow {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    Clear-PendingState -ChatId $ChatId
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { return }
    $state = @{
        Mode = 'schedule_fields'; TemplateIndex = $TemplateIndex; TemplateKey = [string]$template.Key; Layer = [int]$template.Layer
        Fields = @($template.Fields); Labels = @($template.FieldLabels); Limits = @($template.FieldLimits)
        Required = @(Get-JsonProp $template 'FieldRequired' | Where-Object { $null -ne $_ })
        Values = @{}; Index = 0; UserId = $UserId
    }
    if ($state.Fields.Count -eq 0) {
        $state.Mode = 'schedule_time'; Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل موعد العرض بصيغة YYYY-MM-DD HH:mm`nالوقت الحالي: $([datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm zzz'))`nالمنطقة: $([System.TimeZoneInfo]::Local.Id)" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text "📅 قيمة الحقل (1/$($state.Fields.Count)):`n$($state.Fields[0])" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-ScheduleText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    if ($state.Mode -eq 'schedule_end_date') {
        $endDate = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($Value.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$endDate)) {
            Send-TelegramMessage -ChatId $ChatId -Text '❌ أرسل تاريخ الانتهاء بصيغة YYYY-MM-DD.' -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        if ($endDate.Date -lt ([datetimeoffset]$state.ScheduledAt).Date) {
            Send-TelegramMessage -ChatId $ChatId -Text '❌ تاريخ الانتهاء يجب ألا يسبق أول موعد.' -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.RecurrenceUntil = $endDate.ToString('yyyy-MM-dd')
        Show-ScheduleReview -ChatId $ChatId -State $state
        return
    }
    if ($state.Mode -eq 'schedule_fields') {
        $required = $state.Index -lt @($state.Required).Count -and [bool]$state.Required[$state.Index]
        if ($required -and [string]::IsNullOrWhiteSpace($Value)) {
            Send-TelegramMessage -ChatId $ChatId -Text "هذا الحقل إلزامي ولا يمكن تركه فارغًا." -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $limit = if ($state.Index -lt @($state.Limits).Count) { [int]$state.Limits[$state.Index] } else { 0 }
        if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-CancelKeyboard))) { return }
        $state.Values[[string]$state.Fields[$state.Index]] = $Value
        $state.Index = [int]$state.Index + 1
        if ($state.Index -lt $state.Fields.Count) {
            Set-PendingState -ChatId $ChatId -State $state
            Send-TelegramMessage -ChatId $ChatId -Text "📅 قيمة الحقل ($($state.Index + 1)/$($state.Fields.Count)):`n$($state.Fields[$state.Index])" -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.Mode = 'schedule_time'; Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل موعد العرض بصيغة YYYY-MM-DD HH:mm`nالوقت الحالي: $([datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm zzz'))`nالمنطقة: $([System.TimeZoneInfo]::Local.Id)" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    if ($state.Mode -eq 'schedule_time') {
        $parsed = ConvertFrom-OperatorScheduleTime -Text $Value
        if (-not $parsed.Success) {
            Send-TelegramMessage -ChatId $ChatId -Text "❌ $($parsed.Error)`nأرسل الموعد بصيغة YYYY-MM-DD HH:mm" -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.ScheduledAt = $parsed.ScheduledAt.ToString('o'); $state.TimeZoneId = $parsed.TimeZoneId
        if ($state.ContainsKey('MutationAction')) {
            Show-ScheduleReview -ChatId $ChatId -State $state
            return
        }
        $state.Mode = 'schedule_recurrence'; Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "فُهم الموعد: $($parsed.ScheduledAt.ToString('yyyy-MM-dd HH:mm zzz'))`nالمنطقة: $($parsed.TimeZoneId)`nاختر التكرار:" -ReplyMarkup (Get-ScheduleRecurrenceKeyboard)
    }
}

function Show-ScheduleReview {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    $recurrence = switch ([string]$State.Recurrence) { 'daily' { 'يومي' }; 'weekly' { 'أسبوعي' }; default { 'مرة واحدة' } }
    $reviewTitle = if ($State.ContainsKey('MutationAction')) {
        if ([string]$State.MutationAction -eq 'copy') { '🔎 مراجعة نسخة الحدث' } else { '🔎 مراجعة تعديل موعد الحدث' }
    } else { '🔎 مراجعة الجدولة' }
    $lines = @(
        $reviewTitle, "القالب: $($State.TemplateKey)",
        "الموعد: $(([datetimeoffset]$State.ScheduledAt).ToString('yyyy-MM-dd HH:mm zzz'))", "المنطقة: $($State.TimeZoneId)", "التكرار: $recurrence"
    )
    if ([string]$State.Recurrence -ne 'once') {
        $until = [string](Get-JsonProp $State 'RecurrenceUntil')
        $lines += "نهاية التكرار: $(if ($until) { $until } else { 'بدون تاريخ انتهاء' })"
    }
    foreach ($field in @($State.Fields)) { $lines += "• $field`: $($State.Values[[string]$field])" }
    $conflicts = @(Get-ScheduleLayerConflicts -Layer ([int]$State.Layer) -ScheduledAt ([datetimeoffset]$State.ScheduledAt) `
        -WindowMinutes (Get-SettingInt 'ScheduleConflictWindowMinutes' 2))
    if ($conflicts.Count -gt 0) {
        $lines += ''
        $lines += "⚠️ تعارض محتمل على الطبقة $($State.Layer):"
        foreach ($conflict in $conflicts) { $lines += "• $(Format-ScheduleEvent -ScheduleEntry $conflict)" }
    }
    $lines += ''; $lines += 'لن يُحفظ الحدث حتى تضغط تأكيد الجدولة.'
    $State.Mode = 'schedule_review'; Set-PendingState -ChatId $ChatId -State $State
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-ScheduleReviewKeyboard -State $State)
}

function Confirm-ScheduledShow {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $UserId) { return }
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    $scheduleEntry = $null
    $saved = $false
    if ($state.ContainsKey('MutationAction') -and [string]$state.MutationAction -eq 'edit') {
        $scheduleEntry = @($script:ScheduleEvents | Where-Object { [string]$_.Id -eq [string]$state.OriginalEventId -and [string]$_.Status -eq 'pending' }) | Select-Object -First 1
        if ($scheduleEntry) {
            $previous = @{
                ScheduledAt = [string]$scheduleEntry.ScheduledAt; TimeZoneId = [string]$scheduleEntry.TimeZoneId
                ExecutionKey = [string]$scheduleEntry.ExecutionKey; CompletedExecutionKey = [string]$scheduleEntry.CompletedExecutionKey
                NextAttemptAt = [string]$scheduleEntry.NextAttemptAt; AttemptCount = [int]$scheduleEntry.AttemptCount
                RecurrenceUntil = [string](Get-JsonProp $scheduleEntry 'RecurrenceUntil')
            }
            $scheduleEntry.ScheduledAt = [string]$state.ScheduledAt; $scheduleEntry.TimeZoneId = [string]$state.TimeZoneId
            $scheduleEntry.RecurrenceUntil = [string](Get-JsonProp $state 'RecurrenceUntil')
            $scheduleEntry.ExecutionKey = ''; $scheduleEntry.CompletedExecutionKey = ''; $scheduleEntry.NextAttemptAt = ''; $scheduleEntry.AttemptCount = 0
            $saved = Save-ScheduleEvents
            if (-not $saved) {
                foreach ($name in $previous.Keys) { $scheduleEntry[$name] = $previous[$name] }
            }
        }
    }
    else {
        $scheduleEntry = New-ScheduledShowEvent -TemplateKey ([string]$state.TemplateKey) -Layer ([int]$state.Layer) -Values $state.Values -ScheduledAt ([datetimeoffset]$state.ScheduledAt) -Recurrence ([string]$state.Recurrence) -ChatId $ChatId -UserId $UserId -RecurrenceUntil ([string](Get-JsonProp $state 'RecurrenceUntil'))
        $saved = Add-ScheduledShowEvent -ScheduleEntry $scheduleEntry
    }
    Clear-PendingState -ChatId $ChatId
    if ($saved) {
        $auditAction = if ($state.ContainsKey('MutationAction')) { [string]$state.MutationAction } else { 'created' }
        Add-AuditEntry "📅 schedule $auditAction $($scheduleEntry.TemplateKey) / $($scheduleEntry.Recurrence) - user $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم حفظ الجدولة.`n$(Format-ScheduleEvent -ScheduleEntry $scheduleEntry)" -ReplyMarkup (Get-ScheduleMenuKeyboard)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ ملف الجدولة، لذلك لم يُعتمد الحدث." -ReplyMarkup (Get-ScheduleMenuKeyboard)
    }
}

function Test-SensitiveFieldName {
    param([Parameter(Mandatory)][string]$FieldName)
    return ($FieldName -match '(?i)(password|passphrase|token|secret|stream[._-]?key|كلمة[ _-]?مرور|رمز[ _-]?سري)')
}

function Get-RecentFieldKey {
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$FieldName)
    return "$UserId|$FieldName"
}

function Save-RecentFieldValues {
    try {
        $temporary = "$script:recentValuesFile.tmp"
        $json = ConvertTo-Json -InputObject $script:RecentFieldValues -Depth 4
        Set-Content -LiteralPath $temporary -Value $json -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:recentValuesFile -Force -ErrorAction Stop
    }
    catch { Write-BridgeLog "Could not write recent-values.json: $($_.Exception.Message)" "WARN" }
}

function Import-RecentFieldValues {
    if (-not (Test-Path -LiteralPath $script:recentValuesFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:recentValuesFile -Raw | ConvertFrom-Json -AsHashtable
        $script:RecentFieldValues.Clear()
        foreach ($key in $raw.Keys) {
            $script:RecentFieldValues[[string]$key] = @($raw[$key] | ForEach-Object { [string]$_ })
        }
    }
    catch { Write-BridgeLog "Could not read recent-values.json: $($_.Exception.Message)" "WARN" }
}

function Get-RecentFieldValues {
    param([Parameter(Mandatory)][long]$UserId, [Parameter(Mandatory)][string]$FieldName)
    $key = Get-RecentFieldKey -UserId $UserId -FieldName $FieldName
    if (-not $script:RecentFieldValues.ContainsKey($key)) { return @() }
    return @($script:RecentFieldValues[$key])
}

function Add-RecentFieldValue {
    param(
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][string]$FieldName,
        [AllowEmptyString()][string]$Value,
        [switch]$Sensitive
    )
    if ($Sensitive -or (Test-SensitiveFieldName -FieldName $FieldName) -or [string]::IsNullOrWhiteSpace($Value)) { return }
    $limit = Get-SettingInt 'RecentValuesPerField' 1
    if ($limit -le 0) { return }
    $key = Get-RecentFieldKey -UserId $UserId -FieldName $FieldName
    $values = @($Value) + @(Get-RecentFieldValues -UserId $UserId -FieldName $FieldName | Where-Object { $_ -cne $Value })
    $script:RecentFieldValues[$key] = @($values | Select-Object -First $limit)
    Save-RecentFieldValues
}

function Save-DraftStates {
    <# Only SHOW preparation is recoverable. Short-lived prompts such as raw
       settings or stream URLs are deliberately never written to disk. #>
    try {
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($chatId in $script:PendingState.Keys) {
            $state = $script:PendingState[$chatId]
            if ([string]$state.Mode -notin @('show_fields', 'show_review')) { continue }
            $copy = @{}
            foreach ($name in $state.Keys) { $copy[$name] = $state[$name] }
            if ($copy.StartedAt -is [datetime]) { $copy.StartedAt = $copy.StartedAt.ToString('o') }
            $entries.Add(@{ ChatId = [long]$chatId; State = $copy })
        }
        $json = ConvertTo-Json -InputObject @($entries.ToArray()) -Depth 8
        $temporary = "$script:draftsFile.tmp"
        Set-Content -LiteralPath $temporary -Value $json -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $script:draftsFile -Force -ErrorAction Stop
    }
    catch { Write-BridgeLog "Could not write drafts.json: $($_.Exception.Message)" "WARN" }
}

function Import-DraftStates {
    if (-not (Test-Path -LiteralPath $script:draftsFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $script:draftsFile -Raw | ConvertFrom-Json -AsHashtable
        $timeout = Get-SettingInt 'PendingStateTimeoutMinutes' 1
        foreach ($entry in @($raw)) {
            if (-not $entry -or -not $entry.ContainsKey('State')) { continue }
            $state = $entry.State
            if ([string]$state.Mode -notin @('show_fields', 'show_review')) { continue }
            $startedAt = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$state.StartedAt, [ref]$startedAt)) { continue }
            if (((Get-Date) - $startedAt).TotalMinutes -ge $timeout) { continue }
            if ((Get-TemplateIndex -Key ([string]$state.Key)) -lt 0) { continue }
            $chatId = [long]$entry.ChatId
            $layer = [int]$state.LockLayer
            $lock = Lock-GfxLayer -Layer $layer -ChatId $chatId -UserId ([long]$state.UserId) -Key ([string]$state.Key)
            if (-not $lock.Success) { continue }
            $state.StartedAt = $startedAt
            $script:PendingState[$chatId] = $state
        }
        if ($script:PendingState.Count -gt 0) {
            Write-BridgeLog "Restored $($script:PendingState.Count) operator draft(s) from the previous run"
        }
        Save-DraftStates
    }
    catch { Write-BridgeLog "Could not read drafts.json: $($_.Exception.Message)" "WARN" }
}

# ChatId -> @{ Name; ChatId; UserId; RequestedAt } for users awaiting approval.
$script:PendingApprovals = @{}

# ChatId -> @{ Key; Variables } - powers the 🔁 repeat button.
$script:LastShow = @{}
$script:LastSuccessfulLayerShows = @{}
$script:RollbackCandidates = @{}

# Layer -> @{ Key; At; UserId } for everything THIS bridge has put on air and
# not yet hidden. Air Pro exposes no "what is currently on screen" query, so
# this is a best-effort record of the bot's own actions - graphics triggered
# from the Air Pro UI itself will not appear here.
$script:OnAir = @{}
$script:OnAirDirty = $false   # set when the in-memory record changes so a sync flushes it

# Async ffmpeg snapshot jobs, polled by Invoke-BridgeTick.
$script:SnapshotJobs = [System.Collections.Generic.List[hashtable]]::new()
$script:LastSnapshotAt = [datetime]::MinValue
$script:LastSnapshotFile = ''
$script:LastSnapshotSweep = [datetime]::MinValue

# Auto-hide timers created by the ⏱ timed-show button.
$script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()

# Follow-up postbox writes queued just after a SHOW. Some Titler scenes ignore
# the variables embedded in the SHOW command's Op2 entirely - Air still returns
# 200 OK - while accepting the very same name/type/value on the /postbox
# endpoint. Writing the values again a moment later makes the text land either
# way. The delay gives the scene time to load before it is addressed, and the
# queue keeps that wait off the polling loop.
$script:PostShowQueue = [System.Collections.Generic.List[hashtable]]::new()

# Live relay (ffmpeg -> Telegram Video Chat RTMP). Telegram's Bot API cannot
# push continuous video to a chat; the supported route is a Group/Channel
# Video Chat's RTMP ingestion endpoint.
$script:RuntimeState = New-BridgeRuntimeState
$script:RelayState = $script:RuntimeState.Relay

$script:LastHeartbeatDate = [datetime]::MinValue.Date
$script:LastConfigSaveFailed = $false
$script:HealthHistory = @{
    Telegram = @{ LastSuccess = $null; LastError = ''; LastErrorAt = $null; FailureCount = 0; OutageStartedAt = $null; AlertSent = $false }
    Cinegy   = @{ LastSuccess = $null; LastError = ''; LastErrorAt = $null; FailureCount = 0; OutageStartedAt = $null; AlertSent = $false }
}

# ============================================================================
#  Inline keyboards
# ============================================================================
# callback_data is capped at 64 *bytes* by Telegram, and an over-long value
# makes the entire keyboard fail with BUTTON_DATA_INVALID. Template and field
# names (Arabic = 2 bytes/char) are therefore never embedded - only their
# indices into Get-TemplateStore's stable ordering.

function New-Button {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$Data)
    $maxLength = Get-SettingInt 'ButtonTextMaxLength'
    $displayText = $Text
    if ($maxLength -gt 1 -and (Get-TextElementCount -Text $Text) -gt $maxLength) {
        $info = [Globalization.StringInfo]::new($Text)
        $displayText = $info.SubstringByTextElements(0, $maxLength - 1).TrimEnd() + '…'
    }
    return @{ text = $displayText; callback_data = $Data }
}

function Get-MainMenuKeyboard {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $rows = @()
    $rows += , @( (New-Button "📋 القوالب" "menu:templates"), (New-Button "🎚 الطبقات" "menu:layers") )
    $rows += , @( (New-Button "ℹ️ الحالة" "menu:status") )
    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
        $rows += , @( (New-Button "📊 الحالة الكاملة" "menu:fullstatus") )
    }

    if (Get-Setting 'EnableFavorites') {
        # @() is mandatory, not decoration: a PowerShell function that returns
        # an empty array emits ZERO objects, so an unwrapped assignment yields
        # $null and $null.Count throws under Set-StrictMode. Same rule applies
        # to every array-returning helper called below.
        $favs = @(Get-FavoriteTemplateKeys -UserId $UserId)
        if ($favs.Count -gt 0) {
            $favRow = @()
            foreach ($key in $favs) {
                $idx = Get-TemplateIndex -Key $key
                if ($idx -ge 0) { $favRow += (New-Button "⭐ $key" "tpl:$idx") }
            }
            if ($favRow.Count -gt 0) { $rows += , $favRow }
        }
        $rows += , @( (New-Button "⭐ إدارة المفضلة" "menu:favorites") )
    }

    $rows += , @( (New-Button "🙈 اخفاء طبقة" "menu:hide"), (New-Button "🚪 خروج من المشهد" "menu:exit") )

    # One tap per live layer, so taking a wrong graphic off air is immediate
    # and the operator can see at a glance what the bridge believes is up.
    if ($script:OnAir.Count -gt 0) {
        foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
            $liveRow = @( (New-Button "🔴 إخفاء $layer · $($script:OnAir[$layer].Key)" "hide:$layer") )
            # A timer can be attached to something already live, not just at
            # the moment it is put on air.
            if (Get-Setting 'EnableTimedShow') {
                $pending = @($script:AutoHideQueue | Where-Object { [int]$_.Layer -eq [int]$layer })
                $label = if ($pending.Count -gt 0) {
                    "⏱ $([int](($pending[0].At - (Get-Date)).TotalSeconds)) ث"
                }
                else { "⏱ مؤقت" }
                $liveRow += (New-Button $label "timer:$layer")
            }
            $rows += , $liveRow
        }
    }

    $thirdRow = @()
    if (Get-Setting 'EnableHideAll') { $thirdRow += (New-Button "🚨 إخفاء الكل" "menu:hideall") }
    if ($script:LastShow.ContainsKey($ChatId)) { $thirdRow += (New-Button "🔁 تكرار مع تعديل" "menu:repeat") }
    if ($thirdRow.Count -gt 0) { $rows += , $thirdRow }

    $fourthRow = @( (New-Button "✏️ تحديث نص" "menu:update") )
    if (Get-Setting 'EnableTimedShow') { $fourthRow += (New-Button "⏱ عرض مؤقّت" "menu:timed") }
    $rows += , $fourthRow
    $rows += , @( (New-Button "📅 الجدولة" 'menu:schedule') )
    $rows += , @( (New-Button "🧾 عملياتي" 'menu:myops') )
    if (Get-Setting 'EnableNewsTickerManagement') {
        $rows += , @( (New-Button "📰 إدارة شريط الأخبار" 'menu:news') )
    }

    if (Get-Setting 'EnableSnapshot') {
        $rows += , @( (New-Button "📸 صورة من البث" "menu:snapshot"), (New-Button "❓ مساعدة" "menu:help") )
    }
    else {
        $rows += , @( (New-Button "❓ مساعدة" "menu:help") )
    }

    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
        $pendingCount = $script:PendingApprovals.Count
        $pendingLabel = if ($pendingCount -gt 0) { "👤 طلبات الوصول ($pendingCount)" } else { "👤 طلبات الوصول" }
        $rows += , @( (New-Button "⚙️ الإعدادات" "menu:settings"), (New-Button $pendingLabel "menu:pending") )
        $rows += , @( (New-Button "👥 إدارة المستخدمين" "menu:usersadmin") )
        $rows += , @( (New-Button "⚡ إدارة النصوص الجاهزة" "menu:presetsadmin") )
        $rows += , @( (New-Button "📚 القوالب والإعدادات" "menu:templatesadmin") )

        if (Get-Setting 'EnableLiveRelay') {
            $relayRunning = [bool](Get-RunningRelayProcess)
            $relayLabel = if ($relayRunning) { "⏹ إيقاف البث" } else { "▶️ بدء البث" }
            $relayData = if ($relayRunning) { "menu:stream:stop" } else { "menu:stream:start" }
            $rows += , @( (New-Button $relayLabel $relayData), (New-Button "🔗 رابط البث" "menu:stream:seturl") )
        }

        $adminRow = @( (New-Button "📜 السجل" "menu:audit"), (New-Button "🧪 التشخيص" "menu:diagnostics") )
        if (Get-Setting 'EnableRawCommand') { $adminRow += (New-Button "🛠 أمر خام" "menu:rawcmd") }
        $rows += , $adminRow
    }
    return @{ inline_keyboard = $rows }
}

function Get-TemplateCategories {
    $store = Get-TemplateStore
    return @($store.Order | ForEach-Object { ([string]$store.Map[$_].Category).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-TemplateLastUsedLabel {
    param([Parameter(Mandatory)][string]$Key)
    if (-not $script:TemplateLastUsed.ContainsKey($Key)) { return '' }
    return " · 🕘 $(([datetime]$script:TemplateLastUsed[$Key]).ToLocalTime().ToString('MM-dd HH:mm'))"
}

function Get-TemplatesKeyboard {
    <# Prefix selects what tapping a template does: tpl = show now,
       tplT = show with auto-hide, updtpl = pick a field to update. #>
    param([string]$Prefix = 'tpl', [string]$Category = '', [string]$Query = '', [switch]$BrowseControls)
    $store = Get-TemplateStore
    $rows = @()
    if ($BrowseControls -and $Prefix -eq 'tpl') {
        $rows += , @((New-Button '🔎 بحث' 'menu:templatesearch'), (New-Button '🗂 التصنيفات' 'menu:templatecategories'))
    }
    $matched = 0
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        $t = $store.Map[$store.Order[$i]]
        if ($Category -and -not ([string]$t.Category).Equals($Category, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($Query) {
            $haystack = "$($t.Key) $($t.Description) $($t.Category)"
            if ($haystack.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $matched++
        $categoryLabel = if ([string]::IsNullOrWhiteSpace([string]$t.Category)) { '' } else { " · $($t.Category)" }
        $templateRow = @((New-Button "$($t.Key) (طبقة $($t.Layer))$categoryLabel$(Get-TemplateLastUsedLabel -Key ([string]$t.Key))" "$Prefix`:$i"))
        if ($Prefix -eq 'tpl') { $templateRow += (New-Button 'ℹ️' "tplinfo:$i") }
        $rows += , $templateRow
        # Presets are only meaningful for an immediate show.
        if ($Prefix -eq 'tpl') {
            $presetRow = @()
            for ($p = 0; $p -lt $t.Presets.Count; $p++) {
                $presetRow += (New-Button "  ⚡ $($t.Presets[$p].Name)" "preset:$i`:$p")
                if ($presetRow.Count -eq 2) { $rows += , $presetRow; $presetRow = @() }
            }
            if ($presetRow.Count -gt 0) { $rows += , $presetRow }
        }
    }
    if ($matched -eq 0) {
        $rows += , @( (New-Button $(if ($Query -or $Category) { 'لا توجد نتائج مطابقة' } else { 'لا توجد قوالب معرّفة' }) "menu:templates") )
    }
    $rows += , @( (New-Button "⬅️ رجوع" "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateCategoriesKeyboard {
    $categories = @(Get-TemplateCategories)
    $rows = @()
    for ($i = 0; $i -lt $categories.Count; $i++) { $rows += , @((New-Button "🗂 $($categories[$i])" "tplcat:$i")) }
    if ($categories.Count -eq 0) { $rows += , @((New-Button 'لا توجد تصنيفات معرّفة' 'menu:templates')) }
    $rows += , @((New-Button '📋 كل القوالب' 'menu:templates'), (New-Button '⬅️ رجوع' 'menu'))
    return @{ inline_keyboard = $rows }
}

function Get-TemplatePreviewText {
    param([Parameter(Mandatory)]$Template)
    $category = if ([string]::IsNullOrWhiteSpace([string]$Template.Category)) { 'غير مصنف' } else { [string]$Template.Category }
    $description = if ([string]::IsNullOrWhiteSpace([string]$Template.Description)) { 'لا يوجد وصف.' } else { [string]$Template.Description }
    $fields = if (@($Template.Fields).Count -eq 0) { 'بلا حقول تحريرية' } else { @($Template.Fields) -join '، ' }
    $lastUsed = if ($script:TemplateLastUsed.ContainsKey([string]$Template.Key)) {
        ([datetime]$script:TemplateLastUsed[[string]$Template.Key]).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
    }
    else { 'لم يُستخدم بعد' }
    return "ℹ️ $($Template.Key)`nالتصنيف: $category`nالطبقة: $($Template.Layer)`nالوصف: $description`nالحقول: $fields`nآخر استخدام: $lastUsed"
}

function Get-TemplatePreviewKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    return @{ inline_keyboard = @(
        , @((New-Button '▶️ اختيار هذا القالب' "tpl:$TemplateIndex"))
        , @((New-Button '⬅️ القوالب' 'menu:templates'))
    ) }
}

function Start-TemplateSearch {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'template_search'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text '🔎 أرسل جزءًا من اسم القالب أو وصفه أو تصنيفه:' -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-TemplateSearch {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_search') { return }
    Clear-PendingState -ChatId $ChatId
    $query = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($query)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لم تُدخل عبارة بحث.' -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -BrowseControls)
        return
    }
    Send-TelegramMessage -ChatId $ChatId -Text "🔎 نتائج البحث عن '$query':" -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -Query $query -BrowseControls)
}

function Get-RetryDelaySeconds {
    param([int]$BaseSeconds, [int]$Attempt, [int]$Factor = 2, [int]$MaxSeconds = 300)
    $base = [math]::Max(1, $BaseSeconds)
    $safeAttempt = [math]::Min(31, [math]::Max(1, $Attempt))
    $safeFactor = [math]::Max(1, $Factor)
    $cap = [math]::Max(1, $MaxSeconds)
    $calculated = [double]$base * [math]::Pow([double]$safeFactor, [double]($safeAttempt - 1))
    return [int][math]::Min([double]$cap, $calculated)
}

function Get-ScheduleLayerConflicts {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][datetimeoffset]$ScheduledAt,
        [int]$WindowMinutes = 2,
        [string]$ExcludeId = ''
    )
    if ($Layer -le 0) { return @() }
    $window = [math]::Max(0, $WindowMinutes)
    foreach ($entry in @($script:ScheduleEvents)) {
        if ([string]$entry.Status -ne 'pending' -or ([string]$entry.Id -eq $ExcludeId -and $ExcludeId)) { continue }
        $entryLayer = 0
        [int]::TryParse([string](Get-JsonProp $entry 'Layer'), [ref]$entryLayer) | Out-Null
        if ($entryLayer -le 0) {
            $store = Get-TemplateStore
            $entryKey = [string]$entry.TemplateKey
            if ($store.Map.ContainsKey($entryKey)) { $entryLayer = [int]$store.Map[$entryKey].Layer }
        }
        if ($entryLayer -ne $Layer) { continue }
        $distance = [math]::Abs((([datetimeoffset]$entry.ScheduledAt) - $ScheduledAt).TotalMinutes)
        if ($distance -le $window) { Write-Output $entry }
    }
}

function Get-UsersAdminKeyboard {
    $rows = @()
    foreach ($user in @(Get-AuthorizedUsers)) {
        $role = if ($user.Role -eq 'admin') { 'مشرف' } else { 'مشغّل' }
        $state = if ($user.Disabled) { '⛔ معطّل' } else { '✅ نشط' }
        $rows += , @((New-Button "$state · $($user.Alias) · $role" "usr:toggle:$($user.UserId)"))
        $rows += , @((New-Button "✏️ Alias · $($user.Alias)" "usr:alias:$($user.UserId)"))
        $lastActivity = if ($user.LastActivityAt) { ([datetime]$user.LastActivityAt).ToString('MM-dd HH:mm') } else { 'غير معروف' }
        $rows += , @((New-Button "🕒 آخر نشاط: $lastActivity" "usr:revoke:$($user.UserId)"))
        $rows += , @((New-Button "🗑 سحب صلاحية $($user.Alias)" "usr:revoke:$($user.UserId)"))
    }
    $rows += , @((New-Button '⬅️ رجوع' 'menu'))
    return @{ inline_keyboard = $rows }
}

function Show-UsersAdminScreen {
    param([Parameter(Mandatory)][long]$ChatId)
    Send-TelegramMessage -ChatId $ChatId -Text "👥 المستخدمون المصرح لهم`nاضغط المستخدم لتعطيله أو إعادة تفعيله، واستخدم ✏️ Alias لتعديل اسمه التشغيلي، أو زر السحب مع التأكيد." -ReplyMarkup (Get-UsersAdminKeyboard)
}

function Start-UserAliasEdit {
    param(
        [Parameter(Mandatory)][long]$TargetUserId,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$AdminUserId
    )
    if (-not (Test-Admin -ChatId $ChatId -UserId $AdminUserId)) { return }
    if (@(Get-AuthorizedUsers | Where-Object UserId -eq $TargetUserId).Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text 'المستخدم لم يعد ضمن قائمة المصرح لهم.' -ReplyMarkup (Get-UsersAdminKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode='user_alias_edit'; TargetUserId=$TargetUserId; UserId=$AdminUserId }
    $current = Get-UserDisplayName -UserId $TargetUserId
    Send-TelegramMessage -ChatId $ChatId -Text "✏️ الاسم التشغيلي للمستخدم $TargetUserId`nالحالي: $current`n`nأرسل الاسم الجديد، أو أرسل - لحذف الـAlias." -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-UserAliasEdit {
    param(
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$AdminUserId,
        [AllowEmptyString()][string]$Value = ''
    )
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'user_alias_edit' -or [long]$state.UserId -ne $AdminUserId) { return $false }
    $target = [long]$state.TargetUserId
    $alias = $Value.Trim()
    if ($alias -eq '-') { $alias = '' }
    if ([string]::IsNullOrWhiteSpace($alias)) { $alias = '' }
    if (-not (Set-UserAlias -TargetUserId $target -Alias $alias)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذر حفظ الاسم التشغيلي.' -ReplyMarkup (Get-UsersAdminKeyboard)
        return $false
    }
    Clear-PendingState -ChatId $ChatId
    $action = if ($alias) { "تعيين Alias '$alias'" } else { 'حذف Alias' }
    Write-BridgeLog "Admin $AdminUserId updated alias for user ${target}: $action"
    Add-AuditEntry "👤 $action للمستخدم $target - by $(Get-UserDisplayName -UserId $AdminUserId)"
    Show-UsersAdminScreen -ChatId $ChatId
    return $true
}

function Get-FavoritesManagementKeyboard {
    param([Parameter(Mandatory)][long]$UserId)
    $store = Get-TemplateStore; $selected = @(Get-FavoriteTemplateKeys -UserId $UserId); $rows = @()
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        $key = [string]$store.Order[$i]
        $mark = if ($selected -contains $key) { '✅' } else { '▫️' }
        $rows += , @((New-Button "$mark $key" "favtoggle:$i"))
    }
    $rows += , @((New-Button '⬅️ رجوع' 'menu'))
    return @{ inline_keyboard = $rows }
}

function Get-LayersKeyboard {
    param([Parameter(Mandatory)][string]$Prefix)
    $rows = @()
    $row = @()
    foreach ($l in (Get-KnownLayers)) {
        $row += (New-Button (Get-LayerDisplayName -Layer $l) "$Prefix`:$l")
        if ($row.Count -eq 4) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button "⬅️ رجوع" "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-PresetAdminTemplatesKeyboard {
    $store = Get-TemplateStore
    $rows = @()
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        $template = $store.Map[$store.Order[$i]]
        $rows += , @( (New-Button "$($template.Key) ($(@($template.Presets).Count))" "padm:$i") )
    }
    $rows += , @( (New-Button "⬅️ القائمة" 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-PresetAdminKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    $rows = @()
    if ($template) {
        for ($i = 0; $i -lt @($template.Presets).Count; $i++) {
            $rows += , @( (New-Button "⚡ $($template.Presets[$i].Name)" "pa:$TemplateIndex`:$i") )
        }
        $rows += , @( (New-Button "➕ إنشاء نص جاهز" "pac:$TemplateIndex") )
    }
    $rows += , @( (New-Button "⬅️ القوالب" 'menu:presetsadmin') )
    return @{ inline_keyboard = $rows }
}

function Get-PresetActionKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex)
    return @{ inline_keyboard = @(
            , @( (New-Button "✏️ تعديل القيم" "pae:$TemplateIndex`:$PresetIndex"), (New-Button "🏷 إعادة تسمية" "par:$TemplateIndex`:$PresetIndex") )
            , @( (New-Button "🗑 حذف" "pad:$TemplateIndex`:$PresetIndex"), (New-Button "⬅️ رجوع" "padm:$TemplateIndex") )
        ) }
}

function Get-PresetReviewKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "✅ حفظ التغيير" 'presetadmin:confirm'), (New-Button "❌ إلغاء" 'cancel') )
        ) }
}

function Get-ScheduleMenuKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "➕ جدولة عرض" 'schedule:new'), (New-Button "📋 الأحداث القادمة" 'schedule:list') )
            , @( (New-Button "⬅️ القائمة" 'menu') )
        ) }
}

function Get-ScheduleRecurrenceKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "مرة واحدة" 'schrec:once'), (New-Button "يومي" 'schrec:daily'), (New-Button "أسبوعي" 'schrec:weekly') )
            , @( (New-Button "❌ إلغاء" 'cancel') )
        ) }
}

function Get-ScheduleReviewKeyboard {
    param([hashtable]$State)
    $rows = @()
    if ($State -and [string]$State.Recurrence -ne 'once') {
        $rows += , @((New-Button '📆 تحديد نهاية التكرار' 'schedule:setend'), (New-Button '♾ بدون انتهاء' 'schedule:clearend'))
    }
    $rows += , @((New-Button "✅ تأكيد الجدولة" 'schedule:confirm'), (New-Button "❌ إلغاء" 'cancel'))
    return @{ inline_keyboard = $rows }
}

function Get-UpcomingScheduleKeyboard {
    $rows = @()
    foreach ($scheduleEntry in @(Get-UpcomingScheduleEvents)) {
        $at = [datetimeoffset]$scheduleEntry.ScheduledAt
        $rows += , @(
            (New-Button "✏️ $($scheduleEntry.TemplateKey) $($at.ToString('MM-dd HH:mm'))" "schededit:$($scheduleEntry.Id)"),
            (New-Button '📄 نسخ' "schedcopy:$($scheduleEntry.Id)"),
            (New-Button '🗑' "schcancel:$($scheduleEntry.Id)")
        )
    }
    $rows += , @( (New-Button "⬅️ الجدولة" 'menu:schedule') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerDashboardKeyboard {
    param([Parameter(Mandatory)][object[]]$LayerStatuses)
    $rows = @()
    $row = @()
    foreach ($status in @($LayerStatuses | Sort-Object Layer)) {
        $layer = [int]$status.Layer
        if (-not $status.Success) {
            $button = New-Button "🔄 فحص ومقارنة · $(Get-LayerDisplayName -Layer $layer)" 'menu:layers'
        }
        elseif ($status.IsOnAir) {
            $button = New-Button "🙈 إخفاء $(Get-LayerDisplayName -Layer $layer)" "hide:$layer"
        }
        else {
            $button = New-Button "🔄 تحديث · $(Get-LayerDisplayName -Layer $layer) مخفية" 'menu:layers'
        }
        $row += $button
        if ($row.Count -eq 2) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button "🔎 فحص ومقارنة مع Cinegy" 'menu:layers'), (New-Button "⬅️ رجوع" 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-FieldsKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    $t = Get-TemplateByIndex -Index $TemplateIndex
    $rows = @()
    if ($t) {
        for ($f = 0; $f -lt $t.Fields.Count; $f++) {
            $label = [string]$t.Fields[$f]
            if ($f -lt @($t.FieldLabels).Count -and $t.FieldLabels[$f]) { $label = [string]$t.FieldLabels[$f] }
            $rows += , @( (New-Button $label "updf:$TemplateIndex`:$f") )
        }
    }
    $rows += , @( (New-Button "⬅️ رجوع" "menu:update") )
    return @{ inline_keyboard = $rows }
}

function Get-AfterShowKeyboard {
    <# Shown with the "on air" confirmation: hide/exit that exact layer without
       hunting through menus, plus the usual main menu underneath. #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $menu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    $first = @( (New-Button "🙈 إخفاء هذا (طبقة $Layer)" "hide:$Layer"), (New-Button "🚪 خروج" "exit:$Layer") )
    if (Get-Setting 'EnableTimedShow') { $first += (New-Button "⏱ مؤقت" "timer:$Layer") }
    $rows = @( , $first )
    if (Get-RollbackCandidate -Layer $Layer -UserId $UserId) { $rows += , @((New-Button '↩️ تراجع آمن' "rollback:$Layer")) }
    $rows += $menu.inline_keyboard
    return @{ inline_keyboard = $rows }
}

function Get-AfterLayerRemovalKeyboard {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $menu = Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId
    $rows = @()
    if (Get-RollbackCandidate -Layer $Layer -UserId $UserId) { $rows += , @((New-Button '↩️ استعادة المشهد السابق' "rollback:$Layer")) }
    $rows += $menu.inline_keyboard
    return @{ inline_keyboard=$rows }
}

function Get-RollbackReviewKeyboard {
    param([Parameter(Mandatory)][int]$Layer)
    return @{ inline_keyboard=@(
        , @((New-Button '✅ تأكيد التراجع' "rollbackconfirm:$Layer"), (New-Button '❌ إلغاء' 'menu'))
    ) }
}

function Get-CancelKeyboard {
    return @{ inline_keyboard = @( , @( (New-Button "❌ إلغاء" "cancel") ) ) }
}

function Get-FieldPromptKeyboard {
    param([hashtable]$State)
    $rows = @()
    if ($State -and $State.Fields -and [int]$State.Index -lt @($State.Fields).Count) {
        $index = [int]$State.Index
        $fieldName = [string]$State.Fields[$index]
        $isSensitive = Test-SensitiveFieldName -FieldName $fieldName
        if ($State.ContainsKey('Sensitives') -and $index -lt @($State.Sensitives).Count) {
            $isSensitive = $isSensitive -or [bool]$State.Sensitives[$index]
        }
        if (-not $isSensitive) {
            $recent = @(Get-RecentFieldValues -UserId ([long]$State.UserId) -FieldName $fieldName)
            for ($i = 0; $i -lt $recent.Count; $i++) {
                $label = [string]$recent[$i]
                if ($label.Length -gt 32) { $label = $label.Substring(0, 29) + '...' }
                $rows += , @( (New-Button "🕘 $label" "recent:$i") )
            }
        }
    }
    $row = @()
    if ($State -and [int]$State.Index -gt 0) { $row += (New-Button "⬅️ السابق" "show:back") }
    if ($State -and $State.Values.Count -gt 0) { $row += (New-Button "🔎 معاينة" "show:preview") }
    $row += (New-Button "⏭ تخطي" "skip")
    $row += (New-Button "❌ إلغاء" "cancel")
    $rows += , $row
    return @{ inline_keyboard = $rows }
}

function Get-ShowReviewKeyboard {
    param([switch]$HasFields)
    $row = @( (New-Button "✅ تأكيد الإرسال" "show:confirm") )
    if ($HasFields) { $row += (New-Button "✏️ تعديل" "show:edit") }
    return @{ inline_keyboard = @( , $row; , @( (New-Button "❌ إلغاء" "cancel") ) ) }
}

function Get-HideAllConfirmKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "🚨 نعم، إخفاء الكل" "hideall:confirm"), (New-Button "❌ إلغاء" "cancel") )
        ) }
}

function Get-ApprovalKeyboard {
    param([Parameter(Mandatory)][long]$TargetChatId)
    return @{ inline_keyboard = @( , @( (New-Button "✅ موافقة" "approve:$TargetChatId"), (New-Button "❌ رفض" "reject:$TargetChatId") ) ) }
}

function Get-PendingKeyboard {
    $rows = @()
    foreach ($id in @($script:PendingApprovals.Keys)) {
        $info = $script:PendingApprovals[$id]
        $label = if ($info.Name) { "$($info.Name)" } else { "$id" }
        $rows += , @( (New-Button "✅ $label" "approve:$id"), (New-Button "❌" "reject:$id") )
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button "لا توجد طلبات معلّقة حاليًا" "menu") ) }
    else { $rows += , @( (New-Button "⬅️ رجوع" "menu") ) }
    return @{ inline_keyboard = $rows }
}

# Settings whose whole purpose is to restrict access. Turning one off from a
# chat button - by accident or by someone who got hold of an admin's phone -
# silently weakens the security model, so they require an explicit confirm.
$script:ProtectedSettings = @('RequireUserLevelAuth', 'EnableSelfServiceRequests', 'EnableRawCommand', 'EnableFullTemplateManagement', 'EnableDpapiSecrets')

# Allowed values for string settings. A typo here would silently stop graphics
# updating, so the choice is constrained rather than free text.
$script:SettingChoices = @{
    AirVariableType = @('Text', 'String', 'Bool', 'Float')
}

function Get-SettingsKeyboard {
    <# One row per setting. Booleans toggle in place (cfg:t:), numbers open a
       "send me a value" prompt (cfg:v:). Setting names are ASCII and short, so
       they stay well inside the 64-byte callback_data budget. #>
    $rows = @()
    foreach ($name in $script:DefaultSettings.Keys) {
        if ($name -in @('HideAllLayers', 'LayerNames')) { continue }
        $value = Get-Setting $name
        if ($script:DefaultSettings[$name] -is [bool]) {
            $mark = if ($value) { "✅" } else { "❌" }
            $lock = if ($script:ProtectedSettings -contains $name) { "🔒 " } else { "" }
            $rows += , @( (New-Button "$mark $lock$name" "cfg:t:$name") )
        }
        elseif ($script:DefaultSettings[$name] -is [string]) {
            $label = if ($name -eq 'NewsFilePath') { "📰 ملف الأخبار = $value" } else { "🔤 $name = $value" }
            $rows += , @( (New-Button $label "cfg:s:$name") )
        }
        else {
            $rows += , @( (New-Button "🔢 $name = $(Format-SettingDisplay -Name $name -Value $value)" "cfg:v:$name") )
        }
    }
    $scope = [string](Get-Setting 'HideAllLayers')
    $scopeLabel = if ($scope.Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) { 'كل الطبقات المعروفة' } elseif ($scope.Trim()) { "طبقات: $scope" } else { 'لا توجد طبقات محددة' }
    $rows += , @( (New-Button "🚨 طبقات إخفاء الكل: $scopeLabel" 'menu:hideallsettings') )
    $rows += , @( (New-Button '🏷️ أسماء الطبقات' 'menu:layernames') )
    $rows += , @( (New-Button "🗄 نسخ الإعدادات" "menu:backups"), (New-Button "♻️ استعادة الافتراضي" "cfg:reset") )
    $rows += , @( (New-Button "⬅️ رجوع" "menu") )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateAdminCatalogueKeyboard {
    $store = Get-TemplateStore
    $rows = @()
    for ($i = 0; $i -lt $store.Order.Count; $i++) {
        $template = $store.Map[$store.Order[$i]]
        $rows += , @( (New-Button "$($template.Key) (طبقة $($template.Layer))" "tadm:$i") )
    }
    $transferRow = @((New-Button '📤 تصدير JSON' 'timport:export'))
    if (Get-Setting 'EnableFullTemplateManagement') { $transferRow += (New-Button '📥 استيراد JSON' 'timport:start') }
    $rows += , $transferRow
    if (Get-Setting 'EnableFullTemplateManagement') { $rows += , @( (New-Button '➕ إضافة قالب' 'tadm:create') ) }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button 'لا توجد قوالب صالحة' 'menu') ) }
    $rows += , @( (New-Button '⬅️ القائمة' 'menu') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateAdminDetailKeyboard {
    param([Parameter(Mandatory)][int]$TemplateIndex)
    $rows = @()
    if (Get-Setting 'EnableFullTemplateManagement') {
        $rows += , @( (New-Button '✏️ تعديل التعريف' "tadm:edit:$TemplateIndex"), (New-Button '🗑 حذف القالب' "tadm:delete:$TemplateIndex") )
        if ((Get-SettingInt 'TemplateTestLayer' 0) -gt 0) { $rows += , @((New-Button '🧪 اختبار على طبقة التجربة' "tadm:test:$TemplateIndex")) }
    }
    $rows += , @( (New-Button '⬅️ القوالب' 'menu:templatesadmin') )
    return @{ inline_keyboard = $rows }
}

function Get-TemplateDefinitionReviewKeyboard {
    return @{ inline_keyboard = @(
        , @( (New-Button '✅ حفظ التغيير' 'tadm:confirm'), (New-Button '❌ إلغاء' 'menu:templatesadmin') )
    ) }
}

function Get-HideAllLayerSettingsKeyboard {
    $selected = @(Get-HideAllTargetLayers)
    $allMode = ([string](Get-Setting 'HideAllLayers')).Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)
    $rows = @()
    foreach ($layer in @(Get-KnownLayers | ForEach-Object { [int]$_ } | Sort-Object -Unique)) {
        $mark = if ($allMode -or $selected -contains $layer) { '✅' } else { '⬜' }
        $rows += , @( (New-Button "$mark طبقة $layer" "hideallcfg:toggle:$layer") )
    }
    $rows += , @( (New-Button "☑️ اختيار كل الطبقات" 'hideallcfg:all'), (New-Button "🚫 إلغاء اختيار الكل" 'hideallcfg:none') )
    $rows += , @( (New-Button "⬅️ الإعدادات" 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerNamesKeyboard {
    $rows = @()
    foreach ($layer in @(Get-KnownLayers | ForEach-Object { [int]$_ } | Sort-Object -Unique)) {
        $rows += , @( (New-Button "🏷️ $(Get-LayerDisplayName -Layer $layer)" "layername:$layer") )
    }
    if ($rows.Count -eq 0) { $rows += , @( (New-Button 'لا توجد طبقات معرفة' 'menu:settings') ) }
    $rows += , @( (New-Button '⬅️ الإعدادات' 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-LayerNameEditKeyboard {
    param([Parameter(Mandatory)][int]$Layer)
    return @{ inline_keyboard = @(
            , @( (New-Button '🗑️ مسح الاسم' "layername:clear:$Layer") )
            , @( (New-Button '⬅️ أسماء الطبقات' 'menu:layernames'), (New-Button '❌ إلغاء' 'menu:settings') )
        ) }
}

function Get-ConfigBackupsKeyboard {
    param([string]$Path = $ConfigPath)
    $backupDirectory = "$Path.backups"
    $files = if (Test-Path -LiteralPath $backupDirectory) {
        @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' | Sort-Object LastWriteTimeUtc, Name -Descending)
    }
    else { @() }
    $rows = @()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $label = $files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $rows += , @( (New-Button "🗄 $label" "cfg:restore:$i") )
    }
    if ($files.Count -eq 0) { $rows += , @( (New-Button "لا توجد نسخ محفوظة" 'menu:settings') ) }
    $rows += , @( (New-Button "⬅️ رجوع" 'menu:settings') )
    return @{ inline_keyboard = $rows }
}

function Get-ConfigRestoreConfirmKeyboard {
    return @{ inline_keyboard = @(
            , @( (New-Button "⚠️ نعم، استعادة النسخة" 'cfg:restoreconfirm'), (New-Button "❌ إلغاء" 'menu:backups') )
        ) }
}

function Get-SettingConfirmKeyboard {
    param([Parameter(Mandatory)][string]$Name)
    return @{ inline_keyboard = @( , @( (New-Button "⚠️ نعم، عطّل الحماية" "cfgc:$Name"), (New-Button "❌ إلغاء" "menu:settings") ) ) }
}

function Get-AutoHideChoices {
    <# Quick-pick durations, parsed from the AutoHidePresetSeconds setting so
       an admin can retune them without touching code. Bad entries are ignored
       rather than breaking the keyboard. #>
    $raw = [string](Get-Setting 'AutoHidePresetSeconds')
    $values = @()
    foreach ($part in ($raw -split '[,;\s]+')) {
        $n = 0
        if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -gt 0) { $values += $n }
    }
    if ($values.Count -eq 0) { $values = @(5, 10, 15, 30, 60) }
    return @($values | Sort-Object -Unique)
}

function Format-Duration {
    param([int]$Seconds)
    if ($Seconds -ge 60 -and $Seconds % 60 -eq 0) { return "$([int]($Seconds / 60)) د" }
    if ($Seconds -ge 60) { return "$([int]($Seconds / 60)) د $($Seconds % 60) ث" }
    return "$Seconds ث"
}

function Get-DurationKeyboard {
    <# Shared duration picker. Prefix 'dur' targets a template about to be
       shown; 'tlay' targets a layer that is already on air. The default is
       marked so the common case stays one tap. #>
    param(
        [Parameter(Mandatory)][ValidateSet('dur', 'tlay')][string]$Prefix,
        [Parameter(Mandatory)][string]$Token,
        [string]$BackData = 'menu'
    )
    $default = Get-SettingInt 'AutoHideDefaultSeconds' 0
    $rows = @()
    $row = @()
    foreach ($sec in (Get-AutoHideChoices)) {
        $mark = if ($sec -eq $default) { "⭐ " } else { "" }
        $row += (New-Button "$mark$(Format-Duration -Seconds $sec)" "$Prefix`:$Token`:$sec")
        if ($row.Count -eq 3) { $rows += , $row; $row = @() }
    }
    if ($row.Count -gt 0) { $rows += , $row }
    $rows += , @( (New-Button "⌨️ مدة أخرى" "$Prefix`:$Token`:c") )
    $rows += , @( (New-Button "⬅️ رجوع" $BackData) )
    return @{ inline_keyboard = $rows }
}

function Get-SettingChoiceKeyboard {
    <# String settings are picked from a fixed list rather than typed, so a
       typo cannot quietly break graphics. Index-based callback data keeps it
       inside the 64-byte budget. #>
    param([Parameter(Mandatory)][string]$Name)
    $rows = @()
    $choices = @($script:SettingChoices[$Name])
    $current = [string](Get-Setting $Name)
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $mark = if ($choices[$i] -eq $current) { "✅ " } else { "" }
        $rows += , @( (New-Button "$mark$($choices[$i])" "cfgs:$Name`:$i") )
    }
    $rows += , @( (New-Button "⬅️ رجوع" "menu:settings") )
    return @{ inline_keyboard = $rows }
}

function Show-SettingChoices {
    <# String settings come in two flavours: a constrained list (AirVariableType)
       gets a pick-list, anything else gets a free-text prompt. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($script:SettingChoices.ContainsKey($Name)) {
        Send-TelegramMessage -ChatId $ChatId -Text "اختر قيمة $Name`:" -ReplyMarkup (Get-SettingChoiceKeyboard -Name $Name)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'setting_text'; Name = $Name; UserId = $UserId }
    $prompt = if ($Name -eq 'NewsFilePath') {
        "أرسل المسار المطلق لملف الأخبار بصيغة TXT.`nالحالي: $(Get-Setting $Name)`nالافتراضي: $($script:DefaultSettings[$Name])`nلن يتم إنشاء الملف أو تعديله في هذه الخطوة."
    }
    else { "أرسل القيمة الجديدة لـ $Name (الحالية: $(Get-Setting $Name)، الافتراضية: $($script:DefaultSettings[$Name])):" }
    Send-TelegramMessage -ChatId $ChatId -Text $prompt -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-SettingText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ القيمة فارغة، لم يتغيّر شيء." -ReplyMarkup (Get-SettingsKeyboard)
        Clear-PendingState -ChatId $ChatId
        return
    }
    if ($state.Name -eq 'NewsFilePath' -and -not (Test-NewsTickerFilePathSetting -Path $trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ يجب إدخال مسار مطلق ينتهي بـ .txt، مثل:`nD:\cingy cg\ticker msg\news.txt`nلم يتغيّر الإعداد." -ReplyMarkup (Get-SettingsKeyboard)
        Clear-PendingState -ChatId $ChatId
        return
    }
    Clear-PendingState -ChatId $ChatId
    Set-Setting -Name $state.Name -Value $trimmed
    Write-BridgeLog "User $($state.UserId) set $($state.Name) = $trimmed"
    Add-AuditEntry "⚙️ $($state.Name) = $trimmed - user $($state.UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ $($state.Name) = $trimmed$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-SettingsKeyboard)
}

function Set-SettingChoice {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int]$Index, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $choices = @($script:SettingChoices[$Name])
    if ($Index -lt 0 -or $Index -ge $choices.Count) {
        Send-TelegramMessage -ChatId $ChatId -Text "خيار غير صالح." -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    Set-Setting -Name $Name -Value $choices[$Index]
    Write-BridgeLog "User $UserId set $Name = $($choices[$Index])"
    Add-AuditEntry "⚙️ $Name = $($choices[$Index]) - user $UserId"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ $Name = $($choices[$Index])$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-SettingsKeyboard)
}

# ============================================================================
#  Pending conversation state
# ============================================================================

function Lock-GfxLayer {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][string]$Key
    )
    if ($script:LayerLocks.ContainsKey($Layer)) {
        $existing = $script:LayerLocks[$Layer]
        if ([long]$existing.ChatId -ne $ChatId -or [long]$existing.UserId -ne $UserId) {
            return [pscustomobject]@{
                Success = $false
                OwnerChatId = [long]$existing.ChatId
                OwnerUserId = [long]$existing.UserId
                Key = [string]$existing.Key
            }
        }
    }
    $script:LayerLocks[$Layer] = @{
        ChatId = $ChatId; UserId = $UserId; Key = $Key; StartedAt = (Get-Date)
    }
    return [pscustomobject]@{ Success = $true; OwnerChatId = $ChatId; OwnerUserId = $UserId; Key = $Key }
}

function Unlock-GfxLayer {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Layer = 0)
    foreach ($candidate in @($script:LayerLocks.Keys)) {
        if (($Layer -le 0 -or [int]$candidate -eq $Layer) -and [long]$script:LayerLocks[$candidate].ChatId -eq $ChatId) {
            $script:LayerLocks.Remove($candidate)
        }
    }
}

function Set-PendingState {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    Set-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId -State $State
    if ([string]$State.Mode -in @('show_fields', 'show_review')) { Save-DraftStates }
}

function Get-PendingState {
    <# Returns the pending flow for a chat, or $null if there is none or it has
       aged out. Expiry is checked on read as well as on the tick so a stale
       entry can never be consumed. #>
    param([Parameter(Mandatory)][long]$ChatId)
    $timeout = Get-SettingInt 'PendingStateTimeoutMinutes' 1
    $result=Get-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId -TimeoutMinutes $timeout
    if (-not $result.State) { return $null }
    if ($result.Expired) {
        Complete-PendingStateCleanup -ChatId $ChatId -State $result.State
        return $null
    }
    return $result.State
}

function Complete-PendingStateCleanup {
    param([Parameter(Mandatory)][long]$ChatId,[Parameter(Mandatory)][hashtable]$State)
    if ($State.ContainsKey('LockLayer')) { Unlock-GfxLayer -ChatId $ChatId -Layer ([int]$State.LockLayer) }
    if ($State.ContainsKey('ImportStagedPath') -and (Test-Path -LiteralPath ([string]$State.ImportStagedPath))) {
        Remove-Item -LiteralPath ([string]$State.ImportStagedPath) -Force -ErrorAction SilentlyContinue
    }
    if ([string]$State.Mode -in @('show_fields', 'show_review')) { Save-DraftStates }
}

function Clear-PendingState {
    param([Parameter(Mandatory)][long]$ChatId)
    $state=Remove-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId
    if ($state) { Complete-PendingStateCleanup -ChatId $ChatId -State $state }
}

# ============================================================================
#  Help text
# ============================================================================

function Get-HelpText {
    param([long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }

    $lines = @(
        "📘 دليل استخدام بوت Cinegy Air",
        "",
        "🚀 الاستخدام السريع",
        "",
        "▶️ نشر قالب على الهواء:",
        "📋 القوالب ← اختر القالب ← أدخل نص كل حقل ← راجع القيم ← تأكيد الإرسال",
        "حتى القالب بلا حقول يمر بشاشة مراجعة قبل الهواء.",
        "",
        "✏️ تغيير النص أثناء العرض:",
        "✏️ تحديث نص ← اختر القالب ← اختر الحقل ← أرسل النص الجديد",
        "يُحدّث النص دون إعادة تشغيل حركة القالب.",
        "",
        "⏱ عرض لمدة محددة:",
        "⏱ عرض مؤقّت ← اختر القالب ← اختر المدة ← أدخل النص",
        "سيخفي البوت الطبقة تلقائيًا عند انتهاء المدة.",
        "",
        "🛑 إنهاء العرض والطوارئ",
        "🙈 إخفاء طبقة: إخفاء القالب فورًا من طبقة محددة.",
        "🚪 خروج من المشهد: تشغيل نهاية المشهد أو الخروج من الحلقة.",
        "🚨 إخفاء الكل: يعرض الطبقات ثم يطلب تأكيدًا ثانيًا قبل الإخفاء.",
        "",
        "🧰 أدوات مفيدة",
        "⭐ المفضّلة: أسرع وصول إلى القوالب الأكثر استخدامًا.",
        "🔁 إعادة الأخير: تكرار آخر قالب عرضته بالقيم نفسها.",
        "🎚 الطبقات: تفحص Cinegy مباشرة، تقارن الطبقات المعروفة مع onair.json، وتعرض كل طبقة كـ ظاهر، خارجي، مخفي أو غير معروف.",
        "اضغط على طبقة ظاهرة لإخفائها سريعًا؛ والضغط على طبقة غير ظاهرة يحدّث لوحة الطبقات.",
        "ℹ️ الحالة: ملخص سريع للجميع يعرض خادم Air والقناة والقوالب المتابعة.",
        "📸 صورة من البث: إرسال لقطة حديثة من خرج القناة.",
        "📅 الجدولة: اختر القالب والقيم والموعد ثم مرة واحدة/يومي/أسبوعي وراجع الحدث قبل حفظه.",
        ""
    )
    if (Test-Admin -ChatId $ChatId -UserId $UserId) {
        $lines += "🛡️ أدوات المشرف"
        $lines += "⚙️ الإعدادات، 👤 طلبات الوصول، 📊 الحالة الكاملة وصحة الخدمات،"
        $lines += "⚡ إدارة النصوص الجاهزة، ▶️/⏹ البث المباشر، 🔗 رابط البث، 📜 السجل، 🛠 أمر خام."
        $lines += ""
    }
    $lines += "↩️ الرجوع أو الإلغاء"
    $lines += "• اضغط 🏠 القائمة للرجوع، حتى أثناء إدخال النص."
    $lines += "• اضغط ☰ بجانب مربع الكتابة لعرض الأوامر."
    $lines += "• أرسل /الغاء لإلغاء العملية الحالية، أو /قائمة لفتح القائمة."
    return ($lines -join "`n")
}

# ============================================================================
#  Core on-air actions
# ============================================================================

function New-AirOperationContext {
    return [pscustomobject]@{
        Id        = "air-$([guid]::NewGuid().ToString('N'))"
        Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Get-TemplateTestReviewKeyboard {
    return @{ inline_keyboard = @(
        , @((New-Button '🧪 نعم، اختبر القالب' 'tadm:testconfirm'), (New-Button '❌ إلغاء' 'menu:templatesadmin'))
    ) }
}

function Write-AirOperationResult {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][ValidateSet('SHOW', 'HIDE', 'EXIT', 'UPDATE')][string]$Action,
        [Parameter(Mandatory)][ValidateSet('success', 'failed', 'blocked')][string]$Result,
        [Parameter(Mandatory)][long]$DurationMs,
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][long]$ChatId,
        [int]$Layer = 0,
        [string]$Target = '',
        [string]$ErrorText = ''
    )
    $cleanTarget = ($Target -replace '[\r\n]+', ' ').Replace('"', "'")
    $cleanError = ($ErrorText -replace '[\r\n]+', ' ').Replace('"', "'")
    $message = "AIR_OP id=$OperationId action=$Action result=$Result durationMs=$DurationMs user=$UserId chat=$ChatId layer=$Layer target=`"$cleanTarget`""
    if (-not [string]::IsNullOrWhiteSpace($cleanError)) { $message += " error=`"$cleanError`"" }
    $level = if ($Result -eq 'success') { 'INFO' } else { 'WARN' }
    $counterName = switch ($Result) { 'success' { 'Success' }; 'failed' { 'Failed' }; default { 'Blocked' } }
    $script:AirOperationCounters[$counterName] = [int]$script:AirOperationCounters[$counterName] + 1
    Add-UserOperationHistory -OperationId $OperationId -Action $Action -Result $Result -DurationMs $DurationMs -UserId $UserId -Layer $Layer -Target $Target
    Write-AuditRecord -OperationId $OperationId -Event air_control -Result $Result -UserId $UserId -ChatId $ChatId -Action $Action -Layer $Layer -Target $Target -DurationMs $DurationMs -Message $ErrorText
    Write-BridgeLog $message $level
}

function Test-MaintenanceControl {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [switch]$EmergencyOverride)
    if (-not (Get-Setting 'MaintenanceMode')) { return $true }
    if ($EmergencyOverride -and (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text '🛠 وضع الصيانة مفعّل؛ أوامر التحكم في الهواء متوقفة مؤقتًا.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $false
}

function Test-TemplateShowPolicy {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][int]$Layer)
    $reserved = @()
    foreach ($part in ([string](Get-Setting 'ReservedLayers') -split '[,;\s]+')) {
        $parsedLayer = 0
        if ([int]::TryParse($part.Trim(), [ref]$parsedLayer) -and $parsedLayer -gt 0) { $reserved += $parsedLayer }
    }
    if ($reserved -contains $Layer) {
        return [pscustomobject]@{ Allowed = $false; Reason = "الطبقة $Layer محجوزة إداريًا." }
    }
    $disabled = @([string](Get-Setting 'DisabledTemplateKeys') -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (@($disabled | Where-Object { $_.Equals($Key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        return [pscustomobject]@{ Allowed = $false; Reason = "القالب '$Key' معطّل مؤقتًا." }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = '' }
}

function Get-EffectiveAutoHideSeconds {
    param(
        [Parameter(Mandatory)][string]$Key,
        [int]$RequestedSeconds = 0
    )
    $sensitiveKeys = @([string](Get-Setting 'SensitiveTemplateKeys') -split '[,;\r\n]+' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $isSensitive = @($sensitiveKeys | Where-Object { $_.Equals($Key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if (-not $isSensitive) { return [math]::Max(0, $RequestedSeconds) }
    $requiredSeconds = Get-SettingInt 'SensitiveTemplateAutoHideSeconds' 1
    if ($RequestedSeconds -gt 0) { return [math]::Min($RequestedSeconds, $requiredSeconds) }
    return $requiredSeconds
}

function Copy-ShowVariables {
    param([hashtable]$Variables = @{})
    $copy = @{}
    foreach ($name in $Variables.Keys) { $copy[[string]$name] = [string]$Variables[$name] }
    return $copy
}

function Set-RollbackCandidate {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][hashtable]$RestoreSnapshot,
        [Parameter(Mandatory)][ValidateSet('replace','hidden')][string]$ExpectedState,
        [string]$ExpectedActiveId = '',
        [Parameter(Mandatory)][long]$ActorUserId
    )
    if (-not (Get-Setting 'EnableSafeRollback')) { return }
    $window = [math]::Max(10, [math]::Min(900, (Get-SettingInt 'RollbackWindowSeconds' 10)))
    $script:RollbackCandidates[$Layer] = @{
        Id=[guid]::NewGuid().ToString('N'); Layer=$Layer; Restore=$RestoreSnapshot
        ExpectedState=$ExpectedState; ExpectedActiveId=$ExpectedActiveId
        ActorUserId=$ActorUserId; CreatedAt=(Get-Date); ExpiresAt=(Get-Date).AddSeconds($window)
    }
}

function Get-RollbackCandidate {
    param([Parameter(Mandatory)][int]$Layer, [long]$UserId = 0)
    if (-not (Get-Setting 'EnableSafeRollback')) { return $null }
    if (-not $script:RollbackCandidates.ContainsKey($Layer)) { return $null }
    $candidate = $script:RollbackCandidates[$Layer]
    if ((Get-Date) -ge [datetime]$candidate.ExpiresAt) { $script:RollbackCandidates.Remove($Layer) | Out-Null; return $null }
    if ($UserId -gt 0 -and [long]$candidate.ActorUserId -ne $UserId -and -not (Test-Admin -ChatId $UserId -UserId $UserId)) { return $null }
    return $candidate
}

function Get-CorrelatedLayerSnapshot {
    param([Parameter(Mandatory)][int]$Layer, $LiveStatus)
    if (-not $script:LastSuccessfulLayerShows.ContainsKey($Layer) -or -not $LiveStatus -or
        -not $LiveStatus.Success -or $LiveStatus.IsOnAir -ne $true) { return $null }
    $snapshot = $script:LastSuccessfulLayerShows[$Layer]
    $activeId = [string](Get-JsonProp $LiveStatus 'ActiveId')
    if ([string]::IsNullOrWhiteSpace($activeId) -or $activeId -ne [string]$snapshot.ActiveId) { return $null }
    return $snapshot
}

function Invoke-ShowTemplateResult {
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Variables = @{},
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [int]$AutoHideSeconds = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $AutoHideSeconds = Get-EffectiveAutoHideSeconds -Key $Key -RequestedSeconds $AutoHideSeconds
    $operation = New-AirOperationContext
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target $Key -ErrorText 'maintenance mode'
        return [pscustomobject]@{ Success = $false; Error = 'وضع الصيانة مفعّل.' }
    }
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($Key)) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب '$Key' غير معروف." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target $Key -ErrorText 'unknown template'
        return
    }
    $template = $store.Map[$Key]
    $attemptVariables = @{}
    foreach ($variableName in $Variables.Keys) { $attemptVariables[[string]$variableName] = [string]$Variables[$variableName] }
    $script:LastShowAttempts[[string]$UserId] = @{
        Key = $Key; Variables = $attemptVariables; AutoHideSeconds = $AutoHideSeconds
    }
    $policy = Test-TemplateShowPolicy -Key $Key -Layer ([int]$template.Layer)
    if (-not $policy.Allowed) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لم يتم الإرسال: $($policy.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -ErrorText ([string]$policy.Reason)
        return [pscustomobject]@{ Success = $false; Error = [string]$policy.Reason }
    }

    # SHOW is the only operation that can replace visible content. Verify the
    # target layer immediately before mutating it; an unreachable Cinegy must
    # never be interpreted as an empty or safe layer.
    $layerStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -Layer ([int]$template.Layer) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not $layerStatus.Success) {
        $errorText = [string](Get-JsonProp $layerStatus 'Error')
        Write-BridgeLog "Blocked SHOW '$Key' on layer $($template.Layer): live Cinegy verification failed: $errorText" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لم يتم الإرسال: تعذّر التحقق من حالة طبقة Cinegy $($template.Layer). أعد فحص الحالة ثم حاول مجددًا." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -ErrorText $errorText
        return [pscustomobject]@{ Success = $false; Error = 'تعذّر التحقق من حالة طبقة Cinegy.' }
    }
    $layerStatus | Add-Member -NotePropertyName Layer -NotePropertyValue ([int]$template.Layer) -Force
    Update-OnAirStateFromCinegy -Reason 'before-show' -LayerStatuses @($layerStatus) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal | Out-Null
    $previousSnapshot = Get-CorrelatedLayerSnapshot -Layer ([int]$template.Layer) -LiveStatus $layerStatus

    # A scene that is already loaded on the layer keeps running with the values
    # it was started with, so a second SHOW can leave the PREVIOUS text on air.
    # Taking the layer down first forces the scene to initialise with the new
    # variables. (To change text without re-firing the animation, use the
    # ✏️ تحديث نص button, which writes to the live postbox instead.)
    if ((Get-Setting 'ReshowClearsLayer') -and $script:OnAir.ContainsKey([int]$template.Layer)) {
        $clear = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $template.Layer -TimeoutSec (Get-AirTimeout)
        if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air pre-show HIDE on layer $($template.Layer): success=$($clear.Success)" }
    }

    # Only pass through explicit per-field type overrides; everything else
    # takes the AirVariableType default.
    $types = @{}
    foreach ($name in @($template.FieldTypes.Keys)) {
        if ($template.FieldTypes[$name]) { $types[$name] = [string]$template.FieldTypes[$name] }
    }
    $defaultType = [string](Get-Setting 'AirVariableType')
    if ([string]::IsNullOrWhiteSpace($defaultType)) { $defaultType = 'Text' }

    $result = Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $template.Layer -TemplatePath $template.Path -Variables $Variables `
        -Types $types -DefaultType $defaultType -TimeoutSec (Get-AirTimeout)

    # Air Pro answers 200 OK even when it does not recognise a variable name,
    # so "Success" only means the request was accepted - not that the text
    # landed. Turn on LogAirXml to see exactly what was transmitted.
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air SHOW XML: $($result.Xml)" }

    if ($result.Success) {
        if ($previousSnapshot) {
            Set-RollbackCandidate -Layer ([int]$template.Layer) -RestoreSnapshot $previousSnapshot `
                -ExpectedState replace -ExpectedActiveId ([string]$result.EventId) -ActorUserId $UserId
        }
        else { $script:RollbackCandidates.Remove([int]$template.Layer) | Out-Null }
        $script:LastSuccessfulLayerShows[[int]$template.Layer] = @{
            Key=$Key; Variables=(Copy-ShowVariables -Variables $Variables); UserId=$UserId; ChatId=$ChatId
            ActiveId=[string]$result.EventId; At=(Get-Date)
        }
        $script:LastShow[$ChatId] = @{ Key = $Key; Variables = $Variables }
        $script:OnAir[[int]$template.Layer] = @{
            Key = $Key; At = (Get-Date); UserId = $UserId; ActiveId = [string]$result.EventId
        }
        Save-OnAirState
        Add-UsageCount -Key $Key
        Write-BridgeLog "User $UserId (chat $ChatId) pushed template '$Key' (layer $($template.Layer))"
        Add-AuditEntry "▶ $Key (طبقة $($template.Layer)) - user $UserId"

        # Belt and braces: also write the values through the postbox, which is
        # the channel this scene actually honours.
        if ((Get-Setting 'SetValuesAfterShow') -and $Variables.Count -gt 0) {
            $delay = Get-SettingInt 'PostShowDelayMs' 0
            $script:PostShowQueue.Add(@{
                    At = (Get-Date).AddMilliseconds($delay); Values = $Variables
                    Layer = [int]$template.Layer; Key = $Key
                })
        }

        $suffix = ""
        if ($AutoHideSeconds -gt 0) {
            for ($i = $script:AutoHideQueue.Count - 1; $i -ge 0; $i--) {
                if ([int]$script:AutoHideQueue[$i].Layer -eq [int]$template.Layer) { $script:AutoHideQueue.RemoveAt($i) }
            }
            $script:AutoHideQueue.Add(@{ Layer = $template.Layer; At = (Get-Date).AddSeconds($AutoHideSeconds); ChatId = $ChatId; UserId = $UserId })
            $suffix = " سيُخفى تلقائيًا بعد $AutoHideSeconds ثانية."
        }
        # A one-tap hide right where the operator is looking: previously taking
        # something back off air meant going 🙈 -> pick layer, which is several
        # taps too many when a wrong graphic is live.
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم إظهار '$Key' على الهواء (طبقة $($template.Layer)).$suffix" -ReplyMarkup (Get-AfterShowKeyboard -Layer ([int]$template.Layer) -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key
    }
    else {
        Write-BridgeLog "User $UserId failed to push template '$Key': $($result.Error)" "ERROR"
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -ErrorText ([string]$result.Error)
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل إظهار '$Key': $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    return $result
}

function Get-LayerShowContext {
    param([Parameter(Mandatory)][int]$Layer, [datetime]$Now = (Get-Date))
    $record = if ($script:OnAir.ContainsKey($Layer)) { $script:OnAir[$Layer] } else { $null }
    $lastSuccess = if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccess -FailedCount 0 -Now $Now `
        -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    return [pscustomobject]@{
        IsKnown = ($freshness.State -eq 'connected')
        IsOnAir = ($null -ne $record)
        Key      = if ($record) { [string](Get-JsonProp $record 'Key') } else { '' }
        UserId   = if ($record) { [long](Get-JsonProp $record 'UserId') } else { 0L }
        Source   = if ($record) { [string](Get-JsonProp $record 'Source') } else { '' }
    }
}

function Start-ShowFlow {
    <# Entry point for every SHOW source. ReviewImmediately is used when values
       already came from a preset or typed command; required missing fields
       still force the ordinary field-entry flow. #>
    param(
        [Parameter(Mandatory)][int]$TemplateIndex,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [int]$AutoHideSeconds = 0,
        [hashtable]$InitialValues = @{},
        [switch]$ReviewImmediately
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    $t = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $t) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب غير معروف (ربما تغيّر ملف القوالب). افتح 📋 القوالب من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $policy = Test-TemplateShowPolicy -Key ([string]$t.Key) -Layer ([int]$t.Layer)
    if (-not $policy.Allowed) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لا يمكن تجهيز العرض: $($policy.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $AutoHideSeconds = Get-EffectiveAutoHideSeconds -Key ([string]$t.Key) -RequestedSeconds $AutoHideSeconds
    $lock = Lock-GfxLayer -Layer ([int]$t.Layer) -ChatId $ChatId -UserId $UserId -Key ([string]$t.Key)
    if (-not $lock.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "الطبقة $($t.Layer) قيد التجهيز حاليًا بواسطة المستخدم $($lock.OwnerUserId). حاول لاحقًا أو اختر قالبًا على طبقة أخرى." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $replacementContext = Get-LayerShowContext -Layer ([int]$t.Layer)
    $draftValues = @{}
    foreach ($name in $InitialValues.Keys) { $draftValues[[string]$name] = [string]$InitialValues[$name] }
    $required = @(Get-JsonProp $t 'FieldRequired' | Where-Object { $null -ne $_ })
    $canReviewImmediately = [bool]$ReviewImmediately
    if ($canReviewImmediately) {
        for ($i = 0; $i -lt $t.Fields.Count; $i++) {
            if ($i -lt $required.Count -and [bool]$required[$i]) {
                $fieldName = [string]$t.Fields[$i]
                if (-not $draftValues.ContainsKey($fieldName) -or [string]::IsNullOrWhiteSpace([string]$draftValues[$fieldName])) {
                    $canReviewImmediately = $false
                    break
                }
            }
        }
    }
    if ($t.Fields.Count -eq 0 -or $canReviewImmediately) {
        $state = @{
            Mode = 'show_review'; Key = $t.Key; Fields = @($t.Fields); Labels = @($t.FieldLabels)
            Limits = @($t.FieldLimits); Required = $required
            Sensitives = @(Get-JsonProp $t 'FieldSensitive' | Where-Object { $null -ne $_ })
            Index = 0; Values = $draftValues; UserId = $UserId; AutoHideSeconds = $AutoHideSeconds
            LockLayer = [int]$t.Layer; ReplacementContext = $replacementContext
        }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text (Format-ShowReviewText -State $state) -ReplyMarkup (Get-ShowReviewKeyboard -HasFields)
        return
    }
    $state = @{
        Mode = 'show_fields'; Key = $t.Key; Fields = @($t.Fields); Labels = @($t.FieldLabels)
        Limits = @($t.FieldLimits)
        Required = $required
        Sensitives = @(Get-JsonProp $t 'FieldSensitive' | Where-Object { $null -ne $_ })
        Index = 0; Values = $draftValues; UserId = $UserId; AutoHideSeconds = $AutoHideSeconds
        LockLayer = [int]$t.Layer; ReplacementContext = $replacementContext
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text (Get-FieldPromptText -State $state) -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
}

function Resume-ShowFlow {
    <# Called for each text reply (or the ⏭ skip button) while a show_fields
       flow is pending. Advances one field, or fires the template once full.

       -Skip omits the field from the variable set entirely rather than sending
       an empty string, so the scene keeps whatever text it was designed with
       instead of being blanked. #>
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "", [switch]$Skip)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $isRequired = $state.Required -and $state.Index -lt @($state.Required).Count -and [bool]$state.Required[$state.Index]
    if ($isRequired -and ($Skip -or [string]::IsNullOrWhiteSpace($Value))) {
        $message = if ($Skip) { "❌ هذا الحقل مطلوب ولا يمكن تخطيه." } else { "❌ هذا الحقل مطلوب ولا يمكن تركه فارغًا." }
        Send-TelegramMessage -ChatId $ChatId -Text $message -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
        return
    }
    if (-not $Skip) {
        # Re-prompt rather than push oversized text: a pasted paragraph would
        # otherwise go straight to air and wreck the graphic's layout.
        $limit = 0
        if ($state.Limits -and $state.Index -lt @($state.Limits).Count) { $limit = [int]$state.Limits[$state.Index] }
        if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-FieldPromptKeyboard -State $state))) { return }
        $fieldName = [string]$state.Fields[$state.Index]
        $state.Values[$fieldName] = $Value
        $isSensitive = Test-SensitiveFieldName -FieldName $fieldName
        if ($state.ContainsKey('Sensitives') -and $state.Index -lt @($state.Sensitives).Count) {
            $isSensitive = $isSensitive -or [bool]$state.Sensitives[$state.Index]
        }
        Add-RecentFieldValue -UserId ([long]$state.UserId) -FieldName $fieldName -Value $Value -Sensitive:$isSensitive
    }
    $state.Index++

    if ($state.Index -ge $state.Fields.Count) {
        $state.Mode = 'show_review'
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text (Format-ShowReviewText -State $state) -ReplyMarkup (Get-ShowReviewKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text (Get-FieldPromptText -State $state) -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
}

function Format-ShowReviewText {
    param([Parameter(Mandatory)][hashtable]$State)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("🔎 مراجعة قبل الإرسال")
    $lines.Add("القالب: $($State.Key)")
    $lines.Add("الطبقة: $($State.LockLayer)")
    $context = Get-JsonProp $State 'ReplacementContext'
    if ($context -and -not [bool](Get-JsonProp $context 'IsKnown')) {
        $lines.Add("⚠️ تعذّر التحقق من حداثة حالة الطبقة؛ راجع شاشة الحالة قبل التأكيد عند الشك.")
    }
    if ($context -and [bool](Get-JsonProp $context 'IsOnAir')) {
        $currentKey = [string](Get-JsonProp $context 'Key')
        if ([string]::IsNullOrWhiteSpace($currentKey)) { $currentKey = 'مشهد غير مسمّى' }
        $currentUserId = [long](Get-JsonProp $context 'UserId')
        $sourceText = if ([string](Get-JsonProp $context 'Source') -eq 'cinegy') { 'Cinegy Air' } elseif ($currentUserId -gt 0) { "المستخدم $(Get-UserDisplayName -UserId $currentUserId)" } else { 'Bot' }
        $lines.Add("⚠️ سيتم استبدال القالب الحالي: $currentKey ($sourceText).")
    }
    if ($State.AutoHideSeconds -gt 0) { $lines.Add("الإخفاء التلقائي: $($State.AutoHideSeconds) ثانية") }
    $lines.Add("")
    for ($i = 0; $i -lt @($State.Fields).Count; $i++) {
        $name = [string]$State.Fields[$i]
        $label = $name
        if ($State.Labels -and $i -lt @($State.Labels).Count -and $State.Labels[$i]) { $label = [string]$State.Labels[$i] }
        $value = if ($State.Values.ContainsKey($name)) { [string]$State.Values[$name] } else { "(متروك)" }
        $lines.Add("• $label`: $value")
    }
    $lines.Add("")
    $lines.Add("لن يُرسل شيء إلى Cinegy حتى تضغط تأكيد الإرسال.")
    return ($lines -join "`n")
}

function Get-EffectiveFieldLimit {
    <# Resolution order: per-field maxLength -> per-template maxLength -> the
       global MaxFieldLength setting. A graphic's usable text length depends on
       its design, so one global number is a floor, not the whole answer. #>
    param([int]$FieldLimit = 0)
    if ($FieldLimit -gt 0) { return $FieldLimit }
    return (Get-SettingInt 'MaxFieldLength' 0)
}

function Test-FieldLength {
    <# Returns $true when the text is short enough to put on air, otherwise
       tells the operator and returns $false. The pending flow is deliberately
       left intact so they can simply retype the value. #>
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][long]$ChatId,
        [int]$FieldLimit = 0,
        [hashtable]$ReplyMarkup
    )
    $max = Get-EffectiveFieldLimit -FieldLimit $FieldLimit
    $visibleLength = Get-TextElementCount -Text $Value
    if ($max -le 0 -or $visibleLength -le $max) { return $true }
    if (-not $ReplyMarkup) { $ReplyMarkup = Get-FieldPromptKeyboard }
    Send-TelegramMessage -ChatId $ChatId -Text "❌ النص طويل جدًا ($visibleLength حرفًا) والحد الأقصى $max حرفًا. أرسل نصًا أقصر." -ReplyMarkup $ReplyMarkup
    return $false
}

function Get-FieldPromptText {
    <# Shows the operator-friendly label when templates.json provides one,
       falling back to the raw variable name (e.g. "Ajel.center") otherwise. #>
    param([Parameter(Mandatory)][hashtable]$State)
    $index = [int]$State.Index
    $name = [string]$State.Fields[$index]
    $label = $name
    if ($State.Labels -and $index -lt @($State.Labels).Count -and $State.Labels[$index]) {
        $label = "$($State.Labels[$index])`n($name)"
    }
    # Tell the operator the limit up front rather than rejecting after typing.
    $limit = 0
    if ($State.Limits -and $index -lt @($State.Limits).Count) { $limit = [int]$State.Limits[$index] }
    $limit = Get-EffectiveFieldLimit -FieldLimit $limit
    $limitText = if ($limit -gt 0) { " (الحد: $limit حرفًا)" } else { "" }
    return "القالب '$($State.Key)' - أرسل نص الحقل ($($index + 1)/$($State.Fields.Count))$limitText`:`n$label"
}

function Sync-LayerAfterOperatorAction {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][string]$Reason)
    $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    return Update-OnAirStateFromCinegy -Reason $Reason -LayerStatuses @($status) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
}

function Invoke-HideLayer {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [switch]$Quiet,
        [switch]$MaintenanceOverride
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId -EmergencyOverride:$MaintenanceOverride)) {
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -ErrorText 'maintenance mode'
        return $false
    }
    $rollbackSnapshot = $null
    if (-not $Quiet -and (Get-Setting 'EnableSafeRollback')) {
        $preHideStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $rollbackSnapshot = Get-CorrelatedLayerSnapshot -Layer $Layer -LiveStatus $preHideStatus
    }
    $result = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-AirTimeout)
    if ($result.Success) {
        if ($rollbackSnapshot) { Set-RollbackCandidate -Layer $Layer -RestoreSnapshot $rollbackSnapshot -ExpectedState hidden -ActorUserId $UserId }
        Sync-LayerAfterOperatorAction -Layer $Layer -Reason 'after-hide' | Out-Null
        Write-BridgeLog "User $UserId hid layer $Layer"
        Add-AuditEntry "🙈 إخفاء طبقة $Layer - user $UserId"
        if (-not $Quiet) { Send-TelegramMessage -ChatId $ChatId -Text "✅ تم إخفاء الطبقة $Layer." -ReplyMarkup (Get-AfterLayerRemovalKeyboard -Layer $Layer -ChatId $ChatId -UserId $UserId) }
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer
    }
    elseif (-not $Quiet) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل إخفاء الطبقة $Layer : $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    if (-not $result.Success) {
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Invoke-ExitLayer {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -ErrorText 'maintenance mode'
        return $false
    }
    $rollbackSnapshot = $null
    if (Get-Setting 'EnableSafeRollback') {
        $preExitStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $rollbackSnapshot = Get-CorrelatedLayerSnapshot -Layer $Layer -LiveStatus $preExitStatus
    }
    $result = Exit-TitlerScene -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-AirTimeout)
    if ($result.Success) {
        if ($rollbackSnapshot) { Set-RollbackCandidate -Layer $Layer -RestoreSnapshot $rollbackSnapshot -ExpectedState hidden -ActorUserId $UserId }
        Sync-LayerAfterOperatorAction -Layer $Layer -Reason 'after-exit' | Out-Null
        Write-BridgeLog "User $UserId exited scene on layer $Layer"
        Add-AuditEntry "🚪 خروج من مشهد طبقة $Layer - user $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم الخروج من المشهد على الطبقة $Layer." -ReplyMarkup (Get-AfterLayerRemovalKeyboard -Layer $Layer -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل الخروج من المشهد على الطبقة $Layer : $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Start-SafeRollbackReview {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $candidate = Get-RollbackCandidate -Layer $Layer -UserId $UserId
    if (-not $candidate) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد تراجع صالح لهذه الطبقة، أو انتهت مدته.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $snapshot = $candidate.Restore
    $expected = if ([string]$candidate.ExpectedState -eq 'hidden') { 'يجب أن تبقى الطبقة فارغة' } else { 'يجب أن يبقى المشهد الحالي نفسه دون تغيير خارجي' }
    Set-PendingState -ChatId $ChatId -State @{ Mode='safe_rollback_review'; UserId=$UserId; Layer=$Layer; CandidateId=[string]$candidate.Id }
    Send-TelegramMessage -ChatId $ChatId -Text "↩️ مراجعة التراجع الآمن`nالطبقة: $Layer`nسيُستعاد القالب: $($snapshot.Key)`nشرط التنفيذ: $expected`nتنتهي الصلاحية: $(([datetime]$candidate.ExpiresAt).ToString('HH:mm:ss'))`n`nسيُفحص Cinegy مباشرة بعد التأكيد." -ReplyMarkup (Get-RollbackReviewKeyboard -Layer $Layer)
}

function Confirm-SafeRollback {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'safe_rollback_review' -or [long]$state.UserId -ne $UserId -or [int]$state.Layer -ne $Layer) { return }
    $candidate = Get-RollbackCandidate -Layer $Layer -UserId $UserId
    Clear-PendingState -ChatId $ChatId
    if (-not $candidate -or [string]$candidate.Id -ne [string]$state.CandidateId) {
        Send-TelegramMessage -ChatId $ChatId -Text 'انتهى أو تغير مرشح التراجع. لم يُرسل شيء.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    $lock = Lock-GfxLayer -Layer $Layer -ChatId $ChatId -UserId $UserId -Key ([string]$candidate.Restore.Key)
    if (-not $lock.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الطبقة قيد عملية أخرى؛ لم يُنفذ التراجع.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try {
        $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $safe = $status.Success -and $null -ne $status.IsOnAir
        if ($safe -and [string]$candidate.ExpectedState -eq 'hidden') { $safe = -not [bool]$status.IsOnAir }
        elseif ($safe) {
            $activeId = [string](Get-JsonProp $status 'ActiveId')
            $safe = [bool]$status.IsOnAir -and -not [string]::IsNullOrWhiteSpace($activeId) -and $activeId -eq [string]$candidate.ExpectedActiveId
        }
        if (-not $safe) {
            $script:RollbackCandidates.Remove($Layer) | Out-Null
            Send-TelegramMessage -ChatId $ChatId -Text '⛔ تغيرت حالة Cinegy أو تعذر التحقق منها؛ أُلغي التراجع ولم يُرسل شيء.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
            return
        }
        $restore = $candidate.Restore
        $result = Invoke-ShowTemplateResult -Key ([string]$restore.Key) -Variables ([hashtable]$restore.Variables) -ChatId $ChatId -UserId $UserId
        if ($result -and $result.Success) {
            Add-AuditEntry "↩️ تراجع آمن إلى $($restore.Key) على طبقة $Layer - user $UserId"
            Write-BridgeLog "User $UserId safely rolled layer $Layer back to '$($restore.Key)'" 'WARN'
        }
    }
    finally { Unlock-GfxLayer -ChatId $ChatId -Layer $Layer }
}

function Invoke-HideAllLayers {
    <# Emergency "get it off air" button - hides only the layers selected by
       the administrator. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $maintenanceOverride = Test-Admin -ChatId $ChatId -UserId $UserId
    $layers = @(Get-HideAllTargetLayers)
    if ($layers.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لا توجد طبقات محددة لإخفاء الكل. يضبطها المشرف من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $ok = @(); $failed = @()
    foreach ($l in $layers) {
        if (Invoke-HideLayer -Layer $l -ChatId $ChatId -UserId $UserId -Quiet -MaintenanceOverride:$maintenanceOverride) { $ok += $l } else { $failed += $l }
    }
    $script:AutoHideQueue.Clear()
    Write-BridgeLog "User $UserId triggered HIDE ALL (ok: $($ok -join ','); failed: $($failed -join ','))" "WARN"
    Add-AuditEntry "🚨 إخفاء الكل - user $UserId"
    $text = "🚨 تم إخفاء الطبقات: $($ok -join ', ')"
    if ($failed.Count -gt 0) { $text += "`n❌ فشلت: $($failed -join ', ')" }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Invoke-SetValues {
    param([Parameter(Mandatory)][hashtable]$Values, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',') -ErrorText 'maintenance mode'
        return $false
    }
    $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Values $Values -TimeoutSec (Get-AirTimeout)
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air POSTBOX XML: $($result.Xml)" }
    if ($result.Success) {
        Write-BridgeLog "User $UserId set values: $($Values.Keys -join ', ')"
        Add-AuditEntry "✏️ تحديث $($Values.Keys -join ', ') - user $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم التحديث: $($Values.Keys -join ', ')" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',')
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل التحديث: $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',') -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Start-UpdateFieldPrompt {
    param([Parameter(Mandatory)][string]$FieldName, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$FieldLimit = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'update_field'; Field = $FieldName; UserId = $UserId; FieldLimit = $FieldLimit }
    $limit = Get-EffectiveFieldLimit -FieldLimit $FieldLimit
    $limitText = if ($limit -gt 0) { " (الحد: $limit حرفًا)" } else { "" }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل القيمة الجديدة لـ '$FieldName'$limitText`:" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-UpdateField {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $limit = 0
    if ($state.ContainsKey('FieldLimit')) { $limit = [int]$state.FieldLimit }
    if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-CancelKeyboard))) { return }
    Clear-PendingState -ChatId $ChatId
    Invoke-SetValues -Values @{ $state.Field = $Value } -ChatId $ChatId -UserId $state.UserId
}

function Set-LayerAutoHide {
    <# Attaches (or replaces) an auto-hide timer on a layer that is already on
       air. Replacing rather than stacking matters: two timers on one layer
       would hide it twice, the second one possibly killing a later graphic. #>
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][int]$Seconds,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($Seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "المدة يجب أن تكون أكبر من صفر." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    foreach ($existing in @($script:AutoHideQueue | Where-Object { [int]$_.Layer -eq $Layer })) {
        $script:AutoHideQueue.Remove($existing) | Out-Null
    }
    $script:AutoHideQueue.Add(@{ Layer = $Layer; At = (Get-Date).AddSeconds($Seconds); ChatId = $ChatId; UserId = $UserId })
    Write-BridgeLog "User $UserId set an auto-hide timer of $Seconds s on layer $Layer"
    Add-AuditEntry "⏱ مؤقت $Seconds ث على طبقة $Layer - user $UserId"
    Send-TelegramMessage -ChatId $ChatId -Text "⏱ سيتم إخفاء الطبقة $Layer بعد $(Format-Duration -Seconds $Seconds)." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Complete-TimedShowCustom {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $seconds = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$seconds) -or $seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ أرسل رقمًا صحيحًا أكبر من صفر (بالثواني)." -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Start-ShowFlow -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $state.UserId -AutoHideSeconds $seconds
}

function Complete-LayerTimerCustom {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $seconds = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$seconds) -or $seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ أرسل رقمًا صحيحًا أكبر من صفر (بالثواني)." -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Set-LayerAutoHide -Layer ([int]$state.Layer) -Seconds $seconds -ChatId $ChatId -UserId $state.UserId
}

function Invoke-RepeatLastShow {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:LastShow.ContainsKey($ChatId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "لا يوجد إظهار سابق لإعادته." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $last = $script:LastShow[$ChatId]
    $templateIndex = Get-TemplateIndex -Key ([string]$last.Key)
    if ($templateIndex -lt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب السابق لم يعد موجودًا في ملف القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    Start-ShowFlow -TemplateIndex $templateIndex -ChatId $ChatId -UserId $UserId -InitialValues $last.Variables
}

function Get-MyOperationsKeyboard {
    param([Parameter(Mandatory)][long]$UserId)
    $rows = @()
    if ($script:LastShowAttempts.ContainsKey([string]$UserId)) {
        $rows += , @((New-Button '🔁 إعادة محاولة آمنة' 'ops:retry'))
    }
    $rows += , @((New-Button '🔄 تحديث' 'menu:myops'), (New-Button '🏠 القائمة' 'menu:main'))
    return @{ inline_keyboard = $rows }
}

function Test-NewsTickerFilePathSetting {
    param([AllowEmptyString()][string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) { return $false }
    if (-not [IO.Path]::GetExtension($Path).Equals('.txt', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    try { [void][IO.Path]::GetFullPath($Path); return $true } catch { return $false }
}

function Invoke-MyOperationsCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $history = @(Get-UserOperationHistory -UserId $UserId | Select-Object -Last 10)
    if ($history.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا توجد عمليات تحكم مسجلة لك منذ آخر تشغيل.' -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('🧾 آخر عملياتك:')
    foreach ($item in $history) {
        $icon = switch ([string]$item.Result) { 'success' { '✅' }; 'blocked' { '⛔' }; default { '❌' } }
        $target = if ([string]::IsNullOrWhiteSpace([string]$item.Target)) { '-' } else { [string]$item.Target }
        $advice = if ([string]$item.Result -eq 'failed') { ' — افحص الاتصال ثم أعد المحاولة' } elseif ([string]$item.Result -eq 'blocked') { ' — راجع السياسة أو حالة Cinegy' } else { '' }
        $lines.Add("$icon $(([datetime]$item.At).ToString('HH:mm:ss')) $($item.Action) · $target · طبقة $($item.Layer) · $($item.DurationMs)ms$advice")
    }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
}

function Invoke-RetryLastShowAttempt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $key = [string]$UserId
    if (-not $script:LastShowAttempts.ContainsKey($key)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا توجد محاولة عرض قابلة للمراجعة.' -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    $attempt = $script:LastShowAttempts[$key]
    $templateIndex = Get-TemplateIndex -Key ([string]$attempt.Key)
    if ($templateIndex -lt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text 'القالب المستخدم في المحاولة لم يعد موجودًا.' -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    Start-ShowFlow -TemplateIndex $templateIndex -ChatId $ChatId -UserId $UserId `
        -InitialValues $attempt.Variables -AutoHideSeconds ([int]$attempt.AutoHideSeconds) -ReviewImmediately
}

function Invoke-PresetShow {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $t = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $t -or $PresetIndex -ge $t.Presets.Count) {
        Send-TelegramMessage -ChatId $ChatId -Text "النص الجاهز غير موجود." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $preset = $t.Presets[$PresetIndex]
    $variables = @{}
    for ($i = 0; $i -lt $t.Fields.Count -and $i -lt $preset.Values.Count; $i++) {
        $variables[[string]$t.Fields[$i]] = [string]$preset.Values[$i]
    }
    Start-ShowFlow -TemplateIndex $TemplateIndex -ChatId $ChatId -UserId $UserId -InitialValues $variables -ReviewImmediately
}

function Show-PresetAdminTemplate {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب لم يعد موجودًا." -ReplyMarkup (Get-PresetAdminTemplatesKeyboard)
        return
    }
    Send-TelegramMessage -ChatId $ChatId -Text "⚡ النصوص الجاهزة للقالب '$($template.Key)'`nاختر نصًا لإدارته أو أنشئ نصًا جديدًا:" -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $TemplateIndex)
}

function Show-PresetAdminReview {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    $actionLabel = switch ([string]$State.Action) {
        'create' { 'إنشاء' }; 'edit' { 'تعديل القيم' }; 'rename' { 'إعادة تسمية' }; 'delete' { 'حذف' }
    }
    $lines = @("🔎 مراجعة تغيير النص الجاهز", "العملية: $actionLabel", "القالب: $($State.TemplateKey)")
    if ($State.Name) { $lines += "الاسم: $($State.Name)" }
    if ($State.Action -in @('create', 'edit')) {
        for ($i = 0; $i -lt @($State.Fields).Count; $i++) {
            $value = if ($i -lt @($State.Values).Count) { [string]$State.Values[$i] } else { '' }
            $lines += "• $($State.Fields[$i]): $value"
        }
    }
    $lines += ''
    $lines += 'لن يُعدّل ملف القوالب حتى تضغط حفظ التغيير.'
    $State.Mode = 'preset_admin_review'
    Set-PendingState -ChatId $ChatId -State $State
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-PresetReviewKeyboard)
}

function Start-PresetAdminCreate {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { return }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'preset_admin_name'; Action = 'create'; TemplateIndex = $TemplateIndex
        TemplateKey = [string]$template.Key; PresetIndex = -1; UserId = $UserId
        Fields = @($template.Fields); Values = @(); Name = ''; Index = 0
    }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل اسم النص الجاهز الجديد للقالب '$($template.Key)':" -ReplyMarkup (Get-CancelKeyboard)
}

function Start-PresetAdminEditValues {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template -or $PresetIndex -lt 0 -or $PresetIndex -ge @($template.Presets).Count) { return }
    $state = @{
        Mode = 'preset_admin_values'; Action = 'edit'; TemplateIndex = $TemplateIndex
        TemplateKey = [string]$template.Key; PresetIndex = $PresetIndex; UserId = $UserId
        Fields = @($template.Fields); Values = @(); Name = [string]$template.Presets[$PresetIndex].Name; Index = 0
    }
    if ($state.Fields.Count -eq 0) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل (1/$($state.Fields.Count)):`n$($state.Fields[0])" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-PresetAdminText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    if ($state.Mode -eq 'preset_admin_name') {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            Send-TelegramMessage -ChatId $ChatId -Text "الاسم لا يمكن أن يكون فارغًا." -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.Name = $Value.Trim()
        if ($state.Action -eq 'rename') { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        $state.Mode = 'preset_admin_values'
        if ($state.Fields.Count -eq 0) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل (1/$($state.Fields.Count)):`n$($state.Fields[0])" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    if ($state.Mode -eq 'preset_admin_values') {
        $state.Values = @($state.Values) + @([string]$Value)
        $state.Index = [int]$state.Index + 1
        if ($state.Index -ge $state.Fields.Count) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل ($($state.Index + 1)/$($state.Fields.Count)):`n$($state.Fields[$state.Index])" -ReplyMarkup (Get-CancelKeyboard)
    }
}

function Confirm-PresetAdminChange {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'preset_admin_review' -or [long]$state.UserId -ne $UserId) {
        Send-TelegramMessage -ChatId $ChatId -Text "انتهت مراجعة التغيير. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $templateIndex = [int]$state.TemplateIndex
    $result = Save-TemplatePresetChange -TemplateKey ([string]$state.TemplateKey) -PresetIndex ([int]$state.PresetIndex) -Action ([string]$state.Action) -Name ([string]$state.Name) -Values @($state.Values)
    Clear-PendingState -ChatId $ChatId
    if ($result.Success) {
        Write-BridgeLog "Admin $UserId applied preset $($state.Action) to template '$($state.TemplateKey)'"
        Add-AuditEntry "⚡ Preset $($state.Action) / $($state.TemplateKey) - admin $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم حفظ تغيير النص الجاهز، وأُنشئت نسخة احتياطية." -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $templateIndex)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ التغيير: $($result.Error)" -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $templateIndex)
    }
}

function Invoke-TemplatesCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $store = Get-TemplateStore
    if ($store.Order.Count -eq 0) {
        $text = "لا توجد قوالب معرّفة حاليًا."
        if ($store.Errors.Count -gt 0) { $text += "`n⚠️ " + ($store.Errors -join "`n⚠️ ") }
        Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $lines = foreach ($key in $store.Order) {
        $t = $store.Map[$key]
        "$($t.Key) (طبقة $($t.Layer)): $($t.Description)  الحقول: $($t.Fields -join ', ')"
    }
    $text = ($lines -join "`n")
    if ($store.Errors.Count -gt 0) { $text += "`n`n⚠️ " + ($store.Errors -join "`n⚠️ ") }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Get-AirTimeout {
    <# Air Pro sits on localhost or the local LAN, so the module's 10s default
       is far too generous: every graphics command blocks the single polling
       loop for its full timeout, and 🚨 إخفاء الكل multiplies that by the
       number of layers - on the one button that gets pressed in a crisis. #>
    $value = Get-SettingInt 'AirCommandTimeoutSeconds' 1
    if ($value -le 0) { $value = 3 }
    return $value
}

function Get-OnAirSummary {
    <# Shows the bridge's tracked layers after they have been reconciled with
       Cinegy. Externally started scenes cannot be named reliably, but a scene
       hidden outside the bridge is removed by Update-OnAirStateFromCinegy. #>
    if ($script:OnAir.Count -eq 0) { return "📺 المشاهد النشطة`n• لا توجد مشاهد على الهواء حسب آخر فحص." }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('📺 المشاهد النشطة')
    foreach ($layer in ($script:OnAir.Keys | Sort-Object)) {
        $info = $script:OnAir[$layer]
        $age = [math]::Max(0, [int]((Get-Date) - $info.At).TotalSeconds)
        $ageText = if ($age -ge 60) { "$([int]($age / 60)) دقيقة" } else { "$age ثانية" }
        $source = [string](Get-JsonProp $info 'Source')
        if ($source -eq 'cinegy') {
            $eventName = [string](Get-JsonProp $info 'CinegyEventName')
            $detail = "   المصدر: Cinegy Air · منذ $ageText"
            if ($eventName) { $detail += " · الحدث: $eventName" }
            $lines.Add("🟣 $(Get-LayerDisplayName -Layer ([int]$layer)) · $($info.Key)")
            $lines.Add($detail)
        }
        else {
            $operator = if ($null -ne $info.UserId -and [long]$info.UserId -gt 0) { Get-UserDisplayName -UserId ([long]$info.UserId) } else { 'غير معروف' }
            $lines.Add("🔵 $(Get-LayerDisplayName -Layer ([int]$layer)) · $($info.Key)")
            $lines.Add("   المصدر: Bot · المستخدم: $operator · منذ $ageText")
        }
    }
    return ($lines -join "`n")
}

function Invoke-StatusCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (Test-UserDisabled -UserId $UserId) { return $false }
    $store = Get-TemplateStore
    $layerStatuses = @(Get-CinegyLayerDashboard)
    $sync = Update-OnAirStateFromCinegy -Reason 'status' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal

    # Quick overall line so a non-admin glance shows whether anything is off.
    if ($sync.Failed.Count -gt 0) {
        $overall = "🟠 تعذّر فحص بعض الطبقات"
    }
    elseif ($script:OnAir.Count -gt 0) {
        $overall = "🟠 طبقات على الهواء"
    }
    else {
        $overall = "🟢 كل شيء سليم"
    }

    $sep = '━━━━━━━━━━━━━━━━━'
    $now = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("ℹ️ الحالة — v$($script:BridgeVersion)")
    $lines.Add("🕒 $($now.ToString('yyyy-MM-dd HH:mm:ss')) (محلي)")
    $lines.Add($overall)
    $lines.Add('')
    $lines.Add($sep)
    $lines.Add("🌐 $($config.AirServerAddress) · القناة $($config.AirChannelNumber) · القوالب: $($store.Order.Count)")
    $sharedLayers = Get-JsonProp $store 'SharedLayers'
    if ($sharedLayers -and $sharedLayers.Count -gt 0) {
        $sharedText = @($sharedLayers.Keys | Sort-Object {[int]$_} | ForEach-Object { "طبقة ${_}: $(@($sharedLayers[$_]) -join '، ')" }) -join ' | '
        $lines.Add("ℹ️ طبقات مشتركة بين عدة قوالب (مسموح): $sharedText")
    }
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: $($freshness.Label)")
    if ($lastSuccessfulAt) {
        $lines.Add("🔄 آخر فحص ناجح: $(([datetime]$lastSuccessfulAt).ToString('yyyy-MM-dd HH:mm:ss'))")
    }
    $lines.Add((Get-OnAirSummary))
    $lines.Add('')
    $lines.Add($sep)
    if ($sync.Failed.Count -gt 0) {
        $lines.Add("⚠️ تعذّر فحص طبقات Cinegy: $($sync.Failed -join '، ') — تم الاحتفاظ بالحالة السابقة.")
    }
    elseif ($sync.Removed.Count -gt 0) {
        $lines.Add("🔄 تم تحديث الحالة وأُزيلت الطبقات المخفية خارجيًا: $($sync.Removed -join '، ')")
    }
    else {
        $lines.Add("✅ الحالة متزامنة مع Cinegy.")
    }
    if ($store.Errors.Count -gt 0) { $lines.Add("⚠️ " + ($store.Errors -join "`n⚠️ ")) }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Request-HideAllConfirmation {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    $layers = @(Get-HideAllTargetLayers)
    if ($layers.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لا توجد طبقات محددة لإخفاء الكل. يضبطها المشرف من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'hide_all_review'; UserId = $UserId; Layers = $layers
    }
    $labels = @($layers | ForEach-Object { Get-LayerDisplayName -Layer ([int]$_) })
    Send-TelegramMessage -ChatId $ChatId -Text "⚠️ سيتم إخفاء الطبقات المحددة: $($labels -join '، '). هل أنت متأكد؟" -ReplyMarkup (Get-HideAllConfirmKeyboard)
}

function Get-HealthStatusReport {
    $telegramWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $telegramOk = $false
    $telegramError = ''
    try {
        $probe = Invoke-RestMethod -Uri "$apiBase/getMe" -Method Get -TimeoutSec 3
        $telegramOk = [bool](Get-JsonProp $probe 'ok')
        if (-not $telegramOk) { $telegramError = 'رد غير صالح' }
    }
    catch { $telegramError = $_.Exception.Message }
    $telegramWatch.Stop()

    $cinegyWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $telemetry = Get-AirTelemetryStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    $cinegyWatch.Stop()

    $checkedAt = Get-Date
    if ($telegramOk) { $script:HealthHistory.Telegram.LastSuccess = $checkedAt }
    else {
        $script:HealthHistory.Telegram.LastError = Protect-SensitiveText $telegramError
        $script:HealthHistory.Telegram.LastErrorAt = $checkedAt
    }
    if ($telemetry.Success) { $script:HealthHistory.Cinegy.LastSuccess = $checkedAt }
    else {
        $script:HealthHistory.Cinegy.LastError = [string](Get-JsonProp $telemetry 'Error')
        if ([string]::IsNullOrWhiteSpace($script:HealthHistory.Cinegy.LastError)) { $script:HealthHistory.Cinegy.LastError = 'تعذّر الوصول' }
        $script:HealthHistory.Cinegy.LastErrorAt = $checkedAt
    }

    $telegramLine = if ($telegramOk) { "✅ Telegram: $($telegramWatch.ElapsedMilliseconds)ms" }
    else { "❌ Telegram: $($telegramWatch.ElapsedMilliseconds)ms — $(Protect-SensitiveText $telegramError)" }
    $cinegyLine = if ($telemetry.Success) { "✅ Cinegy: $($cinegyWatch.ElapsedMilliseconds)ms" }
    else { "❌ Cinegy: $($cinegyWatch.ElapsedMilliseconds)ms — تعذّر الوصول" }
    $historyLines = foreach ($service in @('Telegram', 'Cinegy')) {
        $history = $script:HealthHistory[$service]
        $lastSuccess = if ($history.LastSuccess) { ([datetime]$history.LastSuccess).ToString('yyyy-MM-dd HH:mm:ss') } else { 'لا يوجد' }
        $lastError = if ($history.LastErrorAt) {
            "$($history.LastError) — $(([datetime]$history.LastErrorAt).ToString('yyyy-MM-dd HH:mm:ss'))"
        }
        else { 'لا يوجد' }
        $failureCount = [int]$history.FailureCount
        $outage = if ($history.OutageStartedAt) { ([datetime]$history.OutageStartedAt).ToString('yyyy-MM-dd HH:mm:ss') } else { 'لا يوجد' }
        "$service — آخر نجاح: $lastSuccess | آخر خطأ: $lastError | فشل متتالٍ: $failureCount | بداية الانقطاع: $outage"
    }
    $historyText = $historyLines -join "`n"
    $text = @(
        "💚 صحة الخدمات",
        $telegramLine,
        $cinegyLine,
        "",
        $historyText,
        "",
        (Format-CinegyTelemetryStatus -Telemetry $telemetry)
    ) -join "`n"
    return [pscustomobject]@{ Text = $text; Telemetry = $telemetry }
}

function Show-TemplateAdminDetail {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text 'القالب لم يعد موجودًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $lines = @(
        "📚 تفاصيل القالب: $($template.Key)",
        "المسار: $($template.Path)",
        "الطبقة: $($template.Layer)",
        "الترتيب: $($template.Order)",
        "الوصف: $($template.Description)",
        "الحقول: $(if (@($template.Fields).Count -gt 0) { $template.Fields -join '، ' } else { 'لا توجد' })",
        "النصوص الجاهزة: $(@($template.Presets).Count)"
    )
    if (Get-Setting 'EnableFullTemplateManagement') {
        $lines += '✅ التحكم الكامل بالقوالب مفعّل. اختر عملية التعديل من الأزرار.'
    }
    else {
        $lines += '🔒 التحكم الكامل معطّل. يمكنك القراءة وإدارة النصوص الجاهزة فقط.'
    }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex)
}

function Start-TemplateDefinitionPrompt {
    param([Parameter(Mandatory)][ValidateSet('create', 'edit', 'delete')][string]$Action, [int]$TemplateIndex = -1, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Get-Setting 'EnableFullTemplateManagement')) {
        Send-TelegramMessage -ChatId $ChatId -Text '🔒 التحكم الكامل بالقوالب معطّل من الإعدادات.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $template = if ($TemplateIndex -ge 0) { Get-TemplateByIndex -Index $TemplateIndex } else { $null }
    if ($Action -ne 'create' -and -not $template) { Send-TelegramMessage -ChatId $ChatId -Text 'القالب لم يعد موجودًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard); return }
    if ($Action -eq 'delete') {
        Set-PendingState -ChatId $ChatId -State @{ Mode='template_definition_review'; Action='delete'; TemplateKey=$template.Key; Definition=@{}; UserId=$UserId }
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ مراجعة حذف القالب '$($template.Key)'. لن يُحذف إذا كان على الهواء أو ضمن جدولة قادمة." -ReplyMarkup (Get-TemplateDefinitionReviewKeyboard)
        return
    }
    $example = if ($Action -eq 'create') { '{"key":"new-template","path":"titles/new.cintitle","layer":4,"fields":["Headline.Text"]}' } else { "{`"path`":`"$($template.Path)`",`"layer`":$($template.Layer),`"fields`":[]}" }
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_definition_json'; Action=$Action; TemplateKey=if ($template) { $template.Key } else { '' }; UserId=$UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل تعريف القالب بصيغة JSON في رسالة واحدة.`nمثال:`n$example" -ReplyMarkup (Get-CancelKeyboard)
}

function Get-TemplateDefinitionComparisonText {
    param($Existing, [Parameter(Mandatory)][hashtable]$Definition)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($name in @('path', 'layer', 'order', 'description', 'category', 'fields')) {
        if (-not $Definition.ContainsKey($name)) { continue }
        [string]$oldJson = if ($Existing) { Get-JsonProp $Existing $name | ConvertTo-Json -Depth 10 -Compress } else { '<غير موجود>' }
        [string]$newJson = $Definition[$name] | ConvertTo-Json -Depth 10 -Compress
        if ([string]::IsNullOrEmpty($oldJson)) { $oldJson = 'null' }
        if ([string]::IsNullOrEmpty($newJson)) { $newJson = 'null' }
        if ($oldJson -ne $newJson) {
            $oldDisplay = if ($oldJson.Length -gt 120) { $oldJson.Substring(0,117) + '...' } else { $oldJson }
            $newDisplay = if ($newJson.Length -gt 120) { $newJson.Substring(0,117) + '...' } else { $newJson }
            $lines.Add("• $name`n  قبل: $oldDisplay`n  بعد: $newDisplay")
        }
    }
    if ($lines.Count -eq 0) { return 'الاختلافات: لا توجد تغييرات فعلية.' }
    return "الاختلافات:`n$($lines -join "`n")"
}

function Complete-TemplateDefinitionJson {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'template_definition_json') { return }
    try { $definition = $Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { Send-TelegramMessage -ChatId $ChatId -Text '❌ JSON غير صالح. أرسل تعريفًا صحيحًا أو ألغِ العملية.' -ReplyMarkup (Get-CancelKeyboard); return }
    $key = [string]$state.TemplateKey
    if ($state.Action -eq 'create') { $key = [string](Get-JsonProp $definition 'key'); $definition.Remove('key') }
    if ([string]::IsNullOrWhiteSpace($key)) { Send-TelegramMessage -ChatId $ChatId -Text '❌ يتطلب القالب الجديد مفتاح key.' -ReplyMarkup (Get-CancelKeyboard); return }
    $state.Mode = 'template_definition_review'; $state.TemplateKey = $key; $state.Definition = $definition
    Set-PendingState -ChatId $ChatId -State $state
    $existing = if ($state.Action -eq 'edit') { Get-JsonProp (Get-Content -LiteralPath (Get-TemplateRegistryFilePath) -Raw | ConvertFrom-Json) $key } else { $null }
    $comparison = Get-TemplateDefinitionComparisonText -Existing $existing -Definition $definition
    Send-TelegramMessage -ChatId $ChatId -Text "🔎 مراجعة $($state.Action) للقالب '$key'`nالمسار: $($definition.path)`nالطبقة: $($definition.layer)`n`n$comparison`n`nلن يُحفظ شيء قبل التأكيد، وستُنشأ نسخة احتياطية من التعريفات الحالية." -ReplyMarkup (Get-TemplateDefinitionReviewKeyboard)
}

function Confirm-TemplateDefinitionChange {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'template_definition_review' -or [long]$state.UserId -ne $UserId) { return }
    Clear-PendingState -ChatId $ChatId
    $result = Save-TemplateDefinitionChange -TemplateKey ([string]$state.TemplateKey) -Action ([string]$state.Action) -Definition ([hashtable]$state.Definition)
    if ($result.Success) { Add-AuditEntry "📚 $($state.Action) قالب $($state.TemplateKey) - user $UserId"; Send-TelegramMessage -ChatId $ChatId -Text '✅ تم حفظ تعريف القالب مع نسخة احتياطية.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
    else { Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ القالب: $($result.Error)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
}

function Invoke-FullStatusCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "هذا الأمر مخصص للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $store = Get-TemplateStore
    $layerStatuses = @(Get-CinegyLayerDashboard)
    $sync = Update-OnAirStateFromCinegy -Reason 'full-status' -LayerStatuses $layerStatuses `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal
    $health = Get-HealthStatusReport
    # Overall status line derived from the live signals so a quick glance at
    # the top of the message tells the operator whether anything needs attention.
    if ($sync.Failed.Count -gt 0) {
        $overall = "🔴 لا يمكن فحص بعض الطبقات"
    }
    elseif (-not $health.Telemetry.Success) {
        $overall = "🟠 Cinegy غير متاح"
    }
    elseif ($script:OnAir.Count -gt 0) {
        $overall = "🟠 طبقات على الهواء"
    }
    else {
        $overall = "🟢 كل شيء سليم"
    }

    $now = Get-Date
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("📊 الحالة الكاملة — v$($script:BridgeVersion)")
    $lines.Add("🕒 $($now.ToString('yyyy-MM-dd HH:mm:ss')) (محلي)")
    $lines.Add($overall)
    $lines.Add('')
    $lines.Add((Get-OnAirSummary))
    $lines.Add('')
    $lines.Add('🎛 اتصال Cinegy')
    $lines.Add("🌐 $($config.AirServerAddress) · القناة $($config.AirChannelNumber) · القوالب: $($store.Order.Count)")
    $lastSuccessfulAt = Get-JsonProp $sync 'LastSuccessfulAt'
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccessfulAt -FailedCount @($sync.Failed).Count `
        -Now $now -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    $lines.Add("📶 حالة بيانات Cinegy: $($freshness.Label)")
    $lines.Add((Format-CinegyLayerDashboard -LayerStatuses $layerStatuses))
    $lines.Add('')
    $lines.Add('🩺 صحة الخدمات')
    $lines.Add($health.Text)
    $lines.Add('')
    $lines.Add('⚙️ التشغيل والجدولة')
    $lines.Add("📡 البث المباشر: $(Get-LiveRelayStatusText)")
    $lines.Add("🖼 الصور المعلّقة: $($script:SnapshotJobs.Count) · مؤقتات الإخفاء: $($script:AutoHideQueue.Count)")
    $lines.Add("🗓 الأحداث المجدولة القادمة: $(@(Get-UpcomingScheduleEvents).Count)")
    $lines.Add('')
    $lines.Add('👥 الوصول')
    $lines.Add("🔐 المستخدمون المصرح لهم: $(@(Get-JsonProp $config 'AllowedChatIds').Count) محادثة / $(@(Get-JsonProp $config 'AllowedUserIds').Count) مستخدم")
    $lines.Add("🔔 طلبات الوصول المعلّقة: $($script:PendingApprovals.Count)")
    $lines.Add('')
    if ($sync.Failed.Count -gt 0) {
        $lines.Add("⚠️ تعذّر فحص طبقات Cinegy: $($sync.Failed -join '، ') — تم الاحتفاظ بالحالة السابقة.")
    }
    elseif ($sync.Removed.Count -gt 0) {
        $lines.Add("🔄 أُزيلت الطبقات المخفية خارجيًا: $($sync.Removed -join '، ')")
    }
    else { $lines.Add("✅ حالة Cinegy متزامنة.") }
    if ($store.Errors.Count -gt 0) { $lines.Add("⚠️ " + ($store.Errors -join "`n⚠️ ")) }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Invoke-HealthCommand {
    <# Backward-compatible typed alias. Health is no longer a separate public
       screen; administrators receive it inside the full status report. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Invoke-FullStatusCommand -ChatId $ChatId -UserId $UserId
}

function Get-BridgeDiagnosticsSnapshot {
    $process = Get-Process -Id $PID
    $scriptFile = Join-Path $scriptRoot 'TelegramBridge.ps1'
    $buildTime = if (Test-Path -LiteralPath $scriptFile) { (Get-Item -LiteralPath $scriptFile).LastWriteTimeUtc } else { $null }
    $fileSizes = [ordered]@{}
    foreach ($path in @($ConfigPath, (Get-TemplateRegistryFilePath), $onAirFile, $script:scheduleFile, $script:scheduleExecutionFile, $script:auditFile, $logPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }
        $name = [IO.Path]::GetFileName([string]$path)
        $fileSizes[$name] = if (Test-Path -LiteralPath $path) { [long](Get-Item -LiteralPath $path).Length } else { 0L }
    }
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($scriptRoot)).TrimEnd('\', '/')
    $driveName = $root.TrimEnd(':')
    $drive = Get-PSDrive -Name $driveName -ErrorAction SilentlyContinue
    $runtimeStorageBytes = 0L
    foreach ($runtimeFile in @(Get-ChildItem -LiteralPath $script:logDir -File -ErrorAction SilentlyContinue)) {
        $length = Get-JsonProp $runtimeFile 'Length'
        if ($null -ne $length) { $runtimeStorageBytes += [long]$length }
    }
    $backupStorageBytes = 0L
    foreach ($backupDir in @("$ConfigPath.backups", "$(Get-TemplateRegistryFilePath).backups")) {
        if (Test-Path -LiteralPath $backupDir) {
            foreach ($backupFile in @(Get-ChildItem -LiteralPath $backupDir -File -Recurse -ErrorAction SilentlyContinue)) {
                $length = Get-JsonProp $backupFile 'Length'
                if ($null -ne $length) { $backupStorageBytes += [long]$length }
            }
        }
    }
    return [pscustomobject]@{
        BuildTimeUtc  = $buildTime
        ProcessStart  = $process.StartTime
        Uptime        = (Get-Date) - $process.StartTime
        Processor     = if ($env:PROCESSOR_IDENTIFIER) { $env:PROCESSOR_IDENTIFIER } else { [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() }
        WorkingSetMB  = [math]::Round($process.WorkingSet64 / 1MB, 1)
        PrivateMemoryMB = [math]::Round($process.PrivateMemorySize64 / 1MB, 1)
        DiskFreeGB    = if ($drive) { [math]::Round([double]$drive.Free / 1GB, 2) } else { $null }
        RuntimeStorageBytes = $runtimeStorageBytes
        BackupStorageBytes = $backupStorageBytes
        FileSizes     = $fileSizes
        AirOperations = [pscustomobject]@{
            Success = [int]$script:AirOperationCounters.Success
            Failed  = [int]$script:AirOperationCounters.Failed
            Blocked = [int]$script:AirOperationCounters.Blocked
        }
    }
}

function Start-TemplateTestReview {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId) -or -not (Get-Setting 'EnableFullTemplateManagement')) { return }
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { Send-TelegramMessage -ChatId $ChatId -Text 'القالب لم يعد موجودًا.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard); return }
    $testLayer = Get-SettingInt 'TemplateTestLayer' 0
    if ($testLayer -le 0) { Send-TelegramMessage -ChatId $ChatId -Text 'طبقة تجربة القوالب معطلة. اضبط TemplateTestLayer أولاً.' -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex); return }
    if (@(Get-KnownLayers | ForEach-Object { [int]$_ }) -contains $testLayer) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ طبقة التجربة $testLayer مستخدمة كطبقة إنتاج في سجل القوالب. اختر طبقة مستقلة." -ReplyMarkup (Get-TemplateAdminDetailKeyboard -TemplateIndex $TemplateIndex)
        return
    }
    $seconds = [math]::Min(300, (Get-SettingInt 'TemplateTestAutoHideSeconds' 3))
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_test_review'; UserId=$UserId; TemplateIndex=$TemplateIndex; TestLayer=$testLayer; AutoHideSeconds=$seconds }
    Send-TelegramMessage -ChatId $ChatId -Text "🧪 مراجعة اختبار القالب '$($template.Key)'`nطبقة التجربة المستقلة: $testLayer`nقيم الحقول: TEST`nالإخفاء التلقائي: $seconds ثانية`n`nسيُفحص أن الطبقة فارغة مباشرة قبل الاختبار." -ReplyMarkup (Get-TemplateTestReviewKeyboard)
}

function Confirm-TemplateTest {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_test_review' -or [long]$state.UserId -ne $UserId) { return }
    Clear-PendingState -ChatId $ChatId
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    $template = Get-TemplateByIndex -Index ([int]$state.TemplateIndex)
    $testLayer = Get-SettingInt 'TemplateTestLayer' 0
    if (-not $template -or $testLayer -le 0 -or $testLayer -ne [int]$state.TestLayer -or
        (@(Get-KnownLayers | ForEach-Object { [int]$_ }) -contains $testLayer)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تغيّر تعريف القالب أو طبقة التجربة. ابدأ المراجعة من جديد.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $testLayer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not $status.Success -or $null -eq $status.IsOnAir) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ تعذر التأكد من فراغ طبقة التجربة $testLayer؛ لم يُرسل شيء." -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    if ([bool]$status.IsOnAir) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ طبقة التجربة $testLayer مشغولة حاليًا؛ أخفها أو اختر طبقة أخرى." -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $variables = @{}
    foreach ($field in @($template.Fields)) { $variables[[string]$field] = 'TEST' }
    $types = @{}
    foreach ($field in @($template.FieldTypes.Keys)) { if ($template.FieldTypes[$field]) { $types[$field] = [string]$template.FieldTypes[$field] } }
    $result = Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $testLayer -TemplatePath ([string]$template.Path) -Variables $variables -Types $types `
        -DefaultType ([string](Get-Setting 'AirVariableType')) -TimeoutSec (Get-AirTimeout)
    if (-not $result.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل اختبار القالب: $($result.Error)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    $script:OnAir[$testLayer] = @{ Key="[TEST] $($template.Key)"; At=(Get-Date); UserId=$UserId; ActiveId=[string]$result.EventId; Source='BotTest' }
    Save-OnAirState
    $seconds = [math]::Max(3, [math]::Min(300, [int]$state.AutoHideSeconds))
    $script:AutoHideQueue.Add(@{ Layer=$testLayer; At=(Get-Date).AddSeconds($seconds); ChatId=$ChatId; UserId=$UserId })
    Write-BridgeLog "Admin $UserId tested template '$($template.Key)' on isolated layer $testLayer for $seconds seconds" 'WARN'
    Add-AuditEntry "🧪 اختبار قالب $($template.Key) على طبقة $testLayer - user $UserId"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ بدأ اختبار '$($template.Key)' على طبقة التجربة $testLayer وسيُخفى خلال $seconds ثانية." -ReplyMarkup (Get-AfterShowKeyboard -Layer $testLayer -ChatId $ChatId -UserId $UserId)
}

function Test-TemplateRegistryImport {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $rawText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([Text.Encoding]::UTF8.GetByteCount($rawText) -gt 1048576) { throw 'الملف أكبر من 1 ميغابايت.' }
        $document = $rawText | ConvertFrom-Json -ErrorAction Stop
        $properties = @($document.PSObject.Properties)
        if ($properties.Count -eq 0 -or $properties.Count -gt 200) { throw 'يجب أن يحتوي السجل بين قالب واحد و200 قالب.' }
        foreach ($property in $properties) {
            if ($property.Name -notmatch '^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$') { throw "مفتاح القالب '$($property.Name)' غير صالح." }
            $entry = $property.Value
            $templatePath = [string](Get-JsonProp $entry 'path')
            if ([string]::IsNullOrWhiteSpace($templatePath) -or -not [IO.Path]::IsPathRooted($templatePath) -or
                -not [IO.Path]::GetExtension($templatePath).Equals('.cintitle', [StringComparison]::OrdinalIgnoreCase)) {
                throw "القالب '$($property.Name)' يحتاج مسارًا مطلقًا لملف .cintitle."
            }
            $layer = 0
            if (-not [int]::TryParse([string](Get-JsonProp $entry 'layer'), [ref]$layer) -or $layer -le 0) {
                throw "القالب '$($property.Name)' يحتاج رقم طبقة موجبًا."
            }
            foreach ($field in @(Get-JsonProp $entry 'fields' | Where-Object { $null -ne $_ })) {
                $fieldName = if ($field -is [string]) { [string]$field } else { [string](Get-JsonProp $field 'name') }
                if ([string]::IsNullOrWhiteSpace($fieldName)) { throw "القالب '$($property.Name)' يحتوي حقلاً بلا اسم." }
            }
        }
        return [pscustomobject]@{ Success=$true; Error=''; Document=$document; Count=$properties.Count }
    }
    catch { return [pscustomobject]@{ Success=$false; Error=Protect-SensitiveText $_.Exception.Message; Document=$null; Count=0 } }
}

function Get-TemplateRegistryImportComparison {
    param([Parameter(Mandatory)]$Current, [Parameter(Mandatory)]$Imported)
    $currentNames = @($Current.PSObject.Properties.Name)
    $importedNames = @($Imported.PSObject.Properties.Name)
    $added = @($importedNames | Where-Object { $currentNames -notcontains $_ })
    $removed = @($currentNames | Where-Object { $importedNames -notcontains $_ })
    $changed = @($importedNames | Where-Object {
        $currentNames -contains $_ -and
        ((Get-JsonProp $Current $_ | ConvertTo-Json -Depth 20 -Compress) -ne (Get-JsonProp $Imported $_ | ConvertTo-Json -Depth 20 -Compress))
    })
    $unchanged = @($importedNames | Where-Object { $currentNames -contains $_ -and $changed -notcontains $_ })
    return [pscustomobject]@{ Added=$added; Removed=$removed; Changed=$changed; Unchanged=$unchanged }
}

function Start-TemplateRegistryImport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Get-Setting 'EnableFullTemplateManagement')) {
        Send-TelegramMessage -ChatId $ChatId -Text '🔒 فعّل إدارة القوالب الكاملة أولاً.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Set-PendingState -ChatId $ChatId -State @{ Mode='template_import_upload'; UserId=$UserId }
    Send-TelegramMessage -ChatId $ChatId -Text '📥 أرسل ملف JSON واحدًا (بحد أقصى 1 ميغابايت). سيُفحص ويُعرض الفرق قبل أي استبدال.' -ReplyMarkup (Get-CancelKeyboard)
}

function Invoke-TemplateRegistryExport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return }
    $path = Get-TemplateRegistryFilePath
    if (Send-TelegramDocument -ChatId $ChatId -FilePath $path -Caption '📤 نسخة تعريفات القوالب. لا تحتوي حالة الهواء أو قيم النصوص المستخدمة.') {
        Add-AuditEntry "📤 تصدير تعريفات القوالب - user $UserId"
    }
}

function Receive-TemplateRegistryImport {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_import_upload' -or [long]$state.UserId -ne $UserId -or
        -not (Test-Admin -ChatId $ChatId -UserId $UserId)) { return }
    $fileName = [string](Get-JsonProp $Document 'file_name')
    $fileSize = [long](Get-JsonProp $Document 'file_size')
    if (-not $fileName.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -or $fileSize -le 0 -or $fileSize -gt 1048576) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ يجب رفع ملف JSON حجمه بين 1 بايت و1 ميغابايت.' -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $stagingDirectory = Join-Path $script:logDir 'template-imports'
    $stagedPath = Join-Path $stagingDirectory "staged-$([guid]::NewGuid().ToString('N')).json"
    try {
        Receive-TelegramDocument -FileId ([string](Get-JsonProp $Document 'file_id')) -DestinationPath $stagedPath -MaximumBytes 1048576 | Out-Null
        $validation = Test-TemplateRegistryImport -Path $stagedPath
        if (-not $validation.Success) { throw $validation.Error }
        $current = Get-Content -LiteralPath (Get-TemplateRegistryFilePath) -Raw | ConvertFrom-Json
        $comparison = Get-TemplateRegistryImportComparison -Current $current -Imported $validation.Document
        $state = @{ Mode='template_import_review'; UserId=$UserId; ImportStagedPath=$stagedPath }
        Set-PendingState -ChatId $ChatId -State $state
        $summary = "🔎 مراجعة استيراد القوالب`nالإجمالي: $($validation.Count)`nمضاف: $($comparison.Added.Count)`nمعدّل: $($comparison.Changed.Count)`nمحذوف: $($comparison.Removed.Count)`nبلا تغيير: $($comparison.Unchanged.Count)`n`nلن يُستبدل الملف حتى التأكيد."
        Send-TelegramMessage -ChatId $ChatId -Text $summary -ReplyMarkup @{ inline_keyboard=@(
            , @((New-Button '✅ اعتماد الاستيراد' 'timport:confirm'), (New-Button '❌ إلغاء' 'menu:templatesadmin'))
        ) }
    }
    catch {
        Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
        Send-TelegramMessage -ChatId $ChatId -Text "❌ رُفض ملف الاستيراد: $(Protect-SensitiveText $_.Exception.Message)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
    }
}

function Apply-TemplateRegistryImport {
    param([Parameter(Mandatory)][string]$StagedPath)
    $path = Get-TemplateRegistryFilePath
    $temporary = "$path.import.tmp"
    try {
        $validation = Test-TemplateRegistryImport -Path $StagedPath
        if (-not $validation.Success) { throw $validation.Error }
        $current = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $comparison = Get-TemplateRegistryImportComparison -Current $current -Imported $validation.Document
        $unsafeKeys = @($comparison.Removed + $comparison.Changed | Sort-Object -Unique)
        $liveKeys = @($script:OnAir.Values | ForEach-Object { [string](Get-JsonProp $_ 'Key') })
        $scheduledKeys = @(Get-UpcomingScheduleEvents | ForEach-Object { [string](Get-JsonProp $_ 'TemplateKey') })
        $blocked = @($unsafeKeys | Where-Object { $liveKeys -contains $_ -or $scheduledKeys -contains $_ })
        if ($blocked.Count -gt 0) { throw "لا يمكن تغيير أو حذف قالب مستخدم على الهواء أو في جدولة قادمة: $($blocked -join '، ')" }
        $backupDirectory = "$path.backups"
        New-Item -ItemType Directory -Path $backupDirectory -Force -ErrorAction Stop | Out-Null
        $backupPath = Join-Path $backupDirectory "templates-import-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force -ErrorAction Stop
        [IO.File]::WriteAllText($temporary, ($validation.Document | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        $script:TemplateCache = @{ WriteTime=[datetime]::MinValue; Path=''; Map=@{}; Order=@(); Errors=@() }
        return [pscustomobject]@{ Success=$true; Error=''; BackupPath=$backupPath; Comparison=$comparison }
    }
    catch { return [pscustomobject]@{ Success=$false; Error=Protect-SensitiveText $_.Exception.Message; BackupPath=''; Comparison=$null } }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Confirm-TemplateRegistryImport {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'template_import_review' -or [long]$state.UserId -ne $UserId) { return }
    $stagedPath = [string]$state.ImportStagedPath
    $result = Apply-TemplateRegistryImport -StagedPath $stagedPath
    Clear-PendingState -ChatId $ChatId
    if ($result.Success) {
        Add-AuditEntry "📥 استيراد تعريفات القوالب مع نسخة احتياطية - user $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text '✅ تم استيراد تعريفات القوالب وحفظ نسخة من السجل السابق.' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
    }
    else { Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر اعتماد الاستيراد: $($result.Error)" -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard) }
}

function Get-DiagnosticWarnings {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [int]$DiskFreeWarningGB = 2,
        [int]$RuntimeStorageWarningMB = 100,
        [int]$BackupStorageWarningMB = 50
    )
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Snapshot.DiskFreeGB -and [double]$Snapshot.DiskFreeGB -lt [math]::Max(1, $DiskFreeWarningGB)) {
        $warnings.Add("⚠️ مساحة القرص الحرة منخفضة: $($Snapshot.DiskFreeGB) GB")
    }
    if ([long]$Snapshot.RuntimeStorageBytes -gt ([math]::Max(1, $RuntimeStorageWarningMB) * 1MB)) {
        $warnings.Add("⚠️ حجم السجلات وملفات التشغيل تجاوز $RuntimeStorageWarningMB MB")
    }
    if ([long]$Snapshot.BackupStorageBytes -gt ([math]::Max(1, $BackupStorageWarningMB) * 1MB)) {
        $warnings.Add("⚠️ حجم النسخ الاحتياطية تجاوز $BackupStorageWarningMB MB")
    }
    return $warnings.ToArray()
}

function Get-DiagnosticsKeyboard {
    return @{ inline_keyboard = @(
        , @((New-Button '📦 حزمة تشخيص منقحة' 'diag:bundle'))
        , @((New-Button '🧹 مسح سجل التشغيل' 'diag:clearruntime'), (New-Button '🧹 مسح سجل التدقيق' 'diag:clearaudit'))
        , @((New-Button '🏠 القائمة' 'menu:main'))
    ) }
}

function New-DiagnosticBundle {
    $bundleDirectory = Join-Path $script:logDir 'diagnostics'
    New-Item -ItemType Directory -Path $bundleDirectory -Force -ErrorAction Stop | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $stagingDirectory = Join-Path $bundleDirectory "staging-$id"
    $bundlePath = Join-Path $bundleDirectory "cinegy-bridge-diagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$($id.Substring(0,8)).zip"
    New-Item -ItemType Directory -Path $stagingDirectory -Force -ErrorAction Stop | Out-Null
    try {
        $snapshot = Get-BridgeDiagnosticsSnapshot
        $warnings = @(Get-DiagnosticWarnings -Snapshot $snapshot `
            -DiskFreeWarningGB (Get-SettingInt 'DiskFreeWarningGB' 1) `
            -RuntimeStorageWarningMB (Get-SettingInt 'RuntimeStorageWarningMB' 1) `
            -BackupStorageWarningMB (Get-SettingInt 'BackupStorageWarningMB' 1))
        $summary = [ordered]@{
            generatedAtUtc      = [DateTime]::UtcNow.ToString('o')
            bridgeVersion       = $script:BridgeVersion
            powershellVersion   = [string]$PSVersionTable.PSVersion
            uptimeSeconds       = [long]([timespan]$snapshot.Uptime).TotalSeconds
            processor           = Protect-DiagnosticText ([string]$snapshot.Processor)
            workingSetMB        = $snapshot.WorkingSetMB
            privateMemoryMB     = $snapshot.PrivateMemoryMB
            diskFreeGB          = $snapshot.DiskFreeGB
            runtimeStorageBytes = $snapshot.RuntimeStorageBytes
            backupStorageBytes  = $snapshot.BackupStorageBytes
            airOperations       = $snapshot.AirOperations
            warnings            = @($warnings | ForEach-Object { Protect-DiagnosticText $_ })
        }
        $summaryPath = Join-Path $stagingDirectory 'summary.json'
        [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

        $recentPath = Join-Path $stagingDirectory 'recent-runtime.log'
        $recentLines = if (Test-Path -LiteralPath $script:logPath) { @(Get-Content -LiteralPath $script:logPath -Tail 200 -ErrorAction SilentlyContinue) } else { @() }
        $safeLines = @($recentLines | ForEach-Object { Protect-DiagnosticText ([string]$_) })
        [IO.File]::WriteAllLines($recentPath, [string[]]$safeLines, [Text.UTF8Encoding]::new($false))

        Compress-Archive -LiteralPath $summaryPath, $recentPath -DestinationPath $bundlePath -CompressionLevel Optimal -ErrorAction Stop
        return $bundlePath
    }
    finally {
        if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-DiagnosticBundleCommand {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'هذا الخيار للمشرفين فقط.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $bundlePath = $null
    try {
        $bundlePath = New-DiagnosticBundle
        if (Send-TelegramDocument -ChatId $ChatId -FilePath $bundlePath -Caption '📦 حزمة تشخيص منقحة: لا تحتوي الإعدادات أو حالة الهواء أو معرفات المستخدمين.') {
            Add-AuditEntry "📦 تنزيل حزمة تشخيص منقحة - user $UserId"
        }
        else {
            Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذر إرسال حزمة التشخيص.' -ReplyMarkup (Get-DiagnosticsKeyboard)
        }
    }
    catch {
        Write-BridgeLog "Diagnostic bundle creation failed: $($_.Exception.Message)" 'ERROR'
        Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذر إنشاء حزمة التشخيص.' -ReplyMarkup (Get-DiagnosticsKeyboard)
    }
    finally {
        if ($bundlePath -and (Test-Path -LiteralPath $bundlePath)) { Remove-Item -LiteralPath $bundlePath -Force -ErrorAction SilentlyContinue }
    }
}

function Request-DiagnosticLogClear {
    param(
        [Parameter(Mandatory)][ValidateSet('runtime', 'audit')][string]$Kind,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId
    )
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'diagnostic_log_clear'; Kind = $Kind; UserId = $UserId }
    $label = if ($Kind -eq 'runtime') { 'سجل التشغيل الحالي وكل نسخه المدورة' } else { 'سجل التدقيق الدائم' }
    Send-TelegramMessage -ChatId $ChatId -Text "⚠️ هل تريد مسح $label؟`nلا يؤثر هذا على onair.json أو القوالب الموجودة على الهواء." -ReplyMarkup @{
        inline_keyboard = @(
            , @((New-Button '⚠️ نعم، امسح' 'diag:clearconfirm'), (New-Button '❌ إلغاء' 'menu:diagnostics'))
        )
    }
}

function Clear-DiagnosticLog {
    param(
        [Parameter(Mandatory)][ValidateSet('runtime', 'audit')][string]$Kind,
        [Parameter(Mandatory)][long]$UserId
    )
    try {
        if ($Kind -eq 'runtime') {
            foreach ($file in @(Get-ChildItem -LiteralPath $script:logDir -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
            [IO.File]::WriteAllText($script:logPath, '', [Text.UTF8Encoding]::new($false))
        }
        else {
            [IO.File]::WriteAllText($script:auditFile, '', [Text.UTF8Encoding]::new($false))
        }
        $operationId = "audit-$([guid]::NewGuid().ToString('N'))"
        Write-AuditRecord -OperationId $operationId -Event log_clear -Result success -UserId $UserId -Action CLEAR -Target $Kind -Message 'administrator confirmed log cleanup'
        Write-BridgeLog "Administrator user $UserId cleared $Kind log history" 'WARN'
        return $true
    }
    catch {
        Write-BridgeLog "Failed to clear $Kind log history: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Invoke-DiagnosticsCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "هذا الأمر مخصص للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $store = Get-TemplateStore
    $telemetry = Get-AirTelemetryStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    $relayState = if ($script:RelayState.ShouldRun) { 'مطلوب التشغيل' } else { 'متوقف' }
    $diagnostics = Get-BridgeDiagnosticsSnapshot
    $buildText = if ($diagnostics.BuildTimeUtc) { ([datetime]$diagnostics.BuildTimeUtc).ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' } else { 'غير معروف' }
    $uptime = [timespan]$diagnostics.Uptime
    $fileText = ($diagnostics.FileSizes.GetEnumerator() | ForEach-Object { "$($_.Key)=$([math]::Round([double]$_.Value / 1KB, 1))KB" }) -join ' | '
    $diskText = if ($null -ne $diagnostics.DiskFreeGB) { "$($diagnostics.DiskFreeGB) GB" } else { 'غير معروف' }
    $diagnosticWarnings = @(Get-DiagnosticWarnings -Snapshot $diagnostics `
        -DiskFreeWarningGB (Get-SettingInt 'DiskFreeWarningGB' 1) `
        -RuntimeStorageWarningMB (Get-SettingInt 'RuntimeStorageWarningMB' 1) `
        -BackupStorageWarningMB (Get-SettingInt 'BackupStorageWarningMB' 1))
    $text = @(
        "🧪 تشخيص Cinegy Telegram Bridge",
        "Bridge: v$script:BridgeVersion | PowerShell $($PSVersionTable.PSVersion)",
        "وقت البناء: $buildText | مدة التشغيل: $([int]$uptime.TotalHours)س $($uptime.Minutes)د",
        "المعالج: $($diagnostics.Processor)",
        "الذاكرة: Working $($diagnostics.WorkingSetMB) MB | Private $($diagnostics.PrivateMemoryMB) MB",
        "مساحة القرص الحرة: $diskText",
        "أحجام الملفات: $fileText",
        "عمليات الهواء: نجاح $($diagnostics.AirOperations.Success) | فشل $($diagnostics.AirOperations.Failed) | محظور $($diagnostics.AirOperations.Blocked)",
        "Cinegy: $($config.AirServerAddress) / قناة $($config.AirChannelNumber)",
        "القوالب: $(@($store.Order).Count) | تحذيرات القوالب: $(@($store.Errors).Count)",
        "المحادثات المعلقة: $($script:PendingState.Count) | أقفال الطبقات: $($script:LayerLocks.Count)",
        "طابور postbox: $($script:PostShowQueue.Count) | مؤقتات الإخفاء: $($script:AutoHideQueue.Count)",
        "الأحداث المجدولة القادمة: $(@(Get-UpcomingScheduleEvents).Count) | ملف الجدولة: $script:scheduleFile",
        "لقطات قيد التنفيذ: $($script:SnapshotJobs.Count) | relay: $relayState",
        "حالة Cinegy المحلية: $($script:RuntimeState.Monitoring.CinegyHealthState)",
        "",
        (Format-CinegyTelemetryStatus -Telemetry $telemetry)
    ) -join "`n"
    if ($diagnosticWarnings.Count -gt 0) { $text += "`n`n" + ($diagnosticWarnings -join "`n") }
    Send-TelegramMessage -ChatId $ChatId -Text (Protect-SensitiveText $text) -ReplyMarkup (Get-DiagnosticsKeyboard)
}

function Invoke-AuditCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($script:AuditTrail.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "لا توجد عمليات مسجّلة منذ آخر تشغيل." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $text = "📜 آخر العمليات:`n" + (($script:AuditTrail | Select-Object -Last 20) -join "`n")
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

# ============================================================================
#  Access requests / approvals
# ============================================================================

function Request-Approval {
    <# Notifies every admin once per pending chat, with Approve/Reject buttons.
       Capped by MaxPendingApprovals so a publicly-discovered bot cannot flood
       the admins, and entries age out after PendingApprovalExpiryHours. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, $From)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableSelfServiceRequests')) { return $false }
    if ($script:PendingApprovals.ContainsKey($ChatId)) { return $true }

    $max = Get-SettingInt 'MaxPendingApprovals' 1
    if ($script:PendingApprovals.Count -ge $max) {
        Write-BridgeLog "Dropped access request from $ChatId - pending queue full ($max)" "WARN"
        return $false
    }

    $firstName = Get-JsonProp $From 'first_name'
    $lastName = Get-JsonProp $From 'last_name'
    $username = Get-JsonProp $From 'username'
    $name = (@($firstName, $lastName) | Where-Object { $_ }) -join ' '
    if ($username) { $name = if ($name) { "$name (@$username)" } else { "@$username" } }

    $script:PendingApprovals[$ChatId] = @{ Name = $name; ChatId = $ChatId; UserId = $UserId; RequestedAt = (Get-Date) }

    if (@(Get-JsonProp $config 'AdminChatIds').Count -eq 0) {
        Write-BridgeLog "Access request from $ChatId but no AdminChatIds configured to notify" "WARN"
        return $true
    }
    $nameLine = if ($name) { "الاسم: $name`n" } else { "" }
    Send-AdminBroadcast -Text "🔔 طلب وصول جديد للبوت`n$($nameLine)رقم المحادثة: $ChatId`nرقم المستخدم: $UserId" -ReplyMarkup (Get-ApprovalKeyboard -TargetChatId $ChatId)
    Write-BridgeLog "Access request from chat $ChatId / user $UserId ($name) sent to admins"
    return $true
}

function Grant-UserAccess {
    param([Parameter(Mandatory)][long]$TargetChatId, [Parameter(Mandatory)][long]$ApprovedBy, [long]$ApproverUserId = 0)
    if ($ApproverUserId -eq 0) { $ApproverUserId = $ApprovedBy }
    $targetUserId = $TargetChatId
    if ($script:PendingApprovals.ContainsKey($TargetChatId)) { $targetUserId = [long]$script:PendingApprovals[$TargetChatId].UserId }

    # Idempotent: the approval buttons sit in a message that stays tappable,
    # and two admins (or one double-tap) previously re-ran the whole flow and
    # re-notified the new user.
    if ((Test-Authorized -ChatId $TargetChatId -UserId $targetUserId) -and -not $script:PendingApprovals.ContainsKey($TargetChatId)) {
        Send-TelegramMessage -ChatId $ApprovedBy -Text "ℹ️ $TargetChatId مصرّح له بالفعل." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ApprovedBy -UserId $ApproverUserId)
        return
    }

    $changed = $false
    if (@(Get-JsonProp $config 'AllowedChatIds') -notcontains $TargetChatId) {
        $config.AllowedChatIds = @(Get-JsonProp $config 'AllowedChatIds') + $TargetChatId
        $changed = $true
    }
    if ($targetUserId -ne 0 -and (@(Get-JsonProp $config 'AllowedUserIds') -notcontains $targetUserId)) {
        $config.AllowedUserIds = @(Get-JsonProp $config 'AllowedUserIds') + $targetUserId
        $changed = $true
    }
    if ($changed) { Save-Config }
    Record-UserApprovalMetadata -TargetUserId $targetUserId -ApprovedByUserId $ApproverUserId | Out-Null

    $script:PendingApprovals.Remove($TargetChatId)
    Write-BridgeLog "User $ApproverUserId approved new user $targetUserId (chat $TargetChatId)"
    Add-AuditEntry "👤 موافقة على $targetUserId - by $ApproverUserId"
    Send-TelegramMessage -ChatId $ApprovedBy -Text "✅ تمت الموافقة على $TargetChatId وأُضيف إلى المستخدمين المصرح لهم.$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ApprovedBy -UserId $ApproverUserId)
    Send-TelegramMessage -ChatId $TargetChatId -Text "✅ تمت الموافقة على طلبك، يمكنك الآن استخدام البوت." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $TargetChatId -UserId $targetUserId)
}

function Deny-UserAccess {
    param([Parameter(Mandatory)][long]$TargetChatId, [Parameter(Mandatory)][long]$RejectedBy, [long]$RejecterUserId = 0)
    if ($RejecterUserId -eq 0) { $RejecterUserId = $RejectedBy }
    $script:PendingApprovals.Remove($TargetChatId)
    Write-BridgeLog "User $RejecterUserId rejected access request from $TargetChatId"
    Add-AuditEntry "👤 رفض طلب $TargetChatId - by $RejecterUserId"
    Send-TelegramMessage -ChatId $RejectedBy -Text "❌ تم رفض طلب $TargetChatId." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $RejectedBy -UserId $RejecterUserId)
    Send-TelegramMessage -ChatId $TargetChatId -Text "تم رفض طلب الوصول الخاص بك."
}

# ============================================================================
#  ffmpeg: shared helpers, snapshot (async), live relay (watchdogged)
# ============================================================================

function Get-LiveStreamConfig {
    <# Ensures $config.LiveStream exists and returns it. Fields: SourceType
       (m3u8|hls|srt|ndi), SourceUrl, RtmpDestination (Telegram's
       rtmp://.../key, set from chat), VideoBitrateKbps, CopyCodec ($true to
       pass through with -c copy instead of re-encoding - far lighter on the
       playout box's CPU when the source is already H.264/AAC). #>
    $ls = Get-JsonProp $config 'LiveStream'
    if (-not $ls) {
        $ls = [pscustomobject]@{ SourceType = 'm3u8'; SourceUrl = ''; RtmpDestination = ''; VideoBitrateKbps = 2500; CopyCodec = $false }
        $config | Add-Member -NotePropertyName LiveStream -NotePropertyValue $ls -Force
    }
    return $ls
}

function Get-FfmpegPath {
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
            "$env:ProgramFiles\ffmpeg\bin\ffmpeg.exe",
            "$env:ProgramData\chocolatey\bin\ffmpeg.exe",
            (Join-Path $scriptRoot "ffmpeg.exe")
        )) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function ConvertTo-ProcessArgumentLine {
    <# Start-Process -ArgumentList joins an array with spaces and does NOT quote
       elements that contain spaces. With a script path like
       "D:\cingy cg\...\snapshot.jpg" ffmpeg then receives "D:\cingy" as the
       output filename and dies with "Invalid argument" (exit -22). Every
       external process launch therefore goes through this, which applies the
       standard Windows argv quoting rules. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    return ConvertTo-BridgeProcessArgumentLine -Arguments $Arguments
}

function Get-LastErrorLine {
    <# Surfaces the tail of an ffmpeg stderr file so the operator sees the real
       reason in Telegram instead of a bare exit code. #>
    param([Parameter(Mandatory)][string]$Path, [int]$MaxLength = 250)
    if (-not (Test-Path $Path)) { return '' }
    try {
        $lines = @(Get-Content -Path $Path -ErrorAction Stop | Where-Object { $_ -and $_.Trim() })
        if ($lines.Count -eq 0) { return '' }
        $text = Protect-SensitiveText ((@($lines | Select-Object -Last 2) -join ' | ').Trim())
        if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + '…' }
        return $text
    }
    catch { return '' }
}

function Get-FfmpegInputArguments {
    param([Parameter(Mandatory)][string]$SourceType, [Parameter(Mandatory)][string]$SourceUrl, [switch]$Realtime)
    return Get-BridgeFfmpegInputArguments -SourceType $SourceType -SourceUrl $SourceUrl -Realtime:$Realtime
}

# ---- snapshot (fully asynchronous: never blocks the polling loop) ----

function Start-SnapshotJob {
    <# Kicks off a one-frame ffmpeg grab and returns immediately. The result is
       delivered later by Update-SnapshotJobs. Within SnapshotCooldownSeconds
       the previous frame is re-sent instead of spawning ffmpeg again, which
       keeps repeated taps from loading the playout machine's CPU. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }

    if (-not (Get-Setting 'EnableSnapshot')) {
        Send-TelegramMessage -ChatId $ChatId -Text "خاصية الصور معطّلة من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $cooldown = Get-SettingInt 'SnapshotCooldownSeconds' 0
    if ($cooldown -gt 0 -and $script:LastSnapshotFile -and (Test-Path $script:LastSnapshotFile) -and
        ((Get-Date) - $script:LastSnapshotAt).TotalSeconds -lt $cooldown) {
        Send-TelegramPhoto -ChatId $ChatId -FilePath $script:LastSnapshotFile `
            -Caption "📸 آخر لقطة ($([int]((Get-Date) - $script:LastSnapshotAt).TotalSeconds) ثانية مضت)" `
            -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $ls = Get-LiveStreamConfig
    $sourceUrl = [string]$ls.SourceUrl
    if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ LiveStream.SourceUrl غير مضبوط في config.json." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $ffmpeg = Get-FfmpegPath
    if (-not $ffmpeg) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ لم يتم العثور على ffmpeg.exe. ثبّته أولًا (winget install ffmpeg)." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try {
        $inputArgs = @(Get-FfmpegInputArguments -SourceType ([string]$ls.SourceType) -SourceUrl $sourceUrl)
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ $($_.Exception.Message)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $outPath = Join-Path $logDir "snapshot-$stamp.jpg"
    # Per-job stderr file: a shared one would race between concurrent captures
    # and report the wrong error back to the wrong operator.
    $errLog = Join-Path $logDir "snapshot-$stamp.err"
    $timeout = Get-SettingInt 'SnapshotTimeoutSeconds' 3

    $processArguments = @('-y', '-loglevel', 'error') + $inputArgs + @('-frames:v', '1', '-q:v', '2', $outPath)
    try {
        $proc = Start-BridgeMediaProcess -FilePath $ffmpeg -Arguments $processArguments `
            -WorkingDirectory $scriptRoot -StandardErrorPath $errLog
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل تشغيل ffmpeg: $($_.Exception.Message)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }

    $script:SnapshotJobs.Add(@{
            Proc = $proc; ChatId = $ChatId; UserId = $UserId; OutPath = $outPath; ErrLog = $errLog
            Deadline = (Get-Date).AddSeconds($timeout)
        })
    Send-TelegramMessage -ChatId $ChatId -Text "⏳ جاري التقاط صورة من البث..."
}

function Update-SnapshotJobs {
    <# Polled from Invoke-BridgeTick. Delivers finished snapshots and kills
       ones that overran their deadline. #>
    if ($script:SnapshotJobs.Count -eq 0) { return }
    $done = @()
    foreach ($job in $script:SnapshotJobs) {
        $expired = (Get-Date) -gt $job.Deadline
        if (-not $job.Proc.HasExited -and -not $expired) { continue }

        if (-not $job.Proc.HasExited) {
            Stop-Process -Id $job.Proc.Id -Force -ErrorAction SilentlyContinue
            Remove-Item $job.OutPath -Force -ErrorAction SilentlyContinue
            Send-TelegramMessage -ChatId $job.ChatId -Text "❌ انتهت مهلة التقاط الصورة - تأكد أن المصدر قابل للوصول." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $job.ChatId -UserId $job.UserId)
        }
        elseif ($job.Proc.ExitCode -ne 0 -or -not (Test-Path $job.OutPath)) {
            $detail = Get-LastErrorLine -Path $job.ErrLog
            Write-BridgeLog "Snapshot ffmpeg failed (exit $($job.Proc.ExitCode)): $detail" "ERROR"
            $msg = "❌ فشل التقاط الصورة (كود $($job.Proc.ExitCode))."
            if ($detail) { $msg += "`nسبب ffmpeg: $detail" }
            # Clean up the partial/zero-byte output ffmpeg may have left behind.
            Remove-Item $job.OutPath -Force -ErrorAction SilentlyContinue
            Send-TelegramMessage -ChatId $job.ChatId -Text $msg -ReplyMarkup (Get-MainMenuKeyboard -ChatId $job.ChatId -UserId $job.UserId)
        }
        else {
            # Retain only the newest frame for the cooldown cache.
            if ($script:LastSnapshotFile -and $script:LastSnapshotFile -ne $job.OutPath) {
                Remove-Item $script:LastSnapshotFile -Force -ErrorAction SilentlyContinue
            }
            $script:LastSnapshotFile = $job.OutPath
            $script:LastSnapshotAt = Get-Date
            Write-BridgeLog "User $($job.UserId) captured a stream snapshot"
            Add-AuditEntry "📸 لقطة - user $($job.UserId)"
            Send-TelegramPhoto -ChatId $job.ChatId -FilePath $job.OutPath `
                -Caption "📸 لقطة من الهواء - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" `
                -ReplyMarkup (Get-MainMenuKeyboard -ChatId $job.ChatId -UserId $job.UserId)
        }
        Remove-Item $job.ErrLog -Force -ErrorAction SilentlyContinue
        $done += $job
    }
    foreach ($job in $done) { $script:SnapshotJobs.Remove($job) | Out-Null }
}

function Update-SnapshotCleanup {
    <# Snapshots are throwaway files. The success path already deletes the
       previously cached frame and the failure paths delete their own output,
       but a hard kill of the bridge mid-capture can still orphan files - so
       sweep the folder periodically and once at startup. Runs at most every
       few minutes; it is only a few Get-ChildItem calls. #>
    param([switch]$Force)
    if (-not $Force -and ((Get-Date) - $script:LastSnapshotSweep).TotalSeconds -lt 300) { return }
    $script:LastSnapshotSweep = Get-Date

    $retention = Get-SettingInt 'SnapshotRetentionMinutes' 1
    $cutoff = (Get-Date).AddMinutes(-$retention)
    $active = @($script:SnapshotJobs | ForEach-Object { $_.OutPath })
    $removed = 0
    foreach ($pattern in @('snapshot-*.jpg', 'snapshot-*.err')) {
        foreach ($file in @(Get-ChildItem -Path $logDir -Filter $pattern -File -ErrorAction SilentlyContinue)) {
            if ($active -contains $file.FullName) { continue }          # capture in flight
            if ($file.LastWriteTime -ge $cutoff) { continue }           # still fresh / cached
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    # Drop the stale legacy shared error log from earlier versions.
    $legacy = Join-Path $logDir 'snapshot-stderr.log'
    if (Test-Path $legacy) { Remove-Item $legacy -Force -ErrorAction SilentlyContinue }

    if ($removed -gt 0) { Write-BridgeLog "Snapshot cleanup removed $removed stale file(s)" }
}

# ---- live relay ----

function Get-RunningRelayProcess {
    <# The pid file stores "<pid>|<start ticks>". Matching the start time too
       matters because Windows recycles PIDs: a stale relay.pid could otherwise
       resolve to an unrelated ffmpeg - very plausibly one of this bridge's own
       short-lived snapshot captures - and the menu would claim the relay is
       live while offering to kill the wrong process. #>
    if ($script:RelayState.Process -and -not $script:RelayState.Process.HasExited) { return $script:RelayState.Process }
    if (Test-Path $relayPidFile) {
        $raw = ''
        try { $raw = (Get-Content $relayPidFile -Raw -ErrorAction Stop).Trim() } catch { $raw = '' }
        $parts = @($raw -split '\|')
        $parsedPid = 0
        if ($parts.Count -ge 1 -and [int]::TryParse($parts[0], [ref]$parsedPid)) {
            $proc = Get-Process -Id $parsedPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like 'ffmpeg*') {
                $ticks = 0L
                if ($parts.Count -lt 2 -or -not [long]::TryParse($parts[1], [ref]$ticks)) {
                    return $proc          # legacy pid file without a timestamp
                }
                if ([Math]::Abs($proc.StartTime.Ticks - $ticks) -lt [TimeSpan]::TicksPerSecond) {
                    return $proc
                }
            }
        }
        Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
    }
    return $null
}

function Get-LiveRelayStatusText {
    $proc = Get-RunningRelayProcess
    if ($proc) { return "🟢 يعمل (PID $($proc.Id))" }
    if ($script:RelayState.ShouldRun) { return "🟠 متوقف - محاولة إعادة التشغيل" }
    return "⚪ متوقف"
}

function Build-RelayArguments {
    $ls = Get-LiveStreamConfig
    $rtmp = [string]$ls.RtmpDestination
    if ([string]::IsNullOrWhiteSpace($rtmp)) { throw "لم يتم ضبط رابط RTMP بعد - استخدم زر 🔗 رابط البث أولًا." }
    $sourceUrl = [string]$ls.SourceUrl
    if ([string]::IsNullOrWhiteSpace($sourceUrl)) { throw "LiveStream.SourceUrl غير مضبوط في config.json." }

    $inputArgs = @(Get-FfmpegInputArguments -SourceType ([string]$ls.SourceType) -SourceUrl $sourceUrl -Realtime)

    if (Get-JsonProp $ls 'CopyCodec') {
        $outputArgs = @('-c', 'copy', '-f', 'flv', $rtmp)
    }
    else {
        $vBitrate = 0
        if (-not [int]::TryParse([string](Get-JsonProp $ls 'VideoBitrateKbps'), [ref]$vBitrate) -or $vBitrate -le 0) { $vBitrate = 2500 }
        $outputArgs = @(
            '-c:v', 'libx264', '-preset', 'veryfast', '-b:v', "${vBitrate}k", '-maxrate', "${vBitrate}k", '-bufsize', "$($vBitrate * 2)k",
            '-pix_fmt', 'yuv420p', '-g', '60',
            '-c:a', 'aac', '-b:a', '128k', '-ar', '44100',
            '-f', 'flv', $rtmp
        )
    }
    return $inputArgs + $outputArgs
}

function Start-RelayProcess {
    <# Low-level launch shared by the button and the watchdog's auto-restart.
       Returns $true if the process started (startup success is verified later,
       asynchronously, so the caller never blocks). #>
    $ffmpeg = Get-FfmpegPath
    if (-not $ffmpeg) { throw "لم يتم العثور على ffmpeg.exe. ثبّته أولًا (winget install ffmpeg)." }
    $relayArgs = @(Build-RelayArguments)
    $stdoutLog = Join-Path $logDir "relay-stdout.log"
    $stderrLog = Join-Path $logDir "relay-stderr.log"

    # Quoted for the same reason as the snapshot: source URLs, RTMP keys and
    # paths can all contain spaces.
    $script:RelayState.Process = Start-BridgeMediaProcess -FilePath $ffmpeg -Arguments $relayArgs `
        -WorkingDirectory $scriptRoot -StandardOutputPath $stdoutLog -StandardErrorPath $stderrLog
    # pid + process start time, so a recycled PID cannot be mistaken for ours.
    $stamp = "$($script:RelayState.Process.Id)|$($script:RelayState.Process.StartTime.Ticks)"
    Set-Content -Path $relayPidFile -Value $stamp -Encoding ascii
    return $true
}

function Start-LiveRelay {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableLiveRelay')) {
        Send-TelegramMessage -ChatId $ChatId -Text "البث المباشر معطّل من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if (Get-RunningRelayProcess) {
        Send-TelegramMessage -ChatId $ChatId -Text "البث يعمل بالفعل." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try { Start-RelayProcess | Out-Null }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ $($_.Exception.Message)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $script:RelayState.ShouldRun = $true
    $script:RelayState.Restarts = 0
    $script:RelayState.NotifyChatId = $ChatId
    $script:RelayState.VerifyAt = (Get-Date).AddSeconds(3)
    Write-BridgeLog "User $UserId started live relay (PID $($script:RelayState.Process.Id))"
    Add-AuditEntry "▶️ بدء البث - user $UserId"
    Send-TelegramMessage -ChatId $ChatId -Text "⏳ جاري بدء البث..." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Stop-LiveRelay {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $script:RelayState.ShouldRun = $false
    $script:RelayState.VerifyAt = $null
    $proc = Get-RunningRelayProcess
    if (-not $proc) {
        Send-TelegramMessage -ChatId $ChatId -Text "لا يوجد بث يعمل حاليًا." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        Write-BridgeLog "User $UserId stopped live relay (PID $($proc.Id))"
        Add-AuditEntry "⏹ إيقاف البث - user $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text "⏹ تم إيقاف البث." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    catch {
        Send-TelegramMessage -ChatId $ChatId -Text "فشل إيقاف البث: $($_.Exception.Message)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    $script:RelayState.Process = $null
    Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
}

function Update-RelayWatchdog {
    <# Two jobs: confirm a just-started relay actually stayed up (deferred so
       Start-LiveRelay does not sleep), and restart a relay that died on its
       own - a dropped source used to silently kill the stream with nobody
       noticing until someone checked. #>
    if ($script:RelayState.VerifyAt) {
        if ((Get-Date) -lt $script:RelayState.VerifyAt) { return }
        $script:RelayState.VerifyAt = $null
        $notify = [long]$script:RelayState.NotifyChatId
        if ($script:RelayState.Process -and $script:RelayState.Process.HasExited) {
            # Capture the exit code before clearing the reference.
            $exitCode = $script:RelayState.Process.ExitCode
            $detail = Get-LastErrorLine -Path (Join-Path $logDir "relay-stderr.log")
            Write-BridgeLog "Live relay exited immediately (code $exitCode): $detail" "ERROR"
            $script:RelayState.ShouldRun = $false
            $script:RelayState.Process = $null
            Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
            if ($notify) {
                $msg = "❌ توقف البث فورًا بعد التشغيل (كود $exitCode)."
                if ($detail) { $msg += "`nسبب ffmpeg: $detail" }
                Send-TelegramMessage -ChatId $notify -Text $msg -ReplyMarkup (Get-MainMenuKeyboard -ChatId $notify)
            }
        }
        elseif ($notify) {
            Send-TelegramMessage -ChatId $notify -Text "▶️ البث يعمل الآن." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $notify)
        }
        return
    }

    $interval = Get-SettingInt 'RelayWatchdogSeconds' 5
    $now=Get-Date
    $running=$null
    if($script:RelayState.ShouldRun -and ($now-$script:RelayState.LastCheck).TotalSeconds -ge $interval){$running=Get-RunningRelayProcess}
    $maxRestarts = Get-SettingInt 'RelayMaxRestarts' 0
    $decision=Get-BridgeRelayWatchdogDecision -ShouldRun:([bool]$script:RelayState.ShouldRun) `
        -HasRunningProcess:([bool]$running) -AutoRestart:([bool](Get-Setting 'RelayAutoRestart')) `
        -Restarts ([int]$script:RelayState.Restarts) -MaxRestarts $maxRestarts `
        -LastCheck ([datetime]$script:RelayState.LastCheck) -IntervalSeconds $interval -Now $now
    if($decision.Action -in @('idle','wait')){return}
    $script:RelayState.LastCheck=$decision.CheckedAt
    if($decision.Action -eq 'running'){return}

    Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
    $script:RelayState.Process = $null

    if ($decision.Action -eq 'stay_down') {
        $script:RelayState.ShouldRun = $false
        Write-BridgeLog "Live relay died and RelayAutoRestart is off - staying down" "WARN"
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text "⚠️ توقف البث المباشر (إعادة التشغيل التلقائي معطّلة)." }
        return
    }

    if ($decision.Action -eq 'give_up') {
        $script:RelayState.ShouldRun = $false
        Write-BridgeLog "Live relay exceeded RelayMaxRestarts ($maxRestarts) - giving up" "ERROR"
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text "⚠️ توقف البث نهائيًا بعد $maxRestarts محاولة إعادة تشغيل. راجع logs\relay-stderr.log." }
        return
    }

    $script:RelayState.Restarts=$decision.Restarts
    Write-BridgeLog "Live relay died - auto-restart attempt $($script:RelayState.Restarts)/$maxRestarts" "WARN"
    try {
        Start-RelayProcess | Out-Null
        $script:RelayState.VerifyAt = (Get-Date).AddSeconds(3)
        $script:RelayState.NotifyChatId = 0
        if (Get-Setting 'NotifyAdminsOnRelayFailure') { Send-AdminBroadcast -Text "🔄 انقطع البث وتمت إعادة تشغيله تلقائيًا (محاولة $($script:RelayState.Restarts))." }
    }
    catch {
        Write-BridgeLog "Live relay auto-restart failed: $($_.Exception.Message)" "ERROR"
    }
}

function Start-StreamUrlPrompt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'stream_url'; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل رابط RTMP الكامل (الخادم + المفتاح معًا) من إعدادات بث فيديو تشات تليجرام:" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-StreamUrl {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    Clear-PendingState -ChatId $ChatId
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        Send-TelegramMessage -ChatId $ChatId -Text "لم يتم إدخال رابط، لم يتغيّر شيء." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $state.UserId)
        return
    }
    $ls = Get-LiveStreamConfig
    $ls | Add-Member -NotePropertyName 'RtmpDestination' -NotePropertyValue $trimmed -Force
    Save-Config
    Write-BridgeLog "User $($state.UserId) updated LiveStream.RtmpDestination"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ تم حفظ رابط البث.$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $state.UserId)
}

# ============================================================================
#  Settings screen
# ============================================================================

function Show-SettingsScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text "⚙️ الإعدادات - اضغط على أي خيار لتبديله أو تغيير قيمته:" -ReplyMarkup (Get-SettingsKeyboard)
}

function Show-HideAllLayerSettings {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $layers = @(Get-HideAllTargetLayers)
    $scopeText = if ($layers.Count -gt 0) { $layers -join '، ' } else { 'لا توجد طبقات محددة' }
    Send-TelegramMessage -ChatId $ChatId -Text "🚨 طبقات إخفاء الكل الحالية: $scopeText`nاضغط طبقة لتضمينها أو استبعادها. هذا التحديد هو فقط ما سيخفيه زر الطوارئ." -ReplyMarkup (Get-HideAllLayerSettingsKeyboard)
}

function Show-LayerNamesScreen {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Send-TelegramMessage -ChatId $ChatId -Text "🏷️ أسماء الطبقات`nاختر طبقة، ثم أرسل اسمًا واحدًا واضحًا لها. لا تحتاج إلى كتابة رموز أو أرقام بصيغة خاصة." -ReplyMarkup (Get-LayerNamesKeyboard)
}

function Set-LayerName {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [AllowEmptyString()][string]$Name = '',
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $trimmed = $Name.Trim()
    if ($trimmed.Length -gt 60 -or $trimmed.IndexOfAny([char[]]';=') -ge 0) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ الاسم يجب أن يكون حتى 60 حرفًا، ولا يحتوي على ; أو =. لم يتغيّر شيء.' -ReplyMarkup (Get-LayerNameEditKeyboard -Layer $Layer)
        return $false
    }

    $names = [ordered]@{}
    foreach ($pair in @([string](Get-Setting 'LayerNames') -split ';')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        if ($parts.Count -lt 2) { continue }
        $number = 0
        if ([int]::TryParse($parts[0].Trim(), [ref]$number) -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
            $key = [string]$number
            $names[$key] = $parts[1].Trim()
        }
    }
    $layerKey = [string]$Layer
    if ([string]::IsNullOrWhiteSpace($trimmed)) { $names.Remove($layerKey) | Out-Null }
    else { $names[$layerKey] = $trimmed }

    $stored = @($names.Keys | Sort-Object { [int]$_ } | ForEach-Object { "$_=$($names[$_])" }) -join ';'
    Set-Setting -Name 'LayerNames' -Value $stored
    $action = if ([string]::IsNullOrWhiteSpace($trimmed)) { 'cleared' } else { "set to '$trimmed'" }
    Write-BridgeLog "User $UserId $action layer $Layer name"
    Add-AuditEntry "🏷️ اسم طبقة $Layer $action - user $UserId"
    $message = if ([string]::IsNullOrWhiteSpace($trimmed)) { "✅ تم مسح اسم طبقة $Layer." } else { "✅ تم حفظ الاسم: $(Get-LayerDisplayName -Layer $Layer)" }
    Send-TelegramMessage -ChatId $ChatId -Text "$message$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-LayerNamesKeyboard)
    return $true
}

function Start-LayerNamePrompt {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'layer_name'; Layer = $Layer; UserId = $UserId }
    $current = Get-LayerName -Layer $Layer
    $currentText = if ($current) { "الاسم الحالي: $current" } else { 'لا يوجد اسم حاليًا.' }
    Send-TelegramMessage -ChatId $ChatId -Text "🏷️ طبقة $Layer`n$currentText`nأرسل الاسم الجديد فقط." -ReplyMarkup (Get-LayerNameEditKeyboard -Layer $Layer)
}

function Complete-LayerName {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = '')
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'layer_name') { return }
    Clear-PendingState -ChatId $ChatId
    if ([string]::IsNullOrWhiteSpace($Value)) {
        Send-TelegramMessage -ChatId $ChatId -Text '❌ الاسم فارغ. استخدم زر «مسح الاسم» إن أردت حذفه.' -ReplyMarkup (Get-LayerNameEditKeyboard -Layer ([int]$state.Layer))
        return
    }
    Set-LayerName -Layer ([int]$state.Layer) -Name $Value -ChatId $ChatId -UserId ([long]$state.UserId) | Out-Null
}

function Set-HideAllLayerSelection {
    param(
        [int]$Layer = 0,
        [switch]$SelectAll,
        [switch]$ClearAll,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $known = @((Get-KnownLayers | ForEach-Object { [int]$_ }) | Sort-Object -Unique)
    if ($SelectAll) { $value = 'all' }
    elseif ($ClearAll) { $value = '' }
    else {
        if ($known -notcontains $Layer) {
            Send-TelegramMessage -ChatId $ChatId -Text "هذه الطبقة لم تعد ضمن القوالب المعرّفة." -ReplyMarkup (Get-HideAllLayerSettingsKeyboard)
            return
        }
        $selected = @(Get-HideAllTargetLayers)
        if (([string](Get-Setting 'HideAllLayers')).Trim().Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) { $selected = $known }
        if ($selected -contains $Layer) { $selected = @($selected | Where-Object { $_ -ne $Layer }) }
        else { $selected += $Layer }
        $value = (@($selected | Sort-Object -Unique) -join ',')
    }
    Set-Setting -Name 'HideAllLayers' -Value $value
    Write-BridgeLog "User $UserId changed HideAllLayers to '$value'" "WARN"
    Add-AuditEntry "🚨 طبقات إخفاء الكل = $value - user $UserId"
    Show-HideAllLayerSettings -ChatId $ChatId -UserId $UserId
}

function Invoke-SettingToggle {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [switch]$Confirmed)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:DefaultSettings.Contains($Name)) {
        Send-TelegramMessage -ChatId $ChatId -Text "إعداد غير معروف: $Name" -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    $new = -not [bool](Get-Setting $Name)

    # Only *weakening* a protected setting needs confirmation; re-enabling
    # protection should stay a single tap.
    if (-not $Confirmed -and -not $new -and $script:ProtectedSettings -contains $Name) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ '$Name' إعداد حماية. تعطيله يوسّع من يستطيع التحكم بالهواء.`nهل أنت متأكد؟" -ReplyMarkup (Get-SettingConfirmKeyboard -Name $Name)
        return
    }
    Set-Setting -Name $Name -Value $new
    Write-BridgeLog "User $UserId set $Name = $new"
    Add-AuditEntry "⚙️ $Name = $new - user $UserId"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ $Name = $(if ($new) { 'مفعّل' } else { 'معطّل' })$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-SettingsKeyboard)
}

function Start-SettingValuePrompt {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:DefaultSettings.Contains($Name)) {
        Send-TelegramMessage -ChatId $ChatId -Text "إعداد غير معروف: $Name" -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'setting_value'; Name = $Name; UserId = $UserId }
    Send-TelegramMessage -ChatId $ChatId -Text (Get-SettingPromptText -Name $Name) -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-SettingValue {
    param([Parameter(Mandatory)][long]$ChatId, [string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    Clear-PendingState -ChatId $ChatId
    $parsed = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$parsed)) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ القيمة يجب أن تكون رقمًا صحيحًا. لم يتغيّر شيء." -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    if ($parsed -lt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ القيمة لا يمكن أن تكون سالبة." -ReplyMarkup (Get-SettingsKeyboard)
        return
    }
    Set-Setting -Name $state.Name -Value $parsed
    Write-BridgeLog "User $($state.UserId) set $($state.Name) = $parsed"
    Add-AuditEntry "⚙️ $($state.Name) = $parsed - user $($state.UserId)"
    Send-TelegramMessage -ChatId $ChatId -Text "✅ $($state.Name) = $parsed$(Get-ConfigSaveWarning)" -ReplyMarkup (Get-SettingsKeyboard)
}

function Reset-SettingsToDefault {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $settings = [pscustomobject]@{}
    foreach ($name in $script:DefaultSettings.Keys) {
        $settings | Add-Member -NotePropertyName $name -NotePropertyValue $script:DefaultSettings[$name] -Force
    }
    $config | Add-Member -NotePropertyName 'Settings' -NotePropertyValue $settings -Force
    Save-Config
    Write-BridgeLog "User $UserId reset all settings to defaults" "WARN"
    Add-AuditEntry "♻️ استعادة الإعدادات الافتراضية - user $UserId"
    Send-TelegramMessage -ChatId $ChatId -Text "♻️ تمت استعادة جميع الإعدادات الافتراضية." -ReplyMarkup (Get-SettingsKeyboard)
}

# ============================================================================
#  Typed slash-command fallback
# ============================================================================

function Invoke-AdminRawCommand {
    <# /أمر <Device> <Cmd> [Op1 ...] - admin-only escape hatch for Device/Cmd
       pairs not wrapped by a dedicated command. Typed only, since Device/Cmd
       are arbitrary. Confirm values against Cinegy's Air Remote docs before
       relying on this for anything beyond graphics layers. #>
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not (Get-Setting 'EnableRawCommand')) {
        Send-TelegramMessage -ChatId $ChatId -Text "الأمر الخام معطّل من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "هذا الأمر مخصص للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $parts = $ArgText -split '\s+', 3
    if ($parts.Count -lt 2) {
        Send-TelegramMessage -ChatId $ChatId -Text "الاستخدام: /أمر Device Cmd [Op1]" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    $device = $parts[0]; $cmd = $parts[1]; $op1 = if ($parts.Count -gt 2) { $parts[2] } else { "" }
    $result = Send-AirCommand -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Device $device -Cmd $cmd -Op1 $op1 -TimeoutSec (Get-AirTimeout)
    if ($result.Success) {
        Write-BridgeLog "User $UserId (admin) sent raw command Device=$device Cmd=$cmd"
        Add-AuditEntry "🛠 أمر خام $device/$cmd - user $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text "تم الإرسال: Device=$device Cmd=$cmd" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "فشل: $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
}

function Invoke-ShowCommand {
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $parts = @($ArgText -split '\|' | ForEach-Object { $_.Trim() })
    if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) {
        Send-TelegramMessage -ChatId $ChatId -Text "الاستخدام: /عرض اسم_القالب | نص الحقل الأول | ..." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $key = $parts[0]
    $fieldValues = @()
    if ($parts.Count -gt 1) { $fieldValues = @($parts[1..($parts.Count - 1)]) }

    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($key)) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب '$key' غير معروف. استخدم زر 📋 القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $fields = @($store.Map[$key].Fields)
    if ($fieldValues.Count -gt $fields.Count) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب '$key' يحتوي على $($fields.Count) حقل/حقول فقط: $($fields -join ', ')" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $limits = @($store.Map[$key].FieldLimits)
    $variables = @{}
    for ($i = 0; $i -lt $fieldValues.Count; $i++) {
        $limit = 0
        if ($i -lt $limits.Count) { $limit = [int]$limits[$i] }
        if (-not (Test-FieldLength -Value ([string]$fieldValues[$i]) -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId))) { return }
        $variables[[string]$fields[$i]] = $fieldValues[$i]
    }
    $templateIndex = Get-TemplateIndex -Key $key
    Start-ShowFlow -TemplateIndex $templateIndex -ChatId $ChatId -UserId $UserId -InitialValues $variables -ReviewImmediately
}

function Invoke-HideCommand {
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $layer = 0
    if (-not [int]::TryParse($ArgText.Trim(), [ref]$layer)) {
        Send-TelegramMessage -ChatId $ChatId -Text "اختر الطبقة:" -ReplyMarkup (Get-LayersKeyboard -Prefix 'hide')
        return
    }
    Invoke-HideLayer -Layer $layer -ChatId $ChatId -UserId $UserId | Out-Null
}

function Invoke-ExitCommand {
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $layer = 0
    if (-not [int]::TryParse($ArgText.Trim(), [ref]$layer)) {
        Send-TelegramMessage -ChatId $ChatId -Text "اختر الطبقة:" -ReplyMarkup (Get-LayersKeyboard -Prefix 'exit')
        return
    }
    Invoke-ExitLayer -Layer $layer -ChatId $ChatId -UserId $UserId
}

function Invoke-SetCommand {
    <# Pairs are pipe-separated so values may contain spaces:
       /تحديث Line1.Text=Home Team | Line2.Text=Away Team #>
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $pairs = @($ArgText -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '=' })
    if ($pairs.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "الاستخدام: /تحديث الاسم=القيمة [| الاسم٢=القيمة٢ ...]" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $values = @{}
    foreach ($pair in $pairs) {
        $idx = $pair.IndexOf('=')
        $values[$pair.Substring(0, $idx).Trim()] = $pair.Substring($idx + 1)
    }
    Invoke-SetValues -Values $values -ChatId $ChatId -UserId $UserId
}

function Invoke-UserAliasCommand {
    param([string]$ArgText, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (-not (Test-Admin -ChatId $ChatId -UserId $UserId)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'هذا الخيار للمشرفين فقط.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if ($ArgText -notmatch '^\s*(\d+)\s*(.*)$') {
        Send-TelegramMessage -ChatId $ChatId -Text "الاستخدام: /alias USER_ID الاسم`nلحذف الاسم: /alias USER_ID -"
        return
    }
    $targetUserId = [long]$Matches[1]; $alias = $Matches[2].Trim()
    if ($alias -eq '-') { $alias = '' }
    if (Set-UserAlias -TargetUserId $targetUserId -Alias $alias) {
        $result = if ($alias) { "✅ تم تعيين اسم المستخدم $targetUserId إلى: $alias" } else { "✅ تم حذف الاسم المستعار للمستخدم $targetUserId" }
        Write-BridgeLog "Admin $(Get-UserDisplayName -UserId $UserId) updated alias for user $targetUserId"
        Add-AuditEntry "👤 Alias للمستخدم $targetUserId عُدّل بواسطة $(Get-UserDisplayName -UserId $UserId)"
        Send-TelegramMessage -ChatId $ChatId -Text $result -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    else { Send-TelegramMessage -ChatId $ChatId -Text '❌ تعذر حفظ الاسم المستعار.' }
}

function Invoke-BridgeCommand {
    <# Named Invoke-BridgeCommand rather than Invoke-Command so it does not
       shadow PowerShell's built-in remoting cmdlet. #>
    param([string]$Text, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, $From)
    if ($UserId -eq 0) { $UserId = $ChatId }

    if (-not (Test-Authorized -ChatId $ChatId -UserId $UserId)) {
        Write-BridgeLog "Rejected message from unauthorized chat $ChatId / user $UserId" "WARN"
        $queued = Request-Approval -ChatId $ChatId -UserId $UserId -From $From
        $msg = if ($queued) { "غير مصرح لك باستخدام هذا البوت بعد. تم إرسال طلب وصول إلى المشرف - ستصلك رسالة فور الموافقة." }
        else { "غير مصرح لك باستخدام هذا البوت. تواصل مع المشرف مباشرة." }
        Send-TelegramMessage -ChatId $ChatId -Text $msg
        return
    }
    Update-UserLastActivity -UserId $UserId | Out-Null

    $text = $Text.Trim()
    if ($text -notmatch '^/(\S+)\s*(.*)$') {
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل /بدء لعرض القائمة الرئيسية." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    # Telegram appends @BotName to commands in groups.
    $command = ($Matches[1] -replace '@.*$', '').ToLowerInvariant()
    $argText = $Matches[2]

    switch ($command) {
        { $_ -in @('بدء', 'start') } { Show-MainMenu -ChatId $ChatId -UserId $UserId -Intro "أهلاً! اختر من القائمة:" }
        { $_ -in @('قائمة', 'القائمة', 'menu') } { Show-MainMenu -ChatId $ChatId -UserId $UserId }
        { $_ -in @('الغاء', 'إلغاء', 'cancel') } { Show-MainMenu -ChatId $ChatId -UserId $UserId -Intro "❌ تم إلغاء أي عملية معلّقة. اختر من القائمة:" }
        { $_ -in @('مساعدة', 'help') } { Send-TelegramMessage -ChatId $ChatId -Text (Get-HelpText -ChatId $ChatId -UserId $UserId) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
        { $_ -in @('قوالب', 'templates') } { Invoke-TemplatesCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('عرض', 'show') } { Invoke-ShowCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        { $_ -in @('اخفاء', 'إخفاء', 'hide') } { Invoke-HideCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        { $_ -in @('اخفاءالكل', 'hideall') } { Request-HideAllConfirmation -ChatId $ChatId -UserId $UserId }
        { $_ -in @('خروج', 'exit') } { Invoke-ExitCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        { $_ -in @('تحديث', 'set') } { Invoke-SetCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        { $_ -in @('حالة', 'status') } { Invoke-StatusCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('عملياتي', 'myoperations', 'myops') } { Invoke-MyOperationsCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('صحة', 'health', 'fullstatus') } { Invoke-HealthCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('تشخيص', 'diagnostics', 'diag') } { Invoke-DiagnosticsCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('حزمةتشخيص', 'diagbundle') } { Invoke-DiagnosticBundleCommand -ChatId $ChatId -UserId $UserId }
        { $_ -in @('صورة', 'snapshot') } { Start-SnapshotJob -ChatId $ChatId -UserId $UserId }
        { $_ -in @('جدولة', 'schedule') } { Send-TelegramMessage -ChatId $ChatId -Text "📅 الجدولة:" -ReplyMarkup (Get-ScheduleMenuKeyboard) }
        { $_ -in @('سجل', 'audit') } {
            if (Test-Admin -ChatId $ChatId -UserId $UserId) { Invoke-AuditCommand -ChatId $ChatId -UserId $UserId }
            else { Send-TelegramMessage -ChatId $ChatId -Text "هذا الخيار للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
        }
        { $_ -in @('اعدادات', 'إعدادات', 'settings') } {
            if (Test-Admin -ChatId $ChatId -UserId $UserId) { Show-SettingsScreen -ChatId $ChatId -UserId $UserId }
            else { Send-TelegramMessage -ChatId $ChatId -Text "هذا الخيار للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
        }
        { $_ -in @('امر', 'أمر', 'cmd') } { Invoke-AdminRawCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        default { Send-TelegramMessage -ChatId $ChatId -Text "أمر غير معروف '/$command'. استخدم الأزرار أدناه:" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId) }
    }
}

# ============================================================================
#  Button (callback_query) dispatch
# ============================================================================

function Test-CallbackAdmin {
    <# Guard used by every admin-only callback branch. #>
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    if (Test-Admin -ChatId $ChatId -UserId $UserId) { return $true }
    Send-TelegramMessage -ChatId $ChatId -Text "هذا الخيار للمشرفين فقط." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $false
}

function Invoke-CallbackQuery {
    param($CallbackQuery)

    # message is absent when the originating message is too old for Telegram to
    # still have it, so it cannot be dereferenced blindly under StrictMode.
    $fromObj = Get-JsonProp $CallbackQuery 'from'
    $userId = if ($fromObj) { [long](Get-JsonProp $fromObj 'id') } else { 0 }
    $msgObj = Get-JsonProp $CallbackQuery 'message'
    $chatId = if ($msgObj) { [long]$msgObj.chat.id } else { $userId }
    $data = [string](Get-JsonProp $CallbackQuery 'data')
    Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id

    if ($chatId -eq 0) {
        Write-BridgeLog "Ignoring callback with neither a message nor a sender" "WARN"
        return
    }

    if ($msgObj -and -not (Test-TelegramPrivateChat -Chat $msgObj.chat)) {
        Write-BridgeLog "Ignoring callback from non-private chat $chatId" "WARN"
        return
    }

    if (-not (Test-Authorized -ChatId $chatId -UserId $userId)) {
        Write-BridgeLog "Rejected callback from unauthorized chat $chatId / user $userId" "WARN"
        $queued = Request-Approval -ChatId $chatId -UserId $userId -From $fromObj
        $msg = if ($queued) { "غير مصرح لك باستخدام هذا البوت بعد. تم إرسال طلب وصول إلى المشرف." }
        else { "غير مصرح لك باستخدام هذا البوت. تواصل مع المشرف مباشرة." }
        Send-TelegramMessage -ChatId $chatId -Text $msg
        return
    }
    Update-UserLastActivity -UserId $userId | Out-Null

    switch -Wildcard ($data) {
        'menu:news' { Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId; break }
        'news:refresh' { Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId; break }
        'news:start' {
            $result=Start-NewsTickerDraft -ChatId $chatId -UserId $userId
            if(-not $result.Success){Send-TelegramMessage -ChatId $chatId -Text "🔒 $($result.Error)" -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId)}else{Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId};break
        }
        'news:add' {
            if(-not(Get-NewsTickerDraft -UserId $userId)){Send-TelegramMessage -ChatId $chatId -Text 'لا توجد مسودة مملوكة لك.';break}
            Set-PendingState -ChatId $chatId -State @{Mode='news_add_text';UserId=$userId;StartedAt=(Get-Date)}
            Send-TelegramMessage -ChatId $chatId -Text 'أرسل نص الخبر الجديد:';break
        }
        'news:preview' {
            $draft=Get-NewsTickerDraft -UserId $userId;if(-not $draft){Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId;break}
            $preview=@($draft.Items|ForEach-Object -Begin {$i=0} -Process {$i++;"$i. $_"}) -join "`n"
            Send-TelegramMessage -ChatId $chatId -Text "👁 معاينة المسودة ($(@($draft.Items).Count)):`n$preview" -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break
        }
        'news:publish' {
            $draft=Get-NewsTickerDraft -UserId $userId;if(-not $draft){Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId;break}
            Send-TelegramMessage -ChatId $chatId -Text "⚠️ تأكيد نشر $(@($draft.Items).Count) خبرًا إلى الملف الحي؟" -ReplyMarkup @{inline_keyboard=@(,@(@{text='✅ نعم، انشر';callback_data='news:publishconfirm'},@{text='إلغاء';callback_data='news:refresh'}))};break
        }
        'news:publishconfirm' {
            $result=Publish-NewsTickerDraft -ChatId $chatId -UserId $userId
            Send-TelegramMessage -ChatId $chatId -Text $(if($result.Success){'✅ نُشر شريط الأخبار مع إنشاء نسخة احتياطية.'}else{"❌ لم يتم النشر: $($result.Error)"}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break
        }
        'news:list' { Show-NewsTickerReorderScreen -ChatId $chatId -UserId $userId -MessageId ([int]$msgObj.message_id);break }
        'news:item:*' {
            $i=[int]$data.Substring(10);$draft=Get-NewsTickerDraft -UserId $userId;if(-not $draft -or $i-ge @($draft.Items).Count){break}
            <# Full text goes in the message BODY (not the button), with move
               buttons here so the operator never needs to return to the list
               just to reposition one item. #>
            $rows=@(,@(@{text='⬆️ تحريك لأعلى';callback_data="news:up:$i"},@{text='⬇️ تحريك لأسفل';callback_data="news:down:$i"}))
            $rows+=,@(@{text='✏️ تعديل';callback_data="news:edit:$i"},@{text='🗑 حذف';callback_data="news:delete:$i"})
            $rows+=,@(@{text='⬅️ رجوع للترتيب';callback_data='news:list'})
            Send-TelegramMessage -ChatId $chatId -Text "📰 الخبر $(($i+1)) من $(@($draft.Items).Count):`n`n$($draft.Items[$i])" -ReplyMarkup @{inline_keyboard=$rows};break
        }
        'news:edit:*' { $i=[int]$data.Substring(10);Set-PendingState -ChatId $chatId -State @{Mode='news_edit_text';UserId=$userId;Index=$i;StartedAt=(Get-Date)};Send-TelegramMessage -ChatId $chatId -Text 'أرسل النص البديل للخبر:';break }
        'news:delete:*' { $i=[int]$data.Substring(12);$ok=Remove-NewsTickerDraftItem -ChatId $chatId -UserId $userId -Index $i;if($ok){Edit-TelegramMessageText -ChatId $chatId -MessageId ([int]$msgObj.message_id) -Text '🗑 حُذف هذا الخبر من المسودة.' -ReplyMarkup @{inline_keyboard=@(,@(@{text='⬅️ رجوع للترتيب';callback_data='news:list'}))}|Out-Null}else{Send-TelegramMessage -ChatId $chatId -Text '⛔ الحذف غير مسموح.'};break }
        'news:up:*' {
            $i=[int]$data.Substring(8);if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta -1){Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text '⬆️ حُرِّك لأعلى'}
            else{Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text '⛔ الخبر في أول القائمة بالفعل.'};break
        }
        'news:down:*' {
            $i=[int]$data.Substring(10);if(Move-NewsTickerDraftItem -UserId $userId -Index $i -Delta 1){Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text '⬇️ حُرِّك لأسفل'}
            else{Confirm-TelegramCallback -CallbackQueryId $CallbackQuery.id -Text '⛔ الخبر في آخر القائمة بالفعل.'};break
        }
        'news:unlock' { if(Test-CallbackAdmin -ChatId $chatId -UserId $userId){Remove-NewsTickerDraft;Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId};break }
        'news:clear' { Send-TelegramMessage -ChatId $chatId -Text '⚠️ سيُمسح كل محتوى المسودة فقط. هل تؤكد؟' -ReplyMarkup @{inline_keyboard=@(,@(@{text='نعم، امسح المسودة';callback_data='news:clearconfirm'},@{text='إلغاء';callback_data='news:refresh'}))};break }
        'news:clearconfirm' { $ok=Clear-NewsTickerDraftItems -ChatId $chatId -UserId $userId;Send-TelegramMessage -ChatId $chatId -Text $(if($ok){'✅ مُسحت المسودة. لم يُمس الملف الحي.'}else{'⛔ غير مسموح.'}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break }
        'news:backups' { Send-TelegramMessage -ChatId $chatId -Text 'اختر نسخة لمراجعة استعادتها:' -ReplyMarkup (Get-NewsTickerBackupsKeyboard);break }
        'news:restore:*' {
            if(-not(Test-Admin -ChatId $chatId -UserId $userId)-and -not(Get-Setting 'AllowOperatorsRestoreNews')){break};$i=[int]$data.Substring(13)
            Send-TelegramMessage -ChatId $chatId -Text '⚠️ تأكيد الاستعادة؟ ستُحفظ الحالة الحالية أولًا.' -ReplyMarkup @{inline_keyboard=@(,@(@{text='✅ استعادة';callback_data="news:restoreconfirm:$i"},@{text='إلغاء';callback_data='news:backups'}))};break
        }
        'news:restoreconfirm:*' {
            if(-not(Test-Admin -ChatId $chatId -UserId $userId)-and -not(Get-Setting 'AllowOperatorsRestoreNews')){break};$i=[int]$data.Substring(20);$files=@(Get-ChildItem -LiteralPath $script:newsBackupDirectory -File -Filter '*.txt' -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 10);if($i-ge $files.Count){break}
            $live=Get-NewsTickerConfiguredSnapshot;$result=Restore-NewsTickerBackup -Path ([string](Get-Setting 'NewsFilePath')) -BackupPath $files[$i].FullName -ExpectedHash $live.Hash -Separator ([string](Get-Setting 'NewsItemSeparator')) -BackupDirectory $script:newsBackupDirectory -BackupKeepFiles (Get-SettingInt 'NewsBackupKeepFiles' 1) -MaxItemLength (Get-SettingInt 'NewsMaxItemLength' 1) -MaxItems (Get-SettingInt 'NewsMaxItems' 1)
            if($result.Success){Remove-NewsTickerDraft;Add-AuditEntry "📰 استعادة نسخة شريط الأخبار بواسطة $(Get-UserDisplayName -UserId $userId)"};Send-TelegramMessage -ChatId $chatId -Text $(if($result.Success){'✅ تمت الاستعادة وحفظت الحالة السابقة.'}else{"❌ فشلت الاستعادة: $($result.Error)"}) -ReplyMarkup (Get-NewsTickerManagementKeyboard -ChatId $chatId -UserId $userId);break
        }
        'news:cancel' { if(Get-NewsTickerDraft -UserId $userId){Remove-NewsTickerDraft};Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId;break }
        'news:import' {
            $started=Start-NewsTickerDraft -ChatId $chatId -UserId $userId;if(-not $started.Success){Send-TelegramMessage -ChatId $chatId -Text $started.Error;break}
            Set-PendingState -ChatId $chatId -State @{Mode='news_import_upload';UserId=$userId;StartedAt=(Get-Date)}
            Send-TelegramMessage -ChatId $chatId -Text '📥 أرسل ملف TXT UTF-8. سيُستورد إلى المسودة فقط ثم يمكنك معاينته ونشره.';break
        }
        'menu' {
            Clear-PendingState -ChatId $chatId
            Send-TelegramMessage -ChatId $chatId -Text "القائمة الرئيسية:" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'cancel' {
            Clear-PendingState -ChatId $chatId
            Send-TelegramMessage -ChatId $chatId -Text "تم الإلغاء." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'show:confirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_review' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "انتهت أو تغيّرت مراجعة الإرسال. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $key = [string]$state.Key
            $variables = $state.Values
            $autoHideSeconds = [int]$state.AutoHideSeconds
            Clear-PendingState -ChatId $chatId
            Invoke-ShowTemplateResult -Key $key -Variables $variables -ChatId $chatId -UserId $userId -AutoHideSeconds $autoHideSeconds
            break
        }
        'show:edit' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_review' -or [long]$state.UserId -ne $userId -or @($state.Fields).Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text "لا توجد مراجعة قابلة للتعديل. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $state.Mode = 'show_fields'
            $state.Index = 0
            Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text (Get-FieldPromptText -State $state) -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'show:back' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId -or [int]$state.Index -le 0) {
                Send-TelegramMessage -ChatId $chatId -Text "لا توجد خطوة سابقة متاحة." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $state.Index = [int]$state.Index - 1
            Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text (Get-FieldPromptText -State $state) -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'show:preview' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId -or $state.Values.Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text "لا توجد قيم مدخلة لمعاينتها بعد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $preview = "🔎 معاينة المسودة الحالية`n`n$(Format-ShowReviewText -State $state)"
            Send-TelegramMessage -ChatId $chatId -Text $preview -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
            break
        }
        'hideall:confirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'hide_all_review' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "انتهى أو تغيّر طلب إخفاء الكل. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            Clear-PendingState -ChatId $chatId
            Invoke-HideAllLayers -ChatId $chatId -UserId $userId
            break
        }
        'skip' { Resume-ShowFlow -ChatId $chatId -Skip; break }
        'recent:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'show_fields' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "انتهت مسودة الإدخال. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                break
            }
            $recentIndex = [int]($data.Substring(7))
            $fieldName = [string]$state.Fields[[int]$state.Index]
            $values = @(Get-RecentFieldValues -UserId $userId -FieldName $fieldName)
            if ($recentIndex -lt 0 -or $recentIndex -ge $values.Count) {
                Send-TelegramMessage -ChatId $chatId -Text "القيمة الحديثة لم تعد متاحة." -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
                break
            }
            Resume-ShowFlow -ChatId $chatId -Value ([string]$values[$recentIndex])
            break
        }
        'menu:templates' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر القالب لإظهاره أو استخدم البحث والتصنيفات:" -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'tpl' -BrowseControls)
            break
        }
        'menu:templatesearch' {
            Start-TemplateSearch -ChatId $chatId -UserId $userId
            break
        }
        'menu:templatecategories' {
            Send-TelegramMessage -ChatId $chatId -Text '🗂 اختر تصنيف القوالب:' -ReplyMarkup (Get-TemplateCategoriesKeyboard)
            break
        }
        'tplcat:*' {
            $categories = @(Get-TemplateCategories)
            $categoryIndex = [int]$data.Substring(7)
            if ($categoryIndex -lt 0 -or $categoryIndex -ge $categories.Count) {
                Send-TelegramMessage -ChatId $chatId -Text 'التصنيف لم يعد متاحًا.' -ReplyMarkup (Get-TemplateCategoriesKeyboard)
                break
            }
            $category = [string]$categories[$categoryIndex]
            Send-TelegramMessage -ChatId $chatId -Text "🗂 قوالب '$category':" -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -Category $category -BrowseControls)
            break
        }
        'tplinfo:*' {
            $templateIndex = [int]$data.Substring(8)
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template) {
                Send-TelegramMessage -ChatId $chatId -Text 'القالب لم يعد متاحًا.' -ReplyMarkup (Get-TemplatesKeyboard -Prefix tpl -BrowseControls)
                break
            }
            Send-TelegramMessage -ChatId $chatId -Text (Get-TemplatePreviewText -Template $template) -ReplyMarkup (Get-TemplatePreviewKeyboard -TemplateIndex $templateIndex)
            break
        }
        'menu:favorites' {
            Send-TelegramMessage -ChatId $chatId -Text '⭐ اختر القوالب التي تريد إظهارها في مفضلتك:' -ReplyMarkup (Get-FavoritesManagementKeyboard -UserId $userId)
            break
        }
        'favtoggle:*' {
            $template = Get-TemplateByIndex -Index ([int]$data.Substring(10))
            if (-not $template) { break }
            $selected = @(Get-FavoriteTemplateKeys -UserId $userId) -contains [string]$template.Key
            if (Set-UserFavorite -UserId $userId -TemplateKey ([string]$template.Key) -Enabled (-not $selected)) {
                $action = if ($selected) { 'أزيل من' } else { 'أضيف إلى' }
                Add-AuditEntry "⭐ $($template.Key) $action مفضلة $(Get-UserDisplayName -UserId $userId)"
                Send-TelegramMessage -ChatId $chatId -Text "✅ $($template.Key): $action المفضلة." -ReplyMarkup (Get-FavoritesManagementKeyboard -UserId $userId)
            }
            break
        }
        'menu:timed' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر القالب، ثم حدّد مدة الإخفاء التلقائي:" -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'tplT')
            break
        }
        'menu:hide' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر الطبقة لإخفائها:" -ReplyMarkup (Get-LayersKeyboard -Prefix 'hide')
            break
        }
        'menu:exit' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر الطبقة للخروج من مشهدها:" -ReplyMarkup (Get-LayersKeyboard -Prefix 'exit')
            break
        }
        'menu:hideall' {
            Request-HideAllConfirmation -ChatId $chatId -UserId $userId
            break
        }
        'menu:repeat' { Invoke-RepeatLastShow -ChatId $chatId -UserId $userId; break }
        'menu:myops' { Invoke-MyOperationsCommand -ChatId $chatId -UserId $userId; break }
        'ops:retry' { Invoke-RetryLastShowAttempt -ChatId $chatId -UserId $userId; break }
        'menu:update' {
            Send-TelegramMessage -ChatId $chatId -Text "اختر القالب لتحديث أحد حقوله:" -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'updtpl')
            break
        }
        'menu:snapshot' { Start-SnapshotJob -ChatId $chatId -UserId $userId; break }
        'menu:status' { Invoke-StatusCommand -ChatId $chatId -UserId $userId; break }
        'menu:fullstatus' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-FullStatusCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:health' {
            # Backward-compatible callback for messages created before 3.0.
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-FullStatusCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:diagnostics' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-DiagnosticsCommand -ChatId $chatId -UserId $userId }
            break
        }
        'diag:bundle' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-DiagnosticBundleCommand -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearruntime' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-DiagnosticLogClear -Kind runtime -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearaudit' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-DiagnosticLogClear -Kind audit -ChatId $chatId -UserId $userId }
            break
        }
        'diag:clearconfirm' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or [string]$state.Mode -ne 'diagnostic_log_clear' -or [long]$state.UserId -ne $userId) {
                Send-TelegramMessage -ChatId $chatId -Text 'انتهى أو تغيّر طلب المسح. افتح التشخيص وابدأ من جديد.' -ReplyMarkup (Get-DiagnosticsKeyboard)
                break
            }
            $kind = [string]$state.Kind
            Clear-PendingState -ChatId $chatId
            if (Clear-DiagnosticLog -Kind $kind -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text '✅ تم مسح السجل المحدد بأمان.' -ReplyMarkup (Get-DiagnosticsKeyboard)
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text '❌ تعذر مسح السجل. راجع سجل التشغيل وصلاحيات الملفات.' -ReplyMarkup (Get-DiagnosticsKeyboard)
            }
            break
        }
        'menu:layers' {
            $layerStatuses = @(Get-CinegyLayerDashboard)
            $comparison = Update-OnAirStateFromCinegy -Reason 'operator-check' -LayerStatuses $layerStatuses `
                -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal
            $comparisonText = @(
                "🔎 نتيجة المقارنة: أضيف $(@($comparison.Added).Count) · أزيل $(@($comparison.Removed).Count) · تعذر $(@($comparison.Failed).Count)",
                (Format-CinegyLayerDashboard -LayerStatuses $layerStatuses)
            ) -join "`n`n"
            Send-TelegramMessage -ChatId $chatId -Text $comparisonText -ReplyMarkup (Get-LayerDashboardKeyboard -LayerStatuses $layerStatuses)
            break
        }
        { $_ -in @('اسم', 'alias') } { Invoke-UserAliasCommand -ArgText $argText -ChatId $ChatId -UserId $UserId }
        'menu:refreshstatus' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Invoke-FullStatusCommand -ChatId $chatId -UserId $userId
            }
            break
        }
        'menu:help' {
            Send-TelegramMessage -ChatId $chatId -Text (Get-HelpText -ChatId $chatId -UserId $userId) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            break
        }
        'menu:audit' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-AuditCommand -ChatId $chatId -UserId $userId }
            break
        }
        'menu:settings' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-SettingsScreen -ChatId $chatId -UserId $userId }
            break
        }
        'menu:usersadmin' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-UsersAdminScreen -ChatId $chatId }
            break
        }
        'usr:toggle:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $target = [long]$data.Substring(11); $disabled = Test-UserDisabled -UserId $target
            if (Set-UserDisabled -TargetUserId $target -Disabled (-not $disabled)) {
                $action = if ($disabled) { 'إعادة تفعيل' } else { 'تعطيل' }
                Write-BridgeLog "Admin $userId changed user $target state: $action"
                Add-AuditEntry "👥 $action المستخدم $target - by $(Get-UserDisplayName -UserId $userId)"
                Show-UsersAdminScreen -ChatId $chatId
            }
            break
        }
        'usr:alias:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Start-UserAliasEdit -TargetUserId ([long]$data.Substring(10)) -ChatId $chatId -AdminUserId $userId
            }
            break
        }
        'usr:revoke:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Request-UserRevocation -TargetUserId ([long]$data.Substring(11)) -ChatId $chatId -AdminUserId $userId }
            break
        }
        'usr:revokeconfirm' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'user_revoke' -or [long]$state.UserId -ne $userId) { break }
            $target = [long]$state.TargetUserId; Clear-PendingState -ChatId $chatId
            $result = Revoke-AuthorizedUser -TargetUserId $target
            if ($result.Success) {
                Write-BridgeLog "Admin $userId revoked user $target" 'WARN'
                Add-AuditEntry "👥 سحب صلاحية المستخدم $target - by $(Get-UserDisplayName -UserId $userId)"
                Send-TelegramMessage -ChatId $chatId -Text "✅ تم سحب صلاحية المستخدم $target." -ReplyMarkup (Get-UsersAdminKeyboard)
            }
            else { Send-TelegramMessage -ChatId $chatId -Text "❌ $($result.Error)" -ReplyMarkup (Get-UsersAdminKeyboard) }
            break
        }
        'menu:layernames' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-LayerNamesScreen -ChatId $chatId -UserId $userId }
            break
        }
        'menu:hideallsettings' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Show-HideAllLayerSettings -ChatId $chatId -UserId $userId }
            break
        }
        'menu:schedule' {
            Send-TelegramMessage -ChatId $chatId -Text "📅 جدولة العروض وإدارة الأحداث القادمة:" -ReplyMarkup (Get-ScheduleMenuKeyboard)
            break
        }
        'schedule:new' {
            $clock = Get-SystemClockStatus
            if (-not $clock.Success) {
                Send-TelegramMessage -ChatId $chatId -Text "❌ ساعة الجهاز أو المنطقة الزمنية غير صالحة للجدولة." -ReplyMarkup (Get-ScheduleMenuKeyboard)
                break
            }
            Send-TelegramMessage -ChatId $chatId -Text "اختر القالب المراد جدولته:" -ReplyMarkup (Get-TemplatesKeyboard -Prefix 'schtpl')
            break
        }
        'schedule:list' {
            $events = @(Get-UpcomingScheduleEvents)
            $text = if ($events.Count -eq 0) { 'لا توجد أحداث قادمة.' } else { "📋 الأحداث القادمة:`n" + (@($events | ForEach-Object { "• $(Format-ScheduleEvent -ScheduleEntry $_)" }) -join "`n") }
            Send-TelegramMessage -ChatId $chatId -Text $text -ReplyMarkup (Get-UpcomingScheduleKeyboard)
            break
        }
        'schtpl:*' {
            Start-ScheduleShowFlow -TemplateIndex ([int]$data.Substring(7)) -ChatId $chatId -UserId $userId
            break
        }
        'schrec:*' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_recurrence' -or [long]$state.UserId -ne $userId) { break }
            $state.Recurrence = $data.Substring(7)
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schedule:confirm' {
            Confirm-ScheduledShow -ChatId $chatId -UserId $userId
            break
        }
        'schedule:setend' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $userId -or [string]$state.Recurrence -eq 'once') { break }
            $state.Mode = 'schedule_end_date'; Set-PendingState -ChatId $chatId -State $state
            Send-TelegramMessage -ChatId $chatId -Text '📆 أرسل آخر تاريخ مسموح للتكرار بصيغة YYYY-MM-DD.' -ReplyMarkup (Get-CancelKeyboard)
            break
        }
        'schedule:clearend' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_review' -or [long]$state.UserId -ne $userId) { break }
            $state.RecurrenceUntil = ''
            Show-ScheduleReview -ChatId $chatId -State $state
            break
        }
        'schededit:*' {
            Start-ScheduleMutationFlow -Action edit -EventId $data.Substring(10) -ChatId $chatId -UserId $userId
            break
        }
        'schedcopy:*' {
            Start-ScheduleMutationFlow -Action copy -EventId $data.Substring(10) -ChatId $chatId -UserId $userId
            break
        }
        'schcancel:*' {
            $eventId = $data.Substring(10)
            $scheduleEntry = @(Get-UpcomingScheduleEvents | Where-Object { [string]$_.Id -eq $eventId }) | Select-Object -First 1
            if (-not $scheduleEntry) { break }
            Set-PendingState -ChatId $chatId -State @{ Mode = 'schedule_cancel'; EventId = $eventId; UserId = $userId }
            Send-TelegramMessage -ChatId $chatId -Text "هل تريد إلغاء الحدث؟`n$(Format-ScheduleEvent -ScheduleEntry $scheduleEntry)" -ReplyMarkup @{ inline_keyboard = @(, @((New-Button "✅ نعم، إلغاء" 'schedule:cancelconfirm'), (New-Button "❌ رجوع" 'schedule:list'))) }
            break
        }
        'schedule:cancelconfirm' {
            $state = Get-PendingState -ChatId $chatId
            if (-not $state -or $state.Mode -ne 'schedule_cancel' -or [long]$state.UserId -ne $userId) { break }
            $cancelled = Stop-ScheduledShowEvent -Id ([string]$state.EventId)
            Clear-PendingState -ChatId $chatId
            $text = if ($cancelled) { '✅ تم إلغاء الحدث.' } else { 'تعذر إلغاء الحدث؛ ربما نُفّذ أو أُلغي مسبقًا.' }
            Send-TelegramMessage -ChatId $chatId -Text $text -ReplyMarkup (Get-ScheduleMenuKeyboard)
            break
        }
        'menu:presetsadmin' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "⚡ إدارة النصوص الجاهزة`nاختر القالب:" -ReplyMarkup (Get-PresetAdminTemplatesKeyboard)
            }
            break
        }
        'menu:templatesadmin' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $pendingImport = Get-PendingState -ChatId $chatId
                if ($pendingImport -and [string]$pendingImport.Mode -like 'template_import_*') { Clear-PendingState -ChatId $chatId }
                Send-TelegramMessage -ChatId $chatId -Text '📚 القوالب والإعدادات — اختر قالبًا لقراءة تعريفه:' -ReplyMarkup (Get-TemplateAdminCatalogueKeyboard)
            }
            break
        }
        'timport:export' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-TemplateRegistryExport -ChatId $chatId -UserId $userId }
            break
        }
        'timport:start' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-TemplateRegistryImport -ChatId $chatId -UserId $userId }
            break
        }
        'timport:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Confirm-TemplateRegistryImport -ChatId $chatId -UserId $userId }
            break
        }
        'tadm:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $token = $data.Substring(5)
                if ($token -eq 'create') { Start-TemplateDefinitionPrompt -Action create -ChatId $chatId -UserId $userId }
                elseif ($token -eq 'confirm') { Confirm-TemplateDefinitionChange -ChatId $chatId -UserId $userId }
                elseif ($token -eq 'testconfirm') { Confirm-TemplateTest -ChatId $chatId -UserId $userId }
                elseif ($token -match '^test:(\d+)$') { Start-TemplateTestReview -TemplateIndex ([int]$Matches[1]) -ChatId $chatId -UserId $userId }
                elseif ($token -match '^(edit|delete):(\d+)$') { Start-TemplateDefinitionPrompt -Action $Matches[1] -TemplateIndex ([int]$Matches[2]) -ChatId $chatId -UserId $userId }
                else { Show-TemplateAdminDetail -TemplateIndex ([int]$token) -ChatId $chatId -UserId $userId }
            }
            break
        }
        'padm:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Show-PresetAdminTemplate -TemplateIndex ([int]$data.Substring(5)) -ChatId $chatId
            }
            break
        }
        'pa:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template -or $presetIndex -ge @($template.Presets).Count) { break }
            Send-TelegramMessage -ChatId $chatId -Text "⚡ $($template.Presets[$presetIndex].Name)`nاختر العملية المطلوبة:" -ReplyMarkup (Get-PresetActionKeyboard -TemplateIndex $templateIndex -PresetIndex $presetIndex)
            break
        }
        'pac:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Start-PresetAdminCreate -TemplateIndex ([int]$data.Substring(4)) -ChatId $chatId -UserId $userId
            }
            break
        }
        'pae:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            Start-PresetAdminEditValues -TemplateIndex ([int]$presetParts[1]) -PresetIndex ([int]$presetParts[2]) -ChatId $chatId -UserId $userId
            break
        }
        'par:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template -or $presetIndex -ge @($template.Presets).Count) { break }
            Set-PendingState -ChatId $chatId -State @{
                Mode = 'preset_admin_name'; Action = 'rename'; TemplateIndex = $templateIndex
                TemplateKey = [string]$template.Key; PresetIndex = $presetIndex; UserId = $userId
                Fields = @($template.Fields); Values = @(); Name = [string]$template.Presets[$presetIndex].Name; Index = 0
            }
            Send-TelegramMessage -ChatId $chatId -Text "أرسل الاسم الجديد لـ '$($template.Presets[$presetIndex].Name)':" -ReplyMarkup (Get-CancelKeyboard)
            break
        }
        'pad:*' {
            if (-not (Test-CallbackAdmin -ChatId $chatId -UserId $userId)) { break }
            $presetParts = $data -split ':'
            $templateIndex = [int]$presetParts[1]; $presetIndex = [int]$presetParts[2]
            $template = Get-TemplateByIndex -Index $templateIndex
            if (-not $template -or $presetIndex -ge @($template.Presets).Count) { break }
            Show-PresetAdminReview -ChatId $chatId -State @{
                Mode = 'preset_admin_review'; Action = 'delete'; TemplateIndex = $templateIndex
                TemplateKey = [string]$template.Key; PresetIndex = $presetIndex; UserId = $userId
                Fields = @($template.Fields); Values = @($template.Presets[$presetIndex].Values)
                Name = [string]$template.Presets[$presetIndex].Name; Index = 0
            }
            break
        }
        'presetadmin:confirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Confirm-PresetAdminChange -ChatId $chatId -UserId $userId
            }
            break
        }
        'menu:backups' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "🗄 نسخ الإعدادات المحفوظة:" -ReplyMarkup (Get-ConfigBackupsKeyboard)
            }
            break
        }
        'menu:rawcmd' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "أرسل الأمر بصيغة: /أمر Device Cmd [Op1]" -ReplyMarkup (Get-CancelKeyboard)
            }
            break
        }
        'menu:pending' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Send-TelegramMessage -ChatId $chatId -Text "طلبات الوصول المعلّقة:" -ReplyMarkup (Get-PendingKeyboard)
            }
            break
        }
        'menu:stream:start' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-LiveRelay -ChatId $chatId -UserId $userId }
            break
        }
        'menu:stream:stop' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Stop-LiveRelay -ChatId $chatId -UserId $userId }
            break
        }
        'menu:stream:seturl' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-StreamUrlPrompt -ChatId $chatId -UserId $userId }
            break
        }
        'tplT:*' {
            # Pick the duration first, then collect the field text; the show
            # fires as soon as the last field is entered.
            $idx = [int]($data.Substring(5))
            $t = Get-TemplateByIndex -Index $idx
            $name = if ($t) { $t.Key } else { '' }
            Send-TelegramMessage -ChatId $chatId -Text "المدة قبل الإخفاء التلقائي لـ '$name'`:" -ReplyMarkup (Get-DurationKeyboard -Prefix 'dur' -Token "$idx" -BackData 'menu:timed')
            break
        }
        'dur:*' {
            $parts = $data -split ':'
            $idx = [int]$parts[1]
            if ($parts[2] -eq 'c') {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'timed_custom'; TemplateIndex = $idx; UserId = $userId }
                Send-TelegramMessage -ChatId $chatId -Text "أرسل المدة بالثواني (رقم فقط):" -ReplyMarkup (Get-CancelKeyboard)
            }
            else {
                Start-ShowFlow -TemplateIndex $idx -ChatId $chatId -UserId $userId -AutoHideSeconds ([int]$parts[2])
            }
            break
        }
        'timer:*' {
            $layer = [int]($data.Substring(6))
            Send-TelegramMessage -ChatId $chatId -Text "المدة قبل إخفاء الطبقة $layer`:" -ReplyMarkup (Get-DurationKeyboard -Prefix 'tlay' -Token "$layer")
            break
        }
        'tlay:*' {
            $parts = $data -split ':'
            $layer = [int]$parts[1]
            if ($parts[2] -eq 'c') {
                Set-PendingState -ChatId $chatId -State @{ Mode = 'layer_timer_custom'; Layer = $layer; UserId = $userId }
                Send-TelegramMessage -ChatId $chatId -Text "أرسل المدة بالثواني لإخفاء الطبقة $layer (رقم فقط):" -ReplyMarkup (Get-CancelKeyboard)
            }
            else {
                Set-LayerAutoHide -Layer $layer -Seconds ([int]$parts[2]) -ChatId $chatId -UserId $userId
            }
            break
        }
        'tpl:*' {
            $idx = [int]($data.Substring(4))
            Start-ShowFlow -TemplateIndex $idx -ChatId $chatId -UserId $userId
            break
        }
        'preset:*' {
            $parts = $data -split ':'
            Invoke-PresetShow -TemplateIndex ([int]$parts[1]) -PresetIndex ([int]$parts[2]) -ChatId $chatId -UserId $userId
            break
        }
        'rollbackconfirm:*' { Confirm-SafeRollback -Layer ([int]$data.Substring(16)) -ChatId $chatId -UserId $userId; break }
        'rollback:*' { Start-SafeRollbackReview -Layer ([int]$data.Substring(9)) -ChatId $chatId -UserId $userId; break }
        'hide:*' { Invoke-HideLayer -Layer ([int]$data.Substring(5)) -ChatId $chatId -UserId $userId | Out-Null; break }
        'exit:*' { Invoke-ExitLayer -Layer ([int]$data.Substring(5)) -ChatId $chatId -UserId $userId; break }
        'updtpl:*' {
            $idx = [int]($data.Substring(7))
            $t = Get-TemplateByIndex -Index $idx
            if (-not $t -or $t.Fields.Count -eq 0) {
                Send-TelegramMessage -ChatId $chatId -Text "لا توجد حقول قابلة للتحديث في هذا القالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            else {
                Send-TelegramMessage -ChatId $chatId -Text "اختر الحقل لتحديثه:" -ReplyMarkup (Get-FieldsKeyboard -TemplateIndex $idx)
            }
            break
        }
        'updf:*' {
            $parts = $data -split ':'
            $t = Get-TemplateByIndex -Index ([int]$parts[1])
            $fieldIdx = [int]$parts[2]
            if (-not $t -or $fieldIdx -ge $t.Fields.Count) {
                Send-TelegramMessage -ChatId $chatId -Text "الحقل غير موجود (ربما تغيّر ملف القوالب)." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
            }
            else {
                $fieldLimit = 0
                if ($fieldIdx -lt @($t.FieldLimits).Count) { $fieldLimit = [int]$t.FieldLimits[$fieldIdx] }
                Start-UpdateFieldPrompt -FieldName ([string]$t.Fields[$fieldIdx]) -ChatId $chatId -UserId $userId -FieldLimit $fieldLimit
            }
            break
        }
        'approve:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Grant-UserAccess -TargetChatId ([long]$data.Substring(8)) -ApprovedBy $chatId -ApproverUserId $userId
            }
            break
        }
        'reject:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Deny-UserAccess -TargetChatId ([long]$data.Substring(7)) -RejectedBy $chatId -RejecterUserId $userId
            }
            break
        }
        'cfg:restoreconfirm' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $state = Get-PendingState -ChatId $chatId
                if (-not $state -or $state.Mode -ne 'config_restore' -or [long]$state.UserId -ne $userId) {
                    Send-TelegramMessage -ChatId $chatId -Text "انتهى أو تغيّر طلب الاستعادة. اختر النسخة من جديد." -ReplyMarkup (Get-ConfigBackupsKeyboard)
                    break
                }
                $backupPath = [string]$state.BackupPath
                Clear-PendingState -ChatId $chatId
                $restore = Restore-ConfigBackup -BackupPath $backupPath
                if ($restore.Success) {
                    Write-BridgeLog "Admin user $userId restored configuration backup '$([System.IO.Path]::GetFileName($backupPath))'" "WARN"
                    Add-AuditEntry "🗄 استعادة نسخة إعدادات - user $userId"
                    Send-TelegramMessage -ChatId $chatId -Text "✅ تمت استعادة نسخة الإعدادات. أعد تشغيل البوت لتطبيقها بالكامل." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                }
                else {
                    Send-TelegramMessage -ChatId $chatId -Text "❌ فشلت الاستعادة: $($restore.Error)" -ReplyMarkup (Get-ConfigBackupsKeyboard)
                }
            }
            break
        }
        'cfg:restore:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $backupDirectory = "$ConfigPath.backups"
                $files = if (Test-Path -LiteralPath $backupDirectory) {
                    @(Get-ChildItem -LiteralPath $backupDirectory -Filter '*.json' | Sort-Object LastWriteTimeUtc, Name -Descending)
                }
                else { @() }
                $index = [int]$data.Substring(12)
                if ($index -lt 0 -or $index -ge $files.Count) {
                    Send-TelegramMessage -ChatId $chatId -Text "النسخة المحددة لم تعد موجودة." -ReplyMarkup (Get-ConfigBackupsKeyboard)
                    break
                }
                Clear-PendingState -ChatId $chatId
                Set-PendingState -ChatId $chatId -State @{
                    Mode = 'config_restore'; UserId = $userId; BackupPath = $files[$index].FullName
                }
                $differenceSummary = Get-ConfigDifferenceSummary -CurrentPath $ConfigPath -BackupPath $files[$index].FullName
                Send-TelegramMessage -ChatId $chatId -Text "⚠️ تأكيد استعادة النسخة '$($files[$index].Name)'؟`n$differenceSummary`nسيتم حفظ الإعدادات الحالية أولًا، ويجب إعادة تشغيل البوت بعد الاستعادة." -ReplyMarkup (Get-ConfigRestoreConfirmKeyboard)
            }
            break
        }
        'cfg:reset' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Reset-SettingsToDefault -ChatId $chatId -UserId $userId }
            break
        }
        'hideallcfg:all' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -SelectAll -ChatId $chatId -UserId $userId }
            break
        }
        'hideallcfg:none' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -ClearAll -ChatId $chatId -UserId $userId }
            break
        }
        'hideallcfg:toggle:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Set-HideAllLayerSelection -Layer ([int]$data.Substring(18)) -ChatId $chatId -UserId $userId }
            break
        }
        'layername:clear:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $layerText = $data -replace '^layername:clear:', ''
                if ([string]::IsNullOrWhiteSpace($layerText)) { break }
                $layer = 0
                if (-not [int]::TryParse($layerText, [ref]$layer)) { break }
                Clear-PendingState -ChatId $chatId
                Set-LayerName -Layer $layer -Name '' -ChatId $chatId -UserId $userId | Out-Null
            }
            break
        }
        'layername:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $layerText = $data -replace '^layername:', ''
                if ([string]::IsNullOrWhiteSpace($layerText)) { break }
                $layer = 0
                if (-not [int]::TryParse($layerText, [ref]$layer)) { break }
                if (@(Get-KnownLayers | ForEach-Object { [int]$_ }) -contains $layer) { Start-LayerNamePrompt -Layer $layer -ChatId $chatId -UserId $userId }
            }
            break
        }
        'cfg:t:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Invoke-SettingToggle -Name $data.Substring(6) -ChatId $chatId -UserId $userId }
            break
        }
        'cfgc:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                Invoke-SettingToggle -Name $data.Substring(5) -ChatId $chatId -UserId $userId -Confirmed
            }
            break
        }
        'cfg:v:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) { Start-SettingValuePrompt -Name $data.Substring(6) -ChatId $chatId -UserId $userId }
            break
        }
        'cfg:s:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $settingName = $data.Substring(6)
                if ($settingName -eq 'LayerNames') { Show-LayerNamesScreen -ChatId $chatId -UserId $userId }
                else { Show-SettingChoices -Name $settingName -ChatId $chatId -UserId $userId }
            }
            break
        }
        'cfgs:*' {
            if (Test-CallbackAdmin -ChatId $chatId -UserId $userId) {
                $parts = $data -split ':'
                Set-SettingChoice -Name $parts[1] -Index ([int]$parts[2]) -ChatId $chatId -UserId $userId
            }
            break
        }
        default {
            Send-TelegramMessage -ChatId $chatId -Text "خيار غير معروف." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
        }
    }
}

# ============================================================================
#  Periodic housekeeping (runs between polls, never blocks)
# ============================================================================

function Update-PendingExpiry {
    $stateTimeout = Get-SettingInt 'PendingStateTimeoutMinutes' 1
    foreach ($chatId in @($script:PendingState.Keys)) {
        $state = $script:PendingState[$chatId]
        if (((Get-Date) - $state.StartedAt).TotalMinutes -ge $stateTimeout) {
            Clear-PendingState -ChatId ([long]$chatId)
            Write-BridgeLog "Expired abandoned '$($state.Mode)' flow for chat $chatId" "WARN"
            Send-TelegramMessage -ChatId ([long]$chatId) -Text "⌛ انتهت مهلة الإدخال ولم يُنفّذ شيء. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId ([long]$chatId))
        }
    }

    $approvalTimeout = Get-SettingInt 'PendingApprovalExpiryHours' 1
    foreach ($chatId in @($script:PendingApprovals.Keys)) {
        if (((Get-Date) - $script:PendingApprovals[$chatId].RequestedAt).TotalHours -ge $approvalTimeout) {
            $script:PendingApprovals.Remove($chatId)
            Write-BridgeLog "Expired stale access request from $chatId"
        }
    }
}

function Update-PostShowQueue {
    <# Fires the deferred postbox write that follows a SHOW. Failures are
       logged but never surfaced to the operator: the SHOW itself already
       succeeded and was already confirmed in chat. #>
    if ($script:PostShowQueue.Count -eq 0) { return }
    $due = @($script:PostShowQueue | Where-Object { (Get-Date) -ge $_.At })
    foreach ($item in $due) {
        $script:PostShowQueue.Remove($item) | Out-Null
        $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress `
            -AirChannelNumber $config.AirChannelNumber -Values $item.Values -TimeoutSec (Get-AirTimeout)
        if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air post-show POSTBOX ($($item.Key)): success=$($result.Success) $($result.Xml)" }
        if (-not $result.Success) {
            Write-BridgeLog "Post-show postbox write failed for '$($item.Key)': $($result.Error)" "WARN"
        }
    }
}

function Update-AutoHideQueue {
    if ($script:AutoHideQueue.Count -eq 0) { return }
    $due = @($script:AutoHideQueue | Where-Object { (Get-Date) -ge $_.At })
    foreach ($item in $due) {
        $script:AutoHideQueue.Remove($item) | Out-Null
        Write-BridgeLog "Auto-hiding layer $($item.Layer) (timed show by user $($item.UserId))"
        if (Invoke-HideLayer -Layer ([int]$item.Layer) -ChatId ([long]$item.ChatId) -UserId ([long]$item.UserId) -Quiet) {
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⏱ تم الإخفاء التلقائي للطبقة $($item.Layer)."
        }
        else {
            Send-TelegramMessage -ChatId ([long]$item.ChatId) -Text "⚠️ فشل الإخفاء التلقائي للطبقة $($item.Layer) - أخفها يدويًا."
        }
    }
}

function Update-Heartbeat {
    if (-not (Get-Setting 'HeartbeatEnabled')) { return }
    $now = Get-Date
    if ($now.Date -eq $script:LastHeartbeatDate) { return }
    if ($now.Hour -ne (Get-SettingInt 'HeartbeatHour' 0)) { return }
    $script:LastHeartbeatDate = $now.Date
    $store = Get-TemplateStore
    Send-AdminBroadcast -Text "💚 الجسر يعمل. القوالب: $($store.Order.Count)، البث: $(Get-LiveRelayStatusText)"
    Write-BridgeLog "Heartbeat sent to admins"
}

function Update-CinegyStateWatchdog {
    $now = Get-Date
    $interval = Get-SettingInt 'CinegyStateCheckSeconds' 1
    if (($now - $script:RuntimeState.Monitoring.LastCinegyStateCheck).TotalSeconds -lt $interval) { return }
    $script:RuntimeState.Monitoring.LastCinegyStateCheck = $now

    $sync = Update-OnAirStateFromCinegy -Reason 'watchdog' `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if ($sync.Removed.Count -gt 0 -and (Get-Setting 'NotifyAdminsOnExternalChange')) {
        Send-AdminBroadcast -Text (Format-ExternalCinegyChangeAlert -Changes @($sync.Changes))
    }
}

function Update-CinegyHealthWatchdog {
    $now = Get-Date
    $interval = Get-SettingInt 'CinegyHealthCheckSeconds' 1
    if (($now - $script:RuntimeState.Monitoring.LastCinegyHealthCheck).TotalSeconds -lt $interval) { return }
    $script:RuntimeState.Monitoring.LastCinegyHealthCheck = $now

    $telemetry = Get-AirTelemetryStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    $newState = if (-not $telemetry.Success -or $null -eq $telemetry.Healthy) { 'unreachable' }
    elseif ($telemetry.Healthy) { 'healthy' }
    else { 'unhealthy' }

    $oldState = $script:RuntimeState.Monitoring.CinegyHealthState; $history = $script:HealthHistory.Cinegy
    if ($newState -ne $oldState) { Write-BridgeLog "Cinegy health changed from $oldState to $newState" }
    $script:RuntimeState.Monitoring.CinegyHealthState = $newState
    if ($newState -eq 'healthy') {
        $shouldRecover = [bool]$history.AlertSent
        $history.LastSuccess = $now; $history.FailureCount = 0; $history.OutageStartedAt = $null; $history.AlertSent = $false
        if ($shouldRecover -and (Get-Setting 'NotifyAdminsOnCinegyHealth')) { Send-AdminBroadcast -Text "💚 تعافت صحة Cinegy وعادت القياسات إلى الحالة السليمة." }
        return
    }
    if ([int]$history.FailureCount -eq 0) { $history.OutageStartedAt = $now }
    $history.FailureCount = [int]$history.FailureCount + 1; $history.LastErrorAt = $now
    $history.LastError = if ($newState -eq 'unreachable') { 'تعذّر الوصول' } else { 'قياسات غير سليمة' }
    $threshold = [Math]::Max(1, (Get-SettingInt 'HealthFailureAlertThreshold' 1))
    if ([int]$history.FailureCount -ge $threshold -and -not [bool]$history.AlertSent -and (Get-Setting 'NotifyAdminsOnCinegyHealth')) {
        $history.AlertSent = $true
        $started = ([datetime]$history.OutageStartedAt).ToString('yyyy-MM-dd HH:mm:ss')
        $detail = if ($newState -eq 'unhealthy') { Format-CinegyTelemetryStatus -Telemetry $telemetry } else { 'تعذّر الوصول إلى قياسات صحة Cinegy. تحقق من Air والاتصال بالشبكة.' }
        Send-AdminBroadcast -Text "🔴 تحذير صحة Cinegy بعد $($history.FailureCount) حالات فشل متتالية`nبداية الانقطاع: $started`n$detail"
    }
}

function Set-TelegramConnectionState {
    param([Parameter(Mandatory)][bool]$Connected, [string]$ErrorMessage = '')
    $newState = if ($Connected) { 'connected' } else { 'disconnected' }
    $oldState = $script:RuntimeState.Monitoring.TelegramConnectionState; $history = $script:HealthHistory.Telegram; $now = Get-Date
    if ($newState -ne $oldState) { Write-BridgeLog "Telegram connection changed from $oldState to $newState" }
    $script:RuntimeState.Monitoring.TelegramConnectionState = $newState
    if ($Connected) {
        $shouldRecover = [bool]$history.AlertSent
        $history.LastSuccess = $now; $history.FailureCount = 0; $history.OutageStartedAt = $null; $history.AlertSent = $false
        if ($shouldRecover) { Send-AdminBroadcast -Text "✅ استعاد البوت اتصال Telegram وعادت دورة التحديث للعمل." }
        return
    }
    if ([int]$history.FailureCount -eq 0) { $history.OutageStartedAt = $now }
    $history.FailureCount = [int]$history.FailureCount + 1
    $history.LastError = Protect-SensitiveText $ErrorMessage; $history.LastErrorAt = $now
    $threshold = [Math]::Max(1, (Get-SettingInt 'HealthFailureAlertThreshold' 1))
    if ([int]$history.FailureCount -ge $threshold -and -not [bool]$history.AlertSent) {
        $history.AlertSent = $true
        $started = ([datetime]$history.OutageStartedAt).ToString('yyyy-MM-dd HH:mm:ss')
        Send-AdminBroadcast -Text "⚠️ فُقد اتصال Telegram بعد $($history.FailureCount) حالات فشل متتالية`nبداية الانقطاع: $started`n$($history.LastError)"
    }
}

function Send-BridgeStartupNotification {
    Send-AdminBroadcast -Text "🟢 بدأ تشغيل Cinegy Telegram Bridge v$script:BridgeVersion`nAir: $($config.AirServerAddress) / قناة $($config.AirChannelNumber)"
}

function Invoke-BridgeTick {
    <# Everything time-based happens here, between long-polls. Each helper is
       cheap and non-blocking; any failure is logged rather than allowed to
       kill the loop. #>
    foreach ($step in @('Update-PostShowQueue', 'Update-SnapshotJobs', 'Update-RelayWatchdog', 'Update-AutoHideQueue', 'Update-ScheduleQueue', 'Update-PendingExpiry', 'Update-SnapshotCleanup', 'Save-UsageCounts', 'Save-UserProfiles', 'Update-CinegyStateWatchdog', 'Update-CinegyHealthWatchdog', 'Update-Heartbeat')) {
        try { & $step | Out-Null }
        catch { Write-BridgeLog "Tick step $step failed: $($_.Exception.Message)" "ERROR" }
    }
}

function Get-BasePollTimeout {
    $value = 0
    if (-not [int]::TryParse([string](Get-JsonProp $config 'PollTimeoutSeconds'), [ref]$value) -or $value -le 0) { $value = 30 }
    return $value
}

function Get-EffectivePollTimeout {
    <# Long-poll for the configured time normally, but collapse to 1 second
       whenever async work is outstanding so a finished snapshot or a dead
       relay is noticed within a second instead of up to 30. #>
    if ($script:PostShowQueue.Count -gt 0) { return 1 }
    if ($script:SnapshotJobs.Count -gt 0 -or $script:AutoHideQueue.Count -gt 0 -or $script:RelayState.VerifyAt) { return 1 }
    $base = Get-BasePollTimeout
    $upcoming = @(Get-UpcomingScheduleEvents)
    if ($upcoming.Count -gt 0) {
        $secondsToEvent = [int][Math]::Ceiling((([datetimeoffset]$upcoming[0].ScheduledAt) - [datetimeoffset]::Now).TotalSeconds)
        $base = [Math]::Min($base, [Math]::Max(1, $secondsToEvent))
    }
    if ($script:RelayState.ShouldRun) { return [Math]::Min($base, (Get-SettingInt 'RelayWatchdogSeconds' 5)) }
    $base = [Math]::Min($base, (Get-SettingInt 'CinegyStateCheckSeconds' 1))
    return [Math]::Min($base, (Get-SettingInt 'CinegyHealthCheckSeconds' 1))
}

# ============================================================================
#  Startup
# ============================================================================

# Everything above is declarations only; everything below has side effects.
if ($LoadOnly) { return }

$script:InstanceMutex = $null
if (-not $AllowMultipleInstances) {
    # Two bridges polling the same bot token make Telegram return 409 Conflict
    # and the bot behaves erratically in a way that is painful to diagnose.
    try {
        $created = $false
        $script:InstanceMutex = New-Object System.Threading.Mutex($true, 'Global\CinegyTelegramBridge', [ref]$created)
        if (-not $created) {
            Write-Host "Another CinegyTelegramBridge instance is already running. Exiting."
            Write-BridgeLog "Startup aborted - another instance already holds the single-instance mutex." "ERROR"
            exit 1
        }
    }
    catch {
        Write-Host "Single-instance check unavailable ($($_.Exception.Message)) - continuing."
    }
}

Initialize-Settings
Import-UsageCounts
Import-NewsTickerDraft
Import-UserFavorites
Import-UserAliases
Import-DisabledUsers
Import-UserProfiles
Import-OnAirState
Import-DraftStates
Import-RecentFieldValues
Import-ScheduleEvents
Initialize-CinegyOnAirState | Out-Null
Register-BotCommands
Update-SnapshotCleanup -Force   # clear anything orphaned by a previous run

$store = Get-TemplateStore
Write-BridgeLog "Bridge v$($script:BridgeVersion) starting. Air $($config.AirServerAddress):$(5521 + $config.AirChannelNumber), templates: $($store.Order.Count), allowed chats: $(@(Get-JsonProp $config 'AllowedChatIds').Count)"
foreach ($e in $store.Errors) { Write-BridgeLog "Template warning: $e" "WARN" }
Send-BridgeStartupNotification

$offset = 0
if (Get-Setting 'DropPendingUpdatesOnStart') { $offset = Clear-PendingTelegramUpdates }
$backoffSeconds = 1

try {
    while ($true) {
        try {
            $updates = @(Get-TelegramUpdates -Offset $offset -TimeoutSeconds (Get-EffectivePollTimeout))
            Set-TelegramConnectionState -Connected:$true
            $backoffSeconds = 1

            foreach ($update in $updates) {
                $offset = [long]$update.update_id + 1

                $callback = Get-JsonProp $update 'callback_query'
                if ($callback) {
                    try { Invoke-CallbackQuery -CallbackQuery $callback | Out-Null }
                    catch { Write-BridgeLog "Unhandled error processing callback query: $($_.Exception.Message)" "ERROR" }
                    continue
                }

                $message = Get-JsonProp $update 'message'
                if (-not $message) { continue }
                $chatId = [long]$message.chat.id
                if (-not (Test-TelegramPrivateChat -Chat $message.chat)) {
                    Write-BridgeLog "Ignoring message from non-private chat $chatId" "WARN"
                    continue
                }
                $fromObj = Get-JsonProp $message 'from'
                $userId = if ($fromObj) { [long](Get-JsonProp $fromObj 'id') } else { $chatId }
                $document = Get-JsonProp $message 'document'
                if ($document) {
                    try {
                        $uploadState=Get-PendingState -ChatId $chatId
                        if($uploadState -and $uploadState.Mode -eq 'news_import_upload'){Receive-NewsTickerImport -Document $document -ChatId $chatId -UserId $userId}
                        else{Receive-TemplateRegistryImport -Document $document -ChatId $chatId -UserId $userId}
                    }
                    catch { Write-BridgeLog "Unhandled error processing document from $chatId : $($_.Exception.Message)" 'ERROR' }
                    continue
                }
                $text = [string](Get-JsonProp $message 'text')
                if ([string]::IsNullOrWhiteSpace($text)) { continue }

                try {
                    # Persistent-keyboard taps are checked first and on purpose:
                    # they are the escape hatch for a user stuck mid-flow, so
                    # they must not be consumed as a field value.
                    $trimmed = $text.Trim()
                    if ($trimmed -eq $script:MenuHotword -or $trimmed -eq $script:HelpHotword -or $trimmed -eq $script:NewsHotword) {
                        if (-not (Test-Authorized -ChatId $chatId -UserId $userId)) {
                            Invoke-BridgeCommand -Text '/start' -ChatId $chatId -UserId $userId -From $fromObj
                        }
                        elseif ($trimmed -eq $script:NewsHotword) {
                            Clear-PendingState -ChatId $chatId
                            Show-NewsTickerManagementScreen -ChatId $chatId -UserId $userId
                        }
                        elseif ($trimmed -eq $script:HelpHotword) {
                            Clear-PendingState -ChatId $chatId
                            Send-TelegramMessage -ChatId $chatId -Text (Get-HelpText -ChatId $chatId -UserId $userId) -ReplyMarkup (Get-MainMenuKeyboard -ChatId $chatId -UserId $userId)
                        }
                        else {
                            Show-MainMenu -ChatId $chatId -UserId $userId
                        }
                    }
                    else {
                        $state = Get-PendingState -ChatId $chatId
                        if ($state -and -not $text.StartsWith('/')) {
                            switch ($state.Mode) {
                                'show_fields' { Resume-ShowFlow -ChatId $chatId -Value $text | Out-Null }
                                'update_field' { Complete-UpdateField -ChatId $chatId -Value $text | Out-Null }
                                'stream_url' { Complete-StreamUrl -ChatId $chatId -Value $text | Out-Null }
                                'setting_value' { Complete-SettingValue -ChatId $chatId -Value $text | Out-Null }
                                'setting_text' { Complete-SettingText -ChatId $chatId -Value $text | Out-Null }
                                'layer_name' { Complete-LayerName -ChatId $chatId -Value $text | Out-Null }
                                'user_alias_edit' { Complete-UserAliasEdit -ChatId $chatId -AdminUserId $userId -Value $text | Out-Null }
                                'news_add_text' { Complete-NewsTickerAddText -ChatId $chatId -UserId $userId -Value $text | Out-Null }
                                'news_edit_text' { Complete-NewsTickerEditText -ChatId $chatId -UserId $userId -Value $text | Out-Null }
                                'template_search' { Complete-TemplateSearch -ChatId $chatId -Value $text | Out-Null }
                                'timed_custom' { Complete-TimedShowCustom -ChatId $chatId -Value $text | Out-Null }
                                'layer_timer_custom' { Complete-LayerTimerCustom -ChatId $chatId -Value $text | Out-Null }
                                'template_definition_json' { Complete-TemplateDefinitionJson -ChatId $chatId -Value $text | Out-Null }
                                { $_ -in @('preset_admin_name', 'preset_admin_values') } { Complete-PresetAdminText -ChatId $chatId -Value $text | Out-Null }
                                { $_ -in @('schedule_fields', 'schedule_time', 'schedule_end_date') } { Complete-ScheduleText -ChatId $chatId -Value $text | Out-Null }
                                default { Invoke-BridgeCommand -Text $text -ChatId $chatId -UserId $userId -From $fromObj | Out-Null }
                            }
                        }
                        else {
                            Clear-PendingState -ChatId $chatId
                            Invoke-BridgeCommand -Text $text -ChatId $chatId -UserId $userId -From $fromObj | Out-Null
                        }
                    }
                }
                catch {
                    Write-BridgeLog "Unhandled error processing message from $chatId : $($_.Exception.Message)" "ERROR"
                    Send-TelegramMessage -ChatId $chatId -Text "حدث خطأ داخلي أثناء تنفيذ الأمر - راجع سجل التشغيل (bridge.log)."
                }
            }
        }
        catch {
            Write-BridgeLog "Polling error: $($_.Exception.Message)" "ERROR"
            Set-TelegramConnectionState -Connected:$false -ErrorMessage $_.Exception.Message
            Start-Sleep -Seconds $backoffSeconds
            $backoffSeconds = [Math]::Min($backoffSeconds * 2, 60)
        }

        Invoke-BridgeTick | Out-Null
    }
}
finally {
    Save-UsageCounts -Force
    foreach ($job in @($script:SnapshotJobs)) {
        if ($job.Proc -and -not $job.Proc.HasExited) { Stop-Process -Id $job.Proc.Id -Force -ErrorAction SilentlyContinue }
    }
    $relayProc = Get-RunningRelayProcess
    if ($relayProc) {
        Write-BridgeLog "Bridge shutting down - stopping live relay (PID $($relayProc.Id))"
        Stop-Process -Id $relayProc.Id -Force -ErrorAction SilentlyContinue
        Remove-Item $relayPidFile -Force -ErrorAction SilentlyContinue
    }
    if ($script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() }
        catch { Write-BridgeLog "Could not release instance mutex: $($_.Exception.Message)" "DEBUG" }
        $script:InstanceMutex.Dispose()
    }
}
