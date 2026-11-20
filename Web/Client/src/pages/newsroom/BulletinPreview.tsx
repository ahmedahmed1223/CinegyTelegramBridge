import { Alert, Badge, Box, Group, Modal, Pagination, Paper, Skeleton, Stack, Text } from '@mantine/core'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'

const number = new Intl.NumberFormat('ar', { maximumFractionDigits: 2 })

function describeMedia(row: Schemas['BulletinPreviewRow'], field: string, imageField?: string | null) {
  if (row.media.includes(field)) return 'مرفق'
  if (field !== imageField) return 'بلا مرفق'
  if (row.imageMode === 'template' || (row.imageMode === 'inherit' && row.number === 1)) return 'صورة القالب'
  if (row.imageMode === 'inherit') return 'استمرار الصورة السابقة'
  return 'بلا مرفق'
}

export function BulletinPreview({ bulletin, onClose }: {
  bulletin: Schemas['BulletinEditor']
  onClose: () => void
}) {
  const [selection, setSelection] = useState<{ page: number; stamp?: string }>({ page: 0 })
  const query = useQuery({
    queryKey: ['bulletin-preview', bulletin.id, bulletin.revision, selection],
    retry: false,
    queryFn: async ({ signal }) => {
      const { data, error, response } = await api.GET('/api/content/bulletins/preview', {
        params: { query: { id: bulletin.id, revision: bulletin.revision, ...selection } }, signal,
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
  })
  const preview = query.data
  return (
    <Modal opened title="معاينة الموجز" onClose={onClose} size="lg" closeButtonProps={{ 'aria-label': 'إغلاق المعاينة' }}>
      <Stack gap="md">
        <Group justify="space-between" gap="xs">
          <Text fw={600} dir="auto">{bulletin.name}</Text>
          <Text size="sm" c="dimmed">النسخة {number.format(bulletin.revision)}</Text>
        </Group>
        {query.isPending && <Skeleton h={96} aria-label="جارٍ تحميل المعاينة" />}
        {query.error && <Alert color="orange" role="alert">
          {query.error.message === 'bulletin_stale' ? 'تغيّر الموجز أو توقيت تشغيله. أغلق المعاينة وحدّث الموجز.' : messageFor(query.error.message)}
        </Alert>}
        {preview && <>
          {preview.total === 0 && <Text c="dimmed">لا توجد صفوف لمراجعتها.</Text>}
          {preview.total > 0 && !preview.fields.length && <Alert color="orange">تعذّر قراءة حقول التصميم.</Alert>}
          {preview.total > 0 && !preview.playbackSupported && <Text size="sm" c="dimmed">مراجعة المحتوى متاحة. توقيت التشغيل غير متاح لهذا التصميم.</Text>}
          {preview.playbackSupported && preview.exitSeconds != null && <Group gap="xs">
            <Badge variant="light">{number.format(preview.plannedCount)} صف في خطة التشغيل</Badge>
            <Text size="sm" c="dimmed">إشارة الخروج عند {number.format(preview.exitSeconds)} ثانية</Text>
          </Group>}
          {preview.playbackSupported && preview.total > 0 && preview.exitSeconds == null && <Text size="sm" c="dimmed">لا توجد صفوف مضمّنة في التشغيل.</Text>}
          {preview.rows.map((row) => <Paper key={row.id} withBorder p="md" radius="md">
            <Stack gap="xs">
              <Group justify="space-between" gap="xs">
                <Text fw={600}>الصف {number.format(row.number)}</Text>
                {row.skipped ? <Badge variant="light" color="gray">مستبعد</Badge>
                  : row.startSeconds != null ? <Text size="sm" c="dimmed">يبدأ عند {number.format(row.startSeconds)} ثانية</Text>
                    : preview.playbackSupported && <Badge variant="light" color="gray">خارج خطة التشغيل</Badge>}
              </Group>
              {preview.fields.map((field) => <Box key={field.name}>
                <Text size="xs" c="dimmed">{field.label}</Text>
                <Text size="sm" dir={field.kind === 'text' ? 'auto' : undefined} style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>
                  {field.kind === 'text' ? row.values[field.name] || '—' : describeMedia(row, field.name, preview.imageField)}
                </Text>
              </Box>)}
            </Stack>
          </Paper>)}
          {preview.pageCount > 1 && <Pagination total={preview.pageCount} value={preview.page + 1}
            onChange={(next) => setSelection({ page: next - 1, stamp: preview.stamp })}
            getItemProps={(value) => ({ 'aria-label': `الصفحة ${number.format(value)}` })} />}
        </>}
      </Stack>
    </Modal>
  )
}
