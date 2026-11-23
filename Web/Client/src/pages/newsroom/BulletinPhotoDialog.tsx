import { Alert, Button, FileInput, Group, Image, Modal, Stack, Text } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { uploadBulletinPhoto, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Bulletin = Schemas['BulletinEditor']
type PhotoField = { name: string; label: string }
type PhotoJob = { field: PhotoField; file: File }
export const bulletinPhotoMaxBytes = 10 * 1024 * 1024

export function BulletinPhotoInput({ label, file, disabled, describe, onChange }: {
  label: string; file: File | null; disabled: boolean; describe: boolean; onChange: (file: File | null) => void
}) {
  const [preview, setPreview] = useState<{ file: File; url: string } | null>(null)
  const tooLarge = !!file && file.size > bulletinPhotoMaxBytes
  const isTiff = !!file && /\.tiff?$/i.test(file.name)
  useEffect(() => {
    if (!file || tooLarge || !/^image\/(jpeg|png|gif|bmp)$/.test(file.type)) return
    const reader = new FileReader()
    reader.onload = () => { if (typeof reader.result === 'string') setPreview({ file, url: reader.result }) }
    reader.readAsDataURL(file)
    return () => { reader.onload = null; if (reader.readyState === FileReader.LOADING) reader.abort() }
  }, [file, tooLarge])

  return <Stack gap="xs">
    <FileInput label={label} description={describe ? 'JPEG أو PNG أو GIF أو BMP أو TIFF. الحد الأقصى 10 ميغابايت لكل صورة.' : undefined}
      placeholder="اختر صورة" accept=".jpg,.jpeg,.png,.gif,.bmp,.tif,.tiff" clearable
      clearButtonProps={{ 'aria-label': 'إزالة الملف المختار' }} value={file} disabled={disabled} onChange={onChange} />
    {preview && preview.file === file && <Image src={preview.url} alt="معاينة الصورة المختارة" h={155} fit="contain"
      radius="sm" onError={() => setPreview(null)} />}
    {isTiff && !tooLarge && <Text size="sm">تظهر صورة TIFF في معاينة الموجز بعد الحفظ.</Text>}
    {tooLarge && <Alert color="red" role="alert">{messageFor('bulletin_photo_size')}</Alert>}
  </Stack>
}

export function BulletinPhotoDialog({ id, rowId, revision, title, field, otherFields = [], onClose, onSaved }: {
  id: string
  rowId: string | null
  revision: number
  title: string
  field: string
  otherFields?: PhotoField[]
  onClose: () => void
  onSaved: (bulletin: Bulletin) => void
}) {
  const [files, setFiles] = useState(() => new Map<string, File | null>())
  const [expanded, setExpanded] = useState(false)
  const [activeField, setActiveField] = useState('')
  const [savedCount, setSavedCount] = useState(0)
  const lastSaved = useRef<Bulletin | null>(null)
  const fields: PhotoField[] = [{ name: field, label: 'ملف الصورة' }, ...(expanded ? otherFields : [])]
  const jobs = fields.flatMap(target => {
    const file = files.get(target.name)
    return file ? [{ field: target, file }] : []
  })
  const upload = useMutation({
    mutationFn: async (selected: PhotoJob[]) => {
      let latest = lastSaved.current
      for (const job of selected) {
        setActiveField(job.field.label)
        // Each write advances the shared bulletin revision. Use the revision
        // returned by our previous write so unrelated edits still fail closed.
        latest = await uploadBulletinPhoto(job.file, id, rowId, latest?.revision ?? revision, job.field.name)
        lastSaved.current = latest
        setSavedCount(count => count + 1)
        setFiles(current => new Map(current).set(job.field.name, null))
      }
      if (!latest) throw new Error('bulletin_photo_invalid')
      return latest
    },
    onSuccess: (bulletin) => onSaved(bulletin),
  })
  const stale = upload.error?.message === 'bulletin_stale'
  const canSubmit = jobs.length > 0 && jobs.every(({ file }) => file.size <= bulletinPhotoMaxBytes) && !upload.isPending && !stale
  function close() {
    if (upload.isPending) return
    if (lastSaved.current) onSaved(lastSaved.current)
    else onClose()
  }
  return (
    <Modal opened title={title} onClose={close} closeOnEscape={!upload.isPending} closeOnClickOutside={!upload.isPending} withCloseButton={!upload.isPending}>
      <form onSubmit={(event) => {
        event.preventDefault()
        if (canSubmit) upload.mutate(jobs)
      }}>
        <Stack gap="md">
          {fields.map((target, index) => <BulletinPhotoInput key={target.name} label={target.label} file={files.get(target.name) ?? null}
            describe={index === 0} disabled={upload.isPending || stale} onChange={(file) => {
              setFiles(current => new Map(current).set(target.name, file))
              if (!stale) upload.reset()
            }} />)}
          {rowId && !!otherFields.length && !expanded && <Button type="button" variant="light" size="sm" disabled={upload.isPending || stale}
            onClick={() => setExpanded(true)}>إضافة صور إلى حقول أخرى</Button>}
          {upload.isPending && <Text size="sm" role="status">
            {expanded && activeField ? `جارٍ رفع صورة «${activeField}» ومعالجتها…` : 'جارٍ رفع الصورة ومعالجتها…'}
          </Text>}
          {expanded && savedCount > 0 && <Text size="sm" role="status">الصور المحفوظة في هذه العملية {savedCount}</Text>}
          {upload.error && <Alert color="red" role="alert">
            {stale ? 'تغيّر الموجز أثناء اختيار الصورة. أغلق النافذة وحدّث الموجز، ثم اختر الصورة من جديد.'
              : `${expanded && activeField ? `${activeField} · ` : ''}${messageFor(upload.error.message)}`}
          </Alert>}
          <Group justify="flex-end">
            <Button variant="default" disabled={upload.isPending} onClick={close}>{savedCount ? 'إغلاق' : 'إلغاء'}</Button>
            <Button type="submit" loading={upload.isPending} disabled={!canSubmit}>{rowId ? expanded ? 'حفظ الصور' : 'حفظ الصورة' : 'إضافة الصف'}</Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
