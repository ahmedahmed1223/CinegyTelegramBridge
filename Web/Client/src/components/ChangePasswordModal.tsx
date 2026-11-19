import { Alert, Button, Group, Modal, PasswordInput, Stack } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useState, type FormEvent } from 'react'
import { api, errorCode } from '../api/client'
import { messageFor } from '../api/messages'

export function ChangePasswordModal({ opened, onClose }: { opened: boolean; onClose: () => void }) {
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  function close() {
    setCurrent('')
    setNext('')
    setError('')
    onClose()
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    const { error: failure, response } = await api.PUT('/api/me/password', { body: { currentPassword: current, newPassword: next } })
    setBusy(false)
    if (response.ok) {
      notifications.show({ color: 'green', message: 'تغيّرت كلمة المرور.' })
      close()
      return
    }
    setError(messageFor(errorCode(failure, response)))
  }

  return (
    <Modal opened={opened} onClose={close} title="تغيير كلمة المرور" centered>
      <form onSubmit={submit}>
        <Stack>
          {error && <Alert color="red">{error}</Alert>}
          <PasswordInput label="كلمة المرور الحالية" value={current} onChange={(e) => setCurrent(e.currentTarget.value)} autoComplete="current-password" required />
          <PasswordInput
            label="كلمة المرور الجديدة"
            description="عشرة أحرف على الأقل"
            value={next}
            onChange={(e) => setNext(e.currentTarget.value)}
            autoComplete="new-password"
            minLength={10}
            required
          />
          <Group justify="flex-end">
            <Button variant="default" onClick={close}>
              إلغاء
            </Button>
            <Button type="submit" loading={busy}>
              حفظ
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
