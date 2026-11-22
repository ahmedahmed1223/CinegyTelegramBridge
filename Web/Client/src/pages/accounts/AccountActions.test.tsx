import { MantineProvider } from '@mantine/core'
import { ModalsProvider } from '@mantine/modals'
import { notifications } from '@mantine/notifications'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
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
  api: { GET: vi.fn(), POST: vi.fn(), PUT: vi.fn(), DELETE: vi.fn() },
}))

const user: CurrentUser = { id: 1, name: 'مشرف الوردية', role: 'owner', method: 'password', webOnly: true }

function renderAuthenticated(element: ReactNode) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(sessionKey, user)
  render(
    <MantineProvider env="test">
      <QueryClientProvider client={client}><ModalsProvider>{element}</ModalsProvider></QueryClientProvider>
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

it('recovers the account list and resolves actions against the account found after filtering', async () => {
  const operator = { username: 'editor-news', userId: 2, displayName: 'مُحرّر الأخبار', webOnly: true, role: 'operator',
    createdAt: '2026-01-01T00:00:00Z', lastLoginAt: null, lockedUntil: null }
  const admin = { ...operator, username: 'desk-admin', userId: 3, displayName: 'مشرف التحرير', role: 'admin' }
  vi.mocked(api.GET).mockRejectedValueOnce(new TypeError('Failed to fetch'))
    .mockResolvedValue({ data: { accounts: [operator, admin], bridgeUsers: [] }, response: new Response() })
  renderAuthenticated(<AccountsPage />)

  fireEvent.click(await screen.findByRole('button', { name: 'إعادة المحاولة' }))
  await screen.findByText(operator.displayName)
  const search = screen.getByRole('searchbox', { name: 'بحث في الحسابات' })
  fireEvent.change(search, { target: { value: 'desk-admin' } })
  expect(screen.queryByText(operator.displayName)).not.toBeInTheDocument()
  expect(screen.getByText(admin.displayName)).toBeInTheDocument()
  fireEvent.change(search, { target: { value: 'محرر' } })
  expect(screen.queryByText(admin.displayName)).not.toBeInTheDocument()
  fireEvent.change(screen.getByRole('combobox', { name: 'الدور' }), { target: { value: 'admin' } })
  expect(screen.getByText('لا توجد حسابات تطابق البحث والتصفية.')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'مسح البحث والتصفية' }))
  fireEvent.change(screen.getByRole('combobox', { name: 'الدور' }), { target: { value: 'operator' } })
  fireEvent.click(screen.getByRole('button', { name: `إجراءات ${operator.displayName}` }))
  fireEvent.click(await screen.findByRole('menuitem', { name: 'كلمة مرور جديدة' }))
  const dialog = await screen.findByRole('dialog')
  expect(within(dialog).getByText(/editor-news/)).toBeInTheDocument()
})

it('keeps the account visible and asks for a refresh when a deletion cannot be confirmed', async () => {
  const account = { username: 'desk-editor', userId: 2, displayName: 'محرر الوردية', webOnly: false, role: 'operator',
    createdAt: '2026-01-01T00:00:00Z', lastLoginAt: null, lockedUntil: null }
  vi.mocked(api.GET).mockResolvedValueOnce({ data: { accounts: [account], bridgeUsers: [] }, response: new Response() })
    .mockResolvedValueOnce({ data: { accounts: [], bridgeUsers: [] }, response: new Response() })
  vi.mocked(api.DELETE).mockRejectedValueOnce(new TypeError('Failed to fetch'))
  renderAuthenticated(<AccountsPage />)

  fireEvent.click(await screen.findByRole('button', { name: `إجراءات ${account.displayName}` }))
  fireEvent.click(await screen.findByRole('menuitem', { name: 'حذف' }))
  const dialog = await screen.findByRole('dialog', { name: 'حذف حساب الويب' })
  expect(within(dialog).getByText(account.username)).toBeInTheDocument()
  fireEvent.click(within(dialog).getByRole('button', { name: 'حذف' }))
  await waitFor(() => expect(notifications.show).toHaveBeenCalledWith(expect.objectContaining({
    color: 'red', message: expect.stringContaining('تعذّر تأكيد الحذف'),
  })))
  expect(screen.getByText(account.displayName)).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'تحديث' }))
  expect(await screen.findByText('لا حسابات بكلمة مرور بعد')).toBeInTheDocument()
})
