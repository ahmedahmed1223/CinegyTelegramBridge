import { Alert, Badge, Button, Group, Pagination, Paper, Skeleton, Stack, Tabs, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconRefresh } from '@tabler/icons-react'
import { useState } from 'react'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { PageHeader } from '../../components/PageHeader'
import { UrgentPlayback } from './UrgentPlayback'
import { UrgentTiming } from './UrgentTiming'
import { UrgentTable } from './UrgentTable'
import { TickerEditor } from './TickerEditor'
import { BulletinEditor, BulletinNameForm } from './BulletinEditor'
import { ProgrammeBoards } from './ProgrammeBoards'
import classes from './NewsroomPage.module.css'

const views = {
  urgent: { label: 'العواجل', title: 'إدارة العواجل', empty: 'لا توجد عواجل في الجدول.' },
  bulletins: { label: 'الموجز', title: 'مكتبة الموجز', empty: 'لا توجد موجزات محفوظة.' },
  ticker: { label: 'الشريط', title: 'إدارة شريط الأخبار', empty: 'لا توجد أخبار منشورة في الشريط.' },
  boards: { label: 'لوحات البرامج', title: 'لوحات البرامج', empty: 'لا توجد لوحات برامج.' },
} as const
type View = keyof typeof views
const sectionKeys = Object.keys(views) as View[]

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
  const [visited, setVisited] = useState<View[]>(['urgent'])

  return (
    <Stack gap="xl" className={classes.page}>
      <PageHeader title="غرفة الأخبار" description="حرّر العواجل والموجز وشريط الأخبار ولوحات البرامج." />

      <Tabs
        value={view}
        variant="pills"
        keepMountedMode="activity"
        onChange={(next) => {
          if (next === 'urgent' || next === 'bulletins' || next === 'ticker' || next === 'boards') {
            setView(next)
            setVisited((previous) => previous.includes(next) ? previous : [...previous, next])
          }
        }}
      >
        <Tabs.List grow aria-label="أقسام غرفة الأخبار" className={classes.tabs}>
          {sectionKeys.map((section) => <Tabs.Tab key={section} value={section}>{views[section].label}</Tabs.Tab>)}
        </Tabs.List>
        {sectionKeys.map((section) => (
          <Tabs.Panel key={section} value={section} pt="lg">
            {/* Mount on first visit; hidden Activity panels suspend polling effects. */}
            {visited.includes(section) && (
              section === 'boards' ? <ProgrammeBoards /> : <NewsroomContent view={section} />
            )}
          </Tabs.Panel>
        ))}
      </Tabs>
    </Stack>
  )
}

function NewsroomContent({ view }: { view: Exclude<View, 'boards'> }) {
  const [page, setPage] = useState(0)
  const [selected, setSelected] = useState<string[]>([])
  const [bulletinId, setBulletinId] = useState<string | null>(null)
  const [creatingBulletin, setCreatingBulletin] = useState(false)
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

  return view === 'bulletins' && bulletinId ? (
    <BulletinEditor key={bulletinId} id={bulletinId} onBack={() => setBulletinId(null)} onSaved={(value) => {
      setBulletinId(value.id)
      void content.refetch()
    }} />
  ) : <Stack gap="md">
    <Group justify="space-between" align="center">
      <div>
        <Title order={2}>{current.title}</Title>
        {result && view !== 'ticker' && <Text size="sm" c="dimmed">{number.format(result.total)} في القائمة</Text>}
      </div>
      {view !== 'ticker' && (
        <Group gap="xs">
          <Button variant="default" leftSection={<IconRefresh size={16} />} onClick={() => content.refetch()} loading={content.isFetching}>
            تحديث
          </Button>
          {view === 'bulletins' && result && !content.isError && (
            <Button disabled={creatingBulletin} onClick={() => setCreatingBulletin(true)}>إنشاء موجز</Button>
          )}
        </Group>
      )}
    </Group>

    {view === 'bulletins' && creatingBulletin && (
      <BulletinNameForm mode="create" onCancel={() => setCreatingBulletin(false)} onSave={(value) => {
        setCreatingBulletin(false)
        setBulletinId(value.id)
        void content.refetch()
      }} />
    )}
    {view === 'ticker' && (
      <>
        <TickerEditor onPublished={() => content.refetch()} />
        <Group justify="space-between">
          <div>
            <Title order={4}>الشريط المنشور</Title>
            {result && <Text size="sm" c="dimmed">{number.format(result.total)} خبرًا</Text>}
          </div>
          <Button variant="default" onClick={() => content.refetch()} loading={content.isFetching} leftSection={<IconRefresh size={16} />}>
            تحديث المنشور
          </Button>
        </Group>
      </>
    )}

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
      <>
        <UrgentPlayback selected={selected} />
        <UrgentTiming />
        <UrgentTable
          key={result.page}
          board={result}
          selected={selected}
          onToggle={(id) => setSelected((previous) => previous.includes(id) ? previous.filter((value) => value !== id) : [...previous, id])}
          onClear={() => setSelected([])}
          onSaved={async (added) => {
            const nextPage = added ? Math.floor(result.total / 20) : result.page
            if (nextPage !== result.page) setPage(nextPage)
            await content.refetch()
          }}
        />
      </>
    ) : result?.items.length ? (
      <Paper radius="lg">
        <ol className={classes.list} start={result.page * 20 + 1}>
          {result.items.map((item, index) => {
            const state = states[item.state]
            return (
              <li key={item.id ?? index} className={classes.row}>
                <div className={classes.entry}>
                  <Text component="span" className={classes.headline} dir="auto">{item.title}</Text>
                  {(item.rows != null || state) && (
                    <Group gap="xs" className={classes.details}>
                      {item.rows != null && <Text size="sm" c="dimmed">الصفوف {number.format(item.rows)}</Text>}
                      {state && <Badge color={state.color} variant="light">{state.label}</Badge>}
                      {view === 'bulletins' && item.id && (
                        <Button variant="light" size="compact-sm" aria-label={`فتح ${item.title}`}
                          disabled={creatingBulletin} onClick={() => setBulletinId(item.id)}>فتح</Button>
                      )}
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
}
