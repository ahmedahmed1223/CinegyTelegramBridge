import { Alert, Button, Code, CopyButton, Group, Progress, Stack, Text, ThemeIcon } from '@mantine/core'
import { IconBrandTelegram, IconCheck, IconCopy, IconShieldCheck } from '@tabler/icons-react'
import { useEffect, useRef, useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useRefreshSession } from '../../api/session'
import { useNow } from '../../hooks/useNow'
import { formatClock } from '../../lib/time'
import classes from './TelegramSignIn.module.css'

type Flow = Schemas['TelegramSignInResponse']
const POLL_MS = 2000

/**
 * Sign-in by approval in the bot. The page shows a code; the person sends it
 * to the bot (or taps the link), checks the code matches, and approves. The
 * page asks every two seconds until the bridge says yes, no, or time is up.
 */
export function TelegramSignIn() {
  const [flow, setFlow] = useState<Flow | null>(null)
  const [error, setError] = useState('')
  const [ended, setEnded] = useState<'' | 'denied' | 'expired'>('')
  const [busy, setBusy] = useState(false)
  const refreshSession = useRefreshSession()
  const now = useNow()
  const polling = useRef(false)

  async function begin() {
    setBusy(true)
    setError('')
    setEnded('')
    const { data, error: failure, response } = await api.POST('/api/auth/telegram')
    setBusy(false)
    if (data) setFlow(data)
    else setError(messageFor(errorCode(failure, response)))
  }

  useEffect(() => {
    if (!flow) return
    const timer = window.setInterval(async () => {
      if (polling.current) return
      polling.current = true
      try {
        const { data } = await api.POST('/api/auth/telegram/{flowId}', { params: { path: { flowId: flow.flowId } } })
        if (!data) return
        if (data.state === 'approved') {
          window.clearInterval(timer)
          await refreshSession()
        } else if (data.state === 'denied' || data.state === 'expired') {
          window.clearInterval(timer)
          setFlow(null)
          setEnded(data.state)
        }
      } finally {
        polling.current = false
      }
    }, POLL_MS)
    return () => window.clearInterval(timer)
  }, [flow, refreshSession])

  if (!flow) {
    return (
      <Stack>
        {error && <Alert color="red">{error}</Alert>}
        {ended === 'denied' && <Alert color="orange">رُفض طلب الدخول من Telegram.</Alert>}
        {ended === 'expired' && <Alert color="orange">انتهت مهلة الرمز قبل الموافقة. اطلب رمزًا جديدًا.</Alert>}
        <Group gap="sm" wrap="nowrap" align="flex-start">
          <ThemeIcon variant="light" size={40} radius="md">
            <IconShieldCheck size={22} />
          </ThemeIcon>
          <Text size="sm" c="dimmed">
            ستحصل على رمز من ستة أرقام ترسله إلى البوت، ثم توافق على الدخول من رسالة يرسلها لك. لا كلمة مرور تُكتب هنا.
          </Text>
        </Group>
        <Button size="md" leftSection={<IconBrandTelegram size={20} />} loading={busy} onClick={begin} fullWidth>
          اطلب رمز الدخول
        </Button>
      </Stack>
    )
  }

  const expiresAt = Date.parse(flow.expiresAt)
  const remaining = Math.max(0, expiresAt - now)
  const command = `/web ${flow.code}`
  const link = flow.botUsername ? `https://t.me/${flow.botUsername}?start=web-${flow.code}` : ''

  return (
    <Stack gap="md">
      <div className={classes.code} aria-label={`رمز الدخول ${flow.code.split('').join(' ')}`}>
        <span>{flow.code.slice(0, 3)}</span>
        <span>{flow.code.slice(3)}</span>
      </div>
      <Progress value={(remaining / 300_000) * 100} size="xs" aria-hidden />
      <Text size="sm" c="dimmed" ta="center">
        ينتهي الرمز بعد <span className="cgb-mono">{formatClock(remaining)}</span>
      </Text>

      {link && (
        <Button component="a" href={link} target="_blank" rel="noopener noreferrer" size="md" leftSection={<IconBrandTelegram size={20} />} fullWidth>
          افتح البوت وأرسل الرمز
        </Button>
      )}
      <Group justify="center" gap="xs">
        <Text size="sm" c="dimmed">
          {link ? 'أو أرسل إلى البوت:' : 'أرسل إلى البوت:'}
        </Text>
        <Code className="cgb-mono">{command}</Code>
        <CopyButton value={command}>
          {({ copied, copy }) => (
            <Button size="compact-xs" variant="subtle" onClick={copy} leftSection={copied ? <IconCheck size={14} /> : <IconCopy size={14} />}>
              {copied ? 'نُسخ' : 'نسخ'}
            </Button>
          )}
        </CopyButton>
      </Group>
      <Alert variant="light" color="gray">
        سيرسل لك البوت الرمز نفسه مع عنوان هذا المتصفح. وافق فقط إن كان مطابقًا.
      </Alert>
      <Button variant="subtle" color="gray" onClick={() => setFlow(null)}>
        إلغاء
      </Button>
    </Stack>
  )
}
