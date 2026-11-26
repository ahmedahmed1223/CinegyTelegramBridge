import { AdjustableRow, AdjustableTable } from '../../components/AdjustableTable'
import { Alert, Button, Group, Pagination, Paper, Select, Skeleton, Stack, Switch, Table, Text, Title } from '@mantine/core'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'

const personalKey = ['shift-notices', 'personal'] as const
const rulesKey = ['shift-notices', 'rules'] as const
const scopes = [
  { value: 'none', label: 'لا أحد' },
  { value: 'admins', label: 'المشرفون' },
  { value: 'all', label: 'جميع المشغّلين المصرّح لهم' },
]
const noticesMessages: Readonly<Record<string, string>> = {
  notices_invalid: 'إعداد التنبيه غير صالح.',
  notices_no_telegram: 'لا يستقبل هذا الحساب تنبيهات تيليجرام.',
  notices_stale: 'تغيّر الإعداد أثناء فتح الصفحة. حدّثه ثم أعد المحاولة.',
  notices_template_gone: 'القالب لم يعد موجودًا في الكتالوج.',
  notices_save_failed: 'تعذّر حفظ إعداد التنبيه.',
}

function noticeMessage(error: Error) {
  return noticesMessages[error.message] ?? messageFor(error.message)
}

function PersonalNotices({ actor }: { actor: number }) {
  const queryClient = useQueryClient()
  const key = [...personalKey, actor] as const
  const [saved, setSaved] = useState(false)
  const personal = useQuery({
    queryKey: key,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/notices/me', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const update = useMutation({
    mutationFn: async (body: Schemas['PersonalAirNoticeChange']) => {
      const { data, error, response } = await api.PUT('/api/notices/me', { body })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (result) => {
      queryClient.setQueryData(key, result)
      setSaved(true)
    },
    onError: () => void queryClient.invalidateQueries({ queryKey: key }),
  })
  const data = personal.data
  const error = update.error ?? personal.error
  return (
    <Paper p="md" withBorder>
      <Stack gap="sm">
        <Group justify="space-between">
          <Title order={3} size="h4">تنبيهاتي</Title>
          {personal.isError && <Button variant="subtle" size="compact-sm" onClick={() => void personal.refetch()}>إعادة التحميل</Button>}
        </Group>
        {personal.isPending && <Skeleton h={65} aria-label="جارٍ تحميل إعداد التنبيهات" />}
        {data && !data.telegramAvailable && <Text size="sm" c="dimmed">تصل تنبيهات هذا الحساب داخل الويب.</Text>}
        {data?.telegramAvailable && typeof data.muted === 'boolean' && (
          <Switch label="استقبال تنبيهات عرض القوالب ورفعها" checked={!data.muted}
            description="قد تصلك تنبيهات التعارض أثناء تجهيز قالب على الهواء حتى إذا كتمت تنبيهات العرض."
            disabled={update.isPending || personal.isFetching}
            onChange={(event) => {
              setSaved(false)
              update.mutate({ muted: !event.currentTarget.checked, expectedMuted: data.muted })
            }} />
        )}
        {saved && <Text size="sm" role="status">حُفظ إعداد التنبيه.</Text>}
        {data?.events && <>
          <Title order={4} size="sm">تنبيهات الهواء خلال آخر دقيقتين</Title>
          {data.events.length === 0 && <Text size="sm" c="dimmed">لا توجد تنبيهات حديثة لهذا الحساب.</Text>}
          {data.events.slice().reverse().map(event => <Text key={event.id} size="sm">
            {new Date(event.at).toLocaleTimeString('ar')} · {event.action === 'SHOW' ? 'عرض' : event.action === 'HIDE' ? 'إخفاء' : 'خروج'} · <bdi>{event.key}</bdi> · الطبقة {event.layer}
          </Text>)}
        </>}
        {error && <Alert color="orange" role="alert">{noticeMessage(error)}</Alert>}
      </Stack>
    </Paper>
  )
}

function TemplateNoticeRules() {
  const [page, setPage] = useState(0)
  const [saved, setSaved] = useState(false)
  const queryClient = useQueryClient()
  const rules = useQuery({
    queryKey: [...rulesKey, page],
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/notices/template-rules', { params: { query: { page } }, signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const update = useMutation({
    mutationFn: async ({ key, body }: { key: string; body: Schemas['TemplateAirNoticeChange'] }) => {
      const { data, error, response } = await api.PUT('/api/notices/template-rules/{key}', { params: { path: { key } }, body })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onSuccess: (result) => {
      queryClient.setQueryData([...rulesKey, result.page], result)
      setPage(result.page)
      setSaved(true)
    },
    onError: () => void queryClient.invalidateQueries({ queryKey: rulesKey }),
  })
  const data = rules.data
  const error = update.error ?? rules.error
  return (
    <Paper p="md" withBorder>
      <Stack gap="sm">
        <Group justify="space-between">
          <Title order={3} size="h4">تنبيهات القوالب للمحطة</Title>
          {rules.isError && <Button variant="subtle" size="compact-sm" onClick={() => void rules.refetch()}>إعادة التحميل</Button>}
        </Group>
        <Text size="sm" c="dimmed">حدّد من يصله تنبيه تيليجرام عند عرض كل قالب أو رفعه من الهواء.</Text>
        {rules.isPending && <Skeleton h={105} aria-label="جارٍ تحميل قواعد تنبيهات القوالب" />}
        {saved && <Text size="sm" role="status">حُفظت قاعدة تنبيه القالب.</Text>}
        {error && <Alert color="orange" role="alert">{noticeMessage(error)}</Alert>}
        {data?.items.length === 0 && <Text size="sm" c="dimmed">لا توجد قوالب مسجّلة.</Text>}
        {data && data.items.length > 0 && (
          <AdjustableTable layoutKey="shift-notices" label="قواعد تنبيه القوالب" verticalSpacing="xs" columns={[
            { id: 'template', label: 'القالب', width: 185 },
            { id: 'recipients', label: 'مَن يستقبل التنبيه', width: 270, minWidth: 240 },
          ]}>
            <Table.Tbody>
              {data.items.map((item) => (
                <AdjustableRow key={item.key}>
                  <Table.Td><bdi dir="auto">{item.key}</bdi></Table.Td>
                  <Table.Td>
                    <Select aria-label={`تنبيه قالب ${item.key}`} size="sm" data={scopes} value={item.scope} allowDeselect={false}
                      disabled={!item.canChange || update.isPending || rules.isFetching}
                      onChange={(scope) => {
                        if (!scope || scope === item.scope) return
                        setSaved(false)
                        update.mutate({ key: item.key, body: { scope, expectedScope: item.scope, page: data.page } })
                      }} />
                    {!item.canChange && <Text size="xs" c="dimmed">اسم القالب غير صالح في قواعد التنبيه.</Text>}
                  </Table.Td>
                </AdjustableRow>
              ))}
            </Table.Tbody>
          </AdjustableTable>
        )}
        {data && data.pageCount > 1 && <Pagination total={data.pageCount} value={data.page + 1} disabled={update.isPending}
          onChange={(next) => { setSaved(false); update.reset(); setPage(next - 1) }} />}
      </Stack>
    </Paper>
  )
}

export function ShiftNoticesPage() {
  const user = useSession().data
  if (!user) return null
  return (
    <Stack gap="lg" dir="rtl" key={user.id}>
      <Title order={2}>التنبيهات</Title>
      <PersonalNotices actor={user.id} />
      {isAdmin(user) && <TemplateNoticeRules />}
    </Stack>
  )
}
