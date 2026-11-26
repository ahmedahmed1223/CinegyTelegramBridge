import { AdjustableRow, AdjustableTable } from '../../components/AdjustableTable'
import { Alert, Button, Group, Paper, SegmentedControl, Select, SimpleGrid, Stack, Table, Text, Title } from '@mantine/core'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link } from 'react-router'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'

const periods = [
  { value: 'today', label: 'اليوم' }, { value: 'yesterday', label: 'أمس' },
  { value: 'week', label: 'آخر ٧ أيام' }, { value: 'month', label: 'آخر ٣٠ يومًا' },
]
const scopes = [{ value: 'all', label: 'كل المشغّلين' }, { value: 'mine', label: 'تعديلاتي' }]
const number = new Intl.NumberFormat('ar')

export function TickerReportPage() {
  const user = useSession().data
  const admin = isAdmin(user)
  const [scopeChoice, setScopeChoice] = useState('all')
  const [period, setPeriod] = useState('today')
  const [message, setMessage] = useState('')
  const scope = admin ? scopeChoice : 'mine'
  const report = useQuery({
    queryKey: ['ticker-report', user?.id, scope, period],
    enabled: Boolean(user),
    gcTime: 0,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/reports/ticker', { params: { query: { period, scope } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const download = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/reports/ticker/export', { params: { query: { period, scope } } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: ({ html, truncated }) => {
      const url = URL.createObjectURL(new Blob([html], { type: 'text/html;charset=utf-8' }))
      const link = document.createElement('a')
      link.href = url
      link.download = 'ticker-report.html'
      link.click()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      setMessage(truncated ? 'حُفظ التقرير بالبيانات المتاحة من سجل المحطة.' : 'حُفظ تقرير شريط الأخبار.')
    },
  })
  function resetNotice() {
    setMessage('')
    download.reset()
  }
  const data = report.data
  const error = report.error ?? download.error
  return (
    <Stack gap="lg" dir="rtl">
      <Group justify="space-between">
        <Title order={2}>تقرير شريط الأخبار</Title>
        <Group gap="xs">
          <Button component={Link} to="/history" variant="default">سجل العمليات</Button>
          <Button onClick={() => { setMessage(''); download.mutate() }} loading={download.isPending}
            disabled={!data || report.isFetching} variant="default">تنزيل التقرير</Button>
        </Group>
      </Group>
      <Group align="flex-end">
        <Select label="الفترة" data={periods} value={period} allowDeselect={false} disabled={download.isPending}
          onChange={(value) => { setPeriod(value ?? 'today'); resetNotice() }} />
        {admin && <SegmentedControl aria-label="نطاق التقرير" data={scopes} value={scope} disabled={download.isPending}
          onChange={(value) => { setScopeChoice(String(value)); resetNotice() }} />}
      </Group>
      {report.isPending && <Text role="status">جارٍ قراءة التقرير…</Text>}
      {message && <Text role="status">{message}</Text>}
      {error && <Alert color="red" role="alert">{messageFor(error.message)}</Alert>}
      {data?.truncated && <Alert color="orange">يعرض التقرير ما أمكن قراءته من سجل المحطة لهذه الفترة. النتائج جزئية.</Alert>}
      {data && (
        <>
          <SimpleGrid cols={{ base: 2, sm: 4 }}>
            <Paper p="md" withBorder><Text c="dimmed" size="sm">مرات النشر</Text><Text fw={600} size="xl">{number.format(data.publishes)}</Text></Paper>
            <Paper p="md" withBorder><Text c="dimmed" size="sm">الأخبار عند آخر نشر</Text><Text fw={600} size="xl">{number.format(data.items)}</Text></Paper>
            <Paper p="md" withBorder><Text c="dimmed" size="sm">أيام بلا نشر</Text><Text fw={600} size="xl">{number.format(data.silentDays)}</Text></Paper>
            <Paper p="md" withBorder><Text c="dimmed" size="sm">آخر نشر بتوقيت المحطة</Text><Text fw={600}><bdi dir="ltr">{data.lastPublishedAt || '—'}</bdi></Text></Paper>
          </SimpleGrid>
          <AdjustableTable layoutKey="ticker-report" label="تقرير الشريط" striped columns={[
            { id: 'date', label: 'التاريخ', width: 145 },
            { id: 'publications', label: 'مرات النشر', width: 118 },
            { id: 'latest', label: 'الأخبار عند آخر نشر', width: 148 },
            { id: 'range', label: 'نطاق العدد', width: 118 },
            { id: 'change', label: 'تغيّر العدد', width: 118 },
            { id: 'first', label: 'أول نشر', width: 138 },
            { id: 'last', label: 'آخر نشر', width: 138 },
            { id: 'operators', label: 'المشغّلون', width: 130 },
          ]}>
            <Table.Tbody>
              {data.days.map((day) => (
                <AdjustableRow key={day.date}>
                  <Table.Td><bdi dir="ltr">{day.date}</bdi></Table.Td>
                  <Table.Td>{number.format(day.publishes)}</Table.Td>
                  <Table.Td>{day.publishes ? number.format(day.items) : '—'}</Table.Td>
                  <Table.Td><bdi>{day.range}</bdi></Table.Td><Table.Td><bdi>{day.edits}</bdi></Table.Td>
                  <Table.Td><bdi dir="ltr">{day.first || '—'}</bdi></Table.Td>
                  <Table.Td><bdi dir="ltr">{day.last || '—'}</bdi></Table.Td>
                  <Table.Td><bdi>{day.operators || '—'}</bdi></Table.Td>
                </AdjustableRow>
              ))}
            </Table.Tbody>
          </AdjustableTable>
        </>
      )}
    </Stack>
  )
}
