import { ActionIcon, Badge, Group, Paper, Stack, Text, Tooltip } from '@mantine/core'
import { IconEyeOff, IconLogout } from '@tabler/icons-react'
import { useState } from 'react'
import type { Schemas } from '../../api/client'
import { useNow } from '../../hooks/useNow'
import { useLiveStatus } from '../../layout/LiveStatusContext'
import { isFresh } from '../../lib/time'
import { LayerRemovalModal, type RemovalOperation } from '../status/LayerRemovalModal'
import { useUrgentManual } from './urgentManualApi'
import { useTemplateText } from '../templates/useTemplateText'
import classes from './NewsroomPage.module.css'

export function UrgentAirBanner({ items }: { items: Schemas['ContentItem'][] }) {
  const live = useLiveStatus()
  const manual = useUrgentManual()
  const now = useNow()
  const [review, setReview] = useState<{ layer: number; operation: RemovalOperation; expectedTemplateKey: string } | null>(null)
  const tracked = live.status?.layers.find(item => item.key.toLowerCase() === 'urgent')
  const shared = useTemplateText(tracked?.key ?? 'Urgent')
  const values = shared.isSuccess ? Object.entries(shared.data).filter(([, value]) => value.trim()) : []
  const control = manual.data?.live
  const layer = tracked?.layer ?? control?.layer
  const individual = control && control.layer === layer
  const row = individual ? items.find(item => item.id === control.itemId) : undefined
  const fresh = tracked && live.bridgeOnline && isFresh(live.status?.cinegy.freshUntil ?? 0, now)
  return <>
    {(layer != null || values.length > 0) && <Paper component="section" aria-label="العاجل المعروض" className={classes.airBanner} p="sm" withBorder>
      <Group justify="space-between">
        <Stack gap={2} aria-live="polite">
          <Group gap="xs">
            <Badge color={fresh ? 'red' : 'yellow'}>{fresh ? 'عاجل على الهواء' : 'آخر حالة للعاجل'}</Badge>
            {layer != null && <Text fw={600} size="sm">{individual ? 'عرض يدوي' : 'قالب العاجل'} · الطبقة {layer}</Text>}
          </Group>
          {values.length > 0 ? <>
            <Text size="xs" c="dimmed">آخر نص عُرض بقالب العاجل</Text>
            {values.map(([field, value]) => <Text size="sm" key={field} dir="auto">{value}</Text>)}
          </> : row?.title && <Text size="sm" lineClamp={2} dir="auto">نص الصف في الجدول · {row.title}</Text>}
        </Stack>
        {layer != null && <Group gap={4}>
          {(['hide', 'exit'] as const).map(operation => {
            const label = operation === 'hide' ? 'إخفاء العاجل المعروض' : 'خروج المعروض (EXIT)'
            return <Tooltip key={operation} label={label}><ActionIcon size={44} aria-label={label}
              color={operation === 'hide' ? 'red' : 'orange'} variant="light"
              onClick={() => setReview({ layer, operation, expectedTemplateKey: tracked?.key ?? 'Urgent' })}>
              {operation === 'hide' ? <IconEyeOff size={18} /> : <IconLogout size={18} />}
            </ActionIcon></Tooltip>
          })}
        </Group>}
      </Group>
    </Paper>}
    {review && <LayerRemovalModal {...review} onClose={() => setReview(null)} />}
  </>
}
