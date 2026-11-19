import { Alert, Button, Group, Modal, PasswordInput, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useState, type FormEvent } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

export function ResetPasswordModal({ account, onClose }: { account: Schemas['WebAccountResponse'] | null; onClose: () => void }) {
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
    if (!account) return
    setBusy(true)
    const { error: failure, response } = await api.PUT('/api/accounts/{username}/password', {
      params: { path: { username: account.username } },
      body: { password },
    })
    setBusy(false)
    if (response.ok) {
      notifications.show({ color: 'green', message: `تغيّرت كلمة مرور ${account.displayName}.` })
      close()
      return
    }
    setError(messageFor(errorCode(failure, response)))
  }

  return (
    <Modal opened={account !== null} onClose={close} title="كلمة مرور جديدة" centered>
      <form onSubmit={submit}>
        <Stack>
          <Text size="sm" c="dimmed">
            لـ {account?.displayName}. من دخل بكلمة المرور القديمة يُسجَّل خروجه.
          </Text>
          {error && <Alert color="red">{error}</Alert>}
          <PasswordInput
            label="كلمة المرور الجديدة"
            description="عشرة أحرف على الأقل"
            value={password}
            onChange={(e) => setPassword(e.currentTarget.value)}
            autoComplete="new-password"
            minLength={10}
            required
            data-autofocus
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
