import { Alert, Button, Group, Modal, Skeleton, Stack, Table, Text } from '@mantine/core'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

type Maintenance = NonNullable<Schemas['AirMaintenanceState']>
type MaintenanceReview = { state: Maintenance; enabled: boolean; token: string }
const number = new Intl.NumberFormat('ar')
const apiErrors: Record<string, string> = {
  maintenance_invalid: 'تعذّرت قراءة طلب الصيانة.',
  maintenance_stale: 'تغيّر وضع الصيانة منذ المراجعة. حمّل الحالة الحالية من جديد.',
  maintenance_save_failed: 'تعذّر حفظ وضع الصيانة وبقيت حالته السابقة سارية.',
  emergency_invalid: 'تعذّرت قراءة طلب الإخفاء الطارئ.',
  emergency_stale: 'تغيّرت إحدى الطبقات منذ المراجعة. راجع الطبقات من جديد.',
  emergency_ambiguous: 'يتعذّر تحديد هدف واحد لكل طبقة في هذا الوضع.',
  emergency_unverified: 'تعذّر التحقق من إحدى الطبقات. راجع لوحة الهواء.',
  emergency_none: 'لا توجد طبقات معروضة ومسموح بإخفائها ضمن إعداد الإخفاء الطارئ.',
}

function errorText(error: Error) {
  return apiErrors[error.message] ?? messageFor(error.message)
}

async function maintenanceRequest(action: string, enabled: boolean | null, review: string | null, signal?: AbortSignal) {
  const body: Schemas['AirMaintenanceCommand'] = { action, enabled, review }
  const { data, error, response } = await api.POST('/api/air/maintenance', { body, signal })
  if (!data?.maintenance) throw new Error(errorCode(error, response))
  return data.maintenance
}

async function emergencyRequest(action: string, review: string | null, signal?: AbortSignal) {
  const body: Schemas['EmergencyHideCommand'] = { action, review }
  const { data, error, response } = await api.POST('/api/air/emergency-hide', { body, signal })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

function MaintenanceDetails({ status }: { status: Maintenance }) {
  return (
    <Stack gap={4}>
      <Text fw={600}>{status.manualEnabled ? 'الصيانة اليدوية مفعّلة' : 'الصيانة اليدوية متوقفة'}</Text>
      <Text size="sm">{status.effectiveBlocked ? 'أوامر العرض العادية معلّقة.' : 'أوامر العرض العادية متاحة.'}</Text>
      {status.windowStart && status.windowEnd && (
        <Text size="sm" c="dimmed">
          {status.windowActive ? 'نافذة الصيانة نشطة' : 'نافذة الصيانة المجدولة'} <bdi>{status.windowStart} – {status.windowEnd}</bdi>
        </Text>
      )}
    </Stack>
  )
}

export function AirMaintenanceModal({ onClose }: { onClose: () => void }) {
  const queryClient = useQueryClient()
  const [review, setReview] = useState<MaintenanceReview | null>(null)
  const state = useQuery({
    queryKey: ['air-maintenance'],
    queryFn: ({ signal }) => maintenanceRequest('inspect', null, null, signal),
    gcTime: 0, retry: false, refetchOnWindowFocus: false, refetchOnReconnect: false,
  })
  const prepare = useMutation({
    mutationFn: async (enabled: boolean) => {
      const next = await maintenanceRequest('preview', enabled, null)
      if (!next.review || next.requestedEnabled !== enabled) throw new Error('maintenance_stale')
      return { state: next, enabled, token: next.review }
    },
    onSuccess: setReview,
  })
  const apply = useMutation({
    mutationFn: (decision: MaintenanceReview) => maintenanceRequest('apply', decision.enabled, decision.token),
    onSuccess: status => {
      queryClient.setQueryData(['air-maintenance'], status)
      setReview(null)
    },
  })
  const pending = prepare.isPending || apply.isPending
  const error = apply.error ?? prepare.error ?? state.error
  const current = state.data

  function refresh() {
    setReview(null)
    prepare.reset()
    apply.reset()
    void state.refetch()
  }

  return (
    <Modal opened title={review ? 'مراجعة وضع الصيانة' : 'وضع الصيانة'} onClose={() => { if (!pending) onClose() }}
      withCloseButton={!pending} closeOnEscape={!pending} closeOnClickOutside={!pending}>
      <Stack gap="md" dir="rtl">
        {state.isFetching ? <Skeleton h={74} aria-label="جارٍ تحميل وضع الصيانة" /> : current && (
          <MaintenanceDetails status={review?.state ?? current} />
        )}
        {error && <Alert color="orange" role="alert">{errorText(error)}</Alert>}
        {review ? (
          <>
            <Alert color="orange">
              {review.enabled ? 'سيُفعّل وضع الصيانة اليدوية وتتوقّف أوامر العرض العادية.' : review.state.effectiveAfter
                ? 'ستتوقّف الصيانة اليدوية وتستمر نافذة الصيانة المجدولة في تعليق أوامر العرض.'
                : 'ستتوقّف الصيانة اليدوية وتتاح أوامر العرض العادية.'}
            </Alert>
            <Group justify="flex-end">
              <Button variant="default" disabled={pending} onClick={refresh}>رجوع</Button>
              <Button color="orange" loading={apply.isPending} disabled={!!apply.error}
                onClick={() => apply.mutate(review)}>تأكيد التغيير</Button>
            </Group>
          </>
        ) : (
          <Group justify="flex-end">
            <Button variant="default" disabled={pending} onClick={onClose}>إغلاق</Button>
            {error ? <Button variant="light" disabled={state.isFetching} onClick={refresh}>تحميل الحالة الحالية</Button> :
              current && !state.isFetching && (
                <Button variant="light" loading={prepare.isPending} onClick={() => prepare.mutate(!current.manualEnabled)}>
                  {current.manualEnabled ? 'مراجعة إنهاء الصيانة اليدوية' : 'مراجعة تشغيل الصيانة اليدوية'}
                </Button>
              )}
          </Group>
        )}
      </Stack>
    </Modal>
  )
}

const receiptLabels: Record<string, string> = { sent: 'قُبل أمر الإخفاء', failed: 'تعذّر إرسال الإخفاء', skipped: 'لم يُرسل الإخفاء' }

export function EmergencyHideModal({ onClose }: { onClose: () => void }) {
  const preview = useQuery({
    queryKey: ['air-emergency-hide'],
    queryFn: async ({ signal }) => {
      const result = await emergencyRequest('preview', null, signal)
      if (!result.preview) throw new Error('emergency_unverified')
      return result.preview
    },
    gcTime: 0, retry: false, refetchOnWindowFocus: false, refetchOnReconnect: false,
  })
  const apply = useMutation({
    mutationFn: async (review: string) => {
      const result = await emergencyRequest('apply', review)
      if (!result.results) throw new Error('emergency_unverified')
      return result.results
    },
  })
  const error = apply.error ?? preview.error
  const plan = preview.data
  const busy = apply.isPending
  return (
    <Modal opened title="الإخفاء الطارئ" size="md" onClose={() => { if (!busy) onClose() }}
      withCloseButton={!busy} closeOnEscape={!busy} closeOnClickOutside={!busy}>
      <Stack gap="md" dir="rtl">
        {error && <Alert role="alert" color="orange">{errorText(error)}</Alert>}
        {preview.isFetching ? <Skeleton h={80} aria-label="جارٍ التحقق من الطبقات" /> : apply.data ? (
          <>
            <Table withRowBorders aria-label="نتيجة أوامر الإخفاء">
              <Table.Thead><Table.Tr><Table.Th scope="col">الطبقة</Table.Th><Table.Th scope="col">النتيجة</Table.Th></Table.Tr></Table.Thead>
              <Table.Tbody>{apply.data.map(item => <Table.Tr key={item.layer}>
                <Table.Th scope="row">{number.format(item.layer)}</Table.Th>
                <Table.Td>{receiptLabels[item.status] ?? 'النتيجة غير مؤكدة'}</Table.Td>
              </Table.Tr>)}</Table.Tbody>
            </Table>
            <Text size="sm" c="dimmed">تابع حالة الطبقات في لوحة الهواء.</Text>
          </>
        ) : plan && (
          <>
            <Alert color="red">سيُرسل الإخفاء إلى المشاهد أدناه وقد يتوقف التشغيل المرتبط بطبقاتها.</Alert>
            <Table withRowBorders aria-label="الطبقات المطلوب إخفاؤها">
              <Table.Thead><Table.Tr><Table.Th scope="col">الطبقة</Table.Th><Table.Th scope="col">المشهد</Table.Th></Table.Tr></Table.Thead>
              <Table.Tbody>{plan.targets.map(target => <Table.Tr key={target.layer}>
                <Table.Th scope="row">{number.format(target.layer)}</Table.Th>
                <Table.Td><bdi>{target.name || 'مشهد معروض'}</bdi></Table.Td>
              </Table.Tr>)}</Table.Tbody>
            </Table>
            {!!plan.blockedLayers.length && <Text size="sm" c="dimmed">طبقات خارج صلاحية هذا الطلب {plan.blockedLayers.map(item => number.format(item)).join('، ')}</Text>}
          </>
        )}
        <Group justify="flex-end">
          <Button variant="default" disabled={busy} onClick={onClose}>{apply.data ? 'إغلاق' : 'إلغاء'}</Button>
          {error ? <Button variant="light" disabled={preview.isFetching} onClick={() => { apply.reset(); void preview.refetch() }}>إعادة المراجعة</Button> :
            plan && !preview.isFetching && !apply.data && <Button color="red" loading={busy}
              onClick={() => apply.mutate(plan.review)}>تأكيد إخفاء الطبقات</Button>}
        </Group>
      </Stack>
    </Modal>
  )
}
