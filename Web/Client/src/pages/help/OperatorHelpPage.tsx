import { Alert, Button, List, Paper, SimpleGrid, Skeleton, Stack, Tabs, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { Link } from 'react-router'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'

const destinations = new Map([
  ['templates', ['القوالب', '/templates']],
  ['air', ['لوحة الهواء', '/air']],
  ['newsroom', ['غرفة الأخبار', '/newsroom']],
  ['schedule', ['جدولة القوالب', '/schedule']],
  ['history', ['سجل العمليات', '/history']],
  ['notices', ['التنبيهات', '/notices']],
  ['system', ['إدارة النظام', '/admin/overview']],
  ['access', ['صلاحيات البوت', '/telegram-access']],
  ['roles', ['إدارة أدوار Telegram', '/telegram-access']],
  ['announcements', ['التعاميم', '/admin/announcements']],
])

export function OperatorHelpPage() {
  const session = useSession()
  const help = useQuery({
    queryKey: ['operator-help', session.data?.id, session.data?.role],
    enabled: Boolean(session.data),
    staleTime: 0,
    gcTime: 0,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/help/operator', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })

  return (
    <Stack gap="lg">
      <PageHeader title="دليل الويب" />
      {help.isPending && <Skeleton h={180} radius="md" />}
      {help.isError && <Alert color="red" role="alert">{messageFor(help.error.message)}</Alert>}
      {help.data && !help.isError && (
        <Tabs defaultValue="guide">
          <Tabs.List>
            <Tabs.Tab value="guide">دليل التشغيل</Tabs.Tab>
            <Tabs.Tab value="updates">ما الجديد</Tabs.Tab>
          </Tabs.List>
          <Tabs.Panel value="guide" pt="md">
            <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="sm">
              {help.data.chapters.map((chapter) => {
                const destination = destinations.get(chapter.id)
                if (!destination) return null
                const [label, to] = destination
                return (
                  <Paper key={chapter.id} withBorder p="md" radius="md" component="article">
                    <Stack align="flex-start" gap="xs">
                      <Title order={2} size="h4">{chapter.title}</Title>
                      <Text size="sm" c="dimmed">{chapter.detail}</Text>
                      <Button component={Link} to={to} size="xs" variant="light">{label}</Button>
                    </Stack>
                  </Paper>
                )
              })}
            </SimpleGrid>
          </Tabs.Panel>
          <Tabs.Panel value="updates" pt="md">
            <Stack gap="sm">
              {help.data.releases.map((release) => (
                <Paper key={release.version} withBorder p="md" radius="md" component="article">
                  <Title order={2} size="h4" mb="xs">الإصدار <bdi dir="ltr">{release.version}</bdi></Title>
                  <List spacing="xs" size="sm">
                    {release.items.map((item) => <List.Item key={item}>{item}</List.Item>)}
                  </List>
                </Paper>
              ))}
            </Stack>
          </Tabs.Panel>
        </Tabs>
      )}
    </Stack>
  )
}
