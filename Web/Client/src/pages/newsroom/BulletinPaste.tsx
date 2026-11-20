import { Alert, Button, Group, Paper, SegmentedControl, Stack, Table, Text, Textarea, Title } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import classes from './NewsroomPage.module.css'

const number = new Intl.NumberFormat('ar')
type Bulletin = Schemas['BulletinEditor']
type Preview = Schemas['BulletinPastePreview']

export function BulletinPaste({ bulletin, onSave, onCancel }: {
  bulletin: Bulletin
  onSave: (page: number) => void
  onCancel: () => void
}) {
  const [text, setText] = useState('')
  const [format, setFormat] = useState('table')
  const [preview, setPreview] = useState<Preview | null>(null)
  const fields = bulletin.fields.filter((field) => field.kind === 'text')
  const exceedsLimit = text.length > 8000
  const paste = useMutation({
    mutationFn: async (review: string | null) => {
      const { data, error, response } = await api.POST('/api/content/bulletins/paste', {
        body: { action: review ? 'commit' : 'preview', id: bulletin.id, revision: bulletin.revision, text, format, review },
      })
      if (!data) throw new Error(error?.message || messageFor(errorCode(error, response)))
      return data
    },
    onSuccess: ({ preview: next, savedPage }) => {
      if (savedPage != null) onSave(savedPage)
      else if (next) setPreview(next)
    },
  })
  return (
    <Paper radius="lg" withBorder className={classes.urgentGrid}>
      <form onSubmit={(event) => {
        event.preventDefault()
        if (paste.isPending || exceedsLimit || !text.trim() || (preview && !preview.rows.length)) return
        paste.mutate(preview?.review ?? null)
      }}>
        <Stack gap="sm" p="md">
          <Title order={4}>{preview ? 'مراجعة الصفوف قبل الإضافة' : 'لصق صفوف الموجز'}</Title>
          {!preview && (
            <>
              {bulletin.headlinePaste && (
                <Group>
                  <SegmentedControl<string> aria-label="صيغة اللصق" value={format} onChange={setFormat} disabled={paste.isPending}
                    data={[{ value: 'table', label: 'من جدول' }, { value: 'headlines', label: 'عناوين ونصوص' }]} />
                </Group>
              )}
              <Text size="sm" c="dimmed" id="bulletin-paste-instructions">
                {format === 'table'
                  ? <>انسخ خلايا النص بالترتيب <strong>{fields.map((field) => field.label).join('، ')}</strong>. اترك الخلية فارغة عند الحاجة.</>
                  : <>الصق خبرًا في كل سطر بصيغة «العنوان | نص الخبر»، أو الصق نص الخبر وحده.</>}
              </Text>
              <Textarea label="الصفوف المنسوخة" aria-describedby="bulletin-paste-instructions"
                dir="auto" autosize minRows={4} maxRows={9}
                autoFocus disabled={paste.isPending} value={text} onChange={(event) => setText(event.currentTarget.value)} />
              <Text size="xs" c="dimmed">حتى ٤٠ صفًا و٨٠٠٠ حرف في الدفعة الواحدة.</Text>
              {exceedsLimit && <Alert color="yellow" role="alert">النص أطول من ٨٠٠٠ حرف. قسّمه إلى دفعات قبل المعاينة.</Alert>}
            </>
          )}
          {preview && (
            <>
              <Text size="sm" role="status">الصفوف الجاهزة للإضافة · {number.format(preview.rows.length)}</Text>
              {!!preview.skippedLines.length && (
                <Alert color="yellow">
                  صفوف لن تُضاف ({preview.skippedLines.map((line) => number.format(line)).join('، ')}).
                  راجع عدد الخلايا ومحتواها. لا تُحسب الأسطر الفارغة.
                </Alert>
              )}
              {!preview.rows.length && <Text c="dimmed">لا توجد صفوف صالحة. عدّل النص ثم أعد المعاينة.</Text>}
            </>
          )}
          {paste.error && <Alert color="red" role="alert">{paste.error.message}</Alert>}
        </Stack>
        {!!preview?.rows.length && (
          <Table.ScrollContainer minWidth={Math.max(270, 150 * preview.fields.length)} type="native" tabIndex={0} aria-label="معاينة جدول اللصق">
            <Table verticalSpacing="xs" horizontalSpacing="md">
              <Table.Thead>
                <Table.Tr>{preview.fields.map((field) => <Table.Th key={field.name} scope="col">{field.label}</Table.Th>)}</Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {preview.rows.map((row, index) => (
                  <Table.Tr key={index}>
                    {preview.fields.map((field) => (
                      <Table.Td key={field.name} className={classes.urgentCell}>
                        <Text dir="auto" size="sm" className={classes.bulletinCellText}>{row[field.name] || '—'}</Text>
                      </Table.Td>
                    ))}
                  </Table.Tr>
                ))}
              </Table.Tbody>
            </Table>
          </Table.ScrollContainer>
        )}
        <Group justify="flex-end" gap="xs" className={classes.bulletinSave}>
          <Button variant="subtle" disabled={paste.isPending} onClick={onCancel}>إلغاء</Button>
          {preview && (
            <Button variant="default" disabled={paste.isPending} onClick={() => { setPreview(null); paste.reset() }}>
              تعديل النص
            </Button>
          )}
          <Button type="submit" loading={paste.isPending} disabled={exceedsLimit || !text.trim() || (!!preview && !preview.rows.length)}>
            {preview ? 'إضافة الصفوف' : 'معاينة اللصق'}
          </Button>
        </Group>
      </form>
    </Paper>
  )
}
