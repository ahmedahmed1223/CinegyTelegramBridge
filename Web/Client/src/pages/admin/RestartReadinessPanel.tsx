import { Alert, Button, Group, Modal, Paper, Stack, Text, Title } from '@mantine/core'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatDateTime } from '../../lib/time'

const states: Record<string, string> = {
  disabled: 'إعادة التشغيل عن بُعد معطّلة في إعدادات الجسر.',
  'already-requested': 'طُلبت إعادة تشغيل الجسر بالفعل.',
  'supervisor-reported': 'تعرّف الجسر إلى مشرف خارجي محتمل.',
  'relaunch-command-available': 'استطاع الجسر تحديد أمر إعادة تشغيله محليًا.',
  unavailable: 'تعذّر تحديد طريقة تعيد الجسر إلى العمل.',
  stalled: 'تعذّر إكمال إعادة التشغيل. تحقّق من الجسر محليًا في برنامج المدير.',
}
const resultStates: Record<string, string> = {
  reserved: 'المراجعة مفتوحة.',
  reviewed: 'بانتظار استلام تأكيد المتصفّح.',
  received: 'استلم المشرف الموافقة.',
  granted: 'الجسر يغادر دورة التشغيل.',
  clean: 'اكتمل إغلاق الجسر السابق.',
  launching: 'بانتظار أول قراءة ناجحة من الجسر الجديد.',
  running: 'أعاد المشرف تشغيل الجسر وتحقّق من أول قراءة ناجحة.',
  failed: 'تعذّر التحقّق من إعادة تشغيل الجسر.',
  stalled: 'تعذّر إكمال إعادة التشغيل. تحقّق من الجسر محليًا في برنامج المدير.',
  'relay-active': messageFor('restart_relay_active'),
}
const terminalStates = ['running', 'failed', 'stalled', 'relay-active']
const observationWindow = 5 * 60_000
const duration = new Intl.NumberFormat('ar')

export function RestartReadinessPanel() {
  const [review, setReview] = useState<Schemas['ManagedRestartResult'] | null>(null)
  const [request, setRequest] = useState<string | null>(null)
  const [observationExpired, setObservationExpired] = useState(false)
  const readiness = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/admin/restart/readiness')
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const reviewRequest = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.POST('/api/admin/restart/review')
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (result) => { setRequest(null); setReview(result) },
  })
  const confirmRequest = useMutation({
    mutationFn: async (id: string) => {
      const confirmed = await api.POST('/api/admin/restart/confirm', { body: { id } })
      if (!confirmed.data) throw new Error(errorCode(confirmed.error, confirmed.response))
      setObservationExpired(false)
      setRequest(id)
      setReview(null)
      const accepted = await api.POST('/api/admin/restart/accept', {
        body: { id, receipt: confirmed.data.receipt },
      })
      if (!accepted.data) throw new Error(errorCode(accepted.error, accepted.response))
    },
  })
  const progress = useQuery({
    queryKey: ['managed-restart', request],
    enabled: request !== null && !observationExpired,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/restart/{id}/status', {
        params: { path: { id: request ?? '' } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    refetchInterval: (query) => terminalStates.includes(query.state.data?.state ?? '') ? false : 2000,
  })
  const cancelReview = () => {
    if (review && !confirmRequest.isPending) {
      void api.POST('/api/admin/restart/cancel', { body: { id: review.id } })
      setReview(null)
    }
  }
  const failure = readiness.error ?? reviewRequest.error ?? confirmRequest.error
  const progressState = progress.data?.state ?? ''
  const terminal = terminalStates.includes(progressState)
  useEffect(() => {
    if (!request || terminal) return
    const timeout = setTimeout(() => setObservationExpired(true), observationWindow)
    return () => clearTimeout(timeout)
  }, [request, terminal])
  const complete = progressState === 'running' || progressState === 'failed'
  const progressText = terminal ? resultStates[progressState]
    : observationExpired ? 'تعذّر التحقّق من عودة الجسر ضمن المهلة. افحص حالته في برنامج المدير المحلي.'
      : progress.isError ? 'الاتصال بالجسر غير متاح الآن. يستمر انتظار التحقّق.'
        : resultStates[progressState] ?? 'بانتظار تحديث حالة إعادة التشغيل.'

  return <Paper withBorder radius="md" p="md">
    <Stack gap="xs">
      <Group justify="space-between" gap="xs">
        <Title order={3} size="h5">جاهزية إعادة تشغيل الجسر</Title>
        <Button variant="default" size="xs" loading={readiness.isPending} onClick={() => readiness.mutate(undefined, {
          onSuccess: (current) => {
            if (current.managedRestartAvailable && (terminal || observationExpired)) {
              setRequest(null)
              setObservationExpired(false)
            }
          },
        })}>فحص الجاهزية</Button>
      </Group>
      {failure && <Alert color="red" role="alert">{messageFor(failure.message)}</Alert>}
      {readiness.data && <Stack gap={4} role="status">
        <Text size="sm">{states[readiness.data.state] ?? messageFor('unknown')}</Text>
        <Text size="sm">المشاهد المسجّلة على الهواء {duration.format(readiness.data.activeScenes)}</Text>
        <Text size="xs" c="dimmed">وقت الفحص {formatDateTime(readiness.data.checkedAt)}</Text>
      </Stack>}
      {readiness.data?.relayBlocksRestart && <Alert color="yellow" role="status">{messageFor('restart_relay_active')}</Alert>}
      {readiness.data?.managedRestartAvailable && !observationExpired && (!request || complete) && <Group>
        <Button size="xs" color="red" variant="light" loading={reviewRequest.isPending}
          onClick={() => { confirmRequest.reset(); reviewRequest.mutate() }}>مراجعة إعادة التشغيل</Button>
      </Group>}
      {request && <Text size="sm" role="status">
        {progressText}
      </Text>}
    </Stack>
    <Modal centered opened={review !== null} title="تأكيد إعادة تشغيل الجسر" onClose={cancelReview}
      closeOnClickOutside={!confirmRequest.isPending} closeOnEscape={!confirmRequest.isPending} withCloseButton={!confirmRequest.isPending}>
      <Stack gap="md">
        <Text size="sm">سيغلق الجسر عمله الحالي ثم يبدأ المشرف نسخة جديدة.</Text>
        {review && review.activeScenes > 0 && <Alert color="orange" role="alert">
          المشاهد المسجّلة على الهواء {duration.format(review.activeScenes)}
        </Alert>}
        {confirmRequest.error && <Alert color="red" role="alert">{messageFor(confirmRequest.error.message)}</Alert>}
        <Group justify="flex-end">
          <Button variant="default" disabled={confirmRequest.isPending} onClick={cancelReview}>إلغاء</Button>
          <Button color="red" loading={confirmRequest.isPending} onClick={() => {
            if (review) confirmRequest.mutate(review.id)
          }}>تأكيد إعادة التشغيل</Button>
        </Group>
      </Stack>
    </Modal>
  </Paper>
}
