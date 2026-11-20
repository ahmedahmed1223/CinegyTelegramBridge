import { Alert, Button, Group, Modal, Pagination, ScrollArea, SimpleGrid, Skeleton, Stack, Text, Title } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatDateTime } from '../../lib/time'
import classes from './NewsroomPage.module.css'

type Preview = Schemas['TickerBackupPreview']
type Review = { id: string; preview: Preview }
const number = new Intl.NumberFormat('ar')

function HeadlineList({ title, items }: { title: string; items: string[] }) {
  return (
    <Stack gap="xs">
      <Title order={5}>{title} · {number.format(items.length)}</Title>
      {items.length === 0 ? <Text c="dimmed" size="sm">لا توجد أخبار.</Text> : (
        <ScrollArea.Autosize mah="27vh" type="auto" tabIndex={0} role="region" aria-label={title}>
          <ol className={classes.reviewItems}>
            {items.map((item, index) => <li key={index}><Text size="sm" dir="auto">{item}</Text></li>)}
          </ol>
        </ScrollArea.Autosize>
      )}
    </Stack>
  )
}

export function TickerBackups({ onRestored, disabled }: { onRestored: () => Promise<unknown>; disabled: boolean }) {
  const [page, setPage] = useState(0)
  const [review, setReview] = useState<Review | null>(null)
  const backups = useQuery({
    queryKey: ['ticker-backups', page],
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/ticker/backups', { signal, params: { query: { page } } })
      if (!data?.list) throw new Error(messageFor(errorCode(error, response)))
      return data.list
    },
  })
  const command = useMutation({
    mutationFn: async ({ id, token }: { id: string; token?: string }) => {
      const { data, error, response } = await api.POST('/api/content/ticker/backups', {
        body: { action: token ? 'restore' : 'preview', id, review: token ?? null, page: null },
      })
      if (!response.ok) throw new Error(messageFor(errorCode(error, response)))
      if (!token && !data?.preview) throw new Error(messageFor('unknown'))
      return data?.preview
    },
    onSuccess: async (preview, request) => {
      if (preview) {
        setReview({ id: request.id, preview })
        return
      }
      setReview(null)
      notifications.show({ color: 'teal', message: 'استُعيدت النسخة إلى الشريط المنشور.' })
      if (page === 0) await backups.refetch()
      else setPage(0)
      await onRestored()
    },
  })
  const list = backups.data

  return (
    <Stack component="section" id="ticker-backups" aria-labelledby="ticker-backups-title" gap="sm" className={classes.tickerTools}>
      <Group justify="space-between" gap="xs">
        <Title id="ticker-backups-title" order={5}>النسخ الاحتياطية للشريط</Title>
        {list && <Text c="dimmed" size="sm">{number.format(list.total)} نسخة</Text>}
      </Group>
      {backups.isPending && <Skeleton h={44} aria-label="جارٍ تحميل النسخ الاحتياطية" />}
      {backups.error && <Alert color="orange" role="alert">
        {backups.error.message}
        <Button variant="subtle" size="compact-sm" onClick={() => void backups.refetch()}>إعادة المحاولة</Button>
      </Alert>}
      {!review && command.error && <Alert color="orange" role="alert">{command.error.message}</Alert>}
      {list && list.items.length === 0 && <Text size="sm" c="dimmed">لا توجد نسخ احتياطية للشريط.</Text>}
      {list && list.items.length > 0 && (
        <>
          <ol className={classes.tickerItems} start={list.page * 8 + 1}>
            {list.items.map((item) => (
              <li key={item.id}>
                <Group justify="space-between" gap="xs">
                  <Text size="sm"><bdi>{formatDateTime(item.savedAt)}</bdi></Text>
                  <Button variant="subtle" size="compact-sm" disabled={disabled || command.isPending}
                    loading={command.isPending && command.variables?.id === item.id}
                    onClick={() => command.mutate({ id: item.id })}>مراجعة النسخة</Button>
                </Group>
              </li>
            ))}
          </ol>
          {list.pageCount > 1 && <Pagination value={list.page + 1} total={list.pageCount}
            onChange={(next) => setPage(next - 1)} disabled={command.isPending} aria-label="صفحات النسخ الاحتياطية" />}
        </>
      )}
      <Modal opened={!!review} onClose={() => { if (!command.isPending) { setReview(null); command.reset() } }}
        title="مراجعة استعادة الشريط" size="xl">
        {review && <Stack gap="md">
          <Text size="sm" c="dimmed">النسخة المحفوظة في <bdi>{formatDateTime(review.preview.savedAt)}</bdi></Text>
          <SimpleGrid cols={{ base: 1, sm: 2 }} spacing="md">
            {review.preview.currentReadable ? <HeadlineList title="الشريط المنشور الآن" items={review.preview.currentItems} />
              : <Alert color="orange" title="الشريط المنشور الآن">تعذّرت قراءة أخبار الملف الحالي.</Alert>}
            <HeadlineList title="النسخة الاحتياطية" items={review.preview.items} />
          </SimpleGrid>
          {review.preview.identical ? <Alert color="gray">الأخبار وترتيبها مطابقان للشريط المنشور.</Alert> : (
            <Alert color="orange">
              ستصل أخبار النسخة إلى الشريط المنشور فورًا. تُحفظ مسودات المحرّرين.
              {review.preview.cancelsSchedule && <Text size="sm" fw={600} mt={4}>سيُلغى موعد نشر المسودة المجدول.</Text>}
            </Alert>
          )}
          {command.error && <Alert color="orange" role="alert">{command.error.message}</Alert>}
          <Group justify="flex-end">
            {command.error && <Button variant="default" disabled={command.isPending}
              onClick={() => command.mutate({ id: review.id })}>إعادة المراجعة</Button>}
            <Button color="red" disabled={review.preview.identical || !!command.error || disabled}
              loading={command.isPending} onClick={() => command.mutate({ id: review.id, token: review.preview.review })}>
              استعادة إلى الشريط المنشور
            </Button>
          </Group>
        </Stack>}
      </Modal>
    </Stack>
  )
}
