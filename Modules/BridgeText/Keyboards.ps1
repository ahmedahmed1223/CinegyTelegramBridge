#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the keyboards and tables the administrator screens are
    built from: the administration tools menu, the user list and the card
    behind each name, the access requests, the settings sections, the two
    backup screens, and the per-template duration ceiling with its arithmetic
    buttons.
#>

function Add-BridgeTextKeyboards {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- The administrator keyboards --------------------------------------
    $catalogue['kb.readyToRun'] = @{ ar = '🟢 جاهز للتشغيل'; en = '🟢 Ready to run' }
    $catalogue['kb.needsReview'] = @{ ar = '🟠 يحتاج مراجعة'; en = '🟠 Needs a review' }
    $catalogue['kb.col.layer'] = @{ ar = 'الطبقة'; en = 'Layer' }
    $catalogue['kb.col.template'] = @{ ar = 'القالب'; en = 'Template' }
    $catalogue['kb.col.since'] = @{ ar = 'منذ'; en = 'Since' }
    $catalogue['kb.col.operator'] = @{ ar = 'المشغّل'; en = 'Operator' }
    $catalogue['kb.test'] = @{ ar = 'اختبار'; en = 'a test' }
    $catalogue['kb.usersAndRights'] = @{ ar = 'المستخدمون والصلاحيات'; en = 'Users and rights' }
    $catalogue['kb.contentAndTemplates'] = @{ ar = 'المحتوى والقوالب'; en = 'Content and templates' }
    $catalogue['kb.healthAndDiagnostics'] = @{ ar = 'الصحة والتشخيص'; en = 'Health and diagnostics' }
    $catalogue['kb.systemAndFeed'] = @{ ar = 'النظام والبث'; en = 'The system and the feed' }
    $catalogue['kb.manageUsers'] = @{ ar = '👥 إدارة المستخدمين'; en = '👥 Manage users' }
    $catalogue['kb.userActivity'] = @{ ar = '🟢 نشاط المستخدمين'; en = '🟢 User activity' }
    $catalogue['kb.templatesAndSettings'] = @{ ar = '📚 القوالب والإعدادات'; en = '📚 Templates and settings' }
    $catalogue['kb.readyTexts'] = @{ ar = '⚡ النصوص الجاهزة'; en = '⚡ Ready-made texts' }
    $catalogue['kb.notices'] = @{ ar = '📢 التنويهات'; en = '📢 Notices' }
    $catalogue['kb.shiftReadiness'] = @{ ar = '✅ جاهزية المناوبة'; en = '✅ Shift readiness' }
    $catalogue['kb.systemHealth'] = @{ ar = '🩺 صحة النظام'; en = '🩺 System health' }
    $catalogue['kb.runNumbers'] = @{ ar = '📈 أرقام التشغيل'; en = '📈 Running numbers' }
    $catalogue['kb.livePathCheck'] = @{ ar = '🧪 فحص المسار الحي'; en = '🧪 Live path check' }
    $catalogue['kb.usageSummary'] = @{ ar = '📊 ملخص الاستخدام'; en = '📊 Usage summary' }
    $catalogue['kb.log'] = @{ ar = '📜 السجل'; en = '📜 The log' }
    $catalogue['kb.diagnostics'] = @{ ar = '🧪 التشخيص'; en = '🧪 Diagnostics' }
    $catalogue['kb.rawCommand'] = @{ ar = '🛠 أمر خام'; en = '🛠 Raw command' }
    $catalogue['kb.stopFeed'] = @{ ar = '⏹ إيقاف البث'; en = '⏹ Stop the feed' }
    $catalogue['kb.startFeed'] = @{ ar = '▶️ بدء البث'; en = '▶️ Start the feed' }
    $catalogue['kb.feedLink'] = @{ ar = '🔗 رابط البث'; en = '🔗 Feed link' }
    $catalogue['kb.exportSettings'] = @{ ar = '📤 تصدير الإعدادات'; en = '📤 Export the settings' }
    $catalogue['kb.importSettings'] = @{ ar = '📥 استيراد الإعدادات'; en = '📥 Import settings' }
    $catalogue['kb.restartBridge'] = @{ ar = '♻️ إعادة تشغيل الجسر'; en = '♻️ Restart the bridge' }
    $catalogue['kb.backToAdminTools'] = @{ ar = '⬅️ أدوات الإدارة'; en = '⬅️ Administration tools' }
    $catalogue['kb.fullState'] = @{ ar = '📊 الحالة الكاملة'; en = '📊 The full state' }
    $catalogue['kb.runtimeFiles'] = @{ ar = '🗂 ملفات التشغيل'; en = '🗂 Runtime files' }
    $catalogue['kb.engineHealth'] = @{ ar = '🖥 صحة المحرك'; en = '🖥 Engine health' }
    $catalogue['kb.back'] = @{ ar = '⬅️ رجوع'; en = '⬅️ Back' }
    $catalogue['kb.authorisedUsers'] = @{ ar = '<b>👥 المستخدمون المصرح لهم</b>'; en = '<b>👥 Authorised users</b>' }
    $catalogue['kb.nobodyYet'] = @{ ar = '<i>لا أحد في القائمة بعد.</i>'; en = '<i>Nobody is on the list yet.</i>' }
    $catalogue['kb.owner'] = @{ ar = '👑 مالك'; en = '👑 Owner' }
    $catalogue['kb.admin'] = @{ ar = '🛡️ مشرف'; en = '🛡️ Administrator' }
    $catalogue['kb.operator'] = @{ ar = 'مشغّل'; en = 'operator' }
    $catalogue['kb.disabled'] = @{ ar = '⛔ معطّل'; en = '⛔ Disabled' }
    $catalogue['kb.enabled'] = @{ ar = '✅ نشط'; en = '✅ Active' }
    $catalogue['kb.noWorkingName'] = @{ ar = 'بلا اسم تشغيلي'; en = 'no working name' }
    $catalogue['kb.now'] = @{ ar = 'الآن'; en = 'now' }
    $catalogue['kb.you'] = @{ ar = ' (أنت)'; en = ' (you)' }
    $catalogue['kb.ownerMayPromote'] = @{ ar = "`n👑 بصفتك المالك يمكنك ترقية مشغّل إلى مشرف أو خفضه."; en = "`nAs the owner you may promote an operator to administrator, or demote one." }
    $catalogue['kb.tapNameForCard'] = @{ ar = "`n`nاضغط اسم المستخدم لفتح بطاقته: التعطيل والاسم والنشاط والسحب هناك."; en = "`n`nTap a name to open its card: disabling, the name, the activity and revoking all live there." }
    $catalogue['kb.userGoneHtml'] = @{ ar = '<i>المستخدم لم يعد ضمن قائمة المصرح لهم.</i>'; en = '<i>This user is no longer on the authorised list.</i>' }
    $catalogue['kb.bridgeOwner'] = @{ ar = '👑 مالك الجسر'; en = '👑 The bridge owner' }
    $catalogue['kb.operatorTag'] = @{ ar = '👤 مشغّل'; en = '👤 Operator' }
    $catalogue['kb.reEnable'] = @{ ar = '✅ إعادة التفعيل'; en = '✅ Enable again' }
    $catalogue['kb.disableTemporarily'] = @{ ar = '⛔ تعطيل مؤقت'; en = '⛔ Disable for now' }
    $catalogue['kb.workingName'] = @{ ar = '✏️ الاسم التشغيلي'; en = '✏️ Working name' }
    $catalogue['kb.activityDetail'] = @{ ar = '📈 تفاصيل النشاط'; en = '📈 Activity in detail' }
    $catalogue['kb.demoteToOperator'] = @{ ar = '⬇️ خفض إلى مشغّل'; en = '⬇️ Demote to operator' }
    $catalogue['kb.promoteToAdmin'] = @{ ar = '⬆️ ترقية إلى مشرف'; en = '⬆️ Promote to administrator' }
    $catalogue['kb.revoke'] = @{ ar = '🗑 سحب الصلاحية'; en = '🗑 Revoke the right' }
    $catalogue['kb.backToUserList'] = @{ ar = '⬅️ قائمة المستخدمين'; en = '⬅️ The user list' }
    $catalogue['kb.userGone'] = @{ ar = 'المستخدم لم يعد ضمن قائمة المصرح لهم.'; en = 'This user is no longer on the authorised list.' }
    $catalogue['kb.nameNotSaved'] = @{ ar = '❌ تعذر حفظ الاسم التشغيلي.'; en = '❌ Could not save the working name.' }
    $catalogue['kb.clearAlias'] = @{ ar = 'حذف الاسم البديل'; en = 'Remove the alias' }
    $catalogue['kb.pickFavourites'] = @{ ar = '<b>⭐ اختر القوالب التي تريد إظهارها في مفضلتك:</b>'; en = '<b>⭐ Choose the templates you want in your favourites:</b>' }
    $catalogue['kb.favouritesZero'] = @{ ar = '<i>⚠️ عدد المفضلة المعروضة مضبوط على صفر، فلن يظهر أي قالب في القائمة.</i>'; en = '<i>⚠️ The number of favourites on show is set to zero, so no template will appear in the menu.</i>' }
    $catalogue['kb.newReadyText'] = @{ ar = '➕ إنشاء نص جاهز'; en = '➕ New ready-made text' }
    $catalogue['kb.editValues'] = @{ ar = '✏️ تعديل القيم'; en = '✏️ Edit the values' }
    $catalogue['kb.addSchedule'] = @{ ar = '➕ جدولة عرض'; en = '➕ Schedule a show' }
    $catalogue['kb.setRepeatEnd'] = @{ ar = '📆 تحديد نهاية التكرار'; en = '📆 Set when the repeat ends' }
    $catalogue['kb.noEnd'] = @{ ar = '♾ بدون انتهاء'; en = '♾ With no end' }
    $catalogue['kb.unlinkItem'] = @{ ar = '🔗 إلغاء الربط بالمادة'; en = '🔗 Unlink from the item' }
    $catalogue['kb.linkItem'] = @{ ar = '🎞 اربط بمادة'; en = '🎞 Link to an item' }
    $catalogue['kb.confirmSchedule'] = @{ ar = '✅ تأكيد الجدولة'; en = '✅ Confirm the schedule' }
    $catalogue['kb.noUpcoming'] = @{ ar = 'لا توجد أحداث قادمة.'; en = 'There are no upcoming events.' }
    $catalogue['kb.col.when'] = @{ ar = 'الموعد'; en = 'When' }
    $catalogue['kb.col.repeat'] = @{ ar = 'التكرار'; en = 'Repeat' }
    $catalogue['kb.copy'] = @{ ar = '📄 نسخ'; en = '📄 Copy' }
    $catalogue['kb.accepted'] = @{ ar = '✅ مقبول'; en = '✅ Accepted' }
    $catalogue['kb.refused'] = @{ ar = '❌ مرفوض'; en = '❌ Refused' }
    $catalogue['kb.awaitingDecision'] = @{ ar = '⏳ بانتظار القرار'; en = '⏳ Awaiting a decision' }
    $catalogue['kb.noRequestsInPeriod'] = @{ ar = 'لا توجد طلبات مسجّلة في هذه المدة.'; en = 'No request is recorded in this period.' }
    $catalogue['kb.col.requester'] = @{ ar = 'الطالب'; en = 'Requester' }
    $catalogue['kb.col.status'] = @{ ar = 'الحالة'; en = 'Status' }
    $catalogue['kb.col.decision'] = @{ ar = 'القرار'; en = 'Decision' }
    $catalogue['kb.col.by'] = @{ ar = 'بواسطة'; en = 'By' }
    $catalogue['kb.oldRefusalsNote'] = @{ ar = 'ℹ️ الطلبات المرفوضة قبل هذا الإصدار غير مسجّلة؛ الموافقات القديمة مأخوذة من سجل المستخدمين.'; en = 'ℹ️ Requests refused before this release are not recorded; the older approvals come from the user log.' }
    $catalogue['kb.noRequestsInPeriodHtml'] = @{ ar = '<i>لا توجد طلبات مسجّلة في هذه المدة.</i>'; en = '<i>No request is recorded in this period.</i>' }
    $catalogue['kb.pendingRequests'] = @{ ar = '👤 الطلبات المعلّقة'; en = '👤 Pending requests' }
    $catalogue['kb.noRequestsNow'] = @{ ar = 'لا طلبات الآن.'; en = 'No requests right now.' }
    $catalogue['kb.col.id'] = @{ ar = 'المعرّف'; en = 'Id' }
    $catalogue['kb.col.name'] = @{ ar = 'الاسم'; en = 'Name' }
    $catalogue['kb.pendingRequestsTitle'] = @{ ar = '<b>👤 طلبات الوصول المعلّقة</b>'; en = '<b>👤 Pending access requests</b>' }
    $catalogue['kb.noRequestsNowHtml'] = @{ ar = '<i>لا طلبات الآن.</i>'; en = '<i>No requests right now.</i>' }
    $catalogue['kb.pastRequests'] = @{ ar = '📜 الطلبات السابقة'; en = '📜 Earlier requests' }
    $catalogue['kb.noPendingNow'] = @{ ar = 'لا توجد طلبات معلّقة حاليًا'; en = 'There are no pending requests right now' }
    $catalogue['kb.blocked'] = @{ ar = '🚫 المحظورون'; en = '🚫 The blocked' }
    $catalogue['kb.adminRefused'] = @{ ar = 'رفض المشرف الطلب'; en = 'the administrator refused the request' }
    $catalogue['kb.repeatedBadCode'] = @{ ar = 'رمز انضمام خاطئ متكرر'; en = 'a wrong join code, over and over' }
    $catalogue['kb.noReasonRecorded'] = @{ ar = 'بلا سبب مسجّل'; en = 'with no reason recorded' }
    $catalogue['kb.blockedChats'] = @{ ar = '<b>🚫 المحادثات المحظورة</b>'; en = '<b>🚫 Blocked chats</b>' }
    $catalogue['kb.noBlockedChat'] = @{ ar = '<i>لا محادثة محظورة.</i>'; en = '<i>No chat is blocked.</i>' }
    $catalogue['kb.backToSettings'] = @{ ar = '⬅️ الإعدادات'; en = '⬅️ The settings' }
    $catalogue['kb.resetThisSetting'] = @{ ar = '✅ إعادة هذا الإعداد'; en = '✅ Reset this setting' }
    $catalogue['kb.allKnownLayers'] = @{ ar = 'كل الطبقات المعروفة'; en = 'every known layer' }
    $catalogue['kb.noLayersChosen'] = @{ ar = 'لا توجد طبقات محددة'; en = 'no layer is chosen' }
    $catalogue['kb.on'] = @{ ar = 'مفعّل'; en = 'on' }
    $catalogue['kb.off'] = @{ ar = 'معطّل'; en = 'off' }
    $catalogue['kb.newsFile'] = @{ ar = '📰 ملف الأخبار'; en = '📰 The news file' }
    $catalogue['kb.quietTwoHours'] = @{ ar = '🔇 هدوء ساعتين (غير العاجل فقط)'; en = '🔇 Two quiet hours (the non-urgent only)' }
    $catalogue['kb.backToSettingsSections'] = @{ ar = '⬅️ أقسام الإعدادات'; en = '⬅️ The settings sections' }
    $catalogue['kb.pickTemplateToRead'] = @{ ar = '📚 القوالب والإعدادات — اختر قالبًا لقراءة تعريفه:'; en = '📚 Templates and settings — choose a template to read its definition:' }
    $catalogue['kb.exportJson'] = @{ ar = '📤 تصدير JSON'; en = '📤 Export JSON' }
    $catalogue['kb.importJson'] = @{ ar = '📥 استيراد JSON'; en = '📥 Import JSON' }
    $catalogue['kb.addTemplate'] = @{ ar = '➕ إضافة قالب'; en = '➕ Add a template' }
    $catalogue['kb.addViaJson'] = @{ ar = '📄 إضافة عبر JSON'; en = '📄 Add through JSON' }
    $catalogue['kb.appearAlert'] = @{ ar = '🔔 تنبيه الظهور'; en = '🔔 Appearance alert' }
    $catalogue['kb.editDefinition'] = @{ ar = '✏️ تعديل التعريف'; en = '✏️ Edit the definition' }
    $catalogue['kb.deleteTemplate'] = @{ ar = '🗑 حذف القالب'; en = '🗑 Delete the template' }
    $catalogue['kb.testOnTrialLayer'] = @{ ar = '🧪 اختبار على طبقة التجربة'; en = '🧪 Test on the trial layer' }
    $catalogue['kb.selectAllLayers'] = @{ ar = '☑️ اختيار كل الطبقات'; en = '☑️ Select every layer' }
    $catalogue['kb.selectNoLayers'] = @{ ar = '🚫 إلغاء اختيار الكل'; en = '🚫 Select none' }
    $catalogue['kb.noLayersDefined'] = @{ ar = 'لا توجد طبقات معرفة'; en = 'no layer is defined' }
    $catalogue['kb.clearName'] = @{ ar = '🗑️ مسح الاسم'; en = '🗑️ Clear the name' }
    $catalogue['kb.backToLayerNames'] = @{ ar = '⬅️ أسماء الطبقات'; en = '⬅️ The layer names' }
    $catalogue['kb.templateBackups'] = @{ ar = '<b>🗄 نسخ القوالب</b>'; en = '<b>🗄 Template backups</b>' }
    $catalogue['kb.noTemplateBackups'] = @{ ar = '<i>لا نسخ محفوظة بعد. تُحفظ نسخة مع كل تعديل على القوالب.</i>'; en = '<i>No backup is kept yet. One is kept with every edit to the templates.</i>' }
    $catalogue['kb.restoreShowsDiff'] = @{ ar = '<i>الاستعادة تعرض ما سيتغيّر قبل الكتابة، وتُرفض إن مسّت قالبًا على الهواء أو في جدولة قادمة.</i>'; en = '<i>A restore shows what will change before it writes, and is refused if it touches a template on air or in an upcoming schedule.</i>' }
    $catalogue['kb.noBackupsKept'] = @{ ar = 'لا توجد نسخ محفوظة'; en = 'no backup is kept' }
    $catalogue['kb.yesRestoreThis'] = @{ ar = '⚠️ نعم، استعد هذه النسخة'; en = '⚠️ Yes, restore this backup' }
    $catalogue['kb.confirmTemplateRestore'] = @{ ar = '<b>⚠️ تأكيد استعادة القوالب</b>'; en = '<b>⚠️ Confirm the template restore</b>' }
    $catalogue['kb.willBeDeleted'] = @{ ar = '🗑 ستُحذف'; en = '🗑 Will be deleted' }
    $catalogue['kb.willChange'] = @{ ar = '✏️ ستتغيّر'; en = '✏️ Will change' }
    $catalogue['kb.willBeAdded'] = @{ ar = '➕ ستُضاف'; en = '➕ Will be added' }
    $catalogue['kb.noDifference'] = @{ ar = '<i>لا فرق بين هذه النسخة والقوالب الحالية.</i>'; en = '<i>There is no difference between this backup and the templates as they stand.</i>' }
    $catalogue['kb.restoreIsUndoable'] = @{ ar = '<i>تُحفظ نسخة من القوالب الحالية قبل الكتابة، فالاستعادة نفسها قابلة للتراجع.</i>'; en = '<i>A backup of the current templates is kept before writing, so the restore itself can be undone.</i>' }
    $catalogue['kb.settingsBackups'] = @{ ar = '<b>🗄 نسخ الإعدادات</b>'; en = '<b>🗄 Settings backups</b>' }
    $catalogue['kb.noSettingsBackups'] = @{ ar = '<i>لا نسخ محفوظة بعد. تُحفظ نسخة مع كل تغيير.</i>'; en = '<i>No backup is kept yet. One is kept with every change.</i>' }
    $catalogue['kb.settingsRestoreNote'] = @{ ar = '<i>الاستعادة تعرض جدول ما سيتغيّر قبل الكتابة، وتحتاج إعادة تشغيل بعدها.</i>'; en = '<i>A restore shows a table of what will change before it writes, and needs a restart afterwards.</i>' }
    $catalogue['kb.yesRestoreBackup'] = @{ ar = '⚠️ نعم، استعادة النسخة'; en = '⚠️ Yes, restore the backup' }
    $catalogue['kb.yesDisableProtection'] = @{ ar = '⚠️ نعم، عطّل الحماية'; en = '⚠️ Yes, turn the protection off' }
    $catalogue['kb.anotherDuration'] = @{ ar = '⌨️ مدة أخرى'; en = '⌨️ Another duration' }
    $catalogue['kb.everyone'] = @{ ar = '📢 الجميع'; en = '📢 Everyone' }
    $catalogue['kb.adminsOnly'] = @{ ar = '👮 المشرفون'; en = '👮 The administrators' }
    $catalogue['kb.nobody'] = @{ ar = '🔕 لا أحد'; en = '🔕 Nobody' }
    $catalogue['kb.showNoticeByTemplate'] = @{ ar = '🔔 <b>إشعار العرض حسب القالب</b>'; en = '🔔 <b>Show notice, template by template</b>' }
    $catalogue['kb.tapToCycle'] = @{ ar = 'اضغط على القالب ليتنقّل بين: 🔕 لا أحد ← 👮 المشرفون ← 📢 الجميع.'; en = 'Tap a template to cycle it: 🔕 Nobody ← 👮 The administrators ← 📢 Everyone.' }
    $catalogue['kb.noticeCarries'] = @{ ar = 'الإشعار يحمل نصّ الخبر ومدّته ومن نشره، ولا يصل صاحبه.'; en = 'The notice carries the headline text, its duration and who published it, and never reaches its own author.' }
    $catalogue['kb.perTemplateCeiling'] = @{ ar = "⏱ أقصى مدة لكل قالب`nاختر القالب. القاعدة تُطبّق على العروض الجديدة للجميع؛ مدة أقصر مسموحة، ولا يمكن تمديدها فوق الحد. لا تغيّر ما على الهواء الآن."; en = "⏱ The longest duration, template by template`nChoose a template. The rule applies to new shows for everyone; a shorter duration is allowed, and none can be stretched past the ceiling. It changes nothing that is on air now." }
    $catalogue['kb.thirtySeconds'] = @{ ar = '30 ث'; en = '30 s' }
    $catalogue['kb.oneMinute'] = @{ ar = 'دقيقة'; en = '1 min' }
    $catalogue['kb.twoMinutes'] = @{ ar = 'دقيقتان'; en = '2 min' }
    $catalogue['kb.threeMinutes'] = @{ ar = '3 دقائق'; en = '3 min' }
    $catalogue['kb.fiveMinutes'] = @{ ar = '5 دقائق'; en = '5 min' }
    $catalogue['kb.tenMinutes'] = @{ ar = '10 دقائق'; en = '10 min' }
    $catalogue['kb.minusTenSeconds'] = @{ ar = '−10 ث'; en = '−10 s' }
    $catalogue['kb.plusTenSeconds'] = @{ ar = '+10 ث'; en = '+10 s' }
    $catalogue['kb.minusOneSecond'] = @{ ar = '−1 ث'; en = '−1 s' }
    $catalogue['kb.plusOneSecond'] = @{ ar = '+1 ث'; en = '+1 s' }
    $catalogue['kb.customAmount'] = @{ ar = '⌨️ مقدار مخصص'; en = '⌨️ A custom amount' }
    $catalogue['kb.confirmCeilingRemoval'] = @{ ar = "`n⚠️ تأكيد إزالة الحد الخاص؟ تبقى مؤقتات العروض الحالية كما هي."; en = "`n⚠️ Remove the special ceiling? The timers on the current shows stay as they are." }
    $catalogue['kb.yesRemoveCeiling'] = @{ ar = 'نعم، إزالة الحد'; en = 'Yes, remove the ceiling' }
    $catalogue['kb.removeCeiling'] = @{ ar = 'إزالة الحد…'; en = 'Remove the ceiling…' }
    $catalogue['kb.applyNow'] = @{ ar = '⚖️ طبّق الآن'; en = '⚖️ Apply it now' }
    $catalogue['kb.applyNowExplain'] = @{ ar = "`n⚖️ «طبّق الآن» يقصّر بقاء العرض الحالي إلى الحد إذا كان أطول منه؛ لا يطيل ولا يخفي فورًا."; en = "`n⚖️ `"Apply it now`" shortens the current show down to the ceiling if it runs longer; it never lengthens one and never hides one on the spot." }
    $catalogue['kb.customAmountExplain'] = @{ ar = "`n⌨️ «مقدار مخصص» لكتابة Duration مثل 2:30 أو 90."; en = "`n⌨️ `"A custom amount`" lets you type a duration such as 2:30 or 90." }
    $catalogue['kb.buttonsExpired'] = @{ ar = '⚠️ انتهت صلاحية الأزرار. افتح إعداد المدة من جديد.'; en = '⚠️ These buttons have expired. Open the duration setting again.' }
    $catalogue['kb.noShowOverCeiling'] = @{ ar = 'لا عرض حالي لهذا القالب أطول من الحد، أو لا مؤقّت له.'; en = 'No current show of this template runs past the ceiling, or none has a timer.' }
    $catalogue['kb.sendDuration'] = @{ ar = "⌨️ أرسل المدة بـ«دقائق:ثوانٍ» (مثل 2:30) أو ثوانٍ فقط (مثل 90).`nللإلغاء: /الغاء"; en = "⌨️ Send the duration as `"minutes:seconds`" (such as 2:30) or as seconds alone (such as 90).`nTo cancel: /الغاء" }
    $catalogue['kb.ceilingNotSaved'] = @{ ar = '⚠️ تعذّر حفظ الحد؛ بقيت القاعدة السابقة.'; en = '⚠️ Could not save the ceiling; the earlier rule still stands.' }
    $catalogue['kb.notSet'] = @{ ar = 'غير محدّد'; en = 'not set' }
    $catalogue['kb.noTiming'] = @{ ar = '🚫 بلا توقيت'; en = '🚫 With no timing' }
    $catalogue['kb.anotherHour'] = @{ ar = '⬅️ ساعة أخرى'; en = '⬅️ Another hour' }
    $catalogue['kb.noTimingPlain'] = @{ ar = 'بلا توقيت'; en = 'with no timing' }
    $catalogue['kb.noItemsDefined'] = @{ ar = 'لا توجد عناصر معرفة'; en = 'no item is defined' }
    $catalogue['kb.emptyTheList'] = @{ ar = '🧹 إفراغ القائمة (للجميع)'; en = '🧹 Empty the list (for everyone)' }
    $catalogue['kb.nothingChosen'] = @{ ar = '<i>لا شيء محدد — متاح للجميع.</i>'; en = '<i>Nothing is chosen — it is open to everyone.</i>' }
    $catalogue['kb.tapToToggle'] = @{ ar = 'اضغط العنصر لإضافته أو إزالته.'; en = 'Tap an item to add or remove it.' }
    $catalogue['kb.needAbsoluteTxtPath'] = @{ ar = "❌ يجب إدخال مسار مطلق ينتهي بـ .txt، مثل:`nD:\cingy cg\ticker msg\news.txt`nلم يتغيّر الإعداد."; en = "❌ An absolute path ending in .txt is required, such as:`nD:\cingy cg\ticker msg\news.txt`nThe setting did not change." }
    $catalogue['kb.multiSceneUnavailable'] = @{ ar = '⛔ وضع المشاهد المتعددة غير متاح: تعذّر التحقق من Cinegy.'; en = '⛔ The multi-scene mode is unavailable: Cinegy could not be checked.' }
}
