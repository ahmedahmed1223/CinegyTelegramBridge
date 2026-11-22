import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen } from '@testing-library/react'
import { expect, it, vi } from 'vitest'
import { api } from '../../api/client'
import { NewsroomPage } from './NewsroomPage'

// Mantine's autosizing textarea listens for font changes.
if (!document.fonts) Object.defineProperty(document, 'fonts', { value: new EventTarget() })

it('keeps an unsaved ticker headline when switching newsroom tabs', async () => {
  const get = vi.spyOn(api, 'GET').mockImplementation(async (path) => {
    const content = { items: [], fields: [], page: 0, pageCount: 1, total: 0 }
    const data = path === '/api/content/ticker/draft' ? {
      state: 'mine',
      draft: {
        revision: 'draft-1', items: [], maxItems: 10, scheduledAt: null,
        paused: { items: [], page: 1, pageCount: 1, total: 0, offset: 0 },
      },
    } : content
    return { data, response: new Response(null, { status: 200 }) }
  })
  const client = new QueryClient()
  try {
    render(
      <MantineProvider>
        <QueryClientProvider client={client}>
          <NewsroomPage />
        </QueryClientProvider>
      </MantineProvider>,
    )
    fireEvent.click(screen.getByRole('tab', { name: 'الشريط' }))
    fireEvent.click(await screen.findByRole('button', { name: 'إضافة خبر' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'الخبر الجديد' }), {
      target: { value: 'عنوان خبر قيد التحرير' },
    })

    fireEvent.click(screen.getByRole('tab', { name: 'الموجز' }))
    expect(screen.queryByRole('textbox', { name: 'الخبر الجديد' })).toBeNull()
    expect(client.getQueryCache().find({ queryKey: ['ticker-draft', 1] })?.getObserversCount()).toBe(0)
    fireEvent.click(screen.getByRole('tab', { name: 'الشريط' }))
    expect(await screen.findByRole('textbox', { name: 'الخبر الجديد' })).toHaveValue('عنوان خبر قيد التحرير')
  } finally {
    get.mockRestore()
  }
})
