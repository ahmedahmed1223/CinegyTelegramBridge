#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    The manual: the quick-start card, the chapters, and the screens that
    page through them.

    Split out of Bridge.ShowFlow.ps1, which had grown to 2733 lines by
    accumulating three things that are not the show flow: the release notes,
    the operator manual, and the audited air operation underneath every push.
    Nothing moved between scopes - dot-sourced parts share one.
#>

function Get-QuickStartText {
    <# The shortest path from "I was handed this bot" to "a graphic is on
       air". Deliberately not a feature list: a new operator on shift needs
       the six presses that work, and can find everything else in the index. #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $lines = @(
        '🚀 بداية سريعة'
        '━━━━━━━━━━━━━━'
        'أول قالب لك على الهواء في ست خطوات:'
        ''
        '1️⃣ اضغط 📋 القوالب.'
        '2️⃣ اختر القالب الذي تريده.'
        '3️⃣ اكتب نص كل حقل يطلبه، أو ⏭ تخطِّ ما لا تحتاجه.'
        '4️⃣ تظهر شاشة مراجعة بما ستعرضه — اقرأها.'
        '5️⃣ اضغط ✅ تأكيد. الآن هو على الهواء.'
        '6️⃣ لإخفائه: الصف الأحمر أعلى القائمة الرئيسية، اضغطه.'
        ''
        '━━━━━━━━━━━━━━'
        'ثلاث قواعد تريحك:'
        '• كل قالب يمر بمراجعة قبل الهواء، فلا شيء يُنشر بضغطة واحدة.'
        '• 🏠 القائمة يعيدك للرئيسية في أي لحظة، حتى وأنت تكتب.'
        '• الصفوف الحمراء أعلى القائمة هي ما يراه الجسر على الهواء الآن.'
        ''
        '📖 للتفصيل: افتح فهرس المساعدة واختر ما يخصّك.'
    )
    return ($lines -join "`n")
}

function Get-HelpChapters {
    <# The manual as chapters instead of one long screen. An operator asking
       "how do I hide this" wants that answer, not to scroll past scheduling
       to reach it. Each chapter is a screen; the index is the map.

       Content is the same material the full guide carries, regrouped. Admin
       chapters are filtered out for everyone else rather than shown locked. #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }

    $chapters = @(
        @{ Key = 'show'; Title = '▶️ نشر قالب'; AdminOnly = $false; Body = @(
                '📋 القوالب ← اختر القالب ← أدخل نص كل حقل ← راجع ← تأكيد.'
                '↳ كل قالب يمر بشاشة مراجعة قبل الهواء، حتى بلا حقول.'
                '↳ ⭐ المفضّلة تظهر في أعلى القائمة للوصول بنقرة.'
                ''
                '⏭ تخطِّ أي حقل لا تريد تعبئته؛ يبقى فارغًا على الشاشة.'
                '🔖 بعد كل عملية يظهر لها مرجع قصير في 🧾 عملياتي — اذكره'
                '   للمشرف إن احتجت أن يجد أثرها في السجل.'
            ) }
        @{ Key = 'edit'; Title = '✏️ التعديل أثناء العرض'; AdminOnly = $false; Body = @(
                '✏️ تحديث نص ← القالب ← الحقل ← النص الجديد.'
                '↳ يغيّر النص دون إعادة تشغيل حركة القالب.'
                '🔁 تكرار مع تعديل: يعيد آخر قالب بقيمه لتغيّر ما تريد.'
                '↩️ تراجع: يظهر في القائمة بعد أي عملية ويعيد الحالة السابقة'
                '   خلال مهلته.'
                ''
                '📋 التعديل يبدأ من النصّ الحالي لا من فراغ: يظهر أمامك'
                '   وتنسخه بضغطة — عليه أو على زر «نسخ» — ثم تلصقه وتعدّله.'
                '↳ والنصّ الذي سيظهر على الشاشة يُعرض دائمًا بخطّ ثابت،'
                '   فلا يختلط بأسماء الحقول التي تصفه.'
                ''
                '⏳ إن انشغلت أثناء الكتابة يصلك تنبيه قبل انتهاء المهلة بدقيقة'
                '   ومعه زر «تمديد» يعيدها من جديد، فلا يضيع ما كنت تكتبه.'
                '↳ ومسودة شريط الأخبار لها التنبيه نفسه قبل انتهائها.'
                '↳ ولو أُعيد تشغيل الجسر وأنت في منتصف الكتابة، تعود مسودتك'
                '   وتصلك رسالة تقول ذلك — فلا تذهب رسالتك التالية نصًّا'
                '   لقالبٍ دون أن تدري.'
            ) }
        @{ Key = 'stop'; Title = '🛑 الإنهاء والطوارئ'; AdminOnly = $false; Body = @(
                '🔴 صفوف أعلى القائمة هي ما يراه الجسر على الهواء الآن.'
                '↳ اضغط الصف لإخفاء تلك الطبقة مباشرة.'
                '🚨 إخفاء الكل: يعرض الطبقات ثم يطلب تأكيدًا قبل التنفيذ.'
                '🚪 خروج من المشهد: يشغّل نهاية المشهد بدل القطع الفوري.'
                '↳ عند تفعيل التأكيد يظهر اسم القالب ومدّته ومَن أرسله قبل التنفيذ.'
                '🕓 وإن قبِل Cinegy أمر الإخفاء ولم يؤكّد رفع الطبقة بعد، تقول'
                '   لك الرسالة ذلك، وتبقى الطبقة معروضة كأنها على الهواء حتى'
                '   يصل التأكيد — فلا تُفقد من نظرك وهي ربما ما تزال ظاهرة.'
                ''
                '⚡ الإخفاء والخروج لهما أولوية على العرض داخل الدفعة نفسها،'
                '   فأمر الطوارئ لا ينتظر خلف عملية عرض.'
            ) }
        @{ Key = 'trouble'; Title = '🆘 حين يحدث خطأ'; AdminOnly = $false; Body = @(
                'الشاشة تقول «فشل» ولا تعرف السبب:'
                '↳ 🔍 لماذا لم يظهر؟ تحت رسالة الفشل: هل Cinegy يستجيب، وهل'
                '   ملف المشهد في مكانه، ومن يحجز الطبقة. فحص قراءة فقط.'
                '↳ 🧾 عملياتي يذكر سبب الفشل والإرشاد المناسب لكل حالة.'
                '↳ انسخ 🔖 المرجع وأرسله للمشرف؛ يجد به سطر العملية في السجل.'
                ''
                'قالب ظاهر على الشاشة والجسر لا يعرفه، أو العكس:'
                '↳ 🎚 الطبقات يفحص Cinegy مباشرة ويقارن — «خارجي» تعني أن'
                '   شيئًا عُرض من خارج الجسر.'
                '↳ 📸 صورة من البث تحسم الأمر بالنظر.'
                ''
                'لا شيء يستجيب:'
                '↳ ℹ️ الحالة تبيّن إن كان Air غير متصل.'
                '↳ أبلغ المشرف؛ مركز الصحة عنده يوضح أين الخلل.'
            ) }
        @{ Key = 'time'; Title = '⏱ التوقيت والجدولة'; AdminOnly = $false; Body = @(
                '⏱ عرض مؤقّت: يعرض القالب ويخفيه تلقائيًا بعد المدة.'
                '↳ يمكن ربط مؤقّت بقالب موجود على الهواء من زر ⏱ بجانبه.'
                '📅 الجدولة: القالب والقيم والموعد، ثم مرة واحدة أو يومي أو أسبوعي.'
                ''
                '🔔 إن بقي قالب على الهواء طويلًا يصلك تنبيه ومعه زر'
                '   «تمت المعالجة». إن لم تؤكد تصلك متابعة واحدة بعدها.'
                '↳ المؤقتات والتنبيهات تُحفظ، فتستمر بعد إعادة تشغيل الجسر.'
            ) }
        @{ Key = 'urgent'; Title = '🚨 جدول العواجل'; AdminOnly = $false; Available = (Test-UrgentBoardAvailable); Body = @(
                'أسطر عاجلة تُعرض واحدًا بعد الآخر بإيقاع ثابت، بلا أن تقف'
                '   عند كل سطر لتكتبه وتنشره بيدك.'
                '🚨 العواجل ← ➕ أضف سطرًا ← ✅ حدّد ما يُعرض ← ▶️ تشغيل.'
                '↳ ⏹ إيقاف العواجل يظهر في القائمة ما دام الجدول يعمل.'
                '⏱ لكل سطر فاصله، وإلا فالفاصل العام.'
                '↳ 🔁 cycle يعيد الجدول كاملًا (١ ٢ ٣ · ١ ٢ ٣)، وitem'
                '   يكرّر كل سطر ثم ينتقل (١ ١ · ٢ ٢). والسقف الزمني يقصّهما.'
                '🎬 text يبدّل الكلمات في المشهد القائم، وexit يُخرجه ويعيده'
                '   بالسطر التالي. لكل سطر نمطه، وإلا فالنمط العام.'
                '⚙️ إعداداته في ⚙️ الإعدادات ← التشغيل على الهواء.'
            ) }
        @{ Key = 'news'; Title = '📰 شريط الأخبار'; AdminOnly = $false; Body = @(
                'الشريط يُحرَّر كمسودة، ولا يصل الهواء إلا بالنشر.'
                ''
                '✏️ بدء التحرير: يفتح مسودة ويقفلها باسمك حتى لا يعدّلها اثنان معًا.'
                '➕ إضافة خبر · 📝 تعديل وترتيب · 👁 معاينة.'
                '📥 استيراد TXT: ملف نصي يحل محل المسودة أو يُضاف إليها.'
                '🕘 النسخ والاستعادة: كل نشر يحفظ نسخة يمكن الرجوع إليها.'
                ''
                '📊 ⬇️ سحب ونشر و📝 سحب إلى المسودة يجلبان الشيت (إن ضُبط'
                '   رابطه). التفاصيل في باب «📊 الربط مع Google Sheets».'
                ''
                '🔒 إن كانت المسودة بيد زميل: 🔓 طلب فكّ القفل يرسل له طلبًا.'
                ''
                '🚪 ثلاث نهايات للمسودة، اختر بقصد:'
                '↳ ✅ مراجعة ونشر: يعرض ما سيتغيّر، ثم ينشر ويُفتح القفل.'
                '↳ 🤝 سلّم المسودة للتالي: لا تُحذف ولا تصل الهواء؛'
                '   تبقى بكل أخبارها ويتابعها أول من يضغط ✏️ — للمغادرة منتصف العمل.'
                '↳ 🗑 إلغاء المسودة: يُعيد إليك نصّ أخبارها رسالةً ثم يحذفها.'
                ''
                '⏳ مسودة تُترك بلا تعديل تنتهي صلاحيتها: يصلك تحذير قبلها،'
                '   ونصّ ما كُتب بعدها، وزرّ لاستئنافها.'
                '🧾 سجل التنفيذ: هل عملت مزامنة الشيت التلقائية، ومتى،'
                '   وكم خبرًا نشرت — فهي تنشر على الهواء بساعتها الخاصة.'
            ) }
        @{ Key = 'sheet'; Title = '📊 الربط مع Google Sheets'; AdminOnly = $false; Body = @(
                'الشيت والشريط وجهان لمحتوى واحد: ما في الشيت يصل الهواء،'
                'وما يُنشر من البوت يعود إلى الشيت.'
                ''
                '📄 شكل الشيت:'
                '↳ كل صف خبر واحد، من العمود الأول فقط.'
                '↳ الأعمدة التالية ملاحظات المحرر ولا تصل الهواء أبدًا.'
                '↳ الصف الفارغ يُتجاهل، والفاصلة داخل الخلية لا تكسر الخبر.'
                ''
                '⬇️ من الشيت إلى الهواء:'
                '↳ «⬇️ سحب ونشر» يجلب الشيت ويضعه على الهواء بعد تأكيد.'
                '↳ «📝 سحب إلى المسودة» يجلبه للمراجعة والترتيب، ولا يصل'
                '   الهواء شيء حتى تضغط «✅ مراجعة ونشر».'
                '↳ التأكيد يخبرك كم خبرًا سيُستبدل قبل التنفيذ.'
                '↳ الشيت الفارغ يُرفض ولا يمسح الشريط — إن كان المسح مقصودًا'
                '   فامسح من شاشة الأخبار يدويًا.'
                ''
                '⬆️ من البوت إلى الشيت:'
                '↳ كل نشر من تيليجرام يُكتب في الشيت أيضًا، فلا نسخ يدوي.'
                '↳ إن رفض الشيت الحفظ يبقى ما على الهواء منشورًا ويصلك أن'
                '   الحفظ وحده فشل.'
                ''
                '🔒 المسودة والقفل:'
                '↳ المزامنة التلقائية تتخطّى دورتها ما دامت هناك مسودة مفتوحة،'
                '   فلا يُمحى نصف سطر يكتبه زميل.'
                '↳ إن كانت المسودة بيد غيرك: «🔓 طلب فكّ القفل»، والاستبدال'
                '   المباشر للمشرف وحده وبتأكيد.'
            ) }
        @{ Key = 'mojaz'; Title = '📑 الموجز'; AdminOnly = $false; Available = (Test-MojazAvailable); Body = @(
                'نشرة كاملة من جدول: كل صف صورة وعنوان وخبر، تُعرض بالترتيب'
                '   في مشهد واحد لا يُعاد عرضه بين خبر وآخر.'
                ''
                '📚 المكتبة: احفظ ما شئت من الموجزات، لكلٍّ اسمه وصفوفه وتوقيته.'
                '↳ ➕ موجز جديد · ✏️ إعادة تسمية · 📋 نسخة منه · 🗑 حذفه.'
                '↳ الحذف يُلغي مواعيد الموجز معه، ويُمنع وهو على الهواء.'
                ''
                '➕ إضافة صف: صورة ثم عنوان ثم نص.'
                '✏️ برقم الصف: تعديل صورته أو عنوانه أو نصه دون حذفه.'
                '⬆️ ⬇️ لترتيب الصفوف · 🗑 لحذف صف · 🧹 لمسح الجدول.'
                ''
                '🖼 لكل صف ثلاثة اختيارات للصورة:'
                '↳ 🖼 صورة خاصة: ترفعها من الجوال أو تكتب مسارها.'
                '↳ ↑ يتبع السابق: لا تتغيّر الصورة — هكذا تخدم صورةٌ عدة صفوف.'
                '↳ ▫️ صورة القالب: العودة إلى صورة المشهد الأصلية.'
                '↳ صورة سبق رفعها في هذا الموجز تُعاد بضغطة بلا رفع ثانٍ.'
                '↳ ما تُرفعه يُفحص ويُقاس على مقاس القالب ويُحفظ PNG؛ وما ليس'
                '   صورة يُرفض بدل أن يصير صفًّا لا يعرض شيئًا.'
                '↳ عمود 🖼 في الجدول يقول لكل صف أيّ الثلاثة هو.'
                ''
                '🎬 مزامنة الظهور — ما هي ولماذا:'
                '↳ المشهد يلفّ، وعند نقطة اللفّ يختفي المحتوى ويعود بالظهور.'
                '↳ مطفأة: الخبر يُكتب في وقته، وقد يراه المشاهد يتبدّل أمامه.'
                '↳ مفعّلة: يُكتب داخل تلك الفيضة، فيظهر الخبر الجديد كأنه دخل'
                '   لتوّه — لا تبديل مرئي.'
                '↳ وثمنها أن الإيقاع يصير طول اللوب لا المدة التي كتبتها:'
                '   لوب من دقيقة يعني خبرًا كل دقيقة مهما كتبت.'
                '↳ لتغيير الإيقاع عندها، اقصص LoopEndFrame في Titler.'
                ''
                '⏱ المدة: كم يبقى كل صف · ⏩ الأول: زيادة حركة الدخول ·'
                '   ⏹ الأخير: بقاؤه قبل الخروج. صفرٌ يعني اتّباع القالب.'
                ''
                '▶️ تشغيل · ⏹ إيقاف وخروج.'
                '🕒 تشغيل لاحقًا: موعد محفوظ يبقى بعد إعادة تشغيل الجسر.'
                '🕒 المواعيد: كل المواعيد القادمة، وإلغاء أيّها.'
                '↳ الموعد يشغّل آخر نسخة محفوظة، لا نسخته وقت الحجز.'
                '↳ موعدان معًا لا يتصادمان: الثاني ينتظر ويصلك إشعار واحد.'
                '↳ تعديل الجدول أثناء البث يغيّر المرة القادمة لا ما يُعرض الآن.'
                '🧾 سجل التنفيذ في شاشة المواعيد: هل بدأ موجز أمس فعلًا،'
                '   وكم تأخّر عن موعده، وسبب فشله إن فشل.'
                ''
                '🚨 العاجل أولى: خروجه إلى الهواء يسحب الموجز. وقبل إرساله'
                '   تُسأل: الآن أم بعد انتهاء الموجز؟ والمؤجَّل يخرج وحده.'
                '↳ وتشغيل موجز والعاجل على الهواء يسألك المثل.'
                '⏹ «إخفاء الموجز» في القائمة الرئيسية يوقفه ويخرجه بحركة الخروج.'
            ) }
        @{ Key = 'track'; Title = '🔍 المتابعة والتحقق'; AdminOnly = $false; Body = @(
                'ℹ️ الحالة: ملخص سريع لخادم Air والقناة والقوالب المتابعة.'
                '🎞 جدول المواد: ما يعرضه جدول Cinegy اليوم، بلا تحرير — قراءة فقط.'
                '🤝 تسليم: ما على الهواء والمواعيد القادمة والفشل غير المعالَج في'
                '   شاشة واحدة، مع سطر ملاحظة حرّ وإقرار استلام من المُستلِم.'
                '🎚 الطبقات: يفحص Cinegy مباشرة ويقارنه بسجل الجسر.'
                '↳ لكل طبقة: ظاهر أو خارجي أو مخفي أو غير معروف.'
                '📸 صورة من البث: لقطة حديثة من خرج القناة.'
                '🧾 عملياتي: آخر عملياتك مع إعادة المحاولة ومرجع كل عملية.'
                '📅 سجل العمليات (من 🧾 عملياتي أو 📊 التقارير أو 📜 السجل):'
                '↳ نافذة 24 أو 48 أو 72 ساعة أو 7 أيام، والمقروءة معلَّمة بنقطة.'
                '↳ 📆 يوم أمس، ثم ◀ و▶ للتنقّل يومًا بيوم إلى الوراء.'
                '↳ جدول فيه الوقت والعملية والقالب والنتيجة، وحكمٌ فوقه يقول'
                '   إن كان في المدة فشل أو رفض.'
                '↳ يقرأ من سجلّ التدقيق لا من الذاكرة، فيبقى بعد إعادة التشغيل.'
                '↳ وللمشرف زر 👥 كل المشغّلين لرؤية عمليات الجميع في المدة نفسها.'
                '🕘 ماذا فاتني: ما جرى أثناء غيابك ومَن نفّذه.'
                '📊 تقارير: البنرات والأخبار خلال فترة، مع تحميل ملف.'
                '🆕 ما الجديد: ملخص تغييرات الإصدارات الأخيرة.'
                ''
                '⚠️ السطر أعلى القائمة يذكر متى تحقّق الجسر آخر مرة.'
                '↳ إن ظهر تحذير هناك فالمعلومة قد لا تطابق الشاشة — تأكد بلقطة.'
            ) }
        @{ Key = 'notices'; Title = '🔔 التنبيهات'; AdminOnly = $false; Body = @(
                'يمكن لأي قالب أن يُعلن عن نفسه حين يظهر على الهواء وحين يُرفع'
                '   عنه، ويقرّر المشرف أيّ القوالب تفعل ذلك ولمن.'
                ''
                '📨 ما يصلك في الإشعار:'
                '↳ اسم القالب والطبقة، ونصّ الخبر كما سيُقرأ على الشاشة.'
                '↳ المدة: «يُخفى تلقائيًا بعد …» أو «يبقى حتى يُخفى يدويًا»،'
                '   وعند الرفع: كم بقي على الهواء.'
                '↳ ومَن نفّذ العملية. ولا يصلك إشعار عن عملية نفّذتها أنت.'
                ''
                '🔕 على كل إشعار زر «أوقف تنبيهاتي» يخصّك وحدك.'
                '↳ وللعودة أرسل تنبيهاتي في أي وقت.'
                '⏸ ولا يقاطعك التنبيه وأنت تكتب: يُحتجَز حتى تنهي ما بيدك'
                '   ثم يصلك مجموعًا في رسالة واحدة.'
                '⚠️ إلا تنبيهًا واحدًا يصلك فورًا ولو أوقفت تنبيهاتك: أن يُعرض'
                '   أو يُرفع القالب الذي تجهّزه أنت الآن — راجع ما أعددته قبل'
                '   الإرسال، فقد تغيّر ما على الشاشة.'
                ''
                '🔁 والقالب الواحد لا يُبلَّغ عنه أكثر من مرة كل نصف دقيقة،'
                '   فتصحيحٌ متتابع لعنوان واحد لا يصير ثلاث مقاطعات.'
                ''
                '🌙 فترة الهدوء (يضبطها المشرف): ما ليس عاجلًا يُحتجَز ليلًا'
                '   ويصلك مجموعًا في موجز واحد حين تنتهي الفترة.'
                '↳ وما يعني أن الشاشة خطأ الآن — مخرجٌ أسود، غرافيك لا يُرفع —'
                '   يصل فورًا مهما كانت الساعة.'
                '↳ والمحتجَز محفوظ، فلا يضيع لو أُعيد تشغيل الجسر ليلًا.'
                ''
                '⚙️ للمشرف: «إشعار العرض حسب القالب» في الإعدادات — شاشة فيها'
                '   كل قالب، واضغط عليه ليتنقّل بين:'
                '↳ 🔕 لا أحد ← 👮 المشرفون ← 📢 كل المصرّح لهم.'
            ) }
        @{ Key = 'settings'; Title = '⚙️ الإعدادات'; AdminOnly = $true; Body = @(
                'كل ما يغيّر سلوك الجسر هنا، والتعديل يسري فورًا ويُحفظ في'
                '   config.json دون إعادة تشغيل، إلا ما يقول عكس ذلك عند حفظه.'
                ''
                '🎛 وأغلب القيم تُضبط بالضغط لا بالكتابة:'
                '↳ الأرقام: ➖ و➕ بخطوة تناسب حجم الرقم، ومعها الافتراضي'
                '   والحدّ الأدنى والأعلى، وزر ⌨️ لمن يعرف الرقم بالضبط.'
                '↳ الساعات وأيام الأسبوع: شبكة تختار منها، والحالية معلَّمة.'
                '↳ نافذة الصيانة: ساعة ثم ربع، وزر 🚫 بلا توقيت لإلغائها.'
                '↳ قوائم القوالب والطبقات والمدد: منتقٍ يمنع الخطأ في الهجاء.'
                '↳ والأرقام الحسّاسة لها مدًى لا يقبل ما خارجه.'
                ''
                '🤏 «وضع اليد الواحدة»: زرٌّ واحد بعرض الشاشة في كل صف، على'
                '   كل الشاشات لا القائمة وحدها — لمن يمسك الهاتف بيدٍ واحدة'
                '   وإبهامٍ واحد والوقت ضيّق.'
                ''
                '🗂 الأبواب التسعة:'
                '↳ 🔐 الأمان · 🔴 التشغيل على الهواء · 📚 القوالب · 📰 شريط الأخبار.'
                '↳ 📅 الجدولة · 📊 المراقبة · 🗄️ الملفات والاحتفاظ · 🔔 الإشعارات.'
                '↳ 🛠️ خيارات متقدمة.'
                '↳ كل إعداد في باب واحد فقط، وكل زر يعرض قيمته الحالية.'
                ''
                '🔎 الوصول السريع:'
                '↳ «🔎 بحث» يقبل اسم الإعداد أو جزءًا من وصفه العربي.'
                '↳ «📝 المعدّل فقط» يعرض ما يخالف الافتراضي — أول ما يُنظر إليه'
                '   حين يتصرف الجسر خلاف المتوقّع.'
                '↳ «🧭 مبسّط» ما يحتاجه التشغيل اليومي، و«🛠 متقدم» الباقي.'
                ''
                '✏️ التعديل:'
                '↳ إعداد نعم/لا ينقلب بضغطة واحدة.'
                '↳ إعداد رقمي يُضبط بـ ➖ و➕، ومن يعرف الرقم يكتبه من ⌨️؛'
                '   وما خرج عن مدى الإعداد يُرفض ولا يتغيّر شيء.'
                '↳ إعداد محدود الخيارات يُعرض أزرارًا، فلا يكسره خطأ إملائي.'
                '↳ كل تغيير يُكتب في 📜 السجل باسم من غيّره.'
                ''
                '🔐 صلاحية العرض والإخفاء لكل قالب وطبقة:'
                '↳ «قوالب للمشرفين» و«قوالب للمالك»: من يعرض هذا القالب ويخفيه.'
                '↳ «طبقات للمشرفين» و«طبقات للمالك»: تحمي الطبقة أيًّا كان'
                '   القالب الذي يُوضع عليها.'
                '↳ فارغٌ يعني للجميع، وهو الافتراضي. وحين تنطبق قاعدتان'
                '   يفوز الأشدّ: قالبٌ للمشرفين على طبقةٍ للمالك يصير للمالك.'
                '↳ الإخفاء الآلي لا يُمنع أبدًا — مؤقّت الإخفاء، «إخفاء الكل»،'
                '   وخروج الموجز — فبقاء غرافيك على الهواء أسوأ.'
                ''
                '🔒 إعدادات الحماية:'
                '↳ تظهر بقفل وتطلب تأكيدًا عند إضعافها لا عند تقويتها.'
                '↳ وهي: RequireUserLevelAuth، EnableSelfServiceRequests،'
                '   EnableRawCommand، EnableFullTemplateManagement،'
                '   EnableDpapiSecrets، BlockRejectedRequesters،'
                '   LeaveUnknownGroups.'
                ''
                '♻️ التراجع:'
                '↳ لكل إعداد زر يعيده إلى الافتراضي بتأكيد، و«استعادة الافتراضي»'
                '   يعيد الكل.'
                "↳ 🗄 نسخ الإعدادات: كل حفظ يخلف نسخة، ويُحتفظ بـ $(Get-SettingInt 'ConfigBackupKeepFiles' 1) منها."
                '↳ الاستعادة تعرض جدولًا: الإعداد، قيمته الآن، وقيمته في النسخة —'
                '   ثم تحفظ الحالية قبل الكتابة، وتحتاج إعادة تشغيل بعدها.'
                '↳ القيم السرّية تظهر بطولها لا بمحتواها، والقوائم بعدد عناصرها.'
                ''
                '📤 النقل بين الأجهزة:'
                '↳ التصدير يخرج الإعدادات وحدها: لا BotToken ولا قوائم المستخدمين.'
                '↳ الاستيراد يعرض ما سيتغيّر ويرفض أي مفتاح لا يعرفه، ولا يُطبّق'
                '   إلا بتأكيد.'
            ) }
        @{ Key = 'admin'; Title = '🛡️ أدوات المشرف'; AdminOnly = $true; Body = @(
                '⚙️ الإعدادات و👤 طلبات الوصول: في القائمة الرئيسية.'
                '🗂 أدوات الإدارة تجمع الباقي:'
                '↳ 👥 المستخدمون، ⚡ النصوص الجاهزة، 📚 القوالب.'
                '↳ ▶️ البث المباشر و🔗 رابط البث.'
                '↳ 📜 السجل و🧪 التشخيص و🛠 الأمر الخام.'
                '↳ ✅ جاهزية المناوبة: طبقات على الهواء وعمليات معلَّقة ومسودة'
                '   شريط ومحادثات محجورة وأعطال مثبَّتة، ثم حكم جاهز أو قائمة.'
                '↳ وتحتها 🛡 الحمايات المعطّلة بنتيجتها واسم إعدادها — ثلاث منها'
                '   تُشحن مطفأة. وهي اختيار إعداد، فلا تدخل حكم «جاهز».'
                '↳ 🗄 نسخ القوالب في 📚 القوالب: استعادة تُسمّي ما ستحذف وتغيّر'
                '   قبل الكتابة، وتُرفض إن مسّت قالبًا على الهواء أو مجدولًا.'
                '🔇 هدوء ساعتين: في ⚙️ الإعدادات ← المراقبة، بجانب فترة الهدوء'
                '   المجدولة. يحتجز غير العاجل فقط، وينتهي وحده مع إعادة التشغيل.'
                '🩺 مركز الصحة: Telegram وCinegy والمخرج والتخزين والجدولة'
                '   في شاشة واحدة، ومعها 🗂 ملفات التشغيل وسطر الاستخدام.'
                '🧪 فحص المسار الحي: دورة عرض وإخفاء كاملة على طبقة التجربة'
                '   تُبلّغ بنتيجة كل خطوة. تحتاج TemplateTestLayer غير مستخدمة.'
                '📤/📥 الإعدادات: نقل التهيئة بين الأجهزة. التصدير بلا توكن'
                '   ولا قائمة مستخدمين، والاستيراد يعرض ما سيتغيّر قبل تطبيقه.'
                '♻️ إعادة تشغيل الجسر: بتأكيد، وبعد التحقق من وجود خدمة تعيده.'
                ''
                '🖤 مراقبة المخرج — كيف تعرف أن البث شغّال:'
                $(if ((Get-SettingInt 'OutputMonitorMinutes' 0) -le 0) { '↳ المراقبة متوقفة الآن (OutputMonitorMinutes = 0).' }
                  else { "↳ الجسر يلتقط لقطة من خرج القناة كل $(Format-DurationMinutes -Minutes (Get-SettingInt 'OutputMonitorMinutes' 1))." })
                '↳ ينظر إلى الصورة نفسها، لا إلى ما يقوله Cinegy عن نفسه.'
                "↳ إن جاءت اللقطة سوداء لا يُنبّه فورًا: ينتظر $(Format-DurationSeconds -Seconds (Get-SettingInt 'OutputBlackConfirmSeconds' 1)) ويلتقط أخرى."
                '↳ التنبيه يصل فقط إذا كانت اللقطتان سوداوين — فاصل أو تعتيم'
                '   مقصود لا يوقظ أحدًا.'
                '↳ ينبّه مرة واحدة، ثم يُبلغ بالتعافي عند عودة الصورة.'
                '↳ اضبط OutputMonitorMinutes بـ 0 لإيقاف المراقبة كليًا.'
                ''
                '❤️ صحة Cinegy — من أين تأتي أرقام التحذير:'
                "↳ تُقرأ من قياسات المحرّك كل $(Format-DurationSeconds -Seconds (Get-SettingInt 'CinegyHealthCheckSeconds' 1)): عيّنات آخر دقيقة."
                "↳ «الساقط» يُحتسب عطلًا فقط إذا تجاوز $(Get-SettingInt 'CinegyFrameLossTolerance' 0) إطارًا وتجاوز $(Get-Setting 'CinegyFrameLossTolerancePercent')% من الخرج معًا."
                "↳ ولا تتغيّر الحالة إلا بعد $(Get-SettingInt 'CinegyHealthConfirmChecks' 1) فحوص متتالية متّفقة،"
                "   ثم لا يصل تحذير إلا بعد $(Get-SettingInt 'HealthFailureAlertThreshold' 1) حالات فشل متتالية."
                '↳ إن كانت التنبيهات كثيرة فارفع النسبة أو عدد الفحوص من ⚙️ الإعدادات.'
            ) }
        @{ Key = 'access'; Title = '🚪 من يدخل البوت'; AdminOnly = $true; Body = @(
                'البوت يجده الغرباء، ولكل قفل من أقفاله مفتاح في ⚙️ الإعدادات.'
                ''
                '👤 طلبات الوصول: من ينتظر، ومنذ متى، ومتى ينتهي طلبه.'
                '↳ ✅ موافقة تسأل مرة ثانية قبل التنفيذ — منح الوصول إلى الهواء'
                '   لا يقع بضغطة عابرة — ثم تعتمد الاسم الذي أرسله صاحب الطلب.'
                '↳ وكل موافقة تُبلَّغ لكل المشرفين باسم من منحها.'
                '↳ ❌ رفض يزيل الطلب ويحظر المحادثة فلا تعود تطلب أبدًا.'
                '   أطفئ «حظر من رُفض طلبه» إن أردت الرفض بلا حظر.'
                ''
                '📜 الطلبات السابقة (زر في شاشة الطلبات): من طلب، والحالة'
                '   (مقبول أو مرفوض أو بانتظار القرار)، ومتى صدر القرار،'
                '   وبواسطة من، وكم انتظر الطالب.'
                ''
                '📡 وكل مشرف يصله إشعار المشرفين، سواء كان في AdminChatIds'
                '   أو AdminUserIds — و🧪 التشخيص ينبّهك إن اختلفت القائمتان.'
                ''
                '🚫 المحظورون (من شاشة الطلبات): السبب والتاريخ ومن حظر،'
                '   وزر يرفع الحظر عن أي محادثة.'
                '↳ المحظور لا يُخبَر بأنه محظور — من يعرف يفتح حسابًا آخر.'
                ''
                '🔑 رمز الانضمام: اضبطه فيُسأل الغريب عنه قبل أن يصلك طلبه.'
                "↳ $(Get-SettingInt 'JoinSecretMaxAttempts' 0) محاولات خاطئة في اليوم تحظر المحادثة بلا رسالة."
                '↳ الرمز يُعرض ويُسجَّل بطوله لا بنصّه. أرسل - لمسحه.'
                "↳ ولكل محادثة $(Get-SettingInt 'MaxAccessRequestsPerDay' 0) طلبات في اليوم لا أكثر."
                ''
                "😴 كل يوم يصلك من لم يستخدم البوت منذ $(Get-SettingInt 'DormantUserDays' 0) يومًا."
                '↳ «تعطيل الخامل تلقائيًا» يعطّله فعلًا بدل الاكتفاء بالتبليغ.'
                '↳ المالك لا يُدرج، ومن لا تاريخ له لا يُحسب.'
                ''
                '🚪 المجموعات: البوت يغادر أي مجموعة يُضاف إليها ويخبرك.'
                '↳ مجموعة في AllowedChatIds ليست مجهولة فلا يغادرها.'
            ) }
        @{ Key = 'back'; Title = '↩️ الرجوع والإلغاء'; AdminOnly = $false; Body = @(
                '• ⬅️ رجوع في أسفل كل شاشة يعود خطوة للخلف.'
                '• 🏠 القائمة يرجعك للرئيسية في أي وقت، حتى أثناء إدخال نص.'
                '  زر الرجوع في الجوال يخرج من المحادثة كلها ولا يمكن للبوت'
                '  اعتراضه، لذلك استخدم أزرار الشاشة بدلًا منه.'
                '• ☰ بجانب مربع الكتابة يعرض كل الأوامر.'
                '• /الغاء يلغي العملية الحالية، و/قائمة يفتح القائمة.'
            ) }
    )

    $isAdmin = Test-Admin -ChatId $ChatId -UserId $UserId
    if ($isAdmin) {
        $sheet = @($chapters | Where-Object { $_.Key -eq 'sheet' })[0]
        $sheet.Body += @(
            ''
            '⚙️ الضبط (مشرف):'
            "↳ «رابط Google Sheets (CSV)» في ⚙️ الإعدادات: رابط تصدير CSV لا رابط الشيت العادي، والشيت مشارَك «أي شخص لديه الرابط»."
            "↳ «وضع مزامنة الشيت» يدوي أو تلقائي، ومعه فترة المزامنة ($(Get-SettingInt 'NewsSheetSyncMinutes' 1) د) ومهلة التنزيل ونطاق من يُبلَّغ بالتغيير."
            '↳ الكتابة العكسية تحتاج Google Apps Script منشورًا كتطبيق ويب.'
            '   رابطه وسرّه في config.json بجانب BotToken لا داخل Settings،'
            '   حتى لا يخرجا في تصدير الإعدادات. الخطوات في'
            '   docs/news-sheet-writeback.gs، ثم أعد تشغيل الجسر.'
            '↳ السكربت يستبدل العمود الأول فقط؛ ملاحظات الأعمدة الأخرى تبقى.'
        )
    }

    if (Test-StatusViewer -ChatId $ChatId -UserId $UserId) {
        $track = @($chapters | Where-Object { $_.Key -eq 'track' })[0]
        $track.Body += '📊 الحالة الكاملة: للمشرف والمالك؛ تفحص المصدر يدويًا وتوضح حالة سيرفر المتابعة.'
    }

    # A chapter about a scene this station has not got is dead text, and dead
    # text is not free: the manual is already bigger than one message, so every
    # paragraph that cannot apply costs a chapter that can its place on the
    # screen.
    #
    # The test is what the station HAS, never what it has CONFIGURED. Gating
    # the sheet chapter on a filled-in sheet URL hid the only page that
    # explains how to fill it in - a chapter that appears once you have set
    # the thing up can never be the chapter that teaches you to. A missing
    # scene file cannot be fixed from the bot; a missing setting can, and this
    # is where you learn how.
    #
    # ContainsKey, not a bare property read - Set-StrictMode throws on the
    # missing key, and most chapters carry no Available at all.
    $available = @($chapters | Where-Object { -not $_.ContainsKey('Available') -or [bool]$_.Available })
    return @($available | Where-Object { -not $_.AdminOnly -or $isAdmin })
}

function Get-HelpRichBlocks {
    <#
        The whole manual as one message, a chapter per collapsible block.

        The full guide has always been longer than a Telegram message, so it
        arrived split across several and the reader had to scroll through
        every chapter to reach the one they wanted. A details block (Bot API
        10.2) puts the chapter titles on screen and the bodies behind them,
        which is what an index was approximating with buttons and round
        trips.
    #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    $chapters = @(Get-HelpChapters -ChatId $ChatId -UserId $UserId)
    $blocks = @(@{ type = 'heading'; text = '📖 دليل الجسر'; size = 3 })
    # Capped against the payload limit rather than built and hoped for. Every
    # chapter of this manual at once came to 115% of the limit for an operator
    # and 182% for an administrator, so the rich send failed every time and the
    # reader always got the paged-text fallback: the collapsible chapters this
    # function exists to produce had never once rendered, and the only sign was
    # a warning line in bridge.log. Chapters go in until the next one would not
    # fit; the rest are named, because a manual that silently stops is worse
    # than one that says where it continues.
    $skipped = @()
    $used = (ConvertTo-RichMessagePayload -Blocks $blocks).Length
    foreach ($chapter in $chapters) {
        $body = @(@($chapter.Body) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { @{ type = 'paragraph'; text = [string]$_ } })
        # A details block with nothing in it renders as a control that opens
        # onto blank space, which reads as a chapter that failed to load.
        if ($body.Count -eq 0) { continue }
        # Measured per chapter and accumulated, not by re-serialising the whole
        # growing list each time round: that was quadratic, and it showed - the
        # gate slowed by more than a minute on a screen nobody had complained
        # about. Room is kept back for the closing line that names what was
        # left out.
        $entry = @{ type = 'details'; summary = [string]$chapter.Title; blocks = $body }
        $entryLength = (ConvertTo-RichMessagePayload -Blocks @($entry)).Length
        # Every chapter that fits goes in, not just the unbroken run before the
        # first one that does not. The manual has been bigger than one message
        # for a long time - an operator's is 15000 characters against a 12000
        # limit - so stopping at the first overflow spent the remaining budget
        # on nothing and threw away 🆘 حين يحدث خطأ, the chapter most worth
        # having on screen, to keep a contiguous run. Order is preserved and
        # whatever is missing is still named below, so a gap reads as a gap
        # rather than as an end.
        if (Test-RichPayloadSize -Length ($used + $entryLength + 400)) {
            $blocks += $entry
            $used += $entryLength
            continue
        }
        $skipped += [string]$chapter.Title
    }
    if ($skipped.Count -gt 0) {
        $blocks += @{ type = 'paragraph'; text = "📚 وبقية الأبواب في الفهرس: $($skipped -join ' · ')" }
    }
    return $blocks
}

function Get-MyOperationBlock {
    <#
        One operation, in as few lines as it can be told in.

        The first version spent up to five blocks each - the sentence, the
        category, the copy, the reference and the advice on separate lines -
        so three operations filled fifteen. Most of that was true of every
        row and therefore told the reader nothing: the category belongs
        beside the name it describes, and the reference is eight hex
        characters that matter only when something has to be reported.
    #>
    param([Parameter(Mandatory)]$Item)
    $icon = switch ([string]$Item.Result) { 'success' { '✅' } 'blocked' { '⛔' } default { '❌' } }
    $sentence = Get-OperationSentence -Action ([string]$Item.Action) -Result ([string]$Item.Result) -Target ([string]$Item.Target)
    $head = "$icon $(([datetime]$Item.At).ToString('HH:mm')) — $sentence"
    $category = Get-TemplateCategoryLabel -Key ([string]$Item.Target)
    if ($category) { $head += " · $category" }
    $blocks = @(@{ type = 'paragraph'; text = $head })

    # The copy keeps its own line: it is a whole sentence that went to air,
    # and it is what the graphic is recognised by.
    $onAirText = [string](Get-JsonProp $Item 'Values')
    if ($onAirText) { $blocks += @{ type = 'paragraph'; text = "📝 $onAirText" } }

    # Reference and advice only where they are asked for. On a successful
    # operation the reference is eight characters of noise on every row; on a
    # failed one it is the thing the administrator needs, so it arrives on the
    # same line as what to do about it.
    $advice = switch ([string]$Item.Result) {
        'failed' { 'افحص الاتصال ثم أعد المحاولة' }
        'blocked' { 'راجع صلاحيتك أو حالة Cinegy' }
        default { '' }
    }
    if ($advice) {
        $reference = Get-OperationReference -OperationId ([string]$Item.OperationId)
        $tail = if ($reference) { "🔖 $reference · $advice" } else { "↳ $advice" }
        $blocks += @{ type = 'paragraph'; text = $tail }
    }
    return $blocks
}

function Get-MyOperationsBlocks {
    <#
        The operation history: a verdict, then the newest few, then the rest
        folded.

        Deliberately not a table - the line that matters here is the copy that
        reached the screen, and it is a sentence, which is exactly why the
        banner report leaves that column out.

        The tally leads because it is the question the screen is opened with:
        did anything I did fail? Reading ten rows to find out is the work the
        screen exists to save.
    #>
    param([Parameter(Mandatory)][long]$UserId)
    $history = @(Get-UserOperationHistory -UserId $UserId | Select-Object -Last 10)
    $blocks = @(@{ type = 'heading'; text = '🧾 آخر عملياتك'; size = 3 })
    if ($history.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لم تُسجَّل لك عمليات بعد.' }
        return $blocks
    }

    $failed = @($history | Where-Object { [string]$_.Result -eq 'failed' }).Count
    $blockedCount = @($history | Where-Object { [string]$_.Result -eq 'blocked' }).Count
    $succeeded = $history.Count - $failed - $blockedCount
    $tally = "$(Get-ArabicCountNoun -Count $history.Count -One 'عملية' -Two 'عمليتان' -Few 'عمليات' -Many 'عملية') · ✅ $succeeded"
    if ($failed -gt 0) { $tally += " · ❌ $failed" }
    if ($blockedCount -gt 0) { $tally += " · ⛔ $blockedCount" }
    $blocks += @{ type = 'paragraph'; text = $tally }

    # Newest first here, unlike the list which is stored oldest-first: the one
    # being looked for is almost always the one just done.
    $ordered = @($history)[($history.Count - 1)..0]
    $recent = @($ordered | Select-Object -First 3)
    $older = @($ordered | Select-Object -Skip 3)

    foreach ($item in $recent) {
        $blocks += @{ type = 'divider' }
        $blocks += @(Get-MyOperationBlock -Item $item)
    }
    if ($older.Count -gt 0) {
        $inner = @()
        foreach ($item in $older) {
            if ($inner.Count -gt 0) { $inner += @{ type = 'divider' } }
            $inner += @(Get-MyOperationBlock -Item $item)
        }
        $blocks += @{ type = 'details'; summary = "🔍 عمليات أقدم ($($older.Count))"; blocks = $inner }
    }
    # Only when the keyboard actually carries the button - both screens ask
    # the same function, so the promise cannot outlive the button.
    $copyReference = Get-MyOperationsCopyReference -UserId $UserId
    if ($copyReference) {
        $blocks += @{ type = 'paragraph'; text = (Get-CopyButtonNotice -Label (Get-MyOperationsCopyLabel -Reference $copyReference) -Hint 'أرسله للمشرف مع وصف ما حدث.') }
    }
    return $blocks
}

function Format-HelpHtmlLine {
    <#
        One line of the manual, formatted.

        The guide is a hierarchy - chapter, section, step - and plain text
        gave all three the same weight: the line naming a section read
        exactly like the steps under it. Two rules carry that structure, and
        both are read off the text rather than written into every line:
        a line that ends in a colon is a section head, and a word that is
        the name of a real setting is code.

        The tags never span a line, because Split-TelegramText cuts on line
        boundaries and Telegram refuses a message with half a tag in it.
    #>
    param([string]$Line)
    $text = ConvertTo-TelegramHtmlText -Text ([string]$Line)
    if ([string]::IsNullOrWhiteSpace($text)) { return $text }
    if (-not $script:HelpCodeTermPattern) {
        # Longest first, so SceneMode inside a longer name is not matched
        # before the name itself.
        $terms = @(@($script:DefaultSettings.Keys) + @('BotToken', 'config.json')) |
            Sort-Object -Property Length -Descending
        $script:HelpCodeTermPattern = '(' + ((@($terms) | ForEach-Object { [regex]::Escape([string]$_) }) -join '|') + ')'
    }
    $text = [regex]::Replace($text, $script:HelpCodeTermPattern, '<code>$1</code>')
    if ($text.TrimEnd().EndsWith(':')) { return "<b>$text</b>" }
    return $text
}

function Get-HelpChapterIndex {
    param([AllowNull()][object[]]$Chapters, [string]$Key)
    $list = @($Chapters)
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ([string]$list[$i].Key -eq $Key) { return $i }
    }
    return -1
}

function Get-HelpChapterText {
    param([Parameter(Mandatory)][string]$Key, [long]$ChatId = 0, [long]$UserId = 0)
    $chapters = @(Get-HelpChapters -ChatId $ChatId -UserId $UserId)
    $index = Get-HelpChapterIndex -Chapters $chapters -Key $Key
    if ($index -lt 0) { return '' }
    $chapter = $chapters[$index]
    $lines = @("<b>📖 $(ConvertTo-TelegramHtmlText -Text ([string]$chapter.Title))</b>", '━━━━━━━━━━━━━━') +
        @(@($chapter.Body) | ForEach-Object { Format-HelpHtmlLine -Line ([string]$_) }) +
        @('', "<i>الباب $($index + 1) من $($chapters.Count)</i>")
    return ($lines -join "`n")
}

function Get-HelpChapterKeyboard {
    <# Previous and next keep sequential reading possible for anyone who wants
       the whole manual in order, while the index button means nobody has to. #>
    param([Parameter(Mandatory)][string]$Key, [long]$ChatId = 0, [long]$UserId = 0)
    $chapters = @(Get-HelpChapters -ChatId $ChatId -UserId $UserId)
    $index = Get-HelpChapterIndex -Chapters $chapters -Key $Key
    $navigation = @()
    if ($index -gt 0) { $navigation += @{ text = '⬅️ السابق'; callback_data = "help:ch:$($chapters[$index - 1].Key)" } }
    $navigation += @{ text = '📖 الفهرس'; callback_data = 'help:home' }
    if ($index -ge 0 -and $index -lt ($chapters.Count - 1)) { $navigation += @{ text = '➡️ التالي'; callback_data = "help:ch:$($chapters[$index + 1].Key)" } }
    $rows = @()
    $rows += , @($navigation)
    $rows += , @(@{ text = '🏠 القائمة'; callback_data = 'menu:main' })
    return @{ inline_keyboard = $rows }
}

function Get-HelpHomeText {
    param([long]$ChatId = 0, [long]$UserId = 0)
    $chapters = @(Get-HelpChapters -ChatId $ChatId -UserId $UserId)
    $lines = @(
        '<b>📘 دليل بوت Cinegy Air</b>'
        "الإصدار <code>$($script:BridgeVersion)</code>"
        ''
        '<b>اختر ما تريد معرفته:</b>'
        ''
    )
    foreach ($chapter in $chapters) { $lines += "• $(ConvertTo-TelegramHtmlText -Text ([string]$chapter.Title))" }
    $lines += @('', '<i>🚀 جديد على البوت؟ ابدأ بـ«بداية سريعة».</i>')
    return ($lines -join "`n")
}

function Get-HelpHomeKeyboard {
    param([long]$ChatId = 0, [long]$UserId = 0)
    $rows = @()
    $rows += , @(@{ text = '🚀 بداية سريعة'; callback_data = 'help:quickstart' })
    $chapters = @(Get-HelpChapters -ChatId $ChatId -UserId $UserId)
    # Two chapters per row: the titles are short enough to stay readable, and a
    # nine-row column would push the menu button off a phone screen.
    for ($i = 0; $i -lt $chapters.Count; $i += 2) {
        $row = @(@{ text = $chapters[$i].Title; callback_data = "help:ch:$($chapters[$i].Key)" })
        if ($i + 1 -lt $chapters.Count) { $row += @{ text = $chapters[$i + 1].Title; callback_data = "help:ch:$($chapters[$i + 1].Key)" } }
        $rows += , $row
    }
    $rows += , @(@{ text = '📄 الدليل كاملًا'; callback_data = 'help:full' }, @{ text = '🏠 القائمة'; callback_data = 'menu:main' })
    return @{ inline_keyboard = $rows }
}

function Get-HelpText {
    <# The full guide is every chapter end to end, so the words live in one
       place: a chapter that gains a section gains it here too. It runs past
       one Telegram message, which is why the button behind it pages. #>
    param([long]$ChatId = 0, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('<b>📘 دليل بوت Cinegy Air</b>')
    $lines.Add("الإصدار <code>$($script:BridgeVersion)</code>")
    $lines.Add('')
    foreach ($chapter in @(Get-HelpChapters -ChatId $ChatId -UserId $UserId)) {
        $lines.Add('━━━━━━━━━━━━━━━━')
        $lines.Add("<b>$(ConvertTo-TelegramHtmlText -Text ([string]$chapter.Title))</b>")
        $lines.Add('━━━━━━━━━━━━━━━━')
        foreach ($line in @($chapter.Body)) { $lines.Add([string](Format-HelpHtmlLine -Line ([string]$line))) }
        $lines.Add('')
    }
    return (($lines -join "`n").TrimEnd())
}
