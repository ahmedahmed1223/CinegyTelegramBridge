import { Alert, Button, Group, Modal, Stack, Text } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

const number = new Intl.NumberFormat('ar')
const messages: Record<string, string> = {
  template_registry_export_invalid: 'تعذّر تصدير سجل بصيغة تصلح للاستيراد.',
  template_registry_export_unavailable: 'تعذّر الوصول إلى سجل القوالب المحلي.',
  template_registry_export_size: 'يتجاوز السجل حد تنزيل الويب البالغ ١٠ ميغابايت.',
  template_registry_export_stale: 'تغيّر السجل أو انتهت صلاحية المراجعة. راجع السجل مجددًا.',
}

export function TemplateRegistryExport({ onClose }: { onClose: () => void }) {
  const review = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.POST('/api/air/template-registry/export/review')
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const download = useMutation({
    mutationFn: async (token: string) => {
      const { data, error, response } = await api.POST('/api/air/template-registry/export/download', {
        body: { review: token }, parseAs: 'blob',
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (file) => {
      const url = URL.createObjectURL(file)
      const link = document.createElement('a')
      link.href = url
      link.download = 'templates.json'
      link.click()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      onClose()
    },
  })
  const error = download.error ?? review.error
  const busy = review.isPending || download.isPending
  const selection = review.data
  return (
    <Modal opened onClose={() => { if (!busy) onClose() }} title="تنزيل سجل القوالب">
      <Stack>
        <Text>يتضمن الملف تعريفات القوالب ومسارات المشاهد والقيم المحفوظة.</Text>
        {selection && <Text>{number.format(selection.templates)} قالبًا · {number.format(selection.bytes)} بايت</Text>}
        {error && <Alert color="red" role="alert">{messages[error.message] ?? messageFor(error.message)}</Alert>}
        <Group justify="flex-end">
          <Button variant="default" disabled={busy} onClick={onClose}>إلغاء</Button>
          {!selection || error ? (
            <Button loading={review.isPending} onClick={() => { download.reset(); review.mutate() }}>مراجعة السجل</Button>
          ) : (
            <Button loading={download.isPending} onClick={() => download.mutate(selection.review)}>تنزيل الملف</Button>
          )}
        </Group>
      </Stack>
    </Modal>
  )
}
