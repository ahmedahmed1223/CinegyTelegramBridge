import { Alert, Badge, Button, Group, Modal, Paper, Stack, Text, Title } from '@mantine/core'
import { modals } from '@mantine/modals'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Request = Schemas['UrgentPlaybackRequest']
type Preview = Schemas['UrgentRunPreview']
const format = new Intl.NumberFormat('ar', { maximumFractionDigits: 1 })

export function UrgentPlayback({ selected }: { selected: string[] }) {
  const [review, setReview] = useState<{ plan: Preview; selected: string[] } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const status = useQuery({
    queryKey: ['urgent-playback'],
    queryFn: async ({ signal }) => {
      const { data, error: failure, response } = await api.GET('/api/content/urgent/playback', { signal })
      if (!data) throw new Error(messageFor(errorCode(failure, response)))
      return data
    },
    retry: false,
    refetchInterval: 2000,
  })
  const run = status.data?.run

  async function send(body: Pick<Request, 'action'> & Partial<Request>) {
    if (busy) return
    setBusy(true)
    setError('')
    try {
      const { data, error: refusal, response } = await api.POST('/api/content/urgent/playback', {
        body: { selectedIds: null, review: null, runId: null, step: null, ...body },
      })
      if (!data) {
        setError(refusal?.message || messageFor(errorCode(refusal, response)))
      } else if (body.action === 'preview' && data.preview) {
        setReview({ plan: data.preview, selected: body.selectedIds ?? [] })
      } else {
        setReview(null)
      }
      await status.refetch()
    } catch {
      setError('تعذّر الوصول إلى الجسر. تحقّق من حالة التشغيل قبل إعادة الأمر.')
      await status.refetch()
    } finally {
      setBusy(false)
    }
  }

  function confirmStop() {
    if (!run) return
    modals.openConfirmModal({
      title: run.state === 'stop_unconfirmed' ? 'إعادة محاولة إيقاف العواجل' : 'إيقاف دورة العواجل',
      children: <Text>سيطلب الجسر إخراج مشهد الدورة الحالية من الهواء.</Text>,
      labels: { confirm: 'إيقاف الدورة', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: () => void send({ action: 'stop', runId: run.id }),
    })
  }

  return (
    <Paper withBorder px="md" py="sm" radius="md">
      <Stack gap="sm">
        <Group justify="space-between" align="flex-start">
          <Stack gap={2}>
            <Title order={4}>تشغيل العواجل</Title>
            <Text size="sm" c="dimmed">
              {status.isPending ? 'جارٍ قراءة حالة التشغيل…'
                : run ? `الخطوة ${format.format(run.step + 1)} من ${format.format(run.stepCount)}`
                : 'لا توجد دورة نشطة.'}
            </Text>
          </Stack>
          {run ? (
            <Badge color={run.state === 'playing' ? 'red' : 'orange'} variant="light">
              {run.state === 'playing' ? 'قيد العرض' : run.state === 'paused' ? 'متوقفة مؤقتًا' : 'الإيقاف غير مؤكّد'}
            </Badge>
          ) : (
            <Button variant="light" disabled={!status.isSuccess || busy} onClick={() => void send({ action: 'preview', selectedIds: selected })}>
              {selected.length ? `مراجعة المحدّد (${format.format(selected.length)})` : 'مراجعة تشغيل الكل'}
            </Button>
          )}
        </Group>
        {status.isError && <Alert color="orange">{status.error.message}</Alert>}
        {!review && error && <Alert color="red" role="alert">{error}</Alert>}
        {run && (
          <Stack gap="xs">
            {run.current && <Text size="sm" dir="auto"><strong>الحالي</strong> · {run.current}</Text>}
            {run.next && <Text size="sm" c="dimmed" dir="auto"><strong>التالي</strong> · {run.next}</Text>}
            <Group gap="xs">
              {run.state !== 'stop_unconfirmed' && (
                <>
                  <Button variant="default" disabled={busy || !status.isSuccess} onClick={() => void send({ action: run.state === 'paused' ? 'resume' : 'pause', runId: run.id })}>
                    {run.state === 'paused' ? 'استئناف' : 'إيقاف مؤقت'}
                  </Button>
                  <Button variant="default" disabled={busy || !status.isSuccess || run.step + 1 >= run.stepCount} onClick={() => void send({ action: 'skip', runId: run.id, step: run.step })}>
                    العاجل التالي
                  </Button>
                </>
              )}
              <Button color="red" variant="light" disabled={busy || !status.isSuccess} onClick={confirmStop}>
                {run.state === 'stop_unconfirmed' ? 'إعادة محاولة الإيقاف' : 'إيقاف الدورة'}
              </Button>
            </Group>
          </Stack>
        )}
      </Stack>
      <Modal opened={!!review} onClose={() => { if (!busy) { setReview(null); setError('') } }} title="مراجعة دورة العواجل" size="lg">
        {review && (
          <Stack>
            <Text>المدة المتوقعة {format.format(review.plan.totalSeconds)} ثانية · {format.format(review.plan.itemCount)} عاجل</Text>
            {review.plan.replacesGraphic && (
              <Alert color="orange" title="سيُستبدل المشهد الحالي">
                الطبقة {format.format(review.plan.layer)} تعرض الآن {review.plan.graphicName || 'مشهدًا قائمًا'}.
              </Alert>
            )}
            <Stack gap="xs" component="ol" mt={0} mb={0} ps="lg">
              {review.plan.steps.map((step, index) => (
                <li key={index}>
                  <Text size="sm" dir="auto">{step.text}</Text>
                  <Text size="xs" c="dimmed">بداية {format.format(step.startSeconds)} ث · مدة {format.format(step.holdSeconds)} ث</Text>
                </li>
              ))}
            </Stack>
            {review.plan.stepCount > review.plan.steps.length && (
              <Text size="sm" c="dimmed">تظهر أول {format.format(review.plan.steps.length)} خطوة من {format.format(review.plan.stepCount)}.</Text>
            )}
            {review.plan.notes.map((note, index) => <Alert key={index} color="orange">{note}</Alert>)}
            {error && <Alert color="red" role="alert">{error}</Alert>}
            <Group justify="flex-end">
              <Button color="red" loading={busy} disabled={!!run || !status.isSuccess} onClick={() => void send({ action: 'start', review: review.plan.review, selectedIds: review.selected })}>
                تشغيل على الهواء
              </Button>
            </Group>
          </Stack>
        )}
      </Modal>
    </Paper>
  )
}
