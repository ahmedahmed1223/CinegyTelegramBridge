#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the feed-watch screen: its state line, the source and
    the cycle behind it, the outage ledger's summary and the rows of the
    outages themselves.

    Written in both languages from the first line rather than in Arabic to be
    translated later, which is the debt the rest of this catalogue was built
    to pay off.
#>

function Add-BridgeTextFeed {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    $catalogue['feed.title'] = @{ ar = '📡 <b>مراقبة البثّ</b>'; en = '📡 <b>The feed watch</b>' }
    $catalogue['feed.stateGood'] = @{ ar = '🟢 <b>البثّ يصل</b>'; en = '🟢 <b>The feed is arriving</b>' }
    $catalogue['feed.stateBlack'] = @{ ar = '🖤 <b>الشاشة سوداء</b>'; en = '🖤 <b>The screen is black</b>' }
    $catalogue['feed.stateDown'] = @{ ar = '🔴 <b>البثّ لا يصل</b>'; en = '🔴 <b>The feed is not arriving</b>' }
    $catalogue['feed.stateUnknown'] = @{ ar = '⚪ <b>لم يُفحص بعد</b>'; en = '⚪ <b>Not checked yet</b>' }
    $catalogue['feed.watchOff'] = @{ ar = '⚠️ المراقبة الدورية متوقّفة — اضبط <code>OutputMonitorMinutes</code> لتعمل.'; en = '⚠️ The regular watch is off — set <code>OutputMonitorMinutes</code> to start it.' }
    $catalogue['feed.noFfmpeg'] = @{ ar = '⛔ لا يوجد ffmpeg، فلا لقطة ولا مراقبة.'; en = '⛔ There is no ffmpeg, so there is neither a snapshot nor a watch.' }
    $catalogue['feed.since'] = @{ ar = 'منذ {0}'; en = 'for {0}' }
    $catalogue['feed.lastCheck'] = @{ ar = '🕒 آخر فحص: {0}'; en = '🕒 Last checked: {0}' }
    $catalogue['feed.neverChecked'] = @{ ar = 'لم يبدأ بعد'; en = 'not started yet' }
    $catalogue['feed.source'] = @{ ar = '🎚 المصدر: {0} · {1}'; en = '🎚 The source: {0} · {1}' }
    $catalogue['feed.cycle'] = @{ ar = '⏱ الدورة: {0}'; en = '⏱ The cycle: {0}' }
    $catalogue['feed.lastGood'] = @{ ar = '✅ آخر مرّة كان سليمًا: {0}'; en = '✅ Last whole: {0}' }
    $catalogue['feed.noOutageRecorded'] = @{ ar = '✅ لا انقطاع مسجَّل بعد.'; en = '✅ No outage is recorded yet.' }
    $catalogue['feed.windowSummary'] = @{ ar = '📉 خلال {0}: {1} — بإجمالي {2}'; en = '📉 In the last {0}: {1} — {2} in all' }
    $catalogue['feed.windowClean'] = @{ ar = '📗 خلال {0}: لا انقطاع.'; en = '📗 In the last {0}: no outage.' }
    $catalogue['feed.outagesTitle'] = @{ ar = '<b>الانقطاعات الأخيرة</b>'; en = '<b>The recent outages</b>' }
    $catalogue['feed.outageRow'] = @{ ar = '{0} {1} · {2} — {3}'; en = '{0} {1} · {2} — {3}' }
    $catalogue['feed.stillDown'] = @{ ar = 'ما زال'; en = 'still going' }
    $catalogue['feed.kind.unreachable'] = @{ ar = 'لا يصل'; en = 'not arriving' }
    $catalogue['feed.kind.black'] = @{ ar = 'سوداء'; en = 'black' }
    $catalogue['feed.noOutages'] = @{ ar = '<i>لا انقطاع مسجَّل. تُسجَّل الانقطاعات منذ هذا الإصدار.</i>'; en = '<i>No outage is recorded. Outages have been recorded since this release.</i>' }
    $catalogue['feed.snapshotNow'] = @{ ar = '📸 لقطة الآن'; en = '📸 A snapshot now' }
    $catalogue['feed.refresh'] = @{ ar = '🔄 تحديث'; en = '🔄 Refresh' }
    $catalogue['feed.watch'] = @{ ar = '📡 مراقبة البثّ'; en = '📡 The feed watch' }
    $catalogue['feed.probeNote'] = @{ ar = '<i>«تحديث» يلتقط إطارًا من الخرج ليقيس عليه — قراءة فقط.</i>'; en = '<i>"Refresh" grabs one frame from the output to measure — a read, nothing more.</i>' }
    $catalogue['feed.watchLive'] = @{ ar = '📺 شاهد البثّ الآن'; en = '📺 Watch the feed now' }
    $catalogue['feed.clipNow'] = @{ ar = '🎬 مقطع من الهواء'; en = '🎬 A clip from air' }
    $catalogue['media.recording'] = @{ ar = '🎬 يسجّل {0} ثوانٍ من الهواء…'; en = '🎬 Recording {0} seconds from air…' }
    $catalogue['media.clipOfAir'] = @{ ar = "🎬 مقطع من الهواء - {0}`n📡 المصدر: {1}"; en = "🎬 A clip from air - {0}`n📡 The source: {1}" }
    $catalogue['media.clipAudit'] = @{ ar = '🎬 مقطع من الهواء - بواسطة {0}'; en = '🎬 A clip from air - by {0}' }
    $catalogue['tg.videoFailed'] = @{ ar = '❌ فشل إرسال المقطع: {0}'; en = '❌ The clip could not be sent: {0}' }
}
