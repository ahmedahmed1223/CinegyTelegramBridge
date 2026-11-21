import { Alert, Button, Group, Modal, Stack, Text } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

const queueMessages: Readonly<Record<string, string>> = {
  bulletin_urgent_gone: 'لا يوجد عاجل على الهواء الآن.',
  bulletin_urgent_unconfirmed: 'تعذّر التحقّق من العاجل المعروض. حدّث حالة الهواء قبل الحجز.',
  bulletin_stale: 'تغيّر الموجز أو العاجل بعد المراجعة.',
  bulletin_schedule_save_failed: 'تعذّر حجز موعد الموجز.',
}

export function BulletinAfterUrgentButton({ bulletin, disabled, onQueued }: {
  bulletin: Pick<Schemas['BulletinEditor'], 'id' | 'revision' | 'name'>
  disabled?: boolean
  onQueued: () => void
}) {
  const [opened, setOpened] = useState(false)
  const [notice, setNotice] = useState('')
  const review = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.POST('/api/content/bulletins/after-urgent/review', {
        body: { id: bulletin.id, revision: bulletin.revision },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const confirm = useMutation({
    mutationFn: async (reviewToken: string) => {
      const { data, error, response } = await api.POST('/api/content/bulletins/after-urgent/confirm', { body: { review: reviewToken } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (data) => {
      setOpened(false)
      setNotice(data.alreadyQueued ? 'الموجز في قائمة الانتظار بالفعل.' : 'حُجز الموجز للعرض بعد رفع العاجل.')
      onQueued()
    },
  })
  const busy = confirm.isPending || review.isPending
  const failure = confirm.error ?? review.error
  return (
    <Stack gap="xs">
      <Group>
        <Button variant="default" disabled={disabled || busy} onClick={() => {
          review.reset()
          confirm.reset()
          setNotice('')
          setOpened(true)
          review.mutate()
        }}>جدولة بعد العاجل</Button>
        {notice && <Text size="sm" role="status">{notice}</Text>}
      </Group>
      <Modal opened={opened} onClose={() => { if (!busy) setOpened(false) }} closeOnEscape={!busy} closeOnClickOutside={!busy}
        closeButtonProps={{ disabled: busy, 'aria-label': 'إغلاق مراجعة الموعد' }} title="حجز الموجز بعد العاجل">
        <Stack gap="md">
          <Text fw={600} dir="auto">{review.data?.name ?? bulletin.name}</Text>
          {review.isPending && <Text size="sm" role="status">جارٍ التحقّق من العاجل.</Text>}
          {review.data && <Text size="sm">
            ينتظر الموجز رفع العاجل عن الطبقة {review.data.urgentLayer} وانتهاء أي موجز على الهواء. تُستخدم النسخة المحفوظة عند بدء العرض.
          </Text>}
          {failure && <Alert color="orange" role="alert">{queueMessages[failure.message] ?? messageFor(failure.message)}</Alert>}
          <Group justify="flex-end">
            <Button variant="default" disabled={busy} onClick={() => setOpened(false)}>العودة</Button>
            {review.data && <Button loading={confirm.isPending} disabled={busy || confirm.isError}
              onClick={() => confirm.mutate(review.data.review)}>تأكيد الحجز</Button>}
          </Group>
        </Stack>
      </Modal>
    </Stack>
  )
}
