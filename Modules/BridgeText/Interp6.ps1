#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the answers to a button press, the show flow from the
    first field to the safe undo, and the commands with the settings editor
    and the raw command.
#>

function Add-BridgeTextInterp6 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['cb.draftLoaded'] = @{ ar = '📝 حُمّل {0} خبرًا في المسودة. راجعها ثم اضغط «مراجعة ونشر».'; en = '📝 {0} headlines were loaded into the draft. Look them over, then press "Review and publish".' }
    $catalogue['cb.draftPreview'] = @{ ar = "👁 معاينة المسودة ({0}):`n{1}"; en = "👁 A look at the draft ({0}):`n{1}" }
    $catalogue['cb.confirmPublish'] = @{ ar = '⚠️ تأكيد نشر {0} خبرًا إلى الملف الحي؟'; en = '⚠️ Publish {0} headlines to the live file?' }
    $catalogue['cb.notPublished'] = @{ ar = '❌ لم يتم النشر: {0}'; en = '❌ Nothing was published: {0}' }
    $catalogue['cb.tickerRestoreAudit'] = @{ ar = '📰 استعادة نسخة شريط الأخبار بواسطة {0}'; en = '📰 A news ticker backup restored by {0}' }
    $catalogue['cb.restoreFailed'] = @{ ar = '❌ فشلت الاستعادة: {0}'; en = '❌ The restore failed: {0}' }
    $catalogue['cb.sendValueFor'] = @{ ar = 'أرسل قيمة «{0}»'; en = 'Send the value for "{0}"' }
    $catalogue['cb.sendRow'] = @{ ar = 'أرسل الصفّ: {0}'; en = 'Send the row: {0}' }
    $catalogue['cb.fieldsInSceneOrder'] = @{ ar = 'الحقول بترتيب المشهد مفصولة بـ | : {0}'; en = 'The fields in the scene order, separated by | : {0}' }
    $catalogue['cb.fillRightAudit'] = @{ ar = '🛡 صلاحية تعبئة «{0}» = {1} - بواسطة {2}'; en = '🛡 The right to fill "{0}" = {1} - by {2}' }
    $catalogue['cb.boardDeletedAudit'] = @{ ar = '🗑 حذف جدول محتوى «{0}» - بواسطة {1}'; en = '🗑 The content board "{0}" deleted - by {1}' }
    $catalogue['cb.confirmBoardDelete'] = @{ ar = '⚠️ حذف «{0}» نهائيًا مع {1} صفًّا؟'; en = '⚠️ Delete "{0}" for good, with its {1} rows?' }
    $catalogue['cb.andCancelSlots'] = @{ ar = ' وسيُلغى معه {0} موعدًا.'; en = ' and {0} slots go with it.' }
    $catalogue['cb.bulletinOnAirWhen'] = @{ ar = "📑 «{0}» على الهواء الآن.`nمتى يخرج العاجل؟"; en = "📑 `"{0}`" is on air now.`nWhen should the urgent go out?" }
    $catalogue['cb.currentDraftPreview'] = @{ ar = "<b>🔎 معاينة المسودة الحالية</b>`n`n{0}"; en = "<b>🔎 A look at the current draft</b>`n`n{0}" }
    $catalogue['cb.templatesOf'] = @{ ar = '🗂 قوالب ''{0}'':'; en = '🗂 The templates of ''{0}'':' }
    $catalogue['cb.favouritesAudit'] = @{ ar = '⭐ {0} {1} مفضلة - بواسطة {2}'; en = '⭐ {1} favourites {0} - by {2}' }
    $catalogue['cb.favouritesResult'] = @{ ar = "✅ {0}: {1} المفضلة.`n{2}"; en = "✅ {0}: {1} favourites.`n{2}" }
    $catalogue['cb.handoverAudit'] = @{ ar = '🤝 تسليم مناوبة - بواسطة {0}'; en = '🤝 A shift handover - by {0}' }
    $catalogue['cb.compareResult'] = @{ ar = '🔎 نتيجة المقارنة: أضيف {0} · أزيل {1} · تعذر {2}'; en = '🔎 The comparison: {0} added · {1} removed · {2} could not be read' }
    $catalogue['cb.quietUntilAudit'] = @{ ar = '🔇 هدوء يدوي حتى {0} - بواسطة {1}'; en = '🔇 Quiet by hand until {0} - by {1}' }
    $catalogue['cb.quietCancelledAudit'] = @{ ar = '🔊 إلغاء الهدوء اليدوي - بواسطة {0}'; en = '🔊 The quiet by hand cancelled - by {0}' }
    $catalogue['cb.languageAudit'] = @{ ar = '🌐 Language = {0} - بواسطة {1}'; en = '🌐 Language = {0} - by {1}' }
    $catalogue['cb.deadChatRevokedAudit'] = @{ ar = '💀 سحب صلاحية المحادثة الميتة {0} - بواسطة {1}'; en = '💀 The dead chat {0} had its right revoked - by {1}' }
    $catalogue['cb.userAudit'] = @{ ar = '👥 {0} المستخدم {1} - بواسطة {2}'; en = '👥 User {1} {0} - by {2}' }
    $catalogue['cb.userRevokedAudit'] = @{ ar = '👥 سحب صلاحية المستخدم {0} - بواسطة {1}'; en = '👥 User {0} had their right revoked - by {1}' }
    $catalogue['cb.userRevoked'] = @{ ar = '✅ تم سحب صلاحية المستخدم {0}.'; en = '✅ User {0}''s right was revoked.' }
    $catalogue['cb.roleAudit'] = @{ ar = '👑 {0} للمستخدم {1} - بواسطة {2}'; en = '👑 {0} for user {1} - by {2}' }
    $catalogue['cb.roleDone'] = @{ ar = '✅ تم {0} للمستخدم {1}.'; en = '✅ {0} for user {1}.' }
    $catalogue['cb.pickHour'] = @{ ar = '🕒 {0} — اختر الساعة:'; en = '🕒 {0} — choose the hour:' }
    $catalogue['cb.pickMinute'] = @{ ar = '🕒 {0} {1} — اختر الدقيقة:'; en = '🕒 {0} {1} — choose the minute:' }
    $catalogue['cb.itemWhenGraphic'] = @{ ar = "🎞 المادة: {0}`nمتى يُعرض الغرافيك؟"; en = "🎞 The item: {0}`nWhen should the graphic show?" }
    $catalogue['cb.confirmEventCancel'] = @{ ar = "هل تريد إلغاء الحدث؟`n{0}"; en = "Cancel the event?`n{0}" }
    $catalogue['cb.confirmInvalidDelete'] = @{ ar = "🗑 حذف القالب غير الصالح '{0}'؟`n{1}`nتُؤخذ نسخة احتياطية أولًا."; en = "🗑 Delete the invalid template '{0}'?`n{1}`nA backup is taken first." }
    $catalogue['cb.invalidDeletedAudit'] = @{ ar = '🧹 حذف قالب غير صالح {0} - بواسطة {1}'; en = '🧹 The invalid template {0} deleted - by {1}' }
    $catalogue['cb.deletedWithBackup'] = @{ ar = '✅ حُذف ''{0}'' مع نسخة احتياطية.'; en = '✅ ''{0}'' was deleted, with a backup.' }
    $catalogue['cb.pickAction'] = @{ ar = "⚡ {0}`nاختر العملية المطلوبة:"; en = "⚡ {0}`nChoose what to do:" }
    $catalogue['cb.sendNewNameFor'] = @{ ar = 'أرسل الاسم الجديد لـ ''{0}'':'; en = 'Send the new name for ''{0}'':' }
    $catalogue['cb.unblockAudit'] = @{ ar = '👤 رفع حظر {0} - بواسطة {1}'; en = '👤 {0} unblocked - by {1}' }
    $catalogue['cb.autoHideFor'] = @{ ar = 'المدة قبل الإخفاء التلقائي لـ ''{0}'':'; en = 'How long before ''{0}'' hides by itself:' }
    $catalogue['cb.autoHideLayer'] = @{ ar = 'المدة قبل إخفاء الطبقة {0}:'; en = 'How long before layer {0} is hidden:' }
    $catalogue['cb.sendSecondsForLayer'] = @{ ar = 'أرسل المدة بالثواني لإخفاء الطبقة {0} (رقم فقط):'; en = 'Send the seconds before layer {0} is hidden (a number alone):' }
    $catalogue['cb.noTimerForLayer'] = @{ ar = '⚠️ لا يوجد مؤقت نشط للطبقة {0}.'; en = '⚠️ No timer is running for layer {0}.' }
    $catalogue['cb.confirmHide'] = @{ ar = "⚠️ تأكيد الإخفاء`n{0}"; en = "⚠️ Confirm the hide`n{0}" }
    $catalogue['cb.confirmExit'] = @{ ar = "⚠️ تأكيد الخروج من المشهد`n{0}"; en = "⚠️ Confirm the exit from the scene`n{0}" }
    $catalogue['cb.confirmGrant'] = @{ ar = "⚠️ <b>منح الوصول إلى {0}؟</b>`nسيتمكّن من عرض الغرافيك على الهواء."; en = "⚠️ <b>Grant access to {0}?</b>`nThey will be able to put graphics on air." }
    $catalogue['cb.backupUnreadable'] = @{ ar = '❌ تعذّرت قراءة النسخة: {0}'; en = '❌ The backup could not be read: {0}' }
    $catalogue['cb.templateRestoreAudit'] = @{ ar = '🗄 استعادة نسخة قوالب - بواسطة {0}'; en = '🗄 A template backup restored - by {0}' }
    $catalogue['cb.settingsRestoreAudit'] = @{ ar = '🗄 استعادة نسخة إعدادات - بواسطة {0}'; en = '🗄 A settings backup restored - by {0}' }
    $catalogue['cb.confirmRestore'] = @{ ar = "⚠️ تأكيد استعادة النسخة '{0}'؟`n{1}`nسيتم حفظ الإعدادات الحالية أولًا، ويجب إعادة تشغيل البوت بعد الاستعادة."; en = "⚠️ Restore the backup '{0}'?`n{1}`nThe current settings are kept first, and the bot has to be restarted afterwards." }
    $catalogue['flow.someonePreparing'] = @{ ar = '⚠️ {0} يجهّز ''{1}'' على الطبقة {2} منذ {3}.'; en = '⚠️ {0} has been preparing ''{1}'' on layer {2} for {3}.' }
    $catalogue['flow.cannotPrepare'] = @{ ar = '⛔ لا يمكن تجهيز العرض: {0}'; en = '⛔ The show cannot be prepared: {0}' }
    $catalogue['flow.waitOrOther'] = @{ ar = "{0}`nانتظر أو اختر قالبًا على طبقة أخرى."; en = "{0}`nWait, or choose a template on another layer." }
    $catalogue['flow.draftKept'] = @{ ar = "{0}`nمسودتك محفوظة — حاول الاستئناف بعد أن تتحرر الطبقة."; en = "{0}`nYour draft is kept — try resuming once the layer is free." }
    $catalogue['flow.resumedExpiredAudit'] = @{ ar = '↩️ استئناف مسودة منتهية ({0}) - بواسطة {1}'; en = '↩️ An expired draft resumed ({0}) - by {1}' }
    $catalogue['flow.templateLayer'] = @{ ar = 'القالب: <b>{0}</b> · الطبقة <code>{1}</code>'; en = 'Template: <b>{0}</b> · layer <code>{1}</code>' }
    $catalogue['flow.user'] = @{ ar = 'المستخدم {0}'; en = 'user {0}' }
    $catalogue['flow.willReplace'] = @{ ar = '<b>⚠️ سيتم استبدال القالب الحالي</b>: {0} ({1})'; en = '<b>⚠️ The current template will be replaced</b>: {0} ({1})' }
    $catalogue['flow.layerShared'] = @{ ar = '<b>⚠️ هذه الطبقة يتشاركها أيضًا</b>: {0} — لا يمكن عرضها مع هذا القالب في الوقت نفسه.'; en = '<b>⚠️ This layer is also shared by</b>: {0} — they cannot be on screen with this template at the same time.' }
    $catalogue['flow.autoHideSeconds'] = @{ ar = 'الإخفاء التلقائي: <code>{0}</code> ثانية'; en = 'Hides by itself: <code>{0}</code> seconds' }
    $catalogue['flow.leftBlank'] = @{ ar = '{0}: <i>(متروك)</i>'; en = '{0}: <i>(left blank)</i>' }
    $catalogue['flow.textTooLong'] = @{ ar = '❌ النص طويل جدًا ({0} حرفًا) والحد الأقصى {1} حرفًا. أرسل نصًا أقصر.'; en = '❌ That text is too long ({0} characters) and the limit is {1}. Send a shorter one.' }
    $catalogue['flow.limitIs'] = @{ ar = '     <i>الحد: {0} حرفًا</i>'; en = '     <i>The limit: {0} characters</i>' }
    $catalogue['flow.hideAudit'] = @{ ar = '🙈 إخفاء طبقة {0} - بواسطة {1}'; en = '🙈 Layer {0} hidden - by {1}' }
    $catalogue['flow.hideNotConfirmed'] = @{ ar = "🕓 أُرسل أمر إخفاء الطبقة {0} وقبِله Cinegy، لكن لم يُؤكَّد رفعها بعد.`nتبقى معروضة هنا كأنها على الهواء حتى يصل التأكيد."; en = "🕓 The command to hide layer {0} was sent and Cinegy took it, but the layer is not confirmed down yet.`nIt stays here as though on air until the confirmation arrives." }
    $catalogue['flow.hidden'] = @{ ar = '✅ تم إخفاء الطبقة {0}.'; en = '✅ Layer {0} was hidden.' }
    $catalogue['flow.hideFailed'] = @{ ar = '❌ فشل إخفاء الطبقة {0} : {1}'; en = '❌ Layer {0} could not be hidden: {1}' }
    $catalogue['flow.exitAudit'] = @{ ar = '🚪 خروج من مشهد طبقة {0} - بواسطة {1}'; en = '🚪 An exit from the scene on layer {0} - by {1}' }
    $catalogue['flow.exited'] = @{ ar = '✅ تم الخروج من المشهد على الطبقة {0}.'; en = '✅ The scene on layer {0} was exited.' }
    $catalogue['flow.exitFailed'] = @{ ar = '❌ فشل الخروج من المشهد على الطبقة {0} : {1}'; en = '❌ The scene on layer {0} could not be exited: {1}' }
    $catalogue['flow.undoReview'] = @{ ar = "↩️ مراجعة التراجع الآمن`nالطبقة: {0}`nسيُستعاد القالب: {1}`nشرط التنفيذ: {2}`nتنتهي الصلاحية: {3}`n`nسيُفحص Cinegy مباشرة بعد التأكيد."; en = "↩️ Review the safe undo`nLayer: {0}`nThe template to be restored: {1}`nIt runs only if: {2}`nIt expires: {3}`n`nCinegy is checked right after you confirm." }
    $catalogue['flow.undoAudit'] = @{ ar = '↩️ تراجع: أُزيل {0} من طبقة {1} - بواسطة {2}'; en = '↩️ Undo: {0} removed from layer {1} - by {2}' }
    $catalogue['flow.undoAskReason'] = @{ ar = "↩️ أُزيل '{0}' من الطبقة {1}.`nما السبب؟ (اختياري)"; en = "↩️ '{0}' was removed from layer {1}.`nWhy? (you need not say)" }
    $catalogue['flow.undoFailed'] = @{ ar = '❌ تعذّر التراجع: {0}'; en = '❌ The undo did not go through: {0}' }
    $catalogue['flow.safeUndoAudit'] = @{ ar = '↩️ تراجع آمن إلى {0} على طبقة {1} - بواسطة {2}'; en = '↩️ A safe undo back to {0} on layer {1} - by {2}' }
    $catalogue['flow.hideAllAudit'] = @{ ar = '🚨 إخفاء الكل - بواسطة {0}'; en = '🚨 Hide all - by {0}' }
    $catalogue['flow.updateAudit'] = @{ ar = '✏️ تحديث {0} - بواسطة {1}'; en = '✏️ {0} updated - by {1}' }
    $catalogue['flow.updated'] = @{ ar = '✅ تم التحديث: {0}'; en = '✅ Updated: {0}' }
    $catalogue['flow.updateFailed'] = @{ ar = '❌ فشل التحديث: {0}'; en = '❌ The update failed: {0}' }
    $catalogue['flow.limitParen'] = @{ ar = ' (الحد: {0} حرفًا)'; en = ' (the limit: {0} characters)' }
    $catalogue['flow.sendNewValueFor'] = @{ ar = 'أرسل القيمة الجديدة لـ ''{0}''{1}:'; en = 'Send the new value for ''{0}''{1}:' }
    $catalogue['flow.noSceneOnLayer'] = @{ ar = '⚠️ لا يوجد مشهد مسجّل على الطبقة {0}؛ لم يُضبط المؤقت.'; en = '⚠️ No scene is recorded on layer {0}; the timer was not set.' }
    $catalogue['flow.timerAudit'] = @{ ar = '⏱ مؤقت {0} ث على طبقة {1} - بواسطة {2}'; en = '⏱ A {0} s timer on layer {1} - by {2}' }
    $catalogue['flow.willHideWithin'] = @{ ar = '⏱ سيتم إخفاء الطبقة {0} خلال {1}؛ لا يتجاوز حدّ القالب إن كان مضبوطًا.'; en = '⏱ Layer {0} will be hidden within {1}; it never passes the template''s ceiling where one is set.' }
    $catalogue['flow.timerNotPersisted'] = @{ ar = '⚠️ ضُبط مؤقت الطبقة {0} داخل الجسر، لكن تعذّر حفظه ليستمر بعد إعادة التشغيل.'; en = '⚠️ The timer on layer {0} is set inside the bridge, but could not be saved to survive a restart.' }
    $catalogue['flow.copyReference'] = @{ ar = 'نسخ مرجع {0}'; en = 'Copy reference {0}' }
    $catalogue['flow.refused'] = @{ ar = 'رُفض {0}'; en = '{0} refused' }
    $catalogue['flow.failed'] = @{ ar = 'فشل {0}'; en = '{0} failed' }
    $catalogue['flow.onLayer'] = @{ ar = ' على الطبقة {0}'; en = ' on layer {0}' }
    $catalogue['flow.reference'] = @{ ar = '      🔖 مرجع {0}'; en = '      🔖 Reference {0}' }
    $catalogue['flow.readyTextsFor'] = @{ ar = "⚡ النصوص الجاهزة للقالب '{0}'`nاختر نصًا لإدارته أو أنشئ نصًا جديدًا:"; en = "⚡ The ready-made texts for the template '{0}'`nChoose one to manage, or make a new one:" }
    $catalogue['flow.operation'] = @{ ar = 'العملية: {0}'; en = 'The operation: {0}' }
    $catalogue['flow.template'] = @{ ar = 'القالب: {0}'; en = 'The template: {0}' }
    $catalogue['flow.name'] = @{ ar = 'الاسم: {0}'; en = 'The name: {0}' }
    $catalogue['flow.sendReadyTextName'] = @{ ar = 'أرسل اسم النص الجاهز الجديد للقالب ''{0}'':'; en = 'Send the name of the new ready-made text for the template ''{0}'':' }
    $catalogue['flow.sendFirstField'] = @{ ar = "أرسل قيمة الحقل (1/{0}):`n{1}"; en = "Send the field value (1/{0}):`n{1}" }
    $catalogue['flow.sendField'] = @{ ar = "أرسل قيمة الحقل ({0}/{1}):`n{2}"; en = "Send the field value ({0}/{1}):`n{2}" }
    $catalogue['flow.saveFailed'] = @{ ar = '❌ تعذّر حفظ التغيير: {0}'; en = '❌ Could not save the change: {0}' }
    $catalogue['flow.templateLine'] = @{ ar = '{0} (طبقة {1}): {2}  الحقول: {3}'; en = '{0} (layer {1}): {2}  fields: {3}' }
    $catalogue['cmd.fromTo'] = @{ ar = 'من «{0}» إلى «{1}»'; en = 'from "{0}" to "{1}"' }
    $catalogue['cmd.settingsSection'] = @{ ar = '<b>⚙️ الإعدادات ← {0}</b>'; en = '<b>⚙️ Settings ← {0}</b>' }
    $catalogue['cmd.hideAllLayers'] = @{ ar = "🚨 طبقات إخفاء الكل الحالية: {0}`nاضغط طبقة لتضمينها أو استبعادها. هذا التحديد هو فقط ما سيخفيه زر الطوارئ."; en = "🚨 The layers hide-all covers now: {0}`nTap a layer to take it in or leave it out. This choice is only what the emergency button will hide." }
    $catalogue['cmd.layerNameAudit'] = @{ ar = '🏷️ اسم طبقة {0} {1} - بواسطة {2}'; en = '🏷️ The name of layer {0} {1} - by {2}' }
    $catalogue['cmd.layerNameCleared'] = @{ ar = '✅ تم مسح اسم طبقة {0}.'; en = '✅ The name of layer {0} was cleared.' }
    $catalogue['cmd.nameSaved'] = @{ ar = '✅ تم حفظ الاسم: {0}'; en = '✅ The name was saved: {0}' }
    $catalogue['cmd.currentName'] = @{ ar = 'الاسم الحالي: {0}'; en = 'The name now: {0}' }
    $catalogue['cmd.layerNamePrompt'] = @{ ar = "🏷️ طبقة {0}`n{1}`nأرسل الاسم الجديد فقط."; en = "🏷️ Layer {0}`n{1}`nSend the new name, nothing else." }
    $catalogue['cmd.hideAllAudit'] = @{ ar = '🚨 طبقات إخفاء الكل = {0} - بواسطة {1}'; en = '🚨 The hide-all layers = {0} - by {1}' }
    $catalogue['cmd.unknownSetting'] = @{ ar = 'إعداد غير معروف: {0}'; en = 'That setting is not known: {0}' }
    $catalogue['cmd.protectionSetting'] = @{ ar = "⚠️ «{0}» إعداد حماية. تعطيله يوسّع من يستطيع التحكم بالهواء.`nهل أنت متأكد؟"; en = "⚠️ `"{0}`" is a protection setting. Turning it off widens who can control the air.`nAre you sure?" }
    $catalogue['cmd.settingAudit'] = @{ ar = '⚙️ {0} = {1} - بواسطة {2}'; en = '⚙️ {0} = {1} - by {2}' }
    $catalogue['cmd.layerInProduction'] = @{ ar = "❌ الطبقة {0} مستخدمة في قوالب الإنتاج: {1}`nاختر طبقة غير مستخدمة، وإلا خرجت التجربة على الهواء. لم يتغيّر شيء."; en = "❌ Layer {0} is used by production templates: {1}`nChoose an unused layer, or the test goes out on air. Nothing changed." }
    $catalogue['cmd.valueUnchanged'] = @{ ar = '⚠️ القيمة الحالية مطابقة بالفعل ({0}). لم يتغيّر شيء.'; en = '⚠️ The value is already the same ({0}). Nothing changed.' }
    $catalogue['cmd.minutes'] = @{ ar = '{0} دقيقة'; en = '{0} minutes' }
    $catalogue['cmd.minutesSeconds'] = @{ ar = '{0} دقيقة و{1} ثانية'; en = '{0} minutes and {1} seconds' }
    $catalogue['cmd.seconds'] = @{ ar = '{0} ثانية'; en = '{0} seconds' }
    $catalogue['cmd.ceilingSet'] = @{ ar = '✅ تم ضبط الحد الأقصى لـ ''{0}'' على {1}.'; en = '✅ The ceiling for ''{0}'' is set to {1}.' }
    $catalogue['cmd.willReset'] = @{ ar = '<i>{0} إعدادًا ستعود إلى قيمتها الأصلية:</i>'; en = '<i>{0} settings will go back to what they were:</i>' }
    $catalogue['cmd.andOthers'] = @{ ar = '… و{0} غيرها.'; en = '… and {0} others.' }
    $catalogue['cmd.resetAudit'] = @{ ar = '♻️ استعادة الإعدادات الافتراضية - بواسطة {0}'; en = '♻️ The settings restored to their defaults - by {0}' }
    $catalogue['cmd.searchResults'] = @{ ar = '🔎 نتائج البحث عن «{0}»'; en = '🔎 Search results for "{0}"' }
    $catalogue['cmd.settingCount'] = @{ ar = '<i>{0} إعدادًا{1}</i>'; en = '<i>{0} settings{1}</i>' }
    $catalogue['cmd.confirmResetOne'] = @{ ar = "↩️ إعادة «{0}» وحده إلى الافتراضي؟`nالآن: {1}`nسيصير: {2}"; en = "↩️ Put `"{0}`" alone back to its default?`nNow: {1}`nIt becomes: {2}" }
    $catalogue['cmd.resetOneAudit'] = @{ ar = '↩️ إعادة إعداد {0} - بواسطة {1}'; en = '↩️ The setting {0} reset - by {1}' }
    $catalogue['cmd.rawAudit'] = @{ ar = '🛠 أمر خام {0}/{1} - بواسطة {2}'; en = '🛠 A raw command {0}/{1} - by {2}' }
    $catalogue['cmd.rawSent'] = @{ ar = 'تم الإرسال: Device={0} Cmd={1}'; en = 'Sent: Device={0} Cmd={1}' }
    $catalogue['cmd.failed'] = @{ ar = 'فشل: {0}'; en = 'Failed: {0}' }
    $catalogue['cmd.templateUnknown'] = @{ ar = 'القالب ''{0}'' غير معروف. استخدم زر 📋 القوالب.'; en = 'The template ''{0}'' is not known. Use the 📋 Templates button.' }
    $catalogue['cmd.templateFieldCount'] = @{ ar = 'القالب ''{0}'' يحتوي على {1} حقل/حقول فقط: {2}'; en = 'The template ''{0}'' holds only {1} field(s): {2}' }
    $catalogue['cmd.userNameSet'] = @{ ar = '✅ تم تعيين اسم المستخدم {0} إلى: {1}'; en = '✅ The name of user {0} is set to: {1}' }
    $catalogue['cmd.userAliasCleared'] = @{ ar = '✅ تم حذف الاسم المستعار للمستخدم {0}'; en = '✅ The alias of user {0} was removed' }
    $catalogue['cmd.userAliasAudit'] = @{ ar = '👤 اسم بديل للمستخدم {0} عُدّل بواسطة {1}'; en = '👤 The alias of user {0} was changed by {1}' }
    $catalogue['cmd.unknownCommand'] = @{ ar = 'أمر غير معروف ''/{0}''. استخدم الأزرار أدناه:'; en = 'That command is not known, ''/{0}''. Use the buttons below:' }
}
