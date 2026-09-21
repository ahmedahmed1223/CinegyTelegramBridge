#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds what the bridge says when nobody asked: the alerts it
    raises about the air and about itself, the periodic digests, and the
    reason-for-undo prompts.

    Its own file because an alert is read at three in the morning by whoever
    is on call, and a translator working on it should not have to scroll past
    the settings labels to find it.
#>

function Add-BridgeTextAlerts {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- Alerts, digests and the tick screens ---------------------------
    $catalogue['tick.uncategorised'] = @{ ar = 'غير مصنّف'; en = 'Uncategorised' }
    $catalogue['tick.newsTicker'] = @{ ar = 'شريط الأخبار'; en = 'the news ticker' }
    $catalogue['tick.bulletin'] = @{ ar = 'الموجز'; en = 'the bulletin' }
    $catalogue['tick.scheduling'] = @{ ar = 'الجدولة'; en = 'scheduling' }
    $catalogue['tick.accessRequest'] = @{ ar = 'طلب صلاحية'; en = 'an access request' }
    $catalogue['tick.resumeWhereLeft'] = @{ ar = '↩️ استئناف من حيث توقفت'; en = '↩️ Resume where you left off' }
    $catalogue['tick.menu'] = @{ ar = '⬅️ القائمة'; en = '⬅️ Menu' }
    $catalogue['tick.inputTimedOut'] = @{ ar = '⌛ انتهت مهلة الإدخال ولم يُنفّذ شيء.'; en = '⌛ The input timed out and nothing was done.' }
    $catalogue['tick.textNotArrived'] = @{ ar = '⏳ لم يصل نصّك بعد، وستُلغى العملية بعد دقيقة. أرسل النص الآن أو اضغط «تمديد».'; en = '⏳ Your text has not arrived, and the operation will be cancelled in a minute. Send it now, or press "extend".' }
    $catalogue['tick.extend'] = @{ ar = '⏳ تمديد'; en = '⏳ Extend' }
    $catalogue['tick.cancel'] = @{ ar = '❌ إلغاء'; en = '❌ Cancel' }
    $catalogue['tick.shortenSaveFailed'] = @{ ar = '⚠️ تعذّر حفظ التقصير؛ بقي الموعد السابق.'; en = '⚠️ Could not save the shortening; the previous time stands.' }
    $catalogue['tick.choiceSaveFailed'] = @{ ar = '⚠️ تعذّر حفظ الاختيار؛ لم يتغير موعد الإخفاء.'; en = '⚠️ Could not save the choice; the hide time is unchanged.' }
    $catalogue['tick.minusMinute'] = @{ ar = '− دقيقة'; en = '− a minute' }
    $catalogue['tick.plusMinute'] = @{ ar = '+ دقيقة'; en = '+ a minute' }
    $catalogue['tick.minus10s'] = @{ ar = '−10 ث'; en = '−10s' }
    $catalogue['tick.plus10s'] = @{ ar = '+10 ث'; en = '+10s' }
    $catalogue['tick.confirmExtension'] = @{ ar = 'تأكيد التمديد'; en = 'Confirm the extension' }
    $catalogue['tick.fiveMinutes'] = @{ ar = '٥ دقائق'; en = 'Five minutes' }
    $catalogue['tick.customDuration'] = @{ ar = 'مدة مخصصة'; en = 'A custom time' }
    $catalogue['tick.hideNow'] = @{ ar = 'إخفاء الآن'; en = 'Hide it now' }
    $catalogue['tick.layerGone'] = @{ ar = 'لم تعد الطبقة على الهواء.'; en = 'The layer is no longer on air.' }
    $catalogue['tick.sceneChanged'] = @{ ar = 'تغيّر المشهد على الطبقة.'; en = 'The scene on the layer changed.' }
    $catalogue['tick.templateChanged'] = @{ ar = 'تغيّر القالب على الطبقة.'; en = 'The template on the layer changed.' }
    $catalogue['tick.becameLongRun'] = @{ ar = 'القالب أصبح Long run.'; en = 'The template became a long run.' }
    $catalogue['tick.noticeStopped'] = @{ ar = 'أُوقف تنبيه الظهور للقالب.'; en = 'The show notice for the template was turned off.' }
    $catalogue['tick.remindLater'] = @{ ar = '⏰ ذكّرني لاحقًا'; en = '⏰ Remind me later' }
    $catalogue['tick.hideTemplate'] = @{ ar = '🙈 إخفاء القالب'; en = '🙈 Hide the template' }
    $catalogue['tick.recentStart'] = @{ ar = '🟠 التشغيل حديث — قد يكون الجسر يُعاد تشغيله'; en = '🟠 Recently started — the bridge may be restarting' }
    $catalogue['tick.telegramLimiting'] = @{ ar = '🟠 تيليجرام يحدّ من الإرسال'; en = '🟠 Telegram is rate limiting' }
    $catalogue['tick.stableRun'] = @{ ar = '🟢 تشغيل مستقر'; en = '🟢 Running steadily' }
    $catalogue['tick.notSentYet'] = @{ ar = 'لم تُرسل بعد'; en = 'Not sent yet' }
    $catalogue['tick.uptime'] = @{ ar = '⏱ مدة التشغيل'; en = '⏱ Uptime' }
    $catalogue['tick.since'] = @{ ar = '📅 منذ'; en = '📅 Since' }
    $catalogue['tick.airOperations'] = @{ ar = '🎬 عمليات الهواء'; en = '🎬 Air operations' }
    $catalogue['tick.telegramLimit'] = @{ ar = '🚦 حدّ تيليجرام (429)'; en = '🚦 Telegram limit (429)' }
    $catalogue['tick.droppedFromQueue'] = @{ ar = '📭 أُسقطت من الطابور'; en = '📭 Dropped from the queue' }
    $catalogue['tick.telegramConnection'] = @{ ar = '📡 اتصال Telegram'; en = '📡 Telegram connection' }
    $catalogue['tick.cinegyHealth'] = @{ ar = '🎛 صحة Cinegy'; en = '🎛 Cinegy health' }
    $catalogue['tick.lastHeartbeat'] = @{ ar = '💚 آخر نبضة يومية'; en = '💚 Last daily heartbeat' }
    $catalogue['tick.scenesOnAir'] = @{ ar = '🔴 مشاهد على الهواء'; en = '🔴 Scenes on air' }
    $catalogue['tick.largestScreen'] = @{ ar = '📐 أكبر شاشة أُرسلت'; en = '📐 Largest screen sent' }
    $catalogue['tick.col.item'] = @{ ar = 'البند'; en = 'Item' }
    $catalogue['tick.col.value'] = @{ ar = 'القيمة'; en = 'Value' }
    $catalogue['tick.nothingOnAir'] = @{ ar = 'لا شيء على الهواء.'; en = 'Nothing is on air.' }
    $catalogue['tick.nothingOnAirNow'] = @{ ar = '⚫️ لا شيء على الهواء الآن'; en = '⚫️ Nothing on air right now' }
    $catalogue['tick.nothingInPeriod'] = @{ ar = 'لا شيء مسجّل في هذه الفترة.'; en = 'Nothing was recorded in this period.' }
    $catalogue['tick.nothingInPeriodHtml'] = @{ ar = '<i>لا شيء مسجّل في هذه الفترة.</i>'; en = '<i>Nothing was recorded in this period.</i>' }
    $catalogue['tick.col.template'] = @{ ar = 'القالب'; en = 'Template' }
    $catalogue['tick.col.times'] = @{ ar = 'مرات'; en = 'Times' }
    $catalogue['tick.col.last'] = @{ ar = 'آخرها'; en = 'Last' }
    $catalogue['tick.col.operator'] = @{ ar = 'المشغّل'; en = 'Operator' }
    $catalogue['tick.noDetail'] = @{ ar = 'بلا تفصيل'; en = 'No detail' }
    $catalogue['tick.worthAttention'] = @{ ar = '<b>📌 أحداث تستحق الانتباه</b>'; en = '<b>📌 Events worth noticing</b>' }
    $catalogue['tick.noRecordKept'] = @{ ar = 'لا يوجد سجل ضمن ما هو محفوظ.'; en = 'There is no record within what is kept.' }
    $catalogue['tick.col.when'] = @{ ar = 'متى'; en = 'When' }
    $catalogue['tick.col.operation'] = @{ ar = 'العملية'; en = 'Operation' }
    $catalogue['tick.col.result'] = @{ ar = 'النتيجة'; en = 'Result' }
    $catalogue['tick.questionMark'] = @{ ar = '؟'; en = '?' }
    $catalogue['tick.whoUsage'] = @{ ar = 'اكتب اسم القالب بعد الأمر، مثل: /who الانتخابات'; en = 'Type the template name after the command, for example: /who Elections' }
    $catalogue['tick.openDraft'] = @{ ar = '📰 فتح المسودة'; en = '📰 Open the draft' }
    $catalogue['tick.resumeDraft'] = @{ ar = '↩️ استئناف المسودة'; en = '↩️ Resume the draft' }
    $catalogue['tick.reason.wrongTemplate'] = @{ ar = 'قالب خاطئ'; en = 'the wrong template' }
    $catalogue['tick.reason.wrongTiming'] = @{ ar = 'توقيت خاطئ'; en = 'the wrong timing' }
    $catalogue['tick.reason.directorAsked'] = @{ ar = 'طلب المخرج'; en = 'the director asked' }
    $catalogue['tick.reason.other'] = @{ ar = 'سبب آخر'; en = 'another reason' }
    $catalogue['tick.reasonBtn.wrongTemplate'] = @{ ar = '🎬 قالب خاطئ'; en = '🎬 Wrong template' }
    $catalogue['tick.reasonBtn.wrongTiming'] = @{ ar = '⏱ توقيت خاطئ'; en = '⏱ Wrong timing' }
    $catalogue['tick.reasonBtn.directorAsked'] = @{ ar = '🎧 طلب المخرج'; en = '🎧 The director asked' }
    $catalogue['tick.reasonBtn.other'] = @{ ar = '❔ سبب آخر'; en = '❔ Another reason' }
    $catalogue['tick.skip'] = @{ ar = 'تخطٍّ'; en = 'Skip' }
    $catalogue['tick.usageDigest'] = @{ ar = '📊 ملخص الاستخدام'; en = '📊 Usage digest' }
    $catalogue['tick.noTemplatesUsed'] = @{ ar = 'لم تُستخدم أي قوالب بعد.'; en = 'No templates have been used yet.' }
    $catalogue['tick.noTemplatesUsedHtml'] = @{ ar = '<i>لم تُستخدم أي قوالب بعد.</i>'; en = '<i>No templates have been used yet.</i>' }
    $catalogue['tick.col.lastTime'] = @{ ar = 'آخر مرة'; en = 'Last time' }
    $catalogue['tick.col.count'] = @{ ar = 'العدد'; en = 'Count' }
    $catalogue['tick.successful'] = @{ ar = '✅ ناجحة'; en = '✅ succeeded' }
    $catalogue['tick.failed'] = @{ ar = '❌ فاشلة'; en = '❌ failed' }
    $catalogue['tick.refused'] = @{ ar = '⛔ مرفوضة'; en = '⛔ refused' }
    $catalogue['tick.checkAudit'] = @{ ar = 'راجع 📜 السجل لمعرفة سبب الفشل أو الرفض.'; en = 'Check 📜 the audit for why it failed or was refused.' }
    $catalogue['tick.checkAuditHtml'] = @{ ar = '<i>راجع 📜 السجل لمعرفة سبب الفشل أو الرفض.</i>'; en = '<i>Check 📜 the audit for why it failed or was refused.</i>' }
    $catalogue['tick.undoReason'] = @{ ar = 'سبب التراجع'; en = 'Undo reason' }
    $catalogue['tick.never'] = @{ ar = 'أبدًا'; en = 'Never' }
    $catalogue['tick.whatBridgeNoticed'] = @{ ar = '👁 ما لاحظه الجسر'; en = '👁 What the bridge noticed' }
    $catalogue['tick.whatBridgeNoticedHtml'] = @{ ar = '<b>👁 ما لاحظه الجسر</b>'; en = '<b>👁 What the bridge noticed</b>' }
    $catalogue['tick.usageDigestHtml'] = @{ ar = '<b>📊 ملخص الاستخدام</b>'; en = '<b>📊 Usage digest</b>' }
    $catalogue['tick.mostUsed'] = @{ ar = '<b>🏆 الأكثر استخدامًا</b> (تراكمي)'; en = '<b>🏆 Most used</b> (all time)' }
    $catalogue['tick.undoReasonsHtml'] = @{ ar = '<b>↩️ أسباب التراجع المسجّلة</b>'; en = '<b>↩️ Recorded undo reasons</b>' }
    $catalogue['tick.publishTiming'] = @{ ar = '⏱ زمن النشر والمسودات'; en = '⏱ Publish and draft timing' }
    $catalogue['tick.publishTimingHtml'] = @{ ar = '<b>⏱ زمن النشر والمسودات</b>'; en = '<b>⏱ Publish and draft timing</b>' }
    $catalogue['tick.noLocalCopy'] = @{ ar = 'بلا نسخة محلية'; en = 'no local copy' }
    $catalogue['tick.status'] = @{ ar = 'ℹ️ الحالة'; en = 'ℹ️ Status' }
    $catalogue['tick.stillOnAirRepeat'] = @{ ar = '⚠️ <b>ما زال على الهواء</b> — تنبيه متكرّر:'; en = '⚠️ <b>Still on air</b> — a repeated warning:' }
    $catalogue['tick.longOnAir'] = @{ ar = '⚠️ سجلات على الهواء منذ وقت طويل — تحقّق من الشاشة:'; en = '⚠️ Records on air for a long time — check the screen:' }
    $catalogue['tick.unreachable'] = @{ ar = 'تعذّر الوصول'; en = 'unreachable' }
    $catalogue['tick.unhealthy'] = @{ ar = 'غير سليم'; en = 'unhealthy' }
    $catalogue['tick.cinegyRecovered'] = @{ ar = '💚 تعافت صحة Cinegy'; en = '💚 Cinegy health recovered' }
    $catalogue['tick.belowThreshold'] = @{ ar = 'لم يبلغ الخلل حدّ التنبيه، فلم يُرسل تحذير عند بدايته.'; en = 'The fault never reached the alert threshold, so no warning was sent when it began.' }
    $catalogue['tick.unhealthyReadings'] = @{ ar = 'قياسات غير سليمة'; en = 'unhealthy readings' }
    $catalogue['tick.cinegyUnreachable'] = @{ ar = 'تعذّر الوصول إلى قياسات صحة Cinegy. تحقق من Air والاتصال بالشبكة.'; en = 'The Cinegy health counters could not be reached. Check Air and the network.' }
    $catalogue['tick.telegramRecovered'] = @{ ar = '✅ استعاد البوت اتصال Telegram وعادت دورة التحديث للعمل.'; en = '✅ The bot regained its Telegram connection and the update cycle is running again.' }
    $catalogue['tick.sheetSync'] = @{ ar = 'مزامنة الشيت'; en = 'the sheet sync' }
    $catalogue['tick.neverSucceeded'] = @{ ar = 'ولم تنجح ولا مرة منذ إقلاع الجسر.'; en = 'and has not succeeded once since the bridge started.' }
    $catalogue['tick.tickerStale'] = @{ ar = 'الشريط على الهواء ما زال على آخر نص نُشر — تعديلات الشيت لا تصل.'; en = 'The ticker on air is still on the last published text — sheet edits are not arriving.' }
}
