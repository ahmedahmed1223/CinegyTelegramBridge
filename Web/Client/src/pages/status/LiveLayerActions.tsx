import { ActionIcon, Group, Tooltip } from '@mantine/core'
import { IconClock, IconEdit, IconEyeOff, IconLogout } from '@tabler/icons-react'
import { useState } from 'react'
import { LayerRemovalModal, type RemovalOperation } from './LayerRemovalModal'
import { LayerTextModal } from './LayerTextModal'
import { LayerTimerModal } from './LayerTimerModal'

export function LiveLayerActions({ layer, templateKey, urgent = false, canEdit = true }: {
  layer: number
  templateKey: string
  urgent?: boolean
  canEdit?: boolean
}) {
  const [action, setAction] = useState<'text' | 'timer' | RemovalOperation | null>(null)
  const close = () => setAction(null)
  return <>
    <Group gap={4} role="group" aria-label="التحكم بالطبقة">
      <Tooltip label={canEdit ? 'تحديث النص على الهواء' : 'النص تتولى عرضه دورة العواجل'}>
        <ActionIcon size={44} variant="light" color="blue" aria-label="تحديث النص على الهواء"
          disabled={!canEdit} onClick={() => setAction('text')}>
          <IconEdit size={18} />
        </ActionIcon>
      </Tooltip>
      <Tooltip label="مؤقّت إخفاء العرض">
        <ActionIcon size={44} variant="light" color="gray" aria-label="مؤقّت إخفاء العرض"
          disabled={!canEdit} onClick={() => setAction('timer')}><IconClock size={18} /></ActionIcon>
      </Tooltip>
      {(['hide', 'exit'] as const).map(operation => {
        const label = operation === 'hide' ? (urgent ? 'إخفاء العاجل المعروض' : 'إخفاء القالب المعروض') : 'خروج المعروض (EXIT)'
        return <Tooltip key={operation} label={label}>
          <ActionIcon size={44} aria-label={label} variant="light" color={operation === 'hide' ? 'red' : 'orange'}
            onClick={() => setAction(operation)}>
            {operation === 'hide' ? <IconEyeOff size={18} /> : <IconLogout size={18} />}
          </ActionIcon>
        </Tooltip>
      })}
    </Group>
    {action === 'text' && <LayerTextModal layer={layer} expectedTemplateKey={templateKey} onClose={close} />}
    {action === 'timer' && <LayerTimerModal layer={layer} expectedTemplateKey={templateKey} onClose={close} />}
    {(action === 'hide' || action === 'exit') && <LayerRemovalModal
      layer={layer} operation={action} expectedTemplateKey={templateKey} onClose={close} />}
  </>
}
