import { ActionIcon, Alert, Button, Group, Paper, SimpleGrid, Stack, Switch, Text, Title } from '@mantine/core'
import { IconMinus, IconPlus } from '@tabler/icons-react'
import { useState } from 'react'
import type { Schemas } from '../../api/client'
import classes from './NewsroomPage.module.css'

type Timing = NonNullable<Schemas['BulletinTiming']>
type TimingInput = NonNullable<Schemas['BulletinTimingInput']>
type TimingDraft = { delayFrames: number; introExtraFrames: number; lastRowFrames: number; syncToLoop: boolean }
const number = new Intl.NumberFormat('ar', { maximumFractionDigits: 2 })
const maximum = 15000

export function BulletinTimingForm({ timing, busy, error, onSave, onCancel }: {
  timing: Timing
  busy: boolean
  error: string
  onSave: (value: TimingInput) => void
  onCancel: () => void
}) {
  const [draft, setDraft] = useState<TimingDraft>({
    delayFrames: timing.delayFrames,
    introExtraFrames: timing.introExtraFrames,
    lastRowFrames: timing.lastRowFrames,
    syncToLoop: timing.syncToLoop,
  })
  const second = Math.max(1, Math.round(timing.fps))
  const canMatch = timing.loopFrames > 0 && timing.loopFrames <= maximum
  const patch = {
    delayFrames: draft.delayFrames !== timing.delayFrames ? draft.delayFrames : null,
    introExtraFrames: draft.introExtraFrames !== timing.introExtraFrames ? draft.introExtraFrames : null,
    lastRowFrames: draft.lastRowFrames !== timing.lastRowFrames ? draft.lastRowFrames : null,
    syncToLoop: draft.syncToLoop !== timing.syncToLoop ? draft.syncToLoop : null,
  }
  const dirty = Object.values(patch).some((value) => value != null)

  function stepper(key: Exclude<keyof TimingInput, 'syncToLoop'>, label: string, minimum: number, fallback?: number) {
    const frames = draft[key]
    function adjust(step: number) {
      setDraft((previous) => ({ ...previous, [key]: Math.min(maximum, Math.max(minimum, previous[key] + step)) }))
    }
    return (
      <Stack gap={6}>
        <Text fw={600} size="sm">{label}</Text>
        <Group gap={6} wrap="nowrap">
          <Button size="compact-sm" variant="default" disabled={busy || frames <= minimum} onClick={() => adjust(-second)}
            aria-label={`إنقاص ${label} بمقدار ${second} إطارًا`}>−{number.format(second)}</Button>
          <ActionIcon variant="default" disabled={busy || frames <= minimum} onClick={() => adjust(-1)}
            aria-label={`إنقاص ${label} إطارًا واحدًا`}><IconMinus size={16} /></ActionIcon>
          <Text component="output" aria-label={label} fw={600} size="sm" ta="center" className={classes.frameValue}>
            {number.format(frames)}
          </Text>
          <ActionIcon variant="default" disabled={busy || frames >= maximum} onClick={() => adjust(1)}
            aria-label={`زيادة ${label} إطارًا واحدًا`}><IconPlus size={16} /></ActionIcon>
          <Button size="compact-sm" variant="default" disabled={busy || frames >= maximum} onClick={() => adjust(second)}
            aria-label={`زيادة ${label} بمقدار ${second} إطارًا`}>+{number.format(second)}</Button>
        </Group>
        <Text size="xs" c="dimmed">
          {frames === 0
            ? fallback != null ? `افتراضي · ${number.format(fallback)} إطار في التوقيت المحفوظ` : 'افتراضي من المشهد أو إعدادات الجسر'
            : `${number.format(frames / timing.fps)} ثانية`}
        </Text>
      </Stack>
    )
  }

  return (
    <Paper withBorder p="md" radius="lg">
      <form onSubmit={(event) => { event.preventDefault(); if (dirty && !busy) onSave(patch) }}>
        <Stack gap="md">
          <div>
            <Title order={4}>توقيت الموجز</Title>
            <Text c="dimmed" size="sm">
              {number.format(timing.fps)} إطارًا في الثانية
              {timing.loopFrames > 0 && ` · طول حلقة المشهد ${number.format(timing.loopFrames)} إطارًا`}
            </Text>
          </div>
          <SimpleGrid cols={{ base: 1, sm: 2, lg: 3 }} spacing="lg">
            {stepper('delayFrames', 'مدة عرض الصف', 1)}
            {stepper('introExtraFrames', 'إضافة الدخول', 0, timing.introExtraFrames === 0 ? timing.effectiveIntroFrames : undefined)}
            {stepper('lastRowFrames', 'مدة الصف الأخير', 0, timing.lastRowFrames === 0 ? timing.effectiveLastFrames : undefined)}
          </SimpleGrid>
          <Group gap="md" align="center">
            <Switch label="مزامنة تبديل الصفوف مع الحلقة" checked={draft.syncToLoop} disabled={busy}
              onChange={(event) => setDraft({ ...draft, syncToLoop: event.currentTarget.checked })} />
            {canMatch && (
              <Button size="compact-sm" variant="subtle" disabled={busy || draft.delayFrames === timing.loopFrames}
                onClick={() => setDraft({ ...draft, delayFrames: timing.loopFrames })}>استخدم طول الحلقة</Button>
            )}
          </Group>
          {draft.syncToLoop && (
            <Text size="sm" c="dimmed">{timing.loopFrames > 0
              ? 'يحدّد طول الحلقة وقت تبديل الصفوف عند التشغيل.'
              : 'سيستخدم الجسر مدة عرض الصف عند غياب حلقة قابلة للقراءة.'}</Text>
          )}
          {!dirty && timing.fitNote && <Text size="sm">{timing.fitNote}</Text>}
          {error && <Alert color="red" role="alert">{error}</Alert>}
          <Group justify="flex-end" gap="xs">
            <Button variant="subtle" onClick={onCancel} disabled={busy}>إلغاء</Button>
            <Button type="submit" disabled={!dirty} loading={busy}>حفظ التوقيت</Button>
          </Group>
        </Stack>
      </form>
    </Paper>
  )
}
