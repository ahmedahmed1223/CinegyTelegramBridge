import { Alert, Button, Group, Paper, SimpleGrid, Stack, Table, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { HandoverAcknowledgementPanel } from './HandoverAcknowledgementPanel'
import { Link } from 'react-router'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useSession } from '../../api/session'

const number = new Intl.NumberFormat('ar')

function Totals({ entries }: { entries: [string, number][] }) {
  return (
    <SimpleGrid cols={{ base: 2, sm: 4 }}>
      {entries.map(([label, value]) => (
        <Paper withBorder p="md" key={label}>
          <Text size="sm" c="dimmed">{label}</Text>
          <Text size="xl" fw={600}>{number.format(value)}</Text>
        </Paper>
      ))}
    </SimpleGrid>
  )
}

function Weekly({ report }: { report: Schemas['WeeklyReport'] }) {
  return (
    <>
      <Text size="sm" c="dimmed">من <bdi dir="ltr">{report.from}</bdi> إلى <bdi dir="ltr">{report.through}</bdi> بتوقيت المحطة</Text>
      <Totals entries={[
        ['مرات نشر الشريط', report.tickerPublishes], ['تشغيلات لوحة العواجل', report.urgentRuns],
        ['العواجل المعروضة', report.urgentStories], ['إعدادات تختلف عن الافتراضي', report.changedCount],
      ]} />
      {report.tickerLast && <Text>آخر نشر للشريط <bdi dir="ltr">{report.tickerLast}</bdi></Text>}
      {report.nearLimit && <Alert color="orange">شاشة Telegram <bdi>{report.peakScreen || '—'}</bdi> بلغت {number.format(report.peakPercent)}٪ من حد الحمولة.</Alert>}
      {report.idleCount > 0 && (
        <Stack gap="xs">
          <Title order={3}>قوالب لم تُستخدم خلال آخر ٣٠ يومًا ({number.format(report.idleCount)})</Title>
          {report.idle.map((entry, index) => <Text key={index}><bdi>{entry}</bdi></Text>)}
        </Stack>
      )}
      {report.repeatCounts.length > 0 && (
        <Stack gap="xs">
          <Title order={3}>تنبيهات متكررة</Title>
          {report.repeatCounts.map((count, index) => <Text key={index}>تكرر تنبيه {number.format(count)} مرات</Text>)}
        </Stack>
      )}
      {report.changed.length > 0 && (
        <Stack gap="xs">
          <Title order={3}>الإعدادات المختلفة عن الافتراضي</Title>
          <Text><bdi>{report.changed.join('، ')}</bdi></Text>
        </Stack>
      )}
    </>
  )
}

function Handover({ report }: { report: Schemas['ShiftHandoverReport'] }) {
  return (
    <>
      <Text size="sm" c="dimmed">آخر {number.format(report.hours)} ساعة · {report.connection}</Text>
      <Stack gap="xs">
        <Title order={3}>على الهواء الآن</Title>
        {!report.activeCount && <Text c="dimmed">لا يوجد عرض مسجّل على الهواء.</Text>}
        {report.active.map((layer) => (
          <Text key={layer.layer}>الطبقة {number.format(layer.layer)} · <bdi>{layer.name || '—'}</bdi></Text>
        ))}
        {report.activeCount > report.active.length && <Text size="sm">طبقات إضافية {number.format(report.activeCount - report.active.length)}</Text>}
      </Stack>
      <Totals entries={[
        ['مرات العرض', report.showCount], ['مرات الإزالة', report.removalCount],
        ['العمليات المتعذّرة', report.failureCount], ['العمليات المرفوضة', report.blockedCount],
      ]} />
      {report.shows.length > 0 && (
        <Table.ScrollContainer minWidth={620}>
          <Table striped>
            <Table.Thead><Table.Tr><Table.Th>القالب</Table.Th><Table.Th>مرات العرض</Table.Th><Table.Th>آخر ظهور بتوقيت المحطة</Table.Th><Table.Th>المشغّلون</Table.Th></Table.Tr></Table.Thead>
            <Table.Tbody>
              {report.shows.map((item, index) => (
                <Table.Tr key={index}><Table.Td><bdi>{item.name || '—'}</bdi></Table.Td><Table.Td>{number.format(item.count)}</Table.Td>
                  <Table.Td><bdi dir="ltr">{item.last}</bdi></Table.Td><Table.Td><bdi>{item.operators || '—'}</bdi></Table.Td></Table.Tr>
              ))}
            </Table.Tbody>
          </Table>
        </Table.ScrollContainer>
      )}
      {report.hiddenGroups > 0 && <Text size="sm" c="dimmed">قوالب إضافية {number.format(report.hiddenGroups)}</Text>}
      {report.lastRemoval && <Text>آخر إزالة <bdi dir="ltr">{report.lastRemoval}</bdi></Text>}
      {report.recentFailures.length > 0 && (
        <Stack gap="xs">
          <Title order={3}>أحدث العمليات المتعذّرة</Title>
          {report.recentFailures.map((item, index) => (
            <Text key={index}><bdi dir="ltr">{item.when}</bdi> · <bdi>{[item.action, item.name].filter(Boolean).join(' ') || 'تعذّرت العملية'}</bdi></Text>
          ))}
        </Stack>
      )}
      {report.notableCount > 0 && <Text>أحداث لافتة في السجل {number.format(report.notableCount)}</Text>}
    </>
  )
}

export function HandoverReportsPage({ view }: { view: 'handover' | 'weekly' }) {
  const user = useSession().data
  const weekly = useQuery({
    queryKey: ['weekly-report', user?.id],
    enabled: Boolean(user) && view === 'weekly', retry: false, gcTime: 0,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/reports/weekly', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const handover = useQuery({
    queryKey: ['handover-report', user?.id],
    enabled: Boolean(user) && view === 'handover', retry: false, gcTime: 0,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/reports/handover', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const active = view === 'weekly' ? weekly : handover
  return (
    <Stack gap="lg" dir="rtl">
      <Group justify="space-between">
        <Title order={2}>{view === 'weekly' ? 'التقرير الأسبوعي' : 'تسليم المناوبة'}</Title>
        <Group gap="xs">
          <Button component={Link} to="/history" variant="default">سجل العمليات</Button>
          <Button loading={active.isFetching} variant="default" onClick={() => void active.refetch()}>تحديث</Button>
        </Group>
      </Group>
      <Group gap="xs">
        <Button component={Link} to="/reports/handover" variant={view === 'handover' ? 'filled' : 'subtle'}>تسليم المناوبة</Button>
        <Button component={Link} to="/reports/weekly" variant={view === 'weekly' ? 'filled' : 'subtle'}>التقرير الأسبوعي</Button>
      </Group>
      {active.isPending && <Text role="status">جارٍ قراءة التقرير…</Text>}
      {active.error && <Alert color="red" role="alert">{messageFor(active.error.message)}</Alert>}
      {active.data?.truncated && <Alert color="orange">التقرير جزئي. يعرض أحدث السجلات المتاحة في الفترة.</Alert>}
      {view === 'weekly' && weekly.data && <Weekly report={weekly.data} />}
      {view === 'handover' && handover.data && <>
        {handover.data.acknowledgement && <HandoverAcknowledgementPanel key={user?.id} scope={handover.data.acknowledgement} />}
        <Handover report={handover.data} />
      </>}
    </Stack>
  )
}
