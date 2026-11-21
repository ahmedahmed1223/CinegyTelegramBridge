import { Alert, Button, Group, Modal, Pagination, Radio, Stack, Text } from '@mantine/core'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

const number = new Intl.NumberFormat('ar')

export function BulletinSceneImageDialog({ id, rowId, revision, onClose, onSaved }: {
  id: string
  rowId: string
  revision: number
  onClose: () => void
  onSaved: (bulletin: Schemas['BulletinEditor']) => void
}) {
  const [page, setPage] = useState(0)
  const [slot, setSlot] = useState('')
  const images = useQuery({
    queryKey: ['bulletin-scene-images', id, rowId, revision, page],
    retry: false,
    gcTime: 0,
    refetchOnWindowFocus: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/bulletins/scene-images', {
        params: { query: { id, rowId, revision, page } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const apply = useMutation({
    mutationFn: async ({ selection, candidate }: { selection: string; candidate: number }) => {
      const { data, error, response } = await api.POST('/api/content/bulletins/scene-images', {
        body: { id, rowId, revision, selection, slot: candidate },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: onSaved,
  })
  const error = apply.error?.message ?? images.error?.message
  const files = images.data
  return (
    <Modal opened title="اختيار صورة من مجلد المشهد" onClose={() => { if (!apply.isPending) onClose() }}>
      <Stack>
        {images.isPending && <Text role="status">جارٍ قراءة الصور…</Text>}
        {error && <Alert color="red" role="alert">{messageFor(error)}</Alert>}
        {files?.truncated && <Text size="sm">فُحص أول {number.format(200)} عنصراً في المجلد.</Text>}
        {files?.items.length === 0 && <Text>لا توجد صور مدعومة في هذا المجلد.</Text>}
        {files && files.items.length > 0 && (
          <Radio.Group label="صورة الصف" value={slot} onChange={(value) => setSlot(String(value))}>
            <Stack gap="xs" mt="xs">
              {files.items.map((item) => (
                <Radio key={item.slot} value={String(item.slot)} label={<bdi>{item.label}</bdi>} disabled={apply.isPending || !!error} />
              ))}
            </Stack>
          </Radio.Group>
        )}
        {files && files.pageCount > 1 && (
          <Pagination total={files.pageCount} value={files.page + 1} disabled={apply.isPending} onChange={(next) => {
            setSlot('')
            apply.reset()
            setPage(next - 1)
          }} />
        )}
        <Group justify="flex-end">
          {error === 'bulletin_scene_image_stale' && <Button variant="subtle" onClick={() => {
            setSlot('')
            apply.reset()
            void images.refetch()
          }}>تحديث الصور</Button>}
          <Button variant="default" disabled={apply.isPending} onClick={onClose}>إلغاء</Button>
          <Button loading={apply.isPending} disabled={!slot || !files?.selection || images.isFetching || !!error}
            onClick={() => { if (files?.selection) apply.mutate({ selection: files.selection, candidate: Number(slot) }) }}>حفظ الصورة</Button>
        </Group>
      </Stack>
    </Modal>
  )
}
