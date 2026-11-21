import { Alert, Button, Group, Loader, Modal, Paper, ScrollArea, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type BackupCommand = Schemas['TemplateBackupCommand']
type Preview = Schemas['TemplateBackupPreview']

const errors: Record<string, string> = {
  template_backup_stale: 'تغيّرت النسخة أو القوالب الحالية. راجع النسخة مجددًا.',
  template_backup_identical: 'النسخة مطابقة للقوالب الحالية.',
  template_backup_invalid: 'تعذّر قراءة تعريفات النسخة بصيغتها الحالية.',
  template_backup_unavailable: 'تعذّر الوصول إلى النسخة أو حفظ الاستعادة.',
  scene_definition_live: 'يتأثر قالب معروض على الهواء بهذه الاستعادة.',
  scene_definition_scheduled: 'يتأثر قالب مجدول بهذه الاستعادة.',
  scene_definition_linked: 'يتأثر قالب مرتبط بنشرة أو لوحة بهذه الاستعادة.',
  scene_definition_alias: 'تتعارض الاستعادة مع ربط الطبقات بأجهزة العرض.',
}

function backupError(error: Error) {
  return errors[error.message] ?? messageFor(error.message)
}

async function manage(command: Pick<BackupCommand, 'action'> & Partial<BackupCommand>, signal?: AbortSignal) {
  const body: BackupCommand = { id: null, review: null, ...command }
  const { data, error, response } = await api.POST('/api/air/template-backups', { body, signal })
  if (error || !data) throw new Error(errorCode(error, response))
  return data
}

const date = Intl.DateTimeFormat('ar', { dateStyle: 'medium', timeStyle: 'medium' })
const formatSize = Intl.NumberFormat('ar', { style: 'unit', unit: 'kilobyte', maximumFractionDigits: 1 })

export function TemplateBackups({ onClose }: { onClose: () => void }) {
  const cache = useQueryClient()
  const [review, setReview] = useState<Preview | null>(null)
  const backups = useQuery({
    queryKey: ['template-backups'],
    queryFn: ({ signal }) => manage({ action: 'list' }, signal),
    retry: false,
    gcTime: 0,
  })
  const preview = useMutation({
    mutationFn: async (id: string) => {
      const result = (await manage({ action: 'preview', id })).preview
      if (!result) throw new Error('template_backup_unavailable')
      return result
    },
    onSuccess: setReview,
  })
  const restore = useMutation({
    mutationFn: async (approved: Preview) => {
      const result = await manage({ action: 'restore', id: approved.id, review: approved.review })
      if (!result.restored) throw new Error('template_backup_unavailable')
    },
    onError: () => setReview(null),
    onSuccess: async () => {
      await cache.invalidateQueries({ queryKey: ['templates'] })
      notifications.show({ title: 'استُعيدت نسخة القوالب', message: 'حُفظت نسخة من القوالب السابقة.', color: 'teal' })
      onClose()
    },
  })
  const error = restore.error ?? preview.error ?? backups.error
  const pending = restore.isPending || preview.isPending
  const rows = backups.data?.backups ?? []

  return (
    <Modal opened title="نسخ القوالب الاحتياطية" onClose={onClose} scrollAreaComponent={ScrollArea.Autosize}
      closeOnClickOutside={!restore.isPending} closeOnEscape={!restore.isPending} withCloseButton={!restore.isPending}>
      <Stack>
        {backups.isPending && <Loader size="sm" aria-label="جاري تحميل النسخ" />}
        {error && <Alert color="red">{backupError(error)}</Alert>}
        {review ? (
          <>
            <Alert color="yellow">تستبدل الاستعادة تعريفات القوالب الحالية بعد حفظ نسخة منها.</Alert>
            <ChangeList title="قوالب ستُضاف" keys={review.added} />
            <ChangeList title="قوالب ستتغيّر" keys={review.changed} />
            <ChangeList title="قوالب ستُزال" keys={review.removed} />
            <Group justify="end">
              <Button variant="default" disabled={pending} onClick={() => setReview(null)}>رجوع</Button>
              <Button color="red" loading={restore.isPending} onClick={() => restore.mutate(review)}>تأكيد الاستعادة</Button>
            </Group>
          </>
        ) : (
          <>
            {!backups.isPending && !backups.error && !rows.length && <Text c="dimmed">لا توجد نسخ متاحة.</Text>}
            {backups.data?.truncated && <Text size="sm" c="dimmed">تظهر أحدث ٨٠ نسخة.</Text>}
            {rows.map((backup) => (
              <Paper key={backup.id} withBorder p="sm">
                <Group justify="space-between" gap="sm">
                  <div>
                    <Text fw={600}>{date.format(backup.savedAt)}</Text>
                    <Text size="sm" c="dimmed">{formatSize.format(backup.bytes / 1024)}</Text>
                  </div>
                  <Button variant="light" disabled={pending} onClick={() => { restore.reset(); preview.mutate(backup.id) }}>
                    مراجعة النسخة
                  </Button>
                </Group>
              </Paper>
            ))}
          </>
        )}
      </Stack>
    </Modal>
  )
}

function ChangeList({ title, keys }: { title: string; keys: string[] }) {
  if (!keys.length) return null
  return (
    <Stack gap={4}>
      <Text fw={600}>{title} ({keys.length})</Text>
      <Text size="sm" style={{ overflowWrap: 'anywhere' }}>{keys.join('، ')}</Text>
    </Stack>
  )
}
