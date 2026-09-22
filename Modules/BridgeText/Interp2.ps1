#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the users and what a dead chat says about itself, the
    weekly sheet, the notice board from the first draft to the delivery
    count, and the template register with the Cinegy health line and every
    reason a template is skipped at load.
#>

function Add-BridgeTextInterp2 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['usr.badImportSize'] = @{ ar = 'حجم ملف الاستيراد غير صالح ({0} بايت).'; en = 'The import file size is not valid ({0} bytes).' }
    $catalogue['usr.deadArchived'] = @{ ar = '💀 أُرشفت محادثة ميتة {0} بعد 30 يومًا بلا قرار'; en = '💀 The dead chat {0} was archived after 30 days with no decision' }
    $catalogue['usr.deadChat'] = @{ ar = '💀 محادثة ميتة: {0} ({1}) — أُوقف الإرسال لها بعد {2}'; en = '💀 A dead chat: {0} ({1}) — sending to it stopped after {2}' }
    $catalogue['usr.deadChatNotice'] = @{ ar = '💀 المحادثة «{0}» ({1}) لا تستقبل من البوت ({2}) — أُوقف الإرسال لها. أعد التفعيل بعد إصلاحها أو اسحب صلاحيتها من شاشة المستخدمين.'; en = '💀 The chat "{0}" ({1}) does not receive from the bot ({2}) — sending to it stopped. Enable it again once it is fixed, or revoke its right from the users screen.' }
    $catalogue['usr.chatReEnabled'] = @{ ar = '💀 أُعيد تفعيل المحادثة {0}'; en = '💀 The chat {0} was enabled again' }
    $catalogue['usr.testPassed'] = @{ ar = '🔍 اختبار المحادثة {0} ناجح — أُعيد التفعيل بواسطة {1}'; en = '🔍 The test on chat {0} passed — enabled again by {1}' }
    $catalogue['usr.chatReceives'] = @{ ar = '✅ المحادثة {0} تستقبل — أُعيد تفعيلها.'; en = '✅ Chat {0} receives — it was enabled again.' }
    $catalogue['usr.stillNotReceiving'] = @{ ar = "❌ ما زالت لا تستقبل — بقيت محجورة.`n{0}"; en = "❌ It still does not receive — it stays quarantined.`n{0}" }
    $catalogue['usr.deadChats'] = @{ ar = '<b>💀 محادثات ميتة ({0})</b>'; en = '<b>💀 Dead chats ({0})</b>' }
    $catalogue['usr.deadChatRow'] = @{ ar = "• {0} (<code>{1}</code>) · منذ {2}`n  {3}"; en = "• {0} (<code>{1}</code>) · since {2}`n  {3}" }
    $catalogue['usr.autoBlocked'] = @{ ar = "🚫 حُظرت المحادثة {0} تلقائيًا ({1}).`nارفع الحظر من 👤 طلبات الوصول ← 🚫 المحظورون."; en = "🚫 Chat {0} was blocked automatically ({1}).`nLift the block from 👤 Access requests ← 🚫 The blocked." }
    $catalogue['usr.dormantSince'] = @{ ar = '😴 مستخدمون بلا نشاط منذ {0} يومًا أو أكثر:'; en = '😴 Users with no activity for {0} days or more:' }
    $catalogue['usr.dormantRow'] = @{ ar = '• {0} ({1}) · {2} يومًا{3}'; en = '• {0} ({1}) · {2} days{3}' }
    $catalogue['usr.leftUnknownGroup'] = @{ ar = '🚪 غادر البوت محادثة جماعية غير معروفة: {0} ({1})'; en = '🚪 The bot left a group chat it does not know: {0} ({1})' }
    $catalogue['usr.confirmRevoke'] = @{ ar = '⚠️ تأكيد سحب صلاحية {0} ({1})؟'; en = '⚠️ Revoke {0}''s right ({1})?' }
    $catalogue['usr.activeRecently'] = @{ ar = '🟢 نشط حديثًا · منذ {0}'; en = '🟢 Active recently · {0} ago' }
    $catalogue['usr.idle'] = @{ ar = '🟠 خامل · منذ {0}'; en = '🟠 Idle · {0} ago' }
    $catalogue['usr.activityScreen'] = @{ ar = '<b>👥 نشاط المستخدمين التقريبي</b> · النافذة <code>{0}</code> د'; en = '<b>👥 Roughly how active the users are</b> · a <code>{0}</code> min window' }
    $catalogue['usr.card'] = @{ ar = "<b>👤 {0}</b>`n{1}`n<i>الحالة تقريبية حسب آخر تفاعل مع البوت؛ Telegram لا يوفّر اتصالًا لحظيًا للبوت.</i>"; en = "<b>👤 {0}</b>`n{1}`n<i>This is a rough state, from the last exchange with the bot; Telegram gives a bot no live connection.</i>" }
    $catalogue['usr.confirmPromote'] = @{ ar = "⚠️ ترقية {0} ({1}) إلى مشرف؟`nسيستطيع تغيير كل الإعدادات وإعادة تشغيل الجسر وسحب صلاحيات المستخدمين."; en = "⚠️ Promote {0} ({1}) to administrator?`nThey will be able to change every setting, restart the bridge and revoke other users." }
    $catalogue['usr.confirmDemote'] = @{ ar = "⚠️ خفض {0} ({1}) إلى مشغّل؟`nستُسحب منه أدوات الإدارة كلها."; en = "⚠️ Demote {0} ({1}) to operator?`nEvery administration tool is taken away." }
    $catalogue['wk.title'] = @{ ar = '📋 تقرير أسبوعي — {0}'; en = '📋 Weekly report — {0}' }
    $catalogue['wk.screenNearLimit'] = @{ ar = '📐 شاشة قريبة من حدّ حجمها: <b>{0}</b> — {1}% من الحدّ.'; en = '📐 A screen near its size limit: <b>{0}</b> — {1}% of the limit.' }
    $catalogue['wk.plusOthers'] = @{ ar = ' (+{0} أخرى)'; en = ' (+{0} more)' }
    $catalogue['wk.unusedTemplates'] = @{ ar = '🕸 قوالب بلا استعمال منذ شهر: {0}{1}'; en = '🕸 Templates unused for a month: {0}{1}' }
    $catalogue['wk.pair'] = @{ ar = '{0} — {1}'; en = '{0} — {1}' }
    $catalogue['wk.repeatFailures'] = @{ ar = '🔁 فشل متكرر بنفس السبب: {0}'; en = '🔁 Failures repeating for the same cause: {0}' }
    $catalogue['wk.plusOthers2'] = @{ ar = ' (+{0} غيرها)'; en = ' (+{0} others)' }
    $catalogue['wk.changedSettings'] = @{ ar = '⚙️ إعدادات معدّلة عن الافتراضي: {0}{1}'; en = '⚙️ Settings changed from their default: {0}{1}' }
    $catalogue['wk.news'] = @{ ar = '📰 الأخبار: {0} · آخر نشرة {1}'; en = '📰 The news: {0} · the last bulletin {1}' }
    $catalogue['wk.urgents'] = @{ ar = '🚨 العواجل: {0} · {1} بُثّت'; en = '🚨 The urgents: {0} · {1} went out' }
    $catalogue['wk.readLimit'] = @{ ar = '⚠️ بلغ السجل حدّ القراءة ({0} سجلًّا)؛ قد تكون هناك عمليات أقدم داخل المدة.'; en = '⚠️ The log hit its read limit ({0} records); there may be older operations inside the period.' }
    $catalogue['wk.titleHtml'] = @{ ar = '<b>📋 تقرير أسبوعي</b> — {0}'; en = '<b>📋 Weekly report</b> — {0}' }
    $catalogue['wk.screenNearLimitShort'] = @{ ar = '📐 شاشة قريبة من حدّها: <b>{0}</b> — {1}%'; en = '📐 A screen near its limit: <b>{0}</b> — {1}%' }
    $catalogue['wk.repeatFailuresShort'] = @{ ar = '🔁 فشل متكرر: {0}'; en = '🔁 Repeating failures: {0}' }
    $catalogue['wk.changedSettingsShort'] = @{ ar = '⚙️ إعدادات معدّلة: {0}{1}'; en = '⚙️ Changed settings: {0}{1}' }
    $catalogue['ann.forWhom'] = @{ ar = 'لـ {0}'; en = 'for {0}' }
    $catalogue['ann.from'] = @{ ar = '<i>من {0}</i>'; en = '<i>from {0}</i>' }
    $catalogue['ann.stoppedAudit'] = @{ ar = '📢 إيقاف تنويه {0} - بواسطة {1}'; en = '📢 Notice {0} stopped - by {1}' }
    $catalogue['ann.countLine'] = @{ ar = '{0} تنويهًا · {1} نشِط'; en = '{0} notices · {1} active' }
    $catalogue['ann.page'] = @{ ar = ' · صفحة {0} من {1}'; en = ' · page {0} of {1}' }
    $catalogue['ann.row'] = @{ ar = '   {0} · {1} · اطّلع {2}'; en = '   {0} · {1} · seen by {2}' }
    $catalogue['ann.repeatsEvery'] = @{ ar = ' · يتكرر كل {0} س'; en = ' · repeats every {0} h' }
    $catalogue['ann.stopButton'] = @{ ar = '🚫 إيقاف · {0}'; en = '🚫 Stop · {0}' }
    $catalogue['ann.newScreen'] = @{ ar = "📢 <b>تنويه جديد</b>`n`nأرسل نص التنويه كما تريد أن يقرأه الناس.`n<i>الحد {0} حرفًا، وتختار بعده من يصله ومدّته وتكراره.</i>"; en = "📢 <b>A new notice</b>`n`nSend the notice text as you want people to read it.`n<i>The limit is {0} characters, and after it you choose who it reaches, how long it lasts and how often it repeats.</i>" }
    $catalogue['ann.hours'] = @{ ar = '{0} س'; en = '{0} h' }
    $catalogue['ann.everyHours'] = @{ ar = 'كل {0} س'; en = 'every {0} h' }
    $catalogue['ann.recipients'] = @{ ar = '👥 المستلمون: {0}'; en = '👥 Recipients: {0}' }
    $catalogue['ann.duration'] = @{ ar = '⌛ المدة: {0}'; en = '⌛ Duration: {0}' }
    $catalogue['ann.repeat'] = @{ ar = '🔁 التكرار: {0}'; en = '🔁 Repeat: {0}' }
    $catalogue['ann.seenButtonToggle'] = @{ ar = '{0} زر «تم الاطلاع»'; en = '{0} a "Seen" button' }
    $catalogue['ann.pinToggle'] = @{ ar = '{0} تثبيت في القائمة'; en = '{0} pinned to the menu' }
    $catalogue['ann.review'] = @{ ar = "📢 <b>مراجعة التنويه</b>`n`n{0}`n`n<i>سيصل إلى {1} شخصًا عداك.</i>"; en = "📢 <b>Review the notice</b>`n`n{0}`n`n<i>It will reach {1} people besides you.</i>" }
    $catalogue['ann.sentAudit'] = @{ ar = '📢 تنويه {0} ({1} مستلمًا) - بواسطة {2}'; en = '📢 Notice {0} ({1} recipients) - by {2}' }
    $catalogue['ann.delivered'] = @{ ar = '✅ وصل التنويه إلى {0} شخصًا.'; en = '✅ The notice reached {0} people.' }
    $catalogue['tpl.lockedOnAir'] = @{ ar = 'لا يمكن تغيير أو حذف قالب على الهواء أو في جدولة قادمة: {0}'; en = 'A template on air or in an upcoming schedule cannot be changed or deleted: {0}' }
    $catalogue['tpl.fileMissing'] = @{ ar = 'ملف القوالب غير موجود: {0}'; en = 'The templates file is not there: {0}' }
    $catalogue['tpl.unreadable'] = @{ ar = 'تعذّر قراءة templates.json: {0}'; en = 'templates.json could not be read: {0}' }
    $catalogue['tpl.noPath'] = @{ ar = 'القالب ''{0}'' بلا حقل path - تم تخطيه.'; en = 'The template ''{0}'' has no path field - it was skipped.' }
    $catalogue['tpl.pathNotAbsolute'] = @{ ar = 'القالب ''{0}'' له مسار غير مطلق ''{1}'' - اضبط TemplateBasePath أو اكتب مسارًا كاملًا.'; en = 'The template ''{0}'' has a path that is not absolute, ''{1}'' - set TemplateBasePath or write a full path.' }
    $catalogue['tpl.notCintitle'] = @{ ar = 'القالب ''{0}'' يجب أن يشير إلى ملف .cintitle - تم تخطيه.'; en = 'The template ''{0}'' must point at a .cintitle file - it was skipped.' }
    $catalogue['tpl.noLayer'] = @{ ar = 'القالب ''{0}'' بلا حقل layer صالح - تم تخطيه.'; en = 'The template ''{0}'' has no valid layer field - it was skipped.' }
    $catalogue['tpl.fieldWithoutName'] = @{ ar = 'القالب ''{0}'' فيه حقل بلا اسم - تم تخطيه.'; en = 'The template ''{0}'' has a field without a name - it was skipped.' }
    $catalogue['tpl.badDeviceName'] = @{ ar = 'القالب ''{0}'' فيه اسم جهاز غير صالح ''{1}'' - تم تجاهل الاسم.'; en = 'The template ''{0}'' has an invalid device name, ''{1}'' - the name was ignored.' }
    $catalogue['tpl.badReminder'] = @{ ar = 'القالب ''{0}'' فيه reminderMinutes غير صالح؛ استخدم 0 إلى 1440 دقيقة.'; en = 'The template ''{0}'' has an invalid reminderMinutes; use 0 to 1440 minutes.' }
    $catalogue['tpl.minutesBefore'] = @{ ar = 'قبل {0} د'; en = '{0} min before' }
    $catalogue['tpl.hoursBefore'] = @{ ar = 'قبل {0} س'; en = '{0} h before' }
    $catalogue['tpl.before'] = @{ ar = 'قبل {0}'; en = '{0} before' }
    $catalogue['tpl.keyExists'] = @{ ar = 'يوجد قالب بالمفتاح ''{0}'' بالفعل.'; en = 'A template with the key ''{0}'' already exists.' }
    $catalogue['tpl.notFound'] = @{ ar = 'القالب ''{0}'' غير موجود.'; en = 'The template ''{0}'' is not there.' }
    $catalogue['tpl.layerUnknown'] = @{ ar = '⚠️ {0}: غير معروف'; en = '⚠️ {0}: unknown' }
    $catalogue['tpl.layerHidden'] = @{ ar = '⚪ {0}: مخفية'; en = '⚪ {0}: hidden' }
    $catalogue['tpl.layerExternal'] = @{ ar = '🟠 {0}: {1} (خارجي)'; en = '🟠 {0}: {1} (from outside)' }
    $catalogue['tpl.output'] = @{ ar = 'الخرج {0}'; en = 'output {0}' }
    $catalogue['tpl.licence'] = @{ ar = 'الترخيص {0}'; en = 'licence {0}' }
    $catalogue['tpl.client'] = @{ ar = 'العميل {0}'; en = 'client {0}' }
    $catalogue['tpl.metrics'] = @{ ar = 'العينات {0}، الخرج {1}، الساقط {2}، فقد الإدخال {3}، أخطاء القراءة {4}%، متوسط القراءة {5}ms، Heartbeat {6}ms'; en = 'samples {0}, output {1}, dropped {2}, input lost {3}, read errors {4}%, mean read {5}ms, heartbeat {6}ms' }
    $catalogue['tpl.healthGood'] = @{ ar = '💚 صحة Cinegy: سليمة — {0}'; en = '💚 Cinegy health: sound — {0}' }
    $catalogue['tpl.healthWarning'] = @{ ar = '🔴 صحة Cinegy: تحذير — {0}'; en = '🔴 Cinegy health: a warning — {0}' }
}
