import { Alert, Badge, Button, Group, Paper, Stack, Text, Title } from '@mantine/core'
import { modals } from '@mantine/modals'
import { IconPlayerStop } from '@tabler/icons-react'
import { useState, type ReactNode } from 'react'
import { Link } from 'react-router'
import type { Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { CapturePanel } from '../live/CapturePanel'
import { usePlaybackCommand } from './bulletinPlaybackApi'
import classes from './NewsroomPage.module.css'

type Playback = Schemas['BulletinPlayback']
const number = new Intl.NumberFormat('ar')

export function BulletinRunStatus({ id, playback, supported, statusError, children }: {
  id: string
  playback: Playback | undefined
  supported: boolean
  statusError?: string
  children: ReactNode
}) {
  const command = usePlaybackCommand(id)
  const run = playback?.run
  const retry = run?.state === 'stop_unconfirmed'
  const sceneUnconfirmed = run?.state === 'scene_unconfirmed'
  const blocked = run?.state === 'fields_blocked'
  const playing = run?.state === 'playing' && !statusError
  const status = statusError ? 'حالة العرض غير مؤكّدة' : sceneUnconfirmed ? 'المشهد غير مؤكّد' :
    blocked ? 'تبديل الصفوف متوقف' : retry ? 'الخروج غير مؤكّد' :
      playing ? 'على الهواء' : playback?.busy ? 'موجز آخر قيد التشغيل' :
        !supported ? 'العرض غير متاح لهذا التصميم' : playback ? 'لا يوجد عرض نشط' : 'جارٍ قراءة حالة العرض…'

  return (
    <Paper component="section" aria-labelledby="bulletin-playback-heading" withBorder radius="md" p="md">
      <Stack gap="sm">
        <Group justify="space-between" gap="xs">
          <Title id="bulletin-playback-heading" order={4}>تشغيل الموجز</Title>
          <Badge variant="light" color={playing ? 'red' : run || statusError ? 'orange' : 'gray'} role="status">{status}</Badge>
        </Group>
        <div className={classes.airBanner}>
          <div className={classes.airLayout}>
            <Stack gap={6} className={classes.airCopy} aria-live="polite">
              {run && <Text size="xs" c="dimmed" fw={600}>
                {playing ? 'الخبر الحالي' : 'صف التشغيل'} · {number.format(run.row)} من {number.format(run.rowCount)}
              </Text>}
              {run?.current && <Text className={classes.airHeadline} dir="auto">{run.current}</Text>}
              {run?.next && <div className={classes.airNext}>
                <Text size="xs" fw={600} c="dimmed">الخبر التالي في الخطة</Text>
                <Text size="sm" dir="auto">{run.next}</Text>
              </div>}
              {blocked && <Text size="sm" c="dimmed">توقّف تبديل الصفوف لحماية حقول رسم آخر على الهواء.</Text>}
              {children}
            </Stack>
            <Stack gap="sm" className={classes.airActions}>
              {run && <Group gap="xs">
                {sceneUnconfirmed ? <Button component={Link} to="/air" size="sm" variant="default">افتح لوحة الهواء</Button>
                  : <Button size="sm" color="red" variant="light" loading={command.isPending}
                    leftSection={<IconPlayerStop size={17} aria-hidden />}
                    onClick={() => modals.openConfirmModal({
                      title: 'إيقاف عرض الموجز',
                      children: <Text size="sm">سيُرسل طلب الخروج للموجز الجاري، ليُكمل المشهد حركة الخروج.</Text>,
                      labels: { confirm: 'إيقاف العرض', cancel: 'العودة' },
                      confirmProps: { color: 'red' },
                      onConfirm: () => command.mutate({ action: 'stop', runId: run.id }),
                    })}>
                    {retry ? 'إعادة طلب الإيقاف' : 'إيقاف العرض'}
                  </Button>}
              </Group>}
              <CapturePanel photoOnly />
            </Stack>
          </div>
        </div>
        {statusError && <Alert color="orange" role="alert">{messageFor(statusError)}</Alert>}
        {command.error && <Alert role="alert" color="orange">{messageFor(command.error.message)}</Alert>}
      </Stack>
    </Paper>
  )
}

export function BulletinStartReview({ id, revision, stamp, playback, onStarted }: {
  id: string
  revision: number
  stamp: string
  playback: Playback | undefined
  onStarted: () => void
}) {
  const [review, setReview] = useState<Playback>()
  const command = usePlaybackCommand(id)
  const request = { revision, stamp }
  const reviewToken = review?.review
  if (!playback?.canStart && !command.error) return null

  return (
    <Paper withBorder radius="md" p="md">
      <Stack gap="xs">
        {reviewToken && review?.layer != null && <Alert color={review.replacing ? 'orange' : 'blue'}>
          {review.replacing
            ? `سيحل الموجز محل الرسم الحالي على الطبقة ${number.format(review.layer)}.`
            : `الطبقة ${number.format(review.layer)} خالية وجاهزة لعرض الموجز.`}
          {review.pausesTicker && <Text size="sm" mt="xs">سيتوقف شريط الأخبار مؤقتًا أثناء العرض.</Text>}
        </Alert>}
        {command.error && <Alert role="alert" color="orange">{messageFor(command.error.message)}</Alert>}
        <Group justify="flex-end" gap="xs">
          {reviewToken && <Button variant="default" disabled={command.isPending} onClick={() => setReview(undefined)}>العودة للمراجعة</Button>}
          {reviewToken
            ? <Button color="red" loading={command.isPending} disabled={playback?.busy || !playback?.canStart}
              onClick={() => command.mutate({ action: 'start', ...request, review: reviewToken }, {
                onSuccess: onStarted,
                onError: () => setReview(undefined),
              })}>بدء العرض على الهواء</Button>
            : <Button variant="light" loading={command.isPending} disabled={playback?.busy || !playback?.canStart || command.error?.message === 'bulletin_stale'}
              onClick={() => command.mutate({ action: 'review', ...request }, { onSuccess: setReview })}>مراجعة بدء العرض</Button>}
        </Group>
      </Stack>
    </Paper>
  )
}
