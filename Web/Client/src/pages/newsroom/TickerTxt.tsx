import { Alert, Button, FileInput, Group, Modal, SimpleGrid, Stack, Text } from '@mantine/core'
import { IconFileUpload } from '@tabler/icons-react'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { uploadTickerTxt, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { TickerReviewHeadlines } from './TickerReviewHeadlines'

const number = new Intl.NumberFormat('ar')
type Review = { revision: string; value: Schemas['TickerTxtPreview'] }

export function TickerTxt({ draft, onClose, onRefresh }: {
  draft: Schemas['TickerDraft']
  onClose: () => void
  onRefresh: () => Promise<unknown>
}) {
  const [file, setFile] = useState<File | null>(null)
  const [review, setReview] = useState<Review | null>(null)
  const command = useMutation({
    mutationFn: ({ selected, revision, token }: { selected: File; revision: string; token?: string }) =>
      uploadTickerTxt(selected, revision, token),
    onSuccess: async (value, { revision }) => {
      if (value) setReview({ revision, value })
      else {
        onClose()
        await onRefresh()
      }
    },
    onError: async () => { await onRefresh() },
  })
  const reviewValue = review?.value
  const outdated = !!review && review.revision !== draft.revision
  const wrongType = !!file && !file.name.toLowerCase().endsWith('.txt')
  return (
    <Modal opened title="استيراد أخبار من TXT" size="xl" onClose={() => { if (!command.isPending) onClose() }}>
      <form onSubmit={(event) => {
        event.preventDefault()
        if (file && !wrongType && !command.isPending) command.mutate({ selected: file, revision: draft.revision })
      }}>
        <Stack gap="md">
          <FileInput label="ملف الأخبار" placeholder="اختر ملف TXT" accept=".txt,text/plain" clearable
            description="ملف UTF-8. ضع كل خبر في سطر، أو استخدم فاصل الشريط المضبوط."
            leftSection={<IconFileUpload size={17} aria-hidden />} value={file} disabled={command.isPending}
            error={wrongType ? 'اختر ملفًا بامتداد TXT.' : undefined}
            onChange={(selected) => { setFile(selected); setReview(null); command.reset() }} />
          {reviewValue && <>
            <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="md">
              <TickerReviewHeadlines title="المسودة الآن" items={reviewValue.currentItems} />
              <TickerReviewHeadlines title="الأخبار من الملف" items={reviewValue.items} />
            </SimpleGrid>
            {reviewValue.duplicates > 0 &&
              <Text size="sm" c="dimmed">أخبار مكرّرة استُبعدت · {number.format(reviewValue.duplicates)}</Text>}
            {reviewValue.identical ? <Alert color="gray">أخبار الملف وترتيبها مطابقان للمسودة.</Alert>
              : <Alert color="orange">ستحلّ أخبار الملف محلّ أخبار المسودة.
                {reviewValue.cancelsSchedule && <Text size="sm" fw={600}>سيُلغى موعد نشر المسودة المجدول.</Text>}
              </Alert>}
          </>}
          {outdated && <Alert color="orange" role="alert">تغيّرت المسودة. اعرض معاينة جديدة قبل الاستبدال.</Alert>}
          {command.error && <Alert color="red" role="alert">{messageFor(command.error.message)}</Alert>}
          <Group justify="flex-end" gap="xs">
            <Button type="submit" variant="default" disabled={!file || wrongType || command.isPending}
              loading={command.isPending && !command.variables?.token}>{review ? 'إعادة المعاينة' : 'معاينة الملف'}</Button>
            {review && <Button color="orange" type="button" disabled={!file || command.isPending || outdated || review.value.identical || !!command.error}
              loading={command.isPending && !!command.variables?.token}
              onClick={() => { if (file) command.mutate({ selected: file, revision: review.revision, token: review.value.review }) }}>
              استبدال أخبار المسودة
            </Button>}
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
