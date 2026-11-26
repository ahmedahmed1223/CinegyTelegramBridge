import { AdjustableRow, AdjustableTable } from '../../components/AdjustableTable'
import { Alert, Button, Group, Paper, SimpleGrid, Stack, Table, Text, Title } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'

const number = new Intl.NumberFormat('ar')
const time = new Intl.DateTimeFormat('ar', { dateStyle: 'short', timeStyle: 'short' })

export function UsageSummaryPanel() {
  const summary = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/admin/usage-summary')
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const report = summary.data
  const outcomes = report && [
    { label: 'ناجحة', count: report.successful },
    { label: 'فاشلة', count: report.failed },
    { label: 'مرفوضة', count: report.blocked },
  ]

  return (
    <Paper withBorder p="md">
      <Stack gap="md">
        <Group justify="space-between" align="start">
          <Title order={3} size="h4">ملخص الاستخدام</Title>
          <Button size="sm" variant="default" loading={summary.isPending} onClick={() => summary.mutate()}>
            {report ? 'تحديث الملخص' : 'عرض الملخص'}
          </Button>
        </Group>
        {summary.error && (
          <Alert color="red" role="alert" title="تعذّر قراءة ملخص الاستخدام">
            {messageFor(summary.error.message)}
          </Alert>
        )}
        {report && (
          <>
            <Text size="xs" c="dimmed">وقت القراءة {time.format(report.capturedAt)}</Text>
            <Stack gap={4}>
              <Group justify="space-between">
                <Text fw={600}>العمليات منذ بدء تشغيل الجسر</Text>
                {report.startedAt > 0 && <Text size="xs" c="dimmed">{time.format(report.startedAt)}</Text>}
              </Group>
              <SimpleGrid cols={{ base: 1, xs: 3 }} spacing="xs">
                {outcomes?.map((outcome) => (
                  <Stack gap={0} key={outcome.label}>
                    <Text size="sm" c="dimmed">{outcome.label}</Text>
                    <Text fw={600}>{number.format(outcome.count)}</Text>
                  </Stack>
                ))}
              </SimpleGrid>
            </Stack>

            <Stack gap={4}>
              <Text fw={600}>آخر سبعة أيام في سجل العمليات</Text>
              <Text size="sm">
                {number.format(report.sevenDayOperations)} عملية · {number.format(report.dailyAverage)} في اليوم
              </Text>
              {report.sevenDayTruncated && (
                <Alert color="orange" role="status">الأرقام مبنية على الجزء المقروء من السجل لأن الفحص بلغ حدّ القراءة.</Alert>
              )}
            </Stack>

            <Stack gap="xs">
              <Text fw={600}>القوالب الأكثر عرضًا منذ بدء العدّ</Text>
              {report.templates.length > 0 ? (
                <AdjustableTable layoutKey="usage-summary" label="جدول استخدام القوالب" columns={[
                  { id: 'template', label: 'القالب', width: 142 },
                  { id: 'count', label: 'مرات العرض', width: 125 },
                  { id: 'last', label: 'آخر عرض', width: 162 },
                ]}>
                  <Table.Tbody>
                    {report.templates.map((item, index) => (
                      <AdjustableRow key={index}>
                        <Table.Td style={{ overflowWrap: 'anywhere' }}>{item.name || 'اسم القالب محجوب'}</Table.Td>
                        <Table.Td>{number.format(item.uses)}</Table.Td>
                        <Table.Td>{item.lastUsedAt != null ? time.format(item.lastUsedAt) : 'غير مسجّل'}</Table.Td>
                      </AdjustableRow>
                    ))}
                  </Table.Tbody>
                </AdjustableTable>
              ) : <Text size="sm" c="dimmed">لم يُسجّل استخدام لأي قالب.</Text>}
            </Stack>
          </>
        )}
      </Stack>
    </Paper>
  )
}
