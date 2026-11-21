import { Alert, Badge, Button, Group, Paper, SimpleGrid, Skeleton, Stack, Text, ThemeIcon, Title } from '@mantine/core'
import { IconAlertTriangle, IconBrandTelegram, IconCpu, IconDeviceTv, IconPlugConnected, IconStack2, IconArrowBackUp } from '@tabler/icons-react'
import { useState, type ReactNode } from 'react'
import { Link } from 'react-router'
import { PageHeader } from '../../components/PageHeader'
import { useNow } from '../../hooks/useNow'
import { useLiveStatus } from '../../layout/LiveStatusContext'
import { cinegyLamp, telegramLamp } from '../../lib/lamps'
import { formatAgo, formatClock, isFresh } from '../../lib/time'
import { AirOperationsMenu } from './AirOperationsMenu'
import { LayerTile } from './LayerTile'
import { LayerTimerModal } from './LayerTimerModal'
import { LayerRemovalModal, type RemovalOperation } from './LayerRemovalModal'
import { LayerRollbackModal } from './LayerRollbackModal'
import { LayerTextModal } from './LayerTextModal'

const healthLabel: Record<string, string> = {
  healthy: 'سليم',
  unhealthy: 'غير سليم',
  unreachable: 'لا يُجيب',
}

export function StatusPage() {
  const [rollbackOpen, setRollbackOpen] = useState(false)
  const [editingLayer, setEditingLayer] = useState<number | null>(null)
  const [timedLayer, setTimedLayer] = useState<number | null>(null)
  const [removal, setRemoval] = useState<{ layer: number; operation: RemovalOperation } | null>(null)
  const live = useLiveStatus()
  const now = useNow()
  const status = live.status

  if (!status) {
    return (
      <Stack>
        <PageHeader title="لوحة الهواء" />
        {live.stream !== 'connecting' && !live.bridgeOnline ? (
          <Alert color="red" icon={<IconAlertTriangle />} title="الجسر لا يجيب">
            خادم الويب يعمل، لكنه لا يصل إلى الجسر. تأكّد أن الجسر يعمل وأن «واجهة الويب» مفعّلة من برنامج التحكم.
          </Alert>
        ) : (
          <SimpleGrid cols={{ base: 1, sm: 3 }}>
            <Skeleton h={112} radius="md" />
            <Skeleton h={112} radius="md" />
            <Skeleton h={112} radius="md" />
          </SimpleGrid>
        )}
      </Stack>
    )
  }

  const fresh = live.bridgeOnline && isFresh(status.cinegy.freshUntil, now)
  const engine = cinegyLamp(status, now)
  const telegram = telegramLamp(status)
  const layers = [...status.layers].sort((a, b) => a.layer - b.layer)

  return (
    <Stack gap="xl">
      <PageHeader title="لوحة الهواء" description="تابع الطبقات المعروضة وحالة محرك البث."
        actions={
          <Group gap="sm">
            <AirOperationsMenu disabled={!live.bridgeOnline} />
            <Button variant="default" disabled={!live.bridgeOnline} leftSection={<IconArrowBackUp size={18} />}
              onClick={() => setRollbackOpen(true)}>التراجع عن أمر</Button>
            <Button component={Link} to="/live" variant="default" leftSection={<IconDeviceTv size={18} />}>البث المباشر</Button>
          </Group>
        } />
      {rollbackOpen && <LayerRollbackModal onClose={() => setRollbackOpen(false)} />}
      {editingLayer !== null && <LayerTextModal layer={editingLayer} onClose={() => setEditingLayer(null)} />}
      {timedLayer !== null && <LayerTimerModal layer={timedLayer} onClose={() => setTimedLayer(null)} />}
      {removal && <LayerRemovalModal {...removal} onClose={() => setRemoval(null)} />}

      {!live.bridgeOnline && (
        <Alert color="red" icon={<IconPlugConnected />} title="الجسر لا يجيب">
          ما تراه آخر حالة معروفة، لا الحالة الآن. العدّادات متوقفة حتى يعود.
        </Alert>
      )}

      <SimpleGrid cols={{ base: 1, sm: 3 }} spacing="md">
        <SummaryCard
          icon={<IconCpu size={20} />}
          tone={engine.state}
          title="المحرك"
          value={healthLabel[status.cinegy.health] ?? 'غير معروف'}
          detail={
            status.cinegy.lastReadAt > 0 ? (
              <>
                آخر قراءة <span className="cgb-mono">{formatAgo(now - status.cinegy.lastReadAt)}</span>
                {!fresh && ' · غير مؤكَّدة'}
              </>
            ) : (
              'لم تُقرأ الطبقات بعد'
            )
          }
        />
        <SummaryCard
          icon={<IconBrandTelegram size={20} />}
          tone={telegram.state}
          title="Telegram"
          value={status.telegram.state === 'connected' ? 'متصل' : status.telegram.state === 'disconnected' ? 'منقطع' : 'غير معروف'}
          detail={telegram.detail}
        />
        <SummaryCard
          icon={<IconStack2 size={20} />}
          tone={live.bridgeOnline ? 'ok' : 'down'}
          title="الجسر"
          value={<span className="cgb-mono">v{status.version}</span>}
          detail={
            status.startedAt > 0 ? (
              <>
                يعمل منذ <span className="cgb-mono">{formatClock(now - status.startedAt)}</span>
              </>
            ) : (
              '—'
            )
          }
        />
      </SimpleGrid>

      <Stack gap="sm">
        <Group justify="space-between">
          <Group gap="xs">
            <Title order={2}>الطبقات على الهواء</Title>
            <Badge variant={layers.length > 0 ? 'filled' : 'default'} color="red" radius="sm" className="cgb-mono">
              {layers.length}
            </Badge>
          </Group>
          {!fresh && layers.length > 0 && (
            <Badge color="yellow" variant="light">
              قراءة غير مؤكَّدة
            </Badge>
          )}
        </Group>
        {layers.length === 0 ? (
          <Paper p="xl" radius="lg" ta="center">
            <Text fw={600}>لا شيء على الهواء</Text>
            <Text size="sm" c="dimmed" mt={4}>
              {fresh ? 'المحرك لا يعرض أي قالب من الجسر الآن.' : 'لا قراءة مؤكَّدة بعد، فلا يُجزم بأن الطبقات فارغة.'}
            </Text>
          </Paper>
        ) : (
          <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }} spacing="md">
            {layers.map((layer) => (
              <LayerTile key={layer.layer} layer={layer} now={now} fresh={fresh}
                onEditText={() => setEditingLayer(layer.layer)} onTimer={() => setTimedLayer(layer.layer)}
                onRemove={(operation) => setRemoval({ layer: layer.layer, operation })} />
            ))}
          </SimpleGrid>
        )}
      </Stack>
    </Stack>
  )
}

const toneColor = { ok: 'teal', warn: 'yellow', down: 'red', unknown: 'gray' } as const

function SummaryCard(props: { icon: ReactNode; tone: keyof typeof toneColor; title: string; value: ReactNode; detail: ReactNode }) {
  return (
    <Paper p="lg" radius="lg">
      <Group gap="sm" wrap="nowrap" align="flex-start">
        <ThemeIcon variant="light" color={toneColor[props.tone]} size={40} radius="md">
          {props.icon}
        </ThemeIcon>
        <div style={{ minWidth: 0 }}>
          <Text size="xs" c="dimmed" fw={500}>
            {props.title}
          </Text>
          <Text fw={700} size="lg" lh={1.3}>
            {props.value}
          </Text>
          <Text size="xs" c="dimmed" mt={2}>
            {props.detail}
          </Text>
        </div>
      </Group>
    </Paper>
  )
}
