import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { expect, it, vi } from 'vitest'
import { uploadTickerTxt, type Schemas } from '../../api/client'
import { TickerTxt } from './TickerTxt'

vi.mock('../../api/client', () => ({ uploadTickerTxt: vi.fn() }))

it('retries a failed draft refresh without uploading the saved file again', async () => {
  const draft: NonNullable<Schemas['TickerDraft']> = {
    revision: 'draft-1',
    items: ['خبر سابق'],
    scheduledAt: null,
    canRemove: true,
    maxItems: 10,
    paused: { items: [], page: 1, pageCount: 1, total: 0, offset: 0 },
    canClear: true,
    sharedDraftKey: null,
    rowKeys: null,
    canManage: null,
  }
  vi.mocked(uploadTickerTxt).mockResolvedValueOnce({
    review: 'review-1',
    items: ['خبر جديد'],
    currentItems: draft.items,
    duplicates: 0,
    identical: false,
    cancelsSchedule: false,
  }).mockResolvedValueOnce(null)
  let failRefresh!: (error: Error) => void
  const refresh = new Promise<void>((_resolve, reject) => { failRefresh = reject })
  const onRefresh = vi.fn<() => Promise<void>>().mockReturnValueOnce(refresh).mockResolvedValueOnce(undefined)
  const onClose = vi.fn()
  const queryClient = new QueryClient()
  render(
    <MantineProvider env="test">
      <QueryClientProvider client={queryClient}>
        <TickerTxt draft={draft} onClose={onClose} onRefresh={onRefresh} />
      </QueryClientProvider>
    </MantineProvider>,
  )
  const input = document.querySelector('input[type="file"]')!
  fireEvent.change(input, { target: { files: [new File(['خبر جديد'], 'news.txt', { type: 'text/plain' })] } })
  fireEvent.click(screen.getByRole('button', { name: 'معاينة الملف' }))
  const replace = await screen.findByRole('button', { name: 'استبدال أخبار المسودة' })
  fireEvent.click(replace)
  await waitFor(() => expect(onRefresh).toHaveBeenCalledTimes(1))
  expect(onClose).not.toHaveBeenCalled()
  expect(await screen.findByRole('status')).toHaveTextContent('جارٍ تحميل المسودة المحدّثة')
  await act(async () => { failRefresh(new Error('bridge_unavailable')) })
  const retry = await screen.findByRole('button', { name: 'إعادة تحميل المسودة' })
  expect(onClose).not.toHaveBeenCalled()
  expect(screen.queryByRole('button', { name: 'استبدال أخبار المسودة' })).not.toBeInTheDocument()
  fireEvent.click(retry)
  await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
  expect(onRefresh).toHaveBeenCalledTimes(2)
  expect(uploadTickerTxt).toHaveBeenCalledTimes(2)
})
