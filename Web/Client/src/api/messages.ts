// What each server error code means to the person in front of the screen.
// Codes come from the server (ErrorResponse.error) and the bridge.
const messages: Record<string, string> = {
  invalid_credentials: 'اسم المستخدم أو كلمة المرور غير صحيحة.',
  locked: 'أُقفل الحساب مؤقتًا بعد محاولات خاطئة متتالية. حاول بعد ربع ساعة أو اطلب من المشرف إعادة تعيين كلمة المرور.',
  not_authorized: 'هذا الحساب لم يعد مخوّلًا في الجسر.',
  bridge_unavailable: 'الجسر لا يجيب الآن. تأكّد أنه يعمل وأن «واجهة الويب» مفعّلة من برنامج التحكم.',
  rate_limited: 'محاولات كثيرة في وقت قصير. انتظر دقيقة ثم أعد المحاولة.',
  csrf: 'انتهت صلاحية الصفحة. حدّثها ثم أعد المحاولة.',
  unauthorized: 'انتهت الجلسة. سجّل الدخول من جديد.',
  forbidden: 'لا تملك صلاحية هذا الإجراء.',
  owner_only: 'هذا الإجراء للمالك وحده: حسابات المشرفين لا يديرها إلا المالك.',
  bad_username: 'اسم المستخدم من 3 إلى 32 حرفًا لاتينيًا أو رقمًا أو . _ -',
  username_taken: 'اسم المستخدم مستعمل.',
  account_exists: 'لهذا الشخص حساب ويب بالفعل.',
  password_required: 'اكتب كلمة المرور.',
  password_too_short: 'كلمة المرور عشرة أحرف على الأقل.',
  password_too_long: 'كلمة المرور أطول من المسموح.',
  wrong_password: 'كلمة المرور الحالية غير صحيحة.',
  bad_display_name: 'الاسم الظاهر مطلوب، وحدّه 48 حرفًا.',
  bad_role: 'اختر الدور.',
  unknown_user: 'هذا المستخدم ليس في قائمة الجسر.',
  no_password_account: 'ليس لحسابك كلمة مرور ويب بعد. يضيفها المشرف من صفحة الحسابات.',
  too_many: 'طلبات دخول كثيرة معلّقة. انتظر قليلًا.',
  not_found: 'لم يعد موجودًا.',
  refused: 'رفض الجسر تنفيذ العملية على الهواء.',
  bad_key: 'القالب غير محدد أو غير صالح.',
  bad_duration: 'اختر مدة إخفاء بين 0 و86400 ثانية.',
  content_disabled: 'هذا القسم غير مفعّل في إعدادات الجسر أو يفتقد القالب المطلوب.',
  content_unreadable: 'تعذّرت قراءة ملف شريط الأخبار. راجع إعداد الملف في الجسر.',
  urgent_stale: 'تغيّر الجدول أو حقول القالب. حدّث الجدول ثم افتح الصف من جديد.',
  urgent_invalid: 'املأ الحقول المطلوبة في صف العاجل.',
  urgent_save_failed: 'تعذّر حفظ جدول العواجل في الجسر.',
  urgent_air_busy: 'هناك دورة عواجل أو موجز قيد التشغيل. راجع حالة الهواء قبل بدء دورة أخرى.',
  urgent_stop_unconfirmed: 'تعذّر تأكيد إخراج المشهد. توقّفت خطوات الدورة ويمكن إعادة محاولة الإيقاف.',
  bridge_outcome_unknown: 'وصل الأمر إلى الجسر لكن نتيجته لم تتأكد بعد. راجع حالة التشغيل قبل إعادة المحاولة.',
  unknown: 'حدث خطأ غير متوقّع.',
}

export function messageFor(code: string): string {
  return messages[code] ?? messages.unknown
}
