import { Alert, Button, Group, Modal, Select, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey, useSession } from '../../api/session'
import { formatDateTime } from '../../lib/time'
import { SettingsChangesTable } from './SettingsImportDialog'

type ReviewCommand = Schemas['WebSettingsRecoveryReviewCommand']
type Review = Schemas['WebSettingsImportPreview']
type Selection = { preview: Review; source: string }

const errors: Record<string, string> = {
  settings_backup_invalid: 'تعذّر قراءة إعدادات الويب المدعومة من هذه النسخة.',
  settings_import_invalid: 'تحتوي النسخة على قيمة غير صالحة لأحد الإعدادات المدعومة.',
  setting_stale: 'تغيّرت النسخة أو الإعدادات أو انتهت المراجعة. حدّث القائمة وراجع التغييرات من جديد.',
  setting_save_failed: 'تعذّر حفظ التغييرات. بقيت الإعدادات السابقة مطبّقة.',
}

const sourceLabels = new Map([
  ['previous', 'الحالة قبل آخر حفظ'],
  ['automatic', 'نسخة تلقائية'],
  ['before-restore', 'نسخة قبل استرجاع سابق'],
])

export function SettingsRecoveryDialog({ labels, onClose }: { labels: Record<string, string>; onClose: () => void }) {
  const cache = useQueryClient()
  const session = useSession()
  const [backup, setBackup] = useState<string | null>(null)
  const [selection, setSelection] = useState<Selection | null>(null)
  const key = ['admin-settings-backups', session.data?.id, session.data?.role] as const
  const backups = useQuery({
    queryKey: key,
    enabled: Boolean(session.data),
    gcTime: 0,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/settings/recovery/backups', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const review = useMutation({
    mutationFn: async (body: ReviewCommand) => {
      const { data, error, response } = await api.POST('/api/admin/settings/recovery/review', { body })
      if (!data) throw new Error(errorCode(error, response))
      return { preview: data, source: body.source }
    },
    onSuccess: setSelection,
    onError: (error: Error) => {
      if (error.message === 'setting_stale') {
        setBackup(null)
        void cache.invalidateQueries({ queryKey: key })
      }
    },
  })
  const apply = useMutation({
    mutationFn: async (token: string) => {
      const { data, error, response } = await api.POST('/api/admin/settings/recovery/confirm', { body: { review: token } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onError: () => {
      setSelection(null)
      setBackup(null)
      void cache.invalidateQueries({ queryKey: key })
    },
    onSuccess: async (result) => {
      await Promise.all([
        cache.invalidateQueries({ queryKey: ['admin-overview'] }),
        cache.invalidateQueries({ queryKey: key }),
        cache.invalidateQueries({ queryKey: sessionKey }),
      ])
      notifications.show({
        title: 'حُفظت إعدادات الويب',
        message: `عدد القيم التي تغيّرت: ${new Intl.NumberFormat('ar').format(result.applied)}.`,
        color: 'teal',
      })
      onClose()
    },
  })
  const resultError = apply.error ?? review.error ?? backups.error
  const busy = apply.isPending || review.isPending
  const options = backups.data?.items.map((item) => ({
    value: item.id,
    label: `${sourceLabels.get(item.kind) ?? 'نسخة إعدادات'} · ${formatDateTime(item.savedAt)}`,
  })) ?? []

  function startPreview(body: ReviewCommand) {
    apply.reset()
    review.mutate(body)
  }

  return (
    <Modal opened title="استرجاع إعدادات الويب" onClose={onClose}
      closeOnClickOutside={!apply.isPending} closeOnEscape={!apply.isPending} withCloseButton={!apply.isPending}>
      <Stack>
        <Text size="sm" c="dimmed">يمكن استرجاع الإعدادات القابلة للتعديل من نسخة محفوظة أو إعادتها إلى قيمها الافتراضية.</Text>
        {resultError && <Alert color="red" role="alert">{errors[resultError.message] ?? messageFor(resultError.message)}</Alert>}
        {selection ? (
          <>
            <Text fw={600}>{selection.source === 'defaults' ? 'القيم الافتراضية المسجّلة' : 'النسخة المحفوظة المختارة'}</Text>
            {selection.preview.changes.length ? <SettingsChangesTable changes={selection.preview.changes} labels={labels} />
              : <Text size="sm">القيم المقترحة مطابقة للإعدادات الحالية.</Text>}
            <Group justify="end">
              <Button variant="default" disabled={busy} onClick={() => { setSelection(null); review.reset() }}>رجوع</Button>
              {selection.preview.review && <Button loading={apply.isPending}
                onClick={() => { if (selection.preview.review) apply.mutate(selection.preview.review) }}>حفظ التغييرات</Button>}
            </Group>
          </>
        ) : (
          <>
            <Select label="نسخة محفوظة" placeholder={backups.isPending ? 'جارٍ تحميل النسخ' : 'اختر نسخة'}
              data={options} value={backup} onChange={(value) => setBackup(typeof value === 'string' ? value : null)}
              disabled={busy || backups.isPending || backups.isError} />
            {backups.data?.truncated && <Text c="dimmed" size="xs">تعرض القائمة أحدث نسخ الاسترجاع المتاحة.</Text>}
            {backups.data && !options.length && <Text c="dimmed" size="sm">لا توجد نسخ محفوظة متاحة.</Text>}
            {backups.isError && <Button variant="subtle" onClick={() => void backups.refetch()}>تحديث قائمة النسخ</Button>}
            <Group justify="end">
              <Button variant="default" disabled={busy}
                onClick={() => startPreview({ source: 'defaults', backup: '' })}>مراجعة القيم الافتراضية</Button>
              <Button loading={review.isPending && review.variables?.source === 'backup'} disabled={busy || !backup || backups.isError}
                onClick={() => { if (backup) startPreview({ source: 'backup', backup }) }}>مراجعة النسخة</Button>
            </Group>
          </>
        )}
      </Stack>
    </Modal>
  )
}
