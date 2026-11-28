import { Alert, Button, Group, Modal, NumberInput, Skeleton, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Command = Schemas['AirTimerCommand']
type Plan = NonNullable<Schemas['AirTimerPlan']>
type Change = { seconds: number; adjustSeconds?: never } | { adjustSeconds: number; seconds?: never }
type Review = { plan: Plan; token: string; change: Change }

const number = new Intl.NumberFormat('ar')
const localTime = new Intl.DateTimeFormat('ar', { timeStyle: 'medium' })
const timerErrors: Record<string, string> = {
  live_timer_invalid: 'أدخل مدة صحيحة بين ثانية واحدة و٢٤ ساعة.',
  live_timer_stale: 'تغيّر المشهد أو المؤقّت منذ المراجعة. حمّل الحالة الحالية.',
  live_timer_managed: 'يدير الجسر توقيت هذا المشهد ضمن تشغيل آخر.',
  live_timer_unverified: 'تعذّر التأكد من المشهد الذي سيُخفى. راجع لوحة الهواء.',
  live_timer_save_failed: 'تعذّر حفظ المؤقّت. بقيت الحالة السابقة سارية.',
}

async function timerRequest(layer: number, command: Pick<Command, 'action'> & Partial<Command>, signal?: AbortSignal) {
  const body: Command = { seconds: null, adjustSeconds: null, review: null, ...command }
  const { data, error, response } = await api.POST('/api/air/layers/{layer}/timer', { params: { path: { layer } }, body, signal })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

function timerError(error: Error) {
  return timerErrors[error.message] ?? messageFor(error.message)
}

export function LayerTimerModal({ layer, expectedTemplateKey, onClose }: {
  layer: number
  expectedTemplateKey?: string
  onClose: () => void
}) {
  const result = useQuery({
    queryKey: ['air-layer-timer', layer, expectedTemplateKey],
    queryFn: async ({ signal }) => {
      const result = await timerRequest(layer, { action: 'inspect' }, signal)
      if (!result.plan) throw new Error('live_timer_unverified')
      if (expectedTemplateKey && result.plan.templateKey !== expectedTemplateKey) throw new Error('live_timer_stale')
      return result.plan
    },
    gcTime: 0, retry: false, refetchOnWindowFocus: false, refetchOnReconnect: false,
  })
  if (result.data && !result.isFetching && !result.error) {
    return <TimerEditor key={result.dataUpdatedAt} plan={result.data} onClose={onClose}
      onReload={() => void result.refetch()} />
  }
  return <Modal opened title="مؤقّت إخفاء الطبقة" onClose={onClose}>
    <Stack gap="md" dir="rtl">
      {result.isFetching ? <Skeleton h={72} aria-label="جارٍ التحقق من مؤقّت المشهد" /> : result.error && (
        <Alert color="orange" role="alert">{timerError(result.error)}</Alert>
      )}
      <Group justify="flex-end">
        <Button variant="default" onClick={onClose}>إغلاق</Button>
        {result.error && <Button variant="light" onClick={() => void result.refetch()}>إعادة التحقق</Button>}
      </Group>
    </Stack>
  </Modal>
}

function TimerEditor({ plan, onClose, onReload }: { plan: Plan; onClose: () => void; onReload: () => void }) {
  const [seconds, setSeconds] = useState<number | string>('')
  const [review, setReview] = useState<Review | null>(null)
  const preview = useMutation({
    mutationFn: async (change: Change) => {
      const result = (await timerRequest(plan.layer, { action: 'preview', ...change })).plan
      if (!result?.review || !result.proposedHideAt || result.templateKey !== plan.templateKey) throw new Error('live_timer_stale')
      return { plan: result, token: result.review, change }
    },
    onSuccess: setReview,
  })
  const apply = useMutation({
    mutationFn: async (decision: Review) => {
      const result = await timerRequest(plan.layer, { action: 'apply', ...decision.change, review: decision.token })
      if (!result.hideAt) throw new Error('live_timer_save_failed')
      return result.hideAt
    },
    onSuccess: hideAt => {
      notifications.show({ color: 'teal', message: `حُفظ مؤقّت الإخفاء عند ${localTime.format(hideAt)}.` })
      onClose()
    },
  })
  const pending = preview.isPending || apply.isPending
  const error = apply.error ?? preview.error
  const validSeconds = typeof seconds === 'number' && Number.isInteger(seconds) && seconds >= 1 && seconds <= 86400

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!pending && validSeconds) preview.mutate({ seconds })
  }

  function back() {
    setReview(null)
    preview.reset()
    apply.reset()
  }

  return <Modal opened title={review ? 'مراجعة مؤقّت الإخفاء' : 'مؤقّت إخفاء الطبقة'}
    onClose={() => { if (!pending) onClose() }} withCloseButton={!pending} closeOnEscape={!pending} closeOnClickOutside={!pending}>
    <Stack gap="md" dir="rtl">
      <Group justify="space-between" gap="sm">
        <Text fw={600}><bdi>{plan.templateKey}</bdi></Text>
        <Text size="sm">الطبقة {number.format(plan.layer)}</Text>
      </Group>
      {plan.currentHideAt && <Text size="sm">المؤقّت الحالي <bdi>{localTime.format(plan.currentHideAt)}</bdi></Text>}
      {plan.maximumHideAt && <Text size="sm" c="dimmed">أقصى موعد حسب إعداد القالب <bdi>{localTime.format(plan.maximumHideAt)}</bdi></Text>}
      {error && <Alert role="alert" color="orange">
        <Stack gap="xs" align="flex-start">
          {timerError(error)}
          {error.message === 'live_timer_stale' && <Button size="xs" variant="light" onClick={onReload}>تحميل الحالة الحالية</Button>}
        </Stack>
      </Alert>}
      {review ? <>
        <Alert color="orange">
          موعد الإخفاء بعد التأكيد <bdi>{localTime.format(review.plan.proposedHideAt ?? 0)}</bdi>.
        </Alert>
        <Group justify="flex-end">
          <Button variant="default" disabled={pending} onClick={back}>رجوع</Button>
          <Button loading={apply.isPending} disabled={!!apply.error} onClick={() => apply.mutate(review)}>تأكيد المؤقّت</Button>
        </Group>
      </> : <form onSubmit={submit}>
        <Stack gap="md">
          <NumberInput label="مدة الإخفاء بالثواني" min={1} max={86400} allowDecimal={false} value={seconds} disabled={pending}
            onChange={value => setSeconds(typeof value === 'bigint' ? Number(value) : value)} />
          {!!plan.choices.length && <Group gap="xs" aria-label="مدد الإخفاء السريعة">
            {plan.choices.map(choice => <Button type="button" key={choice} size="xs" variant="light" disabled={pending}
              onClick={() => setSeconds(choice)}>{number.format(choice)} ثانية</Button>)}
          </Group>}
          {plan.currentHideAt && <Group gap="xs" aria-label="تعديل الوقت المتبقي">
            {[-30, -10, 10, 30].map(change => <Button type="button" size="xs" key={change} variant="default" disabled={pending}
              onClick={() => preview.mutate({ adjustSeconds: change })}>
              {change < 0 ? 'اطرح' : 'أضف'} {number.format(Math.abs(change))} ثانية
            </Button>)}
          </Group>}
          <Group justify="flex-end">
            <Button variant="default" disabled={pending} onClick={onClose}>إلغاء</Button>
            <Button type="submit" loading={preview.isPending} disabled={!validSeconds || error?.message === 'live_timer_stale'}>مراجعة المؤقّت</Button>
          </Group>
        </Stack>
      </form>}
    </Stack>
  </Modal>
}
