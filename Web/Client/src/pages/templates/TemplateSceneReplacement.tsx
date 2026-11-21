import { Alert, Button, Group, Modal, Skeleton, Stack, Table, Text, TextInput } from '@mantine/core'
import { useDebouncedValue } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { IconFile, IconFolder, IconSearch } from '@tabler/icons-react'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type SceneCommand = Schemas['TemplateSceneReplacementCommand']
type SceneCurrent = NonNullable<Schemas['TemplateSceneReplacementCurrent']>
type Selection = NonNullable<Schemas['TemplateSceneReplacementSelection']>
type Preview = NonNullable<Schemas['TemplateSceneReplacementPreview']>

const number = new Intl.NumberFormat('ar')
const sceneErrors: Record<string, string> = {
  scene_replacement_managed: 'لهذا القالب متطلبات تشغيل خاصة. استخدم إعدادات القالب المخصّصة.',
  scene_replacement_unverified: 'تعذّر تأكيد خلوّ الطبقة. تحقّق من لوحة الهواء قبل استبدال الملف.',
  scene_replacement_incompatible: 'حقول الملف الجديد غير متوافقة مع تعريف القالب.',
  scene_replacement_format: 'يجب أن يحتوي الملف على مشهد Cinegy صالح واحد.',
  scene_replacement_size: 'تعذّر التحقق من الملف. اختر ملف مشهد صالحًا ضمن ١٦ ميغابايت.',
}

async function sceneRequest(key: string, command: Pick<SceneCommand, 'action'> & Partial<SceneCommand>, signal?: AbortSignal) {
  const body: SceneCommand = { revision: null, file: null, selection: null, review: null, ...command }
  const { data, error, response } = await api.POST('/api/air/templates/{key}/scene', { params: { path: { key } }, body, signal })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

function sceneError(error: Error) {
  return sceneErrors[error.message] ?? messageFor(error.message)
}

export function TemplateSceneReplacement({ templateKey, onClose }: { templateKey: string; onClose: () => void }) {
  const current = useQuery({
    queryKey: ['template-scene-replacement', templateKey],
    queryFn: async ({ signal }) => {
      const result = await sceneRequest(templateKey, { action: 'inspect' }, signal)
      if (!result.current) throw new Error('scene_registry_stale')
      return result.current
    },
    gcTime: 0, retry: false, refetchOnWindowFocus: false, refetchOnReconnect: false,
  })
  if (current.data && !current.isFetching && !current.error) {
    return <SceneReplacementEditor key={current.dataUpdatedAt} template={current.data} onClose={onClose}
      onReload={() => void current.refetch()} />
  }
  return <Modal opened title="استبدال ملف المشهد" onClose={onClose}>
    <Stack gap="md" dir="rtl">
      {current.isFetching ? <Skeleton h={76} aria-label="جارٍ تحميل تعريف القالب" /> : current.error && (
        <Alert color="orange" role="alert">{sceneError(current.error)}</Alert>
      )}
      <Group justify="flex-end">
        <Button variant="default" onClick={onClose}>إغلاق</Button>
        {current.error && <Button variant="light" onClick={() => void current.refetch()}>إعادة التحميل</Button>}
      </Group>
    </Stack>
  </Modal>
}

function SceneReplacementEditor({ template, onClose, onReload }: { template: SceneCurrent; onClose: () => void; onReload: () => void }) {
  const cache = useQueryClient()
  const [folder, setFolder] = useState('')
  const [page, setPage] = useState(0)
  const [search, setSearch] = useState('')
  const [debouncedSearch] = useDebouncedValue(search, 250)
  const [selection, setSelection] = useState<Selection | null>(null)
  const [review, setReview] = useState<{ preview: Preview; selection: string } | null>(null)
  const browser = useQuery({
    queryKey: ['template-scene-folder', folder, page, debouncedSearch],
    queryFn: async ({ signal }) => {
      const body: Schemas['TemplateCatalogueRequest'] = { action: 'browse', folder, page, search: debouncedSearch, definition: null, review: '' }
      const { data, error, response } = await api.POST('/api/air/template-catalogue', { body, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    enabled: !selection,
    gcTime: 0, retry: false, refetchOnWindowFocus: false, refetchOnReconnect: false,
  })
  const choose = useMutation({
    mutationFn: async (file: string) => {
      const result = await sceneRequest(template.key, { action: 'select', revision: template.revision, file })
      if (!result.selection) throw new Error('scene_not_found')
      return result.selection
    },
    onSuccess: setSelection,
  })
  const prepare = useMutation({
    mutationFn: async (handle: string) => {
      const result = await sceneRequest(template.key, { action: 'preview', revision: template.revision, selection: handle })
      if (!result.preview) throw new Error('scene_registry_stale')
      return { preview: result.preview, selection: handle }
    },
    onSuccess: setReview,
  })
  const apply = useMutation({
    mutationFn: (decision: { preview: Preview; selection: string }) => sceneRequest(template.key, {
      action: 'apply', revision: template.revision, selection: decision.selection, review: decision.preview.review,
    }),
    onSuccess: async () => {
      await Promise.all([cache.invalidateQueries({ queryKey: ['templates'] }), cache.invalidateQueries({ queryKey: ['template-definition', template.key] })])
      notifications.show({ color: 'teal', message: 'استُبدل ملف المشهد في سجل القوالب المشترك.' })
      onClose()
    },
  })
  const pending = choose.isPending || prepare.isPending || apply.isPending
  const error = apply.error ?? prepare.error ?? choose.error ?? (!selection ? browser.error : null)
  const handle = selection?.handle

  function openFolder(target: string) {
    setFolder(target)
    setPage(0)
    setSearch('')
    choose.reset()
  }

  function returnToFiles() {
    setSelection(null)
    setReview(null)
    choose.reset()
    prepare.reset()
    apply.reset()
  }

  return <Modal opened title={review ? 'مراجعة استبدال المشهد' : 'استبدال ملف المشهد'} size="lg"
    onClose={() => { if (!pending) onClose() }} withCloseButton={!pending} closeOnEscape={!pending} closeOnClickOutside={!pending}>
    <Stack gap="md" dir="rtl">
      <Group justify="space-between">
        <Text fw={600}><bdi>{template.key}</bdi></Text>
        <Text size="sm">الطبقة {number.format(template.layer)}</Text>
      </Group>
      {error && <Alert color="orange" role="alert">
        <Stack gap="xs" align="flex-start">
          {sceneError(error)}
          {error.message === 'scene_registry_stale' && <Button variant="light" size="xs" onClick={onReload}>تحميل التعريف الحالي</Button>}
          {browser.error && !selection && <Button variant="light" size="xs" onClick={() => void browser.refetch()}>إعادة تحميل المجلد</Button>}
        </Stack>
      </Alert>}
      {review ? <>
        <Table withRowBorders aria-label="ملف المشهد قبل الاستبدال وبعده" style={{ overflowWrap: 'anywhere' }}>
          <Table.Tbody>
            <Table.Tr><Table.Th scope="row">الملف الحالي</Table.Th><Table.Td><bdi>{review.preview.beforeFile}</bdi></Table.Td></Table.Tr>
            <Table.Tr><Table.Th scope="row">الملف الجديد</Table.Th><Table.Td><bdi>{review.preview.afterFile}</bdi></Table.Td></Table.Tr>
          </Table.Tbody>
        </Table>
        {!!review.preview.fields.length && <Text size="sm">الحقول المتوافقة {review.preview.fields.map(field => <bdi key={field} style={{ marginInlineStart: '0.5em' }}>{field}</bdi>)}</Text>}
        {review.preview.presetCount > 0 && <Text size="sm">النصوص الجاهزة المرتبطة بالقالب {number.format(review.preview.presetCount)}</Text>}
        <Group justify="flex-end">
          <Button variant="default" disabled={pending} onClick={returnToFiles}>اختيار ملف آخر</Button>
          <Button loading={apply.isPending} disabled={!!apply.error} onClick={() => apply.mutate(review)}>تأكيد الاستبدال</Button>
        </Group>
      </> : selection ? <>
        <Text size="sm">الملف المختار <bdi>{selection.file}</bdi></Text>
        {!!selection.incompatibleFields.length && <Alert color="orange" role="alert">
          يتطلب القالب حقولًا متوافقة مع الأسماء التالية {selection.incompatibleFields.map(field => <bdi key={field} style={{ marginInlineStart: '0.5em' }}>{field}</bdi>)}.
        </Alert>}
        <Group justify="flex-end">
          <Button variant="default" disabled={pending} onClick={returnToFiles}>اختيار ملف آخر</Button>
          {handle && <Button loading={prepare.isPending} disabled={error?.message === 'scene_registry_stale'}
            onClick={() => prepare.mutate(handle)}>مراجعة الاستبدال</Button>}
        </Group>
      </> : <>
        <Text size="sm">الملف الحالي <bdi>{template.file}</bdi></Text>
        <Group justify="space-between">
          <Text fw={600}><bdi>{folder || 'مجلد المشاهد'}</bdi></Text>
          {folder && <Button size="xs" variant="default" disabled={pending}
            onClick={() => openFolder(folder.split('/').slice(0, -1).join('/'))}>المجلد الأعلى</Button>}
        </Group>
        <TextInput label="بحث في المجلد" value={search} maxLength={120} disabled={pending} leftSection={<IconSearch size={16} />}
          onChange={event => { setSearch(event.currentTarget.value); setPage(0) }} />
        {browser.isFetching ? <Skeleton h={110} aria-label="جارٍ تحميل ملفات المشاهد" /> : browser.data?.entries?.length ? (
          <Stack gap={4}>
            {browser.data.entries.map(entry => {
              const Icon = entry.folder ? IconFolder : IconFile
              return <Button key={entry.path} variant="subtle" justify="start" leftSection={<Icon size={16} />} disabled={pending}
                styles={{ label: { whiteSpace: 'normal', overflowWrap: 'anywhere', textAlign: 'start' }, root: { height: 'auto', minHeight: '2.25rem' } }}
                onClick={() => { if (entry.folder) openFolder(entry.path); else choose.mutate(entry.path) }}><bdi>{entry.name}</bdi></Button>
            })}
          </Stack>
        ) : !browser.error && <Text size="sm" c="dimmed">لا توجد ملفات أو مجلدات مطابقة.</Text>}
        {(browser.data?.pageCount ?? 1) > 1 && <Group justify="space-between">
          <Button variant="default" size="xs" disabled={pending || page === 0} onClick={() => setPage(page - 1)}>السابق</Button>
          <Text size="sm">{number.format((browser.data?.page ?? page) + 1)} / {number.format(browser.data?.pageCount ?? 1)}</Text>
          <Button variant="default" size="xs" disabled={pending || page + 1 >= (browser.data?.pageCount ?? 1)} onClick={() => setPage(page + 1)}>التالي</Button>
        </Group>}
      </>}
    </Stack>
  </Modal>
}
