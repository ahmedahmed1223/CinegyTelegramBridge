import {
  ActionIcon, Alert, Button, Group, Menu, NativeSelect, Pagination, Paper, Select, Skeleton, Stack,
  Table, Text, Textarea, TextInput, Title, Tooltip,
} from '@mantine/core'
import { modals } from '@mantine/modals'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { IconArrowDown, IconArrowRight, IconArrowUp, IconClipboard, IconClock, IconCopy, IconEdit, IconFileUpload, IconPhoto, IconPlus, IconRefresh, IconTrash } from '@tabler/icons-react'
import { useState } from 'react'
import { api, errorCode, uploadBulletinPhotoRow, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { BulletinPaste } from './RowPaste'
import { BulletinNewRowDialog, BulletinPhotoDialog } from './BulletinPhotoDialog'
import { BulletinSceneImageDialog } from './BulletinSceneImageDialog'
import { BulletinPreview } from './BulletinPreview'
import { BulletinRunStatus } from './BulletinPlayback'
import { CapturePanel } from '../live/CapturePanel'
import { BulletinSchedule } from './BulletinSchedule'
import { BulletinManagementDialog, type BulletinManagementOperation } from './BulletinManagementDialog'
import { BulletinAfterUrgentButton } from './BulletinAfterUrgentButton'
import { BulletinTimingForm } from './BulletinTimingForm'
import { useBulletinPlayback } from './bulletinPlaybackApi'
import classes from './NewsroomPage.module.css'

type Bulletin = Schemas['BulletinEditor']
type Row = Schemas['BulletinRow']
type EditRequest = Pick<Schemas['BulletinEditRequest'], 'action'> & Partial<Schemas['BulletinEditRequest']>
type EditRow = { row: Row; revision: number; values: Record<string, string>; imageChoice: string }
type NameAction = 'create' | 'rename' | 'copy'
const number = new Intl.NumberFormat('ar')
const names = { create: 'إنشاء موجز', rename: 'إعادة تسمية', copy: 'نسخ الموجز' }

async function applyEdit(request: EditRequest) {
  const { data, error, response } = await api.POST('/api/content/bulletins/editor', {
    body: { id: null, revision: null, page: null, rowId: null, name: null, design: null, values: null, timing: null,
      imageMode: null, imageSourceRowId: null, ...request },
  })
  if (!data) {
    const code = errorCode(error, response)
    throw new Error(error?.message || messageFor(code), { cause: code })
  }
  return data
}

function useBulletinDesigns(enabled: boolean) {
  return useQuery({
    queryKey: ['bulletin-designs'], enabled, retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/bulletins/designs', { signal })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data.designs.map((item) => ({ value: item.key, label: item.label }))
    },
  })
}

export function BulletinNameForm({ mode, current, onCancel, onSave }: {
  mode: NameAction
  current?: Bulletin
  onCancel: () => void
  onSave: (value: Bulletin) => void
}) {
  const [name, setName] = useState(mode === 'rename' ? current?.name ?? '' : '')
  const [design, setDesign] = useState<string | null>(null)
  const designs = useBulletinDesigns(mode === 'create')
  const edit = useMutation({ mutationFn: applyEdit, onSuccess: onSave })
  return (
    <Paper withBorder p="md" radius="lg">
      <form onSubmit={(event) => {
        event.preventDefault()
        if (edit.isPending || !name.trim()) return
        edit.mutate({ action: mode, id: current?.id, revision: current?.revision, page: current?.page, name: name.trim(), design })
      }}>
        <Stack gap="sm">
          <Title order={4}>{names[mode]}</Title>
          <Group align="flex-end" gap="sm">
            <TextInput
              className={classes.bulletinName} label="اسم الموجز" required maxLength={120} autoFocus
              value={name} onChange={(event) => setName(event.currentTarget.value)} disabled={edit.isPending}
            />
            {!!designs.data?.length && (
              <Select<string> label="التصميم" placeholder="التصميم الافتراضي" clearable data={designs.data}
                value={design} onChange={setDesign} disabled={edit.isPending} />
            )}
            <Button type="submit" loading={edit.isPending} disabled={!name.trim() || (mode === 'create' && designs.isPending)}>{mode === 'create' ? 'إنشاء' : 'حفظ'}</Button>
            <Button variant="subtle" onClick={onCancel} disabled={edit.isPending}>إلغاء</Button>
          </Group>
          {edit.error && <Alert color="red" role="alert">{edit.error.message}</Alert>}
          {designs.error && <Alert color="red" role="alert">{designs.error.message}</Alert>}
        </Stack>
      </form>
    </Paper>
  )
}

const bulletinKey = (id: string, page: number) => ['bulletin-editor', id, page]

export function BulletinEditor({ id, onBack, onSaved }: {
  id: string
  onBack: () => void
  onSaved: (value: Bulletin) => void
}) {
  const [page, setPage] = useState(0)
  const [rowEdit, setRowEdit] = useState<EditRow | null>(null)
  const [nameMode, setNameMode] = useState<Exclude<NameAction, 'create'> | null>(null)
  const [pasting, setPasting] = useState(false)
  const [editingTiming, setEditingTiming] = useState(false)
  const [previewing, setPreviewing] = useState(false)
  const [scheduling, setScheduling] = useState(false)
  const [management, setManagement] = useState<BulletinManagementOperation | null>(null)
  const [newRow, setNewRow] = useState<{ revision: number; uploadField?: string; title: string; imageChoice: string } | null>(null)
  const [photoRow, setPhotoRow] = useState<{ rowId: string; revision: number; field: string; title: string } | null>(null)
  const [sceneImageRow, setSceneImageRow] = useState<{ rowId: string; revision: number } | null>(null)
  const [designChange, setDesignChange] = useState<{ key: string | null; revision: number } | null>(null)
  const [savedNote, setSavedNote] = useState('')
  const queryClient = useQueryClient()
  const query = useQuery({
    queryKey: bulletinKey(id, page),
    retry: false,
    refetchOnWindowFocus: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/bulletins/editor', { params: { query: { id, page } }, signal })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const designs = useBulletinDesigns(!!query.data)
  function acceptSaved(value: Bulletin) {
    queryClient.setQueryData(bulletinKey(value.id, value.page), value)
    if (value.id === id) {
      setPage(value.page)
      setSavedNote('حُفظ الموجز.')
    }
    setRowEdit(null)
    setNameMode(null)
    setPasting(false)
    setEditingTiming(false)
    setNewRow(null)
    setPhotoRow(null)
    setSceneImageRow(null)
    setDesignChange(null)
    onSaved(value)
  }
  const edit = useMutation({ mutationFn: applyEdit, onSuccess: acceptSaved })
  const bulletin = query.data
  const playback = useBulletinPlayback(id, Boolean(bulletin?.playbackSupported || bulletin?.onAir))
  const onAir = playback.data ? Boolean(playback.data.run) : bulletin?.onAir === true
  const sceneUnconfirmed = playback.data?.run?.state === 'scene_unconfirmed'
  const busy = edit.isPending || query.isFetching
  const editing = !!rowEdit || !!newRow || !!nameMode || !!designChange || !!photoRow || !!sceneImageRow || pasting || editingTiming || previewing || scheduling || !!management
  const fields = bulletin?.fields ?? []
  const textFields = fields.filter((field) => field.kind === 'text')
  const photoFields = fields.filter((field) => bulletin?.photoFields?.includes(field.name) ??
    (bulletin?.canUploadPhoto && field.name === bulletin.imageField))
  const isBuiltInStory = bulletin?.design.toLowerCase() === 'mojaz' && bulletin.headlinePaste
  const preferredPhoto = bulletin?.imageField ? photoFields.find((field) => field.name === bulletin.imageField) : photoFields[0]
  const imageOptions = bulletin?.imageField ? [
    { value: 'inherit', label: 'الصورة السابقة' },
    { value: 'template', label: 'صورة القالب' },
    ...(bulletin.imageChoices ?? []).map(({ rowId, rowNumber }) => ({ value: `reuse:${rowId}`, label: `صورة الصف ${number.format(rowNumber)}` })),
  ] : []
  const canEnterRow = textFields.length > 0 || Boolean(bulletin?.imageField)
  const rowCanSave = Boolean(rowEdit && !busy && (textFields.length || rowEdit.imageChoice))
  const availableDesigns = designs.data?.filter((entry) => entry.value !== bulletin?.design) ?? []

  function startRow(row: Row, revision: number) {
    edit.reset()
    setSavedNote('')
    setRowEdit({ row, revision, values: Object.fromEntries(textFields.map((field) => [field.name, row.values[field.name] ?? ''])),
      imageChoice: '' })
  }

  function startNewRow(revision: number, field?: Bulletin['fields'][number]) {
    edit.reset()
    setSavedNote('')
    const title = field ? (photoFields.length === 1 ? 'إضافة صف بصورة' : `إضافة صف بصورة في عمود ${field.label}`) : 'إضافة صف'
    setNewRow({
      revision, title, uploadField: (field ?? preferredPhoto)?.name,
      imageChoice: field ? 'new' : bulletin?.imageField ? 'inherit' : '',
    })
  }

  function rowAction(action: 'up' | 'down' | 'skip' | 'remove', row: Row, latest: Bulletin) {
    const write = () => {
      setSavedNote('')
      edit.mutate({ action, id, revision: latest.revision, page: latest.page, rowId: row.id })
    }
    if (action === 'remove') {
      const text = textFields.map((field) => row.values[field.name]).find(Boolean)
      modals.openConfirmModal({
        title: 'حذف صف من الموجز',
        children: <Text dir="auto" lineClamp={4}>{text || 'سيُحذف الصف المحدد من الموجز.'}</Text>,
        labels: { confirm: 'حذف الصف', cancel: 'إلغاء' },
        confirmProps: { color: 'red' },
        onConfirm: write,
      })
    } else write()
  }

  function cell(row: Row, field: Bulletin['fields'][number]) {
    if (field.kind === 'media') {
      if (row.media.includes(field.name)) return <Text size="sm">مرفق</Text>
      if (field.name === bulletin?.imageField && row.imageMode) {
        return <Text size="sm" c="dimmed">{row.imageMode === 'template' ? 'صورة القالب' : 'استمرار الصورة السابقة'}</Text>
      }
      return <Text size="sm" c="dimmed">—</Text>
    }
    return <Text size="sm" dir="rtl" className={classes.bulletinCellText}>{row.values[field.name] || '—'}</Text>
  }

  function editRow(active: EditRow, rank: number) {
    return (
      <Table.Tr key={active.row.id} className={classes.editRow}>
        <Table.Td>{number.format(rank)}</Table.Td>
        {fields.map((field) => (
          <Table.Td key={field.name} className={field.kind === 'text' ? classes.urgentCell : undefined}>
            {field.kind === 'text' ? (
              <Textarea aria-label={field.label} dir="rtl" autosize minRows={2} maxRows={6} maxLength={4096}
                autoFocus={field === textFields[0]} disabled={busy} value={active.values[field.name] ?? ''}
                onChange={(event) => setRowEdit({ ...active, values: { ...active.values, [field.name]: event.currentTarget.value } })} />
            ) : field.name === bulletin?.imageField ? (
              <NativeSelect miw={170} aria-label="مصدر الصورة"
                data={[{ value: '', label: 'الإبقاء على الإعداد الحالي' }, ...imageOptions]} value={active.imageChoice} disabled={busy}
                onChange={(event) => setRowEdit({ ...active, imageChoice: event.currentTarget.value })} />
            ) : cell(active.row, field)}
          </Table.Td>
        ))}
        <Table.Td colSpan={2}><Text size="sm" c="dimmed">قيد التحرير</Text></Table.Td>
      </Table.Tr>
    )
  }

  return (
    <Stack gap="md">
      <Group justify="space-between">
        <Button variant="subtle" leftSection={<IconArrowRight size={17} />} onClick={onBack} disabled={editing || edit.isPending}>مكتبة الموجز</Button>
        <Button variant="default" leftSection={<IconRefresh size={16} />} onClick={() => void query.refetch()} loading={query.isFetching} disabled={editing || edit.isPending}>تحديث</Button>
      </Group>
      {query.error && <Alert color="red" role="alert">{query.error.message}</Alert>}
      {!bulletin && <Paper withBorder p="md"><CapturePanel photoOnly /></Paper>}
      {query.isPending && <Skeleton h={150} aria-label="جارٍ تحميل الموجز" />}
      {bulletin && (
        <>
          <Group justify="space-between" align="flex-start">
            <div className={classes.bulletinTitle}>
              <Title order={3} dir="auto">{bulletin.name}</Title>
              <Text size="sm" c="dimmed">{number.format(bulletin.total)} صف · النسخة {number.format(bulletin.revision)} · <bdi>{bulletin.design}</bdi></Text>
            </div>
          </Group>
          <BulletinRunStatus id={id} playback={playback.data} supported={bulletin.playbackSupported} statusError={playback.error?.message}>
            <Group gap="xs">
              <Button variant="default" disabled={busy || editing} onClick={() => setPreviewing(true)}>معاينة الموجز</Button>
              {playback.data?.canQueueAfterUrgent && <BulletinAfterUrgentButton bulletin={bulletin} disabled={busy || editing}
                onQueued={() => { void queryClient.invalidateQueries({ queryKey: ['bulletin-schedule', id] }) }} />}
            </Group>
          </BulletinRunStatus>
          <Group gap="xs">
              <Button variant="default" disabled={busy || editing} onClick={() => setScheduling(true)}>المواعيد</Button>
              {availableDesigns.length > 0 && <Button variant="default" disabled={busy || editing || onAir}
                onClick={() => { edit.reset(); setSavedNote(''); setDesignChange({ key: null, revision: bulletin.revision }) }}>
                تغيير التصميم
              </Button>}
              {bulletin.timing && <Button variant="default" leftSection={<IconClock size={16} />} disabled={busy || editing}
                onClick={() => { edit.reset(); setSavedNote(''); setEditingTiming(true) }}>التوقيت</Button>}
              <Button variant="default" leftSection={<IconEdit size={16} />} onClick={() => setNameMode('rename')} disabled={busy || editing}>إعادة تسمية</Button>
              <Button variant="default" leftSection={<IconCopy size={16} />} onClick={() => setNameMode('copy')} disabled={busy || editing}>نسخ</Button>
              <Button variant="subtle" color="red" disabled={busy || editing || onAir || sceneUnconfirmed}
                onClick={() => { setSavedNote(''); setManagement('delete') }}>حذف الموجز</Button>
          </Group>
          {nameMode && <BulletinNameForm mode={nameMode} current={bulletin} onSave={acceptSaved} onCancel={() => setNameMode(null)} />}
          {previewing && <BulletinPreview bulletin={bulletin} playback={playback.data} onClose={() => setPreviewing(false)} />}
          {scheduling && <BulletinSchedule bulletin={bulletin} onClose={() => setScheduling(false)} />}
          {management && <BulletinManagementDialog bulletin={bulletin} operation={management} onClose={() => setManagement(null)}
            onSaved={(result) => {
              setManagement(null)
              void queryClient.invalidateQueries({ queryKey: ['newsroom', 'bulletins'] })
              if (result.operation === 'delete') {
                onBack()
                queryClient.removeQueries({ queryKey: ['bulletin-editor', id] })
              } else {
                setPage(0)
                setSavedNote('أُفرغت صفوف الموجز.')
                void queryClient.invalidateQueries({ queryKey: ['bulletin-editor', id] })
              }
            }} />}
          {sceneImageRow && <BulletinSceneImageDialog id={id} {...sceneImageRow} onClose={() => setSceneImageRow(null)}
            onSaved={(value) => { acceptSaved(value); setSavedNote('حُفظت صورة الصف.') }} />}
          {newRow && <BulletinNewRowDialog title={newRow.title} textFields={textFields} requireText={isBuiltInStory}
            imageOptions={imageOptions} canUpload={!!newRow.uploadField} initialImageChoice={newRow.imageChoice}
            onClose={() => setNewRow(null)} onSaved={(value) => { acceptSaved(value); setSavedNote('أُضيف الصف إلى الموجز.') }}
            saveRow={async ({ values, imageChoice, file }) => {
              if (file && newRow.uploadField) {
                try {
                  return await uploadBulletinPhotoRow({ id, revision: newRow.revision, field: newRow.uploadField, file, values })
                } catch (error) {
                  const code = error instanceof Error ? error.message : 'unknown'
                  throw new Error(messageFor(code), { cause: code })
                }
              }
              const [imageMode, imageSourceRowId] = imageChoice.split(':', 2)
              return applyEdit({ action: 'add', id, revision: newRow.revision, values, imageMode: imageMode || null, imageSourceRowId })
            }} />}
          {photoRow && <BulletinPhotoDialog id={id} {...photoRow}
            otherFields={photoFields.filter(field => field.name !== photoRow.field)}
            onClose={() => setPhotoRow(null)}
            onSaved={(value) => { acceptSaved(value); setSavedNote('حُفظت مرفقات الصف.') }} />}
          {designChange && <Paper withBorder p="md" radius="lg">
            <form onSubmit={(event) => {
              event.preventDefault()
              if (!designChange.key || busy) return
              edit.mutate({ action: 'design', id, revision: designChange.revision, page: bulletin.page, design: designChange.key })
            }}>
              <Stack gap="sm">
                <Text size="sm">يغيّر التصميم أعمدة الجدول. تُحفظ قيم الحقول عند الرجوع إلى التصميم السابق.</Text>
                <Group align="flex-end" gap="sm">
                  <Select<string> label="التصميم الجديد" data={availableDesigns} value={designChange.key} disabled={busy}
                    onChange={(key) => setDesignChange({ ...designChange, key })} autoFocus />
                  <Button type="submit" loading={edit.isPending} disabled={!designChange.key || busy}>حفظ التصميم</Button>
                  <Button variant="subtle" disabled={busy} onClick={() => { setDesignChange(null); edit.reset() }}>إلغاء</Button>
                </Group>
                {edit.error && <Alert color="red" role="alert">{edit.error.message}</Alert>}
              </Stack>
            </form>
          </Paper>}
          {editingTiming && bulletin.timing && (
            <BulletinTimingForm timing={bulletin.timing} busy={edit.isPending} error={edit.error?.message ?? ''}
              onCancel={() => { setEditingTiming(false); edit.reset() }}
              onSave={(timing) => edit.mutate({ action: 'timing', id, revision: bulletin.revision, page: bulletin.page, timing })} />
          )}
          <Group justify="space-between">
            <Title order={4}>صفوف الموجز</Title>
            <Group gap="xs">
              <Button variant="subtle" color="red" disabled={busy || editing || onAir || sceneUnconfirmed || bulletin.total === 0}
                onClick={() => { setSavedNote(''); setManagement('clear') }}>إفراغ الصفوف</Button>
              {textFields.length > 0 && <Button variant="default" leftSection={<IconClipboard size={17} />} disabled={busy || editing}
                onClick={() => { setSavedNote(''); setPasting(true) }}>لصق صفوف</Button>}
              {photoFields.length === 1 && <Button variant={canEnterRow ? 'default' : 'filled'}
                leftSection={<IconFileUpload size={17} />} disabled={busy || editing}
                onClick={() => startNewRow(bulletin.revision, photoFields[0])}>إضافة صف بصورة</Button>}
              {photoFields.length > 1 && <Menu position="bottom-end">
                <Menu.Target>
                  <Button variant={canEnterRow ? 'default' : 'filled'} leftSection={<IconFileUpload size={17} />} disabled={busy || editing}>
                    إضافة صف بصورة
                  </Button>
                </Menu.Target>
                <Menu.Dropdown>
                  <Menu.Label>اختر عمود الصورة</Menu.Label>
                  {photoFields.map((field) => <Menu.Item key={field.name}
                    onClick={() => startNewRow(bulletin.revision, field)}>{field.label}</Menu.Item>)}
                </Menu.Dropdown>
              </Menu>}
              {canEnterRow && <Button leftSection={<IconPlus size={17} />} disabled={busy || editing}
                onClick={() => startNewRow(bulletin.revision)}>إضافة صف</Button>}
            </Group>
          </Group>
          {pasting && <BulletinPaste bulletin={bulletin} onCancel={() => setPasting(false)} onSave={(nextPage) => {
            setPasting(false)
            setSavedNote('أُضيفت الصفوف إلى الموجز.')
            void queryClient.invalidateQueries({ queryKey: ['bulletin-editor', id] })
            setPage(nextPage)
            onSaved(bulletin)
          }} />}
          {onAir && <Text size="sm" c="dimmed">تُستخدم النسخة المحفوظة عند بدء التشغيل التالي.</Text>}
          {savedNote && <Text size="sm" role="status">{savedNote}</Text>}
          {edit.error && !editingTiming && !designChange && <Alert color="red" role="alert">{edit.error.message}</Alert>}
          {!fields.length && <Alert color="gray">تعذّر قراءة حقول التصميم من الجسر.</Alert>}
          {!bulletin.total && !rowEdit && !pasting && <Text c="dimmed">لا توجد صفوف في الموجز.</Text>}
          {(bulletin.total > 0 || rowEdit) && (
            <>
            <Text size="xs" c="dimmed" hiddenFrom="sm">مرّر الجدول أفقيًا للوصول إلى بقية الحقول والإجراءات.</Text>
            <Paper withBorder radius="lg" className={classes.urgentGrid}>
              <form onSubmit={(event) => {
                event.preventDefault()
                if (!rowEdit || !rowCanSave) return
                const [imageMode, imageSourceRowId] = rowEdit.imageChoice.split(':', 2)
                edit.mutate({ action: 'update', id, revision: rowEdit.revision, page: bulletin.page,
                  rowId: rowEdit.row.id, values: rowEdit.values, imageMode: imageMode || null, imageSourceRowId })
              }}>
                <Table.ScrollContainer minWidth={Math.max(520, textFields.length * 165 + 265)} type="native" tabIndex={0} aria-label="جدول إدخال الموجز">
                  <Table verticalSpacing="sm" horizontalSpacing="sm">
                    <Table.Thead>
                      <Table.Tr>
                        <Table.Th scope="col">الترتيب</Table.Th>
                        {fields.map((field) => (
                          <Table.Th scope="col" key={field.name} className={field.kind === 'text' ? classes.urgentCell : undefined}>{field.label}</Table.Th>
                        ))}
                        <Table.Th scope="col">الحالة</Table.Th>
                        <Table.Th scope="col">الإجراءات</Table.Th>
                      </Table.Tr>
                    </Table.Thead>
                    <Table.Tbody>
                      {bulletin.rows.map((row, index) => {
                        const rank = bulletin.page * 20 + index + 1
                        return rowEdit?.row.id === row.id ? editRow(rowEdit, rank) : (
                          <Table.Tr key={row.id}>
                            <Table.Td>{number.format(rank)}</Table.Td>
                            {fields.map((field) => {
                              const canonical = field.name === bulletin.imageField
                              const canUpload = photoFields.includes(field)
                              const title = canonical ? `رفع صورة للصف ${number.format(rank)}`
                                : `رفع صورة إلى ${field.label} للصف ${number.format(rank)}`
                              return (
                                <Table.Td key={field.name}>
                                  {canUpload || canonical ? <Group gap={6} wrap="nowrap">
                                    {cell(row, field)}
                                    {canonical && <Tooltip label="اختيار صورة من مجلد المشهد">
                                      <ActionIcon variant="subtle" aria-label={`اختيار صورة من مجلد المشهد للصف ${number.format(rank)}`} disabled={busy || editing}
                                        onClick={() => { setSavedNote(''); setSceneImageRow({ rowId: row.id, revision: bulletin.revision }) }}>
                                        <IconPhoto size={16} />
                                      </ActionIcon>
                                    </Tooltip>}
                                    {canUpload && <Tooltip label={title}>
                                      <ActionIcon variant="subtle" aria-label={title} disabled={busy || editing}
                                        onClick={() => { setSavedNote(''); setPhotoRow({ rowId: row.id, field: field.name, title, revision: bulletin.revision }) }}>
                                        <IconFileUpload size={16} />
                                      </ActionIcon>
                                    </Tooltip>}
                                  </Group> : cell(row, field)}
                                </Table.Td>
                              )
                            })}
                            <Table.Td>
                              <Button size="compact-xs" variant="subtle" color={row.skipped ? 'gray' : 'teal'} disabled={busy || editing}
                                aria-label={row.skipped ? `تضمين الصف ${rank}` : `تجاوز الصف ${rank}`}
                                onClick={() => rowAction('skip', row, bulletin)}>{row.skipped ? 'مستبعد' : 'مضمّن'}</Button>
                            </Table.Td>
                            <Table.Td>
                              <Group gap={4} wrap="nowrap">
                                <Tooltip label="تعديل"><ActionIcon variant="subtle" aria-label={`تعديل الصف ${rank}`} disabled={(!textFields.length && !bulletin.imageField) || busy || editing} onClick={() => startRow(row, bulletin.revision)}><IconEdit size={16} /></ActionIcon></Tooltip>
                                <Tooltip label="رفع"><ActionIcon variant="subtle" aria-label={`رفع الصف ${rank}`} disabled={rank === 1 || busy || editing} onClick={() => rowAction('up', row, bulletin)}><IconArrowUp size={16} /></ActionIcon></Tooltip>
                                <Tooltip label="خفض"><ActionIcon variant="subtle" aria-label={`خفض الصف ${rank}`} disabled={rank === bulletin.total || busy || editing} onClick={() => rowAction('down', row, bulletin)}><IconArrowDown size={16} /></ActionIcon></Tooltip>
                                <Tooltip label="حذف"><ActionIcon variant="subtle" color="red" aria-label={`حذف الصف ${rank}`} disabled={busy || editing} onClick={() => rowAction('remove', row, bulletin)}><IconTrash size={16} /></ActionIcon></Tooltip>
                              </Group>
                            </Table.Td>
                          </Table.Tr>
                        )
                      })}
                    </Table.Tbody>
                  </Table>
                </Table.ScrollContainer>
                {rowEdit && (
                  <Group justify="flex-end" gap="xs" className={classes.bulletinSave}>
                    <Button variant="subtle" disabled={busy} onClick={() => { setRowEdit(null); edit.reset() }}>إلغاء</Button>
                    <Button type="submit" loading={edit.isPending} disabled={!rowCanSave}>حفظ الصف</Button>
                  </Group>
                )}
              </form>
            </Paper>
            </>
          )}
          {bulletin.pageCount > 1 && <Pagination total={bulletin.pageCount} value={bulletin.page + 1}
            disabled={busy || editing} onChange={(next) => setPage(next - 1)}
            getItemProps={(value) => ({ 'aria-label': `الصفحة ${number.format(value)}` })}
            getControlProps={(control) => ({ 'aria-label': control === 'next' ? 'الصفحة التالية' : 'الصفحة السابقة' })} />}
        </>
      )}
    </Stack>
  )
}
