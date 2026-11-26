import { Alert, Badge, Button, Group, Pagination, Paper, Skeleton, Stack, Table, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconRefresh } from '@tabler/icons-react'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatClock, formatDateTime } from '../../lib/time'

const terminalErrors = new Set(['schedule_material_disabled', 'forbidden', 'unauthorized'])

export function useScheduleMaterials(page: number, enabled: boolean, autoRefresh = false) {
  return useQuery<Schemas['ScheduleMaterialPage']>({
    queryKey: ['schedule-materials', page],
    enabled,
    retry: false,
    refetchInterval: ({ state }) => enabled && autoRefresh && !terminalErrors.has(state.error?.message ?? '') ? 45_000 : false,
    refetchIntervalInBackground: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/schedule/materials', { params: { query: { page } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
}

export function ScheduleMaterialsPanel({ enabled = true, autoRefresh = false, title = 'جدول مواد القناة' }: {
  enabled?: boolean
  autoRefresh?: boolean
  title?: string
}) {
  const [page, setPage] = useState(0)
  const materials = useScheduleMaterials(page, enabled, autoRefresh)
  const list = materials.data
  const error = materials.error?.message
  const fresh = enabled && !error
  return (
    <Paper withBorder p="md" component="section" aria-label={title}>
      <Stack gap="sm">
        <Group justify="space-between" align="flex-start">
          <div>
            <Title order={2} size="h4">{title}</Title>
            {list && <Text size="xs" c="dimmed">
              {fresh ? 'آخر قراءة' : 'آخر قراءة محفوظة'} · {formatDateTime(materials.dataUpdatedAt)}
            </Text>}
          </div>
          <Button variant="default" size="sm" leftSection={<IconRefresh size={16} aria-hidden />}
            disabled={!enabled} loading={materials.isFetching} onClick={() => void materials.refetch()}>تحديث الجدول</Button>
        </Group>
        {!list && !enabled && <Text size="sm" c="dimmed">بانتظار اتصال الجسر.</Text>}
        {materials.isPending && materials.isFetching && <Skeleton h={90} aria-label="جارٍ تحميل جدول البث" />}
        {error && <Alert color="orange" role="alert">
          {error === 'schedule_material_disabled' ? 'جدول مواد القناة معطّل في إعدادات الجسر.'
            : error === 'schedule_material_unavailable' ? 'تعذّر قراءة جدول البث من المحطة.' : messageFor(error)}
        </Alert>}
        {list && !list.activeKnown && <Text size="sm" c="dimmed">تعذّر تحديد المادة المعروضة الآن.</Text>}
        {list && list.items.length === 0 && <Text size="sm" c="dimmed">لا توجد مواد في جدول القناة.</Text>}
        {list && list.items.length > 0 && <Table.ScrollContainer minWidth={510} type="native" tabIndex={0} aria-label={title}>
          <Table highlightOnHover aria-label={title}>
            <Table.Thead><Table.Tr>
              <Table.Th scope="col">المادة</Table.Th><Table.Th scope="col">البداية بتوقيت المحطة</Table.Th>
              <Table.Th scope="col">المدة</Table.Th><Table.Th scope="col">الحالة</Table.Th>
            </Table.Tr></Table.Thead>
            <Table.Tbody>{list.items.map((item) => <Table.Tr key={item.id}>
              <Table.Td><Text size="sm" dir="auto" style={{ overflowWrap: 'anywhere' }}>{item.name}</Text></Table.Td>
              <Table.Td><bdi dir="ltr">{item.stationTime}</bdi></Table.Td>
              <Table.Td><bdi dir="ltr">{formatClock(item.durationSeconds * 1000)}</bdi></Table.Td>
              <Table.Td>{item.active ? <Badge variant="light" color={fresh ? 'red' : 'gray'}>
                {fresh ? 'على الهواء' : 'عند آخر قراءة'}
              </Badge> : '—'}</Table.Td>
            </Table.Tr>)}</Table.Tbody>
          </Table>
        </Table.ScrollContainer>}
        {list && list.pageCount > 1 && <Pagination total={list.pageCount} value={list.page + 1} onChange={(next) => setPage(next - 1)} />}
      </Stack>
    </Paper>
  )
}
