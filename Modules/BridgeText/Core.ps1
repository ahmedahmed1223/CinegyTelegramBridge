#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds what Bridge.Core.ps1 and Bridge.Commands.ps1 say for
    themselves: the config-restore screen with its table, the names the
    typography check gives each fault it finds in a headline, the layer-names
    screen and the four usage lines.

    The usage lines keep their Arabic command word on both sides. It is what
    the operator types, and a station that switches language does not want
    every typed command to stop working.
#>

function Add-BridgeTextCore {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['core.backupFileMissing'] = @{ ar = 'ملف النسخة غير موجود.'; en = 'The backup file is not there.' }
    $catalogue['core.backupNoToken'] = @{ ar = 'النسخة لا تحتوي BotToken صالحًا.'; en = 'The backup holds no valid BotToken.' }
    $catalogue['core.empty'] = @{ ar = '(فارغ)'; en = '(empty)' }
    $catalogue['core.notThere'] = @{ ar = '(غير موجود)'; en = '(not there)' }
    $catalogue['core.noVisibleDifferences'] = @{ ar = 'لا اختلافات ظاهرة: الاستعادة لن تغيّر شيئًا.'; en = 'No visible differences: the restore would change nothing.' }
    $catalogue['core.col.setting'] = @{ ar = 'الإعداد'; en = 'Setting' }
    $catalogue['core.col.current'] = @{ ar = 'الحالي'; en = 'Now' }
    $catalogue['core.col.inBackup'] = @{ ar = 'في النسخة'; en = 'In the backup' }
    $catalogue['core.noDifferences'] = @{ ar = 'الاختلافات: لا توجد اختلافات ظاهرة.'; en = 'The differences: there are none to see.' }
    $catalogue['core.configNotSaved'] = @{ ar = "`n⚠️ تعذّر حفظ config.json - التغيير مؤقّت حتى إعادة التشغيل."; en = "`n⚠️ config.json could not be saved - the change lasts only until the next restart." }
    $catalogue['core.doubleSpace'] = @{ ar = 'مسافتان متتاليتان'; en = 'two spaces in a row' }
    $catalogue['core.punctuationNoSpace'] = @{ ar = 'علامة ترقيم بلا مسافة بعدها'; en = 'punctuation with no space after it' }
    $catalogue['core.spaceBeforePunctuation'] = @{ ar = 'مسافة قبل علامة ترقيم'; en = 'a space before punctuation' }
    $catalogue['core.latinDigits'] = @{ ar = 'أرقام لاتينية داخل نصّ عربي'; en = 'Latin digits inside Arabic text' }
    $catalogue['core.edgeSpace'] = @{ ar = 'مسافة في أول النصّ أو آخره'; en = 'a space at the start or the end of the text' }
    $catalogue['cmd.layerNamesScreen'] = @{ ar = "🏷️ أسماء الطبقات`nاختر طبقة، ثم أرسل اسمًا واحدًا واضحًا لها. لا تحتاج إلى كتابة رموز أو أرقام بصيغة خاصة."; en = "🏷️ The layer names`nChoose a layer, then send one clear name for it. No codes and no special number format." }
    $catalogue['cmd.usageRaw'] = @{ ar = 'الاستخدام: /أمر Device Cmd [Op1]'; en = 'Usage: /أمر Device Cmd [Op1]' }
    $catalogue['cmd.usageShow'] = @{ ar = 'الاستخدام: /عرض اسم_القالب | نص الحقل الأول | ...'; en = 'Usage: /عرض template_name | the first field | ...' }
    $catalogue['cmd.usageUpdate'] = @{ ar = 'الاستخدام: /تحديث الاسم=القيمة [| الاسم٢=القيمة٢ ...]'; en = 'Usage: /تحديث name=value [| name2=value2 ...]' }
    $catalogue['cmd.usageAlias'] = @{ ar = "الاستخدام: /alias USER_ID الاسم`nلحذف الاسم: /alias USER_ID -"; en = "Usage: /alias USER_ID name`nTo remove the name: /alias USER_ID -" }
    $catalogue['core.joinAnd'] = @{ ar = ' و'; en = ' and ' }
}
