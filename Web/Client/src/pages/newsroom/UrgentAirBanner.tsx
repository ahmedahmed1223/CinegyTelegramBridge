import { Badge, Group, Stack, Text } from '@mantine/core'
import type { Schemas } from '../../api/client'
import { useNow } from '../../hooks/useNow'
import { useLiveStatus } from '../../layout/LiveStatusContext'
import { formatClock, isFresh } from '../../lib/time'
import { CapturePanel } from '../live/CapturePanel'
import { LiveLayerActions } from '../status/LiveLayerActions'
import { useUrgentManual } from './urgentManualApi'
import { useTemplateText } from '../templates/useTemplateText'
import classes from './NewsroomPage.module.css'

export function UrgentAirBanner({ items, fields, run }: {
  items: Schemas['ContentItem'][]
  fields?: readonly { name: string }[] | null
  run?: Schemas['UrgentRunStatus'] | null
}) {
  const live = useLiveStatus()
  const manual = useUrgentManual()
  const now = useNow()
  const tracked = live.status?.layers.find(item => item.key.toLowerCase() === 'urgent')
  const shared = useTemplateText(tracked?.key ?? 'Urgent')
  const lastValues = shared.data ?? {}
  const names = fields?.length ? fields.map(field => field.name) : Object.keys(lastValues)
  const values = run ? [] : names.map(name => [name, lastValues[name] ?? '']).filter(([, value]) => value.trim())
  const control = manual.data?.live
  const layer = tracked?.layer ?? control?.layer
  const individual = control && control.layer === layer
  const row = individual ? items.find(item => item.id === control.itemId) : undefined
  const fresh = tracked && live.bridgeOnline && isFresh(live.status?.cinegy?.freshUntil ?? 0, now)
  const elapsed = fresh && tracked.at > 0 ? now - tracked.at : null
  const remaining = live.bridgeOnline && tracked && tracked.hideAt > 0
    ? Math.ceil((tracked.hideAt - now) / 1000) * 1000 : null
  const headline = run?.current || values[0]?.[1] || row?.title
  const context = run ? 'دورة العواجل' : individual ? 'عرض يدوي' : 'قالب العاجل'
  return <section aria-label="العاجل المعروض" className={classes.airBanner}>
      <div className={classes.airLayout}>
        <Stack gap={6} className={classes.airCopy} aria-live="polite">
          <Group gap="xs">
            <Badge variant="light" color={fresh ? 'red' : layer != null ? 'yellow' : 'gray'}>
              {fresh ? 'على الهواء' : layer != null ? 'العرض غير مؤكّد' : 'لا يوجد عاجل مؤكّد على الهواء'}
            </Badge>
            {layer != null && <Text size="sm" c="dimmed">{context} · الطبقة <bdi>{layer}</bdi></Text>}
          </Group>
          {headline && <>
            <Text size="xs" c="dimmed" fw={600}>
              {run ? 'خطوة العرض الحالية' : 'آخر نص عُرض بالقالب'}
            </Text>
            <Text className={classes.airHeadline} dir="auto">{headline}</Text>
            {values.filter(([, value]) => value !== headline).map(([field, value]) =>
              <Text size="sm" key={field} dir="auto">{value}</Text>)}
          </>}
          {run?.next && <div className={classes.airNext}>
            <Text size="xs" c="dimmed" fw={600}>العاجل التالي</Text>
            <Text size="sm" dir="auto">{run.next}</Text>
          </div>}
        </Stack>
        <Stack gap="sm" className={classes.airActions}>
          {elapsed != null && <Group gap="xs" role="timer" aria-label="مدة عرض العاجل" aria-live="off">
            <Text size="sm" c="dimmed">مدة العرض</Text>
            <Text size="sm" fw={600} className="cgb-mono"><bdi dir="ltr">{formatClock(elapsed)}</bdi></Text>
          </Group>}
          {remaining != null && <Group gap="xs" role="timer" aria-label="الوقت المتبقي للعاجل" aria-live="off">
            <Text size="sm" c="dimmed">الوقت المتبقي</Text>
            <Badge color="orange" variant="light" className="cgb-mono"><bdi dir="ltr">{formatClock(remaining)}</bdi></Badge>
          </Group>}
          {layer != null && <LiveLayerActions key={layer} layer={layer} templateKey={tracked?.key ?? 'Urgent'} urgent canEdit={!run} />}
          <CapturePanel photoOnly />
        </Stack>
      </div>
    </section>
}
