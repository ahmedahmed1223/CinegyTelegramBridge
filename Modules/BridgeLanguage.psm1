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
