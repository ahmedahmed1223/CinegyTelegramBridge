#requires -Version 7
<#
    Dot-sourced by Modules/BridgeLanguage.psm1, which holds the mechanism.

    This file holds the operation log and the four period reports: the column
    headings, the empty-period lines in their three renderings (plain, HTML
    and the downloadable page), and the short weekday names the day-by-day
    breakdown uses.
#>

function Add-BridgeTextReports {
    <# Fills the shared dictionary in place; see the sibling files. #>
    param([Parameter(Mandatory)]$Catalogue)
    $catalogue = $Catalogue

    # --- The operation log and the period reports -----------------------
    $catalogue['rep.yesterday'] = @{ ar = 'أمس'; en = 'Yesterday' }
    $catalogue['rep.today'] = @{ ar = 'اليوم'; en = 'Today' }
    $catalogue['rep.dayBefore'] = @{ ar = 'أول أمس'; en = 'The day before yesterday' }
    $catalogue['rep.sevenDays'] = @{ ar = '7 أيام'; en = '7 days' }
    $catalogue['rep.thirtyDays'] = @{ ar = '30 يومًا'; en = '30 days' }
    $catalogue['rep.allOperators'] = @{ ar = 'كل المشغّلين'; en = 'All operators' }
    $catalogue['rep.myOperations'] = @{ ar = 'عملياتي'; en = 'My operations' }
    $catalogue['rep.nothingToFilter'] = @{ ar = '<i>لا عمليات في هذه المدة، فلا شيء يُصفّى.</i>'; en = '<i>No operations in this period, so there is nothing to filter.</i>' }
    $catalogue['rep.filterNote'] = @{ ar = '<i>الخيارات من هذه المدة وحدها، والأكثر نشاطًا أولًا.</i>'; en = '<i>The choices come from this period alone, busiest first.</i>' }
    $catalogue['rep.noneInPeriod'] = @{ ar = 'لا عمليات في هذه المدة'; en = 'No operations in this period' }
    $catalogue['rep.wholeLog'] = @{ ar = '⬅️ السجل كاملًا'; en = '⬅️ The whole log' }
    $catalogue['rep.noneRecorded'] = @{ ar = 'لم تُسجَّل أي عملية في هذه المدة.'; en = 'No operation was recorded in this period.' }
    $catalogue['rep.noneRecordedHtml'] = @{ ar = '<i>لم تُسجَّل أي عملية في هذه المدة.</i>'; en = '<i>No operation was recorded in this period.</i>' }
    $catalogue['rep.col.time'] = @{ ar = 'الوقت'; en = 'Time' }
    $catalogue['rep.col.operation'] = @{ ar = 'العملية'; en = 'Operation' }
    $catalogue['rep.col.template'] = @{ ar = 'القالب'; en = 'Template' }
    $catalogue['rep.col.result'] = @{ ar = 'النتيجة'; en = 'Result' }
    $catalogue['rep.col.operator'] = @{ ar = 'المشغّل'; en = 'Operator' }
    $catalogue['rep.op.show'] = @{ ar = 'عرض'; en = 'Show' }
    $catalogue['rep.op.hide'] = @{ ar = 'إخفاء'; en = 'Hide' }
    $catalogue['rep.op.exit'] = @{ ar = 'خروج'; en = 'Exit' }
    $catalogue['rep.op.update'] = @{ ar = 'تحديث'; en = 'Update' }
    $catalogue['rep.readLimit'] = @{ ar = '<i>⚠️ بلغ السجل حدّ القراءة؛ قد تكون هناك عمليات أقدم داخل المدة.</i>'; en = '<i>⚠️ The log hit its read limit; there may be older operations inside the period.</i>' }
    $catalogue['rep.noOperations'] = @{ ar = 'لا توجد عمليات'; en = 'No operations' }
    $catalogue['rep.exportCsv'] = @{ ar = '📤 تصدير CSV'; en = '📤 Export CSV' }
    $catalogue['rep.clearFilter'] = @{ ar = '✖️ أزل التصفية'; en = '✖️ Clear the filter' }
    $catalogue['rep.filter'] = @{ ar = '🔎 تصفية'; en = '🔎 Filter' }
    $catalogue['rep.allOperatorsButton'] = @{ ar = '👥 كل المشغّلين'; en = '👥 All operators' }
    $catalogue['rep.mineOnly'] = @{ ar = '👤 عملياتي فقط'; en = '👤 Mine only' }
    $catalogue['rep.myLatest'] = @{ ar = '🧾 آخر عملياتي'; en = '🧾 My latest operations' }
    $catalogue['rep.home'] = @{ ar = '🏠 القائمة'; en = '🏠 Menu' }
    $catalogue['rep.col.date'] = @{ ar = 'التاريخ'; en = 'Date' }
    $catalogue['rep.col.layer'] = @{ ar = 'الطبقة'; en = 'Layer' }
    $catalogue['rep.col.operatorId'] = @{ ar = 'معرّف المشغّل'; en = 'Operator id' }
    $catalogue['rep.col.error'] = @{ ar = 'الخطأ'; en = 'Error' }
    $catalogue['rep.exportAdminOnly'] = @{ ar = '🔒 تصدير السجل للمشرفين.'; en = '🔒 Exporting the log is for administrators.' }
    $catalogue['rep.nothingToExport'] = @{ ar = 'لا عمليات في هذه المدة، فلا شيء يُصدَّر.'; en = 'No operations in this period, so there is nothing to export.' }
    $catalogue['rep.sendLogFailed'] = @{ ar = '⚠️ تعذّر إرسال ملف السجل.'; en = '⚠️ Could not send the log file.' }
    $catalogue['rep.createLogFailed'] = @{ ar = '⚠️ تعذّر إنشاء ملف السجل.'; en = '⚠️ Could not create the log file.' }
    $catalogue['rep.banners'] = @{ ar = '🖼 البنرات'; en = '🖼 Banners' }
    $catalogue['rep.news'] = @{ ar = '📰 الأخبار'; en = '📰 News' }
    $catalogue['rep.bulletins'] = @{ ar = '📑 الموجزات'; en = '📑 Bulletins' }
    $catalogue['rep.workReport'] = @{ ar = '👥 تقرير العمل'; en = '👥 Work report' }
    $catalogue['rep.weeklyReport'] = @{ ar = '📋 تقرير أسبوعي'; en = '📋 Weekly report' }
    $catalogue['rep.operationLog'] = @{ ar = '🧾 سجل العمليات'; en = '🧾 Operation log' }
    $catalogue['rep.downloadFile'] = @{ ar = '⬇️ تحميل الملف'; en = '⬇️ Download the file' }
    $catalogue['rep.reports'] = @{ ar = '📊 التقارير'; en = '📊 Reports' }
    $catalogue['rep.yourOperations'] = @{ ar = 'عملياتك أنت'; en = 'your own operations' }
    $catalogue['rep.last7'] = @{ ar = 'آخر 7 أيام'; en = 'the last 7 days' }
    $catalogue['rep.last30'] = @{ ar = 'آخر 30 يومًا'; en = 'the last 30 days' }
    $catalogue['rep.noAirOpsHtml'] = @{ ar = '<i>لا توجد عمليات هواء مسجلة في هذه الفترة.</i>'; en = '<i>No air operations are recorded in this period.</i>' }
    $catalogue['rep.noAirOps'] = @{ ar = 'لا توجد عمليات هواء مسجلة في هذه الفترة.'; en = 'No air operations are recorded in this period.' }
    $catalogue['rep.col.operations'] = @{ ar = 'العمليات'; en = 'Operations' }
    $catalogue['rep.col.onAir'] = @{ ar = 'على الهواء'; en = 'On air' }
    $catalogue['rep.col.refused'] = @{ ar = 'مرفوضة'; en = 'Refused' }
    $catalogue['rep.col.failed'] = @{ ar = 'فاشلة'; en = 'Failed' }
    $catalogue['rep.col.most'] = @{ ar = 'الأكثر'; en = 'Most' }
    $catalogue['rep.col.lastActivity'] = @{ ar = 'آخر نشاط'; en = 'Last activity' }
    $catalogue['rep.col.total'] = @{ ar = 'الإجمالي'; en = 'Total' }
    $catalogue['rep.onAirMark'] = @{ ar = '🔴 على الهواء'; en = '🔴 On air' }
    $catalogue['rep.noBulletinRun'] = @{ ar = 'لم يُشغَّل أي موجز في هذه الفترة.'; en = 'No bulletin was run in this period.' }
    $catalogue['rep.noBulletinRunHtml'] = @{ ar = '<i>لم يُشغَّل أي موجز في هذه الفترة.</i>'; en = '<i>No bulletin was run in this period.</i>' }
    $catalogue['rep.noBulletinRunP'] = @{ ar = '<p>لم يُشغَّل أي موجز في هذه الفترة.</p>'; en = '<p>No bulletin was run in this period.</p>' }
    $catalogue['rep.col.bulletin'] = @{ ar = 'الموجز'; en = 'Bulletin' }
    $catalogue['rep.col.start'] = @{ ar = 'البداية'; en = 'Start' }
    $catalogue['rep.col.duration'] = @{ ar = 'المدة'; en = 'Duration' }
    $catalogue['rep.noTickerPublish'] = @{ ar = 'لم يُنشر شريط أخبار في هذه الفترة.'; en = 'No news ticker was published in this period.' }
    $catalogue['rep.noTickerPublishHtml'] = @{ ar = '<i>لم يُنشر شريط أخبار في هذه الفترة.</i>'; en = '<i>No news ticker was published in this period.</i>' }
    $catalogue['rep.noTickerPublishP'] = @{ ar = '<p>لم يُنشر شريط أخبار في هذه الفترة.</p>'; en = '<p>No news ticker was published in this period.</p>' }
    $catalogue['rep.col.edits'] = @{ ar = 'تعديلات'; en = 'Edits' }
    $catalogue['rep.col.range'] = @{ ar = 'المدى'; en = 'Range' }
    $catalogue['rep.noEdit'] = @{ ar = 'بلا تعديل'; en = 'no edit' }
    $catalogue['rep.dayDetail'] = @{ ar = '🔍 تفاصيل كل يوم'; en = '🔍 Day by day' }
    $catalogue['rep.noBulletinPublished'] = @{ ar = '🕒 لم تُنشر أي نشرة في هذه الفترة.'; en = '🕒 No bulletin was published in this period.' }
    $catalogue['rep.replacement'] = @{ ar = 'استبدال'; en = 'replacement' }
    $catalogue['rep.noBanner'] = @{ ar = 'لم يُعرض أي بنر في هذه الفترة.'; en = 'No banner was shown in this period.' }
    $catalogue['rep.noBannerHtml'] = @{ ar = '<i>لم يُعرض أي بنر في هذه الفترة.</i>'; en = '<i>No banner was shown in this period.</i>' }
    $catalogue['rep.noBannerP'] = @{ ar = '<p>لم يُعرض أي بنر في هذه الفترة.</p>'; en = '<p>No banner was shown in this period.</p>' }
    $catalogue['rep.col.banner'] = @{ ar = 'البنر'; en = 'Banner' }
    $catalogue['rep.textNotRecorded'] = @{ ar = 'النص غير مسجَّل لهذه العملية'; en = 'The text is not recorded for this operation' }
    $catalogue['rep.stillOnAirHtml'] = @{ ar = ' &#8592; ما زال على الهواء</span>'; en = ' &#8592; still on air</span>' }
    $catalogue['rep.bySchedule'] = @{ ar = ' &middot; بالجدولة'; en = ' &middot; by schedule' }
    $catalogue['rep.newsReport'] = @{ ar = '📰 تقرير الأخبار'; en = '📰 News report' }
    $catalogue['rep.bulletinReport'] = @{ ar = '📑 تقرير الموجزات'; en = '📑 Bulletin report' }
    $catalogue['rep.bannerReport'] = @{ ar = '🖼 تقرير البنرات'; en = '🖼 Banner report' }
    $catalogue['rep.sendReportFailed'] = @{ ar = '⚠️ تعذّر إرسال ملف التقرير.'; en = '⚠️ Could not send the report file.' }
    $catalogue['rep.createReportFailed'] = @{ ar = '⚠️ تعذّر إنشاء ملف التقرير.'; en = '⚠️ Could not create the report file.' }
    $catalogue['rep.day.sun'] = @{ ar = 'أحد'; en = 'Sun' }
    $catalogue['rep.day.mon'] = @{ ar = 'إثنين'; en = 'Mon' }
    $catalogue['rep.day.tue'] = @{ ar = 'ثلاثاء'; en = 'Tue' }
    $catalogue['rep.day.wed'] = @{ ar = 'أربعاء'; en = 'Wed' }
    $catalogue['rep.day.thu'] = @{ ar = 'خميس'; en = 'Thu' }
    $catalogue['rep.day.fri'] = @{ ar = 'جمعة'; en = 'Fri' }
    $catalogue['rep.day.sat'] = @{ ar = 'سبت'; en = 'Sat' }
}
