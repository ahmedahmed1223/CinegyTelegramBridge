#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the flow an operator walks through and the machinery
    around it: the typed commands' replies, the scheduling wizard, the
    show/review/rollback flow, and the output relay and snapshots.

    NOT here: the typed Arabic command keywords themselves. Those are input,
    matched against what somebody types, and translating them would silently
    break every typed command the moment a station switched language.
#>

function Add-BridgeTextFlow {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- Commands, scheduling, the show flow, and the output --------------
    $catalogue['cmd.enabled'] = @{ ar = 'مفعّل'; en = 'on' }
    $catalogue['cmd.disabled'] = @{ ar = 'معطّل'; en = 'off' }
    $catalogue['cmd.empty'] = @{ ar = '(فارغ)'; en = '(empty)' }
    $catalogue['cmd.pressToToggle'] = @{ ar = 'اضغط خيارًا لتبديله أو تغيير قيمته.'; en = 'Press an option to toggle it or change its value.' }
    $catalogue['cmd.noLayersSelected'] = @{ ar = 'لا توجد طبقات محددة'; en = 'No layers are selected' }
    $catalogue['cmd.nameTooLong'] = @{ ar = '❌ الاسم يجب أن يكون حتى 60 حرفًا، ولا يحتوي على ; أو =. لم يتغيّر شيء.'; en = '❌ The name must be at most 60 characters and contain no ; or =. Nothing changed.' }
    $catalogue['cmd.noNameYet'] = @{ ar = 'لا يوجد اسم حاليًا.'; en = 'There is no name at present.' }
    $catalogue['cmd.nameEmpty'] = @{ ar = '❌ الاسم فارغ. استخدم زر «مسح الاسم» إن أردت حذفه.'; en = '❌ The name is empty. Use the "clear the name" button if you want it gone.' }
    $catalogue['cmd.layerNotInTemplates'] = @{ ar = 'هذه الطبقة لم تعد ضمن القوالب المعرّفة.'; en = 'That layer is no longer among the defined templates.' }
    $catalogue['cmd.mustBeWholeNumber'] = @{ ar = '❌ القيمة يجب أن تكون رقمًا صحيحًا. لم يتغيّر شيء.'; en = '❌ The value must be a whole number. Nothing changed.' }
    $catalogue['cmd.notNegative'] = @{ ar = '❌ القيمة لا يمكن أن تكون سالبة.'; en = '❌ The value cannot be negative.' }
    $catalogue['cmd.valueEmpty'] = @{ ar = '❌ القيمة فارغة، لم يتغيّر شيء.'; en = '❌ The value is empty; nothing changed.' }
    $catalogue['cmd.secondsRange'] = @{ ar = '⚠️ صيغة غير صالحة. الثواني يجب أن تكون من 0 إلى 59.'; en = '⚠️ Not a valid format. The seconds must be 0 to 59.' }
    $catalogue['cmd.durationFormat'] = @{ ar = '⚠️ صيغة غير صالحة. استخدم «دقائق:ثوانٍ» مثل 2:30 أو ثوانٍ فقط مثل 90.'; en = '⚠️ Not a valid format. Use minutes:seconds, like 2:30, or seconds alone, like 90.' }
    $catalogue['cmd.range1to3600'] = @{ ar = '⚠️ المدى 1–3600 ثانية (حتى ساعة).'; en = '⚠️ The range is 1–3600 seconds (up to an hour).' }
    $catalogue['cmd.limitSaveFailed'] = @{ ar = '⚠️ تعذّر حفظ الحد؛ بقيت القاعدة السابقة.'; en = '⚠️ Could not save the limit; the previous rule stands.' }
    $catalogue['cmd.resetAllTitle'] = @{ ar = '<b>♻️ استعادة كل الإعدادات الافتراضية؟</b>'; en = '<b>♻️ Restore every setting to its default?</b>' }
    $catalogue['cmd.nothingDiffers'] = @{ ar = '<i>لا إعداد يخالف الافتراضي الآن، فلن يتغيّر شيء.</i>'; en = '<i>No setting differs from its default, so nothing will change.</i>' }
    $catalogue['cmd.backupBeforeWrite'] = @{ ar = 'تُحفظ نسخة من الإعدادات الحالية قبل الكتابة، وتجدها في 🗄 نسخ الإعدادات.'; en = 'A copy of the current settings is kept before writing, in 🗄 settings backups.' }
    $catalogue['cmd.allRestored'] = @{ ar = '♻️ تمت استعادة جميع الإعدادات الافتراضية.'; en = '♻️ Every setting was restored to its default.' }
    $catalogue['cmd.simpleSettings'] = @{ ar = '🧭 الإعدادات المبسطة'; en = '🧭 Simple settings' }
    $catalogue['cmd.allSettings'] = @{ ar = '🛠 كل الإعدادات'; en = '🛠 All settings' }
    $catalogue['cmd.changedSettings'] = @{ ar = '📝 الإعدادات المعدّلة'; en = '📝 Changed settings' }
    $catalogue['cmd.noSettingMatches'] = @{ ar = '<i>لا إعداد يطابق. جرّب كلمة أقصر، أو افتح 📝 المعدّل فقط أو أحد الأبواب.</i>'; en = '<i>No setting matches. Try a shorter word, or open 📝 changed only, or one of the doors.</i>' }
    $catalogue['cmd.searchPrompt'] = @{ ar = 'أرسل اسم الإعداد أو وصفه بالعربية:'; en = 'Send the setting name or part of its description:' }
    $catalogue['cmd.rawDisabled'] = @{ ar = 'الأمر الخام معطّل من الإعدادات.'; en = 'The raw command is disabled in Settings.' }
    $catalogue['cmd.adminsOnly'] = @{ ar = 'هذا الأمر مخصص للمشرفين فقط.'; en = 'That command is for administrators only.' }
    $catalogue['cmd.adminsOnlyOption'] = @{ ar = 'هذا الخيار للمشرفين فقط.'; en = 'That option is for administrators only.' }
    $catalogue['cmd.adminsOnlyThis'] = @{ ar = 'هذا الأمر للمشرفين فقط.'; en = 'That command is for administrators only.' }
    $catalogue['cmd.pickLayer'] = @{ ar = 'اختر الطبقة:'; en = 'Choose the layer:' }
    $catalogue['cmd.aliasSaveFailed'] = @{ ar = '❌ تعذر حفظ الاسم المستعار.'; en = '❌ Could not save the alias.' }
    $catalogue['cmd.sendStart'] = @{ ar = 'أرسل /بدء لعرض القائمة الرئيسية.'; en = 'Send the start command to open the main menu.' }
    $catalogue['cmd.welcome'] = @{ ar = 'أهلاً! اختر من القائمة:'; en = 'Welcome. Choose from the menu:' }
    $catalogue['cmd.cancelled'] = @{ ar = '❌ تم إلغاء أي عملية معلّقة. اختر من القائمة:'; en = '❌ Any pending operation was cancelled. Choose from the menu:' }
    $catalogue['cmd.noticesOffNow'] = @{ ar = '🔕 تنبيهات العرض متوقّفة لك حاليًا.'; en = '🔕 Show notices are currently off for you.' }
    $catalogue['cmd.noticesOnNow'] = @{ ar = '🔔 تنبيهات العرض تصلك حاليًا.'; en = '🔔 Show notices are currently reaching you.' }
    $catalogue['cmd.noticesBack'] = @{ ar = '🔔 أعد التنبيهات'; en = '🔔 Turn the notices back on' }
    $catalogue['cmd.noticesStop'] = @{ ar = '🔕 أوقف تنبيهاتي'; en = '🔕 Stop my notices' }
    $catalogue['cmd.scheduling'] = @{ ar = '📅 الجدولة:'; en = '📅 Scheduling:' }
    $catalogue['sch.prev'] = @{ ar = '◀️ السابق'; en = '◀️ Previous' }
    $catalogue['sch.next'] = @{ ar = 'التالي ▶️'; en = 'Next ▶️' }
    $catalogue['sch.cancel'] = @{ ar = '❌ إلغاء'; en = '❌ Cancel' }
    $catalogue['sch.backDate'] = @{ ar = '◀️ التاريخ'; en = '◀️ The date' }
    $catalogue['sch.backHour'] = @{ ar = '◀️ الساعة'; en = '◀️ The hour' }
    $catalogue['sch.plus15'] = @{ ar = '⏱ +15 د'; en = '⏱ +15 min' }
    $catalogue['sch.plus30'] = @{ ar = '⏱ +30 د'; en = '⏱ +30 min' }
    $catalogue['sch.plus60'] = @{ ar = '⏱ +60 د'; en = '⏱ +60 min' }
    $catalogue['sch.calendar'] = @{ ar = '📅 اختر من التقويم'; en = '📅 Choose from the calendar' }
    $catalogue['sch.today'] = @{ ar = 'اليوم'; en = 'Today' }
    $catalogue['sch.ambiguousTime'] = @{ ar = 'الوقت غير واضح بسبب تغيير التوقيت المحلي؛ اختر وقتًا آخر.'; en = 'That time is ambiguous because the local clock changes; choose another.' }
    $catalogue['sch.mustBeFuture'] = @{ ar = 'يجب أن يكون الموعد في المستقبل.'; en = 'The time must be in the future.' }
    $catalogue['sch.onTime'] = @{ ar = 'في وقتها'; en = 'on time' }
    $catalogue['sch.mojazExecLog'] = @{ ar = '🧾 سجل تنفيذ مواعيد الموجز'; en = '🧾 Bulletin schedule execution log' }
    $catalogue['sch.newsExecLog'] = @{ ar = '🧾 سجل تنفيذ شريط الأخبار'; en = '🧾 News ticker execution log' }
    $catalogue['sch.execLog'] = @{ ar = '🧾 سجل التنفيذ'; en = '🧾 Execution log' }
    $catalogue['sch.nothingRunYet'] = @{ ar = 'لم يُنفَّذ شيء بعد.'; en = 'Nothing has run yet.' }
    $catalogue['sch.nothingRunYetHtml'] = @{ ar = '<i>لم يُنفَّذ شيء بعد.</i>'; en = '<i>Nothing has run yet.</i>' }
    $catalogue['sch.col.time'] = @{ ar = 'الوقت'; en = 'Time' }
    $catalogue['sch.col.template'] = @{ ar = 'القالب'; en = 'Template' }
    $catalogue['sch.col.result'] = @{ ar = 'النتيجة'; en = 'Result' }
    $catalogue['sch.col.delay'] = @{ ar = 'التأخير'; en = 'Delay' }
    $catalogue['sch.backToTimes'] = @{ ar = '⬅️ المواعيد'; en = '⬅️ Scheduled times' }
    $catalogue['sch.backToNews'] = @{ ar = '⬅️ شريط الأخبار'; en = '⬅️ News ticker' }
    $catalogue['sch.upcoming'] = @{ ar = '📋 الأحداث القادمة'; en = '📋 Upcoming events' }
    $catalogue['sch.backToScheduling'] = @{ ar = '⬅️ الجدولة'; en = '⬅️ Scheduling' }
    $catalogue['sch.refresh'] = @{ ar = '🔄 تحديث'; en = '🔄 Refresh' }
    $catalogue['sch.bulletin'] = @{ ar = '📑 الموجز'; en = '📑 The bulletin' }
    $catalogue['sch.news'] = @{ ar = '📰 الأخبار'; en = '📰 News' }
    $catalogue['sch.materialGone'] = @{ ar = 'مادة لم تعد في الجدول'; en = 'material no longer in the schedule' }
    $catalogue['sch.withStart'] = @{ ar = 'مع بدء'; en = 'at the start of' }
    $catalogue['sch.noTemplateKey'] = @{ ar = 'الحدث المجدول بلا مفتاح قالب.'; en = 'The scheduled event has no template key.' }
    $catalogue['sch.daily'] = @{ ar = 'يومي'; en = 'Daily' }
    $catalogue['sch.weekly'] = @{ ar = 'أسبوعي'; en = 'Weekly' }
    $catalogue['sch.once'] = @{ ar = 'مرة واحدة'; en = 'Once' }
    $catalogue['sch.eventGone'] = @{ ar = 'الحدث لم يعد متاحًا للنسخ أو التعديل.'; en = 'The event can no longer be copied or edited.' }
    $catalogue['sch.yourEventsOnly'] = @{ ar = 'يمكنك تعديل أحداثك فقط.'; en = 'You may only edit your own events.' }
    $catalogue['sch.copyEvent'] = @{ ar = 'نسخ الحدث إلى موعد جديد'; en = 'Copying the event to a new time' }
    $catalogue['sch.editEventTime'] = @{ ar = 'تعديل موعد الحدث'; en = 'Changing the event time' }
    $catalogue['sch.sendEndDate'] = @{ ar = '❌ أرسل تاريخ الانتهاء بصيغة YYYY-MM-DD.'; en = '❌ Send the end date as YYYY-MM-DD.' }
    $catalogue['sch.endBeforeStart'] = @{ ar = '❌ تاريخ الانتهاء يجب ألا يسبق أول موعد.'; en = '❌ The end date must not precede the first time.' }
    $catalogue['sch.fieldRequired'] = @{ ar = 'هذا الحقل إلزامي ولا يمكن تركه فارغًا.'; en = 'This field is required and cannot be left empty.' }
    $catalogue['sch.reviewCopy'] = @{ ar = '🔎 مراجعة نسخة الحدث'; en = '🔎 Review the copied event' }
    $catalogue['sch.reviewEdit'] = @{ ar = '🔎 مراجعة تعديل موعد الحدث'; en = '🔎 Review the changed time' }
    $catalogue['sch.review'] = @{ ar = '🔎 مراجعة الجدولة'; en = '🔎 Review the schedule' }
    $catalogue['sch.notSavedUntilConfirm'] = @{ ar = 'لن يُحفظ الحدث حتى تضغط تأكيد الجدولة.'; en = 'The event is not saved until you press confirm.' }
    $catalogue['sch.back'] = @{ ar = '❌ رجوع'; en = '❌ Back' }
    $catalogue['sch.after30s'] = @{ ar = 'بعد البدء بـ 30 ثانية'; en = '30 seconds after the start' }
    $catalogue['sch.after1m'] = @{ ar = 'بعد البدء بدقيقة'; en = 'a minute after the start' }
    $catalogue['sch.after5m'] = @{ ar = 'بعد البدء بـ 5 دقائق'; en = 'five minutes after the start' }
    $catalogue['sch.atMaterialStart'] = @{ ar = 'مع بدء المادة'; en = 'at the material start' }
    $catalogue['sch.edit'] = @{ ar = 'تعديل'; en = 'editing' }
    $catalogue['sch.delete'] = @{ ar = 'حذف'; en = 'deleting' }
    $catalogue['sch.create'] = @{ ar = 'إنشاء'; en = 'creating' }
    $catalogue['sch.saveFailed'] = @{ ar = '❌ تعذّر حفظ ملف الجدولة، لذلك لم يُعتمد الحدث.'; en = '❌ The schedule file could not be saved, so the event was not accepted.' }
    $catalogue['flow.period'] = @{ ar = 'فترة'; en = 'period' }
    $catalogue['flow.templateUnknown'] = @{ ar = 'القالب غير معروف (ربما تغيّر ملف القوالب). افتح 📋 القوالب من جديد.'; en = 'The template is unknown (the templates file may have changed). Open 📋 Templates again.' }
    $catalogue['flow.operationInProgress'] = @{ ar = 'لديك عملية جارية — أتممها أو ألغها أولًا، ثم استأنف.'; en = 'You have an operation in progress — finish or cancel it first, then resume.' }
    $catalogue['flow.noResumableDraft'] = @{ ar = 'لا مسودة منتهية قابلة للاستئناف.'; en = 'There is no expired draft to resume.' }
    $catalogue['flow.templateGoneNoResume'] = @{ ar = 'القالب لم يعد موجودًا — لا يمكن الاستئناف.'; en = 'The template no longer exists — it cannot be resumed.' }
    $catalogue['flow.fieldRequiredNoSkip'] = @{ ar = '❌ هذا الحقل مطلوب ولا يمكن تخطيه.'; en = '❌ This field is required and cannot be skipped.' }
    $catalogue['flow.fieldRequiredNoEmpty'] = @{ ar = '❌ هذا الحقل مطلوب ولا يمكن تركه فارغًا.'; en = '❌ This field is required and cannot be left empty.' }
    $catalogue['flow.reviewTitle'] = @{ ar = '<b>🔎 مراجعة قبل الإرسال</b>'; en = '<b>🔎 Review before sending</b>' }
    $catalogue['flow.freshnessWarning'] = @{ ar = '<b>⚠️ تعذّر التحقق من حداثة حالة الطبقة</b>؛ راجع شاشة الحالة قبل التأكيد عند الشك.'; en = '<b>⚠️ The layer state could not be confirmed as current</b>; check the status screen before confirming if in doubt.' }
    $catalogue['flow.unnamedScene'] = @{ ar = 'مشهد غير مسمّى'; en = 'an unnamed scene' }
    $catalogue['flow.whatWillShow'] = @{ ar = '📺 <b>ما سيظهر على الشاشة:</b>'; en = '📺 <b>What will appear on screen:</b>' }
    $catalogue['flow.spellingWarnings'] = @{ ar = '<b>✍️ تنبيهات إملائية</b> (إرشادية — لا تمنع الإرسال):'; en = '<b>✍️ Spelling warnings</b> (advisory — they do not block the send):' }
    $catalogue['flow.nothingUntilConfirm'] = @{ ar = '<i>لن يُرسل شيء إلى Cinegy حتى تضغط تأكيد الإرسال.</i>'; en = '<i>Nothing is sent to Cinegy until you press confirm.</i>' }
    $catalogue['flow.sendFieldText'] = @{ ar = 'أرسل نص الحقل'; en = 'Send the field text' }
    $catalogue['flow.typeInBox'] = @{ ar = '⌨️ <b>اكتب النص في صندوق الرسالة بالأسفل وأرسله.</b>'; en = '⌨️ <b>Type the text in the message box below and send it.</b>' }
    $catalogue['flow.noValidRollback'] = @{ ar = 'لا يوجد تراجع صالح لهذه الطبقة، أو انتهت مدته.'; en = 'There is no valid undo for this layer, or its window has passed.' }
    $catalogue['flow.layerMustStayEmpty'] = @{ ar = 'يجب أن تبقى الطبقة فارغة'; en = 'the layer must stay empty' }
    $catalogue['flow.sceneMustStay'] = @{ ar = 'يجب أن يبقى المشهد الحالي نفسه دون تغيير خارجي'; en = 'the current scene must stay the same, with no external change' }
    $catalogue['flow.beforePublish'] = @{ ar = '📷 قبل النشر'; en = '📷 Before publishing' }
    $catalogue['flow.nowOnAir'] = @{ ar = '📷 الآن على الهواء'; en = '📷 Now on air' }
    $catalogue['flow.rollbackExpired'] = @{ ar = 'انتهى أو تغير مرشح التراجع. لم يُرسل شيء.'; en = 'The undo candidate expired or changed. Nothing was sent.' }
    $catalogue['flow.layerBusy'] = @{ ar = 'الطبقة قيد عملية أخرى؛ لم يُنفذ التراجع.'; en = 'The layer is busy with another operation; the undo did not run.' }
    $catalogue['flow.cinegyChangedRollback'] = @{ ar = '⛔ تغيرت حالة Cinegy أو تعذر التحقق منها؛ أُلغي التراجع ولم يُرسل شيء.'; en = '⛔ The Cinegy state changed or could not be verified; the undo was cancelled and nothing was sent.' }
    $catalogue['flow.durationPositive'] = @{ ar = 'المدة يجب أن تكون أكبر من صفر.'; en = 'The time must be greater than zero.' }
    $catalogue['flow.timerNotSet'] = @{ ar = '⚠️ لم يُضبط المؤقت: تعذّر ربط المشهد الحالي بهوية Cinegy مؤكدة. أخفه يدويًا عند الحاجة.'; en = '⚠️ The timer was not set: the current scene could not be tied to a confirmed Cinegy identity. Hide it by hand when needed.' }
    $catalogue['flow.sendPositiveSeconds'] = @{ ar = '❌ أرسل رقمًا صحيحًا أكبر من صفر (بالثواني).'; en = '❌ Send a whole number greater than zero, in seconds.' }
    $catalogue['flow.noPreviousShow'] = @{ ar = 'لا يوجد إظهار سابق لإعادته.'; en = 'There is no previous show to repeat.' }
    $catalogue['flow.previousTemplateGone'] = @{ ar = 'القالب السابق لم يعد موجودًا في ملف القوالب.'; en = 'The previous template is no longer in the templates file.' }
    $catalogue['flow.safeRetry'] = @{ ar = '🔁 إعادة محاولة آمنة'; en = '🔁 Retry safely' }
    $catalogue['flow.log48h'] = @{ ar = '📅 سجل 48 ساعة'; en = '📅 48-hour log' }
    $catalogue['flow.refresh'] = @{ ar = '🔄 تحديث'; en = '🔄 Refresh' }
    $catalogue['flow.home'] = @{ ar = '🏠 القائمة'; en = '🏠 Menu' }
    $catalogue['flow.sinceLastStart'] = @{ ar = 'منذ آخر تشغيل'; en = 'since the last start' }
    $catalogue['flow.myLatest'] = @{ ar = '🧾 آخر عملياتك'; en = '🧾 Your latest operations' }
    $catalogue['flow.checkConnection'] = @{ ar = 'افحص الاتصال ثم أعد المحاولة'; en = 'Check the connection, then try again' }
    $catalogue['flow.checkPermission'] = @{ ar = 'راجع صلاحيتك أو حالة Cinegy'; en = 'Check your permission or the Cinegy state' }
    $catalogue['flow.sendToAdmin'] = @{ ar = 'أرسله للمشرف مع وصف ما حدث.'; en = 'Send it to an administrator with a description of what happened.' }
    $catalogue['flow.noAttemptToReview'] = @{ ar = 'لا توجد محاولة عرض قابلة للمراجعة.'; en = 'There is no show attempt to review.' }
    $catalogue['flow.attemptTemplateGone'] = @{ ar = 'القالب المستخدم في المحاولة لم يعد موجودًا.'; en = 'The template used in that attempt no longer exists.' }
    $catalogue['flow.presetMissing'] = @{ ar = 'النص الجاهز غير موجود.'; en = 'That ready-made text does not exist.' }
    $catalogue['flow.templateGone'] = @{ ar = 'القالب لم يعد موجودًا.'; en = 'The template no longer exists.' }
    $catalogue['flow.presetCreate'] = @{ ar = 'إنشاء'; en = 'creating' }
    $catalogue['flow.presetEdit'] = @{ ar = 'تعديل القيم'; en = 'editing the values' }
    $catalogue['flow.presetRename'] = @{ ar = 'إعادة تسمية'; en = 'renaming' }
    $catalogue['flow.presetDelete'] = @{ ar = 'حذف'; en = 'deleting' }
    $catalogue['flow.reviewPreset'] = @{ ar = '🔎 مراجعة تغيير النص الجاهز'; en = '🔎 Review the ready-made text change' }
    $catalogue['flow.notWrittenUntilSave'] = @{ ar = 'لن يُعدّل ملف القوالب حتى تضغط حفظ التغيير.'; en = 'The templates file is not changed until you press save.' }
    $catalogue['flow.nameNotEmpty'] = @{ ar = 'الاسم لا يمكن أن يكون فارغًا.'; en = 'The name cannot be empty.' }
    $catalogue['flow.reviewExpired'] = @{ ar = 'انتهت مراجعة التغيير. ابدأ من جديد.'; en = 'The change review expired. Start again.' }
    $catalogue['flow.presetSaved'] = @{ ar = '✅ تم حفظ تغيير النص الجاهز، وأُنشئت نسخة احتياطية.'; en = '✅ The ready-made text change was saved, and a backup was made.' }
    $catalogue['flow.noTemplatesDefined'] = @{ ar = 'لا توجد قوالب معرّفة حاليًا.'; en = 'No templates are defined at present.' }
    $catalogue['media.primary'] = @{ ar = 'البث الأساسي'; en = 'the primary source' }
    $catalogue['media.backup'] = @{ ar = 'بث Cinegy الاحتياطي'; en = 'the Cinegy backup source' }
    $catalogue['media.restartFailed'] = @{ ar = '❌ تعذرت إعادة تشغيل البث بعد تبديل المصدر.'; en = '❌ The relay could not be restarted after switching source.' }
    $catalogue['media.snapshotsDisabled'] = @{ ar = 'خاصية الصور معطّلة من الإعدادات.'; en = 'Snapshots are disabled in Settings.' }
    $catalogue['media.snapshotBusy'] = @{ ar = '⏳ لقطة أخرى قيد الالتقاط الآن - انتظر لحظات ثم أعد المحاولة.'; en = '⏳ Another snapshot is being taken — wait a moment and try again.' }
    $catalogue['media.sourceUrlUnset'] = @{ ar = '❌ LiveStream.SourceUrl غير مضبوط في config.json.'; en = '❌ LiveStream.SourceUrl is not set in config.json.' }
    $catalogue['media.ffmpegMissing'] = @{ ar = '❌ لم يتم العثور على ffmpeg.exe. ثبّته أولًا (winget install ffmpeg).'; en = '❌ ffmpeg.exe was not found. Install it first (winget install ffmpeg).' }
    $catalogue['media.grabbing'] = @{ ar = '⏳ جاري التقاط صورة من البث...'; en = '⏳ Grabbing a frame from the output...' }
    $catalogue['media.grabTimedOut'] = @{ ar = 'انتهت مهلة التقاط الصورة'; en = 'the snapshot timed out' }
    $catalogue['media.grabTimedOutMsg'] = @{ ar = '❌ انتهت مهلة التقاط الصورة - تأكد أن المصدر قابل للوصول.'; en = '❌ The snapshot timed out — check the source is reachable.' }
    $catalogue['media.tryingBackup'] = @{ ar = '⚠️ تعذّر التقاط الأساسي؛ أجرب الآن مصدر Cinegy الاحتياطي.'; en = '⚠️ The primary grab failed; trying the Cinegy backup source now.' }
    $catalogue['media.stoppedNoFfmpeg'] = @{ ar = 'متوقف — ffmpeg غير موجود'; en = 'stopped — ffmpeg is missing' }
    $catalogue['media.runningMonitorOff'] = @{ ar = 'يعمل، والمراقبة الدورية معطلة'; en = 'running, with periodic monitoring off' }
    $catalogue['media.running'] = @{ ar = 'يعمل'; en = 'running' }
    $catalogue['media.notRun'] = @{ ar = 'لم يُنفّذ'; en = 'has not run' }
    $catalogue['media.failedNoFfmpeg'] = @{ ar = 'تعذّر — ffmpeg غير موجود'; en = 'failed — ffmpeg is missing' }
    $catalogue['media.failedNoUrl'] = @{ ar = 'تعذّر — رابط المصدر الأساسي غير مضبوط'; en = 'failed — the primary source URL is not set' }
    $catalogue['media.unavailable'] = @{ ar = 'غير متاح'; en = 'unavailable' }
    $catalogue['media.grabbedNoLuma'] = @{ ar = 'تم التقاط الصورة (تعذّر قياس السطوع)'; en = 'a frame was grabbed (the luminance could not be measured)' }
    $catalogue['media.cinegyBackup'] = @{ ar = 'Cinegy الاحتياطي'; en = 'the Cinegy backup' }
    $catalogue['media.primarySource'] = @{ ar = 'المصدر الأساسي'; en = 'the primary source' }
    $catalogue['media.notSet'] = @{ ar = 'غير مضبوط'; en = 'not set' }
    $catalogue['media.notStarted'] = @{ ar = 'لم يبدأ بعد'; en = 'not started yet' }
    $catalogue['media.monitorDisabled'] = @{ ar = 'معطلة'; en = 'disabled' }
    $catalogue['media.sourceMonitor'] = @{ ar = '📡 مراقب المصدر'; en = '📡 Source monitor' }
    $catalogue['media.primaryReturned'] = @{ ar = '💡 عاد المصدر الأساسي؛ تمت العودة إليه من مصدر Cinegy الاحتياطي.'; en = '💡 The primary source is back; switched to it from the Cinegy backup.' }
    $catalogue['media.outputUnreachable'] = @{ ar = 'تعذّر الوصول إلى مخرج البث'; en = 'the channel output could not be reached' }
    $catalogue['media.channelSilent'] = @{ ar = '• القناة: لا تُجيب — ابدأ من Cinegy Air نفسه.'; en = '• The channel: not answering — start from Cinegy Air itself.' }
    $catalogue['media.nextOpenAir'] = @{ ar = '🔎 الخطوة التالية: افتح Cinegy Air وتأكد أن المحرك يعمل.'; en = '🔎 Next step: open Cinegy Air and check the engine is running.' }
    $catalogue['media.channelNormal'] = @{ ar = '• القناة: تُجيب ومخرجها طبيعي.'; en = '• The channel: answering, and its output is normal.' }
    $catalogue['media.relayRunning'] = @{ ar = '• الترحيل: يعمل.'; en = '• The relay: running.' }
    $catalogue['media.relayShouldRun'] = @{ ar = '• الترحيل: مطلوب تشغيله لكنه غير عامل — أعد تشغيل البث المباشر.'; en = '• The relay: it should be running and is not — restart the live relay.' }
    $catalogue['media.nextRestartRelay'] = @{ ar = '🔎 الخطوة التالية: أعد تشغيل البث المباشر من القائمة.'; en = '🔎 Next step: restart the live relay from the menu.' }
    $catalogue['media.nextCheckServer'] = @{ ar = '🔎 الخطوة التالية: تحقق من سيرفر البث وشبكته.'; en = '🔎 Next step: check the streaming server and its network.' }
    $catalogue['media.sourceUnset'] = @{ ar = '• المصدر: غير مضبوط في الإعدادات.'; en = '• The source: not set in Settings.' }
    $catalogue['media.nextAskSnapshot'] = @{ ar = '🔎 الخطوة التالية: اطلب لقطة من القائمة لترى الصورة الحالية.'; en = '🔎 Next step: ask for a snapshot from the menu to see the current picture.' }
    $catalogue['media.outputBack'] = @{ ar = '💡 عاد الوصول إلى مخرج البث بعد تعذّر التقاطه.'; en = '💡 The channel output is reachable again after the grab failures.' }
    $catalogue['media.copyReady'] = @{ ar = '📋 نسخة جاهزة للنسخ'; en = '📋 A copy ready to paste' }
    $catalogue['media.stoppedRetrying'] = @{ ar = '🟠 متوقف - محاولة إعادة التشغيل'; en = '🟠 Stopped — trying to restart' }
    $catalogue['media.stopped'] = @{ ar = '⚪ متوقف'; en = '⚪ Stopped' }
    $catalogue['media.rtmpUnset'] = @{ ar = 'لم يتم ضبط رابط RTMP بعد - استخدم زر 🔗 رابط البث أولًا.'; en = 'The RTMP link is not set yet — use the 🔗 stream link button first.' }
    $catalogue['media.sourceUrlUnsetPlain'] = @{ ar = 'LiveStream.SourceUrl غير مضبوط في config.json.'; en = 'LiveStream.SourceUrl is not set in config.json.' }
    $catalogue['media.ffmpegMissingPlain'] = @{ ar = 'لم يتم العثور على ffmpeg.exe. ثبّته أولًا (winget install ffmpeg).'; en = 'ffmpeg.exe was not found. Install it first (winget install ffmpeg).' }
    $catalogue['media.relayDisabled'] = @{ ar = 'البث المباشر معطّل من الإعدادات.'; en = 'The live relay is disabled in Settings.' }
    $catalogue['media.alreadyRunning'] = @{ ar = 'البث يعمل بالفعل.'; en = 'The relay is already running.' }
    $catalogue['media.starting'] = @{ ar = '⏳ جاري بدء البث...'; en = '⏳ Starting the relay...' }
    $catalogue['media.noneRunning'] = @{ ar = 'لا يوجد بث يعمل حاليًا.'; en = 'No relay is running.' }
    $catalogue['media.stoppedOk'] = @{ ar = '⏹ تم إيقاف البث.'; en = '⏹ The relay was stopped.' }
    $catalogue['media.runningNow'] = @{ ar = '▶️ البث يعمل الآن.'; en = '▶️ The relay is running now.' }
    $catalogue['media.relayStopped'] = @{ ar = '⚠️ توقف البث المباشر (إعادة التشغيل التلقائي معطّلة).'; en = '⚠️ The live relay stopped (automatic restart is off).' }
    $catalogue['media.sendRtmp'] = @{ ar = 'أرسل رابط RTMP الكامل (الخادم + المفتاح معًا) من إعدادات بث فيديو تشات تليجرام:'; en = 'Send the full RTMP link (server and key together) from the Telegram video chat streaming settings:' }
    $catalogue['media.noUrlGiven'] = @{ ar = 'لم يتم إدخال رابط، لم يتغيّر شيء.'; en = 'No link was given; nothing changed.' }
    $catalogue['media.rtmpPrefix'] = @{ ar = '❌ الرابط يجب أن يبدأ بـ rtmp:// أو rtmps://.'; en = '❌ The link must start with rtmp:// or rtmps://.' }
}
