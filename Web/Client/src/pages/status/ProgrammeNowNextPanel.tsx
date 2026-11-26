import { Alert, Button, Group, Paper, SimpleGrid, Skeleton, Stack, Text, Title } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { IconRefresh } from '@tabler/icons-react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatClock, formatDateTime } from '../../lib/time'

export function ProgrammeNowNextPanel({ disabled }: { disabled: boolean }) {
  const reading = useQuery<Schemas['ProgrammeNowNext']>({
    queryKey: ['air-programme'],
    enabled: !disabled,
    retry: false,
    refetchInterval: ({ state }) => !disabled && !['forbidden', 'unauthorized'].includes(state.error?.message ?? '') ? 15_000 : false,
    refetchIntervalInBackground: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/status/programme', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const snapshot = reading.data
  return (
    <Paper withBorder p="md" radius="md" component="section" aria-labelledby="programme-status">
      <Stack gap="sm">
        <Group justify="space-between">
          <Title order={2} size="h4" id="programme-status">قائمة التشغيل · الآن والتالي</Title>
          <Button variant="default" size="sm" leftSection={<IconRefresh size={16} aria-hidden />} disabled={disabled}
            loading={reading.isFetching} onClick={() => void reading.refetch()}>
            تحديث القراءة
          </Button>
        </Group>
        <Stack gap="xs">
          {!snapshot && reading.isFetching && <Skeleton h={66} aria-label="جارٍ قراءة قائمة التشغيل" />}
          {!snapshot && disabled && <Text size="sm" c="dimmed">بانتظار اتصال الجسر.</Text>}
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
              <Text size="xs" c="dimmed">
                {disabled || reading.isError ? 'آخر قراءة محفوظة' : 'آخر قراءة'} · {formatDateTime(snapshot.checkedAtMs)}
              </Text>
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
