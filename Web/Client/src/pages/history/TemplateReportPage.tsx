import { AdjustableRow, AdjustableTable } from '../../components/AdjustableTable'
import { Alert, Button, Group, Pagination, Paper, SegmentedControl, Select, SimpleGrid, Stack, Table, Text, Title } from '@mantine/core'
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
const scopes = [{ value: 'all', label: 'كل المشغّلين' }, { value: 'mine', label: 'عمليات العرض الخاصة بي' }]
const count = new Intl.NumberFormat('ar')

function saveReport(html: string) {
  const url = URL.createObjectURL(new Blob([html], { type: 'text/html;charset=utf-8' }))
  const link = document.createElement('a')
  link.href = url
  link.download = 'template-report.html'
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export function TemplateReportPage() {
  const user = useSession().data
  const admin = isAdmin(user)
  const [scopeChoice, setScopeChoice] = useState('all')
  const [period, setPeriod] = useState('today')
  const [page, setPage] = useState(0)
  const [notice, setNotice] = useState('')
  const scope = admin ? scopeChoice : 'mine'
  const report = useQuery({
    queryKey: ['template-report', user?.id, scope, period, page],
    enabled: Boolean(user),
    gcTime: 0,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/reports/templates', {
        params: { query: { period, scope, page } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const download = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/reports/templates/export', { params: { query: { period, scope } } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: ({ html, truncated, count: supplied }) => {
      if (!supplied) {
        setNotice('لا توجد عمليات عرض للتصدير.')
        return
      }
      saveReport(html)
      setNotice(truncated ? `حُفظ أحدث ${count.format(supplied)} عرضًا متاحًا. التقرير جزئي.` : 'حُفظ تقرير عرض القوالب.')
    },
  })
  const data = report.data
  const error = report.error ?? download.error
  function resetPage() {
    setPage(0)
    setNotice('')
    download.reset()
  }

  return (
    <Stack gap="lg" dir="rtl">
      <Group justify="space-between">
        <Title order={2}>تقرير عرض القوالب</Title>
        <Group gap="xs">
          <Button component={Link} to="/history" variant="default">سجل العمليات</Button>
          <Button onClick={() => { setNotice(''); download.mutate() }} loading={download.isPending}
            disabled={!data?.total || report.isFetching} variant="default">تنزيل التقرير</Button>
        </Group>
      </Group>
      <Group align="flex-end">
        <Select label="الفترة" data={periods} value={period} allowDeselect={false} disabled={download.isPending}
          onChange={(value) => { setPeriod(value ?? 'today'); resetPage() }} />
        {admin && <SegmentedControl aria-label="نطاق التقرير" data={scopes} value={scope} disabled={download.isPending}
          onChange={(value) => { setScopeChoice(String(value)); resetPage() }} />}
      </Group>
      {report.isPending && <Text role="status">جارٍ قراءة التقرير…</Text>}
      {notice && <Text role="status">{notice}</Text>}
      {error && <Alert color="red" role="alert">{messageFor(error.message)}</Alert>}
      {data?.truncated && <Alert color="orange">يعرض التقرير ما أمكن قراءته من سجل المحطة لهذه الفترة. النتائج جزئية.</Alert>}
      {data && (
        <>
          <SimpleGrid cols={{ base: 2, sm: 3 }}>
            {[
              ['مرات العرض', data.total], ['المشغّلون', data.operators], ['بلا نهاية مسجّلة', data.withoutEnd],
            ].map(([label, value]) => (
              <Paper key={label} p="md" withBorder>
                <Text c="dimmed" size="sm">{label}</Text>
                <Text fw={600} size="xl">{count.format(Number(value))}</Text>
              </Paper>
            ))}
          </SimpleGrid>
          {!data.items.length ? <Text c="dimmed">لا توجد عمليات عرض في هذه الفترة.</Text> : (
            <AdjustableTable layoutKey="template-report" label="تقرير عرض القوالب" striped columns={[
              { id: 'template', label: 'القالب', width: 140 },
              { id: 'layer', label: 'الطبقة', width: 92 },
              { id: 'operator', label: 'المشغّل', width: 126 },
              { id: 'start', label: 'البدء بتوقيت المحطة', width: 175 },
              { id: 'end', label: 'النهاية بتوقيت المحطة', width: 175 },
              { id: 'duration', label: 'المدة', width: 95 },
              { id: 'reason', label: 'سبب النهاية', width: 140 },
            ]}>
              <Table.Tbody>
                {data.items.map((run, index) => (
                  <AdjustableRow key={`${data.page}-${index}`}>
                    <Table.Td><bdi>{run.name || '—'}</bdi></Table.Td>
                    <Table.Td>{count.format(run.layer)}</Table.Td>
                    <Table.Td><bdi>{run.operatorName || '—'}</bdi></Table.Td>
                    <Table.Td><bdi dir="ltr">{run.started || '—'}</bdi></Table.Td>
                    <Table.Td>{run.ended ? <bdi dir="ltr">{run.ended}</bdi> : 'بلا نهاية مسجّلة'}</Table.Td>
                    <Table.Td>{run.duration || '—'}</Table.Td>
                    <Table.Td>{run.endedBy || '—'}</Table.Td>
                  </AdjustableRow>
                ))}
              </Table.Tbody>
            </AdjustableTable>
          )}
          {data.pageCount > 1 && <Pagination total={data.pageCount} value={data.page + 1} onChange={(value) => setPage(value - 1)} />}
        </>
      )}
    </Stack>
  )
}
