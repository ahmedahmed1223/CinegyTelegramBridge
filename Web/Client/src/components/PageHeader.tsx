import { Group, Text, Title } from '@mantine/core'
import type { ReactNode } from 'react'

export function PageHeader({ title, description, actions }: { title: string; description?: string; actions?: ReactNode }) {
  return (
    <Group component="header" justify="space-between" align="flex-end" gap="sm" className="cgb-page-header">
      <div>
        <Title order={1} className="cgb-page-title">{title}</Title>
        {description && <Text size="sm" c="dimmed" mt={5}>{description}</Text>}
      </div>
      {actions}
    </Group>
  )
}
