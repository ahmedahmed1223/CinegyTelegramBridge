import { Button, Menu } from '@mantine/core'
import { IconCopy, IconDotsVertical, IconEyeOff, IconListCheck, IconTool } from '@tabler/icons-react'
import { useState } from 'react'
import { isAdmin, useSession } from '../../api/session'
import { AirMaintenanceModal, EmergencyHideModal } from './AirEmergencyModals'
import { HideAllLayerScopeModal } from './HideAllLayerScopeModal'

export function AirOperationsMenu({ disabled, onCopyStatus }: { disabled: boolean; onCopyStatus?: () => void }) {
  const session = useSession().data
  const [open, setOpen] = useState<'maintenance' | 'emergency' | 'hide-all-scope' | null>(null)
  if (!session) return null

  return (
    <>
      <Menu position="bottom-end" width={210} shadow="md">
        <Menu.Target>
          <Button variant="default" disabled={disabled} leftSection={<IconDotsVertical size={16} />}>
            إجراءات الهواء
          </Button>
        </Menu.Target>
        <Menu.Dropdown>
          {onCopyStatus && <Menu.Item leftSection={<IconCopy size={16} />} onClick={onCopyStatus}>
            نسخ ملخّص حالة الهواء
          </Menu.Item>}
          {isAdmin(session) && (
            <Menu.Item leftSection={<IconTool size={16} />} onClick={() => setOpen('maintenance')}>
              صيانة البث
            </Menu.Item>
          )}
          <Menu.Item leftSection={<IconListCheck size={16} />} onClick={() => setOpen('hide-all-scope')}>
            نطاق إخفاء الكل
          </Menu.Item>
          <Menu.Item color="red" leftSection={<IconEyeOff size={16} />} onClick={() => setOpen('emergency')}>
            إخفاء الطوارئ
          </Menu.Item>
        </Menu.Dropdown>
      </Menu>
      {open === 'maintenance' && <AirMaintenanceModal onClose={() => setOpen(null)} />}
      {open === 'emergency' && <EmergencyHideModal onClose={() => setOpen(null)} />}
      {open === 'hide-all-scope' && <HideAllLayerScopeModal onClose={() => setOpen(null)} />}
    </>
  )
}
