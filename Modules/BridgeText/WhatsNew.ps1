#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the furniture of the what's-new screen: its two
    headings, the line pointing at CHANGELOG.md and the button beside it.

    The releases themselves are not here and are not translated. They are an
    archive written for one station about screens as they were, and a
    half-translated archive is worse than an untranslated one: it changes
    language partway down the page.
#>

function Add-BridgeTextWhatsNew {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['whatsnew.olderReleases'] = @{ ar = '<b>🆕 ما الجديد</b> — <i>الإصدارات الأقدم</i>'; en = '<b>🆕 What''s new</b> — <i>the older releases</i>' }
    $catalogue['whatsnew.fullLog'] = @{ ar = '<i>السجل التقني الكامل في ملف CHANGELOG.md مع الإصدار.</i>'; en = '<i>The full technical log is in CHANGELOG.md, which ships with the release.</i>' }
    $catalogue['whatsnew.technicalLog'] = @{ ar = '📄 السجل التقني (ملف)'; en = '📄 The technical log (a file)' }
}
