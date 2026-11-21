import { Alert, Button, Group, Modal, Pagination, Paper, Skeleton, Stack, Text, Title } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey, useSession } from '../../api/session'

const quarantineKey = ['telegram-access', 'delivery-quarantine'] as const
const date = new Intl.DateTimeFormat('ar', { dateStyle: 'medium', timeStyle: 'short' })
const number = new Intl.NumberFormat('ar')
type Row = Schemas['TelegramDeliveryQuarantineRow']
type Preview = Schemas['TelegramDeliveryQuarantineReview']

function quarantineError(code: string) {
  switch (code) {
    case 'telegram_quarantine_protected': return 'رفع تعليق التسليم متاح للمحادثات الخاصة فقط.'
    case 'telegram_quarantine_unavailable':
    case 'telegram_quarantine_stale': return 'تغيّرت حالة المحادثة أو انتهت المراجعة.'
    case 'telegram_quarantine_save_failed': return 'تعذّر الحفظ. بقي تعليق التسليم قائمًا.'
    default: return messageFor(code)
  }
}

function ChatDetails({ row }: { row: Row }) {
  return (
    <Stack gap={2}>
      <Text fw={600} className="cgb-mono" dir="ltr" style={{ textAlign: 'start' }}>{row.chatId}</Text>
      <Text c="dimmed" size="sm">
        {row.since ? date.format(new Date(row.since)) : 'وقت التعليق غير مسجّل'} · حالات فشل التسليم: {number.format(row.strikes)}
      </Text>
    </Stack>
  )
}

export function TelegramDeliveryQuarantine() {
  const client = useQueryClient()
  const session = useSession()
  const [page, setPage] = useState(0)
  const [preview, setPreview] = useState<Preview | null>(null)
  const rows = useQuery({
    queryKey: [...quarantineKey, session.data?.id, page],
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/telegram-access/delivery-quarantine', {
        params: { query: { page, pageSize: 20 } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    enabled: !!session.data,
    retry: false,
  })

  function refresh() {
    return Promise.all([
      client.invalidateQueries({ queryKey: quarantineKey }),
      client.invalidateQueries({ queryKey: ['admin-overview'] }),
    ])
  }

  function fail(error: Error) {
    setPreview(null)
    notifications.show({ color: 'red', message: quarantineError(error.message) })
    if (['forbidden', 'unauthorized'].includes(error.message)) void client.invalidateQueries({ queryKey: sessionKey })
    void refresh()
  }

  const review = useMutation({
    mutationFn: async (chatId: number) => {
      const { data, error, response } = await api.POST('/api/telegram-access/delivery-quarantine/{chatId}/reset/review', {
        params: { path: { chatId } },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: setPreview,
    onError: fail,
  })
  const confirm = useMutation({
    mutationFn: async (selected: Preview) => {
      const { data, error, response } = await api.POST('/api/telegram-access/delivery-quarantine/{chatId}/reset/confirm', {
        params: { path: { chatId: selected.target.chatId } }, body: { review: selected.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async () => {
      setPreview(null)
      notifications.show({ color: 'green', message: 'رُفع تعليق التسليم.' })
      await refresh()
    },
    onError: fail,
  })
  const busy = review.isPending || confirm.isPending
  const totalPages = rows.data ? Math.ceil(rows.data.total / rows.data.pageSize) : 0

  return (
    <Stack gap="sm" dir="rtl">
      <Title order={3}>المحادثات المعلّقة عن التسليم</Title>
      {rows.isError ? (
        <Alert color="red">{quarantineError(rows.error.message)}</Alert>
      ) : !rows.data ? (
        <Skeleton height={100} />
      ) : rows.data.items.length === 0 ? (
        <Text c="dimmed">لا توجد محادثات معلّقة.</Text>
      ) : rows.data.items.map((row) => (
        <Paper key={row.chatId} withBorder p="sm">
          <Group justify="space-between">
            <ChatDetails row={row} />
            {row.canReset && (
              <Button variant="light" size="xs" disabled={busy} onClick={() => review.mutate(row.chatId)}>رفع التعليق</Button>
            )}
          </Group>
        </Paper>
      ))}
      {totalPages > 1 && (
        <Pagination total={totalPages} value={(rows.data?.page ?? 0) + 1} onChange={(value) => setPage(value - 1)} disabled={busy} />
      )}
      <Modal opened={preview !== null} onClose={() => { if (!confirm.isPending) setPreview(null) }} title="تأكيد رفع تعليق التسليم"
        closeOnClickOutside={!confirm.isPending} closeOnEscape={!confirm.isPending} withCloseButton={!confirm.isPending} dir="rtl">
        {preview && (
          <Stack>
            <ChatDetails row={preview.target} />
            <Text size="sm">سيستأنف الجسر محاولات التسليم المعتادة لهذه المحادثة. قد يتوقف التسليم مجددًا بعد ثلاثة إخفاقات جديدة.</Text>
            <Group justify="end">
              <Button variant="default" disabled={confirm.isPending} onClick={() => setPreview(null)}>إلغاء</Button>
              <Button loading={confirm.isPending} onClick={() => confirm.mutate(preview)}>تأكيد رفع التعليق</Button>
            </Group>
          </Stack>
        )}
      </Modal>
    </Stack>
  )
}
