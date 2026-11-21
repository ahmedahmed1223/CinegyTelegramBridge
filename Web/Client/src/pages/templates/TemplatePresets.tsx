import { ActionIcon, Alert, Button, Group, Modal, Pagination, Skeleton, Stack, Table, Text, Textarea, TextInput, Tooltip } from '@mantine/core'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { IconPencil, IconPlus, IconTrash } from '@tabler/icons-react'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Preset = Schemas['TemplatePresetItem']
type Page = Schemas['TemplatePresetPage']
type Action = 'create' | 'edit' | 'rename' | 'delete'
type Draft = { action: Action; revision: string; preset?: Preset; name: string; values: Record<string, string> }

export function TemplatePresets({ templateKey, templateName, onClose, onChoose }: {
  templateKey: string
  templateName: string
  onClose: () => void
  onChoose: (preset: Preset, revision: string) => void
}) {
  const [page, setPage] = useState(0)
  const [draft, setDraft] = useState<Draft | null>(null)
  const cache = useQueryClient()
  const prefix = ['template-presets', templateKey]
  const path = { key: templateKey }
  const query = useQuery({
    queryKey: [...prefix, page],
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/air/templates/{key}/presets', { params: { path, query: { page } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    refetchOnWindowFocus: false,
    retry: false,
  })
  const save = useMutation({
    mutationFn: async (state: Draft) => {
      const { data, error, response } = await api.POST('/api/air/templates/{key}/presets', {
        params: { path },
        body: { action: state.action, revision: state.revision, index: state.preset?.index ?? null, name: state.name, values: state.values, page },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async (updated: Page) => {
      await cache.invalidateQueries({ queryKey: prefix, refetchType: 'none' })
      cache.setQueryData([...prefix, updated.page], updated)
      setPage(updated.page)
      setDraft(null)
    },
    onError: async (error) => { if (error.message === 'preset_stale') await query.refetch() },
  })
  const data = query.data
  const close = () => { if (!save.isPending) onClose() }
  function start(action: Action, preset?: Preset) {
    if (!data) return
    save.reset()
    setDraft({ action, revision: data.revision, preset, name: preset?.name ?? '', values: { ...preset?.values } })
  }
  const needsName = draft?.action === 'create' || draft?.action === 'rename'
  const needsValues = draft?.action === 'create' || draft?.action === 'edit'
  const stale = !!draft && (save.error?.message === 'preset_stale' || draft.revision !== data?.revision)

  return (
    <Modal opened size="lg" title={`النصوص الجاهزة · ${templateName}`} onClose={close} withCloseButton={!save.isPending}>
      {query.isPending && <Stack aria-label="جارٍ تحميل النصوص الجاهزة"><Skeleton h={32} /><Skeleton h={54} /></Stack>}
      {query.error && <Alert color="red" role="alert">
        <Group justify="space-between">
          <Text size="sm">{messageFor(query.error.message)}</Text>
          <Button variant="subtle" size="compact-sm" onClick={() => void query.refetch()}>إعادة المحاولة</Button>
        </Group>
      </Alert>}
      {data && !draft && <Stack gap="md">
        {data.canManage && <Group justify="flex-end"><Button variant="light" leftSection={<IconPlus size={16} />}
          onClick={() => start('create')}>إضافة نص جاهز</Button></Group>}
        {data.items.length === 0 ? <Text c="dimmed">لا توجد نصوص جاهزة لهذا القالب.</Text>
          : <Table withRowBorders verticalSpacing="sm">
            <Table.Thead><Table.Tr><Table.Th scope="col">الاسم</Table.Th><Table.Th scope="col">الإجراءات</Table.Th></Table.Tr></Table.Thead>
            <Table.Tbody>{data.items.map(preset => <Table.Tr key={preset.index}>
              <Table.Td><Text size="sm" fw={600} dir="auto" style={{ overflowWrap: 'anywhere' }}>{preset.name}</Text></Table.Td>
              <Table.Td>
                <Group gap={6}>
                  <Button size="compact-sm" variant="light" aria-label={`استخدام ${preset.name}`}
                    onClick={() => onChoose(preset, data.revision)}>استخدام</Button>
                  {data.canManage && <>
                    <Tooltip label="تعديل القيم"><ActionIcon variant="subtle" aria-label={`تعديل قيم ${preset.name}`}
                      onClick={() => start('edit', preset)}><IconPencil size={16} /></ActionIcon></Tooltip>
                    <Button size="compact-xs" variant="subtle" aria-label={`تسمية ${preset.name}`}
                      onClick={() => start('rename', preset)}>تسمية</Button>
                    <Tooltip label="حذف"><ActionIcon variant="subtle" color="red" aria-label={`حذف ${preset.name}`}
                      onClick={() => start('delete', preset)}><IconTrash size={16} /></ActionIcon></Tooltip>
                  </>}
                </Group>
              </Table.Td>
            </Table.Tr>)}</Table.Tbody>
          </Table>}
        {data.pageCount > 1 && <Pagination total={data.pageCount} value={data.page + 1} onChange={next => setPage(next - 1)} />}
      </Stack>}
      {data && draft && <form onSubmit={event => {
        event.preventDefault()
        if (!save.isPending && !stale) save.mutate(draft)
      }}>
        <Stack gap="md">
          {needsName && <TextInput label="اسم النص الجاهز" required maxLength={80} value={draft.name} disabled={save.isPending}
            onChange={event => setDraft({ ...draft, name: event.currentTarget.value })} />}
          {needsValues && data.fields.map(field => {
            const hasStoredValue = draft.preset?.hiddenFields.includes(field.name)
            const input = {
              label: field.label, value: draft.values[field.name] ?? '', disabled: save.isPending, dir: 'auto' as const,
              onChange: (event: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
                setDraft({ ...draft, values: { ...draft.values, [field.name]: event.currentTarget.value } }),
            }
            return field.sensitive
              ? <TextInput key={field.name} type="password" autoComplete="off" {...input}
                description={hasStoredValue ? 'اترك الحقل دون تعديل للاحتفاظ بالقيمة المحفوظة.' : undefined} />
              : <Textarea key={field.name} autosize minRows={2} maxRows={5} {...input} />
          })}
          {draft.action === 'delete' && <Text>سيُحذف «{draft.preset?.name}» من النصوص الجاهزة لهذا القالب.</Text>}
          {(stale || save.error) && <Alert color="orange" role="alert">{messageFor(stale ? 'preset_stale' : save.error!.message)}</Alert>}
          <Group justify="flex-end" gap="xs">
            <Button variant="default" disabled={save.isPending} onClick={() => setDraft(null)}>رجوع</Button>
            <Button type="submit" color={draft.action === 'delete' ? 'red.9' : undefined} loading={save.isPending}
              disabled={stale || (needsName && !draft.name.trim())}>{draft.action === 'delete' ? 'تأكيد الحذف' : 'حفظ النص الجاهز'}</Button>
          </Group>
        </Stack>
      </form>}
    </Modal>
  )
}
