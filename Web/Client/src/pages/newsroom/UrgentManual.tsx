import { Alert, Button, Group, Modal, NativeSelect, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import type { Schemas } from '../../api/client'
import { manualKey, sendUrgentManual } from './urgentManualApi'
import { UrgentTimingStepper } from './UrgentTimingStepper'

const format = new Intl.NumberFormat('ar')

export function UrgentManual({ itemId, mode, fields, onClose, onChanged }: {
  itemId: string
  mode: 'direct' | 'timed'
  fields: Schemas['TemplateFieldDto'][]
  onClose: () => void
  onChanged: () => Promise<void>
}) {
  const client = useQueryClient()
  const [choice, setChoice] = useState<string | null>(null)
  const [rehearsal, setRehearsal] = useState(false)
  const [custom, setCustom] = useState(1)
  const [requestedReview, setReview] = useState<Schemas['UrgentManualPreview'] | null>(null)
  const direct = mode === 'direct' && !rehearsal
  const options = useQuery({ queryKey: [...manualKey, 'options', itemId],
    retry: false, queryFn: () => sendUrgentManual({ action: 'options', itemId }) })
  const directReview = useQuery({
    queryKey: ['urgent-manual-direct-review', itemId], enabled: direct, retry: false, gcTime: 0,
    refetchOnMount: 'always', refetchOnWindowFocus: false, refetchOnReconnect: false,
    queryFn: () => sendUrgentManual({ action: 'preview', itemId, autoHideSeconds: 0 }),
  })
  const durations = options.data?.durations?.filter((seconds) => seconds > 0) ?? []
  const durationChoice = choice ?? (durations.length ? String(durations[0]) : 'custom')
  const duration = direct ? 0 : durationChoice === 'custom' ? custom : Number(durationChoice)
  const review = direct ? (directReview.isSuccess && !directReview.isFetching ? directReview.data.preview : null) : requestedReview
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
      if (!answer.rehearsalStarted && answer.sceneConfirmed === false) {
        notifications.show({ color: 'orange', autoClose: false,
          message: 'أُرسل أمر العرض وتعذّر تأكيد ظهور العاجل في Cinegy. تحقّق من الطبقة.' })
      } else if (answer.autoHideFailed) {
        notifications.show({ color: 'orange', autoClose: false,
          message: answer.rehearsalStarted ? `تعذّر تأكيد الإخفاء التلقائي للبروفة. تحقّق من طبقة التجربة${review ? ` ${format.format(review.layer)}` : ''} في Cinegy.`
            : 'أُرسل أمر العرض وتعذّر تأكيد مؤقّت الإخفاء. راقب الطبقة واستخدم الإخفاء عند انتهاء المدة.' })
      } else {
        notifications.show({ color: 'teal', message: answer.rehearsalStarted ? 'بدأت البروفة على طبقة التجربة.' : 'ظهر العاجل على الهواء.' })
      }
      onClose()
      await Promise.all([client.invalidateQueries({ queryKey: manualKey }), client.invalidateQueries({ queryKey: ['urgent-playback'] }), onChanged()])
    },
  })
  const labels = [
    ...durations.map((seconds) => ({ value: String(seconds), label: `${format.format(seconds)} ثانية` })),
    { value: 'custom', label: 'مدة أخرى' },
  ]
  const selectDestination = (next: boolean) => {
    if (rehearsal === next) return
    setRehearsal(next)
    setReview(null)
    send.reset()
  }
  return (
    <Modal opened title={mode === 'direct' ? 'عرض عاجل مباشر' : 'عرض عاجل بمؤقّت'} onClose={() => { if (!send.isPending) onClose() }}>
      <Stack gap="md">
        {direct && directReview.isFetching && <Text size="sm" role="status">جارٍ مراجعة العرض المباشر…</Text>}
        {direct && directReview.error && <Alert color="orange" role="alert">{directReview.error.message}</Alert>}
        {!direct && options.isPending && <Text size="sm" role="status">جارٍ قراءة مدد العرض…</Text>}
        {!direct && options.error && <Alert color="orange" role="alert">{options.error.message}</Alert>}
        {options.data?.canRehearse && <Group grow gap="xs" role="group" aria-label="وجهة عرض العاجل">
          <Button type="button" variant={rehearsal ? 'default' : 'light'} aria-pressed={!rehearsal}
            disabled={send.isPending} onClick={() => selectDestination(false)}>البث</Button>
          <Button type="button" variant={rehearsal ? 'light' : 'default'} aria-pressed={rehearsal}
            disabled={send.isPending} onClick={() => selectDestination(true)}>البروفة</Button>
        </Group>}
        {mode === 'timed' && options.data && !rehearsal && <NativeSelect label="مدة العرض" data={labels} value={durationChoice} disabled={send.isPending}
          onChange={(event) => { setChoice(event.currentTarget.value); setReview(null); send.reset() }} />}
        {mode === 'timed' && options.data && !rehearsal && durationChoice === 'custom' && <Stack gap="xs">
          <Text size="sm" aria-live="polite">المدة · {format.format(custom)} ثانية</Text>
          <UrgentTimingStepper label="مدة العرض" value={custom} minimum={1} maximum={86400} disabled={send.isPending}
            onChange={(value) => { setCustom(value); setReview(null); send.reset() }} />
        </Stack>}
        {review && <Stack gap="xs">
          {fields.map((field) => review.values[field.name] && <div key={field.name}>
            <Text size="xs" c="dimmed">{field.label}</Text>
            <Text size="sm" dir="rtl">{review.values[field.name]}</Text>
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
          {direct ? <Button variant="default" disabled={send.isPending || directReview.isFetching}
            onClick={() => { send.reset(); void directReview.refetch() }}>إعادة المراجعة</Button>
            : <Button variant="default" disabled={!options.data || send.isPending}
              onClick={() => { setReview(null); send.mutate(undefined) }}>{rehearsal ? 'مراجعة البروفة' : 'مراجعة العرض'}</Button>}
          {review && <Button color={review.rehearsal ? 'blue' : 'red'} disabled={send.isPending || !!send.error} loading={send.isPending}
            onClick={() => send.mutate(review.review)}>{review.rehearsal ? 'بدء البروفة' : 'عرض على الهواء'}</Button>}
        </Group>
      </Stack>
    </Modal>
  )
}
