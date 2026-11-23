import { ActionIcon, Alert, Badge, Button, Checkbox, Group, Paper, Stack, Table, Text, Textarea, Tooltip } from '@mantine/core'
import { modals } from '@mantine/modals'
import { IconArrowDown, IconArrowUp, IconClockPlay, IconEdit, IconPlayerPlay, IconPlayerStop, IconPlus, IconSettings, IconTrash } from '@tabler/icons-react'
import { useEffect, useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import classes from './NewsroomPage.module.css'
import { UrgentRowTiming } from './UrgentRowTiming'
import { UrgentManual } from './UrgentManual'
import { sendUrgentManual, useUrgentManual } from './urgentManualApi'

type ContentPage = Schemas['ContentPage']
type ContentItem = Schemas['ContentItem']
type Edit = { id: string | null; revision: number; values: Record<string, string>; enabled: boolean }

const status: Record<string, { label: string; color: string }> = {
  on_air: { label: 'على الهواء', color: 'red' },
  disabled: { label: 'معطّل', color: 'gray' },
  selected: { label: 'محدّد', color: 'signal' },
  ready: { label: 'جاهز', color: 'teal' },
}

export function UrgentTable({ board, filtered, searchPending, selected, onToggle, onClear, onSaved, onEditingChange }: {
  board: ContentPage
  filtered: boolean
  searchPending: boolean
  selected: string[]
  onToggle: (id: string) => void
  onClear: () => void
  onSaved: (added: boolean) => Promise<void>
  onEditingChange: (editing: boolean) => void
}) {
  const [edit, setEdit] = useState<Edit | null>(null)
  const [timingEdit, setTimingEdit] = useState<{ item: ContentItem; revision: number } | null>(null)
  const [manualAction, setManualAction] = useState<{ itemId: string; mode: 'direct' | 'timed' } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const fields = board.fields ?? []
  const manual = useUrgentManual()
  const liveManual = manual.data?.live
  const editing = !!edit || !!timingEdit || !!manualAction || busy
  useEffect(() => {
    onEditingChange(editing)
    return () => onEditingChange(false)
  }, [editing, onEditingChange])

  function confirmHide() {
    if (!liveManual) return
    modals.openConfirmModal({
      title: 'إخفاء العاجل المعروض',
      children: <Text size="sm">سيُخفى العاجل الذي عرضته من الطبقة {liveManual.layer}.</Text>,
      labels: { confirm: 'إخفاء العاجل', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: () => void (async () => {
        setBusy(true)
        setError('')
        try { await sendUrgentManual({ action: 'hide', review: liveManual.review }); await Promise.all([manual.refetch(), onSaved(false)]) }
        catch (failure) { setError(failure instanceof Error ? failure.message : messageFor('bridge_unavailable')); await manual.refetch() }
        finally { setBusy(false) }
      })(),
    })
  }

  function startEdit(item?: ContentItem) {
    if (board.revision == null) return
    setError('')
    setEdit({
      id: item?.id ?? null,
      revision: board.revision,
      values: Object.fromEntries(fields.map((field) => [field.name, item?.values?.[field.name] ?? ''])),
      enabled: item?.enabled ?? true,
    })
  }

  async function write(body: Schemas['UrgentWriteRequest']) {
    if (busy) return
    setBusy(true)
    setError('')
    try {
      const { error: refusal, response } = await api.POST('/api/content/urgent', { body })
      if (!response.ok) {
        setError(refusal?.message || messageFor(errorCode(refusal, response)))
        return
      }
      setEdit(null)
      setTimingEdit(null)
      await onSaved(body.action === 'add')
    } catch {
      setError('تعذّر الوصول إلى الجسر. حدّث الجدول للتحقق من حفظ التغيير.')
    } finally {
      setBusy(false)
    }
  }

  function rowAction(item: ContentItem, action: 'up' | 'down' | 'remove') {
    const revision = board.revision
    if (!item.id || revision == null) return
    const body = { action, revision, id: item.id }
    if (action !== 'remove') {
      void write(body)
      return
    }
    modals.openConfirmModal({
      title: 'حذف العاجل من الجدول',
      children: <Text dir="auto" lineClamp={4}>{item.title}</Text>,
      labels: { confirm: 'حذف', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: () => void write(body),
    })
  }

  function editorRow(row: Edit) {
    return (
      <Table.Tr key={row.id ?? 'new'} className={classes.editRow}>
        <Table.Td />
        <Table.Td>{row.id ? '—' : 'جديد'}</Table.Td>
        {fields.map((field, index) => (
          <Table.Td key={field.name} className={classes.urgentCell}>
            <Textarea
              aria-label={field.label}
              dir="rtl"
              autosize
              minRows={2}
              maxRows={5}
              required={field.required}
              maxLength={field.maxLength ?? undefined}
              value={row.values[field.name] ?? ''}
              onChange={(event) => setEdit({ ...row, values: { ...row.values, [field.name]: event.currentTarget.value } })}
              autoFocus={index === 0}
              disabled={busy}
            />
          </Table.Td>
        ))}
        <Table.Td>
          <Checkbox label="مفعّل" checked={row.enabled} disabled={busy} onChange={(event) => setEdit({ ...row, enabled: event.currentTarget.checked })} />
        </Table.Td>
        <Table.Td>
          <Group gap="xs" wrap="nowrap">
            <Button type="submit" size="compact-sm" loading={busy}>حفظ</Button>
            <Button variant="subtle" size="compact-sm" disabled={busy} onClick={() => { setEdit(null); setError('') }}>إلغاء</Button>
          </Group>
        </Table.Td>
      </Table.Tr>
    )
  }

  if (!fields.length) return <Alert>لم تُسجّل حقول إدخال لقالب العواجل في الجسر.</Alert>

  return (
    <Stack gap="sm">
      <Group justify="space-between">
        <Text size="sm" c="dimmed">جدول مشترك مع بوت Telegram. الأعمدة من قالب العواجل.</Text>
        <Group gap="xs">
          {!!selected.length && <Button variant="subtle" size="sm" onClick={onClear}>إلغاء التحديد</Button>}
          <Button leftSection={<IconPlus size={17} />} disabled={!!edit || busy || searchPending} onClick={() => startEdit()}>إضافة عاجل</Button>
        </Group>
      </Group>
      <Text size="xs" c="dimmed" hiddenFrom="sm">مرّر الجدول أفقيًا لرؤية الحقول والإجراءات.</Text>
      {!timingEdit && error && <Alert color="red" role="alert">{error}</Alert>}
      {liveManual && <Group justify="space-between">
        <Text size="sm">عرض فردي على الطبقة {liveManual.layer}</Text>
        <Button color="red" variant="light" size="sm" leftSection={<IconPlayerStop size={17} />}
          disabled={busy || !manual.isSuccess} onClick={confirmHide}>إيقاف العرض وإخفاء العاجل</Button>
      </Group>}
      <Paper radius="lg" className={classes.urgentGrid}>
        <form onSubmit={(event) => {
          event.preventDefault()
          if (edit) void write({
            action: edit.id ? 'update' : 'add',
            revision: edit.revision,
            id: edit.id,
            row: { values: edit.values, enabled: edit.enabled },
          })
        }}>
          <Table.ScrollContainer minWidth={Math.max(480, 160 * fields.length + 260)} tabIndex={0} aria-label="جدول إدخال العواجل">
            <Table verticalSpacing="sm" horizontalSpacing="sm" captionSide="top">
              <Table.Thead>
                <Table.Tr>
                  <Table.Th scope="col" w={70}>تحديد</Table.Th>
                  <Table.Th scope="col" w={55}>الترتيب</Table.Th>
                  {fields.map((field) => (
                    <Table.Th key={field.name} scope="col">
                      {field.label}{field.required && <span aria-label="مطلوب"> *</span>}
                    </Table.Th>
                  ))}
                  <Table.Th scope="col" w={100}>الحالة</Table.Th>
                  <Table.Th scope="col" w={150}>الإجراءات</Table.Th>
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {edit && !edit.id && editorRow(edit)}
                {board.items.map((item, index) => {
                  if (edit && edit.id === item.id) return editorRow(edit)
                  const rank = item.position ?? board.page * 20 + index + 1
                  const state = status[item.state]
                  const itemId = item.id
                  const displayed = !!itemId && liveManual?.itemId === itemId
                  const canShow = !!itemId && item.enabled && !edit && !busy && !searchPending
                  return (
                    <Table.Tr key={item.id ?? rank}>
                      <Table.Td>
                        {item.id && <Checkbox
                          aria-label={`تحديد العاجل ${rank}`}
                          checked={selected.includes(item.id)}
                          disabled={!item.enabled && !selected.includes(item.id)}
                          onChange={() => { if (item.id) onToggle(item.id) }}
                        />}
                      </Table.Td>
                      <Table.Td className="cgb-mono">{rank}</Table.Td>
                      {fields.map((field) => (
                        <Table.Td key={field.name} className={classes.urgentCell}>
                          <Text dir="rtl" size="sm" className={classes.headline}>{item.values?.[field.name] || '—'}</Text>
                        </Table.Td>
                      ))}
                      <Table.Td>{state && <Badge color={state.color} variant="light">{state.label}</Badge>}</Table.Td>
                      <Table.Td>
                        <Stack gap={4}>
                          <Group wrap="nowrap" gap={4} aria-label="إجراءات العرض" role="group">
                            <Tooltip label="عرض مباشر">
                              <ActionIcon size={44} variant="light" aria-label={`عرض مباشر للعاجل ${rank}`} disabled={!canShow}
                                onClick={() => { if (itemId) setManualAction({ itemId, mode: 'direct' }) }}><IconPlayerPlay size={17} /></ActionIcon>
                            </Tooltip>
                            <Tooltip label="عرض بمؤقّت">
                              <ActionIcon size={44} variant="light" aria-label={`عرض العاجل ${rank} بمؤقّت`} disabled={!canShow}
                                onClick={() => { if (itemId) setManualAction({ itemId, mode: 'timed' }) }}><IconClockPlay size={17} /></ActionIcon>
                            </Tooltip>
                            {displayed && <Tooltip label="إيقاف العرض وإخفاء العاجل">
                              <ActionIcon size={44} color="red" variant="light" aria-label={`إيقاف وإخفاء العاجل ${rank}`} disabled={busy || !manual.isSuccess}
                                onClick={confirmHide}><IconPlayerStop size={17} /></ActionIcon>
                            </Tooltip>}
                          </Group>
                          <Group wrap="nowrap" gap={4} aria-label="إجراءات التحرير" role="group">
                            <ActionIcon variant="subtle" aria-label={`تعديل العاجل ${rank}`} disabled={!item.id || !!edit || busy || searchPending} onClick={() => startEdit(item)}><IconEdit size={17} /></ActionIcon>
                            <Tooltip label="توقيت الصف في الدورة">
                              <ActionIcon variant={item.timing?.intervalSeconds || item.timing?.repeats || item.timing?.mode ? 'light' : 'subtle'}
                                aria-label={`توقيت العاجل ${rank} في الدورة`} disabled={!item.id || !!edit || busy || searchPending}
                                onClick={() => { if (board.revision != null) { setError(''); setTimingEdit({ item, revision: board.revision }) } }}><IconSettings size={17} /></ActionIcon>
                            </Tooltip>
                            <ActionIcon variant="subtle" aria-label={`رفع العاجل ${rank}`} disabled={rank === 1 || !item.id || !!edit || busy} onClick={() => rowAction(item, 'up')}><IconArrowUp size={17} /></ActionIcon>
                            <ActionIcon variant="subtle" aria-label={`خفض العاجل ${rank}`} disabled={rank === (board.collectionTotal ?? board.total) || !item.id || !!edit || busy} onClick={() => rowAction(item, 'down')}><IconArrowDown size={17} /></ActionIcon>
                            <ActionIcon variant="subtle" color="red" aria-label={`حذف العاجل ${rank}`} disabled={!item.id || !!edit || busy} onClick={() => rowAction(item, 'remove')}><IconTrash size={17} /></ActionIcon>
                          </Group>
                        </Stack>
                      </Table.Td>
                    </Table.Tr>
                  )
                })}
                {!board.items.length && !edit && (
                  <Table.Tr><Table.Td colSpan={fields.length + 4}><Text c="dimmed" ta="center" py="sm">
                    {filtered ? 'لا توجد عواجل تطابق البحث.' : 'الجدول فارغ. أضف أول عاجل.'}
                  </Text></Table.Td></Table.Tr>
                )}
              </Table.Tbody>
            </Table>
          </Table.ScrollContainer>
        </form>
      </Paper>
      {timingEdit && <UrgentRowTiming title={timingEdit.item.title} timing={timingEdit.item.timing} busy={busy}
        stale={timingEdit.revision !== board.revision} error={error} onClose={() => { setTimingEdit(null); setError('') }}
        onSave={(timing) => void write({ action: 'timing', id: timingEdit.item.id, revision: timingEdit.revision, timing })} />}
      {manualAction && <UrgentManual {...manualAction} fields={fields} onClose={() => setManualAction(null)} onChanged={() => onSaved(false)} />}
    </Stack>
  )
}
