import { Alert, Button, Group, Skeleton, Stack, Text, TextInput, Title } from '@mantine/core'
import { modals } from '@mantine/modals'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import classes from './NewsroomPage.module.css'

type Draft = Schemas['TickerDraft']
type SavedSet = Schemas['TickerSavedSet']
type SetRequest = Schemas['TickerSetRequest']
const setsKey = ['ticker-sets']
const number = new Intl.NumberFormat('ar')

export function TickerSets({ draft, disabled, onLoad }: {
  draft: Draft | null
  disabled: boolean
  onLoad: () => Promise<unknown>
}) {
  const client = useQueryClient()
  const [name, setName] = useState('')
  const library = useQuery({
    queryKey: setsKey,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/ticker/sets', { signal })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
  })
  const command = useMutation({
    mutationFn: async (request: Pick<SetRequest, 'action'> & Partial<SetRequest>) => {
      await client.cancelQueries({ queryKey: setsKey })
      const { data, error, response } = await api.POST('/api/content/ticker/sets', {
        body: { index: null, revision: null, draftRevision: null, name: null, ...request },
      })
      if (!data) throw new Error(messageFor(errorCode(error, response)))
      return data
    },
    onSuccess: async (data, request) => {
      client.setQueryData(setsKey, data)
      if (request.action === 'save') setName('')
      if (request.action === 'load') await onLoad()
      notifications.show({
        color: 'teal',
        message: request.action === 'delete' ? 'حُذفت المجموعة المحفوظة.'
          : request.action === 'load' ? 'حُمّلت المجموعة في المسودة.'
            : 'حُفظت المجموعة.',
      })
    },
    onError: async () => { await Promise.all([library.refetch(), onLoad()]) },
  })
  const blocked = disabled || command.isPending
  const canSave = !!draft?.items.length && !blocked

  function confirm(action: 'load' | 'replace' | 'delete', item: SavedSet) {
    const title = action === 'load' ? 'تحميل المجموعة في المسودة' : action === 'replace' ? 'تحديث المجموعة من المسودة' : 'حذف المجموعة المحفوظة'
    const detail = action === 'load' ? 'ستحل أخبار هذه المجموعة محل أخبار المسودة الحالية.'
      : action === 'replace' ? 'ستحل أخبار المسودة الحالية محل الأخبار المحفوظة في هذه المجموعة.'
        : 'ستُحذف المجموعة من المكتبة المشتركة.'
    modals.openConfirmModal({
      title,
      children: <Stack gap="xs">
        <Text fw={700} dir="auto">{item.name}</Text>
        <Text size="sm">{detail}</Text>
        {action === 'load' && draft?.scheduledAt && (
          <Alert color="orange" variant="light">موعد نشر المسودة ما زال محددًا. ستُستخدم الأخبار الجديدة عند حلول الموعد.</Alert>
        )}
      </Stack>,
      labels: { confirm: action === 'load' ? 'تحميل المجموعة' : action === 'replace' ? 'تحديث المجموعة' : 'حذف المجموعة', cancel: 'إلغاء' },
      confirmProps: action === 'delete' ? { color: 'red' } : undefined,
      onConfirm: () => command.mutate({ action, index: item.index, revision: item.revision, draftRevision: draft?.revision }),
    })
  }

  return (
    <Stack component="section" id="ticker-sets" aria-labelledby="ticker-sets-title" gap="sm" className={classes.tickerTools}>
      <Group justify="space-between" gap="xs">
        <Title order={5} id="ticker-sets-title">المجموعات المحفوظة</Title>
        {library.data && <Text size="xs" c="dimmed">{number.format(library.data.items.length)} من {number.format(library.data.maxSets)}</Text>}
      </Group>
      {library.isPending && <Skeleton h={44} aria-label="جارٍ تحميل المجموعات" />}
      {(command.error || library.error) && (
        <Alert color="orange" role="alert">
          {(command.error ?? library.error)?.message}
          {library.isError && <Button size="compact-sm" variant="subtle" onClick={() => void library.refetch()}>تحديث المجموعات</Button>}
        </Alert>
      )}
      {library.data && (
        <>
          {draft ? <form onSubmit={(event) => {
            event.preventDefault()
            if (canSave && name.trim()) command.mutate({ action: 'save', name, draftRevision: draft.revision })
          }}>
            <Group align="flex-end" gap="xs">
              <TextInput label="اسم المجموعة الجديدة" dir="rtl" value={name} maxLength={40}
                disabled={!canSave || library.data.items.length >= library.data.maxSets}
                onChange={(event) => setName(event.currentTarget.value)} />
              <Button type="submit" size="sm" disabled={!canSave || !name.trim() || library.data.items.length >= library.data.maxSets}>حفظ المسودة كمجموعة</Button>
            </Group>
          </form> : <Text size="sm" c="dimmed">افتح مسودة لتتمكن من حفظ مجموعة أو تحميلها.</Text>}
          {library.data.items.length === 0 ? <Text size="sm" c="dimmed">لا توجد مجموعات محفوظة.</Text> : (
            <ol className={classes.tickerItems}>
              {library.data.items.map((item) => (
                <li key={item.revision}>
                  <div className={classes.tickerEntry}>
                    <div className={classes.headline}>
                      <Text fw={600} dir="auto">{item.name}</Text>
                      <Text size="xs" c="dimmed">{number.format(item.count)} خبرًا</Text>
                    </div>
                    <Group gap={4}>
                      <Button size="compact-sm" variant="subtle" disabled={blocked || !draft}
                        onClick={() => confirm('load', item)} aria-label={`تحميل المجموعة ${item.name}`}>تحميل</Button>
                      {item.canManage && <Button size="compact-sm" variant="subtle" disabled={!canSave}
                        onClick={() => confirm('replace', item)} aria-label={`تحديث المجموعة ${item.name}`}>تحديث</Button>}
                      {item.canManage && <Button size="compact-sm" variant="subtle" color="red" disabled={blocked}
                        onClick={() => confirm('delete', item)} aria-label={`حذف المجموعة ${item.name}`}>حذف</Button>}
                    </Group>
                  </div>
                </li>
              ))}
            </ol>
          )}
        </>
      )}
    </Stack>
  )
}
