import { Alert, Button, Group, Modal, Stack, Text, TextInput } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey } from '../../api/session'

type Target = Pick<Schemas['TelegramAliasTarget'], 'id' | 'name'>
type Preview = Schemas['TelegramAliasPreview']

function aliasError(code: string) {
  switch (code) {
    case 'telegram_user_unavailable': return 'لم يعد المشغّل متاحًا للتعديل.'
    case 'telegram_user_protected': return 'يُتاح تعديل أسماء مشغّلي Telegram فقط.'
    case 'telegram_alias_too_long': return 'اكتب اسمًا لا يتجاوز ٨٠ حرفًا.'
    case 'telegram_alias_multiline': return 'اكتب الاسم في سطر واحد.'
    case 'telegram_alias_unchanged': return 'هذا هو الاسم الحالي.'
    case 'telegram_alias_stale': return 'تغيّر الاسم الحالي أو انتهت المراجعة. راجع التعديل مرة أخرى.'
    case 'telegram_alias_save_failed': return 'تعذّر حفظ اسم العمل. حاول مرة أخرى.'
    default: return messageFor(code)
  }
}

export function TelegramAliasButton({ user, busy = false }: { user: Target; busy?: boolean }) {
  const client = useQueryClient()
  const [opened, setOpened] = useState(false)
  const [alias, setAlias] = useState('')
  const [preview, setPreview] = useState<Preview | null>(null)
  const [failure, setFailure] = useState('')

  const reviewing = useMutation({
    mutationFn: async (value: string) => {
      const { data, error, response } = await api.POST('/api/telegram-access/users/{userId}/alias/review', {
        params: { path: { userId: user.id } }, body: { alias: value },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: setPreview,
    onError: (error) => setFailure(aliasError(error.message)),
  })

  const saving = useMutation({
    mutationFn: async (selected: Preview) => {
      const { data, error, response } = await api.POST('/api/telegram-access/users/{userId}/alias/confirm', {
        params: { path: { userId: selected.target.id } }, body: { review: selected.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async () => {
      setOpened(false)
      setPreview(null)
      notifications.show({ color: 'green', message: 'حُفظ اسم العمل.' })
      await Promise.all([
        client.invalidateQueries({ queryKey: ['accounts'] }),
        client.invalidateQueries({ queryKey: sessionKey }),
      ])
    },
    onError: (error) => {
      setFailure(aliasError(error.message))
      setPreview(null)
      void client.invalidateQueries({ queryKey: ['accounts'] })
      if (['forbidden', 'unauthorized'].includes(error.message)) {
        void client.invalidateQueries({ queryKey: sessionKey })
      }
    },
  })

  const pending = reviewing.isPending || saving.isPending
  function open() {
    setAlias(user.name === String(user.id) ? '' : user.name)
    setFailure('')
    setPreview(null)
    setOpened(true)
  }

  return (
    <>
      <Button size="xs" variant="subtle" onClick={open} disabled={busy}>اسم العمل</Button>
      <Modal opened={opened} onClose={() => { if (!pending) setOpened(false) }} title="تعديل اسم العمل"
        closeOnClickOutside={!pending} closeOnEscape={!pending} withCloseButton={!pending} dir="rtl">
        <Stack>
          <Group gap="xs" wrap="wrap">
            <Text style={{ overflowWrap: 'anywhere' }}><bdi>{preview?.target.name ?? user.name}</bdi></Text>
            <Text c="dimmed" size="sm" className="cgb-mono" dir="ltr">{preview?.target.id ?? user.id}</Text>
          </Group>
          {failure && <Alert color="red" role="alert">{failure}</Alert>}
          {preview ? (
            <>
              <Text size="sm" fw={600}>الاسم بعد الحفظ</Text>
              <Text style={{ overflowWrap: 'anywhere' }}><bdi>{preview.alias || String(preview.target.id)}</bdi></Text>
              <Group justify="end">
                <Button variant="default" disabled={pending} onClick={() => setPreview(null)}>رجوع للتعديل</Button>
                <Button loading={saving.isPending} onClick={() => saving.mutate(preview)}>تأكيد الحفظ</Button>
              </Group>
            </>
          ) : (
            <>
              <TextInput label="اسم العمل الجديد" description="حتى ٨٠ حرفًا. اتركه فارغًا لعرض رقم المستخدم."
                value={alias} onChange={(event) => setAlias(event.currentTarget.value)} disabled={pending} />
              <Group justify="end">
                <Button variant="default" disabled={pending} onClick={() => setOpened(false)}>إلغاء</Button>
                <Button loading={reviewing.isPending} onClick={() => { setFailure(''); reviewing.mutate(alias) }}>مراجعة التعديل</Button>
              </Group>
            </>
          )}
        </Stack>
      </Modal>
    </>
  )
}
