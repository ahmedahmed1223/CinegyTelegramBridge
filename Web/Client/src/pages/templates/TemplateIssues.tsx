import { Alert, Button, Group, Loader, Modal, Paper, ScrollArea, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Command = Schemas['TemplateIssueCommand']
type Preview = Schemas['TemplateIssuePreview']

const reasons: Record<string, string> = {
  missing_path: 'مسار ملف المشهد مفقود.',
  unresolved_path: 'تعذّر تفسير مسار ملف المشهد.',
  invalid_extension: 'امتداد ملف المشهد غير صالح.',
  invalid_layer: 'رقم الطبقة غير صالح.',
}

const errors: Record<string, string> = {
  scene_registry_stale: 'تغيّرت القوالب الحالية أو انتهت المراجعة. راجع القالب مجددًا.',
  scene_registry_failed: 'تعذّر تحميل سجل القوالب أو حفظه.',
  scene_definition_live: 'توجد إشارة نشطة على طبقة مرتبطة بالقالب.',
  scene_definition_scheduled: 'القالب مرتبط بموعد تشغيل.',
  scene_definition_linked: 'القالب مرتبط بنشرة أو لوحة.',
  scene_definition_alias: 'الحذف يتعارض مع ربط الطبقة بجهاز العرض.',
  template_issue_layer_unverified: 'تعذّر التحقق من أن جميع الأجهزة المرتبطة بالقالب خالية.',
}

async function manage(command: Pick<Command, 'action'> & Partial<Command>, signal?: AbortSignal) {
  const body: Command = { id: null, review: null, ...command }
  const { data, error, response } = await api.POST('/api/air/template-issues', { body, signal })
  if (error || !data) throw new Error(errorCode(error, response))
  return data
}

export function TemplateIssues({ onClose }: { onClose: () => void }) {
  const cache = useQueryClient()
  const [approval, setApproval] = useState<Preview | null>(null)
  const catalogue = useQuery({
    queryKey: ['template-issues'],
    queryFn: ({ signal }) => manage({ action: 'list' }, signal),
    retry: false,
    gcTime: 0,
  })
  const preview = useMutation({
    mutationFn: async (id: string) => {
      const result = (await manage({ action: 'preview', id })).preview
      if (!result) throw new Error('scene_registry_failed')
      return result
    },
    onSuccess: setApproval,
  })
  const remove = useMutation({
    mutationFn: async (decision: Preview) => {
      const result = await manage({ action: 'delete', id: decision.issue.id, review: decision.review })
      if (!result.deleted) throw new Error('scene_registry_failed')
    },
    onError: () => setApproval(null),
    onSuccess: async () => {
      setApproval(null)
      await Promise.all([
        cache.invalidateQueries({ queryKey: ['templates'] }),
        cache.invalidateQueries({ queryKey: ['template-issues'] }),
      ])
      notifications.show({ title: 'حُذف القالب', message: 'حُفظت نسخة احتياطية من السجل.', color: 'teal' })
    },
  })
  const error = remove.error ?? preview.error ?? catalogue.error
  const pending = preview.isPending || remove.isPending
  const rows = catalogue.data?.items ?? []
  return (
    <Modal opened title="القوالب غير الصالحة" onClose={onClose} scrollAreaComponent={ScrollArea.Autosize}
      closeOnClickOutside={!remove.isPending} closeOnEscape={!remove.isPending} withCloseButton={!remove.isPending}>
      <Stack>
        {catalogue.isPending && <Loader size="sm" aria-label="جاري تحميل القوالب" />}
        {error && <Alert color="red">{errors[error.message] ?? messageFor(error.message)}</Alert>}
        {approval ? (
          <>
            <Alert color="yellow">سيُحذف <strong>{approval.issue.name}</strong> من السجل بعد حفظ نسخة احتياطية.</Alert>
            <Text size="sm">{reasons[approval.issue.reason]}</Text>
            <Group justify="end">
              <Button variant="default" disabled={pending} onClick={() => setApproval(null)}>رجوع</Button>
              <Button color="red" loading={remove.isPending} onClick={() => remove.mutate(approval)}>تأكيد الحذف</Button>
            </Group>
          </>
        ) : (
          <>
            {!catalogue.isPending && !catalogue.error && !rows.length && <Text c="dimmed">لا توجد قوالب غير صالحة.</Text>}
            {catalogue.data?.truncated && <Text size="sm" c="dimmed">تظهر أول ٨٠ نتيجة.</Text>}
            {rows.map((item) => (
              <Paper key={item.id} withBorder p="sm">
                <Group justify="space-between" gap="sm">
                  <div>
                    <Text fw={600}>{item.name || 'اسم غير قابل للعرض'}</Text>
                    <Text size="sm" c="dimmed">{reasons[item.reason]}</Text>
                    {!item.canReview && <Text size="xs" c="dimmed">الحذف غير متاح لهذا القالب.</Text>}
                  </div>
                  {item.canReview && <Button color="red" variant="light" disabled={pending}
                    onClick={() => { remove.reset(); preview.mutate(item.id) }}>مراجعة الحذف</Button>}
                </Group>
              </Paper>
            ))}
          </>
        )}
      </Stack>
    </Modal>
  )
}
