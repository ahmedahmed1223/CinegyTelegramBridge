import { Alert, Badge, Button, Group, Paper, SimpleGrid, Skeleton, Stack, Text, Title } from '@mantine/core'
import { IconRefresh } from '@tabler/icons-react'
import { useQuery } from '@tanstack/react-query'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { isAdmin, useSession } from '../../api/session'
import { PageHeader } from '../../components/PageHeader'
import { formatDateTime } from '../../lib/time'

type Row = Schemas['RuntimeFileDiagnostic']
const kinds: Record<string, string> = {
  onair: 'حالة الطبقات',
  schedule: 'جدولة العرض',
  autohide: 'مواعيد الإخفاء',
  reminders: 'تذكيرات القوالب',
  drafts: 'مسودات العرض',
  newsDraft: 'مسودة شريط الأخبار',
  favorites: 'المفضّلة',
  profiles: 'ملفات المستخدمين',
}
const states: Record<string, { label: string; color: string }> = {
  healthy: { label: 'سليم', color: 'teal' },
  absent: { label: 'لم يُنشأ', color: 'gray' },
  recoverable: { label: 'الملف الأساسي تالف', color: 'orange' },
  broken: { label: 'تالف ولا توجد نسخة احتياطية', color: 'red' },
  skipped: { label: 'يتجاوز حد الفحص', color: 'gray' },
  unreadable: { label: 'تعذّرت قراءته', color: 'orange' },
  unknown: { label: 'غير معروف', color: 'gray' },
}
const number = new Intl.NumberFormat('ar', { numberingSystem: 'latn', maximumFractionDigits: 1 })

function RuntimeFileCard({ row }: { row: Row }) {
  const state = states[row.state] ?? states.unknown
  return (
    <Paper withBorder p="md" radius="md">
      <Stack gap="xs">
        <Group justify="space-between" gap="xs">
          <Title order={3} size="h5">{kinds[row.kind] ?? 'ملف تشغيل'}</Title>
          <Badge variant="light" color={state.color}>{state.label}</Badge>
        </Group>
        {row.modifiedAt > 0 && <Text size="sm" c="dimmed">آخر تعديل {formatDateTime(row.modifiedAt)}</Text>}
        {row.state !== 'absent' && <Group gap="sm">
          <Text size="sm" c="dimmed">الحجم {number.format(row.sizeKilobytes)} كيلوبايت</Text>
          {row.hasBackup && <Text size="sm" c="dimmed">نسخة احتياطية موجودة</Text>}
        </Group>}
      </Stack>
    </Paper>
  )
}

export function RuntimeFileDiagnosticsPage({ embedded = false }: { embedded?: boolean }) {
  const session = useSession()
  const canRead = isAdmin(session.data)
  const diagnostics = useQuery({
    queryKey: ['admin', 'runtime-file-diagnostics', session.data?.id],
    enabled: canRead,
    staleTime: 30_000,
    refetchOnWindowFocus: false,
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/admin/diagnostics/runtime-files', { signal })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })

  if (session.isPending) return <Skeleton h={120} />
  if (!canRead) return embedded ? null : <Alert color="red" role="alert">{messageFor('forbidden')}</Alert>
  const refresh = (
    <Button variant="default" size="sm" leftSection={<IconRefresh size={17} />} loading={diagnostics.isFetching}
      onClick={() => void diagnostics.refetch()}>تحديث</Button>
  )
  const report = diagnostics.isError ? undefined : diagnostics.data
  return (
    <Stack gap="md" dir="rtl">
      {embedded ? <Group justify="space-between">
        <Title order={2} size="h4">صحة ملفات التشغيل</Title>{refresh}
      </Group> : <PageHeader title="صحة ملفات التشغيل" actions={refresh} />}
      {diagnostics.isPending && <Skeleton h={120} />}
      {diagnostics.isError && <Alert color="red" role="alert">{messageFor(diagnostics.error.message)}</Alert>}
      {report && <>
        <Group gap="sm">
          <Text size="sm" c="dimmed">آخر فحص {formatDateTime(report.checkedAt)}</Text>
          <Text size="sm" c="dimmed">حد الفحص لكل ملف {number.format(report.parseLimitBytes / (1024 * 1024))} ميغابايت</Text>
        </Group>
        {report.items.length === 0 ? <Text size="sm" c="dimmed">لا توجد ملفات تشغيل معرّفة للفحص.</Text> :
          <SimpleGrid cols={{ base: 1, sm: 2 }}>
            {report.items.map((row) => <RuntimeFileCard key={row.kind} row={row} />)}
          </SimpleGrid>}
      </>}
    </Stack>
  )
}
