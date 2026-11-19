import { Group, Text, Tooltip } from '@mantine/core'
import classes from './SignalLamp.module.css'

export type Lamp = 'ok' | 'warn' | 'down' | 'unknown'

/** A tally-style indicator: one coloured dot and a word, readable at a glance. */
export function SignalLamp({ state, label, detail }: { state: Lamp; label: string; detail: string }) {
  return (
    <Tooltip label={detail}>
      <Group gap={6} wrap="nowrap" className={classes.lamp} data-state={state} tabIndex={0} aria-label={`${label}: ${detail}`}>
        <span className={classes.dot} aria-hidden />
        <Text size="sm" fw={500}>
          {label}
        </Text>
      </Group>
    </Tooltip>
  )
}
