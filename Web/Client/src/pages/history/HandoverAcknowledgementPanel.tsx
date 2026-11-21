import { Alert, Button, Group, Paper, Stack, Text, Title } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

const errors: Record<string, string> = {
  handover_stale: 'انتهت صلاحية هذه الفترة. حدّث التقرير قبل تسجيل التسليم.',
  handover_disabled: 'تسجيل التسليم معطّل حاليًا.',
  handover_unavailable: 'تعذّر تأكيد حفظ التسليم. حدّث التقرير قبل محاولة أخرى.',
}

export function HandoverAcknowledgementPanel({ scope }: { scope: Schemas['HandoverAcknowledgementView'] }) {
  const saved = useMutation({
    mutationFn: async (reference: string) => {
      const { data, error, response } = await api.POST('/api/reports/handover/acknowledge', { body: { reference } })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const latest = saved.data ?? scope.recent
  const currentRecorded = latest?.from === scope.from && latest.through === scope.through

  return (
    <Paper withBorder radius="md" p="md" component="section" aria-labelledby="handover-ack-title">
      <Stack gap="xs">
        <Group justify="space-between">
          <Title order={3} size="h5" id="handover-ack-title">تسجيل التسليم</Title>
          {scope.reference && !currentRecorded && <Button size="xs" loading={saved.isPending}
            onClick={() => { if (scope.reference) saved.mutate(scope.reference) }}>سلّمت المناوبة</Button>}
        </Group>
        <Text size="sm">فترة التقرير من <bdi dir="ltr">{scope.from}</bdi> إلى <bdi dir="ltr">{scope.through}</bdi> بتوقيت المحطة.</Text>
        {latest && <Text size="sm" role="status">
          آخر تسليم لك للفترة من <bdi dir="ltr">{latest.from}</bdi> إلى <bdi dir="ltr">{latest.through}</bdi>
          {'، سُجّل عند '}<bdi dir="ltr">{latest.recordedAt}</bdi>.
        </Text>}
        {saved.error && <Alert color="red" role="alert">
          {errors[saved.error.message] ?? messageFor(saved.error.message)}
        </Alert>}
      </Stack>
    </Paper>
  )
}
