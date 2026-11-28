import { Alert, Button, Checkbox, Group, Modal, Skeleton, Stack, Table, Text, Textarea } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Command = Schemas['AirTextCommand']
type Plan = NonNullable<Schemas['AirTextPlan']>
type Review = { plan: Plan; token: string; values: Record<string, string> }

const number = new Intl.NumberFormat('ar')
const textErrors: Record<string, string> = {
  live_text_invalid: 'اختر حقولًا نصية صالحة للتصحيح.',
  live_text_required: 'لا يمكن ترك أحد الحقول المختارة فارغًا.',
  live_text_too_long: 'إحدى القيم تتجاوز الحدّ الأقصى للحقل.',
  live_text_stale: 'تغيّر المشهد أو النص منذ المراجعة. حمّل حالة الطبقة الحالية من جديد.',
  live_text_managed: 'يدير الجسر هذا المشهد ضمن تشغيل آخر أو على طبقة غير قابلة للتصحيح المباشر.',
  live_text_busy: 'يجري تجهيز عرض لهذه الطبقة.',
  live_text_no_fields: 'لا تتوفّر حقول نصية قابلة للتصحيح في هذا المشهد.',
  live_text_conflict: 'تعذّر التأكد من أن المشهد المطلوب وحده سيستقبل هذا النص.',
  live_text_unverified: 'تعذّر التحقق من المشهد الحالي وحقوله. راجع حالة الطبقة في لوحة الهواء.',
  live_text_refused: 'تعذّر تأكيد التصحيح. تحقّق من حالة الطبقة قبل إعادة المحاولة.',
}

async function requestText(layer: number, command: Pick<Command, 'action'> & Partial<Command>, signal?: AbortSignal) {
  const body: Command = { values: null, review: null, ...command }
  const { data, error, response } = await api.POST('/api/air/layers/{layer}/text', {
    params: { path: { layer } }, body, signal,
  })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

export function LayerTextModal({ layer, expectedTemplateKey, onClose }: {
  layer: number
  expectedTemplateKey?: string
  onClose: () => void
}) {
  const inspection = useQuery({
    queryKey: ['air-live-text', layer, expectedTemplateKey],
    queryFn: async ({ signal }) => {
      const result = await requestText(layer, { action: 'inspect' }, signal)
      if (!result.plan) throw new Error('live_text_unverified')
      if (expectedTemplateKey && result.plan.templateKey !== expectedTemplateKey) throw new Error('live_text_stale')
      return result.plan
    },
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: false,
  })
  if (inspection.data && !inspection.isFetching && !inspection.error) {
    return <LayerTextEditor key={inspection.dataUpdatedAt} plan={inspection.data} onClose={onClose}
      onReload={() => void inspection.refetch()} />
  }

  return (
    <Modal opened title="تصحيح النص على الهواء" onClose={onClose}>
      <Stack gap="md" dir="rtl">
        {inspection.isFetching ? <Skeleton h={80} aria-label="جارٍ التحقق من المشهد" /> : inspection.error && (
          <Alert role="alert" color="orange">{textErrors[inspection.error.message] ?? messageFor(inspection.error.message)}</Alert>
        )}
        <Group justify="flex-end">
          <Button variant="default" onClick={onClose}>إغلاق</Button>
          {inspection.error && <Button variant="light" onClick={() => void inspection.refetch()}>إعادة الفحص</Button>}
        </Group>
      </Stack>
    </Modal>
  )
}

function LayerTextEditor({ plan, onClose, onReload }: { plan: Plan; onClose: () => void; onReload: () => void }) {
  const client = useQueryClient()
  const [selected, setSelected] = useState<string[]>([])
  const [values, setValues] = useState<Record<string, string>>({})
  const [review, setReview] = useState<Review | null>(null)
  const preview = useMutation({
    mutationFn: async (patch: Record<string, string>) => {
      const result = (await requestText(plan.layer, { action: 'preview', values: patch })).plan
      if (!result?.review || result.templateKey !== plan.templateKey) throw new Error('live_text_stale')
      return { plan: result, token: result.review, values: patch }
    },
    onSuccess: setReview,
  })
  const apply = useMutation({
    mutationFn: async (decision: Review) => {
      const result = await requestText(plan.layer, { action: 'apply', review: decision.token, values: decision.values })
      if (!result.accepted) throw new Error('live_text_refused')
    },
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: ['shared-template-text'] })
      notifications.show({ color: 'teal', message: 'قُبل تصحيح النص. تحقّق من ظهوره على الهواء.' })
      onClose()
    },
  })
  const busy = preview.isPending || apply.isPending
  const error = apply.error ?? preview.error

  function reviewChanges(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (busy || !selected.length) return
    preview.mutate(Object.fromEntries(selected.map(name => [name, Object.hasOwn(values, name) ? values[name] : ''])))
  }

  function editAgain() {
    setReview(null)
    preview.reset()
    apply.reset()
  }

  return (
    <Modal opened title={review ? 'مراجعة تصحيح النص' : 'تصحيح النص على الهواء'} size="lg"
      onClose={() => { if (!busy) onClose() }} withCloseButton={!busy} closeOnEscape={!busy} closeOnClickOutside={!busy}>
      <Stack gap="md" dir="rtl">
        <Group justify="space-between" gap="sm">
          <Text fw={600}><bdi>{(review?.plan ?? plan).templateKey}</bdi></Text>
          <Text size="sm">الطبقة {number.format((review?.plan ?? plan).layer)}</Text>
        </Group>
        {error && (
          <Alert role="alert" color="orange">
            <Stack gap="xs" align="flex-start">
              {textErrors[error.message] ?? messageFor(error.message)}
              {error.message === 'live_text_stale' && <Button size="xs" variant="light" onClick={onReload}>تحميل المشهد الحالي</Button>}
            </Stack>
          </Alert>
        )}
        {review ? (
          <>
            <Table withRowBorders aria-label="الحقول المختارة للتصحيح" style={{ overflowWrap: 'anywhere' }}>
              <Table.Thead><Table.Tr><Table.Th scope="col">الحقل</Table.Th><Table.Th scope="col">القيمة الجديدة</Table.Th></Table.Tr></Table.Thead>
              <Table.Tbody>
                {review.plan.changes?.map(change => (
                  <Table.Tr key={change.name}>
                    <Table.Th scope="row"><bdi>{change.label || change.name}</bdi></Table.Th>
                    <Table.Td style={{ whiteSpace: 'pre-wrap' }}>{change.value ? <bdi>{change.value}</bdi> : 'إفراغ الحقل'}</Table.Td>
                  </Table.Tr>
                ))}
              </Table.Tbody>
            </Table>
            <Group justify="flex-end">
              <Button variant="default" disabled={busy} onClick={editAgain}>رجوع إلى الحقول</Button>
              <Button color="orange" loading={apply.isPending} disabled={!!apply.error}
                onClick={() => apply.mutate(review)}>تأكيد التصحيح على الهواء</Button>
            </Group>
          </>
        ) : (
          <form onSubmit={reviewChanges}>
            <Stack gap="md">
              {plan.fields.map(field => (
                <Stack gap={6} key={field.name}>
                  <Checkbox label={<bdi>{field.label || field.name}</bdi>} checked={selected.includes(field.name)} disabled={busy}
                    onChange={event => {
                      const checked = event.currentTarget.checked
                      setSelected(fields => checked ? [...fields, field.name] : fields.filter(name => name !== field.name))
                      // The bridge appends an ellipsis when the current value
                      // is too long to return in full. Keep that as a hint.
                      if (checked && field.lastKnownValue.length <= 160) {
                        setValues(previous => Object.hasOwn(previous, field.name)
                          ? previous : { ...previous, [field.name]: field.lastKnownValue })
                      }
                    }} />
                  {selected.includes(field.name) && <>
                    {field.lastKnownValue && <Text size="xs" c="dimmed">آخر قيمة لدى الجسر <bdi>{field.lastKnownValue}</bdi></Text>}
                    <Textarea label={`القيمة الجديدة لحقل ${field.label || field.name}`} dir="rtl" autosize minRows={2} maxRows={5}
                      required={field.required} disabled={busy} value={Object.hasOwn(values, field.name) ? values[field.name] : ''}
                      description={field.maxLength ? `الحد الأقصى ${number.format(field.maxLength)} حرفًا` : undefined}
                      onChange={event => {
                        const value = event.currentTarget.value
                        setValues(current => ({ ...current, [field.name]: value }))
                      }} />
                  </>}
                </Stack>
              ))}
              <Group justify="flex-end">
                <Button variant="default" disabled={busy} onClick={onClose}>إلغاء</Button>
                <Button type="submit" loading={preview.isPending} disabled={!selected.length || error?.message === 'live_text_stale'}>مراجعة التصحيح</Button>
              </Group>
            </Stack>
          </form>
        )}
      </Stack>
    </Modal>
  )
}
