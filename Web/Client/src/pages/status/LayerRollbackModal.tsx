import { Alert, Button, Group, Modal, Skeleton, Stack, Table, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Plan = NonNullable<Schemas['AirRollbackPlan']>
type Command = Schemas['AirRollbackCommand']

const number = new Intl.NumberFormat('ar')
const time = new Intl.DateTimeFormat('ar', { timeStyle: 'medium' })
const rollbackErrors: Record<string, string> = {
  rollback_invalid: 'تعذّرت قراءة طلب التراجع.',
  rollback_missing: 'انتهت مهلة التراجع أو لم يعد الإجراء متاحًا لهذا الحساب.',
  rollback_stale: 'تغيّر المشهد أو الإجراء منذ المراجعة. حدّث القائمة وأعد المراجعة.',
  rollback_managed: 'يدير الجسر هذه الطبقة ضمن تشغيل آخر، أو يتعذّر تحديد مشهد واحد عليها.',
  rollback_scheduled: 'يوجد عرض مجدول يستخدم الجهاز نفسه.',
  rollback_busy: 'يجري تجهيز عرض لهذه الطبقة.',
  rollback_unavailable: 'لا يمكن استعادة المشهد السابق بأمان.',
  rollback_unverified: 'تعذّر التحقق من حالة الطبقة أو من ملف المشهد السابق.',
  rollback_refused: 'تعذّر تأكيد تنفيذ التراجع. تحقّق من لوحة الهواء قبل إرسال طلب آخر.',
}

async function requestRollback(command: Pick<Command, 'action'> & Partial<Command>, signal?: AbortSignal) {
  const body: Command = { layer: null, review: null, ...command }
  const { data, error, response } = await api.POST('/api/air/rollback', { body, signal })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

export function LayerRollbackModal({ onClose }: { onClose: () => void }) {
  const [review, setReview] = useState<(Plan & { review: string }) | null>(null)
  const candidates = useQuery({
    queryKey: ['air-rollback'],
    queryFn: async ({ signal }) => (await requestRollback({ action: 'list' }, signal)).candidates ?? [],
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: false,
  })
  const preview = useMutation({
    mutationFn: async (layer: number) => {
      const result = (await requestRollback({ action: 'preview', layer })).preview
      if (!result?.review) throw new Error('rollback_stale')
      return { ...result, review: result.review }
    },
    onSuccess: setReview,
  })
  const apply = useMutation({
    mutationFn: (plan: Plan & { review: string }) => requestRollback({ action: 'apply', layer: plan.layer, review: plan.review }),
    onSuccess: result => {
      notifications.show({
        color: result.sceneConfirmed ? 'teal' : 'orange',
        message: result.sceneConfirmed ? 'تأكّد التراجع على الطبقة.' : 'قُبل أمر التراجع. تحقّق من حالة الطبقة في لوحة الهواء.',
      })
      onClose()
    },
  })
  const pending = preview.isPending || apply.isPending
  const error = apply.error ?? preview.error ?? candidates.error

  function refresh() {
    if (pending) return
    setReview(null)
    preview.reset()
    apply.reset()
    void candidates.refetch()
  }

  return (
    <Modal opened title={review ? 'مراجعة التراجع' : 'التراجع عن إجراء على الهواء'} size="md"
      onClose={() => { if (!pending) onClose() }} withCloseButton={!pending} closeOnEscape={!pending}
      closeOnClickOutside={!pending}>
      <Stack gap="md" dir="rtl">
        {error && (
          <Alert role="alert" color="orange">{rollbackErrors[error.message] ?? messageFor(error.message)}</Alert>
        )}
        {review ? (
          <>
            <Text fw={600}>الطبقة {number.format(review.layer)}</Text>
            <Alert color="orange">
              {review.action === 'clear' ? (
                <>سيُخفى <bdi>{review.currentName || review.templateKey}</bdi> وتعود الطبقة فارغة.</>
              ) : (
                <>سيُستعاد <bdi>{review.templateKey}</bdi>{review.currentName && <> بدلًا من <bdi>{review.currentName}</bdi></>}.</>
              )}
            </Alert>
            <Text size="sm" c="dimmed">ينتهي إمكان التراجع عند {time.format(review.expiresAt)}</Text>
            <Group justify="flex-end">
              <Button variant="default" disabled={pending} onClick={refresh}>رجوع</Button>
              <Button color="orange" loading={apply.isPending} disabled={!!apply.error}
                onClick={() => apply.mutate(review)}>تأكيد التراجع</Button>
            </Group>
          </>
        ) : (
          <>
            {candidates.isFetching ? <Skeleton h={72} aria-label="جارٍ تحميل إجراءات التراجع" /> :
              !candidates.error && (candidates.data?.length ? (
                <Table withRowBorders aria-label="إجراءات التراجع" style={{ overflowWrap: 'anywhere' }}>
                  <Table.Thead><Table.Tr><Table.Th scope="col">الطبقة</Table.Th><Table.Th scope="col">القالب</Table.Th>
                    <Table.Th scope="col">الإجراء</Table.Th></Table.Tr></Table.Thead>
                  <Table.Tbody>
                    {candidates.data.map(candidate => (
                      <Table.Tr key={candidate.layer}>
                        <Table.Th scope="row">{number.format(candidate.layer)}</Table.Th>
                        <Table.Td><bdi>{candidate.templateKey}</bdi></Table.Td>
                        <Table.Td>
                          <Button size="compact-sm" variant="light" disabled={pending}
                            onClick={() => preview.mutate(candidate.layer)}
                            aria-label={`مراجعة التراجع عن الطبقة ${number.format(candidate.layer)}`}>
                            {candidate.action === 'clear' ? 'مراجعة الإخفاء' : 'مراجعة الاستعادة'}
                          </Button>
                        </Table.Td>
                      </Table.Tr>
                    ))}
                  </Table.Tbody>
                </Table>
              ) : <Text size="sm" c="dimmed">لا توجد إجراءات متاحة للتراجع.</Text>)}
            <Group justify="flex-end">
              <Button variant="default" disabled={pending} onClick={onClose}>إغلاق</Button>
              <Button variant="light" disabled={pending || candidates.isFetching} onClick={refresh}>تحديث القائمة</Button>
            </Group>
          </>
        )}
      </Stack>
    </Modal>
  )
}
