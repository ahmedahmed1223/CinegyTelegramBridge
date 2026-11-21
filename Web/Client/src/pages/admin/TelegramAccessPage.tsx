import { Alert, Badge, Button, Divider, Group, Modal, Pagination, Paper, Skeleton, Stack, Text, Title } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { IconRefresh } from '@tabler/icons-react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, roleLabel, sessionKey, useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'
import { formatDateTime } from '../../lib/time'

import { SuspendedTelegramOperators, TelegramSuspensionButton } from './TelegramSuspension'
import { TelegramAliasButton } from './TelegramAliasButton'
import { TelegramOperatorActivityButton } from './TelegramOperatorActivityButton'
import { TelegramPresenceButton } from './TelegramPresenceButton'
import { TelegramAccessHistory } from './TelegramAccessHistory'
import { BlockedTelegramChats } from './BlockedTelegramChats'
import { TelegramDeliveryQuarantine } from './TelegramDeliveryQuarantine'
import { TelegramRevokeButton } from './TelegramRevokeButton'

const requestsKey = ['telegram-access', 'requests'] as const
const accountsKey = ['accounts'] as const
const pageSize = 12
const pageControlLabel = { first: 'الصفحة الأولى', previous: 'الصفحة السابقة', next: 'الصفحة التالية', last: 'الصفحة الأخيرة' }

type AccessRequest = Schemas['TelegramAccessItem']
type AccessReview = Schemas['TelegramAccessReview']
type BridgeUser = Schemas['BridgeUserResponse']
type Decision = 'approve' | 'deny'
type EditableRole = 'operator' | 'admin'
type Change =
  | { kind: 'decision'; chatId: number; decision: Decision; review: AccessReview }
  | { kind: 'role'; user: BridgeUser; expectedRole: EditableRole; role: EditableRole }

function accessMessage(code: string) {
  switch (code) {
    case 'access_request_stale': return 'انتهت صلاحية الطلب أو تغيّر. افتح الطلب الحالي وراجعه من جديد.'
    case 'access_role_stale': return 'تغيّر دور المستخدم. راجع دوره الحالي قبل المحاولة من جديد.'
    case 'access_role_refused': return 'تعذّر تغيير الدور. تحقّق من أن للجسر مشرفًا آخر ومن أن المستخدم ما زال ضمن قائمة الوصول.'
    case 'owner_only': return 'تغيير أدوار المشرفين للمالك وحده.'
    default: return messageFor(code)
  }
}

function requestName(request: AccessRequest) {
  return request.name.trim() || 'اسم غير متاح'
}

function TelegramId({ value }: { value: number }) {
  return <Text span size="sm" c="dimmed" className="cgb-mono" dir="ltr">{value}</Text>
}

function RequestDetails({ request }: { request: AccessRequest }) {
  return (
    <Stack gap={3} style={{ minWidth: 0, overflowWrap: 'anywhere' }}>
      <Text fw={600}><bdi>{requestName(request)}</bdi></Text>
      <Group gap="sm">
        <Text size="sm" c="dimmed">معرّف المستخدم <TelegramId value={request.userId} /></Text>
        {request.chatId !== request.userId && <Text size="sm" c="dimmed">معرّف المحادثة <TelegramId value={request.chatId} /></Text>}
      </Group>
      <Group gap="sm">
        <Text size="sm" c="dimmed">أُرسل في {formatDateTime(request.requestedAt)}</Text>
        <Text size="sm" c="dimmed">ينتهي في {formatDateTime(request.expiresAt)}</Text>
      </Group>
    </Stack>
  )
}

export function TelegramAccessPage({ embedded = false }: { embedded?: boolean }) {
  const session = useSession()
  const client = useQueryClient()
  const canManage = isAdmin(session.data)
  const isOwner = session.data?.role === 'owner'
  const [page, setPage] = useState(0)
  const [change, setChange] = useState<Change | null>(null)
  const requests = useQuery({
    queryKey: [...requestsKey, session.data?.id, page],
    enabled: canManage,
    refetchInterval: 15_000,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/telegram-access/requests', {
        params: { query: { page, pageSize } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const roster = useQuery({
    queryKey: accountsKey,
    enabled: canManage,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/accounts', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })

  function refreshAccess() {
    return Promise.all([
      client.invalidateQueries({ queryKey: requestsKey }),
      client.invalidateQueries({ queryKey: ['telegram-access', 'history'] }),
      client.invalidateQueries({ queryKey: accountsKey }),
    ])
  }

  function reportFailure(error: Error) {
    notifications.show({ color: 'red', message: accessMessage(error.message) })
    void refreshAccess()
    if (['unauthorized', 'forbidden', 'owner_only'].includes(error.message)) {
      void client.invalidateQueries({ queryKey: sessionKey })
    }
  }

  const reviewing = useMutation({
    mutationFn: async ({ chatId, decision }: { chatId: number; decision: Decision }): Promise<Change> => {
      const { data, error, response } = await api.POST('/api/telegram-access/requests/{chatId}/review', {
        params: { path: { chatId } },
        body: { decision },
      })
      if (!data) throw new Error(errorCode(error, response))
      return { kind: 'decision', chatId, decision, review: data }
    },
    onSuccess: setChange,
    onError: reportFailure,
  })
  const saving = useMutation({
    mutationFn: async (selected: Change) => {
      if (selected.kind === 'decision') {
        const { data, error, response } = await api.POST('/api/telegram-access/requests/{chatId}/decision', {
          params: { path: { chatId: selected.chatId } },
          body: { decision: selected.decision, review: selected.review.review },
        })
        if (!data) throw new Error(errorCode(error, response))
        return selected.decision === 'approve' ? 'مُنح المستخدم صلاحية الدخول إلى الجسر.' : 'رُفض طلب الوصول.'
      }
      const { data, error, response } = await api.PUT('/api/telegram-access/users/{userId}/role', {
        params: { path: { userId: selected.user.id } },
        body: { role: selected.role, expectedRole: selected.expectedRole },
      })
      if (!data) throw new Error(errorCode(error, response))
      return 'تغيّر دور المستخدم.'
    },
    onSuccess: async (message) => {
      setChange(null)
      notifications.show({ color: 'green', message })
      await refreshAccess()
    },
    onError: (error) => {
      setChange(null)
      reportFailure(error)
    },
  })

  if (session.isPending) return <Skeleton h={120} />
  if (!canManage) return embedded ? null : <Alert color="red">{accessMessage('forbidden')}</Alert>

  const users = roster.data?.bridgeUsers.filter((user) => !user.webOnly)
  const pending = requests.data
  const pageCount = pending ? Math.ceil(pending.total / pending.pageSize) : 0
  const busy = reviewing.isPending || saving.isPending
  const isDenial = change?.kind === 'decision' && change.decision === 'deny'
  const confirmLabel = change?.kind === 'role' ? 'تأكيد تغيير الدور' : isDenial ? 'تأكيد الرفض' : 'تأكيد الموافقة'

  return (
    <Stack gap="lg" dir="rtl">
      {!embedded && <PageHeader title="الوصول عبر Telegram" />}

      <Paper withBorder radius="lg" p="md">
        <Stack gap="md">
          <Group justify="space-between">
            <Group gap="xs">
              <Title order={2} size="h4">طلبات الوصول</Title>
              {pending && <Badge variant="light" color="signal" aria-label={`${pending.total} طلب وصول`}>{pending.total}</Badge>}
            </Group>
            <Button variant="default" size="xs" leftSection={<IconRefresh size={15} />}
              disabled={busy} loading={requests.isFetching} onClick={() => void requests.refetch()}>تحديث</Button>
          </Group>
          {requests.isError && <Alert color="red" role="alert">{accessMessage(requests.error.message)}</Alert>}
          {requests.isPending && <Skeleton h={76} />}
          {!requests.isError && pending && (
            pending.requests.length === 0 ? <Text c="dimmed" size="sm">لا توجد طلبات وصول معلّقة.</Text> : (
              <>
                <Stack gap="sm">
                  {pending.requests.map((request) => (
                    <Paper key={request.chatId} withBorder p="sm" radius="md">
                      <Group justify="space-between" align="center" gap="sm">
                        <RequestDetails request={request} />
                        <Group gap="xs">
                          <Button size="compact-sm" variant="light"
                            aria-label={`مراجعة الموافقة على طلب ${requestName(request)}`}
                            disabled={busy} loading={reviewing.isPending && reviewing.variables?.chatId === request.chatId && reviewing.variables.decision === 'approve'}
                            onClick={() => reviewing.mutate({ chatId: request.chatId, decision: 'approve' })}>موافقة</Button>
                          <Button size="compact-sm" variant="subtle" color="red"
                            aria-label={`مراجعة رفض طلب ${requestName(request)}`}
                            disabled={busy} loading={reviewing.isPending && reviewing.variables?.chatId === request.chatId && reviewing.variables.decision === 'deny'}
                            onClick={() => reviewing.mutate({ chatId: request.chatId, decision: 'deny' })}>رفض</Button>
                        </Group>
                      </Group>
                    </Paper>
                  ))}
                </Stack>
                {pageCount > 1 && <Pagination total={pageCount} value={pending.page + 1} disabled={busy}
                  getItemProps={(number) => ({ 'aria-label': `الصفحة ${number}` })}
                  getControlProps={(control) => ({ 'aria-label': pageControlLabel[control] })}
                  onChange={(next) => setPage(next - 1)} />}
              </>
            )
          )}
        </Stack>
      </Paper>

      <Paper withBorder radius="lg" p="md">
        <Stack gap="md">
          <Group justify="space-between">
            <Title order={2} size="h4">أدوار مستخدمي Telegram</Title>
            {session.data?.id != null && <TelegramPresenceButton accountId={session.data.id} />}
          </Group>
          {roster.isError && <Alert color="red" role="alert">{accessMessage(roster.error.message)}</Alert>}
          {roster.isPending && <Skeleton h={76} />}
          {!roster.isError && users?.length === 0 && <Text size="sm" c="dimmed">لا يوجد مستخدمو Telegram في قائمة الوصول.</Text>}
          {!roster.isError && users && users.length > 0 && (
            <Stack gap="xs">
              {users.map((user, index) => {
                const expectedRole = user.role === 'operator' || user.role === 'admin' ? user.role : null
                const nextRole = expectedRole === 'admin' ? 'operator' : 'admin'
                return (
                  <Stack key={user.id} gap="xs">
                    {index > 0 && <Divider />}
                    <Group justify="space-between" gap="sm">
                      <Group gap="sm" style={{ overflowWrap: 'anywhere', minWidth: 0 }}>
                        <Text fw={600}><bdi>{user.name}</bdi></Text>
                        <TelegramId value={user.id} />
                        <Badge variant="light" color={user.role === 'operator' ? 'gray' : 'signal'}>{roleLabel[user.role] ?? user.role}</Badge>
                      </Group>
                      <Group gap="xs">
                        <TelegramRevokeButton user={user} disabled={busy} />
                        {user.role === 'operator' && <TelegramSuspensionButton user={user} suspend busy={busy} />}
                        {user.role === 'operator' && <TelegramAliasButton user={user} busy={busy} />}
                        {user.role === 'operator' && <TelegramOperatorActivityButton user={user} />}
                        {isOwner && expectedRole && <Button variant="default" size="compact-sm" disabled={busy}
                        aria-label={`تغيير دور ${user.name} إلى ${roleLabel[nextRole]}`}
                        onClick={() => setChange({ kind: 'role', user, expectedRole, role: nextRole })}>
                          {nextRole === 'admin' ? 'ترقية إلى مشرف' : 'إعادة إلى مشغّل'}
                        </Button>}
                      </Group>
                    </Group>
                  </Stack>
                )
              })}
            </Stack>
          )}
        </Stack>
      </Paper>

      <BlockedTelegramChats />
      <TelegramDeliveryQuarantine />
      <SuspendedTelegramOperators />
      <TelegramAccessHistory />
      <Modal opened={change !== null} centered title={confirmLabel}
        closeOnClickOutside={!saving.isPending} closeOnEscape={!saving.isPending} withCloseButton={!saving.isPending}
        closeButtonProps={{ 'aria-label': 'إغلاق' }} onClose={() => setChange(null)}>
        {change && <Stack gap="md" dir="rtl">
          {change.kind === 'decision' ? (
            <>
              <RequestDetails request={change.review.request} />
              <Text size="sm">{isDenial ? 'سيصل إلى المستخدم إشعار برفض طلبه.' : 'سيُمنح المستخدم صلاحية الدخول إلى الجسر بصفة مشغّل.'}</Text>
              {isDenial && change.review.rejectionBlocks && <Alert color="orange">
                سيحظر الجسر هذه المحادثة بعد الرفض. لن يتمكّن صاحبها من تقديم طلب جديد ما دام الحظر قائمًا.
              </Alert>}
            </>
          ) : (
            <Text size="sm">
              تغيير دور <bdi>{change.user.name}</bdi> (<TelegramId value={change.user.id} />)
              {' '}من «{roleLabel[change.expectedRole]}» إلى «{roleLabel[change.role]}».
            </Text>
          )}
          <Group justify="flex-end" gap="xs">
            <Button variant="default" disabled={saving.isPending} onClick={() => setChange(null)}>إلغاء</Button>
            <Button color={isDenial ? 'red' : undefined} loading={saving.isPending}
              disabled={change.kind === 'role' && !isOwner} onClick={() => saving.mutate(change)}>{confirmLabel}</Button>
          </Group>
        </Stack>}
      </Modal>
    </Stack>
  )
}
