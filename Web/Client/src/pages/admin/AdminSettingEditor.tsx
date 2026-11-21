import { Alert, Button, Group, Modal, Slider, Stack, Switch, Text } from '@mantine/core'
import { useDisclosure } from '@mantine/hooks'
import { notifications } from '@mantine/notifications'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { api, errorCode, type Schemas } from '../../api/client'
import { messageFor } from '../../api/messages'
import { sessionKey } from '../../api/session'

type Setting = Schemas['AdminOverviewSetting']
type Preview = Schemas['AdminSettingPreview']
const writable = new Set(['NotifyAdminsOnAccessRequest', 'AskRequesterName', 'MaxPendingApprovals', 'PendingStateTimeoutMinutes', 'OneHandMode', 'EnablePersistentMenuButton'])

function settingMessage(code: string) {
  switch (code) {
    case 'setting_stale': return 'تغيّرت القيمة أو انتهت المراجعة. افتح الإعداد وراجع القيمة مجددًا.'
    case 'setting_not_editable': return 'هذا الإعداد متاح للقراءة فقط.'
    case 'setting_invalid': return 'اختر قيمة مختلفة ضمن الحدود المسموح بها.'
    case 'setting_save_failed': return 'تعذّر حفظ الإعداد. بقيت القيمة السابقة مطبّقة.'
    default: return messageFor(code)
  }
}

function valueText(enabled: boolean | null | undefined, value: number | null | undefined, unit: string) {
  if (typeof enabled === 'boolean') return enabled ? 'مفعّل' : 'معطّل'
  return typeof value === 'number' ? `${value} ${unit}`.trim() : 'غير متاح'
}

export function AdminSettingEditor({ setting }: { setting: Setting }) {
  const client = useQueryClient()
  const [opened, modal] = useDisclosure()
  const [enabled, setEnabled] = useState(false)
  const [number, setNumber] = useState(0)
  const [preview, setPreview] = useState<Preview | null>(null)
  const [failure, setFailure] = useState('')
  const isBoolean = setting.kind === 'boolean'
  const minimum = setting.minimum ?? 0
  const maximum = setting.maximum ?? minimum
  const allowEdit = writable.has(setting.id) && !setting.protected && (isBoolean || maximum > minimum)

  function refresh() {
    return client.invalidateQueries({ queryKey: ['admin-overview'] })
  }

  function reportFailure(error: Error) {
    setFailure(settingMessage(error.message))
    if (['forbidden', 'unauthorized'].includes(error.message)) {
      modal.close()
      notifications.show({ color: 'red', message: settingMessage(error.message) })
      void client.invalidateQueries({ queryKey: sessionKey })
    }
    void refresh()
  }

  const reviewing = useMutation({
    mutationFn: async () => {
      const { data, error, response } = await api.POST('/api/admin/settings/{id}/review', {
        params: { path: { id: setting.id } },
        body: { enabled: isBoolean ? enabled : null, value: isBoolean ? null : number },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onMutate: () => setFailure(''),
    onSuccess: setPreview,
    onError: reportFailure,
  })
  const saving = useMutation({
    mutationFn: async (review: string) => {
      const { data, error, response } = await api.POST('/api/admin/settings/{id}/confirm', {
        params: { path: { id: setting.id } }, body: { review },
      })
      if (!data) throw new Error(errorCode(error, response))
      return data
    },
    onMutate: () => setFailure(''),
    onSuccess: async () => {
      modal.close()
      notifications.show({ color: 'green', message: 'حُفظ الإعداد.' })
      await refresh()
    },
    onError: (error) => {
      setPreview(null)
      reportFailure(error)
    },
  })

  if (!allowEdit) return null
  const busy = reviewing.isPending || saving.isPending
  const unchanged = isBoolean ? enabled === setting.enabled : number === setting.value

  function open() {
    setEnabled(setting.enabled ?? false)
    setNumber(Math.max(minimum, Math.min(maximum, setting.value ?? minimum)))
    setPreview(null)
    setFailure('')
    modal.open()
  }

  return <>
    <Button variant="subtle" size="compact-xs" aria-label={`تعديل ${setting.label}`} onClick={open}>تعديل</Button>
    <Modal opened={opened} title={setting.label} centered closeButtonProps={{ 'aria-label': 'إغلاق' }}
      closeOnClickOutside={!busy} closeOnEscape={!busy} withCloseButton={!busy} onClose={modal.close}>
      <Stack gap="md" dir="rtl">
        {failure && <Alert color="red" role="alert">{failure}</Alert>}
        {preview ? (
          <Text size="sm">
            تتغيّر القيمة من «{valueText(preview.setting.enabled, preview.setting.value, preview.setting.unit)}»
            {' '}إلى «{valueText(preview.enabled, preview.value, preview.setting.unit)}».
          </Text>
        ) : <>
          <Text size="sm" c="dimmed">{setting.description}</Text>
          {isBoolean ? (
            <Switch label="تفعيل الإعداد" checked={enabled} disabled={busy} onChange={(event) => setEnabled(event.currentTarget.checked)} />
          ) : (
            <Stack gap="xs">
              <Text size="sm" fw={600}>{number} {setting.unit}</Text>
              <Slider min={minimum} max={maximum} step={1} value={number} onChange={setNumber} disabled={busy}
                thumbLabel={setting.label} label={(value) => `${value} ${setting.unit}`.trim()} />
              <Group justify="space-between">
                <Text size="xs" c="dimmed">الحد الأدنى {minimum}</Text>
                <Text size="xs" c="dimmed">الحد الأقصى {maximum}</Text>
              </Group>
            </Stack>
          )}
        </>}
        <Group justify="flex-end" gap="xs">
          <Button variant="default" onClick={modal.close} disabled={busy}>إلغاء</Button>
          {preview ? <Button loading={saving.isPending} onClick={() => saving.mutate(preview.review)}>تأكيد الحفظ</Button> :
            <Button loading={reviewing.isPending} disabled={unchanged} onClick={() => reviewing.mutate()}>مراجعة التغيير</Button>}
        </Group>
      </Stack>
    </Modal>
  </>
}
