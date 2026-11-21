import { Alert, Badge, Button, Group, List, Paper, Stack, Text, Title } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

const findings: Readonly<Record<string, string>> = {
  maintenance_active: 'وضع الصيانة اليدوي أو المجدول يمنع إجراء الاختبار.',
  test_layer_missing: 'طبقة الاختبار غير مضبوطة.',
  multi_scene_state: 'قراءة العنصر النشط وحده لا تكفي للتحقق من خلو الطبقة في وضع المشاهد المتعددة.',
  registered_scene_missing: 'لا يوجد قالب مسجّل لاستخدامه في الفحص.',
  layer_configured_for_templates: 'طبقة الاختبار مخصّصة حاليًا لقالب بث مسجّل.',
  permanent_layer: 'طبقة الاختبار تحمل رسماً دائمًا حسب الإعدادات.',
  physical_layer_conflict: 'طبقة أخرى في السجل تشير إلى جهاز Cinegy نفسه.',
  layer_tracked: 'الجسر يتتبّع مشهدًا على جهاز طبقة الاختبار.',
  dedicated_scene_unavailable: 'يلزم تحديد مشهد مسجّل مخصّص للاختبار.',
  identity_cleanup_unavailable: 'أوامر الإنهاء والإخفاء المتاحة تستهدف الطبقة بكاملها. يلزم تقييد التنظيف بمشهد الاختبار نفسه.',
}

const observations: Readonly<Record<string, string>> = {
  idle: 'أبلغ Cinegy عن عدم وجود عنصر نشط.',
  occupied: 'أبلغ Cinegy عن عنصر نشط على الطبقة.',
  unknown: 'تعذّر التحقق من وجود عنصر نشط.',
  not_checked: 'لم تُفحص حالة الطبقة في Cinegy بسبب شروط الإعداد أو الصيانة.',
}

const clock = new Intl.DateTimeFormat('ar', { dateStyle: 'medium', timeStyle: 'medium' })

export function SelfTestReadinessPanel() {
  const check = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/admin/self-test/readiness')
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const report = check.data

  return (
    <Paper p="md" withBorder>
      <Stack gap="sm">
        <Group justify="space-between" align="start">
          <Stack gap={4}>
            <Title order={3} size="h4">جاهزية طبقة الاختبار</Title>
            <Text c="dimmed" size="sm">يفحص الإعدادات ويقرأ حالة طبقة الاختبار.</Text>
          </Stack>
          <Button variant="default" size="sm" loading={check.isPending} onClick={() => check.mutate()}>
            {report ? 'إعادة الفحص' : 'فحص الجاهزية'}
          </Button>
        </Group>
        <Badge color="yellow" variant="light">التحقق على جهاز البث معلّق</Badge>
        {check.error && (
          <Alert color="red" role="alert" title="تعذّر الفحص">
            {check.error.message === 'layer_comparison_busy' ? 'أعد المحاولة بعد لحظة.' : messageFor(check.error.message)}
          </Alert>
        )}
        {report && (
          <Stack gap="xs" role="status">
            {report.layer != null && <Text size="sm">طبقة الاختبار {report.layer}</Text>}
            <Text size="sm">{observations[report.engine] ?? observations.unknown}</Text>
            {report.observedAt != null && <Text size="xs" c="dimmed">وقت الفحص {clock.format(report.observedAt)}</Text>}
            <List size="sm" spacing={3}>
              {report.findings.map((finding) => (
                <List.Item key={finding}>{findings[finding] ?? 'يلزم التحقق من إعدادات طبقة الاختبار.'}</List.Item>
              ))}
            </List>
          </Stack>
        )}
      </Stack>
    </Paper>
  )
}
