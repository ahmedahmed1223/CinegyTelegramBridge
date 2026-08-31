#requires -Version 7
<#
    Dot-sourced by TelegramBridge.ps1. NOT a module: these functions must
    share the bridge script's scope and $script: state.

    Declarations only - ordered initialization stays in TelegramBridge.ps1.
#>

function Get-LayerLockNotice {
    <#
        Describes an editing lock held by someone else: who, and for how long.

        The raw owner id told an operator nothing they could act on. Two people
        on the same channel - one on a phone, one at the desk - hit this
        routinely, and "المستخدم 7275359265" does not tell you whether to wait
        or to call across the room. Returns '' when the layer is free or held
        by the asker themselves.
    #>
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$UserId)
    if (-not $script:LayerLocks.ContainsKey($Layer)) { return '' }
    $lock = $script:LayerLocks[$Layer]
    if ([long]$lock.UserId -eq $UserId) { return '' }
    $held = if ($lock.StartedAt -is [datetime]) { Format-Duration -Seconds ([int]((Get-Date) - $lock.StartedAt).TotalSeconds) } else { 'فترة' }
    return "⚠️ $(Get-UserDisplayName -UserId ([long]$lock.UserId)) يجهّز '$($lock.Key)' على الطبقة $Layer منذ $held."
}

function Lock-GfxLayer {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][long]$ChatId,
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][string]$Key
    )
    if ($script:LayerLocks.ContainsKey($Layer)) {
        $existing = $script:LayerLocks[$Layer]
        if ([long]$existing.ChatId -ne $ChatId -or [long]$existing.UserId -ne $UserId) {
            return [pscustomobject]@{
                Success = $false
                OwnerChatId = [long]$existing.ChatId
                OwnerUserId = [long]$existing.UserId
                Key = [string]$existing.Key
            }
        }
    }
    $script:LayerLocks[$Layer] = @{
        ChatId = $ChatId; UserId = $UserId; Key = $Key; StartedAt = (Get-Date)
    }
    return [pscustomobject]@{ Success = $true; OwnerChatId = $ChatId; OwnerUserId = $UserId; Key = $Key }
}

function Unlock-GfxLayer {
    param([Parameter(Mandatory)][long]$ChatId, [int]$Layer = 0)
    foreach ($candidate in @($script:LayerLocks.Keys)) {
        if (($Layer -le 0 -or [int]$candidate -eq $Layer) -and [long]$script:LayerLocks[$candidate].ChatId -eq $ChatId) {
            $script:LayerLocks.Remove($candidate)
        }
    }
}

function Set-PendingState {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    Set-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId -State $State
    if ([string]$State.Mode -in @('show_fields', 'show_review')) { Save-DraftStates }
}

function Get-PendingState {
    <# Returns the pending flow for a chat, or $null if there is none or it has
       aged out. Expiry is checked on read as well as on the tick so a stale
       entry can never be consumed. #>
    param([Parameter(Mandatory)][long]$ChatId)
    $timeout = Get-SettingInt 'PendingStateTimeoutMinutes' 1
    $result=Get-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId -TimeoutMinutes $timeout
    if (-not $result.State) { return $null }
    if ($result.Expired) {
        Complete-PendingStateCleanup -ChatId $ChatId -State $result.State
        return $null
    }
    return $result.State
}

function Complete-PendingStateCleanup {
    param([Parameter(Mandatory)][long]$ChatId,[Parameter(Mandatory)][hashtable]$State)
    if ($State.ContainsKey('LockLayer')) { Unlock-GfxLayer -ChatId $ChatId -Layer ([int]$State.LockLayer) }
    if ($State.ContainsKey('ImportStagedPath') -and (Test-Path -LiteralPath ([string]$State.ImportStagedPath))) {
        Remove-Item -LiteralPath ([string]$State.ImportStagedPath) -Force -ErrorAction SilentlyContinue
    }
    if ([string]$State.Mode -in @('show_fields', 'show_review')) { Save-DraftStates }
}

function Clear-PendingState {
    param([Parameter(Mandatory)][long]$ChatId)
    $state=Remove-BridgePendingFlow -Store $script:PendingState -ChatId $ChatId
    if ($state) { Complete-PendingStateCleanup -ChatId $ChatId -State $state }
}

function Get-WhatsNewSections {
    <#
        Operator-facing release notes, held here rather than parsed out of
        CHANGELOG.md on purpose: the changelog is written for whoever
        maintains the bridge and is full of function names, while an operator
        needs to know what changed on their screen and what to do
        differently. Keep the newest release first, keep it short, and only
        mention things an operator can see or act on.
    #>
    return @(
        @{ Version = '7.10.0'; Items = @(
                '🕘 «ماذا فاتني» تبدأ الآن بما على الهواء — كان آخر سطر فيها، وهو أول ما تحتاجه عند تسلّم الوردية.'
                '📝 نصوص البنرات عادت إلى تقرير البنرات تحت «نصوص البنرات».'
                '🧾 «عملياتي» تعرض الثلاث الأحدث وتطوي ما قبلها.'
            ) }
        @{ Version = '7.9.0'; Items = @(
                '📐 التقارير صارت تتسع لشاشة الهاتف: أربعة أعمدة قصيرة، والتفصيل تحت «تفاصيل كل يوم» يُفتح بالضغط.'
                '📊 عمود «المدى» (12–18) يقول أين تراوح الشريط طوال اليوم مهما بلغ عدد التعديلات.'
            ) }
        @{ Version = '7.8.0'; Items = @(
                '📊 تقرير الأخبار صُحّح: الشريط واحد يُعدَّل، فعدد الأخبار صار «ما على الهواء» لا مجموع القراءات — كان يضخّم الرقم.'
                '📈 وصار يعرض حجم كل تعديل (12 ← 15 ← 14)، ووقت أول وآخر تعديل، والأيام التي مرّت بلا تعديل.'
                '📖 «الدليل كاملًا» صار رسالة واحدة بأبواب تُفتح بالضغط.'
                '🧾 «عملياتي» صار قائمة مرتّبة بدل أسطر مُزاحة.'
            ) }
        @{ Version = '7.7.0'; Items = @(
                '📰 تقرير الأخبار صار جدولًا أيضًا: اليوم · النشرات · الأخبار · المشغّلون في صف واحد.'
            ) }
        @{ Version = '7.6.0'; Items = @(
                '📅 الجدولة صار فيها تقويم: اضغط «اختر من التقويم» ثم اليوم ثم الساعة ثم الدقيقة — بلا كتابة.'
                '⏱ وأزرار +15 و+30 و+60 دقيقة لأكثر ما يُجدوَل.'
                '⌨️ ومَن يفضّل الكتابة: «21:45» وحدها تكفي، وكذلك «غدًا 21:45» و«+30» — والأرقام العربية ٢١:٤٥ صارت مقبولة.'
            ) }
        @{ Version = '7.5.0'; Items = @(
                '🕒 «الأحداث القادمة» صارت تعرض الوقت بمنطقتك الزمنية ويوم الأسبوع، ومنطقة المحطة تبقى مكتوبة بجانبه.'
            ) }
        @{ Version = '7.4.0'; Items = @(
                '📊 تقرير البنرات صار جدولًا بأعمدة: البنر · الطبقة · المشغّل · الوقت · المدة. إن لم يظهر جدولًا فتطبيقك أقدم من الميزة، والتقرير يصل نصًّا كما كان.'
            ) }
        @{ Version = '7.3.0'; Items = @(
                '🔎 للمشرف: «ابحث بمرجع عملية» في شاشة التشخيص — الصق المرجع الذي نسخه المشغّل لترى سطر العملية فورًا.'
            ) }
        @{ Version = '7.2.0'; Items = @(
                '🔔 «سحب الشيت غير مسموح لك» و«الاستعادة للمشرف» صارا نافذة على الزر. والاستعادة كانت ترفض بصمت تام قبل ذلك.'
                '📋 «نسخ مرجع» في 🧾 عملياتي: انسخ المرجع بنقرة بدل كتابته حرفًا حرفًا للمشرف.'
            ) }
        @{ Version = '7.1.1'; Items = @(
                '🔴 تأكيد الإخفاء والخروج صار أحمر أيضًا: تفعيل التأكيد كان يعطي شاشة أضعف إشارة من تركه مطفأً.'
            ) }
        @{ Version = '7.1.0'; Items = @(
                '🔔 الرفض صار نافذة تظهر على الزر نفسه وتنتظر إغلاقك، بدل رسالة جديدة تدفع اللوحة خارج الشاشة.'
            ) }
        @{ Version = '7.0.1'; Items = @(
                '🎨 اللون وصل بقية الشاشات: الإخفاء والخروج من المشهد وحذف القالب وسحب الصلاحية بالأحمر، و«تأكيد الإرسال» و«تأكيد الجدولة» و«حفظ التغيير» بالأخضر.'
                '🧭 زر القائمة الذي يفتح شاشة يبقى بلا لون — الأحمر على الضغطة التي تُنفّذ فعلًا، لا على الطريق إليها.'
            ) }
        @{ Version = '7.0.0'; Items = @(
                '🎨 الأزرار صار لها لون: الحذف وإلغاء المسودة ومسح الكل بالأحمر، و«مراجعة ونشر» بالأخضر. أطفئه من ⚙️ الإعدادات ← «تلوين الأزرار».'
                '🚫 السهم الخامل في طرفي القائمة (▫️) صار معطّلًا فعلًا: لم يعد يُضغط ويبتلع الضغطة بلا نتيجة.'
                '📜 سرد الترتيب صار داخل اقتباس قابل للطيّ، فالصفحة الطويلة لم تعد تدفع الأزرار خارج الشاشة — اضغط «إظهار المزيد» لقراءته كاملًا.'
            ) }
        @{ Version = '6.9.5'; Items = @(
                '🔢 في الشكل المكدّس: رقم الخبر صار على كل زر إجراء، والعلامة تتناوب ▪️/▫️، فلا يختلط خبر بأزرار جاره.'
                '🗜 شكل خامس… رابع: compact — أرقام فقط خمسة في الصف، حتى 40 خبرًا في شاشة واحدة، والإجراءات في شاشة الخبر.'
            ) }
        @{ Version = '6.9.4'; Items = @(
                '🧩 «شكل قائمة الأخبار» في ⚙️ الإعدادات: ثلاثة أشكال للترتيب — text نص كامل فوق الأزرار · stacked الخبر بزر مستقل · inline الخبر داخل الصف. جرّب واختر.'
            ) }
        @{ Version = '6.9.3'; Items = @(
                '📝 شاشة الترتيب: نص الخبر صار يظهر كاملًا فوق الأزرار بدل أن يُقصّ داخل زر ضيق، وصفوف الأخبار صارت بحجم واحد.'
            ) }
        @{ Version = '6.9.2'; Items = @(
                '📊 باب جديد في المساعدة: «الربط مع Google Sheets» — شكل الشيت، والسحب في الاتجاهين، ومن يملك المسودة.'
            ) }
        @{ Version = '6.9.1'; Items = @(
                '📖 «مساعدة» و/help صارا يفتحان فهرس الأبواب نفسه الذي يفتحه زر المساعدة، لا الدليل القديم.'
                '📰 «الدليل كاملًا» صار يشمل شريط الأخبار وسحب الشيت — كانا ناقصين منه.'
                '📜 في السجل: اسم مَن نفّذ مع رقمه في كل سطر، ورقمه بأقواس سليمة لا معكوسة.'
            ) }
        @{ Version = '6.9.0'; Items = @(
                '↔️ صار ما تنشره من تيليجرام يُحفظ في الشيت أيضًا، فيبقى الشيت السجل المقروء مهما كان مكان التحرير.'
                '🛟 إن رفض الشيت الحفظ لا يتأثر ما على الهواء: الشريط منشور، ويصلك أن الحفظ في الشيت وحده فشل.'
            ) }
        @{ Version = '6.8.0'; Items = @(
                '🚀 «بداية سريعة»: بطاقة واحدة تأخذ من لم يستخدم البوت قط إلى أول قالب على الهواء في ست خطوات.'
                '📖 المساعدة صارت فهرس أبواب: اضغط الباب الذي يخصّك بدل قراءة دليل كامل بحثًا عن سطر.'
                '⬅️➡️ داخل كل باب أزرار السابق والتالي والفهرس، ومن يريد الدليل كاملًا يجده كما كان.'
                '🔒 سحب الشيت صار يحترم قفل المسودة: لا يستطيع مشغّل محو مسودة زميله، بل يطلب فكّ القفل كبقية الشاشات.'
            ) }
        @{ Version = '6.7.0'; Items = @(
                '⚠️ زرّا سحب الشيت صارا يطلبان تأكيدًا دائمًا قبل التنفيذ، فلا تعيد نقرة عابرة كتابة الشريط.'
                '🔎 رسالة التأكيد تقول ماذا سيحدث بالضبط: كم خبرًا سيُستبدل، ومَن يحرّر المسودة الآن إن وُجد.'
            ) }
        @{ Version = '6.6.0'; Items = @(
                '👥 زرّا سحب الشيت («سحب ونشر» و«سحب إلى المسودة») صارا متاحين لكل المشغّلين، لا للمشرفين وحدهم.'
                '🔔 صار تنبيه المزامنة يصل الجميع افتراضيًا، فيعرف الفريق كله بما تغيّر على الشريط.'
                '🔐 يستطيع المشرف إعادة السحب للمشرفين فقط من إعداد «سماح المشغّلين بسحب الشيت».'
            ) }
        @{ Version = '6.5.0'; Items = @(
                '📝 زر «سحب إلى المسودة» يجلب الشيت للمراجعة بدل النشر الفوري — راجع ورتّب وصحّح، ثم انشر.'
                '⬇️ زر «سحب ونشر» يبقى كما هو لمن يريد الشيت على الهواء مباشرة.'
                '🔔 صار بإمكانك اختيار من يُنبَّه بعد كل مزامنة: لا أحد، أو المشرفون، أو كل المستخدمين المصرّح لهم.'
            ) }
        @{ Version = '6.4.0'; Items = @(
                '📊 صار الشريط يُحدَّث من Google Sheets مباشرة. اكتب الخبر في الشيت وهو يصل الهواء دون أي برنامج وسيط.'
                '⬇️ زر «سحب من الشيت» في شاشة الأخبار يجلب الآن فورًا؛ أو اضبط المزامنة تلقائية كل عدة دقائق.'
                '🔒 المزامنة التلقائية لا تدهس مسودة يحرّرها أحد: تتخطّى الدورة وتعيد المحاولة، ولا يضيع ما كتبته.'
                '🛟 الشيت الفارغ لا يمسح الشريط — يُرفض التحديث بدل أن يترك الشاشة بلا أخبار.'
            ) }
        @{ Version = '6.3.0'; Items = @(
                '🔖 كل عملية في «عملياتي» صار لها مرجع قصير. اذكره للمشرف وهو يجد سطرها في السجل مباشرة.'
                '🗂 «ملفات التشغيل» شاشة جديدة في مركز الصحة: تقول أي ملف حالة سليم، وأيّهما تالف، وأيّهما له نسخة احتياطية تُستعاد وحدها.'
                '📈 مركز الصحة صار يعرض سطر استخدام: عمليات اليوم، عدد المشغّلين، كم على الهواء، ومنذ متى يعمل الجسر.'
            ) }
        @{ Version = '6.2.0'; Items = @(
                '🧹 إصدار صيانة: لا شيء تغيّر في أي شاشة أو زر أو أمر. العمل كله داخلي.'
                '🕒 «ماذا فاتني» صارت تقرأ أوقات سجل التدقيق بنفس الطريقة التي تقرأ بها بقية الشاشات، فلا تختلف الساعة بين شاشة وأخرى.'
                '✅ الاختبارات أعيد تنظيمها ووُسّعت لتغطي «استعادة الافتراضي» و«البحث» في الإعدادات، وهما مساران لم يكن يحرسهما اختبار.'
            ) }
        @{ Version = '6.1.0'; Items = @(
                '📊 زر «تقارير» جديد: البنرات (ماذا ظهر، بأي نص، ومتى اختفى) والأخبار (النشر اليومي وعدد الأخبار).'
                '⬇️ أي تقرير يُحمَّل ملفًا يُفتح في المتصفح، ومنه تطبعه PDF بعربية سليمة.'
                '🧾 «عملياتي» صارت تُكتب بالعربية وتعرض النص الذي ظهر على الهواء، بدل رموز تقنية وأرقام مللي ثانية.'
                '🕘 «ماذا فاتني» توضّح مَن نفّذ ماذا: مجموع العمليات، وتوزيع القالب المشترك على مشغّليه.'
                '📜 «السجل» و«عملياتي» لم تعودا تفرغان بعد إعادة تشغيل الجسر؛ تُستعادان من سجل التدقيق الدائم.'
            ) }
        # One entry per shipped release. The -preview.N milestones were internal
        # steps toward 6.0.0 and never reached an operator, so they are folded
        # in here rather than listed as four near-identical versions.
        @{ Version = '6.0.0'; Items = @(
                '⚙️ الإعدادات أصبحت أقسامًا عربية قصيرة موزعة على صفحات، وكل بند يعرض حالته أو قيمته الحالية في صف كامل.'
                '🩺 مركز صحة جديد يجمع Telegram وCinegy والمخرج والبث والتخزين والجدولة في شاشة واحدة للمشرف.'
                '🚨 أوامر الإخفاء والخروج تتقدم داخل دفعة Telegram، والتحديث المكرر لا يُنفذ مرتين.'
                '⏱ مؤقت الإخفاء يتابع معرّف Cinegy الصحيح لنفس القالب ولا يلغي نفسه بعد العرض.'
                '🔔 تنبيه القالب يتيح تأكيد المعالجة، ويرسل متابعة واحدة إذا لم يؤكده المستخدم.'
                '📄 إدارة القوالب والمستخدمين وطلبات الوصول تعمل بصفحات آمنة حتى مع الأعداد الكبيرة.'
                '👥 المشرف يرى نشاط المستخدمين التقريبي حسب آخر تفاعل، دون ادعاء حالة اتصال لحظية.'
                '📜 «السجل» و«عملياتي» تبقيان ممتلئتين بعد إعادة التشغيل، ويظهر Alias المشغّل مع معرّفه الثابت.'
            ) }
        @{ Version = '5.7.9'; Items = @(
                '👤 طلبات الوصول ما زالت متاحة للمستخدمين، لكن زر قبول أو رفض الطلبات يظهر للمشرف والمالك فقط.'
                '🛡️ فحص التشغيل الأحادي متسامح افتراضيًا عند تعذّر إنشاء القفل؛ استخدم -RequireSingleInstance للتشدد.'
                '📦 ملفات إعدادات الجسر وتعريفات القوالب تقبل الآن حتى 10 ميغابايت.'
            ) }
        @{ Version = '5.7.7'; Items = @(
                '📸 كل لقطة من البث توضح الآن مصدرها: الأساسي أو Cinegy الاحتياطي.'
            ) }
        @{ Version = '5.7.6'; Items = @(
                '🔔 من تفاصيل كل قالب، يضبط المشرف أو المالك تنبيه الظهور بالدقائق (0 لإيقافه).'
                '⏰ التنبيه يصل للشخص الذي أظهر القالب فقط، ويُحفظ ليستمر بعد إعادة التشغيل.'
                '🟣 القالب Long run مثل الشعار أو الشريط 24/7 لا يأخذ تنبيه ظهور.'
            ) }
        @{ Version = '5.7.5'; Items = @(
                '⏱ مؤقت العرض يُحفظ ويُستعاد بعد إعادة تشغيل الجسر، ثم يُكمل المدة المتبقية.'
                '🛡️ إذا تغيّر المشهد على الطبقة، يُلغى المؤقت القديم حتى لا يخفي المشهد الجديد.'
            ) }
        @{ Version = '5.7.4'; Items = @(
                '⚠️ مراقب المخرج ينبه الآن إذا تعذّر التقاط المصدر، لا للشاشة السوداء فقط.'
                '🔁 عند تعذّر المصدر الأساسي يتحول فورًا إلى مصدر Cinegy الاحتياطي، واللقطة تعيد المحاولة منه تلقائيًا.'
                'مصدر الاحتياط لقناة Cinegy 0 هو معاينة SRT المحلية: srt://127.0.0.1:5421.'
                '📡 الحالة الكاملة تفحص المصدر يدوياً وتوضح حالة سيرفر المتابعة؛ الزر متاح للمشرف والمالك.'
                '📅 الأحداث المجدولة تبقى بعد إعادة تشغيل الجسر؛ وعند حلول المؤقت يُفحص القالب الحالي ثم طبقة Cinegy قبل SHOW.'
            ) }
        @{ Version = '5.7.3'; Items = @(
                'إصلاح: أعمار المشاهد كانت ما تزال بالثواني — «107775 ثانية» بدل «يوم و5 ساعات و56 دقيقة».'
                'وسطر آخر فحص ناجح يقول «الآن» بدل «منذ 0 ثانية».'
            ) }
        @{ Version = '5.7.2'; Items = @(
                '⏱ الأوقات في شاشات الحالة صارت مقروءة: «يوم وساعتان» بدل «1560 دقيقة».'
                '«آخر فحص ناجح» يبدأ بالمدّة لا بالتاريخ، ووقت الساعة بين قوسين.'
                '🗄 سجل التدقيق يُؤرشف تلقائيًا عند 110 ميغابايت في ملف مستقل — بلا حذف.'
                'و«ماذا فاتني» تقرأ من الأرشيف أيضًا، فلا يضيع تاريخ بعد الأرشفة.'
            ) }
        @{ Version = '5.7.1'; Items = @(
                '❤️ تنبيهات صحة Cinegy صارت أهدأ: الإطارات الساقطة تُقاس كنسبة من الخرج لا كعدد مجرّد.'
                '34 إطارًا من 1467 هي 2٪ ولم تعد تستحق تحذيرًا، والحالة لا تتغيّر إلا بعد ثلاثة فحوص متّفقة.'
                '🖤 شرح مراقبة المخرج وأرقام الصحة صار في ❓ المساعدة للمشرفين.'
                '📝 مهلة مسودة الأخبار صارت ساعتين بدل نصف ساعة، وقابلة للضبط من الإعدادات.'
                'وعند انتهاء المهلة تُعاد إليك الأخبار نصًّا بدل إبلاغك بعددها فقط.'
                '⏱ المدد تُكتب بالساعات: «20 ساعة» بدل «1200 دقيقة».'
            ) }
        @{ Version = '5.7.0'; Items = @(
                '📰 الخبر الجديد يُضاف الآن في أول الشريط لا آخره (يمكن عكسه من الإعدادات).'
                '➕ إضافة قالب صارت تقبل مسار المشهد الحقيقي: قرص، أو شبكة، أو %PROGRAMDATA%.'
                'ويمكن إعطاء اسم جهاز مثل logo بدل رقم الطبقة، مع تنبيه إن كانت الطبقة مستخدَمة.'
                'وخطوة أخيرة اختيارية للوصف والتصنيف، تُتخطّى بكلمة واحدة.'
                '⚙️ أوامر المشرفين لم تعد تظهر في قائمة الأوامر لغير المشرفين.'
                '👑 صلاحية المالك: هو وحده من يعيّن المشرفين أو يخفضهم، من شاشة 👥 المستخدمون.'
                'المالك افتراضيًا أول مشرف في config، ويمكن تحديده صراحةً بـ OwnerUserIds.'
                'الترقية والخفض بتأكيد، ويصل إشعار للمستخدم بتغيّر صلاحيته.'
                'لا يمكن خفض المالك ولا آخر مشرف، ولا ترقية مستخدم غير مصرّح له.'
            ) }
        @{ Version = '5.6.1'; Items = @(
                'إصلاح: لم يعد الشريط الإخباري والشعار يُبلَّغ عنهما كـ«قالب قديم على الهواء» وهما يعملان سليمَين.'
                'الجسر صار يقرأ المدّة التي حدّدها Cinegy للقالب — ٢٤ ساعة للشريط — ويحترمها.'
                'ويمكن تعليم أي قالب بـ longRunning في ملف القوالب ليُعفى دائمًا.'
                'صحة Cinegy لم تعد تتقلّب بسبب إطار واحد مفقود؛ صار لها هامش تسامح قابل للضبط.'
            ) }
        @{ Version = '5.6.0'; Items = @(
                'إصلاح: زر ♻️ إعادة التشغيل يعمل الآن حين يكون البوت مشغَّلًا يدويًا — يعيد نفسه في نفس النافذة.'
                'أسماء أزرار القوالب صارت الاسم وحده، بلا أرقام ولا تواريخ مقطوعة.'
                'التفاصيل (الطبقة، التصنيف، الحقول، آخر استخدام) في شاشة ℹ️ بجانب كل قالب.'
                '🕘 ماذا فاتني صارت تقول ماذا عُرض ومَن عرضه ومتى، وما الذي فشل ولماذا.'
                'تأكيد قبل إخفاء قالب على الهواء، فلا تُخفيه بضغطة واحدة.'
                'دعم طبقة الشعار الخاصة في Cinegy عبر خيار device في القالب.'
                'قائمة ترتيب الأخبار صارت مقسّمة صفحات — كل الأخبار قابلة للوصول، بما فيها الأخير.'
                'خيار جديد: قائمة أخبار واحدة طويلة بدل الصفحات — أطفئ «قائمة الأخبار على صفحات».'
                'القائمة الطويلة تعرض ٢١ خبرًا في الشاشة بدل ١٠، وما زاد يبقى على صفحات لأن تيليجرام لا يقبل أكثر.'
                'حذف خبر مباشرة من قائمة الترتيب مع تأكيد.'
            ) }
        @{ Version = '5.5.0'; Items = @(
                'شريط الأخبار: عند تعارض الملف يمكنك الإضافة إلى النص الحالي أو استبداله.'
                'طلب فكّ قفل المسودة من زميل، مع مهلة للرد ومنح تلقائي بعدها.'
                'تُعاد إليك أخبار مسودتك نصًّا قبل تسليم القفل.'
                'إصلاح: مسودة قديمة كانت تمنع النشر إلى الأبد — صار لها مهلة.'
            ) }
        @{ Version = '5.4.0'; Items = @(
                'إصلاح: لم يعد يظهر قالب وهمي على الهواء عند الإقلاع.'
                'التراجع صار يشمل العرض على طبقة فارغة — يزيله بضغطة.'
                'عند التعارض يظهر اسم من يجهّز الطبقة ومنذ متى.'
                'بعد التراجع يسألك عن السبب — لتحسين التدريب لاحقًا.'
                '🕘 ماذا فاتني و/who لمعرفة من استخدم قالبًا ومتى.'
                'تنبيه عند تكرار القالب ثلاث مرات في ساعة.'
                'وضع ليلي يؤجّل التنبيهات غير العاجلة، ونافذة صيانة تلقائية.'
                'وضع اليد الواحدة، واختصار بكتابة اسم القالب مباشرة.'
            ) }
        @{ Version = '5.3.0'; Items = @(
                '📷 لقطة الآن بجانب صفّ الهواء — تتحقق من الشاشة دون مغادرة المحادثة.'
                '📋 نسخ الحالة: ملخص نصّي جاهز للإرسال إلى المخرج.'
                '📈 أرقام التشغيل و/stats للمشرف: مدة التشغيل وحصيلة العمليات.'
                'تنبيه قبل الحدث المجدول بثلاث دقائق، مع حالة Cinegy.'
            ) }
        @{ Version = '5.2.0'; Items = @(
                'زر ↩️ تراجع صار يظهر في القائمة الرئيسية طوال مهلته، لا في رسالة العملية فقط.'
                'المشرف يستطيع العرض على طبقة محجوزة مع تنبيه؛ المشغّل ما زال ممنوعًا.'
                'تنبيه عندما يستبدل حدث مجدول مشهدًا موجودًا على الهواء.'
                '📊 ملخص الاستخدام: أكثر القوالب استخدامًا وحصيلة العمليات، عند الطلب وأسبوعيًا.'
                '📤 تصدير و📥 استيراد الإعدادات لنقلها بين الأجهزة بلا توكن ولا قائمة مستخدمين.'
            ) }
        @{ Version = '5.1.0'; Items = @(
                'القائمة تبدأ بما هو على الهواء، وتحته زر إخفاء الكل مباشرة.'
                'سطر أعلى القائمة يقول ما هو على الهواء ومتى تم آخر تحقّق منه.'
                'أدوات الإدارة صارت في شاشة مستقلة لتقصير القائمة الرئيسية.'
                'يمكن تفعيل تأكيد قبل الإخفاء والخروج يعرض اسم القالب ومدّته ومَن أرسله.'
                'مراقبة تلقائية لصورة المخرج: عند تأكيد شاشة سوداء بلقطتين يصل تنبيه.'
                'تنبيه للمشرفين عن أي قالب بقي مسجّلًا على الهواء مدة طويلة.'
                'الملفات التي ترفعها تُحذف تلقائيًا بعد مدة قابلة للضبط.'
                'زر «فحص المسار الحي» يختبر دورة عرض وإخفاء كاملة على طبقة التجربة.'
            ) }
        @{ Version = '5.0.1'; Items = @(
                'إصلاح: الخروج من مشهد كان يترك سجلًا دائمًا يوهم بأن القالب ما زال على الهواء.'
            ) }
        @{ Version = '5.0.0'; Items = @(
                'استقرار أعلى عند انقطاع Cinegy: لم يعد البوت يتجمّد في انتظاره.'
                'الرسائل لم تعد تُفقد عند ازدحام Telegram.'
                'رفض ضبط طبقة التجربة على طبقة يستخدمها قالب إنتاج.'
            ) }
        @{ Version = '4.x — ملخص'; Items = @(
                'الأساس: عرض القوالب بحقول نصية، وإخفاء وخروج، وتحديث النص أثناء العرض.'
                '⭐ المفضّلة و🔁 التكرار و⏱ العرض المؤقّت و📅 الجدولة بتكرار يومي وأسبوعي.'
                '📰 إدارة شريط الأخبار بمسودة ومعاينة ونسخ احتياطية.'
                '📸 لقطات من البث و▶️ البث المباشر إلى Telegram.'
                '🎚 لوحة الطبقات تقارن Cinegy بسجل الجسر وتكتشف المشاهد الخارجية.'
                '👥 إدارة المستخدمين والأسماء وطلبات الوصول، مع سجل تدقيق دائم.'
                '🛡️ وضع الصيانة وحماية الأسرار وتقييد صلاحيات الملفات.'
            ) }
    )
}

function Get-WhatsNewText {
    <# The whole history as one string. Get-WhatsNewParts is what the screen
       actually sends; this stays for anything that wants the lot. #>
    param([int]$Skip = 0, [int]$Take = 0, [switch]$NoHeading)
    $sections = @(Get-WhatsNewSections)
    if ($Skip -gt 0) { $sections = @($sections | Select-Object -Skip $Skip) }
    if ($Take -gt 0) { $sections = @($sections | Select-Object -First $Take) }

    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not $NoHeading) { $lines.Add("🆕 ما الجديد — الإصدار الحالي $($script:BridgeVersion)") }
    else { $lines.Add('🆕 ما الجديد — الإصدارات الأقدم') }
    foreach ($section in $sections) {
        $lines.Add('')
        $lines.Add("▪️ $($section.Version)")
        foreach ($item in $section.Items) { $lines.Add("• $item") }
    }
    $lines.Add('')
    $lines.Add('السجل التقني الكامل في ملف CHANGELOG.md مع الإصدار.')
    return ($lines -join "`n")
}

function Get-WhatsNewParts {
    <# The newest few releases, then everything older behind 📄 المزيد. Split
       at a version boundary rather than at a character count, so the first
       screen ends where a release ends instead of mid-sentence. #>
    param([int]$LeadVersions = 3)
    $total = @(Get-WhatsNewSections).Count
    $parts = @((Get-WhatsNewText -Take $LeadVersions))
    if ($total -gt $LeadVersions) { $parts += (Get-WhatsNewText -Skip $LeadVersions -NoHeading) }
    return $parts
}

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
            ) }
        @{ Key = 'stop'; Title = '🛑 الإنهاء والطوارئ'; AdminOnly = $false; Body = @(
                '🔴 صفوف أعلى القائمة هي ما يراه الجسر على الهواء الآن.'
                '↳ اضغط الصف لإخفاء تلك الطبقة مباشرة.'
                '🚨 إخفاء الكل: يعرض الطبقات ثم يطلب تأكيدًا قبل التنفيذ.'
                '🚪 خروج من المشهد: يشغّل نهاية المشهد بدل القطع الفوري.'
                '↳ عند تفعيل التأكيد يظهر اسم القالب ومدّته ومَن أرسله قبل التنفيذ.'
                ''
                '⚡ الإخفاء والخروج لهما أولوية على العرض داخل الدفعة نفسها،'
                '   فأمر الطوارئ لا ينتظر خلف عملية عرض.'
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
        @{ Key = 'news'; Title = '📰 شريط الأخبار'; AdminOnly = $false; Body = @(
                'الشريط يُحرَّر كمسودة، ولا يصل الهواء إلا بالنشر.'
                ''
                '✏️ بدء التحرير: يفتح مسودة ويقفلها باسمك حتى لا يعدّلها اثنان معًا.'
                '➕ إضافة خبر · 📝 تعديل وترتيب · 👁 معاينة.'
                '✅ مراجعة ونشر: يعرض ما سيتغيّر ثم ينشر.'
                '📥 استيراد TXT: ملف نصي يحل محل المسودة أو يُضاف إليها.'
                '🕘 النسخ والاستعادة: كل نشر يحفظ نسخة يمكن الرجوع إليها.'
                ''
                '📊 ⬇️ سحب ونشر و📝 سحب إلى المسودة يجلبان الشيت (إن ضُبط'
                '   رابطه). التفاصيل في باب «📊 الربط مع Google Sheets».'
                ''
                '🔒 إن كانت المسودة بيد زميل: 🔓 طلب فكّ القفل يرسل له طلبًا.'
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
        @{ Key = 'track'; Title = '🔍 المتابعة والتحقق'; AdminOnly = $false; Body = @(
                'ℹ️ الحالة: ملخص سريع لخادم Air والقناة والقوالب المتابعة.'
                '🎚 الطبقات: يفحص Cinegy مباشرة ويقارنه بسجل الجسر.'
                '↳ لكل طبقة: ظاهر أو خارجي أو مخفي أو غير معروف.'
                '📸 صورة من البث: لقطة حديثة من خرج القناة.'
                '🧾 عملياتي: آخر عملياتك مع إعادة المحاولة ومرجع كل عملية.'
                '🕘 ماذا فاتني: ما جرى أثناء غيابك ومَن نفّذه.'
                '📊 تقارير: البنرات والأخبار خلال فترة، مع تحميل ملف.'
                '🆕 ما الجديد: ملخص تغييرات الإصدارات الأخيرة.'
                ''
                '⚠️ السطر أعلى القائمة يذكر متى تحقّق الجسر آخر مرة.'
                '↳ إن ظهر تحذير هناك فالمعلومة قد لا تطابق الشاشة — تأكد بلقطة.'
            ) }
        @{ Key = 'admin'; Title = '🛡️ أدوات المشرف'; AdminOnly = $true; Body = @(
                '⚙️ الإعدادات و👤 طلبات الوصول: في القائمة الرئيسية.'
                '🗂 أدوات الإدارة تجمع الباقي:'
                '↳ 👥 المستخدمون، ⚡ النصوص الجاهزة، 📚 القوالب.'
                '↳ ▶️ البث المباشر و🔗 رابط البث.'
                '↳ 📜 السجل و🧪 التشخيص و🛠 الأمر الخام.'
                '🩺 مركز الصحة: Telegram وCinegy والمخرج والتخزين والجدولة'
                '   في شاشة واحدة، ومعها 🗂 ملفات التشغيل وسطر الاستخدام.'
                '🧪 فحص المسار الحي: دورة عرض وإخفاء كاملة على طبقة التجربة'
                '   تُبلّغ بنتيجة كل خطوة. تحتاج TemplateTestLayer غير مستخدمة.'
                '📤/📥 الإعدادات: نقل التهيئة بين الأجهزة. التصدير بلا توكن'
                '   ولا قائمة مستخدمين، والاستيراد يعرض ما سيتغيّر قبل تطبيقه.'
                '♻️ إعادة تشغيل الجسر: بتأكيد، وبعد التحقق من وجود خدمة تعيده.'
                ''
                '🖤 مراقبة المخرج — كيف تعرف أن البث شغّال:'
                "↳ الجسر يلتقط لقطة من خرج القناة كل $(Format-DurationMinutes -Minutes (Get-SettingInt 'OutputMonitorMinutes' 1))."
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
        @{ Key = 'trouble'; Title = '🆘 حين يحدث خطأ'; AdminOnly = $false; Body = @(
                'الشاشة تقول «فشل» ولا تعرف السبب:'
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
        $track.Body += '📊 الحالة الكاملة: للمشرف والمالك؛ تفحص المصدر يدوياً وتوضح حالة سيرفر المتابعة.'
    }

    return @($chapters | Where-Object { -not $_.AdminOnly -or $isAdmin })
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
    foreach ($chapter in $chapters) {
        $body = @(@($chapter.Body) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { @{ type = 'paragraph'; text = [string]$_ } })
        # A details block with nothing in it renders as a control that opens
        # onto blank space, which reads as a chapter that failed to load.
        if ($body.Count -eq 0) { continue }
        $blocks += @{ type = 'details'; summary = [string]$chapter.Title; blocks = $body }
    }
    return $blocks
}

function Get-MyOperationsBlocks {
    <#
        The operation history as a list rather than a table.

        Deliberately not a table: the line that matters most here is the copy
        that actually reached the screen, and it is a sentence. The banner
        report leaves that column out for exactly this reason - a column wide
        enough for it squeezes every other one to nothing - so where the copy
        IS the point, the grid is the wrong shape and a list is the right one.
    #>
    param([Parameter(Mandatory)][long]$UserId)
    $history = @(Get-UserOperationHistory -UserId $UserId | Select-Object -Last 10)
    $blocks = @(@{ type = 'heading'; text = '🧾 آخر عملياتك'; size = 3 })
    if ($history.Count -eq 0) {
        $blocks += @{ type = 'paragraph'; text = 'لم تُسجَّل لك عمليات بعد.' }
        return $blocks
    }

    $items = @()
    foreach ($item in $history) {
        $icon = switch ([string]$item.Result) { 'success' { '✅' } 'blocked' { '⛔' } default { '❌' } }
        $sentence = Get-OperationSentence -Action ([string]$item.Action) -Result ([string]$item.Result) -Target ([string]$item.Target)
        $inner = @(@{ type = 'paragraph'; text = "$icon $(([datetime]$item.At).ToString('HH:mm')) — $sentence" })

        $category = Get-TemplateCategoryLabel -Key ([string]$item.Target)
        if ($category) { $inner += @{ type = 'paragraph'; text = "🏷 $category" } }
        $onAirText = [string](Get-JsonProp $item 'Values')
        if ($onAirText) { $inner += @{ type = 'paragraph'; text = "📝 $onAirText" } }
        $reference = Get-OperationReference -OperationId ([string]$item.OperationId)
        if ($reference) { $inner += @{ type = 'paragraph'; text = "🔖 مرجع $reference" } }
        $advice = switch ([string]$item.Result) {
            'failed' { 'افحص الاتصال ثم أعد المحاولة' }
            'blocked' { 'راجع صلاحيتك أو حالة Cinegy' }
            default { '' }
        }
        if ($advice) { $inner += @{ type = 'paragraph'; text = "↳ $advice" } }
        $items += @{ blocks = $inner }
    }
    # The three newest stay open and the rest fold. Ten operations, each
    # carrying its copy and its reference, is a screen nobody scrolls to the
    # end of - and the one being looked for is almost always the last one.
    $recent = @($items | Select-Object -Last 3)
    $older = @($items | Select-Object -First ([math]::Max(0, $items.Count - 3)))
    $blocks += @{ type = 'list'; items = $recent }
    if ($older.Count -gt 0) {
        $blocks += @{ type = 'details'; summary = "عمليات أقدم ($($older.Count))"; blocks = @(@{ type = 'list'; items = $older }) }
    }
    return $blocks
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
    $lines = @("📖 $($chapter.Title)", '━━━━━━━━━━━━━━') + @($chapter.Body) +
        @('', "الباب $($index + 1) من $($chapters.Count)")
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
        '📘 دليل بوت Cinegy Air'
        "الإصدار $($script:BridgeVersion)"
        ''
        'اختر ما تريد معرفته:'
        ''
    )
    foreach ($chapter in $chapters) { $lines += "• $($chapter.Title)" }
    $lines += @('', '🚀 جديد على البوت؟ ابدأ بـ«بداية سريعة».')
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
    $lines.Add('📘 دليل بوت Cinegy Air')
    $lines.Add("الإصدار $($script:BridgeVersion)")
    $lines.Add('')
    foreach ($chapter in @(Get-HelpChapters -ChatId $ChatId -UserId $UserId)) {
        $lines.Add('━━━━━━━━━━━━━━━━')
        $lines.Add([string]$chapter.Title)
        $lines.Add('━━━━━━━━━━━━━━━━')
        foreach ($line in @($chapter.Body)) { $lines.Add([string]$line) }
        $lines.Add('')
    }
    return (($lines -join "`n").TrimEnd())
}

function New-AirOperationContext {
    param([Parameter(Mandatory)][ValidateSet('SHOW', 'HIDE', 'EXIT', 'UPDATE')][string]$Action, [int]$Layer = 0, [long]$UserId = 0)
    $id = "air-$([guid]::NewGuid().ToString('N'))"
    Add-BridgeOperation -Ledger $script:BridgeOperationLedger -OperationId $id -Action $Action -Layer $Layer -ActorId $UserId | Out-Null
    return [pscustomobject]@{
        Id        = $id
        Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
}

function Start-AirOperation {
    param([Parameter(Mandatory)]$Operation, [Parameter(Mandatory)][ValidateSet('SHOW', 'HIDE', 'EXIT', 'UPDATE')][string]$Action, [int]$Layer = 0, [long]$UserId = 0)
    Start-BridgeOperation -Ledger $script:BridgeOperationLedger -OperationId $Operation.Id -Action $Action -Layer $Layer -ActorId $UserId | Out-Null
}

function Get-TemplateTestReviewKeyboard {
    return @{ inline_keyboard = @(
        , @((New-Button '🧪 نعم، اختبر القالب' 'tadm:testconfirm' -Style success), (New-Button '❌ إلغاء' 'menu:templatesadmin'))
    ) }
}

function Format-AuditTemplateValues {
    <# The text that actually reached the screen, folded into one short line
       for the audit record. Without it a report can only say which template
       ran, never what it said - and audit.jsonl is the only permanent record.

       Capped and switchable: this file is archived and never deleted, so the
       operator decides whether on-air copy belongs in it forever. #>
    param([hashtable]$Variables = @{})
    if (-not (Get-Setting 'AuditTemplateValues')) { return '' }
    if ($null -eq $Variables -or $Variables.Count -eq 0) { return '' }
    $parts = foreach ($name in @($Variables.Keys | Sort-Object)) {
        $value = ([string]$Variables[$name] -replace '[\r\n]+', ' ').Trim()
        if ($value) { "${name}: $value" }
    }
    $text = (@($parts) -join ' | ')
    $max = Get-SettingInt 'AuditTemplateValuesMaxChars' 1
    if ($text.Length -gt $max) { $text = $text.Substring(0, $max) + '…' }
    return $text
}

function Write-AirOperationResult {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][ValidateSet('SHOW', 'HIDE', 'EXIT', 'UPDATE')][string]$Action,
        [Parameter(Mandatory)][ValidateSet('success', 'failed', 'blocked')][string]$Result,
        [Parameter(Mandatory)][long]$DurationMs,
        [Parameter(Mandatory)][long]$UserId,
        [Parameter(Mandatory)][long]$ChatId,
        [int]$Layer = 0,
        [string]$Target = '',
        [string]$ErrorText = '',
        [string]$Values = ''
    )
    $cleanTarget = ($Target -replace '[\r\n]+', ' ').Replace('"', "'")
    $cleanError = ($ErrorText -replace '[\r\n]+', ' ').Replace('"', "'")
    $displayName = [string](Get-UserDisplayName -UserId $UserId)
    $cleanUserName = if ($displayName -eq [string]$UserId) { '' } else {
        Protect-SensitiveText ((($displayName -replace '[\r\n]+', ' ').Trim()).Replace('"', "'"))
    }
    $message = "AIR_OP id=$OperationId action=$Action result=$Result durationMs=$DurationMs user=$UserId chat=$ChatId layer=$Layer target=`"$cleanTarget`""
    if ($cleanUserName) { $message += " userName=`"$cleanUserName`"" }
    if (-not [string]::IsNullOrWhiteSpace($cleanError)) { $message += " error=`"$cleanError`"" }
    $level = if ($Result -eq 'success') { 'INFO' } else { 'WARN' }
    $counterName = switch ($Result) { 'success' { 'Success' }; 'failed' { 'Failed' }; default { 'Blocked' } }
    $script:AirOperationCounters[$counterName] = [int]$script:AirOperationCounters[$counterName] + 1
    Complete-BridgeOperation -Ledger $script:BridgeOperationLedger -OperationId $OperationId -Result $Result -ErrorText $ErrorText | Out-Null
    Add-UserOperationHistory -OperationId $OperationId -Action $Action -Result $Result -DurationMs $DurationMs -UserId $UserId -Layer $Layer -Target $Target -Values $Values
    Write-AuditRecord -OperationId $OperationId -EventName air_control -Result $Result -UserId $UserId -UserName $cleanUserName -ChatId $ChatId -Action $Action -Layer $Layer -Target $Target -DurationMs $DurationMs -Message $ErrorText -Values $Values
    Write-BridgeLog $message $level
}

function Test-MaintenanceWindowActive {
    <# The nightly slot when the playout machine is patched or re-cabled. An
       unset or malformed window is no window: this must never fail closed and
       silently block control of a live channel. #>
    return (Test-BridgeMaintenanceWindow -Now (Get-Date) `
            -StartTime ([string](Get-Setting 'MaintenanceWindowStart')) `
            -EndTime ([string](Get-Setting 'MaintenanceWindowEnd')))
}

function Test-MaintenanceControl {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId, [switch]$EmergencyOverride)
    $manual = [bool](Get-Setting 'MaintenanceMode')
    $scheduled = Test-MaintenanceWindowActive
    if (-not $manual -and -not $scheduled) { return $true }
    # The emergency override still works during a scheduled window: a machine
    # being patched is no reason an administrator cannot pull a graphic that
    # is wrongly on air.
    if ($EmergencyOverride -and (Test-Admin -ChatId $ChatId -UserId $UserId)) { return $true }
    $reason = if ($scheduled -and -not $manual) {
        "🛠 نافذة الصيانة المجدولة مفتوحة ($([string](Get-Setting 'MaintenanceWindowStart'))–$([string](Get-Setting 'MaintenanceWindowEnd')))؛ أوامر الهواء متوقفة حتى نهايتها."
    }
    else { '🛠 وضع الصيانة مفعّل؛ أوامر التحكم في الهواء متوقفة مؤقتًا.' }
    Send-TelegramMessage -ChatId $ChatId -Text $reason -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    return $false
}

function Test-TemplateShowPolicy {
    <# A reserved layer normally carries something that must not be disturbed -
       a station logo, a clock, a permanent ticker. Administrators may still
       push to one deliberately, since they are who reserved it; operators
       cannot. Pass -IsAdmin only where the caller has actually checked. #>
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][int]$Layer, [switch]$IsAdmin)
    $reserved = @()
    foreach ($part in ([string](Get-Setting 'ReservedLayers') -split '[,;\s]+')) {
        $parsedLayer = 0
        if ([int]::TryParse($part.Trim(), [ref]$parsedLayer) -and $parsedLayer -gt 0) { $reserved += $parsedLayer }
    }
    if ($reserved -contains $Layer -and -not $IsAdmin) {
        return [pscustomobject]@{ Allowed = $false; Reason = "الطبقة $Layer محجوزة إداريًا."; Warning = '' }
    }
    if ($reserved -contains $Layer) {
        return [pscustomobject]@{ Allowed = $true; Reason = ''; Warning = "⚠️ الطبقة $Layer محجوزة — تتجاوزها بصلاحية المشرف." }
    }
    $disabled = @([string](Get-Setting 'DisabledTemplateKeys') -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (@($disabled | Where-Object { $_.Equals($Key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        return [pscustomobject]@{ Allowed = $false; Reason = "القالب '$Key' معطّل مؤقتًا."; Warning = '' }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = ''; Warning = '' }
}

function Get-EffectiveAutoHideSeconds {
    param(
        [Parameter(Mandatory)][string]$Key,
        [int]$RequestedSeconds = 0
    )
    $sensitiveKeys = @([string](Get-Setting 'SensitiveTemplateKeys') -split '[,;\r\n]+' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $isSensitive = @($sensitiveKeys | Where-Object { $_.Equals($Key, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if (-not $isSensitive) { return [math]::Max(0, $RequestedSeconds) }
    $requiredSeconds = Get-SettingInt 'SensitiveTemplateAutoHideSeconds' 1
    if ($RequestedSeconds -gt 0) { return [math]::Min($RequestedSeconds, $requiredSeconds) }
    return $requiredSeconds
}

function Copy-ShowVariables {
    param([hashtable]$Variables = @{})
    $copy = @{}
    foreach ($name in $Variables.Keys) { $copy[[string]$name] = [string]$Variables[$name] }
    return $copy
}

function Set-RollbackCandidate {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][hashtable]$RestoreSnapshot,
        [Parameter(Mandatory)][ValidateSet('replace','hidden')][string]$ExpectedState,
        [string]$ExpectedActiveId = '',
        [Parameter(Mandatory)][long]$ActorUserId
    )
    if (-not (Get-Setting 'EnableSafeRollback')) { return }
    $window = [math]::Max(10, [math]::Min(900, (Get-SettingInt 'RollbackWindowSeconds' 10)))
    $script:RollbackCandidates[$Layer] = @{
        Id=[guid]::NewGuid().ToString('N'); Layer=$Layer; Restore=$RestoreSnapshot
        ExpectedState=$ExpectedState; ExpectedActiveId=$ExpectedActiveId
        ActorUserId=$ActorUserId; CreatedAt=(Get-Date); ExpiresAt=(Get-Date).AddSeconds($window)
    }
}

function Get-RollbackCandidate {
    param([Parameter(Mandatory)][int]$Layer, [long]$UserId = 0)
    if (-not (Get-Setting 'EnableSafeRollback')) { return $null }
    if (-not $script:RollbackCandidates.ContainsKey($Layer)) { return $null }
    $candidate = $script:RollbackCandidates[$Layer]
    if ((Get-Date) -ge [datetime]$candidate.ExpiresAt) { $script:RollbackCandidates.Remove($Layer) | Out-Null; return $null }
    if ($UserId -gt 0 -and [long]$candidate.ActorUserId -ne $UserId -and -not (Test-Admin -ChatId $UserId -UserId $UserId)) { return $null }
    return $candidate
}

function Get-CorrelatedLayerSnapshot {
    param([Parameter(Mandatory)][int]$Layer, $LiveStatus)
    if (-not $script:LastSuccessfulLayerShows.ContainsKey($Layer) -or -not $LiveStatus -or
        -not $LiveStatus.Success -or $LiveStatus.IsOnAir -ne $true) { return $null }
    $snapshot = $script:LastSuccessfulLayerShows[$Layer]
    $activeId = [string](Get-JsonProp $LiveStatus 'ActiveId')
    if ([string]::IsNullOrWhiteSpace($activeId) -or $activeId -ne [string]$snapshot.ActiveId) { return $null }
    return $snapshot
}

function Get-VerifiedCinegyShowIdentity {
    <#
        Resolve the engine's active item while the successful SHOW operation is
        still in hand. This is the only safe moment to translate Cinegy's
        client EventId into its engine ActiveId: a later watchdog observation
        may already describe a replacement and must never inherit old work.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$TemplatePath = '',
        [Parameter(Mandatory)][int]$Layer,
        [AllowEmptyString()][string]$ExpectedPreviousActiveId = '',
        [AllowEmptyString()][string]$ExpectedActiveId = '',
        [switch]$AllowAnonymousActiveId
    )
    $failed = { param([string]$Reason) [pscustomobject]@{ Success=$false; ActiveId=''; Error=$Reason } }
    $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -Layer $Layer `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not [bool](Get-JsonProp $status 'Success') -or -not [bool](Get-JsonProp $status 'IsOnAir')) {
        return (& $failed 'لم يؤكد Cinegy أن المشهد على الهواء بعد SHOW.')
    }
    $activeId = [string](Get-JsonProp $status 'ActiveId')
    $normalizedId = $activeId.Trim().Trim('{', '}')
    if ([string]::IsNullOrWhiteSpace($normalizedId) -or $normalizedId -eq '00000000-0000-0000-0000-000000000000') {
        return (& $failed 'لم يعرض Cinegy معرّفًا نشطًا صالحًا.')
    }

    $expectedPreviousId = ([string]$ExpectedPreviousActiveId).Trim().Trim('{', '}')
    $expectedCurrentId = ([string]$ExpectedActiveId).Trim().Trim('{', '}')

    # Prefer the filename parsed from Cinegy's active-item description. Falling
    # back to ActiveName is allowed only as an exact name, never a substring.
    $reported = [string](Get-JsonProp $status 'ActiveTemplateName')
    if ([string]::IsNullOrWhiteSpace($reported)) { $reported = [string](Get-JsonProp $status 'ActiveName') }
    if ([string]::IsNullOrWhiteSpace($reported)) {
        # Some Cinegy items expose a valid engine identity but no Name or
        # Description. Accept that shape only when the id itself proves the
        # relation: it is either the already-confirmed id for a manual timer,
        # or a new id observed immediately after this bridge's SHOW.
        if ($AllowAnonymousActiveId -and
            ((-not [string]::IsNullOrWhiteSpace($expectedCurrentId) -and
              $normalizedId.Equals($expectedCurrentId, [StringComparison]::OrdinalIgnoreCase)) -or
             (-not [string]::IsNullOrWhiteSpace($expectedPreviousId) -and
              -not $normalizedId.Equals($expectedPreviousId, [StringComparison]::OrdinalIgnoreCase)))) {
            return [pscustomobject]@{ Success=$true; ActiveId=$activeId; Error=''; IdentitySource='active-id-correlation' }
        }
        return (& $failed 'لم يعرض Cinegy اسم قالب يمكن مطابقته.')
    }
    $reported = $reported.Trim()
    $reportedWithoutExtension = [IO.Path]::GetFileNameWithoutExtension($reported)
    $expected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expected.Add($Key.Trim()) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($TemplatePath)) {
        $expected.Add([IO.Path]::GetFileName($TemplatePath).Trim()) | Out-Null
        $expected.Add([IO.Path]::GetFileNameWithoutExtension($TemplatePath).Trim()) | Out-Null
    }
    if (-not ($expected.Contains($reported) -or $expected.Contains($reportedWithoutExtension))) {
        return (& $failed "اسم المشهد الذي أعاده Cinegy لا يطابق '$Key'.")
    }
    return [pscustomobject]@{ Success=$true; ActiveId=$activeId; Error=''; IdentitySource='template-name' }
}

function Invoke-ShowTemplateResult {
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Variables = @{},
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [int]$AutoHideSeconds = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $AutoHideSeconds = Get-EffectiveAutoHideSeconds -Key $Key -RequestedSeconds $AutoHideSeconds
    $operation = New-AirOperationContext -Action SHOW -UserId $UserId
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target $Key -ErrorText 'maintenance mode'
        return [pscustomobject]@{ Success = $false; Error = 'وضع الصيانة مفعّل.' }
    }
    $store = Get-TemplateStore
    if (-not $store.Map.ContainsKey($Key)) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب '$Key' غير معروف." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target $Key -ErrorText 'unknown template'
        return
    }
    $template = $store.Map[$Key]
    $attemptVariables = @{}
    foreach ($variableName in $Variables.Keys) { $attemptVariables[[string]$variableName] = [string]$Variables[$variableName] }
    $script:LastShowAttempts[[string]$UserId] = @{
        Key = $Key; Variables = $attemptVariables; AutoHideSeconds = $AutoHideSeconds
    }
    $policy = Test-TemplateShowPolicy -Key $Key -Layer ([int]$template.Layer) -IsAdmin:(Test-Admin -ChatId $ChatId -UserId $UserId)
    if (-not $policy.Allowed) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لم يتم الإرسال: $($policy.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -ErrorText ([string]$policy.Reason)
        return [pscustomobject]@{ Success = $false; Error = [string]$policy.Reason }
    }

    # SHOW is the only operation that can replace visible content. Verify the
    # target layer immediately before mutating it; an unreachable Cinegy must
    # never be interpreted as an empty or safe layer.
    $layerStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -Layer ([int]$template.Layer) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    if (-not $layerStatus.Success) {
        $errorText = [string](Get-JsonProp $layerStatus 'Error')
        Write-BridgeLog "Blocked SHOW '$Key' on layer $($template.Layer): live Cinegy verification failed: $errorText" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لم يتم الإرسال: تعذّر التحقق من حالة طبقة Cinegy $($template.Layer). أعد فحص الحالة ثم حاول مجددًا." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -ErrorText $errorText
        return [pscustomobject]@{ Success = $false; Error = 'تعذّر التحقق من حالة طبقة Cinegy.' }
    }
    $layerStatus | Add-Member -NotePropertyName Layer -NotePropertyValue ([int]$template.Layer) -Force
    Update-OnAirStateFromCinegy -Reason 'before-show' -LayerStatuses @($layerStatus) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1) -DiscoverExternal | Out-Null
    $previousSnapshot = Get-CorrelatedLayerSnapshot -Layer ([int]$template.Layer) -LiveStatus $layerStatus

    # A scene that is already loaded on the layer keeps running with the values
    # it was started with, so a second SHOW can leave the PREVIOUS text on air.
    # Taking the layer down first forces the scene to initialise with the new
    # variables. (To change text without re-firing the animation, use the
    # ✏️ تحديث نص button, which writes to the live postbox instead.)
    $operationStarted = $false
    if ((Get-Setting 'ReshowClearsLayer') -and $script:OnAir.ContainsKey([int]$template.Layer)) {
        Start-AirOperation -Operation $operation -Action SHOW -Layer ([int]$template.Layer) -UserId $UserId
        $operationStarted = $true
        $clear = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $template.Layer -TimeoutSec (Get-AirTimeout)
        if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air pre-show HIDE on layer $($template.Layer): success=$($clear.Success)" }
    }

    # Only pass through explicit per-field type overrides; everything else
    # takes the AirVariableType default.
    $types = @{}
    foreach ($name in @($template.FieldTypes.Keys)) {
        if ($template.FieldTypes[$name]) { $types[$name] = [string]$template.FieldTypes[$name] }
    }
    $defaultType = [string](Get-Setting 'AirVariableType')
    if ([string]::IsNullOrWhiteSpace($defaultType)) { $defaultType = 'Text' }

    if (-not $operationStarted) { Start-AirOperation -Operation $operation -Action SHOW -Layer ([int]$template.Layer) -UserId $UserId }
    $result = Show-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
        -Layer $template.Layer -TemplatePath $template.Path -Variables $Variables `
        -Types $types -DefaultType $defaultType -TimeoutSec (Get-AirTimeout)

    # Air Pro answers 200 OK even when it does not recognise a variable name,
    # so "Success" only means the request was accepted - not that the text
    # landed. Turn on LogAirXml to see exactly what was transmitted.
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air SHOW XML: $($result.Xml)" }

    if ($result.Success) {
        $reminderMinutes = [int](Get-JsonProp $template 'ReminderMinutes')
        $activeId = [string]$result.EventId
        $activeIdConfirmed = $false
        # Capture Cinegy's engine id for every successful SHOW. The old bridge
        # kept the client EventId, which happened to work until Cinegy returned
        # a different identity. An anonymous active item is accepted only when
        # its engine id changed from the pre-SHOW item.
        $identity = Get-VerifiedCinegyShowIdentity -Key $Key -TemplatePath ([string](Get-JsonProp $template 'Path')) `
            -Layer ([int]$template.Layer) -ExpectedPreviousActiveId ([string](Get-JsonProp $layerStatus 'ActiveId')) `
            -AllowAnonymousActiveId
        if ($identity.Success) { $activeId = [string]$identity.ActiveId; $activeIdConfirmed = $true }
        if ($previousSnapshot) {
            Set-RollbackCandidate -Layer ([int]$template.Layer) -RestoreSnapshot $previousSnapshot `
                -ExpectedState replace -ExpectedActiveId $activeId -ActorUserId $UserId
        }
        elseif ($layerStatus.Success -and $false -eq [bool]$layerStatus.IsOnAir) {
            # Pushing onto a layer that was genuinely EMPTY used to leave
            # nothing to undo, which is the commonest mistake there is: the
            # wrong template, on a layer that had nothing on it. Undoing that
            # means taking it back off, so the restore is a hide.
            #
            # Only when the layer was verifiably empty. If correlation failed -
            # something the bridge cannot identify was on that layer - a hide
            # would silently discard it rather than restore anything, so no
            # undo is offered and the operator decides deliberately.
            Set-RollbackCandidate -Layer ([int]$template.Layer) `
                -RestoreSnapshot @{ Key = [string]$Key; Action = 'hide' } `
                -ExpectedState replace -ExpectedActiveId $activeId -ActorUserId $UserId
        }
        else { $script:RollbackCandidates.Remove([int]$template.Layer) | Out-Null }
        # Three of the same graphic in an hour is almost always a paste slip or
        # a double tap. Asked after the push, never before: blocking a repeat
        # that was deliberate would be worse than the mistake it prevents.
        if (Test-RepeatedShow -Key ([string]$Key)) {
            Send-TelegramMessage -ChatId $ChatId -Text "🔁 تكرار غير معتاد: عُرض '$Key' عدة مرات خلال فترة قصيرة.`nهل هذا مقصود؟ إن لم يكن، اضغط ↩️ تراجع من القائمة."
        }
        $script:LastSuccessfulLayerShows[[int]$template.Layer] = @{
            Key=$Key; Variables=(Copy-ShowVariables -Variables $Variables); UserId=$UserId; ChatId=$ChatId
            ActiveId=$activeId; ActiveIdConfirmed=$activeIdConfirmed; At=(Get-Date)
        }
        $script:LastShow[$ChatId] = @{ Key = $Key; Variables = $Variables }
        Set-OnAirShownRecord -Layer ([int]$template.Layer) -Record @{
            Key = $Key; At = (Get-Date); UserId = $UserId; ActiveId = $activeId
            ActiveIdConfirmed = $activeIdConfirmed
        }
        Save-OnAirState
        Add-UsageCount -Key $Key
        $actor = Format-UserAuditActor -UserId $UserId
        Write-BridgeLog "User $actor (chat $ChatId) pushed template '$Key' (layer $($template.Layer))"
        Add-AuditEntry "▶ $Key (طبقة $($template.Layer)) - بواسطة $actor"

        # Belt and braces: also write the values through the postbox, which is
        # the channel this scene actually honours.
        if ((Get-Setting 'SetValuesAfterShow') -and $Variables.Count -gt 0) {
            $delay = Get-SettingInt 'PostShowDelayMs' 0
            $script:PostShowQueue.Add(@{
                    At = (Get-Date).AddMilliseconds($delay); Values = $Variables
                    Layer = [int]$template.Layer; Key = $Key
                })
        }

        $suffix = ""
        if ($AutoHideSeconds -gt 0) {
            $timerSaved = $activeIdConfirmed -and (Set-AutoHideTimer -Layer ([int]$template.Layer) -Seconds $AutoHideSeconds `
                    -ChatId $ChatId -UserId $UserId -TemplateKey $Key -ActiveId $activeId -ActiveIdConfirmed $true)
            $suffix = if (-not $activeIdConfirmed) {
                " ⚠️ لم يُضبط الإخفاء التلقائي لأن Cinegy لم يؤكد هوية المشهد؛ أخفه يدويًا."
            }
            elseif ($timerSaved) {
                " سيُخفى تلقائيًا بعد $AutoHideSeconds ثانية."
            }
            else {
                " ⚠️ تعذّر حفظ مؤقت الإخفاء؛ أخفه يدويًا."
            }
        }
        if (-not [bool](Get-JsonProp $template 'LongRunning') -and $reminderMinutes -gt 0) {
            if (-not $activeIdConfirmed) {
                $suffix += ' ⚠️ لم يُضبط تنبيه الظهور لأن Cinegy لم يؤكد هوية المشهد.'
            }
            elseif (Set-TemplateReminder -Template $template -ChatId $ChatId -UserId $UserId -ActiveId $activeId -ActiveIdConfirmed $true) {
                $suffix += " سيصل إليك تنبيه شخصي بعد $reminderMinutes دقيقة إذا بقي القالب ظاهرًا."
            }
            else {
                $suffix += ' ⚠️ تعذّر حفظ تنبيه ظهور القالب لإعادة التشغيل.'
            }
        }
        else {
            # A new SHOW replaces the visible scene on its layer, so any old
            # operator reminder for that layer must never reach the wrong person.
            Remove-TemplateRemindersForLayer -Layer ([int]$template.Layer) | Out-Null
        }
        # A one-tap hide right where the operator is looking: previously taking
        # something back off air meant going 🙈 -> pick layer, which is several
        # taps too many when a wrong graphic is live.
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم إظهار '$Key' على الهواء (طبقة $($template.Layer)).$suffix" -ReplyMarkup (Get-AfterShowKeyboard -Layer ([int]$template.Layer) -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -Values (Format-AuditTemplateValues -Variables $Variables)
    }
    else {
        Write-BridgeLog "User $(Format-UserAuditActor -UserId $UserId) failed to push template '$Key': $($result.Error)" "ERROR"
        Write-AirOperationResult -OperationId $operation.Id -Action SHOW -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer ([int]$template.Layer) -Target $Key -ErrorText ([string]$result.Error)
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل إظهار '$Key': $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    return $result
}

function Get-LayerShowContext {
    param([Parameter(Mandatory)][int]$Layer, [datetime]$Now = (Get-Date))
    $record = if ($script:OnAir.ContainsKey($Layer)) { $script:OnAir[$Layer] } else { $null }
    $lastSuccess = if ($script:RuntimeState.Monitoring.LastCinegyStateSuccess -gt [datetime]::MinValue) { $script:RuntimeState.Monitoring.LastCinegyStateSuccess } else { $null }
    $freshness = Get-CinegyStateFreshness -LastSuccessfulAt $lastSuccess -FailedCount 0 -Now $Now `
        -StaleAfterSeconds (Get-SettingInt 'CinegyStateStaleSeconds' 45)
    return [pscustomobject]@{
        IsKnown = ($freshness.State -eq 'connected')
        IsOnAir = ($null -ne $record)
        Key      = if ($record) { [string](Get-JsonProp $record 'Key') } else { '' }
        UserId   = if ($record) { [long](Get-JsonProp $record 'UserId') } else { 0L }
        Source   = if ($record) { [string](Get-JsonProp $record 'Source') } else { '' }
    }
}

function Start-ShowFlow {
    <# Entry point for every SHOW source. ReviewImmediately is used when values
       already came from a preset or typed command; required missing fields
       still force the ordinary field-entry flow. #>
    param(
        [Parameter(Mandatory)][int]$TemplateIndex,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [int]$AutoHideSeconds = 0,
        [hashtable]$InitialValues = @{},
        [switch]$ReviewImmediately
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    Clear-PendingState -ChatId $ChatId
    $t = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $t) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب غير معروف (ربما تغيّر ملف القوالب). افتح 📋 القوالب من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $policy = Test-TemplateShowPolicy -Key ([string]$t.Key) -Layer ([int]$t.Layer) -IsAdmin:(Test-Admin -ChatId $ChatId -UserId $UserId)
    if (-not $policy.Allowed) {
        Send-TelegramMessage -ChatId $ChatId -Text "⛔ لا يمكن تجهيز العرض: $($policy.Reason)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $AutoHideSeconds = Get-EffectiveAutoHideSeconds -Key ([string]$t.Key) -RequestedSeconds $AutoHideSeconds
    $lock = Lock-GfxLayer -Layer ([int]$t.Layer) -ChatId $ChatId -UserId $UserId -Key ([string]$t.Key)
    if (-not $lock.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text "$(Get-LayerLockNotice -Layer ([int]$t.Layer) -UserId $UserId)`nانتظر أو اختر قالبًا على طبقة أخرى." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $replacementContext = Get-LayerShowContext -Layer ([int]$t.Layer)
    $draftValues = @{}
    foreach ($name in $InitialValues.Keys) { $draftValues[[string]$name] = [string]$InitialValues[$name] }
    $required = @(Get-JsonProp $t 'FieldRequired' | Where-Object { $null -ne $_ })
    $canReviewImmediately = [bool]$ReviewImmediately
    if ($canReviewImmediately) {
        for ($i = 0; $i -lt $t.Fields.Count; $i++) {
            if ($i -lt $required.Count -and [bool]$required[$i]) {
                $fieldName = [string]$t.Fields[$i]
                if (-not $draftValues.ContainsKey($fieldName) -or [string]::IsNullOrWhiteSpace([string]$draftValues[$fieldName])) {
                    $canReviewImmediately = $false
                    break
                }
            }
        }
    }
    if ($t.Fields.Count -eq 0 -or $canReviewImmediately) {
        $state = @{
            Mode = 'show_review'; Key = $t.Key; Fields = @($t.Fields); Labels = @($t.FieldLabels)
            Limits = @($t.FieldLimits); Required = $required
            Sensitives = @(Get-JsonProp $t 'FieldSensitive' | Where-Object { $null -ne $_ })
            Index = 0; Values = $draftValues; UserId = $UserId; AutoHideSeconds = $AutoHideSeconds
            LockLayer = [int]$t.Layer; ReplacementContext = $replacementContext
        }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text (Format-ShowReviewText -State $state) -ReplyMarkup (Get-ShowReviewKeyboard -HasFields)
        return
    }
    $state = @{
        Mode = 'show_fields'; Key = $t.Key; Fields = @($t.Fields); Labels = @($t.FieldLabels)
        Limits = @($t.FieldLimits)
        Required = $required
        Sensitives = @(Get-JsonProp $t 'FieldSensitive' | Where-Object { $null -ne $_ })
        Index = 0; Values = $draftValues; UserId = $UserId; AutoHideSeconds = $AutoHideSeconds
        LockLayer = [int]$t.Layer; ReplacementContext = $replacementContext
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text (Get-FieldPromptText -State $state) -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
}

function Resume-ShowFlow {
    <# Called for each text reply (or the ⏭ skip button) while a show_fields
       flow is pending. Advances one field, or fires the template once full.

       -Skip omits the field from the variable set entirely rather than sending
       an empty string, so the scene keeps whatever text it was designed with
       instead of being blanked. #>
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "", [switch]$Skip)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $isRequired = $state.Required -and $state.Index -lt @($state.Required).Count -and [bool]$state.Required[$state.Index]
    if ($isRequired -and ($Skip -or [string]::IsNullOrWhiteSpace($Value))) {
        $message = if ($Skip) { "❌ هذا الحقل مطلوب ولا يمكن تخطيه." } else { "❌ هذا الحقل مطلوب ولا يمكن تركه فارغًا." }
        Send-TelegramMessage -ChatId $ChatId -Text $message -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
        return
    }
    if (-not $Skip) {
        # Re-prompt rather than push oversized text: a pasted paragraph would
        # otherwise go straight to air and wreck the graphic's layout.
        $limit = 0
        if ($state.Limits -and $state.Index -lt @($state.Limits).Count) { $limit = [int]$state.Limits[$state.Index] }
        if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-FieldPromptKeyboard -State $state))) { return }
        $fieldName = [string]$state.Fields[$state.Index]
        $state.Values[$fieldName] = $Value
        $isSensitive = Test-SensitiveFieldName -FieldName $fieldName
        if ($state.ContainsKey('Sensitives') -and $state.Index -lt @($state.Sensitives).Count) {
            $isSensitive = $isSensitive -or [bool]$state.Sensitives[$state.Index]
        }
        Add-RecentFieldValue -UserId ([long]$state.UserId) -FieldName $fieldName -Value $Value -Sensitive:$isSensitive
    }
    $state.Index++

    if ($state.Index -ge $state.Fields.Count) {
        $state.Mode = 'show_review'
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text (Format-ShowReviewText -State $state) -ReplyMarkup (Get-ShowReviewKeyboard)
        return
    }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text (Get-FieldPromptText -State $state) -ReplyMarkup (Get-FieldPromptKeyboard -State $state)
}

function Format-ShowReviewText {
    param([Parameter(Mandatory)][hashtable]$State)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("🔎 مراجعة قبل الإرسال")
    $lines.Add("القالب: $($State.Key)")
    $lines.Add("الطبقة: $($State.LockLayer)")
    $context = Get-JsonProp $State 'ReplacementContext'
    if ($context -and -not [bool](Get-JsonProp $context 'IsKnown')) {
        $lines.Add("⚠️ تعذّر التحقق من حداثة حالة الطبقة؛ راجع شاشة الحالة قبل التأكيد عند الشك.")
    }
    if ($context -and [bool](Get-JsonProp $context 'IsOnAir')) {
        $currentKey = [string](Get-JsonProp $context 'Key')
        if ([string]::IsNullOrWhiteSpace($currentKey)) { $currentKey = 'مشهد غير مسمّى' }
        $currentUserId = [long](Get-JsonProp $context 'UserId')
        $sourceText = if ([string](Get-JsonProp $context 'Source') -eq 'cinegy') { 'Cinegy Air' } elseif ($currentUserId -gt 0) { "المستخدم $(Get-UserDisplayName -UserId $currentUserId)" } else { 'Bot' }
        $lines.Add("⚠️ سيتم استبدال القالب الحالي: $currentKey ($sourceText).")
    }
    # A structural clash, distinct from the runtime one above: these templates
    # can never be on air together, whether or not the layer is busy right now.
    $sharedLayers = Get-JsonProp (Get-TemplateStore) 'SharedLayers'
    $layerKey = [string]$State.LockLayer
    if ($sharedLayers -and $sharedLayers.Contains($layerKey)) {
        $siblings = @(@($sharedLayers[$layerKey]) | Where-Object { $_ -ne [string]$State.Key })
        if ($siblings.Count -gt 0) {
            $lines.Add("⚠️ هذه الطبقة يتشاركها أيضًا: $($siblings -join '، ') — لا يمكن عرضها مع هذا القالب في الوقت نفسه.")
        }
    }
    if ($State.AutoHideSeconds -gt 0) { $lines.Add("الإخفاء التلقائي: $($State.AutoHideSeconds) ثانية") }
    $lines.Add("")
    for ($i = 0; $i -lt @($State.Fields).Count; $i++) {
        $name = [string]$State.Fields[$i]
        $label = $name
        if ($State.Labels -and $i -lt @($State.Labels).Count -and $State.Labels[$i]) { $label = [string]$State.Labels[$i] }
        $value = if ($State.Values.ContainsKey($name)) { [string]$State.Values[$name] } else { "(متروك)" }
        $lines.Add("• $label`: $value")
    }
    $lines.Add("")
    $lines.Add("لن يُرسل شيء إلى Cinegy حتى تضغط تأكيد الإرسال.")
    return ($lines -join "`n")
}

function Get-EffectiveFieldLimit {
    <# Resolution order: per-field maxLength -> per-template maxLength -> the
       global MaxFieldLength setting. A graphic's usable text length depends on
       its design, so one global number is a floor, not the whole answer. #>
    param([int]$FieldLimit = 0)
    if ($FieldLimit -gt 0) { return $FieldLimit }
    return (Get-SettingInt 'MaxFieldLength' 0)
}

function Test-FieldLength {
    <# Returns $true when the text is short enough to put on air, otherwise
       tells the operator and returns $false. The pending flow is deliberately
       left intact so they can simply retype the value. #>
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][long]$ChatId,
        [int]$FieldLimit = 0,
        [hashtable]$ReplyMarkup
    )
    $max = Get-EffectiveFieldLimit -FieldLimit $FieldLimit
    $visibleLength = Get-TextElementCount -Text $Value
    if ($max -le 0 -or $visibleLength -le $max) { return $true }
    if (-not $ReplyMarkup) { $ReplyMarkup = Get-FieldPromptKeyboard }
    Send-TelegramMessage -ChatId $ChatId -Text "❌ النص طويل جدًا ($visibleLength حرفًا) والحد الأقصى $max حرفًا. أرسل نصًا أقصر." -ReplyMarkup $ReplyMarkup
    return $false
}

function Get-FieldPromptText {
    <# Shows the operator-friendly label when templates.json provides one,
       falling back to the raw variable name (e.g. "Ajel.center") otherwise. #>
    param([Parameter(Mandatory)][hashtable]$State)
    $index = [int]$State.Index
    $name = [string]$State.Fields[$index]
    $label = $name
    if ($State.Labels -and $index -lt @($State.Labels).Count -and $State.Labels[$index]) {
        $label = "$($State.Labels[$index])`n($name)"
    }
    # Tell the operator the limit up front rather than rejecting after typing.
    $limit = 0
    if ($State.Limits -and $index -lt @($State.Limits).Count) { $limit = [int]$State.Limits[$index] }
    $limit = Get-EffectiveFieldLimit -FieldLimit $limit
    $limitText = if ($limit -gt 0) { " (الحد: $limit حرفًا)" } else { "" }
    return "القالب '$($State.Key)' - أرسل نص الحقل ($($index + 1)/$($State.Fields.Count))$limitText`:`n$label"
}

function Sync-LayerAfterOperatorAction {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][string]$Reason)
    $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress `
        -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
    return Update-OnAirStateFromCinegy -Reason $Reason -LayerStatuses @($status) `
        -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
}

function Invoke-HideLayer {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0,
        [switch]$Quiet,
        [switch]$MaintenanceOverride
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext -Action HIDE -Layer $Layer -UserId $UserId
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId -EmergencyOverride:$MaintenanceOverride)) {
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -ErrorText 'maintenance mode'
        return $false
    }
    $rollbackSnapshot = $null
    if (-not $Quiet -and (Get-Setting 'EnableSafeRollback')) {
        $preHideStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $rollbackSnapshot = Get-CorrelatedLayerSnapshot -Layer $Layer -LiveStatus $preHideStatus
    }
    Start-AirOperation -Operation $operation -Action HIDE -Layer $Layer -UserId $UserId
    $result = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-AirTimeout)
    if ($result.Success) {
        if ($rollbackSnapshot) { Set-RollbackCandidate -Layer $Layer -RestoreSnapshot $rollbackSnapshot -ExpectedState hidden -ActorUserId $UserId }
        Sync-LayerAfterOperatorAction -Layer $Layer -Reason 'after-hide' | Out-Null
        $actor = Format-UserAuditActor -UserId $UserId
        Write-BridgeLog "User $actor hid layer $Layer"
        Add-AuditEntry "🙈 إخفاء طبقة $Layer - بواسطة $actor"
        if (-not $Quiet) { Send-TelegramMessage -ChatId $ChatId -Text "✅ تم إخفاء الطبقة $Layer." -ReplyMarkup (Get-AfterLayerRemovalKeyboard -Layer $Layer -ChatId $ChatId -UserId $UserId) }
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer
    }
    elseif (-not $Quiet) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل إخفاء الطبقة $Layer : $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
    }
    if (-not $result.Success) {
        Write-AirOperationResult -OperationId $operation.Id -Action HIDE -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Invoke-ExitLayer {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext -Action EXIT -Layer $Layer -UserId $UserId
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -ErrorText 'maintenance mode'
        return $false
    }
    $rollbackSnapshot = $null
    if (Get-Setting 'EnableSafeRollback') {
        $preExitStatus = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $rollbackSnapshot = Get-CorrelatedLayerSnapshot -Layer $Layer -LiveStatus $preExitStatus
    }
    Start-AirOperation -Operation $operation -Action EXIT -Layer $Layer -UserId $UserId
    $result = Exit-TitlerScene -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-AirTimeout)
    if ($result.Success) {
        if ($rollbackSnapshot) { Set-RollbackCandidate -Layer $Layer -RestoreSnapshot $rollbackSnapshot -ExpectedState hidden -ActorUserId $UserId }
        # Dropped directly rather than reconciled: Cinegy keeps the playlist
        # item Active after EXIT_SCENE_LOOP, so a status read here cannot tell
        # an exited scene from a live one and would preserve the record for
        # ever. See Remove-OnAirRecord.
        Remove-OnAirRecord -Layer $Layer -Reason 'after-exit' | Out-Null
        $actor = Format-UserAuditActor -UserId $UserId
        Write-BridgeLog "User $actor exited scene on layer $Layer"
        Add-AuditEntry "🚪 خروج من مشهد طبقة $Layer - بواسطة $actor"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم الخروج من المشهد على الطبقة $Layer." -ReplyMarkup (Get-AfterLayerRemovalKeyboard -Layer $Layer -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل الخروج من المشهد على الطبقة $Layer : $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action EXIT -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Layer $Layer -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Start-SafeRollbackReview {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $candidate = Get-RollbackCandidate -Layer $Layer -UserId $UserId
    if (-not $candidate) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا يوجد تراجع صالح لهذه الطبقة، أو انتهت مدته.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $snapshot = $candidate.Restore
    $expected = if ([string]$candidate.ExpectedState -eq 'hidden') { 'يجب أن تبقى الطبقة فارغة' } else { 'يجب أن يبقى المشهد الحالي نفسه دون تغيير خارجي' }
    Set-PendingState -ChatId $ChatId -State @{ Mode='safe_rollback_review'; UserId=$UserId; Layer=$Layer; CandidateId=[string]$candidate.Id }
    Send-TelegramMessage -ChatId $ChatId -Text "↩️ مراجعة التراجع الآمن`nالطبقة: $Layer`nسيُستعاد القالب: $($snapshot.Key)`nشرط التنفيذ: $expected`nتنتهي الصلاحية: $(([datetime]$candidate.ExpiresAt).ToString('HH:mm:ss'))`n`nسيُفحص Cinegy مباشرة بعد التأكيد." -ReplyMarkup (Get-RollbackReviewKeyboard -Layer $Layer)
}

function Confirm-SafeRollback {
    param([Parameter(Mandatory)][int]$Layer, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or [string]$state.Mode -ne 'safe_rollback_review' -or [long]$state.UserId -ne $UserId -or [int]$state.Layer -ne $Layer) { return }
    $candidate = Get-RollbackCandidate -Layer $Layer -UserId $UserId
    Clear-PendingState -ChatId $ChatId
    if (-not $candidate -or [string]$candidate.Id -ne [string]$state.CandidateId) {
        Send-TelegramMessage -ChatId $ChatId -Text 'انتهى أو تغير مرشح التراجع. لم يُرسل شيء.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) { return }
    $lock = Lock-GfxLayer -Layer $Layer -ChatId $ChatId -UserId $UserId -Key ([string]$candidate.Restore.Key)
    if (-not $lock.Success) {
        Send-TelegramMessage -ChatId $ChatId -Text 'الطبقة قيد عملية أخرى؛ لم يُنفذ التراجع.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    try {
        $status = Get-TitlerLayerStatus -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber `
            -Layer $Layer -TimeoutSec (Get-SettingInt 'CinegyMonitorTimeoutSeconds' 1)
        $safe = $status.Success -and $null -ne $status.IsOnAir
        if ($safe -and [string]$candidate.ExpectedState -eq 'hidden') { $safe = -not [bool]$status.IsOnAir }
        elseif ($safe) {
            $activeId = [string](Get-JsonProp $status 'ActiveId')
            $safe = [bool]$status.IsOnAir -and -not [string]::IsNullOrWhiteSpace($activeId) -and $activeId -eq [string]$candidate.ExpectedActiveId
        }
        if (-not $safe) {
            $script:RollbackCandidates.Remove($Layer) | Out-Null
            Send-TelegramMessage -ChatId $ChatId -Text '⛔ تغيرت حالة Cinegy أو تعذر التحقق منها؛ أُلغي التراجع ولم يُرسل شيء.' -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
            return
        }
        $restore = $candidate.Restore
        # Undoing a push onto a previously empty layer means clearing it again,
        # not restoring a scene that was never there.
        if ([string](Get-JsonProp $restore 'Action') -eq 'hide') {
            $hidden = Hide-TitlerTemplate -AirServerAddress $config.AirServerAddress `
                -AirChannelNumber $config.AirChannelNumber -Layer $Layer -TimeoutSec (Get-AirTimeout)
            if ($hidden.Success) {
                Remove-OnAirRecord -Layer $Layer -Reason 'undo of show onto an empty layer' | Out-Null
                $actor = Format-UserAuditActor -UserId $UserId
                Add-AuditEntry "↩️ تراجع: أُزيل $($restore.Key) من طبقة $Layer - بواسطة $actor"
                Write-BridgeLog "User $actor undid the show of '$($restore.Key)' on layer $Layer" 'WARN'
                # Asked now, not later: in ten seconds they will have moved on.
                $script:PendingCancelReason = @{ UserId = $UserId; Key = [string]$restore.Key; At = (Get-Date) }
                Send-TelegramMessage -ChatId $ChatId -Text "↩️ أُزيل '$($restore.Key)' من الطبقة $Layer.
ما السبب؟ (اختياري)" -ReplyMarkup (Get-CancelReasonKeyboard)
            }
            else {
                Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر التراجع: $($hidden.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
            }
            return
        }
        $result = Invoke-ShowTemplateResult -Key ([string]$restore.Key) -Variables ([hashtable]$restore.Variables) -ChatId $ChatId -UserId $UserId
        if ($result -and $result.Success) {
            $actor = Format-UserAuditActor -UserId $UserId
            Add-AuditEntry "↩️ تراجع آمن إلى $($restore.Key) على طبقة $Layer - بواسطة $actor"
            Write-BridgeLog "User $actor safely rolled layer $Layer back to '$($restore.Key)'" 'WARN'
        }
    }
    finally { Unlock-GfxLayer -ChatId $ChatId -Layer $Layer }
}

function Invoke-HideAllLayers {
    <# Emergency "get it off air" button - hides only the layers selected by
       the administrator. #>
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $maintenanceOverride = Test-Admin -ChatId $ChatId -UserId $UserId
    $layers = @(Get-HideAllTargetLayers)
    if ($layers.Count -eq 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لا توجد طبقات محددة لإخفاء الكل. يضبطها المشرف من الإعدادات." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $ok = @(); $failed = @()
    foreach ($l in $layers) {
        if (Invoke-HideLayer -Layer $l -ChatId $ChatId -UserId $UserId -Quiet -MaintenanceOverride:$maintenanceOverride) { $ok += $l } else { $failed += $l }
    }
    $script:AutoHideQueue.Clear()
    $actor = Format-UserAuditActor -UserId $UserId
    Write-BridgeLog "User $actor triggered HIDE ALL (ok: $($ok -join ','); failed: $($failed -join ','))" "WARN"
    Add-AuditEntry "🚨 إخفاء الكل - بواسطة $actor"
    $text = "🚨 تم إخفاء الطبقات: $($ok -join ', ')"
    if ($failed.Count -gt 0) { $text += "`n❌ فشلت: $($failed -join ', ')" }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Invoke-SetValues {
    param([Parameter(Mandatory)][hashtable]$Values, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $operation = New-AirOperationContext -Action UPDATE -UserId $UserId
    if (-not (Test-MaintenanceControl -ChatId $ChatId -UserId $UserId)) {
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result blocked -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',') -ErrorText 'maintenance mode'
        return $false
    }
    Start-AirOperation -Operation $operation -Action UPDATE -UserId $UserId
    $result = Send-PostboxValues -AirServerAddress $config.AirServerAddress -AirChannelNumber $config.AirChannelNumber -Values $Values -TimeoutSec (Get-AirTimeout)
    if (Get-Setting 'LogAirXml') { Write-BridgeLog "Air POSTBOX XML: $($result.Xml)" }
    if ($result.Success) {
        $actor = Format-UserAuditActor -UserId $UserId
        Write-BridgeLog "User $actor set values: $($Values.Keys -join ', ')"
        Add-AuditEntry "✏️ تحديث $($Values.Keys -join ', ') - بواسطة $actor"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم التحديث: $($Values.Keys -join ', ')" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result success -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',') -Values (Format-AuditTemplateValues -Variables $Values)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ فشل التحديث: $($result.Error)" -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        Write-AirOperationResult -OperationId $operation.Id -Action UPDATE -Result failed -DurationMs $operation.Stopwatch.ElapsedMilliseconds -UserId $UserId -ChatId $ChatId -Target ($Values.Keys -join ',') -ErrorText ([string]$result.Error)
    }
    return $result.Success
}

function Start-UpdateFieldPrompt {
    param([Parameter(Mandatory)][string]$FieldName, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0, [int]$FieldLimit = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    Set-PendingState -ChatId $ChatId -State @{ Mode = 'update_field'; Field = $FieldName; UserId = $UserId; FieldLimit = $FieldLimit }
    $limit = Get-EffectiveFieldLimit -FieldLimit $FieldLimit
    $limitText = if ($limit -gt 0) { " (الحد: $limit حرفًا)" } else { "" }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل القيمة الجديدة لـ '$FieldName'$limitText`:" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-UpdateField {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $limit = 0
    if ($state.ContainsKey('FieldLimit')) { $limit = [int]$state.FieldLimit }
    if (-not (Test-FieldLength -Value $Value -ChatId $ChatId -FieldLimit $limit -ReplyMarkup (Get-CancelKeyboard))) { return }
    Clear-PendingState -ChatId $ChatId
    Invoke-SetValues -Values @{ $state.Field = $Value } -ChatId $ChatId -UserId $state.UserId
}

function Set-LayerAutoHide {
    <# Attaches (or replaces) an auto-hide timer on a layer that is already on
       air. Replacing rather than stacking matters: two timers on one layer
       would hide it twice, the second one possibly killing a later graphic. #>
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][int]$Seconds,
        [Parameter(Mandatory)][long]$ChatId,
        [long]$UserId = 0
    )
    if ($UserId -eq 0) { $UserId = $ChatId }
    if ($Seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "المدة يجب أن تكون أكبر من صفر." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $current = if ($script:OnAir.ContainsKey($Layer)) { $script:OnAir[$Layer] } else { $null }
    if ($null -eq $current) {
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لا يوجد مشهد مسجّل على الطبقة $Layer؛ لم يُضبط المؤقت." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $currentKey = [string](Get-JsonProp $current 'Key')
    $templatePath = ''
    $store = Get-TemplateStore
    if ($store.Map.ContainsKey($currentKey)) { $templatePath = [string](Get-JsonProp $store.Map[$currentKey] 'Path') }
    $expectedActiveId = ''
    if ($script:LastSuccessfulLayerShows.ContainsKey($Layer)) {
        $lastShow = $script:LastSuccessfulLayerShows[$Layer]
        if ([string](Get-JsonProp $lastShow 'Key') -ieq $currentKey -and
            [bool](Get-JsonProp $lastShow 'ActiveIdConfirmed')) {
            $expectedActiveId = [string](Get-JsonProp $lastShow 'ActiveId')
        }
    }
    if ([string]::IsNullOrWhiteSpace($expectedActiveId) -and
        [bool](Get-JsonProp $current 'ActiveIdConfirmed')) {
        $expectedActiveId = [string](Get-JsonProp $current 'ActiveId')
    }
    $identity = Get-VerifiedCinegyShowIdentity -Key $currentKey -TemplatePath $templatePath -Layer $Layer `
        -ExpectedActiveId $expectedActiveId -AllowAnonymousActiveId
    if (-not $identity.Success) {
        Write-BridgeLog "Refused auto-hide timer on layer $Layer because live identity could not be verified: $($identity.Error)" 'WARN'
        Send-TelegramMessage -ChatId $ChatId -Text "⚠️ لم يُضبط المؤقت: تعذّر ربط المشهد الحالي بهوية Cinegy مؤكدة. أخفه يدويًا عند الحاجة." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $current.ActiveId = [string]$identity.ActiveId
    $current.ActiveIdConfirmed = $true
    Save-OnAirState
    $timerSaved = Set-AutoHideTimer -Layer $Layer -Seconds $Seconds -ChatId $ChatId -UserId $UserId `
        -TemplateKey $currentKey -ActiveId ([string]$identity.ActiveId) -ActiveIdConfirmed $true
    $actor = Format-UserAuditActor -UserId $UserId
    Write-BridgeLog "User $actor set an auto-hide timer of $Seconds s on layer $Layer"
    Add-AuditEntry "⏱ مؤقت $Seconds ث على طبقة $Layer - بواسطة $actor"
    $timerText = if ($timerSaved) {
        "⏱ سيتم إخفاء الطبقة $Layer بعد $(Format-Duration -Seconds $Seconds)."
    }
    else {
        "⚠️ ضُبط مؤقت الطبقة $Layer داخل الجسر، لكن تعذّر حفظه ليستمر بعد إعادة التشغيل."
    }
    Send-TelegramMessage -ChatId $ChatId -Text $timerText -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

function Complete-TimedShowCustom {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $seconds = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$seconds) -or $seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ أرسل رقمًا صحيحًا أكبر من صفر (بالثواني)." -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Start-ShowFlow -TemplateIndex ([int]$state.TemplateIndex) -ChatId $ChatId -UserId $state.UserId -AutoHideSeconds $seconds
}

function Complete-LayerTimerCustom {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value = "")
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    $seconds = 0
    if (-not [int]::TryParse($Value.Trim(), [ref]$seconds) -or $seconds -le 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ أرسل رقمًا صحيحًا أكبر من صفر (بالثواني)." -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    Clear-PendingState -ChatId $ChatId
    Set-LayerAutoHide -Layer ([int]$state.Layer) -Seconds $seconds -ChatId $ChatId -UserId $state.UserId
}

function Invoke-RepeatLastShow {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    if (-not $script:LastShow.ContainsKey($ChatId)) {
        Send-TelegramMessage -ChatId $ChatId -Text "لا يوجد إظهار سابق لإعادته." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $last = $script:LastShow[$ChatId]
    $templateIndex = Get-TemplateIndex -Key ([string]$last.Key)
    if ($templateIndex -lt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب السابق لم يعد موجودًا في ملف القوالب." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    Start-ShowFlow -TemplateIndex $templateIndex -ChatId $ChatId -UserId $UserId -InitialValues $last.Variables
}

function Get-MyOperationsKeyboard {
    param([Parameter(Mandatory)][long]$UserId)
    $rows = @()
    # The reference is eight hex characters an operator quotes to an
    # administrator so one grep finds the line. It was printed in the message
    # and had to be retyped off a phone, one character wrong being one grep
    # that finds nothing; copy_text (Bot API 7.11) puts it on the clipboard.
    # Only the newest one gets a button - ten of them would bury the two
    # controls under a wall of hex.
    $latest = @(Get-UserOperationHistory -UserId $UserId | Select-Object -Last 1)
    if ($latest.Count -gt 0) {
        $reference = Get-OperationReference -OperationId ([string]$latest[0].OperationId)
        if ($reference) {
            $rows += , @(@{ text = "📋 نسخ مرجع $reference"; copy_text = @{ text = $reference } })
        }
    }
    if ($script:LastShowAttempts.ContainsKey([string]$UserId)) {
        $rows += , @((New-Button '🔁 إعادة محاولة آمنة' 'ops:retry'))
    }
    $rows += , @((New-Button '🔄 تحديث' 'menu:myops'), (New-Button '🏠 القائمة' 'menu:main'))
    return @{ inline_keyboard = $rows }
}

function Test-NewsTickerFilePathSetting {
    param([AllowEmptyString()][string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) { return $false }
    if (-not [IO.Path]::GetExtension($Path).Equals('.txt', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    try { [void][IO.Path]::GetFullPath($Path); return $true } catch { return $false }
}

function Get-TemplateCategoryLabel {
    <# The template's own category, when it still exists. A history entry can
       outlive the template it names, so a missing one is normal and silent. #>
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    $index = Get-TemplateIndex -Key $Key
    if ($index -lt 0) { return '' }
    $template = Get-TemplateByIndex -Index $index
    if (-not $template) { return '' }
    return [string](Get-JsonProp $template 'Category')
}

function Get-OperationSentence {
    <# Operator-facing wording for one control action. This screen is read by
       the people pressing the buttons, not by whoever opens bridge.log, so it
       says «عرض» rather than SHOW and never prints a millisecond count. #>
    param([string]$Action, [string]$Result, [string]$Target, [int]$Layer)
    $verb = switch ($Action) {
        'SHOW' { 'عرض' }
        'HIDE' { 'إخفاء' }
        'EXIT' { 'خروج' }
        'UPDATE' { 'تحديث' }
        default { $Action }
    }
    $phrase = switch ($Result) {
        'success' { $verb }
        'blocked' { "رُفض $verb" }
        default { "فشل $verb" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Target)) { $phrase += " «$Target»" }
    if ($Layer -gt 0) { $phrase += " على الطبقة $Layer" }
    return $phrase
}

function Get-OperationReference {
    <# The short half of the AIR_OP correlation id. An operator reporting a
       problem can quote this and an administrator can find the exact line in
       the log with it; the full 32-hex id is unreadable on a phone and nobody
       would retype it. Eight hex characters is 4 billion values against a
       history of at most a few thousand operations. #>
    param([string]$OperationId)
    if ([string]::IsNullOrWhiteSpace($OperationId)) { return '' }
    $hex = $OperationId -replace '^air-', ''
    if ($hex.Length -lt 8) { return '' }
    return $hex.Substring(0, 8)
}

function Invoke-MyOperationsCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    # Structured list first; the text below is what it falls back to.
    if (Send-TelegramRichMessage -ChatId $ChatId -Blocks (Get-MyOperationsBlocks -UserId $UserId) `
            -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)) { return }
    $history = @(Get-UserOperationHistory -UserId $UserId | Select-Object -Last 10)
    if ($history.Count -eq 0) {
        # Not "منذ آخر تشغيل" any more: the history is rebuilt from audit.jsonl
        # at startup, so an empty screen now genuinely means nothing was done.
        Send-TelegramMessage -ChatId $ChatId -Text "🧾 آخر عملياتك`n━━━━━━━━━━━━━━`nلم تُسجَّل لك أي عملية بعد." -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('🧾 آخر عملياتك')
    $lines.Add('━━━━━━━━━━━━━━')
    foreach ($item in $history) {
        $icon = switch ([string]$item.Result) {
            'success' { '✅' }
            'blocked' { '⛔' }
            default { '❌' }
        }
        $stamp = ([datetime]$item.At).ToString('HH:mm')
        $lines.Add("$icon $stamp — $(Get-OperationSentence -Action ([string]$item.Action) -Result ([string]$item.Result) -Target ([string]$item.Target) -Layer ([int]$item.Layer))")

        # What the operator can recognise the graphic by: its category, and
        # above all the text that actually reached the screen.
        $category = Get-TemplateCategoryLabel -Key ([string]$item.Target)
        if ($category) { $lines.Add("      🏷 $category") }
        $onAirText = [string](Get-JsonProp $item 'Values')
        if ($onAirText) { $lines.Add("      📝 $onAirText") }

        # The link back to the log. Shown for every operation, not just
        # failures: when an operator asks "what happened at 21:40" the
        # reference is what turns that into one grep.
        $reference = Get-OperationReference -OperationId ([string]$item.OperationId)
        if ($reference) { $lines.Add("      🔖 مرجع $reference") }

        $advice = switch ([string]$item.Result) {
            'failed' { 'افحص الاتصال ثم أعد المحاولة' }
            'blocked' { 'راجع صلاحيتك أو حالة Cinegy' }
            default { '' }
        }
        if ($advice) { $lines.Add("      ↳ $advice") }
    }
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
}

function Invoke-RetryLastShowAttempt {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $key = [string]$UserId
    if (-not $script:LastShowAttempts.ContainsKey($key)) {
        Send-TelegramMessage -ChatId $ChatId -Text 'لا توجد محاولة عرض قابلة للمراجعة.' -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    $attempt = $script:LastShowAttempts[$key]
    $templateIndex = Get-TemplateIndex -Key ([string]$attempt.Key)
    if ($templateIndex -lt 0) {
        Send-TelegramMessage -ChatId $ChatId -Text 'القالب المستخدم في المحاولة لم يعد موجودًا.' -ReplyMarkup (Get-MyOperationsKeyboard -UserId $UserId)
        return
    }
    Start-ShowFlow -TemplateIndex $templateIndex -ChatId $ChatId -UserId $UserId `
        -InitialValues $attempt.Variables -AutoHideSeconds ([int]$attempt.AutoHideSeconds) -ReviewImmediately
}

function Invoke-PresetShow {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex, [Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $t = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $t -or $PresetIndex -ge $t.Presets.Count) {
        Send-TelegramMessage -ChatId $ChatId -Text "النص الجاهز غير موجود." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $preset = $t.Presets[$PresetIndex]
    $variables = @{}
    for ($i = 0; $i -lt $t.Fields.Count -and $i -lt $preset.Values.Count; $i++) {
        $variables[[string]$t.Fields[$i]] = [string]$preset.Values[$i]
    }
    Start-ShowFlow -TemplateIndex $TemplateIndex -ChatId $ChatId -UserId $UserId -InitialValues $variables -ReviewImmediately
}

function Show-PresetAdminTemplate {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) {
        Send-TelegramMessage -ChatId $ChatId -Text "القالب لم يعد موجودًا." -ReplyMarkup (Get-PresetAdminTemplatesKeyboard)
        return
    }
    Send-TelegramMessage -ChatId $ChatId -Text "⚡ النصوص الجاهزة للقالب '$($template.Key)'`nاختر نصًا لإدارته أو أنشئ نصًا جديدًا:" -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $TemplateIndex)
}

function Show-PresetAdminReview {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][hashtable]$State)
    $actionLabel = switch ([string]$State.Action) {
        'create' { 'إنشاء' }; 'edit' { 'تعديل القيم' }; 'rename' { 'إعادة تسمية' }; 'delete' { 'حذف' }
    }
    $lines = @("🔎 مراجعة تغيير النص الجاهز", "العملية: $actionLabel", "القالب: $($State.TemplateKey)")
    if ($State.Name) { $lines += "الاسم: $($State.Name)" }
    if ($State.Action -in @('create', 'edit')) {
        for ($i = 0; $i -lt @($State.Fields).Count; $i++) {
            $value = if ($i -lt @($State.Values).Count) { [string]$State.Values[$i] } else { '' }
            $lines += "• $($State.Fields[$i]): $value"
        }
    }
    $lines += ''
    $lines += 'لن يُعدّل ملف القوالب حتى تضغط حفظ التغيير.'
    $State.Mode = 'preset_admin_review'
    Set-PendingState -ChatId $ChatId -State $State
    Send-TelegramMessage -ChatId $ChatId -Text ($lines -join "`n") -ReplyMarkup (Get-PresetReviewKeyboard)
}

function Start-PresetAdminCreate {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template) { return }
    Set-PendingState -ChatId $ChatId -State @{
        Mode = 'preset_admin_name'; Action = 'create'; TemplateIndex = $TemplateIndex
        TemplateKey = [string]$template.Key; PresetIndex = -1; UserId = $UserId
        Fields = @($template.Fields); Values = @(); Name = ''; Index = 0
    }
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل اسم النص الجاهز الجديد للقالب '$($template.Key)':" -ReplyMarkup (Get-CancelKeyboard)
}

function Start-PresetAdminEditValues {
    param([Parameter(Mandatory)][int]$TemplateIndex, [Parameter(Mandatory)][int]$PresetIndex, [Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $template = Get-TemplateByIndex -Index $TemplateIndex
    if (-not $template -or $PresetIndex -lt 0 -or $PresetIndex -ge @($template.Presets).Count) { return }
    $state = @{
        Mode = 'preset_admin_values'; Action = 'edit'; TemplateIndex = $TemplateIndex
        TemplateKey = [string]$template.Key; PresetIndex = $PresetIndex; UserId = $UserId
        Fields = @($template.Fields); Values = @(); Name = [string]$template.Presets[$PresetIndex].Name; Index = 0
    }
    if ($state.Fields.Count -eq 0) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
    Set-PendingState -ChatId $ChatId -State $state
    Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل (1/$($state.Fields.Count)):`n$($state.Fields[0])" -ReplyMarkup (Get-CancelKeyboard)
}

function Complete-PresetAdminText {
    param([Parameter(Mandatory)][long]$ChatId, [AllowEmptyString()][string]$Value)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state) { return }
    if ($state.Mode -eq 'preset_admin_name') {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            Send-TelegramMessage -ChatId $ChatId -Text "الاسم لا يمكن أن يكون فارغًا." -ReplyMarkup (Get-CancelKeyboard)
            return
        }
        $state.Name = $Value.Trim()
        if ($state.Action -eq 'rename') { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        $state.Mode = 'preset_admin_values'
        if ($state.Fields.Count -eq 0) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل (1/$($state.Fields.Count)):`n$($state.Fields[0])" -ReplyMarkup (Get-CancelKeyboard)
        return
    }
    if ($state.Mode -eq 'preset_admin_values') {
        $state.Values = @($state.Values) + @([string]$Value)
        $state.Index = [int]$state.Index + 1
        if ($state.Index -ge $state.Fields.Count) { Show-PresetAdminReview -ChatId $ChatId -State $state; return }
        Set-PendingState -ChatId $ChatId -State $state
        Send-TelegramMessage -ChatId $ChatId -Text "أرسل قيمة الحقل ($($state.Index + 1)/$($state.Fields.Count)):`n$($state.Fields[$state.Index])" -ReplyMarkup (Get-CancelKeyboard)
    }
}

function Confirm-PresetAdminChange {
    param([Parameter(Mandatory)][long]$ChatId, [Parameter(Mandatory)][long]$UserId)
    $state = Get-PendingState -ChatId $ChatId
    if (-not $state -or $state.Mode -ne 'preset_admin_review' -or [long]$state.UserId -ne $UserId) {
        Send-TelegramMessage -ChatId $ChatId -Text "انتهت مراجعة التغيير. ابدأ من جديد." -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $templateIndex = [int]$state.TemplateIndex
    $result = Save-TemplatePresetChange -TemplateKey ([string]$state.TemplateKey) -PresetIndex ([int]$state.PresetIndex) -Action ([string]$state.Action) -Name ([string]$state.Name) -Values @($state.Values)
    Clear-PendingState -ChatId $ChatId
    if ($result.Success) {
        Write-BridgeLog "Admin $UserId applied preset $($state.Action) to template '$($state.TemplateKey)'"
        Add-AuditEntry "⚡ Preset $($state.Action) / $($state.TemplateKey) - admin $UserId"
        Send-TelegramMessage -ChatId $ChatId -Text "✅ تم حفظ تغيير النص الجاهز، وأُنشئت نسخة احتياطية." -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $templateIndex)
    }
    else {
        Send-TelegramMessage -ChatId $ChatId -Text "❌ تعذّر حفظ التغيير: $($result.Error)" -ReplyMarkup (Get-PresetAdminKeyboard -TemplateIndex $templateIndex)
    }
}

function Invoke-TemplatesCommand {
    param([Parameter(Mandatory)][long]$ChatId, [long]$UserId = 0)
    if ($UserId -eq 0) { $UserId = $ChatId }
    $store = Get-TemplateStore
    if ($store.Order.Count -eq 0) {
        $text = "لا توجد قوالب معرّفة حاليًا."
        if ($store.Errors.Count -gt 0) { $text += "`n⚠️ " + ($store.Errors -join "`n⚠️ ") }
        Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
        return
    }
    $lines = foreach ($key in $store.Order) {
        $t = $store.Map[$key]
        "$($t.Key) (طبقة $($t.Layer)): $($t.Description)  الحقول: $($t.Fields -join ', ')"
    }
    $text = ($lines -join "`n")
    if ($store.Errors.Count -gt 0) { $text += "`n`n⚠️ " + ($store.Errors -join "`n⚠️ ") }
    Send-TelegramMessage -ChatId $ChatId -Text $text -ReplyMarkup (Get-MainMenuKeyboard -ChatId $ChatId -UserId $UserId)
}

