#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds what a press gets back: the refusals, the prompts that ask
    for a value, the confirmations, and the "that expired, start again" lines
    a bot with a chat history has to say more often than any other.

    Its own file because these are short, numerous, and read in isolation -
    an operator sees one of them at a time, with none of its neighbours.
#>

function Add-BridgeTextReplies {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- Answers to a button press --------------------------------------
    $catalogue['reply.adminOnly'] = @{ ar = 'هذا الخيار للمشرفين فقط.'; en = 'That option is for administrators only.' }
    $catalogue['reply.checkAdminOwner'] = @{ ar = 'هذا الفحص متاح للمشرف والمالك فقط.'; en = 'That check is for administrators and the owner only.' }
    $catalogue['reply.noticeAdminOwner'] = @{ ar = 'إعداد تنبيه القالب متاح للمشرف والمالك فقط.'; en = 'The template notice setting is for administrators and the owner only.' }
    $catalogue['reply.ownerOnlyAdmins'] = @{ ar = '👑 تعيين المشرفين للمالك وحده.'; en = '👑 Appointing administrators is the owners alone.' }
    $catalogue['reply.sheetPullDenied'] = @{ ar = 'سحب الشيت غير مسموح لك. اطلب من المشرف تفعيله.'; en = 'You may not pull the sheet. Ask an administrator to enable it.' }
    $catalogue['reply.sheetPullDeniedShort'] = @{ ar = 'سحب الشيت غير مسموح لك.'; en = 'You may not pull the sheet.' }
    $catalogue['reply.newsRestoreAdminOnly'] = @{ ar = 'استعادة نسخ الأخبار للمشرف وحده.'; en = 'Restoring news backups is for administrators alone.' }
    $catalogue['reply.urgentExpired'] = @{ ar = '⚠️ انتهت صلاحية الأزرار. افتح العواجل من جديد.'; en = '⚠️ These buttons have expired. Open the urgent board again.' }
    $catalogue['reply.urgentChanged'] = @{ ar = '⚠️ تغيّر الجدول أو انتهت صلاحية الأزرار. افتح العواجل من جديد.'; en = '⚠️ The board changed or the buttons expired. Open the urgent board again.' }
    $catalogue['reply.urgentItemChanged'] = @{ ar = '⚠️ لم يُنفّذ الطلب: تغيّر الخبر أو العرض أو انتهت صلاحية التأكيد. افتح الخبر من جديد.'; en = '⚠️ Nothing was done: the story, the display or the confirmation changed. Open the story again.' }
    $catalogue['reply.sheetMatchesAir'] = @{ ar = 'ℹ️ الشيت مطابق لما على الهواء؛ لم يتغير شيء.'; en = 'ℹ️ The sheet matches what is on air; nothing changed.' }
    $catalogue['reply.noDraftOfYours'] = @{ ar = 'لا توجد مسودة مملوكة لك.'; en = 'You do not hold a draft.' }
    $catalogue['reply.sendNewStory'] = @{ ar = 'أرسل نص الخبر الجديد — أو الصق عدّة أخبار، خبرًا في كل سطر:'; en = 'Send the new headline text — or paste several, one per line:' }
    $catalogue['reply.yesPublish'] = @{ ar = '✅ نعم، انشر'; en = '✅ Yes, publish' }
    $catalogue['reply.cancelWord'] = @{ ar = 'إلغاء'; en = 'Cancel' }
    $catalogue['reply.notPublished'] = @{ ar = 'لم يتم النشر'; en = 'It was not published' }
    $catalogue['reply.tickerPublished'] = @{ ar = '✅ نُشر شريط الأخبار على الهواء، مع نسخة احتياطية.'; en = '✅ The news ticker was published to air, with a backup kept.' }
    $catalogue['reply.appendMine'] = @{ ar = '➕ أضف أخباري إلى الحالي'; en = '➕ Add mine to what is there' }
    $catalogue['reply.replaceAll'] = @{ ar = '♻️ استبدل بالكامل بمسودتي'; en = '♻️ Replace it entirely with my draft' }
    $catalogue['reply.cancel'] = @{ ar = '❌ إلغاء'; en = '❌ Cancel' }
    $catalogue['reply.sendReplacementColon'] = @{ ar = 'أرسل النص البديل للخبر:'; en = 'Send the replacement text for the headline:' }
    $catalogue['reply.sendReplacement'] = @{ ar = 'أرسل النص البديل للخبر'; en = 'Send the replacement text for the headline' }
    $catalogue['reply.backToOrder'] = @{ ar = '⬅️ رجوع للترتيب'; en = '⬅️ Back to the ordering' }
    $catalogue['reply.headlineDeleted'] = @{ ar = '🗑 حُذف هذا الخبر من المسودة.'; en = '🗑 That headline was deleted from the draft.' }
    $catalogue['reply.deleteNotAllowed'] = @{ ar = '⛔ الحذف غير مسموح.'; en = '⛔ Deleting is not allowed.' }
    $catalogue['reply.alreadyFirst'] = @{ ar = '⛔ الخبر في أول القائمة بالفعل.'; en = '⛔ The headline is already first.' }
    $catalogue['reply.alreadyLast'] = @{ ar = '⛔ الخبر في آخر القائمة بالفعل.'; en = '⛔ The headline is already last.' }
    $catalogue['reply.appended'] = @{ ar = '✅ أُضيفت أخبارك إلى النص الحالي ونُشرت على الهواء.'; en = '✅ Your headlines were added to the current text and published to air.' }
    $catalogue['reply.replaced'] = @{ ar = '✅ استُبدل النص بالكامل بمسودتك ونُشر على الهواء. النص السابق محفوظ في النسخ.'; en = '✅ The text was replaced entirely with your draft and published. The previous text is kept in the backups.' }
    $catalogue['reply.yesClearDraft'] = @{ ar = 'نعم، امسح المسودة'; en = 'Yes, clear the draft' }
    $catalogue['reply.confirmClearDraft'] = @{ ar = '⚠️ سيُمسح كل محتوى المسودة فقط. هل تؤكد؟'; en = '⚠️ Only the draft content will be cleared. Confirm?' }
    $catalogue['reply.draftCleared'] = @{ ar = '✅ مُسحت المسودة. لم يُمس الملف الحي.'; en = '✅ The draft was cleared. The live file was not touched.' }
    $catalogue['reply.notAllowed'] = @{ ar = '⛔ غير مسموح.'; en = '⛔ Not allowed.' }
    $catalogue['reply.restore'] = @{ ar = '✅ استعادة'; en = '✅ Restore' }
    $catalogue['reply.confirmRestore'] = @{ ar = '⚠️ تأكيد الاستعادة؟ ستُحفظ الحالة الحالية أولًا.'; en = '⚠️ Confirm the restore? The current state will be saved first.' }
    $catalogue['reply.restored'] = @{ ar = '✅ تمت الاستعادة وحفظت الحالة السابقة.'; en = '✅ Restored, and the previous state was saved.' }
    $catalogue['reply.draftHandedOver'] = @{ ar = '🤝 سُلّمت المسودة بما فيها. أول من يضغط ✏️ يتابع نفس القائمة.'; en = '🤝 The draft was handed over as it is. Whoever presses ✏️ first continues the same list.' }
    $catalogue['reply.sendTxt'] = @{ ar = '📥 أرسل ملف TXT UTF-8. سيُستورد إلى المسودة فقط ثم يمكنك معاينته ونشره.'; en = '📥 Send a UTF-8 TXT file. It is imported into the draft only; you can then preview and publish it.' }
    $catalogue['reply.extensionExpired'] = @{ ar = '⚠️ انتهت صلاحية عرض التمديد أو تم استخدامه.'; en = '⚠️ The extension offer has expired or was already used.' }
    $catalogue['reply.sendRowText'] = @{ ar = 'أرسل نصّ الصفّ — أو الصق عدّة صفوف، صفًّا في كل سطر'; en = 'Send the row text — or paste several rows, one per line' }
    $catalogue['reply.pasteRows'] = @{ ar = '📋 ألصق الصفوف، سطرًا لكل صفّ.'; en = '📋 Paste the rows, one line per row.' }
    $catalogue['reply.pasteLimit'] = @{ ar = 'الرسالة الواحدة محدودة بـ4096 حرفًا — ألصق على دفعات، فاللصق يُضيف ولا يستبدل.'; en = 'One message is limited to 4096 characters — paste in batches; a paste adds and does not replace.' }
    $catalogue['reply.sendNewUrgent'] = @{ ar = 'أرسل نصّ العاجل الجديد:'; en = 'Send the new urgent text:' }
    $catalogue['reply.sendUrgentReplacement'] = @{ ar = 'أرسل النصّ البديل للعاجل'; en = 'Send the replacement urgent text' }
    $catalogue['reply.sendUrgentTitle'] = @{ ar = 'أرسل عنوان العاجل'; en = 'Send the urgent items title' }
    $catalogue['reply.noReadyUrgent'] = @{ ar = 'ℹ️ لا يوجد عاجل جاهز للتشغيل.'; en = 'ℹ️ There is no urgent item ready to play.' }
    $catalogue['reply.noRunToStop'] = @{ ar = 'ℹ️ لا يوجد تشغيل جدول يمكن إيقافه الآن.'; en = 'ℹ️ There is no board run to stop right now.' }
    $catalogue['reply.confirmClearRows'] = @{ ar = '⚠️ مسح كل صفوف هذا الموجز؟ لا يؤثر على ما هو على الهواء الآن.'; en = '⚠️ Clear every row of this bulletin? It does not affect what is on air now.' }
    $catalogue['reply.yesClearRows'] = @{ ar = '🧹 نعم، امسح الصفوف'; en = '🧹 Yes, clear the rows' }
    $catalogue['reply.yesDeleteBulletin'] = @{ ar = '🗑 نعم، احذف الموجز'; en = '🗑 Yes, delete the bulletin' }
    $catalogue['reply.cancelled'] = @{ ar = 'تم الإلغاء.'; en = 'Cancelled.' }
    $catalogue['reply.reviewExpired'] = @{ ar = 'انتهت أو تغيّرت مراجعة الإرسال. ابدأ من جديد.'; en = 'The send review expired or changed. Start again.' }
    $catalogue['reply.noEditableReview'] = @{ ar = 'لا توجد مراجعة قابلة للتعديل. ابدأ من جديد.'; en = 'There is no review to edit. Start again.' }
    $catalogue['reply.noPreviousStep'] = @{ ar = 'لا توجد خطوة سابقة متاحة.'; en = 'There is no previous step.' }
    $catalogue['reply.nothingToPreview'] = @{ ar = 'لا توجد قيم مدخلة لمعاينتها بعد.'; en = 'Nothing has been entered to preview yet.' }
    $catalogue['reply.hideAllExpired'] = @{ ar = 'انتهى أو تغيّر طلب إخفاء الكل. ابدأ من جديد.'; en = 'The hide-all request expired or changed. Start again.' }
    $catalogue['reply.inputDraftExpired'] = @{ ar = 'انتهت مسودة الإدخال. ابدأ من جديد.'; en = 'The input draft expired. Start again.' }
    $catalogue['reply.recentValueGone'] = @{ ar = 'القيمة الحديثة لم تعد متاحة.'; en = 'That recent value is no longer available.' }
    $catalogue['reply.pickTemplate'] = @{ ar = 'اختر القالب لإظهاره أو استخدم البحث والتصنيفات:'; en = 'Choose a template to show, or use the search and the categories:' }
    $catalogue['reply.pickCategory'] = @{ ar = '🗂 اختر تصنيف القوالب:'; en = '🗂 Choose a template category:' }
    $catalogue['reply.categoryGone'] = @{ ar = 'التصنيف لم يعد متاحًا.'; en = 'That category is no longer available.' }
    $catalogue['reply.templateGone'] = @{ ar = 'القالب لم يعد متاحًا.'; en = 'That template is no longer available.' }
    $catalogue['reply.removedFrom'] = @{ ar = 'أزيل من'; en = 'removed from' }
    $catalogue['reply.addedTo'] = @{ ar = 'أضيف إلى'; en = 'added to' }
    $catalogue['reply.favouritesSaveFailed'] = @{ ar = '⚠️ تعذّر حفظ المفضلة. راجع السجل ثم أعد المحاولة.'; en = '⚠️ Could not save the favourites. Check the log and try again.' }
    $catalogue['reply.pickTemplateThenHide'] = @{ ar = 'اختر القالب، ثم حدّد مدة الإخفاء التلقائي:'; en = 'Choose the template, then set the auto-hide time:' }
    $catalogue['reply.pickLayerToHide'] = @{ ar = 'اختر الطبقة لإخفائها:'; en = 'Choose the layer to hide:' }
    $catalogue['reply.pickLayerToExit'] = @{ ar = 'اختر الطبقة للخروج من مشهدها:'; en = 'Choose the layer whose scene to exit:' }
    $catalogue['reply.noticesOff'] = @{ ar = '🔕 أُوقفت تنبيهات العرض لك.'; en = '🔕 Show notices are off for you.' }
    $catalogue['reply.noticesBackButton'] = @{ ar = '🔔 أعد التنبيهات'; en = '🔔 Turn the notices back on' }
    $catalogue['reply.noticesOn'] = @{ ar = '🔔 عادت تنبيهات العرض لك.'; en = '🔔 Show notices are back on for you.' }
    $catalogue['reply.pickTemplateShort'] = @{ ar = 'اختر القالب:'; en = 'Choose the template:' }
    $catalogue['reply.pickTemplateField'] = @{ ar = 'اختر القالب لتحديث أحد حقوله:'; en = 'Choose the template whose field to update:' }
    $catalogue['reply.handoverRecorded'] = @{ ar = '✅ سُجِّل التسليم.'; en = '✅ The handover was recorded.' }
    $catalogue['reply.clearExpired'] = @{ ar = 'انتهى أو تغيّر طلب المسح. افتح التشخيص وابدأ من جديد.'; en = 'The clear request expired or changed. Open diagnostics and start again.' }
    $catalogue['reply.logCleared'] = @{ ar = '✅ تم مسح السجل المحدد بأمان.'; en = '✅ The selected log was cleared safely.' }
    $catalogue['reply.logClearFailed'] = @{ ar = '❌ تعذر مسح السجل. راجع سجل التشغيل وصلاحيات الملفات.'; en = '❌ Could not clear the log. Check the runtime log and the file permissions.' }
    $catalogue['reply.layersScreenDenied'] = @{ ar = '⛔ شاشة الطبقات ليست متاحة لك.'; en = '⛔ The layers screen is not available to you.' }
    $catalogue['reply.nameWord'] = @{ ar = 'اسم'; en = 'name' }
    $catalogue['reply.helpIndex'] = @{ ar = '📖 فهرس المساعدة'; en = '📖 Help index' }
    $catalogue['reply.menu'] = @{ ar = '🏠 القائمة'; en = '🏠 Menu' }
    $catalogue['reply.quietTwoHours'] = @{ ar = '🔇 هدوء ساعتين: غير العاجل يُجمَّع، والعاجل يصلك.'; en = '🔇 Two hours quiet: the non-urgent is held, the urgent still reaches you.' }
    $catalogue['reply.quietEnded'] = @{ ar = '🔊 انتهى الهدوء.'; en = '🔊 The quiet period has ended.' }
    $catalogue['reply.recordedThanks'] = @{ ar = 'سُجّل، شكرًا.'; en = 'Recorded, thank you.' }
    $catalogue['reply.copyAndSend'] = @{ ar = 'انسخ الرسالة أعلاه وأرسلها لمن يحتاجها.'; en = 'Copy the message above and send it to whoever needs it.' }
    $catalogue['reply.fullChangelog'] = @{ ar = '📄 سجل التغييرات التقني الكامل.'; en = '📄 The full technical changelog.' }
    $catalogue['reply.sendFileFailed'] = @{ ar = 'تعذّر إرسال الملف. حاول مرة أخرى.'; en = 'Could not send the file. Try again.' }
    $catalogue['reply.changelogMissing'] = @{ ar = 'ملف CHANGELOG.md غير موجود بجانب الجسر.'; en = 'CHANGELOG.md is not beside the bridge.' }
    $catalogue['reply.sendSettingsFile'] = @{ ar = '📥 أرسل ملف الإعدادات المُصدَّر من هذا الجسر. ستراجع التغييرات قبل تطبيقها.'; en = '📥 Send the settings file exported from this bridge. You will review the changes before they are applied.' }
    $catalogue['reply.adminTools'] = @{ ar = '🗂 أدوات الإدارة'; en = '🗂 Admin tools' }
    $catalogue['reply.thanksRecorded'] = @{ ar = '✅ شكرًا، سُجّل اطّلاعك.'; en = '✅ Thank you, your acknowledgement was recorded.' }
    $catalogue['reply.pullFailed'] = @{ ar = 'تعذّر السحب.'; en = 'The pull failed.' }
    $catalogue['reply.reEnable'] = @{ ar = 'إعادة تفعيل'; en = 're-enabling' }
    $catalogue['reply.disableWord'] = @{ ar = 'تعطيل'; en = 'disabling' }
    $catalogue['reply.promoteToAdmin'] = @{ ar = 'ترقية إلى مشرف'; en = 'promotion to administrator' }
    $catalogue['reply.demoteToOperator'] = @{ ar = 'خفض إلى مشغّل'; en = 'demotion to operator' }
    $catalogue['reply.youWerePromoted'] = @{ ar = '👑 تمت ترقيتك إلى مشرف. أدوات الإدارة صارت متاحة لك من القائمة.'; en = '👑 You have been promoted to administrator. The admin tools are now in your menu.' }
    $catalogue['reply.youWereDemoted'] = @{ ar = 'ℹ️ تم خفض صلاحيتك إلى مشغّل. أدوات الإدارة لم تعد متاحة.'; en = 'ℹ️ You have been returned to operator. The admin tools are no longer available.' }
    $catalogue['reply.nothingMoreToShow'] = @{ ar = 'لم يعد هناك المزيد لعرضه - اطلب الشاشة من جديد.'; en = 'There is nothing more to show — ask for the screen again.' }
    $catalogue['reply.schedulingIntro'] = @{ ar = '📅 جدولة العروض وإدارة الأحداث القادمة:'; en = '📅 Scheduling shows and managing the coming events:' }
    $catalogue['reply.clockInvalid'] = @{ ar = '❌ ساعة الجهاز أو المنطقة الزمنية غير صالحة للجدولة.'; en = '❌ The machine clock or time zone is not valid for scheduling.' }
    $catalogue['reply.pickTemplateToSchedule'] = @{ ar = 'اختر القالب المراد جدولته:'; en = 'Choose the template to schedule:' }
    $catalogue['reply.pickDay'] = @{ ar = '📅 اختر اليوم:'; en = '📅 Choose the day:' }
    $catalogue['reply.materialUnreadable'] = @{ ar = '⛔ تعذّر قراءة جدول المواد من القناة الآن — احفظ بالموعد الحالي أو أعد المحاولة.'; en = '⛔ The material schedule could not be read from the channel — save with the current time or try again.' }
    $catalogue['reply.noUpcomingMaterial'] = @{ ar = 'لا توجد مواد قادمة في جدول القناة للربط بها.'; en = 'There is no upcoming material in the channel schedule to link to.' }
    $catalogue['reply.pickMaterial'] = @{ ar = '🎞 اختر المادة التي يُربط بها العرض:'; en = '🎞 Choose the material to tie the show to:' }
    $catalogue['reply.sendEndDate'] = @{ ar = '📆 أرسل آخر تاريخ مسموح للتكرار بصيغة YYYY-MM-DD.'; en = '📆 Send the last date the repeat may run, as YYYY-MM-DD.' }
    $catalogue['reply.yesCancel'] = @{ ar = '✅ نعم، إلغاء'; en = '✅ Yes, cancel it' }
    $catalogue['reply.back'] = @{ ar = '❌ رجوع'; en = '❌ Back' }
    $catalogue['reply.eventCancelled'] = @{ ar = '✅ تم إلغاء الحدث.'; en = '✅ The event was cancelled.' }
    $catalogue['reply.eventCancelFailed'] = @{ ar = 'تعذر إلغاء الحدث؛ ربما نُفّذ أو أُلغي مسبقًا.'; en = 'The event could not be cancelled; it may have run or been cancelled already.' }
    $catalogue['reply.yesDelete'] = @{ ar = '🗑 نعم، احذف'; en = '🗑 Yes, delete' }
    $catalogue['reply.deleteFailed'] = @{ ar = 'تعذّر الحذف.'; en = 'The delete failed.' }
    $catalogue['reply.rawCommandUsage'] = @{ ar = 'أرسل الأمر بصيغة: /أمر Device Cmd [Op1]'; en = 'Send the command as: /command Device Cmd [Op1]' }
    $catalogue['reply.sendBulletinName'] = @{ ar = '📝 أرسل اسم الموجز الجديد.'; en = '📝 Send the new bulletins name.' }
    $catalogue['reply.sendSeconds'] = @{ ar = 'أرسل المدة بالثواني (رقم فقط):'; en = 'Send the time in seconds (a number only):' }
    $catalogue['reply.alertExpiredOrOther'] = @{ ar = 'انتهى التنبيه أو أنه مخصص لمستخدم آخر.'; en = 'The alert has expired, or it belongs to somebody else.' }
    $catalogue['reply.reminderSet'] = @{ ar = '⏰ تم ضبط التذكير: سيصلك تنبيه جديد بعد 5 دقائق إن بقي القالب ظاهرًا.'; en = '⏰ Reminder set: you will be told again in five minutes if the template is still showing.' }
    $catalogue['reply.reminderSaveFailed'] = @{ ar = '⚠️ تعذّر حفظ التذكير. حاول مجددًا.'; en = '⚠️ Could not save the reminder. Try again.' }
    $catalogue['reply.handledRecorded'] = @{ ar = '✅ تم تسجيل المعالجة وإلغاء تنبيه المتابعة.'; en = '✅ Recorded as handled, and the follow-up was cancelled.' }
    $catalogue['reply.handledSaveFailed'] = @{ ar = '⚠️ تعذّر حفظ إلغاء المتابعة؛ ما زال التنبيه قائمًا. حاول مجددًا.'; en = '⚠️ Could not save that; the alert still stands. Try again.' }
    $catalogue['reply.noUpdatableFields'] = @{ ar = 'لا توجد حقول قابلة للتحديث في هذا القالب.'; en = 'This template has no fields that can be updated.' }
    $catalogue['reply.pickField'] = @{ ar = 'اختر الحقل لتحديثه:'; en = 'Choose the field to update:' }
    $catalogue['reply.fieldGone'] = @{ ar = 'الحقل غير موجود (ربما تغيّر ملف القوالب).'; en = 'The field does not exist (the templates file may have changed).' }
    $catalogue['reply.draftExtended'] = @{ ar = '⏳ مُدِّدت مهلة المسودة.'; en = '⏳ The draft timeout was extended.' }
    $catalogue['reply.noDraft'] = @{ ar = 'لا توجد مسودة قائمة.'; en = 'There is no draft open.' }
    $catalogue['reply.snapshotExpired'] = @{ ar = 'انتهت صلاحية النسخة — اطلب تشخيصًا جديدًا من القائمة.'; en = 'That snapshot has expired — ask for a new diagnostic from the menu.' }
    $catalogue['reply.timeoutExtended'] = @{ ar = '⏳ مُدِّدت المهلة. أكمل كتابتك.'; en = '⏳ The timeout was extended. Carry on typing.' }
    $catalogue['reply.noOperation'] = @{ ar = 'لا توجد عملية قائمة.'; en = 'There is no operation in progress.' }
    $catalogue['reply.templateNoLongerExists'] = @{ ar = 'القالب لم يعد موجودًا.'; en = 'The template no longer exists.' }
    $catalogue['reply.backupGone'] = @{ ar = 'النسخة المحددة لم تعد موجودة.'; en = 'The chosen backup no longer exists.' }
    $catalogue['reply.restoreExpired'] = @{ ar = 'انتهى أو تغيّر طلب الاستعادة. اختر النسخة من جديد.'; en = 'The restore request expired or changed. Choose the backup again.' }
    $catalogue['reply.templatesRestored'] = @{ ar = '✅ استُعيدت نسخة القوالب، وحُفظت نسخة من السابقة قبلها.'; en = '✅ The template backup was restored, and a copy of the previous one was kept first.' }
    $catalogue['reply.settingsRestored'] = @{ ar = '✅ تمت استعادة نسخة الإعدادات. أعد تشغيل البوت لتطبيقها بالكامل.'; en = '✅ The settings backup was restored. Restart the bot to apply it fully.' }
    $catalogue['reply.restoreNote'] = @{ ar = 'سيتم حفظ الإعدادات الحالية أولاً، ويجب إعادة تشغيل البوت بعد الاستعادة.'; en = 'The current settings are saved first, and the bot must be restarted after the restore.' }
    $catalogue['reply.unknownOption'] = @{ ar = 'خيار غير معروف.'; en = 'Unknown option.' }
}
