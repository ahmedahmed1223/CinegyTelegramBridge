import { Alert, Button, Group, Paper, Skeleton, Stack, Table, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatDateTime } from '../../lib/time'

const count = new Intl.NumberFormat('ar')
const stateLabels = new Map([
  ['recent-start', 'بدأ الجسر منذ أقل من ١٥ دقيقة.'],
  ['telegram-limiting', 'فُرض حدّ للإرسال عبر Telegram منذ بدء التشغيل.'],
  ['stable', 'استقرّ التشغيل وفق عدّادات هذه الجلسة.'],
])
const cinegyLabels = new Map([
  ['healthy', 'سليم'],
  ['unhealthy', 'متعثّر'],
  ['unreachable', 'يتعذّر الاتصال'],
])

export function OperationMetricsPanel({ accountId }: { accountId: number }) {
  const metrics = useQuery({
    queryKey: ['operation-metrics', accountId],
    gcTime: 0,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/operations/metrics', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const data = !metrics.isError ? metrics.data : undefined
  const rows = data ? [
    ['بدأ التشغيل', formatDateTime(data.startedAt)],
    ['مدة التشغيل بالدقائق', count.format(Math.floor(data.uptimeSeconds / 60))],
    ['إجمالي عمليات الهواء', count.format(data.airOperations.success + data.airOperations.failed + data.airOperations.blocked)],
    ['عمليات الهواء الناجحة', count.format(data.airOperations.success)],
    ['عمليات الهواء الفاشلة', count.format(data.airOperations.failed)],
    ['عمليات الهواء المحجوبة', count.format(data.airOperations.blocked)],
    ['مرات تقييد Telegram للإرسال', count.format(data.telegramRateLimitHits)],
    ['رسائل أسقطها طابور Telegram', count.format(data.telegramOutboxDropped)],
    ['اتصال Telegram', data.telegramState === 'connected' ? 'متصل' : data.telegramState === 'disconnected' ? 'منقطع' : 'غير معروف'],
    ['صحة Cinegy', cinegyLabels.get(data.cinegyState) ?? 'غير معروف'],
    ['آخر نبضة يومية', data.lastHeartbeatDate ?? 'لم تُرسل بعد'],
    ['المشاهد على الهواء', count.format(data.onAirCount)],
    ['أعلى حمولة لشاشة Telegram من الحدّ', data.richPayloadPeakPercent == null ? 'لا توجد قراءة' : `${count.format(data.richPayloadPeakPercent)}٪`],
  ] : []

  return (
    <Paper withBorder p="md" radius="md" component="section" aria-labelledby="operation-metrics-title">
      <Stack gap="sm">
        <Group justify="space-between">
          <Title order={2} size="h4" id="operation-metrics-title">أرقام التشغيل</Title>
          <Button variant="default" size="xs" loading={metrics.isFetching}
            onClick={() => void metrics.refetch()}>تحديث الأرقام</Button>
        </Group>
        {metrics.isPending && <Skeleton h={120} />}
        {metrics.isError && <Alert color="red" role="alert">{messageFor(metrics.error.message)}</Alert>}
        {data && (
          <>
            <Text size="sm" fw={600}>{stateLabels.get(data.state) ?? 'حالة التشغيل غير معروفة.'}</Text>
            <Text size="xs" c="dimmed">آخر قراءة {formatDateTime(data.checkedAt)}</Text>
            <Table>
              <Table.Tbody>{rows.map(([label, value]) => (
                <Table.Tr key={label}>
                  <Table.Th scope="row">{label}</Table.Th>
                  <Table.Td><bdi>{value}</bdi></Table.Td>
                </Table.Tr>
              ))}</Table.Tbody>
            </Table>
          </>
        )}
      </Stack>
    </Paper>
  )
}
