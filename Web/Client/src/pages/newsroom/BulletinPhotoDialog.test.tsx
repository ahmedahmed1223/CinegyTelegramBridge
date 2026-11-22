import { MantineProvider } from '@mantine/core'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { expect, it, vi } from 'vitest'
import { uploadBulletinPhoto, type Schemas } from '../../api/client'
import { BulletinPhotoDialog } from './BulletinPhotoDialog'

vi.mock('../../api/client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../api/client')>(),
  uploadBulletinPhoto: vi.fn(),
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
