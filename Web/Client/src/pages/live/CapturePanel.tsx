import { Alert, Button, Group, Paper, Stack, Text, Title } from '@mantine/core'
import { useMutation, useMutationState, useQuery } from '@tanstack/react-query'
import { IconCamera, IconDownload, IconVideo } from '@tabler/icons-react'
import { useEffect, useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useSession } from '../../api/session'
import { formatDateTime } from '../../lib/time'
import classes from './LivePage.module.css'

type Capture = Schemas['OutputCapture']

export function CapturePanel({ hidden }: { hidden: boolean }) {
  const user = useSession().data
  const mutationKey = ['start-live-capture', user?.id]
  const capture = useMutationState({
    filters: { mutationKey, exact: true, status: 'success' },
    select: (mutation) => mutation.state.data as Capture,
  }).at(-1)
  const [expiredId, setExpiredId] = useState<string>()
  const [previewErrorId, setPreviewErrorId] = useState<string>()
  const request = useMutation({
    mutationKey,
    gcTime: 6 * 60_000,
    mutationFn: async (kind: 'photo' | 'clip') => {
      const { data, error, response } = await api.POST('/api/live/captures', { body: { kind } })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const status = useQuery<Capture>({
    queryKey: ['live-capture', capture?.id],
    enabled: !!user && capture?.state === 'pending',
    retry: 2,
    refetchInterval: ({ state }) => !state.error && (!state.data || state.data.state === 'pending') ? 1000 : false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/live/captures/{id}', { signal, params: { path: { id: capture!.id } } })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const current = status.data ?? capture
  const pending = current?.state === 'pending' && !status.error
  const expired = !!current && current.id === expiredId
  const photo = current?.kind === 'photo'

  useEffect(() => {
    if (!current?.expiresAt) return
    const timer = window.setTimeout(() => setExpiredId(current.id), Math.max(0, current.expiresAt - Date.now()))
    return () => window.clearTimeout(timer)
  }, [current?.id, current?.expiresAt])

  const file = current?.state === 'ready' && !expired ? '/api/live/captures/' + encodeURIComponent(current.id) + '/file' : undefined
  const error = request.error ?? status.error
  return (
    <div hidden={hidden}>
      <Paper radius="lg" className={classes.capturePanel}>
        <Stack gap="sm">
          <Group justify="space-between" align="center" gap="xs">
            <Title order={3} size="h4">التقاط من الخرج</Title>
            <Group gap="xs">
              <Button variant="default" size="sm" leftSection={<IconCamera size={18} aria-hidden />} disabled={pending || request.isPending}
                onClick={() => request.mutate('photo')}>التقاط صورة</Button>
              <Button variant="light" size="sm" leftSection={<IconVideo size={18} aria-hidden />} disabled={pending || request.isPending}
                onClick={() => request.mutate('clip')}>تسجيل مقطع</Button>
            </Group>
          </Group>
          {(pending || request.isPending || error || current?.state === 'failed' || expired) && <div aria-live="polite">
            {(pending || request.isPending) && <Text size="sm" c="dimmed">جارٍ {((request.isPending ? request.variables : current?.kind) === 'photo') ? 'التقاط الصورة' : 'تسجيل المقطع'}…</Text>}
            {error && <Alert color="yellow">
              <Group justify="space-between" gap="xs">
                <Text size="sm">{error.message}</Text>
                {status.error && <Button size="xs" variant="subtle" onClick={() => void status.refetch()}>تحديث حالة الالتقاط</Button>}
              </Group>
            </Alert>}
            {!error && !expired && current?.state === 'failed' && <Alert color="yellow">تعذّر الالتقاط من المصدر. أعد المحاولة.</Alert>}
            {expired && <Text size="sm" c="dimmed">انتهت مهلة تنزيل الملف. يمكنك طلب التقاط جديد.</Text>}
          </div>}
          {file && current && (
            <Stack gap="xs">
              {previewErrorId === current.id
                ? <Text size="sm" c="dimmed">تعذّرت المعاينة. يمكنك تنزيل الملف.</Text>
                : photo
                  ? <img className={classes.capturePreview} src={file} alt="صورة ملتقطة من خرج القناة" onError={() => setPreviewErrorId(current.id)} />
                  : <video key={file} className={classes.capturePreview} src={file} controls playsInline preload="metadata"
                      aria-label="المقطع المسجل من خرج القناة" onError={() => setPreviewErrorId(current.id)} />}
              <Group justify="space-between" gap="xs">
                <Text size="sm" c="dimmed">{current.source === 'backup' ? 'المصدر الاحتياطي' : 'المصدر الرئيسي'} · {formatDateTime(current.completedAt)}</Text>
                <Button component="a" href={file} download={photo ? 'output.jpg' : 'output.mp4'} variant="default" size="sm"
                  leftSection={<IconDownload size={16} aria-hidden />}>{photo ? 'تنزيل الصورة' : 'تنزيل المقطع'}</Button>
              </Group>
            </Stack>
          )}
        </Stack>
      </Paper>
    </div>
  )
}
