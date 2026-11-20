import { Alert, Button, Group, Modal, SimpleGrid, Stack, Text, Title } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import classes from './NewsroomPage.module.css'
import { TickerReviewHeadlines } from './TickerReviewHeadlines'

type Target = 'draft' | 'air'
type Review = { target: Target; preview: Schemas['TickerSheetPreview'] }

export function TickerSheet({ disabled, onApplied }: { disabled: boolean; onApplied: (target: Target) => Promise<unknown> }) {
  const [review, setReview] = useState<Review | null>(null)
  const command = useMutation({
    mutationFn: async ({ target, token }: { target: Target; token?: string }) => {
      const { data, error, response } = await api.POST('/api/content/ticker/sheet', {
        body: { action: token ? 'apply' : 'preview', target, review: token ?? null },
      })
      if (!response.ok) throw new Error(messageFor(errorCode(error, response)))
      if (!token && !data) throw new Error(messageFor('unknown'))
      return data
    },
    onSuccess: async (preview, request) => {
      if (preview) {
        setReview({ target: request.target, preview })
        return
      }
      setReview(null)
      notifications.show({
        color: 'teal',
        message: request.target === 'air' ? 'نُشرت أخبار الجدول في الشريط.' : 'حُمّلت أخبار الجدول إلى المسودة.',
      })
      await onApplied(request.target)
    },
    onError: async (_failure, request) => {
      if (request.token) await onApplied(request.target)
    },
  })
  const blocked = command.isPending || disabled
  const air = review?.target === 'air'
  return (
    <Stack component="section" id="ticker-sheet" aria-labelledby="ticker-sheet-title" className={classes.tickerTools} gap="sm">
      <Title order={5} id="ticker-sheet-title">استيراد من Google Sheets</Title>
      <Group gap="xs">
        <Button size="sm" variant="default" disabled={blocked} loading={command.isPending && command.variables?.target === 'draft'}
          onClick={() => command.mutate({ target: 'draft' })}>مراجعة للمسودة</Button>
        <Button size="sm" variant="light" disabled={blocked} loading={command.isPending && command.variables?.target === 'air'}
          onClick={() => command.mutate({ target: 'air' })}>مراجعة للنشر</Button>
      </Group>
      {!review && command.error && <Alert color="orange" role="alert">{command.error.message}</Alert>}
      <Modal opened={!!review} onClose={() => { if (!command.isPending) { setReview(null); command.reset() } }}
        size="xl" title={air ? 'مراجعة نشر أخبار الجدول' : 'مراجعة تحميل أخبار الجدول'}>
        {review && <Stack gap="md">
          <SimpleGrid cols={{ base: 1, sm: 2 }}>
            <TickerReviewHeadlines title={air ? 'الشريط المنشور الآن' : 'أخبار المسودة الآن'} items={review.preview.currentItems} />
            <TickerReviewHeadlines title="أخبار Google Sheets" items={review.preview.items} />
          </SimpleGrid>
          {review.preview.identical ? <Alert color="gray">الأخبار وترتيبها مطابقان.</Alert> : (
            <Alert color={air || review.preview.cancelsSchedule ? 'orange' : 'blue'}>
              {air ? 'ستصل أخبار الجدول إلى الشريط المنشور فور التأكيد. تبقى المسودة متاحة للتحرير.'
                : 'ستحلّ أخبار الجدول محل أخبار المسودة.'}
              {review.preview.cancelsSchedule && <Text size="sm" fw={600} mt={4}>سيُلغى موعد نشر المسودة المجدول.</Text>}
            </Alert>
          )}
          {command.error && <Alert color="orange" role="alert">{command.error.message}</Alert>}
          <Group justify="flex-end" gap="xs">
            {command.error && <Button variant="default" disabled={blocked}
              onClick={() => command.mutate({ target: review.target })}>إعادة المراجعة</Button>}
            <Button color={air ? 'red' : undefined} disabled={disabled || !!command.error || review.preview.identical}
              loading={command.isPending} onClick={() => command.mutate({ target: review.target, token: review.preview.review })}>
              {air ? 'نشر أخبار الجدول' : 'استبدال أخبار المسودة'}
            </Button>
          </Group>
        </Stack>}
      </Modal>
    </Stack>
  )
}
