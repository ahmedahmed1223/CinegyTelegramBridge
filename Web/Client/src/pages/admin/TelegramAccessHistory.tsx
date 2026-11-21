import { Alert, Badge, Group, Pagination, Paper, Select, Skeleton, Stack, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'
import { formatDateTime } from '../../lib/time'

type Decision = Schemas['AccessHistoryDecision']
const historyKey = ['telegram-access', 'history'] as const
const decisionOptions = [
  { value: 'all', label: 'كل القرارات' },
  { value: 'approved', label: 'الموافقات' },
  { value: 'rejected', label: 'الطلبات المرفوضة' },
]

function DecisionRow({ row }: { row: Decision }) {
  return (
    <Group justify="space-between" align="flex-start" gap="sm">
      <Stack gap={3}>
        <Text fw={600}>المعرّف <bdi className="cgb-mono" dir="ltr">{row.userId}</bdi></Text>
        <Group gap="xs">
          <Text size="sm" c="dimmed">اتُّخذ القرار في {formatDateTime(row.decidedAt)}</Text>
          {row.decidedByUserId && <Text size="sm" c="dimmed">
            معرّف المشرف <bdi className="cgb-mono" dir="ltr">{row.decidedByUserId}</bdi>
          </Text>}
          {row.requestedAt && <Text size="sm" c="dimmed">قُدّم الطلب في {formatDateTime(row.requestedAt)}</Text>}
        </Group>
      </Stack>
      <Badge variant="light" color={row.decision === 'approved' ? 'teal' : 'red'}>
        {row.decision === 'approved' ? 'مقبول' : 'مرفوض'}
      </Badge>
    </Group>
  )
}

export function TelegramAccessHistory() {
  const session = useSession()
  const canRead = isAdmin(session.data)
  const [page, setPage] = useState(0)
  const [decision, setDecision] = useState('all')
  const history = useQuery({
    queryKey: [...historyKey, session.data?.id, page, decision],
    enabled: canRead,
    staleTime: 15_000,
    retry: false,
    refetchOnWindowFocus: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/telegram-access/history', {
        params: { query: { page, pageSize: 12, decision } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })

  if (!canRead) return null
  const data = history.isError ? undefined : history.data
  const pages = data ? Math.ceil(data.total / data.pageSize) : 0
  return (
    <Paper withBorder radius="lg" p="md" dir="rtl">
      <Stack gap="md">
        <Group justify="space-between" align="flex-end">
          <Title order={2} size="h4">قرارات الوصول السابقة</Title>
          <Select label="نوع القرار" value={decision} data={decisionOptions} allowDeselect={false}
            onChange={(next) => { if (next) { setDecision(next); setPage(0) } }} />
        </Group>
        {history.isPending && <Skeleton h={72} />}
        {history.isError && <Alert color="red" role="alert">{messageFor(history.error.message)}</Alert>}
        {data && <>
          {data.truncated && <Alert color="orange">يعرض السجل أحدث القرارات المتاحة. قد توجد قرارات أقدم.</Alert>}
          {data.items.length === 0 && <Text size="sm" c="dimmed">لا تظهر قرارات بهذا الاختيار.</Text>}
          {data.items.map((row) => (
            <DecisionRow key={`${row.userId}/${row.decision}/${row.decidedAt}`} row={row} />
          ))}
          {pages > 1 && <Pagination value={data.page + 1} total={pages}
            getItemProps={(index) => ({ 'aria-label': `الصفحة ${index}` })}
            onChange={(next) => setPage(next - 1)} />}
        </>}
      </Stack>
    </Paper>
  )
}
