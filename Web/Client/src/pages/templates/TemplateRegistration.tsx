import { ActionIcon, Alert, Button, Group, Modal, NumberInput, ScrollArea, SimpleGrid, Skeleton, Stack, Table, Text, TextInput } from '@mantine/core'
import { useDebouncedValue } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { IconFile, IconFolder, IconPlus, IconSearch, IconTrash } from '@tabler/icons-react'
import { useState, type FormEvent } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type CatalogueRequest = Schemas['TemplateCatalogueRequest']

async function catalogue(request: Pick<CatalogueRequest, 'action'> & Partial<CatalogueRequest>, signal?: AbortSignal) {
  const body: CatalogueRequest = { folder: '', page: 0, search: '', review: '', ...request }
  const { data, error, response } = await api.POST('/api/air/template-catalogue', { body, signal })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

export function TemplateRegistration({ onClose }: { onClose: () => void }) {
  const cache = useQueryClient()
  const [folder, setFolder] = useState('')
  const [page, setPage] = useState(0)
  const [search, setSearch] = useState('')
  const [debouncedSearch] = useDebouncedValue(search, 250)
  const [file, setFile] = useState('')
  const [key, setKey] = useState('')
  const [layer, setLayer] = useState<number | string>('')
  const [description, setDescription] = useState('')
  const [category, setCategory] = useState('')
  const [fields, setFields] = useState<{ id: string; name: string }[]>([])
  const [preview, setPreview] = useState<Schemas['TemplateCataloguePreview'] | null>(null)
  const listing = useQuery({
    queryKey: ['template-scene-folder', folder, page, debouncedSearch],
    queryFn: ({ signal }) => catalogue({ action: 'browse', folder, page, search: debouncedSearch }, signal),
    enabled: !file,
    retry: false,
    staleTime: 0,
    gcTime: 0,
  })
  const review = useMutation({
    mutationFn: (definition: Schemas['TemplateSceneDefinition']) => catalogue({ action: 'review', definition }),
    onSuccess: result => { if (result.preview) setPreview(result.preview) },
  })
  const register = useMutation({
    mutationFn: (plan: Schemas['TemplateCataloguePreview']) => catalogue({
      action: 'register',
      review: plan.review,
      definition: { key: plan.key, file: plan.file, layer: plan.layer, description: plan.description, category: plan.category, fields: plan.fields },
    }),
    onSuccess: async () => {
      await cache.invalidateQueries({ queryKey: ['templates'] })
      notifications.show({ color: 'teal', message: 'سُجّل القالب في المكتبة المشتركة.' })
      onClose()
    },
  })
  const pending = review.isPending || register.isPending
  const error = register.error ?? review.error
  function openFolder(path: string) {
    setFolder(path)
    setPage(0)
    setSearch('')
  }
  function reviewDefinition(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (typeof layer !== 'number') return
    review.mutate({ key: key.trim(), file, layer, description, category, fields: fields.map(field => field.name.trim()) })
  }

  return (
    <Modal opened title="تسجيل قالب" size="lg" onClose={() => { if (!pending) onClose() }} withCloseButton={!pending}>
      <Stack gap="md">
        {!file ? <>
          <Group justify="space-between" align="center">
            <Text fw={600} dir="auto" style={{ overflowWrap: 'anywhere' }}>{folder || 'مجلد المشاهد'}</Text>
            {folder && <Button variant="default" size="xs" onClick={() => openFolder(folder.split('/').slice(0, -1).join('/'))}>المجلد الأعلى</Button>}
          </Group>
          <TextInput label="بحث في المجلد" value={search} maxLength={120} leftSection={<IconSearch size={16} />}
            onChange={event => { setSearch(event.currentTarget.value); setPage(0) }} />
          {listing.isPending ? <Skeleton h={112} /> : listing.error ? (
            <Alert color="orange" role="alert">
              <Stack gap="xs" align="flex-start">
                {messageFor(listing.error.message)}
                <Button variant="default" size="xs" onClick={() => void listing.refetch()}>إعادة التحميل</Button>
              </Stack>
            </Alert>
          ) : !listing.data?.entries?.length ? (
            <Text c="dimmed" size="sm">{search.trim() ? 'لا توجد ملفات أو مجلدات مطابقة.' : 'لا توجد ملفات مشاهد في هذا المجلد.'}</Text>
          ) : (
            <ScrollArea.Autosize mah={300} type="auto">
              <Table highlightOnHover aria-label="ملفات المشاهد">
                <Table.Thead><Table.Tr><Table.Th scope="col">الاسم</Table.Th></Table.Tr></Table.Thead>
                <Table.Tbody>{listing.data.entries.map(entry => {
                  const Icon = entry.folder ? IconFolder : IconFile
                  return <Table.Tr key={entry.path}><Table.Td>
                    <Button variant="subtle" justify="start" fullWidth leftSection={<Icon size={17} />}
                      styles={{ root: { height: 'auto', minHeight: '2.25rem', paddingBlock: '0.4rem' }, label: { whiteSpace: 'normal', textAlign: 'start', overflowWrap: 'anywhere' } }}
                      onClick={() => {
                        if (entry.folder) openFolder(entry.path)
                        else { setFile(entry.path); review.reset() }
                      }}><bdi>{entry.name}</bdi></Button>
                  </Table.Td></Table.Tr>
                })}</Table.Tbody>
              </Table>
            </ScrollArea.Autosize>
          )}
          {(listing.data?.pageCount ?? 1) > 1 && <Group justify="space-between">
            <Button variant="default" size="xs" disabled={page === 0} onClick={() => setPage(page - 1)}>السابق</Button>
            <Text size="sm" c="dimmed">{(listing.data?.page ?? page) + 1} / {listing.data?.pageCount}</Text>
            <Button variant="default" size="xs" disabled={page + 1 >= (listing.data?.pageCount ?? 1)} onClick={() => setPage(page + 1)}>التالي</Button>
          </Group>}
        </> : preview ? <>
          <Stack gap={4}>
            <Text fw={700}>{preview.description || preview.key}</Text>
            {preview.description && <Text size="sm" c="dimmed" className="cgb-mono" style={{ overflowWrap: 'anywhere' }}>{preview.key}</Text>}
            <Text size="sm" c="dimmed" dir="auto" style={{ overflowWrap: 'anywhere' }}>{preview.file}</Text>
            <Text size="sm">الطبقة {preview.layer}{preview.category ? ` · ${preview.category}` : ''}</Text>
          </Stack>
          {!!preview.fields.length && <Table withRowBorders aria-label="الحقول التي ستُسجّل">
            <Table.Thead><Table.Tr><Table.Th scope="col">حقول الإدخال</Table.Th></Table.Tr></Table.Thead>
            <Table.Tbody>{preview.fields.map(name => <Table.Tr key={name}><Table.Td><bdi>{name}</bdi></Table.Td></Table.Tr>)}</Table.Tbody>
          </Table>}
          {!!preview.sharedTemplates.length && <Alert color="orange">
            تستخدم قوالب أخرى الطبقة نفسها.{' '}
            {preview.sharedTemplates.map((name, index) => <span key={name}>{index > 0 && '، '}<bdi>{name}</bdi></span>)}
          </Alert>}
          {error && <Alert color="orange" role="alert">{messageFor(error.message)}</Alert>}
          <Group justify="flex-end">
            <Button variant="default" disabled={pending} onClick={() => { setPreview(null); register.reset() }}>تعديل البيانات</Button>
            <Button loading={pending} disabled={!!register.error} onClick={() => register.mutate(preview)}>تأكيد التسجيل</Button>
          </Group>
        </> : (
          <form onSubmit={reviewDefinition}>
            <Stack gap="md">
              <Group justify="space-between">
                <Text size="sm" fw={600} dir="auto" style={{ overflowWrap: 'anywhere' }}>{file}</Text>
                <Button variant="default" size="xs" disabled={pending} onClick={() => setFile('')}>تغيير الملف</Button>
              </Group>
              <SimpleGrid cols={{ base: 1, xs: 2 }}>
                <TextInput required label="مفتاح القالب" description="مثل EveningProgramme" value={key} maxLength={64}
                  onChange={event => setKey(event.currentTarget.value)} />
                <NumberInput required label="الطبقة" min={1} max={2147483647} allowDecimal={false} value={layer}
                  onChange={value => setLayer(typeof value === 'bigint' ? Number(value) : value)} />
                <TextInput label="اسم العرض" value={description} maxLength={120} onChange={event => setDescription(event.currentTarget.value)} />
                <TextInput label="التصنيف" value={category} maxLength={60} onChange={event => setCategory(event.currentTarget.value)} />
              </SimpleGrid>
              <Group justify="space-between">
                <Text fw={600}>حقول الإدخال</Text>
                <Button size="xs" variant="default" leftSection={<IconPlus size={16} />} disabled={fields.length >= 40}
                  onClick={() => setFields(previous => [...previous, { id: crypto.randomUUID(), name: '' }])}>إضافة حقل</Button>
              </Group>
              {!!fields.length && <Table aria-label="تعريف حقول القالب">
                <Table.Thead><Table.Tr><Table.Th scope="col">اسم الحقل في المشهد</Table.Th><Table.Th scope="col">إزالة</Table.Th></Table.Tr></Table.Thead>
                <Table.Tbody>{fields.map((field, index) => (
                  <Table.Tr key={field.id}>
                    <Table.Td><TextInput required aria-label={`اسم الحقل ${index + 1}`} value={field.name} maxLength={100}
                      onChange={event => {
                        const name = event.currentTarget.value
                        setFields(previous => previous.map(item => item.id === field.id ? { ...item, name } : item))
                      }} /></Table.Td>
                    <Table.Td><ActionIcon aria-label={`إزالة الحقل ${index + 1}`} variant="default"
                      onClick={() => setFields(previous => previous.filter(item => item.id !== field.id))}><IconTrash size={16} /></ActionIcon></Table.Td>
                  </Table.Tr>
                ))}</Table.Tbody>
              </Table>}
              {error && <Alert color="orange" role="alert">{messageFor(error.message)}</Alert>}
              <Group justify="flex-end"><Button type="submit" loading={pending}>مراجعة التسجيل</Button></Group>
            </Stack>
          </form>
        )}
      </Stack>
    </Modal>
  )
}
