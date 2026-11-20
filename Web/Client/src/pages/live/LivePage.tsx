import { Alert, Badge, Button, Group, Paper, Skeleton, Stack, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconAntenna, IconCircleDot, IconDeviceTv, IconPlayerPlay, IconPlayerStop, IconRefresh } from '@tabler/icons-react'
import { useEffect, useRef, useState } from 'react'
import type Hls from 'hls.js'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { useLiveStatus } from '../../layout/LiveStatusContext'
import { formatClock, formatDateTime } from '../../lib/time'
import classes from './LivePage.module.css'

type Feed = Schemas['FeedStatus']
type PlayerState = 'loading' | 'playing' | 'paused' | 'buffering' | 'failed'
const number = new Intl.NumberFormat('ar')
const feedStates: Record<string, { label: string; color: string }> = {
  receiving: { label: 'الإشارة تصل', color: 'teal' },
  unreachable: { label: 'الإشارة منقطعة', color: 'red' },
  black: { label: 'صورة سوداء', color: 'red' },
  degraded: { label: 'تعذّر آخر فحص', color: 'yellow' },
  off: { label: 'المراقبة معطّلة', color: 'gray' },
  pending: { label: 'بانتظار أول فحص', color: 'gray' },
  unconfigured: { label: 'مصدر المراقبة غير مضبوط', color: 'gray' },
}
const playerLabels = {
  loading: 'جارٍ فتح البث',
  playing: 'جارٍ العرض',
  paused: 'المشاهدة متوقفة مؤقتًا',
  buffering: 'جارٍ استئناف البث',
  failed: 'تعذّر تشغيل الفيديو',
}

function LiveVideo({ url, onStop }: { url: string; onStop: () => void }) {
  const video = useRef<HTMLVideoElement>(null)
  const [state, setState] = useState<PlayerState>('loading')
  const [attempt, setAttempt] = useState(0)

  useEffect(() => { video.current?.focus({ preventScroll: true }) }, [])

  useEffect(() => {
    const element = video.current
    if (!element) return
    let disposed = false
    let engine: Hls | undefined
    function fail() {
      if (!disposed) setState('failed')
      const stopped = engine
      engine = undefined
      stopped?.destroy()
    }
    async function open(target: HTMLVideoElement) {
      if (/\.(mp4|webm)$/i.test(new URL(url).pathname)) {
        target.src = url
        return
      }
      const { default: HlsEngine } = await import('hls.js')
      if (disposed) return
      if (!HlsEngine.isSupported()) {
        if (target.canPlayType('application/vnd.apple.mpegurl')) target.src = url
        else fail()
        return
      }
      engine = new HlsEngine({ enableWorker: false, lowLatencyMode: true, backBufferLength: 15 })
      engine.on(HlsEngine.Events.ERROR, (_event, data) => { if (data.fatal) fail() })
      engine.loadSource(url)
      engine.attachMedia(target)
    }
    element.addEventListener('error', fail)
    void open(element).catch(fail)
    return () => {
      disposed = true
      element.removeEventListener('error', fail)
      engine?.destroy()
      element.pause()
      element.removeAttribute('src')
      element.load()
    }
  }, [url, attempt])

  return (
    <>
      <div className={classes.screen}>
        <video
          ref={video} controls muted autoPlay playsInline aria-label="مشغّل البث المباشر"
          onPlaying={() => setState('playing')}
          onWaiting={() => setState((previous) => previous === 'failed' || previous === 'loading' ? previous : 'buffering')}
          onPause={() => setState((previous) => previous === 'playing' || previous === 'buffering' ? 'paused' : previous)}
          onEnded={() => setState('paused')}
          onCanPlay={() => { if (video.current?.paused) setState((previous) => previous === 'loading' ? 'paused' : previous) }}
        />
      </div>
      <Group justify="space-between" className={classes.monitorFooter}>
        <Text size="sm" role="status" className={classes.playerStatus} data-state={state}>
          <IconCircleDot size={15} aria-hidden />
          {playerLabels[state]}
        </Text>
        <Group gap="xs">
          {state === 'failed' && <Button size="xs" variant="default" leftSection={<IconRefresh size={15} />}
            onClick={() => { setState('loading'); setAttempt((previous) => previous + 1) }}>إعادة المحاولة</Button>}
          <Button size="xs" variant="default" leftSection={<IconPlayerStop size={15} />} onClick={onStop}>إيقاف المشاهدة</Button>
        </Group>
      </Group>
      {state === 'failed' && (
        <Alert color="yellow" className={classes.playerAlert}>
          تأكّد من إتاحة رابط المشاهدة لهذا المتصفح ومن سماح خادم الفيديو بتشغيله من الموقع.
        </Alert>
      )}
    </>
  )
}

function SignalDetails({ feed, fresh }: { feed: Feed | undefined | null; fresh: boolean }) {
  const state = fresh && feed ? feedStates[feed.state] : undefined
  return (
    <Paper className={classes.signalPanel} radius="lg">
      <Group justify="space-between" gap="xs" wrap="wrap">
        <Title order={3}>إشارة الخرج</Title>
        <Badge color={state?.color ?? 'gray'} variant="light">{state?.label ?? (feed ? 'آخر قراءة محفوظة' : 'بانتظار الجسر')}</Badge>
      </Group>
      <dl className={classes.details}>
        <div>
          <dt>المصدر الذي يراقبه الجسر</dt>
          <dd>{feed?.activeSource === 'backup' ? 'الاحتياطي' : feed?.activeSource === 'primary' ? 'الرئيسي' : '—'}</dd>
        </div>
        <div>
          <dt>آخر فحص</dt>
          <dd>{formatDateTime(feed?.lastCheckAt)}</dd>
        </div>
        <div>
          <dt>دورية الفحص</dt>
          <dd>{feed ? (feed.intervalMinutes > 0 ? `كل ${number.format(feed.intervalMinutes)} د` : 'معطّلة') : '—'}</dd>
        </div>
        {feed?.backupConfigured && feed.activeSource !== 'backup' && <div><dt>المصدر الاحتياطي</dt><dd>مُعدّ</dd></div>}
      </dl>
    </Paper>
  )
}

export function LivePage() {
  const live = useLiveStatus()
  const feed = live.status?.feed
  const fresh = live.stream === 'live' && live.bridgeOnline
  const [watching, setWatching] = useState(false)
  const restoreWatchFocus = useRef(false)
  const player = useQuery({
    queryKey: ['live-playback'],
    retry: false,
    refetchOnWindowFocus: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/live', { signal })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const url = player.data?.url
  return (
    <Stack gap="xl" className={classes.page}>
      <header className={classes.heading}>
        <Title order={1}>البث المباشر</Title>
        <Text c="dimmed">شاهد خرج القناة وتابع حالة الإشارة من غرفة التحكم.</Text>
      </header>
      <div className={classes.workspace}>
        <Paper radius="lg" className={classes.monitor}>
          <Group gap="xs" className={classes.monitorHeader}>
            <Group gap="xs"><IconDeviceTv size={20} aria-hidden /><Title order={2}>مشاهدة الخرج</Title></Group>
          </Group>
          {watching && url ? <LiveVideo url={url} key={url} onStop={() => {
            restoreWatchFocus.current = true
            setWatching(false)
          }} /> : (
            <div className={classes.screen}>
              {player.isPending ? <Skeleton className={classes.screenLoading} aria-label="جارٍ تحميل إعداد المشاهدة" /> : (
                <Stack align="center" gap="sm" className={classes.idle}>
                  <div className={classes.idleIcon}><IconAntenna size={35} stroke={1.4} aria-hidden /></div>
                  {player.error ? (
                    <>
                      <Text size="sm" role="alert">{player.error.message}</Text>
                      <Button size="sm" variant="light" onClick={() => void player.refetch()} leftSection={<IconRefresh size={16} />}>إعادة المحاولة</Button>
                    </>
                  ) : url ? (
                    <Button size="md" onClick={() => setWatching(true)} leftSection={<IconPlayerPlay size={19} />}
                      ref={(button) => {
                        if (button && restoreWatchFocus.current) {
                          restoreWatchFocus.current = false
                          button.focus({ preventScroll: true })
                        }
                      }}>مشاهدة البث</Button>
                  ) : (
                    <>
                      <Text fw={600}>رابط المشاهدة غير مضبوط</Text>
                      <Text size="sm">أضف رابط خرج مخصصًا للمشاهدة في إعداد <bdi className="cgb-mono">LivePlaybackUrl</bdi>.</Text>
                    </>
                  )}
                </Stack>
              )}
            </div>
          )}
        </Paper>
        <SignalDetails feed={feed} fresh={fresh} />
      </div>
      <Paper radius="lg" className={classes.history}>
        <Group justify="space-between" align="baseline" gap="xs" className={classes.historyHead}>
          <Title order={3}>الانقطاعات الأخيرة</Title>
          {feed && <Text size="sm" c="dimmed">آخر ٢٤ ساعة · {number.format(feed.outageCount)} انقطاع · <bdi>{formatClock(feed.outageSeconds * 1000)}</bdi></Text>}
        </Group>
        {!feed?.recent.length ? (
          <Text c="dimmed" size="sm" className={classes.empty}>{feed ? 'لا توجد انقطاعات مسجّلة.' : 'بانتظار سجل الجسر.'}</Text>
        ) : (
          <ol className={classes.outages}>
            {feed.recent.map((outage) => (
              <li key={`${outage.kind}-${outage.startedAt}`}>
                <div>
                  <Text fw={600} size="sm">{outage.kind === 'black' ? 'صورة سوداء' : 'إشارة منقطعة'}</Text>
                  <Text c="dimmed" size="xs">{formatDateTime(outage.startedAt)}</Text>
                </div>
                {outage.endedAt > 0
                  ? <Text size="sm" className="cgb-mono">{formatClock(outage.endedAt - outage.startedAt)}</Text>
                  : <Badge color={fresh ? 'red' : 'gray'} variant="light">{fresh ? 'مستمر' : 'آخر قراءة: مستمر'}</Badge>}
              </li>
            ))}
          </ol>
        )}
      </Paper>
    </Stack>
  )
}
