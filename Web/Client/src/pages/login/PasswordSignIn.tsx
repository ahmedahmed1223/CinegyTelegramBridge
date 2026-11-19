import { Alert, Button, PasswordInput, Stack, TextInput } from '@mantine/core'
import { IconAlertCircle } from '@tabler/icons-react'
import { useState, type FormEvent } from 'react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useRefreshSession } from '../../api/session'

export function PasswordSignIn() {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const refreshSession = useRefreshSession()

  async function submit(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError('')
    const { error: failure, response } = await api.POST('/api/auth/password', { body: { username, password } })
    if (response.ok) {
      await refreshSession()
      return
    }
    setBusy(false)
    setPassword('')
    setError(messageFor(errorCode(failure, response)))
  }

  return (
    <form onSubmit={submit}>
      <Stack>
        {error && (
          <Alert color="red" icon={<IconAlertCircle size={18} />} role="alert">
            {error}
          </Alert>
        )}
        <TextInput
          label="اسم المستخدم"
          value={username}
          onChange={(e) => setUsername(e.currentTarget.value)}
          autoComplete="username"
          dir="ltr"
          required
          data-autofocus
        />
        <PasswordInput
          label="كلمة المرور"
          value={password}
          onChange={(e) => setPassword(e.currentTarget.value)}
          autoComplete="current-password"
          required
        />
        <Button type="submit" size="md" loading={busy} fullWidth>
          دخول
        </Button>
      </Stack>
    </form>
  )
}
