import { AppShell, Badge, Burger, Group, NavLink, ScrollArea, Stack, Text } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { IconBroadcast, IconCalendarTime, IconDevices, IconDeviceTv, IconLayoutGrid, IconNews, IconUserCheck, IconUsersGroup } from '@tabler/icons-react'
import { NavLink as RouterLink, Outlet, useLocation } from 'react-router'
import { useState } from 'react'
import { isAdmin, useSession } from '../api/session'
import { useNow } from '../hooks/useNow'
import { useStatusStream } from '../hooks/useStatusStream'
import { bridgeLamp, cinegyLamp, telegramLamp } from '../lib/lamps'
import { LivePage } from '../pages/live/LivePage'
import { LiveStatusContext } from './LiveStatusContext'
import { SignalLamp } from './SignalLamp'
import { UserMenu } from './UserMenu'
import classes from './Shell.module.css'

const navigation = [
  { to: '/newsroom', label: 'غرفة الأخبار', description: 'العواجل والموجز والشريط', icon: IconNews, admin: false },
  { to: '/air', label: 'لوحة الهواء', description: 'الطبقات وحالة المحرك', icon: IconBroadcast, admin: false },
  { to: '/live', label: 'البث المباشر', description: 'مشاهدة الخرج ومراقبة الإشارة', icon: IconDeviceTv, admin: false },
  { to: '/templates', label: 'القوالب', description: 'عرض الرسوم على الهواء', icon: IconLayoutGrid, admin: false },
  { to: '/schedule', label: 'جدولة القوالب', description: 'مواعيد العرض القادمة', icon: IconCalendarTime, admin: false },
  { to: '/sessions', label: 'الجلسات', description: 'المتصفحات المسجّلة', icon: IconDevices, admin: false },
  { to: '/accounts', label: 'الحسابات', description: 'دخول الويب بكلمة مرور', icon: IconUsersGroup, admin: true },
  { to: '/telegram-access', label: 'صلاحيات البوت', description: 'طلبات الوصول وأدوار Telegram', icon: IconUserCheck, admin: true },
]

const sections = [
  { label: 'التشغيل', links: navigation.slice(0, 5) },
  { label: 'إدارة الوصول', links: navigation.slice(5) },
]

export function Shell() {
  const [opened, { toggle, close }] = useDisclosure()
  const session = useSession()
  const live = useStatusStream()
  const now = useNow()
  const location = useLocation()
  const [watching, setWatching] = useState(false)
  const currentPath = location.pathname.replace(/\/$/, '')
  const livePage = currentPath === '/live'
  const admin = isAdmin(session.data)
  const status = live.status

  return (
    <LiveStatusContext.Provider value={live}>
      <AppShell
        header={{ height: 68 }}
        navbar={{ width: 256, breakpoint: 'sm', collapsed: { mobile: !opened } }}
        padding={{ base: 'md', sm: 'xl' }}
      >
        <AppShell.Header className={classes.header}>
          <Group h="100%" px={{ base: 'md', sm: 'lg' }} justify="space-between" wrap="nowrap">
            <Group gap="sm" wrap="nowrap">
              <Burger opened={opened} onClick={toggle} hiddenFrom="sm" size="sm" aria-label="القائمة" />
              <div className={classes.mark} aria-hidden><IconBroadcast size={20} stroke={1.8} /></div>
              <Stack gap={0}>
                <Text fw={700} lh={1.2}>
                  غرفة تحكّم Cinegy
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

        <AppShell.Navbar p="md" className={classes.navbar}>
          <AppShell.Section grow component={ScrollArea}>
            <Stack component="nav" gap="lg" aria-label="التنقّل الرئيسي">
              {sections.map((section) => (
                <Stack key={section.label} gap={4}>
                  <Text component="div" className={classes.sectionLabel}>{section.label}</Text>
                  {section.links.filter((item) => !item.admin || admin).map((item) => (
                    <NavLink
                      key={item.to}
                      component={RouterLink}
                      to={item.to}
                      end
                      onClick={close}
                      active={currentPath === item.to}
                      label={item.label}
                      description={item.description}
                      leftSection={<span className={classes.navIcon}><item.icon size={19} stroke={1.7} /></span>}
                      className={classes.link}
                    />
                  ))}
                </Stack>
              ))}
            </Stack>
          </AppShell.Section>
          <AppShell.Section className={classes.navFooter}>
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

        <AppShell.Main id="bridge-main" tabIndex={-1} className={classes.main} data-watch-workspace={!livePage && watching || undefined}>
          {(livePage || watching) && <LivePage active={livePage} watching={watching} onWatchingChange={setWatching} />}
          {!livePage && <div className={classes.route}><Outlet /></div>}
        </AppShell.Main>
      </AppShell>
    </LiveStatusContext.Provider>
  )
}
