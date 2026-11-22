import { MantineProvider } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { ReactNode } from 'react'
import { beforeEach, expect, it, vi } from 'vitest'
import { api, type CurrentUser } from '../../api/client'
import { sessionKey } from '../../api/session'
import { UserMenu } from '../../layout/UserMenu'
import { AccountsPage } from './AccountsPage'

const navigate = vi.hoisted(() => vi.fn())
vi.mock('react-router', () => ({ useNavigate: () => navigate }))
vi.mock('@mantine/notifications', () => ({ notifications: { show: vi.fn() } }))
vi.mock('../../api/client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../api/client')>(),
  api: { GET: vi.fn(), POST: vi.fn(), PUT: vi.fn() },
}))

const user: CurrentUser = { id: 1, name: 'مشرف الوردية', role: 'owner', method: 'password', webOnly: true }

function renderAuthenticated(element: ReactNode) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(sessionKey, user)
  render(
    <MantineProvider env="test">
      <QueryClientProvider client={client}>{element}</QueryClientProvider>
    </MantineProvider>,
  )
  return client
}

beforeEach(() => vi.resetAllMocks())

it('keeps the session after a failed sign-out and allows the operator to retry', async () => {
  vi.mocked(api.POST).mockResolvedValueOnce({ error: { error: 'unknown' }, response: new Response(null, { status: 500 }) })
    .mockRejectedValueOnce(new TypeError('Failed to fetch'))
    .mockResolvedValueOnce({ data: undefined, response: new Response(null, { status: 401 }) })
  const client = renderAuthenticated(<UserMenu user={user} />)

  async function signOut() {
    fireEvent.click(screen.getByRole('button', { name: 'حسابي' }))
    fireEvent.click(await screen.findByRole('menuitem', { name: 'تسجيل الخروج' }))
  }

  await signOut()
  await waitFor(() => expect(notifications.show).toHaveBeenCalledWith(expect.objectContaining({ color: 'red' })))
  expect(client.getQueryData(sessionKey)).toEqual(user)
  expect(navigate).not.toHaveBeenCalled()

  await signOut()
  await waitFor(() => expect(notifications.show).toHaveBeenCalledTimes(2))
  expect(client.getQueryData(sessionKey)).toEqual(user)

  await signOut()
  await waitFor(() => expect(navigate).toHaveBeenCalledWith('/login', { replace: true }))
  expect(client.getQueryData(sessionKey)).toBeUndefined()
})

it('refreshes a locked account after its password is reset', async () => {
  const account = {
    username: 'editor', userId: 2, displayName: 'محرر الأخبار', webOnly: true, role: 'operator',
    createdAt: '2026-01-01T00:00:00Z', lastLoginAt: null, lockedUntil: '2099-01-01T00:00:00Z',
  }
  vi.mocked(api.GET).mockResolvedValueOnce({ data: { accounts: [account], bridgeUsers: [] }, response: new Response() })
    .mockResolvedValueOnce({ data: { accounts: [{ ...account, lockedUntil: null }], bridgeUsers: [] }, response: new Response() })
  vi.mocked(api.PUT).mockRejectedValueOnce(new TypeError('Failed to fetch'))
    .mockResolvedValueOnce({ data: undefined, response: new Response(null, { status: 204 }) })
  renderAuthenticated(<AccountsPage />)

  await screen.findByText('محرر الأخبار')
  expect(screen.getByText('مقفل')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'إجراءات محرر الأخبار' }))
  fireEvent.click(await screen.findByRole('menuitem', { name: 'كلمة مرور جديدة' }))
  fireEvent.change(await screen.findByLabelText(/كلمة المرور الجديدة/), { target: { value: 'long-password' } })
  fireEvent.click(screen.getByRole('button', { name: 'حفظ' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('تعذّر الاتصال بالخادم')
  expect(screen.getByText('مقفل')).toBeInTheDocument()

  fireEvent.click(screen.getByRole('button', { name: 'حفظ' }))

  await waitFor(() => expect(screen.queryByText('مقفل')).not.toBeInTheDocument())
  expect(api.GET).toHaveBeenCalledTimes(2)
})
