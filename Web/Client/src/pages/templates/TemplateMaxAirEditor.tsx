import { Alert, Button, Group, Modal, NumberInput, Skeleton, Stack, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey } from '../../api/session'

type Current = Schemas['TemplateMaxAirView']
type Preview = Schemas['TemplateMaxAirPreview']
const number = new Intl.NumberFormat('ar')

function secondsLabel(seconds: number) {
  return seconds > 0 ? `${number.format(seconds)} ثانية` : 'بلا حدّ خاص'
}

function maxAirError(code: string) {
  switch (code) {
    case 'template_air_limit_invalid': return 'أدخل مدة صحيحة من ثانية واحدة إلى ٣٦٠٠ ثانية.'
    case 'template_air_limit_stale': return 'تغيّر القالب أو الحدّ، أو انتهت المراجعة. أعد تحميل القيمة الحالية.'
    case 'template_air_limit_unchanged': return 'هذا هو الحدّ الحالي.'
    case 'template_air_limit_save_failed': return 'تعذّر حفظ حدّ العرض. بقي الحدّ السابق قائمًا.'
    default: return messageFor(code)
  }
}

export function TemplateMaxAirEditor({ templateKey, onClose }: { templateKey: string; onClose: () => void }) {
  const current = useQuery({
    queryKey: ['template-max-air', templateKey],
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/air/templates/{key}/max-air', {
        params: { path: { key: templateKey } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    retry: false,
    refetchOnWindowFocus: false,
    gcTime: 0,
  })
  if (current.data) {
    return <MaxAirForm key={current.data.revision} current={current.data} onClose={onClose} reload={() => void current.refetch()} />
  }
  return (
    <Modal opened title="أقصى مدة على الهواء" onClose={onClose} dir="rtl">
      {current.error
        ? <Alert color="red">{maxAirError(current.error.message)}</Alert>
        : <Skeleton height={100} />}
    </Modal>
  )
}

function MaxAirForm({ current, onClose, reload }: { current: Current; onClose: () => void; reload: () => void }) {
  const cache = useQueryClient()
  const [seconds, setSeconds] = useState<number | string>(current.seconds || '')
  const [preview, setPreview] = useState<Preview | null>(null)
  const [failure, setFailure] = useState('')

  function fail(error: Error) {
    setFailure(error.message)
    setPreview(null)
    if (['forbidden', 'unauthorized'].includes(error.message)) void cache.invalidateQueries({ queryKey: sessionKey })
  }

  const checking = useMutation({
    mutationFn: async (mode: 'set' | 'remove') => {
      const { data, error, response } = await api.POST('/api/air/templates/{key}/max-air/review', {
        params: { path: { key: current.key } },
        body: { revision: current.revision, mode, ...(mode === 'set' ? { seconds: Number(seconds) } : {}) },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: setPreview,
    onError: fail,
  })
  const saving = useMutation({
    mutationFn: async (decision: Preview) => {
      const { data, error, response } = await api.POST('/api/air/templates/{key}/max-air/confirm', {
        params: { path: { key: decision.current.key } },
        body: { review: decision.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: async () => {
      notifications.show({ color: 'teal', message: 'حُفظ حدّ مدة العرض.' })
      onClose()
      await cache.invalidateQueries({ queryKey: ['template-max-air', current.key] })
    },
    onError: fail,
  })
  const busy = checking.isPending || saving.isPending
  const valid = typeof seconds === 'number' && Number.isInteger(seconds) && seconds >= 1 && seconds <= 3600
  function review(mode: 'set' | 'remove') {
    setFailure('')
    checking.mutate(mode)
  }

  return (
    <Modal opened title="أقصى مدة على الهواء" onClose={() => { if (!busy) onClose() }}
      closeOnClickOutside={!busy} closeOnEscape={!busy} withCloseButton={!busy} dir="rtl">
      <Stack gap="md">
        <Text fw={600} style={{ overflowWrap: 'anywhere' }}><bdi>{current.key}</bdi></Text>
        {failure && (
          <Alert color="orange" role="alert">
            <Stack gap="xs">
              {maxAirError(failure)}
              {failure === 'template_air_limit_stale' && <Button variant="default" size="xs" onClick={reload}>تحميل الحدّ الحالي</Button>}
            </Stack>
          </Alert>
        )}
        {preview ? (
          <>
            <Text>الحدّ الحالي: {secondsLabel(preview.current.seconds)}</Text>
            <Text fw={600}>الحدّ بعد الحفظ: {secondsLabel(preview.seconds)}</Text>
            <Text size="sm" c="dimmed">يُستخدم الحدّ عند بدء عرض جديد. يبقى مؤقّت العرض الجاري كما هو.</Text>
            <Group justify="end">
              <Button variant="default" disabled={busy} onClick={() => setPreview(null)}>رجوع</Button>
              <Button loading={saving.isPending} onClick={() => saving.mutate(preview)}>
                {preview.seconds === 0 ? 'تأكيد إزالة الحدّ' : 'تأكيد حفظ الحدّ'}
              </Button>
            </Group>
          </>
        ) : (
          <>
            <Text size="sm">الحدّ الحالي: {secondsLabel(current.seconds)}</Text>
            <NumberInput label="الحدّ بالثواني" min={1} max={3600} allowDecimal={false} allowNegative={false}
              value={seconds} onChange={(value) => setSeconds(typeof value === 'bigint' ? Number(value) : value)} disabled={busy} />
            <Group justify="end">
              {current.seconds > 0 && <Button variant="light" color="red" disabled={busy} onClick={() => review('remove')}>مراجعة إزالة الحدّ</Button>}
              <Button loading={checking.isPending} disabled={!valid || seconds === current.seconds} onClick={() => review('set')}>مراجعة تعديل الحدّ</Button>
            </Group>
          </>
        )}
      </Stack>
    </Modal>
  )
}
