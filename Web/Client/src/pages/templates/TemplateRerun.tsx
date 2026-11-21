import { Alert, Button, Group, Modal, PasswordInput, Skeleton, Stack, Table, Text, TextInput } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useQuery } from '@tanstack/react-query'
import { useRef, useState, type FormEvent } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

export type TemplateRerunKind = 'repeat' | 'retry'
type RerunPlan = NonNullable<Schemas['AirRerunPlan']>
type RerunCommand = Schemas['AirRerunCommand']

const titles = { repeat: 'إعادة آخر عرض', retry: 'إعادة محاولة العرض' }
const number = new Intl.NumberFormat('ar')
const rerunErrors: Record<string, string> = {
  rerun_missing: 'لا يوجد عرض أو طلب سابق لهذا الحساب.',
  rerun_stale: 'تغيّر القالب أو المشهد منذ المراجعة. حمّل البيانات الحالية وراجعها من جديد.',
  rerun_invalid: 'راجع القيم المدخلة قبل طلب المعاينة.',
  rerun_required: 'أكمل الحقول الإلزامية.',
  rerun_too_long: 'إحدى القيم تتجاوز طول الحقل المحدّد.',
  rerun_busy: 'يجري تجهيز عرض لهذه الطبقة. أعد المراجعة بعد انتهاء التجهيز.',
  rerun_ambiguous: 'يتعذّر تأكيد المشهد المستهدف في وضع تعدّد المشاهد.',
  rerun_unverified: 'تعذّر التحقق من حالة الطبقة. راجع لوحة الهواء ثم أعد المراجعة.',
  rerun_refused: 'تعذّر تأكيد العرض. تحقّق من حالة الطبقة قبل إرسال طلب آخر.',
}

async function requestRerun(command: Pick<RerunCommand, 'kind' | 'action'> & Partial<RerunCommand>, signal?: AbortSignal) {
  const body: RerunCommand = { variables: null, review: null, ...command }
  const { data, error, response } = await api.POST('/api/air/rerun', { body, signal })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

function displayError(code: string) {
  return rerunErrors[code] ?? messageFor(code)
}

export function TemplateRerun({ kind, onClose }: { kind: TemplateRerunKind; onClose: () => void }) {
  const inspection = useQuery({
    queryKey: ['template-rerun', kind],
    queryFn: async ({ signal }) => {
      const result = await requestRerun({ kind, action: 'inspect' }, signal)
      if (!result.rerun) throw new Error('rerun_missing')
      return result.rerun
    },
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: false,
  })

  if (inspection.data && !inspection.isFetching && !inspection.error) {
    return <RerunEditor key={`${kind}:${inspection.dataUpdatedAt}`} kind={kind} plan={inspection.data}
      onClose={onClose} onReload={() => void inspection.refetch()} />
  }

  return (
    <Modal opened title={titles[kind]} onClose={onClose}>
      <Stack gap="md" dir="rtl">
        {inspection.isFetching ? (
          <Stack gap="xs" aria-label="جارٍ تحميل بيانات العرض"><Skeleton h={22} /><Skeleton h={42} /></Stack>
        ) : inspection.error && (
          <Alert color={inspection.error.message === 'rerun_missing' ? 'gray' : 'orange'} role="alert">
            {displayError(inspection.error.message)}
          </Alert>
        )}
        <Group justify="flex-end">
          <Button variant="default" onClick={onClose}>إغلاق</Button>
          {inspection.error && <Button variant="light" onClick={() => void inspection.refetch()}>إعادة التحميل</Button>}
        </Group>
      </Stack>
    </Modal>
  )
}

function RerunEditor({ kind, plan, onClose, onReload }: {
  kind: TemplateRerunKind
  plan: RerunPlan
  onClose: () => void
  onReload: () => void
}) {
  const [publicValues, setPublicValues] = useState(() => Object.fromEntries(
    plan.fields.filter(field => !field.sensitive).map(field => [field.name, field.value ?? ''] as const),
  ))
  const [review, setReview] = useState<{ plan: RerunPlan; token: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const running = useRef(false)
  // Hold the exact reviewed request only until confirm or return to editing.
  // React Query's mutation cache must not retain these transient credentials.
  const reviewedValues = useRef<Record<string, string> | null>(null)

  function close() {
    if (running.current) return
    reviewedValues.current = null
    onClose()
  }

  async function reviewRequest(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (running.current) return
    const form = new FormData(event.currentTarget)
    const values = Object.fromEntries(plan.fields.flatMap(field => {
      const value = field.sensitive ? String(form.get(field.name) ?? '') : publicValues[field.name] ?? ''
      return value !== (field.sensitive ? '' : field.value ?? '') ? [[field.name, value] as const] : []
    }))
    running.current = true
    setBusy(true)
    setError(null)
    try {
      const result = await requestRerun({ kind, action: 'preview', variables: values })
      if (!result.rerun?.review) throw new Error('rerun_unverified')
      reviewedValues.current = values
      setReview({ plan: result.rerun, token: result.rerun.review })
    } catch (failure) {
      reviewedValues.current = null
      setError(failure instanceof Error ? failure.message : 'unknown')
    } finally {
      running.current = false
      setBusy(false)
    }
  }

  async function confirm() {
    if (running.current || !review || !reviewedValues.current) return
    const values = reviewedValues.current
    reviewedValues.current = null
    running.current = true
    setBusy(true)
    setError(null)
    try {
      const result = await requestRerun({ kind, action: 'start', variables: values, review: review.token })
      notifications.show({
        color: result.sceneConfirmed ? 'teal' : 'orange',
        message: result.sceneConfirmed ? 'تأكّد العرض على الطبقة.' : 'قُبل أمر العرض. تحقّق من المشهد في لوحة الهواء.',
      })
      onClose()
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'unknown')
    } finally {
      running.current = false
      setBusy(false)
    }
  }

  function editAgain() {
    reviewedValues.current = null
    setReview(null)
    setError(null)
  }

  function reload() {
    editAgain()
    onReload()
  }

  return (
    <Modal opened title={review ? 'مراجعة إعادة العرض' : titles[kind]} size="lg" onClose={close}
      withCloseButton={!busy} closeOnEscape={!busy} closeOnClickOutside={!busy}>
      <Stack gap="md" dir="rtl">
        <Group justify="space-between" gap="sm">
          <Text fw={600}><bdi>{(review?.plan ?? plan).key}</bdi></Text>
          <Text size="sm">الطبقة {number.format((review?.plan ?? plan).layer)}</Text>
        </Group>
        {error && (
          <Alert color="orange" role="alert">
            <Stack gap="xs" align="flex-start">
              {displayError(error)}
              {error === 'rerun_stale' && <Button variant="light" size="xs" onClick={reload}>تحميل البيانات الحالية</Button>}
            </Stack>
          </Alert>
        )}
        {review ? (
          <>
            <Text size="sm" c="dimmed">
              {review.plan.autoHideSeconds > 0
                ? `الإخفاء التلقائي بعد ${number.format(review.plan.autoHideSeconds)} ثانية`
                : 'لا يوجد مؤقّت إخفاء لهذا العرض.'}
            </Text>
            {review.plan.replacesGraphic ? (
              <Alert color="orange">
                سيحلّ هذا العرض محلّ {review.plan.graphicName ? <bdi>{review.plan.graphicName}</bdi> : 'المشهد الظاهر حاليًا'}.
              </Alert>
            ) : <Text size="sm" c="dimmed">الطبقة فارغة عند المراجعة.</Text>}
            {!!review.plan.fields.length && (
              <Table withRowBorders aria-label="القيم التي ستُرسل" style={{ overflowWrap: 'anywhere' }}>
                <Table.Thead><Table.Tr><Table.Th scope="col">الحقل</Table.Th><Table.Th scope="col">القيمة</Table.Th></Table.Tr></Table.Thead>
                <Table.Tbody>
                  {review.plan.fields.map(field => (
                    <Table.Tr key={field.name}>
                      <Table.Th scope="row"><bdi>{field.label || field.name}</bdi></Table.Th>
                      <Table.Td>{field.sensitive && field.hasValue ? 'قيمة حسّاسة محجوبة' : <bdi>{field.value || '—'}</bdi>}</Table.Td>
                    </Table.Tr>
                  ))}
                </Table.Tbody>
              </Table>
            )}
            <Group justify="flex-end">
              <Button variant="default" disabled={busy} onClick={editAgain}>رجوع إلى القيم</Button>
              <Button loading={busy} disabled={!!error} onClick={() => void confirm()}>تأكيد العرض</Button>
            </Group>
          </>
        ) : (
          <form onSubmit={reviewRequest}>
            <Stack gap="md">
              {plan.fields.map(field => {
                const label = field.label || field.name
                const description = field.maxLength ? `الحد الأقصى ${number.format(field.maxLength)} حرفًا` : undefined
                return field.sensitive ? (
                  <PasswordInput key={field.name} name={field.name} label={label} description={description}
                    required={field.required} autoComplete="new-password" disabled={busy}
                    visibilityToggleButtonProps={{ 'aria-label': 'إظهار القيمة الحسّاسة أو إخفاؤها' }} />
                ) : <TextInput key={field.name} label={label} description={description} required={field.required}
                  disabled={busy} dir="auto" value={publicValues[field.name] ?? ''}
                  onChange={event => {
                    const value = event.currentTarget.value
                    setPublicValues(current => ({ ...current, [field.name]: value }))
                  }} />
              })}
              <Group justify="flex-end">
                <Button variant="default" disabled={busy} onClick={close}>إلغاء</Button>
                <Button type="submit" loading={busy} disabled={error === 'rerun_stale'}>مراجعة العرض</Button>
              </Group>
            </Stack>
          </form>
        )}
      </Stack>
    </Modal>
  )
}
