import { Alert, Button, Group, Modal, Pagination, Paper, Skeleton, Stack, Text, Title } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, sessionKey, useSession } from '../../api/session'
import { formatDateTime } from '../../lib/time'

type Block = Schemas['BlockedAccessItem']
type Preview = Schemas['AccessUnblockPreview']
const blockedKey = ['telegram-access', 'blocked'] as const
const reasons: Record<string, string> = {
  rejected: 'رُفض طلب الوصول',
  join_secret: 'تكررت محاولة إدخال رمز خاطئ',
  unknown: 'سبب الحظر غير مسجّل',
}

function blockedError(code: string) {
  if (code === 'access_blocked_stale') return 'تغيّر الحظر أو أُزيل. راجع القائمة الحالية.'
  if (code === 'access_unblock_save_failed') return 'تعذّر حفظ رفع الحظر. ما زال الحظر ساريًا.'
  return messageFor(code)
}

function BlockDetails({ item }: { item: Block }) {
  return (
    <Stack gap={3}>
      <Text fw={600}>المحادثة <bdi className="cgb-mono" dir="ltr">{item.chatId}</bdi></Text>
      <Group gap="xs">
        <Text size="sm" c="dimmed">{reasons[item.reason] ?? reasons.unknown}</Text>
        {item.blockedAt > 0 && <Text size="sm" c="dimmed">{formatDateTime(item.blockedAt)}</Text>}
        {item.blockedBy && <Text size="sm" c="dimmed">بواسطة <bdi>{item.blockedBy}</bdi></Text>}
      </Group>
    </Stack>
  )
}

export function BlockedTelegramChats() {
  const session = useSession()
  const client = useQueryClient()
  const canManage = isAdmin(session.data)
  const [page, setPage] = useState(0)
  const [preview, setPreview] = useState<Preview | null>(null)
  const blocked = useQuery({
    queryKey: [...blockedKey, session.data?.id, page],
    enabled: canManage,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/telegram-access/blocked', {
        params: { query: { page, pageSize: 12 } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })

  function refresh() {
    return client.invalidateQueries({ queryKey: blockedKey })
  }

  function fail(error: Error) {
    setPreview(null)
    notifications.show({ color: 'red', message: blockedError(error.message) })
    if (['forbidden', 'unauthorized'].includes(error.message)) {
      void client.invalidateQueries({ queryKey: sessionKey })
    }
    void refresh()
  }

  const reviewing = useMutation({
    mutationFn: async (chatId: number) => {
      const { data, error, response } = await api.POST('/api/telegram-access/blocked/{chatId}/review', {
        params: { path: { chatId } },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: setPreview,
    onError: fail,
  })
  const saving = useMutation({
    mutationFn: async (selected: Preview) => {
      const { data, error, response } = await api.POST('/api/telegram-access/blocked/{chatId}/confirm', {
        params: { path: { chatId: selected.item.chatId } }, body: { review: selected.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async () => {
      setPreview(null)
      notifications.show({ color: 'green', message: 'رُفع الحظر. يمكن للمحادثة تقديم طلب وصول جديد.' })
      await refresh()
    },
    onError: fail,
  })

  if (!canManage) return null
  const data = blocked.data
  const pages = data ? Math.ceil(data.total / data.pageSize) : 0
  const busy = reviewing.isPending || saving.isPending
  return (
    <Paper withBorder radius="lg" p="md" dir="rtl">
      <Stack gap="md">
        <Title order={2} size="h4">المحادثات المحظورة</Title>
        {blocked.isPending && <Skeleton h={70} />}
        {blocked.isError && <Alert role="alert" color="red">{blockedError(blocked.error.message)}</Alert>}
        {!blocked.isError && data && <>
          {data.items.length === 0 && <Text size="sm" c="dimmed">لا توجد محادثات محظورة.</Text>}
          {data.items.map((item) => (
            <Group key={item.chatId} justify="space-between" align="center" gap="sm">
              <BlockDetails item={item} />
              <Button variant="default" size="compact-sm" aria-label={`رفع حظر المحادثة ${item.chatId}`}
                disabled={busy} loading={reviewing.isPending && reviewing.variables === item.chatId}
                onClick={() => reviewing.mutate(item.chatId)}>رفع الحظر</Button>
            </Group>
          ))}
          {pages > 1 && <Pagination value={data.page + 1} total={pages} disabled={busy}
            onChange={(next) => setPage(next - 1)} />}
        </>}
      </Stack>
      <Modal opened={preview !== null} title="مراجعة رفع الحظر" centered closeButtonProps={{ 'aria-label': 'إغلاق' }}
        closeOnEscape={!saving.isPending} closeOnClickOutside={!saving.isPending} withCloseButton={!saving.isPending}
        onClose={() => setPreview(null)}>
        {preview && <Stack gap="md" dir="rtl">
          <BlockDetails item={preview.item} />
          <Text size="sm">تصبح المحادثة مؤهلة لتقديم طلب وصول جديد. يظل منح الصلاحية خاضعًا لموافقة المشرف.</Text>
          <Group justify="flex-end">
            <Button variant="default" disabled={saving.isPending} onClick={() => setPreview(null)}>إلغاء</Button>
            <Button loading={saving.isPending} onClick={() => saving.mutate(preview)}>تأكيد رفع الحظر</Button>
          </Group>
        </Stack>}
      </Modal>
    </Paper>
  )
}
