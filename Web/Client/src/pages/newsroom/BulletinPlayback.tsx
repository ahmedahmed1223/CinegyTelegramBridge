import { Alert, Button, Group, Paper, Stack, Text } from '@mantine/core'
import { modals } from '@mantine/modals'
import { useState } from 'react'
import { Link } from 'react-router'
import type { Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { usePlaybackCommand } from './bulletinPlaybackApi'

type Playback = Schemas['BulletinPlayback']
const number = new Intl.NumberFormat('ar')

export function BulletinRunStatus({ id, playback }: { id: string; playback: Playback | undefined }) {
  const command = usePlaybackCommand(id)
  const run = playback?.run
  const retry = run?.state === 'stop_unconfirmed'
  const sceneUnconfirmed = run?.state === 'scene_unconfirmed'
  if (!run && !playback?.busy && !command.error) return null

  return (
    <Paper withBorder radius="md" p="sm">
      <Stack gap="xs">
        {run && <Group justify="space-between" gap="xs">
          <Text size="sm" role="status">
            {sceneUnconfirmed ? 'تعذّر تأكيد المشهد بعد بدء العرض. راجع الطبقة من لوحة الهواء.' :
              retry ? 'خروج الموجز غير مؤكّد' : `يعرض الصف ${number.format(run.row)} من ${number.format(run.rowCount)}`}
          </Text>
          {sceneUnconfirmed ? <Button component={Link} to="/air" size="compact-sm" variant="default">افتح لوحة الهواء</Button>
            : <Button size="compact-sm" color="red" variant="light" loading={command.isPending}
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
        {!run && playback?.busy && <Text size="sm" c="dimmed">يوجد موجز آخر قيد التشغيل.</Text>}
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
