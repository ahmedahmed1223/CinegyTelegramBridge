import { Badge, Button, Group, Popover, Stack, Text, Title } from '@mantine/core'
import { IconBell } from '@tabler/icons-react'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey, useSession } from '../../api/session'
import { formatDateTime } from '../../lib/time'

const number = new Intl.NumberFormat('ar')

function reminderError(code: string) {
  switch (code) {
    case 'reminder_stale': return 'انتهت مهلة التذكير أو تغيّر العرض.'
    case 'reminder_save_failed': return 'تعذّر حفظ التغيير. بقي التذكير كما هو.'
    default: return messageFor(code)
  }
}

export function PersonalAirReminders() {
  const client = useQueryClient()
  const session = useSession()
  const queryKey = ['personal-air-reminders', session.data?.id] as const
  const reminders = useQuery({
    queryKey,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/air/reminders', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    enabled: !!session.data,
    refetchInterval: 10000,
    retry: false,
    gcTime: 0,
  })
  const change = useMutation({
    mutationFn: async ({ id, action }: { id: string; action: 'acknowledge' | 'snooze' }) => {
      const { data, error, response } = await api.POST('/api/air/reminders/{id}', {
        params: { path: { id } }, body: { action },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onMutate: async () => client.cancelQueries({ queryKey }),
    onSuccess: (data, { action }) => {
      client.setQueryData(queryKey, data)
      notifications.show({ color: 'teal', message: action === 'snooze' ? 'أُجّل التذكير.' : 'تم تأكيد الاطّلاع على التذكير.' })
    },
    onError: (error) => {
      notifications.show({ color: 'red', message: reminderError(error.message) })
      if (['forbidden', 'unauthorized'].includes(error.message)) void client.invalidateQueries({ queryKey: sessionKey })
      void client.invalidateQueries({ queryKey })
    },
  })
  if (!session.data || !reminders.data?.items.length || reminders.isError) return null
  const snoozeMinutes = number.format(reminders.data.snoozeMinutes)
  return (
    <Popover position="bottom-end" width={350} shadow="md" withArrow>
      <Popover.Target>
        <Button variant="light" size="sm" px="xs" aria-label="تذكيرات البث" leftSection={<IconBell size={16} />}>
          <Badge variant="transparent" color="blue" aria-live="polite">{number.format(reminders.data.items.length)}</Badge>
        </Button>
      </Popover.Target>
      <Popover.Dropdown dir="rtl" maw="calc(100vw - 24px)" mah="min(55dvh, 26rem)" style={{ overflowY: 'auto' }}>
        <Stack gap="sm">
          <Title order={2} size="h4">تذكيرات البث</Title>
          {reminders.data.items.map((item) => (
            <Group key={item.id} justify="space-between">
              <Stack gap={3}>
                <Text fw={600}><bdi>{item.templateLabel}</bdi> · الطبقة {number.format(item.layer)}</Text>
                <Text c="dimmed" size="sm">
                  تذكير بعد {number.format(item.elapsedMinutes)} دقيقة · {item.expiresSilently ? 'متاح حتى' : 'المتابعة'} {formatDateTime(item.followUpAt)}
                </Text>
              </Stack>
              <Group gap="xs">
                <Button variant="default" size="xs" disabled={change.isPending}
                  onClick={() => change.mutate({ id: item.id, action: 'snooze' })}>
                  تأجيل {snoozeMinutes} دقائق
                </Button>
                <Button variant="light" size="xs" disabled={change.isPending}
                  onClick={() => change.mutate({ id: item.id, action: 'acknowledge' })}>
                  تم الاطّلاع
                </Button>
              </Group>
            </Group>
          ))}
        </Stack>
      </Popover.Dropdown>
    </Popover>
  )
}
