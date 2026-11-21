import { Button, Checkbox, Group, Modal, Stack, Text, Textarea } from '@mantine/core'
import { useState } from 'react'
import type { Schemas } from '../../api/client'
import { ProgrammeBoardPlayout, type BoardAirResult, type BoardAirTarget } from './ProgrammeBoardPlayout'

export function ProgrammeBoardCorrection({ board, row, onClose, onChanged }: {
  board: Schemas['ProgrammeBoardEditor']
  row: Schemas['ProgrammeBoardRow']
  onClose: () => void
  onChanged: (result?: BoardAirResult) => void
}) {
  const [selected, setSelected] = useState<string[]>([])
  const [values, setValues] = useState<Record<string, string>>({ ...row.values })
  const [target, setTarget] = useState<BoardAirTarget | null>(null)
  const [revision] = useState(board.revision)
  const tooLong = selected.some(name => (values[name] ?? '').length > board.maxFieldLength)

  if (target) {
    return <ProgrammeBoardPlayout id={board.id} target={target} onClose={() => setTarget(null)} onChanged={onChanged} />
  }
  return (
    <Modal opened title="تصحيح نص العرض الحالي" size="lg" onClose={onClose}>
      <form onSubmit={(event) => {
        event.preventDefault()
        if (!selected.length || tooLong) return
        setTarget({ action: 'update', rowId: row.id, revision, values: Object.fromEntries(
          selected.map(name => [name, values[name] ?? '']),
        ) })
      }}>
        <Stack gap="md">
          <Text size="sm" c="dimmed">حدّد الحقول التي تريد تصحيحها في المشهد المعروض. لتحرير النسخة المحفوظة، استخدم زر تحرير الصف.</Text>
          {board.fields.map(({ name, label }) => (
            <Stack gap="xs" key={name}>
              <Checkbox checked={selected.includes(name)} label={label} onChange={(event) => {
                setSelected(event.currentTarget.checked ? [...selected, name] : selected.filter(field => field !== name))
              }} />
              {selected.includes(name) && <Textarea aria-label={`القيمة الجديدة لـ ${label}`}
                dir="auto" autosize minRows={2} maxRows={5} value={values[name] ?? ''} maxLength={board.maxFieldLength}
                onChange={(event) => setValues({ ...values, [name]: event.currentTarget.value })} />}
            </Stack>
          ))}
          {tooLong && <Text size="sm" c="red" role="alert">اختصر القيمة المحدّدة لتناسب الحد المسموح للحقل.</Text>}
          <Group justify="flex-end">
            <Button variant="default" onClick={onClose}>إلغاء</Button>
            <Button type="submit" disabled={!selected.length || tooLong}>مراجعة التصحيح</Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  )
}
