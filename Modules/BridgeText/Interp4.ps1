#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the health centre and the status screen, and the air
    operation itself: every sentence a SHOW can come back with, from a
    reserved layer to a scene file that moved.
#>

function Add-BridgeTextInterp4 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['hlth.docVersion'] = @{ ar = '📄 توثيق Cinegy المرجعي مبنيّ على {0}، والمثبَّت هنا {1} ({2}) — قِس أي قدرة جديدة على الجهاز قبل بنائها، فقد لا تكون موجودة بعد.'; en = '📄 The Cinegy reference documentation is written against {0}, and what is installed here is {1} ({2}) — measure any new capability on the machine before building on it, as it may not be there yet.' }
    $catalogue['hlth.fullState'] = @{ ar = '<b>📊 الحالة الكاملة</b> — <code>v{0}</code>'; en = '<b>📊 The full state</b> — <code>v{0}</code>' }
    $catalogue['hlth.localTime'] = @{ ar = '🕒 <code>{0}</code> (محلي)'; en = '🕒 <code>{0}</code> (local)' }
    $catalogue['hlth.yourId'] = @{ ar = '👤 معرّفك: {0}'; en = '👤 Your id: {0}' }
    $catalogue['hlth.engine'] = @{ ar = '🌐 <code>{0}</code> · القناة <code>{1}</code> · القوالب: <code>{2}</code>'; en = '🌐 <code>{0}</code> · channel <code>{1}</code> · templates: <code>{2}</code>' }
    $catalogue['hlth.sceneMode'] = @{ ar = '🧩 وضع المشاهد المختار: <code>{0}</code> · {1}'; en = '🧩 The chosen scene mode: <code>{0}</code> · {1}' }
    $catalogue['hlth.dataState'] = @{ ar = '📶 حالة بيانات Cinegy: <b>{0}</b>'; en = '📶 The state of the Cinegy data: <b>{0}</b>' }
    $catalogue['hlth.liveFeed'] = @{ ar = '📡 البث المباشر: {0}'; en = '📡 The live feed: {0}' }
    $catalogue['hlth.pending'] = @{ ar = '🖼 الصور المعلّقة: <code>{0}</code> · مؤقتات الإخفاء: <code>{1}</code> · تنبيهات الظهور: <code>{2}</code>'; en = '🖼 Pictures waiting: <code>{0}</code> · hide timers: <code>{1}</code> · appearance alerts: <code>{2}</code>' }
    $catalogue['hlth.upcoming'] = @{ ar = '🗓 الأحداث المجدولة القادمة: <code>{0}</code>'; en = '🗓 Upcoming scheduled events: <code>{0}</code>' }
    $catalogue['hlth.authorised'] = @{ ar = '🔐 المستخدمون المصرح لهم: <code>{0}</code> محادثة / <code>{1}</code> مستخدم'; en = '🔐 Authorised: <code>{0}</code> chats / <code>{1}</code> users' }
    $catalogue['hlth.pendingRequests'] = @{ ar = '🔔 طلبات الوصول المعلّقة: <code>{0}</code>'; en = '🔔 Pending access requests: <code>{0}</code>' }
    $catalogue['hlth.layerCheckFailed'] = @{ ar = '⚠️ تعذّر فحص طبقات Cinegy: {0} — تم الاحتفاظ بالحالة السابقة.'; en = '⚠️ The Cinegy layers could not be checked: {0} — the earlier state was kept.' }
    $catalogue['hlth.removedHidden'] = @{ ar = '🔄 أُزيلت الطبقات المخفية خارجيًا: {0}'; en = '🔄 The layers hidden from outside were removed: {0}' }
    $catalogue['hlth.bytes'] = @{ ar = '{0} بايت'; en = '{0} bytes' }
    $catalogue['hlth.filesNeedYou'] = @{ ar = '🔴 ملفات تحتاج انتباهك: {0}'; en = '🔴 Files that need your attention: {0}' }
    $catalogue['hlth.lastWritten'] = @{ ar = '{0} · آخر كتابة {1}'; en = '{0} · last written {1}' }
    $catalogue['hlth.filesNeedYouHtml'] = @{ ar = '<b>🔴 ملفات تحتاج انتباهك:</b> <code>{0}</code>'; en = '<b>🔴 Files that need your attention:</b> <code>{0}</code>' }
    $catalogue['hlth.soundOrUnwritten'] = @{ ar = '<b>سليمة أو لم تُكتب بعد ({0}):</b>'; en = '<b>Sound, or not written yet ({0}):</b>' }
    $catalogue['hlth.alarmOn'] = @{ ar = 'إنذار نشط (فشل متتالٍ: {0})'; en = 'an alarm is on (failures in a row: {0})' }
    $catalogue['hlth.gbFree'] = @{ ar = '{0} GB متاح'; en = '{0} GB free' }
    $catalogue['hlth.pair'] = @{ ar = '{0} — {1}'; en = '{0} — {1}' }
    $catalogue['hlth.pausedNext'] = @{ ar = 'متوقفة مؤقتًا — {0} قادم'; en = 'paused — {0} upcoming' }
    $catalogue['hlth.next'] = @{ ar = '{0} قادم'; en = '{0} upcoming' }
    $catalogue['hlth.usage'] = @{ ar = '📈 الاستخدام: {0} اليوم · {1} · {2} على الهواء'; en = '📈 Usage: {0} today · {1} · {2} on air' }
    $catalogue['hlth.needsYou'] = @{ ar = "<b>⚠️ يحتاج انتباهك ({0})</b>`n{1}`n"; en = "<b>⚠️ Needs your attention ({0})</b>`n{1}`n" }
    $catalogue['hlth.sound'] = @{ ar = "<b>✅ سليم ({0})</b>`n{1}{2}</blockquote>"; en = "<b>✅ Sound ({0})</b>`n{1}{2}</blockquote>" }
    $catalogue['hlth.usageHtml'] = @{ ar = '<b>📈 الاستخدام</b>: <code>{0}</code> عملية اليوم · <code>{1}</code> مشغّل · <code>{2}</code> على الهواء'; en = '<b>📈 Usage</b>: <code>{0}</code> operations today · <code>{1}</code> operators · <code>{2}</code> on air' }
    $catalogue['hlth.sinceLastCheck'] = @{ ar = ' (+{0} منذ آخر فحص)'; en = ' (+{0} since the last check)' }
    $catalogue['hlth.frames'] = @{ ar = '🎞 الإطارات — المخرَجة: {0} · الساقطة: {1}{2}'; en = '🎞 Frames — out: {0} · dropped: {1}{2}' }
    $catalogue['hlth.readTimes'] = @{ ar = '⏱ متوسط القراءة: {0}ms · أخطاء القراءة: {1}%'; en = '⏱ Mean read: {0}ms · read errors: {1}%' }
    $catalogue['hlth.licence'] = @{ ar = '📄 الترخيص: {0}'; en = '📄 Licence: {0}' }
    $catalogue['hlth.licenceWarning'] = @{ ar = '📄 الترخيص: <b>{0}</b> — تحقق من ترخيص المحرك'; en = '📄 Licence: <b>{0}</b> — check the engine licence' }
    $catalogue['hlth.trialLayerInUse'] = @{ ar = '❌ طبقة التجربة {0} مستخدمة كطبقة إنتاج في سجل القوالب. اختر طبقة مستقلة.'; en = '❌ The trial layer {0} is used as a production layer in the template register. Choose a layer of its own.' }
    $catalogue['hlth.testReview'] = @{ ar = "🧪 مراجعة اختبار القالب '{0}'`nطبقة التجربة المستقلة: {1}`nقيم الحقول: TEST`nالإخفاء التلقائي: {2}`n`nسيُفحص أن الطبقة فارغة مباشرة قبل الاختبار."; en = "🧪 Review the test of the template '{0}'`nThe trial layer of its own: {1}`nField values: TEST`nAutomatic hide: {2}`n`nThe layer is checked to be empty right before the test." }
    $catalogue['hlth.noRestartPath'] = @{ ar = "⛔ لا توجد وسيلة لإعادة تشغيل الجسر (العملية الأصل: {0})، ولا يمكن إعادة بناء أمر التشغيل.`nالخروج الآن يعني توقف البوت نهائيًا بلا وسيلة لإعادته من هنا."; en = "⛔ There is no way to restart the bridge (the parent process: {0}), and the run command cannot be rebuilt.`nExiting now would stop the bot for good, with no way to bring it back from here." }
    $catalogue['hlth.restartWithScenes'] = @{ ar = "`n⚠️ يوجد {0} مشهدًا مسجّلًا على الهواء. إعادة التشغيل لا تغيّر ما هو على الشاشة، لكن البوت لن يستجيب لثوانٍ."; en = "`n⚠️ {0} scenes are recorded on air. A restart changes nothing on screen, but the bot will not answer for a few seconds." }
    $catalogue['hlth.confirmRestart'] = @{ ar = "♻️ تأكيد إعادة تشغيل الجسر`nستتوقف الاستجابة بضع ثوانٍ ثم يعيده {0} تلقائيًا.{1}"; en = "♻️ Confirm the bridge restart`nIt stops answering for a few seconds, then {0} brings it back by itself.{1}" }
    $catalogue['hlth.restartAudit'] = @{ ar = '♻️ إعادة تشغيل الجسر - بواسطة {0}'; en = '♻️ The bridge restarted - by {0}' }
    $catalogue['adm.sourceCinegy'] = @{ ar = '   المصدر: Cinegy Air · منذ {0}'; en = '   Source: Cinegy Air · {0} ago' }
    $catalogue['adm.event'] = @{ ar = ' · الحدث: {0}'; en = ' · the event: {0}' }
    $catalogue['adm.sourceBot'] = @{ ar = '   المصدر: Bot · المستخدم: {0} · منذ {1}'; en = '   Source: the bot · user: {0} · {1} ago' }
    $catalogue['adm.remaining'] = @{ ar = ' · تبقّى <code>{0} د</code>'; en = ' · <code>{0} min</code> left' }
    $catalogue['adm.running'] = @{ ar = '▶️ الجاري: {0}'; en = '▶️ Running: {0}' }
    $catalogue['adm.nextUp'] = @{ ar = '⏭ التالي: {0}'; en = '⏭ Next: {0}' }
    $catalogue['adm.repeats'] = @{ ar = '🔁 يتكرر: {0} ({1})'; en = '🔁 Repeats: {0} ({1})' }
    $catalogue['adm.layersOnAirNow'] = @{ ar = '🟠 طبقات على الهواء الآن: <code>{0}</code> — راجعها قبل أن تلمس شيئًا.'; en = '🟠 Layers on air right now: <code>{0}</code> — look at them before you touch anything.' }
    $catalogue['adm.pendingOps'] = @{ ar = '⏳ عمليات معلقة بانتظار أصحابها: <code>{0}</code>.'; en = '⏳ Operations waiting on the person who started them: <code>{0}</code>.' }
    $catalogue['adm.openDraft'] = @{ ar = '📰 مسودة شريط مفتوحة ({0}).'; en = '📰 A ticker draft is open ({0}).' }
    $catalogue['adm.quarantined'] = @{ ar = '💀 محادثات محجورة بانتظار قرار: <code>{0}</code>.'; en = '💀 Quarantined chats waiting on a decision: <code>{0}</code>.' }
    $catalogue['adm.pinnedFaults'] = @{ ar = '📌 أعطال مثبّتة لم تُحل: <code>{0}</code>.'; en = '📌 Pinned faults not yet settled: <code>{0}</code>.' }
    $catalogue['adm.protectionsOff'] = @{ ar = '🛡 <b>حمايات معطّلة</b> (<code>{0}</code>) — اختيار إعداد، لا عطل:'; en = '🛡 <b>Protections turned off</b> (<code>{0}</code>) — a choice in the settings, not a fault:' }
    $catalogue['adm.since'] = @{ ar = ' · منذ {0}'; en = ' · {0} ago' }
    $catalogue['adm.layerRow'] = @{ ar = '• طبقة {0} · {1}{2}{3}'; en = '• layer {0} · {1}{2}{3}' }
    $catalogue['adm.state'] = @{ ar = '<b>ℹ️ الحالة</b> — <code>v{0}</code>'; en = '<b>ℹ️ The state</b> — <code>v{0}</code>' }
    $catalogue['adm.localTime'] = @{ ar = '🕒 <code>{0}</code> (محلي)'; en = '🕒 <code>{0}</code> (local)' }
    $catalogue['adm.yourId'] = @{ ar = '👤 معرّفك: {0}'; en = '👤 Your id: {0}' }
    $catalogue['adm.engine'] = @{ ar = '🌐 <code>{0}</code> · القناة <code>{1}</code> · القوالب: <code>{2}</code>'; en = '🌐 <code>{0}</code> · channel <code>{1}</code> · templates: <code>{2}</code>' }
    $catalogue['adm.layerPair'] = @{ ar = 'طبقة {0}: {1}'; en = 'layer {0}: {1}' }
    $catalogue['adm.sharedLayers'] = @{ ar = '⚠️ قوالب تتشارك الطبقة نفسها ولا يمكن عرضها معًا: {0}'; en = '⚠️ Templates that share a layer and cannot be shown together: {0}' }
    $catalogue['adm.dataState'] = @{ ar = '📶 حالة بيانات Cinegy: <b>{0}</b>'; en = '📶 The state of the Cinegy data: <b>{0}</b>' }
    $catalogue['adm.ago'] = @{ ar = 'منذ {0}'; en = '{0} ago' }
    $catalogue['adm.lastGoodCheck'] = @{ ar = '🔄 آخر فحص ناجح: <i>{0}</i> (<code>{1}</code>)'; en = '🔄 The last check that passed: <i>{0}</i> (<code>{1}</code>)' }
    $catalogue['adm.layerCheckFailed'] = @{ ar = '⚠️ تعذّر فحص طبقات Cinegy: {0} — تم الاحتفاظ بالحالة السابقة.'; en = '⚠️ The Cinegy layers could not be checked: {0} — the earlier state was kept.' }
    $catalogue['adm.stateRefreshed'] = @{ ar = '🔄 تم تحديث الحالة وأُزيلت الطبقات المخفية خارجيًا: {0}'; en = '🔄 The state was refreshed and the layers hidden from outside removed: {0}' }
    $catalogue['adm.confirmHideAll'] = @{ ar = '⚠️ سيتم إخفاء الطبقات المحددة: {0}. هل أنت متأكد؟'; en = '⚠️ The chosen layers will be hidden: {0}. Are you sure?' }
    $catalogue['adm.cinegyUnreachable'] = @{ ar = '❌ Cinegy: {0}ms — تعذّر الوصول'; en = '❌ Cinegy: {0}ms — could not be reached' }
    $catalogue['adm.healthDetail'] = @{ ar = '{0} — آخر نجاح: {1} | آخر خطأ: {2} | فشل متتالٍ: {3} | بداية الانقطاع: {4}'; en = '{0} — last pass: {1} | last error: {2} | failures in a row: {3} | the outage began: {4}' }
    $catalogue['adm.templateDetail'] = @{ ar = '📚 تفاصيل القالب: {0}'; en = '📚 Template details: {0}' }
    $catalogue['adm.path'] = @{ ar = 'المسار: {0}'; en = 'Path: {0}' }
    $catalogue['adm.layer'] = @{ ar = 'الطبقة: {0}'; en = 'Layer: {0}' }
    $catalogue['adm.order'] = @{ ar = 'الترتيب: {0}'; en = 'Order: {0}' }
    $catalogue['adm.description'] = @{ ar = 'الوصف: {0}'; en = 'Description: {0}' }
    $catalogue['adm.fields'] = @{ ar = 'الحقول: {0}'; en = 'Fields: {0}' }
    $catalogue['adm.readyTexts'] = @{ ar = 'النصوص الجاهزة: {0}'; en = 'Ready-made texts: {0}' }
    $catalogue['adm.alertAfter'] = @{ ar = 'بعد {0} دقيقة للشخص الذي أظهر القالب.'; en = '{0} minutes later, to whoever put the template on air.' }
    $catalogue['adm.appearAlert'] = @{ ar = '🔔 تنبيه الظهور: {0}'; en = '🔔 The appearance alert: {0}' }
    $catalogue['adm.longRunNoAlert'] = @{ ar = '🔔 ''{0}'' قالب Long run يعمل 24/7، لذلك تنبيه الظهور الشخصي معطّل.'; en = '🔔 ''{0}'' is a long-run template that runs 24/7, so the personal appearance alert is off.' }
    $catalogue['adm.sendAlertMinutes'] = @{ ar = "🔔 أرسل مدة التنبيه لقالب '{0}' بالدقائق من 0 إلى 1440.`nأرسل 0 لإيقاف التنبيه."; en = "🔔 Send the alert delay for the template '{0}' in minutes, from 0 to 1440.`nSend 0 to turn the alert off." }
    $catalogue['air.layer'] = @{ ar = ' · طبقة {0}'; en = ' · layer {0}' }
    $catalogue['air.left'] = @{ ar = '⏱ بقي {0}'; en = '⏱ {0} left' }
    $catalogue['air.endedOutside'] = @{ ar = '⚠️ انتهى من جهة Cinegy لا من الجسر.'; en = '⚠️ It ended from the Cinegy side, not through the bridge.' }
    $catalogue['air.autoHideAfter'] = @{ ar = '⏱ يُخفى تلقائيًا بعد {0}'; en = '⏱ Hidden by itself after {0}' }
    $catalogue['air.whileBusyCount'] = @{ ar = '📣 <b>حدث أثناء انشغالك ({0}):</b>'; en = '📣 <b>While you were busy ({0}):</b>' }
    $catalogue['air.by'] = @{ ar = ' بواسطة {0}'; en = ' by {0}' }
    $catalogue['air.changedWhileYouWorked'] = @{ ar = "⚠️ <b>{0} {1}{2} أثناء تجهيزك.</b>`nراجع ما أعددته قبل الإرسال — قد يكون ما على الشاشة قد تغيّر."; en = "⚠️ <b>{0} {1}{2} while you were getting ready.</b>`nLook over what you prepared before you send it — what is on screen may have changed." }
    $catalogue['air.maintenanceWindow'] = @{ ar = '🛠 نافذة الصيانة المجدولة مفتوحة ({0}–{1})؛ أوامر الهواء متوقفة حتى نهايتها.'; en = '🛠 The scheduled maintenance window is open ({0}–{1}); the air commands are stopped until it ends.' }
    $catalogue['air.layerReserved'] = @{ ar = 'الطبقة {0} محجوزة إداريًا.'; en = 'Layer {0} is reserved by the administration.' }
    $catalogue['air.layerReservedOverride'] = @{ ar = '⚠️ الطبقة {0} محجوزة — تتجاوزها بصلاحية المشرف.'; en = '⚠️ Layer {0} is reserved — you pass it with the administrator right.' }
    $catalogue['air.templateDisabled'] = @{ ar = 'القالب ''{0}'' معطّل مؤقتًا.'; en = 'The template ''{0}'' is turned off for now.' }
    $catalogue['air.durationLowered'] = @{ ar = '⏱ المدة المطلوبة {0} ثانية؛ خُفّضت إلى {1} ثانية — {2}.'; en = '⏱ The duration asked for was {0} seconds; it came down to {1} seconds — {2}.' }
    $catalogue['air.sceneNameMismatch'] = @{ ar = 'اسم المشهد الذي أعاده Cinegy لا يطابق ''{0}''.'; en = 'The scene name Cinegy returned does not match ''{0}''.' }
    $catalogue['air.templateUnknown'] = @{ ar = 'القالب ''{0}'' غير معروف.'; en = 'The template ''{0}'' is not known.' }
    $catalogue['air.notSent'] = @{ ar = '⛔ لم يتم الإرسال: {0}'; en = '⛔ Nothing was sent: {0}' }
    $catalogue['air.notSentLayerUnsure'] = @{ ar = '⛔ لم يتم الإرسال: تعذّر التحقق من حالة طبقة Cinegy {0}. أعد فحص الحالة ثم حاول مجددًا.'; en = '⛔ Nothing was sent: the state of Cinegy layer {0} could not be checked. Read the state again, then try once more.' }
    $catalogue['air.unusualRepeat'] = @{ ar = "🔁 تكرار غير معتاد: عُرض '{0}' عدة مرات خلال فترة قصيرة.`nهل هذا مقصود؟ إن لم يكن، اضغط ↩️ تراجع من القائمة."; en = "🔁 An unusual repeat: '{0}' went on air several times in a short stretch.`nIs that meant? If not, press ↩️ Undo in the menu." }
    $catalogue['air.showAudit'] = @{ ar = '▶ {0} (طبقة {1}) - بواسطة {2}'; en = '▶ {0} (layer {1}) - by {2}' }
    $catalogue['air.willAutoHide'] = @{ ar = ' سيُخفى تلقائيًا بعد {0}.'; en = ' It hides by itself after {0}.' }
    $catalogue['air.personalAlertAfter'] = @{ ar = ' سيصل إليك تنبيه شخصي بعد {0} إذا بقي القالب ظاهرًا.'; en = ' A personal alert reaches you after {0} if the template is still showing.' }
    $catalogue['air.shown'] = @{ ar = '✅ تم إظهار ''{0}'' على الهواء (طبقة {1}).{2}'; en = '✅ ''{0}'' is on air (layer {1}).{2}' }
    $catalogue['air.showFailed'] = @{ ar = '❌ فشل إظهار ''{0}'': {1}'; en = '❌ ''{0}'' could not be put on air: {1}' }
    $catalogue['air.templateGone'] = @{ ar = '❌ القالب <code>{0}</code> لم يعد في سجل القوالب — حُذف أو أُعيدت تسميته.'; en = '❌ The template <code>{0}</code> is no longer in the register — it was deleted or renamed.' }
    $catalogue['air.staleState'] = @{ ar = '⚠️ حالة Cinegy متأخرة ({0}) — قد يكون المحرّك مشغولًا أو الشبكة بطيئة.'; en = '⚠️ The Cinegy state is behind ({0}) — the engine may be busy, or the network slow.' }
    $catalogue['air.sceneFileMissing'] = @{ ar = '❌ ملف المشهد غير موجود: <code>{0}</code> — نُقل أو أُعيدت تسميته أو تعذّر الوصول إلى المشاركة.'; en = '❌ The scene file is not there: <code>{0}</code> — it moved, was renamed, or the share cannot be reached.' }
    $catalogue['air.layerHeldBy'] = @{ ar = '⚠️ الطبقة {0} محجوزة الآن لـ{1} — انتظر أو اطلب منه الإنهاء.'; en = '⚠️ Layer {0} is held right now by {1} — wait, or ask them to finish.' }
    $catalogue['air.layerOccupied'] = @{ ar = 'ℹ️ الطبقة {0} عليها الآن <code>{1}</code> — العرض يستبدله لا يُضاف فوقه.'; en = 'ℹ️ Layer {0} currently carries <code>{1}</code> — showing replaces it rather than adding on top.' }
    $catalogue['air.layerEmpty'] = @{ ar = '✅ الطبقة {0} خالية.'; en = '✅ Layer {0} is empty.' }
    $catalogue['air.templateForbidden'] = @{ ar = '⛔ القالب ممنوع عليك: {0}'; en = '⛔ This template is not yours to use: {0}' }
    $catalogue['air.layerAlsoShared'] = @{ ar = 'ℹ️ يتشارك الطبقة {0} أيضًا: {1} — لا يظهر اثنان منها معًا.'; en = 'ℹ️ Layer {0} is also shared by: {1} — no two of them show together.' }
    $catalogue['air.whyNotShownTitle'] = @{ ar = '<b>🔍 لماذا لم يظهر ''{0}''؟</b>'; en = '<b>🔍 Why did ''{0}'' not appear?</b>' }
}
