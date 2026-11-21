import { Alert, Button, Group, Modal, Skeleton, Stack, Table, Text } from '@mantine/core'
import { notifications } from '@mantine/notifications'
import { useMutation, useQuery } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

const number = new Intl.NumberFormat('ar')

export function TemplateRehearsal({ template, onClose }: { template: Schemas['TemplateDto']; onClose: () => void }) {
  async function request(action: 'preview' | 'start', review: string | null, signal?: AbortSignal) {
    const { data, error, response } = await api.POST('/api/air/rehearsal', { body: { key: template.key, action, review }, signal })
    if (!data) throw new Error(errorCode(error, response))
    return data
  }
  const preview = useQuery({
    queryKey: ['template-rehearsal', template.key],
    queryFn: ({ signal }) => request('preview', null, signal),
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: false,
  })
  const play = useMutation({
    mutationFn: (token: string) => request('start', token),
    onSuccess: result => {
      if (!result.autoHideFailed) {
        notifications.show({ color: 'teal', message: 'بدأت بروفة القالب على طبقة التجربة.' })
        onClose()
      }
    },
  })
  const plan = preview.data?.preview
  const error = play.error ?? preview.error
  const close = () => { if (!play.isPending) onClose() }

  return (
    <Modal opened title={`بروفة القالب · ${template.name}`} size="lg" onClose={close} withCloseButton={!play.isPending}>
      <Stack gap="md">
        {preview.isFetching && <Stack gap="xs" aria-label="جارٍ التحقق من طبقة التجربة"><Skeleton h={20} /><Skeleton h={42} /></Stack>}
        {plan && <>
          <Group justify="space-between" gap="sm">
            <Text fw={600}>طبقة التجربة {number.format(plan.layer)}</Text>
            <Text size="sm" c="dimmed">الإخفاء التلقائي بعد {number.format(plan.autoHideSeconds)} ثانية</Text>
          </Group>
          {plan.fields.length > 0 && <Table withRowBorders>
            <Table.Thead><Table.Tr><Table.Th scope="col">الحقل</Table.Th><Table.Th scope="col">قيمة التجربة</Table.Th></Table.Tr></Table.Thead>
            <Table.Tbody>{plan.fields.map(({ label, value }, index) => <Table.Tr key={index}>
              <Table.Th scope="row"><Text size="sm" dir="auto" style={{ overflowWrap: 'anywhere' }}>{label}</Text></Table.Th>
              <Table.Td><Text size="sm" dir="auto">{value}</Text></Table.Td>
            </Table.Tr>)}</Table.Tbody>
          </Table>}
        </>}
        {error && <Alert color="orange" role="alert">{messageFor(error.message)}</Alert>}
        {play.data?.autoHideFailed && <Alert color="orange" role="alert">
          أُرسل أمر البروفة وتعذّر تأكيد مؤقّت الإخفاء. تحقّق من طبقة التجربة مباشرةً في Cinegy.
        </Alert>}
        <Group justify="flex-end" gap="xs">
          <Button variant="default" disabled={play.isPending} onClick={close}>{error || play.data ? 'إغلاق' : 'إلغاء'}</Button>
          {error && <Button variant="light" disabled={preview.isFetching} onClick={() => {
            play.reset()
            void preview.refetch()
          }}>إعادة المراجعة</Button>}
          {plan && !error && !play.data && <Button loading={play.isPending} disabled={preview.isFetching}
            onClick={() => play.mutate(plan.review)}>بدء البروفة</Button>}
        </Group>
      </Stack>
    </Modal>
  )
}
