import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { api } from '../../api/client'
import { TickerEditor } from './TickerEditor'

if (!document.fonts) Object.defineProperty(document, 'fonts', { value: new EventTarget() })
afterEach(() => vi.restoreAllMocks())

const queryKey = ['ticker-draft', 1]
const response = new Response(null, { status: 200 })
const draft = {
  revision: 'original-revision', sharedDraftKey: 'shared-draft', canManage: false,
  items: ['عنوان أول', 'عنوان ثانٍ'], rowKeys: ['first-row', 'second-row'],
  maxItems: 20, scheduledAt: null, canRemove: true, canClear: true,
}
const editor = { state: 'editing', draft, owner: 'مشرف الشريط' }

function openEditor() {
  const client = new QueryClient()
  vi.spyOn(api, 'GET').mockResolvedValue({ data: editor, response })
  render(
    <MantineProvider env="test">
      <QueryClientProvider client={client}>
        <TickerEditor onPublished={async () => {}} />
      </QueryClientProvider>
    </MantineProvider>,
  )
  return client
}

it('lets a contributor edit the same headline after it moves and hides management actions', async () => {
  const client = openEditor()
  const post = vi.spyOn(api, 'POST').mockResolvedValue({ data: editor, response })
  expect(await screen.findByText(/المشرف على المسودة: مشرف الشريط/)).toBeVisible()
  expect(screen.queryByRole('button', { name: 'مراجعة النشر' })).toBeNull()
  expect(screen.queryByRole('button', { name: 'حذف الخبر 1' })).toBeNull()
  expect(screen.queryByRole('button', { name: 'مجموعات الشريط' })).toBeNull()

  fireEvent.click(screen.getByRole('button', { name: 'تعديل الخبر 1' }))
  const input = screen.getByRole('textbox', { name: 'نص الخبر' })
  fireEvent.change(input, { target: { value: 'نصي بعد النقل' } })
  await act(async () => client.setQueryData(queryKey, {
    ...editor, draft: { ...draft, revision: 'reordered', items: ['عنوان ثانٍ', 'عنوان أول'], rowKeys: ['second-row', 'first-row'] },
  }))
  await waitFor(() => expect(screen.getByText('عنوان أول').closest('li')).toHaveAttribute('value', '2'))
  expect(input).toHaveValue('نصي بعد النقل')
  fireEvent.click(screen.getByRole('button', { name: 'حفظ الخبر' }))
  await screen.findByText('حُفظ الخبر في المسودة.')
  expect(post).toHaveBeenCalledWith('/api/content/ticker/draft', expect.objectContaining({
    body: expect.objectContaining({ action: 'update', index: 1, review: 'first-row', revision: 'original-revision', text: 'نصي بعد النقل' }),
  }))
})

it('keeps my text and requires a decision after another editor changes the same headline', async () => {
  openEditor()
  const post = vi.spyOn(api, 'POST')
    .mockResolvedValueOnce({ error: { error: 'ticker_stale' }, response: new Response(null, { status: 409 }) })
    .mockResolvedValueOnce({ data: editor, response })
  fireEvent.click(await screen.findByRole('button', { name: 'تعديل الخبر 1' }))
  const input = screen.getByRole('textbox', { name: 'نص الخبر' })
  fireEvent.change(input, { target: { value: 'النص الذي أكتبُه' } })
  vi.mocked(api.GET).mockResolvedValue({
    data: { ...editor, draft: { ...draft, revision: 'edited', items: ['نص زميلي', ...draft.items.slice(1)], rowKeys: ['revised-row', 'second-row'] } },
    response,
  })
  fireEvent.click(screen.getByRole('button', { name: 'حفظ الخبر' }))
  expect(await screen.findByText('تغيّر الخبر أثناء تحريره')).toBeVisible()
  expect(screen.getByText('الخبر قبل التعديل: عنوان أول')).toBeVisible()
  expect(input).toHaveValue('النص الذي أكتبُه')
  expect(screen.getByRole('button', { name: 'حفظ الخبر' })).toBeDisabled()
  fireEvent.click(screen.getByRole('button', { name: 'اختيار الخبر من القائمة' }))
  fireEvent.click(screen.getByRole('button', { name: 'اختيار الخبر 1 لهذا التعديل' }))
  expect(input).toHaveValue('النص الذي أكتبُه')
  fireEvent.click(screen.getByRole('button', { name: 'حفظ الخبر' }))
  await screen.findByText('حُفظ الخبر في المسودة.')
  expect(post).toHaveBeenNthCalledWith(2, '/api/content/ticker/draft', expect.objectContaining({
    body: expect.objectContaining({ action: 'update', index: 0, review: 'revised-row', revision: 'edited', text: 'النص الذي أكتبُه' }),
  }))
})

it('appends to the same shared draft while other editors add headlines', async () => {
  const client = openEditor()
  const post = vi.spyOn(api, 'POST').mockResolvedValue({ data: editor, response })
  fireEvent.click(await screen.findByRole('button', { name: 'إضافة خبر' }))
  const input = screen.getByRole('textbox', { name: 'الخبر الجديد' })
  fireEvent.change(input, { target: { value: 'العنوان الجديد' } })
  await act(async () => client.setQueryData(queryKey, {
    ...editor, draft: { ...draft, revision: 'added', items: [...draft.items, 'عنوان زميل'], rowKeys: [...draft.rowKeys, 'third-row'] },
  }))
  await screen.findByText('عنوان زميل')
  expect(input).toHaveValue('العنوان الجديد')
  fireEvent.click(screen.getByRole('button', { name: 'حفظ الخبر' }))
  await screen.findByText('حُفظ الخبر في المسودة.')
  expect(post).toHaveBeenCalledWith('/api/content/ticker/draft', expect.objectContaining({
    body: expect.objectContaining({ action: 'add', index: null, review: 'shared-draft', revision: 'original-revision', text: 'العنوان الجديد' }),
  }))
})

it('keeps a contributor’s unsaved text readable while the owner has scheduled publication', async () => {
  const client = openEditor()
  fireEvent.click(await screen.findByRole('button', { name: 'إضافة خبر' }))
  const input = screen.getByRole('textbox', { name: 'الخبر الجديد' })
  fireEvent.change(input, { target: { value: 'عنوان قبل الجدولة' } })
  await act(async () => client.setQueryData(queryKey, {
    ...editor, draft: { ...draft, revision: 'scheduled', scheduledAt: '2099-01-01T12:00:00Z' },
  }))
  expect(await screen.findByText(/هذه المسودة مجدولة للنشر/)).toBeVisible()
  expect(input).toHaveValue('عنوان قبل الجدولة')
  expect(input).toHaveAttribute('readonly')
  expect(screen.getByRole('button', { name: 'حفظ الخبر' })).toBeDisabled()
  expect(screen.getByRole('button', { name: 'تعديل الخبر 1' })).toBeDisabled()
  await act(async () => client.setQueryData(queryKey, {
    ...editor, draft: { ...draft, revision: 'unscheduled' },
  }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'حفظ الخبر' })).toBeEnabled())
  expect(input).not.toHaveAttribute('readonly')
  expect(input).toHaveValue('عنوان قبل الجدولة')
})
