import { Alert, Button, FileInput, Group, Modal, Stack, Table, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas, uploadAdminSettingsImport } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey } from '../../api/session'

type Review = Schemas['WebSettingsImportPreview']
type Change = Schemas['WebSettingsImportChange']

const errors: Record<string, string> = {
  settings_import_invalid: 'تعذّر قراءة الملف. استخدم ملف إعدادات الويب بقيم صالحة.',
  settings_import_size: 'ملف الإعدادات أكبر من ١٦ كيلوبايت.',
  setting_stale: 'تغيّرت الإعدادات أو انتهت المراجعة. راجع الملف مجددًا.',
  setting_save_failed: 'تعذّر حفظ التغييرات. بقيت الإعدادات السابقة مطبّقة.',
}

function showValue(change: Change, side: 'before' | 'after') {
  if (change.kind === 'boolean') {
    const value = side === 'before' ? change.beforeEnabled : change.afterEnabled
    return value == null ? '—' : value ? 'مفعّل' : 'معطّل'
  }
  const value = side === 'before' ? change.beforeValue : change.afterValue
  return value == null ? '—' : new Intl.NumberFormat('ar').format(value)
}

export function SettingsChangesTable({ changes, labels }: { changes: Change[]; labels: Record<string, string> }) {
  return (
    <Table>
      <Table.Thead><Table.Tr><Table.Th>الإعداد</Table.Th><Table.Th>الحالي</Table.Th><Table.Th>بعد الحفظ</Table.Th></Table.Tr></Table.Thead>
      <Table.Tbody>
        {changes.map((change) => (
          <Table.Tr key={change.id}><Table.Td>{labels[change.id] ?? change.id}</Table.Td>
            <Table.Td>{showValue(change, 'before')}</Table.Td><Table.Td>{showValue(change, 'after')}</Table.Td></Table.Tr>
        ))}
      </Table.Tbody>
    </Table>
  )
}

export function SettingsImportDialog({ labels, onClose }: { labels: Record<string, string>; onClose: () => void }) {
  const cache = useQueryClient()
  const [file, setFile] = useState<File | null>(null)
  const [review, setReview] = useState<Review | null>(null)
  const preview = useMutation({
    mutationFn: (chosen: File) => {
      if (chosen.size > 16 * 1024) throw new Error('settings_import_size')
      return uploadAdminSettingsImport(chosen)
    },
    onSuccess: setReview,
  })
  const apply = useMutation({
    mutationFn: async (token: string) => {
      const { data, error, response } = await api.POST('/api/admin/settings/import/confirm', { body: { review: token } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onError: () => setReview(null),
    onSuccess: async (result) => {
      await Promise.all([
        cache.invalidateQueries({ queryKey: ['admin-overview'] }),
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
  const error = apply.error ?? preview.error
  const busy = apply.isPending || preview.isPending

  return (
    <Modal opened title="استيراد إعدادات الويب" onClose={onClose}
      closeOnClickOutside={!apply.isPending} closeOnEscape={!apply.isPending} withCloseButton={!apply.isPending}>
      <Stack>
        {error && <Alert color="red">{errors[error.message] ?? messageFor(error.message)}</Alert>}
        {!review ? (
          <FileInput label="ملف إعدادات الويب" description="ملف JSON، حتى ١٦ كيلوبايت." accept=".json,application/json"
            value={file} disabled={busy} clearable onChange={(chosen) => { preview.reset(); apply.reset(); setFile(chosen) }} />
        ) : review.changes.length ? (
          <SettingsChangesTable changes={review.changes} labels={labels} />
        ) : <Text size="sm">قيم الملف مطابقة للإعدادات الحالية.</Text>}
        <Group justify="end">
          <Button variant="default" disabled={busy} onClick={review ? () => { setReview(null); preview.reset() } : onClose}>
            {review ? 'رجوع' : 'إلغاء'}
          </Button>
          {review ? (review.review && <Button loading={apply.isPending}
            onClick={() => { if (review.review) apply.mutate(review.review) }}>حفظ التغييرات</Button>) :
            <Button loading={preview.isPending} disabled={!file}
              onClick={() => { if (file) { apply.reset(); preview.mutate(file) } }}>مراجعة الملف</Button>}
        </Group>
      </Stack>
    </Modal>
  )
}
