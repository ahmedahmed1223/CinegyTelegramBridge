import { Alert, Badge, Button, Group, Modal, Paper, Skeleton, Stack, Text, Title } from '@mantine/core'
import { IconBrandTelegram, IconPlayerPlay, IconPlayerStop, IconRefresh } from '@tabler/icons-react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import classes from './LivePage.module.css'

type RelayState = Schemas['RelayState']
type Review = { action: 'start' | 'stop'; revision: string }
const relayKey = ['live-relay'] as const
const labels: Record<string, { title: string; color: string }> = {
  disabled: { title: 'معطّل', color: 'gray' },
  stopped: { title: 'متوقف', color: 'gray' },
  starting: { title: 'جارٍ التحقق من التشغيل', color: 'yellow' },
  running: { title: 'عملية الترحيل تعمل', color: 'teal' },
  retrying: { title: 'بانتظار إعادة المحاولة', color: 'yellow' },
  switching: { title: 'جارٍ تبديل المصدر', color: 'yellow' },
  failed: { title: 'تعذّر تشغيل الترحيل', color: 'red' },
  unverified: { title: 'تعذّر تحديد العملية', color: 'yellow' },
}

export function RelayPanel() {
  const [review, setReview] = useState<Review | null>(null)
  const [notice, setNotice] = useState('')
  const client = useQueryClient()
  const relay = useQuery<RelayState>({
    queryKey: relayKey,
    retry: false,
    refetchInterval: (query) => query.state.data?.state === 'starting' ? 1500 : 5000,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/live/relay', { signal })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const command = useMutation({
    mutationFn: async (request: Review) => {
      const { data, error, response } = await api.POST('/api/live/relay', { body: request })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
    onMutate: async () => {
      setNotice('')
      await client.cancelQueries({ queryKey: relayKey })
    },
    onSuccess: (data) => {
      client.setQueryData<RelayState>(relayKey, data)
      if (data.outcome === 'stopping') setNotice('طُلب الإيقاف. تظهر النتيجة في الحالة أعلاه.')
    },
    onSettled: () => {
      setReview(null)
      void client.invalidateQueries({ queryKey: relayKey })
    },
  })
  const data = relay.isError ? undefined : relay.data
  const state = data ? labels[data.state] : undefined
  const stopping = review?.action === 'stop'
  const stale = review && data?.revision !== review.revision

  function open(action: Review['action']) {
    if (!data) return
    command.reset()
    setNotice('')
    setReview({ action, revision: data.revision })
  }

  return (
    <Paper className={classes.signalPanel} radius="lg">
      <Stack gap="sm">
        <Group justify="space-between" align="center" gap="xs">
          <Group gap={6} wrap="nowrap"><IconBrandTelegram size={19} aria-hidden /><Title order={3}>ترحيل Telegram</Title></Group>
          {state && <Badge component="span" role="status" color={state.color} variant="light">{state.title}</Badge>}
        </Group>
        {relay.isPending && <Skeleton h={38} aria-label="جارٍ قراءة حالة الترحيل" />}
        {relay.isError && (
          <Stack gap="xs" align="flex-start">
            <Text size="sm" role="alert">{relay.error.message}</Text>
            <Button size="xs" variant="default" loading={relay.isFetching} leftSection={<IconRefresh size={15} />} onClick={() => relay.refetch()}>
              إعادة القراءة
            </Button>
          </Stack>
        )}
        {data?.state === 'disabled' && <Text size="sm" c="dimmed">فعّل الترحيل من إعدادات الجسر.</Text>}
        {data?.enabled && !data.configured && <Text size="sm" c="dimmed">اضبط مصدر البث ووجهة الترحيل من إعدادات الجسر.</Text>}
        {data?.state === 'unverified' && <Text size="sm" c="dimmed">تحقّق من عملية الترحيل على جهاز الجسر.</Text>}
        {data?.canStart && (
          <Button onClick={() => open('start')} loading={command.isPending} leftSection={<IconPlayerPlay size={17} />}>بدء الترحيل</Button>
        )}
        {data?.canStop && (
          <Button onClick={() => open('stop')} loading={command.isPending} variant="light" color="red" leftSection={<IconPlayerStop size={17} />}>إيقاف الترحيل</Button>
        )}
        {notice && data?.canStop && <Text size="sm" role="status">{notice}</Text>}
        {command.error && <Alert color="red" role="alert">{command.error.message}</Alert>}
      </Stack>
      <Modal opened={!!review} onClose={() => { if (!command.isPending) setReview(null) }} centered
        title={stopping ? 'إيقاف الترحيل إلى Telegram' : 'بدء الترحيل إلى Telegram'}
        closeOnEscape={!command.isPending} closeOnClickOutside={!command.isPending} withCloseButton={!command.isPending}>
        <Stack gap="md">
          <Text size="sm">
            {stopping ? 'سيوقف الجسر إرسال خرج القناة إلى Telegram ويلغي إعادة المحاولة التلقائية.'
              : 'سيبدأ الجسر إرسال خرج القناة إلى وجهة Telegram المضبوطة.'}
          </Text>
          {stale && <Alert color="yellow" role="alert">تغيّرت حالة الترحيل. أغلق التأكيد وراجع الحالة الحالية.</Alert>}
          <Group justify="flex-end" gap="xs">
            <Button variant="default" onClick={() => setReview(null)} disabled={command.isPending} data-autofocus>إلغاء</Button>
            <Button color={stopping ? 'red' : undefined} loading={command.isPending} disabled={!!stale}
              onClick={() => { if (review) command.mutate(review) }}>{stopping ? 'إيقاف الترحيل' : 'بدء الترحيل'}</Button>
          </Group>
        </Stack>
      </Modal>
    </Paper>
  )
}
