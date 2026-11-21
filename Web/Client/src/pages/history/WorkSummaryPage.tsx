import { Alert, Group, Paper, Select, SimpleGrid, Skeleton, Stack, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'

type Report = Schemas['WorkSummaryResponse']
const periods = [
  { value: 'today', label: 'اليوم' },
  { value: 'yesterday', label: 'أمس' },
  { value: 'week', label: 'آخر 7 أيام' },
  { value: 'month', label: 'آخر 30 يومًا' },
]
const scopes = [
  { value: 'all', label: 'جميع المشغّلين' },
  { value: 'mine', label: 'عملي فقط' },
]
const numberFormat = new Intl.NumberFormat('ar', { numberingSystem: 'latn' })

function SummaryCards({ data }: { data: Report }) {
  const metrics = [
    { label: 'العمليات', count: data.operations },
    { label: 'عمليات ناجحة', count: data.successful },
    { label: 'عروض ناجحة', count: data.shows },
    { label: 'عمليات رُفضت', count: data.blocked },
    { label: 'عمليات فشلت', count: data.failed },
    ...(data.scope === 'all' ? [{ label: 'مشغّلون نفّذوا عمليات', count: data.operators }] : []),
  ]
  return (
    <Stack gap="md">
      {data.truncated && <Alert color="orange">تغطي الحصيلة أحدث سجلات التشغيل المتاحة. قد تكون هناك عمليات أقدم في الفترة نفسها.</Alert>}
      {data.operations === 0 && !data.truncated && <Text size="sm" c="dimmed">لا توجد عمليات مسجّلة في هذه الفترة.</Text>}
      <SimpleGrid cols={{ base: 2, sm: 3 }}>
        {metrics.map(({ label, count }) => (
          <Paper key={label} withBorder radius="md" p="md">
            <Text fw={700} size="xl">{numberFormat.format(count)}</Text>
            <Text size="sm" c="dimmed">{label}</Text>
          </Paper>
        ))}
      </SimpleGrid>
    </Stack>
  )
}

export function WorkSummaryPage({ embedded = false }: { embedded?: boolean }) {
  const session = useSession()
  const stationScope = isAdmin(session.data)
  const [period, setPeriod] = useState('today')
  const [selectedScope, setSelectedScope] = useState('all')
  const scope = stationScope ? selectedScope : 'mine'
  const report = useQuery({
    queryKey: ['work-summary', session.data?.id, period, scope],
    enabled: !!session.data,
    staleTime: 15_000,
    retry: false,
    refetchOnWindowFocus: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/reports/work-summary', {
        params: { query: { period, scope } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })

  if (session.isPending) return <Skeleton h={100} />
  if (!session.data) return <Alert color="red" role="alert">{messageFor('unauthorized')}</Alert>

  return (
    <Stack gap="md" dir="rtl">
      {embedded ? <Title order={2} size="h4">تقرير العمل</Title> : <PageHeader title="تقرير العمل" />}
      <Group gap="sm" align="flex-end">
        <Select label="الفترة" value={period} data={periods} allowDeselect={false}
          onChange={(next) => { if (next) setPeriod(next) }} />
        {stationScope && <Select label="النطاق" value={scope} data={scopes} allowDeselect={false}
          onChange={(next) => { if (next) setSelectedScope(next) }} />}
      </Group>
      {report.isPending && <Skeleton h={100} />}
      {report.isError && <Alert color="red" role="alert">{messageFor(report.error.message)}</Alert>}
      {!report.isError && report.data && <SummaryCards data={report.data} />}
    </Stack>
  )
}
