import { Alert, Button, Group, Modal, NativeSelect, Stack, Text } from '@mantine/core'
import { useState } from 'react'
import type { Schemas } from '../../api/client'
import { UrgentTimingStepper } from './UrgentTimingStepper'

type Timing = Schemas['UrgentItemTiming']
const inherited = { mode: '', intervalSeconds: 0, repeats: 0 }
const modes = [
  { value: '', label: 'إعداد الجدول' },
  { value: 'text', label: 'تحديث النص' },
  { value: 'exit', label: 'خروج قبل الخبر' },
  { value: 'auto_hide', label: 'إخفاء بعد الخبر' },
]
const format = new Intl.NumberFormat('ar')

export function UrgentRowTiming({ title, timing, busy, stale, error, onClose, onSave }: {
  title: string
  timing?: Timing | null
  busy: boolean
  stale: boolean
  error: string
  onClose: () => void
  onSave: (value: Timing) => void
}) {
  const initial = timing ?? inherited
  const [values, setValues] = useState(initial)
  const unchanged = values.mode === initial.mode && values.intervalSeconds === initial.intervalSeconds && values.repeats === initial.repeats
  return (
    <Modal opened title="توقيت العاجل" onClose={() => { if (!busy) onClose() }}>
      <Stack gap="md">
        <Text size="sm" dir="auto" lineClamp={3}>{title}</Text>
        <NativeSelect label="نمط العرض" data={modes} value={values.mode} disabled={busy}
          onChange={(event) => setValues({ ...values, mode: event.currentTarget.value })} />
        <Stack gap="xs">
          <Text size="sm" fw={500} aria-live="polite">مدة العرض · {values.intervalSeconds ? `${format.format(values.intervalSeconds)} ثانية` : 'إعداد الجدول'}</Text>
          <UrgentTimingStepper label="مدة العرض" value={values.intervalSeconds} minimum={0} maximum={3600} disabled={busy}
            onChange={(intervalSeconds) => setValues({ ...values, intervalSeconds })} />
        </Stack>
        <Stack gap="xs">
          <Text size="sm" fw={500} aria-live="polite">عدد التكرارات · {values.repeats ? format.format(values.repeats) : 'إعداد الجدول'}</Text>
          <UrgentTimingStepper label="عدد التكرارات" value={values.repeats} minimum={0} maximum={99} disabled={busy}
            onChange={(repeats) => setValues({ ...values, repeats })} />
        </Stack>
        {stale && <Alert color="orange" role="alert">تغيّر جدول العواجل. أعد فتح توقيت الخبر من أحدث نسخة.</Alert>}
        {error && <Alert color="orange" role="alert">{error}</Alert>}
        <Group justify="space-between" gap="xs">
          <Button variant="subtle" size="sm" disabled={busy} onClick={() => setValues(inherited)}>الرجوع إلى إعدادات الجدول</Button>
          <Button size="sm" loading={busy} disabled={unchanged || stale} onClick={() => onSave(values)}>حفظ توقيت الخبر</Button>
        </Group>
      </Stack>
    </Modal>
  )
}
