import { Alert, Button, Group, Modal, PasswordInput, Stack, Text } from '@mantine/core'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

interface Props {
  revision: string
  stale: boolean
  onClose: () => void
  onSaved: (status: Schemas['RelayState']) => void
}

export function RelayDestinationDialog({ revision, stale, onClose, onSaved }: Props) {
  const [destination, setDestination] = useState('')
  const [review, setReview] = useState('')
  const [pending, setPending] = useState(false)
  const [failure, setFailure] = useState('')
  const ready = /^rtmps?:\/\//i.test(destination.trim())

  async function submit() {
    if (!ready || stale || pending) return
    setPending(true)
    setFailure('')
    try {
      if (!review) {
        const { data, error, response } = await api.POST('/api/live/relay/destination/review', {
          body: { revision, destination },
        })
        if (!data) throw new Error(errorCode(error, response))
        setReview(data.review)
      } else {
        const { data, error, response } = await api.POST('/api/live/relay/destination/confirm', {
          body: { revision, destination, review },
        })
        if (!data) throw new Error(errorCode(error, response))
        setDestination('')
        onSaved(data)
      }
    } catch (error) {
      setReview('')
      setFailure(error instanceof Error && error.message === 'relay_invalid'
        ? 'أدخل رابط وجهة RTMP أو RTMPS صالحًا.' : messageFor(error instanceof Error ? error.message : ''))
    } finally {
      setPending(false)
    }
  }

  return (
    <Modal opened onClose={() => { if (!pending) onClose() }} title="تعديل وجهة الترحيل" centered
      closeOnEscape={!pending} closeOnClickOutside={!pending} withCloseButton={!pending}>
      <form onSubmit={(event) => { event.preventDefault(); void submit() }}>
        <Stack gap="md">
          {review ? <Text size="sm">
            سيحفظ الجسر وجهة الترحيل التي أدخلتها. يمكنك بدء الترحيل بعد الحفظ.
          </Text> : <PasswordInput label="رابط وجهة Telegram" description="رابط RTMP أو RTMPS الذي يتضمن مفتاح البث."
            value={destination} onChange={(event) => setDestination(event.currentTarget.value)}
            maxLength={4096} spellCheck={false} autoComplete="new-password" dir="ltr"
            data-autofocus disabled={pending || stale} />}
          {stale && <Alert color="yellow" role="alert">تغيّرت حالة الترحيل. أغلق النافذة وراجع الحالة الحالية.</Alert>}
          {failure && <Alert color="red" role="alert">{failure}</Alert>}
          <Group justify="flex-end" gap="xs">
            <Button variant="default" disabled={pending} onClick={onClose}>إلغاء</Button>
            <Button type="submit" loading={pending} disabled={!ready || stale}>
              {review ? 'حفظ الوجهة' : 'مراجعة'}
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
