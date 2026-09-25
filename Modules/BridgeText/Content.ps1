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


    # --- The news ticker ------------------------------------------------

    $catalogue['news.noResumableDraft'] = @{ ar = 'لا مسودة منتهية قابلة للاستئناف.'; en = 'There is no expired draft to resume.' }

    $catalogue['news.draftActive'] = @{ ar = 'توجد مسودة نشطة الآن — انشرها أو أغلقها أولًا.'; en = 'A draft is open right now — publish or close it first.' }

    $catalogue['news.noDraftOfYours'] = @{ ar = 'لا توجد مسودة مملوكة لك.'; en = 'You do not hold a draft.' }

    $catalogue['news.noDraftOfYoursShort'] = @{ ar = 'لا توجد مسودة مملوكة لك'; en = 'You do not hold a draft' }

    $catalogue['news.writeUrlHttps'] = @{ ar = 'يجب أن يبدأ رابط الكتابة بـ https.'; en = 'The write-back link must start with https.' }

    $catalogue['news.publishTicker'] = @{ ar = 'نشر شريط الأخبار'; en = 'publishing the news ticker' }

    $catalogue['news.draftAlreadyOpen'] = @{ ar = '🤝 المسودة مفتوحة أصلًا — اضغط ✏️ لتتابعها.'; en = '🤝 The draft is already open — press ✏️ to continue it.' }

    $catalogue['news.handLock'] = @{ ar = '✅ سلّم القفل'; en = '✅ Hand over the lock' }

    $catalogue['news.stillWorking'] = @{ ar = '⛔ ما زلت أعمل'; en = '⛔ I am still working' }

    $catalogue['news.requestNotSaved'] = @{ ar = '⚠️ تعذّر حفظ الطلب على القرص؛ إعادة تشغيل الجسر قبل الردّ ستُلغيه.'; en = '⚠️ The request could not be saved to disk; a restart before an answer will cancel it.' }

    $catalogue['news.ownerChanged'] = @{ ar = 'ℹ️ تغيّر مالك المسودة أثناء انتظار طلبك؛ أرسل طلب فكّ قفل جديدًا إن كنت ما زلت بحاجة إليها.'; en = 'ℹ️ The draft changed hands while your request was waiting; send a new unlock request if you still need it.' }

    $catalogue['news.lockHandedOver'] = @{ ar = '🔓 سُلّم قفل شريط الأخبار وأُلغيت مسودتك.'; en = '🔓 The ticker lock was handed over and your draft was discarded.' }

    $catalogue['news.draftTextBeforeDelete'] = @{ ar = '📄 نصّ مسودتك قبل حذفها، انسخه إن أردت:'; en = '📄 Your draft text before it is deleted; copy it if you want it:' }

    $catalogue['news.confirmSheetPublish'] = @{ ar = '⚠️ سحب الشيت ونشره على الهواء مباشرة؟'; en = '⚠️ Pull the sheet and publish it straight to air?' }

    $catalogue['news.confirmSheetDraft'] = @{ ar = '⚠️ تحميل الشيت في المسودة للمراجعة؟'; en = '⚠️ Load the sheet into the draft for review?' }

    $catalogue['news.nothingUntilPublish'] = @{ ar = 'لن يصل الهواء شيء قبل أن تضغط «مراجعة ونشر».'; en = 'Nothing reaches air until you press "review and publish".' }

    $catalogue['news.yesPublish'] = @{ ar = '✅ نعم، انشر'; en = '✅ Yes, publish' }

    $catalogue['news.yesLoadDraft'] = @{ ar = '✅ نعم، حمّل المسودة'; en = '✅ Yes, load the draft' }

    $catalogue['news.sheetNeedsLock'] = @{ ar = 'السحب من الشيت يحتاج قفل المسودة. اضغط ✏️ بدء التحرير أولًا.'; en = 'Pulling from the sheet needs the draft lock. Press ✏️ start editing first.' }

    $catalogue['news.draftUnowned'] = @{ ar = 'المسودة مفتوحة ولا مالك لها. اضغط ✏️ تابِع المسودة لتتبنّاها أولًا.'; en = 'The draft is open and unowned. Press ✏️ continue the draft to adopt it first.' }

    $catalogue['news.sheetUrlUnset'] = @{ ar = 'لم يُضبط رابط الشيت.'; en = 'The sheet link is not set.' }

    $catalogue['news.sheetUrlHttps'] = @{ ar = 'يجب أن يبدأ رابط الشيت بـ https.'; en = 'The sheet link must start with https.' }

    $catalogue['news.automatically'] = @{ ar = 'تلقائيًا'; en = 'automatically' }

    $catalogue['news.orderOnly'] = @{ ar = 'تغيّر الترتيب فقط'; en = 'only the order changed' }

    $catalogue['news.sheetUpdatedToo'] = @{ ar = '📄 وحُدِّث الشيت بالنص نفسه.'; en = '📄 And the sheet was updated with the same text.' }

    $catalogue['news.airAlreadyPublished'] = @{ ar = 'ما على الهواء منشور فعلًا؛ الشيت وحده متأخّر عنه.'; en = 'What is on air is already published; only the sheet is behind it.' }

    $catalogue['news.draftNeedsUser'] = @{ ar = 'السحب إلى المسودة يحتاج مستخدمًا معروفًا.'; en = 'Pulling into the draft needs a known user.' }

    $catalogue['news.sheetNotConfigured'] = @{ ar = 'لم يُضبط رابط Google Sheets في الإعدادات.'; en = 'The Google Sheets link is not set in Settings.' }

    $catalogue['news.syncSkipped'] = @{ ar = 'مسودة الأخبار قيد التحرير؛ تُخطّيت هذه الدورة.'; en = 'A news draft is being edited; this cycle was skipped.' }

    $catalogue['news.openDraftWarning'] = @{ ar = '🤝 توجد مسودة مفتوحة للجميع. التأكيد يستبدل محتواها بمحتوى الشيت.'; en = '🤝 There is a draft open to everyone. Confirming replaces its content with the sheet.' }

    $catalogue['news.sheetEmpty'] = @{ ar = 'الشيت فارغ؛ لن يُمسح الشريط تلقائيًا. امسحه يدويًا إن كان هذا مقصودًا.'; en = 'The sheet is empty; the ticker will not be cleared automatically. Clear it by hand if that is what you meant.' }

    $catalogue['news.autoSync'] = @{ ar = 'المزامنة التلقائية'; en = 'the automatic sync' }

    $catalogue['news.importTxt'] = @{ ar = '📥 استيراد TXT'; en = '📥 Import TXT' }

    $catalogue['news.startEditing'] = @{ ar = '✏️ بدء التحرير'; en = '✏️ Start editing' }

    $catalogue['news.addItem'] = @{ ar = '➕ إضافة خبر'; en = '➕ Add a headline' }

    $catalogue['news.editOrder'] = @{ ar = '📝 تعديل وترتيب'; en = '📝 Edit and reorder' }

    $catalogue['news.preview'] = @{ ar = '👁 معاينة'; en = '👁 Preview' }

    $catalogue['news.clearAll'] = @{ ar = '🧹 مسح الكل'; en = '🧹 Clear everything' }

    $catalogue['news.handOverDraft'] = @{ ar = '🤝 سلّم المسودة للتالي'; en = '🤝 Hand the draft to the next person' }

    $catalogue['news.reviewPublish'] = @{ ar = '✅ مراجعة ونشر'; en = '✅ Review and publish' }

    $catalogue['news.discardDraft'] = @{ ar = '🗑 إلغاء المسودة'; en = '🗑 Discard the draft' }

    $catalogue['news.requestUnlock'] = @{ ar = '🔓 طلب فكّ القفل'; en = '🔓 Request the lock' }

    $catalogue['news.forceUnlock'] = @{ ar = '🔓 إلغاء القفل (مشرف)'; en = '🔓 Force the lock open (administrator)' }

    $catalogue['news.backups'] = @{ ar = '🕘 النسخ والاستعادة'; en = '🕘 Backups and restore' }

    $catalogue['news.pullPublish'] = @{ ar = '⬇️ سحب ونشر'; en = '⬇️ Pull and publish' }

    $catalogue['news.pullDraft'] = @{ ar = '📝 سحب إلى المسودة'; en = '📝 Pull into the draft' }

    $catalogue['news.executionLog'] = @{ ar = '🧾 سجل التنفيذ'; en = '🧾 Execution log' }


    $catalogue['news.yesDelete'] = @{ ar = '🗑 نعم، احذف'; en = '🗑 Yes, delete' }

    $catalogue['news.moveUp'] = @{ ar = '⬆️ تحريك لأعلى'; en = '⬆️ Move up' }

    $catalogue['news.moveDown'] = @{ ar = '⬇️ تحريك لأسفل'; en = '⬇️ Move down' }

    $catalogue['news.backToOrder'] = @{ ar = '⬅️ رجوع للترتيب'; en = '⬅️ Back to the ordering' }

    $catalogue['news.backToManage'] = @{ ar = '⬅️ إدارة الأخبار'; en = '⬅️ News management' }

    $catalogue['news.prev'] = @{ ar = '◀️ السابق'; en = '◀️ Previous' }

    $catalogue['news.next'] = @{ ar = 'التالي ▶️'; en = 'Next ▶️' }

    $catalogue['news.orderTitle'] = @{ ar = '<b>📝 ترتيب المسودة</b>'; en = '<b>📝 Ordering the draft</b>' }

    $catalogue['news.orderHintStacked'] = @{ ar = 'أزرار كل خبر أسفله: ⬆️ ⬇️ ترتيب · ✏️ تعديل · 🗑 حذف'; en = 'Each headlines buttons are under it: ⬆️ ⬇️ order · ✏️ edit · 🗑 delete' }

    $catalogue['news.orderHintInline'] = @{ ar = '⬆️ ⬇️ للترتيب · اضغط النص للتعديل · 🗑 للحذف'; en = '⬆️ ⬇️ to reorder · press the text to edit · 🗑 to delete' }

    $catalogue['news.orderHintCompact'] = @{ ar = 'اضغط رقم الخبر: الترتيب والتعديل والحذف في شاشته'; en = 'Press the headline number: ordering, editing and deleting are on its screen' }

    $catalogue['news.orderHintNumbers'] = @{ ar = 'الرقم يفتح الخبر للتعديل · ⬆️ ⬇️ للترتيب · 🗑 للحذف'; en = 'The number opens the headline to edit · ⬆️ ⬇️ to reorder · 🗑 to delete' }

    $catalogue['news.orderHeading'] = @{ ar = '📝 الترتيب والتعديل'; en = '📝 Ordering and editing' }

    $catalogue['news.noDraftWarning'] = @{ ar = '⚠️ لا توجد مسودة مملوكة لك.'; en = '⚠️ You do not hold a draft.' }

    $catalogue['news.col.item'] = @{ ar = 'الخبر'; en = 'Headline' }

    $catalogue['news.chars'] = @{ ar = 'أحرف'; en = 'characters' }

    $catalogue['news.noDifference'] = @{ ar = 'لا فرق بين المسودة وما على الهواء.'; en = 'There is no difference between the draft and what is on air.' }

    $catalogue['news.reviewPublishButton'] = @{ ar = '✅ مراجعة النشر'; en = '✅ Review the publish' }

    $catalogue['news.noChangeOnPublish'] = @{ ar = 'لا فرق: النشر لن يغيّر ما على الهواء.'; en = 'No difference: publishing will not change what is on air.' }

    $catalogue['news.pickBackup'] = @{ ar = 'اختر نسخة لمراجعة استعادتها:'; en = 'Choose a backup to review restoring:' }

    $catalogue['news.backupsTitle'] = @{ ar = '<b>🕘 نسخ شريط الأخبار</b>'; en = '<b>🕘 News ticker backups</b>' }

    $catalogue['news.noBackups'] = @{ ar = '<i>لا نسخ محفوظة بعد. تُحفظ نسخة مع كل نشر.</i>'; en = '<i>No backups yet. One is kept with every publish.</i>' }

    $catalogue['news.backupUnreadable'] = @{ ar = ' · تعذّرت قراءتها'; en = ' · could not be read' }

    $catalogue['news.restoreNote'] = @{ ar = '<i>الاستعادة تعرض النسخة للمراجعة قبل أن يصل شيء إلى الهواء.</i>'; en = '<i>Restoring shows the backup for review before anything reaches air.</i>' }

    $catalogue['news.atStart'] = @{ ar = 'في أول الشريط'; en = 'at the start of the ticker' }

    $catalogue['news.atEnd'] = @{ ar = 'في آخر الشريط'; en = 'at the end of the ticker' }
    $catalogue['news.later.button'] = @{ ar = '📅 انشر في وقت محدّد'; en = '📅 Publish at a set time' }
    $catalogue['news.later.cancel'] = @{ ar = '📅 سيُنشر {0} — إلغاء الموعد'; en = '📅 Publishing at {0} — cancel it' }
    $catalogue['news.later.prompt'] = @{ ar = "📅 متى يُنشر الشريط؟ اكتب الوقت مثل 18:00 أو 2026-09-25 18:00، أو اختر:`nتبقى المسودة قابلة للتعديل حتى موعدها، ويُنشر ما فيها عندئذ."; en = "📅 When should the ticker publish? Type a time such as 18:00 or 2026-09-25 18:00, or pick one:`nThe draft stays editable until then, and whatever it holds is published." }
    $catalogue['news.later.in'] = @{ ar = 'بعد {0} د'; en = 'In {0} min' }
    $catalogue['news.later.set'] = @{ ar = '📅 سيُنشر الشريط {0}.'; en = '📅 The ticker will publish at {0}.' }
    $catalogue['news.later.refused'] = @{ ar = 'لم يُضبط الموعد: يجب أن يكون في المستقبل وأن تكون المسودة لك.'; en = 'The time was not set: it must be in the future, and the draft must be yours.' }
    $catalogue['news.later.done'] = @{ ar = '📅 نُشر الشريط في موعده {0}.'; en = '📅 The ticker was published at its time, {0}.' }
    $catalogue['news.later.failed'] = @{ ar = '⚠️ لم يُنشر الشريط في موعده {0}: {1}. المسودة باقية لتنشرها بنفسك.'; en = '⚠️ The ticker was not published at {0}: {1}. The draft is kept for you to publish.' }
    $catalogue['news.later.conflict'] = @{ ar = 'تغيّر الشريط على الهواء منذ بدأت المسودة'; en = 'the ticker on air changed since the draft was started' }
    $catalogue['news.later.openDraft'] = @{ ar = '📅 أُلغي موعد نشر الشريط: المسودة سُلّمت للجميع فلم يبقَ من يُنشر باسمه.'; en = '📅 The ticker''s publish time was dropped: the draft was handed to everyone, so there was nobody to publish as.' }
    $catalogue['news.later.label'] = @{ ar = 'نشر مجدول'; en = 'a scheduled publish' }
    $catalogue['news.later.audit'] = @{ ar = '📅 ضُبط نشر الشريط {0} — {1}'; en = '📅 The ticker set to publish at {0} — {1}' }
    $catalogue['news.execScheduled'] = @{ ar = 'نشر مجدول · {0}'; en = 'scheduled publish · {0}' }
    $catalogue['news.table.title'] = @{ ar = '📰 شريط الأخبار'; en = '📰 The news ticker' }
    $catalogue['news.table.headline'] = @{ ar = 'الخبر'; en = 'Headline' }
    $catalogue['news.table.state'] = @{ ar = 'الحالة'; en = 'State' }
    $catalogue['news.table.onAir'] = @{ ar = 'على الهواء'; en = 'on air' }
    $catalogue['news.table.firstOnly'] = @{ ar = 'يظهر أول {0} فقط، و{1} بعدها في شاشة الترتيب.'; en = 'The first {0} shown; {1} more are on the ordering screen.' }
    $catalogue['rows.paste.found'] = @{ ar = '📋 <b>وُجد في اللصق {0} صفّ</b>'; en = '📋 <b>{0} row(s) found in the paste</b>' }
    $catalogue['rows.paste.confirm'] = @{ ar = '➕ أضف {0} صفّ'; en = '➕ Add {0} row(s)' }
    $catalogue['mjz.pasteRows'] = @{ ar = '📋 لصق صفوف'; en = '📋 Paste rows' }
    $catalogue['mjz.pastePrompt'] = @{ ar = "📋 الصق الصفوف، صفًّا في كل سطر: <code>العنوان | القصة</code> — أو القصة وحدها.`nتأخذ الصورة التي على الشاشة، وتغيّرها لكل صفّ بعد الإضافة."; en = "📋 Paste the rows, one per line: <code>title | story</code> — or the story alone.`nThey take the picture on screen; change it per row after adding." }
    $catalogue['mjz.pasteBuiltInOnly'] = @{ ar = 'اللصق متاح للتصميم الأساسي للموجز وحده؛ هذا الموجز بتصميم له حقوله الخاصة، فأضف صفوفه واحدًا واحدًا.'; en = 'Pasting works with the bulletin''s built-in design only; this bulletin has a design with its own fields, so add its rows one at a time.' }
    $catalogue['news.pause'] = @{ ar = '⏸ إيقاف مؤقت (يبقى محفوظًا)'; en = '⏸ Pause (kept, not deleted)' }
    $catalogue['news.paused.done'] = @{ ar = '⏸ أُوقف الخبر مؤقتًا، ولن يُنشر حتى تعيده. تجده في «⏸ الموقوفة».'; en = '⏸ The headline is paused and will not be published until you bring it back. It is under ⏸ Paused.' }
    $catalogue['news.paused.open'] = @{ ar = '⏸ الموقوفة ({0})'; en = '⏸ Paused ({0})' }
    $catalogue['news.paused.title'] = @{ ar = '⏸ الأخبار الموقوفة مؤقتًا: {0}'; en = '⏸ Paused headlines: {0}' }
    $catalogue['news.paused.resume'] = @{ ar = '▶️ أعِد {0} إلى المسودة'; en = '▶️ Bring {0} back into the draft' }
    $catalogue['mjz.skipRow'] = @{ ar = '⏸ تخطَّ هذا الصفّ في العرض'; en = '⏸ Sit this row out of the run' }
    $catalogue['mjz.unskipRow'] = @{ ar = '▶️ أعِد الصفّ إلى العرض'; en = '▶️ Bring the row back into the run' }
    $catalogue['mjz.rowSkipped'] = @{ ar = '⏸ <b>هذا الصفّ متخطّى</b> — باقٍ في الجدول ولا يُعرض.'; en = '⏸ <b>This row sits out</b> — kept in the table, not played.' }
    $catalogue['news.execDraft'] = @{ ar = 'نشر المسودة · {0}'; en = 'the draft published · {0}' }
    $catalogue['news.execSheet'] = @{ ar = 'سحب من الشيت · {0}'; en = 'pulled from the sheet · {0}' }
    $catalogue['news.paste.found'] = @{ ar = '📋 <b>وُجد في اللصق {0} خبر</b>'; en = '📋 <b>{0} headline(s) found in the paste</b>' }
    $catalogue['news.paste.new'] = @{ ar = '✅ جديدة: {0}'; en = '✅ New: {0}' }
    $catalogue['news.paste.inDraft'] = @{ ar = '↩️ موجودة في المسودة وستُتجاوز: {0}'; en = '↩️ Already in the draft, skipped: {0}' }
    $catalogue['news.paste.repeated'] = @{ ar = '🔁 مكرّرة داخل اللصق: {0}'; en = '🔁 Repeated within the paste: {0}' }
    $catalogue['news.paste.tooLong'] = @{ ar = '⚠️ أطول من {1} حرف ولن تُضاف: {0}'; en = '⚠️ Longer than {1} characters, not added: {0}' }
    $catalogue['news.paste.noRoom'] = @{ ar = '⛔ لا تتّسع لها المسودة (الحد {1}): {0}'; en = '⛔ No room in the draft (the limit is {1}): {0}' }
    $catalogue['news.paste.more'] = @{ ar = '… و{0} أخرى'; en = '… and {0} more' }
    $catalogue['news.paste.keepSending'] = @{ ar = '<i>أرسل المزيد ليُضم إلى هذه الدفعة، أو اضغط «أضف». لم يُضف شيء بعد.</i>'; en = '<i>Send more to join this batch, or press Add. Nothing has been added yet.</i>' }
    $catalogue['news.paste.confirm'] = @{ ar = '➕ أضف {0} {1}'; en = '➕ Add {0} {1}' }
    $catalogue['news.paste.added'] = @{ ar = '✅ أُضيف {0} خبر {1}، بترتيب اللصق.'; en = '✅ Added {0} headline(s) {1}, in the order pasted.' }
    $catalogue['news.paste.nothingAdded'] = @{ ar = 'لم يُضف شيء: كل الأخبار موجودة في المسودة أو لا مكان لها.'; en = 'Nothing was added: every headline is already in the draft or there is no room.' }
    $catalogue['news.paste.cancelled'] = @{ ar = 'أُلغي اللصق، ولم يُضف شيء.'; en = 'The paste was cancelled, and nothing was added.' }
    $catalogue['news.paste.gone'] = @{ ar = 'انتهت هذه المراجعة. الصق الأخبار من جديد.'; en = 'This review has ended. Paste the headlines again.' }

    $catalogue['news.addFailed'] = @{ ar = '❌ لم تتم الإضافة؛ تحقق من النص والحدود.'; en = '❌ It was not added; check the text and the limits.' }

    $catalogue['news.itemUpdated'] = @{ ar = '✅ حُدّث الخبر في المسودة.'; en = '✅ The headline was updated in the draft.' }

    $catalogue['news.editFailed'] = @{ ar = '❌ تعذر تعديل الخبر.'; en = '❌ The headline could not be edited.' }

    $catalogue['news.startImportFirst'] = @{ ar = 'ابدأ الاستيراد من إدارة شريط الأخبار أولًا.'; en = 'Start the import from news management first.' }

    $catalogue['news.txtOnly'] = @{ ar = 'يُقبل ملف TXT فقط.'; en = 'Only a TXT file is accepted.' }

    $catalogue['news.orderNoDraft'] = @{ ar = '📝 الترتيب والتعديل'; en = '📝 Ordering and editing' }

    # --- The bulletin --------------------------------------------------

    $catalogue['mojaz.word'] = @{ ar = 'الموجز'; en = 'the bulletin' }

    $catalogue['mojaz.emptyAddRow'] = @{ ar = 'الجدول فارغ. أضف صفًّا: صورة، عنوان، خبر.'; en = 'The table is empty. Add a row: image, headline, story.' }

    $catalogue['mojaz.emptyAddRowHtml'] = @{ ar = '<i>الجدول فارغ. أضف صفًّا: صورة، عنوان، خبر.</i>'; en = '<i>The table is empty. Add a row: image, headline, story.</i>' }

    $catalogue['mojaz.col.title'] = @{ ar = 'العنوان'; en = 'Headline' }

    $catalogue['mojaz.col.story'] = @{ ar = 'الخبر'; en = 'Story' }

    $catalogue['mojaz.imageLegend'] = @{ ar = '🖼 صورة خاصة · ↑ يتبع الصف السابق · ▫️ صورة القالب'; en = '🖼 its own image · ↑ follows the previous row · ▫️ the template image' }

    $catalogue['mojaz.stopExit'] = @{ ar = '⏹ إيقاف وخروج'; en = '⏹ Stop and exit' }

    $catalogue['mojaz.runLater'] = @{ ar = '🕒 تشغيل لاحقًا'; en = '🕒 Run later' }

    $catalogue['mojaz.addRow'] = @{ ar = '➕ إضافة صف'; en = '➕ Add a row' }

    $catalogue['mojaz.clearTable'] = @{ ar = '🧹 مسح الجدول'; en = '🧹 Clear the table' }

    $catalogue['mojaz.rename'] = @{ ar = '✏️ إعادة تسمية'; en = '✏️ Rename' }

    $catalogue['mojaz.duplicate'] = @{ ar = '📋 نسخة منه'; en = '📋 Duplicate it' }

    $catalogue['mojaz.delete'] = @{ ar = '🗑 حذف الموجز'; en = '🗑 Delete the bulletin' }

    $catalogue['mojaz.previewFull'] = @{ ar = '👁 معاينة النص كاملًا'; en = '👁 Preview the whole text' }

    $catalogue['mojaz.schedules'] = @{ ar = '🕒 المواعيد'; en = '🕒 Scheduled times' }

    $catalogue['mojaz.refresh'] = @{ ar = '🔄 تحديث'; en = '🔄 Refresh' }

    $catalogue['mojaz.backToLibrary'] = @{ ar = '⬅️ الموجزات'; en = '⬅️ Bulletins' }

    $catalogue['mojaz.emptyHtml'] = @{ ar = '<i>الجدول فارغ.</i>'; en = '<i>The table is empty.</i>' }

    $catalogue['mojaz.backToTable'] = @{ ar = '⬅️ الجدول'; en = '⬅️ The table' }

    $catalogue['mojaz.noneSaved'] = @{ ar = 'لا توجد موجزات محفوظة. أنشئ موجزًا ثم أضف صفوفه.'; en = 'No bulletins are saved. Create one, then add its rows.' }

    $catalogue['mojaz.noneSavedHtml'] = @{ ar = '<i>لا توجد موجزات محفوظة. أنشئ موجزًا ثم أضف صفوفه.</i>'; en = '<i>No bulletins are saved. Create one, then add its rows.</i>' }

    $catalogue['mojaz.col.rows'] = @{ ar = 'صفوف'; en = 'Rows' }

    $catalogue['mojaz.col.review'] = @{ ar = 'مراجعة'; en = 'Review' }

    $catalogue['mojaz.col.state'] = @{ ar = 'الحالة'; en = 'State' }

    $catalogue['mojaz.onAir'] = @{ ar = '▶️ على الهواء'; en = '▶️ On air' }

    $catalogue['mojaz.onAirSuffix'] = @{ ar = ' · ▶️ على الهواء'; en = ' · ▶️ on air' }

    $catalogue['mojaz.libraryTitle'] = @{ ar = '<b>📑 الموجزات المحفوظة</b>'; en = '<b>📑 Saved bulletins</b>' }

    $catalogue['mojaz.prev'] = @{ ar = '⬅️ السابق'; en = '⬅️ Previous' }

    $catalogue['mojaz.next'] = @{ ar = 'التالي ➡️'; en = 'Next ➡️' }

    $catalogue['mojaz.new'] = @{ ar = '➕ موجز جديد'; en = '➕ New bulletin' }

    $catalogue['mojaz.home'] = @{ ar = '🏠 القائمة'; en = '🏠 Menu' }

    $catalogue['mojaz.askNewName'] = @{ ar = '📝 أرسل اسم الموجز الجديد، مثل: الموجز الصباحي.'; en = '📝 Send the new bulletins name, for example: Morning bulletin.' }

    $catalogue['mojaz.askRename'] = @{ ar = '✏️ أرسل الاسم الجديد لهذا الموجز.'; en = '✏️ Send this bulletins new name.' }

    $catalogue['mojaz.askCopyName'] = @{ ar = '📋 أرسل اسم النسخة الجديدة.'; en = '📋 Send the name for the copy.' }

    $catalogue['mojaz.saveFailed'] = @{ ar = '❌ تعذّر الحفظ. لم يتغيّر شيء؛ تحقّق من مساحة القرص والسجل.'; en = '❌ Could not save. Nothing changed; check the disk space and the log.' }

    $catalogue['mojaz.actionCreate'] = @{ ar = 'إنشاء'; en = 'creating' }

    $catalogue['mojaz.actionCopy'] = @{ ar = 'نسخ'; en = 'copying' }

    $catalogue['mojaz.undo'] = @{ ar = '↩️ تراجع'; en = '↩️ Undo' }

    $catalogue['mojaz.onAirStopFirst'] = @{ ar = '❌ هذا الموجز على الهواء الآن. أوقفه أولًا.'; en = '❌ This bulletin is on air right now. Stop it first.' }

    $catalogue['mojaz.cancelSchedulesFailed'] = @{ ar = '❌ تعذّر إلغاء مواعيد هذا الموجز، فلم يُحذف شيء.'; en = '❌ Its scheduled times could not be cancelled, so nothing was deleted.' }

    $catalogue['mojaz.deleteFailed'] = @{ ar = '❌ تعذّر حذف الموجز. لم يتغيّر شيء؛ تحقّق من مساحة القرص والسجل.'; en = '❌ Could not delete the bulletin. Nothing changed; check the disk space and the log.' }

    $catalogue['mojaz.img.inherit'] = @{ ar = '↑ يتبع السابق'; en = '↑ Follow the previous' }

    $catalogue['mojaz.img.template'] = @{ ar = '▫️ صورة القالب'; en = '▫️ The template image' }

    $catalogue['mojaz.cancel'] = @{ ar = '❌ إلغاء'; en = '❌ Cancel' }

    $catalogue['mojaz.askTitle'] = @{ ar = '📝 أرسل عنوان الصف (مثل: قطاع غزة).'; en = '📝 Send the rows headline.' }

    $catalogue['mojaz.field.image'] = @{ ar = '🖼 الصورة'; en = '🖼 Image' }

    $catalogue['mojaz.field.title'] = @{ ar = '📝 العنوان'; en = '📝 Headline' }

    $catalogue['mojaz.field.story'] = @{ ar = '📰 النص'; en = '📰 Story' }

    $catalogue['mojaz.deleteRow'] = @{ ar = '🗑 حذف الصف'; en = '🗑 Delete the row' }

    $catalogue['mojaz.askNewTitle'] = @{ ar = '📝 أرسل العنوان الجديد'; en = '📝 Send the new headline' }

    $catalogue['mojaz.askNewStory'] = @{ ar = '📰 أرسل نص الخبر الجديد'; en = '📰 Send the new story text' }

    $catalogue['mojaz.titleEmpty'] = @{ ar = '❌ العنوان فارغ. أرسل عنوانًا.'; en = '❌ The headline is empty. Send one.' }

    $catalogue['mojaz.storyEmpty'] = @{ ar = '❌ نص الخبر فارغ. أرسل النص.'; en = '❌ The story is empty. Send the text.' }

    $catalogue['mojaz.askStory'] = @{ ar = '📰 أرسل نص الخبر.'; en = '📰 Send the story text.' }

    $catalogue['mojaz.noImageFolder'] = @{ ar = '❌ لا يمكن تحديد مجلد الصور: القالب غير موجود.'; en = '❌ The image folder cannot be determined: the template does not exist.' }

    $catalogue['mojaz.asIs'] = @{ ar = 'كما هي'; en = 'as it is' }

    $catalogue['mojaz.notAnImage'] = @{ ar = '❌ هذا الملف ليس صورة يمكن قراءتها. أرسل صورة (JPG أو PNG).'; en = '❌ That file is not a readable image. Send a JPG or PNG.' }

    $catalogue['mojaz.frames1to15000'] = @{ ar = '❌ أرسل عدد إطارات بين 1 و15000.'; en = '❌ Send a frame count between 1 and 15000.' }

    $catalogue['mojaz.frames0to15000'] = @{ ar = '❌ أرسل عدد إطارات بين 0 و15000.'; en = '❌ Send a frame count between 0 and 15000.' }

    $catalogue['mojaz.cancelScheduleFailed'] = @{ ar = '❌ تعذّر إلغاء الموعد. لم يتغيّر شيء.'; en = '❌ Could not cancel the time. Nothing changed.' }

    $catalogue['mojaz.saveScheduleFailed'] = @{ ar = '❌ تعذّر حفظ الموعد. لم يتغيّر شيء.'; en = '❌ Could not save the time. Nothing changed.' }

    $catalogue['mojaz.schedTitle'] = @{ ar = '<b>🕒 مواعيد الموجزات</b>'; en = '<b>🕒 Bulletin schedule</b>' }

    $catalogue['mojaz.schedNone'] = @{ ar = '<i>لا مواعيد. افتح موجزًا واضغط «تشغيل لاحقًا».</i>'; en = '<i>No times. Open a bulletin and press "run later".</i>' }

    $catalogue['mojaz.schedNote'] = @{ ar = '<i>الموعد يستخدم آخر تحديث محفوظ للموجز، لا نسخته وقت الحجز</i>'; en = '<i>A scheduled time plays the latest saved version, not the one booked</i>' }

    $catalogue['mojaz.deletedBulletin'] = @{ ar = 'موجز محذوف'; en = 'a deleted bulletin' }

    $catalogue['mojaz.waitingOther'] = @{ ar = '⏳ في الانتظار — موجز آخر كان يعمل'; en = '⏳ Waiting — another bulletin was running' }

    $catalogue['mojaz.scheduled'] = @{ ar = '🕒 مجدول'; en = '🕒 Scheduled' }

    $catalogue['mojaz.execLog'] = @{ ar = '🧾 سجل التنفيذ'; en = '🧾 Execution log' }

    $catalogue['mojaz.scheduledBulletin'] = @{ ar = 'موجز مجدول'; en = 'a scheduled bulletin' }

    $catalogue['mojaz.theScheduled'] = @{ ar = 'الموجز المجدول'; en = 'the scheduled bulletin' }

    $catalogue['mojaz.theCurrent'] = @{ ar = 'الموجز الحالي'; en = 'the current bulletin' }

    $catalogue['mojaz.urgentOnAir'] = @{ ar = 'العاجل على الهواء'; en = 'the urgent item on air' }
}
