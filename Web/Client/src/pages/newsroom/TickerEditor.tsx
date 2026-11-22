import { ActionIcon, Alert, Button, Group, Menu, Modal, NumberInput, Pagination, Paper, ScrollArea, Stack, Text, Textarea, TextInput, Title } from '@mantine/core'
import { modals } from '@mantine/modals'
import { notifications } from '@mantine/notifications'
import { IconArrowDown, IconArrowUp, IconCalendarTime, IconEdit, IconFolders, IconHistory, IconListNumbers, IconPlayerPause, IconPlus, IconRestore, IconTrash } from '@tabler/icons-react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatDateTime, localDateInput } from '../../lib/time'
import classes from './NewsroomPage.module.css'
import { TickerBackups } from './TickerBackups'
import { TickerPaste } from './TickerPaste'
import { TickerSheet } from './TickerSheet'
import { TickerSets } from './TickerSets'
import { TickerTxt } from './TickerTxt'
import { EditorialSearch, type EditorialOrder } from './EditorialSearch'

type Request = Schemas['TickerDraftRequest']
type Draft = Schemas['TickerDraft']
type Conflict = Schemas['TickerConflict']
type Edit = { revision: string; index: number | null; text: string }
type Review = { draft: Draft; conflict?: Conflict }
type Schedule = { revision: string; time: string }
type Move = { revision: string; index: number; text: string; position: number | string }
const draftKey = ['ticker-draft']
const pageSize = 20
const number = new Intl.NumberFormat('ar')
const alphabet = new Intl.Collator('ar', { sensitivity: 'base', numeric: true })
const searchText = (text: string) => text.normalize('NFKD').replace(/[\p{M}\u0640]/gu, '').toLowerCase().trim()

async function tickerCommand(body: Pick<Request, 'action'> & Partial<Request>) {
  const { data, error, response } = await api.POST('/api/content/ticker/draft', {
    body: { revision: null, index: null, text: null, review: null, publishAtMs: null, pausedPage: null, destination: null, ...body },
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
  const [search, setSearch] = useState('')
  const [order, setOrder] = useState<EditorialOrder>('sequence')
  const [pausedPage, setPausedPage] = useState(1)
  const [showPaused, setShowPaused] = useState(false)
  const [showSets, setShowSets] = useState(false)
  const [showBackups, setShowBackups] = useState(false)
  const [showSheet, setShowSheet] = useState(false)
  const [showPaste, setShowPaste] = useState(false)
  const [showTxt, setShowTxt] = useState(false)
  const [schedule, setSchedule] = useState<Schedule | null>(null)
  const [edit, setEdit] = useState<Edit | null>(null)
  const [move, setMove] = useState<Move | null>(null)
  const [review, setReview] = useState<Review | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [savedMessage, setSavedMessage] = useState('')
  const lastScheduledAt = useRef<string | null>(null)
  const status = useQuery({
    queryKey: [...draftKey, pausedPage],
    queryFn: async ({ signal }) => {
      const { data, error: failure, response } = await api.GET('/api/content/ticker/draft', { signal, params: { query: { pausedPage } } })
      if (!data) throw new Error(errorCode(failure, response))
      return data
    },
    retry: false,
    refetchInterval: ({ state }) => {
      const scheduledAt = state.data?.draft?.scheduledAt
      if (!scheduledAt) return 10_000
      return Math.min(10_000, Math.max(3000, Date.parse(scheduledAt) - Date.now() + 1000))
    },
  })
  const editor = status.data
  const draft = editor?.draft
  const lock = editor?.lock
  const items = draft?.items ?? []
  const needle = searchText(search)
  const matching = items.map((text, index) => ({ text, index }))
    .filter(({ text }) => !needle || searchText(text).includes(needle))
  if (order !== 'sequence') {
    const direction = order === 'title-asc' ? 1 : -1
    matching.sort((left, right) => direction * alphabet.compare(left.text, right.text))
  }
  const pageCount = Math.max(1, Math.ceil(matching.length / pageSize))
  const currentPage = Math.min(page, pageCount)
  const offset = (currentPage - 1) * pageSize
  const destination = typeof move?.position === 'number' && Number.isInteger(move.position) ? move.position - 1 : -1
  const canMove = move && move.revision === draft?.revision && destination >= 0 && destination < items.length && destination !== move.index

  useEffect(() => {
    if (!editor) return
    const previous = lastScheduledAt.current
    lastScheduledAt.current = draft?.scheduledAt ?? null
    if (previous && !lastScheduledAt.current && Date.parse(previous) <= Date.now()) void onPublished()
  }, [editor, draft?.scheduledAt, onPublished])

  async function send(body: Pick<Request, 'action'> & Partial<Request>, addAnother = false) {
    if (busy) return
    setBusy(true)
    setError('')
    setSavedMessage('')
    try {
      await queryClient.cancelQueries({ queryKey: draftKey })
      const updated = await tickerCommand({ ...body, pausedPage })
      const updatedPage = updated.draft?.paused?.page ?? 1
      await queryClient.invalidateQueries({ queryKey: draftKey, refetchType: 'none' })
      queryClient.setQueryData([...draftKey, updatedPage], updated)
      setPausedPage(updatedPage)
      const savedDraft = updated.draft
      setEdit(addAnother && savedDraft && savedDraft.items.length < savedDraft.maxItems
        ? { index: null, text: '', revision: savedDraft.revision } : null)
      if (body.action === 'add' || body.action === 'update') setSavedMessage('حُفظ الخبر في المسودة.')
      if (body.action === 'move' && body.destination != null) {
        setMove(null)
        setSavedMessage(`نُقل الخبر إلى الموضع ${number.format(body.destination + 1)} في المسودة.`)
        if (!needle && order === 'sequence') setPage(Math.floor(body.destination / pageSize) + 1)
      }
      setReview(null)
      setSchedule(null)
      if (body.action === 'start') { setPage(1); setSearch(''); setOrder('sequence') }
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

  function openSchedule(current: Draft) {
    setError('')
    setSchedule({ revision: current.revision, time: localDateInput(new Date(current.scheduledAt ?? Date.now() + 15 * 60_000)) })
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

  function confirmForceRelease(revision: string) {
    modals.openConfirmModal({
      title: 'تحرير قفل المسودة',
      children: <Text size="sm">ستُفتح المسودة للتسلّم مع أخبارها، ويُلغى أي موعد نشر مجدول. إن كان هناك طلب قائم، تُحجز المسودة لصاحبه أولًا.</Text>,
      labels: { confirm: 'تحرير القفل', cancel: 'رجوع' },
      confirmProps: { color: 'orange' },
      onConfirm: () => void send({ action: 'force_release', revision }),
    })
  }

  function confirmDraftRemoval(current: Draft, action: 'clear' | 'discard') {
    const discard = action === 'discard'
    const label = discard ? 'إلغاء المسودة' : 'تفريغ المسودة'
    modals.openConfirmModal({
      title: label,
      children: <Stack gap="xs">
        <Text size="sm">{discard ? 'سيُغلق التحرير وتُحذف المسودة.' : 'ستُحذف أخبار المسودة ويظل التحرير مفتوحًا.'}</Text>
        {current.scheduledAt && <Text size="sm">سيُلغى موعد النشر المجدول.</Text>}
        {current.items.length > 0 && <Button variant="subtle" size="compact-sm" onClick={() => {
          const url = URL.createObjectURL(new Blob([current.items.join('\r\n')], { type: 'text/plain;charset=utf-8' }))
          const link = document.createElement('a')
          link.href = url
          link.download = 'ticker-draft.txt'
          link.click()
          window.setTimeout(() => URL.revokeObjectURL(url), 1000)
        }}>تنزيل نص المسودة</Button>}
      </Stack>,
      labels: { confirm: label, cancel: 'رجوع' },
      confirmProps: { color: 'red' },
      onConfirm: () => void send({ action, revision: current.revision }),
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
      <form key={current.revision} onSubmit={(event) => {
        event.preventDefault()
        if (!current.text.trim()) return
        const submitter = (event.nativeEvent as SubmitEvent).submitter
        void send({ action: current.index === null ? 'add' : 'update', ...current }, submitter?.getAttribute('value') === 'another')
      }}>
        <Stack gap="xs">
          <Textarea
            label={current.index === null ? 'الخبر الجديد' : 'نص الخبر'}
            dir="rtl" autosize minRows={2} maxRows={6} required autoFocus
            maxLength={editor?.maxItemLength}
            value={current.text}
            onChange={(event) => setEdit({ ...current, text: event.currentTarget.value })}
            disabled={busy}
          />
          <Group gap="xs">
            <Button type="submit" size="sm" loading={busy} disabled={!current.text.trim()}>حفظ الخبر</Button>
            {current.index === null && <Button type="submit" value="another" variant="light" size="sm" disabled={busy || !current.text.trim()}>
              حفظ وإضافة خبر آخر
            </Button>}
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
        {!review && !schedule && !move && error && <Alert color="red" role="alert">{error}</Alert>}
        {editor?.state === 'locked' && (
          <Alert color="orange" title="المسودة قيد التحرير">
            <Stack gap="xs">
              <Text size="sm">{editor.owner ? `المسودة مع ${editor.owner} الآن.` : 'المسودة مع محرّر آخر الآن.'}</Text>
              {lock?.waiting && <Text size="sm" role="status">طلبك بانتظار الردّ{lock.expiresAt ? ` حتى ${formatDateTime(lock.expiresAt)}` : ''}.</Text>}
              <Group gap="xs">
                {lock?.canRequest && lock.revision && <Button size="compact-sm" variant="light" loading={busy}
                  onClick={() => void send({ action: 'request_lock', revision: lock.revision })}>طلب تسليم المسودة</Button>}
                {lock?.canForce && lock.revision && <Button size="compact-sm" variant="light" color="orange" disabled={busy}
                  onClick={() => confirmForceRelease(lock.revision!)}>تحرير القفل</Button>}
                <Button variant="subtle" size="compact-sm" onClick={() => void status.refetch()}>تحديث الحالة</Button>
              </Group>
            </Stack>
          </Alert>
        )}
        {draft && lock?.response && (
          <Alert color="blue" title="طلب تسليم المسودة">
            <Stack gap="xs">
              <Text size="sm">{lock.requester || 'محرّر آخر'} يطلب تسلّم المسودة. ستبقى الأخبار فيها إذا وافقت هنا.</Text>
              {draft.scheduledAt && <Text size="sm">سيلغي التسليم موعد النشر المجدول.</Text>}
              {lock.expiresAt && !lock.preservesAtDeadline &&
                <Text size="sm">عند انتهاء مهلة طلب Telegram، تُرسل نسخة الأخبار إلى صاحب المسودة ويُتاح القفل للطالب.</Text>}
              {lock.expiresAt && <Text size="sm">مهلة الردّ {formatDateTime(lock.expiresAt)}.</Text>}
              <Group gap="xs">
                <Button size="compact-sm" loading={busy} onClick={() => void send({ action: 'approve_lock', review: lock.response })}>تسليم المسودة</Button>
                <Button size="compact-sm" variant="default" disabled={busy}
                  onClick={() => void send({ action: 'deny_lock', review: lock.response })}>متابعة التحرير</Button>
              </Group>
            </Stack>
          </Alert>
        )}
        {draft && (
          <>
            {edit?.index === null && editForm(edit)}
            {savedMessage && <Text size="sm" c="teal" role="status">{savedMessage}</Text>}
            {(items.length > 0 || search) && <EditorialSearch label="بحث في المسودة" sequenceLabel="ترتيب الشريط"
              search={search} order={order} disabled={!!edit || busy}
              onSearch={(value) => { setSearch(value); setPage(1) }}
              onOrder={(value) => { setOrder(value); setPage(1) }} />}
            {!matching.length && !edit && <Text size="sm" c="dimmed">
              {needle ? 'لا توجد أخبار تطابق البحث.' : 'المسودة فارغة.'}
            </Text>}
            {!!matching.length && <ol className={classes.tickerItems}>
              {matching.slice(offset, offset + pageSize).map(({ text: item, index }) => {
                return (
                  <li key={index} value={index + 1}>
                    {edit?.index === index ? editForm(edit) : (
                      <div className={classes.tickerEntry}>
                        <Text dir="rtl" className={classes.headline}>{item}</Text>
                        <Group gap={2} wrap="nowrap">
                          <ActionIcon variant="subtle" aria-label={`تعديل الخبر ${index + 1}`} disabled={busy || !!edit}
                            onClick={() => { setError(''); setEdit({ index, text: item, revision: draft.revision }) }}><IconEdit size={16} /></ActionIcon>
                          <ActionIcon variant="subtle" aria-label={`رفع الخبر ${index + 1}`} disabled={busy || !!edit || index === 0}
                            onClick={() => void send({ action: 'up', revision: draft.revision, index })}><IconArrowUp size={16} /></ActionIcon>
                          <ActionIcon variant="subtle" aria-label={`خفض الخبر ${index + 1}`} disabled={busy || !!edit || index + 1 === items.length}
                            onClick={() => void send({ action: 'down', revision: draft.revision, index })}><IconArrowDown size={16} /></ActionIcon>
                          <ActionIcon variant="subtle" title="نقل إلى موضع محدد" aria-label={`نقل الخبر ${index + 1} إلى موضع محدد`}
                            disabled={busy || !!edit || items.length < 2}
                            onClick={() => { setError(''); setMove({ index, position: index + 1, text: item, revision: draft.revision }) }}><IconListNumbers size={16} /></ActionIcon>
                          <ActionIcon variant="subtle" title="إيقاف مؤقتًا" aria-label={`إيقاف الخبر ${index + 1} مؤقتًا`} disabled={busy || !!edit}
                            onClick={() => void send({ action: 'pause', revision: draft.revision, index })}><IconPlayerPause size={16} /></ActionIcon>
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
            </ol>}
            {pageCount > 1 && <Pagination total={pageCount} value={currentPage} onChange={setPage} disabled={!!edit || busy} />}
            <Modal opened={!!move} title="نقل خبر في ترتيب الشريط" onClose={() => { setMove(null); setError('') }}
              closeOnEscape={!busy} closeOnClickOutside={!busy} withCloseButton={!busy}>
              {move && <form onSubmit={(event) => {
                event.preventDefault()
                if (canMove) void send({ action: 'move', index: move.index, revision: move.revision, destination })
              }}>
                <Stack gap="sm">
                  <Text size="sm" dir="rtl">{move.text}</Text>
                  <NumberInput label="الموضع الجديد" min={1} max={items.length} value={move.position} disabled={busy}
                    allowDecimal={false} allowNegative={false} onChange={(position) => setMove({ ...move, position })} />
                  {(error || move.revision !== draft.revision) && <Alert color="red" role="alert">
                    {error || messageFor('ticker_stale')}
                  </Alert>}
                  <Group justify="flex-end">
                    <Button variant="default" disabled={busy} onClick={() => { setMove(null); setError('') }}>إلغاء</Button>
                    <Button type="submit" disabled={!canMove} loading={busy}>نقل الخبر</Button>
                  </Group>
                </Stack>
              </form>}
            </Modal>
            {draft.paused && (draft.paused.total > 0 || showPaused) && (
              <Stack gap="xs" className={classes.tickerTools}>
                <Group justify="space-between" align="center">
                  <Title order={5} size="sm">الأخبار الموقوفة · {number.format(draft.paused.total)}</Title>
                  <Button variant="subtle" size="compact-sm" aria-expanded={showPaused} aria-controls="ticker-paused"
                    onClick={() => setShowPaused(!showPaused)}>{showPaused ? 'طيّ القائمة' : 'عرض الموقوفة'}</Button>
                </Group>
                {showPaused && (
                  <Stack id="ticker-paused" gap="xs">
                    {draft.paused.total === 0 && <Text size="sm" c="dimmed">لا توجد أخبار موقوفة.</Text>}
                    <ol className={classes.tickerItems} start={draft.paused.offset + 1}>
                      {draft.paused.items.map((item, index) => (
                        <li key={draft.paused.offset + index}>
                          <div className={classes.tickerEntry}>
                            <Text dir="auto" className={classes.headline}>{item}</Text>
                            <Button variant="subtle" size="compact-sm" leftSection={<IconRestore size={15} />}
                              aria-label={`إعادة الخبر ${number.format(draft.paused.offset + index + 1)} للمسودة`}
                              disabled={busy || !!edit} onClick={() => void send({
                                action: 'resume', revision: draft.revision, index: draft.paused.offset + index, text: item,
                              })}>إعادة للمسودة</Button>
                          </div>
                        </li>
                      ))}
                    </ol>
                    {draft.paused.pageCount > 1 && <Pagination total={draft.paused.pageCount} value={draft.paused.page}
                      onChange={setPausedPage} disabled={busy || !!edit} aria-label="صفحات الأخبار الموقوفة" />}
                  </Stack>
                )}
              </Stack>
            )}
            {draft.scheduledAt && (
              <Group justify="space-between" className={classes.tickerTools}>
                <Text size="sm">موعد النشر <bdi>{formatDateTime(draft.scheduledAt)}</bdi></Text>
                <Button variant="subtle" size="compact-sm" disabled={busy || !!edit}
                  onClick={() => void send({ action: 'unschedule', revision: draft.revision })}>إلغاء الموعد</Button>
              </Group>
            )}
            <Group justify="space-between">
              <Group gap="xs">
                <Button variant="default" disabled={busy || !!edit} onClick={() => setShowPaste(true)}>لصق أخبار</Button>
                <Menu position="bottom-start">
                  <Menu.Target><Button variant="default" disabled={busy || !!edit}>خيارات المسودة</Button></Menu.Target>
                  <Menu.Dropdown>
                    <Menu.Item onClick={() => setShowTxt(true)}>استيراد ملف TXT</Menu.Item>
                    <Menu.Item onClick={() => confirmHandover(draft)}>تسليم المسودة</Menu.Item>
                    {draft.canClear && items.length > 0 && <Menu.Item color="red" onClick={() => confirmDraftRemoval(draft, 'clear')}>تفريغ المسودة</Menu.Item>}
                    <Menu.Item color="red" onClick={() => confirmDraftRemoval(draft, 'discard')}>إلغاء المسودة</Menu.Item>
                  </Menu.Dropdown>
                </Menu>
              </Group>
              <Group gap="xs">
                <Button variant="default" leftSection={<IconCalendarTime size={17} />} disabled={busy || !!edit}
                  onClick={() => openSchedule(draft)}>{draft.scheduledAt ? 'تغيير الموعد' : 'جدولة النشر'}</Button>
                <Button color="red" variant="light" disabled={busy || !!edit} onClick={() => { setError(''); setReview({ draft }) }}>مراجعة النشر</Button>
              </Group>
            </Group>
          </>
        )}
        {editor && (
          <>
            <Group>
              <Button variant="default" size="sm" leftSection={<IconFolders size={17} aria-hidden />}
                aria-expanded={showSets} aria-controls={showSets ? 'ticker-sets' : undefined}
                onClick={() => setShowSets(!showSets)}>مجموعات الشريط</Button>
              {editor.canRestore && <Button variant="default" size="sm" leftSection={<IconHistory size={17} aria-hidden />}
                aria-expanded={showBackups} aria-controls={showBackups ? 'ticker-backups' : undefined}
                onClick={() => setShowBackups(!showBackups)}>النسخ الاحتياطية</Button>}
              {editor.canPullSheet && <Button variant="default" size="sm"
                aria-expanded={showSheet} aria-controls={showSheet ? 'ticker-sheet' : undefined}
                onClick={() => setShowSheet(!showSheet)}>Google Sheets</Button>}
            </Group>
            {showSets && <TickerSets draft={draft ?? null} disabled={busy || !!edit}
              onLoad={() => queryClient.invalidateQueries({ queryKey: draftKey })} />}
            {editor.canRestore && showBackups && <TickerBackups disabled={busy || !!edit}
              onRestored={() => Promise.all([onPublished(), queryClient.invalidateQueries({ queryKey: draftKey })])} />}
            {editor.canPullSheet && showSheet && <TickerSheet disabled={busy || !!edit}
              onApplied={(target) => Promise.all([
                queryClient.invalidateQueries({ queryKey: draftKey }),
                target === 'air' ? onPublished() : Promise.resolve(),
              ])} />}
          </>
        )}
      </Stack>
      {draft && showPaste && <TickerPaste draft={draft} onClose={() => setShowPaste(false)}
        onCommand={(body) => tickerCommand({ ...body, pausedPage })}
        onRefresh={() => queryClient.invalidateQueries({ queryKey: draftKey })} />}
      {draft && showTxt && <TickerTxt draft={draft} onClose={() => setShowTxt(false)}
        onRefresh={() => queryClient.invalidateQueries({ queryKey: draftKey }, { throwOnError: true })} />}
      <Modal opened={!!schedule} onClose={() => { if (!busy) { setSchedule(null); setError('') } }} title="جدولة نشر شريط الأخبار">
        {schedule && <form onSubmit={(event) => {
          event.preventDefault()
          const date = new Date(schedule.time)
          if (!Number.isFinite(date.getTime()) || localDateInput(date) !== schedule.time || date.getTime() <= Date.now()) {
            setError(messageFor('ticker_schedule_invalid'))
            return
          }
          void send({ action: 'schedule', revision: schedule.revision, publishAtMs: date.getTime() })
        }}>
          <Stack gap="sm">
            <Text size="sm">ستُنشر النسخة المحفوظة من المسودة عند حلول الموعد. يمكنك تعديل الأخبار حتى ذلك الوقت.</Text>
            {!items.length && <Alert color="orange">قد يمسح النشر أخبار الشريط إذا بقيت المسودة فارغة.</Alert>}
            <TextInput type="datetime-local" label="موعد النشر بتوقيت جهازك" required autoFocus dir="ltr"
              value={schedule.time} onChange={(event) => setSchedule({ ...schedule, time: event.currentTarget.value })} />
            {error && <Alert color="red" role="alert">{error}</Alert>}
            <Group justify="flex-end">
              <Button type="submit" loading={busy}>حفظ الموعد</Button>
            </Group>
          </Stack>
        </form>}
      </Modal>
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
