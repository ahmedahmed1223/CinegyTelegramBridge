import { Alert, Badge, Button, Group, Paper, SimpleGrid, Skeleton, Stack, Tabs, Text, Title } from '@mantine/core'
import { IconActivityHeartbeat, IconRefresh, IconSettings } from '@tabler/icons-react'
import { useQuery } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'
import { formatDateTime } from '../../lib/time'

import { RuntimeFileDiagnosticsPage } from './RuntimeFileDiagnosticsPage'
import { ShiftReadinessPanel } from './ShiftReadinessPanel'
import { NotificationCoveragePanel } from './NotificationCoveragePanel'
import { AdminSettingEditor } from './AdminSettingEditor'

type Overview = Schemas['AdminOverview']
type Setting = Schemas['AdminOverviewSetting']
type Status = { label: string; color: string }

const statuses: Record<string, Status> = {
  connected: { label: 'متصل', color: 'teal' },
  disconnected: { label: 'منقطع', color: 'red' },
  healthy: { label: 'سليم', color: 'teal' },
  unhealthy: { label: 'يحتاج متابعة', color: 'red' },
  running: { label: 'يعمل', color: 'teal' },
  stopped: { label: 'متوقف', color: 'gray' },
  disabled: { label: 'معطّل', color: 'gray' },
  off: { label: 'متوقفة', color: 'gray' },
  unconfigured: { label: 'غير مُعدّة', color: 'gray' },
  pending: { label: 'بانتظار أول فحص', color: 'gray' },
  receiving: { label: 'تصل الإشارة', color: 'teal' },
  degraded: { label: 'الإشارة غير مستقرة', color: 'orange' },
  black: { label: 'صورة سوداء', color: 'red' },
  unreachable: { label: 'لا تصل الإشارة', color: 'red' },
  unresponsive: { label: 'المحرك لا يجيب', color: 'red' },
  unverified: { label: 'غير مؤكّد', color: 'orange' },
  switching: { label: 'يبدّل المصدر', color: 'orange' },
  starting: { label: 'يبدأ التشغيل', color: 'orange' },
  retrying: { label: 'يعيد المحاولة', color: 'orange' },
  failed: { label: 'تعذّر التشغيل', color: 'red' },
  stale: { label: 'قراءة قديمة', color: 'orange' },
  unknown: { label: 'غير معروف', color: 'gray' },
}
const settingGroups = [
  ['access', 'طلبات الوصول'],
  ['presentation', 'واجهة البوت'],
  ['air', 'العرض والجدولة'],
  ['newsroom', 'غرفة الأخبار'],
  ['monitoring', 'المراقبة'],
] as const
const numberFormat = new Intl.NumberFormat('ar', { numberingSystem: 'latn' })

function HealthTile({ title, state, detail }: { title: string; state: string; detail?: string }) {
  const status = statuses[state] ?? statuses.unknown
  return (
    <Paper withBorder p="md" radius="md">
      <Stack gap={6}>
        <Group justify="space-between" gap="xs">
          <Text fw={600}>{title}</Text>
          <Badge color={status.color} variant="light">{status.label}</Badge>
        </Group>
        {detail && <Text size="sm" c="dimmed">{detail}</Text>}
      </Stack>
    </Paper>
  )
}

function HealthPanel({ overview }: { overview: Overview }) {
  const { services, activity } = overview
  const cinegyState = services.cinegyState === 'healthy' && !services.cinegyFresh
    ? (services.cinegyLastReadAt ? 'stale' : 'unknown')
    : services.cinegyState
  const metrics = [
    { label: 'الطبقات على الهواء', count: activity.onAirLayers },
    { label: 'العمليات الأخيرة المسجّلة اليوم', count: activity.recentOperationsToday },
    { label: 'المشغّلون النشطون اليوم', count: activity.activeOperatorsToday },
    { label: 'مواعيد العرض المعلّقة', count: activity.scheduledEvents },
    { label: 'طلبات الوصول المعلّقة', count: activity.pendingRequests },
    { label: 'المحادثات المتوقفة عن استقبال الرسائل', count: services.quarantinedChats },
  ]
  return (
    <Stack gap="lg">
      {services.schedulePaused && <Alert color="orange">تنفيذ المواعيد متوقف مؤقتًا، وتبقى المواعيد المعلّقة في الجدول.</Alert>}
      <SimpleGrid cols={{ base: 1, sm: 2, lg: 4 }}>
        <HealthTile title="Telegram" state={services.telegramState}
          detail={services.telegramFailures > 0 ? `حالات الفشل المتتالية ${numberFormat.format(services.telegramFailures)}` : undefined} />
        <HealthTile title="محرك Cinegy" state={cinegyState === 'unreachable' ? 'unresponsive' : cinegyState}
          detail={services.cinegyLastReadAt ? `آخر قراءة ${formatDateTime(services.cinegyLastReadAt)}` : 'لم تسجَّل قراءة بعد'} />
        <HealthTile title="مراقبة المخرج" state={services.outputMonitorState} />
        <HealthTile title="ترحيل البث" state={services.relayState} />
      </SimpleGrid>
      <Stack gap="sm">
        <Title order={2} size="h4">نشاط الجسر</Title>
        <SimpleGrid cols={{ base: 2, sm: 3, lg: 6 }}>
          {metrics.map(({ label, count }) => (
            <Paper key={label} withBorder p="md" radius="md">
              <Text size="xl" fw={700} c={count > 0 ? 'signal' : undefined}>{numberFormat.format(count)}</Text>
              <Text size="sm" c="dimmed">{label}</Text>
            </Paper>
          ))}
        </SimpleGrid>
        <Group gap="sm">
          <Text size="sm" c="dimmed">إصدار الجسر <bdi className="cgb-mono">{overview.version}</bdi></Text>
          <Text size="sm" c="dimmed">بدأ في {formatDateTime(overview.startedAt)}</Text>
        </Group>
      </Stack>
    </Stack>
  )
}

function SettingValue({ setting }: { setting: Setting }) {
  if (setting.kind === 'boolean' && setting.enabled !== null && setting.enabled !== undefined) {
    return <Badge color={setting.enabled ? 'teal' : 'gray'} variant="light">{setting.enabled ? 'مفعّل' : 'معطّل'}</Badge>
  }
  if (setting.kind === 'integer' && typeof setting.value === 'number') {
    return <Text size="sm" fw={600}>{numberFormat.format(setting.value)} {setting.unit}</Text>
  }
  return <Text size="sm" c="dimmed">غير متاح</Text>
}

function SettingsPanel({ settings }: { settings: Setting[] }) {
  return (
    <Stack gap="lg">
      <Text size="sm" c="dimmed">راجع التغييرات المتاحة هنا قبل حفظها. بقية الخيارات في إعدادات البوت.</Text>
      <SimpleGrid cols={{ base: 1, lg: 2 }} spacing="lg" style={{ alignItems: 'start' }}>
        {settingGroups.map(([id, label]) => {
          const group = settings.filter((setting) => setting.category === id)
          if (!group.length) return null
          return (
            <Paper key={id} withBorder radius="md" p="md">
              <Stack gap="md">
                <Title order={2} size="h4">{label}</Title>
                {group.map((setting) => (
                  <Group key={setting.id} justify="space-between" align="flex-start" gap="sm">
                    <Stack gap={4} style={{ flex: '1 1 220px', minWidth: 0 }}>
                      <Text fw={600} size="sm">{setting.label || setting.id}</Text>
                      {setting.description && <Text size="sm" c="dimmed">{setting.description}</Text>}
                    </Stack>
                    <Stack align="flex-end" gap={5}>
                      <Group gap="xs" justify="flex-end">
                        <SettingValue setting={setting} />
                        <AdminSettingEditor setting={setting} />
                      </Group>
                      {setting.protected && <Badge color="orange" variant="outline" size="xs">يتطلب تأكيدًا</Badge>}
                    </Stack>
                  </Group>
                ))}
              </Stack>
            </Paper>
          )
        })}
      </SimpleGrid>
    </Stack>
  )
}

export function AdminOverviewPage() {
  const session = useSession()
  const canRead = isAdmin(session.data)
  const overview = useQuery({
    queryKey: ['admin-overview', session.data?.id],
    enabled: canRead,
    refetchInterval: 30_000,
    retry: (failureCount, error) => !['forbidden', 'unauthorized'].includes(error.message) && failureCount < 1,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/overview', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const forbidden = overview.error?.message === 'forbidden' || overview.error?.message === 'unauthorized'
  const data = canRead && !forbidden ? overview.data : undefined

  return (
    <Stack gap="lg" dir="rtl">
      <PageHeader title="صحة الجسر والإعدادات" actions={canRead && <Button variant="default"
        leftSection={<IconRefresh size={17} />} loading={overview.isFetching}
        onClick={() => void overview.refetch()}>تحديث</Button>} />
      {session.isError && <Alert color="red" role="alert">{messageFor(session.error.message)}</Alert>}
      {!session.isPending && !session.isError && !canRead && <Alert color="red" role="alert">{messageFor('forbidden')}</Alert>}
      {(session.isPending || (canRead && overview.isPending)) && <Skeleton h={150} />}
      {overview.isError && <Alert color="red" role="alert">
        {messageFor(overview.error.message)}{data && ' تعرض الصفحة آخر قراءة متاحة.'}
      </Alert>}
      {data && <Text size="sm" c="dimmed">آخر تحديث {formatDateTime(data.publishedAt)}</Text>}
      {canRead && (
        <Tabs defaultValue="health" keepMounted={false}>
          <Tabs.List mb="md">
            <Tabs.Tab value="health" leftSection={<IconActivityHeartbeat size={17} />}>الحالة</Tabs.Tab>
            <Tabs.Tab value="settings" leftSection={<IconSettings size={17} />}>الإعدادات</Tabs.Tab>
            <Tabs.Tab value="readiness">جاهزية الوردية</Tabs.Tab>
            <Tabs.Tab value="files">ملفات التشغيل</Tabs.Tab>
          </Tabs.List>
          <Tabs.Panel value="readiness">{session.data?.id != null && <ShiftReadinessPanel accountId={session.data.id} />}</Tabs.Panel>
          <Tabs.Panel value="files"><RuntimeFileDiagnosticsPage embedded /></Tabs.Panel>
          <Tabs.Panel value="health">
            <Stack>
              {data && <HealthPanel overview={data} />}
              {session.data?.id != null && <NotificationCoveragePanel accountId={session.data.id} />}
            </Stack>
          </Tabs.Panel>
          <Tabs.Panel value="settings">{data && <SettingsPanel settings={data.settings} />}</Tabs.Panel>
        </Tabs>
      )}
    </Stack>
  )
}
