import { Alert, Button, Group, Modal, Skeleton, Stack, Table, Text } from '@mantine/core'
import { useMutation, useQuery } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

const number = new Intl.NumberFormat('ar')
export type BoardAirResult = Schemas['ProgrammeBoardAirResult']
export type BoardAirTarget = { action: 'show' | 'hide' | 'update'; rowId: string; revision: number; values?: Record<string, string> }

export function ProgrammeBoardPlayout({ id, target, onClose, onChanged }: {
  id: string
  target: BoardAirTarget
  onClose: () => void
  onChanged: (result?: BoardAirResult) => void
}) {
  const hiding = target.action === 'hide'
  const updating = target.action === 'update'
  const title = { show: 'مراجعة عرض صف البرنامج', hide: 'مراجعة إخفاء صف البرنامج', update: 'مراجعة التصحيح على الهواء' }[target.action]
  const confirmation = { show: 'عرض الصف على الهواء', hide: 'تأكيد إخفاء الصف', update: 'تطبيق التصحيح على الهواء' }[target.action]
  async function request(action: string, review: string | null, signal?: AbortSignal) {
    const { data, error, response } = await api.POST('/api/content/boards/air', {
      body: { id, revision: target.revision, rowId: target.rowId, action, review, values: target.values ?? null },
      signal,
    })
    if (!data) throw new Error(errorCode(error, response))
    return data
  }
  const review = useQuery({
    queryKey: ['programme-board-air', id, target.revision, target.rowId, target.action],
    queryFn: ({ signal }) => request(`${target.action}-preview`, null, signal),
    gcTime: 0,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: false,
  })
  const apply = useMutation({
    mutationFn: (token: string) => request(target.action, token),
    onSuccess: (result) => onChanged(result),
    onError: () => onChanged(),
  })
  const preview = review.data?.preview
  const error = apply.error ?? review.error
  const close = () => { if (!apply.isPending) onClose() }

  return (
    <Modal opened onClose={close} size="lg" title={title}>
      <Stack gap="md">
        {review.isFetching && <Stack gap="xs" aria-label="جارٍ التحقق من الطبقة">
          <Skeleton height={20} width="55%" />
          <Skeleton height={44} />
        </Stack>}
        {preview && <>
          <Group justify="space-between" gap="xs">
            <Text fw={600} dir="auto">{preview.template}</Text>
            <Text size="sm" c="dimmed">الطبقة {number.format(preview.layer)}</Text>
          </Group>
          {!!preview.fields.length && <Table withRowBorders>
            <Table.Tbody>
              {preview.fields.map(({ label, value }, index) => <Table.Tr key={index}>
                <Table.Th scope="row" w="36%"><Text size="sm" fw={600} dir="auto" style={{ overflowWrap: 'anywhere' }}>{label}</Text></Table.Th>
                <Table.Td><Text size="sm" dir="auto" style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{value || '—'}</Text></Table.Td>
              </Table.Tr>)}
            </Table.Tbody>
          </Table>}
          {preview.replacesGraphic && <Alert color="orange">
            سيحل هذا الصف محل المشهد المعروض{preview.graphicName ? ` «${preview.graphicName}»` : ''} على الطبقة.
          </Alert>}
          {(preview.stopsUrgent || preview.stopsBulletin) && <Alert color="orange">
            {preview.stopsUrgent && <Text size="sm">سيتوقف عرض جدول العواجل.</Text>}
            {preview.stopsBulletin && <Text size="sm">سيتوقف عرض الموجز.</Text>}
          </Alert>}
          {!!preview.autoHideSeconds && <Text size="sm" c="dimmed">الإخفاء التلقائي بعد {number.format(preview.autoHideSeconds)} ثانية.</Text>}
          {hiding && <Text size="sm">سيُخفى المشهد الجاري على هذه الطبقة بعد التحقق من هويته.</Text>}
          {updating && <Text size="sm">يُطبّق التصحيح على نص العرض الحالي فور تأكيده.</Text>}
        </>}
        {error && <Alert color="orange" role="alert">
          {error.message === 'board_stale' ? 'تغيّر الصف أو المشهد منذ فتح المراجعة. حدّث اللوحة وافتح مراجعة جديدة.' : messageFor(error.message)}
        </Alert>}
        <Group justify="flex-end">
          <Button variant="default" disabled={apply.isPending} onClick={close}>{updating ? 'رجوع إلى الحقول' : error ? 'إغلاق' : 'إلغاء'}</Button>
          {preview && !error && <Button color="red.9" loading={apply.isPending} disabled={review.isFetching}
            onClick={() => apply.mutate(preview.review)}>
            {confirmation}
          </Button>}
        </Group>
      </Stack>
    </Modal>
  )
}
