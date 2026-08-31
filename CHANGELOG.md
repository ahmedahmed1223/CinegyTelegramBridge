# Changelog

## 6.8.0 — 2026-08-31

- **يضيف «🚀 بداية سريعة»**: بطاقة واحدة تأخذ مشغّلًا لم يفتح البوت من قبل إلى أول قالب على الهواء في ست خطوات، ثم ثلاث قواعد تريحه. ليست قائمة ميزات — من يتسلّم وردية يحتاج الضغطات التي تعمل، والباقي في الفهرس.
- **يحوّل المساعدة إلى فهرس أبواب** بدل شاشة واحدة طويلة. مَن يسأل «كيف أخفي هذا» يريد هذه الإجابة لا أن يمرّ بالجدولة ليصل إليها. ثمانية أبواب للمشغّل وتاسع للمشرف، وكل باب شاشة واحدة.
- داخل كل باب **⬅️ السابق · 📖 الفهرس · ➡️ التالي**، فتبقى القراءة المتسلسلة ممكنة لمن يريد الدليل بترتيبه، دون إجبار الباقين عليها. و**📄 الدليل كاملًا** يبقى كما كان بآلية «المزيد».
- باب المشرف يُحذف من قائمة غير المشرف بدل عرضه مقفلًا، ورقم الباب يُحسب من الأبواب التي يراها القارئ فعلًا.
- **يصلح ثغرة: سحب الشيت كان يتجاوز قفل المسودة.** كسر قفل زميل فعل مشرف في كل شاشات الأخبار («🔓 إلغاء القفل (مشرف)»)، لكن سحب الشيت — بعد فتحه للمشغّلين في `6.6.0` — كان يمحو مسودة الزميل بتأكيد واحد. الآن يُمنع المشغّل ويُوجَّه إلى «🔓 طلب فكّ القفل»، ويبقى التجاوز للمشرف، والزرّان يختفيان أصلًا عمّن لا يملك ذلك.

## 6.7.0 — 2026-08-31

- **يطلب زرّا سحب الشيت تأكيدًا دائمًا**، لا عند التعارض فقط. بعد فتح السحب للمشغّلين في `6.6.0` صارت نقرة واحدة كافية لإعادة كتابة الشريط؛ الآن الضغطة الأولى تسأل والثانية تنفّذ.
- **رسالة تأكيد واحدة تحمل كل الحقائق** بدل «هل أنت متأكد» عامة يتبعها تحذير ثانٍ عن صاحب المسودة: تأكيد النشر يذكر كم خبرًا سيُستبدل على الهواء، وتأكيد المسودة يوضح أن شيئًا لن يصل الهواء قبل «مراجعة ونشر»، وكلاهما يسمّي صاحب المسودة الحالية إن كانت مشغولة.
- `news:sheet` و`news:sheetdraft` صارتا تسألان فقط، والتنفيذ في `news:sheetconfirm` و`news:sheetdraftconfirm` — فصل مقصود حتى لا يكون زر الشاشة هو نفسه الزر المنفّذ.

## 6.6.0 — 2026-08-31

- **يفتح سحب الشيت لكل المشغّلين، لا للمشرفين وحدهم** — الزرّان معًا: «⬇️ سحب ونشر» و«📝 سحب إلى المسودة». المحتوى محكوم بالشيت أصلًا، فالسحب ينشر نسخة تحريرية لا نصًا يكتبه الضاغط.
- يضيف `AllowOperatorsSheetPull` (افتراضيًا `true`) على نمط بقية مفاتيح `AllowOperators*` في قسم الأخبار، فيستطيع المشرف إعادة السحب خلف حاجز الإشراف بإعداد واحد. الفحص مزدوج كما كان: الزر لا يُرسم، والضغط عليه يُرفض — لأن تيليجرام يحتفظ بالأزرار في الرسائل القديمة.
- **يجعل `NewsSheetNotifyScope` افتراضيًا `all`**، فيصل تنبيه ما تغيّر إلى كل المحادثات المصرّح لها بدل المشرفين وحدهم. التنبيه نص للقراءة فقط ولا يمنح أحدًا زرًا ولا صلاحية.

## 6.5.0 — 2026-08-31

- **يضيف «📝 سحب إلى المسودة» بجانب «⬇️ سحب ونشر».** الأول يحمّل الشيت في المسودة ليراجعه المشرف ويرتّبه أو يصحّحه قبل أن يصل الهواء، والثاني ينشر مباشرة كما في `6.4.0`. الاختيار عند كل سحبة، بلا إعداد يُبدَّل.
- التحميل إلى المسودة يمر بمسار الاستيراد العادي، فتنطبق عليه حدود الطول والعدد ورفض التكرار نفسها. ويستبدل محتوى المسودة بدل أن يضيف إليه، فسحبتان متتاليتان لا تُنتجان نسخة مكررة.
- السحب إلى المسودة يعمل حتى حين يكون الشيت مطابقًا لما على الهواء: «لا تغيير» تعني أنه لا شيء لينشر، لا أن المشرف لا يريد مسودة يعمل عليها.
- **يستبدل `NewsSheetNotifyAdmins` بـ`NewsSheetNotifyScope`** بثلاث قيم: `none` أو `admins` (الافتراضي) أو `all`. القيمة الأخيرة تُنبّه كل المحادثات المصرّح لها، لغرفة أخبار تريد أن يرى الجميع ما خرج. إعداد واحد بدل منطقيّ ونطاق يمكن أن يتناقضا؛ المفتاح القديم يبقى غير ضار ويظهر تحت «متقدم».
- السحب إلى المسودة لا يرسل تنبيهًا: لم يصل الهواء شيء بعد.

## 6.4.0 — 2026-08-31

- **يُحدَّث شريط الأخبار من Google Sheets داخل الجسر.** يُضبط رابط تصدير CSV للشيت في `NewsSheetCsvUrl`، فيجلبه الجسر ويحوّله وينشره بنفسه. هذا يُلغي الحاجة إلى Power Automate والسكربت الوسيط معًا، والأهم أنه يُنهي السباق على `news.txt`: كان طرفان يكتبان الملف نفسه، والآن يمر كل نشر عبر `Publish-NewsTickerFile` بنسخته الاحتياطية وتحققه بعد الكتابة وكشف تعارضه.
- **وضعان قابلان للتبديل من الإعدادات:** `manual` (افتراضي) يضيف زر «⬇️ سحب من الشيت» للمشرف في شاشة الأخبار، و`auto` يزامن كل `NewsSheetSyncMinutes` دقيقة. الافتراضي يدوي عمدًا: مهمة غير مراقَبة تعيد كتابة ما على الهواء يجب أن يُشغّلها المشرف عن قصد.
- **المزامنة التلقائية تتنحّى لمن يحرّر.** إن كانت مسودة الأخبار بيد مشغّل، تُتخطّى الدورة وتُعاد المحاولة لاحقًا؛ الكتابة فوق مسودة نصف مكتوبة تُتلف عملًا لا يستعيده صاحبه ولا يعرف سببه. السحب اليدوي فعل مقصود فيمضي، لكنه يسمّي صاحب المسودة ويطلب تأكيدًا أولًا.
- **الشيت الفارغ لا يُنزل الشريط عن الهواء.** شيت لم يُحمَّل، أو أفرغه أحد سهوًا، يُرفض بدل أن يمسح الأخبار؛ المسح يبقى فعلًا يدويًا مؤكَّدًا.
- **يُقرأ الشيت كـCSV حقيقي لا كأسطر نص.** الخلية التي تحوي فاصلة يصدّرها Google بين علامتَي اقتباس، وكان السكربت السابق يضع الاقتباسين على الهواء؛ كما كان يشطر الخلية متعددة الأسطر إلى عنوانين ناقصين. الأعمدة بعد الأول ملاحظات المحرّر ولا تصل الشريط.
- التنزيل عبر https فقط، بمهلة محدودة وسقف بايتات (`NewsImportMaxBytes`)، لأن ما يُنزَّل يصل الهواء.

## 6.3.0 — 2026-08-31

- **يعرض «🧾 عملياتي» مرجعًا قصيرًا لكل عملية** (أول ثمانية محارف من معرّف `AIR_OP`). كان المعرّف داخليًا لا تُظهره شاشة، فلا يملك المشغّل ما يذكره حين يبلّغ عن خلل؛ الآن يقول «مرجع 1fbf8e20» ويجد المشرف سطرها في السجل بحثًا واحدًا. المعرّف الكامل 32 محرفًا لا يُقرأ على الهاتف ولا يعيد أحد كتابته.
- **يضيف شاشة «🗂 ملفات التشغيل»** إلى مركز الصحة (للمشرف): لكل ملف حالة — سليم، أو غير مكتوب بعد، أو تالف بنسخة احتياطية يستعيدها الجسر عند الإقلاع، أو تالف بلا نسخة. «غير مكتوب بعد» ليس عطلًا ولا يُلوَّن أحمر، وإلا تعوّد المشرف على تجاهل الشاشة.
- **يضيف سطر الاستخدام إلى مركز الصحة:** عمليات اليوم، عدد المشغّلين، عدد ما على الهواء، ومدة التشغيل. يُقرأ من الحالة في الذاكرة، فالشاشة ما زالت لا تنفّذ أي probe جديد.
- يؤشّر خطة شريط الأخبار (2026-08-23) بأثر رجعي: الميزة مشحونة منذ مدة والصناديق وحدها كانت متأخرة.

## 6.2.0 — 2026-08-30

- **يقسّم `Tests/Bridge.Tests.ps1`** (8095 سطرًا) إلى تسعة ملفات حسب الموضوع، مع إعداد مشترك واحد في `Tests/Bridge.TestContext.ps1` بدل نسخه في كل ملف. لا اختبار حُذف ولا نص تغيّر؛ النقل بحدود كتل `Describe` كاملة.
- **يضيف اختبارات لمسار الإنتاج في «♻️ استعادة الافتراضي» و«🔎 بحث».** كانت دالتا الوحدة المُختبَرتان محذوفتين ومسار الإنتاج بلا تغطية: التأكيد قبل الكتابة، تجاهل اسم إعداد غير معروف، قصّ نص البحث، وأن ما يظهر على الشاشة هو نتيجة `Find-BridgeSettings` نفسها.
- **يوحّد قراءة `audit.jsonl` في «🕘 ماذا فاتني».** كانت الدالة تعرّف قارئ حقول خاصًا بها وتحلّل الطابع الزمني بـ`TryParse` عاريًا؛ صارت تستدعي `Get-AuditRecordField` و`Read-AuditRecordStamp` مثل بقية القرّاء، فتعامل ختم `Z` بـ`RoundtripKind`.

## 6.1.0 — 2026-08-30

- **يضيف زر «📊 تقارير» بقسمَي البنرات والأخبار.** تقرير البنرات يقرن كل عرض بما أنهاه (إخفاء أو خروج أو استبدال على الطبقة نفسها) فيعرض النص الذي ظهر ومَن عرضه ومدة بقائه؛ وما لم ينتهِ يُعرض «ما زال على الهواء» بلا تخمين مدة. تقرير الأخبار يجمع النشر اليومي ويوزّعه على ناشريه. أربع مدد: اليوم، أمس، 7 أيام، 30 يومًا. المشغّل يرى عملياته، والمشرف والمالك يريان الجميع.
- **يتيح تحميل أي تقرير كملف HTML** مكتفٍ بذاته ومن اليمين إلى اليسار، بلا أي مرجع خارجي لأن آلة الإخراج قد تكون بلا إنترنت. الطباعة إلى PDF تتم من المتصفح مباشرة بعربية سليمة التشكيل. نصوص المشغّل مهرَّبة فلا تتحول إلى وسوم.
- **يسجّل نص القالب الذي ظهر على الهواء** في `audit.jsonl` لعمليتَي العرض والتحديث، بحد أقصى قابل للضبط (`AuditTemplateValuesMaxChars`) وبإمكانية التعطيل (`AuditTemplateValues`) لأن الملف دائم ويُؤرشف. تعرضه شاشة «🧾 عملياتي» مع تصنيف القالب.
- **يوضح «🕘 ماذا فاتني» مَن نفّذ ماذا.** يذكر مجموع العمليات، ويوزّع القالب المشترك على مشغّليه («محمد 3 · أحمد 2») بدل تسمية آخر شخص فقط، وينسب آخر إخفاء لصاحبه.
- يحدّ مسح التقارير بـ5000 سجل ويعلن ذلك في التقرير عند بلوغه؛ التقرير المقصوص الصامت يُقرأ كأنه شامل.
- **تتحدث شاشة «🧾 عملياتي» بالعربية بدل مصطلحات البروتوكول.** كانت تعرض `SHOW`/`HIDE` ورقم الطبقة وعدّاد المللي ثانية لمن يضغط الأزرار؛ صارت جُملًا عربية بأسلوب شاشة «📜 السجل»: رمز النتيجة أولًا، ثم الجملة، ثم الإرشاد في سطر مستقل.
- **تحذف وحدة `BridgeStateMigration` غير المستخدمة.** لم يكن أي من صادراتها الأربع مُستدعى من كود إنتاجي؛ الترحيل الفعلي يجري في `Import-OnAirState` عبر `ConvertTo-BridgeLiveSceneState`، والكتابة الذرّية مع النسخة الاحتياطية في `Write-BridgeValidatedJson`. صُحّح `docs/VERSION-6.md` ليذكر ما هو موصول فعلًا.
- **يوحّد قسم «✨ الجديد» حول الإصدارات المُسلَّمة.** كانت الشاشة تفتح على أربعة عناوين 6.0.0 متطابقة تقريبًا (الإصدار وثلاث نسخ preview داخلية لم تصل مشغّلًا قط).

- **تبقى شاشتا «📜 السجل» و«🧾 عملياتي» ممتلئتين بعد إعادة التشغيل.** كانت الشاشتان تقرآن من الذاكرة وحدها فتقولان «منذ آخر تشغيل»؛ صارتا تُعاد بناؤهما عند الإقلاع من `audit.jsonl` — السجل الدائم الذي يقرأ منه «🕘 ماذا فاتني» و`/who` أصلًا — بما في ذلك الأرشيف. لا ملف حالة جديد، ولا أي كتابة إضافية على مسار العرض/الإخفاء.
- يقرأ استرجاع الطوابع الزمنية بـ`RoundtripKind`، فلا يتحول ختم `Z` إلى توقيت محلي ثم يُزاح مرة ثانية عند العرض.
- **يصلح ازدواج تأكيد أزرار ترتيب الأخبار.** كانت `news:up`/`down`/`iup`/`idown` تؤكّد الـcallback مرتين لنفس الضغطة؛ أصبحت كل ضغطة تُؤكَّد مرة واحدة فقط.
- **يصلح ربط مؤقت الإخفاء التلقائي بهوية Cinegy الفعلية** عند اختلاف معرّف أمر SHOW عن معرّف العنصر الذي يعيده محرك Cinegy لنفس المشهد.
- يعيد تسمية `Queue-BridgeOperation` إلى `Add-BridgeOperation` (الاسم القديم يستخدم فعل PowerShell غير معتمد وكان يظهر كتحذير في Analyzer).
- يغلق بقية ملاحظات مراجعة v6 ويحسّن صفوف شاشة الإعدادات.

## 6.0.0 — 2026-08-29

- **يحسّن قراءة الإعدادات داخل الأقسام.** كل بند يحتفظ بصف كامل ويعرض اسمه العربي مع حالته أو قيمته الحالية ووحدتها؛ إعدادات طبقات الإخفاء وأسماء الطبقات تعرض ملخصًا مباشرًا، دون تغيير توزيع الأقسام أو callbacks أو الصلاحيات.
- يضمن أن كل مفاتيح الإعدادات الحالية تحمل تسمية عربية فعلية، وأن قيم الصفوف الكاملة تبقى ضمن حد عرض آمن (64 محرفًا) حتى لا تكسر لوحة Telegram.
- يحافظ قبول دفعات Telegram على ترتيب الأوامر التابعة للطبقة نفسها؛ لا يمكن أن يتحول SHOW ثم HIDE إلى HIDE ثم SHOW.
- يرفض تفعيل `Multi` إذا لم تثبت Cinegy هوية نشطة غير فارغة، ويحفظ `onair.json` جميع سجلات المشاهد canonical على الطبقة المشتركة عند العرض وإعادة الحفظ؛ يحدّث المشهد المُمثَّل فقط ويترك بقية كتالوج Multi محفوظًا.
- ربط سجل دورة العمليات المحدود بنتائج SHOW/HIDE/EXIT/UPDATE الفعلية باستخدام معرّف `AIR_OP` نفسه؛ تبقى العملية `queued` خلال التحقق والصلاحيات ولا تدخل `running` إلا قبل أول استدعاء إلى Cinegy.
- يمنع سجل دورة العمليات المحدود تكرار العملية نفسها عند الانتقال من `queued` إلى `running`، ويحافظ على حد السعة.

- **Version 6 official release.** The visible administrator audit trail and durable `AIR_OP` records retain the immutable numeric user id and, when configured, the corresponding administrator Alias. Template SHOW, HIDE, EXIT, undo, hide-all, live-value updates, and auto-hide timer actions use the same safe `Alias (ID)` representation; users without an Alias retain their numeric id only. The release keeps the existing configuration and template formats and may be merged into `main` through the documented side-by-side upgrade path.

## 6.0.0-preview.3 — 2026-08-29

- **Fixes timed auto-hide being discarded for the original operator without weakening replacement safety.** Cinegy can expose a different engine active id than the client EventId sent with `SHOW`; the bridge now resolves and persists that identity synchronously inside the successful SHOW using a positive exact template-name match. A missing or ambiguous identity does not arm a destructive timer, and a later watchdog observation can never transfer old work to a replacement—even one using the same template name. Attaching a timer to an existing scene performs the same live identity check.
- **Adds an explicit personal-reminder acknowledgement and one optional follow-up.** The notified operator gets a «تمت المعالجة» button; only that user can acknowledge it. If it remains unacknowledged and the same scene is still live, one follow-up is sent after `TemplateReminderFollowUpMinutes` (default 5 minutes, 0 disables). The acknowledgement identity and follow-up stage survive restart.
- **Adds approximate user activity to administrator tools.** Users are labelled recent, idle, or unknown from their cached last interaction. `UserActivityRecentMinutes` controls the window (default 5 minutes), and the UI states clearly that Telegram bots do not receive true online presence.
- Makes queue consumption transactional: if persisting removal fails, a due auto-hide or reminder remains pending and is not executed in a way that could repeat after restart.
- Adds regression coverage for exact SHOW identity, later-replacement safety, persistence failures, follow-up persistence and ownership, disabled follow-ups, and recent/idle/unknown user activity.

## 6.0.0-preview.2 — 2026-08-28

The complete Version 6 delivery record and merge gate are documented in [`docs/VERSION-6.md`](docs/VERSION-6.md).

- **Prioritizes emergency removal inside each Telegram update batch.** HIDE, EXIT, and hide-all callbacks run before SHOW and administration while equal-priority actions retain Telegram order. The bridge remains deliberately single-worker so shared PowerShell state is not exposed to unsafe runspace concurrency.
- **Rejects duplicate Telegram update ids through a bounded 4,096-entry in-memory ledger.** The polling offset advances from the highest fetched id before priority ordering, avoiding offset regression when processing order changes.
- **Adds an administrator health center.** One non-blocking screen summarizes cached Telegram and Cinegy health, output monitoring, relay state, storage warnings, pending schedules, and recent errors, with refresh, full-status, and diagnostic controls.
- **Introduces a unified setting-schema record.** Every existing default now composes into a record containing type, category, Arabic label, unit, description, protection flag, and constrained choices; future settings still fall back to Advanced.
- **Adds explicit state-migration primitives.** Legacy unwrapped data is version zero, ordered migration steps produce a current envelope, and missing or future schema versions fail with structured results.
- **Bounds large administrator catalogues.** Template administration, user administration, and pending access requests use absolute-index pages and remain below Telegram's 100-button keyboard limit. Stress coverage includes 1,000 templates, 250 users, and 200 requests.
- **Defines Cinegy shared-layer `Multi` mode without inventing unsupported scene targeting.** Several named template definitions may share a layer while Cinegy reports one active item; HIDE and EXIT remain layer-scoped and `Single` remains the default.
- **Adds Version 6 operation, settings-validation, migration-health, and readiness contracts.** Operation correlation states, numeric setting ranges, simple/advanced schema filtering, single-setting reset, timestamped state backups, cached readiness, and measured 1,000-item acceptance are covered by the release gate.
- **Completes the administrator settings discovery surface.** Search accepts Arabic labels/descriptions, modified-only and simple/advanced views are paged, and each setting can be reset independently after confirmation without resetting unrelated configuration.

## 6.0.0-preview.1 — 2026-08-28

- **Replaces the unbounded administrator settings keyboard with eight Arabic operational categories.** Security, on-air operation, templates/layers, news, scheduling, monitoring, storage, and advanced settings are now discoverable without scrolling through every technical key.
- **Pages large setting categories at eight options.** Previous/next controls preserve deterministic default-setting order while existing toggle, numeric, string, protected-setting, backup, layer-name, emergency-scope, and reset paths remain compatible.
- **Keeps every setting reachable.** A centralized navigation map assigns current settings to one category, and unknown future keys automatically fall back to Advanced rather than disappearing from Telegram administration.
- Adds administrator-gated `cfgcat:<category>:<page>` navigation and regression coverage for schema completeness, pagination, Arabic labels, callback routing, and role enforcement.
- Begins the Version 6 current-architecture program; no desktop application, service rewrite, or configuration migration is introduced in this preview.

## 5.7.9 — 2026-08-27

- **Keeps self-service access requests enabled by default while restricting approval controls to administrators and the owner.** Operators can still request access; only the authorized management roles see and can use the approval entry point.
- **Makes single-instance startup tolerant by default.** If Windows cannot enforce the mutex, the bridge continues with a warning; `-RequireSingleInstance` is available for deployments that must refuse startup when the lock cannot be verified.
- **Hardens settings imports.** JSON values are type-checked, all changes are saved in one transaction, and failed persistence restores the in-memory settings.
- **Raises the fixed JSON upload limits to 10 MiB.** Settings and template-registry imports now allow larger files for installations with many templates; the configurable news-import limit is unchanged.
- **Makes the template-registry count limit configurable.** `TemplateRegistryImportMaxTemplates` defaults to 1000, so the previous fixed 200-template ceiling no longer blocks larger catalogues.
- Rejects Telegram documents that already report an invalid size before downloading them, and makes analyzer execution failures fail the validation gate instead of reporting a misleading clean result.
- Adds regression coverage for exact bridge-process matching, role-gated approval visibility, typed/atomic settings import, and pre-download size limits.

## 5.7.7 — 2026-08-27

- **Enforces the role hierarchy `owner > administrator > operator`.** A configured owner inherits every administrator permission even when their id is not duplicated in `AdminUserIds`; administrators still cannot appoint or remove administrators or use other owner-only actions.
- **Routes personal template reminders to the initiating user.** When a template is launched from a Telegram group, its elapsed-time alert is sent directly to the user who launched it instead of being posted back to the group. Scheduled launches retain their creator's user id and follow the same rule.
- **Labels every operator snapshot with its real source.** Both the «📸 صورة من البث» and «📷 لقطة الآن» buttons use the same capture path; the sent photo now says whether its frame came from the primary broadcast or Cinegy backup. The cooldown-resend path retains the source captured with that frame rather than relabelling it based on the current failover state.
- Adds regression coverage for the primary and backup source labels.

## 5.7.6 — 2026-08-27

- **Adds per-template personal on-air reminders.** An administrator or owner can set `reminderMinutes` (0–1440) from a template's details. When an operator or their scheduled event shows that exact scene, the deadline is stored in `logs/template-reminders.json`; after a restart it resumes and messages that same operator only if the scene is still visible. A replacement or hidden scene cancels the reminder quietly.
- **Keeps permanent graphics quiet.** `longRunning: true` templates—logos and tickers intended to run 24/7—are excluded from personal reminders, even if a stale timer was saved before the template was marked long-running.
- Adds regression coverage for persistence, delivery to the original operator, replacement safety, long-running exclusion, and parsing `reminderMinutes`.

## 5.7.5 — 2026-08-27

- **Persists timed-show auto-hide deadlines across restart.** The remaining deadline is stored in `logs/autohide.json` and restored after the on-air state, so a duration selected before a bot restart still ends. The saved scene identity is checked before hiding; if the layer now carries a different scene, the stale timer is discarded safely.
- Adds regression coverage for restoring a timed-show deadline, hiding after the remaining duration, and refusing to hide a replacement scene.

## 5.7.4 — 2026-08-27

- **Turns an unreachable output source into an actionable alarm.** The output watchdog previously returned quietly whenever ffmpeg could not capture a frame, deliberately avoiding a false "black" claim but leaving a stopped HLS origin invisible to Telegram. It now counts consecutive capture failures and alerts administrators at `OutputMonitorFailureAlertThreshold` (default 2) when no backup is configured, once per outage, with one recovery notice when the primary source is captured again.
- **Adds automatic Cinegy SRT failover.** `LiveStream.BackupSourceType` and `LiveStream.BackupSourceUrl` define an optional standby source. The first failed primary probe immediately switches snapshots and the live relay to the standby; an already-running relay is restarted so ffmpeg opens the new input. The primary remains the only health probe, and a successful primary capture returns the bridge to it. A failed operator snapshot also retries once from the standby instead of returning an avoidable error.
- **Makes source status actionable for the right roles.** The full-status report now runs a manual primary-source probe and labels the monitoring server, active source, standby configuration, periodic-monitor state, and consecutive failures. The read-only report is available to administrators and the owner; other users remain excluded.
- The deployed configuration uses Cinegy Playout instance 0's local feedback stream, `srt://127.0.0.1:5421`, as the standby source. It was verified by capturing a real frame with ffmpeg before release.
- Adds regression coverage for unavailable-source alerts, fallback selection, one-time switching, and restoration to the primary source.
- **Keeps scheduled templates working across a bridge restart.** Pending events are restored from the validated schedule store before polling resumes. At the timer moment the current template registry is checked again; missing or invalid templates are recorded as a failed attempt instead of being sent, while valid templates still pass the existing live Cinegy layer verification immediately before SHOW. A regression test covers persist → simulated restart → timer execution exactly once.

## 5.7.3 — 2026-08-26

- **Fixes the duration formatting that 5.7.2 claimed to fix.** `Format-DurationSeconds` only promoted a value to minutes when it divided exactly by sixty, so the status screen still reported "منذ 107775 ثانية" for a ticker that had been up for a day. Uptime and scene age are almost never a round number of minutes, which is to say the fix reached almost nothing. Promotion now happens whenever there are enough seconds: leftover seconds are kept below an hour, where "دقيقة و30 ثانية" is useful, and dropped above it, where they are noise beside a day. Found reviewing 5.7.2, reported by the operator on the running channel within the hour.
- "آخر فحص ناجح" says "الآن" rather than "منذ 0 ثانية".
## 5.7.2 — 2026-08-26

- **Durations on the status screens read as durations.** They counted in a single unit for ever: a ticker on air since yesterday showed "1560 دقيقة", the stale-data label showed "متأخر منذ 372741 ثانية" - four days written as a number nobody divides out at a glance - and uptime showed "26س 5د". All three go through the duration formatter now, and `Format-Duration` delegates rather than duplicating, so the on-air row, the layer-lock notice, the auto-hide confirmation and the duration picker improve together instead of four of them drifting apart.
- "آخر فحص ناجح" leads with how long ago rather than a wall-clock stamp, because the question that line is asked is whether the reading is current. The clock time stays in brackets for anyone comparing against the log.
- **Archives the audit trail past `AuditMaxSizeMB` (110) instead of letting it grow without bound.** `bridge.log` has rotated for a long time; `audit.jsonl` - the permanent record of who put what on air - never had a limit at all. It now rolls into `audit-<stamp>.jsonl` and keeps every archive by default. That is the deliberate difference from `bridge.log`, which drops its oldest generation: right for a diagnostic log, wrong for the record whose whole purpose is answering questions about the past. `AuditArchiveKeepFiles` exists for a disk that genuinely demands pruning and defaults to 0, meaning keep everything.
- `Read-AuditRecords` reads back through the archives when the active file is short, so the first digest after a rotation does not report an empty morning.
- Two faults found while building the rotation, both introduced by it: `Invoke-AuditRotation` returned a boolean into `Write-AuditRecord`'s output stream, so `Invoke-ShowTemplateResult` came back as an array and lost its `.Success` - every operation that writes an audit record was affected; and the archive glob `audit-*.jsonl` adopted anything sitting in the log folder and read it as history, now narrowed to the exact stamped shape with the active file excluded.
- Test suite grows from 607 to 611.
## 5.7.1 — 2026-08-26

- **Makes the Cinegy health alert answer a question worth waking up for.** An administrator was warned about "الساقط 34، الخرج 1467" - thirty-four dropped frames, which sounds alarming and is 2.3% of what actually went out. A bare count cannot tell those apart, and the sample window is not a fixed size. Frame loss now has to cross both an absolute floor (`CinegyFrameLossTolerance`, 5) and a share of output (`CinegyFrameLossTolerancePercent`, 5%) before it counts as a fault: the count stops a tiny sample raising an alarm on percentages, the percentage stops a busy minute raising one on counts.
- Adds hysteresis to the health state itself. The tolerance filters the values; this filters the verdict. Even inside tolerance the channel kept crossing the line and back, and the log holds 332 health transitions - 23 of them today - on an engine that was fine every time anybody looked. `CinegyHealthConfirmChecks` (3) readings must now agree before the state moves at all. A monitor that changes its mind every minute is one operators stop reading, which costs more than the outage it was watching for.
- Explains the output monitor to administrators, in the help screen and in its own words: a frame every `OutputMonitorMinutes` taken from the channel output rather than from anything Cinegy says about itself, a confirming second frame after a dark one, an alert only when both are black so a deliberate fade wakes nobody, once, then a recovery notice. The health thresholds are spelled out beside it with their live values, so an administrator drowning in alerts can see which number to raise.
- The news draft timeout was thirty minutes, which expired a 28-item draft mid-edit. It is two hours now, and `NewsDraftTimeoutMinutes` finally appears on the settings screen - it had no metadata entry, so it could not be changed from the bot at all. Expiry also hands the items back as text instead of reporting a body count: an unpublished draft is somebody's work, and the lock hand-over has returned it since 5.5.
- Durations are spelled out wherever a setting is measured in time. `1200` reads as `20 ساعة` rather than a number the reader has to divide, and Arabic's own counting is respected - dual for two, plural three to ten, singular again from eleven - so `5 ثانية` and `كل 1 دقيقة` stop happening.
- Test suite grows from 592 to 607.
## 5.7.0 — 2026-08-26

- **Adds an owner role, and makes it the only one that can appoint administrators.** Until now the bot could disable, rename and revoke a user but never promote one, so adding an administrator meant hand-editing `config.json`. Promotion and demotion now live on the 👥 المستخدمون screen, behind a confirmation, and the person whose role changed is told directly rather than discovering it when a button stops working.
- The owner is whoever set the bridge up: with `OwnerUserIds` unset it is the first id in `AdminUserIds`. Deliberately the first id and not every administrator - the point of the tier is that appointing administrators is narrower than being one. Naming ids in `OwnerUserIds` overrides that.
- `OwnerUserIds` is never written by the bridge. It sits outside `Save-Config`'s managed keys, so ownership changes by hand in `config.json` and nowhere else - the bot cannot promote its way to controlling who controls it.
- Ownership matches on the user id alone, with no `RequireUserLevelAuth` relaxation. Administrator rights can be granted to a whole chat; owner rights are a person, and a group must never confer them.
- Guards: the owner cannot be demoted, the last administrator cannot be demoted, and only an already-authorized user can be promoted - so promotion never doubles as a way in. The promote/demote buttons are drawn only for an owner, because a button that always answers "not allowed" is worse than no button, and ownership is re-checked when the confirmation is tapped rather than only when it was drawn.
- Adds the news item where a ticker wants it: at the front. A newly typed item used to be appended behind however many older items the draft already held, which is the opposite of what a ticker is for. `NewNewsItemAtTop` (default on) turns it back into an append for a rundown ordered by hand, and the confirmation now says which end it landed on.
- The add-template wizard can finally reach a real scene. It refused every absolute path and required the file to sit inside the bridge's own project folder - scenes live in C:\Cinegy\Titler\Scenes, on a mapped drive or on a UNC share, never there - so the guided flow could not register a single real template and the only way in was the raw JSON screen, which has always accepted absolute paths. It now takes any path Cinegy can open, reports which file it actually looked at, and treats a file it cannot see as a warning rather than a refusal.
- The wizard's layer step also takes a device name, so the logo on `gfx_logo` no longer needs hand-edited JSON, and it names the templates already sitting on a layer number as it is typed. A fifth, skippable step captures description and category.
- Admin-only commands are no longer advertised to every operator. Each screen and handler was already gated, but `setMyCommands` registers one global list, so ⚙️ الإعدادات, 📜 سجل and the diagnostics commands appeared in everyone's ☰ menu and were refused only once tapped. The default scope now carries the twelve an operator can use; administrators get all eighteen in their own chat, and a demoted administrator's scope is cleared.
- Template paths accept `%PROGRAMDATA%`-style environment variables, and `TemplateBasePath` lets `templates.json` carry a bare file name. UNC shares and mapped drives already worked.
- Sweeps a class of StrictMode faults rather than the four instances that surfaced: every Cinegy entry point now returns the same field set on success and failure, so a caller reading `.Error` or `.StatusCode` on the wrong branch cannot crash the bridge exactly when the engine is in trouble.
- Adds a 📄 المزيد button for long screens. The release notes lead with the newest three versions and the audit log with its first page; the rest arrives only when asked for. Send-TelegramMessage already split past 4096 characters, but it fired every part at once - four unasked-for messages, with the beginning somewhere above. The release notes split at a version boundary rather than a character count, so the first screen ends where a release ends.
- Test suite grows from 557 to 592.

## 5.6.1 — 2026-08-26

- **Stops the staleness alert crying wolf on graphics that are meant to stay up.** The news ticker was reported to administrators as a stale record five times over two days while it was genuinely on screen - its Cinegy `Active Id` matched the record exactly. The alert measured elapsed time alone, and an alert that fires on correct behaviour teaches operators to ignore it. Two independent exemptions now answer it: Cinegy's own declared `Duration` for the active item (a ticker is scheduled as `24:00:00` with a manual end), honoured via `RespectCinegyItemDuration`; and a `longRunning` flag on the template for engines that declare nothing useful. An unreachable engine never silences the alert - "cannot check" and "fine" are different things.
- Gives the Cinegy health check a tolerance instead of demanding perfection. One dropped frame inside the sixty-sample window turned the whole channel unhealthy, and the next check - the window having rolled past it - turned it healthy again: 54 transitions in a single day on a channel that was fine. `CinegyFrameLossTolerance` (default 5 frames) and `CinegyReadErrorRateTolerance` (default 0.5%) set where a drop stops being television and starts being a fault. Counts are still reported in full: within tolerance never reads as nothing happened.
- `Get-TitlerLayerStatus` exposes `ActiveDurationSeconds` and `ActiveManualEnd`, parsed from Cinegy's own format rather than with `TimeSpan.TryParse`, which rejects the one value this exists for: `24:00:00` needs an hour field of 0-23.
- Its error path now returns the same field set as its success path. A caller reading a field that exists only when the call worked would crash under `StrictMode` exactly when the engine is already in trouble.
- Test suite grows from 547 to 557.
## 5.6.0 — 2026-08-25

- **The restart button now works when the bridge was started by hand.** It only ever signalled an exit and left the restarting to NSSM or the scheduled task; started from a terminal - which is how it is run during a shift, from the VS Code console - nothing brought it back, so the button refused rather than causing an outage with no way back in through the bot that just stopped. The bridge now relaunches itself into the same console with the same configuration, and refuses only when it can rebuild neither a supervisor nor its own command line. Under a supervisor it deliberately does *not* self-relaunch: two bridges long-polling one bot token means button presses vanish into whichever instance received them.
- Template buttons carry the name alone. The label used to append the layer number and the last-used time, which overran Telegram's 32-character button limit and cut the date mid-way - `News-Ticker (طبقة 8) · 🕘 08-25…` reads as noise. Layer, device, category, fields, usage count and last use moved onto the ℹ️ preview screen, which has room for them.
- 🕘 ماذا فاتني answers the questions asked at a handover instead of counting verbs. It used to report `SHOW 23, EXIT 12, أخرى 73`, where the largest bucket was simply every record without an action field. It now names which graphic went to air, who put it there and when, what failed and why, the notable activity notes verbatim, and the current on-air and engine state.
- Fixes a crash in that same digest: under `StrictMode` a single audit record missing a field threw, taking down the whole screen - and that screen is what an operator opens once something has already gone wrong. Records are normalised once on read, so an absent field is empty rather than fatal.
- Confirms before taking a live graphic off air, so a single tap cannot hide what is on screen.
- Addresses the Cinegy logo by its device name (`gfx_logo`) rather than a layer number, via an optional `device` on a template. The logo layer is not numbered, so it was previously uncontrollable.
- Pages the news reorder list. A 38-item draft rendered 152 buttons, past Telegram's keyboard cap, so the edit was rejected and the list appeared not to update - which read as "the last items are missing". Every item is now reachable.
- Adds `NewsListPaged` (default on): turn it off for one long news list instead of small pages. It is a cap rather than a promise - Telegram rejects an over-large keyboard, and a rejected edit looks exactly like a list that will not update - so the long list runs to the button budget, pages beyond it, and says on screen why.
- Adds delete-with-confirmation straight from the reorder list, a configurable news label length, and an optional stacked list layout (`NewsListStackedLayout`, default off).
- Stops calling a shared template layer harmless.
- De-duplicates the 5.1-5.5 changelog entries, each of which had been written twice during a merge.
- Test suite grows from 495 to 544.
## 5.5.0 — 2026-08-24

- **Makes the ticker usable alongside another writer.** A second system writes the same `news.txt`, so a publish conflict is the normal case rather than an accident, and refusing forever made the bot useless for the ticker. A conflict now offers two explicit choices: append the draft's items to whatever is live now, or replace it entirely. Never a silent overwrite - the other writer's work is only discarded by a deliberate choice, and the previous text is backed up either way.
- Adds a lock hand-over request. A non-owner can ask the operator holding the draft to release it; the owner has `NewsLockRequestMinutes` (default 5) to agree or refuse, and silence hands it over - an operator who has gone home cannot answer, and the ticker cannot wait for them. Previously the only way past someone else's draft was an administrator forcing it, which is the wrong tool for two operators on one channel.
- The owner's unpublished items are sent back to them as text before the draft is released. An unpublished draft is somebody's work: transferring it to another person, or dropping it silently, would both be worse than handing it back.
- The lock label now names the holder instead of showing a raw user id.
- Test suite grows from 484 to 495.
## 5.4.0 — 2026-08-24

- **Fixes a phantom on-air record.** On startup the bot reported a template on layer 7 while the screen was blank. Discovery treated "not marked empty" as evidence of a live scene, but a spent item stays Active - briefly with no `IsEmpty` at all - and reports Cinegy's placeholder name `Item` with no description, exactly as every empty layer does. Discovery now requires a real describing name. Ambiguity must never ADD a record, and still never removes one.
- Generalises undo. A push onto a verifiably empty layer now leaves an undo that clears the layer again - the commonest mistake there is. Deliberately not offered when correlation failed, since hiding would discard whatever the bridge could not identify rather than restore it.
- Names who holds a layer lock, what they are preparing, and for how long, instead of printing a bare user id. An optional 🔒 badge on the template list (`ShowLayerLockBadge`, default off) shows the clash before a field is typed.
- Asks why after an undo - wrong template, wrong timing, director asked, other - and reports the counts in the usage digest. `logs\cancel-reasons.json` holds counts only: no field text, no user ids.
- Adds `/digest` and 🕘 ماذا فاتني, and `/who <template>`. Both read `audit.jsonl` rather than a new events file, which would only drift out of sync with the audit trail.
- Adds a repeat radar: one template pushed three times inside an hour is queried, since that is almost always a paste slip. Asked after the push, never before.
- Adds quiet hours (`QuietHoursEnabled`, default off): non-urgent administrator notices are batched overnight and delivered as one message when the window closes. A black output or a stale on-air record is always urgent and always immediate.
- Adds an automatic maintenance window (`MaintenanceWindowStart`/`End`, `HH:mm`). Both it and quiet hours handle windows that cross midnight. An unset or malformed window is no window - neither may fail closed and block control of a live channel. The administrator emergency override still works inside one.
- Adds one-hand mode (`OneHandMode`) for thumb-only use, and optional text shortcuts (`EnableTextShortcuts`) where a bare template name starts a show. Exact match only: a fuzzy match would put the wrong graphic on air from a typo.
- `templates.json` is no longer tracked in git. It carries station-specific names and scene paths and belongs with `config.json`; `templates.example.json` remains for a fresh install.
- Test suite grows from 434 to 477.
## 5.3.0 — 2026-08-24

- Adds 📷 لقطة الآن and 📋 نسخ الحالة to the on-air row. The frame lets an operator check what the bridge claims is on air against the real output without leaving the chat - the exact gap that let an exited scene sit unnoticed for ninety minutes. The status text is deliberately plain so it survives being pasted into another app.
- Adds `/stats` and 📈 أرقام التشغيل: uptime, air operation outcomes, Telegram and Cinegy connection states, and the last daily heartbeat. Uptime is the number that matters - a bridge up for eleven minutes has been restarting. Telegram flood limits (429) are counted separately from ordinary send failures, since a rate limit is a capacity problem rather than a bug.
- Enables the pre-schedule warning by default at three minutes, and adds the Cinegy health line to it so the operator can decide whether to intervene. The mechanism already existed but shipped disabled.
- Fixes another `"$layer:"` interpolation, where PowerShell reads the colon as a scope delimiter and the whole load fails.
- Test suite grows from 427 to 434.
## 5.2.0 — 2026-08-24

- Surfaces an active rollback in the main menu with its remaining seconds. Undo was reachable only from the message that offered it, so navigating away lost it for the rest of its window - and the fastest human error is pressing the wrong template.
- `ReservedLayers` now admits administrators, stating that the layer is reserved, while still refusing operators. It previously refused everyone including the administrators who reserved the layer, so touching a protected layer meant editing `config.json`. A disabled template stays blocked for everyone.
- Warns administrators when a scheduled event is about to displace a live graphic (`NotifyOnScheduleOverwrite`, default on). The creation-time conflict check compares scheduled events only, and cannot know what an operator put up by hand.
- Adds settings export and import. Export carries only the keys declared in `DefaultSettings`, so the bot token and the operator whitelist never reach a chat. Import refuses a foreign or malformed document, refuses an unknown key rather than dropping it, previews exactly which keys differ, and applies nothing until the same administrator confirms.
- Adds a usage digest, on demand and weekly (`UsageDigestEnabled`, `UsageDigestDayOfWeek`): busiest templates, operation totals, and refusals.
- Settings export now creates the log directory if it is missing rather than assuming an earlier code path made it.
- Adds an administrator restart (`AllowRemoteRestart`, default off). It refuses unless a supervisor is actually present - the parent process is inspected, and NSSM or Task Scheduler both restart on exit - because exiting unsupervised is an outage with no way back in through the bot that just stopped. It confirms first, warns when scenes are recorded on air, and signals the polling loop to leave rather than exiting in place, so the finally block still stops the relay, saves counters and releases the single-instance mutex.
- Seeds the output monitor's timestamp to launch time so the first picture check lands one interval later, rather than probing the source during startup. This also stopped the test suite shelling out to ffmpeg against the example URL.
- Gives the approval keyboard a way back to the menu, so no screen is a dead end. A phone's own back button leaves the chat entirely and cannot be intercepted by a bot; the help now says so and points at the on-screen buttons.
- Release notes now carry a condensed summary of what version 4 brought, for operators who never saw its changelog.
- Adds `scripts\Test-BridgeReadiness.ps1` and `Modules\BridgeInstall.psm1`. Both installers now refuse to register a service over a configuration that cannot start: a supervisor wrapped around a broken config produces a bridge that crashes and is restarted for ever while `services.msc` reports it Running. It checks PowerShell 7, config.json validity, a real bot token, at least one administrator, and a parseable template registry; a missing ffmpeg warns rather than blocks.
- Catches the DPAPI account trap by name. Secrets are protected with `DataProtectionScope::CurrentUser` while both installers run the bridge as `SYSTEM`, so protecting the token as yourself and then installing the service produced a bridge that could not decrypt its own token. `Protect-BridgeSecrets.ps1` now records `ProtectedBy` in the store, and the readiness check refuses the mismatch and names both accounts.
- Both installers accept `-RunAsAccount`, and after starting they confirm the bridge actually came up by reading `logs\bridge.log` rather than trusting the service state. Repeated startup lines are reported as a crash loop.
- `RELEASE.md` gains a first-install section covering the readiness check, the account choice, and the DPAPI trap.
- Test suite grows from 384 to 427.
## 5.1.0 — 2026-08-23

- Alerts administrators about a bridge-pushed layer recorded on air longer than `StaleOnAirAlertHours` (default 6, 0 disables). Reports only, never removes: deleting a record the operator can still see on screen would be worse than a stale one. Cinegy-owned scenes are excluded, being legitimately up for days.
- The main menu now states how old the on-air claim is and flags it when Cinegy could not be reached. A stale claim reading identically to a fresh one is what let an exited scene go unnoticed.
- Adds `Invoke-BridgeSelfTest` (🧪 فحص المسار الحي): SHOW, read back, EXIT, read back, reporting what Cinegy said at each step. Refuses a layer that is busy or that production templates use, and always attempts a HIDE afterwards.
- Adds `ConfirmLayerRemoval` (default off): a confirmation before hide and exit naming the template, how long it has been on air, and who pushed it. Off by default because it costs the emergency path a tap.
- Deletes staged operator uploads past `UploadRetentionMinutes` (default 60). News and template registry uploads were staged, parsed, then left on the playout machine for ever.
- Adds an output monitor that looks at the picture itself: a frame every `OutputMonitorMinutes` (default 60), and on a dark frame a confirming second capture `OutputBlackConfirmSeconds` later. Alerts only when both are black, once, then reports recovery. Administrators always hear; operators only when `NotifyOperatorsOnBlackOutput` is on.
- Adds 🆕 ما الجديد and `/whatsnew`: operator-facing release notes describing what changed on screen rather than in the code.
- Rewrites the help screen grouped by task rather than by menu, covering the on-air rows, the freshness warning, the removal confirmation, the admin tools screen, the self-test and the output monitor.
- Test suite grows from 345 to 384.
## 5.0.0 — 2026-08-23

- Splits `TelegramBridge.ps1` from 7407 lines into a 973-line orchestrator plus 14 dot-sourced declaration files under `Parts/`. Parts are dot-sourced rather than imported because they must share the script scope and `$script:` state; only declarations move, while the 64 ordered top-level initialization statements stay put because they depend on `$config`.
- Replaces all 40 hand-counted `$data.Substring(N)` callback parses with `Get-CallbackArg $data '<prefix>'`, making the off-by-N class that broke news reordering unrepresentable. A renamed prefix now throws instead of slicing silently.
- Backs off Cinegy layer reconciliation while Air is unreachable: an unverifiable layer doubles the wait up to `CinegyStateBackoffMaxSeconds` (default 60) and the first success clears it, so a dead engine no longer freezes the polling loop for layers x timeout on every interval. The long-poll timeout follows the widened interval.
- Honours Telegram's `retry_after` on HTTP 429 instead of retrying at a fixed 400 ms, and raises sends to three attempts, so admin broadcasts and chunked long messages are no longer dropped under flood limits. Callback acknowledgements now use the same wrapper. `Get-TelegramUpdates` deliberately stays outside it, because the polling loop already is its retry policy.
- Renames the `Write-AuditRecord` parameter that shadowed the automatic `$Event` variable. The emitted audit field name is unchanged.
- Fails the verification gate on analyzer warnings, not only errors, and excludes `dist/` and `artifacts/` so stale release copies stop reporting findings already fixed. Clears the six real findings this exposed, including a `Publish-NewsTickerDraft` parameter that was never used and a DPAPI test teardown that restored into a local and therefore did nothing.
- Unpacks the semicolon-chained news draft functions, verified behaviour-preserving by comparing parsed token streams.
- Leads the main menu with what is on air: live-layer hide buttons and the emergency hide-all now render above everything that can put more on air, and the menu message reports the live state instead of a static prompt. Five rows of rarely used administrator configuration move behind a single `🗂 أدوات الإدارة` entry; settings and access requests stay one tap away, and operators see no change.
- Refuses a `TemplateTestLayer` that registered templates already occupy, naming the clashing templates, so a template test cannot go out on a programme layer.
- Test suite grows from 307 to 341.
## 4.2.44 — 2026-08-22

- Refreshes the display name of an already tracked external Cinegy scene when later live status exposes its actual `.cintitle` filename.
- Replaces legacy generic names such as `Cinegy Type Layer 8 On` without deleting the on-air record or changing its layer identity and preserves the original Cinegy event name as diagnostic metadata.
- Adds an explicit regression test for upgrading an existing live external record in place.
- Reorganizes full status into active scenes, Cinegy connection, service health, operations/scheduling, and access sections.
- Expands active-scene status with source, operator Alias, elapsed time, and retained Cinegy event metadata; main-menu hide buttons now include both layer and template name.
- Adds an explicit `Alias` action per authorized user, with interactive edit/delete flow, persistence, audit, and tests.

## 4.2.43 — 2026-08-22

- Adds `Modules/BridgeRuntimeState.psm1` as an explicit, isolated runtime-state model.
- Consolidates relay process ownership, relay intent/restart/watchdog fields, and Cinegy/Telegram monitoring timestamps and states under that model.
- Removes the separate global relay-process and monitoring variables while retaining the existing relay-state compatibility reference during gradual migration.
- Adds isolation/default tests and keeps relay, freshness, external-change, outage-threshold, and recovery coverage.
- Extracts the actual `.cintitle` template name from Cinegy's active-item `Description` for externally started or scheduled scenes, instead of presenting the generic layer event name; retains the Cinegy event name as diagnostic metadata.
- Shortens long Telegram button labels centrally at a configurable Unicode-aware visual limit (`ButtonTextMaxLength`, default `32`, `0` disables), without changing callback commands.
- Completes the planned modularization and gradual global-state reduction work without a broad rewrite.

## 4.2.42 — 2026-08-22

- Extracts live-relay watchdog timing, healthy/idle/wait states, disabled restart, retry-limit, and restart-count decisions into `Modules/BridgeRelayPolicy.psm1`.
- Keeps process ownership, PID cleanup, logging, administrator notifications, and actual restart execution in the bridge.
- Adds direct policy tests for every watchdog branch and completes the planned first separation of scheduling, live relay, and ffmpeg process handling.

## 4.2.41 — 2026-08-22

- Extracts Windows-safe argument quoting, ffmpeg input selection, and hidden redirected process launch into `Modules/BridgeMedia.psm1`.
- Routes both asynchronous snapshots and the live relay through the shared media-process launcher while retaining bridge-owned jobs, watchdogs, PID ownership, messages, and cleanup.
- Adds direct tests for paths with spaces, empty and quoted arguments, supported/unsupported inputs, and exact hidden redirected process launch parameters.

## 4.2.40 — 2026-08-22

- Extracts schedule due-time, completed-occurrence, retry timing, retry count, exponential backoff, and maximum-delay decisions into `Modules/BridgeSchedulePolicy.psm1`.
- Keeps persistence, notifications, SHOW invocation, recurrence advancement, and execution audit logging in the bridge orchestrator.
- Adds direct policy tests and retains the full schedule store/executor, pause, notification, recurrence, restart, retry, conflict, and review-flow coverage.

## 4.2.39 — 2026-08-22

- Extracts per-layer Cinegy reconciliation decisions into `Modules/BridgeCinegyState.psm1` while retaining network polling, logging, persistence, notifications, and timer cleanup in the bridge orchestrator.
- Preserves tracked scenes on unavailable status, adopts Cinegy's actual id while on air, removes only after confirmed hidden state, and discovers untracked scenes as `cinegy` source only during explicit full comparison.
- Avoids mutating caller-owned tracked records inside the policy module.
- Adds direct policy tests plus existing reconciliation, startup, external-scene, identity persistence, and on-air smoke coverage.

## 4.2.38 — 2026-08-22

- Extracts interactive pending-flow storage, timeout evaluation, and removal into `Modules/BridgeFlowState.psm1`.
- Preserves bridge-owned cleanup effects for layer locks, staged imports, and persisted drafts while reducing direct `$script:PendingState` manipulation.
- Supports numeric chat keys restored through different PowerShell/JSON key types.
- Adds direct flow-state tests and bridge compatibility coverage for cancellation, expiry, periodic cleanup, draft persistence, and lock release.
- Completes the planned first separation of Telegram transport, authorization policy, and interactive flow state.

## 4.2.37 — 2026-08-22

- Extracts private-chat, operator, administrator, disabled-user, and legacy private-chat fallback decisions into `Modules/BridgeAuthorization.psm1`.
- Keeps user administration, approval messages, and interactive flows in the bridge while routing their authorization decisions through an explicit-input policy module.
- Adds direct policy tests for allowed and disabled users, sender/chat separation, administrator identity, group rejection, and legacy positive-id compatibility.
- Includes the authorization module and tests in all parser, required-file, Pester, packaging, signing, and manifest gates.

## 4.2.36 — 2026-08-22

- Extracts bounded Telegram HTTP transport and retry behavior into the independent `Modules/BridgeTelegram.psm1` module.
- Routes message, photo, and document uploads through the shared transport while preserving one transient retry, existing timeouts, logging, and photo fallback behavior.
- Adds direct transport tests for retry success, structured terminal failure, and single-attempt behavior, and keeps bridge-level compatibility tests.
- Includes the Telegram module and its tests in parser, required-file, Pester, release-package, signing, and manifest gates.

## 4.2.35 — 2026-08-22

- Extracts validated JSON primary/backup writes and recovery reads into the independent `Modules/BridgeStorage.psm1` module.
- Adds direct storage tests for atomic primary/backup creation, invalid-input protection, backup recovery, and missing-state handling.
- Organizes reusable modules under `Modules/`, administration and installation tools under `scripts/`, and historical reviews under `docs/archive/`.
- Updates runtime imports, test imports, release packaging, recursive signing/manifest generation, documentation, and required-file/parser gates for the organized layout.
- Removes only regenerated build/test outputs and example-config backups; live `config.json`, its backups, `templates.json`, and `logs/` remain untouched.

## 4.2.34 — 2026-08-22

- Extracts setting lookup, integer normalization, and schema initialization into the pure `BridgeSettings.psm1` module.
- Keeps the existing `Get-Setting`, `Get-SettingInt`, and `Initialize-Settings` bridge interfaces so callers and administrator workflows retain identical behavior.
- Adds direct module tests covering configured values, defaults, numeric boundaries, non-destructive initialization, and complete-schema no-op behavior.
- Includes the new module and tests in parser, required-file, Pester, and allow-listed release-package gates.

## 4.2.33 — 2026-08-22

- Keeps safe rollback disabled by default through `EnableSafeRollback`; administrators can opt in without changing the existing operating workflow.

- Added short-lived, in-memory rollback candidates for correlated bot scenes
  replaced by SHOW or removed manually with HIDE/EXIT.
- Kept editorial field values out of every disk file and expired candidates
  after the configurable `RollbackWindowSeconds` interval.
- Required operator ownership or administrator access, a review step, a layer
  lock, and an immediate Cinegy comparison before restoration.
- Required exact `ActiveId` continuity after replacement or a still-empty layer
  after HIDE/EXIT; external changes, timeout, uncertainty, and expiry cancel and
  invalidate rollback without sending a playout command.
- Added regression tests for correlation, replacement, hide restoration,
  review, expiry, external changes, and Cinegy uncertainty.

## 4.2.32 — 2026-08-22

- Added an administrator-configured template test layer, disabled by default.
- Required the test layer to be absent from every production template
  definition and verified directly with Cinegy that it is empty before SHOW.
- Added administrator review and confirmation, synthetic `TEST` field values,
  explicit `BotTest` tracking, and a mandatory 3-300 second automatic hide.
- Added field-level before/after comparison to template-definition review and
  stated that the existing timestamped backup is created before saving.
- Added regression tests for production-layer rejection, occupied/uncertain
  layer blocking, isolated SHOW targeting, automatic hide, and comparison.

## 4.2.31 — 2026-08-22

- Added administrator template-registry export through Telegram.
- Added opt-in full-management import of JSON documents up to 1 MiB, with
  bounded download, safe Telegram file-path validation, and temporary staging.
- Validated every template key, absolute `.cintitle` path, positive layer, and
  field name before showing added/changed/removed/unchanged counts.
- Required an explicit confirmation before atomic replacement and created a
  timestamped backup of the previous registry.
- Blocked imports that change or remove a template currently on air or used by
  an upcoming schedule, and removed staged files on cancellation or expiry.

## 4.2.30 — 2026-08-22

- Added private per-user template search across key, description, and optional
  category without changing stable callback indexes.
- Added category browsing and documented optional `category` values in the
  example registry and administrator definition editor.
- Added a non-mutating template detail preview before SHOW selection.
- Persisted and displayed the local time of each template's last successful
  use while remaining compatible with legacy integer usage counters.

## 4.2.29 — 2026-08-22

- Added opt-in CurrentUser DPAPI storage for the bot token and live-stream
  source/destination URLs; the existing plaintext configuration remains the
  disabled-by-default behavior.
- Added the protected administrator setting `EnableDpapiSecrets` and an
  explicit `Protect-BridgeSecrets.ps1` migration command.
- Persisted only `dpapi:` references while enabled and prevented later config
  saves from leaking decrypted values back to JSON.
- Protected the encrypted store and the pre-migration backup with the same
  strict Windows ACL, and excluded both from Git and release packages.
- Added DPAPI round-trip, no-plaintext, migration, activation, deactivation,
  and default-off regression tests.

## 4.2.28 — 2026-08-22

- Added Windows ACL enforcement for `config.json`, its fallback copy, and all
  versioned configuration backups at startup and after save or restore.
- Restricted access to the bridge runtime identity, Local System, and the
  built-in Administrators group using stable Windows security identifiers.
- Added an integration test that verifies protected inheritance and the exact
  allow-list on temporary files and directories.

## 4.2.27 — 2026-08-22

- Extended the administrator-confirmed runtime cleanup to all direct `.log`
  files in `logs`, including bridge rotations and relay stdout/stderr logs.
- Kept `audit.jsonl`, `onair.json`, schedules, templates, backups, and
  diagnostic subdirectories outside runtime-log cleanup.
- Retained a fresh audit record after either runtime or audit cleanup.

## 4.2.26 — 2026-08-22

- Added Windows/PowerShell 7 GitHub Actions for parser, PSScriptAnalyzer, and
  Pester verification on pushes and pull requests.
- Persisted NUnit-format Pester results and uploaded verification artifacts.
- Added an allow-listed release builder that excludes live configuration,
  templates, logs, backups, snapshots, audit history, and on-air state.
- Added a release manifest, ZIP SHA-256 sidecar, and optional Authenticode
  signing using a Windows certificate thumbprint.
- Documented checksum/signature verification, side-by-side upgrade, and safe
  rollback preserving validated runtime state.
- Added automated package allow-list, manifest, and checksum tests.

## 4.2.25 — 2026-08-22

- Added `TelegramRequestTimeoutSeconds` with a 15-second default for
  `sendMessage`, `sendPhoto`, and `sendDocument`.
- Retained one bounded retry for transient Telegram send failures.
- Kept long polling on its independent poll timeout.
- Added send retry and timeout propagation tests for text and multipart
  uploads, completing the existing HTTP, Cinegy timeout, disk-failure, and
  corrupt-JSON coverage.

## 4.2.24 — 2026-08-22

- Counted field limits using Unicode text elements rather than UTF-16 code
  units, so emoji and Arabic combining marks match what operators see.
- Added Unicode-safe Telegram chunk boundaries that never split surrogate
  pairs or ordinary combining sequences.
- Preserved the existing 3500-code-unit Telegram safety ceiling.
- Added emoji, Arabic diacritic, invalid-surrogate, long-line, XML-special,
  and message-loss regression coverage.

## 4.2.23 — 2026-08-22

- Added `SchedulePaused` to keep all events pending without executing or
  deleting them.
- Added optional `SchedulePreNotifyMinutes` notifications, disabled by default,
  with one notification per occurrence.
- Added reviewed recurrence end dates for daily and weekly events, including
  validation that the end does not precede the first occurrence.
- Completed recurring events after their next local occurrence exceeds the
  configured end date.
- Preserved recurrence end dates during copy and edit operations.
- Added pause, notification de-duplication, recurrence completion, and UI flow
  coverage.

## 4.2.22 — 2026-08-22

- Added copy and edit-time buttons for each pending schedule event.
- Required a new local time followed by the existing schedule review before
  either mutation is saved.
- Kept the original event unchanged when copying and generated a fresh event
  id for the copy.
- Preserved the stable event id when editing time and reset stale execution or
  retry state only after an atomic save succeeds.
- Added full timezone ids to event summaries in addition to numeric offsets.
- Restricted copy/edit to the event owner or an administrator.
- Added copy isolation, edit identity, and timezone summary tests.

## 4.2.21 — 2026-08-22

- Required template paths to be absolute and use the `.cintitle` extension;
  existence is intentionally not checked because the path may belong to the
  remote Cinegy server.
- Excluded invalid template definitions from SHOW controls and exposed their
  keys and reasons through existing health warnings.
- Reported layers shared by multiple templates as allowed informational data,
  preserving the operational rule that one layer may host many templates.
- Retained scheduled-event proximity warnings as the actual layer conflict
  detector.
- Added invalid-path and shared-layer regression tests.

## 4.2.20 — 2026-08-22

- Added a private, in-memory recent operation history keyed by Telegram user
  id and capped at 20 records per user.
- Excluded editorial field values from operation history.
- Added the `🧾 عملياتي` screen and `/myoperations` (`/myops`) command with
  success, blocked, and failure guidance.
- Added a safe retry button that restores the same user's last SHOW values
  into the confirmation screen without sending directly to Cinegy.
- Added user-isolation, content-minimization, and no-direct-send retry tests.

## 4.2.19 — 2026-08-22

- Added shared validated JSON state read/write helpers with atomic temporary
  files and a last-known-good `.bak` copy.
- Applied automatic corruption recovery to `onair.json` and `schedule.json`.
- Repaired the primary state file from its validated backup during import.
- Preserved current in-memory state when neither primary nor backup can be
  parsed instead of replacing it with an empty collection.
- Added corruption and recovery tests alongside existing Cinegy/Telegram
  outage, recovery-notification, and interrupted-schedule coverage.

## 4.2.18 — 2026-08-22

- Added `SensitiveTemplateKeys` and `SensitiveTemplateAutoHideSeconds`.
- Enforced an automatic-hide timer for configured sensitive templates through
  ordinary, preset, and scheduled SHOW execution.
- Treated the administrator duration as the maximum on-air lifetime while
  retaining a shorter operator-selected timer.
- Replaced an existing timer on the same layer instead of stacking timers that
  could hide a later scene.
- Added mandatory timer and duration-bound regression tests.

## 4.2.17 — 2026-08-22

- Added an administrator-only redacted diagnostic ZIP via the diagnostics
  screen and `/diagbundle`.
- Limited bundle contents to `summary.json` and the latest 200 sanitized
  runtime lines; configuration, on-air state, schedules, templates, and audit
  history are never packaged.
- Removed bot credentials and stable user/chat/from/admin identifiers from
  exported text.
- Deleted the generated ZIP locally after the Telegram send attempt.
- Corrected runtime-path isolation so diagnostics and cleanup always target
  the selected runtime directory.
- Added bundle allow-list, redaction, and administrator delivery tests.

## 4.2.16 — 2026-08-22

- Added administrator-only buttons to clear runtime logs or the structured
  audit history independently.
- Required a fresh, expiring, per-administrator confirmation before deletion.
- Kept `onair.json`, schedules, templates, and backups outside cleanup scope.
- Recreated an audit record after cleanup identifying the administrator and
  selected history type.
- Added configurable low-disk, runtime-storage, and backup-storage warnings to
  administrator diagnostics.
- Added stricter diagnostic text redaction for user/chat/from/admin identifiers.
- Added confirmation, cleanup isolation, audit recreation, warning, and
  redaction regression tests.

## 4.2.15 — 2026-08-22

- Added the independent permanent `logs/audit.jsonl` audit trail.
- Recorded UTC timestamp, correlation id, event, result, actor, action, layer,
  target, duration, and redacted message as one machine-readable JSON object
  per line.
- Reused each air-control operation id in its structured audit record while
  retaining the human-readable `AIR_OP` runtime entry in `bridge.log`.
- Persisted general in-chat audit activity independently from the bounded
  in-memory list.
- Included the audit file size in administrator diagnostics.
- Added correlation, persistence, single-line, and secret-redaction tests.
- Suppressed helper return values such as `True` at the runtime orchestration
  boundary while preserving actual operational log lines in the terminal.

## 4.2.14 — 2026-08-22

- Added bridge build-file time and process uptime to administrator diagnostics.
- Added processor architecture, working-set memory, private memory, and free
  disk capacity.
- Added byte-derived sizes for configuration, templates, on-air state,
  schedule state, schedule execution history, and bridge log files.
- Added in-memory success, failure, and blocked counters for air-control
  operations without reparsing logs.
- Kept diagnostics administrator-only and passed all output through existing
  secret redaction.
- Added diagnostic content and counter regression coverage.

## 4.2.13 — 2026-08-22

- Changed opted-in scheduled retry delays from fixed to exponential backoff.
- Added `ScheduleRetryBackoffFactor` with a default factor of 2.
- Added `ScheduleRetryMaxDelaySeconds` with a default cap of 300 seconds.
- Normalized invalid timing values to a positive bounded delay.
- Added deterministic growth and cap regression coverage.

## 4.2.12 — 2026-08-22

- Added independent `logs/schedule-execution.jsonl` execution history.
- Recorded timestamp, event and execution ids, template, layer, scheduled time,
  attempt number, result, duration, and sanitized error for every scheduled
  SHOW attempt.
- Excluded template field names and editorial values from the execution log.
- Logged retry attempts independently while preserving `schedule.json` as the
  current schedule state.
- Added persistence and privacy regression coverage for the JSONL record.

## 4.2.11 — 2026-08-22

- Added `ScheduleMaxRetries` and `ScheduleRetryDelaySeconds` settings.
- Kept retries disabled by default (`ScheduleMaxRetries = 0`) to avoid
  surprising delayed graphics on air.
- Persisted attempt count, next-attempt time, and last failure reason with each
  scheduled event.
- Deferred retries until their configured time and cleared retry state after a
  successful recurring occurrence.
- Preserved the existing no-replay rule for occurrences interrupted while
  marked `running` across a bridge restart.
- Added deterministic retry-delay regression coverage.

## 4.2.10 — 2026-08-22

- Added same-layer scheduled-event conflict detection.
- Added configurable `ScheduleConflictWindowMinutes`, defaulting to two
  minutes.
- Stored the resolved layer with new schedule events while retaining fallback
  lookup compatibility for older persisted events.
- Displayed each conflicting template and time in schedule review before the
  operator confirms the event.
- Added coverage for same-layer conflicts, different-layer non-conflicts, and
  the Telegram review warning.

## 4.2.9 — 2026-08-22

- Added administrator-editable `ReservedLayers` and `DisabledTemplateKeys`
  settings.
- Blocked SHOW preparation and final execution for reserved layers and
  temporarily disabled templates before any Cinegy query or mutation.
- Kept HIDE and EXIT available for reserved layers so operators can still take
  content off air safely.
- Applied the central execution policy to scheduled and interactive SHOW paths.
- Added regression coverage proving blocked policies send no Cinegy command.

## 4.2.8 — 2026-08-22

- Added a unique `air-*` correlation id to every SHOW, HIDE, EXIT, and live
  UPDATE attempt.
- Added a single structured `AIR_OP` bridge-log result containing action,
  result, duration, operator, chat, layer, target, and sanitized failure reason.
- Recorded blocked maintenance and uncertain-Cinegy attempts as well as
  successful and failed commands.
- Kept historical operation records in `bridge.log`; `onair.json` remains live
  state only.
- Added regression coverage for successful and blocked operation records.

## 4.2.7 — 2026-08-22

- Added a direct target-layer verification immediately before every SHOW.
- Blocked SHOW when Cinegy cannot confirm the target layer instead of assuming
  an unreachable layer is safe.
- Reconciled the verified layer with `onair.json` before any replacement or
  pre-show hide action.
- Added regression coverage proving that an uncertain layer sends no SHOW
  command and does not run reconciliation on an invalid response.

## 4.2.6 — 2026-08-22

- Added the currently tracked scene to SHOW review before a layer replacement.
- Identified whether that scene came from Cinegy Air, the bot, or a named
  operator.
- Added an explicit warning when the layer state sample is not fresh enough to
  trust during review.
- Added regression coverage for replacement and uncertain-state warnings.

## 4.2.5 — 2026-08-22

- Added explicit Cinegy state freshness classification: connected, stale,
  unavailable, or unknown.
- Added `CinegyStateStaleSeconds` with a 45-second default threshold.
- Displayed the classification in both the operator status and administrator
  full-status views.
- Added deterministic tests for all four classifications.

## 4.2.4 — 2026-08-22

- Added an administrator-controlled maintenance mode in Settings.
- Maintenance mode blocks SHOW, ordinary HIDE, EXIT, live-value updates, and
  creation or execution of scheduled SHOW operations without altering current
  on-air scenes.
- Due scheduled events remain pending and resume after maintenance is disabled.
- The administrator-only emergency hide-all action remains available during
  maintenance.
- Added regression coverage proving that blocked controls do not send Cinegy
  commands and that the emergency override is restricted to the hide-all path.

## 4.2.3 — 2026-08-22

- Added `logs/user-profiles.json` with approval time, approving administrator,
  and last authorized activity time; message content is never stored.
- Existing users receive unknown historical metadata until their first new
  activity instead of invented timestamps.
- User management now displays last activity, and revocation removes the
  runtime profile while preserving the audit event.
- Activity persistence is atomically flushed at most once per minute to keep
  disk writes out of the high-frequency interaction path.
- Added regression coverage for approval metadata, authorized-only activity,
  and profile cleanup on revocation.

## 4.2.2 — 2026-08-22

- Added an administrator user-management screen with Alias, role, and active
  or disabled state for every authorized private-chat user.
- Added persistent temporary disable/enable state in
  `logs/disabled-users.json` without deleting whitelist entries.
- Added confirmed permission revocation across chat/user and operator/admin
  lists, with audit logging.
- Prevented revoking or disabling the final active administrator.
- Added regression coverage for disabled authorization, unique user listing,
  confirmation, revocation, and final-administrator protection.

## 4.2.1 — 2026-08-22

- Added `HealthFailureAlertThreshold` (default 3) for consecutive Cinegy and
  Telegram failures before notifying administrators.
- Outages now produce one alert and one recovery message without repeats.
- Full health status includes the consecutive failure count and outage start.
- On-air status distinguishes `🟣 Cinegy Air` external or scheduled scenes
  from `🔵 Bot · operator` scenes created through Telegram.
- Successful HIDE and EXIT commands read the affected Cinegy layer and
  reconcile `onair.json` from the confirmed result.
- Added regression coverage for thresholding, deduplication, recovery, and
  clearing outage state.

## 4.2.0 — 2026-08-22

- Added independently editable per-user favourites in `logs/favorites.json`.
- Kept usage-ranked templates as fallback and added the disabled
  `SharedFavoritesEnabled` placeholder for a future unified list.
- Added persistent operator aliases in `logs/user-aliases.json`, managed by
  `/alias USER_ID name` and displayed in status and audit text.
- Added regression coverage for user isolation, removal, invalid templates,
  alias normalization, and alias removal.
- Expanded the development backlog to retain all previously proposed items.

## 4.1.2 — 2026-08-22

- Fixed the Pester harness writing synthetic template records into the live
  `logs/onair.json` file while `Run-Checks.ps1` was running.
- Added an explicit `RuntimePath` parameter so tests isolate `onair.json`,
  schedules, drafts, recent values, usage data, relay state, snapshots, and
  `bridge.log` inside Pester's `TestDrive`.
- Added a release-gate regression test that fails if test persistence points
  at the live `logs` directory.
- Verified the live `onair.json` hash and timestamp remain unchanged across the
  complete 146-test suite.

## 4.1.1 — 2026-08-22

- Added a full Cinegy layer comparison during bridge startup before operator
  commands are accepted.
- Startup now discovers scenes launched directly from Cinegy and restores them
  to `onair.json` as current, hideable state.
- Unreachable startup layers preserve their previous local records and produce
  an explicit warning in `bridge.log` rather than being treated as hidden.
- Added a startup reconciliation summary to `bridge.log` with checked, added,
  and removed counts.
- Added regression coverage for full startup discovery and uncertain-layer
  preservation. Existing restart tests continue to verify scheduled
  occurrences are not replayed after a service restart.

## 4.1.0 — 2026-08-22

- Added an operator-triggered live reconciliation against every Cinegy GFX
  layer referenced by `templates.json` from both Status and the Layers panel.
- Scenes started directly in Cinegy are discovered, recorded in `onair.json`
  with `Source: cinegy`, and exposed to operators for HIDE/EXIT actions.
- Kept `onair.json` as current operational state only; historical actions and
  detailed add/remove reasons are written to `bridge.log`.
- Unreachable or uncertain Cinegy reads never add or remove an on-air record.
- Persisted each record's source (`bridge` or `cinegy`) across restarts.
- Added the last successful Cinegy comparison time to the status screen and a
  comparison summary to the Layers panel.
- Added regression coverage for discovery, uncertain reads, comparison from
  the Layers panel, and detailed removal logging.

## 4.0.1 — 2026-08-22

- Fixed the release gate so the five on-air persistence smoke tests are
  discovered and executed by Pester.
- Prevented `onair.json` from being rewritten on every Cinegy sync when the
  tracked `ActiveId` has not changed, with a regression test for the behavior.
- Restricted the bridge to private Telegram chats; group, supergroup, and
  channel updates are ignored before authorization or command dispatch.
- Added regression coverage proving a successful EXIT removes and persists the
  on-air template record, while a failed Cinegy EXIT keeps it for recovery.
- Cleaned actionable PSScriptAnalyzer warnings and documented the intentional
  UTF-8-without-BOM and private helper naming exclusions.
- Added `DEVELOPMENT-PLAN.md` with the 4.0.1–5.0 roadmap and release gate.

## 4.0.0

- Fixed onair.json losing live templates: a layer that is genuinely on air is
  no longer dropped just because Cinegy reports a different ActiveId (Cinegy
  generates its own id and ignores the bot's EventId). The record is kept and
  Cinegy's real id is adopted.
- Restored the external-change alert (regression in 3.1.1 on-air fix): a layer
  removed because Cinegy reports it hidden/off-air now produces a `Changes`
  entry, so admins are notified again.
- Added on-air dirty tracking so an updated ActiveId is persisted on the next
  sync instead of only on removal.
- Raised `CinegyMonitorTimeoutSeconds` default from 1 to 3 seconds so Air Pro
  status reads stop timing out and dropping tracked layers.
- Restructured the simple and full status reports with sections, an overall
  status line, and a local timestamp.
- Added `Tests/Smoke-OnAir.Pester.ps1` — a no-server, no-disk smoke test for
  on-air persistence (runs as part of Run-Checks.ps1).

## 3.1.1

- Replaced free-text `LayerNames` editing with an administrator-only layer
  picker: select a layer, enter one label, or use a dedicated clear button.
- Layer labels are validated before saving to prevent malformed configuration.

## 3.0.0 — 2026-08-20

- Added mandatory review before every interactive, preset, or typed `SHOW`,
  required fields, layer preparation locks, draft navigation, previews, and
  two-step confirmation for hide-all.
- Added persistent per-user drafts, repeat-with-edit, recent field choices that
  exclude sensitive values, and a live quick-action layer panel.
- Added administrator preset creation, value editing, rename, and deletion with
  review, atomic writes, and timestamped template-registry backups.
- Added reliable one-time, daily, and weekly scheduling with clock/time-zone
  validation, upcoming-event cancellation, atomic persistence, and crash-safe
  occurrence keys that prevent automatic replay.
- Added `/health`, Telegram/Cinegy latency and health history, startup and
  recovery notifications, and a redacted administrator diagnostics report.
- Split status by role: every authorized user gets a lightweight Air summary,
  while administrators get a combined full layer and service-health report.
- Clarified the layer panel states and its quick-hide behavior in the Arabic help.
- Added an administrator-selected `HideAllLayers` scope, so the emergency
  hide-all action affects only the layers selected from Settings.
- Enriched external Cinegy-change alerts with the tracked template, old/new
  item details, Air endpoint, and available Cinegy client identity.
- Added Arabic unit/description labels to administrator numeric settings.
- Added administrator-configurable operational layer names throughout layer
  status, actions, emergency confirmation, and external-change alerts.
- Added a read-only administrator template catalogue and protected, disabled-
  by-default full template definition management with atomic backups.
- Added configuration backup comparison/restoration and migration coverage.
- Added a real Cinegy dashboard for every GFX layer referenced by the template
  registry, distinguishing bridge-owned, external, hidden, and unknown state.
- Added layer metadata from Cinegy `/status`: active item name, output state,
  license state, and connected client identity.
- Added one-minute Cinegy `/metrics` health aggregation for output, dropped
  frames, missing input, read errors, read time, and heartbeat.
- Added deduplicated admin alerts for external scene changes, unhealthy or
  unreachable telemetry, and health recovery.
- Bounded automatic monitoring requests with a dedicated short timeout.
- Expanded the release gate to validate required files, JSON, PowerShell
  syntax, PSScriptAnalyzer, and the complete Pester suite.
- Kept the existing regular-user/admin permission model and automatic migration
  of 2.x configuration settings.

## 2.8.4

- Improved role-aware Arabic help with short on-air workflows.
# 4.3.0

- أضيف زر دائم **إدارة شريط الأخبار** مع مسودة واحدة مقفلة، إدخال يدوي، تعديل، حذف وترتيب، واستيراد TXT UTF-8.
- أصبح نشر `news.txt` ذريًا مع فحص تعارض SHA-256 ونسخة احتياطية قبل الاستبدال؛ لا يغيّر التحرير أو الاستيراد الملف الحي قبل التأكيد.
- أضيفت صلاحيات مستقلة للمشغل للحذف والاستعادة ومسح الكل، مع بقاء الافتراضي للمشرف فقط، وفاصل قابل للضبط افتراضيه `|`.
# 4.3.1

- أضيف اسم عربي واضح لمسار ملف الأخبار في إعدادات المشرف، مع إبقاء المسار الحالي افتراضيًا ورفض أي مسار غير مطلق أو لا ينتهي بـ `.txt`.
