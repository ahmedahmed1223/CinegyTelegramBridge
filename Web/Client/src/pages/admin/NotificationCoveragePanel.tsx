import { Alert, Button, Group, Paper, SimpleGrid, Skeleton, Stack, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconRefresh } from '@tabler/icons-react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

const number = new Intl.NumberFormat('ar')
const time = new Intl.DateTimeFormat('ar', { dateStyle: 'medium', timeStyle: 'short' })

export function NotificationCoveragePanel({ accountId }: { accountId: number | string }) {
  const coverage = useQuery({
    queryKey: ['admin-notification-coverage', accountId],
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/notifications/coverage', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const report = coverage.data

  return (
    <Paper withBorder p="md">
      <Stack gap="sm">
        <Group justify="space-between">
          <Title order={2} size="h4">مطابقة قوائم تنبيهات المشرفين</Title>
          <Button variant="default" size="xs" leftSection={<IconRefresh size={15} />}
            loading={coverage.isFetching} onClick={() => coverage.refetch()}>تحديث</Button>
        </Group>
        <Text size="sm" c="dimmed">يقارن الفحص بين صلاحيات المشرفين ووجهات التنبيه الفردية في الإعدادات.</Text>
        {report && !coverage.error && <Text size="xs" c="dimmed">آخر قراءة {time.format(report.checkedAt)}</Text>}
        {coverage.error ? (
          <Alert color="red">{messageFor(coverage.error.message)}</Alert>
        ) : report ? (
          <SimpleGrid cols={{ base: 1, sm: 3 }}>
            <CoverageCount label="مشرفون لهم وجهة تنبيه فردية" value={report.matched} />
            <CoverageCount label="مشرفون بلا وجهة تنبيه فردية" value={report.withoutPersonalChat} warn />
            <CoverageCount label="وجهات فردية بلا صلاحية مشرف" value={report.withoutAdminRights} warn />
          </SimpleGrid>
        ) : <Skeleton height={64} />}
      </Stack>
    </Paper>
  )
}

function CoverageCount({ label, value, warn = false }: { label: string; value: number; warn?: boolean }) {
  return (
    <div>
      <Text size="sm" c="dimmed">{label}</Text>
      <Text fw={700} c={warn && value > 0 ? 'orange' : undefined}>{number.format(value)}</Text>
    </div>
  )
}
