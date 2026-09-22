#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the administrator's sentences with holes: the settings
    import with a complaint per option, the diagnostics screen line by line,
    the access door from the request to the decision, and the add-a-template
    wizard with the review it shows before it writes.
#>

function Add-BridgeTextInterp3 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['cfg.exportFailed'] = @{ ar = '❌ تعذّر تجهيز ملف الإعدادات: {0}'; en = '❌ Could not prepare the settings file: {0}' }
    $catalogue['cfg.exportNote2'] = @{ ar = '📤 نسخة الإعدادات ({0} خيارًا). لا تحتوي التوكن ولا قائمة المستخدمين.'; en = '📤 A copy of the settings ({0} options). It carries neither the token nor the user list.' }
    $catalogue['cfg.exportAudit'] = @{ ar = '📤 تصدير الإعدادات - بواسطة {0}'; en = '📤 Settings exported - by {0}' }
    $catalogue['cfg.mustBeBool'] = @{ ar = 'الخيار {0} يجب أن يكون true أو false.'; en = 'The option {0} has to be true or false.' }
    $catalogue['cfg.mustBeInt'] = @{ ar = 'الخيار {0} يجب أن يكون رقمًا صحيحًا.'; en = 'The option {0} has to be a whole number.' }
    $catalogue['cfg.outOfRange'] = @{ ar = 'قيمة الخيار {0} خارج الحدود المسموحة.'; en = 'The value of {0} is outside the allowed range.' }
    $catalogue['cfg.mustBeNumber'] = @{ ar = 'الخيار {0} يجب أن يكون رقمًا.'; en = 'The option {0} has to be a number.' }
    $catalogue['cfg.mustBeText'] = @{ ar = 'الخيار {0} يجب أن يكون نصًا.'; en = 'The option {0} has to be text.' }
    $catalogue['cfg.valueNotAllowed'] = @{ ar = 'قيمة الخيار {0} غير مسموحة.'; en = 'The value of {0} is not allowed.' }
    $catalogue['cfg.atLeast'] = @{ ar = '{0} لا يقلّ عن {1}.'; en = '{0} is no less than {1}.' }
    $catalogue['cfg.atMost'] = @{ ar = '{0} لا يزيد عن {1}.'; en = '{0} is no more than {1}.' }
    $catalogue['cfg.unknownOption'] = @{ ar = 'خيار غير معروف في الملف: {0}'; en = 'An option in the file is not known: {0}' }
    $catalogue['cfg.andMoreOptions'] = @{ ar = "`n… و{0} خيارًا آخر."; en = "`n… and {0} options more." }
    $catalogue['cfg.importReview'] = @{ ar = "⚠️ مراجعة استيراد الإعدادات — {0} تغييرًا:`n"; en = "⚠️ Review the settings import — {0} changes:`n" }
    $catalogue['cfg.importFailed'] = @{ ar = '❌ فشل استيراد الإعدادات: {0}'; en = '❌ The settings import failed: {0}' }
    $catalogue['cfg.importAudit'] = @{ ar = '📥 استيراد الإعدادات ({0} تغييرًا) - بواسطة {1}'; en = '📥 Settings imported ({0} changes) - by {1}' }
    $catalogue['cfg.applied'] = @{ ar = '✅ طُبِّق {0} تغييرًا.{1}'; en = '✅ {0} changes applied.{1}' }
    $catalogue['cfg.trialLayerInUse'] = @{ ar = '⛔ طبقة التجربة {0} مستخدمة في قوالب الإنتاج: {1}'; en = '⛔ The trial layer {0} is used by production templates: {1}' }
    $catalogue['cfg.readingLayer'] = @{ ar = 'قراءة حالة الطبقة {0}'; en = 'Reading the state of layer {0}' }
    $catalogue['cfg.pathCheckAudit'] = @{ ar = '🧪 فحص المسار الحي على طبقة {0} - {1} - بواسطة {2}'; en = '🧪 Live path check on layer {0} - {1} - by {2}' }
    $catalogue['cfg.trialLayerUnsure'] = @{ ar = '⛔ تعذر التأكد من فراغ طبقة التجربة {0}؛ لم يُرسل شيء.'; en = '⛔ Could not confirm that the trial layer {0} is empty; nothing was sent.' }
    $catalogue['cfg.trialLayerBusy'] = @{ ar = '⛔ طبقة التجربة {0} مشغولة حاليًا؛ أخفها أو اختر طبقة أخرى.'; en = '⛔ The trial layer {0} is busy right now; hide it or choose another layer.' }
    $catalogue['cfg.templateTestFailed'] = @{ ar = '❌ فشل اختبار القالب: {0}'; en = '❌ The template test failed: {0}' }
    $catalogue['cfg.templateTestAudit'] = @{ ar = '🧪 اختبار قالب {0} على طبقة {1} - بواسطة {2}'; en = '🧪 Template {0} tested on layer {1} - by {2}' }
    $catalogue['cfg.templateTestStarted'] = @{ ar = '✅ بدأ اختبار ''{0}'' على طبقة التجربة {1} وسيُخفى خلال {2}.'; en = '✅ The test of ''{0}'' started on the trial layer {1} and will be hidden within {2}.' }
    $catalogue['cfg.registerSize'] = @{ ar = 'يجب أن يحتوي السجل بين قالب واحد و{0}.'; en = 'The register has to hold between one template and {0}.' }
    $catalogue['cfg.badTemplateKey'] = @{ ar = 'مفتاح القالب ''{0}'' غير صالح.'; en = 'The template key ''{0}'' is not valid.' }
    $catalogue['cfg.needsAbsolutePath'] = @{ ar = 'القالب ''{0}'' يحتاج مسارًا مطلقًا لملف .cintitle.'; en = 'The template ''{0}'' needs an absolute path to a .cintitle file.' }
    $catalogue['cfg.needsLayer'] = @{ ar = 'القالب ''{0}'' يحتاج رقم طبقة موجبًا.'; en = 'The template ''{0}'' needs a positive layer number.' }
    $catalogue['cfg.hasUnnamedField'] = @{ ar = 'القالب ''{0}'' يحتوي حقلاً بلا اسم.'; en = 'The template ''{0}'' holds a field without a name.' }
    $catalogue['cfg.templateExportAudit'] = @{ ar = '📤 تصدير تعريفات القوالب - بواسطة {0}'; en = '📤 Template definitions exported - by {0}' }
    $catalogue['cfg.templateImportReview'] = @{ ar = "🔎 مراجعة استيراد القوالب`nالإجمالي: {0}`nمضاف: {1}`nمعدّل: {2}`nمحذوف: {3}`nبلا تغيير: {4}`n`nلن يُستبدل الملف حتى التأكيد."; en = "🔎 Review the template import`nIn all: {0}`nAdded: {1}`nChanged: {2}`nDeleted: {3}`nUnchanged: {4}`n`nThe file is not replaced until you confirm." }
    $catalogue['cfg.importRefused'] = @{ ar = '❌ رُفض ملف الاستيراد: {0}'; en = '❌ The import file was refused: {0}' }
    $catalogue['cfg.lockedOnAir'] = @{ ar = 'لا يمكن تغيير أو حذف قالب مستخدم على الهواء أو في جدولة قادمة: {0}'; en = 'A template in use on air or in an upcoming schedule cannot be changed or deleted: {0}' }
    $catalogue['cfg.templateImportAudit'] = @{ ar = '📥 استيراد تعريفات القوالب مع نسخة احتياطية - بواسطة {0}'; en = '📥 Template definitions imported, with a backup - by {0}' }
    $catalogue['cfg.approveFailed'] = @{ ar = '❌ تعذّر اعتماد الاستيراد: {0}'; en = '❌ Could not approve the import: {0}' }
    $catalogue['cfg.lowDisc'] = @{ ar = '⚠️ مساحة القرص الحرة منخفضة: {0} GB'; en = '⚠️ The free disc space is low: {0} GB' }
    $catalogue['cfg.logsOverLimit'] = @{ ar = '⚠️ حجم السجلات وملفات التشغيل تجاوز {0} MB'; en = '⚠️ The logs and runtime files have passed {0} MB' }
    $catalogue['cfg.backupsOverLimit'] = @{ ar = '⚠️ حجم النسخ الاحتياطية تجاوز {0} MB'; en = '⚠️ The backups have passed {0} MB' }
    $catalogue['cfg.adminsWithoutNotices'] = @{ ar = '⚠️ مشرفون بلا إشعارات (في AdminUserIds لا AdminChatIds): {0}'; en = '⚠️ Administrators with no notices (in AdminUserIds, not AdminChatIds): {0}' }
    $catalogue['cfg.noticesWithoutRight'] = @{ ar = '⚠️ يصلهم إشعار المشرفين بلا صلاحية مشرف: {0}'; en = '⚠️ They receive the administrator notices without the administrator right: {0}' }
    $catalogue['diag.noRecord'] = @{ ar = "🔎 لا سجل بالمرجع {0}.`nقد يكون السجل دُوِّر أو مُسح."; en = "🔎 No record under the reference {0}.`nThe log may have rotated, or been cleared." }
    $catalogue['diag.referenceLines'] = @{ ar = "🔎 المرجع {0} — {1} سطرًا:`n`n"; en = "🔎 Reference {0} — {1} lines:`n`n" }
    $catalogue['diag.referenceLinesShort'] = @{ ar = '🔎 المرجع {0} — {1} سطرًا'; en = '🔎 Reference {0} — {1} lines' }
    $catalogue['diag.bundleAudit'] = @{ ar = '📦 تنزيل حزمة تشخيص منقحة - بواسطة {0}'; en = '📦 A redacted diagnostic bundle downloaded - by {0}' }
    $catalogue['diag.confirmClear'] = @{ ar = "⚠️ هل تريد مسح {0}؟`nلا يؤثر هذا على onair.json أو القوالب الموجودة على الهواء."; en = "⚠️ Clear {0}?`nThis touches neither onair.json nor anything on air." }
    $catalogue['diag.builtAt'] = @{ ar = 'وقت البناء: {0} | مدة التشغيل: {1}'; en = 'Built at: {0} | running for: {1}' }
    $catalogue['diag.cpu'] = @{ ar = 'المعالج: {0}'; en = 'Processor: {0}' }
    $catalogue['diag.memory'] = @{ ar = 'الذاكرة: Working {0} MB | Private {1} MB'; en = 'Memory: working {0} MB | private {1} MB' }
    $catalogue['diag.freeDisc'] = @{ ar = 'مساحة القرص الحرة: {0}'; en = 'Free disc space: {0}' }
    $catalogue['diag.fileSizes'] = @{ ar = 'أحجام الملفات: {0}'; en = 'File sizes: {0}' }
    $catalogue['diag.airOps'] = @{ ar = 'عمليات الهواء: نجاح {0} | فشل {1} | محظور {2}'; en = 'Air operations: passed {0} | failed {1} | blocked {2}' }
    $catalogue['diag.cinegy'] = @{ ar = 'Cinegy: {0} / قناة {1}'; en = 'Cinegy: {0} / channel {1}' }
    $catalogue['diag.templates'] = @{ ar = 'القوالب: {0} | تحذيرات القوالب: {1}'; en = 'Templates: {0} | template warnings: {1}' }
    $catalogue['diag.pendingChats'] = @{ ar = 'المحادثات المعلقة: {0} | أقفال الطبقات: {1}'; en = 'Chats mid-flow: {0} | layer locks: {1}' }
    $catalogue['diag.postbox'] = @{ ar = 'طابور postbox: {0} | مؤقتات الإخفاء: {1}'; en = 'The postbox queue: {0} | hide timers: {1}' }
    $catalogue['diag.upcoming'] = @{ ar = 'الأحداث المجدولة القادمة: {0} | ملف الجدولة: {1}'; en = 'Upcoming scheduled events: {0} | the schedule file: {1}' }
    $catalogue['diag.snapshots'] = @{ ar = 'لقطات قيد التنفيذ: {0} | relay: {1}'; en = 'Snapshots under way: {0} | relay: {1}' }
    $catalogue['diag.localCinegyState'] = @{ ar = 'حالة Cinegy المحلية: {0}'; en = 'The local Cinegy state: {0}' }
    $catalogue['diag.period'] = @{ ar = 'الفترة: {0} ← {1}'; en = 'The period: {0} ← {1}' }
    $catalogue['diag.shown'] = @{ ar = 'المعروض: {0} من {1} سطرًا محفوظة'; en = 'Shown: {0} of {1} lines kept' }
    $catalogue['diag.name'] = @{ ar = "الاسم: {0}`n"; en = "Name: {0}`n" }
    $catalogue['diag.newRequest'] = @{ ar = "🔔 طلب وصول جديد للبوت`n{0}رقم المحادثة: {1}`nرقم المستخدم: {2}"; en = "🔔 A new access request for the bot`n{0}Chat id: {1}`nUser id: {2}" }
    $catalogue['diag.nameReceived'] = @{ ar = "✅ وصل اسمك: {0}`nطلبك عند المشرفين، وستصلك رسالة فور الموافقة."; en = "✅ Your name arrived: {0}`nYour request is with the administrators, and you will hear as soon as it is approved." }
    $catalogue['diag.requestAudit'] = @{ ar = '📝 طلب الوصول من {0} باسم: {1}'; en = '📝 An access request from {0} under the name: {1}' }
    $catalogue['diag.alreadyAuthorised'] = @{ ar = 'ℹ️ {0} مصرّح له بالفعل.'; en = 'ℹ️ {0} is authorised already.' }
    $catalogue['diag.accessGranted'] = @{ ar = '👤 مُنح الوصول: {0} — بواسطة {1}'; en = '👤 Access granted: {0} — by {1}' }
    $catalogue['diag.approvedAudit'] = @{ ar = '👤 موافقة على {0} - بواسطة {1}'; en = '👤 {0} approved - by {1}' }
    $catalogue['diag.approvedAdded'] = @{ ar = '✅ تمت الموافقة على {0} وأُضيف إلى المستخدمين المصرح لهم.{1}'; en = '✅ {0} was approved and added to the authorised users.{1}' }
    $catalogue['diag.refusedAudit'] = @{ ar = '👤 رفض طلب {0} - بواسطة {1}'; en = '👤 {0}''s request refused - by {1}' }
    $catalogue['diag.refused'] = @{ ar = '❌ تم رفض طلب {0}.{1}'; en = '❌ {0}''s request was refused.{1}' }
    $catalogue['atpl.alertNotSaved'] = @{ ar = '❌ تعذّر حفظ تنبيه القالب: {0}'; en = '❌ Could not save the template alert: {0}' }
    $catalogue['atpl.alertSetAudit'] = @{ ar = '🔔 ضبط تنبيه ظهور {0} على {1} - بواسطة {2}'; en = '🔔 The appearance alert on {0} set to {1} - by {2}' }
    $catalogue['atpl.alertSet'] = @{ ar = '✅ تم ضبط تنبيه الظهور بعد {0}.'; en = '✅ The appearance alert is set for {0} from now.' }
    $catalogue['atpl.invalidTemplates'] = @{ ar = '<b>🧹 قوالب غير صالحة ({0})</b>'; en = '<b>🧹 Invalid templates ({0})</b>' }
    $catalogue['atpl.delete'] = @{ ar = '🗑 حذف {0}'; en = '🗑 Delete {0}' }
    $catalogue['atpl.deleteReview'] = @{ ar = '⚠️ مراجعة حذف القالب ''{0}''. لن يُحذف إذا كان على الهواء أو ضمن جدولة قادمة.'; en = '⚠️ Review the deletion of ''{0}''. It is not deleted if it is on air or in an upcoming schedule.' }
    $catalogue['atpl.sendJson'] = @{ ar = "أرسل تعريف القالب بصيغة JSON في رسالة واحدة.`nمثال:`n{0}"; en = "Send the template definition as JSON in one message.`nFor example:`n{0}" }
    $catalogue['atpl.reviewNew'] = @{ ar = '🔎 مراجعة القالب الجديد ''{0}'''; en = '🔎 Review the new template ''{0}''' }
    $catalogue['atpl.path'] = @{ ar = 'المسار: {0}'; en = 'Path: {0}' }
    $catalogue['atpl.readFrom'] = @{ ar = 'يُقرأ من: {0}'; en = 'Read from: {0}' }
    $catalogue['atpl.device'] = @{ ar = 'الجهاز: gfx_{0}'; en = 'Device: gfx_{0}' }
    $catalogue['atpl.layer'] = @{ ar = 'الطبقة: {0}'; en = 'Layer: {0}' }
    $catalogue['atpl.fields'] = @{ ar = 'الحقول: {0}'; en = 'Fields: {0}' }
    $catalogue['atpl.description'] = @{ ar = 'الوصف: {0}'; en = 'Description: {0}' }
    $catalogue['atpl.category'] = @{ ar = 'التصنيف: {0}'; en = 'Category: {0}' }
    $catalogue['atpl.keyTaken'] = @{ ar = '❌ يوجد قالب بالمفتاح ''{0}'' بالفعل. أرسل مفتاحًا آخر:'; en = '❌ A template with the key ''{0}'' already exists. Send another key:' }
    $catalogue['atpl.orFileNameAlone'] = @{ ar = "`nأو اسم الملف وحده، فمجلد المشاهد مضبوط: {0}"; en = "`nOr the file name alone, since the scenes folder is set: {0}" }
    $catalogue['atpl.add2'] = @{ ar = "(2/5) أرسل مسار ملف المشهد كاملًا، مثل:`nC:\Cinegy\Titler\Scenes\Lower3rd.cintitle`nويُقبل أيضًا مسار الشبكة \\nas01\scenes\... و%PROGRAMDATA%\...{0}"; en = "(2/5) Send the full path to the scene file, such as:`nC:\Cinegy\Titler\Scenes\Lower3rd.cintitle`nA network path \\nas01\scenes\... and %PROGRAMDATA%\... are accepted too.{0}" }
    $catalogue['atpl.fileNotSeen'] = @{ ar = "⚠️ لا أرى الملف على هذا المسار:`n{0}`n`nللمتابعة به رغم ذلك أرسل: تم`nأو أرسل مسارًا آخر."; en = "⚠️ There is no file at this path:`n{0}`n`nTo go on with it anyway send: ok`nor send another path." }
    $catalogue['atpl.fileThere'] = @{ ar = "✅ الملف موجود.`n{0}"; en = "✅ The file is there.`n{0}" }
    $catalogue['atpl.layerShared'] = @{ ar = "`n⚠️ الطبقة {0} يستخدمها أيضًا: {1}"; en = "`n⚠️ Layer {0} is also used by: {1}" }
    $catalogue['atpl.deviceWillBeUsed'] = @{ ar = "✅ سيُستخدم الجهاز gfx_{0}.`n{1}"; en = "✅ The device gfx_{0} will be used.`n{1}" }
    $catalogue['atpl.diffRow'] = @{ ar = "• {0}`n  قبل: {1}`n  بعد: {2}"; en = "• {0}`n  before: {1}`n  after: {2}" }
    $catalogue['atpl.differences'] = @{ ar = "الاختلافات:`n{0}"; en = "The differences:`n{0}" }
    $catalogue['atpl.reviewChange'] = @{ ar = "🔎 مراجعة {0} للقالب '{1}'`nالمسار: {2}`nالطبقة: {3}`n`n{4}`n`nلن يُحفظ شيء قبل التأكيد، وستُنشأ نسخة احتياطية من التعريفات الحالية."; en = "🔎 Review the {0} of the template '{1}'`nPath: {2}`nLayer: {3}`n`n{4}`n`nNothing is saved before you confirm, and a backup of the current definitions will be made." }
    $catalogue['atpl.savedAudit'] = @{ ar = '📚 {0} قالب {1} - بواسطة {2}'; en = '📚 Template {1} {0} - by {2}' }
    $catalogue['atpl.saveFailed'] = @{ ar = '❌ تعذّر حفظ القالب: {0}'; en = '❌ Could not save the template: {0}' }
}
