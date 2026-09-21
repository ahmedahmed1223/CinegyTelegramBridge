#requires -Version 7
<#
    BridgeLanguage.psm1 - the bridge's text in both languages.

    WHY A CATALOGUE AND NOT A SECOND SET OF LITERALS

    The bridge grew with its Arabic written inline, which was right while the
    station that runs it is the only one reading the screens. Publishing it
    means a second reader, and the two ways to serve them are:

      - branch at every call site (`if ($lang -eq 'en') { ... } else { ... }`),
        which doubles every screen in place and guarantees the two halves
        drift the first time one is edited alone; or
      - name each piece of text once and hold both languages beside each
        other, where a missing translation is a fact a test can assert rather
        than a sentence somebody has to notice.

    This is the second. A key that lacks 'en' falls back to Arabic and says so
    once in the log - an operator reading one English screen with one Arabic
    line still knows what it says, while a screen that refuses to render
    because a key is missing takes the graphics with it.

    THE ARABIC LIVES HERE TOO, NOT AT THE CALL SITE

    Keeping the Arabic inline and passing only English here would leave the
    catalogue half-populated and the coverage test unable to see what it is
    missing. Both languages sit together so that reading one entry tells you
    whether it is finished.

    PLACEHOLDERS

    {0}, {1} ... are filled by Format-BridgeText through [string]::Format, so
    the two languages may put them in different places - which Arabic and
    English routinely need. A translation that drops a placeholder the Arabic
    uses is a silent hole, so Test-BridgeTextCatalogue reports it.
#>

Set-StrictMode -Version Latest

# Every language the bridge can be set to. Adding a third means adding its
# code here and a column in the catalogue; nothing else reads a hard-coded
# pair of names.
$script:BridgeLanguages = @('ar', 'en')
$script:BridgeDefaultLanguage = 'ar'

function Test-BridgeLanguage {
    param([string]$Language = '')
    return ($script:BridgeLanguages -contains ([string]$Language).ToLowerInvariant())
}

function Get-BridgeLanguages {
    return @($script:BridgeLanguages)
}

function Get-BridgeDefaultLanguage {
    return $script:BridgeDefaultLanguage
}

function New-BridgeTextCatalogue {
    <#
        The catalogue itself: key -> @{ ar = '...'; en = '...' }.

        Built by a function rather than held as a module variable so a test can
        take a fresh copy without the module's state leaking between cases.
    #>
    $catalogue = [ordered]@{}

    # --- The language control itself -----------------------------------
    $catalogue['lang.button'] = @{ ar = '🌐 English'; en = '🌐 العربية' }
    $catalogue['lang.changed'] = @{ ar = '🌐 لغة الجسر الآن: العربية'; en = '🌐 Bridge language is now: English' }
    $catalogue['lang.setting.label'] = @{ ar = 'لغة الجسر'; en = 'Bridge language' }
    $catalogue['lang.setting.description'] = @{
        ar = 'لغة كل شاشات البوت وأزراره ورسائله. التغيير يسري فورًا على الجميع.'
        en = 'The language of every bot screen, button and message. Applies to everyone immediately.'
    }

    # --- Words that recur on many screens ------------------------------
    $catalogue['common.cancel'] = @{ ar = '❌ إلغاء'; en = '❌ Cancel' }
    $catalogue['common.back'] = @{ ar = '↩️ رجوع'; en = '↩️ Back' }
    $catalogue['common.home'] = @{ ar = '🏠 القائمة'; en = '🏠 Menu' }
    $catalogue['common.previous'] = @{ ar = '⬅️ السابق'; en = '⬅️ Previous' }
    $catalogue['common.next'] = @{ ar = 'التالي ➡️'; en = 'Next ➡️' }
    $catalogue['common.yes'] = @{ ar = 'نعم'; en = 'Yes' }
    $catalogue['common.no'] = @{ ar = 'لا'; en = 'No' }
    $catalogue['common.layer'] = @{ ar = 'طبقة {0}'; en = 'Layer {0}' }
    $catalogue['common.seconds'] = @{ ar = '{0} ثانية'; en = '{0}s' }
    $catalogue['common.notAllowed'] = @{ ar = '⛔ غير مسموح.'; en = '⛔ Not allowed.' }

    # --- The eleven settings doors --------------------------------------
    $catalogue['settingCategory.security.label'] = @{ ar = 'الأمان والصلاحيات'; en = 'Security and permissions' }
    $catalogue['settingCategory.onair.label'] = @{ ar = 'التشغيل على الهواء'; en = 'On air' }
    $catalogue['settingCategory.templates.label'] = @{ ar = 'القوالب والطبقات'; en = 'Templates and layers' }
    $catalogue['settingCategory.news.label'] = @{ ar = 'شريط الأخبار'; en = 'News ticker' }
    $catalogue['settingCategory.urgent.label'] = @{ ar = 'جدول العواجل'; en = 'The urgent board' }
    $catalogue['settingCategory.boards.label'] = @{ ar = 'محتوى البرامج'; en = 'Programme content' }
    $catalogue['settingCategory.schedule.label'] = @{ ar = 'الجدولة'; en = 'Scheduling' }
    $catalogue['settingCategory.monitoring.label'] = @{ ar = 'المراقبة والتنبيهات'; en = 'Monitoring and alerts' }
    $catalogue['settingCategory.storage.label'] = @{ ar = 'الملفات والاحتفاظ'; en = 'Files and retention' }
    $catalogue['settingCategory.notifications.label'] = @{ ar = 'الإشعارات والتنبيهات'; en = 'Notifications' }
    $catalogue['settingCategory.advanced.label'] = @{ ar = 'خيارات متقدمة'; en = 'Advanced' }
    $catalogue['settingCategory.security.summary'] = @{ ar = 'من يستطيع التحكم بالهواء، وكيف يُتحقق منه، وأي أبواب إدارية مفتوحة.'; en = 'Who may control the air, how they are verified, and which administrative doors are open.' }
    $catalogue['settingCategory.onair.summary'] = @{ ar = 'ما يظهر ويختفي على الشاشة: أزرار العرض والإخفاء والطوارئ، وكيف يتعامل الجسر مع Cinegy.'; en = 'What appears and disappears on screen: the show, hide and emergency buttons, and how the bridge deals with Cinegy.' }
    $catalogue['settingCategory.templates.summary'] = @{ ar = 'أي قالب متاح، وعلى أي طبقة، وبأي اسم يراه المشغّل.'; en = 'Which template is available, on which layer, and under what name the operator sees it.' }
    $catalogue['settingCategory.news.summary'] = @{ ar = 'الشريط وملفه وحدوده، والربط مع Google Sheets، وما يُسمح به للمشغّل.'; en = 'The ticker, its file and limits, the Google Sheets link, and what an operator is allowed to do with it.' }
    $catalogue['settingCategory.urgent.summary'] = @{ ar = 'الجدول الذي يتقدّم وحده: توقيته وتكراره ونمطه وحدود نصّه، والفاصل بين خبر وآخر.'; en = 'The board that advances by itself: its timing, repeats, mode and text limits, and the gap between stories.' }
    $catalogue['settingCategory.boards.summary'] = @{ ar = 'جداول النصوص المجهَّزة لقوالب البرامج: كم جدولًا، وكم صفًّا في الجدول الواحد.'; en = 'The prepared text tables for programme templates: how many boards, and how many rows in each.' }
    $catalogue['settingCategory.schedule.summary'] = @{ ar = 'الأحداث المؤجلة: متى تُنفَّذ، ومتى يُنبَّه على تعارضها، وماذا يجري إن فشلت.'; en = 'Deferred events: when they run, when a clash is flagged, and what happens if one fails.' }
    $catalogue['settingCategory.monitoring.summary'] = @{ ar = 'ما يراقبه الجسر بنفسه ومتى يوقظ المشرف: المخرج، صحة Cinegy، القوالب المنسية.'; en = 'What the bridge watches by itself and when it wakes an administrator: the output, Cinegy health, forgotten templates.' }
    $catalogue['settingCategory.storage.summary'] = @{ ar = 'كم يُحتفظ بالسجلات واللقطات والنسخ، ومتى يُنبَّه على امتلاء القرص.'; en = 'How long logs, snapshots and backups are kept, and when a full disk is flagged.' }
    $catalogue['settingCategory.notifications.summary'] = @{ ar = 'ما الذي يوقظك ومتى: تنبيهات الهواء والصحة والجدولة، وساعات الهدوء، والملخصات الدورية.'; en = 'What wakes you and when: air, health and schedule alerts, quiet hours, and the periodic digests.' }
    $catalogue['settingCategory.advanced.summary'] = @{ ar = 'تفاصيل التشخيص والسلوك الداخلي؛ لا يحتاجها التشغيل اليومي.'; en = 'Diagnostic detail and internal behaviour; daily operation does not need these.' }

    # --- The main menu --------------------------------------------------
    # The live rows first, because this menu is what an operator opens when a
    # wrong graphic is on air and every row above the fix is one to scroll past.
    $catalogue['menu.hideLive'] = @{ ar = '🔴 إخفاء {0} · {1}'; en = '🔴 Hide {0} · {1}' }
    $catalogue['menu.hideLive.copy'] = @{ ar = '🔴 إخفاء {0} · {1} — {2}'; en = '🔴 Hide {0} · {1} — {2}' }
    $catalogue['menu.timerExtend'] = @{ ar = '⏱ +30ث ({0} ث)'; en = '⏱ +30s ({0}s)' }
    $catalogue['menu.timer'] = @{ ar = '⏱ مؤقت'; en = '⏱ Timer' }
    $catalogue['menu.reshow'] = @{ ar = '↩️ إعادة عرض {0}'; en = '↩️ Show {0} again' }
    $catalogue['menu.hideAll'] = @{ ar = '🚨 إخفاء الكل'; en = '🚨 Hide everything' }
    $catalogue['menu.snapshotNow'] = @{ ar = '📷 لقطة الآن'; en = '📷 Grab a frame' }
    $catalogue['menu.copyStatus'] = @{ ar = '📋 نسخ الحالة'; en = '📋 Copy status' }
    $catalogue['menu.hideMojaz'] = @{ ar = '⏹ إخفاء الموجز'; en = '⏹ Stop the bulletin' }
    $catalogue['menu.stopUrgent'] = @{ ar = '⏹ إيقاف العواجل'; en = '⏹ Stop the urgent board' }
    $catalogue['menu.rollback'] = @{ ar = '↩️ تراجع طبقة {0} ({1} ث)'; en = '↩️ Undo layer {0} ({1}s)' }
    $catalogue['menu.templates'] = @{ ar = '📋 القوالب'; en = '📋 Templates' }
    $catalogue['menu.layers'] = @{ ar = '🎚 الطبقات {0}'; en = '🎚 Layers {0}' }
    $catalogue['menu.status'] = @{ ar = 'ℹ️ الحالة'; en = 'ℹ️ Status' }
    $catalogue['menu.fullStatus'] = @{ ar = '📊 الحالة الكاملة'; en = '📊 Full status' }
    $catalogue['menu.material'] = @{ ar = '🎞 جدول المواد'; en = '🎞 Material schedule' }
    $catalogue['menu.handover'] = @{ ar = '🤝 تسليم'; en = '🤝 Handover' }
    $catalogue['menu.favourite'] = @{ ar = '⭐ {0}'; en = '⭐ {0}' }
    $catalogue['menu.favourites'] = @{ ar = '⭐ إدارة المفضلة'; en = '⭐ Manage favourites' }
    $catalogue['menu.hideLayer'] = @{ ar = '🙈 اخفاء طبقة'; en = '🙈 Hide a layer' }
    $catalogue['menu.exitScene'] = @{ ar = '🚪 خروج من المشهد'; en = '🚪 Exit the scene' }
    $catalogue['menu.repeatEdit'] = @{ ar = '🔁 تكرار مع تعديل'; en = '🔁 Repeat with edits' }
    $catalogue['menu.updateText'] = @{ ar = '✏️ تحديث نص'; en = '✏️ Update text' }
    $catalogue['menu.timedShow'] = @{ ar = '⏱ عرض مؤقّت'; en = '⏱ Timed show' }
    $catalogue['menu.schedule'] = @{ ar = '📅 الجدولة'; en = '📅 Scheduling' }
    $catalogue['menu.reports'] = @{ ar = '📊 تقارير'; en = '📊 Reports' }
    $catalogue['menu.myOps'] = @{ ar = '🧾 عملياتي'; en = '🧾 My operations' }
    $catalogue['menu.digest'] = @{ ar = '🕘 ماذا فاتني'; en = '🕘 What did I miss' }
    $catalogue['menu.news'] = @{ ar = '📰 شريط الأخبار'; en = '📰 News ticker' }
    $catalogue['menu.mojaz'] = @{ ar = '📑 إدارة الموجز'; en = '📑 The bulletin' }
    $catalogue['menu.urgent'] = @{ ar = '🚨 إدارة العواجل'; en = '🚨 The urgent board' }
    $catalogue['menu.boards'] = @{ ar = '🗂 محتوى البرامج'; en = '🗂 Programme content' }
    $catalogue['menu.snapshot'] = @{ ar = '📸 صورة من البث'; en = '📸 Frame from air' }
    $catalogue['menu.help'] = @{ ar = '❓ مساعدة'; en = '❓ Help' }
    $catalogue['menu.whatsNew'] = @{ ar = '🆕 ما الجديد'; en = '🆕 What''s new' }
    $catalogue['menu.pending'] = @{ ar = '👤 طلبات الوصول'; en = '👤 Access requests' }
    $catalogue['menu.pending.count'] = @{ ar = '👤 طلبات الوصول ({0})'; en = '👤 Access requests ({0})' }
    $catalogue['menu.settings'] = @{ ar = '⚙️ الإعدادات'; en = '⚙️ Settings' }
    $catalogue['menu.adminTools'] = @{ ar = '🗂 أدوات الإدارة'; en = '🗂 Admin tools' }

    # --- The settings home screen ---------------------------------------
    $catalogue['settings.title'] = @{ ar = '⚙️ الإعدادات'; en = '⚙️ Settings' }
    $catalogue['settings.intro'] = @{
        ar = 'اختر قسمًا. تظهر الخيارات الشائعة أولًا، وتبقى الإعدادات التقنية في «خيارات متقدمة».'
        en = 'Choose a section. The common choices come first; the technical ones stay in Advanced.'
    }
    $catalogue['settings.search'] = @{ ar = '🔎 بحث'; en = '🔎 Search' }
    $catalogue['settings.modifiedOnly'] = @{ ar = '📝 المعدّل فقط'; en = '📝 Changed only' }
    $catalogue['settings.simple'] = @{ ar = '🧭 مبسّط'; en = '🧭 Simple' }
    $catalogue['settings.advanced'] = @{ ar = '🛠 متقدم'; en = '🛠 Advanced' }
    $catalogue['settings.hideAllScope'] = @{ ar = '🚨 طبقات إخفاء الكل: {0}'; en = '🚨 Hide-all layers: {0}' }
    $catalogue['settings.hideAllScope.all'] = @{ ar = 'كل الطبقات المعروفة'; en = 'every known layer' }
    $catalogue['settings.hideAllScope.some'] = @{ ar = 'طبقات: {0}'; en = 'layers: {0}' }
    $catalogue['settings.hideAllScope.none'] = @{ ar = 'لا توجد طبقات محددة'; en = 'none selected' }
    $catalogue['settings.layerNames'] = @{ ar = '🏷️ أسماء الطبقات'; en = '🏷️ Layer names' }
    $catalogue['settings.backups'] = @{ ar = '🗄 نسخ الإعدادات'; en = '🗄 Settings backups' }
    $catalogue['settings.reset'] = @{ ar = '♻️ استعادة الافتراضي'; en = '♻️ Restore defaults' }

    # --- Emergency hide-all --------------------------------------------
    $catalogue['hideAll.none'] = @{
        ar = '⚠️ لا توجد طبقات محددة لإخفاء الكل. يضبطها المشرف من الإعدادات.'
        en = '⚠️ No layers are selected for hide-all. An administrator sets them in Settings.'
    }
    $catalogue['hideAll.hidden'] = @{ ar = '🚨 تم إخفاء الطبقات: {0}'; en = '🚨 Layers hidden: {0}' }
    $catalogue['hideAll.nothing'] = @{ ar = '🚨 لم تُخفَ أي طبقة.'; en = '🚨 No layer was hidden.' }
    $catalogue['hideAll.failed'] = @{ ar = '❌ فشلت: {0}'; en = '❌ Failed: {0}' }
    $catalogue['hideAll.blocked'] = @{ ar = '⛔ الطبقة {0}: {1}'; en = '⛔ Layer {0}: {1}' }

    # --- Per-layer and per-template protection --------------------------
    $catalogue['access.ownerOnly'] = @{ ar = '{0} لمالك الجسر وحده.'; en = '{0} is for the bridge owner only.' }
    $catalogue['access.adminOnly'] = @{ ar = '{0} للمشرفين وحدهم.'; en = '{0} is for administrators only.' }
    $catalogue['access.template'] = @{ ar = "القالب '{0}'"; en = "Template '{0}'" }
    $catalogue['access.layer'] = @{ ar = 'الطبقة {0}'; en = 'Layer {0}' }

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

    # --- Every setting label, resolved through TF at read time ----------
    # The Arabic here is the same text $script:SettingNavigationLabels has
    # shipped all along; holding both together is what lets the catalogue
    # test see a label that has gained an English half and lost its Arabic.
    $catalogue['setting.EnableSnapshot.label'] = @{ ar = 'التقاط لقطات البث'; en = 'Output snapshots' }
    $catalogue['setting.EnableLiveRelay.label'] = @{ ar = 'ترحيل البث المباشر'; en = 'Live relay' }
    $catalogue['setting.EnableTimedShow.label'] = @{ ar = 'العرض المؤقت'; en = 'Timed show' }
    $catalogue['setting.EnableHideAll.label'] = @{ ar = 'تفعيل إخفاء الكل'; en = 'Hide-all button' }
    $catalogue['setting.HideAllLayers.label'] = @{ ar = 'طبقات إخفاء الكل'; en = 'Hide-all layers' }
    $catalogue['setting.ReservedLayers.label'] = @{ ar = 'الطبقات المحجوزة'; en = 'Reserved layers' }
    $catalogue['setting.AdminOnlyTemplateKeys.label'] = @{ ar = 'قوالب للمشرفين'; en = 'Administrator-only templates' }
    $catalogue['setting.OwnerOnlyTemplateKeys.label'] = @{ ar = 'قوالب للمالك'; en = 'Owner-only templates' }
    $catalogue['setting.AdminOnlyLayers.label'] = @{ ar = 'طبقات للمشرفين'; en = 'Administrator-only layers' }
    $catalogue['setting.OwnerOnlyLayers.label'] = @{ ar = 'طبقات للمالك'; en = 'Owner-only layers' }
    $catalogue['setting.LayersScreenAccess.label'] = @{ ar = 'من يرى زر الطبقات'; en = 'Who sees the layers button' }
    $catalogue['setting.DisabledTemplateKeys.label'] = @{ ar = 'القوالب المعطّلة'; en = 'Disabled templates' }
    $catalogue['setting.SensitiveTemplateKeys.label'] = @{ ar = 'القوالب الحساسة'; en = 'Sensitive templates' }
    $catalogue['setting.TemplateMaxAirSeconds.label'] = @{ ar = 'أقصى مدة لكل قالب'; en = 'Maximum air time per template' }
    $catalogue['setting.TemplateAirExtensionEnabled.label'] = @{ ar = 'تمديد واحد للمشغّل'; en = 'One operator extension' }
    $catalogue['setting.TemplateAirExtensionResponseSeconds.label'] = @{ ar = 'مهلة الرد على التمديد'; en = 'Extension reply window' }
    $catalogue['setting.TemplateAirExtensionMaxSeconds.label'] = @{ ar = 'أقصى مدة للتمديد'; en = 'Maximum extension' }
    $catalogue['setting.LayerNames.label'] = @{ ar = 'أسماء الطبقات'; en = 'Layer names' }
    $catalogue['setting.EnableFavorites.label'] = @{ ar = 'المفضلة'; en = 'Favourites' }
    $catalogue['setting.MaintenanceMode.label'] = @{ ar = 'وضع الصيانة'; en = 'Maintenance mode' }
    $catalogue['setting.EnablePersistentMenuButton.label'] = @{ ar = 'زر القائمة الثابت'; en = 'Persistent menu button' }
    $catalogue['setting.EnableNewsTickerManagement.label'] = @{ ar = 'إدارة شريط الأخبار'; en = 'News ticker management' }
    $catalogue['setting.NewsFilePath.label'] = @{ ar = 'ملف الأخبار'; en = 'News file' }
    $catalogue['setting.NewsItemSeparator.label'] = @{ ar = 'فاصل الأخبار'; en = 'News separator' }
    $catalogue['setting.NewsSheetCsvUrl.label'] = @{ ar = 'رابط Google Sheets (CSV)'; en = 'Google Sheets link (CSV)' }
    $catalogue['setting.NewsSheetSyncMode.label'] = @{ ar = 'وضع مزامنة الشيت'; en = 'Sheet sync mode' }
    $catalogue['setting.NewsSheetSyncMinutes.label'] = @{ ar = 'كل كم دقيقة تُزامن الشيت'; en = 'Sheet sync interval' }
    $catalogue['setting.NewsSheetTimeoutSeconds.label'] = @{ ar = 'مهلة تنزيل الشيت'; en = 'Sheet download timeout' }
    $catalogue['setting.NewsSheetNotifyScope.label'] = @{ ar = 'من يُنبَّه بعد مزامنة الشيت'; en = 'Who is told after a sheet sync' }
    $catalogue['setting.NewsPublishNotifyScope.label'] = @{ ar = 'من يُنبَّه بعد النشر اليدوي'; en = 'Who is told after a manual publish' }
    $catalogue['setting.NewsSheetFailureAlertAfter.label'] = @{ ar = 'تنبيه فشل مزامنة الشيت'; en = 'Sheet sync failure alert' }
    $catalogue['setting.AllowOperatorsSheetPull.label'] = @{ ar = 'سماح المشغّلين بسحب الشيت'; en = 'Operators may pull the sheet' }
    $catalogue['setting.NewsMaxItemLength.label'] = @{ ar = 'الحد الأقصى لطول الخبر'; en = 'Maximum headline length' }
    $catalogue['setting.NewsMaxItems.label'] = @{ ar = 'الحد الأقصى لعدد الأخبار'; en = 'Maximum number of headlines' }
    $catalogue['setting.NewsImportMaxBytes.label'] = @{ ar = 'حد استيراد الأخبار'; en = 'News import size limit' }
    $catalogue['setting.NewsBackupKeepFiles.label'] = @{ ar = 'نسخ الأخبار المحفوظة'; en = 'News backups kept' }
    $catalogue['setting.NewsLockRequestMinutes.label'] = @{ ar = 'مهلة قفل مسودة الأخبار'; en = 'News draft lock timeout' }
    $catalogue['setting.NewsLockGrantHoldSeconds.label'] = @{ ar = 'حجز قفل الأخبار بعد التسليم'; en = 'Lock hold after handover' }
    $catalogue['setting.AllowOperatorsDeleteNews.label'] = @{ ar = 'السماح للمشغل بحذف الأخبار'; en = 'Operators may delete headlines' }
    $catalogue['setting.AllowOperatorsRestoreNews.label'] = @{ ar = 'السماح للمشغل باستعادة الأخبار'; en = 'Operators may restore headlines' }
    $catalogue['setting.AllowOperatorsClearAllNews.label'] = @{ ar = 'السماح للمشغل بمسح كل الأخبار'; en = 'Operators may clear all headlines' }
    $catalogue['setting.DropPendingUpdatesOnStart.label'] = @{ ar = 'إسقاط التحديثات عند البدء'; en = 'Drop pending updates at start' }
    $catalogue['setting.LogAirXml.label'] = @{ ar = 'تسجيل XML الخاص بـ Cinegy'; en = 'Log Cinegy XML' }
    $catalogue['setting.ReshowClearsLayer.label'] = @{ ar = 'مسح الطبقة قبل إعادة العرض'; en = 'Clear the layer before re-showing' }
    $catalogue['setting.AirVariableType.label'] = @{ ar = 'نوع متغيرات Cinegy'; en = 'Cinegy variable type' }
    $catalogue['setting.SetValuesAfterShow.label'] = @{ ar = 'تحديث القيم بعد العرض'; en = 'Set values after show' }
    $catalogue['setting.AutoHidePresetSeconds.label'] = @{ ar = 'مدد الإخفاء الجاهزة'; en = 'Auto-hide presets' }
    $catalogue['setting.RelayAutoRestart.label'] = @{ ar = 'إعادة تشغيل الترحيل تلقائيًا'; en = 'Restart the relay automatically' }
    $catalogue['setting.CinegyStateStaleSeconds.label'] = @{ ar = 'حد قِدم حالة Cinegy'; en = 'Cinegy state staleness limit' }
    $catalogue['setting.ScheduleConflictWindowMinutes.label'] = @{ ar = 'نافذة تعارض الجدولة'; en = 'Schedule clash window' }
    $catalogue['setting.SchedulePaused.label'] = @{ ar = 'إيقاف الجدولة مؤقتًا'; en = 'Pause scheduling' }
    $catalogue['setting.ScheduleMaxRetries.label'] = @{ ar = 'أقصى محاولات الجدولة'; en = 'Maximum schedule retries' }
    $catalogue['setting.ScheduleRetryDelaySeconds.label'] = @{ ar = 'تأخير إعادة محاولة الجدولة'; en = 'Schedule retry delay' }
    $catalogue['setting.ScheduleRetryBackoffFactor.label'] = @{ ar = 'معامل تراجع إعادة المحاولة'; en = 'Retry backoff factor' }
    $catalogue['setting.ScheduleRetryMaxDelaySeconds.label'] = @{ ar = 'أقصى تأخير لإعادة المحاولة'; en = 'Maximum retry delay' }
    $catalogue['setting.HeartbeatEnabled.label'] = @{ ar = 'نبض الجسر'; en = 'Bridge heartbeat' }
    $catalogue['setting.NotifyAdminsOnRelayFailure.label'] = @{ ar = 'إشعار المشرفين بفشل الترحيل'; en = 'Tell admins about relay failures' }
    $catalogue['setting.NotifyAdminsOnExternalChange.label'] = @{ ar = 'إشعار المشرفين بالتغيير الخارجي'; en = 'Tell admins about external changes' }
    $catalogue['setting.NotifyAdminsOnCinegyHealth.label'] = @{ ar = 'إشعار المشرفين بصحة Cinegy'; en = 'Tell admins about Cinegy health' }
    $catalogue['setting.SceneMode.label'] = @{ ar = 'وضع المشاهد'; en = 'Scene mode' }
    $catalogue['setting.RequireUserLevelAuth.label'] = @{ ar = 'التحقق من هوية المستخدم'; en = 'Verify the user identity' }
    $catalogue['setting.EnableSelfServiceRequests.label'] = @{ ar = 'طلبات الوصول الذاتية'; en = 'Self-service access requests' }
    $catalogue['setting.EnableAnnouncements.label'] = @{ ar = 'تنويهات المشرفين'; en = 'Administrator announcements' }
    $catalogue['setting.AnnouncementMaxLength.label'] = @{ ar = 'طول التنويه'; en = 'Announcement length' }
    $catalogue['setting.AnnouncementDefaultExpiryHours.label'] = @{ ar = 'مدة التنويه الافتراضية'; en = 'Default announcement lifetime' }
    $catalogue['setting.NotifyAdminsOnAccessRequest.label'] = @{ ar = 'إشعار طلبات الوصول'; en = 'Access request alerts' }
    $catalogue['setting.NotifyAdminsOnBlockedChat.label'] = @{ ar = 'إشعار الحظر التلقائي'; en = 'Automatic block alerts' }
    $catalogue['setting.NotifyAdminsOnMissingGraphic.label'] = @{ ar = 'تنبيه غياب قالب دائم'; en = 'Missing permanent graphic alert' }
    $catalogue['setting.MissingGraphicConfirmChecks.label'] = @{ ar = 'فحوص تأكيد الغياب'; en = 'Checks confirming it is missing' }
    $catalogue['setting.BlockRejectedRequesters.label'] = @{ ar = 'حظر من رُفض طلبه'; en = 'Block a rejected requester' }
    $catalogue['setting.JoinSecret.label'] = @{ ar = 'رمز الانضمام'; en = 'Join code' }
    $catalogue['setting.JoinSecretMaxAttempts.label'] = @{ ar = 'محاولات رمز الانضمام'; en = 'Join code attempts' }
    $catalogue['setting.MaxAccessRequestsPerDay.label'] = @{ ar = 'طلبات الوصول يوميًا'; en = 'Access requests per day' }
    $catalogue['setting.DormantUserDays.label'] = @{ ar = 'أيام خمول المستخدم'; en = 'Days before a user is dormant' }
    $catalogue['setting.AutoDisableDormantUsers.label'] = @{ ar = 'تعطيل الخامل تلقائيًا'; en = 'Disable dormant users automatically' }
    $catalogue['setting.LeaveUnknownGroups.label'] = @{ ar = 'مغادرة المجموعات المجهولة'; en = 'Leave unknown groups' }
    $catalogue['setting.EnableRawCommand.label'] = @{ ar = 'الأوامر الخام للمشرف'; en = 'Raw administrator commands' }
    $catalogue['setting.EnableFullTemplateManagement.label'] = @{ ar = 'الإدارة الكاملة للقوالب'; en = 'Full template management' }
    $catalogue['setting.UserActivityRecentMinutes.label'] = @{ ar = 'نافذة النشاط الحديث للمستخدم'; en = 'Recent-activity window' }
    $catalogue['setting.TemplateReminderFollowUpMinutes.label'] = @{ ar = 'مهلة متابعة تنبيه القالب'; en = 'Template reminder follow-up' }
    $catalogue['setting.EnableDpapiSecrets.label'] = @{ ar = 'حماية الأسرار عبر Windows'; en = 'Protect secrets with Windows DPAPI' }
    $catalogue['setting.MojazMultiDesign.label'] = @{ ar = 'موجز متعدد التصاميم'; en = 'Multi-design bulletin' }
    $catalogue['setting.MojazAnchorToAirClock.label'] = @{ ar = 'ضبط الزمن من Cinegy'; en = 'Take timing from Cinegy' }
    $catalogue['setting.MojazRowFrames.label'] = @{ ar = 'إطارات صف الموجز'; en = 'Bulletin row frames' }
    $catalogue['setting.MojazImageKeepHours.label'] = @{ ar = 'الاحتفاظ بصور الموجز'; en = 'Keep bulletin images' }
    $catalogue['setting.BroadcastFps.label'] = @{ ar = 'معدل إطارات القناة'; en = 'Channel frame rate' }
    $catalogue['setting.MojazIntroExtraFrames.label'] = @{ ar = 'إطارات الصف الأول'; en = 'First row frames' }
    $catalogue['setting.MojazLastRowFrames.label'] = @{ ar = 'إطارات الصف الأخير'; en = 'Last row frames' }
    $catalogue['setting.MojazSyncOffsetMs.label'] = @{ ar = 'لحظة الكتابة داخل الظهور'; en = 'Write moment inside the reveal' }
    $catalogue['setting.MojazSyncLeadMs.label'] = @{ ar = 'تعويض زمن الشبكة'; en = 'Network latency compensation' }
    $catalogue['setting.MojazNotifyOnFinish.label'] = @{ ar = 'إشعار انتهاء الموجز'; en = 'Tell me when the bulletin ends' }
    $catalogue['setting.MojazScheduleNoticeSeconds.label'] = @{ ar = 'تنبيه قبل الموعد'; en = 'Warning before a scheduled run' }
    $catalogue['setting.MojazHidesTicker.label'] = @{ ar = 'إخفاء الشريط أثناء الموجز'; en = 'Hide the ticker during a bulletin' }
    $catalogue['setting.EnableUrgentBoard.label'] = @{ ar = 'إدارة العواجل'; en = 'Urgent board' }
    $catalogue['setting.UrgentBoardIntervalSeconds.label'] = @{ ar = 'فاصل العواجل'; en = 'Urgent interval' }
    $catalogue['setting.UrgentBoardRepeats.label'] = @{ ar = 'تكرار العواجل'; en = 'Urgent repeats' }
    $catalogue['setting.UrgentBoardMode.label'] = @{ ar = 'نمط عرض العواجل'; en = 'Urgent display mode' }
    $catalogue['setting.UrgentBoardRepeatMode.label'] = @{ ar = 'ترتيب التكرار'; en = 'Repeat order' }
    $catalogue['setting.UrgentBoardTotalSeconds.label'] = @{ ar = 'المدة الكلية للعواجل'; en = 'Total urgent run time' }
    $catalogue['setting.UrgentBoardMaxItems.label'] = @{ ar = 'حدّ عدد العواجل'; en = 'Maximum urgent items' }
    $catalogue['setting.UrgentMinIntervalSeconds.label'] = @{ ar = 'أقصر فاصل للعواجل'; en = 'Shortest urgent interval' }
    $catalogue['setting.UrgentExitGapSeconds.label'] = @{ ar = 'الفاصل بين الأخبار'; en = 'Gap between stories' }
    $catalogue['setting.Language.label'] = @{ ar = 'لغة الجسر'; en = 'Bridge language' }
    $catalogue['setting.EnableContentBoards.label'] = @{ ar = 'محتوى البرامج'; en = 'Programme content boards' }
    $catalogue['setting.MaxContentBoards.label'] = @{ ar = 'أقصى عدد الجداول'; en = 'Maximum boards' }
    $catalogue['setting.BoardMaxItems.label'] = @{ ar = 'أقصى صفوف الجدول'; en = 'Maximum rows per board' }
    $catalogue['setting.UrgentSyncLeadMs.label'] = @{ ar = 'تعويض زمن الشبكة للعواجل'; en = 'Urgent network latency compensation' }
    $catalogue['setting.UrgentBoardNotifyOnFinish.label'] = @{ ar = 'إشعار انتهاء العواجل'; en = 'Tell me when the urgent run ends' }
    $catalogue['setting.UrgentBoardMaxTextLength.label'] = @{ ar = 'أطول نصّ عاجل'; en = 'Longest urgent text' }
    $catalogue['setting.MojazImageWidth.label'] = @{ ar = 'عرض صورة الصف'; en = 'Row image width' }
    $catalogue['setting.MojazImageHeight.label'] = @{ ar = 'ارتفاع صورة الصف'; en = 'Row image height' }
    $catalogue['setting.AirCommandTimeoutSeconds.label'] = @{ ar = 'مهلة أمر Cinegy'; en = 'Cinegy command timeout' }
    $catalogue['setting.AllowRemoteRestart.label'] = @{ ar = 'إعادة التشغيل من البوت'; en = 'Restart from the bot' }
    $catalogue['setting.AuditArchiveKeepFiles.label'] = @{ ar = 'أرشيفات التدقيق المحفوظة'; en = 'Audit archives kept' }
    $catalogue['setting.AuditMaxSizeMB.label'] = @{ ar = 'حجم سجل التدقيق'; en = 'Audit log size' }
    $catalogue['setting.AuditTemplateValues.label'] = @{ ar = 'تسجيل نص القالب'; en = 'Record template text' }
    $catalogue['setting.AuditTemplateValuesMaxChars.label'] = @{ ar = 'طول النص المسجَّل'; en = 'Recorded text length' }
    $catalogue['setting.AuditTrailSize.label'] = @{ ar = 'حجم سجل العمليات'; en = 'Operation log size' }
    $catalogue['setting.AutoHideDefaultSeconds.label'] = @{ ar = 'مدة الإخفاء الافتراضية'; en = 'Default auto-hide time' }
    $catalogue['setting.BackupStorageWarningMB.label'] = @{ ar = 'تنبيه حجم النسخ'; en = 'Backup size warning' }
    $catalogue['setting.ButtonTextMaxLength.label'] = @{ ar = 'طول نص الأزرار'; en = 'Button text length' }
    $catalogue['setting.CinegyFrameLossTolerance.label'] = @{ ar = 'الإطارات المفقودة المسموحة'; en = 'Dropped frames allowed' }
    $catalogue['setting.CinegyFrameLossTolerancePercent.label'] = @{ ar = 'نسبة الإطارات المفقودة'; en = 'Dropped frame percentage' }
    $catalogue['setting.CinegyHealthCheckSeconds.label'] = @{ ar = 'فاصل فحص صحة Cinegy'; en = 'Cinegy health check interval' }
    $catalogue['setting.CinegyHealthConfirmChecks.label'] = @{ ar = 'فحوص تأكيد الحالة'; en = 'Checks confirming the state' }
    $catalogue['setting.CinegyMonitorTimeoutSeconds.label'] = @{ ar = 'مهلة فحص Cinegy'; en = 'Cinegy check timeout' }
    $catalogue['setting.CinegyReadErrorRateTolerance.label'] = @{ ar = 'نسبة أخطاء القراءة'; en = 'Read error rate allowed' }
    $catalogue['setting.CinegyStateBackoffMaxSeconds.label'] = @{ ar = 'أقصى تباعد عند التعذّر'; en = 'Maximum backoff when unreachable' }
    $catalogue['setting.CinegyStateCheckSeconds.label'] = @{ ar = 'فاصل فحص الطبقات'; en = 'Layer check interval' }
    $catalogue['setting.DiscoverExternalLayers.label'] = @{ ar = 'تبنّي الطبقات الخارجية'; en = 'Adopt external layers' }
    $catalogue['setting.TelegramPollMarginSeconds.label'] = @{ ar = 'مهلة الاستطلاع الإضافية'; en = 'Extra poll timeout' }
    $catalogue['setting.TelegramPollTimeoutTolerance.label'] = @{ ar = 'تأخر الاستطلاع المحتمل'; en = 'Tolerated poll delays' }
    $catalogue['setting.ConfigBackupKeepFiles.label'] = @{ ar = 'نسخ الإعدادات المحفوظة'; en = 'Settings backups kept' }
    $catalogue['setting.AskRequesterName.label'] = @{ ar = 'سؤال طالب الوصول عن اسمه'; en = 'Ask a requester for their name' }
    $catalogue['setting.ConfirmLayerRemoval.label'] = @{ ar = 'تأكيد قبل الإخفاء'; en = 'Confirm before hiding' }
    $catalogue['setting.ShowOnAirTextOnRemoval.label'] = @{ ar = 'عرض النص قبل الإخفاء'; en = 'Show the text before hiding' }
    $catalogue['setting.DiskFreeWarningGB.label'] = @{ ar = 'تنبيه مساحة القرص'; en = 'Free disk warning' }
    $catalogue['setting.EnableButtonStyles.label'] = @{ ar = 'تلوين الأزرار'; en = 'Colour the buttons' }
    $catalogue['setting.EnableSafeRollback.label'] = @{ ar = 'التراجع الآمن'; en = 'Safe rollback' }
    $catalogue['setting.EnableTextShortcuts.label'] = @{ ar = 'اختصارات الكتابة'; en = 'Typing shortcuts' }
    $catalogue['setting.FavoritesCount.label'] = @{ ar = 'عدد المفضلة المعروضة'; en = 'Favourites shown' }
    $catalogue['setting.HealthFailureAlertThreshold.label'] = @{ ar = 'حد تنبيه الفشل'; en = 'Failure alert threshold' }
    $catalogue['setting.HeartbeatHour.label'] = @{ ar = 'ساعة النبض اليومي'; en = 'Daily heartbeat hour' }
    $catalogue['setting.LogKeepFiles.label'] = @{ ar = 'ملفات السجل المحفوظة'; en = 'Log files kept' }
    $catalogue['setting.LogMaxSizeMB.label'] = @{ ar = 'حجم ملف السجل'; en = 'Log file size' }
    $catalogue['setting.ExecutionLogKeepRecords.label'] = @{ ar = 'سجلات التنفيذ المحفوظة'; en = 'Execution records kept' }
    $catalogue['setting.ScheduleHistoryKeepDays.label'] = @{ ar = 'تاريخ الجدولة المحفوظ'; en = 'Schedule history kept' }
    $catalogue['setting.AccessGuardKeepDays.label'] = @{ ar = 'مدة تذكّر المحظورين'; en = 'How long blocks are remembered' }
    $catalogue['setting.MaintenanceWindowEnd.label'] = @{ ar = 'نهاية نافذة الصيانة'; en = 'Maintenance window end' }
    $catalogue['setting.MaintenanceWindowStart.label'] = @{ ar = 'بداية نافذة الصيانة'; en = 'Maintenance window start' }
    $catalogue['setting.MaxFieldLength.label'] = @{ ar = 'طول نص الحقل'; en = 'Field text length' }
    $catalogue['setting.MaxPendingApprovals.label'] = @{ ar = 'طلبات الوصول المعلّقة'; en = 'Pending access requests' }
    $catalogue['setting.MissedEventsHours.label'] = @{ ar = 'مدة «ماذا فاتني»'; en = 'What-did-I-miss window' }
    $catalogue['setting.NewNewsItemAtTop.label'] = @{ ar = 'مكان الخبر الجديد'; en = 'Where a new headline goes' }
    $catalogue['setting.NewsDraftTimeoutMinutes.label'] = @{ ar = 'مهلة مسودة الأخبار'; en = 'News draft timeout' }
    $catalogue['setting.NewsListLabelLength.label'] = @{ ar = 'طول الخبر في القائمة'; en = 'Headline length in the list' }
    $catalogue['setting.NewsListLayout.label'] = @{ ar = 'شكل قائمة الأخبار'; en = 'News list layout' }
    $catalogue['setting.NewsListPaged.label'] = @{ ar = 'تقسيم القائمة لصفحات'; en = 'Page the list' }
    $catalogue['setting.NewsListPageSize.label'] = @{ ar = 'أخبار كل صفحة'; en = 'Headlines per page' }
    $catalogue['setting.NewsListStackedLabelLength.label'] = @{ ar = 'طول الخبر في سطره'; en = 'Headline length on its own line' }
    $catalogue['setting.NotifyOnScheduleOverwrite.label'] = @{ ar = 'تنبيه استبدال مشهد'; en = 'Warn when a scene is replaced' }
    $catalogue['setting.NotifyOperatorsOnBlackOutput.label'] = @{ ar = 'إشعار المشغّلين بالسواد'; en = 'Tell operators about black output' }
    $catalogue['setting.TemplateNotifyRules.label'] = @{ ar = 'إشعار العرض حسب القالب'; en = 'Show notices per template' }
    $catalogue['setting.OneHandMode.label'] = @{ ar = 'وضع اليد الواحدة'; en = 'One-hand mode' }
    $catalogue['setting.OutputBlackConfirmSeconds.label'] = @{ ar = 'انتظار اللقطة المؤكِّدة'; en = 'Wait for the confirming frame' }
    $catalogue['setting.OutputBlackLuminance.label'] = @{ ar = 'حد سطوع السواد'; en = 'Black luminance threshold' }
    $catalogue['setting.OutputMonitorFailureAlertThreshold.label'] = @{ ar = 'حد تنبيه فشل الالتقاط'; en = 'Capture failure alert threshold' }
    $catalogue['setting.OutputMonitorFlapAlertCount.label'] = @{ ar = 'حد تنبيه تذبذب المصدر'; en = 'Source flapping alert threshold' }
    $catalogue['setting.OutputMonitorMinutes.label'] = @{ ar = 'فاصل مراقبة المخرج'; en = 'Output monitoring interval' }
    $catalogue['setting.EnableTextChecks.label'] = @{ ar = 'التنبيهات الإملائية'; en = 'Spelling warnings' }
    $catalogue['setting.EnableMaterialSchedule.label'] = @{ ar = 'شاشة جدول المواد'; en = 'Material schedule screen' }
    $catalogue['setting.EnableShiftHandover.label'] = @{ ar = 'شاشة تسليم المناوبة'; en = 'Shift handover screen' }
    $catalogue['setting.NotifyAdminsOnMissingProxy.label'] = @{ ar = 'تنبيه المادة بلا نسخة محلية'; en = 'Alert on material with no local copy' }
    $catalogue['setting.RepeatAlertWindowHours.label'] = @{ ar = 'نافذة تكرار التنبيه'; en = 'Repeat alert window' }
    $catalogue['setting.AlertMaxPerCausePerHour.label'] = @{ ar = 'سقف تنبيهات السبب الواحد'; en = 'Alerts per cause per hour' }
    $catalogue['setting.MaterialProxyLeadMinutes.label'] = @{ ar = 'مهلة فحص النسخة المحلية'; en = 'Local copy check lead time' }
    $catalogue['setting.PendingApprovalExpiryHours.label'] = @{ ar = 'صلاحية طلب الوصول'; en = 'Access request lifetime' }
    $catalogue['setting.PendingStateTimeoutMinutes.label'] = @{ ar = 'مهلة الإدخال غير المكتمل'; en = 'Unfinished input timeout' }
    $catalogue['setting.PostShowDelayMs.label'] = @{ ar = 'تأخير النص بعد العرض'; en = 'Text delay after show' }
    $catalogue['setting.QuietHoursEnabled.label'] = @{ ar = 'فترة الهدوء'; en = 'Quiet hours' }
    $catalogue['setting.QuietHoursEnd.label'] = @{ ar = 'نهاية فترة الهدوء'; en = 'Quiet hours end' }
    $catalogue['setting.QuietHoursStart.label'] = @{ ar = 'بداية فترة الهدوء'; en = 'Quiet hours start' }
    $catalogue['setting.RecentValuesPerField.label'] = @{ ar = 'القيم الحديثة لكل حقل'; en = 'Recent values per field' }
    $catalogue['setting.RelayMaxRestarts.label'] = @{ ar = 'محاولات إعادة البث'; en = 'Relay restart attempts' }
    $catalogue['setting.RelayWatchdogSeconds.label'] = @{ ar = 'فاصل فحص البث'; en = 'Relay check interval' }
    $catalogue['setting.RepeatWarningCount.label'] = @{ ar = 'حد تنبيه التكرار'; en = 'Repeat warning threshold' }
    $catalogue['setting.RepeatWarningWindowMinutes.label'] = @{ ar = 'نافذة قياس التكرار'; en = 'Repeat measurement window' }
    $catalogue['setting.RespectCinegyItemDuration.label'] = @{ ar = 'احترام مدة Cinegy'; en = 'Respect the Cinegy duration' }
    $catalogue['setting.RollbackWindowSeconds.label'] = @{ ar = 'مدة التراجع الآمن'; en = 'Safe rollback window' }
    $catalogue['setting.RuntimeStorageWarningMB.label'] = @{ ar = 'تنبيه حجم ملفات التشغيل'; en = 'Runtime file size warning' }
    $catalogue['setting.SchedulePreNotifyMinutes.label'] = @{ ar = 'الإشعار المسبق للحدث'; en = 'Advance notice for an event' }
    $catalogue['setting.SensitiveTemplateAutoHideSeconds.label'] = @{ ar = 'إخفاء القالب الحساس'; en = 'Sensitive template auto-hide' }
    $catalogue['setting.ShowLayerLockBadge.label'] = @{ ar = 'شارة قفل الطبقة'; en = 'Layer lock badge' }
    $catalogue['setting.SnapshotCooldownSeconds.label'] = @{ ar = 'فاصل بين اللقطات'; en = 'Gap between snapshots' }
    $catalogue['setting.SnapshotRetentionMinutes.label'] = @{ ar = 'الاحتفاظ بصور البث'; en = 'Keep output stills' }
    $catalogue['setting.SnapshotTimeoutSeconds.label'] = @{ ar = 'مهلة التقاط الصورة'; en = 'Snapshot timeout' }
    $catalogue['setting.StaleOnAirAlertHours.label'] = @{ ar = 'تنبيه القالب المنسي'; en = 'Forgotten template alert' }
    $catalogue['setting.StartupStormThreshold.label'] = @{ ar = 'تنبيه عاصفة الإقلاع'; en = 'Startup storm threshold' }
    $catalogue['setting.TelegramRequestTimeoutSeconds.label'] = @{ ar = 'مهلة طلبات Telegram'; en = 'Telegram request timeout' }
    $catalogue['setting.TemplateBasePath.label'] = @{ ar = 'مجلد المشاهد'; en = 'Scenes folder' }
    $catalogue['setting.TemplateRegistryImportMaxTemplates.label'] = @{ ar = 'حد استيراد القوالب'; en = 'Template import limit' }
    $catalogue['setting.TemplateTestAutoHideSeconds.label'] = @{ ar = 'إخفاء اختبار القالب'; en = 'Template test auto-hide' }
    $catalogue['setting.TemplateTestLayer.label'] = @{ ar = 'طبقة تجربة القوالب'; en = 'Template test layer' }
    $catalogue['setting.UploadRetentionMinutes.label'] = @{ ar = 'الاحتفاظ بالملفات المرفوعة'; en = 'Keep uploaded files' }
    $catalogue['setting.UsageDigestDayOfWeek.label'] = @{ ar = 'يوم الملخص الأسبوعي'; en = 'Weekly digest day' }
    $catalogue['setting.UsageDigestEnabled.label'] = @{ ar = 'الملخص الأسبوعي'; en = 'Weekly digest' }
    $catalogue['setting.MaterialEndAlertMinutes.label'] = @{ ar = 'تنبيه نهاية المادة'; en = 'Material ending alert' }
    $catalogue['setting.EnableEngineHealth.label'] = @{ ar = 'صحة المحرك'; en = 'Engine health' }

    return $catalogue
}

$script:BridgeTextCatalogue = New-BridgeTextCatalogue
$script:BridgeTextMissing = [System.Collections.Generic.HashSet[string]]::new()

function Get-BridgeTextEntry {
    <# The raw pair for a key, or $null. Exposed so a test can read the
       catalogue without going through the fallback path. #>
    param([Parameter(Mandatory)][string]$Key)
    if ($script:BridgeTextCatalogue.Contains($Key)) { return $script:BridgeTextCatalogue[$Key] }
    return $null
}

function Get-BridgeTextKeys {
    return @($script:BridgeTextCatalogue.Keys)
}

function Format-BridgeText {
    <#
        [string]::Format with the arguments the caller actually passed.

        A format string whose placeholders outnumber the arguments throws, and
        a screen that throws while an operator is mid-edit is worse than one
        that reads awkwardly - so the unformatted template is returned instead
        and the fault is logged by the caller's own logger, not swallowed.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template, [object[]]$Arguments = @())
    if (@($Arguments).Count -eq 0) { return $Template }
    try { return [string]::Format([cultureinfo]::InvariantCulture, $Template, $Arguments) }
    catch { return $Template }
}

function Get-BridgeText {
    <#
        The text for a key in the requested language.

        An unknown key returns the key itself: it is visible, greppable, and
        cannot be mistaken for a sentence somebody wrote. A key that exists but
        has no translation in the requested language falls back to Arabic,
        because half a screen an operator can read beats a blank one.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$Language = '',
        [object[]]$Arguments = @(),
        [AllowEmptyString()][string]$Fallback = $null
    )
    $entry = Get-BridgeTextEntry -Key $Key
    if (-not $entry) {
        [void]$script:BridgeTextMissing.Add($Key)
        # -Fallback is for text that ALREADY exists in Arabic somewhere else:
        # the setting labels and descriptions built at load, which are several
        # hundred strings that can only be translated a few at a time. Without
        # it every untranslated one would render as its key; with it, the
        # screen keeps saying exactly what it said before this feature existed.
        #
        # Asked of the bound parameters, not of the value: [string]$Fallback
        # coerces an unpassed $null to '', so "$null -ne $Fallback" is true
        # even when no fallback was given - and every unknown key came back as
        # an empty string instead of as its own name.
        if ($PSBoundParameters.ContainsKey('Fallback')) { return (Format-BridgeText -Template $Fallback -Arguments $Arguments) }
        return $Key
    }
    $code = ([string]$Language).ToLowerInvariant()
    if (-not (Test-BridgeLanguage -Language $code)) { $code = $script:BridgeDefaultLanguage }
    $template = if ($entry.Contains($code) -and -not [string]::IsNullOrEmpty([string]$entry[$code])) {
        [string]$entry[$code]
    }
    else {
        [void]$script:BridgeTextMissing.Add("$Key`:$code")
        [string]$entry[$script:BridgeDefaultLanguage]
    }
    return (Format-BridgeText -Template $template -Arguments $Arguments)
}

function Get-BridgeTextMisses {
    <# Keys asked for and not found, so a diagnostic screen can report a gap
       the catalogue test cannot see - one reached only at runtime. #>
    return @($script:BridgeTextMissing)
}

function Clear-BridgeTextMisses {
    $script:BridgeTextMissing.Clear()
}

function Get-BridgeTextPlaceholders {
    <# The distinct {N} indices a template uses, sorted. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Template)
    $found = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($match in [regex]::Matches($Template, '\{(\d+)\}')) {
        [void]$found.Add([int]$match.Groups[1].Value)
    }
    return @($found)
}

function Test-BridgeTextCatalogue {
    <#
        What is wrong with the catalogue, as data.

        Three faults, each of which reaches an operator as a broken screen:
        a key with no entry for a language; a translation that drops a
        placeholder the other language fills (so a layer number or a count
        simply vanishes from the sentence); and an empty string, which renders
        as a blank line rather than as the missing text it is.
    #>
    param($Catalogue = $null)
    if (-not $Catalogue) { $Catalogue = $script:BridgeTextCatalogue }
    $problems = @()
    foreach ($key in @($Catalogue.Keys)) {
        $entry = $Catalogue[$key]
        foreach ($language in $script:BridgeLanguages) {
            if (-not $entry.Contains($language)) {
                $problems += [pscustomobject]@{ Key = $key; Language = $language; Problem = 'missing' }
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$entry[$language])) {
                $problems += [pscustomobject]@{ Key = $key; Language = $language; Problem = 'empty' }
            }
        }
        $reference = @(Get-BridgeTextPlaceholders -Template ([string]$entry[$script:BridgeDefaultLanguage]))
        foreach ($language in $script:BridgeLanguages) {
            if ($language -eq $script:BridgeDefaultLanguage -or -not $entry.Contains($language)) { continue }
            $theirs = @(Get-BridgeTextPlaceholders -Template ([string]$entry[$language]))
            if (($reference -join ',') -ne ($theirs -join ',')) {
                $problems += [pscustomobject]@{ Key = $key; Language = $language; Problem = 'placeholders' }
            }
        }
    }
    return @($problems)
}

Export-ModuleMember -Function Test-BridgeLanguage, Get-BridgeLanguages, Get-BridgeDefaultLanguage,
New-BridgeTextCatalogue, Get-BridgeTextEntry, Get-BridgeTextKeys, Format-BridgeText, Get-BridgeText,
Get-BridgeTextMisses, Clear-BridgeTextMisses, Get-BridgeTextPlaceholders, Test-BridgeTextCatalogue
