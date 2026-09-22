#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the administrator's own working files: importing
    settings and templates with the difference shown first, the live-path
    check step by step, the diagnostics bundle, the five-step add-a-template
    wizard, and the health screen.
#>

function Add-BridgeTextAdminTools {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['cfg.notJson'] = @{ ar = 'الملف ليس JSON صالحًا.'; en = 'The file is not valid JSON.' }
    $catalogue['cfg.notOurExport'] = @{ ar = 'الملف ليس نسخة إعدادات صادرة عن هذا الجسر.'; en = 'The file is not a settings export from this bridge.' }
    $catalogue['cfg.noSettingsSection'] = @{ ar = 'لا يحتوي الملف على قسم Settings.'; en = 'The file holds no Settings section.' }
    $catalogue['cfg.identical'] = @{ ar = '✅ الملف مطابق للإعدادات الحالية؛ لا يوجد ما يتغيّر.'; en = '✅ The file matches the settings as they stand; nothing would change.' }
    $catalogue['cfg.apply'] = @{ ar = '✅ تطبيق'; en = '✅ Apply' }
    $catalogue['cfg.reviewExpired'] = @{ ar = 'انتهت مراجعة الاستيراد أو تغيّرت. ابدأ من جديد.'; en = 'The import review expired or changed. Start again.' }
    $catalogue['cfg.importCancelled'] = @{ ar = '❌ أُلغي الاستيراد؛ لم يتغيّر شيء.'; en = '❌ The import was cancelled; nothing changed.' }
    $catalogue['cfg.importNotSaved'] = @{ ar = '❌ تعذّر حفظ استيراد الإعدادات؛ لم يُطبّق أي تغيير.'; en = '❌ Could not save the settings import; no change was applied.' }
    $catalogue['cfg.noTrialLayer'] = @{ ar = '⛔ لا توجد طبقة تجربة. اضبط TemplateTestLayer على طبقة غير مستخدمة أولًا.'; en = '⛔ There is no trial layer. Point TemplateTestLayer at an unused layer first.' }
    $catalogue['cfg.noTemplatesToCheck'] = @{ ar = '⛔ لا توجد قوالب مسجّلة لإجراء الفحص.'; en = '⛔ No template is registered, so there is nothing to check.' }
    $catalogue['cfg.layerReady'] = @{ ar = 'الطبقة جاهزة للفحص'; en = 'The layer is ready for the check' }
    $catalogue['cfg.layerBusy'] = @{ ar = 'مشغولة أو غير مقروءة؛ لم يُرسل شيء'; en = 'busy or unreadable; nothing was sent' }
    $catalogue['cfg.pathCheckFailedNl'] = @{ ar = "🧪 فحص المسار الحي — فشل`n"; en = "🧪 Live path check — failed`n" }
    $catalogue['cfg.sendShow'] = @{ ar = 'إرسال SHOW'; en = 'Sending SHOW' }
    $catalogue['cfg.cinegyConfirms'] = @{ ar = 'Cinegy يؤكد ظهور المشهد'; en = 'Cinegy confirms the scene appeared' }
    $catalogue['cfg.sendExit'] = @{ ar = 'إرسال EXIT'; en = 'Sending EXIT' }
    $catalogue['cfg.cleanLayer'] = @{ ar = 'تنظيف الطبقة (HIDE)'; en = 'Clearing the layer (HIDE)' }
    $catalogue['cfg.layerEmptyAfter'] = @{ ar = 'الطبقة فارغة بعد الفحص'; en = 'The layer is empty after the check' }
    $catalogue['cfg.pathCheckFailed'] = @{ ar = '🧪 فحص المسار الحي — فشل'; en = '🧪 Live path check — failed' }
    $catalogue['cfg.pathCheckPassed'] = @{ ar = '🧪 فحص المسار الحي — نجح'; en = '🧪 Live path check — passed' }
    $catalogue['cfg.failed'] = @{ ar = 'فشل'; en = 'failed' }
    $catalogue['cfg.passed'] = @{ ar = 'نجح'; en = 'passed' }
    $catalogue['cfg.templateChanged'] = @{ ar = '❌ تغيّر تعريف القالب أو طبقة التجربة. ابدأ المراجعة من جديد.'; en = '❌ The template definition or the trial layer changed. Start the review again.' }
    $catalogue['cfg.fileTooBig'] = @{ ar = 'الملف أكبر من 10 ميغابايت.'; en = 'The file is larger than 10 megabytes.' }
    $catalogue['cfg.enableFullTemplates'] = @{ ar = '🔒 فعّل إدارة القوالب الكاملة أولاً.'; en = '🔒 Turn full template management on first.' }
    $catalogue['cfg.sendJsonFile'] = @{ ar = '📥 أرسل ملف JSON واحدًا (بحد أقصى 10 ميغابايت). سيُفحص ويُعرض الفرق قبل أي استبدال.'; en = '📥 Send one JSON file (10 megabytes at most). It will be checked and the difference shown before anything is replaced.' }
    $catalogue['cfg.exportNote'] = @{ ar = '📤 نسخة تعريفات القوالب. لا تحتوي حالة الهواء أو قيم النصوص المستخدمة.'; en = '📤 A copy of the template definitions. It carries no air state and none of the text values in use.' }
    $catalogue['cfg.uploadJsonSize'] = @{ ar = '❌ يجب رفع ملف JSON حجمه بين 1 بايت و10 ميغابايت.'; en = '❌ The JSON file you upload must be between 1 byte and 10 megabytes.' }
    $catalogue['cfg.approveImport'] = @{ ar = '✅ اعتماد الاستيراد'; en = '✅ Approve the import' }
    $catalogue['cfg.importedTemplates'] = @{ ar = '✅ تم استيراد تعريفات القوالب وحفظ نسخة من السجل السابق.'; en = '✅ The template definitions were imported and a copy of the earlier register kept.' }
    $catalogue['diag.sendReference'] = @{ ar = "أرسل مرجع العملية — ثمانية أحرف، مثل 5023333b.`nينسخه المشغّل من 🧾 عملياتي."; en = "Send the operation reference — eight characters, such as 5023333b.`nThe operator copies it from 🧾 My operations." }
    $catalogue['diag.searchAdminOnly'] = @{ ar = '🔎 البحث بالمرجع للمشرف وحده.'; en = '🔎 Searching by reference is for the administrator alone.' }
    $catalogue['diag.notAReference'] = @{ ar = '❌ ليس مرجعًا: يتكوّن من ثمانية أحرف من 0-9 و a-f.'; en = '❌ That is not a reference: it is eight characters from 0-9 and a-f.' }
    $catalogue['diag.searchByReference'] = @{ ar = '🔎 ابحث بمرجع عملية'; en = '🔎 Search by operation reference' }
    $catalogue['diag.redactedBundle'] = @{ ar = '📦 حزمة تشخيص منقحة'; en = '📦 Redacted diagnostic bundle' }
    $catalogue['diag.clearRunLog'] = @{ ar = '🧹 مسح سجل التشغيل'; en = '🧹 Clear the run log' }
    $catalogue['diag.clearAuditLog'] = @{ ar = '🧹 مسح سجل التدقيق'; en = '🧹 Clear the audit log' }
    $catalogue['diag.adminOptionOnly'] = @{ ar = 'هذا الخيار للمشرفين فقط.'; en = 'This option is for administrators only.' }
    $catalogue['diag.bundleNote'] = @{ ar = '📦 حزمة تشخيص منقحة: لا تحتوي الإعدادات أو حالة الهواء أو معرفات المستخدمين.'; en = '📦 A redacted diagnostic bundle: it carries no settings, no air state and no user ids.' }
    $catalogue['diag.bundleSendFailed'] = @{ ar = '❌ تعذر إرسال حزمة التشخيص.'; en = '❌ Could not send the diagnostic bundle.' }
    $catalogue['diag.bundleCreateFailed'] = @{ ar = '❌ تعذر إنشاء حزمة التشخيص.'; en = '❌ Could not build the diagnostic bundle.' }
    $catalogue['diag.currentRunLog'] = @{ ar = 'سجل التشغيل الحالي وكل نسخه المدورة'; en = 'the current run log and every rotated copy of it' }
    $catalogue['diag.permanentAuditLog'] = @{ ar = 'سجل التدقيق الدائم'; en = 'the permanent audit log' }
    $catalogue['diag.yesClear'] = @{ ar = '⚠️ نعم، امسح'; en = '⚠️ Yes, clear it' }
    $catalogue['diag.adminCommandOnly'] = @{ ar = 'هذا الأمر مخصص للمشرفين فقط.'; en = 'This command is for administrators only.' }
    $catalogue['diag.shouldBeRunning'] = @{ ar = 'مطلوب التشغيل'; en = 'should be running' }
    $catalogue['diag.stopped'] = @{ ar = 'متوقف'; en = 'stopped' }
    $catalogue['diag.title'] = @{ ar = '🧪 تشخيص Cinegy Telegram Bridge'; en = '🧪 Cinegy Telegram Bridge diagnostics' }
    $catalogue['diag.opsByHour'] = @{ ar = '📅 سجل العمليات بالساعات'; en = '📅 Operations hour by hour' }
    $catalogue['diag.latestOpsEmpty'] = @{ ar = "📜 آخر العمليات`n━━━━━━━━━━━━━━`nلا توجد عمليات مسجّلة بعد."; en = "📜 The latest operations`n━━━━━━━━━━━━━━`nNo operation is recorded yet." }
    $catalogue['diag.latestOps'] = @{ ar = '📜 آخر العمليات'; en = '📜 The latest operations' }
    $catalogue['diag.sendYourName'] = @{ ar = '📝 أرسل اسمك كما تريده أن يظهر للمشرفين (مثل: أحمد - قسم الأخبار).'; en = '📝 Send your name as you want the administrators to see it (such as: Ahmed - the newsroom).' }
    $catalogue['diag.botClosed'] = @{ ar = '🔑 هذا البوت مغلق. أرسل رمز الانضمام للمتابعة.'; en = '🔑 This bot is closed. Send the join code to go on.' }
    $catalogue['diag.wrongCode'] = @{ ar = '❌ الرمز غير صحيح.'; en = '❌ That code is wrong.' }
    $catalogue['diag.requestNotRecorded'] = @{ ar = 'تعذّر تسجيل طلبك الآن. حاول لاحقًا.'; en = 'Your request could not be recorded now. Try later.' }
    $catalogue['diag.nameEmpty'] = @{ ar = '❌ الاسم فارغ. أرسل اسمك.'; en = '❌ The name is empty. Send your name.' }
    $catalogue['diag.approved'] = @{ ar = '✅ تمت الموافقة على طلبك، يمكنك الآن استخدام البوت.'; en = '✅ Your request was approved; you may use the bot now.' }
    $catalogue['diag.chatBlockedToo'] = @{ ar = ' وحُظرت المحادثة من الطلب مجددًا.'; en = ' and the chat is blocked from asking again.' }
    $catalogue['diag.requestRefused'] = @{ ar = 'تم رفض طلب الوصول الخاص بك.'; en = 'Your access request was refused.' }
    $catalogue['atpl.alertRightLost'] = @{ ar = 'فقدت صلاحية إدارة تنبيه القالب؛ لم يتم حفظ التغيير.'; en = 'You no longer hold the right to manage the template alert; the change was not saved.' }
    $catalogue['atpl.sendMinutes'] = @{ ar = 'أرسل رقمًا صحيحًا من 0 إلى 1440 دقيقة.'; en = 'Send a whole number from 0 to 1440 minutes.' }
    $catalogue['atpl.templateChanged'] = @{ ar = 'تغيّر القالب؛ افتح تفاصيله مجددًا.'; en = 'The template changed; open its details again.' }
    $catalogue['atpl.nowLongRun'] = @{ ar = 'القالب أصبح Long run؛ لا يمكن تفعيل تنبيه الظهور له.'; en = 'The template is now a long run; an appearance alert cannot be set for it.' }
    $catalogue['atpl.alertStopped'] = @{ ar = '✅ تم إيقاف تنبيه الظهور لهذا القالب.'; en = '✅ The appearance alert for this template was turned off.' }
    $catalogue['atpl.noInvalidTemplates'] = @{ ar = '🧹 لا قوالب غير صالحة — السجل نظيف.'; en = '🧹 No invalid template — the register is clean.' }
    $catalogue['atpl.skippedNote'] = @{ ar = '<i>تُتخطى عند كل تحميل. الحذف بنسخة احتياطية، والمشغول على الهواء أو المجدول محمي.</i>'; en = '<i>These are skipped on every load. A delete keeps a backup, and anything on air or scheduled is protected.</i>' }
    $catalogue['atpl.fullControlOff'] = @{ ar = '🔒 التحكم الكامل بالقوالب معطّل من الإعدادات.'; en = '🔒 Full control over the templates is turned off in the settings.' }
    $catalogue['atpl.templateGone'] = @{ ar = 'القالب لم يعد موجودًا.'; en = 'The template is no longer there.' }
    $catalogue['atpl.add1'] = @{ ar = "➕ إضافة قالب (1/5)`nأرسل مفتاح القالب - وهو الاسم الذي سيظهر على الزر (أحرف وأرقام ونقاط/شرطات، مثل: Lower3rd):"; en = "➕ Add a template (1/5)`nSend the template key — the name that will sit on the button (letters, digits, dots and dashes, such as: Lower3rd):" }
    $catalogue['atpl.add3'] = @{ ar = "(3/5) أرسل رقم الطبقة (مثل 4 أو 7)،`nأو اسم جهاز Cinegy إن كانت الطبقة بلا رقم (مثل: logo)."; en = "(3/5) Send the layer number (such as 4 or 7),`nor a Cinegy device name if the layer has no number (such as: logo)." }
    $catalogue['atpl.add4'] = @{ ar = "(4/5) أرسل أسماء الحقول مفصولة بفواصل (مثل: Headline.Text, Subtitle.Text)`nأو أرسل: لا يوجد إذا كان القالب بلا حقول."; en = "(4/5) Send the field names separated by commas (such as: Headline.Text, Subtitle.Text)`nor send: none if the template has no fields." }
    $catalogue['atpl.noFields'] = @{ ar = 'لا توجد حقول'; en = 'no fields' }
    $catalogue['atpl.noDescription'] = @{ ar = 'بلا وصف'; en = 'no description' }
    $catalogue['atpl.uncategorised'] = @{ ar = 'غير مصنف'; en = 'uncategorised' }
    $catalogue['atpl.nothingSavedYet'] = @{ ar = 'لن يُحفظ شيء قبل التأكيد، وستُنشأ نسخة احتياطية من التعريفات الحالية.'; en = 'Nothing is saved before you confirm, and a backup of the current definitions will be made.' }
    $catalogue['atpl.badKey'] = @{ ar = '❌ مفتاح غير صالح. استخدم أحرفًا وأرقامًا ونقاط/شرطات فقط (حتى 64 حرفًا):'; en = '❌ That key is not valid. Use letters, digits, dots and dashes only (up to 64 characters):' }
    $catalogue['atpl.noPendingPath'] = @{ ar = '❌ لا يوجد مسار معلّق للمتابعة. أرسل مسار ملف القالب أولًا:'; en = '❌ There is no pending path to go on with. Send the template file path first:' }
    $catalogue['atpl.needCintitle'] = @{ ar = "❌ يجب أن ينتهي المسار بـ .cintitle، مثل:`nC:\Cinegy\Titler\Scenes\Lower3rd.cintitle"; en = "❌ The path must end in .cintitle, such as:`nC:\Cinegy\Titler\Scenes\Lower3rd.cintitle" }
    $catalogue['atpl.needFullPath'] = @{ ar = "❌ أرسل مسارًا كاملًا، أو اضبط TemplateBasePath من الإعدادات لتكتفي باسم الملف.`nمثال: C:\Cinegy\Titler\Scenes\Lower3rd.cintitle"; en = "❌ Send a full path, or set TemplateBasePath in the settings so a file name is enough.`nFor example: C:\Cinegy\Titler\Scenes\Lower3rd.cintitle" }
    $catalogue['atpl.needLayerOrDevice'] = @{ ar = '❌ أرسل رقم طبقة موجبًا (مثل 4) أو اسم جهاز بأحرف إنجليزية (مثل logo):'; en = '❌ Send a positive layer number (such as 4) or a device name in Latin letters (such as logo):' }
    $catalogue['atpl.add5'] = @{ ar = '(5/5) الوصف والتصنيف - يظهران في شاشة ℹ️ وفي بحث القوالب.'; en = '(5/5) The description and the category — they show on the ℹ️ screen and in the template search.' }
    $catalogue['atpl.add5Example'] = @{ ar = "`nأرسلهما في سطر واحد مفصولين بـ | مثل:`nشريط الأخبار | أخبار`n`nأو أرسل: تخطي"; en = "`nSend them on one line separated by | such as:`nThe news ticker | news`n`nor send: skip" }
    $catalogue['atpl.missing'] = @{ ar = '<غير موجود>'; en = '&lt;not there&gt;' }
    $catalogue['atpl.noRealChanges'] = @{ ar = 'الاختلافات: لا توجد تغييرات فعلية.'; en = 'The differences: nothing actually changes.' }
    $catalogue['atpl.badJson'] = @{ ar = '❌ JSON غير صالح. أرسل تعريفًا صحيحًا أو ألغِ العملية.'; en = '❌ That JSON is not valid. Send a correct definition or cancel.' }
    $catalogue['atpl.needKey'] = @{ ar = '❌ يتطلب القالب الجديد مفتاح key.'; en = '❌ A new template needs a key.' }
    $catalogue['atpl.savedWithBackup'] = @{ ar = '✅ تم حفظ تعريف القالب مع نسخة احتياطية.'; en = '✅ The template definition was saved, with a backup.' }
    $catalogue['hlth.layersOnAir'] = @{ ar = '🟠 طبقات على الهواء'; en = '🟠 Layers on air' }
    $catalogue['hlth.allWell'] = @{ ar = '🟢 كل شيء سليم'; en = '🟢 All is well' }
    $catalogue['hlth.sync'] = @{ ar = '<b>🔄 التزامن</b>'; en = '<b>🔄 The sync</b>' }
    $catalogue['hlth.restartDisabled'] = @{ ar = "⛔ إعادة التشغيل من البوت معطّلة.`nفعّل AllowRemoteRestart من الإعدادات، وتأكد أولًا أن الجسر يعمل كخدمة أو كمهمة مجدولة تعيد تشغيله."; en = "⛔ Restarting from the bot is turned off.`nTurn AllowRemoteRestart on in the settings, and make sure first that the bridge runs as a service or as a scheduled task that brings it back." }
    $catalogue['adm.noActiveScenes'] = @{ ar = "📺 المشاهد النشطة`n• لا توجد مشاهد على الهواء حسب آخر فحص."; en = "📺 The active scenes`n• No scene is on air as of the last check." }
    $catalogue['adm.none'] = @{ ar = 'لا توجد'; en = 'none' }
    $catalogue['air.yesTestTemplate'] = @{ ar = '🧪 نعم، اختبر القالب'; en = '🧪 Yes, test the template' }
    $catalogue['air.takenOffTitle'] = @{ ar = '⚫️ <b>رُفع عن الهواء</b>'; en = '⚫️ <b>Taken off air</b>' }
    $catalogue['air.onAirNow'] = @{ ar = '🔴 <b>على الهواء الآن</b>'; en = '🔴 <b>On air now</b>' }
    $catalogue['air.staysUntilHidden'] = @{ ar = '⏱ يبقى حتى يُخفى يدويًا'; en = '⏱ It stays until it is hidden by hand' }
    $catalogue['air.cinegyAnswers'] = @{ ar = '✅ Cinegy يستجيب، وحالة الطبقات حديثة.'; en = '✅ Cinegy answers, and the layer state is fresh.' }
    $catalogue['air.noFreshState'] = @{ ar = '❌ لا حالة حديثة من Cinegy — تحقّق من عنوان المحرّك ومن الشبكة قبل أي شيء آخر.'; en = '❌ No fresh state from Cinegy — check the engine address and the network before anything else.' }
    $catalogue['air.noScenePath'] = @{ ar = '❌ لا مسار مشهد لهذا القالب في سجل القوالب.'; en = '❌ There is no scene path for this template in the template register.' }
    $catalogue['air.sceneFileThere'] = @{ ar = '✅ ملف المشهد موجود في مساره.'; en = '✅ The scene file is there at its path.' }
    $catalogue['ann.forAdmins'] = @{ ar = 'للمشرفين'; en = 'for the administrators' }
    $catalogue['ann.forOperators'] = @{ ar = 'للمشغّلين'; en = 'for the operators' }
    $catalogue['ann.forEveryone'] = @{ ar = 'للجميع'; en = 'for everyone' }
    $catalogue['ann.seen'] = @{ ar = '✅ تم الاطلاع'; en = '✅ Seen' }
    $catalogue['board.noScenePath'] = @{ ar = 'لا مسار لملف المشهد.'; en = 'There is no path to the scene file.' }
    $catalogue['board.sceneFileMissing'] = @{ ar = 'ملف المشهد غير موجود في مساره.'; en = 'The scene file is not there at its path.' }
    $catalogue['board.noTextField'] = @{ ar = 'المشهد لا يعلن حقلًا نصّيًا يُكتب فيه.'; en = 'The scene declares no text field to write into.' }
    $catalogue['board.rowDisabled'] = @{ ar = '🚫 هذا الصفّ معطّل. فعّله أولًا.'; en = '🚫 This row is disabled. Enable it first.' }
    $catalogue['board.saveFailed'] = @{ ar = '❌ تعذّر حفظ الجدول.'; en = '❌ Could not save the board.' }
    $catalogue['board.notYoursToEdit'] = @{ ar = '⛔ تحرير هذا الجدول ليس لك.'; en = '⛔ Editing this board is not yours to do.' }
    $catalogue['board.needOneField'] = @{ ar = '⛔ لا بدّ من ملء حقل واحد على الأقل.'; en = '⛔ At least one field has to be filled.' }
    $catalogue['board.fieldGone'] = @{ ar = '⛔ هذا الحقل لم يعد في المشهد.'; en = '⛔ That field is no longer in the scene.' }
    $catalogue['tpl.backupFileMissing'] = @{ ar = 'ملف النسخة غير موجود.'; en = 'The backup file is not there.' }
    $catalogue['tpl.backupEmpty'] = @{ ar = 'النسخة لا تحتوي أي قالب.'; en = 'The backup holds no template.' }
}
