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
    # The default remains tolerant for an on-air workstation. Specify this to
    # refuse startup if the operating system cannot enforce the mutex.
    [switch]$RequireSingleInstance,
    # Stop whatever bridge is already running and take its place. Without it
    # an interactive console asks first; a service or scheduled task, which
    # has nobody to ask, refuses as before.
    [switch]$StopExisting,
    # Dot-source the script with -LoadOnly to get every function defined
    # without contacting Telegram, taking the single-instance mutex, or
    # entering the polling loop. Used by Tests\Bridge.Tests.ps1.
    [switch]$LoadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Bump on every functional change. Shown in ℹ️ الحالة and logged at startup so
# "which build is actually running?" is answerable without diffing files.
$script:BridgeVersion = '6.0.0-preview.3'

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
Import-Module (Join-Path $moduleRoot "BridgeOperationPolicy.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeSettingsSchema.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeStateMigration.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeUiPaging.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeLiveScenes.psm1") -Force
Import-Module (Join-Path $moduleRoot "BridgeOperationLifecycle.psm1") -Force

$script:ProcessedUpdateLedger = New-BridgeUpdateLedger -Capacity 4096

# The bridge implementation lives in Parts/*.ps1. These are dot-sourced and
# deliberately not modules: each part shares this script's scope and
# $script: state. Only declarations live there - the ordered initialization
# below depends on $config and therefore stays here.
foreach ($part in @(
        'Bridge.Core'
        'Bridge.Telegram'
        'Bridge.News'
        'Bridge.Users'
        'Bridge.Templates'
        'Bridge.OnAir'
        'Bridge.Schedule'
        'Bridge.Keyboards'
        'Bridge.ShowFlow'
        'Bridge.Admin'
        'Bridge.Media'
        'Bridge.Commands'
        'Bridge.Callbacks'
        'Bridge.Tick'
    )) {
    . (Join-Path $scriptRoot "Parts/$part.ps1")
}

# Resolve the config path relative to the script, not the caller's cwd, so a
# Scheduled Task / service with a different working directory still works.
if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot ($ConfigPath -replace '^\.[\\/]+', '')
}

# Everything needed to start this bridge again, captured while it is still
# unambiguous. Get-BridgeRelaunchCommand rebuilds the command line from these
# so the restart button works when nothing external supervises the process.
$script:BridgeLaunch = @{
    ScriptPath             = $PSCommandPath
    ConfigPath             = $ConfigPath
    RuntimePath            = $RuntimePath
    AllowMultipleInstances = [bool]$AllowMultipleInstances
    RequireSingleInstance  = [bool]$RequireSingleInstance
    WorkingDirectory       = (Get-Location).Path
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
    TemplateRegistryImportMaxTemplates = 1000 # upper bound for one administrator template-registry import
    EnableDpapiSecrets        = $false  # opt-in; current plaintext config behavior remains the default
    # --- features ---
    EnableSnapshot             = $true
    EnableLiveRelay            = $true
    EnableTimedShow            = $true
    EnableHideAll              = $true
    SceneMode                  = 'Single' # Multi remains capability-gated and fails closed
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
    # Two hours, because writing a bulletin is not a thirty-minute errand: a
    # 28-item draft expired mid-edit at the old default. The timeout exists to
    # clear a draft left open overnight, not to hurry an operator who is still
    # working on it.
    NewsDraftTimeoutMinutes    = 120
    NewsListStackedLayout      = $false  # headline on its own row, move/edit/delete beneath it
    NewNewsItemAtTop           = $true   # a newly added item leads the ticker instead of trailing it
    NewsListPaged              = $true   # off puts the whole draft on one screen, as far as Telegram allows
    NewsListPageSize           = 10      # items per page; Telegram refuses an over-large keyboard outright
    NewsListLabelLength        = 24      # headline characters shown when the row also carries buttons
    NewsListStackedLabelLength = 60      # headline characters shown when it owns the row
    NewsLockRequestMinutes     = 5       # a draft owner has this long to answer a hand-over request
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
    UploadRetentionMinutes     = 60      # delete staged operator uploads older than this; 0 keeps them
    ConfirmLayerRemoval        = $true   # ask before hiding something that IS on air, naming the template
    ShowLayerLockBadge         = $false  # mark templates whose layer someone else is preparing
    RepeatWarningCount         = 3       # ask after this many pushes of one template in the window; 0 or 1 disables
    RepeatWarningWindowMinutes = 60      # the window the repeat count is measured over
    MissedEventsHours          = 12      # how far back ماذا فاتني looks
    QuietHoursEnabled          = $false  # batch non-urgent admin notices overnight
    QuietHoursStart            = 1       # hour the quiet window opens
    QuietHoursEnd              = 7       # hour it closes and held notices are delivered
    MaintenanceWindowStart     = ''      # HH:mm; empty disables the automatic window
    MaintenanceWindowEnd       = ''      # HH:mm
    OneHandMode                = $false  # one full-width button per row, for thumb-only use
    EnableTextShortcuts        = $false  # let a bare template name start a show
    OutputMonitorMinutes       = 60      # look at the actual picture this often; 0 disables
    OutputMonitorFailureAlertThreshold = 2 # consecutive unavailable captures before alerting when no backup is configured
    OutputBlackLuminance       = 6       # mean luma at or below this counts as black (0-255)
    OutputBlackConfirmSeconds  = 5       # wait this long before the confirming second capture
    NotifyOperatorsOnBlackOutput = $false # admins always hear; operators only if this is on
    NotifyOnScheduleOverwrite  = $true   # warn when a scheduled event displaces a live graphic
    AllowRemoteRestart         = $false  # let an admin restart the bridge from Telegram; needs a service or task to bring it back
    UsageDigestEnabled         = $true   # weekly usage summary to administrators
    UsageDigestDayOfWeek       = 0       # 0=Sunday .. 6=Saturday, sent at HeartbeatHour
    AutoHideDefaultSeconds     = 10      # pre-selected duration for the timed-show button
    AutoHidePresetSeconds      = '5,10,15,30,60,120'  # quick-pick durations offered on screen
    RelayAutoRestart           = $true
    RelayMaxRestarts           = 20
    RelayWatchdogSeconds       = 20
    CinegyStateCheckSeconds    = 15      # reconcile tracked GFX layers for external changes
    CinegyStateStaleSeconds    = 45      # age after which the last successful state sample is stale
    CinegyHealthCheckSeconds   = 60      # sample /metrics and alert only on transitions
    CinegyMonitorTimeoutSeconds = 3      # bounded, but enough for Air Pro to answer a status read
    CinegyFrameLossTolerance   = 5       # dropped/missing frames per minute before the channel counts as unhealthy
    CinegyFrameLossTolerancePercent = 5  # ...and it must also exceed this share of the frames actually output
    CinegyHealthConfirmChecks  = 3       # consecutive agreeing readings before the health state moves at all
    CinegyReadErrorRateTolerance = 0.5   # percent; below this a read error rate is noise, not an outage
    RespectCinegyItemDuration  = $true   # a graphic Cinegy scheduled for 24h is not "forgotten on air"
    TemplateBasePath           = ''      # scenes folder; lets templates.json carry a bare file name
    CinegyStateBackoffMaxSeconds = 60    # ceiling for backing off reconciliation while Air is unreachable
    StaleOnAirAlertHours      = 6       # warn admins about a bridge record on air this long; 0 disables
    ScheduleConflictWindowMinutes = 2    # warn when pending events target one layer this close together
    SchedulePaused              = $false # keep events pending without executing them
    SchedulePreNotifyMinutes    = 3      # notify this many minutes before a scheduled occurrence; 0 disables
    ScheduleMaxRetries          = 0       # safe default: do not replay a failed SHOW unless admin opts in
    ScheduleRetryDelaySeconds   = 30      # wait before an opted-in scheduled SHOW retry
    ScheduleRetryBackoffFactor  = 2       # exponential multiplier per failed attempt
    ScheduleRetryMaxDelaySeconds = 300    # cap retry delay even with many attempts
    HealthFailureAlertThreshold = 3      # consecutive failures before one outage alert
    UserActivityRecentMinutes   = 5      # approximate recent activity; Telegram does not expose true online presence
    TemplateReminderFollowUpMinutes = 5 # one follow-up after the first personal template reminder; 0 disables
    MaxPendingApprovals        = 20
    PendingApprovalExpiryHours = 24
    FavoritesCount             = 3
    RecentValuesPerField       = 5       # quick choices remembered per operator and field
    # --- housekeeping ---
    LogMaxSizeMB               = 10
    LogKeepFiles               = 5
    AuditMaxSizeMB             = 110     # archive audit.jsonl past this; 0 never rotates it
    AuditArchiveKeepFiles      = 0       # 0 keeps every archive - the audit trail is the permanent record
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

# Upload policy for the two JSON documents that can contain a large number of
# entries. These remain fixed safety limits; NewsImportMaxBytes is intentionally
# configurable because its input is plain editorial text.
$script:SettingsImportMaximumBytes = 10 * 1024 * 1024
$script:TemplateRegistryImportMaximumBytes = 10 * 1024 * 1024

$script:SettingDisplayMetadata = @{
    SceneMode = @{ Unit = ''; Description = 'Single للتوافق الحالي؛ Multi يسمح بعدة قوالب على الطبقة مع قالب نشط واحد في اللحظة نفسها' }
    AirCommandTimeoutSeconds = @{ Unit = 'ثانية'; Description = 'مهلة انتظار أمر Cinegy' }
    TelegramRequestTimeoutSeconds = @{ Unit = 'ثانية'; Description = 'مهلة إرسال رسائل وملفات Telegram' }
    MaxFieldLength = @{ Unit = 'حرفًا'; Description = 'الحد الأقصى لطول نص الحقل' }
    ButtonTextMaxLength = @{ Unit = 'حرفًا'; Description = 'الحد البصري لنص أزرار Telegram (0 للتعطيل)' }
    PostShowDelayMs = @{ Unit = 'مللي ثانية'; Description = 'تأخير إعادة إرسال النص بعد العرض' }
    PendingStateTimeoutMinutes = @{ Unit = 'دقيقة'; Description = 'مدة صلاحية عملية الإدخال غير المكتملة' }
    SnapshotCooldownSeconds = @{ Unit = 'ثانية'; Description = 'الفاصل قبل التقاط صورة بث جديدة' }
    SnapshotTimeoutSeconds = @{ Unit = 'ثانية'; Description = 'مهلة التقاط صورة البث' }
    SnapshotRetentionMinutes = @{ Unit = 'دقيقة'; Description = 'مدة الاحتفاظ بصور البث المؤقتة' }
    UploadRetentionMinutes = @{ Unit = 'دقيقة'; Description = 'مدة الاحتفاظ بالملفات التي يرفعها المستخدمون (0 للاحتفاظ الدائم)' }
    ConfirmLayerRemoval = @{ Unit = ''; Description = 'طلب تأكيد قبل الإخفاء والخروج مع عرض اسم القالب' }
    ShowLayerLockBadge = @{ Unit = ''; Description = 'إظهار 🔒 على القوالب التي يجهّز طبقتها مشغّل آخر' }
    NewsListStackedLayout = @{ Unit = ''; Description = 'قائمة الأخبار: نص الخبر بسطر مستقل وأزرار الترتيب والحذف أسفله' }
    NewsDraftTimeoutMinutes = @{ Unit = 'دقيقة'; Description = 'مهلة مسودة الأخبار قبل انتهاء صلاحيتها (0 = بلا مهلة)' }
    NewNewsItemAtTop = @{ Unit = ''; Description = 'الخبر الجديد يُضاف في أول الشريط (عند الإطفاء: في آخره)' }
    NewsListPaged = @{ Unit = ''; Description = 'قائمة الأخبار على صفحات (عند الإطفاء: قائمة واحدة طويلة)' }
    NewsListPageSize = @{ Unit = 'خبر'; Description = 'عدد الأخبار في صفحة قائمة الترتيب' }
    NewsListLabelLength = @{ Unit = 'حرف'; Description = 'طول نص الخبر في الصف الأفقي (مع الأزرار)' }
    NewsListStackedLabelLength = @{ Unit = 'حرف'; Description = 'طول نص الخبر حين يشغل السطر وحده' }
    RepeatWarningCount = @{ Unit = 'مرة'; Description = 'التنبيه عند تكرار القالب هذا العدد خلال النافذة (0 للتعطيل)' }
    RepeatWarningWindowMinutes = @{ Unit = 'دقيقة'; Description = 'نافذة قياس تكرار القالب' }
    MissedEventsHours = @{ Unit = 'ساعة'; Description = 'المدة التي يغطيها ملخص «ماذا فاتني»' }
    QuietHoursEnabled = @{ Unit = ''; Description = 'تجميع التنبيهات غير العاجلة ليلًا وإرسالها صباحًا' }
    QuietHoursStart = @{ Unit = 'ساعة'; Description = 'بداية فترة الهدوء' }
    QuietHoursEnd = @{ Unit = 'ساعة'; Description = 'نهاية فترة الهدوء ووقت إرسال المؤجّل' }
    MaintenanceWindowStart = @{ Unit = 'HH:mm'; Description = 'بداية نافذة الصيانة التلقائية (فارغ للتعطيل)' }
    MaintenanceWindowEnd = @{ Unit = 'HH:mm'; Description = 'نهاية نافذة الصيانة التلقائية' }
    OneHandMode = @{ Unit = ''; Description = 'زر واحد بعرض الشاشة في كل صف (استخدام بيد واحدة)' }
    EnableTextShortcuts = @{ Unit = ''; Description = 'كتابة اسم القالب مباشرة لبدء عرضه' }
    OutputMonitorMinutes = @{ Unit = 'دقيقة'; Description = 'الفاصل بين فحوص صورة المخرج (0 للتعطيل)' }
    OutputMonitorFailureAlertThreshold = @{ Unit = 'محاولة'; Description = 'عدد فشل التقاط المخرج المتتالي قبل تنبيه المشرف (من دون احتياط)' }
    OutputBlackLuminance = @{ Unit = 'سطوع'; Description = 'حد السطوع الذي يُعتبر تحته المخرج أسود' }
    OutputBlackConfirmSeconds = @{ Unit = 'ثانية'; Description = 'الانتظار قبل اللقطة المؤكِّدة الثانية' }
    NotifyOperatorsOnBlackOutput = @{ Unit = ''; Description = 'إشعار المشغّلين أيضًا عند تأكيد الشاشة السوداء' }
    NotifyOnScheduleOverwrite = @{ Unit = ''; Description = 'تنبيه عندما يستبدل حدث مجدول مشهدًا موجودًا على الهواء' }
    AllowRemoteRestart = @{ Unit = ''; Description = 'السماح للمشرف بإعادة تشغيل الجسر من البوت' }
    UsageDigestEnabled = @{ Unit = ''; Description = 'إرسال ملخص استخدام أسبوعي للمشرفين' }
    UsageDigestDayOfWeek = @{ Unit = 'يوم'; Description = 'يوم إرسال الملخص (0 الأحد .. 6 السبت)' }
    AutoHideDefaultSeconds = @{ Unit = 'ثانية'; Description = 'مدة الإخفاء التلقائي الافتراضية' }
    RelayMaxRestarts = @{ Unit = 'محاولة'; Description = 'الحد الأقصى لمحاولات إعادة تشغيل البث' }
    RelayWatchdogSeconds = @{ Unit = 'ثانية'; Description = 'الفاصل بين فحوص البث المباشر' }
    CinegyStateCheckSeconds = @{ Unit = 'ثانية'; Description = 'الفاصل بين فحوص تغير طبقات Cinegy' }
    CinegyHealthCheckSeconds = @{ Unit = 'ثانية'; Description = 'الفاصل بين فحوص صحة Cinegy' }
    CinegyMonitorTimeoutSeconds = @{ Unit = 'ثانية'; Description = 'مهلة فحص حالة Cinegy' }
    CinegyFrameLossTolerance = @{ Unit = 'إطار'; Description = 'الإطارات المفقودة المسموح بها في الدقيقة قبل اعتبار القناة غير سليمة' }
    CinegyFrameLossTolerancePercent = @{ Unit = '%'; Description = 'نسبة الإطارات المفقودة المسموح بها من إجمالي الخرج' }
    CinegyHealthConfirmChecks = @{ Unit = 'فحص'; Description = 'عدد الفحوص المتتالية المتّفقة قبل تغيير حالة صحة Cinegy' }
    CinegyReadErrorRateTolerance = @{ Unit = '%'; Description = 'نسبة أخطاء القراءة المسموح بها قبل اعتبار القناة غير سليمة' }
    RespectCinegyItemDuration = @{ Unit = ''; Description = 'عدم تنبيه القِدَم لقالب حدّد Cinegy مدّته ولم تنتهِ بعد' }
    TemplateBasePath = @{ Unit = ''; Description = 'مجلد المشاهد: يسمح بكتابة اسم الملف وحده في القوالب' }
    CinegyStateBackoffMaxSeconds = @{ Unit = 'ثانية'; Description = 'أقصى تباعد لفحص طبقات Cinegy عند تعذّر الوصول' }
    StaleOnAirAlertHours = @{ Unit = 'ساعة'; Description = 'تنبيه المشرفين عن سجل على الهواء منذ هذه المدة (0 للتعطيل)' }
    SensitiveTemplateAutoHideSeconds = @{ Unit = 'ثانية'; Description = 'الحد الأقصى لبقاء القالب الحساس على الهواء' }
    TemplateTestLayer = @{ Unit = 'طبقة'; Description = 'طبقة تجربة القوالب المستقلة (0 للتعطيل)' }
    TemplateTestAutoHideSeconds = @{ Unit = 'ثانية'; Description = 'مدة إخفاء اختبار القالب تلقائيًا' }
    TemplateRegistryImportMaxTemplates = @{ Unit = 'قالب'; Description = 'الحد الأقصى لعدد القوالب في ملف استيراد سجل القوالب' }
    EnableSafeRollback = @{ Unit = ''; Description = 'تفعيل التراجع الآمن قصير العمر (معطل افتراضيًا)' }
    RollbackWindowSeconds = @{ Unit = 'ثانية'; Description = 'مدة صلاحية التراجع الآمن داخل الذاكرة' }
    HealthFailureAlertThreshold = @{ Unit = 'محاولة'; Description = 'عدد حالات الفشل المتتالية قبل تنبيه المشرف' }
    UserActivityRecentMinutes = @{ Unit = 'دقيقة'; Description = 'مدة اعتبار المستخدم نشطًا حديثًا حسب آخر تفاعل مع البوت' }
    TemplateReminderFollowUpMinutes = @{ Unit = 'دقيقة'; Description = 'مهلة تنبيه المتابعة عند عدم تأكيد معالجة تنبيه القالب (0 للتعطيل)' }
    SchedulePreNotifyMinutes = @{ Unit = 'دقيقة'; Description = 'مدة الإشعار المسبق للحدث المجدول (0 للتعطيل)' }
    MaxPendingApprovals = @{ Unit = 'طلب'; Description = 'الحد الأقصى لطلبات الوصول المعلّقة' }
    PendingApprovalExpiryHours = @{ Unit = 'ساعة'; Description = 'مدة صلاحية طلب الوصول' }
    FavoritesCount = @{ Unit = 'قوالب'; Description = 'عدد القوالب المفضلة المعروضة' }
    RecentValuesPerField = @{ Unit = 'قيم'; Description = 'عدد القيم الحديثة لكل حقل' }
    LogMaxSizeMB = @{ Unit = 'ميغابايت'; Description = 'الحجم الأقصى لملف السجل' }
    LogKeepFiles = @{ Unit = 'ملفات'; Description = 'عدد ملفات السجل المحتفَظ بها' }
    AuditMaxSizeMB = @{ Unit = 'ميغابايت'; Description = 'حجم سجل التدقيق قبل أرشفته في ملف جديد (0 = بلا أرشفة)' }
    AuditArchiveKeepFiles = @{ Unit = 'ملفات'; Description = 'عدد أرشيفات التدقيق المحتفَظ بها (0 = الاحتفاظ بالكل)' }
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

$script:relayPidFile = Join-Path $logDir "relay.pid"
$script:usageFile = Join-Path $logDir "usage.json"
$script:userFavoritesFile = Join-Path $logDir "favorites.json"
$script:userAliasesFile = Join-Path $logDir "user-aliases.json"
$script:disabledUsersFile = Join-Path $logDir "disabled-users.json"
$script:userProfilesFile = Join-Path $logDir "user-profiles.json"
$script:onAirFile = Join-Path $logDir "onair.json"
$script:autoHideFile = Join-Path $logDir "autohide.json"
$script:templateReminderFile = Join-Path $logDir "template-reminders.json"
$script:draftsFile = Join-Path $logDir "drafts.json"
$script:recentValuesFile = Join-Path $logDir "recent-values.json"
$script:scheduleFile = Join-Path $logDir "schedule.json"
$script:scheduleExecutionFile = Join-Path $logDir "schedule-execution.jsonl"
$script:auditFile = Join-Path $logDir "audit.jsonl"
$script:newsDraftFile = Join-Path $logDir 'news-draft.json'
$script:newsBackupDirectory = Join-Path $logDir 'news-backups'
$script:newsImportDirectory = Join-Path $logDir 'news-imports'
$script:NewsTickerDraft = $null







$script:AuditTrail = [System.Collections.Generic.List[string]]::new()
$script:AirOperationCounters = @{ Success = 0; Failed = 0; Blocked = 0 }
$script:UserOperationHistory = @{}
$script:LastShowAttempts = @{}





# ============================================================================
#  Telegram API helpers
# ============================================================================

$script:apiBase = "https://api.telegram.org/bot$($config.BotToken)"
$script:TelegramTextLimit = 3500   # below the hard 4096 so captions/markup fit










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
    @{ command = 'whatsnew'; description = '🆕 ملخص تغييرات الإصدارات الأخيرة' }
    # Admin = $true keeps the command out of the menu every operator sees.
    # Telegram shows one global command list to everybody, so an admin-only
    # command listed there was visible to all - refused on tap, but advertised.
    @{ command = 'stats'; description = '📈 مدة التشغيل وأرقام العمليات'; Admin = $true }
    @{ command = 'digest'; description = '🕘 ماذا فاتني — ملخص ما حدث' }
    @{ command = 'who'; description = '👤 من استخدم قالبًا'; Admin = $true }
    @{ command = 'templates'; description = '📋 عرض القوالب المتاحة' }
    @{ command = 'status'; description = 'ℹ️ حالة النظام والبث والقوالب' }
    @{ command = 'myoperations'; description = '🧾 آخر عملياتي وإعادة المحاولة' }
    @{ command = 'snapshot'; description = '📸 التقاط صورة من البث' }
    @{ command = 'schedule'; description = '📅 جدولة عرض ومراجعة الأحداث القادمة' }
    @{ command = 'hideall'; description = '🚨 إخفاء كل الطبقات (طوارئ)' }
    @{ command = 'settings'; description = '⚙️ الإعدادات'; Admin = $true }
    @{ command = 'audit'; description = '📜 سجل آخر العمليات'; Admin = $true }
    @{ command = 'diagnostics'; description = '🧪 تقرير التشخيص'; Admin = $true }
    @{ command = 'diagbundle'; description = '📦 حزمة تشخيص منقحة'; Admin = $true }
)


# Exact labels of the persistent keyboard buttons. Telegram delivers a tap on
# these as an ordinary text message, so they are matched verbatim (emoji
# included) to avoid ever swallowing legitimate on-air text.
$script:MenuHotword = '🏠 القائمة'
$script:HelpHotword = '🆘 مساعدة'
$script:NewsHotword = '📰 إدارة شريط الأخبار'



# ============================================================================
#  Authorization (user-level, not just chat-level)
# ============================================================================

$script:DisabledUserIds = @{}
$script:UserProfiles = @{}
$script:UserProfilesDirty = $false
$script:LastUserProfilesFlush = [datetime]::MinValue


# ============================================================================
#  News ticker editor (single durable draft; the live file changes on publish)
# ============================================================================




































# ============================================================================
#  Template registry (cached, validated, deterministically ordered)
# ============================================================================

$script:TemplateCache = @{ WriteTime = [datetime]::MinValue; Path = ''; Map = @{}; Order = @(); Errors = @() }












# ---- usage counters (drive the ⭐ favourites row) ----

$script:UsageCounts = @{}
$script:TemplateLastUsed = @{}
$script:UserFavorites = @{}
$script:UserAliases = @{}
$script:UsageDirty = $false
$script:LastUsageFlush = [datetime]::MinValue



















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
$script:LastSnapshotSourceIsPrimary = $true
$script:LastUploadSweep = [datetime]::MinValue
# Seeded to now, not MinValue: the first output check should land one interval
# after launch rather than during startup, when the source may not be up yet
# and nobody is watching for the alert anyway.
# Probe immediately after startup so a stopped primary cannot keep operator
# snapshots on the dead source until the normal monitor interval elapses.
$script:LastOutputMonitorAt = [datetime]::MinValue
$script:OutputBlackAlerted = $false
$script:OutputMonitorFailureCount = 0
$script:OutputMonitorFailureAlerted = $false
$script:OutputMonitorFallbackActive = $false
$script:LastSnapshotSweep = [datetime]::MinValue

# Auto-hide timers created by the ⏱ timed-show button.
$script:AutoHideQueue = [System.Collections.Generic.List[hashtable]]::new()

# Personal, per-template elapsed-time reminders. Unlike an auto-hide timer,
# these never change Cinegy; they only notify the operator who showed a scene.
$script:TemplateReminderQueue = [System.Collections.Generic.List[hashtable]]::new()

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

$script:CancelReasons = @{}
$script:RecentShowTimes = @{}
$script:QuietHoursQueue = [System.Collections.Generic.List[object]]::new()
$script:NewsLockRequest = $null
$script:PendingCancelReason = $null
$script:BridgeStartedAt = Get-Date
$script:TelegramRateLimitHits = 0
$script:RestartRequested = $false
$script:RestartSelfRelaunch = $false
# Long screens waiting behind 📄 المزيد, keyed by chat. In memory only: a
# restart drops them, and the button says so rather than pretending.
$script:PagedText = @{}
$script:PendingSettingsImport = $null
$script:LastUsageDigestDate = [datetime]::MinValue
$script:LastHeartbeatDate = [datetime]::MinValue.Date
$script:LastConfigSaveFailed = $false
# Layers already reported as stale, so the alert fires once per record.
$script:StaleOnAirAlerted = [System.Collections.Generic.HashSet[int]]::new()
$script:HealthHistory = @{
    Telegram = @{ LastSuccess = $null; LastError = ''; LastErrorAt = $null; FailureCount = 0; OutageStartedAt = $null; AlertSent = $false }
    # PendingState/PendingCount hold a verdict that has not been confirmed by
    # enough consecutive readings yet. Declared here because reading a key a
    # hashtable does not have throws under StrictMode.
    Cinegy   = @{ LastSuccess = $null; LastError = ''; LastErrorAt = $null; FailureCount = 0; OutageStartedAt = $null; AlertSent = $false; PendingState = ''; PendingCount = 0 }
}

# ============================================================================
#  Inline keyboards
# ============================================================================
# callback_data is capped at 64 *bytes* by Telegram, and an over-long value
# makes the entire keyboard fail with BUTTON_DATA_INVALID. Template and field
# names (Arabic = 2 bytes/char) are therefore never embedded - only their
# indices into Get-TemplateStore's stable ordering.






































# Settings whose whole purpose is to restrict access. Turning one off from a
# chat button - by accident or by someone who got hold of an admin's phone -
# silently weakens the security model, so they require an explicit confirm.
$script:ProtectedSettings = @('RequireUserLevelAuth', 'EnableSelfServiceRequests', 'EnableRawCommand', 'EnableFullTemplateManagement', 'EnableDpapiSecrets')

# Allowed values for string settings. A typo here would silently stop graphics
# updating, so the choice is constrained rather than free text.
$script:SettingChoices = @{
    AirVariableType = @('Text', 'String', 'Bool', 'Float')
    SceneMode = @('Single', 'Multi')
}

# Version 6 settings navigation. Defaults remain the authoritative setting
# schema for compatibility; this map only controls how administrators discover
# them in Telegram. Any future key omitted here is deliberately shown under
# Advanced rather than becoming unreachable.
$script:SettingCategoryDefinitions = @(
    [pscustomobject]@{ Key = 'security';   Label = 'الأمان والصلاحيات';       Icon = '🔐' }
    [pscustomobject]@{ Key = 'onair';      Label = 'التشغيل على الهواء';      Icon = '🔴' }
    [pscustomobject]@{ Key = 'templates';  Label = 'القوالب والطبقات';        Icon = '📚' }
    [pscustomobject]@{ Key = 'news';       Label = 'شريط الأخبار';            Icon = '📰' }
    [pscustomobject]@{ Key = 'schedule';   Label = 'الجدولة';                 Icon = '📅' }
    [pscustomobject]@{ Key = 'monitoring'; Label = 'المراقبة والتنبيهات';     Icon = '📊' }
    [pscustomobject]@{ Key = 'storage';    Label = 'الملفات والاحتفاظ';       Icon = '🗄️' }
    [pscustomobject]@{ Key = 'advanced';   Label = 'خيارات متقدمة';           Icon = '🛠️' }
)

$script:SettingCategoryByName = @{}
foreach ($entry in @(
        @{ Category = 'security'; Names = @(
                'RequireUserLevelAuth', 'EnableSelfServiceRequests', 'EnableRawCommand',
                'EnableFullTemplateManagement', 'EnableDpapiSecrets', 'MaxPendingApprovals',
                'PendingApprovalExpiryHours', 'UserActivityRecentMinutes'
            ) },
        @{ Category = 'onair'; Names = @(
                'EnableSnapshot', 'EnableLiveRelay', 'EnableTimedShow', 'EnableHideAll',
                'SceneMode',
                'HideAllLayers', 'MaintenanceMode', 'DropPendingUpdatesOnStart',
                'AirCommandTimeoutSeconds', 'TelegramRequestTimeoutSeconds', 'MaxFieldLength',
                'ReshowClearsLayer', 'SetValuesAfterShow', 'PostShowDelayMs',
                'ConfirmLayerRemoval', 'AutoHideDefaultSeconds', 'AutoHidePresetSeconds',
                'RelayAutoRestart', 'RelayMaxRestarts', 'RelayWatchdogSeconds',
                'AllowRemoteRestart'
            ) },
        @{ Category = 'templates'; Names = @(
                'TemplateRegistryImportMaxTemplates', 'ReservedLayers', 'DisabledTemplateKeys',
                'SensitiveTemplateKeys', 'SensitiveTemplateAutoHideSeconds', 'TemplateTestLayer',
                'TemplateTestAutoHideSeconds', 'EnableSafeRollback', 'RollbackWindowSeconds',
                'TemplateReminderFollowUpMinutes',
                'LayerNames', 'EnableFavorites', 'SharedFavoritesEnabled', 'FavoritesCount',
                'RecentValuesPerField', 'TemplateBasePath', 'RespectCinegyItemDuration',
                'ShowLayerLockBadge', 'ButtonTextMaxLength'
            ) },
        @{ Category = 'news'; Names = @(
                'EnableNewsTickerManagement', 'NewsFilePath', 'NewsItemSeparator',
                'NewsMaxItemLength', 'NewsMaxItems', 'NewsImportMaxBytes',
                'NewsDraftTimeoutMinutes', 'NewsListStackedLayout', 'NewNewsItemAtTop',
                'NewsListPaged', 'NewsListPageSize', 'NewsListLabelLength',
                'NewsListStackedLabelLength', 'NewsLockRequestMinutes',
                'AllowOperatorsDeleteNews', 'AllowOperatorsRestoreNews',
                'AllowOperatorsClearAllNews'
            ) },
        @{ Category = 'schedule'; Names = @(
                'ScheduleConflictWindowMinutes', 'SchedulePaused', 'SchedulePreNotifyMinutes',
                'ScheduleMaxRetries', 'ScheduleRetryDelaySeconds', 'ScheduleRetryBackoffFactor',
                'ScheduleRetryMaxDelaySeconds', 'NotifyOnScheduleOverwrite'
            ) },
        @{ Category = 'monitoring'; Names = @(
                'SnapshotCooldownSeconds', 'SnapshotTimeoutSeconds', 'OutputMonitorMinutes',
                'OutputMonitorFailureAlertThreshold', 'OutputBlackLuminance',
                'OutputBlackConfirmSeconds', 'NotifyOperatorsOnBlackOutput',
                'CinegyStateCheckSeconds', 'CinegyStateStaleSeconds',
                'CinegyHealthCheckSeconds', 'CinegyMonitorTimeoutSeconds',
                'CinegyFrameLossTolerance', 'CinegyFrameLossTolerancePercent',
                'CinegyHealthConfirmChecks', 'CinegyReadErrorRateTolerance',
                'CinegyStateBackoffMaxSeconds', 'StaleOnAirAlertHours',
                'HealthFailureAlertThreshold', 'MissedEventsHours', 'QuietHoursEnabled',
                'QuietHoursStart', 'QuietHoursEnd', 'HeartbeatEnabled', 'HeartbeatHour',
                'NotifyAdminsOnRelayFailure', 'NotifyAdminsOnExternalChange',
                'NotifyAdminsOnCinegyHealth', 'UsageDigestEnabled', 'UsageDigestDayOfWeek'
            ) },
        @{ Category = 'storage'; Names = @(
                'SnapshotRetentionMinutes', 'UploadRetentionMinutes', 'NewsBackupKeepFiles',
                'LogMaxSizeMB', 'LogKeepFiles', 'AuditMaxSizeMB', 'AuditArchiveKeepFiles',
                'AuditTrailSize', 'ConfigBackupKeepFiles', 'DiskFreeWarningGB',
                'RuntimeStorageWarningMB', 'BackupStorageWarningMB'
            ) },
        @{ Category = 'advanced'; Names = @(
                'LogAirXml', 'AirVariableType', 'PendingStateTimeoutMinutes',
                'RepeatWarningCount', 'RepeatWarningWindowMinutes', 'MaintenanceWindowStart',
                'MaintenanceWindowEnd', 'OneHandMode', 'EnableTextShortcuts'
            ) }
    )) {
    foreach ($name in $entry.Names) { $script:SettingCategoryByName[$name] = $entry.Category }
}

$script:SettingNavigationLabels = @{
    SceneMode = 'وضع المشاهد'
    RequireUserLevelAuth = 'التحقق من هوية المستخدم'
    EnableSelfServiceRequests = 'طلبات الوصول الذاتية'
    EnableRawCommand = 'الأوامر الخام للمشرف'
    EnableFullTemplateManagement = 'الإدارة الكاملة للقوالب'
    UserActivityRecentMinutes = 'نافذة النشاط الحديث للمستخدم'
    TemplateReminderFollowUpMinutes = 'مهلة متابعة تنبيه القالب'
    EnableDpapiSecrets = 'حماية الأسرار عبر Windows'
}

$script:SettingSchema = @(New-BridgeSettingSchema `
        -Defaults $script:DefaultSettings `
        -DisplayMetadata $script:SettingDisplayMetadata `
        -CategoryByName $script:SettingCategoryByName `
        -Labels $script:SettingNavigationLabels `
        -ProtectedNames $script:ProtectedSettings `
        -Choices $script:SettingChoices)


















# ============================================================================
#  Pending conversation state
# ============================================================================







# ============================================================================
#  Help text
# ============================================================================


# ============================================================================
#  Core on-air actions
# ============================================================================












































































# ============================================================================
#  Access requests / approvals
# ============================================================================




# ============================================================================
#  ffmpeg: shared helpers, snapshot (async), live relay (watchdogged)
# ============================================================================






# ---- snapshot (fully asynchronous: never blocks the polling loop) ----




# ---- live relay ----










# ============================================================================
#  Settings screen
# ============================================================================












# ============================================================================
#  Typed slash-command fallback
# ============================================================================








# ============================================================================
#  Button (callback_query) dispatch
# ============================================================================



# ============================================================================
#  Periodic housekeeping (runs between polls, never blocks)
# ============================================================================












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
        # Ask whether the lock can be TAKEN, not whether the name already
        # exists. Those are different questions, and answering the wrong one
        # locked the bridge out of its own machine: a named mutex outlives its
        # creator for as long as any handle stays open, so after a crash - or
        # a Ctrl+C in a console host that keeps running - the name was still
        # there, createdNew came back false, and every start refused with
        # "another instance already holds it" while nothing held anything.
        #
        # An abandoned mutex is the normal aftermath of a bridge that died
        # without unwinding. AbandonedMutexException means this process now
        # owns it, so it is a success with a warning, never a refusal. On a
        # playout box at three in the morning, refusing to start because a
        # previous copy crashed is the worst possible reading.
        $script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Global\CinegyTelegramBridge')
        $acquired = $false
        try { $acquired = $script:InstanceMutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
            Write-BridgeLog 'Took over a single-instance lock abandoned by a previous run.' 'WARN'
        }
        if (-not $acquired) {
            # Something really is running. Name it before offering to end it:
            # "another instance" is not enough to decide by, and the operator
            # is the one who knows whether that instance is mid-shift.
            $others = @(Get-OtherBridgeProcess)
            foreach ($other in $others) {
                Write-Host "  running: PID $($other.ProcessId), started $($other.StartedAt)"
            }

            $stopIt = $false
            if ($others.Count -eq 0) {
                Write-Host "The lock is held, but no other bridge process can be found - it is held by a console that ran one and stayed open."
            }
            elseif ($StopExisting) { $stopIt = $true }
            elseif ([Environment]::UserInteractive) {
                # Asked, never assumed: stopping the running bridge takes the
                # bot off the air for the seconds it takes to come back, and a
                # scheduled task or service must never sit here waiting for an
                # answer nobody is there to give.
                $answer = ''
                try { $answer = Read-Host "Stop the running instance and start this one? [y/N]" } catch { $answer = '' }
                $stopIt = $answer -match '^(?i:y|yes|ن|نعم)$'
            }

            if ($stopIt) {
                foreach ($other in $others) {
                    Write-Host "Stopping PID $($other.ProcessId)..."
                    Stop-Process -Id $other.ProcessId -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep -Milliseconds 700
                try { $acquired = $script:InstanceMutex.WaitOne(0) }
                catch [System.Threading.AbandonedMutexException] { $acquired = $true }
                if ($acquired) { Write-BridgeLog "Started after stopping $($others.Count) running instance(s) on request." 'WARN' }
            }

            if (-not $acquired) {
                Write-Host "Another CinegyTelegramBridge instance is already running. Exiting."
                Write-Host "Start with -StopExisting to end it automatically."
                Write-BridgeLog "Startup aborted - another instance already holds the single-instance mutex." "ERROR"
                $script:InstanceMutex.Dispose(); $script:InstanceMutex = $null
                exit 1
            }
        }
    }
    catch {
        $message = "Single-instance check unavailable ($($_.Exception.Message))"
        if ($RequireSingleInstance) {
            Write-Host "$message - refusing startup because -RequireSingleInstance was requested."
            Write-BridgeLog "$message - startup refused because strict single-instance mode was requested." 'ERROR'
            if ($script:InstanceMutex) { $script:InstanceMutex.Dispose(); $script:InstanceMutex = $null }
            exit 1
        }
        Write-Host "$message - continuing (default tolerant mode)."
        Write-BridgeLog "$message - continuing in default tolerant mode; use -RequireSingleInstance to refuse startup." 'WARN'
    }
}

Initialize-Settings
Import-UsageCounts
Import-CancelReasons
Import-NewsTickerDraft
Import-UserFavorites
Import-UserAliases
Import-DisabledUsers
Import-UserProfiles
Import-OnAirState
Import-DraftStates
Import-RecentFieldValues
Import-ScheduleEvents
Write-BridgeLog "Restored $(@($script:ScheduleEvents).Count) scheduled event(s); pending timers: $(@(Get-UpcomingScheduleEvents).Count)."
Initialize-CinegyOnAirState | Out-Null
Import-AutoHideQueue
Import-TemplateReminderQueue
Register-BotCommands
Update-SnapshotCleanup -Force   # clear anything orphaned by a previous run
Update-UploadCleanup -Force     # and any staged upload left behind with it

$store = Get-TemplateStore
Write-BridgeLog "Bridge v$($script:BridgeVersion) starting. Air $($config.AirServerAddress):$(5521 + $config.AirChannelNumber), templates: $($store.Order.Count), allowed chats: $(@(Get-JsonProp $config 'AllowedChatIds').Count)"
# An owner who cannot use the bot leaves nobody able to appoint an
# administrator. Said once at startup, because the failure is otherwise
# silent: every screen simply refuses and nothing explains it.
foreach ($ownerWarning in @(Test-OwnerConfiguration)) { Write-BridgeLog $ownerWarning 'WARN' }
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

            if ($updates.Count -gt 0) {
                $highestUpdateId = ($updates | Measure-Object -Property update_id -Maximum).Maximum
                $offset = [long]$highestUpdateId + 1
            }

            foreach ($update in @(Get-BridgeUpdatesForProcessing -Updates $updates)) {
                if (-not (Test-BridgeUpdateAdmission -Ledger $script:ProcessedUpdateLedger -UpdateId ([long]$update.update_id))) {
                    Write-BridgeLog "Skipped duplicate Telegram update $($update.update_id)" 'DEBUG'
                    continue
                }

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
                        elseif($uploadState -and $uploadState.Mode -eq 'settings_import_upload'){Receive-SettingsImport -Document $document -ChatId $chatId -UserId $userId}
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
                                'settings_search' { Complete-SettingsSearch -ChatId $chatId -Value $text | Out-Null }
                                'layer_name' { Complete-LayerName -ChatId $chatId -Value $text | Out-Null }
                                'user_alias_edit' { Complete-UserAliasEdit -ChatId $chatId -AdminUserId $userId -Value $text | Out-Null }
                                'news_add_text' { Complete-NewsTickerAddText -ChatId $chatId -UserId $userId -Value $text | Out-Null }
                                'news_edit_text' { Complete-NewsTickerEditText -ChatId $chatId -UserId $userId -Value $text | Out-Null }
        'template_search' { Complete-TemplateSearch -ChatId $chatId -Value $text | Out-Null }
        'template_reminder_minutes' { Complete-TemplateReminderMinutes -ChatId $chatId -UserId $userId -Value $text | Out-Null }
        'timed_custom' { Complete-TimedShowCustom -ChatId $chatId -Value $text | Out-Null }
                                'layer_timer_custom' { Complete-LayerTimerCustom -ChatId $chatId -Value $text | Out-Null }
                                'template_definition_json' { Complete-TemplateDefinitionJson -ChatId $chatId -Value $text | Out-Null }
                                { $_ -like 'template_create_*' } { Complete-TemplateCreateWizardStep -ChatId $chatId -UserId $userId -Value $text | Out-Null }
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

        # Leaving the loop rather than exiting in place, so the finally block
        # below still stops the relay, saves counters and releases the mutex.
        if ($script:RestartRequested) {
            Write-BridgeLog 'Restart requested - leaving the polling loop' 'WARN'
            break
        }
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

    # Last, and only after the mutex is gone: the replacement takes the same
    # single-instance mutex, so starting it any earlier means it finds the
    # lock still held by a process that is on its way out, and refuses.
    # -NoNewWindow keeps it in the console it was started from, which is the
    # one the operator is looking at.
    if ($script:RestartSelfRelaunch) {
        $relaunch = Get-BridgeRelaunchCommand
        if (-not $relaunch) { Write-BridgeLog 'Restart wanted but the launch command could not be rebuilt - not restarting' 'ERROR' }
        else {
            try {
                Write-BridgeLog "Relaunching: $($relaunch.FilePath) $($relaunch.Arguments -join ' ')" 'WARN'
                Start-Process -FilePath $relaunch.FilePath -ArgumentList $relaunch.Arguments -WorkingDirectory $relaunch.WorkingDirectory -NoNewWindow
            }
            catch { Write-BridgeLog "Relaunch failed: $($_.Exception.Message)" 'ERROR' }
        }
    }
}
