import { AppShell, Badge, Burger, Group, NavLink, ScrollArea, Stack, Text } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { IconBroadcast, IconDevices, IconLayoutGrid, IconUsersGroup } from '@tabler/icons-react'
import { NavLink as RouterLink, Outlet, useLocation } from 'react-router'
import { isAdmin, useSession } from '../api/session'
import { useNow } from '../hooks/useNow'
import { useStatusStream } from '../hooks/useStatusStream'
import { bridgeLamp, cinegyLamp, telegramLamp } from '../lib/lamps'
import { LiveStatusContext } from './LiveStatusContext'
import { SignalLamp } from './SignalLamp'
import { UserMenu } from './UserMenu'
import classes from './Shell.module.css'

const navigation = [
  { to: '/', label: 'لوحة الهواء', description: 'الطبقات وحالة المحرك', icon: IconBroadcast, admin: false },
  { to: '/templates', label: 'القوالب', description: 'عرض الرسوم على الهواء', icon: IconLayoutGrid, admin: false },
  { to: '/sessions', label: 'الجلسات', description: 'المتصفحات المسجّلة', icon: IconDevices, admin: false },
  { to: '/accounts', label: 'الحسابات', description: 'دخول الويب بكلمة مرور', icon: IconUsersGroup, admin: true },
]

export function Shell() {
  const [opened, { toggle, close }] = useDisclosure()
  const session = useSession()
  const live = useStatusStream()
  const now = useNow()
  const location = useLocation()
  const admin = isAdmin(session.data)
  const status = live.status

  return (
    <LiveStatusContext.Provider value={live}>
      <AppShell
        header={{ height: 64 }}
        navbar={{ width: 248, breakpoint: 'sm', collapsed: { mobile: !opened } }}
        padding={{ base: 'md', sm: 'xl' }}
      >
        <AppShell.Header className={classes.header}>
          <Group h="100%" px="md" justify="space-between" wrap="nowrap">
            <Group gap="sm" wrap="nowrap">
              <Burger opened={opened} onClick={toggle} hiddenFrom="sm" size="sm" aria-label="القائمة" />
              <div className={classes.mark} aria-hidden />
              <Stack gap={0}>
                <Text fw={700} lh={1.2}>
                  جسر Cinegy
                </Text>
                {status && (
                  <Text size="xs" c="dimmed" className="cgb-mono">
                    {status.cinegy.address}:{5521 + status.cinegy.channel}
                  </Text>
                )}
              </Stack>
            </Group>
            <Group gap="xs" wrap="nowrap">
              <Group gap="xs" visibleFrom="md" wrap="nowrap">
                <SignalLamp label="الجسر" {...bridgeLamp(live)} />
                <SignalLamp label="المحرك" {...cinegyLamp(status, now)} />
                <SignalLamp label="Telegram" {...telegramLamp(status)} />
              </Group>
              {session.data && <UserMenu user={session.data} />}
            </Group>
          </Group>
        </AppShell.Header>

        <AppShell.Navbar p="sm" className={classes.navbar}>
          <AppShell.Section grow component={ScrollArea}>
            <Stack gap={4}>
              {navigation
                .filter((item) => !item.admin || admin)
                .map((item) => (
                  <NavLink
                    key={item.to}
                    component={RouterLink}
                    to={item.to}
                    end
                    onClick={close}
                    active={location.pathname === item.to}
                    label={item.label}
                    description={item.description}
                    leftSection={<item.icon size={20} stroke={1.6} />}
                    className={classes.link}
                  />
                ))}
            </Stack>
          </AppShell.Section>
          <AppShell.Section>
            <Group gap="xs" hiddenFrom="md" mb="sm" wrap="wrap">
              <SignalLamp label="الجسر" {...bridgeLamp(live)} />
              <SignalLamp label="المحرك" {...cinegyLamp(status, now)} />
              <SignalLamp label="Telegram" {...telegramLamp(status)} />
            </Group>
            {status && (
              <Badge variant="default" radius="sm" fw={500} className="cgb-mono">
                v{status.version}
              </Badge>
            )}
          </AppShell.Section>
        </AppShell.Navbar>

        <AppShell.Main>
          <Outlet />
        </AppShell.Main>
      </AppShell>
    </LiveStatusContext.Provider>
  )
}
