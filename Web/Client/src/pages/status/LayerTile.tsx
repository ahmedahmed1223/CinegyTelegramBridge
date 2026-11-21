import { ActionIcon, Badge, Button, Group, Menu, Progress, Stack, Text, Tooltip } from '@mantine/core'
import { IconClockHour4, IconDotsVertical, IconEyeOff, IconLogout, IconPencil, IconUser } from '@tabler/icons-react'
import type { LayerStatus } from '../../api/client'
import { formatClock } from '../../lib/time'
import classes from './LayerTile.module.css'
import type { RemovalOperation } from './LayerRemovalModal'

const sourceLabel: Record<string, string> = {
  cinegy: 'من خارج الجسر',
  BotTest: 'تجربة قالب',
}

/**
 * One layer, styled like a multiviewer tile with a tally strip. Counters run
 * only while the reading is fresh: a clock ticking over an unconfirmed
 * reading would claim more than the bridge knows.
 */
export function LayerTile({ layer, now, fresh, onEditText, onTimer, onRemove }: {
  layer: LayerStatus
  now: number
  fresh: boolean
  onEditText: () => void
  onTimer: () => void
  onRemove: (operation: RemovalOperation) => void
}) {
  const onAirFor = fresh && layer.at > 0 ? now - layer.at : null
  const hidesIn = fresh && layer.hideAt > now ? layer.hideAt - now : null
  const span = layer.hideAt > layer.at && layer.at > 0 ? layer.hideAt - layer.at : 0
  const elapsed = span > 0 && hidesIn !== null ? ((span - hidesIn) / span) * 100 : 0
  const origin = sourceLabel[layer.source]

  return (
    <div className={classes.tile} data-fresh={fresh}>
      <div className={classes.number} aria-label={`الطبقة ${layer.layer}`}>
        {layer.layer}
      </div>
      <Stack gap={6} className={classes.body}>
        <Group justify="space-between" wrap="nowrap" gap="xs">
          <Text fw={700} truncate="end" title={layer.key}>
            {layer.key || '—'}
          </Text>
          <Group gap={4} wrap="nowrap">
            {layer.name && (
              <Badge variant="default" radius="sm" fw={500} style={{ flex: 'none' }}>
                {layer.name}
              </Badge>
            )}
            <Menu shadow="md" width={160} position="bottom-end">
              <Menu.Target>
                <ActionIcon variant="subtle" color="gray" size="sm" aria-label="خيارات الطبقة">
                  <IconDotsVertical size={16} />
                </ActionIcon>
              </Menu.Target>
              <Menu.Dropdown>
                <Menu.Item disabled={!fresh} leftSection={<IconClockHour4 size={14} />} onClick={onTimer}>
                  مؤقّت الإخفاء
                </Menu.Item>
                <Menu.Item disabled={!fresh} leftSection={<IconPencil size={14} />} onClick={onEditText}>
                  تعديل النص المباشر
                </Menu.Item>
                <Menu.Item color="red" leftSection={<IconEyeOff size={14} />} disabled={!fresh} onClick={() => onRemove('hide')}>
                  إخفاء (HIDE)
                </Menu.Item>
                <Menu.Item color="orange" leftSection={<IconLogout size={14} />} disabled={!fresh} onClick={() => onRemove('exit')}>
                  خروج (EXIT)
                </Menu.Item>
              </Menu.Dropdown>
            </Menu>
          </Group>
        </Group>

        <Group gap="md" wrap="nowrap">
          <Text size="sm" className={classes.onAir}>
            <span className={classes.liveDot} aria-hidden />
            <span className="cgb-mono">{onAirFor !== null ? formatClock(onAirFor) : '—:—'}</span>
          </Text>
          {hidesIn !== null && (
            <Tooltip label="يختفي تلقائيًا بعد">
              <Text size="sm" c="dimmed">
                <IconClockHour4 size={14} style={{ verticalAlign: '-2px', marginInlineEnd: 4 }} />
                <span className="cgb-mono">{formatClock(hidesIn)}</span>
              </Text>
            </Tooltip>
          )}
        </Group>

        {hidesIn !== null && span > 0 && <Progress value={elapsed} size={4} color="red" radius="xl" aria-hidden />}

        <Group justify="space-between" align="center" mt={2}>
          <Group gap={6} c="dimmed">
            <IconUser size={14} />
            <Text size="xs" truncate="end">
              {origin ?? (layer.by || 'الجسر')}
            </Text>
          </Group>
          <Button size="compact-xs" color="red" variant="light" leftSection={<IconEyeOff size={12} />} disabled={!fresh} onClick={() => onRemove('hide')}>
            إخفاء
          </Button>
        </Group>
      </Stack>
    </div>
  )
}
