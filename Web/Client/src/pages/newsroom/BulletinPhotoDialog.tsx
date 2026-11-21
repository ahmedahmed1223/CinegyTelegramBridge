import { Alert, Button, FileInput, Group, Image, Modal, Stack, Text } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { uploadBulletinPhoto, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

export function BulletinPhotoDialog({ id, rowId, revision, title, field, onClose, onSaved }: {
  id: string
  rowId: string | null
  revision: number
  title: string
  field: string
  onClose: () => void
  onSaved: (bulletin: Schemas['BulletinEditor']) => void
}) {
  const [file, setFile] = useState<File | null>(null)
  const [preview, setPreview] = useState('')
  const upload = useMutation({
    mutationFn: (image: File) => uploadBulletinPhoto(image, id, rowId, revision, field),
    onSuccess: onSaved,
  })
  const tooLarge = !!file && file.size > 10 * 1024 * 1024
  const isTiff = !!file && /\.tiff?$/i.test(file.name)
  const stale = upload.error?.message === 'bulletin_stale'
  useEffect(() => {
    if (!file || tooLarge || !/^image\/(jpeg|png|gif|bmp)$/.test(file.type)) return
    const reader = new FileReader()
    reader.onload = () => { if (typeof reader.result === 'string') setPreview(reader.result) }
    reader.readAsDataURL(file)
    return () => { reader.onload = null; if (reader.readyState === FileReader.LOADING) reader.abort() }
  }, [file, tooLarge])
  return (
    <Modal opened title={title} onClose={() => { if (!upload.isPending) onClose() }}>
      <form onSubmit={(event) => {
        event.preventDefault()
        if (file && !tooLarge && !upload.isPending && !stale) upload.mutate(file)
      }}>
        <Stack gap="md">
          <FileInput label="ملف الصورة" description="JPEG أو PNG أو GIF أو BMP أو TIFF. الحد الأقصى 10 ميغابايت." placeholder="اختر صورة"
            accept=".jpg,.jpeg,.png,.gif,.bmp,.tif,.tiff" clearable clearButtonProps={{ 'aria-label': 'إزالة الملف المختار' }}
            value={file} disabled={upload.isPending}
            onChange={(next) => { setPreview(''); setFile(next); if (!stale) upload.reset() }} />
          {preview && <Image src={preview} alt="معاينة الصورة المختارة" h={155} fit="contain" radius="sm" onError={() => setPreview('')} />}
          {isTiff && !tooLarge && <Text size="sm">تظهر صورة TIFF في معاينة الموجز بعد الحفظ.</Text>}
          {upload.isPending && <Text size="sm" role="status">جارٍ رفع الصورة ومعالجتها…</Text>}
          {(tooLarge || upload.error) && <Alert color="red" role="alert">
            {stale ? 'تغيّر الموجز أثناء اختيار الصورة. أغلق النافذة وحدّث الموجز، ثم اختر الصورة من جديد.'
              : messageFor(tooLarge ? 'bulletin_photo_size' : upload.error?.message ?? 'unknown')}
          </Alert>}
          <Group justify="flex-end">
            <Button variant="default" disabled={upload.isPending} onClick={onClose}>إلغاء</Button>
            <Button type="submit" loading={upload.isPending} disabled={!file || tooLarge || stale}>{rowId ? 'حفظ الصورة' : 'إضافة الصف'}</Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
