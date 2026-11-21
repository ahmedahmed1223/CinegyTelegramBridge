import {
  Alert, Button, Group, Modal, NumberInput, Pagination, Paper, SegmentedControl,
  Select, SimpleGrid, Skeleton, Stack, Table, Text, Textarea, TextInput, Title,
} from '@mantine/core'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { Link } from 'react-router'
import { getTemplates } from '../../api/air'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type SchedulePage = Schemas['TemplateSchedulePage']
type ScheduleItem = Schemas['PendingTemplateSchedule']
type ScheduleCommand = Schemas['TemplateScheduleReviewCommand']
type Recurrence = 'once' | 'daily' | 'weekly'
type Mutation = 'edit' | 'copy' | 'cancel'
type ScheduleSelection = { operation: 'create' } | { operation: Mutation; item: ScheduleItem }
type TimeMode = 'station' | 'relative' | 'anchor'

const scheduleKey = ['template-schedule'] as const
const recurrenceLabels: Record<Recurrence, string> = { once: 'مرة واحدة', daily: 'يوميًا', weekly: 'أسبوعيًا' }
const recurrenceOptions = Object.entries(recurrenceLabels).map(([value, label]) => ({ value, label }))
const operationLabels = { create: 'جدولة عرض قالب', edit: 'تعديل الموعد', copy: 'نسخ الموعد', cancel: 'إلغاء الموعد' }
const anchorOffsets = [
  { value: '0', label: 'مع بداية المادة' }, { value: '30', label: 'بعد 30 ثانية' },
  { value: '60', label: 'بعد دقيقة' }, { value: '300', label: 'بعد 5 دقائق' },
]
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
  schedule_material_invalid: 'اختر مادة ومدة تأخير صالحتين لموعد يُعرض مرة واحدة.',
  schedule_material_disabled: 'جدول المواد معطّل في إعدادات الجسر.',
  schedule_material_unavailable: 'تعذّر قراءة جدول المواد من المحطة.',
  schedule_material_stale: 'تغيّرت المادة أو موعدها في الجدول. حدّث قائمة المواد وراجع الموعد مجددًا.',
}

function scheduleMessage(error: Error) {
  return scheduleMessages[error.message] ?? messageFor(error.message)
}

function ScheduleTable({ items, label, onManage, clockValid }: {
  items: ScheduleItem[]
  label: string
  onManage?: (item: ScheduleItem, operation: Mutation) => void
  clockValid?: boolean
}) {
  return (
    <Table.ScrollContainer minWidth={onManage ? 730 : 560} type="native" tabIndex={0} aria-label={label}>
      <Table verticalSpacing="sm" aria-label={label}>
        <Table.Thead>
          <Table.Tr>
            <Table.Th scope="col">القالب</Table.Th>
            <Table.Th scope="col">الطبقة</Table.Th>
            <Table.Th scope="col">موعد المحطة</Table.Th>
            <Table.Th scope="col">التكرار</Table.Th>
            {onManage && <Table.Th scope="col">الإجراءات</Table.Th>}
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
                {item.anchorMaterialId && <Text size="xs" c="dimmed">مرتبط بمادة</Text>}
              </Table.Td>
              {onManage && <Table.Td>
                {item.canManage && <Group gap="xs" wrap="nowrap">
                  <Button size="compact-xs" variant="subtle" disabled={!clockValid} onClick={() => onManage(item, 'edit')}>تعديل الموعد</Button>
                  <Button size="compact-xs" variant="subtle" disabled={!clockValid} onClick={() => onManage(item, 'copy')}>نسخ</Button>
                  <Button size="compact-xs" variant="subtle" color="red" onClick={() => onManage(item, 'cancel')}>إلغاء</Button>
                </Group>}
              </Table.Td>}
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

function useScheduleMaterials(page: number, enabled: boolean) {
  return useQuery({
    queryKey: ['schedule-materials', page],
    enabled, retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/schedule/materials', { params: { query: { page } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
}

function ScheduleMaterials() {
  const [page, setPage] = useState(0)
  const materials = useScheduleMaterials(page, true)
  const list = materials.data
  return (
    <Paper withBorder p="md">
      <Stack gap="sm">
        <Group justify="space-between">
          <Title order={3} size="h4">جدول مواد القناة</Title>
          <Button variant="subtle" size="compact-sm" loading={materials.isFetching} onClick={() => void materials.refetch()}>تحديث</Button>
        </Group>
        {materials.isPending && <Skeleton h={90} aria-label="جارٍ تحميل المواد" />}
        {materials.error && <Alert color="orange" role="alert">{scheduleMessage(materials.error)}</Alert>}
        {list && !list.activeKnown && <Text size="sm" c="dimmed">تعذّر معرفة المادة المعروضة الآن.</Text>}
        {list && list.items.length === 0 && <Text size="sm" c="dimmed">لا توجد مواد في جدول القناة.</Text>}
        {list && list.items.length > 0 && <Table.ScrollContainer minWidth={460} type="native" tabIndex={0} aria-label="جدول مواد القناة">
          <Table aria-label="جدول مواد القناة">
            <Table.Thead><Table.Tr><Table.Th scope="col">المادة</Table.Th><Table.Th scope="col">وقت البداية</Table.Th><Table.Th scope="col">الحالة</Table.Th></Table.Tr></Table.Thead>
            <Table.Tbody>{list.items.map((item) => <Table.Tr key={item.id}>
              <Table.Td><bdi dir="auto">{item.name}</bdi></Table.Td>
              <Table.Td><bdi dir="ltr">{item.stationTime}</bdi></Table.Td>
              <Table.Td>{item.active ? 'على الهواء' : '—'}</Table.Td>
            </Table.Tr>)}</Table.Tbody>
          </Table>
        </Table.ScrollContainer>}
        {list && list.pageCount > 1 && <Pagination total={list.pageCount} value={list.page + 1} onChange={(next) => setPage(next - 1)} />}
      </Stack>
    </Paper>
  )
}

function ScheduleDialog({ stationTimeZone, selection, materialsEnabled, onClose, onSaved }: {
  stationTimeZone: string
  selection: ScheduleSelection
  materialsEnabled: boolean
  onClose: () => void
  onSaved: (result: SchedulePage) => void
}) {
  const item = 'item' in selection ? selection.item : undefined
  const operation = selection.operation
  const [templateKey, setTemplateKey] = useState<string | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const [timeMode, setTimeMode] = useState<TimeMode>(item?.anchorMaterialId && materialsEnabled ? 'anchor' : 'station')
  const [stationInput, setStationInput] = useState('')
  const [minutes, setMinutes] = useState<number | string>(15)
  const [recurrence, setRecurrence] = useState<Recurrence>(item?.recurrence === 'daily' || item?.recurrence === 'weekly' ? item.recurrence : 'once')
  const [until, setUntil] = useState(item?.recurrenceUntil ?? '')
  const [materialPage, setMaterialPage] = useState(0)
  const [materialId, setMaterialId] = useState(item?.anchorMaterialId ?? '')
  const [offset, setOffset] = useState(String(item?.anchorOffsetSeconds ?? 0))
  const [inputError, setInputError] = useState('')

  const templates = useQuery({ queryKey: ['templates'], queryFn: getTemplates, enabled: operation === 'create' })
  const materials = useScheduleMaterials(materialPage, operation !== 'cancel' && timeMode === 'anchor')
  const template = templates.data?.find((item) => item.key === templateKey && !item.disabled)
  const choices = (templates.data ?? []).filter((item) => !item.disabled).map((item) => ({
    value: item.key, label: item.name === item.key ? item.name : `${item.name} · ${item.key}`,
  }))
  const materialChoices = (materials.data?.items ?? []).filter((entry) => entry.canAnchor).map((entry) => ({
    value: entry.id, label: `${entry.name} · ${entry.stationTime}`,
  }))
  if (materialId && !materialChoices.some((choice) => choice.value === materialId)) {
    materialChoices.unshift({ value: materialId, label: materialId === item?.anchorMaterialId ? 'المادة المرتبطة حاليًا' : materialId })
  }

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
  const error = review ? confirm.error : (preview.error ?? (operation === 'create' ? templates.error : null) ?? materials.error)

  function requestReview(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if ((!item && !template) || busy) return
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
    if (operation !== 'cancel' && timeMode === 'anchor' && !materialId) {
      setInputError('اختر مادة من جدول المحطة.')
      return
    }
    if (operation === 'cancel' && item) {
      preview.mutate({
        operation, scheduleId: item.id, revision: item.revision,
        key: null, time: null, recurrence: 'once', recurrenceUntil: null, variables: null,
        anchorMaterialId: null, anchorOffsetSeconds: null,
      })
      return
    }
    preview.mutate({
      operation,
      scheduleId: item?.id,
      revision: item?.revision,
      key: template?.key,
      time,
      recurrence,
      recurrenceUntil: recurrence !== 'once' ? until : null,
      variables: operation === 'create' ? values : null,
      anchorMaterialId: timeMode === 'anchor' ? materialId : '',
      anchorOffsetSeconds: timeMode === 'anchor' ? Number(offset) : 0,
    })
  }

  function backToForm() {
    preview.reset()
    confirm.reset()
  }

  return (
    <Modal opened onClose={() => { if (!busy) onClose() }} closeOnEscape={!busy} closeOnClickOutside={!busy}
      closeButtonProps={{ 'aria-label': 'إغلاق الجدولة', disabled: busy }} size="lg"
      title={review ? `مراجعة · ${operationLabels[operation]}` : operationLabels[operation]}>
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
                {review.anchorMaterialId && <Text size="sm">
                  المادة <bdi dir="auto">{review.anchorMaterialName || review.anchorMaterialId}</bdi> · {anchorOffsets.find((entry) => entry.value === String(review.anchorOffsetSeconds))?.label}
                </Text>}
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
              <Button variant="default" disabled={busy} onClick={operation === 'cancel' ? onClose : backToForm}>
                {operation === 'cancel' ? 'العودة' : 'العودة إلى الإدخال'}
              </Button>
              <Button color={operation === 'cancel' ? 'red' : undefined} loading={confirm.isPending} disabled={busy || confirm.isError}
                onClick={() => confirm.mutate(review.review)}>{operation === 'cancel' ? 'تأكيد إلغاء الموعد' : 'حفظ الموعد'}</Button>
            </Group>
          </>
        ) : (
          <form onSubmit={requestReview}>
            <Stack gap="md">
              {item && <Text fw={600} dir="auto">{item.key}</Text>}
              {operation === 'create' && (templates.isPending ? <Skeleton h={60} aria-label="جارٍ تحميل القوالب" /> :
                <Select label="القالب" placeholder="اختر قالبًا" searchable allowDeselect={false}
                  nothingFoundMessage="لا توجد قوالب مطابقة" data={choices} value={templateKey} required disabled={busy}
                  onChange={(value) => { setTemplateKey(value); setValues({}); preview.reset() }} />)}
              {operation === 'create' && template?.fields.map((field) => {
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
              {operation !== 'cancel' && <>
              <SegmentedControl fullWidth aria-label="طريقة تحديد الموعد" value={timeMode} disabled={busy}
                data={[
                  { value: 'station', label: 'موعد محدّد' }, { value: 'relative', label: 'بعد دقائق' },
                  ...(materialsEnabled && recurrence === 'once' ? [{ value: 'anchor', label: 'مع مادة' }] : []),
                ]}
                onChange={(value) => { setTimeMode(value === 'relative' || value === 'anchor' ? value : 'station'); setInputError('') }} />
              {timeMode === 'station' ?
                <TextInput label="التاريخ والوقت بتوقيت المحطة" description={<bdi dir="ltr">{stationTimeZone}</bdi>}
                  type="datetime-local" dir="ltr" value={stationInput} required disabled={busy} onChange={(event) => setStationInput(event.currentTarget.value)} /> :
                timeMode === 'relative' ? <NumberInput label="عدد الدقائق من الآن" value={minutes} onChange={(value) => { setMinutes(value); setInputError('') }}
                  min={1} max={9999} allowDecimal={false} allowNegative={false} clampBehavior="none" required disabled={busy} /> :
                  <Stack gap="xs">
                    <Select label="المادة" searchable data={materialChoices} value={materialId || null} disabled={busy || materials.isPending}
                      nothingFoundMessage="لا توجد مواد متاحة للربط في هذه الصفحة" onChange={(value) => setMaterialId(value ?? '')} />
                    {materials.data && materials.data.pageCount > 1 &&
                      <Pagination total={materials.data.pageCount} value={materials.data.page + 1} onChange={(next) => setMaterialPage(next - 1)} />}
                    <Select label="وقت العرض بالنسبة إلى بداية المادة" data={anchorOffsets} value={offset} allowDeselect={false}
                      disabled={busy} onChange={(value) => setOffset(value ?? '0')} />
                  </Stack>}
              <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
                <Select label="التكرار" data={recurrenceOptions} value={recurrence} allowDeselect={false} disabled={busy || operation !== 'create'}
                  onChange={(value) => {
                    const chosen = value === 'daily' || value === 'weekly' ? value : 'once'
                    setRecurrence(chosen)
                    if (chosen !== 'once' && timeMode === 'anchor') setTimeMode('station')
                  }} />
                {recurrence !== 'once' && <TextInput label="نهاية التكرار" description="اختياري"
                  type="date" dir="ltr" value={until} disabled={busy} onChange={(event) => setUntil(event.currentTarget.value)} />}
              </SimpleGrid>
              </>}
              {operation === 'cancel' && item && <Text size="sm">موعد المحطة <bdi dir="ltr">{item.stationTime}</bdi></Text>}
              <Group justify="flex-end">
                <Button variant="default" disabled={busy} onClick={onClose}>العودة</Button>
                <Button type="submit" loading={preview.isPending} disabled={(!item && !template) || busy}>
                  {operation === 'cancel' ? 'مراجعة إلغاء الموعد' : 'مراجعة الموعد'}
                </Button>
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
  const [editing, setEditing] = useState<ScheduleSelection | null>(null)
  const [showMaterials, setShowMaterials] = useState(false)
  const [feedback, setFeedback] = useState('')
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
    setFeedback(editing?.operation === 'cancel' ? 'أُلغي الموعد.' : 'حُفظ موعد القالب.')
    setEditing(null)
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
        <Group gap="xs">
          {schedule?.materialsEnabled && <Button variant="default" aria-expanded={showMaterials}
            onClick={() => setShowMaterials((previous) => !previous)}>جدول المواد</Button>}
          <Button component={Link} to="/schedule/executions" variant="default">سجل تنفيذ المواعيد</Button>
          <Button disabled={!schedule?.clockValid || schedules.isError} onClick={() => { setFeedback(''); setEditing({ operation: 'create' }) }}>إضافة موعد</Button>
        </Group>
      </Group>
      {feedback && <Text size="sm" role="status">{feedback}</Text>}
      {showMaterials && schedule?.materialsEnabled && <ScheduleMaterials />}
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
            ? <ScheduleTable items={schedule.items} label="المواعيد القادمة" clockValid={schedule.clockValid}
                onManage={(item, operation) => { setFeedback(''); setEditing({ item, operation }) }} />
            : <Text size="sm" c="dimmed">لا توجد مواعيد قادمة.</Text>)}
          {schedule && schedule.pageCount > 1 && <Pagination
            total={schedule.pageCount} value={schedule.page + 1} onChange={(next) => setPage(next - 1)}
            getControlProps={(control) => ({ 'aria-label': control === 'next' ? 'الصفحة التالية' : 'الصفحة السابقة' })} />}
        </Stack>
      </Paper>
      {editing && schedule && <ScheduleDialog selection={editing} materialsEnabled={schedule.materialsEnabled}
        stationTimeZone={schedule.stationTimeZone} onClose={() => setEditing(null)} onSaved={finish} />}
    </Stack>
  )
}
