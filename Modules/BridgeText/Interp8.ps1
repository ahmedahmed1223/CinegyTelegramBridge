#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the ticking clock — the hide timers, the alert that
    follows up when nobody answered, the operating numbers, what-you-missed
    and the health watch — and the urgent board with its gap, its rounds and
    the ceiling a scene puts on both.
#>

function Add-BridgeTextInterp8 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['tick.template'] = @{ ar = 'قالب {0}'; en = 'template {0}' }
    $catalogue['tick.layerNotOnAir'] = @{ ar = 'الطبقة {0} لم تعد مسجلة على الهواء.'; en = 'Layer {0} is no longer recorded on air.' }
    $catalogue['tick.layerChanged'] = @{ ar = 'الطبقة {0} تغيّرت منذ ضبط المؤقت.'; en = 'Layer {0} changed since the timer was set.' }
    $catalogue['tick.templateChanged'] = @{ ar = 'القالب على الطبقة {0} تغيّر منذ ضبط المؤقت.'; en = 'The template on layer {0} changed since the timer was set.' }
    $catalogue['tick.layerUnverifiable'] = @{ ar = 'تعذّر التحقق من حالة Cinegy للطبقة {0}.'; en = 'The Cinegy state of layer {0} could not be checked.' }
    $catalogue['tick.layerGone'] = @{ ar = 'الطبقة {0} لم تعد على الهواء.'; en = 'Layer {0} is no longer on air.' }
    $catalogue['tick.extendedOnce'] = @{ ar = '⏱ تم التمديد مرة واحدة؛ الإخفاء عند {0}.'; en = '⏱ It was extended once; it hides at {0}.' }
    $catalogue['tick.reachedCeiling'] = @{ ar = "⏱ بلغ القالب {0} حدّه على الهواء.`nتمديد واحد فقط. إذا لم تؤكّد قبل {1} فسيُخفى تلقائيًا."; en = "⏱ The template {0} has reached its ceiling on air.`nOne extension only. If you do not confirm before {1} it hides by itself." }
    $catalogue['tick.chosenDuration'] = @{ ar = "`nالمدة المختارة: {0} ثانية. تعديلها لا يمدّد مهلة الرد."; en = "`nThe duration chosen: {0} seconds. Changing it does not lengthen the time you have to answer." }
    $catalogue['tick.seconds'] = @{ ar = '{0} ثانية'; en = '{0} seconds' }
    $catalogue['tick.autoHidden'] = @{ ar = '⏱ تم الإخفاء التلقائي للطبقة {0}.'; en = '⏱ Layer {0} was hidden by itself.' }
    $catalogue['tick.hideUnconfirmed'] = @{ ar = '⚠️ تعذّر تأكيد الإخفاء للطبقة {0}. ستتكرر المحاولة؛ تحقّق من الهواء.'; en = '⚠️ The hide on layer {0} could not be confirmed. It will be tried again; look at the air.' }
    $catalogue['tick.followUp'] = @{ ar = '🔔 متابعة: لم يتم تأكيد معالجة تنبيه ''{0}'' على الطبقة {1}، وما زال ظاهرًا.'; en = '🔔 A follow-up: nobody confirmed dealing with the alert on ''{0}'', layer {1}, and it is still showing.' }
    $catalogue['tick.remaining'] = @{ ar = "`n⏱ يتبقى {0}"; en = "`n⏱ {0} left" }
    $catalogue['tick.stillShowing'] = @{ ar = '⏰ تنبيه: مرّ {0} منذ إظهار ''{1}'' على الطبقة {2}، وما زال ظاهرًا.{3}'; en = '⏰ An alert: {0} has passed since ''{1}'' went on layer {2}, and it is still showing.{3}' }
    $catalogue['tick.theText'] = @{ ar = "`n📝 النص: {0}"; en = "`n📝 The text: {0}" }
    $catalogue['tick.heartbeat'] = @{ ar = '💚 الجسر يعمل. القوالب: {0}، البث: {1}'; en = '💚 The bridge is running. Templates: {0}, the feed: {1}' }
    $catalogue['tick.dhm'] = @{ ar = '{0} ي {1} س {2} د'; en = '{0} d {1} h {2} min' }
    $catalogue['tick.percentOfLimit'] = @{ ar = '{0}% من الحدّ · {1}'; en = '{0}% of the limit · {1}' }
    $catalogue['tick.numbers'] = @{ ar = '📈 أرقام التشغيل — v{0}'; en = '📈 The operating numbers — v{0}' }
    $catalogue['tick.localTime'] = @{ ar = '🕒 {0} (محلي)'; en = '🕒 {0} (local)' }
    $catalogue['tick.biggestScreen'] = @{ ar = "`n📐 أكبر شاشة أُرسلت — {0}% من الحدّ · {1}"; en = "`n📐 The biggest screen sent — {0}% of the limit · {1}" }
    $catalogue['tick.numbersHtml'] = @{ ar = '<b>📈 أرقام التشغيل</b> — <code>v{0}</code>'; en = '<b>📈 The operating numbers</b> — <code>v{0}</code>' }
    $catalogue['tick.localTimeHtml'] = @{ ar = '🕒 <code>{0}</code> (محلي)'; en = '🕒 <code>{0}</code> (local)' }
    $catalogue['tick.uptime'] = @{ ar = '⏱ <b>مدة التشغيل</b> — {0} ي {1} س {2} د'; en = '⏱ <b>Running for</b> — {0} d {1} h {2} min' }
    $catalogue['tick.since'] = @{ ar = '📅 <b>منذ</b> — {0}'; en = '📅 <b>Since</b> — {0}' }
    $catalogue['tick.airOps'] = @{ ar = '🎬 <b>عمليات الهواء</b> — {0} · ✅ {1} · ❌ {2} · ⛔ {3}'; en = '🎬 <b>Air operations</b> — {0} · ✅ {1} · ❌ {2} · ⛔ {3}' }
    $catalogue['tick.countersBlock'] = @{ ar = "<blockquote>🚦 حدّ تيليجرام (429) — {0}
`n📭 رسائل أُسقطت من الطابور — {1}
`n📡 اتصال Telegram — {2}
`n🎛 صحة Cinegy — {3}
`n💚 آخر نبضة يومية — {4}
`n🔴 مشاهد على الهواء — {5}{6}</blockquote>"; en = "<blockquote>🚦 The Telegram limit (429) — {0}
`n📭 Messages dropped from the queue — {1}
`n📡 The Telegram connection — {2}
`n🎛 Cinegy health — {3}
`n💚 The last daily heartbeat — {4}
`n🔴 Scenes on air — {5}{6}</blockquote>" }
    $catalogue['tick.airState'] = @{ ar = 'حالة الهواء — {0}'; en = 'the state of the air — {0}' }
    $catalogue['tick.agoParen'] = @{ ar = ' (منذ {0})'; en = ' ({0} ago)' }
    $catalogue['tick.layerRow'] = @{ ar = '- طبقة {0}: {1}{2}'; en = '- layer {0}: {1}{2}' }
    $catalogue['tick.missed'] = @{ ar = '🕘 ماذا فاتني — آخر {0} ساعة'; en = '🕘 What I missed — the last {0} hours' }
    $catalogue['tick.onAir'] = @{ ar = '🔴 على الهواء: {0}'; en = '🔴 On air: {0}' }
    $catalogue['tick.whatShowed'] = @{ ar = '📺 ما عُرض — {0}'; en = '📺 What went on — {0}' }
    $catalogue['tick.hidesAndExits'] = @{ ar = '🙈 إخفاء وخروج: {0} — آخرها {1}'; en = '🙈 Hides and exits: {0} — the last at {1}' }
    $catalogue['tick.failedRefused'] = @{ ar = '⚠️ فشل: {0} · مرفوض: {1}'; en = '⚠️ Failed: {0} · refused: {1}' }
    $catalogue['tick.worthAttention'] = @{ ar = '📌 أحداث تستحق الانتباه ({0})'; en = '📌 Events worth your attention ({0})' }
    $catalogue['tick.missedHtml'] = @{ ar = '<b>🕘 ماذا فاتني</b> — آخر <code>{0}</code> ساعة'; en = '<b>🕘 What I missed</b> — the last <code>{0}</code> hours' }
    $catalogue['tick.whatShowedHtml'] = @{ ar = '<b>📺 ما عُرض</b> — <code>{0}</code> عرضًا'; en = '<b>📺 What went on</b> — <code>{0}</code> shows' }
    $catalogue['tick.operatorCount'] = @{ ar = ' · <code>{0}</code> مشغّلين'; en = ' · <code>{0}</code> operators' }
    $catalogue['tick.timesLast'] = @{ ar = '<code>{0}×</code> · آخرها <code>{1}</code>'; en = '<code>{0}×</code> · the last <code>{1}</code>' }
    $catalogue['tick.hidesAndExitsHtml'] = @{ ar = '<b>🙈 إخفاء وخروج</b>: <code>{0}</code> — آخرها <code>{1}</code>'; en = '<b>🙈 Hides and exits</b>: <code>{0}</code> — the last <code>{1}</code>' }
    $catalogue['tick.failedRefusedHtml'] = @{ ar = '<b>⚠️ فشل:</b> <code>{0}</code> · <b>مرفوض:</b> <code>{1}</code>'; en = '<b>⚠️ Failed:</b> <code>{0}</code> · <b>refused:</b> <code>{1}</code>' }
    $catalogue['tick.onAirHtml'] = @{ ar = '🔴 <b>على الهواء</b>: {0}'; en = '🔴 <b>On air</b>: {0}' }
    $catalogue['tick.whoUsed'] = @{ ar = '👤 من استخدم «{0}»'; en = '👤 Who used "{0}"' }
    $catalogue['tick.noUsageRecord'] = @{ ar = '<i>لا يوجد سجل لاستخدام «{0}» ضمن ما هو محفوظ.</i>'; en = '<i>There is no record of "{0}" being used within what is kept.</i>' }
    $catalogue['tick.whoUsedHtml'] = @{ ar = '<b>👤 من استخدم «{0}»</b>'; en = '<b>👤 Who used "{0}"</b>' }
    $catalogue['tick.draftExpiring'] = @{ ar = "⏳ <b>مسودة الشريط ({0} خبرًا) على وشك الانتهاء</b>`nستُحذف بعد {1} بلا تعديل. مدّدها أو انشرها."; en = "⏳ <b>The ticker draft ({0} headlines) is about to expire</b>`nIt is dropped after {1} with no edit. Give it longer, or publish it." }
    $catalogue['tick.draftExpired'] = @{ ar = "⌛ انتهت صلاحية مسودة شريط الأخبار ({0} خبرًا) بعد {1} بلا تعديل، ولم يُنشر شيء.`nابدأ مسودة جديدة لتعمل على النص الحالي."; en = "⌛ The news ticker draft ({0} headlines) expired after {1} with no edit, and nothing was published.`nStart a new draft to work on the current text." }
    $catalogue['tick.cancelReasonAudit'] = @{ ar = '📝 سبب الإلغاء: {0} - بواسطة {1}'; en = '📝 The reason for the undo: {0} - by {1}' }
    $catalogue['tick.sinceLastRun'] = @{ ar = '🎬 منذ آخر تشغيل: {0} · 📆 آخر 7 أيام: {1} · متوسط {2} يوميًا'; en = '🎬 Since the last run: {0} · 📆 the last 7 days: {1} · {2} a day on average' }
    $catalogue['tick.screenNearLimit'] = @{ ar = '📐 شاشة قريبة من حدّها: {0} — {1}% من الحدّ.'; en = '📐 A screen near its limit: {0} — {1}% of the limit.' }
    $catalogue['tick.plusOthers'] = @{ ar = ' (+{0} أخرى)'; en = ' (+{0} more)' }
    $catalogue['tick.unusedTemplates'] = @{ ar = '🕸 قوالب بلا استعمال منذ شهر: {0}{1}'; en = '🕸 Templates unused for a month: {0}{1}' }
    $catalogue['tick.pair'] = @{ ar = '{0} — {1}'; en = '{0} — {1}' }
    $catalogue['tick.repeatFailures'] = @{ ar = '🔁 فشل متكرر بنفس السبب: {0}'; en = '🔁 Failures repeating for the same cause: {0}' }
    $catalogue['tick.changedSettings'] = @{ ar = "⚙️ إعدادات معدّلة عن الافتراضي:`n{0}{1}"; en = "⚙️ Settings changed from their default:`n{0}{1}" }
    $catalogue['tick.changedSettingsHtml'] = @{ ar = "⚙️ <b>إعدادات معدّلة عن الافتراضي</b>`n<blockquote>{0}{1}</blockquote>"; en = "⚙️ <b>Settings changed from their default</b>`n<blockquote>{0}{1}</blockquote>" }
    $catalogue['tick.lastTime'] = @{ ar = ' · آخر مرة {0}'; en = ' · the last time {0}' }
    $catalogue['tick.sinceLastRunHtml'] = @{ ar = '🎬 <b>منذ آخر تشغيل</b> — {0}'; en = '🎬 <b>Since the last run</b> — {0}' }
    $catalogue['tick.outcomeBlock'] = @{ ar = "<blockquote>✅ ناجحة — {0}
`n❌ فاشلة — {1}
`n⛔ مرفوضة — {2}</blockquote>"; en = "<blockquote>✅ Passed — {0}
`n❌ Failed — {1}
`n⛔ Refused — {2}</blockquote>" }
    $catalogue['tick.lastSevenDays'] = @{ ar = '📆 <b>آخر 7 أيام</b> — {0} · متوسط {1} يوميًا'; en = '📆 <b>The last 7 days</b> — {0} · {1} a day on average' }
    $catalogue['tick.meanSeconds'] = @{ ar = '{0} — متوسط {1} ث ({2})'; en = '{0} — {1} s on average ({2})' }
    $catalogue['tick.slowestToAir'] = @{ ar = '🐢 الأبطأ وصولًا للهواء: {0}'; en = '🐢 The slowest to reach air: {0}' }
    $catalogue['tick.abandonedDrafts'] = @{ ar = '🗑 مسودات مهجورة: {0}'; en = '🗑 Drafts left behind: {0}' }
    $catalogue['tick.itemEndingSoon'] = @{ ar = '⏳ المادة «{0}» تنتهي بعد نحو {1} ({2}). جهّز غرافيك الختام.'; en = '⏳ The item "{0}" ends in about {1} ({2}). Get the closing graphic ready.' }
    $catalogue['tick.copyStuck'] = @{ ar = 'النسخ متوقف عند {0}%'; en = 'the copy is stuck at {0}%' }
    $catalogue['tick.layerBullet'] = @{ ar = '• طبقة {0} · {1} — منذ {2}'; en = '• layer {0} · {1} — {2} ago' }
    $catalogue['tick.hideLayerPair'] = @{ ar = '🙈 أخفِ طبقة {0} · {1}'; en = '🙈 Hide layer {0} · {1}' }
    $catalogue['tick.stillOnAirNotice'] = @{ ar = "⚠️ <b>ما زال على الهواء</b>`n{0} على الطبقة {1} منذ {2}.`nإن لم يعد مطلوبًا فأخفِه من الزرّ أدناه."; en = "⚠️ <b>Still on air</b>`n{0} on layer {1} for {2}.`nIf it is no longer wanted, hide it with the button below." }
    $catalogue['tick.hideLayer'] = @{ ar = '🙈 أخفِ طبقة {0}'; en = '🙈 Hide layer {0}' }
    $catalogue['tick.backOnAir'] = @{ ar = '✅ عاد «{0}» إلى الهواء على {1}.'; en = '✅ "{0}" is back on air on {1}.' }
    $catalogue['tick.notOnAirShouldBe'] = @{ ar = "⚠️ «{0}» ليس على الهواء على {1}.`nيُفترض أن يبقى دائمًا؛ أعِده من 📋 القوالب أو من 🎚 الطبقات."; en = "⚠️ `"{0}`" is not on air on {1}.`nIt is meant to stay there; bring it back from 📋 Templates or 🎚 Layers." }
    $catalogue['tick.unreachable'] = @{ ar = 'تعذّر الوصول: {0}'; en = 'could not be reached: {0}' }
    $catalogue['tick.badMetrics'] = @{ ar = 'قياسات غير سليمة: {0}'; en = 'the measurements are unsound: {0}' }
    $catalogue['tick.badMetricsDropped'] = @{ ar = 'قياسات غير سليمة (الساقط {0} من {1}'; en = 'the measurements are unsound (dropped {0} of {1}' }
    $catalogue['tick.readErrors'] = @{ ar = ' · {0}% · أخطاء القراءة {1}%)'; en = ' · {0}% · read errors {1}%)' }
    $catalogue['tick.faultLasted'] = @{ ar = 'استمر الخلل {0} — من {1} إلى {2}'; en = 'The fault lasted {0} — from {1} to {2}' }
    $catalogue['tick.causeWas'] = @{ ar = 'السبب كان: {0}'; en = 'The cause was: {0}' }
    $catalogue['tick.cinegyHealthWarning'] = @{ ar = "🔴 تحذير صحة Cinegy بعد {0} حالات فشل متتالية`nبداية الانقطاع: {1}`n{2}"; en = "🔴 A Cinegy health warning after {0} failures in a row`nThe outage began: {1}`n{2}" }
    $catalogue['tick.telegramLost'] = @{ ar = "⚠️ فُقد اتصال Telegram بعد {0} حالات فشل متتالية`nبداية الانقطاع: {1}`n{2}"; en = "⚠️ The Telegram connection was lost after {0} failures in a row`nThe outage began: {1}`n{2}" }
    $catalogue['tick.started'] = @{ ar = '🟢 بدأ تشغيل Cinegy Telegram Bridge v{0}'; en = '🟢 Cinegy Telegram Bridge v{0} has started' }
    $catalogue['tick.air'] = @{ ar = 'Air: {0} / قناة {1}'; en = 'Air: {0} / channel {1}' }
    $catalogue['tick.scenesFromBefore'] = @{ ar = '📡 يوجد {0} مشهدًا لا يزال على الهواء من التشغيل السابق:'; en = '📡 {0} scenes are still on air from the previous run:' }
    $catalogue['tick.sceneRow'] = @{ ar = '   • {0} — الطبقة {1}'; en = '   • {0} — layer {1}' }
    $catalogue['tick.sheetSync'] = @{ ar = 'مزامنة الشيت · {0}'; en = 'the sheet sync · {0}' }
    $catalogue['tick.sheetSyncBack'] = @{ ar = '✅ عادت مزامنة الشيت بعد فشل {0} متتالية.'; en = '✅ The sheet sync is back after {0} failures in a row.' }
    $catalogue['tick.lastGoodPublish'] = @{ ar = 'آخر نشر ناجح منذ {0}.'; en = 'The last publish that worked was {0} ago.' }
    $catalogue['tick.sheetSyncFailed'] = @{ ar = "⚠️ مزامنة الشيت فشلت {0} متتالية.`n"; en = "⚠️ The sheet sync has failed {0} times in a row.`n" }
    $catalogue['tick.cause'] = @{ ar = "السبب: {0}`n"; en = "The cause: {0}`n" }
    $catalogue['urg.minutesAgo'] = @{ ar = 'منذ {0} د'; en = '{0} min ago' }
    $catalogue['urg.hoursAgo'] = @{ ar = 'منذ {0} س'; en = '{0} h ago' }
    $catalogue['urg.daysAgo'] = @{ ar = 'منذ {0} يوم'; en = '{0} days ago' }
    $catalogue['urg.counts'] = @{ ar = 'الإجمالي {0} · جاهز {1} · على الهواء {2} · معطّل {3} · محدد {4}'; en = 'In all {0} · ready {1} · on air {2} · off {3} · chosen {4}' }
    $catalogue['urg.manualMode'] = @{ ar = '{0}يدوي — خبر واحد'; en = '{0}by hand — one headline' }
    $catalogue['urg.autoMode'] = @{ ar = '{0}تلقائي — بالتتابع'; en = '{0}automatic — one after another' }
    $catalogue['urg.autoHideAfter'] = @{ ar = '⏱ إخفاء تلقائي بعد {0} ث — تغيير'; en = '⏱ Hides by itself after {0} s — change' }
    $catalogue['urg.playChosen'] = @{ ar = '▶️ تشغيل المحدَّد ({0})'; en = '▶️ Play the chosen ({0})' }
    $catalogue['urg.airShownBy'] = @{ ar = '🚨 عاجل على الهواء الآن — رفعه {0}.'; en = '🚨 An urgent is on air now — put up by {0}.' }
    $catalogue['urg.airHiddenBy'] = @{ ar = '⏹ خرج العاجل عن الهواء — أخفاه {0}.'; en = '⏹ The urgent is off air — hidden by {0}.' }
    $catalogue['urg.runStartedNotice'] = @{ ar = '▶️ بدأ التتابع ({0} أخبار). على الهواء الآن: {1}'; en = '▶️ The sequence is up ({0} stories). On air now: {1}' }
    $catalogue['urg.addedJoinedRun'] = @{ ar = '➕ أُضيف الخبر إلى التتابع الجاري: الخبر {0} من {1}.'; en = '➕ The story joined the live sequence as headline {0} of {1}.' }
    $catalogue['urg.headlineOf'] = @{ ar = 'الخبر {0} من {1}'; en = 'Headline {0} of {1}' }
    $catalogue['urg.current'] = @{ ar = 'الحالي: {0}'; en = 'Now: {0}' }
    $catalogue['urg.next'] = @{ ar = 'التالي: {0}'; en = 'Next: {0}' }
    $catalogue['urg.title'] = @{ ar = '🚨 العواجل — {0} عاجلًا'; en = '🚨 The urgents — {0} of them' }
    $catalogue['urg.filter'] = @{ ar = '{0} · التصفية: {1}'; en = '{0} · the filter: {1}' }
    $catalogue['urg.seconds'] = @{ ar = '{0} ث'; en = '{0} s' }
    $catalogue['urg.defaults'] = @{ ar = 'الافتراضي: {0} · فاصل {1} ث · {2} دورة ({3}) · المدة {4}'; en = 'The default: {0} · a {1} s gap · {2} rounds ({3}) · lasting {4}' }
    $catalogue['urg.autoHideWarning'] = @{ ar = '⚠️ {0}: يُخفى تلقائيًا بعد {1} ث؛ قد ينتهي الجدول قبل ذلك.'; en = '⚠️ {0}: it hides by itself after {1} s; the board may end before that.' }
    $catalogue['urg.showing'] = @{ ar = 'المعروض: {0}–{1} · صفحة {2} من {3}'; en = 'Showing: {0}–{1} · page {2} of {3}' }
    $catalogue['urg.secondsStar'] = @{ ar = '{0} ث ✱'; en = '{0} s ✱' }
    $catalogue['urg.titleHtml'] = @{ ar = '🚨 <b>العواجل</b> — {0} عاجلًا'; en = '🚨 <b>The urgents</b> — {0} of them' }
    $catalogue['urg.defaultsShort'] = @{ ar = 'الافتراضي: إخفاء بعد {0} ث · {1} دورة'; en = 'The default: hide after {0} s · {1} rounds' }
    $catalogue['urg.row'] = @{ ar = '{0} {1} {2}. {3} {4} — {5} ث · {6}'; en = '{0} {1} {2}. {3} {4} — {5} s · {6}' }
    $catalogue['urg.gap'] = @{ ar = '⏱ الإخفاء التلقائي: {0} ث'; en = '⏱ Auto-hide: {0} s' }
    $catalogue['urg.repeat'] = @{ ar = '🔁 التكرار: {0}'; en = '🔁 The repeat: {0}' }
    $catalogue['urg.willReplaceHeadline'] = @{ ar = "`n⚠️ سيتم استبدال الخبر الحالي:`n«{0}»`nبالخبر:`n«{1}»"; en = "`n⚠️ The headline on air will be replaced:`n`"{0}`"`nwith:`n`"{1}`"" }
    $catalogue['urg.readFull'] = @{ ar = "👁 الخبر {0} من {1}`nقراءة النص الكامل — التصفّح لا يغيّر الهواء.`n`n{2}"; en = "👁 Headline {0} of {1}`nReading the whole text — paging through changes nothing on air.`n`n{2}" }
    $catalogue['urg.part'] = @{ ar = "`n`nجزء {0} من {1}"; en = "`n`nPart {0} of {1}" }
    $catalogue['urg.headlineOfHtml'] = @{ ar = '{0} · <b>الخبر {1} من {2}</b>'; en = '{0} · <b>Headline {1} of {2}</b>' }
    $catalogue['urg.mode'] = @{ ar = 'العرض: {0}{1}'; en = 'The mode: {0}{1}' }
    $catalogue['urg.gapLine'] = @{ ar = 'الفاصل: {0} ث{1}'; en = 'The gap: {0} s{1}' }
    $catalogue['urg.repeatLine'] = @{ ar = 'التكرار: {0}{1}'; en = 'The repeat: {0}{1}' }
    $catalogue['urg.gapRaised'] = @{ ar = '⚠️ رُفع الفاصل إلى {0} ث: أقصر ممّا يسمح به المشهد.'; en = '⚠️ The gap was raised to {0} s: shorter than the scene allows.' }
    $catalogue['urg.disabledReason'] = @{ ar = 'سبب التعطيل: {0}'; en = 'Why it is off: {0}' }
    $catalogue['urg.lastEdit'] = @{ ar = 'آخر تعديل: {0}'; en = 'Last edited: {0}' }
    $catalogue['urg.totalDuration'] = @{ ar = '⏳ المدة الكلية: {0} ث'; en = '⏳ In all it lasts: {0} s' }
    $catalogue['urg.defaultMode'] = @{ ar = '🎬 النمط الافتراضي: {0}'; en = '🎬 The default mode: {0}' }
    $catalogue['urg.gapBetween'] = @{ ar = '⏳ الفاصل بين الأخبار: {0} ث'; en = '⏳ The gap between headlines: {0} s' }
    $catalogue['urg.showThisOneTimed'] = @{ ar = 'عرض هذا الخبر لمدة {0} ث'; en = 'Show this story for {0} s' }
    $catalogue['urg.shortestGap'] = @{ ar = 'أقصر فاصل يسمح به هذا المشهد: {0} ث.'; en = 'The shortest gap this scene allows: {0} s.' }
    $catalogue['urg.didNotStart'] = @{ ar = '⚠️ لم يبدأ التشغيل: {0}'; en = '⚠️ It did not start: {0}' }
    $catalogue['urg.reviewBeforePlay'] = @{ ar = '▶️ <b>مراجعة قبل التشغيل</b> — {0}'; en = '▶️ <b>A look before it plays</b> — {0}' }
    $catalogue['urg.actualGap'] = @{ ar = 'الفاصل الفعلي: {0} ث'; en = 'The gap in fact: {0} s' }
    $catalogue['urg.runCeiling'] = @{ ar = 'سقف التشغيل: {0} ث — {1}'; en = 'The run ceiling: {0} s — {1}' }
    $catalogue['urg.updateWithoutLoop'] = @{ ar = '⚠️ {0} سطرًا بنمط «تحديث نص» على مشهد بلا حلقة: سيُرى التبديل.'; en = '⚠️ {0} rows in "update the text" mode on a scene with no loop: the change will be seen.' }
    $catalogue['urg.deletedAudit'] = @{ ar = '🗑 حذف عاجل من الجدول - بواسطة {0}'; en = '🗑 An urgent deleted from the board - by {0}' }
    $catalogue['urg.delete'] = @{ ar = '🗑 احذف {0}'; en = '🗑 Delete {0}' }
    $catalogue['urg.confirmDelete'] = @{ ar = '🗑 حذف {0} عاجلًا من الجدول؟'; en = '🗑 Delete {0} urgents from the board?' }
    $catalogue['urg.deletedManyAudit'] = @{ ar = '🗑 حذف {0} عاجلًا من الجدول - بواسطة {1}'; en = '🗑 {0} urgents deleted from the board - by {1}' }
    $catalogue['urg.numberScreen'] = @{ ar = "🔢 {0}`nالقيمة: {1}`nالمدى: {2}–{3}`nاختر بالأزرار؛ كل ضغطة تُحفظ فورًا."; en = "🔢 {0}`nThe value: {1}`nThe range: {2}–{3}`nChoose with the buttons; every press is saved at once." }
    $catalogue['urg.actualValue'] = @{ ar = "`nالقيمة الفعلية: {0}"; en = "`nThe value in fact: {0}" }
    $catalogue['urg.gapRaisedNl'] = @{ ar = "`n⚠️ رُفع الفاصل إلى {0} ث: أقصر ممّا يسمح به المشهد."; en = "`n⚠️ The gap was raised to {0} s: shorter than the scene allows." }
    $catalogue['urg.lowest'] = @{ ar = 'الأدنى: {0}'; en = 'The lowest: {0}' }
    $catalogue['urg.highest'] = @{ ar = 'الأقصى: {0}'; en = 'The highest: {0}' }
    $catalogue['tick.timerNotRun'] = @{ ar = '⚠️ لم يُنفَّذ المؤقت للطبقة {0}: {1}'; en = '⚠️ The timer on layer {0} did not run: {1}' }
}
