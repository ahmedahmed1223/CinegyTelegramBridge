import { Alert, Button, Group, Modal, NativeSelect, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import type { Schemas } from '../../api/client'
import { manualKey, sendUrgentManual } from './urgentManualApi'
import { UrgentTimingStepper } from './UrgentTimingStepper'

const format = new Intl.NumberFormat('ar')

export function UrgentManual({ itemId, fields, onClose, onChanged }: {
  itemId: string
  fields: Schemas['TemplateFieldDto'][]
  onClose: () => void
  onChanged: () => Promise<void>
}) {
  const client = useQueryClient()
  const [choice, setChoice] = useState('0')
  const [rehearsal, setRehearsal] = useState(false)
  const [custom, setCustom] = useState(1)
  const [review, setReview] = useState<Schemas['UrgentManualPreview'] | null>(null)
  const options = useQuery({ queryKey: [...manualKey, 'options', itemId],
    retry: false, queryFn: () => sendUrgentManual({ action: 'options', itemId }) })
  const duration = choice === 'custom' ? custom : Number(choice)
  const send = useMutation({
    mutationFn: (token?: string) => sendUrgentManual({
      action: rehearsal ? (token ? 'rehearse' : 'rehearse-preview') : (token ? 'show' : 'preview'),
      itemId, autoHideSeconds: rehearsal ? null : duration, review: token,
    }),
    onSuccess: async (answer) => {
      if (answer.preview) {
        setReview(answer.preview)
        return
      }
      if (answer.autoHideFailed) {
        notifications.show({ color: 'orange', autoClose: false,
          message: answer.rehearsalStarted ? `تعذّر تأكيد الإخفاء التلقائي للبروفة. تحقّق من طبقة التجربة${review ? ` ${format.format(review.layer)}` : ''} في Cinegy.`
            : 'أُرسل أمر العرض وتعذّر تأكيد مؤقّت الإخفاء. راقب الطبقة واستخدم الإخفاء عند انتهاء المدة.' })
      } else {
        notifications.show({ color: 'teal', message: answer.rehearsalStarted ? 'بدأت البروفة على طبقة التجربة.' : 'أُرسل أمر عرض العاجل.' })
      }
      onClose()
      await Promise.all([client.invalidateQueries({ queryKey: manualKey }), client.invalidateQueries({ queryKey: ['urgent-playback'] }), onChanged()])
    },
  })
  const labels = [
    { value: '0', label: 'عرض عادي' },
    ...(options.data?.durations ?? []).map((seconds) => ({ value: String(seconds), label: `${format.format(seconds)} ثانية` })),
    { value: 'custom', label: 'مدة أخرى' },
  ]
  const selectDestination = (next: boolean) => {
    if (rehearsal === next) return
    setRehearsal(next)
    setReview(null)
    send.reset()
  }
  return (
    <Modal opened title="عرض عاجل منفرد" onClose={() => { if (!send.isPending) onClose() }}>
      <Stack gap="md">
        {options.isPending && <Text size="sm" role="status">جارٍ قراءة مدد العرض…</Text>}
        {options.error && <Alert color="orange" role="alert">{options.error.message}</Alert>}
        {options.data?.canRehearse && <Group grow gap="xs" role="group" aria-label="وجهة عرض العاجل">
          <Button type="button" variant={rehearsal ? 'default' : 'light'} aria-pressed={!rehearsal}
            disabled={send.isPending} onClick={() => selectDestination(false)}>البث</Button>
          <Button type="button" variant={rehearsal ? 'light' : 'default'} aria-pressed={rehearsal}
            disabled={send.isPending} onClick={() => selectDestination(true)}>البروفة</Button>
        </Group>}
        {options.data && !rehearsal && <NativeSelect label="مدة العرض" data={labels} value={choice} disabled={send.isPending}
          onChange={(event) => { setChoice(event.currentTarget.value); setReview(null); send.reset() }} />}
        {!rehearsal && choice === 'custom' && <Stack gap="xs">
          <Text size="sm" aria-live="polite">المدة · {format.format(custom)} ثانية</Text>
          <UrgentTimingStepper label="مدة العرض" value={custom} minimum={1} maximum={86400} disabled={send.isPending}
            onChange={(value) => { setCustom(value); setReview(null); send.reset() }} />
        </Stack>}
        {review && <Stack gap="xs">
          {fields.map((field) => review.values[field.name] && <div key={field.name}>
            <Text size="xs" c="dimmed">{field.label}</Text>
            <Text size="sm" dir="auto">{review.values[field.name]}</Text>
          </div>)}
          <Alert color={review.rehearsal ? 'blue' : 'orange'}>
            <Text size="sm">{review.rehearsal ? 'طبقة التجربة' : 'الطبقة'} {format.format(review.layer)}. {review.autoHideSeconds > 0
              ? `إخفاء بعد ${format.format(review.autoHideSeconds)} ثانية.` : 'يبقى العاجل معروضًا حتى يُخفى.'}</Text>
            {review.replacesGraphic && <Text size="sm">سيستبدل الرسم الحالي{review.graphicName ? ` «${review.graphicName}»` : ''}.</Text>}
            {review.stopsRun && <Text size="sm">سيتوقّف تشغيل دورة العواجل الحالية.</Text>}
            {review.stopsBulletin && <Text size="sm">سيخرج الموجز الجاري من الهواء.</Text>}
          </Alert>
        </Stack>}
        {send.error && <Alert color="orange" role="alert">{send.error.message}</Alert>}
        <Group justify="flex-end" gap="xs">
          <Button variant="default" disabled={!options.data || send.isPending}
            onClick={() => { setReview(null); send.mutate(undefined) }}>{rehearsal ? 'مراجعة البروفة' : 'مراجعة العرض'}</Button>
          {review && <Button color={review.rehearsal ? 'blue' : 'red'} disabled={send.isPending || !!send.error} loading={send.isPending}
            onClick={() => send.mutate(review.review)}>{review.rehearsal ? 'بدء البروفة' : 'عرض على الهواء'}</Button>}
        </Group>
      </Stack>
    </Modal>
  )
}
