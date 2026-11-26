import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ReactNode } from 'react'
import { MemoryRouter } from 'react-router'
import { expect, it, vi } from 'vitest'
import { getTemplates } from '../api/air'
import { api, type BridgeStatus, type Schemas } from '../api/client'
import { sessionKey } from '../api/session'
import { LiveStatusContext } from '../layout/LiveStatusContext'
import { LivePage } from '../pages/live/LivePage'
import { NewsroomPage } from '../pages/newsroom/NewsroomPage'
import { BulletinRunStatus } from '../pages/newsroom/BulletinPlayback'
import { UrgentTable } from '../pages/newsroom/UrgentTable'
import { UrgentAirBanner } from '../pages/newsroom/UrgentAirBanner'
import { TemplateSchedulePage } from '../pages/schedule/TemplateSchedulePage'
import { StatusPage } from '../pages/status/StatusPage'
import { ShowModal } from '../pages/templates/ShowModal'

vi.mock('../api/air', () => ({ getTemplates: vi.fn() }))

function renderPage(page: ReactNode, schedule?: Schemas['TemplateSchedulePage'], playback?: { url: string | null }, path = '/') {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  queryClient.setQueryData(sessionKey, { id: 1, name: 'مشغّل تجريبي', role: 'admin', method: 'test', webOnly: true })
  if (schedule) queryClient.setQueryData(['template-schedule', 0], schedule)
  if (playback) queryClient.setQueryData(['live-playback'], playback)
  return render(
    <MantineProvider env="test">
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={[path]}>{page}</MemoryRouter>
      </QueryClientProvider>
    </MantineProvider>,
  )
}

function emptySnapshot(freshUntil: number): BridgeStatus {
  return {
    version: '8.141.0', startedAt: 0, publishedAt: Date.now(), layers: [], feed: null,
    urgentNoticeId: null, urgentRevision: null,
    cinegy: { address: 'local', channel: 0, health: 'healthy', freshUntil, lastReadAt: Date.now() },
    telegram: { state: 'connected', failures: 0 },
  }
}

it('loads the on-air playlist and the station rundown when the air dashboard opens', async () => {
  const now = Date.now()
  const get = vi.spyOn(api, 'GET').mockImplementation(async path => ({
    data: path === '/api/status/programme' ? {
      checkedAtMs: now, statusAvailable: true, scheduleAvailable: true,
      current: { listed: true, label: 'المادة الحالية' }, cued: { listed: true, label: 'المادة المجهزة' },
    } : {
      items: [{ id: 'material', name: 'برنامج مدرج في الجدول', stationTime: '2026-11-26 19:00 +02:00', durationSeconds: 90, active: true }],
      page: 0, pageCount: 1, total: 1, activeKnown: true,
    },
    response: new Response(),
  }))
  const dashboard = <LiveStatusContext.Provider value={{ stream: 'live', bridgeOnline: true, status: emptySnapshot(now + 60_000) }}>
    <StatusPage />
  </LiveStatusContext.Provider>
  try {
    const { unmount } = renderPage(dashboard)
    expect(await screen.findByText('المادة الحالية')).toBeVisible()
    expect(screen.getByText('المادة المجهزة')).toBeVisible()
    const rundown = await screen.findByRole('table', { name: 'جدول البث' })
    expect(within(rundown).getByText('برنامج مدرج في الجدول')).toBeVisible()
    expect(within(rundown).getByText('على الهواء')).toBeVisible()
    expect(screen.getByRole('button', { name: 'التقاط صورة من البث' })).toBeEnabled()
    expect(get.mock.calls.map(([path]) => path)).toEqual(expect.arrayContaining(['/api/status/programme', '/api/schedule/materials']))

    const move = within(rundown).getByRole('button', { name: 'ترتيب عمود المادة' })
    const resize = within(rundown).getByRole('button', { name: 'تغيير عرض عمود المادة' })
    const forward = getComputedStyle(move).direction === 'rtl' ? 'ArrowLeft' : 'ArrowRight'
    fireEvent.keyDown(resize, { key: forward })
    fireEvent.keyDown(move, { key: forward })
    unmount()

    renderPage(dashboard)
    const reopened = await screen.findByRole('table', { name: 'جدول البث' })
    expect(within(reopened).getAllByRole('columnheader')[1]).toHaveTextContent('المادة')
    expect(within(reopened).getAllByRole('cell')[1]).toHaveTextContent('برنامج مدرج في الجدول')
    expect(reopened.querySelectorAll('col')[1]).toHaveStyle({ width: '256px' })
    fireEvent.click(screen.getByRole('button', { name: 'إعادة ضبط الأعمدة' }))
    expect(within(reopened).getAllByRole('columnheader')[0]).toHaveTextContent('المادة')
    expect(reopened.querySelectorAll('col')[0]).toHaveStyle({ width: '240px' })
  } finally {
    localStorage.removeItem('cgb-table-layout:broadcast-schedule')
    get.mockRestore()
  }
})

it('shows shared template text without overwriting the operator until they choose to reuse it', async () => {
  const get = vi.spyOn(api, 'GET').mockResolvedValue({ data: { lastValues: { title: 'النص الذي عُرض' } }, response: new Response() })
  try {
    renderPage(<ShowModal template={{ key: 'banner', name: 'قالب', layer: 3, category: null, disabled: false,
      fields: [{ name: 'title', label: 'العنوان', required: true, sensitive: false, maxLength: 80 }] }} onClose={() => {}} />)
    const field = screen.getByRole('textbox', { name: /العنوان/ })
    fireEvent.change(field, { target: { value: 'مسودة الويب' } })
    const reuse = await screen.findByRole('button', { name: 'استخدام النص المعروض سابقًا' })
    expect(field).toHaveValue('مسودة الويب')
    fireEvent.click(reuse)
    expect(field).toHaveValue('النص الذي عُرض')
  } finally { get.mockRestore() }
})

it('shows current and next bulletin headlines beside the stop and camera controls', () => {
  renderPage(<BulletinRunStatus id="bulletin" supported playback={{
    canStart: true, busy: true, review: null, layer: null, replacing: null, pausesTicker: null, canQueueAfterUrgent: false,
    run: { id: 'run', state: 'playing', row: 2, rowCount: 3, current: 'خبر الموجز الحالي', next: 'خبر الموجز التالي' },
  }}><button>معاينة الموجز</button></BulletinRunStatus>)
  const panel = screen.getByRole('region', { name: 'تشغيل الموجز' })
  expect(within(panel).getByText('خبر الموجز الحالي')).toBeVisible()
  expect(within(panel).getByText('خبر الموجز التالي')).toBeVisible()
  expect(within(panel).getByRole('button', { name: 'إيقاف العرض' })).toBeEnabled()
  expect(within(panel).getByRole('button', { name: 'التقاط صورة من البث' })).toBeEnabled()
})

it('offers capture in the bulletin library before any bulletin is opened', async () => {
  const get = vi.spyOn(api, 'GET').mockResolvedValue({ data: { items: [], page: 0, pageCount: 1, total: 0 }, response: new Response() })
  try {
    renderPage(<NewsroomPage />, undefined, undefined, '/newsroom?section=bulletins')
    expect(await screen.findByRole('heading', { name: 'مكتبة الموجز' })).toBeVisible()
    expect(screen.getByRole('button', { name: 'التقاط صورة من البث' })).toBeEnabled()
  } finally { get.mockRestore() }
})

function urgentSnapshot(): BridgeStatus {
  return { ...emptySnapshot(Date.now() - 1000), layers: [
    { layer: 7, key: 'Urgent', name: 'العاجل', at: Date.now() - 3000, hideAt: 0, source: 'telegram', by: '' },
  ] }
}

it('keeps urgent control at the top of the newsroom when the table cannot load', async () => {
  const get = vi.spyOn(api, 'GET').mockImplementation(async path => {
    if (path === '/api/content/urgent/playback') return {
      data: { run: { id: 'run', state: 'playing', step: 0, stepCount: 2, current: 'العاجل الحالي', next: 'عنوان العاجل القادم' }, preview: null },
      response: new Response(),
    }
    return { error: { code: 'bridge_unavailable' }, response: new Response(null, { status: 503 }) }
  })
  try {
    renderPage(<LiveStatusContext.Provider value={{ stream: 'live', bridgeOnline: true, status: urgentSnapshot() }}>
      <NewsroomPage />
    </LiveStatusContext.Provider>)
    const stop = await screen.findByRole('button', { name: 'إيقاف الدورة وإخفاء العاجل' })
    expect(stop).toBeEnabled()
    expect(screen.getByRole('button', { name: 'إيقاف مؤقت' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'العاجل التالي' })).toBeEnabled()
    const banner = screen.getByRole('region', { name: 'العاجل المعروض' })
    expect(within(banner).getByText('العاجل الحالي')).toBeVisible()
    expect(within(banner).getByText('عنوان العاجل القادم')).toBeVisible()
    expect(within(banner).getByRole('button', { name: 'التقاط صورة من البث' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'إخفاء العاجل المعروض' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'خروج المعروض (EXIT)' })).toBeEnabled()
    const search = screen.getByRole('searchbox', { name: 'بحث في العواجل' })
    expect(stop.compareDocumentPosition(search) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  } finally { get.mockRestore() }
})

it('captures a photo from the urgent desk and provides its authenticated download', async () => {
  const get = vi.spyOn(api, 'GET').mockResolvedValue({ data: {}, response: new Response() })
  const post = vi.spyOn(api, 'POST').mockResolvedValue({
    data: { id: 'urgent-photo', state: 'ready', kind: 'photo', source: 'main', completedAt: Date.now(), expiresAt: Date.now() + 60_000 },
    response: new Response(),
  })
  try {
    renderPage(<UrgentAirBanner items={[]} />)
    fireEvent.click(screen.getByRole('button', { name: 'التقاط صورة من البث' }))
    expect(await screen.findByRole('img', { name: 'صورة ملتقطة من خرج القناة' })).toBeVisible()
    expect(post).toHaveBeenCalledWith('/api/live/captures', { body: { kind: 'photo' } })
    expect(screen.getByRole('link', { name: 'تنزيل الصورة' })).toHaveAttribute('href', '/api/live/captures/urgent-photo/file')
  } finally { post.mockRestore(); get.mockRestore() }
})

it('shows the last urgent text in the newsroom without a saved row or a manual control', async () => {
  const get = vi.spyOn(api, 'GET').mockImplementation(async path => ({
    data: path === '/api/air/templates/{key}/presets' ? { lastValues: { strap: 'عاجل من مشغّل آخر' } } : { live: null },
    response: new Response(),
  }))
  try {
    renderPage(<UrgentAirBanner items={[]} />)
    expect(await screen.findByText('عاجل من مشغّل آخر')).toBeVisible()
    expect(screen.queryByRole('button', { name: 'إخفاء العاجل المعروض' })).not.toBeInTheDocument()
  } finally { get.mockRestore() }
})

it('keeps both reviewed controls on the urgent banner for a single manual row outside the current page', async () => {
  const get = vi.spyOn(api, 'GET').mockResolvedValue({ data: { live: { layer: 7, itemId: 'other-page', review: 'manual' } }, response: new Response() })
  try {
    renderPage(<LiveStatusContext.Provider value={{ stream: 'live', bridgeOnline: true, status: urgentSnapshot() }}>
      <UrgentAirBanner items={[]} />
    </LiveStatusContext.Provider>)
    const banner = screen.getByRole('region', { name: 'العاجل المعروض' })
    expect(await within(banner).findByText(/عرض يدوي/)).toBeVisible()
    expect(within(banner).getByRole('button', { name: 'إخفاء العاجل المعروض' })).toBeEnabled()
    expect(within(banner).getByRole('button', { name: 'خروج المعروض (EXIT)' })).toBeEnabled()
  } finally { get.mockRestore() }
})

it.each([true, false])('opens tracked layer actions with a stale reading and bridgeOnline=%s', (bridgeOnline) => {
  renderPage(
    <LiveStatusContext.Provider value={{ stream: 'live', bridgeOnline, status: urgentSnapshot() }}>
      <StatusPage />
    </LiveStatusContext.Provider>,
  )
  expect(screen.getByText('قراءة غير مؤكَّدة')).toBeVisible()
  expect(screen.getByRole('button', { name: 'إخفاء' })).toBeEnabled()
})

it.each([['Urgent', true], ['Bulletin', false]])('reviews urgent removal without a manual token when Cinegy reports %s', async (templateKey, matches) => {
  const post = vi.spyOn(api, 'POST').mockResolvedValue({ data: { preview: {
    layer: 7, templateKey, operation: 'hide', review: 'test', expiresAt: Date.now() + 60_000,
  } }, response: new Response() })
  const get = vi.spyOn(api, 'GET').mockResolvedValue({ data: { live: null }, response: new Response() })
  try {
    renderPage(
      <LiveStatusContext.Provider value={{ stream: 'live', bridgeOnline: true, status: urgentSnapshot() }}>
        <UrgentTable board={{ items: [{ id: 'row-1', title: 'خبر', state: 'ready', enabled: true, rows: null,
          values: { Text: 'خبر' }, position: 1 }], page: 0, pageCount: 1, total: 1, collectionTotal: 1, revision: 1,
          fields: [{ name: 'Text', label: 'الخبر', required: true, sensitive: false, maxLength: 200 }] }}
          filtered={false} searchPending={false} selected={[]} onToggle={() => {}} onClear={() => {}}
          onSaved={async () => {}} onEditingChange={() => {}} />
      </LiveStatusContext.Provider>,
    )
    const row = screen.getByText('خبر').closest('tr')!
    expect(within(row).getByRole('button', { name: 'خروج المعروض (EXIT)' })).toBeEnabled()
    fireEvent.click(within(row).getByRole('button', { name: 'إخفاء العاجل المعروض' }))
    const dialog = screen.getByRole('dialog')
    if (matches) {
      await waitFor(() => expect(within(dialog).getByRole('button', { name: 'تأكيد الإخفاء' })).toBeEnabled())
    } else {
      expect(await within(dialog).findByRole('alert')).toHaveTextContent('تغيّر المشهد')
      expect(within(dialog).queryByRole('button', { name: 'تأكيد الإخفاء' })).not.toBeInTheDocument()
    }
    expect(post).toHaveBeenCalledTimes(1)
    expect(post).toHaveBeenCalledWith('/api/air/layers/{layer}/removal', expect.objectContaining({
      body: { action: 'preview', operation: 'hide', review: null },
    }))
  } finally {
    post.mockRestore()
    get.mockRestore()
  }
})

it('distinguishes an expired empty snapshot from a confirmed empty snapshot', () => {
  const now = Date.now()
  const page = (freshUntil: number) => (
    <LiveStatusContext.Provider value={{ stream: 'live', bridgeOnline: true, status: emptySnapshot(freshUntil) }}>
      <StatusPage />
    </LiveStatusContext.Provider>
  )
  const { unmount } = renderPage(page(now - 1000))
  expect(screen.getByText('حالة الطبقات غير مؤكَّدة')).toBeVisible()
  fireEvent.change(screen.getByLabelText('رقم الطبقة'), { target: { value: '7' } })
  expect(screen.getByRole('button', { name: 'مراجعة خروج المشهد (EXIT)' })).toBeEnabled()
  expect(screen.queryByText('لا شيء على الهواء')).not.toBeInTheDocument()
  unmount()

  renderPage(page(now + 60_000))
  expect(screen.getByText('لا شيء على الهواء')).toBeVisible()
})

it('copies the cached summary while keeping offline broadcast actions disabled', async () => {
  const user = userEvent.setup()
  renderPage(
    <LiveStatusContext.Provider value={{ stream: 'live', bridgeOnline: false, status: emptySnapshot(Date.now() + 60_000) }}>
      <StatusPage />
    </LiveStatusContext.Provider>,
  )
  await user.click(screen.getByRole('button', { name: 'إجراءات الهواء' }))
  for (const name of ['صيانة البث', 'نطاق إخفاء الكل', 'إخفاء الطوارئ']) {
    expect(screen.getByRole('menuitem', { name })).toBeDisabled()
  }
  await user.click(screen.getByRole('menuitem', { name: 'نسخ ملخّص حالة الهواء' }))
  await waitFor(async () => expect(await navigator.clipboard.readText()).toContain('حالة الطبقات غير مؤكَّدة'))
})

it('copies the same viewing link supplied to the live player', async () => {
  const user = userEvent.setup()
  const url = 'https://media.example.test/live/channel.m3u8'
  const watch = vi.fn()
  renderPage(<LivePage active watching={false} onWatchingChange={watch} />, undefined, { url })
  await user.click(screen.getByRole('button', { name: 'نسخ رابط البث' }))
  await waitFor(async () => expect(await navigator.clipboard.readText()).toBe(url))
  await user.click(screen.getByRole('button', { name: 'مشاهدة البث' }))
  expect(watch).toHaveBeenCalledWith(true)
})

it('lets the operator retry a failed template load without leaving scheduling', async () => {
  vi.mocked(getTemplates).mockRejectedValueOnce(new Error('bridge_unavailable')).mockResolvedValueOnce([
    { key: 'example', name: 'قالب تجريبي', layer: 1, category: null, disabled: false, fields: [] },
  ])
  renderPage(<TemplateSchedulePage />, {
    items: [], page: 0, pageCount: 1, total: 0, stationTimeZone: 'UTC', stationOffsetMinutes: 0,
    stationTime: '2026-11-22 12:00', clockValid: true, paused: false, materialsEnabled: false,
  })

  fireEvent.click(screen.getByRole('button', { name: 'إضافة موعد' }))
  const dialog = screen.getByRole('dialog')
  const retry = await within(dialog).findByRole('button', { name: 'إعادة تحميل القوالب' })
  expect(within(dialog).getByRole('alert')).toHaveTextContent('تعذّر تحميل القوالب')
  expect(within(dialog).getByRole('button', { name: 'مراجعة الموعد' })).toBeDisabled()
  fireEvent.click(retry)
  const picker = await within(dialog).findByRole('combobox', { name: 'القالب' })
  expect(picker).toBeEnabled()
  fireEvent.click(picker)
  expect(await screen.findByRole('option', { name: 'قالب تجريبي · example' })).toBeVisible()
  expect(getTemplates).toHaveBeenCalledTimes(2)
})
