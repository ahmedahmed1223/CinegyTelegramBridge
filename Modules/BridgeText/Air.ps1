#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the air operation itself: the refusal sentences a SHOW can
    come back with, the maintenance notices, the notice board, the programme
    boards, the template checks, and the on-air card with the line it prints
    when Cinegy changed under the bot.
#>

function Add-BridgeTextAir {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- The air operation, the notices, the boards and the on-air card ---
    $catalogue['common.comma'] = @{ ar = '، '; en = ', ' }
    $catalogue['air.whileBusy'] = @{ ar = '📣 <b>حدث أثناء انشغالك:</b>'; en = '📣 <b>While you were busy:</b>' }
    $catalogue['air.takenOff'] = @{ ar = 'رُفع عن الهواء'; en = 'taken off air' }
    $catalogue['air.putOn'] = @{ ar = 'عُرض على الهواء'; en = 'put on air' }
    $catalogue['air.muteMyAlerts'] = @{ ar = '🔕 أوقف تنبيهاتي'; en = '🔕 Mute my alerts' }
    $catalogue['air.maintenanceOn'] = @{ ar = '🛠 وضع الصيانة مفعّل؛ أوامر التحكم في الهواء متوقفة مؤقتًا.'; en = '🛠 Maintenance mode is on; the air control commands are paused.' }
    $catalogue['air.sensitiveCap'] = @{ ar = 'سقف القالب الحسّاس'; en = 'the sensitive template ceiling' }
    $catalogue['air.templateLimit'] = @{ ar = 'حد القالب'; en = 'the template limit' }
    $catalogue['air.noConfirmAfterShow'] = @{ ar = 'لم يؤكد Cinegy أن المشهد على الهواء بعد SHOW.'; en = 'Cinegy did not confirm the scene was on air after SHOW.' }
    $catalogue['air.noActiveId'] = @{ ar = 'لم يعرض Cinegy معرّفًا نشطًا صالحًا.'; en = 'Cinegy reported no valid active id.' }
    $catalogue['air.noMatchableName'] = @{ ar = 'لم يعرض Cinegy اسم قالب يمكن مطابقته.'; en = 'Cinegy reported no template name that could be matched.' }
    $catalogue['air.maintenanceOnShort'] = @{ ar = 'وضع الصيانة مفعّل.'; en = 'Maintenance mode is on.' }
    $catalogue['air.layerCheckFailed'] = @{ ar = 'تعذّر التحقق من حالة طبقة Cinegy.'; en = 'Could not verify the state of the Cinegy layer.' }
    $catalogue['air.autoHideNotSet'] = @{ ar = ' ⚠️ لم يُضبط الإخفاء التلقائي لأن Cinegy لم يؤكد هوية المشهد؛ أخفه يدويًا.'; en = ' ⚠️ The automatic hide was not set because Cinegy did not confirm which scene this is; hide it by hand.' }
    $catalogue['air.hideTimerNotSaved'] = @{ ar = ' ⚠️ تعذّر حفظ مؤقت الإخفاء؛ أخفه يدويًا.'; en = ' ⚠️ Could not save the hide timer; hide it by hand.' }
    $catalogue['air.appearAlertNotSet'] = @{ ar = ' ⚠️ لم يُضبط تنبيه الظهور لأن Cinegy لم يؤكد هوية المشهد.'; en = ' ⚠️ The appearance alert was not set because Cinegy did not confirm which scene this is.' }
    $catalogue['air.appearAlertNotSaved'] = @{ ar = ' ⚠️ تعذّر حفظ تنبيه ظهور القالب لإعادة التشغيل.'; en = ' ⚠️ Could not save the template appearance alert across a restart.' }
    $catalogue['air.whyNotShown'] = @{ ar = '🔍 لماذا لم يظهر؟'; en = '🔍 Why did it not appear?' }
    $catalogue['air.templateAllowed'] = @{ ar = '✅ هذا القالب مسموح لك.'; en = '✅ This template is allowed for you.' }
    $catalogue['air.maintenanceAllStopped'] = @{ ar = '🛠 وضع الصيانة مفعّل — كل أوامر الهواء موقوفة.'; en = '🛠 Maintenance mode is on — every air command is stopped.' }
    $catalogue['air.maintenanceWindowOpen'] = @{ ar = '🛠 نافذة الصيانة المجدولة مفتوحة الآن — أوامر الهواء موقوفة حتى نهايتها.'; en = '🛠 The scheduled maintenance window is open now — the air commands are stopped until it ends.' }
    $catalogue['air.readOnlyCheck'] = @{ ar = '<i>فحص قراءة فقط: لم يُرسل شيء إلى Cinegy لإعداد هذه الشاشة.</i>'; en = '<i>A read-only check: nothing was sent to Cinegy to build this screen.</i>' }
    $catalogue['ann.noticeTitle'] = @{ ar = '📢 <b>تنويه</b>'; en = '📢 <b>Notice</b>' }
    $catalogue['ann.screen'] = @{ ar = '<b>📢 التنويهات</b>'; en = '<b>📢 Notices</b>' }
    $catalogue['ann.none'] = @{ ar = '<i>لا تنويه بعد. اكتب واحدًا ليصل من تختاره.</i>'; en = '<i>No notice yet. Write one and it reaches whoever you choose.</i>' }
    $catalogue['ann.active'] = @{ ar = '🟢 نشِط'; en = '🟢 Active' }
    $catalogue['ann.expired'] = @{ ar = '⌛ منتهٍ'; en = '⌛ Expired' }
    $catalogue['ann.stopped'] = @{ ar = '🚫 موقوف'; en = '🚫 Stopped' }
    $catalogue['ann.pinned'] = @{ ar = ' · مثبّت'; en = ' · pinned' }
    $catalogue['ann.new'] = @{ ar = '➕ تنويه جديد'; en = '➕ New notice' }
    $catalogue['ann.adminTools'] = @{ ar = '🗂 أدوات الإدارة'; en = '🗂 Administration tools' }
    $catalogue['ann.emptyText'] = @{ ar = '❌ النص فارغ. أرسل نص التنويه.'; en = '❌ The text is empty. Send the notice text.' }
    $catalogue['ann.admins'] = @{ ar = 'المشرفون'; en = 'The administrators' }
    $catalogue['ann.operators'] = @{ ar = 'المشغّلون'; en = 'The operators' }
    $catalogue['ann.everyone'] = @{ ar = 'الجميع'; en = 'Everyone' }
    $catalogue['ann.sendNow'] = @{ ar = '📤 إرسال الآن'; en = '📤 Send now' }
    $catalogue['board.showNow'] = @{ ar = '▶️ اعرض الآن'; en = '▶️ Show now' }
    $catalogue['board.disable'] = @{ ar = '🚫 تعطيل'; en = '🚫 Disable' }
    $catalogue['board.backToBoard'] = @{ ar = '⬅️ الجدول'; en = '⬅️ The board' }
    $catalogue['board.empty'] = @{ ar = '<i>(فارغ)</i>'; en = '<i>(empty)</i>' }
    $catalogue['tpl.invalid'] = @{ ar = 'غير صالح'; en = 'invalid' }
    $catalogue['tpl.neverAired'] = @{ ar = 'لم يُبث بعد'; en = 'never aired yet' }
    $catalogue['tpl.cannotDeleteOnAir'] = @{ ar = 'لا يمكن حذف قالب على الهواء.'; en = 'A template that is on air cannot be deleted.' }
    $catalogue['tpl.cannotDeleteScheduled'] = @{ ar = 'لا يمكن حذف قالب مرتبط بجدولة قادمة.'; en = 'A template tied to an upcoming schedule cannot be deleted.' }
    $catalogue['tpl.pathEmpty'] = @{ ar = 'مسار القالب فارغ.'; en = 'The template path is empty.' }
    $catalogue['tpl.layerPositive'] = @{ ar = 'رقم الطبقة يجب أن يكون موجبًا.'; en = 'The layer number must be positive.' }
    $catalogue['tpl.pathInsideProject'] = @{ ar = 'مسار القالب يجب أن يكون داخل مجلد المشروع.'; en = 'The template path must sit inside the project folder.' }
    $catalogue['tpl.fieldNoName'] = @{ ar = 'يوجد حقل بلا اسم صالح.'; en = 'There is a field without a valid name.' }
    $catalogue['tpl.durationRange'] = @{ ar = 'المدة يجب أن تكون من 0 إلى 1440 دقيقة.'; en = 'The duration must be from 0 to 1440 minutes.' }
    $catalogue['tpl.layerState'] = @{ ar = '🎚 حالة طبقات Cinegy:'; en = '🎚 The state of the Cinegy layers:' }
    $catalogue['tpl.layerActions'] = @{ ar = 'الإجراءات: 🙈 إخفاء = يخفي الطبقة فورًا | 🔄 تحديث = يعيد فحص كل الطبقات'; en = 'The actions: 🙈 Hide takes the layer down at once | 🔄 Refresh re-reads every layer' }
    $catalogue['tpl.unnamedScene'] = @{ ar = 'مشهد غير مسمّى'; en = 'an unnamed scene' }
    $catalogue['tpl.connected'] = @{ ar = 'متصل'; en = 'connected' }
    $catalogue['tpl.clientOffline'] = @{ ar = 'العميل غير متصل'; en = 'the client is offline' }
    $catalogue['tpl.healthUnknownMetrics'] = @{ ar = '⚠️ صحة Cinegy: غير معروفة (تعذّر قراءة metrics)'; en = '⚠️ Cinegy health: unknown (the metrics could not be read)' }
    $catalogue['tpl.healthUnknownSamples'] = @{ ar = '⚠️ صحة Cinegy: غير معروفة (لا توجد عينات)'; en = '⚠️ Cinegy health: unknown (there are no samples)' }
    $catalogue['onair.unavailable'] = @{ ar = '🔴 غير متاح'; en = '🔴 Unavailable' }
    $catalogue['onair.unknownDot'] = @{ ar = '⚪ غير معروف'; en = '⚪ Unknown' }
    $catalogue['onair.connected'] = @{ ar = '🟢 متصل'; en = '🟢 Connected' }
    $catalogue['onair.externalChange'] = @{ ar = '⚠️ تغيير خارجي في Cinegy'; en = '⚠️ An external change in Cinegy' }
    $catalogue['onair.replacedExternally'] = @{ ar = 'استُبدل خارجيًا'; en = 'replaced from outside' }
    $catalogue['onair.noLongerOnAir'] = @{ ar = 'لم يعد على الهواء'; en = 'no longer on air' }
    $catalogue['onair.unnamedItem'] = @{ ar = 'عنصر غير مسمّى'; en = 'an unnamed item' }
    $catalogue['onair.unknownExternalSource'] = @{ ar = 'مصدر خارجي غير معرّف'; en = 'an unidentified outside source' }
    $catalogue['onair.layerEmptyExplain'] = @{ ar = 'لا عنصر آخر على الطبقة — المشهد انتهى أو أُخفي من خارج البوت، ولم يأخذها أحد.'; en = 'Nothing else is on the layer — the scene ended or was hidden from outside the bot, and no one took it.' }
    $catalogue['onair.stateUpdated'] = @{ ar = 'تم تحديث حالة البوت وإلغاء أي مؤقت مرتبط.'; en = 'The bot state was refreshed and any timer tied to it was cancelled.' }
    $catalogue['onair.yoursLeft'] = @{ ar = '⚫️ <b>{0}</b> لم يعد على الهواء — طبقة {1}.'; en = '⚫️ <b>{0}</b> is no longer on air — layer {1}.' }
    $catalogue['onair.yoursLeftAfter'] = @{ ar = '⏱ بقي على الهواء {0}.'; en = '⏱ It was on air for {0}.' }
    $catalogue['onair.yoursReplaced'] = @{ ar = '⚠️ أخذ الطبقة: {0}'; en = '⚠️ What took the layer: {0}' }
}
