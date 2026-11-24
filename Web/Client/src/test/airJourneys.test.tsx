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
import { UrgentTable } from '../pages/newsroom/UrgentTable'
import { TemplateSchedulePage } from '../pages/schedule/TemplateSchedulePage'
import { StatusPage } from '../pages/status/StatusPage'
import { ShowModal } from '../pages/templates/ShowModal'

vi.mock('../api/air', () => ({ getTemplates: vi.fn() }))

function renderPage(page: ReactNode, schedule?: Schemas['TemplateSchedulePage'], playback?: { url: string | null }) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  queryClient.setQueryData(sessionKey, { id: 1, name: 'مشغّل تجريبي', role: 'admin', method: 'test', webOnly: true })
  if (schedule) queryClient.setQueryData(['template-schedule', 0], schedule)
  if (playback) queryClient.setQueryData(['live-playback'], playback)
  return render(
    <MantineProvider env="test">
      <QueryClientProvider client={queryClient}>
        <MemoryRouter>{page}</MemoryRouter>
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

function urgentSnapshot(): BridgeStatus {
  return { ...emptySnapshot(Date.now() - 1000), layers: [
    { layer: 7, key: 'Urgent', name: 'العاجل', at: Date.now() - 3000, hideAt: 0, source: 'telegram', by: '' },
  ] }
}

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
