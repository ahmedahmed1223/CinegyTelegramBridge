import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ReactNode } from 'react'
import { MemoryRouter } from 'react-router'
import { expect, it, vi } from 'vitest'
import { getTemplates } from '../api/air'
import type { BridgeStatus, Schemas } from '../api/client'
import { sessionKey } from '../api/session'
import { LiveStatusContext } from '../layout/LiveStatusContext'
import { TemplateSchedulePage } from '../pages/schedule/TemplateSchedulePage'
import { StatusPage } from '../pages/status/StatusPage'

vi.mock('../api/air', () => ({ getTemplates: vi.fn() }))

function renderPage(page: ReactNode, schedule?: Schemas['TemplateSchedulePage']) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  queryClient.setQueryData(sessionKey, { id: 1, name: 'مشغّل تجريبي', role: 'admin', method: 'test', webOnly: true })
  if (schedule) queryClient.setQueryData(['template-schedule', 0], schedule)
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
    cinegy: { address: 'local', channel: 0, health: 'healthy', freshUntil, lastReadAt: Date.now() },
    telegram: { state: 'connected', failures: 0 },
  }
}

it('distinguishes an expired empty snapshot from a confirmed empty snapshot', () => {
  const now = Date.now()
  const page = (freshUntil: number) => (
    <LiveStatusContext.Provider value={{ stream: 'live', bridgeOnline: true, status: emptySnapshot(freshUntil) }}>
      <StatusPage />
    </LiveStatusContext.Provider>
  )
  const { unmount } = renderPage(page(now - 1000))
  expect(screen.getByText('حالة الطبقات غير مؤكَّدة')).toBeVisible()
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
