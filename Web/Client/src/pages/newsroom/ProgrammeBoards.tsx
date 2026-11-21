import {
  ActionIcon, Alert, Badge, Button, Group, NativeSelect, Pagination, Paper, Skeleton,
  Stack, Table, Text, Textarea, TextInput, Title, Tooltip,
} from '@mantine/core'
import { modals } from '@mantine/modals'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { IconArrowDown, IconArrowRight, IconArrowUp, IconEdit, IconPlayerPlay, IconPlayerStop, IconPlus, IconRefresh, IconTrash } from '@tabler/icons-react'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { ProgrammeBoardPaste } from './RowPaste'
import { ProgrammeBoardCorrection } from './ProgrammeBoardCorrection'
import { ProgrammeBoardPlayout, type BoardAirResult, type BoardAirTarget } from './ProgrammeBoardPlayout'
import classes from './NewsroomPage.module.css'

type Board = Schemas['ProgrammeBoardEditor']
type Row = Schemas['ProgrammeBoardRow']
type Edit = Pick<Schemas['ProgrammeBoardEditRequest'], 'action'> & Partial<Schemas['ProgrammeBoardEditRequest']>
const number = new Intl.NumberFormat('ar')
const roles = [
  { value: 'all', label: 'جميع المشغّلين' },
  { value: 'admin', label: 'المشرفون' },
  { value: 'owner', label: 'المالك فقط' },
]
const listKey = ['programme-boards']
const editorKey = (id: string, page: number) => ['programme-board', id, page]

async function writeBoard(body: Edit) {
  const { data, error, response } = await api.POST('/api/content/boards/editor', {
    body: { id: null, revision: null, page: null, rowId: null, values: null, name: null, template: null, role: null, ...body },
  })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

function CreateBoard({ onCancel, onCreated }: { onCancel: () => void; onCreated: (board: Board) => void }) {
  const [name, setName] = useState('')
  const [template, setTemplate] = useState('')
  const templates = useQuery({
    queryKey: ['programme-board-templates'],
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/boards/templates', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data.templates
    },
  })
  const create = useMutation({ mutationFn: writeBoard, onSuccess: onCreated })
  return <Paper withBorder p="md" radius="lg">
    <form onSubmit={(event) => {
      event.preventDefault()
      if (name.trim() && template && !create.isPending) create.mutate({ action: 'create', name: name.trim(), template })
    }}>
      <Stack gap="sm">
        <Group grow align="flex-start">
          <TextInput label="اسم اللوحة" value={name} onChange={(event) => setName(event.currentTarget.value)}
            maxLength={60} disabled={create.isPending} required autoFocus />
          <NativeSelect label="قالب البرنامج" value={template} onChange={(event) => setTemplate(event.currentTarget.value)}
            data={[{ value: '', label: templates.isPending ? 'جارٍ تحميل القوالب' : 'اختر قالبًا', disabled: true },
              ...(templates.data ?? []).map(({ key, label }) => ({ value: key, label }))]}
            disabled={!templates.data?.length || create.isPending} required />
        </Group>
        {templates.isSuccess && !templates.data.length && <Text size="sm" c="dimmed">لا توجد قوالب برامج تحتوي على حقول نصية.</Text>}
        {(create.error || templates.error) && <Alert color="red" role="alert">
          {messageFor((create.error ?? templates.error)?.message ?? 'unknown')}
        </Alert>}
        <Group>
          <Button type="submit" loading={create.isPending} disabled={!name.trim() || !template}>إنشاء اللوحة</Button>
          <Button type="button" variant="subtle" disabled={create.isPending} onClick={onCancel}>إلغاء</Button>
        </Group>
      </Stack>
    </form>
  </Paper>
}

export function ProgrammeBoards() {
  const [page, setPage] = useState(0)
  const [open, setOpen] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)
  const cache = useQueryClient()
  const query = useQuery({
    queryKey: [...listKey, page],
    enabled: !open,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/boards', { params: { query: { page } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  if (open) return <ProgrammeBoard key={open} id={open} onBack={() => setOpen(null)} />
  const boards = query.data
  return <Stack gap="md">
    <Group justify="space-between">
      <Title order={2}>لوحات البرامج</Title>
      <Group gap="xs">
        <Button variant="default" leftSection={<IconRefresh size={16} />} loading={query.isFetching} onClick={() => void query.refetch()}>تحديث</Button>
        {boards?.canCreate && <Button leftSection={<IconPlus size={16} />} disabled={creating} onClick={() => setCreating(true)}>إنشاء لوحة</Button>}
      </Group>
    </Group>
    {query.isPending && <Skeleton h={68} aria-label="جارٍ تحميل لوحات البرامج" />}
    {query.error && <Alert color={query.error.message === 'content_disabled' ? 'gray' : 'red'} role="alert">
      {query.error.message === 'content_disabled' ? 'لوحات البرامج معطّلة في إعدادات الجسر.' : messageFor(query.error.message)}
    </Alert>}
    {creating && boards?.canCreate && <CreateBoard onCancel={() => setCreating(false)} onCreated={(board) => {
      cache.setQueryData(editorKey(board.id, board.page), board)
      void cache.invalidateQueries({ queryKey: listKey })
      setCreating(false)
      setOpen(board.id)
    }} />}
    {boards && !boards.total && !creating && <Text c="dimmed">لا توجد لوحات برامج محفوظة.</Text>}
    {!!boards?.items.length && <Paper radius="lg" withBorder>
      <ul className={classes.list}>
        {boards.items.map((board) => <li key={board.id} className={classes.row}>
          <Group justify="space-between">
            <div className={classes.entry}>
              <Text fw={600} dir="auto" className={classes.headline}>{board.name}</Text>
              <Text size="sm" c="dimmed">{number.format(board.rows)} صف</Text>
            </div>
            <Button variant="light" aria-label={`فتح لوحة ${board.name}`} onClick={() => { setCreating(false); setOpen(board.id) }}>فتح اللوحة</Button>
          </Group>
        </li>)}
      </ul>
    </Paper>}
    {boards && boards.pageCount > 1 && <Pagination total={boards.pageCount} value={boards.page + 1} onChange={(next) => setPage(next - 1)} />}
  </Stack>
}

function ProgrammeBoard({ id, onBack }: { id: string; onBack: () => void }) {
  const [page, setPage] = useState(0)
  const [draft, setDraft] = useState<{ rowId?: string; revision: number; values: Record<string, string> } | null>(null)
  const [role, setRole] = useState<{ value: string; revision: number } | null>(null)
  const [pasting, setPasting] = useState(false)
  const [air, setAir] = useState<BoardAirTarget | null>(null)
  const [correction, setCorrection] = useState<Row | null>(null)
  const [airNotice, setAirNotice] = useState<{ text: string; warning: boolean } | null>(null)
  const [saved, setSaved] = useState(false)
  const cache = useQueryClient()
  const query = useQuery({
    queryKey: editorKey(id, page),
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/boards/editor', { params: { query: { id, page } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    retry: false,
    refetchOnWindowFocus: false,
    refetchInterval: 10_000,
  })
  function acceptSaved(board: Board) {
    cache.setQueryData(editorKey(id, board.page), board)
    void cache.invalidateQueries({ queryKey: listKey })
    setPage(board.page)
    setDraft(null)
    setRole(null)
    setPasting(false)
    setSaved(true)
  }
  const write = useMutation({ mutationFn: writeBoard, onSuccess: acceptSaved })
  const removeBoard = useMutation({
    mutationFn: async ({ boardId, revision }: { boardId: string; revision: number }) => {
      const { error, response } = await api.DELETE('/api/content/boards/{id}', {
        params: { path: { id: boardId }, query: { revision } },
      })
      if (!response.ok) throw new Error(errorCode(error, response))
    },
    onSuccess: () => {
      void cache.invalidateQueries({ queryKey: listKey })
      cache.removeQueries({ queryKey: ['programme-board', id] })
      onBack()
    },
  })
  const board = query.data
  const busy = write.isPending || removeBoard.isPending || query.isFetching
  const editing = !!draft || !!role || pasting
  const blocked = busy || editing
  const liveRow = board?.rows.find(row => row.id === board.liveRowId)
  function acceptAirChange(action: BoardAirTarget['action'], result?: BoardAirResult) {
    if (result) {
      cache.setQueriesData<Board>({ queryKey: ['programme-board', id] },
        (cached) => cached && { ...cached, liveRowId: result.liveRowId })
      if (action === 'hide') setAirNotice({ text: 'أُخفي صف البرنامج.', warning: false })
      else if (action === 'update') setAirNotice({ text: 'أُرسل تصحيح النص إلى المشهد المعروض.', warning: false })
      else if (!result.liveRowId) setAirNotice({ text: 'أُرسل أمر العرض وتعذّر تأكيد المشهد. راجع حالة الطبقة.', warning: true })
      else if (result.autoHideFailed) setAirNotice({ text: 'عُرض الصف وتعذّر ضبط الإخفاء التلقائي.', warning: true })
      else setAirNotice({ text: 'عُرض صف البرنامج.', warning: false })
      setAir(null)
      setCorrection(null)
    }
    void cache.invalidateQueries({ queryKey: ['programme-board', id] })
  }
  function startRow(row?: Row) {
    if (!board) return
    write.reset()
    setSaved(false)
    setDraft({ rowId: row?.id, revision: board.revision, values: Object.fromEntries(
      board.fields.map(({ name }) => [name, row?.values[name] ?? '']),
    ) })
  }

  function changeRow(action: string, row: Row) {
    if (!board) return
    const save = () => {
      setSaved(false)
      write.mutate({ id, page: board.page, revision: board.revision, action, rowId: row.id })
    }
    if (action !== 'remove') { save(); return }
    modals.openConfirmModal({
      title: 'حذف صف من اللوحة',
      children: <Text>سيُحذف الصف {number.format(row.number)} من «{board.name}».</Text>,
      labels: { confirm: 'حذف الصف', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: save,
    })
  }

  function confirmBoardDeletion() {
    if (!board) return
    removeBoard.reset()
    modals.openConfirmModal({
      title: 'حذف لوحة البرنامج',
      children: <Text dir="auto">ستُحذف لوحة «{board.name}» مع صفوفها المحفوظة ({number.format(board.total)}).</Text>,
      labels: { confirm: 'حذف اللوحة', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: () => removeBoard.mutate({ boardId: board.id, revision: board.revision }),
    })
  }

  function editRow(rank?: number, key = 'draft') {
    if (!board || !draft) return null
    return <Table.Tr key={key}>
      <Table.Td>{rank === undefined ? 'جديد' : number.format(rank)}</Table.Td>
      {board.fields.map(({ name, label }, index) => <Table.Td key={name} className={classes.urgentCell}>
        <Textarea aria-label={label} dir="auto" minRows={2} autosize maxRows={5} maxLength={board.maxFieldLength}
          autoFocus={index === 0} disabled={write.isPending} value={draft.values[name] ?? ''}
          onChange={(event) => setDraft({ ...draft, values: { ...draft.values, [name]: event.currentTarget.value } })} />
      </Table.Td>)}
      <Table.Td colSpan={2}><Group gap="xs" wrap="nowrap">
        <Button type="submit" loading={write.isPending} disabled={busy || (!draft.rowId && !Object.values(draft.values).some((value) => value.trim()))}>حفظ الصف</Button>
        <Button type="button" variant="subtle" disabled={write.isPending} onClick={() => { setDraft(null); write.reset() }}>إلغاء</Button>
      </Group></Table.Td>
    </Table.Tr>
  }

  return <Stack gap="md">
    <Group justify="space-between">
      <Button variant="subtle" leftSection={<IconArrowRight size={16} />} onClick={onBack} disabled={write.isPending || removeBoard.isPending}>لوحات البرامج</Button>
      <Button variant="default" leftSection={<IconRefresh size={16} />} disabled={editing || write.isPending || removeBoard.isPending}
        loading={query.isFetching} onClick={() => { setSaved(false); write.reset(); removeBoard.reset(); void query.refetch() }}>تحديث</Button>
    </Group>
    {query.isPending && <Skeleton h={82} aria-label="جارٍ تحميل لوحة البرنامج" />}
    {query.error && <Alert color="red" role="alert">{messageFor(query.error.message)}</Alert>}
    {board && <>
      <Group justify="space-between" align="flex-start">
        <div>
          <Title order={2} dir="auto">{board.name}</Title>
          <Text size="sm" c="dimmed">تحرير النصوص: {roles.find(({ value }) => value === board.editRole)?.label ?? 'بحسب الصلاحية'}</Text>
        </div>
        <Group gap="xs">
          {board.canManage && <Button variant="default" disabled={blocked} onClick={() => {
            setSaved(false); write.reset(); setRole({ value: board.editRole, revision: board.revision })
          }}>صلاحية التحرير</Button>}
          {board.canEdit && board.fields.length > 0 && <Button variant="default" disabled={blocked} onClick={() => {
            setSaved(false); write.reset(); setPasting(true)
          }}>لصق صفوف</Button>}
          {board.canEdit && board.fields.length > 0 && <Button disabled={blocked} leftSection={<IconPlus size={16} />} onClick={() => startRow()}>إضافة صف</Button>}
          {board.canManage && <Button variant="subtle" color="red" disabled={blocked} loading={removeBoard.isPending}
            leftSection={<IconTrash size={16} />} onClick={confirmBoardDeletion}>حذف اللوحة</Button>}
        </Group>
      </Group>
      {pasting && <ProgrammeBoardPaste board={board} onSave={(nextPage) => {
        void cache.invalidateQueries({ queryKey: ['programme-board', id] })
        void cache.invalidateQueries({ queryKey: listKey })
        setPage(nextPage)
        setPasting(false)
        setSaved(true)
      }} onCancel={() => setPasting(false)} />}
      {role && <Paper withBorder p="md" radius="lg">
        <form onSubmit={(event) => {
          event.preventDefault()
          if (role.value !== board.editRole && !busy) write.mutate({ action: 'role', id, page, revision: role.revision, role: role.value })
        }}>
          <Group align="flex-end">
            <NativeSelect label="من يستطيع تحرير النصوص؟" data={roles} value={role.value} disabled={write.isPending}
              onChange={(event) => setRole({ ...role, value: event.currentTarget.value })} />
            <Button type="submit" loading={write.isPending} disabled={busy || role.value === board.editRole}>حفظ الصلاحية</Button>
            <Button type="button" variant="subtle" disabled={busy} onClick={() => { setRole(null); write.reset() }}>إلغاء</Button>
          </Group>
        </form>
      </Paper>}
      {!!board.sceneMedia.length && <Text size="sm" c="dimmed">وسائط من القالب: {board.sceneMedia.join('، ')}</Text>}
      {!board.fields.length && <Alert color="orange">لا يحتوي قالب اللوحة الآن على حقول نصية قابلة للتحرير.</Alert>}
      {board.liveRowId && <Group justify="space-between">
        <Badge color="red" variant="light">صف من اللوحة على الهواء</Badge>
        <Group gap="xs">
          {board.canEdit && liveRow && <Button variant="light" size="compact-sm" leftSection={<IconEdit size={16} />}
            disabled={blocked || !board.fields.length} onClick={() => { setAirNotice(null); setCorrection(liveRow) }}>تصحيح على الهواء</Button>}
          <Button color="red" variant="light" size="compact-sm" leftSection={<IconPlayerStop size={16} />}
            disabled={blocked} onClick={() => {
              setAirNotice(null)
              setAir({ action: 'hide', rowId: board.liveRowId!, revision: board.revision })
            }}>مراجعة الإخفاء</Button>
        </Group>
      </Group>}
      {airNotice && <Alert role="status" color={airNotice.warning ? 'orange' : 'teal'}>{airNotice.text}</Alert>}
      {saved && <Text size="sm" role="status">حُفظت التغييرات.</Text>}
      {write.error && <Alert color={write.error.message === 'board_stale' ? 'orange' : 'red'} role="alert">{messageFor(write.error.message)}</Alert>}
      {removeBoard.error && <Alert color={removeBoard.error.message === 'board_stale' ? 'orange' : 'red'} role="alert">
        {removeBoard.error.message === 'board_stale' ? 'تغيّرت اللوحة بعد فتحها. حدّثها وراجع عدد الصفوف قبل تأكيد الحذف.' : messageFor(removeBoard.error.message)}
      </Alert>}
      {(board.total > 0 || draft) && <Text size="xs" c="dimmed" hiddenFrom="sm">مرّر الجدول أفقيًا للوصول إلى بقية الحقول والإجراءات.</Text>}
      {(!board.total && !draft) ? <Text c="dimmed">لا توجد صفوف في اللوحة.</Text> : <Paper withBorder radius="lg" className={classes.urgentGrid}>
        <form onSubmit={(event) => {
          event.preventDefault()
          if (!draft || busy) return
          write.mutate({ action: draft.rowId ? 'update' : 'add', id, page, revision: draft.revision, rowId: draft.rowId, values: draft.values })
        }}>
          <Table.ScrollContainer minWidth={Math.max(490, board.fields.length * 165 + 225)} type="native" tabIndex={0} aria-label="جدول محتوى البرنامج">
            <Table verticalSpacing="sm">
              <Table.Thead><Table.Tr>
                <Table.Th scope="col">الصف</Table.Th>
                {board.fields.map(({ name, label }) => <Table.Th key={name} scope="col" className={classes.urgentCell}>{label}</Table.Th>)}
                <Table.Th scope="col">الحالة</Table.Th>
                <Table.Th scope="col">الإجراءات</Table.Th>
              </Table.Tr></Table.Thead>
              <Table.Tbody>
                {draft && !draft.rowId && editRow()}
                {board.rows.map((row) => draft?.rowId === row.id ? editRow(row.number, row.id) : <Table.Tr key={row.id}>
                  <Table.Td><Stack gap={4} align="start">
                    <Text size="sm">{number.format(row.number)}</Text>
                    {board.liveRowId === row.id ? <Badge color="red" variant="light" size="xs">على الهواء</Badge>
                      : <Button size="compact-xs" variant="light" leftSection={<IconPlayerPlay size={13} />}
                        aria-label={`مراجعة عرض الصف ${number.format(row.number)}`}
                        disabled={blocked || !row.enabled || !board.fields.length} onClick={() => {
                          setAirNotice(null)
                          setAir({ action: 'show', rowId: row.id, revision: board.revision })
                        }}>عرض</Button>}
                  </Stack></Table.Td>
                  {board.fields.map(({ name }) => <Table.Td key={name} className={classes.urgentCell}>
                    <Text size="sm" dir="auto" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{row.values[name] || '—'}</Text>
                  </Table.Td>)}
                  <Table.Td><Button variant="subtle" size="compact-xs" color={row.enabled ? 'teal' : 'gray'} disabled={blocked}
                    aria-label={`${row.enabled ? 'تعطيل' : 'تفعيل'} الصف ${number.format(row.number)}`}
                    onClick={() => changeRow(row.enabled ? 'disable' : 'enable', row)}>{row.enabled ? 'مفعّل' : 'معطّل'}</Button></Table.Td>
                  <Table.Td><Group gap={4} wrap="nowrap">
                    <Tooltip label="رفع الصف"><ActionIcon variant="subtle" aria-label={`رفع الصف ${number.format(row.number)}`}
                      disabled={blocked || row.number === 1} onClick={() => changeRow('up', row)}><IconArrowUp size={16} /></ActionIcon></Tooltip>
                    <Tooltip label="خفض الصف"><ActionIcon variant="subtle" aria-label={`خفض الصف ${number.format(row.number)}`}
                      disabled={blocked || row.number === board.total} onClick={() => changeRow('down', row)}><IconArrowDown size={16} /></ActionIcon></Tooltip>
                    {board.canEdit && <>
                      <Tooltip label="تحرير الصف"><ActionIcon variant="subtle" aria-label={`تحرير الصف ${number.format(row.number)}`}
                        disabled={blocked || !board.fields.length} onClick={() => startRow(row)}><IconEdit size={16} /></ActionIcon></Tooltip>
                      <Tooltip label="حذف الصف"><ActionIcon color="red" variant="subtle" aria-label={`حذف الصف ${number.format(row.number)}`}
                        disabled={blocked} onClick={() => changeRow('remove', row)}><IconTrash size={16} /></ActionIcon></Tooltip>
                    </>}
                  </Group></Table.Td>
                </Table.Tr>)}
              </Table.Tbody>
            </Table>
          </Table.ScrollContainer>
        </form>
      </Paper>}
      {board.pageCount > 1 && <Pagination disabled={blocked} total={board.pageCount} value={board.page + 1} onChange={(next) => setPage(next - 1)} />}
      {air && <ProgrammeBoardPlayout id={id} target={air} onClose={() => setAir(null)} onChanged={(result) => acceptAirChange(air.action, result)} />}
      {correction && <ProgrammeBoardCorrection board={board} row={correction} onClose={() => setCorrection(null)}
        onChanged={(result) => acceptAirChange('update', result)} />}
    </>}
  </Stack>
}
