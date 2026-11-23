import { Alert, Button, FileInput, Group, Image, Modal, NativeSelect, Stack, Text, Textarea, TextInput } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { uploadBulletinPhoto, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Bulletin = Schemas['BulletinEditor']
type PhotoField = { name: string; label: string }
type PhotoJob = { field: PhotoField; file: File }
const bulletinPhotoMaxBytes = 10 * 1024 * 1024
const bulletinTextMaxLength = 4096

function BulletinPhotoInput({ label, file, disabled, describe, onChange }: {
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

type NewRowInput = { values: Record<string, string>; imageChoice: string; file: File | null }

export function BulletinNewRowDialog({
  title, textFields, requireText, imageOptions, canUpload, initialImageChoice, onClose, saveRow, onSaved,
}: {
  title: string
  textFields: PhotoField[]
  requireText: boolean
  imageOptions: { value: string; label: string }[]
  canUpload: boolean
  initialImageChoice: string
  onClose: () => void
  saveRow: (row: NewRowInput) => Promise<Bulletin>
  onSaved: (bulletin: Bulletin) => void
}) {
  const [file, setFile] = useState<File | null>(null)
  const [location, setLocation] = useState('')
  const [imageChoice, setImageChoice] = useState(initialImageChoice)
  const [values, setValues] = useState<Record<string, string>>(() => Object.fromEntries(textFields.map(({ name }) => [name, ''])))
  const save = useMutation({ mutationFn: saveRow, onSuccess: onSaved })
  const stale = save.error?.cause === 'bulletin_stale'
  const locked = save.isPending || stale
  const uploadPhoto = imageChoice === 'new'
  const selectedFile = uploadPhoto ? file : null
  const storyField = requireText ? textFields.find(({ name }) => name.toLowerCase() === 'subject.text')?.name : undefined
  const story = (storyField && values[storyField]) || ''
  const preparedStory = location.trim() ? `${location.trim()}\n${story.trim()}` : story
  const storyTooLong = preparedStory.length > bulletinTextMaxLength
  const sources = imageOptions.length ? imageOptions : textFields.length ? [{ value: '', label: 'بلا صورة' }] : []
  const choices = [
    ...sources.slice(0, 1),
    ...(canUpload ? [{ value: 'new', label: 'صورة جديدة' }] : []),
    ...sources.slice(1),
  ]
  const missingText = requireText && textFields.some(({ name }) => !values[name]?.trim())
  const missingPhoto = uploadPhoto && (!selectedFile || selectedFile.size === 0 || selectedFile.size > bulletinPhotoMaxBytes)
  const canSave = !locked && !missingText && !missingPhoto && !storyTooLong

  return (
    <Modal opened title={title} onClose={onClose} closeOnEscape={!save.isPending}
      closeOnClickOutside={false} withCloseButton={!save.isPending}>
      <form onSubmit={(event) => {
        event.preventDefault()
        if (!canSave) return
        save.mutate({
          values: storyField ? { ...values, [storyField]: preparedStory } : values,
          imageChoice, file: selectedFile,
        })
      }}>
        <Stack gap="md">
          {textFields.map(({ name, label }, index) => (
            <Textarea key={name} label={label} dir="rtl" required={requireText} maxLength={bulletinTextMaxLength}
              autosize minRows={index === 0 ? 1 : 3} maxRows={8} autoFocus={index === 0}
              disabled={locked} value={values[name]} error={name === storyField && storyTooLong ? 'قصّر المكان أو متن الخبر.' : undefined}
              onChange={(event) => {
                const text = event.currentTarget.value
                setValues((current) => ({ ...current, [name]: text }))
              }} />
          ))}
          {storyField && <TextInput label="المكان" description="اختياري. يظهر في أول سطر من الخبر." dir="rtl"
            maxLength={bulletinTextMaxLength} disabled={locked} value={location}
            onChange={(event) => setLocation(event.currentTarget.value)} />}
          {choices.length > 1 && <NativeSelect label="مصدر الصورة" data={choices} value={imageChoice}
            disabled={locked} onChange={(event) => {
              setImageChoice(event.currentTarget.value)
              save.reset()
            }} />}
          {uploadPhoto && <BulletinPhotoInput label="ملف الصورة" file={file} disabled={locked} describe onChange={(next) => {
            setFile(next)
            save.reset()
          }} />}
          {selectedFile?.size === 0 && <Alert color="red" role="alert">{messageFor('bulletin_photo_invalid')}</Alert>}
          {save.isPending && <Text size="sm" role="status">{uploadPhoto ? 'جارٍ معالجة الصورة وحفظ الصف…' : 'جارٍ حفظ الصف…'}</Text>}
          {save.error && <Alert color="red" role="alert">{save.error.message}</Alert>}
          <Group justify="flex-end">
            <Button type="button" variant="default" disabled={save.isPending} onClick={onClose}>إلغاء</Button>
            <Button type="submit" loading={save.isPending} disabled={!canSave}>حفظ الصف</Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}

export function BulletinPhotoDialog({ id, rowId, revision, title, field, otherFields = [], onClose, onSaved }: {
  id: string
  rowId: string
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
          {!!otherFields.length && !expanded && <Button type="button" variant="light" size="sm" disabled={upload.isPending || stale}
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
            <Button type="submit" loading={upload.isPending} disabled={!canSubmit}>{expanded ? 'حفظ الصور' : 'حفظ الصورة'}</Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
