import { Alert, Button, Group, Modal, Pagination, Paper, Skeleton, Stack, Text, TextInput, Title } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey, useSession } from '../../api/session'

type Row = Schemas['LayerNameView']
type Preview = Schemas['LayerNamePreview']
const key = ['admin', 'layer-names'] as const
const number = new Intl.NumberFormat('ar')

function layerNameError(code: string) {
  switch (code) {
    case 'layer_name_invalid': return 'اكتب اسمًا من ٦٠ حرفًا على الأكثر، دون ; أو =.'
    case 'layer_name_single_line': return 'اكتب الاسم في سطر واحد.'
    case 'layer_name_not_found': return 'لم تعد الطبقة ضمن القائمة.'
    case 'layer_name_stale': return 'تغيّر اسم الطبقة أو انتهت المراجعة. راجع التعديل من جديد.'
    case 'layer_name_unchanged': return 'هذا هو الاسم الحالي.'
    case 'layer_name_save_failed': return 'تعذّر حفظ الاسم. بقي الاسم السابق قائمًا.'
    default: return messageFor(code)
  }
}

function displayName(row: Row) {
  return row.name || (row.hasCustomName ? 'اسم سابق خارج الصيغة' : 'بلا اسم مخصّص')
}

export function LayerNamesPanel() {
  const client = useQueryClient()
  const session = useSession()
  const [page, setPage] = useState(0)
  const [target, setTarget] = useState<Row | null>(null)
  const [name, setName] = useState('')
  const [failure, setFailure] = useState('')
  const [preview, setPreview] = useState<Preview | null>(null)

  const layers = useQuery({
    queryKey: [...key, session.data?.id, page],
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/layer-names', {
        params: { query: { page, pageSize: 20 } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    enabled: !!session.data,
    retry: false,
  })

  function fail(error: Error) {
    setFailure(layerNameError(error.message))
    setPreview(null)
    if (['forbidden', 'unauthorized'].includes(error.message)) void client.invalidateQueries({ queryKey: sessionKey })
    void client.invalidateQueries({ queryKey: key })
  }

  const checking = useMutation({
    mutationFn: async ({ layer, name }: { layer: number; name: string }) => {
      const { data, error, response } = await api.POST('/api/admin/layer-names/{layer}/review', {
        params: { path: { layer } }, body: { name },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: setPreview,
    onError: fail,
  })
  const saving = useMutation({
    mutationFn: async (decision: Preview) => {
      const { data, error, response } = await api.POST('/api/admin/layer-names/{layer}/confirm', {
        params: { path: { layer: decision.current.layer } }, body: { review: decision.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async () => {
      setTarget(null)
      setPreview(null)
      notifications.show({ color: 'teal', message: 'حُفظ اسم الطبقة.' })
      await Promise.all([
        client.invalidateQueries({ queryKey: key }),
        client.invalidateQueries({ queryKey: ['admin-overview'] }),
      ])
    },
    onError: fail,
  })
  const busy = checking.isPending || saving.isPending
  const totalPages = layers.data ? Math.ceil(layers.data.total / layers.data.pageSize) : 0

  function open(row: Row) {
    setTarget(row)
    setName(row.name)
    setPreview(null)
    setFailure('')
  }

  return (
    <Paper withBorder radius="md" p="md" dir="rtl">
      <Stack gap="sm">
        <Title order={2} size="h4">أسماء الطبقات</Title>
        {layers.isError ? (
          <Alert color="orange" role="alert">{layerNameError(layers.error.message)}</Alert>
        ) : !layers.data ? (
          <Skeleton height={90} />
        ) : layers.data.items.length === 0 ? (
          <Text c="dimmed" size="sm">لا توجد طبقات معرّفة.</Text>
        ) : layers.data.items.map((row) => (
          <Group key={row.layer} justify="space-between">
            <Text size="sm" style={{ overflowWrap: 'anywhere' }}>
              الطبقة {number.format(row.layer)} · <bdi>{displayName(row)}</bdi>
            </Text>
            <Button variant="light" size="xs" onClick={() => open(row)}>تعديل الاسم</Button>
          </Group>
        ))}
        {totalPages > 1 && (
          <Pagination total={totalPages} value={(layers.data?.page ?? 0) + 1} onChange={(value) => setPage(value - 1)} />
        )}
        <Modal opened={target !== null} title={target ? `اسم الطبقة ${number.format(target.layer)}` : 'اسم الطبقة'}
          onClose={() => { if (!busy) setTarget(null) }} closeOnClickOutside={!busy} closeOnEscape={!busy} withCloseButton={!busy} dir="rtl">
          {target && (
            <Stack>
              {failure && <Alert color="orange" role="alert">{failure}</Alert>}
              {preview ? (
                <>
                  <Text>الاسم الحالي: <bdi>{displayName(preview.current)}</bdi></Text>
                  <Text fw={600}>الاسم بعد الحفظ: <bdi>{preview.name || 'بلا اسم مخصّص'}</bdi></Text>
                  <Group justify="end">
                    <Button variant="default" disabled={busy} onClick={() => setPreview(null)}>رجوع</Button>
                    <Button loading={saving.isPending} onClick={() => saving.mutate(preview)}>تأكيد الحفظ</Button>
                  </Group>
                </>
              ) : (
                <>
                  <TextInput label="اسم الطبقة" description="حتى ٦٠ حرفًا في سطر واحد."
                    value={name} onChange={(event) => setName(event.currentTarget.value)} disabled={busy} />
                  <Group justify="end">
                    {target.hasCustomName && <Button variant="light" color="red" disabled={busy}
                      onClick={() => { setFailure(''); checking.mutate({ layer: target.layer, name: '' }) }}>مراجعة إزالة الاسم</Button>}
                    <Button loading={checking.isPending} disabled={!name.trim()}
                      onClick={() => { setFailure(''); checking.mutate({ layer: target.layer, name }) }}>مراجعة الاسم</Button>
                  </Group>
                </>
              )}
            </Stack>
          )}
        </Modal>
      </Stack>
    </Paper>
  )
}
