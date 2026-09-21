#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the screens an operator passes through: hide-all, the permission refusals, and the template and confirmation keyboards.

    Split out when the catalogue passed a thousand lines: one file per domain
    keeps each under the size this repository asks a file to stay, and puts a
    translator in front of one subject at a time instead of the whole bot.
    Nothing about the contract changed - every entry still carries both
    languages, and Test-BridgeTextCatalogue still reads them all together.
#>

function Add-BridgeTextScreens {
    <# Fills the shared dictionary in place. Partial by design: the catalogue
       is one ordered map assembled from four files, not four maps. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

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

    # --- Operator-facing screens in Bridge.Keyboards.ps1 -----------------
    $catalogue['confirm.hideYes'] = @{ ar = '✅ نعم، أخفِ'; en = '✅ Yes, hide it' }
    $catalogue['confirm.exitYes'] = @{ ar = '✅ نعم، اخرج'; en = '✅ Yes, exit' }
    $catalogue['confirm.hideAllYes'] = @{ ar = '🚨 نعم، إخفاء الكل'; en = '🚨 Yes, hide everything' }
    $catalogue['confirm.send'] = @{ ar = '✅ تأكيد الإرسال'; en = '✅ Confirm and send' }
    $catalogue['confirm.edit'] = @{ ar = '✏️ تعديل'; en = '✏️ Edit' }
    $catalogue['confirm.preview'] = @{ ar = '🔎 معاينة'; en = '🔎 Preview' }
    $catalogue['confirm.skip'] = @{ ar = '⏭ تخطي'; en = '⏭ Skip' }
    $catalogue['confirm.approve'] = @{ ar = '✅ موافقة'; en = '✅ Approve' }
    $catalogue['confirm.reject'] = @{ ar = '❌ رفض'; en = '❌ Reject' }
    $catalogue['confirm.grantYes'] = @{ ar = '✅ نعم، امنح الوصول'; en = '✅ Yes, grant access' }
    $catalogue['confirm.undo'] = @{ ar = '❌ تراجع'; en = '❌ Undo' }
    $catalogue['confirm.resetYes'] = @{ ar = '♻️ نعم، استعد الافتراضي'; en = '♻️ Yes, restore defaults' }
    $catalogue['layer.exit'] = @{ ar = '🚪 خروج'; en = '🚪 Exit' }
    $catalogue['layer.hideThis'] = @{ ar = '🙈 إخفاء هذا (طبقة {0})'; en = '🙈 Hide this (layer {0})' }
    $catalogue['layer.compare'] = @{ ar = '🔎 فحص ومقارنة مع Cinegy'; en = '🔎 Check and compare with Cinegy' }
    $catalogue['layer.rollbackSafe'] = @{ ar = '↩️ تراجع آمن'; en = '↩️ Safe undo' }
    $catalogue['layer.rollbackRestore'] = @{ ar = '↩️ استعادة المشهد السابق'; en = '↩️ Restore the previous scene' }
    $catalogue['layer.rollbackConfirm'] = @{ ar = '✅ تأكيد التراجع'; en = '✅ Confirm the undo' }
    $catalogue['timer.plus30'] = @{ ar = '⏱ +30ث'; en = '⏱ +30s' }
    $catalogue['timer.plus1m'] = @{ ar = '⏱ +1د'; en = '⏱ +1m' }
    $catalogue['timer.minus30'] = @{ ar = '⏱ -30ث'; en = '⏱ -30s' }
    $catalogue['timer.minus1m'] = @{ ar = '⏱ -1د'; en = '⏱ -1m' }
    $catalogue['onair.none'] = @{ ar = '⚫️ لا شيء على الهواء'; en = '⚫️ Nothing on air' }
    $catalogue['onair.allWell'] = @{ ar = '🟢 كل شيء سليم'; en = '🟢 All well' }
    $catalogue['onair.layersUp'] = @{ ar = '🟠 طبقات على الهواء'; en = '🟠 Layers on air' }
    $catalogue['onair.unconfirmed'] = @{ ar = '🟠 تعذّر تأكيد الحالة من Cinegy'; en = '🟠 Could not confirm the state from Cinegy' }
    $catalogue['onair.notChecked'] = @{ ar = 'لم يتم التحقّق بعد'; en = 'Not checked yet' }
    $catalogue['onair.checkFailed'] = @{ ar = '⚠️ تعذّر التحقّق من Cinegy'; en = '⚠️ Could not check Cinegy' }
    $catalogue['onair.unknown'] = @{ ar = 'غير معروف'; en = 'Unknown' }
    $catalogue['onair.external'] = @{ ar = 'Cinegy (خارج الجسر)'; en = 'Cinegy (outside the bridge)' }
    $catalogue['onair.templateTest'] = @{ ar = 'اختبار قالب'; en = 'Template test' }
    $catalogue['onair.sourceExternal'] = @{ ar = 'المصدر: Cinegy (خارج الجسر)'; en = 'Source: Cinegy (outside the bridge)' }
    $catalogue['onair.sourceTest'] = @{ ar = 'المصدر: اختبار قالب'; en = 'Source: a template test' }
    $catalogue['onair.noRecord'] = @{ ar = 'الطبقة {0} — لا يوجد سجل لدى الجسر'; en = 'Layer {0} — the bridge has no record' }
    $catalogue['onair.text'] = @{ ar = 'النص: {0}'; en = 'Text: {0}' }
    $catalogue['onair.textUnknown'] = @{ ar = 'النص: غير مسجّل (عُرض قبل تفعيل الخيار أو من خارج الجسر)'; en = 'Text: not recorded (shown before the option was on, or from outside the bridge)' }
    $catalogue['menu.pickFromList'] = @{ ar = 'اختر من القائمة:'; en = 'Choose from the menu:' }
    $catalogue['templates.noneDefined'] = @{ ar = 'لا توجد قوالب معرّفة'; en = 'No templates are defined' }
    $catalogue['templates.noValid'] = @{ ar = 'لا توجد قوالب صالحة'; en = 'No valid templates' }
    $catalogue['templates.noMatch'] = @{ ar = 'لا توجد نتائج مطابقة'; en = 'Nothing matched' }
    $catalogue['templates.categories'] = @{ ar = '🗂 التصنيفات'; en = '🗂 Categories' }
    $catalogue['templates.all'] = @{ ar = '📋 كل القوالب'; en = '📋 All templates' }
    $catalogue['templates.uncategorised'] = @{ ar = 'غير مصنف'; en = 'Uncategorised' }
    $catalogue['templates.noCategories'] = @{ ar = 'لا توجد تصنيفات معرّفة'; en = 'No categories are defined' }
    $catalogue['templates.noDescription'] = @{ ar = 'لا يوجد وصف.'; en = 'No description.' }
    $catalogue['templates.noFields'] = @{ ar = 'بلا حقول تحريرية'; en = 'No editable fields' }
    $catalogue['templates.neverUsed'] = @{ ar = 'لم يُستخدم بعد'; en = 'Never used yet' }
    $catalogue['templates.neverUsedShort'] = @{ ar = 'لم يُستخدم'; en = 'Never used' }
    $catalogue['templates.liveNow'] = @{ ar = '🔴 على الهواء الآن'; en = '🔴 On air now' }
    $catalogue['templates.notShowing'] = @{ ar = '⚫️ غير معروض'; en = '⚫️ Not showing' }
    $catalogue['templates.choose'] = @{ ar = '▶️ اختيار هذا القالب'; en = '▶️ Choose this template' }
    $catalogue['templates.back'] = @{ ar = '⬅️ القوالب'; en = '⬅️ Templates' }
    $catalogue['templates.searchPrompt'] = @{ ar = '🔎 أرسل جزءًا من اسم القالب أو وصفه أو تصنيفه:'; en = '🔎 Send part of the template name, its description or its category:' }
    $catalogue['templates.searchEmpty'] = @{ ar = 'لم تُدخل عبارة بحث.'; en = 'No search term was given.' }
    $catalogue['templates.layerOf'] = @{ ar = 'الطبقة: {0}'; en = 'Layer: {0}' }
    $catalogue['templates.deviceLayer'] = @{ ar = 'طبقة الجهاز: {0}'; en = 'Engine layer: {0}' }
    $catalogue['common.search'] = @{ ar = '🔎 بحث'; en = '🔎 Search' }
    $catalogue['common.refresh'] = @{ ar = '🔄 تحديث'; en = '🔄 Refresh' }
    $catalogue['common.delete'] = @{ ar = '🗑 حذف'; en = '🗑 Delete' }
    $catalogue['common.rename'] = @{ ar = '🏷 إعادة تسمية'; en = '🏷 Rename' }
    $catalogue['common.saveChange'] = @{ ar = '✅ حفظ التغيير'; en = '✅ Save the change' }
    $catalogue['common.done'] = @{ ar = '✅ تم'; en = '✅ Done' }
    $catalogue['common.noResults'] = @{ ar = 'لا توجد نتائج'; en = 'No results' }
    $catalogue['common.notSet'] = @{ ar = 'غير مضبوط'; en = 'Not set' }
    $catalogue['common.enabled'] = @{ ar = 'مفعّل'; en = 'On' }
    $catalogue['common.disabled'] = @{ ar = 'معطّل'; en = 'Off' }
    $catalogue['common.noName'] = @{ ar = 'بلا اسم'; en = 'No name' }
    $catalogue['common.now'] = @{ ar = 'الآن'; en = 'Now' }
    $catalogue['common.badChoice'] = @{ ar = 'خيار غير صالح.'; en = 'That is not a valid choice.' }
    $catalogue['common.valueEmpty'] = @{ ar = '❌ القيمة فارغة، لم يتغيّر شيء.'; en = '❌ The value is empty; nothing changed.' }
    $catalogue['common.typeNumber'] = @{ ar = '⌨️ اكتب رقمًا'; en = '⌨️ Type a number' }
    $catalogue['day.sunday'] = @{ ar = 'الأحد'; en = 'Sunday' }
    $catalogue['day.monday'] = @{ ar = 'الاثنين'; en = 'Monday' }
    $catalogue['day.tuesday'] = @{ ar = 'الثلاثاء'; en = 'Tuesday' }
    $catalogue['day.wednesday'] = @{ ar = 'الأربعاء'; en = 'Wednesday' }
    $catalogue['day.thursday'] = @{ ar = 'الخميس'; en = 'Thursday' }
    $catalogue['day.friday'] = @{ ar = 'الجمعة'; en = 'Friday' }
    $catalogue['day.saturday'] = @{ ar = 'السبت'; en = 'Saturday' }
}
