import { Alert, Button, Group, Modal, SimpleGrid, Skeleton, Stack, Text } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useSession } from '../../api/session'

type Target = { id: number; name: string }

const number = new Intl.NumberFormat('ar')
const relative = new Intl.RelativeTimeFormat('ar', { numeric: 'always' })

function activityAge(minutes: number) {
  if (minutes >= 1440) return relative.format(-Math.floor(minutes / 1440), 'day')
  if (minutes >= 60) return relative.format(-Math.floor(minutes / 60), 'hour')
  return minutes > 0 ? relative.format(-minutes, 'minute') : 'الآن'
}

function operatorActivityError(code: string) {
  switch (code) {
    case 'telegram_user_unavailable': return 'لم يعد المشغّل ضمن القائمة المتاحة.'
    case 'telegram_user_protected': return 'يتاح سجل النشاط لمشغّلي Telegram فقط.'
    default: return messageFor(code)
  }
}

function OperatorActivity({ id }: { id: number }) {
  const session = useSession()
  const activity = useQuery({
    queryKey: ['telegram-access', session.data?.id, 'operator-activity', id],
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/telegram-access/users/{userId}/activity', {
        params: { path: { userId: id } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    enabled: !!session.data,
    retry: false,
    gcTime: 0,
  })

  if (activity.isError) {
    return (
      <Stack>
        <Alert color="red">{operatorActivityError(activity.error.message)}</Alert>
        <Button variant="default" onClick={() => void activity.refetch()}>إعادة المحاولة</Button>
      </Stack>
    )
  }
  if (!activity.data) return <Skeleton height={150} />
  const { ageMinutes, recentMinutes, state, today } = activity.data
  const lastSeen = ageMinutes == null
    ? 'لا يوجد تفاعل مسجّل'
    : `${state === 'recent' ? 'تفاعل حديث' : 'آخر تفاعل'} · ${activityAge(ageMinutes)}`
  return (
    <Stack gap="md">
      <div>
        <Text fw={600}>{lastSeen}</Text>
        <Text c="dimmed" size="sm">آخر تفاعل مع البوت. تُحسب الحداثة خلال {number.format(recentMinutes)} دقيقة.</Text>
      </div>
      <div>
        <Text fw={700} mb="xs">عمليات البث اليوم</Text>
        {today.truncated && <Alert color="yellow" mb="xs">بلغ السجل حدّ القراءة. قد تكون الأرقام جزئية.</Alert>}
        <SimpleGrid cols={{ base: 2, xs: 3 }}>
          {([
            ['العمليات', today.operations],
            ['الناجحة', today.successful],
            ['الممنوعة', today.blocked],
            ['الفاشلة', today.failed],
            ['العروض الناجحة', today.shows],
          ] as const).map(([label, value]) => (
            <Stack key={label} gap={2}>
              <Text size="sm" c="dimmed">{label}</Text>
              <Text fw={600}>{number.format(value)}</Text>
            </Stack>
          ))}
        </SimpleGrid>
      </div>
    </Stack>
  )
}

export function TelegramOperatorActivityButton({ user }: { user: Target }) {
  const [opened, setOpened] = useState(false)
  return (
    <>
      <Button size="xs" variant="subtle" onClick={() => setOpened(true)}>النشاط</Button>
      <Modal opened={opened} onClose={() => setOpened(false)} title="نشاط المشغّل" dir="rtl">
        <Stack>
          <Group gap="xs">
            <Text fw={600} style={{ overflowWrap: 'anywhere' }}><bdi>{user.name}</bdi></Text>
            <Text c="dimmed" size="sm" className="cgb-mono" dir="ltr">{user.id}</Text>
          </Group>
          {opened && <OperatorActivity id={user.id} />}
        </Stack>
      </Modal>
    </>
  )
}
