import { Alert, Badge, Button, Group, Modal, Pagination, Paper, Skeleton, Stack, Text, TextInput } from '@mantine/core'
import { modals } from '@mantine/modals'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatDateTime, localDateInput } from '../../lib/time'

const scheduleStates: Record<string, { label: string; color: string }> = {
  scheduled: { label: 'مجدول', color: 'blue' },
  queued: { label: 'في الانتظار', color: 'orange' },
  running: { label: 'على الهواء', color: 'red' },
  completed: { label: 'اكتمل', color: 'teal' },
  failed: { label: 'تعذّر التشغيل', color: 'red' },
}
const waitingReasons: Record<string, string> = {
  active_bulletin: 'يوجد موجز آخر على الهواء.',
  urgent_on_air: 'يوجد عاجل على الهواء.',
  playback_target_changed: 'تغيّر القالب أو طبقته بعد حجز الموعد.',
  playback_start_failed: 'تعذّر بدء العرض. راجع حالة الطبقة قبل حجز موعد جديد.',
  not_authorized: 'لم تعد صلاحية المشغّل تسمح بعرض الموجز.',
}

export function BulletinSchedule({ bulletin, onClose }: { bulletin: Schemas['BulletinEditor']; onClose: () => void }) {
  const [page, setPage] = useState(0)
  const [time, setTime] = useState(() => localDateInput(new Date(Date.now() + 15 * 60_000)))
  const [inputError, setInputError] = useState('')
  const [feedback, setFeedback] = useState('')
  const client = useQueryClient()
  const key = ['bulletin-schedule', bulletin.id] as const
  const query = useQuery({
    queryKey: [...key, page], retry: false, refetchInterval: 10_000,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/bulletins/schedule', { params: { query: { id: bulletin.id, page } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const command = useMutation({
    mutationFn: async (change: { action: 'add' | 'cancel'; scheduledAtMs?: number; scheduleId?: string }) => {
      const { data, error, response } = await api.POST('/api/content/bulletins/schedule', {
        body: { id: bulletin.id, revision: bulletin.revision, page, scheduledAtMs: null, scheduleId: null, ...change },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (result, change) => {
      client.setQueryData([...key, result.page], result)
      setPage(result.page)
      setFeedback(change.action === 'add' ? 'حُفظ موعد الموجز.' : 'أُلغي الموعد.')
      void client.invalidateQueries({ queryKey: key })
    },
  })
  const schedule = query.data
  const stale = command.error?.message === 'bulletin_stale'
  return (
    <Modal opened title="جدولة الموجز" onClose={() => { if (!command.isPending) onClose() }} closeButtonProps={{ 'aria-label': 'إغلاق الجدولة' }}>
      <Stack gap="md">
        <Text fw={600} dir="auto">{bulletin.name}</Text>
        {query.isPending && <Skeleton h={100} aria-label="جارٍ تحميل المواعيد" />}
        {schedule?.canSchedule ? <form onSubmit={(event) => {
          event.preventDefault()
          if (command.isPending || stale) return
          const date = new Date(time)
          if (!Number.isFinite(date.getTime()) || localDateInput(date) !== time || date.getTime() <= Date.now()) {
            setInputError(messageFor('bulletin_schedule_invalid'))
            return
          }
          setInputError('')
          setFeedback('')
          command.mutate({ action: 'add', scheduledAtMs: date.getTime() })
        }}>
          <Stack gap="sm">
            <Text size="sm">يستخدم الموعد أحدث نسخة محفوظة. ينتظر الموجز إذا كان عاجل أو موجز آخر على الهواء.</Text>
            <TextInput type="datetime-local" label="موعد العرض بتوقيت جهازك" required dir="ltr" value={time}
              onChange={(event) => { setTime(event.currentTarget.value); setInputError('') }} />
            <Group justify="flex-end">
              <Button type="submit" loading={command.isPending && command.variables?.action === 'add'} disabled={command.isPending || stale}>حفظ الموعد</Button>
            </Group>
          </Stack>
        </form> : schedule && <Text size="sm" c="dimmed">{messageFor('bulletin_schedule_unavailable')}</Text>}
        {feedback && <Text size="sm" role="status">{feedback}</Text>}
        {(inputError || command.error || query.error) && <Alert color="orange" role="alert">
          {stale ? 'تغيّرت نسخة الموجز. أغلق الجدولة وحدّث الموجز.' : inputError || messageFor(command.error?.message ?? query.error?.message ?? 'unknown')}
        </Alert>}
        {schedule && !schedule.items.length && <Text size="sm" c="dimmed">لا توجد مواعيد لهذا الموجز.</Text>}
        {schedule?.items.map((entry) => {
          const state = scheduleStates[entry.status] ?? { label: entry.status, color: 'gray' }
          return <Paper key={entry.id} p="sm" withBorder radius="md">
            <Group justify="space-between" gap="xs">
              <div>
                <Group gap="xs">
                  <Text size="sm" fw={600}>{formatDateTime(entry.scheduledAtMs)}</Text>
                  <Badge color={state.color} variant="light">{state.label}</Badge>
                </Group>
                {(entry.status === 'queued' || entry.status === 'failed') && waitingReasons[entry.reason] &&
                  <Text size="xs" c="dimmed">{waitingReasons[entry.reason]}</Text>}
              </div>
              {entry.canCancel && <Button size="compact-sm" variant="subtle" color="red" disabled={command.isPending}
                onClick={() => modals.openConfirmModal({
                  title: 'إلغاء موعد الموجز',
                  children: <Text size="sm">{formatDateTime(entry.scheduledAtMs)}</Text>,
                  labels: { confirm: 'إلغاء الموعد', cancel: 'العودة' }, confirmProps: { color: 'red' },
                  onConfirm: () => {
                    setInputError('')
                    setFeedback('')
                    command.mutate({ action: 'cancel', scheduleId: entry.id })
                  },
                })}>إلغاء الموعد</Button>}
            </Group>
          </Paper>
        })}
        {schedule && schedule.pageCount > 1 && <Pagination total={schedule.pageCount} value={schedule.page + 1}
          disabled={command.isPending} onChange={(next) => setPage(next - 1)} />}
      </Stack>
    </Modal>
  )
}
