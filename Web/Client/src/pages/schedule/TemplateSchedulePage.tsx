import {
  Alert, Button, Group, Modal, NumberInput, Pagination, Paper, SegmentedControl,
  Select, SimpleGrid, Skeleton, Stack, Table, Text, Textarea, TextInput, Title,
} from '@mantine/core'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { getTemplates } from '../../api/air'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type SchedulePage = Schemas['TemplateSchedulePage']
type ScheduleItem = Schemas['PendingTemplateSchedule']
type ScheduleCommand = Schemas['TemplateScheduleReviewCommand']
type Recurrence = 'once' | 'daily' | 'weekly'

const scheduleKey = ['template-schedule'] as const
const recurrenceLabels: Record<Recurrence, string> = { once: 'مرة واحدة', daily: 'يوميًا', weekly: 'أسبوعيًا' }
const recurrenceOptions = Object.entries(recurrenceLabels).map(([value, label]) => ({ value, label }))
const scheduleMessages: Readonly<Record<string, string>> = {
  schedule_invalid: 'راجع بيانات الموعد وحدّد وقت العرض.',
  schedule_invalid_time: 'أدخل موعدًا مستقبليًا صالحًا بتوقيت المحطة.',
  schedule_invalid_end: 'اختر تاريخ انتهاء يوافق يوم العرض الأول أو يليه.',
  schedule_invalid_fields: 'تحقّق من الحقول المطلوبة وحدود طول النص.',
  schedule_template_unavailable: 'القالب غير متاح للجدولة. حدّث قائمة القوالب واختر قالبًا متاحًا.',
  schedule_maintenance: 'الجدولة غير متاحة خلال فترة الصيانة.',
  schedule_clock: 'تعذّر التحقق من ساعة المحطة.',
  schedule_stale: 'تغيّر الموعد أو القالب أو المواعيد المتعارضة، أو انتهت صلاحية المراجعة. راجع الموعد مجددًا.',
  schedule_save_failed: 'تعذّر حفظ الموعد. أعد المراجعة قبل المحاولة مجددًا.',
}

function scheduleMessage(error: Error) {
  return scheduleMessages[error.message] ?? messageFor(error.message)
}

function ScheduleTable({ items, label }: { items: ScheduleItem[]; label: string }) {
  return (
    <Table.ScrollContainer minWidth={560} type="native" tabIndex={0} aria-label={label}>
      <Table verticalSpacing="sm" aria-label={label}>
        <Table.Thead>
          <Table.Tr>
            <Table.Th scope="col">القالب</Table.Th>
            <Table.Th scope="col">الطبقة</Table.Th>
            <Table.Th scope="col">موعد المحطة</Table.Th>
            <Table.Th scope="col">التكرار</Table.Th>
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {items.map((item) => (
            <Table.Tr key={item.id}>
              <Table.Td><bdi dir="auto">{item.key}</bdi></Table.Td>
              <Table.Td className="cgb-mono">{item.layer || '—'}</Table.Td>
              <Table.Td>
                <Text size="sm" component="div"><bdi dir="ltr">{item.stationTime}</bdi></Text>
                <Text size="xs" c="dimmed" component="div"><bdi dir="ltr">{item.stationTimeZone}</bdi></Text>
              </Table.Td>
              <Table.Td>
                {recurrenceOptions.find((option) => option.value === item.recurrence)?.label ?? item.recurrence}
                {item.recurrenceUntil && <Text size="xs" c="dimmed">حتى <bdi dir="ltr">{item.recurrenceUntil}</bdi></Text>}
              </Table.Td>
            </Table.Tr>
          ))}
        </Table.Tbody>
      </Table>
    </Table.ScrollContainer>
  )
}

function ScheduleDialog({ stationTimeZone, onClose, onSaved }: {
  stationTimeZone: string
  onClose: () => void
  onSaved: (result: SchedulePage) => void
}) {
  const [templateKey, setTemplateKey] = useState<string | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [timeMode, setTimeMode] = useState<'station' | 'relative'>('station')
  const [stationInput, setStationInput] = useState('')
  const [minutes, setMinutes] = useState<number | string>(15)
  const [recurrence, setRecurrence] = useState<Recurrence>('once')
  const [until, setUntil] = useState('')
  const [inputError, setInputError] = useState('')

  const templates = useQuery({ queryKey: ['templates'], queryFn: getTemplates })
  const template = templates.data?.find((item) => item.key === templateKey && !item.disabled)
  const choices = (templates.data ?? []).filter((item) => !item.disabled).map((item) => ({
    value: item.key, label: item.name === item.key ? item.name : `${item.name} · ${item.key}`,
  }))

  const preview = useMutation({
    gcTime: 0,
    mutationFn: async (body: ScheduleCommand) => {
      const { data, error, response } = await api.POST('/api/schedule/templates/review', { body })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const confirm = useMutation({
    mutationFn: async (review: string) => {
      const { data, error, response } = await api.POST('/api/schedule/templates/confirm', { body: { review } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: onSaved,
  })
  const review = preview.data
  const busy = preview.isPending || confirm.isPending
  const error = review ? confirm.error : (preview.error ?? templates.error)

  function requestReview(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!template || busy) return
    setInputError('')
    let time = stationInput.replace('T', ' ')
    if (timeMode === 'relative') {
      if (typeof minutes !== 'number' || !Number.isInteger(minutes) || minutes < 1 || minutes > 9999) {
        setInputError('أدخل عددًا صحيحًا من الدقائق بين 1 و9999.')
        return
      }
      time = `+${minutes}`
    }
    // datetime-local supplies calendar parts. The bridge interprets them in
    // station time even when this browser is in a different time zone.
    preview.mutate({
      key: template.key,
      time,
      recurrence,
      recurrenceUntil: recurrence !== 'once' && until ? until : null,
      variables: values,
    })
  }

  function backToForm() {
    preview.reset()
    confirm.reset()
  }

  return (
    <Modal opened onClose={() => { if (!busy) onClose() }} closeOnEscape={!busy} closeOnClickOutside={!busy}
      closeButtonProps={{ 'aria-label': 'إغلاق الجدولة', disabled: busy }} size="lg"
      title={review ? 'مراجعة موعد العرض' : 'جدولة عرض قالب'}>
      <Stack gap="md">
        {inputError && <Alert color="orange" role="alert">{inputError}</Alert>}
        {error && <Alert color="orange" role="alert">{scheduleMessage(error)}</Alert>}
        {review ? (
          <>
            <Paper p="md" withBorder>
              <Stack gap={4}>
                <Text fw={600} dir="auto">{review.key}</Text>
                <Text size="sm">الطبقة {review.layer} · {recurrenceOptions.find((option) => option.value === review.recurrence)?.label ?? review.recurrence}</Text>
                <Text size="sm">موعد المحطة <bdi dir="ltr">{review.stationTime}</bdi> · <bdi dir="ltr">{review.stationTimeZone}</bdi></Text>
                {review.recurrenceUntil && <Text size="sm">يتكرر حتى <bdi dir="ltr">{review.recurrenceUntil}</bdi></Text>}
              </Stack>
            </Paper>
            {review.fields.length > 0 && <Stack gap={6}>
              {review.fields.map((field) => (
                <Text size="sm" key={field.name} style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
                  <Text component="span" fw={600} inherit><bdi dir="auto">{field.label}</bdi></Text>
                  {' · '}<bdi dir="auto">{field.sensitive ? 'مخفي' : (field.value || 'فارغ')}</bdi>
                </Text>
              ))}
            </Stack>}
            {review.conflictCount > 0 && <Alert color="orange" title="تعارض محتمل على الطبقة" role="status">
              <Stack gap="xs">
                <Text size="sm">مواعيد قريبة تستخدم الطبقة نفسها. راجع التوقيت قبل الحفظ.</Text>
                <ScheduleTable items={review.conflicts} label="المواعيد المتعارضة" />
                {review.conflictCount > review.conflicts.length &&
                  <Text size="xs">مواعيد متعارضة إضافية · {review.conflictCount - review.conflicts.length}</Text>}
              </Stack>
            </Alert>}
            <Group justify="flex-end">
              <Button variant="default" disabled={busy} onClick={backToForm}>العودة إلى الإدخال</Button>
              <Button loading={confirm.isPending} disabled={busy || confirm.isError} onClick={() => confirm.mutate(review.review)}>حفظ الموعد</Button>
            </Group>
          </>
        ) : (
          <form onSubmit={requestReview}>
            <Stack gap="md">
              {templates.isPending ? <Skeleton h={60} aria-label="جارٍ تحميل القوالب" /> :
                <Select label="القالب" placeholder="اختر قالبًا" searchable allowDeselect={false}
                  nothingFoundMessage="لا توجد قوالب مطابقة" data={choices} value={templateKey} required disabled={busy}
                  onChange={(value) => { setTemplateKey(value); setValues({}); preview.reset() }} />}
              {template?.fields.map((field) => {
                const props = {
                  label: field.label || field.name,
                  description: field.maxLength ? `الحد الأقصى ${field.maxLength} حرفًا` : undefined,
                  value: Object.hasOwn(values, field.name) ? values[field.name] : '',
                  required: field.required,
                  disabled: busy,
                  onChange: (event: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
                    const value = event.currentTarget.value
                    setValues((previous) => ({ ...previous, [field.name]: value }))
                  },
                }
                return field.sensitive
                  ? <TextInput key={field.name} type="password" autoComplete="off" {...props} />
                  : <Textarea key={field.name} dir="auto" autosize minRows={2} maxRows={5} {...props} />
              })}
              <SegmentedControl fullWidth aria-label="طريقة تحديد الموعد" value={timeMode} disabled={busy}
                data={[{ value: 'station', label: 'موعد محدّد' }, { value: 'relative', label: 'بعد دقائق' }]}
                onChange={(value) => { setTimeMode(value === 'relative' ? 'relative' : 'station'); setInputError('') }} />
              {timeMode === 'station' ?
                <TextInput label="التاريخ والوقت بتوقيت المحطة" description={<bdi dir="ltr">{stationTimeZone}</bdi>}
                  type="datetime-local" dir="ltr" value={stationInput} required disabled={busy} onChange={(event) => setStationInput(event.currentTarget.value)} /> :
                <NumberInput label="عدد الدقائق من الآن" value={minutes} onChange={(value) => { setMinutes(value); setInputError('') }}
                  min={1} max={9999} allowDecimal={false} allowNegative={false} clampBehavior="none" required disabled={busy} />}
              <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
                <Select label="التكرار" data={recurrenceOptions} value={recurrence} allowDeselect={false} disabled={busy}
                  onChange={(value) => setRecurrence(value === 'daily' || value === 'weekly' ? value : 'once')} />
                {recurrence !== 'once' && <TextInput label="نهاية التكرار" description="اختياري"
                  type="date" dir="ltr" value={until} disabled={busy} onChange={(event) => setUntil(event.currentTarget.value)} />}
              </SimpleGrid>
              <Group justify="flex-end">
                <Button variant="default" disabled={busy} onClick={onClose}>إلغاء</Button>
                <Button type="submit" loading={preview.isPending} disabled={!template || busy}>مراجعة الموعد</Button>
              </Group>
            </Stack>
          </form>
        )}
      </Stack>
    </Modal>
  )
}

export function TemplateSchedulePage() {
  const [page, setPage] = useState(0)
  const [editing, setEditing] = useState(false)
  const [saved, setSaved] = useState(false)
  const queryClient = useQueryClient()
  const schedules = useQuery({
    queryKey: [...scheduleKey, page],
    retry: false,
    refetchInterval: 10_000,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/schedule/templates', { params: { query: { page } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const schedule = schedules.data

  function finish(result: SchedulePage) {
    setEditing(false)
    setSaved(true)
    setPage(result.page)
    queryClient.setQueryData([...scheduleKey, result.page], result)
    void queryClient.invalidateQueries({ queryKey: scheduleKey })
  }

  return (
    <Stack gap="lg" dir="rtl">
      <Group justify="space-between" align="flex-start">
        <Stack gap={4}>
          <Title order={2}>جدولة القوالب</Title>
          {schedule?.clockValid && <Text size="sm" c="dimmed">
            توقيت المحطة <bdi dir="ltr">{schedule.stationTime}</bdi> · <bdi dir="ltr">{schedule.stationTimeZone}</bdi>
          </Text>}
        </Stack>
        <Button disabled={!schedule?.clockValid || schedules.isError} onClick={() => { setSaved(false); setEditing(true) }}>إضافة موعد</Button>
      </Group>
      {saved && <Text size="sm" role="status">حُفظ موعد القالب.</Text>}
      {schedules.isError && <Alert color="orange" role="alert">
        <Group justify="space-between">
          <Text size="sm">{scheduleMessage(schedules.error)}</Text>
          <Button variant="subtle" size="compact-sm" onClick={() => void schedules.refetch()}>إعادة التحميل</Button>
        </Group>
      </Alert>}
      {schedule && !schedule.clockValid && <Alert color="orange" role="alert">{scheduleMessages.schedule_clock}</Alert>}
      {schedule?.paused && <Alert color="orange">تنفيذ المواعيد متوقّف مؤقتًا.</Alert>}
      <Paper withBorder p="md">
        <Stack gap="sm">
          <Group justify="space-between">
            <Title order={3} size="h4">المواعيد القادمة</Title>
            {schedule && <Text size="sm" c="dimmed">عدد المواعيد · {schedule.total}</Text>}
          </Group>
          {schedules.isPending && <Skeleton h={112} aria-label="جارٍ تحميل المواعيد" />}
          {schedule && (schedule.items.length > 0
            ? <ScheduleTable items={schedule.items} label="المواعيد القادمة" />
            : <Text size="sm" c="dimmed">لا توجد مواعيد قادمة.</Text>)}
          {schedule && schedule.pageCount > 1 && <Pagination
            total={schedule.pageCount} value={schedule.page + 1} onChange={(next) => setPage(next - 1)}
            getControlProps={(control) => ({ 'aria-label': control === 'next' ? 'الصفحة التالية' : 'الصفحة السابقة' })} />}
        </Stack>
      </Paper>
      {editing && schedule && <ScheduleDialog stationTimeZone={schedule.stationTimeZone} onClose={() => setEditing(false)} onSaved={finish} />}
    </Stack>
  )
}
