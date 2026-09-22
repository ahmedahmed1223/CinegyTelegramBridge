#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the relay and its snapshots with the black-screen
    watch, the scheduling from reading a typed time to the clash it warns
    about, the formatters shared across screens, and the what's-new
    heading.
#>

function Add-BridgeTextInterp9 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['media.lastSnapshot'] = @{ ar = "📸 آخر لقطة ({0} ثانية مضت)`n📡 المصدر: {1}"; en = "📸 The last snapshot ({0} seconds ago)`n📡 The source: {1}" }
    $catalogue['media.ffmpegFailed'] = @{ ar = '❌ فشل تشغيل ffmpeg: {0}'; en = '❌ ffmpeg would not run: {0}' }
    $catalogue['media.captureFailed'] = @{ ar = '❌ فشل التقاط الصورة (كود {0}).'; en = '❌ The picture could not be taken (code {0}).' }
    $catalogue['media.ffmpegReason'] = @{ ar = "`nسبب ffmpeg: {0}"; en = "`nffmpeg's reason: {0}" }
    $catalogue['media.snapshotAudit'] = @{ ar = '📸 لقطة - بواسطة {0}'; en = '📸 A snapshot - by {0}' }
    $catalogue['media.snapshotOfAir'] = @{ ar = "📸 لقطة من الهواء - {0}`n📡 المصدر: {1}"; en = "📸 A snapshot of the air - {0}`n📡 The source: {1}" }
    $catalogue['media.captureTimedOut'] = @{ ar = 'انتهت مهلة الالتقاط بعد {0}'; en = 'the capture timed out after {0}' }
    $catalogue['media.blackButThere'] = @{ ar = 'متاح لكن أسود (سطوع {0})'; en = 'there but black (brightness {0})' }
    $catalogue['media.there'] = @{ ar = 'متاح (سطوع {0})'; en = 'there (brightness {0})' }
    $catalogue['media.set'] = @{ ar = 'مضبوط ({0})'; en = 'set ({0})' }
    $catalogue['media.every'] = @{ ar = 'كل {0}'; en = 'every {0}' }
    $catalogue['media.watchServer'] = @{ ar = '🖥️ سيرفر المتابعة: {0} · {1}'; en = '🖥️ The monitoring server: {0} · {1}' }
    $catalogue['media.manualCheck'] = @{ ar = '🔎 الفحص اليدوي للمصدر الأساسي: {0}'; en = '🔎 The main source, checked by hand: {0}' }
    $catalogue['media.sourceInUse'] = @{ ar = '🎚 المصدر المستخدم حالياً: {0}'; en = '🎚 The source in use right now: {0}' }
    $catalogue['media.mainSourceKind'] = @{ ar = '🔗 نوع المصدر الأساسي: {0}'; en = '🔗 The kind of the main source: {0}' }
    $catalogue['media.fallbackSource'] = @{ ar = '🛟 المصدر الاحتياطي: {0}'; en = '🛟 The fallback source: {0}' }
    $catalogue['media.watchCycle'] = @{ ar = '⏱ المراقبة الدورية: {0} · آخر دورة: {1}'; en = '⏱ The regular watch: {0} · the last round: {1}' }
    $catalogue['media.capturesInARow'] = @{ ar = '⚠️ فشل التقاط متتالٍ: {0}'; en = '⚠️ Captures failing in a row: {0}' }
    $catalogue['media.sourceFlappingShort'] = @{ ar = '⚠️ مصدر البث متذبذب - فشل الالتقاط {0} خلال ست ساعات'; en = '⚠️ The feed source is flapping - {0} capture failures in six hours' }
    $catalogue['media.sourceFlapping'] = @{ ar = "⚠️ مصدر البث يتذبذب: فشل التقاط المخرج {0} خلال الساعات الست الماضية، وفي كل مرة عاد بعدها.`nالمراقبة تعمل، لكنها لا ترى المخرج جزءًا من الوقت. يستحسن فحص الخادم قبل أن يتوقف كليًا."; en = "⚠️ The feed source is flapping: the output failed to capture {0} times in the last six hours, and came back each time.`nThe watch is running, but it cannot see the output part of the time. Worth checking the server before it stops for good." }
    $catalogue['media.outputUnreachableShort'] = @{ ar = '⚠️ تعذّر الوصول إلى مخرج البث {0} متتالية'; en = '⚠️ The feed output could not be reached, {0} times in a row' }
    $catalogue['media.switchedToFallback'] = @{ ar = "⚠️ تعذّر الوصول إلى المصدر الأساسي بعد {0} محاولات متتالية.`nتم التحويل إلى مصدر Cinegy الاحتياطي.`nسيُعاد فحص المصدر الأساسي خلال دقائق."; en = "⚠️ The main source could not be reached after {0} tries in a row.`nIt switched to the Cinegy fallback source.`nThe main source is checked again in a few minutes." }
    $catalogue['media.blackConfirmed'] = @{ ar = '🖤 تأكيد شاشة سوداء على المخرج (سطوع {0})'; en = '🖤 A black screen on the output, confirmed (brightness {0})' }
    $catalogue['media.channelAnswers'] = @{ ar = '• القناة: تُجيب، ومخرجها مضبوط على <b>{0}</b> — أي أنّ السواد مقصود لا عطل.'; en = '• The channel: it answers, and its output is set to <b>{0}</b> — so the black is meant, not a fault.' }
    $catalogue['media.serverNotAnswering'] = @{ ar = '• سيرفر البث: آخر خطأ يشير إلى أن الخادم لا يجيب — {0}'; en = '• The feed server: the last error says the server is not answering — {0}' }
    $catalogue['media.lastRecordedError'] = @{ ar = '• سيرفر البث: آخر خطأ مسجّل — {0}'; en = '• The feed server: the last error recorded — {0}' }
    $catalogue['media.checkSource'] = @{ ar = '• المصدر المستعمل: {0} — تحقّق من خادمه وشبكته.'; en = '• The source in use: {0} — check its server and its network.' }
    $catalogue['media.outputUnreachable'] = @{ ar = "⚠️ <b>تعذّر الوصول إلى مخرج البث</b> بعد {0} محاولات متتالية.`n"; en = "⚠️ <b>The feed output could not be reached</b> after {0} tries in a row.`n" }
    $catalogue['media.backToLight'] = @{ ar = '💡 عاد المخرج إلى الإضاءة الطبيعية (سطوع {0}).'; en = '💡 The output is back to its normal light (brightness {0}).' }
    $catalogue['media.outputBlack'] = @{ ar = "🖤 المخرج أسود — تأكّد عبر لقطتين متتاليتين (سطوع {0}).`nتحقّق من المصدر وسلسلة البث."; en = "🖤 The output is black — confirmed by two snapshots in a row (brightness {0}).`nCheck the source and the feed chain." }
    $catalogue['media.running'] = @{ ar = '🟢 يعمل (PID {0})'; en = '🟢 Running (PID {0})' }
    $catalogue['media.feedStartedAudit'] = @{ ar = '▶️ بدء البث - بواسطة {0}'; en = '▶️ The feed started - by {0}' }
    $catalogue['media.feedStoppedAudit'] = @{ ar = '⏹ إيقاف البث - بواسطة {0}'; en = '⏹ The feed stopped - by {0}' }
    $catalogue['media.stopFailed'] = @{ ar = 'فشل إيقاف البث: {0}'; en = 'The feed would not stop: {0}' }
    $catalogue['media.stoppedAtOnce'] = @{ ar = '❌ توقف البث فورًا بعد التشغيل (كود {0}).'; en = '❌ The feed stopped the moment it started (code {0}).' }
    $catalogue['media.gaveUp'] = @{ ar = '⚠️ توقف البث نهائيًا بعد {0} محاولة إعادة تشغيل. راجع logs\relay-stderr.log.'; en = '⚠️ The feed stopped for good after {0} restart attempts. Look at logs\relay-stderr.log.' }
    $catalogue['media.restarted'] = @{ ar = '🔄 انقطع البث وتمت إعادة تشغيله تلقائيًا (محاولة {0}).'; en = '🔄 The feed dropped and was restarted by itself (attempt {0}).' }
    $catalogue['media.linkSaved'] = @{ ar = '✅ تم حفظ رابط البث.{0}'; en = '✅ The feed link was saved.{0}' }
    $catalogue['sch.timeRead'] = @{ ar = "فُهم الموعد: {0}`nالمنطقة: {1}`nاختر التكرار:"; en = "The time was read as: {0}`nThe zone: {1}`nChoose the repeat:" }
    $catalogue['sch.pickHour'] = @{ ar = '{0} — اختر الساعة'; en = '{0} — choose the hour' }
    $catalogue['sch.pickMinute'] = @{ ar = '{0} {1}:— اختر الدقيقة'; en = '{0} {1}:— choose the minute' }
    $catalogue['sch.outOfRange'] = @{ ar = "ساعة أو دقيقة خارج المدى.`n{0}"; en = "The hour or the minute is out of range.`n{0}" }
    $catalogue['sch.notUnderstood'] = @{ ar = "لم أفهم الموعد.`n{0}"; en = "I could not read that time.`n{0}" }
    $catalogue['sch.late'] = @{ ar = 'متأخرة {0}'; en = '{0} late' }
    $catalogue['sch.attempt'] = @{ ar = ' · محاولة {0}'; en = ' · attempt {0}' }
    $catalogue['sch.allPassed'] = @{ ar = '🟢 {0}، كلّها ناجحة'; en = '🟢 {0}, every one of them passed' }
    $catalogue['sch.someFailed'] = @{ ar = '🟠 {0} · ❌ {1}'; en = '🟠 {0} · ❌ {1}' }
    $catalogue['sch.nameLayer'] = @{ ar = '{0} · ط{1}'; en = '{0} · L{1}' }
    $catalogue['sch.secondsAfterStart'] = @{ ar = 'بعد بدء بـ {0} ث'; en = '{0} s after the start' }
    $catalogue['sch.minutesAfterStart'] = @{ ar = 'بعد بدء بـ {0} د'; en = '{0} min after the start' }
    $catalogue['sch.linkedTo'] = @{ ar = '🎞 مربوط: {0} «{1}»'; en = '🎞 Linked to: {0} "{1}"' }
    $catalogue['sch.templateInvalidAtRun'] = @{ ar = 'القالب ''{0}'' غير صالح عند وقت التنفيذ.'; en = 'The template ''{0}'' is not valid at the time it runs.' }
    $catalogue['sch.templateMissingAtRun'] = @{ ar = 'القالب ''{0}'' غير موجود عند وقت التنفيذ.'; en = 'The template ''{0}'' is not there at the time it runs.' }
    $catalogue['sch.templateIncompleteAtRun'] = @{ ar = 'القالب ''{0}'' غير صالح عند وقت التنفيذ (المسار أو الطبقة غير مكتملة).'; en = 'The template ''{0}'' is not valid at the time it runs (the path or the layer is incomplete).' }
    $catalogue['sch.templateCheckFailed'] = @{ ar = 'تعذّر فحص القالب ''{0}'' عند وقت التنفيذ: {1}'; en = 'The template ''{0}'' could not be checked at the time it runs: {1}' }
    $catalogue['sch.eventSoon'] = @{ ar = "⏰ الحدث المجدول '{0}' سيُعرض بعد نحو {1}.`n{2}"; en = "⏰ The scheduled event '{0}' goes on in about {1}.`n{2}" }
    $catalogue['sch.layerSwap'] = @{ ar = 'الطبقة {0}: ''{1}'' ← ''{2}'''; en = 'Layer {0}: ''{1}'' ← ''{2}''' }
    $catalogue['sch.didNotRun'] = @{ ar = '⛔ لم يتم تشغيل الموعد: {0}'; en = '⛔ The event did not run: {0}' }
    $catalogue['sch.sendNewTime'] = @{ ar = "📅 {0}`nالموعد الحالي: {1}`nالمنطقة: {2}`nأرسل الموعد الجديد بصيغة YYYY-MM-DD HH:mm"; en = "📅 {0}`nThe time now: {1}`nThe zone: {2}`nSend the new time as YYYY-MM-DD HH:mm" }
    $catalogue['sch.whenToShow'] = @{ ar = "⏰ متى يُعرض؟`n{0}`n`nالوقت الحالي: {1}`nالمنطقة: {2}"; en = "⏰ When should it go on?`n{0}`n`nThe time now: {1}`nThe zone: {2}" }
    $catalogue['sch.firstField'] = @{ ar = "📅 قيمة الحقل (1/{0}):`n{1}"; en = "📅 The field value (1/{0}):`n{1}" }
    $catalogue['sch.field'] = @{ ar = "📅 قيمة الحقل ({0}/{1}):`n{2}"; en = "📅 The field value ({0}/{1}):`n{2}" }
    $catalogue['sch.template'] = @{ ar = 'القالب: {0}'; en = 'The template: {0}' }
    $catalogue['sch.time'] = @{ ar = 'الموعد: {0}'; en = 'The time: {0}' }
    $catalogue['sch.zone'] = @{ ar = 'المنطقة: {0}'; en = 'The zone: {0}' }
    $catalogue['sch.repeat'] = @{ ar = 'التكرار: {0}'; en = 'The repeat: {0}' }
    $catalogue['sch.repeatEnds'] = @{ ar = 'نهاية التكرار: {0}'; en = 'The repeat ends: {0}' }
    $catalogue['sch.possibleClash'] = @{ ar = '⚠️ تعارض محتمل على الطبقة {0}:'; en = '⚠️ A possible clash on layer {0}:' }
    $catalogue['sch.scheduledAudit'] = @{ ar = '📅 جدولة: {0} {1} / {2} - بواسطة {3}'; en = '📅 Scheduled: {0} {1} / {2} - by {3}' }
    $catalogue['sch.saved'] = @{ ar = "✅ تم حفظ الجدولة.`n{0}"; en = "✅ The schedule was saved.`n{0}" }
    $catalogue['sch.draftSurvivedRestart'] = @{ ar = "↩️ أُعيد تشغيل الجسر، ومسودتك لم تضِع: <b>{0}</b> ما تزال مفتوحة وتنتظر نصّك.`nأكمل من حيث توقفت، أو ألغِها إن لم تعد تريدها."; en = "↩️ The bridge restarted and your draft is not lost: <b>{0}</b> is still open and waiting for your text.`nCarry on from where you stopped, or drop it if you no longer want it." }
    $catalogue['core.redacted'] = @{ ar = '•••• ({0} حرفًا)'; en = '•••• ({0} characters)' }
    $catalogue['core.items'] = @{ ar = '{0} عنصرًا'; en = '{0} items' }
    $catalogue['core.restoreBackup'] = @{ ar = '⚠️ استعادة النسخة {0}'; en = '⚠️ Restore the backup {0}' }
    $catalogue['core.settingsWillChange'] = @{ ar = '{0} إعدادًا سيتغيّر · تُحفظ الحالة الحالية أولًا'; en = '{0} settings will change · the current state is kept first' }
    $catalogue['core.differences'] = @{ ar = 'الاختلافات: {0}'; en = 'The differences: {0}' }
    $catalogue['core.differencesFailed'] = @{ ar = 'الاختلافات: تعذّر حسابها ({0}).'; en = 'The differences: they could not be worked out ({0}).' }
    $catalogue['core.layer'] = @{ ar = 'طبقة {0}'; en = 'layer {0}' }
    $catalogue['core.nameLayer'] = @{ ar = '{0} · طبقة {1}'; en = '{0} · layer {1}' }
    $catalogue['core.tripledLetter'] = @{ ar = 'حرف مكرّر ثلاث مرات: «{0}»'; en = 'a letter three times over: "{0}"' }
    $catalogue['core.unseenWord'] = @{ ar = 'كلمة لم تكتبها المحطة من قبل: {0} — تأكّد من هجائها'; en = 'a word the station has never written before: {0} — check its spelling' }
    $catalogue['core.newestRowsOnly'] = @{ ar = '⚠️ عُرض أحدث {0} صفًّا فقط؛ {1} صفًّا أقدم غير معروضة.'; en = '⚠️ Only the newest {0} rows are shown; {1} older rows are not.' }
    $catalogue['core.secondsFew'] = @{ ar = '{0} ثوانٍ'; en = '{0} seconds' }
    $catalogue['core.seconds'] = @{ ar = '{0} ثانية'; en = '{0} seconds' }
    $catalogue['core.and'] = @{ ar = ' و{0}'; en = ' and {0}' }
    $catalogue['core.plusOthers'] = @{ ar = ' (+{0} أخرى)'; en = ' (+{0} more)' }
    $catalogue['core.sendWholeNumber'] = @{ ar = "{0}.`nالقيمة الحالية: <code>{1}</code>`nالقيمة الافتراضية: <code>{2}</code>`nأرسل رقمًا صحيحًا غير سالب:"; en = "{0}.`nThe value now: <code>{1}</code>`nThe default: <code>{2}</code>`nSend a whole number that is not negative:" }
    $catalogue['core.atLeast'] = @{ ar = '{0} لا يقلّ عن {1}.'; en = '{0} is no less than {1}.' }
    $catalogue['core.atMost'] = @{ ar = '{0} لا يزيد عن {1}.'; en = '{0} is no more than {1}.' }
    $catalogue['core.restartLoopShort'] = @{ ar = '🔁 الجسر أُعيد تشغيله {0} خلال 24 ساعة — عمل إصدارات أم حلقة عطل؟'; en = '🔁 The bridge restarted {0} times in 24 hours — release work, or a crash loop?' }
    $catalogue['core.restartLoop'] = @{ ar = '🔁 الجسر أُعيد تشغيله {0} خلال 24 ساعة. إن كان عمل إصدارات مخططًا فتجاهل هذا — وإلا راجع آخر أسطر bridge.log.'; en = '🔁 The bridge restarted {0} times in 24 hours. If that is planned release work, ignore this — otherwise read the last lines of bridge.log.' }
    $catalogue['whatsnew.title'] = @{ ar = '<b>🆕 ما الجديد</b> — الإصدار الحالي <code>{0}</code>'; en = '<b>🆕 What''s new</b> — this release is <code>{0}</code>' }
}
