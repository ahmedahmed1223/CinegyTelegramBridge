# دليل الوكلاء — كيف يُطوَّر هذا الجسر ويُوثَّق ويُختبر

<!--
    Written for whoever - person or agent - opens this repository next.
    Everything here is a rule the codebase already follows; nothing in it is
    aspiration. Where a rule exists because something once broke, the reason
    is written down, because a rule without its reason is the first thing an
    agent argues itself out of.

    Claude Code and Codex both read this file. Keep it in sync with the code.
-->

## ما هذا البرنامج

جسر بين Telegram وCinegy Air Pro Titler. عاملٌ في غرفة الأخبار يرسل رسالة، فيظهر
قالب رسومي **على الهواء**. هذه الجملة تحكم كل قرار في المستودع: خطأٌ هنا يظهر
للمشاهدين، لا في سجل يُقرأ لاحقًا.

| المكوّن | ما هو |
|---|---|
| `TelegramBridge.ps1` | نقطة الدخول: التهيئة المرتّبة، الإعدادات، حلقة الاستطلاع الطويل. **PowerShell 7**. |
| `Parts/*.ps1` | تعريفات دوال تُحمَّل بـ dot-source داخل نطاق السكربت نفسه. **ليست وحدات**. |
| `Modules/*.psm1` | وحدات مجال وتخزين قابلة للاختبار وحدها؛ منطق المجال لا يتصل بـ Telegram أو Cinegy، ووحدات التخزين هي الاستثناء المعلن للقرص. |
| `Tests/*.Tests.ps1` | Pester 5+. كل ملف يبدأ بـ `. (Join-Path $PSScriptRoot 'Bridge.TestContext.ps1')`. |
| `Manager/BridgeManager/` | **برنامج التحكم**: تطبيق Windows Forms (C#/.NET) يشغّل الجسر ويوقفه، ويعرض السجل والحالة، ويحرّر الإعدادات دون فتح `config.json` بيد. |
| `Run-Checks.ps1` | بوابة الإصدار: صحة التركيب + PSScriptAnalyzer + Pester. |

## قواعد لا تُخالَف

1. **لا تُرسل أمرًا يغيّر الهواء** أثناء التطوير أو التشخيص. الاستعلام عن
   `/gfx_<n>/status` و`/status/active` قراءةٌ فقط ومسموح. أما `SHOW` و`HIDE`
   و`EXIT_SCENE_LOOP` فتنتظر نافذة تغيير معتمدة وطبقة تجربة (`TemplateTestLayer`).
2. **`config.json` يحمل `BotToken`.** لا تطبعه ولا تنسخه ولا ترفعه. وكل إعداد
   اسمه يطابق `token|secret|password|apikey` يُعرض بطوله لا بنصّه — القاعدة في
   `Format-ConfigDiffValue` بـ `Parts/Bridge.Core.ps1`.
3. **الجسر يكتب `config.json` عند كل حفظ إعداد.** فلا تحرّره يدويًا والجسر يعمل؛
   عدّل من شاشة الإعدادات في البوت أو من برنامج التحكم.
4. **كل نص من مستخدم غير موثوق** — اسم مستعار، اسم طالب وصول، خبر، عنوان صف —
   يُهرَّب بـ `ConvertTo-TelegramHtmlText` ويُقصّ بطول أقصى قبل أن يدخل شاشة.
5. **لا ملفات تشغيل في Git**: `logs/`، `config.json`، `templates.json`،
   `artifacts/`، `dist/`، ومخرجات البناء تحت `Manager/BridgeManager/bin|obj`.

## طقوس الإصدار — كل تغيير سلوكي يمر بها كاملة

```powershell
# 1. ارفع الرقم
#    TelegramBridge.ps1   ->  $script:BridgeVersion = 'X.Y.Z'
# 2. أضف مدخلًا في أعلى Get-WhatsNewSections  (Parts/Bridge.ShowFlow.ps1)
#    بلغة المشغّل: ما تغيّر على شاشته وما يفعله مختلفًا. لا أسماء دوال.
# 3. أضف قسمًا في أعلى CHANGELOG.md  (بالعربية، وفيه السبب لا الوصف فقط)
# 4. أضف قسمًا في أعلى README.md    (بالإنجليزية، فقرة أو فقرتان)
# 5. حدّث التثبيتين في Tests/Bridge.SettingsScreens.Tests.ps1
#    ($script:BridgeVersion و @(Get-WhatsNewSections)[0].Version)
# 6. البوابة:
pwsh -File Run-Checks.ps1
# 7. commit ثم push
```

`Run-Checks.ps1` يفشل على **تحذيرات** PSScriptAnalyzer لا أخطائها فقط. ولا تُدفَع
شجرة حمراء.

### إعداد جديد

الإعداد لا يوجد ما لم يُسجَّل في **أربعة** مواضع داخل `TelegramBridge.ps1`:

1. `$script:DefaultSettings` — القيمة الافتراضية ومعها تعليق سطر واحد.
2. `$script:SettingMetadata` — الوحدة والوصف العربي.
3. قائمة الفئة في `$script:SettingCategoryDefinitions` — وإلا لم يظهر في أي شاشة.
4. `$script:SettingNavigationLabels` — الاسم العربي القصير.

> هذه ليست شكليات: أربعة إعدادات صلاحيات قُرئت بـ `Get-Setting` ولم تُسجَّل قط،
> فمرّت الاختبارات (كانت تحقن القيم) والميزة كلها ميتة على الجهاز. يوجد الآن
> اختبار يمسح **كل** أسماء `Get-Setting` في الشجرة ويقارنها بـ `DefaultSettings`.
> أضف الإعداد كاملًا وإلا أسقطك ذلك الاختبار.

إعدادٌ إطفاؤه يُضعف الأمان يُضاف إلى `$script:ProtectedSettings` فيُطلب تأكيد.

### ملف حالة جديد

اتبع نمط `logs/user-profiles.json`: متغيّر مسار في `TelegramBridge.ps1`، دالتا
`Import-*` و`Save-*` في الجزء المناسب، وملف مؤقت **فريد** في المجلد نفسه ثم نسخة
احتياطية صالحة واستبدال ذري، وتواريخ بصيغة `'o'`، وقراءة كل حقل عبر `Get-JsonProp`
(فـ `Set-StrictMode -Version Latest` يرمي على الخاصية الغائبة)، واستدعاء `Import-*`
في كتلة التهيئة المرتّبة.

## مصائد PowerShell التي كلّفتنا إصدارات

| المصيدة | الصواب |
|---|---|
| `@()` يسطّح المصفوفات المتداخلة، فصفوف لوحة المفاتيح تنهار → `400 Bad Request` | فاصلة قبل **كل** صف: `$rows += , @( ... )` |
| `[math]::Max(0, $double)` يختار حِمل `int` ويقصّ الكسر | `[math]::Max(0.0, $x)` |
| `return , $array` يتداخل حين يلفّ المستدعي بـ `@()` | `return $array` |
| كتلة سكربت تُستدعى بـ `&` نطاقها ديناميكي، فتقرأ متغيّرات الدالة المضيفة | سمِّ متغيّرات الكتلة بأسماء مميّزة، ووثّق ذلك |
| دالة تُخرج قيمة عرضًا (مثل `Set-PendingState`) تلوّث قيمة الإرجاع | `\| Out-Null` |
| `Set-StrictMode -Version Latest` يرمي على خاصية غائبة | `Get-JsonProp $obj 'Name'` |
| بيانات `callback_data` محدودة بـ **64 بايت** | عنونة بالموضع لا بالاسم |
| رسالة Telegram محدودة بـ **4096 حرفًا** | `Send-TelegramPagedText` أو تصفيح الشاشة |

## الاختبار

```powershell
pwsh -Command "Invoke-Pester -Path Tests/Bridge.Access.Tests.ps1 -Output Detailed"
pwsh -File Run-Checks.ps1
pwsh -File Run-Checks.ps1 -SkipAnalyzer
```

- ملف اختبار جديد يُسجَّل في مصفوفة الملفات داخل `Run-Checks.ps1`، وإلا لم يُفحص
  تركيبه.
- `Bridge.TestContext.ps1` يملك كتلة `BeforeAll` الوحيدة في الملف. الدوال
  المساعدة تُعرَّف `function global:` لأن دوال المستوى الأعلى لا تعيش إلا في طور
  الاكتشاف.
- **`$script:` في ملف الاختبار ليس دائمًا الكائن الذي تكتب فيه دوال الجسر.**
  `$script:PendingApprovals` يفترق؛ `$script:UserAliases` لا يفترق. حين تشك،
  اقرأ الحالة عبر الشاشة التي تعرضها (`Get-PendingApprovalsText`) وغيّرها عبر
  الدالة التي تغيّرها (`Deny-UserAccess`)، لا بلمس الجدول.
- الاختبار الذي يعتمد على التاريخ يُثبَّت بـ `-Now` صريح؛ اختبارٌ كُتب بـ «قبل
  ساعتين» انكسر بعد منتصف الليل.
- اختبار سلوك لا اختبار صياغة: اسم الاختبار يصف ما يجب أن يحدث للمستخدم.

## التوثيق

| أين | لمن | باللغة |
|---|---|---|
| `Get-WhatsNewSections` | المشغّل داخل البوت | العربية، جملة لكل تغيير مرئي |
| فصول `Get-HelpChapters` | المشغّل والمشرف | العربية، كل فصل شاشة واحدة |
| `CHANGELOG.md` | من يصون الجسر | العربية، ومعه **السبب** |
| `README.md` | القارئ الخارجي | الإنجليزية |
| تعليقات الكود | الوكيل التالي | الإنجليزية، وتشرح **لماذا** |

تعليق يعيد صياغة السطر الذي تحته لا قيمة له. التعليق الذي يستحق البقاء يحفظ
السبب: ما الذي كُسر، ولماذا هذا الحل دون غيره، وما الذي جُرّب وفشل. وحين تُبسِّط
عن قصد، اكتب `ponytail:` وسمِّ السقف وطريق الترقية.

## برنامج التحكم (BridgeManager)

`Manager/BridgeManager/` — تطبيق Windows Forms بلغة C# يشغّل الجسر ويوقفه ويعيد
تشغيله، ويتابع `logs/bridge.log` حيًّا، ويحرّر الإعدادات في نافذة بدل تحرير
`config.json` بيد. رقم إصداره يُزامَن مع رقم الجسر، فارفعهما معًا.

```powershell
dotnet build Manager/BridgeManager/BridgeManager.csproj
.\scripts\Build-BridgeManager.ps1          # ينشر ثم يشغّل --selftest ويفشل عليه
```

`bin/` و`obj/` مُتجاهَلان في Git. ولا يجوز للبرنامج أن يعرض توكن أو يكتبه في
سجل: القاعدة نفسها المطبَّقة في الجسر. والحقل مخفي افتراضيًّا، ويُعطَّل كليًّا حين
تكون قيمة `BotToken` مرجعًا يبدأ بـ`dpapi:`.

- **المنطق الجديد يُختبر في `SelfTest` بـ `Program.cs`**، لا بإطار اختبار: لا
  Pester هنا. اجعل ما تكتبه دالة `internal static` صافية ثم أضف `Check` لها.
  `Build-BridgeManager.ps1` يشغّلها بعد كل نشر ويرمي إن رجعت بغير صفر. (بقيت
  ستة فحوص لا يستدعيها أحد لعدة إصدارات — فحصٌ لا يُنفَّذ غير موجود.)
- **قوائم `$managed` في `Save-Config` ليست ملكًا للمدير.** الجسر وهو يعمل يكتب
  نسخته فوق `AllowedChatIds` و`AdminChatIds` و`AllowedUserIds` و`AdminUserIds`.
  إن أضفت حقلًا جديدًا إلى تلك القائمة فأضف اسمه إلى `SettingsForm.BridgeManagedKeys`،
  وإلا عاد التعديل من شاشة المدير يضيع بصمت.
- **الألوان والعناصر كلها من `Theme.cs`**، ومنه الوضعان الفاتح (الافتراضي)
  والداكن. لا تكتب لونًا صريحًا في نموذج. وكل عنصر يبنيه `Theme` يحمل دالة
  إعادة تلوينه في `Tag`، و`Theme.Apply` تمشي على الشجرة وتستدعيها — فالتبديل
  فوري بلا إعادة تشغيل.
- **مصيدتان في WinForms هنا**: `CheckBox` بـ`FlatStyle.Flat` يرسم مربّعه بألوان
  الأب فيختفي على الداكن (استعمل `ToggleChip` أو `FlatStyle.System`)؛ و`Padding`
  مع `AutoSize` على `CheckBox` بمظهر زر يُخفي النص كليًّا (الحشو بمسافات في
  النص و`MinimumSize`).
- **`logs/bridge.liveness`** نبضة يكتبها الجسر بعد كل دورة استطلاع ويقرؤها
  المدير لكشف التعليق. لا تجعل الكشف يعتمد على صمت السجل: الجسر السليم يصمت
  ١٠–١٨ ساعة كل ليلة، وقياس ذلك موجود في `CHANGELOG.md` تحت 7.63.0.
- **السجل الحي محدود.** احتفظ بعدد ثابت من الأسطر المعروضة والمعلّقة، وفرّغ
  دفعة محدودة في كل نبضة واجهة، وقدّم `WARN` و`ERROR` على `INFO` و`DEBUG`؛ لا
  تلوّن نصًا حساسًا ولا تسجله لهذا الغرض. أضف اختبار `SelfTest` لكل سياسة جديدة.

## قبل أن تقول «تم»

- [ ] `pwsh -File Run-Checks.ps1` يمرّ كاملًا — لا تحذيرات Analyzer ولا اختبار فاشل.
- [ ] كل إعداد جديد مسجَّل في المواضع الأربعة.
- [ ] كل نص غير موثوق مُهرَّب ومقصوص.
- [ ] الرقم والـWhat's New وCHANGELOG وREADME والتثبيتان محدَّثة.
- [ ] لا سرّ ولا ملف تشغيل في `git status`.
- [ ] ما يقوله التقرير هو ما حدث فعلًا: اختبار فاشل يُذكر، وخطوة تُخطَّت تُقال.
