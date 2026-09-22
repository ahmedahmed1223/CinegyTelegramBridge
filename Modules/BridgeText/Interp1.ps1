#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds sentences with holes in them: the boards, the on-air
    card, the relay that carries an alert, the urgent board, and the
    bulletin's design arithmetic and its playback with the handover to and
    from an urgent.

    The Arabic side was taken from the source by the parser rather than
    retyped, so every hole sits exactly where it sat before.
#>

function Add-BridgeTextInterp1 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['board.templateGone'] = @{ ar = '⛔ قالب هذا الجدول (''{0}'') لم يعد في السجلّ.'; en = '⛔ This board''s template (''{0}'') is no longer in the register.' }
    $catalogue['board.rowOf'] = @{ ar = '{0} <b>الصفّ {1} من {2}</b>'; en = '{0} <b>Row {1} of {2}</b>' }
    $catalogue['board.fromScene'] = @{ ar = '🖼 {0} — من المشهد، لا تُملأ من هنا.'; en = '🖼 {0} — it comes from the scene, and is not filled in here.' }
    $catalogue['board.created'] = @{ ar = '🗂 إنشاء جدول محتوى «{0}» - بواسطة {1}'; en = '🗂 Content board "{0}" created - by {1}' }
    $catalogue['board.rowsAdded'] = @{ ar = '📋 أُضيف {0} صفًّا.'; en = '📋 {0} rows were added.' }
    $catalogue['board.skipped'] = @{ ar = 'تُخطّي {0}: {1}'; en = '{0} skipped: {1}' }
    $catalogue['board.stopped'] = @{ ar = '⛔ توقّف: {0}'; en = '⛔ Stopped: {0}' }
    $catalogue['onair.lateSince'] = @{ ar = '🟠 متأخر منذ {0}'; en = '🟠 Late since {0}' }
    $catalogue['onair.airServer'] = @{ ar = 'خادم Air: {0} | القناة: {1}'; en = 'Air server: {0} | channel: {1}' }
    $catalogue['onair.botTemplate'] = @{ ar = 'القالب الذي كان يعرضه البوت: {0}'; en = 'The template the bot was showing: {0}' }
    $catalogue['onair.operatorStarted'] = @{ ar = 'المشغّل: {0} | بدأ: {1}'; en = 'Operator: {0} | started: {1}' }
    $catalogue['onair.previousId'] = @{ ar = 'المعرّف السابق: {0}'; en = 'The earlier id: {0}' }
    $catalogue['onair.currentItem'] = @{ ar = 'العنصر الحالي: {0} | المعرّف: {1}'; en = 'The current item: {0} | id: {1}' }
    $catalogue['onair.outputState'] = @{ ar = 'حالة الخرج: {0}'; en = 'Output state: {0}' }
    $catalogue['onair.cinegyClient'] = @{ ar = 'عميل Cinegy: {0}'; en = 'Cinegy client: {0}' }
    $catalogue['onair.source'] = @{ ar = 'المصدر: {0}'; en = 'Source: {0}' }
    $catalogue['tg.photoFailed'] = @{ ar = '❌ فشل إرسال الصورة: {0}'; en = '❌ The picture could not be sent: {0}' }
    $catalogue['tg.repeat'] = @{ ar = '🔁 تكرار: هذه المرة رقم {0} لنفس السبب خلال {1} (الأولى {2}). السبب واحد - عالجه، لا الحالة.'; en = '🔁 A repeat: this is number {0} for the same cause within {1} (the first at {2}). One cause - treat that, not the symptom.' }
    $catalogue['tg.muted'] = @{ ar = "🔇 كُتم {0} من نفس السبب خلال الساعة الماضية بعد بلوغ السقف.`n"; en = "🔇 {0} from the same cause were muted in the last hour once the ceiling was reached.`n" }
    $catalogue['tg.cause'] = @{ ar = 'السبب: {0}'; en = 'The cause: {0}' }
    $catalogue['tg.heldAlertsDropped'] = @{ ar = '🌅 تنبيهات مؤجّلة من فترة الهدوء ({0}، وسقط {1} أقدم منها)'; en = '🌅 Alerts held back from the quiet hours ({0}, and {1} older ones were dropped)' }
    $catalogue['tg.heldAlerts'] = @{ ar = '🌅 تنبيهات مؤجّلة من فترة الهدوء ({0})'; en = '🌅 Alerts held back from the quiet hours ({0})' }
    $catalogue['tg.copyButton'] = @{ ar = '📋 زر «{0}» ينسخ النص إلى حافظة جهازك فورًا — {1}'; en = '📋 The "{0}" button copies the text straight to your clipboard — {1}' }
    $catalogue['tg.more'] = @{ ar = '📄 المزيد ({0}/{1})'; en = '📄 More ({0}/{1})' }
    $catalogue['urgp.didNotStart'] = @{ ar = '⚠️ لم يبدأ التشغيل: {0}'; en = '⚠️ It did not start: {0}' }
    $catalogue['urgp.boardDidNotStart'] = @{ ar = '❌ لم يبدأ جدول العواجل: {0}'; en = '❌ The urgent board did not start: {0}' }
    $catalogue['urgp.boardStarted'] = @{ ar = '🚨 تشغيل جدول العواجل ({0} خطوة) - بواسطة {1}'; en = '🚨 The urgent board started ({0} steps) - by {1}' }
    $catalogue['urgp.stoppedAtStep'] = @{ ar = '❌ توقّف جدول العواجل عند الخطوة {0}: {1}'; en = '❌ The urgent board stopped at step {0}: {1}' }
    $catalogue['urgp.afterRestart'] = @{ ar = '🚨 جدول العواجل {0} بعد إعادة التشغيل عند الخطوة {1} من {2}.'; en = '🚨 The urgent board {0} after the restart, at step {1} of {2}.' }
    $catalogue['urgp.skipped'] = @{ ar = '⏭ تخطي العاجل الحالي — بواسطة {0}'; en = '⏭ The current urgent was skipped — by {0}' }
    $catalogue['mjd.media'] = @{ ar = '{0} وسائط'; en = '{0} media' }
    $catalogue['mjd.text'] = @{ ar = '{0} نص'; en = '{0} text' }
    $catalogue['mjd.durationMultiple'] = @{ ar = '⚠️ المدة {0} أضعاف طول اللوب ({1}) — سيُعرض كل خبر {2}. اجعلها {3} أو فعّل «مزامنة الظهور».'; en = '⚠️ The duration is {0} times the loop length ({1}) — every headline will show for {2}. Make it {3}, or turn "sync with the reveal" on.' }
    $catalogue['mjd.durationMismatch'] = @{ ar = '⚠️ المدة لا توافق طول اللوب ({0}) — سيتبدّل الخبر في منتصف الحركة. اجعلها من مضاعفات {1} أو فعّل «مزامنة الظهور».'; en = '⚠️ The duration does not fit the loop length ({0}) — a headline will change mid-motion. Make it a multiple of {1}, or turn "sync with the reveal" on.' }
    $catalogue['mjd.syncExplain'] = @{ ar = '<b>🎬 مزامنة مع حركة الظهور</b>: كل صف يبقى لوبًا كاملًا (<code>{0}</code> ث) ويتبدّل داخل ظهورٍ مدّته <code>{1}</code> ث.'; en = '<b>🎬 Synced with the reveal</b>: every row holds for a whole loop (<code>{0}</code> s) and changes inside a reveal of <code>{1}</code> s.' }
    $catalogue['mjd.loopLong'] = @{ ar = "`n⚠️ اللوب طويل، فالصف يبقى <code>{0}</code> ث. لتسريعه قصِّر <code>LoopEndFrame</code> في Titler."; en = "`n⚠️ The loop is long, so a row holds for <code>{0}</code> s. To speed it up, shorten <code>LoopEndFrame</code> in Titler." }
    $catalogue['mjd.oneLoopPerRow'] = @{ ar = "كل صف لوب واحد ({0} ث) · الإجمالي ≈ {1}`n{2}"; en = "One loop per row ({0} s) · in all ≈ {1}`n{2}" }
    $catalogue['mjd.framesPerRow'] = @{ ar = 'كل صف {0} إطار ({1} ث) · الأول +{2} إطار لحركة الدخول · الأخير {3} إطار ثم خروج · الإجمالي ≈ {4}'; en = 'Each row {0} frames ({1} s) · the first +{2} frames for the entry · the last {3} frames then out · in all ≈ {4}' }
    $catalogue['mjd.fromTemplate'] = @{ ar = "`nمن القالب: دخول {0} إطار · لوب {1} إطار · خروج {2} إطار (‏{3} إطارًا/ث)"; en = "`nFrom the template: entry {0} frames · loop {1} frames · exit {2} frames ({3} frames/s)" }
    $catalogue['mjd.paceBecomesLoop'] = @{ ar = '، والإيقاع يصير طول اللوب ({0}) لا المدة أعلاه'; en = ', and the pace becomes the loop length ({0}), not the duration above' }
    $catalogue['mjp.urgentOnAirWhen'] = @{ ar = "🚨 العاجل على الهواء الآن.`nمتى يبدأ «{0}»؟"; en = "🚨 The urgent is on air now.`nWhen should `"{0}`" start?" }
    $catalogue['mjp.didNotStart'] = @{ ar = '❌ لم يبدأ الموجز: {0}'; en = '❌ The bulletin did not start: {0}' }
    $catalogue['mjp.started'] = @{ ar = '📑 تشغيل «{0}» ({1} صفًّا) - بواسطة {2}'; en = '📑 "{0}" started ({1} rows) - by {2}' }
    $catalogue['mjp.pulledForUrgent'] = @{ ar = '🚨 سُحب الموجز «{0}» لصالح العاجل - بواسطة {1}'; en = '🚨 The bulletin "{0}" was pulled for the urgent - by {1}' }
    $catalogue['mjp.leftForUrgent'] = @{ ar = '🚨 خرج «{0}» ليفسح المجال للعاجل.'; en = '🚨 "{0}" left to make room for the urgent.' }
    $catalogue['mjp.heldUntilAfterUrgent'] = @{ ar = '⏳ تأجيل «{0}» إلى ما بعد العاجل - بواسطة {1}'; en = '⏳ "{0}" was held until after the urgent - by {1}' }
    $catalogue['mjp.startsWhenUrgentLeaves'] = @{ ar = '⏳ سيبدأ «{0}» فور خروج العاجل.'; en = '⏳ "{0}" starts the moment the urgent leaves.' }
    $catalogue['mjp.urgentHeld'] = @{ ar = '⏳ تأجيل العاجل إلى ما بعد الموجز - بواسطة {0}'; en = '⏳ The urgent was held until after the bulletin - by {0}' }
    $catalogue['mjp.hidden'] = @{ ar = '⏹ إخفاء الموجز - بواسطة {0}'; en = '⏹ The bulletin was hidden - by {0}' }
    $catalogue['mjp.notResumed'] = @{ ar = '⚠️ لم يُستأنف الموجز «{0}» أو يُخرج بعد إعادة التشغيل لأن هوية المشهد على الطبقة تغيّرت أو تعذّر التحقق منها.'; en = '⚠️ The bulletin "{0}" was neither resumed nor taken out after the restart, because the scene on the layer changed identity or could not be checked.' }
    $catalogue['mjp.pastItsTime'] = @{ ar = '⏹ كان الموجز «{0}» على الهواء لحظة إعادة التشغيل وقد تجاوز وقت خروجه، فأُخرج الآن.'; en = '⏹ The bulletin "{0}" was on air at the restart and had run past its exit time, so it was taken out now.' }
    $catalogue['mjp.resumed'] = @{ ar = '▶️ استُؤنف الموجز «{0}» بعد إعادة التشغيل عند الصف {1}.'; en = '▶️ The bulletin "{0}" resumed after the restart, at row {1}.' }
    $catalogue['mjp.endedAndLeft'] = @{ ar = '⏹ انتهى «{0}» وخرج عن الهواء.'; en = '⏹ "{0}" ended and left the air.' }
    $catalogue['mjp.stoppedAtRow'] = @{ ar = '❌ توقّف الموجز عند الصف {0}: {1}'; en = '❌ The bulletin stopped at row {0}: {1}' }
}
