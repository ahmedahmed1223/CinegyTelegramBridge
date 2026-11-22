import { Avatar, Badge, Group, Menu, Text, UnstyledButton, useComputedColorScheme, useMantineColorScheme } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import { IconKey, IconLogout, IconMoon, IconSun } from '@tabler/icons-react'
import { useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useNavigate } from 'react-router'
import { api, setCsrfToken, type CurrentUser } from '../api/client'
import { roleLabel, sessionKey } from '../api/session'
import { ChangePasswordModal } from '../components/ChangePasswordModal'

export function UserMenu({ user }: { user: CurrentUser }) {
  const { setColorScheme } = useMantineColorScheme()
  const colorScheme = useComputedColorScheme('light')
  const [passwordOpen, password] = useDisclosure()
  const [signingOut, setSigningOut] = useState(false)
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const dark = colorScheme === 'dark'

  async function signOut() {
    if (signingOut) return
    setSigningOut(true)
    try {
      const { response } = await api.POST('/api/auth/logout')
      if (!response.ok && response.status !== 401) throw new Error('logout_failed')
      queryClient.clear()
      setCsrfToken('')
      await queryClient.invalidateQueries({ queryKey: sessionKey })
      navigate('/login', { replace: true })
    } catch {
      notifications.show({ color: 'red', message: 'تعذّر تسجيل الخروج. تحقّق من الاتصال وحاول مجددًا من قائمة حسابي.' })
    } finally {
      setSigningOut(false)
    }
  }

  return (
    <>
      <Menu position="bottom-end" width={240} shadow="md">
        <Menu.Target>
          <UnstyledButton aria-label="حسابي">
            <Group gap="xs" wrap="nowrap">
              <Avatar radius="xl" size={34} color="signal" name={user.name} />
              <div style={{ lineHeight: 1.15 }}>
                <Text size="sm" fw={600} visibleFrom="xs">
                  {user.name}
                </Text>
                <Text size="xs" c="dimmed" visibleFrom="xs">
                  {roleLabel[user.role] ?? user.role}
                </Text>
              </div>
            </Group>
          </UnstyledButton>
        </Menu.Target>
        <Menu.Dropdown>
          <Menu.Label>
            <Group justify="space-between">
              <span>دخلت {user.method === 'telegram' ? 'عبر Telegram' : 'بكلمة مرور'}</span>
              {user.webOnly && (
                <Badge size="xs" variant="light">
                  ويب فقط
                </Badge>
              )}
            </Group>
          </Menu.Label>
          <Menu.Item leftSection={<IconKey size={16} />} onClick={password.open}>
            تغيير كلمة المرور
          </Menu.Item>
          <Menu.Item leftSection={dark ? <IconSun size={16} /> : <IconMoon size={16} />} onClick={() => setColorScheme(dark ? 'light' : 'dark')}>
            {dark ? 'المظهر الفاتح' : 'المظهر الكحلي'}
          </Menu.Item>
          <Menu.Divider />
          <Menu.Item color="red" leftSection={<IconLogout size={16} />} disabled={signingOut} onClick={signOut}>
            {signingOut ? 'جارٍ تسجيل الخروج…' : 'تسجيل الخروج'}
          </Menu.Item>
        </Menu.Dropdown>
      </Menu>
      <ChangePasswordModal opened={passwordOpen} onClose={password.close} />
    </>
  )
}
