import { Alert, Badge, Button, Group, Pagination, Paper, Skeleton, Stack, Tabs, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconRefresh } from '@tabler/icons-react'
import { useState } from 'react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { UrgentTable } from './UrgentTable'
import classes from './NewsroomPage.module.css'

const views = {
  urgent: { label: 'العواجل', title: 'إدارة العواجل', empty: 'لا توجد عواجل في الجدول.' },
  bulletins: { label: 'الموجز', title: 'مكتبة الموجز', empty: 'لا توجد موجزات محفوظة.' },
  ticker: { label: 'الشريط', title: 'الشريط المنشور', empty: 'لا توجد أخبار منشورة في الشريط.' },
} as const
type View = keyof typeof views

const states: Record<string, { label: string; color: string }> = {
  on_air: { label: 'على الهواء', color: 'red' },
  disabled: { label: 'معطّل', color: 'gray' },
  selected: { label: 'محدّد', color: 'signal' },
  ready: { label: 'جاهز', color: 'teal' },
  saved: { label: 'محفوظ', color: 'gray' },
}
const number = new Intl.NumberFormat('ar')

export function NewsroomPage() {
  const [view, setView] = useState<View>('urgent')
  const [page, setPage] = useState(0)
  const content = useQuery({
    queryKey: ['newsroom', view, page],
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/{view}', {
        params: { path: { view }, query: { page } },
        signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    retry: false,
    refetchOnWindowFocus: view !== 'ticker',
  })
  const current = views[view]
  const result = content.data

  return (
    <Stack gap="xl" className={classes.page}>
      <div>
        <Title order={2}>غرفة الأخبار</Title>
        <Text c="dimmed">تابع محتوى النشرات والشريط من الجسر.</Text>
      </div>

      <Tabs
        value={view}
        onChange={(next) => {
          if (next === 'urgent' || next === 'bulletins' || next === 'ticker') {
            setView(next)
            setPage(0)
          }
        }}
        keepMounted={false}
      >
        <Tabs.List grow aria-label="أقسام غرفة الأخبار">
          {Object.entries(views).map(([key, { label }]) => <Tabs.Tab key={key} value={key}>{label}</Tabs.Tab>)}
        </Tabs.List>
        <Tabs.Panel value={view} pt="lg">
          <Stack gap="md">
            <Group justify="space-between" align="center">
              <div>
                <Title order={3}>{current.title}</Title>
                {result && <Text size="sm" c="dimmed">{number.format(result.total)} في القائمة</Text>}
              </div>
              <Button variant="default" leftSection={<IconRefresh size={16} />} onClick={() => content.refetch()} loading={content.isFetching}>
                تحديث
              </Button>
            </Group>

            {content.isError ? (
              <Alert color={content.error.message === 'content_disabled' ? 'gray' : 'red'} role="alert">
                {messageFor(content.error.message)}
              </Alert>
            ) : content.isPending ? (
              <Stack gap="xs" aria-busy="true" aria-label="جارٍ تحميل المحتوى">
                <Skeleton h={56} />
                <Skeleton h={56} />
                <Skeleton h={56} />
              </Stack>
            ) : result && view === 'urgent' ? (
              <UrgentTable
                key={result.page}
                board={result}
                onSaved={async (added) => {
                  const nextPage = added ? Math.floor(result.total / 20) : result.page
                  if (nextPage !== result.page) setPage(nextPage)
                  await content.refetch()
                }}
              />
            ) : result?.items.length ? (
              <Paper radius="lg">
                <ol className={classes.list} start={result.page * 20 + 1}>
                  {result.items.map((item, index) => {
                    const state = states[item.state]
                    return (
                      <li key={index} className={classes.row}>
                        <div className={classes.entry}>
                          <Text component="span" className={classes.headline} dir="auto">{item.title}</Text>
                          {(item.rows != null || state) && (
                            <Group gap="xs" className={classes.details}>
                              {item.rows != null && <Text size="sm" c="dimmed">الصفوف {number.format(item.rows)}</Text>}
                              {state && <Badge color={state.color} variant="light">{state.label}</Badge>}
                            </Group>
                          )}
                        </div>
                      </li>
                    )
                  })}
                </ol>
              </Paper>
            ) : (
              <Paper p="xl" radius="lg"><Text c="dimmed">{current.empty}</Text></Paper>
            )}

            {result && result.pageCount > 1 && (
              <Pagination
                total={result.pageCount}
                value={result.page + 1}
                onChange={(next) => setPage(next - 1)}
                getItemProps={(value) => ({ 'aria-label': `الصفحة ${number.format(value)}` })}
                getControlProps={(control) => ({ 'aria-label': control === 'next' ? 'الصفحة التالية' : 'الصفحة السابقة' })}
              />
            )}
          </Stack>
        </Tabs.Panel>
      </Tabs>
    </Stack>
  )
}
