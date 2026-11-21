import { Button, Menu } from '@mantine/core'
import { IconDotsVertical, IconEyeOff, IconTool } from '@tabler/icons-react'
import { useState } from 'react'
import { isAdmin, useSession } from '../../api/session'
import { AirMaintenanceModal, EmergencyHideModal } from './AirEmergencyModals'

export function AirOperationsMenu({ disabled }: { disabled: boolean }) {
  const session = useSession().data
  const [open, setOpen] = useState<'maintenance' | 'emergency' | null>(null)
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
          {isAdmin(session) && (
            <Menu.Item leftSection={<IconTool size={16} />} onClick={() => setOpen('maintenance')}>
              صيانة البث
            </Menu.Item>
          )}
          <Menu.Item color="red" leftSection={<IconEyeOff size={16} />} onClick={() => setOpen('emergency')}>
            إخفاء الطوارئ
          </Menu.Item>
        </Menu.Dropdown>
      </Menu>
      {open === 'maintenance' && <AirMaintenanceModal onClose={() => setOpen(null)} />}
      {open === 'emergency' && <EmergencyHideModal onClose={() => setOpen(null)} />}
    </>
  )
}
