import {
  ActionIcon, Alert, Badge, Button, Group, Pagination, Paper, Select, Skeleton, Stack,
  Table, Text, Textarea, TextInput, Title, Tooltip,
} from '@mantine/core'
import { modals } from '@mantine/modals'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { IconArrowDown, IconArrowRight, IconArrowUp, IconCopy, IconEdit, IconPlus, IconRefresh, IconTrash } from '@tabler/icons-react'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import classes from './NewsroomPage.module.css'

type Bulletin = Schemas['BulletinEditor']
type Row = Schemas['BulletinRow']
type EditRequest = Pick<Schemas['BulletinEditRequest'], 'action'> & Partial<Schemas['BulletinEditRequest']>
type EditRow = { row: Row | null; revision: number; values: Record<string, string> }
type NameAction = 'create' | 'rename' | 'copy'
const number = new Intl.NumberFormat('ar')
const names = { create: 'إنشاء موجز', rename: 'إعادة تسمية', copy: 'نسخ الموجز' }

async function applyEdit(request: EditRequest) {
  const { data, error, response } = await api.POST('/api/content/bulletins/editor', {
    body: { id: null, revision: null, page: null, rowId: null, name: null, design: null, values: null, ...request },
  })
  if (!data) throw new Error(error?.message || messageFor(errorCode(error, response)))
  return data
}

export function BulletinNameForm({ mode, current, onCancel, onSave }: {
  mode: NameAction
  current?: Bulletin
  onCancel: () => void
  onSave: (value: Bulletin) => void
}) {
  const [name, setName] = useState(mode === 'rename' ? current?.name ?? '' : '')
  const [design, setDesign] = useState<string | null>(null)
  const designs = useQuery({
    queryKey: ['bulletin-designs'],
    enabled: mode === 'create',
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/bulletins/designs', { signal })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data.designs.map((item) => ({ value: item.key, label: item.label }))
    },
  })
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
  function acceptSaved(value: Bulletin) {
    queryClient.setQueryData(bulletinKey(value.id, value.page), value)
    if (value.id === id) {
      setPage(value.page)
      setSavedNote('حُفظ الموجز.')
    }
    setRowEdit(null)
    setNameMode(null)
    onSaved(value)
  }
  const edit = useMutation({ mutationFn: applyEdit, onSuccess: acceptSaved })
  const bulletin = query.data
  const busy = edit.isPending || query.isFetching
  const editing = !!rowEdit || !!nameMode
  const fields = bulletin?.fields ?? []
  const textFields = fields.filter((field) => field.kind === 'text')

  function startRow(row: Row | null, revision: number) {
    edit.reset()
    setSavedNote('')
    setRowEdit({ row, revision, values: Object.fromEntries(textFields.map((field) => [field.name, row?.values[field.name] ?? ''])) })
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

  function cell(row: Row | null, field: Bulletin['fields'][number]) {
    if (field.kind === 'media') {
      return row?.media.includes(field.name) ? <Text size="sm">مرفق</Text> : <Text size="sm" c="dimmed">—</Text>
    }
    return <Text size="sm" dir="auto" className={classes.bulletinCellText}>{row?.values[field.name] || '—'}</Text>
  }

  function editRow(active: EditRow, rank?: number) {
    return (
      <Table.Tr key={active.row?.id ?? 'new'} className={classes.editRow}>
        <Table.Td>{rank == null ? 'جديد' : number.format(rank)}</Table.Td>
        {fields.map((field) => (
          <Table.Td key={field.name} className={field.kind === 'text' ? classes.urgentCell : undefined}>
            {field.kind === 'text' ? (
              <Textarea aria-label={field.label} dir="auto" autosize minRows={2} maxRows={6} maxLength={4096}
                autoFocus={field === textFields[0]} disabled={busy} value={active.values[field.name] ?? ''}
                onChange={(event) => setRowEdit({ ...active, values: { ...active.values, [field.name]: event.currentTarget.value } })} />
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
      {query.isPending && <Skeleton h={150} aria-label="جارٍ تحميل الموجز" />}
      {bulletin && (
        <>
          <Group justify="space-between" align="flex-start">
            <div className={classes.bulletinTitle}>
              <Group gap="xs">
                <Title order={3} dir="auto">{bulletin.name}</Title>
                {bulletin.onAir && <Badge color="red" variant="light">على الهواء</Badge>}
              </Group>
              <Text size="sm" c="dimmed">{number.format(bulletin.total)} صف · النسخة {number.format(bulletin.revision)} · <bdi>{bulletin.design}</bdi></Text>
            </div>
            <Group gap="xs">
              <Button variant="default" leftSection={<IconEdit size={16} />} onClick={() => setNameMode('rename')} disabled={busy || editing}>إعادة تسمية</Button>
              <Button variant="default" leftSection={<IconCopy size={16} />} onClick={() => setNameMode('copy')} disabled={busy || editing}>نسخ</Button>
            </Group>
          </Group>
          {nameMode && <BulletinNameForm mode={nameMode} current={bulletin} onSave={acceptSaved} onCancel={() => setNameMode(null)} />}
          {!bulletin.playbackSupported && <Alert color="gray">التشغيل على الهواء غير متاح لهذا التصميم في هذا الإصدار.</Alert>}
          <Group justify="space-between">
            <Title order={4}>صفوف الموجز</Title>
            <Button leftSection={<IconPlus size={17} />} disabled={!textFields.length || busy || editing}
              onClick={() => startRow(null, bulletin.revision)}>إضافة صف</Button>
          </Group>
          {bulletin.onAir && <Text size="sm" c="dimmed">تُستخدم النسخة المحفوظة عند بدء التشغيل التالي.</Text>}
          {savedNote && <Text size="sm" role="status">{savedNote}</Text>}
          {edit.error && <Alert color="red" role="alert">{edit.error.message}</Alert>}
          {!fields.length && <Alert color="gray">تعذّر قراءة حقول التصميم من الجسر.</Alert>}
          {!bulletin.total && !rowEdit && <Text c="dimmed">لا توجد صفوف في الموجز. اختر «إضافة صف» لبدء الإدخال.</Text>}
          {(bulletin.total > 0 || rowEdit) && (
            <>
            <Text size="xs" c="dimmed" hiddenFrom="sm">مرّر الجدول أفقيًا للوصول إلى بقية الحقول والإجراءات.</Text>
            <Paper withBorder radius="lg" className={classes.urgentGrid}>
              <form onSubmit={(event) => {
                event.preventDefault()
                if (!rowEdit || busy) return
                edit.mutate({ action: rowEdit.row ? 'update' : 'add', id, revision: rowEdit.revision, page: bulletin.page, rowId: rowEdit.row?.id, values: rowEdit.values })
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
                      {rowEdit && !rowEdit.row && editRow(rowEdit)}
                      {bulletin.rows.map((row, index) => {
                        const rank = bulletin.page * 20 + index + 1
                        return rowEdit?.row?.id === row.id ? editRow(rowEdit, rank) : (
                          <Table.Tr key={row.id}>
                            <Table.Td>{number.format(rank)}</Table.Td>
                            {fields.map((field) => <Table.Td key={field.name}>{cell(row, field)}</Table.Td>)}
                            <Table.Td>
                              <Button size="compact-xs" variant="subtle" color={row.skipped ? 'gray' : 'teal'} disabled={busy || editing}
                                aria-label={row.skipped ? `تضمين الصف ${rank}` : `تجاوز الصف ${rank}`}
                                onClick={() => rowAction('skip', row, bulletin)}>{row.skipped ? 'مستبعد' : 'مضمّن'}</Button>
                            </Table.Td>
                            <Table.Td>
                              <Group gap={4} wrap="nowrap">
                                <Tooltip label="تعديل"><ActionIcon variant="subtle" aria-label={`تعديل الصف ${rank}`} disabled={!textFields.length || busy || editing} onClick={() => startRow(row, bulletin.revision)}><IconEdit size={16} /></ActionIcon></Tooltip>
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
                    <Button type="submit" loading={edit.isPending} disabled={query.isFetching}>حفظ الصف</Button>
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
