#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the frame around the manual: its title, the index, the
    paging buttons and the three short screens beside it.

    The chapters themselves are not here. Get-HelpChapters hands over to
    Get-HelpChaptersEn on an English bridge, so the Arabic bodies in
    Get-HelpChaptersAr are one half of a pair rather than an untranslated
    screen. What was untranslated is everything around them: an operator
    reading the English manual still met "⬅️ السابق" under it.
#>

function Add-BridgeTextHelp {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['help.guide'] = @{ ar = '📖 دليل الجسر'; en = '📖 The bridge manual' }
    $catalogue['help.checkConnection'] = @{ ar = 'افحص الاتصال ثم أعد المحاولة'; en = 'check the connection, then try again' }
    $catalogue['help.checkRights'] = @{ ar = 'راجع صلاحيتك أو حالة Cinegy'; en = 'look at your rights, or at the state of Cinegy' }
    $catalogue['help.yourLatestOperations'] = @{ ar = '🧾 آخر عملياتك'; en = '🧾 Your latest operations' }
    $catalogue['help.noOperationsYet'] = @{ ar = 'لم تُسجَّل لك عمليات بعد.'; en = 'No operation is recorded for you yet.' }
    $catalogue['help.sendToAdmin'] = @{ ar = 'أرسله للمشرف مع وصف ما حدث.'; en = 'Send it to the administrator with a word about what happened.' }
    $catalogue['help.index'] = @{ ar = '📖 الفهرس'; en = '📖 The index' }
    $catalogue['help.next'] = @{ ar = '➡️ التالي'; en = '➡️ Next' }
    $catalogue['help.title'] = @{ ar = '<b>📘 دليل بوت Cinegy Air</b>'; en = '<b>📘 The Cinegy Air bot manual</b>' }
    $catalogue['help.chooseWhat'] = @{ ar = '<b>اختر ما تريد معرفته:</b>'; en = '<b>Choose what you want to know:</b>' }
    $catalogue['help.newHere'] = @{ ar = '<i>🚀 جديد على البوت؟ ابدأ بـ«بداية سريعة».</i>'; en = '<i>🚀 New to the bot? Start with "A quick start".</i>' }
    $catalogue['help.wholeGuide'] = @{ ar = '📄 الدليل كاملًا'; en = '📄 The whole manual' }
    $catalogue['help.otherChapters'] = @{ ar = '📚 وبقية الأبواب في الفهرس: {0}'; en = '📚 And the rest of the chapters are in the index: {0}' }
    $catalogue['help.pair'] = @{ ar = '{0} · ✅ {1}'; en = '{0} · ✅ {1}' }
    $catalogue['help.olderOperations'] = @{ ar = '🔍 عمليات أقدم ({0})'; en = '🔍 Older operations ({0})' }
    $catalogue['help.chapterOf'] = @{ ar = '<i>الباب {0} من {1}</i>'; en = '<i>Chapter {0} of {1}</i>' }
    $catalogue['help.release'] = @{ ar = 'الإصدار <code>{0}</code>'; en = 'Release <code>{0}</code>' }
}
