import { Alert, Badge, Button, Group, Paper, SimpleGrid, Stack, Text, Title } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { api, errorCode } from '../../api/client'
import { messageFor } from '../../api/messages'
import { formatDateTime } from '../../lib/time'

const number = new Intl.NumberFormat('ar', { maximumFractionDigits: 2 })
const healthLabels: Record<string, { title: string; color: string }> = {
  healthy: { title: 'سليم', color: 'green' },
  warning: { title: 'تحذير من المحرك', color: 'orange' },
  no_input: { title: 'فقد إشارة في العينة', color: 'orange' },
  no_samples: { title: 'لا توجد عينات', color: 'gray' },
  unavailable: { title: 'القراءة غير متاحة', color: 'gray' },
}
const licenseLabels: Record<string, string> = {
  licensed: 'مرخّص',
  warning: 'تحذير ترخيص',
  unavailable: 'غير متاح',
}

export function EngineHealthPanel() {
  const reading = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.GET('/api/admin/operations/engine-health')
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const sample = reading.data
  const health = healthLabels[sample?.health ?? ''] ?? healthLabels.unavailable
  const metrics = [
    ['عينات القياس', sample?.sampleCount, ''],
    ['إطارات الخرج', sample?.outputFrames, ''],
    ['إطارات مفقودة', sample?.droppedFrames, ''],
    ['فقد إشارة الدخل', sample?.inputLossFrames, ' إطار'],
    ['متوسط زمن القراءة', sample?.meanReadMs, ' مللي ثانية'],
    ['أقصى نسبة لأخطاء القراءة', sample?.maxReadErrorPercent, '%'],
  ] as const

  return (
    <Paper withBorder p="md" radius="md" component="section" aria-labelledby="engine-diagnostics-heading">
      <Stack gap="sm">
        <Group justify="space-between">
          <Title order={2} size="h4" id="engine-diagnostics-heading">تشخيص محرك البث</Title>
          <Button variant="default" loading={reading.isPending} onClick={() => reading.mutate()}>
            {sample?.enabled ? 'تحديث القراءة' : 'قراءة حالة المحرك'}
          </Button>
        </Group>
        <Stack gap="sm" aria-live="polite" aria-busy={reading.isPending}>
          {reading.error && <Alert color="red">{reading.error.message === 'layer_comparison_busy'
            ? 'تجري قراءة من محرك البث. أعد المحاولة بعد لحظة.'
            : messageFor(reading.error.message)}</Alert>}
          {sample && (sample.enabled ? (
            <>
              <Group>
                <Badge color={health.color}>{health.title}</Badge>
                <Text size="sm">الترخيص · {licenseLabels[sample.license ?? ''] ?? licenseLabels.unavailable}</Text>
              </Group>
              {sample.sampleCount != null && (
                <>
                  <SimpleGrid cols={{ base: 2, md: 3 }} spacing="sm">
                    {metrics.map(([label, value, unit]) => (
                      <div key={label}>
                        <Text size="sm" c="dimmed">{label}</Text>
                        <Text fw={600}>{value == null ? '—' : <bdi>{number.format(value)}{unit}</bdi>}</Text>
                      </div>
                    ))}
                  </SimpleGrid>
                  {sample.droppedSampleIncrease != null && (
                    <Text size="sm">زيادة الإطارات المفقودة في العينة مقارنة بالقراءة السابقة · {number.format(sample.droppedSampleIncrease)}</Text>
                  )}
                </>
              )}
              <Text size="xs" c="dimmed">
                آخر قراءة · {formatDateTime(sample.checkedAtMs)}
                {sample.elapsedMs != null && <> · استغرقت {number.format(sample.elapsedMs)} مللي ثانية</>}
              </Text>
            </>
          ) : <Text size="sm" c="dimmed">تشخيص المحرك التفصيلي معطّل في إعدادات الجسر.</Text>)}
        </Stack>
      </Stack>
    </Paper>
  )
}
