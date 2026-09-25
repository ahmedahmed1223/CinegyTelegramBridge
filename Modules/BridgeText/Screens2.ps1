#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the last of the screens: the user cards and what the
    door says to someone not yet authorised, the bulletin design and its
    playback, the urgent board, the scheduling parser with its accepted
    forms, the weekly sheet, and the relay that carries a text to be copied.
#>

function Add-BridgeTextScreens2 {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['usr.fileInfoRefused'] = @{ ar = 'Telegram رفض طلب معلومات الملف.'; en = 'Telegram refused the file information request.' }
    $catalogue['usr.badFilePath'] = @{ ar = 'Telegram أعاد مسار ملف غير صالح.'; en = 'Telegram returned an invalid file path.' }
    $catalogue['usr.reEnable'] = @{ ar = '✅ إعادة تفعيل'; en = '✅ Enable again' }
    $catalogue['usr.notQuarantined'] = @{ ar = 'هذه المحادثة ليست محجورة الآن.'; en = 'This chat is not quarantined right now.' }
    $catalogue['usr.deliveryTest'] = @{ ar = '🔔 اختبار استلام من البوت — تجاهل هذه الرسالة.'; en = '🔔 A delivery test from the bot — ignore this message.' }
    $catalogue['usr.backToUsers'] = @{ ar = '⬅️ المستخدمون'; en = '⬅️ The users' }
    $catalogue['usr.noDeadChats'] = @{ ar = '💀 لا محادثات ميتة — كل القائمة تستقبل.'; en = '💀 No dead chats — everyone on the list receives.' }
    $catalogue['usr.test'] = @{ ar = '🔍 اختبار'; en = '🔍 Test' }
    $catalogue['usr.revoke'] = @{ ar = '⛔ سحب الصلاحية'; en = '⛔ Revoke the right' }
    $catalogue['usr.notAuthorisedYet'] = @{ ar = 'غير مصرح لك باستخدام هذا البوت بعد. تم إرسال طلب وصول إلى المشرف - ستصلك رسالة فور الموافقة.'; en = 'You are not authorised to use this bot yet. An access request went to the administrator — you will hear as soon as it is approved.' }
    $catalogue['usr.notAuthorised'] = @{ ar = 'غير مصرح لك باستخدام هذا البوت. تواصل مع المشرف مباشرة.'; en = 'You are not authorised to use this bot. Speak to the administrator directly.' }
    $catalogue['usr.wasDisabled'] = @{ ar = ' · تم تعطيله'; en = ' · disabled' }
    $catalogue['usr.reEnableWhenNeeded'] = @{ ar = 'أعد التفعيل من 👥 المستخدمين عند الحاجة.'; en = 'Enable it again from 👥 Users when you need to.' }
    $catalogue['usr.autoDisableOff'] = @{ ar = 'التعطيل التلقائي مغلق؛ فعّل AutoDisableDormantUsers إن أردته.'; en = 'The automatic disabling is off; turn AutoDisableDormantUsers on if you want it.' }
    $catalogue['usr.cannotRevokeOwner'] = @{ ar = 'لا يمكن سحب صلاحية المالك.'; en = 'The owner''s right cannot be revoked.' }
    $catalogue['usr.cannotRevokeLastAdmin'] = @{ ar = 'لا يمكن سحب صلاحية آخر مشرف.'; en = 'The last administrator''s right cannot be revoked.' }
    $catalogue['usr.yesRevoke'] = @{ ar = '✅ نعم، اسحب الصلاحية'; en = '✅ Yes, revoke the right' }
    $catalogue['usr.activityUnknown'] = @{ ar = '⚪ النشاط غير معروف'; en = '⚪ The activity is unknown' }
    $catalogue['usr.noLiveStatus'] = @{ ar = '<i>Telegram لا يوفّر حالة اتصال لحظية؛ الحالة مبنية على آخر تفاعل مع البوت.</i>'; en = '<i>Telegram gives no live connection status; this is built from the last exchange with the bot.</i>' }
    $catalogue['usr.userGoneHtml'] = @{ ar = '<i>المستخدم لم يعد ضمن قائمة المصرح لهم.</i>'; en = '<i>This user is no longer on the authorised list.</i>' }
    $catalogue['usr.badUserId'] = @{ ar = 'معرّف مستخدم غير صالح.'; en = 'That user id is not valid.' }
    $catalogue['usr.alreadyAdmin'] = @{ ar = 'هذا المستخدم مشرف بالفعل.'; en = 'This user is an administrator already.' }
    $catalogue['usr.cannotPromoteUnauthorised'] = @{ ar = 'لا يمكن ترقية مستخدم غير مصرّح له.'; en = 'A user who is not authorised cannot be promoted.' }
    $catalogue['usr.notAnAdmin'] = @{ ar = 'هذا المستخدم ليس مشرفًا.'; en = 'This user is not an administrator.' }
    $catalogue['usr.cannotDemoteOwner'] = @{ ar = 'لا يمكن خفض صلاحية المالك.'; en = 'The owner cannot be demoted.' }
    $catalogue['usr.cannotDemoteLastAdmin'] = @{ ar = 'لا يمكن خفض آخر مشرف.'; en = 'The last administrator cannot be demoted.' }
    $catalogue['usr.confirm'] = @{ ar = '✅ تأكيد'; en = '✅ Confirm' }
    $catalogue['mjd.sceneUnreadable'] = @{ ar = 'تعذّرت قراءة ملف المشهد.'; en = 'The scene file could not be read.' }
    $catalogue['mjd.sceneMissing'] = @{ ar = 'ملف المشهد غير موجود في مساره.'; en = 'The scene file is not there at its path.' }
    $catalogue['mjd.noFields'] = @{ ar = 'بلا حقول'; en = 'no fields' }
    $catalogue['mjd.manyHeadlines'] = @{ ar = 'عدة أخبار'; en = 'several headlines' }
    $catalogue['mjd.oneHeadline'] = @{ ar = 'خبر واحد'; en = 'one headline' }
    $catalogue['mjd.screen'] = @{ ar = "🎬 <b>تصميم الموجز</b>
`n
`nاختر التصميم الذي تُبثّ عليه هذه النشرة.
`n<i>الحقول تُقرأ من المشهد نفسه، فما يطلبه التصميم هو ما ستُسأل عنه.</i>"; en = "🎬 <b>The bulletin design</b>
`n
`nChoose the design this bulletin goes out on.
`n<i>The fields are read from the scene itself, so what the design asks for is what you will be asked.</i>" }
    $catalogue['mjd.notWhileOnAir'] = @{ ar = '⛔ لا يُبدَّل تصميم موجز وهو على الهواء. أوقفه أولًا.'; en = '⛔ A bulletin design is not swapped while it is on air. Stop it first.' }
    $catalogue['mjd.designGone'] = @{ ar = '⛔ هذا التصميم غير صالح أو لم يعد موجودًا.'; en = '⛔ That design is not valid, or is no longer there.' }
    $catalogue['mjd.syncOff'] = @{ ar = '<b>🎬 المزامنة متوقّفة</b>: يتغيّر الصف في منتصف الثبات، بلا حركة تُخفيه.'; en = '<b>🎬 The sync is off</b>: the row changes mid-hold, with no motion to cover it.' }
    $catalogue['mjd.syncWantedNoLoop'] = @{ ar = '<b>⚠️ المزامنة مطلوبة</b> لكن القالب لا يعطي لوبًا صالحًا، فيعمل الموجز بالمدّة المكتوبة.'; en = '<b>⚠️ The sync is wanted</b> but the template gives no valid loop, so the bulletin runs on the written duration.' }
    $catalogue['mjd.syncOn'] = @{ ar = "`n🎬 المزامنة مفعّلة: كل خبر يُكتب داخل فيضة اللوب فلا يُرى وهو يتبدّل"; en = "`n🎬 The sync is on: every headline is written inside the loop dissolve, so it is never seen changing" }
    $catalogue['mjp.alreadyRunning'] = @{ ar = 'الموجز يعمل بالفعل.'; en = 'The bulletin is running already.' }
    $catalogue['mjp.notThere'] = @{ ar = 'الموجز غير موجود.'; en = 'That bulletin is not there.' }
    $catalogue['mjp.boardEmpty'] = @{ ar = 'الجدول فارغ.'; en = 'The board is empty.' }
    $catalogue['mjp.showFailed'] = @{ ar = 'تعذّر العرض'; en = 'the show failed' }
    $catalogue['mjp.exitUnconfirmed'] = @{ ar = '⚠️ تعذّر تأكيد خروج الموجز. جُمّد التشغيل؛ أعد محاولة الإيقاف وتحقّق من الطبقة.'; en = '⚠️ The bulletin exit could not be confirmed. The run is frozen; try stopping it again and check the layer.' }
    $catalogue['mjp.endedUrgentNow'] = @{ ar = '▶️ انتهى الموجز — يُرسل العاجل الآن.'; en = '▶️ The bulletin ended — the urgent goes out now.' }
    $catalogue['mjp.nowBulletinLeaves'] = @{ ar = '🚨 الآن — يخرج الموجز'; en = '🚨 Now — the bulletin leaves' }
    $catalogue['mjp.afterBulletinEnds'] = @{ ar = '⏳ بعد انتهاء الموجز'; en = '⏳ After the bulletin ends' }
    $catalogue['mjp.afterUrgentLeaves'] = @{ ar = '⏳ بعد خروج العاجل'; en = '⏳ After the urgent leaves' }
    $catalogue['mjp.startDespiteUrgent'] = @{ ar = '▶️ ابدأ الآن رغم العاجل'; en = '▶️ Start now, urgent or not' }
    $catalogue['mjp.slotNotHeld'] = @{ ar = '❌ تعذّر حجز الموعد. لم يتغيّر شيء.'; en = '❌ Could not hold the slot. Nothing changed.' }
    $catalogue['mjp.noUrgentWaiting'] = @{ ar = 'لا يوجد عاجل بانتظار الإرسال.'; en = 'No urgent is waiting to go out.' }
    $catalogue['mjp.urgentWaits'] = @{ ar = '⏳ ينتظر العاجل انتهاء الموجز، ثم يخرج وحده.'; en = '⏳ The urgent waits for the bulletin to end, then goes out by itself.' }
    $catalogue['mjp.noTemplate'] = @{ ar = 'لا يوجد قالب للموجز.'; en = 'The bulletin has no template.' }
    $catalogue['mjp.notOnAir'] = @{ ar = 'الموجز ليس على الهواء.'; en = 'The bulletin is not on air.' }
    $catalogue['mjp.left'] = @{ ar = '⏹ خرج الموجز.'; en = '⏹ The bulletin left.' }
    $catalogue['mjz.current'] = @{ ar = 'الموجز الحالي'; en = 'the current bulletin' }
    $catalogue['mjz.saveFailed'] = @{ ar = '❌ تعذّر الحفظ. لم يتغيّر شيء؛ تحقّق من مساحة القرص والسجل.'; en = '❌ Could not save. Nothing changed; check the disc space and the log.' }
    $catalogue['mjz.ownPicture'] = @{ ar = '🖼 صورة خاصة'; en = '🖼 Its own picture' }
    $catalogue['mjz.templatePicture'] = @{ ar = '▫️ صورة القالب'; en = '▫️ The template picture' }
    $catalogue['mjz.followsPrevious'] = @{ ar = '↑ يتبع الصف السابق'; en = '↑ Follows the row above' }
    $catalogue['mjz.paceFromLoop'] = @{ ar = 'نعم · الإيقاع من اللوب'; en = 'Yes · the pace comes from the loop' }
    $catalogue['mjz.paceFromDuration'] = @{ ar = 'لا · الإيقاع من المدة'; en = 'No · the pace comes from the duration' }
    $catalogue['mjz.sendRowPicture'] = @{ ar = "🖼 أرسل صورة الصف (كصورة أو كملف)، أو أرسل مسارًا مثل ‎.\Mojaz\Pic01.png‎`nأو اختر أحد الأزرار."; en = "🖼 Send the picture for this row (as a photo or as a file), or send a path such as ‎.\Mojaz\Pic01.png‎`nor pick one of the buttons." }
    $catalogue['urg.templateCeiling'] = @{ ar = 'الحد الأقصى للقالب'; en = 'the template ceiling' }
    $catalogue['urg.sensitiveAutoHide'] = @{ ar = 'الإخفاء التلقائي للقالب الحسّاس'; en = 'the automatic hide on a sensitive template' }
    $catalogue['urg.refresh'] = @{ ar = '🔄 تحديث'; en = '🔄 Refresh' }
    $catalogue['urg.pairPattern'] = @{ ar = '١ ١ · ٢ ٢'; en = '1 1 · 2 2' }
    $catalogue['urg.roundPattern'] = @{ ar = '١ ٢ ٣ · ١ ٢ ٣'; en = '1 2 3 · 1 2 3' }
    $catalogue['urg.boardStopsFirst'] = @{ ar = "`nسيُوقف الجدول التلقائي أولًا؛ إن فشل الإيقاف فلن يُعرض الخبر."; en = "`nThe automatic board is stopped first; if stopping it fails, the headline is not shown." }
    $catalogue['urg.readFullText'] = @{ ar = "`n… اقرأ النص الكامل من زر العودة قبل التأكيد."; en = "`n… read the full text from the back button before you confirm." }
    $catalogue['urg.fromTheBoard'] = @{ ar = ' (من الجدول)'; en = ' (from the board)' }
    $catalogue['urgp.boardOffOrNoTemplate'] = @{ ar = '⚠️ جدول العواجل غير مفعّل أو لا قالب له.'; en = '⚠️ The urgent board is off, or it has no template.' }
    $catalogue['urgp.alreadyRunning'] = @{ ar = 'جدول العواجل يعمل بالفعل.'; en = 'The urgent board is running already.' }
    $catalogue['urgp.bulletinOnAir'] = @{ ar = '📑 الموجز على الهواء. ابدأ الجدول بعد إيقافه، أو أوقفه من شاشته.'; en = '📑 The bulletin is on air. Start the board once it has stopped, or stop it from its own screen.' }
    $catalogue['urgp.showFailed'] = @{ ar = 'تعذّر العرض'; en = 'the show failed' }
    $catalogue['urgp.exitUnconfirmed'] = @{ ar = '⚠️ تعذّر تأكيد خروج العاجل. جُمّد الجدول؛ أعد محاولة الإيقاف وتحقّق من الطبقة.'; en = '⚠️ The urgent exit could not be confirmed. The board is frozen; try stopping it again and check the layer.' }
    $catalogue['urgp.stoppedByYou'] = @{ ar = '⏹ أوقفتَ التتابع، وخرج العاجل عن الهواء.'; en = '⏹ You stopped the sequence; the urgent is off air.' }
    $catalogue['urgp.pausedByYou'] = @{ ar = '⏸ أوقفتَ التتابع مؤقتًا؛ الخبر الحالي يبقى على الهواء.'; en = '⏸ You paused the sequence; the current story stays on air.' }
    $catalogue['urgp.resumedByYou'] = @{ ar = '▶️ استأنفتَ التتابع.'; en = '▶️ You resumed the sequence.' }
    $catalogue['urgp.skippedByYou'] = @{ ar = '⏭ انتقلتَ إلى الخبر التالي.'; en = '⏭ You skipped to the next story.' }
    $catalogue['urgp.stoppedBySingle'] = @{ ar = '⏹ توقّف جدول العواجل: أُرسل عاجل مفرد على المشهد نفسه.'; en = '⏹ The urgent board stopped: a single urgent went out on the same scene.' }
    $catalogue['urgp.stoppedNoReturn'] = @{ ar = '❌ توقّف جدول العواجل: تعذّر إعادة المشهد بعد الفاصل.'; en = '❌ The urgent board stopped: the scene could not be brought back after the break.' }
    $catalogue['urgp.ended'] = @{ ar = '⏹ انتهى جدول العواجل وخرج عن الهواء.'; en = '⏹ The urgent board ended and left the air.' }
    $catalogue['urgp.noTemplate'] = @{ ar = 'لا قالب للعاجل.'; en = 'The urgent has no template.' }
    $catalogue['urgp.stayedPaused'] = @{ ar = 'بقي متوقفًا مؤقتًا'; en = 'it stayed paused' }
    $catalogue['urgp.resumed'] = @{ ar = 'استأنف'; en = 'it resumed' }
    $catalogue['urgp.exitUnsure'] = @{ ar = '⚠️ خروج المشهد غير مؤكّد؛ أعد محاولة الإيقاف أولًا.'; en = '⚠️ The scene exit is not confirmed; try stopping it again first.' }
    $catalogue['urgp.cannotAdvance'] = @{ ar = '❌ تعذّر الانتقال للعاجل التالي؛ أُوقف الجدول. راجع حالة الطبقة.'; en = '❌ Could not move to the next urgent; the board was stopped. Check the layer state.' }
    $catalogue['sch.day.sun'] = @{ ar = 'أحد'; en = 'Sun' }
    $catalogue['sch.day.mon'] = @{ ar = 'إثن'; en = 'Mon' }
    $catalogue['sch.day.tue'] = @{ ar = 'ثلا'; en = 'Tue' }
    $catalogue['sch.day.wed'] = @{ ar = 'أرب'; en = 'Wed' }
    $catalogue['sch.day.thu'] = @{ ar = 'خمي'; en = 'Thu' }
    $catalogue['sch.day.fri'] = @{ ar = 'جمع'; en = 'Fri' }
    $catalogue['sch.day.sat'] = @{ ar = 'سبت'; en = 'Sat' }
    $catalogue['sch.acceptedForms'] = @{ ar = "الصيغ المقبولة:`n• 21:45 — اليوم، أو الغد إن مضى الوقت`n• غدًا 21:45 · اليوم 21:45`n• +30 — بعد ثلاثين دقيقة`n• 09-15 21:45 — يوم وشهر`n• 2026-09-15 21:45 — كاملة"; en = "The forms that are accepted:`n• 21:45 — today, or tomorrow if the time has passed`n• غدًا 21:45 · اليوم 21:45 — tomorrow, today`n• +30 — in thirty minutes`n• 09-15 21:45 — a day and a month`n• 2026-09-15 21:45 — the whole date" }
    $catalogue['sch.replacesOnAir'] = @{ ar = "⚠️ حدث مجدول يستبدل مشهدًا على الهواء`n"; en = "⚠️ A scheduled event replaces a scene that is on air`n" }
    $catalogue['sch.noEndDate'] = @{ ar = 'بدون تاريخ انتهاء'; en = 'with no end date' }
    $catalogue['wk.lastSevenDays'] = @{ ar = 'آخر 7 أيام'; en = 'the last 7 days' }
    $catalogue['wk.never'] = @{ ar = 'أبدًا'; en = 'never' }
    $catalogue['wk.noScreensNearLimit'] = @{ ar = '📐 لا شاشات قريبة من حدّ حجمها.'; en = '📐 No screen is near its size limit.' }
    $catalogue['wk.allTemplatesUsed'] = @{ ar = '🕸 كل القوالب مستخدمة خلال آخر شهر.'; en = '🕸 Every template was used within the last month.' }
    $catalogue['wk.noRepeatFailureWeek'] = @{ ar = '🔁 لا فشل متكرر بنفس السبب هذا الأسبوع.'; en = '🔁 No failure repeated for the same reason this week.' }
    $catalogue['wk.noChangedSettings'] = @{ ar = '⚙️ لا إعدادات معدّلة عن الافتراضي.'; en = '⚙️ No setting differs from its default.' }
    $catalogue['wk.noTickerThisWeek'] = @{ ar = '📰 لم يُنشر شريط أخبار هذا الأسبوع.'; en = '📰 No news ticker was published this week.' }
    $catalogue['wk.noRepeatFailure'] = @{ ar = '🔁 لا فشل متكرر بنفس السبب.'; en = '🔁 No failure repeated for the same reason.' }
    $catalogue['wk.reports'] = @{ ar = '📊 التقارير'; en = '📊 Reports' }
    $catalogue['tg.requestFailed'] = @{ ar = '⚠️ حدث خطأ أثناء تنفيذ طلبك — حاول مجددًا، وإن تكرر أبلغ المشرف.'; en = '⚠️ Something went wrong carrying out your request — try again, and tell the administrator if it keeps happening.' }
    $catalogue['tg.pasteWhereNeeded'] = @{ ar = 'الصقه حيث تحتاجه.'; en = 'Paste it wherever you need it.' }
    $catalogue['tg.copyCurrentText'] = @{ ar = '📋 نسخ النص الحالي'; en = '📋 Copy the current text' }
    $catalogue['tg.noCurrentText'] = @{ ar = '<i>لا يوجد نص حالي.</i>'; en = '<i>There is no current text.</i>' }
    $catalogue['tg.currentTextTapToCopy'] = @{ ar = 'النص الحالي — اضغط عليه لنسخه:'; en = 'The current text — tap it to copy:' }
    $catalogue['tg.typeNewText'] = @{ ar = '⌨️ <b>اكتب النص الجديد في صندوق الرسالة وأرسله</b>، أو انسخ الحالي وعدّله.'; en = '⌨️ <b>Type the new text in the message box and send it</b>, or copy the current one and edit that.' }
    $catalogue['tg.pasteThenEdit'] = @{ ar = 'الصقه في صندوق الرسالة ثم عدّله.'; en = 'Paste it into the message box, then edit it.' }
    $catalogue['tg.useHomeButton'] = @{ ar = 'استخدم زر 🏠 القائمة أسفل الشاشة في أي وقت للرجوع إلى هنا.'; en = 'Use the 🏠 Menu button at the bottom of the screen at any time to come back here.' }
    $catalogue['flow.noOperationsYet'] = @{ ar = "🧾 آخر عملياتك`n━━━━━━━━━━━━━━`nلم تُسجَّل لك أي عملية بعد."; en = "🧾 Your latest operations`n━━━━━━━━━━━━━━`nNo operation is recorded for you yet." }
    $catalogue['news.refresh'] = @{ ar = '🔄 تحديث'; en = '🔄 Refresh' }
    $catalogue['news.edit'] = @{ ar = '✏️ تعديل'; en = '✏️ Edit' }
    $catalogue['news.savedNow'] = @{ ar = 'حُفظت الآن'; en = 'saved just now' }
    $catalogue['tick.expiredDraft'] = @{ ar = "📝 أخبار المسودة المنتهية، انسخها إن أردت:`n"; en = "📝 The headlines of the expired draft, to copy if you want them:`n" }
    $catalogue['tick.itemNoLocalCopy'] = @{ ar = "📼 <b>مادة تقارب موعدها بلا نسخة محلية</b>`n"; en = "📼 <b>An item is near its slot with no local copy</b>`n" }
    $catalogue['tick.readFromSource'] = @{ ar = "`nستُقرأ من المصدر أثناء البثّ — تحقّق من المصدر والشبكة، أو أوقف هذا التنبيه من ⚙️ الإعدادات."; en = "`nIt will be read from the source while on air — check the source and the network, or turn this alert off in ⚙️ Settings." }
    $catalogue['tick.hideClearsRecord'] = @{ ar = "`nإن كانت الشاشة خالية فالإخفاء يصفّي السجل."; en = "`nIf the screen is empty, hiding clears the record." }
    $catalogue['cb.newsFileChangedOutside'] = @{ ar = "⚠️ تغيّر ملف الأخبار خارج البوت منذ أن بدأت المسودة، فلم يُنشر شيء.`nنظام آخر يكتب هذا الملف أيضًا، فاختر كيف تريد المتابعة:"; en = "⚠️ The news file changed outside the bot since you started the draft, so nothing was published.`nAnother system writes this file too, so choose how you want to go on:" }
    $catalogue['cb.manageReadyTexts'] = @{ ar = "⚡ إدارة النصوص الجاهزة`nاختر القالب:"; en = "⚡ Manage the ready-made texts`nChoose the template:" }
    $catalogue['cb.back'] = @{ ar = '❌ رجوع'; en = '❌ Back' }
    $catalogue['cb.restoreExpired'] = @{ ar = 'انتهى أو تغيّر طلب الاستعادة. اختر النسخة من جديد.'; en = 'The restore request expired or changed. Choose the backup again.' }
    $catalogue['cb.backupGone'] = @{ ar = 'النسخة المحددة لم تعد موجودة.'; en = 'The backup you chose is no longer there.' }
    $catalogue['rep.readLimitFile'] = @{ ar = "`n⚠️ بلغ السجل حدّ القراءة؛ قد تكون هناك عمليات أقدم داخل المدة لم تدخل الملف."; en = "`n⚠️ The log hit its read limit; there may be older operations inside the period that never reached this file." }
    $catalogue['rep.noScreenText'] = @{ ar = "`nلا يحتوي نصوص ما عُرض على الشاشة."; en = "`nIt carries none of the text that went on screen." }
    $catalogue['rep.textNotRecordedRow'] = @{ ar = '     📝 <i>النص غير مسجَّل لهذه العملية</i>'; en = '     📝 <i>The text is not recorded for this operation</i>' }
}
