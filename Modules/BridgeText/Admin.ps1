#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the administrator's own screens: shift readiness and the
    handover sheet, the health centre, the runtime-file health table, and the
    disabled-protection list with the sentence each one costs.
#>

function Add-BridgeTextAdmin {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- Readiness, handover, health -------------------------------------
    $catalogue['adm.activeScenes'] = @{ ar = '📺 المشاهد النشطة'; en = '📺 Active scenes' }
    $catalogue['adm.unknown'] = @{ ar = 'غير معروف'; en = 'Unknown' }
    $catalogue['adm.nothingOnAir'] = @{ ar = '⚫️ لا شيء على الهواء'; en = '⚫️ Nothing on air' }
    $catalogue['adm.col.layer'] = @{ ar = 'الطبقة'; en = 'Layer' }
    $catalogue['adm.col.template'] = @{ ar = 'القالب'; en = 'Template' }
    $catalogue['adm.col.since'] = @{ ar = 'منذ'; en = 'Since' }
    $catalogue['adm.col.operator'] = @{ ar = 'المشغّل'; en = 'Operator' }
    $catalogue['adm.now'] = @{ ar = 'الآن'; en = 'Now' }
    $catalogue['adm.materialNotScheduled'] = @{ ar = 'مادة غير مدرجة في الجدول'; en = 'material not in the schedule' }
    $catalogue['adm.refresh'] = @{ ar = '🔄 تحديث'; en = '🔄 Refresh' }
    $catalogue['adm.menu'] = @{ ar = '⬅️ القائمة'; en = '⬅️ Menu' }
    $catalogue['adm.materialUnreadable'] = @{ ar = '⛔ تعذّر قراءة جدول المواد من القناة.'; en = '⛔ The material schedule could not be read from the channel.' }
    $catalogue['adm.noMaterial'] = @{ ar = 'لا توجد مواد مجدولة على القناة.'; en = 'No material is scheduled on the channel.' }
    $catalogue['adm.materialTitle'] = @{ ar = '<b>🎞 جدول المواد</b>'; en = '<b>🎞 Material schedule</b>' }
    $catalogue['adm.maintenanceOn'] = @{ ar = 'وضع الصيانة مفعّل — لا عرض ولا إخفاء حتى يُطفأ.'; en = 'Maintenance mode is on — nothing is shown or hidden until it is off.' }
    $catalogue['adm.schedulePaused'] = @{ ar = 'الجدولة موقوفة — المواعيد المؤجلة تبقى معلّقة ولا تُنفَّذ.'; en = 'Scheduling is paused — deferred times stay pending and do not run.' }
    $catalogue['adm.noRollback'] = @{ ar = 'لا تراجع بعد عرض خاطئ — الإصلاح الوحيد إخفاء ثم إعادة عرض.'; en = 'No undo after a wrong show — the only fix is to hide and show again.' }
    $catalogue['adm.hideNoConfirm'] = @{ ar = 'الإخفاء ينفَّذ بلا تأكيد — ضغطة واحدة تُنزل ما على الهواء.'; en = 'Hiding runs without confirmation — one press takes what is on air off it.' }
    $catalogue['adm.chatLevelAuth'] = @{ ar = 'الصلاحية بالمحادثة لا بالشخص — كل عضو في مجموعة مصرّح لها يتحكّم بالهواء.'; en = 'Permission is by chat, not by person — every member of an authorised group controls the air.' }
    $catalogue['adm.templateEditOpen'] = @{ ar = 'تعديل بنية القوالب مفتوح من تيليجرام.'; en = 'Editing template structure is open from Telegram.' }
    $catalogue['adm.rejectedCanRetry'] = @{ ar = 'المرفوض يستطيع إعادة طلب الوصول بلا حدّ.'; en = 'A rejected requester can ask again without limit.' }
    $catalogue['adm.staysInGroups'] = @{ ar = 'البوت يبقى في أي مجموعة يُضاف إليها.'; en = 'The bot stays in any group it is added to.' }
    $catalogue['adm.tokenPlaintext'] = @{ ar = 'التوكن مكتوب نصًّا في config.json.'; en = 'The token is in plain text in config.json.' }
    $catalogue['adm.noMissingGraphicAlert'] = @{ ar = 'لا تنبيه حين يغيب اللوغو أو الشريط عن الهواء.'; en = 'No alert when the logo or the ticker goes missing from air.' }
    $catalogue['adm.noSpellWarnings'] = @{ ar = 'لا تنبيهات إملائية في شاشة المراجعة قبل النشر.'; en = 'No spelling warnings on the review screen before publishing.' }
    $catalogue['adm.noTestLayer'] = @{ ar = '• لا طبقة تجربة — لا مكان لتجربة قالب خارج البرنامج. <code>TemplateTestLayer</code>'; en = '• No test layer — nowhere to try a template off air. <code>TemplateTestLayer</code>' }
    $catalogue['adm.readinessTitle'] = @{ ar = '<b>✅ جاهزية المناوبة</b>'; en = '<b>✅ Shift readiness</b>' }
    $catalogue['adm.nothingOnAirGreen'] = @{ ar = '🟢 لا شيء على الهواء.'; en = '🟢 Nothing is on air.' }
    $catalogue['adm.noPending'] = @{ ar = '✅ لا عمليات معلقة.'; en = '✅ No pending operations.' }
    $catalogue['adm.draftUnowned'] = @{ ar = '🤝 مسودة شريط مسلّمة بلا مالك — من يتابعها؟'; en = '🤝 A handed-over ticker draft with no owner — who continues it?' }
    $catalogue['adm.noDraft'] = @{ ar = '✅ لا مسودة شريط.'; en = '✅ No ticker draft.' }
    $catalogue['adm.noQuarantined'] = @{ ar = '✅ لا محادثات محجورة.'; en = '✅ No quarantined chats.' }
    $catalogue['adm.noStandingFaults'] = @{ ar = '✅ لا أعطال مثبّتة.'; en = '✅ No standing faults.' }
    $catalogue['adm.quietOn'] = @{ ar = '🔇 الهدوء مفعّل — غير العاجل يُجمَّع.'; en = '🔇 Quiet is on — the non-urgent is held.' }
    $catalogue['adm.alertsDirect'] = @{ ar = '🔊 التنبيهات تصل مباشرة.'; en = '🔊 Alerts arrive straight away.' }
    $catalogue['adm.readyVerdict'] = @{ ar = '<b>جاهز ✅ — ابدأ بالفحص الحي للتأكد من المسار.</b>'; en = '<b>Ready ✅ — start with the live check to confirm the path.</b>' }
    $catalogue['adm.notCleanVerdict'] = @{ ar = '<b>ليست نظيفة — صفِّ ما فوق ثم افحص المسار الحي.</b>'; en = '<b>Not clean — clear the above, then run the live check.</b>' }
    $catalogue['adm.changedInSettings'] = @{ ar = 'تُبدَّل من ⚙️ الإعدادات.'; en = 'Changed from ⚙️ Settings.' }
    $catalogue['adm.noProtectionOff'] = @{ ar = '🛡 لا حماية معطّلة.'; en = '🛡 No protection is disabled.' }
    $catalogue['adm.livePathCheck'] = @{ ar = '🧪 فحص المسار الحي'; en = '🧪 Live path check' }
    $catalogue['adm.handover'] = @{ ar = '📋 التسليم'; en = '📋 Handover' }
    $catalogue['adm.backToTools'] = @{ ar = '⬅️ أدوات الإدارة'; en = '⬅️ Admin tools' }
    $catalogue['adm.handoverTitle'] = @{ ar = '<b>🤝 تسليم المناوبة</b>'; en = '<b>🤝 Shift handover</b>' }
    $catalogue['adm.nothingFromBridge'] = @{ ar = '🟢 لا شيء من الجسر على الهواء.'; en = '🟢 Nothing from the bridge is on air.' }
    $catalogue['adm.onAirNow'] = @{ ar = '<b>🔴 على الهواء الآن</b>'; en = '<b>🔴 On air now</b>' }
    $catalogue['adm.noUpcoming'] = @{ ar = '📅 لا مواعيد قادمة.'; en = '📅 No upcoming times.' }
    $catalogue['adm.upcomingTitle'] = @{ ar = '<b>📅 المواعيد القادمة</b>'; en = '<b>📅 Upcoming times</b>' }
    $catalogue['adm.openDraftsTitle'] = @{ ar = '<b>✍️ مسودات مفتوحة</b>'; en = '<b>✍️ Open drafts</b>' }
    $catalogue['adm.noOpenDrafts'] = @{ ar = '✍️ لا مسودات مفتوحة.'; en = '✍️ No open drafts.' }
    $catalogue['adm.autoImportant'] = @{ ar = '<b>📌 الأهم تلقائيًا</b>'; en = '<b>📌 What matters most</b>' }
    $catalogue['adm.handoverNote'] = @{ ar = '<i>راجع القائمة مع من يستلم، ثم اضغط «سلّمت» ليُسجَّل.</i>'; en = '<i>Go through the list with whoever takes over, then press "handed over" to record it.</i>' }
    $catalogue['adm.handedOver'] = @{ ar = '✅ سلّمت المناوبة'; en = '✅ I handed the shift over' }
    $catalogue['adm.someLayersUnchecked'] = @{ ar = '🟠 تعذّر فحص بعض الطبقات'; en = '🟠 Some layers could not be checked' }
    $catalogue['adm.layersOnAir'] = @{ ar = '🟠 طبقات على الهواء'; en = '🟠 Layers on air' }
    $catalogue['adm.allWell'] = @{ ar = '🟢 كل شيء سليم'; en = '🟢 All well' }
    $catalogue['adm.channelAndMaterial'] = @{ ar = '<b>🎛 القناة والمادة</b>'; en = '<b>🎛 The channel and the material</b>' }
    $catalogue['adm.syncTitle'] = @{ ar = '<b>🔄 التزامن</b>'; en = '<b>🔄 Sync</b>' }
    $catalogue['adm.syncedWithCinegy'] = @{ ar = '✅ الحالة متزامنة مع Cinegy.'; en = '✅ The state is in sync with Cinegy.' }
    $catalogue['adm.status'] = @{ ar = 'ℹ️ الحالة'; en = 'ℹ️ Status' }
    $catalogue['adm.noHideAllLayers'] = @{ ar = '⚠️ لا توجد طبقات محددة لإخفاء الكل. يضبطها المشرف من الإعدادات.'; en = '⚠️ No layers are selected for hide-all. An administrator sets them in Settings.' }
    $catalogue['adm.invalidReply'] = @{ ar = 'رد غير صالح'; en = 'an invalid reply' }
    $catalogue['adm.unreachable'] = @{ ar = 'تعذّر الوصول'; en = 'unreachable' }
    $catalogue['adm.none'] = @{ ar = 'لا يوجد'; en = 'none' }
    $catalogue['adm.serviceHealth'] = @{ ar = '💚 صحة الخدمات'; en = '💚 Service health' }
    $catalogue['adm.templateGone'] = @{ ar = 'القالب لم يعد موجودًا.'; en = 'The template no longer exists.' }
    $catalogue['adm.disabledLongRun'] = @{ ar = 'معطّل للقالب Long run (يعمل 24/7).'; en = 'Disabled for a long-run template (it runs 24/7).' }
    $catalogue['adm.disabledDot'] = @{ ar = 'معطّل.'; en = 'Disabled.' }
    $catalogue['adm.fullTemplateControl'] = @{ ar = '✅ التحكم الكامل بالقوالب مفعّل. اختر عملية التعديل من الأزرار.'; en = '✅ Full template control is on. Choose the edit from the buttons.' }
    $catalogue['adm.templateEditAdminOnly'] = @{ ar = '🔒 تعديل تعريف القالب مخصص للمشرف. يمكنك قراءة التعريف وإدارة تنبيه الظهور.'; en = '🔒 Editing a template definition is for administrators. You can read it and manage its show notice.' }
    $catalogue['adm.lostNoticeRight'] = @{ ar = 'فقدت صلاحية إدارة تنبيه القالب.'; en = 'You no longer have the right to manage the template notice.' }
    $catalogue['hl.cinegyPublic'] = @{ ar = '🔓 عنوان Cinegy خارج النطاقات الخاصة. واجهة Cinegy بلا مصادقة: من يصل إلى المنفذ يتحكم بالهواء. أبقِ المنفذ داخل شبكة البثّ.'; en = '🔓 The Cinegy address is outside the private ranges. The Cinegy interface has no authentication: whoever reaches the port controls the air. Keep the port inside the broadcast network.' }
    $catalogue['hl.adminOwnerOnly'] = @{ ar = 'هذا الفحص متاح للمشرف والمالك فقط.'; en = 'That check is for administrators and the owner only.' }
    $catalogue['hl.someLayersUncheckable'] = @{ ar = '🔴 لا يمكن فحص بعض الطبقات'; en = '🔴 Some layers cannot be checked' }
    $catalogue['hl.cinegyUnavailable'] = @{ ar = '🟠 Cinegy غير متاح'; en = '🟠 Cinegy is unavailable' }
    $catalogue['hl.cinegyConnection'] = @{ ar = '<b>🎛 اتصال Cinegy</b>'; en = '<b>🎛 Cinegy connection</b>' }
    $catalogue['hl.verified'] = @{ ar = 'تم التحقق'; en = 'verified' }
    $catalogue['hl.awaitingCinegy'] = @{ ar = 'بانتظار تحقق Cinegy'; en = 'awaiting Cinegy verification' }
    $catalogue['hl.compatibilityMode'] = @{ ar = 'وضع متوافق'; en = 'compatibility mode' }
    $catalogue['hl.serviceHealthTitle'] = @{ ar = '<b>🩺 صحة الخدمات</b>'; en = '<b>🩺 Service health</b>' }
    $catalogue['hl.runAndSchedule'] = @{ ar = '<b>⚙️ التشغيل والجدولة</b>'; en = '<b>⚙️ Running and scheduling</b>' }
    $catalogue['hl.access'] = @{ ar = '<b>👥 الوصول</b>'; en = '<b>👥 Access</b>' }
    $catalogue['hl.cinegySynced'] = @{ ar = '✅ حالة Cinegy متزامنة.'; en = '✅ The Cinegy state is in sync.' }
    $catalogue['hl.fullStatus'] = @{ ar = '📊 الحالة الكاملة'; en = '📊 Full status' }
    $catalogue['hl.runtimeFilesHealthy'] = @{ ar = '🟢 كل ملفات التشغيل سليمة.'; en = '🟢 Every runtime file is sound.' }
    $catalogue['hl.runtimeFiles'] = @{ ar = '🗂 صحة ملفات التشغيل'; en = '🗂 Runtime file health' }
    $catalogue['hl.col.file'] = @{ ar = 'الملف'; en = 'File' }
    $catalogue['hl.col.state'] = @{ ar = 'الحالة'; en = 'State' }
    $catalogue['hl.col.detail'] = @{ ar = 'التفصيل'; en = 'Detail' }
    $catalogue['hl.notWrittenNothing'] = @{ ar = 'لم يُكتب بعد — لا شيء لاستعادته'; en = 'not written yet — nothing to restore' }
    $catalogue['hl.corruptWithBackup'] = @{ ar = 'تالف، لكن توجد نسخة احتياطية يستعيدها الجسر عند الإقلاع'; en = 'corrupt, but a backup exists that the bridge restores at startup' }
    $catalogue['hl.corruptNoBackup'] = @{ ar = 'تالف ولا توجد نسخة احتياطية'; en = 'corrupt, with no backup' }
    $catalogue['hl.corruptNote'] = @{ ar = 'الملف التالف بنسخة احتياطية يُستعاد تلقائيًا عند إعادة التشغيل؛ والتالف بلا نسخة يبدأ فارغًا.'; en = 'A corrupt file with a backup is restored automatically on restart; one without starts empty.' }
    $catalogue['hl.runtimeFilesTitle'] = @{ ar = '<b>🗂 صحة ملفات التشغيل</b>'; en = '<b>🗂 Runtime file health</b>' }
    $catalogue['hl.allSoundHtml'] = @{ ar = '<b>🟢 كل ملفات التشغيل سليمة.</b>'; en = '<b>🟢 Every runtime file is sound.</b>' }
    $catalogue['hl.notWrittenYet'] = @{ ar = 'لم يُكتب بعد'; en = 'not written yet' }
    $catalogue['hl.corruptNote1'] = @{ ar = '<i>↳ الملف التالف بنسخة احتياطية يُستعاد تلقائيًا عند إعادة التشغيل.</i>'; en = '<i>↳ A corrupt file with a backup is restored automatically on restart.</i>' }
    $catalogue['hl.corruptNote2'] = @{ ar = '<i>↳ التالف بلا نسخة يبدأ فارغًا؛ خذ نسخة من المجلد قبل إعادة التشغيل إن كان محتواه مهمًا.</i>'; en = '<i>↳ One without a backup starts empty; copy the folder before restarting if its contents matter.</i>' }
    $catalogue['hl.connected'] = @{ ar = 'متصل'; en = 'connected' }
    $catalogue['hl.disconnected'] = @{ ar = 'غير متصل'; en = 'disconnected' }
    $catalogue['hl.undecided'] = @{ ar = 'لم تُحسم الحالة'; en = 'the state is undecided' }
    $catalogue['hl.healthy'] = @{ ar = 'سليم'; en = 'healthy' }
    $catalogue['hl.unhealthy'] = @{ ar = 'غير سليم'; en = 'unhealthy' }
    $catalogue['hl.stateUnknown'] = @{ ar = 'الحالة غير معروفة'; en = 'the state is unknown' }
    $catalogue['hl.outputMonitoring'] = @{ ar = 'مراقبة المخرج'; en = 'Output monitoring' }
    $catalogue['hl.disabledByAdmin'] = @{ ar = 'معطلة باختيار المشرف'; en = 'disabled by the administrator' }
    $catalogue['hl.sound'] = @{ ar = 'سليمة'; en = 'sound' }
    $catalogue['hl.relayedStream'] = @{ ar = 'البث المرحّل'; en = 'The relayed stream' }
    $catalogue['hl.notRequired'] = @{ ar = 'غير مطلوب'; en = 'not required' }
    $catalogue['hl.running'] = @{ ar = 'يعمل'; en = 'running' }
    $catalogue['hl.requiredButStopped'] = @{ ar = 'مطلوب لكنه متوقف'; en = 'required but stopped' }
    $catalogue['hl.spaceUnknown'] = @{ ar = 'المساحة غير معروفة'; en = 'the free space is unknown' }
    $catalogue['hl.storage'] = @{ ar = 'التخزين'; en = 'Storage' }
    $catalogue['hl.scheduling'] = @{ ar = 'الجدولة'; en = 'Scheduling' }
    $catalogue['hl.quarantinedChats'] = @{ ar = 'محادثات محجورة'; en = 'Quarantined chats' }
    $catalogue['hl.nothing'] = @{ ar = 'لا شيء'; en = 'none' }
    $catalogue['hl.recentErrors'] = @{ ar = 'آخر الأخطاء'; en = 'Recent errors' }
    $catalogue['hl.healthCentre'] = @{ ar = '🩺 مركز صحة النظام'; en = '🩺 System health centre' }
    $catalogue['hl.system'] = @{ ar = 'النظام'; en = 'The system' }
    $catalogue['hl.faultNeedsAction'] = @{ ar = '🔴 عطلٌ يحتاج تدخلًا'; en = '🔴 A fault needing action' }
    $catalogue['hl.needsReview'] = @{ ar = '🟠 يحتاج مراجعة'; en = '🟠 Needs review' }
    $catalogue['hl.healthCentreTitle'] = @{ ar = '<b>🩺 مركز صحة النظام</b>'; en = '<b>🩺 System health centre</b>' }
    $catalogue['hl.engineHealthOff'] = @{ ar = 'شاشة صحة المحرك معطلة افتراضيًا. يفعّلها المشرف من الإعدادات (صحة المحرك) إن أرادها.'; en = 'The engine health screen is off by default. An administrator turns it on from Settings if they want it.' }
    $catalogue['hl.engineHealthTitle'] = @{ ar = '<b>🖥 صحة المحرك</b>'; en = '<b>🖥 Engine health</b>' }
    $catalogue['hl.engineCountersUnreadable'] = @{ ar = '⚠️ تعذّر قراءة عدادات المحرك من القناة.'; en = '⚠️ The engine counters could not be read from the channel.' }
    $catalogue['hl.warning'] = @{ ar = '🔴 تحذير'; en = '🔴 Warning' }
    $catalogue['hl.noInputSignal'] = @{ ar = '🟠 بلا إشارة دخل'; en = '🟠 No input signal' }
    $catalogue['hl.healthyGreen'] = @{ ar = '🟢 سليم'; en = '🟢 Healthy' }
    $catalogue['hl.testLayerDisabled'] = @{ ar = 'طبقة تجربة القوالب معطلة. اضبط TemplateTestLayer أولاً.'; en = 'The template test layer is disabled. Set TemplateTestLayer first.' }
    $catalogue['hl.bridgeItself'] = @{ ar = 'الجسر نفسه'; en = 'the bridge itself' }
    $catalogue['hl.yesRestart'] = @{ ar = '✅ نعم، أعد التشغيل'; en = '✅ Yes, restart it' }
    $catalogue['hl.cancel'] = @{ ar = '❌ إلغاء'; en = '❌ Cancel' }
    $catalogue['hl.restarting'] = @{ ar = '♻️ يُعاد التشغيل الآن… أرسل /بدء بعد قليل للتأكد من عودته.'; en = '♻️ Restarting now… send the start command shortly to confirm it came back.' }
}
