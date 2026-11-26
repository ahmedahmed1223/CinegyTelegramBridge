import { AdjustableRow, AdjustableTable } from '../../components/AdjustableTable'
import { Alert, Button, Group, Pagination, Paper, Select, SimpleGrid, Skeleton, Stack, Table, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { Link, useSearchParams } from 'react-router'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

const kindLabels: Readonly<Record<string, string>> = {
  all: 'كل الأنواع', show: 'عرض القوالب', mojaz: 'الموجز', news: 'شريط الأخبار',
}
const resultLabels: Readonly<Record<string, string>> = { all: 'كل النتائج', success: 'نجح', failed: 'تعذّر التنفيذ' }
const reasonLabels: Readonly<Record<string, string>> = {
  not_authorized: 'لم تعد صلاحية صاحب الموعد تسمح بالتنفيذ.',
  playback_target_changed: 'تغيّر تصميم الموجز أو طبقته بعد حجز الموعد.',
  playback_start_failed: 'تعذّر بدء تشغيل الموجز.',
  draft_handed_over: 'أُلغي النشر المؤجّل بعد تسليم المسودة لمشغّل آخر.',
  execution_failed: 'تعذّر التنفيذ. راجع حالة القالب أو سجل المحطة.',
}

function toOptions(labels: Readonly<Record<string, string>>) {
  return Object.entries(labels).map(([value, label]) => ({ value, label }))
}

const kinds = toOptions(kindLabels)
const results = toOptions(resultLabels)

export function ScheduleExecutionPage() {
  const [params, setParams] = useSearchParams()
  const requestedKind = params.get('kind') ?? 'all'
  const requestedResult = params.get('result') ?? 'all'
  const kind = Object.hasOwn(kindLabels, requestedKind) ? requestedKind : 'all'
  const result = Object.hasOwn(resultLabels, requestedResult) ? requestedResult : 'all'
  const requestedPage = Number(params.get('page') ?? 0)
  const page = Number.isInteger(requestedPage) && requestedPage >= 0 && requestedPage <= 2147483647 ? requestedPage : 0
  const history = useQuery({
    queryKey: ['schedule-executions', kind, result, page],
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/schedule/executions', {
        params: { query: { kind, result, page } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const data = history.data

  function change(name: string, value: string) {
    const next = new URLSearchParams(params)
    if (name !== 'page') next.delete('page')
    if (value === 'all' || value === '0') next.delete(name)
    else next.set(name, value)
    setParams(next)
  }

  return (
    <Stack dir="rtl" gap="lg">
      <Group justify="space-between" align="flex-start">
        <Stack gap={4}>
          <Title order={2}>سجل تنفيذ المواعيد</Title>
          {data && <Text size="sm" c="dimmed">يُفحص آخر {data.readLimit} سجلًا بتوقيت المحطة <bdi dir="ltr">{data.stationTimeZone}</bdi></Text>}
        </Stack>
        <Group gap="xs">
          <Button component={Link} to="/schedule" variant="default">المواعيد القادمة</Button>
          <Button variant="subtle" loading={history.isFetching} onClick={() => void history.refetch()}>تحديث</Button>
        </Group>
      </Group>
      <Paper p="md" withBorder>
        <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
          <Select label="نوع التنفيذ" value={kind} data={kinds} allowDeselect={false} onChange={(value) => change('kind', value ?? 'all')} />
          <Select label="النتيجة" value={result} data={results} allowDeselect={false} onChange={(value) => change('result', value ?? 'all')} />
        </SimpleGrid>
      </Paper>
      {history.isPending && <Skeleton h={112} aria-label="جارٍ تحميل سجل التنفيذ" />}
      {history.error && <Alert color="orange" role="alert">
        {history.error.message === 'schedule_execution_invalid' ? 'اختيار سجل التنفيذ غير صالح.' : messageFor(history.error.message)}
      </Alert>}
      {data && (
        <Paper p="md" withBorder>
          <Stack gap="sm">
            {data.items.length === 0 ? <Text size="sm" c="dimmed">لا توجد محاولات تنفيذ مطابقة.</Text> : (
              <AdjustableTable layoutKey="schedule-execution" label="سجل تنفيذ المواعيد" verticalSpacing="sm" columns={[
                { id: 'event', label: 'النوع والعنوان', width: 195 },
                { id: 'planned', label: 'الموعد', width: 146 },
                { id: 'executed', label: 'وقت التنفيذ', width: 146 },
                { id: 'delay', label: 'التأخير', width: 108 },
                { id: 'attempt', label: 'المحاولة', width: 108 },
                { id: 'result', label: 'النتيجة', width: 154 },
              ]}>
                <Table.Tbody>
                  {data.items.map((entry, index) => (
                    <AdjustableRow key={`${entry.kind}:${entry.ranAtMs}:${index}`}>
                      <Table.Td>
                        <Text fw={600}><bdi dir="auto">{entry.label || kindLabels[entry.kind]}</bdi></Text>
                        <Text size="xs" c="dimmed">{kindLabels[entry.kind]}{entry.layer > 0 && ` · الطبقة ${entry.layer}`}</Text>
                      </Table.Td>
                      <Table.Td><bdi dir="ltr">{entry.dueAtStation || '—'}</bdi></Table.Td>
                      <Table.Td><bdi dir="ltr">{entry.ranAtStation || '—'}</bdi></Table.Td>
                      <Table.Td>{entry.delaySeconds === null ? '—' : entry.delaySeconds <= 2 ? 'في الموعد' : `${entry.delaySeconds} ثانية`}</Table.Td>
                      <Table.Td>{entry.attempt || '—'}</Table.Td>
                      <Table.Td>
                        <Text size="sm" fw={600} c={entry.result === 'failed' ? 'red' : undefined}>{resultLabels[entry.result]}</Text>
                        {entry.reason && <Text size="xs" c="dimmed">{reasonLabels[entry.reason]}</Text>}
                      </Table.Td>
                    </AdjustableRow>
                  ))}
                </Table.Tbody>
              </AdjustableTable>
            )}
            {data.pageCount > 1 && <Pagination total={data.pageCount} value={data.page + 1}
              onChange={(value) => change('page', String(value - 1))}
              getControlProps={(control) => ({ 'aria-label': control === 'next' ? 'الصفحة التالية' : 'الصفحة السابقة' })} />}
          </Stack>
        </Paper>
      )}
    </Stack>
  )
}
