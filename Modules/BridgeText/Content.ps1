#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the content systems: the programme boards and the urgent board.

    Split out when the catalogue passed a thousand lines: one file per domain
    keeps each under the size this repository asks a file to stay, and puts a
    translator in front of one subject at a time instead of the whole bot.
    Nothing about the contract changed - every entry still carries both
    languages, and Test-BridgeTextCatalogue still reads them all together.
#>

function Add-BridgeTextContent {
    <# Fills the shared dictionary in place. Partial by design: the catalogue
       is one ordered map assembled from four files, not four maps. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- Programme content boards ---------------------------------------
    $catalogue['boards.title'] = @{ ar = '🗂 محتوى البرامج'; en = '🗂 Programme content' }
    $catalogue['boards.empty'] = @{ ar = 'لا جدول بعد.'; en = 'No board yet.' }
    $catalogue['boards.empty.bound'] = @{
        ar = '<b>كل جدول مبنيّ على قالب تختاره أنت</b>، والقالب هو الذي يقرّر حقول كل صفّ والطبقة.'
        en = '<b>Every board is bound to a template you choose</b>, and the template decides each row''s fields and the layer.'
    }
    $catalogue['boards.empty.steps'] = @{
        ar = 'الإنشاء خطوتان: «➕ جدول جديد» ← اختر القالب ← سمِّ الجدول.'
        en = 'Two steps: "➕ New board" → choose the template → name the board.'
    }
    $catalogue['boards.empty.then'] = @{
        ar = 'ثم يكتب المعدّ نصوص الحلقة صفًّا صفًّا أو بلصقة واحدة، ويعرضها المنفّذ بضغطة.'
        en = 'The producer then writes the episode''s texts row by row or as one paste, and the operator shows them with one press.'
    }
    $catalogue['boards.count'] = @{ ar = '{0} جدولًا. اضغط جدولًا لفتح صفوفه.'; en = '{0} board(s). Press one to open its rows.' }
    $catalogue['boards.new'] = @{ ar = '➕ جدول جديد'; en = '➕ New board' }
    $catalogue['boards.addRow'] = @{ ar = '➕ إضافة صفّ'; en = '➕ Add row' }
    $catalogue['boards.paste'] = @{ ar = '📋 لصق دفعة'; en = '📋 Paste a batch' }
    $catalogue['boards.delete'] = @{ ar = '🗑 حذف الجدول'; en = '🗑 Delete board' }
    $catalogue['boards.role.button'] = @{ ar = '🛡 من يملأ الجدول: {0}'; en = '🛡 Who may fill it: {0}' }
    $catalogue['boards.role.all'] = @{ ar = 'الجميع'; en = 'Everyone' }
    $catalogue['boards.role.admin'] = @{ ar = 'المشرفون'; en = 'Administrators' }
    $catalogue['boards.role.owner'] = @{ ar = 'المالك'; en = 'The owner' }
    $catalogue['boards.template'] = @{ ar = '📐 القالب: <b>{0}</b> · طبقة {1}'; en = '📐 Template: <b>{0}</b> · layer {1}' }
    $catalogue['boards.fields'] = @{ ar = 'حقول كل صفّ ({0}): {1}'; en = 'Fields per row ({0}): {1}' }
    $catalogue['boards.templateFixed'] = @{
        ar = 'القالب يُختار عند الإنشاء ولا يتغيّر — لجدولٍ بقالبٍ آخر أنشئ جدولًا آخر.'
        en = 'The template is chosen at creation and does not change — for another template, create another board.'
    }
    $catalogue['boards.rows'] = @{ ar = 'الصفوف: {0} من {1}'; en = 'Rows: {0} of {1}' }
    $catalogue['boards.templateGone'] = @{
        ar = "⛔ قالب هذا الجدول ('{0}') لم يعد في السجلّ، فلا يمكن عرض صفوفه. صفوفه محفوظة كما هي."
        en = "⛔ This board's template ('{0}') is no longer in the registry, so its rows cannot be shown. The rows are kept as they are."
    }
    $catalogue['boards.picker.title'] = @{ ar = '🗂 <b>الخطوة 1 من 2: اختر قالب البرنامج</b>'; en = '🗂 <b>Step 1 of 2: choose the programme template</b>' }
    $catalogue['boards.picker.decides'] = @{
        ar = 'القالب الذي تختاره هو الذي يقرّر <b>حقول كل صفّ</b> و<b>الطبقة</b> التي يخرج عليها.'
        en = 'The template you choose decides <b>each row''s fields</b> and the <b>layer</b> it goes out on.'
    }
    $catalogue['boards.picker.fields'] = @{
        ar = 'الحقول تُقرأ من المشهد نفسه، فلا تُكتب ولا تُخترع — والرقم بجوار كل قالب هو عددها.'
        en = 'The fields are read from the scene itself, never typed or invented — the number beside each template is how many.'
    }
    $catalogue['boards.picker.fixed'] = @{
        ar = 'ولا يتغيّر القالب بعد الإنشاء؛ لبرنامجٍ آخر أنشئ جدولًا آخر.'
        en = 'The template does not change after creation; for another programme, create another board.'
    }
    $catalogue['boards.picker.usable'] = @{ ar = '✅ {0} · {1} حقلًا'; en = '✅ {0} · {1} field(s)' }
    $catalogue['boards.picker.unusable'] = @{ ar = '⛔ {0}'; en = '⛔ {0}' }
    $catalogue['boards.picked'] = @{ ar = '✅ القالب: <b>{0}</b>'; en = '✅ Template: <b>{0}</b>' }
    $catalogue['boards.picked.fields'] = @{ ar = 'حقول كل صفّ: {0}'; en = 'Fields per row: {0}' }
    $catalogue['boards.name.prompt'] = @{
        ar = '<b>الخطوة 2 من 2:</b> أرسل اسم الجدول كما تريد أن يراه المشغّل'
        en = '<b>Step 2 of 2:</b> send the board''s name as the operator should see it'
    }
    $catalogue['boards.name.example'] = @{ ar = '(مثلًا: بنر برنامج الاقتصاد).'; en = '(for example: Economy Programme Banner).' }
    $catalogue['boards.full'] = @{ ar = '⛔ بلغت الجداول سقفها ({0}).'; en = '⛔ Boards have reached their ceiling ({0}).' }
    $catalogue['boards.deleteConfirm'] = @{
        ar = '⚠️ حذف «{0}» ومعه {1} صفًّا. لا تراجع.'
        en = '⚠️ Delete "{0}" and its {1} row(s). This cannot be undone.'
    }
    $catalogue['boards.deleteYes'] = @{ ar = '🗑 نعم، احذف'; en = '🗑 Yes, delete' }
    $catalogue['boards.list'] = @{ ar = '⬅️ الجداول'; en = '⬅️ Boards' }
    $catalogue['boards.live'] = @{ ar = '🔴 على الهواء الآن'; en = '🔴 On air now' }
    $catalogue['boards.hide'] = @{ ar = '⏹ إخفاء'; en = '⏹ Hide' }
    $catalogue['boards.orphan'] = @{
        ar = '⚠️ {0} لم تعد في المشهد، فقيمتها محفوظة ولا تُرسل.'
        en = '⚠️ {0} is no longer in the scene, so its value is kept but not sent.'
    }
    $catalogue['boards.autoHide'] = @{ ar = '⏱ هذا القالب يُخفى تلقائيًا بعد {0} ث.'; en = '⏱ This template auto-hides after {0}s.' }

    # --- The urgent board -----------------------------------------------
    $catalogue['urgent.saveFailed'] = @{ ar = '❌ تعذّر حفظ جدول العواجل.'; en = '❌ Could not save the urgent board.' }
    $catalogue['urgent.mode.exit'] = @{ ar = '🚪 مع حركة خروج'; en = '🚪 With the exit animation' }
    $catalogue['urgent.mode.autoHide'] = @{ ar = '🙈 إخفاء بعد المدة'; en = '🙈 Hide after the time' }
    $catalogue['urgent.mode.text'] = @{ ar = '✏️ تحديث نص'; en = '✏️ Update the text' }
    $catalogue['urgent.state.disabled'] = @{ ar = '⛔ معطّل'; en = '⛔ Disabled' }
    $catalogue['urgent.state.onAir'] = @{ ar = '🔴 على الهواء'; en = '🔴 On air' }
    $catalogue['urgent.state.selected'] = @{ ar = '✅ محدد'; en = '✅ Selected' }
    $catalogue['urgent.state.ready'] = @{ ar = '🟢 جاهز'; en = '🟢 Ready' }
    $catalogue['urgent.updatedUnknown'] = @{ ar = 'وقت التحديث غير معروف'; en = 'Update time unknown' }
    $catalogue['urgent.lessThanMinute'] = @{ ar = 'منذ أقل من دقيقة'; en = 'Less than a minute ago' }
    $catalogue['urgent.filter.ready'] = @{ ar = 'الجاهز'; en = 'Ready' }
    $catalogue['urgent.filter.selected'] = @{ ar = 'المحدد'; en = 'Selected' }
    $catalogue['urgent.filter.onAir'] = @{ ar = 'على الهواء'; en = 'On air' }
    $catalogue['urgent.filter.disabled'] = @{ ar = 'المعطّل'; en = 'Disabled' }
    $catalogue['urgent.filter.newest'] = @{ ar = 'الأحدث'; en = 'Newest' }
    $catalogue['urgent.filter.all'] = @{ ar = 'الكل'; en = 'All' }
    $catalogue['urgent.filter.section'] = @{ ar = '🔎 قسم التصفية'; en = '🔎 Filter' }
    $catalogue['urgent.filter.newestButton'] = @{ ar = '🕒 الأحدث'; en = '🕒 Newest' }
    $catalogue['urgent.noLoopFixNow'] = @{ ar = '⚠️ المشهد بلا حلقة — اضبط الآن'; en = '⚠️ The scene has no loop — fix it now' }
    $catalogue['urgent.rowsDivider'] = @{ ar = '──────── صفوف الأخبار ────────'; en = '──────── the story rows ────────' }
    $catalogue['urgent.read'] = @{ ar = '👁 قراءة'; en = '👁 Read' }
    $catalogue['urgent.actions'] = @{ ar = '⚙️ إجراءات'; en = '⚙️ Actions' }
    $catalogue['urgent.runOnAir'] = @{ ar = '🚨 تشغيل على الهواء'; en = '🚨 Put it on air' }
    $catalogue['urgent.stopCurrent'] = @{ ar = '⏹ إيقاف العاجل الحالي'; en = '⏹ Stop the current item' }
    $catalogue['urgent.add'] = @{ ar = '➕ إضافة'; en = '➕ Add' }
    $catalogue['urgent.selectAll'] = @{ ar = '☑ تحديد الكل'; en = '☑ Select all' }
    $catalogue['urgent.clearSelection'] = @{ ar = '☐ إلغاء التحديد'; en = '☐ Clear the selection' }
    $catalogue['urgent.timings'] = @{ ar = '⚙️ توقيتات الجدول'; en = '⚙️ Board timings' }
    $catalogue['urgent.deleteSelected'] = @{ ar = '🗑 حذف المحدَّد'; en = '🗑 Delete the selected' }
    $catalogue['urgent.retryStop'] = @{ ar = '🔁 إعادة الإيقاف'; en = '🔁 Try stopping again' }
    $catalogue['urgent.stopRun'] = @{ ar = '⏹ إيقاف التشغيل'; en = '⏹ Stop the run' }
    $catalogue['urgent.resume'] = @{ ar = '▶️ استئناف'; en = '▶️ Resume' }
    $catalogue['urgent.pause'] = @{ ar = '⏸ مؤقت'; en = '⏸ Pause' }
    $catalogue['urgent.skipCurrent'] = @{ ar = '⏭ تخطي الحالي'; en = '⏭ Skip the current one' }
    $catalogue['urgent.playAll'] = @{ ar = '⏭ تشغيل الكل'; en = '⏭ Play them all' }
    $catalogue['urgent.playNextReady'] = @{ ar = '⏭ تشغيل التالي الجاهز'; en = '⏭ Play the next ready one' }
    $catalogue['urgent.stopUnconfirmed'] = @{ ar = '⚠️ تعذّر تأكيد الإيقاف؛ التشغيل مجمّد وحالة الهواء غير مؤكدة. أعد محاولة الإيقاف، لا الاستئناف.'; en = '⚠️ The stop could not be confirmed; the run is frozen and the air state is unconfirmed. Try stopping again, not resuming.' }
    $catalogue['urgent.pausedNote'] = @{ ar = '⏸ متوقف مؤقتًا؛ العاجل يبقى ظاهرًا. مؤقّت أمان القالب لا يتوقف.'; en = '⏸ Paused; the item stays on screen. The template safety timer does not pause.' }
    $catalogue['urgent.running'] = @{ ar = '▶️ يعمل'; en = '▶️ Running' }
    $catalogue['urgent.nextEnd'] = @{ ar = 'التالي: نهاية الجدول'; en = 'Next: the end of the board' }
    $catalogue['urgent.noCeiling'] = @{ ar = 'بلا سقف'; en = 'No ceiling' }
    $catalogue['urgent.emptyPress'] = @{ ar = 'الجدول فارغ. اضغط ➕ إضافة.'; en = 'The board is empty. Press ➕ Add.' }
    $catalogue['urgent.empty'] = @{ ar = 'الجدول فارغ.'; en = 'The board is empty.' }
    $catalogue['urgent.col.item'] = @{ ar = 'العاجل'; en = 'Item' }
    $catalogue['urgent.col.mode'] = @{ ar = 'العرض'; en = 'Mode' }
    $catalogue['urgent.col.interval'] = @{ ar = 'الفاصل'; en = 'Interval' }
    $catalogue['urgent.legend'] = @{ ar = '🟢 جاهز · 🔴 على الهواء · ✅ محدد · ⛔ معطّل · ✱ = قيمة خاصة بالعنصر · التحديد يخصّ محادثتك وحدها.'; en = '🟢 ready · 🔴 on air · ✅ selected · ⛔ disabled · ✱ = a value of its own · the selection is yours alone.' }
    $catalogue['urgent.noLoopShort'] = @{ ar = '⚠️ مشهد العاجل بلا حلقة: «تحديث نص» سيُرى وهو يتبدّل.'; en = '⚠️ The urgent scene has no loop: "update the text" will be seen changing.' }
    $catalogue['urgent.noLoopUseExit'] = @{ ar = '⚠️ مشهد العاجل بلا حلقة: «تحديث نص» سيُرى وهو يتبدّل. استعمل «مع حركة خروج».'; en = '⚠️ The urgent scene has no loop: "update the text" will be seen changing. Use "with the exit animation".' }
    $catalogue['urgent.back'] = @{ ar = '⬅️ العواجل'; en = '⬅️ Urgent' }
    $catalogue['urgent.liveNow'] = @{ ar = '🔴 على الهواء الآن'; en = '🔴 On air now' }
    $catalogue['urgent.stopThis'] = @{ ar = '⏹ إيقاف الحالي'; en = '⏹ Stop the current one' }
    $catalogue['urgent.editText'] = @{ ar = '✏️ تعديل النص'; en = '✏️ Edit the text' }
    $catalogue['urgent.title'] = @{ ar = '🏷 العنوان'; en = '🏷 Title' }
    $catalogue['urgent.displayMode'] = @{ ar = '🎬 نمط العرض'; en = '🎬 Display mode' }
    $catalogue['urgent.fromBoard'] = @{ ar = '↩️ من الجدول'; en = '↩️ From the board' }
    $catalogue['urgent.disable'] = @{ ar = '⛔ تعطيل'; en = '⛔ Disable' }
    $catalogue['urgent.enable'] = @{ ar = '✅ تفعيل'; en = '✅ Enable' }
    $catalogue['urgent.moveUp'] = @{ ar = '⬆️ أعلى'; en = '⬆️ Up' }
    $catalogue['urgent.moveDown'] = @{ ar = '⬇️ أسفل'; en = '⬇️ Down' }
    $catalogue['urgent.sceneUnknown'] = @{ ar = 'مشهد حالي غير معروف'; en = 'the current scene is unknown' }
    $catalogue['urgent.showThisOne'] = @{ ar = 'عرض هذا الخبر'; en = 'Show this story' }
    $catalogue['urgent.backNoShow'] = @{ ar = 'رجوع دون عرض'; en = 'Back without showing' }
    $catalogue['urgent.shownAlone'] = @{ ar = '🚨 عُرض الخبر وحده. لن ينتقل للخبر التالي تلقائيًا.'; en = '🚨 The story was shown on its own. It will not advance to the next by itself.' }
    $catalogue['urgent.hideShown'] = @{ ar = 'إخفاء الخبر المعروض'; en = 'Hide the shown story' }
    $catalogue['urgent.pickAnother'] = @{ ar = 'اختيار خبر آخر'; en = 'Choose another story' }
    $catalogue['urgent.itemGone'] = @{ ar = '⚠️ الخبر لم يعد موجودًا. افتح الجدول من جديد.'; en = '⚠️ The story is gone. Open the board again.' }
    $catalogue['urgent.prevPart'] = @{ ar = 'الجزء السابق'; en = 'The previous part' }
    $catalogue['urgent.restOfText'] = @{ ar = 'بقية النص'; en = 'The rest of the text' }
    $catalogue['urgent.prevItem'] = @{ ar = '⬅️ الخبر السابق'; en = '⬅️ Previous story' }
    $catalogue['urgent.nextItem'] = @{ ar = 'الخبر التالي ➡️'; en = 'Next story ➡️' }
    $catalogue['urgent.showAlone'] = @{ ar = '🚨 عرض هذا الخبر وحده'; en = '🚨 Show this story on its own' }
    $catalogue['urgent.editAndSettings'] = @{ ar = '✏️ تعديل وإعدادات'; en = '✏️ Edit and settings' }
    $catalogue['urgent.backToBoard'] = @{ ar = '⬅️ الجدول'; en = '⬅️ The board' }
    $catalogue['urgent.notFound'] = @{ ar = '⚠️ العاجل غير موجود.'; en = '⚠️ That urgent item does not exist.' }
    $catalogue['urgent.noTitleField'] = @{ ar = '⚠️ هذا المشهد يحمل حقلًا واحدًا، فالعنوان لا يظهر على الهواء — النصّ وحده هو ما يُعرض.'; en = '⚠️ This scene carries one field, so the title never reaches air — only the text is shown.' }
    $catalogue['urgent.noLoopSwap'] = @{ ar = '⚠️ هذا المشهد بلا حلقة: التبديل سيُرى.'; en = '⚠️ This scene has no loop: the swap will be seen.' }
    $catalogue['urgent.manualDisable'] = @{ ar = 'تعطيل يدوي'; en = 'disabled by hand' }
    $catalogue['urgent.orderItem'] = @{ ar = 'الترتيب: كل عاجل مرّات (١ ١ · ٢ ٢)'; en = 'Order: each item repeated (1 1 · 2 2)' }
    $catalogue['urgent.orderCycle'] = @{ ar = 'الترتيب: الجدول كاملًا (١ ٢ ٣ · ١ ٢ ٣)'; en = 'Order: the whole board (1 2 3 · 1 2 3)' }
    $catalogue['urgent.totalNone'] = @{ ar = '⏳ المدة الكلية: بلا سقف'; en = '⏳ Total time: no ceiling' }
    $catalogue['urgent.gapSceneOnly'] = @{ ar = '⏳ الفاصل بين الأخبار: حركة المشهد وحدها'; en = '⏳ Gap between stories: the scene motion alone' }
    $catalogue['urgent.timings.title'] = @{ ar = '⚙️ <b>توقيتات جدول العواجل</b>'; en = '⚙️ <b>Urgent board timings</b>' }
    $catalogue['urgent.timings.intro'] = @{ ar = 'هذه قيم الجدول. كل عاجل يستطيع تجاوزها من شاشته، وما لم يتجاوزها يأخذها من هنا.'; en = 'These are the board values. Each item may override them from its own screen; whatever it does not override, it takes from here.' }
    $catalogue['urgent.timings.order'] = @{ ar = 'الترتيب: «الجدول كاملًا» يعيد الجدول من أوّله (١ ٢ ٣ · ١ ٢ ٣)، و«كل عاجل مرّات» يكرّر العاجل ثم ينتقل (١ ١ · ٢ ٢).'; en = 'Order: "the whole board" replays it from the start (1 2 3 · 1 2 3); "each item repeated" repeats one then moves on (1 1 · 2 2).' }
    $catalogue['urgent.timings.gap'] = @{ ar = 'الفاصل بين الأخبار يخصّ نمط «حركة الخروج» وحده: شاشة فارغة بين خبر وآخر. وهو يرفع أقصر فاصل مسموح بالقدر نفسه، لأن السطر لا يُعرض أقصر من انتقاله.'; en = 'The gap between stories belongs to the exit mode alone: a blank screen between one and the next. It raises the shortest allowed interval by the same amount, because a line cannot be shown for less than its own transition.' }
    $catalogue['urgent.scopeSelected'] = @{ ar = 'المحدَّد'; en = 'the selected' }
    $catalogue['urgent.scopeWhole'] = @{ ar = 'الجدول كاملًا'; en = 'the whole board' }
    $catalogue['urgent.reviewTitle'] = @{ ar = '▶️ <b>مراجعة قبل التشغيل</b> — {0}'; en = '▶️ <b>Review before running</b> — {0}' }
    $catalogue['urgent.totalLabel'] = @{ ar = 'المدة الكلية'; en = 'Total time' }
    $catalogue['urgent.startNow'] = @{ ar = '🚨 ابدأ الآن'; en = '🚨 Start now' }
    $catalogue['urgent.fixLoop'] = @{ ar = '⚠️ اضبط التبديل — الحلقة مفقودة'; en = '⚠️ Fix the swap — the loop is missing' }
    $catalogue['urgent.nothingToDelete'] = @{ ar = 'لم تحدّد شيئًا لحذفه.'; en = 'You have not selected anything to delete.' }
    $catalogue['urgent.deleteExpired'] = @{ ar = '⚠️ انتهت صلاحية تأكيد الحذف. حدّد العواجل وأكّد من جديد.'; en = '⚠️ The delete confirmation has expired. Select the items and confirm again.' }
    $catalogue['urgent.pickNumberButton'] = @{ ar = 'اختر قيمة رقمية صحيحة من الأزرار.'; en = 'Choose a whole number from the buttons.' }
    $catalogue['urgent.settingSaveFailed'] = @{ ar = 'تعذّر حفظ الإعداد؛ بقيت القيمة السابقة.'; en = 'Could not save the setting; the previous value stands.' }
    $catalogue['urgent.num.itemInterval'] = @{ ar = 'فاصل هذا العاجل (ثانية)'; en = 'This items interval (seconds)' }
    $catalogue['urgent.num.inherited'] = @{ ar = 'من الجدول'; en = 'from the board' }
    $catalogue['urgent.num.itemRepeats'] = @{ ar = 'تكرار هذا العاجل'; en = 'This items repeats' }
    $catalogue['urgent.num.boardInterval'] = @{ ar = 'فاصل الجدول (ثانية)'; en = 'The board interval (seconds)' }
    $catalogue['urgent.num.boardRepeats'] = @{ ar = 'تكرار الجدول'; en = 'The board repeats' }
    $catalogue['urgent.num.total'] = @{ ar = 'المدة الكلية (ثانية)'; en = 'Total time (seconds)' }
    $catalogue['urgent.num.gap'] = @{ ar = 'الفاصل بين الأخبار (ثانية)'; en = 'Gap between stories (seconds)' }
    $catalogue['urgent.num.sceneOnly'] = @{ ar = 'حركة المشهد وحدها'; en = 'the scene motion alone' }
    $catalogue['urgent.num.doneBack'] = @{ ar = '✅ تمّ / رجوع'; en = '✅ Done / back' }
    $catalogue['urgent.num.expired'] = @{ ar = '⚠️ انتهت صلاحية هذه الأزرار. افتح شاشة الرقم من جديد.'; en = '⚠️ These buttons have expired. Open the number screen again.' }
    $catalogue['urgent.manualSingle'] = @{ ar = '🚨 عرض خبر واحد فقط — دون انتقال تلقائي.'; en = '🚨 Showing one story only — with no automatic advance.' }
    $catalogue['urgent.manualRules'] = @{ ar = 'تظل قواعد الإخفاء والتمديد سارية.'; en = 'The hide and extension rules still apply.' }
}
