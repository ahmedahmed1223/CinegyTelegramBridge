#requires -Version 7
<#
    Text for the web interface's touch points inside the bot: the login
    confirmation an operator approves in Telegram. Everything the browser shows
    lives in the web client, not here.
#>

function Add-BridgeTextWeb {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['web.disabled'] = @{ ar = '🌐 واجهة الويب غير مفعّلة على هذه المحطة.'; en = '🌐 The web interface is not enabled on this station.' }
    $catalogue['web.login.unknown'] = @{ ar = '⛔ رمز الدخول غير صالح أو انتهت صلاحيته. اطلب رمزًا جديدًا من صفحة الدخول.'; en = '⛔ That sign-in code is invalid or has expired. Ask the sign-in page for a new one.' }
    $catalogue['web.login.confirm'] = @{
        ar = "🌐 <b>طلب دخول إلى واجهة الويب</b>`n`nالرمز: <code>{0}</code>`nالعنوان: {1}`nالمتصفح: {2}`n`nتأكّد أن الرمز هو نفسه الظاهر في صفحتك. إن لم تطلب الدخول أنت فاضغط «رفض»."
        en = "🌐 <b>Web interface sign-in request</b>`n`nCode: <code>{0}</code>`nAddress: {1}`nBrowser: {2}`n`nCheck the code matches the one on your page. If you did not ask to sign in, press Deny."
    }
    $catalogue['web.login.approve'] = @{ ar = '✅ موافقة'; en = '✅ Approve' }
    $catalogue['web.login.deny'] = @{ ar = '❌ رفض'; en = '❌ Deny' }
    $catalogue['web.login.approved'] = @{ ar = '✅ تمّت الموافقة على الدخول إلى واجهة الويب بالرمز <code>{0}</code>.'; en = '✅ Web sign-in with code <code>{0}</code> approved.' }
    $catalogue['web.login.denied'] = @{ ar = '❌ رُفض طلب الدخول بالرمز <code>{0}</code>.'; en = '❌ Sign-in request <code>{0}</code> denied.' }
    $catalogue['web.login.expired'] = @{ ar = '⌛ انتهت صلاحية طلب الدخول هذا.'; en = '⌛ This sign-in request has expired.' }
    $catalogue['web.login.notYours'] = @{ ar = '⛔ هذا الطلب أرسله حساب آخر.'; en = '⛔ Another account sent this request.' }
}
