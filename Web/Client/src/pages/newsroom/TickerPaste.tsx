import { Alert, Button, Group, Modal, Stack, Text, Textarea } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import type { Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { TickerReviewHeadlines } from './TickerReviewHeadlines'

type Request = Schemas['TickerDraftRequest']
type Preview = Schemas['TickerPastePreview']
const number = new Intl.NumberFormat('ar')

export function TickerPaste({ draft, onClose, onCommand, onRefresh }: {
  draft: Schemas['TickerDraft']
  onClose: () => void
  onCommand: (body: Pick<Request, 'action'> & Partial<Request>) => Promise<Schemas['TickerEditorState']>
  onRefresh: () => Promise<unknown>
}) {
  const [text, setText] = useState('')
  const [review, setReview] = useState<{ preview: Preview; revision: string }>()
  const request = useMutation({
    mutationFn: async ({ token }: { token?: string }) => {
      const revision = draft.revision
      const result = await onCommand({ action: token ? 'apply_paste' : 'preview_paste', revision, text, review: token })
      if (token) return null
      if (!result.paste) throw new Error('unknown')
      return { preview: result.paste, revision }
    },
    onSuccess: async (result) => {
      if (result) setReview(result)
      else {
        onClose()
        await onRefresh()
      }
    },
    onError: async () => { await onRefresh() },
  })
  const preview = review?.preview
  const fresh = review?.revision === draft.revision
  const overLimit = text.length > 8000
  return (
    <Modal opened onClose={() => { if (!request.isPending) onClose() }} title="لصق أخبار الشريط" size="lg">
      <form onSubmit={(event) => { event.preventDefault(); if (text.trim() && !overLimit && !request.isPending) request.mutate({}) }}>
        <Stack gap="md">
          <Textarea data-autofocus label="الأخبار" description="ضع كل خبر في سطر مستقل."
            value={text} minRows={4} maxRows={10} autosize dir="rtl" disabled={request.isPending}
            error={overLimit ? 'يتجاوز النص ٨٠٠٠ حرف. قلّل النص أو وزّع الأخبار على دفعتين.' : undefined}
            onChange={(event) => { setText(event.currentTarget.value); setReview(undefined); request.reset() }} />
          {preview && <>
            <TickerReviewHeadlines title={preview.atTop ? 'يُضاف في بداية المسودة' : 'يُضاف في نهاية المسودة'} items={preview.items} />
            <Group gap="sm">
              {preview.duplicates > 0 && <Text size="sm" c="dimmed">مكررة · {number.format(preview.duplicates)}</Text>}
              {preview.tooLong > 0 && <Text size="sm" c="dimmed">تجاوزت طول الخبر · {number.format(preview.tooLong)}</Text>}
              {preview.noRoom > 0 && <Text size="sm" c="dimmed">تجاوزت سعة المسودة · {number.format(preview.noRoom)}</Text>}
            </Group>
            {draft.scheduledAt && preview.items.length > 0 && <Alert color="orange">ستدخل الأخبار المضافة ضمن النشر المجدول.</Alert>}
          </>}
          {review && !fresh && <Alert color="orange">تغيّرت المسودة. اعرض المعاينة مرة أخرى.</Alert>}
          {request.error && <Alert color="orange" role="alert">{messageFor(request.error.message)}</Alert>}
          <Group justify="flex-end" gap="xs">
            <Button type="submit" variant="default" disabled={!text.trim() || overLimit || request.isPending}>معاينة الأخبار</Button>
            {preview && <Button type="button" disabled={!fresh || !!request.error || preview.items.length === 0}
              loading={request.isPending && !!request.variables?.token} onClick={() => request.mutate({ token: preview.review })}>
              إضافة الأخبار إلى المسودة
            </Button>}
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
