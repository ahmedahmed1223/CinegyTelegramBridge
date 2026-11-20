import { Alert, Button, Group, NativeSelect, Paper, Stack, Table, Text } from '@mantine/core'
import { IconAdjustmentsHorizontal } from '@tabler/icons-react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { UrgentTimingStepper } from './UrgentTimingStepper'

const timingKey = ['urgent-timing']
const displayNumber = new Intl.NumberFormat('ar', { maximumFractionDigits: 2 })
const rows = [
  { field: 'interval', key: 'intervalSeconds', label: 'مدة عرض الخبر', unit: 'ثانية' },
  { field: 'repeats', key: 'repeats', label: 'عدد التكرارات', unit: 'مرة' },
  { field: 'order', key: 'repeatMode', label: 'ترتيب التكرار' },
  { field: 'total', key: 'totalSeconds', label: 'الحدّ الأقصى للدورة', unit: 'ثانية', zero: 'بلا حدّ' },
  { field: 'mode', key: 'mode', label: 'نمط العرض الافتراضي' },
  { field: 'gap', key: 'exitGapSeconds', label: 'الفاصل في نمط الخروج', unit: 'ثانية', zero: 'حركة المشهد فقط' },
] as const
const options = {
  mode: [{ value: 'text', label: 'تحديث النص' }, { value: 'exit', label: 'خروج قبل الخبر' }, { value: 'auto_hide', label: 'إخفاء بعد الخبر' }],
  order: [{ value: 'cycle', label: 'إعادة الجدول كاملًا' }, { value: 'item', label: 'تكرار كل خبر على حدة' }],
}
type Row = (typeof rows)[number]
type Edit = { row: Row; revision: string; value: number | string }

function display(row: Row, value: number | string) {
  if (row.field === 'mode' || row.field === 'order') return options[row.field].find((option) => option.value === value)?.label
  if (value === 0 && 'zero' in row) return row.zero
  return `${displayNumber.format(Number(value))} ${row.unit}`
}

export function UrgentTiming() {
  const [opened, setOpened] = useState(false)
  const [edit, setEdit] = useState<Edit | null>(null)
  const editor = useRef<HTMLDivElement>(null)
  const client = useQueryClient()
  const timing = useQuery({
    queryKey: timingKey,
    enabled: opened,
    retry: false,
    refetchInterval: opened ? 5000 : false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/urgent/timing', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const state = timing.data
  const save = useMutation({
    onMutate: () => client.cancelQueries({ queryKey: timingKey }),
    mutationFn: async (change: Edit) => {
      const body: Schemas['UrgentTimingRequest'] = {
        action: 'save', field: change.row.field, revision: change.revision,
        number: typeof change.value === 'number' ? change.value : null,
        option: typeof change.value === 'string' ? change.value : null,
      }
      const { data, error, response } = await api.POST('/api/content/urgent/timing', { body })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (updated) => { client.setQueryData(timingKey, updated); setEdit(null) },
    onError: (error) => {
      if (error.message === 'urgent_stale') { setEdit(null); void timing.refetch() }
    },
  })
  const editingField = edit?.row.field
  useEffect(() => { if (editingField) editor.current?.focus() }, [editingField])
  const bounds = state && edit && typeof edit.value === 'number' ? state.bounds[edit.row.field] : undefined
  const stale = !!edit && edit.revision !== state?.revision

  return (
    <Stack gap="xs" align="flex-start">
      <Button variant="default" leftSection={<IconAdjustmentsHorizontal size={17} aria-hidden />}
        aria-expanded={opened} aria-controls={opened ? 'urgent-timing-panel' : undefined}
        disabled={save.isPending} onClick={() => { setOpened(!opened); setEdit(null); save.reset() }}>إعدادات التوقيت</Button>
      {opened && <Paper id="urgent-timing-panel" withBorder p="md" w="100%">
        <Stack gap="sm">
          {timing.isPending && <Text size="sm" role="status">جارٍ قراءة إعدادات التوقيت…</Text>}
          {timing.isError && <Alert color="orange" role="alert">{messageFor(timing.error.message)}{' '}
            <Button variant="subtle" size="compact-sm" onClick={() => void timing.refetch()}>إعادة المحاولة</Button>
          </Alert>}
          {state && <>
            <Text size="sm" c="dimmed">أقصر مدة عرض حسب المشهد وإعداداته {displayNumber.format(state.floorSeconds)} ثانية. تسري التغييرات على الدورات التالية.</Text>
            {!state.canEdit && <Alert color="orange">{messageFor('urgent_timing_active')}</Alert>}
            <Table verticalSpacing="xs" aria-label="توقيت العواجل">
              <Table.Tbody>
                {rows.map((row) => <Table.Tr key={row.field}>
                  <Table.Th scope="row" fw={500}>{row.label}</Table.Th>
                  <Table.Td>{display(row, state[row.key])}</Table.Td>
                  <Table.Td ta="end"><Button size="compact-sm" variant="subtle" disabled={!state.canEdit || save.isPending} aria-label={`تعديل ${row.label}`}
                    onClick={() => { save.reset(); setEdit({ row, revision: state.revision, value: state[row.key] }) }}>تعديل</Button></Table.Td>
                </Table.Tr>)}
              </Table.Tbody>
            </Table>
            {edit && <Stack gap="xs" ref={editor} tabIndex={-1} aria-label={edit.row.label}>
              {bounds && typeof edit.value === 'number' ? <>
                <Text size="sm" fw={600} aria-live="polite">{edit.row.label} · {display(edit.row, edit.value)}</Text>
                <UrgentTimingStepper label={edit.row.label} value={edit.value} minimum={bounds.minimum} maximum={bounds.maximum}
                  disabled={save.isPending || !state.canEdit} onChange={(value) => setEdit({ ...edit, value })} />
              </> : (edit.row.field === 'mode' || edit.row.field === 'order') && (
                <NativeSelect label={edit.row.label} data={options[edit.row.field]} value={edit.value}
                  disabled={save.isPending} onChange={(event) => setEdit({ ...edit, value: event.currentTarget.value })} />
              )}
              {stale && <Alert color="orange" role="alert">تغيّرت الإعدادات. أعد فتح الحقل قبل الحفظ.</Alert>}
              <Group gap="xs">
                <Button size="sm" loading={save.isPending} disabled={!state.canEdit || stale || edit.value === state[edit.row.key]}
                  onClick={() => save.mutate(edit)}>حفظ التوقيت</Button>
                <Button size="sm" variant="default" disabled={save.isPending} onClick={() => { setEdit(null); save.reset() }}>إلغاء</Button>
              </Group>
            </Stack>}
          </>}
          {save.error && <Alert color="orange" role="alert">{messageFor(save.error.message)}</Alert>}
        </Stack>
      </Paper>}
    </Stack>
  )
}
