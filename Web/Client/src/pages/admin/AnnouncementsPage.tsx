import { Alert, Badge, Button, Group, Modal, Pagination, Paper, Select, SimpleGrid, Skeleton, Stack, Switch, Text, Textarea } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { IconPlus } from '@tabler/icons-react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, sessionKey, useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'
import { formatDateTime } from '../../lib/time'

type Notice = Schemas['AnnouncementAdminItem']
type Draft = Schemas['AnnouncementReviewCommand']
type Review = { kind: 'queue'; preview: Schemas['AnnouncementPreview'] } | { kind: 'cancel'; preview: Schemas['AnnouncementCancelPreview'] }
const listKey = ['admin', 'announcements'] as const
const initialDraft: Draft = { text: '', scope: 'all', expiryHours: 0, repeatHours: 0, requireAck: true, pinned: false }
const recipients: Record<string, string> = { all: 'الجميع', admins: 'المشرفون', operators: 'المشغّلون', user: 'مستخدم محدد' }
const stateLabels: Record<string, { label: string; color: string }> = {
  queued: { label: 'في قائمة الإرسال', color: 'orange' },
  active: { label: 'نشط', color: 'teal' },
  cancelled: { label: 'موقوف', color: 'gray' },
  expired: { label: 'منتهي', color: 'gray' },
}

function announcementError(code: string) {
  switch (code) {
    case 'announcement_disabled': return 'التنويهات معطّلة في إعدادات الجسر.'
    case 'announcement_no_recipients': return 'لا يوجد مستلمون عبر Telegram ضمن هذه الفئة حاليًا.'
    case 'announcement_invalid': return 'راجع نص التنويه وخيارات الإرسال.'
    case 'announcement_stale': return 'تغيّرت بيانات التنويه أو قائمة المستلمين. راجعها من جديد.'
    case 'announcement_save_failed': return 'تعذّر حفظ التنويه، ولم يدخل قائمة الإرسال.'
    default: return messageFor(code)
  }
}

function NoticeDetails({ item }: { item: Notice }) {
  const state = stateLabels[item.status] ?? stateLabels.expired
  return (
    <Stack gap={7}>
      <Group gap="xs">
        <Badge color={state.color} variant="light">{state.label}</Badge>
        <Text size="sm" c="dimmed">{recipients[item.scope] ?? item.scope}</Text>
        {item.pinned && <Badge color="gray" variant="outline">مثبّت</Badge>}
      </Group>
      <Text style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}><bdi>{item.text}</bdi></Text>
      <Group gap="sm">
        <Text size="xs" c="dimmed">أُنشئ في {formatDateTime(item.createdAt)}</Text>
        <Text size="xs" c="dimmed">ينتهي في {formatDateTime(item.expiresAt)}</Text>
        {item.lastSentAt > 0 && <Text size="xs" c="dimmed">آخر إرسال {formatDateTime(item.lastSentAt)}</Text>}
        {item.requireAck && <Text size="xs" c="dimmed">تأكيدات القراءة {item.readCount}</Text>}
      </Group>
    </Stack>
  )
}

export function AnnouncementsPage() {
  const session = useSession()
  const client = useQueryClient()
  const canManage = isAdmin(session.data)
  const [page, setPage] = useState(0)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [review, setReview] = useState<Review | null>(null)
  const list = useQuery({
    queryKey: [...listKey, session.data?.id, page],
    enabled: canManage,
    refetchInterval: 30_000,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/announcements', {
        params: { query: { page, pageSize: 8 } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })

  function refresh() { return client.invalidateQueries({ queryKey: listKey }) }

  function fail(error: Error) {
    notifications.show({ color: 'red', message: announcementError(error.message) })
    if (['forbidden', 'unauthorized'].includes(error.message)) {
      setDraft(null)
      setReview(null)
      void client.invalidateQueries({ queryKey: sessionKey })
    }
    void refresh()
  }

  const reviewing = useMutation({
    mutationFn: async (request: { kind: 'queue'; draft: Draft } | { kind: 'cancel'; id: string }): Promise<Review> => {
      if (request.kind === 'queue') {
        const { data, error, response } = await api.POST('/api/admin/announcements/review', { body: request.draft })
        if (!data) throw new Error(errorCode(error, response))
        return { kind: 'queue', preview: data }
      }
      const { data, error, response } = await api.POST('/api/admin/announcements/{id}/cancel/review', {
        params: { path: { id: request.id } },
      })
      if (!data) throw new Error(errorCode(error, response))
      return { kind: 'cancel', preview: data }
    },
    onSuccess: setReview,
    onError: fail,
  })

  const saving = useMutation({
    mutationFn: async (selected: Review) => {
      if (selected.kind === 'queue') {
        const { data, error, response } = await api.POST('/api/admin/announcements/confirm', { body: { review: selected.preview.review } })
        if (!data) throw new Error(errorCode(error, response))
        return { color: 'green', message: 'أُضيف التنويه إلى قائمة الإرسال.' }
      }
      const { data, error, response } = await api.POST('/api/admin/announcements/{id}/cancel/confirm', {
        params: { path: { id: selected.preview.item.id } }, body: { review: selected.preview.review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data.persisted ? { color: 'green', message: 'أُوقف التنويه.' } : {
        color: 'orange', message: 'أُوقف التنويه أثناء التشغيل الحالي وتعذّر حفظ الإيقاف. قد يعود بعد إعادة تشغيل الجسر.',
      }
    },
    onSuccess: async (notice, selected) => {
      if (selected.kind === 'queue') setPage(0)
      setDraft(null)
      setReview(null)
      notifications.show(notice)
      await refresh()
    },
    onError: (error) => {
      setReview(null)
      fail(error)
    },
  })

  if (session.isPending) return <Skeleton h={120} />
  if (!canManage) return <Alert color="red" role="alert">{announcementError('forbidden')}</Alert>

  const busy = reviewing.isPending || saving.isPending
  const pageData = list.data
  const pageCount = pageData ? Math.ceil(pageData.total / pageData.pageSize) : 0
  const modalTitle = review?.kind === 'cancel' ? 'مراجعة إيقاف التنويه' : review ? 'مراجعة التنويه' : 'تنويه جديد'

  return (
    <Stack gap="lg" dir="rtl">
      <PageHeader title="التنويهات" actions={<Button leftSection={<IconPlus size={18} />}
        disabled={busy || list.isError || !pageData?.enabled} onClick={() => setDraft(initialDraft)}>تنويه جديد</Button>} />
      {list.isError && <Alert color="red" role="alert">{announcementError(list.error.message)}</Alert>}
      {list.isPending && <Skeleton h={120} />}
      {!list.isError && pageData && <>
        {!pageData.enabled && <Alert color="orange">التنويهات معطّلة. يمكنك قراءة السجل وإيقاف التنويهات المتبقية.</Alert>}
        {pageData.items.length === 0 && <Text size="sm" c="dimmed">لا توجد تنويهات.</Text>}
        {pageData.items.map((item) => (
          <Paper withBorder p="md" radius="md" key={item.id}>
            <Stack gap="sm">
              <NoticeDetails item={item} />
              {(item.status === 'active' || item.status === 'queued') && <Group justify="flex-end">
                <Button color="red" variant="subtle" size="compact-sm" disabled={busy}
                  loading={reviewing.isPending && reviewing.variables?.kind === 'cancel' && reviewing.variables.id === item.id}
                  onClick={() => reviewing.mutate({ kind: 'cancel', id: item.id })}>إيقاف التنويه</Button>
              </Group>}
            </Stack>
          </Paper>
        ))}
        {pageCount > 1 && <Pagination value={pageData.page + 1} total={pageCount} disabled={busy}
          onChange={(next) => setPage(next - 1)} />}
      </>}

      <Modal opened={draft !== null || review !== null} title={modalTitle} centered
        closeOnClickOutside={!busy} closeOnEscape={!busy} withCloseButton={!busy}
        closeButtonProps={{ 'aria-label': 'إغلاق' }} onClose={() => { setDraft(null); setReview(null) }}>
        <Stack gap="md" dir="rtl">
          {draft && !review && pageData && <>
            <Textarea label="نص التنويه" autosize minRows={3} maxRows={8} maxLength={pageData.maxLength}
              description={`الحد الأقصى ${pageData.maxLength} حرفًا`} value={draft.text} disabled={busy}
              onChange={(event) => setDraft({ ...draft, text: event.currentTarget.value })} />
            <Select label="المستلمون" allowDeselect={false} disabled={busy} value={draft.scope}
              data={['all', 'operators', 'admins'].map((value) => ({ value, label: recipients[value] }))}
              onChange={(scope) => setDraft({ ...draft, scope: scope ?? draft.scope })} />
            <SimpleGrid cols={{ base: 1, sm: 2 }}>
              <Select label="مدة التنويه" allowDeselect={false} disabled={busy} value={String(draft.expiryHours)}
                data={[{ value: '0', label: `افتراضية (${pageData.defaultExpiryHours} ساعة)` },
                  ...[1, 6, 24, 72].map((value) => ({ value: String(value), label: `${value} ساعة` }))]}
                onChange={(value) => setDraft({ ...draft, expiryHours: Number(value ?? draft.expiryHours) })} />
              <Select label="التكرار" allowDeselect={false} disabled={busy} value={String(draft.repeatHours)}
                data={[{ value: '0', label: 'مرة واحدة' }, ...[1, 3, 6, 12].map((value) => ({ value: String(value), label: `كل ${value} ساعة` }))]}
                onChange={(value) => setDraft({ ...draft, repeatHours: Number(value ?? draft.repeatHours) })} />
            </SimpleGrid>
            <Switch label="طلب تأكيد القراءة" checked={draft.requireAck} disabled={busy}
              onChange={(event) => setDraft({ ...draft, requireAck: event.currentTarget.checked })} />
            <Switch label="تثبيت التنويه" checked={draft.pinned} disabled={busy}
              onChange={(event) => setDraft({ ...draft, pinned: event.currentTarget.checked })} />
            <Group justify="flex-end">
              <Button variant="default" disabled={busy} onClick={() => setDraft(null)}>إلغاء</Button>
              <Button loading={reviewing.isPending} disabled={!draft.text.trim() || !pageData.enabled}
                onClick={() => reviewing.mutate({ kind: 'queue', draft })}>مراجعة قبل الإرسال</Button>
            </Group>
          </>}
          {review && <>
            {review.kind === 'cancel' ? <>
              <NoticeDetails item={review.preview.item} />
              <Text size="sm">يوقف هذا الإجراء عمليات الإرسال التالية ويحتفظ بالتنويه في السجل.</Text>
            </> : <>
              <Text style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}><bdi>{review.preview.text}</bdi></Text>
              <Group gap="xs">
                <Badge variant="light">{recipients[review.preview.scope]} · {review.preview.audienceCount} حاليًا</Badge>
                <Badge variant="default">المدة {review.preview.expiryHours} ساعة</Badge>
                <Badge variant="default">{review.preview.repeatHours ? `كل ${review.preview.repeatHours} ساعة` : 'مرة واحدة'}</Badge>
                {review.preview.requireAck && <Badge variant="default">تأكيد القراءة</Badge>}
                {review.preview.pinned && <Badge variant="default">مثبّت</Badge>}
              </Group>
              <Text size="sm" c="dimmed">يرسل الجسر التنويه عند حلول دورة الإرسال خارج ساعات الهدوء.</Text>
            </>}
            <Group justify="flex-end">
              <Button variant="default" disabled={busy} onClick={() => setReview(null)}>
                {review.kind === 'queue' ? 'العودة للتعديل' : 'إلغاء'}
              </Button>
              <Button color={review.kind === 'cancel' ? 'red' : undefined} loading={saving.isPending}
                onClick={() => saving.mutate(review)}>{review.kind === 'cancel' ? 'تأكيد الإيقاف' : 'إضافة إلى قائمة الإرسال'}</Button>
            </Group>
          </>}
        </Stack>
      </Modal>
    </Stack>
  )
}
