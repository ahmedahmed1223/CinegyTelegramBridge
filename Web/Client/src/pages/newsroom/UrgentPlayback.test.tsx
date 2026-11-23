import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, within } from '@testing-library/react'
import { expect, it, vi } from 'vitest'
import { api, type Schemas } from '../../api/client'
import { UrgentPlayback } from './UrgentPlayback'

vi.mock('../../api/client', () => ({ api: { GET: vi.fn(), POST: vi.fn() } }))

it('previews all or selected rows explicitly, using the chosen session mode', async () => {
  const response = new Response(null, { status: 200 })
  const preview: Schemas['UrgentRunPreview'] = {
    review: 'synthetic-review', totalSeconds: 18, itemCount: 1, stepCount: 1, layer: 5,
    replacesGraphic: false, graphicName: '', notes: [], steps: [],
  }
  vi.mocked(api.GET).mockResolvedValue({ data: { run: null, preview: null }, response })
  vi.mocked(api.POST).mockResolvedValue({ data: { preview, run: null }, response })
  const client = new QueryClient()
  render(
    <MantineProvider env="test">
      <QueryClientProvider client={client}><UrgentPlayback selected={['row-2']} /></QueryClientProvider>
    </MantineProvider>,
  )
  await screen.findByText('لا توجد دورة نشطة.')
  fireEvent.change(screen.getByRole('combobox', { name: 'نمط هذه الدورة' }), { target: { value: 'auto_hide' } })
  fireEvent.click(screen.getByRole('button', { name: 'تشغيل الكل' }))
  const all = await screen.findByRole('dialog', { name: 'مراجعة تشغيل الكل' })
  expect(within(all).getByRole('button', { name: 'تشغيل على الهواء' })).toBeInTheDocument()
  expect(api.POST).toHaveBeenNthCalledWith(1, '/api/content/urgent/playback', expect.objectContaining({
    body: expect.objectContaining({ action: 'preview', selectedIds: [], mode: 'auto_hide' }),
  }))
  fireEvent.click(within(all).getByRole('button', { name: 'العودة' }))
  fireEvent.click(screen.getByRole('button', { name: /تشغيل المحدد/ }))
  await screen.findByRole('dialog', { name: 'مراجعة تشغيل المحدد' })
  expect(api.POST).toHaveBeenNthCalledWith(2, '/api/content/urgent/playback', expect.objectContaining({
    body: expect.objectContaining({ action: 'preview', selectedIds: ['row-2'], mode: 'auto_hide' }),
  }))
  expect(api.POST).toHaveBeenCalledTimes(2)
})
