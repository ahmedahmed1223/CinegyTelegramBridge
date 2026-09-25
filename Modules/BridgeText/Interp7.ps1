#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the news ticker with its lock, its handover and the
    sheet it can be pulled from, and the four reports in all three of their
    renderings: the screen, the message and the page that downloads.
#>

function Add-BridgeTextInterp7 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['news.lockedBy'] = @{ ar = 'المسودة مقفلة حاليًا لدى {0}.'; en = 'The draft is locked right now by {0}.' }
    $catalogue['news.lockHeldFor'] = @{ ar = 'القفل محجوز لـ {0} لمدة {1} بعد تسليم القفل له.'; en = 'The lock is held for {0} for {1} after it was handed over.' }
    $catalogue['news.adoptedOpenDraft'] = @{ ar = '🤝 تبنّى {0} مسودة شريط الأخبار المفتوحة ({1})'; en = '🤝 {0} took over the open news ticker draft ({1})' }
    $catalogue['news.resumeFailed'] = @{ ar = '❌ تعذّر الاستئناف: {0}'; en = '❌ Could not resume: {0}' }
    $catalogue['news.resumedExpiredAudit'] = @{ ar = '↩️ استئناف مسودة أخبار منتهية ({0} خبرًا) - بواسطة {1}'; en = '↩️ An expired news draft resumed ({0} headlines) - by {1}' }
    $catalogue['news.sheetRefusedWrite'] = @{ ar = 'رفض الشيت الكتابة: {0}'; en = 'The sheet refused the write: {0}' }
    $catalogue['news.publishedAudit'] = @{ ar = '📰 نشر شريط الأخبار بواسطة {0}: {1} خبرًا'; en = '📰 The news ticker published by {0}: {1} headlines' }
    $catalogue['news.publishedByHand'] = @{ ar = '📰 نُشر شريط الأخبار يدويًا بواسطة {0}: {1} خبرًا.'; en = '📰 The news ticker was published by hand by {0}: {1} headlines.' }
    $catalogue['news.unlockPending'] = @{ ar = '⏳ يوجد طلب فكّ قفل قيد الانتظار من {0}. انتظر نتيجته.'; en = '⏳ There is an unlock request waiting from {0}. Wait for its answer.' }
    $catalogue['news.unlockRequestAudit'] = @{ ar = '🔓 طلب فكّ قفل شريط الأخبار من {0} بواسطة {1}'; en = '🔓 An unlock request for the news ticker from {0} by {1}' }
    $catalogue['news.unlockAsk'] = @{ ar = "🔓 يطلب {0} تحرير شريط الأخبار.`nلديك {1} للرد؛ بلا رد سيُمنح تلقائيًا وستُلغى مسودتك (سنرسل لك نصّها)."; en = "🔓 {0} is asking to edit the news ticker.`nYou have {1} to answer; with no answer it is granted by itself and your draft is dropped (we will send you its text)." }
    $catalogue['news.requestSent'] = @{ ar = '⏳ أُرسل الطلب إلى {0}. إن لم يردّ خلال {1} سيُمنح لك تلقائيًا.{2}'; en = '⏳ The request went to {0}. If they do not answer within {1} it is granted to you by itself.{2}' }
    $catalogue['news.handoverRefused'] = @{ ar = '⛔ رفض {0} تسليم القفل؛ ما زال يعمل على المسودة.'; en = '⛔ {0} refused to hand the lock over; they are still working on the draft.' }
    $catalogue['news.yourDraftText'] = @{ ar = "📄 نصّ مسودتك قبل تسليم القفل ({0} خبرًا):`n{1}"; en = "📄 The text of your draft before the lock went over ({0} headlines):`n{1}" }
    $catalogue['news.lockHandedAudit'] = @{ ar = '🔓 سُلّم قفل شريط الأخبار إلى {0} ({1})'; en = '🔓 The news ticker lock was handed to {0} ({1})' }
    $catalogue['news.lockYoursFor'] = @{ ar = ' القفل محجوز لك وحدك لمدة {0}.'; en = ' The lock is yours alone for {0}.' }
    $catalogue['news.youMayEdit'] = @{ ar = '🔓 صار بإمكانك التحرير. اضغط ✏️ بدء التحرير للعمل على النص الحالي.{0}'; en = '🔓 You may edit now. Press ✏️ Start editing to work on the current text.{0}' }
    $catalogue['news.unlockSettledAudit'] = @{ ar = '🔓 سُوّي طلب فكّ قفل شريط الأخبار لصالح {0} بعد تسليم المالك طوعًا'; en = '🔓 The news ticker unlock request was settled in favour of {0} after the holder gave it up willingly' }
    $catalogue['news.draftOpenedAudit'] = @{ ar = '🤝 فتح {0} مسودة شريط الأخبار للجميع ({1})'; en = '🤝 {0} opened the news ticker draft to everyone ({1})' }
    $catalogue['news.draftOpened'] = @{ ar = '🤝 فتح {0} المسودة للتحرير بما فيها. اضغط ✏️ لمتابعة نفس القائمة.'; en = '🤝 {0} opened the draft for editing as it stands. Press ✏️ to carry on with the same list.' }
    $catalogue['news.willReplace'] = @{ ar = 'سيستبدل {0} خبرًا على الشريط الآن.'; en = 'It replaces the {0} headlines on the ticker now.' }
    $catalogue['news.openDraftWillBeReplaced'] = @{ ar = '🤝 توجد مسودة مفتوحة للجميع ({0})، وسيُستبدل محتواها.'; en = '🤝 There is a draft open to everyone ({0}), and its content will be replaced.' }
    $catalogue['news.draftHeldWillBeReplaced'] = @{ ar = '🔒 المسودة الحالية بيد {0}، وسيُستبدل محتواها.'; en = '🔒 The current draft is with {0}, and its content will be replaced.' }
    $catalogue['news.pullNeedsLock'] = @{ ar = 'المسودة بيد {0}؛ السحب من الشيت لمن يحمل القفل وحده.'; en = 'The draft is with {0}; pulling from the sheet is for whoever holds the lock alone.' }
    $catalogue['news.sheetTooBig'] = @{ ar = 'حجم الشيت يتجاوز الحد المسموح ({0} بايت).'; en = 'The sheet is larger than the limit allows ({0} bytes).' }
    $catalogue['news.byHandBy'] = @{ ar = 'يدويًا بواسطة {0}'; en = 'by hand, by {0}' }
    $catalogue['news.updatedFromSheetAudit'] = @{ ar = '📰 حُدِّث الشريط من الشيت {0}'; en = '📰 The ticker was updated from the sheet {0}' }
    $catalogue['news.nowOnAir'] = @{ ar = 'الآن على الهواء: {0} خبرًا'; en = 'On air now: {0} headlines' }
    $catalogue['news.new'] = @{ ar = 'جديد: {0}'; en = 'New: {0}' }
    $catalogue['news.removed'] = @{ ar = 'أُزيل: {0}'; en = 'Removed: {0}' }
    $catalogue['news.sheetNotUpdated'] = @{ ar = '⚠️ لكن تعذّر تحديث الشيت: {0}'; en = '⚠️ But the sheet could not be updated: {0}' }
    $catalogue['news.draftHeldUseUnlock'] = @{ ar = 'المسودة بيد {0}. استخدم «🔓 طلب فكّ القفل» أو اطلب من مشرف.'; en = 'The draft is with {0}. Use "🔓 Ask to unlock", or ask an administrator.' }
    $catalogue['news.draftHeldConfirmReplaces'] = @{ ar = 'المسودة بيد {0}. التأكيد يستبدلها بمحتوى الشيت.'; en = 'The draft is with {0}. Confirming replaces it with what the sheet holds.' }
    $catalogue['news.sheetDownloadFailed'] = @{ ar = 'تعذّر تنزيل الشيت: {0}'; en = 'The sheet could not be downloaded: {0}' }
    $catalogue['news.sheetLoadFailed'] = @{ ar = 'تعذّر تحميل الشيت في المسودة: {0}'; en = 'The sheet could not be loaded into the draft: {0}' }
    $catalogue['news.sheetPublishFailed'] = @{ ar = 'تعذّر نشر الشيت: {0}'; en = 'The sheet could not be published: {0}' }
    $catalogue['news.publishedFromSheetAudit'] = @{ ar = '📰 نشر شريط الأخبار من الشيت ({0}): {1} خبرًا'; en = '📰 The news ticker published from the sheet ({0}): {1} headlines' }
    $catalogue['news.heldFor'] = @{ ar = '⏳ محجوز لـ {0}'; en = '⏳ Held for {0}' }
    $catalogue['news.carryOnDraft'] = @{ ar = '✏️ تابِع المسودة ({0})'; en = '✏️ Carry on with the draft ({0})' }
    $catalogue['news.with'] = @{ ar = '🔒 لدى {0}'; en = '🔒 With {0}' }
    $catalogue['news.confirmDelete'] = @{ ar = "🗑 تأكيد حذف الخبر {0} من {1}:`n`n{2}"; en = "🗑 Delete headline {0} of {1}:`n`n{2}" }
    $catalogue['news.headlineOf'] = @{ ar = "📰 الخبر {0} من {1}:`n`n{2}"; en = "📰 Headline {0} of {1}:`n`n{2}" }
    $catalogue['news.page'] = @{ ar = 'صفحة {0}/{1}'; en = 'page {0}/{1}' }
    $catalogue['news.headlines'] = @{ ar = 'الأخبار: <b>{0}</b>'; en = 'The headlines: <b>{0}</b>' }
    $catalogue['news.showing'] = @{ ar = 'المعروض: {0}–{1}  ·  صفحة {2} من {3}'; en = 'Showing: {0}–{1}  ·  page {2} of {3}' }
    $catalogue['news.longListLimit'] = @{ ar = 'القائمة الطويلة مفعّلة، لكن تيليجرام لا يقبل أكثر من {0} خبرًا في شاشة واحدة.'; en = 'The long list is on, but Telegram takes no more than {0} headlines on one screen.' }
    $catalogue['news.draftOrder'] = @{ ar = '📝 ترتيب المسودة — {0} خبرًا'; en = '📝 The draft order — {0} headlines' }
    $catalogue['news.showing2'] = @{ ar = 'المعروض: {0}–{1} · صفحة {2} من {3}'; en = 'Showing: {0}–{1} · page {2} of {3}' }
    $catalogue['news.onAirNowCount'] = @{ ar = '🔴 على الهواء الآن: {0} خبرًا · +{1} −{2}'; en = '🔴 On air now: {0} headlines · +{1} −{2}' }
    $catalogue['news.draftVsAir'] = @{ ar = 'المسودة {0} خبرًا · على الهواء {1} — سيُضاف {2} ويُحذف {3}'; en = 'The draft has {0} headlines · on air {1} — {2} will be added and {3} removed' }
    $catalogue['news.noChange'] = @{ ar = 'بلا تغيير ({0})'; en = 'no change ({0})' }
    $catalogue['news.backupCount'] = @{ ar = '<i>{0} نسخة · الأحدث أولًا</i>'; en = '<i>{0} backups · the newest first</i>' }
    $catalogue['news.headlineCount'] = @{ ar = ' · {0} خبرًا'; en = ' · {0} headlines' }
    $catalogue['news.indented'] = @{ ar = '   {0}'; en = '   {0}' }
    $catalogue['news.manage'] = @{ ar = "📰 إدارة شريط الأخبار`nالحالي: {0} على الهواء."; en = "📰 Manage the news ticker`nCurrently: {0} on air." }
    $catalogue['news.draftHeading'] = @{ ar = "`n`n✏️ مسودتك: {0} خبر، منها {1} 🆕 جديد"; en = "`n`n✏️ Your draft: {0} headline(s), {1} of them 🆕 new" }
    $catalogue['news.draftRemoves'] = @{ ar = '🗑 ونشرها يحذف من الهواء: {0}'; en = '🗑 Publishing it drops from air: {0}' }
    $catalogue['news.andMore'] = @{ ar = "`n… و{0} آخر"; en = "`n… and {0} more" }
    $catalogue['news.tickerEmpty'] = @{ ar = "{0}`nالشريط فارغ."; en = "{0}`nThe ticker is empty." }
    $catalogue['news.fileUnreadable'] = @{ ar = '⚠️ تعذر قراءة ملف الأخبار: {0}'; en = '⚠️ The news file could not be read: {0}' }
    $catalogue['news.handedOverBy'] = @{ ar = ' سلّمها {0}'; en = ' handed over by {0}' }
    $catalogue['news.openDraftLine'] = @{ ar = "`n🤝 مسودة مفتوحة للجميع{0} وفيها {1} خبرًا — اضغط ✏️ لمتابعتها."; en = "`n🤝 A draft open to everyone{0} holding {1} headlines — press ✏️ to carry on with it." }
    $catalogue['news.lockedDraftLine'] = @{ ar = "`nالمسودة مقفلة لدى {0} وتحتوي {1} خبرًا."; en = "`nThe draft is locked with {0} and holds {1} headlines." }
    $catalogue['news.added'] = @{ ar = '✅ أضيف الخبر {0} - في المسودة فقط.'; en = '✅ Headline {0} was added - to the draft only.' }
    $catalogue['news.imported'] = @{ ar = '✅ استورد {0} خبرًا إلى المسودة فقط. راجعها قبل النشر.'; en = '✅ {0} headlines were imported to the draft only. Look them over before publishing.' }
    $catalogue['news.importFailed'] = @{ ar = '❌ فشل الاستيراد: {0}'; en = '❌ The import failed: {0}' }
    $catalogue['rep.day'] = @{ ar = 'يوم {0}'; en = '{0}' }
    $catalogue['rep.hours'] = @{ ar = '{0} ساعة'; en = '{0} hours' }
    $catalogue['rep.last'] = @{ ar = 'آخر {0}'; en = 'the last {0}' }
    $catalogue['rep.filterTitle'] = @{ ar = '<b>🔎 تصفية سجل العمليات</b> — {0}'; en = '<b>🔎 Filter the operation log</b> — {0}' }
    $catalogue['rep.hiddenOperators'] = @{ ar = '<i>وأُخفي {0} مشغّلًا أقل نشاطًا.</i>'; en = '<i>and {0} less busy operators are hidden.</i>' }
    $catalogue['rep.hiddenTemplates'] = @{ ar = '<i>وأُخفي {0} قالبًا أقل نشاطًا.</i>'; en = '<i>and {0} less used templates are hidden.</i>' }
    $catalogue['rep.logTitle'] = @{ ar = '🧾 سجل العمليات — {0} · {1}'; en = '🧾 The operation log — {0} · {1}' }
    $catalogue['rep.allPassed'] = @{ ar = '🟢 {0}، كلّها ناجحة'; en = '🟢 {0}, every one of them passed' }
    $catalogue['rep.layerShort'] = @{ ar = ' · ط{0}'; en = ' · L{0}' }
    $catalogue['rep.readLimitCount'] = @{ ar = '⚠️ بلغ السجل حدّ القراءة ({0} سجلًّا)؛ قد تكون هناك عمليات أقدم داخل المدة.'; en = '⚠️ The log hit its read limit ({0} records); there may be older operations inside the period.' }
    $catalogue['rep.logTitleHtml'] = @{ ar = '<b>🧾 سجل العمليات</b> — {0} · {1}'; en = '<b>🧾 The operation log</b> — {0} · {1}' }
    $catalogue['rep.totals'] = @{ ar = '📊 <b>الإجمالي</b> — {0} · ✅ {1} · ❌ {2} · ⛔ {3}'; en = '📊 <b>In all</b> — {0} · ✅ {1} · ❌ {2} · ⛔ {3}' }
    $catalogue['rep.lastDuration'] = @{ ar = '⏱ آخر {0}'; en = '⏱ the last {0}' }
    $catalogue['rep.yesterdayOn'] = @{ ar = '📆 يوم أمس ({0})'; en = '📆 Yesterday ({0})' }
    $catalogue['rep.screen'] = @{ ar = "📊 التقارير`n━━━━━━━━━━━━━━`nالنطاق: {0}`n`n🖼 البنرات — ماذا ظهر، بأي نص، ومتى اختفى`n📰 الأخبار — تعديلات الشريط اليومي وحجم كل تعديل`n📑 الموجزات — أي نشرة شُغّلت، بكم صفًّا، ومن شغّلها`n👥 تقرير العمل — حصيلة كل مشغّل من عمليات الهواء"; en = "📊 Reports`n━━━━━━━━━━━━━━`nThe range: {0}`n`n🖼 Banners — what appeared, with what text, and when it went`n📰 News — the daily ticker edits and the size of each one`n📑 Bulletins — which bulletin ran, with how many rows, and who ran it`n👥 Work report — what each operator did on air" }
    $catalogue['rep.refusedCount'] = @{ ar = '🚫 {0} مرفوضة'; en = '🚫 {0} refused' }
    $catalogue['rep.failedCount'] = @{ ar = '⚠️ {0} فاشلة'; en = '⚠️ {0} failed' }
    $catalogue['rep.onAirCount'] = @{ ar = '🔴 {0} على الهواء'; en = '🔴 {0} on air' }
    $catalogue['rep.most'] = @{ ar = 'الأكثر: {0}'; en = 'Most: {0}' }
    $catalogue['rep.lastActivityAt'] = @{ ar = 'آخر نشاط {0}'; en = 'last activity {0}' }
    $catalogue['rep.workTitleHtml'] = @{ ar = '<b>👥 تقرير العمل</b> — {0}'; en = '<b>👥 The work report</b> — {0}' }
    $catalogue['rep.workTotals'] = @{ ar = '🎬 <b>الإجمالي</b> — {0} · 🔴 {1} على الهواء · ✅ {2}{3}'; en = '🎬 <b>In all</b> — {0} · 🔴 {1} on air · ✅ {2}{3}' }
    $catalogue['rep.operatorsHtml'] = @{ ar = '👥 <b>المشغّلون</b> — {0}'; en = '👥 <b>The operators</b> — {0}' }
    $catalogue['rep.operatorRow'] = @{ ar = '👤 <b>{0}</b> — {1} · ✅ {2}{3}'; en = '👤 <b>{0}</b> — {1} · ✅ {2}{3}' }
    $catalogue['rep.workTitle'] = @{ ar = '👥 تقرير العمل — {0}'; en = '👥 The work report — {0}' }
    $catalogue['rep.bulletinTitle'] = @{ ar = '📑 تقرير الموجزات — {0}'; en = '📑 The bulletin report — {0}' }
    $catalogue['rep.triple'] = @{ ar = '{0}{1} · {2}'; en = '{0}{1} · {2}' }
    $catalogue['rep.totalTriple'] = @{ ar = 'الإجمالي: {0} · {1} · {2}'; en = 'In all: {0} · {1} · {2}' }
    $catalogue['rep.byScheduleCount'] = @{ ar = ' · {0} بالجدولة 🕒'; en = ' · {0} by schedule 🕒' }
    $catalogue['rep.newestOnly'] = @{ ar = '⚠️ عُرض أحدث {0} فقط؛ اختر مدة أقصر لتقرير كامل.'; en = '⚠️ Only the newest {0} are shown; choose a shorter period for a full report.' }
    $catalogue['rep.bulletinTitleHtml'] = @{ ar = '<b>📑 تقرير الموجزات</b> — {0}'; en = '<b>📑 The bulletin report</b> — {0}' }
    $catalogue['rep.totalsPair'] = @{ ar = '📊 <b>الإجمالي</b> — {0} · {1}'; en = '📊 <b>In all</b> — {0} · {1}' }
    $catalogue['rep.bulletinRow'] = @{ ar = '{0} {1} · <b>{2}</b> · {3} · {4}'; en = '{0} {1} · <b>{2}</b> · {3} · {4}' }
    $catalogue['rep.operatorIndented'] = @{ ar = '     المشغّل: {0}'; en = '     Operator: {0}' }
    $catalogue['rep.newestRecordsOnly'] = @{ ar = '<i>⚠️ عُرض أحدث {0} سجل فقط.</i>'; en = '<i>⚠️ Only the newest {0} records are shown.</i>' }
    $catalogue['rep.newsTitle'] = @{ ar = '📰 تقرير الأخبار — {0}'; en = '📰 The news report — {0}' }
    $catalogue['rep.newsTotals'] = @{ ar = 'الإجمالي: {0} تعديلًا · على الهواء {1} خبرًا'; en = 'In all: {0} edits · on air {1} headlines' }
    $catalogue['rep.newestRecordsOnlyPlain'] = @{ ar = '⚠️ عُرض أحدث {0} سجل فقط؛ اختر مدة أقصر لتقرير كامل.'; en = '⚠️ Only the newest {0} records are shown; choose a shorter period for a full report.' }
    $catalogue['rep.lastBulletin'] = @{ ar = '🕒 آخر نشرة: {0} — منذ {1}'; en = '🕒 The last bulletin: {0} — {1} ago' }
    $catalogue['rep.daysWithout'] = @{ ar = '🔇 أيام بلا نشرة: {0}'; en = '🔇 Days with no bulletin: {0}' }
    $catalogue['rep.newsTitleHtml'] = @{ ar = '<b>📰 تقرير الأخبار</b> — {0}'; en = '<b>📰 The news report</b> — {0}' }
    $catalogue['rep.newsTotalsHtml'] = @{ ar = '📊 <b>الإجمالي</b> — {0} تعديلًا · على الهواء {1} خبرًا'; en = '📊 <b>In all</b> — {0} edits · on air {1} headlines' }
    $catalogue['rep.newsDayRow'] = @{ ar = '📆 <b>{0}</b> — {1} تعديلًا · على الهواء {2} · {3}'; en = '📆 <b>{0}</b> — {1} edits · on air {2} · {3}' }
    $catalogue['rep.newestRecordsOnlyHtml'] = @{ ar = '<i>⚠️ عُرض أحدث {0} سجل فقط؛ اختر مدة أقصر لتقرير كامل.</i>'; en = '<i>⚠️ Only the newest {0} records are shown; choose a shorter period for a full report.</i>' }
    $catalogue['rep.bannerTitle'] = @{ ar = '🖼 تقرير البنرات — {0}'; en = '🖼 The banner report — {0}' }
    $catalogue['rep.newestBanners'] = @{ ar = 'أحدث {0} من {1} بنرًا — اختر مدة أقصر لرؤية البقية في جدول.'; en = 'The newest {0} of {1} banners — choose a shorter period to see the rest in a table.' }
    $catalogue['rep.nameLayer'] = @{ ar = '{0} · ط{1}'; en = '{0} · L{1}' }
    $catalogue['rep.bannerTotals'] = @{ ar = 'الإجمالي: {0} بنرًا · {1} مشغّلين'; en = 'In all: {0} banners · {1} operators' }
    $catalogue['rep.bannerTexts'] = @{ ar = '📝 نصوص البنرات ({0})'; en = '📝 The banner texts ({0})' }
    $catalogue['rep.bannerTitleHtml'] = @{ ar = '<b>🖼 تقرير البنرات</b> — {0}'; en = '<b>🖼 The banner report</b> — {0}' }
    $catalogue['rep.bannerTotalsHtml'] = @{ ar = '📊 <b>الإجمالي</b> — {0} بنرًا · {1} مشغّلين'; en = '📊 <b>In all</b> — {0} banners · {1} operators' }
    $catalogue['rep.stillOnAirArrow'] = @{ ar = '{0} ← ما زال على الهواء'; en = '{0} ← still on air' }
    $catalogue['rep.textOnLayer'] = @{ ar = '     «<b>{0}</b>» على الطبقة {1}'; en = '     "<b>{0}</b>" on layer {1}' }
    $catalogue['rep.newestRecordsOnlyBare'] = @{ ar = 'عُرض أحدث {0} سجل فقط؛ اختر مدة أقصر للحصول على تقرير كامل.'; en = 'Only the newest {0} records are shown; choose a shorter period for a full report.' }
    $catalogue['rep.page'] = @{ ar = "{0}<title>{1}</title>`n</head>`n<body>`n<div class=`"sheet`">`n<h1>{2}</h1>`n<p class=`"meta`">أُنشئ في {3} · جسر Cinegy Telegram {4}</p>`n{5}`n{6}`n</div>`n</body>`n</html>"; en = "{0}<title>{1}</title>`n</head>`n<body>`n<div class=`"sheet`">`n<h1>{2}</h1>`n<p class=`"meta`">Made at {3} · Cinegy Telegram Bridge {4}</p>`n{5}`n{6}`n</div>`n</body>`n</html>" }
    $catalogue['rep.layerHtml'] = @{ ar = '&raquo; &middot; الطبقة {0}'; en = '&raquo; &middot; layer {0}' }
    $catalogue['rep.bannerTotalsPage'] = @{ ar = 'الإجمالي: {0} بنرًا &middot; {1} مشغّلين'; en = 'In all: {0} banners &middot; {1} operators' }
    $catalogue['rep.bannerPageTitle'] = @{ ar = 'تقرير البنرات — {0}'; en = 'The banner report — {0}' }
    $catalogue['rep.rowsHtml'] = @{ ar = '&raquo; &middot; {0} صفًّا'; en = '&raquo; &middot; {0} rows' }
    $catalogue['rep.bulletinTotalsPage'] = @{ ar = 'الإجمالي: {0} تشغيلًا &middot; {1} صفًّا &middot; {2} مشغّلين'; en = 'In all: {0} runs &middot; {1} rows &middot; {2} operators' }
    $catalogue['rep.bulletinPageTitle'] = @{ ar = 'تقرير الموجزات — {0}'; en = 'The bulletin report — {0}' }
    $catalogue['rep.newsDayPage'] = @{ ar = '{0} — {1} تعديلًا &middot; على الهواء {2} &middot; {3}'; en = '{0} — {1} edits &middot; on air {2} &middot; {3}' }
    $catalogue['rep.newsTotalsPage'] = @{ ar = 'الإجمالي: {0} تعديلًا &middot; على الهواء {1} خبرًا'; en = 'In all: {0} edits &middot; on air {1} headlines' }
    $catalogue['rep.newsPageTitle'] = @{ ar = 'تقرير الأخبار — {0}'; en = 'The news report — {0}' }
    $catalogue['rep.openInBrowser'] = @{ ar = '{0} — افتحه في المتصفح، ويمكنك طباعته PDF من هناك.'; en = '{0} — open it in a browser, and you can print it to PDF from there.' }
    $catalogue['news.yourRequestPending'] = @{ ar = '⏳ طلبك قيد الانتظار بالفعل. متبقٍّ {0} قبل المنح التلقائي.'; en = '⏳ Your request is already waiting. {0} left before it is granted by itself.' }
    $catalogue['news.ago'] = @{ ar = 'منذ {0}'; en = '{0} ago' }
}
