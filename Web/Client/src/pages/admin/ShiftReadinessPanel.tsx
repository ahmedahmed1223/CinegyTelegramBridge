import { Alert, Badge, Button, Group, List, Paper, SimpleGrid, Skeleton, Stack, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconRefresh } from '@tabler/icons-react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

const time = new Intl.DateTimeFormat('ar', { dateStyle: 'medium', timeStyle: 'medium' })
const count = new Intl.NumberFormat('ar')

const draftText: Record<string, string> = {
  none: 'لا توجد مسودة',
  open: 'مسودة مفتوحة',
  locked: 'مسودة محجوزة',
}

const findings: Record<string, string> = {
  MaintenanceMode: 'وضع الصيانة اليدوي مفعّل.',
  SchedulePaused: 'تنفيذ الأوامر المجدولة متوقف مؤقتًا.',
  EnableSafeRollback: 'التراجع الآمن عن آخر أمر معطّل.',
  ConfirmLayerRemoval: 'الأوامر لا تتطلب تأكيد إزالة الطبقة.',
  RequireUserLevelAuth: 'المصادقة على مستوى المستخدم معطلة.',
  EnableFullTemplateManagement: 'إدارة تعريفات القوالب مفعّلة.',
  BlockRejectedRequesters: 'يستطيع مقدّمو الطلبات المرفوضة المحاولة مجددًا.',
  LeaveUnknownGroups: 'الجسر لا يغادر المجموعات المجهولة تلقائيًا.',
  EnableDpapiSecrets: 'حماية الأسرار بواسطة Windows DPAPI معطّلة.',
  NotifyAdminsOnMissingGraphic: 'تنبيه المشرفين عند فقد الرسم معطّل.',
  EnableTextChecks: 'تنبيهات تدقيق النص معطّلة.',
  TemplateTestLayer: 'طبقة اختبار القوالب غير مضبوطة.',
}

export function ShiftReadinessPanel({ accountId }: { accountId: number | string }) {
  const check = useQuery({
    queryKey: ['admin-readiness', accountId],
    refetchInterval: 30_000,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/readiness', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })

  if (check.error) {
    return (
      <Alert color="red" title="تعذّر قراءة جاهزية الوردية">
        <Stack align="start" gap="xs">
          <Text size="sm">{messageFor(check.error.message)}</Text>
          <Button variant="default" size="xs" onClick={() => check.refetch()} loading={check.isFetching}>إعادة المحاولة</Button>
        </Stack>
      </Alert>
    )
  }

  const report = check.data
  if (!report) return <Skeleton height={150} radius="md" />

  const figures = [
    ['الطبقات المعروضة', count.format(report.onAirLayers)],
    ['عمليات قيد الإعداد', count.format(report.pendingOperations)],
    ['مسودة الشريط', draftText[report.tickerDraft] ?? 'غير معروف'],
    ['محادثات معزولة', count.format(report.quarantinedChats)],
    ['أعطال متكررة مثبّتة', count.format(report.pinnedFaults)],
    ['التنبيهات', report.quietHours ? 'الهدوء مفعّل' : 'إرسال مباشر'],
  ]

  return (
    <Stack gap="md">
      <Group justify="space-between">
        <Title order={2} size="h3">تسلّم الوردية</Title>
        <Button variant="default" size="xs" leftSection={<IconRefresh size={15} />}
          loading={check.isFetching} onClick={() => check.refetch()}>تحديث</Button>
      </Group>
      <Group gap="sm">
        <Badge size="lg" color={report.ready ? 'teal' : 'yellow'}>
          {report.ready ? 'الحالة المسجّلة جاهزة' : 'حالة الوردية تحتاج إلى مراجعة'}
        </Badge>
        <Text size="sm" c="dimmed">آخر قراءة {time.format(report.checkedAt)}</Text>
      </Group>
      <Text size="sm" c="dimmed">تعرض الصفحة حالة الجسر المسجّلة. فحص مسار البث منفصل.</Text>
      <SimpleGrid cols={{ base: 1, xs: 2, md: 3 }}>
        {figures.map(([label, value]) => (
          <Paper key={label} withBorder p="sm">
            <Text size="xs" c="dimmed">{label}</Text>
            <Text size="lg" fw={600}>{value}</Text>
          </Paper>
        ))}
      </SimpleGrid>
      <Paper withBorder p="md">
        <Stack gap="xs">
          <Title order={3} size="h4">إعدادات تحتاج إلى انتباه</Title>
          {report.protectionFindings.length ? (
            <List size="sm" spacing={4}>
              {report.protectionFindings.map((finding) => (
                <List.Item key={finding}>{findings[finding] ?? 'يوجد إعداد آخر يحتاج إلى مراجعة.'}</List.Item>
              ))}
            </List>
          ) : <Text size="sm" c="dimmed">لا توجد إعدادات تحتاج إلى انتباه في هذا الفحص.</Text>}
        </Stack>
      </Paper>
    </Stack>
  )
}
