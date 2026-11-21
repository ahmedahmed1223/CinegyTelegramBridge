import {
  Alert, Button, Group, Menu, Pagination, Paper, SegmentedControl, Select, SimpleGrid, Skeleton, Stack,
  Table, Text, TextInput, Title,
} from '@mantine/core'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { Link } from 'react-router'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'

type View = 'mine' | 'operations' | 'audit'
type Filters = { period: string; day: string; target: string; operatorId: string; kind: string; result: string }
type HistoryOption = Schemas['ShiftHistoryOption']

const initialFilters: Filters = { period: '48', day: '', target: '', operatorId: '', kind: '', result: '' }
const scopeOptions = [
  { value: 'mine', label: 'عملياتي' }, { value: 'operations', label: 'كل العمليات' }, { value: 'audit', label: 'تدقيق المحطة' },
]
const periodOptions = [
  { value: '24', label: 'آخر 24 ساعة' }, { value: '48', label: 'آخر 48 ساعة' },
  { value: '72', label: 'آخر 72 ساعة' }, { value: '168', label: 'آخر 7 أيام' }, { value: 'day', label: 'يوم محدد' },
]
const results = [
  { value: 'success', label: 'نجحت' }, { value: 'failed', label: 'تعذّرت' },
  { value: 'blocked', label: 'رُفضت' }, { value: 'problems', label: 'الأعطال والرفض' },
]
const resultLabels: Readonly<Record<string, string>> = { success: 'نجحت', failed: 'تعذّرت', blocked: 'رُفضت', cancelled: 'أُلغيت' }
const eventLabels: Readonly<Record<string, string>> = {
  air_control: 'تحكّم بالهواء',
  activity: 'نشاط',
  mojaz_run: 'الموجز',
  urgent_board_run: 'لوحة العواجل',
  news_publish: 'نشر الشريط',
  log_clear: 'مسح السجل',
}

function historyMessage(error: Error) {
  return error.message === 'history_invalid' ? 'تحقّق من فلاتر سجل العمليات.' : messageFor(error.message)
}

function toOptions(options: HistoryOption[] = [], labels: Readonly<Record<string, string>> = {}) {
  return options.map((option) => ({
    value: option.value,
    label: `${labels[option.value] ?? (option.label || option.value)} · ${option.count}`,
  }))
}

function downloadCsv(name: string, csv: string) {
  const url = URL.createObjectURL(new Blob(['\uFEFF', csv], { type: 'text/csv;charset=utf-8' }))
  const link = document.createElement('a')
  link.href = url
  link.download = name
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export function ShiftHistoryPage() {
  const admin = isAdmin(useSession().data)
  const [selected, setSelected] = useState<View>('mine')
  const [filters, setFilters] = useState(initialFilters)
  const [page, setPage] = useState(0)
  const [feedback, setFeedback] = useState('')
  const view = admin ? selected : 'mine'
  const showOperator = view !== 'mine'
  const audit = view === 'audit'
  const ready = filters.period !== 'day' || Boolean(filters.day)
  const scope = showOperator ? 'all' : 'mine'
  const queryFilter = {
    scope,
    hours: filters.period !== 'day' ? Number(filters.period) : undefined,
    day: filters.period === 'day' ? filters.day : undefined,
    target: filters.target || undefined,
    operatorId: showOperator ? filters.operatorId || undefined : undefined,
    kind: audit ? filters.kind || undefined : undefined,
    result: filters.result || undefined,
  }
  const records = useQuery({
    queryKey: ['shift-history', view, queryFilter, page],
    enabled: ready, retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET(audit ? '/api/history/audit' : '/api/history/operations', {
        params: { query: { ...queryFilter, page } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const csv = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET(audit ? '/api/history/audit/export' : '/api/history/operations/export', {
        params: { query: queryFilter },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (result) => {
      if (!result.count) {
        setFeedback('لا توجد سجلات للتصدير.')
        return
      }
      downloadCsv(audit ? 'audit.csv' : 'operations.csv', result.csv)
      setFeedback(result.truncated ? `صُدّر أحدث ${result.count} سجلًا متاحًا. التصدير جزئي.` : `صُدّر ${result.count} سجلًا.`)
    },
  })
  const data = records.data
  const error = records.error ?? csv.error

  function change(key: keyof Filters, value: string, resetChoices = false) {
    setFilters((previous) => ({
      ...previous, ...(resetChoices ? { target: '', operatorId: '', kind: '' } : {}), [key]: value,
    }))
    setPage(0)
    setFeedback('')
    csv.reset()
  }

  function switchView(value: string) {
    setSelected(value === 'operations' || value === 'audit' ? value : 'mine')
    setFilters((previous) => ({ ...previous, operatorId: '', kind: '', target: '' }))
    setPage(0)
    setFeedback('')
    csv.reset()
  }

  return (
    <Stack gap="lg" dir="rtl">
      <Group justify="space-between" align="flex-start">
        <Stack gap={4}>
          <Title order={2}>سجل العمليات</Title>
          {data && <Text size="sm" c="dimmed">بتوقيت المحطة <bdi dir="ltr">{data.stationTimeZone}</bdi></Text>}
        </Stack>
        <Group gap="xs">
          <Menu>
            <Menu.Target><Button variant="default">التقارير</Button></Menu.Target>
            <Menu.Dropdown>
              <Menu.Item component={Link} to="/reports/handover">تسليم المناوبة</Menu.Item>
              <Menu.Item component={Link} to="/reports/weekly">التقرير الأسبوعي</Menu.Item>
              <Menu.Item component={Link} to="/reports/work-summary">ملخص العمل</Menu.Item>
              <Menu.Item component={Link} to="/reports/templates">تقرير القوالب</Menu.Item>
              <Menu.Item component={Link} to="/reports/bulletins">تقرير الموجزات</Menu.Item>
              <Menu.Item component={Link} to="/reports/ticker">تقرير شريط الأخبار</Menu.Item>
            </Menu.Dropdown>
          </Menu>
          {admin && <Button variant="default" loading={csv.isPending} disabled={!ready || !data?.total || records.isError}
            onClick={() => { setFeedback(''); csv.mutate() }}>تصدير CSV</Button>}
        </Group>
      </Group>
      {admin && <SegmentedControl aria-label="نطاق السجل" value={view} data={scopeOptions} disabled={csv.isPending}
        onChange={switchView} />}
      <Paper p="md" withBorder>
        <Stack gap="sm">
          <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }} spacing="sm">
            <Select label="الفترة" data={periodOptions} value={filters.period} allowDeselect={false} disabled={csv.isPending}
              onChange={(value) => change('period', value ?? '48', true)} />
            {filters.period === 'day' && <TextInput type="date" label="اليوم بتوقيت المحطة" value={filters.day} dir="ltr" disabled={csv.isPending}
              onChange={(event) => change('day', event.currentTarget.value, true)} />}
            <Select label="النتيجة" placeholder="كل النتائج" data={results} value={filters.result || null} clearable disabled={csv.isPending}
              onChange={(value) => change('result', value ?? '')} />
            <Select label="القالب أو الهدف" placeholder="كل الأهداف" data={toOptions(data?.targets)} value={filters.target || null}
              clearable searchable disabled={csv.isPending}
              onChange={(value) => change('target', value ?? '')} />
            {showOperator && <Select label="المشغّل" placeholder="كل المشغّلين" data={toOptions(data?.operators)} value={filters.operatorId || null}
              clearable searchable disabled={csv.isPending} onChange={(value) => change('operatorId', value ?? '')} />}
            {audit && <Select label="نوع السجل" placeholder="كل الأنواع" data={toOptions(data?.kinds, eventLabels)} value={filters.kind || null}
              clearable disabled={csv.isPending} onChange={(value) => change('kind', value ?? '')} />}
          </SimpleGrid>
          {data && (data.hiddenTargets > 0 || data.hiddenOperators > 0) && <Text size="xs" c="dimmed">تظهر الخيارات الأكثر ورودًا في الفترة المحددة.</Text>}
        </Stack>
      </Paper>
      {feedback && <Text size="sm" role="status">{feedback}</Text>}
      {error && <Alert color="orange" role="alert">
        <Group justify="space-between">
          <Text size="sm">{historyMessage(error)}</Text>
          {records.isError && <Button variant="subtle" size="compact-sm" onClick={() => void records.refetch()}>إعادة التحميل</Button>}
        </Group>
      </Alert>}
      {data?.truncated && <Alert color="orange">بلغ السجل حدّ القراءة. تظهر أحدث السجلات المتاحة ضمن الفترة.</Alert>}
      <Paper p="md" withBorder>
        <Stack gap="sm">
          <Group justify="space-between">
            <Title order={3} size="h4">{scopeOptions.find((option) => option.value === view)?.label}</Title>
            {data && <Text size="sm" c="dimmed">عدد السجلات · {data.total}</Text>}
          </Group>
          {!ready && <Text size="sm" c="dimmed">اختر يومًا لعرض سجله.</Text>}
          {ready && records.isPending && <Skeleton h={110} aria-label="جارٍ تحميل العمليات" />}
          {data?.items.length === 0 && <Text size="sm" c="dimmed">لا توجد سجلات مطابقة.</Text>}
          {data && data.items.length > 0 && (
            <Table.ScrollContainer minWidth={showOperator ? 800 : 640} type="native" tabIndex={0} aria-label="سجل العمليات">
              <Table verticalSpacing="sm" aria-label="سجل العمليات">
                <Table.Thead><Table.Tr>
                  <Table.Th scope="col">وقت المحطة</Table.Th>
                  {audit && <Table.Th scope="col">النوع</Table.Th>}
                  <Table.Th scope="col">العملية</Table.Th><Table.Th scope="col">الهدف</Table.Th>
                  <Table.Th scope="col">الطبقة</Table.Th><Table.Th scope="col">النتيجة</Table.Th>
                  {showOperator && <Table.Th scope="col">المشغّل</Table.Th>}
                  <Table.Th scope="col">المرجع</Table.Th>
                </Table.Tr></Table.Thead>
                <Table.Tbody>
                  {data.items.map((item, index) => (
                    <Table.Tr key={`${item.reference}:${item.atMs}:${index}`}>
                      <Table.Td><bdi dir="ltr">{item.stationTime}</bdi></Table.Td>
                      {audit && <Table.Td>{eventLabels[item.event] ?? item.event}</Table.Td>}
                      <Table.Td><bdi dir="auto">{item.action || '—'}</bdi></Table.Td>
                      <Table.Td><bdi dir="auto">{item.target || '—'}</bdi></Table.Td>
                      <Table.Td>{item.layer || '—'}</Table.Td>
                      <Table.Td><Text size="sm" c={item.result === 'failed' ? 'red' : item.result === 'blocked' ? 'orange' : undefined}>
                        {resultLabels[item.result] ?? (item.result || '—')}
                      </Text></Table.Td>
                      {showOperator && <Table.Td><bdi dir="auto">{item.operatorName || item.operatorId || '—'}</bdi></Table.Td>}
                      <Table.Td><bdi dir="ltr" className="cgb-mono">{item.reference || '—'}</bdi></Table.Td>
                    </Table.Tr>
                  ))}
                </Table.Tbody>
              </Table>
            </Table.ScrollContainer>
          )}
          {data && data.pageCount > 1 && <Pagination total={data.pageCount} value={data.page + 1} onChange={(next) => setPage(next - 1)}
            getControlProps={(control) => ({ 'aria-label': control === 'next' ? 'الصفحة التالية' : 'الصفحة السابقة' })} />}
        </Stack>
      </Paper>
    </Stack>
  )
}
