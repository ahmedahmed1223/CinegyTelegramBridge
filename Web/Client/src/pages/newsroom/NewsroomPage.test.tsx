import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, within } from '@testing-library/react'
import { Link, MemoryRouter } from 'react-router'
import { expect, it, vi } from 'vitest'
import { api } from '../../api/client'
import { NewsroomPage } from './NewsroomPage'
import { ProgrammeBoards } from './ProgrammeBoards'

// Mantine's autosizing textarea listens for font changes.
if (!document.fonts) Object.defineProperty(document, 'fonts', { value: new EventTarget() })

it('keeps an unsaved ticker headline opened by a deep link when an urgent notice opens the urgent tab', async () => {
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
          <MemoryRouter initialEntries={['/newsroom?section=ticker']}>
            <Link to="/newsroom?section=urgent">فتح جدول العواجل</Link>
            <NewsroomPage />
          </MemoryRouter>
        </QueryClientProvider>
      </MantineProvider>,
    )
    expect(screen.getByRole('tab', { name: 'الشريط' })).toHaveAttribute('aria-selected', 'true')
    fireEvent.click(await screen.findByRole('button', { name: 'إضافة خبر' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'الخبر الجديد' }), {
      target: { value: 'عنوان خبر قيد التحرير' },
    })

    fireEvent.click(screen.getByRole('link', { name: 'فتح جدول العواجل' }))
    expect(screen.getByRole('tab', { name: 'العواجل' })).toHaveAttribute('aria-selected', 'true')
    expect(screen.queryByRole('textbox', { name: 'الخبر الجديد' })).toBeNull()
    expect(client.getQueryCache().find({ queryKey: ['ticker-draft', 1] })?.getObserversCount()).toBe(0)
    fireEvent.click(screen.getByRole('tab', { name: 'الشريط' }))
    expect(await screen.findByRole('textbox', { name: 'الخبر الجديد' })).toHaveValue('عنوان خبر قيد التحرير')
  } finally {
    get.mockRestore()
  }
})

it('opens correction for the on-air programme row even when a search hides that row', async () => {
  const liveRow = { id: 'row-1', number: 1, enabled: true, values: { title: 'عنوان الصف المعروض' } }
  const otherRow = { id: 'row-21', number: 21, enabled: true, values: { title: 'عنوان الصف الآخر' } }
  const get = vi.spyOn(api, 'GET').mockImplementation(async (path, options) => {
    const { page = 0, search } = (options?.params?.query ?? {}) as { page?: number; search?: string }
    const data = path === '/api/content/boards' ? {
      items: [{ id: 'programme-1', name: 'برنامج المساء', rows: 21 }], total: 1, page: 0, pageCount: 1, canCreate: false,
    } : {
      id: 'programme-1', name: 'برنامج المساء', revision: 3, canEdit: true, canManage: false, editRole: 'all',
      fields: [{ name: 'title', label: 'العنوان' }], sceneMedia: [], rows: [page === 0 && !search ? liveRow : otherRow],
      total: search ? 1 : 21, collectionTotal: 21, page, pageCount: search ? 1 : 2, maxFieldLength: 100, liveRowId: liveRow.id, liveRow,
    }
    return { data, response: new Response(null, { status: 200 }) }
  })
  const client = new QueryClient()
  try {
    render(
      <MantineProvider env="test">
        <QueryClientProvider client={client}>
          <ProgrammeBoards />
        </QueryClientProvider>
      </MantineProvider>,
    )
    fireEvent.click(await screen.findByRole('button', { name: 'فتح لوحة برنامج المساء' }))
    await screen.findByText(liveRow.values.title)
    fireEvent.change(screen.getByRole('searchbox', { name: 'بحث في صفوف اللوحة' }), { target: { value: 'الآخر' } })
    await screen.findByText(otherRow.values.title)
    expect(screen.queryByText(liveRow.values.title)).toBeNull()
    fireEvent.click(await screen.findByRole('button', { name: 'تصحيح على الهواء' }))
    const dialog = await screen.findByRole('dialog', { name: 'تصحيح نص العرض الحالي' })
    fireEvent.click(within(dialog).getByRole('checkbox', { name: 'العنوان' }))
    expect(within(dialog).getByRole('textbox', { name: 'القيمة الجديدة لـ العنوان' })).toHaveValue(liveRow.values.title)
  } finally {
    get.mockRestore()
  }
})

it('finds a ticker headline beyond the first page and edits its original position', async () => {
  const items = [...Array.from({ length: 20 }, (_, index) => `خبر ${index + 1}`), 'تقرير الاستوديو']
  const draft = { revision: 'draft-search', items, maxItems: 40, scheduledAt: null }
  const get = vi.spyOn(api, 'GET').mockImplementation(async (path) => ({
    data: path === '/api/content/ticker/draft' ? { state: 'mine', draft, maxItemLength: 120 } : {
      items: [], fields: [], page: 0, pageCount: 1, total: 0,
    },
    response: new Response(null, { status: 200 }),
  }))
  const post = vi.spyOn(api, 'POST').mockResolvedValue({
    data: { state: 'mine', draft: { ...draft, items: [...items.slice(0, 20), 'تقرير الاستوديو المباشر'] } },
    response: new Response(null, { status: 200 }),
  })
  try {
    render(
      <MantineProvider>
        <QueryClientProvider client={new QueryClient()}>
          <MemoryRouter><NewsroomPage /></MemoryRouter>
        </QueryClientProvider>
      </MantineProvider>,
    )
    fireEvent.click(screen.getByRole('tab', { name: 'الشريط' }))
    await screen.findByText('خبر 1')
    expect(screen.queryByText('تقرير الاستوديو')).toBeNull()
    fireEvent.change(screen.getByRole('searchbox', { name: 'بحث في المسودة' }), { target: { value: 'الاستوديو' } })
    fireEvent.click(await screen.findByRole('button', { name: 'تعديل الخبر 21' }))
    fireEvent.change(screen.getByRole('textbox', { name: 'نص الخبر' }), { target: { value: 'تقرير الاستوديو المباشر' } })
    fireEvent.click(screen.getByRole('button', { name: 'حفظ الخبر' }))
    expect(await screen.findByText('تقرير الاستوديو المباشر', { selector: 'p' })).toBeVisible()
    expect(post).toHaveBeenCalledWith('/api/content/ticker/draft', expect.objectContaining({
      body: expect.objectContaining({ action: 'update', index: 20, revision: 'draft-search' }),
    }))
  } finally {
    post.mockRestore()
    get.mockRestore()
  }
})
