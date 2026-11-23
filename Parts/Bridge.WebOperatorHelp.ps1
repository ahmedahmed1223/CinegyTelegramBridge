function Invoke-WebOperatorHelp {
    param([System.Collections.IDictionary]$Arguments)

    $actor = 0L
    if (-not [long]::TryParse([string](Get-JsonProp $Arguments 'actor'), [ref]$actor) -or $actor -le 0 -or
        -not (Test-Authorized -ChatId $actor -UserId $actor)) { return @{ ok = $false; error = 'forbidden' } }

    $isAdmin = Test-Admin -ChatId $actor -UserId $actor
    $isOwner = Test-Owner -ChatId $actor -UserId $actor
    $allowedChapters = @{}
    foreach ($chapter in @(Get-HelpChapters -ChatId $actor -UserId $actor)) {
        $key = [string](Get-JsonProp $chapter 'Key')
        if ($key -and ($isAdmin -or -not (Get-JsonProp $chapter 'AdminOnly'))) {
            $allowedChapters[$key] = $true
        }
    }

    # The Bot manual determines chapter availability. Its bodies describe Telegram
    # actions and can interpolate station settings, so the Web copy is explicit.
    $chapters = @(foreach ($topic in @(
                @{ source = 'show'; id = 'templates'; title = 'نشر قالب'; detail = 'افتح قالبًا، أدخل القيم، ثم راجع الطبقة والحقول قبل تأكيد العرض.' }
                @{ source = 'edit'; id = 'air'; title = 'متابعة العرض وإنهاؤه'; detail = 'افتح الطبقة النشطة للتحقق من المشهد. راجع التعديل أو الإخفاء المتاح قبل تأكيده.' }
                @{ source = 'news'; id = 'newsroom'; title = 'غرفة الأخبار'; detail = 'جهّز العواجل والموجز وشريط الأخبار من التبويب المتاح لكل منها.' }
                @{ source = 'time'; id = 'schedule'; title = 'جدولة القوالب'; detail = 'راجع وقت المحطة والطبقة عند تجهيز الموعد. افتح سجل التنفيذ لمعرفة نتيجته.' }
                @{ source = 'track'; id = 'history'; title = 'سجل المناوبة والتقارير'; detail = 'راجع نتائج العمليات، وابحث بمرجع العملية، وافتح تقارير العمل وتسليم المناوبة.' }
                @{ source = 'notices'; id = 'notices'; title = 'التنبيهات'; detail = 'راجع تفضيل إشعارات حساب Telegram المرتبط. تظهر تذكيرات المتابعة الشخصية في شريط الويب حين يحين موعدها.' }
                @{ source = 'settings'; id = 'system'; title = 'صحة الجسر والإعدادات'; detail = 'تحقّق من صحة الخدمات وراجع تغييرات الإعدادات المتاحة قبل حفظها.'; admin = $true }
                @{ source = 'access'; id = 'access'; title = 'وصول مستخدمي Telegram'; detail = 'راجع الطلبات الجديدة، سجل قراراتها، وحالة حسابات المشغّلين.'; admin = $true }
                @{ source = 'access'; id = 'roles'; title = 'أدوار مستخدمي Telegram'; detail = 'افتح حساب المشغّل وراجع الدور الحالي والجديد قبل تأكيد التغيير.'; owner = $true }
                @{ source = 'admin'; id = 'announcements'; title = 'إدارة التعاميم'; detail = 'راجع نص التعميم والجمهور قبل جدولته، وتابع حالة تسليمه.'; admin = $true }
            )) {
            if (-not $allowedChapters.ContainsKey($topic.source) -or ($topic['admin'] -and -not $isAdmin) -or
                ($topic['owner'] -and -not $isOwner)) { continue }
            @{ id = $topic.id; title = $topic.title; detail = $topic.detail }
        })

    # The shared release ledger owns versions and order. A release may mix
    # several audiences in one Bot line, so expose only reviewed Web summaries.
    $publicUpdates = @{
        '9.1.1' = @(
            'افتح صفحة البث لمشاهدة الرابط المضبوط في إعدادات البوت، أو انسخه لمشاركته.'
            'راجع ملخصات الإصدارات الأخيرة من تبويب «ما الجديد» في دليل الويب.'
        )
        '9.1.0' = @(
            'ابدأ مسودة شريط مشتركة ليحرّر عدة مشغّلين سطورًا مختلفة بالتزامن.'
            'تابع العواجل المشتركة بين البوت والويب، وراجع تشغيل الكل أو المحدد ونمط التسلسل قبل البدء.'
            'يصلك إشعار بعد تأكيد عرض العاجل، ويمكن للمشغّل المخوّل إخفاؤه من أيٍّ من الواجهتين.'
        )
        '9.0.0' = @(
            'استخدم جداول غرفة الأخبار العربية مع البحث والترتيب، وتابع البث أثناء التحرير.'
            'أضف صور JPG وPNG إلى حقول الموجز من النافذة نفسها.'
        )
        '8.141.0' = 'اعرض العاجل مباشرة أو بمؤقّت وأخفه من الجدول. حقول التحرير تُكتب من اليمين إلى اليسار.'
        '8.140.0' = 'اختر المظهر الكحلي من قائمة الحساب.'
        '8.137.0' = 'راجع تسجيل مشهد خارجي بديل من نافذة مقارنة الطبقات.'
        '8.135.0' = 'اعرض المادة الجارية والتالية، أو انسخ ملخّص الحالة من لوحة الهواء.'
        '8.130.0' = 'افتح دليل الويب للعثور على خطوات العمل والانتقال إلى الصفحة المناسبة.'
        '8.129.0' = 'راجع حالة المحرك والطبقات من لوحة الهواء.'
        '8.128.0' = 'أكّد تذكير المتابعة الشخصية أو أجّله من صفحة البث.'
        '8.127.0' = 'ابحث بمرجع العملية في سجل المناوبة.'
        '8.126.0' = 'افتح مفضّلة القوالب المشتركة مع Telegram.'
        '8.125.0' = 'افتح تقريري الأسبوع وتسليم المناوبة من سجل العمليات.'
    }
    $adminUpdates = @{
        '8.136.0' = 'اطلب قراءة صحة المحرّك من الإدارة لمراجعة الدخل والإطارات والترخيص.'
        '8.134.0' = 'راجع استعادة الإعدادات أو إعادة تشغيل الجسر تحت إشراف برنامج التحكم من إدارة الويب.'
        '8.133.0' = 'ابحث عن آخر تفاعل لمستخدمي Telegram من شاشة الوصول.'
        '8.132.0' = 'راجع إزالة سجل محلي قديم من نافذة مقارنة الطبقات.'
        '8.131.0' = 'افتح أرقام التشغيل من صفحة صحة الجسر لمتابعة نتائج الأوامر وتسليم إشعارات Telegram.'
        '8.130.0' = 'راجع توقيت المحتوى وملخّص استخدام القوالب من إدارة الويب.'
        '8.129.0' = 'نزّل تقرير التشخيص وراجع جاهزية طبقة الاختبار من إدارة النظام.'
        '8.128.0' = 'راجع الطبقات التي يشملها الإخفاء الشامل.'
        '8.127.0' = 'راجع اسم الطبقة وعدّله من إدارة النظام.'
        '8.126.0' = 'راجع التغييرات قبل استيراد سجل القوالب أو الإعدادات المدعومة.'
        '8.125.0' = 'راجع جاهزية المناوبة وتغطية إشعارات Telegram من إدارة النظام.'
    }
    $versions = @(foreach ($release in @(Get-WhatsNewSections)) {
            $version = [string](Get-JsonProp $release 'Version')
            $items = @()
            if ($publicUpdates.ContainsKey($version)) { $items += @($publicUpdates[$version]) }
            if ($isAdmin -and $adminUpdates.ContainsKey($version)) { $items += [string]$adminUpdates[$version] }
            if ($items.Count -eq 0) { continue }
            @{ version = $version; items = $items }
        })
    $recent = @($versions | Select-Object -First 5)

    return @{ ok = $true; data = @{ chapters = $chapters; releases = $recent } }
}
