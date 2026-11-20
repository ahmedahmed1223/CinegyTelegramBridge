import { Button, Group } from '@mantine/core'
import { IconMinus, IconPlus } from '@tabler/icons-react'

export function UrgentTimingStepper({ label, value, minimum, maximum, disabled, onChange }: {
  label: string
  value: number
  minimum: number
  maximum: number
  disabled: boolean
  onChange: (value: number) => void
}) {
  return (
    <Group gap="xs" aria-label={label}>
      {(maximum > 300 ? [1, 60, 300] : [1, 10]).map((step) => (
        <Group key={step} gap={4} wrap="nowrap">
          <Button variant="default" size="compact-sm" leftSection={<IconMinus size={13} aria-hidden />}
            aria-label={`إنقاص ${label} بمقدار ${step}`} disabled={disabled || value <= minimum}
            onClick={() => onChange(Math.max(minimum, value - step))}>{step}</Button>
          <Button variant="default" size="compact-sm" leftSection={<IconPlus size={13} aria-hidden />}
            aria-label={`زيادة ${label} بمقدار ${step}`} disabled={disabled || value >= maximum}
            onClick={() => onChange(Math.min(maximum, value + step))}>{step}</Button>
        </Group>
      ))}
    </Group>
  )
}
