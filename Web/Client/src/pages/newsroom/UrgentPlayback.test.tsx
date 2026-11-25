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
    review: 'synthetic-review', totalSeconds: 18, itemCount: 1, stepCount: 2, layer: 5,
    replacesGraphic: false, graphicName: '', notes: [], headlines: ['العاجل المختار'],
    steps: [
      { text: 'العاجل المختار', startSeconds: 0, holdSeconds: 9 },
      { text: 'العاجل المختار', startSeconds: 9, holdSeconds: 9 },
    ],
  }
  vi.mocked(api.GET).mockResolvedValue({ data: { run: null, preview: null }, response })
  vi.mocked(api.POST).mockResolvedValue({ data: { preview, run: null }, response })
  const client = new QueryClient()
  const onStarted = vi.fn()
  render(
    <MantineProvider env="test">
      <QueryClientProvider client={client}><UrgentPlayback selected={['row-2']} onStarted={onStarted} /></QueryClientProvider>
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
  const selected = await screen.findByRole('dialog', { name: 'مراجعة تشغيل المحدد' })
  const headlines = within(selected).getByRole('list', { name: 'عناوين المعاينة' })
  expect(within(headlines).getAllByRole('listitem')).toHaveLength(1)
  const timing = within(selected).getByText(/التوقيت والتكرار/)
  expect(timing.closest('details')).not.toHaveAttribute('open')
  expect(api.POST).toHaveBeenNthCalledWith(2, '/api/content/urgent/playback', expect.objectContaining({
    body: expect.objectContaining({ action: 'preview-selected', selectedIds: ['row-2'], mode: 'auto_hide' }),
  }))
  expect(api.POST).toHaveBeenCalledTimes(2)
  expect(onStarted).not.toHaveBeenCalled()
  vi.mocked(api.POST).mockResolvedValueOnce({ data: { run: { id: 'run' } }, response })
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'تشغيل على الهواء' }))
  await vi.waitFor(() => expect(onStarted).toHaveBeenCalledWith(['row-2']))
  expect(api.POST).toHaveBeenNthCalledWith(3, '/api/content/urgent/playback', expect.objectContaining({
    body: expect.objectContaining({ action: 'start-selected', selectedIds: ['row-2'], review: preview.review }),
  }))
})
