#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the settings area: the eleven doors, their summaries, and every label and description.

    Split out when the catalogue passed a thousand lines: one file per domain
    keeps each under the size this repository asks a file to stay, and puts a
    translator in front of one subject at a time instead of the whole bot.
    Nothing about the contract changed - every entry still carries both
    languages, and Test-BridgeTextCatalogue still reads them all together.
#>

function Add-BridgeTextSettings {
    <# Fills the shared dictionary in place. Partial by design: the catalogue
       is one ordered map assembled from four files, not four maps. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- The eleven settings doors --------------------------------------
    $catalogue['settingCategory.security.label'] = @{ ar = 'الأمان والصلاحيات'; en = 'Security and permissions' }
    $catalogue['settingCategory.onair.label'] = @{ ar = 'التشغيل على الهواء'; en = 'On air' }
    $catalogue['settingCategory.templates.label'] = @{ ar = 'القوالب والطبقات'; en = 'Templates and layers' }
    $catalogue['settingCategory.news.label'] = @{ ar = 'شريط الأخبار'; en = 'News ticker' }
    $catalogue['settingCategory.urgent.label'] = @{ ar = 'جدول العواجل'; en = 'The urgent board' }
    $catalogue['settingCategory.boards.label'] = @{ ar = 'محتوى البرامج'; en = 'Programme content' }
    $catalogue['settingCategory.schedule.label'] = @{ ar = 'الجدولة'; en = 'Scheduling' }
    $catalogue['settingCategory.monitoring.label'] = @{ ar = 'المراقبة والتنبيهات'; en = 'Monitoring and alerts' }
    $catalogue['settingCategory.storage.label'] = @{ ar = 'الملفات والاحتفاظ'; en = 'Files and retention' }
    $catalogue['settingCategory.notifications.label'] = @{ ar = 'الإشعارات والتنبيهات'; en = 'Notifications' }
    $catalogue['settingCategory.advanced.label'] = @{ ar = 'خيارات متقدمة'; en = 'Advanced' }
    $catalogue['settingCategory.security.summary'] = @{ ar = 'من يستطيع التحكم بالهواء، وكيف يُتحقق منه، وأي أبواب إدارية مفتوحة.'; en = 'Who may control the air, how they are verified, and which administrative doors are open.' }
    $catalogue['settingCategory.onair.summary'] = @{ ar = 'ما يظهر ويختفي على الشاشة: أزرار العرض والإخفاء والطوارئ، وكيف يتعامل الجسر مع Cinegy.'; en = 'What appears and disappears on screen: the show, hide and emergency buttons, and how the bridge deals with Cinegy.' }
    $catalogue['settingCategory.templates.summary'] = @{ ar = 'أي قالب متاح، وعلى أي طبقة، وبأي اسم يراه المشغّل.'; en = 'Which template is available, on which layer, and under what name the operator sees it.' }
    $catalogue['settingCategory.news.summary'] = @{ ar = 'الشريط وملفه وحدوده، والربط مع Google Sheets، وما يُسمح به للمشغّل.'; en = 'The ticker, its file and limits, the Google Sheets link, and what an operator is allowed to do with it.' }
    $catalogue['settingCategory.urgent.summary'] = @{ ar = 'الجدول الذي يتقدّم وحده: توقيته وتكراره ونمطه وحدود نصّه، والفاصل بين خبر وآخر.'; en = 'The board that advances by itself: its timing, repeats, mode and text limits, and the gap between stories.' }
    $catalogue['settingCategory.boards.summary'] = @{ ar = 'جداول النصوص المجهَّزة لقوالب البرامج: كم جدولًا، وكم صفًّا في الجدول الواحد.'; en = 'The prepared text tables for programme templates: how many boards, and how many rows in each.' }
    $catalogue['settingCategory.schedule.summary'] = @{ ar = 'الأحداث المؤجلة: متى تُنفَّذ، ومتى يُنبَّه على تعارضها، وماذا يجري إن فشلت.'; en = 'Deferred events: when they run, when a clash is flagged, and what happens if one fails.' }
    $catalogue['settingCategory.monitoring.summary'] = @{ ar = 'ما يراقبه الجسر بنفسه ومتى يوقظ المشرف: المخرج، صحة Cinegy، القوالب المنسية.'; en = 'What the bridge watches by itself and when it wakes an administrator: the output, Cinegy health, forgotten templates.' }
    $catalogue['settingCategory.storage.summary'] = @{ ar = 'كم يُحتفظ بالسجلات واللقطات والنسخ، ومتى يُنبَّه على امتلاء القرص.'; en = 'How long logs, snapshots and backups are kept, and when a full disk is flagged.' }
    $catalogue['settingCategory.notifications.summary'] = @{ ar = 'ما الذي يوقظك ومتى: تنبيهات الهواء والصحة والجدولة، وساعات الهدوء، والملخصات الدورية.'; en = 'What wakes you and when: air, health and schedule alerts, quiet hours, and the periodic digests.' }
    $catalogue['settingCategory.advanced.summary'] = @{ ar = 'تفاصيل التشخيص والسلوك الداخلي؛ لا يحتاجها التشغيل اليومي.'; en = 'Diagnostic detail and internal behaviour; daily operation does not need these.' }

    # --- The settings home screen ---------------------------------------
    $catalogue['settings.title'] = @{ ar = '⚙️ الإعدادات'; en = '⚙️ Settings' }
    $catalogue['settings.intro'] = @{
        ar = 'اختر قسمًا. تظهر الخيارات الشائعة أولًا، وتبقى الإعدادات التقنية في «خيارات متقدمة».'
        en = 'Choose a section. The common choices come first; the technical ones stay in Advanced.'
    }
    $catalogue['settings.search'] = @{ ar = '🔎 بحث'; en = '🔎 Search' }
    $catalogue['settings.modifiedOnly'] = @{ ar = '📝 المعدّل فقط'; en = '📝 Changed only' }
    $catalogue['settings.simple'] = @{ ar = '🧭 مبسّط'; en = '🧭 Simple' }
    $catalogue['settings.advanced'] = @{ ar = '🛠 متقدم'; en = '🛠 Advanced' }
    $catalogue['settings.hideAllScope'] = @{ ar = '🚨 طبقات إخفاء الكل: {0}'; en = '🚨 Hide-all layers: {0}' }
    $catalogue['settings.hideAllScope.all'] = @{ ar = 'كل الطبقات المعروفة'; en = 'every known layer' }
    $catalogue['settings.hideAllScope.some'] = @{ ar = 'طبقات: {0}'; en = 'layers: {0}' }
    $catalogue['settings.hideAllScope.none'] = @{ ar = 'لا توجد طبقات محددة'; en = 'none selected' }
    $catalogue['settings.layerNames'] = @{ ar = '🏷️ أسماء الطبقات'; en = '🏷️ Layer names' }
    $catalogue['settings.backups'] = @{ ar = '🗄 نسخ الإعدادات'; en = '🗄 Settings backups' }
    $catalogue['settings.reset'] = @{ ar = '♻️ استعادة الافتراضي'; en = '♻️ Restore defaults' }

    # --- Every setting label, resolved through TF at read time ----------
    # The Arabic here is the same text $script:SettingNavigationLabels has
    # shipped all along; holding both together is what lets the catalogue
    # test see a label that has gained an English half and lost its Arabic.
    $catalogue['setting.EnableSnapshot.label'] = @{ ar = 'التقاط لقطات البث'; en = 'Output snapshots' }
    $catalogue['setting.LiveWatchUrl.label'] = @{ ar = 'رابط صفحة المشاهدة'; en = 'The watch page address' }
    $catalogue['setting.EnableLiveRelay.label'] = @{ ar = 'ترحيل البث المباشر'; en = 'Live relay' }
    $catalogue['setting.EnableTimedShow.label'] = @{ ar = 'العرض المؤقت'; en = 'Timed show' }
    $catalogue['setting.EnableHideAll.label'] = @{ ar = 'تفعيل إخفاء الكل'; en = 'Hide-all button' }
    $catalogue['setting.HideAllLayers.label'] = @{ ar = 'طبقات إخفاء الكل'; en = 'Hide-all layers' }
    $catalogue['setting.ReservedLayers.label'] = @{ ar = 'الطبقات المحجوزة'; en = 'Reserved layers' }
    $catalogue['setting.AdminOnlyTemplateKeys.label'] = @{ ar = 'قوالب للمشرفين'; en = 'Administrator-only templates' }
    $catalogue['setting.OwnerOnlyTemplateKeys.label'] = @{ ar = 'قوالب للمالك'; en = 'Owner-only templates' }
    $catalogue['setting.AdminOnlyLayers.label'] = @{ ar = 'طبقات للمشرفين'; en = 'Administrator-only layers' }
    $catalogue['setting.OwnerOnlyLayers.label'] = @{ ar = 'طبقات للمالك'; en = 'Owner-only layers' }
    $catalogue['setting.LayersScreenAccess.label'] = @{ ar = 'من يرى زر الطبقات'; en = 'Who sees the layers button' }
    $catalogue['setting.DisabledTemplateKeys.label'] = @{ ar = 'القوالب المعطّلة'; en = 'Disabled templates' }
    $catalogue['setting.SensitiveTemplateKeys.label'] = @{ ar = 'القوالب الحساسة'; en = 'Sensitive templates' }
    $catalogue['setting.TemplateMaxAirSeconds.label'] = @{ ar = 'أقصى مدة لكل قالب'; en = 'Maximum air time per template' }
    $catalogue['setting.TemplateAirExtensionEnabled.label'] = @{ ar = 'تمديد واحد للمشغّل'; en = 'One operator extension' }
    $catalogue['setting.TemplateAirExtensionResponseSeconds.label'] = @{ ar = 'مهلة الرد على التمديد'; en = 'Extension reply window' }
    $catalogue['setting.TemplateAirExtensionMaxSeconds.label'] = @{ ar = 'أقصى مدة للتمديد'; en = 'Maximum extension' }
    $catalogue['setting.LayerNames.label'] = @{ ar = 'أسماء الطبقات'; en = 'Layer names' }
    $catalogue['setting.EnableFavorites.label'] = @{ ar = 'المفضلة'; en = 'Favourites' }
    $catalogue['setting.MaintenanceMode.label'] = @{ ar = 'وضع الصيانة'; en = 'Maintenance mode' }
    $catalogue['setting.EnablePersistentMenuButton.label'] = @{ ar = 'زر القائمة الثابت'; en = 'Persistent menu button' }
    $catalogue['setting.EnableNewsTickerManagement.label'] = @{ ar = 'إدارة شريط الأخبار'; en = 'News ticker management' }
    $catalogue['setting.NewsFilePath.label'] = @{ ar = 'ملف الأخبار'; en = 'News file' }
    $catalogue['setting.NewsItemSeparator.label'] = @{ ar = 'فاصل الأخبار'; en = 'News separator' }
    $catalogue['setting.NewsSheetCsvUrl.label'] = @{ ar = 'رابط Google Sheets (CSV)'; en = 'Google Sheets link (CSV)' }
    $catalogue['setting.NewsSheetSyncMode.label'] = @{ ar = 'وضع مزامنة الشيت'; en = 'Sheet sync mode' }
    $catalogue['setting.NewsSheetSyncMinutes.label'] = @{ ar = 'كل كم دقيقة تُزامن الشيت'; en = 'Sheet sync interval' }
    $catalogue['setting.NewsSheetTimeoutSeconds.label'] = @{ ar = 'مهلة تنزيل الشيت'; en = 'Sheet download timeout' }
    $catalogue['setting.NewsSheetNotifyScope.label'] = @{ ar = 'من يُنبَّه بعد مزامنة الشيت'; en = 'Who is told after a sheet sync' }
    $catalogue['setting.NewsPublishNotifyScope.label'] = @{ ar = 'من يُنبَّه بعد النشر اليدوي'; en = 'Who is told after a manual publish' }
    $catalogue['setting.NewsSheetFailureAlertAfter.label'] = @{ ar = 'تنبيه فشل مزامنة الشيت'; en = 'Sheet sync failure alert' }
    $catalogue['setting.AllowOperatorsSheetPull.label'] = @{ ar = 'سماح المشغّلين بسحب الشيت'; en = 'Operators may pull the sheet' }
    $catalogue['setting.NewsMaxItemLength.label'] = @{ ar = 'الحد الأقصى لطول الخبر'; en = 'Maximum headline length' }
    $catalogue['setting.NewsMaxItems.label'] = @{ ar = 'الحد الأقصى لعدد الأخبار'; en = 'Maximum number of headlines' }
    $catalogue['setting.NewsImportMaxBytes.label'] = @{ ar = 'حد استيراد الأخبار'; en = 'News import size limit' }
    $catalogue['setting.NewsBackupKeepFiles.label'] = @{ ar = 'نسخ الأخبار المحفوظة'; en = 'News backups kept' }
    $catalogue['setting.NewsLockRequestMinutes.label'] = @{ ar = 'مهلة قفل مسودة الأخبار'; en = 'News draft lock timeout' }
    $catalogue['setting.NewsLockGrantHoldSeconds.label'] = @{ ar = 'حجز قفل الأخبار بعد التسليم'; en = 'Lock hold after handover' }
    $catalogue['setting.AllowOperatorsDeleteNews.label'] = @{ ar = 'السماح للمشغل بحذف الأخبار'; en = 'Operators may delete headlines' }
    $catalogue['setting.AllowOperatorsRestoreNews.label'] = @{ ar = 'السماح للمشغل باستعادة الأخبار'; en = 'Operators may restore headlines' }
    $catalogue['setting.AllowOperatorsClearAllNews.label'] = @{ ar = 'السماح للمشغل بمسح كل الأخبار'; en = 'Operators may clear all headlines' }
    $catalogue['setting.DropPendingUpdatesOnStart.label'] = @{ ar = 'إسقاط التحديثات عند البدء'; en = 'Drop pending updates at start' }
    $catalogue['setting.LogAirXml.label'] = @{ ar = 'تسجيل XML الخاص بـ Cinegy'; en = 'Log Cinegy XML' }
    $catalogue['setting.ReshowClearsLayer.label'] = @{ ar = 'مسح الطبقة قبل إعادة العرض'; en = 'Clear the layer before re-showing' }
    $catalogue['setting.AirVariableType.label'] = @{ ar = 'نوع متغيرات Cinegy'; en = 'Cinegy variable type' }
    $catalogue['setting.SetValuesAfterShow.label'] = @{ ar = 'تحديث القيم بعد العرض'; en = 'Set values after show' }
    $catalogue['setting.AutoHidePresetSeconds.label'] = @{ ar = 'مدد الإخفاء الجاهزة'; en = 'Auto-hide presets' }
    $catalogue['setting.RelayAutoRestart.label'] = @{ ar = 'إعادة تشغيل الترحيل تلقائيًا'; en = 'Restart the relay automatically' }
    $catalogue['setting.CinegyStateStaleSeconds.label'] = @{ ar = 'حد قِدم حالة Cinegy'; en = 'Cinegy state staleness limit' }
    $catalogue['setting.ScheduleConflictWindowMinutes.label'] = @{ ar = 'نافذة تعارض الجدولة'; en = 'Schedule clash window' }
    $catalogue['setting.SchedulePaused.label'] = @{ ar = 'إيقاف الجدولة مؤقتًا'; en = 'Pause scheduling' }
    $catalogue['setting.ScheduleMaxRetries.label'] = @{ ar = 'أقصى محاولات الجدولة'; en = 'Maximum schedule retries' }
    $catalogue['setting.ScheduleRetryDelaySeconds.label'] = @{ ar = 'تأخير إعادة محاولة الجدولة'; en = 'Schedule retry delay' }
    $catalogue['setting.ScheduleRetryBackoffFactor.label'] = @{ ar = 'معامل تراجع إعادة المحاولة'; en = 'Retry backoff factor' }
    $catalogue['setting.ScheduleRetryMaxDelaySeconds.label'] = @{ ar = 'أقصى تأخير لإعادة المحاولة'; en = 'Maximum retry delay' }
    $catalogue['setting.HeartbeatEnabled.label'] = @{ ar = 'نبض الجسر'; en = 'Bridge heartbeat' }
    $catalogue['setting.NotifyAdminsOnRelayFailure.label'] = @{ ar = 'إشعار المشرفين بفشل الترحيل'; en = 'Tell admins about relay failures' }
    $catalogue['setting.NotifyAdminsOnExternalChange.label'] = @{ ar = 'إشعار المشرفين بالتغيير الخارجي'; en = 'Tell admins about external changes' }
    $catalogue['setting.NotifyAdminsOnCinegyHealth.label'] = @{ ar = 'إشعار المشرفين بصحة Cinegy'; en = 'Tell admins about Cinegy health' }
    $catalogue['setting.SceneMode.label'] = @{ ar = 'وضع المشاهد'; en = 'Scene mode' }
    $catalogue['setting.RequireUserLevelAuth.label'] = @{ ar = 'التحقق من هوية المستخدم'; en = 'Verify the user identity' }
    $catalogue['setting.EnableSelfServiceRequests.label'] = @{ ar = 'طلبات الوصول الذاتية'; en = 'Self-service access requests' }
    $catalogue['setting.EnableAnnouncements.label'] = @{ ar = 'تنويهات المشرفين'; en = 'Administrator announcements' }
    $catalogue['setting.AnnouncementMaxLength.label'] = @{ ar = 'طول التنويه'; en = 'Announcement length' }
    $catalogue['setting.AnnouncementDefaultExpiryHours.label'] = @{ ar = 'مدة التنويه الافتراضية'; en = 'Default announcement lifetime' }
    $catalogue['setting.NotifyAdminsOnAccessRequest.label'] = @{ ar = 'إشعار طلبات الوصول'; en = 'Access request alerts' }
    $catalogue['setting.NotifyAdminsOnBlockedChat.label'] = @{ ar = 'إشعار الحظر التلقائي'; en = 'Automatic block alerts' }
    $catalogue['setting.NotifyAdminsOnMissingGraphic.label'] = @{ ar = 'تنبيه غياب قالب دائم'; en = 'Missing permanent graphic alert' }
    $catalogue['setting.MissingGraphicConfirmChecks.label'] = @{ ar = 'فحوص تأكيد الغياب'; en = 'Checks confirming it is missing' }
    $catalogue['setting.BlockRejectedRequesters.label'] = @{ ar = 'حظر من رُفض طلبه'; en = 'Block a rejected requester' }
    $catalogue['setting.JoinSecret.label'] = @{ ar = 'رمز الانضمام'; en = 'Join code' }
    $catalogue['setting.JoinSecretMaxAttempts.label'] = @{ ar = 'محاولات رمز الانضمام'; en = 'Join code attempts' }
    $catalogue['setting.MaxAccessRequestsPerDay.label'] = @{ ar = 'طلبات الوصول يوميًا'; en = 'Access requests per day' }
    $catalogue['setting.DormantUserDays.label'] = @{ ar = 'أيام خمول المستخدم'; en = 'Days before a user is dormant' }
    $catalogue['setting.AutoDisableDormantUsers.label'] = @{ ar = 'تعطيل الخامل تلقائيًا'; en = 'Disable dormant users automatically' }
    $catalogue['setting.LeaveUnknownGroups.label'] = @{ ar = 'مغادرة المجموعات المجهولة'; en = 'Leave unknown groups' }
    $catalogue['setting.EnableRawCommand.label'] = @{ ar = 'الأوامر الخام للمشرف'; en = 'Raw administrator commands' }
    $catalogue['setting.EnableFullTemplateManagement.label'] = @{ ar = 'الإدارة الكاملة للقوالب'; en = 'Full template management' }
    $catalogue['setting.UserActivityRecentMinutes.label'] = @{ ar = 'نافذة النشاط الحديث للمستخدم'; en = 'Recent-activity window' }
    $catalogue['setting.TemplateReminderFollowUpMinutes.label'] = @{ ar = 'مهلة متابعة تنبيه القالب'; en = 'Template reminder follow-up' }
    $catalogue['setting.EnableDpapiSecrets.label'] = @{ ar = 'حماية الأسرار عبر Windows'; en = 'Protect secrets with Windows DPAPI' }
    $catalogue['setting.MojazMultiDesign.label'] = @{ ar = 'موجز متعدد التصاميم'; en = 'Multi-design bulletin' }
    $catalogue['setting.MojazAnchorToAirClock.label'] = @{ ar = 'ضبط الزمن من Cinegy'; en = 'Take timing from Cinegy' }
    $catalogue['setting.MojazRowFrames.label'] = @{ ar = 'إطارات صف الموجز'; en = 'Bulletin row frames' }
    $catalogue['setting.MojazImageKeepHours.label'] = @{ ar = 'الاحتفاظ بصور الموجز'; en = 'Keep bulletin images' }
    $catalogue['setting.BroadcastFps.label'] = @{ ar = 'معدل إطارات القناة'; en = 'Channel frame rate' }
    $catalogue['setting.MojazIntroExtraFrames.label'] = @{ ar = 'إطارات الصف الأول'; en = 'First row frames' }
    $catalogue['setting.MojazLastRowFrames.label'] = @{ ar = 'إطارات الصف الأخير'; en = 'Last row frames' }
    $catalogue['setting.MojazSyncOffsetMs.label'] = @{ ar = 'لحظة الكتابة داخل الظهور'; en = 'Write moment inside the reveal' }
    $catalogue['setting.MojazSyncLeadMs.label'] = @{ ar = 'تعويض زمن الشبكة'; en = 'Network latency compensation' }
    $catalogue['setting.MojazNotifyOnFinish.label'] = @{ ar = 'إشعار انتهاء الموجز'; en = 'Tell me when the bulletin ends' }
    $catalogue['setting.MojazScheduleNoticeSeconds.label'] = @{ ar = 'تنبيه قبل الموعد'; en = 'Warning before a scheduled run' }
    $catalogue['setting.MojazHidesTicker.label'] = @{ ar = 'إخفاء الشريط أثناء الموجز'; en = 'Hide the ticker during a bulletin' }
    $catalogue['setting.EnableUrgentBoard.label'] = @{ ar = 'إدارة العواجل'; en = 'Urgent board' }
    $catalogue['setting.UrgentBoardIntervalSeconds.label'] = @{ ar = 'فاصل العواجل'; en = 'Urgent interval' }
    $catalogue['setting.UrgentBoardRepeats.label'] = @{ ar = 'تكرار العواجل'; en = 'Urgent repeats' }
    $catalogue['setting.UrgentBoardMode.label'] = @{ ar = 'نمط عرض العواجل'; en = 'Urgent display mode' }
    $catalogue['setting.UrgentBoardRepeatMode.label'] = @{ ar = 'ترتيب التكرار'; en = 'Repeat order' }
    $catalogue['setting.UrgentBoardTotalSeconds.label'] = @{ ar = 'المدة الكلية للعواجل'; en = 'Total urgent run time' }
    $catalogue['setting.UrgentBoardMaxItems.label'] = @{ ar = 'حدّ عدد العواجل'; en = 'Maximum urgent items' }
    $catalogue['setting.UrgentMinIntervalSeconds.label'] = @{ ar = 'أقصر فاصل للعواجل'; en = 'Shortest urgent interval' }
    $catalogue['setting.UrgentExitGapSeconds.label'] = @{ ar = 'الفاصل بين الأخبار'; en = 'Gap between stories' }
    $catalogue['setting.Language.label'] = @{ ar = 'لغة الجسر'; en = 'Bridge language' }
    $catalogue['setting.EnableContentBoards.label'] = @{ ar = 'محتوى البرامج'; en = 'Programme content boards' }
    $catalogue['setting.MaxContentBoards.label'] = @{ ar = 'أقصى عدد الجداول'; en = 'Maximum boards' }
    $catalogue['setting.BoardMaxItems.label'] = @{ ar = 'أقصى صفوف الجدول'; en = 'Maximum rows per board' }
    $catalogue['setting.UrgentSyncLeadMs.label'] = @{ ar = 'تعويض زمن الشبكة للعواجل'; en = 'Urgent network latency compensation' }
    $catalogue['setting.UrgentBoardNotifyOnFinish.label'] = @{ ar = 'إشعار انتهاء العواجل'; en = 'Tell me when the urgent run ends' }
    $catalogue['setting.UrgentBoardMaxTextLength.label'] = @{ ar = 'أطول نصّ عاجل'; en = 'Longest urgent text' }
    $catalogue['setting.MojazImageWidth.label'] = @{ ar = 'عرض صورة الصف'; en = 'Row image width' }
    $catalogue['setting.MojazImageHeight.label'] = @{ ar = 'ارتفاع صورة الصف'; en = 'Row image height' }
    $catalogue['setting.AirCommandTimeoutSeconds.label'] = @{ ar = 'مهلة أمر Cinegy'; en = 'Cinegy command timeout' }
    $catalogue['setting.AllowRemoteRestart.label'] = @{ ar = 'إعادة التشغيل من البوت'; en = 'Restart from the bot' }
    $catalogue['setting.AuditArchiveKeepFiles.label'] = @{ ar = 'أرشيفات التدقيق المحفوظة'; en = 'Audit archives kept' }
    $catalogue['setting.AuditMaxSizeMB.label'] = @{ ar = 'حجم سجل التدقيق'; en = 'Audit log size' }
    $catalogue['setting.AuditTemplateValues.label'] = @{ ar = 'تسجيل نص القالب'; en = 'Record template text' }
    $catalogue['setting.AuditTemplateValuesMaxChars.label'] = @{ ar = 'طول النص المسجَّل'; en = 'Recorded text length' }
    $catalogue['setting.AuditTrailSize.label'] = @{ ar = 'حجم سجل العمليات'; en = 'Operation log size' }
    $catalogue['setting.AutoHideDefaultSeconds.label'] = @{ ar = 'مدة الإخفاء الافتراضية'; en = 'Default auto-hide time' }
    $catalogue['setting.BackupStorageWarningMB.label'] = @{ ar = 'تنبيه حجم النسخ'; en = 'Backup size warning' }
    $catalogue['setting.ButtonTextMaxLength.label'] = @{ ar = 'طول نص الأزرار'; en = 'Button text length' }
    $catalogue['setting.CinegyFrameLossTolerance.label'] = @{ ar = 'الإطارات المفقودة المسموحة'; en = 'Dropped frames allowed' }
    $catalogue['setting.CinegyFrameLossTolerancePercent.label'] = @{ ar = 'نسبة الإطارات المفقودة'; en = 'Dropped frame percentage' }
    $catalogue['setting.CinegyHealthCheckSeconds.label'] = @{ ar = 'فاصل فحص صحة Cinegy'; en = 'Cinegy health check interval' }
    $catalogue['setting.CinegyHealthConfirmChecks.label'] = @{ ar = 'فحوص تأكيد الحالة'; en = 'Checks confirming the state' }
    $catalogue['setting.CinegyMonitorTimeoutSeconds.label'] = @{ ar = 'مهلة فحص Cinegy'; en = 'Cinegy check timeout' }
    $catalogue['setting.CinegyReadErrorRateTolerance.label'] = @{ ar = 'نسبة أخطاء القراءة'; en = 'Read error rate allowed' }
    $catalogue['setting.CinegyStateBackoffMaxSeconds.label'] = @{ ar = 'أقصى تباعد عند التعذّر'; en = 'Maximum backoff when unreachable' }
    $catalogue['setting.CinegyStateCheckSeconds.label'] = @{ ar = 'فاصل فحص الطبقات'; en = 'Layer check interval' }
    $catalogue['setting.DiscoverExternalLayers.label'] = @{ ar = 'تبنّي الطبقات الخارجية'; en = 'Adopt external layers' }
    $catalogue['setting.TelegramPollMarginSeconds.label'] = @{ ar = 'مهلة الاستطلاع الإضافية'; en = 'Extra poll timeout' }
    $catalogue['setting.TelegramPollTimeoutTolerance.label'] = @{ ar = 'تأخر الاستطلاع المحتمل'; en = 'Tolerated poll delays' }
    $catalogue['setting.ConfigBackupKeepFiles.label'] = @{ ar = 'نسخ الإعدادات المحفوظة'; en = 'Settings backups kept' }
    $catalogue['setting.AskRequesterName.label'] = @{ ar = 'سؤال طالب الوصول عن اسمه'; en = 'Ask a requester for their name' }
    $catalogue['setting.ConfirmLayerRemoval.label'] = @{ ar = 'تأكيد قبل الإخفاء'; en = 'Confirm before hiding' }
    $catalogue['setting.ShowOnAirTextOnRemoval.label'] = @{ ar = 'عرض النص قبل الإخفاء'; en = 'Show the text before hiding' }
    $catalogue['setting.DiskFreeWarningGB.label'] = @{ ar = 'تنبيه مساحة القرص'; en = 'Free disk warning' }
    $catalogue['setting.EnableButtonStyles.label'] = @{ ar = 'تلوين الأزرار'; en = 'Colour the buttons' }
    $catalogue['setting.EnableSafeRollback.label'] = @{ ar = 'التراجع الآمن'; en = 'Safe rollback' }
    $catalogue['setting.EnableTextShortcuts.label'] = @{ ar = 'اختصارات الكتابة'; en = 'Typing shortcuts' }
    $catalogue['setting.FavoritesCount.label'] = @{ ar = 'عدد المفضلة المعروضة'; en = 'Favourites shown' }
    $catalogue['setting.HealthFailureAlertThreshold.label'] = @{ ar = 'حد تنبيه الفشل'; en = 'Failure alert threshold' }
    $catalogue['setting.HeartbeatHour.label'] = @{ ar = 'ساعة النبض اليومي'; en = 'Daily heartbeat hour' }
    $catalogue['setting.LogKeepFiles.label'] = @{ ar = 'ملفات السجل المحفوظة'; en = 'Log files kept' }
    $catalogue['setting.LogMaxSizeMB.label'] = @{ ar = 'حجم ملف السجل'; en = 'Log file size' }
    $catalogue['setting.ExecutionLogKeepRecords.label'] = @{ ar = 'سجلات التنفيذ المحفوظة'; en = 'Execution records kept' }
    $catalogue['setting.ScheduleHistoryKeepDays.label'] = @{ ar = 'تاريخ الجدولة المحفوظ'; en = 'Schedule history kept' }
    $catalogue['setting.AccessGuardKeepDays.label'] = @{ ar = 'مدة تذكّر المحظورين'; en = 'How long blocks are remembered' }
    $catalogue['setting.MaintenanceWindowEnd.label'] = @{ ar = 'نهاية نافذة الصيانة'; en = 'Maintenance window end' }
    $catalogue['setting.MaintenanceWindowStart.label'] = @{ ar = 'بداية نافذة الصيانة'; en = 'Maintenance window start' }
    $catalogue['setting.MaxFieldLength.label'] = @{ ar = 'طول نص الحقل'; en = 'Field text length' }
    $catalogue['setting.MaxPendingApprovals.label'] = @{ ar = 'طلبات الوصول المعلّقة'; en = 'Pending access requests' }
    $catalogue['setting.MissedEventsHours.label'] = @{ ar = 'مدة «ماذا فاتني»'; en = 'What-did-I-miss window' }
    $catalogue['setting.NewNewsItemAtTop.label'] = @{ ar = 'مكان الخبر الجديد'; en = 'Where a new headline goes' }
    $catalogue['setting.NewsDraftTimeoutMinutes.label'] = @{ ar = 'مهلة مسودة الأخبار'; en = 'News draft timeout' }
    $catalogue['setting.NewsListLabelLength.label'] = @{ ar = 'طول الخبر في القائمة'; en = 'Headline length in the list' }
    $catalogue['setting.NewsListLayout.label'] = @{ ar = 'شكل قائمة الأخبار'; en = 'News list layout' }
    $catalogue['setting.NewsListPaged.label'] = @{ ar = 'تقسيم القائمة لصفحات'; en = 'Page the list' }
    $catalogue['setting.NewsListPageSize.label'] = @{ ar = 'أخبار كل صفحة'; en = 'Headlines per page' }
    $catalogue['setting.NewsListStackedLabelLength.label'] = @{ ar = 'طول الخبر في سطره'; en = 'Headline length on its own line' }
    $catalogue['setting.NotifyOnScheduleOverwrite.label'] = @{ ar = 'تنبيه استبدال مشهد'; en = 'Warn when a scene is replaced' }
    $catalogue['setting.NotifyOperatorsOnBlackOutput.label'] = @{ ar = 'إشعار المشغّلين بالسواد'; en = 'Tell operators about black output' }
    $catalogue['setting.TemplateNotifyRules.label'] = @{ ar = 'إشعار العرض حسب القالب'; en = 'Show notices per template' }
    $catalogue['setting.OneHandMode.label'] = @{ ar = 'وضع اليد الواحدة'; en = 'One-hand mode' }
    $catalogue['setting.OutputBlackConfirmSeconds.label'] = @{ ar = 'انتظار اللقطة المؤكِّدة'; en = 'Wait for the confirming frame' }
    $catalogue['setting.OutputBlackLuminance.label'] = @{ ar = 'حد سطوع السواد'; en = 'Black luminance threshold' }
    $catalogue['setting.OutputMonitorFailureAlertThreshold.label'] = @{ ar = 'حد تنبيه فشل الالتقاط'; en = 'Capture failure alert threshold' }
    $catalogue['setting.OutputMonitorFlapAlertCount.label'] = @{ ar = 'حد تنبيه تذبذب المصدر'; en = 'Source flapping alert threshold' }
    $catalogue['setting.OutputMonitorMinutes.label'] = @{ ar = 'فاصل مراقبة المخرج'; en = 'Output monitoring interval' }
    $catalogue['setting.EnableTextChecks.label'] = @{ ar = 'التنبيهات الإملائية'; en = 'Spelling warnings' }
    $catalogue['setting.EnableMaterialSchedule.label'] = @{ ar = 'شاشة جدول المواد'; en = 'Material schedule screen' }
    $catalogue['setting.EnableShiftHandover.label'] = @{ ar = 'شاشة تسليم المناوبة'; en = 'Shift handover screen' }
    $catalogue['setting.NotifyAdminsOnMissingProxy.label'] = @{ ar = 'تنبيه المادة بلا نسخة محلية'; en = 'Alert on material with no local copy' }
    $catalogue['setting.RepeatAlertWindowHours.label'] = @{ ar = 'نافذة تكرار التنبيه'; en = 'Repeat alert window' }
    $catalogue['setting.AlertMaxPerCausePerHour.label'] = @{ ar = 'سقف تنبيهات السبب الواحد'; en = 'Alerts per cause per hour' }
    $catalogue['setting.MaterialProxyLeadMinutes.label'] = @{ ar = 'مهلة فحص النسخة المحلية'; en = 'Local copy check lead time' }
    $catalogue['setting.PendingApprovalExpiryHours.label'] = @{ ar = 'صلاحية طلب الوصول'; en = 'Access request lifetime' }
    $catalogue['setting.PendingStateTimeoutMinutes.label'] = @{ ar = 'مهلة الإدخال غير المكتمل'; en = 'Unfinished input timeout' }
    $catalogue['setting.PostShowDelayMs.label'] = @{ ar = 'تأخير النص بعد العرض'; en = 'Text delay after show' }
    $catalogue['setting.QuietHoursEnabled.label'] = @{ ar = 'فترة الهدوء'; en = 'Quiet hours' }
    $catalogue['setting.QuietHoursEnd.label'] = @{ ar = 'نهاية فترة الهدوء'; en = 'Quiet hours end' }
    $catalogue['setting.QuietHoursStart.label'] = @{ ar = 'بداية فترة الهدوء'; en = 'Quiet hours start' }
    $catalogue['setting.RecentValuesPerField.label'] = @{ ar = 'القيم الحديثة لكل حقل'; en = 'Recent values per field' }
    $catalogue['setting.RelayMaxRestarts.label'] = @{ ar = 'محاولات إعادة البث'; en = 'Relay restart attempts' }
    $catalogue['setting.RelayWatchdogSeconds.label'] = @{ ar = 'فاصل فحص البث'; en = 'Relay check interval' }
    $catalogue['setting.RepeatWarningCount.label'] = @{ ar = 'حد تنبيه التكرار'; en = 'Repeat warning threshold' }
    $catalogue['setting.RepeatWarningWindowMinutes.label'] = @{ ar = 'نافذة قياس التكرار'; en = 'Repeat measurement window' }
    $catalogue['setting.RespectCinegyItemDuration.label'] = @{ ar = 'احترام مدة Cinegy'; en = 'Respect the Cinegy duration' }
    $catalogue['setting.RollbackWindowSeconds.label'] = @{ ar = 'مدة التراجع الآمن'; en = 'Safe rollback window' }
    $catalogue['setting.RuntimeStorageWarningMB.label'] = @{ ar = 'تنبيه حجم ملفات التشغيل'; en = 'Runtime file size warning' }
    $catalogue['setting.SchedulePreNotifyMinutes.label'] = @{ ar = 'الإشعار المسبق للحدث'; en = 'Advance notice for an event' }
    $catalogue['setting.SensitiveTemplateAutoHideSeconds.label'] = @{ ar = 'إخفاء القالب الحساس'; en = 'Sensitive template auto-hide' }
    $catalogue['setting.ShowLayerLockBadge.label'] = @{ ar = 'شارة قفل الطبقة'; en = 'Layer lock badge' }
    $catalogue['setting.SnapshotCooldownSeconds.label'] = @{ ar = 'فاصل بين اللقطات'; en = 'Gap between snapshots' }
    $catalogue['setting.SnapshotRetentionMinutes.label'] = @{ ar = 'الاحتفاظ بصور البث'; en = 'Keep output stills' }
    $catalogue['setting.SnapshotTimeoutSeconds.label'] = @{ ar = 'مهلة التقاط الصورة'; en = 'Snapshot timeout' }
    $catalogue['setting.StaleOnAirAlertHours.label'] = @{ ar = 'تنبيه القالب المنسي'; en = 'Forgotten template alert' }
    $catalogue['setting.StartupStormThreshold.label'] = @{ ar = 'تنبيه عاصفة الإقلاع'; en = 'Startup storm threshold' }
    $catalogue['setting.TelegramRequestTimeoutSeconds.label'] = @{ ar = 'مهلة طلبات Telegram'; en = 'Telegram request timeout' }
    $catalogue['setting.TemplateBasePath.label'] = @{ ar = 'مجلد المشاهد'; en = 'Scenes folder' }
    $catalogue['setting.TemplateRegistryImportMaxTemplates.label'] = @{ ar = 'حد استيراد القوالب'; en = 'Template import limit' }
    $catalogue['setting.TemplateTestAutoHideSeconds.label'] = @{ ar = 'إخفاء اختبار القالب'; en = 'Template test auto-hide' }
    $catalogue['setting.TemplateTestLayer.label'] = @{ ar = 'طبقة تجربة القوالب'; en = 'Template test layer' }
    $catalogue['setting.UploadRetentionMinutes.label'] = @{ ar = 'الاحتفاظ بالملفات المرفوعة'; en = 'Keep uploaded files' }
    $catalogue['setting.UsageDigestDayOfWeek.label'] = @{ ar = 'يوم الملخص الأسبوعي'; en = 'Weekly digest day' }
    $catalogue['setting.UsageDigestEnabled.label'] = @{ ar = 'الملخص الأسبوعي'; en = 'Weekly digest' }
    $catalogue['setting.MaterialEndAlertMinutes.label'] = @{ ar = 'تنبيه نهاية المادة'; en = 'Material ending alert' }
    $catalogue['setting.EnableEngineHealth.label'] = @{ ar = 'صحة المحرك'; en = 'Engine health' }

    # --- Every setting description, resolved through TF at read time ----
    # Same contract as the labels: the Arabic here is the Arabic the
    # bridge ships in $script:SettingDisplayMetadata, and a test holds
    # the two identical so a reworded description cannot pass silently.
    $catalogue['setting.noDescription'] = @{ ar = 'قيمة الإعداد'; en = 'The setting value' }
    $catalogue['setting.SceneMode.description'] = @{ ar = 'Single للتوافق الحالي؛ Multi يسمح بعدة قوالب على الطبقة مع قالب نشط واحد في اللحظة نفسها'; en = 'Single for current compatibility; Multi allows several templates on one layer with one active at a time' }
    $catalogue['setting.AirCommandTimeoutSeconds.description'] = @{ ar = 'مهلة انتظار أمر Cinegy'; en = 'How long to wait for a Cinegy command' }
    $catalogue['setting.TelegramRequestTimeoutSeconds.description'] = @{ ar = 'مهلة إرسال رسائل وملفات Telegram'; en = 'Timeout for sending Telegram messages and files' }
    $catalogue['setting.MaxFieldLength.description'] = @{ ar = 'الحد الأقصى لطول نص الحقل'; en = 'Maximum length of a field value' }
    $catalogue['setting.ButtonTextMaxLength.description'] = @{ ar = 'الحد البصري لنص أزرار Telegram (0 للتعطيل)'; en = 'Visible length limit for Telegram button text (0 disables it)' }
    $catalogue['setting.EnableButtonStyles.description'] = @{ ar = 'تلوين الأزرار: أحمر للحذف · أخضر للنشر · أزرق للأساسي (تتجاهله التطبيقات القديمة)'; en = 'Colour the buttons: red for delete, green for publish, blue for primary (older clients ignore it)' }
    $catalogue['setting.PostShowDelayMs.description'] = @{ ar = 'تأخير إعادة إرسال النص بعد العرض'; en = 'Delay before re-sending the text after a show' }
    $catalogue['setting.PendingStateTimeoutMinutes.description'] = @{ ar = 'مدة صلاحية عملية الإدخال غير المكتملة'; en = 'How long an unfinished input stays valid' }
    $catalogue['setting.SnapshotCooldownSeconds.description'] = @{ ar = 'الفاصل قبل التقاط صورة بث جديدة'; en = 'Gap before another output snapshot may be taken' }
    $catalogue['setting.SnapshotTimeoutSeconds.description'] = @{ ar = 'مهلة التقاط صورة البث'; en = 'Timeout for grabbing an output frame' }
    $catalogue['setting.SnapshotRetentionMinutes.description'] = @{ ar = 'مدة الاحتفاظ بصور البث المؤقتة'; en = 'How long temporary output stills are kept' }
    $catalogue['setting.UploadRetentionMinutes.description'] = @{ ar = 'مدة الاحتفاظ بالملفات التي يرفعها المستخدمون (0 للاحتفاظ الدائم)'; en = 'How long files uploaded by users are kept (0 keeps them for ever)' }
    $catalogue['setting.AskRequesterName.description'] = @{ ar = 'يسأل طالب الوصول عن اسمه للعرض، ويصير اسمه في السجل عند الموافقة دون أن يكتبه المشرف'; en = 'Asks a requester for a display name, which becomes their name in the log on approval without an administrator typing it' }
    $catalogue['setting.ConfirmLayerRemoval.description'] = @{ ar = 'طلب تأكيد قبل الإخفاء والخروج مع عرض اسم القالب'; en = 'Ask for confirmation before hide and exit, showing the template name' }
    $catalogue['setting.ShowOnAirTextOnRemoval.description'] = @{ ar = 'يعرض نص القالب المعروض عند تأكيد إخفائه أو الخروج منه، فيرى المستخدم ما سيسحبه قبل أن يسحبه. الحقول الحسّاسة تُذكر بأسمائها دون قيمها'; en = 'Shows the live template text when confirming a hide or exit, so the operator sees what they are about to pull. Sensitive fields are named without their values' }
    $catalogue['setting.ShowLayerLockBadge.description'] = @{ ar = 'إظهار 🔒 على القوالب التي يجهّز طبقتها مشغّل آخر'; en = 'Show a lock on templates whose layer another operator is preparing' }
    $catalogue['setting.NewsListLayout.description'] = @{ ar = 'شكل قائمة الأخبار: text نص فوق الأزرار · stacked الخبر بزر مستقل · inline الخبر داخل الصف · compact أرقام فقط (حتى 40 خبرًا في شاشة)'; en = 'News list layout: text above the buttons, stacked one headline per button, inline within the row, or compact numbers only (up to 40 on a screen)' }
    $catalogue['setting.NewsDraftTimeoutMinutes.description'] = @{ ar = 'مهلة مسودة الأخبار قبل انتهاء صلاحيتها (0 = بلا مهلة)'; en = 'How long a news draft stays valid (0 = no timeout)' }
    $catalogue['setting.NewNewsItemAtTop.description'] = @{ ar = 'الخبر الجديد يُضاف في أول الشريط (عند الإطفاء: في آخره)'; en = 'A new headline goes at the top of the strip (off: at the bottom)' }
    $catalogue['setting.NewsListPaged.description'] = @{ ar = 'قائمة الأخبار على صفحات (عند الإطفاء: قائمة واحدة طويلة)'; en = 'Page the news list (off: one long list)' }
    $catalogue['setting.NewsListPageSize.description'] = @{ ar = 'عدد الأخبار في صفحة قائمة الترتيب'; en = 'Headlines on one page of the ordering list' }
    $catalogue['setting.NewsListLabelLength.description'] = @{ ar = 'طول نص الخبر في قائمة الترتيب'; en = 'Headline length in the ordering list' }
    $catalogue['setting.NewsListStackedLabelLength.description'] = @{ ar = 'طول نص الخبر حين يشغل السطر وحده'; en = 'Headline length when it has a line to itself' }
    $catalogue['setting.RepeatWarningCount.description'] = @{ ar = 'التنبيه عند تكرار القالب هذا العدد خلال النافذة (0 للتعطيل)'; en = 'Warn when a template repeats this many times inside the window (0 disables it)' }
    $catalogue['setting.RepeatWarningWindowMinutes.description'] = @{ ar = 'نافذة قياس تكرار القالب'; en = 'Window over which template repeats are counted' }
    $catalogue['setting.MissedEventsHours.description'] = @{ ar = 'المدة التي يغطيها ملخص «ماذا فاتني»'; en = 'The period the what-did-I-miss digest covers' }
    $catalogue['setting.QuietHoursEnabled.description'] = @{ ar = 'تجميع التنبيهات غير العاجلة ليلًا وإرسالها صباحًا'; en = 'Hold non-urgent alerts overnight and send them in the morning' }
    $catalogue['setting.QuietHoursStart.description'] = @{ ar = 'بداية فترة الهدوء'; en = 'When quiet hours begin' }
    $catalogue['setting.QuietHoursEnd.description'] = @{ ar = 'نهاية فترة الهدوء ووقت إرسال المؤجّل'; en = 'When quiet hours end, and when held alerts are sent' }
    $catalogue['setting.MaintenanceWindowStart.description'] = @{ ar = 'بداية نافذة الصيانة التلقائية (فارغ للتعطيل)'; en = 'Start of the automatic maintenance window (empty disables it)' }
    $catalogue['setting.MaintenanceWindowEnd.description'] = @{ ar = 'نهاية نافذة الصيانة التلقائية'; en = 'End of the automatic maintenance window' }
    $catalogue['setting.OneHandMode.description'] = @{ ar = 'زر واحد بعرض الشاشة في كل صف (استخدام بيد واحدة)'; en = 'One full-width button per row, for one-handed use' }
    $catalogue['setting.EnableTextShortcuts.description'] = @{ ar = 'كتابة اسم القالب مباشرة لبدء عرضه'; en = 'Type a template name to start showing it' }
    $catalogue['setting.OutputMonitorMinutes.description'] = @{ ar = 'الفاصل بين فحوص صورة المخرج (0 للتعطيل)'; en = 'Interval between output frame checks (0 disables it)' }
    $catalogue['setting.EnableTextChecks.description'] = @{ ar = 'تنبيهات إملائية إرشادية في شاشة المراجعة قبل النشر — لا تمنع النشر أبدًا'; en = 'Advisory spelling warnings on the review screen before publishing - they never block a publish' }
    $catalogue['setting.EnableMaterialSchedule.description'] = @{ ar = 'زر جدول المواد في القائمة: ما يبثّه الجهاز اليوم بمواعيده'; en = 'The material schedule button: what the channel plays today and when' }
    $catalogue['setting.EnableShiftHandover.description'] = @{ ar = 'زر التسليم: شاشة واحدة تجمع ما يحتاجه تبديل المناوبة'; en = 'The handover button: one screen with everything a shift change needs' }
    $catalogue['setting.NotifyAdminsOnMissingProxy.description'] = @{ ar = 'تنبيه المشرفين إن قاربت مادة موعدها ولا نسخة محلية لها على السيرفر — عندها تُقرأ من المصدر أثناء البثّ'; en = 'Warn administrators when material is due and has no local copy on the server, so it will be read from the source while on air' }
    $catalogue['setting.RepeatAlertWindowHours.description'] = @{ ar = 'خلال كم ساعة يُحسب تكرار التنبيه: من الثالث فصاعدًا يقول التنبيه إنه تكرار ومتى بدأ (0 للتعطيل)'; en = 'The window over which a repeated alert is counted: from the third on, the alert says it is a repeat and when it started (0 disables it)' }
    $catalogue['setting.AlertMaxPerCausePerHour.description'] = @{ ar = 'أقصى عدد تنبيهات من السبب الواحد في الساعة؛ ما بعده يُكتم ويُلخَّص في رسالة واحدة (0 لرفع السقف)'; en = 'Alerts per cause per hour; beyond it they are muted and summarised in one message (0 removes the ceiling)' }
    $catalogue['setting.MaterialProxyLeadMinutes.description'] = @{ ar = 'قبل كم دقيقة من موعد المادة تُفحص نسختها المحلية'; en = 'How long before material is due its local copy is checked' }
    $catalogue['setting.MaterialEndAlertMinutes.description'] = @{ ar = 'التنبيه قبل نهاية المادة الجارية بهذه الدقائق لتجهيز غرافيك الختام (0 للتعطيل)'; en = 'Warn this many minutes before the current material ends, to prepare the closing graphic (0 disables it)' }
    $catalogue['setting.EnableEngineHealth.description'] = @{ ar = 'شاشة صحة المحرك من عدادات Cinegy (إطارات مسقطة وترخيص) — معطلة افتراضيًا ويفعّلها المشرف'; en = 'Engine health from Cinegy counters (dropped frames and licence) - off by default, enabled by an administrator' }
    $catalogue['setting.OutputMonitorFailureAlertThreshold.description'] = @{ ar = 'عدد فشل التقاط المخرج المتتالي قبل تنبيه المشرف (من دون احتياط)'; en = 'Consecutive capture failures before an administrator is warned (with no fallback)' }
    $catalogue['setting.OutputMonitorFlapAlertCount.description'] = @{ ar = 'عدد مرات فشل الالتقاط خلال ست ساعات قبل الإبلاغ عن مصدر متذبذب (0 للتعطيل)'; en = 'Capture failures within six hours before reporting a flapping source (0 disables it)' }
    $catalogue['setting.OutputBlackLuminance.description'] = @{ ar = 'حد السطوع الذي يُعتبر تحته المخرج أسود'; en = 'The luminance below which the output counts as black' }
    $catalogue['setting.OutputBlackConfirmSeconds.description'] = @{ ar = 'الانتظار قبل اللقطة المؤكِّدة الثانية'; en = 'Wait before the second, confirming grab' }
    $catalogue['setting.NotifyOperatorsOnBlackOutput.description'] = @{ ar = 'إشعار المشغّلين أيضًا عند تأكيد الشاشة السوداء'; en = 'Tell operators too when a black screen is confirmed' }
    $catalogue['setting.NotifyOnScheduleOverwrite.description'] = @{ ar = 'تنبيه عندما يستبدل حدث مجدول مشهدًا موجودًا على الهواء'; en = 'Warn when a scheduled event replaces a scene already on air' }
    $catalogue['setting.AllowRemoteRestart.description'] = @{ ar = 'السماح للمشرف بإعادة تشغيل الجسر من البوت'; en = 'Let an administrator restart the bridge from the bot' }
    $catalogue['setting.UsageDigestEnabled.description'] = @{ ar = 'إرسال ملخص استخدام أسبوعي للمشرفين'; en = 'Send administrators a weekly usage digest' }
    $catalogue['setting.UsageDigestDayOfWeek.description'] = @{ ar = 'يوم إرسال الملخص (0 الأحد .. 6 السبت)'; en = 'The day the digest is sent (0 Sunday .. 6 Saturday)' }
    $catalogue['setting.AutoHideDefaultSeconds.description'] = @{ ar = 'مدة الإخفاء التلقائي الافتراضية'; en = 'Default auto-hide time' }
    $catalogue['setting.RelayMaxRestarts.description'] = @{ ar = 'الحد الأقصى لمحاولات إعادة تشغيل البث'; en = 'Maximum relay restart attempts' }
    $catalogue['setting.RelayWatchdogSeconds.description'] = @{ ar = 'الفاصل بين فحوص البث المباشر'; en = 'Interval between live relay checks' }
    $catalogue['setting.CinegyStateCheckSeconds.description'] = @{ ar = 'الفاصل بين فحوص تغير طبقات Cinegy'; en = 'Interval between checks for Cinegy layer changes' }
    $catalogue['setting.DiscoverExternalLayers.description'] = @{ ar = 'تبنّي الطبقات التي شُغّلت من خارج الجسر أثناء الفحص الدوري، فتظهر في القائمة ويمكن إخفاؤها. أطفئه ليقتصر الفحص على ما أرسله الجسر بنفسه'; en = 'Adopt layers started outside the bridge during the periodic check, so they appear in the menu and can be hidden. Turn it off to limit the check to what the bridge sent itself' }
    $catalogue['setting.TelegramPollMarginSeconds.description'] = @{ ar = 'المهلة الإضافية فوق زمن الاستطلاع الطويل قبل قطع الطلب. ارفعها إن كثرت انقطاعات Telegram'; en = 'Extra timeout above the long-poll time before the request is cut. Raise it if Telegram drops often' }
    $catalogue['setting.TelegramPollTimeoutTolerance.description'] = @{ ar = 'عدد مرات تأخر الاستطلاع المتتالية المحتملة قبل اعتبار الاتصال مفقودًا (0 = اعتبار أول تأخر انقطاعًا)'; en = 'Consecutive poll delays tolerated before the connection counts as lost (0 = the first delay counts)' }
    $catalogue['setting.CinegyHealthCheckSeconds.description'] = @{ ar = 'الفاصل بين فحوص صحة Cinegy'; en = 'Interval between Cinegy health checks' }
    $catalogue['setting.CinegyMonitorTimeoutSeconds.description'] = @{ ar = 'مهلة فحص حالة Cinegy'; en = 'Timeout for a Cinegy state check' }
    $catalogue['setting.CinegyFrameLossTolerance.description'] = @{ ar = 'الإطارات المفقودة المسموح بها في الدقيقة قبل اعتبار القناة غير سليمة'; en = 'Dropped frames per minute allowed before the channel counts as unhealthy' }
    $catalogue['setting.CinegyFrameLossTolerancePercent.description'] = @{ ar = 'نسبة الإطارات المفقودة المسموح بها من إجمالي الخرج'; en = 'Percentage of dropped frames allowed out of total output' }
    $catalogue['setting.CinegyHealthConfirmChecks.description'] = @{ ar = 'عدد الفحوص المتتالية المتّفقة قبل تغيير حالة صحة Cinegy'; en = 'Consecutive agreeing checks before the Cinegy health state changes' }
    $catalogue['setting.CinegyReadErrorRateTolerance.description'] = @{ ar = 'نسبة أخطاء القراءة المسموح بها قبل اعتبار القناة غير سليمة'; en = 'Read error rate allowed before the channel counts as unhealthy' }
    $catalogue['setting.RespectCinegyItemDuration.description'] = @{ ar = 'عدم تنبيه القِدَم لقالب حدّد Cinegy مدّته ولم تنتهِ بعد'; en = 'Do not raise a staleness alert for a template whose Cinegy duration has not run out' }
    $catalogue['setting.TemplateBasePath.description'] = @{ ar = 'مجلد المشاهد: يسمح بكتابة اسم الملف وحده في القوالب'; en = 'Scenes folder: lets a template carry only a file name' }
    $catalogue['setting.CinegyStateBackoffMaxSeconds.description'] = @{ ar = 'أقصى تباعد لفحص طبقات Cinegy عند تعذّر الوصول'; en = 'Maximum spacing of Cinegy layer checks when it is unreachable' }
    $catalogue['setting.StaleOnAirAlertHours.description'] = @{ ar = 'تنبيه المشرفين عن سجل على الهواء منذ هذه المدة (0 للتعطيل)'; en = 'Warn administrators about a record on air this long (0 disables it)' }
    $catalogue['setting.StartupStormThreshold.description'] = @{ ar = 'عدد إقلاعات الجسر خلال 24 ساعة قبل تنبيه واحد (0 للتعطيل)'; en = 'Bridge starts within 24 hours before one warning is sent (0 disables it)' }
    $catalogue['setting.SensitiveTemplateAutoHideSeconds.description'] = @{ ar = 'الحد الأقصى لبقاء القالب الحساس على الهواء'; en = 'The longest a sensitive template may stay on air' }
    $catalogue['setting.TemplateMaxAirSeconds.description'] = @{ ar = 'حد مستقل لكل قالب يبدأ من العرض التالي؛ يُعدّل بأزرار القوالب فقط'; en = 'A separate per-template limit, effective from the next show; set from the template buttons only' }
    $catalogue['setting.TemplateAirExtensionEnabled.description'] = @{ ar = 'السماح بتمديد واحد عند بلوغ حد القالب؛ لا يشمل القوالب الحساسة'; en = 'Allow one extension when a template reaches its limit; never for sensitive templates' }
    $catalogue['setting.TemplateAirExtensionResponseSeconds.description'] = @{ ar = 'مهلة الرد على طلب التمديد؛ عند انتهائها دون تأكيد يُخفى القالب'; en = 'How long to answer an extension request; with no answer the template is hidden' }
    $catalogue['setting.TemplateAirExtensionMaxSeconds.description'] = @{ ar = 'أقصى مدة للتمديد الواحد؛ المدة المخصصة بالأزرار فقط'; en = 'Maximum length of one extension; the allotted time is set from the buttons only' }
    $catalogue['setting.TemplateTestLayer.description'] = @{ ar = 'طبقة تجربة القوالب المستقلة (0 للتعطيل)'; en = 'The separate template test layer (0 disables it)' }
    $catalogue['setting.TemplateTestAutoHideSeconds.description'] = @{ ar = 'مدة إخفاء اختبار القالب تلقائيًا'; en = 'How long before a template test hides itself' }
    $catalogue['setting.TemplateRegistryImportMaxTemplates.description'] = @{ ar = 'الحد الأقصى لعدد القوالب في ملف استيراد سجل القوالب'; en = 'Maximum templates in a registry import file' }
    $catalogue['setting.EnableSafeRollback.description'] = @{ ar = 'تفعيل التراجع الآمن قصير العمر (معطل افتراضيًا)'; en = 'Enable short-lived safe rollback (off by default)' }
    $catalogue['setting.RollbackWindowSeconds.description'] = @{ ar = 'مدة صلاحية التراجع الآمن داخل الذاكرة'; en = 'How long an in-memory safe rollback stays valid' }
    $catalogue['setting.HealthFailureAlertThreshold.description'] = @{ ar = 'عدد حالات الفشل المتتالية قبل تنبيه المشرف'; en = 'Consecutive failures before an administrator is warned' }
    $catalogue['setting.UserActivityRecentMinutes.description'] = @{ ar = 'مدة اعتبار المستخدم نشطًا حديثًا حسب آخر تفاعل مع البوت'; en = 'How long a user counts as recently active after their last interaction' }
    $catalogue['setting.TemplateReminderFollowUpMinutes.description'] = @{ ar = 'مهلة تنبيه المتابعة عند عدم تأكيد معالجة تنبيه القالب (0 للتعطيل)'; en = 'Follow-up delay when a template reminder is not acknowledged (0 disables it)' }
    $catalogue['setting.SchedulePreNotifyMinutes.description'] = @{ ar = 'مدة الإشعار المسبق للحدث المجدول (0 للتعطيل)'; en = 'Advance notice for a scheduled event (0 disables it)' }
    $catalogue['setting.MaxPendingApprovals.description'] = @{ ar = 'الحد الأقصى لطلبات الوصول المعلّقة'; en = 'Maximum pending access requests' }
    $catalogue['setting.PendingApprovalExpiryHours.description'] = @{ ar = 'مدة صلاحية طلب الوصول'; en = 'How long an access request stays valid' }
    $catalogue['setting.FavoritesCount.description'] = @{ ar = 'عدد القوالب المفضلة المعروضة'; en = 'How many favourite templates are shown' }
    $catalogue['setting.NewsLockGrantHoldSeconds.description'] = @{ ar = 'مدة حجز قفل الأخبار لمن طلبه بعد التسليم (0 للتعطيل)'; en = 'How long the news lock is held for whoever asked, after a handover (0 disables it)' }
    $catalogue['setting.RecentValuesPerField.description'] = @{ ar = 'عدد القيم الحديثة لكل حقل'; en = 'Recent values kept per field' }
    $catalogue['setting.LogMaxSizeMB.description'] = @{ ar = 'الحجم الأقصى لملف السجل'; en = 'Maximum log file size' }
    $catalogue['setting.LogKeepFiles.description'] = @{ ar = 'عدد ملفات السجل المحتفَظ بها'; en = 'How many log files are kept' }
    $catalogue['setting.AuditMaxSizeMB.description'] = @{ ar = 'حجم سجل التدقيق قبل أرشفته في ملف جديد (0 = بلا أرشفة)'; en = 'Audit log size before it is archived into a new file (0 = never archive)' }
    $catalogue['setting.ExecutionLogKeepRecords.description'] = @{ ar = 'عدد سجلات تنفيذ الجدولة المحتفَظ بها (0 = بلا تقليم)'; en = 'Schedule execution records kept (0 = never trim)' }
    $catalogue['setting.ScheduleHistoryKeepDays.description'] = @{ ar = 'مدة الاحتفاظ بالمواعيد المنتهية في ملف الجدولة (0 = الاحتفاظ بالكل)'; en = 'How long finished events are kept in the schedule file (0 = keep all)' }
    $catalogue['setting.AccessGuardKeepDays.description'] = @{ ar = 'مدة تذكّر محادثة محظورة قبل نسيانها (0 = بلا نسيان)'; en = 'How long a blocked chat is remembered before it is forgotten (0 = never forget)' }
    $catalogue['setting.AuditArchiveKeepFiles.description'] = @{ ar = 'عدد أرشيفات التدقيق المحتفَظ بها (0 = الاحتفاظ بالكل)'; en = 'How many audit archives are kept (0 = keep all)' }
    $catalogue['setting.AuditTrailSize.description'] = @{ ar = 'عدد عناصر سجل العمليات المحتفَظ بها'; en = 'How many entries the operation log keeps' }
    $catalogue['setting.AuditTemplateValues.description'] = @{ ar = 'تسجيل نص القالب الذي ظهر على الهواء لعرضه في التقارير'; en = 'Record the template text that went on air, for the reports' }
    $catalogue['setting.AuditTemplateValuesMaxChars.description'] = @{ ar = 'أقصى طول لنص القالب المسجَّل في كل عملية'; en = 'Maximum recorded template text per operation' }
    $catalogue['setting.ConfigBackupKeepFiles.description'] = @{ ar = 'عدد نسخ الإعدادات المحتفَظ بها'; en = 'How many settings backups are kept' }
    $catalogue['setting.DiskFreeWarningGB.description'] = @{ ar = 'حد تنبيه انخفاض مساحة القرص'; en = 'Free disk space warning threshold' }
    $catalogue['setting.RuntimeStorageWarningMB.description'] = @{ ar = 'حد تنبيه حجم ملفات التشغيل والسجلات'; en = 'Warning threshold for runtime files and logs' }
    $catalogue['setting.BackupStorageWarningMB.description'] = @{ ar = 'حد تنبيه حجم النسخ الاحتياطية'; en = 'Warning threshold for backup size' }
    $catalogue['setting.HeartbeatHour.description'] = @{ ar = 'ساعة إرسال نبض التشغيل اليومي'; en = 'The hour the daily heartbeat is sent' }
    $catalogue['setting.MojazAnchorToAirClock.description'] = @{ ar = 'ضبط زمن الموجز على لحظة البدء التي يقولها Cinegy بدل ساعة الجسر، فتصيب المزامنة الفيضة بدقة أعلى'; en = 'Take the bulletin''s timing from the start moment Cinegy reports rather than the bridge clock, so the sync hits the reveal more precisely' }
    $catalogue['setting.MojazMultiDesign.description'] = @{ ar = 'يسمح بربط كل موجز بتصميم مختلف وقراءة حقوله من المشهد. مطفأ = التصميم الواحد الحالي بحقوله الثلاثة'; en = 'Lets each bulletin use a different design and read its fields from the scene. Off = the current single design with its three fields' }
    $catalogue['setting.MojazImageKeepHours.description'] = @{ ar = 'مدة الاحتفاظ بصورة موجز لم يعد يشير إليها أي صف قبل حذفها تلقائيًا (0 = لا حذف)'; en = 'How long a bulletin image no row refers to is kept before it is deleted (0 = never delete)' }
    $catalogue['setting.MojazRowFrames.description'] = @{ ar = 'المدة الافتراضية لبقاء صف الموجز قبل الصف التالي، بالإطارات. تُستخدم لكل موجز جديد ولكل موجز لم يُحدَّد له رقم'; en = 'Default time a bulletin row holds before the next, in frames. Used for every new bulletin and every one with no number set' }
    $catalogue['setting.BroadcastFps.description'] = @{ ar = 'معدل إطارات القناة، يُستخدم في حساب المدد حين لا يذكر المشهد معدله. المشهد أولى بنفسه حين يذكره'; en = 'The channel frame rate, used for durations when a scene does not state its own. The scene wins when it does' }
    $catalogue['setting.MojazIntroExtraFrames.description'] = @{ ar = 'إطارات تُضاف إلى الصف الأول وحده بقدر حركة الدخول. صفر يعني أخذها من المشهد نفسه'; en = 'Frames added to the first row alone for the entrance animation. Zero takes it from the scene' }
    $catalogue['setting.MojazLastRowFrames.description'] = @{ ar = 'إطارات يبقاها الصف الأخير قبل أمر الخروج. صفر يعني أخذها من حركة خروج المشهد'; en = 'Frames the last row holds before the exit command. Zero takes it from the scene outro' }
    $catalogue['setting.MojazSyncOffsetMs.description'] = @{ ar = 'بعد التفاف اللوب بكم يُكتب الصف التالي، ليقع داخل حركة الظهور فتُخفيه'; en = 'How long after the loop wraps the next row is written, so it lands inside the reveal and is hidden by it' }
    $catalogue['setting.MojazSyncLeadMs.description'] = @{ ar = 'يُرسل الأمر مبكرًا بهذا القدر ليعوّض زمن الشبكة، فيصل في لحظته'; en = 'Send the command this early to offset network latency, so it arrives on the moment' }
    $catalogue['setting.MojazNotifyOnFinish.description'] = @{ ar = 'إشعار في المحادثة حين ينتهي الموجز وحده ويخرج عن الهواء. الطرق الأخرى لإنهائه تقول ذلك أصلًا'; en = 'A message when the bulletin ends by itself and leaves the air. The other ways of ending it already say so' }
    $catalogue['setting.MojazScheduleNoticeSeconds.description'] = @{ ar = 'ينبّه قبل بدء موجز مجدول بهذه المدة. صفر يوقف التنبيه'; en = 'Warn this long before a scheduled bulletin starts. Zero turns the warning off' }
    $catalogue['setting.MojazHidesTicker.description'] = @{ ar = 'شريط الأخبار يخرج عند بدء الموجز ويعود بعد انتهائه، لأنهما يتقاسمان أسفل الشاشة. لا يُعاد شريط لم يكن على الهواء أصلًا'; en = 'The news ticker leaves when the bulletin starts and returns when it ends, because they share the bottom of the screen. A ticker that was not on air is not brought back' }
    $catalogue['setting.EnableUrgentBoard.description'] = @{ ar = 'يفعّل 🚨 إدارة العواجل: جدول عواجل يُعرض بالتتابع. زرّ العاجل الثابت يبقى كما هو سواء فُعّل أو لا'; en = 'Enables the urgent board: a table of urgent items played in sequence. The single urgent button is unaffected either way' }
    $catalogue['setting.UrgentBoardIntervalSeconds.description'] = @{ ar = 'كم يبقى كل عاجل قبل الذي يليه، ما لم يحدّد العاجل نفسه فاصلًا'; en = 'How long each urgent item holds before the next, unless the item sets its own' }
    $catalogue['setting.UrgentBoardRepeats.description'] = @{ ar = 'كم مرة يُعاد تشغيل الجدول. معنى «المرة» يحدّده ترتيب التكرار'; en = 'How many times the board is replayed. What "a time" means is set by the repeat order' }
    $catalogue['setting.UrgentBoardMode.description'] = @{ ar = 'نمط العرض الافتراضي: text يحدّث النصّ، exit يُخرج المشهد قبل هذا العاجل، auto_hide يُخرجه عند انتهاء مدة هذا العاجل'; en = 'Default display mode: text updates the text, exit takes the scene out before this item, auto_hide takes it out when this item ends' }
    $catalogue['setting.UrgentBoardRepeatMode.description'] = @{ ar = 'ترتيب التكرار: cycle يعيد الجدول كاملًا (١ ٢ ٣ · ١ ٢ ٣)، وitem يكرّر كل عاجل ثم ينتقل (١ ١ · ٢ ٢)'; en = 'Repeat order: cycle replays the whole board (1 2 3 . 1 2 3), item repeats each one then moves on (1 1 . 2 2)' }
    $catalogue['setting.UrgentBoardTotalSeconds.description'] = @{ ar = 'سقف زمني للتشغيل كلّه، يقصّ التكرارات إن لزم. صفر يعني بلا سقف'; en = 'A ceiling on the whole run, trimming repeats if needed. Zero means no ceiling' }
    $catalogue['setting.UrgentBoardMaxItems.description'] = @{ ar = 'أقصى عدد عواجل في الجدول. الحدّ الأعلى هو حدّ صفوف الجداول الثرية'; en = 'Maximum urgent items on the board. The upper bound is the rich table row limit' }
    $catalogue['setting.UrgentMinIntervalSeconds.description'] = @{ ar = 'أقصر فاصل مسموح حين يتعذّر قراءة توقيت المشهد. حين يُقرأ المشهد فأرضيته هي حركتا الدخول والخروج'; en = 'Shortest interval allowed when the scene timing cannot be read. When it can, the floor is the entrance and exit animations' }
    $catalogue['setting.UrgentExitGapSeconds.description'] = @{ ar = 'فاصل شاشة فارغة بين خبر وآخر في وضع حركة الخروج (0 = حركة المشهد وحدها). يرفع أقصر فاصل مسموح بالقدر نفسه'; en = 'A blank gap between stories in exit mode (0 = the scene motion alone). It raises the shortest allowed interval by the same amount' }
    $catalogue['setting.Language.description'] = @{ ar = 'لغة كل شاشات البوت وأزراره ورسائله. التغيير يسري فورًا على الجميع'; en = 'The language of every bot screen, button and message. Applies to everyone immediately' }
    $catalogue['setting.EnableContentBoards.description'] = @{ ar = 'جداول محتوى البرامج: يجهّز المعدّ نصوص البرنامج مسبقًا ويعرضها المنفّذ صفًّا صفًّا'; en = 'Programme content boards: a producer prepares the texts in advance and the operator shows them row by row' }
    $catalogue['setting.MaxContentBoards.description'] = @{ ar = 'أقصى عدد جداول محتوى في وقت واحد'; en = 'Maximum content boards at one time' }
    $catalogue['setting.BoardMaxItems.description'] = @{ ar = 'أقصى عدد صفوف في الجدول الواحد'; en = 'Maximum rows in one board' }
    $catalogue['setting.UrgentSyncLeadMs.description'] = @{ ar = 'يُرسل الأمر مبكرًا بهذا القدر ليعوّض زمن الشبكة، فيصل في لحظته'; en = 'Send the command this early to offset network latency, so it arrives on the moment' }
    $catalogue['setting.UrgentBoardNotifyOnFinish.description'] = @{ ar = 'إشعار في المحادثة حين ينتهي تشغيل جدول العواجل وحده'; en = 'A message when the urgent board run ends by itself' }
    $catalogue['setting.UrgentBoardMaxTextLength.description'] = @{ ar = 'أطول نصّ عاجل يقبله الجدول'; en = 'The longest urgent text the board accepts' }
    $catalogue['setting.MojazImageWidth.description'] = @{ ar = 'عرض صورة صف الموجز كما يُصدِّرها Titler فعلًا. صفر يعني قراءة المقاس من لوحة القالب'; en = 'The width Titler actually exports a bulletin row image at. Zero reads the size from the template' }
    $catalogue['setting.MojazImageHeight.description'] = @{ ar = 'ارتفاع صورة صف الموجز كما يُصدِّرها Titler فعلًا. صفر يعني قراءة المقاس من لوحة القالب'; en = 'The height Titler actually exports a bulletin row image at. Zero reads the size from the template' }
    $catalogue['setting.RequireUserLevelAuth.description'] = @{ ar = 'يتحقق من هوية المستخدم لا من المحادثة وحدها؛ في المجموعات لا تكفي عضوية المحادثة للتحكم بالهواء'; en = 'Verifies the user, not the chat alone; in a group, chat membership is not enough to control the air' }
    $catalogue['setting.EnableSelfServiceRequests.description'] = @{ ar = 'يسمح لغير المصرّح له بإرسال طلب وصول من البوت، يصلك في 👤 طلبات الوصول'; en = 'Lets an unauthorised person send an access request from the bot, which reaches you in Access requests' }
    $catalogue['setting.EnableAnnouncements.description'] = @{ ar = 'يسمح للمشرفين بإرسال تنويه إلى مستخدمي البوت من 📢 التنويهات'; en = 'Lets administrators send an announcement to the bot users' }
    $catalogue['setting.AnnouncementMaxLength.description'] = @{ ar = 'أقصى طول لنص التنويه'; en = 'Maximum announcement length' }
    $catalogue['setting.AnnouncementDefaultExpiryHours.description'] = @{ ar = 'المدة الافتراضية لبقاء التنويه نشطًا قبل أن ينتهي وحده'; en = 'How long an announcement stays active by default before it expires' }
    $catalogue['setting.NotifyAdminsOnAccessRequest.description'] = @{ ar = 'إشعار المشرفين بكل طلب وصول جديد. أطفئه لتقرأ الطلبات من 👤 طلبات الوصول وحدها'; en = 'Tell administrators about every new access request. Turn it off to read them from the Access requests screen alone' }
    $catalogue['setting.NotifyAdminsOnMissingGraphic.description'] = @{ ar = 'تنبيه المشرفين حين لا يكون قالب دائم (اللوغو، الشريط) على الهواء. يُسأل Cinegy مباشرة، فيُكشف الغياب سواء أُخفي من البوت أو من خارجه'; en = 'Warn administrators when a permanent template (the logo, the ticker) is not on air. Cinegy is asked directly, so the absence is caught whether it was hidden from the bot or from outside it' }
    $catalogue['setting.MissingGraphicConfirmChecks.description'] = @{ ar = 'عدد الفحوص المتتالية قبل الإبلاغ عن غياب قالب دائم، حتى لا يُنبَّه أثناء استبدال يستغرق ثوانٍ'; en = 'Consecutive checks before reporting a permanent template missing, so a swap taking seconds raises nothing' }
    $catalogue['setting.NotifyAdminsOnBlockedChat.description'] = @{ ar = 'إشعار المشرفين حين يحظر الحارس محادثة تلقائيًا. والحظر يبقى صامتًا تجاه المحظور دائمًا'; en = 'Tell administrators when the guard blocks a chat automatically. The block is always silent towards the blocked party' }
    $catalogue['setting.BlockRejectedRequesters.description'] = @{ ar = 'رفض الطلب يحظر المحادثة نهائيًا فلا تستطيع الطلب مجددًا. ارفع الحظر من 🚫 المحظورون'; en = 'Rejecting a request blocks the chat for good so it cannot ask again. Lift it from the blocked list' }
    $catalogue['setting.JoinSecret.description'] = @{ ar = 'رمز يُطلب من الغريب قبل أن يصل طلبه إلى المشرفين. اتركه فارغًا لتعطيل الرمز، وأرسل - لمسحه'; en = 'A code a stranger must give before their request reaches administrators. Leave it empty to disable it, and send - to clear it' }
    $catalogue['setting.JoinSecretMaxAttempts.description'] = @{ ar = 'عدد المحاولات الخاطئة لرمز الانضمام في اليوم قبل حظر المحادثة (0 للتعطيل)'; en = 'Wrong join-code attempts per day before the chat is blocked (0 disables it)' }
    $catalogue['setting.MaxAccessRequestsPerDay.description'] = @{ ar = 'عدد طلبات الوصول المسموح بها من محادثة واحدة خلال ٢٤ ساعة (0 للتعطيل)'; en = 'Access requests allowed from one chat in 24 hours (0 disables it)' }
    $catalogue['setting.DormantUserDays.description'] = @{ ar = 'مدة الصمت التي بعدها يُبلَّغ المشرفون عن المستخدم الخامل (0 للتعطيل)'; en = 'The silence after which administrators are told a user is dormant (0 disables it)' }
    $catalogue['setting.AutoDisableDormantUsers.description'] = @{ ar = 'تعطيل المستخدم الخامل تلقائيًا بدل الاكتفاء بالتبليغ عنه'; en = 'Disable a dormant user automatically rather than only reporting them' }
    $catalogue['setting.LeaveUnknownGroups.description'] = @{ ar = 'مغادرة أي مجموعة يُضاف إليها البوت ولم تُدرج في AllowedChatIds، مع إشعار المشرفين'; en = 'Leave any group the bot is added to that is not in AllowedChatIds, and tell administrators' }
    $catalogue['setting.EnableRawCommand.description'] = @{ ar = 'يفتح 🛠 الأمر الخام للمشرف: إرسال أمر Cinegy مباشرة دون قالب'; en = 'Opens the raw command for administrators: send a Cinegy command directly, without a template' }
    $catalogue['setting.EnableFullTemplateManagement.description'] = @{ ar = 'يسمح بتعديل بنية القوالب من تيليجرام لا بعرضها فقط'; en = 'Allows editing template structure from Telegram, not only viewing it' }
    $catalogue['setting.EnableDpapiSecrets.description'] = @{ ar = 'يخزّن الأسرار مشفّرة بـ Windows DPAPI لحساب التشغيل بدل نص صريح في config.json'; en = 'Stores secrets encrypted with Windows DPAPI for the run account instead of plain text in config.json' }
    $catalogue['setting.EnableSnapshot.description'] = @{ ar = 'يفعّل 📸 صورة من البث: لقطة من خرج القناة'; en = 'Enables the output snapshot: a frame from the channel output' }
    $catalogue['setting.LiveWatchUrl.description'] = @{ ar = 'رابط صفحة المشاهدة (https) التي يفتحها زرّ 📺 داخل تيليجرام. اتركه فارغًا ليختفي الزرّ. الصفحة ملف واحد في docs/watch.html'; en = 'The https page the 📺 button opens inside Telegram. Leave it empty and the button disappears. The page is one file, docs/watch.html' }
    $catalogue['setting.EnableLiveRelay.description'] = @{ ar = 'يفعّل ▶️ البث المباشر: ترحيل خرج القناة إلى تيليجرام'; en = 'Enables the live relay: the channel output forwarded to Telegram' }
    $catalogue['setting.EnableTimedShow.description'] = @{ ar = 'يفعّل ⏱ العرض المؤقّت: عرض يُخفى تلقائيًا بعد مدة'; en = 'Enables the timed show: a graphic that hides itself after a set time' }
    $catalogue['setting.EnableHideAll.description'] = @{ ar = 'يفعّل 🚨 إخفاء الكل: زر الطوارئ الذي يخفي الطبقات المحددة'; en = 'Enables hide-all: the emergency button that clears the selected layers' }
    $catalogue['setting.HideAllLayers.description'] = @{ ar = 'ما يخفيه زر الطوارئ: all لكل الطبقات المعروفة، أو قائمة طبقات محددة'; en = 'What the emergency button hides: all for every known layer, or a list of layers' }
    $catalogue['setting.ReservedLayers.description'] = @{ ar = 'طبقات يُمنع العرض عليها؛ الإخفاء والخروج يبقيان متاحين'; en = 'Layers nothing may be shown on; hide and exit stay available' }
    $catalogue['setting.AdminOnlyTemplateKeys.description'] = @{ ar = 'قوالب لا يعرضها ولا يخفيها إلا المشرفون. فارغ يعني متاحًا للجميع'; en = 'Templates only administrators may show or hide. Empty means everyone' }
    $catalogue['setting.OwnerOnlyTemplateKeys.description'] = @{ ar = 'قوالب لا يعرضها ولا يخفيها إلا المالك. تعلو على قائمة المشرفين'; en = 'Templates only the owner may show or hide. Outranks the administrator list' }
    $catalogue['setting.AdminOnlyLayers.description'] = @{ ar = 'طبقات لا يُعرض عليها ولا يُخفى منها إلا بصلاحية مشرف، أيًّا كان القالب'; en = 'Layers nothing may be shown on or hidden from without administrator rights, whatever the template' }
    $catalogue['setting.OwnerOnlyLayers.description'] = @{ ar = 'طبقات لا يُعرض عليها ولا يُخفى منها إلا بصلاحية المالك. تعلو على طبقات المشرفين'; en = 'Layers nothing may be shown on or hidden from without owner rights. Outranks the administrator layers' }
    $catalogue['setting.LayersScreenAccess.description'] = @{ ar = 'من يرى زر «الطبقات» ويفتح شاشته: الجميع، أو المشرفون، أو المالك. شاشة الطبقات أدوات خام — إخفاء وخروج وعرض على رقم طبقة'; en = 'Who sees the Layers button and opens its screen: everyone, administrators, or the owner. That screen is raw tooling - hide, exit, and show on a bare layer number' }
    $catalogue['setting.ReshowClearsLayer.description'] = @{ ar = 'يخفي الطبقة قبل إعادة العرض عليها فيظهر النص الجديد بدل القديم'; en = 'Hides the layer before showing on it again, so the new text replaces the old' }
    $catalogue['setting.SetValuesAfterShow.description'] = @{ ar = 'يعيد إرسال قيم الحقول بعد العرض مباشرة ليضمن ظهور النص الصحيح'; en = 'Re-sends the field values straight after the show, to guarantee the right text appears' }
    $catalogue['setting.AutoHidePresetSeconds.description'] = @{ ar = 'مدد الإخفاء الجاهزة المعروضة كأزرار في ⏱ العرض المؤقّت، مفصولة بفاصلة'; en = 'The ready-made hide times offered as buttons in the timed show, comma separated' }
    $catalogue['setting.RelayAutoRestart.description'] = @{ ar = 'يعيد تشغيل الترحيل تلقائيًا إن انقطع'; en = 'Restarts the relay automatically if it drops' }
    $catalogue['setting.MaintenanceMode.description'] = @{ ar = 'يوقف كل ما يغيّر الهواء ويُبقي المتابعة والتقارير تعمل'; en = 'Stops everything that changes the air while monitoring and reports keep working' }
    $catalogue['setting.DisabledTemplateKeys.description'] = @{ ar = 'قوالب ممنوعة من العرض، بمفاتيحها مفصولة بفاصلة'; en = 'Templates barred from being shown, by key, comma separated' }
    $catalogue['setting.SensitiveTemplateKeys.description'] = @{ ar = 'قوالب تُعطى مؤقّت إخفاء تلقائيًا دائمًا فلا تبقى على الهواء منسية'; en = 'Templates always given a hide timer, so they are never left on air forgotten' }
    $catalogue['setting.LayerNames.description'] = @{ ar = 'أسماء الطبقات كما تُعرض للمشغّل، بصيغة 7=عاجل;8=شريط الأخبار'; en = 'Layer names as the operator sees them, as 7=Urgent;8=News ticker' }
    $catalogue['setting.EnableFavorites.description'] = @{ ar = 'يفعّل ⭐ المفضّلة: القوالب المختارة تظهر أعلى القائمة'; en = 'Enables favourites: chosen templates appear at the top of the menu' }
    $catalogue['setting.EnablePersistentMenuButton.description'] = @{ ar = 'يبقي شريط 🏠 القائمة و🆘 مساعدة ظاهرًا أسفل المحادثة'; en = 'Keeps the Menu and Help bar visible under the conversation' }
    $catalogue['setting.EnableNewsTickerManagement.description'] = @{ ar = 'يفعّل 📰 إدارة شريط الأخبار في القائمة'; en = 'Enables news ticker management in the menu' }
    $catalogue['setting.NewsFilePath.description'] = @{ ar = 'مسار ملف الشريط الذي يقرأه المشغّل على الهواء (.txt بمسار كامل)'; en = 'Path to the ticker file the player reads on air (.txt, full path)' }
    $catalogue['setting.NewsItemSeparator.description'] = @{ ar = 'الفاصل بين الأخبار داخل ملف الشريط'; en = 'The separator between headlines inside the ticker file' }
    $catalogue['setting.NewsMaxItemLength.description'] = @{ ar = 'أطول خبر مسموح به؛ ما يقاربه يُعلَّم بـ ⚠️ في شاشة الترتيب'; en = 'The longest headline allowed; one approaching it is flagged in the ordering screen' }
    $catalogue['setting.NewsMaxItems.description'] = @{ ar = 'أقصى عدد أخبار في الشريط'; en = 'Maximum headlines on the ticker' }
    $catalogue['setting.NewsImportMaxBytes.description'] = @{ ar = 'أكبر حجم لملف الاستيراد TXT'; en = 'Largest TXT import file' }
    $catalogue['setting.NewsBackupKeepFiles.description'] = @{ ar = 'كم نسخة من الشريط يُحتفظ بها للاستعادة'; en = 'How many ticker backups are kept for restoring' }
    $catalogue['setting.NewsLockRequestMinutes.description'] = @{ ar = 'مهلة صاحب المسودة للردّ على طلب فكّ القفل'; en = 'How long the draft''s holder has to answer an unlock request' }
    $catalogue['setting.NewsSheetCsvUrl.description'] = @{ ar = 'رابط تصدير CSV للشيت — لا رابط الشيت العادي'; en = 'The CSV export link for the sheet - not the ordinary sheet link' }
    $catalogue['setting.NewsSheetSyncMode.description'] = @{ ar = 'manual: بزر فقط · auto: كل فترة المزامنة'; en = 'manual: by button only. auto: every sync interval' }
    $catalogue['setting.NewsSheetSyncMinutes.description'] = @{ ar = 'كل كم تُسحب نسخة من الشيت في الوضع التلقائي'; en = 'How often a copy of the sheet is pulled in automatic mode' }
    $catalogue['setting.NewsSheetTimeoutSeconds.description'] = @{ ar = 'مهلة تنزيل الشيت قبل اعتباره فاشلًا'; en = 'Sheet download timeout before it counts as failed' }
    $catalogue['setting.NewsSheetNotifyScope.description'] = @{ ar = 'من يصله إشعار تغيّر الشيت: none بلا أحد · admins المشرفون · all كل المصرّح لهم'; en = 'Who is told the sheet changed: none, admins, or all authorised users' }
    $catalogue['setting.NewsPublishNotifyScope.description'] = @{ ar = 'من يصله إشعار النشر اليدوي: none بلا أحد · admins المشرفون · admins_and_publisher المشرفون والناشر · all كل المصرّح لهم'; en = 'Who is told about a manual publish: none, admins, admins and the publisher, or all authorised users' }
    $catalogue['setting.NewsSheetFailureAlertAfter.description'] = @{ ar = 'كم محاولة مزامنة فاشلة متتالية قبل التنبيه أن الشيت لا يصل (0 للصمت)'; en = 'Consecutive failed syncs before warning that the sheet is not arriving (0 stays silent)' }
    $catalogue['setting.TemplateNotifyRules.description'] = @{ ar = 'قوالب تُعلن عن نفسها عند العرض: «القالب=الجهة» مفصولة بفاصلة (الجهة: none · admins · all)'; en = 'Templates that announce themselves when shown: template=audience, comma separated (audience: none, admins, all)' }
    $catalogue['setting.AllowOperatorsSheetPull.description'] = @{ ar = 'يسمح للمشغّل بسحب الشيت، لا للمشرف وحده'; en = 'Lets an operator pull the sheet, not administrators alone' }
    $catalogue['setting.AllowOperatorsDeleteNews.description'] = @{ ar = 'يسمح للمشغّل بحذف خبر من الشريط'; en = 'Lets an operator delete a headline from the ticker' }
    $catalogue['setting.AllowOperatorsRestoreNews.description'] = @{ ar = 'يسمح للمشغّل باستعادة نسخة سابقة من الشريط'; en = 'Lets an operator restore an earlier version of the ticker' }
    $catalogue['setting.AllowOperatorsClearAllNews.description'] = @{ ar = 'يسمح للمشغّل بمسح الشريط كاملًا'; en = 'Lets an operator clear the whole ticker' }
    $catalogue['setting.ScheduleConflictWindowMinutes.description'] = @{ ar = 'ينبّه إن تقاربت أحداث على طبقة واحدة داخل هذه النافذة'; en = 'Warns when events on one layer fall this close together' }
    $catalogue['setting.SchedulePaused.description'] = @{ ar = 'يُبقي الأحداث المجدولة معلّقة دون تنفيذ'; en = 'Holds scheduled events without running them' }
    $catalogue['setting.ScheduleMaxRetries.description'] = @{ ar = 'كم مرة يُعاد عرض مجدول فشل؛ 0 يعني لا إعادة'; en = 'How many times a failed scheduled show is retried; 0 means never' }
    $catalogue['setting.ScheduleRetryDelaySeconds.description'] = @{ ar = 'الانتظار قبل إعادة محاولة عرض مجدول'; en = 'Wait before retrying a scheduled show' }
    $catalogue['setting.ScheduleRetryBackoffFactor.description'] = @{ ar = 'مضاعف التأخير بعد كل محاولة فاشلة'; en = 'Delay multiplier after each failed attempt' }
    $catalogue['setting.ScheduleRetryMaxDelaySeconds.description'] = @{ ar = 'سقف التأخير مهما تكرّر الفشل'; en = 'Delay ceiling however often it fails' }
    $catalogue['setting.CinegyStateStaleSeconds.description'] = @{ ar = 'بعدها تُعدّ آخر قراءة ناجحة لحالة Cinegy قديمة'; en = 'After this, the last successful Cinegy state read counts as stale' }
    $catalogue['setting.HeartbeatEnabled.description'] = @{ ar = 'رسالة نبض يومية تؤكد أن الجسر يعمل'; en = 'A daily heartbeat message confirming the bridge is running' }
    $catalogue['setting.NotifyAdminsOnRelayFailure.description'] = @{ ar = 'يُبلغ المشرفين حين يفشل ترحيل البث'; en = 'Tells administrators when the relay fails' }
    $catalogue['setting.NotifyAdminsOnExternalChange.description'] = @{ ar = 'يُبلغ المشرفين حين يظهر أو يختفي شيء لم يُرسله الجسر'; en = 'Tells administrators when something the bridge did not send appears or disappears' }
    $catalogue['setting.NotifyAdminsOnCinegyHealth.description'] = @{ ar = 'يُبلغ المشرفين بتغيّر صحة Cinegy: إطارات ساقطة أو انقطاع'; en = 'Tells administrators when Cinegy health changes: dropped frames or a disconnection' }
    $catalogue['setting.LogAirXml.description'] = @{ ar = 'يسجّل XML المُرسل إلى Cinegy في السجل — للتشخيص لا للتشغيل اليومي'; en = 'Logs the XML sent to Cinegy - for diagnosis, not daily running' }
    $catalogue['setting.AirVariableType.description'] = @{ ar = 'نوع المتغيرات المُرسلة مع العرض؛ Text يناسب القوالب النصية'; en = 'The variable type sent with a show; Text suits text templates' }
    $catalogue['setting.DropPendingUpdatesOnStart.description'] = @{ ar = 'يتجاهل ضغطات الأزرار التي وصلت قبل إعادة التشغيل فلا تُنفَّذ على الهواء متأخرة'; en = 'Ignores button presses that arrived before a restart, so they do not reach the air late' }
}
