import { Alert, Button, FileInput, Group, Modal, Stack, Text } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { uploadTemplateRegistry } from '../../api/client'
import { messageFor } from '../../api/messages'

const number = new Intl.NumberFormat('ar')
const errors: Record<string, string> = {
  template_registry_import_invalid: 'السجل أو أحد تعريفات القوالب غير صالح.',
  template_registry_import_size: 'يتجاوز الملف حد الاستيراد البالغ ١٠ ميغابايت.',
  template_registry_import_path: 'يجب أن يكون كل ملف مشهد جديد أو متغيّر داخل مجلد المشاهد المحلي المعتمد.',
  template_registry_import_path_count: 'يتجاوز الملف حد الأربعين مسارًا جديدًا أو متغيّرًا في مراجعة واحدة.',
  template_registry_import_stale: 'تغيّر السجل أو ملف المشهد أو انتهت صلاحية المراجعة. أعد المراجعة.',
  template_registry_import_unavailable: 'تعذّر قراءة السجل المحلي أو حفظه.',
  template_backup_identical: 'الملف مطابق لتعريفات السجل الحالي.',
  scene_definition_live: 'يشمل التغيير قالبًا أو طبقة معروضة حاليًا.',
  scene_definition_scheduled: 'يشمل التغيير قالبًا مرتبطًا بموعد.',
  scene_definition_linked: 'يشمل التغيير قالبًا مرتبطًا بمحتوى غرفة الأخبار.',
  scene_definition_alias: 'تتعارض طبقات الملف مع أسماء أجهزة العرض أو طبقة الاختبار.',
}

export function TemplateRegistryImport({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const [file, setFile] = useState<File | null>(null)
  const review = useMutation({ mutationFn: (selected: File) => uploadTemplateRegistry(selected) })
  const apply = useMutation({
    mutationFn: ({ selected, token }: { selected: File; token: string }) => uploadTemplateRegistry(selected, token),
    onSuccess: () => { onSaved(); onClose() },
  })
  const selection = review.data
  const error = apply.error ?? review.error
  const tooLarge = Boolean(file && file.size > 10 * 1024 * 1024)
  const errorText = tooLarge ? errors.template_registry_import_size : error ? errors[error.message] ?? messageFor(error.message) : ''
  const busy = apply.isPending || review.isPending
  return (
    <Modal opened onClose={() => { if (!busy) onClose() }} title="استيراد سجل القوالب">
      <Stack>
        <FileInput label="ملف سجل القوالب" description="ملف JSON بحجم لا يتجاوز ١٠ ميغابايت."
          accept=".json,application/json" value={file} disabled={busy} clearable
          clearButtonProps={{ 'aria-label': 'إزالة الملف المختار' }}
          onChange={(value) => { setFile(value); review.reset(); apply.reset() }} />
        {selection && (
          <>
            <Text>سيحلّ الملف محلّ سجل القوالب الحالي. تُحفظ نسخة من السجل قبل الاستبدال.</Text>
            <Text>{number.format(selection.added)} جديد · {number.format(selection.changed)} معدّل · {number.format(selection.removed)} محذوف · {number.format(selection.unchanged)} دون تعديل</Text>
          </>
        )}
        {errorText && <Alert color="red" role="alert">{errorText}</Alert>}
        <Group justify="flex-end">
          <Button variant="default" disabled={busy} onClick={onClose}>إلغاء</Button>
          {!selection || error ? (
            <Button disabled={!file || tooLarge} loading={review.isPending}
              onClick={() => { if (file) { apply.reset(); review.mutate(file) } }}>مراجعة الملف</Button>
          ) : (
            <Button disabled={!file} loading={apply.isPending}
              onClick={() => { if (file) apply.mutate({ selected: file, token: selection.review }) }}>استبدال السجل</Button>
          )}
        </Group>
      </Stack>
    </Modal>
  )
}
