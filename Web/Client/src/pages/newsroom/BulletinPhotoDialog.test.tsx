import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { expect, it, vi } from 'vitest'
import { api, uploadBulletinPhoto, uploadBulletinPhotoRow, type Schemas } from '../../api/client'
import { BulletinEditor } from './BulletinEditor'
import { BulletinPhotoDialog } from './BulletinPhotoDialog'

if (!document.fonts) Object.defineProperty(document, 'fonts', { value: new EventTarget() })

vi.mock('../../api/client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../api/client')>(),
  uploadBulletinPhoto: vi.fn(),
  uploadBulletinPhotoRow: vi.fn(),
}))

const afterJpg = { id: 'bulletin', revision: 8 } as Schemas['BulletinEditor']
const afterPng = { id: 'bulletin', revision: 9 } as Schemas['BulletinEditor']

function selectMixedPhotos() {
  const onSaved = vi.fn()
  render(
    <MantineProvider env="test">
      <QueryClientProvider client={new QueryClient()}>
        <BulletinPhotoDialog id="bulletin" rowId="row" revision={7} title="صور الصف" field="main"
          otherFields={[{ name: 'thumb', label: 'الصورة المصغّرة' }]} onClose={vi.fn()} onSaved={onSaved} />
      </QueryClientProvider>
    </MantineProvider>,
  )

  fireEvent.click(screen.getByRole('button', { name: 'إضافة صور إلى حقول أخرى' }))
  const [primaryInput, otherInput] = Array.from(document.querySelectorAll('input[type="file"]'))
  const jpg = new File(['jpeg fixture'], 'primary.jpg', { type: 'image/jpeg' })
  const png = new File(['png fixture'], 'thumbnail.png', { type: 'image/png' })
  fireEvent.change(primaryInput, { target: { files: [jpg] } })
  fireEvent.change(otherInput, { target: { files: [png] } })
  const save = () => fireEvent.click(screen.getByRole('button', { name: 'حفظ الصور' }))
  return { jpg, png, onSaved, save }
}

it('saves selected JPG and PNG files into separate fields from one action using the updated revision', async () => {
  const upload = vi.mocked(uploadBulletinPhoto).mockReset().mockResolvedValueOnce(afterJpg).mockResolvedValueOnce(afterPng)
  const { jpg, png, onSaved, save } = selectMixedPhotos()
  save()
  await waitFor(() => expect(onSaved).toHaveBeenCalledWith(afterPng))
  expect(upload).toHaveBeenNthCalledWith(1, jpg, 'bulletin', 'row', 7, 'main')
  expect(upload).toHaveBeenNthCalledWith(2, png, 'bulletin', 'row', 8, 'thumb')
})

it('preserves a confirmed image and retries only the image that did not save', async () => {
  const upload = vi.mocked(uploadBulletinPhoto).mockReset().mockResolvedValueOnce(afterJpg)
    .mockRejectedValueOnce(new Error('bulletin_photo_invalid')).mockResolvedValueOnce(afterPng)
  const { jpg, png, onSaved, save } = selectMixedPhotos()
  save()
  expect(await screen.findByRole('alert')).toHaveTextContent('الصورة المصغّرة')
  expect(screen.getByText('الصور المحفوظة في هذه العملية 1')).toBeInTheDocument()
  expect(onSaved).not.toHaveBeenCalled()
  save()
  await waitFor(() => expect(onSaved).toHaveBeenCalledWith(afterPng))
  expect(upload.mock.calls).toEqual([
    [jpg, 'bulletin', 'row', 7, 'main'],
    [png, 'bulletin', 'row', 8, 'thumb'],
    [png, 'bulletin', 'row', 8, 'thumb'],
  ])
})

function renderBulletinEditor(options: Partial<Schemas['BulletinEditor']> = {}) {
  const bulletin: Schemas['BulletinEditor'] = {
    id: 'b_news', name: 'موجز', design: 'Mojaz', revision: 7, onAir: false, playbackSupported: false,
    headlinePaste: true, fields: [
      { name: 'title.Text', label: 'العنوان', kind: 'text' },
      { name: 'Subject.Text', label: 'الخبر', kind: 'text' },
      { name: 'mojaz_img', label: 'الصورة', kind: 'media' },
    ],
    rows: [], page: 0, pageCount: 1, total: 0, timing: null,
    imageField: 'mojaz_img', imageChoices: [], canUploadPhoto: true, photoFields: ['mojaz_img'],
    ...options,
  }
  const saved = { ...bulletin, revision: 8 }
  const mockGet = vi.spyOn(api, 'GET').mockImplementation(async (path) => ({
    data: path === '/api/content/bulletins/designs' ? { designs: [] } : bulletin,
    response: new Response(),
  }))
  const upload = vi.mocked(uploadBulletinPhotoRow).mockReset().mockResolvedValue(saved)
  const onSaved = vi.fn()
  render(
    <MantineProvider env="test">
      <QueryClientProvider client={new QueryClient()}>
        <BulletinEditor id={bulletin.id} onBack={vi.fn()} onSaved={onSaved} />
      </QueryClientProvider>
    </MantineProvider>,
  )
  return { saved, mockGet, upload, onSaved }
}

it('adds the location with the story and keeps the previous picture without uploading a file', async () => {
  const { saved, mockGet, upload, onSaved } = renderBulletinEditor({
    fields: [
      { name: 'title.Text', label: 'العنوان', kind: 'text' },
      { name: 'subject.Text', label: 'الخبر', kind: 'text' },
      { name: 'mojaz_img', label: 'الصورة', kind: 'media' },
    ],
  })
  const post = vi.spyOn(api, 'POST').mockResolvedValue({ data: saved, response: new Response() })
  try {
    fireEvent.click(await screen.findByRole('button', { name: 'إضافة صف' }))
    const save = screen.getByRole('button', { name: 'حفظ الصف' })
    expect(screen.getByRole('combobox', { name: 'مصدر الصورة' })).toHaveValue('inherit')
    expect(document.querySelector('input[type="file"]')).not.toBeInTheDocument()
    fireEvent.change(screen.getByRole('textbox', { name: 'العنوان' }), { target: { value: 'عنوان' } })
    fireEvent.change(screen.getByRole('textbox', { name: 'المكان' }), { target: { value: 'الميدان' } })
    expect(save).toBeDisabled()
    fireEvent.change(screen.getByRole('textbox', { name: 'الخبر' }), { target: { value: 'متن\nالخبر' } })
    fireEvent.click(save)
    await waitFor(() => expect(onSaved).toHaveBeenCalledWith(saved))
    expect(upload).not.toHaveBeenCalled()
    expect(post).toHaveBeenCalledExactlyOnceWith('/api/content/bulletins/editor', expect.objectContaining({
      body: expect.objectContaining({
        action: 'add', id: 'b_news', revision: 7, imageMode: 'inherit',
        values: { 'title.Text': 'عنوان', 'subject.Text': 'الميدان\nمتن\nالخبر' },
      }),
    }))
  } finally {
    post.mockRestore()
    mockGet.mockRestore()
  }
})

it('opens addition from a photo, then collects the headline and story before saving the row', async () => {
  const { saved, mockGet, upload, onSaved } = renderBulletinEditor()
  try {
    fireEvent.click(await screen.findByRole('button', { name: 'إضافة صف بصورة' }))
    expect(screen.getByRole('dialog', { name: 'إضافة صف بصورة' })).toBeInTheDocument()
    expect(screen.getByRole('combobox', { name: 'مصدر الصورة' })).toHaveValue('new')
    const headline = screen.getByRole('textbox', { name: 'العنوان' })
    const story = screen.getByRole('textbox', { name: 'الخبر' })
    expect(screen.getByRole('textbox', { name: 'المكان' })).toBeInTheDocument()
    const file = new File(['photo'], 'first.jpg', { type: 'image/jpeg' })
    fireEvent.change(document.querySelector('input[type="file"]')!, { target: { files: [file] } })

    const save = screen.getByRole('button', { name: 'حفظ الصف' })
    expect(upload).not.toHaveBeenCalled()
    expect(save).toBeDisabled()
    fireEvent.change(headline, { target: { value: 'عنوان' } })
    expect(save).toBeDisabled()
    fireEvent.change(story, { target: { value: 'متن\nالخبر' } })
    fireEvent.change(screen.getByRole('combobox', { name: 'مصدر الصورة' }), { target: { value: 'inherit' } })
    expect(document.querySelector('input[type="file"]')).not.toBeInTheDocument()
    expect(story).toHaveValue('متن\nالخبر')
    fireEvent.change(screen.getByRole('combobox', { name: 'مصدر الصورة' }), { target: { value: 'new' } })
    fireEvent.click(save)

    await waitFor(() => expect(onSaved).toHaveBeenCalledWith(saved))
    expect(upload).toHaveBeenCalledExactlyOnceWith({
      id: 'b_news', revision: 7, field: 'mojaz_img', file,
      values: { 'title.Text': 'عنوان', 'Subject.Text': 'متن\nالخبر' },
    })
  } finally {
    mockGet.mockRestore()
  }
})

it('keeps the location in its own field when the bulletin design has one', async () => {
  const { mockGet, upload, onSaved } = renderBulletinEditor({
    design: 'StudioBulletin', headlinePaste: false, fields: [
      { name: 'Subject.Text', label: 'الخبر', kind: 'text' },
      { name: 'location[1]', label: 'المكان', kind: 'text' },
      { name: 'mojaz_img', label: 'الصورة', kind: 'media' },
    ],
  })
  try {
    fireEvent.click(await screen.findByRole('button', { name: 'إضافة صف بصورة' }))
    const file = new File(['photo'], 'studio.png', { type: 'image/png' })
    fireEvent.change(document.querySelector('input[type="file"]')!, { target: { files: [file] } })
    fireEvent.change(screen.getByRole('textbox', { name: 'الخبر' }), { target: { value: 'متن الخبر' } })
    fireEvent.change(screen.getByRole('textbox', { name: 'المكان' }), { target: { value: 'الاستوديو' } })
    fireEvent.click(screen.getByRole('button', { name: 'حفظ الصف' }))

    await waitFor(() => expect(onSaved).toHaveBeenCalled())
    expect(upload).toHaveBeenCalledExactlyOnceWith({
      id: 'b_news', revision: 7, field: 'mojaz_img', file,
      values: { 'Subject.Text': 'متن الخبر', 'location[1]': 'الاستوديو' },
    })
  } finally {
    mockGet.mockRestore()
  }
})
