import { Alert, Button, Group, Modal, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useIsMutating, useMutation, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey } from '../../api/session'

const revokeKey = ['telegram-access', 'revoke'] as const
type User = Schemas['BridgeUserResponse']
type Preview = Schemas['TelegramRevokePreview']

function revokeMessage(code: string) {
  switch (code) {
    case 'telegram_user_unavailable': return 'هذا المستخدم لم يعد مشغّلًا نشطًا.'
    case 'telegram_user_protected': return 'إلغاء الوصول من هذه الشاشة متاح للمشغّلين النشطين فحسب.'
    case 'telegram_user_stale': return 'تغيّرت بيانات المستخدم أو انتهت المراجعة. افتح مراجعة جديدة.'
    default: return messageFor(code)
  }
}

export function TelegramRevokeButton({ user, disabled = false }: { user: User; disabled?: boolean }) {
  const client = useQueryClient()
  const activeRequests = useIsMutating({ mutationKey: revokeKey })
  const [preview, setPreview] = useState<Preview | null>(null)

  function refreshRoster() {
    return Promise.all([
      client.invalidateQueries({ queryKey: ['accounts'] }),
      client.invalidateQueries({ queryKey: ['sessions'] }),
    ])
  }

  function reportFailure(error: Error) {
    setPreview(null)
    notifications.show({ color: 'red', message: revokeMessage(error.message) })
    if (['forbidden', 'unauthorized'].includes(error.message)) {
      void client.invalidateQueries({ queryKey: sessionKey })
    }
    void refreshRoster()
  }

  const reviewing = useMutation({
    mutationKey: revokeKey,
    mutationFn: async () => {
      const { data, response, error } = await api.POST('/api/telegram-access/users/{userId}/revoke/review', {
        params: { path: { userId: user.id } },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: setPreview,
    onError: reportFailure,
  })
  const saving = useMutation({
    mutationKey: revokeKey,
    mutationFn: async (selected: Preview) => {
      const { data, response, error } = await api.POST('/api/telegram-access/users/{userId}/revoke/confirm', {
        params: { path: { userId: selected.target.id } },
        body: { review: selected.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async ({ persisted }) => {
      setPreview(null)
      notifications.show(persisted ? { color: 'green', message: 'أُلغي وصول المستخدم وأُنهيت جلساته.' } : {
        color: 'orange',
        message: 'أُلغي الوصول أثناء التشغيل الحالي وتعذّر حفظ التغيير. قد يعود الوصول بعد إعادة تشغيل الجسر.',
      })
      await refreshRoster()
    },
    onError: reportFailure,
  })

  if (user.webOnly || user.role !== 'operator') return null
  return <>
    <Button variant="subtle" color="red" size="compact-sm" aria-label={`مراجعة إلغاء وصول ${user.name}`}
      loading={reviewing.isPending} disabled={disabled || activeRequests > 0} onClick={() => reviewing.mutate()}>
      إلغاء الوصول
    </Button>
    <Modal opened={preview !== null} title="مراجعة إلغاء الوصول" centered closeButtonProps={{ 'aria-label': 'إغلاق' }}
      closeOnEscape={!saving.isPending} closeOnClickOutside={!saving.isPending} withCloseButton={!saving.isPending}
      onClose={() => setPreview(null)}>
      {preview && <Stack gap="md" dir="rtl">
        <Text fw={600}><bdi>{preview.target.name}</bdi> <bdi className="cgb-mono">{preview.target.id}</bdi></Text>
        <Alert color="orange">يفقد المشغّل صلاحية الدخول من البوت والويب، وتُنهي الواجهة جلساته المفتوحة.</Alert>
        <Group justify="flex-end" gap="xs">
          <Button variant="default" disabled={saving.isPending} onClick={() => setPreview(null)}>إلغاء</Button>
          <Button color="red" loading={saving.isPending} onClick={() => saving.mutate(preview)}>تأكيد إلغاء الوصول</Button>
        </Group>
      </Stack>}
    </Modal>
  </>
}
