import { Alert, Button, Group, Paper, SegmentedControl, Stack, Table, Text, Textarea, Title } from '@mantine/core'
import { useMutation } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import classes from './NewsroomPage.module.css'

const number = new Intl.NumberFormat('ar')
type Bulletin = Schemas['BulletinEditor']
type Preview = Omit<Schemas['BulletinPastePreview'], 'fields'> & { fields: Schemas['ProgrammeBoardField'][] }
type Board = Schemas['ProgrammeBoardEditor']

export function BulletinPaste({ bulletin, onSave, onCancel }: {
  bulletin: Bulletin
  onSave: (page: number) => void
  onCancel: () => void
}) {
  return <RowPaste title="لصق صفوف الموجز" fields={bulletin.fields.filter((field) => field.kind === 'text')}
    alternative={bulletin.headlinePaste ? { value: 'headlines', label: 'عناوين ونصوص', instructions: 'الصق خبرًا في كل سطر بصيغة «العنوان | نص الخبر»، أو الصق نص الخبر وحده.' } : undefined}
    onCancel={onCancel} submit={async (text, format, review) => {
      const { data, error, response } = await api.POST('/api/content/bulletins/paste', {
        body: { action: review ? 'commit' : 'preview', id: bulletin.id, revision: bulletin.revision, text, format, review },
      })
      if (!data) throw new Error(error?.message || messageFor(errorCode(error, response)))
      if (data.savedPage != null) onSave(data.savedPage)
      return data.preview
    }} />
}

export function ProgrammeBoardPaste({ board, onSave, onCancel }: {
  board: Board
  onSave: (page: number) => void
  onCancel: () => void
}) {
  return <RowPaste title="لصق صفوف لوحة البرنامج" fields={board.fields}
    alternative={{ value: 'pipe', label: 'نص مفصول بـ |', instructions: 'اكتب صفًا في كل سطر وافصل بين الحقول بعلامة | بالترتيب الموضّح.' }}
    onCancel={onCancel} submit={async (text, format, review) => {
      const { data, error, response } = await api.POST('/api/content/boards/paste', {
        body: { action: review ? 'commit' : 'preview', id: board.id, revision: board.revision, text, format, review },
      })
      if (!data) throw new Error(error?.message || messageFor(errorCode(error, response)))
      if (data.savedPage != null) onSave(data.savedPage)
      return data.preview
    }} />
}

function RowPaste({ title, fields, alternative, submit, onCancel }: {
  title: string
  fields: Preview['fields']
  alternative?: { value: string; label: string; instructions: string }
  submit: (text: string, format: string, review: string | null) => Promise<Preview | null | undefined>
  onCancel: () => void
}) {
  const [text, setText] = useState('')
  const [format, setFormat] = useState('table')
  const [preview, setPreview] = useState<Preview | null>(null)
  const exceedsLimit = text.length > 8000
  const paste = useMutation({
    mutationFn: (review: string | null) => submit(text, format, review),
    onSuccess: (next) => { if (next) setPreview(next) },
  })
  return (
    <Paper radius="lg" withBorder className={classes.urgentGrid}>
      <form onSubmit={(event) => {
        event.preventDefault()
        if (paste.isPending || exceedsLimit || !text.trim() || (preview && !preview.rows.length)) return
        paste.mutate(preview?.review ?? null)
      }}>
        <Stack gap="sm" p="md">
          <Title order={4}>{preview ? 'مراجعة الصفوف قبل الإضافة' : title}</Title>
          {!preview && (
            <>
              {alternative && (
                <Group>
                  <SegmentedControl<string> aria-label="صيغة اللصق" value={format} onChange={setFormat} disabled={paste.isPending}
                    data={[{ value: 'table', label: 'من جدول' }, { value: alternative.value, label: alternative.label }]} />
                </Group>
              )}
              <Text size="sm" c="dimmed" id="row-paste-instructions">
                {format !== 'table' && alternative && <>{alternative.instructions} </>}
                ترتيب الأعمدة <strong>{fields.map((field) => field.label).join('، ')}</strong>. اترك الخلية فارغة عند الحاجة.
              </Text>
              <Textarea label="الصفوف المنسوخة" aria-describedby="row-paste-instructions"
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
                  راجع عدد الخلايا ومحتواها والمساحة المتاحة. لا تُحسب الأسطر الفارغة.
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
