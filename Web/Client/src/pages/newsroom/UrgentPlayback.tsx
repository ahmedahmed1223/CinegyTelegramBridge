import { Alert, Badge, Button, Group, Modal, NativeSelect, Paper, Stack, Text, Title } from '@mantine/core'
import { modals } from '@mantine/modals'
import { IconPlayerPlay, IconPlayerStop } from '@tabler/icons-react'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Request = Schemas['UrgentPlaybackRequest']
type Preview = Schemas['UrgentRunPreview']
const format = new Intl.NumberFormat('ar', { maximumFractionDigits: 1 })
const sessionModes = [
  { value: '', label: 'حسب إعدادات التوقيت' },
  { value: 'text', label: 'تحديث النص' },
  { value: 'exit', label: 'خروج قبل الخبر' },
  { value: 'auto_hide', label: 'إخفاء بعد الخبر' },
]

export function UrgentPlayback({ selected, hasRows = true, onStarted }: { selected: string[]; hasRows?: boolean; onStarted: (ids: string[]) => void }) {
  const [review, setReview] = useState<{ plan: Preview; selected: string[]; mode: string | null } | null>(null)
  const [mode, setMode] = useState('')
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
        body: { selectedIds: null, review: null, runId: null, step: null, mode: null, ...body },
      })
      if (!data) {
        const code = errorCode(refusal, response)
        setError(code === 'urgent_stale' && body.action.endsWith('-selected')
          ? 'تغيّر تحديد العواجل. اختر الصفوف وراجعها من جديد.'
          : refusal?.message || messageFor(code))
        if (code === 'urgent_stale') setReview(null)
      } else if ((body.action === 'preview' || body.action === 'preview-selected') && data.preview) {
        setReview({ plan: data.preview, selected: body.selectedIds ?? [], mode: body.mode ?? null })
        return
      } else {
        if (body.action === 'start-selected' && data.run && body.selectedIds?.length) onStarted(body.selectedIds)
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

  function closeReview() {
    if (busy) return
    setReview(null)
    setError('')
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
                : status.isError ? 'حالة التشغيل غير مؤكّدة.' : 'لا توجد دورة نشطة.'}
            </Text>
          </Stack>
          {run && (
            <Badge color={run.state === 'playing' ? 'red' : 'orange'} variant="light">
              {run.state === 'playing' ? 'قيد العرض' : run.state === 'paused' ? 'متوقفة مؤقتًا' : 'الإيقاف غير مؤكّد'}
            </Badge>
          )}
        </Group>
        {status.isError && <Alert color="orange" role="alert">
          <Group justify="space-between">
            <Text size="sm">{status.error.message}</Text>
            <Button variant="subtle" size="compact-sm" onClick={() => void status.refetch()}>إعادة قراءة الحالة</Button>
          </Group>
        </Alert>}
        {!review && error && <Alert color="red" role="alert">{error}</Alert>}
        {!run && (
          <Stack gap="xs" align="flex-start">
            <NativeSelect label="نمط هذه الدورة" data={sessionModes} value={mode} disabled={!status.isSuccess || busy || !hasRows}
              onChange={(event) => setMode(event.currentTarget.value)} />
            <Group gap="xs">
              <Button variant="light" leftSection={<IconPlayerPlay size={17} aria-hidden />}
                disabled={!status.isSuccess || busy || !hasRows} onClick={() => void send({ action: 'preview', selectedIds: [], mode: mode || null })}>
                تشغيل الكل
              </Button>
              <Button variant="default" disabled={!status.isSuccess || busy || !hasRows || !selected.length}
                onClick={() => void send({ action: 'preview-selected', selectedIds: [...selected], mode: mode || null })}>
                تشغيل المحدد{selected.length > 0 && ` (${format.format(selected.length)})`}
              </Button>
            </Group>
            {busy && !review && <Text size="sm" c="dimmed" role="status">جارٍ إعداد المعاينة…</Text>}
          </Stack>
        )}
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
              <Button color="red" variant="light" leftSection={<IconPlayerStop size={17} />} disabled={busy || !status.isSuccess} onClick={confirmStop}>
                {run.state === 'stop_unconfirmed' ? 'إعادة محاولة الإيقاف' : 'إيقاف الدورة وإخفاء العاجل'}
              </Button>
            </Group>
          </Stack>
        )}
      </Stack>
      <Modal opened={!!review} onClose={closeReview}
        title={review?.selected.length ? 'مراجعة تشغيل المحدد' : 'مراجعة تشغيل الكل'} size="lg">
        {review && (
          <Stack>
            <Text>المدة المتوقعة {format.format(review.plan.totalSeconds)} ثانية · {format.format(review.plan.itemCount)} عاجل</Text>
            <Text size="sm" c="dimmed">
              نمط الدورة · {sessionModes.find((option) => option.value === (review.mode ?? ''))?.label}. يُطبّق نمط الصف إذا كان محدّدًا في توقيته.
            </Text>
            {review.plan.replacesGraphic && (
              <Alert color="orange" title="سيُستبدل المشهد الحالي">
                الطبقة {format.format(review.plan.layer)} تعرض الآن {review.plan.graphicName || 'مشهدًا قائمًا'}.
              </Alert>
            )}
            {review.plan.headlines && <Stack gap="xs">
              <Text fw={600}>{review.selected.length ? 'العواجل المختارة' : 'عواجل الدورة'}</Text>
              <Stack gap="xs" component="ol" aria-label="عناوين المعاينة" mt={0} mb={0} ps="lg">
                {review.plan.headlines.map((text, index) => <li key={index}><Text size="sm" dir="auto">{text}</Text></li>)}
              </Stack>
              {review.plan.itemCount > review.plan.headlines.length && (
                <Text size="sm" c="dimmed">تظهر أول {format.format(review.plan.headlines.length)} عنوانًا من {format.format(review.plan.itemCount)}.</Text>
              )}
            </Stack>}
            <details open={!review.plan.headlines}>
              <Text component="summary" size="sm" fw={600}>
                التوقيت والتكرار ({format.format(review.plan.stepCount)} خطوة عرض)
              </Text>
              <Stack gap="xs" component="ol" mt="xs" mb={0} ps="lg">
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
            </details>
            {review.plan.notes.map((note, index) => <Alert key={index} color="orange">{note}</Alert>)}
            {error && <Alert color="red" role="alert">{error}</Alert>}
            <Group justify="flex-end">
              <Button variant="default" disabled={busy} onClick={closeReview}>العودة</Button>
              <Button color="red" loading={busy} disabled={!!run || !status.isSuccess}
                onClick={() => void send({ action: review.selected.length ? 'start-selected' : 'start', review: review.plan.review, selectedIds: review.selected, mode: review.mode })}>
                تشغيل على الهواء
              </Button>
            </Group>
          </Stack>
        )}
      </Modal>
    </Paper>
  )
}
