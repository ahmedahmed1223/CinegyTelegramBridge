# Version 6.2 — تنظيف الأساس

**الحالة:** مُصدَر `6.2.0` · يلي `6.1.0`

هذه ليست ميزات للمشغّل. كلها إزالة كود لا يعمل، وتوحيد منطق مزدوج، وشدّ بوابة
الجودة. القيمة هي أن تعبّر الاختبارات والتوثيق عن الواقع بدل أن يبالغا فيه.

## لماذا الآن

مراجعة `6.1.0` وجدت تسع دوال مُصدَّرة تمرّ عليها اختبارات ولا يستدعيها أي كود
إنتاجي. حُذفت وحدة كاملة منها في `6.1.0` (`BridgeStateMigration`)، وبقيت سبع
دوال داخل وحدات حيّة. الأثر ليس بطئًا ولا عطلًا، بل **ثقة زائفة**: عدد
الاختبارات يوحي بتغطية أوسع مما هو موصول فعلًا.

## المهام

### 6.2.1 — حذف الدوال السبع غير المستخدمة ✅ مُنجَز

| الوحدة | الدوال |
|---|---|
| `BridgeLiveScenes.psm1` | `Get-BridgeLiveScene`، `Get-BridgePrimarySceneForLayer` |
| `BridgeOperationLifecycle.psm1` | `New-BridgeSceneCallbackToken`، `Resolve-BridgeSceneCallbackToken`، `Get-BridgeOperationStatusText` |
| `BridgeSettingsSchema.psm1` | `Test-BridgeSettingValue`، `Reset-BridgeSettingToDefault` |

الوحدات الثلاث حيّة — تُحذف الدوال وحدها مع اختباراتها ومن `Export-ModuleMember`.

**التحقق:** `Run-Checks.ps1` أخضر، وعدد الاختبارات ينقص بمقدار المحذوف فقط.

**خطر:** منخفض جدًا. لا مستدعي في الإنتاج (مُتحقَّق منه بمسح كل ملفات `Parts/`
و`TelegramBridge.ps1`).

### 6.2.2 — قياس `PSUseApprovedVerbs` ثم إعادته للبوابة ✅ مُنجَز

القاعدة مستثناة في [`Run-Checks.ps1`](../Run-Checks.ps1) ضمن `-ExcludeRule`،
ولهذا مرّ `Queue-BridgeOperation` (فعل غير معتمد) حتى اكتُشف يدويًا لاحقًا.

خطوتان منفصلتان:

1. **قياس فقط** ✅ — أربع مخالفات لا غير:

   | الدالة | الملف |
   |---|---|
   | `Apply-SettingsImport` | `Parts/Bridge.Admin.ps1:957` |
   | `Apply-TemplateRegistryImport` | `Parts/Bridge.Admin.ps1:1285` |
   | `Record-UserApprovalMetadata` | `Parts/Bridge.Users.ps1:71` |
   | `Escape-XmlValue` | `Modules/CinegyAirTitler.psm1:41` |

   الأخيرة وحدها هي «مساعد XML الخاص» الذي يذكره تعليق `Run-Checks.ps1` كاستثناء
   متعمَّد؛ الثلاث الأخرى تسلّلت خلف الاستثناء نفسه.

2. **إصلاح ثم إعادة القاعدة** ✅ — أُعيدت التسمية والقاعدة مفعّلة في البوابة:

   | القديم | الجديد |
   |---|---|
   | `Apply-SettingsImport` | `Set-ImportedSettings` |
   | `Apply-TemplateRegistryImport` | `Set-ImportedTemplateRegistry` |
   | `Record-UserApprovalMetadata` | `Write-UserApprovalMetadata` |
   | `Escape-XmlValue` | `ConvertTo-XmlSafeValue` |
   | `Fail-Step` | `Stop-Step` |

   **درس:** القياس اليدوي أحصى أربعًا لأنه مسح `Parts/` و`Modules/` فقط؛ القاعدة
   نفسها كشفت خامسة في `scripts/Test-ServiceLifecycle.ps1`. تفعيل القاعدة أدق من
   أي مسح يدوي — وهذا هو سبب إعادتها لا مجرد إصلاح ما وجدناه.

### 6.2.3 — توحيد `cfg:reset` و`cfg:search` ✅ مُنجَز

قُورن التنفيذان، واختير **الحذف**: `Reset-BridgeSettingToDefault` و
`Test-BridgeSettingValue` حُذفتا مع 6.2.1، ولم يخسر الإنتاج شيئًا لأن مسار
الإنتاج يستدعي بالفعل دوال الوحدة التي تعمل: `Find-BridgeSettings` لـ
`cfg:search` و`Get-ModifiedBridgeSettings` لـ«المعدّل فقط». المحذوفتان كانتا
تحققًا مكرّرًا لم يصله أحد.

بقي الجزء الثاني من القرار: كتابة اختبارات لتنفيذ الإنتاج. أُضيفت خمسة إلى
`Tests/Bridge.SettingsScreens.Tests.ps1` تغطي ما لم يكن مغطى:

| الاختبار | يحرس |
|---|---|
| يسأل قبل إعادة الإعداد | `cfgrgo:` لا يُكتب قبل التأكيد |
| يتجاهل اسمًا غير معروف | لا رسالة ولا كتابة لاسم ليس في `DefaultSettings` |
| يوجّه نص البحث ويمسح الطلب | `Complete-SettingsSearch` يقصّ المسافات ويصفّي الحالة |
| يعرض ما طابقه schema فقط | نتيجة `Find-BridgeSettings` هي ما يظهر على الشاشة |
| يتجاهل بحثًا بلا طلب معلّق | لا شيء يُرسل حين لا توجد حالة `settings_search` |

### 6.2.4 — تقسيم `Tests/Bridge.Tests.ps1` ✅ مُنجَز

قُسِّم 8095 سطرًا إلى تسعة ملفات حسب الموضوع. الإعداد المشترك
(`BeforeDiscovery` و`BeforeAll` و`New-TempTemplateFile`) خرج إلى
`Tests/Bridge.TestContext.ps1` ويُستدعى بسطر واحد في رأس كل ملف، فلا يُنسخ
خمسون سطرًا تسع مرات.

| الملف | Describe |
|---|---|
| `Bridge.Templates.Tests.ps1` | 21 |
| `Bridge.OnAir.Tests.ps1` | 22 |
| `Bridge.Admin.Tests.ps1` | 20 |
| `Bridge.Cinegy.Tests.ps1` | 12 |
| `Bridge.NewsScreens.Tests.ps1` | 10 |
| `Bridge.SettingsScreens.Tests.ps1` | 10 |
| `Bridge.Users.Tests.ps1` | 7 |
| `Bridge.Schedule.Tests.ps1` | 5 |
| `Bridge.Tests.ps1` (مساعدات نقية) | 16 |

الملفات التسعة مسجّلة في قائمة الملفات المطلوبة في `Run-Checks.ps1`. لم يُحذف
اختبار ولم يُعدّل نصه؛ النقل كان بحدود كتل `Describe` كاملة.

### 6.2.5 — تنظيف صغير ✅ مُنجَز

- `Get-MissedEventsText` كان يعرّف `$read` داخليًا يكرر `Get-AuditRecordField`،
  ويحلّل الطابع الزمني بـ`TryParse` عاريًا بدل `Read-AuditRecordStamp`. صار
  يستدعي المساعدَين المشتركين، فقراءة الطوابع في التقرير صارت هي نفسها
  المستخدمة في بقية قرّاء `audit.jsonl` (`RoundtripKind`).
- `artifacts/` و`dist/` مُدرجتان في `.gitignore` ولا يتتبع git أي ملف فيهما —
  فالمشكلة المقصودة غير موجودة. أشجار البناء القديمة تُركت على القرص عمدًا:
  حزمة `6.0.0` هي دليل التحقق المذكور في `docs/VERSION-6.md`، وحذفها لا
  يُسترجع. مسحها قرار مشغّل، لا خطوة تنظيف.

## خارج النطاق عمدًا

**تقسيم `Bridge.Admin.ps1` و`Bridge.ShowFlow.ps1`.** يتجاوزان حد 800 سطر،
لكن تجاوز الحد وحده ليس سببًا كافيًا لإعادة هيكلة ملف يعمل. يُقسَّم الملف حين
يؤلم فعلًا: تعارض دمج متكرر أو صعوبة إيجاد دالة. المرشح الحقيقي الوحيد هو
`Bridge.Callbacks.ps1` لأنه الأكثر تعديلًا.

## الترتيب

```
6.2.1  →  6.2.2 (قياس)  →  6.2.3  →  6.2.2 (إصلاح)  →  6.2.4  →  6.2.5
```

الحذف أولًا: تقسيم ملف يحوي كودًا ميتًا ينقل الكود الميت من مكان لآخر فقط.

**التحقق النهائي:** `Run-Checks.ps1` أخضر — Parser سليم، Analyzer بلا نتائج مع
`PSUseApprovedVerbs` مفعّلة، و`767` اختبارًا ناجحًا بلا فشل.
