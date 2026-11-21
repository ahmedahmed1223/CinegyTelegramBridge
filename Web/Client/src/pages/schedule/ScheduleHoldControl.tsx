import { Alert, Button, Group, Modal, Stack, Text } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type HoldResult = Schemas['ScheduleHoldResult']
type Props = {
  paused: boolean
  onRefresh: (result?: HoldResult) => Promise<void>
}

const holdMessages: Readonly<Record<string, string>> = {
  schedule_hold_stale: 'تغيّرت حالة الجدولة أو قائمة المواعيد، أو انتهت صلاحية المراجعة. حدّث الحالة وراجعها مجددًا.',
  schedule_hold_unavailable: 'تعذّرت قراءة حالة تنفيذ مواعيد القوالب.',
  schedule_hold_save_failed: 'تعذّر حفظ حالة الجدولة. أعد المراجعة قبل المحاولة مجددًا.',
}

const actionLabel = (paused: boolean) =>
  paused ? 'إيقاف تنفيذ مواعيد القوالب' : 'استئناف تنفيذ مواعيد القوالب'

export function ScheduleHoldControl({ paused, onRefresh }: Props) {
  const [desired, setDesired] = useState<boolean | null>(null)
  const review = useMutation({
    mutationFn: async (next: boolean) => {
      const { data, error, response } = await api.POST('/api/schedule/templates/hold/review', { body: { paused: next } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const confirm = useMutation({
    mutationFn: async (token: string) => {
      const { data, error, response } = await api.POST('/api/schedule/templates/hold/confirm', { body: { review: token } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async (result) => {
      await onRefresh(result)
      setDesired(null)
    },
  })

  const busy = review.isPending || confirm.isPending
  const failure = confirm.error ?? review.error
  const startReview = (next: boolean) => {
    review.reset()
    confirm.reset()
    setDesired(next)
    review.mutate(next)
  }
  const close = () => {
    if (busy) return
    if (failure?.message === 'schedule_hold_stale') void onRefresh()
    setDesired(null)
    review.reset()
    confirm.reset()
  }
  const reviewed = review.data
  const mayConfirm = reviewed && !failure && reviewed.paused === desired

  return (
    <>
      <Button variant="light" color={paused ? 'blue' : 'orange'} onClick={() => startReview(!paused)}>
        {actionLabel(!paused)}
      </Button>
      <Modal opened={desired !== null} onClose={close} title={actionLabel(desired === true)}
        closeOnClickOutside={!busy} closeOnEscape={!busy} withCloseButton={!busy}>
        <Stack>
          {review.isPending && <Text role="status">جارٍ التحقق من حالة الجدولة…</Text>}
          {reviewed && (
            <>
              <Text>المواعيد المنتظرة لجميع مشغّلي القوالب: {reviewed.pendingAppointments}</Text>
              <Text size="sm">
                {reviewed.paused
                  ? 'تبقى المواعيد محفوظة، ويستمر العرض الجاري.'
                  : 'قد تُنفَّذ المواعيد المستحقة بعد الاستئناف حسب قواعد الجدولة.'}
              </Text>
              <Text size="sm">تبقى جدولة الموجز والشريط مستقلة.</Text>
              {reviewed.maintenance && !reviewed.paused && (
                <Alert color="orange">يبقى تنفيذ مواعيد القوالب معلّقًا أثناء الصيانة.</Alert>
              )}
            </>
          )}
          {failure && <Alert color="red" role="alert">{holdMessages[failure.message] ?? messageFor(failure.message)}</Alert>}
          <Group justify="flex-end">
            <Button variant="default" disabled={busy} onClick={close}>{failure ? 'إغلاق' : 'إلغاء'}</Button>
            {mayConfirm && (
              <Button color={reviewed.paused ? 'orange' : 'blue'} loading={confirm.isPending}
                onClick={() => confirm.mutate(reviewed.review)}>
                {reviewed.paused ? 'تأكيد الإيقاف' : 'تأكيد الاستئناف'}
              </Button>
            )}
          </Group>
        </Stack>
      </Modal>
    </>
  )
}
