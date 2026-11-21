import { ActionIcon, Alert, Button, Checkbox, Group, Modal, NumberInput, SimpleGrid, Skeleton, Stack, Table, Text, TextInput } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMediaQuery } from '@mantine/hooks'
import { IconPlus, IconTrash } from '@tabler/icons-react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Definition = Schemas['TemplateDefinitionView']
type Changes = Schemas['TemplateDefinitionChanges']
type Command = Schemas['TemplateDefinitionCommand']
type Review = { mode: 'edit' | 'delete'; preview: Schemas['TemplateDefinitionPreview']; changes?: Changes }
type Field = Schemas['TemplateDefinitionFieldChange'] & { id: string }

async function requestDefinition(key: string, command: Pick<Command, 'action'> & Partial<Command>, signal?: AbortSignal) {
  const { data, error, response } = await api.POST('/api/air/templates/{key}/definition', {
    params: { path: { key } },
    body: { revision: '', review: '', ...command },
    signal,
  })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

export function TemplateDefinitionEditor({ templateKey, onClose }: { templateKey: string; onClose: () => void }) {
  const result = useQuery({
    queryKey: ['template-definition', templateKey],
    queryFn: ({ signal }) => requestDefinition(templateKey, { action: 'inspect' }, signal),
    retry: false,
    refetchOnWindowFocus: false,
    gcTime: 0,
  })
  if (result.data?.definition) {
    return <DefinitionForm key={result.data.definition.revision} definition={result.data.definition}
      onClose={onClose} onReload={() => void result.refetch()} />
  }
  return <Modal opened title="إدارة القالب" onClose={onClose}>
    {result.error ? <Alert color="orange" role="alert">
      <Stack gap="xs" align="flex-start">
        {messageFor(result.error.message)}
        <Button variant="default" size="xs" onClick={() => void result.refetch()}>إعادة التحميل</Button>
      </Stack>
    </Alert> : <Skeleton h={120} />}
  </Modal>
}

function DefinitionForm({ definition, onClose, onReload }: { definition: Definition; onClose: () => void; onReload: () => void }) {
  const cache = useQueryClient()
  const compact = useMediaQuery('(max-width: 44em)')
  const [description, setDescription] = useState(definition.description)
  const [category, setCategory] = useState(definition.category)
  const [layer, setLayer] = useState<number | string>(definition.layer)
  const [fields, setFields] = useState<Field[]>(() =>
    definition.fields.map(({ name, label, maxLength, required, sensitive }) =>
      ({ id: crypto.randomUUID(), name, label, maxLength, required, sensitive })))
  const [review, setReview] = useState<Review | null>(null)
  const checking = useMutation({
    mutationFn: async ({ mode, changes }: Pick<Review, 'mode' | 'changes'>) => {
      const reply = await requestDefinition(definition.key, { action: `review-${mode}`, revision: definition.revision, changes })
      if (!reply.preview) throw new Error('scene_registry_failed')
      return { mode, changes, preview: reply.preview }
    },
    onSuccess: setReview,
  })
  const saving = useMutation({
    mutationFn: (decision: Review) => requestDefinition(definition.key, {
      action: decision.mode, revision: definition.revision, changes: decision.changes, review: decision.preview.review,
    }),
    onSuccess: async (_, decision) => {
      await Promise.all([
        cache.invalidateQueries({ queryKey: ['templates'] }),
        cache.invalidateQueries({ queryKey: ['template-presets', definition.key] }),
      ])
      notifications.show({ color: 'teal', message: decision.mode === 'delete' ? 'حُذف القالب من السجل المشترك.' : 'حُفظ تعريف القالب.' })
      onClose()
    },
  })
  const pending = checking.isPending || saving.isPending
  const error = saving.error ?? checking.error
  const lockedNames = definition.presetCount > 0
  const noChanges = !!review?.preview.after && JSON.stringify(review.preview.before) === JSON.stringify(review.preview.after)
  function changeField(id: string, changes: Partial<Omit<Field, 'id'>>) {
    setFields(items => items.map(field => field.id === id ? { ...field, ...changes } : field))
  }
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (typeof layer !== 'number') return
    checking.mutate({
      mode: 'edit', changes: { description, category, layer,
        fields: fields.map(({ name, label, maxLength, required, sensitive }) => ({ name, label, maxLength, required, sensitive })) },
    })
  }

  return <Modal opened size="xl" title={review?.mode === 'delete' ? 'مراجعة حذف القالب' : 'إدارة القالب'}
    onClose={() => { if (!pending) onClose() }} withCloseButton={!pending}>
    <Stack gap="md">
      <Stack gap={3}>
        <Text fw={700}>{definition.description || definition.key}</Text>
        <Text size="sm" c="dimmed" dir="auto" style={{ overflowWrap: 'anywhere' }}>{definition.file}</Text>
      </Stack>
      {error && <Alert color="orange" role="alert">
        <Stack gap="xs" align="flex-start">
          {messageFor(error.message)}
          {error.message === 'scene_registry_stale' && <Button variant="default" size="xs" onClick={onReload}>تحميل التعريف الحالي</Button>}
        </Stack>
      </Alert>}
      {review ? <>
        {review.mode === 'delete'
          ? <Alert color="red">سيُحذف تعريف القالب ونصوصه المحفوظة من السجل المشترك.</Alert>
          : review.preview.after && <DefinitionComparison before={review.preview.before} after={review.preview.after} />}
        <Group justify="flex-end">
          <Button variant="default" disabled={pending} onClick={() => { setReview(null); saving.reset() }}>رجوع</Button>
          <Button color={review.mode === 'delete' ? 'red' : undefined} loading={pending} disabled={!!saving.error || noChanges}
            onClick={() => saving.mutate(review)}>{review.mode === 'delete' ? 'تأكيد الحذف' : 'حفظ التعديل'}</Button>
        </Group>
      </> : (
        <form onSubmit={submit}>
          <Stack gap="md">
            <SimpleGrid cols={{ base: 1, xs: 2 }}>
              <TextInput label="اسم العرض" value={description} maxLength={120}
                onChange={event => setDescription(event.currentTarget.value)} />
              <TextInput label="التصنيف" value={category} maxLength={60}
                onChange={event => setCategory(event.currentTarget.value)} />
              {definition.device ? <TextInput label="جهاز القالب" value={definition.device} readOnly />
                : <NumberInput required label="الطبقة" min={1} allowDecimal={false} value={layer}
                  onChange={value => setLayer(typeof value === 'bigint' ? Number(value) : value)} />}
            </SimpleGrid>
            <Group justify="space-between">
              <Text fw={600}>حقول الإدخال</Text>
              {!lockedNames && <Button size="xs" variant="default" leftSection={<IconPlus size={16} />}
                disabled={fields.length >= 40} onClick={() => setFields(items => [
                  ...items, { id: crypto.randomUUID(), name: '', label: '', maxLength: 0, required: false, sensitive: false },
                ])}>إضافة حقل</Button>}
            </Group>
            {lockedNames && <Text size="sm" c="dimmed">ترتبط النصوص المحفوظة بأسماء الحقول وترتيبها.</Text>}
            {!!fields.length && <Table.ScrollContainer minWidth={compact ? 0 : 620}>
              <Table aria-label="حقول تعريف القالب">
                {!compact && <Table.Thead><Table.Tr>
                  <Table.Th scope="col">الحقل في المشهد</Table.Th><Table.Th scope="col">الاسم المعروض</Table.Th>
                  <Table.Th scope="col">الحدّ</Table.Th><Table.Th scope="col">إلزامي</Table.Th><Table.Th scope="col">حسّاس</Table.Th>
                  {!lockedNames && <Table.Th scope="col">إزالة</Table.Th>}
                </Table.Tr></Table.Thead>}
                <Table.Tbody>{fields.map((field, index) => {
                  const name = <TextInput required readOnly={lockedNames} aria-label={`الحقل ${index + 1}`}
                    label={compact ? 'الحقل في المشهد' : undefined} value={field.name}
                    onChange={event => changeField(field.id, { name: event.currentTarget.value })} />
                  const label = <TextInput aria-label={`الاسم المعروض للحقل ${index + 1}`} label={compact ? 'الاسم المعروض' : undefined}
                    value={field.label} maxLength={120} onChange={event => changeField(field.id, { label: event.currentTarget.value })} />
                  const limit = <NumberInput aria-label={`حد الحقل ${index + 1}`} label={compact ? 'الحدّ' : undefined}
                    value={field.maxLength} min={0} max={2147483647} allowDecimal={false}
                    onChange={value => changeField(field.id, { maxLength: Number(value) })} />
                  const required = <Checkbox aria-label={`الحقل ${index + 1} إلزامي`} label={compact ? 'إلزامي' : undefined}
                    checked={field.required} onChange={event => changeField(field.id, { required: event.currentTarget.checked })} />
                  const sensitive = <Checkbox aria-label={`الحقل ${index + 1} حساس`} label={compact ? 'حسّاس' : undefined}
                    checked={field.sensitive} onChange={event => changeField(field.id, { sensitive: event.currentTarget.checked })} />
                  const remove = <ActionIcon variant="default" aria-label={`إزالة الحقل ${index + 1}`}
                    onClick={() => setFields(items => items.filter(item => item.id !== field.id))}><IconTrash size={16} /></ActionIcon>
                  return <Table.Tr key={field.id}>{compact ? <Table.Td>
                    <Stack gap="xs" py="xs">
                      <SimpleGrid cols={2} spacing="xs">{name}{label}</SimpleGrid>
                      <Group align="end" justify="space-between" gap="xs">
                        {limit}<Group gap="xs" pb={6}>{required}{sensitive}{!lockedNames && remove}</Group>
                      </Group>
                    </Stack>
                  </Table.Td> : <>
                    <Table.Td>{name}</Table.Td><Table.Td>{label}</Table.Td><Table.Td>{limit}</Table.Td>
                    <Table.Td>{required}</Table.Td><Table.Td>{sensitive}</Table.Td>{!lockedNames && <Table.Td>{remove}</Table.Td>}
                  </>}</Table.Tr>
                })}</Table.Tbody>
              </Table>
            </Table.ScrollContainer>}
            {!!fields.length && <Text size="xs" c="dimmed">الحدّ 0 يستخدم الحدّ الافتراضي للقالب.</Text>}
            <Group justify="space-between">
              <Button variant="light" color="red" disabled={pending} onClick={() => checking.mutate({ mode: 'delete' })}>مراجعة الحذف</Button>
              <Button type="submit" loading={pending}>مراجعة التعديل</Button>
            </Group>
          </Stack>
        </form>
      )}
    </Stack>
  </Modal>
}

function describeField(field: Definition['fields'][number]) {
  return [field.label || field.name, field.maxLength > 0 ? `حدّ ${field.maxLength}` : 'حدّ افتراضي',
    field.required ? 'إلزامي' : '', field.sensitive ? 'حسّاس' : ''].filter(Boolean).join(' · ')
}

function DefinitionComparison({ before, after }: { before: Definition; after: Definition }) {
  const oldFields = new Map(before.fields.map(field => [field.name, describeField(field)]))
  const newFields = new Map(after.fields.map(field => [field.name, describeField(field)]))
  const fields = new Set([...oldFields.keys(), ...newFields.keys()])
  const rows = [
    { name: 'اسم العرض', before: before.description, after: after.description },
    { name: 'التصنيف', before: before.category, after: after.category },
    { name: 'الطبقة', before: String(before.layer), after: String(after.layer) },
    ...Array.from(fields, name => ({ name, before: oldFields.get(name), after: newFields.get(name) })),
  ].filter(row => row.before !== row.after)

  if (!rows.length) return <Text c="dimmed" size="sm">لا توجد تغييرات في القالب.</Text>
  return <Table withRowBorders aria-label="مقارنة تعريف القالب" style={{ overflowWrap: 'anywhere' }}>
    <Table.Thead><Table.Tr><Table.Th scope="col">البند</Table.Th><Table.Th scope="col">قبل</Table.Th><Table.Th scope="col">بعد</Table.Th></Table.Tr></Table.Thead>
    <Table.Tbody>{rows.map((row, index) => <Table.Tr key={index}>
      <Table.Th scope="row"><bdi>{row.name}</bdi></Table.Th><Table.Td>{row.before || '—'}</Table.Td><Table.Td>{row.after || '—'}</Table.Td>
    </Table.Tr>)}</Table.Tbody>
  </Table>
}
