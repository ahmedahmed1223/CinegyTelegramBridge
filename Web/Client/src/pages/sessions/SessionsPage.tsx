import { Alert, Badge, Button, Group, Paper, Skeleton, Stack, Table, Text, Title, Tooltip } from '@mantine/core'
import { modals } from '@mantine/modals'
import { notifications } from '@mantine/notifications'
import { IconBrandTelegram, IconKey } from '@tabler/icons-react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, sessionKey, useSession } from '../../api/session'
import { useNow } from '../../hooks/useNow'
import { describeAgent } from '../../lib/agent'
import { formatAgo, formatDateTime } from '../../lib/time'

type Session = Schemas['SessionInfoResponse']
const sessionsKey = ['sessions'] as const

export function SessionsPage() {
  const me = useSession()
  const now = useNow(30_000)
  const queryClient = useQueryClient()
  const sessions = useQuery({
    queryKey: sessionsKey,
    queryFn: async () => {
      const { data, error, response } = await api.GET('/api/sessions')
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
    refetchInterval: 30_000,
  })

  function confirmEnd(session: Session) {
    modals.openConfirmModal({
      title: session.current ? 'إنهاء جلستك هذه' : 'إنهاء الجلسة',
      centered: true,
      children: (
        <Text size="sm">
          {session.current ? 'ستُسجَّل خروجك من هذا المتصفح.' : `سيُسجَّل خروج ${session.name} من ${describeAgent(session.agent)}.`}
        </Text>
      ),
      labels: { confirm: 'إنهاء', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: async () => {
        const { error, response } = await api.DELETE('/api/sessions/{id}', { params: { path: { id: session.id } } })
        if (!response.ok) {
          notifications.show({ color: 'red', message: messageFor(errorCode(error, response)) })
          return
        }
        if (session.current) await queryClient.invalidateQueries({ queryKey: sessionKey })
        else await queryClient.invalidateQueries({ queryKey: sessionsKey })
      },
    })
  }

  return (
    <Stack gap="lg">
      <div>
        <Title order={2}>الجلسات</Title>
        <Text c="dimmed" size="sm">
          {isAdmin(me.data) ? 'كل متصفح مسجَّل الدخول الآن. إنهاء جلسة يخرج صاحبها فورًا.' : 'المتصفحات التي دخلت منها. أنهِ ما لا تعرفه.'}
        </Text>
      </div>

      {sessions.isError && <Alert color="red">{sessions.error.message}</Alert>}

      <Paper radius="lg" p={0} style={{ overflow: 'hidden' }}>
        {sessions.isPending ? (
          <Stack p="lg">
            <Skeleton h={20} />
            <Skeleton h={20} />
          </Stack>
        ) : (
          <Table.ScrollContainer minWidth={760}>
            <Table verticalSpacing="sm" horizontalSpacing="lg" highlightOnHover style={{ whiteSpace: 'nowrap' }}>
              <Table.Thead>
                <Table.Tr>
                  <Table.Th>المستخدم</Table.Th>
                  <Table.Th>الدخول</Table.Th>
                  <Table.Th>المتصفح</Table.Th>
                  <Table.Th>العنوان</Table.Th>
                  <Table.Th>بدأت</Table.Th>
                  <Table.Th>آخر نشاط</Table.Th>
                  <Table.Th />
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {sessions.data?.map((session) => (
                  <Table.Tr key={session.id}>
                    <Table.Td>
                      <Group gap={6}>
                        <Text fw={600}>{session.name}</Text>
                        {session.current && (
                          <Badge size="sm" variant="light">
                            هذه الجلسة
                          </Badge>
                        )}
                      </Group>
                    </Table.Td>
                    <Table.Td>
                      <Group gap={6} wrap="nowrap">
                        {session.method === 'telegram' ? <IconBrandTelegram size={16} color="var(--mantine-color-signal-6)" /> : <IconKey size={16} />}
                        <Text size="sm">{session.method === 'telegram' ? 'Telegram' : 'كلمة مرور'}</Text>
                      </Group>
                    </Table.Td>
                    <Table.Td>
                      <Tooltip label={session.agent || '—'} multiline w={320}>
                        <Text size="sm">{describeAgent(session.agent)}</Text>
                      </Tooltip>
                    </Table.Td>
                    <Table.Td>
                      <Text size="sm" className="cgb-mono" span>
                        {session.address || '—'}
                      </Text>
                    </Table.Td>
                    <Table.Td>
                      <Text size="sm" c="dimmed">
                        {formatDateTime(session.createdAt)}
                      </Text>
                    </Table.Td>
                    <Table.Td>
                      <Text size="sm">{formatAgo(now - Date.parse(session.lastSeenAt))}</Text>
                    </Table.Td>
                    <Table.Td>
                      <Button size="compact-sm" variant="subtle" color="red" onClick={() => confirmEnd(session)}>
                        إنهاء
                      </Button>
                    </Table.Td>
                  </Table.Tr>
                ))}
              </Table.Tbody>
            </Table>
          </Table.ScrollContainer>
        )}
      </Paper>
    </Stack>
  )
}
