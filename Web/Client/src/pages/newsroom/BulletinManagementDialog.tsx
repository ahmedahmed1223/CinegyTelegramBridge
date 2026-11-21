import { Alert, Button, Group, Modal, Stack, Text } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

export type BulletinManagementOperation = 'clear' | 'delete'

const labels = { clear: 'إفراغ صفوف الموجز', delete: 'حذف الموجز' }
const managementMessages: Readonly<Record<string, string>> = {
  bulletin_empty: 'الموجز خالٍ من الصفوف.',
  bulletin_on_air: 'أوقف تشغيل هذا الموجز قبل تغيير صفوفه أو حذفه.',
  bulletin_stale: 'تغيّر الموجز أو مواعيده. أغلق المراجعة وحدّث الموجز.',
  bulletin_schedule_save_failed: 'تعذّر حفظ إلغاء المواعيد. بقي الموجز محفوظًا.',
  bulletin_schedule_rollback_failed: 'تعذّر حذف الموجز واستعادة ملف مواعيده. راجع سجل المحطة.',
  bulletin_save_failed: 'تعذّر حفظ التغيير.',
}

export function BulletinManagementDialog({ bulletin, operation, onClose, onSaved }: {
  bulletin: Pick<Schemas['BulletinEditor'], 'id' | 'revision' | 'name'>
  operation: BulletinManagementOperation
  onClose: () => void
  onSaved: (result: Schemas['BulletinManagementResult']) => void
}) {
  const review = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.POST('/api/content/bulletins/management/review', {
        body: { id: bulletin.id, revision: bulletin.revision, operation },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const confirm = useMutation({
    mutationFn: async (token: string) => {
      const { data, error, response } = await api.POST('/api/content/bulletins/management/confirm', { body: { review: token } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: onSaved,
  })
  const plan = review.data
  const busy = review.isPending || confirm.isPending
  const failure = review.error ?? confirm.error
  return (
    <Modal opened title={labels[operation]} onClose={() => { if (!busy) onClose() }}
      closeOnEscape={!busy} closeOnClickOutside={!busy} closeButtonProps={{ 'aria-label': 'إغلاق المراجعة', disabled: busy }}>
      <Stack gap="md">
        <Text fw={600} dir="auto">{plan?.name ?? bulletin.name}</Text>
        {plan && <Stack gap="xs">
          <Text size="sm">الصفوف التي ستُحذف · {plan.rowCount}</Text>
          {operation === 'delete' && plan.pendingCount > 0 && <Text size="sm">المواعيد التي ستُلغى · {plan.pendingCount}</Text>}
          {operation === 'delete' && plan.referenceCount > plan.pendingCount &&
            <Text size="sm">سجلات المواعيد السابقة التي ستُحذف · {plan.referenceCount - plan.pendingCount}</Text>}
          {operation === 'clear' && plan.pendingCount > 0 && <Text size="sm">تبقى المواعيد القائمة ({plan.pendingCount}). أضف صفوفًا قبل موعد العرض.</Text>}
        </Stack>}
        {failure && <Alert color="orange" role="alert">{managementMessages[failure.message] ?? messageFor(failure.message)}</Alert>}
        <Group justify="flex-end">
          <Button variant="default" disabled={busy} onClick={onClose}>العودة</Button>
          {plan ? <Button color="red" loading={confirm.isPending} disabled={busy || confirm.isError}
            onClick={() => confirm.mutate(plan.review)}>{operation === 'delete' ? 'تأكيد الحذف' : 'تأكيد إفراغ الصفوف'}</Button> :
            <Button loading={review.isPending} disabled={busy || review.isError} onClick={() => review.mutate()}>مراجعة التغيير</Button>}
        </Group>
      </Stack>
    </Modal>
  )
}
