import { Alert, Button, Group, Modal, PasswordInput, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useState, type FormEvent } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

export function ResetPasswordModal({ account, onClose, onReset }: {
  account: Schemas['WebAccountResponse'] | null
  onClose: () => void
  onReset: () => void
}) {
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  function close() {
    setPassword('')
    setError('')
    onClose()
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!account || busy) return
    setError('')
    setBusy(true)
    try {
      const { error: failure, response } = await api.PUT('/api/accounts/{username}/password', {
        params: { path: { username: account.username } },
        body: { password },
      })
      if (!response.ok) {
        setError(messageFor(errorCode(failure, response)))
        return
      }
      notifications.show({ color: 'green', message: `تغيّرت كلمة مرور ${account.displayName}.` })
      onReset()
      close()
    } catch {
      setError('تعذّر الاتصال بالخادم. تحقّق من الاتصال وحاول مجددًا.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal opened={account !== null} onClose={close} title="كلمة مرور جديدة" centered
      closeOnClickOutside={!busy} closeOnEscape={!busy} withCloseButton={!busy}>
      <form onSubmit={submit}>
        <Stack>
          <Text size="sm" c="dimmed">
            لـ {account?.displayName} <Text span dir="ltr" className="cgb-mono">{account?.username}</Text>.
            {' '}من دخل بكلمة المرور القديمة يُسجَّل خروجه.
          </Text>
          {error && <Alert color="red" role="alert">{error}</Alert>}
          <PasswordInput
            label="كلمة المرور الجديدة"
            description="عشرة أحرف على الأقل"
            value={password}
            onChange={(e) => setPassword(e.currentTarget.value)}
            autoComplete="new-password"
            minLength={10}
            disabled={busy}
            required
            data-autofocus
          />
          <Group justify="flex-end">
            <Button variant="default" disabled={busy} onClick={close}>
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
