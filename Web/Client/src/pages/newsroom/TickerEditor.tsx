import { ActionIcon, Alert, Button, Group, Modal, Pagination, Paper, ScrollArea, Stack, Text, Textarea, Title } from '@mantine/core'
import { modals } from '@mantine/modals'
import { notifications } from '@mantine/notifications'
import { IconArrowDown, IconArrowUp, IconEdit, IconPlus, IconTrash } from '@tabler/icons-react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import classes from './NewsroomPage.module.css'

type Request = Schemas['TickerDraftRequest']
type Draft = Schemas['TickerDraft']
type Conflict = Schemas['TickerConflict']
type Edit = { revision: string; index: number | null; text: string }
type Review = { draft: Draft; conflict?: Conflict }
const draftKey = ['ticker-draft']
const pageSize = 20
const number = new Intl.NumberFormat('ar')

async function tickerCommand(body: Pick<Request, 'action'> & Partial<Request>) {
  const { data, error, response } = await api.POST('/api/content/ticker/draft', {
    body: { revision: null, index: null, text: null, review: null, ...body },
  })
  if (!data) throw new Error(errorCode(error, response))
  return data
}

function ReviewItems({ items }: { items: string[] }) {
  if (!items.length) return <Text size="sm" c="dimmed">القائمة فارغة.</Text>
  return (
    <ScrollArea.Autosize mah="30vh" type="auto">
      <ol className={classes.reviewItems}>
        {items.map((item, index) => <li key={index}><Text size="sm" dir="auto">{item}</Text></li>)}
      </ol>
    </ScrollArea.Autosize>
  )
}

export function TickerEditor({ onPublished }: { onPublished: () => Promise<unknown> }) {
  const queryClient = useQueryClient()
  const [page, setPage] = useState(1)
  const [edit, setEdit] = useState<Edit | null>(null)
  const [review, setReview] = useState<Review | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const status = useQuery({
    queryKey: draftKey,
    queryFn: async ({ signal }) => {
      const { data, error: failure, response } = await api.GET('/api/content/ticker/draft', { signal })
      if (!data) throw new Error(errorCode(failure, response))
      return data
    },
    retry: false,
  })
  const editor = status.data
  const draft = editor?.draft
  const items = draft?.items ?? []
  const pageCount = Math.max(1, Math.ceil(items.length / pageSize))
  const currentPage = Math.min(page, pageCount)
  const offset = (currentPage - 1) * pageSize

  async function send(body: Pick<Request, 'action'> & Partial<Request>) {
    if (busy) return
    setBusy(true)
    setError('')
    try {
      await queryClient.cancelQueries({ queryKey: draftKey })
      const updated = await tickerCommand(body)
      queryClient.setQueryData(draftKey, updated)
      setEdit(null)
      setReview(null)
      if (body.action === 'start') setPage(1)
      if (body.action === 'publish' || body.action === 'append' || body.action === 'replace') {
        notifications.show({
          color: updated.sheetFailed ? 'orange' : 'teal',
          message: updated.sheetFailed ? 'نُشر الشريط وتعذّرت مزامنة Google Sheets.' : 'نُشر شريط الأخبار.',
        })
        await onPublished()
      }
    } catch (failure) {
      const code = failure instanceof Error ? failure.message : 'bridge_unavailable'
      setError(messageFor(code))
      if (code === 'ticker_conflict' && review) {
        try {
          const latest = await tickerCommand({ action: 'review_conflict', revision: review.draft.revision })
          if (latest.conflict) setReview({ draft: review.draft, conflict: latest.conflict })
        } catch (reloadError) {
          setError(messageFor(reloadError instanceof Error ? reloadError.message : 'bridge_unavailable'))
        }
      }
      await status.refetch()
    } finally {
      setBusy(false)
    }
  }

  function confirmHandover(current: Draft) {
    modals.openConfirmModal({
      title: 'تسليم مسودة الشريط',
      children: (
        <Stack gap="xs">
          <Text>ستبقى الأخبار محفوظة، ويستطيع المحرّر التالي تسلّم المسودة.</Text>
          {current.scheduledAt && <Text>سيلغي التسليم موعد النشر المجدول.</Text>}
        </Stack>
      ),
      labels: { confirm: 'تسليم المسودة', cancel: 'إلغاء' },
      onConfirm: () => void send({ action: 'handover', revision: current.revision }),
    })
  }

  function confirmDelete(current: Draft, index: number) {
    modals.openConfirmModal({
      title: 'حذف خبر من المسودة',
      children: <Text dir="auto">{current.items[index]}</Text>,
      labels: { confirm: 'حذف الخبر', cancel: 'إلغاء' },
      confirmProps: { color: 'red' },
      onConfirm: () => void send({ action: 'remove', revision: current.revision, index }),
    })
  }

  function editForm(current: Edit) {
    return (
      <form onSubmit={(event) => {
        event.preventDefault()
        void send({ action: current.index === null ? 'add' : 'update', ...current })
      }}>
        <Stack gap="xs">
          <Textarea
            label={current.index === null ? 'الخبر الجديد' : 'نص الخبر'}
            dir="auto" autosize minRows={2} maxRows={6} required autoFocus
            maxLength={editor?.maxItemLength}
            value={current.text}
            onChange={(event) => setEdit({ ...current, text: event.currentTarget.value })}
            disabled={busy}
          />
          <Group gap="xs">
            <Button type="submit" size="sm" loading={busy}>حفظ الخبر</Button>
            <Button variant="subtle" size="sm" disabled={busy} onClick={() => { setEdit(null); setError('') }}>إلغاء</Button>
          </Group>
        </Stack>
      </form>
    )
  }

  return (
    <Paper withBorder p="md">
      <Stack gap="md">
        <Group justify="space-between">
          <div>
            <Title order={4}>مسودة الشريط</Title>
            {draft && <Text size="sm" c="dimmed">{number.format(items.length)} من {number.format(draft.maxItems)} خبرًا</Text>}
          </div>
          {editor && !draft && editor.state !== 'locked' && (
            <Button variant="light" loading={busy} onClick={() => void send({ action: 'start' })}>
              {editor.state === 'open' ? 'تسلّم المسودة' : 'بدء مسودة'}
            </Button>
          )}
          {draft && (
            <Button leftSection={<IconPlus size={16} />} disabled={busy || !!edit || items.length >= draft.maxItems}
              onClick={() => { setError(''); setEdit({ index: null, text: '', revision: draft.revision }) }}>
              إضافة خبر
            </Button>
          )}
        </Group>
        {status.isPending && <Text size="sm" c="dimmed">جارٍ قراءة حالة المسودة…</Text>}
        {status.isError && (
          <Alert color="orange">
            {messageFor(status.error.message)}
            <Button variant="subtle" size="compact-sm" onClick={() => void status.refetch()}>إعادة المحاولة</Button>
          </Alert>
        )}
        {!review && error && <Alert color="red" role="alert">{error}</Alert>}
        {editor?.state === 'locked' && (
          <Alert color="orange" title="المسودة قيد التحرير">
            {editor.owner ? `المسودة مع ${editor.owner} الآن.` : 'المسودة مع محرّر آخر الآن.'}
            <Button variant="subtle" size="compact-sm" onClick={() => void status.refetch()}>تحديث الحالة</Button>
          </Alert>
        )}
        {draft && (
          <>
            {edit?.index === null && editForm(edit)}
            <ol className={classes.tickerItems} start={offset + 1}>
              {items.slice(offset, offset + pageSize).map((item, pageIndex) => {
                const index = offset + pageIndex
                return (
                  <li key={index}>
                    {edit?.index === index ? editForm(edit) : (
                      <div className={classes.tickerEntry}>
                        <Text dir="auto" className={classes.headline}>{item}</Text>
                        <Group gap={2} wrap="nowrap">
                          <ActionIcon variant="subtle" aria-label={`تعديل الخبر ${index + 1}`} disabled={busy || !!edit}
                            onClick={() => { setError(''); setEdit({ index, text: item, revision: draft.revision }) }}><IconEdit size={16} /></ActionIcon>
                          <ActionIcon variant="subtle" aria-label={`رفع الخبر ${index + 1}`} disabled={busy || !!edit || index === 0}
                            onClick={() => void send({ action: 'up', revision: draft.revision, index })}><IconArrowUp size={16} /></ActionIcon>
                          <ActionIcon variant="subtle" aria-label={`خفض الخبر ${index + 1}`} disabled={busy || !!edit || index + 1 === items.length}
                            onClick={() => void send({ action: 'down', revision: draft.revision, index })}><IconArrowDown size={16} /></ActionIcon>
                          {draft.canRemove && (
                            <ActionIcon variant="subtle" color="red" aria-label={`حذف الخبر ${index + 1}`} disabled={busy || !!edit}
                              onClick={() => confirmDelete(draft, index)}><IconTrash size={16} /></ActionIcon>
                          )}
                        </Group>
                      </div>
                    )}
                  </li>
                )
              })}
            </ol>
            {pageCount > 1 && <Pagination total={pageCount} value={currentPage} onChange={setPage} disabled={!!edit || busy} />}
            <Group justify="space-between">
              <Button variant="default" disabled={busy || !!edit} onClick={() => confirmHandover(draft)}>تسليم المسودة</Button>
              <Button color="red" variant="light" disabled={busy || !!edit} onClick={() => { setError(''); setReview({ draft }) }}>مراجعة النشر</Button>
            </Group>
          </>
        )}
      </Stack>
      <Modal opened={!!review} onClose={() => { if (!busy) { setReview(null); setError('') } }} title="مراجعة نشر شريط الأخبار" size="lg">
        {review && <Stack>
          {review.conflict && (
            <>
              <Alert color="orange" title="تغيّر الشريط المنشور منذ فتح المسودة">راجع الأخبار الحالية قبل اختيار طريقة النشر.</Alert>
              <Title order={5}>الشريط المنشور الآن</Title>
              <ReviewItems items={review.conflict.items} />
            </>
          )}
          <Title order={5}>المسودة · {number.format(review.draft.items.length)} خبرًا</Title>
          <ReviewItems items={review.draft.items} />
          {!review.draft.items.length && <Alert color="orange">نشر مسودة فارغة سيمسح كل أخبار الشريط.</Alert>}
          {review.draft.scheduledAt && <Alert color="orange">النشر الآن سيُنهي المسودة وموعد نشرها المجدول.</Alert>}
          {error && <Alert color="red" role="alert">{error}</Alert>}
          <Group justify="flex-end">
            {review.conflict ? (
              <>
                <Button variant="default" disabled={busy} onClick={() => void send({ action: 'append', revision: review.draft.revision, review: review.conflict?.review })}>
                  أضف المسودة بعد المنشور
                </Button>
                <Button color="red" disabled={busy} onClick={() => void send({ action: 'replace', revision: review.draft.revision, review: review.conflict?.review })}>
                  استبدل المنشور بالمسودة
                </Button>
              </>
            ) : (
              <Button color="red" loading={busy} onClick={() => void send({ action: 'publish', revision: review.draft.revision })}>نشر الشريط الآن</Button>
            )}
          </Group>
        </Stack>}
      </Modal>
    </Paper>
  )
}
