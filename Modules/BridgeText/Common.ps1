#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the language control, the words that recur on every screen, and the main menu.

    Split out when the catalogue passed a thousand lines: one file per domain
    keeps each under the size this repository asks a file to stay, and puts a
    translator in front of one subject at a time instead of the whole bot.
    Nothing about the contract changed - every entry still carries both
    languages, and Test-BridgeTextCatalogue still reads them all together.
#>

function Add-BridgeTextCommon {
    <# Fills the shared dictionary in place. Partial by design: the catalogue
       is one ordered map assembled from four files, not four maps. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

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

    # --- The main menu --------------------------------------------------
    # The live rows first, because this menu is what an operator opens when a
    # wrong graphic is on air and every row above the fix is one to scroll past.
    $catalogue['menu.hideLive'] = @{ ar = '🔴 إخفاء {0} · {1}'; en = '🔴 Hide {0} · {1}' }
    $catalogue['menu.hideLive.copy'] = @{ ar = '🔴 إخفاء {0} · {1} — {2}'; en = '🔴 Hide {0} · {1} — {2}' }
    $catalogue['menu.timerExtend'] = @{ ar = '⏱ +30ث ({0} ث)'; en = '⏱ +30s ({0}s)' }
    $catalogue['menu.timer'] = @{ ar = '⏱ مؤقت'; en = '⏱ Timer' }
    $catalogue['menu.reshow'] = @{ ar = '↩️ إعادة عرض {0}'; en = '↩️ Show {0} again' }
    $catalogue['menu.hideAll'] = @{ ar = '🚨 إخفاء الكل'; en = '🚨 Hide everything' }
    $catalogue['menu.clearLayers'] = @{ ar = '🧹 تنظيف الطبقات'; en = '🧹 Clear the layers' }
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
}
