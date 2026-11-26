import { Center, Loader, Paper, Stack, Tabs, Text, Title } from '@mantine/core'
import { IconBrandTelegram, IconBroadcast, IconKey } from '@tabler/icons-react'
import { Navigate } from 'react-router'
import { useSession } from '../../api/session'
import classes from './LoginPage.module.css'
import { PasswordSignIn } from './PasswordSignIn'
import { TelegramSignIn } from './TelegramSignIn'

export function LoginPage() {
  const session = useSession()
  if (session.isPending) {
    return (
      <Center h="100vh">
        <Loader />
      </Center>
    )
  }
  if (session.data) return <Navigate to="/" replace />

  return (
    <div className={classes.page}>
      <aside className={classes.brand}>
        <div className={classes.brandMark}><IconBroadcast size={25} stroke={1.7} aria-hidden /> Cinegy</div>
        <div className={classes.brandText}>
          <Text className={classes.brandTitle}>إدارة الجرافيك</Text>
          <Text className={classes.brandLead}>الرسوم على الهواء، تحرير الأخبار، ومراقبة البث.</Text>
        </div>
      </aside>

      <main className={classes.panel}>
        <Paper className={classes.card} p={{ base: 'lg', sm: 32 }} radius="xl">
          <Stack gap="lg">
            <div>
              <Text size="sm" fw={700} color="signal" hiddenFrom="md">إدارة الجرافيك</Text>
              <Title order={1} size="h2">تسجيل الدخول</Title>
              <Text c="dimmed" size="sm" mt={4}>
                بحسابك في البوت، أو بكلمة مرور أعطاك إياها المشرف.
              </Text>
            </div>
            <Tabs defaultValue="telegram" variant="pills" radius="md">
              <Tabs.List grow mb="lg" className={classes.methods}>
                <Tabs.Tab value="telegram" leftSection={<IconBrandTelegram size={18} />}>
                  عبر Telegram
                </Tabs.Tab>
                <Tabs.Tab value="password" leftSection={<IconKey size={18} />}>
                  بكلمة مرور
                </Tabs.Tab>
              </Tabs.List>
              <Tabs.Panel value="telegram">
                <TelegramSignIn />
              </Tabs.Panel>
              <Tabs.Panel value="password">
                <PasswordSignIn />
              </Tabs.Panel>
            </Tabs>
          </Stack>
        </Paper>
      </main>
    </div>
  )
}
