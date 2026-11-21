import { Alert, Button, Group, Paper, SimpleGrid, Stack, Text, Title } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatClock, formatDateTime } from '../../lib/time'

export function ProgrammeNowNextPanel({ disabled }: { disabled: boolean }) {
  const reading = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/status/programme')
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const snapshot = reading.data
  return (
    <Paper withBorder p="md" radius="md" component="section" aria-labelledby="programme-status">
      <Stack gap="sm">
        <Group justify="space-between">
          <Title order={2} size="h4" id="programme-status">الآن والتالي</Title>
          <Button variant="default" disabled={disabled} loading={reading.isPending} onClick={() => reading.mutate()}>
            {snapshot ? 'تحديث القراءة' : 'قراءة حالة المواد'}
          </Button>
        </Group>
        <Stack gap="xs" aria-live="polite" aria-busy={reading.isPending}>
          {reading.error && (
            <Alert color="red">{reading.error.message === 'layer_comparison_busy'
              ? 'تجري قراءة من محرك البث. أعد المحاولة بعد لحظة.'
              : messageFor(reading.error.message)}</Alert>
          )}
          {snapshot && (
            <>
              {snapshot.statusAvailable ? (
                <SimpleGrid cols={{ base: 1, sm: 2 }}>
                  <ProgrammeItem title="يُعرض الآن" item={snapshot.current} scheduleAvailable={snapshot.scheduleAvailable} />
                  <ProgrammeItem title="التالي المجهّز" item={snapshot.cued} scheduleAvailable={snapshot.scheduleAvailable} />
                </SimpleGrid>
              ) : <Text size="sm" c="dimmed">تعذّرت قراءة المواد من Cinegy.</Text>}
              <Text size="xs" c="dimmed">{disabled ? 'آخر قراءة' : 'وقت القراءة'} · {formatDateTime(snapshot.checkedAtMs)}</Text>
            </>
          )}
        </Stack>
      </Stack>
    </Paper>
  )
}

function ProgrammeItem({ title, item, scheduleAvailable }: {
  title: string
  item: Schemas['ProgrammeStatusItem'] | null | undefined
  scheduleAvailable: boolean
}) {
  const label = item?.listed ? item.label || 'مادة بلا تسمية متاحة'
    : item ? (scheduleAvailable ? 'مادة غير مدرجة في الجدول' : 'تعذّرت مطابقة المادة بالجدول')
      : 'لم يبلّغ Cinegy عن مادة'
  return (
    <Stack gap={4}>
      <Text size="sm" c="dimmed">{title}</Text>
      <Text fw={600} style={{ overflowWrap: 'anywhere' }}>{label}</Text>
      {!!item?.startsAtMs && <Text size="xs">البداية في الجدول · {formatDateTime(item.startsAtMs)}</Text>}
      {item?.remainingSeconds != null && (
        <Text size="xs">المتبقي وفق الجدول عند القراءة · <bdi>{formatClock(item.remainingSeconds * 1000)}</bdi></Text>
      )}
    </Stack>
  )
}
