import { Center, Loader, Paper, Stack, Tabs, Text, Title } from '@mantine/core'
import { IconBrandTelegram, IconKey } from '@tabler/icons-react'
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
      <aside className={classes.brand} aria-hidden>
        <div className={classes.tally}>
          <span className={classes.tallyDot} />
          ON AIR
        </div>
        <div className={classes.brandText}>
          <Text className={classes.brandTitle}>جسر Cinegy</Text>
          <Text className={classes.brandLead}>
            غرفة التحكم بالرسوم على الهواء، من أي متصفح. البوت والويب يعملان معًا على الحالة نفسها.
          </Text>
        </div>
        <div className={classes.grid} />
      </aside>

      <main className={classes.panel}>
        <Paper className={classes.card} p={{ base: 'lg', sm: 32 }} radius="lg" shadow="sm">
          <Stack gap="lg">
            <div>
              <Title order={2}>تسجيل الدخول</Title>
              <Text c="dimmed" size="sm" mt={4}>
                بحسابك في البوت، أو بكلمة مرور أعطاك إياها المشرف.
              </Text>
            </div>
            <Tabs defaultValue="telegram" variant="pills" radius="md">
              <Tabs.List grow mb="lg">
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
