import { Alert, Badge, Button, Group, Modal, Pagination, Paper, Skeleton, Stack, Text, TextInput } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { roleLabel } from '../../api/session'

const number = new Intl.NumberFormat('ar')
const time = new Intl.DateTimeFormat('ar', { dateStyle: 'medium', timeStyle: 'short' })

const activityLabel: Readonly<Record<string, string>> = {
  recent: 'تفاعل حديث',
  idle: 'تفاعل سابق',
  unknown: 'آخر تفاعل غير مسجّل',
}

function TelegramPresence({ accountId }: { accountId: number | string }) {
  const [input, setInput] = useState('')
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(0)
  const presence = useQuery({
    queryKey: ['telegram-access', accountId, 'presence', page, query],
    retry: false,
    refetchOnWindowFocus: false,
    gcTime: 0,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/telegram-access/presence', {
        params: { query: { page, q: query || undefined } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const data = presence.isError ? undefined : presence.data

  return (
    <Stack>
      <form onSubmit={(event) => {
        event.preventDefault()
        setPage(0)
        setQuery(input.trim())
      }}>
        <Group align="end" gap="xs">
          <TextInput label="اسم مستخدم Telegram" value={input} maxLength={80}
            onChange={(event) => setInput(event.currentTarget.value)} style={{ flex: '1 1 180px' }} />
          <Button type="submit">بحث</Button>
          {query && (
            <Button variant="default" onClick={() => { setInput(''); setQuery(''); setPage(0) }}>مسح البحث</Button>
          )}
        </Group>
      </form>
      {presence.isError && (
        <Alert color="red" role="alert">
          <Group justify="space-between">
            <Text size="sm">{messageFor(presence.error.message)}</Text>
            <Button size="compact-sm" variant="default" loading={presence.isFetching} onClick={() => void presence.refetch()}>
              إعادة المحاولة
            </Button>
          </Group>
        </Alert>
      )}
      {presence.isPending && <Skeleton h={104} />}
      {data && (
        <>
          <Group justify="space-between" align="start">
            <Stack gap={2}>
              <Text size="sm">خلال آخر {number.format(data.recentMinutes)} دقيقة يُعد التفاعل حديثًا.</Text>
              <Text size="xs" c="dimmed">وقت القراءة {time.format(data.capturedAt)}</Text>
            </Stack>
            <Button size="compact-sm" variant="default" loading={presence.isFetching} onClick={() => void presence.refetch()}>تحديث</Button>
          </Group>
          {data.items.length ? (
            <Stack gap="xs">
              {data.items.map((item, index) => (
                <Paper withBorder p="xs" key={index}>
                  <Group justify="space-between" gap="xs" align="start">
                    <Stack gap={4}>
                      <Text fw={600} style={{ overflowWrap: 'anywhere' }}><bdi>{item.name || 'بلا اسم مسجّل'}</bdi></Text>
                      <Group gap={6}>
                        <Badge variant="light" color="gray">{roleLabel[item.role] ?? item.role}</Badge>
                        {item.disabled && <Badge variant="light" color="orange">موقوف</Badge>}
                      </Group>
                    </Stack>
                    <Stack gap={3} align="end">
                      <Text size="sm" fw={600}>{activityLabel[item.state] ?? activityLabel.unknown}</Text>
                      {item.lastSeenAt != null && <Text size="xs" c="dimmed">{time.format(item.lastSeenAt)}</Text>}
                    </Stack>
                  </Group>
                </Paper>
              ))}
            </Stack>
          ) : <Text size="sm" c="dimmed">{query ? 'لا توجد أسماء تطابق البحث.' : 'لا يوجد مستخدمو Telegram في قائمة الوصول.'}</Text>}
          {data.pageCount > 1 && (
            <Pagination total={data.pageCount} value={data.page + 1} onChange={(value) => setPage(value - 1)} />
          )}
        </>
      )}
    </Stack>
  )
}

export function TelegramPresenceButton({ accountId }: { accountId: number | string }) {
  const [opened, setOpened] = useState(false)
  return (
    <>
      <Button size="xs" variant="default" onClick={() => setOpened(true)}>آخر تفاعل</Button>
      <Modal opened={opened} onClose={() => setOpened(false)} title="آخر تفاعل مع بوت Telegram" dir="rtl">
        {opened && <TelegramPresence accountId={accountId} />}
      </Modal>
    </>
  )
}
