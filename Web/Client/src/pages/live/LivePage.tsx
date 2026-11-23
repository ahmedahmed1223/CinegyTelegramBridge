import { Alert, Badge, Button, CopyButton, Group, Paper, Skeleton, Stack, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconAntenna, IconArrowUpRight, IconCircleDot, IconCopy, IconDeviceTv, IconPictureInPicture, IconPlayerPlay, IconPlayerStop, IconRefresh } from '@tabler/icons-react'
import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router'
import type Hls from 'hls.js'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'
import { AirOperationsMenu } from '../status/AirOperationsMenu'
import { useLiveStatus } from '../../layout/LiveStatusContext'
import { formatClock, formatDateTime } from '../../lib/time'
import classes from './LivePage.module.css'
import { CapturePanel } from './CapturePanel'
import { RelayPanel } from './RelayPanel'

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

function LiveVideo({ url, floating, nativePip, onPipChange, onStop }: {
  url: string
  floating: boolean
  nativePip: boolean
  onPipChange: (open: boolean) => void
  onStop: () => void
}) {
  const video = useRef<HTMLVideoElement>(null)
  const [state, setState] = useState<PlayerState>('loading')
  const [attempt, setAttempt] = useState(0)
  const [pipError, setPipError] = useState(false)
  const canUsePip = document.pictureInPictureEnabled && typeof HTMLVideoElement.prototype.requestPictureInPicture === 'function'

  useEffect(() => { video.current?.focus({ preventScroll: true }) }, [])

  useEffect(() => {
    const element = video.current
    if (!element) return
    onPipChange(document.pictureInPictureElement === element)
    const enter = () => { setPipError(false); onPipChange(true) }
    const leave = () => onPipChange(false)
    element.addEventListener('enterpictureinpicture', enter)
    element.addEventListener('leavepictureinpicture', leave)
    return () => {
      element.removeEventListener('enterpictureinpicture', enter)
      element.removeEventListener('leavepictureinpicture', leave)
      if (document.pictureInPictureElement === element) void document.exitPictureInPicture().catch(() => {})
    }
  }, [onPipChange])

  async function togglePip() {
    const element = video.current
    if (!element) return
    setPipError(false)
    try {
      if (document.pictureInPictureElement === element) await document.exitPictureInPicture()
      else await element.requestPictureInPicture()
    } catch {
      setPipError(true)
    }
  }

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
          tabIndex={floating && nativePip ? -1 : 0}
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
          {canUsePip && state !== 'loading' && state !== 'failed' && (
            <Button size="xs" variant="default" leftSection={<IconPictureInPicture size={15} />} aria-pressed={nativePip} onClick={() => void togglePip()}>
              {nativePip ? 'إغلاق صورة داخل صورة' : 'صورة داخل صورة'}
            </Button>
          )}
          {!floating && <Button component={Link} to="/newsroom" size="xs" variant="subtle" leftSection={<IconArrowUpRight size={15} />}>المشاهدة أثناء التحرير</Button>}
          <Button size="xs" variant="default" leftSection={<IconPlayerStop size={15} />} onClick={onStop}>إيقاف المشاهدة</Button>
        </Group>
      </Group>
      {state === 'failed' && (
        <Alert color="yellow" className={classes.playerAlert}>
          تأكّد من إتاحة رابط المشاهدة لهذا المتصفح. إذا تغيّر عنوان خادم البث في إعدادات البوت، أعد تحميل صفحة البث.
        </Alert>
      )}
      {pipError && (
        <Alert color="yellow" className={classes.playerAlert} role="alert">
          تعذّر فتح نافذة المتصفح. يمكنك متابعة البث في المشغّل العائم داخل الموقع.
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

export function LivePage({ active, watching, onWatchingChange }: {
  active: boolean
  watching: boolean
  onWatchingChange: (watching: boolean) => void
}) {
  const admin = isAdmin(useSession().data)
  const live = useLiveStatus()
  const feed = live.status?.feed
  const fresh = live.stream === 'live' && live.bridgeOnline
  const [nativePip, setNativePip] = useState(false)
  const restoreWatchFocus = useRef(false)
  const player = useQuery({
    queryKey: ['live-playback'],
    retry: false,
    refetchInterval: active ? 15_000 : false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/live', { signal })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const url = player.data?.url
  return (
    <Stack gap="xl" className={active ? classes.page : classes.floatingPage}>
      {active && <PageHeader title="البث المباشر" description="مشاهدة خرج القناة ومراقبة الإشارة."
        actions={<AirOperationsMenu disabled={!live.bridgeOnline} />} />}
      <div className={active ? classes.workspace : undefined}>
        <Stack gap="md" className={classes.monitorColumn}>
          <Paper radius="lg" className={classes.monitor} data-floating-video={active ? undefined : nativePip ? 'native' : 'inline'}>
            <Group gap="xs" justify="space-between" className={classes.monitorHeader}>
              <Group gap="xs"><IconDeviceTv size={20} aria-hidden /><Title order={2}>مشاهدة الخرج</Title></Group>
              {active && url && <CopyButton value={url}>
                {({ copied, copy }) => <Button size="compact-sm" variant="subtle" onClick={copy} leftSection={<IconCopy size={15} aria-hidden />}>
                  {copied ? 'نُسخ رابط البث' : 'نسخ رابط البث'}
                </Button>}
              </CopyButton>}
              {!active && <Button component={Link} to="/live" size="compact-xs" variant="subtle">فتح صفحة البث</Button>}
            </Group>
            {watching && url ? <LiveVideo url={url} key={url} floating={!active} nativePip={nativePip} onPipChange={setNativePip} onStop={() => {
              restoreWatchFocus.current = true
              setNativePip(false)
              onWatchingChange(false)
              if (!active) document.getElementById('bridge-main')?.focus({ preventScroll: true })
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
                      <Button size="md" onClick={() => onWatchingChange(true)} leftSection={<IconPlayerPlay size={19} />}
                        ref={(button) => {
                          if (button && restoreWatchFocus.current) {
                            restoreWatchFocus.current = false
                            button.focus({ preventScroll: true })
                          }
                        }}>مشاهدة البث</Button>
                    ) : (
                      <>
                        <Text fw={600}>رابط المشاهدة غير مضبوط</Text>
                        <Text size="sm">يضيف المشرف «رابط مشاهدة البث» من إعدادات البوت.</Text>
                      </>
                    )}
                  </Stack>
                )}
              </div>
            )}
          </Paper>
          <CapturePanel hidden={!active} />
        </Stack>
        {active && <Stack gap="md">
          <SignalDetails feed={feed} fresh={fresh} />
          {admin && <RelayPanel />}
        </Stack>}
      </div>
      {active && <Paper radius="lg" className={classes.history}>
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
      </Paper>}
    </Stack>
  )
}
