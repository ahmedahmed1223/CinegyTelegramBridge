import { Alert, Button, Group, Modal, Pagination, Paper, Skeleton, Stack, Text, Title } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useIsMutating, useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, sessionKey, useSession } from '../../api/session'

type Target = Pick<Schemas['TelegramSuspensionTarget'], 'id' | 'name'>
type Preview = Schemas['TelegramSuspensionPreview']
const suspendedKey = ['telegram-access', 'suspended-operators'] as const
const changeKey = ['telegram-access', 'suspension'] as const

function suspensionError(code: string) {
  switch (code) {
    case 'telegram_user_unavailable': return 'لم يعد هذا المستخدم ضمن المشغّلين المتاحين للإدارة.'
    case 'telegram_user_protected': return 'هذا الإجراء مخصّص لحسابات مشغّلي Telegram.'
    case 'telegram_suspension_stale': return 'تغيّرت حالة المشغّل أو انتهت المراجعة. راجع القائمة من جديد.'
    case 'telegram_suspension_save_failed': return 'تعذّر حفظ إعادة التفعيل. ما زال الوصول معطّلًا.'
    default: return messageFor(code)
  }
}

function OperatorIdentity({ user }: { user: Target }) {
  return (
    <Group gap="xs" style={{ overflowWrap: 'anywhere', minWidth: 0 }}>
      <Text fw={600}><bdi>{user.name}</bdi></Text>
      <Text size="sm" c="dimmed" className="cgb-mono" dir="ltr">{user.id}</Text>
    </Group>
  )
}

export function TelegramSuspensionButton({ user, suspend, busy = false }: { user: Target; suspend: boolean; busy?: boolean }) {
  const client = useQueryClient()
  const changes = useIsMutating({ mutationKey: changeKey })
  const [preview, setPreview] = useState<Preview | null>(null)
  const label = suspend ? 'تعطيل مؤقت' : 'إعادة التفعيل'

  function refresh() {
    return Promise.all([
      client.invalidateQueries({ queryKey: suspendedKey }),
      client.invalidateQueries({ queryKey: ['accounts'] }),
      client.invalidateQueries({ queryKey: ['sessions'] }),
    ])
  }

  function fail(error: Error) {
    setPreview(null)
    notifications.show({ color: 'red', message: suspensionError(error.message) })
    if (['forbidden', 'unauthorized'].includes(error.message)) {
      void client.invalidateQueries({ queryKey: sessionKey })
    }
    void refresh()
  }

  const reviewing = useMutation({
    mutationKey: changeKey,
    mutationFn: async () => {
      const { data, error, response } = await api.POST('/api/telegram-access/users/{userId}/suspension/review', {
        params: { path: { userId: user.id } },
        body: { disabled: suspend },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: setPreview,
    onError: fail,
  })
  const saving = useMutation({
    mutationKey: changeKey,
    mutationFn: async (selected: Preview) => {
      const { data, error, response } = await api.POST('/api/telegram-access/users/{userId}/suspension/confirm', {
        params: { path: { userId: selected.target.id } },
        body: { review: selected.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async ({ disabled, persisted }) => {
      setPreview(null)
      notifications.show(persisted ? {
        color: 'green', message: disabled ? 'عُطّل الوصول وأُنهيت جلسات الويب.' : 'أُعيد تفعيل الوصول.',
      } : {
        color: 'orange', message: 'عُطّل الوصول أثناء التشغيل الحالي وتعذّر حفظه. قد يعود بعد إعادة تشغيل الجسر.',
      })
      await refresh()
    },
    onError: fail,
  })

  return <>
    <Button size="compact-sm" variant="default" color={suspend ? 'orange' : undefined}
      aria-label={`${label} لحساب ${user.name}`} loading={reviewing.isPending}
      disabled={busy || changes > 0} onClick={() => reviewing.mutate()}>{label}</Button>
    <Modal opened={preview !== null} centered title={`مراجعة ${label}`} closeButtonProps={{ 'aria-label': 'إغلاق' }}
      closeOnClickOutside={!saving.isPending} closeOnEscape={!saving.isPending} withCloseButton={!saving.isPending}
      onClose={() => setPreview(null)}>
      {preview && <Stack gap="md" dir="rtl">
        <OperatorIdentity user={preview.target} />
        <Text size="sm">
          {preview.disabled
            ? 'يتوقف دخول المشغّل من البوت والويب وتُنهي الواجهة جلساته المفتوحة. تبقى عضويته وبياناتها في السجل إلى أن تعيد تفعيله.'
            : 'يستطيع المشغّل الدخول من البوت والويب مجددًا بعد إعادة التفعيل.'}
        </Text>
        <Group justify="flex-end">
          <Button variant="default" onClick={() => setPreview(null)} disabled={saving.isPending}>إلغاء</Button>
          <Button color={preview.disabled ? 'orange' : undefined}
            loading={saving.isPending} onClick={() => saving.mutate(preview)}>تأكيد {label}</Button>
        </Group>
      </Stack>}
    </Modal>
  </>
}

export function SuspendedTelegramOperators() {
  const session = useSession()
  const canManage = isAdmin(session.data)
  const [page, setPage] = useState(0)
  const suspended = useQuery({
    queryKey: [...suspendedKey, session.data?.id, page],
    enabled: canManage,
    staleTime: 15_000,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/telegram-access/suspended-operators', {
        params: { query: { page, pageSize: 12 } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  if (!canManage) return null
  const data = suspended.isError ? undefined : suspended.data
  const pages = data ? Math.ceil(data.total / data.pageSize) : 0
  return (
    <Paper withBorder p="md" radius="lg" dir="rtl">
      <Stack gap="md">
        <Title order={2} size="h4">المشغّلون المعطّلون مؤقتًا</Title>
        {suspended.isPending && <Skeleton h={75} />}
        {suspended.isError && <Alert color="red" role="alert">{suspensionError(suspended.error.message)}</Alert>}
        {data && <>
          {data.items.length === 0 && <Text c="dimmed" size="sm">لا يوجد مشغّلون معطّلون مؤقتًا.</Text>}
          {data.items.map((user) => (
            <Group justify="space-between" gap="sm" key={user.id}>
              <OperatorIdentity user={user} />
              <TelegramSuspensionButton user={user} suspend={false} />
            </Group>
          ))}
          {pages > 1 && <Pagination value={data.page + 1} total={pages}
            getItemProps={(index) => ({ 'aria-label': `الصفحة ${index}` })} onChange={(next) => setPage(next - 1)} />}
        </>}
      </Stack>
    </Paper>
  )
}
