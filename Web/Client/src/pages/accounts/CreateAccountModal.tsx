import { Alert, Button, Group, Modal, PasswordInput, SegmentedControl, Select, Stack, Text, TextInput } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useState, type FormEvent } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { roleLabel } from '../../api/session'

type Kind = 'telegram' | 'webOnly'

interface Props {
  opened: boolean
  onClose: () => void
  bridgeUsers: Schemas['BridgeUserResponse'][]
  canCreateAdmin: boolean
  onCreated: () => void
}

export function CreateAccountModal({ opened, onClose, bridgeUsers, canCreateAdmin, onCreated }: Props) {
  const [kind, setKind] = useState<Kind>('telegram')
  const [userId, setUserId] = useState<string | null>(null)
  const [displayName, setDisplayName] = useState('')
  const [role, setRole] = useState<string | null>('operator')
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  // A password can be added for anyone in the bot who has none yet.
  const candidates = bridgeUsers
    .filter((user) => !user.webOnly && !user.username)
    .map((user) => ({ value: String(user.id), label: `${user.name} — ${roleLabel[user.role] ?? user.role}` }))

  function close() {
    setKind('telegram')
    setUserId(null)
    setDisplayName('')
    setRole('operator')
    setUsername('')
    setPassword('')
    setError('')
    onClose()
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError('')
    const body =
      kind === 'telegram'
        ? { kind, username, password, userId: userId ? Number(userId) : null, displayName: null, role: null }
        : { kind, username, password, displayName, role, userId: null }
    const { error: failure, response } = await api.POST('/api/accounts', { body })
    setBusy(false)
    if (response.ok) {
      notifications.show({ color: 'green', message: `أُنشئ الحساب ${username}.` })
      onCreated()
      close()
      return
    }
    setError(messageFor(errorCode(failure, response)))
  }

  return (
    <Modal opened={opened} onClose={close} title="حساب ويب جديد" centered size="lg">
      <form onSubmit={submit}>
        <Stack>
          <SegmentedControl
            fullWidth
            value={kind}
            onChange={(value) => setKind(value as Kind)}
            data={[
              { value: 'telegram', label: 'لمستخدم في البوت' },
              { value: 'webOnly', label: 'لشخص بلا Telegram' },
            ]}
          />
          <Text size="sm" c="dimmed">
            {kind === 'telegram'
              ? 'كلمة مرور لحساب موجود في البوت. يدخل بها الشخص نفسه بصلاحياته في البوت.'
              : 'حساب جديد يُضاف إلى الجسر كأي مستخدم، ويعمل من الويب وحده.'}
          </Text>

          {error && <Alert color="red">{error}</Alert>}

          {kind === 'telegram' ? (
            <Select
              label="المستخدم"
              placeholder={candidates.length ? 'اختر من مستخدمي البوت' : 'لكل مستخدمي البوت حسابات ويب'}
              data={candidates}
              value={userId}
              onChange={(value) => setUserId(value === null || value === undefined ? null : String(value))}
              searchable
              nothingFoundMessage="لا نتيجة"
              required
            />
          ) : (
            <Group grow align="flex-start">
              <TextInput label="الاسم الظاهر" value={displayName} onChange={(e) => setDisplayName(e.currentTarget.value)} maxLength={48} required />
              <Select
                label="الدور"
                value={role}
                onChange={(value) => setRole(value === null || value === undefined ? null : String(value))}
                allowDeselect={false}
                data={[
                  { value: 'operator', label: 'مشغّل' },
                  { value: 'admin', label: canCreateAdmin ? 'مشرف' : 'مشرف (للمالك وحده)', disabled: !canCreateAdmin },
                ]}
              />
            </Group>
          )}

          <Group grow align="flex-start">
            <TextInput
              label="اسم المستخدم"
              description="حروف لاتينية وأرقام و . _ -"
              value={username}
              onChange={(e) => setUsername(e.currentTarget.value)}
              dir="ltr"
              autoComplete="off"
              required
            />
            <PasswordInput
              label="كلمة المرور"
              description="عشرة أحرف على الأقل"
              value={password}
              onChange={(e) => setPassword(e.currentTarget.value)}
              autoComplete="new-password"
              minLength={10}
              required
            />
          </Group>

          <Group justify="flex-end">
            <Button variant="default" onClick={close}>
              إلغاء
            </Button>
            <Button type="submit" loading={busy}>
              إنشاء
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
