import { AdjustableRow, AdjustableTable } from '../../components/AdjustableTable'
import { ActionIcon, Alert, Badge, Button, Checkbox, Group, Paper, Stack, Table, Text, Textarea, Tooltip } from '@mantine/core'
import { modals } from '@mantine/modals'
import { useQuery } from '@tanstack/react-query'
import { getTemplates } from '../../api/air'
import { IconArrowDown, IconArrowUp, IconClockPlay, IconEdit, IconEyeOff, IconLogout, IconPlayerPlay, IconPlus, IconSettings, IconTrash } from '@tabler/icons-react'
import { useEffect, useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useLiveStatus } from '../../layout/LiveStatusContext'
import { LayerRemovalModal } from '../status/LayerRemovalModal'
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
  const [removal, setRemoval] = useState<{ layer: number; expectedTemplateKey: string; operation: 'hide' | 'exit' } | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const fields = board.fields ?? []
  const manual = useUrgentManual()
  const liveManual = manual.data?.live
  const live = useLiveStatus()
  // The breaking-news template uses the bridge's fixed MojazUrgentKey.
  const trackedUrgent = live.status?.layers.find((layer) => layer.key.toLowerCase() === 'urgent')
  const registry = useQuery({ queryKey: ['urgent-control-templates'], queryFn: () => getTemplates(), enabled: !trackedUrgent && !liveManual, retry: false })
  const urgentTemplate = registry.data?.find(template => template.key.toLowerCase() === 'urgent')
  const urgentLayer = liveManual?.layer ?? trackedUrgent?.layer ?? urgentTemplate?.layer
  const urgentKey = trackedUrgent?.key ?? urgentTemplate?.key ?? 'Urgent'
  const editing = !!edit || !!timingEdit || !!manualAction || !!removal || busy
  useEffect(() => {
    onEditingChange(editing)
    return () => onEditingChange(false)
  }, [editing, onEditingChange])

  function confirmHide() {
    if (!liveManual) return
    modals.openConfirmModal({
      title: 'إخفاء العاجل المعروض',
      children: <Text size="sm">عند التأكيد سيُخفى العاجل المعروض من الهواء على الطبقة {liveManual.layer}.</Text>,
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
      <AdjustableRow key={row.id ?? 'new'} className={classes.editRow}>
        <Table.Td />
        <Table.Td>{row.id ? '—' : 'جديد'}</Table.Td>
        {fields.map((field, index) => (
          <Table.Td key={field.name}>
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
      </AdjustableRow>
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
          <AdjustableTable layoutKey="urgent" label="جدول إدخال العواجل" verticalSpacing="sm" horizontalSpacing="sm" captionSide="top" columns={[
            { id: 'select', label: 'تحديد', width: 85, minWidth: 68 },
            { id: 'rank', label: 'الترتيب', width: 90, minWidth: 74 },
            ...fields.map((field) => ({ id: `field:${field.name}`, label: field.label, width: 218, minWidth: 130,
              header: <>{field.label}{field.required && <span aria-label="مطلوب"> *</span>}</> })),
            { id: 'state', label: 'الحالة', width: 120, minWidth: 106 },
            { id: 'actions', label: 'الإجراءات', width: 226, minWidth: 198 },
          ]}>
            <Table.Tbody>
              {edit && !edit.id && editorRow(edit)}
              {board.items.map((item, index) => {
                if (edit && edit.id === item.id) return editorRow(edit)
                const rank = item.position ?? board.page * 20 + index + 1
                const selectionState = item.id && selected.includes(item.id) ? 'selected' : 'ready'
                const state = status[item.state === 'on_air' || item.state === 'disabled' ? item.state : selectionState]
                const itemId = item.id
                const displayed = !!itemId && liveManual?.itemId === itemId
                const canShow = !!itemId && item.enabled && !edit && !busy && !searchPending
                return (
                  <AdjustableRow key={item.id ?? rank}>
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
                      <Table.Td key={field.name}>
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
                        </Group>
                        <Group gap={4} aria-label="التحكم بالعاجل المعروض على الهواء" role="group">
                          <Tooltip label="إخفاء العاجل المعروض"><ActionIcon size={44} variant="light" color="red"
                            aria-label="إخفاء العاجل المعروض" disabled={busy || !urgentLayer}
                            onClick={() => { if (displayed) confirmHide(); else if (urgentLayer) setRemoval({ layer: urgentLayer, expectedTemplateKey: urgentKey, operation: 'hide' }) }}>
                            <IconEyeOff size={18} />
                          </ActionIcon></Tooltip>
                          <Tooltip label="خروج المعروض (EXIT)"><ActionIcon size={44} variant="light" color="orange"
                            aria-label="خروج المعروض (EXIT)" disabled={busy || !urgentLayer}
                            onClick={() => { if (urgentLayer) setRemoval({ layer: urgentLayer, expectedTemplateKey: urgentKey, operation: 'exit' }) }}>
                            <IconLogout size={18} />
                          </ActionIcon></Tooltip>
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
                  </AdjustableRow>
                )
              })}
              {!board.items.length && !edit && (
                <Table.Tr><Table.Td colSpan={fields.length + 4}><Text c="dimmed" ta="center" py="sm">
                  {filtered ? 'لا توجد عواجل تطابق البحث.' : 'الجدول فارغ. أضف أول عاجل.'}
                </Text></Table.Td></Table.Tr>
              )}
            </Table.Tbody>
          </AdjustableTable>
        </form>
      </Paper>
      {timingEdit && <UrgentRowTiming title={timingEdit.item.title} timing={timingEdit.item.timing} busy={busy}
        stale={timingEdit.revision !== board.revision} error={error} onClose={() => { setTimingEdit(null); setError('') }}
        onSave={(timing) => void write({ action: 'timing', id: timingEdit.item.id, revision: timingEdit.revision, timing })} />}
      {manualAction && <UrgentManual {...manualAction} fields={fields} onClose={() => setManualAction(null)} onChanged={() => onSaved(false)} />}
      {removal && <LayerRemovalModal {...removal} onClose={() => setRemoval(null)} />}
    </Stack>
  )
}
