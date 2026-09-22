#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the administrator keyboards — the readiness line, the
    user list, the access requests, the backups and the settings editors —
    and the bulletin screens with their frame arithmetic and slots.
#>

function Add-BridgeTextInterp5 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['kb.readinessLine'] = @{ ar = '{0} · Telegram: {1} · Cinegy: {2} · القرص: {3} GB'; en = '{0} · Telegram: {1} · Cinegy: {2} · disc: {3} GB' }
    $catalogue['kb.checkedAgo'] = @{ ar = 'تحقّق قبل {0} ث'; en = 'checked {0} s ago' }
    $catalogue['kb.lastCheckAgo'] = @{ ar = '⚠️ آخر تحقّق قبل {0} ث'; en = '⚠️ last checked {0} s ago' }
    $catalogue['kb.engineChannel'] = @{ ar = '🌐 {0} · القناة {1}'; en = '🌐 {0} · channel {1}' }
    $catalogue['kb.onAirCount'] = @{ ar = '🔴 <b>على الهواء ({0})</b>'; en = '🔴 <b>On air ({0})</b>' }
    $catalogue['kb.layerRow'] = @{ ar = ' • طبقة <code>{0}</code> · <b>{1}</b>'; en = ' • layer <code>{0}</code> · <b>{1}</b>' }
    $catalogue['kb.ago'] = @{ ar = 'منذ {0}'; en = '{0} ago' }
    $catalogue['kb.andMoreHideBelow'] = @{ ar = '   <i>و{0} أخرى - أزرار الإخفاء أدناه</i>'; en = '   <i>and {0} more - the hide buttons are below</i>' }
    $catalogue['kb.engineChannelHtml'] = @{ ar = '🌐 <code>{0}</code> · القناة <code>{1}</code>'; en = '🌐 <code>{0}</code> · channel <code>{1}</code>' }
    $catalogue['kb.layerPair'] = @{ ar = 'الطبقة {0} · {1}'; en = 'Layer {0} · {1}' }
    $catalogue['kb.onAirSince'] = @{ ar = 'على الهواء منذ {0}'; en = 'on air for {0}' }
    $catalogue['kb.sentBy'] = @{ ar = 'أرسله: {0}'; en = 'sent by: {0}' }
    $catalogue['kb.narrowSearch'] = @{ ar = '🔎 ضيّق البحث · {0} نتيجة أخرى'; en = '🔎 Narrow the search · {0} more results' }
    $catalogue['kb.templateQuote'] = @{ ar = "<blockquote>{0}`nالتصنيف: {1}`nالحقول: {2}</blockquote>"; en = "<blockquote>{0}`nCategory: {1}`nFields: {2}</blockquote>" }
    $catalogue['kb.usageLast'] = @{ ar = 'الاستخدام: <code>{0}</code> · آخر مرة: <code>{1}</code>'; en = 'Used: <code>{0}</code> · last time: <code>{1}</code>' }
    $catalogue['kb.searchResults'] = @{ ar = '🔎 نتائج البحث عن ''{0}'':'; en = '🔎 Search results for ''{0}'':' }
    $catalogue['kb.withAdminRight'] = @{ ar = '{0} · {1} بصلاحية إشراف'; en = '{0} · {1} with the administrator right' }
    $catalogue['kb.disabledCount'] = @{ ar = ' · {0} معطّل'; en = ' · {0} disabled' }
    $catalogue['kb.pageOf'] = @{ ar = ' · صفحة {0} من {1}'; en = ' · page {0} of {1}' }
    $catalogue['kb.minutesAgo'] = @{ ar = 'قبل {0} د'; en = '{0} min ago' }
    $catalogue['kb.hoursAgo'] = @{ ar = 'قبل {0} س'; en = '{0} h ago' }
    $catalogue['kb.lastAction'] = @{ ar = '   ⏺ آخر إجراء: {0}{1}'; en = '   ⏺ Last action: {0}{1}' }
    $catalogue['kb.deadChats'] = @{ ar = '💀 محادثات ميتة ({0})'; en = '💀 Dead chats ({0})' }
    $catalogue['kb.activityIsRough'] = @{ ar = "`n<i>حالة النشاط تقريبية حسب آخر تفاعل؛ Telegram لا يوفّر اتصالًا لحظيًا للبوت.</i>{0}"; en = "`n<i>The activity is a rough state, from the last exchange; Telegram gives a bot no live connection.</i>{0}" }
    $catalogue['kb.noExchangeFor'] = @{ ar = '😴 بلا تفاعل منذ {0} يومًا'; en = '😴 No exchange for {0} days' }
    $catalogue['kb.by'] = @{ ar = ' · بواسطة {0}'; en = ' · by {0}' }
    $catalogue['kb.addedOn'] = @{ ar = '📅 أُضيف {0}{1}'; en = '📅 Added {0}{1}' }
    $catalogue['kb.workingNamePrompt'] = @{ ar = "✏️ الاسم التشغيلي للمستخدم {0}`nالحالي: {1}`n`nأرسل الاسم الجديد، أو أرسل - لحذف الـAlias."; en = "✏️ The working name for user {0}`nCurrently: {1}`n`nSend the new name, or send - to remove the alias." }
    $catalogue['kb.aliasSet'] = @{ ar = 'تعيين اسم بديل ''{0}'''; en = 'an alias set to ''{0}''' }
    $catalogue['kb.userAudit'] = @{ ar = '👤 {0} للمستخدم {1} - بواسطة {2}'; en = '👤 {0} for user {1} - by {2}' }
    $catalogue['kb.noFavouritesYet'] = @{ ar = '<i>ℹ️ لم تختر شيئًا بعد، فتعرض القائمة أكثر {0} استخدامًا تلقائيًا.</i>'; en = '<i>ℹ️ You have chosen nothing yet, so the menu shows the {0} most used by itself.</i>' }
    $catalogue['kb.tooManyFavourites'] = @{ ar = '<i>⚠️ اخترت {0}، وتعرض القائمة أول {1} منها فقط.</i>'; en = '<i>⚠️ You chose {0}, and the menu shows only the first {1} of them.</i>' }
    $catalogue['kb.upcomingCount'] = @{ ar = '📅 الأحداث القادمة ({0})'; en = '📅 Upcoming events ({0})' }
    $catalogue['kb.page'] = @{ ar = 'صفحة {0} من {1}'; en = 'page {0} of {1}' }
    $catalogue['kb.upcomingCount2'] = @{ ar = '📋 الأحداث القادمة ({0})'; en = '📋 Upcoming events ({0})' }
    $catalogue['kb.checkAndCompare'] = @{ ar = '🔄 فحص ومقارنة · {0}'; en = '🔄 Check and compare · {0}' }
    $catalogue['kb.hide'] = @{ ar = '🙈 إخفاء {0}'; en = '🙈 Hide {0}' }
    $catalogue['kb.refreshHidden'] = @{ ar = '🔄 تحديث · {0} مخفية'; en = '🔄 Refresh · {0} hidden' }
    $catalogue['kb.pastRequestsDays'] = @{ ar = '📜 طلبات الوصول السابقة — آخر {0} يومًا'; en = '📜 Earlier access requests — the last {0} days' }
    $catalogue['kb.after'] = @{ ar = ' (بعد {0})'; en = ' (after {0})' }
    $catalogue['kb.askedAgo'] = @{ ar = 'طُلب منذ {0}'; en = 'asked {0} ago' }
    $catalogue['kb.pastRequestsDaysHtml'] = @{ ar = '<b>📜 طلبات الوصول السابقة</b> — آخر {0} يومًا'; en = '<b>📜 Earlier access requests</b> — the last {0} days' }
    $catalogue['kb.pendingRequestsCount'] = @{ ar = '👤 طلبات الوصول المعلّقة ({0})'; en = '👤 Pending access requests ({0})' }
    $catalogue['kb.requestCount'] = @{ ar = '<i>{0} طلبًا{1}</i>'; en = '<i>{0} requests{1}</i>' }
    $catalogue['kb.userChat'] = @{ ar = '   المستخدم <code>{0}</code> · المحادثة <code>{1}</code>'; en = '   User <code>{0}</code> · chat <code>{1}</code>' }
    $catalogue['kb.agoIndented'] = @{ ar = '   منذ {0}'; en = '   {0} ago' }
    $catalogue['kb.expiresAfter'] = @{ ar = ' · ينتهي تلقائيًا بعد {0}'; en = ' · it expires by itself after {0}' }
    $catalogue['kb.italicPair'] = @{ ar = '<i>{0}{1}</i>'; en = '<i>{0}{1}</i>' }
    $catalogue['kb.unblock'] = @{ ar = '♻️ رفع الحظر عن {0}'; en = '♻️ Unblock {0}' }
    $catalogue['kb.layers'] = @{ ar = 'طبقات: {0}'; en = 'Layers: {0}' }
    $catalogue['kb.namedLayers'] = @{ ar = '🏷️ {0} · {1} تسمية'; en = '🏷️ {0} · {1} named' }
    $catalogue['kb.quietUntil'] = @{ ar = '🔇 هدوء حتى {0} — إلغاء'; en = '🔇 Quiet until {0} — cancel' }
    $catalogue['kb.lastAired'] = @{ ar = '• <b>{0}</b> — آخر بث: {1}'; en = '• <b>{0}</b> — last on air: {1}' }
    $catalogue['kb.nameAndLayer'] = @{ ar = '{0} (طبقة {1})'; en = '{0} (layer {1})' }
    $catalogue['kb.templateBackupsCount'] = @{ ar = '🗄 نسخ القوالب ({0})'; en = '🗄 Template backups ({0})' }
    $catalogue['kb.invalidTemplatesCount'] = @{ ar = '🧹 قوالب غير صالحة ({0})'; en = '🧹 Invalid templates ({0})' }
    $catalogue['kb.countLayer'] = @{ ar = '{0} طبقة {1}'; en = '{0} layer {1}' }
    $catalogue['kb.backupCount'] = @{ ar = '<i>{0} نسخة · الأحدث أولًا</i>'; en = '<i>{0} backups · the newest first</i>' }
    $catalogue['kb.backupRow'] = @{ ar = '{0}. <code>{1}</code> · {2}'; en = '{0}. <code>{1}</code> · {2}' }
    $catalogue['kb.backupIs'] = @{ ar = 'النسخة: <code>{0}</code>'; en = 'The backup: <code>{0}</code>' }
    $catalogue['kb.andOthers'] = @{ ar = ' …و{0} غيرها'; en = ' …and {0} others' }
    $catalogue['kb.seconds'] = @{ ar = '{0} ث'; en = '{0} s' }
    $catalogue['kb.ceilingScreen'] = @{ ar = "⏱ {0}`nالحد الحالي: {1} ثانية (0 = بلا قاعدة خاصة).`nالمدى: 1–3600 ثانية. كل ضغطة تُحفظ. القالب الحسّاس يحتفظ بحدّه الأقصر."; en = "⏱ {0}`nThe ceiling now: {1} seconds (0 = no special rule).`nThe range: 1–3600 seconds. Every press is saved. A sensitive template keeps its shorter ceiling." }
    $catalogue['kb.currentShowShortened'] = @{ ar = '⚖️ قُصِّر بقاء العرض الحالي لقالب {0} إلى الحد المضبوط.'; en = '⚖️ The current show of {0} was shortened to the ceiling that is set.' }
    $catalogue['kb.defaultIs'] = @{ ar = '↩️ الافتراضي ({0})'; en = '↩️ The default ({0})' }
    $catalogue['kb.lowest'] = @{ ar = 'الأدنى ({0})'; en = 'the lowest ({0})' }
    $catalogue['kb.highest'] = @{ ar = 'الأعلى ({0})'; en = 'the highest ({0})' }
    $catalogue['kb.pickHour'] = @{ ar = "🕐 <b>{0}</b>`nالحالي: <code>{1}</code>`nاختر الساعة:"; en = "🕐 <b>{0}</b>`nCurrently: <code>{1}</code>`nChoose the hour:" }
    $catalogue['kb.pickMinute'] = @{ ar = "🕐 <b>{0}</b>`nالساعة {1} — اختر الدقيقة:"; en = "🕐 <b>{0}</b>`nHour {1} — choose the minute:" }
    $catalogue['kb.settingAudit'] = @{ ar = '⚙️ {0} = {1} - بواسطة {2}'; en = '⚙️ {0} = {1} - by {2}' }
    $catalogue['kb.range'] = @{ ar = ' · المدى: {0}–{1}'; en = ' · the range: {0}–{1}' }
    $catalogue['kb.value'] = @{ ar = 'القيمة: <b>{0}</b>{1}'; en = 'The value: <b>{0}</b>{1}' }
    $catalogue['kb.default'] = @{ ar = 'الافتراضي: {0}{1}'; en = 'The default: {0}{1}' }
    $catalogue['kb.chosen'] = @{ ar = '<i>المحدد ({0}): {1}</i>'; en = '<i>Chosen ({0}): {1}</i>' }
    $catalogue['kb.pageHtml'] = @{ ar = '<i>صفحة {0} من {1}</i>'; en = '<i>page {0} of {1}</i>' }
    $catalogue['kb.emptiedAudit'] = @{ ar = '⚙️ إفراغ {0} - بواسطة {1}'; en = '⚙️ {0} emptied - by {1}' }
    $catalogue['kb.chooseValueFor'] = @{ ar = 'اختر قيمة {0}:'; en = 'Choose a value for {0}:' }
    $catalogue['kb.sendNewsPath'] = @{ ar = "أرسل المسار المطلق لملف الأخبار بصيغة TXT.`nالحالي: {0}`nالافتراضي: {1}`nلن يتم إنشاء الملف أو تعديله في هذه الخطوة."; en = "Send the absolute path to the news file, as TXT.`nCurrently: {0}`nThe default: {1}`nThis step neither creates the file nor changes it." }
    $catalogue['kb.sendNewValue'] = @{ ar = 'أرسل القيمة الجديدة لـ {0} (الحالية: {1}، الافتراضية: {2}):'; en = 'Send the new value for {0} (currently: {1}, the default: {2}):' }
    $catalogue['mjz.rowsAnd'] = @{ ar = '{0} صفًّا · {1}'; en = '{0} rows · {1}' }
    $catalogue['mjz.runningRow'] = @{ ar = '▶️ يعمل الآن: الصف {0} من {1}'; en = '▶️ Running now: row {0} of {1}' }
    $catalogue['mjz.rowsAndHtml'] = @{ ar = '<i>{0} صفًّا · {1}</i>'; en = '<i>{0} rows · {1}</i>' }
    $catalogue['mjz.playRows'] = @{ ar = '▶️ تشغيل ({0} صفًّا)'; en = '▶️ Play ({0} rows)' }
    $catalogue['mjz.durationFrames'] = @{ ar = '⏱ المدة: {0} إطار'; en = '⏱ Duration: {0} frames' }
    $catalogue['mjz.firstPlus'] = @{ ar = '⏩ الأول: +{0} إطار'; en = '⏩ The first: +{0} frames' }
    $catalogue['mjz.lastFrames'] = @{ ar = '⏹ الأخير: {0} إطار'; en = '⏹ The last: {0} frames' }
    $catalogue['mjz.syncWithReveal'] = @{ ar = '🎬 مزامنة الظهور: {0}'; en = '🎬 Sync with the reveal: {0}' }
    $catalogue['mjz.makeItFrames'] = @{ ar = '⚡ اجعلها {0} إطارًا'; en = '⚡ Make it {0} frames' }
    $catalogue['mjz.preview'] = @{ ar = '<b>👁 معاينة «{0}»</b>'; en = '<b>👁 A look at "{0}"</b>' }
    $catalogue['mjz.templateNotInRegister'] = @{ ar = 'قالب ''{0}'' غير موجود في سجل القوالب.'; en = 'The template ''{0}'' is not in the template register.' }
    $catalogue['mjz.savedBulletins'] = @{ ar = '📑 الموجزات المحفوظة ({0})'; en = '📑 The bulletins kept ({0})' }
    $catalogue['mjz.slotCount'] = @{ ar = '🕒 {0} موعدًا'; en = '🕒 {0} slots' }
    $catalogue['mjz.bulletinCount'] = @{ ar = '<i>{0} موجزًا · كل تشغيل يستخدم آخر تحديث محفوظ</i>'; en = '<i>{0} bulletins · every run uses the last version kept</i>' }
    $catalogue['mjz.rowsRevision'] = @{ ar = '   {0} صف · المراجعة {1}'; en = '   {0} rows · revision {1}' }
    $catalogue['mjz.upcomingSlots'] = @{ ar = ' · {0} موعدًا قادمًا'; en = ' · {0} upcoming slots' }
    $catalogue['mjz.renamedAudit'] = @{ ar = '📑 إعادة تسمية موجز - بواسطة {0}'; en = '📑 A bulletin renamed - by {0}' }
    $catalogue['mjz.bulletinAudit'] = @{ ar = '📑 {0} موجز ''{1}'' - بواسطة {2}'; en = '📑 Bulletin ''{1}'' {0} - by {2}' }
    $catalogue['mjz.withSlots'] = @{ ar = ' ومعه {0} موعدًا'; en = ' along with {0} slots' }
    $catalogue['mjz.deletedAudit'] = @{ ar = '🗑 حذف موجز ''{0}''{1} - بواسطة {2}'; en = '🗑 Bulletin ''{0}'' deleted{1} - by {2}' }
    $catalogue['mjz.deleted'] = @{ ar = '🗑 حُذف «{0}»{1}.'; en = '🗑 "{0}" was deleted{1}.' }
    $catalogue['mjz.rowOf'] = @{ ar = '<b>✏️ الصف {0} من «{1}»</b>'; en = '<b>✏️ Row {0} of "{1}"</b>' }
    $catalogue['mjz.willShow'] = @{ ar = '<i>ما سيظهر: {0}</i>'; en = '<i>What will show: {0}</i>' }
    $catalogue['mjz.rowEditedAudit'] = @{ ar = '📑 تعديل صف في الموجز - بواسطة {0}'; en = '📑 A bulletin row edited - by {0}' }
    $catalogue['mjz.rowAddedAudit'] = @{ ar = '📑 أُضيف صف للموجز - بواسطة {0}'; en = '📑 A row added to the bulletin - by {0}' }
    $catalogue['mjz.pictureNotSaved'] = @{ ar = '❌ تعذّر حفظ الصورة: {0}'; en = '❌ Could not save the picture: {0}' }
    $catalogue['mjz.clearedAudit'] = @{ ar = '🧹 مسح جدول الموجز - بواسطة {0}'; en = '🧹 The bulletin board cleared - by {0}' }
    $catalogue['mjz.askRowFrames'] = @{ ar = "⏱ كم إطارًا يبقى كل صف على الهواء؟`nالحالي: {0} إطار ≈ {1} ث · المشهد {2} إطارًا في الثانية.{3}"; en = "⏱ How many frames does each row stay on air?`nCurrently: {0} frames ≈ {1} s · the scene runs at {2} frames a second.{3}" }
    $catalogue['mjz.askIntroFrames'] = @{ ar = "⏩ كم إطارًا يُضاف إلى الصف الأول وحده (حركة الدخول)؟`nالحالي: {0} إطار ≈ {1} ث · المشهد {2} إطارًا في الثانية.`nأرسل 0 لاتّباع القالب."; en = "⏩ How many frames are added to the first row alone (the entry)?`nCurrently: {0} frames ≈ {1} s · the scene runs at {2} frames a second.`nSend 0 to follow the template." }
    $catalogue['mjz.askLastFrames'] = @{ ar = "⏹ كم إطارًا يبقى الصف الأخير قبل أمر الخروج؟`nالحالي: {0} إطار ≈ {1} ث · المشهد {2} إطارًا في الثانية.`nأرسل 0 لاتّباع القالب."; en = "⏹ How many frames does the last row stay before the exit command?`nCurrently: {0} frames ≈ {1} s · the scene runs at {2} frames a second.`nSend 0 to follow the template." }
    $catalogue['mjz.waitingSlotPassed'] = @{ ar = '⏳ في الانتظار — موعده {0} مرّ وموجز آخر على الهواء.'; en = '⏳ Waiting — its slot at {0} has passed and another bulletin is on air.' }
    $catalogue['mjz.startsAt'] = @{ ar = '🕒 يبدأ {0} — بعد {1}'; en = '🕒 Starts {0} — in {1}' }
    $catalogue['mjz.slotCancelledAudit'] = @{ ar = '🚫 إلغاء موعد موجز - بواسطة {0}'; en = '🚫 A bulletin slot cancelled - by {0}' }
    $catalogue['mjz.whenStart'] = @{ ar = "🕒 متى يبدأ «{0}»؟`nاختر من الأزرار، أو اكتب: +30 · بعد 90 · 21:45 · غدًا 07:00"; en = "🕒 When should `"{0}`" start?`nPick a button, or type: +30 · بعد 90 · 21:45 · غدًا 07:00" }
    $catalogue['mjz.slotAudit'] = @{ ar = '🕒 موعد موجز {0} - بواسطة {1}'; en = '🕒 A bulletin slot {0} - by {1}' }
    $catalogue['mjz.startsIn'] = @{ ar = '🔔 «{0}» يبدأ بعد {1} — {2}.'; en = '🔔 "{0}" starts in {1} — {2}.' }
    $catalogue['mjz.stillOnAir'] = @{ ar = '«{0}» ما زال على الهواء'; en = '"{0}" is still on air' }
    $catalogue['mjz.heldBecause'] = @{ ar = '⏳ تأخّر «{0}» لأن {1}. سيبدأ بعد انتهائه.'; en = '⏳ "{0}" was held because {1}. It starts once that has ended.' }
}
