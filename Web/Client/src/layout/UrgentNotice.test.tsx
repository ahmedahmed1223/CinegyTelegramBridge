import { MantineProvider } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, render, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { afterEach, expect, it, vi } from 'vitest'
import { api } from '../api/client'
import { UrgentNotice } from './UrgentNotice'
import { AirNotices } from './AirNotices'

vi.mock('@mantine/notifications', () => ({ notifications: { show: vi.fn() } }))
vi.mock('../api/client', () => ({ api: { GET: vi.fn() }, errorCode: vi.fn() }))

afterEach(() => {
  cleanup()
  vi.resetAllMocks()
})

it('shows successive air operations once across reloads', async () => {
  sessionStorage.clear()
  vi.mocked(api.GET).mockResolvedValue({ data: { events: [
    { id: 'one', action: 'SHOW', key: 'Urgent', layer: 7, at: 1 },
    { id: 'two', action: 'EXIT', key: 'Banner', layer: 2, at: 2 },
  ] }, response: new Response() })
  const view = () => render(<QueryClientProvider client={new QueryClient()}><AirNotices actor={123} /></QueryClientProvider>)
  const first = view()
  await waitFor(() => expect(notifications.show).toHaveBeenCalledTimes(2))
  first.unmount()
  view()
  await waitFor(() => expect(api.GET).toHaveBeenCalledTimes(2))
  expect(notifications.show).toHaveBeenCalledTimes(2)
})

it('notifies once for an actor-approved confirmed event and ignores a marker without their notice', async () => {
  vi.mocked(api.GET)
    .mockResolvedValueOnce({ data: { noticeId: 'first', noticeHeadline: 'عنوان العاجل المؤكد' }, response: new Response() })
    .mockResolvedValueOnce({ data: { noticeId: '' }, response: new Response() })
  const client = new QueryClient()
  const view = (noticeId: string | null) => <MantineProvider><QueryClientProvider client={client}><MemoryRouter>
    <UrgentNotice actor={123} noticeId={noticeId} />
  </MemoryRouter></QueryClientProvider></MantineProvider>
  const component = render(view('first'))
  await waitFor(() => expect(notifications.show).toHaveBeenCalledTimes(1))
  expect(vi.mocked(notifications.show)).toHaveBeenCalledWith(expect.objectContaining({ id: 'urgent-123:first' }))
  const shown = vi.mocked(notifications.show).mock.calls[0][0]
  const message = render(<MantineProvider>{shown.message}</MantineProvider>)
  expect(message.getByText('عنوان العاجل المؤكد')).toBeVisible()
  component.rerender(view(null))
  component.rerender(view('first'))
  component.rerender(view('second'))
  await waitFor(() => expect(api.GET).toHaveBeenCalledTimes(2))
  expect(notifications.show).toHaveBeenCalledTimes(1)
  client.clear()
})
