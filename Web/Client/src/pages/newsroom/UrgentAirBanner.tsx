import { ActionIcon, Badge, Group, Stack, Text, Tooltip } from '@mantine/core'
import { IconEyeOff, IconLogout } from '@tabler/icons-react'
import { useState } from 'react'
import type { Schemas } from '../../api/client'
import { useNow } from '../../hooks/useNow'
import { useLiveStatus } from '../../layout/LiveStatusContext'
import { isFresh } from '../../lib/time'
import { CapturePanel } from '../live/CapturePanel'
import { LayerRemovalModal, type RemovalOperation } from '../status/LayerRemovalModal'
import { useUrgentManual } from './urgentManualApi'
import { useTemplateText } from '../templates/useTemplateText'
import classes from './NewsroomPage.module.css'

export function UrgentAirBanner({ items, run }: { items: Schemas['ContentItem'][]; run?: Schemas['UrgentRunStatus'] | null }) {
  const live = useLiveStatus()
  const manual = useUrgentManual()
  const now = useNow()
  const [review, setReview] = useState<{ layer: number; operation: RemovalOperation; expectedTemplateKey: string } | null>(null)
  const tracked = live.status?.layers.find(item => item.key.toLowerCase() === 'urgent')
  const shared = useTemplateText(tracked?.key ?? 'Urgent')
  const values = !run && shared.isSuccess ? Object.entries(shared.data).filter(([, value]) => value.trim()) : []
  const control = manual.data?.live
  const layer = tracked?.layer ?? control?.layer
  const individual = control && control.layer === layer
  const row = individual ? items.find(item => item.id === control.itemId) : undefined
  const fresh = tracked && live.bridgeOnline && isFresh(live.status?.cinegy?.freshUntil ?? 0, now)
  const headline = run?.current || (individual ? row?.title : undefined) || values[0]?.[1]
  const context = run ? 'دورة العواجل' : individual ? 'عرض يدوي' : 'قالب العاجل'
  return <>
    <section aria-label="العاجل المعروض" className={classes.airBanner}>
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
              {run ? 'خطوة العرض الحالية' : row?.title ? 'عنوان صف العرض اليدوي' : 'آخر نص عُرض بالقالب'}
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
          {layer != null && <Group gap={4} aria-label="التحكم بالطبقة" role="group">
          {(['hide', 'exit'] as const).map(operation => {
            const label = operation === 'hide' ? 'إخفاء العاجل المعروض' : 'خروج المعروض (EXIT)'
            return <Tooltip key={operation} label={label}><ActionIcon size={44} aria-label={label}
              color={operation === 'hide' ? 'red' : 'orange'} variant="light"
              onClick={() => setReview({ layer, operation, expectedTemplateKey: tracked?.key ?? 'Urgent' })}>
              {operation === 'hide' ? <IconEyeOff size={18} /> : <IconLogout size={18} />}
            </ActionIcon></Tooltip>
          })}
          </Group>}
          <CapturePanel photoOnly />
        </Stack>
      </div>
    </section>
    {review && <LayerRemovalModal {...review} onClose={() => setReview(null)} />}
  </>
}
